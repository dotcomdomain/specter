plan "keybox selection prefers active over softbanned"

bootstrap
source_libs

_CATALOG='{"entries":[{"source":"droidwin","version":"1","text":"v1","serial":"12345","revoked":false,"softbanned":false},{"source":"droidwin","version":"2","text":"v2","serial":"67890","revoked":false,"softbanned":true},{"source":"droidwin","version":"3","text":"v3","serial":"99999","revoked":true,"softbanned":false},{"source":"yuri","version":"8","text":"v8","serial":"11111","revoked":false,"softbanned":true},{"source":"badprov","version":"1","text":"v1","serial":"00000","revoked":true,"softbanned":false}],"working":{"source":"droidwin","version":"1"},"workingEntries":[{"source":"droidwin","version":"1","text":"v1"},{"source":"droidwin","version":"2","text":"v2"},{"source":"yuri","version":"8","text":"v8"}]}'

# --- keybox_is_softbanned ---
keybox_is_softbanned "$_CATALOG" "droidwin" "2"
_rc=$?
assert_eq "is_softbanned: droidwin/2" "0" "$_rc"

keybox_is_softbanned "$_CATALOG" "droidwin" "1"
_rc=$?
assert_eq "is_softbanned: droidwin/1 active" "1" "$_rc"

# --- keybox_prefer_active: mix of active + softbanned -> only active ---
_wk='{"source":"droidwin","version":"1","text":"v1"}
{"source":"droidwin","version":"2","text":"v2"}
{"source":"yuri","version":"8","text":"v8"}'
_pool=$(printf '%s\n' "$_wk" | keybox_prefer_active "$_CATALOG")
assert_contains "prefer_active: keeps active" "$_pool" '"version":"1"'
assert_not_contains "prefer_active: drops softbanned droidwin/2" "$_pool" '"version":"2"'
assert_not_contains "prefer_active: drops softbanned yuri/8" "$_pool" '"version":"8"'

# --- keybox_prefer_active: only softbanned -> softbanned ok ---
_wk_soft='{"source":"droidwin","version":"2","text":"v2"}
{"source":"yuri","version":"8","text":"v8"}'
_pool_soft=$(printf '%s\n' "$_wk_soft" | keybox_prefer_active "$_CATALOG")
assert_contains "prefer_active fallback: softbanned kept" "$_pool_soft" '"version":"2"'
assert_contains "prefer_active fallback: both softbanned kept" "$_pool_soft" '"version":"8"'

# --- keybox_latest_for_provider: skips softbanned and revoked latest ---
_ver=$(keybox_latest_for_provider "$_CATALOG" "droidwin")
assert_eq "latest_for_provider: prefers active over newer softbanned and revoked" "1" "$_ver"

# --- keybox_latest_for_provider: softbanned-only provider ---
_ver_yuri=$(keybox_latest_for_provider "$_CATALOG" "yuri")
assert_eq "latest_for_provider: softbanned when no active" "8" "$_ver_yuri"

# --- keybox_latest_for_provider: all revoked provider returns empty ---
_ver_bad=$(keybox_latest_for_provider "$_CATALOG" "badprov")
assert_eq "latest_for_provider: empty when all revoked" "" "$_ver_bad"

assert_eq "hex_to_dec: issue serial" "3207438651777393527" "$(hex_to_dec 2c831c75c60ca377)"
assert_eq "hex_to_dec: 128-bit serial" "313574063671127819551733845561321004702" "$(hex_to_dec ebe82afb8b019ca17bed42839ba51e9e)"

_dl_count="$TEST_ROOT/downloads"
: > "$_dl_count"
download() { echo x >> "$_dl_count"; printf '%s' "$_CATALOG"; }
_cat1=$(keybox_catalog)
_cat2=$(keybox_catalog)
assert_contains "catalog cache: content" "$_cat2" '"droidwin"'
assert_eq "catalog cache: one download" "1" "$(grep -c x "$_dl_count")"

: > "$_dl_count"
download() { echo x >> "$_dl_count"; printf '%s' '{"entries":{"10":{"status":"REVOKED"},"3207438651777393527":{"status":"REVOKED"}}}'; }
check_google_revocation 2c831c75c60ca377
assert_eq "crl: issue serial is revoked" "0" "$?"
check_google_revocation a
assert_eq "crl: hex a is decimal 10" "0" "$?"
check_google_revocation 10
assert_eq "crl: hex 10 is not decimal 10" "1" "$?"
assert_eq "crl cache: one download" "1" "$(grep -c x "$_dl_count")"

# --- keybox.sh --if-needed skips a healthy installed keybox ---
bootstrap
source_libs
mk_module tricky_store "Tricky Store"
detect_keystore_manager
printf '<keybox/>\n' > "$KSM_KEYBOX"
_ki_info="$TEST_ROOT/keybox_info.json"
printf '{\n  "installed": true,\n  "source": "TAKR",\n  "source_version": "32",\n  "revocation_checked": true,\n  "revoked": false,\n  "softbanned": false\n}\n' > "$_ki_info"
sleep 1
touch "$_ki_info"
export SPECTER_KEYBOX_INFO="$_ki_info"
_out=$(run_feature keybox.sh --if-needed)
assert_contains "if-needed: healthy keybox skipped" "$_out" "Current keybox is healthy, skipping refresh"
_out_info=$(run_feature keybox_info.sh --if-needed)
assert_contains "if-needed: current info skipped" "$_out_info" "Keybox info is current, skipping refresh"
unset SPECTER_KEYBOX_INFO

done_testing
