#!/usr/bin/env bash
# vpsm - disguise health check, seen the way an active prober sees it
#
# The anti-detection value of a Reality node lives or dies on the fallback site:
# a prober that completes a plain TLS handshake against the Xray port is handed
# to the Caddy dest and judges the node by what comes back. Every failure mode
# here is silent by default (an expired certificate, a CDN proxy breaking ACME,
# a placeholder page, a dead panel behind /api/*), so this makes them visible.

CK_PASS=0
CK_WARN=0
CK_FAIL=0

ck_ok() { printf '  %s[PASS]%s %-20s %s\n' "$C_GRN" "$C_RST" "$1" "$2"; CK_PASS=$((CK_PASS + 1)); }
ck_warn() { printf '  %s[WARN]%s %-20s %s\n' "$C_YLW" "$C_RST" "$1" "$2"; CK_WARN=$((CK_WARN + 1)); }
ck_fail() { printf '  %s[FAIL]%s %-20s %s\n' "$C_RED" "$C_RST" "$1" "$2"; CK_FAIL=$((CK_FAIL + 1)); }
ck_info() { printf '  %s[INFO]%s %-20s %s\n' "$C_CYN" "$C_RST" "$1" "$2"; }

# Read one field out of a probe JSON blob, tolerating an empty or invalid blob.
ck_json() {
    [[ -n ${1:-} ]] || return 0
    jq -r "$2" <<<"$1" 2>/dev/null
}

# check.py always exits 0 for a completed probe and reports findings in JSON, so
# an empty result means python3 or the script itself is unavailable.
check_cert_json() {
    timeout 15 python3 "$SH_DIR/src/check.py" cert "$1" "$2" "$3" 2>/dev/null
}

# One-line certificate status for show_status. Never fails: an unreachable Caddy
# is a finding to report, not an error condition for the caller.
cert_summary() {
    local domain port json days issuer err
    domain=$(db_get '.settings.domain // ""' 2>/dev/null)
    [[ -n $domain ]] || { echo "no domain configured"; return 0; }
    port=$(db_get '.settings.port // 443' 2>/dev/null)
    json=$(check_cert_json 127.0.0.1 "$port" "$domain")
    if [[ -z $json ]] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
        echo "unavailable"
        return 0
    fi
    if [[ $(ck_json "$json" '.ok') != true ]]; then
        err=$(ck_json "$json" '.error // ""')
        if [[ $(ck_json "$json" '.reachable // false') != true ]]; then
            echo "unavailable (${err:-nothing answered on 127.0.0.1:$port})"
        else
            echo "VERIFY FAILED: ${err:-unknown reason}"
        fi
        return 0
    fi
    days=$(ck_json "$json" '.days_left // empty')
    issuer=$(ck_json "$json" '.issuer // ""')
    if [[ -z $days ]]; then
        echo "valid, expiry unknown (${issuer:-unknown issuer})"
    elif ((days < 0)); then
        echo "EXPIRED $((-days)) days ago (${issuer:-unknown issuer})"
    else
        echo "$days days left (${issuer:-unknown issuer})"
    fi
    return 0
}

# Called from sync_all at most once per CERT_CHECK_INTERVAL so the per-minute
# timer does not spawn python3 on every tick. Warnings land in journald.
cert_warn_if_expiring() {
    local domain port json days err
    # Nothing to probe while Caddy is deliberately down, and the service state is
    # already reported by node_check and show_status.
    svc_active "$CADDY_SVC" || return 0
    domain=$(db_get '.settings.domain // ""' 2>/dev/null)
    [[ -n $domain ]] || return 0
    port=$(db_get '.settings.port // 443' 2>/dev/null)
    json=$(check_cert_json 127.0.0.1 "$port" "$domain")
    [[ -n $json ]] && jq -e . >/dev/null 2>&1 <<<"$json" || return 0
    if [[ $(ck_json "$json" '.ok') != true ]]; then
        err=$(ck_json "$json" '.error // ""')
        warn "Fallback TLS certificate is unusable (${err:-unknown reason}); probers see a broken site (run: vpsm check)"
        return 0
    fi
    days=$(ck_json "$json" '.days_left // empty')
    if [[ -n $days ]] && ((days < CERT_WARN_DAYS)); then
        warn "Fallback TLS certificate expires in $days day(s); ACME renewal is failing (run: vpsm check)"
    fi
    return 0
}

# Throttled wrapper used by sync_all, which vpsm-traffic.timer runs every minute
# as root. The stamp file caps the probe at once per CERT_CHECK_INTERVAL.
cert_check_throttled() {
    [[ -f $CERT_STAMP ]] &&
        (($(date +%s) - $(stat -c %Y "$CERT_STAMP" 2>/dev/null || echo 0) < CERT_CHECK_INTERVAL)) && return 0
    touch "$CERT_STAMP" 2>/dev/null || return 0
    cert_warn_if_expiring
    return 0
}

