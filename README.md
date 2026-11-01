# PVE-template-maker

基于 Proxmox VE 的一组辅助脚本：在节点上快速创建**云模板 / 虚拟机**、**从模板克隆**，并把 VM/LXC 的局域网 IP 同步到 **tags**（`ip-10.0.0.5`），方便在 PVE WebUI 里直接看到每台机器的地址。

当前主脚本是单文件脚本 `pve-unified.sh`，设计目标：

- **单文件**：支持 `bash <(curl ...)` 直接运行，不依赖 clone 仓库；
- **安全可预期**：所有破坏性操作都要确认，支持 `--dry-run` 预演；
- **可自动化**：交互菜单 + 完整子命令/参数两套入口；
- **可测试**：仓库自带无 PVE 依赖的 mock 测试框架（`tests/`）与 CI。

---

## 1. 快速开始

在 **Proxmox VE 节点** 上以 root 运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xonec/PVE-template-maker/refs/heads/main/pve-unified.sh)
```

或：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/xonec/PVE-template-maker/refs/heads/main/pve-unified.sh)
```

无参数且处于交互终端时显示菜单：

```
  1) 创建虚拟机（q35+UEFI+QEMU Agent，启动并写 IP 标签）
  2) 创建云模板（不启动，之后可克隆）
  3) 从模板克隆虚拟机
  4) 同步 VM/LXC 的 IP 标签（保留其他 tags）
  5) 清理镜像缓存
  6) 环境自检
  0) 退出
```

> ⚠️ 脚本会修改 VM/CT 配置（创建、启动、写 tags、销毁半成品）。建议先看 `--help`，必要时用 `--dry-run` 预演。

---

## 2. 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Proxmox VE 7.x / 8.x / 9.x（节点 root shell）；已在 PVE 9.1.1 + dir 存储上实测通过 |
| shell | bash >= 3.2（PVE 自带 bash 5.x） |
| 必需命令 | `qm`、`pct`、`pvesm`、`wget` 或 `curl` |
| 推荐命令 | `pvesh`、`jq`、`qemu-img`、`flock`、`timeout`、`sha256sum` |
| 存储 | 目标存储需支持 `images` 内容（如 `local`、`local-lvm`、NFS、Ceph 等） |
| 网络 | 至少一个 Linux 网桥（`vmbr0` 等） |
| Guest | 创建普通 VM 并要求写 IP 标签时，镜像内需有 `qemu-guest-agent` |

缺少推荐命令不会阻止运行，但会退化为兼容解析路径；`doctor` 命令会逐项检查。

---

## 3. 子命令与参数

```
pve-unified.sh [命令] [选项]
```

### 3.1 命令

| 命令 | 说明 |
| --- | --- |
| `create` | 创建虚拟机，启动后等待 IP 并写入 tags（默认命令，仅当传了创建参数时） |
| `template` | 创建云模板：配置与 create 相同，但不启动、不写 IP，最后 `qm template` |
| `clone` | 从已有模板克隆虚拟机（默认链接克隆，`--full` 完整克隆） |
| `sync-tags` | 扫描所有 VM/LXC，把局域网 IPv4 写入 tags，**保留已有 tags** |
| `clear-cache` | 清理本地镜像缓存（只删除 `*.qcow2/*.img/*.part`） |
| `doctor` | 环境自检（权限、命令、存储、网桥、缓存/日志可写性等） |
| `list-distros` | 列出内置发行版与镜像地址 |
| `menu` | 交互菜单 |
| `help` / `version` | 帮助 / 版本 |

不带命令且 stdin 是终端时等价于 `menu`；非交互环境请显式指定命令，否则会报错退出。

### 3.2 通用选项

| 选项 | 说明 |
| --- | --- |
| `-y, --yes` | 非交互确认：不再询问确认，半成品 VM 自动销毁 |
| `-n, --dry-run` | 只打印将执行的命令，不实际修改系统 |
| `--no-color` | 禁用颜色（也支持环境变量 `NO_COLOR=1`） |
| `-v, --verbose` | 输出调试信息 |
| `--log FILE` | 日志文件，默认 `/var/log/pve-unified.log`，传空字符串禁用 |
| `--cache-dir DIR` | 镜像缓存目录，默认 `/var/cache/pve-unified-images` |
| `--exclude IDS` | 仅 `sync-tags`：跳过指定 VMID/CTID（逗号分隔），保护现有生产 VM |

