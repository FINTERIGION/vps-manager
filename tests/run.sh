#!/usr/bin/env bash
# vpsm - isolated functional tests; never modify host security or service state
set -o pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for dependency in jq python3; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "Missing test dependency: $dependency. Run install.sh or install jq and Python 3 first." >&2
        exit 1
    fi
done
python3 -c 'import yaml' >/dev/null 2>&1 || {
    echo "Missing test dependency: PyYAML. Install python3-yaml or python3-pyyaml first." >&2
    exit 1
}
TMP=$(mktemp -d "$PROJECT/.test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok_test() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail_test() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert_eq() {
    local expected=$1 actual=$2 label=$3
    if [[ $actual == "$expected" ]]; then ok_test "$label"; else
        fail_test "$label (expected '$expected', got '$actual')"
    fi
}
assert_file_contains() {
    local file=$1 text=$2 label=$3
    if grep -qF -- "$text" "$file"; then ok_test "$label"; else fail_test "$label"; fi
}
assert_file_not_contains() {
    local file=$1 text=$2 label=$3
    if ! grep -qF -- "$text" "$file"; then ok_test "$label"; else fail_test "$label"; fi
}
assert_success() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then ok_test "$label"; else fail_test "$label"; fi
}
assert_failure() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then fail_test "$label"; else ok_test "$label"; fi
}

export VPSM_ROOT="$TMP/root"
export VPSM_NO_SERVICE=1
export VPSM_SSH_DIR="$TMP/ssh"
export VPSM_SYSTEMD_DIR="$TMP/systemd"
export VPSM_SWAP_FILE="$TMP/swap/swapfile"
export VPSM_FSTAB="$TMP/fstab"
mkdir -p "$VPSM_ROOT" "$VPSM_SSH_DIR/sshd_config.d" "$VPSM_SYSTEMD_DIR" "$TMP/stubs"
printf 'Port 22\nInclude %s/sshd_config.d/*.conf\n' "$VPSM_SSH_DIR" >"$VPSM_SSH_DIR/sshd_config"
printf '# test fstab\n' >"$VPSM_FSTAB"

# shellcheck disable=SC1091
. "$PROJECT/src/core.sh"
for lib in xray traffic extra_sub sub caddy user firewall security manage; do
    # shellcheck disable=SC1090
    . "$PROJECT/src/$lib.sh"
done
: >"$CUSTOM_RULES"
db_init node.example.com 443 private public abcd1234 1 2099-12-31

assert_eq 1073741824 "$(parse_quota 1G)" "quota parser uses binary units"
assert_eq "1.50 GB" "$(fmt_size 1610612736)" "size formatter retains the value"
assert_failure "invalid quota is rejected" parse_quota invalid
assert_eq 2099-12-31 "$(parse_expire 2099-12-31)" "absolute expiry parser"
assert_eq "" "$(parse_expire 0)" "never-expire parser"

user_add alice 1G
user_add bob 2G
assert_eq 2 "$(db_get '.users | length')" "two local users are created"
assert_eq 1073741824 "$(user_get alice '.quota')" "first user has an individual quota"
assert_eq 2147483648 "$(user_get bob '.quota')" "second user has a different quota"
[[ $(user_get alice '.token') != "$(user_get bob '.token')" ]] &&
    ok_test "users have independent subscription tokens" || fail_test "users have independent subscription tokens"
[[ $(sub_url alice) != "$(sub_url bob)" ]] &&
    ok_test "users have independent subscription URLs" || fail_test "users have independent subscription URLs"
assert_eq "" "$(user_get alice '.expire // ""')" "per-user expiry is absent"
assert_eq 2099-12-31 "$(db_get '.settings.expire')" "global expiry is stored once"

raw='{"stat":[{"name":"user>>>alice>>>traffic>>>uplink","value":10},{"name":"user>>>alice>>>traffic>>>downlink","value":20}]}'
traffic_apply "$raw"
assert_eq 10 "$(user_get alice '.up')" "local upload counter is accumulated"
assert_eq 20 "$(user_get alice '.down')" "local download counter is accumulated"
assert_eq 0 "$(user_get bob '.up')" "traffic is isolated by user"

