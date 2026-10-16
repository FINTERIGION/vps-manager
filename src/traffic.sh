#!/usr/bin/env bash
# vpsm - traffic accounting / quota and expiry checks / monthly reset

# Read and reset counters from Xray, adding them to the database
traffic_pull() {
    xray_active || return 0
    local out
    out=$(timeout 15 "$XRAY_BIN" api statsquery -s "$API_ADDR" -pattern "user>>>" -reset 2>/dev/null) || return 1
    [[ -n $out ]] || return 0
    if ! db_write --argjson raw "$out" '
        (reduce (($raw.stat // [])[]) as $s ({};
            ($s.name | split(">>>")) as $p
            | if ($p | length) == 4 and $p[0] == "user" and $p[2] == "traffic"
              then .[$p[1]][$p[3]] += (($s.value // 0) | tonumber) else . end)) as $t
        | .users |= map(
            ($t[.name] // {}) as $d
            | .up += ($d.uplink // 0)
            | .down += ($d.downlink // 0))' 2>/dev/null; then
        # Counters were already zeroed by -reset; keep the raw data for manual recovery
        echo "$out" >"$ROOT/stats.lost.$(date +%s).json"
        warn "Failed to parse traffic stats, raw data saved to $ROOT/stats.lost.*.json"
        return 1
    fi
}

# Snapshot of each user's enabled state: {"alice":true,"bob":false}
state_snapshot() {
    jq -c '[.users[] | {key: .name, value: .enabled}] | from_entries' "$DB"
}

# Compare a snapshot with the current database, printing "add <name>" / "rm <name>"
state_diff() {
    jq -r --argjson old "$1" '
        (.users | map({key: .name, value: .enabled}) | from_entries) as $new
        | ([.users[] | select(.enabled) | select($old[.name] != true) | "add \(.name)"]
           + [$old | to_entries[] | select(.value == true) | select($new[.key] != true) | "rm \(.key)"])
        | .[]' "$DB"
}

# Monthly reset + recompute each user's enabled state from quota/expiry/manual status
traffic_evaluate() {
    RESET_DONE=""
    local month day rd last
    month=$(date +%Y-%m)
    day=$((10#$(date +%d)))
    rd=$(db_get '.settings.reset_day')
    last=$(db_get '.settings.last_reset')
    if ((day >= rd)) && [[ $last != "$month" ]]; then
        db_write --arg m "$month" '.settings.last_reset = $m | .users |= map(.up = 0 | .down = 0)'
        RESET_DONE=1
        msg "Monthly traffic reset done ($month)"
    fi
    db_write --arg today "$(today)" '
        .users |= map(
            (if .disabled_reason == "manual" then "manual"
             elif (.expire // "") != "" and .expire < $today then "expired"
             elif .quota > 0 and (.up + .down) >= .quota then "quota"
             else "" end) as $r
            | .disabled_reason = $r | .enabled = ($r == ""))'
}

# Call after a command modifies the database: apply_state <state_snapshot before the change> [force]
# Re-evaluates states and applies changes to config.json / the running Xray / subscription files
apply_state() {
    local snap=$1 force=${2:-} changes name op fallback=""
    traffic_pull || warn "Failed to read Xray traffic stats"
    traffic_evaluate
    changes=$(state_diff "$snap")
    # Always regenerated, so a config left stale by an earlier failed command is repaired on the next sync
    xray_gen_config
    [[ -n $changes ]] && force=1
    if [[ -n $XRAY_CONF_CHANGED ]]; then
        if xray_active; then
            # Without user changes the running Xray cannot be patched via the API: restart it
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
                xray_restart
            fi
        fi
        force=1
    fi
    [[ -n $RESET_DONE ]] && force=1
    sub_regen "$force"
}

# Timer entry point: pull traffic -> re-evaluate -> apply changes
sync_all() {
    local snap
    snap=$(state_snapshot)
    apply_state "$snap"
}
