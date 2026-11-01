#!/usr/bin/env bash
# Case: illegal interactive input recovery (spec "c" mapped to v2).
# An invalid main-menu choice and an out-of-range distribution number must be
# rejected, then the valid input must continue the flow to a successful create.
# expected-v1: PASS
CASE_DESCRIPTION="interactive menu: invalid choice 9 and distro 0 are rejected, then valid 1/3 continues and creates VM 8000"
CASE_KNOWN_BUGS=""

case_run() {
  scene_set_bridges vmbr0 vmbr1
  scene_reset_storages
  scene_add_storage local dir 98497780 45793152 "iso,vztmpl,backup,images,rootdir"
  scene_add_storage local-lvm lvmthin 16777216 0 "images,rootdir"

  PVE_TEST_FORCE_INTERACTIVE=1 run_script menu <<'EOF'
9

1
0
3
8000

1
1
2
2
1
Y

0
EOF

  assert_rc 0
  assert_output_contains "无效选择"
  assert_output_contains "输入无效"
  assert_output_contains "虚拟机创建完成"
  # no stdout/stderr pollution ended up in the captured variables
  assert_calls_contains "qm create 8000 --name Debian-12"
  assert_calls_contains "--net0 virtio,bridge=vmbr0,firewall=0"
  assert_vm_exists 8000
  assert_config_value 8000 net0 "virtio,bridge=vmbr0,firewall=0"
  assert_config_value 8000 tags "ip-10.0.0.10"
  assert_output_not_contains "未知发行版"
}

# expected: PASS
