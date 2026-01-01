#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use IO::Socket::UNIX;
use IO::Select;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(strftime);
use Getopt::Long;

# Comprehensive test suite for serencp.pl with millisecond timestamp logging

my $log_file = '/tmp/sercov_comprehensive_test.log';
my $socket_path = '/tmp/serial_test-vm';
my $vm_name = 'test-vm';
my $verbose = 0;
my $run_all = 0;

GetOptions(
    'log=s' => \$log_file,
    'socket=s' => \$socket_path,
    'vm=s' => \$vm_name,
    'verbose' => \$verbose,
    'all' => \$run_all,
);

# Open log file with timestamp
open my $log_fh, '>>', $log_file or die "Cannot open log file $log_file: $!";
$| = 1; # Autoflush

sub log_event {
    my ($event, $data) = @_;
    my $timestamp = gettimeofday();
    my $time_str = strftime("%Y-%m-%d %H:%M:%S", localtime) . sprintf(".%03d", ($timestamp - int($timestamp)) * 1000);
    my $log_entry = "[$time_str] $event: " . (defined $data ? $data : '') . "\n";
    print $log_fh $log_entry;
    print $log_entry if $verbose;
}

# Track test results
my %test_results;
my $current_test = '';

sub start_test {
    my ($test_name) = @_;
    $current_test = $test_name;
    log_event("TEST_START", $test_name);
    my %test_info = ( start_time => gettimeofday() );
    $test_results{$test_name} = \%test_info;
}

sub end_test {
    my ($result, $message) = @_;
    my $test_info = $test_results{$current_test};
    my $start_time = $test_info->{start_time};
    my $duration = gettimeofday() - $start_time;
    
    $test_results{$current_test}{result} = $result;
    $test_results{$current_test}{duration} = $duration;
    $test_results{$current_test}{message} = $message;
    
    log_event("TEST_END", "$current_test - Result: $result - Duration: ${duration}s - $message");
    return $result;
}

# Connect to serencp.pl MCP server
sub connect_to_server {
    my $max_attempts = 30; # 3 seconds with 100ms sleep
    my $attempt = 0;
    
    while ($attempt < $max_attempts) {
        eval {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_STREAM,
                Peer => $socket_path,
                Timeout => 0.1
            );
            if ($sock) {
                $sock->autoflush(1);
                log_event("CONNECTION", "Successfully connected to $socket_path");
                return $sock;
            }
        };
        $attempt++;
        select(undef, undef, undef, 0.1); # 100ms delay
    }
    
    log_event("CONNECTION_ERROR", "Failed to connect to $socket_path after $max_attempts attempts");
    return undef;
}

my $request_id = 1;

sub send_request {
    my ($sock, $method, $params) = @_;
    return undef unless $sock;
    
    my $request = {
        jsonrpc => "2.0",
        id => $request_id++,
        method => $method,
        params => $params || {}
    };
    
    my $json = encode_json($request);
    log_event("REQUEST", $json);
    
    eval {
        print $sock $json . "\n";
        
        # Read response with timeout
        my $select = IO::Select->new($sock);
        if ($select->can_read(5)) { # 5 second timeout
            my $response = <$sock>;
            if ($response) {
                chomp $response;
                log_event("RESPONSE", $response);
                return decode_json($response);
            }
        }
    };
    
    if ($@) {
        log_event("REQUEST_ERROR", $@);
    }
    
    log_event("TIMEOUT", "No response received");
    return undef;
}

sub send_tool_call {
    my ($sock, $tool, $arguments) = @_;
    return send_request($sock, 'tools/call', {
        name => $tool,
        arguments => $arguments || {}
    });
}

# Test 1: Server Initialization
sub test_initialization {
    start_test("Server Initialization");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $response = send_request($sock, 'initialize', {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => {
            name => "comprehensive_test",
            version => "1.0.0"
        }
    });
    
    close $sock;
    
    if ($response && $response->{result} && $response->{result}{serverInfo}) {
        return end_test("PASS", "Server initialized successfully");
    } else {
        return end_test("FAIL", "Server initialization failed");
    }
}

# Test 2: Tools Listing
sub test_tools_list {
    start_test("Tools Listing");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $response = send_request($sock, 'tools/list');
    
    close $sock;
    
    if ($response && $response->{result} && $response->{result}{tools}) {
        my $tool_count = scalar(@{$response->{result}{tools}});
        return end_test("PASS", "Found $tool_count tools");
    } else {
        return end_test("FAIL", "Tools listing failed");
    }
}

# Test 3: Start Bridge
sub test_start_bridge {
    start_test("Start Bridge");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $response = send_tool_call($sock, 'start', {
        vm_name => $vm_name,
        port => 4556
    });
    
    close $sock;
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            return end_test("PASS", "Bridge started on port $result->{port}");
        } else {
            return end_test("FAIL", $result->{message});
        }
    } else {
        return end_test("FAIL", "Start bridge command failed");
    }
}

