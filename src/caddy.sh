#!/usr/bin/env bash
# vpsm - Caddy config (Reality dest + subscription server)

CADDY_OLD_INDEX='<h1>It works!</h1><p>This site is under construction.</p>'
# The fixed sentences caddy_gen_index emits. They live in one place because
# caddy_index_is_placeholder matches on them to detect a fallback page that has
# silently degraded to a generated placeholder.
CADDY_PLACEHOLDER_LEADS=(
    "A new site is on its way."
    "Something new is coming soon."
    "We are rebuilding this site."
    "This page is being redesigned."
)
CADDY_PLACEHOLDER_TAILS=(
    "Please check back in a few weeks."
    "Thanks for your patience."
    "The new content will be available shortly."
)
# 16x16 RGBA PNG inside a single-entry ICO container (104 bytes), inlined so the
# repository carries no binary file.
CADDY_FAVICON_B64='AAABAAEAEBAAAAEAIABSAAAAFgAAAIlQTkcNChoKAAAADUlIRFIAAAAQAAAAEAgGAAAAH/P/YQAA
ABlJREFUeNpjsPJL+08JZhg1YNSAUQOGiwEAcyjtEFqGvIMAAAAASUVORK5CYII='
rand_pick() { printf '%s\n' "$@" | shuf -n "${PICK_N:-1}"; }

caddy_index_is_placeholder() {
    local f=${1:-$WWW_DIR/index.html} line
    [[ -f $f ]] || return 1
    grep -qF "$CADDY_OLD_INDEX" "$f" && return 0
    for line in "${CADDY_PLACEHOLDER_LEADS[@]}" "${CADDY_PLACEHOLDER_TAILS[@]}"; do
        grep -qF "$line" "$f" && return 0
    done
    return 1
}

# Browsers ask for /favicon.ico and a 404 there is a cheap tell for a site that
# was never really built. Only created when absent, so a favicon shipped by the
# fallback site itself is never overwritten.
caddy_gen_favicon() {
    [[ -f $WWW_DIR/favicon.ico ]] && return 0
    if ! base64 -d >"$WWW_DIR/favicon.ico" <<<"$CADDY_FAVICON_B64"; then
        rm -f "$WWW_DIR/favicon.ico"
        warn "Failed to write $WWW_DIR/favicon.ico"
        return 1
    fi
    chmod 644 "$WWW_DIR/favicon.ico"
    return 0
}

caddy_gen_index() {
    local title hue font width body year
    title="$(rand_pick Quiet Northern Little Open Simple Bright Silver Paper Slow Green Small Blue Lucky Golden Wild Rainy) $(
        rand_pick Notes Garden Studio Workshop Journal Corner Field Harbor Atlas Notebook Archive Kitchen Lantern Orchard)"
    hue=$((RANDOM % 360))
    width=$((560 + RANDOM % 9 * 40))
    font=$(rand_pick "Georgia, serif" "system-ui, sans-serif" "Helvetica, Arial, sans-serif" "Palatino, 'Palatino Linotype', serif" \
        "Verdana, Geneva, sans-serif" "'Segoe UI', sans-serif" "'Trebuchet MS', sans-serif")
    year=$(date +%Y)
    body="<h1>$title</h1>
