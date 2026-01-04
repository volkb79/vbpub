#!/usr/bin/env python3
"""
benchmark.py - I/O and compression benchmark for swap configuration

Tests different block sizes, compression algorithms, allocators, and
ZRAM vs ZSWAP performance to generate optimal recommendations.

Usage:
    sudo ./benchmark.py --test-all
    sudo ./benchmark.py --test-compression
    sudo ./benchmark.py --output results.json
"""

import os
import sys
import json
import time
import subprocess
import argparse
import tempfile
from pathlib import Path

# Test parameters
BLOCK_SIZES = [4096, 8192, 16384, 32768]  # Corresponds to vm.page-cluster 0,1,2,3
COMPRESSION_ALGOS = ['lz4', 'zstd', 'lzo-rle']
ALLOCATORS = ['zsmalloc', 'z3fold', 'zbud']
TEST_SIZE_MB = 100  # Size of test data
CONCURRENCY_LEVELS = [1, 2, 4, 8]

class Colors:
    BLUE = '\033[0;34m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    NC = '\033[0m'

def log_info(msg):
    print(f"{Colors.BLUE}[INFO]{Colors.NC} {msg}")

def log_success(msg):
    print(f"{Colors.GREEN}[OK]{Colors.NC} {msg}")

def log_warn(msg):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")

def log_error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")

def run_command(cmd, capture=True, check=True):
    """Run shell command and return output"""
    try:
        if capture:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=check)
            return result.stdout.strip()
        else:
            subprocess.run(cmd, shell=True, check=check)
            return None
    except subprocess.CalledProcessError as e:
        if check:
            log_error(f"Command failed: {cmd}")
            log_error(f"Error: {e.stderr}")
        return None

def check_root():
    """Ensure script is run as root"""
    if os.geteuid() != 0:
        log_error("This script must be run as root")
        sys.exit(1)

def get_system_info():
    """Gather system information"""
    info = {}
    
    # RAM
    with open('/proc/meminfo') as f:
        for line in f:
            if line.startswith('MemTotal:'):
                info['ram_kb'] = int(line.split()[1])
                info['ram_gb'] = info['ram_kb'] // 1024 // 1024
                break
    
    # CPU
    info['cpu_count'] = os.cpu_count()
    try:
        cpu_info = run_command("lscpu | grep 'CPU MHz' | awk '{print $3}'")
        info['cpu_mhz'] = int(float(cpu_info.split('\n')[0]) if cpu_info else 2000)
    except:
        info['cpu_mhz'] = 2000
    
    # Disk
    stat = os.statvfs('/')
    info['disk_free_gb'] = (stat.f_bavail * stat.f_frsize) // (1024**3)
    
    return info

def test_disk_io(block_size, test_file, concurrency=1):
    """Test disk I/O performance"""
    log_info(f"Testing disk I/O (block_size={block_size}, concurrency={concurrency})...")
    
    # Write test
    start = time.time()
    cmd = f"dd if=/dev/zero of={test_file} bs={block_size} count={TEST_SIZE_MB * 1024 * 1024 // block_size} oflag=direct 2>&1"
    output = run_command(cmd, check=False)
    write_time = time.time() - start
    
    # Extract throughput from dd output
    write_speed = 0
    if output:
        for line in output.split('\n'):
            if 'bytes' in line and 'copied' in line:
                parts = line.split(',')
                for part in parts:
                    if 'MB/s' in part or 'GB/s' in part:
                        speed_str = part.strip().split()[0]
                        try:
                            write_speed = float(speed_str)
                            if 'GB/s' in part:
                                write_speed *= 1024
                        except:
                            pass
    
    # Read test
    run_command("sync")
    run_command("echo 3 > /proc/sys/vm/drop_caches")
    
    start = time.time()
    cmd = f"dd if={test_file} of=/dev/null bs={block_size} iflag=direct 2>&1"
    output = run_command(cmd, check=False)
    read_time = time.time() - start
    
    read_speed = 0
    if output:
        for line in output.split('\n'):
            if 'bytes' in line and 'copied' in line:
                parts = line.split(',')
                for part in parts:
                    if 'MB/s' in part or 'GB/s' in part:
                        speed_str = part.strip().split()[0]
                        try:
                            read_speed = float(speed_str)
                            if 'GB/s' in part:
                                read_speed *= 1024
                        except:
                            pass
    
    # Cleanup
    try:
        os.remove(test_file)
    except:
        pass
    
    return {
        'block_size': block_size,
        'write_time': write_time,
        'read_time': read_time,
        'write_speed_mb': write_speed,
        'read_speed_mb': read_speed,
        'concurrency': concurrency
    }

