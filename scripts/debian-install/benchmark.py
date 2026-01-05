#!/usr/bin/env python3
"""
Swap Performance Benchmark Script
==================================

Comprehensive benchmark tool for testing swap configurations on Debian 12/13 systems.

OVERVIEW
--------
This tool provides both synthetic and semi-realistic performance testing for:
- Block size I/O performance (matching vm.page-cluster values)
- Compression algorithms (lz4, zstd, lzo-rle)
- Memory allocators (zsmalloc, z3fold, zbud)
- Concurrency with multiple swap devices
- ZRAM vs ZSWAP memory-only comparison

TEST TYPES
----------
1. **Block Size Tests** (SYNTHETIC)
   - Tests I/O performance with different block sizes (4KB-128KB)
   - Matches vm.page-cluster settings (0=4KB, 1=8KB, 2=16KB, 3=32KB, 4=64KB, 5=128KB)
   - Uses fio for accurate I/O measurement
   - Measures sequential read/write throughput and latency
   
2. **Compression Tests** (SEMI-REALISTIC)
   - Tests different compression algorithms with memory workloads
   - Creates actual memory pressure to trigger swapping
   - Measures compression ratio and performance
   - Tests with random, zero-filled, and pattern data
   
3. **Allocator Tests** (REALISTIC)
   - Tests zsmalloc (~90% efficiency), z3fold (~75%), zbud (~50%)
   - Measures actual memory usage vs theoretical
   - Identifies fragmentation characteristics
   
4. **Concurrency Tests** (REALISTIC)
   - Tests multiple swap files with parallel I/O
   - Measures throughput scaling with 1-16 files
   - Identifies optimal number of concurrent swap devices
   
5. **Memory-Only Comparison** (REALISTIC)
   - Compares ZRAM vs ZSWAP without disk backing
   - Measures latency differences
   - Tests with real application-like workloads

INTERPRETATION GUIDE
-------------------
**Block Size Results:**
- Higher throughput is better
- Lower latency is better  
- Match block size to storage type (SSD: 32-64KB, HDD: 64-128KB)
- vm.page-cluster should match optimal block size

**Compression Results:**
- Higher compression ratio = more effective memory extension
- lz4: Fastest, moderate compression (2-2.5x typical)
- zstd: Slower, better compression (2.5-3.5x typical)
- lzo-rle: Fast, moderate compression (2-2.3x typical)
- Choose based on CPU availability vs memory constraints

**Allocator Results:**
- zsmalloc: Best compression, higher CPU overhead, recommended for low RAM
- z3fold: Balanced, good for general use
- zbud: Lowest CPU, but 50% overhead, use when CPU is bottleneck

**Concurrency Results:**
- Throughput should scale linearly up to number of CPU cores
- Optimal file count typically matches or exceeds core count
- Default 8 files is good for most systems

USE CASES COVERED
----------------
✓ SSD optimization (find optimal block size)
✓ HDD optimization (larger block sizes)  
✓ Low RAM systems (best compression algorithm/allocator)
✓ High memory pressure (concurrency scaling)
✓ CPU-constrained systems (allocator selection)
✓ Quick vs thorough compression tradeoff

USE CASES NOT COVERED  
--------------------
✗ Real application-specific workloads (use application benchmarks)
✗ Long-term fragmentation effects (would require extended testing)
✗ Network-based swap (NFS, iSCSI)
✗ Hibernation performance
✗ Mixed workload interactions

SYNTHETIC VS REALISTIC
---------------------
**Synthetic Tests:**
- Block size I/O: Pure sequential I/O, not representative of random access patterns
- Simple to interpret, identifies hardware limits

**Semi-Realistic Tests:**
- Compression: Uses memory pressure but with controlled data patterns
- Good for comparing algorithms

**Realistic Tests:**
- Allocator: Actual ZRAM operation under memory pressure
- Concurrency: Real parallel swap I/O
- Memory-only: Actual swap cache behavior

DEPENDENCIES
-----------
- python3
- fio (for I/O benchmarking): apt install fio
- Root privileges (for system configuration)
- gawk (for calculations)

EXAMPLES
--------
# Test all configurations
sudo ./benchmark.py --test-all

# Test specific block size
sudo ./benchmark.py --block-size 64

# Test compressors only
sudo ./benchmark.py --test-compressors

# Test all allocators  
sudo ./benchmark.py --test-allocators

# Test concurrency scaling
sudo ./benchmark.py --test-concurrency 8

# Compare ZRAM vs ZSWAP
sudo ./benchmark.py --compare-memory-only

# Export results
sudo ./benchmark.py --test-all --output results.json --shell-config optimal.conf
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# Optional telegram client import (for --telegram flag)
try:
    sys.path.insert(0, str(Path(__file__).parent))
    from telegram_client import TelegramClient
    TELEGRAM_AVAILABLE = True
except ImportError:
    TELEGRAM_AVAILABLE = False
    TelegramClient = None

# Optional matplotlib import (for chart generation)
try:
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend
    import matplotlib.pyplot as plt
    MATPLOTLIB_AVAILABLE = True
except ImportError:
    MATPLOTLIB_AVAILABLE = False
    plt = None

# Colors for output
class Colors:
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    BOLD = '\033[1m'
    NC = '\033[0m'

# Benchmark configuration constants
COMPRESSION_TEST_SIZE_MB = 256  # Default compression test size
COMPRESSION_MEMORY_PERCENT = 90  # Percentage of test size to allocate (90%)
COMPRESSION_MEMORY_PASSES = 3  # Number of passes over memory to ensure swapping
COMPRESSION_MIN_SWAP_PERCENT = 50  # Minimum expected swap activity (50% of test size)
COMPRESSION_RATIO_MIN = 1.5  # Minimum expected compression ratio
COMPRESSION_RATIO_MAX = 4.0  # Maximum typical compression ratio
COMPRESSION_RATIO_SUSPICIOUS = 10.0  # Ratio above this is suspicious

# Memory pressure test constants
STRESS_NG_TIMEOUT_SEC = 15  # Timeout for stress-ng memory allocation
STRESS_NG_WAIT_SEC = 20  # Maximum wait time for stress-ng process
MEMORY_ACCESS_STEP_SIZE = 65536  # 64KB steps for memory access patterns

# FIO test configuration constants
FIO_TEST_FILE_SIZE = '1G'  # Test file size for fio benchmarks

def log_info(msg):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")

def log_debug(msg):
    print(f"{Colors.CYAN}[DEBUG]{Colors.NC} {msg}")

def log_warn(msg):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")

def log_error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}", file=sys.stderr)

def log_step(msg):
    print(f"{Colors.BLUE}[STEP]{Colors.NC} {msg}")

def format_timestamp():
    """Return formatted timestamp for logging"""
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def log_info_ts(msg):
    """Log info message with timestamp"""
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {format_timestamp()} {msg}")

def log_warn_ts(msg):
    """Log warning message with timestamp"""
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {format_timestamp()} {msg}")

def log_step_ts(msg):
    """Log step message with timestamp"""
    print(f"{Colors.BLUE}[STEP]{Colors.NC} {format_timestamp()} {msg}")

def log_debug_ts(msg):
    """Log debug message with timestamp"""
    print(f"{Colors.CYAN}[DEBUG]{Colors.NC} {format_timestamp()} {msg}")

def check_root():
    """Check if running as root"""
    if os.geteuid() != 0:
        log_error("This script must be run as root")
        sys.exit(1)

def check_dependencies():
    """Check required dependencies"""
    missing = []
    
    # Check for fio
    try:
        subprocess.run(['fio', '--version'], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        missing.append('fio')
    
    # Check for awk
    try:
        subprocess.run(['awk', '--version'], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        missing.append('gawk')
    
    if missing:
        log_error(f"Missing dependencies: {', '.join(missing)}")
        log_error("Install with: apt install " + " ".join(missing))
        sys.exit(1)

def run_command(cmd, check=True):
    """Run shell command and return output"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            check=check
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        if check:
            log_error(f"Command failed: {cmd}")
            log_error(f"Error: {e.stderr}")
            raise
        return ""

