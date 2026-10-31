#!/usr/bin/env bash
# vpsm installer - single-node multi-user VLESS+Reality+Vision (Xray + Caddy)
set -o pipefail

usage() {
    cat <<'EOF'
vpsm installer - single-node multi-user VLESS+Reality+Vision manager

Usage:
  bash install.sh                    (interactive, from a cloned repo)
  bash <(curl -fsSL https://raw.githubusercontent.com/FINTERIGION/vps-manager/main/install.sh)

Running without options prompts for every setting.
Options (unattended installation, environment variable in brackets):
  --domain <domain>    Domain resolving to this host (Reality SNI and Caddy TLS) [VPSM_DOMAIN]
  --port <port>        Public Xray listen port, default 443 [VPSM_PORT]
  --name <name>        Node name shown in clients, default the domain [VPSM_NAME]
  --user <name>        First user, default admin [VPSM_USER]
  --quota <traffic>    First user's monthly traffic, e.g. 200G, 0=unlimited [VPSM_QUOTA]
  --expire <expiry>    Global expiry for every user: 30d / YYYY-MM-DD / 0=never [VPSM_EXPIRE]
  --reset-day <1-28>   Monthly traffic reset day shared by all users, default 1 [VPSM_RESET_DAY]
  --firewall           Enable the iptables inbound whitelist [VPSM_FIREWALL=y]
  -y, --yes            Non-interactive, use defaults and arguments
  -h, --help           Show this help
EOF
}

export VPSM_ROOT="${VPSM_ROOT:-/etc/vpsm}"
REPO="${VPSM_REPO:-FINTERIGION/vps-manager}"
REF="${VPSM_REF:-}"
DOMAIN="${VPSM_DOMAIN:-}"
PORT="${VPSM_PORT:-}"
NODE_NAME="${VPSM_NAME:-}"
FIRST_USER="${VPSM_USER:-}"
QUOTA="${VPSM_QUOTA:-}"
EXPIRE="${VPSM_EXPIRE:-}"
RESET_DAY="${VPSM_RESET_DAY:-}"
FIREWALL="${VPSM_FIREWALL:-}"
YES=""

die() { echo "Error: $*" >&2; exit 1; }
need_opt_arg() { [[ -n ${2:-} && $2 != --* ]] || die "$1 requires a value"; }
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) need_opt_arg "$1" "${2:-}"; DOMAIN=$2; shift 2 ;;
        --port) need_opt_arg "$1" "${2:-}"; PORT=$2; shift 2 ;;
        --name) need_opt_arg "$1" "${2:-}"; NODE_NAME=$2; shift 2 ;;
        --user) need_opt_arg "$1" "${2:-}"; FIRST_USER=$2; shift 2 ;;
        --quota) need_opt_arg "$1" "${2:-}"; QUOTA=$2; shift 2 ;;
        --expire) need_opt_arg "$1" "${2:-}"; EXPIRE=$2; shift 2 ;;
        --reset-day) need_opt_arg "$1" "${2:-}"; RESET_DAY=$2; shift 2 ;;
        --firewall) FIREWALL=y; shift ;;
        -y | --yes) YES=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 || -n ${VPSM_NO_SERVICE:-} ]] || die "Please run as root"
[[ -n ${VPSM_NO_SERVICE:-} ]] || { [[ -d /run/systemd/system ]] || die "systemd is required"; }
if [[ -s $VPSM_ROOT/users.json && ! -f $VPSM_ROOT/.installing ]]; then
    die "Existing installation found ($VPSM_ROOT/users.json); use vpsm update to upgrade, or vpsm uninstall first"
fi
[[ -f $VPSM_ROOT/.installing ]] && echo "Resuming an unfinished installation in $VPSM_ROOT"

ask() {
    local __var=$1 __prompt=$2 __def=$3 __in=""
    if [[ -z ${!__var} ]]; then
        if [[ -z $YES && -r /dev/tty ]]; then
            read -r -p "$__prompt${__def:+ [$__def]}: " __in </dev/tty
        fi
        printf -v "$__var" '%s' "${__in:-$__def}"
    fi
}

