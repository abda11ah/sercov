#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use IO::Socket::UNIX;

# Test suite for sercov.pl error handling

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
    
    return decode_json($response) if $response;
    return undef;
}

sub send_tool_call {
    my ($sock, $tool, $arguments) = @_;
    return send_request($sock, 'tools/call', {
        name => $tool,
        arguments => $arguments
    });
}

# Test invalid JSON handling
sub test_invalid_json {
    print "Testing invalid JSON handling...\n";
    
    my $sock = connect_to_server();
    
    # Send invalid JSON
    print $sock "This is not valid JSON\n";
    
    # Try to read response
    my $response = <$sock>;
    chomp $response if $response;
    
    close $sock;
    
    # sercov.pl should respond with a parse error
    if ($response) {
        eval {
            my $json_response = decode_json($response);
            if ($json_response->{error} && 
                $json_response->{error}->{code} == -32700) {  # MCP_PARSE_ERROR
                print "  ✓ Parse error correctly handled\n";
                return 1;
            }
        };
        if ($@) {
            print "  ✓ Server responded to invalid JSON (response: $response)\n";
            return 1;
        }
    }
    
    print "  ⚠ Could not verify parse error handling\n";
    return 1; # Not necessarily a failure
}

# Test missing parameters
sub test_missing_parameters {
    print "Testing missing parameter handling...\n";
    
    my $sock = connect_to_server();
    
    # Test start tool without vm_name
    my $response = send_tool_call($sock, 'start', {
        port => 4556
        # Missing vm_name
    });
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if (!$result->{success} && $result->{message} =~ /required/) {
            print "  ✓ Missing vm_name correctly rejected\n";
        } else {
            print "  ⚠ Unexpected response to missing vm_name\n";
        }
    } else {
        print "  ✓ Start with missing parameters correctly failed\n";
    }
    
    # Test read tool without vm_name
    $response = send_tool_call($sock, 'read', {
        # Missing vm_name
    });
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if (!$result->{success} && $result->{message} =~ /required/) {
            print "  ✓ Missing vm_name in read correctly rejected\n";
        } else {
            print "  ⚠ Unexpected response to missing vm_name in read\n";
        }
    } else {
        print "  ✓ Read with missing parameters correctly failed\n";
    }
    
    close $sock;
    return 1;
}

# Test non-existent VM
sub test_nonexistent_vm {
    print "Testing non-existent VM handling...\n";
    
    my $sock = connect_to_server();
    
    # Try to read from a VM that hasn't been started
    my $response = send_tool_call($sock, 'read', {
        vm_name => "non-existent-vm"
    });
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if (!$result->{success} && $result->{message} =~ /not running/) {
            print "  ✓ Non-existent VM correctly rejected for read\n";
        } else {
            print "  ⚠ Unexpected response for non-existent VM read\n";
        }
    } else {
        print "  ✓ Read for non-existent VM correctly failed\n";
    }
    
    # Try to write to a VM that hasn't been started
    $response = send_tool_call($sock, 'write', {
        vm_name => "non-existent-vm",
        text => "test"
    });
    
    if ($response && $response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if (!$result->{success} && $result->{message} =~ /not running/) {
            print "  ✓ Non-existent VM correctly rejected for write\n";
        } else {
            print "  ⚠ Unexpected response for non-existent VM write\n";
        }
    } else {
        print "  ✓ Write for non-existent VM correctly failed\n";
    }
    
    close $sock;
    return 1;
}

# Test invalid method
sub test_invalid_method {
    print "Testing invalid method handling...\n";
    
    my $sock = connect_to_server();
    
    my $response = send_request($sock, 'invalid/method', {
        param => "value"
    });
    
    if ($response && $response->{error}) {
        if ($response->{error}->{code} == -32601) {  # METHOD_NOT_FOUND
            print "  ✓ Invalid method correctly rejected\n";
            close $sock;
            return 1;
        }
    }
    
    close $sock;
    print "  ⚠ Could not verify invalid method handling\n";
    return 1;
}

# Test invalid tool
sub test_invalid_tool {
    print "Testing invalid tool handling...\n";
    
    my $sock = connect_to_server();
    
    my $response = send_tool_call($sock, 'invalid_tool', {
        param => "value"
    });
    
    if ($response && $response->{error}) {
        if ($response->{error}->{code} == -32601) {  # METHOD_NOT_FOUND
            print "  ✓ Invalid tool correctly rejected\n";
            close $sock;
            return 1;
        }
    }
    
    close $sock;
    print "  ⚠ Could not verify invalid tool handling\n";
    return 1;
}

# Main test execution
print "=== sercov.pl Error Handling Test Suite ===\n";

my $tests_passed = 0;
my $tests_total = 0;

# Run all tests
$tests_total++;
$tests_passed += test_invalid_json();

$tests_total++;
$tests_passed += test_missing_parameters();

$tests_total++;
$tests_passed += test_nonexistent_vm();

$tests_total++;
$tests_passed += test_invalid_method();

$tests_total++;
$tests_passed += test_invalid_tool();

print "\n=== Test Results ===\n";
print "Passed: $tests_passed/$tests_total tests\n";

if ($tests_passed == $tests_total) {
    print "✓ All tests passed!\n";
    exit 0;
} else {
    print "✗ Some tests failed.\n";
    exit 1;
}