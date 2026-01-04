# Memory Analysis for Running Systems

Comprehensive guide to analyzing memory usage, working sets, and optimization opportunities on live Linux systems.

## Overview

This guide covers advanced memory analysis tools and techniques:
- DAMON/DAMO for working set analysis
- KSM (Kernel Same-page Merging) for deduplication
- Hot/cold page identification
- Memory pressure analysis

---

## DAMON/DAMO - Data Access Monitoring

### What is DAMON?

DAMON (Data Access MONitor) is a kernel subsystem for monitoring memory access patterns with minimal overhead.

**Key features:**
- Low overhead (~1% CPU)
- Identifies hot/cold memory regions
- Working set size estimation
- Access pattern heatmaps
- Page-level access tracking

### Installation

```bash
# Install DAMO (DAMON user-space tool)
pip3 install damo

# Verify installation
damo version
```

### Kernel Requirements

DAMON requires specific kernel configuration options:

```bash
# Check if kernel supports DAMON
grep -E 'CONFIG_DAMON|CONFIG_DAMON_' /boot/config-$(uname -r)
```

**Required options:**
- `CONFIG_DAMON=y` - Core DAMON support
- `CONFIG_DAMON_VADDR=y` - Virtual address monitoring
- `CONFIG_DAMON_PADDR=y` - Physical address monitoring
- `CONFIG_DAMON_SYSFS=y` - Sysfs interface (kernel 5.15+)
- `CONFIG_DAMON_DBGFS=y` - Debugfs interface (older)

**On Debian:**
```bash
# Most recent Debian kernels (Bookworm+) include DAMON
apt install linux-image-amd64  # Latest kernel

# Reboot to new kernel if updated
uname -r  # Check current kernel version
```

### Basic Usage

#### 1. Monitor Specific Process

```bash
# Monitor process by PID
damo start -t $(pidof nginx)

# Let it run for monitoring period
sleep 60

# Stop and generate report
damo report
```

#### 2. System-Wide Monitoring

```bash
# Monitor all processes
damo start --all

# Monitor for specific duration
damo start --all --duration 300s  # 5 minutes

# Generate working set analysis
damo report --sort wss
```

#### 3. Generate Heatmap

```bash
# Monitor and create access heatmap
damo start -t $(pidof postgres)
sleep 120
damo report --plot heatmap --output /tmp/heatmap.png
```

### Working Set Analysis

**Working set** = actively used memory pages

```bash
# Start monitoring
damo start -t $(pidof java) --monitor working_set

# After collection period
damo report --working-set-sizes

# Output format:
# Time    WSS (MB)    Access Rate
# 10s     256         85%
# 20s     312         78%
# 30s     298         82%
```

**Interpreting results:**
- High WSS = Process needs more RAM
- Low access rate = Memory can be compressed/swapped
- Stable WSS = Predictable behavior
- Fluctuating WSS = Bursty workload

### Hot/Cold Page Analysis

```bash
# Identify hot (frequently accessed) regions
damo start -t $(pidof mysql)
sleep 300  # 5 minute sample
damo report --sort hotness

# Export hot/cold regions
damo report --hot-cold-ratio --threshold 10
```

**Output interpretation:**
- **Hot pages (>10 accesses/sec):** Keep in RAM, never swap
- **Warm pages (1-10 accesses/sec):** Good candidates for compression
- **Cold pages (<1 access/sec):** Safe to swap to disk

### Recommendations Based on DAMON Data

```bash
# After collecting data, use damo recommendations
damo recommend --target memory_efficiency

# Possible recommendations:
# - Increase swap for cold pages
# - Enable KSM for duplicate detection
# - Adjust vm.swappiness based on access patterns
# - Reclaim cold caches more aggressively
```

### Example Analysis Script

