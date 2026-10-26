plan "uninstall — restore original persistent properties after cleanup"
bootstrap
source_libs
_module="$TEST_ROOT/uninstall_module"
mkdir -p "$_module/lib" "$SPECTER_DIR"
cp "$REPO_ROOT/src/uninstall.sh" "$_module/uninstall.sh"
cp "$REPO_ROOT/src/lib/log.sh" "$_module/lib/log.sh"
cat > "$_module/lib/common.sh" <<'MOCK'
. "$MODDIR/lib/log.sh"
resetprop() {
  case "$*" in
    '-n -p persist.sys.pixelprops.gms original') printf restored > "$TEST_ROOT/result" ;;
    '-p --delete persist.sys.pixelprops.gms') printf deleted > "$TEST_ROOT/result" ;;
  esac
}
getprop() { :; }
stop_specter_scheduler() { :; }
MOCK
printf 'restore|persist.sys.pixelprops.gms|original\n' > "$SPECTER_DIR/persist_backup.txt"
_out=$("${SPECTER_TEST_SHELL:-sh}" "$_module/uninstall.sh" 2>&1); _rc=$?
assert_exit_code "uninstall: completes" 0 "$_rc"
assert_file_eq "uninstall: original persistent value survives" "$TEST_ROOT/result" restored
done_testing