<p>$(rand_pick "${CADDY_PLACEHOLDER_LEADS[@]}")</p>
<p>$(rand_pick "${CADDY_PLACEHOLDER_TAILS[@]}")</p>"
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$title</title>
<style>
body{font-family:$font;max-width:${width}px;margin:$((5 + RANDOM % 9 * 2))vh auto;padding:0 1em;color:#333;line-height:1.6}
h1{color:hsl($hue,45%,35%)}footer{margin-top:3em;color:#999}
</style>
</head>
<body>
$body
<footer>&copy; $year $title</footer>
</body>
</html>
EOF
}

fv_enabled() {
    [[ -f $DB ]] || return 1
    [[ $(db_get '.settings.futures_view.enabled // false') == true ]]
}

fv_port() {
    db_get '.settings.futures_view.port // 8888'
}

caddy_stale() {
    local domain port want
    [[ -f $CADDYFILE ]] || return 0
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    if [[ $port == 443 ]]; then
        want="redir https://$domain{uri}"
    else
        want="redir https://$domain:$port{uri}"
    fi
    grep -qF "$want" "$CADDYFILE" || return 0
    grep -qF "$domain:$CADDY_PORT" "$CADDYFILE" || return 0
    grep -qF "$CADDY_SUB_LOG" "$CADDYFILE" || return 0
    if fv_enabled; then
        grep -qF "127.0.0.1:$(fv_port)" "$CADDYFILE" || return 0
    else
        grep -qF "127.0.0.1:$(fv_port)" "$CADDYFILE" && return 0
    fi
    grep -qF "vpsm-http-redirect-only" "$CADDYFILE" && return 1
    return 0
}

caddy_gen() {
    local domain port tmp fv_handle=""
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    [[ $port == 443 ]] && port="" || port=":$port"
    mkdir -p "$CADDY_DIR" "$WWW_DIR"
    chmod 755 "$WWW_DIR"
    svc_dir "$CADDY_DIR"
    svc_dir "$CADDY_USERS"
    touch "$CADDY_SUB_LOG"
    chmod 640 "$CADDY_SUB_LOG"

    if [[ ! -f $WWW_DIR/index.html ]] || grep -qF "$CADDY_OLD_INDEX" "$WWW_DIR/index.html"; then
        if fv_enabled; then
            warn "FuturesView is enabled but $WWW_DIR/index.html is missing or stale, so a generated placeholder is being served (run: vpsm fv update)"
        fi
        caddy_gen_index >"$WWW_DIR/index.html"
        chmod 644 "$WWW_DIR/index.html"
    fi
    caddy_gen_favicon

    if fv_enabled; then
        fv_handle="	handle /api/* {
		reverse_proxy 127.0.0.1:$(fv_port)
	}
"
    fi

    tmp=$(mktemp "$CADDY_DIR/.Caddyfile.XXXXXX") || err "Failed to create temporary file"
    cat >"$tmp" <<EOF
{
	admin unix/$CADDY_ADMIN_SOCK
	https_port $CADDY_PORT
	auto_https disable_redirects
	servers {
		protocols h1 h2
	}
	log {
		output stderr
		level WARN
	}
}

(site) {
	root * $WWW_DIR
	header -Server
	handle_errors {
		header -Server
	}
}

$domain:$CADDY_PORT {
	bind 127.0.0.1
	tls {
		issuer acme {
			disable_tlsalpn_challenge
		}
	}
	log {
		output file $CADDY_SUB_LOG {
			roll_size 1MiB
			roll_keep 1
		}
	}
	@not_sub not path /sub/*
	log_skip @not_sub
	import site
	import $CADDY_USERS/*.conf
${fv_handle}	handle {
		try_files {path} /index.html
		file_server
	}
}

http://$domain {
	import site
	# vpsm-http-redirect-only: ACME HTTP-01 and HTTPS redirect
	handle {
		redir https://$domain$port{uri} permanent
	}
}
EOF
    if ! caddy_validate "$tmp"; then
        rm -f "$tmp"
        err "Generated Caddyfile failed validation, not applied"
    fi
    chmod 640 "$tmp"
    mv -f "$tmp" "$CADDYFILE"
    fix_perms
}

caddy_validate() {
    local f=${1:-$CADDYFILE} tmp
    [[ -x $CADDY_BIN ]] || return 0
    tmp=$(mktemp -d) || return 1
    if ! XDG_DATA_HOME=$tmp XDG_CONFIG_HOME=$tmp "$CADDY_BIN" validate --config "$f" --adapter caddyfile \
        >"$tmp/log" 2>&1; then
        tail -n 20 "$tmp/log" >&2
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
}

caddy_reload() {
    if ! svc_active "$CADDY_SVC"; then
        return 0
    fi
    if ! caddy_validate; then
        warn "Caddy config is invalid, keeping the running config (check: vpsm log caddy)"
        return 1
    fi
    if ! svc reload "$CADDY_SVC" 2>/dev/null; then
        if ! svc restart "$CADDY_SVC"; then
            warn "Caddy reload failed, check: vpsm log caddy"
            return 1
        fi
    fi
    return 0
}
