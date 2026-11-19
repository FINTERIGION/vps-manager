#!/usr/bin/env bash
# vpsm - external Clash/Mihomo subscriptions shared by every user

EXTRA_MAX_BYTES=10485760

extra_sub_count() { db_get '(.settings.extra_subs // []) | length'; }

extra_sub_get() {
    db_get --arg a "$1" ".settings.extra_subs[]? | select(.alias == \$a) | $2"
}

extra_sub_exists() { [[ -n $(extra_sub_get "$1" '.alias') ]]; }

extra_sub_list() {
    local count
    count=$(extra_sub_count)
    if ((count == 0)); then
        msg "No external subscriptions yet, add one with: vpsm attach <alias> <URL> [filter]"
        return 0
    fi
    printf '%-16s %-24s %s\n' ALIAS FILTER URL
    db_get '.settings.extra_subs[] | "\(.alias)\t\(if (.filter // "") == "" then "-" else .filter end)\t\(.url)"' |
        while IFS=$'\t' read -r alias filter url; do
            printf '%-16s %-24s %s\n' "$alias" "$filter" "$url"
        done
}

extra_sub_check_filter() {
    timeout 20 python3 "$SH_DIR/src/extra_sub.py" check-filter "${1:-}" ||
        err "Invalid filter regular expression: ${1:-}"
}

extra_sub_check_url() {
    local strict_flag=()
    [[ -z ${VPSM_NO_SERVICE:-} ]] && strict_flag=(--strict)
    timeout 20 python3 "$SH_DIR/src/extra_sub.py" check-url "${strict_flag[@]}" "${1:-}" ||
        err "Invalid or forbidden subscription URL (cannot point to private, loopback, or cloud metadata addresses)"
}

