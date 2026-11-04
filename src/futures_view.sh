#!/usr/bin/env bash
# vpsm - FuturesView deployment, update, and password management

fv_gen_password() {
    local pass=""
    # 256 bytes of urandom yield about 62 alphanumeric characters, so the
    # 20-character target is always met. 64 bytes reached it only ~13% of the
    # time and silently fell through to the weaker paths below.
    if [[ -r /dev/urandom ]]; then
        pass=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    if ((${#pass} < 16)) && command -v openssl >/dev/null 2>&1; then
        pass=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    # Deliberately no timestamp/$RANDOM fallback: the panel login is reachable
    # through the public /api/* proxy, so a guessable password would hand over
    # the very site that is supposed to be the disguise. Returns non-zero rather
    # than calling err(), because callers use a command substitution and an
    # exit inside it would only kill the subshell, yielding an empty password.
    if ((${#pass} < 16)); then
        warn "Cannot generate a strong password: neither /dev/urandom nor openssl produced enough entropy"
        return 1
    fi
    printf '%s\n' "$pass"
    return 0
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

fv_cpu_limit() {
    db_get 'if (.settings.futures_view.cpu_limit // null) != null and .settings.futures_view.cpu_limit != "" then .settings.futures_view.cpu_limit else 60 end'
}

fv_get_dce_api_key() {
    db_get '.settings.futures_view.dce_api_key // ""'
}

fv_sync_env_file() {
    [[ -d $FV_DIR ]] || return 0
    local key env_file="$FV_DIR/.env" tmp=""
    key=$(fv_get_dce_api_key)
    if [[ -f $env_file ]]; then
        tmp=$(grep -v -E '^(DCE_API_KEY|FT_DCE_API_KEY)=' "$env_file" 2>/dev/null || true)
    fi
    if [[ -n $key ]]; then
        {
            [[ -n $tmp ]] && printf '%s\n' "$tmp"
            printf 'DCE_API_KEY="%s"\n' "$key"
            printf 'FT_DCE_API_KEY="%s"\n' "$key"
        } > "$env_file"
        chmod 600 "$env_file" 2>/dev/null || true
    else
        if [[ -n $tmp ]]; then
            printf '%s\n' "$tmp" > "$env_file"
            chmod 600 "$env_file" 2>/dev/null || true
        else
            rm -f "$env_file"
        fi
    fi
}

fv_render_unit() {
    local domain port cpu_limit cpu_opts="" content dce_key env_opts=""
    domain=$(db_get '.settings.domain // ""' 2>/dev/null || echo "")
    port=$(fv_port 2>/dev/null || echo "8888")
    cpu_limit=$(fv_cpu_limit 2>/dev/null || echo "60")
    if [[ $cpu_limit =~ ^[1-9][0-9]*$ && $cpu_limit -gt 0 ]]; then
        cpu_opts=$(printf 'CPUQuota=%s%%\nNice=15' "$cpu_limit")
    fi
    dce_key=$(fv_get_dce_api_key 2>/dev/null || echo "")
    if [[ -n $dce_key ]]; then
        local escaped_k="${dce_key//\\/\\\\}"
        escaped_k="${escaped_k//\"/\\\"}"
        env_opts=$(printf 'Environment="DCE_API_KEY=%s"\nEnvironment="FT_DCE_API_KEY=%s"' "$escaped_k" "$escaped_k")
    fi
    content=$(sed -e "s#@ROOT@#$ROOT#g" -e "s#@DOMAIN@#$domain#g" -e "s#@PORT@#$port#g" "$SH_DIR/systemd/vpsm-futures-view.service")
    if [[ -n $cpu_opts ]]; then
        content="${content//@FV_CPU_OPTS@/$cpu_opts}"
    else
        content=$(printf '%s\n' "$content" | grep -v '@FV_CPU_OPTS@')
    fi
    if [[ -n $env_opts ]]; then
        content="${content//@FV_ENV_OPTS@/$env_opts}"
    else
        content=$(printf '%s\n' "$content" | grep -v '@FV_ENV_OPTS@')
    fi
    printf '%s\n' "$content"
}

fv_status() {
    local state pid rss="-" domain port pwd cpu_lim dce_k
    domain=$(db_get '.settings.domain')
    port=$(fv_port)
    pwd=$(fv_get_password)
    cpu_lim=$(fv_cpu_limit)
    dce_k=$(fv_get_dce_api_key)
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
    if [[ $cpu_lim =~ ^[1-9][0-9]*$ && $cpu_lim -gt 0 ]]; then
        echo "CPU limit:     ${cpu_lim}% (Nice=15, low priority)"
    else
        echo "CPU limit:     Disabled (unlimited)"
    fi
    if [[ -n $dce_k ]]; then
        local masked_k="${dce_k:0:4}****${dce_k: -4}"
        (( ${#dce_k} <= 8 )) && masked_k="****"
        echo "DCE API Key:   Configured ($masked_k)"
    else
        echo "DCE API Key:   Not set"
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
    if ! "$FV_DIR/.venv/bin/pip" install -e "${FV_DIR}[web]"; then
        err "Failed to install Python dependencies for FuturesView"
    fi

    pass=$(fv_gen_password) || err "Failed to generate a WebUI password"
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

    db_write '.settings.futures_view.enabled = true | if (.settings.futures_view.cpu_limit // null) == null then .settings.futures_view.cpu_limit = 60 else . end'

    fv_sync_env_file
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
    local cpu_lim
    cpu_lim=$(fv_cpu_limit)

    cat <<EOF

================ FuturesView Deployment Complete ================
WebUI URL:      https://$domain
Camouflage:     Active (serving FuturesView SPA on 443)
API Reverse:    https://$domain/api/* -> 127.0.0.1:$port
CPU Limit:      ${cpu_lim}% (Nice=15, protects proxy latency)
WebUI Password: $pass
Service:        $FV_SVC

Notes:
 1. Access the web panel at https://$domain and unlock it using the password above.
 2. To change or view the password later, run: vpsm fv password
 3. To configure CPU rate limiting, run: vpsm fv cpu
 4. To update FuturesView after repository changes, run: vpsm fv update
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
        "$FV_DIR/.venv/bin/pip" install -e "${FV_DIR}[web]" || warn "pip install encountered issues"
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

    fv_sync_env_file

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
            1) new_p=$(fv_gen_password) || return 1 ;;
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

fv_set_cpu_limit_cmd() {
    need_root
    need_installed
    local val=${1:-}
    if [[ -z $val ]]; then
        local curr choice
        curr=$(fv_cpu_limit)
        if [[ $curr =~ ^[1-9][0-9]*$ && $curr -gt 0 ]]; then
            echo "Current CPU limit: ${curr}% (Nice=15, low scheduling priority)"
        else
            echo "Current CPU limit: Disabled (unlimited CPU)"
        fi
        echo
        echo "1) Set CPU limit to 60% (Recommended for 1C1G: preserves proxy performance)"
        echo "2) Enter custom CPU limit percentage (e.g. 50% / 70% / 80%)"
        echo "3) Disable CPU limit (allow 100% CPU usage)"
        echo "0) Cancel"
        choice=$(ask "Choose: ")
        case $choice in
            1) val=60 ;;
            2)
                val=$(ask "Enter CPU limit percentage (5-1000%): ")
                [[ -z $val ]] && return 0
                ;;
            3) val=0 ;;
            *) return 0 ;;
        esac
    fi

    val=${val%%%}
    case ${val,,} in
        status | show)
            local curr
            curr=$(fv_cpu_limit)
            if [[ $curr =~ ^[1-9][0-9]*$ && $curr -gt 0 ]]; then
                echo "FuturesView CPU limit: ${curr}% (Nice=15)"
            else
                echo "FuturesView CPU limit: Disabled (unlimited)"
            fi
            return 0
            ;;
        off | disable | disabled | 0 | none | unlimited)
            val=0
            ;;
        *)
            if ! [[ $val =~ ^[1-9][0-9]*$ ]] || ((val < 5 || val > 1000)); then
                err "Invalid CPU limit: $val (must be a percentage between 5 and 1000, or '0' / 'off')"
            fi
            ;;
    esac

    db_write --argjson c "$val" '.settings.futures_view.cpu_limit = $c'
    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        if svc_active "$FV_SVC"; then
            systemctl restart "$FV_SVC" || warn "Failed to restart $FV_SVC with new CPU limit"
        fi
    fi

    if ((val > 0)); then
        ok "FuturesView CPU limit configured: ${val}% (Nice=15)"
    else
        ok "FuturesView CPU limit disabled (unlimited CPU)"
    fi
}

fv_set_dce_api_key_cmd() {
    need_root
    need_installed
    local key=${1:-}
    if [[ -z $key ]]; then
        local curr choice
        curr=$(fv_get_dce_api_key)
        if [[ -n $curr ]]; then
            local masked="${curr:0:4}****${curr: -4}"
            (( ${#curr} <= 8 )) && masked="****"
            echo "Current DCE API Key: $masked"
        else
            echo "Current DCE API Key: (none / not set)"
        fi
        echo
        echo "1) Enter new DCE API Key"
        echo "2) Clear DCE API Key"
        echo "0) Cancel"
        choice=$(ask "Choose: ")
        case $choice in
            1)
                key=$(ask "Enter DCE API Key: ")
                [[ -z $key ]] && return 0
                ;;
            2)
                key="clear"
                ;;
            *) return 0 ;;
        esac
    fi

    case ${key,,} in
        status | show)
            local curr
            curr=$(fv_get_dce_api_key)
            if [[ -n $curr ]]; then
                local masked="${curr:0:4}****${curr: -4}"
                (( ${#curr} <= 8 )) && masked="****"
                echo "FuturesView DCE API Key: $masked"
            else
                echo "FuturesView DCE API Key: (none / not set)"
            fi
            return 0
            ;;
        clear | none | off | delete | del | disable | disabled | 0)
            key=""
            ;;
    esac

    if [[ -n $key && $key =~ [[:cntrl:]] ]]; then
        err "API key must not contain control characters or newlines"
    fi

    db_write --arg k "$key" '.settings.futures_view.dce_api_key = $k'
    fv_sync_env_file
    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        if svc_active "$FV_SVC"; then
            systemctl restart "$FV_SVC" || warn "Failed to restart $FV_SVC with new DCE API key"
        fi
    fi

    if [[ -n $key ]]; then
        ok "FuturesView DCE API key configured successfully!"
    else
        ok "FuturesView DCE API key cleared"
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
    local a state cpu_lim cpu_desc dce_k dce_desc
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
        cpu_lim=$(fv_cpu_limit)
        if [[ $cpu_lim =~ ^[1-9][0-9]*$ && $cpu_lim -gt 0 ]]; then
            cpu_desc="${cpu_lim}% (Nice=15)"
        else
            cpu_desc="Unlimited"
        fi
        dce_k=$(fv_get_dce_api_key)
        if [[ -n $dce_k ]]; then
            dce_desc="Configured"
        else
            dce_desc="Not set"
        fi
        echo "=== FuturesView Panel ==="
        echo "Status: $state"
        echo
        echo "1) Deploy FuturesView (with auto-generated password)"
        echo "2) Update and rebuild (git pull + npm build)"
        echo "3) View / Change WebUI password"
        echo "4) Configure DCE API key (current: $dce_desc)"
        echo "5) Configure CPU rate limit (current: $cpu_desc)"
        echo "6) Show status and logs"
        echo "7) Restart service"
        echo "8) Disable / Remove"
        echo "0) Back"
        a=$(ask "Choose: ")
        case $a in
            1) run_locked fv_deploy ;;
            2) run_locked fv_update ;;
            3) run_locked fv_set_password_cmd ;;
            4) run_locked fv_set_dce_api_key_cmd ;;
            5) run_locked fv_set_cpu_limit_cmd ;;
            6) fv_status; echo; show_log fv ;;
            7) run_locked svc_restart fv ;;
            8) run_locked fv_remove ;;
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
        key | apikey | dce | dce-key | dce_key) shift; fv_set_dce_api_key_cmd "$@" ;;
        cpu | cpulimit | limit) shift; fv_set_cpu_limit_cmd "$@" ;;
        restart) shift; svc_restart fv ;;
        start) shift; svc_start fv ;;
        stop) shift; svc_stop fv ;;
        log) shift; show_log fv ;;
        remove | disable | del) shift; fv_remove "$@" ;;
        *) err "Usage: vpsm fv [deploy|update|status|password|apikey|cpu|restart|log|remove]" ;;
    esac
}

