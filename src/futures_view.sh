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

fv_ensure_user() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    if ! getent group "$FV_USER" >/dev/null 2>&1; then
        groupadd --system "$FV_USER" >/dev/null 2>&1 ||
            err "Failed to create system group $FV_USER"
    fi
    if ! getent passwd "$FV_USER" >/dev/null 2>&1; then
        useradd --system --gid "$FV_USER" --no-create-home --shell /usr/sbin/nologin "$FV_USER" >/dev/null 2>&1 ||
            useradd --system --gid "$FV_USER" --no-create-home --shell /sbin/nologin "$FV_USER" >/dev/null 2>&1 ||
            err "Failed to create system user $FV_USER"
    fi
}

fv_fix_perms() {
    [[ -n ${VPSM_NO_SERVICE:-} ]] && return 0
    fv_ensure_user
    mkdir -p "$FV_HOME"
    chown -h "$FV_USER:$FV_USER" "$FV_HOME"
    chmod 700 "$FV_HOME"
    if [[ -d $FV_DIR && ! -L $FV_DIR ]]; then
        chown -h "$FV_USER:$FV_USER" "$FV_DIR"
        find "$FV_DIR" -mindepth 1 -maxdepth 1 -exec chown -hR "$FV_USER:$FV_USER" {} + 2>/dev/null || true
    fi
    if [[ -f $FV_ENV_FILE && ! -L $FV_ENV_FILE ]]; then
        chown root:root "$FV_ENV_FILE"
        chmod 600 "$FV_ENV_FILE"
    fi
}

fv_run_in() {
    local dir=$1
    shift
    if [[ -n ${VPSM_NO_SERVICE:-} ]]; then
        (cd "$dir" && "$@")
        return
    fi
    fv_ensure_user
    mkdir -p "$FV_HOME"
    chown "$FV_USER:$FV_USER" "$FV_HOME"
    chmod 700 "$FV_HOME"
    local path_env="/usr/local/bin:/usr/bin:/bin"
    [[ -d $ROOT/node/bin ]] && path_env="$ROOT/node/bin:$path_env"
    (
        cd "$dir" || return 1
        runuser -u "$FV_USER" -- env -i \
            HOME="$FV_HOME" \
            LANG=C.UTF-8 \
            LC_ALL=C.UTF-8 \
            PATH="$path_env" \
            npm_config_cache="$FV_HOME/.npm" \
            PIP_CACHE_DIR="$FV_HOME/.cache/pip" \
            "$@"
    )
}

fv_run() {
    local dir=$ROOT
    [[ -d $FV_DIR ]] && dir=$FV_DIR
    fv_run_in "$dir" "$@"
}

fv_webui_url() {
    local domain port
    domain=$(db_get '.settings.domain')
    port=$(db_get '.settings.port // 443' 2>/dev/null || echo "443")
    if [[ $port == 443 ]]; then
        printf 'https://%s\n' "$domain"
    else
        printf 'https://%s:%s\n' "$domain" "$port"
    fi
}

fv_sync_static_assets() {
    mkdir -p "$WWW_DIR"
    [[ -d $FV_DIR && ! -L $FV_DIR ]] || return 0
    [[ -d $FV_DIR/web && ! -L $FV_DIR/web ]] || return 0
    [[ -d $FV_DIR/web/static && ! -L $FV_DIR/web/static ]] || return 0

    local stage rc tar_rc
    stage=$(mktemp -d "$ROOT/.www.XXXXXX") || return 1
    fv_run python3 -c '
import io, os, stat, sys, tarfile

fv_dir = sys.argv[1]
dir_flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)

def open_dir_nofollow(path, dir_fd=None):
    fd = os.open(path, dir_flags, dir_fd=dir_fd)
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        os.close(fd)
        raise OSError("not a directory")
    return fd

try:
    root_fd = open_dir_nofollow(fv_dir)
    try:
        web_fd = open_dir_nofollow("web", dir_fd=root_fd)
    finally:
        os.close(root_fd)
    try:
        static_fd = open_dir_nofollow("static", dir_fd=web_fd)
    finally:
        os.close(web_fd)