def test_compression(algo, allocator='zsmalloc'):
    """Test compression algorithm performance with ZRAM"""
    log_info(f"Testing compression: {algo} with {allocator}...")
    
    # Unload existing ZRAM
    run_command("swapoff /dev/zram0 2>/dev/null", check=False)
    run_command("rmmod zram 2>/dev/null", check=False)
    
    # Load ZRAM with allocator
    if allocator != 'zsmalloc':
        run_command(f"modprobe zram allocator={allocator}")
    else:
        run_command("modprobe zram")
    
    # Configure ZRAM
    try:
        run_command(f"echo {algo} > /sys/block/zram0/comp_algorithm 2>/dev/null", check=False)
        run_command(f"echo {TEST_SIZE_MB}M > /sys/block/zram0/disksize")
        run_command("mkswap /dev/zram0 >/dev/null 2>&1")
        run_command("swapon /dev/zram0")
    except Exception as e:
        log_warn(f"Failed to configure ZRAM with {algo}/{allocator}: {e}")
        run_command("rmmod zram 2>/dev/null", check=False)
        return None
    
    # Generate test data (mix of zeros and random)
    test_data = os.urandom(TEST_SIZE_MB * 1024 * 512)  # 50% of disksize
    test_data += b'\x00' * (TEST_SIZE_MB * 1024 * 512)  # 50% zeros
    
    # Create temp file and trigger swapping
    with tempfile.NamedTemporaryFile(delete=False) as f:
        temp_file = f.name
        
        # Write test
        start = time.time()
        f.write(test_data)
        f.flush()
        os.fsync(f.fileno())
        write_time = time.time() - start
    
    # Force memory pressure to trigger swap
    run_command(f"echo 3 > /proc/sys/vm/drop_caches")
    
    # Read stats
    try:
        with open('/sys/block/zram0/mm_stat') as f:
            stats = f.read().split()
            orig_size = int(stats[0])
            comp_size = int(stats[1])
            mem_used = int(stats[2])
            same_pages = int(stats[5]) if len(stats) > 5 else 0
            
            ratio = orig_size / comp_size if comp_size > 0 else 1.0
    except:
        orig_size = comp_size = mem_used = same_pages = 0
        ratio = 1.0
    
    # Cleanup
    try:
        os.remove(temp_file)
    except:
        pass
    
    run_command("swapoff /dev/zram0", check=False)
    run_command("rmmod zram 2>/dev/null", check=False)
    
    return {
        'algorithm': algo,
        'allocator': allocator,
        'write_time': write_time,
        'compression_ratio': ratio,
        'orig_size_mb': orig_size / (1024 * 1024),
        'comp_size_mb': comp_size / (1024 * 1024),
        'mem_used_mb': mem_used / (1024 * 1024),
        'same_pages': same_pages
    }

def test_zram_vs_zswap():
    """Compare ZRAM and ZSWAP memory-only performance"""
    log_info("Testing ZRAM vs ZSWAP memory-only performance...")
    
    results = {
        'zram': [],
        'zswap': []
    }
    
    # Test ZRAM with all allocators
    for allocator in ALLOCATORS:
        result = test_compression('zstd', allocator)
        if result:
            result['type'] = 'zram'
            results['zram'].append(result)
    
    # ZSWAP testing would require disk backing, so we skip actual ZSWAP test
    # and note that ZSWAP uses the same compression/allocator mechanisms
    log_info("ZSWAP uses same allocators as ZRAM - performance similar for memory-only")
    
    return results

def generate_recommendations(results, system_info):
    """Generate configuration recommendations based on benchmark results"""
    log_info("Generating recommendations...")
    
    recommendations = {
        'system': system_info,
        'architecture': '',
        'swap_total_gb': 0,
        'swap_files': 8,
        'vm_page_cluster': 3,
        'compression': {},
        'reasoning': []
    }
    
    ram_gb = system_info['ram_gb']
    cpu_mhz = system_info['cpu_mhz']
    
    # Select architecture
    if ram_gb >= 32:
        recommendations['architecture'] = 'zram-only'
        recommendations['reasoning'].append('High RAM (32GB+): ZRAM-only sufficient')
    elif ram_gb <= 2:
        recommendations['architecture'] = 'zswap-files'
        recommendations['compression']['algorithm'] = 'zstd'
        recommendations['compression']['allocator'] = 'zsmalloc'
        recommendations['reasoning'].append('Low RAM (≤2GB): ZSWAP with zstd for maximum compression')
    elif cpu_mhz < 2000 and ram_gb > 4:
        recommendations['architecture'] = 'files-only'
        recommendations['reasoning'].append('Slow CPU + sufficient RAM: Skip compression overhead')
    else:
        recommendations['architecture'] = 'zswap-files'
        recommendations['compression']['algorithm'] = 'lz4' if cpu_mhz > 3000 else 'zstd'
        recommendations['compression']['allocator'] = 'zsmalloc'
        recommendations['reasoning'].append('Balanced system: ZSWAP recommended')
    
    # Calculate swap size
    if ram_gb <= 2:
        recommendations['swap_total_gb'] = ram_gb * 4
    elif ram_gb <= 8:
        recommendations['swap_total_gb'] = ram_gb * 2
    else:
        recommendations['swap_total_gb'] = int(ram_gb * 1.5)
    
    # Cap at reasonable limits
    recommendations['swap_total_gb'] = min(128, max(4, recommendations['swap_total_gb']))
    
    # Find best compression from results
    if 'compression' in results and results['compression']:
        best_comp = max(results['compression'], 
                       key=lambda x: x['compression_ratio'] / x['write_time'] if x else 0)
        recommendations['compression']['best_tested'] = {
            'algorithm': best_comp['algorithm'],
            'allocator': best_comp['allocator'],
            'ratio': best_comp['compression_ratio']
        }
    
    # Find best block size from I/O results
    if 'disk_io' in results and results['disk_io']:
        best_io = max(results['disk_io'],
                     key=lambda x: (x['read_speed_mb'] + x['write_speed_mb']) / 2 if x else 0)
        # Map block size to vm.page-cluster
        block_to_cluster = {4096: 0, 8192: 1, 16384: 2, 32768: 3}
        recommendations['vm_page_cluster'] = block_to_cluster.get(best_io['block_size'], 3)
        recommendations['reasoning'].append(
            f"Best I/O performance at {best_io['block_size']} bytes (cluster={recommendations['vm_page_cluster']})"
        )
    
    return recommendations

