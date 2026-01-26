#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode qw(decode_utf8 encode);
use JSON::PP qw(decode_json encode_json);
use IO::Socket::UNIX;
use IO::Pty;
use IO::Select;
use POSIX qw(:termios_h strftime WNOHANG setsid TCSANOW ECHO ECHOK ECHOE ICANON);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IPC::Cmd qw(can_run);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Getopt::Long;
our %options;
GetOptions(\%options,'socket=s',) or exit 1;
# --- Internal Unix-socket client mode ---
if ($options{'socket'}) {
	my $socket_path = $options{'socket'};
	if (!$socket_path) {
		print STDERR "Missing socket path\n";
		exit 1;
	}
	run_unix_socket_client($socket_path);
	exit 0;
}
# Configuration
our $VERSION           = "1.0.1";
our $PROTOCOL_VERSION  = "2025-06-18";
our $DEFAULT_VM_PORT   = 4555;
our $RING_BUFFER_SIZE  = 1000;
our $MAX_BUFFER_BYTES  = 10 * 1024 * 1024;  # 10MB per VM
our $CONSOLE_HISTORY_LINES = 60;  # Lines of history to send to new console clients
our $DEBUG             = 0;  # Enable debug output
# Cleanup timeout configuration
our $SIGTERM_TIMEOUT   = 5;   # Seconds to wait for SIGTERM to work
our $SIGKILL_WAIT      = 1;   # Seconds to wait after SIGKILL
our $READ_TIMEOUT      = 10;  # Seconds to wait for read operation
# Simplified defaults for LLM use
# MCP Error Constants
use constant {
	# JSON-RPC 2.0 standard errors
	MCP_PARSE_ERROR      => -32700,
	MCP_INVALID_REQUEST  => -32600,
	MCP_METHOD_NOT_FOUND => -32601,
	MCP_INVALID_PARAMS   => -32602,
	MCP_INTERNAL_ERROR   => -32603,
	# MCP-specific errors (-32000 to -32099)
	MCP_SERVER_ERROR          => -32000,
	MCP_RESOURCE_NOT_FOUND    => -32001,
	MCP_TOOL_EXECUTION_FAILED => -32002,
	MCP_PERMISSION_DENIED     => -32003,
	MCP_RATE_LIMITED          => -32004,
	MCP_VALIDATION_ERROR      => -32005,
	# Custom MCP errors
	MCP_PROMPT_TOO_LARGE      => -32010,
	MCP_CONTEXT_TOO_LARGE     => -32011,
	MCP_UNSUPPORTED_FORMAT    => -32012,
	# Log Levels
	MCP_LOG_LEVEL_DEBUG     => 'debug',
	MCP_LOG_LEVEL_INFO      => 'info',
	MCP_LOG_LEVEL_ERROR     => 'error',
};
# OS Compatibiltiy Check
if ($^O !~ /^(linux|darwin|freebsd|openbsd|netbsd|solaris|aix|cygwin|dragonfly|midnightbsd|gnu|haiku|hpux|irix|minix|qnx|sco|sysv|unix)/i) {
	print mcp_error(undef, MCP_SERVER_ERROR, "Unsupported Operating System: $^O. This server only runs on *nix-like systems.") . "\n";
	exit 1;
}
# Global state
our %bridges;
our $running = 1;
our $PARENT_PID = $$;
# Main MCP select - handles only STDIN for JSON-RPC requests
my $mcp_select = IO::Select->new(\*STDIN);
# Terminal detection and spawning helpers
our $term = sub {
	# macOS Terminal.app detection - early return for efficiency
	if ($^O eq 'darwin') {
		return ['terminal-macos', sub { "open -a Terminal \"$_[0]\"" }]
			if -d "/Applications/Terminal.app";
		return ['iterm-macos', sub { "open -a iTerm \"$_[0]\"" }]
			if -d "/Applications/iTerm.app";
	}
	# Define terminals in order of preference for better selection
	my @terminals = (
		[gnome      => [ 'gnome-terminal', '-- sh -c' ]],
		[konsole    => [ 'konsole',        '-e' ]],
		[terminator => [ 'terminator',     '-e' ]],
		[guake      => [ 'guake',          '-e' ]],
		[tilix      => [ 'tilix',          '-e' ]],
		[alacritty  => [ 'alacritty',      '-e' ]],
		[kitty      => [ 'kitty',          sub { "kitty $_[0]" } ]],
		[xfce4      => [ 'xfce4-terminal', '--command' ]],
		[lxterminal => [ 'lxterminal',     '--command' ]],
		[deepin     => [ 'deepin-terminal','-x' ]],
		[mate       => [ 'mate-terminal',  '--command' ]],
		[qterminal  => [ 'qterminal',      '-e' ]],
		[wezterm    => [ 'wezterm',        sub { "wezterm start -- $_[0]" } ]],
		[ghostty    => [ 'ghostty',        '-e' ]],
		[xterm      => [ 'xterm',          '-e' ]],
		[urxvt      => [ 'urxvt',          '-e' ]],
	);
	# Return first available terminal - optimized loop
	for my $terminal (@terminals) {
		my (undef, $config) = @$terminal;
		return $config if can_run($config->[0]);
	}
	undef; # Explicit undef return for clarity
	}
	->();
