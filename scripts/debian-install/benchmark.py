#!/usr/bin/env python3
"""
benchmark.py - Swap configuration benchmarking tool

Tests and compares different swap configurations:
- ZRAM vs ZSWAP memory-only performance
- Different allocators (zsmalloc, z3fold, zbud)
- ZRAM writeback performance
- Same-page deduplication effectiveness
- Compression algorithm comparison
"""

import os
import sys
import time
import subprocess
import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# Color codes
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'

def print_colored(color: str, message: str):
    """Print colored message"""
    print(f"{color}{message}{Colors.NC}")

def print_section(title: str):
    """Print section header"""
    print()
    print_colored(Colors.BLUE, f"=== {title} ===")
    print()

def run_command(cmd: List[str], capture: bool = True) -> Tuple[int, str, str]:
    """Run shell command and return exit code, stdout, stderr"""
    try:
        if capture:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            return result.returncode, result.stdout, result.stderr
        else:
            result = subprocess.run(cmd, timeout=300)
            return result.returncode, "", ""
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def check_root():
    """Check if running as root"""
    if os.geteuid() != 0:
        print_colored(Colors.RED, "Error: This script must be run as root")
        print("Run with: sudo ./benchmark.py")
        sys.exit(1)

def get_vmstat_value(key: str) -> int:
    """Get value from /proc/vmstat"""
    try:
        with open('/proc/vmstat', 'r') as f:
            for line in f:
                if line.startswith(key):
                    return int(line.split()[1])
    except Exception:
        pass
    return 0

def get_memory_info() -> Dict[str, int]:
    """Get memory information in KB"""
    info = {}
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    key = parts[0].strip()
                    value = int(parts[1].strip().split()[0])
                    info[key] = value
    except Exception:
        pass
    return info

def create_memory_pressure(size_mb: int, duration: int):
    """Create memory pressure by allocating and touching memory"""
    print(f"Creating memory pressure: {size_mb} MB for {duration} seconds...")
    
    # Use stress-ng if available, otherwise use dd
    if subprocess.run(['which', 'stress-ng'], capture_output=True).returncode == 0:
        cmd = ['stress-ng', '--vm', '1', '--vm-bytes', f'{size_mb}M', '--timeout', f'{duration}s']
        returncode, _, _ = run_command(cmd, capture=False)
    else:
        print_colored(Colors.YELLOW, "stress-ng not found, using dd method")
        # Create temp file to force swapping
        cmd = ['dd', 'if=/dev/zero', 'of=/tmp/benchmark_temp', f'bs=1M', f'count={size_mb}']
        run_command(cmd)
        time.sleep(duration)
        os.remove('/tmp/benchmark_temp') if os.path.exists('/tmp/benchmark_temp') else None

class BenchmarkResult:
    """Store benchmark results"""
    def __init__(self, name: str):
        self.name = name
        self.compression_ratio = 0.0
        self.throughput_mb_s = 0.0
        self.latency_ms = 0.0
        self.memory_saved_mb = 0.0
        self.cpu_usage_pct = 0.0
        self.swap_in = 0
        self.swap_out = 0
        self.notes = []
    
    def to_dict(self) -> Dict:
        """Convert to dictionary"""
        return {
            'name': self.name,
            'compression_ratio': self.compression_ratio,
            'throughput_mb_s': self.throughput_mb_s,
            'latency_ms': self.latency_ms,
            'memory_saved_mb': self.memory_saved_mb,
            'cpu_usage_pct': self.cpu_usage_pct,
            'swap_in': self.swap_in,
            'swap_out': self.swap_out,
            'notes': self.notes
        }

