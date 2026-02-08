#!/bin/bash

# ============================================================================
#  PVE 一体化脚本：云模板/虚拟机创建 + IP 标签同步
#  - 使用自定义镜像源: https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/
#  - 支持交互选择发行版 + VMID，创建模板或普通虚拟机
#  - 创建模板：不写入 IP
#  - 创建虚拟机：使用 DHCP 自动获取 IP，启动后写入 IP 到 tags
#  - 支持扫描所有 VM/LXC，并将局域网 IP 写入 tags
# ============================================================================

set -o pipefail

# 配置镜像源
MIRROR_BASE="https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/"
CACHE_DIR="/var/cache/pve-unified-images"
NOTES_TEXT=$'#  镜像说明 (请务必阅读)\n\n- 已预安装：`wget`、`curl`、`openssh-server`、`sshpass`、`sudo`、`cron(cronie)`、`qemu-guest-agent`\n- 已安装并启用 **cloud-init**，开启 SSH 登录，预设 SSH 监听 **IPv4 / IPv6 的 22 端口**，允许密码登录\n- 所有镜像均允许 **root 用户** 通过 SSH 登录\n\n**默认账户信息：**\n\n- 用户名：`root`\n- 密码：`oneclickvirt`\n\n> ⚠️ 安全提示：如果在生产或公网环境使用，请务必在首次登录后立刻修改 root 密码，否则存在被暴力破解/入侵的高风险。'

# -------------------- 颜色定义 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok(){   echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err(){  echo -e "${RED}[ERR]${NC}  $*" >&2; }

cleanup(){ :; }
trap cleanup EXIT

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

# -------------------- 功能函数 --------------------

show_distro_menu(){
  echo "================ 发行版选择 ================"
  for i in $(seq 1 9); do
    IFS='|' read -r name subdir file <<<"${DISTROS[$i]}"
    [ -z "$name" ] && continue
    printf "%2d) %s" "$i" "$name"
    [ -n "$file" ] && printf " (%s/%s)" "$subdir" "$file"
    echo
  done
  echo "==========================================="
}

# 输入虚拟机参数
prompt_vm_params(){
  read -rp "请输入 VMID (例如 8000): " VMID
  [[ "$VMID" =~ ^[0-9]+$ ]] || { log_err "VMID 必须为数字"; exit 1; }

  read -rp "请输入网络桥接 (默认 vmbr0): " VMBR
  [ -z "$VMBR" ] && VMBR="vmbr0"

  read -rp "请输入存储名称 (默认 local): " STORAGE
  [ -z "$STORAGE" ] && STORAGE="local"
}

# 磁盘命名处理：确保磁盘名称不包含非法字符
sanitize_disk_name() {
  local disk_name="$1"
  # 替换所有斜杠（/）为横杠（-）并去掉 .qcow2 后缀
  echo "${disk_name//\//-}" | sed 's/\.qcow2$//'
}

download_image(){
  local rel_path="$1"
  local file="${rel_path##*/}"
  if [ -z "$file" ]; then
    log_err "无效的相对路径: $rel_path"
    exit 1
  fi

  mkdir -p "$CACHE_DIR"
  local cached="$CACHE_DIR/$file"
  local url="$MIRROR_BASE$rel_path"

  local remote_size
  remote_size=$(curl -sI "$url" | awk 'tolower($1) ~ /^content-length:/ {gsub("\r",""); print $2}' || true)

  if [ -n "$remote_size" ]; then
    log_info "远程镜像大小: $remote_size 字节 ($url)"
  else
    log_warn "无法获取远程镜像大小，将直接采用下载逻辑: $url"
  fi

  if [ -s "$cached" ] && [ -n "$remote_size" ]; then
    local local_size
    local_size=$(stat -c '%s' "$cached" 2>/dev/null || echo "")

    if [ "$local_size" = "$remote_size" ]; then
      log_info "本地缓存镜像与远程大小一致，跳过下载。"
      return 0
    else
      log_warn "本地与远程大小不一致，删除缓存重新下载。"
      rm -f "$cached"
    fi
  fi

  log_info "下载镜像: $url"
  if ! wget -c -O "$cached" "$url"; then
    log_err "下载失败: $url"; exit 1;
  fi
  log_ok "镜像已下载并缓存: $cached"
}

