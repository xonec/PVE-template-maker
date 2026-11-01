#!/usr/bin/env bash
# Case: VMID conflict detection (spec "b" mapped to v2 CLI).
# A VM, a container and a VM+CT pair occupying ids must all be rejected, and
# the existing objects must stay untouched.
# expected-v1: PASS
CASE_DESCRIPTION="create with an already used VMID (VM / CT / same id on both) must exit 1 without calling qm create"
CASE_KNOWN_BUGS=""

case_run() {
  scene_add_vm 8000 Debian-11 stopped "keepme"
  scene_add_ct 8001 ct-existing running "ct-tag"
  scene_add_vm 8002 vm-both stopped ""
  scene_add_ct 8002 ct-both stopped ""

  run_script create --distro 3 --vmid 8000 --yes
  assert_rc 1
  assert_output_contains "VMID 8000 已被 VM/容器占用"
  assert_calls_not_contains "qm create 8000"
  assert_config_value 8000 name Debian-11
  assert_config_has 8000 "tags: keepme"

  run_script create --distro 3 --vmid 8001 --yes
  assert_rc 1
  assert_output_contains "VMID 8001 已被 VM/容器占用"
  assert_calls_not_contains "qm create 8001"
  assert_ct_config_value 8001 hostname ct-existing

  # same id present on both a VM and a CT
  run_script create --distro 3 --vmid 8002 --yes
  assert_rc 1
  assert_output_contains "VMID 8002 已被 VM/容器占用"
  assert_calls_not_contains "qm create 8002"
}

# expected: PASS
