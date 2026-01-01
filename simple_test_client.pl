#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);

# This script sends JSON-RPC requests to sercov.pl through STDIN/STDOUT
# It's designed to be run as part of a pipeline with sercov.pl

# Send initialize request
my $init_request = {
    jsonrpc => "2.0",
    id => 1,
    method => "initialize",
    params => {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => {
            name => "test_client",
            version => "1.0.0"
        }
    }
};

print encode_json($init_request) . "\n";

# Send tools/list request
my $list_request = {
    jsonrpc => "2.0",
    id => 2,
    method => "tools/list",
    params => {}
};

print encode_json($list_request) . "\n";

# Send start request
my $start_request = {
    jsonrpc => "2.0",
    id => 3,
    method => "tools/call",
    params => {
        name => "start",
        arguments => {
            vm_name => "test-vm",
            port => 4556
        }
    }
};

print encode_json($start_request) . "\n";

# Wait a bit for the VM to generate output
sleep(3);

# Send read request
my $read_request = {
    jsonrpc => "2.0",
    id => 4,
    method => "tools/call",
    params => {
        name => "read",
        arguments => {
            vm_name => "test-vm"
        }
    }
};

print encode_json($read_request) . "\n";

# Send stop request
my $stop_request = {
    jsonrpc => "2.0",
    id => 5,
    method => "tools/call",
    params => {
        name => "stop",
        arguments => {
            vm_name => "test-vm"
        }
    }
};

print encode_json($stop_request) . "\n";