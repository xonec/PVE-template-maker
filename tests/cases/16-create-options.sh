#!/usr/bin/env bash
# Case: every create option wired through to qm create / qm set:
# official Debian (ciuser debian), seabios (no efidisk), pc machine, custom
# cores/memory/disk, static ip + gateway, nameserver, password, onboot,
# extra tags, no description, no start.
# expected-v1: PASS
CASE_DESCRIPTION="create option matrix: bios/machine/cores/memory/disk/static-ip/nameserver/cipassword/onboot/vm-tags/no-start/no-description"
CASE_KNOWN_BUGS=""

case_run() {
  run_script create \
    --distro Debian-12 \
    --vmid 8002 \
    --bios seabios \
    --machine pc \
    --cores 4 \
    --memory 4G \
    --disk 32G \
    --static-ip 10.0.0.50/24 \
    --gateway 10.0.0.1 \
    --nameserver 1.1.1.1 \
    --ciuser debian \
    --cipassword S3cret \
    --onboot \
    --vm-tags web,docker \
    --no-start \
    --no-description \
    --yes

  assert_rc 0
  assert_output_contains "创建参数确认"
  assert_output_contains "ip=10.0.0.50/24"

  assert_calls_contains "qm create 8002 --name Debian-12"
  assert_calls_contains "--machine pc"
  assert_calls_contains "--bios seabios"
  assert_calls_not_contains "--efidisk0"
  assert_calls_contains "--cores 4"
  assert_calls_contains "--memory 4096"
  assert_calls_contains "qm resize 8002 scsi0 32G"
  assert_calls_contains "qm importdisk 8002 $CACHE_DIR_RUN/debian12.qcow2 local --format qcow2"
  assert_calls_not_contains "qm start 8002"

  assert_config_value 8002 machine pc
  assert_config_value 8002 bios seabios
  assert_config_lacks 8002 "efidisk0:"
  assert_config_value 8002 cores 4
  assert_config_value 8002 memory 4096
  assert_config_value 8002 balloon 4096
  assert_config_value 8002 scsi0 "local:vm-8002-disk-0,size=32G"
  assert_config_value 8002 ipconfig0 "ip=10.0.0.50/24,gw=10.0.0.1,ip6=dhcp"
  assert_config_value 8002 nameserver 1.1.1.1
  assert_config_value 8002 ciuser debian
  assert_config_value 8002 cipassword S3cret
  assert_config_value 8002 onboot 1
  assert_config_value 8002 tags "web;docker"
  assert_config_lacks 8002 "description:"
  assert_config_lacks 8002 "tags: web;docker;ip-"
  assert_file_missing "$MOCK_STATE/vm/8002/template"
}

# expected: PASS
