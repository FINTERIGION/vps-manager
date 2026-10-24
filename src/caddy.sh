#!/usr/bin/env bash
# vpsm - Caddy config (Reality dest + subscription server)

# Homepage of versions <= 1.2.0, identical on every install; replaced so it cannot be used to find nodes
CADDY_OLD_INDEX='<h1>It works!</h1><p>This site is under construction.</p>'

rand_pick() { printf '%s\n' "$@" | shuf -n "${PICK_N:-1}"; }

# Print a decoy homepage whose title, wording, fonts, colors and layout are randomized per install
caddy_gen_index() {
    local title hue font width body year days d t
    title="$(rand_pick Quiet Northern Little Open Simple Bright Silver Paper Slow Green Small Blue Lucky Golden Wild Rainy) $(
        rand_pick Notes Garden Studio Workshop Journal Corner Field Harbor Atlas Notebook Archive Kitchen Lantern Orchard)"
    hue=$((RANDOM % 360))
    width=$((560 + RANDOM % 9 * 40))
    font=$(rand_pick "Georgia, serif" "system-ui, sans-serif" "Helvetica, Arial, sans-serif" "Palatino, 'Book Antiqua', serif" \
        "Verdana, Geneva, sans-serif" "-apple-system, 'Segoe UI', Roboto, sans-serif" "'Trebuchet MS', sans-serif")
    year=$(date +%Y)
    case $((RANDOM % 3)) in
        0)
            body="<h1>$title</h1>
<p>$(rand_pick "A new site is on its way." "Something new is coming soon." "We are rebuilding this site." "This page is being redesigned.")</p>
<p>$(rand_pick "Please check back in a few weeks." "Thanks for your patience." "Stay tuned." "See you soon.")</p>"
            ;;
        1)
            body="<header><h1>$title</h1><p>$(rand_pick "Thoughts, notes and small projects." "A personal space on the web." \
                "Writing about everyday things." "Photos, recipes and the occasional essay." "Notes from a slow life.")</p></header>
<main>"
            days=$((RANDOM % 20 + 3))
            while IFS= read -r t; do
                d=$(LC_ALL=C date -d "-$days days" '+%B %-d, %Y')
                body+="
<article><h2>$t</h2><p><small>$d</small></p></article>"
                days=$((days + RANDOM % 60 + 7))
            done < <(PICK_N=$((RANDOM % 3 + 3)) rand_pick "Brewing better coffee at home" "A weekend in the mountains" \
                "Getting started with sourdough" "A simpler desktop setup" "What I read this month" "Fixing an old bicycle" \
                "Small changes to my daily routine" "Learning to take better photos" "Tomatoes on the balcony" \
                "A short walk through the old town" "Notes on a rainy afternoon" "Cleaning up my bookshelf")
            body+="
</main>"
            ;;
        *)
            body="<h1>$title</h1>
<p>$(rand_pick "Hi, welcome to my little corner of the internet." "Hello and welcome." "Thanks for stopping by.")</p>
<p>$(rand_pick "I write about books, travel and things I build in my spare time." \
                "This is where I keep notes on cooking, photography and long walks." \
                "Here you will find a few projects and the occasional post.")</p>
<p>$(rand_pick "New posts are coming soon." "More content will be added over time." "The archive is being moved here.")</p>"
            ;;
    esac
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
body{font-family:$font;max-width:${width}px;margin:$((5 + RANDOM % 10))vh auto;padding:0 1em;color:#333;line-height:1.6}
h1,h2{color:hsl($hue,45%,35%)}a{color:hsl($hue,55%,40%)}small,footer{color:#999}footer{margin-top:3em;font-size:.85em}
</style>
</head>
<body>
$body
<footer>&copy; $year $title</footer>
</body>
</html>
EOF
}

# True when Caddyfile is missing or its domain / HTTPS redirect port do not match users.json
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
    grep -qF "$want" "$CADDYFILE" && grep -qF "$domain:$CADDY_PORT {" "$CADDYFILE" && return 1
    return 0
}

# Generate the Caddyfile and the decoy homepage
caddy_gen() {
    local domain port
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port')
    [[ $port == 443 ]] && port="" || port=":$port"
    mkdir -p "$CADDY_DIR" "$WWW_DIR"
    chmod 755 "$CADDY_DIR" "$WWW_DIR"
    svc_dir "$CADDY_USERS"

    if [[ ! -f $WWW_DIR/index.html ]] || grep -qF "$CADDY_OLD_INDEX" "$WWW_DIR/index.html"; then
        caddy_gen_index >"$WWW_DIR/index.html"
        chmod 644 "$WWW_DIR/index.html"
    fi

    # Xray owns 443; Caddy listens only on 127.0.0.1:8443 and obtains certificates via HTTP-01 on port 80.
    # "bind" also restricts the ACME challenge listener to 127.0.0.1, so the public http:// site is
    # required: Caddy then answers HTTP-01 challenges from its own :80 server, ahead of the redirect
    # The admin API has no authentication: a unix socket in a vpsm-only directory instead of localhost:2019
    cat >"$CADDYFILE" <<EOF
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

# Error responses skip the site's header directives, so they need their own to also drop "Server"
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
	# Unknown /sub/ paths fall through to file_server, so they 404 exactly like any other missing page
	import $CADDY_USERS/*.conf
	handle {
		file_server
	}
}

http://$domain {
	import site
	redir https://$domain$port{uri} permanent
}
EOF
    chmod 644 "$CADDYFILE"
    fix_perms
}

# A reload goes through the admin endpoint of the new config, so it fails when that endpoint changed
# (e.g. after upgrading from localhost:2019 to the unix socket): fall back to a restart
caddy_reload() {
    if ! svc_active "$CADDY_SVC"; then
        return 0
    fi
    svc reload "$CADDY_SVC" 2>/dev/null || svc restart "$CADDY_SVC" || warn "Caddy reload failed, check: vpsm log caddy"
}
