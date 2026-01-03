# SERENCP Testing Guide

This directory contains test infrastructure for the serencp MCP server.

## Test Files

### 1. `mock_vm_server.pl`
A mock VM server that simulates a Linux VM's serial console on TCP port.

**Features:**
- Simulates boot sequence with kernel messages
- Interactive shell with basic commands (ls, uptime, date, whoami, top)
- Authenticates with username/password (any input works)

**Usage:**
```bash
perl t/mock_vm_server.pl [--port=PORT]
```

**Default port:** 4555

### 2. `integration_test.pl`
Comprehensive integration test that demonstrates dual-mode operation.

**What it tests:**
1. ✓ Mock VM startup and connectivity
2. ✓ MCP server initialization
3. ✓ VM bridge creation
4. ✓ JSON notifications to LLM
5. ✓ Terminal window spawning (socket mode)

**Usage:**
```bash
perl t/integration_test.pl
```

**Expected output:**
- JSON notifications printed to console (LLM view)
- Terminal window opens with live VM output (human view)

### 3. `run_tests.sh`
Main test runner that checks dependencies and executes tests.

**Usage:**
```bash
./run_tests.sh
```

**It will:**
- Check Perl and required modules
- Validate syntax of serencp.pl
- Clean up old test instances
- Run the integration test

## Dual-Mode Operation

The serencp server provides two simultaneous views of VM output:

### Mode 1: MCP JSON Notifications (for LLM)
When VM data arrives, serencp.pl sends JSON-RPC 2.0 notifications:

```json
{
    "jsonrpc": "2.0",
    "method": "notifications/vm_output",
    "params": {
        "vm": "test_vm",
        "stream": "stdout",
        "chunk": "mock-vm login: ",
        "timestamp": "2026-01-03T10:30:45.000Z"
    }
}
```

### Mode 2: Unix Socket Client (for Humans)
Simultaneously, serencp.pl:
1. Creates a Unix socket at `/tmp/serial_{vm_name}`
2. Spawns a terminal window using `serencp.pl --socket=/tmp/serial_{vm_name}`
3. Forwards VM output to terminal in real-time

**Both modes run simultaneously!** LLM gets structured JSON, humans get readable output.

## Test Scenarios

### Scenario 1: Basic Bridge Start
```bash
# Start mock VM
perl t/mock_vm_server.pl &

# Start serencp and connect to it
perl serencp.pl &
# Send: {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start","arguments":{"vm_name":"test1"}}}
```

**Expected:**
- Terminal window appears
- Mock VM output visible in terminal
- JSON notifications sent to stdout

### Scenario 2: Manual Socket Connection
```bash
# Start mock VM and serencp
perl t/mock_vm_server.pl &
perl serencp.pl &
# Start VM bridge via MCP

# Manually connect via socket
perl serencp.pl --socket=/tmp/serial_test_vm
```

**Expected:**
- Interactive shell in terminal
- Same VM output as auto-spawned terminal

## Troubleshooting

### Terminal window doesn't appear
**Cause:** No compatible terminal emulator found

**Solution:** Install one of the supported terminals:
```bash
# Ubuntu/Debian
sudo apt install gnome-terminal konsole xterm

# Fedora/RHEL
sudo dnf install gnome-terminal konsole xterm
```

### Port already in use
**Cause:** Previous test instance still running

**Solution:** Kill old processes:
```bash
pkill -f mock_vm_server.pl
pkill -f serencp.pl
rm -f /tmp/serial_*
```

## Running Individual Tests

### Quick Syntax Check
```bash
perl -c serencp.pl
```

### Mock VM Only
```bash
perl t/mock_vm_server.pl --port=4556
# In another terminal:
telnet localhost 4556
```

### Integration Test Only
```bash
perl t/integration_test.pl
```
