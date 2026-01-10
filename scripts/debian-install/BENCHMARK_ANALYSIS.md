# Benchmark and Swap Sizing Review

**Date**: 2026-01-10  
**Context**: Reviewing benchmark.py testing methodology and automatic swap sizing against chat-merged.md recommendations

---

## Executive Summary

### ✅ What We're Doing Right

1. **Matrix Testing** (PRIMARY TEST)
   - ✅ Tests all combinations of block size (4-128KB) × concurrency (1-8)
   - ✅ Uses `rw=randrw` (mixed random read/write) - matches real swap behavior
   - ✅ Uses `numjobs` for parallelism - critical for testing multiple devices
   - ✅ Uses `iodepth=4` - matches kernel `SWAP_CLUSTER_MAX`
   - ✅ Comprehensive - replaces deprecated individual tests
   - ✅ **Fully aligned with chat-merged.md methodology**

2. **Test Parameters**
   - ✅ Block sizes: 4KB-128KB (covers all vm.page-cluster values 0-5)
   - ✅ Concurrency: 1,2,4,6,8 (identifies scaling inflection points)
   - ✅ Runtime: 5s per test (reasonable for 30 combinations)
   - ✅ Mixed 50/50 read/write (realistic swap workload)

3. **ZSWAP Preference**
   - ✅ Correctly recommends ZSWAP over ZRAM always
   - ✅ Documents why (LRU eviction, shrinker, hot/cold separation)
   - ✅ Tests compression algorithms (lz4, zstd, lzo-rle)
   - ✅ Tests allocators (zsmalloc, z3fold, zbud)

---

## ⚠️ Issues Found: Swap Sizing Logic

### Current Swap Sizing (setup-swap.sh)

```bash
# Lines 356-378 in setup-swap.sh
if [ "$RAM_GB" -le 2 ]; then
    SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))  # 2GB RAM → 4GB swap ✓
    [ "$SWAP_DISK_TOTAL_GB" -lt 4 ] && SWAP_DISK_TOTAL_GB=4
elif [ "$RAM_GB" -le 4 ]; then
    SWAP_DISK_TOTAL_GB=4  # 4GB RAM → 4GB swap (1x)
elif [ "$RAM_GB" -le 8 ]; then
    SWAP_DISK_TOTAL_GB=8  # 8GB RAM → 8GB swap (1x)
elif [ "$RAM_GB" -le 16 ]; then
    SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))  # 16GB RAM → 32GB swap ✓
    [ "$SWAP_DISK_TOTAL_GB" -gt 32 ] && SWAP_DISK_TOTAL_GB=32
else
    SWAP_DISK_TOTAL_GB=32  # >16GB RAM → 32GB swap
fi
```

### User Requirements

> "we should start at 4GB swap for 2GB RAM, have 32GB swap for 16GB RAM"

This suggests a **2x multiplier** (2GB → 4GB, 16GB → 32GB).

### Problem Analysis

| RAM Size | Current Logic | User Requirement | Status | Issue |
|----------|--------------|------------------|--------|-------|
| 2GB | 4GB (2x) | 4GB (2x) | ✓ | None |
| 4GB | 4GB (1x) | **8GB (2x)** | ❌ | **Underprovisioned** |
| 8GB | 8GB (1x) | **16GB (2x)** | ❌ | **Underprovisioned** |
| 16GB | 32GB (2x) | 32GB (2x) | ✓ | None |
| 32GB | 32GB (1x) | **64GB (2x)?** | ❓ | Capped at 32GB |

**Key Issues:**
1. **Non-uniform multiplier**: Uses 2x for ≤2GB and 8-16GB, but 1x for 4GB and 8GB
2. **Inconsistent with user intent**: Should be consistent 2x across all RAM sizes
3. **Mid-range systems underprovisioned**: 4GB and 8GB RAM systems get only 1x

---

## 📊 Chat-merged.md Recommendations vs Current

### Disk Swap Sizing Table (chat-merged.md lines 390-397)

| RAM Size | chat-merged.md | Current Logic | Difference |
|----------|----------------|---------------|------------|
| 1-2GB | 2-4GB | 4GB (2x min) | ✓ Similar |
| 4GB | **4-8GB** | **4GB** | ❌ Underprovisioned |
| 8GB | **8GB** | **8GB** | ✓ Matches |
| 16GB | **8-16GB** | **32GB** | ❌ Overprovisioned |
| 32GB+ | **8GB** | **32GB** | ❌ Overprovisioned |

