#!/usr/bin/env bash
# vpsm - SSH port and dedicated swap management

SSH_ROOT=${VPSM_SSH_DIR:-/etc/ssh}
SYSTEMD_ROOT=${VPSM_SYSTEMD_DIR:-/etc/systemd/system}
SSH_DROPIN="$SSH_ROOT/sshd_config.d/99-vpsm.conf"
SWAP_FILE=${VPSM_SWAP_FILE:-/var/lib/vpsm/swapfile}
FSTAB=${VPSM_FSTAB:-/etc/fstab}
SWAP_MARKER="$ROOT/.swap_managed"

ssh_socket_unit() {
    local unit
    for unit in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$unit" 2>/dev/null || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            echo "$unit"
            return 0
        fi
    done
    return 1
}

ssh_service_unit() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        echo ssh.service
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        echo sshd.service
    else
        return 1
    fi
}

ssh_includes_dropins() {
    grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSH_ROOT/sshd_config" 2>/dev/null
}

ssh_comment_port_lines() {
    local file=$1 tmp
    grep -qiE '^[[:space:]]*Port[[:space:]]+' "$file" 2>/dev/null || return 0
    tmp=$(mktemp "${file}.vpsm.XXXXXX") || return 1
    if ! awk 'tolower($1) == "port" { print "# vpsm-disabled: " $0; next } { print }' "$file" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

ssh_prepend_port_line() {
    local file=$1 port=$2 tmp
    tmp=$(mktemp "${file}.vpsm.XXXXXX") || return 1
    if ! { printf 'Port %s\n' "$port"; cat "$file"; } >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

ssh_rewrite_ports() {
    local new=$1 f
    ssh_comment_port_lines "$SSH_ROOT/sshd_config" || return 1
    if [[ -d $SSH_ROOT/sshd_config.d ]]; then
        for f in "$SSH_ROOT"/sshd_config.d/*.conf; do
            [[ -e $f ]] || continue
            [[ $f == "$SSH_DROPIN" ]] && continue
            ssh_comment_port_lines "$f" || return 1
        done
    fi
    if ssh_includes_dropins; then
        mkdir -p "${SSH_DROPIN%/*}"
        printf 'Port %s\n' "$new" >"$SSH_DROPIN" || return 1
    else
        rm -f "$SSH_DROPIN"
        ssh_prepend_port_line "$SSH_ROOT/sshd_config" "$new" || return 1
    fi
}

ssh_change_port() {
    local new=${1:-} old unit="" socket_dir backup had_dropin="" had_socket="" had_fw="" configured rewrite_failed="" p
    valid_port "$new" || err "Usage: vpsm ssh-port <1-65535>"
    cmd_exists sshd || err "OpenSSH server (sshd) is not installed"
    [[ -f $SSH_ROOT/sshd_config ]] || err "$SSH_ROOT/sshd_config not found"
    configured=$(fw_sshd_ports | tr '\n' ' ')
    if [[ " $configured " == *" $new "* ]] && [[ $(wc -w <<<"$configured") -eq 1 ]]; then
        msg "SSH is already configured to use only port $new"
        return 0
    fi
    if port_in_use "$new" && [[ " $configured " != *" $new "* ]] && ! fw_ssh_live_ports | grep -qx "$new"; then
        err "Port $new is already in use by another program"
    fi
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        msg "(dry run, skipped) configure SSH port $new with firewall and socket activation handling"
        return 0
    fi

    backup=$(mktemp -d "$ROOT/.ssh.XXXXXX") || err "Failed to create SSH backup directory"
    cp -a "$SSH_ROOT/sshd_config" "$backup/sshd_config" ||
        { rm -rf "$backup"; err "Failed to back up $SSH_ROOT/sshd_config"; }
    if [[ -d $SSH_ROOT/sshd_config.d ]]; then
        cp -a "$SSH_ROOT/sshd_config.d" "$backup/sshd_config.d" ||
            { rm -rf "$backup"; err "Failed to back up $SSH_ROOT/sshd_config.d"; }
    fi
    [[ -f $SSH_DROPIN ]] && cp -p "$SSH_DROPIN" "$backup/dropin" && had_dropin=1
    unit=$(ssh_socket_unit || true)
    if [[ -n $unit ]]; then
        socket_dir="$SYSTEMD_ROOT/$unit.d"
        if [[ -f $socket_dir/override.conf ]]; then
            cp -p "$socket_dir/override.conf" "$backup/socket" ||
                { rm -rf "$backup"; err "Failed to back up $socket_dir/override.conf"; }
            had_socket=1
        fi
    fi

    old=$(fw_sshd_ports | tr '\n' ' ')
    [[ $(db_get --arg s "$new/tcp" '(.settings.firewall.allow // []) | any(.[]; . == $s)') == true ]] && had_fw=1
    msg "Opening the new SSH port in the firewall before restarting SSH ..."
    fw_allow "$new/tcp"
    if fw_enabled && ! fw_apply; then
        [[ -z $had_fw ]] && db_write --arg s "$new/tcp" '.settings.firewall.allow -= [$s]'
        fw_refresh || true
        rm -rf "$backup"
        err "Failed to apply the SSH firewall rule; SSH configuration was not changed"
    fi

    if ! ssh_rewrite_ports "$new"; then
        warn "Failed to rewrite sshd Port directives; restoring the previous configuration"
        rewrite_failed=1
    fi
    if [[ -z $rewrite_failed && -n $unit ]]; then
        mkdir -p "$socket_dir"
        cat >"$socket_dir/override.conf" <<'EOF'
[Socket]
ListenStream=
ListenStream=SSH_PORT_PLACEHOLDER
EOF
        sed -i "s/SSH_PORT_PLACEHOLDER/$new/" "$socket_dir/override.conf"
        systemctl daemon-reload
    fi

    if [[ -z $rewrite_failed ]] && ! sshd -t; then
        warn "OpenSSH rejected the new configuration; restoring the previous port"
    elif [[ -z $rewrite_failed ]]; then
        if [[ -n $unit ]]; then
            systemctl restart "$unit"
        else
            unit=$(ssh_service_unit || true)
            [[ -n $unit ]] && systemctl restart "$unit"
        fi
        sleep 1
        if port_in_use "$new"; then
            [[ -z $had_fw ]] && db_write --arg s "$new/tcp" '.settings.firewall.allow -= [$s]'
            fw_refresh || warn "Failed to refresh firewall rules after the SSH port change"
            rm -rf "$backup"
            ok "SSH port changed to $new; other Port directives were disabled"
            for p in $old; do
                [[ $p == "$new" ]] && continue
                [[ $p == 80 || $p == "$(db_get '.settings.port')" ]] && continue
                fw_allowed | cut -f1 | grep -qx "$p/tcp" &&
                    warn "Port $p/tcp is still allowed; check sshd_config includes or remove it with: vpsm firewall deny $p/tcp"
            done
            warn "Open a new SSH connection to port $new before closing this session, and update your provider firewall"
            return 0
        fi
        warn "SSH did not start listening on port $new; restoring the previous configuration"
    fi

    if [[ -f $backup/sshd_config ]]; then
        cp -p "$backup/sshd_config" "$SSH_ROOT/sshd_config"
    fi
    if [[ -d $backup/sshd_config.d ]]; then
        rm -rf "$SSH_ROOT/sshd_config.d"
        cp -a "$backup/sshd_config.d" "$SSH_ROOT/sshd_config.d"
    fi
    if [[ -n $had_dropin ]]; then
        cp -p "$backup/dropin" "$SSH_DROPIN"
    else
        rm -f "$SSH_DROPIN"
        if [[ ! -d $backup/sshd_config.d ]]; then
            rmdir "${SSH_DROPIN%/*}" 2>/dev/null || true
        fi
    fi
    if [[ -n $unit && $unit == *.socket ]]; then
        if [[ -n $had_socket ]]; then
            cp -p "$backup/socket" "$socket_dir/override.conf"
        else
            rm -f "$socket_dir/override.conf"
        fi
        systemctl daemon-reload
        systemctl restart "$unit" || true
    else
        unit=$(ssh_service_unit || true)
        [[ -n $unit ]] && systemctl restart "$unit" || true
    fi
    [[ -z $had_fw ]] && db_write --arg s "$new/tcp" '.settings.firewall.allow -= [$s]'
    fw_refresh || true
    rm -rf "$backup"
    err "SSH port change rolled back; configured ports remain: $old"
}

swap_is_active() { awk 'NR > 1 {print $1}' /proc/swaps 2>/dev/null | grep -Fxq "$SWAP_FILE"; }
swap_is_managed() {
    [[ -f $SWAP_MARKER ]] && return 0
    [[ -f $FSTAB ]] && awk -v file="$SWAP_FILE" '$1 == file {found=1} END {exit !found}' "$FSTAB"
}

swap_status() {
    echo "Managed swap file: $SWAP_FILE"
    if swap_is_active; then
        awk -v file="$SWAP_FILE" 'NR == 1 || $1 == file {print}' /proc/swaps
    elif [[ -e $SWAP_FILE ]]; then
        echo "Status: configured but not active"
    else
        echo "Status: not configured"
    fi
    echo "All active swap areas:"
    cat /proc/swaps 2>/dev/null || true
}

swap_fstab_update() {
    local enable=$1 tmp
    [[ -f $FSTAB ]] || : >"$FSTAB"
    tmp=$(mktemp "${FSTAB}.vpsm.XXXXXX") || return 1
    awk -v file="$SWAP_FILE" '$1 != file' "$FSTAB" >"$tmp"
    [[ $enable == on ]] && printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>"$tmp"
    chmod --reference="$FSTAB" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$FSTAB"
}

swap_off() {
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        msg "(dry run, skipped) disable managed swap $SWAP_FILE"
        return 0
    fi
    if [[ -e $SWAP_FILE ]] && ! swap_is_managed; then
        err "Refusing to modify an unmanaged file at $SWAP_FILE"
    fi
    if swap_is_active; then
        swapoff "$SWAP_FILE" || err "Failed to disable $SWAP_FILE"
    fi
    swap_fstab_update off || err "Failed to update $FSTAB"
    rm -f "$SWAP_FILE" "$SWAP_MARKER"
    ok "Managed swap disabled"
}

swap_set() {
    local size=${1:-} bytes parent avail old_active=""
    case ${size,,} in
        status | "") swap_status; return 0 ;;
        off | disable | 0) swap_off; return 0 ;;
    esac
    bytes=$(parse_quota "$size") || err "Invalid swap size: $size (examples: 1G / 512M / 2T)"
    ((bytes > 0)) || err "Swap size must be greater than zero"
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        msg "(dry run, skipped) configure managed swap $SWAP_FILE with $(fmt_size "$bytes")"
        return 0
    fi
    cmd_exists fallocate && cmd_exists mkswap && cmd_exists swapon && cmd_exists swapoff ||
        err "Swap tools are missing; install util-linux"
    if [[ -e $SWAP_FILE ]] && ! swap_is_managed; then
        err "Refusing to overwrite an unmanaged file at $SWAP_FILE"
    fi
    parent=${SWAP_FILE%/*}
    mkdir -p "$parent"
    avail=$(df -PB1 "$parent" | awk 'NR == 2 {print $4}')
    is_uint "$avail" || err "Failed to determine free disk space"
    ((avail > bytes + 104857600)) || err "Insufficient disk space for $(fmt_size "$bytes") plus a safety reserve"

    rm -f "$SWAP_FILE.new"
    ( umask 077 && touch "$SWAP_FILE.new" && chmod 600 "$SWAP_FILE.new" ) || { rm -f "$SWAP_FILE.new"; err "Failed to create swap file"; }
    fallocate -l "$bytes" "$SWAP_FILE.new" || { rm -f "$SWAP_FILE.new"; err "Failed to allocate swap file"; }
    chmod 600 "$SWAP_FILE.new"
    mkswap "$SWAP_FILE.new" >/dev/null || { rm -f "$SWAP_FILE.new"; err "Failed to format swap file"; }

    swap_is_active && old_active=1
    if [[ -n $old_active ]] && ! swapoff "$SWAP_FILE"; then
        rm -f "$SWAP_FILE.new"
        err "Failed to disable the previous swap file; no files were changed"
    fi
    [[ -e $SWAP_FILE ]] && mv -f "$SWAP_FILE" "$SWAP_FILE.old"
    mv -f "$SWAP_FILE.new" "$SWAP_FILE"
    if ! swapon "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        if [[ -e $SWAP_FILE.old ]]; then
            mv -f "$SWAP_FILE.old" "$SWAP_FILE"
            [[ -n $old_active ]] && swapon "$SWAP_FILE" || true
        fi
        err "Failed to enable the new swap file; the previous file was restored"
    fi
    rm -f "$SWAP_FILE.old"
    touch "$SWAP_MARKER"
    chmod 600 "$SWAP_MARKER"
    swap_fstab_update on || err "Swap is active, but $FSTAB could not be updated"
    ok "Managed swap configured: $(fmt_size "$bytes") at $SWAP_FILE"
}

swap_cmd() {
    case ${1:-status} in
        status | s) swap_status ;;
        off | disable) swap_off ;;
        *) swap_set "$1" ;;
    esac
}
