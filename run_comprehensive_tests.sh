#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_DIR="./logs"
COMPREHENSIVE_LOG="$LOG_DIR/comprehensive_test.log"
SERENCP_LOG="$LOG_DIR/serencp_orchestrator.log"
MOCK_VM_LOG="$LOG_DIR/mock_vm_enhanced.log"
TEST_RESULTS_LOG="$LOG_DIR/orchestrator_results.log"

SERENCP_PID=""
MOCK_PID=""

timestamp_ms() {
    date +"%Y-%m-%d %H:%M:%S.%3N"
}

log_event() {
    local event="$1"
    local data="${2:-}"
    echo "[$(timestamp_ms)] $event: $data" | tee -a "$TEST_RESULTS_LOG"
}

cleanup() {
    log_event "CLEANUP" "Starting cleanup process"
    
    [ -n "$MOCK_PID" ] && {
        kill "$MOCK_PID" 2>/dev/null || true
        log_event "CLEANUP" "Killed mock VM server PID: $MOCK_PID"
    }
    [ -n "$SERENCP_PID" ] && {
        kill "$SERENCP_PID" 2>/dev/null || true
        log_event "CLEANUP" "Killed serencp.pl PID: $SERENCP_PID"
    }
    
    rm -f /tmp/serial_test-vm 2>/dev/null || true
    rm -f "$LOG_DIR"/serial_test-vm 2>/dev/null || true
    
    log_event "CLEANUP" "Cleanup complete"
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

trap cleanup EXIT INT TERM

mkdir -p "$LOG_DIR"

echo -e "${BLUE}=== Enhanced serencp.pl Test Orchestrator ===${NC}"
log_event "ORCHESTRATOR_START" "Starting comprehensive test suite"

echo -e "${YELLOW}Step 1: Starting serencp.pl MCP server...${NC}"
log_event "STEP1_START" "Starting serencp.pl"

PIPE_IN="$LOG_DIR/serencp_stdin.pipe"
mkfifo "$PIPE_IN"

./serencp.pl > "$SERENCP_LOG" 2>&1 < "$PIPE_IN" &
SERENCP_PID=$!

log_event "SERENCP_START" "serencp.pl started with PID: $SERENCP_PID"

tail -f /dev/null > "$PIPE_IN" &
PIPE_PID=$!

sleep 3

if ! kill -0 "$SERENCP_PID" 2>/dev/null; then
    log_event "SERENCP_ERROR" "serencp.pl failed to start"
    echo -e "${RED}ERROR: serencp.pl failed to start${NC}"
    tail -10 "$SERENCP_LOG"
    exit 1
fi

log_event "SERENCP_READY" "serencp.pl is running and ready"
echo -e "${GREEN}✓ serencp.pl started successfully (PID: $SERENCP_PID)${NC}"

echo -e "${YELLOW}Step 2: Starting enhanced mock VM server...${NC}"
log_event "STEP2_START" "Starting mock VM server"

./mock_vm_enhanced.pl --port=4556 --scenario=test --verbose > "$MOCK_VM_LOG" 2>&1 &
MOCK_PID=$!

log_event "MOCK_VM_START" "Mock VM server started with PID: $MOCK_PID"

sleep 2

if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    log_event "MOCK_VM_ERROR" "Mock VM server failed to start"
    echo -e "${RED}ERROR: Mock VM server failed to start${NC}"
    tail -10 "$MOCK_VM_LOG"
    exit 1
fi

log_event "MOCK_VM_READY" "Mock VM server is running and ready"
echo -e "${GREEN}✓ Mock VM server started successfully (PID: $MOCK_PID)${NC}"

echo -e "${YELLOW}Step 3: Running comprehensive test suite...${NC}"
log_event "STEP3_START" "Running comprehensive tests"

if ./comprehensive_test.pl --log="$COMPREHENSIVE_LOG" --verbose; then
    log_event "TEST_SUCCESS" "All tests passed"
    echo -e "${GREEN}✓ All tests passed successfully${NC}"
    TEST_RESULT=0
else
    log_event "TEST_FAILURE" "Some tests failed"
    echo -e "${RED}✗ Some tests failed${NC}"
    TEST_RESULT=1
fi

echo -e "${YELLOW}Step 4: Analyzing test results...${NC}"
log_event "STEP4_START" "Analyzing results"

PASSED_COUNT=$(grep -c "TEST_END.*Result: PASS" "$COMPREHENSIVE_LOG" 2>/dev/null || echo "0")
FAILED_COUNT=$(grep -c "TEST_END.*Result: FAIL" "$COMPREHENSIVE_LOG" 2>/dev/null || echo "0")
TOTAL_COUNT=$((PASSED_COUNT + FAILED_COUNT))

log_event "RESULTS_COUNT" "Total: $TOTAL_COUNT, Passed: $PASSED_COUNT, Failed: $FAILED_COUNT"

SERENCP_ERRORS=$(grep -c "ERROR\|FATAL" "$SERENCP_LOG" 2>/dev/null || echo "0")
if [ "$SERENCP_ERRORS" -gt 0 ]; then
    log_event "SERENCP_ERRORS_FOUND" "Found $SERENCP_ERRORS errors in serencp.pl log"
    echo -e "${YELLOW}⚠ Found $SERENCP_ERRORS errors in serencp.pl log${NC}"
else
    log_event "SERENCP_CLEAN" "No errors found in serencp.pl log"
fi

MOCK_ERRORS=$(grep -c "ERROR\|FATAL\|Cannot\|Failed" "$MOCK_VM_LOG" 2>/dev/null || echo "0")
if [ "$MOCK_ERRORS" -gt 0 ]; then
    log_event "MOCK_ERRORS_FOUND" "Found $MOCK_ERRORS errors in mock VM log"
    echo -e "${YELLOW}⚠ Found $MOCK_ERRORS errors in mock VM log${NC}"
else
    log_event "MOCK_CLEAN" "No errors found in mock VM log"
fi

echo -e "${BLUE}=== Detailed Test Results ===${NC}"
echo "Total tests run: $TOTAL_COUNT"
echo "Passed: $PASSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "Success rate: $(( PASSED_COUNT * 100 / TOTAL_COUNT ))%" 2>/dev/null || echo "N/A"

echo -e "${BLUE}=== Sample Test Events ===${NC}"
head -20 "$TEST_RESULTS_LOG" | tail -10

if [ "$SERENCP_ERRORS" -gt 0 ]; then
    echo -e "${BLUE}=== serencp.pl Errors ===${NC}"
    grep -i "error\|fatal" "$SERENCP_LOG" | head -5
fi

# Check for mock VM issues
MOCK_ERRORS=$(grep -c "ERROR\|FATAL\|Cannot\|Failed" "$MOCK_VM_LOG" 2>/dev/null || echo "0")
if [ "$MOCK_ERRORS" -gt 0 ]; then
    log_event "MOCK_ERRORS_FOUND" "Found $MOCK_VM_ERRORS errors in mock VM log"
    echo -e "${YELLOW}⚠ Found $MOCK_VM_ERRORS errors in mock VM log${NC}"
else
    log_event "MOCK_CLEAN" "No errors found in mock VM log"
fi

# Print detailed results
echo -e "${BLUE}=== Detailed Test Results ===${NC}"
echo "Total tests run: $TOTAL_COUNT"
echo "Passed: $PASSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "Success rate: $(( PASSED_COUNT * 100 / TOTAL_COUNT ))%" 2>/dev/null || echo "N/A"

# Show sample of test events
echo -e "${BLUE}=== Sample Test Events ===${NC}"
head -20 "$TEST_RESULTS_LOG" | tail -10

# Show any errors found
if [ "$SERENCP_ERRORS" -gt 0 ]; then
    echo -e "${BLUE}=== serencp.pl Errors ===${NC}"
    grep -i "error\|fatal" "$SERENCP_LOG" | head -5
fi

echo -e "${YELLOW}Step 5: Generating final report...${NC}"
log_event "STEP5_START" "Generating final report"

REPORT="$LOG_DIR/final_test_report.txt"
cat > "$REPORT" << EOF
=== serencp.pl Test Report ===
Generated: $(timestamp_ms)

Test Summary:
- Total Tests: $TOTAL_COUNT
- Passed: $PASSED_COUNT  
- Failed: $FAILED_COUNT
- Success Rate: $(( PASSED_COUNT * 100 / TOTAL_COUNT ))%

Process Information:
- serencp.pl PID: $SERENCP_PID
- Mock VM PID: $MOCK_PID
- Test Result: $([ $TEST_RESULT -eq 0 ] && echo "SUCCESS" || echo "FAILURE")

Error Analysis:
- serencp.pl Errors: $SERENCP_ERRORS
- Mock VM Errors: $MOCK_ERRORS

Log Files:
- Comprehensive Test Log: $COMPREHENSIVE_LOG
- serencp.pl Log: $SERENCP_LOG
- Mock VM Log: $MOCK_VM_LOG
- Orchestrator Log: $TEST_RESULTS_LOG

EOF

log_event "REPORT_GENERATED" "Final report saved to $REPORT"

if [ "$TEST_RESULT" -eq 0 ]; then
    echo -e "${GREEN}=== TEST SUITE COMPLETED SUCCESSFULLY ===${NC}"
    log_event "ORCHESTRATOR_SUCCESS" "All tests completed successfully"
else
    echo -e "${RED}=== TEST SUITE COMPLETED WITH FAILURES ===${NC}"
    log_event "ORCHESTRATOR_FAILURE" "Test suite completed with failures"
fi

echo -e "${BLUE}Log files available at:${NC}"
echo "  - Comprehensive test: $COMPREHENSIVE_LOG"
echo "  - serencp.pl: $SERENCP_LOG" 
echo "  - Mock VM: $MOCK_VM_LOG"
echo "  - Orchestrator: $TEST_RESULTS_LOG"
echo "  - Final report: $REPORT"

exit $TEST_RESULT