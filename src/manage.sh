#!/usr/bin/env bash
# vpsm - service management / update / BBR / uninstall / help

# Install the systemd units; the names of units whose content changed are stored in UNITS_CHANGED
install_units() {
    UNITS_CHANGED=""
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    local u dst new
    for u in vpsm-xray.service vpsm-caddy.service vpsm-traffic.service vpsm-traffic.timer vpsm-firewall.service; do
        dst=/etc/systemd/system/$u
        new=$(sed "s#@ROOT@#$ROOT#g" "$SH_DIR/systemd/$u")
        [[ -f $dst && $(<"$dst") == "$new" ]] && continue
        printf '%s\n' "$new" >"$dst"
        UNITS_CHANGED+=" $u"
    done
    systemctl daemon-reload
}

# Restart running services whose unit changed (the firewall unit only matters at boot)
restart_changed_units() {
    local u
    for u in $UNITS_CHANGED; do
        case $u in
            vpsm-xray.service) xray_active && xray_restart && ok "Restarted $XRAY_SVC (unit updated)" ;;
            vpsm-caddy.service) svc_active "$CADDY_SVC" && svc restart "$CADDY_SVC" && ok "Restarted $CADDY_SVC (unit updated)" ;;
            vpsm-traffic.timer) svc try-restart vpsm-traffic.timer ;;
        esac
    done
    return 0
}

# Map xray|caddy|all (default all) to a list of service names
svc_targets() {
    case ${1:-all} in
        xray) echo "$XRAY_SVC" ;;
        caddy) echo "$CADDY_SVC" ;;
        all | "") echo "$XRAY_SVC $CADDY_SVC" ;;
        *) err "Unknown target: $1 (choose xray | caddy | all)" ;;
    esac
}

svc_start() {
    local s list
    list=$(svc_targets "${1:-}") || return 1
    for s in $list; do svc start "$s" && ok "Started $s"; done
}

svc_stop() {
    local s list
    list=$(svc_targets "${1:-}") || return 1
    [[ ${1:-all} != caddy ]] && xray_active && traffic_pull
    for s in $list; do svc stop "$s" && ok "Stopped $s"; done
}

svc_restart() {
    local t=${1:-all}
    svc_targets "$t" >/dev/null
    if [[ $t != caddy ]]; then
        xray_gen_config
        xray_restart
        ok "Restarted $XRAY_SVC"
    fi
    if [[ $t != xray ]]; then
        caddy_gen
        svc restart "$CADDY_SVC"
        ok "Restarted $CADDY_SVC"
    fi
}

show_status() {
    local s state pid rss ver
    for s in "$XRAY_SVC" "$CADDY_SVC"; do
        state=$(systemctl is-active "$s" 2>/dev/null)
        rss="-"
        if [[ $state == active ]]; then
            pid=$(systemctl show -p MainPID --value "$s")
            [[ $pid =~ ^[0-9]+$ && $pid -gt 0 ]] &&
                rss="$(($(ps -o rss= -p "$pid" | tr -d ' ') / 1024)) MB"
        fi
        printf '%-14s %-10s memory: %s\n' "$s" "$state" "$rss"
    done
    ver=$(cat "$BIN_DIR/xray.version" 2>/dev/null)
    echo "Xray version:  ${ver:-unknown}"
    echo "Caddy version: $(cat "$BIN_DIR/caddy.version" 2>/dev/null || echo unknown)"
    echo "Domain/port:   $(db_get '.settings.domain'):$(db_get '.settings.port')"
    echo "Node name:     $(node_name)"
    echo "Users:         $(db_get '.users | length') ($(db_get '[.users[] | select(.enabled)] | length') enabled)"
    echo "Reset day:     day $(db_get '.settings.reset_day') of each month (next: $(next_reset_date))"
    echo "Sync timer:    $(systemctl is-active vpsm-traffic.timer 2>/dev/null)"
    echo "Firewall:      $(fw_state_text)"
    echo "API guard:     $(fw_guard_text)"
}

show_log() {
    case ${1:-xray} in
        xray) journalctl -u "$XRAY_SVC" -n 100 --no-pager -f ;;
        caddy) journalctl -u "$CADDY_SVC" -n 100 --no-pager -f ;;
        sync | traffic) journalctl -u vpsm-traffic.service -n 100 --no-pager ;;
        *) err "Usage: vpsm log [xray|caddy|sync]" ;;
    esac
}

