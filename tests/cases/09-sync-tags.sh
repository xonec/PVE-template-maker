#!/usr/bin/env bash
# Case: sync-tags (spec "e" mapped to v2).  Mixed inventory:
#   * running qemu VM with agent (eth0 + docker0 + tailscale0 interfaces)
#   * stopped qemu VM with a static ipconfig0
#   * unknown-status qemu VM with a static ipconfig0 (RRD race: live probe then fallback)
#   * template (must be skipped)
#   * running LXC container (pct exec)
#   * stopped LXC container with a static net0 ip
# Existing tags must be lowercased/preserved, docker0/tailscale addresses
# ignored, output tags use the PVE ';' form, and a second run must be a no-op.
# expected-v1: PASS
CASE_DESCRIPTION="sync-tags: agent / pct exec / static fallback / unknown status, template skip, tag merge + lowercase, idempotency"
CASE_KNOWN_BUGS=""

case_run() {
  scene_add_vm 8000 vm-run running "Prod;Web"
  scene_set_guest_mode 8000 docker
  scene_add_vm 8001 vm-stopped stopped "keepme"
  scene_set_vm_static_ip 8001 "10.0.0.77/24"
  scene_add_vm 8003 vm-unknown unknown ""
  scene_set_vm_static_ip 8003 "10.0.0.88/24"
  scene_add_vm 9000 tpl-debian stopped "tpl"
  scene_mark_template 9000
  scene_add_ct 200 ct-run running "ct-tag"
  scene_add_ct 201 ct-stop stopped "keep-ct"
  scene_set_ct_static_ip 201 "10.0.0.31/24"

  run_script sync-tags
  assert_rc 0
  assert_output_contains "共 6 个对象：更新 5"
  assert_output_contains "IP 标签已更新：prod;web;ip-10.0.0.10"
  assert_output_contains "IP 标签已更新：ct-tag;ip-10.0.0.20"

  # running VM: PVE stores tags lowercased and ';'-joined, pre-existing tags kept
  assert_config_value 8000 tags "prod;web;ip-10.0.0.10"
  # stopped VM: static ipconfig0 fallback, no live probe for stopped objects
  assert_config_value 8001 tags "keepme;ip-10.0.0.77"
  # unknown status: live probe attempted, static fallback used
  assert_config_value 8003 tags "ip-10.0.0.88"
  # containers: running uses pct exec, stopped uses static net0
  assert_ct_config_value 200 tags "ct-tag;ip-10.0.0.20"
  assert_ct_config_value 201 tags "keep-ct;ip-10.0.0.31"
  # template untouched
  assert_config_value 9000 tags "tpl"
  assert_config_value 9000 template 1
  assert_calls_not_contains "qm set 9000"
  assert_calls_not_contains "pct set 9000"
  # stopped objects never get a live probe
  assert_calls_not_contains "qm guest cmd 8001"
  # docker0 / tailscale addresses are excluded by default
  assert_file_not_contains "$MOCK_STATE/vm/8000/conf" "172.17"
  assert_file_not_contains "$MOCK_STATE/vm/8000/conf" "100.64"

  # second run: everything is already up to date, no writes at all
  local qm_before pct_before
  qm_before=$(mock_calls_count_value "qm set ")
  pct_before=$(mock_calls_count_value "pct set ")
  run_script sync-tags
  assert_rc 0
  assert_output_contains "共 6 个对象：更新 0，已是最新 5，跳过 1，失败 0"
  assert_output_contains "ip-10.0.0.10 已存在"
  assert_equals "$qm_before" "$(mock_calls_count_value "qm set ")" "qm set count unchanged on second run"
  assert_equals "$pct_before" "$(mock_calls_count_value "pct set ")" "pct set count unchanged on second run"
  assert_config_value 8000 tags "prod;web;ip-10.0.0.10"
}

# expected: PASS
