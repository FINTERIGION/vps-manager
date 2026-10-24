#!/usr/bin/env bash
# vpsm - iptables inbound firewall (allow only the required ports, reject everything else)
#
# All rules live in dedicated chains jumped to from the top of INPUT / OUTPUT, so rules managed by
# other tools (Docker, etc.) are left untouched. Settings: .settings.firewall.{enabled,allow}
# VPSM-OUT (the Xray API guard) is always loaded by vpsm-firewall.service; VPSM-IN only when enabled

FW_CHAIN="VPSM-IN"
FW_OUT_CHAIN="VPSM-OUT"
FW_SVC="vpsm-firewall"
FW_STAMP="$ROOT/.fw_ports" # allowed ports of the loaded VPSM-IN rules

fw_enabled() { [[ $(db_get '.settings.firewall.enabled // false') == true ]]; }
fw_has_v6() { [[ -e /proc/net/if_inet6 ]]; }

fw_ensure_tools() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    cmd_exists iptables && cmd_exists iptables-restore && return 0
    msg "Installing iptables ..."
    if cmd_exists apt-get; then
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >/dev/null
    elif cmd_exists dnf; then
        dnf install -y iptables >/dev/null
    elif cmd_exists yum; then
        yum install -y iptables >/dev/null
    fi
    cmd_exists iptables && cmd_exists iptables-restore || err "iptables is not available, please install it manually"
}