db_write '.settings.last_reset = "2000-01" | .settings.reset_day = 1'
traffic_evaluate
assert_eq 0 "$(user_get alice '.up')" "monthly reset clears upload counters"
assert_eq 0 "$(user_get bob '.down')" "monthly reset clears every user"
assert_eq "$(date +%Y-%m)" "$(db_get '.settings.last_reset')" "monthly reset marker is updated"

set_expire 2000-01-01
assert_eq expired "$(user_get alice '.disabled_reason')" "global expiry disables first user"
assert_eq expired "$(user_get bob '.disabled_reason')" "global expiry disables second user"
[[ ! -f "$SUB_DIR/$(user_get alice '.token').yaml" ]] &&
    ok_test "expired user cannot obtain subscription" || fail_test "expired user cannot obtain subscription"
[[ ! -f "$CADDY_USERS/alice.conf" ]] &&
    ok_test "expired user Caddy route is removed" || fail_test "expired user Caddy route is removed"
set_expire 2099-12-31
assert_eq "" "$(user_get alice '.disabled_reason')" "extending global expiry restores eligible users"

alice_yaml="$SUB_DIR/$(user_get alice '.token').yaml"
bob_yaml="$SUB_DIR/$(user_get bob '.token').yaml"
assert_file_contains "$alice_yaml" "name: \"node.example.com\"" "local VLESS node is rendered"
assert_file_contains "$alice_yaml" "- MATCH,Final" "original final Clash rule is retained"
assert_success "generated Clash YAML is valid" python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$alice_yaml"
assert_file_contains "$XRAY_CONF" '"queryStrategy": "UseIPv4"' "Xray DNS defaults to IPv4"
assert_file_contains "$XRAY_CONF" '"domainStrategy": "ForceIPv4"' "Xray outbound defaults to IPv4"
assert_file_contains "$alice_yaml" "ip-version: ipv4" "Clash node defaults to IPv4"

db_write '.users |= map(if .name == "alice" then .up = 12345 else . end)'
sub_regen
assert_file_contains "$CADDY_USERS/alice.conf" "upload=12345" "subscription info refreshes without full regeneration"
db_write '.users |= map(if .name == "alice" then .up = 0 else . end)'
sub_regen

db_write '.users |= map(if .name == "alice" then .up = 2147483648 else . end)'
traffic_evaluate
assert_eq quota "$(user_get alice '.disabled_reason')" "quota exceeded marks user quota-disabled"
sub_regen force
[[ -f "$alice_yaml" ]] &&
    ok_test "quota-exceeded user can still obtain subscription" || fail_test "quota-exceeded user can still obtain subscription"
db_write '.users |= map(if .name == "alice" then .up = 0 else . end)'
traffic_evaluate
sub_regen force

printf '[\n' >"$CUSTOM_RULES"
if sub_regen force >/dev/null 2>&1; then
    fail_test "invalid custom rules are rejected"
else
    ok_test "invalid custom rules are rejected"
fi
: >"$CUSTOM_RULES"
sub_regen force
assert_success "generated Clash YAML is valid after restoring rules" python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$alice_yaml"

mkdir -p "$BIN_DIR"
printf 'v26.7.28\n' >"$BIN_DIR/xray.version"
sub_regen force
assert_file_contains "$alice_yaml" "support-x25519mlkem768: false" "legacy Xray keeps ML-KEM out of the subscription"
if vless_share_url alice | grep -qF -- "support-x25519mlkem768"; then
    fail_test "legacy Xray keeps ML-KEM out of the share link"
else
    ok_test "legacy Xray keeps ML-KEM out of the share link"
fi
printf 'v26.9.9\n' >"$BIN_DIR/xray.version"
sub_regen force
assert_file_contains "$alice_yaml" "support-x25519mlkem768: true" "new Xray enables ML-KEM in the subscription"
if vless_share_url alice | grep -qF -- "support-x25519mlkem768=true"; then
    ok_test "new Xray enables ML-KEM in the share link"