except FileNotFoundError:
    sys.exit(0)
except OSError:
    sys.exit(2)

def stream_dir(tf, dir_fd, prefix):
    for name in sorted(os.listdir(dir_fd)):
        if name in (".", "..") or "/" in name or "\0" in name:
            continue
        rel = f"{prefix}/{name}" if prefix else name
        try:
            lst = os.lstat(name, dir_fd=dir_fd)
        except OSError:
            continue
        if stat.S_ISLNK(lst.st_mode):
            continue
        if stat.S_ISDIR(lst.st_mode):
            try:
                sub_fd = open_dir_nofollow(name, dir_fd=dir_fd)
            except OSError:
                continue
            try:
                ti = tarfile.TarInfo(name=rel)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                tf.addfile(ti)
                stream_dir(tf, sub_fd, rel)
            finally:
                os.close(sub_fd)
        elif stat.S_ISREG(lst.st_mode):
            try:
                ffd = os.open(name, file_flags, dir_fd=dir_fd)
            except OSError:
                continue
            try:
                fst = os.fstat(ffd)
                if not stat.S_ISREG(fst.st_mode):
                    continue
                with os.fdopen(ffd, "rb") as fobj:
                    ffd = -1
                    data = fobj.read()
                ti = tarfile.TarInfo(name=rel)
                ti.type = tarfile.REGTYPE
                ti.mode = 0o644
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
            finally:
                if ffd >= 0:
                    os.close(ffd)

try:
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as tf:
        stream_dir(tf, static_fd, "")
finally:
    os.close(static_fd)
