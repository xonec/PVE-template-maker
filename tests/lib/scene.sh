#!/usr/bin/env bash
# Scene helpers: build the $MOCK_STATE fixture for one test case.
# Sourced by tests/run.sh before a case runs; cases call these helpers to
# describe the fake PVE node they need.  Bash 3.2 compatible.

# ---------------------------------------------------------------------------
# default fixture (framework calls this before every case)
# ---------------------------------------------------------------------------
_init_default_state() {
  mkdir -p "$MOCK_STATE/vm" "$MOCK_STATE/ct" "$MOCK_STATE/storages" "$MOCK_STATE/bridges"
  printf '0\n' > "$MOCK_STATE/uid"
  printf 'pve\n' > "$MOCK_STATE/node"
  printf 'ok\n' > "$MOCK_STATE/wget_mode"
  printf 'ok\n' > "$MOCK_STATE/curl_mode"
  : > "$MOCK_STATE/calls.log"
  scene_reset_bridges
  scene_set_bridges vmbr0
  scene_reset_storages
  scene_add_storage local dir 98497780 45793152 "iso,vztmpl,backup,images,rootdir"
}

# ---------------------------------------------------------------------------
# node / identity
# ---------------------------------------------------------------------------
scene_set_uid() { printf '%s\n' "$1" > "$MOCK_STATE/uid"; }
scene_set_node() { printf '%s\n' "$1" > "$MOCK_STATE/node"; }

# ---------------------------------------------------------------------------
# bridges: scene_set_bridges vmbr0 vmbr1
# ---------------------------------------------------------------------------
scene_reset_bridges() { rm -rf "$MOCK_STATE/bridges"; mkdir -p "$MOCK_STATE/bridges"; }

