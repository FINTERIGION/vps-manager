#!/usr/bin/env bash
# vpsm - per-user external Clash/Mihomo subscriptions

EXTRA_MAX_BYTES=10485760

extra_dir() { printf '%s/%s\n' "$SUB_EXTRA" "$1"; }

extra_sub_list() {
    require_user "${1:-}"
    local count
    count=$(user_get "$1" '(.extra_subs // []) | length')
    if ((count == 0)); then
        msg "No external subscriptions for user $1"
        return 0
    fi
    printf '%-20s %s\n' ALIAS URL
    user_get "$1" '.extra_subs[] | "\(.alias)\t\(.url)"' | while IFS=$'\t' read -r alias url; do
        printf '%-20s %s\n' "$alias" "$url"
    done
}

extra_sub_fetch() {
    local name=$1 alias=$2 url=$3 force=${4:-} dir stamp age tmp size
    dir=$(extra_dir "$name")
    stamp="$dir/$alias.stamp"
    if [[ -z $force && -f $stamp && -f $dir/$alias.proxies.yaml && -f $dir/$alias.names.yaml ]]; then
        age=$(($(date +%s) - $(stat -c %Y "$stamp")))
        ((age < EXTRA_REFRESH)) && return 0
    fi
    [[ $url =~ ^https?:// ]] || { warn "External subscription $alias for $name has an invalid URL"; return 1; }
    tmp=$(mktemp -d "$ROOT/.extra.XXXXXX") || return 1
    if ! curl -fSL --retry 2 --connect-timeout 10 --max-time 45 \
        --max-filesize "$EXTRA_MAX_BYTES" --proto '=http,https' --proto-redir '=http,https' \
        -o "$tmp/source.yaml" "$url"; then
        rm -rf "$tmp"
        warn "Failed to download external subscription $alias for $name"
        return 1
    fi
    size=$(stat -c %s "$tmp/source.yaml" 2>/dev/null || echo 0)
    if ! is_uint "$size" || ((size == 0 || size > EXTRA_MAX_BYTES)); then
        rm -rf "$tmp"
        warn "External subscription $alias for $name is empty or too large"
        return 1
    fi
    if ! python3 "$SH_DIR/src/extra_sub.py" normalize "$tmp/source.yaml" "$alias" \
        "$tmp/proxies.yaml" "$tmp/names.yaml"; then
        rm -rf "$tmp"
        warn "External subscription $alias for $name was rejected"
        return 1
    fi
    mkdir -p "$dir"
    chmod 700 "$SUB_EXTRA" "$dir"
    install -m 600 "$tmp/proxies.yaml" "$dir/$alias.proxies.yaml.new"
    install -m 600 "$tmp/names.yaml" "$dir/$alias.names.yaml.new"
    mv -f "$dir/$alias.proxies.yaml.new" "$dir/$alias.proxies.yaml"
    mv -f "$dir/$alias.names.yaml.new" "$dir/$alias.names.yaml"
    touch "$stamp"
    chmod 600 "$stamp"
    rm -rf "$tmp"
    msg "External subscription $alias for $name refreshed"
}

user_attach() {
    require_user "${1:-}"
    local name=$1 alias=${2:-} url=${3:-} dir
    valid_name "$alias" || err "Alias may only contain letters, digits, underscores and hyphens, length 1-32"
    [[ -n $url ]] || err "Usage: vpsm attach <user> <alias> <Clash/Mihomo URL>"
    [[ $url =~ ^https?:// ]] || err "Only HTTP/HTTPS subscription URLs are supported"
    [[ $(db_get --arg n "$name" --arg a "$alias" '.users[] | select(.name == $n) | .extra_subs[]? | select(.alias == $a) | .alias') ]] &&
        err "Alias $alias already exists for user $name"
    extra_sub_fetch "$name" "$alias" "$url" force || err "External subscription was not attached"
    dir=$(extra_dir "$name")
    if ! python3 "$SH_DIR/src/extra_sub.py" check-names "$dir/$alias.names.yaml" "$(local_proxy_name)"; then
        rm -f "$dir/$alias.proxies.yaml" "$dir/$alias.names.yaml" "$dir/$alias.stamp"
        err "External subscription $alias conflicts with the local node name or contains duplicate proxy names"
    fi
    db_write --arg n "$name" --arg a "$alias" --arg u "$url" \
        '.users |= map(if .name == $n then .extra_subs = ((.extra_subs // []) + [{alias:$a,url:$u}]) else . end)'
    if ! ( sub_regen force ); then
        db_write --arg n "$name" --arg a "$alias" \
            '.users |= map(if .name == $n then .extra_subs = ((.extra_subs // []) | map(select(.alias != $a))) else . end)'
        rm -f "$dir/$alias.proxies.yaml" "$dir/$alias.names.yaml" "$dir/$alias.stamp"
        ( sub_regen force ) || warn "Subscriptions were not regenerated after rolling back $alias for $name"
        err "External subscription $alias was not attached"
    fi
    ok "External subscription $alias attached to user $name"
}

user_detach() {
    require_user "${1:-}"
    local name=$1 alias=${2:-} dir db_snap cache_bak f
    [[ -n $alias ]] || err "Usage: vpsm detach <user> <alias>"
    [[ $(db_get --arg n "$name" --arg a "$alias" '.users[] | select(.name == $n) | .extra_subs[]? | select(.alias == $a) | .alias') ]] ||
        err "External subscription $alias does not exist for user $name"
    dir=$(extra_dir "$name")
    db_snap=$(db_snapshot) || err "Failed to back up the database"
    cache_bak=$(mktemp -d "$ROOT/.extra.bak.XXXXXX") || { rm -f "$db_snap"; err "Failed to back up user data"; }
    for f in "$dir/$alias.proxies.yaml" "$dir/$alias.names.yaml" "$dir/$alias.stamp"; do
        [[ -e $f ]] && cp -a "$f" "$cache_bak/"
    done
    db_write --arg n "$name" --arg a "$alias" \
        '.users |= map(if .name == $n then .extra_subs = ((.extra_subs // []) | map(select(.alias != $a))) else . end)'
    rm -f "$dir/$alias.proxies.yaml" "$dir/$alias.names.yaml" "$dir/$alias.stamp"
    if ! ( sub_regen force ); then
        db_restore "$db_snap" || warn "Failed to restore the database"
        mkdir -p "$dir"
        for f in "$cache_bak"/*; do
            [[ -e $f ]] || continue
            cp -a "$f" "$dir/"
        done
        rm -rf "$cache_bak"
        db_rollback_runtime
        err "External subscription $alias was not detached from user $name"
    fi
    rm -rf "$cache_bak"
    rm -f "$db_snap"
    ok "External subscription $alias detached from user $name"
}

extra_sub_refresh() {
    local target=${1:-all} force=${2:-} name alias url rc=0
    if [[ $target != all ]]; then
        require_user "$target"
    fi
    while IFS='|' read -r name alias url; do
        [[ -n $name ]] || continue
        extra_sub_fetch "$name" "$alias" "$url" "$force" || rc=1
    done < <(jq -r --arg n "$target" '.users[] | select($n == "all" or .name == $n)
        | .name as $name | .extra_subs[]? | "\($name)|\(.alias)|\(.url)"' "$DB")
    if [[ $force == force ]]; then
        sub_regen force
    fi
    return "$rc"
}

extra_sub_assert_local_name() {
    local candidate=$1 file
    for file in "$SUB_EXTRA"/*/*.names.yaml; do
        [[ -e $file ]] || continue
        python3 "$SH_DIR/src/extra_sub.py" check-names "$file" "$candidate" || return 1
    done
}

extra_sub_stage_user() {
    local name=$1 out=$2 alias dir
    : >"$out/proxies"
    : >"$out/names"
    while read -r alias; do
        [[ -n $alias ]] || continue
        dir=$(extra_dir "$name")
        if [[ ! -s $dir/$alias.proxies.yaml || ! -s $dir/$alias.names.yaml ]]; then
            warn "No valid cache for external subscription $alias ($name); its nodes are unavailable"
            continue
        fi
        cat "$dir/$alias.proxies.yaml" >>"$out/proxies"
        cat "$dir/$alias.names.yaml" >>"$out/names"
    done < <(user_get "$name" '.extra_subs[]?.alias')
    python3 "$SH_DIR/src/extra_sub.py" check-names "$out/names" "$(local_proxy_name)"
}
