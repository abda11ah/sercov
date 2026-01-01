#!/bin/bash

echo "=== Manual Test for serencp.pl ===" > serencp_manual.log
echo "Test started at: $(date)" >> serencp_manual.log
echo "================================" >> serencp_manual.log

echo "Starting mock VM server..." | tee -a serencp_manual.log
./mock_vm_server.pl --port=4556 --delay=1 --scenario=all > mock_vm.log 2>&1 &
MOCK_PID=$!
echo "Mock VM server started with PID: $MOCK_PID" | tee -a serencp_manual.log

sleep 3

echo "Running manual test..." | tee -a serencp_manual.log
./manual_test.pl > serencp_test_output.log 2>&1 &
TEST_PID=$!

sleep 15

echo "Stopping processes..." | tee -a serencp_manual.log
kill $MOCK_PID 2>/dev/null || true

echo "Test completed at: $(date)" >> serencp_manual.log
echo "================================" >> serencp_manual.log

echo "=== Test Results ==="
echo "Mock VM log (last 20 lines):"
tail -20 mock_vm.log
echo ""
echo "serencp.pl test output (last 20 lines):"
tail -20 serencp_test_output.log