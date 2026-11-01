#!/usr/bin/env bash
# Case: --dry-run create must not mutate anything.
# Read-only probes (qm importdisk --help, qm guest cmd, qemu-img info) are
# allowed; qm create/set/importdisk/start and the cache download are not.
# expected-v1: PASS
CASE_DESCRIPTION="create --dry-run: prints the plan and commands but creates no VM, no cache file and no mutating qm calls"
CASE_KNOWN_BUGS=""

case_run() {
  run_script create --distro 3 --vmid 8000 --yes --dry-run --wait-ip 1

  assert_rc 0
  assert_output_contains "[dry-run]"
  assert_output_contains "以上命令仅为打印，未实际执行"
  assert_output_contains "创建参数确认"

  assert_vm_absent 8000
  assert_file_missing "$MOCK_STATE/vm/8000/conf"
  assert_cache_file_missing debian12.qcow2
  assert_calls_not_contains "qm create 8000"
  assert_calls_not_contains "qm importdisk 8000"
  assert_calls_not_contains "qm set 8000"
  assert_calls_not_contains "qm start 8000"
  assert_calls_not_contains "wget "

  # read-only probes are expected and prove the dry-run path was exercised
  assert_calls_contains "qm importdisk --help"
  assert_calls_contains "qm guest cmd 8000 network-get-interfaces"
  assert_calls_contains "qemu-img info --output=json"
}

# expected: PASS
