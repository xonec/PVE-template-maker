#!/usr/bin/env bash
# Test framework: per-case sandbox, script runner, assertions.
# Sourced by tests/run.sh.  Bash 3.2 compatible (no associative arrays,
# no mapfile, no ${var,,}); only ordinary indexed arrays are used.

# ---------------------------------------------------------------------------
# per-case context
# ---------------------------------------------------------------------------
run_one_case() {
  local case_file="$1"
  CASE_FILE="$case_file"
  CASE_NAME=$(basename "$case_file" .sh)
  CASE_DESCRIPTION=""
  CASE_KNOWN_BUGS=""
  CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pve-mock-test.XXXXXX") || {
    printf 'cannot create temporary directory\n' >&2
    exit 2
  }
  MOCK_STATE="$CASE_DIR/state"
  CACHE_DIR_RUN="$CASE_DIR/cache"
  CALLS_LOG="$MOCK_STATE/calls.log"
  OUTPUT_LOG="$CASE_DIR/output.log"
  ASSERT_LOG="$CASE_DIR/assertions.log"
  FAILURE_LOG="$CASE_DIR/failures.log"
  SCRIPT_RC=""
  ASSERT_TOTAL=0
  ASSERT_FAILED=0
  mkdir -p "$MOCK_STATE" "$CACHE_DIR_RUN" "$CASE_DIR/home"
  : > "$OUTPUT_LOG"
  : > "$ASSERT_LOG"
  : > "$FAILURE_LOG"
  _init_default_state

  unset -f case_run 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$case_file"
  if [ "$(type -t case_run 2>/dev/null)" != "function" ]; then
    _assert_fail "case defines case_run()" "$CASE_NAME does not define case_run()"
  else
    case_run
  fi
  if [ -z "$SCRIPT_RC" ]; then
    _assert_fail "script executed" "case did not call run_script"
  fi
  if [ "$ASSERT_TOTAL" -eq 0 ]; then
    _assert_fail "case assertions" "case contains no assertions"
  fi
  if [ "$ASSERT_FAILED" -eq 0 ]; then
    CASE_PASSED=1
  else
    CASE_PASSED=0
  fi
}

cleanup_case_dir() {
  [ "${KEEP:-0}" = "1" ] && return 0
  [ -n "${CASE_DIR:-}" ] && [ -d "$CASE_DIR" ] && rm -rf "$CASE_DIR"
}

# ---------------------------------------------------------------------------
# script runner: runs the tested script with PATH pointing at tests/mock/bin,
# an isolated $MOCK_STATE and hermetic per-case paths for every tunable the
# script understands (PVE_CACHE_DIR / PVE_LOG_FILE / PVE_LOCK_FILE ...).
# PVE_FORCE_INTERACTIVE=1 can be requested per run for interactive cases.
# ---------------------------------------------------------------------------
_run_script_child() {
  cd "$REPO_ROOT" || exit 99
  env PATH="$MOCK_PATH" TERM=dumb LC_ALL=C NO_COLOR=1 \
    MOCK_STATE="$MOCK_STATE" PVE_TEST_CASE="$CASE_NAME" \
    PVE_CACHE_DIR="$CACHE_DIR_RUN" \
    PVE_LOG_FILE="$CASE_DIR/pve.log" \
    PVE_LOCK_FILE="$CASE_DIR/lock/pve.lock" \
    PVE_WAIT_INTERVAL="${PVE_TEST_WAIT_INTERVAL:-1}" \
    PVE_FORCE_INTERACTIVE="${PVE_TEST_FORCE_INTERACTIVE:-0}" \
    HOME="$CASE_DIR/home" TMPDIR="${TMPDIR:-/tmp}" \
    "$BASH_BIN" "$SCRIPT" "$@"
}

run_script() {
  SCRIPT_RC=""
  rm -f "$CASE_DIR/timed_out"
  _run_script_child "$@" <&0 > "$OUTPUT_LOG" 2>&1 &
  local pid=$! watchdog rc
  (
    sleep "${CASE_TIMEOUT:-20}"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$CASE_DIR/timed_out"
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
    fi
  ) &
  watchdog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ -f "$CASE_DIR/timed_out" ]; then
    SCRIPT_RC=124
  else
    SCRIPT_RC=$rc
  fi
}

