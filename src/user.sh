#!/usr/bin/env bash
# vpsm - user management and global settings

user_status_text() {
    case "$(user_get "$1" '.disabled_reason')" in
        "") echo "active" ;;
        quota) echo "disabled (quota exceeded)" ;;
        expired) echo "disabled (expired)" ;;
        manual) echo "disabled (manual)" ;;
    esac
}

# Next traffic reset date
next_reset_date() {
    local rd last month
    rd=$(db_get '.settings.reset_day')
    last=$(db_get '.settings.last_reset')
    month=$(date +%Y-%m)
    if [[ $last == "$month" ]]; then
        month=$(date -d "$(date +%Y-%m-01) +1 month" +%Y-%m)
    fi
    printf '%s-%02d' "$month" "$rd"
}

require_user() {
    [[ -n ${1:-} ]] || err "Please specify a username"
    user_exists "$1" || err "User $1 does not exist"
}

# vpsm add <name> [quota 200G|0] [expiry 30d|2026-12-31|0]
user_add() {
    local name=${1:-} quota expire snap
    [[ -n $name ]] || err "Usage: vpsm add <name> [quota e.g. 200G, 0=unlimited] [expiry e.g. 30d / 2026-12-31, 0=never]"
    valid_name "$name" || err "Username may only contain letters, digits, underscores and hyphens, length 1-32 (\"all\" is reserved)"
    user_exists "$name" && err "User $name already exists"
    quota=$(parse_quota "${2:-0}") || err "Invalid traffic: ${2:-}, examples: 200G / 500M / 1.5T / 0 (max 1024T)"
    expire=$(parse_expire "${3:-0}") || err "Invalid expiry format: ${3:-}, examples: 30d / 6m / 1y / 2026-12-31 / 0"
    snap=$(state_snapshot)
    db_write --arg name "$name" --arg uuid "$(gen_uuid)" --arg token "$(gen_hex 16)" \
        --argjson quota "$quota" --arg expire "$expire" \
        '.users += [{name:$name,uuid:$uuid,token:$token,quota:$quota,up:0,down:0,
                     expire:$expire,enabled:true,disabled_reason:""}]'
    apply_state "$snap" force
    ok "User $name added"
    user_info "$name"
}

user_del() {
    require_user "${1:-}"
    local snap
    snap=$(state_snapshot)
    db_write --arg n "$1" '.users |= map(select(.name != $n))'
    apply_state "$snap" force
    ok "User $1 deleted"
}