def get_system_info():
    """Get system information"""
    info = {}
    
    # RAM
    with open('/proc/meminfo') as f:
        for line in f:
            if 'MemTotal' in line:
                info['ram_kb'] = int(line.split()[1])
                info['ram_gb'] = info['ram_kb'] // 1024 // 1024
                break
    
    # Available memory
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if 'MemAvailable' in line:
                    info['available_kb'] = int(line.split()[1])
                    info['available_gb'] = round(info['available_kb'] / 1024 / 1024, 1)
                    break
    except:
        info['available_kb'] = info['ram_kb']
        info['available_gb'] = info['ram_gb']
    
    # CPU
    info['cpu_cores'] = os.cpu_count()
    
    # Current page-cluster
    try:
        info['page_cluster'] = int(run_command('sysctl -n vm.page-cluster'))
    except:
        info['page_cluster'] = 3
    
    return info

def calculate_optimal_compression_size(ram_gb, small_tests=False):
    """
    Calculate optimal compression test size based on available RAM
    
    Args:
        ram_gb: Total RAM in GB
        small_tests: If True, use smaller test sizes (64MB max)
    
    Returns:
        Test size in MB
    """
    if small_tests:
        # Small tests mode: 64MB for systems with >=8GB RAM, 32MB otherwise
        return 64 if ram_gb >= 8 else 32
    
    # Scale based on RAM: use 10-20% of total RAM
    # But cap at reasonable values to avoid excessive test times
    if ram_gb <= 4:
        # For 4GB systems: 128MB (12.5% of RAM, manageable)
        return 128
    elif ram_gb <= 8:
        # For 8GB systems: 128MB (10% of RAM)
        return 128
    elif ram_gb <= 16:
        # For 16GB systems: 256MB (10% of RAM)
        return 256
    elif ram_gb <= 32:
        # For 32GB systems: 512MB (10% of RAM)
        return 512
    else:
        # For >32GB systems: 1024MB (cap at 1GB)
        return 1024

def ensure_zram_loaded():
    """Ensure ZRAM kernel module is loaded and device is clean"""
    try:
        # Load zram module
        run_command('modprobe zram', check=False)
        
        # Wait for device to appear
        import time
        for i in range(10):
            if os.path.exists('/dev/zram0'):
                break
            time.sleep(0.1)
        
        if not os.path.exists('/dev/zram0'):
            log_error("ZRAM device /dev/zram0 not found after loading module")
            return False
        
        # Reset any existing zram device completely
        if os.path.exists('/sys/block/zram0/disksize'):
            # First, disable swap if active
            run_command('swapoff /dev/zram0 2>/dev/null || true', check=False)
            
            # Try to read current disksize
            try:
                with open('/sys/block/zram0/disksize', 'r') as f:
                    current_size = f.read().strip()
                    if current_size != '0':
                        # Device is configured, need to reset using direct file I/O
                        with open('/sys/block/zram0/reset', 'w') as reset_f:
                            reset_f.write('1\n')
                        time.sleep(0.5)
            except:
                pass
        
        return True
    except Exception as e:
        log_error(f"Failed to ensure ZRAM loaded: {e}")
        return False

