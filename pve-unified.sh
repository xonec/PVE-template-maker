#!/bin/bash

# ============================================================================
#  PVE 一体化脚本：云模板/虚拟机创建 + IP 标签同步
#  - 自动识别PVE资源：VMID、网络桥接、存储
#  - 上下键选择式交互：镜像、网络、存储、核心、内存、硬盘
#  - VMID：自动分配/手动输入（冲突检查）
#  - 创建失败自动清理残留虚拟机
# ============================================================================

set -o pipefail

# 全局配置
MIRROR_BASE="https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/"
CACHE_DIR="/var/cache/pve-unified-images"
FAILED_VMID=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'
REVERSE='\033[7m'  # 反色（选中项高亮）

# 日志函数
log_info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok(){   echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err(){  echo -e "${RED}[ERR]${NC}  $*" >&2; }

# -------------------- 核心新增：系统资源识别函数 --------------------

# 获取所有已存在的VMID
get_all_vmids() {
  local vids
  vids=$(sudo qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n)
  echo "$vids"
}

# 获取所有网络桥接（vmbr开头）
get_all_vmbrs() {
  local vmbrs
  vmbrs=$(ip link show 2>/dev/null | grep -E '^[0-9]+: vmbr' | awk -F: '{gsub(/ /,""); print $2}' | sort)
  # 保底（如果没识别到，默认vmbr0）
  if [ -z "$vmbrs" ]; then
    vmbrs="vmbr0"
  fi
  echo "$vmbrs"
}

# 获取PVE所有可用存储
get_all_storages() {
  local storages
  storages=$(sudo pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort)
  # 保底
  if [ -z "$storages" ]; then
    storages="local
local-lvm"
  fi
  echo "$storages"
}

# 自动分配VMID（PVE默认规则：从100开始找最小未使用的）
auto_assign_vmid() {
  local used_vids=($(get_all_vmids))
  local new_vid=100
  
  # 如果100-999有未使用的，优先分配；否则从8000开始
  while [[ " ${used_vids[@]} " =~ " $new_vid " ]]; do
    new_vid=$((new_vid + 1))
    # 100-999用完，直接用8000开始
    if [ $new_vid -gt 999 ]; then
      new_vid=8000
      break
    fi
  done
  
  # 8000开始继续找
  while [[ " ${used_vids[@]} " =~ " $new_vid " ]]; do
    new_vid=$((new_vid + 1))
  done
  
  echo "$new_vid"
}

# 检查VMID是否冲突
check_vmid_conflict() {
  local vmid=$1
  local used_vids=($(get_all_vmids))
  
  if [[ " ${used_vids[@]} " =~ " $vmid " ]]; then
    return 0  # 冲突
  else
    return 1  # 不冲突
  fi
}

# -------------------- 核心新增：上下键菜单选择函数 --------------------

# 上下键选择菜单
# 参数1：菜单标题
# 参数2：选项列表（换行分隔）
# 参数3：默认选中索引（从0开始）
# 返回：选中的选项值
menu_select() {
  local title="$1"
  local options=($(echo "$2" | tr '\n' ' '))
  local default_idx=${3:-0}
  local current_idx=$default_idx
  local num_options=${#options[@]}
  local key=""

  # 关闭终端回显，启用原始模式（捕获上下键）
  stty -echo raw 2>/dev/null

  # 菜单循环
  while true; do
    # 清屏并显示标题
    clear
    echo -e "${BOLD}${title}${NC}"
    echo "========================================"
    
    # 显示选项（高亮选中项）
    for ((i=0; i<num_options; i++)); do
      if [ $i -eq $current_idx ]; then
        echo -e "${REVERSE}${i+1}. ${options[$i]}${NC}"  # 反色高亮
      else
        echo -e " ${i+1}. ${options[$i]}"
      fi
    done
    
    echo "========================================"
    echo "↑/↓ 选择 | Enter 确认 | ESC 退出"

    # 读取按键
    read -n 1 key 2>/dev/null
    
    # 处理按键
    case "$key" in
      # 上键（ESC[A）
      $'\x1b')
        read -n 2 -t 0.1 key2 2>/dev/null
        if [ "$key2" = "[A" ]; then
          current_idx=$((current_idx - 1))
          [ $current_idx -lt 0 ] && current_idx=$((num_options - 1))
        elif [ "$key2" = "[B" ]; then
          # 下键（ESC[B）
          current_idx=$((current_idx + 1))
          [ $current_idx -ge $num_options ] && current_idx=0
        elif [ "$key" = $'\x1b' ]; then
          # ESC退出
          stty echo cooked 2>/dev/null
          log_err "用户取消选择"
          exit 1
        fi
        ;;
      # 回车键确认
      $'\n')
        stty echo cooked 2>/dev/null
        echo -e "\n您选择了：${options[$current_idx]}"
        echo "${options[$current_idx]}"
        return 0
        ;;
    esac
  done
}

