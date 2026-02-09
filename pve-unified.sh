#!/bin/bash
set -o pipefail

# 全局配置
MIRROR_BASE="https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/"
DEBIAN_OFFICIAL_BASE="https://cloud.debian.org/images/cloud/"
CACHE_DIR="/var/cache/pve-unified-images"
FAILED_VMID=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# 日志函数
log_info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok(){   echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err(){  echo -e "${RED}[ERR]${NC}  $*"; }

# -------------------- 系统资源识别函数 --------------------
get_all_vmids() {
  local vids=$(sudo qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tr '\n' ' ')
  [ -z "$vids" ] && vids="无"
  echo "$vids"
}

get_all_vmbrs() {
  local vmbrs=()
  if command -v jq &>/dev/null; then
    vmbrs=($(ip -j link show type bridge | jq -r '.[].ifname' | grep -v -E "^lo$|^fwbr" | grep -v "^$"))
  fi
  if [ ${#vmbrs[@]} -eq 0 ]; then
    while IFS= read -r dev; do
      if [ "$dev" != "lo" ] && [[ ! "$dev" =~ ^fwbr ]] && ip link show "$dev" type bridge 2>/dev/null; then
        vmbrs+=("$dev")
      fi
    done < <(ip link show | awk '/^[0-9]+: / {gsub(/:/, "", $2); print $2}' | grep -v -E "^lo$|^fwbr")
  fi
  vmbrs=($(printf "%s\n" "${vmbrs[@]}" | sort -u | grep -v -E "^$|^fwbr"))
  [ ${#vmbrs[@]} -eq 0 ] && vmbrs=("vmbr0")
  printf "%s\n" "${vmbrs[@]}"
}

get_all_storages() {
  local storages=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^([a-zA-Z0-9_-]+)\ + ]]; then
      local storage="${BASH_REMATCH[1]}"
      if sudo pvesm status | grep -q "^$storage\s"; then
        storages+=("$storage")
      fi
    fi
  done < <(sudo pvesm status 2>/dev/null | tail -n +2)
  [ ${#storages[@]} -eq 0 ] && storages=("local" "local-lvm")
  printf "%s\n" "${storages[@]}"
}

auto_assign_vmid() {
  local used_vids=($(sudo qm list 2>/dev/null | awk 'NR>1 {print $1}'))
  local new_vid=100
  while [[ " ${used_vids[@]} " =~ " $new_vid " ]]; do
    new_vid=$((new_vid + 1))
    [ $new_vid -gt 999 ] && { new_vid=8000; break; }
  done
  while [[ " ${used_vids[@]} " =~ " $new_vid " ]]; do
    new_vid=$((new_vid + 1))
  done
  echo "$new_vid"
}

check_vmid_conflict() {
  local vmid=$1
  local used_vids=($(sudo qm list 2>/dev/null | awk 'NR>1 {print $1}'))
  [[ " ${used_vids[@]} " =~ " $vmid " ]] && return 0 || return 1
}

# -------------------- 核心菜单函数 --------------------
num_menu_select() {
  local title="$1"
  local options=()
  local num_options=0
  local input=""
  while IFS= read -r line; do 
    [ -z "$line" ] && continue; 
    options+=("$line"); 
  done < <(echo "$2")
  num_options=${#options[@]}
  [ $num_options -eq 0 ] && { log_err "❌ 无可用选项"; exit 1; }
  if [ $num_options -eq 1 ]; then
    local selected="${options[0]}"
    echo -e "\n✅ 仅检测到1个可选选项，自动选中：${BOLD}$selected${NC}\n"
    selected=$(echo "$selected" | tr -d '[:space:]')
    echo "$selected"
    return 0
  fi
  while true; do
    read -rp "请输入选择的序号 (1-$num_options)：" input
    input=$(echo "$input" | xargs)
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$num_options" ]; then
      local selected="${options[$((input-1))]}"
      selected=$(echo "$selected" | tr -d '[:space:]')
      echo "$selected"
      return 0
    else
      log_err "❌ 输入无效，请输 1-$num_options 之间的数字"
    fi
  done
}

custom_input() {
  local prompt="$1"
  local validate_regex="$2"
  local error_msg="$3"
  local input=""
  while true; do
    read -rp "$prompt" input
    input=$(echo "$input" | xargs)
    [ -z "$input" ] && { log_err "❌ 输入不能为空"; continue; }
    if [[ $input =~ $validate_regex ]]; then
      echo "$input"
      return 0
    else
      log_err "❌ $error_msg"
      echo "💡 示例：$3"
    fi
  done
}

# -------------------- 失败清理 --------------------
cleanup_failed_vm(){
  local id="$1"
  [ -z "$id" ] && return 1
  if [ -f "/etc/pve/qemu-server/$id.conf" ]; then
    log_info "停止失败的 VMID $id ..."
    sudo qm stop "$id" 2>/dev/null || log_warn "停止失败（虚拟机未运行）"
    log_info "销毁失败的 VMID $id 并清理磁盘..."
    if sudo qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1; then
      log_ok "成功销毁 VMID: $id"
    else
      log_err "销毁失败，请手动执行：sudo qm destroy $id --destroy-unreferenced-disks 1 --purge 1"
    fi
  else
    log_info "VMID $id 无配置文件，无需清理"
  fi
}

cleanup(){
  [ -n "$FAILED_VMID" ] && {
    log_warn "检测到失败的虚拟机 VMID: $FAILED_VMID"
    log_warn "开始自动清理..."
    cleanup_failed_vm "$FAILED_VMID"
    FAILED_VMID=""
  }
}
trap cleanup EXIT

# -------------------- 发行版定义 --------------------
DISTRO_LIST=(
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

get_distro_path() {
  local distro_name="$1"
  case "$distro_name" in
    Debian-11) echo "debian/debian11.qcow2" ;;
    Debian-11-Official-Generic) echo "${DEBIAN_OFFICIAL_BASE}bullseye/latest/debian-11-genericcloud-amd64.qcow2" ;;
    Debian-12) echo "debian/debian12.qcow2" ;;
    Debian-12-Official-Generic) echo "${DEBIAN_OFFICIAL_BASE}bookworm/latest/debian-12-genericcloud-amd64.qcow2" ;;
    Debian-13) echo "debian/debian13.qcow2" ;;
    Debian-13-Official-Generic) echo "${DEBIAN_OFFICIAL_BASE}trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
    Ubuntu-18.04) echo "ubuntu/ubuntu1804.qcow2" ;;
    Ubuntu-20.04) echo "ubuntu/ubuntu2004.qcow2" ;;
    Ubuntu-22.04) echo "ubuntu/ubuntu2204.qcow2" ;;
    Ubuntu-24.04) echo "ubuntu/ubuntu2404.qcow2" ;;
    CentOS-8) echo "centos/centos8.qcow2" ;;
    CentOS-9) echo "centos/centos9.qcow2" ;;
    *) log_err "未找到该系统的镜像路径"; exit 1 ;;
  esac
}