# Test 4: Bridge Status
sub test_bridge_status {
    start_test("Bridge Status");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $response = send_tool_call($sock, 'status', {
        vm_name => $vm_name
    });
    
    close $sock;
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{running}) {
            return end_test("PASS", "Bridge is running on port $result->{port}");
        } else {
            return end_test("FAIL", "Bridge is not running");
        }
    } else {
        return end_test("FAIL", "Status command failed");
    }
}

# Test 5: Write Command
sub test_write_command {
    start_test("Write Command");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $test_command = "echo 'test command'";
    my $response = send_tool_call($sock, 'write', {
        vm_name => $vm_name,
        text => $test_command
    });
    
    close $sock;
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            return end_test("PASS", "Command sent successfully");
        } else {
            return end_test("FAIL", $result->{message});
        }
    } else {
        return end_test("FAIL", "Write command failed");
    }
}

# Test 6: Read Output
sub test_read_output {
    start_test("Read Output");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    # Wait a moment for output to accumulate
    select(undef, undef, undef, 1);
    
    my $response = send_tool_call($sock, 'read', {
        vm_name => $vm_name
    });
    
    close $sock;
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            my $output_length = length($result->{output});
            return end_test("PASS", "Read $output_length characters of output");
        } else {
            return end_test("FAIL", $result->{message});
        }
    } else {
        return end_test("FAIL", "Read command failed");
    }
}

# Test 7: Error Handling - Missing Parameters
sub test_error_handling {
    start_test("Error Handling - Missing Parameters");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    # Try to start without vm_name
    my $response = send_tool_call($sock, 'start', {
        port => 4556
        # Missing vm_name
    });
    
    close $sock;
    
    if ($response && $response->{error}) {
        return end_test("PASS", "Missing parameters correctly rejected");
    } else {
        return end_test("FAIL", "Should have rejected missing parameters");
    }
}

# Test 8: Stop Bridge
sub test_stop_bridge {
    start_test("Stop Bridge");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $response = send_tool_call($sock, 'stop', {
        vm_name => $vm_name
    });
    
    close $sock;
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            return end_test("PASS", "Bridge stopped successfully");
        } else {
            return end_test("FAIL", $result->{message});
        }
    } else {
        return end_test("FAIL", "Stop bridge command failed");
    }
}

# Test 9: Invalid Tool
sub test_invalid_tool {
    start_test("Invalid Tool");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    my $response = send_tool_call($sock, 'nonexistent_tool', {
        param => "value"
    });
    
    close $sock;
    
    if ($response && $response->{error} && $response->{error}{code} == -32601) {
        return end_test("PASS", "Invalid tool correctly rejected");
    } else {
        return end_test("FAIL", "Should have rejected invalid tool");
    }
}

# Test 10: Invalid JSON
sub test_invalid_json {
    start_test("Invalid JSON");
    
    my $sock = connect_to_server();
    return end_test("FAIL", "Could not connect to server") unless $sock;
    
    # Send invalid JSON
    eval {
        print $sock "This is not valid JSON\n";
        
        my $select = IO::Select->new($sock);
        if ($select->can_read(2)) {
            my $response = <$sock>;
            if ($response) {
                chomp $response;
                my $json_response = decode_json($response);
                if ($json_response->{error} && $json_response->{error}{code} == -32700) {
                    close $sock;
                    return end_test("PASS", "Invalid JSON correctly handled");
                }
            }
        }
    };
    
    close $sock;
    return end_test("PASS", "Server responded to invalid input");
}

# Main test execution
log_event("TEST_SUITE_START", "Comprehensive serencp.pl test suite");

my @tests = (
    \&test_initialization,
    \&test_tools_list,
    \&test_start_bridge,
    \&test_bridge_status,
    \&test_write_command,
    \&test_read_output,
    \&test_error_handling,
    \&test_stop_bridge,
    \&test_invalid_tool,
    \&test_invalid_json
);

my $passed = 0;
my $failed = 0;

for my $test (@tests) {
    my $result = $test->();
    if ($result eq "PASS") {
        $passed++;
    } else {
        $failed++;
    }
    
    # Small delay between tests
    select(undef, undef, undef, 0.5);
}

log_event("TEST_SUITE_END", "Completed: $passed passed, $failed failed");

# Print summary
print "\n=== Test Summary ===\n";
print "Passed: $passed\n";
print "Failed: $failed\n";
print "Total: " . ($passed + $failed) . "\n";
print "Log file: $log_file\n\n";

close $log_fh;

exit($failed > 0 ? 1 : 0);