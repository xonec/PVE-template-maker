#!/usr/bin/env bash
# Case: cache hit (spec "d" second half).  A valid qcow2 already in PVE_CACHE_DIR
# must be reused: no wget, no re-download, importdisk gets the cached path.
# expected-v1: PASS
CASE_DESCRIPTION="cache hit: existing valid cache file is reused and wget is never called"
CASE_KNOWN_BUGS=""

case_run() {
  scene_cache_put debian12.qcow2

  run_script create --distro 3 --vmid 8000 --yes

  assert_rc 0
  assert_output_contains "命中缓存"
  assert_output_not_contains "下载镜像"
  assert_mock_calls_count "wget " 0
  assert_cache_file debian12.qcow2
  assert_calls_contains "qm importdisk 8000 $CACHE_DIR_RUN/debian12.qcow2 local --format qcow2"
  assert_vm_exists 8000
  assert_config_value 8000 scsi0 "local:vm-8000-disk-0,size=20G"
  assert_config_value 8000 tags "ip-10.0.0.10"
}

# expected: PASS
