# Visualization & Testing Enhancements

## Overview
Three major enhancements implemented to improve data quality and visualization in the benchmark suite:

1. **Multiple Data Pattern Testing for Allocators**
2. **Real-Time ZSWAP Stats Graphing**
3. **Latency Line Diagrams** (added line charts; heatmap retained)

---

## Feature 1: Multiple Data Pattern Testing

### Purpose
Test each memory allocator (zsmalloc, z3fold, zbud) with varied data patterns to reveal true performance differences under realistic workloads.

### Implementation
Previously: Single test per allocator (3 total tests)
Now: 4 tests per allocator × 3 allocators = **12 total tests**

### Data Patterns Tested
```
Pattern 0 (mixed):      Realistic workload - varied data
Pattern 1 (random):     Worst-case for compression
Pattern 2 (zeros):      Best-case for compression  
Pattern 3 (sequential): Predictable patterns
```

### Benefits
- **Reveals real differences**: Single-pattern tests showed similar results (~2.5x compression)
- **Identifies strengths/weaknesses**: Some allocators excel with specific data types
- **More comprehensive**: Tests both compression ratio AND allocator efficiency

### Usage
```bash
# Runs automatically with:
sudo python3 benchmark.py --test-allocators
sudo python3 benchmark.py --test-all

# Results include pattern info:
{
  "allocator": "zsmalloc",
  "data_pattern": "random",
  "pattern_id": 1,
  "compression_ratio": 1.2
}
```

### Expected Results
- **Zeros pattern**: Highest compression (5-10x typical)
- **Random pattern**: Lowest compression (1.0-1.5x typical)
- **Mixed/Sequential**: Medium compression (2-4x typical)
- **Allocator differences**: Visible across patterns (z3fold vs zsmalloc behavior differs)

---

## Feature 2: Real-Time ZSWAP Stats Graphing

### Purpose
Visualize ZSWAP behavior over time during latency tests to understand pool dynamics, writebacks, and rejection events.

### Implementation
- **Stats Collection**: Every 2 seconds during `mem_pressure` test
- **Time-Series Data**: Timestamps + ZSWAP stats snapshots
- **Chart Generation**: 6-panel matplotlib visualization

### Chart Panels
```
┌─────────────────────┬─────────────────────┐
│ Pool Size (MB)      │ Stored Pages        │
├─────────────────────┼─────────────────────┤
│ Writebacks          │ Pool Limit Hits     │
├─────────────────────┼─────────────────────┤
│ Compression Rejects │ Allocation Failures │
└─────────────────────┴─────────────────────┘
```

### Metrics Tracked
1. **pool_total_size**: Compressed pool size in MB (shows pool growth)
2. **stored_pages**: Number of pages in ZSWAP (shows activity)
3. **written_back_pages**: Pages evicted to disk (shows overflow)
4. **pool_limit_hit**: Pool capacity reached (triggers writeback)
5. **reject_compress_poor**: Pages rejected (poor compression)
6. **reject_alloc_fail**: Allocation failures (pressure indicator)

### Output
```bash
# Chart saved to:
/var/log/debian-install/zswap-stats-timeseries-20250106-202200.png

# Reference in results:
results['zswap_latency']['zswap']['stats_chart'] = "/var/log/.../zswap-stats-timeseries-*.png"
```

When `--telegram` is enabled, this chart is included with the other generated charts.

### Use Cases
- **Debug writeback issues**: See when pool limit is hit
- **Analyze compression effectiveness**: Track reject rates
- **Understand memory pressure**: Monitor allocation failures
- **Optimize pool settings**: Visualize max_pool_percent impact

### Example Insights
```
- Pool size plateaus → Pool limit reached, writeback active
- High reject_compress_poor → Data not compressible, wasting CPU
- Pool_limit_hit spikes → Frequent evictions, increase pool size
- Writebacks correlate with limit hits → Expected behavior
```

---

## Feature 3: Latency Line Diagrams

### Purpose
Add latency line charts for better trend visualization and easier comparison across configurations.

### Previous: Heatmaps
```
❌ Hard to see exact values
❌ Color interpretation subjective  
❌ Difficult to compare trends
```

