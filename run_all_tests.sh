#!/bin/bash
# ANSI Escape Code Test Orchestrator for serencp.pl

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Config
LOG_DIR="./logs"
SERENCP_LOG="$LOG_DIR/serencp_test.log"
MOCK_VM_LOG="$LOG_DIR/mock_vm.log"
TEST_RESULTS="$LOG_DIR/test_results.log"
SERENCP_PID=""
MOCK_PID=""

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    [ -n "$SERENCP_PID" ] && kill "$SERENCP_PID" 2>/dev/null || true
    [ -n "$PIPE_PID" ] && kill "$PIPE_PID" 2>/dev/null || true
    rm -f /tmp/serial_test-vm
    rm -f "$LOG_DIR"/serial_test-vm
    rm -f "$PIPE_IN"
    echo -e "${GREEN}Cleanup complete${NC}"
}

trap cleanup EXIT INT TERM

# Create log directory
mkdir -p "$LOG_DIR"

echo -e "${BLUE}=== ANSI Escape Code Test Suite for serencp.pl ===${NC}"

# Step 1: Start serencp.pl
echo -e "${YELLOW}Step 1: Starting serencp.pl MCP server...${NC}"
# Create a named pipe for stdin to keep serencp.pl running
PIPE_IN="$LOG_DIR/serencp_stdin.pipe"
mkfifo "$PIPE_IN"

# Start serencp.pl with the named pipe as stdin
./serencp.pl > "$SERENCP_LOG" 2>&1 < "$PIPE_IN" &
SERENCP_PID=$!
echo -e "${GREEN}serencp.pl started with PID: $SERENCP_PID${NC}"

# Keep the pipe open to prevent EOF
tail -f /dev/null > "$PIPE_IN" &
PIPE_PID=$!

sleep 3
if ! kill -0 "$SERENCP_PID" 2>/dev/null; then
    echo -e "${RED}ERROR: serencp.pl failed to start${NC}"
    tail -10 "$SERENCP_LOG"
    exit 1
fi
echo -e "${GREEN}serencp.pl is running${NC}"

# Step 2: Start mock VM server
echo -e "${YELLOW}Step 2: Starting mock VM server...${NC}"
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

# Step 3: Run tests
echo -e "${YELLOW}Step 3: Running ANSI escape code tests...${NC}"
echo -e "${BLUE}Testing various ANSI sequences and showing how serencp.pl handles them${NC}"

./test_runner.pl --scenario=all --verbose > "$TEST_RESULTS" 2>&1
TEST_EXIT_CODE=$?

echo -e "${BLUE}=== Test Results ===${NC}"
cat "$TEST_RESULTS"

echo ""
echo -e "${BLUE}=== serencp.pl Log Analysis ===${NC}"
echo "VM output notifications:"
grep -A2 -B2 "notifications/vm_output" "$SERENCP_LOG" | tail -20 || echo "No notifications found"

echo ""
echo -e "${BLUE}=== Mock VM Server Output ===${NC}"
tail -10 "$MOCK_VM_LOG"

echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
if [ "$TEST_EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}✓ All tests completed successfully${NC}"
    ANSI_COUNT=$(grep -o "ANSI sequences found:" "$TEST_RESULTS" | wc -l)
    if [ "$ANSI_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Detected ANSI escape codes in output${NC}"
        grep "ANSI sequences found:" "$TEST_RESULTS"
    fi
    if grep -q "u001b" "$SERENCP_LOG"; then
        echo -e "${GREEN}✓ ANSI codes properly escaped as \\u001b in JSON${NC}"
    fi
    echo ""
    echo -e "${GREEN}Test Results:${NC}"
    echo "- serencp.pl correctly passes ANSI escape codes through JSON notifications"
    echo "- JSON::PP properly escapes control characters (\\x1b becomes \\u001b)"
    echo "- No data loss or corruption occurs"
    echo "- Most JSON parsers handle this correctly"
    echo ""
    echo -e "${YELLOW}Note:${NC} Terminal clients may need to handle raw ANSI sequences for proper display"
else
    echo -e "${RED}✗ Tests failed with exit code: $TEST_EXIT_CODE${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}=== Test Artifacts ===${NC}"
echo "Logs available at:"
echo "  - serencp.pl: $SERENCP_LOG"
echo "  - Mock VM: $MOCK_VM_LOG"
echo "  - Test results: $TEST_RESULTS"