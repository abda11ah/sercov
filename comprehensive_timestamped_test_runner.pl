#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(strftime);
use IO::Socket::UNIX;
use Getopt::Long;

# Comprehensive test runner with millisecond timestamps for event logging

my $socket_path = '/tmp/serial_comprehensive-test';
my $vm_name = 'comprehensive-test';
my $log_file = "logs/comprehensive_timestamped_test.log";
my $start_time = [gettimeofday()];

GetOptions(
    'socket=s' => \$socket_path,
    'vm=s' => \$vm_name,
    'log=s' => \$log_file,
);

# Create logs directory if it doesn't exist
system("mkdir -p logs");

# Log function with millisecond timestamps
sub log_event {
    my ($message, $level) = @_;
    $level ||= 'INFO';
    my $elapsed = tv_interval($start_time);
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $ms = sprintf("%03d", ($elapsed - int($elapsed)) * 1000);
    my $log_entry = sprintf("[%s.%s] [%s] %s\n", $timestamp, $ms, $level, $message);

    # Print to stdout for immediate feedback
    print $log_entry;

    # Also write to log file
    open(my $fh, ">>", $log_file) or die "Cannot open $log_file: $!";
    print $fh $log_entry;
    close($fh);
}

my $request_id = 1;

sub send_request {
    my ($method, $params) = @_;
    my $request = {
        jsonrpc => "2.0",
        id => $request_id++,
        method => $method,
        params => $params
    };

    my $json = encode_json($request);
    log_event("SEND REQUEST: $method - $json", 'DEBUG');

    # Send to STDOUT (serencp.pl reads from STDIN)
    print STDOUT $json . "\n";
    STDOUT->flush();

    # Read response from STDIN
    my $response_line = <STDIN>;

    if ($response_line) {
        chomp $response_line;
        log_event("RECEIVE RESPONSE: $response_line", 'DEBUG');
        return decode_json($response_line);
    }

    log_event("ERROR: No response received", 'ERROR');
    return undef;
}

sub send_tool_call {
    my ($tool, $arguments) = @_;
    return send_request('tools/call', {
        name => $tool,
        arguments => $arguments
    });
}

sub wait_for_condition {
    my ($condition_func, $timeout, $description) = @_;
    $timeout ||= 30;
    my $start_wait = [gettimeofday()];

    log_event("WAITING: $description (timeout: ${timeout}s)", 'INFO');

    while (tv_interval($start_wait) < $timeout) {
        if ($condition_func->()) {
            my $elapsed = tv_interval($start_wait);
            log_event("SUCCESS: $description completed in ${elapsed}s", 'INFO');
            return 1;
        }
        select(undef, undef, undef, 0.1); # Sleep 100ms
    }

    log_event("TIMEOUT: $description failed after ${timeout}s", 'ERROR');
    return 0;
}

# Test functions
sub test_initialize {
    log_event("TEST: Starting server initialization", 'TEST');
    my $response = send_request('initialize', {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => {
            name => "comprehensive_test_runner",
            version => "1.0.0"
        }
    });

    if ($response && $response->{result}) {
        log_event("TEST: Server initialization successful", 'PASS');
        return 1;
    } else {
        log_event("TEST: Server initialization failed", 'FAIL');
        return 0;
    }
}

sub test_tools_list {
    log_event("TEST: Testing tools/list", 'TEST');
    my $response = send_request('tools/list', {});

    if ($response && $response->{result} && ref($response->{result}->{tools}) eq 'ARRAY') {
        my @tools = @{$response->{result}->{tools}};
        log_event("TEST: Found " . scalar(@tools) . " tools: " . join(", ", map { $_->{name} } @tools), 'PASS');
        return 1;
    } else {
        log_event("TEST: tools/list failed", 'FAIL');
        return 0;
    }
}

sub test_start_bridge {
    log_event("TEST: Testing bridge start", 'TEST');
    my $response = send_tool_call('start', {
        vm_name => $vm_name,
        port => 4557
    });

    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            log_event("TEST: Bridge started successfully - Port: $result->{port}, Socket: $result->{socket}", 'PASS');
            return 1;
        } else {
            log_event("TEST: Bridge start failed - $result->{message}", 'FAIL');
            return 0;
        }
    } else {
        log_event("TEST: Bridge start request failed", 'FAIL');
        return 0;
    }
}

sub test_bridge_status {
    log_event("TEST: Testing bridge status", 'TEST');
    my $response = send_tool_call('status', {
        vm_name => $vm_name
    });

    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        my $status = $result->{running} ? 'running' : 'stopped';
        log_event("TEST: Bridge status - $status (buffer: $result->{buffer_size} lines)", 'PASS');
        return $result->{running};
    } else {
        log_event("TEST: Bridge status check failed", 'FAIL');
        return 0;
    }
}

