#!/usr/bin/env bash
# vpsm - local traffic accounting, quota/expiry checks and monthly reset

traffic_apply() {
    local raw=$1
    (db_write --argjson raw "$raw" '
        (reduce (($raw.stat // [])[]) as $s ({};
            ($s.name | split(">>>")) as $p
            | if ($p | length) == 4 and $p[0] == "user" and $p[2] == "traffic"
              then .[$p[1]][$p[3]] += (($s.value // 0) | tonumber) else . end)) as $t
        | .users |= map(
            ($t[.name] // {}) as $d
            | .up += ($d.uplink // 0)
            | .down += ($d.downlink // 0))') 2>/dev/null
}

traffic_save_lost() {
    local f
    jq -e '(.stat // []) | type == "array"' <<<"$1" >/dev/null 2>&1 || return 1
    f=$(umask 077; mktemp "$ROOT/stats.lost.$(date +%s).XXXXXX.json") || return 1
    printf '%s\n' "$1" >"$f"
}

traffic_recover_lost() {
    local f raw
    for f in "$ROOT"/stats.lost.*.json; do
        [[ -e $f ]] || continue
        raw=$(<"$f")
        if ! jq -e '(.stat // []) | type == "array"' <<<"$raw" >/dev/null 2>&1; then
            mv -f "$f" "$f.bad"
            warn "Unreadable saved traffic stats moved to $f.bad"
            continue
        fi
        traffic_apply "$raw" || return 1
        rm -f "$f"
        msg "Recovered saved traffic stats (${f##*/})"
    done
    return 0
}

traffic_pull() {
    traffic_recover_lost || warn "Saved traffic stats could not be stored yet, will retry"
    xray_active || return 0
    local out rc=0
    out=$(timeout 15 "$XRAY_BIN" api statsquery -s "$API_ADDR" -pattern "user>>>" -reset 2>/dev/null) || rc=$?
    if ((rc != 0)); then
        [[ -n $out ]] && traffic_save_lost "$out"
        return 1
    fi
    [[ -n $out ]] || return 0
    if ! traffic_apply "$out"; then
        traffic_save_lost "$out" || true
        warn "Failed to store traffic stats, raw data saved to $ROOT/stats.lost.*.json (recovered automatically)"
        return 1
    fi
}

state_snapshot() {
    jq -c '[.users[] | select(.enabled) | {key: .name, value: .uuid}] | from_entries' "$DB"
}

state_diff() {
    jq -r --argjson old "$1" '
        ([.users[] | select(.enabled) | {key: .name, value: .uuid}] | from_entries) as $new
        | ([.users[] | select(.enabled) | select($old[.name] == null) | "add \(.name)"]
           + [$old | to_entries[] | select($new[.key] != .value) | "rm \(.key)"])
        | .[]' "$DB"
}

traffic_evaluate() {
    RESET_DONE=""
    local month day rd last expire
    month=$(date +%Y-%m)
    day=$((10#$(date +%d)))
    rd=$(db_get '.settings.reset_day')
    last=$(db_get '.settings.last_reset')
    expire=$(db_get '.settings.expire // ""')
    if ((day >= rd)) && [[ $last != "$month" ]]; then
        db_write --arg m "$month" \
            '.settings.last_reset = $m | .users |= map(.up = 0 | .down = 0)'
        RESET_DONE=1
        msg "Monthly traffic reset done ($month)"
    fi
    db_write --arg today "$(today)" --arg expire "$expire" '
        .users |= map(
            (if .disabled_reason == "manual" then "manual"
             elif $expire != "" and $expire < $today then "expired"
             elif .quota > 0 and (.up + .down) >= .quota then "quota"
             else "" end) as $r
            | .disabled_reason = $r | .enabled = ($r == ""))'
}

apply_state() {
    local snap=$1 force=${2:-} skip_pull=${3:-} changes name op fallback="" restart_failed=""
    if [[ -z $skip_pull ]]; then
        traffic_pull || warn "Failed to read Xray traffic stats"
    fi
    traffic_evaluate
    changes=$(state_diff "$snap")
    xray_gen_config
    [[ -n $changes ]] && force=1
    if [[ -n $XRAY_CONF_CHANGED ]]; then
        if xray_active; then
            if [[ -z $changes ]] || grep -q '^rm ' <<<"$changes"; then
                fallback=1
            else
                while read -r op name; do
                    [[ $op == add ]] || continue
                    xray_adu "$name" || { fallback=1; break; }
                done <<<"$changes"
            fi
            if [[ -n $fallback ]]; then
                msg "Restarting Xray to apply user changes..."
                if [[ -n $skip_pull ]]; then
                    xray_restart force skip || { warn "Failed to restart Xray, check: journalctl -u $XRAY_SVC -n 50"; restart_failed=1; }
                else
                    xray_restart force || { warn "Failed to restart Xray, check: journalctl -u $XRAY_SVC -n 50"; restart_failed=1; }
                fi
            fi
        fi
        force=1
    fi
    [[ -n $RESET_DONE ]] && force=1
    sub_regen "$force" || return 1
    [[ -n $restart_failed ]] && return 1
    return 0
}

sync_all() {
    local snap
    fw_guard_ensure
    fw_ports_ensure
    if caddy_stale; then
        warn "Caddyfile does not match the current domain/port, regenerating"
        caddy_gen
        caddy_reload || warn "Caddy reload failed; it will be retried on the next sync"
    fi
    extra_sub_refresh all || warn "Some external subscriptions could not be refreshed; cached nodes were kept"
    snap=$(state_snapshot)
    apply_state "$snap"
}