### 3.3 创建 / 模板选项

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `--distro NAME\|ID` | — | 发行版名称或序号（见 `list-distros`）；非交互必填 |
| `--vmid ID` | 自动分配 | 指定 VMID（会同时检查 VM 与 LXC 占用） |
| `--name NAME` | 发行版名 | 1–63 位，字母/数字/`.`/`_`/`-`，字母或数字开头 |
| `--bridge BR` | 第一个网桥 | 网络桥接 |
| `--storage ST` | 第一个 images 存储 | 系统盘 / cloud-init 存储 |
| `--cores N` | 2 | CPU 核心数 |
| `--memory SIZE` | 2G | 支持 `2G` / `2048M` / `2048` |
| `--disk SIZE` | 20G | 支持 `20G` / `20`（GB），不能小于镜像原始大小 |
| `--bios ovmf\|seabios` | ovmf | UEFI / Legacy 固件 |
| `--machine q35\|pc` | q35 | 机型 |
| `--secureboot` | 关闭 | 仅 OVMF：`pre-enrolled-keys=1` 启用 Secure Boot |
| `--ciuser USER` | root / debian | Cloud-Init 用户（官方 Debian 镜像默认 `debian`） |
| `--cipassword PASS` | `oneclickvirt` | Cloud-Init 密码；指定 `--sshkeys` 时默认不设密码 |
| `--sshkeys FILE` | — | SSH 公钥文件（生产环境推荐，避免密码） |
| `--static-ip CIDR` | DHCP | 静态 IP，如 `10.0.0.50/24` |
| `--gateway IP` | — | 静态 IP 网关 |
| `--nameserver DNS` | — | 自定义 DNS（逗号分隔） |
| `--no-ipv6` | 开启 IPv6 DHCP | 关闭 `ip6=dhcp` |
| `--import-format F` | auto | `auto/raw/qcow2`；auto 时目录型存储用 qcow2，块存储交给 PVE 决定 |
| `--sha256 HASH` | — | 校验下载镜像的 SHA256（命中缓存时也会校验） |
| `--subnet REGEX` | — | 只采纳匹配该正则的 IPv4，如 `--subnet '^10\.'` |
| `--iface-exclude RE` | 见下 | 忽略匹配的网卡名（默认忽略 `lo/docker*/veth*/virbr*/tailscale*/zt*/wg*/tun*/tap*` 等） |
| `--tag-prefix PREFIX` | `ip-` | IP 标签前缀；**PVE tag 不允许冒号**，不要用 `IP:` |
| `--vm-tags TAGS` | — | 创建时附加 tags（逗号分隔，会先做合法性校验） |
| `--no-tags` | — | 创建后不写 IP 标签 |
| `--description TEXT` | 内置说明 | 覆盖 VM 描述 |
| `--no-description` | — | 不写描述 |
| `--onboot` | 关闭 | 设置开机自启 |
| `--no-start` | — | 创建/克隆后不启动 |
| `--wait-ip SECONDS` | 180（模板为 0） | 等待 IP 秒数，`0` 表示不等待 |
| `--skip-space-check` | — | 跳过缓存/存储空间提示 |

### 3.4 克隆选项

| 选项 | 说明 |
| --- | --- |
| `--template ID` | 模板 VMID；非交互必填 |
| `--vmid ID` / `--name NAME` | 新 VM 的 VMID / 名称 |
| `--full` | 完整克隆（默认链接克隆） |
| `--storage ST` | 完整克隆的目标存储 |
| `--no-start` / `--wait-ip N` | 同上 |

### 3.5 示例

```bash
# 交互菜单
./pve-unified.sh

# 非交互创建虚拟机（Debian 12，VMID 8000，等待并写 IP 标签）
./pve-unified.sh create --yes --distro Debian-12 --vmid 8000

# 指定资源与静态 IP
./pve-unified.sh create --yes --distro 1 --vmid 8001 --memory 4G --disk 40G \
  --static-ip 10.0.0.50/24 --gateway 10.0.0.1

# 创建云模板（不启动），再克隆
./pve-unified.sh template --yes --distro Debian-12 --vmid 9000
./pve-unified.sh clone --yes --template 9000 --vmid 8002 --name web-02 --wait-ip 120

# 同步所有 VM/LXC 的 IP 到 tags
./pve-unified.sh sync-tags

# 预演（不改系统）
./pve-unified.sh create --dry-run --distro Debian-12 --vmid 8003

# 清理缓存 / 环境自检
./pve-unified.sh clear-cache --yes
./pve-unified.sh doctor
```

---

## 4. 镜像下载与缓存

- 内置镜像表（`list-distros` 可查）：

