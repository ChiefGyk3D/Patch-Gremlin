#!/bin/bash
# Test logic validation for setup-unattended-upgrades.sh
# This script performs dry-run logic checks without making system changes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Testing Setup Script Logic"
echo "=========================================="
echo

# Test 1: Check for required functions
echo -e "${YELLOW}Test 1: Checking for required functions...${NC}"
required_functions=(
    "detect_os"
    "check_root"
    "install_dependencies"
    "collect_doppler_secrets"
    "collect_local_secrets"
    "configure_debian"
    "configure_rhel"
    "create_systemd_service"
)

all_functions_found=true
for func in "${required_functions[@]}"; do
    if grep -q "^${func}()" setup-unattended-upgrades.sh; then
        echo -e "${GREEN}✓ Found function: ${func}${NC}"
    else
        echo -e "${RED}✗ Missing function: ${func}${NC}"
        all_functions_found=false
    fi
done

if [ "$all_functions_found" = true ]; then
    echo -e "${GREEN}Test 1 PASSED${NC}"
else
    echo -e "${RED}Test 1 FAILED${NC}"
fi
echo

# Test 2: Check SECRET_MODE logic flow
echo -e "${YELLOW}Test 2: Checking SECRET_MODE logic flow...${NC}"
secret_mode_checks=(
    "SECRET_MODE selection prompt"
    "Doppler token prompt"
    "Local secrets collection"
    "DOPPLER_TOKEN validation"
)

secret_mode_ok=true

# Check for SECRET_MODE prompt
if grep -q 'read.*"Choose.*secret.*storage.*mode"' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found SECRET_MODE prompt${NC}"
else
    echo -e "${RED}✗ Missing SECRET_MODE prompt${NC}"
    secret_mode_ok=false
fi

# Check for Doppler token prompt
if grep -q 'read.*"Enter your Doppler service token"' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found Doppler token prompt${NC}"
else
    echo -e "${RED}✗ Missing Doppler token prompt${NC}"
    secret_mode_ok=false
fi

# Check for token validation
if grep -q 'dp\.st\.' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found Doppler token validation${NC}"
else
    echo -e "${RED}✗ Missing Doppler token validation${NC}"
    secret_mode_ok=false
fi

# Check for local secrets file creation
if grep -q '/etc/update-notifier/secrets.conf' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found local secrets file handling${NC}"
else
    echo -e "${RED}✗ Missing local secrets file handling${NC}"
    secret_mode_ok=false
fi

if [ "$secret_mode_ok" = true ]; then
    echo -e "${GREEN}Test 2 PASSED${NC}"
else
    echo -e "${RED}Test 2 FAILED${NC}"
fi
echo

# Test 3: Check for safe parameter expansion
echo -e "${YELLOW}Test 3: Checking for safe parameter expansion...${NC}"
safe_expansion_ok=true

# Check for unsafe variable references in critical sections
if grep -E '\$DOPPLER_TOKEN[^:-]' setup-unattended-upgrades.sh | grep -v '^\s*#' | grep -v 'ESCAPED_TOKEN'; then
    echo -e "${RED}✗ Found potentially unsafe DOPPLER_TOKEN references${NC}"
    safe_expansion_ok=false
else
    echo -e "${GREEN}✓ All DOPPLER_TOKEN references use safe expansion${NC}"
fi

# Check that ESCAPED_* variables use safe expansion
if grep -E 'ESCAPED_.*=.*\$\{[A-Z_]+:-\}' setup-unattended-upgrades.sh >/dev/null; then
    echo -e "${GREEN}✓ ESCAPED_* variables use safe expansion${NC}"
else
    echo -e "${RED}✗ ESCAPED_* variables may not use safe expansion${NC}"
    safe_expansion_ok=false
fi

if [ "$safe_expansion_ok" = true ]; then
    echo -e "${GREEN}Test 3 PASSED${NC}"
else
    echo -e "${RED}Test 3 FAILED${NC}"
fi
echo

# Test 4: Check systemd service creation logic
echo -e "${YELLOW}Test 4: Checking systemd service creation...${NC}"
systemd_ok=true

