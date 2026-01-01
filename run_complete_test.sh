#!/bin/bash

echo "=== Complete Test for serencp.pl ==="
echo "Test started at: $(date)"
echo "=================================="

echo "Starting mock VM server on port 4556..."
./mock_vm_server.pl --port=4556 --delay=1 --scenario=all > mock_vm.log 2>&1 &
MOCK_PID=$!
echo "Mock VM server started with PID: $MOCK_PID"

sleep 3

if kill -0 $MOCK_PID 2>/dev/null; then
    echo "Mock VM server is running"
else
    echo "ERROR: Mock VM server failed to start"
    exit 1
fi

echo "Running complete test sequence..."
cat complete_test_sequence.json | perl serencp.pl > sercov_test.log 2>&1 &
SERCov_PID=$!

sleep 10

if kill -0 $SERCov_PID 2>/dev/null; then
    echo "serencp.pl is still running, sending EOF..."
    kill -TERM $SERCov_PID 2>/dev/null || true
fi

sleep 2

echo "Stopping mock VM server..."
kill $MOCK_PID 2>/dev/null || true

echo ""
echo "=== Test Results ==="
echo "Test completed at: $(date)"
echo "=================================="
echo ""

echo "serencp.pl output (last 30 lines):"
tail -30 sercov_test.log
echo ""

echo "Mock VM log (last 20 lines):"
tail -20 mock_vm.log
echo ""

echo "=== Analysis ==="
if grep -q '"result"' sercov_test.log; then
    echo "✓ serencp.pl responded to requests successfully"
else
    echo "✗ serencp.pl did not respond to requests"
fi

if grep -q '"tools"' sercov_test.log; then
    echo "✓ tools/list returned tool definitions"
else
    echo "✗ tools/list did not return tool definitions"
fi

if grep -q '"notifications/vm_output"' sercov_test.log; then
    echo "✓ VM output notifications were sent"
else
    echo "⚠ No VM output notifications detected"
fi

if grep -q '"success"' sercov_test.log; then
    echo "✓ Tool operations reported success"
else
    echo "⚠ Tool operations may have failed"
fi

echo ""
echo "Full logs are available in:"
echo "  - sercov_test.log"
echo "  - mock_vm.log"