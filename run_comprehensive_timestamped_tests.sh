#!/bin/bash
# Comprehensive Test Orchestrator for serencp.pl with millisecond timestamp logging

set -e

# ANSI Escape Code Test Orchestrator for serencp.pl

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Config
LOG_DIR="./logs"
SERENCP_LOG="$LOG_DIR/serencp_orchestrator.log"
MOCK_VM_LOG="$LOG_DIR/mock_vm_orchestrator.log"
TEST_RUNNER_LOG="$LOG_DIR/comprehensive_test_orchestrator.log"
ORCHESTRATOR_LOG="$LOG_DIR/test_orchestrator.log"
SERENCP_PID=""
MOCK_PID=""
TEST_PID=""

# Test parameters
VM_NAME="orchestrator-test"
SOCKET_PATH="/tmp/serial_$VM_NAME"
PORT=4558
SCENARIO="all"

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}" | tee -a "$ORCHESTRATOR_LOG"
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    [ -n "$SERENCP_PID" ] && kill "$SERENCP_PID" 2>/dev/null || true
    [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null || true
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
    [ -n "$PIPE_PID" ] && kill "$PIPE_PID" 2>/dev/null || true
    rm -f "$SOCKET_PATH"
    rm -f /tmp/serial_*
    rm -f "$PIPE_IN"
    rm -f "$LOG_DIR/test_responses.pipe"
    echo -e "${GREEN}Cleanup complete${NC}" | tee -a "$ORCHESTRATOR_LOG"
}

trap cleanup EXIT INT TERM

# Create log directory
mkdir -p "$LOG_DIR"

# Log function with timestamps
log_event() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    echo "[$timestamp] [$level] $message" | tee -a "$ORCHESTRATOR_LOG"
}

log_event "=== STARTING COMPREHENSIVE SERENCP.PL TEST ORCHESTRATION ===" "INFO"

# Step 1: Start serencp.pl
log_event "Step 1: Starting serencp.pl MCP server..." "INFO"

# Create a named pipe for stdin to keep serencp.pl running
PIPE_IN="$LOG_DIR/serencp_stdin.pipe"
mkfifo "$PIPE_IN"

# Start serencp.pl with the named pipe as stdin
./serencp.pl > "$SERENCP_LOG" 2>&1 < "$PIPE_IN" &
SERENCP_PID=$!
log_event "serencp.pl started with PID: $SERENCP_PID" "INFO"

# Keep the pipe open to prevent EOF
tail -f /dev/null > "$PIPE_IN" &
PIPE_PID=$!

sleep 3
if ! kill -0 "$SERENCP_PID" 2>/dev/null; then
    log_event "ERROR: serencp.pl failed to start" "ERROR"
    tail -10 "$SERENCP_LOG" | while read line; do log_event "SERENCP_LOG: $line" "ERROR"; done
    exit 1
fi
log_event "serencp.pl is running" "INFO"

# Step 2: Start mock VM server with timestamp logging
log_event "Step 2: Starting mock VM server with timestamp logging..." "INFO"
./mock_vm_timestamped.pl --port=$PORT --delay=1 --scenario=$SCENARIO --log="$MOCK_VM_LOG" &
MOCK_PID=$!
log_event "Mock VM server started with PID: $MOCK_PID" "INFO"

sleep 3
if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    log_event "ERROR: Mock VM server failed to start" "ERROR"
    tail -10 "$MOCK_VM_LOG" | while read line; do log_event "MOCK_VM_LOG: $line" "ERROR"; done
    exit 1
fi
log_event "Mock VM server is running on port $PORT" "INFO"

# Step 3: Run comprehensive timestamped tests
log_event "Step 3: Running comprehensive timestamped tests..." "INFO"

# Run test runner with bidirectional communication to serencp.pl via pipes
# The test runner writes requests to its STDOUT (redirected to serencp.pl's STDIN via PIPE_IN)
# and reads responses from its STDIN (fed by serencp.pl's STDOUT via the pipe)
mkfifo "$LOG_DIR/test_responses.pipe"
./comprehensive_timestamped_test_runner.pl --socket="$SOCKET_PATH" --vm="$VM_NAME" --log="$TEST_RUNNER_LOG" < "$LOG_DIR/test_responses.pipe" > "$PIPE_IN" 2>&1 &
TEST_PID=$!

# Connect serencp.pl's STDOUT to test runner's STDIN through a pipe
# Filter out debug notifications to avoid confusing the JSON parser
tail -f "$SERENCP_LOG" | grep -v "notifications/log" > "$LOG_DIR/test_responses.pipe" &
TAIL_PID=$!

# Wait for test completion
wait $TEST_PID
TEST_EXIT_CODE=$?
log_event "Test runner completed with exit code: $TEST_EXIT_CODE" "INFO"

# Step 4: Analyze results
log_event "Step 4: Analyzing test results..." "INFO"