# 自定义输入函数（用于自定义核心/内存/硬盘）
custom_input() {
  local prompt="$1"
  local validate_regex="$2"
  local error_msg="$3"
  local input=""
  
  while true; do
    read -rp "$prompt" input
    # 空输入退出
    if [ -z "$input" ]; then
      log_err "输入不能为空"
      continue
    fi
    # 验证格式
    if [[ $input =~ $validate_regex ]]; then
      echo "$input"
      return 0
    else
      log_err "$error_msg"
    fi
  done
}

# -------------------- 失败清理函数（保留原有功能） --------------------
cleanup_failed_vm(){
  local id="$1"
  if [ -z "$id" ]; then
    log_err "清理失败虚拟机时，VMID 为空"
    return 1
  fi

  if ! sudo qm status "$id" >/dev/null 2>&1; then
    log_info "VMID $id 不存在，无需清理"
    return 0
  fi

  log_info "停止失败的 VMID $id ..."
  sudo qm stop "$id" 2>/dev/null || log_warn "停止 VMID $id 失败（可能已停止）"

  log_info "销毁失败的 VMID $id 并清理关联磁盘..."
  if sudo qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1; then
    log_ok "已成功销毁失败的虚拟机 VMID: $id"
  else
    log_err "销毁 VMID $id 失败，请手动执行：sudo qm destroy $id --destroy-unreferenced-disks 1 --purge 1"
  fi
}

cleanup(){
  if [ -n "$FAILED_VMID" ]; then
    log_warn "========================================"
    log_warn "检测到创建失败的虚拟机 VMID: $FAILED_VMID"
    log_warn "开始自动清理残留资源..."
    log_warn "========================================"
    cleanup_failed_vm "$FAILED_VMID"
    FAILED_VMID=""
  fi
}
trap cleanup EXIT

# -------------------- 基础检查函数 --------------------
check_root(){
  : # 允许非 root 运行，由 sudo 提权具体命令
}

check_cmd(){
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log_err "缺少命令: $c"; exit 1; }
  done
}

# -------------------- 发行版定义 --------------------
declare -A DISTROS
DISTROS[1]="Debian-11|debian|debian11.qcow2"
DISTROS[2]="Debian-12|debian|debian12.qcow2"
DISTROS[3]="Debian-13|debian|debian13.qcow2"
DISTROS[4]="Ubuntu-18.04|ubuntu|ubuntu1804.qcow2"
DISTROS[5]="Ubuntu-20.04|ubuntu|ubuntu2004.qcow2"
DISTROS[6]="Ubuntu-22.04|ubuntu|ubuntu2204.qcow2"
DISTROS[7]="Ubuntu-24.04|ubuntu|ubuntu2404.qcow2"
DISTROS[8]="CentOS-8|centos|centos8.qcow2"
DISTROS[9]="CentOS-9|centos|centos9.qcow2"

# 构建发行版选项列表
get_distro_options() {
  local options=""
  for i in $(seq 1 10); do
    IFS='|' read -r name subdir file <<<"${DISTROS[$i]}"
    [ -z "$name" ] && continue
    options+="$name"$'\n'
  done
  echo -e "$options" | sed '/^$/d'  # 移除空行
}

# 根据发行版名称获取镜像路径
get_distro_path() {
  local distro_name="$1"
  for i in $(seq 1 10); do
    IFS='|' read -r name subdir file <<<"${DISTROS[$i]}"
    if [ "$name" = "$distro_name" ]; then
      echo "$subdir/$file"
      return 0
    fi
  done
  log_err "未找到发行版 $distro_name 的镜像路径"
  exit 1
}

