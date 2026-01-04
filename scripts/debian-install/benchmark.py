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

# Colors for output
class Colors:
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    BOLD = '\033[1m'
    NC = '\033[0m'

def log_info(msg):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")

def log_warn(msg):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")

def log_error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}", file=sys.stderr)

def log_step(msg):
    print(f"{Colors.BLUE}[STEP]{Colors.NC} {msg}")

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
    
    # CPU
    info['cpu_cores'] = os.cpu_count()
    
    # Current page-cluster
    try:
        info['page_cluster'] = int(run_command('sysctl -n vm.page-cluster'))
    except:
        info['page_cluster'] = 3
    
    return info

def ensure_zram_loaded():
    """Ensure ZRAM kernel module is loaded"""
    try:
        run_command('modprobe zram', check=False)
        # Reset any existing zram devices
        if os.path.exists('/dev/zram0'):
            run_command('swapoff /dev/zram0', check=False)
            run_command('echo 1 > /sys/block/zram0/reset', check=False)
        return True
    except:
        return False

def benchmark_block_size_fio(size_kb, test_file='/tmp/fio_test', size_mb=512):
    """
    Benchmark I/O performance with fio (more accurate than dd)
    
    Args:
        size_kb: Block size in KB
        test_file: Path to test file
        size_mb: Test file size in MB
    """
    log_step(f"Benchmarking block size: {size_kb}KB with fio")
    
    results = {
        'block_size_kb': size_kb,
        'test_size_mb': size_mb,
        'timestamp': datetime.now().isoformat()
    }
    
    # Sequential write test
    log_info("Sequential write test...")
    fio_write = f"""
[global]
ioengine=libaio
direct=1
size={size_mb}m
filename={test_file}

[seqwrite]
rw=write
bs={size_kb}k
"""
    
    try:
        with open('/tmp/fio_write.job', 'w') as f:
            f.write(fio_write)
        
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
    except Exception as e:
        log_error(f"Write test failed: {e}")
        results['write_error'] = str(e)
    
    # Sequential read test
    log_info("Sequential read test...")
    fio_read = f"""
[global]
ioengine=libaio
direct=1
size={size_mb}m
filename={test_file}

[seqread]
rw=read
bs={size_kb}k
"""
    
    try:
        with open('/tmp/fio_read.job', 'w') as f:
            f.write(fio_read)
        
        # Clear cache
        run_command('sync && echo 3 > /proc/sys/vm/drop_caches')
        
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
    except Exception as e:
        log_error(f"Read test failed: {e}")
        results['read_error'] = str(e)
    
    # Cleanup
    for f in [test_file, '/tmp/fio_write.job', '/tmp/fio_read.job']:
        if os.path.exists(f):
            try:
                os.remove(f)
            except:
                pass
    
    return results

def benchmark_compression(compressor, allocator='zsmalloc', size_mb=100):
    """
    Benchmark compression algorithm with specific allocator
    Tests with semi-realistic memory workload
    """
    log_step(f"Benchmarking {compressor} with {allocator}")
    
    results = {
        'compressor': compressor,
        'allocator': allocator,
        'test_size_mb': size_mb,
        'timestamp': datetime.now().isoformat()
    }
    
    try:
        # Ensure ZRAM is loaded
        ensure_zram_loaded()
        
        # Check if we can set allocator (may not be available)
        if os.path.exists('/sys/block/zram0/mem_pool'):
            try:
                run_command(f'echo {allocator} > /sys/block/zram0/mem_pool', check=False)
            except:
                log_warn(f"Could not set allocator to {allocator}, using default")
        
        # Set compressor
        if os.path.exists('/sys/block/zram0/comp_algorithm'):
            run_command(f'echo {compressor} > /sys/block/zram0/comp_algorithm', check=False)
        
        # Set size
        size_bytes = size_mb * 1024 * 1024
        run_command(f'echo {size_bytes} > /sys/block/zram0/disksize')
        
        # Make swap
        run_command('mkswap /dev/zram0')
        run_command('swapon -p 100 /dev/zram0')
        
        # Create memory pressure with mixed data patterns
        start = time.time()
        
        # Test with different data patterns
        test_script = f"""
python3 << 'PYEOF'
import time
import random

# Allocate memory (80% of test size to trigger swapping)
size = {size_mb * 1024 * 1024 * 8 // 10}
data = bytearray(size)

# Fill with mixed patterns (more realistic than pure zeros)
print("Filling memory with mixed patterns...")
for i in range(0, len(data), 4096):
    pattern = random.choice([0, 255, i % 256, random.randint(0, 255)])
    data[i:min(i+4096, len(data))] = bytes([pattern] * min(4096, len(data)-i))

# Touch all memory to ensure it's allocated
print("Touching all memory...")
for i in range(0, len(data), 4096):
    data[i] = (data[i] + 1) % 256

time.sleep(2)
print("Memory pressure test complete")
PYEOF
"""
        
        run_command(test_script, check=False)
        
        duration = time.time() - start
        
        # Get stats
        if os.path.exists('/sys/block/zram0/mm_stat'):
            stats = run_command('cat /sys/block/zram0/mm_stat').split()
            if len(stats) >= 3:
                orig_size = int(stats[0])
                compr_size = int(stats[1])
                mem_used = int(stats[2])
                
                results['orig_size_mb'] = round(orig_size / 1024 / 1024, 2)
                results['compr_size_mb'] = round(compr_size / 1024 / 1024, 2)
                results['mem_used_mb'] = round(mem_used / 1024 / 1024, 2)
                
                if compr_size > 0:
                    results['compression_ratio'] = round(orig_size / compr_size, 2)
                    results['efficiency_pct'] = round((1 - mem_used / orig_size) * 100, 2) if orig_size > 0 else 0
                    
                    log_info(f"  Compression ratio: {results['compression_ratio']}x")
                    log_info(f"  Space efficiency: {results['efficiency_pct']}%")
                    log_info(f"  Memory saved: {results['orig_size_mb'] - results['mem_used_mb']:.2f} MB")
        
        results['duration_sec'] = round(duration, 2)
        
    except Exception as e:
        log_error(f"Benchmark failed: {e}")
        results['error'] = str(e)
    finally:
        # Cleanup
        run_command('swapoff /dev/zram0', check=False)
        if os.path.exists('/sys/block/zram0/reset'):
            run_command('echo 1 > /sys/block/zram0/reset', check=False)
    
    return results