install_deps() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    local required=(curl jq unzip tar flock timeout cmp diff ip ss python3) need=() c pm iproute=iproute2
    for c in "${required[@]}" qrencode iptables; do
        command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
    python3 -c 'import yaml' >/dev/null 2>&1 || need+=(pyyaml)
    [[ ${#need[@]} -eq 0 ]] && return 0
    if command -v apt-get >/dev/null 2>&1; then
        pm=apt-get
    elif command -v dnf >/dev/null 2>&1; then
        pm=dnf iproute=iproute
    elif command -v yum >/dev/null 2>&1; then
        pm=yum iproute=iproute
    fi
    local pkgs=() p
    for p in "${need[@]}"; do
        case $p in
            flock) p=util-linux ;;
            timeout) p=coreutils ;;
            cmp | diff) p=diffutils ;;
            ip | ss) p=$iproute ;;
            pyyaml) [[ $pm == apt-get ]] && p=python3-yaml || p=python3-pyyaml ;;
        esac
        [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
    done
    [[ -n $pm ]] || die "Unsupported package manager, please install manually: ${pkgs[*]}"
    echo "Installing dependencies: ${pkgs[*]}"
    if [[ $pm == apt-get ]]; then
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || true
    else
        "$pm" install -y "${pkgs[@]}" || true
    fi
    for c in "${required[@]}"; do
        command -v "$c" >/dev/null 2>&1 || die "Missing dependency: $c"
    done
    python3 -c 'import yaml' >/dev/null 2>&1 || die "Missing dependency: Python YAML support"
}

fetch_scripts() {
    local here url label
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -f $here/src/core.sh && -f $here/vpsm.sh && -d $here/templates && -d $here/systemd ]]; then
        SRC_DIR=$here
        if [[ -z $REF ]]; then
            if [[ -e $here/.git ]] && command -v git >/dev/null 2>&1; then
                REF=$(git -C "$here" symbolic-ref --short -q HEAD 2>/dev/null || true)
            elif [[ -f $here/.git/HEAD ]] && [[ $(<"$here/.git/HEAD") == "ref: refs/heads/"* ]]; then
                REF=$(<"$here/.git/HEAD")
                REF=${REF#ref: refs/heads/}
            fi
            REF=${REF:-main}
        fi
        return 0
    fi
    REF=${REF:-main}
    url="https://github.com/$REPO/archive/$REF.tar.gz"
    label="$REPO@$REF"
    DL_TMP=$(mktemp -d) || die "Failed to create temporary directory"
    trap 'rm -rf "$DL_TMP"' EXIT
    echo "Downloading scripts $label ..."
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 -o "$DL_TMP/s.tgz" "$url" || die "Failed to download scripts"
    tar -xzf "$DL_TMP/s.tgz" -C "$DL_TMP" --strip-components=1 || die "Failed to extract scripts"
    [[ -f $DL_TMP/src/core.sh && -f $DL_TMP/vpsm.sh && -d $DL_TMP/templates && -d $DL_TMP/systemd ]] ||
        die "Downloaded scripts are incomplete ($label)"
    SRC_DIR=$DL_TMP
}

install_deps
fetch_scripts
mkdir -p "$VPSM_ROOT/sh"
exec 9>"$VPSM_ROOT/.lock"
flock -w 60 9 || die "Timed out waiting for lock (is another vpsm process running?)"
if [[ -s $VPSM_ROOT/users.json && ! -f $VPSM_ROOT/.installing ]]; then
    die "Existing installation found ($VPSM_ROOT/users.json); use vpsm update to upgrade, or vpsm uninstall first"
fi
touch "$VPSM_ROOT/.installing"
if [[ $SRC_DIR != "$VPSM_ROOT/sh" ]]; then
    cp -r "$SRC_DIR/vpsm.sh" "$SRC_DIR/src" "$SRC_DIR/templates" "$SRC_DIR/systemd" "$VPSM_ROOT/sh/" ||
        die "Failed to copy scripts to $VPSM_ROOT/sh"
