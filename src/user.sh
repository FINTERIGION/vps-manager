#!/usr/bin/env bash
# vpsm - local users and global node settings

user_status_text() {
    case "$(user_get "$1" '.disabled_reason')" in
        "") echo "active" ;;
        quota) echo "disabled (quota exceeded)" ;;
        expired) echo "disabled (expired)" ;;
        manual) echo "disabled (manual)" ;;
    esac
}

next_reset_date() {
    local rd last month day
    rd=$(db_get '.settings.reset_day')
    last=$(db_get '.settings.last_reset')
    month=$(date +%Y-%m)
    day=$((10#$(date +%d)))
    [[ $rd =~ ^[0-9]+$ ]] || rd=1
    if [[ $last == "$month" ]]; then
        month=$(date -d "$(date +%Y-%m-01) +1 month" +%Y-%m)
    elif ((day >= 10#$rd)); then
        date +%F
        return
    fi
    printf '%s-%02d' "$month" "$rd"
}

require_user() {
    [[ -n ${1:-} ]] || err "Please specify a username"
    user_exists "$1" || err "User $1 does not exist"
}

user_add() {
    local name=${1:-} quota snap db_snap
    [[ -n $name ]] || err "Usage: vpsm user add <name> [quota e.g. 200G, 0=unlimited]"
    valid_name "$name" || err "Username may only contain letters, digits, underscores and hyphens, length 1-32 (\"all\" is reserved)"
    user_exists "$name" && err "User $name already exists"
    quota=$(parse_quota "${2:-0}") || err "Invalid traffic: ${2:-}, examples: 200G / 500M / 1.5T / 0 (max 1024T)"
    snap=$(state_snapshot)
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg name "$name" --arg uuid "$(gen_uuid)" --arg token "$(gen_hex 16)" \
        --argjson quota "$quota" \
        '.users += [{name:$name,uuid:$uuid,token:$token,quota:$quota,up:0,down:0,
                     enabled:true,disabled_reason:""}]'
    if ! ( apply_state "$snap" force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "User $name was not added"
    fi
    rm -f "$db_snap"
    ok "User $name added"
    user_info "$name"
}

user_del() {
    require_user "${1:-}"
    local snap db_snap
    snap=$(state_snapshot)
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$1" '.users |= map(select(.name != $n))'
    if ! ( apply_state "$snap" force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "User $1 was not deleted"
    fi
    rm -f "$db_snap"
    ok "User $1 deleted"
}

user_list() {
    traffic_pull
    local count name quota up down reason used pct total expire
    count=$(db_get '.users | length')
    ((count == 0)) && { msg "No users yet, add one with: vpsm user add <name> [quota]"; return 0; }
    expire=$(db_get '.settings.expire // ""')
    printf '%-16s %-26s %-5s %s\n' NAME "USED / TOTAL" PCT STATUS
    while IFS='|' read -r name quota up down reason; do
        [[ -n $name ]] || continue
        is_uint "$quota" || quota=0
        is_uint "$up" || up=0
        is_uint "$down" || down=0
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
        printf '%-16s %-26s %-5s %s\n' "$name" "$(fmt_size "$used") / $total" "$pct" "$reason"
    done < <(jq -r '.users[] | "\(.name)|\(.quota)|\(.up)|\(.down)|\(if .disabled_reason == "" then "-" else .disabled_reason end)"' "$DB")
    echo
    echo "Traffic resets on day $(db_get '.settings.reset_day') of each month, next reset: $(next_reset_date)"
    echo "All users expire: ${expire:-never}"
}

user_info() {
    require_user "${1:-}"
    traffic_pull
    local n=$1 quota up down expire
    quota=$(user_get "$n" '.quota')
    up=$(user_get "$n" '.up')
    down=$(user_get "$n" '.down')
    expire=$(db_get '.settings.expire // ""')
    is_uint "$quota" || quota=0
    is_uint "$up" || up=0
    is_uint "$down" || down=0
    echo "Username:       $n"
    echo "UUID:           $(user_get "$n" '.uuid')"
    echo "Status:         $(user_status_text "$n")"
    echo "Used:           $(fmt_size $((up + down))) (up $(fmt_size "$up") / down $(fmt_size "$down"))"
    if ((quota > 0)); then
        echo "Quota:          $(fmt_size "$quota") ($(fmt_size $((quota > up + down ? quota - up - down : 0))) left)"
    else
        echo "Quota:          unlimited"
    fi
    echo "Expires:        ${expire:-never}"
    echo "Next reset:     $(next_reset_date)"
    echo "External subs:  $(extra_sub_count) shared by every user"
    echo "Subscription:   $(sub_url "$n")"
    echo "Share link:     $(vless_share_url "$n")"
}

user_sub() {
    require_user "${1:-}"
    sub_url "$1"
}

vless_share_url() {
    local domain port url
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    url="vless://$(user_get "$1" '.uuid')@$domain:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain&fp=chrome&pbk=$(db_get '.settings.public_key')&sid=$(db_get '.settings.short_ids[0]')&type=tcp"
    xray_mlkem_ok && url+="&support-x25519mlkem768=true"
    printf '%s#%s\n' "$url" "$(urlencode "$(local_proxy_name)")"
}

user_url() {
    require_user "${1:-}"
    vless_share_url "$1"
}

user_qr() {
    require_user "${1:-}"
    cmd_exists qrencode || err "qrencode is not installed, install it first"
    qrencode -t ansiutf8 "$(sub_url "$1")"
}

user_quota() {
    require_user "${1:-}"
    [[ -n ${2:-} ]] || err "Usage: vpsm quota <name> <traffic e.g. 200G, 0=unlimited>"
    local quota snap db_snap
    quota=$(parse_quota "$2") || err "Invalid traffic: $2, examples: 200G / 500M / 1.5T / 0 (max 1024T)"
    snap=$(state_snapshot)
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$1" --argjson q "$quota" '.users |= map(if .name == $n then .quota = $q else . end)'
    if ! ( apply_state "$snap" force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Quota of user $1 was not changed"
    fi
    rm -f "$db_snap"
    ok "Quota of user $1 set to $( ((quota > 0)) && fmt_size "$quota" || echo unlimited)"
    msg "Status: $(user_status_text "$1")"
}

set_expire() {
    local expire snap db_snap
    [[ -n ${1:-} ]] || err "Usage: vpsm expire <YYYY-MM-DD | 30d | +30d | 0>"
    expire=$(parse_expire "$1" "$(db_get '.settings.expire // ""')") || err "Invalid expiry format: $1"
    snap=$(state_snapshot)
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg e "$expire" '.settings.expire = $e'
    if ! ( apply_state "$snap" force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Global expiry was not changed"
    fi
    rm -f "$db_snap"
    ok "Global expiry set to ${expire:-never}; it now applies to every user"
}

user_reset() {
    [[ -n ${1:-} ]] || err "Usage: vpsm reset <name|all>"
    local snap db_snap
    if [[ $1 == all ]]; then
        snap=$(state_snapshot)
        traffic_pull || traffic_pull || err "Failed to persist Xray traffic, not reset"
        db_snap=$(db_snapshot) || err "Failed to back up the database"
        db_write '.users |= map(.up = 0 | .down = 0)'
        if ! ( apply_state "$snap" force skip ); then
            db_restore "$db_snap" || warn "Failed to restore the database"
            db_rollback_runtime
            err "Traffic reset failed"
        fi
        rm -f "$db_snap"
        ok "Traffic reset for all users"
    else
        require_user "$1"
        snap=$(state_snapshot)
        traffic_pull || traffic_pull || err "Failed to persist Xray traffic, not reset"
        db_snap=$(db_snapshot) || err "Failed to back up the database"
        db_write --arg n "$1" '.users |= map(if .name == $n then .up = 0 | .down = 0 else . end)'
        if ! ( apply_state "$snap" force skip ); then
            db_restore "$db_snap" || warn "Failed to restore the database"
            db_rollback_runtime
            err "Traffic reset failed for user $1"
        fi
        rm -f "$db_snap"
        ok "Traffic reset for user $1"
    fi
}

user_disable() {
    require_user "${1:-}"
    local snap db_snap
    snap=$(state_snapshot)
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$1" '.users |= map(if .name == $n then .enabled = false | .disabled_reason = "manual" else . end)'
    if ! ( apply_state "$snap" force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "User $1 was not disabled"
    fi
    rm -f "$db_snap"
    ok "User $1 disabled"
}

user_enable() {
    require_user "${1:-}"
    local snap db_snap
    snap=$(state_snapshot)
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$1" '.users |= map(if .name == $n then .disabled_reason = "" else . end)'
    if ! ( apply_state "$snap" force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "User $1 was not enabled"
    fi
    rm -f "$db_snap"
    if [[ -n "$(user_get "$1" 'select(.enabled) | .name')" ]]; then
        ok "User $1 enabled"
    else
        warn "User $1 is still disabled: $(user_status_text "$1") (adjust the quota/expiry or reset traffic first)"
    fi
}

user_token() {
    require_user "${1:-}"
    local db_snap
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$1" --arg t "$(gen_hex 16)" '.users |= map(if .name == $n then .token = $t else . end)'
    if ! ( sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Subscription token for user $1 was not changed"
    fi
    rm -f "$db_snap"
    ok "Subscription URL updated, the old URL no longer works:"
    sub_url "$1"
}

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
    if fw_ssh_ports | grep -qx "$1"; then
        err "Port $1 is the SSH port, choose another"
    fi
    if (($1 == $(db_get '.settings.port'))); then
        msg "Listen port is already $1"
        return 0
    fi
    [[ -z ${VPSM_NO_SERVICE:-} ]] && port_in_use "$1" && err "Port $1 is already in use by another program"
    local old new=$1
    old=$(db_get '.settings.port')
    db_write --argjson p "$new" '.settings.port = $p'
    xray_gen_config
    caddy_gen
    sub_regen force
    if xray_active; then
        if ! xray_restart force || ! svc_settled "$XRAY_SVC"; then
            db_write --argjson p "$old" '.settings.port = $p'
            xray_gen_config
            caddy_gen
            sub_regen force
            xray_restart force
            err "Xray failed to listen on port $new, listen port not changed"
        fi
    fi
    if fw_enabled && ! fw_apply; then
        db_write --argjson p "$old" '.settings.port = $p'
        xray_gen_config
        caddy_gen
        sub_regen force
        xray_active && xray_restart force
        fw_apply || warn "Firewall may still allow port $new, run: vpsm firewall reload"
        err "Failed to update firewall for port $new, listen port not changed"
    fi
    caddy_reload || warn "Caddy reload failed after the port change; run: vpsm regen"
    ok "Listen port changed to $new; subscriptions and client nodes have been updated"
}

set_domain() {
    valid_domain "${1:-}" || err "Usage: vpsm domain <domain> (must resolve to this server)"
    if [[ -z $(db_get '.settings.name // ""') ]]; then
        extra_sub_assert_local_name "$1" || err "Domain $1 conflicts with an external proxy name"
    fi
    local db_snap
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg d "$1" '.settings.domain = $d'
    if ! ( caddy_gen && xray_gen_config ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Domain was not changed"
    fi
    if xray_active && { ! xray_restart force || ! svc_settled "$XRAY_SVC"; }; then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Xray failed to start with the new domain; domain was not changed"
    fi
    if ! ( sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Subscriptions could not be regenerated; domain was not changed"
    fi
    if ! caddy_reload; then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Caddy could not reload the new domain; domain was not changed"
    fi
    rm -f "$db_snap"
    ok "Domain changed to $1, Caddy will obtain a certificate for it automatically"
}

set_node_name() {
    local n="$*"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    if [[ -z $n ]]; then
        echo "Node name: $(node_name)"
        echo "Subscription name: $(sub_name)"
        return 0
    fi
    if [[ $n == 0 ]]; then
        n=""
    else
        valid_node_name "$n" || err "Invalid name: 1-64 characters without quotes, backslashes or control characters, and not a Clash policy/group name"
    fi
    local candidate=$n db_snap
    [[ -z $candidate ]] && candidate=$(db_get '.settings.domain')
    extra_sub_assert_local_name "$candidate" || err "Node name $candidate conflicts with an external proxy name"
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$n" '.settings.name = $n'
    if ! ( sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Node name was not changed"
    fi
    rm -f "$db_snap"
    ok "Node name set to $(node_name) (clients pick it up after refreshing)"
}

set_sub_name() {
    local n="$*" db_snap
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    if [[ -z $n ]]; then
        echo "Subscription name: $(sub_name)"
        return 0
    fi
    if [[ $n == 0 ]]; then
        n=""
    else
        valid_node_name "$n" || err "Invalid subscription name"
    fi
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg n "$n" '.settings.sub_name = $n'
    if ! ( sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Subscription name was not changed"
    fi
    rm -f "$db_snap"
    ok "Subscription name set to $(sub_name)"
}

set_key() {
    local pair priv pub key=${1:-} db_snap
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
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg a "$priv" --arg b "$pub" '.settings.private_key = $a | .settings.public_key = $b'
    if ! ( xray_gen_config && { ! xray_active || { xray_restart force && svc_settled "$XRAY_SVC"; }; } && sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "Key pair was not changed"
    fi
    rm -f "$db_snap"
    ok "Key pair updated, public key: $pub (clients just need to refresh their subscription)"
}

set_shortid() {
    local sid=${1:-$(gen_hex 4)} db_snap
    valid_shortid "$sid" || err "shortId must be a hex string of even length between 2 and 16"
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    db_write --arg s "$sid" '.settings.short_ids = [$s]'
    if ! ( xray_gen_config && { ! xray_active || { xray_restart force && svc_settled "$XRAY_SVC"; }; } && sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        db_rollback_runtime
        err "shortId was not changed"
    fi
    rm -f "$db_snap"
    ok "shortId updated to $sid (clients just need to refresh their subscription)"
}

regen_all() {
    xray_gen_config
    [[ -n $XRAY_CONF_CHANGED ]] && xray_active && xray_restart force
    caddy_gen
    sub_regen force || return 1
    caddy_reload || return 1
    fw_refresh || warn "Firewall rules were not reloaded, run: vpsm firewall reload"
    ok "Configs regenerated"
}

edit_rules() {
    if [[ ! -f $CUSTOM_RULES ]]; then
        cat >"$CUSTOM_RULES" <<'EOF'
# Custom Clash rules, one per line, inserted before all built-in rules (highest priority)
# Available policy groups: Proxy / AI / Google / Steam / Final / DIRECT / REJECT
# Examples:
# DOMAIN-SUFFIX,example.com,Proxy
# DOMAIN-SUFFIX,openai.com,AI
# DOMAIN-SUFFIX,googleapis.cn,Google
# IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
EOF
    fi
    "${EDITOR:-vi}" "$CUSTOM_RULES"
    run_locked sub_regen force || return 1
    ok "Subscriptions updated, takes effect after clients refresh"
}