' "$FV_DIR" | tar --no-same-owner --no-same-permissions -xf - -C "$stage" 2>/dev/null
    rc=${PIPESTATUS[0]}
    tar_rc=${PIPESTATUS[1]}
    if ((rc != 0)); then
        rm -rf "$stage"
        ((rc == 2)) && warn "Refusing to sync FuturesView static assets through a symlink"
        return 0
    fi
    if ((tar_rc != 0)); then
        rm -rf "$stage"
        warn "Failed to extract FuturesView static assets"
        return 1
    fi
    find "$stage" -mindepth 1 ! -type f ! -type d -delete 2>/dev/null || true
    if [[ -n $(find "$stage" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
        find "$stage" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$stage" -type f -exec chmod 644 {} + 2>/dev/null || true
        find "$WWW_DIR" -mindepth 1 -delete 2>/dev/null || rm -rf "${WWW_DIR:?}"/*
        find "$stage" -mindepth 1 -maxdepth 1 -exec mv -f {} "$WWW_DIR/" + 2>/dev/null ||
            cp -rP --no-preserve=ownership "$stage/." "$WWW_DIR/"
        chmod 755 "$WWW_DIR"
    fi
    rm -rf "$stage"
}

fv_apply_password() {
    local pass=$1 py="$FV_DIR/.venv/bin/python"
    [[ -x $py ]] || return 1
    printf '%s' "$pass" | fv_run "$py" -c "import sys; from web.auth import set_password; set_password(sys.stdin.read())" || return 1
    fv_fix_perms
    VPSM_SECRET_PASS="$pass" db_write '.settings.futures_view.password = (env.VPSM_SECRET_PASS // "")'
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

fv_get_dce_secret() {
    db_get '.settings.futures_view.dce_secret // ""'
}

fv_escape_env_val() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//\$/\\\$}
    v=${v//\`/\\\`}
    printf '%s' "$v"
}

fv_sync_env_file() {
    local key secret env_file="$FV_ENV_FILE" legacy="$FV_DIR/.env" tmp="" out_tmp esc_k esc_s migrated=""
    key=$(fv_get_dce_api_key)
    secret=$(fv_get_dce_secret)
    if [[ -f $env_file && ! -L $env_file ]]; then
        tmp=$(grep -v -E '^(DCE_API_KEY|DCE_KEY|FT_DCE_API_KEY|DCE_SECRET|DCE_API_SECRET|FT_DCE_SECRET)=' "$env_file" 2>/dev/null || true)
    elif [[ ! -e $env_file && -f $legacy && ! -L $legacy ]]; then
        if [[ -n ${VPSM_NO_SERVICE:-} || $(stat -c %u "$legacy" 2>/dev/null || echo -1) == 0 ]]; then
            tmp=$(grep -v -E '^(DCE_API_KEY|DCE_KEY|FT_DCE_API_KEY|DCE_SECRET|DCE_API_SECRET|FT_DCE_SECRET)=' "$legacy" 2>/dev/null || true)
            migrated=1
        fi
    fi
    if [[ -n $key || -n $secret ]]; then
        mkdir -p "$ROOT"
        esc_k=$(fv_escape_env_val "$key")
        esc_s=$(fv_escape_env_val "$secret")
        out_tmp=$(umask 077; mktemp "$ROOT/.fv.env.XXXXXX") || return 1
        {
            [[ -n $tmp ]] && printf '%s\n' "$tmp"
            if [[ -n $key ]]; then
                printf 'DCE_API_KEY="%s"\n' "$esc_k"
                printf 'DCE_KEY="%s"\n' "$esc_k"
                printf 'FT_DCE_API_KEY="%s"\n' "$esc_k"
            fi
            if [[ -n $secret ]]; then
                printf 'DCE_SECRET="%s"\n' "$esc_s"
                printf 'DCE_API_SECRET="%s"\n' "$esc_s"
                printf 'FT_DCE_SECRET="%s"\n' "$esc_s"
            fi
        } > "$out_tmp"
        chmod 600 "$out_tmp" 2>/dev/null || true
        [[ -z ${VPSM_NO_SERVICE:-} ]] && chown root:root "$out_tmp" 2>/dev/null || true
        mv -f "$out_tmp" "$env_file"
        [[ -n $migrated ]] && rm -f "$legacy"
    else
        if [[ -n $tmp ]]; then
            mkdir -p "$ROOT"
            out_tmp=$(umask 077; mktemp "$ROOT/.fv.env.XXXXXX") || return 1
            printf '%s\n' "$tmp" > "$out_tmp"
            chmod 600 "$out_tmp" 2>/dev/null || true
            [[ -z ${VPSM_NO_SERVICE:-} ]] && chown root:root "$out_tmp" 2>/dev/null || true
            mv -f "$out_tmp" "$env_file"
            [[ -n $migrated ]] && rm -f "$legacy"
        else
            rm -f "$env_file"
            [[ -n $migrated ]] && rm -f "$legacy"
        fi
    fi
}

fv_render_unit() {
    local domain port xray_port cpu_limit cpu_opts="" allowed_hosts allowed_origins content
    domain=$(db_get '.settings.domain // ""' 2>/dev/null || echo "")
    port=$(fv_port 2>/dev/null || echo "8888")
    xray_port=$(db_get '.settings.port // 443' 2>/dev/null || echo "443")
    cpu_limit=$(fv_cpu_limit 2>/dev/null || echo "60")
    if [[ $cpu_limit =~ ^[1-9][0-9]*$ && $cpu_limit -gt 0 ]]; then
        cpu_opts=$(printf 'CPUQuota=%s%%\nNice=15' "$cpu_limit")
    fi
    if [[ -n $domain ]]; then
        if [[ $xray_port == 443 ]]; then
            allowed_hosts="127.0.0.1,localhost,$domain"
            allowed_origins="https://$domain,http://$domain"
        else
            allowed_hosts="127.0.0.1,localhost,$domain,$domain:$xray_port"
            allowed_origins="https://$domain:$xray_port,http://$domain:$xray_port,https://$domain,http://$domain"
        fi
    else
        allowed_hosts="127.0.0.1,localhost"
        allowed_origins="https://127.0.0.1,http://127.0.0.1"
    fi
    content=$(sed -e "s#@ROOT@#$ROOT#g" -e "s#@DOMAIN@#$domain#g" -e "s#@PORT@#$port#g" \
        -e "s#@FV_USER@#$FV_USER#g" -e "s#@FV_HOME@#$FV_HOME#g" -e "s#@FV_ENV_FILE@#$FV_ENV_FILE#g" \
        -e "s#@FV_ALLOWED_HOSTS@#$allowed_hosts#g" \
        -e "s#@FV_ALLOWED_ORIGINS@#$allowed_origins#g" "$SH_DIR/systemd/vpsm-futures-view.service") || return 1
    if [[ -n $cpu_opts ]]; then
        content="${content//@FV_CPU_OPTS@/$cpu_opts}"
    else
        content=$(printf '%s\n' "$content" | grep -v '@FV_CPU_OPTS@')
    fi
    content=$(printf '%s\n' "$content" | grep -v '@FV_ENV_OPTS@')
    printf '%s\n' "$content"
}

fv_status() {
    local state pid rss="-" port pwd cpu_lim dce_k dce_s
    port=$(fv_port)
    pwd=$(fv_get_password)
    cpu_lim=$(fv_cpu_limit)
    dce_k=$(fv_get_dce_api_key)
    dce_s=$(fv_get_dce_secret)
    echo "=== FuturesView Panel Status ==="
    echo "Enabled:       $(fv_enabled && echo "yes" || echo "no")"
    echo "Repository:    $FV_DIR $([[ -d $FV_DIR/.git ]] && echo "(git $(fv_run git -C "$FV_DIR" rev-parse --short HEAD 2>/dev/null || echo "cloned"))" || echo "(not cloned)")"
    echo "Virtualenv:    $([[ -x $FV_DIR/.venv/bin/python ]] && echo "installed ($(fv_run "$FV_DIR/.venv/bin/python" --version 2>/dev/null))" || echo "missing")"
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
    if [[ -n $dce_k && -n $dce_s ]]; then
        local masked_k="${dce_k:0:4}****${dce_k: -4}"
        (( ${#dce_k} <= 8 )) && masked_k="****"
        local masked_s="${dce_s:0:4}****${dce_s: -4}"
        (( ${#dce_s} <= 8 )) && masked_s="****"
        echo "DCE Credentials: Configured (Key: $masked_k, Secret: $masked_s)"
    elif [[ -n $dce_k ]]; then
        local masked_k="${dce_k:0:4}****${dce_k: -4}"
        (( ${#dce_k} <= 8 )) && masked_k="****"
        echo "DCE Credentials: Incomplete (Key: $masked_k, Secret: missing)"
    elif [[ -n $dce_s ]]; then
        local masked_s="${dce_s:0:4}****${dce_s: -4}"
        (( ${#dce_s} <= 8 )) && masked_s="****"
        echo "DCE Credentials: Incomplete (Key: missing, Secret: configured)"
    else
        echo "DCE Credentials: Not set"
    fi
    echo "Listen addr:   127.0.0.1:$port"
    echo "WebUI URL:     $(fv_webui_url)"
    if [[ ${1:-} == --show-password ]]; then
        echo "WebUI Pass:    ${pwd:-"(none / not set)"}"
    elif [[ -n $pwd ]]; then
        local masked_pwd="****"
        (( ${#pwd} > 8 )) && masked_pwd="${pwd:0:2}****${pwd: -2}"
        echo "WebUI Pass:    $masked_pwd (run 'vpsm fv password' to view or change)"
    else
        echo "WebUI Pass:    (none / not set)"
    fi
}

fv_install_node22() {
    local narch tmp base name sum
    case "$(uname -m)" in
        x86_64 | amd64) narch="x64" ;;
        aarch64 | arm64) narch="arm64" ;;
        *) return 1 ;;
    esac
    tmp=$(mktemp -d) || return 1
    base="https://nodejs.org/dist/latest-v22.x"
    if ! dl "$base/SHASUMS256.txt" "$tmp/sums"; then
        rm -rf "$tmp"
        return 1
    fi
    name=$(awk -v a="linux-$narch.tar.gz" '$2 ~ "^node-v22\\.[0-9]+\\.[0-9]+-" a "$" {print $2; exit}' "$tmp/sums")
    sum=$(awk -v f="$name" '$2 == f {print $1; exit}' "$tmp/sums")
    if [[ -z $name || -z $sum ]]; then
        rm -rf "$tmp"
        return 1
    fi
    msg "Downloading Node.js ($name) with SHA-256 verification ..."
    if ! dl "$base/$name" "$tmp/node.tgz" || ! verify_sum sha256 "$sum" "$tmp/node.tgz"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$ROOT/node.new"
    mkdir -p "$ROOT/node.new"
    chmod 755 "$ROOT/node.new"
    if ! tar -xzf "$tmp/node.tgz" -C "$ROOT/node.new" --strip-components=1; then
        rm -rf "$tmp" "$ROOT/node.new"
        return 1
    fi
    chmod 755 "$ROOT/node.new"
    rm -rf "$tmp" "$ROOT/node"
    mv -f "$ROOT/node.new" "$ROOT/node"
    export PATH="$ROOT/node/bin:$PATH"
}

fv_check_prereqs() {
    [[ -d $ROOT/node/bin ]] && export PATH="$ROOT/node/bin:$PATH"
    local missing=() p
    for p in git python3 curl runuser; do
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
        if [[ $EUID -eq 0 ]] && command -v curl >/dev/null 2>&1; then
            msg "Node.js >= 20 is required for WebUI build (found: ${node_ver:-none}). Installing Node.js 22 LTS ..."
            fv_install_node22 || warn "Failed to install verified Node.js 22 binary"
        fi
        node_major=0
        if command -v node >/dev/null 2>&1; then
            node_ver=$(node -v 2>/dev/null || echo "")
            node_major=$(echo "$node_ver" | sed -E 's/^v([0-9]+).*/\1/')
        fi
        [[ $node_major =~ ^[0-9]+$ ]] || node_major=0
        if ((node_major < 20)) || ! command -v npm >/dev/null 2>&1; then
            err "Node.js >= 20 and npm are required (found: ${node_ver:-none}). Install Node.js >= 20 manually and retry."
        fi
    fi
}

fv_deploy() {
    need_root
    need_installed
    local pass url port

    echo "=== Deploying FuturesView Web Panel ==="
    fv_check_prereqs

    mkdir -p "${FV_DIR%/*}"
    fv_sync_env_file
    if [[ ! -d $FV_DIR/.git ]]; then
        mkdir -p "$FV_DIR"
        fv_fix_perms
        msg "Cloning $FV_REPO into $FV_DIR ..."
        if ! fv_run git clone "$FV_REPO" "$FV_DIR"; then
            err "Failed to clone $FV_REPO"
        fi
    else
        fv_fix_perms
        msg "Repository already exists in $FV_DIR, updating..."
        fv_run git -C "$FV_DIR" pull --ff-only 2>/dev/null || warn "git pull failed, using current checkout"
    fi

    if [[ ! -x $FV_DIR/.venv/bin/python || ! -x $FV_DIR/.venv/bin/pip ]]; then
        msg "Creating Python virtual environment in $FV_DIR/.venv ..."
        rm -rf "$FV_DIR/.venv"
        fv_run python3 -m venv "$FV_DIR/.venv" || err "Failed to create Python virtualenv"
    fi

    msg "Installing FuturesView dependencies with pip ..."
    fv_run "$FV_DIR/.venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
    if ! fv_run "$FV_DIR/.venv/bin/pip" install -e "${FV_DIR}[web]"; then
        err "Failed to install Python dependencies for FuturesView"
    fi

    pass=$(fv_gen_password) || err "Failed to generate a WebUI password"
    msg "Configuring high-strength WebUI password ..."
    if ! fv_apply_password "$pass"; then
        warn "Could not automatically apply password via web.auth, setting in database"
        VPSM_SECRET_PASS="$pass" db_write '.settings.futures_view.password = (env.VPSM_SECRET_PASS // "")'
    fi

    msg "Building frontend assets in $FV_DIR/webui ..."
    if [[ -d $FV_DIR/webui ]]; then
        fv_run_in "$FV_DIR/webui" npm ci || fv_run_in "$FV_DIR/webui" npm install || err "npm install failed in $FV_DIR/webui"
        fv_run_in "$FV_DIR/webui" npm run build || err "npm run build failed in $FV_DIR/webui"
    else
        err "Directory $FV_DIR/webui not found"
    fi

    msg "Deploying static assets to Caddy web root ($WWW_DIR) ..."
    fv_sync_static_assets

    db_write '.settings.futures_view.enabled = true | if (.settings.futures_view.cpu_limit // null) == null then .settings.futures_view.cpu_limit = 60 else . end'

    fv_sync_env_file
    fv_fix_perms
    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        systemctl enable "$FV_SVC"
        systemctl restart "$FV_SVC"
    fi

    caddy_gen
    caddy_reload

    url=$(fv_webui_url)
    port=$(fv_port)
    local cpu_lim
    cpu_lim=$(fv_cpu_limit)

    cat <<EOF

================ FuturesView Deployment Complete ================
WebUI URL:      $url
Camouflage:     Active (serving FuturesView SPA on $(db_get '.settings.port // 443'))
API Reverse:    $url/api/* -> 127.0.0.1:$port
CPU Limit:      ${cpu_lim}% (Nice=15, protects proxy latency)
WebUI Password: $pass
Service:        $FV_SVC

Notes:
 1. Access the web panel at $url and unlock it using the password above.
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
    fv_fix_perms
    msg "Pulling latest code from git ..."
    local branch
    branch=$(fv_run git -C "$FV_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if ! fv_run git -C "$FV_DIR" pull --ff-only origin "$branch"; then
        err "Failed to git pull in $FV_DIR"
    fi

    msg "Updating Python dependencies ..."
    if [[ -x $FV_DIR/.venv/bin/pip ]]; then
        fv_run "$FV_DIR/.venv/bin/pip" install -e "${FV_DIR}[web]" || warn "pip install encountered issues"
    fi

    msg "Rebuilding frontend assets ..."
    if [[ -d $FV_DIR/webui ]]; then
        fv_run_in "$FV_DIR/webui" npm ci || fv_run_in "$FV_DIR/webui" npm install || err "npm install failed"
        fv_run_in "$FV_DIR/webui" npm run build || err "npm run build failed"
    fi

    msg "Syncing built static assets to web root ..."
    fv_sync_static_assets

    fv_sync_env_file
    fv_fix_perms
    install_units

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
    local new_p=${1:-}
    if [[ $new_p == - ]]; then
        if [[ -t 0 ]]; then
            read -r -s -p "New password (8-256 characters): " new_p || { echo; return 0; }
            echo
        else
            read -r new_p || return 0
        fi
    elif [[ -n $new_p ]]; then
        warn "Passing passwords directly as CLI arguments may expose them in process lists and shell history. Prefer interactive 'vpsm fv password' or '-' via stdin."
    else
        local curr choice
        curr=$(fv_get_password)
        echo "Current WebUI password: ${curr:-"(none / not set)"}"
        echo
        echo "1) Generate a new random high-strength password"
        echo "2) Enter a custom password"
        echo "0) Cancel"
        choice=$(ask "Choose: ") || return 0
        case $choice in
            1) new_p=$(fv_gen_password) || return 1 ;;
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

    if fv_apply_password "$new_p"; then
        ok "Password updated successfully!"
        echo "New password: $new_p"
    else
        warn "Could not update password via web.auth, saving to database"
        VPSM_SECRET_PASS="$new_p" db_write '.settings.futures_view.password = (env.VPSM_SECRET_PASS // "")'
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
        if svc_should_restart "$FV_SVC"; then
            systemctl restart "$FV_SVC" || warn "Failed to restart $FV_SVC with new CPU limit"
        fi
    fi

    if ((val > 0)); then
        ok "FuturesView CPU limit configured: ${val}% (Nice=15)"
    else
        ok "FuturesView CPU limit disabled (unlimited CPU)"
    fi
}

fv_read_secret() {
    local prompt=$1 val=""
    if [[ -t 0 ]]; then
        read -r -s -p "$prompt" val || { echo >&2; return 130; }
        echo >&2
    else
        read -r val || return 130
    fi
    printf '%s\n' "$val"
}

fv_set_dce_credentials_cmd() {
    need_root
    need_installed
    local key="" secret="" arg1=${1:-} arg2=${2:-}
    local curr_k curr_s masked_k masked_s

    curr_k=$(fv_get_dce_api_key)
    curr_s=$(fv_get_dce_secret)

    if [[ -z $arg1 ]]; then
        masked_k="none"
        if [[ -n $curr_k ]]; then
            masked_k="${curr_k:0:4}****${curr_k: -4}"
            (( ${#curr_k} <= 8 )) && masked_k="****"
        fi
        masked_s="none"
        if [[ -n $curr_s ]]; then
            masked_s="${curr_s:0:4}****${curr_s: -4}"
            (( ${#curr_s} <= 8 )) && masked_s="****"
        fi
        echo "=== FuturesView DCE Credentials ==="
        echo "Current API Key: $masked_k"
        echo "Current Secret:  $masked_s"
        echo
        echo "1) Configure both DCE API Key and Secret"
        echo "2) Configure DCE API Key only"
        echo "3) Configure DCE Secret only"
        echo "4) Clear DCE credentials"
        echo "0) Cancel"
        local choice
        choice=$(ask "Choose: ") || return 0
        case $choice in
            1)
                key=$(fv_read_secret "Enter DCE API Key: ") || return 0
                secret=$(fv_read_secret "Enter DCE Secret: ") || return 0
                if [[ -z $key || -z $secret ]]; then
                    warn "Both API Key and Secret are required by DCE."
                fi
                ;;
            2)
                key=$(fv_read_secret "Enter DCE API Key: ") || return 0
                secret="$curr_s"
                ;;
            3)
                key="$curr_k"
                secret=$(fv_read_secret "Enter DCE Secret: ") || return 0
                ;;
            4)
                key=""
                secret=""
                ;;
            *) return 0 ;;
        esac
    else
        case ${arg1,,} in
            status | show)
                masked_k="none"
                if [[ -n $curr_k ]]; then
                    masked_k="${curr_k:0:4}****${curr_k: -4}"
                    (( ${#curr_k} <= 8 )) && masked_k="****"
                fi
                masked_s="none"
                if [[ -n $curr_s ]]; then
                    masked_s="${curr_s:0:4}****${curr_s: -4}"
                    (( ${#curr_s} <= 8 )) && masked_s="****"
                fi
                echo "FuturesView DCE API Key: $masked_k"
                echo "FuturesView DCE Secret:  $masked_s"
                return 0
                ;;
            clear | none | off | delete | del | disable | disabled | 0)
                key=""
                secret=""
                ;;
            -)
                if [[ -t 0 ]]; then
                    read -r -s -p "Enter DCE API Key: " key || { echo; return 0; }
                    echo
                    read -r -s -p "Enter DCE Secret: " secret || { echo; return 0; }
                    echo
                else
                    read -r key || true
                    read -r secret || true
                fi
                ;;
            key | apikey)
                if [[ $arg2 == - ]]; then
                    if [[ -t 0 ]]; then
                        read -r -s -p "Enter DCE API Key: " key || { echo; return 0; }
                        echo
                    else
                        read -r key || true
                    fi
                else
                    [[ -n $arg2 ]] && warn "Passing API credentials directly as CLI arguments may expose them in process lists and shell history. Prefer interactive 'vpsm fv apikey' or '-' via stdin."
                    key=$arg2
                fi
                secret="$curr_s"
                ;;
            secret | sec)
                key="$curr_k"
                if [[ $arg2 == - ]]; then
                    if [[ -t 0 ]]; then
                        read -r -s -p "Enter DCE Secret: " secret || { echo; return 0; }
                        echo
                    else
                        read -r secret || true
                    fi
                else
                    [[ -n $arg2 ]] && warn "Passing API credentials directly as CLI arguments may expose them in process lists and shell history. Prefer interactive 'vpsm fv apikey' or '-' via stdin."
                    secret=$arg2
                fi
                ;;
            *)
                warn "Passing API credentials directly as CLI arguments may expose them in process lists and shell history. Prefer interactive 'vpsm fv apikey' or '-' via stdin."
                key=$arg1
                if (($# >= 2)); then
                    secret=$arg2
                else
                    if [[ -t 0 ]]; then
                        secret=$(fv_read_secret "Enter DCE Secret (leave blank to keep current): ") || return 0
                        [[ -z $secret ]] && secret="$curr_s"
                    else
                        secret="$curr_s"
                    fi
                fi
                ;;
        esac
    fi

    if [[ -n $key && $key =~ [[:cntrl:]] ]] || [[ -n $secret && $secret =~ [[:cntrl:]] ]]; then
        err "API credentials must not contain control characters or newlines"
    fi

    VPSM_SECRET_KEY="$key" VPSM_SECRET_SEC="$secret" db_write \
        '.settings.futures_view.dce_api_key = (env.VPSM_SECRET_KEY // "") | .settings.futures_view.dce_secret = (env.VPSM_SECRET_SEC // "")'
    fv_sync_env_file
    install_units
    if [[ -z ${VPSM_NO_SERVICE:-} ]]; then
        systemctl daemon-reload
        if svc_should_restart "$FV_SVC"; then
            systemctl restart "$FV_SVC" || warn "Failed to restart $FV_SVC with new DCE credentials"
        fi
    fi

    if [[ -n $key && -n $secret ]]; then
        ok "FuturesView DCE credentials configured successfully! (API Key and Secret)"
    elif [[ -n $key ]]; then
        warn "FuturesView DCE API Key set, but DCE Secret is missing (DCE needs both)"
    elif [[ -n $secret ]]; then
        warn "FuturesView DCE Secret set, but DCE API Key is missing (DCE needs both)"
    else
        ok "FuturesView DCE credentials cleared"
    fi
}

fv_set_dce_api_key_cmd() {
    fv_set_dce_credentials_cmd "$@"
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
    find "$WWW_DIR" -mindepth 1 -delete 2>/dev/null || rm -rf "${WWW_DIR:?}"/*
    caddy_gen
    caddy_reload
    ok "FuturesView disabled and removed from Caddy routing"

    if [[ -d $FV_DIR ]]; then
        ans=$(ask "Delete the FuturesView directory ($FV_DIR)? [y/N]: ") || return 0
        if [[ ${ans,,} == y ]]; then
            rm -rf "$FV_DIR" "$FV_HOME" "$FV_ENV_FILE"
            ok "Deleted $FV_DIR"
        fi
    fi
}

futures_view_menu() {
    local a state cpu_lim cpu_desc dce_k dce_s dce_desc
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
        dce_s=$(fv_get_dce_secret)
        if [[ -n $dce_k && -n $dce_s ]]; then
            dce_desc="Configured"
        elif [[ -n $dce_k || -n $dce_s ]]; then
            dce_desc="Incomplete"
        else
            dce_desc="Not set"
        fi
        echo "=== FuturesView Panel ==="
        echo "Status: $state"
        echo
        echo "1) Deploy FuturesView (with auto-generated password)"
        echo "2) Update and rebuild (git pull + npm build)"
        echo "3) View / Change WebUI password"
        echo "4) Configure DCE API credentials (current: $dce_desc)"
        echo "5) Configure CPU rate limit (current: $cpu_desc)"
        echo "6) Show status and logs"
        echo "7) Restart service"
        echo "8) Disable / Remove"
        echo "0) Back"
        a=$(ask "Choose: ") || return 0
        case $a in
            1) run_locked fv_deploy ;;
            2) run_locked fv_update ;;
            3) run_locked fv_set_password_cmd ;;
            4) run_locked fv_set_dce_credentials_cmd ;;
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
        key | apikey | dce | dce-key | dce_key | credentials | dce-credentials) shift; fv_set_dce_credentials_cmd "$@" ;;
        cpu | cpulimit | limit) shift; fv_set_cpu_limit_cmd "$@" ;;
        restart) shift; svc_restart fv ;;
        start) shift; svc_start fv ;;
        stop) shift; svc_stop fv ;;
        log) shift; show_log fv ;;
        remove | disable | del) shift; fv_remove "$@" ;;
        *) err "Usage: vpsm fv [deploy|update|status|password|apikey|cpu|restart|log|remove]" ;;
    esac
}

