# tests/ — 无 PVE 环境的 mock 回归测试框架

在普通 macOS / Linux（不需要 Proxmox VE、不需要 root、不联网）上运行
`pve-unified.sh` 的端到端交互与命令回归测试。所有 PVE 命令（`qm`、`pct`、
`pvesh`、`pvesm`、`ip`、`wget`、`curl`、`qemu-img`、`id`、`hostname`、`flock`、
`timeout`、`clear`、`sleep`）都由 `tests/mock/bin/` 里的 bash 脚本模拟：
维护 `$MOCK_STATE` 状态目录、输出贴近真实 PVE 的文本 / JSON，并把每次调用
追加到 `$MOCK_STATE/calls.log`。不会真的创建/启动/销毁任何虚拟机。

当前基线：`pve-unified.sh` v2.0.0，**19/19 case PASS**（281 条断言，约 14s）。

---

## 快速开始

```bash
# 在仓库根目录运行全部场景（默认被测脚本 ../pve-unified.sh）
bash tests/run.sh

# 只看结果摘要
bash tests/run.sh | tail -5

# 单场景 / 过滤 / 调试
bash tests/run.sh --case 09            # 名字包含 "09" 的 case
bash tests/run.sh --case sync --verbose
bash tests/run.sh --keep               # 保留每个 case 的临时目录，便于看 calls.log

# 测别的脚本（框架对任意单文件脚本生效，只要它使用这些 PVE 命令）
bash tests/run.sh --script /path/to/other.sh
bash tests/run.sh --script ../pve-unified.sh --bash /bin/bash
```

其它选项：

| 选项 | 作用 |
| --- | --- |
| `--script PATH` | 被测脚本，默认 `repo-root/pve-unified.sh` |
| `--bash PATH` | 运行被测脚本的 bash，默认 `/bin/bash`（macOS 3.2 / CI 5.x 均可） |
| `--case PATTERN` | 只跑名字包含 PATTERN 的 case，可重复 |
| `--timeout SECONDS` | 单 case 看门狗超时，默认 20s |
| `--verbose` | 打印每条断言 |
| `--keep` | 保留 case 临时目录并打印路径 |
| `--list` | 列出 case 与基线期望结果 |
| `--update-baseline` | 用本次实际结果重写 `tests/baseline.tsv` 和每个 case 头部的 `# expected:` 注释 |
| `-h, --help` | 帮助 |

TAP 输出示例（`--verbose` 时断言也会打印）：

```
TAP version 13
# script: /repo/pve-unified.sh
# runner bash: 3.2.57(1)-release (/bin/bash)
# script bash: GNU bash, version 3.2.57(1)-release (arm64-apple-darwin24)
1..19
ok 1 - 01-create-happy-path
ok 2 - 02-vmid-conflict
...
# Summary: total=19 pass=19 xfail=0 fail=0 xpass=0
# RESULT: PASS
```

退出码：全绿 0；出现 `FAIL` 或 `XPASS` 为 1；参数/环境错误为 2。

---

## 结果语义与基线

`tests/baseline.tsv` 记录每个 case 的期望结果（`PASS` / `EXPECTED_FAIL`）。
每个 case 顶部也有一行 `# expected: ...`。

| 基线 | 实际 | 判定 | 退出码影响 |
| --- | --- | --- | --- |
| PASS | 通过 | `ok` | 否 |
| PASS | 失败 | `not ok`（FAIL） | 是 |
| EXPECTED_FAIL | 失败 | `ok ... # XFAIL (expected failure / known bug)` | 否 |
| EXPECTED_FAIL | 通过 | `not ok ... # XPASS` | 是 |

当脚本修好一个已知 bug，对应 case 会变成 `XPASS`，提示运行
`bash tests/run.sh --update-baseline` 把基线翻转成 `PASS`。反过来，如果
v3 又弄坏某个场景，`PASS` 基线的 case 直接 `FAIL`。