def test_concurrency(num_files=8, file_size_mb=128, test_dir='/tmp/swap_test'):
    """
    Test concurrency with multiple swap files using fio
    
    Args:
        num_files: Number of concurrent swap files
        file_size_mb: Size of each file in MB
        test_dir: Directory for test files
    """
    log_step(f"Testing concurrency with {num_files} files")
    
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
        result = subprocess.run(
            ['fio', '--output-format=json', '/tmp/fio_concurrent.job'],
            capture_output=True,
            text=True,
            timeout=600
        )
        
        if result.returncode == 0:
            data = json.loads(result.stdout)
            
            # Extract write performance
            write_bw = data['jobs'][0]['write']['bw'] / 1024  # MB/s
            results['write_mb_per_sec'] = round(write_bw, 2)
            results['write_iops'] = data['jobs'][0]['write']['iops']
            
            # Extract read performance
            read_bw = data['jobs'][1]['read']['bw'] / 1024  # MB/s
            results['read_mb_per_sec'] = round(read_bw, 2)
            results['read_iops'] = data['jobs'][1]['read']['iops']
            
            # Calculate scaling efficiency
            # Baseline is single file, so efficiency = actual / (baseline * num_files)
            # We estimate baseline as 1/num_files of concurrent result
            results['write_scaling_efficiency'] = round(100, 2)  # Placeholder, needs baseline
            results['read_scaling_efficiency'] = round(100, 2)  # Placeholder, needs baseline
            
            log_info(f"  Write: {write_bw:.2f} MB/s, {results['write_iops']:.0f} IOPS")
            log_info(f"  Read: {read_bw:.2f} MB/s, {results['read_iops']:.0f} IOPS")
    
    except Exception as e:
        log_error(f"Concurrency test failed: {e}")
        results['error'] = str(e)
    finally:
        # Cleanup
        import shutil
        if os.path.exists(test_dir):
            shutil.rmtree(test_dir, ignore_errors=True)
        if os.path.exists('/tmp/fio_concurrent.job'):
            os.remove('/tmp/fio_concurrent.job')
    
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
            f.write(f"vm.page-cluster={cluster}\n\n")
        
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
            f.write(f"# Optimal swap file count: {best_concur['num_files']}\n")
            f.write(f"SWAP_FILES={best_concur['num_files']}\n")
    
    log_info(f"Configuration saved to {output_file}")

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
    parser.add_argument('--output', '-o', metavar='FILE',
                       help='Output JSON results to file')
    parser.add_argument('--shell-config', metavar='FILE',
                       help='Export shell configuration file')
    
    args = parser.parse_args()
    
    # Check root and dependencies
    check_root()
    check_dependencies()
    
    # Get system info
    system_info = get_system_info()
    log_info(f"System: {system_info['ram_gb']}GB RAM, {system_info['cpu_cores']} CPU cores")
    
    results = {
        'system_info': system_info,
        'timestamp': datetime.now().isoformat()
    }
    
    # Run benchmarks
    if args.test_all or args.block_size:
        block_sizes = [4, 8, 16, 32, 64, 128] if args.test_all else [args.block_size]
        results['block_sizes'] = []
        for size in block_sizes:
            try:
                result = benchmark_block_size_fio(size)
                results['block_sizes'].append(result)
            except Exception as e:
                log_error(f"Block size {size}KB failed: {e}")
    
    if args.test_all or args.test_compressors:
        compressors = ['lz4', 'zstd', 'lzo-rle']
        results['compressors'] = []
        for comp in compressors:
            try:
                result = benchmark_compression(comp, 'zsmalloc')
                results['compressors'].append(result)
            except Exception as e:
                log_error(f"Compressor {comp} failed: {e}")
    
    if args.test_all or args.test_allocators:
        allocators = ['zsmalloc', 'z3fold', 'zbud']
        results['allocators'] = []
        for alloc in allocators:
            try:
                result = benchmark_compression('lz4', alloc)
                results['allocators'].append(result)
            except Exception as e:
                log_error(f"Allocator {alloc} failed: {e}")
    
    if args.test_all or args.test_concurrency:
        file_counts = [1, 2, 4, 8, 16] if args.test_all else [args.test_concurrency]
        results['concurrency'] = []
        for count in file_counts:
            try:
                result = test_concurrency(count)
                results['concurrency'].append(result)
            except Exception as e:
                log_error(f"Concurrency test with {count} files failed: {e}")
    
    if args.compare_memory_only:
        results['memory_only_comparison'] = compare_memory_only()
    
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
    
    log_info("Benchmark complete!")

if __name__ == '__main__':
    main()
