#!/usr/bin/env bash
# Case: v2 non-interactive create happy path (spec "a" mapped to v2 CLI).
# Covers download -> qm create -> importdisk -> resize -> cloud-init ->
# start -> guest-agent IP -> ip-<addr> tag, and the final VM config.
# expected-v1: PASS
CASE_DESCRIPTION="create --distro 3 --vmid 8000 --yes: full create flow with download, import, resize, cloud-init, start and IP tag"
CASE_KNOWN_BUGS=""

case_run() {
  run_script create --distro 3 --vmid 8000 --yes

  assert_rc 0
  assert_output_contains "虚拟机创建完成"
  assert_output_contains "IP：10.0.0.10"
  assert_output_contains "获取到 IP：10.0.0.10"

  # qm create arguments
  assert_calls_contains "qm create 8000 --name Debian-12"
  assert_calls_contains "--cpu host"
  assert_calls_contains "--cores 2"
  assert_calls_contains "--memory 2048"
  assert_calls_contains "--balloon 2048"
  assert_calls_contains "--machine q35"
  assert_calls_contains "--bios ovmf"
  assert_calls_contains "--efidisk0 local:1,efitype=4m,pre-enrolled-keys=0"
  assert_calls_contains "--scsihw virtio-scsi-pci"
  assert_calls_contains "--agent 1,fstrim_cloned_disks=1"
  assert_calls_contains "--net0 virtio,bridge=vmbr0,firewall=0"
  assert_calls_contains "--ostype l26"

  # download -> create -> import -> resize -> configure -> start -> tag
  assert_mock_calls_count "wget " 1
  assert_cache_file debian12.qcow2
  assert_file_missing "$CACHE_DIR_RUN/debian12.qcow2.part"
  assert_calls_contains "qm importdisk 8000 $CACHE_DIR_RUN/debian12.qcow2 local --format qcow2 --target-disk scsi0"
  assert_calls_sequence \
    "wget -q -c -O" \
    "qm create 8000" \
    "qm importdisk --help" \
    "qm importdisk 8000" \
    "qm resize 8000 scsi0 20G" \
    "qm set 8000 --ide2" \
    "qm start 8000" \
    "qm guest cmd 8000 network-get-interfaces" \
    "qm set 8000 --tags"

  # final qm config
  assert_vm_exists 8000
  assert_vm_status 8000 running
  assert_config_value 8000 name Debian-12
  assert_config_value 8000 cpu host
  assert_config_value 8000 cores 2
  assert_config_value 8000 memory 2048
  assert_config_value 8000 balloon 2048
  assert_config_value 8000 machine q35
  assert_config_value 8000 bios ovmf
  assert_config_value 8000 efidisk0 "local:1,efitype=4m,pre-enrolled-keys=0"
  assert_config_value 8000 scsihw virtio-scsi-pci
  assert_config_value 8000 agent "1,fstrim_cloned_disks=1"
  assert_config_value 8000 net0 "virtio,bridge=vmbr0,firewall=0"
  assert_config_value 8000 ostype l26
  assert_config_value 8000 serial0 socket
  assert_config_value 8000 vga serial0
  assert_config_value 8000 scsi0 "local:vm-8000-disk-0,size=20G"
  assert_config_value 8000 ide2 "local:cloudinit"
  assert_config_value 8000 ipconfig0 "ip=dhcp,ip6=dhcp"
  assert_config_value 8000 boot "order=scsi0"
  assert_config_value 8000 ciuser root
  assert_config_value 8000 cipassword oneclickvirt
  assert_config_value 8000 tags "ip-10.0.0.10"
  assert_config_lacks 8000 "unused0:"
  assert_config_has 8000 "description:"

  # PVE tag format: no colon allowed, prefix must be ip-
  assert_config_lacks 8000 "tags: IP:"

  # structured log file is written (PVE_LOG_FILE points into the case dir)
  assert_file_exists "$CASE_DIR/pve.log"
  assert_file_contains "$CASE_DIR/pve.log" "[INFO]"
}

# expected: PASS
