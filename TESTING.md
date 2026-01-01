# ANSI Escape Code Testing for serencp.pl

This test suite demonstrates how serencp.pl handles ANSI escape codes in VM serial console output and helps verify the current behavior.

## Overview

The serencp.pl script currently passes raw ANSI escape codes through JSON notifications without filtering. This test suite helps verify this behavior and demonstrates potential issues.

## Test Scripts

### 1. mock_vm_server.pl
Simulates a VM serial console that outputs various ANSI escape sequences.

**Usage:**
```bash
./mock_vm_server.pl [options]
```

**Options:**
- `--port=4555` - Port to listen on (default: 4555)
- `--delay=1` - Seconds between output lines (default: 1)
- `--scenario=all` - Test scenario to run (default: all)

**Scenarios:**
- `all` - Run all scenarios
- `basic` - Basic color codes (red, green, yellow, blue)
- `complex` - Complex sequences (bold, underline, 256 colors)
- `cursor` - Cursor movement sequences
- `screen` - Screen clearing sequences
- `progress` - Progress bar simulation
- `mixed` - Mixed ANSI and plain text
- `error` - Error/warning messages with ANSI

**Example:**
```bash
./mock_vm_server.pl --port=4555 --delay=0.5 --scenario=basic
```

### 2. test_client.pl
Basic client for interacting with serencp.pl MCP server.

**Usage:**
```bash
./test_client.pl --action=<action> [options]
```

**Actions:**
- `start` - Start VM bridge
- `stop` - Stop VM bridge
- `status` - Check bridge status
- `read` - Read VM output
- `write` - Send command to VM

**Options:**
- `--socket=/tmp/serencp_test.sock` - Socket path
- `--vm=test-vm` - VM name
- `--text="command"` - Text for write action
- `--verbose` - Show detailed output

**Examples:**
```bash
# Start bridge
./test_client.pl --action=start --vm=test-vm

# Read output
./test_client.pl --action=read --vm=test-vm --verbose

# Send command
./test_client.pl --action=write --vm=test-vm --text="ls -la"
```

### 3. test_runner.pl
Comprehensive test runner with ANSI analysis capabilities.

**Usage:**
```bash
./test_runner.pl --scenario=<scenario> [options]
```

**Scenarios:**
- `basic_colors` - Test basic ANSI color codes
- `complex_sequences` - Test complex ANSI sequences
- `cursor_movement` - Test cursor movement
- `all` or `full` - Run complete test suite

**Options:**
- `--socket=/tmp/serencp_test.sock` - Socket path
- `--vm=test-vm` - VM name
- `--verbose` - Show hex dumps and detailed analysis

**Examples:**
```bash
# Run basic color test
./test_runner.pl --scenario=basic_colors --verbose

# Run full test suite
./test_runner.pl --scenario=all --verbose
```

## Test Setup

### 1. Make scripts executable:
```bash
chmod +x mock_vm_server.pl test_client.pl test_runner.pl serencp.pl
```

### 2. Start serencp.pl with test socket:
```bash
./serencp.pl > /tmp/serencp.log 2>&1 &
```

### 3. In another terminal, start the mock VM server:
```bash
./mock_vm_server.pl --port=4555 --delay=1
```

### 4. Run tests in a third terminal:
```bash
# Basic test
./test_runner.pl --scenario=basic_colors

# Full test with analysis
./test_runner.pl --scenario=all --verbose
```

## Current Behavior Analysis

### What serencp.pl Currently Does

1. **Raw ANSI Pass-through**: ANSI escape codes are passed through JSON notifications unchanged
2. **JSON Escaping**: JSON::PP properly escapes control characters (\x1b becomes \u001b)
3. **UTF-8 Handling**: Control characters are valid UTF-8 and pass through correctly

### Example JSON Notification

When VM outputs: `\x1b[31mError:\x1b[0m Something failed`

