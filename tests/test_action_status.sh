plan "action pipeline — propagate failures through tee and keep later features running"
bootstrap
source_libs
_module="$TEST_ROOT/module"
mkdir -p "$_module/lib" "$_module/features"
cp "$REPO_ROOT/src/action.sh" "$_module/"
cp "$REPO_ROOT/src/lib/log.sh" "$_module/lib/"
cat > "$_module/lib/common.sh" <<'MOCK'
. "$MODDIR/lib/log.sh"
ensure_dir() { mkdir -p "$1"; }
cfg_get() { echo 0; }
_feature_should_run() { case "$1" in keybox|pif) return 0 ;; *) return 1 ;; esac; }
_pif_prop() { echo 'fixture PIF'; }
run_device_info() { return 0; }
MOCK
printf 'refresh_module_description() { :; }\n' > "$_module/lib/desc.sh"
cat > "$_module/features/keybox.sh" <<'MOCK'
echo 'Fatal: fixture keybox fetch failed' >&2
exit "${TEST_KEYBOX_EXIT:-7}"
MOCK
printf 'echo "PIF still ran"\n' > "$_module/features/pif.sh"
printf ':\n' > "$_module/features/keybox_info.sh"
printf ':\n' > "$_module/features/keystore_info.sh"
_out=$("${SPECTER_TEST_SHELL:-sh}" "$_module/action.sh" 2>&1); _rc=$?
assert_exit_code "action: feature failure is nonzero" 1 "$_rc"
assert_contains "action: later features run" "$_out" 'PIF still ran'
assert_contains "action: summary reports errors" "$_out" 'Integrity pipeline completed with errors'
assert_not_contains "action: no false success summary" "$_out" 'Full integrity pipeline completed'
assert_contains "action: failure log has original diagnostic" "$(cat "$SPECTER_DIR/log/action.log")" 'fixture keybox fetch failed'
assert_contains "action: history records failure" "$(tail -1 "$SPECTER_DIR/log/history.jsonl")" '"code":1'
_out=$(TEST_KEYBOX_EXIT=0 "${SPECTER_TEST_SHELL:-sh}" "$_module/action.sh" 2>&1); _rc=$?
assert_exit_code "action: successful pipeline returns zero" 0 "$_rc"
assert_contains "action: successful summary" "$_out" 'Full integrity pipeline completed'
assert_contains "action: successful history" "$(tail -1 "$SPECTER_DIR/log/history.jsonl")" '"code":0'
assert_eq "action: status files removed" '' "$(ls "$SPECTER_DIR/log"/.action_status.* 2>/dev/null)"
done_testing