# ---------------------------------------------------------------------------
# assertion bookkeeping
# ---------------------------------------------------------------------------
_assert_pass() { # label
  ASSERT_TOTAL=$((ASSERT_TOTAL + 1))
  printf 'ok - %s\n' "$1" >> "$ASSERT_LOG"
  if [ "${VERBOSE:-0}" = "1" ]; then
    printf '#   ok - %s\n' "$1"
  fi
}

_assert_fail() { # label detail
  ASSERT_TOTAL=$((ASSERT_TOTAL + 1))
  ASSERT_FAILED=$((ASSERT_FAILED + 1))
  printf 'not ok - %s\n' "$1" >> "$ASSERT_LOG"
  printf '%s :: %s\n' "$1" "$2" >> "$FAILURE_LOG"
  if [ "${VERBOSE:-0}" = "1" ]; then
    printf '#   not ok - %s :: %s\n' "$1" "$2"
  fi
}

_file_has_fixed() { # file needle
  [ -f "$1" ] && grep -Fq -- "$2" "$1"
}

# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------
assert_rc() { # expected [label]
  local expected="$1" label="${2:-exit code}"
  if [ -z "$SCRIPT_RC" ]; then
    _assert_fail "$label" "script was not run"
  elif [ "$SCRIPT_RC" = "$expected" ]; then
    _assert_pass "$label (rc=$SCRIPT_RC)"
  else
    _assert_fail "$label" "expected rc $expected, got $SCRIPT_RC"
  fi
}

