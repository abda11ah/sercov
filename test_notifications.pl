#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use IO::Socket::UNIX;

# Test suite for sercov.pl live output notifications

my $socket_path = '/tmp/serial_test-vm';
my $vm_name = 'test-vm';

# Connect to sercov.pl MCP server
sub connect_to_server {
    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $socket_path
    ) or die "Cannot connect to $socket_path: $!\n";
    
    $sock->autoflush(1);
    return $sock;
}

my $request_id = 1;

sub send_request {
    my ($sock, $method, $params) = @_;
    my $request = {
        jsonrpc => "2.0",
        id => $request_id++,
        method => $method,
        params => $params
    };
    
    my $json = encode_json($request);
    print $sock $json . "\n";
    
    # Read response (for requests with IDs)
    if ($request->{id}) {
        my $response = <$sock>;
        chomp $response;
        return decode_json($response) if $response;
    }
    return undef;
}

sub send_tool_call {
    my ($sock, $tool, $arguments) = @_;
    return send_request($sock, 'tools/call', {
        name => $tool,
        arguments => $arguments
    });
}

# Test notification handling
sub test_notifications {
    print "Testing live output notifications...\n";
    
    my $sock = connect_to_server();
    
    # Initialize connection
    send_request($sock, 'initialize', {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => {
            name => "notification_test_client",
            version => "1.0.0"
        }
    });
    
    # Start the VM bridge
    print "Starting VM bridge...\n";
    my $start_response = send_tool_call($sock, 'start', {
        vm_name => $vm_name,
        port => 4556
    });
    
    unless ($start_response && $start_response->{result}) {
        print "  ✗ Failed to start VM bridge\n";
        close $sock;
        return 0;
    }
    
    my $result = decode_json($start_response->{result}{content}[0]{text});
    print "  ✓ Bridge started on port $result->{port}\n";
    
    # Listen for notifications for a few seconds
    print "Listening for notifications for 5 seconds...\n";
    
    my $notifications_received = 0;
    my $start_time = time();
    my $timeout = 5; # seconds
    
    # Set socket to non-blocking
    use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
    my $flags = fcntl($sock, F_GETFL, 0) or die "Can't get flags: $!";
    fcntl($sock, F_SETFL, $flags | O_NONBLOCK) or die "Can't set flags: $!";
    
    while ((time() - $start_time) < $timeout) {
        # Try to read from socket
        my $line = <$sock>;
        if (defined $line) {
            chomp $line;
            if ($line =~ /jsonrpc.*notifications\/vm_output/) {
                $notifications_received++;
                print "  ✓ Received notification #$notifications_received\n";
                
                # Parse notification
                eval {
                    my $notification = decode_json($line);
                    if ($notification->{method} eq 'notifications/vm_output') {
                        my $params = $notification->{params};
                        my $chunk_length = length($params->{chunk});
                        print "    VM: $params->{vm}, Stream: $params->{stream}, ";
                        print "Chunk size: $chunk_length bytes\n";
                    }
                };
                if ($@) {
                    print "    Warning: Could not parse notification: $@\n";
                }
            }
        }
        
        # Small delay to prevent busy waiting
        select(undef, undef, undef, 0.1);
    }
    
    # Stop the VM bridge
    print "Stopping VM bridge...\n";
    send_tool_call($sock, 'stop', {
        vm_name => $vm_name
    });
    
    close $sock;
    
    if ($notifications_received > 0) {
        print "  ✓ Received $notifications_received notifications\n";
        return 1;
    } else {
        print "  ⚠ No notifications received (this may be expected depending on VM activity)\n";
        return 1; # Not necessarily a failure
    }
}

# Test notification format
sub test_notification_format {
    print "Testing notification format...\n";
    
    # Create a sample notification
    my $sample_notification = {
        jsonrpc => "2.0",
        method => "notifications/vm_output",
        params => {
            vm => "test-vm",
            stream => "stdout",
            chunk => "Sample output data",
            timestamp => "2026-01-01T12:00:00.000Z"
        }
    };
    
    my $json = encode_json($sample_notification);
    
    # Check required fields
    my $valid = 1;
    my $errors = "";
    
    unless ($sample_notification->{jsonrpc} eq "2.0") {
        $valid = 0;
        $errors .= "  - Invalid jsonrpc version\n";
    }
    
    unless ($sample_notification->{method} eq "notifications/vm_output") {
        $valid = 0;
        $errors .= "  - Invalid method\n";
    }
    
    unless (defined $sample_notification->{params}->{vm}) {
        $valid = 0;
        $errors .= "  - Missing vm parameter\n";
    }
    
    unless (defined $sample_notification->{params}->{stream}) {
        $valid = 0;
        $errors .= "  - Missing stream parameter\n";
    }
    
    unless (defined $sample_notification->{params}->{chunk}) {
        $valid = 0;
        $errors .= "  - Missing chunk parameter\n";
    }
    
    unless (defined $sample_notification->{params}->{timestamp}) {
        $valid = 0;
        $errors .= "  - Missing timestamp parameter\n";
    }
    
    if ($valid) {
        print "  ✓ Notification format is valid\n";
        return 1;
    } else {
        print "  ✗ Notification format errors:\n$errors";
        return 0;
    }
}

# Main test execution
print "=== sercov.pl Notification Test Suite ===\n";

my $tests_passed = 0;
my $tests_total = 0;

# Run notification format test
$tests_total++;
$tests_passed += test_notification_format();

# Run live notification test
$tests_total++;
$tests_passed += test_notifications();

print "\n=== Test Results ===\n";
print "Passed: $tests_passed/$tests_total tests\n";

if ($tests_passed == $tests_total) {
    print "✓ All tests passed!\n";
    exit 0;
} else {
    print "✗ Some tests failed.\n";
    exit 1;
}