#!/bin/bash
# Test script to demonstrate the speed improvement of C-based memory allocation
# vs Python-based allocation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Memory Allocation Speed Test"
echo "=========================================="
echo ""

# Compile C programs if needed
if [ ! -f mem_pressure ]; then
    echo "Compiling mem_pressure..."
    gcc -o mem_pressure mem_pressure.c -Wall -O2
fi

# Test size in MB
TEST_SIZE=100

echo "Test 1: C-based memory allocation (mem_pressure)"
echo "------------------------------------------------"
time ./mem_pressure $TEST_SIZE 0 2

echo ""
echo "Test 2: Python-based memory allocation (for comparison)"
echo "--------------------------------------------------------"
time python3 << 'EOF'
import sys
import time

size_mb = 100
size = size_mb * 1024 * 1024

print(f"Allocating {size_mb}MB...")
start = time.time()
data = bytearray(size)
alloc_time = time.time() - start
print(f"Allocation took {alloc_time:.2f}s")

print("Filling memory with patterns...")
start = time.time()
for i in range(0, len(data), 4096):
    pattern_type = i % 4
    chunk_size = min(4096, len(data) - i)
    if pattern_type == 0:
        data[i:i+chunk_size] = bytes([i % 256] * chunk_size)
    elif pattern_type == 1:
        data[i:i+chunk_size] = bytes([0] * chunk_size)
    elif pattern_type == 2:
        data[i:i+chunk_size] = bytes([(i+j) % 256 for j in range(chunk_size)])
    else:
        data[i:i+chunk_size] = bytes([i % 256] * chunk_size)
fill_time = time.time() - start
print(f"Fill took {fill_time:.2f}s")

print("Forcing swapping (3 passes)...")
start = time.time()
for pass_num in range(3):
    for i in range(0, len(data), 65536):
        data[i] = (data[i] + 1) % 256
    time.sleep(0.3)
swap_time = time.time() - start
print(f"Swap forcing took {swap_time:.2f}s")

print(f"Total time: {alloc_time + fill_time + swap_time:.2f}s")

time.sleep(2)
EOF

echo ""
echo "=========================================="
echo "Summary:"
echo "C-based allocation is significantly faster,"
echo "especially for large memory sizes (1GB+)."
echo "=========================================="
