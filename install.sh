#!/usr/bin/env bash
# vpsm installer - multi-user VLESS+Reality+Vision node manager (Xray + Caddy). See usage() for options
set -o pipefail

# Kept in a heredoc rather than a header comment: with bash <(curl ...) the script file cannot be re-read
usage() {
    cat <<'EOF'
vpsm installer - multi-user VLESS+Reality+Vision node manager (Xray + Caddy)

Usage:
  bash install.sh [options]          (from a cloned repo)
  bash <(curl -fsSL https://raw.githubusercontent.com/FINTERIGION/vps-manager/main/install.sh) [options]

Options (env variable in brackets; no prompts when all are given):
  --domain <domain>    Domain already resolving to this host (Reality SNI, also used by Caddy for TLS) [VPSM_DOMAIN]
  --port <port>        Public Xray listen port, default 443 [VPSM_PORT]
  --name <name>        Node name = subscription name shown in clients, default the domain [VPSM_NAME]
  --user <name>        First user, default admin [VPSM_USER]
  --quota <traffic>    Monthly traffic of the first user, e.g. 200G, 0=unlimited, default 0 [VPSM_QUOTA]
  --expire <expiry>    Expiry of the first user, e.g. 30d / 2026-12-31, 0=never, default 0 [VPSM_EXPIRE]
  --reset-day <1-28>   Monthly traffic reset day shared by all users, default 1 [VPSM_RESET_DAY]
  --firewall           Enable the iptables firewall (allow only SSH / 80 / Xray port inbound), default off [VPSM_FIREWALL=y]
  -y, --yes            Non-interactive, use defaults/arguments for everything
  -h, --help           Show this help
EOF
}

export VPSM_ROOT="${VPSM_ROOT:-/etc/vpsm}"
REPO="${VPSM_REPO:-FINTERIGION/vps-manager}"
REF="${VPSM_REF:-main}"
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

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --name) NODE_NAME=$2; shift 2 ;;
        --user) FIRST_USER=$2; shift 2 ;;
        --quota) QUOTA=$2; shift 2 ;;
        --expire) EXPIRE=$2; shift 2 ;;
        --reset-day) RESET_DAY=$2; shift 2 ;;
        --firewall) FIREWALL=y; shift ;;
        -y | --yes) YES=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 || -n ${VPSM_NO_SERVICE:-} ]] || die "Please run as root"
[[ -n ${VPSM_NO_SERVICE:-} ]] || { [[ -d /run/systemd/system ]] || die "systemd is required"; }
# .installing exists until the installer finishes, so a failed run can simply be repeated
if [[ -s $VPSM_ROOT/users.json && ! -f $VPSM_ROOT/.installing ]]; then
    die "Existing installation found ($VPSM_ROOT/users.json); use vpsm update to upgrade, or vpsm uninstall before reinstalling"
fi
[[ -f $VPSM_ROOT/.installing ]] && echo "Resuming an unfinished installation in $VPSM_ROOT"

# ask <var_name> <prompt> <default>
ask() {
    local __var=$1 __prompt=$2 __def=$3 __in=""
    if [[ -z ${!__var} ]]; then
        if [[ -z $YES && -r /dev/tty ]]; then
            read -r -p "$__prompt${__def:+ [$__def]}: " __in </dev/tty
        fi
        printf -v "$__var" '%s' "${__in:-$__def}"
    fi
}

# ---------- Dependencies ----------
install_deps() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    # Without cmp every sync sees a changed config.json and restarts Xray; without ip the
    # self-address block in the Xray routing is silently empty
    local required=(curl jq unzip tar flock timeout cmp diff ip ss) need=() c pm iproute=iproute2
    for c in "${required[@]}" qrencode iptables; do
        command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
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
}

# ---------- Fetch scripts ----------
fetch_scripts() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -f $here/src/core.sh && -f $here/vpsm.sh ]]; then
        SRC_DIR=$here
        return 0
    fi
    DL_TMP=$(mktemp -d) || die "Failed to create temporary directory"
    trap 'rm -rf "$DL_TMP"' EXIT
    echo "Downloading scripts $REPO@$REF ..."
    curl -fsSL --retry 3 -o "$DL_TMP/s.tgz" "https://github.com/$REPO/archive/$REF.tar.gz" || die "Failed to download scripts"
    tar -xzf "$DL_TMP/s.tgz" -C "$DL_TMP" --strip-components=1 || die "Failed to extract scripts"
    [[ -f $DL_TMP/src/core.sh && -f $DL_TMP/vpsm.sh ]] || die "Downloaded scripts are incomplete ($REPO@$REF)"
    SRC_DIR=$DL_TMP
}

# ================= Start =================
install_deps
fetch_scripts

mkdir -p "$VPSM_ROOT/sh"
touch "$VPSM_ROOT/.installing"
if [[ $SRC_DIR != "$VPSM_ROOT/sh" ]]; then
    cp -r "$SRC_DIR/vpsm.sh" "$SRC_DIR/src" "$SRC_DIR/templates" "$SRC_DIR/systemd" "$VPSM_ROOT/sh/" ||
        die "Failed to copy scripts to $VPSM_ROOT/sh"
