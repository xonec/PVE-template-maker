#!/bin/bash
# =============================================================================
#  PVE-template-maker / pve-unified.sh  v2.0.0
#
#  在 Proxmox VE 节点上创建云模板 / 虚拟机、从模板克隆虚拟机，
#  并把 VM/LXC 的局域网 IP 写入 tags（格式：ip-10.0.0.5）。
#
#  设计约束：
#    * 单文件，方便 `bash <(curl ...)` 直接运行；
#    * 兼容 bash >= 3.2（PVE 8/9 自带 bash 5.x；本仓库测试在 macOS bash 3.2 下运行）；
#    * 交互菜单保持简单，自动化请使用子命令 + 参数（见 --help）；
#    * 所有诊断输出走 stderr，stdout 只输出机器可读结果；
#    * 破坏性操作（销毁半成品 VM、清缓存）必须显式确认，非交互需 --yes。
#
#  项目地址: https://github.com/xonec/PVE-template-maker
# =============================================================================
set -o pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="pve-unified.sh"
PROJECT_URL="https://github.com/xonec/PVE-template-maker"

# ----------------------------- 可配置默认值 -----------------------------
# 环境变量（优先于脚本内默认值，方便自动化）：
#   PVE_MIRROR_BASES  空格分隔的镜像前缀列表；或旧变量 MIRROR_BASE（单个）
#   PVE_CACHE_DIR     镜像缓存目录；或旧变量 CACHE_DIR
#   PVE_TAG_PREFIX    IP 标签前缀（默认 ip-）
#   PVE_LOG_FILE      日志文件（默认 /var/log/pve-unified.log）
#   PVE_LOCK_FILE     互斥锁文件（默认 /run/lock/pve-unified.lock）
#   PVE_WAIT_INTERVAL 等待 IP 的轮询间隔秒数（默认 5，测试可调小）
if [ -n "${PVE_MIRROR_BASES:-}" ]; then
  read -r -a MIRROR_BASES <<< "$PVE_MIRROR_BASES"
elif [ -n "${MIRROR_BASE:-}" ]; then
  MIRROR_BASES=("$MIRROR_BASE")
else
  MIRROR_BASES=(
    "https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/"
    "https://github.com/oneclickvirt/pve_kvm_images/releases/download/"
  )
fi
DEBIAN_OFFICIAL_BASE="${PVE_DEBIAN_BASE:-https://cloud.debian.org/images/cloud/}"
CACHE_DIR="${PVE_CACHE_DIR:-${CACHE_DIR:-/var/cache/pve-unified-images}}"
TAG_PREFIX="${PVE_TAG_PREFIX:-ip-}"
LOG_FILE="${PVE_LOG_FILE:-/var/log/pve-unified.log}"
LOCK_FILE="${PVE_LOCK_FILE:-/run/lock/pve-unified.lock}"
WAIT_IP_INTERVAL="${PVE_WAIT_INTERVAL:-5}"
DEFAULT_IFACE_EXCLUDE='^(lo|docker[0-9]*|br-[0-9a-f]+|veth.*|virbr.*|tailscale.*|zt.*|wg.*|tun[0-9]+|tap[0-9]+|cni.*|flannel.*|cilium.*)$'
DEFAULT_WAIT_IP=180

# ----------------------------- 发行版表 -----------------------------
# 顺序即菜单序号；第三个数组区分 thirdparty / official。
DISTRO_LABELS=(
  "Debian-11"
  "Debian-11-Official-Generic"
  "Debian-12"
  "Debian-12-Official-Generic"
  "Debian-13"
  "Debian-13-Official-Generic"
  "Ubuntu-18.04"
  "Ubuntu-20.04"
  "Ubuntu-22.04"
  "Ubuntu-24.04"
  "CentOS-8"
  "CentOS-9"
)
DISTRO_PATHS=(
  "debian/debian11.qcow2"
  "${DEBIAN_OFFICIAL_BASE}bullseye/latest/debian-11-genericcloud-amd64.qcow2"
  "debian/debian12.qcow2"
  "${DEBIAN_OFFICIAL_BASE}bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  "debian/debian13.qcow2"
  "${DEBIAN_OFFICIAL_BASE}trixie/latest/debian-13-genericcloud-amd64.qcow2"
  "ubuntu/ubuntu1804.qcow2"
  "ubuntu/ubuntu2004.qcow2"
  "ubuntu/ubuntu2204.qcow2"
  "ubuntu/ubuntu2404.qcow2"
  "centos/centos8.qcow2"
  "centos/centos9.qcow2"
)
DISTRO_SOURCES=(
  "thirdparty" "official" "thirdparty" "official" "thirdparty" "official"
  "thirdparty" "thirdparty" "thirdparty" "thirdparty" "thirdparty" "thirdparty"
)

# ----------------------------- 运行时全局变量 -----------------------------
COMMAND=""
ASSUME_YES=0
DRY_RUN=0
NO_COLOR="${NO_COLOR:-0}"
VERBOSE=0
INTERACTIVE=0
LOG_ENABLED=0

OPT_DISTRO=""
OPT_VMID=""
OPT_NAME=""
OPT_BRIDGE=""
OPT_STORAGE=""
OPT_CORES=""
OPT_MEMORY=""
OPT_DISK=""
OPT_BIOS="ovmf"
OPT_MACHINE="q35"
OPT_SECUREBOOT=0
OPT_CIUSER=""
OPT_CIPASSWORD=""
OPT_SSHKEYS=""
OPT_STATIC_IP=""
OPT_GATEWAY=""
OPT_NAMESERVER=""
OPT_IPV6=1
OPT_VM_TAGS=""
OPT_DESCRIPTION=""
OPT_NO_DESCRIPTION=0
OPT_NO_TAGS=0
OPT_NO_START=0
OPT_ONBOOT=0
OPT_WAIT_IP=""
OPT_IFACE_EXCLUDE="$DEFAULT_IFACE_EXCLUDE"
OPT_SUBNET=""
OPT_IMPORT_FORMAT="auto"
OPT_SHA256=""
OPT_SKIP_SPACE=0
OPT_TEMPLATE_ID=""
OPT_FULL_CLONE=0
OPT_SYNC_EXCLUDE=""

MODE=""
MODE_LABEL=""
NODE=""
PVE_RELEASE=""
JSON_OK=0
CLUSTER_ROWS=""
STORAGE_ROWS=""
IMAGES_STORAGES=()
BRIDGES=()

VMID=""
VM_NAME=""
DISTRO_LABEL=""
DISTRO_PATH=""
DISTRO_SOURCE=""
IMAGE_FILE=""
IMAGE_DISPLAY=""
VMBR=""
STORAGE=""
CORES=""
MEM_MB=""
MEM_SIZE=""
DISK_GB=""
CIUSER=""
CIPASSWORD=""
IPCONF=""
VM_DESCRIPTION=""
VM_TAGS=""
TARGET_DISK_SUPPORT=""
FAILED_VMID=""
CREATED_BY_US=0
LOCK_HOLDER=""
if [ -x /bin/sleep ]; then SLEEP_BIN="/bin/sleep"; else SLEEP_BIN="sleep"; fi

# ----------------------------- 颜色 / 日志 -----------------------------
setup_colors() {
  USE_COLOR=0
  if [ "${NO_COLOR:-0}" = "0" ] && [ -t 2 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    USE_COLOR=1
  fi
  if [ "$USE_COLOR" -eq 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
  else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""
  fi
}

init_log() {
  LOG_ENABLED=0
  [ -z "$LOG_FILE" ] && return 0
  local dir
  dir=$(dirname "$LOG_FILE" 2>/dev/null || printf '.')
  if [ -f "$LOG_FILE" ] && [ -w "$LOG_FILE" ]; then
    LOG_ENABLED=1
  elif [ -d "$dir" ] && [ -w "$dir" ]; then
    LOG_ENABLED=1
  fi
}

_log() {
  [ "${LOG_ENABLED:-0}" -eq 1 ] || return 0
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || LOG_ENABLED=0
}

info()  { _log INFO "$*";  printf '%b[INFO]%b %s\n' "$BLUE"   "$NC" "$*" >&2; }
ok()    { _log OK "$*";    printf '%b[ OK ]%b %s\n' "$GREEN"  "$NC" "$*" >&2; }
warn()  { _log WARN "$*";  printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()   { _log ERR "$*";   printf '%b[ERR ]%b %s\n' "$RED"    "$NC" "$*" >&2; }
debug() { [ "${VERBOSE:-0}" -eq 1 ] || return 0; _log DEBUG "$*"; printf '%b[DBG ]%b %s\n' "$CYAN" "$NC" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

print_header() {
  if [ "$USE_COLOR" -eq 1 ]; then
    printf '%b%s%b\n' "$BOLD" "$1" "$NC" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}

clear_screen() {
  [ -t 2 ] || return 0
  printf '\033[2J\033[H' >&2
}

# ----------------------------- 基础工具 -----------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# 是否可交互（测试可通过 PVE_FORCE_INTERACTIVE=1 强制走交互路径）
interactive_stdin() {
  [ -t 0 ] && return 0
  [ "${PVE_FORCE_INTERACTIVE:-0}" = "1" ]
}

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

norm_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '._ -'; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

is_valid_ipv4() {
  local ip=$1 a
  case "$ip" in *[!0-9.]*|'') return 1;; esac
  oldIFS=$IFS; IFS=.
  # shellcheck disable=SC2086  # 有意按 . 分列
  set -- $ip
  IFS=$oldIFS
  [ $# -eq 4 ] || return 1
  for a in "$@"; do is_uint "$a" || return 1; [ "$a" -le 255 ] || return 1; done
  return 0
}

is_valid_cidr() {
  local cidr=$1 ip prefix
  ip=${cidr%/*}; prefix=${cidr#*/}
  [ "$ip" != "$cidr" ] || return 1
  is_valid_ipv4 "$ip" || return 1
  is_uint "$prefix" || return 1
  [ "$prefix" -ge 1 ] && [ "$prefix" -le 32 ]
}

is_valid_tag() {
  local t=$1
  [ -n "$t" ] || return 1
  [ "${#t}" -le 128 ] || return 1
  case "$t" in
    [A-Za-z0-9_]*) ;;
    *) return 1 ;;
  esac
  case "$t" in
    *[!A-Za-z0-9._+-]*) return 1 ;;
  esac
  return 0
}

file_size() {
  [ -f "$1" ] || { printf '0'; return 0; }
  wc -c <"$1" 2>/dev/null | tr -d ' '
}

format_size() {
  local bytes=${1:-0}
  if [ "$bytes" -ge 1073741824 ]; then
    printf '%s GiB' "$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')"
  elif [ "$bytes" -ge 1048576 ]; then
    printf '%s MiB' "$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }')"
  elif [ "$bytes" -ge 1024 ]; then
    printf '%s KiB' "$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1024 }')"
  else
    printf '%s B' "$bytes"
  fi
}

quote_cmd() {
  local a out=""
  for a in "$@"; do
    out="$out $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

# dry-run 时只打印命令
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%b[dry-run]%b %s\n' "$CYAN" "$NC" "$(quote_cmd "$@")" >&2
    return 0
  fi
  debug "执行: $(quote_cmd "$@")"
  "$@"
}

run_step() {
  local desc=$1
  shift
  info "$desc"
  if ! run "$@"; then
    err "$desc 失败"
    return 1
  fi
  return 0
}

with_timeout() {
  local secs=$1
  shift
  if have timeout; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# ----------------------------- 交互输入 -----------------------------
ask_value() {
  local prompt=$1 default=$2 regex=$3 errmsg=$4 input
  while true; do
    printf '%s' "$prompt" >&2
    [ -n "$default" ] && printf ' [%s]' "$default" >&2
    printf ': ' >&2
    if ! read -r input; then
      die "读取输入失败（非交互环境请使用 --yes 与命令行参数）"
    fi
    input=$(trim "$input")
    [ -z "$input" ] && input="$default"
    if [ -z "$input" ]; then
      err "输入不能为空"
      continue
    fi
    if [ -n "$regex" ]; then
      if ! [[ "$input" =~ $regex ]]; then
        err "$errmsg"
        continue
      fi
    fi
    REPLY="$input"
    return 0
  done
}

ask_confirm() {
  local prompt=$1 default=$2 input suffix
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if ! interactive_stdin; then
    return 1
  fi
  case "$default" in
    y|Y) suffix="[Y/n]" ;;
    *)   suffix="[y/N]" ;;
  esac
  while true; do
    printf '%s %s: ' "$prompt" "$suffix" >&2
    if ! read -r input; then
      return 1
    fi
    input=$(lower "$(trim "$input")")
    [ -z "$input" ] && input=$(lower "$default")
    case "$input" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) err "请输入 y 或 n" ;;
    esac
  done
}

