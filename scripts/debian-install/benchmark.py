#!/usr/bin/env python3
"""
Swap Performance Benchmark Script
Tests different configurations for optimal performance
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

def benchmark_block_size(size_kb, duration=10):
    """
    Benchmark I/O performance with specific block size
    size_kb should match vm.page-cluster values
    """
    log_step(f"Benchmarking block size: {size_kb}KB")
    
    results = {
        'block_size_kb': size_kb,
        'duration_sec': duration,
        'timestamp': datetime.now().isoformat()
    }
    
    # Create test file
    test_file = '/tmp/benchmark_swap_test'
    test_size_mb = 512  # 512MB test file
    
    try:
        # Write test
        log_info(f"Write test ({size_kb}KB blocks)...")
        start = time.time()
        run_command(f'dd if=/dev/zero of={test_file} bs={size_kb}k count={test_size_mb * 1024 // size_kb} conv=fdatasync 2>&1')
        write_time = time.time() - start
        write_speed = test_size_mb / write_time
        results['write_mb_per_sec'] = round(write_speed, 2)
        
        # Read test
        log_info(f"Read test ({size_kb}KB blocks)...")
        # Clear cache
        run_command('sync && echo 3 > /proc/sys/vm/drop_caches')
        
        start = time.time()
        run_command(f'dd if={test_file} of=/dev/null bs={size_kb}k 2>&1')
        read_time = time.time() - start
        read_speed = test_size_mb / read_time
        results['read_mb_per_sec'] = round(read_speed, 2)
        
        log_info(f"  Write: {write_speed:.2f} MB/s")
        log_info(f"  Read: {read_speed:.2f} MB/s")
        
    finally:
        # Cleanup
        if os.path.exists(test_file):
            os.remove(test_file)
    
    return results

def benchmark_compression(compressor, allocator='zsmalloc', size_mb=100):
    """Benchmark compression algorithm and allocator"""
    log_step(f"Benchmarking {compressor} with {allocator}")
    
    results = {
        'compressor': compressor,
        'allocator': allocator,
        'test_size_mb': size_mb,
        'timestamp': datetime.now().isoformat()
    }
    
    try:
        # Setup ZRAM
        run_command('modprobe zram', check=False)
        
        # Configure
        if os.path.exists('/sys/block/zram0/comp_algorithm'):
            run_command(f'echo {compressor} > /sys/block/zram0/comp_algorithm', check=False)
        
        # Set size
        size_bytes = size_mb * 1024 * 1024
        run_command(f'echo {size_bytes} > /sys/block/zram0/disksize')
        
        # Make swap
        run_command('mkswap /dev/zram0')
        run_command('swapon -p 100 /dev/zram0')
        
        # Measure initial state
        start = time.time()
        
        # Generate memory pressure (allocate and touch memory)
        test_script = f"""
python3 -c "
import time
data = bytearray({size_mb * 1024 * 1024})
# Touch all memory
for i in range(0, len(data), 4096):
    data[i] = i % 256
time.sleep(2)
"
"""
        run_command(test_script)
        
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
                results['compression_ratio'] = round(orig_size / compr_size, 2) if compr_size > 0 else 0
                results['efficiency_pct'] = round((1 - mem_used / orig_size) * 100, 2) if orig_size > 0 else 0
        
        results['duration_sec'] = round(duration, 2)
        
        log_info(f"  Compression ratio: {results.get('compression_ratio', 0)}x")
        log_info(f"  Space efficiency: {results.get('efficiency_pct', 0)}%")
        
    except Exception as e:
        log_error(f"Benchmark failed: {e}")
        results['error'] = str(e)
    finally:
        # Cleanup
        run_command('swapoff /dev/zram0', check=False)
        run_command('rmmod zram', check=False)
    
    return results

def compare_memory_only():
    """Compare ZRAM vs ZSWAP in memory-only mode"""
    log_step("Comparing ZRAM vs ZSWAP (memory-only)")
    
    results = {
        'timestamp': datetime.now().isoformat(),
        'zram': {},
        'zswap': {}
    }
    
    # Test ZRAM
    log_info("Testing ZRAM memory-only...")
    results['zram'] = benchmark_compression('lz4', 'zsmalloc', 100)
    
    # Test ZSWAP (conceptually - requires actual swap backing)
    log_info("ZSWAP requires backing device - skipping direct comparison")
    log_info("Use setup-swap.sh with arch 1 (ZRAM) vs arch 3 (ZSWAP) for real comparison")
    
    return results

def test_concurrency(num_files=8):
    """Test swap performance with multiple concurrent files"""
    log_step(f"Testing concurrency with {num_files} swap files")
    
    results = {
        'num_files': num_files,
        'timestamp': datetime.now().isoformat()
    }
    
    # This would require actual swap setup
    # Placeholder for concept
    log_info(f"Concurrency testing requires full swap setup")
    log_info(f"Use setup-swap.sh with SWAP_FILES={num_files}")
    
    return results

def export_shell_config(results, output_file):
    """Export results as shell configuration"""
    log_step(f"Exporting configuration to {output_file}")
    
    with open(output_file, 'w') as f:
        f.write("# Swap Configuration from Benchmark\n")
        f.write(f"# Generated: {datetime.now().isoformat()}\n\n")
        
        # Find best block size
        if 'block_sizes' in results:
            best_block = max(results['block_sizes'], key=lambda x: x.get('read_mb_per_sec', 0))
            # Map block size to page-cluster
            block_to_cluster = {4: 0, 8: 1, 16: 2, 32: 3, 64: 4, 128: 5}
            cluster = block_to_cluster.get(best_block['block_size_kb'], 3)
            f.write(f"# Best block size: {best_block['block_size_kb']}KB\n")
            f.write(f"vm.page-cluster={cluster}\n\n")
        
        # Find best compressor
        if 'compressors' in results:
            best_comp = max(results['compressors'], key=lambda x: x.get('compression_ratio', 0))
            f.write(f"# Best compressor: {best_comp['compressor']}\n")
            f.write(f"ZSWAP_COMPRESSOR={best_comp['compressor']}\n")
            f.write(f"ZRAM_COMPRESSOR={best_comp['compressor']}\n\n")
    
    log_info(f"Configuration saved to {output_file}")

def main():
    parser = argparse.ArgumentParser(
        description='Benchmark swap configurations',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --test-all
  %(prog)s --block-size 64
  %(prog)s --test-compressors
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
                       help='Compare ZRAM vs ZSWAP memory-only')
    parser.add_argument('--test-concurrency', type=int, metavar='N',
                       help='Test concurrency with N swap files')
    parser.add_argument('--output', '-o', metavar='FILE',
                       help='Output JSON results to file')
    parser.add_argument('--shell-config', metavar='FILE',
                       help='Export shell configuration file')
    
    args = parser.parse_args()
    
    # Check root
    check_root()
    
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
                result = benchmark_block_size(size)
                results['block_sizes'].append(result)
            except Exception as e:
                log_error(f"Block size {size}KB failed: {e}")
    
    if args.test_all or args.test_compressors:
        compressors = ['lz4', 'zstd', 'lzo-rle']
        results['compressors'] = []
        for comp in compressors:
            try:
                result = benchmark_compression(comp)
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
    
    if args.compare_memory_only:
        results['memory_only_comparison'] = compare_memory_only()
    
    if args.test_concurrency:
        results['concurrency'] = test_concurrency(args.test_concurrency)
    
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
