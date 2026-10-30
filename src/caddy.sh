#!/usr/bin/env bash
# vpsm - Caddy config (Reality dest + subscription server)

CADDY_OLD_INDEX='<h1>It works!</h1><p>This site is under construction.</p>'
rand_pick() { printf '%s\n' "$@" | shuf -n "${PICK_N:-1}"; }

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
<p>$(rand_pick "A new site is on its way." "Something new is coming soon." "We are rebuilding this site." "This page is being redesigned.")</p>
<p>$(rand_pick "Please check back in a few weeks." "Thanks for your patience." "The new content will be available shortly.")</p>"
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
    grep -qF "$want" "$CADDYFILE" && grep -qF "$domain:$CADDY_PORT {" "$CADDYFILE" &&
        grep -qF "vpsm-http-redirect-only" "$CADDYFILE" && return 1
    return 0
}

caddy_gen() {
    local domain port tmp
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    [[ $port == 443 ]] && port="" || port=":$port"
    mkdir -p "$CADDY_DIR" "$WWW_DIR"
    chmod 755 "$WWW_DIR"
    svc_dir "$CADDY_DIR"
    svc_dir "$CADDY_USERS"

    if [[ ! -f $WWW_DIR/index.html ]] || grep -qF "$CADDY_OLD_INDEX" "$WWW_DIR/index.html"; then
        caddy_gen_index >"$WWW_DIR/index.html"
        chmod 644 "$WWW_DIR/index.html"
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
	import site
	import $CADDY_USERS/*.conf
	handle {
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
