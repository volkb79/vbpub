# Benchmark Chart Examples

## Chart Overview
The benchmark suite generates 6 comprehensive charts for matrix tests + 1 ZSWAP time-series chart.

---

## Chart 1: Throughput Heatmap
**File**: `matrix-throughput-{timestamp}.png`

```
┌─────────────────────────────────────┐
│  Write Throughput (MB/s)            │
│                                      │
│  Concurrency →                      │
│  32 │ █████████████████████████     │
│  16 │ ████████████████████          │
│   8 │ ███████████████               │
│   4 │ ██████████                    │
│   2 │ ███████                       │
│   1 │ ████                          │
│     └─────────────────────          │
│       4KB  16KB  64KB  256KB  1MB   │
│            Block Size                │
└─────────────────────────────────────┘

Color scale: Dark (low) → Bright (high)
Shows: Peak performance zones at a glance
```

---

## Chart 2: Throughput vs Block Size (Line Chart)
**File**: `matrix-throughput-vs-blocksize-{timestamp}.png`

```
Write Throughput vs Block Size      |  Read Throughput vs Block Size
                                     |
3000 ┤                               |  3000 ┤
     │        ╭───── C=32            |       │        ╭───── C=32
2500 ┤      ╭─┴───── C=16            |  2500 ┤      ╭─┴───── C=16
     │    ╭─┴──────── C=8            |       │    ╭─┴──────── C=8
2000 ┤  ╭─┴────────── C=4            |  2000 ┤  ╭─┴────────── C=4
     │╭─┴──────────── C=2            |       │╭─┴──────────── C=2
1500 ┼┴────────────── C=1            |  1500 ┼┴────────────── C=1
     │                               |       │
MB/s │                               |  MB/s │
     └─────────────────────          |       └─────────────────────
       4   16   64  256  1024 KB     |         4   16   64  256  1024 KB
              Block Size (log)        |                Block Size (log)

Insight: Shows throughput scaling with block size for each concurrency
```

---

## Chart 3: Throughput vs Concurrency (Line Chart)
**File**: `matrix-throughput-vs-concurrency-{timestamp}.png`

```
Write Throughput vs Concurrency     |  Read Throughput vs Concurrency
                                    |
3000 ┤                              |  3000 ┤
     │            ╭────── 1MB       |       │            ╭────── 1MB
2500 ┤          ╭─┤───── 512KB      |  2500 ┤          ╭─┤───── 512KB
     │        ╭─┤ │────── 256KB     |       │        ╭─┤ │────── 256KB
2000 ┤      ╭─┤ │ │─────── 128KB   |  2000 ┤      ╭─┤ │ │─────── 128KB
     │    ╭─┤ │ │ └──────── 64KB   |       │    ╭─┤ │ │ └──────── 64KB
1500 ┤  ╭─┤ │ │ └────────── 32KB   |  1500 ┤  ╭─┤ │ │ └────────── 32KB
     │╭─┘ │ │ └──────────── 16KB   |       │╭─┘ │ │ └──────────── 16KB
1000 ┼┘   └─┴─────────────── 4KB   |  1000 ┼┘   └─┴─────────────── 4KB
MB/s │                              |  MB/s │
     └─────────────────            |       └─────────────────
       1   4   8  16  32            |         1   4   8  16  32
          Concurrency                |            Concurrency

Insight: Shows throughput scaling with parallel operations for each block size
```

---

## Chart 4: Latency Heatmap (EXISTING)
**File**: `matrix-latency-{timestamp}.png`

```
┌─────────────────────────────────────┐
│  Write Latency (µs)                 │
│                                      │
│  Concurrency →                      │
│  32 │ ░░░░░░░░░░░░░░░░░░░░░░░░     │
│  16 │ ░░░░░░░░░░░░░░░░░░░░          │
│   8 │ ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒               │
│   4 │ ▓▓▓▓▓▓▓▓▓▓                    │
│   2 │ ███████                       │
│   1 │ ████                          │
│     └─────────────────────          │
│       4KB  16KB  64KB  256KB  1MB   │
│            Block Size                │
└─────────────────────────────────────┘

Color scale: Dark (high latency) → Bright (low latency)
Shows: Latency hotspots at a glance
```

---

## Chart 5: Latency vs Block Size (NEW)
**File**: `matrix-latency-vs-blocksize-{timestamp}.png`

