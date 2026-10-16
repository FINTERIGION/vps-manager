#!/usr/bin/env bash
# vpsm - Caddy config (Reality dest + subscription server)

# Generate the Caddyfile and the decoy homepage
caddy_gen() {
    local domain
    domain=$(db_get '.settings.domain')
    mkdir -p "$CADDY_DIR" "$WWW_DIR"
    chmod 755 "$CADDY_DIR" "$WWW_DIR"
    svc_dir "$CADDY_USERS"

    if [[ ! -f $WWW_DIR/index.html ]]; then
        cat >"$WWW_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Welcome</title>
<style>body{font-family:sans-serif;max-width:40em;margin:15vh auto;color:#444;text-align:center}</style>
</head>
<body><h1>It works!</h1><p>This site is under construction.</p></body>
</html>
EOF
        chmod 644 "$WWW_DIR/index.html"
    fi

    # Xray owns 443; Caddy listens only on 127.0.0.1:8443 and obtains certificates via HTTP-01 on port 80.
    # "bind" also restricts the ACME challenge listener to 127.0.0.1, so the public http:// site is
    # required: Caddy then answers HTTP-01 challenges from its own :80 server
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

$domain:$CADDY_PORT {
	bind 127.0.0.1
	tls {
		issuer acme {
			disable_tlsalpn_challenge
		}
	}
	root * $WWW_DIR
	header -Server
	import $CADDY_USERS/*.conf
	handle /sub/* {
		respond "Not Found" 404
	}
	handle {
		file_server
	}
}

http://$domain {
	root * $WWW_DIR
	header -Server
	file_server
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
