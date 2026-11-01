#!/usr/bin/env bash
# Portable mock-based regression harness for pve-unified.sh (and any future
# single-file Proxmox VE script).
#
#   bash tests/run.sh                     # run every case, TAP output
#   bash tests/run.sh --case 04           # filter by case name substring
#   bash tests/run.sh --verbose           # show every assertion
#   bash tests/run.sh --update-baseline   # record current observed results
#   bash tests/run.sh --list              # list cases + expected result
#   bash tests/run.sh --script ../other.sh --bash /opt/homebrew/bin/bash
#
# Per case: fresh mktemp dir, isolated $MOCK_STATE, PATH=tests/mock/bin:$PATH,
# TERM=dumb, heredoc answers on stdin.  See tests/README.md for details.
# Bash 3.2 compatible: indexed arrays only, no bash4-only syntax.

set -o pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
MOCK_BIN="$TESTS_DIR/mock/bin"
CASES_DIR="$TESTS_DIR/cases"
BASELINE="$TESTS_DIR/baseline.tsv"

SCRIPT="${PVE_TEST_SCRIPT:-$REPO_ROOT/pve-unified.sh}"
BASH_BIN="${PVE_TEST_BASH:-/bin/bash}"
CASE_TIMEOUT="${PVE_TEST_TIMEOUT:-20}"
KEEP="${PVE_TEST_KEEP:-0}"
VERBOSE=0
UPDATE_BASELINE=0
LIST_ONLY=0
CASE_FILTERS=()

usage() {
  cat <<'USAGE'
Usage: bash tests/run.sh [options]

Options:
  --script PATH       script under test (default: repo-root/pve-unified.sh)
  --bash PATH         bash interpreter used to run the script (default /bin/bash)
  --case PATTERN      only run cases whose name contains PATTERN (repeatable)
  --timeout SECONDS   per-case watchdog (default 20)
  --verbose           print every assertion result
  --keep              keep the per-case temporary directories
  --update-baseline   rewrite tests/baseline.tsv and the case headers from the
                      current observed results (after a v2 rewrite, run this)
  --list              list cases and their recorded expected result
  -h, --help          show this help
USAGE
}