```
Write Latency vs Block Size         |  Read Latency vs Block Size
                                     |
500 ┤                                |  500 ┤
    │                  ╭── C=32      |      │                  ╭── C=32
400 ┤                ╭─┴─── C=16     |  400 ┤                ╭─┴─── C=16
    │              ╭─┴───── C=8      |      │              ╭─┴───── C=8
300 ┤            ╭─┴─────── C=4      |  300 ┤            ╭─┴─────── C=4
    │          ╭─┴───────── C=2      |      │          ╭─┴───────── C=2
200 ┤        ╭─┴─────────── C=1      |  200 ┤        ╭─┴─────────── C=1
    │      ╭─┘                       |      │      ╭─┘
100 ┤    ╭─┘                         |  100 ┤    ╭─┘
 µs │  ╭─┘                           |   µs │  ╭─┘
    │╭─┘                             |      │╭─┘
  0 ┼┘                               |    0 ┼┘
    └─────────────────────           |      └─────────────────────
      4   16   64  256  1024 KB      |        4   16   64  256  1024 KB
             Block Size (log)         |               Block Size (log)

Insight: Shows how latency changes with block size
Expected: Rising trend (larger blocks = more time)
```

---

## Chart 6: Latency vs Concurrency (NEW)
**File**: `matrix-latency-vs-concurrency-{timestamp}.png`

```
Write Latency vs Concurrency        |  Read Latency vs Concurrency
                                    |
500 ┤                               |  500 ┤
    │                  ╭────── 4KB  |      │                  ╭────── 4KB
400 ┤                ╭─┴───── 8KB   |  400 ┤                ╭─┴───── 8KB
    │              ╭─┴────── 16KB   |      │              ╭─┴────── 16KB
300 ┤            ╭─┴─────── 32KB    |  300 ┤            ╭─┴─────── 32KB
    │          ╭─┴──────── 64KB     |      │          ╭─┴──────── 64KB
200 ┤        ╭─┴───────── 128KB     |  200 ┤        ╭─┴───────── 128KB
    │      ╭─┴────────── 256KB      |      │      ╭─┴────────── 256KB
100 ┤    ╭─┴─────────── 512KB       |  100 ┤    ╭─┴─────────── 512KB
 µs │  ╭─┴──────────── 1MB          |   µs │  ╭─┴──────────── 1MB
    │╭─┘                            |      │╭─┘
  0 ┼┘                              |    0 ┼┘
    └─────────────────             |      └─────────────────
      1   4   8  16  32             |        1   4   8  16  32
         Concurrency                 |           Concurrency

Insight: Shows how latency scales with parallel operations
Ideal: Flat line (no contention)
Reality: Rising trend (queuing/contention)
```

---

## Chart 7: ZSWAP Stats Time-Series (NEW)
**File**: `zswap-stats-timeseries-{timestamp}.png`

```
┌────────────────────────────────────┬────────────────────────────────────┐
│ Pool Size (MB)                     │ Stored Pages                       │
│                                    │                                    │
│  200 ┤      ┌────────              │  50k ┤      ┌────────              │
│      │    ╱─┘                      │      │    ╱─┘                      │
│  150 ┤  ╱─                         │  40k ┤  ╱─                         │
│      │╱─                           │      │╱─                           │
│  100 ┼                             │  30k ┼                             │
│   MB │                             │ Pages│                             │
│      └──────────────               │      └──────────────               │
│        0   10   20   30  sec       │        0   10   20   30  sec       │
├────────────────────────────────────┼────────────────────────────────────┤
│ Written Back Pages                 │ Pool Limit Hits                    │
│                                    │                                    │
│  10k ┤              ┌──            │   50 ┤              ┌──            │
│      │            ╱─┘              │      │            ╱─┘              │
│   8k ┤          ╱─                 │   40 ┤          ╱─                 │
│      │        ╱─                   │      │        ╱─                   │
│   5k ┤      ╱─                     │   30 ┤      ╱─                     │
│ Pages│    ╱─                       │ Hits │    ╱─                       │
│      │  ╱─                         │      │  ╱─                         │
│    0 ┼──                           │    0 ┼──                           │
│      └──────────────               │      └──────────────               │
│        0   10   20   30  sec       │        0   10   20   30  sec       │
├────────────────────────────────────┼────────────────────────────────────┤
│ Compression Rejects                │ Allocation Failures                │
│                                    │                                    │
│  100 ┤                             │   20 ┤                             │
│      │        ╭─╮                  │      │                             │
│   80 ┤      ╭─┘ ╰─╮                │   15 ┤                             │
│      │    ╭─┘     ╰─╮              │      │    ╭─╮                      │
│   60 ┤  ╭─┘         ╰─╮            │   10 ┤  ╭─┘ ╰─╮                    │
│      │╭─┘             ╰─╮          │      │╭─┘     ╰─╮                  │
│   40 ┼┘                 ╰─         │    5 ┼┘         ╰─                │
│Reject│                             │ Fails│                             │
│      └──────────────               │      └──────────────               │
│        0   10   20   30  sec       │        0   10   20   30  sec       │
└────────────────────────────────────┴────────────────────────────────────┘

Insights:
- Pool Size plateau → Pool limit reached
- Writebacks correlated with Limit Hits → Normal writeback behavior
- High Compression Rejects → Incompressible data
- Allocation Failures → System under extreme pressure
```