# -------------------- 核心修改：参数提示函数（上下键选择） --------------------
prompt_vm_params() {
  # 1. 自动识别系统资源
  local used_vids=$(get_all_vmids)
  local vmbrs=$(get_all_vmbrs)
  local storages=$(get_all_storages)
  local auto_vmid=$(auto_assign_vmid)

  log_info "=== 系统资源识别结果 ==="
  log_info "已存在VMID: $used_vids"
  log_info "可用网络桥接: $vmbrs"
  log_info "可用存储: $storages"
  log_info "自动分配VMID: $auto_vmid"
  echo "=========================="

  # 2. VMID选择（手动/自动）
  while true; do
    read -rp "请输入VMID（回车使用自动分配的 $auto_vmid）: " VMID
    # 空输入使用自动分配
    if [ -z "$VMID" ]; then
      VMID="$auto_vmid"
      log_info "使用自动分配的VMID: $VMID"
      break
    fi
    # 验证数字格式
    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
      log_err "VMID必须为数字"
      continue
    fi
    # 检查冲突
    if check_vmid_conflict "$VMID"; then
      log_err "VMID $VMID 已存在，请重新输入"
      continue
    fi
    log_info "确认使用VMID: $VMID"
    break
  done

  # 3. 发行版选择（上下键）
  local distro_options=$(get_distro_options)
  DISTRO_NAME=$(menu_select "请选择发行版" "$distro_options" 0)
  IMAGE_PATH=$(get_distro_path "$DISTRO_NAME")

  # 4. 网络桥接选择（上下键）
  VMBR=$(menu_select "请选择网络桥接" "$vmbrs" 0)

  # 5. 存储选择（上下键）
  STORAGE=$(menu_select "请选择存储" "$storages" 0)

  # 6. 核心数选择（上下键+自定义）
  local core_options="1核心
2核心
4核心
8核心
自定义"
  CORE_CHOICE=$(menu_select "请选择CPU核心数" "$core_options" 1)  # 默认2核心
  if [ "$CORE_CHOICE" = "自定义" ]; then
    CORES=$(custom_input "请输入自定义核心数（数字）: " "^[0-9]+$" "核心数必须为正整数")
  else
    CORES=$(echo "$CORE_CHOICE" | awk '{print $1}')
  fi

  # 7. 内存选择（上下键+自定义）
  local mem_options="1G
2G
4G
8G
16G
自定义"
  MEM_CHOICE=$(menu_select "请选择内存大小" "$mem_options" 1)  # 默认2G
  if [ "$MEM_CHOICE" = "自定义" ]; then
    MEM_SIZE=$(custom_input "请输入自定义内存大小（例如 4G/512M）: " "^[0-9]+[GM]$" "内存格式错误，示例：4G 或 512M")
  else
    MEM_SIZE="$MEM_CHOICE"
  fi
  # 转换为MB（PVE qm命令使用MB）
  if [[ "$MEM_SIZE" =~ ^([0-9]+)G$ ]]; then
    MEM_MB=$(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$MEM_SIZE" =~ ^([0-9]+)M$ ]]; then
    MEM_MB=${BASH_REMATCH[1]}
  else
    log_err "内存格式解析失败"
    exit 1
  fi

  # 8. 硬盘大小选择（上下键+自定义）
  local disk_options="16G
32G
64G
128G
256G
自定义"
  DISK_CHOICE=$(menu_select "请选择硬盘大小" "$disk_options" 1)  # 默认32G
  if [ "$DISK_CHOICE" = "自定义" ]; then
    DISK_SIZE=$(custom_input "请输入自定义硬盘大小（例如 20G）: " "^[0-9]+G$" "硬盘格式错误，示例：20G")
  else
    DISK_SIZE="$DISK_CHOICE"
  fi

  # 输出最终参数确认
  echo -e "\n${BOLD}=== 虚拟机参数确认 ==="
  echo "VMID: $VMID"
  echo "发行版: $DISTRO_NAME ($IMAGE_PATH)"
  echo "网络桥接: $VMBR"
  echo "存储: $STORAGE"
  echo "CPU核心: $CORES"
  echo "内存: $MEM_SIZE ($MEM_MB MB)"
  echo "硬盘: $DISK_SIZE"
  echo "=======================${NC}"
  
  read -rp "确认以上参数？(Y/n) " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    log_err "用户取消配置，退出"
    exit 1
  fi
}

# -------------------- 镜像下载函数（适配新的发行版路径） --------------------
download_image(){
  local rel_path="$1"          
  local file="${rel_path##*/}"   

  if [ -z "$file" ]; then
    log_err "无效的相对路径: $rel_path（无法提取文件名）"
    exit 1
  fi

  mkdir -p "$CACHE_DIR"
  local cached="$CACHE_DIR/$file"
  local url="$MIRROR_BASE$rel_path"

  # 获取远程文件大小
  local remote_size
  remote_size=$(curl -sI "$url" | awk 'tolower($1) ~ /^content-length:/ {gsub("\r",""); print $2}' || true)

  if [ -n "$remote_size" ]; then
    log_info "远程镜像大小: $remote_size 字节 ($url)"
  else
    log_warn "无法获取远程镜像大小，将直接采用下载逻辑: $url"
  fi

  # 检查本地缓存
  if [ -s "$cached" ] && [ -n "$remote_size" ]; then
    local local_size
    local_size=$(stat -c '%s' "$cached" 2>/dev/null || stat -f '%z' "$cached" 2>/dev/null || echo "")

    if [ -n "$local_size" ]; then
      log_info "本地缓存镜像大小: $local_size 字节 ($cached)"

      if [ "$local_size" = "$remote_size" ]; then
        log_info "本地与远程大小一致，跳过重新下载。"
        return 0
      else
        log_warn "本地与远程大小不一致，删除本地缓存并重新下载。"
        rm -f "$cached" 2>/dev/null || true
      fi
    else
      log_warn "无法获取本地镜像大小，将重新下载: $cached"
      rm -f "$cached" 2>/dev/null || true
    fi
  elif [ -s "$cached" ]; then
    log_info "命中缓存镜像（未校验远程大小）: $cached"
    return 0
  fi

  # 下载镜像
  log_info "下载镜像: $url"
  if ! wget -c -O "$cached" "$url"; then
    log_err "下载失败: $url"; exit 1;
  fi
  log_ok "镜像已下载并缓存: $cached"
}

# -------------------- 获取导入后的磁盘名称 --------------------
get_imported_disk_name() {
  local vmid="$1"
  local disk_name
  disk_name=$(sudo qm config "$vmid" | grep -E '^unused[0-9]+:' | awk '{print $2}' | head -n1)
  if [ -z "$disk_name" ]; then
    log_err "未找到导入的磁盘（VMID: $vmid）"
    FAILED_VMID="$vmid"
    exit 1
  fi
  echo "$disk_name"
}

# -------------------- 创建云模板 --------------------
create_template_single(){
  check_root
  check_cmd sudo qm wget pct ip

  # 获取虚拟机参数（上下键选择）
  prompt_vm_params

  # 下载镜像
  download_image "$IMAGE_PATH"

  # 创建虚拟机
  log_info "创建云模板 VM $DISTRO_NAME (VMID: $VMID)"
  sudo qm create "$VMID" \
    --name "$DISTRO_NAME" \
    --cpu host \
    --cores "$CORES" \
    --memory "$MEM_MB" \
    --scsihw virtio-scsi-pci \
    --agent 1 \
    --net0 virtio,bridge="$VMBR" || {
    log_err "创建虚拟机失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 导入磁盘
  log_info "导入磁盘到存储 $STORAGE"
  sudo qm importdisk "$VMID" "$CACHE_DIR/${IMAGE_PATH##*/}" "$STORAGE" --format qcow2 || {
    log_err "导入磁盘失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 获取磁盘名称
  local disk_name
  disk_name=$(get_imported_disk_name "$VMID")
  log_info "获取到导入的磁盘名: $disk_name"

  # 配置磁盘
  log_info "配置 SCSI 磁盘 ($DISK_SIZE) 和 CloudInit 双栈 DHCP"
  sudo qm set "$VMID" --scsi0 "$disk_name" || {
    log_err "挂载 scsi0 失败";
    FAILED_VMID="$VMID"
    exit 1;
  }
  sudo qm resize "$VMID" scsi0 "$DISK_SIZE" || {
    log_err "调整磁盘大小失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 配置CloudInit
  sudo qm set "$VMID" --ide2 "$STORAGE:cloudinit" || {
    log_err "配置 cloudinit 失败";
    FAILED_VMID="$VMID"
    exit 1;
  }
  sudo qm set "$VMID" --ipconfig0 "ip=dhcp,ip6=dhcp" || {
    log_err "配置 IP 为双栈 DHCP 失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 其他配置
  sudo qm set "$VMID" --boot c --bootdisk scsi0
  sudo qm set "$VMID" --serial0 socket --vga serial0
  sudo qm set "$VMID" --description "$NOTES_TEXT"

  # 转换为模板
  log_info "转换为模板 (不启动 VM、不写入 IP)"
  sudo qm template "$VMID" || { 
    log_err "转换模板失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  log_ok "云模板 $DISTRO_NAME (VMID: $VMID) 创建完成"
  FAILED_VMID=""
}

# -------------------- 创建普通虚拟机 --------------------
wait_and_set_ip_tag(){
  local vmid="$1"
  local timeout="${2:-120}"
  local interval=5
  local elapsed=0

  log_info "等待虚拟机 $vmid 获取 IP (最多 ${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    IP=$(sudo qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | awk '
      /"ip-address"/ {
        gsub(/[",]/, "");
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^ip-address$/ && (i+1) <= NF && $(i+1) == ":") {
            ip = $(i+2);
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /^127\./) {
              print ip;
              exit;
            }
          }
        }
      }
    ')

    if [ -n "$IP" ]; then
      log_ok "获取到 IP: $IP，写入 tags"
      sudo qm set "$vmid" --tags "$IP"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_warn "在 ${timeout}s 内未获取到虚拟机 $vmid 的 IP (请检查 qemu-guest-agent / 网络配置)"
  return 1
}

create_vm_single(){
  check_root
  check_cmd sudo qm wget pct ip

  # 获取虚拟机参数（上下键选择）
  prompt_vm_params

  # 下载镜像
  download_image "$IMAGE_PATH"

  # 创建虚拟机
  log_info "创建虚拟机 $DISTRO_NAME (VMID: $VMID)"
  sudo qm create "$VMID" \
    --name "$DISTRO_NAME" \
    --cpu host \
    --cores "$CORES" \
    --memory "$MEM_MB" \
    --scsihw virtio-scsi-pci \
    --agent 1 \
    --net0 virtio,bridge="$VMBR" || {
    log_err "创建虚拟机失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 导入磁盘
  log_info "导入磁盘到存储 $STORAGE"
  sudo qm importdisk "$VMID" "$CACHE_DIR/${IMAGE_PATH##*/}" "$STORAGE" --format qcow2 || {
    log_err "导入磁盘失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 获取磁盘名称
  local disk_name
  disk_name=$(get_imported_disk_name "$VMID")
  log_info "获取到导入的磁盘名: $disk_name"

  # 配置磁盘
  log_info "配置 SCSI 磁盘 ($DISK_SIZE) 和 CloudInit 双栈 DHCP"
  sudo qm set "$VMID" --scsi0 "$disk_name" || {
    log_err "挂载 scsi0 失败";
    FAILED_VMID="$VMID"
    exit 1;
  }
  sudo qm resize "$VMID" scsi0 "$DISK_SIZE" || {
    log_err "调整磁盘大小失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 配置CloudInit
  sudo qm set "$VMID" --ide2 "$STORAGE:cloudinit" || {
    log_err "配置 cloudinit 失败";
    FAILED_VMID="$VMID"
    exit 1;
  }
  sudo qm set "$VMID" --ipconfig0 "ip=dhcp,ip6=dhcp" || {
    log_err "配置 IP 为双栈 DHCP 失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 其他配置
  sudo qm set "$VMID" --boot c --bootdisk scsi0
  sudo qm set "$VMID" --serial0 socket --vga serial0
  sudo qm set "$VMID" --description "$NOTES_TEXT"

  # 启动虚拟机
  log_info "启动虚拟机并等待 IP"
  sudo qm start "$VMID" || { 
    log_err "启动虚拟机失败";
    FAILED_VMID="$VMID"
    exit 1;
  }

  # 等待并设置IP标签
  wait_and_set_ip_tag "$VMID" 180

  log_ok "虚拟机 $DISTRO_NAME (VMID: $VMID) 创建完成（如成功获取到 IP 已写入 tags）"
  FAILED_VMID=""
}

# -------------------- IP 标签同步 --------------------
update_ip_tags(){
  check_root
  check_cmd sudo qm sudo pct ip

  echo "开始处理本地节点所有虚拟机和容器..."

  # QEMU 虚拟机
  QMIDS=$(sudo qm list | awk 'NR>1 {print $1}')
  for VMID in $QMIDS; do
    echo "处理 QEMU 虚拟机 $VMID ..."
    IP=$(sudo qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | awk '
      /"ip-address"/ {
        gsub(/[",]/, "");
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^ip-address$/ && (i+1) <= NF && $(i+1) == ":") {
            ip = $(i+2);
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /^127\./) {
              print ip;
              exit;
            }
          }
        }
      }
    ')
    if [ -z "$IP" ]; then
      echo "  未获取到IP (可能未安装 qemu-guest-agent 或虚拟机未运行)"; continue;
    fi
    echo "  获取到IP: $IP"
    sudo qm set "$VMID" --tags "$IP"
    echo "  已将IP写入虚拟机tags"
  done

  # LXC 容器
  CTIDS=$(sudo pct list | awk 'NR>1 {print $1}')
  for CTID in $CTIDS; do
    echo "处理 LXC 容器 $CTID ..."
    IP=$(sudo pct exec "$CTID" -- ip -4 addr show | awk '
      /inet / {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\//) {
            sub(/\/.*/, "", $i);
            if ($i !~ /^127\./) {
              print $i;
              exit;
            }
          }
        }
      }
    ')
    if [ -z "$IP" ]; then
      echo "  未获取到IP (容器未运行或网络未配置)"; continue;
    fi
    echo "  获取到IP: $IP"
    sudo pct set "$CTID" --tags "$IP"
    echo "  已将IP写入容器 tags 标签"
  done

  echo "全部处理完成！"
}

# -------------------- 清除缓存 --------------------
clear_cache(){
  echo "即将删除缓存目录 $CACHE_DIR 及其所有子目录..."

  if [ -d "$CACHE_DIR" ]; then
    sudo rm -rf "$CACHE_DIR" 2>/dev/null || true
    echo "缓存目录已删除。"
  else
    echo "缓存目录不存在，无需删除旧目录。"
  fi

  sudo mkdir -p "$CACHE_DIR"
  echo "已重新创建空的缓存目录: $CACHE_DIR"
}

# -------------------- 主菜单 --------------------
show_main_menu(){
  clear
  echo -e "${BOLD}================ PVE 一体化脚本 ================${NC}"
  echo "1) 创建单个云模板"
  echo "2) 创建单个虚拟机"
  echo "3) 扫描并将局域网 IP 写入 VM/LXC tags"
  echo "4) 清除已缓存的镜像文件"
  echo "5) 退出"
  echo "==============================================="
}

main(){
  check_cmd sudo qm pvesm ip wget  # 检查核心命令

  while true; do
    show_main_menu
    read -rp "请选择操作 (1-5): " opt
    case "$opt" in
      1) create_template_single ;;
      2) create_vm_single ;;
      3) update_ip_tags ;;
      4) clear_cache ;;
      5) echo "退出"; break ;;
      *) log_warn "无效选择，请输入 1-5" ;;
    esac
    read -rp "按任意键返回主菜单..." -n 1
  done
}

# 镜像说明文本（全局）
NOTES_TEXT=$'#  镜像说明 (请务必阅读)\n\n- 已预安装：`wget`、`curl`、`openssh-server`、`sshpass`、`sudo`、`cron(cronie)`、`qemu-guest-agent`\n- 已安装并启用 **cloud-init**，开启 SSH 登录，预设 SSH 监听 **IPv4 / IPv6 的 22 端口**，允许密码登录\n- 所有镜像均允许 **root 用户** 通过 SSH 登录\n\n**默认账户信息：**\n\n- 用户名：`root`\n- 密码：`oneclickvirt`\n\n> ⚠️ 安全提示：如果在生产或公网环境使用，请务必在首次登录后立刻修改 root 密码，否则存在被暴力破解/入侵的高风险。'

# 启动主程序
main "$@"
