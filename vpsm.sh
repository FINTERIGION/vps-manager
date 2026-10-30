#!/usr/bin/env bash
# vpsm - fixed numeric CLI for a single-node multi-user VLESS+Reality+Vision server
set -o pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=src/core.sh
. "$(dirname "$SELF")/src/core.sh"
for _lib in xray traffic extra_sub sub caddy user firewall security manage; do
    # shellcheck disable=SC1090
    . "$SH_DIR/src/$_lib.sh"
done
unset _lib

pause() { read -r -s -n 1 -p "Press any key to return..." _ && echo; }
ask() { local v; read -r -p "$1" v; printf '%s\n' "$v"; }
cls() { [[ -t 1 ]] && clear; }
pick_user() {
    run_locked user_list >&2
    ask "${1:-Username: }"
}

firewall_menu() {
    local a p
    while true; do
        cls
        echo "=== iptables Inbound Rules ==="
        run_locked firewall_cmd status
        echo
        echo "1) Enable firewall"
        echo "2) Disable firewall"
        echo "3) Allow a port"
        echo "4) Remove a custom allowed port"
        echo "5) Reload rules"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1) run_locked firewall_cmd on ;;
            2) run_locked firewall_cmd off ;;
            3) p=$(ask "Port (e.g. 8080, 53/udp, 10000-20000/udp): "); run_locked firewall_cmd allow "$p" ;;
            4) p=$(ask "Port to remove: "); run_locked firewall_cmd deny "$p" ;;
            5) run_locked firewall_cmd reload ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

swap_menu() {
    local a size
    while true; do
        cls
        echo "=== Swap ==="
        swap_status
        echo
        echo "1) Create or resize managed swap"
        echo "2) Disable managed swap"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1) size=$(ask "Swap size (e.g. 1G / 512M): "); run_locked swap_set "$size" ;;
            2) run_locked swap_off ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

node_settings_menu() {
    local a value
    while true; do
        cls
        echo "=== Node Settings ==="
        show_node_info
        echo
        echo "1) Set node name"
        echo "2) Set subscription profile name"
        echo "3) Change domain"
        echo "4) Change Xray port"
        echo "5) Set global expiry"
        echo "6) Set monthly reset day"
        echo "7) Rotate Reality key pair"
        echo "8) Change Reality shortId"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1) value=$(ask "Node name (0 = domain): "); run_locked set_node_name "$value" ;;
            2) value=$(ask "Profile name (0 = follow node name): "); run_locked set_sub_name "$value" ;;
            3) value=$(ask "Domain: "); run_locked set_domain "$value" ;;
            4) value=$(ask "Xray port: "); run_locked set_port "$value" ;;
            5) value=$(ask "Global expiry (YYYY-MM-DD / 30d / +30d / 0): "); run_locked set_expire "$value" ;;
            6) value=$(ask "Monthly reset day (1-28): "); run_locked set_reset_day "$value" ;;
            7) run_locked set_key ;;
            8) value=$(ask "shortId (empty = random): "); run_locked set_shortid "$value" ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

users_menu() {
    local a name quota
    while true; do
        cls
        echo "=== Users ==="
        run_locked user_list
        echo
        echo "1) Add user"
        echo "2) Delete user"
        echo "3) Show user details"
        echo "4) Set user quota"
        echo "5) Reset user traffic"
        echo "6) Enable user"
        echo "7) Disable user"
        echo "8) Rotate subscription token"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1)
                name=$(ask "Username: ")
                quota=$(ask "Monthly traffic (e.g. 200G, 0=unlimited) [0]: ")
                run_locked user_add "$name" "${quota:-0}"
                ;;
            2) name=$(pick_user); [[ -n $name ]] && run_locked user_del "$name" ;;
            3) name=$(pick_user); [[ -n $name ]] && run_locked user_info "$name" ;;
            4)
                name=$(pick_user); quota=$(ask "New quota (e.g. 200G, 0=unlimited): ")
                [[ -n $name ]] && run_locked user_quota "$name" "$quota"
                ;;
            5) name=$(pick_user "Username (or all): "); [[ -n $name ]] && run_locked user_reset "$name" ;;
            6) name=$(pick_user); [[ -n $name ]] && run_locked user_enable "$name" ;;
            7) name=$(pick_user); [[ -n $name ]] && run_locked user_disable "$name" ;;
            8) name=$(pick_user); [[ -n $name ]] && run_locked user_token "$name" ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

