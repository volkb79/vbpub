#!/bin/bash
#
# Test script to validate critical swap benchmark and configuration fixes
# Tests the fixes without requiring root or making system changes
#

set -uo pipefail  # Removed -e to allow tests to continue on failure

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0
FAILED=0

log_test() {
    echo -e "${YELLOW}TEST:${NC} $*"
}

log_pass() {
    echo -e "${GREEN}✓ PASS:${NC} $*"
    ((PASSED++))
}

log_fail() {
    echo -e "${RED}✗ FAIL:${NC} $*"
    ((FAILED++))
}

echo "================================================"
echo "Testing Critical Swap Benchmark Fixes"
echo "================================================"
echo ""

# Test 1: Verify ZSWAP systemd service is in setup-swap.sh
test_zswap_systemd_service() {
    log_test "Checking ZSWAP systemd service configuration"
    
    if grep -q "zswap-config.service" "$SCRIPT_DIR/setup-swap.sh"; then
        log_pass "ZSWAP systemd service definition found"
    else
        log_fail "ZSWAP systemd service definition NOT found"
        return
    fi
    
    # Check for key service components
    if grep -q "Description=Configure ZSWAP Parameters" "$SCRIPT_DIR/setup-swap.sh"; then
        log_pass "Service description present"
    else
        log_fail "Service description missing"
    fi
    
    if grep -q "systemctl enable zswap-config.service" "$SCRIPT_DIR/setup-swap.sh"; then
        log_pass "Service enable command present"
    else
        log_fail "Service enable command missing"
    fi
    
    # Check that ZSWAP_ZPOOL variable is used (not hardcoded z3fold in runtime setup)
    if grep 'echo "\$ZSWAP_ZPOOL"' "$SCRIPT_DIR/setup-swap.sh" > /dev/null 2>&1; then
        log_pass "ZSWAP_ZPOOL variable used in runtime setup"
    else
        log_fail "ZSWAP_ZPOOL variable not used in runtime setup"
    fi
    
    # Check that ZSWAP_ZPOOL is also in systemd service
    if grep -A 20 "zswap-config.service" "$SCRIPT_DIR/setup-swap.sh" | grep 'ZSWAP_ZPOOL' > /dev/null 2>&1; then
        log_pass "ZSWAP_ZPOOL variable found in systemd service"
    else
        log_fail "ZSWAP_ZPOOL variable not in systemd service"
    fi
}

# Test 2: Verify execution order in bootstrap.sh
test_execution_order() {
    log_test "Checking execution order in bootstrap.sh"
    
    # Get line numbers for key sections
    benchmark_line=$(grep -n "Running system benchmarks" "$SCRIPT_DIR/bootstrap.sh" | head -1 | cut -d: -f1)
    swap_line=$(grep -n "Configuring swap" "$SCRIPT_DIR/bootstrap.sh" | head -1 | cut -d: -f1)
    geekbench_line=$(grep -n "Running Geekbench" "$SCRIPT_DIR/bootstrap.sh" | head -1 | cut -d: -f1)
    
    if [ -z "$benchmark_line" ] || [ -z "$swap_line" ] || [ -z "$geekbench_line" ]; then
        log_fail "Could not find all execution markers"
        return
    fi
    
    # Verify order: Benchmarks < Swap < Geekbench
    if [ "$benchmark_line" -lt "$swap_line" ] && [ "$swap_line" -lt "$geekbench_line" ]; then
        log_pass "Execution order correct: Benchmarks (line $benchmark_line) → Swap (line $swap_line) → Geekbench (line $geekbench_line)"
    else
        log_fail "Execution order incorrect: Benchmarks=$benchmark_line, Swap=$swap_line, Geekbench=$geekbench_line"
    fi
    
    # Check for explanatory comment
    if grep -q "MOVED HERE.*after swap configuration" "$SCRIPT_DIR/bootstrap.sh"; then
        log_pass "Explanatory comment present for Geekbench move"
    else
        log_fail "Explanatory comment missing"
    fi
}

