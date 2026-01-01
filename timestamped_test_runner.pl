#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(strftime);

# Enhanced test runner with millisecond timestamps for event logging

my $start_time = [gettimeofday()];
my $log_file = "logs/timestamped_test.log";

# Create logs directory if it doesn't exist
system("mkdir -p logs");

# Log function with millisecond timestamps
sub log_event {
    my ($message) = @_;
    my $elapsed = tv_interval($start_time);
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $ms = sprintf("%03d", ($elapsed - int($elapsed)) * 1000);
    my $log_entry = sprintf("[%s.%s] %s\n", $timestamp, $ms, $message);
    
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
    log_event("SEND: $json");
    print STDOUT $json . "\n";
    STDOUT->flush();
    
    # Read response from STDIN
    my $response_line = <STDIN>;
    chomp $response_line;
    
    if ($response_line) {
        log_event("RECV: $response_line");
        return decode_json($response_line);
    }
    
    return undef;
}

sub send_tool_call {
    my ($tool, $arguments) = @_;
    return send_request('tools/call', {
        name => $tool,
        arguments => $arguments
    });
}

# Start testing
log_event("=== Starting sercov.pl Timestamped Test Suite ===");

# Initialize connection
log_event("Sending initialize request");
my $init_response = send_request('initialize', {
    protocolVersion => "2024-11-05",
    capabilities => {},
    clientInfo => {
        name => "timestamped_test_runner",
        version => "1.0.0"
    }
});

if ($init_response && $init_response->{result}) {
    log_event("SUCCESS: Initialize request completed");
} else {
    log_event("ERROR: Initialize request failed");
    exit 1;
}

# List tools
log_event("Sending tools/list request");
my $list_response = send_request('tools/list', {});

if ($list_response && $list_response->{result}) {
    log_event("SUCCESS: tools/list request completed");
    my @tools = @{$list_response->{result}->{tools}};
    log_event("AVAILABLE TOOLS: " . join(", ", map { $_->{name} } @tools));
} else {
    log_event("ERROR: tools/list request failed");
    exit 1;
}

# Start VM bridge
log_event("Starting VM bridge for test-vm on port 4556");
my $start_response = send_tool_call('start', {
    vm_name => 'test-vm',
    port => 4556
});

if ($start_response && $start_response->{result}) {
    my $result = decode_json($start_response->{result}{content}[0]{text});
    if ($result->{success}) {
        log_event("SUCCESS: Bridge started");
        log_event("PORT: $result->{port}");
        log_event("SOCKET: $result->{socket}");
        log_event("SESSION_ID: $result->{session_id}");
    } else {
        log_event("ERROR: Bridge start failed - $result->{message}");
        exit 1;
    }
} else {
    log_event("ERROR: Bridge start request failed");
    exit 1;
}

# Check status
log_event("Checking VM status");
my $status_response = send_tool_call('status', {
    vm_name => 'test-vm'
});

if ($status_response && $status_response->{result}) {
    my $result = decode_json($status_response->{result}{content}[0]{text});
    log_event("SUCCESS: Status check completed");
    log_event("RUNNING: " . ($result->{running} ? 'Yes' : 'No'));
    log_event("PORT: " . ($result->{port} || 'N/A'));
    log_event("BUFFER_SIZE: $result->{buffer_size} lines");
} else {
    log_event("ERROR: Status check failed");
}

# Wait for VM output (10 seconds to allow mock VM to generate output)
log_event("Waiting 10 seconds for VM output generation");
sleep(10);

# Read output
log_event("Reading VM output");
my $read_response = send_tool_call('read', {
    vm_name => 'test-vm'
});

if ($read_response && $read_response->{result}) {
    my $result = decode_json($read_response->{result}{content}[0]{text});
    if ($result->{success}) {
        my $output_length = length($result->{output});
        log_event("SUCCESS: Read operation completed");
        log_event("OUTPUT_LENGTH: $output_length characters");
        if ($output_length > 0) {
            # Show first 200 characters of output
            my $preview = substr($result->{output}, 0, 200);
            $preview =~ s/\r/\\r/g;
            $preview =~ s/\n/\\n/g;
            log_event("OUTPUT_PREVIEW: $preview");
            
            # Count ANSI sequences
            my $ansi_count = () = $result->{output} =~ /\x1b\[/g;
            log_event("ANSI_SEQUENCES_FOUND: $ansi_count");
        }
    } else {
        log_event("ERROR: Read failed - $result->{message}");
    }
} else {
    log_event("ERROR: Read request failed");
}

# Write a command
log_event("Sending command to VM: echo 'Hello from sercov test'");
my $write_response = send_tool_call('write', {
    vm_name => 'test-vm',
    text => 'echo "Hello from sercov test"'
});

if ($write_response && $write_response->{result}) {
    my $result = decode_json($write_response->{result}{content}[0]{text});
    if ($result->{success}) {
        log_event("SUCCESS: Write operation completed - $result->{message}");
    } else {
        log_event("ERROR: Write failed - $result->{message}");
    }
} else {
    log_event("ERROR: Write request failed");
}

# Wait a moment for the command to execute
log_event("Waiting 3 seconds for command execution");
sleep(3);

# Read output again to see command result
log_event("Reading VM output after command execution");
my $read_response2 = send_tool_call('read', {
    vm_name => 'test-vm'
});

if ($read_response2 && $read_response2->{result}) {
    my $result = decode_json($read_response2->{result}{content}[0]{text});
    if ($result->{success}) {
        my $output_length = length($result->{output});
        log_event("SUCCESS: Second read operation completed");
        log_event("OUTPUT_LENGTH: $output_length characters");
        if ($output_length > 0) {
            # Show first 200 characters of output
            my $preview = substr($result->{output}, 0, 200);
            $preview =~ s/\r/\\r/g;
            $preview =~ s/\n/\\n/g;
            log_event("OUTPUT_PREVIEW: $preview");
        }
    } else {
        log_event("ERROR: Second read failed - $result->{message}");
    }
} else {
    log_event("ERROR: Second read request failed");
}

# Stop VM bridge
log_event("Stopping VM bridge");
my $stop_response = send_tool_call('stop', {
    vm_name => 'test-vm'
});

if ($stop_response && $stop_response->{result}) {
    my $result = decode_json($stop_response->{result}{content}[0]{text});
    if ($result->{success}) {
        log_event("SUCCESS: Bridge stopped - $result->{message}");
    } else {
        log_event("ERROR: Bridge stop failed - $result->{message}");
    }
} else {
    log_event("ERROR: Bridge stop request failed");
}

# Final status check
log_event("Checking final VM status");
my $final_status_response = send_tool_call('status', {
    vm_name => 'test-vm'
});

if ($final_status_response && $final_status_response->{result}) {
    my $result = decode_json($final_status_response->{result}{content}[0]{text});
    log_event("SUCCESS: Final status check completed");
    log_event("RUNNING: " . ($result->{running} ? 'Yes' : 'No'));
} else {
    log_event("ERROR: Final status check failed");
}

log_event("=== Test Runner Complete ===");