echo -e "\n${BLUE}=== COMPREHENSIVE TEST RESULTS ===${NC}" | tee -a "$ORCHESTRATOR_LOG"

# Check serencp.pl logs for notifications
NOTIFICATION_COUNT=$(grep -c "notifications/vm_output" "$SERENCP_LOG" || echo "0")
log_event "VM output notifications sent: $NOTIFICATION_COUNT" "INFO"

if [ "$NOTIFICATION_COUNT" -gt 0 ]; then
    log_event "✓ VM output notifications detected" "PASS"
else
    log_event "✗ No VM output notifications found" "FAIL"
fi

# Check for ANSI codes in logs
ANSI_IN_SERENCP=$(grep -c "u001b" "$SERENCP_LOG" || echo "0")
if [ "$ANSI_IN_SERENCP" -gt 0 ]; then
    log_event "✓ ANSI codes properly escaped as \\u001b in JSON ($ANSI_IN_SERENCP instances)" "PASS"
else
    log_event "✗ No ANSI codes found in serencp.pl logs" "INFO"
fi

# Check test results
if [ "$TEST_EXIT_CODE" -eq 0 ]; then
    log_event "✓ All tests completed successfully" "PASS"
else
    log_event "✗ Tests failed with exit code: $TEST_EXIT_CODE" "FAIL"
fi

# Check mock VM server activity
MOCK_CONNECTIONS=$(grep -c "CLIENT_CONNECTED" "$MOCK_VM_LOG" || echo "0")
MOCK_SENT=$(grep -c "SENT:" "$MOCK_VM_LOG" || echo "0")
log_event "Mock VM connections: $MOCK_CONNECTIONS, Messages sent: $MOCK_SENT" "INFO"

echo -e "\n${BLUE}=== DETAILED LOG ANALYSIS ===${NC}" | tee -a "$ORCHESTRATOR_LOG"

echo -e "${YELLOW}serencp.pl Notifications:${NC}" | tee -a "$ORCHESTRATOR_LOG"
grep -A2 -B2 "notifications/vm_output" "$SERENCP_LOG" | head -20 | while read line; do
    echo "  $line" | tee -a "$ORCHESTRATOR_LOG"
done || echo "  No notifications found" | tee -a "$ORCHESTRATOR_LOG"

echo -e "\n${YELLOW}Test Runner Summary:${NC}" | tee -a "$ORCHESTRATOR_LOG"
grep "TEST.*PASS\|TEST.*FAIL" "$TEST_RUNNER_LOG" | tail -10 | while read line; do
    echo "  $line" | tee -a "$ORCHESTRATOR_LOG"
done

echo -e "\n${YELLOW}Mock VM Activity:${NC}" | tee -a "$ORCHESTRATOR_LOG"
grep "STARTING_SCENARIO\|COMPLETED_SCENARIO\|CLIENT_CONNECTED" "$MOCK_VM_LOG" | tail -10 | while read line; do
    echo "  $line" | tee -a "$ORCHESTRATOR_LOG"
done

# Step 5: Final summary
echo -e "\n${BLUE}=== FINAL TEST SUMMARY ===${NC}" | tee -a "$ORCHESTRATOR_LOG"

TOTAL_PASSES=$(grep -c "\[PASS\]" "$ORCHESTRATOR_LOG" || echo "0")
TOTAL_FAILS=$(grep -c "\[FAIL\]" "$ORCHESTRATOR_LOG" || echo "0")

if [ "$TEST_EXIT_CODE" -eq 0 ] && [ "$TOTAL_FAILS" -eq 0 ]; then
    log_event "🎉 ALL TESTS PASSED! ($TOTAL_PASSES checks passed, $TOTAL_FAILS failed)" "SUCCESS"
    OVERALL_RESULT="SUCCESS"
else
    log_event "❌ SOME TESTS FAILED ($TOTAL_PASSES passed, $TOTAL_FAILS failed)" "FAIL"
    OVERALL_RESULT="FAILED"
fi

echo -e "\n${BLUE}=== TEST ARTIFACTS ===${NC}" | tee -a "$ORCHESTRATOR_LOG"
echo "Logs available at:" | tee -a "$ORCHESTRATOR_LOG"
echo "  - Orchestrator: $ORCHESTRATOR_LOG" | tee -a "$ORCHESTRATOR_LOG"
echo "  - serencp.pl: $SERENCP_LOG" | tee -a "$ORCHESTRATOR_LOG"
echo "  - Mock VM: $MOCK_VM_LOG" | tee -a "$ORCHESTRATOR_LOG"
echo "  - Test Runner: $TEST_RUNNER_LOG" | tee -a "$ORCHESTRATOR_LOG"

log_event "=== COMPREHENSIVE TEST ORCHESTRATION COMPLETED ===" "INFO"

# Exit with test result
if [ "$OVERALL_RESULT" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi