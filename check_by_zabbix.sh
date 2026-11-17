#!/bin/bash
# check_by_zabbix.sh
# Icinga/Nagios plugin: fetch trigger/problem status from Zabbix via JSON-RPC API
# with exclude/include patterns — equivalent to check_by_checkmk for Zabbix
#
# Compatible with Zabbix 5.x, 6.x, and 7.x+
#   Zabbix 7.x+:  Authorization: Bearer <token> header
#   Zabbix <7:    "auth": "<token>" field in JSON body
#
# Dependencies: curl, jq
#
# Author:
#   Felix Longardt <monitoring@longardt.com>
#
# Version history:
# 1.0.0  2026-11-14  Initial release
# 1.0.1  2026-11-15  Add --skip-unsupported to suppress state=1 (item not supported / not enough data) triggers
# 1.0.2  2026-11-15  Use problem.get as source of truth for active problems; rename -s to -H

set -o nounset
set -o pipefail

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

# Zabbix trigger severity levels
readonly SEV_NOT_CLASSIFIED=0
readonly SEV_INFORMATION=1
readonly SEV_WARNING=2
readonly SEV_AVERAGE=3
readonly SEV_HIGH=4
readonly SEV_DISASTER=5

sev_name() {
  case "$1" in
    0) echo "not_classified" ;; 1) echo "information" ;; 2) echo "warning" ;;
    3) echo "average" ;; 4) echo "high" ;; 5) echo "disaster" ;; *) echo "unknown" ;;
  esac
}

sev_num() {
  case "${1,,}" in
    not_classified|not-classified|0) echo 0 ;; information|info|1) echo 1 ;;
    warning|warn|2) echo 2 ;; average|avg|3) echo 3 ;; high|4) echo 4 ;;
    disaster|5) echo 5 ;; *) echo "-1" ;;
  esac
}

