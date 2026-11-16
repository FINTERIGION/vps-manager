#!/usr/bin/env bash
# vpsm - HKUDS/nanobot release deployment, WebUI static sync, and gateway management

# nb_enabled and nb_port live in src/caddy.sh alongside fv_enabled/fv_port.

nb_gw_port() {
    db_get '.settings.nanobot.gw_port // 18790'
}

nb_gen_password() {
    gen_panel_password
}

nb_get_password() {
    db_get '.settings.nanobot.password // ""'
}

nb_cpu_limit() {
    db_get 'if (.settings.nanobot.cpu_limit // null) != null and .settings.nanobot.cpu_limit != "" then .settings.nanobot.cpu_limit else 60 end'
}

nb_installed_version() {
    local py="$NB_DIR/.venv/bin/python" ver=""
    if [[ -x $py ]]; then
        ver=$("$py" -c "import importlib.metadata as m; print(m.version('$NB_PKG'))" 2>/dev/null || true)
    fi
    [[ -n $ver ]] || ver=$(db_get '.settings.nanobot.version // ""' 2>/dev/null || true)
    printf '%s\n' "$ver"
}

nb_public_ws_url() {
    local domain port
    domain=$(db_get '.settings.domain // ""')
    port=$(db_get '.settings.port // 443')
    [[ -n $domain ]] || return 1
    if [[ $port == 443 ]]; then
        printf 'wss://%s/ws\n' "$domain"
    else
        printf 'wss://%s:%s/ws\n' "$domain" "$port"
    fi
}