```bash
#!/bin/bash
# analyze-with-damon.sh

PID=${1:-$(pidof nginx)}
DURATION=${2:-300}

echo "Starting DAMON monitoring for PID $PID"
damo start -t $PID --duration ${DURATION}s &

# Wait for completion
sleep $((DURATION + 5))

echo "Generating reports..."
damo report --working-set-sizes > wss-report.txt
damo report --hot-cold-ratio --threshold 5 > hotcold-report.txt
damo report --plot heatmap --output heatmap.png

echo "Analysis complete!"
echo "- Working set: wss-report.txt"
echo "- Hot/cold ratio: hotcold-report.txt"
echo "- Heatmap: heatmap.png"
```

---

## KSM - Kernel Same-page Merging

### What is KSM?

KSM scans memory to find identical pages and merges them, keeping only one copy with copy-on-write semantics.

**Use cases:**
- Multiple VMs with same OS
- Container hosts running similar images
- Processes with shared data structures
- Deduplication of read-only data

**Important:** ONLY works on pages marked as mergeable by applications (via `madvise(MADV_MERGEABLE)`).

### KSM Statistics Location

All KSM statistics are in `/sys/kernel/mm/ksm/`:

```bash
ls -1 /sys/kernel/mm/ksm/
# full_scans
# pages_shared
# pages_sharing
# pages_unshared
# pages_volatile
# pages_to_scan
# sleep_millisecs
# run
# merge_across_nodes
# ...
```

### Understanding KSM Statistics

#### Core Counters

**1. `pages_shared`** - Number of unique pages being shared
```bash
cat /sys/kernel/mm/ksm/pages_shared
# Example: 12500
```
This is the number of unique pages that KSM found duplicates of.

**2. `pages_sharing`** - Number of sites sharing those pages
```bash
cat /sys/kernel/mm/ksm/pages_sharing
# Example: 87500
```
This is the total number of duplicate page references.

**3. `pages_unshared`** - Checked but not duplicated
```bash
cat /sys/kernel/mm/ksm/pages_unshared
# Example: 234000
```
Pages that were scanned but have no duplicates.

**4. `pages_volatile`** - Changed too frequently to merge
```bash
cat /sys/kernel/mm/ksm/pages_volatile
# Example: 5600
```
Pages that changed during the scan process.

#### Calculate Memory Saved

**Formula:**
```
Memory Saved = (pages_sharing - pages_shared) × 4KB
```

**Example:**
```bash
shared=$(cat /sys/kernel/mm/ksm/pages_shared)
sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
saved_kb=$((($sharing - $shared) * 4))
saved_mb=$(($saved_kb / 1024))

echo "Memory saved: ${saved_mb} MB"
# Output: Memory saved: 292 MB
```

**Interpretation:**
- `pages_shared = 12,500` → 12,500 unique pages (50 MB)
- `pages_sharing = 87,500` → 87,500 duplicate references (350 MB total)
- **Saved = 350 MB - 50 MB = 300 MB**

#### Calculate Deduplication Ratio

**Formula:**
```
Dedup Ratio = pages_sharing / pages_shared
```

**Example:**
```bash
shared=$(cat /sys/kernel/mm/ksm/pages_shared)
sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)

if [ $shared -gt 0 ]; then
    ratio=$(awk "BEGIN {printf \"%.2f\", $sharing / $shared}")
    echo "Deduplication ratio: ${ratio}:1"
else
    echo "No pages shared yet"
fi
# Output: Deduplication ratio: 7.00:1
```

**Interpretation:**
- Ratio 1:1 = No benefit (no duplicates found)
- Ratio 2:1 = Each unique page is duplicated once (50% savings)
- Ratio 7:1 = Each unique page appears 7 times (85% savings)
- Ratio 10:1 = Excellent deduplication (90% savings)

### KSM Configuration

#### Enable KSM

```bash
# Start KSM scanning
echo 1 > /sys/kernel/mm/ksm/run

# Verify it's running
cat /sys/kernel/mm/ksm/run
# Output: 1
```

#### Adjust Scan Rate

```bash
# Pages to scan per iteration
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan

# Sleep between iterations (milliseconds)
echo 20 > /sys/kernel/mm/ksm/sleep_millisecs

# More aggressive scanning:
# - Higher pages_to_scan = more pages per iteration
# - Lower sleep_millisecs = less delay between iterations
```

**Trade-off:**
- Aggressive: Find duplicates faster, higher CPU usage
- Conservative: Lower CPU usage, slower duplicate detection

