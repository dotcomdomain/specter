# shellcheck shell=sh

_log_emit() { printf '%s\n' "$1" >&"${SPECTER_LOG_FD:-1}"; }

log_d() { [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ] || return 0; _log_emit "$(printf '[%s] [D] [%s] %s' "$(date '+%T')" "$1" "$2")"; }

log_u() { [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ] && return 0 || _log_emit "$2"; }

log_i() {
  if [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ]; then
    _log_emit "$(printf '[%s] [I] [%s] %s' "$(date '+%T')" "$1" "$2")"
  else
    _log_emit "$2"
  fi
}

log_w() {
  if [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ]; then
    _log_emit "$(printf '[%s] [W] [%s] %s' "$(date '+%T')" "$1" "$2")"
  else
    _log_emit "Warning: $2"
  fi
}

log_e() {
  if [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ]; then
    printf '[%s] [E] [%s] %s\n' "$(date '+%T')" "$1" "$2" >&2
  else
    echo "Error: $2" >&2
  fi
}

log() { [ $# -eq 2 ] && log_i "$1" "$2"; }

die() {
  if [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ]; then
    log_e "FATAL" "$1"; printf '[%s] [F] [FATAL] %s\n' "$(date '+%T')" "$1" >&2
  else
    echo "Fatal: $1" >&2
  fi
  exit 1
}

log_rotate() {
  _lr_path="$1" _lr_max="${2:-262144}" _lr_keep="${3:-3}"
  [ -f "$_lr_path" ] || return 0
  _lr_size=$(stat -c%s "$_lr_path" 2>/dev/null || echo "0")
  [ "$_lr_size" -lt "$_lr_max" ] 2>/dev/null && return 0
  if [ "${SPECTER_LOG_LEVEL:-info}" = "debug" ]; then
    _lr_i=$_lr_keep
    while [ "$_lr_i" -gt 1 ]; do
      [ ! -f "${_lr_path}.$((_lr_i - 1)).gz" ] || mv -f "${_lr_path}.$((_lr_i - 1)).gz" "${_lr_path}.$_lr_i.gz"
      [ ! -f "${_lr_path}.$((_lr_i - 1))" ] || mv -f "${_lr_path}.$((_lr_i - 1))" "${_lr_path}.$_lr_i"
      _lr_i=$((_lr_i - 1))
    done
    if command -v gzip >/dev/null 2>&1; then
      gzip -c "$_lr_path" > "${_lr_path}.1.gz" || return 1
    else
      cp "$_lr_path" "${_lr_path}.1" || return 1
    fi
  fi
  : > "$_lr_path"
}
