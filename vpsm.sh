#!/usr/bin/env bash
# vpsm - multi-user VLESS+Reality+Vision node manager (command entry point)
set -o pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=src/core.sh
. "$(dirname "$SELF")/src/core.sh"
for _lib in xray traffic sub caddy user firewall manage; do
    # shellcheck disable=SC1090
    . "$SH_DIR/src/$_lib.sh"
done
unset _lib

pause() { read -r -s -n 1 -p "Press any key to return to the menu..." _ && echo; }

# Read one value in the menu; empty input returns empty
ask() { local v; read -r -p "$1" v; echo "$v"; }

# pick_user [prompt]: list users, then read a username
pick_user() {
    run_locked user_list >&2
    ask "${1:-Username: }"
}

menu() {
    local c n a b
    while true; do
        clear
        cat <<EOF
===== vpsm $VPSM_VERSION =====
 1) Add user            2) Delete user         3) User info/sub
 4) Set traffic quota   5) Set expiry          6) Reset user traffic
 7) Enable/disable user 8) Monthly reset day   9) Set node name
10) Reset sub link     11) Edit routing rules 12) Status
13) Restart services   14) View logs          15) Update
16) Enable BBR         17) Firewall           18) Uninstall
 0) Exit
EOF
        c=$(ask "Choose: ")
        case $c in
            1) n=$(ask "Username: "); a=$(ask "Monthly traffic (e.g. 200G, 0=unlimited) [0]: "); b=$(ask "Expiry (e.g. 30d / 2026-12-31, 0=never) [0]: ")
               run_locked user_add "$n" "${a:-0}" "${b:-0}" ;;
            2) n=$(pick_user); run_locked user_del "$n" ;;
            3) n=$(pick_user "Username for details/subscription (Enter to return): ")
               [[ -n $n ]] && run_locked user_info "$n" ;;
            4) n=$(pick_user); a=$(ask "New monthly traffic (e.g. 200G, 0=unlimited): "); run_locked user_quota "$n" "$a" ;;
            5) n=$(pick_user); a=$(ask "New expiry (2026-12-31 / 30d / +30d / 0): "); run_locked user_expire "$n" "$a" ;;
            6) n=$(pick_user); run_locked user_reset "$n" ;;
            7) n=$(pick_user); a=$(ask "Enable (e) or disable (d)? [e/d]: ")
               if [[ $a == d ]]; then run_locked user_disable "$n"; else run_locked user_enable "$n"; fi ;;
            8) a=$(ask "Monthly reset day (1-28): "); run_locked set_reset_day "$a" ;;
            9) run_locked set_node_name
               a=$(ask "New node/subscription name (0 = use the domain, Enter to return): ")
               [[ -n $a ]] || continue
               run_locked set_node_name "$a" ;;
            10) n=$(pick_user); run_locked user_token "$n" ;;
            11) (edit_rules) ;;
            12) (show_status) ;;
            13) run_locked svc_restart all ;;
            14) a=$(ask "Which log [xray/caddy/sync] (Ctrl+C to exit): "); (show_log "${a:-xray}") ;;
            15) run_locked update_cmd all ;;
            16) (enable_bbr) ;;
            17) run_locked firewall_cmd status
                a=$(ask "Action [on/off/allow/deny, Enter to return]: ")
                case $a in
                    on | off) run_locked firewall_cmd "$a" ;;
                    allow | deny) b=$(ask "Port (e.g. 8080, 53/udp, 10000-20000/udp): "); run_locked firewall_cmd "$a" "$b" ;;
                    *) continue ;;
                esac ;;
            18) run_locked do_uninstall; [[ -f $DB ]] || exit 0 ;;
            0 | q) exit 0 ;;
            *) continue ;;
        esac
        pause
    done
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
        a | add) run_locked user_add "$@" ;;
        d | del | rm) run_locked user_del "$@" ;;
        l | ls | list) run_locked user_list ;;
        i | info) run_locked user_info "$@" ;;
        sub | link) run_locked user_sub "$@" ;;
        url) run_locked user_url "$@" ;;
        qr) run_locked user_qr "$@" ;;
        quota) run_locked user_quota "$@" ;;
        expire) run_locked user_expire "$@" ;;
        reset) run_locked user_reset "$@" ;;
        enable) run_locked user_enable "$@" ;;
        disable) run_locked user_disable "$@" ;;
        token) run_locked user_token "$@" ;;
        reset-day | resetday) run_locked set_reset_day "$@" ;;
        port) run_locked set_port "$@" ;;
        domain | sni) run_locked set_domain "$@" ;;
        name) run_locked set_node_name "$@" ;;
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
        bbr) enable_bbr ;;
        # reload/flush are run by vpsm-firewall.service, which locked commands stop via systemctl: taking the lock would deadlock
        firewall | fw)
            case ${1:-} in
                reload | apply | flush) firewall_cmd "$@" ;;
                *) run_locked firewall_cmd "$@" ;;
            esac ;;
        uninstall | un) run_locked do_uninstall ;;
        *) echo "Unknown command: $cmd" >&2; show_help; return 1 ;;
    esac
}

main "$@"