choose_one() {
  local prompt=$1
  shift
  local -a items
  items=("$@")
  local n=${#items[@]} i input
  if [ "$n" -eq 0 ]; then
    die "没有可选项"
  fi
  if [ "$n" -eq 1 ]; then
    info "仅检测到 1 个选项，自动选择：${items[0]}"
    REPLY="${items[0]}"
    return 0
  fi
  printf '%s\n' "$prompt" >&2
  for ((i = 0; i < n; i++)); do
    printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2
  done
  while true; do
    printf '请选择 [1-%d]: ' "$n" >&2
    if ! read -r input; then
      die "读取输入失败（非交互环境请使用 --yes 与命令行参数）"
    fi
    input=$(trim "$input")
    if is_uint "$input" && [ "$input" -ge 1 ] && [ "$input" -le "$n" ]; then
      REPLY="${items[$((input - 1))]}"
      return 0
    fi
    err "输入无效，请输入 1-$n 之间的数字"
  done
}

pause_return() {
  interactive_stdin || return 0
  printf '\n按回车返回主菜单...' >&2
  read -r _ || true
}

# ----------------------------- 环境探测 -----------------------------
need_root() {
  [ "$(id -u)" -eq 0 ] || die "请以 root 运行（PVE 节点上的 root shell）"
}

require_cmds() {
  local -a missing
  missing=()
  local c
  for c in qm pct pvesm; do
    have "$c" || missing+=("$c")
  done
  if ! have wget && ! have curl; then
    missing+=("wget/curl")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    die "缺少必要命令：${missing[*]}（apt install -y qemu-utils wget curl）"
  fi
  for c in qemu-img jq flock timeout sha256sum pvesh; do
    have "$c" || debug "可选命令缺失：$c"
  done
}

# 用独立的 holder 进程持锁，而不是在当前 shell 里 `exec 9>lock`：
#   * 当前 shell 的锁 fd 会被 qm start 拉起的 QEMU/kvm 进程继承，VM 运行期间
#     锁永远不释放（真机实测），导致后续所有调用都被误判为“另一个实例在运行”；
#   * holder 是独立子进程，脚本自己的子进程不会继承锁 fd；holder 发现父进程退出
#     后自动释放，脚本被 SIGKILL 也不会留下永久锁。
acquire_lock() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  have flock || return 0
  [ -n "$LOCK_FILE" ] || return 0
  if [ -n "${LOCK_HOLDER:-}" ] && kill -0 "$LOCK_HOLDER" 2>/dev/null; then
    return 0
  fi
  local dir marker i
  dir=$(dirname "$LOCK_FILE" 2>/dev/null || printf '.')
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  [ -w "$dir" ] || return 0
  marker="${LOCK_FILE}.$$"
  rm -f "$marker" 2>/dev/null
  (
    flock -n 9 || exit 9
    : > "$marker"
    while kill -0 "$$" 2>/dev/null; do
      # 关闭锁 fd 再 sleep：避免 holder 被杀后 sleep 子进程短暂持有锁（真机实测竞态）
      "$SLEEP_BIN" 1 9>&-
    done
    rm -f "$marker"
  ) 9>"$LOCK_FILE" >/dev/null 2>&1 &
  LOCK_HOLDER=$!
  i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$marker" ] && break
    kill -0 "$LOCK_HOLDER" 2>/dev/null || break
    "$SLEEP_BIN" 0.1
    i=$((i + 1))
  done
  if [ -f "$marker" ]; then
    rm -f "$marker"
    debug "已获取锁：$LOCK_FILE（holder=$LOCK_HOLDER）"
    return 0
  fi
  LOCK_HOLDER=""
  die "另一个 pve-unified.sh 正在运行（锁文件：$LOCK_FILE）"
}

detect_node() {
  NODE=$(hostname -s 2>/dev/null)
  [ -n "$NODE" ] || NODE=$(hostname 2>/dev/null)
  [ -n "$NODE" ] || NODE=localhost
  debug "节点：$NODE"
}