# Test 3: Verify concurrency level 8 in matrix test
test_concurrency_level_8() {
    log_test "Checking concurrency level 8 in matrix test"
    
    # Look for the concurrency_levels assignment
    if grep -q "concurrency_levels = \[1, 2, 4, 8\]" "$SCRIPT_DIR/benchmark.py"; then
        log_pass "Concurrency level 8 added to matrix test"
    else
        log_fail "Concurrency level 8 NOT found in matrix test"
        return
    fi
    
    # Check comment update
    if grep -q "Test up to 8 for optimal detection" "$SCRIPT_DIR/benchmark.py"; then
        log_pass "Updated comment explains level 8 addition"
    else
        log_fail "Comment not updated"
    fi
}

# Test 4: Verify drop_caches in allocator tests
test_drop_caches_allocator() {
    log_test "Checking drop_caches in allocator tests"
    
    # Check for drop_caches implementation
    if grep -q "drop_caches" "$SCRIPT_DIR/benchmark.py"; then
        log_pass "drop_caches call found in benchmark.py"
    else
        log_fail "drop_caches call NOT found"
        return
    fi
    
    # Check it's in the allocator test section
    if grep -B 2 -A 20 "test_all or args.test_allocators:" "$SCRIPT_DIR/benchmark.py" | grep -q "drop_caches"; then
        log_pass "drop_caches in allocator test section"
    else
        log_fail "drop_caches not in correct location"
    fi
    
    # Check for explanation
    if grep -q "ensure fresh memory" "$SCRIPT_DIR/benchmark.py"; then
        log_pass "Explanatory comment for drop_caches present"
    else
        log_fail "Explanatory comment missing"
    fi
}

# Test 5: Verify space efficiency calculation exists
test_space_efficiency() {
    log_test "Checking space efficiency calculation"
    
    if grep -q "Space Efficiency.*Optimal Config" "$SCRIPT_DIR/benchmark.py"; then
        log_pass "Space efficiency section found in output"
    else
        log_fail "Space efficiency section NOT found"
    fi
}

# Test 6: Verify Geekbench Telegram integration exists
test_geekbench_telegram() {
    log_test "Checking Geekbench Telegram integration"
    
    if [ -f "$SCRIPT_DIR/sysinfo-notify.py" ]; then
        log_pass "sysinfo-notify.py exists"
    else
        log_fail "sysinfo-notify.py NOT found"
        return
    fi
    
    if grep -q "geekbench" "$SCRIPT_DIR/sysinfo-notify.py"; then
        log_pass "Geekbench integration found in sysinfo-notify.py"
    else
        log_fail "Geekbench integration NOT found"
    fi
}

# Test 7: Verify Python syntax
test_python_syntax() {
    log_test "Validating Python syntax"
    
    if python3 -m py_compile "$SCRIPT_DIR/benchmark.py" 2>/dev/null; then
        log_pass "benchmark.py has valid Python syntax"
    else
        log_fail "benchmark.py has syntax errors"
    fi
}

# Test 8: Verify Bash syntax
test_bash_syntax() {
    log_test "Validating Bash syntax"
    
    if bash -n "$SCRIPT_DIR/setup-swap.sh" 2>/dev/null; then
        log_pass "setup-swap.sh has valid Bash syntax"
    else
        log_fail "setup-swap.sh has syntax errors"
    fi
    
    if bash -n "$SCRIPT_DIR/bootstrap.sh" 2>/dev/null; then
        log_pass "bootstrap.sh has valid Bash syntax"
    else
        log_fail "bootstrap.sh has syntax errors"
    fi
}

# Run all tests
test_zswap_systemd_service
echo ""
test_execution_order
echo ""
test_concurrency_level_8
echo ""
test_drop_caches_allocator
echo ""
test_space_efficiency
echo ""
test_geekbench_telegram
echo ""
test_python_syntax
echo ""
test_bash_syntax
echo ""

# Summary
echo "================================================"
echo "Test Summary"
echo "================================================"
echo -e "Tests passed: ${GREEN}$PASSED${NC}"
echo -e "Tests failed: ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
