#!/system/bin/sh
set -e
MODDIR=${0%/*}

. "$MODDIR/lib/common.sh"
export ROOT_SOL

HOT_LOG="$SPECTER_DIR/log/hotinstall.log"
ensure_dir "$SPECTER_DIR/log" 2>/dev/null || true
log_rotate "$HOT_LOG" 2>/dev/null || true

# Parent reads this back; exit status across the streaming pipe isn't reliable.
rm -f "$SPECTER_DIR/.hotinstall_failed"

{
  log_i "HOT" "Hot-install live-apply starting"

  # Kill the boot-time scheduler + its inotifyd children (pre-update code).
  stop_specter_scheduler

  if [ "$(cfg_get toggle_scheduler 1)" != "0" ]; then
    sh "$MODDIR/lib/scheduler.sh" >"$SPECTER_DIR/log/scheduler.log" 2>&1 &
    log_i "HOT" "Scheduler relaunched (PID $!)"
  fi

  log_i "HOT" "Running action.sh"
  if sh "$MODDIR/action.sh"; then
    log_i "HOT" "action.sh completed"
  else
    _rc=$?
    log_e "HOT" "action.sh failed (exit $_rc)"
    : > "$SPECTER_DIR/.hotinstall_failed"
  fi

  log_i "HOT" "Hot-install live-apply done"
} 2>&1 | tee -a "$HOT_LOG"