detect_pve_version() {
  local out
  PVE_RELEASE=""
  if have pvesh; then
    out=$(pvesh get /version --output-format json 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      if [ "$JSON_OK" -eq 1 ]; then
        PVE_RELEASE=$(printf '%s' "$out" | jq -r '.release // .version // empty' 2>/dev/null) || PVE_RELEASE=""
      else
        PVE_RELEASE=$(printf '%s' "$out" | sed -n 's/.*"release"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
      fi
    fi
  fi
  if [ -z "$PVE_RELEASE" ] && have pveversion; then
    PVE_RELEASE=$(pveversion 2>/dev/null | sed -n 's#pve-manager/\([0-9.]*\)/.*#\1#p' | head -n1)
  fi
  [ -n "$PVE_RELEASE" ] || PVE_RELEASE="unknown"
  debug "PVE 版本：$PVE_RELEASE"
}

detect_json() {
  if have jq; then JSON_OK=1; else JSON_OK=0; fi
}

load_cluster_resources() {
  CLUSTER_ROWS=""
  local json out
  json=""
  if [ "$JSON_OK" -eq 1 ] && have pvesh; then
    json=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || json=""
    if [ -n "$json" ]; then
      CLUSTER_ROWS=$(printf '%s' "$json" | jq -r '
        .[]? | select((.vmid // 0) > 0)
        | [(.vmid | tostring),
           (if (.type // "") == "lxc" then "lxc" else "qemu" end),
           (.status // "unknown"),
           (if ((.template // 0) == 1 or (.template // 0) == true) then "1" else "0" end),
           (.name // "")] | @tsv' 2>/dev/null) || CLUSTER_ROWS=""
    fi
  fi
  if [ -z "$CLUSTER_ROWS" ]; then
    out=$(qm list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1 "\tqemu\t" $3 "\t0\t" $2}') || out=""
    CLUSTER_ROWS="$out"
    out=$(pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1 "\tlxc\t" $2 "\t0\t" $4}') || out=""
    if [ -n "$out" ]; then
      if [ -n "$CLUSTER_ROWS" ]; then
        CLUSTER_ROWS="${CLUSTER_ROWS}"$'\n'"${out}"
      else
        CLUSTER_ROWS="$out"
      fi
    fi
  fi
  debug "发现 $(printf '%s\n' "$CLUSTER_ROWS" | grep -c . ) 个 VM/容器记录"
}

cluster_row() {
  local id=$1
  local line
  [ -n "$CLUSTER_ROWS" ] || return 1
  line=$(printf '%s\n' "$CLUSTER_ROWS" | awk -F'\t' -v id="$id" '$1 == id { print; exit }') || line=""
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

vmid_in_use() {
  local id=$1
  if [ -n "$CLUSTER_ROWS" ]; then
    if printf '%s\n' "$CLUSTER_ROWS" | awk -F'\t' -v id="$id" '$1 == id { found = 1 } END { exit(found ? 0 : 1) }'; then
      return 0
    fi
    return 1
  fi
  [ -f "/etc/pve/qemu-server/$id.conf" ] || [ -f "/etc/pve/lxc/$id.conf" ]
}

is_template_id() {
  local type=$1 id=$2 tpl
  tpl=$(cluster_row "$id" | awk -F'\t' '{ print $4 }' 2>/dev/null || printf '')
  [ "$tpl" = "1" ] && return 0
  if ! [ -n "$CLUSTER_ROWS" ] || [ "$tpl" = "0" ]; then
    case "$type" in
      qemu) qm config "$id" 2>/dev/null | grep -q '^template: *1' && return 0 ;;
      lxc)  pct config "$id" 2>/dev/null | grep -q '^template: *1' && return 0 ;;
    esac
  fi
  return 1
}

next_free_vmid() {
  if have pvesh; then
    local n
    n=$(pvesh get /cluster/nextid --output-format json 2>/dev/null | tr -cd '0-9') || n=""
    if [ -n "$n" ] && [ "$n" -ge 100 ] 2>/dev/null; then
      printf '%s' "$n"
      return 0
    fi
  fi
  local used id=100
  used=""
  [ -n "$CLUSTER_ROWS" ] && used=$(printf '%s\n' "$CLUSTER_ROWS" | cut -f1)
  while true; do
    if ! printf '%s\n' "$used" | grep -qx "$id" 2>/dev/null; then
      printf '%s' "$id"
      return 0
    fi
    id=$((id + 1))
    if [ "$id" -gt 999 ] && [ "$id" -lt 8000 ]; then
      id=8000
    elif [ "$id" -gt 8999 ] && [ "$id" -lt 100000 ]; then
      id=100000
    elif [ "$id" -gt 999999999 ]; then
      die "无法自动分配 VMID（已用 ID 过多）"
    fi
  done
}

load_storages() {
  STORAGE_ROWS=""
  IMAGES_STORAGES=()
  local rows json name type status total used avail_kib rest content avail line c
  rows=""
  if [ "$JSON_OK" -eq 1 ] && have pvesh; then
    json=$(pvesh get "/nodes/$NODE/storage" --output-format json 2>/dev/null) || json=""
    if [ -n "$json" ]; then
      rows=$(printf '%s' "$json" | jq -r '
        .[]? | select((.active == 1) or (.active == true))
        | [(.storage // ""), (.type // ""),
           ((.content // "") | if type == "array" then join(",") else tostring end),
           ((.avail // 0) | tostring)] | @tsv' 2>/dev/null) || rows=""
    fi
  fi
  if [ -z "$rows" ]; then
    local pvesm_out content_hint=""
    pvesm_out=$(pvesm status --content images --enabled 1 2>/dev/null) || pvesm_out=""
    if [ -z "$pvesm_out" ]; then
      pvesm_out=$(pvesm status 2>/dev/null) || pvesm_out=""
    else
      content_hint="images"
    fi
    while read -r name type status total used avail_kib rest; do
      [ -z "$name" ] && continue
      [ "$name" = "Name" ] && continue
      [ "$status" = "active" ] || continue
      is_uint "$avail_kib" || avail_kib=0
      STORAGE_ROWS="${STORAGE_ROWS}${name}|${type}|${content_hint}|$((avail_kib * 1024))"$'\n'
    done < <(printf '%s\n' "$pvesm_out")
  else
    while IFS=$'\t' read -r name type content avail; do
      [ -z "$name" ] && continue
      STORAGE_ROWS="${STORAGE_ROWS}${name}|${type}|${content}|${avail}"$'\n'
    done <<< "$rows"
  fi

  while IFS='|' read -r name type c avail; do
    [ -z "$name" ] && continue
    case ",$c," in
      *",images,"*) IMAGES_STORAGES+=("$name") ;;
      *)
        if [ -z "$c" ]; then
          IMAGES_STORAGES+=("$name")
        fi
        ;;
    esac
  done <<< "$STORAGE_ROWS"
  if [ "${#IMAGES_STORAGES[@]}" -eq 0 ]; then
    while IFS='|' read -r name type c avail; do
      [ -n "$name" ] && IMAGES_STORAGES+=("$name")
    done <<< "$STORAGE_ROWS"
  fi
  [ "${#IMAGES_STORAGES[@]}" -eq 0 ] && IMAGES_STORAGES=("local")
  debug "存储：$(printf '%s ' "${IMAGES_STORAGES[@]}")"
}

storage_exists() {
  local name=$1
  [ -z "$STORAGE_ROWS" ] && return 0
  printf '%s\n' "$STORAGE_ROWS" | awk -F'|' -v n="$name" '$1 == n { found = 1 } END { exit(found ? 0 : 1) }'
}

storage_field() {
  local name=$1 field=$2
  [ -z "$STORAGE_ROWS" ] && return 0
  printf '%s\n' "$STORAGE_ROWS" | awk -F'|' -v n="$name" -v f="$field" '$1 == n { print $f; exit }'
}

storage_avail_bytes() {
  local name=$1 v
  v=$(storage_field "$name" 4)
  is_uint "$v" || v=0
  printf '%s' "$v"
}

storage_supports_images() {
  local name=$1 c
  [ -z "$STORAGE_ROWS" ] && return 0
  c=$(storage_field "$name" 3)
  case "$c" in
    "") return 0 ;;
    *images*) return 0 ;;
    *) return 1 ;;
  esac
}

load_bridges() {
  BRIDGES=()
  local out b
  out=""
  if have ip; then
    if [ "$JSON_OK" -eq 1 ]; then
      out=$(ip -j link show type bridge 2>/dev/null | jq -r '.[].ifname' 2>/dev/null) || out=""
    fi
    if [ -z "$out" ]; then
      out=$(ip link show type bridge 2>/dev/null | sed -n 's/^[0-9][0-9]*: \([^:@][^:@]*\).*/\1/p') || out=""
    fi
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      # 排除非 PVE 网桥（docker/lxc/virbr/防火墙桥等），避免菜单误导
      case "$b" in lo|fwbr*|vnet*|docker*|br-*|virbr*|veth*|lxcbr*) continue ;; esac
      BRIDGES+=("$b")
    done <<< "$out"
  fi
  if [ "${#BRIDGES[@]}" -eq 0 ] && [ -d /sys/class/net ]; then
    for b in /sys/class/net/*; do
      [ -d "$b/bridge" ] || continue
      b=${b##*/}
      [ "$b" = "lo" ] && continue
      case "$b" in fwbr*) continue ;; esac
      BRIDGES+=("$b")
    done
  fi
  if [ "${#BRIDGES[@]}" -gt 0 ]; then
    local -a sorted
    sorted=()
    for b in "${BRIDGES[@]}"; do
      case "$b" in vmbr*) sorted+=("$b") ;; esac
    done
    for b in "${BRIDGES[@]}"; do
      case "$b" in vmbr*) ;; *) sorted+=("$b") ;; esac
    done
    BRIDGES=("${sorted[@]}")
  fi
  [ "${#BRIDGES[@]}" -eq 0 ] && BRIDGES=("vmbr0")
  debug "网桥：${BRIDGES[*]}"
}

bridge_exists() {
  local name=$1 b
  [ -n "$name" ] || return 1
  for b in "${BRIDGES[@]}"; do
    [ "$b" = "$name" ] && return 0
  done
  [ -e "/sys/class/net/$name" ] && return 0
  if have ip; then
    ip link show "$name" >/dev/null 2>&1 && return 0
  fi
  return 1
}

load_environment() {
  detect_json
  detect_node
  detect_pve_version
  load_cluster_resources
  load_storages
  load_bridges
}

# ----------------------------- 发行版相关 -----------------------------
distro_find() {
  local input=$1 i key
  if is_uint "$input" && [ "$input" -ge 1 ] && [ "$input" -le "${#DISTRO_LABELS[@]}" ]; then
    printf '%s' "$input"
    return 0
  fi
  key=$(norm_key "$input")
  for ((i = 0; i < ${#DISTRO_LABELS[@]}; i++)); do
    if [ "$(norm_key "${DISTRO_LABELS[$i]}")" = "$key" ]; then
      printf '%s' "$((i + 1))"
      return 0
    fi
  done
  return 1
}

distro_load() {
  local idx=$1
  if ! is_uint "$idx" || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#DISTRO_LABELS[@]}" ]; then
    die "发行版序号无效：$idx"
  fi
  local pos=$((idx - 1))
  DISTRO_LABEL="${DISTRO_LABELS[$pos]}"
  DISTRO_PATH="${DISTRO_PATHS[$pos]}"
  DISTRO_SOURCE="${DISTRO_SOURCES[$pos]}"
}

distro_ciuser() {
  case "$DISTRO_SOURCE" in
    official) printf 'debian' ;;
    *) printf 'root' ;;
  esac
}

distro_url() {
  local path=$1 b
  case "$path" in
    http://*|https://*) printf '%s\n' "$path"; return 0 ;;
  esac
  for b in "${MIRROR_BASES[@]}"; do
    printf '%s%s\n' "$b" "$path"
  done
}

image_candidate_urls() {
  distro_url "$1"
}

first_image_url() {
  local path=$1
  case "$path" in
    http://*|https://*) printf '%s' "$path" ;;
    *) printf '%s%s' "${MIRROR_BASES[0]}" "$path" ;;
  esac
}

list_distros() {
  local i url
  printf '%-4s %-30s %-12s %s\n' "ID" "名称" "来源" "镜像地址"
  for ((i = 0; i < ${#DISTRO_LABELS[@]}; i++)); do
    url=$(first_image_url "${DISTRO_PATHS[$i]}")
    printf '%-4d %-30s %-12s %s\n' "$((i + 1))" "${DISTRO_LABELS[$i]}" "${DISTRO_SOURCES[$i]}" "$url"
  done
}

# ----------------------------- 镜像缓存 -----------------------------
check_cache_space() {
  local rel=$1 avail_kib remote first
  [ "$OPT_SKIP_SPACE" -eq 1 ] && return 0
  avail_kib=$(df -Pk "$CACHE_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if ! is_uint "$avail_kib"; then
    avail_kib=$(df -Pk "$(dirname "$CACHE_DIR")" 2>/dev/null | awk 'NR == 2 { print $4 }')
  fi
  is_uint "$avail_kib" || return 0
  remote=""
  first=$(first_image_url "$rel")
  if have curl; then
    remote=$(curl -sIL --max-time 10 "$first" 2>/dev/null | awk '
      tolower($1) == "content-length:" { v = $2 }
      END { gsub(/\r/, "", v); print v }')
  fi
  if is_uint "$remote" && [ "$remote" -gt 0 ] && [ "$remote" -gt $((avail_kib * 1024)) ]; then
    warn "缓存目录空间可能不足：需要 $(format_size "$remote")，可用 $(format_size $((avail_kib * 1024)))"
    if [ "$INTERACTIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
      ask_confirm "是否继续下载？" "n" || return 1
    fi
  fi
  return 0
}

sha256_of_file() {
  local f=$1
  if have sha256sum; then
    sha256sum "$f" 2>/dev/null | awk '{ print $1 }'
  elif have shasum; then
    shasum -a 256 "$f" 2>/dev/null | awk '{ print $1 }'
  fi
}

validate_image() {
  local f=$1 magic bytes
  [ -f "$f" ] || return 1
  bytes=$(file_size "$f")
  [ "$bytes" -gt 1024 ] || return 1
  magic=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
  case "$magic" in
    514649fb) ;;
    *) return 1 ;;
  esac
  if have qemu-img; then
    qemu-img info --output=json "$f" >/dev/null 2>&1 || return 1
  fi
  return 0
}

image_virtual_bytes() {
  local f=$1 v
  have qemu-img || { printf '0'; return 0; }
  v=$(qemu-img info --output=json "$f" 2>/dev/null \
      | sed -n 's/.*"virtual-size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
      | head -n1)
  is_uint "$v" || v=0
  printf '%s' "$v"
}

download_image() {
  local rel=$1 file part cached url rc attempt first
  file=${rel##*/}
  [ -n "$file" ] || die "无效镜像路径：$rel"
  cached="$CACHE_DIR/$file"
  part="$cached.part"

  if [ "$DRY_RUN" -eq 1 ]; then
    IMAGE_FILE="$cached"
    info "[dry-run] 将确保镜像存在：$cached"
    return 0
  fi

  if [ -f "$cached" ]; then
    if validate_image "$cached"; then
      if [ -n "$OPT_SHA256" ]; then
        local csum
        csum=$(lower "$(sha256_of_file "$cached")")
        if [ -z "$csum" ]; then
          warn "缺少 sha256sum/shasum，无法校验缓存镜像的 SHA256，继续使用"
        elif [ "$csum" != "$(lower "$OPT_SHA256")" ]; then
          warn "缓存镜像 SHA256 不匹配，删除后重新下载：$cached"
          rm -f "$cached"
        else
          IMAGE_FILE="$cached"
          ok "命中缓存：$cached（SHA256 校验通过，$(format_size "$(file_size "$cached")")）"
          return 0
        fi
      else
        IMAGE_FILE="$cached"
        ok "命中缓存：$cached（$(format_size "$(file_size "$cached")")）"
        return 0
      fi
    else
      warn "缓存文件校验失败，删除后重新下载：$cached"
      rm -f "$cached"
    fi
  fi

  check_cache_space "$rel" || die "磁盘空间不足，已取消"
  have wget || have curl || die "需要 wget 或 curl 下载镜像"

  mkdir -p "$CACHE_DIR" || die "无法创建缓存目录：$CACHE_DIR"
  first=$(first_image_url "$rel")
  info "下载镜像：$first"
  info "缓存路径：$cached"

  rc=1
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    debug "镜像候选：$url"
    for attempt in 1 2; do
      if [ "$attempt" -gt 1 ]; then
        warn "重试下载（$attempt/2）：$url"
        sleep 2
      fi
      if have wget; then
        local -a wopts
        if [ -t 2 ]; then
          wopts=(--show-progress -q -c -O "$part")
        else
          wopts=(-q -c -O "$part")
        fi
        wget "${wopts[@]}" "$url"
      else
        curl -fL --retry 2 -C - -o "$part" "$url"
      fi
      rc=$?
      if [ "$rc" -eq 0 ] && validate_image "$part"; then
        if [ -n "$OPT_SHA256" ]; then
          local sum=""
          if have sha256sum; then sum=$(sha256sum "$part" | awk '{ print $1 }')
          elif have shasum; then sum=$(shasum -a 256 "$part" | awk '{ print $1 }')
          fi
          if [ -n "$sum" ] && [ "$(lower "$sum")" != "$(lower "$OPT_SHA256")" ]; then
            err "SHA256 校验失败：$sum"
            rc=1
            continue
          fi
        fi
        mv -f "$part" "$cached" || die "无法写入缓存文件：$cached"
        IMAGE_FILE="$cached"
        ok "镜像下载完成：$cached（$(format_size "$(file_size "$cached")")）"
        return 0
      fi
      warn "下载失败或文件无效（HTTP 错误 / 非 qcow2 / 不完整）"
    done
  done < <(image_candidate_urls "$rel")

  rm -f "$part"
  die "镜像下载失败：$rel（可检查网络或手动下载到 $cached）"
}

# ----------------------------- 导入磁盘 -----------------------------
qm_supports_target_disk() {
  if [ -z "$TARGET_DISK_SUPPORT" ]; then
    local help
    # PVE 9 上 `qm importdisk --help` 会报 Unknown option，改用 `qm help importdisk`
    help=$(qm importdisk --help 2>&1) || help=""
    case "$help" in
      *--target-disk*) TARGET_DISK_SUPPORT=1 ;;
      *)
        help=$(qm help importdisk 2>&1) || help=""
        case "$help" in
          *--target-disk*) TARGET_DISK_SUPPORT=1 ;;
          *) TARGET_DISK_SUPPORT=0 ;;
        esac
        ;;
    esac
  fi
  [ "$TARGET_DISK_SUPPORT" = "1" ]
}

qm_unused_volumes() {
  qm config "$1" 2>/dev/null \
    | sed -n 's/^unused[0-9]*:[[:space:]]*\([^,[:space:]]*\).*/\1/p' \
    | tr -d '\r'
}

resolve_import_format() {
  local type
  if [ "$OPT_IMPORT_FORMAT" != "auto" ]; then
    printf '%s' "$OPT_IMPORT_FORMAT"
    return 0
  fi
  type=$(storage_field "$STORAGE" 2)
  case "$type" in
    dir|nfs|cifs|glusterfs|cephfs|btrfs) printf 'qcow2' ;;
    *) printf '' ;;
  esac
}

step_create_vm() {
  info "创建虚拟机（VMID $VMID）..."
  local -a args
  local pre_enrolled
  args=(qm create "$VMID"
    --name "$VM_NAME"
    --cpu host
    --cores "$CORES"
    --memory "$MEM_MB"
    --balloon "$MEM_MB"
    --machine "$OPT_MACHINE"
    --ostype l26
    --scsihw virtio-scsi-pci
    --agent "1,fstrim_cloned_disks=1"
    --net0 "virtio,bridge=${VMBR},firewall=0"
    --serial0 socket
    --vga serial0)
  if [ "$OPT_BIOS" = "ovmf" ]; then
    if [ "$OPT_SECUREBOOT" -eq 1 ]; then pre_enrolled=1; else pre_enrolled=0; fi
    args+=(--bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=${pre_enrolled}")
  else
    args+=(--bios seabios)
  fi
  if ! run "${args[@]}"; then
    err "qm create 失败"
    return 1
  fi
  [ "$DRY_RUN" -eq 1 ] || CREATED_BY_US=1
  return 0
}

step_import_disk() {
  local fmt new_vol before after v i
  fmt=$(resolve_import_format)
  info "导入系统盘到存储 $STORAGE ..."
  if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$IMAGE_FILE" ]; then
    err "镜像文件不存在：$IMAGE_FILE"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if qm_supports_target_disk; then
      if [ -n "$fmt" ]; then
        run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$fmt" --target-disk scsi0
      else
        run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --target-disk scsi0
      fi
    else
      if [ -n "$fmt" ]; then
        run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$fmt"
      else
        run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE"
      fi
      run qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
    fi
    step_resize_disk
    return $?
  fi

  before=$(qm_unused_volumes "$VMID")
  if qm_supports_target_disk; then
    if [ -n "$fmt" ]; then
      run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$fmt" --target-disk scsi0 \
        || { err "磁盘导入失败"; return 1; }
    else
      run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --target-disk scsi0 \
        || { err "磁盘导入失败"; return 1; }
    fi
  else
    if [ -n "$fmt" ]; then
      run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$fmt" \
        || { err "磁盘导入失败"; return 1; }
    else
      run qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" \
        || { err "磁盘导入失败"; return 1; }
    fi
    new_vol=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      after=$(qm_unused_volumes "$VMID")
      while IFS= read -r v; do
        [ -z "$v" ] && continue
        case "|${before}|" in
          *"|${v}|"*) continue ;;
        esac
        new_vol="$v"
        break
      done <<< "$after"
      [ -n "$new_vol" ] && break
      sleep 0.5
    done
    if [ -z "$new_vol" ]; then
      err "未找到导入后的 unused 磁盘（VMID $VMID）"
      return 1
    fi
    info "导入为：$new_vol"
    run qm set "$VMID" --scsi0 "$new_vol" || { err "挂载 scsi0 失败"; return 1; }
  fi
  step_resize_disk
}

step_resize_disk() {
  local target_bytes img_bytes img_gb
  target_bytes=$((DISK_GB * 1024 * 1024 * 1024))
  img_bytes=$(image_virtual_bytes "$IMAGE_FILE")
  if is_uint "$img_bytes" && [ "$img_bytes" -gt 0 ] && [ "$target_bytes" -le "$img_bytes" ]; then
    img_gb=$(((img_bytes + 1073741823) / 1073741824))
    if [ "$target_bytes" -lt "$img_bytes" ]; then
      warn "目标磁盘 ${DISK_GB}G 小于镜像原始大小 ${img_gb}G，跳过缩容（保留镜像大小）"
    else
      info "磁盘大小已与镜像一致（${DISK_GB}G），无需扩容"
    fi
    return 0
  fi
  run_step "扩容系统盘到 ${DISK_GB}G" qm resize "$VMID" scsi0 "${DISK_GB}G"
}

step_configure_vm() {
  local -a args
  args=(qm set "$VMID"
    --ide2 "${STORAGE}:cloudinit"
    --ipconfig0 "$IPCONF"
    --ciuser "$CIUSER"
    --boot order=scsi0
    --serial0 socket
    --vga serial0)
  [ -n "$OPT_NAMESERVER" ] && args+=(--nameserver "$OPT_NAMESERVER")
  [ -n "$CIPASSWORD" ] && args+=(--cipassword "$CIPASSWORD")
  [ -n "$OPT_SSHKEYS" ] && args+=(--sshkeys "$OPT_SSHKEYS")
  [ "$OPT_ONBOOT" -eq 1 ] && args+=(--onboot 1)
  [ -n "$VM_TAGS" ] && args+=(--tags "$VM_TAGS")
  [ -n "$VM_DESCRIPTION" ] && args+=(--description "$VM_DESCRIPTION")
  run_step "配置 Cloud-Init / 启动项 / 描述" "${args[@]}"
}

# ----------------------------- 参数解析与校验 -----------------------------
validate_vmid_arg() {
  local id=$1
  is_uint "$id" || die "VMID 必须是数字：$id"
  [ "$id" -ge 100 ] || die "VMID 必须 >= 100：$id"
  [ "$id" -le 999999999 ] || die "VMID 过大：$id"
}

parse_memory_mb() {
  local v=$1 num
  case "$v" in
    *[Gg]) num=${v%[Gg]}; is_uint "$num" || return 1; printf '%s' "$((num * 1024))" ;;
    *[Mm]) num=${v%[Mm]}; is_uint "$num" || return 1; printf '%s' "$num" ;;
    *)      is_uint "$v" || return 1; printf '%s' "$v" ;;
  esac
}

parse_disk_gb() {
  local v=$1 num
  case "$v" in
    *[Gg]) num=${v%[Gg]}; is_uint "$num" || return 1; printf '%s' "$num" ;;
    *)      is_uint "$v" || return 1; printf '%s' "$v" ;;
  esac
}

sanitize_vm_name() {
  local n
  n=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/^-*//' -e 's/-*$//')
  [ -n "$n" ] || n="pve-vm"
  printf '%s' "${n:0:63}"
}

validate_vm_name() {
  local n=$1
  [ -n "$n" ] || return 1
  [ "${#n}" -le 63 ] || return 1
  case "$n" in
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$n" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

build_description() {
  local mode_label=$1 creds
  if [ -n "$OPT_DESCRIPTION" ]; then
    printf '%s' "$OPT_DESCRIPTION"
    return 0
  fi
  if [ "$OPT_NO_DESCRIPTION" -eq 1 ]; then
    printf ''
    return 0
  fi
  if [ -n "$CIPASSWORD" ]; then
    creds="${CIUSER} / ${CIPASSWORD}"
  elif [ -n "$OPT_SSHKEYS" ]; then
    creds="${CIUSER} / 仅 SSH 公钥"
  else
    creds="${CIUSER} / （未设置密码，需通过 SSH 公钥或自行重设）"
  fi
  cat <<EOF
# ${DISTRO_LABEL} ${mode_label}

- 创建时间：$(date '+%F %T')
- 创建工具：${SCRIPT_NAME} v${SCRIPT_VERSION}
- 镜像来源：${IMAGE_DISPLAY}
- 默认登录：${creds}
- IP 标签：tags 中的 ${TAG_PREFIX}<ip>（由同步脚本写入）
- 项目地址：${PROJECT_URL}

⚠️ 安全提示：首次登录后请立即修改默认密码，或改用 SSH 公钥登录。
EOF
}

build_ipconfig() {
  local ipconf
  if [ -n "$OPT_STATIC_IP" ]; then
    ipconf="ip=${OPT_STATIC_IP}"
    [ -n "$OPT_GATEWAY" ] && ipconf="${ipconf},gw=${OPT_GATEWAY}"
    [ "$OPT_IPV6" -eq 1 ] && ipconf="${ipconf},ip6=dhcp"
  else
    ipconf="ip=dhcp"
    [ "$OPT_IPV6" -eq 1 ] && ipconf="${ipconf},ip6=dhcp"
  fi
  printf '%s' "$ipconf"
}

resolve_create_params() {
  local idx tmp
  # 交互判定
  INTERACTIVE=0
  interactive_stdin && INTERACTIVE=1
  if [ "$INTERACTIVE" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    die "检测到非交互环境：请加 --yes 并显式指定必要参数（--distro 等），或改用交互终端"
  fi

  clear_screen
  print_header "========================================"
  print_header "          PVE ${MODE_LABEL}创建向导"
  print_header "========================================"
  info "节点：${NODE}（PVE ${PVE_RELEASE}）"
  info "已存在 VMID：$(printf '%s\n' "$CLUSTER_ROWS" | awk -F'\t' '$1 != "" { printf "%s ", $1 }')"
  info "可用网桥：$(printf '%s ' "${BRIDGES[@]}")"
  info "可用存储：$(printf '%s ' "${IMAGES_STORAGES[@]}")"

  # 1. 发行版
  if [ -n "$OPT_DISTRO" ]; then
    idx=$(distro_find "$OPT_DISTRO") || die "未知发行版：$OPT_DISTRO（可用 --list-distros 查看）"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    choose_one "请选择操作系统：" "${DISTRO_LABELS[@]}"
    idx=$(distro_find "$REPLY") || die "发行版解析失败：$REPLY"
  else
    die "非交互模式必须指定 --distro（可用 --list-distros 查看）"
  fi
  distro_load "$idx"

  # 2. VMID
  if [ -n "$OPT_VMID" ]; then
    validate_vmid_arg "$OPT_VMID"
    if vmid_in_use "$OPT_VMID"; then
      die "VMID $OPT_VMID 已被 VM/容器占用"
    fi
    VMID="$OPT_VMID"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    tmp=$(next_free_vmid)
    while true; do
      ask_value "请输入 VMID" "$tmp" '^[0-9]+$' "VMID 必须是数字"
      validate_vmid_arg "$REPLY"
      if vmid_in_use "$REPLY"; then
        err "VMID $REPLY 已被占用，请换一个"
        continue
      fi
      VMID="$REPLY"
      break
    done
  else
    VMID=$(next_free_vmid)
  fi

  # 3. 名称
  if [ -n "$OPT_NAME" ]; then
    VM_NAME="$OPT_NAME"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    ask_value "请输入虚拟机名称" "$(sanitize_vm_name "$DISTRO_LABEL")" '^[A-Za-z0-9][A-Za-z0-9._-]*$' "名称只能包含字母、数字、点、下划线、连字符，且以字母或数字开头"
    VM_NAME="$REPLY"
  else
    VM_NAME=$(sanitize_vm_name "$DISTRO_LABEL")
  fi
  validate_vm_name "$VM_NAME" || die "虚拟机名称非法：$VM_NAME（1-63 位，字母/数字/点/下划线/连字符）"

  # 4. 网桥
  if [ -n "$OPT_BRIDGE" ]; then
    VMBR="$OPT_BRIDGE"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    choose_one "请选择网络桥接：" "${BRIDGES[@]}"
    VMBR="$REPLY"
  else
    VMBR="${BRIDGES[0]}"
  fi
  [ -n "$VMBR" ] || die "无法确定网络桥接"

  # 5. 存储
  if [ -n "$OPT_STORAGE" ]; then
    STORAGE="$OPT_STORAGE"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    choose_one "请选择存储位置：" "${IMAGES_STORAGES[@]}"
    STORAGE="$REPLY"
  else
    STORAGE="${IMAGES_STORAGES[0]}"
  fi
  [ -n "$STORAGE" ] || die "无法确定存储位置"

  # 6. CPU / 内存 / 磁盘
  if [ -n "$OPT_CORES" ]; then
    CORES="$OPT_CORES"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    choose_one "请选择 CPU 核心数：" "1 核" "2 核" "4 核" "8 核" "自定义"
    case "$REPLY" in
      自定义) ask_value "请输入 CPU 核心数" "2" '^[1-9][0-9]*$' "CPU 核心数必须是正整数"; CORES="$REPLY" ;;
      *) CORES=$(printf '%s' "$REPLY" | tr -cd '0-9') ;;
    esac
  else
    CORES=2
  fi
  is_uint "$CORES" && [ "$CORES" -ge 1 ] || die "CPU 核心数非法：$CORES"
  [ "$CORES" -le 256 ] || die "CPU 核心数过大：$CORES"

  if [ -n "$OPT_MEMORY" ]; then
    MEM_SIZE="$OPT_MEMORY"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    choose_one "请选择内存大小：" "1G" "2G" "4G" "8G" "16G" "自定义"
    if [ "$REPLY" = "自定义" ]; then
      ask_value "请输入内存（如 4G / 2048M）" "4G" '^[1-9][0-9]*([GgMm])?$' "格式：数字+G/M 或纯数字(MB)"
      MEM_SIZE="$REPLY"
    else
      MEM_SIZE="$REPLY"
    fi
  else
    MEM_SIZE=2G
  fi
  MEM_MB=$(parse_memory_mb "$MEM_SIZE") || die "内存格式无效：$MEM_SIZE"
  [ "$MEM_MB" -ge 256 ] || die "内存不能小于 256MB"

  if [ -n "$OPT_DISK" ]; then
    DISK_GB=$(parse_disk_gb "$OPT_DISK") || die "磁盘格式无效：$OPT_DISK"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    choose_one "请选择硬盘大小：" "16G" "32G" "64G" "128G" "256G" "自定义"
    if [ "$REPLY" = "自定义" ]; then
      ask_value "请输入硬盘大小（如 20G）" "20G" '^[1-9][0-9]*[Gg]?$' "格式：数字+G"
      DISK_GB=$(parse_disk_gb "$REPLY") || die "磁盘格式无效：$REPLY"
    else
      DISK_GB=$(parse_disk_gb "$REPLY")
    fi
  else
    DISK_GB=20
  fi
  [ "$DISK_GB" -ge 8 ] || die "硬盘不能小于 8G（当前 ${DISK_GB}G）"

  # 7. BIOS / 安全启动
  [ -n "$OPT_BIOS" ] || OPT_BIOS=ovmf
  case "$OPT_BIOS" in
    ovmf|seabios) ;;
    *) die "BIOS 只能是 ovmf 或 seabios：$OPT_BIOS" ;;
  esac
  case "$OPT_MACHINE" in
    q35|pc) ;;
    *) die "机型只能是 q35 或 pc：$OPT_MACHINE" ;;
  esac
  case "$OPT_IMPORT_FORMAT" in
    auto|raw|qcow2|vmdk) ;;
    *) die "--import-format 只能是 auto/raw/qcow2/vmdk：$OPT_IMPORT_FORMAT" ;;
  esac
  if [ "$OPT_BIOS" != "ovmf" ] && [ "$OPT_SECUREBOOT" -eq 1 ]; then
    warn "--secureboot 仅在 ovmf 下生效，已忽略"
    OPT_SECUREBOOT=0
  fi

  # 8. Cloud-Init 用户/密码/网络
  if [ -n "$OPT_CIUSER" ]; then
    CIUSER="$OPT_CIUSER"
  else
    CIUSER=$(distro_ciuser)
  fi
  if [ -n "$OPT_CIPASSWORD" ]; then
    CIPASSWORD="$OPT_CIPASSWORD"
  elif [ -n "$OPT_SSHKEYS" ]; then
    CIPASSWORD=""
    info "已指定 SSH 公钥，未设置 cloud-init 密码"
  else
    CIPASSWORD="oneclickvirt"
    warn "使用默认密码 oneclickvirt，首次登录后请立即修改（或用 --cipassword/--sshkeys 覆盖）"
  fi
  if [ -n "$OPT_SSHKEYS" ]; then
    [ -r "$OPT_SSHKEYS" ] || die "SSH 公钥文件不可读：$OPT_SSHKEYS"
  fi
  if [ -n "$OPT_STATIC_IP" ]; then
    is_valid_cidr "$OPT_STATIC_IP" || die "静态 IP 格式应为 x.x.x.x/prefix：$OPT_STATIC_IP"
    if [ -n "$OPT_GATEWAY" ]; then
      is_valid_ipv4 "$OPT_GATEWAY" || die "网关格式无效：$OPT_GATEWAY"
    fi
  elif [ -n "$OPT_GATEWAY" ]; then
    die "--gateway 必须与 --static-ip 一起使用"
  fi
  IPCONF=$(build_ipconfig)

  # 正则参数校验（grep -E 语法错误返回 2）
  if [ -n "$OPT_SUBNET" ]; then
    printf '0.0.0.0\n' | grep -Eq -- "$OPT_SUBNET" 2>/dev/null
    [ "$?" -eq 2 ] && die "--subnet 不是合法正则：$OPT_SUBNET"
  fi
  if [ -n "$OPT_IFACE_EXCLUDE" ]; then
    printf 'lo\n' | grep -Eq -- "$OPT_IFACE_EXCLUDE" 2>/dev/null
    [ "$?" -eq 2 ] && die "--iface-exclude 不是合法正则：$OPT_IFACE_EXCLUDE"
  fi

  # 9. 等待 IP / 标签
  if [ -z "$OPT_WAIT_IP" ]; then
    if [ "$MODE" = "template" ]; then OPT_WAIT_IP=0; else OPT_WAIT_IP="$DEFAULT_WAIT_IP"; fi
  fi
  is_uint "$OPT_WAIT_IP" || die "--wait-ip 必须是秒数：$OPT_WAIT_IP"
  if [ -n "$OPT_VM_TAGS" ]; then
    local t
    while IFS= read -r t; do
      t=$(lower "$(trim "$t")")
      [ -z "$t" ] && continue
      is_valid_tag "$t" || die "非法 tag：$t（允许字母/数字/_/-/.，且以字母或数字/_ 开头）"
      case ";${VM_TAGS};" in
        *";${t};"*) continue ;;
      esac
      VM_TAGS="${VM_TAGS:+${VM_TAGS};}${t}"
    done < <(printf '%s\n' "$OPT_VM_TAGS" | tr ',;' '\n')
  fi

  # 10. 镜像展示地址（描述中会引用）
  IMAGE_DISPLAY=$(first_image_url "$DISTRO_PATH")

  # 11. 描述
  if [ "$OPT_NO_DESCRIPTION" -eq 1 ]; then
    VM_DESCRIPTION=""
  else
    VM_DESCRIPTION=$(build_description "$MODE_LABEL")
  fi
  return 0
}

