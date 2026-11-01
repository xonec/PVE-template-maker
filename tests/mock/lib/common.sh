#!/usr/bin/env bash
# Shared helpers for the PVE command mocks.
#
# Bash 3.2 compatible (macOS /bin/bash) and free of jq dependencies: all
# pretty/JSON output is built with printf/awk.  Mocks read their initial
# state from $MOCK_STATE (a directory created per test case) and append one
# line per invocation to $MOCK_STATE/calls.log.
#
# calls.log format: command name followed by shell-quoted arguments, e.g.
#   qm create 8000 --machine q35 --bios ovmf
#   sudo qm create 8000 ...
# `sudo` logs the wrapped command too, so helpers in tests/lib/framework.sh
# ignore lines starting with "sudo " when counting real mock invocations.

if [ -z "${MOCK_STATE:-}" ]; then
  echo "mock: MOCK_STATE is not set; run scripts through tests/run.sh" >&2
  exit 70
fi

MOCK_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MOCK_BIN_DIR=$(cd "$MOCK_LIB_DIR/../bin" && pwd)
TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
# Quote one argument for calls.log: plain shell-safe characters stay raw
# (so assertions can match "--net0 virtio,bridge=vmbr0,firewall=0" verbatim),
# anything with whitespace / quotes / control chars is single-quoted.
mock_quote() {
  local a
  a=$(printf '%s' "$1" | awk 'BEGIN { ORS = "" } NR > 1 { printf "\\n" } { print }')
  case "$a" in
    '') printf "''" ;;
    *[!A-Za-z0-9_./:=,@%+-]*)
      a=$(printf '%s' "$a" | sed "s/'/'\\\\''/g")
      printf "'%s'" "$a"
      ;;
    *) printf '%s' "$a" ;;
  esac
}

mock_call() {
  local name="$1" arg
  shift
  mkdir -p "$MOCK_STATE" 2>/dev/null
  {
    printf '%s' "$name"
    for arg in "$@"; do
      printf ' %s' "$(mock_quote "$arg")"
    done
    printf '\n'
  } >> "$MOCK_STATE/calls.log"
}

mock_fail() {
  local msg="$1" code="${2:-1}"
  printf '%s\n' "$msg" >&2
  exit "$code"
}

mock_usage() {
  mock_fail "usage: $*" 1
}

# ---------------------------------------------------------------------------
# tiny state file helpers
# ---------------------------------------------------------------------------
file_get() { # path [default]
  local f="$1" def="${2-}"
  if [ -f "$f" ]; then cat "$f"; else printf '%s' "$def"; fi
}

file_put() { # path value
  local f="$1" v="$2"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$v" > "$f"
}

