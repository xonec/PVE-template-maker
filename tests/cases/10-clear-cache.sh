#!/usr/bin/env bash
# Case: clear-cache (spec "f" mapped to v2).
#   * non-interactive without --yes must refuse (exit 1) and keep the files
#   * non-interactive --yes removes *.qcow2/*.img/*.part, keeps other files and
#     the directory itself
#   * interactive menu confirmation (PVE_FORCE_INTERACTIVE + stdin) deletes too
# expected-v1: PASS
CASE_DESCRIPTION="clear-cache: --yes requirement, suffix filtering, directory kept, interactive confirmation"
CASE_KNOWN_BUGS=""

case_run() {
  scene_cache_put debian12.qcow2
  scene_cache_put ubuntu2204.img
  printf 'not an image\n' > "$CACHE_DIR_RUN/notes.txt"

  run_script clear-cache
  assert_rc 1
  assert_output_contains "非交互环境清理缓存需要加 --yes"
  assert_cache_file debian12.qcow2
  assert_cache_file ubuntu2204.img

  run_script clear-cache --yes
  assert_rc 0
  assert_output_contains "缓存清理完成"
  assert_cache_file_missing debian12.qcow2
  assert_cache_file_missing ubuntu2204.img
  assert_file_exists "$CACHE_DIR_RUN/notes.txt"
  assert_dir_exists "$CACHE_DIR_RUN"

  scene_cache_put debian12.qcow2
  PVE_TEST_FORCE_INTERACTIVE=1 run_script menu <<'EOF'
5
Y

0
EOF
  assert_rc 0
  assert_output_contains "缓存清理完成"
  assert_cache_file_missing debian12.qcow2
  assert_file_exists "$CACHE_DIR_RUN/notes.txt"
}

# expected: PASS
