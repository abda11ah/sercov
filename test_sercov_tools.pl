#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use IO::Socket::UNIX;

# Test suite for sercov.pl tools
# Tests start, stop, status, read, and write tools

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
    
    # Read response
    my $response = <$sock>;
    chomp $response;
    
    return decode_json($response);
}

sub send_tool_call {
    my ($sock, $tool, $arguments) = @_;
    return send_request($sock, 'tools/call', {
        name => $tool,
        arguments => $arguments
    });
}

# Test functions
sub test_initialize {
    my ($sock) = @_;
    print "Testing initialize...\n";
    
    my $response = send_request($sock, 'initialize', {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => {
            name => "test_client",
            version => "1.0.0"
        }
    });
    
    if ($response->{result}) {
        print "  ✓ Initialize successful\n";
        return 1;
    } else {
        print "  ✗ Initialize failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

sub test_tools_list {
    my ($sock) = @_;
    print "Testing tools/list...\n";
    
    my $response = send_request($sock, 'tools/list', {});
    
    if ($response->{result} && $response->{result}->{tools}) {
        my @tools = @{$response->{result}->{tools}};
        my %tool_names = map { $_->{name} => 1 } @tools;
        
        # Check that all expected tools are present
        my @expected_tools = qw(start stop status read write);
        my $all_present = 1;
        for my $tool (@expected_tools) {
            unless ($tool_names{$tool}) {
                print "  ✗ Missing tool: $tool\n";
                $all_present = 0;
            }
        }
        
        if ($all_present) {
            print "  ✓ tools/list successful - found " . scalar(@tools) . " tools\n";
            return 1;
        } else {
            print "  ✗ tools/list missing expected tools\n";
            return 0;
        }
    } else {
        print "  ✗ tools/list failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

sub test_start_tool {
    my ($sock) = @_;
    print "Testing start tool...\n";
    
    my $response = send_tool_call($sock, 'start', {
        vm_name => $vm_name,
        port => 4556
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            print "  ✓ Start tool successful\n";
            print "    Port: $result->{port}\n";
            print "    Socket: $result->{socket}\n";
            print "    Session ID: $result->{session_id}\n";
            return 1;
        } else {
            print "  ✗ Start tool failed: $result->{message}\n";
            return 0;
        }
    } else {
        print "  ✗ Start tool failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

sub test_status_tool {
    my ($sock) = @_;
    print "Testing status tool...\n";
    
    my $response = send_tool_call($sock, 'status', {
        vm_name => $vm_name
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if (defined $result->{running}) {
            print "  ✓ Status tool successful\n";
            print "    Running: " . ($result->{running} ? 'Yes' : 'No') . "\n";
            print "    Port: " . ($result->{port} || 'N/A') . "\n";
            print "    Buffer size: $result->{buffer_size} lines\n";
            return 1;
        } else {
            print "  ✗ Status tool returned unexpected result\n";
            return 0;
        }
    } else {
        print "  ✗ Status tool failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

sub test_write_tool {
    my ($sock) = @_;
    print "Testing write tool...\n";
    
    my $response = send_tool_call($sock, 'write', {
        vm_name => $vm_name,
        text => 'echo "Hello from test"'
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            print "  ✓ Write tool successful: $result->{message}\n";
            return 1;
        } else {
            print "  ✗ Write tool failed: $result->{message}\n";
            return 0;
        }
    } else {
        print "  ✗ Write tool failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

sub test_read_tool {
    my ($sock) = @_;
    print "Testing read tool...\n";
    
    # Wait a moment for any output to be generated
    sleep(1);
    
    my $response = send_tool_call($sock, 'read', {
        vm_name => $vm_name
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            my $output_length = length($result->{output});
            print "  ✓ Read tool successful\n";
            print "    Output length: $output_length characters\n";
            if ($output_length > 0) {
                print "    First 100 chars: " . substr($result->{output}, 0, 100) . "\n";
            }
            return 1;
        } else {
            print "  ✗ Read tool failed: $result->{message}\n";
            return 0;
        }
    } else {
        print "  ✗ Read tool failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

sub test_stop_tool {
    my ($sock) = @_;
    print "Testing stop tool...\n";
    
    my $response = send_tool_call($sock, 'stop', {
        vm_name => $vm_name
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            print "  ✓ Stop tool successful: $result->{message}\n";
            return 1;
        } else {
            print "  ✗ Stop tool failed: $result->{message}\n";
            return 0;
        }
    } else {
        print "  ✗ Stop tool failed: " . encode_json($response->{error}) . "\n";
        return 0;
    }
}

# Main test execution
print "=== sercov.pl Tool Test Suite ===\n";

my $sock = connect_to_server();
my $tests_passed = 0;
my $tests_total = 0;

# Run all tests
$tests_total++;
$tests_passed += test_initialize($sock);

$tests_total++;
$tests_passed += test_tools_list($sock);

$tests_total++;
$tests_passed += test_start_tool($sock);

$tests_total++;
$tests_passed += test_status_tool($sock);

$tests_total++;
$tests_passed += test_write_tool($sock);

$tests_total++;
$tests_passed += test_read_tool($sock);

$tests_total++;
$tests_passed += test_stop_tool($sock);

# Test status after stop
$tests_total++;
$tests_passed += test_status_tool($sock);

close $sock;

print "\n=== Test Results ===\n";
print "Passed: $tests_passed/$tests_total tests\n";

if ($tests_passed == $tests_total) {
    print "✓ All tests passed!\n";
    exit 0;
} else {
    print "✗ Some tests failed.\n";
    exit 1;
}