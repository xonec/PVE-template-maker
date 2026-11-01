#!/usr/bin/env bash
# Case: non-root invocation (spec "g").  id -u=1000 must abort with a clear
# message before any PVE command is touched.
# expected-v1: PASS
CASE_DESCRIPTION="id -u=1000: exit 1 with a root hint and no qm calls at all"
CASE_KNOWN_BUGS=""

case_run() {
  scene_set_uid 1000

  run_script create --distro 3 --vmid 8000 --yes

  assert_rc 1
  assert_output_contains "请以 root 运行"
  assert_output_not_contains "虚拟机创建完成"
  assert_calls_not_contains "qm create 8000"
  assert_calls_not_contains "qm list"
  assert_vm_absent 8000
}

# expected: PASS