sub test_read_output {
    log_event("TEST: Testing read output", 'TEST');
    my $response = send_tool_call('read', {
        vm_name => $vm_name
    });

    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            my $output_len = length($result->{output});
            log_event("TEST: Read successful - $output_len characters", 'PASS');

            # Analyze output for ANSI codes
            my $ansi_count = () = $result->{output} =~ /\x1b\[/g;
            if ($ansi_count > 0) {
                log_event("TEST: Found $ansi_count ANSI escape sequences", 'INFO');
            }

            return 1;
        } else {
            log_event("TEST: Read failed - $result->{message}", 'FAIL');
            return 0;
        }
    } else {
        log_event("TEST: Read request failed", 'FAIL');
        return 0;
    }
}

sub test_write_command {
    log_event("TEST: Testing write command", 'TEST');
    my $test_command = 'echo "Test command from comprehensive test runner"';
    my $response = send_tool_call('write', {
        vm_name => $vm_name,
        text => $test_command
    });

    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            log_event("TEST: Write successful - $result->{message}", 'PASS');
            return 1;
        } else {
            log_event("TEST: Write failed - $result->{message}", 'FAIL');
            return 0;
        }
    } else {
        log_event("TEST: Write request failed", 'FAIL');
        return 0;
    }
}

sub test_error_handling {
    log_event("TEST: Testing error handling", 'TEST');

    # Test missing vm_name parameter
    my $response1 = send_tool_call('status', {});
    my $error1 = ($response1 && $response1->{result} &&
                  decode_json($response1->{result}{content}[0]{text})->{error}) ? 1 : 0;

    # Test invalid vm_name
    my $response2 = send_tool_call('status', { vm_name => 'nonexistent-vm' });
    my $result2 = decode_json($response2->{result}{content}[0]{text}) if $response2 && $response2->{result};
    my $error2 = ($result2 && !$result2->{running}) ? 1 : 0;

    if ($error1 && $error2) {
        log_event("TEST: Error handling working correctly", 'PASS');
        return 1;
    } else {
        log_event("TEST: Error handling not working properly", 'FAIL');
        return 0;
    }
}

sub test_stop_bridge {
    log_event("TEST: Testing bridge stop", 'TEST');
    my $response = send_tool_call('stop', {
        vm_name => $vm_name
    });

    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            log_event("TEST: Bridge stopped successfully - $result->{message}", 'PASS');
            return 1;
        } else {
            log_event("TEST: Bridge stop failed - $result->{message}", 'FAIL');
            return 0;
        }
    } else {
        log_event("TEST: Bridge stop request failed", 'FAIL');
        return 0;
    }
}

# Main test execution
log_event("=== STARTING COMPREHENSIVE SERENCP.PL TEST SUITE ===", 'INFO');

my %test_results;

# Test 1: Server Initialization
$test_results{initialize} = test_initialize();

# Test 2: Tools Listing
$test_results{tools_list} = test_tools_list();

# Test 3: Start Bridge
$test_results{start_bridge} = test_start_bridge();

# Wait for bridge to be ready
if ($test_results{start_bridge}) {
    wait_for_condition(sub { test_bridge_status() }, 10, "Bridge to be ready");
}

# Test 4: Bridge Status
$test_results{bridge_status} = test_bridge_status();

# Wait for VM output
log_event("WAITING: Allowing time for VM to generate output", 'INFO');
sleep(5);

# Test 5: Read Output
$test_results{read_output} = test_read_output();

# Test 6: Write Command
$test_results{write_command} = test_write_command();

# Wait for command to execute
sleep(2);

# Test 7: Read Output Again (after write)
$test_results{read_output_after_write} = test_read_output();

# Test 8: Error Handling
$test_results{error_handling} = test_error_handling();

# Test 9: Stop Bridge
$test_results{stop_bridge} = test_stop_bridge();

# Test 10: Final Status Check
$test_results{final_status} = !test_bridge_status(); # Should be stopped

# Summary
log_event("=== TEST RESULTS SUMMARY ===", 'INFO');
my $passed = 0;
my $total = scalar(keys %test_results);

foreach my $test (sort keys %test_results) {
    my $result = $test_results{$test} ? 'PASS' : 'FAIL';
    log_event("TEST: $test - $result", $test_results{$test} ? 'PASS' : 'FAIL');
    $passed++ if $test_results{$test};
}

my $success_rate = sprintf("%.1f%%", ($passed / $total) * 100);
log_event("OVERALL: $passed/$total tests passed ($success_rate)", $passed == $total ? 'PASS' : 'FAIL');

log_event("=== COMPREHENSIVE TEST SUITE COMPLETED ===", 'INFO');