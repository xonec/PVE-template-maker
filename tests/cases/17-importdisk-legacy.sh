#!/usr/bin/env bash
# Case: legacy importdisk path (no --target-disk support in `qm importdisk
# --help`): the script must import to unused0, discover the unused volume via
# `qm config`, then attach it with `qm set --scsi0` and resize it.
# expected-v1: PASS
CASE_DESCRIPTION="legacy qm importdisk (no --target-disk): unused0 discovery + qm set --scsi0 + resize"
CASE_KNOWN_BUGS=""

case_run() {
  scene_set_import_target_disk 0

  run_script create --distro 3 --vmid 8000 --yes --wait-ip 1

  assert_rc 0
  assert_calls_not_contains "--target-disk"
  assert_calls_contains "qm importdisk --help"
  assert_calls_contains "qm importdisk 8000 $CACHE_DIR_RUN/debian12.qcow2 local --format qcow2"
  assert_calls_contains "qm set 8000 --scsi0 local:vm-8000-disk-0"
  assert_calls_contains "qm resize 8000 scsi0 20G"
  assert_config_value 8000 scsi0 "local:vm-8000-disk-0,size=20G"
  assert_config_lacks 8000 "unused0:"
  assert_vm_status 8000 running
}

# expected: PASS