preflight_create() {
  local avail needed
  if [ -n "$STORAGE_ROWS" ]; then
    storage_exists "$STORAGE" || die "存储不存在或未激活：$STORAGE（可用：$(printf '%s ' "${IMAGES_STORAGES[@]}")）"
    if ! storage_supports_images "$STORAGE"; then
      warn "存储 $STORAGE 未声明 images 内容，qm importdisk 可能失败"
    fi
    avail=$(storage_avail_bytes "$STORAGE")
    if is_uint "$avail" && [ "$avail" -gt 0 ]; then
      needed=$((DISK_GB * 1024 * 1024 * 1024 + 1073741824 + 268435456))
      if [ "$needed" -gt "$avail" ]; then
        warn "存储空间可能不足：预计需要 $(format_size "$needed")，可用 $(format_size "$avail")"
        if [ "$INTERACTIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
          ask_confirm "是否继续创建？" "n" || { info "已取消"; return 1; }
        elif [ "$OPT_SKIP_SPACE" -eq 0 ]; then
          die "存储空间不足（确认可忽略时加 --skip-space-check）"
        fi
      fi
    fi
  else
    warn "未能获取存储列表，跳过存储空间校验"
  fi
  if ! bridge_exists "$VMBR"; then
    warn "未检测到网桥 $VMBR（qm create 可能失败，可加 --bridge 指定）"
  fi
  if vmid_in_use "$VMID"; then
    die "VMID $VMID 已被 VM/容器占用"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    info "镜像：$IMAGE_DISPLAY"
  fi
  return 0
}

print_create_plan() {
  print_header "----------- 创建参数确认 -----------"
  info "模式：${MODE_LABEL}"
  info "发行版：${DISTRO_LABEL}（${DISTRO_SOURCE}）"
  info "镜像：${IMAGE_DISPLAY}"
  info "VMID：${VMID}    名称：${VM_NAME}"
  info "网桥：${VMBR}    存储：${STORAGE}"
  info "CPU：${CORES} 核    内存：${MEM_SIZE}（${MEM_MB} MB）    磁盘：${DISK_GB}G"
  info "BIOS：${OPT_BIOS}    机型：${OPT_MACHINE}    QEMU Agent：启用"
  info "Cloud-Init：${CIUSER} / $([ -n "$CIPASSWORD" ] && printf '密码已设置' || printf '仅 SSH 公钥')    IP：${IPCONF}"
  local start_desc
  if [ "$MODE" = template ]; then
    start_desc="转换为模板（不启动）"
  elif [ "$OPT_NO_START" -eq 1 ]; then
    start_desc="创建后不启动"
  else
    start_desc="创建后启动"
  fi
  info "启动：${start_desc}"
  [ -n "$VM_TAGS" ] && info "附加 tags：${VM_TAGS}"
  print_header "------------------------------------"
  return 0
}

# ----------------------------- 标签 / IP -----------------------------
# PVE 后端会小写化、去重、排序并用 ';' 重拼 tags（get_unique_tags），
# 因此幂等比较必须按“集合”而不是字符串顺序。
tag_set() {
  printf '%s\n' "$1" \
    | tr ';,' '\n' \
    | awk '{ gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); if ($0 == "") next;
             t = tolower($0);
             if (t ~ /^[a-z0-9_][a-z0-9_+.-]*$/) print t }' \
    | LC_ALL=C sort -u \
    | tr '\n' ';' \
    | sed 's/;$//'
}

