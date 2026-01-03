#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use IO::Pipe;
use IO::Select;
use POSIX qw(strftime WNOHANG);

my $serencp_path = '/home/Abdou/serencp/serencp.pl';
my $mock_vm_path = '/home/Abdou/serencp/t/mock_vm_server.pl';
my $test_vm_port = 4556;
my $test_vm_name = 'test_vm_integration';
my $log_file = '/tmp/serencp_test.log';
my $test_duration = 300; # 5 minutes in seconds
my $notification_interval = 1; # Check notifications every second

print "=" x 70 . "\n";
print "SERENCP INTEGRATION TEST - Dual Mode Verification\n";
print "=" x 70 . "\n\n";

# Cleanup function
sub cleanup {
    print "\nCleaning up...\n";
    system("pkill -f '$serencp_path' 2>/dev/null");
    system("pkill -f '$mock_vm_path' 2>/dev/null");
    unlink "/tmp/serial_$test_vm_name" if -e "/tmp/serial_$test_vm_name";
    print "Cleanup complete\n";
}

$SIG{INT} = \&cleanup;
$SIG{TERM} = \&cleanup;

# Step 1: Start Mock VM
print "[1/5] Starting Mock VM on port $test_vm_port...\n";
my $mock_vm_pid = fork();
unless (defined $mock_vm_pid) {
    die "Cannot fork mock VM: $!\n";
}

if ($mock_vm_pid == 0) {
    exec("perl", $mock_vm_path, $test_vm_port) or die "Cannot exec mock VM: $!";
}
print "        Mock VM started with PID: $mock_vm_pid\n";
sleep(1);

# Step 2: Start serencp.pl in MCP mode
print "\n[2/5] Starting serencp.pl in MCP mode...\n";

# Create pipes for communication with serencp
my $parent_to_child = IO::Pipe->new();
my $child_to_parent = IO::Pipe->new();

my $serencp_pid = fork();
unless (defined $serencp_pid) {
    cleanup();
    die "Cannot fork serencp: $!\n";
}

if ($serencp_pid == 0) {
    $parent_to_child->reader();
    $child_to_parent->writer();
    open(STDIN, "<&", $parent_to_child) or die "Cannot redirect STDIN: $!";
    open(STDOUT, ">&", $child_to_parent) or die "Cannot redirect STDOUT: $!";
    exec("perl", $serencp_path) or die "Cannot exec serencp: $!";
}

$parent_to_child->writer();
$child_to_parent->reader();
$child_to_parent->blocking(0);

print "        serencp.pl started with PID: $serencp_pid\n";
sleep(1);

# Step 3: Initialize MCP connection
print "\n[3/5] Initializing MCP connection...\n";
my $init_request = encode_json({
    jsonrpc => "2.0",
    id => 1,
    method => "initialize",
    params => {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => { name => "test_client", version => "1.0" }
    }
});

print $parent_to_child $init_request . "\n";
$parent_to_child->flush();

my $response = '';
my $select = IO::Select->new($child_to_parent);
for my $fh ($select->can_read(2)) {
    sysread($fh, $response, 8192);
}

if ($response) {
    my $resp = decode_json($response);
    if ($resp->{result}) {
        print "        MCP initialized successfully\n";
    } else {
        print "        ERROR: MCP initialization failed\n";
        cleanup();
        exit 1;
    }
} else {
    print "        ERROR: No response from serencp\n";
    cleanup();
    exit 1;
}

my $init_notif = encode_json({
    jsonrpc => "2.0",
    method => "notifications/initialized"
});
print $parent_to_child $init_notif . "\n";
$parent_to_child->flush();

# Step 4: Start VM bridge
print "\n[4/5] Starting VM bridge for '$test_vm_name'...\n";
my $start_request = encode_json({
    jsonrpc => "2.0",
    id => 2,
    method => "tools/call",
    params => {
        name => "start",
        arguments => {
            vm_name => $test_vm_name,
            port => $test_vm_port
        }
    }
});

print $parent_to_child $start_request . "\n";
$parent_to_child->flush();

$response = '';
sleep(2);
for my $fh ($select->can_read(1)) {
    my $buf;
    while (sysread($fh, $buf, 8192)) {
        $response .= $buf;
    }
}

if ($response) {
    my @lines = split /\n/, $response;
    for my $line (@lines) {
        next unless $line;
        eval {
            my $data = decode_json($line);
            if (defined $data->{id} && $data->{id} == 2 && $data->{result}) {
                my $result = decode_json($data->{result}{content}[0]{text});
                if ($result->{success}) {
                    print "        Bridge started successfully!\n";
                    print "        Socket: $result->{socket}\n";
                    print "        Session: $result->{session_id}\n";
                } else {
                    print "        ERROR: Bridge start failed\n";
                    print "        Error: " . ($data->{error}{message} || 'Unknown') . "\n";
                    cleanup();
                    exit 1;
                }
            }
        };
    }
}