get_distro_source() {
  local distro_name="$1"
  if [[ "$distro_name" == *-Official-Generic ]]; then
    echo "official"
  else
    echo "thirdparty"
  fi
}

# -------------------- 参数配置 --------------------
prompt_vm_params() {
  clear
  echo -e "${BOLD}========================================"
  echo -e "          PVE 虚拟机参数配置"
  echo -e "========================================${NC}\n"

  log_info "📊 系统资源识别结果："
  local used_vids=$(get_all_vmids)
  local vmbrs=$(get_all_vmbrs)
  local storages=$(get_all_storages)
  local auto_vmid=$(auto_assign_vmid)
  echo "   已存在VMID：$used_vids"
  echo "   可用网络桥接：$(echo "$vmbrs" | tr '\n' ' ')"
  echo "   可用存储：$(echo "$storages" | tr '\n' ' ')"
  echo "   自动分配VMID：$auto_vmid"
  echo -e "\n----------------------------------------"

  echo -e "${BOLD}2. VMID 配置${NC}"
  while true; do
    read -rp "请输入VMID（回车用自动分配 $auto_vmid）：" VMID
    VMID=$(echo "$VMID" | xargs)
    [ -z "$VMID" ] && { VMID="$auto_vmid"; break; }
    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
      log_err "❌ VMID必须是数字"
      continue
    fi
    if check_vmid_conflict "$VMID"; then
      log_err "❌ VMID $VMID 已存在"
      continue
    fi
    break
  done
  echo -e "----------------------------------------\n"

  echo -e "${BOLD}3. 操作系统选择${NC}"
  echo -e "📋 可选系统列表（序号对应如下）："
  for ((i=0; i<${#DISTRO_LIST[@]}; i++)); do
    echo -e "  ${BOLD}$((i+1))${NC}. ${DISTRO_LIST[$i]}"
  done
  echo -e "\n----------------------------------------"
  DISTRO_NAME=$(num_menu_select "请选择操作系统" "$(printf "%s\n" "${DISTRO_LIST[@]}")")
  IMAGE_PATH=$(get_distro_path "$DISTRO_NAME")
  DISTRO_SOURCE=$(get_distro_source "$DISTRO_NAME")
  echo -e "----------------------------------------\n"

  echo -e "${BOLD}4. 网络配置${NC}"
  echo -e "📋 可选网络桥接列表（序号对应如下）："
  local vmbr_list=()
  while IFS= read -r line; do vmbr_list+=("$line"); done < <(echo "$vmbrs")
  for ((i=0; i<${#vmbr_list[@]}; i++)); do
    echo -e "  ${BOLD}$((i+1))${NC}. ${vmbr_list[$i]}"
  done
  echo -e "\n----------------------------------------"
  VMBR=$(num_menu_select "请选择网络桥接" "$(printf "%s\n" "${vmbr_list[@]}")")
  if [ -z "$VMBR" ]; then
    log_warn "⚠️  强制使用默认桥接 vmbr0"
    VMBR="vmbr0"
  fi
  if ! ip link show "$VMBR" 2>/dev/null; then
    log_warn "⚠️  网络桥接 $VMBR 未检测到，但继续创建"
  else
    log_ok "✅ 网络桥接 $VMBR 验证通过"
  fi
  echo -e "----------------------------------------\n"

  echo -e "${BOLD}5. 存储配置${NC}"
  echo -e "📋 可选存储位置列表（序号对应如下）："
  local storage_list=()
  while IFS= read -r line; do storage_list+=("$line"); done < <(echo "$storages")
  for ((i=0; i<${#storage_list[@]}; i++)); do
    echo -e "  ${BOLD}$((i+1))${NC}. ${storage_list[$i]}"
  done
  echo -e "\n----------------------------------------"
  STORAGE=$(num_menu_select "请选择存储位置" "$(printf "%s\n" "${storage_list[@]}")")
  echo -e "----------------------------------------\n"

  echo -e "${BOLD}6. CPU核心配置${NC}"
  echo -e "📋 可选CPU核心列表（序号对应如下）："
  local core_options=("1核心" "2核心" "4核心" "8核心" "自定义")
  for ((i=0; i<${#core_options[@]}; i++)); do
    echo -e "  ${BOLD}$((i+1))${NC}. ${core_options[$i]}"
  done
  echo -e "\n----------------------------------------"
  CORE_CHOICE=$(num_menu_select "请选择CPU核心数" "$(printf "%s\n" "${core_options[@]}")")
  if [ "$CORE_CHOICE" = "自定义" ]; then
    CORES=$(custom_input "请输入自定义核心数（纯数字）：" "^[1-9][0-9]*$" "6")
  else
    CORES=$(echo "$CORE_CHOICE" | tr -cd '0-9')
  fi
  if ! [[ "$CORES" =~ ^[1-9][0-9]*$ ]]; then
    log_err "❌ CPU核心数必须是正整数，当前值：$CORES"
    exit 1
  fi
  echo -e "----------------------------------------\n"

  echo -e "${BOLD}7. 内存配置${NC}"
  echo -e "📋 可选内存大小列表（序号对应如下）："
  local mem_options=("1G" "2G" "4G" "8G" "16G" "自定义")
  for ((i=0; i<${#mem_options[@]}; i++)); do
    echo -e "  ${BOLD}$((i+1))${NC}. ${mem_options[$i]}"
  done
  echo -e "\n----------------------------------------"
  MEM_CHOICE=$(num_menu_select "请选择内存大小" "$(printf "%s\n" "${mem_options[@]}")")
  if [ "$MEM_CHOICE" = "自定义" ]; then
    MEM_SIZE=$(custom_input "请输入自定义内存（格式：数字+G/M）：" "^[1-9][0-9]*[GM]$" "4G、512M")
  else
    MEM_SIZE="$MEM_CHOICE"
  fi
  MEM_MB=0
  if [[ "$MEM_SIZE" =~ ^([1-9][0-9]*)G$ ]]; then
    MEM_MB=$(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$MEM_SIZE" =~ ^([1-9][0-9]*)M$ ]]; then
    MEM_MB=${BASH_REMATCH[1]}
  else
    log_err "❌ 内存格式解析失败：$MEM_SIZE"
    exit 1
  fi
  if [ "$MEM_MB" -lt 256 ]; then
    log_err "❌ 内存大小不能小于256MB"
    exit 1
  fi
  echo -e "----------------------------------------\n"

  echo -e "${BOLD}8. 硬盘配置${NC}"
  echo -e "📋 可选硬盘大小列表（序号对应如下）："
  local disk_options=("16G" "32G" "64G" "128G" "256G" "自定义")
  for ((i=0; i<${#disk_options[@]}; i++)); do
    echo -e "  ${BOLD}$((i+1))${NC}. ${disk_options[$i]}"
  done
  echo -e "\n----------------------------------------"
  DISK_CHOICE=$(num_menu_select "请选择硬盘大小" "$(printf "%s\n" "${disk_options[@]}")")
  if [ "$DISK_CHOICE" = "自定义" ]; then
    DISK_SIZE=$(custom_input "请输入自定义硬盘（格式：数字+G）：" "^[1-9][0-9]*G$" "20G")
  else
    DISK_SIZE="$DISK_CHOICE"
  fi
  local disk_size_g=${DISK_SIZE%G}
  if [ "$disk_size_g" -lt 8 ]; then
    log_err "❌ 硬盘大小不能小于8G"
    exit 1
  fi
  echo -e "----------------------------------------\n"

  # 最终参数确认
  clear
  echo -e "${BOLD}========================================"
  echo -e "          最终参数确认"
  echo -e "========================================${NC}\n"
  echo -e "${BOLD}📋 虚拟机配置：${NC}"
  echo -e "  VMID：\t\t$VMID"
  echo -e "  操作系统：\t$DISTRO_NAME"
  echo -e "  镜像源：\t$(if [ "$DISTRO_SOURCE" = "official" ]; then echo "Debian官方Generic"; else echo "第三方优化镜像"; fi)"
  echo -e "  镜像路径：\t$IMAGE_PATH"
  echo -e "  网络桥接：\t$VMBR"
  echo -e "  存储：\t\t$STORAGE"
  echo -e "  CPU核心：\t$CORES 核"
  echo -e "  内存：\t\t$MEM_SIZE ($MEM_MB MB)"
  echo -e "  硬盘：\t\t$DISK_SIZE"
  echo -e "  机型：\t\tq35（默认启用）"
  echo -e "  BIOS：\t\tOVMF (UEFI)（默认启用）"
  echo -e "  Qemu代理：\t启用（支持与qemu-guest-agent交互）"
  echo -e "  网卡类型：\tvirtio（PVE原生兼容，高性能）"
  
  echo -e "\n${BOLD}⚠️  确认参数是否正确？${NC}"
  read -rp "输入 (Y=确认继续 / 其他=重新配置)：" confirm
  confirm=$(echo "$confirm" | xargs | tr '[:lower:]' '[:upper:]')
  [ "$confirm" != "Y" ] && { log_info "🔄 重新配置参数"; prompt_vm_params; } || log_info "✅ 开始创建..."
}

# -------------------- 镜像下载 --------------------
download_image(){
  local rel_path="$1"
  local file="${rel_path##*/}"
  [ -z "$file" ] && { log_err "无效镜像路径"; exit 1; }
  
  CACHE_DIR=${CACHE_DIR:-"/var/cache/pve-unified-images"}
  mkdir -p "$CACHE_DIR"
  local cached="$CACHE_DIR/$file"
  
  if [[ "$rel_path" == https://cloud.debian.org/* ]]; then
    local url="$rel_path"
  else
    local url="$MIRROR_BASE$rel_path"
  fi
  
  [ -f "$cached" ] && { log_info "📦 检测到本地缓存，跳过下载"; return 0; }
  
  log_info "🌐 下载镜像：$url"
  log_info "📥 保存到：$cached"
  if ! wget -q --show-progress -c -O "$cached" "$url"; then
    log_err "❌ 下载失败"
    [ -f "$cached" ] && rm -f "$cached"
    exit 1
  fi
  log_ok "✅ 镜像下载完成：$cached"
}

# -------------------- 获取磁盘名称 --------------------
get_imported_disk_name() {
  local vmid="$1"
  local disk_name=""
  for ((i=0; i<20; i++)); do
    disk_name=$(sudo qm config "$vmid" 2>/dev/null \
      | grep -E '^unused[0-9]+:' \
      | awk '{print $2}' \
      | head -n1 \
      | tr -d '\n\r "[:space:]' \
      | sed -e 's/[^a-zA-Z0-9_:-]//g')
    if [[ "$disk_name" =~ ^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$ ]]; then
      echo -e "${BLUE}[INFO]${NC} ✅ 找到磁盘：$disk_name" >&2
      break
    fi
    sleep 1
  done
  if [ -z "$disk_name" ] || ! [[ "$disk_name" =~ ^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}[ERR]${NC} ❌ 未找到有效磁盘ID（VMID: $vmid），当前值：$disk_name" >&2
    FAILED_VMID="$vmid"
    exit 1
  fi
  echo "$disk_name"
}

# -------------------- 创建虚拟机（网络核心修复） --------------------
create_vm_single(){
  check_cmd sudo qm pvesm wget ip bc jq
  prompt_vm_params
  download_image "$IMAGE_PATH"
  
  log_info "🔍 校验存储 $STORAGE 可用性..."
  if ! sudo pvesm status | grep -q "^$STORAGE\s"; then
    log_err "❌ 存储 $STORAGE 不存在"
    exit 1
  fi
  
  local free_space=$(sudo pvesm free "$STORAGE" 2>/dev/null | awk '/^free|^avail/ {print $2}' | head -n1)
  if [[ "$free_space" =~ ^[0-9]+(\.[0-9]+)?G$ ]]; then
    free_space=$(echo "${free_space%G} * 1024" | bc | awk '{print int($1)}')
  elif [[ "$free_space" =~ ^[0-9]+(\.[0-9]+)?M$ ]]; then
    free_space=${free_space%M}
  elif [[ -z "$free_space" ]]; then
    free_space=0
  fi
  local target_size=$(echo "${DISK_SIZE%G} * 1024" | bc | awk '{print int($1)}')
  
  if [ "$free_space" -gt 0 ] && [ "$free_space" -lt "$target_size" ]; then
    log_warn "⚠️  存储空间不足（需要 ${DISK_SIZE}，可用：$free_space MB）"
    read -rp "是否继续？(Y/N)：" continue_yn
    continue_yn=$(echo "$continue_yn" | xargs | tr '[:lower:]' '[:upper:]')
    [ "$continue_yn" != "Y" ] && { log_info "🔄 取消创建"; exit 0; }
  elif [ "$free_space" -eq 0 ]; then
    log_warn "⚠️  无法检测存储空间"
    read -rp "是否继续？(Y/N)：" continue_yn
    continue_yn=$(echo "$continue_yn" | xargs | tr '[:lower:]' '[:upper:]')
    [ "$continue_yn" != "Y" ] && { log_info "🔄 取消创建"; exit 0; }
  fi
  
  log_info "🚀 创建虚拟机（VMID: $VMID）..."
  # 核心修复：网卡改为virtio，firewall=0
  if ! sudo qm create "$VMID" \
--name "$DISTRO_NAME" \
--cpu host \
--cores "$CORES" \
--memory "$MEM_MB" \
--balloon "$MEM_MB" \
--machine q35 \
--bios ovmf \
--efidisk0 "$STORAGE":1,efitype=4m,pre-enrolled-keys=1 \
--scsihw virtio-scsi-pci \
--agent 1,fstrim_cloned_disks=1 \
--net0 "virtio,bridge=${VMBR},firewall=0" \
--ostype l26 \
--boot order=scsi0; then
    log_err "❌ 创建虚拟机失败！具体错误如上"
    FAILED_VMID="$VMID"
    exit 1
  fi
  
  log_info "📥 导入磁盘到 $STORAGE..."
  local image_file="$CACHE_DIR/${IMAGE_PATH##*/}"
  if ! sudo qm importdisk "$VMID" "$image_file" "$STORAGE" --format qcow2; then
    log_err "❌ 磁盘导入失败！具体错误如上"
    FAILED_VMID="$VMID"
    exit 1
  fi
  
  local disk_name=$(get_imported_disk_name "$VMID")
  log_info "🔧 配置磁盘（大小：$DISK_SIZE）..."
  if ! sudo qm set "$VMID" --scsi0 "$disk_name"; then
    log_err "❌ 挂载磁盘失败！具体错误如上"
    FAILED_VMID="$VMID"
    exit 1
  fi
  
  if ! sudo qm resize "$VMID" scsi0 "$DISK_SIZE"; then
    log_err "❌ 调整磁盘失败！具体错误如上"
    FAILED_VMID="$VMID"
    exit 1
  fi
  
  log_info "🔧 配置CloudInit..."
  if ! sudo qm set "$VMID" --ide2 "$STORAGE:cloudinit"; then
    log_err "❌ 配置CloudInit失败！具体错误如上"
    FAILED_VMID="$VMID"
    exit 1
  fi
  
  sudo qm set "$VMID" \
--ipconfig0 "ip=dhcp,ip6=dhcp" \
--boot c --bootdisk scsi0 \
--serial0 socket --vga serial0 \
--onboot 0
  
  # 配置默认用户密码
  if [ "$DISTRO_SOURCE" = "official" ]; then
    log_info "🔧 配置Debian官方镜像默认用户..."
    sudo qm set "$VMID" --ciuser debian --cipassword oneclickvirt
  else
    sudo qm set "$VMID" --ciuser root --cipassword oneclickvirt
  fi
  
  log_info "▶️  启动虚拟机..."
  if ! sudo qm start "$VMID"; then
    log_err "❌ 启动失败！具体错误如上"
    FAILED_VMID="$VMID"
    exit 1
  fi
  
  log_info "⌛ 等待获取IP（最多180秒）..."
  local timeout=180 interval=5 elapsed=0 IP=""
  while [ $elapsed -lt $timeout ]; do
    IP=$(sudo qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | awk '
      /"ip-address"/ {
        gsub(/[",]/, "");
        for (i=1; i<=NF; i++) {
          if ($i ~ /^ip-address$/ && $(i+1)==":") {
            ip=$(i+2);
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip!~ /^127\./) {print ip; exit;}
          }
        }
      }')
    [ -n "$IP" ] && { log_info "✅ IP：$IP"; sudo qm set "$VMID" --tags "IP:$IP" 2>/dev/null; break; }
    elapsed=$((elapsed + interval))
    sleep $interval
  done
  
  FAILED_VMID=""
  clear
  log_ok "🎉 虚拟机创建完成！"
  echo -e "\n${BOLD}📋 虚拟机信息：${NC}"
  echo -e "  VMID：\t$VMID"
  echo -e "  名称：\t$DISTRO_NAME"
  echo -e "  镜像源：\t$(if [ "$DISTRO_SOURCE" = "official" ]; then echo "Debian官方Generic"; else echo "第三方优化镜像"; fi)"
  echo -e "  机型：\tq35"
  echo -e "  BIOS：\tOVMF (UEFI)"
  echo -e "  Qemu代理：\t已启用"
  echo -e "  CPU：\t\t$CORES 核"
  echo -e "  内存：\t$MEM_SIZE"
  echo -e "  硬盘：\t$DISK_SIZE"
  echo -e "  网络：\t$VMBR（virtio网卡，防火墙已关闭）"
  [ -n "$IP" ] && echo -e "  IP地址：\t$IP" || echo -e "  IP地址：\t未获取到（可在PVE面板->CloudInit重新加载）"
  echo -e "\n🔑 默认账户：$(if [ "$DISTRO_SOURCE" = "official" ]; then echo "debian / oneclickvirt"; else echo "root / oneclickvirt"; fi)"
  echo -e "⚠️  请立即修改默认密码！"
  if [ "$DISTRO_SOURCE" = "official" ]; then
    echo -e "💡 官方镜像提示：登录后执行 'sudo -i' 切换到root用户（debian用户有免密sudo）"
  fi
}

# -------------------- IP标签同步 --------------------
update_ip_tags(){
  check_cmd sudo qm pvesm ip jq
  clear
  echo -e "${BOLD}========================================"
  echo -e "          同步VM/LXC IP标签"
  echo -e "========================================${NC}\n"
  log_info "🔍 扫描所有虚拟机和容器..."

  log_info "📋 处理QEMU虚拟机..."
  local qm_count=0
  while IFS= read -r VMID; do
    [ -z "$VMID" ] && continue
    qm_count=$((qm_count + 1))
    echo -n "  VMID $VMID："
    local IP=$(sudo qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | awk '
      /"ip-address"/ {
        gsub(/[",]/, "");
        for (i=1; i<=NF; i++) {
          if ($i ~ /^ip-address$/ && $(i+1)==":") {
            ip=$(i+2);
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip!~ /^127\./) {print ip; exit;}
          }
        }
      }')
    if [ -n "$IP" ]; then
      sudo qm set "$VMID" --tags "IP:$IP" 2>/dev/null
      echo -e "${GREEN}成功 (IP: $IP)${NC}"
    else
      echo -e "${YELLOW}未获取到IP${NC}"
    fi
  done < <(sudo qm list 2>/dev/null | awk 'NR>1 {print $1}')

  log_info "\n📋 处理LXC容器..."
  local lxc_count=0
  while IFS= read -r CTID; do
    [ -z "$CTID" ] && continue
    lxc_count=$((lxc_count + 1))
    echo -n "  CTID $CTID："
    local IP=$(sudo pct exec "$CTID" -- ip -4 addr show 2>/dev/null | awk '
      /inet / {
        for (i=1; i<=NF; i++) {
          if ($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\//) {
            sub(/\/.*/, "", $i);
            if ($i!~ /^127\./) {print $i; exit;}
          }
        }
      }')
    if [ -n "$IP" ]; then
      sudo pct set "$CTID" --tags "IP:$IP" 2>/dev/null
      echo -e "${GREEN}成功 (IP: $IP)${NC}"
    else
      echo -e "${YELLOW}未获取到IP${NC}"
    fi
  done < <(sudo pct list 2>/dev/null | awk 'NR>1 {print $1}')

  echo -e "\n✅ 同步完成！"
  echo -e "   处理虚拟机：$qm_count 个"
  echo -e "   处理容器：\t$lxc_count 个"
}

# -------------------- 清除缓存 --------------------
clear_cache(){
  clear
  echo -e "${BOLD}========================================"
  echo -e "          清理镜像缓存"
  echo -e "========================================${NC}\n"
  CACHE_DIR=${CACHE_DIR:-"/var/cache/pve-unified-images"}
  
  [ ! -d "$CACHE_DIR" ] && { log_info "📂 缓存目录不存在"; log_ok "✅ 无需清理"; return 0; }
  
  log_info "📋 当前缓存文件："
  ls -lh "$CACHE_DIR" 2>/dev/null | awk 'NR>1 {print "  " $0}'
  
  read -rp "\n⚠️  确定删除所有缓存？(Y/N)：" confirm
  confirm=$(echo "$confirm" | xargs | tr '[:lower:]' '[:upper:]')
  if [ "$confirm" = "Y" ]; then
    log_info "🗑️  开始清理缓存..."
    rm -rf "$CACHE_DIR"/*
    log_ok "✅ 清理完成"
  else
    log_info "🔄 取消清理"
  fi
}

# -------------------- 命令检查 --------------------
check_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_err "❌ 缺少必要命令：$cmd，请先安装（例如：apt install $cmd -y）"
      exit 1
    fi
  done
}

# -------------------- 主菜单 --------------------
show_main_menu(){
  clear
  echo -e "${BOLD}========================================"
  echo -e "          PVE 一体化管理脚本"
  echo -e "========================================${NC}"
  echo -e "  ${BOLD}1${NC}. 创建单个虚拟机（机型q35+UEFI+Qemu代理）"
  echo -e "  ${BOLD}2${NC}. 同步IP标签"
  echo -e "  ${BOLD}3${NC}. 清除缓存"
  echo -e "  ${BOLD}4${NC}. 退出"
  echo -e "${BOLD}========================================${NC}"
}

main(){
  [ "$(id -u)" -ne 0 ] && { log_err "❌ 请以root运行：sudo ./pve-vm-manager.sh"; exit 1; }
  check_cmd sudo qm pvesm wget ip bc jq
  
  while true; do
    show_main_menu
    read -rp "\n请选择操作（1-4）：" opt
    opt=$(echo "$opt" | xargs)
    case "$opt" in
      1) create_vm_single ;;
      2) update_ip_tags ;;
      3) clear_cache ;;
      4) clear; log_info "👋 再见！"; exit 0 ;;
      *) log_err "❌ 无效选择，请输1-4"; sleep 2 ;;
    esac
    
    echo -e "\n----------------------------------------"
    read -rp "按任意键返回主菜单..." -n 1
  done
}

# 启动
main "$@"
