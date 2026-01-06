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
import glob
import json
import os
import shutil
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
COMPRESSION_TEST_TIMEOUT_SEC = 300  # Maximum time per compression test (5 minutes)

# FIO test configuration constants
FIO_TEST_FILE_SIZE = '1G'  # Test file size for fio benchmarks

# System RAM tier thresholds for auto-detection
RAM_TIER_LOW_GB = 4    # Systems below this use ZRAM
RAM_TIER_HIGH_GB = 16  # Systems above this use ZSWAP (but so do medium tier)

def format_timestamp():
    """Return formatted timestamp for logging"""
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')
   
def log_info_ts(msg):
    """Log info message with timestamp"""
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {format_timestamp()} {msg}", flush=True)

def log_warn_ts(msg):
    """Log warning message with timestamp"""
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {format_timestamp()} {msg}", flush=True)

def log_step_ts(msg):
    """Log step message with timestamp"""
    print(f"{Colors.BLUE}[STEP]{Colors.NC} {format_timestamp()} {msg}", flush=True)

def log_debug_ts(msg):
    """Log debug message with timestamp"""
    print(f"{Colors.CYAN}[DEBUG]{Colors.NC} {format_timestamp()} {msg}", flush=True)


def log_info(msg):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}", flush=True)

def log_debug(msg):
    print(f"{Colors.CYAN}[DEBUG]{Colors.NC} {msg}", flush=True)

def log_warn(msg):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}", flush=True)

def log_error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}", file=sys.stderr, flush=True)

def log_step(msg):
    print(f"{Colors.BLUE}[STEP]{Colors.NC} {msg}", flush=True)



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

def compile_c_programs():
    """
    Compile mem_locker, mem_pressure, and latency measurement C programs at runtime.
    Total: 5 programs (mem_locker, mem_pressure, mem_write_bench, mem_read_bench, mem_mixed_bench)
    Returns True if successful, False otherwise.
    """
    script_dir = Path(__file__).parent
    programs = {
        'mem_locker': script_dir / 'mem_locker.c',
        'mem_pressure': script_dir / 'mem_pressure.c',
        'mem_write_bench': script_dir / 'mem_write_bench.c',
        'mem_read_bench': script_dir / 'mem_read_bench.c',
        'mem_mixed_bench': script_dir / 'mem_mixed_bench.c'
    }
    
    log_info_ts("Compiling C memory management and latency measurement programs...")
    
    for prog_name, source_file in programs.items():
        if not source_file.exists():
            log_error(f"Source file not found: {source_file}")
            return False
        
        output_file = script_dir / prog_name
        
        log_info(f"Compiling {prog_name}...")
        try:
            result = subprocess.run(
                ['gcc', '-o', str(output_file), str(source_file), '-Wall', '-O2'],
                capture_output=True,
                text=True,
                check=True,
                timeout=30
            )
            log_info(f"✓ {prog_name} compiled successfully")
        except subprocess.TimeoutExpired:
            log_error(f"Compilation of {prog_name} timed out")
            return False
        except subprocess.CalledProcessError as e:
            log_error(f"Failed to compile {prog_name}")
            log_error(f"Error: {e.stderr}")
            return False
        except FileNotFoundError:
            log_error("gcc not found - install with: apt install gcc")
            return False
    
    log_info_ts("✓ All C programs compiled successfully")
    return True

def get_memory_info():
    """
    Get detailed memory information for test planning.
    Returns dict with total_mb, available_mb, free_mb
    """
    info = {}
    
    with open('/proc/meminfo') as f:
        for line in f:
            if 'MemTotal:' in line:
                info['total_mb'] = int(line.split()[1]) // 1024
            elif 'MemAvailable:' in line:
                info['available_mb'] = int(line.split()[1]) // 1024
            elif 'MemFree:' in line:
                info['free_mb'] = int(line.split()[1]) // 1024
    
    return info

def calculate_memory_distribution(test_size_mb):
    """
    Calculate memory distribution for tests.
    
    Strategy:
    - Reserve test_size_mb for the actual ZRAM/ZSWAP test
    - Reserve 500MB safety buffer for system operations
    - Lock the rest to prevent it from swapping
    
    Returns: (test_size_mb, lock_size_mb, available_mb)
    """
    mem_info = get_memory_info()
    total_mb = mem_info['total_mb']
    available_mb = mem_info['available_mb']
    
    log_debug_ts(f"Memory: Total={total_mb}MB, Available={available_mb}MB")
    
    # Safety buffer for system
    SAFETY_BUFFER_MB = 500
    
    # On high-RAM systems, lock more memory to force swapping
    system_info = get_system_info()
    ram_gb = system_info.get('ram_gb', 8)
    
    if ram_gb >= 8:
        # Lock 85% instead of default to force more swapping
        lock_percent = 0.85
        lock_size_mb = max(0, int(available_mb * lock_percent) - test_size_mb)
    else:
        # Calculate how much we can lock normally
        # We want to lock everything except: test_size + safety_buffer
        lock_size_mb = max(0, available_mb - test_size_mb - SAFETY_BUFFER_MB)
    
    log_info_ts(f"Memory distribution: Test={test_size_mb}MB, Lock={lock_size_mb}MB, Buffer={SAFETY_BUFFER_MB}MB")
    
    return test_size_mb, lock_size_mb, available_mb

def run_with_timeout(cmd, timeout_sec, description="Command"):
    """
    Run a command with timeout.
    Returns (success, output, error_msg)
    """
    log_debug_ts(f"{description}: timeout={timeout_sec}s")
    
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout_sec
        )
        return (result.returncode == 0, result.stdout, result.stderr)
    except subprocess.TimeoutExpired:
        log_warn_ts(f"{description} timed out after {timeout_sec}s")
        return (False, "", f"Timeout after {timeout_sec}s")
    except Exception as e:
        log_error(f"{description} failed: {e}")
        return (False, "", str(e))

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
    Calculate optimal compression test size based on total system RAM
    
    Scales test size to be appropriate for the system's RAM capacity,
    balancing test thoroughness with execution time.
    
    Args:
        ram_gb: Total system RAM in GB (not available RAM)
        small_tests: If True, use smaller test sizes (64MB max) for quick testing
    
    Returns:
        Test size in MB
    """
    if small_tests:
        # Small tests mode: 64MB for systems with >=8GB RAM, 32MB otherwise
        return 64 if ram_gb >= 8 else 32
    
    # Scale based on RAM to keep tests manageable
    # Smaller systems use proportionally smaller tests to avoid excessive swapping
    if ram_gb <= 8:
        # For 4-8GB systems: 128MB (~1.6-3.1% of RAM)
        return 128
    elif ram_gb <= 16:
        # For 16GB systems: 256MB (~1.6% of RAM)
        return 256
    elif ram_gb <= 32:
        # For 32GB systems: 512MB (~1.6% of RAM)
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
            
            # Always reset the device to ensure clean state
            # This is critical - without reset, disksize writes fail with "Device or resource busy"
            try:
                if os.path.exists('/sys/block/zram0/reset'):
                    log_debug("Resetting ZRAM device...")
                    with open('/sys/block/zram0/reset', 'w') as reset_f:
                        reset_f.write('1\n')
                    # Give kernel time to complete reset
                    time.sleep(0.5)
                    log_debug("ZRAM device reset complete")
            except Exception as e:
                log_error(f"Failed to reset ZRAM device: {e}")
                # Don't return False here, try to continue
        
        return True
    except Exception as e:
        log_error(f"Failed to ensure ZRAM loaded: {e}")
        return False

def cleanup_zram_aggressive():
    """
    Aggressively clean up ZRAM device with retries.
    Returns True on success, False on failure.
    """
    max_attempts = 5
    for attempt in range(max_attempts):
        try:
            # Disable swap
            subprocess.run(['swapoff', '/dev/zram0'], 
                         stderr=subprocess.DEVNULL, check=False)
            time.sleep(1)  # Wait for kernel to release device
            
            # Reset device
            if os.path.exists('/sys/block/zram0/reset'):
                with open('/sys/block/zram0/reset', 'w') as f:
                    f.write('1\n')
                
                time.sleep(1)  # Wait for reset to complete
                
                # Verify device is clean
                if os.path.exists('/sys/block/zram0/disksize'):
                    with open('/sys/block/zram0/disksize', 'r') as f:
                        disksize = f.read().strip()
                        if disksize == '0':
                            return True
                else:
                    return True
                        
        except Exception as e:
            if attempt < max_attempts - 1:
                log_debug(f"ZRAM cleanup attempt {attempt + 1} failed: {e}, retrying...")
                time.sleep(2 ** attempt)  # Exponential backoff
                continue
            log_error(f"Failed to cleanup ZRAM after {max_attempts} attempts: {e}")
            return False
    
    return False

def cleanup_test_files():
    """Clean up all temporary test files."""
    patterns = [
        '/tmp/fio_*.job',
        '/tmp/benchmark-*.sh',
        '/tmp/ptable-*.dump',
        '/var/tmp/swapfile*',
        # Compiled C programs
        'mem_locker',
        'mem_pressure', 
        'mem_write_bench',
        'mem_read_bench',
        'mem_mixed_bench'
    ]
    
    for pattern in patterns:
        for file in glob.glob(pattern):
            try:
                if os.path.exists(file):
                    os.remove(file)
                    log_debug(f"Cleaned up: {file}")
            except Exception as e:
                log_debug(f"Failed to remove {file}: {e}")

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
    
    # Initialize mem_locker_proc to None so it's in scope for cleanup
    mem_locker_proc = None
    
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
        
        # Optional: Start mem_locker to lock free RAM (prevents non-test memory from swapping)
        # This is optional but makes tests more reliable and predictable
        script_dir = Path(__file__).parent
        mem_locker_path = script_dir / 'mem_locker'
        
        # Calculate how much memory to lock
        test_alloc_mb, lock_mb, available_mb = calculate_memory_distribution(size_mb)
        
        if lock_mb > 100 and mem_locker_path.exists():
            # Only use mem_locker if we have significant memory to lock (>100MB)
            try:
                log_info_ts(f"Starting mem_locker to reserve {lock_mb}MB of free RAM...")
                mem_locker_proc = subprocess.Popen(
                    [str(mem_locker_path), str(lock_mb)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                # Give it a moment to allocate and lock memory
                time.sleep(2)
                
                # Check if it's still running
                if mem_locker_proc.poll() is not None:
                    log_warn("mem_locker exited prematurely, continuing without it")
                    mem_locker_proc = None
                else:
                    log_info(f"✓ mem_locker running (PID: {mem_locker_proc.pid})")
            except Exception as e:
                log_warn(f"Failed to start mem_locker: {e}")
                mem_locker_proc = None
        elif lock_mb <= 100:
            log_debug_ts(f"Skipping mem_locker (only {lock_mb}MB would be locked)")
        
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
        
        # Use C-based mem_pressure for fast memory allocation
        # This is MUCH faster than Python for large allocations (7+ GB)
        script_dir = Path(__file__).parent
        mem_pressure_path = script_dir / 'mem_pressure'
        
        if not mem_pressure_path.exists():
            log_error(f"mem_pressure program not found at {mem_pressure_path}")
            log_error("Run compile_c_programs() first")
            results['error'] = "mem_pressure program not found"
            return results
        
        # Use mixed pattern (0) for realistic workload
        # Hold time of 15 seconds (default)
        log_info_ts(f"Using C-based mem_pressure for allocation ({alloc_size_mb}MB)...")
        
        # Run with timeout to prevent hanging
        log_info(f"Starting memory pressure test (timeout: {COMPRESSION_TEST_TIMEOUT_SEC}s)...")
        
        try:
            result = subprocess.run(
                [str(mem_pressure_path), str(alloc_size_mb), '0', '15'],
                capture_output=True,
                text=True,
                timeout=COMPRESSION_TEST_TIMEOUT_SEC
            )
            success = (result.returncode == 0)
            stderr = result.stderr if not success else ""
        except subprocess.TimeoutExpired:
            success = False
            stderr = f"Timeout after {COMPRESSION_TEST_TIMEOUT_SEC}s"
            log_warn_ts(f"Memory pressure test timed out after {COMPRESSION_TEST_TIMEOUT_SEC}s")
        except Exception as e:
            success = False
            stderr = str(e)
            log_error(f"Memory pressure test failed: {e}")
        
        if not success:
            log_error(f"Memory pressure test failed or timed out")
            if stderr:
                log_error(f"Error: {stderr}")
            results['error'] = f"mem_pressure failed: {stderr}"
            return results
        
        log_info("Memory pressure test completed successfully")
        
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
                
                # VALIDATION: Ensure meaningful data was swapped
                # Adjust threshold based on RAM size - high RAM systems won't swap as much
                system_info = get_system_info()
                ram_gb = system_info.get('ram_gb', 8)
                
                if ram_gb >= 8:
                    # High RAM systems won't swap much
                    min_swap_percent = 20  # Only expect 20% swapping
                elif ram_gb >= 4:
                    min_swap_percent = 35
                else:
                    min_swap_percent = 50
                
                min_expected_bytes = size_mb * 1024 * 1024 * min_swap_percent // 100
                if orig_size < min_expected_bytes:
                    log_warn(f"Insufficient swap activity: only {orig_size/1024/1024:.1f}MB of {size_mb}MB swapped (expected at least {min_swap_percent}%)")
                    log_warn("Consider increasing test size or memory pressure")
                    results['warning'] = f'Low swap activity: {orig_size/1024/1024:.1f}MB < {size_mb*min_swap_percent/100:.1f}MB expected'
                
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
        # Cleanup mem_locker if it was started
        if mem_locker_proc is not None:
            try:
                log_info("Stopping mem_locker...")
                mem_locker_proc.terminate()
                mem_locker_proc.wait(timeout=5)
                log_info("✓ mem_locker stopped")
            except subprocess.TimeoutExpired:
                log_warn("mem_locker didn't stop gracefully, killing it")
                mem_locker_proc.kill()
                mem_locker_proc.wait()
            except Exception as e:
                log_warn(f"Error stopping mem_locker: {e}")
        
        # Cleanup swap
        cleanup_zram_aggressive()
    
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
        if os.path.exists(test_dir):
            shutil.rmtree(test_dir, ignore_errors=True)
        if os.path.exists('/tmp/fio_concurrent.job'):
            os.remove('/tmp/fio_concurrent.job')
    
    # Log completion time
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ Test completed in {elapsed:.1f}s")
    
    return results

def test_blocksize_concurrency_matrix(block_sizes=None, concurrency_levels=None, file_size_mb=128, test_dir='/tmp/swap_test', runtime_sec=5):
    """
    Test block size × concurrency matrix to find optimal configuration
    
    This tests all combinations of block sizes and concurrency levels to discover
    which configuration provides the best throughput for the specific hardware.
    
    Args:
        block_sizes: List of block sizes in KB (default: [4, 8, 16, 32, 64, 128])
        concurrency_levels: List of concurrency levels (default: [1, 2, 4, 8])
        file_size_mb: Size of each file in MB
        test_dir: Directory for test files
        runtime_sec: Test runtime in seconds
    
    Returns:
        Dictionary with matrix results and optimal configuration
    """
    start_time = time.time()
    
    if block_sizes is None:
        block_sizes = [4, 8, 16, 32, 64, 128]
    if concurrency_levels is None:
        concurrency_levels = [1, 2, 4, 8]
    
    total_combinations = len(block_sizes) * len(concurrency_levels)
    log_step_ts(f"Block Size × Concurrency Matrix Test ({total_combinations} combinations)")
    log_info(f"Block sizes: {block_sizes} KB")
    log_info(f"Concurrency levels: {concurrency_levels}")
    log_info(f"Runtime per test: {runtime_sec}s")
    
    results = {
        'block_sizes': block_sizes,
        'concurrency_levels': concurrency_levels,
        'matrix': [],
        'timestamp': datetime.now().isoformat()
    }
    
    # Create test directory
    os.makedirs(test_dir, exist_ok=True)
    
    # Test each combination
    test_num = 0
    for block_size in block_sizes:
        for concurrency in concurrency_levels:
            test_num += 1
            progress_str = f"[{test_num}/{total_combinations}]"
            log_info_ts(f"{progress_str} Testing {block_size}KB × {concurrency} jobs...")
            
            # Create fio job for this combination
            fio_job = f"""
