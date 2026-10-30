#!/usr/bin/env bash
# vpsm - Xray config generation and runtime user management

self_ips() {
    { ip -o addr show scope global 2>/dev/null || true; } |
        awk '!/ temporary/ {sub(/\/.*/, "", $4); print $4}' | sort -u | jq -Rnc '[inputs]'
}

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
                 serverNames: [$s.domain], privateKey: $s.private_key, shortIds: $s.short_ids,
                 minClientVer: "1.8.2"}},
             sniffing: {enabled: true, destOverride: ["http", "tls"], routeOnly: true}}
          ],
          dns: {servers: ["localhost"], queryStrategy: "UseIPv4"},
          outbounds: [
            {tag: "direct", protocol: "freedom",
             streamSettings: {sockopt: {domainStrategy: "ForceIPv4"}}},
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

xray_adu() {
    local name=$1 uuid f out
    uuid=$(user_get "$name" '.uuid')
    f=$(mktemp "$ROOT/.adu.XXXXXX.json") || return 1
    jq -n --arg tag "$INBOUND_TAG" --argjson port "$(db_get '.settings.port')" \
        --arg id "$uuid" --arg email "$name" \
        '{inbounds:[{tag:$tag,port:$port,protocol:"vless",
          settings:{clients:[{id:$id,email:$email,flow:"xtls-rprx-vision",level:0}],decryption:"none"}}]}' >"$f"
    out=$(timeout 15 "$XRAY_BIN" api adu -s "$API_ADDR" "$f" 2>&1)
    rm -f "$f"
    [[ $out == *"Added 1 user"* ]]
}

xray_restart() {
    local force="" skip="" a
    for a in "$@"; do
        case $a in
            force) force=1 ;;
            skip) skip=1 ;;
        esac
    done
    if xray_active && [[ -z $skip ]]; then
        if ! traffic_pull && ! traffic_pull; then
            warn "Failed to persist Xray traffic counters"
            [[ -n $force ]] || return 1
        fi
    fi
    svc restart "$XRAY_SVC"
}
