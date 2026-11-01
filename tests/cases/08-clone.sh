#!/usr/bin/env bash
# Case: clone from template (v2 "clone" command), linked and --full clones.
# expected-v1: PASS
CASE_DESCRIPTION="clone --template 9000: qm clone, description, start and IP tag; --full/--storage variant"
CASE_KNOWN_BUGS=""

case_run() {
  scene_add_vm 9000 tpl-debian stopped "tpl"
  scene_mark_template 9000

  run_script clone --template 9000 --vmid 8001 --name web-01 --yes
  assert_rc 0
  assert_output_contains "克隆完成"
  assert_output_contains "来源模板：VMID 9000"
  assert_calls_contains "qm clone 9000 8001 --name web-01"
  assert_calls_not_contains "qm clone 9000 8001 --name web-01 --full"
  assert_vm_exists 8001
  assert_vm_status 8001 running
  assert_config_value 8001 name web-01
  assert_config_has 8001 "description:"
  assert_config_value 8001 tags "tpl;ip-10.0.0.10"

  run_script clone --template 9000 --vmid 8002 --name web-02 --full --storage local --yes
  assert_rc 0
  assert_calls_contains "qm clone 9000 8002 --name web-02 --full --storage local"
  assert_vm_exists 8002
  assert_config_value 8002 name web-02
  assert_config_value 8002 tags "tpl;ip-10.0.0.10"
}

# expected: PASS