# Check for SERVICE_ENV variable building
if grep -q 'SERVICE_ENV=' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found SERVICE_ENV construction${NC}"
else
    echo -e "${RED}✗ Missing SERVICE_ENV construction${NC}"
    systemd_ok=false
fi

# Check for both Doppler and local mode handling in systemd
if grep -q 'Environment="SECRET_MODE=local"' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found local mode systemd configuration${NC}"
else
    echo -e "${RED}✗ Missing local mode systemd configuration${NC}"
    systemd_ok=false
fi

if grep -q 'Environment="DOPPLER_TOKEN=' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found Doppler mode systemd configuration${NC}"
else
    echo -e "${RED}✗ Missing Doppler mode systemd configuration${NC}"
    systemd_ok=false
fi

if [ "$systemd_ok" = true ]; then
    echo -e "${GREEN}Test 4 PASSED${NC}"
else
    echo -e "${RED}Test 4 FAILED${NC}"
fi
echo

# Test 5: Check APT/DNF hook creation
echo -e "${YELLOW}Test 5: Checking APT/DNF hook creation...${NC}"
hook_ok=true

# Check for APT hook
if grep -q '99patch-gremlin-notification' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found APT hook configuration${NC}"
else
    echo -e "${RED}✗ Missing APT hook configuration${NC}"
    hook_ok=false
fi

# Check for DNF hook
if grep -q 'patch-gremlin.conf' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found DNF hook configuration${NC}"
else
    echo -e "${RED}✗ Missing DNF hook configuration${NC}"
    hook_ok=false
fi

# Check that hooks handle both modes
if grep -A5 'DPkg::Post-Invoke' setup-unattended-upgrades.sh | grep -q 'DOPPLER_TOKEN'; then
    echo -e "${GREEN}✓ APT hook handles Doppler mode${NC}"
else
    echo -e "${RED}✗ APT hook may not handle Doppler mode${NC}"
    hook_ok=false
fi

if [ "$hook_ok" = true ]; then
    echo -e "${GREEN}Test 5 PASSED${NC}"
else
    echo -e "${RED}Test 5 FAILED${NC}"
fi
echo

# Test 6: Check for proper escaping
echo -e "${YELLOW}Test 6: Checking for proper variable escaping...${NC}"
escape_ok=true

# Check that sed is used for escaping
if grep -q "sed 's/\[\\\\\\\\\\\"" setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Found proper sed escaping${NC}"
else
    echo -e "${RED}✗ May be missing proper sed escaping${NC}"
    escape_ok=false
fi

# Check that ESCAPED_TOKEN is used in systemd service
if grep -q 'Environment="DOPPLER_TOKEN=\$ESCAPED_TOKEN"' setup-unattended-upgrades.sh || \
   grep -q 'Environment="DOPPLER_TOKEN=.*ESCAPED_TOKEN' setup-unattended-upgrades.sh; then
    echo -e "${GREEN}✓ Escaped token used in systemd service${NC}"
else
    echo -e "${RED}✗ May not be using escaped token in systemd service${NC}"
    escape_ok=false
fi

if [ "$escape_ok" = true ]; then
    echo -e "${GREEN}Test 6 PASSED${NC}"
else
    echo -e "${RED}Test 6 FAILED${NC}"
fi
echo

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
total_tests=6
passed_tests=0

[ "$all_functions_found" = true ] && ((passed_tests++))
[ "$secret_mode_ok" = true ] && ((passed_tests++))
[ "$safe_expansion_ok" = true ] && ((passed_tests++))
[ "$systemd_ok" = true ] && ((passed_tests++))
[ "$hook_ok" = true ] && ((passed_tests++))
[ "$escape_ok" = true ] && ((passed_tests++))

echo -e "Passed: ${GREEN}${passed_tests}/${total_tests}${NC}"
echo -e "Failed: ${RED}$((total_tests - passed_tests))/${total_tests}${NC}"

if [ $passed_tests -eq $total_tests ]; then
    echo -e "\n${GREEN}All logic tests PASSED! ✓${NC}"
    exit 0
else
    echo -e "\n${RED}Some logic tests FAILED! ✗${NC}"
    exit 1
fi