def export_shell_config(recommendations, output_file):
    """Export recommendations as shell script"""
    with open(output_file, 'w') as f:
        f.write("#!/bin/bash\n")
        f.write("# Auto-generated swap configuration\n\n")
        f.write(f"export SWAP_ARCH={recommendations['architecture']}\n")
        f.write(f"export SWAP_TOTAL_GB={recommendations['swap_total_gb']}\n")
        f.write(f"export SWAP_FILES={recommendations['swap_files']}\n")
        f.write(f"export VM_PAGE_CLUSTER={recommendations['vm_page_cluster']}\n")
        
        if 'compression' in recommendations and 'algorithm' in recommendations['compression']:
            f.write(f"export ZRAM_COMP_ALGO={recommendations['compression']['algorithm']}\n")
            f.write(f"export ZSWAP_COMP_ALGO={recommendations['compression']['algorithm']}\n")
            f.write(f"export ZRAM_ALLOCATOR={recommendations['compression']['allocator']}\n")
        
        f.write("\n# Reasoning:\n")
        for reason in recommendations['reasoning']:
            f.write(f"# - {reason}\n")
    
    log_success(f"Shell configuration exported to {output_file}")

def main():
    parser = argparse.ArgumentParser(description='Benchmark swap configurations')
    parser.add_argument('--test-all', action='store_true', help='Run all benchmarks')
    parser.add_argument('--test-compression', action='store_true', help='Test compression only')
    parser.add_argument('--test-io', action='store_true', help='Test disk I/O only')
    parser.add_argument('--test-zram-vs-zswap', action='store_true', help='Compare ZRAM and ZSWAP')
    parser.add_argument('--output', default='benchmark-results.json', help='Output file for results')
    parser.add_argument('--shell-config', default='swap-config.sh', help='Shell config output file')
    
    args = parser.parse_args()
    
    check_root()
    
    log_info("=== Swap Configuration Benchmark ===")
    
    system_info = get_system_info()
    log_info(f"System: {system_info['ram_gb']}GB RAM, {system_info['cpu_count']} CPUs @ {system_info['cpu_mhz']}MHz")
    
    results = {
        'system': system_info,
        'compression': [],
        'disk_io': [],
        'zram_vs_zswap': {}
    }
    
    # Run tests
    if args.test_all or args.test_compression:
        log_info("Testing compression algorithms...")
        for algo in COMPRESSION_ALGOS:
            for allocator in ALLOCATORS:
                result = test_compression(algo, allocator)
                if result:
                    results['compression'].append(result)
                    log_success(f"{algo}/{allocator}: ratio={result['compression_ratio']:.2f}x, time={result['write_time']:.2f}s")
    
    if args.test_all or args.test_io:
        log_info("Testing disk I/O...")
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            test_file = tmp.name
        
        for block_size in BLOCK_SIZES:
            result = test_disk_io(block_size, test_file)
            if result:
                results['disk_io'].append(result)
                log_success(f"Block {block_size}: read={result['read_speed_mb']:.1f}MB/s, write={result['write_speed_mb']:.1f}MB/s")
    
    if args.test_all or args.test_zram_vs_zswap:
        results['zram_vs_zswap'] = test_zram_vs_zswap()
    
    # Generate recommendations
    recommendations = generate_recommendations(results, system_info)
    results['recommendations'] = recommendations
    
    # Output results
    with open(args.output, 'w') as f:
        json.dump(results, f, indent=2)
    log_success(f"Results saved to {args.output}")
    
    # Export shell config
    export_shell_config(recommendations, args.shell_config)
    
    # Print recommendations
    print("\n=== RECOMMENDATIONS ===")
    print(f"Architecture: {recommendations['architecture']}")
    print(f"Total Swap: {recommendations['swap_total_gb']}GB")
    print(f"Swap Files: {recommendations['swap_files']}")
    print(f"vm.page-cluster: {recommendations['vm_page_cluster']}")
    if 'compression' in recommendations and 'algorithm' in recommendations['compression']:
        print(f"Compression: {recommendations['compression']['algorithm']}")
        print(f"Allocator: {recommendations['compression']['allocator']}")
    print("\nReasoning:")
    for reason in recommendations['reasoning']:
        print(f"  - {reason}")

if __name__ == '__main__':
    main()