The JSON notification contains:
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/vm_output",
  "params": {
    "vm": "test-vm",
    "stream": "stdout",
    "chunk": "\u001b[31mError:\u001b[0m Something failed",
    "timestamp": "2026-01-01T09:19:08.000Z"
  }
}
```

### Potential Issues

1. **Client Display**: Terminal clients may display raw escape sequences
2. **JSON Parsing**: Some strict JSON parsers might reject control characters
3. **Log Analysis**: ANSI codes can interfere with log parsing and analysis
4. **Cross-platform**: Different terminals handle ANSI codes differently

## Test Scenarios

### Scenario 1: Basic Colors
Tests fundamental ANSI color codes:
- `\x1b[31m` - Red text
- `\x1b[32m` - Green text  
- `\x1b[33m` - Yellow text
- `\x1b[34m` - Blue text
- `\x1b[0m` - Reset

### Scenario 2: Complex Sequences
Tests advanced ANSI features:
- `\x1b[1m` - Bold
- `\x1b[4m` - Underline
- `\x1b[7m` - Inverse
- `\x1b[38;5;196m` - 256-color foreground
- `\x1b[48;5;226m` - 256-color background

### Scenario 3: Cursor Movement
Tests cursor positioning:
- `\x1b[2A` - Move cursor up 2 lines
- `\x1b[1B` - Move cursor down 1 line
- `\x1b[H` - Move to home position

### Scenario 4: Screen Control
Tests screen manipulation:
- `\x1b[2J` - Clear screen
- `\x1b[H` - Move to top-left

### Scenario 5: Mixed Content
Tests combinations:
- Plain text mixed with ANSI
- Multiple attributes combined
- Real-world error/warning messages

## Expected Test Results

### With Current serencp.pl Behavior:

1. **JSON Output**: ANSI codes appear as `\u001b[` in JSON
2. **Raw Bytes**: ESC character (0x1B) passes through unchanged
3. **Notifications**: Live notifications include raw ANSI sequences
4. **Buffer Storage**: Ring buffer stores output with ANSI codes intact

### Example Analysis Output:

```
Raw output (with visible escape sequences):
------------------------------------------------------------
ESC[31mRed textESC[0mESC[32mGreen textESC[0m
ESC[1mBoldESC[0m ESC[4mUnderlineESC[0m
------------------------------------------------------------
ANSI sequences found: 8

Hex dump (first 200 bytes):
[ESC][31mRed text[ESC][0m[ESC][32mGreen text[ESC][0m[ESC][1mBold[ESC][0m
```

## Recommendations

### Current Status: Functional but with Caveats

The current implementation works correctly for most use cases:
- JSON encoding/decoding handles control characters properly
- ANSI codes are preserved for client-side processing
- No data loss or corruption occurs

### Potential Improvements:

1. **ANSI Filtering Option**: Add configuration to strip ANSI codes
2. **Separate Raw/Processed Streams**: Provide both raw and filtered output
3. **Client-side Handling**: Document how clients should process ANSI codes
4. **Base64 Encoding**: For binary data that might cause issues

### When to Use Filtering:

- **Strip ANSI**: For log analysis, text processing, cross-platform compatibility
- **Preserve ANSI**: For terminal display, color preservation, real-time monitoring

## Troubleshooting

### Common Issues:

1. **Connection Refused**: Ensure serencp.pl is running and socket path matches
2. **No Output**: Check that mock VM server is running on correct port
3. **ANSI Not Visible**: Use `--verbose` flag to see hex dumps
4. **JSON Parse Errors**: Verify serencp.pl is outputting valid JSON

### Debug Commands:

```bash
# Watch serencp.pl output
tail -f /tmp/serencp.log

# Monitor socket
tail -f /tmp/serencp_test.sock

# Check processesp
ps aux | grep -E '(serencp|mock_vm)'

# Test socket connection
nc -U /tmp/serencp_test.sock
```

## Integration with CI/CD

These tests can be integrated into automated testing:

```bash
#!/bin/bash
# test_ansi_handling.sh

set -e

# Start serencp.pl
./serencp.pl > /tmp/serencp.log 2>&1 &
SERCov_PID=$!
sleep 2

# Start mock VM
./mock_vm_server.pl --port=4555 --delay=0.1 --scenario=all &
MOCK_PID=$!
sleep 2

# Run tests
./test_runner.pl --scenario=all --verbose > test_results.log

# Cleanup
kill $SERCov_PID $MOCK_PID 2>/dev/null

# Analyze results
grep -q "ANSI sequences found:" test_results.log && echo "Tests passed"