extra_sub_fetch() {
    local alias=$1 url=$2 filter=${3:-} dest_dir=${4:-$SUB_EXTRA}
    local stamp="$dest_dir/$alias.stamp" tmp size rc hop cur_url resolve_arg meta code redir max_kb
    local strict_flag=() curl_opts=()
    [[ -z ${VPSM_NO_SERVICE:-} ]] && strict_flag=(--strict)
    [[ $url =~ ^https?:// ]] || { warn "External subscription $alias has an invalid URL"; return 1; }
    tmp=$(mktemp -d "$ROOT/.extra.XXXXXX") || return 1
    cur_url=$url
    for hop in 0 1 2 3; do
        if ! resolve_arg=$(timeout 20 python3 "$SH_DIR/src/extra_sub.py" check-url "${strict_flag[@]}" --print-resolve "$cur_url" 2>/dev/null); then
            rm -rf "$tmp"
            warn "External subscription $alias has a forbidden or unresolvable URL"
            return 1
        fi
        curl_opts=()
        [[ -n $resolve_arg ]] && curl_opts+=(--resolve "$resolve_arg")
        rm -f "$tmp/headers" "$tmp/source.yaml"
        # Disable curl's built-in -L redirect following so each hop is SSRF-validated
        # before connecting, pin DNS via --resolve when resolved, and enforce a kernel
        # RLIMIT_FSIZE cap so chunked streams on older curl (< 8.4) cannot exhaust disk.
        max_kb=$(((EXTRA_MAX_BYTES + 1023) / 1024))
        rc=0
        meta=$(
            ulimit -c 0 2>/dev/null || true
            ulimit -f "$max_kb" 2>/dev/null || true
            exec curl -fsS --max-redirs 0 --retry 2 --connect-timeout 10 --max-time 45 \
                --max-filesize "$EXTRA_MAX_BYTES" --proto '=http,https' \
                "${curl_opts[@]}" -A "$EXTRA_UA" -D "$tmp/headers" -o "$tmp/source.yaml" \
                -w '%{http_code}\t%{redirect_url}' "$cur_url"
        ) || rc=$?
        if ((rc != 0)); then
            rm -rf "$tmp"
            if ((rc == 22)); then
                warn "Failed to download external subscription $alias (HTTP error, the URL may be expired or blocked)"
            elif ((rc == 63 || rc == 23 || rc == 153)); then
                warn "Failed to download external subscription $alias (file exceeds ${EXTRA_MAX_BYTES} bytes)"
            else
                warn "Failed to download external subscription $alias (curl exit $rc)"
            fi
            return 1
        fi
        IFS=$'\t' read -r code redir <<<"$meta"
        if [[ -z $redir && -f $tmp/headers ]]; then
            redir=$(awk 'tolower($1) == "location:" { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$tmp/headers")
        fi
        if [[ $code == 30[12378] && -n $redir ]]; then
            if ((hop == 3)); then
                rm -rf "$tmp"
                warn "Failed to download external subscription $alias (too many redirects)"
                return 1
            fi
            if ! cur_url=$(timeout 20 python3 "$SH_DIR/src/extra_sub.py" resolve-redirect "${strict_flag[@]}" "$cur_url" "$redir" 2>/dev/null); then
                rm -rf "$tmp"
                warn "External subscription $alias redirected to a forbidden URL"
                return 1
            fi
            continue
        fi
        break
    done
    size=$(stat -c %s "$tmp/source.yaml" 2>/dev/null || echo 0)
    if ! is_uint "$size" || ((size == 0 || size > EXTRA_MAX_BYTES)); then
        rm -rf "$tmp"
        warn "External subscription $alias is empty or too large"
        return 1
    fi
    if ! timeout 20 python3 "$SH_DIR/src/extra_sub.py" normalize "$tmp/source.yaml" "$filter" \
        "$tmp/proxies.yaml" "$tmp/names.yaml"; then
        rm -rf "$tmp"
        warn "External subscription $alias was rejected"
        return 1
    fi
    # Refuse a provider update that renames a node onto the local node, keeping the last good cache
    if ! timeout 20 python3 "$SH_DIR/src/extra_sub.py" check-names "$tmp/names.yaml" "$(local_proxy_name)"; then
        rm -rf "$tmp"
        warn "External subscription $alias conflicts with the local node name"
        return 1
    fi
    mkdir -p "$dest_dir"
    [[ $dest_dir == "$SUB_EXTRA" ]] && chmod 700 "$SUB_EXTRA"
    install -m 600 "$tmp/proxies.yaml" "$dest_dir/$alias.proxies.yaml.new"
    install -m 600 "$tmp/names.yaml" "$dest_dir/$alias.names.yaml.new"
    mv -f "$dest_dir/$alias.proxies.yaml.new" "$dest_dir/$alias.proxies.yaml"
    mv -f "$dest_dir/$alias.names.yaml.new" "$dest_dir/$alias.names.yaml"
    touch "$stamp"
    chmod 600 "$stamp"
    rm -rf "$tmp"
    msg "External subscription $alias refreshed"
}

extra_sub_attach() {
    local alias=${1:-} url=${2:-} filter=${3:-}
    valid_name "$alias" || err "Alias may only contain letters, digits, underscores and hyphens, length 1-32"
    [[ -n $url ]] || err "Usage: vpsm attach <alias> <Clash/Mihomo URL> [filter regex]"
    [[ $url =~ ^https?:// ]] || err "Only HTTP/HTTPS subscription URLs are supported"
    extra_sub_exists "$alias" && err "External subscription $alias already exists"
    extra_sub_check_url "$url"
    extra_sub_check_filter "$filter"
    extra_sub_fetch "$alias" "$url" "$filter" || err "External subscription was not attached"
    db_write --arg a "$alias" --arg u "$url" --arg f "$filter" \
        '.settings.extra_subs = ((.settings.extra_subs // []) + [{alias:$a,url:$u,filter:$f}])'
    if ! ( sub_regen force ); then
        db_write --arg a "$alias" \
            '.settings.extra_subs = ((.settings.extra_subs // []) | map(select(.alias != $a)))'
        rm -f "$SUB_EXTRA/$alias".*.yaml "$SUB_EXTRA/$alias.stamp"
        ( sub_regen force ) || warn "Subscriptions were not regenerated after rolling back $alias"
        err "External subscription $alias was not attached"
    fi
    rm -f "$EXTRA_REFRESH_STAMP" "$EXTRA_ATTEMPT_STAMP"
    ok "External subscription $alias attached, every user now sees its nodes"
}

extra_sub_detach() {
    local alias=${1:-} bak db_snap f
    [[ -n $alias ]] || err "Usage: vpsm detach <alias>"
    extra_sub_exists "$alias" || err "External subscription $alias does not exist"
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    bak=$(mktemp -d "$ROOT/.extra.bak.XXXXXX") || { rm -f "$db_snap"; err "Failed to back up user data"; }
    for f in "$SUB_EXTRA/$alias".*.yaml "$SUB_EXTRA/$alias.stamp"; do
        [[ -e $f ]] && cp -a "$f" "$bak/"
    done
    db_write --arg a "$alias" \
        '.settings.extra_subs = ((.settings.extra_subs // []) | map(select(.alias != $a)))'
    rm -f "$SUB_EXTRA/$alias".*.yaml "$SUB_EXTRA/$alias.stamp"
    if ! ( sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        mkdir -p "$SUB_EXTRA"
        for f in "$bak"/*; do
            [[ -e $f ]] || continue
            cp -a "$f" "$SUB_EXTRA/"
        done
        rm -rf "$bak"
        db_rollback_runtime
        err "External subscription $alias was not detached"
    fi
    rm -rf "$bak"
    rm -f "$db_snap" "$EXTRA_REFRESH_STAMP" "$EXTRA_ATTEMPT_STAMP"
    ok "External subscription $alias detached from every user"
}

extra_sub_set_filter() {
    local alias=${1:-} filter=${2:-} url bak db_snap f
    [[ -n $alias && $# -ge 2 ]] || err "Usage: vpsm filter <alias> <regex|0>"
    extra_sub_exists "$alias" || err "External subscription $alias does not exist"
    [[ $filter == 0 || $filter == - ]] && filter=""
    extra_sub_check_filter "$filter"
    url=$(extra_sub_get "$alias" '.url')
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    bak=$(mktemp -d "$ROOT/.extra.bak.XXXXXX") || { rm -f "$db_snap"; err "Failed to back up user data"; }
    for f in "$SUB_EXTRA/$alias".*.yaml "$SUB_EXTRA/$alias.stamp"; do
        [[ -e $f ]] && cp -a "$f" "$bak/"
    done
    db_write --arg a "$alias" --arg f "$filter" \
        '.settings.extra_subs |= map(if .alias == $a then .filter = $f else . end)'
    if ! ( extra_sub_fetch "$alias" "$url" "$filter" && sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        mkdir -p "$SUB_EXTRA"
        for f in "$bak"/*; do
            [[ -e $f ]] || continue
            cp -a "$f" "$SUB_EXTRA/"
        done
        rm -rf "$bak"
        db_rollback_runtime
        err "Filter for external subscription $alias was not changed"
    fi
    rm -rf "$bak"
    rm -f "$db_snap" "$EXTRA_REFRESH_STAMP" "$EXTRA_ATTEMPT_STAMP"
    ok "Filter for external subscription $alias set to ${filter:-none}, every user is affected"
}

extra_sub_refresh() {
    local target=${1:-all} force=${2:-} alias url filter rc=0 changed="" stamp before after
    if [[ $target != all ]]; then
        extra_sub_exists "$target" || err "External subscription $target does not exist"
    fi
    while IFS=$'\t' read -r alias url filter; do
        [[ -n $alias ]] || continue
        stamp="$SUB_EXTRA/$alias.stamp"
        before=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
        extra_sub_fetch "$alias" "$url" "$filter" || rc=1
        after=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
        [[ $before != "$after" ]] && changed=1
    done < <(db_get --arg a "$target" '.settings.extra_subs[]? | select($a == "all" or .alias == $a)
        | "\(.alias)\t\(.url)\t\(.filter // "")"')
    if [[ $force == force || -n $changed ]]; then
        rm -f "$SUB_STAMP"
        sub_regen force || rc=1
    fi
    return "$rc"
}

extra_sub_async_refresh() {
    local force=${1:-} count now last
    if [[ $force != force ]]; then
        now=$(date +%s)
        if [[ -f $EXTRA_REFRESH_STAMP ]] && ((EXTRA_REFRESH_MIN > 0)); then
            last=$(stat -c %Y "$EXTRA_REFRESH_STAMP" 2>/dev/null || echo 0)
            if ((now - last < EXTRA_REFRESH_MIN)); then
                return 0
            fi
        fi
        if [[ -f $EXTRA_ATTEMPT_STAMP ]] && ((EXTRA_RETRY_MIN > 0)); then
            last=$(stat -c %Y "$EXTRA_ATTEMPT_STAMP" 2>/dev/null || echo 0)
            if ((now - last < EXTRA_RETRY_MIN)); then
                return 0
            fi
        fi
    fi
    count=$(extra_sub_count)
    ((count > 0)) || return 0

    mkdir -p "$ROOT"
    exec 8>"$EXTRA_LOCK_FILE"
    flock -n 8 || return 0

    if [[ $force != force ]]; then
        now=$(date +%s)
        if [[ -f $EXTRA_REFRESH_STAMP ]] && ((EXTRA_REFRESH_MIN > 0)); then
            last=$(stat -c %Y "$EXTRA_REFRESH_STAMP" 2>/dev/null || echo 0)
            if ((now - last < EXTRA_REFRESH_MIN)); then
                return 0
            fi
        fi
        if [[ -f $EXTRA_ATTEMPT_STAMP ]] && ((EXTRA_RETRY_MIN > 0)); then
            last=$(stat -c %Y "$EXTRA_ATTEMPT_STAMP" 2>/dev/null || echo 0)
            if ((now - last < EXTRA_RETRY_MIN)); then
                return 0
            fi
        fi
    fi
    local tmp alias url filter changed="" any_ok=""
    tmp=$(mktemp -d "$ROOT/.extra.async.XXXXXX") || return 1

    while IFS=$'\t' read -r alias url filter; do
        [[ -n $alias && -n $url ]] || continue
        if extra_sub_fetch "$alias" "$url" "$filter" "$tmp"; then
            any_ok=1
            printf '%s\t%s\n' "$url" "$filter" >"$tmp/$alias.meta"
            if ! cmp -s "$tmp/$alias.proxies.yaml" "$SUB_EXTRA/$alias.proxies.yaml" 2>/dev/null || \
               ! cmp -s "$tmp/$alias.names.yaml" "$SUB_EXTRA/$alias.names.yaml" 2>/dev/null; then
                changed=1
            fi
        fi
    done < <(db_get '.settings.extra_subs[]? | "\(.alias)\t\(.url)\t\(.filter // "")"')

    touch "$EXTRA_ATTEMPT_STAMP" 2>/dev/null || true
    [[ -n $any_ok ]] && touch "$EXTRA_REFRESH_STAMP" 2>/dev/null || true

    if [[ -z $changed ]]; then
        rm -rf "$tmp"
        return 0
    fi

    (
        acquire_lock || exit 1
        mkdir -p "$SUB_EXTRA"
        chmod 700 "$SUB_EXTRA"
        local updated="" f b alias cur_meta
        for f in "$tmp"/*.proxies.yaml; do
            [[ -e $f ]] || continue
            b=${f##*/}
            alias=${b%.proxies.yaml}
            extra_sub_exists "$alias" || continue
            cur_meta=$(db_get --arg a "$alias" '.settings.extra_subs[]? | select(.alias == $a) | "\(.url)\t\(.filter // "")"')
            [[ -f $tmp/$alias.meta && $cur_meta == "$(<"$tmp/$alias.meta")" ]] || continue
            install -m 600 "$tmp/$alias.proxies.yaml" "$SUB_EXTRA/$alias.proxies.yaml"
            install -m 600 "$tmp/$alias.names.yaml" "$SUB_EXTRA/$alias.names.yaml"
            install -m 600 "$tmp/$alias.stamp" "$SUB_EXTRA/$alias.stamp"
            updated=1
        done
        if [[ -n $updated ]]; then
            rm -f "$SUB_STAMP"
            sub_regen force || warn "Subscriptions were not regenerated after async refresh"
        fi
    )
    rm -rf "$tmp"
    return 0
}

extra_sub_assert_local_name() {
    local candidate=$1 file
    for file in "$SUB_EXTRA"/*.names.yaml; do
        [[ -e $file ]] || continue
        timeout 20 python3 "$SH_DIR/src/extra_sub.py" check-names "$file" "$candidate" || return 1
    done
}

extra_sub_stage() {
    local out=$1 alias
    : >"$out/proxies"
    : >"$out/names"
    while read -r alias; do
        [[ -n $alias ]] || continue
        if [[ ! -s $SUB_EXTRA/$alias.proxies.yaml || ! -s $SUB_EXTRA/$alias.names.yaml ]]; then
            warn "No valid cache for external subscription $alias; its nodes are unavailable"
            continue
        fi
        cat "$SUB_EXTRA/$alias.proxies.yaml" >>"$out/proxies"
        cat "$SUB_EXTRA/$alias.names.yaml" >>"$out/names"
    done < <(db_get '.settings.extra_subs[]?.alias')
    timeout 20 python3 "$SH_DIR/src/extra_sub.py" check-names "$out/names" "$(local_proxy_name)"
}

# Move caches from the retired per-user layout ($SUB_EXTRA/<user>/<alias>.*) to the shared layout
extra_sub_migrate() {
    local dir src alias user url keep f dropped
    [[ -f $DB ]] || return 0
    if jq -e 'any(.users[]; ((.extra_subs // []) | length) > 0)' "$DB" >/dev/null 2>&1; then
        dropped=$(jq -r '[.users[] | (.extra_subs // [])[] | .alias]
            | group_by(.) | map(select(length > 1) | .[0]) | unique | join(", ")' "$DB")
        db_write '.settings.extra_subs = (
            ((.settings.extra_subs // []) + [.users[] | (.extra_subs // [])[]])
            | reduce .[] as $s ([];
                if any(.[]; .alias == $s.alias) then .
                else . + [{alias:$s.alias, url:$s.url, filter:($s.filter // "")}] end))'
        [[ -z $dropped ]] || warn "Aliases used by several users kept their first URL only: $dropped"
    fi
    [[ -d $SUB_EXTRA ]] || return 0
    for dir in "$SUB_EXTRA"/*/; do
        [[ -d $dir ]] || continue
        user=${dir%/}
        user=${user##*/}
        for src in "$dir"*.proxies.yaml; do
            [[ -e $src ]] || continue
            alias=${src##*/}
            alias=${alias%.proxies.yaml}
            keep=$(jq -r --arg a "$alias" '.settings.extra_subs[]? | select(.alias == $a) | .url' "$DB" | head -n 1)
            url=$(jq -r --arg n "$user" --arg a "$alias" \
                '.users[]? | select(.name == $n) | .extra_subs[]? | select(.alias == $a) | .url' "$DB" | head -n 1)
            [[ -n $url && -n $keep && $url == "$keep" && ! -e $SUB_EXTRA/$alias.proxies.yaml ]] || continue
            for f in "$dir$alias".proxies.yaml "$dir$alias".names.yaml "$dir$alias.stamp"; do
                [[ -e $f ]] && mv -f "$f" "$SUB_EXTRA/${f##*/}"
            done
        done
        rm -rf "$dir"
    done
    return 0
}