tags_equal() {
  [ "$(tag_set "$1")" = "$(tag_set "$2")" ]
}

config_tags() {
  local type=$1 id=$2
  case "$type" in
    qemu) qm config "$id" 2>/dev/null | sed -n 's/^tags:[[:space:]]*//p' | tr -d '\r' | tail -n1 ;;
    lxc)  pct config "$id" 2>/dev/null | sed -n 's/^tags:[[:space:]]*//p' | tr -d '\r' | tail -n1 ;;
  esac
}

# PVE 后端用分号保存 tags（get_unique_tags: split_list + lower + join(';')），
# 输入同时兼容逗号/分号/空白；这里统一小写、去重后用 ';' 输出，保证幂等且
# 不会丢掉用户已有 tags。
merge_tags() {
  local existing=$1 newtags=$2 prefix=$3 out="" t
  out=""
  while IFS= read -r t; do
    t=$(lower "$(trim "$t")")
    [ -z "$t" ] && continue
    case "$t" in
      "$prefix"*) continue ;;
    esac
    if ! is_valid_tag "$t"; then
      warn "忽略已有的非法 tag：$t"
      continue
    fi
    case ";${out};" in
      *";${t};"*) continue ;;
    esac
    out="${out:+${out};}${t}"
  done < <(printf '%s\n' "$existing" | tr ';,' '\n')
  while IFS= read -r t; do
    t=$(lower "$(trim "$t")")
    [ -z "$t" ] && continue
    if ! is_valid_tag "$t"; then
      err "待写入 tag 非法，已跳过：$t"
      continue
    fi
    case ";${out};" in
      *";${t};"*) continue ;;
    esac
    out="${out:+${out};}${t}"
  done < <(printf '%s\n' "$newtags" | tr ';,' '\n')
  printf '%s' "$out"
}

write_tags() {
  local type=$1 id=$2 tags=$3
  local -a cmd
  case "$type" in
    qemu) cmd=(qm set "$id") ;;
    lxc)  cmd=(pct set "$id") ;;
    *) return 1 ;;
  esac
  if [ -z "$tags" ]; then
    run "${cmd[@]}" --delete tags
  else
    run "${cmd[@]}" --tags "$tags"
  fi
}

set_ip_tag() {
  local type=$1 id=$2 ip=$3 existing merged newtag
  newtag="${TAG_PREFIX}${ip}"
  if ! is_valid_tag "$newtag"; then
    err "IP 标签非法：$newtag（检查 --tag-prefix，PVE tag 不允许冒号）"
    return 1
  fi
  existing=$(config_tags "$type" "$id")
  merged=$(merge_tags "$existing" "$newtag" "$TAG_PREFIX")
  if tags_equal "$existing" "$merged"; then
    info "tags 已是 ${newtag}，无需更新"
    return 0
  fi
  if write_tags "$type" "$id" "$merged"; then
    ok "IP 标签已更新：${merged}"
    return 0
  fi
  err "写入 tags 失败（VMID $id）。可用 qm config $id 检查 tags 字段"
  return 1
}

