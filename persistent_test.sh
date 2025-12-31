#!/bin/bash
# persistent_test.sh - Test sercov.pl as a persistent server

# Start the MCP server in background
echo "Starting sercov.pl server..."
perl sercov.pl &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "=== Testing persistent MCP server ==="

# Function to send request to server
send_request() {
    local request="$1"
    echo "Sending: $request"
    echo "$request" | perl sercov.pl
    echo -e "\n"
}

# Test 1: List tools
send_request '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}'

# Test 2: Start bridge
send_request '{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "start", "arguments": {"VM_NAME": "testvm", "PORT": "4555"}}}'

# Test 3: Check status
send_request '{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "status", "arguments": {"VM_NAME": "testvm"}}}'

# Test 4: Read output
send_request '{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read", "arguments": {"VM_NAME": "testvm"}}}'

# Test 5: Send command
send_request '{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "write", "arguments": {"VM_NAME": "testvm", "text": "whoami"}}}'

# Test 6: Read response
send_request '{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "read", "arguments": {"VM_NAME": "testvm"}}}'

# Test 7: Stop bridge
send_request '{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "stop", "arguments": {"VM_NAME": "testvm"}}}'

echo "=== Tests completed ==="

# Clean up
kill $SERVER_PID 2>/dev/null
echo "Server stopped."