| 序号 | 名称 | 来源 |
| --- | --- | --- |
| 1 | Debian-11 | 第三方优化镜像（spiritlhl CDN） |
| 2 | Debian-11-Official-Generic | Debian 官方 cloud |
| 3 | Debian-12 | 第三方优化镜像 |
| 4 | Debian-12-Official-Generic | Debian 官方 cloud |
| 5 | Debian-13 | 第三方优化镜像 |
| 6 | Debian-13-Official-Generic | Debian 官方 cloud |
| 7–10 | Ubuntu-18.04 / 20.04 / 22.04 / 24.04 | 第三方优化镜像 |
| 11–12 | CentOS-8 / CentOS-9 | 第三方优化镜像 |

- 下载顺序：缓存命中 → 否则按镜像前缀列表依次尝试（默认先 spiritlhl CDN，再 GitHub Releases 直链），每个源最多重试 2 次。
- 缓存目录默认 `/var/cache/pve-unified-images`，可用 `--cache-dir` 或 `PVE_CACHE_DIR` 覆盖。
- 下载写入 `*.part`，完成后做 **qcow2 魔数 + qemu-img 校验**，通过后才原子改名为正式缓存文件，避免半截文件被当缓存使用。
- 可选 `--sha256` 校验（需要 `sha256sum`/`shasum`）。
- `clear-cache` 只删除镜像缓存文件，保留目录和其他文件。

自定义镜像源：

```bash
# 单个前缀（兼容旧变量）
MIRROR_BASE="https://my.mirror/download/" ./pve-unified.sh create ...
# 多个前缀（空格分隔，按顺序尝试）
PVE_MIRROR_BASES="https://a/ https://b/" ./pve-unified.sh create ...
# 官方 Debian 基础地址
PVE_DEBIAN_BASE="https://cloud.debian.org/images/cloud/" ...
```

---

## 5. IP 标签规则（重要）

### 5.1 格式

标签格式为 **`ip-10.0.0.5`**，前缀可用 `--tag-prefix` 修改。

> **不要使用 `IP:10.0.0.5`**：Proxmox VE 的 tag 只允许字母、数字、`_`、`-`、`.`、`+`，且必须以字母/数字/`_` 开头（源码见 `pve-common/src/PVE/JSONSchema.pm` 的 `PVE_TAG_RE`）。冒号是非法的，v1 脚本用 `IP:` 写入会被 PVE 拒绝且错误被静默吞掉——这是 v2 修复的关键问题之一。

### 5.2 合并与幂等

- 每次写入都会**保留已有 tags**（如 `prod;web`），只替换旧的 `ip-` 前缀标签，并在无变化时跳过写入；
- PVE 后端会**把 tags 小写化**并用 `;` 重拼保存（`get_unique_tags`），因此脚本读取时同时兼容 `,` 与 `;`，写入时统一使用小写 + 分号，保证重复执行幂等；
- 同一对象的 tag 数量/总长度受 PVE 配置值限制，脚本会做字符与长度校验；
- PVE 默认还会对 tags **排序**，所以脚本按“标签集合”判断是否需要更新（与顺序无关），重复执行不会产生多余写入。

### 5.3 IP 选择顺序

1. **运行中的 VM**：通过 `qm guest cmd <id> network-get-interfaces` 获取；
2. **运行中的 LXC**：通过 `pct exec <id> -- ip -4 -o addr show scope global` 获取（失败时回退 `hostname -I`）；
3. **已停止的 VM/LXC**：从配置中的静态 `ip=x.x.x.x/prefix` 回退（`ipconfigN` / `netN`）；
4. 排除回环、链路本地（169.254/16）、`0.0.0.0` 以及 `--iface-exclude` 匹配的网卡（docker0、veth、tailscale 等）；
5. 设置 `--subnet '^10\.'` 可只采纳内网地址；取第一个匹配项。

> VM 内未安装/未运行 `qemu-guest-agent` 时无法获取 IP，会给出警告并跳过；可稍后重跑 `sync-tags`。

批量同步时如需保护现有生产 VM/CT（不写入任何 IP 标签），使用：

```bash
./pve-unified.sh sync-tags --exclude 100,101,200
```

---

## 6. 创建流程说明

