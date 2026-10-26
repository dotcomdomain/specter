#!/system/bin/sh
set -e
MODDIR=${0%/*}
. "$MODDIR/../lib/common.sh"
. "$MODDIR/../lib/constants.sh"

log_i "KEYBOX_INFO" "Starting keybox info check"

detect_keystore_manager
KEYBOX_FILE="$KSM_KEYBOX"
INFO_PATH="${SPECTER_KEYBOX_INFO:-$MODDIR/../webroot/json/keybox_info.json}"

# --if-needed is used by the action button: reuse fresh info for the keybox
# that is already installed instead of re-parsing the catalog and revocation.
if [ "${1:-}" = "--if-needed" ] &&
   keybox_info_is_fresh "$INFO_PATH" "$KEYBOX_FILE" &&
   grep -q '"installed": true' "$INFO_PATH" &&
   grep -q '"revocation_checked": true' "$INFO_PATH"; then
  log_i "KEYBOX_INFO" "Keybox info is current, skipping refresh"
  exit 0
fi

ensure_dir "$(dirname "$INFO_PATH")"

_installed=false
_source=""
_source_version=""
_text=""
_up_to_date=false
_revoked=false
_revocation_checked=false
_softbanned=false
_serial=""
_is_private_val="false"

if [ -f "$KEYBOX_FILE" ]; then
  _installed=true

  _is_private_val=$(cat "$CONFIG_DIR/val/keybox_private.val" 2>/dev/null || echo "false")
  [ -z "$_is_private_val" ] && _is_private_val="false"
  if [ "$_is_private_val" = "true" ]; then
    _source="Private"
    _text="Keybox"
    _up_to_date=true
    log_d "KEYBOX_INFO" "Private keybox flagged by user"
    if _serial=$(decode_keybox_serial "$KEYBOX_FILE"); then
      if check_google_revocation "$_serial"; then
        _revoked=true
        _revocation_checked=true
        log_w "KEYBOX_INFO" "Revoked by Google"
      else
        [ "$?" -ne 1 ] || _revocation_checked=true
      fi
    fi
  elif _serial=$(decode_keybox_serial "$KEYBOX_FILE"); then
    log_d "KEYBOX_INFO" "Serial: $_serial"

    _serial_dec=$(hex_to_dec "$_serial" 2>/dev/null || echo "")

    if check_google_revocation "$_serial"; then
      _revoked=true
      _revocation_checked=true
      log_w "KEYBOX_INFO" "Revoked by Google"
    else
      [ "$?" -ne 1 ] || _revocation_checked=true
    fi

    if [ "$KSM" = "omk" ] && cmp -s "$OMK_MODULE/keybox.xml" "$KEYBOX_FILE"; then
      _source="OhMyKeymint"
      _text="Default keybox"
    else
      _history_json=$(keybox_catalog 2>/dev/null || true)
      if [ -n "$_history_json" ]; then
        log_d "KEYBOX_INFO" "Catalog response length: ${#_history_json}"
        _provider=$(cat "$CONFIG_DIR/val/keybox_provider.val" 2>/dev/null || echo "auto")
        if [ "$_provider" = "auto" ]; then
          _provider=$(echo "$_history_json" | grep -o '"working":{[^}]*"source":"[^"]*"' | sed 's/.*"source":"\([^"]*\)".*/\1/' || true)
        fi

        for _s in "$_serial" "$_serial_dec"; do
          [ -z "$_s" ] && continue
          if [ -n "$_provider" ]; then
            _entry=$(echo "$_history_json" | grep -o '{[^}]*"source":"'"$_provider"'"[^}]*"serial":"'"$_s"'"[^}]*}' || true)
          fi
          if [ -z "$_entry" ]; then
            _entry=$(echo "$_history_json" | grep -o '{[^}]*"serial":"'"$_s"'"[^}]*}' || true)
          fi
          [ -n "$_entry" ] && break
        done
        unset _s

        if [ -n "$_entry" ]; then
          _source=$(echo "$_entry" | grep -o '"source":"[^"]*"' | head -1 | sed 's/"source":"//;s/"//' || true)
          _source_version=$(echo "$_entry" | grep -o '"version":"[^"]*"' | head -1 | sed 's/"version":"//;s/"//' || true)
          _text=$(echo "$_entry" | grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"//' || true)
          [ -z "$_source" ] && _source="unknown"
          [ -z "$_source_version" ] && _source_version="?"
          [ -z "$_text" ] && _text="$_source_version"

          # A revoked catalog entry remains revoked even if the CRL is
          # unavailable or uses a serial representation we cannot match.
          if echo "$_entry" | grep -q '"revoked":true'; then
            _revoked=true
          fi
          _softbanned=false
          echo "$_entry" | grep -q '"softbanned":true' 2>/dev/null && _softbanned=true || true

          _latest_for_source=$(echo "$_history_json" | grep -o '"'"$_source"'":"[^"]*"' | sed 's/.*":"//;s/"//' || true)
          if [ -n "$_source_version" ] && [ "$_source_version" = "$_latest_for_source" ]; then
            _up_to_date=true
          fi
        else
          log_d "KEYBOX_INFO" "Not found in catalog"
        fi
      else
        log_w "KEYBOX_INFO" "Catalog unavailable"
      fi
    fi
  fi
fi

# Do not turn a previously revoked certificate green when its CRL is offline.
if [ "$_revocation_checked" != "true" ] && [ -n "$_serial" ] &&
   grep -Fq '"serial": "'"$_serial"'"' "$INFO_PATH" 2>/dev/null &&
   grep -q '"revoked": true' "$INFO_PATH"; then
  _revoked=true
fi

_info_tmp=$(mktemp "${INFO_PATH}.XXXXXX")
trap 'rm -f "$_info_tmp"' EXIT
cat <<EOF > "$_info_tmp"
{
  "installed": $_installed,
  "source": "$(_escape_json "$_source")",
  "source_version": "$(_escape_json "$_source_version")",
  "text": "$(_escape_json "$_text")",
  "up_to_date": $_up_to_date,
  "revoked": $_revoked,
  "revocation_checked": $_revocation_checked,
  "softbanned": $_softbanned,
  "serial": "$(_escape_json "$_serial")",
  "is_private": $_is_private_val
}
EOF
mv -f "$_info_tmp" "$INFO_PATH"

if [ "$_installed" = "true" ]; then
  if [ "$_revoked" = "true" ]; then
    log_w "KEYBOX_INFO" "Keybox is revoked by Google"
  elif [ "$_up_to_date" = "true" ]; then
    log_i "KEYBOX_INFO" "Keybox from $_source is valid and up to date"
  elif [ -n "$_source" ]; then
    log_i "KEYBOX_INFO" "Keybox from $_source: version $_source_version"
  else
    log_i "KEYBOX_INFO" "Keybox is installed"
  fi
fi
unset _installed _source _source_version _text _up_to_date _revoked _revocation_checked _softbanned _serial _serial_dec _history_json _entry _provider _latest_for_source _is_private_val
log_i "KEYBOX_INFO" "Keybox info check complete"
exit 0