**Analysis:**
- chat-merged.md uses **conservative sizing** (less swap for high RAM)
- User wants **2x multiplier** (more aggressive swap sizing)
- Current implementation is **inconsistent** (mixes both approaches)

### Philosophy Differences

**chat-merged.md approach:**
- Assumes ZSWAP effectiveness reduces disk swap need
- High RAM systems (16GB+) need minimal disk swap (8GB)
- Rationale: "ZSWAP effective: ~4GB (2GB × 2.0) + 8GB disk = 20GB virtual"

**User's 2x approach:**
- Consistent multiplier across all RAM sizes
- Better for workloads that exceed ZSWAP capacity
- More conservative/safer for production systems
- Simpler logic: `SWAP = RAM × 2`

---

## 🤔 Geekbench Single-Core Question

### Should Geekbench Results Affect Swap Size?

**Current Approach:** 
- Swap sizing based **only on RAM size**
- Geekbench results used for:
  - Compression algorithm selection (fast CPU → lz4, slow CPU → zstd)
  - Performance baseline/comparison
  - Not used for sizing decisions

**Alternative Approach (Performance-Based Sizing):**
```bash
# Hypothetical: Adjust swap based on CPU performance
GEEKBENCH_SCORE=$(get_geekbench_single_score)

if [ "$GEEKBENCH_SCORE" -lt 800 ]; then
    # Slow CPU: Reduce swap size (compression overhead)
    SWAP_MULTIPLIER=1.5
elif [ "$GEEKBENCH_SCORE" -lt 1200 ]; then
    # Medium CPU: Standard sizing
    SWAP_MULTIPLIER=2.0
else
    # Fast CPU: Can handle more swap compression
    SWAP_MULTIPLIER=2.5
fi

SWAP_DISK_TOTAL_GB=$((RAM_GB * SWAP_MULTIPLIER))
```

### Recommendation: **NO** - Don't Use Geekbench for Sizing

**Reasons:**

1. **Swap size is about capacity, not performance**
   - If you have 50 idle browser tabs, you need space for them
   - CPU speed doesn't change memory requirements

2. **ZSWAP already handles CPU differences**
   - Fast CPU → use lz4 (fast compression, more throughput)
   - Slow CPU → use zstd (better ratio, less CPU cycles per GB)
   - Compressor choice is the CPU-aware optimization

3. **Disk swap is backing store**
   - Acts as overflow when ZSWAP fills
   - Size should match workload memory needs, not CPU speed
   - Example: 100 browser tabs need same disk space regardless of CPU

4. **Geekbench should guide:**
   - ✅ Compressor selection (lz4 vs zstd)
   - ✅ ZSWAP pool size (faster CPU → larger pool)
   - ✅ Concurrency settings (more cores → higher parallelism)
   - ❌ **Not swap capacity** (determined by workload)

5. **Simplicity and predictability**
   - RAM-based sizing is easy to understand and debug
   - Performance-based sizing adds complexity without clear benefit
   - Operators expect: "I have 8GB RAM, I'll get 16GB swap"

---

## 📝 Recommendations

### 1. Unified Swap Sizing Formula

**Implement consistent 2x multiplier with practical caps:**

```bash
calculate_swap_sizes() {
    # Consistent 2x multiplier with caps
    if [ "$SWAP_DISK_TOTAL_GB" = "auto" ]; then
        # Base formula: 2x RAM
        SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))
        
        # Apply minimum (4GB) and maximum (64GB) caps
        [ "$SWAP_DISK_TOTAL_GB" -lt 4 ] && SWAP_DISK_TOTAL_GB=4
        [ "$SWAP_DISK_TOTAL_GB" -gt 64 ] && SWAP_DISK_TOTAL_GB=64
        
        log_info "Disk swap size: ${SWAP_DISK_TOTAL_GB}GB (2x RAM, min 4GB, max 64GB)"
        
        # Verify disk capacity
        # ... (existing capacity check logic)
    fi
}
```

**Results:**

| RAM | Formula | Actual | Rationale |
|-----|---------|--------|-----------|
| 1GB | 1×2 | **4GB** | Minimum cap applied |
| 2GB | 2×2 | **4GB** | User requirement ✓ |
| 4GB | 4×2 | **8GB** | Consistent 2x |
| 8GB | 8×2 | **16GB** | Consistent 2x |
| 16GB | 16×2 | **32GB** | User requirement ✓ |
| 32GB | 32×2 | **64GB** | Maximum cap applied |
| 64GB | 64×2 | **64GB** | Maximum cap applied |

