#!/usr/bin/env bash
# Case: single bridge + single storage auto-selection (regression for the old
# v1 bug where the auto-select banner polluted the captured VMBR/STORAGE).
# The interactive menu is driven through stdin with PVE_FORCE_INTERACTIVE=1.
# expected-v1: PASS
CASE_DESCRIPTION="interactive create on a node with one bridge and one storage: both auto-selected, VM created with clean bridge/storage values"
CASE_KNOWN_BUGS=""

case_run() {
  scene_set_bridges vmbr0
  scene_reset_storages
  scene_add_storage local dir 98497780 45793152 "iso,vztmpl,backup,images,rootdir"

  PVE_TEST_FORCE_INTERACTIVE=1 run_script menu <<'EOF'
1
3
8000

2
2
1
Y

0
EOF

  assert_rc 0
  assert_output_contains "虚拟机创建完成"
  # both menus had exactly one option and auto-selected cleanly
  assert_output_contains "自动选择：vmbr0"
  assert_output_contains "自动选择：local"
  assert_output_not_contains "未检测到网桥"
  assert_calls_contains "--net0 virtio,bridge=vmbr0,firewall=0"
  assert_calls_contains "--efidisk0 local:1,efitype=4m,pre-enrolled-keys=0"
  assert_config_value 8000 net0 "virtio,bridge=vmbr0,firewall=0"
  assert_config_value 8000 scsi0 "local:vm-8000-disk-0,size=16G"
  assert_config_value 8000 tags "ip-10.0.0.10"
  assert_vm_status 8000 running
}

# expected: PASS
