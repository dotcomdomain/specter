plan "keybox fetch — provider recovery, signed random indexes, validation and logs"
bootstrap
source_libs
mk_module tricky_store "Tricky Store"
_module="$TEST_ROOT/module"
mkdir -p "$_module"
cp -R "$REPO_ROOT/src/lib" "$REPO_ROOT/src/features" "$_module/"
FIXTURE_OVERRIDES="$TEST_ROOT/overrides.sh"
export FIXTURE_OVERRIDES
printf '\n. "$FIXTURE_OVERRIDES"\n' >> "$_module/lib/common.sh"
cat > "$FIXTURE_OVERRIDES" <<'MOCK'
# Only this isolated module copy sees these overrides.
keybox_catalog() { cat "$TEST_ROOT/catalog.json"; }
check_network() { return 1; } # A blocked connectivity probe must not block fetch.
decode_keybox_serial() { printf 'a\n'; }
check_google_revocation() { return "${TEST_REVOCATION_RC:-1}"; }
hexdump() { printf FFFFFFFF; }
download() {
  echo "$1" >> "$TEST_ROOT/downloads"
  if [ "$1" = 'https://fixture/xml' ]; then
    cp "$TEST_ROOT/keybox.xml" "$2"
  elif [ "$1" = 'https://fixture/invalid' ]; then
    printf '<html>not a keybox</html>' > "$2"
  else
    base64 < "$TEST_ROOT/keybox.xml" | tr "$STD_ALPHABET" "$SHUFFLED_ALPHABET" > "$2"
  fi
}
MOCK
cat > "$TEST_ROOT/keybox.xml" <<'XML'
<AndroidAttestation><Keybox DeviceID="fixture"><Key algorithm="ecdsa">
<PrivateKey>-----BEGIN EC PRIVATE KEY-----
TEST-FIXTURE-ONLY
-----END EC PRIVATE KEY-----</PrivateKey>
<CertificateChain><Certificate>-----BEGIN CERTIFICATE-----
TEST-FIXTURE-ONLY
-----END CERTIFICATE-----</Certificate></CertificateChain>
</Key></Keybox></AndroidAttestation>
XML
cat > "$TEST_ROOT/catalog.json" <<'JSON'
{"entries":[{"source":"TAKR","version":"34","text":"34","revoked":false,"softbanned":false},{"source":"TAKR","version":"33","text":"33","revoked":false,"softbanned":false}]}
JSON
_fetch() {
  TMPDIR="$TEST_ROOT" PATH="$BIN_DIR:$SPECTER_TEST_PATH" "${SPECTER_TEST_SHELL:-sh}" "$_module/features/keybox.sh" "$@" 2>&1
}
set_cfg keybox_provider KOW
_out=$(_fetch); _rc=$?
assert_exit_code "removed provider: recovers" 0 "$_rc"
assert_contains "removed provider: explains Auto fallback" "$_out" "no longer available; switching to Auto"
assert_file_eq "removed provider: repairs saved setting" "$CONFIG_DIR/val/keybox_provider.val" auto
assert_file_eq "Auto: installs validated candidate" "$TRICKY_DIR/keybox.xml" "$(cat "$TEST_ROOT/keybox.xml")"
assert_contains "Auto: FFFFFFFF stays in range" "$_out" "entry 2 of 2"
assert_contains "direct fetch: persistent log" "$(cat "$SPECTER_DIR/log/keybox.log")" 'Keybox installed successfully'
assert_not_contains "persistent log: excludes private key material" "$(cat "$SPECTER_DIR/log/keybox.log")" TEST-FIXTURE-ONLY

# Version labels with a v prefix must sort numerically, not lexicographically.
printf '%s' '{"entries":[{"source":"test.[1]","version":"v2","text":"2","revoked":false,"softbanned":false},{"source":"test.[1]","version":"v10","text":"10","revoked":false,"softbanned":false}]}' > "$TEST_ROOT/catalog.json"
set_cfg keybox_provider 'test.[1]'
: > "$TEST_ROOT/downloads"
_out=$(_fetch); _rc=$?
assert_exit_code "explicit provider: regex characters are literal" 0 "$_rc"
assert_contains "explicit provider: newest prefixed version first" "$(head -1 "$TEST_ROOT/downloads")" '/test.[1]/v10'

# All-revoked is distinct from a removed provider; never install or change it.
printf '%s' '{"entries":[{"source":"TAKR","version":"34","revoked":true,"softbanned":false}]}' > "$TEST_ROOT/catalog.json"
set_cfg keybox_provider TAKR
printf 'existing-keybox' > "$TRICKY_DIR/keybox.xml"
_out=$(_fetch); _rc=$?
assert_exit_code "all revoked: failure survives tee" 1 "$_rc"
assert_contains "all revoked: explains provider failure" "$_out" "No non-revoked keyboxes available for provider 'TAKR'"
assert_file_eq "all revoked: installed file unchanged" "$TRICKY_DIR/keybox.xml" existing-keybox
assert_contains "all revoked: persistent error" "$(cat "$SPECTER_DIR/log/keybox.log")" 'No non-revoked keyboxes'

# Imported XML URLs are documented in the UI and must work without encoding.
set_cfg keybox_custom_type url
set_cfg keybox_custom_value https://fixture/xml
_out=$(_fetch); _rc=$?
assert_exit_code "custom URL: accepts raw XML" 0 "$_rc"
assert_file_eq "custom URL: installed XML" "$TRICKY_DIR/keybox.xml" "$(cat "$TEST_ROOT/keybox.xml")"
set_cfg keybox_custom_type url
set_cfg keybox_custom_value https://fixture/invalid
printf 'existing-keybox' > "$TRICKY_DIR/keybox.xml"
_out=$(_fetch); _rc=$?
assert_exit_code "custom URL: rejects HTML" 1 "$_rc"
assert_file_eq "custom URL: invalid payload preserves old file" "$TRICKY_DIR/keybox.xml" existing-keybox
set_cfg keybox_custom_type path
set_cfg keybox_custom_value "$TEST_ROOT/catalog.json"
_out=$(_fetch); _rc=$?
assert_exit_code "custom path: rejects non-keybox input" 1 "$_rc"
assert_file_eq "custom path: invalid payload preserves old file" "$TRICKY_DIR/keybox.xml" existing-keybox
set_cfg keybox_custom_type ''
set_cfg keybox_custom_value ''

# Unknown revocation status must never be printed as a successful check.
printf '%s' '{"entries":[{"source":"TAKR","version":"34","text":"34","revoked":false,"softbanned":false}]}' > "$TEST_ROOT/catalog.json"
export TEST_REVOCATION_RC=2
_out=$(_fetch); _rc=$?
unset TEST_REVOCATION_RC
assert_exit_code "CRL unavailable: failure" 1 "$_rc"
assert_contains "CRL unavailable: explains failure" "$_out" 'Could not verify Google revocation status'
assert_not_contains "CRL unavailable: no false clean status" "$_out" 'Keybox is not revoked'
assert_file_eq "CRL unavailable: old file retained" "$TRICKY_DIR/keybox.xml" existing-keybox

done_testing
