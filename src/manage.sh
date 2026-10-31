#!/usr/bin/env bash
# vpsm - services, updates, kernel upgrades, BBR, uninstall and help

install_units() {
    UNITS_CHANGED=""
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    local units=(vpsm-xray.service vpsm-caddy.service vpsm-traffic.service vpsm-traffic.timer vpsm-firewall.service)
    local u dst new f base
    for u in "${units[@]}"; do
        dst=/etc/systemd/system/$u
        new=$(sed "s#@ROOT@#$ROOT#g" "$SH_DIR/systemd/$u")
        [[ -f $dst && $(<"$dst") == "$new" ]] && continue
        printf '%s\n' "$new" >"$dst"
        UNITS_CHANGED+=" $u"
    done
    for f in /etc/systemd/system/vpsm-*.service /etc/systemd/system/vpsm-*.timer; do
        [[ -e $f ]] || continue
        base=${f##*/}
        [[ " ${units[*]} " == *" $base "* ]] && continue
        grep -qF 'vpsm.sh' "$f" 2>/dev/null || continue
        systemctl disable --now "$base" >/dev/null 2>&1 || true
        rm -f "$f"
        UNITS_CHANGED+=" $base"
    done
    systemctl daemon-reload
}

restart_changed_units() {
    local u
    for u in $UNITS_CHANGED; do
        case $u in
            vpsm-xray.service) xray_active && xray_restart force && ok "Restarted $XRAY_SVC (unit updated)" ;;
            vpsm-caddy.service) svc_active "$CADDY_SVC" && svc restart "$CADDY_SVC" && ok "Restarted $CADDY_SVC (unit updated)" ;;
            vpsm-traffic.timer) svc try-restart vpsm-traffic.timer ;;
            vpsm-firewall.service) svc try-restart "$FW_SVC" ;;
        esac
    done
    return 0
}

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
    if [[ ${1:-all} != caddy ]] && xray_active; then
        traffic_pull || traffic_pull || err "Failed to persist Xray traffic, not stopping"
    fi
    for s in $list; do svc stop "$s" && ok "Stopped $s"; done
}
svc_restart() {
    local t=${1:-all}
    svc_targets "$t" >/dev/null
    if [[ $t != caddy ]]; then
        xray_gen_config
        xray_restart force || err "Failed to restart Xray, check: journalctl -u $XRAY_SVC -n 50"
        svc_settled "$XRAY_SVC" || err "Xray failed to stay up after restart, check: journalctl -u $XRAY_SVC -n 50"
        ok "Restarted $XRAY_SVC"
    fi
    if [[ $t != xray ]]; then
        caddy_gen
        svc restart "$CADDY_SVC"
        svc_settled "$CADDY_SVC" || err "Caddy failed to stay up after restart, check: journalctl -u $CADDY_SVC -n 50"
        ok "Restarted $CADDY_SVC"
    fi
}

show_node_info() {
    local expire
    expire=$(db_get '.settings.expire // ""')
    echo "Node name:       $(node_name)"
    echo "Profile name:    $(sub_name)"
    echo "Domain/port:     $(db_get '.settings.domain'):$(db_get '.settings.port')"
    echo "Reality:         configured (public key and shortId are available in client links)"
    echo "Users:           $(db_get '.users | length') ($(db_get '[.users[] | select(.enabled)] | length') enabled)"
    echo "Global expiry:   ${expire:-never}"
    echo "Next reset:      $(next_reset_date)"
    echo "Xray service:    $(systemctl is-active "$XRAY_SVC" 2>/dev/null || echo unknown)"
    echo "Caddy service:   $(systemctl is-active "$CADDY_SVC" 2>/dev/null || echo unknown)"
}

show_status() {
    local s state pid rss ver expire
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
    expire=$(db_get '.settings.expire // ""')
    echo "Xray version:  ${ver:-unknown}"
    echo "Caddy version: $(cat "$BIN_DIR/caddy.version" 2>/dev/null || echo unknown)"
    echo "Domain/port:   $(db_get '.settings.domain'):$(db_get '.settings.port')"
    echo "Node name:     $(node_name)"
    echo "Users:         $(db_get '.users | length') ($(db_get '[.users[] | select(.enabled)] | length') enabled)"
    echo "Global expiry: ${expire:-never}"
    echo "Reset day:     day $(db_get '.settings.reset_day') of each month (next: $(next_reset_date))"
    echo "Sync timer:    $(systemctl is-active vpsm-traffic.timer 2>/dev/null)"
    echo "Firewall:      $(fw_state_text)"
    echo "API guard:     $(fw_guard_text)"
    swap_status
}

show_log() {
    case ${1:-xray} in
        xray) journalctl -u "$XRAY_SVC" -n 100 --no-pager -f ;;
        caddy) journalctl -u "$CADDY_SVC" -n 100 --no-pager -f ;;
        sync | traffic) journalctl -u vpsm-traffic.service -n 100 --no-pager ;;
        *) err "Usage: vpsm log [xray|caddy|sync]" ;;
    esac
}