---

## Chart Interpretation Guide

### Throughput Charts
**Good**: 
- Steep rise with block size (up to ~256KB)
- Linear scaling with concurrency
- Plateau indicates optimal configuration

**Bad**:
- Declining throughput at high concurrency (contention)
- No improvement with larger blocks (bottleneck)

### Latency Charts
**Good**:
- Flat or slowly rising with concurrency (scales well)
- Predictable rise with block size (expected)
- Tight clustering (consistent)

**Bad**:
- Sharp rise at low concurrency (contention early)
- Non-linear scaling (resource saturation)
- Wide variance (inconsistent performance)

### ZSWAP Stats
**Normal**:
- Pool size grows then plateaus (limit reached)
- Writebacks start when limit hit
- Low rejection rates (<5%)

**Warning Signs**:
- Pool size never fills → Increase test size
- High compression rejects → Wrong data for ZSWAP
- High allocation failures → System overloaded

---

## File Locations

All charts saved to: `/var/log/debian-install/`

```bash
# Matrix test charts (6 files):
matrix-throughput-20250106-202200.png
matrix-throughput-vs-blocksize-20250106-202200.png
matrix-throughput-vs-concurrency-20250106-202200.png
matrix-latency-20250106-202200.png
matrix-latency-vs-blocksize-20250106-202200.png          # NEW
matrix-latency-vs-concurrency-20250106-202200.png        # NEW

# ZSWAP latency test chart (1 file):
zswap-stats-timeseries-20250106-202200.png              # NEW
```

---

## Viewing Charts

### On Server (via SSH)
```bash
# Download to local machine:
scp user@server:/var/log/debian-install/matrix-*.png ./

# Or use X11 forwarding:
ssh -X user@server
display /var/log/debian-install/matrix-latency-vs-blocksize-*.png
```

### Automated Viewing
```bash
# Convert to WebP (smaller for transfer):
sudo python3 benchmark.py --test-matrix --webp

# Send to Telegram (if configured):
sudo python3 benchmark.py --test-matrix --telegram
```

---

## Chart Comparison

### Before Enhancements
```
Chart 1: Throughput heatmap
Chart 2: Throughput vs block size (line)
Chart 3: Throughput vs concurrency (line)
Chart 4: Latency heatmap

Total: 4 charts
Latency visualization: Heatmap only
ZSWAP monitoring: Final stats only (no graph)
```

### After Enhancements
```
Chart 1: Throughput heatmap
Chart 2: Throughput vs block size (line)
Chart 3: Throughput vs concurrency (line)
Chart 4: Latency heatmap
Chart 5: Latency vs block size (line)         ← NEW
Chart 6: Latency vs concurrency (line)        ← NEW
Chart 7: ZSWAP stats time-series (6 panels)   ← NEW

Total: 7 charts (4 → 7, +75% more visualization)
Latency visualization: Heatmap + 2 line charts
ZSWAP monitoring: Real-time 6-panel graph
```

---

## Summary

### Visualization Improvements
✅ **Latency**: Now same style as throughput (line charts)
✅ **ZSWAP**: Real-time monitoring instead of final stats
✅ **Consistency**: All metrics have both heatmap + line chart views
✅ **Insight**: Time-series reveals behavior during tests

### Chart Count
- Matrix test: 4 → 6 charts (+50%)
- ZSWAP test: 0 → 1 chart (new)
- Total: 4 → 7 charts (+75%)

### File Size
- PNG format: ~200-400KB per chart
- WebP format: ~50-100KB per chart (with --webp)
- Total disk usage: ~2-3MB per full test run
