# Bootstrap Issues and Recommendations

**Date**: 2026-01-10  
**Server**: v1001.vxxu.de  
**Bootstrap Run**: 2026-01-09 17:54:11

---

## 1. Critical Bug Fixed ✅

### Issue: Unbound Variable Error
**Location**: [setup-swap.sh](setup-swap.sh#L1866)  
**Error**: `./setup-swap.sh: line 1866: SWAP_PAGE_CLUSTER: unbound variable`  
**Status**: ✅ **FIXED in commit 28ce300**

#### Root Cause
- `benchmark.py` exports `SWAP_PAGE_CLUSTER` only from deprecated `block_sizes` tests
- Bootstrap now runs only new `matrix` tests
- `setup-swap.sh` uses `[ -n "$SWAP_PAGE_CLUSTER" ]` with `set -u`, causing failure when variable undefined

#### Fix Applied
1. Changed to `[ -n "${SWAP_PAGE_CLUSTER:-}" ]` for safe undefined check
2. `benchmark.py` now exports from matrix test results (primary) with fallback to block_sizes
3. Applied chat-merged.md recommendation: **page-cluster=0 for ZSWAP** (no readahead needed for RAM cache)

---

## 2. Insights from chat-merged.md

### A. ZSWAP is Always Superior to ZRAM ✅ (Already Applied)

**Status**: ✅ **Already correctly implemented**

The auto-detection logic correctly:
- Always selects ZSWAP by default
- Warns if ZRAM is explicitly selected
- Adjusts pool size based on RAM (15-40%)

**Evidence**: [setup-swap.sh#L258-295](setup-swap.sh#L258-295)

```bash
# Always use ZSWAP - it's superior to ZRAM for all RAM sizes
# The only difference is pool size tuning based on RAM
if [ -z "$SWAP_RAM_SOLUTION" ] || [ "$SWAP_RAM_SOLUTION" = "auto" ]; then
    SWAP_RAM_SOLUTION="zswap"
    ...
```

### B. Page-Cluster for ZSWAP ✅ (Now Fixed)

**Recommendation**: `vm.page-cluster=0` for ZSWAP

**Rationale** (from chat-merged.md):
- ZSWAP caches individual 4KB pages in RAM
- No seek cost (data in RAM, not disk)
- Reading extra pages wastes memory bandwidth
- Readahead designed for HDDs to amortize seek cost

**Status**: ✅ **Fixed in commit 28ce300**

Now implements:
```bash
if [ "$SWAP_RAM_SOLUTION" = "zswap" ]; then
    page_cluster=0  # 4KB for ZSWAP (no readahead needed)
```

### C. Compression Algorithm Choice

**Current**: Auto-selects from benchmark results  
**Recommendation from chat-merged.md**:
- **lz4**: Best for most systems (fast, 2.0:1 ratio, ~3µs latency)
- **zstd**: Only for low RAM systems needing maximum compression (2.3:1 ratio, ~15µs latency)
- **lzo**: Fallback if lz4 unavailable

**Status**: ⚠️ **Could be improved**

Current code picks "best compressor" by compression ratio, which would favor zstd. However, chat-merged.md shows lz4 is better for most use cases due to 5x faster decompression.

**Suggested Enhancement**:
```python
# Prefer lz4 unless RAM is very low
if RAM_GB < 4 and best_comp['compressor'] == 'zstd':
    # Use zstd for low RAM systems (better compression matters more)
    f.write(f"ZSWAP_COMPRESSOR={best_comp['compressor']}\n")
else:
    # Default to lz4 for faster latency
    f.write("ZSWAP_COMPRESSOR=lz4  # Recommended for most systems\n")
    f.write(f"# Note: zstd available with {best_comp.get('compression_ratio')}x ratio\n")
```

### D. Allocator for ZSWAP

**Current**: Exports best allocator from benchmark  
**Issue from testing**: z3fold fails to load on some systems, causing ZSWAP to fall back to default

**Evidence from bootstrap**:
```
[INFO] Setting ZSWAP zpool: z3fold
[WARN] Failed to set zpool, using default
```

**Recommendation**: Prefer **zbud** for ZSWAP (always works, sufficient for most cases)

**Status**: ⚠️ **Could be improved**

**Suggested Enhancement**:
```bash
# For ZSWAP, prefer zbud (reliability over efficiency)
if [ "$SWAP_RAM_SOLUTION" = "zswap" ]; then
    ZSWAP_ZPOOL="zbud"  # Always available, good enough
    log_info "Using zbud zpool for ZSWAP (most compatible)"
else
    # For ZRAM, benchmark result matters more
    echo z3fold > /sys/block/zram0/comp_algorithm || \
    echo zsmalloc > /sys/block/zram0/comp_algorithm
fi
```

### E. Transparent Huge Pages (THP)

**Recommendation from chat-merged.md**: `madvise` mode, not `always`

**Rationale**:
- THP causes memory bloat (100KB app gets 2MB)
- Inefficient swapping (swap 2MB vs 4KB)
- khugepaged causes latency spikes
- Fragmentation with many small applications

**Status**: ⚠️ **Not currently configured by bootstrap**

The bootstrap doesn't configure THP at all. Should add:

```bash
# Configure Transparent Huge Pages
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Make persistent
cat > /etc/systemd/system/thp-config.service <<'EOF'
[Unit]
Description=Configure Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable thp-config.service
```

### F. Kernel Parameters for ZSWAP

**Current**: Sets standard vm.* parameters  
**Recommendations from chat-merged.md**:

```ini
# For ZSWAP-optimized systems
vm.swappiness=80         # Current: 60 (should be higher for ZSWAP)
vm.page-cluster=0        # ✅ Fixed: Now 0 for ZSWAP
vm.vfs_cache_pressure=50 # Current: 100 (should be lower to keep metadata)

# Additional recommendations
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.watermark_scale_factor=125  # Current: 10 (too low)
```

**Status**: ⚠️ **Partially applied**

---

## 3. Testing Findings

### A. Matrix Test Replaces Old Tests ✅

**Finding**: Bootstrap ran 30 matrix tests (6 block sizes × 5 concurrency levels)  
**Result**: Found optimal config (128KB × 6 jobs = 10356 MB/s write)  
**Status**: ✅ Working correctly

### B. Benchmark File Cleanup Issue ⚠️

**Finding**: `/tmp/benchmark-optimal-config.sh` was created but then deleted  
**Cause**: Benchmark saves results to `/var/log/debian-install/` but then cleans up temp files  
**Impact**: Config was sourced successfully before cleanup, so no issue  
**Status**: ⚠️ Minor issue, could keep config file for debugging

### C. Performance Results

From the bootstrap run:
- **Best write**: 128KB × 6 jobs = 10356 MB/s
- **Best read**: 128KB × 6 jobs = 10355 MB/s  
- **Combined**: 20710 MB/s

**Interpretation**: System benefits from:
- Large block sizes (128KB = page-cluster=5)
- High concurrency (6-8 jobs)
- Multiple swap devices (8 partitions created)

**Conflict**: Matrix says page-cluster=5, but ZSWAP best practices say 0

**Resolution**: Use 0 for ZSWAP (correct), matrix test is for disk-only scenarios

---

## 4. Recommendations Summary

### Immediate (High Priority)

1. ✅ **Fixed**: SWAP_PAGE_CLUSTER export from matrix tests
2. ✅ **Fixed**: page-cluster=0 for ZSWAP
3. ⚠️ **TODO**: Add THP configuration to bootstrap
4. ⚠️ **TODO**: Increase vm.swappiness to 80 for ZSWAP
5. ⚠️ **TODO**: Set vm.vfs_cache_pressure=50

### Medium Priority

6. ⚠️ **TODO**: Prefer zbud allocator for ZSWAP (reliability)
7. ⚠️ **TODO**: Adjust vm.watermark_scale_factor=125
8. ⚠️ **TODO**: Add vm.dirty_* parameters for better writeback

### Low Priority (Optimization)

9. ⚠️ **TODO**: Prefer lz4 compressor unless RAM < 4GB
10. ⚠️ **TODO**: Keep benchmark config file for debugging

---

## 5. Code Locations

- Bootstrap entry: [bootstrap.sh](bootstrap.sh)
- Benchmark runner: [benchmark.py](benchmark.py)
- Swap configuration: [setup-swap.sh](setup-swap.sh)
- Best practices doc: [chat-merged.md](chat-merged.md)
- This analysis: [ISSUES_AND_RECOMMENDATIONS.md](ISSUES_AND_RECOMMENDATIONS.md)

---

## 6. Next Steps

1. ✅ Push fix to GitHub (commit 28ce300)
2. ⚠️ Test on v1001.vxxu.de with updated code
3. ⚠️ Implement THP configuration
4. ⚠️ Adjust sysctl parameters for ZSWAP optimization
5. ⚠️ Consider zbud vs z3fold preference logic

---

**Document Status**: Complete analysis of 2026-01-09 bootstrap run  
**Primary Fix**: ✅ Applied and pushed to main branch  
**Follow-up**: Additional optimizations recommended but not critical