else
    fail_test "new Xray enables ML-KEM in the share link"
fi
rm -f "$BIN_DIR/xray.version"
sub_regen force

assert_eq "v26.7.28" "$(normalize_tag 26.7.28)" "a bare version gets the v prefix"
assert_eq "v26.7.28" "$(normalize_tag V26.7.28)" "an upper-case prefix is normalized"
github_latest() { printf 'v9.9.9\n'; }
tag_exists() { [[ $2 == v9.9.9 ]]; }
assert_eq "v9.9.9" "$(update_target_tag XTLS/Xray-core "$BIN_DIR/xray.version" 9.9.9)" \
    "an existing tag is accepted and normalized"
if ( update_target_tag XTLS/Xray-core "$BIN_DIR/xray.version" v0.0.0 ) >/dev/null 2>&1; then
    fail_test "an unknown tag is rejected"
else
    ok_test "an unknown tag is rejected"
fi
printf 'v9.9.9\n' >"$BIN_DIR/xray.version"
assert_eq "" "$(update_target_tag XTLS/Xray-core "$BIN_DIR/xray.version")" \
    "an already installed release is not downloaded again"
rm -f "$BIN_DIR/xray.version"

cat >"$TMP/stubs/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_ARGS_LOG"
out=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ ${CURL_STUB_FAIL:-0} == 1 ]] && exit 22
cp "$FIXTURE" "$out"
EOF
chmod 755 "$TMP/stubs/curl"
export PATH="$TMP/stubs:$PATH"
export FIXTURE="$PROJECT/tests/fixtures/valid.yaml"
export CURL_ARGS_LOG="$TMP/curl.args"
: >"$CURL_ARGS_LOG"
set_node_name Tokyo >/dev/null 2>&1
if ( extra_sub_attach provider https://subscriptions.example/clash.yaml ) >/dev/null 2>&1; then
    fail_test "conflicting external proxy names are rejected before attaching"
else
    ok_test "conflicting external proxy names are rejected before attaching"
fi
assert_eq 0 "$(extra_sub_count)" "failed attach leaves the database unchanged"
[[ ! -e "$SUB_EXTRA/provider.proxies.yaml" ]] &&
    ok_test "failed attach removes the cached subscription" || fail_test "failed attach removes the cached subscription"
set_node_name 0 >/dev/null 2>&1
if ( extra_sub_attach ssrf http://127.0.0.1:10085/sub.yaml ) >/dev/null 2>&1; then
    fail_test "attaching loopback URL is rejected"
else
    ok_test "attaching loopback URL is rejected"
fi
if ( extra_sub_attach metadata http://169.254.169.254/latest/meta-data/ ) >/dev/null 2>&1; then
    fail_test "attaching cloud metadata URL is rejected"
else
    ok_test "attaching cloud metadata URL is rejected"
fi
extra_sub_attach provider https://subscriptions.example/clash.yaml ""
assert_file_contains "$CURL_ARGS_LOG" "-A clash-verge" "external fetch presents a Clash user agent"
assert_eq 1 "$(extra_sub_count)" "external subscription is stored once"
assert_eq 0 "$(db_get '.settings.extra_subs[0].filter | length')" "node filter defaults to empty"
assert_file_contains "$alice_yaml" "name: Tokyo" "external proxy keeps its original name"
assert_file_not_contains "$alice_yaml" "provider: Tokyo" "external proxy name is not prefixed with the alias"
assert_file_contains "$bob_yaml" "name: Tokyo" "external subscription is shared by every user"
assert_file_contains "$alice_yaml" "- MATCH,Final" "external rules are not imported"
assert_success "merged Clash YAML remains valid" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert len(d["proxies"]) == 3; assert d["rules"][-1] == "MATCH,Final"' "$alice_yaml"

export FIXTURE="$PROJECT/tests/fixtures/mixed.yaml"
extra_sub_attach osaka https://subscriptions.example/mixed.yaml '^Osaka$'
assert_eq 2 "$(extra_sub_count)" "a second shared subscription is attached with a filter"
assert_file_contains "$SUB_EXTRA/osaka.names.yaml" "Osaka" "filter keeps the matching node"
assert_file_not_contains "$SUB_EXTRA/osaka.names.yaml" "SkipMe" "filter drops the other nodes"
assert_file_contains "$bob_yaml" "name: Osaka" "filtered nodes reach every user"
export FIXTURE="$PROJECT/tests/fixtures/valid.yaml"
if ( extra_sub_attach dupe https://subscriptions.example/dupe.yaml ) >/dev/null 2>&1; then
    fail_test "duplicate node names across subscriptions are rejected"
else
    ok_test "duplicate node names across subscriptions are rejected"
fi
assert_eq 2 "$(extra_sub_count)" "failed duplicate attach keeps the shared list unchanged"
[[ ! -e "$SUB_EXTRA/dupe.names.yaml" ]] &&
    ok_test "failed duplicate attach removes its cache" || fail_test "failed duplicate attach removes its cache"

extra_sub_set_filter provider '^Tokyo$'
assert_eq '^Tokyo$' "$(db_get '.settings.extra_subs[] | select(.alias == "provider") | .filter')" "node filter is stored"
list_output=$(extra_sub_list)
[[ $list_output == *"provider"* && $list_output == *'^Tokyo$'* ]] &&
    ok_test "subscription list shows every alias with its filter" || fail_test "subscription list shows every alias with its filter"
assert_file_contains "$SUB_EXTRA/provider.names.yaml" "Tokyo" "refreshed filter keeps the matching node"
assert_file_not_contains "$SUB_EXTRA/provider.names.yaml" "Quote" "refreshed filter drops the other nodes"
before_filter=$(db_get '.settings.extra_subs[] | select(.alias == "provider") | .filter')
if ( extra_sub_set_filter provider '(' ) >/dev/null 2>&1; then
    fail_test "invalid filter regular expressions are rejected"
else
    ok_test "invalid filter regular expressions are rejected"
fi
assert_eq "$before_filter" "$(db_get '.settings.extra_subs[] | select(.alias == "provider") | .filter')" \
    "a rejected filter leaves the previous filter"
if ( extra_sub_set_filter provider '^Nope$' ) >/dev/null 2>&1; then
    fail_test "a filter without matches is rejected"
else
    ok_test "a filter without matches is rejected"
fi

: >"$SUB_STAMP"
touch -d '13 hours ago' "$SUB_EXTRA/provider.stamp"
extra_sub_refresh all
[[ ! -e $SUB_STAMP ]] && ok_test "a due refresh invalidates the full-render stamp" ||
    fail_test "a due refresh invalidates the full-render stamp"
sub_regen force

cache="$SUB_EXTRA/provider.proxies.yaml"
before=$(sha256sum "$cache" | awk '{print $1}')
if CURL_STUB_FAIL=1 extra_sub_refresh all force >/dev/null 2>&1; then
    fail_test "failed external refresh reports an error"
else
    ok_test "failed external refresh reports an error"
fi
after=$(sha256sum "$cache" | awk '{print $1}')
assert_eq "$before" "$after" "failed refresh keeps the last valid cache"
db_write '.settings.extra_subs |= map(if .alias == "osaka" then .filter = "" else . end)'
if extra_sub_refresh all force >/dev/null 2>&1; then
    fail_test "refresh reports regeneration failures"
else
    ok_test "refresh reports regeneration failures"
fi
assert_file_contains "$SUB_EXTRA/osaka.names.yaml" "Tokyo" "the failed refresh still updates its cache"
assert_file_not_contains "$alice_yaml" "Quote" "a rejected regeneration leaves the subscriptions unchanged"
extra_sub_detach provider
extra_sub_detach osaka
assert_eq 0 "$(extra_sub_count)" "detaching removes every shared subscription"
assert_file_not_contains "$alice_yaml" "Tokyo" "detaching regenerates every user's subscription"
assert_file_not_contains "$bob_yaml" "Osaka" "detaching removes the shared nodes from other users"

db_write --arg u 'https://legacy.example/sub.yaml' \
    '.users |= map(if .name == "alice" then .extra_subs = [{alias:"legacy",url:$u}] else . end)'
db_write --arg u 'https://legacy.example/other.yaml' \
    '.users |= map(if .name == "bob" then .extra_subs = [{alias:"legacy",url:$u}] else . end)'
mkdir -p "$SUB_EXTRA/alice"
cp "$PROJECT/tests/fixtures/mixed.yaml" "$SUB_EXTRA/alice/legacy.proxies.yaml"
printf '      - Legacy\n' >"$SUB_EXTRA/alice/legacy.names.yaml"
: >"$SUB_EXTRA/alice/legacy.stamp"
migration_output=$(db_migrate 2>&1)
assert_eq 1 "$(extra_sub_count)" "legacy per-user subscriptions become shared"
[[ $migration_output == *"legacy"* ]] &&
    ok_test "migration warns about aliases shared by several users" || fail_test "migration warns about aliases shared by several users"
assert_eq https://legacy.example/sub.yaml "$(db_get '.settings.extra_subs[0].url')" "migrated subscription keeps its URL"
assert_eq 0 "$(db_get '(.users[] | select(.name == "alice") | .extra_subs // []) | length')" \
    "legacy per-user subscription fields are dropped"
[[ -f $SUB_EXTRA/legacy.names.yaml && ! -d $SUB_EXTRA/alice ]] &&
    ok_test "legacy per-user cache is moved to the shared layout" || fail_test "legacy per-user cache is moved to the shared layout"
db_write '.settings.extra_subs = []'
rm -f "$SUB_EXTRA/legacy".*.yaml "$SUB_EXTRA/legacy.stamp"
sub_regen force

assert_failure "malformed external YAML is rejected" python3 "$SH_DIR/src/extra_sub.py" normalize \
    "$PROJECT/tests/fixtures/invalid.yaml" "" "$TMP/bad.proxies" "$TMP/bad.names"
assert_failure "duplicate external names are rejected" python3 "$SH_DIR/src/extra_sub.py" normalize \
    "$PROJECT/tests/fixtures/duplicate.yaml" "" "$TMP/dup.proxies" "$TMP/dup.names"
assert_failure "invalid filter regular expressions are rejected by the parser" python3 "$SH_DIR/src/extra_sub.py" check-filter "("
assert_success "empty filters are accepted by the parser" python3 "$SH_DIR/src/extra_sub.py" check-filter ""
printf '      - node.example.com\n' >"$TMP/conflict.names"
assert_failure "local and external name conflicts are rejected" python3 "$SH_DIR/src/extra_sub.py" check-names \
    "$TMP/conflict.names" node.example.com

assert_eq 53/udp "$(fw_parse_spec 53/udp)" "firewall port parser supports UDP"
assert_eq 10000-20000/tcp "$(fw_parse_spec 10000-20000)" "firewall range parser applies TCP default"
fw_rules 4 >"$TMP/fw.rules"
assert_file_contains "$TMP/fw.rules" ":VPSM-IN" "firewall uses a dedicated input chain"
assert_file_contains "$TMP/fw.rules" "--dport 443" "firewall allows the Xray port"
assert_file_contains "$TMP/fw.rules" "RELATED,ESTABLISHED" "firewall preserves established connections"
fw_guard_rules >"$TMP/fw-guard.rules"
assert_file_contains "$TMP/fw-guard.rules" "--uid-owner 0" "Xray API guard is root-only"
assert_file_contains "$XRAY_CONF" '"port": "10085"' "Xray routing explicitly blocks proxy clients from API port"

cat >"$TMP/stubs/sshd" <<'EOF'
#!/usr/bin/env bash
exit "${SSHD_STUB_RC:-0}"
EOF
cat >"$TMP/stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" is-active "* | *" is-enabled "*) exit 1 ;;
    *" cat ssh.service "*) exit 0 ;;
    *" restart ssh.service "*)
        [[ ${SSH_STUB_LISTEN:-1} == 1 ]] && : >"$SSH_TEST_LISTEN"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$TMP/stubs/sshd" "$TMP/stubs/systemctl"
export SSH_TEST_LISTEN="$TMP/ssh-listening"
port_in_use() { [[ -f $SSH_TEST_LISTEN ]]; }
if ( set_port 22 ) >/dev/null 2>&1; then
    fail_test "Xray port cannot equal the SSH port"
else
    ok_test "Xray port cannot equal the SSH port"
fi
unset VPSM_NO_SERVICE
ssh_change_port 2222 >/dev/null 2>&1
assert_file_contains "$SSH_DROPIN" "Port 2222" "SSH success writes the managed drop-in"
assert_eq "2222" "$(fw_sshd_ports)" "SSH change disables other configured ports"
assert_file_contains "$VPSM_SSH_DIR/sshd_config" "# vpsm-disabled: Port 22" "old sshd Port directive is disabled"
assert_eq false "$(db_get --arg s '2222/tcp' '(.settings.firewall.allow // []) | any(.[]; . == $s)')" \
    "temporary SSH firewall allowance is removed"
rm -f "$SSH_TEST_LISTEN"
if (export SSH_STUB_LISTEN=0; ssh_change_port 2233 >/dev/null 2>&1); then
    fail_test "failed SSH listener triggers an error"
else
    ok_test "failed SSH listener triggers an error"
fi
assert_file_contains "$SSH_DROPIN" "Port 2222" "SSH rollback restores the previous drop-in"
assert_eq "2222" "$(fw_sshd_ports)" "SSH rollback leaves only the previous port"
assert_file_contains "$VPSM_SSH_DIR/sshd_config" "# vpsm-disabled: Port 22" "SSH rollback keeps the previous Port state"
assert_file_not_contains "$VPSM_SSH_DIR/sshd_config" "Port 2233" "SSH rollback removes the failed Port"
assert_eq false "$(db_get --arg s '2233/tcp' '(.settings.firewall.allow // []) | any(.[]; . == $s)')" \
    "SSH rollback removes its temporary firewall allowance"
export VPSM_NO_SERVICE=1

cat >"$TMP/stubs/fallocate" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case $1 in
        -l) size=$2; shift 2 ;;
        *) file=$1; shift ;;
    esac