die() { printf 'run.sh: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --script)
      [ $# -ge 2 ] || die "--script needs a value"
      SCRIPT="$2"; shift 2 ;;
    --script=*) SCRIPT="${1#--script=}"; shift ;;
    --bash)
      [ $# -ge 2 ] || die "--bash needs a value"
      BASH_BIN="$2"; shift 2 ;;
    --bash=*) BASH_BIN="${1#--bash=}"; shift ;;
    --case)
      [ $# -ge 2 ] || die "--case needs a value"
      CASE_FILTERS[${#CASE_FILTERS[@]}]="$2"; shift 2 ;;
    --case=*) CASE_FILTERS[${#CASE_FILTERS[@]}]="${1#--case=}"; shift ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout needs a value"
      CASE_TIMEOUT="$2"; shift 2 ;;
    --timeout=*) CASE_TIMEOUT="${1#--timeout=}"; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    --keep) KEEP=1; shift ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# validate environment
# ---------------------------------------------------------------------------
case "$SCRIPT" in
  /*) : ;;
  *) SCRIPT="$(cd "$(dirname "$SCRIPT")" 2>/dev/null && pwd)/$(basename "$SCRIPT")" ;;
esac
[ -f "$SCRIPT" ] || die "script not found: $SCRIPT"
[ -x "$BASH_BIN" ] || [ -x "$(command -v "$BASH_BIN" 2>/dev/null)" ] || die "bash not found: $BASH_BIN"
[ -d "$MOCK_BIN" ] || die "mock bin directory missing: $MOCK_BIN"

for tool in mktemp awk grep sed tail tr wc; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
done

MOCK_PATH="$MOCK_BIN:$PATH"

# ---------------------------------------------------------------------------
# case discovery / filtering
# ---------------------------------------------------------------------------
ALL_FILES=()
ALL_NAMES=()
for f in "$CASES_DIR"/*.sh; do
  [ -f "$f" ] || continue
  ALL_FILES[${#ALL_FILES[@]}]="$f"
  ALL_NAMES[${#ALL_NAMES[@]}]="$(basename "$f" .sh)"
done
[ "${#ALL_FILES[@]}" -gt 0 ] || die "no cases found in $CASES_DIR"

case_selected() {
  local name="$1" pat
  if [ "${#CASE_FILTERS[@]}" -eq 0 ]; then
    return 0
  fi
  for pat in "${CASE_FILTERS[@]}"; do
    case "$name" in
      *"$pat"*) return 0 ;;
    esac
  done
  return 1
}

baseline_expected() { # case-name -> PASS|EXPECTED_FAIL (default PASS)
  local name="$1" expected=""
  if [ -f "$BASELINE" ]; then
    expected=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$BASELINE")
  fi
  [ -n "$expected" ] || expected="PASS"
  printf '%s' "$expected"
}

baseline_note() { # case-name -> known bugs note (may be empty)
  local name="$1"
  if [ -f "$BASELINE" ]; then
    awk -F'\t' -v n="$name" '$1 == n { print $3; exit }' "$BASELINE"
  fi
}

SELECTED_FILES=()
SELECTED_NAMES=()
i=0
while [ "$i" -lt "${#ALL_FILES[@]}" ]; do
  if case_selected "${ALL_NAMES[$i]}"; then
    SELECTED_FILES[${#SELECTED_FILES[@]}]="${ALL_FILES[$i]}"
    SELECTED_NAMES[${#SELECTED_NAMES[@]}]="${ALL_NAMES[$i]}"
  fi
  i=$((i + 1))
done
[ "${#SELECTED_FILES[@]}" -gt 0 ] || die "no case matched the --case filter(s)"

if [ "$LIST_ONLY" = "1" ]; then
  printf 'cases in %s:\n' "$CASES_DIR"
  i=0
  while [ "$i" -lt "${#SELECTED_FILES[@]}" ]; do
    printf '  %-40s expected=%s\n' "${SELECTED_NAMES[$i]}" "$(baseline_expected "${SELECTED_NAMES[$i]}")"
    note=$(baseline_note "${SELECTED_NAMES[$i]}")
    [ -n "$note" ] && printf '  %-40s %s\n' "" "$note"
    i=$((i + 1))
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# bash / platform banner
# ---------------------------------------------------------------------------
SCRIPT_BASH_BANNER=$("$BASH_BIN" --version 2>/dev/null | head -n 1)
[ -n "$SCRIPT_BASH_BANNER" ] || die "cannot execute $BASH_BIN"

printf 'TAP version 13\n'
printf '# script: %s\n' "$SCRIPT"
printf '# runner bash: %s (%s)\n' "$BASH_VERSION" "${BASH:-bash}"
printf '# script bash: %s\n' "$SCRIPT_BASH_BANNER"
printf '# mock path: %s\n' "$MOCK_BIN"
printf '# per-case env: PVE_CACHE_DIR / PVE_LOG_FILE / PVE_LOCK_FILE / PVE_WAIT_INTERVAL\n'
printf '# baseline: %s\n' "$BASELINE"
for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [ -x "$newer" ] && [ "$newer" != "$BASH_BIN" ]; then
    printf '# note: newer bash available: %s (use --bash %s to run the script with it)\n' "$newer" "$newer"
  fi
done
for tool in jq bc; do
  command -v "$tool" >/dev/null 2>&1 || printf '# WARNING: %s not found; the tested script requires it (apt install %s)\n' "$tool" "$tool"
done
printf '1..%d\n' "${#SELECTED_FILES[@]}"

# ---------------------------------------------------------------------------
# run cases
# ---------------------------------------------------------------------------
. "$TESTS_DIR/lib/framework.sh"
. "$TESTS_DIR/lib/scene.sh"

PASS=0
XFAIL=0
FAIL=0
XPASS=0
RUN_NAMES=()
RUN_ACTUAL=()
RUN_BUGS=()
RUN_DESCRIPTIONS=()

n=0
idx=0
while [ "$idx" -lt "${#SELECTED_FILES[@]}" ]; do
  f="${SELECTED_FILES[$idx]}"
  n=$((n + 1))
  run_one_case "$f"
  name="$CASE_NAME"
  expected=$(baseline_expected "$name")
  if [ "$CASE_PASSED" = "1" ]; then actual="PASS"; else actual="EXPECTED_FAIL"; fi
  if [ -n "$CASE_KNOWN_BUGS" ]; then bugs="$CASE_KNOWN_BUGS"; else bugs=$(baseline_note "$name"); fi
  RUN_NAMES[${#RUN_NAMES[@]}]="$name"
  RUN_ACTUAL[${#RUN_ACTUAL[@]}]="$actual"
  RUN_BUGS[${#RUN_BUGS[@]}]="$bugs"
  RUN_DESCRIPTIONS[${#RUN_DESCRIPTIONS[@]}]="$CASE_DESCRIPTION"

  if [ "$expected" = "EXPECTED_FAIL" ]; then
    if [ "$actual" = "EXPECTED_FAIL" ]; then
      XFAIL=$((XFAIL + 1))
      printf 'ok %d - %s # XFAIL (expected failure / known bug)\n' "$n" "$name"
      [ -n "$CASE_DESCRIPTION" ] && printf '#   %s\n' "$CASE_DESCRIPTION"
      [ -n "$bugs" ] && printf '#   known bug: %s\n' "$bugs"
      print_case_failures 10
    else
      XPASS=$((XPASS + 1))
      printf 'not ok %d - %s # XPASS: baseline says EXPECTED_FAIL but the case passed\n' "$n" "$name"
      [ -n "$CASE_DESCRIPTION" ] && printf '#   %s\n' "$CASE_DESCRIPTION"
      printf '#   the known bug may be fixed: rerun with --update-baseline\n'
    fi
  else
    if [ "$actual" = "PASS" ]; then
      PASS=$((PASS + 1))
      printf 'ok %d - %s\n' "$n" "$name"
      [ -n "$CASE_DESCRIPTION" ] && printf '#   %s\n' "$CASE_DESCRIPTION"
    else
      FAIL=$((FAIL + 1))
      printf 'not ok %d - %s\n' "$n" "$name"
      [ -n "$CASE_DESCRIPTION" ] && printf '#   %s\n' "$CASE_DESCRIPTION"
      print_case_failures 25
      print_output_tail 12
      print_calls_tail 15
    fi
  fi
  if [ "$KEEP" != "1" ]; then
    cleanup_case_dir
  else
    printf '#   kept case dir: %s\n' "$CASE_DIR"
  fi
  idx=$((idx + 1))
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '# Summary: total=%d pass=%d xfail=%d fail=%d xpass=%d\n' \
  "${#SELECTED_FILES[@]}" "$PASS" "$XFAIL" "$FAIL" "$XPASS"
if [ "$XFAIL" -gt 0 ]; then
  printf '# Expected failures (known bugs, documented in tests/README.md):\n'
  i=0
  while [ "$i" -lt "${#RUN_NAMES[@]}" ]; do
    if [ "${RUN_ACTUAL[$i]}" = "EXPECTED_FAIL" ] && [ "$(baseline_expected "${RUN_NAMES[$i]}")" = "EXPECTED_FAIL" ]; then
      printf '#   %s%s\n' "${RUN_NAMES[$i]}" "$( [ -n "${RUN_BUGS[$i]}" ] && printf ' :: %s' "${RUN_BUGS[$i]}" )"
    fi
    i=$((i + 1))
  done
fi

# ---------------------------------------------------------------------------
# baseline update (maintenance mode)
# ---------------------------------------------------------------------------
rewrite_case_header() { # case-file expected
  local file="$1" expected="$2" tmp="$1.tmp.$$" written=0 line
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '# expected:'*)
          printf '# expected: %s\n' "$expected"
          written=1
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$file"
    if [ "$written" = "0" ]; then
      printf '\n# expected: %s\n' "$expected"
    fi
  } > "$tmp"
  mv "$tmp" "$file"
}

write_baseline() {
  local tmp="$BASELINE.tmp.$$" i=0 j=0 name expected note found
  {
    printf '# case\texpected\tnote\n'
    printf '# generated by: bash tests/run.sh --update-baseline\n'
    while [ "$i" -lt "${#ALL_NAMES[@]}" ]; do
      name="${ALL_NAMES[$i]}"
      found=0
      j=0
      while [ "$j" -lt "${#RUN_NAMES[@]}" ]; do
        if [ "${RUN_NAMES[$j]}" = "$name" ]; then
          expected="${RUN_ACTUAL[$j]}"
          note="${RUN_BUGS[$j]}"
          found=1
          break
        fi
        j=$((j + 1))
      done
      if [ "$found" = "0" ]; then
        expected=$(baseline_expected "$name")
        note=$(baseline_note "$name")
      fi
      note=$(printf '%s' "$note" | tr '\011\012' '  ')
      printf '%s\t%s\t%s\n' "$name" "$expected" "$note"
      i=$((i + 1))
    done
  } > "$tmp"
  mv "$tmp" "$BASELINE"
}

if [ "$UPDATE_BASELINE" = "1" ]; then
  write_baseline
  printf '# baseline updated: %s\n' "$BASELINE"
  idx=0
  while [ "$idx" -lt "${#SELECTED_FILES[@]}" ]; do
    name="${SELECTED_NAMES[$idx]}"
    expected=""
    j=0
    while [ "$j" -lt "${#RUN_NAMES[@]}" ]; do
      if [ "${RUN_NAMES[$j]}" = "$name" ]; then
        expected="${RUN_ACTUAL[$j]}"
        break
      fi
      j=$((j + 1))
    done
    if [ -n "$expected" ]; then
      rewrite_case_header "${SELECTED_FILES[$idx]}" "$expected"
      printf '# case header updated: %s -> %s\n' "$name" "$expected"
    fi
    idx=$((idx + 1))
  done
  exit 0
fi

if [ "$FAIL" -gt 0 ] || [ "$XPASS" -gt 0 ]; then
  printf '# RESULT: FAIL\n'
  exit 1
fi
printf '# RESULT: PASS\n'
exit 0
