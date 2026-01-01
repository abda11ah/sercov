#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(strftime);

# Mock VM Server with millisecond timestamp logging

my $port = 4557;
my $delay = 1; # seconds between outputs
my $scenario = 'all';
my $log_file = "logs/mock_vm_timestamped.log";
my $start_time = [gettimeofday()];

GetOptions(
    'port=i' => \$port,
    'delay=i' => \$delay,
    'scenario=s' => \$scenario,
    'log=s' => \$log_file,
);

# Create logs directory if it doesn't exist
system("mkdir -p logs");

# Log function with millisecond timestamps
sub log_event {
    my ($message, $level) = @_;
    $level ||= 'INFO';
    my $elapsed = tv_interval($start_time);
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $ms = sprintf("%03d", ($elapsed - int($elapsed)) * 1000);
    my $log_entry = sprintf("[%s.%s] [%s] %s\n", $timestamp, $ms, $level, $message);

    # Print to stdout for immediate feedback
    print $log_entry;

    # Also write to log file
    open(my $fh, ">>", $log_file) or die "Cannot open $log_file: $!";
    print $fh $log_entry;
    close($fh);
}

log_event("=== STARTING MOCK VM SERVER WITH TIMESTAMP LOGGING ===", 'INFO');
log_event("PORT: $port, DELAY: ${delay}s, SCENARIO: $scenario", 'INFO');

my $server = IO::Socket::INET->new(
    LocalPort => $port,
    Proto => 'tcp',
    Listen => 5,
    Reuse => 1
) or die "Cannot create socket: $!\n";

log_event("Mock VM Server listening on port $port", 'INFO');

my $connection_count = 0;

