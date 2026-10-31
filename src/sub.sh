#!/usr/bin/env bash
# vpsm - one Clash/Mihomo YAML and one Caddy route per user

sub_server_rules() {
    local domain
    domain=$(db_get '.settings.domain')
    echo "DOMAIN-SUFFIX,$domain,DIRECT"
    {
        self_ips | jq -r '.[]'
        timeout 5 getent ahosts "$domain" 2>/dev/null | awk '{print $1}'
    } | awk '
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            split($0, o, ".")
            if (o[1] == 0 || o[1] == 10 || o[1] == 127 || (o[1] == 169 && o[2] == 254) ||
                (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168) ||
                (o[1] == 100 && o[2] >= 64 && o[2] <= 127)) next
            print "IP-CIDR," $0 "/32,DIRECT,no-resolve"
            next
        }
        /:/ {
            a = tolower($0)
            if (a == "::1" || a ~ /^::ffff:/ || a ~ /^fe[89ab]/ || a ~ /^f[cd]/) next
            print "IP-CIDR6," a "/128,DIRECT,no-resolve"
        }' | sort -u
}

sub_render_clash() {
    local name=$1 uuid=$2 sf=$3 ef=${4:-} nf=${5:-} domain port pbk sid node mlkem
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    pbk=$(db_get '.settings.public_key')
    sid=$(db_get '.settings.short_ids[0]')
    node=$(local_proxy_name)
    if xray_mlkem_ok; then mlkem=true; else mlkem=false; fi
    awk -v node="$node" -v server="$domain" -v port="$port" -v uuid="$uuid" \
        -v pbk="$pbk" -v sid="$sid" -v sni="$domain" -v user="$name" -v mlkem="$mlkem" \
        -v cf="$CUSTOM_RULES" -v sf="$sf" -v ef="$ef" -v nf="$nf" '
        function rep(s, k, v,   i, out) {
            out = ""
            while ((i = index(s, k)) > 0) {
                out = out substr(s, 1, i - 1) v
                s = substr(s, i + length(k))
            }
            return out s
        }
        function rules(f,   line) {
            while ((getline line < f) > 0) {
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == "" || line ~ /^#/) continue
                sub(/^-[ \t]*/, "", line)
                print "  - " line
            }
            close(f)
        }
        function dump(f,   line) {
            if (f == "") return
            while ((getline line < f) > 0) print line
            close(f)
        }
        /^[[:space:]]*#[[:space:]]*__CUSTOM_RULES__/ { rules(cf); next }
        /^[[:space:]]*#[[:space:]]*__SERVER_RULES__/ { rules(sf); next }
        /^[[:space:]]*#[[:space:]]*__EXTRA_PROXIES__/ { dump(ef); next }
        /^[[:space:]]*#[[:space:]]*__EXTRA_NAMES__/ { dump(nf); next }
        {
            $0 = rep($0, "__NODE__", node); $0 = rep($0, "__SERVER__", server)
            $0 = rep($0, "__PORT__", port); $0 = rep($0, "__UUID__", uuid)
            $0 = rep($0, "__PBK__", pbk); $0 = rep($0, "__SID__", sid)
            $0 = rep($0, "__SNI__", sni); $0 = rep($0, "__USER__", user)
            $0 = rep($0, "__MLKEM__", mlkem)
            print
        }' "$SH_DIR/templates/clash.yaml"
}

