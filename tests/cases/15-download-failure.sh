#!/usr/bin/env bash
# Case: download failure.  wget always fails, so both mirror candidates are
# retried twice and the script aborts before creating the VM.
# expected-v1: PASS
CASE_DESCRIPTION="wget failure: 4 attempts (2 mirrors x 2 tries), exit 1, no VM and no cache file"
CASE_KNOWN_BUGS=""

case_run() {
  scene_set_wget_mode fail

  run_script create --distro 3 --vmid 8000 --yes --wait-ip 1

  assert_rc 1
  assert_output_contains "镜像下载失败"
  assert_output_contains "下载失败或文件无效"
  assert_calls_not_contains "qm create 8000"
  assert_vm_absent 8000
  assert_mock_calls_count "wget " 4
  assert_cache_file_missing debian12.qcow2
  assert_file_missing "$CACHE_DIR_RUN/debian12.qcow2.part"
}

# expected: PASS