scene_set_bridges() {
  scene_reset_bridges
  local i=0 name
  for name in "$@"; do
    mkdir -p "$MOCK_STATE/bridges/$name"
    printf '10.0.%s.1/24\n' "$i" > "$MOCK_STATE/bridges/$name/addr"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# storages: scene_add_storage <name> [type] [total_kib] [used_kib] [content]
# ---------------------------------------------------------------------------
scene_reset_storages() { rm -rf "$MOCK_STATE/storages"; mkdir -p "$MOCK_STATE/storages"; }

scene_add_storage() {
  local name="$1" type="${2:-dir}" total="${3:-98497780}" used="${4:-45793152}"
  local content="${5:-iso,vztmpl,backup,images,rootdir}" dir
  dir="$MOCK_STATE/storages/$name"
  mkdir -p "$dir"
  printf '%s\n' "$type" > "$dir/type"
  printf 'active\n' > "$dir/status"
  printf '%s\n' "$total" > "$dir/total_kib"
  printf '%s\n' "$used" > "$dir/used_kib"
  printf '%s\n' "$content" > "$dir/content"
}

# ---------------------------------------------------------------------------
# QEMU VMs: scene_add_vm <vmid> <name> <status> [tags] [ip]
# ---------------------------------------------------------------------------
scene_add_vm() {
  local id="$1" name="$2" status="$3" tags="${4:-}" ip="${5:-}" dir
  dir="$MOCK_STATE/vm/$id"
  mkdir -p "$dir"
  printf '%s\n' "$name" > "$dir/name"
  printf '%s\n' "$status" > "$dir/status"
  printf '2048\n' > "$dir/mem"
  printf '0\n' > "$dir/bootdisk_bytes"
  if [ "$status" = "running" ]; then printf '12345\n' > "$dir/pid"; else printf '0\n' > "$dir/pid"; fi
  {
    printf 'name: %s\n' "$name"
    printf 'cores: 2\n'
    printf 'memory: 2048\n'
    printf 'net0: virtio,bridge=vmbr0,firewall=0\n'
    [ -n "$tags" ] && printf 'tags: %s\n' "$tags"
  } > "$dir/conf"
  [ -n "$ip" ] && printf '%s\n' "$ip" > "$dir/guest_ip"
}

scene_set_guest_mode() { printf '%s\n' "$2" > "$MOCK_STATE/vm/$1/guest_mode"; }
scene_set_guest_ip() { printf '%s\n' "$2" > "$MOCK_STATE/vm/$1/guest_ip"; }

scene_set_vm_tags() { # vmid tags
  local id="$1" tags="$2" dir
  dir="$MOCK_STATE/vm/$id"
  mkdir -p "$dir"
  awk -v t="tags: " 'index($0, t) != 1 { print }' "$dir/conf" 2>/dev/null > "$dir/conf.tmp.$$"
  printf 'tags: %s\n' "$tags" >> "$dir/conf.tmp.$$"
  mv "$dir/conf.tmp.$$" "$dir/conf"
}

# add a static ipconfig0 entry (used by sync-tags' stopped-VM fallback)
scene_set_vm_static_ip() { # vmid cidr [gateway]
  local id="$1" cidr="$2" gw="${3:-}" dir
  dir="$MOCK_STATE/vm/$id"
  mkdir -p "$dir"
  awk -v t="ipconfig0: " 'index($0, t) != 1 { print }' "$dir/conf" 2>/dev/null > "$dir/conf.tmp.$$"
  if [ -n "$gw" ]; then
    printf 'ipconfig0: ip=%s,gw=%s\n' "$cidr" "$gw" >> "$dir/conf.tmp.$$"
  else
    printf 'ipconfig0: ip=%s\n' "$cidr" >> "$dir/conf.tmp.$$"
  fi
  mv "$dir/conf.tmp.$$" "$dir/conf"
}

scene_mark_template() { # vmid
  local id="$1" dir
  dir="$MOCK_STATE/vm/$id"
  mkdir -p "$dir"
  printf '1\n' > "$dir/template"
  printf 'stopped\n' > "$dir/status"
  printf '0\n' > "$dir/pid"
  awk -v t="template: " 'index($0, t) != 1 { print }' "$dir/conf" 2>/dev/null > "$dir/conf.tmp.$$"
  printf 'template: 1\n' >> "$dir/conf.tmp.$$"
  mv "$dir/conf.tmp.$$" "$dir/conf"
}

# ---------------------------------------------------------------------------
# LXC containers: scene_add_ct <ctid> <name> <status> [tags] [ip-cidr]
# ---------------------------------------------------------------------------
scene_add_ct() {
  local id="$1" name="$2" status="$3" tags="${4:-}" ip="${5:-10.0.0.20/24}" dir
  dir="$MOCK_STATE/ct/$id"
  mkdir -p "$dir"
  printf '%s\n' "$name" > "$dir/name"
  printf '%s\n' "$status" > "$dir/status"
  printf '512\n' > "$dir/mem"
  printf '%s\n' "$ip" > "$dir/ip"
  {
    printf 'arch: amd64\n'
    printf 'cores: 1\n'
    printf 'hostname: %s\n' "$name"
    printf 'memory: 512\n'
    printf 'nameserver: 1.1.1.1\n'
    printf 'net0: name=eth0,bridge=vmbr0,firewall=0,ip=dhcp,type=veth\n'
    printf 'rootfs: local:vm-%s-disk-0,size=8G\n' "$id"
    [ -n "$tags" ] && printf 'tags: %s\n' "$tags"
  } > "$dir/conf"
}

scene_set_ct_tags() { # ctid tags
  local id="$1" tags="$2" dir
  dir="$MOCK_STATE/ct/$id"
  mkdir -p "$dir"
  awk -v t="tags: " 'index($0, t) != 1 { print }' "$dir/conf" 2>/dev/null > "$dir/conf.tmp.$$"
  printf 'tags: %s\n' "$tags" >> "$dir/conf.tmp.$$"
  mv "$dir/conf.tmp.$$" "$dir/conf"
}

scene_set_ct_static_ip() { # ctid cidr
  local id="$1" cidr="$2" dir
  dir="$MOCK_STATE/ct/$id"
  mkdir -p "$dir"
  awk -v t="net0: " 'index($0, t) != 1 { print }' "$dir/conf" 2>/dev/null > "$dir/conf.tmp.$$"
  printf 'net0: name=eth0,bridge=vmbr0,firewall=0,ip=%s,type=veth\n' "$cidr" >> "$dir/conf.tmp.$$"
  mv "$dir/conf.tmp.$$" "$dir/conf"
  printf '%s\n' "$cidr" > "$dir/ip"
}

# ---------------------------------------------------------------------------
# importdisk behaviour: 1 = modern --target-disk, 0 = legacy unused0 path
# ---------------------------------------------------------------------------
scene_set_import_target_disk() { printf '%s\n' "$1" > "$MOCK_STATE/qm_importdisk_target_disk"; }

# ---------------------------------------------------------------------------
# image download / cache fixtures
# ---------------------------------------------------------------------------
scene_cache_put() { # filename [extra-zero-bytes]
  local name="$1" size="${2:-8192}"
  [ -d "$CACHE_DIR_RUN" ] || mkdir -p "$CACHE_DIR_RUN"
  {
    printf 'QFI\373'
    printf 'pve-mock-qcow2 cached image\n'
    dd if=/dev/zero bs="$size" count=1 2>/dev/null || true
  } > "$CACHE_DIR_RUN/$name"
}

scene_cache_clear() { rm -f "$CACHE_DIR_RUN"/* 2>/dev/null; }

scene_set_wget_mode() { printf '%s\n' "$1" > "$MOCK_STATE/wget_mode"; }
scene_set_curl_mode() { printf '%s\n' "$1" > "$MOCK_STATE/curl_mode"; }
scene_set_qemu_img_virtual_size() { printf '%s\n' "$1" > "$MOCK_STATE/qemu_img_virtual_size"; }