update_target_tag() {
    local tag=${3:-}
    [[ -n $tag ]] && { echo "$tag"; return 0; }
    tag=$(github_latest "$1")
    [[ -n $tag ]] || err "Failed to get the latest version of $1"
    [[ $tag == "$(cat "$2" 2>/dev/null)" ]] || echo "$tag"
}

update_core() {
    local files=(xray geoip.dat xray.version) tag new
    tag=$(update_target_tag XTLS/Xray-core "$BIN_DIR/xray.version" "${1:-}") || return 1
    [[ -n $tag ]] || { ok "Xray is already the latest version ($(cat "$BIN_DIR/xray.version"))"; return 0; }
    if xray_active; then
        traffic_pull || traffic_pull || err "Failed to persist traffic, Xray not updated"
    fi
    install_xray "$tag"
    new=$(cat "$BIN_DIR/xray.version")
    if (xray_gen_config) && xray_restart force && svc_settled "$XRAY_SVC"; then
        bin_drop_backup "${files[@]}"
        # REALITY ML-KEM support follows the installed Xray version, so refresh
        # subscriptions right away instead of waiting for the periodic rebuild.
        sub_regen force || warn "Subscriptions were not regenerated, run: vpsm regen"
        ok "Xray updated to $new"
        return 0
    fi
    bin_restore "${files[@]}" || err "Xray $new failed to start and there is no previous version to roll back to"
    xray_restart force
    warn "Xray $new failed to start, rolled back to $(cat "$BIN_DIR/xray.version")"
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
    bin_restore "${files[@]}" || err "Caddy $new failed to start and there is no previous version to roll back to"
    svc restart "$CADDY_SVC"
    warn "Caddy $new failed to start, rolled back to $(cat "$BIN_DIR/caddy.version")"
    return 1
}

update_sh() {
    local arg=${1:-} repo ref url label tmp new ver
    read -r repo ref <"$ROOT/repo" 2>/dev/null
    [[ -n $repo ]] || err "Script repository not recorded ($ROOT/repo), please re-run install.sh"
    [[ -n $arg ]] && ref=$arg
    ref=${ref:-main}
    [[ $ref == latest ]] && ref=main
    url="https://github.com/$repo/archive/$ref.tar.gz"
    label="$repo@$ref"
    tmp=$(mktemp -d)
    msg "Downloading scripts $label ..."
    if ! dl "$url" "$tmp/s.tgz" || ! tar -xzf "$tmp/s.tgz" -C "$tmp" --strip-components=1; then
        rm -rf "$tmp"
        err "Failed to download scripts"
    fi
    [[ -f $tmp/vpsm.sh && -d $tmp/src && -d $tmp/templates && -d $tmp/systemd ]] ||
        { rm -rf "$tmp"; err "Downloaded content is incomplete"; }
    new="$ROOT/sh.new"
    rm -rf "$new"
    mkdir -p "$new"
    cp -r "$tmp/vpsm.sh" "$tmp/src" "$tmp/templates" "$tmp/systemd" "$new/" ||
        { rm -rf "$new" "$tmp"; err "Failed to stage new scripts"; }
    chmod 755 "$new/vpsm.sh"
    rm -rf "$tmp" "$ROOT/sh.old"
    mv "$ROOT/sh" "$ROOT/sh.old" || { rm -rf "$new"; err "Failed to replace scripts"; }
    if ! mv "$new" "$ROOT/sh"; then
        mv "$ROOT/sh.old" "$ROOT/sh"
        rm -rf "$new"
        err "Failed to replace scripts, previous version restored"
    fi
    install_units
    restart_changed_units
    if VPSM_LOCK_HELD=1 "$ROOT/sh/vpsm.sh" regen; then
        [[ -n $arg ]] && echo "$repo $ref" >"$ROOT/repo"
        rm -rf "$ROOT/sh.old"
        ver=$("$ROOT/sh/vpsm.sh" version)
        ok "Scripts updated to $ver"
    else
        warn "Failed to regenerate configs with the new scripts, restoring previous version"
        rm -rf "$ROOT/sh"
        mv "$ROOT/sh.old" "$ROOT/sh" || err "Failed to restore previous scripts"
        install_units
        restart_changed_units
        warn "Previous scripts and units restored. Retry with: vpsm update sh"
        return 1
    fi
}

update_cmd() {
    case ${1:-all} in
        core | xray) update_core "${2:-}" ;;
        caddy) update_caddy "${2:-}" ;;
        sh | script) update_sh "${2:-}" ;;
        all)
            local rc=0
            update_core || rc=1
            update_caddy || rc=1
            update_sh || rc=1
            return "$rc"
            ;;
        *) err "Usage: vpsm update [core|caddy|sh|all] [version]" ;;
    esac
}