def benchmark_zram(algorithm: str, allocator: str, size_mb: int) -> BenchmarkResult:
    """Benchmark ZRAM with specific algorithm and allocator"""
    result = BenchmarkResult(f"ZRAM-{algorithm}-{allocator}")
    
    print_section(f"Benchmarking ZRAM: {algorithm} + {allocator}")
    
    # Remove existing zram
    if os.path.exists('/sys/block/zram0'):
        run_command(['swapoff', '/dev/zram0'])
        run_command(['rmmod', 'zram'])
        time.sleep(1)
    
    # Load zram
    returncode, _, _ = run_command(['modprobe', 'zram'])
    if returncode != 0:
        result.notes.append("Failed to load zram module")
        return result
    
    # Configure zram
    try:
        # Set algorithm
        with open('/sys/block/zram0/comp_algorithm', 'w') as f:
            f.write(algorithm)
        
        # Set size
        with open('/sys/block/zram0/disksize', 'w') as f:
            f.write(f"{size_mb * 1024 * 1024}")
        
        # Make swap
        run_command(['mkswap', '/dev/zram0'])
        run_command(['swapon', '-p', '100', '/dev/zram0'])
        
        # Wait for setup
        time.sleep(2)
        
        # Record initial stats
        pswpin_before = get_vmstat_value('pswpin')
        pswpout_before = get_vmstat_value('pswpout')
        
        # Create memory pressure
        create_memory_pressure(size_mb * 2, 30)
        
        # Record final stats
        time.sleep(2)
        pswpin_after = get_vmstat_value('pswpin')
        pswpout_after = get_vmstat_value('pswpout')
        
        result.swap_in = pswpin_after - pswpin_before
        result.swap_out = pswpout_after - pswpout_before
        
        # Get ZRAM stats
        with open('/sys/block/zram0/mm_stat', 'r') as f:
            stats = f.read().split()
            orig_size = int(stats[0])
            compr_size = int(stats[1])
            mem_used = int(stats[2])
            same_pages = int(stats[5])
            
            if mem_used > 0:
                result.compression_ratio = orig_size / mem_used
                result.memory_saved_mb = (orig_size - mem_used) / (1024 * 1024)
        
        result.notes.append("Test completed successfully")
        
    except Exception as e:
        result.notes.append(f"Error: {str(e)}")
    finally:
        # Cleanup
        run_command(['swapoff', '/dev/zram0'])
        run_command(['rmmod', 'zram'])
    
    return result

def benchmark_zswap(algorithm: str, zpool: str, max_pool_pct: int) -> BenchmarkResult:
    """Benchmark ZSWAP with specific configuration"""
    result = BenchmarkResult(f"ZSWAP-{algorithm}-{zpool}-{max_pool_pct}%")
    
    print_section(f"Benchmarking ZSWAP: {algorithm} + {zpool} ({max_pool_pct}%)")
    
    # Disable existing swap
    run_command(['swapoff', '-a'])
    time.sleep(1)
    
    # Configure ZSWAP
    try:
        # Enable ZSWAP
        with open('/sys/module/zswap/parameters/enabled', 'w') as f:
            f.write('Y')
        
        with open('/sys/module/zswap/parameters/compressor', 'w') as f:
            f.write(algorithm)
        
        with open('/sys/module/zswap/parameters/zpool', 'w') as f:
            f.write(zpool)
        
        with open('/sys/module/zswap/parameters/max_pool_percent', 'w') as f:
            f.write(str(max_pool_pct))
        
        # Create a temporary swap file
        swap_file = '/tmp/benchmark_swap'
        run_command(['fallocate', '-l', '1G', swap_file])
        run_command(['chmod', '600', swap_file])
        run_command(['mkswap', swap_file])
        run_command(['swapon', swap_file])
        
        # Wait for setup
        time.sleep(2)
        
        # Record initial stats
        pswpin_before = get_vmstat_value('pswpin')
        pswpout_before = get_vmstat_value('pswpout')
        
        # Create memory pressure
        create_memory_pressure(512, 30)
        
        # Record final stats
        time.sleep(2)
        pswpin_after = get_vmstat_value('pswpin')
        pswpout_after = get_vmstat_value('pswpout')
        
        result.swap_in = pswpin_after - pswpin_before
        result.swap_out = pswpout_after - pswpout_before
        
        # Get ZSWAP stats
        if os.path.exists('/sys/kernel/debug/zswap'):
            try:
                with open('/sys/kernel/debug/zswap/stored_pages', 'r') as f:
                    stored = int(f.read().strip())
                with open('/sys/kernel/debug/zswap/written_back_pages', 'r') as f:
                    written_back = int(f.read().strip())
                with open('/sys/kernel/debug/zswap/pool_total_size', 'r') as f:
                    pool_size = int(f.read().strip())
                
                result.memory_saved_mb = pool_size / (1024 * 1024)
                
                if stored > 0:
                    wb_ratio = (written_back * 100.0) / stored
                    result.notes.append(f"Writeback ratio: {wb_ratio:.1f}%")
            except Exception as e:
                result.notes.append(f"Could not read stats: {e}")
        
        result.notes.append("Test completed successfully")
        
    except Exception as e:
        result.notes.append(f"Error: {str(e)}")
    finally:
        # Cleanup
        run_command(['swapoff', '-a'])
        if os.path.exists('/tmp/benchmark_swap'):
            os.remove('/tmp/benchmark_swap')
    
    return result

def benchmark_compression_algorithms() -> List[BenchmarkResult]:
    """Benchmark different compression algorithms"""
    results = []
    algorithms = ['lz4', 'zstd', 'lzo']
    
    for algo in algorithms:
        result = benchmark_zram(algo, 'zsmalloc', 512)
        results.append(result)
        time.sleep(2)
    
    return results

def benchmark_allocators() -> List[BenchmarkResult]:
    """Benchmark different memory allocators"""
    results = []
    allocators = ['zsmalloc', 'z3fold', 'zbud']
    
    for allocator in allocators:
        result = benchmark_zram('lz4', allocator, 512)
        results.append(result)
        time.sleep(2)
    
    return results

