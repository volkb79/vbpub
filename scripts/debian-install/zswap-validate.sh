#!/bin/bash
set -euo pipefail

# Optional env inputs
ZSWAP_VALIDATE_HOLD_SECONDS="${ZSWAP_VALIDATE_HOLD_SECONDS:-60}"
ZSWAP_VALIDATE_PRESSURE_MB="${ZSWAP_VALIDATE_PRESSURE_MB:-auto}"

log() { echo "[zswap-validate] $*"; }

read_sys_file() {
  local path="$1"
  if [ -r "$path" ]; then
    tr -d '\n' <"$path"
  else
    echo "N/A"
  fi
}

mount_debugfs_if_needed() {
  if [ -d /sys/kernel/debug/zswap ]; then
    return 0
  fi
  if ! command -v mountpoint >/dev/null 2>&1; then
    return 0
  fi
  if ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs debugfs /sys/kernel/debug >/dev/null 2>&1 || true
  fi
}

zswap_stat() {
  local name="$1"
  local p="/sys/kernel/debug/zswap/$name"
  if [ -r "$p" ]; then
    tr -d '\n' <"$p"
  else
    echo "N/A"
  fi
}

mem_kb() {
  awk -v key="$1" '$1==key {print $2}' /proc/meminfo 2>/dev/null || echo "0"
}

ensure_build_tools() {
  if command -v gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
    return 0
  fi
  log "Installing build tools (build-essential) for validation binaries..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq build-essential >/dev/null
}

build_bins() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [ ! -x /usr/local/bin/vbpub-mem-pressure ]; then
    ensure_build_tools
    log "Compiling mem_pressure.c → /usr/local/bin/vbpub-mem-pressure"
    gcc -O2 -Wall "$script_dir/mem_pressure.c" -o /usr/local/bin/vbpub-mem-pressure
  fi

  if [ ! -x /usr/local/bin/vbpub-mem-mixed-bench ]; then
    ensure_build_tools
    log "Compiling mem_mixed_bench.c → /usr/local/bin/vbpub-mem-mixed-bench"
    gcc -O2 -Wall "$script_dir/mem_mixed_bench.c" -o /usr/local/bin/vbpub-mem-mixed-bench
  fi
}

