#!/system/bin/sh
set -e
MODDIR=${0%/*}

# shellcheck disable=SC3040
case "$(readlink /proc/$$/exe 2>/dev/null)" in *busybox) set +o standalone; unset ASH_STANDALONE ;; esac

. "$MODDIR/lib/common.sh"

ACTION_LOG="$SPECTER_DIR/log/action.log"
ensure_dir "$SPECTER_DIR/log" 2>/dev/null
log_rotate "$ACTION_LOG"

# Pipeline commands run in a subshell when piped to tee. Carry the actual
# feature status back explicitly instead of reporting tee's successful exit.
_action_status=$(mktemp "$SPECTER_DIR/log/.action_status.XXXXXX")
trap 'rm -f "$_action_status"' EXIT
printf '1\n' > "$_action_status"
_action_code=0
_action_feature() {
  if "$@"; then
    return 0
  else
    _action_feature_rc=$?
    _action_code=1
    log_e "ACTION" "Feature failed (exit $_action_feature_rc): $*"
  fi
}

_pif_validate_fingerprint() {
  for _f in "$SPECTER_DIR/pif.prop" "$PIF_DIR/custom.pif.prop" /data/adb/pif.prop "$PIF_DIR/pif.prop" "$PIF_DIR/custom.pif.json" "$PIF_DIR/pif.json"; do
    [ -f "$_f" ] || continue
    _fp=""
    case "$_f" in
      *.json) _fp=$(grep -o '"FINGERPRINT"[[:space:]]*:[[:space:]]*"[^"]*"' "$_f" 2>/dev/null | head -1 | sed 's/.*"FINGERPRINT"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') ;;
      *) _fp=$(sed -n 's/^FINGERPRINT=//p' "$_f" 2>/dev/null | head -1) ;;
    esac
    [ -z "$_fp" ] && continue
    case "$_fp" in *google*/*release-keys*) unset _f _fp; return 0 ;; esac
  done
  unset _f _fp; return 1
}

_first_boot=0
[ "$SPECTER_FIRST_BOOT" = "1" ] && _first_boot=1
[ -f "$SPECTER_DIR/.first_boot_pending" ] && _first_boot=1
_force_target=$(cfg_get toggle_action_force_target 0)
_force_hma=$(cfg_get toggle_action_force_hma 0)

