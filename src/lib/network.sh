# shellcheck shell=sh
# Keep diagnostics on stderr: callers often capture stdout as JSON or a blob.
# A subshell also keeps concurrent/nested callers from sharing scratch variables.
download() (
    _dl_url="$1" _dl_output="${2:-}" _dl_sha256="${3:-}"
    PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/data/com.termux/files/usr/bin:$PATH"
    export SPECTER_LOG_FD=2
    umask 077
    _dl_tmp=$(mktemp "${_dl_output:-${TMPDIR:-/data/local/tmp}/.specter_dl}.XXXXXX") || return 1
    _dl_err="${_dl_tmp}.err"
    trap 'rm -f "$_dl_tmp" "$_dl_err"' EXIT
    _dl_code=1
    log_d "NET" "Downloading $_dl_url"

    for _dl_try in 1 2 3; do
        # curl validates TLS and rejects HTTP errors. Never accept an error page
        # just because its response body is non-empty.
        if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
            if curl --connect-timeout 10 --max-time 30 -fLsS -o "$_dl_tmp" -A "Specter/1.0" "$_dl_url" 2>"$_dl_err" && [ -s "$_dl_tmp" ]; then
                _dl_code=0
                break
            fi
        fi
        if busybox wget -T 10 -qO "$_dl_tmp" -U "Specter/1.0" "$_dl_url" 2>>"$_dl_err" && [ -s "$_dl_tmp" ]; then
            _dl_code=0
            break
        fi
        log_w "NET" "Download attempt $_dl_try failed: $(cat "$_dl_err")" >&2
        [ "$_dl_try" -eq 3 ] || sleep 1
    done

    if [ "$_dl_code" -ne 0 ]; then
        log_e "NET" "Download failed after 3 attempts: $_dl_url"
        return 1
    fi
    log_d "NET" "Downloaded ($(_dl_stat "$_dl_tmp")) bytes"
    if [ -n "$_dl_sha256" ]; then
        _dl_sum=$(sha256sum "$_dl_tmp" | cut -d' ' -f1)
        if [ "$_dl_sum" != "$_dl_sha256" ]; then
            log_e "NET" "SHA256 mismatch for $_dl_url"
            return 1
        fi
    fi
    if [ -n "$_dl_output" ]; then
        mv -f "$_dl_tmp" "$_dl_output"
    else
        cat "$_dl_tmp"
    fi
)

_dl_stat() { stat -c%s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo "?"; }

check_network() {
    _cn_oldpath="$PATH"
    PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/data/com.termux/files/usr/bin:$PATH"

    ping -c1 -W2 "1.1.1.1" >/dev/null 2>&1 && PATH="$_cn_oldpath" && unset _cn_oldpath && return 0

    if busybox wget -T 5 -qO /dev/null "https://clients3.google.com/generate_204" 2>/dev/null; then
        PATH="$_cn_oldpath"; unset _cn_oldpath; return 0
    fi
    if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
        curl --connect-timeout 5 -sI "https://clients3.google.com/generate_204" >/dev/null 2>&1 && PATH="$_cn_oldpath" && unset _cn_oldpath && return 0
    fi

    PATH="$_cn_oldpath"
    unset _cn_oldpath
    return 1
}