external_menu() {
    local a alias url filter
    while true; do
        cls
        echo "=== External Clash/Mihomo Subscriptions ==="
        run_locked extra_sub_list
        echo
        echo "1) Attach a subscription (shared by every user)"
        echo "2) Detach a subscription"
        echo "3) Change a subscription's node filter"
        echo "4) Refresh one subscription"
        echo "5) Refresh all subscriptions"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1)
                alias=$(ask "Alias: "); url=$(ask "Clash/Mihomo URL: ")
                filter=$(ask "Node filter regex (empty = all nodes): ")
                run_locked extra_sub_attach "$alias" "$url" "$filter"
                ;;
            2) alias=$(ask "Alias: "); run_locked extra_sub_detach "$alias" ;;
            3)
                alias=$(ask "Alias: "); filter=$(ask "Filter regex (0 = clear): ")
                run_locked extra_sub_set_filter "$alias" "$filter"
                ;;
            4) alias=$(ask "Alias: "); run_locked extra_sub_refresh "$alias" force ;;
            5) run_locked extra_sub_refresh all force ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

subscription_menu() {
    local name answer
    name=$(pick_user)
    [[ -n $name ]] || return 0
    echo
    echo "Clash subscription: $(sub_url "$name")"
    echo "VLESS share link:   $(vless_share_url "$name")"
    echo
    answer=$(ask "Show subscription QR code? [y/N]: ")
    [[ ${answer,,} == y ]] && user_qr "$name"
}

services_menu() {
    local a
    while true; do
        cls
        echo "=== Services ==="
        show_status
        echo
        echo "1) Restart Xray and Caddy"
        echo "2) Restart Xray"
        echo "3) Restart Caddy"
        echo "4) Follow Xray log"
        echo "5) Follow Caddy log"
        echo "6) Show traffic sync log"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1) run_locked svc_restart all ;;
            2) run_locked svc_restart xray ;;
            3) run_locked svc_restart caddy ;;
            4) show_log xray ;;
            5) show_log caddy ;;
            6) show_log sync ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

core_update_menu() {
    local a
    cls
    echo "=== Update Xray / Caddy ==="
    echo "1) Update Xray"
    echo "2) Update Caddy"
    echo "3) Update both"
    echo "0) Back"
    a=$(ask "Choose: ")
    case $a in
        1) run_locked update_core ;;
        2) run_locked update_caddy ;;
        3) run_locked update_core; run_locked update_caddy ;;
        0 | "") return 0 ;;
        *) return 0 ;;
    esac
}

menu_width() {
    local line width=0
    for line in "$@"; do
        ((${#line} > width)) && width=${#line}
    done
    ((width < 50)) && width=50
    printf '%s\n' "$width"
}

menu_center() {
    local text=$1 width=$2 pad left right
    pad=$((width - ${#text} - 2))
    ((pad < 2)) && pad=2
    left=$((pad / 2))
    right=$((pad - left))
    printf '%s %s %s\n' "$(printf '%*s' "$left" '' | tr ' ' '=')" "$text" \
        "$(printf '%*s' "$right" '' | tr ' ' '=')"
}

menu_banner() { menu_center "vpsm $VPSM_VERSION" "$1"; }

menu() {
    local choice width
    declare -a security=(
        " 1) Change SSH port"
        " 2) Manage iptables inbound rules"
        " 3) Configure Swap"
    )
    declare -a node=(
        " 4) Show node information"
        " 5) Configure node settings"
        " 6) Manage users"
        " 7) Manage external subscriptions"
        " 8) Show subscription links and QR codes"
        " 9) Edit custom Clash rules"
    )
    declare -a system=(
        "10) Service status and logs"
        "11) Update Xray / Caddy"
        "12) Update scripts"
        "13) Update system kernel"
        "14) Enable BBR"
        "15) Sync traffic and status now"
        "16) Uninstall vpsm"
        " 0) Exit"
    )
    width=$(menu_width "${security[@]}" "${node[@]}" "${system[@]}")
    while true; do
        cls
        menu_banner "$width"
        menu_center Security "$width"
        printf '%s\n' "${security[@]}"
        menu_center Node "$width"
        printf '%s\n' "${node[@]}"
        menu_center System "$width"
        printf '%s\n' "${system[@]}"
        printf '%s\n' "$(printf '%*s' "$width" '' | tr ' ' '=')"
        choice=$(ask "Choose: ")
        case $choice in
            1) choice=$(ask "New SSH port: "); run_locked ssh_change_port "$choice" ;;
            2) firewall_menu; continue ;;
            3) swap_menu; continue ;;
            4) show_node_info ;;
            5) node_settings_menu; continue ;;
            6) users_menu; continue ;;
            7) external_menu; continue ;;
            8) subscription_menu ;;
            9) edit_rules ;;
            10) services_menu; continue ;;
            11) core_update_menu; continue ;;
            12) run_locked update_sh && exec "$ROOT/sh/vpsm.sh" ;;
            13) run_locked update_kernel ;;
            14) enable_bbr ;;
            15) run_locked sync_all; ok "Traffic and status synchronized" ;;
            16) run_locked do_uninstall; [[ -f $DB ]] || exit 0 ;;
            0 | q | Q) exit 0 ;;
            *) continue ;;
        esac
        pause
    done
}

