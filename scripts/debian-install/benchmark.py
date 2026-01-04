#!/usr/bin/env python3
"""
benchmark.py - Comprehensive Swap Performance Benchmarking

Tests different swap configurations, allocators, compressors, and concurrency.
"""

import argparse
import os
import subprocess
import sys
import time
import tempfile
import multiprocessing
from pathlib import Path
from typing import List, Dict, Tuple

# Test configuration
MEMORY_SIZE_MB = 100  # Size per test process
ITERATIONS = 5
ZRAM_DEVICE = "/dev/zram0"


class Colors:
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    RED = '\033[0;31m'
    NC = '\033[0m'


def log_info(msg: str):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")


def log_warn(msg: str):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")


def log_error(msg: str):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")


def log_section(msg: str):
    print(f"\n{Colors.BLUE}{'='*70}{Colors.NC}")
    print(f"{Colors.BLUE}{msg}{Colors.NC}")
    print(f"{Colors.BLUE}{'='*70}{Colors.NC}\n")


def check_root():
    """Check if running as root"""
    if os.geteuid() != 0:
        log_error("This script must be run as root")
        sys.exit(1)


def run_command(cmd: List[str], check=True) -> Tuple[int, str, str]:
    """Run command and return (returncode, stdout, stderr)"""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=check
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.CalledProcessError as e:
        return e.returncode, e.stdout, e.stderr


def reset_zram():
    """Reset ZRAM device"""
    run_command(["swapoff", ZRAM_DEVICE], check=False)
    if Path("/sys/block/zram0/reset").exists():
        Path("/sys/block/zram0/reset").write_text("1")
    time.sleep(1)


def setup_zram(size_mb: int, algorithm: str = "lzo", allocator: str = None):
    """Setup ZRAM with specified parameters"""
    reset_zram()
    
    # Load module if needed
    run_command(["modprobe", "zram"], check=False)
    
    # Set algorithm
    algo_path = Path("/sys/block/zram0/comp_algorithm")
    if algo_path.exists():
        available = algo_path.read_text().strip()
        if algorithm in available:
            algo_path.write_text(algorithm)
        else:
            log_warn(f"Algorithm {algorithm} not available, using default")
    
    # Set size
    Path("/sys/block/zram0/disksize").write_text(f"{size_mb}M")
    
    # Initialize swap
    run_command(["mkswap", ZRAM_DEVICE], check=False)
    run_command(["swapon", ZRAM_DEVICE, "-p", "100"])
    
    log_info(f"ZRAM configured: {size_mb}MB, algorithm={algorithm}")


def setup_zswap(enabled: bool = True, compressor: str = "lzo", zpool: str = "zbud"):
    """Configure ZSWAP"""
    zswap_base = Path("/sys/module/zswap/parameters")
    
    if not zswap_base.exists():
        log_error("ZSWAP not available in kernel")
        return False
    
    # Enable/disable
    (zswap_base / "enabled").write_text("1" if enabled else "0")
    
    if enabled:
        # Set compressor
        comp_path = zswap_base / "compressor"
        if comp_path.exists():
            available = comp_path.read_text().strip()
            if compressor in available:
                comp_path.write_text(compressor)
        
        # Set zpool
        zpool_path = zswap_base / "zpool"
        if zpool_path.exists():
            available = zpool_path.read_text().strip()
            if zpool in available:
                zpool_path.write_text(zpool)
        
        # Set pool size
        (zswap_base / "max_pool_percent").write_text("20")
        
        log_info(f"ZSWAP enabled: compressor={compressor}, zpool={zpool}")
    
    return True


def create_swap_file(path: str, size_mb: int):
    """Create and activate swap file"""
    # Remove if exists
    if Path(path).exists():
        run_command(["swapoff", path], check=False)
        Path(path).unlink()
    
    # Create file
    run_command(["dd", "if=/dev/zero", f"of={path}", "bs=1M", f"count={size_mb}"], check=False)
    os.chmod(path, 0o600)
    
    # Make swap
    run_command(["mkswap", path], check=False)
    run_command(["swapon", path, "-p", "10"])
    
    log_info(f"Swap file created: {path} ({size_mb}MB)")


def memory_stress_test(size_mb: int, pattern: str = "random") -> float:
    """
    Stress test memory allocation
    Returns time taken in seconds
    """
    start_time = time.time()
    
    # Allocate and fill memory
    size_bytes = size_mb * 1024 * 1024
    chunk_size = 4096  # 4KB chunks
    
    data = bytearray()
    
    if pattern == "random":
        # Random data (incompressible)
        for _ in range(0, size_bytes, chunk_size):
            data.extend(os.urandom(min(chunk_size, size_bytes - len(data))))
    elif pattern == "zeros":
        # Zero-filled (highly compressible)
        data = bytearray(size_bytes)
    elif pattern == "mixed":
        # 50% zeros, 50% random
        half = size_bytes // 2
        data.extend(bytearray(half))
        for _ in range(0, half, chunk_size):
            data.extend(os.urandom(min(chunk_size, half - (len(data) - half))))
    
    # Keep data in memory briefly
    _ = len(data)
    
    elapsed = time.time() - start_time
    return elapsed


def run_parallel_stress(num_processes: int, size_mb_per_process: int) -> float:
    """Run memory stress test in parallel"""
    log_info(f"Running {num_processes} parallel processes, {size_mb_per_process}MB each")
    
    start_time = time.time()
    
    with multiprocessing.Pool(processes=num_processes) as pool:
        results = [
            pool.apply_async(memory_stress_test, (size_mb_per_process, "random"))
            for _ in range(num_processes)
        ]
        
        # Wait for all to complete
        for r in results:
            r.get()
    
    elapsed = time.time() - start_time
    return elapsed


def get_zram_stats() -> Dict[str, int]:
    """Get ZRAM statistics"""
    stats = {}
    
    mm_stat_path = Path("/sys/block/zram0/mm_stat")
    if mm_stat_path.exists():
        values = mm_stat_path.read_text().split()
        if len(values) >= 7:
            stats["orig_data_size"] = int(values[0])
            stats["compr_data_size"] = int(values[1])
            stats["mem_used_total"] = int(values[2])
            stats["same_pages"] = int(values[5])
            
            # Calculate compression ratio
            if stats["compr_data_size"] > 0:
                stats["compression_ratio"] = stats["orig_data_size"] / stats["compr_data_size"]
            else:
                stats["compression_ratio"] = 0
    
    return stats


def test_zram_vs_zswap():
    """Test ZRAM vs ZSWAP performance"""
    log_section("Test: ZRAM vs ZSWAP")
    
    results = {}
    
    # Test ZRAM
    log_info("Testing ZRAM...")
    setup_zswap(enabled=False)
    setup_zram(512, "lzo")
    
    time.sleep(2)
    
    zram_time = 0
    for i in range(ITERATIONS):
        log_info(f"ZRAM iteration {i+1}/{ITERATIONS}")
        zram_time += memory_stress_test(MEMORY_SIZE_MB, "random")
    
    zram_stats = get_zram_stats()
    results["zram"] = {
        "time": zram_time / ITERATIONS,
        "stats": zram_stats
    }
    
    reset_zram()
    time.sleep(2)
    
    # Test ZSWAP
    log_info("Testing ZSWAP...")
    setup_zswap(enabled=True, compressor="lzo", zpool="z3fold")
    
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        swap_file = tmp.name
    
    create_swap_file(swap_file, 512)
    
    time.sleep(2)
    
    zswap_time = 0
    for i in range(ITERATIONS):
        log_info(f"ZSWAP iteration {i+1}/{ITERATIONS}")
        zswap_time += memory_stress_test(MEMORY_SIZE_MB, "random")
    
    results["zswap"] = {
        "time": zswap_time / ITERATIONS,
        "stats": {}
    }
    
    # Cleanup
    run_command(["swapoff", swap_file], check=False)
    Path(swap_file).unlink()
    setup_zswap(enabled=False)
    
    # Print results
    print("\nResults:")
    print(f"  ZRAM:  {results['zram']['time']:.2f}s avg")
    print(f"  ZSWAP: {results['zswap']['time']:.2f}s avg")
    
    if zram_stats:
        print(f"\n  ZRAM compression ratio: {zram_stats.get('compression_ratio', 0):.2f}x")