def benchmark_block_size_fio(size_kb, test_file='/tmp/fio_test', runtime_sec=5, pattern='sequential', test_num=None, total_tests=None):
    """
    Benchmark I/O performance with fio (more accurate than dd)
    
    Args:
        size_kb: Block size in KB
        test_file: Path to test file
        runtime_sec: Test runtime in seconds (default: 5)
        pattern: 'sequential' or 'random' I/O pattern
        test_num: Current test number (for progress tracking)
        total_tests: Total number of tests (for progress tracking)
    """
    start_time = time.time()
    
    # Log with progress tracking
    progress_str = f"[{test_num}/{total_tests}] " if test_num and total_tests else ""
    log_step_ts(f"{progress_str}Block size test: {size_kb}KB {pattern} (runtime: {runtime_sec}s)")
    
    results = {
        'block_size_kb': size_kb,
        'runtime_sec': runtime_sec,
        'io_pattern': pattern,
        'concurrency': 1,
        'timestamp': datetime.now().isoformat()
    }
    
    # Determine I/O type based on pattern
    if pattern == 'random':
        write_rw = 'randwrite'
        read_rw = 'randread'
    else:  # sequential
        write_rw = 'write'
        read_rw = 'read'
    
    # Sequential or Random write test
    log_info(f"Running fio {pattern} write test...")
    # Use configured test file size to ensure meaningful results
    fio_write = f"""
[global]
ioengine=libaio
direct=1
runtime={runtime_sec}
time_based
size={FIO_TEST_FILE_SIZE}
filename={test_file}

[seqwrite]
rw={write_rw}
bs={size_kb}k
"""
    
    try:
        with open('/tmp/fio_write.job', 'w') as f:
            f.write(fio_write)
        
        # Log fio command at debug level
        log_debug_ts(f"fio command: fio --output-format=json /tmp/fio_write.job")
        
        result = subprocess.run(
            ['fio', '--output-format=json', '/tmp/fio_write.job'],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode == 0:
            data = json.loads(result.stdout)
            write_bw = data['jobs'][0]['write']['bw'] / 1024  # Convert to MB/s
            write_lat = data['jobs'][0]['write']['lat_ns']['mean'] / 1000000  # Convert to ms
            results['write_mb_per_sec'] = round(write_bw, 2)
            results['write_latency_ms'] = round(write_lat, 2)
            log_info(f"  Write: {write_bw:.2f} MB/s, Latency: {write_lat:.2f} ms")
        else:
            log_error(f"Write test exited with code {result.returncode}")
            log_debug(f"Stderr: {result.stderr}")
            results['write_mb_per_sec'] = 0
            results['write_error'] = f'Exit code {result.returncode}'
    except json.JSONDecodeError as e:
        log_error(f"Failed to parse fio JSON output: {e}")
        log_debug(f"Output: {result.stdout[:200]}")
        results['write_mb_per_sec'] = 0
        results['write_error'] = f'JSON parse error: {e}'
    except Exception as e:
        log_error(f"Write test failed: {e}")
        results['write_mb_per_sec'] = 0
        results['write_error'] = str(e)
    
    # Sequential or Random read test
    log_info(f"Running fio {pattern} read test...")
    fio_read = f"""
[global]
ioengine=libaio
direct=1
runtime={runtime_sec}
time_based
size={FIO_TEST_FILE_SIZE}
filename={test_file}

[seqread]
rw={read_rw}
bs={size_kb}k
"""
    
    try:
        with open('/tmp/fio_read.job', 'w') as f:
            f.write(fio_read)
        
        # Clear cache
        run_command('sync && echo 3 > /proc/sys/vm/drop_caches')
        
        log_debug_ts(f"fio command: fio --output-format=json /tmp/fio_read.job")
        
        result = subprocess.run(
            ['fio', '--output-format=json', '/tmp/fio_read.job'],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode == 0:
            data = json.loads(result.stdout)
            read_bw = data['jobs'][0]['read']['bw'] / 1024  # Convert to MB/s
            read_lat = data['jobs'][0]['read']['lat_ns']['mean'] / 1000000  # Convert to ms
            results['read_mb_per_sec'] = round(read_bw, 2)
            results['read_latency_ms'] = round(read_lat, 2)
            log_info(f"  Read: {read_bw:.2f} MB/s, Latency: {read_lat:.2f} ms")
        else:
            log_error(f"Read test exited with code {result.returncode}")
            log_debug(f"Stderr: {result.stderr}")
            results['read_mb_per_sec'] = 0
            results['read_error'] = f'Exit code {result.returncode}'
    except json.JSONDecodeError as e:
        log_error(f"Failed to parse fio JSON output: {e}")
        log_debug(f"Output: {result.stdout[:200]}")
        results['read_mb_per_sec'] = 0
        results['read_error'] = f'JSON parse error: {e}'
    except Exception as e:
        log_error(f"Read test failed: {e}")
        results['read_mb_per_sec'] = 0
        results['read_error'] = str(e)
    
    # Cleanup
    for f in [test_file, '/tmp/fio_write.job', '/tmp/fio_read.job']:
        if os.path.exists(f):
            try:
                os.remove(f)
            except:
                pass
    
    # Log completion time
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ Test completed in {elapsed:.1f}s")
    
    return results

def benchmark_compression(compressor, allocator='zsmalloc', size_mb=COMPRESSION_TEST_SIZE_MB, test_num=None, total_tests=None):
    """
    Benchmark compression algorithm with specific allocator
    Tests with semi-realistic memory workload
    """
    start_time = time.time()
    
    # Log with progress tracking
    progress_str = f"[{test_num}/{total_tests}] " if test_num and total_tests else ""
    log_step_ts(f"{progress_str}Compression test: {compressor} with {allocator} (test size: {size_mb}MB)")
    
    results = {
        'compressor': compressor,
        'allocator': allocator,
        'test_size_mb': size_mb,
        'timestamp': datetime.now().isoformat()
    }
    
    try:
        # Ensure ZRAM is loaded and clean
        log_info("Ensuring ZRAM device is clean...")
        if not ensure_zram_loaded():
            results['error'] = "Failed to load/reset ZRAM device"
            return results
        
        # Check if we can set allocator (may not be available)
        if os.path.exists('/sys/block/zram0/mem_pool'):
            try:
                log_info(f"Setting allocator to {allocator}...")
                with open('/sys/block/zram0/mem_pool', 'w') as f:
                    f.write(f'{allocator}\n')
            except:
                log_warn(f"Could not set allocator to {allocator}, using default")
        
        # Set compressor
        if os.path.exists('/sys/block/zram0/comp_algorithm'):
            try:
                log_info(f"Setting compressor to {compressor}...")
                with open('/sys/block/zram0/comp_algorithm', 'w') as f:
                    f.write(f'{compressor}\n')
            except:
                log_warn(f"Could not set compressor to {compressor}, using default")
        
        # Set size - use bash redirection instead of echo command to avoid shell issues
        size_bytes = size_mb * 1024 * 1024
        try:
            log_info(f"Setting disk size to {size_bytes} bytes ({size_mb}MB)...")
            with open('/sys/block/zram0/disksize', 'w') as f:
                f.write(str(size_bytes))
        except OSError as e:
            log_error(f"Failed to set ZRAM disk size: {e}")
            results['error'] = f"Failed to set disksize: {e}"
            return results
        
        # Make swap
        log_info("Enabling swap on /dev/zram0...")
        run_command('mkswap /dev/zram0')
        run_command('swapon -p 100 /dev/zram0')
        
        # Create memory pressure to force actual swapping to ZRAM
        # The key is to allocate MORE than available RAM to force the kernel to swap
        
        # Get available memory
        try:
            with open('/proc/meminfo', 'r') as f:
                meminfo = f.read()
            mem_available_kb = 0
            for line in meminfo.split('\n'):
                if line.startswith('MemAvailable:'):
                    mem_available_kb = int(line.split()[1])
                    break
            
            # Allocate significantly more than available memory to force swapping
            # This ensures the kernel MUST use ZRAM swap
            alloc_size_mb = max(size_mb, (mem_available_kb // 1024) + size_mb)
            log_info(f"Creating memory pressure (allocating {alloc_size_mb}MB to force swapping)...")
            log_debug_ts(f"Available memory: {mem_available_kb // 1024}MB, allocating: {alloc_size_mb}MB")
        except:
            # Fallback to original approach if we can't read meminfo
            alloc_size_mb = size_mb * COMPRESSION_MEMORY_PERCENT // 100
            log_info(f"Creating memory pressure (allocating {alloc_size_mb}MB)...")
        
        # Test with different data patterns - use stress-ng if available, otherwise Python allocation
        # stress-ng is more reliable at forcing kernel swapping
        use_stress_ng = False
        try:
            result = subprocess.run(['which', 'stress-ng'], capture_output=True, timeout=2)
            use_stress_ng = (result.returncode == 0)
        except:
            pass
        
        if use_stress_ng:
            log_info(f"Using stress-ng for memory allocation...")
            try:
                # stress-ng with vm-method all creates realistic memory pressure patterns
                subprocess.run(
                    ['stress-ng', '--vm', '1', '--vm-bytes', f'{alloc_size_mb}M', 
                     '--vm-method', 'all', '--timeout', f'{STRESS_NG_TIMEOUT_SEC}s', '--metrics-brief'],
                    timeout=STRESS_NG_WAIT_SEC,
                    check=False  # Don't fail on non-zero exit (stress-ng returns 1 on timeout)
                )
                log_info("Memory allocation completed")
            except subprocess.TimeoutExpired:
                log_warn(f"stress-ng timed out after {STRESS_NG_WAIT_SEC}s (expected behavior)")
            except Exception as e:
                log_warn(f"stress-ng failed: {e}, falling back to Python allocation")
                use_stress_ng = False
        
        if not use_stress_ng:
            # Fallback: Python-based memory allocation with improved patterns
            log_info("Using Python-based memory allocation...")
            test_script = f"""
python3 << 'PYEOF'
import time
import random
import sys
import os

# Allocate MORE than available memory to force swapping
size = {alloc_size_mb * 1024 * 1024}
size_mb_actual = size // 1024 // 1024
print("Allocating " + str(size_mb_actual) + "MB of memory...", file=sys.stderr)

try:
    data = bytearray(size)
    print("Memory allocated successfully", file=sys.stderr)
except MemoryError as e:
    print("Failed to allocate memory: " + str(e), file=sys.stderr)
    # Try with smaller allocation if initial fails
    size = size // 2
    size_mb_actual = size // 1024 // 1024
    print("Retrying with " + str(size_mb_actual) + "MB...", file=sys.stderr)
    try:
        data = bytearray(size)
        print("Memory allocated successfully", file=sys.stderr)
    except MemoryError as e2:
        print("Failed again: " + str(e2), file=sys.stderr)
        sys.exit(1)

# Fill with less compressible patterns (random data compresses poorly)
print("Filling memory with varied patterns (less compressible)...", file=sys.stderr)
random.seed(42)  # Reproducible but varied
for i in range(0, len(data), 4096):
    # Mix of patterns: some compressible, some not
    pattern_type = i % 4
    if pattern_type == 0:
        # Random bytes (low compression)
        chunk = bytes([random.randint(0, 255) for _ in range(min(4096, len(data)-i))])
    elif pattern_type == 1:
        # Repeated pattern (medium compression)
        chunk = bytes([i % 256] * min(4096, len(data)-i))
    elif pattern_type == 2:
        # Zero bytes (high compression)
        chunk = bytes(min(4096, len(data)-i))
    else:
        # Mixed (medium compression)
        chunk = bytes([(i + j) % 256 for j in range(min(4096, len(data)-i))])
    data[i:i+len(chunk)] = chunk

print("Pattern filling complete", file=sys.stderr)

# Touch all memory multiple times to ensure it's swapped
print("Forcing memory to swap...", file=sys.stderr)
for pass_num in range({COMPRESSION_MEMORY_PASSES}):
    print("Forcing memory to swap (pass " + str(pass_num + 1) + " of {COMPRESSION_MEMORY_PASSES})...", file=sys.stderr)
    # Access memory in varied patterns to trigger swapping
    for i in range(0, len(data), {MEMORY_ACCESS_STEP_SIZE}):  # 64KB steps
        data[i] = (data[i] + 1) % 256
    time.sleep(0.3)

print("Memory pressure test complete", file=sys.stderr)
time.sleep(2)
PYEOF
"""
            
            run_command(test_script, check=False)
        
        duration = time.time() - start_time
        
        # Get stats
        log_info("Reading ZRAM statistics...")
        if os.path.exists('/sys/block/zram0/mm_stat'):
            stats = run_command('cat /sys/block/zram0/mm_stat').split()
            
            # Debug: show raw stats
            log_debug_ts(f"Raw mm_stat: {' '.join(stats)}")
            
            if len(stats) >= 3:
                orig_size = int(stats[0])
                compr_size = int(stats[1])
                mem_used = int(stats[2])
                
                # Validation: catch impossible values
                if orig_size == 0:
                    log_warn("No data swapped to ZRAM (orig_size = 0)")
                    results['error'] = 'No swap activity detected'
                    return results
                
                # VALIDATION: Ensure meaningful data was swapped (at least 50% of test size)
                min_expected_bytes = size_mb * 1024 * 1024 * COMPRESSION_MIN_SWAP_PERCENT // 100
                if orig_size < min_expected_bytes:
                    log_warn(f"Insufficient swap activity: only {orig_size/1024/1024:.1f}MB of {size_mb}MB swapped (expected at least {COMPRESSION_MIN_SWAP_PERCENT}%)")
                    log_warn("Consider increasing test size or memory pressure")
                    results['warning'] = f'Low swap activity: {orig_size/1024/1024:.1f}MB < {size_mb*COMPRESSION_MIN_SWAP_PERCENT/100:.1f}MB expected'
                
                if compr_size == 0:
                    log_error("Compressed size is zero - invalid ZRAM state")
                    results['error'] = 'Invalid ZRAM compression state'
                    return results
                
                if mem_used > orig_size * 2:
                    log_warn(f"Memory overhead detected: used {mem_used} > orig {orig_size}")
                
                # Calculate with proper bounds checking
                results['orig_size_mb'] = round(orig_size / 1024 / 1024, 2)
                results['compr_size_mb'] = round(compr_size / 1024 / 1024, 2)
                results['mem_used_mb'] = round(mem_used / 1024 / 1024, 2)
                
                # Compression ratio: should be 1.5 - 4.0 typically
                ratio = orig_size / compr_size
                if ratio < COMPRESSION_RATIO_MIN or ratio > COMPRESSION_RATIO_SUSPICIOUS:
                    log_warn(f"Suspicious compression ratio: {ratio:.2f}x (expected {COMPRESSION_RATIO_MIN}-{COMPRESSION_RATIO_MAX}x for typical data)")
                
                results['compression_ratio'] = round(ratio, 2)
                
                # Efficiency: (orig - mem_used) / orig as percentage
                # Negative values indicate allocator overhead exceeds space savings
                # This can happen with small data sizes or high-overhead allocators
                if orig_size > 0:
                    efficiency = ((orig_size - mem_used) / orig_size) * 100
                    results['efficiency_pct'] = round(efficiency, 2)
                    
                    if efficiency < -50:
                        log_warn(f"High allocator overhead: {abs(efficiency):.1f}% overhead (mem_used > orig_size)")
                        log_warn("This can occur with small test sizes or inefficient allocators")
                else:
                    results['efficiency_pct'] = 0
                    
                log_info(f"  Compression ratio: {ratio:.2f}x")
                log_info(f"  Space efficiency: {results['efficiency_pct']:.1f}%")
                log_info(f"  Memory saved: {results['orig_size_mb'] - results['mem_used_mb']:.2f} MB")
        
        results['duration_sec'] = round(duration, 2)
        
        # Log completion time
        elapsed = time.time() - start_time
        log_info(f"✓ Test completed in {elapsed:.1f}s")
        
    except Exception as e:
        log_error(f"Benchmark failed: {e}")
        results['error'] = str(e)
        elapsed = time.time() - start_time
        log_error(f"Test failed after {elapsed:.1f}s")
    finally:
        # Cleanup
        run_command('swapoff /dev/zram0', check=False)
        if os.path.exists('/sys/block/zram0/reset'):
            try:
                with open('/sys/block/zram0/reset', 'w') as f:
                    f.write('1\n')
            except:
                pass
    
    return results

def test_concurrency(num_files=8, file_size_mb=128, test_dir='/tmp/swap_test', test_num=None, total_tests=None):
    """
    Test concurrency with multiple swap files using fio
    
    Args:
        num_files: Number of concurrent swap files
        file_size_mb: Size of each file in MB
        test_dir: Directory for test files
        test_num: Current test number (for progress tracking)
        total_tests: Total number of tests (for progress tracking)
    """
    start_time = time.time()
    
    # Log with progress tracking
    progress_str = f"[{test_num}/{total_tests}] " if test_num and total_tests else ""
    log_step_ts(f"{progress_str}Concurrency test: {num_files} files")
    
    results = {
        'num_files': num_files,
        'file_size_mb': file_size_mb,
        'timestamp': datetime.now().isoformat()
    }
    
    # Create test directory
    os.makedirs(test_dir, exist_ok=True)
    
    # Create fio job for concurrent I/O
    fio_job = f"""
[global]
ioengine=libaio
direct=1
size={file_size_mb}m
directory={test_dir}
numjobs={num_files}
group_reporting

[concurrent_write]
rw=write
bs=64k

[concurrent_read]
rw=read
bs=64k
stonewall
"""
    
    try:
        with open('/tmp/fio_concurrent.job', 'w') as f:
            f.write(fio_job)
        
        log_info(f"Running concurrent I/O test with {num_files} files...")
        log_debug_ts(f"fio command: fio --output-format=json /tmp/fio_concurrent.job")
        
        result = subprocess.run(
            ['fio', '--output-format=json', '/tmp/fio_concurrent.job'],
            capture_output=True,
            text=True,
            timeout=600  # 10 minute timeout
        )
        
        if result.returncode == 0:
            log_info("Parsing fio results...")
            data = json.loads(result.stdout)
            
            # Validate data structure
            if 'jobs' not in data or len(data['jobs']) < 2:
                raise ValueError("Incomplete fio results")
            
            # Extract write performance
            write_bw = data['jobs'][0]['write']['bw'] / 1024  # MB/s
            results['write_mb_per_sec'] = round(write_bw, 2)
            results['write_iops'] = int(round(data['jobs'][0]['write']['iops'], 0))
            
            # Extract read performance
            read_bw = data['jobs'][1]['read']['bw'] / 1024  # MB/s
            results['read_mb_per_sec'] = round(read_bw, 2)
            results['read_iops'] = int(round(data['jobs'][1]['read']['iops'], 0))
            
            # Calculate scaling efficiency
            # Baseline is single file, so efficiency = actual / (baseline * num_files)
            # We estimate baseline as 1/num_files of concurrent result
            results['write_scaling_efficiency'] = round(100, 2)  # Placeholder, needs baseline
            results['read_scaling_efficiency'] = round(100, 2)  # Placeholder, needs baseline
            
            log_info(f"  Write: {write_bw:.2f} MB/s, {results['write_iops']} IOPS")
            log_info(f"  Read: {read_bw:.2f} MB/s, {results['read_iops']} IOPS")
        else:
            raise subprocess.CalledProcessError(result.returncode, 'fio', result.stderr)
    
    except subprocess.TimeoutExpired as e:
        log_error(f"Concurrency test with {num_files} files timed out after 10 minutes")
        log_error(f"Timeout details: cmd={e.cmd}, timeout={e.timeout}s")
        log_warn("Consider increasing timeout or reducing file count for slower systems")
        results['error'] = 'Timeout after 600s'
        results['write_mb_per_sec'] = 0
        results['read_mb_per_sec'] = 0
    except subprocess.CalledProcessError as e:
        log_error(f"Concurrency test failed with return code {e.returncode}")
        log_debug(f"Command: {e.cmd}")
        log_debug(f"Stderr: {e.stderr}")
        results['error'] = f'Exit code {e.returncode}'
        results['write_mb_per_sec'] = 0
        results['read_mb_per_sec'] = 0
    except Exception as e:
        log_error(f"Concurrency test failed: {e}")
        results['error'] = str(e)
        results['write_mb_per_sec'] = 0
        results['read_mb_per_sec'] = 0
    finally:
        # Cleanup
        import shutil
        if os.path.exists(test_dir):
            shutil.rmtree(test_dir, ignore_errors=True)
        if os.path.exists('/tmp/fio_concurrent.job'):
            os.remove('/tmp/fio_concurrent.job')
    
    # Log completion time
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ Test completed in {elapsed:.1f}s")
    
    return results

def compare_memory_only():
    """
    Compare ZRAM vs ZSWAP in memory-only mode
    Note: ZSWAP requires backing device, so this tests ZRAM with different configurations
    """
    log_step("Comparing memory-only configurations")
    
    results = {
        'timestamp': datetime.now().isoformat(),
        'zram_lz4': {},
        'zram_zstd': {}
    }
    
    # Test ZRAM with lz4
    log_info("Testing ZRAM with lz4...")
    results['zram_lz4'] = benchmark_compression('lz4', 'zsmalloc', 100)
    
    # Test ZRAM with zstd
    log_info("Testing ZRAM with zstd...")
    results['zram_zstd'] = benchmark_compression('zstd', 'zsmalloc', 100)
    
    # Compare
    if 'compression_ratio' in results['zram_lz4'] and 'compression_ratio' in results['zram_zstd']:
        log_info("\nComparison:")
        log_info(f"  lz4:  {results['zram_lz4']['compression_ratio']}x compression")
        log_info(f"  zstd: {results['zram_zstd']['compression_ratio']}x compression")
        log_info(f"  zstd advantage: {results['zram_zstd']['compression_ratio'] / results['zram_lz4']['compression_ratio']:.2f}x")
    
    return results

def export_shell_config(results, output_file):
    """Export optimal configuration as shell script"""
    log_step(f"Exporting configuration to {output_file}")
    
    with open(output_file, 'w') as f:
        f.write("# Swap Configuration from Benchmark\n")
        f.write(f"# Generated: {datetime.now().isoformat()}\n\n")
        
        # Find best block size
        if 'block_sizes' in results and results['block_sizes']:
            best_block = max(results['block_sizes'], 
                           key=lambda x: x.get('read_mb_per_sec', 0) + x.get('write_mb_per_sec', 0))
            # Map block size to page-cluster
            block_to_cluster = {4: 0, 8: 1, 16: 2, 32: 3, 64: 4, 128: 5}
            cluster = block_to_cluster.get(best_block['block_size_kb'], 3)
            f.write(f"# Best block size: {best_block['block_size_kb']}KB\n")
            f.write(f"# (Read: {best_block.get('read_mb_per_sec', 0)} MB/s, ")
            f.write(f"Write: {best_block.get('write_mb_per_sec', 0)} MB/s)\n")
            f.write(f"# Optimal page-cluster value: vm.page-cluster={cluster}\n")
            f.write(f"SWAP_PAGE_CLUSTER={cluster}\n\n")
        
        # Find best compressor
        if 'compressors' in results and results['compressors']:
            best_comp = max(results['compressors'], 
                          key=lambda x: x.get('compression_ratio', 0))
            f.write(f"# Best compressor: {best_comp['compressor']}\n")
            f.write(f"# (Compression ratio: {best_comp.get('compression_ratio', 0)}x)\n")
            f.write(f"ZSWAP_COMPRESSOR={best_comp['compressor']}\n")
            f.write(f"ZRAM_COMPRESSOR={best_comp['compressor']}\n\n")
        
        # Best allocator
        if 'allocators' in results and results['allocators']:
            best_alloc = max(results['allocators'], 
                           key=lambda x: x.get('efficiency_pct', 0))
            f.write(f"# Best allocator: {best_alloc['allocator']}\n")
            f.write(f"# (Efficiency: {best_alloc.get('efficiency_pct', 0)}%)\n")
            f.write(f"ZRAM_ALLOCATOR={best_alloc['allocator']}\n\n")
        
        # Optimal file count
        if 'concurrency' in results and results['concurrency']:
            best_concur = max(results['concurrency'], 
                            key=lambda x: x.get('write_mb_per_sec', 0) + x.get('read_mb_per_sec', 0))
            f.write(f"# Optimal swap file count (stripe width): {best_concur['num_files']}\n")
            f.write(f"# (Write: {best_concur.get('write_mb_per_sec', 0)} MB/s, ")
            f.write(f"Read: {best_concur.get('read_mb_per_sec', 0)} MB/s)\n")
            f.write(f"SWAP_STRIPE_WIDTH={best_concur['num_files']}\n")
    
    log_info(f"Configuration saved to {output_file}")

def generate_charts(results, output_dir='/var/log/debian-install'):
    """
    Generate matplotlib charts for benchmark results
    
    Creates PNG charts for:
    1. Block size vs Throughput (read/write, sequential/random)
    2. Block size vs Latency
    3. Concurrency vs Throughput scaling
    4. Compression ratio comparison
    
    Args:
        results: Benchmark results dictionary
        output_dir: Directory to save PNG files
    
    Returns:
        List of generated chart file paths
    """
    if not MATPLOTLIB_AVAILABLE:
        log_warn("matplotlib not available - skipping chart generation")
        log_info("Install with: apt install python3-matplotlib")
        return []
    
    os.makedirs(output_dir, exist_ok=True)
    chart_files = []
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    
    try:
        # Chart 1: Block Size vs Throughput
        if 'block_sizes' in results and results['block_sizes']:
            fig, ax = plt.subplots(figsize=(10, 6))
            
            block_sizes = [b['block_size_kb'] for b in results['block_sizes']]
            seq_write = [b.get('write_mb_per_sec', 0) for b in results['block_sizes']]
            seq_read = [b.get('read_mb_per_sec', 0) for b in results['block_sizes']]
            
            ax.plot(block_sizes, seq_write, 'o-', label='Sequential Write', linewidth=2, markersize=8)
            ax.plot(block_sizes, seq_read, 's-', label='Sequential Read', linewidth=2, markersize=8)
            
            # Add random I/O if available
            has_random = any(b.get('rand_write_mb_per_sec', 0) > 0 for b in results['block_sizes'])
            if has_random:
                rand_write = [b.get('rand_write_mb_per_sec', 0) for b in results['block_sizes']]
                rand_read = [b.get('rand_read_mb_per_sec', 0) for b in results['block_sizes']]
                ax.plot(block_sizes, rand_write, '^--', label='Random Write', linewidth=2, markersize=8, alpha=0.7)
                ax.plot(block_sizes, rand_read, 'v--', label='Random Read', linewidth=2, markersize=8, alpha=0.7)
            
            ax.set_xlabel('Block Size (KB)', fontsize=12)
            ax.set_ylabel('Throughput (MB/s)', fontsize=12)
            ax.set_title('Block Size vs Throughput', fontsize=14, fontweight='bold')
            ax.legend(fontsize=10)
            ax.grid(True, alpha=0.3)
            ax.set_xscale('log', base=2)
            
            chart_file = f"{output_dir}/benchmark-throughput-{timestamp}.png"
            plt.tight_layout()
            plt.savefig(chart_file, dpi=150)
            plt.close()
            chart_files.append(chart_file)
            log_info(f"Generated throughput chart: {chart_file}")
        
        # Chart 2: Block Size vs Latency
        if 'block_sizes' in results and results['block_sizes']:
            has_latency = any(b.get('write_latency_ms', 0) > 0 or b.get('read_latency_ms', 0) > 0 for b in results['block_sizes'])
            if has_latency:
                fig, ax = plt.subplots(figsize=(10, 6))
                
                block_sizes = [b['block_size_kb'] for b in results['block_sizes']]
                write_lat = [b.get('write_latency_ms', 0) for b in results['block_sizes']]
                read_lat = [b.get('read_latency_ms', 0) for b in results['block_sizes']]
                
                ax.plot(block_sizes, write_lat, 'o-', label='Write Latency', linewidth=2, markersize=8)
                ax.plot(block_sizes, read_lat, 's-', label='Read Latency', linewidth=2, markersize=8)
                
                ax.set_xlabel('Block Size (KB)', fontsize=12)
                ax.set_ylabel('Latency (ms)', fontsize=12)
                ax.set_title('Block Size vs Latency', fontsize=14, fontweight='bold')
                ax.legend(fontsize=10)
                ax.grid(True, alpha=0.3)
                ax.set_xscale('log', base=2)
                
                chart_file = f"{output_dir}/benchmark-latency-{timestamp}.png"
                plt.tight_layout()
                plt.savefig(chart_file, dpi=150)
                plt.close()
                chart_files.append(chart_file)
                log_info(f"Generated latency chart: {chart_file}")
        
        # Chart 3: Concurrency vs Throughput Scaling
        if 'concurrency' in results and results['concurrency']:
            fig, ax = plt.subplots(figsize=(10, 6))
            
            # Filter out error results
            valid_concur = [c for c in results['concurrency'] if 'error' not in c]
            if valid_concur:
                num_files = [c['num_files'] for c in valid_concur]
                write_throughput = [c.get('write_mb_per_sec', 0) for c in valid_concur]
                read_throughput = [c.get('read_mb_per_sec', 0) for c in valid_concur]
                total_throughput = [w + r for w, r in zip(write_throughput, read_throughput)]
                
                ax.plot(num_files, write_throughput, 'o-', label='Write', linewidth=2, markersize=8)
                ax.plot(num_files, read_throughput, 's-', label='Read', linewidth=2, markersize=8)
                ax.plot(num_files, total_throughput, '^-', label='Total', linewidth=2, markersize=8)
                
                # Add ideal linear scaling reference
                if num_files and total_throughput:
                    ideal_scaling = [total_throughput[0] * (n / num_files[0]) for n in num_files]
                    ax.plot(num_files, ideal_scaling, '--', color='gray', label='Ideal Linear', alpha=0.5)
                
                ax.set_xlabel('Number of Concurrent Files', fontsize=12)
                ax.set_ylabel('Throughput (MB/s)', fontsize=12)
                ax.set_title('Concurrency Scaling', fontsize=14, fontweight='bold')
                ax.legend(fontsize=10)
                ax.grid(True, alpha=0.3)
                
                chart_file = f"{output_dir}/benchmark-concurrency-{timestamp}.png"
                plt.tight_layout()
                plt.savefig(chart_file, dpi=150)
                plt.close()
                chart_files.append(chart_file)
                log_info(f"Generated concurrency chart: {chart_file}")
        
        # Chart 4: Compression Ratio Comparison
        if 'compressors' in results and results['compressors']:
            fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
            
            # Filter out error results
            valid_comp = [c for c in results['compressors'] if 'error' not in c and c.get('compression_ratio', 0) > 0]
            if valid_comp:
                compressors = [c['compressor'] for c in valid_comp]
                ratios = [c.get('compression_ratio', 0) for c in valid_comp]
                efficiency = [c.get('efficiency_pct', 0) for c in valid_comp]
                
                # Bar chart for compression ratios
                bars = ax1.bar(compressors, ratios, color=['#3498db', '#e74c3c', '#2ecc71'][:len(compressors)])
                ax1.set_ylabel('Compression Ratio (x)', fontsize=12)
                ax1.set_title('Compression Ratio Comparison', fontsize=12, fontweight='bold')
                ax1.grid(True, alpha=0.3, axis='y')
                
                # Add value labels on bars
                for bar in bars:
                    height = bar.get_height()
                    ax1.text(bar.get_x() + bar.get_width()/2., height,
                            f'{height:.1f}x', ha='center', va='bottom', fontsize=10)
                
                # Bar chart for efficiency
                bars2 = ax2.bar(compressors, efficiency, color=['#3498db', '#e74c3c', '#2ecc71'][:len(compressors)])
                ax2.set_ylabel('Space Efficiency (%)', fontsize=12)
                ax2.set_title('Space Efficiency Comparison', fontsize=12, fontweight='bold')
                ax2.grid(True, alpha=0.3, axis='y')
                ax2.axhline(y=0, color='black', linestyle='-', linewidth=0.5)
                
                # Add value labels on bars
                for bar in bars2:
                    height = bar.get_height()
                    ax2.text(bar.get_x() + bar.get_width()/2., height,
                            f'{height:.0f}%', ha='center', va='bottom' if height > 0 else 'top', fontsize=10)
                
                chart_file = f"{output_dir}/benchmark-compression-{timestamp}.png"
                plt.tight_layout()
                plt.savefig(chart_file, dpi=150)
                plt.close()
                chart_files.append(chart_file)
                log_info(f"Generated compression chart: {chart_file}")
        
    except Exception as e:
        log_error(f"Failed to generate charts: {e}")
        import traceback
        log_debug(traceback.format_exc())
    
    return chart_files

def format_benchmark_html(results):
    """Format benchmark results as HTML for Telegram with visual indicators"""
    html = "<b>📊 Swap Benchmark Results</b>\n\n"
    
    # System info
    if 'system_info' in results:
        sysinfo = results['system_info']
        html += f"<b>💻 System:</b> {sysinfo.get('ram_gb', 'N/A')}GB RAM, {sysinfo.get('cpu_cores', 'N/A')} CPU cores\n\n"
    
    # Block size tests with visual bar chart
    if 'block_sizes' in results and results['block_sizes']:
        html += "<b>📦 Block Size Performance:</b>\n"
        
        # DEBUG: Log what we're working with
        log_debug(f"Block sizes data: {results['block_sizes']}")
        
        # Check if we have random I/O data
        has_random = any(b.get('rand_write_mb_per_sec', 0) > 0 or b.get('rand_read_mb_per_sec', 0) > 0 for b in results['block_sizes'])
        
        if has_random:
            # Show both sequential and random side-by-side
            html += "<i>Sequential I/O:</i>\n"
            max_total = max((b.get('write_mb_per_sec', 0) + b.get('read_mb_per_sec', 0)) for b in results['block_sizes'])
            
            for block in results['block_sizes']:
                size_kb = block.get('block_size_kb', 'N/A')
                write_mb = block.get('write_mb_per_sec', 0)
                read_mb = block.get('read_mb_per_sec', 0)
                total = write_mb + read_mb
                bar_length = int((total / max_total) * 10) if max_total > 0 else 0
                bar = '█' * bar_length + '░' * (10 - bar_length)
                html += f"  {size_kb:3d}KB: {bar} ↑{write_mb:6.1f} ↓{read_mb:6.1f} MB/s\n"
            
            html += "\n<i>Random I/O:</i>\n"
            max_total_rand = max((b.get('rand_write_mb_per_sec', 0) + b.get('rand_read_mb_per_sec', 0)) for b in results['block_sizes'])
            
            for block in results['block_sizes']:
                size_kb = block.get('block_size_kb', 'N/A')
                rand_write_mb = block.get('rand_write_mb_per_sec', 0)
                rand_read_mb = block.get('rand_read_mb_per_sec', 0)
                total_rand = rand_write_mb + rand_read_mb
                bar_length = int((total_rand / max_total_rand) * 10) if max_total_rand > 0 else 0
                bar = '█' * bar_length + '░' * (10 - bar_length)
                html += f"  {size_kb:3d}KB: {bar} ↑{rand_write_mb:6.1f} ↓{rand_read_mb:6.1f} MB/s\n"
        else:
            # Only sequential data available
            html += "<i>(Sequential I/O, single-threaded)</i>\n"
            max_total = max((b.get('write_mb_per_sec', 0) + b.get('read_mb_per_sec', 0)) for b in results['block_sizes'])
            
            # VALIDATION: Check if max_total is actually 0
            if max_total == 0:
                log_warn("All block size results show 0 MB/s - check data structure and test execution")
                log_warn(f"Sample block data: {results['block_sizes'][0] if results['block_sizes'] else 'No data'}")
            
            for block in results['block_sizes']:
                size_kb = block.get('block_size_kb', 'N/A')
                write_mb = block.get('write_mb_per_sec', 0)
                read_mb = block.get('read_mb_per_sec', 0)
                
                # DEBUG: Log individual block results
                if write_mb == 0 and read_mb == 0:
                    log_debug(f"Block {size_kb}KB: No throughput data. Keys present: {list(block.keys())}")
                
                total = write_mb + read_mb
                bar_length = int((total / max_total) * 10) if max_total > 0 else 0
                bar = '█' * bar_length + '░' * (10 - bar_length)
                html += f"  {size_kb:3d}KB: {bar} ↑{write_mb:6.1f} ↓{read_mb:6.1f} MB/s\n"
        html += "\n"
    
    # Compressor comparison with visual indicators
    if 'compressors' in results and results['compressors']:
        html += "<b>🗜️ Compressor Performance:</b>\n"
        
        # DEBUG: Log compressor data
        log_debug(f"Compressor data: {results['compressors']}")
        
        max_ratio = max(c.get('compression_ratio', 0) for c in results['compressors'])
        
        # VALIDATION: Check for unrealistic ratios
        if max_ratio > COMPRESSION_RATIO_SUSPICIOUS:
            log_warn(f"Suspicious max compression ratio: {max_ratio:.1f}x (expected {COMPRESSION_RATIO_MIN}-{COMPRESSION_RATIO_MAX}x for typical data)")
        
        for comp in results['compressors']:
            name = comp.get('compressor', 'N/A')
            ratio = comp.get('compression_ratio', 0)
            eff = comp.get('efficiency_pct', 0)
            
            # VALIDATION: Check for issues
            if 'error' in comp:
                log_warn(f"Compressor {name} had error: {comp['error']}")
            if 'warning' in comp:
                log_warn(f"Compressor {name} warning: {comp['warning']}")
            
            bar_length = int((ratio / max_ratio) * 10) if max_ratio > 0 else 0
            bar = '▓' * bar_length + '░' * (10 - bar_length)
            is_best = ratio == max_ratio
            marker = " ⭐" if is_best else ""
            html += f"  {name:8s}: {bar} {ratio:.1f}x ratio, {eff:+.0f}% eff{marker}\n"
        html += "\n"
    
    # Allocator comparison
    if 'allocators' in results and results['allocators']:
        html += "<b>💾 Allocator Performance:</b>\n"
        max_ratio = max(a.get('compression_ratio', 0) for a in results['allocators'])
        for alloc in results['allocators']:
            name = alloc.get('allocator', 'N/A')
            ratio = alloc.get('compression_ratio', 0)
            eff = alloc.get('efficiency_pct', 0)
            bar_length = int((ratio / max_ratio) * 10) if max_ratio > 0 else 0
            bar = '▓' * bar_length + '░' * (10 - bar_length)
            is_best = ratio == max_ratio
            marker = " ⭐" if is_best else ""
            html += f"  {name:8s}: {bar} {ratio:.1f}x ratio, {eff:+.0f}% eff{marker}\n"
        html += "\n"
    
    # Concurrency tests with scaling chart
    if 'concurrency' in results and results['concurrency']:
        html += "<b>⚡ Concurrency Scaling:</b>\n"
        max_total = max((c.get('write_mb_per_sec', 0) + c.get('read_mb_per_sec', 0)) for c in results['concurrency'])
        for concur in results['concurrency']:
            files = concur.get('num_files', 0)
            if files == 0 or not isinstance(files, int):
                files_str = str(files)
            else:
                files_str = f"{files:2d}"
            write_mb = concur.get('write_mb_per_sec', 0)
            read_mb = concur.get('read_mb_per_sec', 0)
            total = write_mb + read_mb
            bar_length = int((total / max_total) * 10) if max_total > 0 else 0
            bar = '█' * bar_length + '░' * (10 - bar_length)
            is_best = total == max_total
            marker = " ⭐" if is_best else ""
            html += f"  {files_str} files: {bar} ↑{write_mb:.0f} ↓{read_mb:.0f} MB/s{marker}\n"
        html += "\n"
    
    # Memory-only comparison
    if 'memory_only_comparison' in results:
        mem_comp = results['memory_only_comparison']
        html += "<b>🎯 Recommended Config:</b>\n"
        if 'best_overall' in mem_comp:
            best = mem_comp['best_overall']
            html += f"  Compressor: {best.get('compressor', 'N/A')}\n"
            html += f"  Allocator: {best.get('allocator', 'N/A')}\n"
            html += f"  Ratio: {best.get('compression_ratio', 0):.1f}x\n"
    
    return html

def main():
    parser = argparse.ArgumentParser(
        description='Swap Performance Benchmark',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --test-all
  %(prog)s --block-size 64
  %(prog)s --test-compressors
  %(prog)s --test-allocators
  %(prog)s --test-concurrency 8
  %(prog)s --compare-memory-only
  %(prog)s --output results.json --shell-config swap.conf
        """
    )
    
    parser.add_argument('--test-all', action='store_true',
                       help='Run all benchmarks')
    parser.add_argument('--block-size', type=int, metavar='KB',
                       help='Test specific block size in KB')
    parser.add_argument('--test-compressors', action='store_true',
                       help='Test all compression algorithms')
    parser.add_argument('--test-allocators', action='store_true',
                       help='Test all memory allocators')
    parser.add_argument('--compare-memory-only', action='store_true',
                       help='Compare ZRAM configurations')
    parser.add_argument('--test-concurrency', type=int, metavar='N',
                       help='Test concurrency with N swap files')
    parser.add_argument('--duration', type=int, metavar='SEC', default=5,
                       help='Test duration in seconds for each I/O parameter set (default: 5)')
    parser.add_argument('--small-tests', action='store_true',
                       help='Use smaller test sizes for faster benchmarks (64MB compression tests)')
    parser.add_argument('--max-compression-size', type=int, metavar='MB',
                       help='Override maximum compression test size in MB')
    parser.add_argument('--output', '-o', metavar='FILE',
                       help='Output JSON results to file')
    parser.add_argument('--shell-config', metavar='FILE',
                       help='Export shell configuration file')
    parser.add_argument('--telegram', action='store_true',
                       help='Send results to Telegram (requires TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)')
    
    args = parser.parse_args()
    
    # Check root and dependencies
    check_root()
    check_dependencies()
    
    # Record overall start time
    benchmark_start_time = time.time()
    
    # Get system info
    system_info = get_system_info()
    
    # Log startup information with timestamps
    log_info_ts("==> Starting Swap Performance Benchmark")
    log_info_ts(f"System: {system_info['ram_gb']}GB RAM, {system_info['cpu_cores']} CPU cores")
    log_info_ts(f"Available memory: {system_info.get('available_gb', 'N/A')}GB")
    
    # Calculate optimal compression test size based on RAM
    if args.max_compression_size:
        compression_test_size = args.max_compression_size
        log_info_ts(f"Using user-specified compression test size: {compression_test_size}MB")
    else:
        compression_test_size = calculate_optimal_compression_size(
            system_info['ram_gb'], 
            small_tests=args.small_tests
        )
        if args.small_tests:
            log_info_ts(f"Using small test size: {compression_test_size}MB (--small-tests mode)")
        else:
            # Show if we're using a reduced size
            default_size = COMPRESSION_TEST_SIZE_MB
            if compression_test_size < default_size:
                percent_of_ram = (compression_test_size / (system_info['ram_gb'] * 1024)) * 100
                log_warn_ts(f"Using reduced test size: {compression_test_size}MB ({percent_of_ram:.0f}% of RAM) for {system_info['ram_gb']}GB system")
            else:
                log_info_ts(f"Using compression test size: {compression_test_size}MB")
    
    # Warn if test size is large relative to available memory
    if system_info.get('available_gb'):
        available_mb = system_info['available_gb'] * 1024
        if compression_test_size > available_mb * 0.5:
            log_warn_ts(f"Compression test size ({compression_test_size}MB) is >50% of available memory ({available_mb:.0f}MB)")
            log_warn_ts("Tests may take longer due to memory pressure")
    
    # Calculate total number of tests
    total_tests = 0
    if args.test_all or args.block_size:
        block_sizes = [4, 8, 16, 32, 64, 128] if args.test_all else [args.block_size]
        # Each block size has sequential test, and --test-all adds random tests
        total_tests += len(block_sizes) * (2 if args.test_all else 1)
    
    if args.test_all or args.test_compressors:
        compressors = ['lz4', 'zstd', 'lzo-rle']
        total_tests += len(compressors)
    
    if args.test_all or args.test_allocators:
        allocators = ['zsmalloc', 'z3fold', 'zbud']
        total_tests += len(allocators)
    
    if args.test_all or args.test_concurrency:
        file_counts = [1, 2, 4, 8, 16] if args.test_all else [args.test_concurrency]
        total_tests += len(file_counts)
    
    if args.compare_memory_only:
        total_tests += 2  # lz4 and zstd
    
    log_info_ts(f"Total tests to run: {total_tests}")
    
    results = {
        'system_info': system_info,
        'timestamp': datetime.now().isoformat(),
        'compression_test_size_mb': compression_test_size
    }
    
    # Track current test number
    current_test = 0
    
    # Run benchmarks
    if args.test_all or args.block_size:
        block_sizes = [4, 8, 16, 32, 64, 128] if args.test_all else [args.block_size]
        results['block_sizes'] = []
        for size in block_sizes:
            try:
                # Test sequential
                current_test += 1
                seq_result = benchmark_block_size_fio(
                    size, 
                    runtime_sec=args.duration, 
                    pattern='sequential',
                    test_num=current_test,
                    total_tests=total_tests
                )
                
                # Test random (if --test-all)
                if args.test_all:
                    current_test += 1
                    rand_result = benchmark_block_size_fio(
                        size, 
                        runtime_sec=args.duration, 
                        pattern='random',
                        test_num=current_test,
                        total_tests=total_tests
                    )
                    # Merge results
                    seq_result['rand_write_mb_per_sec'] = rand_result.get('write_mb_per_sec', 0)
                    seq_result['rand_read_mb_per_sec'] = rand_result.get('read_mb_per_sec', 0)
                
                results['block_sizes'].append(seq_result)
            except Exception as e:
                log_error(f"Block size {size}KB failed: {e}")
    
    if args.test_all or args.test_compressors:
        compressors = ['lz4', 'zstd', 'lzo-rle']
        results['compressors'] = []
        for comp in compressors:
            try:
                current_test += 1
                result = benchmark_compression(
                    comp, 
                    'zsmalloc', 
                    size_mb=compression_test_size,
                    test_num=current_test,
                    total_tests=total_tests
                )
                results['compressors'].append(result)
            except Exception as e:
                log_error(f"Compressor {comp} failed: {e}")
    
    if args.test_all or args.test_allocators:
        allocators = ['zsmalloc', 'z3fold', 'zbud']
        results['allocators'] = []
        for alloc in allocators:
            try:
                current_test += 1
                result = benchmark_compression(
                    'lz4', 
                    alloc, 
                    size_mb=compression_test_size,
                    test_num=current_test,
                    total_tests=total_tests
                )
                results['allocators'].append(result)
            except Exception as e:
                log_error(f"Allocator {alloc} failed: {e}")
    
    if args.test_all or args.test_concurrency:
        file_counts = [1, 2, 4, 8, 16] if args.test_all else [args.test_concurrency]
        results['concurrency'] = []
        for count in file_counts:
            try:
                current_test += 1
                result = test_concurrency(
                    count,
                    test_num=current_test,
                    total_tests=total_tests
                )
                results['concurrency'].append(result)
            except Exception as e:
                log_error(f"Concurrency test with {count} files failed unexpectedly: {e}")
                # Append error result so it shows in output
                results['concurrency'].append({
                    'num_files': count,
                    'error': str(e),
                    'write_mb_per_sec': 0,
                    'read_mb_per_sec': 0
                })
    
    if args.compare_memory_only:
        results['memory_only_comparison'] = compare_memory_only()
    
    # Calculate and log total elapsed time
    total_elapsed = time.time() - benchmark_start_time
    results['total_elapsed_sec'] = round(total_elapsed, 1)
    
    # Format elapsed time nicely (minutes and seconds)
    elapsed_minutes = int(total_elapsed // 60)
    elapsed_seconds = int(total_elapsed % 60)
    if elapsed_minutes > 0:
        elapsed_str = f"{elapsed_minutes}m {elapsed_seconds}s"
    else:
        elapsed_str = f"{elapsed_seconds}s"
    
    log_info_ts(f"==> Benchmark complete! Total time: {elapsed_str}")
    
    # Always persist results locally for debugging
    local_results_file = f"/var/log/debian-install/benchmark-results-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    try:
        os.makedirs(os.path.dirname(local_results_file), exist_ok=True)
        with open(local_results_file, 'w') as f:
            json.dump(results, f, indent=2)
        log_info_ts(f"Results persisted to {local_results_file}")
        
        # Send results JSON as telegram attachment for debugging
        if args.telegram and TELEGRAM_AVAILABLE:
            try:
                telegram = TelegramClient()
                log_info("Sending benchmark JSON to Telegram...")
                if telegram.send_document(local_results_file, caption="📊 Benchmark Results (JSON)"):
                    log_info("✓ Benchmark JSON sent to Telegram")
                else:
                    log_warn("Failed to send benchmark JSON to Telegram")
            except Exception as e:
                log_warn(f"Failed to send benchmark JSON to Telegram: {e}")
    except Exception as e:
        log_warn(f"Failed to persist results locally: {e}")
    
    # Output results
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(results, f, indent=2)
        log_info(f"Results saved to {args.output}")
    else:
        print(json.dumps(results, indent=2))
    
    # Export shell config
    if args.shell_config:
        export_shell_config(results, args.shell_config)
    
    # Send to Telegram if requested
    if args.telegram:
        if not TELEGRAM_AVAILABLE:
            log_error("Cannot send to Telegram: telegram_client module not available")
            log_error("Ensure telegram_client.py is in the same directory as benchmark.py")
        else:
            try:
                telegram = TelegramClient()
                
                # Generate charts
                log_info("Generating performance charts...")
                chart_files = generate_charts(results)
                
                # Send HTML summary
                html_message = format_benchmark_html(results)
                log_info("Sending benchmark results to Telegram...")
                if telegram.send_message(html_message):
                    log_info("✓ Benchmark results sent to Telegram successfully!")
                else:
                    log_error("✗ Failed to send benchmark results to Telegram")
                    log_error(f"Results are available in {local_results_file}")
                
                # Send charts as attachments
                if chart_files:
                    log_info(f"Sending {len(chart_files)} performance charts to Telegram...")
                    # Extract timestamp once to ensure consistency
                    timestamp_str = datetime.now().strftime('%Y%m%d-%H%M%S')
                    for chart_file in chart_files:
                        chart_name = os.path.basename(chart_file).replace('benchmark-', '').replace('.png', '').replace('-' + timestamp_str, '')
                        caption = f"📊 {chart_name.title()} Chart"
                        if telegram.send_document(chart_file, caption=caption):
                            log_info(f"✓ Sent {chart_name} chart")
                        else:
                            log_warn(f"Failed to send {chart_name} chart")
            except ValueError as e:
                log_error(f"Telegram configuration error: {e}")
            except Exception as e:
                log_error(f"Failed to send to Telegram: {e}")

if __name__ == '__main__':
    main()
