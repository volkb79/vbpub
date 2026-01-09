# Testing Methodology and Performance Metrics Documentation

## Overview

This document explains the comprehensive testing approach used in `benchmark.py` to evaluate and optimize swap configurations for Debian systems. The benchmark suite provides actionable data for making system-specific swap configuration decisions.

**Key Recommendation: Always Use ZSWAP**

Based on extensive testing and analysis documented in `chat-merged.md`, **ZSWAP is always superior to ZRAM** for general-purpose systems:

| Feature | ZRAM | ZSWAP |
|---------|------|-------|
| Cold page eviction | ❌ No automatic eviction | ✅ LRU-based eviction |
| Hot/cold separation | ❌ Pages stick forever | ✅ Automatic rebalancing |
| Memory efficiency | ❌ Cold pages waste RAM | ✅ Cold pages go to disk |
| Disk backing | ❌ Requires priority management | ✅ Transparent writeback |
| Shrinker support | ❌ N/A | ✅ Dynamic sizing (kernel 6.8+) |

**There is no use case where ZRAM is better than ZSWAP for general-purpose systems.**

---

## Table of Contents

1. [Testing Philosophy](#testing-philosophy)
2. [Why ZSWAP Over ZRAM](#why-zswap-over-zram)
3. [Test Types and What They Measure](#test-types-and-what-they-measure)
4. [Performance Counters and Metrics](#performance-counters-and-metrics)
5. [Memory Management Strategy](#memory-management-strategy)
6. [System-Specific Decision Making](#system-specific-decision-making)
7. [Data Output and Interpretation](#data-output-and-interpretation)

---

## Testing Philosophy

### Why This Approach?

**Problem:** Default swap configurations often don't match hardware capabilities or workload characteristics.

**Solution:** Data-driven testing across multiple dimensions:
- **Storage performance** (block size, latency)
- **Compression efficiency** (ratio, CPU overhead)
- **Memory allocator behavior** (fragmentation, efficiency)
- **Concurrency scaling** (parallel I/O throughput)

### Synthetic vs. Realistic Testing

We use a **three-tier testing approach**:

1. **Synthetic Tests** (Block Size I/O)
   - Pure sequential I/O patterns
   - Identifies raw hardware limits
   - Simple to interpret, hardware-specific

2. **Semi-Realistic Tests** (Compression)
   - Controlled memory pressure with varied data patterns
   - Tests actual swapping behavior
   - Balances realism with reproducibility

3. **Realistic Tests** (Allocator, Concurrency)
   - Real ZRAM operation under memory pressure
   - Actual parallel swap I/O
   - Represents production workloads

---

## Why ZSWAP Over ZRAM

### The Fundamental Problem with ZRAM

ZRAM is a block device that compresses pages in RAM. When combined with disk swap at lower priority, it creates a tiered system:

```
Application Memory
       ↓
   [ZRAM] (priority 100) - Compressed in RAM
       ↓ (when full)
   [Disk Swap] (priority 10) - Uncompressed on disk
```

**Critical Problem**: Pages "stick" in ZRAM forever:
- No automatic migration of cold pages to disk
- Cold (inactive) pages waste valuable RAM
- Hot (active) pages may end up on slow disk
- No LRU-based rebalancing

ZRAM only frees space when:
- ✓ Process exits/terminates
- ✓ Page is swapped in AND modified
- ✗ **Never**: automatic cold page eviction
- ✗ **Never**: migration to disk tier

### How ZSWAP Solves This

ZSWAP is a compressed write-through cache for swap pages:

```
Application Memory
       ↓
   [ZSWAP Cache] (in RAM) - LRU-managed compressed cache
       ↓ (automatic writeback)
   [Disk Swap] - Backing store, cold pages evicted from cache
```

**ZSWAP Page Lifecycle:**

1. **Swap out**: Compress to ZSWAP cache (RAM) + Write uncompressed to disk
2. **Cache fills**: Shrinker identifies cold pages (LRU) and evicts them
3. **Swap in (hot)**: Read from ZSWAP cache (~10-20µs)
4. **Swap in (cold)**: Read from disk (~500µs-10ms)

### Performance Implications

| Scenario | ZRAM Behavior | ZSWAP Behavior |
|----------|---------------|----------------|
| After hours of use | Cold data wastes RAM | Cold data on disk, hot data cached |
| Memory pressure | New data goes to slow disk | Hot data replaces cold in cache |
| Active/idle mix | No differentiation | Automatic hot/cold separation |
| OOM risk | ZRAM fills, no reclaim | Shrinker reclaims cache |

### Recommendation

**Always use ZSWAP** regardless of RAM size:
- **Small RAM (1-4GB)**: ZSWAP maximizes effective memory with compression
- **Medium RAM (4-16GB)**: ZSWAP provides best balance of speed and capacity
- **Large RAM (16GB+)**: ZSWAP still optimal, larger cache for hot data

---

## Test Types and What They Measure

### 1. Block Size I/O Tests

**What we test:**
```python
# Block sizes: 4KB, 8KB, 16KB, 32KB, 64KB, 128KB
for block_size in [4, 8, 16, 32, 64, 128]:
    benchmark_block_size_fio(block_size, runtime_sec=5)
```

**Why this way:**
- Uses `fio` (Flexible I/O Tester) for accurate, reproducible I/O measurements
- Tests both sequential and random I/O patterns
- Maps directly to `vm.page-cluster` kernel parameter
  - `page-cluster=0` → 4KB pages
  - `page-cluster=3` → 32KB (8 pages)
  - `page-cluster=5` → 128KB (32 pages)

**Performance counters collected:**
```json
{
  "block_size_kb": 64,
  "write_mb_per_sec": 450.5,
  "read_mb_per_sec": 520.3,
  "write_latency_ms": 2.1,
  "read_latency_ms": 1.8,
  "io_pattern": "sequential",
  "elapsed_sec": 10.2
}
```

**Decision impact:**
- **SSD systems:** Optimal at 32-64KB (higher throughput, lower latency)
- **HDD systems:** Optimal at 64-128KB (amortizes seek time)
- **NVMe systems:** May benefit from 128KB or higher

**Access pattern:** Pure sequential I/O (not representative of swap's mixed pattern)

### What is the Matrix Test?

The **Block Size × Concurrency Matrix Test** combines two dimensions:

```python
# Tests all combinations: 6 block sizes × 5 concurrency levels = 30 tests
block_sizes = [4, 8, 16, 32, 64, 128]  # KB
concurrency_levels = [1, 2, 4, 6, 8]   # parallel jobs

for block_size in block_sizes:
    for concurrency in concurrency_levels:
        test_combination(block_size, concurrency)
```

**Key differences from individual tests:**

| Test Type | Block Sizes | Concurrency | Access Pattern | Purpose | Status |
|-----------|-------------|-------------|----------------|---------|--------|
| **Block Size Test** | All sizes | Fixed (1) | Sequential | Find optimal `vm.page-cluster` | **DEPRECATED** - use matrix test instead |
| **Concurrency Test** | Fixed (64KB) | All levels | Parallel sequential | Find optimal stripe width | **DEPRECATED** - use matrix test instead |
| **Matrix Test** | All sizes | All levels | Mixed random read/write | Find **best combination** | **PRIMARY** - comprehensive and realistic |

**Individual tests are now deprecated:**
- Block size test = matrix results where concurrency=1
- Concurrency test = matrix results where block_size=64KB
- **Use `--test-matrix` or `--test-all`** for comprehensive testing
- Individual tests maintained only for backward compatibility

**Why matrix test is critical:**
- Individual tests don't reveal interaction effects
- Optimal block size may differ at high concurrency
- Example: 32KB might be best at concurrency=1, but 64KB best at concurrency=8
- Matrix reveals the **inflection point** where performance plateaus

**Access pattern in tests:**
- **Block Size Test (DEPRECATED):** Pure sequential read/write (simplest case)
- **Concurrency Test (DEPRECATED):** Multiple parallel sequential streams (more realistic)
- **Matrix Test:** Mixed random read/write (`rw=randrw`) - most realistic swap simulation

**Real swap access pattern (now implemented in matrix test):**
- **Write pattern:** Random writes in blocks = `vm.page-cluster` size
  - Kernel writes pages as they're evicted (pseudo-random addresses)
  - Clustering controlled by `vm.page-cluster` (groups adjacent pages)
- **Read pattern:** Logical vs Physical access
  - **Logical (application view):** Semi-sequential - applications access related memory regions
  - **Physical (disk view):** With striped swap files, logical sequential reads become physically random
  - Fragmentation over time: Pages scattered across multiple swap files
  - Example: Reading 5 sequential logical pages may hit 5 different physical swap files
  - **Real-world implication:** Pure sequential test patterns overestimate performance

**Matrix test now uses mixed patterns:**
- ✅ **IMPLEMENTED:** Matrix test uses `rw=randrw` for mixed random read/write
- Simulates: concurrent eviction (writes) + page faults (reads)
- Better represents real swap behavior with striped files and fragmentation
- 50/50 read/write mix provides balanced workload simulation

**Bandwidth vs. Latency tradeoffs:**

| Metric | Matters For | Optimization Strategy |
|--------|-------------|----------------------|
| **Bandwidth** | High RAM compression (ZRAM/ZSWAP) | Larger block sizes (64-128KB), more concurrency |
| **Latency** | Application responsiveness on swap-ins | Smaller block sizes (32-64KB), optimize for single-threaded access |
| **Both** | Production systems | Balance via matrix test results |

**Configuration recommendations:**
- **Low-latency priority** (interactive workloads): Use matrix results at concurrency=1-2
- **High-bandwidth priority** (batch workloads, high ZRAM): Use matrix results at concurrency=6-8
- **Balanced** (general use): Use matrix results at concurrency=4

### 2. Compression Algorithm Tests

**What we test:**
```python
# Compressors: lz4 (fast), zstd (balanced), lzo-rle (moderate)
for compressor in ['lz4', 'zstd', 'lzo-rle']:
    benchmark_compression(compressor, allocator='zsmalloc', size_mb=256)
```

**Why this way:**
- **C-based memory allocation** (`mem_pressure.c`): 100x faster than Python for large allocations
- **Mixed data patterns** (pattern type 0): Realistic workload with varied compressibility
  - 25% random (low compression) → ~1.2x ratio
  - 25% repeated (medium) → ~2.5x ratio
  - 25% zeros (high) → ~10x+ ratio
  - 25% sequential (medium) → ~2.0x ratio
- **Actual memory pressure**: Allocates MORE than available RAM to force swapping
- **300-second timeout**: Prevents tests from hanging indefinitely

**Performance counters collected:**
```json
{
  "compressor": "lz4",
  "allocator": "zsmalloc",
  "test_size_mb": 256,
  "orig_size_mb": 245.3,        // Actual data swapped
  "compr_size_mb": 98.7,        // Compressed size in ZRAM
  "mem_used_mb": 102.1,         // Memory used (includes overhead)
  "compression_ratio": 2.48,     // orig_size / compr_size
  "efficiency_pct": 58.3,        // (orig - mem_used) / orig * 100
  "duration_sec": 24.5
}
```

**Key metrics explained:**

1. **Compression Ratio** (`orig_size / compr_size`):
   - How much memory is effectively gained
   - Example: 2.5x means 1GB RAM can hold 2.5GB of data
   - **Typical values:**
     - lz4: 2.0-2.5x (fast, moderate compression)
     - zstd: 2.5-3.5x (slower, better compression)
     - lzo-rle: 2.0-2.3x (fast, moderate compression)

2. **Space Efficiency** (`(orig_size - mem_used) / orig_size * 100`):
   - Accounts for allocator overhead
   - Negative values indicate overhead > savings (inefficient allocator)
   - **Interpretation:**
     - >50%: Good efficiency, allocator overhead is reasonable
     - 0-50%: Moderate efficiency, some overhead
     - <0%: Poor efficiency, overhead exceeds compression benefits

3. **ZRAM `mm_stat` fields** (from `/sys/block/zram0/mm_stat`):
   ```
   Field 0: orig_data_size - Original uncompressed data size
   Field 1: compr_data_size - Compressed data size
   Field 2: mem_used_total - Total memory used (compressed + metadata)
   ```

**Decision impact:**
- **Low RAM systems:** Choose zstd for better compression ratio
- **CPU-constrained:** Choose lz4 for lower CPU overhead
- **Balanced systems:** zstd offers best overall value

### 3. Memory Allocator Tests

**What we test:**
```python
# Allocators: zsmalloc (best compression), z3fold (balanced), zbud (low overhead)
for allocator in ['zsmalloc', 'z3fold', 'zbud']:
    benchmark_compression('lz4', allocator, size_mb=256)
```

**Why this way:**
- Tests allocator efficiency with the same compressor (lz4) for fair comparison
- Measures actual memory usage vs. theoretical
- Identifies fragmentation characteristics

**Allocator characteristics:**

1. **zsmalloc** (~90% **theoretical** efficiency):
   - Best compression ratio
   - Higher CPU overhead
   - Suitable for: Low RAM systems, memory-critical workloads
   - **Theoretical:** Stores up to 3+ pages per zspage (up to ~90% efficiency)
   - **Actual:** Results vary based on data compressibility and fragmentation

2. **z3fold** (~75% **theoretical** efficiency):
   - Balanced approach
   - Moderate CPU overhead
   - Suitable for: General-purpose systems
   - **Theoretical:** Stores 3 pages per zspage (75% efficiency when full)
   - **Actual:** Efficiency depends on how many pages fit per zspage

3. **zbud** (~50% **theoretical** efficiency):
   - Lowest CPU overhead
   - 2 pages per zspage (50% theoretical efficiency)
   - Suitable for: CPU-bottlenecked systems
   - **Theoretical:** Maximum 2 pages per zspage = 50% efficiency
   - **Actual:** Often matches theoretical closely (~50%)

**Why actual results differ from theoretical:**

The theoretical values (90%, 75%, 50%) represent **maximum possible efficiency** under ideal conditions:
- **Assumes perfect page packing** (all zspages are completely full)
- **Ignores metadata overhead** (page tables, allocator structures)
- **Ignores fragmentation** (partially filled zspages reduce efficiency)

**Real-world example from test output:**
```
💾 Allocator Performance:
  zsmalloc: 2.6x ratio, +54% eff (-3% vs best)
  z3fold  : 2.8x ratio, +57% eff ⭐
  zbud    : 2.8x ratio, +57% eff (-0% vs best)
```

**Analysis:**
- All show similar compression ratios (2.6-2.8x) - **expected** (same compressor)
- Efficiency ~54-57% - **much lower** than theoretical 50-90%
- Why? Compression ratio includes **both** compressor and allocator effects
- The "efficiency" metric accounts for total memory used (compressed data + overhead)

**Correct interpretation:**
1. **Compression ratio = compressor effect + allocator packing**
2. **Efficiency % = (orig_size - mem_used) / orig_size × 100**
3. **mem_used = compressed_size + allocator_overhead + metadata**

For 2.6x compression ratio:
- Compressor reduces 1GB → ~385MB (2.6x)
- Allocator adds overhead → final mem_used ~440MB
- Efficiency: (1024 - 440) / 1024 = 57%

**Testing improvements to verify allocator behavior:**
- Add detailed logging of `mm_stat` fields per test
- Compare same data with different allocators (isolate allocator effect)
- Test with highly compressible data (zeros) to maximize allocator differences
- Graph: compression_ratio vs efficiency_pct for each allocator

**Performance counters:**
Same as compression tests, but with allocator comparison focus.

**Decision impact:**
- Compare `efficiency_pct` across allocators
- Choose allocator based on CPU vs. memory trade-off
- For similar efficiency, choose allocator with lower CPU overhead

### 4. Concurrency Tests

**What we test:**
```python
# File counts: 1, 2, 4, 8, 16 swap files/devices
for num_files in [1, 2, 4, 8, 16]:
    test_concurrency(num_files, file_size_mb=128)
```

**Why this way:**
- Tests parallel I/O throughput
- Identifies optimal stripe width for swap
- Uses fio with multiple jobs for realistic parallel load

**Performance counters collected:**
```json
{
  "num_files": 8,
  "write_mb_per_sec": 1850.3,
  "read_mb_per_sec": 2100.7,
  "write_iops": 14802,
  "read_iops": 16806,
  "write_scaling_efficiency": 92.5,
  "read_scaling_efficiency": 94.8
}
```

**Decision impact:**
- **Scaling efficiency** shows how well throughput scales with concurrency
- Optimal file count typically matches or exceeds CPU core count
- Diminishing returns beyond 8-16 files on most systems
- Helps configure `SWAP_STRIPE_WIDTH` parameter

### 5. Memory-Only Comparison (ZRAM vs ZSWAP)

**What we test:**
```python
# Compare ZRAM with different compressors
results = {
    'zram_lz4': benchmark_compression('lz4', 'zsmalloc', 100),
    'zram_zstd': benchmark_compression('zstd', 'zsmalloc', 100)
}
```

**Why this way:**
- Direct comparison of memory-only swap performance
- No disk I/O interference
- Measures pure compression/decompression latency

**Decision impact:**
- Determines if ZRAM vs disk-backed swap is better for workload
- Identifies best compressor for memory-only swap

---

## Memory Management Strategy

### Why C-Based Memory Allocation?

**Problem:** Python-based memory allocation for 7GB+ is extremely slow:
- Python: ~2919 seconds (48+ minutes) for allocation + pattern generation
- C: ~21 seconds (100x faster for allocation + pattern generation)

**Performance breakdown:**
- C allocation speed: ~330 MB/s (7GB in 21s)
  - This includes malloc() + pattern generation + memory access
  - Pattern generation is CPU-bound, not memory-bound
  - Actual RAM write bandwidth is much higher (~5-10 GB/s typically)
- The 21s includes: allocation time + filling with patterns + forcing pages into RAM
- Pure memory bandwidth is not the bottleneck; pattern computation is

**Optimization opportunity:**
- **Current approach:** Fill entire 7GB with patterns (CPU-intensive)
- **Alternative approach:** 
  - Block 7GB with malloc() to prevent interference (fast)
  - Only generate patterns for the ~300MB test area actually used for swap tests
  - Could reduce pattern generation time from ~21s to ~1s
  - **Trade-off:** More complex code vs faster test setup

**Root causes of Python slowness:**
1. Python's bytearray allocation is slow for large sizes (memory management overhead)
2. List comprehensions and loops for pattern generation are extremely inefficient
3. Byte-by-byte operations don't leverage CPU cache or SIMD instructions
4. Python's GIL (Global Interpreter Lock) prevents parallel memory operations

**Solution: `mem_pressure.c`**

```c
// Fast memory allocation with efficient patterns
size_t total_size = MB_TO_BYTES(size_mb);
char *memory = malloc(total_size);

// Fast fill using memset and direct pointer operations
for (size_t filled = 0; filled < total_size; filled += CHUNK_SIZE) {
    fill_pattern(memory + filled, chunk_size, pattern_type, filled);
    // Report progress every 64MB
}
```

**Key features:**
- Bulk allocation with `malloc()`
- Efficient filling with `memset()` and pointer arithmetic
- Progress reporting (64MB chunks)
- Multiple pattern types for varied compressibility

### Memory Locking Strategy

**Problem:** Other processes' memory can interfere with swap tests, causing:
- Unpredictable swap usage
- System instability during tests
- Inconsistent benchmark results

**Solution: `mem_locker.c`**

```c
// Lock free RAM to prevent interference
size_t lock_size = available_mb - test_size_mb - 500_mb_buffer;
void *memory = malloc(lock_size);
mlock(memory, lock_size);  // Pin in physical RAM
// Stay resident until test completes
```

**Memory distribution:**
```
Total 16GB RAM System:
├── Test Memory: 256MB (ZRAM swap target)
├── Safety Buffer: 500MB (system operations)
└── Locked Memory: 15244MB (prevented from swapping)
```

**Benefits:**
1. **Predictable results:** Only test memory is swapped
2. **System stability:** Safety buffer prevents OOM
3. **No interference:** Other processes' memory stays resident

### Timeout Mechanism

**Why 300 seconds?**
- Prevents indefinite hanging (original problem: 2919+ seconds)
- Sufficient for legitimate tests (typical: 20-60 seconds)
- Configurable via `COMPRESSION_TEST_TIMEOUT_SEC` constant

**Implementation:**
```python
try:
    result = subprocess.run(
        [mem_pressure_path, str(alloc_size_mb), '0', '15'],
        timeout=COMPRESSION_TEST_TIMEOUT_SEC  # 300 seconds
    )
except subprocess.TimeoutExpired:
    log_warn_ts(f"Test timed out after {COMPRESSION_TEST_TIMEOUT_SEC}s")
    # Cleanup and continue to next test
```

---

## System-Specific Decision Making

### How Benchmark Results Guide Configuration

The benchmark suite generates a **shell configuration file** with optimal settings:

```bash
# Example: benchmark-optimal-config.sh

# Optimal block size for this storage
SWAP_PAGE_CLUSTER=4  # 64KB blocks (best throughput: 520 MB/s)

# Best compressor for this workload
ZSWAP_COMPRESSOR=zstd  # 3.2x compression ratio
ZRAM_COMPRESSOR=zstd

# Best allocator for this system
ZRAM_ALLOCATOR=zsmalloc  # 62% efficiency

# Optimal concurrency
SWAP_STRIPE_WIDTH=8  # Best throughput: 1850 MB/s write, 2100 MB/s read
```

### Decision Tree

```
┌─────────────────────────────────────────────────────────┐
│ System Analysis                                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ 1. Storage Type Detection                               │
│    ├─ SSD: Use 32-64KB blocks (page-cluster=3-4)       │
│    ├─ HDD: Use 64-128KB blocks (page-cluster=4-5)      │
│    └─ NVMe: Use 128KB+ blocks (page-cluster=5+)        │
│                                                         │
│ 2. RAM Availability                                     │
│    ├─ Low (<4GB): zstd + zsmalloc (max compression)    │
│    ├─ Medium (4-16GB): zstd + z3fold (balanced)        │
│    └─ High (>16GB): lz4 + z3fold (speed priority)      │
│                                                         │
│ 3. CPU Resources                                        │
│    ├─ Limited: lz4 + zbud (low overhead)               │
│    ├─ Moderate: lz4 + z3fold (balanced)                │
│    └─ Abundant: zstd + zsmalloc (max compression)      │
│                                                         │
│ 4. Workload Pattern                                     │
│    ├─ I/O intensive: Optimize stripe width (8-16)      │
│    ├─ Memory intensive: Optimize compression (zstd)    │
│    └─ CPU intensive: Minimize overhead (lz4 + zbud)    │
└─────────────────────────────────────────────────────────┘
```

### Real-World Examples

**Example 1: Budget VPS (2GB RAM, 2 CPU cores)**
```bash
# Benchmark results:
# - lz4: 2.1x ratio, 55% efficiency, 18s duration
# - zstd: 3.2x ratio, 58% efficiency, 45s duration
# Decision: Use zstd despite slower speed (RAM is bottleneck)

ZRAM_COMPRESSOR=zstd
ZRAM_ALLOCATOR=zsmalloc
SWAP_PAGE_CLUSTER=3  # 32KB (moderate I/O)
```

**Example 2: High-performance server (64GB RAM, 16 CPU cores)**
```bash
# Benchmark results:
# - lz4: 2.2x ratio, 52% efficiency, 12s duration
# - zstd: 3.1x ratio, 55% efficiency, 38s duration
# Decision: Use lz4 for lower latency (RAM not constrained)

ZRAM_COMPRESSOR=lz4
ZRAM_ALLOCATOR=z3fold
SWAP_PAGE_CLUSTER=4  # 64KB (SSD optimized)
SWAP_STRIPE_WIDTH=16  # High concurrency for parallel I/O
```

**Example 3: Development workstation (16GB RAM, 8 cores, SSD)**
```bash
# Benchmark results:
# - 64KB blocks: 520 MB/s read, 450 MB/s write
# - 8 concurrent files: 1850 MB/s write, 2100 MB/s read
# Decision: Balanced configuration

ZSWAP_COMPRESSOR=zstd
ZRAM_COMPRESSOR=zstd
ZRAM_ALLOCATOR=z3fold
SWAP_PAGE_CLUSTER=4  # 64KB (SSD sweet spot)
SWAP_STRIPE_WIDTH=8  # Matches core count
```

---

## Data Output and Interpretation

### JSON Output Format

Complete benchmark results are saved to JSON for programmatic analysis:

```json
{
  "system_info": {
    "ram_gb": 16,
    "cpu_cores": 8,
    "available_gb": 14.2,
    "page_cluster": 3
  },
  "timestamp": "2026-01-06T09:15:00",
  "compression_test_size_mb": 256,
  "block_sizes": [
    {
      "block_size_kb": 64,
      "write_mb_per_sec": 450.5,
      "read_mb_per_sec": 520.3,
      "write_latency_ms": 2.1,
      "read_latency_ms": 1.8,
      "elapsed_sec": 10.2
    }
  ],
  "compressors": [
    {
      "compressor": "lz4",
      "allocator": "zsmalloc",
      "orig_size_mb": 245.3,
      "compr_size_mb": 98.7,
      "mem_used_mb": 102.1,
      "compression_ratio": 2.48,
      "efficiency_pct": 58.3,
      "duration_sec": 24.5
    },
    {
      "compressor": "zstd",
      "allocator": "zsmalloc",
      "orig_size_mb": 243.8,
      "compr_size_mb": 76.2,
      "mem_used_mb": 78.9,
      "compression_ratio": 3.20,
      "efficiency_pct": 67.6,
      "duration_sec": 42.1
    }
  ],
  "allocators": [...],
  "concurrency": [...],
  "total_elapsed_sec": 185.3
}
```

### Performance Charts

Generated PNG charts visualize results:

1. **`benchmark-throughput-TIMESTAMP.png`**
   - Block size vs. throughput (read/write)
   - Identifies optimal I/O size

2. **`benchmark-latency-TIMESTAMP.png`**
   - Block size vs. latency
   - Shows latency trade-offs

3. **`benchmark-concurrency-TIMESTAMP.png`**
   - Concurrency vs. throughput scaling
   - Shows parallel I/O efficiency

4. **`benchmark-compression-TIMESTAMP.png`**
   - Compression ratio and efficiency comparison
   - Visual comparison of compressors/allocators

### Telegram Integration

Results are automatically sent via Telegram (if configured):

```python
# HTML-formatted results with visual indicators
html_message = format_benchmark_html(results)
telegram.send_message(html_message)

# Charts as attachments
for chart_file in chart_files:
    telegram.send_document(chart_file, caption=f"📊 {chart_name}")
```

Example Telegram output:
```
📊 Swap Benchmark Results

💻 System: 16GB RAM, 8 CPU cores

📦 Block Size Performance:
  64KB: ██████████ ↑450.5 ↓520.3 MB/s ⭐

🗜️ Compressor Performance:
  lz4    : ████████░░ 2.5x ratio, +58% eff
  zstd   : ██████████ 3.2x ratio, +68% eff ⭐
  lzo-rle: ███████░░░ 2.2x ratio, +55% eff

⚡ Concurrency Scaling:
  8 files: ██████████ ↑1850 ↓2100 MB/s ⭐
```

---

## Performance Validation

### Expected Test Duration

| Test Type | Size | Expected Duration | Timeout |
|-----------|------|-------------------|---------|
| Block Size | 1GB | 10-15 seconds | 60s |
| Compression | 256MB | 20-45 seconds | 300s |
| Allocator | 256MB | 20-45 seconds | 300s |
| Concurrency | 128MB × N | 30-90 seconds | 600s |

### Validation Checks

The benchmark includes automatic validation:

1. **Compression ratio sanity checks:**
   ```python
   if ratio < 1.5 or ratio > 10.0:
       log_warn(f"Suspicious compression ratio: {ratio}x")
   ```

2. **Swap activity validation:**
   ```python
   min_expected = test_size_mb * 0.5  # 50% minimum
   if actual_swapped < min_expected:
       log_warn("Insufficient swap activity")
   ```

3. **Timeout detection:**
   ```python
   if test_duration > COMPRESSION_TEST_TIMEOUT_SEC:
       log_error("Test timed out - possible system issue")
   ```

---

## Summary

### What We Test
1. **Block size I/O** - Hardware limits and optimal page-cluster
2. **Compression algorithms** - Ratio, efficiency, CPU overhead
3. **Memory allocators** - Fragmentation, overhead, efficiency
4. **Concurrency** - Parallel I/O scaling and optimal stripe width
5. **Memory-only** - ZRAM vs ZSWAP comparison

### Why This Way
- **C-based allocation**: 100x faster, prevents system hangs
- **Mixed data patterns**: Realistic workload simulation
- **Actual memory pressure**: Forces real swapping behavior
- **Timeout protection**: Prevents indefinite hangs (300s limit)
- **Memory locking**: Ensures predictable, stable results

### Performance Counters Generated
- **I/O metrics**: throughput (MB/s), latency (ms), IOPS
- **Compression metrics**: ratio, efficiency, memory usage
- **Timing metrics**: duration, elapsed time
- **System metrics**: RAM usage, CPU overhead

### Decision Support
- **Storage optimization**: Optimal block size → `vm.page-cluster`
- **Compression choice**: Best algorithm → `ZRAM_COMPRESSOR`
- **Allocator selection**: Efficiency trade-off → `ZRAM_ALLOCATOR`
- **Concurrency tuning**: Stripe width → `SWAP_STRIPE_WIDTH`

The benchmark suite transforms raw performance data into actionable configuration decisions, tailored to each system's unique hardware and workload characteristics.

---

## 6. Memory Access Latency Tests

### What We Test

**Comprehensive latency measurement across the entire swap stack:**

1. **Native RAM Baseline**
   - Pure RAM read/write speed without any swap overhead
   - Provides the "ideal" performance target
   - Typical results: 50-150 ns/page

2. **ZRAM Write Latency** (Page-out / Swap-out)
   - Time to compress and store a page in swap
   - Measured using `madvise(MADV_PAGEOUT)` to force page-out
   - Tests with different data patterns (random, zeros, mixed)
   - Per-page timing with high-precision `clock_gettime()`
   - Typical results: 5-50 µs/page depending on compressor

3. **ZRAM Read Latency** (Page Fault + Decompress)
   - Time to handle a page fault and decompress data
   - Tests both sequential and random access patterns
   - Measures real page fault latency in microseconds
   - Typical results: 10-100 µs/page depending on compressor

4. **Impact of Compressor Choice**
   - **lz4**: Lowest latency (~10-30 µs read, ~5-15 µs write)
   - **zstd**: Higher latency (~30-60 µs read, ~15-35 µs write) but better compression
   - **lzo-rle**: Moderate latency (~15-35 µs read, ~8-20 µs write)

5. **Impact of Allocator Choice**
   - **zsmalloc**: More complex lookup, +20-30% read latency, best compression
   - **z3fold**: Balanced performance
   - **zbud**: Fastest lookup, lowest read latency, but 50% space overhead

6. **Access Pattern Effects**
   - **Sequential**: Best case, prefetch can help
   - **Random**: Worst case, realistic for many workloads
   - **Stride**: Tests cache behavior

### Why This Matters

**Throughput vs Latency:**
- Throughput measures bulk performance (MB/s)
- Latency measures responsiveness (µs per operation)
- P95/P99 latencies indicate worst-case behavior
- Critical for interactive workloads where responsiveness matters

**Real-world implications:**
- **Application stalls**: Each page fault blocks the application thread
- **Memory pressure response**: Write latency affects how fast the system can free memory
- **Interactive performance**: High read latency causes UI freezes
- **Batch workloads**: Can tolerate higher latency if throughput is good

### Performance Counters Collected

**Per-operation latency (microseconds):**
```json
{
  "min_read_us": 8.2,      // Best case
  "avg_read_us": 28.3,     // Average
  "max_read_us": 120.5,    // Worst case
  "p50_read_us": 25.1,     // Median
  "p95_read_us": 45.8,     // 95th percentile
  "p99_read_us": 78.2      // 99th percentile
}
```

**Throughput metrics:**
- `pages_per_sec`: Operations per second
- `mb_per_sec`: Throughput in MB/s

**Baseline comparison:**
- Slowdown factor vs native RAM (e.g., "280x slower")

### How Tests Work

**1. Write Latency Test (`mem_write_bench.c`)**

```c
// Process:
1. Allocate memory with mmap()
2. Fill with test pattern (random, zeros, mixed, sequential)
3. For each page:
   - Start high-precision timer
   - Call madvise(MADV_PAGEOUT) to force swap-out
   - Stop timer
   - Record latency
4. Calculate percentile statistics (p50, p95, p99)
5. Output JSON results
```

**2. Read Latency Test (`mem_read_bench.c`)**

```c
// Process:
1. Allocate and fill memory
2. Force all pages to swap out with MADV_PAGEOUT
3. Wait for swap-out to complete
4. For each page (sequential, random, or stride pattern):
   - Start high-precision timer
   - Read from page (triggers page fault)
   - Stop timer
   - Record latency
5. Calculate percentile statistics
6. Output JSON results
```

**3. Native RAM Baseline (`benchmark_native_ram_baseline()`)**

```python
# Process:
1. Allocate memory (NO swap configured)
2. Measure pure RAM write speed
3. Measure pure RAM read speed
4. Calculate bandwidth (GB/s)
5. Provides comparison baseline
```

### Expected Results

**Typical latency ranges:**

| Configuration | Read Latency (avg) | Write Latency (avg) | vs RAM Slowdown |
|---------------|-------------------|---------------------|-----------------|
| Native RAM    | 50-150 ns         | 50-150 ns          | 1x (baseline)   |
| lz4 + zsmalloc | 20-35 µs         | 10-18 µs           | 200-350x        |
| lz4 + zbud    | 15-28 µs         | 8-15 µs            | 150-280x        |
| zstd + zsmalloc | 35-60 µs        | 20-40 µs           | 350-600x        |

**Allocator impact:**
- zsmalloc: +20-30% read overhead vs zbud (complex lookup)
- zbud: Fastest lookup, best read latency
- z3fold: Middle ground

**Compressor impact:**
- zstd: ~50-80% slower than lz4 (decompression overhead)
- lzo-rle: ~20-40% slower than lz4
- Trade-off: Better compression vs lower latency

### Decision Impact

**Choose based on workload characteristics:**

**1. Interactive/Desktop (latency-sensitive):**
```bash
# Minimize latency for responsive UI
ZRAM_COMPRESSOR=lz4
ZRAM_ALLOCATOR=zbud  # Fastest lookup
```
- Lowest read latency for page faults
- Quick memory pressure response
- Acceptable compression ratio (2-2.5x)

**2. Server/Batch (throughput-oriented):**
```bash
# Maximize compression, latency less critical
ZRAM_COMPRESSOR=zstd
ZRAM_ALLOCATOR=zsmalloc  # Best compression
```
- Better compression ratio (2.5-3.5x)
- More effective memory extension
- Higher latency acceptable for background work

**3. Database/Random Access (balanced):**
```bash
# Balance between latency and compression
ZRAM_COMPRESSOR=lz4
ZRAM_ALLOCATOR=z3fold  # Balanced
```
- Moderate read latency
- Decent compression
- Good for random access patterns

**4. Low RAM Systems (memory-critical):**
```bash
# Need maximum compression despite latency
ZRAM_COMPRESSOR=zstd
ZRAM_ALLOCATOR=zsmalloc
```
- Best compression to extend limited RAM
- Accept higher latency as necessary trade-off
- System would be unusable without swap anyway

### Example Output

**Command:**
```bash
sudo ./benchmark.py --test-latency --latency-size 100
```

**Console output:**
```
=== Phase 1: Native RAM Baseline ===
[INFO] Native RAM read: 85 ns/page (11.8 GB/s)
[INFO] Native RAM write: 92 ns/page (10.9 GB/s)

=== Phase 2: Write Latency Tests ===
[1/4] lz4 + zsmalloc: avg=12.5µs, p95=18.7µs, p99=28.4µs
[2/4] lz4 + zbud: avg=9.8µs, p95=15.2µs, p99=23.1µs
[3/4] zstd + zsmalloc: avg=25.3µs, p95=38.9µs, p99=52.7µs
[4/4] zstd + zbud: avg=21.7µs, p95=33.4µs, p99=45.8µs

=== Phase 3: Read Latency Tests ===
[1/4] lz4 + zsmalloc (sequential): avg=24.1µs, p95=35.8µs
[2/4] lz4 + zsmalloc (random): avg=28.3µs, p95=42.1µs
[3/4] zstd + zsmalloc (sequential): avg=38.7µs, p95=56.2µs
[4/4] zstd + zsmalloc (random): avg=45.2µs, p95=68.5µs

=== Latency Comparison Summary ===
Baseline (Native RAM):
  Read:  85 ns/page
  Write: 92 ns/page

lz4      + zsmalloc write:   12.5µs (136x slower than RAM)
lz4      + zbud     write:    9.8µs (106x slower than RAM)
zstd     + zsmalloc write:   25.3µs (275x slower than RAM)
zstd     + zbud     write:   21.7µs (236x slower than RAM)

lz4      + zsmalloc read (sequential):  24.1µs (284x slower than RAM)
lz4      + zsmalloc read (random    ):  28.3µs (333x slower than RAM)
zstd     + zsmalloc read (sequential):  38.7µs (455x slower than RAM)
zstd     + zsmalloc read (random    ):  45.2µs (532x slower than RAM)
```

**JSON output:**
```json
{
  "latency_comparison": {
    "baseline": {
      "read_ns": 85,
      "write_ns": 92,
      "read_gb_per_sec": 11.8,
      "write_gb_per_sec": 10.9
    },
    "write_latency": [
      {
        "compressor": "lz4",
        "allocator": "zsmalloc",
        "avg_write_us": 12.5,
        "p50_write_us": 11.8,
        "p95_write_us": 18.7,
        "p99_write_us": 28.4,
        "pages_per_sec": 80000,
        "mb_per_sec": 312.5
      }
    ],
    "read_latency": [
      {
        "compressor": "lz4",
        "allocator": "zsmalloc",
        "access_pattern": "random",
        "avg_read_us": 28.3,
        "p50_read_us": 26.1,
        "p95_read_us": 42.1,
        "p99_read_us": 65.8,
        "pages_per_sec": 35300
      }
    ]
  }
}
```

### Interpretation Guidelines

**1. Understanding the Numbers:**

- **Baseline (ns)**: Native RAM is measured in nanoseconds (billionths of a second)
- **Swap (µs)**: ZRAM operations are measured in microseconds (millionths of a second)
- **Slowdown factor**: Shows how much slower swap is vs RAM (typically 100-600x)
- **This is expected**: Compression/decompression inherently adds latency

**2. Percentiles Matter:**

- **P50 (median)**: Typical case performance
- **P95**: 95% of operations complete within this time
- **P99**: 99% of operations complete within this time (worst case excluding outliers)
- **High P99**: Indicates occasional very slow operations (investigate if >3x P50)

**3. Read vs Write:**

- **Write latency**: Affects memory pressure response speed
  - Lower write latency = faster memory reclamation
  - Important during memory pressure events
- **Read latency**: Affects application responsiveness
  - Lower read latency = less application stall time
  - Critical for interactive workloads

**4. Sequential vs Random:**

- **Sequential**: Best case, kernel can predict and prefetch
- **Random**: Realistic worst case for many applications
- **Small difference**: Good! Means allocator lookup is efficient
- **Large difference (>50%)**: Consider different allocator

**5. Making Decisions:**

**Use latency data when:**
- System will have interactive workloads
- Application responsiveness matters
- P95/P99 latencies are concerns
- Choosing between similar compression ratios

**Use compression ratio when:**
- RAM is severely constrained
- Batch/background workloads
- Latency less critical than capacity

**Example decision:**
```
Scenario: 4GB system, interactive desktop use

Option A: zstd + zsmalloc
  - Compression: 3.2x (effective 12.8GB)
  - Read latency: P95 = 56µs
  - Write latency: P95 = 39µs

Option B: lz4 + zbud
  - Compression: 2.1x (effective 8.4GB)
  - Read latency: P95 = 32µs (-43% vs Option A)
  - Write latency: P95 = 15µs (-62% vs Option A)

Decision: Choose Option B (lz4 + zbud)
  - 8.4GB still adequate for 4GB system
  - Much better responsiveness for interactive use
  - Lower P95 latencies mean fewer UI freezes
```

### Validation and Sanity Checks

**Expected ranges (flag if outside these):**

- **Native RAM**: 50-200 ns/page
- **ZRAM read**: 10-100 µs/page
- **ZRAM write**: 5-50 µs/page
- **Slowdown vs RAM**: 100-800x

**Warnings:**

- P99 > 3x P50: Investigate variance (memory fragmentation? CPU throttling?)
- Read > 100µs: Check for system issues
- Write > 50µs: May indicate CPU bottleneck or driver issues
- Random ~= Sequential: Good allocator efficiency
- Random >> Sequential (>2x): Consider different allocator

### Use in CI/CD

**Regression detection:**
```bash
# Run latency tests before/after changes
./benchmark.py --test-latency --latency-size 100 --output before.json
# ... make changes ...
./benchmark.py --test-latency --latency-size 100 --output after.json

# Compare results (Python script)
python compare_latency.py before.json after.json
# Fail build if P95 read latency increases >20%
```

### Limitations

**What latency tests DON'T measure:**

- **Long-term effects**: Fragmentation over hours/days
- **Mixed workload interference**: How different apps affect each other
- **Thermal throttling**: Performance degradation over time
- **Memory pressure cascades**: Complex multi-level swapping
- **Application-specific patterns**: Each app has unique access patterns

**For production validation:**
- Use application-specific benchmarks
- Test with real workloads
- Monitor P99 latencies over time
- Consider APM tools for production monitoring