# The action is intentionally non-interactive. Volume-key prompts blocked the
# WebUI for 10/7 seconds; setup choices live in the WebUI settings instead.
{
  log_i "ACTION" "Running full integrity pipeline"

  _feature_should_run "gms" && {
    log_u "ACTION" ""
    log_u "ACTION" "-> Play Store:"
    if [ "$_first_boot" = "1" ]; then
      log_i "ACTION" "First boot, skipping Play Store data clear"
    else
      _action_feature sh "$MODDIR/features/kill_play_store.sh"
    fi
  }

  if _feature_should_run "target"; then
    log_u "ACTION" ""
    log_u "ACTION" "-> App Targeting:"
    if [ "$_first_boot" = "1" ] || [ "$_force_target" = "1" ] || [ "$(cfg_get toggle_auto_target 1)" != "1" ]; then
      _action_feature sh "$MODDIR/features/target.sh" --merge
    else
      log_i "ACTION" "Auto-targeting is enabled, skipping target generation"
    fi
  fi

  _feature_should_run "security_patch" && {
    log_u "ACTION" ""
    log_u "ACTION" "-> Security Patch:"
    SPECTER_FIRST_BOOT=$_first_boot _action_feature sh "$MODDIR/features/security_patch.sh"
  }

  _feature_should_run "keybox" && {
    log_u "ACTION" ""
    log_u "ACTION" "-> Keybox:"
    _action_feature sh "$MODDIR/features/keybox.sh" --if-needed
  }

  if _feature_should_run "pif"; then
    log_u "ACTION" ""
    log_u "ACTION" "-> Play Integrity Fix:"
    _pif_name=$(_pif_prop) || _pif_name=""
    if [ -z "$_pif_name" ]; then
      if [ "$_first_boot" = "1" ]; then
        log_i "ACTION" "PIF not found, first boot suppress"
      else
        log_w "ACTION" "PIF not installed, skipping fingerprint update"
      fi
      _pif_skip=1
    elif [ "$_first_boot" = "1" ]; then
      log_u "ACTION" ""
      log_u "ACTION" "PIF found, first boot - checking existing fingerprint validity"
      if _pif_validate_fingerprint; then
        log_i "ACTION" "Existing fingerprint valid, skipping fetch"
      else
        log_i "ACTION" "Fingerprint invalid or missing, fetching new"
        _action_feature sh "$MODDIR/features/pif.sh"
      fi
      _pif_skip=1
    fi
    unset _pif_name
    if [ -z "$_pif_skip" ] && [ -f "$MODDIR/features/pif.sh" ]; then
      _action_feature sh "$MODDIR/features/pif.sh"
    fi
  fi

  if _feature_should_run "hma"; then
    log_u "ACTION" ""
    log_u "ACTION" "-> HMA-OSS Config:"
    _hma_config_ok=0
    for _hma_config in "$HMAOSS_BASE"/hide_my_applist*/config.json; do
      [ -s "$_hma_config" ] && { _hma_config_ok=1; break; }
    done
    if [ "$_first_boot" = "1" ] || [ "$_force_hma" = "1" ] || [ "$_hma_config_ok" != "1" ] || [ "$(cfg_get toggle_auto_hma 1)" != "1" ]; then
      [ "$_hma_config_ok" != "1" ] && log_w "ACTION" "HMA config missing, regenerating"
      SPECTER_HMA_NO_UI_RELOAD=1 _action_feature sh "$MODDIR/features/hma.sh"

      _hma_policy=$(_hma_launch_policy)
      _do_launch=0

      if [ "$_first_boot" = "1" ]; then
        log_u "ACTION" "HMA-OSS launch skipped on first boot"
      elif [ "$_hma_policy" = "open" ]; then
        log_u "ACTION" "Auto-launching HMA-OSS (policy: auto-accept)..."
        _do_launch=1
      elif [ "$_hma_policy" = "skip" ]; then
        log_u "ACTION" "HMA-OSS launch skipped (policy: auto-refuse)"
        log_u "ACTION" "Config written; reboot or open HMA-OSS to apply"
      else
        log_u "ACTION" "Config written; open HMA-OSS or reboot to apply"
      fi

      if [ "$_do_launch" = "1" ]; then
        if [ "$(cfg_get toggle_hma_live_reload 1)" = "1" ]; then
          _hma_request_reload /data/local/tmp || _hma_open_ui || true
        else
          _hma_open_ui || true
        fi
      fi
      unset _hma_policy _do_launch
    else
      log_i "ACTION" "Auto-HMA is enabled, skipping HMA generation"
    fi
    unset _hma_config _hma_config_ok
  fi
  unset _force_target _force_hma

  _action_feature run_device_info "$MODDIR"
  _action_feature sh "$MODDIR/features/keybox_info.sh" --if-needed >/dev/null
  _action_feature sh "$MODDIR/features/keystore_info.sh" >/dev/null

  [ -f "$MODDIR/module.prop.bak" ] && cp "$MODDIR/module.prop.bak" "$MODDIR/module.prop"
  . "$MODDIR/lib/desc.sh"
  _action_feature refresh_module_description

  log_u "ACTION" ""
  if [ "$_action_code" -eq 0 ]; then
    log_i "ACTION" "Full integrity pipeline completed"
  else
    log_e "ACTION" "Integrity pipeline completed with errors; see $ACTION_LOG"
  fi
  printf '%s\n' "$_action_code" > "$_action_status"
} 2>&1 | tee -a "$ACTION_LOG"
_action_code=$(cat "$_action_status")
_action_summary="Full integrity pipeline completed"
[ "$_action_code" -eq 0 ] || _action_summary="Integrity pipeline completed with errors; see action.log"

if [ "$_first_boot" = "0" ]; then
  printf '{"script":"action.sh","output":"%s","time":"%s","code":%s}\n' "$_action_summary" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$_action_code" >> "$SPECTER_DIR/log/history.jsonl"
fi

echo "Action has ended, please exit"
exit "$_action_code"
