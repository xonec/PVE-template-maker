#!/usr/bin/env bash
# Case: read-only/help commands: list-distros, version, help and the unknown
# command exit code.
# expected-v1: PASS
CASE_DESCRIPTION="list-distros / version / help output content and unknown-command exit code 2"
CASE_KNOWN_BUGS=""

case_run() {
  run_script list-distros
  assert_rc 0
  assert_output_contains "Debian-12"
  assert_output_contains "debian/debian12.qcow2"
  assert_output_contains "thirdparty"
  assert_output_contains "official"
  assert_output_contains "ID"

  run_script version
  assert_rc 0
  assert_output_contains "pve-unified.sh 2.0.0"

  run_script help
  assert_rc 0
  assert_output_contains "create"
  assert_output_contains "template"
  assert_output_contains "clone"
  assert_output_contains "sync-tags"
  assert_output_contains "clear-cache"
  assert_output_contains "--dry-run"
  assert_output_contains "--static-ip"

  run_script definitely-not-a-command
  assert_rc 2
  assert_output_contains "用法"
}

# expected: PASS