create_vm_single(){
  check_cmd sudo qm wget pct ip

  show_distro_menu
  read -rp "请选择要创建的发行版 (1-9): " choice
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le 9 ]] || { log_err "无效选择"; exit 1; }

  IFS='|' read -r NAME SUBDIR FILE <<<"${DISTROS[$choice]}"
  [ -z "$FILE" ] && { log_err "该选项尚未配置镜像文件"; exit 1; }

  prompt_vm_params

  download_image "$SUBDIR/$FILE"

  log_info "创建虚拟机 $NAME (VMID: $VMID)"
  sudo qm create "$VMID" \
    --name "$NAME" \
    --cpu host \
    --cores 2 \
    --memory 2048 \
    --sata0 "$STORAGE:20" \
    --scsihw virtio-scsi-pci \
    --agent 1 \
    --net0 virtio,bridge="$VMBR" || {
    log_err "创建虚拟机失败"; exit 1;
  }

  log_info "导入磁盘到存储 $STORAGE"
  sudo qm importdisk "$VMID" "$CACHE_DIR/$FILE" "$STORAGE" --format qcow2 || {
    log_err "导入磁盘失败"; exit 1;
  }

  log_info "配置 SATA 磁盘 (20G) 和 CloudInit 双栈 DHCP"
  disk_name=$(sanitize_disk_name "$VMID-vm-$VMID-disk-0")
  log_info "生成的磁盘名称: $disk_name"

  # 设置 SATA 磁盘，确保磁盘路径符合 LVM 卷的要求
  sudo qm set "$VMID" --sata0 "$STORAGE:$disk_name" || {
    log_err "挂载 SATA 磁盘失败"; exit 1;
  }

  # 调整磁盘大小
  sudo qm resize "$VMID" sata0 20G || {
    log_err "调整磁盘大小失败"; exit 1;
  }

  # 配置 CloudInit 和 DHCP
  sudo qm set "$VMID" --ide2 "$STORAGE:cloudinit" || {
    log_err "配置 cloudinit 失败"; exit 1;
  }
  sudo qm set "$VMID" --ipconfig0 "ip=dhcp,ip6=dhcp" || {
    log_err "配置 IP 为双栈 DHCP 失败"; exit 1;
  }

  # 设置启动磁盘和其他配置
  sudo qm set "$VMID" --boot c --bootdisk sata0
  sudo qm set "$VMID" --serial0 socket --vga serial0
  sudo qm set "$VMID" --description "$NOTES_TEXT"

  log_info "启动虚拟机并等待 IP"
  sudo qm start "$VMID" || { log_err "启动虚拟机失败"; exit 1; }

  wait_and_set_ip_tag "$VMID" 180

  log_ok "虚拟机 $NAME (VMID: $VMID) 创建完成"
}

# -------------------- 主菜单 --------------------
show_main_menu(){
  echo "================ PVE 一体化脚本 ================"
  echo "1) 创建单个云模板"
  echo "2) 创建单个虚拟机"
  echo "3) 扫描并将局域网 IP 写入 VM/LXC tags"
  echo "4) 清除已缓存的镜像文件"
  echo "5) 退出"
  echo "==============================================="
}

main(){
  while true; do
    show_main_menu
    read -rp "请选择操作 (1-5): " opt
    case "$opt" in
      1) create_template_single ;;
      2) create_vm_single ;;
      3) update_ip_tags ;;
      4) clear_cache ;;
      5) echo "退出"; break ;;
      *) echo "无效选择" ;;
    esac
  done
}

main "$@"