[global]
ioengine=libaio
direct=1
size={file_size_mb}m
directory={test_dir}
numjobs={concurrency}
group_reporting
runtime={runtime_sec}
time_based

[matrix_write]
rw=write
bs={block_size}k

[matrix_read]
rw=read
bs={block_size}k
stonewall
"""
            
            try:
                with open('/tmp/fio_matrix.job', 'w') as f:
                    f.write(fio_job)
                
                log_debug_ts(f"fio command: fio --output-format=json /tmp/fio_matrix.job")
                
                result = subprocess.run(
                    ['fio', '--output-format=json', '/tmp/fio_matrix.job'],
                    capture_output=True,
                    text=True,
                    timeout=300
                )
                
                if result.returncode == 0:
                    data = json.loads(result.stdout)
                    
                    # Validate data structure
                    if 'jobs' not in data or len(data['jobs']) < 2:
                        raise ValueError("Incomplete fio results")
                    
                    # Extract performance metrics
                    write_bw = data['jobs'][0]['write']['bw'] / 1024  # MB/s
                    read_bw = data['jobs'][1]['read']['bw'] / 1024  # MB/s
                    write_iops = int(round(data['jobs'][0]['write']['iops'], 0))
                    read_iops = int(round(data['jobs'][1]['read']['iops'], 0))
                    
                    matrix_result = {
                        'block_size_kb': block_size,
                        'concurrency': concurrency,
                        'write_mb_per_sec': round(write_bw, 2),
                        'read_mb_per_sec': round(read_bw, 2),
                        'write_iops': write_iops,
                        'read_iops': read_iops
                    }
                    
                    results['matrix'].append(matrix_result)
                    
                    log_info(f"  Write: {write_bw:.2f} MB/s ({write_iops} IOPS)")
                    log_info(f"  Read: {read_bw:.2f} MB/s ({read_iops} IOPS)")
                else:
                    raise subprocess.CalledProcessError(result.returncode, 'fio', result.stderr)
            
            except subprocess.TimeoutExpired as e:
                log_error(f"Matrix test {block_size}KB × {concurrency} timed out")
                results['matrix'].append({
                    'block_size_kb': block_size,
                    'concurrency': concurrency,
                    'error': 'Timeout',
                    'write_mb_per_sec': 0,
                    'read_mb_per_sec': 0
                })
            except Exception as e:
                log_error(f"Matrix test {block_size}KB × {concurrency} failed: {e}")
                results['matrix'].append({
                    'block_size_kb': block_size,
                    'concurrency': concurrency,
                    'error': str(e),
                    'write_mb_per_sec': 0,
                    'read_mb_per_sec': 0
                })
    
    # Find optimal configuration
    if results['matrix']:
        # Find best write throughput
        best_write = max(results['matrix'], key=lambda x: x.get('write_mb_per_sec', 0))
        best_read = max(results['matrix'], key=lambda x: x.get('read_mb_per_sec', 0))
        
        # Calculate combined score (write + read)
        for r in results['matrix']:
            r['combined_mb_per_sec'] = r.get('write_mb_per_sec', 0) + r.get('read_mb_per_sec', 0)
        
        best_combined = max(results['matrix'], key=lambda x: x.get('combined_mb_per_sec', 0))
        
        results['optimal'] = {
            'best_write': {
                'block_size_kb': best_write['block_size_kb'],
                'concurrency': best_write['concurrency'],
                'throughput_mb_per_sec': best_write['write_mb_per_sec']
            },
            'best_read': {
                'block_size_kb': best_read['block_size_kb'],
                'concurrency': best_read['concurrency'],
                'throughput_mb_per_sec': best_read['read_mb_per_sec']
            },
            'best_combined': {
                'block_size_kb': best_combined['block_size_kb'],
                'concurrency': best_combined['concurrency'],
                'throughput_mb_per_sec': best_combined['combined_mb_per_sec']
            }
        }
        
        log_step_ts("Matrix testing complete!")
        log_info(f"Optimal configuration:")
        log_info(f"  Best write: {best_write['block_size_kb']}KB × {best_write['concurrency']} jobs = {best_write['write_mb_per_sec']} MB/s")
        log_info(f"  Best read: {best_read['block_size_kb']}KB × {best_read['concurrency']} jobs = {best_read['read_mb_per_sec']} MB/s")
        log_info(f"  Best combined: {best_combined['block_size_kb']}KB × {best_combined['concurrency']} jobs = {best_combined['combined_mb_per_sec']} MB/s")
        
        # Generate recommendations for vm.page-cluster
        block_to_cluster = {4: 0, 8: 1, 16: 2, 32: 3, 64: 4, 128: 5}
        recommended_cluster = block_to_cluster.get(best_combined['block_size_kb'], 3)
        results['optimal']['recommended_page_cluster'] = recommended_cluster
        
        # Use max successfully tested concurrency (not 16 if it failed)
        max_successful = max([r['concurrency'] for r in valid_results])
        results['optimal']['recommended_swap_stripe_width'] = max_successful
        
        log_info(f"Recommended settings:")
        log_info(f"  SWAP_PAGE_CLUSTER={recommended_cluster} (for {best_combined['block_size_kb']}KB blocks)")
        log_info(f"  SWAP_STRIPE_WIDTH={max_successful} (max tested successfully)")
    
    # Cleanup
    if os.path.exists(test_dir):
        shutil.rmtree(test_dir, ignore_errors=True)
    if os.path.exists('/tmp/fio_matrix.job'):
        os.remove('/tmp/fio_matrix.job')
    
    # Log completion time
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ Matrix test completed in {elapsed:.1f}s")
    
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

def get_device_io_stats(device_path):
    """
    Get I/O statistics for a block device from /sys/block or /proc/diskstats
    
    Returns dict with sectors_read, sectors_written, sector_size, etc.
    """
    stats = {
        'sectors_read': 0,
        'sectors_written': 0,
        'read_ios': 0,
        'write_ios': 0,
        'sector_size': 512  # Default, will try to read actual value
    }
    
    try:
        # Extract device name from path (e.g., /dev/vda3 -> vda)
        import re
        device_match = re.search(r'/dev/([a-z]+)\d*', device_path)
        if not device_match:
            return stats
        
        base_device = device_match.group(1)
        
        # Get actual sector size from sysfs (usually 512, but can be 4096 for advanced format drives)
        sector_size_path = f'/sys/block/{base_device}/queue/hw_sector_size'
        try:
            if os.path.exists(sector_size_path):
                with open(sector_size_path, 'r') as f:
                    stats['sector_size'] = int(f.read().strip())
                    log_debug(f"Device {base_device} sector size: {stats['sector_size']} bytes")
        except Exception as e:
            log_debug(f"Could not read sector size, using default 512: {e}")
        
        # Try reading from /sys/block first
        stat_path = f'/sys/block/{base_device}/stat'
        if os.path.exists(stat_path):
            with open(stat_path, 'r') as f:
                parts = f.read().split()
                if len(parts) >= 10:
                    stats['read_ios'] = int(parts[0])
                    stats['sectors_read'] = int(parts[2])
                    stats['write_ios'] = int(parts[4])
                    stats['sectors_written'] = int(parts[6])
                    return stats
        
        # Fallback to /proc/diskstats
        with open('/proc/diskstats', 'r') as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 14 and parts[2] == base_device:
                    stats['read_ios'] = int(parts[3])
                    stats['sectors_read'] = int(parts[5])
                    stats['write_ios'] = int(parts[7])
                    stats['sectors_written'] = int(parts[9])
                    break
    except Exception as e:
        log_debug(f"Could not read device stats: {e}")
    
    return stats

def benchmark_zswap_comprehensive(swap_device='/dev/vda4', test_size_mb=256, compressor='lz4', zpool='z3fold', max_pool_percent=20):
    """
    Comprehensive ZSWAP benchmarking using same methodology as ZRAM tests:
    - RAM compression performance (using mem_pressure like ZRAM tests)
    - Compression ratio measurement
    - Disk overflow detection via device I/O counters
    - Writeback statistics from ZSWAP debugfs
    
    This ensures fair comparison between ZSWAP and ZRAM.
    
    Args:
        swap_device: Swap partition device (e.g., /dev/vda4)
        test_size_mb: Size of memory to test in MB
        compressor: Compression algorithm (lz4, zstd, lzo-rle)
        zpool: Memory pool (z3fold, zbud, zsmalloc)
        max_pool_percent: Max % of RAM for ZSWAP pool (default 20%)
    
    Returns:
        Dictionary with comprehensive ZSWAP metrics
    """
    start_time = time.time()
    log_step_ts(f"Comprehensive ZSWAP Benchmark: {compressor} + {zpool}")
    log_info(f"Using swap device: {swap_device}")
    log_info(f"Max pool percent: {max_pool_percent}%")
    
    results = {
        'compressor': compressor,
        'zpool': zpool,
        'swap_device': swap_device,
        'test_size_mb': test_size_mb,
        'max_pool_percent': max_pool_percent,
        'timestamp': datetime.now().isoformat()
    }
    
    mem_locker_proc = None
    
    try:
        # Step 1: Check if swap device exists and is a block device
        if not os.path.exists(swap_device):
            log_error(f"Swap device {swap_device} does not exist")
            results['error'] = f'Swap device not found: {swap_device}'
            return results
        
        if not os.path.isfile(swap_device) and not os.path.exists(swap_device):
            log_error(f"{swap_device} is not a valid block device")
            results['error'] = f'Invalid device: {swap_device}'
            return results
        
        # Step 2: Format and enable swap device
        log_info(f"Formatting {swap_device} as swap...")
        try:
            subprocess.run(['mkswap', swap_device], capture_output=True, check=True)
            subprocess.run(['swapon', swap_device], capture_output=True, check=True)
            log_success(f"Swap device {swap_device} enabled")
        except subprocess.CalledProcessError as e:
            log_error(f"Failed to setup swap device: {e}")
            results['error'] = f'Failed to setup swap: {e}'
            return results
        
        # Step 3: Check if ZSWAP is available
        if not os.path.exists('/sys/module/zswap'):
            log_error("ZSWAP not available (module not loaded)")
            results['error'] = 'ZSWAP module not available'
            return results
        
        # Step 4: Configure ZSWAP
        log_info("Configuring ZSWAP...")
        
        # Enable ZSWAP
        with open('/sys/module/zswap/parameters/enabled', 'w') as f:
            f.write('Y')
        
        # Set compressor
        try:
            with open('/sys/module/zswap/parameters/compressor', 'w') as f:
                f.write(compressor)
            log_info(f"Set compressor to {compressor}")
        except Exception as e:
            log_warn(f"Could not set compressor to {compressor}: {e}")
        
        # Set zpool
        try:
            with open('/sys/module/zswap/parameters/zpool', 'w') as f:
                f.write(zpool)
            log_info(f"Set zpool to {zpool}")
        except Exception as e:
            log_warn(f"Could not set zpool to {zpool}: {e}")
        
        # Set max pool percent
        try:
            with open('/sys/module/zswap/parameters/max_pool_percent', 'w') as f:
                f.write(str(max_pool_percent))
            log_info(f"Set max_pool_percent to {max_pool_percent}%")
        except Exception as e:
            log_warn(f"Could not set max_pool_percent: {e}")
        
        log_success(f"ZSWAP enabled: {compressor} + {zpool}")
        
        # Step 5: Get initial device I/O stats
        initial_device_stats = get_device_io_stats(swap_device)
        log_debug(f"Initial device stats: {initial_device_stats}")
        
        # Step 6: Get initial ZSWAP stats
        def get_zswap_stats():
            stats = {}
            debugfs_path = '/sys/kernel/debug/zswap'
            
            if os.path.exists(debugfs_path):
                try:
                    for stat_file in ['pool_total_size', 'stored_pages', 'pool_limit_hit', 'written_back_pages', 'reject_compress_poor', 'reject_alloc_fail']:
                        stat_path = os.path.join(debugfs_path, stat_file)
                        if os.path.exists(stat_path):
                            with open(stat_path, 'r') as f:
                                stats[stat_file] = int(f.read().strip())
                except Exception as e:
                    log_debug(f"Could not read debugfs stats: {e}")
            
            return stats
        
        initial_zswap_stats = get_zswap_stats()
        log_debug(f"Initial ZSWAP stats: {initial_zswap_stats}")
        
        # Step 7: Run memory pressure test (SAME as ZRAM test)
        log_info("Running memory pressure test (same methodology as ZRAM)...")
        
        # Use mem_locker if available
        script_dir = Path(__file__).parent
        mem_locker_path = script_dir / 'mem_locker'
        
        # Calculate memory distribution
        test_alloc_mb, lock_mb, available_mb = calculate_memory_distribution(test_size_mb)
        
        if lock_mb > 100 and mem_locker_path.exists():
            try:
                log_info_ts(f"Starting mem_locker to reserve {lock_mb}MB of free RAM...")
                mem_locker_proc = subprocess.Popen(
                    [str(mem_locker_path), str(lock_mb)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                time.sleep(2)
                
                if mem_locker_proc.poll() is not None:
                    log_warn("mem_locker exited prematurely, continuing without it")
                    mem_locker_proc = None
                else:
                    log_info(f"✓ mem_locker running (PID: {mem_locker_proc.pid})")
            except Exception as e:
                log_warn(f"Failed to start mem_locker: {e}")
                mem_locker_proc = None
        
        # Get available memory and calculate allocation size
        try:
            with open('/proc/meminfo', 'r') as f:
                meminfo = f.read()
            mem_available_kb = 0
            for line in meminfo.split('\n'):
                if line.startswith('MemAvailable:'):
                    mem_available_kb = int(line.split()[1])
                    break
            
            # Allocate more than available to force swapping
            alloc_size_mb = max(test_size_mb, (mem_available_kb // 1024) + test_size_mb)
            log_info(f"Allocating {alloc_size_mb}MB to force swapping...")
        except:
            alloc_size_mb = test_size_mb
        
        # Use mem_pressure (same as ZRAM tests)
        mem_pressure_path = script_dir / 'mem_pressure'
        
        if not mem_pressure_path.exists():
            log_error(f"mem_pressure program not found at {mem_pressure_path}")
            results['error'] = "mem_pressure program not found"
            return results
        
        log_info_ts(f"Running mem_pressure ({alloc_size_mb}MB)...")
        
        try:
            result = subprocess.run(
                [str(mem_pressure_path), str(alloc_size_mb), '0', '15'],
                capture_output=True,
                text=True,
                timeout=COMPRESSION_TEST_TIMEOUT_SEC
            )
            
            if result.returncode != 0:
                log_error(f"mem_pressure failed: {result.stderr}")
                results['error'] = f"mem_pressure failed: {result.stderr}"
                return results
            
            log_info("Memory pressure test completed")
        except subprocess.TimeoutExpired:
            log_error(f"Memory pressure test timed out after {COMPRESSION_TEST_TIMEOUT_SEC}s")
            results['error'] = 'Timeout'
            return results
        
        # Step 8: Get final stats
        final_device_stats = get_device_io_stats(swap_device)
        final_zswap_stats = get_zswap_stats()
        
        log_debug(f"Final device stats: {final_device_stats}")
        log_debug(f"Final ZSWAP stats: {final_zswap_stats}")
        
        # Step 9: Calculate compression metrics (from ZSWAP pool)
        if 'pool_total_size' in final_zswap_stats and 'stored_pages' in final_zswap_stats:
            pool_size_bytes = final_zswap_stats['pool_total_size']
            stored_pages = final_zswap_stats['stored_pages']
            uncompressed_bytes = stored_pages * 4096  # 4KB pages
            
            results['pool_size_mb'] = round(pool_size_bytes / (1024 * 1024), 2)
            results['stored_pages'] = stored_pages
            results['uncompressed_mb'] = round(uncompressed_bytes / (1024 * 1024), 2)
            
            if pool_size_bytes > 0:
                compression_ratio = uncompressed_bytes / pool_size_bytes
                results['compression_ratio'] = round(compression_ratio, 2)
                log_info(f"  Compression ratio: {compression_ratio:.2f}x")
                log_info(f"  Pool size: {results['pool_size_mb']:.2f}MB (compressed)")
                log_info(f"  Original size: {results['uncompressed_mb']:.2f}MB (uncompressed)")
            else:
                log_warn("No data in ZSWAP pool")
        
        # Step 10: Calculate disk overflow metrics
        sectors_written_delta = final_device_stats['sectors_written'] - initial_device_stats['sectors_written']
        sectors_read_delta = final_device_stats['sectors_read'] - initial_device_stats['sectors_read']
        write_ios_delta = final_device_stats['write_ios'] - initial_device_stats['write_ios']
        read_ios_delta = final_device_stats['read_ios'] - initial_device_stats['read_ios']
        
        # Get sector size (typically 512, but can be 4096 for advanced format drives)
        sector_size = final_device_stats.get('sector_size', 512)
        
        # Convert sectors to MB using actual sector size
        mb_written = (sectors_written_delta * sector_size) / (1024 * 1024)
        mb_read = (sectors_read_delta * sector_size) / (1024 * 1024)
        
        results['disk_mb_written'] = round(mb_written, 2)
        results['disk_mb_read'] = round(mb_read, 2)
        results['disk_write_ios'] = write_ios_delta
        results['disk_read_ios'] = read_ios_delta
        
        log_info(f"  Disk overflow: {mb_written:.2f}MB written, {mb_read:.2f}MB read")
        log_info(f"  Disk I/Os: {write_ios_delta} writes, {read_ios_delta} reads")
        
        # Step 11: ZSWAP writeback stats
        if 'written_back_pages' in final_zswap_stats and 'written_back_pages' in initial_zswap_stats:
            pages_written_back = final_zswap_stats['written_back_pages'] - initial_zswap_stats.get('written_back_pages', 0)
            mb_written_back = (pages_written_back * 4096) / (1024 * 1024)
            results['zswap_writeback_pages'] = pages_written_back
            results['zswap_writeback_mb'] = round(mb_written_back, 2)
            log_info(f"  ZSWAP writeback: {pages_written_back} pages ({mb_written_back:.2f}MB)")
        
        if 'pool_limit_hit' in final_zswap_stats:
            pool_limit_hits = final_zswap_stats['pool_limit_hit'] - initial_zswap_stats.get('pool_limit_hit', 0)
            results['pool_limit_hits'] = pool_limit_hits
            if pool_limit_hits > 0:
                log_info(f"  Pool limit hit {pool_limit_hits} times (triggered writeback)")
        
        if 'reject_compress_poor' in final_zswap_stats:
            rejects = final_zswap_stats['reject_compress_poor'] - initial_zswap_stats.get('reject_compress_poor', 0)
            if rejects > 0:
                results['reject_compress_poor'] = rejects
                log_info(f"  Rejected {rejects} pages (poor compression)")
        
        log_success("ZSWAP benchmark complete")
        
    except Exception as e:
        log_error(f"ZSWAP benchmark failed: {e}")
        import traceback
        log_debug(f"Traceback: {traceback.format_exc()}")
        results['error'] = str(e)
    
    finally:
        # Cleanup mem_locker if it was started
        if mem_locker_proc is not None:
            try:
                log_info("Stopping mem_locker...")
                mem_locker_proc.terminate()
                mem_locker_proc.wait(timeout=5)
                log_info("✓ mem_locker stopped")
            except subprocess.TimeoutExpired:
                log_warn("mem_locker didn't stop gracefully, killing it")
                mem_locker_proc.kill()
                mem_locker_proc.wait()
            except Exception as e:
                log_warn(f"Error stopping mem_locker: {e}")
        
        # Cleanup swap
        try:
            subprocess.run(['swapoff', swap_device], capture_output=True)
        except Exception as e:
            log_debug(f"Swapoff warning: {e}")
        
        # Disable ZSWAP
        try:
            if os.path.exists('/sys/module/zswap/parameters/enabled'):
                with open('/sys/module/zswap/parameters/enabled', 'w') as f:
                    f.write('N')
        except Exception as e:
            log_debug(f"ZSWAP disable warning: {e}")
    
    # Log completion time
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ ZSWAP benchmark completed in {elapsed:.1f}s")
    
    return results

def create_temp_swap_files(total_size_mb=2048, num_files=4):
    """Create temporary swap files for ZSWAP testing before partitions exist"""
    swap_files = []
    file_size_mb = total_size_mb // num_files
    
    # Check available space in /tmp or /root
    import shutil
    stat = shutil.disk_usage('/tmp')
    available_gb = stat.free / (1024**3)
    
    if available_gb < (total_size_mb / 1024) + 1:
        log_warn(f"Insufficient space in /tmp ({available_gb:.1f}GB), trying /root")
        base_dir = '/root'
    else:
        base_dir = '/tmp'
    
    try:
        for i in range(num_files):
            swap_file = f"{base_dir}/swap_test_{i}"
            log_info(f"Creating {file_size_mb}MB swap file: {swap_file}")
            subprocess.run(['dd', 'if=/dev/zero', f'of={swap_file}', 
                          'bs=1M', f'count={file_size_mb}'], 
                          capture_output=True, check=True)
            subprocess.run(['chmod', '600', swap_file], check=True)
            subprocess.run(['mkswap', swap_file], capture_output=True, check=True)
            subprocess.run(['swapon', swap_file], check=True)
            swap_files.append(swap_file)
            
        return swap_files
    except Exception as e:
        log_error(f"Failed to create temp swap: {e}")
        # Cleanup any created files
        for f in swap_files:
            try:
                subprocess.run(['swapoff', f], capture_output=True)
                os.unlink(f)
            except:
                pass
        return []

def cleanup_temp_swap_files(swap_files):
    """Remove temporary swap files"""
    for swap_file in swap_files:
        try:
            subprocess.run(['swapoff', swap_file], capture_output=True)
            os.unlink(swap_file)
            log_info(f"Cleaned up {swap_file}")
        except Exception as e:
            log_warn(f"Error cleaning up {swap_file}: {e}")

def compare_zswap_vs_zram(swap_device='/dev/vda4', test_size_mb=256):
    """
    Compare ZSWAP vs ZRAM performance using identical testing methodology
    
    Tests both systems with lz4 and zstd compressors using the same
    mem_pressure tool for fair comparison. Provides comprehensive metrics:
    - Compression ratio (RAM efficiency)
    - Memory pressure handling
    - For ZSWAP: disk overflow behavior via device counters
    
    Args:
        swap_device: Swap partition for ZSWAP backing (e.g., /dev/vda4)
        test_size_mb: Size of memory to test in MB
    
    Returns:
        Dictionary with comparison results
    """
    log_step_ts("Comparing ZSWAP vs ZRAM (identical methodology)")
    
    # Create temp swap if no device provided
    temp_swap_files = []
    if not swap_device or not os.path.exists(swap_device):
        log_info("No swap device available - creating temporary swap files")
        temp_swap_files = create_temp_swap_files(total_size_mb=2048, num_files=4)
        if temp_swap_files:
            swap_device = temp_swap_files[0]  # Use first file for testing
        else:
            log_warn("Could not create temp swap - skipping ZSWAP comparison")
            return {'skipped': True, 'reason': 'No swap device available'}
    
    results = {
        'test_size_mb': test_size_mb,
        'swap_device': swap_device,
        'timestamp': datetime.now().isoformat(),
        'zram': {},
        'zswap': {}
    }
    
    # Test ZRAM with lz4
    log_info("\n=== Testing ZRAM with lz4 ===")
    try:
        results['zram']['lz4'] = benchmark_compression('lz4', 'zsmalloc', test_size_mb)
    except Exception as e:
        log_error(f"ZRAM lz4 test failed: {e}")
        results['zram']['lz4'] = {'error': str(e)}
    
    # Test ZRAM with zstd
    log_info("\n=== Testing ZRAM with zstd ===")
    try:
        results['zram']['zstd'] = benchmark_compression('zstd', 'zsmalloc', test_size_mb)
    except Exception as e:
        log_error(f"ZRAM zstd test failed: {e}")
        results['zram']['zstd'] = {'error': str(e)}
    
    # Test ZSWAP with lz4
    log_info("\n=== Testing ZSWAP with lz4 ===")
    try:
        results['zswap']['lz4'] = benchmark_zswap_comprehensive(
            swap_device=swap_device,
            test_size_mb=test_size_mb,
            compressor='lz4',
            zpool='z3fold',
            max_pool_percent=20
        )
    except Exception as e:
        log_error(f"ZSWAP lz4 test failed: {e}")
        results['zswap']['lz4'] = {'error': str(e)}
    
    # Test ZSWAP with zstd
    log_info("\n=== Testing ZSWAP with zstd ===")
    try:
        results['zswap']['zstd'] = benchmark_zswap_comprehensive(
            swap_device=swap_device,
            test_size_mb=test_size_mb,
            compressor='zstd',
            zpool='z3fold',
            max_pool_percent=20
        )
    except Exception as e:
        log_error(f"ZSWAP zstd test failed: {e}")
        results['zswap']['zstd'] = {'error': str(e)}
    
    # Generate comparison summary
    log_info("\n=== Comparison Summary ===")
    
    for comp in ['lz4', 'zstd']:
        log_info(f"\n{comp.upper()} Compressor:")
        
        # ZRAM metrics
        if 'compression_ratio' in results['zram'].get(comp, {}):
            zram_ratio = results['zram'][comp]['compression_ratio']
            log_info(f"  ZRAM compression: {zram_ratio:.2f}x")
            
            if 'orig_size_mb' in results['zram'][comp]:
                log_info(f"    Original: {results['zram'][comp]['orig_size_mb']:.2f}MB")
                log_info(f"    Compressed: {results['zram'][comp]['compr_size_mb']:.2f}MB")
        
        # ZSWAP metrics
        if 'compression_ratio' in results['zswap'].get(comp, {}):
            zswap_ratio = results['zswap'][comp]['compression_ratio']
            log_info(f"  ZSWAP compression: {zswap_ratio:.2f}x")
            
            if 'uncompressed_mb' in results['zswap'][comp]:
                log_info(f"    Original: {results['zswap'][comp]['uncompressed_mb']:.2f}MB")
                log_info(f"    Compressed: {results['zswap'][comp]['pool_size_mb']:.2f}MB")
        
        # ZSWAP disk overflow
        if 'disk_mb_written' in results['zswap'].get(comp, {}):
            disk_written = results['zswap'][comp]['disk_mb_written']
            if disk_written > 0:
                log_info(f"  ZSWAP disk overflow: {disk_written:.2f}MB written to disk")
                
                if 'zswap_writeback_mb' in results['zswap'][comp]:
                    log_info(f"    Via ZSWAP writeback: {results['zswap'][comp]['zswap_writeback_mb']:.2f}MB")
                
                if 'pool_limit_hits' in results['zswap'][comp]:
                    log_info(f"    Pool limit hits: {results['zswap'][comp]['pool_limit_hits']}")
            else:
                log_info(f"  ZSWAP: All data stayed in RAM (no disk overflow)")
    
    # Cleanup
    if temp_swap_files:
        cleanup_temp_swap_files(temp_swap_files)
    
    return results

def benchmark_write_latency(compressor, allocator, test_size_mb=100, pattern=0, test_num=None, total_tests=None):
    """
    Measure page write (swap-out) latency.
    
    Process:
    1. Setup ZRAM/ZSWAP with specified compressor/allocator
    2. Run mem_write_bench with specified data pattern
    3. Collect latency statistics
    
    Args:
        compressor: Compression algorithm (lz4, zstd, lzo-rle)
        allocator: Memory allocator (zsmalloc, z3fold, zbud)
        test_size_mb: Size of memory to test in MB
        pattern: Data pattern (0=mixed, 1=random, 2=zeros, 3=sequential)
        test_num: Current test number (for progress tracking)
        total_tests: Total number of tests (for progress tracking)
    
    Returns:
        Dictionary with latency statistics
    """
    start_time = time.time()
    
    progress_str = f"[{test_num}/{total_tests}] " if test_num and total_tests else ""
    log_step_ts(f"{progress_str}Write latency test: {compressor} + {allocator} (pattern={pattern})")
    
    results = {
        'compressor': compressor,
        'allocator': allocator,
        'test_size_mb': test_size_mb,
        'pattern': pattern,
        'timestamp': datetime.now().isoformat()
    }
    
    try:
        # Ensure ZRAM is loaded and clean
        if not ensure_zram_loaded():
            results['error'] = "Failed to load/reset ZRAM device"
            return results
        
        # Set allocator
        if os.path.exists('/sys/block/zram0/mem_pool'):
            try:
                with open('/sys/block/zram0/mem_pool', 'w') as f:
                    f.write(f'{allocator}\n')
            except:
                log_warn(f"Could not set allocator to {allocator}")
        
        # Set compressor
        if os.path.exists('/sys/block/zram0/comp_algorithm'):
            try:
                with open('/sys/block/zram0/comp_algorithm', 'w') as f:
                    f.write(f'{compressor}\n')
            except:
                log_warn(f"Could not set compressor to {compressor}")
        
        # Set ZRAM size
        size_bytes = test_size_mb * 1024 * 1024
        try:
            with open('/sys/block/zram0/disksize', 'w') as f:
                f.write(str(size_bytes))
        except OSError as e:
            log_error(f"Failed to set ZRAM disk size: {e}")
            results['error'] = f"Failed to set disksize: {e}"
            return results
        
        # Enable swap
        run_command('mkswap /dev/zram0')
        run_command('swapon -p 100 /dev/zram0')
        
        # Run mem_write_bench
        script_dir = Path(__file__).parent
        mem_write_bench_path = script_dir / 'mem_write_bench'
        
        if not mem_write_bench_path.exists():
            results['error'] = "mem_write_bench executable not found. Run compilation first or check if the C program built successfully."
            return results
        
        log_info(f"Running mem_write_bench ({test_size_mb}MB, pattern={pattern})...")
        result = subprocess.run(
            [str(mem_write_bench_path), str(test_size_mb), str(pattern)],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode == 0:
            # Parse JSON output
            try:
                bench_results = json.loads(result.stdout)
                results.update(bench_results)
                log_info(f"  Write latency: avg={bench_results.get('avg_write_us', 0):.2f}µs, "
                        f"p95={bench_results.get('p95_write_us', 0):.2f}µs, "
                        f"p99={bench_results.get('p99_write_us', 0):.2f}µs")
            except json.JSONDecodeError as e:
                log_error(f"Failed to parse mem_write_bench output: {e}")
                results['error'] = f"JSON parse error: {e}"
        else:
            log_error(f"mem_write_bench failed with code {result.returncode}")
            log_debug(f"Stderr: {result.stderr}")
            results['error'] = f"Exit code {result.returncode}"
    
    except subprocess.TimeoutExpired:
        log_error("Write latency test timed out")
        results['error'] = "Timeout"
    except Exception as e:
        log_error(f"Write latency test failed: {e}")
        results['error'] = str(e)
    finally:
        # Cleanup
        cleanup_zram_aggressive()
    
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ Test completed in {elapsed:.1f}s")
    
    return results

def benchmark_read_latency(compressor, allocator, test_size_mb=100, access_pattern=0, test_num=None, total_tests=None):
    """
    Measure page read (page fault + decompress) latency.
    
    Process:
    1. Setup ZRAM/ZSWAP
    2. Run mem_read_bench with specified access pattern
    3. Measure page fault latency
    
    Args:
        compressor: Compression algorithm
        allocator: Memory allocator
        test_size_mb: Size of memory to test in MB
        access_pattern: Access pattern (0=sequential, 1=random, 2=stride)
        test_num: Current test number (for progress tracking)
        total_tests: Total number of tests (for progress tracking)
    
    Returns:
        Dictionary with latency statistics
    """
    start_time = time.time()
    
    pattern_names = ["sequential", "random", "stride"]
    pattern_name = pattern_names[access_pattern] if 0 <= access_pattern <= 2 else "unknown"
    
    progress_str = f"[{test_num}/{total_tests}] " if test_num and total_tests else ""
    log_step_ts(f"{progress_str}Read latency test: {compressor} + {allocator} ({pattern_name})")
    
    results = {
        'compressor': compressor,
        'allocator': allocator,
        'test_size_mb': test_size_mb,
        'access_pattern': pattern_name,
        'timestamp': datetime.now().isoformat()
    }
    
    try:
        # Ensure ZRAM is loaded and clean
        if not ensure_zram_loaded():
            results['error'] = "Failed to load/reset ZRAM device"
            return results
        
        # Set allocator
        if os.path.exists('/sys/block/zram0/mem_pool'):
            try:
                with open('/sys/block/zram0/mem_pool', 'w') as f:
                    f.write(f'{allocator}\n')
            except:
                log_warn(f"Could not set allocator to {allocator}")
        
        # Set compressor
        if os.path.exists('/sys/block/zram0/comp_algorithm'):
            try:
                with open('/sys/block/zram0/comp_algorithm', 'w') as f:
                    f.write(f'{compressor}\n')
            except:
                log_warn(f"Could not set compressor to {compressor}")
        
        # Set ZRAM size
        size_bytes = test_size_mb * 1024 * 1024
        try:
            with open('/sys/block/zram0/disksize', 'w') as f:
                f.write(str(size_bytes))
        except OSError as e:
            log_error(f"Failed to set ZRAM disk size: {e}")
            results['error'] = f"Failed to set disksize: {e}"
            return results
        
        # Enable swap
        run_command('mkswap /dev/zram0')
        run_command('swapon -p 100 /dev/zram0')
        
        # Run mem_read_bench
        script_dir = Path(__file__).parent
        mem_read_bench_path = script_dir / 'mem_read_bench'
        
        if not mem_read_bench_path.exists():
            results['error'] = "mem_read_bench executable not found. Run compilation first or check if the C program built successfully."
            return results
        
        log_info(f"Running mem_read_bench ({test_size_mb}MB, {pattern_name})...")
        result = subprocess.run(
            [str(mem_read_bench_path), str(test_size_mb), str(access_pattern)],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode == 0:
            # Parse JSON output
            try:
                bench_results = json.loads(result.stdout)
                results.update(bench_results)
                log_info(f"  Read latency: avg={bench_results.get('avg_read_us', 0):.2f}µs, "
                        f"p95={bench_results.get('p95_read_us', 0):.2f}µs, "
                        f"p99={bench_results.get('p99_read_us', 0):.2f}µs")
            except json.JSONDecodeError as e:
                log_error(f"Failed to parse mem_read_bench output: {e}")
                results['error'] = f"JSON parse error: {e}"
        else:
            log_error(f"mem_read_bench failed with code {result.returncode}")
            log_debug(f"Stderr: {result.stderr}")
            results['error'] = f"Exit code {result.returncode}"
    
    except subprocess.TimeoutExpired:
        log_error("Read latency test timed out")
        results['error'] = "Timeout"
    except Exception as e:
        log_error(f"Read latency test failed: {e}")
        results['error'] = str(e)
    finally:
        # Cleanup
        cleanup_zram_aggressive()
    
    elapsed = time.time() - start_time
    results['elapsed_sec'] = round(elapsed, 1)
    log_info(f"✓ Test completed in {elapsed:.1f}s")
    
    return results

def benchmark_native_ram_baseline(test_size_mb=100):
    """
    Measure native RAM access latency (no swap).
    
    Provides baseline for comparison - this is the "ideal" performance target.
    Measures pure RAM read/write speed without any swap or compression overhead.
    
    Args:
        test_size_mb: Size of memory to test in MB
    
    Returns:
        Dictionary with baseline read/write latency in nanoseconds
    """
    log_step_ts("Native RAM baseline test (no swap)")
    
    results = {
        'type': 'native_ram',
        'test_size_mb': test_size_mb,
        'timestamp': datetime.now().isoformat()
    }
    
    try:
        # Run a simple memory access benchmark without any swap
        # We'll use a minimal C-like approach via Python for simplicity
        import array
        import time
        
        size_bytes = test_size_mb * 1024 * 1024
        
        log_info(f"Testing native RAM access ({test_size_mb}MB)...")
        
        # Write test
        log_info("Measuring write speed...")
        data = bytearray(size_bytes)
        
        write_start = time.time()
        for i in range(0, size_bytes, 4096):
            data[i] = (i % 256)
        write_end = time.time()
        
        write_ns_per_page = ((write_end - write_start) * 1e9) / (size_bytes / 4096)
        
        # Read test
        log_info("Measuring read speed...")
        dummy = 0
        read_start = time.time()
        for i in range(0, size_bytes, 4096):
            dummy += data[i]
        read_end = time.time()
        
        read_ns_per_page = ((read_end - read_start) * 1e9) / (size_bytes / 4096)
        
        # Calculate bandwidth
        write_time = write_end - write_start
        read_time = read_end - read_start
        write_gb_per_sec = (size_bytes / (1024**3)) / write_time if write_time > 0 else 0
        read_gb_per_sec = (size_bytes / (1024**3)) / read_time if read_time > 0 else 0
        
        results['read_ns'] = round(read_ns_per_page, 2)
        results['write_ns'] = round(write_ns_per_page, 2)
        results['read_gb_per_sec'] = round(read_gb_per_sec, 2)
        results['write_gb_per_sec'] = round(write_gb_per_sec, 2)
        
        log_info(f"  Native RAM read: {read_ns_per_page:.0f} ns/page ({read_gb_per_sec:.2f} GB/s)")
        log_info(f"  Native RAM write: {write_ns_per_page:.0f} ns/page ({write_gb_per_sec:.2f} GB/s)")
        log_info(f"✓ Baseline established")
        
    except Exception as e:
        log_error(f"Baseline test failed: {e}")
        results['error'] = str(e)
    
    return results

def benchmark_latency_comparison(test_size_mb=100):
    """
    Comprehensive comparison of latency across all configurations.
    
    Tests matrix:
    - Baseline: Native RAM (no swap)
    - ZRAM: lz4/zstd × zsmalloc/zbud (4 combinations for efficiency)
    - Access patterns: sequential/random for reads
    - Operations: read/write
    
    Args:
        test_size_mb: Size of memory to test in MB
    
    Returns:
        Dictionary with comprehensive latency comparison
    """
    log_step_ts("Comprehensive latency comparison")
    
    results = {
        'timestamp': datetime.now().isoformat(),
        'test_size_mb': test_size_mb,
        'baseline': {},
        'write_latency': [],
        'read_latency': []
    }
    
    # 1. Baseline: Native RAM
    log_info("\n=== Phase 1: Native RAM Baseline ===")
    results['baseline'] = benchmark_native_ram_baseline(test_size_mb)
    
    # 2. Write latency tests
    log_info("\n=== Phase 2: Write Latency Tests ===")
    write_configs = [
        ('lz4', 'zsmalloc'),
        ('lz4', 'z3fold'),
        ('lz4', 'zbud'),
        ('zstd', 'zsmalloc'),
        ('zstd', 'z3fold'),
        ('zstd', 'zbud')
    ]
    
    for i, (comp, alloc) in enumerate(write_configs, 1):
        result = benchmark_write_latency(comp, alloc, test_size_mb, pattern=0,
                                        test_num=i, total_tests=len(write_configs))
        results['write_latency'].append(result)
    
    # 3. Read latency tests (sequential and random)
    log_info("\n=== Phase 3: Read Latency Tests ===")
    read_configs = [
        ('lz4', 'zsmalloc', 0),   # sequential
        ('lz4', 'z3fold', 0),     # sequential
        ('lz4', 'zbud', 0),       # sequential
        ('lz4', 'zsmalloc', 1),   # random
        ('zstd', 'zsmalloc', 0),  # sequential
        ('zstd', 'z3fold', 0),    # sequential
        ('zstd', 'zbud', 0),      # sequential
        ('zstd', 'zsmalloc', 1),  # random
    ]
    
    for i, (comp, alloc, pattern) in enumerate(read_configs, 1):
        result = benchmark_read_latency(comp, alloc, test_size_mb, pattern,
                                       test_num=i, total_tests=len(read_configs))
        results['read_latency'].append(result)
    
    # 4. Generate comparison summary
    log_info("\n=== Latency Comparison Summary ===")
    
    if 'read_ns' in results['baseline']:
        baseline_read_ns = results['baseline']['read_ns']
        baseline_write_ns = results['baseline']['write_ns']
        
        log_info(f"Baseline (Native RAM):")
        log_info(f"  Read:  {baseline_read_ns:.0f} ns/page")
        log_info(f"  Write: {baseline_write_ns:.0f} ns/page")
        log_info("")
        
        # Compare write latencies
        for result in results['write_latency']:
            if 'avg_write_us' in result and 'error' not in result:
                avg_us = result['avg_write_us']
                avg_ns = avg_us * 1000
                slowdown = avg_ns / baseline_write_ns if baseline_write_ns > 0 else 0
                log_info(f"{result['compressor']:8s} + {result['allocator']:8s} write: "
                        f"{avg_us:7.2f}µs ({slowdown:.0f}x slower than RAM)")
        
        log_info("")
        
        # Compare read latencies
        for result in results['read_latency']:
            if 'avg_read_us' in result and 'error' not in result:
                avg_us = result['avg_read_us']
                avg_ns = avg_us * 1000
                slowdown = avg_ns / baseline_read_ns if baseline_read_ns > 0 else 0
                pattern = result.get('access_pattern', 'unknown')
                log_info(f"{result['compressor']:8s} + {result['allocator']:8s} read ({pattern:10s}): "
                        f"{avg_us:7.2f}µs ({slowdown:.0f}x slower than RAM)")
    
    log_info("\n✓ Latency comparison complete")
    
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

def generate_benchmark_summary_report(results, output_file):
    """Generate human-readable benchmark summary report"""
    log_step(f"Generating benchmark summary report: {output_file}")
    
    system_info = results.get('system_info', {})
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    with open(output_file, 'w') as f:
        f.write("=" * 68 + "\n")
        f.write("SWAP PERFORMANCE BENCHMARK REPORT\n")
        f.write(f"System: {system_info.get('hostname', 'unknown')} - ")
        f.write(f"{system_info.get('ram_gb', '?')}GB RAM, ")
        f.write(f"{system_info.get('cpu_cores', '?')} CPU cores")
        if 'cpu_model' in system_info:
            f.write(f", {system_info['cpu_model']}")
        f.write(f"\nDate: {timestamp}\n")
        f.write("=" * 68 + "\n\n")
        
        # Optimal configuration section
        f.write("OPTIMAL CONFIGURATION\n")
        f.write("-" * 68 + "\n")
        
        if 'block_sizes' in results and results['block_sizes']:
            best_block = max(results['block_sizes'], 
                           key=lambda x: x.get('read_mb_per_sec', 0) + x.get('write_mb_per_sec', 0))
            block_to_cluster = {4: 0, 8: 1, 16: 2, 32: 3, 64: 4, 128: 5}
            cluster = block_to_cluster.get(best_block['block_size_kb'], 3)
            f.write(f"✓ Page Cluster:        {cluster} ({best_block['block_size_kb']}KB blocks)\n")
        
        if 'compressors' in results and results['compressors']:
            best_comp = max(results['compressors'], 
                          key=lambda x: x.get('compression_ratio', 0))
            f.write(f"✓ Compressor:          {best_comp['compressor']} ")
            f.write(f"({best_comp.get('compression_ratio', 0):.2f}x compression ratio)\n")
        
        if 'allocators' in results and results['allocators']:
            best_alloc = max(results['allocators'], 
                           key=lambda x: x.get('efficiency_pct', 0))
            f.write(f"✓ Allocator:           {best_alloc['allocator']} ")
            f.write(f"({best_alloc.get('efficiency_pct', 0):.1f}% efficiency)\n")
        
        if 'concurrency' in results and results['concurrency']:
            best_concur = max(results['concurrency'], 
                            key=lambda x: x.get('write_mb_per_sec', 0) + x.get('read_mb_per_sec', 0))
            f.write(f"✓ Stripe Width:        {best_concur['num_files']} devices ")
            f.write(f"(optimal concurrency)\n")
        
        f.write("\n")
        
        # Performance highlights
        f.write("PERFORMANCE HIGHLIGHTS\n")
        f.write("-" * 68 + "\n")
        
        if 'block_sizes' in results and results['block_sizes']:
            best_block = max(results['block_sizes'], 
                           key=lambda x: x.get('read_mb_per_sec', 0))
            f.write(f"• Best Block Size:     {best_block['block_size_kb']}KB ")
            f.write(f"({best_block.get('read_mb_per_sec', 0):.0f} MB/s read)\n")
        
        if 'compressors' in results and results['compressors']:
            best_comp = max(results['compressors'], 
                          key=lambda x: x.get('compression_ratio', 0))
            space_eff = (1 - 1/best_comp.get('compression_ratio', 1)) * 100
            f.write(f"• Best Compressor:     {best_comp['compressor']} ")
            f.write(f"({space_eff:.1f}% space efficiency)\n")
        
        if 'concurrency' in results and results['concurrency']:
            best_concur = max(results['concurrency'], 
                            key=lambda x: x.get('write_mb_per_sec', 0))
            f.write(f"• Best Concurrency:    {best_concur['num_files']} files ")
            f.write(f"({best_concur.get('write_mb_per_sec', 0):.0f} MB/s write)\n")
        
        # Latency comparison
        if 'latency' in results:
            latency = results['latency']
            if 'ram_baseline' in latency and 'zram_lz4' in latency:
                ram_lat = latency['ram_baseline'].get('avg_latency_ns', 0)
                zram_lat = latency['zram_lz4'].get('write_latency_us', 0) * 1000
                if ram_lat > 0 and zram_lat > 0:
                    slowdown = zram_lat / ram_lat
                    f.write(f"• RAM Access:          {ram_lat:.0f} ns/page (baseline)\n")
                    f.write(f"• ZRAM Latency:        {zram_lat/1000:.2f} µs ({slowdown:.0f}x slower than RAM)\n")
        
        f.write("\n")
        
        # Detailed results summary
        f.write("DETAILED RESULTS\n")
        f.write("-" * 68 + "\n")
        
        if 'block_sizes' in results and results['block_sizes']:
            f.write("Block Size Performance:\n")
            for bs in results['block_sizes'][:5]:  # Top 5
                f.write(f"  {bs['block_size_kb']:3d}KB: ")
                f.write(f"R={bs.get('read_mb_per_sec', 0):6.0f} MB/s, ")
                f.write(f"W={bs.get('write_mb_per_sec', 0):6.0f} MB/s\n")
            f.write("\n")
        
        if 'compressors' in results and results['compressors']:
            f.write("Compression Performance:\n")
            for comp in results['compressors']:
                f.write(f"  {comp['compressor']:8s}: ")
                f.write(f"{comp.get('compression_ratio', 0):.2f}x compression\n")
            f.write("\n")
        
        # Recommendations
        f.write("RECOMMENDATIONS\n")
        f.write("-" * 68 + "\n")
        
        if 'block_sizes' in results and results['block_sizes']:
            best_block = max(results['block_sizes'], 
                           key=lambda x: x.get('read_mb_per_sec', 0) + x.get('write_mb_per_sec', 0))
            block_to_cluster = {4: 0, 8: 1, 16: 2, 32: 3, 64: 4, 128: 5}
            cluster = block_to_cluster.get(best_block['block_size_kb'], 3)
            f.write(f"1. Use vm.page-cluster={cluster} for optimal I/O performance\n")
        
        if 'compressors' in results and results['compressors']:
            best_comp = max(results['compressors'], 
                          key=lambda x: x.get('compression_ratio', 0))
            f.write(f"2. Enable ZSWAP with {best_comp['compressor']} compressor for best compression\n")
        
        if 'concurrency' in results and results['concurrency']:
            best_concur = max(results['concurrency'], 
                            key=lambda x: x.get('write_mb_per_sec', 0) + x.get('read_mb_per_sec', 0))
            f.write(f"3. Configure {best_concur['num_files']} parallel swap devices for maximum throughput\n")
        
        if 'compressors' in results and results['compressors']:
            best_comp = max(results['compressors'], 
                          key=lambda x: x.get('compression_ratio', 0))
            f.write(f"4. Expected memory extension: {best_comp.get('compression_ratio', 0):.1f}x with {best_comp['compressor']} compression\n")
        
        f.write("\n")
        f.write("=" * 68 + "\n")
    
    log_info(f"✓ Benchmark summary report saved to {output_file}")

def generate_swap_config_report(results, output_file):
    """Generate human-readable swap configuration decisions report"""
    log_step(f"Generating swap configuration report: {output_file}")
    
    system_info = results.get('system_info', {})
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    ram_gb = system_info.get('ram_gb', 0)
    
    with open(output_file, 'w') as f:
        f.write("=" * 68 + "\n")
        f.write("SWAP CONFIGURATION DECISIONS\n")
        f.write(f"System: {system_info.get('hostname', 'unknown')} - ")
        f.write(f"{ram_gb}GB RAM\n")
        f.write(f"Date: {timestamp}\n")
        f.write("=" * 68 + "\n\n")
        
        # Auto-detection results
        f.write("AUTO-DETECTION RESULTS\n")
        f.write("-" * 68 + "\n")
        
        # Determine RAM solution based on system RAM
        if ram_gb < RAM_TIER_LOW_GB:
            ram_solution = "zram"
            reason = f"low RAM system (<{RAM_TIER_LOW_GB}GB)"
        elif ram_gb < RAM_TIER_HIGH_GB:
            ram_solution = "zswap"
            reason = f"medium RAM system ({RAM_TIER_LOW_GB}-{RAM_TIER_HIGH_GB}GB)"
        else:
            ram_solution = "zswap"
            reason = f"high RAM system (>{RAM_TIER_HIGH_GB}GB)"
        
        f.write(f"RAM Solution:    {ram_solution} ({reason})\n")
        f.write(f"Backing Type:    files_in_root (SSD with adequate space)\n")
        f.write(f"RAM Swap:        {int(ram_gb * 0.5)}GB (50% of RAM)\n")
        f.write(f"Disk Swap:       {int(ram_gb * 1.0)}GB (overflow protection)\n")
        
        if 'concurrency' in results and results['concurrency']:
            best_concur = max(results['concurrency'], 
                            key=lambda x: x.get('write_mb_per_sec', 0) + x.get('read_mb_per_sec', 0))
            f.write(f"Stripe Width:    {best_concur['num_files']} devices\n")
        
        f.write("\n")
        
        # Rationale
        f.write("RATIONALE\n")
        f.write("-" * 68 + "\n")
        f.write(f"• Selected {ram_solution.upper()}: System has {ram_gb}GB RAM ({reason})\n")
        
        if ram_solution == "zswap":
            f.write("• ZSWAP advantages: Lower overhead, good compression\n")
        else:
            f.write("• ZRAM advantages: Better compression, simpler setup\n")
        
        f.write("• Disk backing required: Prevents OOM situations\n")
        
        if 'concurrency' in results and results['concurrency']:
            best_concur = max(results['concurrency'], 
                            key=lambda x: x.get('write_mb_per_sec', 0) + x.get('read_mb_per_sec', 0))
            cpu_cores = system_info.get('cpu_cores', 4)
            f.write(f"• {best_concur['num_files']} swap files: ")
            if best_concur['num_files'] >= cpu_cores:
                f.write(f"Matches/exceeds CPU core count for parallelism\n")
            else:
                f.write(f"Optimal for this workload\n")
        
        f.write("\n")
        
        # Applied configuration
        f.write("APPLIED CONFIGURATION\n")
        f.write("-" * 68 + "\n")
        
        if 'compressors' in results and results['compressors']:
            best_comp = max(results['compressors'], 
                          key=lambda x: x.get('compression_ratio', 0))
            f.write(f"Compressor:      {best_comp['compressor']}\n")
            f.write(f"Compression:     {best_comp.get('compression_ratio', 0):.2f}x ratio\n")
        
        if 'allocators' in results and results['allocators']:
            best_alloc = max(results['allocators'], 
                           key=lambda x: x.get('efficiency_pct', 0))
            f.write(f"Allocator:       {best_alloc['allocator']}\n")
        
        if 'block_sizes' in results and results['block_sizes']:
            best_block = max(results['block_sizes'], 
                           key=lambda x: x.get('read_mb_per_sec', 0) + x.get('write_mb_per_sec', 0))
            block_to_cluster = {4: 0, 8: 1, 16: 2, 32: 3, 64: 4, 128: 5}
            cluster = block_to_cluster.get(best_block['block_size_kb'], 3)
            f.write(f"Page Cluster:    vm.page-cluster={cluster}\n")
        
        f.write("\n")
        
        # Warnings
        f.write("WARNINGS\n")
        f.write("-" * 68 + "\n")
        
        warnings_found = False
        if 'compressors' in results:
            for comp in results['compressors']:
                if 'warning' in comp:
                    f.write(f"⚠ {comp['warning']}\n")
                    warnings_found = True
        
        if not warnings_found:
            f.write("No warnings\n")
        
        f.write("\n")
        f.write("=" * 68 + "\n")
    
    log_info(f"✓ Swap configuration report saved to {output_file}")

def generate_matrix_heatmaps(matrix_results, output_prefix):
    """Generate heatmaps for matrix test results"""
    if not MATPLOTLIB_AVAILABLE:
        log_warn("matplotlib not available - skipping matrix heatmap generation")
        return None
    
    import numpy as np
    
    block_sizes = matrix_results['block_sizes']
    concurrency_levels = matrix_results['concurrency_levels'] 
    
    # Extract throughput data into 2D array
    write_data = np.zeros((len(concurrency_levels), len(block_sizes)))
    read_data = np.zeros((len(concurrency_levels), len(block_sizes)))
    
    for result in matrix_results['matrix']:
        if 'error' in result:
            continue
        bi = block_sizes.index(result['block_size_kb'])
        ci = concurrency_levels.index(result['concurrency'])
        write_data[ci, bi] = result['write_mb_per_sec']
        read_data[ci, bi] = result['read_mb_per_sec']
    
    # Create throughput heatmap
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))
    
    im1 = ax1.imshow(write_data, cmap='YlOrRd', aspect='auto')
    ax1.set_title('Write Throughput (MB/s)', fontsize=14, fontweight='bold')
    ax1.set_xlabel('Block Size (KB)')
    ax1.set_ylabel('Concurrency Level')
    ax1.set_xticks(range(len(block_sizes)))
    ax1.set_xticklabels(block_sizes)
    ax1.set_yticks(range(len(concurrency_levels)))
    ax1.set_yticklabels(concurrency_levels)
    plt.colorbar(im1, ax=ax1)
    
    # Annotate cells with values
    for i in range(len(concurrency_levels)):
        for j in range(len(block_sizes)):
            if write_data[i, j] > 0:
                text = ax1.text(j, i, f'{write_data[i, j]:.0f}',
                              ha="center", va="center", color="black", fontsize=8)
    
    im2 = ax2.imshow(read_data, cmap='YlGnBu', aspect='auto')
    ax2.set_title('Read Throughput (MB/s)', fontsize=14, fontweight='bold')
    ax2.set_xlabel('Block Size (KB)')
    ax2.set_ylabel('Concurrency Level')
    ax2.set_xticks(range(len(block_sizes)))
    ax2.set_xticklabels(block_sizes)
    ax2.set_yticks(range(len(concurrency_levels)))
    ax2.set_yticklabels(concurrency_levels)
    plt.colorbar(im2, ax=ax2)
    
    for i in range(len(concurrency_levels)):
        for j in range(len(block_sizes)):
            if read_data[i, j] > 0:
                text = ax2.text(j, i, f'{read_data[i, j]:.0f}',
                              ha="center", va="center", color="black", fontsize=8)
    
    plt.tight_layout()
    output_file = f'{output_prefix}-matrix-throughput.png'
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    plt.close()
    log_info(f"Generated matrix throughput heatmap: {output_file}")
    return output_file

def generate_charts(results, output_dir='/var/log/debian-install', webp=False):
    """
    Generate matplotlib charts for benchmark results
    
    Creates PNG (or WebP) charts for:
    1. Block size vs Throughput (read/write, sequential/random)
    2. Block size vs Latency
    3. Concurrency vs Throughput scaling
    4. Compression ratio comparison
    
    Args:
        results: Benchmark results dictionary
        output_dir: Directory to save PNG files
        webp: If True, convert PNG to WebP format (smaller file size)
    
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
            
            # Add subtitle with test parameters
            title = 'Block Size vs Throughput'
            if results['block_sizes']:
                first_test = results['block_sizes'][0]
                test_params = []
                if 'concurrency' in first_test:
                    test_params.append(f"Concurrency: {first_test['concurrency']}")
                if 'runtime_sec' in first_test:
                    test_params.append(f"Duration: {first_test['runtime_sec']}s")
                if 'io_pattern' in first_test:
                    test_params.append(f"Pattern: {first_test['io_pattern']}")
                if test_params:
                    subtitle = ' | '.join(test_params)
                    ax.set_title(f'{title}\n{subtitle}', fontsize=14, fontweight='bold')
                else:
                    ax.set_title(title, fontsize=14, fontweight='bold')
            else:
                ax.set_title(title, fontsize=14, fontweight='bold')
            
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
        
        # Chart 5: Read Latency Heatmap
        if 'latency_comparison' in results and 'read_latency' in results['latency_comparison']:
            read_latencies = results['latency_comparison']['read_latency']
            valid_reads = [r for r in read_latencies if 'error' not in r and 'avg_read_us' in r]
            
            if valid_reads:
                # Create a matrix for heatmap: compressor × allocator
                compressors = sorted(list(set(r['compressor'] for r in valid_reads)))
                allocators = sorted(list(set(r['allocator'] for r in valid_reads)))
                patterns = sorted(list(set(r.get('access_pattern', 'unknown') for r in valid_reads)))
                
                if len(patterns) > 1:
                    # Multiple patterns - create subplots
                    fig, axes = plt.subplots(1, len(patterns), figsize=(6*len(patterns), 5))
                    if len(patterns) == 1:
                        axes = [axes]
                    
                    for idx, pattern in enumerate(patterns):
                        pattern_data = [r for r in valid_reads if r.get('access_pattern') == pattern]
                        
                        # Build matrix
                        matrix = []
                        for comp in compressors:
                            row = []
                            for alloc in allocators:
                                matching = [r for r in pattern_data if r['compressor'] == comp and r['allocator'] == alloc]
                                if matching:
                                    row.append(matching[0]['avg_read_us'])
                                else:
                                    row.append(0)
                            matrix.append(row)
                        
                        im = axes[idx].imshow(matrix, cmap='RdYlGn_r', aspect='auto')
                        axes[idx].set_xticks(range(len(allocators)))
                        axes[idx].set_yticks(range(len(compressors)))
                        axes[idx].set_xticklabels(allocators, rotation=45, ha='right')
                        axes[idx].set_yticklabels(compressors)
                        axes[idx].set_title(f'Read Latency (µs) - {pattern}', fontweight='bold')
                        
                        # Add text annotations
                        for i in range(len(compressors)):
                            for j in range(len(allocators)):
                                if matrix[i][j] > 0:
                                    text = axes[idx].text(j, i, f'{matrix[i][j]:.1f}',
                                                   ha="center", va="center", color="black", fontsize=9)
                        
                        plt.colorbar(im, ax=axes[idx], label='Latency (µs)')
                    
                    chart_file = f"{output_dir}/benchmark-read-latency-{timestamp}.png"
                    plt.tight_layout()
                    plt.savefig(chart_file, dpi=150)
                    plt.close()
                    chart_files.append(chart_file)
                    log_info(f"Generated read latency chart: {chart_file}")
        
        # Chart 6: Write Latency Heatmap
        if 'latency_comparison' in results and 'write_latency' in results['latency_comparison']:
            write_latencies = results['latency_comparison']['write_latency']
            valid_writes = [w for w in write_latencies if 'error' not in w and 'avg_write_us' in w]
            
            if valid_writes:
                compressors = sorted(list(set(w['compressor'] for w in valid_writes)))
                allocators = sorted(list(set(w['allocator'] for w in valid_writes)))
                
                # Build matrix
                matrix = []
                for comp in compressors:
                    row = []
                    for alloc in allocators:
                        matching = [w for w in valid_writes if w['compressor'] == comp and w['allocator'] == alloc]
                        if matching:
                            row.append(matching[0]['avg_write_us'])
                        else:
                            row.append(0)
                    matrix.append(row)
                
                fig, ax = plt.subplots(figsize=(8, 6))
                im = ax.imshow(matrix, cmap='RdYlGn_r', aspect='auto')
                ax.set_xticks(range(len(allocators)))
                ax.set_yticks(range(len(compressors)))
                ax.set_xticklabels(allocators, rotation=45, ha='right')
                ax.set_yticklabels(compressors)
                ax.set_title('Write Latency (µs) - Compressor × Allocator', fontsize=14, fontweight='bold')
                
                # Add text annotations
                for i in range(len(compressors)):
                    for j in range(len(allocators)):
                        if matrix[i][j] > 0:
                            text = ax.text(j, i, f'{matrix[i][j]:.1f}',
                                       ha="center", va="center", color="black", fontsize=10)
                
                plt.colorbar(im, ax=ax, label='Latency (µs)')
                
                chart_file = f"{output_dir}/benchmark-write-latency-{timestamp}.png"
                plt.tight_layout()
                plt.savefig(chart_file, dpi=150)
                plt.close()
                chart_files.append(chart_file)
                log_info(f"Generated write latency chart: {chart_file}")
        
        # Chart 7: Latency Distribution (Box Plot)
        if 'latency_comparison' in results:
            comp = results['latency_comparison']
            has_read = 'read_latency' in comp and any('p50_read_us' in r for r in comp['read_latency'] if 'error' not in r)
            has_write = 'write_latency' in comp and any('p50_write_us' in w for w in comp['write_latency'] if 'error' not in w)
            
            if has_read or has_write:
                fig, axes = plt.subplots(1, 2, figsize=(14, 6))
                
                # Read latency distribution
                if has_read:
                    read_data = comp['read_latency']
                    valid_reads = [r for r in read_data if 'error' not in r and 'p50_read_us' in r]
                    
                    labels = []
                    box_data = []
                    for r in valid_reads:
                        label = f"{r['compressor']}\n{r['allocator']}\n{r.get('access_pattern', '')}"
                        labels.append(label)
                        # Approximate box plot from percentiles
                        box_data.append([
                            r.get('min_read_us', 0),
                            r.get('p50_read_us', 0) - (r.get('p50_read_us', 0) - r.get('min_read_us', 0)) * 0.5,
                            r.get('p50_read_us', 0),
                            r.get('p95_read_us', 0),
                            r.get('max_read_us', 0)
                        ])
                    
                    axes[0].boxplot(box_data, labels=labels, patch_artist=True)
                    axes[0].set_ylabel('Latency (µs)', fontsize=12)
                    axes[0].set_title('Read Latency Distribution', fontsize=12, fontweight='bold')
                    axes[0].tick_params(axis='x', rotation=45)
                    axes[0].grid(True, alpha=0.3, axis='y')
                
                # Write latency distribution
                if has_write:
                    write_data = comp['write_latency']
                    valid_writes = [w for w in write_data if 'error' not in w and 'p50_write_us' in w]
                    
                    labels = []
                    box_data = []
                    for w in valid_writes:
                        label = f"{w['compressor']}\n{w['allocator']}"
                        labels.append(label)
                        box_data.append([
                            w.get('min_write_us', 0),
                            w.get('p50_write_us', 0) - (w.get('p50_write_us', 0) - w.get('min_write_us', 0)) * 0.5,
                            w.get('p50_write_us', 0),
                            w.get('p95_write_us', 0),
                            w.get('max_write_us', 0)
                        ])
                    
                    axes[1].boxplot(box_data, labels=labels, patch_artist=True)
                    axes[1].set_ylabel('Latency (µs)', fontsize=12)
                    axes[1].set_title('Write Latency Distribution', fontsize=12, fontweight='bold')
                    axes[1].tick_params(axis='x', rotation=45)
                    axes[1].grid(True, alpha=0.3, axis='y')
                
                # Add explanatory legend for box plot components
                # Create a text box with explanation
                legend_text = 'Box Plot Legend:\n' \
                             '• Box: Q1-Q3 (25th-75th percentile)\n' \
                             '• Line in box: Median (50th percentile)\n' \
                             '• Whiskers: 1.5×IQR (Interquartile Range)\n' \
                             '• Circles: Outliers beyond whiskers'
                
                # Place legend below the subplots
                fig.text(0.5, -0.05, legend_text, ha='center', va='top', 
                        fontsize=9, bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.3))
                
                chart_file = f"{output_dir}/benchmark-latency-distribution-{timestamp}.png"
                plt.tight_layout()
                plt.subplots_adjust(bottom=0.15)  # Make room for legend
                plt.savefig(chart_file, dpi=150, bbox_inches='tight')
                plt.close()
                chart_files.append(chart_file)
                log_info(f"Generated latency distribution chart: {chart_file}")
        
    except Exception as e:
        log_error(f"Failed to generate charts: {e}")
        import traceback
        log_debug(traceback.format_exc())
    
    # Convert PNG to WebP if requested
    if webp and chart_files:
        log_info("Converting charts to WebP format...")
        webp_files = []
        try:
            from PIL import Image
            for png_file in chart_files:
                if png_file.endswith('.png'):
                    webp_file = png_file.replace('.png', '.webp')
                    try:
                        img = Image.open(png_file)
                        img.save(webp_file, 'WEBP', quality=85, method=6)
                        # Verify the WebP file was created successfully
                        if os.path.exists(webp_file) and os.path.getsize(webp_file) > 0:
                            webp_files.append(webp_file)
                            # Remove original PNG only after successful conversion
                            os.remove(png_file)
                            log_info(f"Converted {os.path.basename(png_file)} to WebP")
                        else:
                            log_warn(f"WebP conversion produced invalid file for {png_file}, keeping PNG")
                            webp_files.append(png_file)
                    except Exception as e:
                        log_warn(f"Failed to convert {png_file} to WebP: {e}")
                        # Keep original PNG if conversion fails
                        webp_files.append(png_file)
            if webp_files:
                chart_files = webp_files
                log_info(f"✓ Converted {len(webp_files)} charts to WebP")
        except ImportError:
            log_warn("PIL (Pillow) not available - cannot convert to WebP")
            log_info("Install with: pip3 install Pillow")
        except Exception as e:
            log_warn(f"WebP conversion failed: {e}")
    
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
        # Use efficiency percentage for bar chart (shows allocator overhead)
        # Higher efficiency = better (less overhead)
        # Note: Negative efficiency indicates overhead (uses more memory than original)
        max_eff = max(a.get('efficiency_pct', 0) for a in results['allocators'])
        for alloc in results['allocators']:
            name = alloc.get('allocator', 'N/A')
            ratio = alloc.get('compression_ratio', 0)
            eff = alloc.get('efficiency_pct', 0)
            # Bar shows efficiency: higher is better
            # For negative efficiency (overhead), show no bar
            # For zero max_eff, show no bar (avoid division by zero)
            if max_eff > 0 and eff >= 0:
                bar_length = int((eff / max_eff) * 10)
            else:
                bar_length = 0  # No bar for negative efficiency or zero max_eff
            bar = '▓' * bar_length + '░' * (10 - bar_length)
            is_best = eff == max_eff and eff > 0
            marker = " ⭐" if is_best else ""
            html += f"  {name:8s}: {bar} {ratio:.1f}x ratio, {eff:+.0f}% eff{marker}\n"
        html += "\n"
    
    # Concurrency tests with scaling chart
    if 'concurrency' in results and results['concurrency']:
        html += "<b>⚡ Concurrency Scaling:</b>\n"
        # Only compute max_total from successful tests
        successful_tests = [c for c in results['concurrency'] if 'error' not in c]
        if successful_tests:
            max_total = max((c.get('write_mb_per_sec', 0) + c.get('read_mb_per_sec', 0)) for c in successful_tests)
        else:
            max_total = 1  # Avoid division by zero
        
        for concur in results['concurrency']:
            files = concur.get('num_files', 0)
            if files == 0 or not isinstance(files, int):
                files_str = str(files)
            else:
                files_str = f"{files:2d}"
            
            # Check if test failed
            if 'error' in concur:
                html += f"  {files_str} files: ❌ FAILED ({concur.get('error', 'unknown error')})\n"
            else:
                write_mb = concur.get('write_mb_per_sec', 0)
                read_mb = concur.get('read_mb_per_sec', 0)
                total = write_mb + read_mb
                bar_length = int((total / max_total) * 10) if max_total > 0 else 0
                bar = '█' * bar_length + '░' * (10 - bar_length)
                is_best = (total == max_total and max_total > 0)
                marker = " ⭐" if is_best else ""
                html += f"  {files_str} files: {bar} ↑{write_mb:.0f} ↓{read_mb:.0f} MB/s{marker}\n"
        html += "\n"
    
    # Matrix test results (block size × concurrency)
    if 'matrix' in results and isinstance(results['matrix'], dict) and 'optimal' in results['matrix']:
        matrix = results['matrix']
        html += "<b>🎯 Optimal Configuration (Matrix Test):</b>\n"
        
        if 'best_combined' in matrix.get('optimal', {}):
            best = matrix['optimal']['best_combined']
            html += f"  Best Overall: {best['block_size_kb']}KB × {best['concurrency']} jobs = {best['throughput_mb_per_sec']:.0f} MB/s\n"
        
        if 'best_write' in matrix.get('optimal', {}):
            best_w = matrix['optimal']['best_write']
            html += f"  Best Write: {best_w['block_size_kb']}KB × {best_w['concurrency']} jobs = {best_w['throughput_mb_per_sec']:.0f} MB/s\n"
        
        if 'best_read' in matrix.get('optimal', {}):
            best_r = matrix['optimal']['best_read']
            html += f"  Best Read: {best_r['block_size_kb']}KB × {best_r['concurrency']} jobs = {best_r['throughput_mb_per_sec']:.0f} MB/s\n"
        
        # Show recommended settings
        if 'recommended_page_cluster' in matrix.get('optimal', {}):
            rec_cluster = matrix['optimal']['recommended_page_cluster']
            rec_width = matrix['optimal'].get('recommended_swap_stripe_width', 'N/A')
            html += f"\n  <i>Recommended:</i>\n"
            html += f"  SWAP_PAGE_CLUSTER={rec_cluster}\n"
            html += f"  SWAP_STRIPE_WIDTH={rec_width}\n"
        html += "\n"
    
    # ZSWAP vs ZRAM comparison
    if 'zswap_vs_zram' in results and 'error' not in results['zswap_vs_zram']:
        comp = results['zswap_vs_zram']
        html += "<b>⚔️ ZSWAP vs ZRAM:</b>\n"
        
        if 'zram' in comp and 'zswap' in comp:
            zram_ratio = comp['zram'].get('compression_ratio', 0)
            zswap_ratio = comp['zswap'].get('compression_ratio', 0)
            zram_lat = comp['zram'].get('avg_latency_us', 0)
            zswap_lat = comp['zswap'].get('avg_latency_us', 0)
            
            html += f"  ZRAM:  {zram_ratio:.1f}x ratio, {zram_lat:.1f}µs latency\n"
            html += f"  ZSWAP: {zswap_ratio:.1f}x ratio, {zswap_lat:.1f}µs latency\n"
            
            # Determine winner (avoid division by zero)
            if zram_lat > 0 and zswap_lat > 0:
                if zram_lat < zswap_lat:
                    winner = "ZRAM"
                    diff_pct = ((zswap_lat - zram_lat) / zram_lat) * 100
                    html += f"  ⭐ {winner} is {diff_pct:.0f}% faster\n"
                elif zswap_lat < zram_lat:
                    winner = "ZSWAP"
                    diff_pct = ((zram_lat - zswap_lat) / zswap_lat) * 100
                    html += f"  ⭐ {winner} is {diff_pct:.0f}% faster\n"
                # If equal latency, don't show a winner
        html += "\n"
    
    # Latency comparison results
    if 'latency_comparison' in results:
        lat_comp = results['latency_comparison']
        
        # Baseline
        if 'baseline' in lat_comp and 'read_ns' in lat_comp['baseline']:
            baseline = lat_comp['baseline']
            html += "<b>⚡ Memory Latency:</b>\n"
            html += f"  <i>Baseline (Native RAM):</i>\n"
            html += f"  Read:  {baseline['read_ns']:.0f} ns/page\n"
            html += f"  Write: {baseline['write_ns']:.0f} ns/page\n\n"
        
        # Write latency
        if 'write_latency' in lat_comp and lat_comp['write_latency']:
            html += "  <i>Write Latency (swap-out):</i>\n"
            valid_writes = [w for w in lat_comp['write_latency'] if 'error' not in w and 'avg_write_us' in w]
            
            # Get baseline for comparison
            baseline_write_ns = baseline.get('write_ns', 0) if 'baseline' in lat_comp else 0
            
            if valid_writes:
                min_latency = min(w['avg_write_us'] for w in valid_writes)
                max_latency = max(w['avg_write_us'] for w in valid_writes)
                
                # Show ALL write latency tests (6 total)
                for w in valid_writes:
                    avg_us = w['avg_write_us']
                    bar_len = int(10 * (avg_us - min_latency) / (max_latency - min_latency + 1)) if max_latency > min_latency else 5
                    bar = '█' * bar_len + '░' * (10 - bar_len)
                    is_best = (avg_us == min_latency)
                    marker = " ⭐" if is_best else ""
                    
                    # Add comparison with baseline if available
                    comparison = ""
                    if baseline_write_ns > 0:
                        slowdown = (avg_us * 1000) / baseline_write_ns  # Convert us to ns for comparison
                        comparison = f" ({slowdown:.0f}×)"
                    
                    html += f"  {w['compressor']:6s}+{w['allocator']:8s}: {bar} {avg_us:6.1f}µs{comparison}{marker}\n"
            html += "\n"
        
        # Read latency
        if 'read_latency' in lat_comp and lat_comp['read_latency']:
            html += "  <i>Read Latency (page fault):</i>\n"
            valid_reads = [r for r in lat_comp['read_latency'] if 'error' not in r and 'avg_read_us' in r]
            
            # Get baseline for comparison
            baseline_read_ns = baseline.get('read_ns', 0) if 'baseline' in lat_comp else 0
            
            if valid_reads:
                # Group by compressor+allocator
                unique_configs = {}
                for r in valid_reads:
                    key = f"{r['compressor']}+{r['allocator']}"
                    if key not in unique_configs or r.get('access_pattern') == 'random':
                        unique_configs[key] = r
                
                configs_list = list(unique_configs.values())
                min_latency = min(r['avg_read_us'] for r in configs_list)
                max_latency = max(r['avg_read_us'] for r in configs_list)
                
                for r in configs_list[:4]:  # Limit to top 4
                    avg_us = r['avg_read_us']
                    pattern = r.get('access_pattern', 'seq')[:3]
                    bar_len = int(10 * (avg_us - min_latency) / (max_latency - min_latency + 1)) if max_latency > min_latency else 5
                    bar = '█' * bar_len + '░' * (10 - bar_len)
                    is_best = (avg_us == min_latency)
                    marker = " ⭐" if is_best else ""
                    
                    # Add comparison with baseline if available
                    comparison = ""
                    if baseline_read_ns > 0:
                        slowdown = (avg_us * 1000) / baseline_read_ns  # Convert us to ns for comparison
                        comparison = f" ({slowdown:.0f}×)"
                    
                    html += f"  {r['compressor']:6s}+{r['allocator']:8s}({pattern}): {bar} {avg_us:6.1f}µs{comparison}{marker}\n"
            html += "\n"
        
        # Add RAM vs ZRAM vs Disk latency comparison
        if 'baseline' in lat_comp and 'write_latency' in lat_comp and 'read_latency' in lat_comp:
            baseline = lat_comp['baseline']
            ram_read = baseline.get('read_ns', 0)
            ram_write = baseline.get('write_ns', 0)
            
            # Best ZRAM latencies
            valid_read_tests = [t for t in lat_comp['read_latency'] if 'error' not in t and 'avg_read_us' in t]
            valid_write_tests = [t for t in lat_comp['write_latency'] if 'error' not in t and 'avg_write_us' in t]
            
            if valid_read_tests and valid_write_tests and ram_read > 0 and ram_write > 0:
                best_zram_read = min([t['avg_read_us'] for t in valid_read_tests]) * 1000  # to ns
                best_zram_write = min([t['avg_write_us'] for t in valid_write_tests]) * 1000
                
                # Disk latency estimates (typical values)
                disk_read_ns = 5000000  # ~5ms typical for HDD
                disk_write_ns = 10000000  # ~10ms typical for HDD
                
                html += "<b>⚡ Latency Comparison:</b>\n"
                html += f"  <i>Read:</i>\n"
                html += f"  RAM:   {ram_read:8.0f} ns (baseline)\n"
                html += f"  ZRAM:  {best_zram_read:8.0f} ns ({best_zram_read/ram_read:4.0f}× slower)\n"
                html += f"  Disk:  {disk_read_ns/1000:8.0f} µs ({disk_read_ns/ram_read:4.0f}× slower)\n\n"
                html += f"  <i>Write:</i>\n"
                html += f"  RAM:   {ram_write:8.0f} ns (baseline)\n"
                html += f"  ZRAM:  {best_zram_write:8.0f} ns ({best_zram_write/ram_write:4.0f}× slower)\n"
                html += f"  Disk:  {disk_write_ns/1000:8.0f} µs ({disk_write_ns/ram_write:4.0f}× slower)\n"
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
  %(prog)s --test-latency --latency-size 100
  %(prog)s --compare-memory-only
  %(prog)s --output results.json --shell-config swap.conf
        """
    )
    
    parser.add_argument('--test-all', action='store_true',
                       help='Run all benchmarks including latency tests')
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
    parser.add_argument('--test-matrix', action='store_true',
                       help='Test block size × concurrency matrix to find optimal configuration')
    parser.add_argument('--test-zswap', action='store_true',
                       help='Run comprehensive ZSWAP benchmarks (requires swap backing device)')
    parser.add_argument('--zswap-device', metavar='DEVICE', default='/dev/vda4',
                       help='Swap device for ZSWAP backing (default: /dev/vda4)')
    parser.add_argument('--compare-zswap-zram', action='store_true',
                       help='Compare ZSWAP vs ZRAM performance')
    parser.add_argument('--test-latency', action='store_true',
                       help='Run comprehensive latency comparison tests')
    parser.add_argument('--latency-size', type=int, metavar='MB', default=100,
                       help='Size for latency tests in MB (default: 100)')
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
    parser.add_argument('--webp', action='store_true',
                       help='Convert charts to WebP format for smaller file size (requires Pillow)')
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.latency_size <= 0 or args.latency_size > 10240:
        log_error(f"Invalid --latency-size: {args.latency_size}. Must be between 1 and 10240 MB")
        sys.exit(1)
    
    if args.duration < 1 or args.duration > 3600:
        log_error(f"Invalid --duration: {args.duration}. Must be between 1 and 3600 seconds")
        sys.exit(1)
    
    # Check root and dependencies
    check_root()
    check_dependencies()
    
    # Compile C programs for memory management
    if not compile_c_programs():
        log_error("Failed to compile C memory management programs")
        log_error("Ensure gcc is installed: apt install gcc")
        sys.exit(1)
    
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
                # Calculate actual percentage (compression_test_size in MB, ram_gb needs to be converted to MB)
                ram_mb = system_info['ram_gb'] * 1024
                percent_of_ram = (compression_test_size / ram_mb) * 100
                log_warn_ts(f"Using reduced test size: {compression_test_size}MB ({percent_of_ram:.1f}% of {system_info['ram_gb']}GB RAM)")
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
    
    if args.test_matrix or args.test_all:
        # Matrix test counts as one comprehensive test
        total_tests += 1
    
    if args.test_zswap:
        total_tests += 2  # lz4 and zstd
    
    if args.compare_zswap_zram:
        total_tests += 4  # ZRAM lz4, ZRAM zstd, ZSWAP lz4, ZSWAP zstd
    
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
    
    # Matrix testing (block size × concurrency)
    if args.test_matrix or args.test_all:
        try:
            log_info_ts("\n=== Running Block Size × Concurrency Matrix Test ===")
            results['matrix'] = test_blocksize_concurrency_matrix(
                runtime_sec=args.duration
            )
        except Exception as e:
            log_error(f"Matrix test failed: {e}")
            results['matrix'] = {'error': str(e)}
    
    # ZSWAP benchmarks
    if args.test_zswap:
        try:
            log_info_ts("\n=== Running ZSWAP Benchmarks ===")
            results['zswap'] = {}
            
            # Test with lz4
            log_info("Testing ZSWAP with lz4...")
            results['zswap']['lz4'] = benchmark_zswap_comprehensive(
                swap_device=args.zswap_device,
                compressor='lz4',
                zpool='z3fold',
                test_size_mb=compression_test_size
            )
            
            # Test with zstd
            log_info("Testing ZSWAP with zstd...")
            results['zswap']['zstd'] = benchmark_zswap_comprehensive(
                swap_device=args.zswap_device,
                compressor='zstd',
                zpool='z3fold',
                test_size_mb=compression_test_size
            )
        except Exception as e:
            log_error(f"ZSWAP benchmark failed: {e}")
            results['zswap'] = {'error': str(e)}
    
    # ZSWAP vs ZRAM comparison
    if args.compare_zswap_zram or args.test_all:
        try:
            log_info_ts("\n=== Comparing ZSWAP vs ZRAM ===")
            results['zswap_vs_zram'] = compare_zswap_vs_zram(
                swap_device=args.zswap_device,
                test_size_mb=compression_test_size
            )
        except Exception as e:
            log_error(f"ZSWAP vs ZRAM comparison failed: {e}")
            results['zswap_vs_zram'] = {'error': str(e)}
    
    if args.compare_memory_only:
        results['memory_only_comparison'] = compare_memory_only()
    
    # Latency tests
    if args.test_all or args.test_latency:
        latency_size = args.latency_size
        log_info(f"\n=== Running Latency Tests ({latency_size}MB) ===")
        results['latency_comparison'] = benchmark_latency_comparison(latency_size)
    
    # Final cleanup of temporary test files
    log_info("Cleaning up temporary test files...")
    cleanup_test_files()
    
    # Additional cleanup patterns for test run directories not covered by cleanup_test_files
    # These are broader patterns that may catch test-specific subdirectories
    additional_patterns = [
        '/tmp/fio_test*',      # FIO test directories (not just .job files)
        '/tmp/swap_test*',     # Swap test directories
        '/tmp/ptable-*',       # Partition table dumps
    ]
    for pattern in additional_patterns:
        try:
            for f in glob.glob(pattern):
                if os.path.isfile(f):
                    os.remove(f)
                    log_debug(f"Removed file: {f}")
                elif os.path.isdir(f):
                    import shutil
                    shutil.rmtree(f)
                    log_debug(f"Removed directory: {f}")
        except Exception as e:
            log_debug(f"Cleanup warning for {pattern}: {e}")
    
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
    
    # Generate human-readable reports
    timestamp_str = datetime.now().strftime('%Y%m%d-%H%M%S')
    report_dir = '/var/log/debian-install'
    os.makedirs(report_dir, exist_ok=True)
    
    summary_report = f"{report_dir}/benchmark-summary-{timestamp_str}.txt"
    config_report = f"{report_dir}/swap-config-decisions-{timestamp_str}.txt"
    
    try:
        generate_benchmark_summary_report(results, summary_report)
    except Exception as e:
        log_warn(f"Failed to generate benchmark summary report: {e}")
    
    try:
        generate_swap_config_report(results, config_report)
    except Exception as e:
        log_warn(f"Failed to generate swap config report: {e}")
    
    # Send to Telegram if requested
    if args.telegram:
        if not TELEGRAM_AVAILABLE:
            log_error("Cannot send to Telegram: telegram_client module not available")
            log_error("Ensure telegram_client.py is in the same directory as benchmark.py")
        else:
            try:
                telegram = TelegramClient()
                
                # Generate charts (with WebP conversion if requested)
                log_info("Generating performance charts...")
                chart_files = generate_charts(results, webp=args.webp)
                
                # Generate matrix heatmaps if matrix tests were run
                if 'matrix' in results and isinstance(results['matrix'], dict) and 'matrix' in results['matrix']:
                    try:
                        output_prefix = f"/var/log/debian-install/benchmark-{timestamp_str}"
                        matrix_chart = generate_matrix_heatmaps(results['matrix'], output_prefix)
                        if matrix_chart:
                            chart_files.append(matrix_chart)
                    except Exception as e:
                        log_warn(f"Failed to generate matrix heatmaps: {e}")
                
                # Send HTML summary
                html_message = format_benchmark_html(results)
                log_info("Sending benchmark results to Telegram...")
                if telegram.send_message(html_message):
                    log_info("✓ Benchmark results sent to Telegram successfully!")
                else:
                    log_error("✗ Failed to send benchmark results to Telegram")
                    log_error(f"Results are available in {local_results_file}")
                
                # Send charts as media group (single message with all charts)
                if chart_files:
                    log_info(f"Sending {len(chart_files)} performance charts as media group...")
                    caption = f"📊 Benchmark Charts ({len(chart_files)} charts)"
                    if telegram.send_media_group(chart_files, caption=caption):
                        log_info(f"✓ Sent all {len(chart_files)} charts in single message")
                    else:
                        log_warn("Failed to send charts as media group, falling back to individual messages")
                        # Fallback: send charts one by one
                        # Use the timestamp_str variable defined at line 3520 for consistency
                        for chart_file in chart_files:
                            # Handle both .png and .webp extensions
                            chart_name = os.path.basename(chart_file)
                            for ext in ['.png', '.webp']:
                                chart_name = chart_name.replace(ext, '')
                            chart_name = chart_name.replace('benchmark-', '').replace('-' + timestamp_str, '')
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
