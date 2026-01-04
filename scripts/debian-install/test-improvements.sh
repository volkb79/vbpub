#!/bin/bash
#
# Test script for debian-install improvements
# Tests the new features without requiring root or making system changes
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0
FAILED=0

# Disable exit on error for grep commands
set +e

log_test() {
    echo -e "${YELLOW}TEST:${NC} $*"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $*"
    ((PASSED++))
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $*"
    ((FAILED++))
}

# Test 1: Check all scripts exist and are executable
test_scripts_exist() {
    log_test "Checking scripts exist and are executable"
    
    local scripts=(
        "bootstrap.sh"
        "setup-swap.sh"
        "configure-users.sh"
        "configure-apt.sh"
        "configure-journald.sh"
        "install-docker.sh"
    )
    
    local all_ok=true
    for script in "${scripts[@]}"; do
        if [ ! -f "$SCRIPT_DIR/$script" ]; then
            log_fail "$script does not exist"
            all_ok=false
        elif [ ! -x "$SCRIPT_DIR/$script" ]; then
            log_fail "$script is not executable"
            all_ok=false
        fi
    done
    
    if [ "$all_ok" = true ]; then
        log_pass "All scripts exist and are executable"
    fi
}

# Test 2: Check FQDN function in scripts
test_fqdn_usage() {
    log_test "Checking FQDN usage in scripts"
    
    local all_ok=true
    
    # Check bootstrap.sh
    if grep -q "hostname -f" "$SCRIPT_DIR/bootstrap.sh"; then
        log_pass "bootstrap.sh uses FQDN (hostname -f)"
    else
        log_fail "bootstrap.sh does not use FQDN"
        all_ok=false
    fi
    
    # Check setup-swap.sh
    if grep -q "hostname -f" "$SCRIPT_DIR/setup-swap.sh"; then
        log_pass "setup-swap.sh uses FQDN (hostname -f)"
    else
        log_fail "setup-swap.sh does not use FQDN"
        all_ok=false
    fi
    
    # Check telegram_client.py
    if grep -q "getfqdn()" "$SCRIPT_DIR/telegram_client.py"; then
        log_pass "telegram_client.py uses FQDN (getfqdn)"
    else
        log_fail "telegram_client.py does not use FQDN"
        all_ok=false
    fi
}

# Test 3: Check newline handling
test_newline_handling() {
    log_test "Checking newline handling in telegram functions"
    
    local all_ok=true
    
    # Check that we don't use literal \n in telegram_send
    if grep 'prefixed_msg=.*\\n' "$SCRIPT_DIR/bootstrap.sh" | grep -v "^#" 2>/dev/null; then
        log_fail "bootstrap.sh still uses literal \\n"
        all_ok=false
    else
        log_pass "bootstrap.sh uses proper newlines"
    fi
    
    if grep 'prefixed_msg=.*\\n' "$SCRIPT_DIR/setup-swap.sh" | grep -v "^#" 2>/dev/null; then
        log_fail "setup-swap.sh still uses literal \\n"
        all_ok=false
    else
        log_pass "setup-swap.sh uses proper newlines"
    fi
}

# Test 4: Check log directory changed
test_log_directory() {
    log_test "Checking log directory is debian-install"
    
    if grep -q "/var/log/debian-install" "$SCRIPT_DIR/bootstrap.sh"; then
        log_pass "Log directory is /var/log/debian-install"
    else
        log_fail "Log directory is not /var/log/debian-install"
    fi
}

# Test 5: Check DRY principle in configure-users.sh
test_dry_principle() {
    log_test "Checking DRY principle in configure-users.sh"
    
    # Check for content functions
    if grep -q "get_nanorc_content()" "$SCRIPT_DIR/configure-users.sh" && \
       grep -q "get_mc_ini_content()" "$SCRIPT_DIR/configure-users.sh" && \
       grep -q "get_iftoprc_content()" "$SCRIPT_DIR/configure-users.sh" && \
       grep -q "get_htoprc_content()" "$SCRIPT_DIR/configure-users.sh"; then
        log_pass "configure-users.sh follows DRY with content functions"
    else
        log_fail "configure-users.sh does not follow DRY"
    fi
}

# Test 6: Check bash aliases
test_bash_aliases() {
    log_test "Checking bash aliases configuration"
    
    if grep -q "get_bash_aliases_content()" "$SCRIPT_DIR/configure-users.sh" && \
       grep -q "alias ll=" "$SCRIPT_DIR/configure-users.sh"; then
        log_pass "Bash aliases are configured"
    else
        log_fail "Bash aliases are not configured"
    fi
}