assert_equals() { # expected actual label
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    _assert_pass "$label == $expected"
  else
    _assert_fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_output_contains() { # needle [label]
  local needle="$1" label="${2:-output contains: $1}"
  if _file_has_fixed "$OUTPUT_LOG" "$needle"; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "script output does not contain '$needle'"
  fi
}

assert_output_not_contains() { # needle [label]
  local needle="$1" label="${2:-output does not contain: $1}"
  if _file_has_fixed "$OUTPUT_LOG" "$needle"; then
    _assert_fail "$label" "script output unexpectedly contains '$needle'"
  else
    _assert_pass "$label"
  fi
}

assert_output_matches() { # extended-regex [label]
  local pattern="$1" label="${2:-output matches: $1}"
  if [ -f "$OUTPUT_LOG" ] && grep -Eq -- "$pattern" "$OUTPUT_LOG"; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "script output does not match /$pattern/"
  fi
}

assert_calls_contains() { # needle [label]
  local needle="$1" label="${2:-calls contain: $1}"
  if _file_has_fixed "$CALLS_LOG" "$needle"; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "calls.log does not contain '$needle'"
  fi
}

assert_calls_not_contains() { # needle [label]
  local needle="$1" label="${2:-calls do not contain: $1}"
  if _file_has_fixed "$CALLS_LOG" "$needle"; then
    _assert_fail "$label" "calls.log unexpectedly contains '$needle'"
  else
    _assert_pass "$label"
  fi
}

assert_mock_calls_count() { # needle expected [label]
  local needle="$1" expected="$2" label="${3:-mock calls count '$1' == $2}" count
  count=0
  if [ -f "$CALLS_LOG" ]; then
    count=$(awk -v ndl="$needle" '
      index($0, "sudo ") == 1 { next }
      index($0, ndl) > 0 { c++ }
      END { print c + 0 }' "$CALLS_LOG")
  fi
  if [ "$count" = "$expected" ]; then
    _assert_pass "$label ($count)"
  else
    _assert_fail "$label" "expected $expected mock invocation(s), got $count"
  fi
}

mock_calls_count_value() { # needle -> prints count of non-sudo calls.log lines containing needle
  local needle="$1" count=0
  if [ -f "$CALLS_LOG" ]; then
    count=$(awk -v ndl="$needle" '
      index($0, "sudo ") == 1 { next }
      index($0, ndl) > 0 { c++ }
      END { print c + 0 }' "$CALLS_LOG")
  fi
  printf '%s' "${count:-0}"
}

assert_file_contains() { # path needle [label]
  local path="$1" needle="$2" label="${3:-file contains '$2': $1}"
  if [ ! -f "$path" ]; then
    _assert_fail "$label" "file does not exist: $path"
  elif grep -Fq -- "$needle" "$path"; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "file $path does not contain '$needle'"
  fi
}

assert_file_not_contains() { # path needle [label]
  local path="$1" needle="$2" label="${3:-file lacks '$2': $1}"
  if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then
    _assert_fail "$label" "file $path unexpectedly contains '$needle'"
  else
    _assert_pass "$label"
  fi
}

assert_calls_sequence() { # needle1 needle2 ... (ordered, subtests)
  local needles=("$@") cur=0 i=0 ok=1 missing="" ln needle
  local filtered="$CASE_DIR/mock_calls.filt"
  if [ -f "$CALLS_LOG" ]; then
    grep -v '^sudo ' "$CALLS_LOG" > "$filtered" 2>/dev/null || true
  else
    : > "$filtered"
  fi
  while [ "$i" -lt "${#needles[@]}" ]; do
    needle="${needles[$i]}"
    ln=$(awk -v start="$cur" -v ndl="$needle" 'NR > start && index($0, ndl) > 0 { print NR; exit }' "$filtered")
    if [ -z "$ln" ]; then
      ok=0
      missing="$needle"
      break
    fi
    cur=$ln
    i=$((i + 1))
  done
  if [ "$ok" = "1" ]; then
    _assert_pass "call order: ${needles[*]}"
  else
    _assert_fail "call order: ${needles[*]}" "missing or out of order: '$missing'"
  fi
}

_config_value() { # file key
  awk -v k="$2" 'BEGIN { p = k ": " } index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$1" 2>/dev/null
}

assert_config_has() { # vmid needle [label]
  local vmid="$1" needle="$2" label="${3:-vm $1 config contains: $2}"
  local f="$MOCK_STATE/vm/$vmid/conf"
  if [ ! -f "$f" ]; then
    _assert_fail "$label" "VM $vmid config file does not exist"
  elif grep -Fq -- "$needle" "$f"; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "config of VM $vmid does not contain '$needle'"
  fi
}

assert_config_lacks() { # vmid needle [label]
  local vmid="$1" needle="$2" label="${3:-vm $1 config lacks: $2}"
  local f="$MOCK_STATE/vm/$vmid/conf"
  if [ -f "$f" ] && grep -Fq -- "$needle" "$f"; then
    _assert_fail "$label" "config of VM $vmid unexpectedly contains '$needle'"
  else
    _assert_pass "$label"
  fi
}

assert_config_value() { # vmid key expected [label]
  local vmid="$1" key="$2" expected="$3" label="${4:-vm $1 config $2 == $3}"
  local f="$MOCK_STATE/vm/$vmid/conf" actual
  if [ ! -f "$f" ]; then
    _assert_fail "$label" "VM $vmid config file does not exist"
    return 0
  fi
  actual=$(_config_value "$f" "$key")
  if [ "$actual" = "$expected" ]; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_ct_config_has() { # ctid needle [label]
  local ctid="$1" needle="$2" label="${3:-ct $1 config contains: $2}"
  local f="$MOCK_STATE/ct/$ctid/conf"
  if [ ! -f "$f" ]; then
    _assert_fail "$label" "CT $ctid config file does not exist"
  elif grep -Fq -- "$needle" "$f"; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "config of CT $ctid does not contain '$needle'"
  fi
}

assert_ct_config_lacks() { # ctid needle [label]
  local ctid="$1" needle="$2" label="${3:-ct $1 config lacks: $2}"
  local f="$MOCK_STATE/ct/$ctid/conf"
  if [ -f "$f" ] && grep -Fq -- "$needle" "$f"; then
    _assert_fail "$label" "config of CT $ctid unexpectedly contains '$needle'"
  else
    _assert_pass "$label"
  fi
}

assert_ct_config_value() { # ctid key expected [label]
  local ctid="$1" key="$2" expected="$3" label="${4:-ct $1 config $2 == $3}"
  local f="$MOCK_STATE/ct/$ctid/conf" actual
  if [ ! -f "$f" ]; then
    _assert_fail "$label" "CT $ctid config file does not exist"
    return 0
  fi
  actual=$(_config_value "$f" "$key")
  if [ "$actual" = "$expected" ]; then
    _assert_pass "$label"
  else
    _assert_fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_vm_exists() { # vmid [label]
  if [ -d "$MOCK_STATE/vm/$1" ]; then _assert_pass "${2:-VM $1 exists}"; else _assert_fail "${2:-VM $1 exists}" "VM $1 state directory does not exist"; fi
}

assert_vm_absent() { # vmid [label]
  if [ -d "$MOCK_STATE/vm/$1" ]; then _assert_fail "${2:-VM $1 absent}" "VM $1 state directory unexpectedly exists"; else _assert_pass "${2:-VM $1 absent}"; fi
}

assert_vm_status() { # vmid expected [label]
  local actual
  actual=$(cat "$MOCK_STATE/vm/$1/status" 2>/dev/null)
  if [ "$actual" = "$2" ]; then _assert_pass "${3:-VM $1 status == $2}"; else _assert_fail "${3:-VM $1 status == $2}" "expected '$2', got '$actual'"; fi
}

assert_ct_exists() { # ctid [label]
  if [ -d "$MOCK_STATE/ct/$1" ]; then _assert_pass "${2:-CT $1 exists}"; else _assert_fail "${2:-CT $1 exists}" "CT $1 state directory does not exist"; fi
}

assert_ct_absent() { # ctid [label]
  if [ -d "$MOCK_STATE/ct/$1" ]; then _assert_fail "${2:-CT $1 absent}" "CT $1 state directory unexpectedly exists"; else _assert_pass "${2:-CT $1 absent}"; fi
}

assert_ct_status() { # ctid expected [label]
  local actual
  actual=$(cat "$MOCK_STATE/ct/$1/status" 2>/dev/null)
  if [ "$actual" = "$2" ]; then _assert_pass "${3:-CT $1 status == $2}"; else _assert_fail "${3:-CT $1 status == $2}" "expected '$2', got '$actual'"; fi
}

assert_file_exists() { # path [label]
  if [ -f "$1" ]; then _assert_pass "${2:-file exists: $1}"; else _assert_fail "${2:-file exists: $1}" "missing file: $1"; fi
}

assert_file_missing() { # path [label]
  if [ -f "$1" ]; then _assert_fail "${2:-file missing: $1}" "file unexpectedly exists: $1"; else _assert_pass "${2:-file missing: $1}"; fi
}

assert_dir_exists() { # path [label]
  if [ -d "$1" ]; then _assert_pass "${2:-dir exists: $1}"; else _assert_fail "${2:-dir exists: $1}" "missing directory: $1"; fi
}

assert_dir_missing() { # path [label]
  if [ -d "$1" ]; then _assert_fail "${2:-dir missing: $1}" "directory unexpectedly exists: $1"; else _assert_pass "${2:-dir missing: $1}"; fi
}

assert_cache_file() { # filename [label]
  if [ -f "$CACHE_DIR_RUN/$1" ]; then _assert_pass "${2:-cache file exists: $1}"; else _assert_fail "${2:-cache file exists: $1}" "missing cache file: $CACHE_DIR_RUN/$1"; fi
}

assert_cache_file_missing() { # filename [label]
  if [ -f "$CACHE_DIR_RUN/$1" ]; then _assert_fail "${2:-cache file missing: $1}" "cache file unexpectedly exists: $CACHE_DIR_RUN/$1"; else _assert_pass "${2:-cache file missing: $1}"; fi
}

# ---------------------------------------------------------------------------
# diagnostics (printed by tests/run.sh after a case)
# ---------------------------------------------------------------------------
print_case_failures() { # [max]
  local max="${1:-25}" n=0 line
  [ -s "$FAILURE_LOG" ] || return 0
  printf '#   failed assertions:\n'
  while IFS= read -r line; do
    if [ "$n" -ge "$max" ]; then
      printf '#   ... (more failures in the kept case directory)\n'
      break
    fi
    printf '#     - %s\n' "$line"
    n=$((n + 1))
  done < "$FAILURE_LOG"
}

print_output_tail() { # [lines]
  local n="${1:-12}"
  [ -s "$OUTPUT_LOG" ] || return 0
  printf '#   script output (tail):\n'
  tail -n "$n" "$OUTPUT_LOG" 2>/dev/null | tr -d '\033' | while IFS= read -r line; do
    printf '#     %s\n' "$line"
  done
}

print_calls_tail() { # [lines]
  local n="${1:-15}"
  [ -s "$CALLS_LOG" ] || return 0
  printf '#   mock calls (tail):\n'
  tail -n "$n" "$CALLS_LOG" 2>/dev/null | while IFS= read -r line; do
    printf '#     %s\n' "$line"
  done
}