user_list() {
    traffic_pull
    local count name quota up down expire reason used pct total
    count=$(db_get '.users | length')
    if ((count == 0)); then
        msg "No users yet, add one with vpsm add <name>"
        return 0
    fi
    printf '%-16s %-26s %-5s %-11s %s\n' NAME "USED / TOTAL" PCT EXPIRE STATUS
    while IFS=$'\t' read -r name quota up down expire reason; do
        used=$((up + down))
        if ((quota > 0)); then
            total=$(fmt_size "$quota")
            pct="$((used * 100 / quota))%"
        else
            total="unlimited"
            pct="-"
        fi
        case $reason in
            "-") reason="active" ;;
            quota) reason="disabled (quota exceeded)" ;;
            expired) reason="disabled (expired)" ;;
            manual) reason="disabled (manual)" ;;
        esac
        printf '%-16s %-26s %-5s %-11s %s\n' "$name" "$(fmt_size "$used") / $total" "$pct" "$expire" "$reason"
    done < <(jq -r '.users[] | [.name, .quota, .up, .down,
                (if (.expire // "") == "" then "-" else .expire end),
                (if .disabled_reason == "" then "-" else .disabled_reason end)] | @tsv' "$DB")
    echo
    echo "Traffic resets on day $(db_get '.settings.reset_day') of each month, next reset: $(next_reset_date)"
}

user_info() {
    require_user "${1:-}"
    traffic_pull
    local n=$1 quota up down expire
    quota=$(user_get "$n" '.quota')
    up=$(user_get "$n" '.up')
    down=$(user_get "$n" '.down')
    expire=$(user_get "$n" '.expire // ""')
    echo "Username:     $n"
    echo "UUID:         $(user_get "$n" '.uuid')"
    echo "Status:       $(user_status_text "$n")"
    echo "Used:         $(fmt_size $((up + down))) (up $(fmt_size "$up") / down $(fmt_size "$down"))"
    if ((quota > 0)); then
        echo "Quota:        $(fmt_size "$quota") ($(fmt_size $((quota > up + down ? quota - up - down : 0))) left)"
    else
        echo "Quota:        unlimited"
    fi
    echo "Expires:      ${expire:-never}"
    echo "Next reset:   $(next_reset_date)"
    echo "Subscription: $(sub_url "$n")"
}

user_sub() {
    require_user "${1:-}"
    sub_url "$1"
}

# Generic vless:// share link (single-node import for v2rayN / Shadowrocket / NekoBox, etc.)
user_url() {
    require_user "${1:-}"
    local domain port
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    echo "vless://$(user_get "$1" '.uuid')@$domain:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain&fp=chrome&pbk=$(db_get '.settings.public_key')&sid=$(db_get '.settings.short_ids[0]')&type=tcp#$(urlencode "$(node_name)")"
}

user_qr() {
    require_user "${1:-}"
    cmd_exists qrencode || err "qrencode is not installed, install it first: apt install qrencode"
    qrencode -t ansiutf8 "$(sub_url "$1")"
}

user_quota() {
    require_user "${1:-}"
    [[ -n ${2:-} ]] || err "Usage: vpsm quota <name> <traffic e.g. 200G, 0=unlimited>"
    local quota snap
    quota=$(parse_quota "$2") || err "Invalid traffic: $2, examples: 200G / 500M / 1.5T / 0 (max 1024T)"
    snap=$(state_snapshot)
    db_write --arg n "$1" --argjson q "$quota" '.users |= map(if .name == $n then .quota = $q else . end)'
    apply_state "$snap" force
    ok "Quota of user $1 set to $( ((quota > 0)) && fmt_size "$quota" || echo unlimited)"
    msg "Status: $(user_status_text "$1")"
}

user_expire() {
    require_user "${1:-}"
    [[ -n ${2:-} ]] || err "Usage: vpsm expire <name> <2026-12-31 | 30d | +30d(extend) | 0(never)>"
    local expire snap
    expire=$(parse_expire "$2" "$(user_get "$1" '.expire // ""')") || err "Invalid expiry format: $2"
    snap=$(state_snapshot)
    db_write --arg n "$1" --arg e "$expire" '.users |= map(if .name == $n then .expire = $e else . end)'
    apply_state "$snap" force
    ok "Expiry of user $1 set to ${expire:-never}"
    msg "Status: $(user_status_text "$1")"
}

# vpsm reset <name|all>: reset used traffic to zero
user_reset() {
    [[ -n ${1:-} ]] || err "Usage: vpsm reset <name|all>"
    local snap
    if [[ $1 == all ]]; then
        snap=$(state_snapshot)
        traffic_pull
        db_write '.users |= map(.up = 0 | .down = 0)'
        apply_state "$snap" force
        ok "Traffic reset for all users"
    else
        require_user "$1"
        snap=$(state_snapshot)
        traffic_pull
        db_write --arg n "$1" '.users |= map(if .name == $n then .up = 0 | .down = 0 else . end)'
        apply_state "$snap" force
        ok "Traffic reset for user $1"
    fi
}

user_disable() {
    require_user "${1:-}"
    local snap
    snap=$(state_snapshot)
    db_write --arg n "$1" '.users |= map(if .name == $n then .enabled = false | .disabled_reason = "manual" else . end)'
    apply_state "$snap" force
    ok "User $1 disabled"
}

user_enable() {
    require_user "${1:-}"
    local snap
    snap=$(state_snapshot)
    db_write --arg n "$1" '.users |= map(if .name == $n then .disabled_reason = "" else . end)'
    apply_state "$snap" force
    if [[ -n "$(user_get "$1" 'select(.enabled) | .name')" ]]; then
        ok "User $1 enabled"
    else
        warn "User $1 is still disabled: $(user_status_text "$1") (adjust the quota/expiry or reset traffic first)"
    fi
}

# Regenerate the subscription token; the old subscription URL stops working immediately
user_token() {
    require_user "${1:-}"
    local snap
    snap=$(state_snapshot)
    db_write --arg n "$1" --arg t "$(gen_hex 16)" '.users |= map(if .name == $n then .token = $t else . end)'
    apply_state "$snap" force
    ok "Subscription URL updated, the old URL no longer works:"
    sub_url "$1"
}

# ---------- Global settings ----------

# vpsm reset-day <1-28>: monthly traffic reset day shared by all users
set_reset_day() {
    local d=${1:-}
    [[ $d =~ ^[0-9]+$ ]] && ((10#$d >= 1 && 10#$d <= 28)) || err "Usage: vpsm reset-day <1-28>"
    d=$((10#$d))
    db_write --argjson rd "$d" --arg lr "$(calc_last_reset "$d")" '.settings.reset_day = $rd | .settings.last_reset = $lr'
    ok "All users' traffic will reset on day $d of each month, next reset: $(next_reset_date)"
}

set_port() {
    valid_port "${1:-}" || err "Usage: vpsm port <1-65535>"
    valid_xray_port "$1" || err "Port $1 is used internally by vpsm (80 / $CADDY_PORT / $API_PORT), choose another"
    if (($1 == $(db_get '.settings.port'))); then
        msg "Listen port is already $1"
        return 0
    fi
    [[ -z ${VPSM_NO_SERVICE:-} ]] && port_in_use "$1" && err "Port $1 is already in use by another program (ss -ltnp 'sport = :$1')"
    db_write --argjson p "$1" '.settings.port = $p'
    fw_refresh
    xray_gen_config
    xray_active && xray_restart
    # The http:// redirect points at the port
    caddy_gen
    sub_regen force
    caddy_reload
    if fw_enabled; then
        ok "Listen port changed to $1 (vpsm firewall updated; subscriptions/client nodes have been updated)"
    else
        ok "Listen port changed to $1 (make sure the firewall allows it; subscriptions/client nodes have been updated)"
    fi
}

set_domain() {
    valid_domain "${1:-}" || err "Usage: vpsm domain <domain> (must resolve to this server)"
    db_write --arg d "$1" '.settings.domain = $d'
    caddy_gen
    xray_gen_config
    xray_active && xray_restart
    sub_regen force
    caddy_reload
    ok "Domain changed to $1, Caddy will obtain a certificate for it automatically"
}

# vpsm name [name|0]: node name and subscription name shown in clients (both are the same);
# without an argument show the current one, 0 restores the default (the domain)
set_node_name() {
    local n="$*"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    if [[ -z $n ]]; then
        echo "Node/subscription name: $(node_name)"
        return 0
    fi
    if [[ $n == 0 ]]; then
        n=""
    else
        valid_node_name "$n" || err "Invalid name: 1-64 characters without quotes, backslashes or control characters, and not a Clash policy/group name (DIRECT, REJECT, Proxy, Final ...)"
    fi
    db_write --arg n "$n" '.settings.name = $n'
    sub_regen force
    ok "Node/subscription name set to $(node_name) (clients pick it up after refreshing; some only use the subscription name on first import)"
}

# vpsm key [private_key|-]: without an argument, generate a new key pair (all clients must refresh subscriptions);
# "-" reads the private key from stdin, keeping it out of the shell history
set_key() {
    local pair priv pub key=${1:-}
    if [[ $key == - ]]; then
        if [[ -t 0 ]]; then
            read -r -s -p "Private key: " key
            echo
        else
            read -r key
        fi
        [[ -n $key ]] || err "No private key given"
    fi
    if [[ -n $key ]]; then
        pair=$(gen_x25519 -i "$key") || err "Invalid private key"
    else
        pair=$(gen_x25519) || err "Failed to generate key pair"
    fi
    priv=$(sed -n 1p <<<"$pair")
    pub=$(sed -n 2p <<<"$pair")
    db_write --arg a "$priv" --arg b "$pub" '.settings.private_key = $a | .settings.public_key = $b'
    xray_gen_config
    xray_active && xray_restart
    sub_regen force
    ok "Key pair updated, public key: $pub (clients just need to refresh their subscription)"
}

# vpsm shortid [hex]: generate a random one without an argument
set_shortid() {
    local sid=${1:-$(gen_hex 4)}
    valid_shortid "$sid" || err "shortId must be a hex string of even length between 2 and 16"
    db_write --arg s "$sid" '.settings.short_ids = [$s]'
    xray_gen_config
    xray_active && xray_restart
    sub_regen force
    ok "shortId updated to $sid (clients just need to refresh their subscription)"
}

# Regenerate all configs (config.json / Caddyfile / subscriptions)
regen_all() {
    xray_gen_config
    # Later syncs see an unchanged config.json, so the running Xray must pick it up now
    [[ -n $XRAY_CONF_CHANGED ]] && xray_active && xray_restart
    caddy_gen
    sub_regen force
    caddy_reload
    fw_refresh
    ok "Configs regenerated"
}

# Edit custom Clash rules, then regenerate subscriptions
edit_rules() {
    if [[ ! -f $CUSTOM_RULES ]]; then
        cat >"$CUSTOM_RULES" <<'EOF'
# Custom Clash rules, one per line, inserted before all built-in rules (highest priority)
# Available policy groups: Proxy / Steam / AdBlock / Final / DIRECT / REJECT
# Examples:
# DOMAIN-SUFFIX,example.com,Proxy
# DOMAIN-KEYWORD,tracker,AdBlock
# IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
EOF
    fi
    "${EDITOR:-vi}" "$CUSTOM_RULES"
    run_locked sub_regen force || return 1
    ok "Subscriptions updated, takes effect after clients refresh"
}
