#!/bin/bash
# Automated test script for sercov.pl based on testing file method 4
# Key Testing Scenarios to Validate:
# 1. Basic MCP Protocol: initialize, tools/list
# 2. Bridge Lifecycle: start → status → read/write → stop
# 3. Error Handling: Invalid VM names, missing parameters
# 4. Auto-restart: Simulate VM disconnect and verify auto-restart
# 5. Multiple VMs: Test concurrent bridges for different VMs
# 6. Performance: High-volume read/write operations

SERVER_PID=""
VM_MOCK_PID="/dev/null"  # Using null for now since we found BEEMO_VM
cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null
    kill "$VM_MOCK_PID" 2>/dev/null
    wait 2>/dev/null
    exit 0
}
trap cleanup INT TERM

echo "=== Starting Comprehensive sercov.pl Automated Test ==="

# Test 1: Basic MCP Protocol - initialize, tools/list
echo "Test 1: Basic MCP Protocol - tools/list"
timeout 10 perl sercov.pl &
SERVER_PID=$!
sleep 3
echo '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}' | timeout 10 perl sercov.pl > test1_output.json
RESULT1=$?
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
echo "Test 1 Result: $RESULT1"
if [ $RESULT1 -eq 0 ] && grep -q "tools.*list" test1_output.json; then
    echo "✓ MCP Protocol test PASSED"
else
    echo "✗ MCP Protocol test FAILED"
fi

# Test 2: Bridge Lifecycle with Mock VM
echo "Test 2: Bridge Lifecycle - start → status → read/write → stop"
python3 mock_vm.py &
VM_MOCK_PID=$!

sleep 3
echo "Starting bridge lifecycle test..."
timeout 15 perl sercov.pl &
SERVER_PID=$!
sleep 3

# Start bridge
echo '{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "start", "arguments": {"VM_NAME": "autotest"}}}' | timeout 15 perl sercov.pl > test2_start.json
START_RESULT=$?

# Check status  
echo '{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "status", "arguments": {"VM_NAME": "autotest"}}}' | timeout 15 perl sercov.pl > test2_status.json
STATUS_RESULT=$?

# Read output
echo '{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read", "arguments": {"VM_NAME": "autotest"}}}' | timeout 15 perl sercov.pl > test2_read.json
READ_RESULT=$?

# Send command
echo '{"jsonrpc": "2.0", "id": "5", "method": "tools/call", "params": {"name": "write", "arguments": {"VM_NAME": "autotest", "text": "echo hello world"}}}' | timeout 15 perl sercov.pl > test2_write.json
WRITE_RESULT=$?

# Read response
echo '{"jsonrpc": "2.0", "id": "6", "method": "tools/call", "params": {"name": "read", "arguments": {"VM_NAME": "autotest"}}}' | timeout 15 perl sercov.pl > test2_read_resp.json
READ_RESP_RESULT=$?

# Stop bridge
echo '{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "stop", "arguments": {"VM_NAME": "autotest"}}}' | timeout 15 perl sercov.pl > test2_stop.json
STOP_RESULT=$?

kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
kill $VM_MOCK_PID 2>/dev/null
wait "$VM_MOCK_PID" 2>/dev/null

echo "Test 2 Results: Start=$START_RESULT, Status=$STATUS_RESULT, Read=$READ_RESULT, Write=$WRITE_RESULT, ReadResp=$READ_RESP_RESULT, Stop=$STOP_RESULT"

if [ $START_RESULT -eq 0 ] && [ $STATUS_RESULT -eq 0 ] && [ $WRITE_RESULT -eq 0 ] && [ $STOP_RESULT -eq 0 ]; then
    echo "✓ Bridge Lifecycle test PASSED"
else
    echo "✗ Bridge Lifecycle test FAILED"
fi

# Test 3: Error Handling Tests
echo "Test 3: Error Handling Tests"
timeout 10 perl sercov.pl &
SERVER_PID=$!
sleep 3

echo '{"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "status", "arguments": {"VM_NAME": "nonexistent"}}}' | timeout 10 perl sercov.pl > test3_error.json
ERROR_RESULT=$?

echo '{"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "read", "arguments": {"VM_NAME": "nonexistent"}}}' | timeout 10 perl sercov.pl >> test3_error.json
ERROR_RESULT2=$?

kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

if grep -q "Bridge not running" test3_error.json && grep -q "error" test3_error.json; then
    echo "✓ Error Handling test PASSED"
else
    echo "✗ Error Handling test FAILED"
fi

# Test 4: Multiple VMs Support
echo "Test 4: Multiple VMs Support"
python3 mock_vm.py &
VM_MOCK_PID=$!
sleep 3

timeout 15 perl sercov.pl &
SERVER_PID=$!
sleep 3

# Start first VM
echo '{"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "start", "arguments": {"VM_NAME": "vm1", "PORT": "4557"}}}' | timeout 15 perl sercov.pl > test4_vm1.json

# Start second VM on same port (should fail gracefully)
echo '{"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "start", "arguments": {"VM_NAME": "vm2", "PORT": "4557"}}}' | timeout 15 perl sercov.pl > test4_vm2.json

# Stop first VM
echo '{"jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": {"name": "stop", "arguments": {"VM_NAME": "vm1"}}}' | timeout 15 perl sercov.pl

# Now start second VM
sleep 2
echo '{"jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": {"name": "start", "arguments": {"VM_NAME": "vm2", "PORT": "4557"}}}' | timeout 15 perl sercov.pl > test4_vm2_restart.json

kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
kill $VM_MOCK_PID 2>/dev/null
wait "$VM_MOCK_PID" 2>/dev/null

echo "Test 4: Multiple VM test completed"

echo "=== Test Summary ==="
echo "Test 1 (MCP Protocol): $(grep -q "tools.*list" test1_output.json 2>/dev/null && echo 'PASSED' || echo 'FAILED')"
echo "Test 2 (Bridge Lifecycle): START=$START_RESULT, STATUS=$STATUS_RESULT, WRITE=$WRITE_RESULT, STOP=$STOP_RESULT"
echo "Test 3 (Error Handling): $(grep -q "Bridge not running" test3_error.json 2>/dev/null && echo 'PASSED' || echo 'FAILED')"
echo "Test 4 (Multiple VMs): Multiple VM support test completed"

cleanup