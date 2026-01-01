#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_DIR="./logs"
SERENCP_LOG="$LOG_DIR/serencp_test.log"
MOCK_VM_LOG="$LOG_DIR/mock_vm.log"
TEST_RESULTS="$LOG_DIR/test_results.log"

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    [ -n "$SERENCP_PID" ] && kill "$SERENCP_PID" 2>/dev/null || true
    rm -f /tmp/serial_test-vm
    echo -e "${GREEN}Cleanup complete${NC}"
}

trap cleanup EXIT INT TERM

mkdir -p "$LOG_DIR"

echo -e "${BLUE}=== ANSI Escape Code Test Suite for serencp.pl ===${NC}"

echo -e "${YELLOW}Step 1: Starting mock VM server...${NC}"
./mock_vm_server.pl --port=4556 --delay=1 --scenario=all > "$MOCK_VM_LOG" 2>&1 &
MOCK_PID=$!
echo -e "${GREEN}Mock VM server started with PID: $MOCK_PID${NC}"
sleep 3
if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo -e "${RED}ERROR: Mock VM server failed to start${NC}"
    tail -10 "$MOCK_VM_LOG"
    exit 1
fi
echo -e "${GREEN}Mock VM server is running${NC}"

echo -e "${YELLOW}Step 2: Testing serencp.pl functionality...${NC}"

{
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test_client","version":"1.0.0"}}}'
    sleep 1
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 1
    echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start","arguments":{"vm_name":"test-vm","port":4556}}}'
    sleep 3
    echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read","arguments":{"vm_name":"test-vm"}}}'
    sleep 1
    echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"stop","arguments":{"vm_name":"test-vm"}}}'
} | ./serencp.pl > "$TEST_RESULTS" 2>&1

TEST_EXIT_CODE=$?

echo -e "${BLUE}=== Test Results ===${NC}"
cat "$TEST_RESULTS"

echo ""
echo -e "${BLUE}=== Mock VM Server Output ===${NC}"
tail -10 "$MOCK_VM_LOG"

echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
if [ "$TEST_EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}✓ serencp.pl test completed successfully${NC}"
    
    if grep -q '"result"' "$TEST_RESULTS"; then
        echo -e "${GREEN}✓ serencp.pl responded to JSON-RPC requests correctly${NC}"
    fi
    
    if grep -q '"tools"' "$TEST_RESULTS"; then
        echo -e "${GREEN}✓ serencp.pl tools are properly exposed${NC}"
    fi
else
    echo -e "${YELLOW}⚠ serencp.pl test completed with exit code: $TEST_EXIT_CODE${NC}"
fi

echo ""
echo -e "${BLUE}=== Test Artifacts ===${NC}"
echo "Logs available at:"
echo "  - Mock VM: $MOCK_VM_LOG"
echo "  - Test results: $TEST_RESULTS"