当前基线全部是 `PASS`：历史上 v1 的 known bug 都已被 v2 修复（见下文
“历史 bug 与回归对应”）。

---

## 每个 case 如何隔离

`tests/lib/framework.sh` 为每个 case：

1. `mktemp -d` 创建独立目录：`state/`（mock 状态）、`cache/`（镜像缓存）、
   `home/`、`output.log`、`assertions.log`、`failures.log`；
2. 用 `PATH="$tests/mock/bin:$PATH"` 启动被测脚本，mock 命令优先于真实命令；
3. 注入隔离环境变量：

   | 变量 | 值 |
   | --- | --- |
   | `MOCK_STATE` | `<case>/state`（mock 唯一状态源） |
   | `PVE_CACHE_DIR` | `<case>/cache`（脚本 v2 的镜像缓存目录） |
   | `PVE_LOG_FILE` | `<case>/pve.log` |
   | `PVE_LOCK_FILE` | `<case>/lock/pve.lock` |
   | `PVE_WAIT_INTERVAL` | `1`（等待 IP 的轮询间隔，测试加速） |
   | `PVE_FORCE_INTERACTIVE` | 仅交互 case 设为 `1`（见下） |
   | `TERM=dumb`、`NO_COLOR=1`、`LC_ALL=C` | 关闭颜色/清屏，输出可断言 |

4. `stdin` 由 case 里的 heredoc 提供（`run_script create ... <<'EOF'`）；
5. 后台看门狗（默认 20s）杀掉死循环，`SCRIPT_RC=124`；
6. 断言检查退出码、`calls.log` 调用序列/参数、最终 mock 状态
   （VM/CT config、tags、status、缓存文件）、脚本输出（stdout+stderr）。

交互场景不使用 pty：v2 的 `interactive_stdin()` 在
`PVE_FORCE_INTERACTIVE=1` 时把管道 stdin 当作终端，交互菜单照常 `read`。

断言失败不会中断 case（会继续跑完其余断言再汇总），便于一次看到全部问题。
失败时会打印失败断言、脚本输出尾部、调用日志尾部；`--keep` 保留完整目录。

---

## 场景列表（19 个）

| # | case | 覆盖内容 |
| --- | --- | --- |
| 01 | `01-create-happy-path` | `create --distro 3 --vmid 8000 --yes` 全流程：下载→`qm create` 参数→`importdisk`→`resize`→cloud-init→`start`→agent 取 IP→`ip-10.0.0.10` tag；最终 config 逐项断言 |
| 02 | `02-vmid-conflict` | VMID 被 VM / CT / VM+CT 同 ID 占用时退出 1，且绝不调用 `qm create` |
| 03 | `03-single-bridge-storage-interactive` | 交互菜单 + 单网桥/单存储自动选择，VMBR/STORAGE 不被日志污染（v1 回归） |
| 04 | `04-interactive-invalid-input-recovery` | 交互菜单非法输入（非法主菜单 9、非法发行版 0）后仍能继续创建成功（v1 回归） |
| 05 | `05-cache-miss` | 空缓存：`wget` 调用 1 次、`.part` 落盘后改名、`importdisk` 使用缓存文件 |
| 06 | `06-cache-hit` | 已有合法 qcow2：不调用 `wget`，命中缓存 |
| 07 | `07-template` | `template --secureboot`：`qm template`、不启动、`pre-enrolled-keys=1`、无 IP tag |
| 08 | `08-clone` | 链接克隆与 `--full --storage` 克隆：`qm clone`、描述、启动、IP tag 合并模板已有 tag |
| 09 | `09-sync-tags` | agent / `pct exec` / stopped+unknown 静态 IP 回退、模板跳过、tag 小写 `;` 合并、docker0/tailscale 排除、二次运行幂等 |
| 10 | `10-clear-cache` | 非交互必须 `--yes`（否则退出 1）；`.qcow2/.img` 删除、其它文件保留、目录保留；交互菜单确认删除 |
| 11 | `11-doctor` | `doctor` 环境自检：root、jq、PVE 版本、必需命令、images 存储、网桥、缓存目录 |
| 12 | `12-cli-readonly` | `list-distros` / `version` / `help` 输出内容，未知命令退出码 2 |
| 13 | `13-dry-run-create` | `--dry-run` 只打印计划/命令：不创建 VM、不写缓存、无 create/set/importdisk/start 调用；只读探测允许 |
| 14 | `14-non-root` | `id -u=1000`：退出 1 + root 提示，且不调用任何 qm |
| 15 | `15-download-failure` | 下载失败：2 个镜像源 × 2 次重试后退出 1，不创建 VM |
| 16 | `16-create-options` | 选项矩阵：seabios/pc/cores/memory/disk/static-ip/gateway/nameserver/ciuser/cipassword/onboot/vm-tags(逗号→分号)/no-start/no-description |
| 17 | `17-importdisk-legacy` | 老 `qm importdisk`（无 `--target-disk`）：unused0 发现 → `qm set --scsi0` → resize |
| 18 | `18-cleanup-on-failure` | 创建中途失败 + `--yes`：`qm stop` + `qm destroy --destroy-unreferenced-disks 1 --purge 1` 清理半成品 |
| 19 | `19-official-image` | 官方 Debian Generic 绝对 URL：校验下载/缓存文件名/importdisk/`--ciuser debian` |

