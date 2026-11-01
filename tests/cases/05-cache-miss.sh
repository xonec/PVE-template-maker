#!/usr/bin/env bash
# Case: cache miss (spec "d" first half).  With an empty cache directory the
# script must download the image once, validate it and import the cached file.
# expected-v1: PASS
CASE_DESCRIPTION="cache miss: wget is called once, .part is renamed to the cache file and importdisk uses it"
CASE_KNOWN_BUGS=""

case_run() {
  run_script create --distro 3 --vmid 8000 --yes

  assert_rc 0
  assert_output_contains "下载镜像"
  assert_output_contains "镜像下载完成"
  assert_output_not_contains "命中缓存"
  assert_mock_calls_count "wget " 1
  assert_calls_contains "https://cdn.spiritlhl.net/"
  assert_calls_contains "debian/debian12.qcow2"
  assert_cache_file debian12.qcow2
  assert_file_missing "$CACHE_DIR_RUN/debian12.qcow2.part"
  assert_calls_contains "qm importdisk 8000 $CACHE_DIR_RUN/debian12.qcow2 local --format qcow2"
  assert_vm_exists 8000
  assert_config_value 8000 scsi0 "local:vm-8000-disk-0,size=20G"
}

# expected: PASS