done
: >"$file"
EOF
for tool in mkswap swapon swapoff; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/stubs/$tool"
    chmod 755 "$TMP/stubs/$tool"
done
chmod 755 "$TMP/stubs/fallocate"
unset VPSM_NO_SERVICE
swap_set 1M >/dev/null 2>&1
[[ -f $SWAP_FILE ]] && ok_test "swap creation uses the dedicated file" || fail_test "swap creation uses the dedicated file"
assert_file_contains "$FSTAB" "$SWAP_FILE none swap sw 0 0" "swap creation persists fstab"
swap_set 2M >/dev/null 2>&1
assert_eq 1 "$(awk -v file="$SWAP_FILE" '$1 == file {n++} END {print n+0}' "$FSTAB")" "swap resize keeps one fstab entry"
swap_off >/dev/null 2>&1
[[ ! -e $SWAP_FILE ]] && ok_test "swap off removes only the managed file" || fail_test "swap off removes only the managed file"
assert_eq 0 "$(awk -v file="$SWAP_FILE" '$1 == file {n++} END {print n+0}' "$FSTAB")" "swap off removes its fstab entry"
export VPSM_NO_SERVICE=1

# apply_state must force a restart when the Xray API is unavailable
mkdir -p "$BIN_DIR"
cat >"$XRAY_BIN" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "run -test") exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$XRAY_BIN"
cat >"$TMP/stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSTEMCTL_LOG"
exit 0
EOF
chmod 755 "$TMP/stubs/systemctl"
export SYSTEMCTL_LOG="$TMP/systemctl.log"
: >"$SYSTEMCTL_LOG"
unset VPSM_NO_SERVICE
xray_active() { return 0; }
traffic_pull() { return 1; }
xray_adu() { return 1; }
user_add carol 0 >/dev/null 2>&1
assert_file_contains "$XRAY_CONF" '"email": "carol"' "force restart writes the new user into the config"
if grep -q 'restart vpsm-xray' "$SYSTEMCTL_LOG"; then
    ok_test "API failure still forces an Xray restart"