update_kernel() {
    local yes=${1:-} ans pm
    echo "Running kernel: $(uname -r)"
    if cmd_exists apt-get; then
        pm=apt
    elif cmd_exists dnf; then
        pm=dnf
    elif cmd_exists yum; then
        pm=yum
    else
        err "Unsupported package manager; use your distribution's standard kernel update procedure"
    fi
    msg "Kernel and system packages will be updated from the configured distribution repositories. No reboot will be performed."
    if [[ $yes != -y && $yes != --yes && -t 0 ]]; then
        read -r -p "Continue with the distribution kernel update? [y/N] " ans
        [[ $ans == y || $ans == Y ]] || { msg "Cancelled"; return 0; }
    fi
    [[ -n ${VPSM_NO_SERVICE:-} ]] && { msg "(dry run, skipped) update kernel using $pm"; return 0; }
    case $pm in
        apt)
            apt-get update || err "Failed to refresh package indexes"
            DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::=--force-confold ||
                err "Distribution kernel update failed"
            ;;
        dnf) dnf upgrade -y || err "Distribution kernel update failed" ;;
        yum) yum update -y || err "Distribution kernel update failed" ;;
    esac
    ok "Distribution packages updated successfully"
    if [[ -f /var/run/reboot-required ]]; then
        warn "A reboot is required to use the new kernel. Reboot manually after verifying your out-of-band access"
    else
        msg "Review the installed kernel packages and reboot manually if a newer kernel was installed"
    fi
}

enable_bbr() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && { msg "(dry run, skipped) enable BBR"; return 0; }
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ $cc == bbr ]] && { ok "BBR is already enabled"; return 0; }
    modprobe tcp_bbr 2>/dev/null
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null ||
        err "The current kernel does not support BBR (Linux 4.9+ required)"
    cat >/etc/sysctl.d/99-vpsm-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p /etc/sysctl.d/99-vpsm-bbr.conf >/dev/null
    ok "BBR enabled"
}

do_uninstall() {
    local ans
    if [[ ${1:-} != -y && ${1:-} != --yes && -t 0 ]]; then
        read -r -p "Uninstall vpsm (deletes all config and user data under $ROOT)? [y/N] " ans
        [[ $ans == y || $ans == Y ]] || { msg "Cancelled"; return 0; }
    fi
    svc disable --now vpsm-traffic.timer 2>/dev/null
    svc disable --now "$XRAY_SVC" 2>/dev/null
    svc disable --now "$CADDY_SVC" 2>/dev/null
    svc disable --now "$FW_SVC" 2>/dev/null
    fw_flush_all
    if swap_is_managed; then
        swap_off
    elif swap_is_active; then
        warn "Leaving unmanaged swap $SWAP_FILE active; disable it manually if needed"
    fi
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        msg "(dry run, skipped) remove unit files, $ROOT and the vpsm user"
        ok "Uninstalled (dry run)"
        return 0
    fi
    rm -f /etc/systemd/system/vpsm-{xray,caddy,traffic,firewall}.service /etc/systemd/system/vpsm-traffic.timer
    rm -f /usr/local/bin/vpsm /etc/sysctl.d/99-vpsm-bbr.conf
    systemctl daemon-reload
    userdel "$SVC_USER" 2>/dev/null
    rm -rf "$ROOT"
    ok "Uninstalled"
}

show_help() {
    cat <<EOF
vpsm $VPSM_VERSION - single-node multi-user VLESS+Reality+Vision manager
Usage: vpsm [command] [args]   (no command opens the fixed numeric menu)

Users:
  user add <name> [quota]           Add a user with an individual monthly quota
  user del|list|info [name]         Delete, list or inspect users
  quota <name> <traffic>            Set quota (200G / 500M / 0=unlimited)
  reset <name|all>                  Reset used traffic
  enable|disable <name>             Manually enable or disable a user
  token <name>                      Rotate the user's subscription token

Global policy:
  expire <date|30d|+30d|0>          Set one expiry date shared by every user
  reset-day <1-28>                  Set the monthly reset day shared by every user

Subscriptions:
  sub <name>                        Show the user's Clash subscription URL
  sub qr|url <name>                 Show a QR code or single-node vless:// link
  sub name [name|0]                 Set the subscription profile name
  sub refresh [alias|all]           Refresh shared external subscriptions now
  attach <alias> <url> [filter]     Attach a Clash/Mihomo subscription shared by every user
  detach <alias>                    Detach a shared external subscription
  filter <alias> <regex|0>          Filter a subscription's nodes by a regular expression

Node:
  node [name|0]                     Show or set the local proxy name
  node port|domain|key|shortid      Configure the listener and Reality parameters
  rules                             Edit custom Clash rules
  regen                             Regenerate all configs and subscriptions

Security:
  ssh-port <port>                   Change SSH with socket and rollback handling
  firewall [status|on|off|reload]   Manage the inbound whitelist
  firewall allow|deny <port>[/proto]
  swap <size|off|status>            Configure the dedicated vpsm swap file

System:
  sync                              Sync traffic, quota and expiry now
  status                            Show service and security status
  start|stop|restart [xray|caddy|all]
  log [xray|caddy|sync]
  update [core|caddy|sh|all]        Update components and scripts, not the kernel
  kernel [-y]                       Update distribution packages without rebooting
  bbr                               Enable BBR
  uninstall [-y]
  version | help
EOF
}