### Now: Line Charts
```
✅ Clear trends visible
✅ Easy value reading
✅ Direct comparison across series
✅ Matches throughput visualization style
```

### Charts Generated
Previously: 1 latency heatmap (write + read combined)
Now: **3 latency charts**

#### Chart 4: Latency Heatmap (KEPT for overview)
- Combined write/read latency
- Quick visual summary
- Good for presentations

#### Chart 5: Latency vs Block Size (NEW)
- X-axis: Block sizes (4KB, 8KB, 16KB, ..., 1024KB) [log scale]
- Y-axis: Latency (microseconds)
- Lines: One per concurrency level (1, 2, 4, 8, 16, 32)
- Two subplots: Write latency | Read latency

**Insight**: Shows how latency changes with block size at different concurrency levels

#### Chart 6: Latency vs Concurrency (NEW)
- X-axis: Concurrency levels (1, 2, 4, 8, 16, 32)
- Y-axis: Latency (microseconds)
- Lines: One per block size (4KB, 8KB, ..., 1024KB)
- Two subplots: Write latency | Read latency

**Insight**: Shows how latency scales with parallel operations for each block size

### File Names
```bash
# Output files:
matrix-latency-20250106-202200.png                    # Heatmap (kept)
matrix-latency-vs-blocksize-20250106-202200.png      # Chart 5 (NEW)
matrix-latency-vs-concurrency-20250106-202200.png    # Chart 6 (NEW)
```

### Usage
```bash
# Generated automatically with matrix test:
sudo python3 benchmark.py --test-matrix

# Charts saved to:
/var/log/debian-install/matrix-latency-*.png
```

### Benefits
- **Trend analysis**: See if latency increases linearly, logarithmically, etc.
- **Optimal point identification**: Find sweet spot for block size × concurrency
- **Performance regression**: Compare before/after system changes
- **Consistency with throughput**: Same style as bandwidth charts

---

## Implementation Details

### Code Changes
```python
# File: benchmark.py

# 1. Added latency line charts (after heatmap generation)
#    Function: generate_matrix_heatmaps()

# 2. Added ZSWAP stats charting function
#    Function: generate_zswap_stats_chart(stats_timeseries, output_dir)

# 3. Modified ZSWAP latency test to collect stats
#    Function: benchmark_zswap_latency()
#    Change: Runs mem_pressure in background, samples stats every 2s

# 4. Extended allocator testing with patterns
#    Change: Nested loop - allocators × patterns

# 5. Updated benchmark_compression signature
#    Added: pattern parameter (default=0 for backward compatibility)
```

### Dependencies
- **matplotlib**: Already integrated (no new dependencies)
- **C programs**: mem_pressure, mem_locker (already compiled)
- **ZSWAP support**: Kernel 3.11+ (already required)

### Backward Compatibility
- ✅ Pattern parameter defaults to 0 (mixed) - existing code works unchanged
- ✅ ZSWAP charting optional - requires matplotlib
- ✅ Latency line charts supplement heatmap (not replace completely)

---

## Testing & Validation

### Verify Features
```bash
cd /home/vb/vbpub/scripts/debian-install

# 1. Test syntax
python3 -m py_compile benchmark.py
# ✓ No errors = syntax valid

# 2. Test allocator patterns (requires root)
sudo python3 benchmark.py --test-allocators
# Should see: "Testing 3 allocators with 4 data patterns each (12 total tests)"

# 3. Test ZSWAP with graphing (requires swap partitions)
sudo python3 benchmark.py --test-zswap-latency
# Should generate: zswap-stats-timeseries-*.png

# 4. Test matrix with new latency charts
sudo python3 benchmark.py --test-matrix
# Should generate 3 latency chart files
```