# fw_parse_spec <port|from-to>[/tcp|/udp]: prints the normalized "port/proto" (protocol defaults to tcp)
fw_parse_spec() {
    local s=${1,,} a b="" proto
    [[ $s =~ ^([0-9]{1,5})(-([0-9]{1,5}))?(/(tcp|udp))?$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]}))
    [[ -n ${BASH_REMATCH[3]} ]] && b=$((10#${BASH_REMATCH[3]}))
    proto=${BASH_REMATCH[5]:-tcp}
    valid_port "$a" || return 1
    if [[ -n $b ]]; then
        valid_port "$b" && ((a < b)) || return 1
        echo "$a-$b/$proto"
    else
        echo "$a/$proto"
    fi
}

# Ports sshd is configured to listen on (falls back to 22)
fw_sshd_ports() {
    local ports
    if cmd_exists sshd; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
    fi
    if [[ -z $ports ]]; then
        ports=$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null |
            awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ {print $2}')
    fi
    echo "${ports:-22}" | sort -un
}

# Ports SSH is actually reachable on right now: the current session (SSH_CONNECTION is dropped by sudo),
# sshd's listeners and ssh.socket (socket activation, e.g. Ubuntu 24.04). These can differ from
# sshd_config until sshd / ssh.socket is restarted
fw_ssh_live_ports() {
    local u
    {
        [[ -n ${SSH_CONNECTION:-} ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
        if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
            cmd_exists ss && ss -ltnpH 2>/dev/null | awk '/users:\(\("sshd"/ {n = split($4, a, ":"); print a[n]}'
            for u in ssh.socket sshd.socket; do
                systemctl is-active --quiet "$u" 2>/dev/null &&
                    systemctl show -p Listen --value "$u" 2>/dev/null | sed -nE 's/.*:([0-9]+) \(Stream\).*/\1/p'
            done
        fi
    } | awk '/^[0-9]+$/' | sort -un
}

# Configured plus live SSH ports, so enabling the firewall over SSH never locks you out
fw_ssh_ports() {
    {
        fw_sshd_ports
        fw_ssh_live_ports
    } | sort -un
}

# Allowed inbound ports, one "port/proto<TAB>description" per line
fw_allowed() {
    local p
    {
        for p in $(fw_ssh_ports); do printf '%s/tcp\tSSH\n' "$p"; done
        printf '80/tcp\tCaddy certificate issuance (ACME HTTP-01)\n'
        printf '%s/tcp\tXray (VLESS Reality) / subscriptions\n' "$(db_get '.settings.port')"
        db_get '.settings.firewall.allow // [] | .[] | "\(.)\tcustom"'
    } | awk -F'\t' '!seen[$1]++'
}

# iptables-restore input for the VPSM-IN chain: fw_rules <4|6>
fw_rules() {
    local v=$1 spec
    echo "*filter"
    echo ":$FW_CHAIN - [0:0]"
    # Only loopback destinations: proxied connections to this host's public IP also arrive via lo
    # and must still go through the port whitelist
    if [[ $v == 4 ]]; then
        echo "-A $FW_CHAIN -i lo -d 127.0.0.0/8 -j ACCEPT"
    else
        echo "-A $FW_CHAIN -i lo -d ::1/128 -j ACCEPT"
    fi
    # ICMP (ping included) goes before the INVALID check: PMTU discovery and IPv6 neighbor discovery
    # must never be dropped
    if [[ $v == 4 ]]; then
        echo "-A $FW_CHAIN -p icmp -j ACCEPT"
    else
        echo "-A $FW_CHAIN -p ipv6-icmp -j ACCEPT"
    fi
    echo "-A $FW_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    # Dropped rather than rejected: a TCP reset here could kill legitimate established connections
    echo "-A $FW_CHAIN -m conntrack --ctstate INVALID -j DROP"
    [[ $v == 6 ]] && echo "-A $FW_CHAIN -s fe80::/10 -p udp --sport 547 --dport 546 -j ACCEPT"
    while read -r spec; do
        echo "-A $FW_CHAIN -p ${spec#*/} --dport $(tr - : <<<"${spec%/*}") -j ACCEPT"
    done < <(fw_allowed | cut -f1)
    echo "-A $FW_CHAIN -p tcp -j REJECT --reject-with tcp-reset"
    if [[ $v == 4 ]]; then
        echo "-A $FW_CHAIN -p udp -j REJECT --reject-with icmp-port-unreachable"
        echo "-A $FW_CHAIN -j REJECT --reject-with icmp-proto-unreachable"
    else
        echo "-A $FW_CHAIN -p udp -j REJECT --reject-with icmp6-port-unreachable"
        echo "-A $FW_CHAIN -j REJECT --reject-with icmp6-adm-prohibited"
    fi
    echo "COMMIT"
}

# The Xray API has no authentication and can add users or reset traffic counters: only root (the
# vpsm CLI) may connect to it. Proxied connections come from Xray's own user, so this also covers
# DNS rebinding past the geoip:private routing rule. The API listens on 127.0.0.1 only, so IPv4 suffices
fw_guard_rules() {
    echo "*filter"
    echo ":$FW_OUT_CHAIN - [0:0]"
    echo "-A $FW_OUT_CHAIN -o lo -p tcp --dport $API_PORT -m owner ! --uid-owner 0 -j REJECT --reject-with tcp-reset"
    echo "COMMIT"
}

# fw_load <iptables|ip6tables> <chain> <INPUT|OUTPUT>: atomically replace the chain from the
# iptables-restore input on stdin (--noflush only flushes the declared chain), then hook it in
fw_load() {
    local ipt=$1 chain=$2 hook=$3
    "$ipt-restore" --noflush || return 1
    "$ipt" -w -C "$hook" -j "$chain" 2>/dev/null || "$ipt" -w -I "$hook" 1 -j "$chain"
}

# fw_unload <iptables|ip6tables> <chain> <INPUT|OUTPUT>
fw_unload() {
    local ipt=$1 chain=$2 hook=$3
    cmd_exists "$ipt" || return 0
    while "$ipt" -w -D "$hook" -j "$chain" 2>/dev/null; do :; done
    "$ipt" -w -F "$chain" 2>/dev/null
    "$ipt" -w -X "$chain" 2>/dev/null
    return 0
}

# fw_loaded <iptables|ip6tables> [chain] [hook]
fw_loaded() { cmd_exists "$1" && "$1" -w -C "${3:-INPUT}" -j "${2:-$FW_CHAIN}" 2>/dev/null; }

fw_apply() {
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        msg "(dry run, skipped) iptables-restore --noflush:"
        fw_rules 4
        fw_has_v6 && { msg "(dry run, skipped) ip6tables-restore --noflush:"; fw_rules 6; }
        return 0
    fi
    fw_rules 4 | fw_load iptables "$FW_CHAIN" INPUT || return 1
    if fw_has_v6; then
        if ! cmd_exists ip6tables; then
            warn "ip6tables not found, IPv6 inbound traffic is NOT filtered"
            return 1
        elif ! fw_rules 6 | fw_load ip6tables "$FW_CHAIN" INPUT; then
            warn "Failed to load IPv6 firewall rules, IPv6 inbound traffic is NOT filtered"
            return 1
        fi
    fi
    fw_allowed | cut -f1 >"$FW_STAMP"
}

fw_guard_apply() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    cmd_exists iptables-restore || return 1
    fw_guard_rules | fw_load iptables "$FW_OUT_CHAIN" OUTPUT
}

# Called by the traffic timer: installs upgraded from older versions (and rules flushed by other
# tools) get the guard back without a reboot. Quiet, since it runs every minute
fw_guard_ensure() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    cmd_exists iptables || return 0
    fw_loaded iptables "$FW_OUT_CHAIN" OUTPUT || fw_guard_apply >/dev/null 2>&1
    systemctl is-enabled --quiet "$FW_SVC" 2>/dev/null || systemctl enable --quiet "$FW_SVC" 2>/dev/null
    return 0
}

# Called by the traffic timer: after the SSH port is changed and sshd restarted, new connections are
# allowed within a minute instead of only after a manual reload. Rules that are not loaded stay so
fw_ports_ensure() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    fw_enabled && fw_loaded iptables || return 0
    local cur
    cur=$(fw_allowed | cut -f1)
    [[ $cur == "$(cat "$FW_STAMP" 2>/dev/null)" ]] && return 0
    msg "Allowed inbound ports changed (${cur//$'\n'/ }), reloading firewall rules"
    fw_apply || warn "Failed to reload firewall rules, run: vpsm firewall reload"
}

fw_guard_text() {
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        echo "unknown (dry run)"
    elif fw_loaded iptables "$FW_OUT_CHAIN" OUTPUT; then
        echo "active"
    else
        echo "NOT active (run vpsm firewall reload)"
    fi
}

# Remove the inbound whitelist only (firewall off); the API guard stays
fw_flush_input() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && { msg "(dry run, skipped) remove $FW_CHAIN rules"; return 0; }
    fw_unload iptables "$FW_CHAIN" INPUT
    fw_unload ip6tables "$FW_CHAIN" INPUT
}

fw_flush_all() {
    fw_flush_input
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    fw_unload iptables "$FW_OUT_CHAIN" OUTPUT
}

# Re-apply the rules if the firewall is enabled (call after changing ports)
fw_refresh() {
    if fw_enabled; then
        fw_apply || return 1
    fi
    return 0
}

fw_list() {
    local spec desc
    while IFS=$'\t' read -r spec desc; do
        printf '  %-16s %s\n' "$spec" "$desc"
    done < <(fw_allowed)
}

fw_state_text() {
    if ! fw_enabled; then
        echo "disabled"
    elif fw_loaded iptables; then
        echo "enabled"
    else
        echo "enabled, but rules are NOT loaded (run vpsm firewall reload)"
    fi
}

fw_status() {
    echo "Firewall: $(fw_state_text)"
    echo "Xray API guard (always on): $(fw_guard_text)"
    echo "Allowed inbound ports (everything else is rejected when enabled, ping stays allowed):"
    fw_list
}

# vpsm firewall on [-y]
fw_enable() {
    local p conf ans s
    fw_ensure_tools
    # Live ports are not detectable at boot (sshd is not running yet), so persist them
    conf=$(fw_sshd_ports)
    for p in $(fw_ssh_live_ports); do
        grep -qx "$p" <<<"$conf" && continue
        db_write --arg s "$p/tcp" '.settings.firewall.allow = ((.settings.firewall.allow // []) + [$s] | unique)'
        msg "SSH is listening on port $p, which is not in sshd_config; added it to the allow list"
    done
    msg "Only these inbound ports will be allowed, everything else will be rejected (ping stays allowed):"
    fw_list
    if [[ ${1:-} != -y && ${1:-} != --yes && -t 0 ]]; then
        read -r -p "Make sure your SSH port is listed above. Enable the firewall? [y/N] " ans
        [[ $ans == y || $ans == Y ]] || { msg "Cancelled"; return 0; }
    fi
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        for s in ufw firewalld; do
            systemctl is-active --quiet "$s" && warn "$s is running; its rules also apply and may block ports allowed here"
        done
    fi
    if ! fw_apply; then
        fw_flush_input
        err "Failed to load firewall rules (IPv4 and IPv6 must both apply when IPv6 is present). Install ip6tables or disable IPv6, then retry"
    fi
    fw_guard_apply || warn "Failed to load the Xray API guard rule"
    db_write '.settings.firewall.enabled = true'
    svc enable "$FW_SVC" >/dev/null 2>&1 || warn "Failed to enable $FW_SVC, rules will not be restored after reboot"
    ok "Firewall enabled (rules are restored automatically on boot)"
    msg "Also allow these ports in your VPS provider's security group, if it has one"
}

# The service stays enabled: it also restores the Xray API guard on boot
fw_disable() {
    db_write '.settings.firewall.enabled = false'
    fw_flush_input
    ok "Firewall disabled, inbound whitelist removed (the Xray API guard stays active)"
}

fw_allow() {
    local spec
    spec=$(fw_parse_spec "${1:-}") || err "Usage: vpsm firewall allow <port|from-to>[/tcp|/udp], e.g. 8080, 53/udp, 10000-20000/udp"
    fw_allowed | cut -f1 | grep -qx "$spec" && { msg "$spec is already allowed"; return 0; }
    db_write --arg s "$spec" '.settings.firewall.allow = ((.settings.firewall.allow // []) + [$s] | unique)'
    fw_refresh || warn "Firewall rules were not reloaded, run: vpsm firewall reload"
    ok "Allowed inbound $spec$(fw_enabled || echo ' (takes effect once the firewall is enabled)')"
}

fw_deny() {
    local spec
    spec=$(fw_parse_spec "${1:-}") || err "Usage: vpsm firewall deny <port|from-to>[/tcp|/udp]"
    if [[ $(db_get --arg s "$spec" '(.settings.firewall.allow // []) | any(.[]; . == $s)') != true ]]; then
        fw_allowed | cut -f1 | grep -qx "$spec" &&
            err "$spec is required by SSH/Caddy/Xray and cannot be removed"
        err "$spec is not in the custom allow list"
    fi
    db_write --arg s "$spec" '.settings.firewall.allow -= [$s]'
    fw_refresh || warn "Firewall rules were not reloaded, run: vpsm firewall reload"
    ok "Removed $spec from the allow list"
}

# Boot entry point (vpsm-firewall.service), also used to re-apply manually
fw_reload() {
    fw_enabled && fw_ensure_tools
    fw_guard_apply || warn "Failed to load the Xray API guard rule (iptables owner match unavailable?)"
    if fw_enabled; then
        fw_apply || err "Failed to load firewall rules (IPv4 and IPv6 must both apply)"
        ok "Firewall rules loaded"
    else
        fw_flush_input
    fi
}

firewall_cmd() {
    local sub=${1:-status}
    [[ $# -gt 0 ]] && shift
    case $sub in
        status | s) fw_status ;;
        on | enable) fw_enable "$@" ;;
        off | disable) fw_disable ;;
        allow | add) fw_allow "$@" ;;
        deny | del | rm) fw_deny "$@" ;;
        reload | apply) fw_reload ;;
        flush) fw_flush_all ;;
        *) err "Usage: vpsm firewall [status|on|off|allow <port>[/proto]|deny <port>[/proto]|reload]" ;;
    esac
}