# update_target_tag <owner/repo> <installed version file> [tag]: prints the tag to install, or nothing when
# no tag was given and the latest release is already installed (a restart would drop every connection)
update_target_tag() {
    local tag=${3:-}
    [[ -n $tag ]] && { echo "$tag"; return 0; }
    tag=$(github_latest "$1")
    [[ -n $tag ]] || err "Failed to get the latest version of $1"
    [[ $tag == "$(cat "$2" 2>/dev/null)" ]] || echo "$tag"
}

# install_xray/install_caddy keep the previous version as *.old: roll back to it if the new one does not stay up
update_core() {
    local files=(xray geoip.dat xray.version) tag new
    tag=$(update_target_tag XTLS/Xray-core "$BIN_DIR/xray.version" "${1:-}") || return 1
    [[ -n $tag ]] || { ok "Xray is already the latest version ($(cat "$BIN_DIR/xray.version"))"; return 0; }
    xray_active && traffic_pull
    install_xray "$tag"
    new=$(cat "$BIN_DIR/xray.version")
    if (xray_gen_config) && svc restart "$XRAY_SVC" && svc_settled "$XRAY_SVC"; then
        bin_drop_backup "${files[@]}"
        ok "Xray updated to $new"
        return 0
    fi
    bin_restore "${files[@]}" ||
        err "Xray $new failed to start and there is no previous version to roll back to, check: journalctl -u $XRAY_SVC -n 50"
    xray_restart
    warn "Xray $new failed to start, rolled back to $(cat "$BIN_DIR/xray.version"); check: journalctl -u $XRAY_SVC -n 50"
    return 1
}

update_caddy() {
    local files=(caddy caddy.version) tag new
    tag=$(update_target_tag caddyserver/caddy "$BIN_DIR/caddy.version" "${1:-}") || return 1
    [[ -n $tag ]] || { ok "Caddy is already the latest version ($(cat "$BIN_DIR/caddy.version"))"; return 0; }
    install_caddy "$tag"
    new=$(cat "$BIN_DIR/caddy.version")
    if svc restart "$CADDY_SVC" && svc_settled "$CADDY_SVC"; then
        bin_drop_backup "${files[@]}"
        ok "Caddy updated to $new"
        return 0
    fi
    bin_restore "${files[@]}" ||
        err "Caddy $new failed to start and there is no previous version to roll back to, check: journalctl -u $CADDY_SVC -n 50"
    svc restart "$CADDY_SVC"
    warn "Caddy $new failed to start, rolled back to $(cat "$BIN_DIR/caddy.version"); check: journalctl -u $CADDY_SVC -n 50"
    return 1
}

# Re-fetch the scripts from GitHub. $ROOT/repo contains "owner/repo [ref]"
update_sh() {
    local repo ref tmp new
    read -r repo ref <"$ROOT/repo" 2>/dev/null
    [[ -n $repo ]] || err "Script repository not recorded ($ROOT/repo), please re-run install.sh"
    ref=${ref:-main}
    tmp=$(mktemp -d)
    msg "Downloading scripts $repo@$ref ..."
    if ! dl "https://github.com/$repo/archive/$ref.tar.gz" "$tmp/s.tgz" ||
        ! tar -xzf "$tmp/s.tgz" -C "$tmp" --strip-components=1; then
        rm -rf "$tmp"
        err "Failed to download scripts"
    fi
    [[ -f $tmp/vpsm.sh && -d $tmp/src ]] || { rm -rf "$tmp"; err "Downloaded content is incomplete"; }
    # Swap the whole directory via rename so the running script is unaffected
    new="$ROOT/sh.new"
    rm -rf "$new"
    mkdir -p "$new"
    cp -r "$tmp/vpsm.sh" "$tmp/src" "$tmp/templates" "$tmp/systemd" "$new/"
    chmod 755 "$new/vpsm.sh"
    rm -rf "$ROOT/sh.old"
    mv "$ROOT/sh" "$ROOT/sh.old" && mv "$new" "$ROOT/sh"
    rm -rf "$ROOT/sh.old" "$tmp"
    install_units
    restart_changed_units
    # Regenerate with the new scripts so template/Caddyfile changes apply now; they inherit our lock
    VPSM_LOCK_HELD=1 "$ROOT/sh/vpsm.sh" regen ||
        warn "Failed to regenerate configs with the new scripts, run: vpsm regen"
    ok "Scripts updated to $("$ROOT/sh/vpsm.sh" version)"
}

