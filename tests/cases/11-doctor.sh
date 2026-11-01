#!/usr/bin/env bash
# Case: doctor self-check (v2 "doctor" command).
# expected-v1: PASS
CASE_DESCRIPTION="doctor: root, jq, PVE version, required commands, images storage and bridge are all detected"
CASE_KNOWN_BUGS=""

case_run() {
  run_script doctor

  assert_rc 0
  assert_output_contains "环境自检"
  assert_output_contains "以 root 运行"
  assert_output_contains "jq 可用"
  assert_output_contains "PVE 版本：8.2"
  assert_output_contains "命令存在：qm"
  assert_output_contains "命令存在：pct"
  assert_output_contains "命令存在：pvesm"
  assert_output_contains "支持 images 的存储：local"
  assert_output_contains "网桥：vmbr0"
  assert_output_contains "缓存目录可写：$CACHE_DIR_RUN"
  assert_output_contains "自检完成：0 项失败"
}

# expected: PASS