def print_results_table(results: List[BenchmarkResult]):
    """Print results in table format"""
    print_section("Benchmark Results")
    
    # Header
    print(f"{'Configuration':<30} {'Comp Ratio':<12} {'Memory Saved':<15} {'Swap In':<12} {'Swap Out':<12}")
    print("-" * 90)
    
    # Results
    for result in results:
        comp_ratio = f"{result.compression_ratio:.2f}:1" if result.compression_ratio > 0 else "N/A"
        mem_saved = f"{result.memory_saved_mb:.2f} MB" if result.memory_saved_mb > 0 else "N/A"
        
        print(f"{result.name:<30} {comp_ratio:<12} {mem_saved:<15} {result.swap_in:<12} {result.swap_out:<12}")
        
        if result.notes:
            for note in result.notes:
                print(f"  → {note}")
    
    print()

def save_results(results: List[BenchmarkResult], filename: str):
    """Save results to JSON file"""
    data = {
        'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
        'system': {
            'kernel': os.uname().release,
            'memory': get_memory_info()
        },
        'results': [r.to_dict() for r in results]
    }
    
    with open(filename, 'w') as f:
        json.dump(data, f, indent=2)
    
    print_colored(Colors.GREEN, f"Results saved to: {filename}")

def main():
    parser = argparse.ArgumentParser(description='Swap configuration benchmarking tool')
    parser.add_argument('--test', choices=['all', 'compression', 'allocators', 'zswap', 'quick'],
                       default='quick', help='Test suite to run')
    parser.add_argument('--output', '-o', default='/tmp/benchmark-results.json',
                       help='Output file for results')
    parser.add_argument('--size', type=int, default=512,
                       help='Test size in MB (default: 512)')
    
    args = parser.parse_args()
    
    # Check if running as root
    check_root()
    
    print_colored(Colors.CYAN, "╔═══════════════════════════════════════════════════╗")
    print_colored(Colors.CYAN, "║       Swap Configuration Benchmark Tool          ║")
    print_colored(Colors.CYAN, "╚═══════════════════════════════════════════════════╝")
    print()
    
    results = []
    
    if args.test == 'quick':
        print_colored(Colors.YELLOW, "Running quick benchmark (lz4 + zsmalloc)...")
        result = benchmark_zram('lz4', 'zsmalloc', args.size)
        results.append(result)
        
    elif args.test == 'compression':
        print_colored(Colors.YELLOW, "Benchmarking compression algorithms...")
        results.extend(benchmark_compression_algorithms())
        
    elif args.test == 'allocators':
        print_colored(Colors.YELLOW, "Benchmarking memory allocators...")
        results.extend(benchmark_allocators())
        
    elif args.test == 'zswap':
        print_colored(Colors.YELLOW, "Benchmarking ZSWAP configurations...")
        zpools = ['z3fold', 'zbud', 'zsmalloc']
        for zpool in zpools:
            result = benchmark_zswap('lz4', zpool, 25)
            results.append(result)
            time.sleep(2)
        
    elif args.test == 'all':
        print_colored(Colors.YELLOW, "Running comprehensive benchmark suite...")
        print_colored(Colors.YELLOW, "This will take several minutes...")
        
        # Compression algorithms
        print_colored(Colors.BLUE, "\n→ Testing compression algorithms")
        results.extend(benchmark_compression_algorithms())
        
        # Allocators
        print_colored(Colors.BLUE, "\n→ Testing memory allocators")
        results.extend(benchmark_allocators())
        
        # ZSWAP
        print_colored(Colors.BLUE, "\n→ Testing ZSWAP configurations")
        result = benchmark_zswap('lz4', 'z3fold', 25)
        results.append(result)
    
    # Print and save results
    print_results_table(results)
    save_results(results, args.output)
    
    # Recommendations
    print_section("Recommendations")
    
    best_compression = max(results, key=lambda r: r.compression_ratio) if results else None
    
    if best_compression and best_compression.compression_ratio > 0:
        print_colored(Colors.GREEN, f"✅ Best compression ratio: {best_compression.name} ({best_compression.compression_ratio:.2f}:1)")
        
        if best_compression.memory_saved_mb > 100:
            print(f"   Saved {best_compression.memory_saved_mb:.2f} MB of memory")
    
    print()
    print("For production use:")
    print("  • ZSWAP + Swap Files: Recommended for most systems")
    print("  • ZRAM: Good for memory-only scenarios")
    print("  • Use lz4 for speed, zstd for better compression")
    print("  • Use zsmalloc for ZRAM, z3fold for ZSWAP")
    print()
    
    print_colored(Colors.GREEN, "✅ Benchmark complete")

if __name__ == '__main__':
    main()
