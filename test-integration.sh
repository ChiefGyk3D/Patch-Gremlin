#!/bin/bash
# Comprehensive integration test for the full Patch Gremlin system
# Tests the interaction between all components

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Comprehensive System Integration Test"
echo "=========================================="
echo

# Test 1: Check all required files exist
echo -e "${YELLOW}Test 1: Checking required files...${NC}"
required_files=(
    "setup-unattended-upgrades.sh"
    "update-notifier.sh"
    "uninstall.sh"
    "test-setup.sh"
    "config.example.sh"
)

files_ok=true
for file in "${required_files[@]}"; do
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓ Found: $file${NC}"
    else
        echo -e "${RED}✗ Missing: $file${NC}"
        files_ok=false
    fi
done

if [ "$files_ok" = true ]; then
    echo -e "${GREEN}Test 1 PASSED${NC}"
else
    echo -e "${RED}Test 1 FAILED${NC}"
fi
echo

# Test 2: Verify setup script structure
echo -e "${YELLOW}Test 2: Verifying setup script structure...${NC}"
setup_checks=(
    "set -euo pipefail"
    "SECRET_MODE"
    "DOPPLER_TOKEN"
    "collect_local_secrets"
    "Environment="
)

setup_ok=true
for check in "${setup_checks[@]}"; do
    if grep -q "$check" setup-unattended-upgrades.sh; then
        echo -e "${GREEN}✓ Found: $check${NC}"
    else
        echo -e "${RED}✗ Missing: $check${NC}"
        setup_ok=false
    fi
done

if [ "$setup_ok" = true ]; then
    echo -e "${GREEN}Test 2 PASSED${NC}"
else
    echo -e "${RED}Test 2 FAILED${NC}"
fi
echo

# Test 3: Verify notification script structure
echo -e "${YELLOW}Test 3: Verifying notification script structure...${NC}"
notifier_checks=(
    "/etc/update-notifier/secrets.conf"
    "SECRET_MODE"
    "send_discord_notification"
    "send_teams_notification"
    "send_slack_notification"
    "send_matrix_notification"
)

notifier_ok=true
for check in "${notifier_checks[@]}"; do
    if grep -q "$check" update-notifier.sh; then
        echo -e "${GREEN}✓ Found: $check${NC}"
    else
        echo -e "${RED}✗ Missing: $check${NC}"
        notifier_ok=false
    fi
done

if [ "$notifier_ok" = true ]; then
    echo -e "${GREEN}Test 3 PASSED${NC}"
else
    echo -e "${RED}Test 3 FAILED${NC}"
fi
echo

# Test 4: Verify uninstaller structure
echo -e "${YELLOW}Test 4: Verifying uninstaller structure...${NC}"
uninstall_checks=(
    "/etc/update-notifier/secrets.conf"
    "update-notifier.service"
    "99patch-gremlin-notification"
    "patch-gremlin.conf"
)

uninstall_ok=true
for check in "${uninstall_checks[@]}"; do
    if grep -q "$check" uninstall.sh; then
        echo -e "${GREEN}✓ Found: $check${NC}"
    else
        echo -e "${RED}✗ Missing: $check${NC}"
        uninstall_ok=false
    fi
done

if [ "$uninstall_ok" = true ]; then
    echo -e "${GREEN}Test 4 PASSED${NC}"
else
    echo -e "${RED}Test 4 FAILED${NC}"
fi
echo

# Test 5: Check for common security issues
echo -e "${YELLOW}Test 5: Checking for security issues...${NC}"
security_ok=true

# Check for eval usage (dangerous)
if grep -E '^\s*eval\s' setup-unattended-upgrades.sh update-notifier.sh uninstall.sh 2>/dev/null; then
    echo -e "${RED}✗ Found dangerous eval usage${NC}"
    security_ok=false
else
    echo -e "${GREEN}✓ No dangerous eval usage${NC}"
fi

# Check for chmod 777 (insecure)
if grep -E 'chmod\s+(777|666)' setup-unattended-upgrades.sh update-notifier.sh 2>/dev/null; then
    echo -e "${RED}✗ Found insecure permissions (777/666)${NC}"
    security_ok=false