场景与 v1→v2 的对应关系：01/03/04 对应原 a/c、05/06 对应 d、09 对应 e、
10 对应 f、14 对应 g；02 对应 b。其余为 v2 新增能力（template/clone/
doctor/dry-run/legacy import/失败清理/官方镜像/选项矩阵）。

---

## 添加一个场景

在 `tests/cases/` 下新建 `NN-name.sh`：

```bash
#!/usr/bin/env bash
# Case: 一句话说明
# expected: PASS
CASE_DESCRIPTION="给 TAP 输出看的一句话"
CASE_KNOWN_BUGS=""          # 已知问题说明（会写进 baseline.tsv，可留空）

case_run() {
  # 1) 构造假 PVE 节点状态（见 tests/lib/scene.sh）
  scene_set_bridges vmbr0 vmbr1
  scene_reset_storages
  scene_add_storage local dir 98497780 45793152 "iso,vztmpl,backup,images,rootdir"
  scene_add_storage local-lvm lvmthin 16777216 0 "images,rootdir"

  # 2) 运行被测脚本（参数原样传给脚本；heredoc 作为 stdin）
  run_script create --distro 3 --vmid 8000 --yes

  # 3) 断言
  assert_rc 0
  assert_output_contains "虚拟机创建完成"
  assert_calls_contains "qm create 8000 --name Debian-12"
  assert_calls_sequence "qm create 8000" "qm importdisk 8000" "qm start 8000"
  assert_config_value 8000 tags "ip-10.0.0.10"
}
```

然后 `bash tests/run.sh --case NN --verbose`，最后
`bash tests/run.sh --update-baseline` 记录基线（新 case 默认期望 `PASS`）。

常用断言（完整列表见 `tests/lib/framework.sh`）：

- `assert_rc` / `assert_equals`
- `assert_output_contains` / `assert_output_not_contains` / `assert_output_matches`
- `assert_calls_contains` / `assert_calls_not_contains` / `assert_mock_calls_count`
  / `assert_calls_sequence`（`sudo` 包装行会被忽略；`mock_calls_count_value`
  返回计数给 case 自己比较）
- `assert_config_value` / `assert_config_has` / `assert_config_lacks`
  （VM：`$MOCK_STATE/vm/<id>/conf`；CT 用 `assert_ct_config_*`）
- `assert_vm_exists` / `assert_vm_absent` / `assert_vm_status` / `assert_ct_*`
- `assert_file_exists` / `assert_file_missing` / `assert_dir_exists` /
  `assert_cache_file` / `assert_file_contains`

