#!/usr/bin/env bash
# Case: official Debian Generic distro (absolute https image path).
# Both the tarball URL handling and the download retry loop must work for
# absolute URLs, not only for MIRROR_BASE + relative paths.
# expected-v1: PASS
CASE_DESCRIPTION="create --distro Debian-12-Official-Generic: absolute cloud.debian.org image is downloaded, validated and imported"
CASE_KNOWN_BUGS=""

case_run() {
  run_script create --distro Debian-12-Official-Generic --vmid 8004 --yes --wait-ip 1

  assert_rc 0
  assert_output_contains "镜像下载完成"
  assert_output_contains "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  assert_mock_calls_count "wget " 1
  assert_cache_file debian-12-genericcloud-amd64.qcow2
  assert_file_missing "$CACHE_DIR_RUN/debian-12-genericcloud-amd64.qcow2.part"
  assert_calls_contains "qm importdisk 8004 $CACHE_DIR_RUN/debian-12-genericcloud-amd64.qcow2 local --format qcow2"
  assert_vm_exists 8004
  assert_config_value 8004 ciuser debian
  assert_config_value 8004 name Debian-12-Official-Generic
}

# expected: PASS