file_has() { # path -> true when present and non-empty
  [ -f "$1" ] && [ -n "$(cat "$1" 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# "key: value" config file helpers (qm config / pct config)
# ---------------------------------------------------------------------------
conf_get() { # file key [default]
  local f="$1" key="$2" def="${3-}" val
  val=""
  if [ -f "$f" ]; then
    val=$(awk -v k="$key" 'BEGIN { p = k ": " } index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$f")
  fi
  if [ -z "$val" ]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}

conf_set() { # file key value
  local f="$1" key="$2" value="$3"
  local tmp="$f.tmp.$$"
  mkdir -p "$(dirname "$f")"
  {
    if [ -f "$f" ]; then
      awk -v k="$key" 'BEGIN { p = k ": " } index($0, p) != 1 { print }' "$f"
    fi
    printf '%s: %s\n' "$key" "$value"
  } > "$tmp"
  mv "$tmp" "$f"
}

conf_del() { # file key
  local f="$1" key="$2"
  local tmp="$f.tmp.$$"
  [ -f "$f" ] || return 0
  awk -v k="$key" 'BEGIN { p = k ": " } index($0, p) != 1 { print }' "$f" > "$tmp"
  mv "$tmp" "$f"
}

# ---------------------------------------------------------------------------
# global state
# ---------------------------------------------------------------------------
mock_node() { file_get "$MOCK_STATE/node" pve; }
mock_uid() { file_get "$MOCK_STATE/uid" 0; }

# ---------------------------------------------------------------------------
# QEMU VM state:  $MOCK_STATE/vm/<vmid>/{conf,name,status,mem,bootdisk_bytes,
#                                       pid,template,guest_mode,guest_ip}
# ---------------------------------------------------------------------------
mock_vm_dir() { printf '%s/vm/%s' "$MOCK_STATE" "$1"; }
mock_vm_exists() { [ -d "$(mock_vm_dir "$1")" ]; }
mock_vm_conf() { printf '%s/conf' "$(mock_vm_dir "$1")"; }
mock_vm_attr() { file_get "$(mock_vm_dir "$1")/$2" "${3-}"; }
mock_vm_attr_put() { file_put "$(mock_vm_dir "$1")/$2" "$3"; }
mock_vm_ids() {
  local d
  for d in "$MOCK_STATE"/vm/*/; do
    [ -d "$d" ] || continue
    basename "$d"
  done | sort -n
}
mock_vm_status() { mock_vm_attr "$1" status stopped; }

# ---------------------------------------------------------------------------
# LXC container state:  $MOCK_STATE/ct/<ctid>/{conf,name,status,mem,ip}
# ---------------------------------------------------------------------------
mock_ct_dir() { printf '%s/ct/%s' "$MOCK_STATE" "$1"; }
mock_ct_exists() { [ -d "$(mock_ct_dir "$1")" ]; }
mock_ct_conf() { printf '%s/conf' "$(mock_ct_dir "$1")"; }
mock_ct_attr() { file_get "$(mock_ct_dir "$1")/$2" "${3-}"; }
mock_ct_attr_put() { file_put "$(mock_ct_dir "$1")/$2" "$3"; }
mock_ct_ids() {
  local d
  for d in "$MOCK_STATE"/ct/*/; do
    [ -d "$d" ] || continue
    basename "$d"
  done | sort -n
}
mock_ct_status() { mock_ct_attr "$1" status stopped; }

# ---------------------------------------------------------------------------
# storages: $MOCK_STATE/storages/<name>/{type,status,total_kib,used_kib}
# ---------------------------------------------------------------------------
mock_storage_exists() { [ -d "$MOCK_STATE/storages/$1" ]; }
mock_storage_attr() { file_get "$MOCK_STATE/storages/$1/$2" "${3-}"; }
mock_storage_names() {
  local d
  for d in "$MOCK_STATE"/storages/*/; do
    [ -d "$d" ] || continue
    basename "$d"
  done | sort
}
mock_require_storage() {
  mock_storage_exists "$1" || mock_fail "storage '$1' does not exist" 255
}

# ---------------------------------------------------------------------------
# bridges: $MOCK_STATE/bridges/<name>/addr  (IPv4 CIDR, e.g. 10.0.0.1/24)
# ---------------------------------------------------------------------------
mock_bridge_exists() { [ -d "$MOCK_STATE/bridges/$1" ]; }
mock_bridge_addr() { file_get "$MOCK_STATE/bridges/$1/addr" "10.0.0.1/24"; }
mock_bridge_names() {
  local d
  for d in "$MOCK_STATE"/bridges/*/; do
    [ -d "$d" ] || continue
    basename "$d"
  done | sort
}

# ---------------------------------------------------------------------------
# misc helpers
# ---------------------------------------------------------------------------
mock_require_vm() {
  mock_vm_exists "$1" ||
    mock_fail "Configuration file 'nodes/$(mock_node)/qemu-server/$1.conf' does not exist" 2
}

mock_require_ct() {
  mock_ct_exists "$1" ||
    mock_fail "Configuration file 'nodes/$(mock_node)/lxc/$1.conf' does not exist" 2
}

# next free "unusedN" index for a VM
mock_next_unused_index() {
  local conf idx=0 seen=""
  conf=$(mock_vm_conf "$1")
  if [ -f "$conf" ]; then
    seen=$(awk '/^unused[0-9]+:/ { k = $1; sub(/^unused/, "", k); sub(/:$/, "", k); if (k + 0 >= m) m = k + 0; s = 1 } END { if (s) print m; else print "" }' "$conf")
  fi
  if [ -n "$seen" ]; then idx=$((seen + 1)); fi
  printf '%s' "$idx"
}

# "16G" / "512M" / "1T" -> bytes (0 when unknown, like PVE does for plain numbers)
size_to_bytes() {
  awk -v s="$1" 'BEGIN {
    if (s ~ /^[0-9]+$/) { print s; exit }
    if (s ~ /^[0-9]+G$/) { sub(/G$/, "", s); print s * 1073741824; exit }
    if (s ~ /^[0-9]+M$/) { sub(/M$/, "", s); print s * 1048576; exit }
    if (s ~ /^[0-9]+T$/) { sub(/T$/, "", s); print s * 1099511627776; exit }
    print 0
  }'
}

# JSON-escape a plain string (used for names in generated JSON)
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Encode newlines as literal "\n" so a config value stays on one line, the way
# PVE stores multi-line properties such as "description" in the VM config.
conf_encode() {
  awk 'BEGIN { ORS = "" } NR > 1 { printf "\\n" } { print }'
}

# PVE stores tags lowercased and ';'-joined (get_unique_tags: split + lower +
# join(';')).  The mocks emulate that on writes so tests see real config state.
pve_normalize_tags() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ',' ';'
}