# The Reality dest, show flag and serverNames are what make a probe land on the
# fallback site at all. Verify them by tag: inbounds[0] is the API inbound.
check_reality_settings() {
    local domain=$1 conf_json dest show nids
    if [[ ! -f $XRAY_CONF ]]; then
        ck_fail "Xray config" "$XRAY_CONF does not exist (run: vpsm restart)"
        return 0
    fi
    conf_json=$(jq -c --arg t "$INBOUND_TAG" \
        '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings' "$XRAY_CONF" 2>/dev/null)
    if [[ -z $conf_json || $conf_json == null ]]; then
        ck_fail "Reality inbound" "no inbound tagged $INBOUND_TAG in $XRAY_CONF"
        return 0
    fi
    dest=$(ck_json "$conf_json" '.dest // ""')
    if [[ $dest == "127.0.0.1:$CADDY_PORT" ]]; then
        ck_ok "Reality dest" "$dest"
    else
        ck_fail "Reality dest" "${dest:-missing}, expected 127.0.0.1:$CADDY_PORT"
    fi
    show=$(ck_json "$conf_json" '.show')
    if [[ $show == false ]]; then
        ck_ok "Reality show" "false (handshakes are not logged)"
    else
        ck_fail "Reality show" "$show, must be false"
    fi
    if jq -e --arg d "$domain" '.serverNames | index($d) != null' >/dev/null 2>&1 <<<"$conf_json"; then
        ck_ok "Reality serverNames" "contains $domain"
    else
        ck_fail "Reality serverNames" "$(ck_json "$conf_json" '.serverNames | join(",")'), must contain $domain"
    fi
    nids=$(ck_json "$conf_json" '.shortIds | length')
    if [[ -n $nids ]] && ((nids > 0)); then
        ck_ok "Reality shortIds" "$nids configured"
    else
        ck_warn "Reality shortIds" "none configured"
    fi
    return 0
}

check_firewall_ports() {
    local port=$1 rules
    if ! fw_enabled; then
        ck_info "Firewall" "disabled (all ports reachable)"
        return 0
    fi
    if ! fw_loaded iptables; then
        ck_fail "Firewall" "enabled in the database but no rules are loaded (run: vpsm firewall reload)"
        return 0
    fi
    if ! cmd_exists iptables; then
        ck_warn "Firewall" "enabled, but iptables is unavailable here"
        return 0
    fi
    rules=$(iptables -w -S "$FW_CHAIN" 2>/dev/null)
    if grep -qE -- "--dport 80([^0-9]|$)" <<<"$rules" && grep -qE -- "--dport $port([^0-9]|$)" <<<"$rules"; then
        ck_ok "Firewall" "rules loaded; 80 and $port allowed"
    else
        ck_fail "Firewall" "$FW_CHAIN does not allow both 80 and $port"
    fi
    return 0
}