get_live_ips() {
  local type=$1 id=$2 out parsed
  out=""
  case "$type" in
    qemu)
      out=$(with_timeout 8 qm guest cmd "$id" network-get-interfaces 2>/dev/null) || out=""
      [ -n "$out" ] || return 0
      if [ "$JSON_OK" -eq 1 ]; then
        printf '%s\n' "$out" | jq -r '
          .[]? | select(type == "object")
          | (.name // "?") as $n
          | (.["ip-addresses"] // [])[]
          | select((.["ip-address-type"] // "") == "ipv4")
          | [$n, (.["ip-address"] // "")] | @tsv' 2>/dev/null
      else
        parsed=$(printf '%s\n' "$out" | awk '
          /"name"[ \t]*:/ { name = $0; sub(/.*"name"[ \t]*:[ \t]*"/, "", name); sub(/".*/, "", name); next }
          /"ip-address"[ \t]*:/ { ip = $0; sub(/.*"ip-address"[ \t]*:[ \t]*"/, "", ip); sub(/".*/, "", ip); next }
          /"ip-address-type"[ \t]*:/ {
            typ = $0; sub(/.*"ip-address-type"[ \t]*:[ \t]*"/, "", typ); sub(/".*/, "", typ);
            if (typ == "ipv4" && ip != "") { print name "\t" ip; ip = "" }
            next
          }')
        if [ -z "$parsed" ]; then
          parsed=$(printf '%s\n' "$out" \
            | grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' 2>/dev/null \
            | sed -e 's/.*"\([0-9.]*\)"$/\1/' \
            | awk '{ print "?\t" $0 }')
        fi
        printf '%s\n' "$parsed"
      fi
      ;;
    lxc)
      out=$(with_timeout 10 pct exec "$id" -- ip -4 -o addr show scope global 2>/dev/null) || out=""
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | awk '
          $3 == "inet" {
            iface = $2; sub(/:$/, "", iface)
            split($4, a, "/")
            if (a[1] != "") { print iface "\t" a[1] }
          }'
      else
        out=$(with_timeout 10 pct exec "$id" -- hostname -I 2>/dev/null) || out=""
        if [ -n "$out" ]; then
          for parsed in $out; do
            printf '?\t%s\n' "$parsed"
          done
        fi
      fi
      ;;
  esac
}

static_ips_from_config() {
  local type=$1 id=$2 cfg
  cfg=""
  case "$type" in
    qemu) cfg=$(qm config "$id" 2>/dev/null | sed -n 's/^ipconfig[0-9]*:[[:space:]]*//p') ;;
    lxc)  cfg=$(pct config "$id" 2>/dev/null | grep '^net[0-9]*:' 2>/dev/null) ;;
  esac
  [ -n "$cfg" ] || return 0
  printf '%s\n' "$cfg" \
    | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' 2>/dev/null \
    | sed -e 's/^ip=//' \
    | while IFS= read -r cidr; do
        printf 'config\t%s\n' "${cidr%%/*}"
      done
}

select_primary_ip() {
  local iface ip
  while IFS=$'\t' read -r iface ip; do
    [ -z "$ip" ] && continue
    is_valid_ipv4 "$ip" || continue
    case "$ip" in
      127.*|169.254.*|0.*) continue ;;
    esac
    if [ -n "$OPT_IFACE_EXCLUDE" ] && [[ "$iface" =~ $OPT_IFACE_EXCLUDE ]]; then
      continue
    fi
    if [ -n "$OPT_SUBNET" ] && ! [[ "$ip" =~ $OPT_SUBNET ]]; then
      continue
    fi
    printf '%s' "$ip"
    return 0
  done
  return 1
}

wait_and_tag_ip() {
  local type=$1 id=$2 timeout=$3 ip ips elapsed interval
  [ "$timeout" -le 0 ] && return 0
  interval="$WAIT_IP_INTERVAL"
  is_uint "$interval" || interval=5
  elapsed=0
  ip=""
  while [ "$elapsed" -lt "$timeout" ]; do
    ips=$(get_live_ips "$type" "$id")
    if ip=$(select_primary_ip <<< "$ips"); then
      [ -n "$ip" ] && break
    fi
    ip=""
    [ "$elapsed" -eq 0 ] && info "等待 $type $id 获取 IP（最多 ${timeout}s，Ctrl-C 跳过）..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  if [ -z "$ip" ]; then
    warn "在 ${timeout}s 内未获取到 IP（请检查 qemu-guest-agent / DHCP）"
    return 1
  fi
  ok "获取到 IP：$ip"
  set_ip_tag "$type" "$id" "$ip"
}

# ----------------------------- 创建结果 -----------------------------
print_create_result() {
  local mode=$1 ip
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上命令仅为打印，未实际执行（VMID ${VMID}）"
    return 0
  fi
  ip=$(config_tags qemu "$VMID" 2>/dev/null \
    | tr ',;' '\n' \
    | awk -v p="$TAG_PREFIX" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }')
  print_header "========================================"
  if [ "$mode" = "template" ]; then
    print_header "          云模板创建完成"
  else
    print_header "          虚拟机创建完成"
  fi
  print_header "========================================"
  info "VMID：${VMID}    名称：${VM_NAME}"
  info "发行版：${DISTRO_LABEL}    存储：${STORAGE}"
  info "CPU：${CORES} 核    内存：${MEM_MB} MB    磁盘：${DISK_GB}G"
  info "BIOS：${OPT_BIOS}（机型 ${OPT_MACHINE}）    QEMU Agent：启用"
  if [ "$mode" = "template" ]; then
    info "模板：可用 qm clone ${VMID} <新VMID> --full 创建虚拟机"
  else
    info "IP：${ip:-未获取到（可稍后运行 sync-tags 补写）}"
    info "默认登录：${CIUSER}${CIPASSWORD:+ / ${CIPASSWORD}}"
    warn "请立即修改默认密码！"
    info "控制台：qm terminal ${VMID}（退出 Ctrl-O）"
  fi
  print_header "========================================"
}

cleanup_failed_vm() {
  local id=$1 answer
  [ -n "$id" ] || return 0
  if [ "$DRY_RUN" -eq 1 ] || [ "$CREATED_BY_US" != "1" ]; then
    FAILED_VMID=""
    CREATED_BY_US=0
    return 0
  fi
  warn "创建失败，VMID $id 可能处于半成品状态"
  if [ "$ASSUME_YES" -eq 1 ]; then
    answer="y"
  elif interactive_stdin; then
    if ask_confirm "是否销毁半成品 VM $id 及其磁盘？" "n"; then answer="y"; else answer="n"; fi
  else
    answer="n"
  fi
  if [ "$answer" = "y" ]; then
    info "销毁 VMID $id ..."
    run qm stop "$id" >/dev/null 2>&1 || true
    if run qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1; then
      ok "已销毁 VMID $id"
    else
      err "销毁失败，请手动执行：qm stop $id; qm destroy $id --destroy-unreferenced-disks 1 --purge 1"
    fi
  else
    warn "已保留 VMID $id。手动清理：qm stop $id; qm destroy $id --destroy-unreferenced-disks 1 --purge 1"
  fi
  FAILED_VMID=""
  CREATED_BY_US=0
}

on_exit() {
  if [ -n "$FAILED_VMID" ]; then
    cleanup_failed_vm "$FAILED_VMID"
  fi
  if [ -n "${LOCK_HOLDER:-}" ]; then
    kill "$LOCK_HOLDER" 2>/dev/null || true
    wait "$LOCK_HOLDER" 2>/dev/null || true
    LOCK_HOLDER=""
  fi
  rm -f "${LOCK_FILE}.$$" 2>/dev/null || true
}

on_signal() {
  warn "收到中断信号"
  exit 130
}

create_common() {
  MODE="$1"
  case "$MODE" in
    vm) MODE_LABEL="虚拟机" ;;
    template) MODE_LABEL="云模板" ;;
    *) die "内部错误：未知创建模式 $MODE" ;;
  esac
  need_root
  require_cmds
  acquire_lock
  load_environment
  resolve_create_params || return 1
  preflight_create || return 1
  print_create_plan
  if [ "$INTERACTIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
    ask_confirm "确认按以上参数创建？" "Y" || { info "已取消"; return 1; }
  fi
  download_image "$DISTRO_PATH" || return 1
  FAILED_VMID=""
  CREATED_BY_US=0
  step_create_vm || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
  [ "$DRY_RUN" -eq 1 ] || FAILED_VMID="$VMID"
  step_import_disk || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
  step_configure_vm || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
  if [ "$MODE" = "template" ]; then
    run_step "转换为模板" qm template "$VMID" || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
  elif [ "$OPT_NO_START" -eq 0 ]; then
    run_step "启动虚拟机" qm start "$VMID" || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
    FAILED_VMID=""
    if [ "$OPT_NO_TAGS" -eq 0 ]; then
      if [ -n "$OPT_STATIC_IP" ]; then
        # 静态 IP 已明确配置，无需等待 guest agent，直接按配置写标签
        info "使用配置的静态 IP 写入标签：${OPT_STATIC_IP%%/*}"
        set_ip_tag qemu "$VMID" "${OPT_STATIC_IP%%/*}"
      else
        wait_and_tag_ip qemu "$VMID" "$OPT_WAIT_IP"
      fi
    fi
  fi
  FAILED_VMID=""
  CREATED_BY_US=0
  print_create_result "$MODE"
  return 0
}

# ----------------------------- 克隆 -----------------------------
list_templates() {
  local rows vmid type status tpl name
  rows=""
  [ -n "$CLUSTER_ROWS" ] || return 0
  while IFS=$'\t' read -r vmid type status tpl name; do
    [ -z "$vmid" ] && continue
    [ "$type" = "qemu" ] || continue
    if [ "$tpl" = "1" ]; then
      rows="${rows}${vmid} ${name}"$'\n'
    elif is_template_id qemu "$vmid"; then
      rows="${rows}${vmid} ${name}"$'\n'
    fi
  done <<< "$CLUSTER_ROWS"
  printf '%s' "$rows"
}

print_clone_plan() {
  print_header "----------- 克隆参数确认 -----------"
  info "来源模板：VMID ${TPL_ID}（${TPL_NAME}）"
  info "新 VMID：${VMID}    名称：${VM_NAME}"
  info "克隆方式：$([ "$OPT_FULL_CLONE" -eq 1 ] && printf '完整克隆' || printf '链接克隆（linked clone）')"
  if [ "$OPT_FULL_CLONE" -eq 1 ] && [ -n "$OPT_STORAGE" ]; then
    info "目标存储：${OPT_STORAGE}"
  fi
  if [ "$OPT_NO_START" -eq 1 ]; then
    info "启动：克隆后不启动"
  else
    info "启动：克隆后启动并等待 IP"
  fi
  print_header "------------------------------------"
  return 0
}

build_clone_description() {
  cat <<EOF
# 克隆虚拟机

- 克隆时间：$(date '+%F %T')
- 来源模板：VMID ${TPL_ID}（${TPL_NAME}）
- 创建工具：${SCRIPT_NAME} v${SCRIPT_VERSION}
- IP 标签：tags 中的 ${TAG_PREFIX}<ip>（同步时会保留其他 tags）

⚠️ 首次登录后请立即修改模板继承的默认密码。
EOF
}

print_clone_result() {
  local ip
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上命令仅为打印，未实际执行（VMID ${VMID}）"
    return 0
  fi
  ip=$(config_tags qemu "$VMID" 2>/dev/null \
    | tr ',;' '\n' \
    | awk -v p="$TAG_PREFIX" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }')
  print_header "========================================"
  print_header "          克隆完成"
  print_header "========================================"
  info "VMID：${VMID}    名称：${VM_NAME}"
  info "来源模板：${TPL_ID}（${TPL_NAME}）"
  info "IP：${ip:-未获取到（可运行 sync-tags 补写）}"
  info "控制台：qm terminal ${VMID}（退出 Ctrl-O）"
  print_header "========================================"
}

clone_cmd() {
  need_root
  require_cmds
  acquire_lock
  load_environment
  INTERACTIVE=0
  interactive_stdin && INTERACTIVE=1
  if [ "$INTERACTIVE" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    die "检测到非交互环境：请加 --yes 并指定 --template/--vmid 等参数"
  fi
  clear_screen
  print_header "========================================"
  print_header "          从模板克隆虚拟机"
  print_header "========================================"

  local templates tpl_line found def
  templates=$(list_templates)
  if [ -z "$templates" ]; then
    die "未发现可用模板，请先使用 template 命令创建云模板"
  fi
  if [ -n "$OPT_TEMPLATE_ID" ]; then
    found=$(printf '%s\n' "$templates" | awk -v id="$OPT_TEMPLATE_ID" '$1 == id { print; exit }')
    [ -n "$found" ] || die "VMID $OPT_TEMPLATE_ID 不是模板或不存在"
    TPL_ID="$OPT_TEMPLATE_ID"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    local -a opts
    opts=()
    while IFS= read -r tpl_line; do
      [ -n "$tpl_line" ] && opts+=("$tpl_line")
    done <<< "$templates"
    choose_one "请选择模板：" "${opts[@]}"
    TPL_ID=${REPLY%% *}
  else
    die "非交互模式必须指定 --template <模板VMID>"
  fi
  is_uint "$TPL_ID" || die "模板 VMID 无效：$TPL_ID"

  TPL_NAME=$(cluster_row "$TPL_ID" | awk -F'\t' '{ print $5 }' 2>/dev/null || printf '')
  [ -n "$TPL_NAME" ] || TPL_NAME="template-${TPL_ID}"

  if [ -n "$OPT_VMID" ]; then
    validate_vmid_arg "$OPT_VMID"
    vmid_in_use "$OPT_VMID" && die "VMID $OPT_VMID 已被占用"
    VMID="$OPT_VMID"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    def=$(next_free_vmid)
    while true; do
      ask_value "请输入新 VMID" "$def" '^[0-9]+$' "VMID 必须是数字"
      validate_vmid_arg "$REPLY"
      vmid_in_use "$REPLY" && { err "VMID $REPLY 已被占用"; continue; }
      VMID="$REPLY"
      break
    done
  else
    VMID=$(next_free_vmid)
  fi

  if [ -n "$OPT_NAME" ]; then
    VM_NAME="$OPT_NAME"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    ask_value "请输入新虚拟机名称" "$(sanitize_vm_name "${TPL_NAME}-clone")" '^[A-Za-z0-9][A-Za-z0-9._-]*$' "名称非法"
    VM_NAME="$REPLY"
  else
    VM_NAME=$(sanitize_vm_name "${TPL_NAME}-clone")
  fi
  validate_vm_name "$VM_NAME" || die "虚拟机名称非法：$VM_NAME"

  if [ -n "$OPT_STORAGE" ] && [ "$OPT_FULL_CLONE" -eq 1 ]; then
    storage_exists "$OPT_STORAGE" || warn "存储 $OPT_STORAGE 未在存储列表中找到"
  fi

  print_clone_plan
  if [ "$INTERACTIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
    ask_confirm "确认克隆？" "Y" || { info "已取消"; return 1; }
  fi

  local -a cargs
  cargs=(qm clone "$TPL_ID" "$VMID" --name "$VM_NAME")
  if [ "$OPT_FULL_CLONE" -eq 1 ]; then
    cargs+=(--full)
    [ -n "$OPT_STORAGE" ] && cargs+=(--storage "$OPT_STORAGE")
  fi
  FAILED_VMID=""
  CREATED_BY_US=0
  if ! run "${cargs[@]}"; then
    err "qm clone 失败"
    if [ "$OPT_FULL_CLONE" -eq 0 ]; then
      err "链接克隆要求模板所在存储支持 linked clone（如 lvmthin/zfspool/rbd）；否则请加 --full 完整克隆"
    fi
    return 1
  fi
  [ "$DRY_RUN" -eq 1 ] || CREATED_BY_US=1
  [ "$DRY_RUN" -eq 1 ] || FAILED_VMID="$VMID"

  if [ "$OPT_NO_DESCRIPTION" -eq 0 ]; then
    local desc
    desc=$(build_clone_description)
    run_step "写入描述" qm set "$VMID" --description "$desc" \
      || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
  fi

  if [ "$OPT_NO_START" -eq 0 ]; then
    run_step "启动虚拟机" qm start "$VMID" \
      || { FAILED_VMID="$VMID"; cleanup_failed_vm "$VMID"; return 1; }
    FAILED_VMID=""
    if [ "$OPT_NO_TAGS" -eq 0 ]; then
      [ -z "$OPT_WAIT_IP" ] && OPT_WAIT_IP="$DEFAULT_WAIT_IP"
      wait_and_tag_ip qemu "$VMID" "$OPT_WAIT_IP"
    fi
  fi
  FAILED_VMID=""
  CREATED_BY_US=0
  print_clone_result
  return 0
}

# ----------------------------- 同步 tags -----------------------------
sync_tags_cmd() {
  need_root
  require_cmds
  acquire_lock
  load_environment
  clear_screen
  print_header "========================================"
  print_header "          同步 VM/LXC 的 IP 标签"
  print_header "========================================"
  if [ -z "$CLUSTER_ROWS" ]; then
    warn "未发现任何虚拟机或容器"
    return 0
  fi
  local total=0 updated=0 unchanged=0 skipped=0 failed=0
  local vmid type status tpl name cfg tags static_ips ips ip newtag merged
  local exclude_list=""
  if [ -n "$OPT_SYNC_EXCLUDE" ]; then
    exclude_list=",${OPT_SYNC_EXCLUDE// /,},"
  fi
  while IFS=$'\t' read -r vmid type status tpl name; do
    [ -z "$vmid" ] && continue
    total=$((total + 1))
    if [ -n "$exclude_list" ]; then
      case "$exclude_list" in
        *",${vmid},"*)
          info "$vmid（${name}）：在 --exclude 列表中，跳过"
          skipped=$((skipped + 1))
          continue
          ;;
      esac
    fi
    case "$type" in
      qemu) cfg=$(qm config "$vmid" 2>/dev/null) || cfg="" ;;
      lxc)  cfg=$(pct config "$vmid" 2>/dev/null) || cfg="" ;;
      *)    cfg="" ;;
    esac
    if [ -z "$cfg" ]; then
      warn "$vmid（${name:-未知}）：读取配置失败，跳过"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$tpl" != "1" ]; then
      tpl=$(printf '%s\n' "$cfg" | sed -n 's/^template:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
    fi
    if [ "$tpl" = "1" ]; then
      info "$vmid（${name}）：模板，跳过"
      skipped=$((skipped + 1))
      continue
    fi
    tags=$(printf '%s\n' "$cfg" | sed -n 's/^tags:[[:space:]]*//p' | tr -d '\r' | tail -n1)
    ips=""
    if [ "$status" != "stopped" ]; then
      ips=$(get_live_ips "$type" "$vmid")
    fi
    if [ -z "$ips" ]; then
      static_ips=$(static_ips_from_config "$type" "$vmid")
      if [ -n "$static_ips" ]; then
        ips="$static_ips"
        [ "$status" = "running" ] || debug "$vmid：使用静态配置 IP（$status）"
      fi
    fi
    if [ -z "$ips" ]; then
      info "$vmid（${name}）：无可用 IP（${status}），跳过"
      skipped=$((skipped + 1))
      continue
    fi
    ip=""
    if ! ip=$(select_primary_ip <<< "$ips"); then
      warn "$vmid（${name}）：IP 被过滤规则排除，跳过"
      skipped=$((skipped + 1))
      continue
    fi
    newtag="${TAG_PREFIX}${ip}"
    if ! is_valid_tag "$newtag"; then
      err "$vmid：IP 标签非法：$newtag（检查 --tag-prefix）"
      failed=$((failed + 1))
      continue
    fi
    merged=$(merge_tags "$tags" "$newtag" "$TAG_PREFIX")
    if tags_equal "$tags" "$merged"; then
      info "$vmid（${name}）：${newtag} 已存在"
      unchanged=$((unchanged + 1))
      continue
    fi
    if write_tags "$type" "$vmid" "$merged"; then
      ok "$vmid（${name}）：获取到 IP：${ip}，IP 标签已更新：${merged}"
      updated=$((updated + 1))
    else
      err "$vmid（${name}）：写入 tags 失败"
      failed=$((failed + 1))
    fi
  done <<< "$CLUSTER_ROWS"

  print_header "----------------------------------------"
  info "共 ${total} 个对象：更新 ${updated}，已是最新 ${unchanged}，跳过 ${skipped}，失败 ${failed}"
  [ "$DRY_RUN" -eq 1 ] && info "（dry-run：以上仅为计划，未写入）"
  [ "$failed" -gt 0 ] && return 1
  return 0
}