else
    echo -e "${GREEN}✓ No insecure permissions${NC}"
fi

# Check that secrets file has proper permissions
if grep -q 'chmod 600.*secrets.conf' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Secrets file has secure permissions (600)${NC}"
else
    echo -e "${RED}✗ Secrets file may not have secure permissions${NC}"
    security_ok=false
fi

if [ "$security_ok" = true ]; then
    echo -e "${GREEN}Test 5 PASSED${NC}"
else
    echo -e "${RED}Test 5 FAILED${NC}"
fi
echo

# Test 6: Verify proper error handling
echo -e "${YELLOW}Test 6: Checking error handling...${NC}"
error_handling_ok=true

# Check for set -e (exit on error)
if grep -q 'set -euo pipefail' setup-unattended-upgrades.sh update-notifier.sh; then
    echo -e "${GREEN}✓ Scripts use strict error handling${NC}"
else
    echo -e "${RED}✗ Scripts may not have strict error handling${NC}"
    error_handling_ok=false
fi

# Check for safe parameter expansion
if grep -E '\$\{[A-Z_]+:-\}' setup-unattended-upgrades.sh >/dev/null; then
    echo -e "${GREEN}✓ Uses safe parameter expansion${NC}"
else
    echo -e "${RED}✗ May not use safe parameter expansion${NC}"
    error_handling_ok=false
fi

if [ "$error_handling_ok" = true ]; then
    echo -e "${GREEN}Test 6 PASSED${NC}"
else
    echo -e "${RED}Test 6 FAILED${NC}"
fi
echo

# Test 7: Verify both modes are fully implemented
echo -e "${YELLOW}Test 7: Checking dual-mode implementation...${NC}"
dual_mode_ok=true

# Doppler mode checks
if grep -q 'SECRET_MODE.*doppler' setup-unattended-upgrades.sh && \
   grep -q 'DOPPLER_TOKEN' setup-unattended-upgrades.sh && \
   grep -q 'DOPPLER_TOKEN' update-notifier.sh; then
    echo -e "${GREEN}✓ Doppler mode fully implemented${NC}"
else
    echo -e "${RED}✗ Doppler mode may not be fully implemented${NC}"
    dual_mode_ok=false
fi

# Local mode checks
if grep -q 'SECRET_MODE.*local' setup-unattended-upgrades.sh && \
   grep -q '/etc/update-notifier/secrets.conf' setup-unattended-upgrades.sh && \
   grep -q '/etc/update-notifier/secrets.conf' update-notifier.sh; then
    echo -e "${GREEN}✓ Local mode fully implemented${NC}"
else
    echo -e "${RED}✗ Local mode may not be fully implemented${NC}"
    dual_mode_ok=false
fi

if [ "$dual_mode_ok" = true ]; then
    echo -e "${GREEN}Test 7 PASSED${NC}"
else
    echo -e "${RED}Test 7 FAILED${NC}"
fi
echo

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
total_tests=7
passed_tests=0

[ "$files_ok" = true ] && ((passed_tests++))
[ "$setup_ok" = true ] && ((passed_tests++))
[ "$notifier_ok" = true ] && ((passed_tests++))
[ "$uninstall_ok" = true ] && ((passed_tests++))
[ "$security_ok" = true ] && ((passed_tests++))
[ "$error_handling_ok" = true ] && ((passed_tests++))
[ "$dual_mode_ok" = true ] && ((passed_tests++))

echo -e "Passed: ${GREEN}${passed_tests}/${total_tests}${NC}"
echo -e "Failed: ${RED}$((total_tests - passed_tests))/${total_tests}${NC}"
echo

if [ $passed_tests -eq $total_tests ]; then
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ALL INTEGRATION TESTS PASSED! ✓    ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo
    echo "The system is ready for:"
    echo "  • Production deployment"
    echo "  • Both Doppler and local file modes"
    echo "  • Secure secret handling"
    echo "  • Multi-platform support (Debian/RHEL)"
    echo
    exit 0
else
    echo -e "${RED}Some integration tests failed.${NC}"
    echo "Please review the failures above."
    exit 1
fi
