# shellcheck shell=sh
# Alphabet variables are defined in decode.sh (sourced via common.sh)

decode_keybox_blob() {
  _dkb_in="$1" _dkb_out="$2"
  _dkb_tmp=$(mktemp "${TMPDIR:-/data/local/tmp}/_dkb.XXXXXX") || return 1
  decode_substitution "$_dkb_in" "$_dkb_tmp" 2>/dev/null || { rm -f "$_dkb_tmp"; return 1; }
  base64 -d < "$_dkb_tmp" > "$_dkb_out" 2>/dev/null || { rm -f "$_dkb_tmp"; return 1; }
  rm -f "$_dkb_tmp"
  unset _dkb_in _dkb_out _dkb_tmp
}

# A basic structural check shared by local XML, XML URLs and encoded blobs.
# Do not log key material when validation fails.
keybox_validate() {
  [ -s "$1" ] &&
    grep -Eq '<Key[[:space:]]+algorithm="(ecdsa|rsa)"' "$1" &&
    grep -Eq 'DeviceID[[:space:]]*=|<serial>' "$1" &&
    grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$1" &&
    grep -q -- '-----BEGIN CERTIFICATE-----' "$1"
}

# Metadata must be newer than the keybox AND recent in wall-clock time.
# Otherwise an installed keybox could be considered healthy indefinitely.
keybox_info_is_fresh() (
  [ -f "$1" ] && [ -f "$2" ] && [ "$1" -nt "$2" ] || return 1
  _kif_age=$(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
  [ "$_kif_age" -ge 0 ] && [ "$_kif_age" -lt "${KEYBOX_INFO_TTL:-3600}" ]
)

# Android mksh arithmetic is signed 32-bit. Mask the sign bit before modulo.
keybox_random_start() (
  _krs_hex=$(hexdump -n 4 -e '4/4 "%08X"' /dev/urandom 2>/dev/null) || _krs_hex=""
  case "$_krs_hex" in
    ""|*[!0-9a-fA-F]*) printf '%s\n' "$(( $$ % $1 ))" ;;
    *) printf '%s\n' "$(( (0x$_krs_hex & 0x7fffffff) % $1 ))" ;;
  esac
)

