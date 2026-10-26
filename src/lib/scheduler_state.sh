# shellcheck shell=sh
# Validate persisted scheduler state before using it in shell arithmetic.
scheduler_interval() (
  _si_value=$1 _si_default=$2
  case "$_si_value" in ''|*[!0-9]*) _si_value=$_si_default ;; esac
  _si_value=$(printf '%s' "$_si_value" | sed 's/^0*//')
  _si_value=${_si_value:-0}
  if [ "${#_si_value}" -gt 10 ] || [ "$_si_value" -gt 2147483647 ]; then
    _si_value=$_si_default
  fi
  [ "$_si_value" -ge 10 ] || _si_value=10
  printf '%s\n' "$_si_value"
)

scheduler_last_run() (
  _sl_value=$1 _sl_now=$2
  case "$_sl_value" in ''|*[!0-9]*) _sl_value=0 ;; esac
  _sl_value=$(printf '%s' "$_sl_value" | sed 's/^0*//')
  _sl_value=${_sl_value:-0}
  if [ "${#_sl_value}" -gt 10 ] || [ "$_sl_value" -gt "$_sl_now" ]; then
    _sl_value=0
  fi
  printf '%s\n' "$_sl_value"
)
