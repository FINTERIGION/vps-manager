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

printf '[\n' >"$CUSTOM_RULES"
if sub_regen force >/dev/null 2>&1; then
    fail_test "invalid custom rules are rejected"
else
    ok_test "invalid custom rules are rejected"
fi
: >"$CUSTOM_RULES"
sub_regen force
assert_success "generated Clash YAML is valid after restoring rules" python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$alice_yaml"

cat >"$TMP/stubs/curl" <<'EOF'
#!/usr/bin/env bash
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
set_node_name "provider: Tokyo" >/dev/null 2>&1
if ( user_attach alice provider https://subscriptions.example/clash.yaml ) >/dev/null 2>&1; then
    fail_test "conflicting external proxy names are rejected before attaching"
else
    ok_test "conflicting external proxy names are rejected before attaching"
fi
assert_eq 0 "$(user_get alice '(.extra_subs // []) | length')" "failed attach leaves the database unchanged"
[[ ! -e "$SUB_EXTRA/alice/provider.proxies.yaml" ]] &&
    ok_test "failed attach removes the cached subscription" || fail_test "failed attach removes the cached subscription"
set_node_name 0 >/dev/null 2>&1
user_attach alice provider https://subscriptions.example/clash.yaml
assert_eq 1 "$(user_get alice '(.extra_subs // []) | length')" "external subscription is attached to one user"
assert_eq 0 "$(user_get bob '(.extra_subs // []) | length')" "external subscription is not shared"
assert_file_contains "$alice_yaml" "provider: Tokyo" "external proxy is merged with an alias"
assert_file_contains "$alice_yaml" "provider: Quote" "quoted external proxy name is rendered"
assert_file_not_contains "$bob_yaml" "provider: Tokyo" "other user's YAML excludes the external proxy"
assert_file_contains "$alice_yaml" "- MATCH,Final" "external rules are not imported"
assert_success "merged Clash YAML remains valid" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert len(d["proxies"]) == 3; assert d["rules"][-1] == "MATCH,Final"' "$alice_yaml"

cache="$SUB_EXTRA/alice/provider.proxies.yaml"
before=$(sha256sum "$cache" | awk '{print $1}')
if CURL_STUB_FAIL=1 extra_sub_fetch alice provider https://subscriptions.example/clash.yaml force >/dev/null 2>&1; then
    fail_test "failed external refresh reports an error"
else
    ok_test "failed external refresh reports an error"
fi
after=$(sha256sum "$cache" | awk '{print $1}')
assert_eq "$before" "$after" "failed refresh keeps the last valid cache"
user_detach alice provider
assert_file_not_contains "$alice_yaml" "provider: Tokyo" "detaching regenerates the user's subscription"
assert_eq 0 "$(user_get alice '(.extra_subs // []) | length')" "detach updates only the owning user"

assert_failure "malformed external YAML is rejected" python3 "$SH_DIR/src/extra_sub.py" normalize \
    "$PROJECT/tests/fixtures/invalid.yaml" bad "$TMP/bad.proxies" "$TMP/bad.names"
assert_failure "duplicate external names are rejected" python3 "$SH_DIR/src/extra_sub.py" normalize \
    "$PROJECT/tests/fixtures/duplicate.yaml" bad "$TMP/dup.proxies" "$TMP/dup.names"
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
assert_file_contains "$PROJECT/vpsm.sh" "=== Security ===" "fixed menu contains the security section"
assert_file_contains "$PROJECT/vpsm.sh" "=== Node ===" "fixed menu contains the node section"
assert_file_contains "$PROJECT/vpsm.sh" "=== System ===" "fixed menu contains the system section"
menu_output=$(printf '0\n' | bash "$PROJECT/vpsm.sh" 2>/dev/null)
if [[ $menu_output == *"1) Change SSH port"* && $menu_output == *"16) Uninstall vpsm"* ]]; then
    ok_test "interactive CLI renders the complete numeric panel"
else
    fail_test "interactive CLI renders the complete numeric panel"
fi
assert_file_contains "$PROJECT/README.md" "## Disclaimer" "README retains the disclaimer heading"
assert_file_contains "$PROJECT/README.md" "The authors accept no liability for any misuse" "README retains the full disclaimer"

printf '\n%d tests passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
