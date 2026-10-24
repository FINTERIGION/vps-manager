#!/usr/bin/env bash
# vpsm - subscription generation: one Clash (Mihomo) YAML + one Caddy route snippet per user

# Clash rules sending the server itself direct, one per line. The domain's records cover NAT hosts
# whose public IP is not on any interface; private addresses are already direct via lancidr
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

# Render one user's Clash YAML to stdout: sub_render_clash <name> <uuid> <server rules file>
sub_render_clash() {
    local name=$1 uuid=$2 sf=$3 domain port pbk sid node
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    pbk=$(db_get '.settings.public_key')
    sid=$(db_get '.settings.short_ids[0]')
    node=$(node_name)
    # Literal replacement: the node name may contain "&", which gsub would treat as the matched text
    awk -v node="$node" -v server="$domain" -v port="$port" -v uuid="$uuid" \
        -v pbk="$pbk" -v sid="$sid" -v sni="$domain" -v user="$name" \
        -v cf="$CUSTOM_RULES" -v sf="$sf" '
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
        /^[[:space:]]*#[[:space:]]*__CUSTOM_RULES__/ { rules(cf); next }
        /^[[:space:]]*#[[:space:]]*__SERVER_RULES__/ { rules(sf); next }
        {
            $0 = rep($0, "__NODE__", node); $0 = rep($0, "__SERVER__", server); $0 = rep($0, "__PORT__", port)
            $0 = rep($0, "__UUID__", uuid); $0 = rep($0, "__PBK__", pbk); $0 = rep($0, "__SID__", sid)
            $0 = rep($0, "__SNI__", sni); $0 = rep($0, "__USER__", user)
            print
        }' "$SH_DIR/templates/clash.yaml"
}

# Render one user's Caddy snippet to stdout; the filename becomes the subscription (profile) name in clients
# sub_render_caddy <url-encoded filename> <token> <quota> <up> <down> <expire>
sub_render_caddy() {
    local fname=$1 token=$2 quota=$3 up=$4 down=$5 expire=$6 info
    info="upload=$up; download=$down"
    ((quota > 0)) && info+="; total=$quota"
    [[ -n $expire ]] && info+="; expire=$(date -d "$expire 23:59:59" +%s)"
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

# Regenerate all subscription files and Caddy snippets; reload Caddy only when content changed.
# sub_regen [force]: without force, skip if the last run was less than SUB_REFRESH seconds ago
# (traffic numbers change every minute, no need to reload Caddy every time)
sub_regen() {
    local force=${1:-} age stage changed="" f b fname
    local name uuid token quota up down expire
    if [[ -z $force && -f $SUB_STAMP ]]; then
        age=$(($(date +%s) - $(stat -c %Y "$SUB_STAMP")))
        ((age < SUB_REFRESH)) && return 0
    fi
    stage=$(mktemp -d "$ROOT/.stage.XXXXXX") || return 1
    mkdir -p "$stage/sub" "$stage/users"
    fname=$(urlencode "$(node_name)")
    sub_server_rules >"$stage/server-rules"

    while IFS=$'\t' read -r name uuid token quota up down expire; do
        [[ -n $name ]] || continue
        sub_render_clash "$name" "$uuid" "$stage/server-rules" >"$stage/sub/$token.yaml"
        sub_render_caddy "$fname" "$token" "$quota" "$up" "$down" "$expire" >"$stage/users/$name.conf"
    done < <(jq -r '.users[] | [.name, .uuid, .token, .quota, .up, .down, (.expire // "")] | @tsv' "$DB")

    # Caddy snippets
    if ! diff -rq "$stage/users" "$CADDY_USERS" >/dev/null 2>&1; then
        changed=1
        rm -rf "$CADDY_USERS"
        svc_dir "$CADDY_USERS"
        for f in "$stage"/users/*.conf; do
            [[ -e $f ]] && install -m 644 "$f" "$CADDY_USERS/${f##*/}"
        done
    fi

    # Subscription YAML
    svc_dir "$SUB_DIR"
    for f in "$stage"/sub/*.yaml; do
        [[ -e $f ]] || continue
        b=${f##*/}
        cmp -s "$f" "$SUB_DIR/$b" || install -m 644 "$f" "$SUB_DIR/$b"
    done
    for f in "$SUB_DIR"/*.yaml; do
        [[ -e $f ]] || continue
        [[ -e $stage/sub/${f##*/} ]] || rm -f "$f"
    done

    rm -rf "$stage"
    touch "$SUB_STAMP"
    [[ -n $changed ]] && caddy_reload
    return 0
}
