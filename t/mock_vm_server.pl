#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my $port = $ARGV[0] || 4555;
print "Mock VM Server starting on port $port\n";

my $server = IO::Socket::INET->new(
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 5,
    Reuse     => 1
) or die "Cannot create socket: $!\n";

print "Waiting for client connection...\n";
my $client = $server->accept();
print "Client connected!\n";

# Send boot sequence
my @boot_output = (
    "[    0.000000] Linux version 6.1.0-generic (mock\@build) (gcc version 12.2.0)",
    "[    0.001234] BIOS-provided physical RAM map:",
    "[    0.002345] BIOS-e820: [mem 0x0000000000000000-0x000000000009fbff] usable",
    "[    0.003456] Reserving Intel BIOS memory",
    "[    1.234567] ACPI: DSDT 0000000000000000 0002A (v02 BOCHS  BXPC 00000001 BXPC 00000001)",
    "[    2.345678] systemd[1]: Detected virtualization qemu.",
    "[    3.456789] systemd[1]: Starting system...",
    "[    4.567890] Welcome to Ubuntu 24.04 LTS!",
    "",
    "mock-vm login: "
);

for my $line (@boot_output) {
    sleep(0.1);
    $client->send($line . "\r\n");
}

# Interactive loop
my $select = IO::Select->new($client);
my $username = '';
my $password = '';
my $authenticated = 0;

while (1) {
    my @ready = $select->can_read(0.5);
    for my $fh (@ready) {
        my $buffer;
        my $bytes = sysread($fh, $buffer, 1024);
        if ($bytes > 0) {
            print "Received: $buffer";
            
            unless ($authenticated) {
                if ($username eq '') {
                    $username = $buffer;
                    $username =~ s/\s+$//;
                    $client->send("Password: ");
                } else {
                    $authenticated = 1;
                    $client->send("\r\n");
                    $client->send("Last login: " . localtime() . "\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                }
            } else {
                # Simulated commands
                $buffer =~ s/[\r\n]+$//;
                
                if ($buffer eq 'ls') {
                    $client->send("Desktop  Documents  Downloads  Pictures  Public  Templates  Videos\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                } elsif ($buffer eq 'uptime') {
                    $client->send(" 10:23:45 up 1 day,  2:34,  1 user,  load average: 0.15, 0.08, 0.05\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                } elsif ($buffer eq 'date') {
                    $client->send(scalar(localtime()) . "\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                } elsif ($buffer eq 'whoami') {
                    $client->send("mockuser\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                } elsif ($buffer eq 'top') {
                    $client->send("top - 10:23:45 up 1 day,  1 user,  load average: 0.15, 0.08, 0.05\r\n");
                    $client->send("Tasks:   5 total,   1 running,   4 sleeping,   0 stopped,   0 zombie\r\n");
                    $client->send("%Cpu(s):  2.3 us,  0.8 sy,  0.0 ni, 96.2 id,  0.7 wa,  0.0 hi,  0.0 si\r\n");
                    $client->send("MiB Mem:   2048.0 total,   512.0 free, 1024.0 used,   512.0 cache\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                } elsif ($buffer eq 'exit') {
                    $client->send("logout\r\n");
                    print "Client disconnected\n";
                    exit 0;
                } elsif ($buffer eq '') {
                    $client->send("\r\nmockuser\@mock-vm:~\$ ");
                } else {
                    $client->send("bash: $buffer: command not found\r\n");
                    $client->send("mockuser\@mock-vm:~\$ ");
                }
            }
        } else {
            print "Client disconnected\n";
            exit 0;
        }
    }
}
