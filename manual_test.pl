#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);

# Send initialize request
my $init_request = {
    jsonrpc => "2.0",
    id => 1,
    method => "initialize",
    params => {
        protocolVersion => "2024-11-05",
        capabilities => {},
        clientInfo => {
            name => "manual_test",
            version => "1.0.0"
        }
    }
};

print encode_json($init_request) . "\n";

# Send start request
my $start_request = {
    jsonrpc => "2.0",
    id => 2,
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