### 2. Geekbench Integration (Compression Only)

**Keep current approach:**
```bash
# Use Geekbench ONLY for compressor selection
if [ "$GEEKBENCH_SCORE" -lt 1000 ]; then
    DEFAULT_COMPRESSOR="zstd"  # Better ratio for slow CPU
else
    DEFAULT_COMPRESSOR="lz4"   # Faster for good CPU
fi

# Do NOT use for swap sizing
SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))  # Always RAM-based
```

### 3. Benchmark Testing - No Changes Needed

**Current matrix testing is excellent:**
- ✅ Fully aligned with chat-merged.md
- ✅ Tests realistic workload (randrw)
- ✅ Identifies optimal block size AND concurrency
- ✅ Uses correct fio parameters (numjobs, iodepth)

**Keep as-is. No changes required.**

### 4. Documentation Updates

**Add to setup-swap.sh comments:**
```bash
# Swap Sizing Philosophy:
# - Base formula: 2x RAM (consistent across all RAM sizes)
# - Minimum: 4GB (safety for very low RAM systems)
# - Maximum: 64GB (practical limit for most workloads)
# - Rationale: With ZSWAP (2-2.5x compression), total effective memory:
#   Example 8GB RAM: 8GB physical + 4GB ZSWAP effective + 16GB disk = ~28GB total
# - NOT based on CPU performance (Geekbench) - swap size is about capacity
# - CPU performance affects compressor choice (lz4 vs zstd), not swap size
```

---

## 🔍 Implementation Changes Required

### File: `setup-swap.sh` (Lines 339-378)

**Change from:**
```bash
if [ "$RAM_GB" -le 2 ]; then
    SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))
    [ "$SWAP_DISK_TOTAL_GB" -lt 4 ] && SWAP_DISK_TOTAL_GB=4
elif [ "$RAM_GB" -le 4 ]; then
    SWAP_DISK_TOTAL_GB=4  # ❌ Inconsistent 1x
elif [ "$RAM_GB" -le 8 ]; then
    SWAP_DISK_TOTAL_GB=8  # ❌ Inconsistent 1x
elif [ "$RAM_GB" -le 16 ]; then
    SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))
    [ "$SWAP_DISK_TOTAL_GB" -gt 32 ] && SWAP_DISK_TOTAL_GB=32
else
    SWAP_DISK_TOTAL_GB=32
fi
```

**Change to:**
```bash
# Consistent 2x multiplier with practical caps
SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))

# Apply minimum (4GB) and maximum (64GB) caps
[ "$SWAP_DISK_TOTAL_GB" -lt 4 ] && SWAP_DISK_TOTAL_GB=4
[ "$SWAP_DISK_TOTAL_GB" -gt 64 ] && SWAP_DISK_TOTAL_GB=64

log_info "Disk swap size: ${SWAP_DISK_TOTAL_GB}GB (2x RAM, min 4GB, max 64GB)"
```

### Verification

**Test cases:**
```bash
# RAM=2GB  → 2×2=4GB   → 4GB ✓ (minimum applied)
# RAM=4GB  → 4×2=8GB   → 8GB ✓ (was 4GB before - FIXED)
# RAM=8GB  → 8×2=16GB  → 16GB ✓ (was 8GB before - FIXED)
# RAM=16GB → 16×2=32GB → 32GB ✓ (unchanged)
# RAM=32GB → 32×2=64GB → 64GB ✓ (was 32GB before - doubled)
# RAM=64GB → 64×2=128GB → 64GB ✓ (maximum cap applied)
```

---

## Summary

### What's Working Well ✅
- Matrix testing methodology perfectly aligned with chat-merged.md
- Correct use of fio parameters (numjobs, iodepth, randrw)
- ZSWAP preference and rationale documented
- Compression and allocator testing

### What Needs Fixing ❌
- **Swap sizing formula inconsistent** (mixes 1x and 2x multipliers)
- **Mid-range systems underprovisioned** (4GB and 8GB RAM)
- **Should use uniform 2x multiplier** as user requested

### What Should NOT Change 🚫
- **Don't use Geekbench for swap sizing** (use for compressor selection only)
- **Keep RAM-based sizing** (workload capacity, not CPU performance)
- **Keep current benchmark testing** (already excellent)

### Action Items
1. ✅ Simplify swap sizing to consistent 2x formula with caps
2. ✅ Document rationale (capacity-based, not performance-based)
3. ✅ Keep Geekbench for compressor selection only
4. ✅ No changes needed to benchmark.py