1. 预检：root、命令、节点、存储（images 内容 + 剩余空间）、网桥、VMID 是否被 VM/LXC 占用、镜像缓存空间；
2. 确认参数（交互模式）或直接执行（`--yes`）；
3. 下载/校验镜像到缓存；
4. `qm create`：q35、OVMF（可选 Secure Boot）、virtio-scsi、virtio 网卡、QEMU Agent、serial 控制台；
5. `qm importdisk` 导入系统盘：
   - PVE ≥ 8.2 自动检测 `--target-disk` 支持，直接导入到 `scsi0`；
   - 旧版本回退 `unused0` → `qm set --scsi0` 流程（目录存储的卷名含 `/` 和 `.` 也能正确解析）；
   - 目录型存储自动选择 `qcow2` 格式，块存储交给 PVE 决定；
6. `qm resize` 扩容到 `--disk` 指定大小（不会缩容；镜像比目标大时保留镜像大小并警告）；
7. 一次性写入 cloud-init（`ide2`、`ipconfig0`、`ciuser`、`cipassword`/`sshkeys`、`nameserver`、启动项、描述、附加 tags）；
8. 普通 VM：`qm start` → 等待 IP → 合并写入 `ip-xxx` 标签；模板：`qm template`，不启动。

失败时：

- 交互模式会询问是否销毁半成品 VM（默认保留，并打印手动清理命令）；
- `--yes` 非交互模式自动销毁半成品（`qm stop` + `qm destroy --destroy-unreferenced-disks 1 --purge 1`）；
- 脚本始终会先检查「这个 VM 是否由本次运行创建」，不会误删已有 VM/容器。

---

## 7. BIOS / Secure Boot 兼容性

- 默认 `ovmf + efitype=4m + pre-enrolled-keys=0`：UEFI 启动但**不启用 Secure Boot**，对第三方云镜像兼容性最好；
- 需要 Secure Boot 时加 `--secureboot`（`pre-enrolled-keys=1`）；官方 Ubuntu/Debian 等带签名引导的镜像通常可用，第三方精简镜像可能无法引导；
- 如果镜像只支持 Legacy BIOS，使用 `--bios seabios`（此时不会创建 efidisk）；
- UEFI 启动失败常见原因：镜像本身不支持 UEFI、Secure Boot 未签名引导、efidisk 丢失。可先用 `--bios seabios` 验证镜像。

默认账号：

- 官方 Debian Generic Cloud：`debian / oneclickvirt`（debian 用户有免密 sudo）；
- 第三方镜像与其余系统：`root / oneclickvirt`；
- 建议生产环境使用 `--sshkeys`，或首次登录后立即修改密码。

---

## 8. 从 v1 迁移

v2 对 v1（单文件 703 行版本）做了一轮重构，行为变化：

1. **菜单编号**：`1` 创建虚拟机、`2` 创建云模板、`3` 克隆、`4` 同步 tags、`5` 清理缓存、`6` 自检、`0` 退出（README 之前描述的“模板/虚拟机”编号已与实际不符，现已对齐）；
2. **标签格式**：由非法的 `IP:1.2.3.4` 改为合法的 `ip-1.2.3.4`，并且会**保留已有 tags**（v1 会覆盖）；
3. **非交互支持**：新增 `create/template/clone/sync-tags/clear-cache/doctor` 子命令与完整参数，可直接放进自动化脚本；
4. **修复**：单网桥/单存储自动选择污染返回值、输错一次即失败、`pvesm free` 误用、目录存储磁盘名校验失败、缓存半截文件、VMID 冲突漏查 LXC、Ctrl-C 误删半成品、多处静默失败等；
5. **去依赖**：不再强制 `sudo`/`bc`；`jq` 可选（缺失时走兼容解析）；
6. **安全**：破坏性操作显式确认；新增 `--dry-run`；锁文件防止并发执行。

> 若你从旧版本升级并曾手动改过脚本内的 `MIRROR_BASE` / `CACHE_DIR`，v2 仍兼容这两个环境变量；新的推荐变量是 `PVE_MIRROR_BASES` / `PVE_CACHE_DIR`。

---

## 9. 常见问题

**Q：创建完虚拟机拿不到 IP？**
检查镜像内是否安装并运行 `qemu-guest-agent`；网卡是否 DHCP；可先 `qm guest cmd <vmid> network-get-interfaces` 手动验证，再运行 `sync-tags`。
注意：官方 Debian/Ubuntu cloud 镜像不一定预装 `qemu-guest-agent`（实测部分官方镜像没有运行 agent），此时：
- 使用 `--static-ip` 创建（脚本会直接按配置写 `ip-` 标签，不依赖 agent）；
- 或跑 `sync-tags`（会回退读取 `ipconfigN`/`netN` 静态配置）；
- 或在镜像内安装并启用 agent 后重新同步。