sub_userinfo_line() {
    local quota=$1 up=$2 down=$3 expire=$4 info exp_ts
    info="upload=$up; download=$down"
    ((quota > 0)) && info+="; total=$quota"
    if [[ $expire =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        exp_ts=$(date -d "$expire 23:59:59" +%s 2>/dev/null) && [[ -n $exp_ts ]] && info+="; expire=$exp_ts"
    fi
    printf '%s' "$info"
}

sub_render_caddy() {
    local fname=$1 token=$2 quota=$3 up=$4 down=$5 expire=$6 info
    info=$(sub_userinfo_line "$quota" "$up" "$down" "$expire")
    cat <<EOF
handle /sub/$token {
	root * $SUB_DIR
	rewrite * /$token.yaml
	header Content-Type "text/yaml; charset=utf-8"
	header Content-Disposition "attachment; filename*=UTF-8''$fname"
	header subscription-userinfo "$info"
	header profile-update-interval 12
	header Cache-Control "no-store"
	file_server
}
EOF
}

sub_regen() {
    local force=${1:-} age stage changed="" full="" reload_pending="" f b fname expire
    local name uuid token quota up down yamls=()
    if [[ -n $force || ! -f $SUB_STAMP ]]; then
        full=1
    else
        age=$(($(date +%s) - $(stat -c %Y "$SUB_STAMP")))
        ((age >= SUB_REFRESH)) && full=1
    fi
    [[ -f $SUB_RELOAD_PENDING ]] && reload_pending=1
    stage=$(mktemp -d "$ROOT/.stage.XXXXXX") || return 1
    mkdir -p "$stage/users"
    fname=$(urlencode "$(sub_name)")
    expire=$(db_get '.settings.expire // ""')
    if [[ -n $full ]]; then
        mkdir -p "$stage/sub" "$stage/ex"
        sub_server_rules >"$stage/ex/server-rules"
        if ! extra_sub_stage "$stage/ex"; then
            rm -rf "$stage"
            warn "External proxy names are invalid; subscriptions were not changed"
            return 1
        fi
    fi

    while IFS='|' read -r name uuid token quota up down; do
        [[ -n $name ]] || continue
        valid_name "$name" || continue
        [[ $token =~ ^[0-9A-Za-z]{16,64}$ ]] || continue
        is_uint "$quota" || quota=0
        is_uint "$up" || up=0
        is_uint "$down" || down=0
        sub_render_caddy "$fname" "$token" "$quota" "$up" "$down" "$expire" \
            >"$stage/users/$name.conf" ||
            { rm -rf "$stage"; warn "Failed to render the subscription info for $name"; return 1; }
        [[ -n $full ]] || continue
        sub_render_clash "$name" "$uuid" "$stage/ex/server-rules" \
            "$stage/ex/proxies" "$stage/ex/names" >"$stage/sub/$token.yaml" ||
            { rm -rf "$stage"; warn "Failed to render the subscription for $name"; return 1; }
    done < <(jq -r '.users[] | select(.disabled_reason != "manual" and .disabled_reason != "expired")
        | "\(.name)|\(.uuid)|\(.token)|\(.quota)|\(.up)|\(.down)"' "$DB")

    if [[ -n $full ]]; then
        yamls=("$stage"/sub/*.yaml)
        if [[ -e ${yamls[0]} ]]; then
            if ! python3 - "${yamls[@]}" <<'PY'
import sys
import yaml
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            yaml.safe_load(handle)
    except Exception as exc:
        print(f"{path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
PY
            then
                rm -rf "$stage"
                warn "Generated subscriptions are not valid YAML; subscriptions were not changed"
                return 1
            fi
        fi
    fi

    if ! diff -rq "$stage/users" "$CADDY_USERS" >/dev/null 2>&1; then
        changed=1
        rm -rf "$CADDY_USERS"
        svc_dir "$CADDY_USERS"
        for f in "$stage"/users/*.conf; do
            [[ -e $f ]] || continue
            install -m 644 "$f" "$CADDY_USERS/${f##*/}" ||
                { rm -rf "$stage"; warn "Failed to install the subscription info"; return 1; }
        done
    fi

    if [[ -n $full ]]; then
        svc_dir "$SUB_DIR"
        for f in "$stage"/sub/*.yaml; do
            [[ -e $f ]] || continue
            b=${f##*/}
            if ! cmp -s "$f" "$SUB_DIR/$b"; then
                install -m 644 "$f" "$SUB_DIR/$b" ||
                    { rm -rf "$stage"; warn "Failed to install subscription $b"; return 1; }
            fi
        done
        for f in "$SUB_DIR"/*.yaml; do
            [[ -e $f ]] || continue
            [[ -e $stage/sub/${f##*/} ]] || rm -f "$f"
        done
        touch "$SUB_STAMP"
    fi
    rm -rf "$stage"

    if [[ -n $changed || -n $reload_pending ]]; then
        if ! caddy_reload; then
            touch "$SUB_RELOAD_PENDING"
            [[ -n $full ]] && rm -f "$SUB_STAMP"
            return 1
        fi
        rm -f "$SUB_RELOAD_PENDING"
    fi
    return 0
}