def test_allocators():
    """Test different ZRAM allocators"""
    log_section("Test: ZRAM Allocators")
    
    # Note: zsmalloc is built-in, z3fold and zbud are for ZSWAP
    log_info("ZRAM uses zsmalloc allocator (built-in, ~90% efficiency)")
    log_info("Other allocators (z3fold, zbud) are used by ZSWAP")
    
    # Test with ZRAM
    setup_zram(512, "lzo")
    time.sleep(1)
    
    total_time = 0
    for i in range(ITERATIONS):
        log_info(f"Iteration {i+1}/{ITERATIONS}")
        total_time += memory_stress_test(MEMORY_SIZE_MB, "random")
    
    stats = get_zram_stats()
    
    print("\nResults:")
    print(f"  Time: {total_time / ITERATIONS:.2f}s avg")
    if stats:
        print(f"  Compression: {stats.get('compression_ratio', 0):.2f}x")
        print(f"  Memory efficiency: {stats.get('orig_data_size', 0) / max(stats.get('mem_used_total', 1), 1):.2f}x")
    
    reset_zram()


def test_compressors():
    """Test different compression algorithms"""
    log_section("Test: Compression Algorithms")
    
    # Get available algorithms
    algo_path = Path("/sys/block/zram0/comp_algorithm")
    if not algo_path.exists():
        log_error("Cannot access ZRAM algorithms")
        return
    
    run_command(["modprobe", "zram"], check=False)
    available_algos = algo_path.read_text().strip().replace('[', '').replace(']', '').split()
    
    # Common algorithms to test
    test_algos = ["lzo", "lzo-rle", "lz4", "zstd"]
    test_algos = [a for a in test_algos if a in available_algos]
    
    if not test_algos:
        log_warn("No common algorithms available for testing")
        return
    
    results = {}
    
    for algo in test_algos:
        log_info(f"Testing {algo}...")
        setup_zram(512, algo)
        time.sleep(1)
        
        algo_time = 0
        for i in range(ITERATIONS):
            algo_time += memory_stress_test(MEMORY_SIZE_MB // 2, "random")
        
        stats = get_zram_stats()
        results[algo] = {
            "time": algo_time / ITERATIONS,
            "ratio": stats.get("compression_ratio", 0)
        }
        
        reset_zram()
        time.sleep(1)
    
    # Print results
    print("\nResults:")
    for algo, data in results.items():
        print(f"  {algo:10s}: {data['time']:.2f}s, compression {data['ratio']:.2f}x")


def test_concurrency():
    """Test performance with different concurrency levels"""
    log_section("Test: Concurrency Scaling")
    
    setup_zram(2048, "lzo")
    time.sleep(1)
    
    cpu_count = multiprocessing.cpu_count()
    test_levels = [1, 2, 4, min(8, cpu_count)]
    
    results = {}
    
    for level in test_levels:
        if level > cpu_count:
            continue
        
        log_info(f"Testing with {level} concurrent processes...")
        elapsed = run_parallel_stress(level, MEMORY_SIZE_MB // 2)
        results[level] = elapsed
        
        time.sleep(2)
    
    # Print results
    print("\nResults:")
    for level, elapsed in results.items():
        print(f"  {level} processes: {elapsed:.2f}s")
    
    reset_zram()


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark swap configurations",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument(
        "--test",
        choices=["all", "zram-vs-zswap", "allocators", "compressors", "concurrency"],
        default="all",
        help="Test to run (default: all)"
    )
    
    args = parser.parse_args()
    
    check_root()
    
    log_info("Starting swap benchmarks...")
    log_info(f"Memory per test: {MEMORY_SIZE_MB}MB")
    log_info(f"Iterations: {ITERATIONS}")
    print()
    
    # Run selected tests
    if args.test in ["all", "zram-vs-zswap"]:
        test_zram_vs_zswap()
    
    if args.test in ["all", "allocators"]:
        test_allocators()
    
    if args.test in ["all", "compressors"]:
        test_compressors()
    
    if args.test in ["all", "concurrency"]:
        test_concurrency()
    
    log_section("Benchmarks Complete")


if __name__ == "__main__":
    main()