usage() {
  cat <<EOF
Usage: $0 -h <hostname> -H <server-url> [options]

Fetches all Zabbix triggers (services) for a host and reports the worst
severity as an Icinga/Nagios-compatible exit code and status line.

Options:
  -h, --host            Hostname to check (Zabbix host name or display name)
  -H, --server-url      Zabbix base URL (e.g. http://zabbix.example.com)
  -u, --user            Zabbix username (triggers session-based login)
  -p, --password        Zabbix password (use with --user)
  -a, --api-token       Zabbix API token (persistent token from Zabbix UI,
                        bypasses session login; preferred for Zabbix 5.4+)
      --api-path        Path to JSON-RPC endpoint
                        (default: /zabbix/api_jsonrpc.php)
  -V, --verify-tls      Verify TLS certificates (default: false)
  -v, --verbose         Show individual trigger status lines
  -D, --debug           Show detailed debug information (stderr)
  -d, --detail          Show trigger comments in verbose output
  -P, --perfdata        Include extended per-trigger performance data
  -O, --perfdata-only   Show only performance data (no status message)
  -e, --exclude         Exclude triggers by name (comma-separated patterns)
  -E, --exclude-output  Exclude triggers by description/comments (comma-sep)
  -i, --include         Include ONLY triggers matching name patterns
  -I, --include-output  Include ONLY triggers matching description patterns
  -j, --include-perfdata  Include ONLY these triggers in perfdata
  -g, --exclude-perfdata  Exclude these triggers from perfdata
      --warn-severity   Minimum Zabbix severity for WARNING
                        (default: 2 = warning; 0=not_classified..5=disaster)
      --crit-severity   Minimum Zabbix severity for CRITICAL
                        (default: 3 = average)
      --skip-dependent  Skip dependent triggers (Zabbix-side filter)
      --skip-acknowledged  Skip triggers with an acknowledged active problem
      --skip-suppressed    Skip triggers in active maintenance/suppression
      --skip-unsupported   Skip triggers with state=1 (expression cannot be evaluated:
                           item not supported by Zabbix agent/module, or not enough
                           data yet); useful for features not enabled on this instance

Patterns can be:
  exact names:     "High CPU usage"
  wildcards:       "CPU*"
  regex (slashes): "/^Filesystem \\/.*/"

Severity names for --warn-severity / --crit-severity:
  not_classified (0)  information (1)  warning (2)
  average (3)         high (4)         disaster (5)

Active problem detection:
  Uses problem.get (matches Zabbix Problems view) rather than trigger.value.
  This correctly catches problems that require manual close (trigger expression
  may be false while the problem event is still open in Zabbix).

  trigger state=1  -> UNKNOWN (expression cannot be evaluated, item unsupported)
                     (use --skip-unsupported to suppress these)
  active problem, severity < warn_severity  -> OK (below alert threshold)
  active problem, severity >= warn_severity -> WARNING
  active problem, severity >= crit_severity -> CRITICAL
  no active problem, state=0               -> OK

Examples:
  $0 -h "Zabbix server" -H http://zabbix.example.com -u Admin -p zabbix
  $0 -h myhost -H http://zabbix.example.com -a my_api_token -v -d
  $0 -h myhost -H http://zabbix.example.com -u user -p pass -i "CPU*,Memory*" -O
  $0 -h myhost -H http://zabbix.example.com -u user -p pass -e "vmware*"
  $0 -h myhost -H http://zabbix.example.com -u user -p pass \\
       --warn-severity warning --crit-severity high
  $0 -h myhost -H http://zabbix.example.com -u user -p pass \\
       --api-path /api_jsonrpc.php

EOF
  exit $UNKNOWN
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
VERIFY_TLS=false
VERBOSE=false
DEBUG=false
DETAIL=false
PERFDATA=false
PERFDATA_ONLY=false
API_TOKEN=""
API_USER=""
API_PASS=""
API_PATH="/zabbix/api_jsonrpc.php"
WARN_SEV=2
CRIT_SEV=3
SKIP_DEPENDENT=false
SKIP_ACKNOWLEDGED=false
SKIP_SUPPRESSED=false
SKIP_UNSUPPORTED=false
EXCLUDES=()
OUTPUT_EXCLUDES=()
INCLUDES=()
OUTPUT_INCLUDES=()
PERFDATA_INCLUDES=()
PERFDATA_EXCLUDES=()

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--host)             HOST="$2"; shift ;;
    -H|--server-url)       SERVER_URL="$2"; shift ;;
    -u|--user)             API_USER="$2"; shift ;;
    -p|--password)         API_PASS="$2"; shift ;;
    -a|--api-token)        API_TOKEN="$2"; shift ;;
    --api-path)            API_PATH="$2"; shift ;;
    -V|--verify-tls)       VERIFY_TLS=true ;;
    -v|--verbose)          VERBOSE=true ;;
    -D|--debug)            DEBUG=true ;;
    -d|--detail)           DETAIL=true ;;
    -P|--perfdata)         PERFDATA=true ;;
    -O|--perfdata-only)    PERFDATA_ONLY=true ;;
    --warn-severity)       WARN_SEV=$(sev_num "$2"); shift
                           [[ "$WARN_SEV" == "-1" ]] && { echo "Unknown severity: $2"; exit $UNKNOWN; } ;;
    --crit-severity)       CRIT_SEV=$(sev_num "$2"); shift
                           [[ "$CRIT_SEV" == "-1" ]] && { echo "Unknown severity: $2"; exit $UNKNOWN; } ;;
    --skip-dependent)      SKIP_DEPENDENT=true ;;
    --skip-acknowledged)   SKIP_ACKNOWLEDGED=true ;;
    --skip-suppressed)     SKIP_SUPPRESSED=true ;;
    --skip-unsupported)    SKIP_UNSUPPORTED=true ;;
    -e|--exclude)
      IFS=',' read -r -a _raw <<< "$2"
      for _p in "${_raw[@]}"; do
        _p="${_p#"${_p%%[![:space:]]*}"}"; _p="${_p%"${_p##*[![:space:]]}"}"
        [[ -n "$_p" ]] && EXCLUDES+=("$_p")
      done; shift ;;
    -E|--exclude-output)
      IFS=',' read -r -a _raw <<< "$2"
      for _p in "${_raw[@]}"; do
        _p="${_p#"${_p%%[![:space:]]*}"}"; _p="${_p%"${_p##*[![:space:]]}"}"
        [[ -n "$_p" ]] && OUTPUT_EXCLUDES+=("$_p")
      done; shift ;;
    -i|--include)
      IFS=',' read -r -a _raw <<< "$2"
      for _p in "${_raw[@]}"; do
        _p="${_p#"${_p%%[![:space:]]*}"}"; _p="${_p%"${_p##*[![:space:]]}"}"
        [[ -n "$_p" ]] && INCLUDES+=("$_p")
      done; shift ;;
    -I|--include-output)
      IFS=',' read -r -a _raw <<< "$2"
      for _p in "${_raw[@]}"; do
        _p="${_p#"${_p%%[![:space:]]*}"}"; _p="${_p%"${_p##*[![:space:]]}"}"
        [[ -n "$_p" ]] && OUTPUT_INCLUDES+=("$_p")
      done; shift ;;
    -j|--include-perfdata)
      IFS=',' read -r -a _raw <<< "$2"
      for _p in "${_raw[@]}"; do
        _p="${_p#"${_p%%[![:space:]]*}"}"; _p="${_p%"${_p##*[![:space:]]}"}"
        [[ -n "$_p" ]] && PERFDATA_INCLUDES+=("$_p")
      done; shift ;;
    -g|--exclude-perfdata)
      IFS=',' read -r -a _raw <<< "$2"
      for _p in "${_raw[@]}"; do
        _p="${_p#"${_p%%[![:space:]]*}"}"; _p="${_p%"${_p##*[![:space:]]}"}"
        [[ -n "$_p" ]] && PERFDATA_EXCLUDES+=("$_p")
      done; shift ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

[[ -z "${HOST:-}" || -z "${SERVER_URL:-}" ]] && usage
if [[ -z "${API_TOKEN:-}" && ( -z "${API_USER:-}" || -z "${API_PASS:-}" ) ]]; then
  echo "ERROR: provide --api-token OR --user + --password"
  exit $UNKNOWN
fi

API_URL="${SERVER_URL%/}${API_PATH}"
CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 30)
[[ "$VERIFY_TLS" = false ]] && CURL_OPTS+=(-k)

