#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);
use Getopt::Long;

my $socket_path = '/tmp/serial_test-vm';
my $vm_name = 'test-vm';
my $scenario = 'all';
my $verbose = 0;

GetOptions(
    'socket=s' => \$socket_path,
    'vm=s' => \$vm_name,
    'scenario=s' => \$scenario,
    'verbose' => \$verbose,
);

# Connect to serencp.pl MCP server
my $sock = IO::Socket::UNIX->new(
    Type => SOCK_STREAM,
    Peer => $socket_path
) or die "Cannot connect to $socket_path: $!\n";

$sock->autoflush(1);

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
    print $sock $json . "\n";
    print "Sent: $json\n" if $verbose;
    
    # Read response
    my $response = <$sock>;
    chomp $response;
    print "Received: $response\n" if $verbose;
    
    return decode_json($response);
}

sub send_tool_call {
    my ($tool, $arguments) = @_;
    return send_request('tools/call', {
        name => $tool,
        arguments => $arguments
    });
}

print "=== ANSI Escape Code Test Runner ===\n";
print "Connecting to serencp.pl MCP server...\n\n";

# Initialize connection
my $init_response = send_request('initialize', {
    protocolVersion => "2024-11-05",
    capabilities => {},
    clientInfo => {
        name => "test_runner",
        version => "1.0.0"
    }
});

if ($scenario) {
    print "Running scenario: $scenario\n\n";
    
    if ($scenario eq 'basic_colors') {
        # Test basic color ANSI codes
        print "=== Test 1: Basic Colors ===\n";
        my $response = send_tool_call('start', { vm_name => $vm_name, port => 4556 });
        if ($response->{result}) {
            print "Bridge started. Waiting for ANSI color output...\n";
            sleep(2);
            
            # Read and display the output with ANSI codes
            my $read_response = send_tool_call('read', { vm_name => $vm_name });
            if ($read_response->{result}) {
                my $result = decode_json($read_response->{result}{content}[0]{text});
                show_ansi_analysis($result->{output});
            }
        }
        
    } elsif ($scenario eq 'complex_sequences') {
        # Test complex ANSI sequences
        print "=== Test 2: Complex ANSI Sequences ===\n";
        my $response = send_tool_call('start', { vm_name => $vm_name, port => 4556 });
        if ($response->{result}) {
            print "Bridge started. Waiting for complex ANSI sequences...\n";
            sleep(3);
            
            my $read_response = send_tool_call('read', { vm_name => $vm_name });
            if ($read_response->{result}) {
                my $result = decode_json($read_response->{result}{content}[0]{text});
                show_ansi_analysis($result->{output});
            }
        }
        
    } elsif ($scenario eq 'cursor_movement') {
        # Test cursor movement codes
        print "=== Test 3: Cursor Movement ===\n";
        my $response = send_tool_call('start', { vm_name => $vm_name, port => 4556 });
        if ($response->{result}) {
            print "Bridge started. Waiting for cursor movement sequences...\n";
            sleep(2);
            
            my $read_response = send_tool_call('read', { vm_name => $vm_name });
            if ($read_response->{result}) {
                my $result = decode_json($read_response->{result}{content}[0]{text});
                show_ansi_analysis($result->{output});
            }
        }
        
    } elsif ($scenario eq 'all' || $scenario eq 'full') {
        # Run all tests
        print "=== Running All ANSI Tests ===\n";
        
        # Start bridge
        my $response = send_tool_call('start', { vm_name => $vm_name, port => 4556 });
        if ($response->{result}) {
            print "Bridge started. Running tests...\n\n";
            
            # Wait for various ANSI output
            sleep(5);
            
            # Read and analyze
            my $read_response = send_tool_call('read', { vm_name => $vm_name });
            if ($read_response->{result}) {
                my $result = decode_json($read_response->{result}{content}[0]{text});
                show_ansi_analysis($result->{output});
            }
        }
        
        # Test write with ANSI
        print "\n=== Test: Writing with ANSI Response ===\n";
        my $write_response = send_tool_call('write', { 
            vm_name => $vm_name, 
            text => 'test command' 
        });
        
        if ($write_response->{result}) {
            sleep(1);
            my $read_response = send_tool_call('read', { vm_name => $vm_name });
            if ($read_response->{result}) {
                my $result = decode_json($read_response->{result}{content}[0]{text});
                show_ansi_analysis($result->{output});
            }
        }
        
        # Cleanup
        send_tool_call('stop', { vm_name => $vm_name });
        
    } else {
        die "Unknown scenario: $scenario\n";
    }
} else {
    # Run in interactive mode
    print "\nInteractive mode - watching for VM output notifications...\n";
    print "Press Ctrl+C to stop.\n\n";
    
    while (1) {
        my $line = <$sock>;
        last unless defined $line;
        chomp $line;
        
        if ($line =~ /jsonrpc.*notifications\/vm_output/) {
            if ($line =~ /"chunk":"([^"]*)"/) {
                my $chunk = $1;
                # Show the raw chunk with visible escape sequences
                my $visible = $chunk;
                $visible =~ s/\x1b/ESC/g;
                $visible =~ s/\r/\\r/g;
                $visible =~ s/\n/\\n/g;
                
                print "[NOTIFICATION] " . scalar(localtime()) . "\n";
                print "Raw chunk: $visible\n";
                
                # Show hex dump of control characters
                if ($visible =~ /ESC/) {
                    print "Hex dump: ";
                    for my $i (0 .. length($chunk) - 1) {
                        my $byte = ord(substr($chunk, $i, 1));
                        if ($byte == 0x1b) {
                            printf "[ESC]";
                        } elsif ($byte >= 0x20 && $byte <= 0x7E) {
                            printf "%c", $byte;
                        } else {
                            printf "[%02x]", $byte;
                        }
                    }
                    print "\n";
                }
                print "\n";
            }
        }
    }
}

close $sock;

sub show_ansi_analysis {
    my ($output) = @_;
    
    print "Raw output (with visible escape sequences):\n";
    print "-" x 60 . "\n";
    
    my $visible = $output;
    $visible =~ s/\x1b/ESC/g;
    $visible =~ s/\r/\\r/g;
    $visible =~ s/\n/\\n/g;
    print $visible;
    
    print "\n" . "-" x 60 . "\n";
    
    # Count ANSI sequences
    my $ansi_count = () = $output =~ /\x1b\[/g;
    print "ANSI sequences found: $ansi_count\n";
    
    # Show hex dump if verbose
    if ($verbose) {
        print "\nHex dump (first 200 bytes):\n";
        my $length = length($output) > 200 ? 200 : length($output);
        for my $i (0 .. $length - 1) {
            my $byte = ord(substr($output, $i, 1));
            if ($byte == 0x1b) {
                printf "[ESC]";
            } elsif ($byte >= 0x20 && $byte <= 0x7E) {
                printf "%c", $byte;
            } elsif ($byte == 0x0d) {
                printf "[CR]";
            } elsif ($byte == 0x0a) {
                printf "[LF]";
            } else {
                printf "[%02x]", $byte;
            }
            print " " if ($i + 1) % 16 == 0;
        }
        print "\n";
    }
}

print "\nTest completed.\n";