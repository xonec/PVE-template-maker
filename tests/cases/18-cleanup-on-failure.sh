#!/usr/bin/env bash
# Case: creation failure with --yes must clean up the half-created VM:
# qm stop (best effort) and qm destroy --destroy-unreferenced-disks 1 --purge 1.
# The failure is injected by making the mock `qm start` fail.
# expected-v1: PASS
CASE_DESCRIPTION="create fails at qm start with --yes: half-created VM is stopped and destroyed, exit code 1"
CASE_KNOWN_BUGS=""

case_run() {
  printf '1\n' > "$MOCK_STATE/qm_fail_start"

  run_script create --distro 3 --vmid 8000 --yes --wait-ip 1

  assert_rc 1
  assert_output_contains "启动虚拟机 失败"
  assert_output_contains "创建失败，VMID 8000"
  assert_calls_contains "qm destroy 8000 --destroy-unreferenced-disks 1 --purge 1"
  assert_output_contains "已销毁 VMID 8000"
  assert_vm_absent 8000
  assert_calls_not_contains "qm guest cmd 8000"
}

# expected: PASS
