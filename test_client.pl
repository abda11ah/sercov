#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);
use Getopt::Long;

my $socket_path = '/tmp/serencp_test.sock';
my $vm_name = 'test-vm';
my $action = 'start'; # start, stop, status, read, write
my $text = '';
my $verbose = 0;

GetOptions(
    'socket=s' => \$socket_path,
    'vm=s' => \$vm_name,
    'action=s' => \$action,
    'text=s' => \$text,
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

print "Connecting to serencp.pl MCP server...\n";

# Initialize connection
my $init_response = send_request('initialize', {
    protocolVersion => "2024-11-05",
    capabilities => {},
    clientInfo => {
        name => "test_client",
        version => "1.0.0"
    }
});

print "Initialize response: " . encode_json($init_response) . "\n" if $verbose;

# Handle different actions
if ($action eq 'start') {
    print "Starting bridge for VM: $vm_name\n";
    my $response = send_tool_call('start', {
        vm_name => $vm_name,
        port => 4555
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        print "Bridge started successfully:\n";
        print "  Port: $result->{port}\n";
        print "  Socket: $result->{socket}\n";
        print "  Session ID: $result->{session_id}\n";
    } else {
        print "Failed to start bridge: " . encode_json($response->{error}) . "\n";
    }
    
} elsif ($action eq 'stop') {
    print "Stopping bridge for VM: $vm_name\n";
    my $response = send_tool_call('stop', {
        vm_name => $vm_name
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        print "Bridge stopped: $result->{message}\n";
    } else {
        print "Failed to stop bridge: " . encode_json($response->{error}) . "\n";
    }
    
} elsif ($action eq 'status') {
    print "Checking status for VM: $vm_name\n";
    my $response = send_tool_call('status', {
        vm_name => $vm_name
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        print "Bridge status:\n";
        print "  Running: " . ($result->{running} ? 'Yes' : 'No') . "\n";
        print "  Port: " . ($result->{port} || 'N/A') . "\n";
        print "  Buffer size: $result->{buffer_size} lines\n";
    } else {
        print "Failed to get status: " . encode_json($response->{error}) . "\n";
    }
    
} elsif ($action eq 'read') {
    print "Reading output from VM: $vm_name\n";
    my $response = send_tool_call('read', {
        vm_name => $vm_name
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        if ($result->{success}) {
            print "VM Output (including ANSI codes):\n";
            print "=" x 50 . "\n";
            print $result->{output};
            print "\n" . "=" x 50 . "\n";
            
            # Show raw bytes for analysis
            if ($verbose) {
                print "\nRaw bytes (hex):\n";
                my $output = $result->{output};
                for my $i (0 .. length($output) - 1) {
                    printf "%02x ", ord(substr($output, $i, 1));
                    print "\n" if (($i + 1) % 16 == 0);
                }
                print "\n";
            }
        } else {
            print "Failed to read: $result->{message}\n";
        }
    } else {
        print "Failed to read: " . encode_json($response->{error}) . "\n";
    }
    
} elsif ($action eq 'write') {
    if (!$text) {
        die "--text parameter required for write action\n";
    }
    print "Writing to VM: $vm_name\n";
    print "Text: $text\n";
    
    my $response = send_tool_call('write', {
        vm_name => $vm_name,
        text => $text
    });
    
    if ($response->{result}) {
        my $result = decode_json($response->{result}{content}[0]{text});
        print "Write result: $result->{message}\n";
    } else {
        print "Failed to write: " . encode_json($response->{error}) . "\n";
    }
    
} else {
    die "Unknown action: $action\n";
}

close $sock;
print "Test completed.\n";