while (my $client = $server->accept()) {
    $connection_count++;
    log_event("CLIENT_CONNECTED: Connection #$connection_count from " . $client->peerhost(), 'INFO');
    $client->autoflush(1);

    # Send initial greeting
    my $greeting = "Mock VM Server ready (connection #$connection_count)\r\n";
    print $client $greeting;
    log_event("SENT: Initial greeting - $greeting", 'DEBUG');

    # Process scenarios
    if ($scenario eq 'all' || $scenario eq 'basic') {
        log_event("STARTING_SCENARIO: basic ANSI color codes", 'INFO');

        sleep($delay);
        my $msg1 = "\x1b[31mRed text\x1b[0m\r\n";
        print $client $msg1;
        log_event("SENT: Basic colors - Red text", 'DEBUG');

        sleep($delay);
        my $msg2 = "\x1b[32mGreen text\x1b[0m\r\n";
        print $client $msg2;
        log_event("SENT: Basic colors - Green text", 'DEBUG');

        sleep($delay);
        my $msg3 = "\x1b[33mYellow text\x1b[0m\r\n";
        print $client $msg3;
        log_event("SENT: Basic colors - Yellow text", 'DEBUG');

        sleep($delay);
        my $msg4 = "\x1b[34mBlue text\x1b[0m\r\n";
        print $client $msg4;
        log_event("SENT: Basic colors - Blue text", 'DEBUG');

        log_event("COMPLETED_SCENARIO: basic ANSI color codes", 'INFO');
    }

    if ($scenario eq 'all' || $scenario eq 'complex') {
        log_event("STARTING_SCENARIO: complex ANSI sequences", 'INFO');

        sleep($delay);
        my $msg1 = "\x1b[1mBold\x1b[0m \x1b[4mUnderline\x1b[0m \x1b[7mInverse\x1b[0m\r\n";
        print $client $msg1;
        log_event("SENT: Complex sequences - Bold/Underline/Inverse", 'DEBUG');

        sleep($delay);
        my $msg2 = "\x1b[38;5;196mBright Red (256 color)\x1b[0m\r\n";
        print $client $msg2;
        log_event("SENT: Complex sequences - 256 color foreground", 'DEBUG');

        sleep($delay);
        my $msg3 = "\x1b[48;5;226mYellow background\x1b[0m\r\n";
        print $client $msg3;
        log_event("SENT: Complex sequences - 256 color background", 'DEBUG');

        log_event("COMPLETED_SCENARIO: complex ANSI sequences", 'INFO');
    }

    if ($scenario eq 'all' || $scenario eq 'cursor') {
        log_event("STARTING_SCENARIO: cursor movement", 'INFO');

        sleep($delay);
        my $msg1 = "Line 1\r\n";
        print $client $msg1;
        log_event("SENT: Cursor movement - Line 1", 'DEBUG');

        sleep($delay);
        my $msg2 = "Line 2\r\n";
        print $client $msg2;
        log_event("SENT: Cursor movement - Line 2", 'DEBUG');

        sleep($delay);
        my $msg3 = "\x1b[2ALine 2 overwritten\r\n";
        print $client $msg3;
        log_event("SENT: Cursor movement - Overwrite line 2", 'DEBUG');

        sleep($delay);
        my $msg4 = "\x1b[1BBack to normal\r\n";
        print $client $msg4;
        log_event("SENT: Cursor movement - Back to normal", 'DEBUG');

        log_event("COMPLETED_SCENARIO: cursor movement", 'INFO');
    }

    if ($scenario eq 'all' || $scenario eq 'screen') {
        log_event("STARTING_SCENARIO: screen control", 'INFO');

        sleep($delay);
        my $msg1 = "\x1b[2J\x1b[HScreen cleared!\r\n";
        print $client $msg1;
        log_event("SENT: Screen control - Clear screen", 'DEBUG');

        sleep($delay);
        my $msg2 = "Line after clear\r\n";
        print $client $msg2;
        log_event("SENT: Screen control - Line after clear", 'DEBUG');

        log_event("COMPLETED_SCENARIO: screen control", 'INFO');
    }

    if ($scenario eq 'all' || $scenario eq 'progress') {
        log_event("STARTING_SCENARIO: progress bar simulation", 'INFO');

        my $progress_msg = "Progress: [";
        print $client $progress_msg;
        log_event("SENT: Progress bar start", 'DEBUG');

        for my $i (0..10) {
            my $block = "\x1b[42m \x1b[0m";
            print $client $block;
            log_event("SENT: Progress bar block $i/10", 'DEBUG');
            sleep(0.5);
        }

        my $end_msg = "] Done!\r\n";
        print $client $end_msg;
        log_event("SENT: Progress bar complete", 'DEBUG');

        log_event("COMPLETED_SCENARIO: progress bar simulation", 'INFO');
    }

    if ($scenario eq 'all' || $scenario eq 'mixed') {
        log_event("STARTING_SCENARIO: mixed content", 'INFO');

        sleep($delay);
        my $msg1 = "Normal text \x1b[35mPurple\x1b[0m more normal\r\n";
        print $client $msg1;
        log_event("SENT: Mixed content - Normal with purple", 'DEBUG');

        sleep($delay);
        my $msg2 = "\x1b[1;32mBold Green\x1b[0m and \x1b[3;33mItalic Yellow\x1b[0m\r\n";
        print $client $msg2;
        log_event("SENT: Mixed content - Bold green and italic yellow", 'DEBUG');

        log_event("COMPLETED_SCENARIO: mixed content", 'INFO');
    }

    if ($scenario eq 'all' || $scenario eq 'error') {
        log_event("STARTING_SCENARIO: error simulation", 'INFO');

        sleep($delay);
        my $msg1 = "\x1b[31mError:\x1b[0m Something failed\r\n";
        print $client $msg1;
        log_event("SENT: Error simulation - Error message", 'DEBUG');

        sleep($delay);
        my $msg2 = "\x1b[33mWarning:\x1b[0m This is a warning\r\n";
        print $client $msg2;
        log_event("SENT: Error simulation - Warning message", 'DEBUG');

        log_event("COMPLETED_SCENARIO: error simulation", 'INFO');
    }

    # Interactive mode
    my $prompt = "\r\nMock VM ready for commands (type 'exit' to quit): \r\n";
    print $client $prompt;
    log_event("ENTERING_INTERACTIVE_MODE: Ready for commands", 'INFO');

    my $command_count = 0;
    while (1) {
        my $input = <$client>;
        last unless defined $input;
        chomp $input;
        $input =~ s/\r$//;

        $command_count++;
        log_event("RECEIVED_COMMAND: #$command_count - '$input'", 'DEBUG');

        if ($input eq 'exit') {
            my $bye_msg = "Goodbye!\r\n";
            print $client $bye_msg;
            log_event("SENT: Goodbye message", 'DEBUG');
            last;
        }

        # Echo back with some ANSI decoration
        my $response = "\x1b[36mYou typed:\x1b[0m $input\r\n";
        print $client $response;
        log_event("SENT: Echo response for command #$command_count", 'DEBUG');
    }

    close $client;
    log_event("CLIENT_DISCONNECTED: Connection #$connection_count ended", 'INFO');
}

close $server;
log_event("=== MOCK VM SERVER SHUTDOWN ===", 'INFO');