# shellcheck disable=SC3057,SC3052
_parse_serial() {
  _h="$1"
  case "${_h:0:1}" in "") return 1 ;; esac 2>/dev/null || { log_w "KEYBOX" "Shell lacks string slicing, skipping serial decode"; return 1; }
  case "$_h" in 30*) _h="${_h#30}" ;; *) return 1 ;; esac
  _l_hex="${_h:0:2}" _l_dec=$((16#$_l_hex))
  [ $_l_dec -ge 128 ] && _h="${_h:2 + ($_l_dec - 128) * 2}" || _h="${_h:2}"

  case "$_h" in 30*) _h="${_h#30}" ;; *) return 1 ;; esac
  _l_hex="${_h:0:2}" _l_dec=$((16#$_l_hex))
  [ $_l_dec -ge 128 ] && _h="${_h:2 + ($_l_dec - 128) * 2}" || _h="${_h:2}"

  case "$_h" in
    a0*)
      _ctx_len_hex="${_h:2:2}"
      _ctx_len=$((16#$_ctx_len_hex))
      _h="${_h:4 + _ctx_len * 2}"
      ;;
  esac

  case "$_h" in 02*) _h="${_h#02}" ;; *) return 1 ;; esac
  _l_hex="${_h:0:2}" _l_dec=$((16#$_l_hex))
  if [ $_l_dec -ge 128 ]; then
    _n=$((_l_dec - 128))
    _sl=$((16#${_h:2:_n * 2}))
    _serial_hex="${_h:2 + _n * 2:$_sl * 2}"
  else
    _serial_hex="${_h:2:$_l_dec * 2}"
  fi

  _serial=$(echo "$_serial_hex" | sed 's/^0*//')
  [ -z "$_serial" ] && _serial="0"
  return 0
}

decode_keybox_serial() {
  _b64=$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p; /-----END CERTIFICATE-----/q' "$1" | grep -v 'CERTIFICATE' | sed 's/^[[:space:]]*//' | tr -d '\n')
  [ -z "$_b64" ] && return 1
  _hex=$(echo "$_b64" | base64 -d 2>/dev/null | od -v -tx1 | awk 'BEGIN{ORS=""} {for(i=2;i<=NF;i++) printf "%s", $i}')
  [ -z "$_hex" ] && return 1
  _parse_serial "$_hex" || return 1
  echo "$_serial"
}

hex_to_dec() {
  # Certificate serials are wider than 64 bits, so keep the big-integer
  # conversion in awk instead of a per-digit shell loop with subshells.
  awk -v h="$1" '
    BEGIN {
      h = tolower(h)
      out = "0"
      for (i = 1; i <= length(h); i++) {
        d = index("0123456789abcdef", substr(h, i, 1)) - 1
        if (d < 0) { print ""; exit 1 }
        carry = d
        res = ""
        for (j = length(out); j >= 1; j--) {
          x = (substr(out, j, 1) + 0) * 16 + carry
          res = (x % 10) res
          carry = int(x / 10)
        }
        while (carry > 0) {
          res = (carry % 10) res
          carry = int(carry / 10)
        }
        out = res
      }
      print out
    }
  '
}

# Shared catalog fetch. keybox.sh and keybox_info.sh run back to back in the
# action pipeline; a short cache keeps them from downloading it twice.
keybox_catalog() {
  _kc_cache="$SPECTER_DIR/cache/keybox_catalog.json"
  _kc_ttl="${KEYBOX_CATALOG_TTL:-300}"
  if [ -s "$_kc_cache" ]; then
    _kc_age=$(( $(date +%s) - $(stat -c %Y "$_kc_cache" 2>/dev/null || echo 0) ))
    if [ "$_kc_age" -ge 0 ] && [ "$_kc_age" -lt "$_kc_ttl" ]; then
      cat "$_kc_cache"
      unset _kc_cache _kc_ttl _kc_age
      return 0
    fi
  fi
  _kc_json=$(download "$CATALOG_URL") || _kc_json=""
  if printf '%s' "$_kc_json" | grep -q '"entries":[[:space:]]*\['; then
    ensure_dir "$SPECTER_DIR/cache"
    printf '%s' "$_kc_json" > "$_kc_cache" 2>/dev/null || true
    printf '%s' "$_kc_json"
    unset _kc_cache _kc_ttl _kc_age _kc_json
    return 0
  fi
  unset _kc_cache _kc_ttl _kc_age _kc_json
  return 1
}

check_google_revocation() {
  _gr_serial=$1
  _gr_cache="$SPECTER_DIR/cache/google_revocation.json"
  _gr_ttl="${GOOGLE_REVOCATION_TTL:-3600}"
  _gr_file=""
  if [ -s "$_gr_cache" ]; then
    _gr_age=$(( $(date +%s) - $(stat -c %Y "$_gr_cache" 2>/dev/null || echo 0) ))
    if [ "$_gr_age" -ge 0 ] && [ "$_gr_age" -lt "$_gr_ttl" ]; then
      _gr_file="$_gr_cache"
    fi
  fi
  if [ -z "$_gr_file" ]; then
    ensure_dir "$SPECTER_DIR/cache"
    _gr_tmp=$(mktemp "${_gr_cache}.XXXXXX") || return 2
    # CRLs exceed Android MAX_ARG_STRLEN. Stream to disk instead of expanding
    # the entire JSON into printf/grep arguments or environment variables.
    if download "$GOOGLE_REVOCATION_URL" > "$_gr_tmp" && grep -q '"entries":[[:space:]]*{' "$_gr_tmp"; then
      mv -f "$_gr_tmp" "$_gr_cache" || { rm -f "$_gr_tmp"; return 2; }
      _gr_file="$_gr_cache"
    else
      rm -f "$_gr_tmp"
    fi
  fi
  if [ -z "$_gr_file" ] || ! grep -q '"entries":[[:space:]]*{' "$_gr_file"; then
    unset _gr_serial _gr_cache _gr_ttl _gr_file _gr_tmp _gr_age
    return 2
  fi
  _gr_dec=$(hex_to_dec "$_gr_serial") || return 2
  _gr_rc=1
  grep -Fq "\"$_gr_dec\"" "$_gr_file" && _gr_rc=0
  unset _gr_serial _gr_cache _gr_ttl _gr_file _gr_tmp _gr_age _gr_dec
  return $_gr_rc
}

find_kmInstallKeybox() {
  _fk_abi=$(getprop ro.product.cpu.abi 2>/dev/null || echo "arm64")
  _fk_lib_dir="/vendor/lib64"
  [ "$_fk_abi" != "arm64" ] && [ "$_fk_abi" != "x86_64" ] && _fk_lib_dir="/vendor/lib"
  _fk_bin=""
  for _fk_dir in "$_fk_lib_dir/hw" "$_fk_lib_dir" "/vendor/bin"; do
    _fk_bin=$(find "$_fk_dir" -iname "*kmInstallKeybox*" 2>/dev/null | head -1)
    [ -n "$_fk_bin" ] && break
  done
  echo "${_fk_bin:-}"
  unset _fk_abi _fk_lib_dir _fk_bin _fk_dir
}

# Emit entries as compact objects. Track strings/escapes rather than stopping
# at a ']' or '}' that happens to occur inside a provider name or display text.
keybox_entries() {
  awk '
    { json = json $0 "\n" }
    END {
      if (!match(json, /"entries"[[:space:]]*:[[:space:]]*\[/)) exit
      json = substr(json, RSTART + RLENGTH)
      quoted = escaped = depth = 0
      obj = ""
      for (i = 1; i <= length(json); i++) {
        c = substr(json, i, 1)
        if (quoted) {
          if (depth) obj = obj c
          if (escaped) escaped = 0
          else if (c == "\\") escaped = 1
          else if (c == "\"") quoted = 0
          continue
        }
        if (c == "\"") quoted = 1
        if (c == "]" && !depth) break
        if (c == "{") depth++
        if (depth && c !~ /[[:space:]]/) obj = obj c
        if (c == "}") {
          depth--
          if (!depth) { print obj; obj = "" }
        }
      }
    }
  '
}

# True if catalog entry for SOURCE/VERSION is softbanned.
keybox_is_softbanned() {
  printf '%s' "$1" | keybox_entries | grep -F '"source":"'"$2"'"' | grep -F '"version":"'"$3"'"' | head -1 | grep -q '"softbanned":true'
}

# Prefer active (non-softbanned) candidates. stdin: one JSON object per line
# with source/version. $1 = full catalog JSON. stdout: preferred pool.
keybox_prefer_active() {
  _kpa_hist=$(printf '%s' "$1" | keybox_entries)
  KEYBOX_CATALOG="$_kpa_hist" awk '
    function field(obj, key,   r) {
      if (!match(obj, "\"" key "\":\"[^\"]*\"")) return ""
      r = substr(obj, RSTART, RLENGTH)
      sub("^\"" key "\":\"", "", r)
      sub("\"$", "", r)
      return r
    }
    BEGIN {
      hist = ENVIRON["KEYBOX_CATALOG"]
      n = split(hist, objects, "\n")
      for (k = 1; k <= n; k++) {
        obj = objects[k]
        src = field(obj, "source")
        ver = field(obj, "version")
        if (src != "" && ver != "") {
          soft[src SUBSEP ver] = (obj ~ /"softbanned":true/) ? 1 : 0
        }
      }
    }
    {
      src = field($0, "source")
      ver = field($0, "version")
      if (((src SUBSEP ver) in soft) && soft[src, ver]) {
        softout = softout $0 "\n"
      } else {
        activeout = activeout $0 "\n"
      }
    }
    END {
      if (activeout != "") printf "%s", activeout
      else printf "%s", softout
    }
  '
  unset _kpa_hist
}

# Latest version for PROVIDER from catalog, preferring non-softbanned and non-revoked.
keybox_latest_for_provider() {
  _klp_hist="$1"
  _klp_prov="$2"
  _klp_entries=$(printf '%s' "$_klp_hist" | keybox_entries | grep -F '"source":"'"$_klp_prov"'"' | grep -v '"revoked":true')
  _klp_ver=$(printf '%s\n' "$_klp_entries" | grep -v '"softbanned":true' | sed 's/.*"version":"\([^"]*\)".*/\1/' | sort -rV | head -1)
  [ -z "$_klp_ver" ] && _klp_ver=$(printf '%s\n' "$_klp_entries" | grep '"softbanned":true' | sed 's/.*"version":"\([^"]*\)".*/\1/' | sort -rV | head -1)
  echo "$_klp_ver"
  unset _klp_hist _klp_prov _klp_entries _klp_ver
}
