#!/usr/bin/env bash
# scripts/lib/dp-preflight-common.sh — shared helpers for dp-upgrade-preflight
# Compatible with Bash 4.3+ / Ubuntu 16.04. Safe to source.
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Filename / JSON helpers (aligned with collect-dp-upgrade-readiness.sh)
# ---------------------------------------------------------------------------

pf_sanitize_filename() {
  local s="${1:-}"
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_' )"
  s="$(printf '%s' "$s" | sed 's/__*/_/g; s/^_//; s/_$//')"
  if [[ -z "$s" ]]; then
    s="unknown"
  fi
  printf '%s' "$s"
}

pf_json_escape() {
  local s="${1-}"
  local out="" i c hex
  local -i len=${#s}
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      $'\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        # shellcheck disable=SC2053
        if [[ "$c" < $'\x20' || "$c" > $'\x7e' ]]; then
          printf -v hex '%02X' "'$c"
          out+="\\u00${hex}"
        else
          out+="$c"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

pf_json_str_or_null() {
  local v="${1-}"
  if [[ -z "$v" || "$v" == "null" ]]; then
    printf 'null'
  else
    printf '"%s"' "$(pf_json_escape "$v")"
  fi
}

pf_json_bool() {
  case "${1:-}" in
    true|1|yes) printf 'true' ;;
    false|0|no) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

pf_json_num_or_null() {
  local v="${1-}"
  if [[ -z "$v" || "$v" == "null" ]]; then
    printf 'null'
  elif [[ "$v" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    printf 'null'
  fi
}

pf_shell_safe() {
  # Quote for shell-safe display (single-quoted, escape embedded quotes).
  local s="${1-}"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# ---------------------------------------------------------------------------
# Version normalize / compare (semantic major.minor.patch base)
# ---------------------------------------------------------------------------

# Normalize DP version strings:
#   6.5.0ubuntu1 -> 6.5.0
#   6.5.0-12     -> 6.5.0
#   6.4.0+build  -> 6.4.0
#   6.5.0.7942   -> 6.5.0  (keep first 3 numeric components)
pf_normalize_version() {
  local raw="${1-}"
  local base
  if [[ -z "$raw" || "$raw" == "null" || "$raw" == "unknown" ]]; then
    printf ''
    return 1
  fi
  # Strip leading non-digit noise
  raw="$(printf '%s' "$raw" | sed -E 's/^[^0-9]*//')"
  # Take leading X.Y.Z or X.Y
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    base="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+\.[0-9]+) ]]; then
    base="${BASH_REMATCH[1]}.0"
  else
    printf ''
    return 1
  fi
  printf '%s' "$base"
  return 0
}

# Compare two normalized versions. Prints: lt | eq | gt | unknown
pf_compare_versions() {
  local a="${1-}" b="${2-}"
  local a1 a2 a3 b1 b2 b3
  if [[ -z "$a" || -z "$b" ]]; then
    printf 'unknown'
    return 1
  fi
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  if ! [[ "$a1" =~ ^[0-9]+$ && "$a2" =~ ^[0-9]+$ && "$a3" =~ ^[0-9]+$ && \
          "$b1" =~ ^[0-9]+$ && "$b2" =~ ^[0-9]+$ && "$b3" =~ ^[0-9]+$ ]]; then
    printf 'unknown'
    return 1
  fi
  if (( a1 < b1 )); then printf 'lt'; return 0; fi
  if (( a1 > b1 )); then printf 'gt'; return 0; fi
  if (( a2 < b2 )); then printf 'lt'; return 0; fi
  if (( a2 > b2 )); then printf 'gt'; return 0; fi
  if (( a3 < b3 )); then printf 'lt'; return 0; fi
  if (( a3 > b3 )); then printf 'gt'; return 0; fi
  printf 'eq'
  return 0
}

# Canonicalize DP role from collector values.
# Collector emits: AIO, DL, DA, worker, master (mixed case)
# Canonical: AIO, DL_MASTER, DA_MASTER, MASTER, WORKER, UNKNOWN
pf_canonical_role() {
  local r="${1-}"
  case "$r" in
    AIO|aio) printf 'AIO' ;;
    DL|dl|DL_MASTER|dl_master) printf 'DL_MASTER' ;;
    DA|da|DA_MASTER|da_master) printf 'DA_MASTER' ;;
    master|MASTER|Master) printf 'MASTER' ;;
    worker|WORKER|Worker) printf 'WORKER' ;;
    null|""|unknown|UNKNOWN) printf 'UNKNOWN' ;;
    *) printf 'UNKNOWN' ;;
  esac
}

