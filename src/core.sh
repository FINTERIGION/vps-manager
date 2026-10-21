#!/usr/bin/env bash
# vpsm - shared library (sourced by vpsm.sh / install.sh, do not execute directly)

VPSM_VERSION="1.2.0"
SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Without VPSM_ROOT (e.g. the /usr/local/bin/vpsm symlink), use the installation these scripts live in
if [[ -z ${VPSM_ROOT:-} && ${SH_DIR##*/} == sh && -f ${SH_DIR%/*}/users.json ]]; then
    ROOT=${SH_DIR%/*}
else
    ROOT="${VPSM_ROOT:-/etc/vpsm}"
fi
BIN_DIR="$ROOT/bin"
XRAY_BIN="$BIN_DIR/xray"
CADDY_BIN="$BIN_DIR/caddy"
DB="$ROOT/users.json"
XRAY_CONF="$ROOT/config.json"
SUB_DIR="$ROOT/sub"
WWW_DIR="$ROOT/www"
CADDY_DIR="$ROOT/caddy"
CADDY_USERS="$CADDY_DIR/users"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_ADMIN_SOCK="$CADDY_DIR/run/admin.sock"
CUSTOM_RULES="$ROOT/clash-custom-rules.yaml"
LOCK_FILE="$ROOT/.lock"
SUB_STAMP="$ROOT/.sub_stamp"
SUB_REFRESH=1800 # without structural changes, refresh the subscription traffic header at most every 30 minutes

API_PORT=10085
API_ADDR="127.0.0.1:$API_PORT"
CADDY_PORT=8443 # Caddy listens only on 127.0.0.1:8443 and serves as the Reality dest
INBOUND_TAG="vless-reality"
XRAY_SVC="vpsm-xray"
CADDY_SVC="vpsm-caddy"
SVC_USER="vpsm"

export XRAY_LOCATION_ASSET="$BIN_DIR"

# ---------- Output ----------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_CYN=$'\e[36m' C_RST=$'\e[0m'
else
    C_RED="" C_GRN="" C_YLW="" C_CYN="" C_RST=""
fi
msg() { echo -e "${C_CYN}$*${C_RST}"; }
ok() { echo -e "${C_GRN}$*${C_RST}"; }
warn() { echo -e "${C_YLW}Warning: $*${C_RST}" >&2; }
err() {
    echo -e "${C_RED}Error: $*${C_RST}" >&2
    exit 1
}

need_root() { [[ $EUID -eq 0 || -n ${VPSM_NO_SERVICE:-} ]] || err "Please run as root"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
port_in_use() { cmd_exists ss && ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

# Service wrapper. With VPSM_NO_SERVICE=1 it only prints instead of executing (local dry run / testing)
svc() {
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        msg "(dry run, skipped) systemctl $*"
        return 0
    fi
    systemctl "$@"
}
svc_active() {
    [[ -z ${VPSM_NO_SERVICE:-} ]] && systemctl is-active --quiet "$1"
}
# True if the unit is still running shortly after a (re)start: a bad config makes it exit within moments
svc_settled() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    sleep 2
    systemctl is-active --quiet "$1"
}

# ---------- Lock ----------
# Call inside a subshell: ( acquire_lock; do_something ); released when the subshell exits
acquire_lock() {
    mkdir -p "$ROOT"
    # Set by update_sh when it runs the new scripts while still holding the lock; waiting would deadlock
    [[ -n ${VPSM_LOCK_HELD:-} ]] && return 0
    exec 9>"$LOCK_FILE"
    flock -w 60 9 || err "Timed out waiting for lock (is another vpsm process running?)"
}

# Run a command in a subshell holding the lock: run_locked func args...
run_locked() { ( acquire_lock && "$@" ); }

# ---------- Database (users.json) ----------
db_get() { jq -r "$@" "$DB"; }

# Atomic write: db_write [jq options...] 'filter'; nothing is written if the content is unchanged
db_write() {
    local tmp
    tmp=$(mktemp "$ROOT/.db.XXXXXX") || err "Failed to create temporary file"
    if ! jq "$@" "$DB" >"$tmp"; then
        rm -f "$tmp"
        err "Failed to update database"
    fi
    if cmp -s "$tmp" "$DB"; then
        rm -f "$tmp"
    else
        chmod 600 "$tmp"
        mv -f "$tmp" "$DB"
    fi
}

# Compute last_reset: this month if this month's reset day has passed, otherwise last month
# (avoids an unintended immediate reset after changing the reset day)
calc_last_reset() {
    local rd=$1 day
    day=$((10#$(date +%d)))
    if ((day >= rd)); then
        date +%Y-%m
    else
        date -d "$(date +%Y-%m-01) -1 month" +%Y-%m
    fi
}

# db_init <domain> <port> <private_key> <public_key> <short_id> <reset_day>
db_init() {
    mkdir -p "$ROOT"
    (
        umask 077
        jq -n --arg domain "$1" --argjson port "$2" --arg priv "$3" --arg pub "$4" \
            --arg sid "$5" --argjson rd "$6" --arg lr "$(calc_last_reset "$6")" \
            '{settings:{domain:$domain,port:$port,private_key:$priv,public_key:$pub,
              short_ids:[$sid],reset_day:$rd,last_reset:$lr},users:[]}' >"$DB.new" &&
            mv -f "$DB.new" "$DB"
    ) || { rm -f "$DB.new"; err "Failed to create $DB"; }
}

need_installed() { [[ -f $DB ]] || err "$DB not found, please run install.sh first"; }

user_exists() { jq -e --arg n "$1" '.users[]|select(.name==$n)' "$DB" >/dev/null 2>&1; }
user_get() { jq -r --arg n "$1" ".users[]|select(.name==\$n)|$2" "$DB"; }

# ---------- Random / validation ----------
gen_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }

# "all" is reserved: vpsm reset all means every user
valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ && $1 != all ]]; }
valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)); }
# The public Xray port must not collide with Caddy (80 / CADDY_PORT) or the Xray API
valid_xray_port() { valid_port "$1" && (($1 != 80 && $1 != CADDY_PORT && $1 != API_PORT)); }
valid_shortid() { [[ $1 =~ ^([0-9a-fA-F]{2}){1,8}$ ]]; }
# Node name: 1-64 characters, no quotes / backslashes / control characters (it is embedded in YAML strings),
# and it must not collide with a Clash built-in policy or a proxy group of the template
valid_node_name() {
    [[ -n $1 && ${#1} -le 64 && $1 != *[\"\\[:cntrl:]]* ]] || return 1
    case $1 in
        DIRECT | REJECT | REJECT-DROP | PASS | COMPATIBLE | Proxy | Steam | AdBlock | Final) return 1 ;;
    esac
}

# ---------- Unit conversion ----------
# parse_quota <200G|500M|1.5T|0|unlimited>: prints bytes; no unit means GB; 0 means unlimited.
# Capped at 1024T so the byte count stays within bash 64-bit arithmetic and exact jq integers
parse_quota() {
    local s="${1,,}" n u m
    s="${s// /}"
    case $s in 0 | unlimited | inf | none | -) echo 0; return 0 ;; esac
    [[ $s =~ ^([0-9]+(\.[0-9]+)?)(b|k|kb|m|mb|g|gb|t|tb)?$ ]] || return 1
    n=${BASH_REMATCH[1]}
    u=${BASH_REMATCH[3]:-g}
    case $u in
        b) m=1 ;;
        k | kb) m=1024 ;;
        m | mb) m=$((1024 ** 2)) ;;
        g | gb) m=$((1024 ** 3)) ;;
        t | tb) m=$((1024 ** 4)) ;;
    esac
    awk -v n="$n" -v m="$m" 'BEGIN{b = n * m; if (b > 0 && b < 1 || b > 1024 ^ 5) exit 1; printf "%.0f", b}'
}

fmt_size() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i]
    }'
}

today() { date +%F; }

# parse_expire <0|never|30d|2m|1y|+30d|YYYY-MM-DD> [current_expiry]
# Prints YYYY-MM-DD; empty string means never expires. "+Nd" extends from the current expiry
# (or from today if already expired)
parse_expire() {
    local s="${1,,}" base="${2:-}" start n unit
    case $s in 0 | never | none | - | "") echo ""; return 0 ;; esac
    if [[ $s =~ ^(\+?)([0-9]+)([dmy])$ ]]; then
        n=${BASH_REMATCH[2]}
        unit=${BASH_REMATCH[3]}
        start=$(today)
        if [[ -n ${BASH_REMATCH[1]} && -n $base && $base > $start ]]; then
            start=$base
        fi
        if [[ $unit == d ]]; then
            date -d "$start +$n days" +%F
            return 0
        fi
        # Months/years: add calendar months, clamping to the last day of the target month (e.g. 1-31 +1m = 2-28)
        [[ $unit == y ]] && n=$((n * 12))
        local ym dd last
        ym=$(date -d "${start%-*}-01 +$n months" +%Y-%m)
        dd=${start##*-}
        last=$(date -d "$ym-01 +1 month -1 day" +%d)
        ((10#$dd > 10#$last)) && dd=$last
        echo "$ym-$dd"
        return 0
    fi
    if [[ $s =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ $(date -d "$s" +%F 2>/dev/null) == "$s" ]]; then
        echo "$s"
        return 0
    fi
    return 1
}

# ---------- Subscription URL ----------
# Name shown in clients: Clash proxy name, subscription (profile) name and share link remark. Defaults to the domain
node_name() { db_get 'if (.settings.name // "") == "" then .settings.domain else .settings.name end'; }

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

sub_url() {
    local domain port token
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    token=$(user_get "$1" '.token')
    if [[ $port == 443 ]]; then
        echo "https://$domain/sub/$token"
    else
        echo "https://$domain:$port/sub/$token"
    fi
}

# ---------- Download / install cores ----------
dl() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# verify_sum <sha256|sha512> <expected hex digest> <file>
verify_sum() {
    local want=${2,,} got
    [[ $want =~ ^[0-9a-f]{64}([0-9a-f]{64})?$ ]] || return 1
    got=$("$1sum" "$3" | awk '{print $1}')
    [[ $got == "$want" ]]
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) XARCH=64 CARCH=amd64 ;;
        aarch64 | arm64) XARCH=arm64-v8a CARCH=arm64 ;;
        armv7l) XARCH=arm32-v7a CARCH=armv7 ;;
        *) err "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

# Get the latest tag via the releases/latest redirect (no API, not subject to rate limits)
github_latest() {
    curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/##'
}

# bin_backup <file...>: keep the installed files in $BIN_DIR as *.old so a failed update can be rolled back
bin_backup() {
    local f
    for f in "$@"; do
        [[ -f $BIN_DIR/$f ]] && cp -p "$BIN_DIR/$f" "$BIN_DIR/$f.old"
    done
    return 0
}

# bin_restore <file...>: put the *.old files back; fails if the first one (the binary) was never backed up
bin_restore() {
    local f
    [[ -f $BIN_DIR/$1.old ]] || return 1
    for f in "$@"; do
        [[ -f $BIN_DIR/$f.old ]] && mv -f "$BIN_DIR/$f.old" "$BIN_DIR/$f"
    done
    return 0
}

bin_drop_backup() {
    local f
    for f in "$@"; do rm -f "$BIN_DIR/$f.old"; done
}

# install_xray [tag]
install_xray() {
    detect_arch
    local tag=${1:-} tmp url
    [[ -n $tag ]] || tag=$(github_latest XTLS/Xray-core)
    [[ -n $tag ]] || err "Failed to get the latest Xray version"
    msg "Downloading Xray $tag ..."
    tmp=$(mktemp -d)
    url="https://github.com/XTLS/Xray-core/releases/download/$tag/Xray-linux-$XARCH.zip"
    dl "$url" "$tmp/x.zip" && dl "$url.dgst" "$tmp/x.dgst" ||
        { rm -rf "$tmp"; err "Failed to download Xray"; }
    verify_sum sha256 "$(awk '$1 == "SHA2-256=" {print $2; exit}' "$tmp/x.dgst")" "$tmp/x.zip" ||
        { rm -rf "$tmp"; err "Xray checksum mismatch, not installed"; }
    unzip -qo "$tmp/x.zip" xray geoip.dat -d "$tmp" || { rm -rf "$tmp"; err "Failed to extract Xray"; }
    if [[ -f $XRAY_CONF ]] && ! XRAY_LOCATION_ASSET=$tmp "$tmp/xray" run -test -config "$XRAY_CONF" >"$tmp/test.log" 2>&1; then
        cat "$tmp/test.log" >&2
        rm -rf "$tmp"
        err "Xray $tag rejects the current config, not installed"
    fi
    mkdir -p "$BIN_DIR"
    bin_backup xray geoip.dat xray.version
    # Copy to a temp file then mv, to avoid overwriting a running binary (Text file busy)
    cp "$tmp/xray" "$BIN_DIR/.xray.new" && chmod 755 "$BIN_DIR/.xray.new" && mv -f "$BIN_DIR/.xray.new" "$XRAY_BIN"
    cp "$tmp/geoip.dat" "$BIN_DIR/geoip.dat" && chmod 644 "$BIN_DIR/geoip.dat"
    echo "$tag" >"$BIN_DIR/xray.version"
    rm -rf "$tmp"
}

# install_caddy [tag]
install_caddy() {
    detect_arch
    local tag=${1:-} tmp base name
    [[ -n $tag ]] || tag=$(github_latest caddyserver/caddy)
    [[ -n $tag ]] || err "Failed to get the latest Caddy version"
    msg "Downloading Caddy $tag ..."
    tmp=$(mktemp -d)
    base="https://github.com/caddyserver/caddy/releases/download/$tag"
    name="caddy_${tag#v}_linux_${CARCH}.tar.gz"
    dl "$base/$name" "$tmp/c.tgz" && dl "$base/caddy_${tag#v}_checksums.txt" "$tmp/sums" ||
        { rm -rf "$tmp"; err "Failed to download Caddy"; }
    verify_sum sha512 "$(awk -v f="$name" '$2 == f {print $1; exit}' "$tmp/sums")" "$tmp/c.tgz" ||
        { rm -rf "$tmp"; err "Caddy checksum mismatch, not installed"; }
    tar -xzf "$tmp/c.tgz" -C "$tmp" caddy || { rm -rf "$tmp"; err "Failed to extract Caddy"; }
    # XDG paths point into $tmp so validation cannot touch the live certificate storage
    if [[ -f $CADDYFILE ]] && ! XDG_DATA_HOME=$tmp XDG_CONFIG_HOME=$tmp \
        "$tmp/caddy" validate --config "$CADDYFILE" --adapter caddyfile >"$tmp/test.log" 2>&1; then
        cat "$tmp/test.log" >&2
        rm -rf "$tmp"
        err "Caddy $tag rejects the current Caddyfile, not installed"
    fi
    mkdir -p "$BIN_DIR"
    bin_backup caddy caddy.version
    cp "$tmp/caddy" "$BIN_DIR/.caddy.new" && chmod 755 "$BIN_DIR/.caddy.new" && mv -f "$BIN_DIR/.caddy.new" "$CADDY_BIN"
    echo "$tag" >"$BIN_DIR/caddy.version"
    rm -rf "$tmp"
}

# Generate an x25519 key pair, printing two lines: private key / public key.
# Handles the output labels of both old and new xray versions
gen_x25519() {
    local out priv pub
    out=$("$XRAY_BIN" x25519 "$@" 2>/dev/null) || return 1
    priv=$(awk -F': *' '/[Pp]rivate/ {print $2; exit}' <<<"$out")
    pub=$(awk -F': *' '/[Pp]ublic|Password/ {print $2; exit}' <<<"$out")
    [[ -n $priv && -n $pub ]] || return 1
    printf '%s\n%s\n' "$priv" "$pub"
}

# svc_dir <dir>: create a directory readable only by root and the service group
# (subscription files and Caddy snippets contain the users' tokens)
svc_dir() {
    mkdir -p "$1"
    chmod 750 "$1"
    [[ -z ${VPSM_NO_SERVICE:-} ]] && getent group "$SVC_USER" >/dev/null 2>&1 && chgrp "$SVC_USER" "$1"
    return 0
}

# Fix file permissions. Caddy runs as the vpsm user; Xray runs as a separate dynamic user and gets
# config.json as stdin from systemd, so the Reality private key stays root-only
fix_perms() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    [[ -f $XRAY_CONF ]] && chown root:root "$XRAY_CONF" && chmod 600 "$XRAY_CONF"
    getent group "$SVC_USER" >/dev/null 2>&1 || return 0
    chmod 755 "$ROOT"
    svc_dir "$SUB_DIR"
    svc_dir "$CADDY_USERS"
    mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config" "${CADDY_ADMIN_SOCK%/*}"
    chown -R "$SVC_USER:$SVC_USER" "$CADDY_DIR/data" "$CADDY_DIR/config" "${CADDY_ADMIN_SOCK%/*}"
    chmod 700 "$CADDY_DIR/data" "$CADDY_DIR/config" "${CADDY_ADMIN_SOCK%/*}"
    return 0
}
