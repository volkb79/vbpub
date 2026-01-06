# Testing Methodology and Performance Metrics Documentation

## Overview

This document explains the comprehensive testing approach used in `benchmark.py` to evaluate and optimize swap configurations for Debian systems. The benchmark suite provides actionable data for making system-specific swap configuration decisions.

---

## Table of Contents

1. [Testing Philosophy](#testing-philosophy)
2. [Test Types and What They Measure](#test-types-and-what-they-measure)
3. [Performance Counters and Metrics](#performance-counters-and-metrics)
4. [Memory Management Strategy](#memory-management-strategy)
5. [System-Specific Decision Making](#system-specific-decision-making)
6. [Data Output and Interpretation](#data-output-and-interpretation)

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

1. **zsmalloc** (~90% efficiency):
   - Best compression ratio
   - Higher CPU overhead
   - Suitable for: Low RAM systems, memory-critical workloads

2. **z3fold** (~75% efficiency):
   - Balanced approach
   - Moderate CPU overhead
   - Suitable for: General-purpose systems

3. **zbud** (~50% efficiency):
   - Lowest CPU overhead
   - 2 pages per zspage (50% theoretical efficiency)
   - Suitable for: CPU-bottlenecked systems

**Performance counters:**
Same as compression tests, but with allocator comparison focus.

**Decision impact:**
- Compare `efficiency_pct` across allocators
- Choose allocator based on CPU vs. memory trade-off

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
- Python: ~2919 seconds (48+ minutes)
- C: ~21 seconds (100x faster)

**Root causes:**
1. Python's bytearray allocation is slow for large sizes
2. List comprehensions for pattern generation are inefficient
3. Byte-by-byte operations don't leverage CPU cache

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
