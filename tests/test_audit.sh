plan "audit regressions — log retention, atomic keybox copy, sanitized exports"
bootstrap
source_libs
_log="$TEST_ROOT/rotation.log"
printf first > "$_log"
SPECTER_LOG_LEVEL=debug log_rotate "$_log" 1 3
printf second > "$_log"
SPECTER_LOG_LEVEL=debug log_rotate "$_log" 1 3
assert_eq "rotation: previous archive retained" first "$(gzip -dc "$_log.2.gz")"
assert_eq "rotation: newest archive retained" second "$(gzip -dc "$_log.1.gz")"

mk_module tricky_store "Tricky Store"
detect_keystore_manager
printf existing > "$KSM_KEYBOX"
printf replacement > "$TEST_ROOT/new.xml"
cp() { echo partial > "$2"; return 1; }
ksm_install_keybox "$TEST_ROOT/new.xml" copy; _rc=$?
unset -f cp
assert_exit_code "keybox copy: reports failure" 1 "$_rc"
assert_file_eq "keybox copy: existing keybox not truncated" "$KSM_KEYBOX" existing
assert_file_exists "keybox copy: source retained on failure" "$TEST_ROOT/new.xml"

mkdir -p "$SPECTER_DIR/log"
cat > "$SPECTER_DIR/log/keybox.log" <<'PEM'
before
-----BEGIN EC PRIVATE KEY-----
PRIVATE-MATERIAL-MUST-NOT-LEAK
-----END EC PRIVATE KEY-----
after
PEM
set_cfg keybox_custom_value 'https://example.invalid/private?token=secret'
SPECTER_EXPORT_DIR="$TEST_ROOT/export" run_feature export_logs.sh >/dev/null
_out=$(cat "$TEST_ROOT/export/specter_logs.txt")
assert_contains "export: keeps useful diagnostics" "$_out" before
assert_contains "export: redacts private PEM by default" "$_out" REDACTED_PRIVATE_KEY
assert_not_contains "export: no private key material" "$_out" PRIVATE-MATERIAL-MUST-NOT-LEAK
assert_not_contains "export: no custom URL credentials" "$_out" 'token=secret'

# Every emitted field must remain valid JSON, including embedded backslashes.
_escaped=$(_escape_json 'A\B"C')
assert_eq "JSON: backslash and quote escaped" 'A\\B\"C' "$_escaped"
_escaped=$(_escape_json "$(printf 'a\tb\nc')")
assert_eq "JSON: tab and newline escaped" 'a\tb\nc' "$_escaped"
# A stale PID file must not kill an unrelated live process (the test shell).
printf '%s' "$$" > "$SPECTER_DIR/scheduler.pid"
stop_specter_scheduler
assert_file_not_exists "scheduler stop: stale PID removed safely" "$SPECTER_DIR/scheduler.pid"

done_testing
