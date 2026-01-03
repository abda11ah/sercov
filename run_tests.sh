#!/bin/bash

# SERENCP Test Runner
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/t"
SERENCP="$SCRIPT_DIR/serencp.pl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}SERENCP Test Suite${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -f "$TEST_DIR/mock_vm_server.pl" 2>/dev/null || true
    pkill -f "$SERENCP" 2>/dev/null || true
    rm -f /tmp/serial_test_vm_* 2>/dev/null || true
    echo "Done"
}
trap cleanup EXIT

# Check Perl
echo -e "${GREEN}>>>${NC} Checking Perl..."
if command -v perl &> /dev/null; then
    echo -e "${GREEN}✓${NC} Perl found: $(perl -v | head -2 | tail -1)"
else
    echo "ERROR: Perl not found"
    exit 1
fi

# Check Perl modules
echo ""
echo -e "${GREEN}>>>${NC} Checking Perl Modules..."
for module in JSON::PP IO::Socket::INET IO::Select IO::Pty IO::Pipe; do
    if perl -M$module -e 'print "OK"' 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $module"
    else
        echo -e "${GREEN}✗${NC} $module is missing"
        exit 1
    fi
done

# Syntax check
echo ""
echo -e "${GREEN}>>>${NC} Syntax Check..."
if perl -c "$SERENCP" 2>&1 | grep -q "syntax OK"; then
    echo -e "${GREEN}✓${NC} serencp.pl syntax is valid"
else
    perl -c "$SERENCP"
    exit 1
fi

# Prepare test scripts
echo ""
echo -e "${GREEN}>>>${NC} Preparing Test Scripts..."
chmod +x "$TEST_DIR/mock_vm_server.pl" 2>/dev/null
chmod +x "$TEST_DIR/integration_test.pl" 2>/dev/null
echo -e "${GREEN}✓${NC} Test scripts executable"

# Cleanup old instances
echo ""
echo -e "${GREEN}>>>${NC} Cleanup..."
pkill -f "$TEST_DIR/mock_vm_server.pl" 2>/dev/null || echo -e "${YELLOW}No old instances${NC}"
pkill -f "$SERENCP" 2>/dev/null || echo -e "${YELLOW}No old instances${NC}"
echo -e "${GREEN}✓${NC} Cleanup complete"

# Run integration test
echo ""
echo -e "${GREEN}>>>${NC} Running Integration Test"
echo ""
echo -e "${YELLOW}This test demonstrates dual-mode operation:${NC}"
echo -e "${YELLOW}  • LLM receives JSON notifications${NC}"
echo -e "${YELLOW}  • Human sees output in spawned terminal${NC}"
echo ""
echo "Press Ctrl+C to stop test"
echo ""

"$TEST_DIR/integration_test.pl"