fi
chmod 755 "$VPSM_ROOT/sh/vpsm.sh"
echo "$REPO $REF" >"$VPSM_ROOT/repo"
# shellcheck disable=SC1091
. "$VPSM_ROOT/sh/src/core.sh"
for _lib in xray traffic extra_sub sub caddy user firewall security manage; do
    # shellcheck disable=SC1090
    . "$SH_DIR/src/$_lib.sh"
done

RESUME=""
if [[ -s $DB ]] && jq -e '.settings.domain != "" and .settings.private_key != "" and .settings.port != null' "$DB" >/dev/null 2>&1; then
    RESUME=1
    msg "Existing keys and users in $DB will be kept"
    DOMAIN=$(db_get '.settings.domain')
    PORT=$(db_get '.settings.port')
    NODE_NAME=$(node_name)
    RESET_DAY=$(db_get '.settings.reset_day')
    EXPIRE=${EXPIRE:-$(db_get '.settings.expire // ""')}
    _existing=$(db_get '.users[0].name // empty')
    [[ -n $_existing ]] && FIRST_USER=$_existing
    QUOTA=${QUOTA:-0}
    unset _existing
fi

if [[ -z $RESUME ]]; then
    ask DOMAIN "Domain (must already resolve to this server's IP)" ""
    valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
    ask PORT "Xray listen port" 443
    valid_port "$PORT" || die "Invalid port: $PORT"
    valid_xray_port "$PORT" || die "Port $PORT is reserved internally (80 / $CADDY_PORT / $API_PORT)"
    ask NODE_NAME "Node name shown in clients" "$DOMAIN"
    if [[ $NODE_NAME != "$DOMAIN" ]]; then
        valid_node_name "$NODE_NAME" || die "Invalid node name"
    fi
    ask FIRST_USER "First username" admin
    valid_name "$FIRST_USER" || die "Invalid username"
    ask QUOTA "Monthly traffic for this user (e.g. 200G, 0=unlimited)" 0
    parse_quota "$QUOTA" >/dev/null || die "Invalid traffic: $QUOTA"
    ask EXPIRE "Global expiry for every user (30d / YYYY-MM-DD, 0=never)" 0
    parse_expire "$EXPIRE" >/dev/null || die "Invalid expiry format: $EXPIRE"
    EXPIRE=$(parse_expire "$EXPIRE")
    ask RESET_DAY "Monthly traffic reset day (1-28, shared by all users)" 1
    [[ $RESET_DAY =~ ^[0-9]+$ ]] && ((10#$RESET_DAY >= 1 && 10#$RESET_DAY <= 28)) || die "Reset day must be between 1 and 28"
    RESET_DAY=$((10#$RESET_DAY))
elif [[ -z $FIRST_USER ]]; then
    ask FIRST_USER "First username" admin
    valid_name "$FIRST_USER" || die "Invalid username"
    ask QUOTA "Monthly traffic for this user (e.g. 200G, 0=unlimited)" 0
    parse_quota "$QUOTA" >/dev/null || die "Invalid traffic: $QUOTA"
fi
ask FIREWALL "Enable iptables firewall (allow only SSH, 80 and $PORT inbound)? (y/n)" n
[[ ${FIREWALL,,} =~ ^(y|yes|1|true)$ ]] && FIREWALL=1 || FIREWALL=""

if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    my_ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null)
    dns_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z $dns_ip ]]; then
        warn "Domain $DOMAIN does not resolve yet; subscriptions are unavailable until DNS and ACME are ready"
    elif [[ -n $my_ip && $dns_ip != "$my_ip" ]]; then
        warn "Domain resolves to $dns_ip, but this server's public IP is $my_ip"
    fi
    if fw_ssh_ports | grep -qx "$PORT"; then
        die "Port $PORT is the SSH port; choose another Xray port"
    fi
    if port_in_use 80 && ! systemctl is-active --quiet "$CADDY_SVC"; then
        die "Port 80 is already in use; stop the conflicting service before installing"
    fi
    if port_in_use "$PORT" && ! systemctl is-active --quiet "$XRAY_SVC"; then
        die "Port $PORT is already in use; stop the conflicting service or choose another Xray port"
    fi
    if ! getent passwd "$SVC_USER" >/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER" ||
            useradd --system --no-create-home --shell /sbin/nologin "$SVC_USER" || die "Failed to create system user"
    fi
fi

mkdir -p "$BIN_DIR" "$SUB_DIR" "$SUB_EXTRA" "$CADDY_USERS" "$WWW_DIR"
chmod 700 "$SUB_EXTRA"
chmod 755 "$VPSM_ROOT"
XRAY_WAS_ACTIVE=""
CADDY_WAS_ACTIVE=""
if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    systemctl is-active --quiet "$XRAY_SVC" 2>/dev/null && XRAY_WAS_ACTIVE=1
    systemctl is-active --quiet "$CADDY_SVC" 2>/dev/null && CADDY_WAS_ACTIVE=1
fi
install_xray
install_caddy
bin_drop_backup xray geoip.dat xray.version caddy caddy.version

if [[ -z $RESUME ]]; then
    pair=$(gen_x25519) || die "Failed to generate Reality key pair"
    priv=$(sed -n 1p <<<"$pair")
    pub=$(sed -n 2p <<<"$pair")
    db_init "$DOMAIN" "$PORT" "$priv" "$pub" "$(gen_hex 4)" "$RESET_DAY" "$EXPIRE"
    [[ $NODE_NAME != "$DOMAIN" ]] && db_write --arg n "$NODE_NAME" '.settings.name = $n'
fi

caddy_gen
if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    ln -sf "$VPSM_ROOT/sh/vpsm.sh" /usr/local/bin/vpsm
    install_units
fi
fix_perms
if [[ -n $FIRST_USER ]] && user_exists "$FIRST_USER"; then
    xray_gen_config
    sub_regen force
    msg "Keeping existing user $FIRST_USER"
else
    user_add "$FIRST_USER" "$QUOTA" || die "Failed to create user"
fi
fix_perms

if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    systemctl enable --now "$FW_SVC" vpsm-traffic.timer
    systemctl enable "$XRAY_SVC" "$CADDY_SVC"
    if [[ -n $XRAY_WAS_ACTIVE ]]; then
        traffic_pull || traffic_pull || warn "Failed to persist Xray traffic before restart"
        systemctl restart "$XRAY_SVC"
    else
        systemctl start "$XRAY_SVC"
    fi
    if [[ -n $CADDY_WAS_ACTIVE ]]; then
        systemctl restart "$CADDY_SVC"
    else
        systemctl start "$CADDY_SVC"
    fi
    sleep 2
    for s in "$XRAY_SVC" "$CADDY_SVC"; do
        systemctl is-active --quiet "$s" || warn "$s failed to start, check: journalctl -u $s -n 50"
    done
fi
if [[ -n $FIREWALL ]]; then
    (fw_enable --yes) || warn "Failed to enable the firewall, retry later with: vpsm firewall on"
fi
rm -f "$VPSM_ROOT/.installing"

cat <<EOF

================ Installation complete ================
Manage:       vpsm        (fixed numeric menu)
Help:         vpsm help
Subscription: $(sub_url "$FIRST_USER")

Notes:
 1. Allow TCP 80 and TCP $PORT in your provider firewall
 2. Subscriptions use the Clash Meta / Mihomo format
 3. Traffic syncs every minute and resets on day $RESET_DAY
 4. Every user expires on ${EXPIRE:-never}; change it with: vpsm expire <date>
 5. Attach shared Clash subscriptions with: vpsm attach <alias> <url> [filter]
 6. Firewall: $(fw_state_text)
 7. Shadowrocket lacks REALITY ML-KEM support: use a Mihomo client, or run
    vpsm update xray v26.7.28 for older-client compatibility
=======================================================
EOF