node_check() {
    local domain port url tmp code size days issuer err my_ip dns_ip s state json
    CK_PASS=0 CK_WARN=0 CK_FAIL=0
    domain=$(db_get '.settings.domain // ""')
    [[ -n $domain ]] || err "No domain is configured yet"
    port=$(db_get '.settings.port // 443')
    if [[ $port == 443 ]]; then url="https://$domain"; else url="https://$domain:$port"; fi

    msg "== Disguise health check for $domain:$port =="
    echo "  Probing the node the way an active prober does: a plain TLS handshake"
    echo "  to port $port, which Reality forwards to the Caddy fallback site."
    echo

    # 1. Certificate, verified with a real CA store and strict hostname matching.
    json=$(check_cert_json 127.0.0.1 "$port" "$domain")
    if [[ $(ck_json "$json" '.ok') == true ]]; then
        days=$(ck_json "$json" '.days_left // empty')
        issuer=$(ck_json "$json" '.issuer // ""')
        if [[ -z $days ]]; then
            ck_warn "TLS certificate" "valid, but the expiry could not be read (${issuer:-unknown issuer})"
        elif ((days < 0)); then
            ck_fail "TLS certificate" "EXPIRED $((-days)) days ago (${issuer:-unknown issuer})"
        elif ((days < CERT_WARN_DAYS)); then
            ck_fail "TLS certificate" "expires in $days day(s); ACME renewal is failing (${issuer:-unknown issuer})"
        else
            ck_ok "TLS certificate" "$days days left (${issuer:-unknown issuer})"
        fi
        ck_info "TLS negotiation" "$(ck_json "$json" '.protocol // "?"') / ALPN $(ck_json "$json" 'if (.alpn // "") == "" then "none" else .alpn end')"
    else
        err=$(ck_json "$json" '.error // ""')
        ck_fail "TLS certificate" "${err:-the certificate probe returned nothing (is python3 present?)}"
        # Isolate the fault: hitting the Caddy dest directly tells a broken
        # Reality forward apart from a broken certificate.
        json=$(check_cert_json 127.0.0.1 "$CADDY_PORT" "$domain")
        if [[ $(ck_json "$json" '.ok') == true ]]; then
            ck_info "Isolation" "Caddy on 127.0.0.1:$CADDY_PORT is healthy, so the Reality dest forward on port $port is at fault"
        else
            ck_info "Isolation" "Caddy on 127.0.0.1:$CADDY_PORT also fails: $(ck_json "$json" '.error // "no result"')"
        fi
    fi

    check_reality_settings "$domain"

    # 2. The fallback page a prober actually receives.
    tmp=$(mktemp -d "$ROOT/.check.XXXXXX") || { warn "Cannot create a temporary directory"; return 1; }
    code=$(curl -sS --resolve "$domain:$port:127.0.0.1" --max-time 15 \
        -o "$tmp/body" -w '%{http_code}' "$url/" 2>"$tmp/err")
    size=$(stat -c %s "$tmp/body" 2>/dev/null || echo 0)
    if [[ $code == 200 ]]; then
        if ((size < 2048)); then
            ck_warn "Fallback page" "HTTP 200 but only $size bytes; a near-empty page reads as a placeholder"
        else
            ck_ok "Fallback page" "HTTP 200, $size bytes"
        fi
    else
        ck_fail "Fallback page" "HTTP ${code:-000}: $(tr -d '\n' <"$tmp/err" | head -c 140)"
    fi

    # 3. Has the fallback silently degraded to the generated placeholder?
    if [[ ! -f $WWW_DIR/index.html ]]; then
        ck_fail "Fallback content" "$WWW_DIR/index.html does not exist"
    elif caddy_index_is_placeholder; then
        if fv_enabled; then
            ck_fail "Fallback content" "FuturesView is enabled but index.html is a generated placeholder (run: vpsm fv update)"
        else
            ck_warn "Fallback content" "index.html is a generated placeholder with no real content"
        fi
    else
        ck_ok "Fallback content" "index.html is not a generated placeholder"
    fi

    # 4. favicon: browsers request it, and its absence is a cheap tell.
    code=$(curl -sS --resolve "$domain:$port:127.0.0.1" --max-time 10 \
        -o /dev/null -w '%{http_code}' "$url/favicon.ico" 2>/dev/null)
    if [[ $code == 200 ]]; then
        ck_ok "favicon.ico" "HTTP 200"
    else
        ck_warn "favicon.ico" "HTTP ${code:-000}"
    fi

    # 5. ACME HTTP-01 prerequisites. Both are silent-failure sources: renewal
    #    keeps failing for weeks before the certificate finally expires.
    if port_in_use 80; then
        ck_ok "ACME port 80" "listening"
    else
        ck_fail "ACME port 80" "nothing is listening, so HTTP-01 renewal cannot succeed"
    fi
    my_ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null)
    dns_ip=$(timeout 8 getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z $dns_ip ]]; then
        ck_fail "DNS -> this host" "$domain does not resolve to any IPv4 address"
    elif [[ -z $my_ip ]]; then
        ck_warn "DNS -> this host" "this server's public IP could not be determined; $domain -> $dns_ip"
    elif [[ $dns_ip == "$my_ip" ]]; then
        ck_ok "DNS -> this host" "$domain -> $dns_ip"
    else
        ck_fail "DNS -> this host" "$domain -> $dns_ip but this server is $my_ip (a CDN proxy breaks ACME HTTP-01)"
    fi

    # 6. Services. A dead panel behind /api/* turns the fallback into a 502 farm.
    for s in "$XRAY_SVC" "$CADDY_SVC"; do
        state=$(systemctl is-active "$s" 2>/dev/null || echo inactive)
        if svc_active "$s"; then ck_ok "service $s" "active"; else ck_fail "service $s" "$state"; fi
    done
    if fv_enabled || [[ -d $FV_DIR ]]; then
        state=$(systemctl is-active "$FV_SVC" 2>/dev/null || echo inactive)
        if svc_active "$FV_SVC"; then
            ck_ok "service $FV_SVC" "active"
        elif fv_enabled; then
            ck_fail "service $FV_SVC" "$state, but /api/* is proxied to it, so the fallback returns 502"
        else
            ck_warn "service $FV_SVC" "$state (disabled, so the stale SPA has no live data)"
        fi
    fi
    if systemctl is-active --quiet vpsm-traffic.timer 2>/dev/null; then
        ck_ok "traffic timer" "active"
    else
        ck_warn "traffic timer" "not active; traffic, quota and expiry accounting are stalled"
    fi

    check_firewall_ports "$port"

    rm -rf "$tmp"
    echo
    printf '  %d passed, %d warning(s), %d failed\n' "$CK_PASS" "$CK_WARN" "$CK_FAIL"
    if ((CK_FAIL > 0)); then
        warn "The fallback site is not passing; a prober can tell this is not a normal website"
        return 1
    fi
    ((CK_WARN > 0)) && warn "The fallback site works but has weaknesses worth closing"
    ok "The fallback site looks healthy from a prober's point of view"
    return 0
}