# ----------------------------- 清理缓存 -----------------------------
clear_cache_cmd() {
  need_root
  acquire_lock
  clear_screen
  print_header "========================================"
  print_header "          清理镜像缓存"
  print_header "========================================"
  if [ ! -d "$CACHE_DIR" ]; then
    ok "缓存目录不存在，无需清理：$CACHE_DIR"
    return 0
  fi
  local -a files
  files=()
  local f total=0 size
  for f in "$CACHE_DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.qcow2|*.img|*.part) files+=("$f") ;;
    esac
  done
  if [ "${#files[@]}" -eq 0 ]; then
    ok "缓存目录为空：$CACHE_DIR"
    return 0
  fi
  info "缓存目录：$CACHE_DIR"
  for f in "${files[@]}"; do
    size=$(file_size "$f")
    total=$((total + size))
    info "  $(basename "$f")（$(format_size "$size")）"
  done
  info "合计：$(format_size "$total")"
  if [ "$ASSUME_YES" -eq 0 ]; then
    if ! interactive_stdin; then
      die "非交互环境清理缓存需要加 --yes"
    fi
    ask_confirm "确定删除以上缓存文件？" "n" || { info "已取消"; return 0; }
  fi
  for f in "${files[@]}"; do
    if [ "$DRY_RUN" -eq 1 ]; then
      run rm -f -- "$f"
    else
      rm -f -- "$f" || { err "删除失败：$f"; return 1; }
    fi
  done
  ok "缓存清理完成"
  return 0
}

# ----------------------------- 自检 -----------------------------
doctor_cmd() {
  local fails=0 warns=0
  doctor_ok()   { ok   "  ✔ $*"; }
  doctor_warn() { warn "  ! $*"; warns=$((warns + 1)); }
  doctor_fail() { err  "  ✘ $*"; fails=$((fails + 1)); }

  print_header "========================================"
  print_header "          环境自检"
  print_header "========================================"
  if [ "$(id -u)" -eq 0 ]; then doctor_ok "以 root 运行"; else doctor_fail "未以 root 运行"; fi
  doctor_ok "bash ${BASH_VERSION}"

  detect_json
  detect_node
  detect_pve_version
  if [ "$PVE_RELEASE" != "unknown" ]; then doctor_ok "PVE 版本：${PVE_RELEASE}，节点：${NODE}"; else doctor_warn "无法识别 PVE 版本（非 PVE 环境？）"; fi

  local c
  for c in qm pct pvesm; do
    if have "$c"; then doctor_ok "命令存在：$c"; else doctor_fail "缺少命令：$c"; fi
  done
  for c in pvesh jq qemu-img wget curl flock timeout sha256sum; do
    if have "$c"; then doctor_ok "命令存在：$c"; else doctor_warn "缺少可选命令：$c"; fi
  done

  if [ "$JSON_OK" -eq 1 ]; then doctor_ok "jq 可用（JSON 解析）"; else doctor_warn "未安装 jq，将使用兼容解析（建议 apt install jq）"; fi

  load_storages
  if [ "${#IMAGES_STORAGES[@]}" -gt 0 ]; then
    doctor_ok "支持 images 的存储：$(printf '%s ' "${IMAGES_STORAGES[@]}")"
  else
    doctor_warn "未发现支持 images 的存储"
  fi
  load_bridges
  doctor_ok "网桥：$(printf '%s ' "${BRIDGES[@]}")"

  if [ -d "$CACHE_DIR" ]; then
    if [ -w "$CACHE_DIR" ]; then doctor_ok "缓存目录可写：$CACHE_DIR"; else doctor_fail "缓存目录不可写：$CACHE_DIR"; fi
  else
    local parent
    parent=$(dirname "$CACHE_DIR")
    if [ -w "$parent" ]; then doctor_ok "缓存目录将创建于可写父目录：$parent"; else doctor_fail "缓存目录父目录不可写：$parent"; fi
  fi
  if [ -n "$LOG_FILE" ]; then
    if [ -w "$LOG_FILE" ] || [ -w "$(dirname "$LOG_FILE")" ]; then doctor_ok "日志文件可写：$LOG_FILE"; else doctor_warn "日志文件不可写：$LOG_FILE"; fi
  fi
  if [ -e "$LOCK_FILE" ] && [ ! -w "$LOCK_FILE" ]; then
    doctor_warn "锁文件不可写：$LOCK_FILE"
  fi

  print_header "----------------------------------------"
  if [ "$fails" -gt 0 ]; then
    err "自检完成：${fails} 项失败，${warns} 项警告"
    return 1
  fi
  ok "自检完成：0 项失败，${warns} 项警告"
  return 0
}

# ----------------------------- 帮助 / 入口 -----------------------------
usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Proxmox VE 云模板 / 虚拟机 / IP 标签管理

用法：
  ${SCRIPT_NAME} [命令] [选项]        无命令且为交互终端时显示菜单

命令：
  create          创建虚拟机（默认启动，可选写 IP 标签）
  template        创建云模板（不启动；之后可用 clone 克隆）
  clone           从模板克隆虚拟机
  sync-tags       扫描所有 VM/LXC，把局域网 IP 写入 tags（保留其他 tags）
  clear-cache     清理镜像缓存
  doctor          环境自检
  list-distros    列出预置发行版及镜像地址
  menu            显示交互菜单
  version         显示版本
  help            显示本帮助