**Q：`sync-tags` 会不会改动现有生产 VM 的标签？**
默认会为所有能取到 IP 的 VM/CT 合并写入 `ip-` 标签（保留其他 tags）。如不希望改动某些对象，用 `sync-tags --exclude 100,101` 跳过它们。

**Q：`qm importdisk` 报存储不支持？**
目标存储需要 `images` 内容；`--storage` 选择错误时用 `doctor` 查看可用存储。目录存储与块存储的格式选择已自动处理。

**Q：UEFI 启动黑屏/进不去系统？**
先试 `--bios seabios`；或确认镜像支持 UEFI；Secure Boot 场景用 `--secureboot` 并要求镜像带签名引导。

**Q：存储空间检查误报？**
`--skip-space-check` 可跳过；空间值来自 PVE 存储 API，短暂误差属于正常。

**Q：如何完全非交互地清理缓存？**
`./pve-unified.sh clear-cache --yes`。

**Q：脚本安全吗？会误删什么？**
只会删除：本次创建失败且已确认的 VM、`clear-cache` 确认的缓存文件。已有 VM/容器不会被删除；建议先 `--dry-run`。

**Q：日志在哪？锁在哪？**
日志 `/var/log/pve-unified.log`（`--log` 可改），锁 `/run/lock/pve-unified.lock`（`PVE_LOCK_FILE` 可改）。

---

## 10. 测试与 CI

仓库内置不依赖 PVE 的 mock 测试框架：

```bash
cd tests
bash run.sh                 # 运行全部场景（默认测试 ../pve-unified.sh）
bash run.sh --case create   # 只跑指定场景
bash run.sh --verbose
```

CI（`.github/workflows/`）在 ubuntu 上执行：

- `bash -n` 语法检查；
- `shellcheck -S warning`（当前 0 warning）；
- `tests/run.sh` 全部场景。

### 真机验证（PVE 9.1.1，单节点，dir 存储）

除 mock 单测外，v2 还在真实 Proxmox VE 9.1.1 节点 (dir 存储 `local`、单网桥 `vmbr0`) 上做过完整回归：

- 创建：第三方 Debian 12 / 官方 Debian 12 Generic Cloud 下载、qcow2 校验、`--target-disk` 直接挂载 `scsi0`、扩容、cloud-init 配置、启动；
- 模板：`qm template`；链接克隆（dir/qcow2）与完整克隆；
- `sync-tags`：guest agent 实时 IP、静态 `ipconfig0` 回退、模板跳过、tags 小写/分号合并、重复执行幂等、`--exclude` 保护现有 VM；
- 静态 IP 创建时直接按配置写标签、`--secureboot` 模板（`pre-enrolled-keys=1`）、seabios/pc/no-start/flags 选项矩阵；
- 失败清理：故意使用不存在的网桥导致 `qm start` 失败，`--yes` 场景自动 `stop + destroy` 半成品 VM；
- 锁：VM 启动后（QEMU 进程存在）脚本退出锁即释放，连续调用不会误报“另一个实例在运行”；
- 现有生产 VM 配置与 tags 在测试前后保持一致，用户镜像缓存未被清理（测试使用独立缓存目录）。

> 说明：测试环境的官方 Debian cloud 镜像未运行 `qemu-guest-agent`，因此该场景的 IP 标签通过 `--static-ip`/`ipconfig0` 回退验证；第三方镜像场景验证了 agent 实时 IP 路径。

---

## 11. 变更日志

### v2.0.0

- 重写为可测试、可自动化的单文件脚本（保留单文件 curl 运行方式）。
- 修复：单选项菜单污染返回值；日志输出污染命令替换（输错一次即失败）；`pvesm free` 误用导致空间检查失效；目录存储 `unusedN` 卷名校验失败；`IP:` 非法 tag 与覆盖已有 tags；VMID 冲突漏查 LXC；缓存半截文件被复用；Ctrl-C/EXIT 误销毁 VM；README 与菜单漂移。
- 新增：`template` / `clone` / `doctor` 子命令；完整非交互参数；`--dry-run`；`--static-ip/--gateway/--sshkeys`；镜像多源回退 + qcow2 校验 + 原子写入；`--target-disk` 自动检测；VM+CT 统一 VMID 检查；锁文件；日志文件；`ip-` 标签合并与幂等；stopped VM/CT 静态 IP 回退。
- 依赖：不再要求 `sudo`/`bc`，`jq` 可选。

### v1.x

- 历史版本：交互式创建 VM / 模板、同步 IP 标签、清理缓存（详见 git 历史）。