状态构造 helper（`tests/lib/scene.sh`）：

`scene_set_uid`、`scene_set_node`、`scene_set_bridges`、`scene_add_storage`、
`scene_add_vm`、`scene_add_ct`、`scene_set_guest_mode`（`normal` / `docker` /
`no-agent`）、`scene_set_guest_ip`、`scene_set_vm_tags`、`scene_set_vm_static_ip`、
`scene_mark_template`、`scene_set_ct_tags`、`scene_set_ct_static_ip`、
`scene_cache_put`、`scene_set_wget_mode`（`ok`/`fail`/`partial`）、
`scene_set_curl_mode`、`scene_set_qemu_img_virtual_size`、
`scene_set_import_target_disk`（1=新 `--target-disk` 路径，0=老 unused0 路径）。

---

## mock 清单与状态布局

`tests/mock/bin/` 中每个命令都是独立的 bash 脚本，共用
`tests/mock/lib/common.sh`（状态读写、`calls.log` 记录、config 解析、
tags 归一化）。mock 不依赖 jq，JSON/表格全部由 `printf` 构造。

`$MOCK_STATE/` 布局：

```
uid                     id -u 返回值（0=root，1000=普通用户）
node                    hostname -s / pvesh 节点名（默认 pve）
calls.log               每次 mock 调用的记录
bridges/<name>/addr     网桥（ip、ip -j、bridge 校验）
storages/<name>/        存储：type、status、total_kib、used_kib、content
vm/<vmid>/              VM：conf（"key: value"）、name、status、mem、
                        bootdisk_bytes、pid、template、guest_mode、guest_ip
ct/<ctid>/              CT：conf、name、status、mem、ip
qm_importdisk_target_disk  1/0 切换 qm importdisk --help 是否包含 --target-disk
qm_fail_start           存在则 mock qm start 失败（失败清理场景注入）
wget_mode / curl_mode   ok / fail / partial
qemu_img_virtual_size   qemu-img 报告的 virtual-size（字节）
pvesm_free              写入后模拟一次成功的 pvesm free（默认按真实行为报错）
```

`calls.log` 每行一次调用：命令名 + 参数。只含 shell 安全字符的参数原样输出
（便于断言 `--net0 virtio,bridge=vmbr0,firewall=0`），含空格/换行的参数用单引号
包裹并把换行显示为 `\n`。`sudo` mock 会额外记录一行 `sudo ...`，断言 helper
统计调用次数时自动忽略 `sudo ` 开头的行。

mock 输出刻意贴近真实 PVE：

- `qm list` 真实表头/列宽；`qm config` 为 `key: value`；guest-agent 输出为
  PVE 风格 pretty JSON（`"key" : value`，3 空格缩进）；
- `pvesh get /version`、`/cluster/resources --type vm --output-format json`、
  `/nodes/<node>/storage --output-format json`、`/cluster/nextid` 等 v2 用到的
  路径返回紧凑 JSON；不带 `--output-format json` 时输出 pretty JSON；
- `pvesm status` 表头 + KiB 数值；`pvesm free <storage>` 按真实行为报
  `unable to parse volume ID`；
- `ip -j link show type bridge` 返回 JSON 数组，`ip link show` 有真实 link 块；
- `qm set --tags` 按 PVE `get_unique_tags` 的行为存成**小写、分号分隔**，
  因此测试里的 tags 断言形如 `prod;web;ip-10.0.0.10`；
- `wget/curl` 只写一个假的 qcow2（前 4 字节 `QFI\xfb`、>1KB，`qemu-img info`
  可解析），不联网。

---

## 历史 bug 与回归对应

v1 的已知问题（原任务里的 EXPECTED_FAIL 场景，v2 已修复，现为 PASS 回归断言）：

