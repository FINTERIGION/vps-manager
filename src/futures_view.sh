#!/usr/bin/env bash
# vpsm - FuturesView deployment, update, and password management

fv_gen_password() {
    local pass=""
    if [[ -r /dev/urandom ]]; then
        pass=$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    if ((${#pass} < 16)) && command -v openssl >/dev/null 2>&1; then
        pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    if ((${#pass} < 16)); then
        pass="Fv$(date +%s)$RANDOM"
    fi
    printf '%s\n' "$pass"
}

fv_apply_password() {
    local pass=$1 py
    py="$FV_DIR/.venv/bin/python"
    [[ -x $py ]] || return 1
    (
        cd "$FV_DIR" && "$py" -c "import sys; from web.auth import set_password; set_password(sys.argv[1])" "$pass"
    ) || return 1
    db_write --arg p "$pass" '.settings.futures_view.password = $p'
}

fv_get_password() {
    db_get '.settings.futures_view.password // ""'
}

fv_status() {
    local state pid rss="-" domain port pwd
    domain=$(db_get '.settings.domain')
    port=$(fv_port)
    pwd=$(fv_get_password)
    echo "=== FuturesView Panel Status ==="
    echo "Enabled:       $(fv_enabled && echo "yes" || echo "no")"
    echo "Repository:    $FV_DIR $([[ -d $FV_DIR/.git ]] && echo "(git $(git -C "$FV_DIR" rev-parse --short HEAD 2>/dev/null || echo "cloned"))" || echo "(not cloned)")"
    echo "Virtualenv:    $([[ -x $FV_DIR/.venv/bin/python ]] && echo "installed ($("$FV_DIR/.venv/bin/python" --version 2>/dev/null))" || echo "missing")"
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        state=$(systemctl is-active "$FV_SVC" 2>/dev/null || echo "unknown")
        if [[ $state == active ]]; then
            pid=$(systemctl show -p MainPID --value "$FV_SVC" 2>/dev/null)
            [[ $pid =~ ^[0-9]+$ && $pid -gt 0 ]] &&
                rss="$(($(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ') / 1024)) MB"
        fi
        echo "Service state: $state (memory: $rss)"
    fi
    echo "Listen addr:   127.0.0.1:$port"
    echo "WebUI URL:     https://$domain"
    echo "WebUI Pass:    ${pwd:-"(none / not set)"}"
}

fv_check_prereqs() {
    local missing=() p
    for p in git python3 curl; do
        command -v "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
        missing+=(python3-venv)
    fi
    if ((${#missing[@]} > 0)); then
        if [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
            msg "Installing required packages: ${missing[*]} ..."
            apt-get update -y && apt-get install -y "${missing[@]}" ||
                err "Failed to install required packages: ${missing[*]}"
        else
            err "Missing required dependencies: ${missing[*]}. Please install them first."
        fi
    fi

    # WebUI toolchain (Vite / Rolldown) requires Node.js >= 20.12 (util.styleText support)
    local node_ver="" node_major=0
    if command -v node >/dev/null 2>&1; then
        node_ver=$(node -v 2>/dev/null || echo "")
        node_major=$(echo "$node_ver" | sed -E 's/^v([0-9]+).*/\1/')
    fi
    [[ $node_major =~ ^[0-9]+$ ]] || node_major=0

    if ((node_major < 20)) || ! command -v npm >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
            msg "Node.js >= 20 is required for WebUI build (found: ${node_ver:-none}). Installing Node.js 22 LTS via NodeSource ..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - &&
                apt-get install -y nodejs ||
                warn "Failed to install Node.js 22 from NodeSource, attempting default package..."
        fi
        node_major=0
        if command -v node >/dev/null 2>&1; then
            node_ver=$(node -v 2>/dev/null || echo "")
            node_major=$(echo "$node_ver" | sed -E 's/^v([0-9]+).*/\1/')
        fi
        [[ $node_major =~ ^[0-9]+$ ]] || node_major=0
        if ((node_major < 20)) || ! command -v npm >/dev/null 2>&1; then
            err "Node.js >= 20 and npm are required (found: ${node_ver:-none}). Please install Node.js 20 or 22: curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs"
        fi
    fi
}

fv_deploy() {
    need_root
    need_installed
    local pass domain port

    echo "=== Deploying FuturesView Web Panel ==="
    fv_check_prereqs

    mkdir -p "${FV_DIR%/*}"
    if [[ ! -d $FV_DIR/.git ]]; then
        msg "Cloning $FV_REPO into $FV_DIR ..."
        git clone "$FV_REPO" "$FV_DIR" || err "Failed to clone $FV_REPO"
    else
        msg "Repository already exists in $FV_DIR, updating..."
        git -C "$FV_DIR" pull --ff-only 2>/dev/null || warn "git pull failed, using current checkout"
    fi

    if [[ ! -x $FV_DIR/.venv/bin/python || ! -x $FV_DIR/.venv/bin/pip ]]; then
        msg "Creating Python virtual environment in $FV_DIR/.venv ..."
        rm -rf "$FV_DIR/.venv"
        python3 -m venv "$FV_DIR/.venv" || err "Failed to create Python virtualenv"
    fi

    msg "Installing FuturesView dependencies with pip ..."
    "$FV_DIR/.venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
    if ! "$FV_DIR/.venv/bin/pip" install -e "$FV_DIR[web]"; then
        err "Failed to install Python dependencies for FuturesView"
    fi

    pass=$(fv_gen_password)
    msg "Configuring high-strength WebUI password ..."
    if ! fv_apply_password "$pass"; then
        warn "Could not automatically apply password via web.auth, setting in database"
        db_write --arg p "$pass" '.settings.futures_view.password = $p'
    fi

    msg "Building frontend assets in $FV_DIR/webui ..."
    if [[ -d $FV_DIR/webui ]]; then
        (
            cd "$FV_DIR/webui"
            npm install || npm ci || { err "npm install failed in $FV_DIR/webui"; }
            npm run build || { err "npm run build failed in $FV_DIR/webui"; }
        ) || return 1
    else
        err "Directory $FV_DIR/webui not found"
    fi

    msg "Deploying static assets to Caddy web root ($WWW_DIR) ..."
    mkdir -p "$WWW_DIR"
    if [[ -d $FV_DIR/web/static ]]; then
        cp -r "$FV_DIR/web/static/"* "$WWW_DIR/"
        chmod -R 755 "$WWW_DIR"
    fi

    db_write '.settings.futures_view.enabled = true'

    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        systemctl enable "$FV_SVC"
        systemctl restart "$FV_SVC"
    fi

    caddy_gen
    caddy_reload

    domain=$(db_get '.settings.domain')
    port=$(fv_port)

    cat <<EOF

================ FuturesView Deployment Complete ================
WebUI URL:      https://$domain
Camouflage:     Active (serving FuturesView SPA on 443)
API Reverse:    https://$domain/api/* -> 127.0.0.1:$port
WebUI Password: $pass
Service:        $FV_SVC

Notes:
 1. Access the web panel at https://$domain and unlock it using the password above.
 2. To change or view the password later, run: vpsm fv password
 3. To update FuturesView after repository changes, run: vpsm fv update
=================================================================
EOF
}

fv_update() {
    need_root
    need_installed
    [[ -d $FV_DIR/.git ]] || err "FuturesView is not installed. Run: vpsm fv deploy"

    echo "=== Updating FuturesView ==="
    fv_check_prereqs
    msg "Pulling latest code from git ..."
    local branch
    branch=$(git -C "$FV_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if ! git -C "$FV_DIR" pull --ff-only origin "$branch"; then
        err "Failed to git pull in $FV_DIR"
    fi

    msg "Updating Python dependencies ..."
    if [[ -x $FV_DIR/.venv/bin/pip ]]; then
        "$FV_DIR/.venv/bin/pip" install -e "$FV_DIR[web]" || warn "pip install encountered issues"
    fi

    msg "Rebuilding frontend assets ..."
    if [[ -d $FV_DIR/webui ]]; then
        (
            cd "$FV_DIR/webui"
            npm install || npm ci || { err "npm install failed"; }
            npm run build || { err "npm run build failed"; }
        ) || return 1
    fi

    msg "Syncing built static assets to web root ..."
    mkdir -p "$WWW_DIR"
    if [[ -d $FV_DIR/web/static ]]; then
        cp -r "$FV_DIR/web/static/"* "$WWW_DIR/"
        chmod -R 755 "$WWW_DIR"
    fi

    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        msg "Restarting $FV_SVC service ..."
        systemctl restart "$FV_SVC" || warn "Failed to restart $FV_SVC"
    fi

    caddy_gen
    caddy_reload

    ok "FuturesView updated and rebuilt successfully!"
}

fv_set_password_cmd() {
    need_root
    need_installed
    local new_p=$1
    if [[ -z $new_p ]]; then
        local curr choice
        curr=$(fv_get_password)
        echo "Current WebUI password: ${curr:-"(none / not set)"}"
        echo
        echo "1) Generate a new random high-strength password"
        echo "2) Enter a custom password"
        echo "0) Cancel"
        choice=$(ask "Choose: ")
        case $choice in
            1) new_p=$(fv_gen_password) ;;
            2)
                if [[ -t 0 ]]; then
                    read -r -s -p "New password (8-256 characters): " new_p
                    echo
                else
                    new_p=$(ask "New password (8-256 characters): ")
                fi
                ;;
            *) return 0 ;;
        esac
    fi

    if ((${#new_p} < 8 || ${#new_p} > 256)); then
        err "Password length must be between 8 and 256 characters"
    fi

    if fv_apply_password "$new_p"; then
        ok "Password updated successfully!"
        echo "New password: $new_p"
    else
        warn "Could not update password via web.auth, saving to database"
        db_write --arg p "$new_p" '.settings.futures_view.password = $p'
        echo "New password: $new_p"
    fi
}

fv_remove() {
    need_root
    need_installed
    local ans
    echo "=== Disabling FuturesView ==="
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl disable --now "$FV_SVC" 2>/dev/null || true
    fi
    db_write '.settings.futures_view.enabled = false'
    caddy_gen
    caddy_reload
    ok "FuturesView disabled and removed from Caddy routing"

    if [[ -d $FV_DIR ]]; then
        ans=$(ask "Delete the FuturesView directory ($FV_DIR)? [y/N]: ")
        if [[ ${ans,,} == y ]]; then
            rm -rf "$FV_DIR"
            ok "Deleted $FV_DIR"
        fi
    fi
}

futures_view_menu() {
    local a state
    while true; do
        cls
        state="Not deployed"
        if fv_enabled; then
            state="Enabled"
            if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
                svc_active "$FV_SVC" && state="Active (running on 127.0.0.1:$(fv_port))" || state="Inactive (service stopped)"
            fi
        elif [[ -d $FV_DIR ]]; then
            state="Installed (disabled)"
        fi
        echo "=== FuturesView Panel ==="
        echo "Status: $state"
        echo
        echo "1) Deploy FuturesView (with auto-generated password)"
        echo "2) Update and rebuild (git pull + npm build)"
        echo "3) View / Change WebUI password"
        echo "4) Show status and logs"
        echo "5) Restart service"
        echo "6) Disable / Remove"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1) run_locked fv_deploy ;;
            2) run_locked fv_update ;;
            3) run_locked fv_set_password_cmd ;;
            4) fv_status; echo; show_log fv ;;
            5) run_locked svc_restart fv ;;
            6) run_locked fv_remove ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

fv_cmd() {
    case ${1:-status} in
        deploy | install) shift; fv_deploy "$@" ;;
        update | upgrade) shift; fv_update "$@" ;;
        status | s) shift; fv_status "$@" ;;
        password | pwd | pass) shift; fv_set_password_cmd "$@" ;;
        restart) shift; svc_restart fv ;;
        start) shift; svc_start fv ;;
        stop) shift; svc_stop fv ;;
        log) shift; show_log fv ;;
        remove | disable | del) shift; fv_remove "$@" ;;
        *) err "Usage: vpsm fv [deploy|update|status|password|restart|log|remove]" ;;
    esac
}