calc_pressure_mb() {
  local mem_total_kb swap_total_kb mem_total_mb swap_total_mb
  mem_total_kb="$(mem_kb MemTotal:)"
  swap_total_kb="$(mem_kb SwapTotal:)"
  mem_total_mb=$((mem_total_kb / 1024))
  swap_total_mb=$((swap_total_kb / 1024))

  if [ "$ZSWAP_VALIDATE_PRESSURE_MB" != "auto" ]; then
    echo "$ZSWAP_VALIDATE_PRESSURE_MB"
    return 0
  fi

  # Heuristic: exceed RAM enough to force swap, but keep under ~80% of swap.
  # pressure = RAM + min(2048MB, 60% of swap)
  local extra_mb
  extra_mb=$((swap_total_mb * 60 / 100))
  if [ "$extra_mb" -gt 2048 ]; then
    extra_mb=2048
  fi
  if [ "$extra_mb" -lt 512 ]; then
    extra_mb=512
  fi

  local max_extra_mb
  max_extra_mb=$((swap_total_mb * 80 / 100))
  if [ "$extra_mb" -gt "$max_extra_mb" ]; then
    extra_mb="$max_extra_mb"
  fi

  echo $((mem_total_mb + extra_mb))
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root." >&2
    exit 1
  fi

  local zswap_enabled
  zswap_enabled="$(read_sys_file /sys/module/zswap/parameters/enabled)"
  if [ "$zswap_enabled" = "N" ] || [ "$zswap_enabled" = "0" ] || [ "$zswap_enabled" = "N/A" ]; then
    log "ZSWAP not enabled (enabled=$zswap_enabled). Skipping validation."
    exit 0
  fi

  mount_debugfs_if_needed

  local compressor zpool max_pool_percent
  compressor="$(read_sys_file /sys/module/zswap/parameters/compressor)"
  zpool="$(read_sys_file /sys/module/zswap/parameters/zpool)"
  max_pool_percent="$(read_sys_file /sys/module/zswap/parameters/max_pool_percent)"

  local mem_total_kb swap_total_kb mem_total_mb swap_total_mb
  mem_total_kb="$(mem_kb MemTotal:)"
  swap_total_kb="$(mem_kb SwapTotal:)"
  mem_total_mb=$((mem_total_kb / 1024))
  swap_total_mb=$((swap_total_kb / 1024))

  echo "ZSWAP validation"
  echo "- enabled: $zswap_enabled"
  echo "- compressor: $compressor"
  echo "- zpool: $zpool"
  echo "- max_pool_percent: $max_pool_percent"
  echo "- MemTotal: ${mem_total_mb} MB"
  echo "- SwapTotal: ${swap_total_mb} MB"

  if [ "$swap_total_mb" -lt 256 ]; then
    echo "- result: skipped (SwapTotal too small)"
    exit 0
  fi

  # Snapshot stats if available
  local pre_pool pre_stored pre_wb pre_limit_hit
  pre_pool="$(zswap_stat pool_total_size)"
  pre_stored="$(zswap_stat stored_pages)"
  pre_wb="$(zswap_stat written_back_pages)"
  pre_limit_hit="$(zswap_stat pool_limit_hit)"

  echo "Pre stats (debugfs):"
  echo "- pool_total_size: $pre_pool"
  echo "- stored_pages: $pre_stored"
  echo "- written_back_pages: $pre_wb"
  echo "- pool_limit_hit: $pre_limit_hit"
  echo

  build_bins

  local pressure_mb
  pressure_mb="$(calc_pressure_mb)"

  log "Running memory pressure to trigger zswap usage"
  log "- mem_pressure: ${pressure_mb} MB, pattern=mixed(0), hold=${ZSWAP_VALIDATE_HOLD_SECONDS}s"

  # Run pressure in background so we can sample stats while it holds memory.
  /usr/local/bin/vbpub-mem-pressure "$pressure_mb" 0 "$ZSWAP_VALIDATE_HOLD_SECONDS" >/tmp/vbpub-mem-pressure.out 2>/tmp/vbpub-mem-pressure.err &
  local pressure_pid=$!

  # Give it a moment to allocate.
  sleep 2

  # During pressure, run a mixed workload latency sample (best-effort)
  local bench_mb
  bench_mb=512
  if [ "$mem_total_mb" -lt 2048 ]; then
    bench_mb=256
  fi
  log "Running mixed workload latency sample (best-effort)"
  /usr/local/bin/vbpub-mem-mixed-bench "$bench_mb" 70 >/tmp/vbpub-mem-mixed-bench.json 2>/tmp/vbpub-mem-mixed-bench.err || true

  # Wait for pressure to complete.
  wait "$pressure_pid" || true

  local post_pool post_stored post_wb post_limit_hit
  post_pool="$(zswap_stat pool_total_size)"
  post_stored="$(zswap_stat stored_pages)"
  post_wb="$(zswap_stat written_back_pages)"
  post_limit_hit="$(zswap_stat pool_limit_hit)"

  echo "Post stats (debugfs):"
  echo "- pool_total_size: $post_pool"
  echo "- stored_pages: $post_stored"
  echo "- written_back_pages: $post_wb"
  echo "- pool_limit_hit: $post_limit_hit"

  # Also show swap in/out counters (not zswap-specific but useful)
  local pswpin_pre pswpout_pre
  pswpin_pre="$(awk '$1=="pswpin" {print $2}' /proc/vmstat 2>/dev/null || echo 0)"
  pswpout_pre="$(awk '$1=="pswpout" {print $2}' /proc/vmstat 2>/dev/null || echo 0)"
  echo "- vmstat: pswpin=$pswpin_pre pswpout=$pswpout_pre"

  # Summarize latency sample if present
  if [ -s /tmp/vbpub-mem-mixed-bench.json ]; then
    echo
    echo "Mixed workload latency sample (mem_mixed_bench):"
    # Keep it robust: just show a few key fields without jq dependency.
    grep -E '"avg_us"|"p50_us"|"p95_us"|"p99_us"|"ops_per_sec"|"read_write_ratio"' /tmp/vbpub-mem-mixed-bench.json | head -30 || true
  else
    echo
    echo "Mixed workload latency sample: unavailable (bench failed)."
  fi

  echo
  echo "Result: validation completed (best-effort)."
  echo "Notes: Rising stored_pages/pool_total_size during pressure indicates zswap activity; rising written_back_pages/pool_limit_hit suggests eviction to disk swap." 
}

main "$@"