#### Monitor Scan Progress

```bash
# Number of complete scans
cat /sys/kernel/mm/ksm/full_scans

# Watch scans in real-time
watch -n 5 cat /sys/kernel/mm/ksm/full_scans
```

### Complete KSM Statistics Example

```bash
#!/bin/bash
# ksm-stats.sh - Display comprehensive KSM statistics

echo "=== KSM Status ==="
run=$(cat /sys/kernel/mm/ksm/run)
if [ "$run" = "1" ]; then
    echo "Status: RUNNING"
else
    echo "Status: STOPPED"
fi

echo ""
echo "=== KSM Statistics ==="
shared=$(cat /sys/kernel/mm/ksm/pages_shared)
sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
unshared=$(cat /sys/kernel/mm/ksm/pages_unshared)
volatile=$(cat /sys/kernel/mm/ksm/pages_volatile)
scans=$(cat /sys/kernel/mm/ksm/full_scans)

echo "Pages shared:    $shared ($(($shared * 4 / 1024)) MB)"
echo "Pages sharing:   $sharing ($(($sharing * 4 / 1024)) MB)"
echo "Pages unshared:  $unshared ($(($unshared * 4 / 1024)) MB)"
echo "Pages volatile:  $volatile ($(($volatile * 4 / 1024)) MB)"
echo "Full scans:      $scans"

echo ""
echo "=== Memory Savings ==="
if [ $shared -gt 0 ]; then
    saved_kb=$((($sharing - $shared) * 4))
    saved_mb=$(($saved_kb / 1024))
    ratio=$(awk "BEGIN {printf \"%.2f\", $sharing / $shared}")
    
    echo "Memory saved:    ${saved_mb} MB"
    echo "Dedup ratio:     ${ratio}:1"
    
    # Calculate percentage saved
    total_kb=$(($sharing * 4))
    if [ $total_kb -gt 0 ]; then
        pct=$(awk "BEGIN {printf \"%.1f\", ($saved_kb * 100.0) / $total_kb}")
        echo "Savings:         ${pct}%"
    fi
else
    echo "No pages shared yet - no savings"
fi

echo ""
echo "=== Scan Configuration ==="
echo "Pages to scan:   $(cat /sys/kernel/mm/ksm/pages_to_scan)"
echo "Sleep (ms):      $(cat /sys/kernel/mm/ksm/sleep_millisecs)"
```

---

## KSM Trial Script Concept

A trial script to test KSM benefits without permanent changes:

### Purpose
1. Save current KSM settings
2. Enable aggressive KSM temporarily
3. Run 3 full scans to find duplicates
4. Report memory savings
5. Provide recommendation
6. Optionally restore settings

### Implementation