else
    fail_test "API failure still forces an Xray restart"
fi
before_restarts=$(grep -c 'restart vpsm-xray' "$SYSTEMCTL_LOG")
svc_restart xray >/dev/null 2>&1
after_restarts=$(grep -c 'restart vpsm-xray' "$SYSTEMCTL_LOG")
assert_eq "$((before_restarts + 1))" "$after_restarts" "manual restart forces Xray when the API is unavailable"
export VPSM_NO_SERVICE=1

apply_state() { return 1; }
if ( user_add dave 0 ) >/dev/null 2>&1; then
    fail_test "failed user add is rolled back"
else
    ok_test "failed user add is rolled back"
fi
assert_eq 0 "$(db_get '.users | map(select(.name == "dave")) | length')" "failed user add leaves the database unchanged"

gen_x25519() { printf 'newpriv\nnewpub\n'; }
xray_gen_config() { return 1; }
old_key=$(db_get '.settings.private_key')
if ( set_key anykey ) >/dev/null 2>&1; then
    fail_test "failed key rotation is rolled back"
else
    ok_test "failed key rotation is rolled back"
fi
assert_eq "$old_key" "$(db_get '.settings.private_key')" "failed key rotation keeps the previous key"

if grep -R -E -n 'cluster_cmd|cluster_is|menu_cluster|cluster_(init|join|report|fetch)' \
    "$PROJECT/src" "$PROJECT/systemd" "$PROJECT/vpsm.sh" "$PROJECT/install.sh" >/dev/null; then
    fail_test "production code contains no cluster runtime calls"