### Expected Output
```
Testing 3 allocators with 4 data patterns each (12 total tests)
[1/12] Compression test: lz4 with zsmalloc (mixed data, test size: 512MB)
✓ zsmalloc with mixed data: 2.8x compression
[2/12] Compression test: lz4 with zsmalloc (random data, test size: 512MB)
✓ zsmalloc with random data: 1.2x compression
[3/12] Compression test: lz4 with zsmalloc (zeros data, test size: 512MB)
✓ zsmalloc with zeros data: 8.5x compression
...

Memory pressure test completed in 33.2s
Collected 17 ZSWAP stat snapshots
Generated ZSWAP stats chart: /var/log/.../zswap-stats-timeseries-*.png

Generated latency vs block size chart: /var/log/.../matrix-latency-vs-blocksize-*.png
Generated latency vs concurrency chart: /var/log/.../matrix-latency-vs-concurrency-*.png
```

---

## Performance Impact

### Additional Time
- **Allocator tests**: 3x → 12 tests (~4x time increase)
  - Typical: 3 min → 12 min for allocator testing
  - Acceptable: Reveals critical insights

- **ZSWAP stats collection**: Negligible (~0.1s every 2s)
  - No noticeable performance impact
  - Runs in parallel with existing test

- **Chart generation**: +2 charts (~1-2s additional)
  - Minimal overhead
  - Parallel with other processing

### Total Impact
- `--test-allocators`: +9 min (acceptable for 4x more data)
- `--test-zswap-latency`: +0s (stats collection is free)
- `--test-matrix`: +2s (chart generation)

---

## Results Interpretation

### Allocator + Pattern Results
```json
{
  "allocators": [
    {
      "allocator": "zsmalloc",
      "data_pattern": "zeros",
      "pattern_id": 2,
      "compression_ratio": 8.5,
      "comment": "Excellent for uniform data"
    },
    {
      "allocator": "zsmalloc",
      "data_pattern": "random",
      "pattern_id": 1,
      "compression_ratio": 1.2,
      "comment": "Poor for random data (expected)"
    }
  ]
}
```

**Analysis**:
- Large variance = compression-dependent workload
- Small variance = allocator overhead dominates
- Best allocator = highest average across all patterns

### ZSWAP Stats Chart Interpretation
```
Pool Size graph:
- Steep rise → Fast memory pressure
- Plateau → Pool limit reached
- Decline → Writeback active

Writebacks graph:
- Correlated with pool_limit_hit → Normal behavior
- Independent spikes → External pressure
- Zero throughout → Pool never full (increase test size)

Rejection graphs:
- High reject_compress_poor → Incompressible data (e.g., encrypted)
- High reject_alloc_fail → System under heavy pressure
```

### Latency Line Chart Interpretation
```
Latency vs Block Size:
- Flat line → Latency independent of block size
- Rising trend → Larger blocks = higher latency (expected)
- Diverging lines → Concurrency impact varies by size

Latency vs Concurrency:
- Flat line → Perfect scaling (ideal)
- Rising trend → Contention/overhead
- Sharp rise → Resource saturation point
```

---

## Future Enhancements

### Potential Additions
1. **Interactive charts**: HTML/JavaScript for zoom/hover
2. **Compression ratio heatmap**: Allocator × Pattern grid
3. **Pattern auto-detection**: Analyze real workloads
4. **ZSWAP tuning recommendations**: Based on stats patterns
5. **Latency percentiles**: P50, P95, P99 on charts

### Not Implemented (Yet)
- Real-time chart updates (requires web server)
- Chart comparison tool (overlay multiple runs)
- Automated anomaly detection (statistical analysis)

---

## Summary

### What Changed
✅ Allocators tested with 4 data patterns (was: 1 pattern)
✅ ZSWAP stats visualized over time (was: final values only)
✅ Latency shown as line charts (was: heatmap only)

### Why It Matters
✅ **Better data quality**: Multiple patterns reveal true allocator behavior
✅ **Better insights**: Time-series shows what's happening during tests
✅ **Better visualization**: Line charts clearer than heatmaps for trends

### Impact
✅ **Code**: +150 lines (chart functions + loop modifications)
✅ **Time**: +9 min for allocator tests, +0s for ZSWAP, +2s for charts
✅ **Value**: Significantly improved data quality and visualization

---

**Implementation Date**: January 6, 2025
**Status**: ✅ Complete - Ready for testing
**Files Modified**: 
- `benchmark.py` (4990 lines, +150 LOC)
- Documentation: `VISUALIZATION_ENHANCEMENTS.md` (new)