update_cmd() {
    case ${1:-all} in
        core | xray) update_core "${2:-}" ;;
        caddy) update_caddy "${2:-}" ;;
        sh | script) update_sh ;;
        all)
            update_core
            update_caddy
            update_sh
            ;;
        *) err "Usage: vpsm update [core|caddy|sh|all] [version]" ;;
    esac
}

enable_bbr() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ $cc == bbr ]]; then
        ok "BBR is already enabled"
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        err "The current kernel does not support BBR (Linux 4.9+ required)"
    fi
    cat >/etc/sysctl.d/99-vpsm-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p /etc/sysctl.d/99-vpsm-bbr.conf >/dev/null
    ok "BBR enabled"
}

do_uninstall() {
    local ans
    read -r -p "Uninstall vpsm (deletes all config and user data under $ROOT)? [y/N] " ans
    [[ $ans == y || $ans == Y ]] || { msg "Cancelled"; return 0; }
    svc disable --now vpsm-traffic.timer 2>/dev/null
    svc disable --now "$XRAY_SVC" 2>/dev/null
    svc disable --now "$CADDY_SVC" 2>/dev/null
    svc disable --now "$FW_SVC" 2>/dev/null
    fw_flush_all
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        rm -f /etc/systemd/system/vpsm-{xray,caddy,traffic,firewall}.service /etc/systemd/system/vpsm-traffic.timer
        rm -f /usr/local/bin/vpsm /etc/sysctl.d/99-vpsm-bbr.conf
        systemctl daemon-reload
        userdel "$SVC_USER" 2>/dev/null
    fi
    # This script lives in $ROOT/sh and has already been read by bash, so deleting it is safe
    rm -rf "$ROOT"
    ok "Uninstalled"
}

show_help() {
    cat <<EOF
vpsm $VPSM_VERSION - multi-user VLESS+Reality+Vision node manager (Xray + Caddy)
Usage: vpsm [command] [args]   (no command opens the interactive menu)

Users:
   add <name> [quota] [expiry]   Add a user. Quota e.g. 200G/500M/0(unlimited), expiry e.g. 30d/6m/2026-12-31/0(never)
   del <name>                    Delete a user
   list                          List users (traffic/expiry/status)
   info <name>                   User details and subscription URL
   sub <name>                    Show the Clash subscription URL
   qr <name>                     Subscription URL as a QR code (requires qrencode)
   url <name>                    Single-node vless:// share link
   quota <name> <traffic>        Set the monthly traffic quota (0=unlimited)
   expire <name> <date>          Set expiry: 2026-12-31 | 30d | +30d(extend) | 0
   reset <name|all>              Reset used traffic to zero
   enable|disable <name>         Manually enable/disable
   token <name>                  Reset the subscription URL (old URL stops working)

Global settings:
   reset-day <1-28>              Monthly traffic reset day shared by all users
   port <port>                   Xray listen port (default 443)
   domain <domain>               Change the domain (also the Reality SNI)
   name [name|0]                 Show/set the node name = subscription name shown in clients (0=use the domain)
   key [private_key|-]           Regenerate/set the Reality key pair (- reads the private key from stdin)
   shortid [hex]                 Regenerate/set the shortId
   rules                         Edit custom Clash routing rules
   regen                         Regenerate Xray/Caddy configs and all subscriptions

Firewall (iptables, allows only SSH / 80 / Xray port + custom ports, rejects all other inbound):
   firewall [status]             Show firewall state and allowed ports
   firewall on|off               Enable/disable the firewall (restored automatically on boot)
   firewall allow <port>[/proto] Allow an extra inbound port, e.g. 8080, 53/udp, 10000-20000/udp
   firewall deny <port>[/proto]  Remove a custom allowed port
   firewall reload               Re-apply the rules
   (Independently of on/off, an always-on rule lets only root reach the Xray API port $API_PORT)

Operations:
   sync                          Sync traffic and check quota/expiry now (the timer runs this every minute)
   status                        Service status
   start|stop|restart [xray|caddy|all]
   log [xray|caddy|sync]         View logs
   update [core|caddy|sh|all]    Update Xray / Caddy / these scripts (skipped when already the latest)
   update core|caddy <version>   Install a specific Xray / Caddy version (e.g. v26.3.27)
   bbr                           Enable BBR
   uninstall                     Uninstall
   v, version                    Show version
   h, help                       Show this help
EOF
}