fi
chmod 755 "$VPSM_ROOT/sh/vpsm.sh"
echo "$REPO $REF" >"$VPSM_ROOT/repo"

# shellcheck disable=SC1091
. "$VPSM_ROOT/sh/src/core.sh"
for _lib in xray traffic sub caddy user firewall manage; do
    # shellcheck disable=SC1090
    . "$SH_DIR/src/$_lib.sh"
done

# ---------- Prompt for parameters ----------
ask DOMAIN "Domain (must already resolve to this server's IP)" ""
valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
ask PORT "Xray listen port" 443
valid_port "$PORT" || die "Invalid port: $PORT"
valid_xray_port "$PORT" || die "Port $PORT is used internally by vpsm (80 / $CADDY_PORT / $API_PORT), choose another"
ask NODE_NAME "Node/subscription name shown in clients" "$DOMAIN"
valid_node_name "$NODE_NAME" || die "Invalid name: $NODE_NAME (1-64 characters without quotes, backslashes or control characters, and not a Clash policy/group name)"
ask FIRST_USER "First username" admin
valid_name "$FIRST_USER" || die "Username may only contain letters, digits, underscores and hyphens, length 1-32 (\"all\" is reserved)"
ask QUOTA "Monthly traffic for this user (e.g. 200G, 0=unlimited)" 0
parse_quota "$QUOTA" >/dev/null || die "Invalid traffic: $QUOTA (e.g. 200G / 500M / 1.5T / 0, max 1024T)"
ask EXPIRE "Expiry for this user (e.g. 30d / 2026-12-31, 0=never)" 0
parse_expire "$EXPIRE" >/dev/null || die "Invalid expiry format: $EXPIRE"
ask RESET_DAY "Monthly traffic reset day (1-28, shared by all users)" 1
[[ $RESET_DAY =~ ^[0-9]+$ ]] && ((10#$RESET_DAY >= 1 && 10#$RESET_DAY <= 28)) || die "Reset day must be between 1 and 28"
RESET_DAY=$((10#$RESET_DAY))
ask FIREWALL "Enable iptables firewall (allow only SSH, 80 and $PORT inbound, reject the rest, block ping)? (y/n)" n
[[ ${FIREWALL,,} =~ ^(y|yes|1|true)$ ]] && FIREWALL=1 || FIREWALL=""

# ---------- Environment checks (warnings only) ----------
if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    my_ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null)
    dns_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z $dns_ip ]]; then
        warn "Domain $DOMAIN does not resolve yet; Caddy cannot obtain a certificate (subscriptions unavailable). Add an A record first"
    elif [[ -n $my_ip && $dns_ip != "$my_ip" ]]; then
        warn "Domain resolves to $dns_ip, but this server's public IP is $my_ip"
    fi
    for p in 80 "$PORT"; do
        port_in_use "$p" && warn "Port $p is already in use; stop the service occupying it first (e.g. nginx/apache)"
    done
fi

# ---------- Install ----------
if [[ -z ${VPSM_NO_SERVICE:-} ]] && ! getent passwd "$SVC_USER" >/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER" ||
        useradd --system --no-create-home --shell /sbin/nologin "$SVC_USER" || die "Failed to create system user"
fi
mkdir -p "$BIN_DIR" "$SUB_DIR" "$CADDY_USERS" "$WWW_DIR"
chmod 755 "$VPSM_ROOT"

install_xray
install_caddy
bin_drop_backup xray geoip.dat xray.version caddy caddy.version

pair=$(gen_x25519) || die "Failed to generate Reality key pair"
priv=$(sed -n 1p <<<"$pair")
pub=$(sed -n 2p <<<"$pair")
db_init "$DOMAIN" "$PORT" "$priv" "$pub" "$(gen_hex 4)" "$RESET_DAY"
# Left unset when it equals the domain, so the name keeps following later domain changes
[[ $NODE_NAME != "$DOMAIN" ]] && db_write --arg n "$NODE_NAME" '.settings.name = $n'

caddy_gen
if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    ln -sf "$VPSM_ROOT/sh/vpsm.sh" /usr/local/bin/vpsm
    install_units
fi
fix_perms

# Create the first user (also generates config.json and subscription files)
user_add "$FIRST_USER" "$QUOTA" "$EXPIRE" || die "Failed to create user"
fix_perms

if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
    systemctl enable --now "$FW_SVC" "$XRAY_SVC" "$CADDY_SVC" vpsm-traffic.timer
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
Manage:       vpsm        (interactive menu)    vpsm help (all commands)
Subscription: $(sub_url "$FIRST_USER")

Notes:
 1. Allow TCP 80 (Caddy certificate issuance) and TCP $PORT (node/subscription) in your firewall
 2. The first certificate request may take tens of seconds; the subscription link is unavailable until then (vpsm log caddy shows progress)
 3. Subscriptions use the Clash Meta / Mihomo format (original Clash does not support VLESS Reality)
 4. Traffic is synced every minute; all users' traffic resets on day $RESET_DAY of each month
 5. Firewall: $(fw_state_text) (vpsm firewall on|off|allow <port> to manage)
=======================================================
EOF