else
    ok_test "production code contains no cluster runtime calls"
fi
help_output=$(bash "$PROJECT/vpsm.sh" help)
[[ $help_output == *"single-node multi-user"* ]] && ok_test "English CLI help is available" || fail_test "English CLI help is available"
menu_output=$(printf '0\n' | bash "$PROJECT/vpsm.sh" 2>/dev/null)
if [[ $menu_output == *"1) Change SSH port"* && $menu_output == *"16) Uninstall vpsm"* ]]; then
    ok_test "interactive CLI renders the complete numeric panel"
else
    fail_test "interactive CLI renders the complete numeric panel"
fi
if [[ $menu_output == *" Security "* && $menu_output == *" Node "* && $menu_output == *" System "* ]]; then
    ok_test "fixed menu renders every category"
else
    fail_test "fixed menu renders every category"
fi
menu_section=$(printf '%s\n' "$menu_output" | grep -m1 ' Security ')
menu_left=${menu_section%% Security*}
menu_right=${menu_section##* Security }
assert_eq "${#menu_left}" "${#menu_right}" "category titles are centered"
menu_first=$(printf '%s\n' "$menu_output" | head -n 1)
[[ $menu_first == *"vpsm $VPSM_VERSION"* ]] && ok_test "menu banner shows the script version" || fail_test "menu banner shows the script version"
menu_panel_width=$(printf '%s\n' "$menu_output" | awk '{ if (length($0) > w) w = length($0) } END { print w }')
assert_eq "$menu_panel_width" "${#menu_first}" "menu rules are as wide as the longest line"
menu_bad_rules=$(printf '%s\n' "$menu_output" | awk -v w="$menu_panel_width" 'substr($0, 1, 3) == "===" { if (length($0) != w) c++ } END { print c + 0 }')
assert_eq 0 "$menu_bad_rules" "every category rule spans the panel width"
assert_file_contains "$PROJECT/README.md" "## Disclaimer" "README retains the disclaimer heading"
assert_file_contains "$PROJECT/README.md" "The authors accept no liability for any misuse" "README retains the full disclaimer"

printf '\n%d tests passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
