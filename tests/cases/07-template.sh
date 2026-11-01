#!/usr/bin/env bash
# Case: template creation (v2 "template" command).
# The VM must be converted with `qm template`, never started, and use
# pre-enrolled-keys=1 when --secureboot is requested.
# expected-v1: PASS
CASE_DESCRIPTION="template --secureboot: importdisk + configure + qm template, no start, efidisk pre-enrolled-keys=1"
CASE_KNOWN_BUGS=""

case_run() {
  run_script template --distro 3 --vmid 9000 --yes --secureboot

  assert_rc 0
  assert_output_contains "云模板创建完成"
  assert_calls_contains "qm create 9000 --name Debian-12"
  assert_calls_contains "--efidisk0 local:1,efitype=4m,pre-enrolled-keys=1"
  assert_calls_contains "qm template 9000"
  assert_calls_not_contains "qm start 9000"
  assert_calls_not_contains "qm guest cmd 9000"

  assert_vm_exists 9000
  assert_vm_status 9000 stopped
  assert_config_value 9000 template 1
  assert_config_value 9000 scsi0 "local:vm-9000-disk-0,size=20G"
  assert_config_value 9000 ide2 "local:cloudinit"
  assert_file_exists "$MOCK_STATE/vm/9000/template"
  # template mode does not write IP tags
  assert_config_lacks 9000 "tags:"
}

# expected: PASS