# ---------------------------------------------------------------------------
# Pattern matching helper
# ---------------------------------------------------------------------------
match_pattern() {
  local text="$1" pat="$2" regex
  if [[ "$pat" =~ ^/.*/$ ]]; then
    regex="${pat:1:${#pat}-2}"
    [[ "$text" =~ $regex ]]
  else
    [[ "$text" == $pat ]]
  fi
}

is_included() {
  local name="$1" output="$2" pat
  [[ ${#INCLUDES[@]} -eq 0 && ${#OUTPUT_INCLUDES[@]} -eq 0 ]] && return 0
  for pat in "${INCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    match_pattern "$name" "$pat" && return 0
  done
  for pat in "${OUTPUT_INCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    match_pattern "$output" "$pat" && return 0
  done
  return 1
}

is_excluded() {
  local name="$1" output="$2" pat
  for pat in "${EXCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    match_pattern "$name" "$pat" && return 0
  done
  for pat in "${OUTPUT_EXCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    match_pattern "$output" "$pat" && return 0
  done
  return 1
}

is_perfdata_included() {
  local name="$1" pat
  [[ ${#PERFDATA_INCLUDES[@]} -eq 0 ]] && return 0
  for pat in "${PERFDATA_INCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    match_pattern "$name" "$pat" && return 0
  done
  return 1
}

is_perfdata_excluded() {
  local name="$1" pat
  for pat in "${PERFDATA_EXCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    match_pattern "$name" "$pat" && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Zabbix API helpers
# ---------------------------------------------------------------------------
ZBX_VERSION=""
ZBX_VERSION_MAJOR=0
ZBX_SESSION_TOKEN=""   # only set when we did user.login (needs logout on exit)

_zbx_raw_request() {
  # Low-level: POST a JSON body, return raw response. Used for login/version
  curl "${CURL_OPTS[@]}" -H "Content-Type: application/json" -X POST "${API_URL}" -d "$1"
}

zbx_get_version() {
  local resp
  resp=$(_zbx_raw_request '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":0}')
  ZBX_VERSION=$(echo "$resp" | jq -r '.result // empty' 2>/dev/null)
  if [[ -z "$ZBX_VERSION" ]]; then
    echo "UNKNOWN - cannot reach Zabbix API at ${API_URL}"
    exit $UNKNOWN
  fi
  ZBX_VERSION_MAJOR=$(echo "$ZBX_VERSION" | cut -d. -f1)
  [[ "$DEBUG" = true ]] && echo "DEBUG: Zabbix API version ${ZBX_VERSION} (major=${ZBX_VERSION_MAJOR})" >&2
}

zbx_login() {
  # Use pre-generated API token if provided — no session needed
  if [[ -n "${API_TOKEN:-}" ]]; then
    ZBX_SESSION_TOKEN=""   # won't need logout
    [[ "$DEBUG" = true ]] && echo "DEBUG: using static API token" >&2
    return 0
  fi
  local resp token
  local body
  if [[ "$ZBX_VERSION_MAJOR" -ge 5 ]]; then
    body=$(jq -n --arg u "$API_USER" --arg p "$API_PASS" \
      '{"jsonrpc":"2.0","method":"user.login","params":{"username":$u,"password":$p},"id":1}')
  else
    body=$(jq -n --arg u "$API_USER" --arg p "$API_PASS" \
      '{"jsonrpc":"2.0","method":"user.login","params":{"user":$u,"password":$p},"id":1}')
  fi
  resp=$(_zbx_raw_request "$body")
  token=$(echo "$resp" | jq -r '.result // empty' 2>/dev/null)
  if [[ -z "$token" ]]; then
    local err
    err=$(echo "$resp" | jq -r '.error.data // .error.message // "unknown error"' 2>/dev/null)
    echo "UNKNOWN - Zabbix login failed: ${err}"
    exit $UNKNOWN
  fi
  ZBX_SESSION_TOKEN="$token"
  [[ "$DEBUG" = true ]] && echo "DEBUG: session token obtained" >&2
}

zbx_logout() {
  [[ -z "$ZBX_SESSION_TOKEN" ]] && return 0
  local body
  if [[ "$ZBX_VERSION_MAJOR" -ge 7 ]]; then
    curl "${CURL_OPTS[@]}" -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ZBX_SESSION_TOKEN}" \
      -X POST "${API_URL}" \
      -d '{"jsonrpc":"2.0","method":"user.logout","params":{},"id":99}' >/dev/null 2>&1
  else
    body=$(jq -n --arg a "$ZBX_SESSION_TOKEN" \
      '{"jsonrpc":"2.0","method":"user.logout","params":[],"auth":$a,"id":99}')
    _zbx_raw_request "$body" >/dev/null 2>&1
  fi
  [[ "$DEBUG" = true ]] && echo "DEBUG: session logged out" >&2
}
trap zbx_logout EXIT

zbx_call() {
  # zbx_call <method> <params-json>
  local method="$1" params="$2"
  local token="${API_TOKEN:-$ZBX_SESSION_TOKEN}"
  local body resp

  if [[ "$ZBX_VERSION_MAJOR" -ge 7 ]]; then
    body=$(jq -n --arg m "$method" --argjson p "$params" \
      '{"jsonrpc":"2.0","method":$m,"params":$p,"id":1}')
    resp=$(curl "${CURL_OPTS[@]}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${token}" \
      -X POST "${API_URL}" -d "$body")
  else
    body=$(jq -n --arg m "$method" --argjson p "$params" --arg a "$token" \
      '{"jsonrpc":"2.0","method":$m,"params":$p,"auth":$a,"id":1}')
    resp=$(_zbx_raw_request "$body")
  fi

  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    local err
    err=$(echo "$resp" | jq -r '.error.data // .error.message // "API error"' 2>/dev/null)
    [[ "$DEBUG" = true ]] && echo "DEBUG: API error for ${method}: ${err}" >&2
    echo "null"
    return 1
  fi
  echo "$resp" | jq '.result' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Host lookup (by technical name or display name)
# ---------------------------------------------------------------------------
find_hostid() {
  local name="$1"
  local result hostid
  # Try exact filter on technical 'host' name first, then display 'name'
  result=$(zbx_call "host.get" \
    "$(jq -n --arg h "$name" '{"output":["hostid","host","name"],"filter":{"host":[$h]}}')")
  hostid=$(echo "$result" | jq -r '.[0].hostid // empty' 2>/dev/null)
  if [[ -z "$hostid" ]]; then
    result=$(zbx_call "host.get" \
      "$(jq -n --arg h "$name" '{"output":["hostid","host","name"],"filter":{"name":[$h]}}')")
    hostid=$(echo "$result" | jq -r '.[0].hostid // empty' 2>/dev/null)
  fi
  if [[ -z "$hostid" ]]; then
    # Last resort: search (substring match on both fields)
    result=$(zbx_call "host.get" \
      "$(jq -n --arg h "$name" '{"output":["hostid","host","name"],"search":{"host":$h,"name":$h},"searchByAny":true}')")
    hostid=$(echo "$result" | jq -r '.[0].hostid // empty' 2>/dev/null)
  fi
  echo "$hostid"
}

# ---------------------------------------------------------------------------
# Trigger processing
# ---------------------------------------------------------------------------
TOTAL=0; OK_COUNT=0; WARN_COUNT=0; CRIT_COUNT=0; UNKNOWN_COUNT=0
CRITICAL_DETAILS=(); WARNING_DETAILS=(); UNKNOWN_DETAILS=(); OK_DETAILS=()
PERFDATA_DETAILS=()

process_triggers() {
  local triggers_json="$1" problems_json="$2"
  local count
  count=$(echo "$triggers_json" | jq 'length' 2>/dev/null)
  [[ "$count" -eq 0 ]] && return 1

  # Build triggerid -> active problem lookup from problem.get results.
  # problem.get matches what the Zabbix Problems view shows, including problems
  # that require manual close (trigger.value may be 0 while problem is still open).
  declare -A _prob_sev _prob_ack _prob_supp
  while IFS= read -r prob; do
    local _tid _sev _ack _supp
    _tid=$(echo "$prob" | jq -r '.objectid')
    _sev=$(echo "$prob" | jq -r '.severity')
    _ack=$(echo "$prob" | jq -r '.acknowledged')
    _supp=$(echo "$prob" | jq -r '.suppressed')
    _prob_sev[$_tid]="$_sev"
    _prob_ack[$_tid]="$_ack"
    _prob_supp[$_tid]="$_supp"
  done < <(echo "$problems_json" | jq -c '.[]?' 2>/dev/null)

  while IFS= read -r trigger; do
    local triggerid name priority state comments

    triggerid=$(echo "$trigger" | jq -r '.triggerid // ""')
    name=$(echo "$trigger"     | jq -r '.description // "unknown"')
    priority=$(echo "$trigger" | jq -r '.priority // "0"')
    state=$(echo "$trigger"    | jq -r '.state // "0"')
    comments=$(echo "$trigger" | jq -r '.comments // ""')

    local _has_prob=0
    [[ -n "${_prob_sev[$triggerid]:-}" ]] && _has_prob=1

    if [[ "$DEBUG" = true ]]; then
      local _dbg_prob=""
      (( _has_prob )) && _dbg_prob=" PROBLEM(sev=${_prob_sev[$triggerid]})"
      echo "DEBUG: trigger '${name}' priority=${priority} state=${state}${_dbg_prob}" >&2
    fi

    # Apply include/exclude filters
    local output_text="${name}"
    [[ -n "$comments" ]] && output_text+=" ${comments}"

    if ! is_included "$name" "$output_text"; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: not included: '${name}'" >&2
      continue
    fi
    if is_excluded "$name" "$output_text"; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: excluded: '${name}'" >&2
      continue
    fi

    # Skip unsupported triggers (state=1 and no active problem) if requested
    if [[ "$SKIP_UNSUPPORTED" = true && "$state" == "1" && "$_has_prob" == "0" ]]; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: skipping unsupported trigger: '${name}'" >&2
      continue
    fi

    (( TOTAL++ ))

    local sev_label label state_num
    local _ack="0" _supp="0"

    if (( _has_prob )); then
      # Active problem from problem.get — use problem severity (may differ from trigger priority)
      local _p_sev="${_prob_sev[$triggerid]}"
      _ack="${_prob_ack[$triggerid]:-0}"
      _supp="${_prob_supp[$triggerid]:-0}"

      # Skip acknowledged / suppressed problems if requested
      if [[ "$SKIP_ACKNOWLEDGED" = true && "$_ack" == "1" ]]; then
        (( TOTAL-- ))
        [[ "$DEBUG" = true ]] && echo "DEBUG: skipping acknowledged problem: '${name}'" >&2
        continue
      fi
      if [[ "$SKIP_SUPPRESSED" = true && "$_supp" == "1" ]]; then
        (( TOTAL-- ))
        [[ "$DEBUG" = true ]] && echo "DEBUG: skipping suppressed trigger: '${name}'" >&2
        continue
      fi

      if   (( _p_sev >= CRIT_SEV )); then
        state_num=$CRITICAL; label="[CRITICAL]"
        (( CRIT_COUNT++ ))
      elif (( _p_sev >= WARN_SEV )); then
        state_num=$WARNING; label="[WARNING]"
        (( WARN_COUNT++ ))
      else
        state_num=$OK; label="[OK]"
        (( OK_COUNT++ ))
      fi
      priority="$_p_sev"
    elif [[ "$state" == "1" ]]; then
      state_num=$UNKNOWN; label="[UNKNOWN]"
      (( UNKNOWN_COUNT++ ))
    else
      state_num=$OK; label="[OK]"
      (( OK_COUNT++ ))
    fi

    sev_label=$(sev_name "$priority")

    # Build verbose detail line
    if [[ "$VERBOSE" = true ]]; then
      local detail_line="${label}: ${name} [${sev_label}]"
      if [[ "$DETAIL" = true && -n "$comments" ]]; then
        detail_line+=" - ${comments}"
      fi
      [[ "$_ack" == "1" ]] && detail_line+=" (acknowledged)"
      [[ "$_supp" == "1" ]] && detail_line+=" (suppressed)"
      case "$state_num" in
        $CRITICAL) CRITICAL_DETAILS+=("$detail_line") ;;
        $WARNING)  WARNING_DETAILS+=("$detail_line") ;;
        $UNKNOWN)  UNKNOWN_DETAILS+=("$detail_line") ;;
        *)         OK_DETAILS+=("$detail_line") ;;
      esac
    fi

    # Perfdata
    if [[ "$PERFDATA" = true || "$PERFDATA_ONLY" = true ]]; then
      if is_perfdata_included "$name" && ! is_perfdata_excluded "$name"; then
        local pkey
        pkey=$(echo "$name" | tr -s ' /:()' '_' | tr -cd 'a-zA-Z0-9_.-')
        PERFDATA_DETAILS+=("${pkey}=${state_num};1;2")
      fi
    fi

  done < <(echo "$triggers_json" | jq -c '.[]?' 2>/dev/null)

  return $(( TOTAL == 0 ? 1 : 0 ))
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
zbx_get_version
zbx_login

# Resolve host -> hostid
HOSTID=$(find_hostid "$HOST")
if [[ -z "$HOSTID" ]]; then
  echo "UNKNOWN - host '${HOST}' not found in Zabbix"
  exit $UNKNOWN
fi
[[ "$DEBUG" = true ]] && echo "DEBUG: resolved '${HOST}' -> hostid=${HOSTID}" >&2

# Get all triggers for the host (total count, state=1 detection, trigger details)
TRIGGER_PARAMS=$(jq -n \
  --arg hid "$HOSTID" \
  --argjson skip_dep "$( [[ "$SKIP_DEPENDENT" = true ]] && echo 1 || echo 0 )" \
  '{
    "hostids": [$hid],
    "output": ["triggerid","description","priority","state","comments","url"],
    "skipDependent": $skip_dep,
    "monitored": true
  }')

TRIGGERS_JSON=$(zbx_call "trigger.get" "$TRIGGER_PARAMS")

if [[ -z "$TRIGGERS_JSON" || "$TRIGGERS_JSON" == "null" ]]; then
  echo "UNKNOWN - could not retrieve triggers for host '${HOST}'"
  exit $UNKNOWN
fi

# Get active problems (matches Zabbix Problems view — source of truth for open problems)
PROBLEMS_JSON=$(zbx_call "problem.get" \
  "$(jq -n --arg hid "$HOSTID" \
    '{"hostids":[$hid],"output":["eventid","objectid","name","severity","acknowledged","suppressed"]}')")

if [[ -z "$PROBLEMS_JSON" || "$PROBLEMS_JSON" == "null" ]]; then
  PROBLEMS_JSON="[]"
fi

trigger_count=$(echo "$TRIGGERS_JSON" | jq 'length' 2>/dev/null)
problem_count=$(echo "$PROBLEMS_JSON" | jq 'length' 2>/dev/null)
[[ "$DEBUG" = true ]] && echo "DEBUG: ${trigger_count} triggers, ${problem_count} active problems" >&2

if ! process_triggers "$TRIGGERS_JSON" "$PROBLEMS_JSON"; then
  if [[ "$trigger_count" -eq 0 ]]; then
    echo "OK - no triggers configured for host '${HOST}' | total=0 ok=0 warning=0 critical=0 unknown=0"
    exit $OK
  fi
  echo "UNKNOWN - no triggers matched filters for host '${HOST}'"
  exit $UNKNOWN
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
BASIC_PERF="total=${TOTAL} ok=${OK_COUNT} warning=${WARN_COUNT} critical=${CRIT_COUNT} unknown=${UNKNOWN_COUNT}"
EXTENDED_PERF=""
if [[ "$PERFDATA" = true || "$PERFDATA_ONLY" = true ]] && [[ ${#PERFDATA_DETAILS[@]} -gt 0 ]]; then
  EXTENDED_PERF=" $(IFS=' '; echo "${PERFDATA_DETAILS[*]}")"
fi

if [[ "$PERFDATA_ONLY" = true ]]; then
  echo "${BASIC_PERF}${EXTENDED_PERF}"
  exit $OK
fi

FINAL_PERF="${BASIC_PERF}"
[[ "$PERFDATA" = true && -n "$EXTENDED_PERF" ]] && FINAL_PERF="${BASIC_PERF}${EXTENDED_PERF}"

print_sorted_details() {
  [[ ${#CRITICAL_DETAILS[@]} -gt 0 ]] && printf "%s\n" "${CRITICAL_DETAILS[@]}"
  [[ ${#WARNING_DETAILS[@]} -gt 0 ]]  && printf "%s\n" "${WARNING_DETAILS[@]}"
  [[ ${#UNKNOWN_DETAILS[@]} -gt 0 ]]  && printf "%s\n" "${UNKNOWN_DETAILS[@]}"
  [[ ${#OK_DETAILS[@]} -gt 0 ]]       && printf "%s\n" "${OK_DETAILS[@]}"
}

if   (( CRIT_COUNT > 0 )); then
  echo "[CRITICAL] - ${CRIT_COUNT} critical, ${WARN_COUNT} warning, ${UNKNOWN_COUNT} unknown (${TOTAL} triggers) | ${FINAL_PERF}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $CRITICAL
elif (( WARN_COUNT > 0 )); then
  echo "[WARNING] - ${WARN_COUNT} warning, ${UNKNOWN_COUNT} unknown (${TOTAL} triggers) | ${FINAL_PERF}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $WARNING
elif (( UNKNOWN_COUNT > 0 )); then
  echo "[UNKNOWN] - ${UNKNOWN_COUNT} triggers in unknown state (${TOTAL} triggers) | ${FINAL_PERF}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $UNKNOWN
else
  echo "[OK] - all ${TOTAL} triggers OK | ${FINAL_PERF}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $OK
fi