```bash
#!/bin/bash
# ksm-trial.sh - Test KSM benefits

set -euo pipefail

# Save current settings
ORIG_RUN=$(cat /sys/kernel/mm/ksm/run)
ORIG_PAGES=$(cat /sys/kernel/mm/ksm/pages_to_scan)
ORIG_SLEEP=$(cat /sys/kernel/mm/ksm/sleep_millisecs)

cleanup() {
    echo "Restoring original settings..."
    echo $ORIG_RUN > /sys/kernel/mm/ksm/run
    echo $ORIG_PAGES > /sys/kernel/mm/ksm/pages_to_scan
    echo $ORIG_SLEEP > /sys/kernel/mm/ksm/sleep_millisecs
}

trap cleanup EXIT

echo "=== KSM Trial ==="
echo "This will temporarily enable aggressive KSM scanning"
echo "Press Ctrl+C to abort..."
sleep 3

# Enable aggressive scanning
echo "Configuring aggressive KSM..."
echo 5000 > /sys/kernel/mm/ksm/pages_to_scan
echo 10 > /sys/kernel/mm/ksm/sleep_millisecs
echo 1 > /sys/kernel/mm/ksm/run

# Record initial state
initial_scans=$(cat /sys/kernel/mm/ksm/full_scans)
target_scans=$((initial_scans + 3))

echo "Waiting for 3 full scans (this may take several minutes)..."

# Wait for 3 complete scans
while [ $(cat /sys/kernel/mm/ksm/full_scans) -lt $target_scans ]; do
    current=$(cat /sys/kernel/mm/ksm/full_scans)
    echo -ne "Scans: $((current - initial_scans))/3\r"
    sleep 5
done

echo ""
echo "Scans complete! Analyzing results..."
sleep 2

# Calculate savings
shared=$(cat /sys/kernel/mm/ksm/pages_shared)
sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)

if [ $shared -gt 0 ]; then
    saved_mb=$(( ($sharing - $shared) * 4 / 1024 ))
    ratio=$(awk "BEGIN {printf \"%.2f\", $sharing / $shared}")
    
    echo ""
    echo "=== Results ==="
    echo "Memory saved: ${saved_mb} MB"
    echo "Dedup ratio:  ${ratio}:1"
    echo ""
    
    # Recommendation
    if [ $saved_mb -gt 100 ]; then
        echo "✅ RECOMMENDATION: Keep KSM enabled"
        echo "   Significant memory savings detected (>100 MB)"
    elif [ $saved_mb -gt 20 ]; then
        echo "⚠️  RECOMMENDATION: Consider keeping KSM enabled"
        echo "   Moderate savings (20-100 MB), evaluate CPU vs memory trade-off"
    else
        echo "❌ RECOMMENDATION: Disable KSM"
        echo "   Low savings (<20 MB), not worth CPU overhead"
    fi
else
    echo ""
    echo "=== Results ==="
    echo "No duplicate pages found"
    echo ""
    echo "❌ RECOMMENDATION: Disable KSM"
    echo "   Your workload does not benefit from deduplication"
fi

echo ""
read -p "Keep KSM enabled? (y/N): " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "KSM will remain enabled with current settings"
    trap - EXIT  # Don't restore on exit
else
    echo "Restoring original settings..."
fi
```

### Recommendation Thresholds

| Memory Saved | Recommendation | Rationale |
|--------------|----------------|-----------|
| **>100 MB** | ✅ Keep KSM enabled | Significant savings justify CPU cost |
| **20-100 MB** | ⚠️ Consider enabling | Evaluate based on CPU headroom |
| **<20 MB** | ❌ Disable KSM | Savings too small for overhead |

---

## Working Set Estimation

### Method 1: Using DAMON/DAMO

```bash
# Monitor for 5 minutes and estimate working set
damo start --all --duration 300s
damo report --working-set-sizes

# Output shows pages actively used
# Working Set Size = Pages × 4KB
```

### Method 2: Using /proc/PID/smaps

```bash
#!/bin/bash
# working-set.sh - Estimate working set from referenced pages

PID=${1:-$(pidof nginx)}

total_rss=0
total_referenced=0

while IFS= read -r line; do
    if [[ $line =~ ^Rss:[[:space:]]+([0-9]+) ]]; then
        rss=${BASH_REMATCH[1]}
        total_rss=$((total_rss + rss))
    elif [[ $line =~ ^Referenced:[[:space:]]+([0-9]+) ]]; then
        ref=${BASH_REMATCH[1]}
        total_referenced=$((total_referenced + ref))
    fi
done < /proc/$PID/smaps

echo "Process: $PID"
echo "Total RSS: $((total_rss / 1024)) MB"
echo "Referenced (working set): $((total_referenced / 1024)) MB"
echo "Working set ratio: $(awk "BEGIN {printf \"%.1f\", ($total_referenced * 100.0) / $total_rss}")%"
```

### Method 3: Page Reference Bits

```bash
# Clear reference bits
echo 1 > /proc/sys/vm/compact_memory

# Wait for workload
sleep 60

# Check referenced pages
grep Referenced /proc/$(pidof nginx)/smaps | awk '{sum+=$2} END {print sum/1024" MB"}'
```

---

## Memory Pressure Analysis

### PSI (Pressure Stall Information)