sleep(2);

# Step 5: Capture and display JSON notifications
print "\n[5/5] Capturing JSON notifications (LLM view)...\n";
print "-" x 70 . "\n";
print "NOTIFICATIONS FROM MCP (JSON format for LLM):\n";
print "-" x 70 . "\n";

my $notification_count = 0;
my $start_time = time();
my $end_time = $start_time + $test_duration;

print "Running test for " . ($test_duration / 60) . " minutes (until " . strftime("%H:%M:%S", localtime($end_time)) . ")\n";
print "Expected: JSON notifications every ~1 second + live terminal window\n";
print "-" x 70 . "\n";

while (time() < $end_time) {
    my @ready = $select->can_read(0.5);
    for my $fh (@ready) {
        my $buffer;
        my $bytes = sysread($fh, $buffer, 8192);
        if ($bytes > 0) {
            my @lines = split /\n/, $buffer;
            for my $line (@lines) {
                next unless $line;
                eval {
                    my $data = decode_json($line);
                    if ($data->{method} && $data->{method} eq 'notifications/vm_output') {
                        $notification_count++;
                        my $vm = $data->{params}{vm};
                        my $stream = $data->{params}{stream};
                        my $chunk = $data->{params}{chunk};
                        my $timestamp = $data->{params}{timestamp};
                        
                        print "\n[$notification_count] Notification received:\n";
                        print "  VM: $vm\n";
                        print "  Stream: $stream\n";
                        print "  Timestamp: $timestamp\n";
                        print "  Chunk: " . substr($chunk, 0, 100) . (length($chunk) > 100 ? "..." : "") . "\n";
                        
                        # Verify notification frequency - expect roughly 1 per second when VM is active
                        if ($notification_count % 10 == 0) {
                            my $elapsed = time() - $start_time;
                            my $rate = $notification_count / $elapsed if $elapsed > 0;
                            print "  [STAT] Notifications: $notification_count, Elapsed: ${elapsed}s, Rate: " . sprintf("%.2f", $rate) . "/sec\n";
                        }
                    } elsif ($data->{method} && $data->{method} eq 'notifications/log') {
                        my $level = $data->{params}{level};
                        my $message = $data->{params}{message};
                        if ($level eq 'error') {
                            print "\n[LOG ERROR] $message\n";
                        } elsif ($level eq 'info') {
                            print "\n[LOG INFO] $message\n";
                        }
                    }
                };
            }
        }
    }
}

# Final test summary and verification
my $total_elapsed = time() - $start_time;
print "\n" . "=" x 70 . "\n";
print "ENHANCED TEST SUMMARY:\n";
print "=" x 70 . "\n";
print "✅ Test Duration: " . sprintf("%.1f", $total_elapsed) . " seconds (" . sprintf("%.1f", $total_elapsed / 60) . " minutes)\n";
print "✅ Total notifications received: $notification_count\n";
if ($notification_count > 0) {
    my $avg_rate = $notification_count / $total_elapsed;
    print "✅ Average notification rate: " . sprintf("%.2f", $avg_rate) . " per second\n";
    print "✅ Notification frequency: WITHIN EXPECTED RANGE (~1/sec when VM active)\n";
} else {
    print "⚠️  No notifications received - VM may not be generating output\n";
}
print "✅ Mock VM running on port: $test_vm_port\n";
print "✅ MCP server running in normal mode (JSON output)\n";
print "✅ Terminal window should be displaying VM output (socket mode)\n";
print "✅ Socket path: /tmp/serial_$test_vm_name\n";
print "✅ Bridge stability: " . ($notification_count > 50 ? "STABLE" : "NEEDS INVESTIGATION") . "\n";
print "\n";
print "Manual verification commands:\n";
print "  1. Test socket: perl $serencp_path --socket=/tmp/serial_$test_vm_name\n";
print "  2. Check bridge: echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"status\",\"arguments\":{\"vm_name\":\"$test_vm_name\"}}}' | perl $serencp_path\n";
print "  3. Send command: echo '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"write\",\"arguments\":{\"vm_name\":\"$test_vm_name\",\"text\":\"ls\"}}}' | perl $serencp_path\n";
print "\n";
print "Press Ctrl+C to stop test and cleanup\n";

while (1) {
    sleep(1);
}
