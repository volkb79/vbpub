# Enhancement Implementation Plan

## Features to Implement

### 1. Multiple Data Pattern Testing for Allocators
**Current:** Single test with default (mixed) pattern  
**New:** Test each allocator with 4 data patterns:
- Pattern 0: Mixed (default) - realistic workload
- Pattern 1: Random - low compression
- Pattern 2: Zeros - high compression
- Pattern 3: Sequential - medium compression

**Impact:** Better understanding of allocator behavior under different workloads

### 2. Real-time ZSWAP Stats Graphing
**Current:** ZSWAP stats collected but not visualized  
**New:** Generate time-series graph showing:
- Pool size growth over time
- Writeback events
- Stored pages
- Pool limit hits

**Format:** PNG graph sent via Telegram

### 3. Latency Visualization Change
**Current:** Heatmap for latency (hard to read)  
**New:** Line diagram like throughput (easier to interpret)
- Same format as throughput vs block size
- Same format as throughput vs concurrency
- Show latency trends clearly

## Implementation Order

1. Add latency line charts (simplest, reuses existing code)
2. Add ZSWAP stats graphing function
3. Extend allocator testing with multiple patterns
4. Integrate all into main flow

## File Changes

- `benchmark.py`: Add new chart functions, extend allocator testing
- Update TODO list when complete
