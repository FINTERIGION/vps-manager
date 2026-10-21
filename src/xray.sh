#!/usr/bin/env bash
# vpsm - Xray config generation and runtime user management

# Addresses of this host's interfaces as a JSON array. geoip:private does not cover them, so without this
# proxied users could reach services bound to the public IP. Temporary IPv6 addresses rotate and are skipped
# to keep config.json stable
self_ips() {
    { ip -o addr show scope global 2>/dev/null || true; } |
        awk '!/ temporary/ {sub(/\/.*/, "", $4); print $4}' | sort -u | jq -Rnc '[inputs]'
}

# Generate config.json from users.json (enabled users only) and validate it with xray -test.
# Sets XRAY_CONF_CHANGED=1 when the file was rewritten; an unchanged config skips validation
xray_gen_config() {
    local tmp errf
    XRAY_CONF_CHANGED=""
    tmp=$(mktemp "$ROOT/.cfg.XXXXXX.json") || err "Failed to create temporary file"
    if ! jq --argjson apiport "$API_PORT" --arg tag "$INBOUND_TAG" --arg dest "127.0.0.1:$CADDY_PORT" \
        --argjson selfips "$(self_ips)" '
        .settings as $s | {
          log: {loglevel: "warning", access: "none"},
          stats: {},
          api: {tag: "api", services: ["StatsService", "HandlerService"]},
          policy: {levels: {"0": {statsUserUplink: true, statsUserDownlink: true}}},
          inbounds: [
            {tag: "api", listen: "127.0.0.1", port: $apiport, protocol: "dokodemo-door",
             settings: {address: "127.0.0.1"}},
            {tag: $tag, port: $s.port, protocol: "vless",
             settings: {
               clients: [.users[] | select(.enabled)
                         | {id: .uuid, email: .name, flow: "xtls-rprx-vision", level: 0}],
               decryption: "none"},
             streamSettings: {
               network: "tcp", security: "reality",
               realitySettings: {
                 show: false, dest: $dest, xver: 0,
                 serverNames: [$s.domain], privateKey: $s.private_key, shortIds: $s.short_ids}},
             sniffing: {enabled: true, destOverride: ["http", "tls"], routeOnly: true}}
          ],
          # Outbound traffic prefers IPv4: domains connect over IPv4 whenever they have an A record and
          # fall back to IPv6 only when they do not. DNS keeps both families so IPIfNonMatch routing
          # also checks AAAA records against the block rules
          dns: {servers: ["localhost"], queryStrategy: "UseIP"},
          outbounds: [
            {tag: "direct", protocol: "freedom",
             streamSettings: {sockopt: {domainStrategy: "ForceIPv4v6"}}},
            {tag: "block", protocol: "blackhole"}
          ],
          routing: {domainStrategy: "IPIfNonMatch", rules: [
            {type: "field", inboundTag: ["api"], outboundTag: "api"},
            {type: "field", protocol: ["bittorrent"], outboundTag: "block"},
            {type: "field", port: "25", outboundTag: "block"},
            {type: "field", ip: (["geoip:private", "geoip:cn"] + $selfips), outboundTag: "block"}
          ]}
        }' "$DB" >"$tmp"; then
        rm -f "$tmp"
        err "Failed to generate Xray config"
    fi
    if cmp -s "$tmp" "$XRAY_CONF"; then
        rm -f "$tmp"
        return 0
    fi
    if [[ -x $XRAY_BIN ]]; then
        errf="$tmp.err"
        if ! "$XRAY_BIN" run -test -config "$tmp" >"$errf" 2>&1; then
            cat "$errf" >&2
            rm -f "$tmp" "$errf"
            err "Xray config validation failed, not applied"
        fi
        rm -f "$errf"
    else
        warn "$XRAY_BIN not found, skipping config validation"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$XRAY_CONF"
    XRAY_CONF_CHANGED=1
    fix_perms
}

xray_active() { svc_active "$XRAY_SVC"; }

# Hot-add a user via the API (returns non-zero on failure)
xray_adu() {
    local name=$1 uuid f out
    uuid=$(user_get "$name" '.uuid')
    f=$(mktemp "$ROOT/.adu.XXXXXX.json") || return 1
    # adu needs the full inbound identity (tag + port), otherwise it silently adds 0 users
    jq -n --arg tag "$INBOUND_TAG" --argjson port "$(db_get '.settings.port')" \
        --arg id "$uuid" --arg email "$name" \
        '{inbounds:[{tag:$tag,port:$port,protocol:"vless",
          settings:{clients:[{id:$id,email:$email,flow:"xtls-rprx-vision",level:0}],decryption:"none"}}]}' >"$f"
    # The command returns 0 even on failure, so check the output for "Added 1 user"
    out=$(timeout 15 "$XRAY_BIN" api adu -s "$API_ADDR" "$f" 2>&1)
    rm -f "$f"
    [[ $out == *"Added 1 user"* ]]
}

# Restart Xray. A restart clears the in-memory traffic counters, so persist them first.
# xray_gen_config must have been called beforehand. A restart also drops all existing connections,
# so deleting/disabling users (including over-quota and expired) always restarts, ensuring
# disabled users' existing connections are cut off immediately.
xray_restart() {
    xray_active && traffic_pull
    svc restart "$XRAY_SVC"
}
