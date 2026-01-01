#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;

my $port = 4555;
my $delay = 1; # seconds between outputs
my $scenario = 'all';

GetOptions(
    'port=i' => \$port,
    'delay=i' => \$delay,
    'scenario=s' => \$scenario,
);

print "Mock VM Server starting on port $port...\n";
print "Scenario: $scenario\n";
print "Delay: ${delay}s between outputs\n\n";

my $server = IO::Socket::INET->new(
    LocalPort => $port,
    Proto => 'tcp',
    Listen => 5,
    Reuse => 1
) or die "Cannot create socket: $!\n";

print "Waiting for connection on port $port...\n";

while (my $client = $server->accept()) {
    print "Client connected!\n";
    $client->autoflush(1);
    
    # Send initial greeting
    print $client "Mock VM Server ready\r\n";
    
    if ($scenario eq 'all' || $scenario eq 'basic') {
        # Test basic ANSI color codes
        sleep($delay);
        print $client "\x1b[31mRed text\x1b[0m\r\n";
        
        sleep($delay);
        print $client "\x1b[32mGreen text\x1b[0m\r\n";
        
        sleep($delay);
        print $client "\x1b[33mYellow text\x1b[0m\r\n";
        
        sleep($delay);
        print $client "\x1b[34mBlue text\x1b[0m\r\n";
    }
    
    if ($scenario eq 'all' || $scenario eq 'complex') {
        # Test complex ANSI sequences
        sleep($delay);
        print $client "\x1b[1mBold\x1b[0m \x1b[4mUnderline\x1b[0m \x1b[7mInverse\x1b[0m\r\n";
        
        sleep($delay);
        print $client "\x1b[38;5;196mBright Red (256 color)\x1b[0m\r\n";
        
        sleep($delay);
        print $client "\x1b[48;5;226mYellow background\x1b[0m\r\n";
    }
    
    if ($scenario eq 'all' || $scenario eq 'cursor') {
        # Test cursor movement
        sleep($delay);
        print $client "Line 1\r\n";
        sleep($delay);
        print $client "Line 2\r\n";
        sleep($delay);
        print $client "\x1b[2ALine 2 overwritten\r\n";
        sleep($delay);
        print $client "\x1b[1BBack to normal\r\n";
    }
    
    if ($scenario eq 'all' || $scenario eq 'screen') {
        # Test screen clearing
        sleep($delay);
        print $client "\x1b[2J\x1b[HScreen cleared!\r\n";
        sleep($delay);
        print $client "Line after clear\r\n";
    }
    
    if ($scenario eq 'all' || $scenario eq 'progress') {
        # Simulate progress bar
        print $client "Progress: [";
        for my $i (0..10) {
            print $client "\x1b[42m \x1b[0m";
            sleep(0.5);
        }
        print $client "] Done!\r\n";
    }
    
    if ($scenario eq 'all' || $scenario eq 'mixed') {
        # Mixed content with ANSI and regular text
        sleep($delay);
        print $client "Normal text \x1b[35mPurple\x1b[0m more normal\r\n";
        sleep($delay);
        print $client "\x1b[1;32mBold Green\x1b[0m and \x1b[3;33mItalic Yellow\x1b[0m\r\n";
    }
    
    if ($scenario eq 'all' || $scenario eq 'error') {
        # Simulate error output
        sleep($delay);
        print $client "\x1b[31mError:\x1b[0m Something failed\r\n";
        sleep($delay);
        print $client "\x1b[33mWarning:\x1b[0m This is a warning\r\n";
    }
    
    # Keep connection open for interactive testing
    print $client "\r\nMock VM ready for commands (type 'exit' to quit): \r\n";
    
    while (1) {
        my $input = <$client>;
        last unless defined $input;
        chomp $input;
        $input =~ s/\r$//;
        
        if ($input eq 'exit') {
            print $client "Goodbye!\r\n";
            last;
        }
        
        # Echo back with some ANSI decoration
        print $client "\x1b[36mYou typed:\x1b[0m $input\r\n";
    }
    
    close $client;
    print "Client disconnected\n";
}

close $server;