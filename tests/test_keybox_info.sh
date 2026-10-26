plan "keybox info — expiring status, decimal serials and offline revocation updates"
bootstrap
source_libs
mk_module tricky_store "Tricky Store"
_module="$TEST_ROOT/module"
mkdir -p "$_module"
cp -R "$REPO_ROOT/src/lib" "$REPO_ROOT/src/features" "$_module/"
FIXTURE_OVERRIDES="$TEST_ROOT/info_overrides.sh"
export FIXTURE_OVERRIDES
printf '\n. "$FIXTURE_OVERRIDES"\n' >> "$_module/lib/common.sh"
cat > "$FIXTURE_OVERRIDES" <<'MOCK'
decode_keybox_serial() { echo ebe82afb8b019ca17bed42839ba51e9e; }
check_google_revocation() { return "${TEST_REVOCATION_RC:-1}"; }
keybox_catalog() { cat "$TEST_ROOT/info_catalog.json"; }
MOCK
printf '<keybox/>\n' > "$TRICKY_DIR/keybox.xml"
cat > "$TEST_ROOT/info_catalog.json" <<'JSON'
{"entries":[{"source":"TAKR","version":"32","text":"32","serial":"313574063671127819551733845561321004702","revoked":false,"softbanned":false}],"latest":{"TAKR":"32"}}
JSON
export SPECTER_KEYBOX_INFO="$TEST_ROOT/info.json"
_info() { "${SPECTER_TEST_SHELL:-sh}" "$_module/features/keybox_info.sh" "$@" 2>&1; }
_out=$(_info); _rc=$?
assert_exit_code "info: refresh succeeds" 0 "$_rc"
assert_contains "info: matches serial wider than 64 bits" "$(cat "$SPECTER_KEYBOX_INFO")" '"source": "TAKR"'
assert_contains "info: records verified revocation status" "$(cat "$SPECTER_KEYBOX_INFO")" '"revocation_checked": true'

# Info newer than keybox but old in real time must not block refreshing forever.
touch -t 202001010000 "$TRICKY_DIR/keybox.xml"
touch -t 202001020000 "$SPECTER_KEYBOX_INFO"
keybox_info_is_fresh "$SPECTER_KEYBOX_INFO" "$TRICKY_DIR/keybox.xml"; _rc=$?
assert_exit_code "freshness: expired metadata rejected despite newer mtime" 1 "$_rc"
export TEST_REVOCATION_RC=0
_out=$(_info --if-needed); _rc=$?
assert_exit_code "info: stale status refreshed" 0 "$_rc"
assert_contains "info: changed CRL updates status" "$(cat "$SPECTER_KEYBOX_INFO")" '"revoked": true'

# A revoked CRL result must be saved even when catalog lookup is unavailable.
printf '' > "$TEST_ROOT/info_catalog.json"
_out=$(_info); _rc=$?
assert_exit_code "info: offline catalog still saves CRL result" 0 "$_rc"
assert_contains "info: offline revocation update retained" "$(cat "$SPECTER_KEYBOX_INFO")" '"revoked": true'
export TEST_REVOCATION_RC=2
_out=$(_info); _rc=$?
assert_exit_code "info: unavailable CRL does not crash" 0 "$_rc"
assert_contains "info: unavailable CRL is explicitly unverified" "$(cat "$SPECTER_KEYBOX_INFO")" '"revocation_checked": false'
unset TEST_REVOCATION_RC SPECTER_KEYBOX_INFO

# The shared CRL helper distinguishes unavailable from a confirmed clean result.
source_libs
download() { return 1; }
rm -f "$SPECTER_DIR/cache/google_revocation.json"
check_google_revocation a; _rc=$?
assert_exit_code "CRL helper: unavailable is distinct" 2 "$_rc"
download() { printf '<html>HTTP error</html>'; }
check_google_revocation a; _rc=$?
assert_exit_code "CRL helper: HTML is not a clean result" 2 "$_rc"
assert_file_not_exists "CRL helper: invalid response not cached" "$SPECTER_DIR/cache/google_revocation.json"

download() { printf '<html>HTTP error</html>'; }
keybox_catalog >/dev/null; _rc=$?
assert_exit_code "catalog helper: HTML is rejected" 1 "$_rc"
assert_file_not_exists "catalog helper: invalid response not cached" "$SPECTER_DIR/cache/keybox_catalog.json"

# Exercise a CRL larger than Android per-argument limits in the actual shell.
cat > "$TEST_ROOT/large_crl.sh" <<'MOCK'
. "$REPO_ROOT/src/lib/log.sh"
. "$REPO_ROOT/src/lib/constants.sh"
. "$REPO_ROOT/src/lib/keybox.sh"
download() {
  awk 'BEGIN {
    printf "{\"entries\":{"
    for (i = 1; i <= 10000; i++) printf "%s\"%d\":{\"status\":\"REVOKED\"}", (i > 1 ? "," : ""), i
    print "}}"
  }'
}
check_google_revocation a
MOCK
rm -f "$SPECTER_DIR/cache/google_revocation.json"
"${SPECTER_TEST_SHELL:-sh}" "$TEST_ROOT/large_crl.sh"; _rc=$?
assert_exit_code "CRL helper: large response processed without argv overflow" 0 "$_rc"
assert_eq "CRL helper: large fixture exceeds 128 KiB" yes "$( [ "$(wc -c < "$SPECTER_DIR/cache/google_revocation.json")" -gt 131072 ] && echo yes )"

done_testing