通用选项：
  -y, --yes            非交互确认（清缓存、销毁半成品等不再询问）
  -n, --dry-run        只打印将执行的命令，不实际修改
      --no-color       禁用彩色输出
  -v, --verbose        输出调试信息
      --log FILE       日志文件（默认 ${LOG_FILE}；传空字符串禁用）
      --cache-dir DIR  镜像缓存目录（默认 ${CACHE_DIR}）

创建/模板选项：
      --distro NAME|ID     发行版名称或序号（见 --list-distros）
      --vmid ID            指定 VMID（默认自动分配）
      --name NAME          虚拟机名称（默认取发行版名）
      --bridge BRIDGE      网络桥接（默认第一个网桥）
      --storage STORAGE    存储（默认第一个支持 images 的存储）
      --cores N            CPU 核心数（默认 2）
      --memory SIZE        内存，如 2G / 2048M（默认 2G）
      --disk SIZE          磁盘，如 20G（默认 20G）
      --bios ovmf|seabios  固件（默认 ovmf；ovmf 需要 efidisk）
      --machine q35|pc     机型（默认 q35）
      --secureboot         启用 UEFI Secure Boot（pre-enrolled-keys=1）
      --ciuser USER        Cloud-Init 用户（官方 Debian 默认 debian，其余默认 root）
      --cipassword PASS    Cloud-Init 密码（默认 oneclickvirt；指定 --sshkeys 时默认不设密码）
      --sshkeys FILE       SSH 公钥文件（建议生产使用）
      --static-ip CIDR     静态 IP，如 10.0.0.50/24（默认 DHCP）
      --gateway IP         静态 IP 网关
      --nameserver DNS     自定义 DNS（逗号分隔）
      --no-ipv6            不启用 IPv6 DHCP
      --import-format F    auto|raw|qcow2|vmdk（默认按存储类型自动选择）
      --sha256 HASH        校验下载镜像的 SHA256
      --subnet REGEX       只采纳匹配该正则的 IPv4（如 '^10\.'）
      --iface-exclude RE   忽略匹配该正则的网卡名（默认忽略 lo/docker/veth 等）
      --tag-prefix PREFIX  IP 标签前缀（默认 ip-，PVE tag 不允许冒号）
      --vm-tags TAGS       创建时附加的 tags（逗号或分号分隔，会小写化）
      --no-tags            创建后不写 IP 标签
      --description TEXT   自定义描述（覆盖默认说明）
      --no-description     不写描述
      --onboot             设置开机自启
      --no-start           创建后不启动
      --wait-ip SECONDS    等待 IP 秒数（默认 180，0 表示不等待）
      --skip-space-check   跳过磁盘空间提示

克隆选项：
      --template ID        模板 VMID（非交互必填）
      --vmid ID            新 VMID
      --name NAME          新虚拟机名称
      --full               完整克隆（默认链接克隆）
      --storage STORAGE    完整克隆的目标存储
      --no-start           克隆后不启动
      --wait-ip SECONDS    等待 IP 秒数

同步选项（sync-tags）：
      --exclude IDS        跳过指定 VMID/CTID（逗号或空格分隔），避免改动现有生产 VM

示例：
  ${SCRIPT_NAME} create --distro Debian-12 --vmid 8000
  ${SCRIPT_NAME} template --distro Debian-12 --vmid 9000 --yes
  ${SCRIPT_NAME} create --distro 1 --memory 4G --disk 40G --static-ip 10.0.0.50/24 --gateway 10.0.0.1
  ${SCRIPT_NAME} clone --template 9000 --vmid 8001 --name web-01 --wait-ip 120
  ${SCRIPT_NAME} sync-tags
  ${SCRIPT_NAME} clear-cache --yes
  ${SCRIPT_NAME} doctor
  ${SCRIPT_NAME} list-distros

注意：
  * PVE tag 只允许字母、数字、_、-、.、+，因此 IP 标签格式为 ip-10.0.0.5（不是 IP:10.0.0.5）。
  * 默认密码 oneclickvirt 仅用于首次登录，生产环境请使用 --sshkeys 或登录后立即修改。
  * 创建 UEFI 模板时默认不启用 Secure Boot（pre-enrolled-keys=0），第三方镜像兼容性更好；
    需要 Secure Boot 时加 --secureboot。
EOF
}

parse_cli() {
  local create_opt_used=0 clone_opt_used=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) COMMAND="help"; shift ;;
      --version|-V) COMMAND="version"; shift ;;
      --list-distros) COMMAND="list-distros"; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run|-n) DRY_RUN=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      --verbose|-v) VERBOSE=1; shift ;;
      --log) [ $# -ge 2 ] || die "--log 需要参数"; LOG_FILE="$2"; shift 2 ;;
      --cache-dir) [ $# -ge 2 ] || die "--cache-dir 需要参数"; CACHE_DIR="$2"; shift 2 ;;
      --distro) [ $# -ge 2 ] || die "--distro 需要参数"; OPT_DISTRO="$2"; create_opt_used=1; shift 2 ;;
      --vmid) [ $# -ge 2 ] || die "--vmid 需要参数"; OPT_VMID="$2"; create_opt_used=1; shift 2 ;;
      --name) [ $# -ge 2 ] || die "--name 需要参数"; OPT_NAME="$2"; create_opt_used=1; shift 2 ;;
      --bridge) [ $# -ge 2 ] || die "--bridge 需要参数"; OPT_BRIDGE="$2"; create_opt_used=1; shift 2 ;;
      --storage) [ $# -ge 2 ] || die "--storage 需要参数"; OPT_STORAGE="$2"; create_opt_used=1; shift 2 ;;
      --cores) [ $# -ge 2 ] || die "--cores 需要参数"; OPT_CORES="$2"; create_opt_used=1; shift 2 ;;
      --memory) [ $# -ge 2 ] || die "--memory 需要参数"; OPT_MEMORY="$2"; create_opt_used=1; shift 2 ;;
      --disk) [ $# -ge 2 ] || die "--disk 需要参数"; OPT_DISK="$2"; create_opt_used=1; shift 2 ;;
      --bios) [ $# -ge 2 ] || die "--bios 需要参数"; OPT_BIOS="$2"; create_opt_used=1; shift 2 ;;
      --machine) [ $# -ge 2 ] || die "--machine 需要参数"; OPT_MACHINE="$2"; create_opt_used=1; shift 2 ;;
      --secureboot) OPT_SECUREBOOT=1; create_opt_used=1; shift ;;
      --ciuser) [ $# -ge 2 ] || die "--ciuser 需要参数"; OPT_CIUSER="$2"; create_opt_used=1; shift 2 ;;
      --cipassword) [ $# -ge 2 ] || die "--cipassword 需要参数"; OPT_CIPASSWORD="$2"; create_opt_used=1; shift 2 ;;
      --sshkeys) [ $# -ge 2 ] || die "--sshkeys 需要参数"; OPT_SSHKEYS="$2"; create_opt_used=1; shift 2 ;;
      --static-ip) [ $# -ge 2 ] || die "--static-ip 需要参数"; OPT_STATIC_IP="$2"; create_opt_used=1; shift 2 ;;
      --gateway) [ $# -ge 2 ] || die "--gateway 需要参数"; OPT_GATEWAY="$2"; create_opt_used=1; shift 2 ;;
      --nameserver) [ $# -ge 2 ] || die "--nameserver 需要参数"; OPT_NAMESERVER="$2"; create_opt_used=1; shift 2 ;;
      --no-ipv6) OPT_IPV6=0; create_opt_used=1; shift ;;
      --import-format) [ $# -ge 2 ] || die "--import-format 需要参数"; OPT_IMPORT_FORMAT="$2"; create_opt_used=1; shift 2 ;;
      --sha256) [ $# -ge 2 ] || die "--sha256 需要参数"; OPT_SHA256="$2"; create_opt_used=1; shift 2 ;;
      --subnet) [ $# -ge 2 ] || die "--subnet 需要参数"; OPT_SUBNET="$2"; create_opt_used=1; shift 2 ;;
      --iface-exclude) [ $# -ge 2 ] || die "--iface-exclude 需要参数"; OPT_IFACE_EXCLUDE="$2"; create_opt_used=1; shift 2 ;;
      --tag-prefix) [ $# -ge 2 ] || die "--tag-prefix 需要参数"; TAG_PREFIX="$2"; create_opt_used=1; shift 2 ;;
      --vm-tags) [ $# -ge 2 ] || die "--vm-tags 需要参数"; OPT_VM_TAGS="$2"; create_opt_used=1; shift 2 ;;
      --description) [ $# -ge 2 ] || die "--description 需要参数"; OPT_DESCRIPTION="$2"; create_opt_used=1; shift 2 ;;
      --no-description) OPT_NO_DESCRIPTION=1; create_opt_used=1; shift ;;
      --no-tags) OPT_NO_TAGS=1; create_opt_used=1; shift ;;
      --onboot) OPT_ONBOOT=1; create_opt_used=1; shift ;;
      --no-start) OPT_NO_START=1; create_opt_used=1; shift ;;
      --wait-ip) [ $# -ge 2 ] || die "--wait-ip 需要参数"; OPT_WAIT_IP="$2"; create_opt_used=1; shift 2 ;;
      --skip-space-check) OPT_SKIP_SPACE=1; create_opt_used=1; shift ;;
      --template) [ $# -ge 2 ] || die "--template 需要参数"; OPT_TEMPLATE_ID="$2"; clone_opt_used=1; shift 2 ;;
      --full) OPT_FULL_CLONE=1; clone_opt_used=1; shift ;;
      --exclude) [ $# -ge 2 ] || die "--exclude 需要参数"; OPT_SYNC_EXCLUDE="$2"; shift 2 ;;
      --) shift; break ;;
      -*) usage >&2; die "未知选项：$1" ;;
      *)
        if [ -z "$COMMAND" ]; then
          COMMAND="$1"
        else
          usage >&2
          die "多余参数：$1"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$COMMAND" ]; then
    if [ "$clone_opt_used" -eq 1 ]; then
      COMMAND="clone"
    elif [ "$create_opt_used" -eq 1 ]; then
      COMMAND="create"
    elif [ -t 0 ]; then
      COMMAND="menu"
    else
      usage >&2
      die "非交互环境请指定命令（create/template/clone/sync-tags/clear-cache/doctor）"
    fi
  fi
}

interactive_menu() {
  INTERACTIVE=1
  local opt
  while true; do
    clear_screen
    print_header "========================================"
    print_header "          PVE 一体化管理脚本 v${SCRIPT_VERSION}"
    print_header "========================================"
    printf '  1) 创建虚拟机（q35+UEFI+QEMU Agent，启动并写 IP 标签）\n' >&2
    printf '  2) 创建云模板（不启动，之后可克隆）\n' >&2
    printf '  3) 从模板克隆虚拟机\n' >&2
    printf '  4) 同步 VM/LXC 的 IP 标签（保留其他 tags）\n' >&2
    printf '  5) 清理镜像缓存\n' >&2
    printf '  6) 环境自检\n' >&2
    printf '  0) 退出\n' >&2
    printf '\n请选择操作 [0-6]: ' >&2
    if ! read -r opt; then
      exit 0
    fi
    opt=$(trim "$opt")
    case "$opt" in
      1) create_common vm ;;
      2) create_common template ;;
      3) clone_cmd ;;
      4) sync_tags_cmd ;;
      5) clear_cache_cmd ;;
      6) doctor_cmd ;;
      0|q|Q) info "再见！"; exit 0 ;;
      *) err "无效选择，请输入 0-6"; sleep 1 ;;
    esac
    pause_return
  done
}

main() {
  setup_colors
  init_log
  parse_cli "$@"
  init_log
  TAG_PREFIX=$(lower "$TAG_PREFIX")
  is_valid_tag "$TAG_PREFIX" || die "--tag-prefix 非法：${TAG_PREFIX}（需符合 PVE tag 字符集，不能含冒号/空格）"
  setup_colors
  case "$COMMAND" in
    help) usage; exit 0 ;;
    version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
    list-distros) list_distros; exit 0 ;;
    menu) need_root; interactive_menu ;;
    create) create_common vm ;;
    template) create_common template ;;
    clone) clone_cmd ;;
    sync-tags) sync_tags_cmd ;;
    clear-cache) clear_cache_cmd ;;
    doctor) doctor_cmd ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

trap on_exit EXIT
trap on_signal INT TERM

main "$@"