# ---------------------------------------------------------------------------
# Safe policy KEY=VALUE parser (never source the file)
# ---------------------------------------------------------------------------

# Usage: pf_parse_policy FILE PREFIX
# Sets PREFIX_KEY variables for allowed keys only.
pf_parse_policy() {
  local file="$1"
  local prefix="${2:-POLICY}"
  local line key value
  local allowed_re='^[A-Z][A-Z0-9_]*$'
  local value_re='^[A-Za-z0-9_./:,%+-]+$'
  local unknown_keys=()

  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf 'policy file not readable: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip CR, comments, blank
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Must be KEY=VALUE with no command substitution / backticks / $()
    if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *'$('* ]]; then
      printf 'policy rejects shell expansion: %s\n' "$line" >&2
      return 1
    fi
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      printf 'policy invalid line: %s\n' "$line" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Trim whitespace around value
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ ! "$key" =~ $allowed_re ]]; then
      printf 'policy invalid key: %s\n' "$key" >&2
      return 1
    fi
    # Reject dangerous characters that could escape when later expanded poorly
    case "$value" in
      *$'\n'*)
        printf 'policy rejects multiline value for %s\n' "$key" >&2
        return 1
        ;;
    esac
    if [[ "$value" =~ [\;\|\&\<\>\`\$\(\)\{\}] ]]; then
      printf 'policy rejects unsafe characters in %s\n' "$key" >&2
      return 1
    fi
    # Assign via printf -v (no eval)
    printf -v "${prefix}_${key}" '%s' "$value"
  done <"$file"
  return 0
}

# ---------------------------------------------------------------------------
# Collector summary.json field extractor with parser fallback chain
# ---------------------------------------------------------------------------

PF_JSON_PARSER=""  # jq|python3|python|ruby|perl|internal

pf_detect_json_parser() {
  if command -v jq >/dev/null 2>&1; then
    PF_JSON_PARSER=jq
  elif command -v python3 >/dev/null 2>&1; then
    PF_JSON_PARSER=python3
  elif command -v python >/dev/null 2>&1; then
    PF_JSON_PARSER=python
  elif command -v ruby >/dev/null 2>&1; then
    PF_JSON_PARSER=ruby
  elif command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1; then
    PF_JSON_PARSER=perl
  else
    PF_JSON_PARSER=internal
  fi
  printf '%s' "$PF_JSON_PARSER"
}

# Extract a dotted path from collector summary.json (schema 1.0).
# Paths like: os.version_id, dp.version, shells.aella, storage.root_available_bytes
# Arrays: dp.worker_ips -> comma-separated or JSON array string
# Returns empty string for null/missing; prints literal null as empty.
pf_json_get() {
  local file="$1"
  local path="$2"
  local parser="${PF_JSON_PARSER:-}"
  local result=""

  if [[ -z "$parser" ]]; then
    pf_detect_json_parser >/dev/null
    parser="$PF_JSON_PARSER"
  fi

  case "$parser" in
    jq)
      result="$(jq -r --arg p "$path" '
        def dig($path):
          if ($path|length)==0 then .
          else
            ($path|split(".")[0]) as $k |
            ($path|split(".")[1:]|join(".")) as $rest |
            if .==null then null
            elif type=="object" then (.[$k] | dig($rest))
            else null end
          end;
        dig($p) | if .==null then "" elif type=="array" then join(",") elif type=="boolean" or type=="number" then tostring else .
        end
      ' "$file" 2>/dev/null)" || result=""
      ;;
    python3|python)
      result="$("$parser" - "$file" "$path" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[2].split(".")
with open(sys.argv[1]) as f:
    data = json.load(f)
cur = data
for p in path:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        print("")
        sys.exit(0)
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, list):
    print(",".join(str(x) for x in cur))
else:
    print(cur)
PY
)"
      ;;
    ruby)
      result="$(ruby -rjson -e '
path=ARGV[1].split(".")
data=JSON.parse(File.read(ARGV[0]))
cur=data
path.each{|p| cur = (cur.is_a?(Hash) && cur.key?(p)) ? cur[p] : nil }
if cur.nil?; print ""
elsif cur==true; print "true"
elsif cur==false; print "false"
elsif cur.is_a?(Array); print cur.join(",")
else print cur.to_s
end
' "$file" "$path" 2>/dev/null)" || result=""
      ;;
    perl)
      result="$(perl -MJSON::PP -e '
use strict; use warnings;
my ($file,$path)=@ARGV;
open my $fh,"<",$file or exit 1;
local $/; my $data=decode_json(<$fh>);
my $cur=$data;
for my $p (split /\./,$path) {
  if (ref($cur) eq "HASH" && exists $cur->{$p}) { $cur=$cur->{$p}; }
  else { print ""; exit 0; }
}
if (!defined $cur) { print ""; }
elsif (JSON::PP::is_bool($cur)) { print $cur ? "true" : "false"; }
elsif (ref($cur) eq "ARRAY") { print join(",", @$cur); }
else { print $cur; }
' "$file" "$path" 2>/dev/null)" || result=""
      ;;
    internal)
      result="$(pf_json_get_internal "$file" "$path")"
      ;;
    *)
      result=""
      ;;
  esac
  printf '%s' "$result"
}

# Controlled-schema internal fallback for collector summary.json 1.0.
# Supports only known leaf paths used by preflight. Not a general JSON parser.
pf_json_get_internal() {
  local file="$1"
  local path="$2"
  local content key pattern

  content="$(tr -d '\r' <"$file" 2>/dev/null)" || { printf ''; return 1; }

  # Validate minimal structure
  if ! grep -q '"schema_version"' <<<"$content"; then
    printf ''
    return 1
  fi

  _pf_extract_string() {
    # Extract "key": "value" or "key": null from a block of JSON text
    local blob="$1" k="$2"
    local line
    line="$(grep -m1 -E "\"${k}\"[[:space:]]*:" <<<"$blob")"
    if [[ -z "$line" ]]; then printf ''; return; fi
    if grep -qE ':[[:space:]]*null' <<<"$line"; then printf ''; return; fi
    if grep -qE ':[[:space:]]*true' <<<"$line"; then printf 'true'; return; fi
    if grep -qE ':[[:space:]]*false' <<<"$line"; then printf 'false'; return; fi
    if grep -qE ':[[:space:]]*-?[0-9]+' <<<"$line"; then
      printf '%s' "$line" | sed -E 's/.*:[[:space:]]*(-?[0-9]+).*/\1/'
      return
    fi
    # string value
    printf '%s' "$line" | sed -E 's/.*"'"${k}"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
  }

  _pf_section() {
    local blob="$1" name="$2"
    # Extract {...} block for "name": { ... } (non-greedy via brace count simplified)
    awk -v n="$name" '
      BEGIN { inb=0; depth=0; buf="" }
      $0 ~ "\"" n "\"[[:space:]]*:[[:space:]]*\\{" {
        inb=1; depth=1
        sub(/^[^\{]*\{/, "{")
        buf=$0
        # count braces on this line
        t=$0
        gsub(/[^{]/,"",t); depth=length(t)
        u=$0; gsub(/[^}]/,"",u); depth-=length(u)
        if (depth<=0) { print buf; exit }
        next
      }
      inb {
        buf=buf "\n" $0
        t=$0; gsub(/[^{]/,"",t); depth+=length(t)
        u=$0; gsub(/[^}]/,"",u); depth-=length(u)
        if (depth<=0) { print buf; exit }
      }
    ' <<<"$blob"
  }

  case "$path" in
    schema_version|script_version|collection_id|hostname|fqdn|started_at_utc|completed_at_utc)
      _pf_extract_string "$content" "${path}"
      ;;
    duration_seconds|effective_user_id)
      _pf_extract_string "$content" "${path}"
      ;;
    os.id|os.version_id|os.codename|os.kernel|os.architecture)
      key="${path#os.}"
      _pf_extract_string "$(_pf_section "$content" os)" "$key"
      ;;
    dp.version|dp.version_status|dp.role)
      key="${path#dp.}"
      _pf_extract_string "$(_pf_section "$content" dp)" "$key"
      ;;
    dp.cluster_detected)
      _pf_extract_string "$(_pf_section "$content" dp)" "cluster_detected"
      ;;
    dp.worker_ips)
      # Extract array contents between [ ]
      local sec
      sec="$(_pf_section "$content" dp)"
      printf '%s' "$sec" | sed -n 's/.*"worker_ips"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | \
        tr -d '"' | tr -d ' ' | tr ',' '\n' | paste -sd, - 2>/dev/null || printf ''
      ;;
    shells.root|shells.aella)
      key="${path#shells.}"
      _pf_extract_string "$(_pf_section "$content" shells)" "$key"
      ;;
    storage.root_available_bytes|storage.boot_available_bytes|storage.aelladata_available_bytes)
      key="${path#storage.}"
      _pf_extract_string "$(_pf_section "$content" storage)" "$key"
      ;;
    storage.aelladata_mounted)
      _pf_extract_string "$(_pf_section "$content" storage)" "aelladata_mounted"
      ;;
    time.utc_now|time.ntp_synchronized|time.source)
      key="${path#time.}"
      _pf_extract_string "$(_pf_section "$content" time)" "$key"
      ;;
    apt.dpkg_audit_clean|apt.held_package_count|apt.source_uri_count)
      key="${path#apt.}"
      _pf_extract_string "$(_pf_section "$content" apt)" "$key"
      ;;
    upgrade.existing_state_detected|upgrade.state|upgrade.hop_history_detected)
      key="${path#upgrade.}"
      _pf_extract_string "$(_pf_section "$content" upgrade)" "$key"
      ;;
    bringup.aelladeb_py3_exists|bringup.aelladeb_py3_file_count|bringup.aelladeb_exists|bringup.aelladeb_file_count)
      key="${path#bringup.}"
      _pf_extract_string "$(_pf_section "$content" bringup)" "$key"
      ;;
    collection.status|collection.successful_checks|collection.failed_checks|collection.skipped_checks)
      key="${path#collection.}"
      _pf_extract_string "$(_pf_section "$content" collection)" "$key"
      ;;
    *)
      printf ''
      return 1
      ;;
  esac
}

# Validate that a file is parseable JSON (using detected parser or python/jq).
pf_json_validate_file() {
  local file="$1"
  local parser
  parser="$(pf_detect_json_parser)"
  case "$parser" in
    jq) jq -e . "$file" >/dev/null 2>&1 ;;
    python3|python) "$parser" -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>/dev/null ;;
    ruby) ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$file" 2>/dev/null ;;
    perl) perl -MJSON::PP -e 'local $/; open F,"<",$ARGV[0]; decode_json(<F>);' "$file" 2>/dev/null ;;
    internal)
      # Minimal structural checks for collector summary
      grep -q '"schema_version"' "$file" && grep -q '"os"' "$file" && grep -q '"collection"' "$file"
      ;;
    *) return 1 ;;
  esac
}