# Tool definitions
my %TOOLS = (
	start => {
		description => "Start the bridge for VM serial console communication.",
		inputSchema => {
			type       => "object",
			properties => {vm_name => {type        => "string",description => "Name of the VM"},port => {type        => "string",description => "Port number for VM serial console (default: 4555)"}},
			required => ["vm_name"]
		},
		handler => \&tool_start
	},
	stop => {
		description => "Stop the bridge.",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM"}},required => ["vm_name"]},
		handler => \&tool_stop
	},
	status => {
		description => "Check the status of the bridge.",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM"}},required => ["vm_name"]},
		handler => \&tool_status
	},
	read => {
		description => "Read output from VM serial console (20s timeout).",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM"}},required => ["vm_name"]},
		handler => \&tool_read
	},
	write => {
		description => "Send a command to the VM serial console.",
		inputSchema => {
			type       => "object",
			properties => {vm_name => {type        => "string",description => "Name of the VM"},text => {type        => "string",description => "Command to send to the VM"}},
			required => [ "vm_name", "text" ]
		},
		handler => \&tool_write
	}
);
# Run MCP server
start_mcp_server() unless caller;
# Helper for ISO8601 timestamps
sub iso8601 {
	return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime);
}
# Debug output function
sub debug {
	my ($message) = @_;
	return unless $DEBUG;
	# Only the parent process should send notifications to STDOUT
	if ($$ != $PARENT_PID) {
		# In child processes, send to STDERR to avoid corrupting MCP STDOUT
		printf STDERR "[DEBUG %d] %s\n", $$, $message;
		return;
	}
	my $log_entry = {jsonrpc => "2.0",method  => "notifications/message",params  => {level  => MCP_LOG_LEVEL_DEBUG,logger => "serencp",message => $message,data   => $message || {}}};
	# Send to STDOUT for MCP clients to see.
	# Using $|=1 (autoflush) which is already set.
	print STDOUT encode_json($log_entry) . "\n";
}
# Send VM output notification automatically
sub send_json_notification {
	my ($vm_name, $stream, $chunk) = @_;
	# Always send notifications for any VM bridge that exists
	# This provides automatic VM output streaming when bridge is active
	my $bridge = $bridges{$vm_name};
	return unless $bridge;
	# Keep raw binary mode - don't decode UTF-8, pass through all characters as-is
	my $chunk_copy = $chunk;
	# PTY is in raw binary mode, so $chunk_copy contains raw bytes
	# Use notifications/tool_stream for MCP compatibility
	my $notification
		= {jsonrpc => "2.0",method  => "notifications/tool_stream",params  => {toolName => "serencp/$vm_name",content  => [ { type => "text", text => $chunk_copy } ],isError  => JSON::PP::false}};
	print STDOUT encode_json($notification) . "\n";
	# Use notifications/message for better client compatibility
	my $log_notification = {
		jsonrpc => "2.0",
		method  => "notifications/message",
		params  => {level  => MCP_LOG_LEVEL_INFO,logger => "serencp",message => $chunk_copy,data   => { vm_name => $vm_name, output => $chunk_copy }}
	};
	print STDOUT encode_json($log_notification) . "\n";
	debug("Sent VM output notification for $vm_name ($stream): " . length($chunk) . " bytes");
}
# Send progress notification
sub send_progress {
	my ($token, $progress, $total, $message) = @_;
	my $notification = {jsonrpc => "2.0",method  => "notifications/progress",params  => {progressToken => $token,progress => $progress,total => $total,message => $message}};
	print STDOUT encode_json($notification) . "\n";
}
# Error helper that returns JSON string
sub mcp_error {
	my ($id, $code, $message, $data) = @_;
	my $error_response = {jsonrpc => "2.0",id      => $id,error   => {code    => $code,message => $message,}};
	# Add data if provided (must be JSON-serializable)
	if ($data) {
		$error_response->{error}{data} = $data;
	}
	return encode_json($error_response);
}
# Start the MCP server
sub start_mcp_server {
	local $SIG{INT}  = \&cleanup;
	local $SIG{TERM} = \&cleanup;
	local $SIG{CHLD} = sub {
		while (waitpid(-1, WNOHANG) > 0) { }
	};
	# Removed UTF-8 encoding for MCP compatibility - JSON is already UTF-8
	binmode(STDIN);
	binmode(STDOUT);
	local $| = 1;    # Autoflush
	 # --- Reliable non‑blocking STDIN ---
	my $flags = fcntl(STDIN, F_GETFL, 0)
		or do {
		debug("Can't get flags for STDIN: $!");
		print mcp_error(undef, MCP_INTERNAL_ERROR, "Can't get flags for STDIN: $!") . "\n";
		exit(1);
		};
	fcntl(STDIN, F_SETFL, $flags | O_NONBLOCK)
		or do {
		debug("Can't set STDIN nonblocking: $!");
		print mcp_error(undef, MCP_INTERNAL_ERROR, "Can't set STDIN nonblocking: $!") . "\n";
		exit(1);
		};
	debug("Starting $0 MCP Server...");
	while ($running) {
		# Handle MCP requests from STDIN (main select)
		my @mcp_ready = $mcp_select->can_read(0.01);  # Non-blocking check
		for my $fh (@mcp_ready) {
			if ($fh == \*STDIN) {
				my $buffer;
				my $bytes = sysread(STDIN, $buffer, 8192);
				unless (defined $bytes) {
					debug("STDIN error: $!. Shutting down...");
					$running = 0;
					next;
				}
				if ($bytes == 0) {
					if (%bridges) {
						debug("STDIN closed (EOF) but keeping server alive for active bridges");
						next;
					} else {
						debug("STDIN closed (EOF). No active bridges, shutting down...");
						$running = 0;
						next;
					}
				}
				for my $line (split /\n/, $buffer) {
					next unless $line;
					debug("Received request: $line");
					eval {
						my $request  = decode_json($line);
						my $response = handle_request($request);
						if ($response) {
							my $response_json = encode_json($response);
							debug("Sending response: $response_json");
							print $response_json . "\n";
						}
					};
					if ($@) {
						debug("Parse error: $@");
						print mcp_error(undef, MCP_PARSE_ERROR, "Parse error: $@") . "\n";
					}
				}
			}
		}
		# Handle each bridge with its dedicated select (parallel processing)
		foreach my $vm_name (keys %bridges) {
			my $bridge = $bridges{$vm_name};
			next unless $bridge && $bridge->{select};
			my @bridge_ready = $bridge->{select}->can_read(0.01);  # Non-blocking check
			for my $fh (@bridge_ready) {
				monitor_bridge($vm_name, $fh);
			}
		}
		# Small sleep to prevent CPU spinning
		sleep(0.001);
	}
}
# Handle JSON RPC requests
sub handle_request {
	my ($request) = @_;
	return unless $request && ref($request) eq 'HASH';
	my $method = $request->{method};
	my $params = $request->{params} || {};
	my $id     = $request->{id};
	# Validate JSON RPC 2.0 (standard says notifications have no ID, so we only validate for requests)
	if (defined $id && (!$request->{jsonrpc} || $request->{jsonrpc} ne '2.0')) {
		return {jsonrpc => "2.0",error   => {code    => MCP_INVALID_REQUEST,message => "Invalid JSON-RPC 2.0 request"},id => $id};
	}
	# Handle MCP methods
	if ($method eq 'initialize') {
		return {
			jsonrpc => "2.0",
			id      => $id,
			result  => {
				protocolVersion => $PROTOCOL_VERSION,
				# Capabilities: logging + tools listChanged flag for OpenCode compatibility
				capabilities => {logging => {},tools   => {listChanged => JSON::PP::true,},},
				# Complete server info
				serverInfo => {
					name        => $0,
					version     => $VERSION,
					title       => "SerenCP Serial Console Bridge",
					description => "MCP server for VM serial console via TCP/Unix sockets",
					websiteUrl  => "https://github.com/abda11ah/serencp",
					icons       => [
						{
							src =>
"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Crect fill='%23333' width='100' height='100' rx='10'/%3E%3Ctext x='50' y='65' font-size='50' text-anchor='middle' fill='white'%3ES%3C/text%3E%3C/svg%3E",
							mimeType => "image/svg+xml"
						}
					]
				},
				# InitializeResult.instructions is a plain string in 2024-11-05
				instructions =>
"VM output is automatically sent as real-time notifications when a bridge is active. VM output appears immediately without requiring polling. The 'read' tool is available for legacy polling if needed.",
			},
		};
	}
	if ($method eq 'notifications/initialized') {
		debug("MCP client initialized");
		return;    # Notification: no response
	}
	if ($method eq 'tools/list') {
		my @list = map { { name => $_, %{ $TOOLS{$_} } } } keys %TOOLS;
		for (@list) { delete $_->{handler} }    # Don't send handler in list
		return {jsonrpc => "2.0",id      => $id,result  => { tools => \@list }};
	}
	if ($method eq 'tools/call') {
		my $name = $params->{name};
		my $args = $params->{arguments} || {};
		if (my $tool = $TOOLS{$name}) {
			my $res = $tool->{handler}->($args);
			return {jsonrpc => "2.0",id      => $id,result  => {content => [{type => "text",text => encode_json($res)}], isError => JSON::PP::false}};
		}
		return {jsonrpc => "2.0",id      => $id,error   => {code    => MCP_METHOD_NOT_FOUND,message => "Tool not found: $name"}};
	}
	# Legacy support for direct method calls if needed
	if (my $tool = $TOOLS{$method}) {
		my $res = $tool->{handler}->($params);
		return {jsonrpc => "2.0",id      => $id,result  => $res};
	}
	return {jsonrpc => "2.0",id      => $id,error   => {code    => MCP_METHOD_NOT_FOUND,message => "Method not found: $method"}} if defined $id;
	return;
}
# Tool: Start VM serial bridge
sub tool_start {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	my $port     = $params->{port} || $DEFAULT_VM_PORT;
	my $progressToken;
	$progressToken = $params->{_meta}->{progressToken} if $params->{_meta};
	debug("Starting bridge for VM: $vm_name on port: $port");
	return mcp_error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
	my $old_term_pid;
	if (bridge_exists($vm_name)) {
		debug("Stopping existing bridge for VM: $vm_name (fresh slate)");
		$old_term_pid = stop_bridge($vm_name, 0); # Don't kill terminal on restart
	}
	return start_bridge($vm_name, $port, $progressToken, $old_term_pid);
}
# Tool: Stop VM serial bridge
sub tool_stop {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	return mcp_error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
	if (!bridge_exists($vm_name)) {
		return {success => 0,message => "No bridge running for VM: $vm_name"};
	}
	stop_bridge($vm_name, 1); # Kill terminal on explicit stop
	return {success => 1,message => "Bridge stopped for VM: $vm_name"};
}
# Tool: Check VM serial bridge status
sub tool_status {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	return mcp_error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
	return do {
		if (bridge_exists($vm_name)) {
			my $bridge = $bridges{$vm_name};
			{running     => 1,vm_name     => $vm_name,port        => $bridge->{port},buffer_size => scalar(@{ $bridge->{buffer} }),buffer_bytes => $bridge->{buffer_bytes} || 0};
		}else {
			{running     => 0,vm_name     => $vm_name,port        => undef,buffer_size => 0,buffer_bytes => 0};
		}
	};
}
# Tool: Read from VM serial console (now reads from output socket directly)
sub tool_read {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	debug("Read request for VM: $vm_name");
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name parameter is required"}} unless $vm_name;
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_RESOURCE_NOT_FOUND,message => "Bridge not running for VM: $vm_name. Use start to start it."}} unless bridge_exists($vm_name);
	return do {
		my $bridge = $bridges{$vm_name};
		debug("Reading from output socket for VM: $vm_name");
		# Connect to output socket and read available data
		my $socket_path = "/tmp/serial_${vm_name}.out";
		my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket_path);
		unless ($socket) {
			debug("Failed to connect to output socket $socket_path: $!");
			return { success => 0, output => "" };
		}
		$socket->blocking(0);
		my $buffer = "";
		my $total_bytes = 0;
		# Read available data with timeout
		my $start_time = time();
		while (time() - $start_time < 2) {  # 2 second timeout
			my $data;
			my $bytes = sysread($socket, $data, 4096);
			if (!defined $bytes) {
				last if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
				debug("Error reading from output socket: $!");
				last;
			} elsif ($bytes == 0) {
				last;  # EOF
			} elsif ($bytes > 0) {
				$buffer .= $data;
				$total_bytes += $bytes;
				debug("Read $bytes bytes from output socket (total: $total_bytes)");
			}
			sleep(0.01);  # Small delay to prevent spinning
		}
		$socket->close();
		debug("Read completed: $total_bytes bytes from VM output");
		{ success => 1, output => $buffer };
	};
}
# Tool: Write to VM serial console
sub tool_write {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	my $text     = $params->{text};
	debug("Write request for VM: $vm_name with text: '$text'");
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name and text parameters are required"}} unless $vm_name && defined $text;
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_RESOURCE_NOT_FOUND,message => "Bridge not running for VM: $vm_name. Use start to start it."}} unless bridge_exists($vm_name);
	my $result = do {
		my $bridge = $bridges{$vm_name};
		debug("Writing to VM: $vm_name text: '$text'");
		return 0 unless $bridge && $bridge->{pty_in};
		# Remove all trailing newlines, then add exactly one
		$text =~ s/\n+$//;
		$text .= "\n";
		debug("Writing to input PTY: " . length($text) . " bytes");
		# Write to input PTY
		my $bytes = syswrite($bridge->{pty_in}, $text);
		debug("Input PTY write result: $bytes bytes");
		$bytes > 0;
	};
	debug("Write result: " . ($result ? "SUCCESS" : "FAILED"));
	return {success => $result,message => $result ? "Command sent successfully" : "Failed to send command"};
}
# Check if bridge exists for VM
sub bridge_exists {
	my ($vm_name) = @_;
	return exists $bridges{$vm_name} && $bridges{$vm_name}->{pty_in} && $bridges{$vm_name}->{pty_out};
}
# Start bridge for VM
sub start_bridge {
	my ($vm_name, $port, $progressToken, $old_term_pid) = @_;
	$port //= $DEFAULT_VM_PORT;
	debug("Creating bridge for $vm_name on port $port");
	# Create two PTYs - one for input, one for output
	my $pty_in = IO::Pty->new();
	my $pty_out = IO::Pty->new();
	unless ($pty_in && $pty_out) {
		debug("Failed to create PTYs");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message => "Failed to create PTYs for VM: $vm_name"}};
	}
	$pty_in->set_raw();
	$pty_out->set_raw();
	debug("PTYs created successfully (input and output)");
	# Create a pipe for child to signal readiness
	my ($read_pipe, $write_pipe);
	unless (pipe($read_pipe, $write_pipe)) {
		debug("Failed to create pipe: $!");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to create communication pipe for VM: $vm_name :".$! }};
	}
	# Fork to handle the bridge
	my $pid = fork();
	unless (defined $pid) {
		debug("Failed to fork");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to fork bridge process for VM: $vm_name"}};
	}
	if ($pid == 0) {
		# Child process - handle the bridge
		close($read_pipe);    # Child doesn't need read end
		 # Don't close PTYs - keep slave ends for communication
		my $pty_in_slave = $pty_in->slave();
		my $pty_out_slave = $pty_out->slave();
		$pty_in->close();        # Close master end in child
		$pty_out->close();       # Close master end in child
		 # Disable PTY line discipline echo to prevent character duplication
		 # This prevents the PTY from echoing characters back to the VM
		my $termios = POSIX::Termios->new();
		my $pty_in_slave_fd = fileno($pty_in_slave);
		my $pty_out_slave_fd = fileno($pty_out_slave);
		$termios->getattr($pty_in_slave_fd);
		my $lflag = $termios->getlflag();
		$lflag &= ~(ECHO | ECHOK | ECHOE | ICANON);  # Disable echo and canonical mode
		$termios->setlflag($lflag);
		$termios->setattr($pty_in_slave_fd, TCSANOW);
		$termios->getattr($pty_out_slave_fd);
		$lflag = $termios->getlflag();
		$lflag &= ~(ECHO | ECHOK | ECHOE | ICANON);  # Disable echo and canonical mode
		$termios->setlflag($lflag);
		$termios->setattr($pty_out_slave_fd, TCSANOW);
		# Try to connect to VM serial console (raw TCP) with retry
		debug("Child process: Attempting to connect to VM serial console on port $port");
		my $vm_socket;
		my $retry_count = 0;
		my $max_retries = 30;  # Try for up to 30 seconds
		while (!$vm_socket && $retry_count < $max_retries) {
			$vm_socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1',PeerPort => $port,Proto    => 'tcp',Timeout  => 2);
			if (!$vm_socket) {
				$retry_count++;
				debug("Child process: Connection attempt $retry_count failed, retrying...");
				sleep(1);
			}
		}
		if ($vm_socket) {
			debug("Child process: Connected to VM serial console successfully after $retry_count retries");
			# Connection successful - signal parent
			debug("Child process: Signaling parent - READY");
			print $write_pipe "READY\n";
			close($write_pipe);
			# Continue with bridge process - pass PTY slaves
			debug("Child process: Starting bridge process child");
			bridge_process_child($vm_socket, $pty_in_slave, $pty_out_slave);
			exit(0);
		}else {
			debug("Child process: Failed to connect to VM serial console after $max_retries attempts: $!");
			# Connection failed - signal parent and exit
			print $write_pipe "FAILED\n";
			close($write_pipe);
			exit(1);
		}
	}
	# Parent process - wait for child to be ready
	close($write_pipe);    # Parent doesn't need write end
	 # Create two sockets - one for input, one for output
	my $socket_in_path = "/tmp/serial_${vm_name}.in";
	my $socket_out_path = "/tmp/serial_${vm_name}.out";
	debug("Parent process: Creating Unix sockets at $socket_in_path and $socket_out_path");
	unlink $socket_in_path if -e $socket_in_path;
	unlink $socket_out_path if -e $socket_out_path;
	my $socket_in = IO::Socket::UNIX->new(Type  => SOCK_STREAM,Local => $socket_in_path,Listen => 1);
	my $socket_out = IO::Socket::UNIX->new(Type  => SOCK_STREAM,Local => $socket_out_path,Listen => 1);
	unless ($socket_in && $socket_out) {
		debug("Failed to create sockets: $!");
		terminate_process($pid, "bridge child process for VM $vm_name (socket creation failed)") if $pid;
		$pty_in->close();
		$pty_out->close();
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message => "Failed to create Unix sockets for VM: $vm_name :".$!}};
	}
	debug("Parent process: Unix sockets created successfully");
	# Set up select - add pipe to monitor child readiness
	my $select = IO::Select->new();
	$select->add($pty_out);  # Only need to monitor output PTY for VM data
	$select->add($socket_in);
	$select->add($socket_out);
	$select->add($read_pipe);
	# Wait for child to signal readiness (with timeout)
	my $ready      = 0;
	my $start_time = time();
	my $last_progress = 0;
	debug("Parent process: Waiting for child to signal readiness");
	while (time() - $start_time < 10) {    # 10 second timeout
		my @ready = $select->can_read(0.1);
		if (@ready && grep { $_ == $read_pipe } @ready) {
			my $response;
			my $bytes = sysread($read_pipe, $response, 10);
			debug("Parent process: Read '$response' from child ($bytes bytes)");
			if ($bytes && $response eq "READY\n") {
				debug("Parent process: Child is ready!");
				$ready = 1;
				last;
			}elsif ($bytes && $response eq "FAILED\n") {
				debug("Parent process: Child failed to connect - will retry in background");
				last;
			}
			unless (defined $bytes && $bytes > 0) {
				debug("Parent process: Failed to read from child pipe");
				last;
			}
		}
		# Send progress notification if requested
		if ($progressToken && time() - $last_progress >= 1) {
			my $elapsed = time() - $start_time;
			send_progress($progressToken, $elapsed, 10, "Waiting for VM connection...");
			$last_progress = time();
		}
		# Check if child process is still alive
		my $child_status = waitpid($pid, WNOHANG);
		if ($child_status == $pid) {
			# Child has exited
			my $exit_code = ($? >> 8) & 0xFF;
			debug("Parent process: Child process exited with status $exit_code");
			last;
		} elsif ($child_status == -1) {
			# waitpid failed
			debug("Parent process: waitpid failed: $!");
			last;
		}
	}
	$select->remove($read_pipe);
	close($read_pipe);
	if ($ready) {
		debug("Parent process: Storing bridge info");
		# Generate Session ID
		my $session_id = sprintf("session_%s_%d", $vm_name, time());
		# Store bridge info with dedicated select for this bridge
		$bridges{$vm_name} = {
			pty_in  => $pty_in,
			pty_out => $pty_out,
			socket_in  => $socket_in,
			socket_out => $socket_out,
			port    => $port,
			buffer  => [],
			buffer_bytes => 0,  # Track total bytes in buffer
			total_bytes_sent => 0,  # Track total bytes sent in notifications
			pid     => $pid,
			terminal_pid => $old_term_pid,
			session => {id      => $session_id,clients => {},input_clients => {},},
			select  => IO::Select->new($pty_out, $socket_in, $socket_out),  # Dedicated select for this bridge
		};
		# Small delay to ensure socket is fully ready before spawning clients
		sleep(0.5);
		# Spawn terminal client for immediate interaction if not already running
		my $term_pid = $old_term_pid;
		if ($term_pid && kill(0, $term_pid)) {
			debug("Terminal already running for VM: $vm_name (PID: $term_pid)");
		} else {
			debug("Spawning terminal client for immediate interaction");
			$term_pid = spawn_terminal_client($vm_name, $socket_in_path, $socket_out_path);
			$bridges{$vm_name}->{terminal_pid} = $term_pid;
		}
		debug("Manual connection available: Connect to Unix sockets at /tmp/serial_${vm_name}.in and /tmp/serial_${vm_name}.out");
		return {success => 1,message => "Bridge started for VM: $vm_name",port => $port,socket_in => $socket_in_path, socket_out => $socket_out_path,session_id => $session_id, terminal_pid => $term_pid};
	}else {
		debug("Parent process: Bridge setup failed - cleaning up");
		# Clean up on failure
		terminate_process($pid, "bridge child process for VM $vm_name (setup failed)") if $pid;
		$pty_in->close();
		$pty_out->close();
		$socket_in->close();
		$socket_out->close();
		unlink $socket_in_path if -e $socket_in_path;
		unlink $socket_out_path if -e $socket_out_path;
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to start bridge for VM: $vm_name - connection timeout"}};
	}
}
# Bridge process (child) - simplified version for child process
sub bridge_process_child {
	my ($vm_socket, $pty_in_slave, $pty_out_slave) = @_;
	debug("Bridge child: Starting data bridge between VM and PTYs");
	# Set both sockets to non-blocking mode immediately
	$vm_socket->blocking(0);
	$pty_in_slave->blocking(0);
	$pty_out_slave->blocking(0);
	$pty_in_slave->set_raw();
	$pty_out_slave->set_raw();
	# Set up select for multiplexing VM socket and PTY slaves
	my $select = IO::Select->new();
	$select->add($vm_socket);
	$select->add($pty_in_slave);   # Read commands from parent via input PTY
	 # Main loop - non-blocking I/O with select
	while (1) {
		# Use IO::Select for efficient multiplexing
		my @ready = $select->can_read(0.01);  # 10ms timeout
		for my $fh (@ready) {
			if ($fh == $vm_socket) {
				# Data from VM → PTY out slave → PTY out master → parent
				my $buffer;
				my $bytes = sysread($vm_socket, $buffer, 4096);
				# Handle different read outcomes
				if (!defined $bytes) {
					# Check for temporary errors
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					# Actual error - break connection
					debug("Bridge child: Error reading from VM socket: $!");
					last;
				} elsif ($bytes == 0) {
					# EOF - VM connection closed
					debug("Bridge child: VM socket closed connection");
					last;
				} elsif ($bytes > 0) {
					debug("Bridge child: Read $bytes bytes from VM");
					# Write to output PTY slave
					syswrite($pty_out_slave, $buffer);
				}
			} elsif ($fh == $pty_in_slave) {
				# Commands from parent PTY in master → VM socket
				my $buffer;
				my $bytes = sysread($pty_in_slave, $buffer, 4096);
				# Handle different read outcomes
				if (!defined $bytes) {
					# Check for temporary errors
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					# Actual error - break connection
					debug("Bridge child: Error reading from input PTY slave: $!");
					last;
				} elsif ($bytes == 0) {
					# EOF - Parent closed connection
					debug("Bridge child: Input PTY slave closed connection");
					$select->remove($pty_in_slave);
					next;
				} elsif ($bytes > 0) {
					debug("Bridge child: Read $bytes bytes from input PTY, forwarding to VM");
					syswrite($vm_socket, $buffer);
				}
			}
		}
		# Check if socket is still connected
		if (!$vm_socket->connected()) {
			debug("Bridge child: VM socket no longer connected");
			last;
		}
	}
	debug("Bridge child: Closing connections");
	close $vm_socket;
	close $pty_in_slave;
	close $pty_out_slave;
}
# Robust process termination with SIGTERM + SIGKILL fallback
sub terminate_process {
	my ($pid, $process_desc) = @_;
	$process_desc ||= "process";
	return unless $pid && kill(0, $pid);  # Check if process exists
	debug("Sending SIGTERM to $process_desc (PID: $pid)");
	kill('TERM', $pid);
	# Wait up to timeout for graceful termination
	my $start_time = time();
	while (time() - $start_time < $SIGTERM_TIMEOUT) {
		my $wait_result = waitpid($pid, WNOHANG);
		if ($wait_result == $pid) {
			debug("$process_desc (PID: $pid) terminated gracefully");
			return 1;
		} elsif ($wait_result == -1) {
			debug("waitpid failed for $process_desc (PID: $pid): $!");
			last;
		}
		sleep(0.1);
	}
	# Check if process is still alive and send SIGKILL if needed
	if (kill(0, $pid)) {
		debug("$process_desc (PID: $pid) still alive after SIGTERM timeout, sending SIGKILL");
		kill('KILL', $pid);
		# Final wait for SIGKILL to take effect
		sleep($SIGKILL_WAIT);
		# Final check
		if (kill(0, $pid)) {
			debug("Warning: $process_desc (PID: $pid) still alive after SIGKILL");
			return 0;
		} else {
			debug("$process_desc (PID: $pid) terminated by SIGKILL");
			return 1;
		}
	}
	return 1;
}
# Stop bridge for VM
sub stop_bridge {
	my ($vm_name, $kill_terminal) = @_;
	return unless bridge_exists($vm_name);
	my $bridge = $bridges{$vm_name};
	my $term_pid = $bridge->{terminal_pid};
	# Kill child processes robustly
	if ($bridge->{pid}) {
		terminate_process($bridge->{pid}, "bridge child process for VM $vm_name");
	}
	if ($kill_terminal && $term_pid) {
		terminate_process($term_pid, "terminal window for VM $vm_name");
		$term_pid = undef;
	}
	# Close handles
	if ($bridge->{pty_in}) {
		$bridge->{pty_in}->close();
	}
	if ($bridge->{pty_out}) {
		$bridge->{pty_out}->close();
	}
	$bridge->{socket_in}->close() if $bridge->{socket_in};
	$bridge->{socket_out}->close() if $bridge->{socket_out};
	# Remove socket files
	my $socket_in_path = "/tmp/serial_${vm_name}.in";
	my $socket_out_path = "/tmp/serial_${vm_name}.out";
	unlink $socket_in_path if -e $socket_in_path;
	unlink $socket_out_path if -e $socket_out_path;
	# Clean up
	delete $bridges{$vm_name};
	return $term_pid;
}
# Monitor bridge for PTY and Unix socket communication (single filehandle processing)
sub monitor_bridge {
	my ($vm_name, $fh) = @_;
	my $bridge = $bridges{$vm_name};
	return unless $bridge;
	if ($fh == $bridge->{pty_out}) {
		# VM data from output PTY master → buffer + output socket clients
		my $buffer;
		my $bytes = sysread($bridge->{pty_out}, $buffer, 4096);
		if (defined $bytes && $bytes > 0) {
			debug("Monitor: Read $bytes bytes from VM via output PTY");
			# Send live output notification automatically
			send_json_notification($vm_name, "stdout", $buffer);
			# Update buffer for read - optimized batch processing
			my $text = $buffer;
			$text =~ s/\r/\n/g;
			# Process all lines (including those with ANSI codes), filter only truly empty lines
			my @new_lines = grep { defined $_ && length($_) > 0 } split /\n/, $text;
			if (@new_lines) {
				my $total_length = 0;
				$total_length += length($_) for @new_lines;
				# Add all lines to buffer
				push @{ $bridge->{buffer} }, @new_lines;
				$bridge->{buffer_bytes} += $total_length;
				# Enforce both line count and byte size limits in one pass
				while (@{ $bridge->{buffer} } > $RING_BUFFER_SIZE || $bridge->{buffer_bytes} > $MAX_BUFFER_BYTES) {
					my $removed = shift @{ $bridge->{buffer} };
					$bridge->{buffer_bytes} -= length($removed) if defined $removed;
					debug("Buffer management: removed line (" . length($removed) . " bytes) for $vm_name. Current: " . scalar(@{ $bridge->{buffer} }) . " lines, " . $bridge->{buffer_bytes} . " bytes");
				}
			}
			# Forward to all connected output socket clients
			my $client_count = scalar keys %{ $bridge->{session}->{clients} };
			debug("Monitor: Forwarding to $client_count output clients");
			for my $cid (keys %{ $bridge->{session}->{clients} }) {
				my $client = $bridge->{session}->{clients}->{$cid};
				unless (send_to_tmp_socket($client, $buffer)) {
					debug("Monitor: Output client $cid write failed, removing.");
					$bridge->{select}->remove($client);
					delete $bridge->{session}->{clients}->{$cid};
					close $client;
				}
			}
		}elsif (defined $bytes && $bytes == 0) {
			debug("Server: Output PTY for $vm_name signaled EOF - VM bridge likely died");
			# Auto-restart bridge after a brief pause to prevent rapid cycling
			debug("VM disconnected - attempting auto-restart bridge for $vm_name. Waiting 1 second...");
			my $port = $bridge->{port};
			my $term_pid = stop_bridge($vm_name, 0); # Don't kill terminal on auto-restart
			sleep(1); # Wait briefly to prevent rapid spin loop on immediate failure
			start_bridge($vm_name, $port, undef, $term_pid);
		}
	}elsif ($fh == $bridge->{socket_out}) {
		# New output client connection
		my $client = $bridge->{socket_out}->accept();
		if ($client) {
			$client->blocking(0); # Ensure non-blocking
			my $client_id = fileno($client);
			$bridge->{session}->{clients}->{$client_id} = $client;
			$bridge->{select}->add($client);  # Add to bridge's dedicated select
			debug("Monitor: New output client connected with ID $client_id");
			# Send current buffer content to new client
			if (@{ $bridge->{buffer} }) {
				my $start
					= @{ $bridge->{buffer} } > $CONSOLE_HISTORY_LINES
					? @{ $bridge->{buffer} } - $CONSOLE_HISTORY_LINES
					: 0;
				my $history = join("\n",@{ $bridge->{buffer} }[ $start .. $#{ $bridge->{buffer} } ]). "\n";
				debug("Monitor: Sending history (" . length($history) . " bytes) to new output client");
				send_to_tmp_socket($client, $history);
			}
		}
	}elsif ($fh == $bridge->{socket_in}) {
		# New input client connection (for writing commands)
		my $client = $bridge->{socket_in}->accept();
		if ($client) {
			$client->blocking(0); # Ensure non-blocking
			my $client_id = fileno($client);
			# Store input clients separately to avoid confusion with output clients
			$bridge->{session}->{input_clients}->{$client_id} = $client;
			$bridge->{select}->add($client);  # Add to bridge's dedicated select
			debug("Monitor: New input client connected with ID $client_id");
		}
	}elsif (exists $bridge->{session}->{clients}->{ fileno($fh) }) {
		# Data from output client (read-only, just monitor)
		my $buffer;
		my $bytes = sysread($fh, $buffer, 4096);
		if (defined $bytes && $bytes == 0) {
			# Output client disconnected
			my $client_id = fileno($fh);
			debug("Monitor: Output client $client_id disconnected");
			$bridge->{select}->remove($fh);  # Remove from bridge's dedicated select
			delete $bridge->{session}->{clients}->{$client_id};
			close $fh;
		}
	}elsif (exists $bridge->{session}->{input_clients}->{ fileno($fh) }) {
		# Data from input client → VM via input PTY master
		my $buffer;
		my $bytes = sysread($fh, $buffer, 4096);
		if (defined $bytes && $bytes > 0) {
			debug("Monitor: Read $bytes bytes from input client, forwarding to VM");
			syswrite($bridge->{pty_in}, $buffer);
		}else {
			# Input client disconnected
			my $client_id = fileno($fh);
			debug("Monitor: Input client $client_id disconnected");
			$bridge->{select}->remove($fh);  # Remove from bridge's dedicated select
			delete $bridge->{session}->{input_clients}->{$client_id};
			close $fh;
		}
	}
}
# Helper to send data to client with non-blocking support
# Returns 1 if success or transient error (keep client), 0 if fatal error (disconnect client)
sub send_to_tmp_socket {
	my ($client, $data) = @_;
	return 1 unless defined $client && defined $data;
	my $written = syswrite($client, $data);
	if (defined $written) {
		return 1;
	}
	# Handle non-blocking errors
	if ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR) {
		return 1; # Drop data, but keep client alive
	}
	return 0; # Fatal error
}
# Cleanup on exit
sub cleanup {
	$running = 0;
	# Stop all bridges
	for my $vm_name (keys %bridges) {
		stop_bridge($vm_name);
	}
	debug("$0 MCP Server stopped");
	exit(0);
}
sub spawn_terminal_client {
	my ($vm_name, $socket_in_path, $socket_out_path) = @_;
	debug("Attempting to spawn terminal for VM: $vm_name");
	eval {
		# Terminal detection with fallback mechanism
		my $terminal_config = $term;
		unless ($terminal_config) {
			debug("No standard terminal detected, attempting fallback methods");
			# Try fallback terminals in order of preference
			my @fallback_terminals = (
				['generic-xterm', ['xterm', '-e']],
				['generic-sh',   ['sh', '-c']],
				[
					'fallback-echo',
					[
						'echo',
						sub {
							"echo 'Terminal spawning failed. Please connect manually to: $_[0]'"
						}
					]
				],
			);
			for my $fallback (@fallback_terminals) {
				my ($name, $config) = @$fallback;
				if ($name eq 'fallback-echo' || can_run($config->[0])) {
					$terminal_config = $config;
					debug("Using fallback terminal: $name");
					last;
				}
			}
		}
		# If still no terminal available, return error to MCP client
		unless ($terminal_config) {
			debug("All terminal detection methods failed");
			# Send error notification to MCP client
			my $msg = "Terminal spawning failed: No compatible terminal emulator found. Please install one of: gnome-terminal, konsole, xterm, or Terminal.app (macOS)";
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params => {
					level => MCP_LOG_LEVEL_ERROR,
					logger => "serencp",
					message => $msg,
					data => {message => $msg,timestamp => iso8601(),vm_name => $vm_name,suggestion => "Manual connection: Connect to Unix sockets at /tmp/serial_${vm_name}.in and /tmp/serial_${vm_name}.out"}
				}
			};
			print STDOUT encode_json($error_notification) . "\n";
			return;
		}
		# Enhanced shell detection with validation
		my $shell = do {
			# Try to detect current shell with better validation
			if (exists $ENV{SHELL} && $ENV{SHELL} && -x $ENV{SHELL}) {
				$ENV{SHELL};
			} elsif (-x '/bin/bash') {
				'/bin/bash';
			} elsif (-x '/bin/sh') {
				'/bin/sh';
			} elsif (-x '/usr/bin/sh') {
				'/usr/bin/sh';
			} else {
				# If no valid shell found, return error
				debug("No valid shell detected");
				my $msg = "Shell detection failed: No valid POSIX shell found";
				my $error_notification = {
					jsonrpc => "2.0",
					method => "notifications/message",
					params => {level => MCP_LOG_LEVEL_ERROR,logger => "serencp",message => $msg,data => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
				};
				print STDOUT encode_json($error_notification) . "\n";
				return;
			}
		};
		my $shell_name = (split '/', $shell)[-1]; # Get shell basename (e.g., 'zsh', 'bash')
		debug("Detected shell: $shell ($shell_name)");
		# Relaunch this script in internal client mode for two-socket operation
		my $cmd = "$^X $0 --socket=$socket_out_path";
		debug("Terminal command target: $cmd");
		# Build terminal command with robust error handling
		my $full_cmd;
		eval {
			my ($terminal, $terminal_cmd) = ($terminal_config, $cmd);
			my ($bin, $prefix) = @$terminal;
			# Handle different terminal types with enhanced compatibility
			if ($bin eq 'terminal-macos' || $bin eq 'iterm-macos') {
				# macOS Terminal/iTerm2 handling
				$full_cmd = $prefix->($terminal_cmd);
			} elsif (ref $prefix eq 'CODE') {
				# Custom terminal handlers (kitty, wezterm, etc.)
				$full_cmd = $prefix->($terminal_cmd);
			} 			elsif ($prefix eq '-- sh -c') {
				# Convert to detected shell
				$full_cmd = qq{$bin -- $shell_name -c "$terminal_cmd; exec $shell_name"};
			} elsif ($prefix =~ /-- \S+ -c$/) {
				# Convert existing shell-specific pattern
				$prefix =~ s/-- (\S+) -c$/-- $shell_name -c/;
				$full_cmd = qq{$bin $prefix "$terminal_cmd; exec $shell_name"};
			} elsif ($prefix eq '-e' || $prefix eq '-x') {
				# Simple terminal emulators
				$full_cmd = qq{$bin $prefix "$terminal_cmd"};
			} elsif ($prefix eq '--command') {
				# Terminals requiring --command flag
				$full_cmd = qq{$bin $prefix "$terminal_cmd"};
			} else {
				# Generic fallback
				$full_cmd = qq{$bin $prefix "$terminal_cmd"};
			}
			debug("Constructed terminal command: $full_cmd");
		};
		if ($@ || !$full_cmd) {
			my $err = $@ || "Unknown error";
			debug("Terminal command construction failed: $err");
			my $msg = "Terminal command construction failed: $err";
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params => {level => MCP_LOG_LEVEL_ERROR,logger => "serencp",message => $msg,data => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
			};
			print STDOUT encode_json($error_notification) . "\n";
			return;
		}
		# Fork and exec to detach with error handling
		debug("Forking to spawn terminal: $full_cmd");
		my $pid = fork();
		if (!defined $pid) {
			my $err = $!;
			debug("Failed to fork for terminal spawn: $err");
			my $msg = "Failed to fork terminal process: $err";
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params => {level => MCP_LOG_LEVEL_ERROR,logger => "serencp",message => $msg,data => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
			};
			print STDOUT encode_json($error_notification) . "\n";
			return;
		}
		if ($pid == 0) {
			# Child process
			eval {
				setsid();    # Detach from terminal
				exec($full_cmd) or do {
					# If exec fails, we need to report back somehow
					my $err = $!;
					my $msg = "Terminal exec failed: $err";
					my $error_notification = {
						jsonrpc => "2.0",
						method  => "notifications/message",
						params  => {level     => MCP_LOG_LEVEL_ERROR,logger    => "serencp",message   => $msg,data      => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
					};
					print STDOUT encode_json($error_notification) . "\n";
					debug("Terminal exec failed: $!");
					exit(1);
				};
			};
			if ($@) {
				my $err = $@;
				my $msg = "Child process error: $err";
				my $error_notification = {
					jsonrpc => "2.0",
					method  => "notifications/message",
					params  => {level     => MCP_LOG_LEVEL_ERROR,logger    => "serencp",message   => $msg,data      => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
				};
				print STDOUT encode_json($error_notification) . "\n";
				debug("Child process error: $err");
				exit(1);
			}
		} else {
			# Parent process - successful spawn
			debug("Terminal spawned successfully with PID: $pid");
			# Optional: Send success notification
			if ($DEBUG) {
				my $msg = "Terminal spawned for VM: $vm_name (PID: $pid)";
				my $success_notification = {
					jsonrpc => "2.0",
					method => "notifications/message",
					params => {level => MCP_LOG_LEVEL_INFO,logger => "serencp",message => $msg,data => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
				};
				print STDOUT encode_json($success_notification) . "\n";
			}
			return $pid;
		}
	};
	if ($@) {
		my $err = $@;
		debug("Terminal spawning failed with exception: $err");
		# Send error notification to MCP client
		eval {
			my $msg = "Terminal spawning failed: $err";
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params => {level => MCP_LOG_LEVEL_ERROR,logger => "serencp",message => $msg,data => {message => $msg, timestamp => iso8601(), vm_name => $vm_name}}
			};
			print STDOUT encode_json($error_notification) . "\n";
		};
	}
}
# Internal Unix-socket client implementation for two-socket mode
sub run_unix_socket_client {
	my ($socket_path) = @_;
	# Derive input socket path from output socket path
	my $socket_out_path = $socket_path;
	my $socket_in_path = $socket_out_path;
	$socket_in_path =~ s/\.out$/.in/;
	# Exponential backoff configuration for client connection
	my $base_delay  = 0.5; # Initial delay in seconds
	my $max_delay   = 16;  # Max delay in seconds
	my $retry_count = 0;
	while (1) {
		# Calculate exponential backoff delay, capped at $max_delay
		my $delay = $base_delay * (2 ** $retry_count);
		$delay = $max_delay if $delay > $max_delay;
		# Connect to both sockets with a connection timeout
		# The timeout is set to the calculated delay, but maxed at 5 seconds for a single attempt.
		my $timeout = $delay < 5 ? $delay : 5;
		my $sock_in = IO::Socket::UNIX->new(Type => SOCK_STREAM,Peer => $socket_in_path,Timeout => $timeout);
		my $sock_out = IO::Socket::UNIX->new(Type => SOCK_STREAM,Peer => $socket_out_path,Timeout => $timeout);
		unless (defined $sock_in && defined $sock_out) {
			print STDERR "Cannot connect to sockets: in=$socket_in_path, out=$socket_out_path. Error: $!. Retrying in $delay seconds (attempt $retry_count)...\n";
			$retry_count++;
			sleep $delay;
			next;
		}
		# Successful connection
		$retry_count = 0;
		# Use raw binary mode for all characters
		binmode(STDIN, ':raw');
		binmode(STDOUT, ':raw');
		my $sel = IO::Select->new();
		$sel->add(\*STDIN);
		$sel->add($sock_out);
		my $connected = 1;
		while ($connected) {
			for my $fh ($sel->can_read) {
				my $buf;
				my $n = sysread($fh, $buf, 4096);
				if (!defined($n)) {
					print STDERR "Error reading from file handle: $!\n";
					$connected = 0;
					last;
				}
				if ($n == 0) {
					print STDERR "Connection closed by peer. Reconnecting...\n";
					$connected = 0;
					last;
				}
				if ($fh == \*STDIN) {
					# Write to input socket
					syswrite($sock_in, $buf);
				}else {
					# Read from output socket and write to STDOUT
					syswrite(STDOUT, $buf);
				}
			}
		}
		$sock_in->close();
		$sock_out->close();
	}
}
