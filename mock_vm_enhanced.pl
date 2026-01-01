#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use Time::HiRes qw(usleep gettimeofday);
use Getopt::Long;

# Enhanced mock VM server with deterministic output for testing

my $port = 4556;
my $scenario = 'test';
my $verbose = 0;
my $log_file = '/tmp/mock_vm_enhanced.log';

GetOptions(
    'port=i' => \$port,
    'scenario=s' => \$scenario,
    'verbose' => \$verbose,
    'log=s' => \$log_file,
);

# Open log file
open my $log_fh, '>>', $log_file or die "Cannot open log file $log_file: $!";
$| = 1; # Autoflush

sub log_vm_event {
    my ($event, $data) = @_;
    my $timestamp = gettimeofday();
    my $time_str = sprintf("%.3f", $timestamp);
    my $log_entry = "[$time_str] $event: " . (defined $data ? $data : '') . "\n";
    print $log_fh $log_entry;
    print $log_entry if $verbose;
}

log_vm_event("START", "Mock VM Server starting on port $port, scenario: $scenario");

my $server = IO::Socket::INET->new(
    LocalPort => $port,
    Proto => 'tcp',
    Listen => 5,
    Reuse => 1
) or die "Cannot create socket: $!\n";

log_vm_event("LISTENING", "Waiting for connection on port $port");

while (my $client = $server->accept()) {
    log_vm_event("CLIENT_CONNECTED", "Client connected");
    $client->autoflush(1);
    
    # Send welcome message
    print $client "Mock VM Server v1.0 - Scenario: $scenario\r\n";
    log_vm_event("SENT", "Welcome message");
    
    if ($scenario eq 'test' || $scenario eq 'all') {
        # Deterministic test output
        sleep(1);
        print $client "VM Boot Sequence Started\r\n";
        log_vm_event("SENT", "Boot sequence");
        
        sleep(1);
        print $client "Loading kernel modules...\r\n";
        log_vm_event("SENT", "Loading modules");
        
        sleep(1);
        print $client "Network interface eth0: UP\r\n";
        log_vm_event("SENT", "Network up");
        
        sleep(1);
        print $client "Login prompt ready\r\n";
        log_vm_event("SENT", "Login ready");
        
        # Wait for commands
        while (1) {
            my $input = <$client>;
            last unless defined $input;
            chomp $input;
            $input =~ s/\r$//;
            
            log_vm_event("RECEIVED", "Command: $input");
            
            if ($input eq 'exit') {
                print $client "Goodbye!\r\n";
                log_vm_event("SENT", "Goodbye");
                last;
            } elsif ($input eq 'ls') {
                print $client "bin  etc  home  lib  tmp  var\r\n";
                log_vm_event("SENT", "Directory listing");
            } elsif ($input eq 'help') {
                print $client "Available commands: ls, help, exit, test\r\n";
                log_vm_event("SENT", "Help");
            } elsif ($input eq 'test') {
                print $client "Test output line 1\r\n";
                sleep(0.5);
                print $client "Test output line 2\r\n";
                sleep(0.5);
                print $client "Test output line 3\r\n";
                log_vm_event("SENT", "Test output sequence");
            } else {
                print $client "Command not found: $input\r\n";
                log_vm_event("SENT", "Unknown command");
            }
        }
    }
    
    close $client;
    log_vm_event("CLIENT_DISCONNECTED", "Client disconnected");
}

close $server;
log_vm_event("STOP", "Mock VM Server stopped");
close $log_fh;