```bash
# Check memory pressure
cat /proc/pressure/memory
# Output:
# some avg10=0.00 avg60=0.03 avg300=0.12 total=1234567
# full avg10=0.00 avg60=0.00 avg300=0.00 total=234567

# Interpretation:
# - some: some tasks stalled on memory
# - full: all tasks stalled (severe)
# - avg10: average % over last 10 seconds
# - avg60: average % over last 60 seconds
# - avg300: average % over last 5 minutes
```

**Thresholds:**
- `full avg10 > 5%` - Severe memory pressure
- `full avg60 > 2%` - Significant pressure
- `some avg10 > 10%` - Moderate pressure

### Memory Statistics

```bash
# Overall memory info
free -h

# Detailed VM statistics
cat /proc/vmstat | grep -E 'pgmajfault|pswpin|pswpout|pgfault'

# Per-process memory
ps aux --sort=-rss | head -20

# Memory map of specific process
pmap -x $(pidof nginx)
```

---

## Recommendations Based on Analysis

### If DAMON shows:
- **High working set, low access rate** → Enable ZSWAP, increase swap
- **Low working set, high access rate** → Keep pages in RAM, reduce swappiness
- **Many cold pages** → Aggressive swap is safe
- **Fluctuating access patterns** → Use priority-based tiering (ZRAM + swap)

### If KSM shows:
- **Dedup ratio >5:1** → Keep KSM enabled
- **Dedup ratio 2-5:1** → Monitor CPU vs savings
- **Dedup ratio <2:1** → Disable KSM
- **No duplicates** → Not applicable for workload

### If PSI shows:
- **full avg10 >5%** → Critical - add RAM or reduce workload
- **full avg60 >2%** → Serious - optimize memory usage
- **some avg10 >10%** → Monitor - possible optimization needed
- **All low values** → System healthy

---

## Complete Analysis Script

```bash
#!/bin/bash
# comprehensive-memory-analysis.sh

echo "=== System Memory Overview ==="
free -h

echo ""
echo "=== Memory Pressure (PSI) ==="
cat /proc/pressure/memory

echo ""
echo "=== Swap Status ==="
swapon --show

echo ""
echo "=== Page Fault Statistics ==="
grep -E 'pgmajfault|pgfault' /proc/vmstat

echo ""
echo "=== KSM Statistics ==="
if [ -f /sys/kernel/mm/ksm/pages_shared ]; then
    shared=$(cat /sys/kernel/mm/ksm/pages_shared)
    sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
    if [ $shared -gt 0 ]; then
        saved_mb=$(( ($sharing - $shared) * 4 / 1024 ))
        echo "Memory saved by KSM: ${saved_mb} MB"
    else
        echo "KSM: No pages shared"
    fi
else
    echo "KSM not available"
fi

echo ""
echo "=== DAMON Availability ==="
if command -v damo &>/dev/null; then
    echo "DAMO installed: $(damo version)"
else
    echo "DAMO not installed (pip3 install damo)"
fi

if grep -q CONFIG_DAMON=y /boot/config-$(uname -r) 2>/dev/null; then
    echo "Kernel DAMON support: YES"
else
    echo "Kernel DAMON support: NO (requires kernel 5.15+)"
fi

echo ""
echo "=== Top Memory Consumers ==="
ps aux --sort=-rss | head -10 | awk '{printf "%-10s %6s %6s %s\n", $1, $4"%", $6/1024"M", $11}'
```

---

## Tools Summary

| Tool | Purpose | Installation | Kernel Version |
|------|---------|--------------|----------------|
| **DAMON/DAMO** | Working set analysis | `pip3 install damo` | 5.15+ |
| **KSM** | Page deduplication | Built-in | All |
| **PSI** | Pressure monitoring | Built-in | 4.20+ |
| **/proc/vmstat** | VM statistics | Built-in | All |
| **smaps** | Process memory maps | Built-in | All |

---

## References

- [DAMON Documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/damon/index.html)
- [KSM Documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/ksm.html)
- [PSI Documentation](https://facebookmicrosites.github.io/psi/)
- [DAMO GitHub](https://github.com/awslabs/damo)

---

This completes the memory analysis documentation. Use these tools to understand your system's memory behavior and optimize accordingly.
