plan "download — HTTP errors, timeouts, checksum failures and stdout purity"
bootstrap
source_libs
# Shell functions take precedence over installed root-manager binaries.
busybox() { echo 'wget: fixture failure' >&2; return 1; }
sleep() { :; }
curl() {
  [ "$1" != '--version' ] || { echo 'curl fixture'; return 0; }
  _mock_out='' _mock_url=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) _mock_out=$2; shift ;;
      https://*) _mock_url=$1 ;;
    esac
    shift
  done
  case "$_mock_url" in
    */ok) printf '{"entries":[]}' > "$_mock_out" ;;
    */404) printf '<html>Not Found</html>' > "$_mock_out"; echo 'curl: (22) HTTP 404' >&2; return 22 ;;
    */timeout) printf 'partial' > "$_mock_out"; echo 'curl: (28) Operation timed out' >&2; return 28 ;;
  esac
}
_out=$(SPECTER_LOG_LEVEL=debug download https://fixture/ok 2>"$TEST_ROOT/stderr"); _rc=$?
assert_exit_code "download: successful response" 0 "$_rc"
assert_eq "download: debug logs never pollute captured JSON" '{"entries":[]}' "$_out"
assert_contains "download: debug diagnostics on stderr" "$(cat "$TEST_ROOT/stderr")" '[D] [NET]'
printf 'old-content' > "$TEST_ROOT/result"
download https://fixture/404 "$TEST_ROOT/result" 2>"$TEST_ROOT/stderr"; _rc=$?
assert_exit_code "HTTP 404: returns failure" 1 "$_rc"
assert_file_eq "HTTP 404: old destination retained" "$TEST_ROOT/result" old-content
assert_contains "HTTP 404: logs underlying error" "$(cat "$TEST_ROOT/stderr")" 'HTTP 404'
download https://fixture/timeout "$TEST_ROOT/result" 2>"$TEST_ROOT/stderr"; _rc=$?
assert_exit_code "timeout: returns failure" 1 "$_rc"
assert_file_eq "timeout: partial body never replaces destination" "$TEST_ROOT/result" old-content
assert_contains "timeout: logs underlying error" "$(cat "$TEST_ROOT/stderr")" 'Operation timed out'
# Deliberately wrong digest; the mock_env hash command also cannot match it.
download https://fixture/ok "$TEST_ROOT/result" wrong-digest 2>"$TEST_ROOT/stderr"; _rc=$?
assert_exit_code "checksum: returns failure" 1 "$_rc"
assert_file_eq "checksum: old destination retained" "$TEST_ROOT/result" old-content
assert_contains "checksum: useful error" "$(cat "$TEST_ROOT/stderr")" 'SHA256 mismatch'
assert_eq "download: no scratch files after any path" '' "$(ls "$TEST_ROOT"/result.* 2>/dev/null)"
done_testing