1. 单选项菜单把“自动选中”横幅打到 stdout，被 `$(...)` 捕获污染 VMBR/STORAGE
   → `03-single-bridge-storage-interactive`；
2. 菜单非法输入的错误日志写 stdout，污染 DISTRO_NAME，导致后续退出
   → `04-interactive-invalid-input-recovery`；
3. tags 覆盖已有值、且使用 PVE 不允许的 `IP:10.0.0.5` 格式
   → `09-sync-tags` 断言 tag 小写、`;` 合并、保留原有 tag、幂等；
4. `pvesm free <storage>` 用法错误导致空间检测失效（v2 改用 pvesh storage）

开发本框架期间由测试发现、v2 已修复的 bug（均已转化为回归断言）：

5. `acquire_lock` 里 `exec 9>... 2>/dev/null` 永久重定向 shell stderr，导致
   root + flock 环境下所有提示/报错不可见 → 现在 01/09/10 等 case 直接断言
   用户可见输出，回归即 FAIL；
6. `distro_url()` 绝对 URL 分支缺尾换行，`while read` 跳过最后一行，官方
   Debian Generic 镜像永远下载失败 → `19-official-image`；
7. tag 合并按逗号切分，分号形态 `prod;web` 只保留第一个 → `09-sync-tags`。

---

## 保真度与限制

- 不执行任何真实 PVE 命令，不访问网络，不需要 root；`sudo` mock 直接
  `exec "$@"`，root 判定由 `id -u` mock 控制；
- `jq`、`bc`、`od`、`df`、`date`、`dd`、`sha256sum` 等使用系统真实命令；
  **jq 必须安装**（脚本的 JSON 路径依赖它），CI 会安装 jq/bc；
- 只实现了脚本实际用到的命令子集；未知子命令 mock 会报错退出，便于发现
  脚本新增的外部调用；
- 未模拟 `/etc/pve` 文件系统、真实磁盘/网络、guest agent 的完整 JSON schema；
- 不支持 pty；交互路径通过 `PVE_FORCE_INTERACTIVE=1` + 管道 stdin 驱动
  （v2 的 `interactive_stdin()` 明确支持，无需 expect）；
- 镜像下载只写假文件；`--sha256` 只可能做格式校验，不验证真实内容；
- 时间相关逻辑（`date`、创建描述里的时间）不做断言；
- mock 输出以 v2 用到的 PVE 8.x 行为为基准；若 v3 改用其它 API/字段，需要同步
  更新对应的 mock 与断言。

---

## bash 兼容性

- 本机 macOS：`/bin/bash` = **3.2.57(1)**，框架与测试全部在 3.2 下通过
  （当前基线即用 `/bin/bash` 跑出：19/19 PASS）；
- 框架代码只使用 bash 3.2 特性：普通索引数组、`[[ ]]`、`=~`、`local`、
  `printf`、进程替换等；**不需要** bash 4+ 特性（无关联数组/`mapfile`/
  `${var,,}`/`wait -n` 等）；
- 被测脚本默认用 `/bin/bash` 运行；可用 `--bash /opt/homebrew/bin/bash` 或
  `PVE_TEST_BASH` 指定更新的 bash（v2 本身声明兼容 bash >= 3.2）；
- runner 会打印 runner bash 与被测 bash 版本；若本机存在更新版 bash 会提示。

---

## CI

`.github/workflows/ci.yml`（ubuntu-latest）：

1. `apt-get install jq bc shellcheck`；
2. `bash -n` 检查 `pve-unified.sh`、runner、lib、全部 case 与 mock；
3. `shellcheck -S warning` 检查 `tests/`（`tests/.shellcheckrc` 仅关闭因
   “跨文件 source 共享变量”导致的 SC2034 误报）；
4. `bash tests/run.sh --verbose` 跑全部 mock 场景。

CI 在普通 Linux 上同样不需要 PVE：mock 目录会遮蔽真实命令；只有 v2 脚本
会以 root 检查（由 `id` mock 满足）。