nb_sync_config() {
    local pass port gw_port ws_url tmp
    pass=$(nb_get_password)
    [[ -n $pass ]] || { warn "Nanobot WebUI password is empty; refusing to write unauthenticated config"; return 1; }
    port=$(nb_port)
    gw_port=$(nb_gw_port)
    ws_url=$(nb_public_ws_url) || { warn "Domain is not configured; cannot determine publicWsUrl"; return 1; }

    mkdir -p "$NB_DIR" "$NB_WORKSPACE" "$NB_DIR/.nanobot"
    chmod 700 "$NB_DIR" "$NB_DIR/.nanobot"

    tmp=$(umask 077; mktemp "$NB_DIR/.config.XXXXXX") || return 1
    if [[ -s $NB_CONF ]] && jq -e 'type == "object"' "$NB_CONF" >/dev/null 2>&1; then
        if ! jq --argjson gw_port "$gw_port" --argjson ws_port "$port" \
            --arg ws_url "$ws_url" --arg secret "$pass" --arg ws_dir "$NB_WORKSPACE" '
            .gateway = ((.gateway // {}) + {host: "127.0.0.1", port: $gw_port})
            | .agents = (.agents // {})
            | .agents.defaults = (.agents.defaults // {})
            | .agents.defaults.workspace = (.agents.defaults.workspace // $ws_dir)
            | .channels = (.channels // {})
            | .channels.websocket = ((.channels.websocket // {}) + {
                enabled: true,
                host: "127.0.0.1",
                port: $ws_port,
                path: "/ws",
                publicWsUrl: $ws_url,
                tokenIssuePath: "",
                tokenIssueSecret: $secret,
                websocketRequiresToken: true
              })' "$NB_CONF" >"$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    else
        if ! jq -n --argjson gw_port "$gw_port" --argjson ws_port "$port" \
            --arg ws_url "$ws_url" --arg secret "$pass" --arg ws_dir "$NB_WORKSPACE" '{
                agents: {
                    defaults: {
                        workspace: $ws_dir
                    }
                },
                gateway: {
                    host: "127.0.0.1",
                    port: $gw_port
                },
                channels: {
                    websocket: {
                        enabled: true,
                        host: "127.0.0.1",
                        port: $ws_port,
                        path: "/ws",
                        publicWsUrl: $ws_url,
                        tokenIssuePath: "",
                        tokenIssueSecret: $secret,
                        websocketRequiresToken: true
                    }
                }
            }' >"$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$NB_CONF"
    ln -sfn ../config.json "$NB_DIR/.nanobot/config.json"
    ln -sfn ../workspace "$NB_DIR/.nanobot/workspace"
}

nb_render_unit() {
    local gw_port cpu_limit cpu_opts="" content
    gw_port=$(nb_gw_port 2>/dev/null || echo "$NB_GW_PORT")
    cpu_limit=$(nb_cpu_limit 2>/dev/null || echo "60")
    if [[ $cpu_limit =~ ^[1-9][0-9]*$ && $cpu_limit -gt 0 ]]; then
        cpu_opts=$(printf 'CPUQuota=%s%%\nNice=15' "$cpu_limit")
    fi
    content=$(sed -e "s#@ROOT@#$ROOT#g" -e "s#@GW_PORT@#$gw_port#g" "$SH_DIR/systemd/vpsm-nanobot.service")
    if [[ -n $cpu_opts ]]; then
        content="${content//@NB_CPU_OPTS@/$cpu_opts}"
    else
        content=$(printf '%s\n' "$content" | grep -v '@NB_CPU_OPTS@')
    fi
    printf '%s\n' "$content"
}

nb_check_prereqs() {
    local missing=() p
    for p in python3 curl; do
        command -v "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [[ ! -x $NB_DIR/.venv/bin/pip ]] && ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
        missing+=(python3-venv)
    fi
    if ((${#missing[@]} > 0)); then
        if [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
            msg "Installing required packages: ${missing[*]} ..."
            apt-get update -y && apt-get install -y "${missing[@]}" ||
                err "Failed to install required packages: ${missing[*]}"
        elif [[ $EUID -eq 0 ]] && command -v dnf >/dev/null 2>&1; then
            msg "Installing required packages: ${missing[*]} ..."
            dnf install -y "${missing[@]}" ||
                err "Failed to install required packages: ${missing[*]}"
        elif [[ $EUID -eq 0 ]] && command -v yum >/dev/null 2>&1; then
            msg "Installing required packages: ${missing[*]} ..."
            yum install -y "${missing[@]}" ||
                err "Failed to install required packages: ${missing[*]}"
        else
            err "Missing required dependencies: ${missing[*]}. Please install them first."
        fi
    fi
}

nb_github_wheel_url() {
    local tag=${1:-} api_url json arch url
    if [[ -n $tag ]]; then
        tag="v${tag#[Vv]}"
        api_url="https://api.github.com/repos/$NB_REPO/releases/tags/$tag"
    else
        api_url="https://api.github.com/repos/$NB_REPO/releases/latest"
    fi
    json=$(curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 30 "$api_url" 2>/dev/null || true)
    [[ -n $json ]] || return 1
    arch=$(uname -m)
    url=$(jq -r --arg arch "$arch" '
        [.assets[]? | select(.name | endswith(".whl"))] as $whls
        | (($whls[] | select(.name | contains("none-any.whl"))),
           ($whls[] | select(.name | contains($arch))),
           $whls[0]) // empty
        | .browser_download_url' <<<"$json" | head -n 1)
    [[ -n $url ]] && printf '%s\n' "$url"
}

nb_install_pkg() {
    local ver=${1:-} spec="$NB_PKG" whl_url="" installed_ver=""
    mkdir -p "$NB_DIR" "$NB_WORKSPACE"
    chmod 700 "$NB_DIR"

    if [[ ! -x $NB_DIR/.venv/bin/python || ! -x $NB_DIR/.venv/bin/pip ]]; then
        msg "Creating Python virtual environment in $NB_DIR/.venv ..."
        rm -rf "$NB_DIR/.venv"
        python3 -m venv "$NB_DIR/.venv" || err "Failed to create Python virtualenv"
    fi

    msg "Upgrading pip in $NB_DIR/.venv ..."
    "$NB_DIR/.venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true

    if [[ -n $ver ]]; then
        spec="${NB_PKG}==${ver#[Vv]}"
    fi

    msg "Installing $spec release package (pre-bundled WebUI) ..."
    if ! "$NB_DIR/.venv/bin/pip" install --upgrade "$spec"; then
        warn "PyPI installation failed, checking GitHub Release wheel for $NB_REPO ..."
        whl_url=$(nb_github_wheel_url "$ver" || true)
        if [[ -n $whl_url ]]; then
            msg "Installing wheel from $whl_url ..."
            "$NB_DIR/.venv/bin/pip" install --upgrade "$whl_url" || err "Failed to install $NB_PKG from GitHub Release wheel"
        else
            err "Failed to install $spec"
        fi
    fi

    installed_ver=$("$NB_DIR/.venv/bin/python" -c "import importlib.metadata as m; print(m.version('$NB_PKG'))" 2>/dev/null || echo "")
    if [[ -n $installed_ver ]]; then
        db_write --arg v "$installed_ver" '.settings.nanobot.version = $v'
    fi
}

nb_locate_dist() {
    local py="$NB_DIR/.venv/bin/python"
    [[ -x $py ]] || return 1
    "$py" -c '
import pathlib, sys
import nanobot
pkg_dir = pathlib.Path(nanobot.__file__).resolve().parent
for rel in ("web/dist", "webui/dist", "static"):
    cand = pkg_dir / rel
    if (cand / "index.html").is_file():
        print(cand)
        sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

nb_sync_static() {
    local dist_dir
    dist_dir=$(nb_locate_dist) || err "Bundled Nanobot WebUI dist directory not found in $NB_DIR/.venv"
    msg "Syncing Nanobot WebUI assets from $dist_dir to $WWW_DIR ..."
    mkdir -p "$WWW_DIR"
    find "$WWW_DIR" -mindepth 1 -delete 2>/dev/null || rm -rf "${WWW_DIR:?}"/*
    cp -r "$dist_dir/." "$WWW_DIR/" || err "Failed to copy Nanobot WebUI assets"
    find "$WWW_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$WWW_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
}

nb_clear_www() {
    [[ -d $WWW_DIR ]] || return 0
    find "$WWW_DIR" -mindepth 1 -delete 2>/dev/null || rm -rf "${WWW_DIR:?}"/*
}

nb_status() {
    local state pid rss="-" domain port gw_port pwd cpu_lim ver ws_url
    domain=$(db_get '.settings.domain')
    port=$(nb_port)
    gw_port=$(nb_gw_port)
    pwd=$(nb_get_password)
    cpu_lim=$(nb_cpu_limit)
    ver=$(nb_installed_version)
    ws_url=$(nb_public_ws_url 2>/dev/null || echo "-")
    echo "=== Nanobot Panel Status ==="
    echo "Enabled:       $(nb_enabled && echo "yes" || echo "no")"
    if [[ -n $ver ]]; then
        echo "Package:       $NB_PKG (v$ver)"
    else
        echo "Package:       $NB_PKG (not installed)"
    fi
    echo "Virtualenv:    $([[ -x $NB_DIR/.venv/bin/python ]] && echo "installed ($("$NB_DIR/.venv/bin/python" --version 2>/dev/null))" || echo "missing")"
    echo "Config file:   $NB_CONF $([[ -f $NB_CONF ]] && echo "(present)" || echo "(missing)")"
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        state=$(systemctl is-active "$NB_SVC" 2>/dev/null || echo "unknown")
        if [[ $state == active ]]; then
            pid=$(systemctl show -p MainPID --value "$NB_SVC" 2>/dev/null)
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
    echo "WebUI listen:  127.0.0.1:$port"
    echo "Gateway port:  127.0.0.1:$gw_port"
    echo "WebUI URL:     https://$domain"
    echo "Public WS URL: $ws_url"
    if [[ ${1:-} == --show-password ]]; then
        echo "WebUI Pass:    ${pwd:-"(none / not set)"}"
    elif [[ -n $pwd ]]; then
        local masked_pwd="****"
        (( ${#pwd} > 8 )) && masked_pwd="${pwd:0:2}****${pwd: -2}"
        echo "WebUI Pass:    $masked_pwd (run 'vpsm nb password' to view or change)"
    else
        echo "WebUI Pass:    (none / not set)"
    fi
}

nb_deploy() {
    need_root
    need_installed
    local ver=${1:-} pass domain port ws_url cpu_lim

    echo "=== Deploying Nanobot Web Panel (HKUDS/nanobot) ==="
    nb_check_prereqs

    port=$(nb_port)
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        if port_in_use "$port" && ! svc_active "$NB_SVC"; then
            err "Port $port is already in use by another process"
        fi
        if port_in_use "$(nb_gw_port)" && ! svc_active "$NB_SVC"; then
            err "Gateway port $(nb_gw_port) is already in use by another process"
        fi
    fi

    nb_install_pkg "$ver"
    nb_locate_dist >/dev/null || err "Bundled Nanobot WebUI dist directory not found in $NB_DIR/.venv"

    if declare -F fv_enabled >/dev/null && fv_enabled; then
        msg "Disabling active FuturesView panel before enabling Nanobot (mutually exclusive)..."
        if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
            systemctl disable --now "$FV_SVC" 2>/dev/null || true
        fi
        db_write '.settings.futures_view.enabled = false'
    fi

    pass=$(nb_get_password)
    if ((${#pass} < 16)); then
        pass=$(nb_gen_password) || err "Failed to generate a WebUI password"
        db_write --arg p "$pass" '.settings.nanobot.password = $p'
    fi

    nb_sync_config || err "Failed to write $NB_CONF"
    nb_sync_static

    db_write '.settings.nanobot.enabled = true | if (.settings.nanobot.cpu_limit // null) == null then .settings.nanobot.cpu_limit = 60 else . end'

    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        systemctl enable "$NB_SVC"
        systemctl restart "$NB_SVC"
        svc_settled "$NB_SVC" || warn "$NB_SVC failed to stay up after start, check: journalctl -u $NB_SVC -n 50"
    fi

    caddy_gen
    caddy_reload

    domain=$(db_get '.settings.domain')
    port=$(nb_port)
    ws_url=$(nb_public_ws_url)
    cpu_lim=$(nb_cpu_limit)
    ver=$(nb_installed_version)

    cat <<EOF

================ Nanobot Deployment Complete ================
WebUI URL:      https://$domain
Public WS URL:  $ws_url
Camouflage:     Active (serving Nanobot WebUI on 443)
Package:        $NB_PKG ${ver:+v$ver}
Reverse Proxy:  /webui/* /api/* /auth/* /ws -> 127.0.0.1:$port
CPU Limit:      ${cpu_lim}% (Nice=15, protects proxy latency)
WebUI Password: $pass
Config File:    $NB_CONF
Workspace:      $NB_WORKSPACE
Service:        $NB_SVC

Notes:
 1. Open https://$domain and enter the WebUI Password above to unlock the panel.
 2. Configure your LLM API keys, models, MCP servers and skills directly in the WebUI Settings.
 3. To view or change the password later, run: vpsm nb password
 4. To configure CPU rate limiting, run: vpsm nb cpu
 5. To upgrade nanobot-ai and sync WebUI assets, run: vpsm nb update
=============================================================
EOF
}

nb_update() {
    need_root
    need_installed
    local ver=${1:-}
    [[ -x $NB_DIR/.venv/bin/pip ]] || err "Nanobot is not installed. Run: vpsm nb deploy"

    echo "=== Updating Nanobot ==="
    nb_check_prereqs
    nb_install_pkg "$ver"

    if [[ -z $(nb_get_password) ]]; then
        local pass
        pass=$(nb_gen_password) || err "Failed to generate a WebUI password"
        db_write --arg p "$pass" '.settings.nanobot.password = $p'
    fi

    nb_sync_config || err "Failed to update $NB_CONF"
    if nb_enabled; then
        nb_sync_static
    fi

    if [[ -z ${VPSM_NO_SERVICE:-} ]] && nb_enabled; then
        msg "Restarting $NB_SVC service ..."
        systemctl restart "$NB_SVC" || warn "Failed to restart $NB_SVC"
        svc_settled "$NB_SVC" || warn "$NB_SVC failed to stay up after update, check: journalctl -u $NB_SVC -n 50"
    fi

    caddy_gen
    caddy_reload

    ok "Nanobot updated successfully (version: $(nb_installed_version))!"
}

nb_set_password_cmd() {
    need_root
    need_installed
    local new_p=${1:-}
    if [[ -z $new_p ]]; then
        local curr choice
        curr=$(nb_get_password)
        echo "Current WebUI password: ${curr:-"(none / not set)"}"
        echo
        echo "1) Generate a new random high-strength password"
        echo "2) Enter a custom password"
        echo "0) Cancel"
        choice=$(ask "Choose: ") || return 0
        case $choice in
            1) new_p=$(nb_gen_password) || return 1 ;;
            2)
                if [[ -t 0 ]]; then
                    read -r -s -p "New password (8-256 characters): " new_p || { echo; return 0; }
                    echo
                else
                    new_p=$(ask "New password (8-256 characters): ") || return 0
                fi
                ;;
            *) return 0 ;;
        esac
    fi

    if ((${#new_p} < 8 || ${#new_p} > 256)); then
        err "Password length must be between 8 and 256 characters"
    fi

    db_write --arg p "$new_p" '.settings.nanobot.password = $p'
    if [[ -d $NB_DIR ]]; then
        nb_sync_config || warn "Failed to sync $NB_CONF"
        if [[ -z ${VPSM_NO_SERVICE:-} ]] && svc_active "$NB_SVC"; then
            systemctl restart "$NB_SVC" || warn "Failed to restart $NB_SVC"
        fi
    fi
    ok "Password updated successfully!"
    echo "New password: $new_p"
}

nb_set_cpu_limit_cmd() {
    need_root
    need_installed
    local val=${1:-} parsed
    if [[ -z $val ]]; then
        local curr choice
        curr=$(nb_cpu_limit)
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
        choice=$(ask "Choose: ") || return 0
        case $choice in
            1) val=60 ;;
            2)
                val=$(ask "Enter CPU limit percentage (5-1000%): ") || return 0
                [[ -z $val ]] && return 0
                ;;
            3) val=0 ;;
            *) return 0 ;;
        esac
    fi

    case ${val,,} in
        status | show)
            local curr
            curr=$(nb_cpu_limit)
            if [[ $curr =~ ^[1-9][0-9]*$ && $curr -gt 0 ]]; then
                echo "Nanobot CPU limit: ${curr}% (Nice=15)"
            else
                echo "Nanobot CPU limit: Disabled (unlimited)"
            fi
            return 0
            ;;
    esac

    parsed=$(parse_cpu_limit "$val") ||
        err "Invalid CPU limit: $val (must be a percentage between 5 and 1000, or '0' / 'off')"
    val=$parsed

    db_write --argjson c "$val" '.settings.nanobot.cpu_limit = $c'
    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        if svc_active "$NB_SVC"; then
            systemctl restart "$NB_SVC" || warn "Failed to restart $NB_SVC with new CPU limit"
        fi
    fi

    if ((val > 0)); then
        ok "Nanobot CPU limit configured: ${val}% (Nice=15)"
    else
        ok "Nanobot CPU limit disabled (unlimited CPU)"
    fi
}

nb_remove() {
    need_root
    need_installed
    local ans
    echo "=== Disabling Nanobot ==="
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl disable --now "$NB_SVC" 2>/dev/null || true
    fi
    db_write '.settings.nanobot.enabled = false'
    if ! declare -F fv_enabled >/dev/null || ! fv_enabled; then
        nb_clear_www
    fi
    caddy_gen
    caddy_reload
    ok "Nanobot disabled and removed from Caddy routing"

    if [[ -d $NB_DIR ]]; then
        ans=$(ask "Delete the Nanobot directory ($NB_DIR, including workspace and config)? [y/N]: ") || return 0
        if [[ ${ans,,} == y ]]; then
            rm -rf "$NB_DIR"
            ok "Deleted $NB_DIR"
        fi
    fi
}

nanobot_menu() {
    local a state cpu_lim cpu_desc ver
    while true; do
        cls
        state="Not deployed"
        if nb_enabled; then
            state="Enabled"
            if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
                svc_active "$NB_SVC" && state="Active (running on 127.0.0.1:$(nb_port))" || state="Inactive (service stopped)"
            fi
        elif [[ -d $NB_DIR ]]; then
            state="Installed (disabled)"
        fi
        cpu_lim=$(nb_cpu_limit)
        if [[ $cpu_lim =~ ^[1-9][0-9]*$ && $cpu_lim -gt 0 ]]; then
            cpu_desc="${cpu_lim}% (Nice=15)"
        else
            cpu_desc="Unlimited"
        fi
        ver=$(nb_installed_version)
        echo "=== Nanobot Panel (HKUDS/nanobot) ==="
        echo "Status:  $state"
        echo "Version: ${ver:-not installed}"
        echo
        echo "1) Deploy Nanobot release (auto password & WebUI)"
        echo "2) Update nanobot-ai package & sync WebUI"
        echo "3) View / Change WebUI password"
        echo "4) Configure CPU rate limit (current: $cpu_desc)"
        echo "5) Show status and logs"
        echo "6) Restart service"
        echo "7) Disable / Remove"
        echo "0) Back"
        a=$(ask "Choose: ") || return 0
        case $a in
            1) run_locked nb_deploy ;;
            2) run_locked nb_update ;;
            3) run_locked nb_set_password_cmd ;;
            4) run_locked nb_set_cpu_limit_cmd ;;
            5) nb_status; echo; show_log nb ;;
            6) run_locked svc_restart nb ;;
            7) run_locked nb_remove ;;
            0 | "") return 0 ;;
            *) continue ;;
        esac
        pause
    done
}

nb_cmd() {
    case ${1:-status} in
        deploy | install) shift; nb_deploy "$@" ;;
        update | upgrade) shift; nb_update "$@" ;;
        status | s) shift; nb_status "$@" ;;
        password | pwd | pass) shift; nb_set_password_cmd "$@" ;;
        cpu | cpulimit | limit) shift; nb_set_cpu_limit_cmd "$@" ;;
        restart) shift; svc_restart nb ;;
        start) shift; svc_start nb ;;
        stop) shift; svc_stop nb ;;
        log) shift; show_log nb ;;
        remove | disable | del) shift; nb_remove "$@" ;;
        *) err "Usage: vpsm nb [deploy|update|status|password|cpu|restart|start|stop|log|remove]" ;;
    esac
}