user_cmd() {
    case ${1:-list} in
        a | add) shift; user_add "$@" ;;
        d | del | rm) shift; user_del "$@" ;;
        l | ls | list | "") user_list ;;
        i | info) shift; user_info "$@" ;;
        quota) shift; user_quota "$@" ;;
        reset) shift; user_reset "$@" ;;
        enable) shift; user_enable "$@" ;;
        disable) shift; user_disable "$@" ;;
        token) shift; user_token "$@" ;;
        *) err "Usage: vpsm user [add|del|list|info|quota|reset|enable|disable|token]" ;;
    esac
}

sub_cmd() {
    case ${1:-} in
        name) shift; set_sub_name "$*" ;;
        qr) shift; user_qr "$@" ;;
        url) shift; user_url "$@" ;;
        link) shift; user_sub "$@" ;;
        refresh) shift; extra_sub_refresh "${1:-all}" force ;;
        filter) shift; extra_sub_set_filter "$@" ;;
        "") err "Usage: vpsm sub <user> | vpsm sub [qr|url|name|refresh|filter]" ;;
        *) user_sub "$1" ;;
    esac
}

node_cmd() {
    case ${1:-} in
        port) shift; set_port "$@" ;;
        domain | sni) shift; set_domain "$@" ;;
        key) shift; set_key "$@" ;;
        shortid) shift; set_shortid "$@" ;;
        name) shift; set_node_name "$*" ;;
        "") show_node_info ;;
        *) set_node_name "$*" ;;
    esac
}

main() {
    local cmd=${1:-}
    [[ $# -gt 0 ]] && shift
    case $cmd in
        v | version | -v | --version) echo "vpsm $VPSM_VERSION"; return 0 ;;
        h | help | -h | --help) show_help; return 0 ;;
    esac
    need_root
    need_installed
    case $cmd in
        "") menu ;;
        user) run_locked user_cmd "$@" ;;
        sub | link) run_locked sub_cmd "$@" ;;
        node) run_locked node_cmd "$@" ;;
        a | add) run_locked user_add "$@" ;;
        d | del | rm) run_locked user_del "$@" ;;
        l | ls | list) run_locked user_list ;;
        i | info) run_locked user_info "$@" ;;
        url) run_locked user_url "$@" ;;
        qr) run_locked user_qr "$@" ;;
        quota) run_locked user_quota "$@" ;;
        expire) run_locked set_expire "$@" ;;
        reset) run_locked user_reset "$@" ;;
        enable) run_locked user_enable "$@" ;;
        disable) run_locked user_disable "$@" ;;
        token) run_locked user_token "$@" ;;
        attach) run_locked extra_sub_attach "$@" ;;
        detach) run_locked extra_sub_detach "$@" ;;
        filter) run_locked extra_sub_set_filter "$@" ;;
        reset-day | resetday) run_locked set_reset_day "$@" ;;
        port) run_locked set_port "$@" ;;
        domain | sni) run_locked set_domain "$@" ;;
        name) run_locked set_node_name "$*" ;;
        key) run_locked set_key "$@" ;;
        shortid) run_locked set_shortid "$@" ;;
        rules) edit_rules ;;
        regen) run_locked regen_all ;;
        sync) run_locked sync_all ;;
        status | s) show_status ;;
        start) run_locked svc_start "$@" ;;
        stop) run_locked svc_stop "$@" ;;
        restart) run_locked svc_restart "$@" ;;
        log) show_log "$@" ;;
        update | u) run_locked update_cmd "$@" ;;
        kernel) run_locked update_kernel "$@" ;;
        bbr) enable_bbr ;;
        ssh-port) run_locked ssh_change_port "$@" ;;
        swap) run_locked swap_cmd "$@" ;;
        firewall | fw)
            case ${1:-} in
                reload | apply | flush) firewall_cmd "$@" ;;
                *) run_locked firewall_cmd "$@" ;;
            esac ;;
        uninstall | un) run_locked do_uninstall "$@" ;;
        *) echo "Unknown command: $cmd" >&2; show_help; return 1 ;;
    esac
}

main "$@"