# Test 7: Check APT configuration
test_apt_configuration() {
    log_test "Checking APT configuration"
    
    local all_ok=true
    
    # Check for deb822 format
    if grep -q "debian.sources" "$SCRIPT_DIR/configure-apt.sh"; then
        log_pass "APT uses deb822 format"
    else
        log_fail "APT does not use deb822 format"
        all_ok=false
    fi
    
    # Check for contrib non-free non-free-firmware
    if grep -q "main contrib non-free non-free-firmware" "$SCRIPT_DIR/configure-apt.sh"; then
        log_pass "APT includes all required components"
    else
        log_fail "APT missing required components"
        all_ok=false
    fi
    
    # Check for backports
    if grep -q "backports" "$SCRIPT_DIR/configure-apt.sh"; then
        log_pass "APT includes backports"
    else
        log_fail "APT missing backports"
        all_ok=false
    fi
    
    # Check for testing
    if grep -q "testing" "$SCRIPT_DIR/configure-apt.sh"; then
        log_pass "APT includes testing"
    else
        log_fail "APT missing testing"
        all_ok=false
    fi
    
    # Check for custom.conf
    if grep -q "99-custom.conf" "$SCRIPT_DIR/configure-apt.sh" && \
       grep -q "pkgPolicy" "$SCRIPT_DIR/configure-apt.sh" && \
       grep -q "Show-Versions" "$SCRIPT_DIR/configure-apt.sh"; then
        log_pass "APT custom.conf configured"
    else
        log_fail "APT custom.conf not configured properly"
        all_ok=false
    fi
}

# Test 8: Check journald configuration
test_journald_configuration() {
    log_test "Checking journald configuration"
    
    if grep -q "SystemMaxUse=200M" "$SCRIPT_DIR/configure-journald.sh" && \
       grep -q "SystemKeepFree=500M" "$SCRIPT_DIR/configure-journald.sh" && \
       grep -q "SystemMaxFileSize=100M" "$SCRIPT_DIR/configure-journald.sh" && \
       grep -q "MaxRetentionSec=12month" "$SCRIPT_DIR/configure-journald.sh" && \
       grep -q "MaxFileSec=1month" "$SCRIPT_DIR/configure-journald.sh"; then
        log_pass "Journald configuration complete"
    else
        log_fail "Journald configuration incomplete"
    fi
}

# Test 9: Check Docker installation
test_docker_installation() {
    log_test "Checking Docker installation script"
    
    local all_ok=true
    
    # Check for Docker official repo
    if grep -q "download.docker.com" "$SCRIPT_DIR/install-docker.sh"; then
        log_pass "Docker uses official repository"
    else
        log_fail "Docker does not use official repository"
        all_ok=false
    fi
    
    # Check for daemon.json
    if grep -q "daemon.json" "$SCRIPT_DIR/install-docker.sh" && \
       grep -q '"log-driver": "local"' "$SCRIPT_DIR/install-docker.sh"; then
        log_pass "Docker daemon.json configured with local log driver"
    else
        log_fail "Docker daemon.json not configured properly"
        all_ok=false
    fi
}

# Test 10: Check bootstrap integration
test_bootstrap_integration() {
    log_test "Checking bootstrap.sh integration"
    
    local all_ok=true
    
    # Check for new config options
    if grep -q "RUN_APT_CONFIG" "$SCRIPT_DIR/bootstrap.sh" && \
       grep -q "RUN_JOURNALD_CONFIG" "$SCRIPT_DIR/bootstrap.sh" && \
       grep -q "RUN_DOCKER_INSTALL" "$SCRIPT_DIR/bootstrap.sh"; then
        log_pass "Bootstrap has new configuration options"
    else
        log_fail "Bootstrap missing configuration options"
        all_ok=false
    fi
    
    # Check for script calls
    if grep -q "./configure-apt.sh" "$SCRIPT_DIR/bootstrap.sh" && \
       grep -q "./configure-journald.sh" "$SCRIPT_DIR/bootstrap.sh" && \
       grep -q "./install-docker.sh" "$SCRIPT_DIR/bootstrap.sh"; then
        log_pass "Bootstrap calls new scripts"
    else
        log_fail "Bootstrap does not call new scripts"
        all_ok=false
    fi
    
    # Check for file attachment support
    if grep -q "send_document" "$SCRIPT_DIR/bootstrap.sh"; then
        log_pass "Bootstrap supports sending file attachments"
    else
        log_fail "Bootstrap does not support file attachments"
        all_ok=false
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "Testing Debian Install Script Improvements"
    echo "=========================================="
    echo ""
    
    test_scripts_exist
    test_fqdn_usage
    test_newline_handling
    test_log_directory
    test_dry_principle
    test_bash_aliases
    test_apt_configuration
    test_journald_configuration
    test_docker_installation
    test_bootstrap_integration
    
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo -e "${GREEN}Passed: $PASSED${NC}"
    echo -e "${RED}Failed: $FAILED${NC}"
    
    if [ $FAILED -eq 0 ]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "\n${RED}Some tests failed!${NC}"
        return 1
    fi
}

main "$@"
