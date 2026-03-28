#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode qw(decode_utf8 encode_utf8 FB_CROAK);
use JSON::PP qw(decode_json encode_json);
use IO::Socket::INET;
use IO::Pty;
use IO::Select;
use POSIX qw(:termios_h strftime WNOHANG TCSANOW ECHO ECHOK ECHOE ICANON);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Getopt::Long;
use Time::HiRes qw(sleep time);
our %options;
GetOptions(\%options, 'host=s', 'http-port=i') or exit 1;
our $VERSION               = "2.0";
our $PROTOCOL_VERSION      = "2025-06-18";
our $DEFAULT_VM_PORT       = 4555;
our $RING_BUFFER_SIZE      = 1000;
our $MAX_BUFFER_BYTES      = 10 * 1024 * 1024;
our $SESSION_BACKLOG_BYTES = 4 * 1024 * 1024;
our $RESTART_BACKOFF_INITIAL = 1.0;
our $RESTART_BACKOFF_MAX     = 60;
our $SIGTERM_TIMEOUT         = 5;
our $SIGKILL_WAIT            = 1;
our $HTTP_HOST = $options{'host'}      // '127.0.0.1';
our $HTTP_PORT = $options{'http-port'} // 8080;
our $MCP_PATH  = '/mcp';
use constant {
	MCP_PARSE_ERROR     => -32700,
	MCP_INVALID_REQUEST => -32600,
	MCP_METHOD_NOT_FOUND=> -32601,
	MCP_INVALID_PARAMS  => -32602,
	MCP_INTERNAL_ERROR  => -32603,
	MCP_SERVER_ERROR    => -32000,
	};
our %LOG_LEVEL_PRIORITY = (
	debug => 0,
	info  => 1,
	error => 2,
	);
our $current_log_level = 'debug';
our $running     = 1;
our $PARENT_PID  = $$;
our $IS_PARENT   = 1;
our %bridges;         # vm_name => { pty_in, pty_out, port, pid, buffer, buffer_bytes, ... }
our %sessions;        # session_id => { ... }
our %http_conns;      # fd => { sock, mode, read_buf, outbuf, ... }
our %pty_fd_to_vm;    # pty fd => vm_name
our %restart_guard;
our %restart_backoff;
our $main_select = IO::Select->new();
my %TOOLS = (
	start => {
		description => "Start the bridge for VM serial console communication.",
		inputSchema => {
			type       => "object",
			properties => {
				vm_name => { type => "string",  description => "Name of the VM" },
				port    => { type => "integer", description => "Port number for VM serial console (default: 4555)" },
				},
			required => ["vm_name"],
			},
		handler => \&tool_start,
		},
	stop => {
		description => "Stop the bridge.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_stop,
		},
	status => {
		description => "Check the status of the bridge.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_status,
		},
	read => {
		description => "Read buffered output from VM serial console.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_read,
		},
	write => {
		description => "Send a command to the VM serial console.",
		inputSchema => {
			type       => "object",
			properties => {
				vm_name => { type => "string", description => "Name of the VM" },
				text    => { type => "string", description => "Command to send to the VM" },
				},
			required => ["vm_name", "text"],
			},
		handler => \&tool_write,
		},
	);
start_http_mcp_server() unless caller;
END {
	return unless $IS_PARENT;
	return unless $$ == $PARENT_PID;
	cleanup();
}
sub should_log {
	my ($level) = @_;
	my $level_pri = $LOG_LEVEL_PRIORITY{$level} // 0;
	my $min_pri   = $LOG_LEVEL_PRIORITY{$current_log_level} // 0;
	return $level_pri >= $min_pri;
}
sub debug {
	my ($message) = @_;
	return unless should_log('debug');
	print STDERR "[DEBUG $$] $message\n";
}
sub info_log {
	my ($message) = @_;
	return unless should_log('info');
	print STDERR "[INFO $$] $message\n";
}
sub error_log {
	my ($message) = @_;
	return unless should_log('error');
	print STDERR "[ERROR $$] $message\n";
}
sub set_nonblocking {
	my ($fh) = @_;
	my $flags = fcntl($fh, F_GETFL, 0);
	return unless defined $flags;
	return fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}
sub http_date {
	return strftime("%a, %d %b %Y %H:%M:%S GMT", gmtime(time()));
}
sub new_session_id {
	return sprintf("%x-%x-%x-%x", int(time() * 1000), $$, int(rand(0xffffffff)), int(rand(0xffffffff)));
}
sub safe_text {
	my ($raw_bytes) = @_;
	return "" unless defined $raw_bytes && length $raw_bytes;
	my $text;
	eval {
		$text = decode_utf8($raw_bytes, FB_CROAK);
		1;
		} or do {
		$text = $raw_bytes;
		$text =~ s/([^\x20-\x7E\r\n\t])/sprintf("\\x{%02X}", ord($1))/ge;
		};
	return $text;
}
sub is_valid_jsonrpc_id {
	my ($id) = @_;
	return 1 if !ref($id);
	return 0;
}
sub jsonrpc_error {
	my ($id, $code, $message, $data) = @_;
	my $obj = {
		jsonrpc => "2.0",
		id      => $id,
		error   => {
			code    => $code,
			message => $message,
			},
		};
	$obj->{error}{data} = $data if defined $data;
	return $obj;
}
sub tool_exec_error {
	my ($message) = @_;
	return {
		content => [{ type => "text", text => $message }],
		isError => JSON::PP::true,
		};
}
sub create_session {
	my $sid = new_session_id();
	$sessions{$sid} = {
		id                     => $sid,
		created_at             => time(),
		stream_fd              => undef,
		backlog                => [],
		backlog_bytes          => 0,
		resource_subscriptions => {},
		progress_subscriptions => {}, # token => { vm_name => ... }
		live_vms               => {}, # vm_name => 1
		};
	debug("Created session $sid");
	return $sid;
}
sub delete_session {
	my ($sid) = @_;
	return unless $sid && exists $sessions{$sid};
	my $fd = $sessions{$sid}{stream_fd};
	close_http_client($fd) if defined $fd && exists $http_conns{$fd};
	delete $sessions{$sid};
	debug("Deleted session $sid");
}
sub sse_frame_json {
	my ($obj) = @_;
	my $json = encode_json($obj);
	my @lines = split /\n/, $json, -1;
	my $out = "event: message\n";
	for my $line (@lines) {
		$out .= "data: $line\n";
	}
	$out .= "\n";
	return encode_utf8($out);
}
sub session_enqueue_frame {
	my ($sid, $frame) = @_;
	return unless $sid && exists $sessions{$sid};
	my $sess = $sessions{$sid};
	my $fd = $sess->{stream_fd};
	if (defined $fd && exists $http_conns{$fd}) {
		$http_conns{$fd}{outbuf} .= $frame;
		return 1;
	}
	push @{ $sess->{backlog} }, $frame;
	$sess->{backlog_bytes} += length($frame);
	while ($sess->{backlog_bytes} > $SESSION_BACKLOG_BYTES && @{ $sess->{backlog} }) {
		my $old = shift @{ $sess->{backlog} };
		$sess->{backlog_bytes} -= length($old);
	}
	return 1;
}
sub session_enqueue_json {
	my ($sid, $obj) = @_;
	return session_enqueue_frame($sid, sse_frame_json($obj));
}
sub broadcast_json {
	my ($obj) = @_;
	for my $sid (keys %sessions) {
		session_enqueue_json($sid, $obj);
	}
}
sub send_progress_notification {
	my ($session_id, $progressToken, $progress, $total, $message) = @_;
	return unless defined $session_id && exists $sessions{$session_id};
	return unless defined $progressToken;
	my $params = { progressToken => $progressToken };
	$params->{progress} = $progress if defined $progress;
	$params->{total}    = $total    if defined $total;
	$params->{message}  = $message  if defined $message;
	session_enqueue_json($session_id, {
			jsonrpc => "2.0",
			method  => "notifications/progress",
			params  => $params,
		});
}
sub send_resource_list_changed_notification {
	broadcast_json({
			jsonrpc => "2.0",
			method  => "notifications/resources/list_changed",
		});
}
sub send_resource_updated_notification {
	my ($uri) = @_;
	for my $sid (keys %sessions) {
		next unless $sessions{$sid}{resource_subscriptions}{$uri};
		session_enqueue_json($sid, {
				jsonrpc => "2.0",
				method  => "notifications/resources/updated",
				params  => { uri => $uri },
			});
	}
}
sub send_live_vm_output_notifications {
	my ($vm_name, $raw_bytes) = @_;
	my $text = safe_text($raw_bytes);
	my $uri  = "vm://$vm_name/output";
	for my $sid (keys %sessions) {
		my $sess = $sessions{$sid};
		if ($sess->{live_vms}{$vm_name}) {
			session_enqueue_json($sid, {
					jsonrpc => "2.0",
					method  => "notifications/vm/output",
					params  => {
						vm_name   => $vm_name,
						uri       => $uri,
						chunk     => $text,
						bytes     => length($raw_bytes),
						timestamp => sprintf("%.3f", time()),
						},
				});
		}
		for my $token (keys %{ $sess->{progress_subscriptions} }) {
			my $sub = $sess->{progress_subscriptions}{$token};
			next unless $sub->{vm_name} eq $vm_name;
			send_progress_notification($sid, $token, undef, undef, $text);
		}
	}
}
sub queue_http_response {
	my ($fd, $status, $reason, $headers, $body, $close_after_write) = @_;
	return unless exists $http_conns{$fd};
	my %h = (
		'Date'                         => http_date(),
		'Server'                       => "serencp/$VERSION",
		'Access-Control-Allow-Origin'  => '*',
		'Access-Control-Allow-Headers' => 'Content-Type, Accept, Mcp-Session-Id',
		'Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS',
		%{ $headers || {} },
		);
	my $body_bytes = defined $body ? (ref($body) ? $$body : encode_utf8($body)) : '';
	$h{'Content-Length'} = length($body_bytes) unless exists $h{'Content-Length'};
	my $resp = "HTTP/1.1 $status $reason\r\n";
	for my $k (sort keys %h) {
		$resp .= "$k: $h{$k}\r\n";
	}
	$resp .= "\r\n";
	$resp .= $body_bytes if defined $body_bytes;
	$http_conns{$fd}{outbuf} .= $resp;
	$http_conns{$fd}{close_after_write} = $close_after_write ? 1 : 0;
}
sub queue_json_response {
	my ($fd, $status, $obj, $extra_headers, $close_after_write) = @_;
	my $json = encode_json($obj);
	queue_http_response(
		$fd,
		$status,
		($status == 200 ? 'OK' :
				$status == 202 ? 'Accepted' :
				$status == 204 ? 'No Content' :
				$status == 400 ? 'Bad Request' :
				$status == 404 ? 'Not Found' :
				$status == 405 ? 'Method Not Allowed' :
				'Error'),
		{
			'Content-Type' => 'application/json; charset=utf-8',
			'Connection'   => 'close',
			%{ $extra_headers || {} },
		},
		$json,
		$close_after_write,
		);
}
sub queue_empty_response {
	my ($fd, $status, $extra_headers, $close_after_write) = @_;
	queue_http_response(
		$fd,
		$status,
		($status == 202 ? 'Accepted' :
				$status == 204 ? 'No Content' :
				$status == 200 ? 'OK' : 'Error'),
		{
			'Content-Length' => 0,
			'Connection'     => 'close',
			%{ $extra_headers || {} },
		},
		'',
		$close_after_write,
		);
}
sub queue_sse_open_response {
	my ($fd, $sid) = @_;
	return unless exists $http_conns{$fd};
	my $resp = "HTTP/1.1 200 OK\r\n";
	my %h = (
		'Date'                         => http_date(),
		'Server'                       => "serencp/$VERSION",
		'Content-Type'                 => 'text/event-stream; charset=utf-8',
		'Cache-Control'                => 'no-cache, no-transform',
		'X-Accel-Buffering'            => 'no',
		'Connection'                   => 'close',
		'Mcp-Session-Id'               => $sid,
		'Access-Control-Allow-Origin'  => '*',
		'Access-Control-Allow-Headers' => 'Content-Type, Accept, Mcp-Session-Id',
		'Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS',
		);
	for my $k (sort keys %h) {
		$resp .= "$k: $h{$k}\r\n";
	}
	$resp .= "\r\n";
	$resp .= ": connected\n\n";
	$http_conns{$fd}{outbuf} .= encode_utf8($resp);
	$http_conns{$fd}{mode} = 'sse';
	$http_conns{$fd}{close_after_write} = 0;
	$http_conns{$fd}{last_keepalive} = time();
	if (@{ $sessions{$sid}{backlog} }) {
		for my $frame (@{ $sessions{$sid}{backlog} }) {
			$http_conns{$fd}{outbuf} .= $frame;
		}
		$sessions{$sid}{backlog} = [];
		$sessions{$sid}{backlog_bytes} = 0;
	}
}
sub close_http_client {
	my ($fd) = @_;
	return unless defined $fd && exists $http_conns{$fd};
	my $conn = delete $http_conns{$fd};
	my $sock = $conn->{sock};
	if (defined $conn->{session_id} && exists $sessions{ $conn->{session_id} }) {
		if (defined $sessions{ $conn->{session_id} }{stream_fd}
			&& $sessions{ $conn->{session_id} }{stream_fd} == $fd) {
			$sessions{ $conn->{session_id} }{stream_fd} = undef;
		}
	}
	eval { $main_select->remove($sock) };
	eval { close($sock) if $sock };
}
sub flush_http_writes {
	for my $fd (keys %http_conns) {
		my $conn = $http_conns{$fd};
		next unless length($conn->{outbuf} || '');
		my $written = syswrite($conn->{sock}, $conn->{outbuf});
		if (defined $written) {
			substr($conn->{outbuf}, 0, $written, '');
		} elsif ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}) {
			next;
		} else {
			debug("HTTP write error on fd $fd: $!");
			close_http_client($fd);
			next;
		}
		if (($conn->{close_after_write} || 0) && length($conn->{outbuf}) == 0) {
			close_http_client($fd);
		}
	}
}
sub send_sse_keepalives {
	my $now = time();
	for my $fd (keys %http_conns) {
		my $conn = $http_conns{$fd};
		next unless ($conn->{mode} || '') eq 'sse';
		next if $now - ($conn->{last_keepalive} || 0) < 15;
		$conn->{outbuf} .= encode_utf8(": keepalive\n\n");
		$conn->{last_keepalive} = $now;
	}
}
sub extract_http_request {
	my ($conn) = @_;
	unless ($conn->{headers_parsed}) {
		my $pos = index($conn->{read_buf}, "\r\n\r\n");
		my $sep_len = 4;
		if ($pos < 0) {
			$pos = index($conn->{read_buf}, "\n\n");
			$sep_len = 2;
		}
		return unless $pos >= 0;
		my $head = substr($conn->{read_buf}, 0, $pos, '');
		substr($conn->{read_buf}, 0, $sep_len, '');
		my @lines = split /\r?\n/, $head;
		my $start = shift @lines;
		return unless defined $start && length $start;
		my ($method, $target, $version) = split /\s+/, $start, 3;
		my %headers;
		for my $line (@lines) {
			next unless $line =~ /^([^:]+):\s*(.*)$/;
			my ($k, $v) = (lc($1), $2);
			$headers{$k} = $v;
		}
		$conn->{headers_parsed} = 1;
		$conn->{method}         = $method;
		$conn->{target}         = $target;
		$conn->{version}        = $version || 'HTTP/1.1';
		$conn->{headers}        = \%headers;
		$conn->{content_length} = int($headers{'content-length'} || 0);
		if (($method eq 'GET' || $method eq 'OPTIONS' || $method eq 'DELETE') && $conn->{content_length} == 0) {
			return {
				method  => $conn->{method},
				target  => $conn->{target},
				version => $conn->{version},
				headers => $conn->{headers},
				body    => '',
				};
		}
	}
	return unless $conn->{headers_parsed};
	return unless length($conn->{read_buf}) >= ($conn->{content_length} || 0);
	my $body = substr($conn->{read_buf}, 0, $conn->{content_length}, '');
	return {
		method  => $conn->{method},
		target  => $conn->{target},
		version => $conn->{version},
		headers => $conn->{headers},
		body    => $body,
		};
}
sub accept_http_clients {
	my ($server) = @_;
	while (1) {
		my $client = $server->accept();
		last unless $client;
		set_nonblocking($client);
		my $fd = fileno($client);
		$http_conns{$fd} = {
			sock              => $client,
			mode              => 'request',
			read_buf          => '',
			outbuf            => '',
			headers_parsed    => 0,
			close_after_write => 0,
			session_id        => undef,
			last_keepalive    => time(),
			};
		$main_select->add($client);
	}
}
sub handle_http_client_read {
	my ($fd) = @_;
	return unless exists $http_conns{$fd};
	my $conn = $http_conns{$fd};
	my $buf = '';
	my $n = sysread($conn->{sock}, $buf, 8192);
	if (!defined $n) {
		return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
		close_http_client($fd);
		return;
	}
	if ($n == 0) {
		close_http_client($fd);
		return;
	}
	if (($conn->{mode} || '') eq 'sse') {
		# Client should not send more bytes after GET /mcp stream is opened.
		close_http_client($fd);
		return;
	}
	$conn->{read_buf} .= $buf;
	my $req = extract_http_request($conn);
	return unless $req;
	handle_http_request($fd, $req);
}
sub handle_http_request {
	my ($fd, $req) = @_;
	my ($path) = split /\?/, ($req->{target} // ''), 2;
	my $method = $req->{method} || '';
	if ($path ne $MCP_PATH) {
		queue_http_response(
			$fd, 404, 'Not Found',
			{ 'Content-Type' => 'text/plain; charset=utf-8', 'Connection' => 'close' },
			"Not Found\n",
			1
			);
		return;
	}
	if ($method eq 'OPTIONS') {
		queue_empty_response($fd, 204, {}, 1);
		return;
	}
	if ($method eq 'GET') {
		my $sid = $req->{headers}{'mcp-session-id'};
		unless (defined $sid && exists $sessions{$sid}) {
			queue_json_response($fd, 400, jsonrpc_error(undef, MCP_INVALID_REQUEST,
					"Missing or invalid Mcp-Session-Id. Call initialize via POST /mcp first."), {}, 1);
			return;
		}
		if (defined $sessions{$sid}{stream_fd} && exists $http_conns{ $sessions{$sid}{stream_fd} }) {
			close_http_client($sessions{$sid}{stream_fd});
		}
		$http_conns{$fd}{session_id} = $sid;
		$sessions{$sid}{stream_fd} = $fd;
		queue_sse_open_response($fd, $sid);
		return;
	}
	if ($method eq 'DELETE') {
		my $sid = $req->{headers}{'mcp-session-id'};
		unless (defined $sid && exists $sessions{$sid}) {
			queue_empty_response($fd, 204, {}, 1);
			return;
		}
		delete_session($sid);
		queue_empty_response($fd, 204, {}, 1);
		return;
	}
	if ($method ne 'POST') {
		queue_http_response(
			$fd, 405, 'Method Not Allowed',
			{ 'Content-Type' => 'text/plain; charset=utf-8', 'Connection' => 'close' },
			"Method Not Allowed\n",
			1
			);
		return;
	}
	my $payload;
	eval {
		my $decoded = decode_utf8($req->{body}, FB_CROAK);
		$payload = decode_json($decoded);
		1;
		} or do {
		my $err = $@ || "parse error";
		queue_json_response($fd, 400, jsonrpc_error(undef, MCP_PARSE_ERROR, "Parse error", "$err"), {}, 1);
		return;
		};
	my $sid = $req->{headers}{'mcp-session-id'};
	if ((!defined $sid || !exists $sessions{$sid})) {
		if (ref($payload) eq 'HASH' && ($payload->{method} || '') eq 'initialize') {
			$sid = create_session();
		} else {
			queue_json_response($fd, 400,
				jsonrpc_error(ref($payload) eq 'HASH' ? $payload->{id} : undef,
					MCP_INVALID_REQUEST,
					"Missing or invalid Mcp-Session-Id. Call initialize first."),
				{},
				1
				);
			return;
		}
	}
	my $extra_headers = { 'Mcp-Session-Id' => $sid };
	$http_conns{$fd}{session_id} = $sid;
	if (ref($payload) eq 'ARRAY') {
		my @responses;
		for my $request (@$payload) {
			my $resp = eval { handle_request($request, $sid) };
			if (my $err = $@) {
				push @responses, jsonrpc_error(ref($request) eq 'HASH' ? $request->{id} : undef,
					MCP_INTERNAL_ERROR, "Internal error", "$err");
			} elsif ($resp) {
				push @responses, $resp;
			}
		}
		if (@responses) {
			queue_json_response($fd, 200, \@responses, $extra_headers, 1);
		} else {
			queue_empty_response($fd, 202, $extra_headers, 1);
		}
		return;
	}
	my $response = eval { handle_request($payload, $sid) };
	if (my $err = $@) {
		queue_json_response($fd, 200,
			jsonrpc_error(ref($payload) eq 'HASH' ? $payload->{id} : undef,
				MCP_INTERNAL_ERROR, "Internal error", "$err"),
			$extra_headers,
			1
			);
		return;
	}
	if ($response) {
		queue_json_response($fd, 200, $response, $extra_headers, 1);
	} else {
		queue_empty_response($fd, 202, $extra_headers, 1);
	}
}
sub handle_request {
	my ($request, $session_id) = @_;
	if (!$request || ref($request) ne 'HASH') {
		return jsonrpc_error(undef, MCP_INVALID_REQUEST, "Invalid Request", "Request must be a JSON object");
	}
	my $jsonrpc = $request->{jsonrpc};
	my $method  = $request->{method};
	my $params  = exists $request->{params} ? $request->{params} : {};
	my $id      = $request->{id};
	my $is_notification = !exists $request->{id};
	if (defined $jsonrpc && $jsonrpc ne '2.0') {
		return if $is_notification;
		return jsonrpc_error(is_valid_jsonrpc_id($id) ? $id : undef, MCP_INVALID_REQUEST, "Invalid Request", "jsonrpc must be '2.0'");
	}
	if (!defined $method || ref($method) || $method eq '') {
		return if $is_notification;
		return jsonrpc_error(is_valid_jsonrpc_id($id) ? $id : undef, MCP_INVALID_REQUEST, "Invalid Request", "method must be a non-empty string");
	}
	if (ref($params) && ref($params) ne 'HASH' && ref($params) ne 'ARRAY') {
		return if $is_notification;
		return jsonrpc_error(is_valid_jsonrpc_id($id) ? $id : undef, MCP_INVALID_PARAMS, "Invalid params");
	}
	if ($method eq 'initialize') {
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => is_valid_jsonrpc_id($id) ? $id : undef,
			result  => {
				protocolVersion => $PROTOCOL_VERSION,
				capabilities    => {
					logging   => {},
					resources => { subscribe => JSON::PP::true, listChanged => JSON::PP::true },
					tools     => { listChanged => JSON::PP::true },
					},
				serverInfo => {
					name        => "serencp",
					version     => $VERSION,
					description => "MCP Streamable HTTP server for VM serial console communication.",
					},
				},
			};
	}
	if ($method eq 'notifications/initialized') {
		debug("Client initialized notification received for session $session_id");
		return;
	}
	if ($method eq 'ping') {
		return if $is_notification;
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	if ($method eq 'logging/setLevel') {
		my $level = ref($params) eq 'HASH' ? $params->{level} : undef;
		if ($level && exists $LOG_LEVEL_PRIORITY{$level}) {
			$current_log_level = $level;
			return if $is_notification;
			return { jsonrpc => "2.0", id => $id, result => {} };
		}
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS,
			"Invalid log level: " . ($level // 'undef') . ". Valid: " . join(', ', sort keys %LOG_LEVEL_PRIORITY));
	}
	if ($method eq 'resources/list') {
		return if $is_notification;
		my @resources;
		for my $vm_name (sort keys %bridges) {
			push @resources, {
				uri         => "vm://$vm_name/output",
				name        => "VM Output: $vm_name",
				description => "Buffered serial console output for $vm_name",
				mimeType    => "text/plain",
				};
		}
		return { jsonrpc => "2.0", id => $id, result => { resources => \@resources } };
	}
	if ($method eq 'resources/read') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid params") if ref($params) ne 'HASH';
		my $uri = $params->{uri};
		if (defined $uri && $uri =~ m{^vm://([^/]+)/output$}) {
			my $vm_name = $1;
			my $bridge = $bridges{$vm_name};
			if ($bridge) {
				my $raw = join('', map { $$_ } @{ $bridge->{buffer} });
				return {
					jsonrpc => "2.0",
					id      => $id,
					result  => {
						contents => [{
								uri      => $uri,
								mimeType => "text/plain",
								text     => safe_text($raw),
							}],
						},
					};
			}
		}
		return jsonrpc_error($id, MCP_INVALID_REQUEST, "Resource not found or bridge not running");
	}
	if ($method eq 'resources/subscribe') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid params") if ref($params) ne 'HASH';
		my $uri = $params->{uri};
		unless (defined $uri && $uri =~ m{^vm://([^/]+)/output$}) {
			return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid resource URI");
		}
		$sessions{$session_id}{resource_subscriptions}{$uri} = 1;
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	if ($method eq 'resources/unsubscribe') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid params") if ref($params) ne 'HASH';
		my $uri = $params->{uri};
		unless (defined $uri && $uri =~ m{^vm://([^/]+)/output$}) {
			return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid resource URI");
		}
		delete $sessions{$session_id}{resource_subscriptions}{$uri};
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	if ($method eq 'tools/list') {
		return if $is_notification;
		my @list;
		for my $name (sort keys %TOOLS) {
			my %tool_def = (
				name        => $name,
				description => $TOOLS{$name}{description},
				inputSchema => $TOOLS{$name}{inputSchema},
				);
			push @list, \%tool_def;
		}
		return { jsonrpc => "2.0", id => $id, result => { tools => \@list } };
	}
	if ($method eq 'tools/call') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "tools/call params must be an object") if ref($params) ne 'HASH';
		my $name = $params->{name};
		my $args = $params->{arguments} || {};
		$args->{_meta}       = $params->{_meta} if ref($params->{_meta}) eq 'HASH';
		$args->{_session_id} = $session_id;
		if (!defined $name || ref($name) || $name eq '') {
			return jsonrpc_error($id, MCP_INVALID_PARAMS, "Tool name must be a non-empty string");
		}
		if (my $tool = $TOOLS{$name}) {
			my $res = $tool->{handler}->($args);
			if (ref($res) eq 'HASH' && exists $res->{content} && exists $res->{isError}) {
				return { jsonrpc => "2.0", id => $id, result => $res };
			}
			my $json_text = encode_json($res);
			return {
				jsonrpc => "2.0",
				id      => $id,
				result  => {
					content => [{ type => "text", text => $json_text }],
					isError => JSON::PP::false,
					},
				};
		}
		return jsonrpc_error($id, MCP_METHOD_NOT_FOUND, "Tool not found: $name");
	}
	return if $is_notification;
	return jsonrpc_error($id, MCP_METHOD_NOT_FOUND, "Method not found: $method");
}
sub tool_start {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $port    = defined($params->{port}) && length($params->{port}) ? $params->{port} : $DEFAULT_VM_PORT;
	my $sid     = $params->{_session_id};
	my $progressToken = ref($params->{_meta}) eq 'HASH' ? $params->{_meta}{progressToken} : undef;
	return tool_exec_error("vm_name parameter is required")
		unless defined $vm_name && length $vm_name;
	return tool_exec_error("port must be numeric")
		unless defined($port) && $port =~ /^\d+$/ && $port >= 1 && $port <= 65535;
	if (bridge_exists($vm_name)) {
		stop_bridge($vm_name, 0);
	}
	my $result = start_bridge($vm_name, $port, $sid, $progressToken);
	if (ref($result) eq 'HASH' && $result->{success} && $sid && exists $sessions{$sid}) {
		$sessions{$sid}{live_vms}{$vm_name} = 1;
		if (defined $progressToken) {
			$sessions{$sid}{progress_subscriptions}{$progressToken} = {
				vm_name => $vm_name,
				};
		}
	}
	return $result;
}
sub tool_stop {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required")
		unless defined $vm_name && length $vm_name;
	if (!bridge_exists($vm_name)) {
		return { success => 0, message => "No bridge running for VM: $vm_name" };
	}
	stop_bridge($vm_name, 1);
	send_resource_list_changed_notification();
	return { success => 1, message => "Bridge stopped for VM: $vm_name" };
}
sub tool_status {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $sid     = $params->{_session_id};
	return tool_exec_error("vm_name parameter is required")
		unless defined $vm_name && length $vm_name;
	my $uri = "vm://$vm_name/output";
	if (bridge_exists($vm_name)) {
		my $bridge = $bridges{$vm_name};
		return {
			running      => JSON::PP::true,
			vm_name      => $vm_name,
			port         => $bridge->{port},
			buffer_size  => scalar(@{ $bridge->{buffer} }),
			buffer_bytes => $bridge->{buffer_bytes} || 0,
			subscribed   => ($sid && $sessions{$sid}{resource_subscriptions}{$uri}) ? JSON::PP::true : JSON::PP::false,
			live_stream  => ($sid && $sessions{$sid}{live_vms}{$vm_name}) ? JSON::PP::true : JSON::PP::false,
			};
	}
	return {
		running      => JSON::PP::false,
		vm_name      => $vm_name,
		port         => undef,
		buffer_size  => 0,
		buffer_bytes => 0,
		subscribed   => JSON::PP::false,
		live_stream  => JSON::PP::false,
		};
}
sub tool_read {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required")
		unless defined $vm_name && length $vm_name;
	return tool_exec_error("Bridge not running for VM: $vm_name. Use start to start it.")
		unless bridge_exists($vm_name);
	my $bridge = $bridges{$vm_name};
	my $raw = join('', map { $$_ } @{ $bridge->{buffer} });
	@{ $bridge->{buffer} } = ();
	$bridge->{buffer_bytes} = 0;
	return {
		success => JSON::PP::true,
		output  => safe_text($raw),
		};
}
sub tool_write {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $text    = $params->{text};
	return tool_exec_error("vm_name and text parameters are required")
		unless defined $vm_name && length($vm_name) && defined $text;
	return tool_exec_error("Bridge not running for VM: $vm_name. Use start to start it.")
		unless bridge_exists($vm_name);
	my $bridge = $bridges{$vm_name};
	return { success => JSON::PP::false, message => "PTY not available" }
		unless $bridge && $bridge->{pty_in};
	$text =~ s/\n+$//;
	$text .= "\n";
	my $bytes = encode_utf8($text);
	my $ok = write_all_nonblocking($bridge->{pty_in}, $bytes, 2.0);
	return {
		success => $ok ? JSON::PP::true : JSON::PP::false,
		message => $ok ? "Command sent successfully" : "Failed to send command",
		};
}
sub bridge_exists {
	my ($vm_name) = @_;
	return exists $bridges{$vm_name}
		&& $bridges{$vm_name}{pty_in}
		&& $bridges{$vm_name}{pty_out}
		&& (!$bridges{$vm_name}{pid} || kill(0, $bridges{$vm_name}{pid}));
}
sub write_all_nonblocking {
	my ($fh, $data, $timeout) = @_;
	$timeout = 2.0 unless defined $timeout;
	return 1 unless defined $fh && defined $data && length $data;
	my $sel = IO::Select->new($fh);
	my $offset = 0;
	my $start  = time();
	while ($offset < length($data)) {
		my $written = syswrite($fh, $data, length($data) - $offset, $offset);
		if (defined $written) {
			return 0 if $written == 0 && (time() - $start) >= $timeout;
			$offset += $written if $written > 0;
			next;
		}
		if ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
			return 0 if (time() - $start) >= $timeout;
			$sel->can_write(0.05);
			next;
		}
		return 0;
	}
	return 1;
}
sub start_bridge {
	my ($vm_name, $port, $session_id, $progressToken) = @_;
	send_progress_notification($session_id, $progressToken, 0, 4, "Creating PTY pair") if defined $progressToken;
	my $pty_in  = IO::Pty->new();
	my $pty_out = IO::Pty->new();
	unless ($pty_in && $pty_out) {
		return tool_exec_error("Failed to create PTYs for VM: $vm_name");
	}
	$pty_in->set_raw();
	$pty_out->set_raw();
	my ($read_pipe, $write_pipe);
	unless (pipe($read_pipe, $write_pipe)) {
		$pty_in->close();
		$pty_out->close();
		return tool_exec_error("Failed to create communication pipe for VM: $vm_name: $!");
	}
	send_progress_notification($session_id, $progressToken, 1, 4, "Forking bridge process") if defined $progressToken;
	my $pid = fork();
	unless (defined $pid) {
		$pty_in->close();
		$pty_out->close();
		close($read_pipe);
		close($write_pipe);
		return tool_exec_error("Failed to fork bridge process for VM: $vm_name");
	}
	if ($pid == 0) {
		$IS_PARENT = 0;
		local $SIG{PIPE} = 'IGNORE';
		close($read_pipe);
		my $pty_in_slave  = $pty_in->slave();
		my $pty_out_slave = $pty_out->slave();
		$pty_in->close();
		$pty_out->close();
		my $termios = POSIX::Termios->new();
		for my $slave ($pty_in_slave, $pty_out_slave) {
			my $fd = fileno($slave);
			next unless defined $fd;
			$termios->getattr($fd);
			my $lflag = $termios->getlflag();
			$lflag &= ~(ECHO | ECHOK | ECHOE | ICANON);
			$termios->setlflag($lflag);
			$termios->setattr($fd, TCSANOW);
		}
		my $vm_socket;
		my $retry_count = 0;
		my $max_retries = 30;
		while (!$vm_socket && $retry_count < $max_retries) {
			$vm_socket = IO::Socket::INET->new(
				PeerAddr => '127.0.0.1',
				PeerPort => $port,
				Proto    => 'tcp',
				Timeout  => 2,
				);
			unless ($vm_socket) {
				$retry_count++;
				sleep(1);
			}
		}
		if ($vm_socket) {
			print {$write_pipe} "READY\n";
			close($write_pipe);
			bridge_process_child($vm_socket, $pty_in_slave, $pty_out_slave);
			exit(0);
		} else {
			print {$write_pipe} "FAILED\n";
			close($write_pipe);
			exit(1);
		}
	}
	close($write_pipe);
	send_progress_notification($session_id, $progressToken, 2, 4, "Waiting for VM connection") if defined $progressToken;
	my $select = IO::Select->new($read_pipe);
	my $ready = 0;
	my $start_time = time();
	while (time() - $start_time < 10) {
		my @ready_fhs = $select->can_read(0.1);
		if (@ready_fhs) {
			my $response = '';
			my $bytes = sysread($read_pipe, $response, 16);
			if ($bytes && $response eq "READY\n") {
				$ready = 1;
				last;
			}
			last;
		}
		my $child_status = waitpid($pid, WNOHANG);
		last if $child_status == $pid || $child_status == -1;
	}
	close($read_pipe);
	unless ($ready) {
		terminate_process($pid, "bridge child for VM $vm_name") if $pid;
		$pty_in->close();
		$pty_out->close();
		return tool_exec_error("Failed to start bridge for VM: $vm_name — connection timeout");
	}
	set_nonblocking($pty_in);
	set_nonblocking($pty_out);
	$bridges{$vm_name} = {
		pty_in               => $pty_in,
		pty_out              => $pty_out,
		port                 => $port,
		pid                  => $pid,
		buffer               => [],
		buffer_bytes         => 0,
		total_bytes_received => 0,
		restarting           => 0,
		};
	my $pty_fd = fileno($pty_out);
	$pty_fd_to_vm{$pty_fd} = $vm_name;
	$main_select->add($pty_out);
	send_resource_list_changed_notification();
	send_progress_notification($session_id, $progressToken, 3, 4, "Bridge ready") if defined $progressToken;
	return {
		success    => JSON::PP::true,
		message    => "Bridge started for VM: $vm_name",
		port       => $port,
		session_id => $session_id,
		resource   => "vm://$vm_name/output",
		};
}
sub bridge_process_child {
	my ($vm_socket, $pty_in_slave, $pty_out_slave) = @_;
	set_nonblocking($vm_socket);
	set_nonblocking($pty_in_slave);
	set_nonblocking($pty_out_slave);
	$pty_in_slave->set_raw();
	$pty_out_slave->set_raw();
	my $select = IO::Select->new();
	$select->add($vm_socket);
	$select->add($pty_in_slave);
	while (1) {
		my @ready = $select->can_read(0.05);
		for my $fh (@ready) {
			if ($fh == $vm_socket) {
				my $buffer;
				my $bytes = sysread($vm_socket, $buffer, 4096);
				if (!defined $bytes) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					goto CHILD_EXIT;
				} elsif ($bytes == 0) {
					goto CHILD_EXIT;
				} else {
					my $offset = 0;
					while ($offset < length($buffer)) {
						my $written = syswrite($pty_out_slave, $buffer, length($buffer) - $offset, $offset);
						if (defined $written) {
							$offset += $written;
						} elsif ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
							select(undef, undef, undef, 0.01);
						} else {
							goto CHILD_EXIT;
						}
					}
				}
			} elsif ($fh == $pty_in_slave) {
				my $buffer;
				my $bytes = sysread($pty_in_slave, $buffer, 4096);
				if (!defined $bytes) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					goto CHILD_EXIT;
				} elsif ($bytes == 0) {
					$select->remove($pty_in_slave);
					next;
				} else {
					unless (write_all_nonblocking($vm_socket, $buffer, 2.0)) {
						goto CHILD_EXIT;
					}
				}
			}
		}
	}
	CHILD_EXIT:
	close $vm_socket;
	close $pty_in_slave;
	close $pty_out_slave;
}
sub terminate_process {
	my ($pid, $process_desc) = @_;
	return unless $pid && kill(0, $pid);
	kill('TERM', $pid);
	my $start = time();
	while (time() - $start < $SIGTERM_TIMEOUT) {
		my $w = waitpid($pid, WNOHANG);
		return 1 if $w == $pid || $w == -1;
		sleep(0.1);
	}
	if (kill(0, $pid)) {
		kill('KILL', $pid);
		sleep($SIGKILL_WAIT);
	}
	return 1;
}
sub stop_bridge {
	my ($vm_name, $clear_watchers) = @_;
	return unless exists $bridges{$vm_name};
	my $bridge = $bridges{$vm_name};
	$bridge->{restarting} = 1;
	if ($bridge->{pty_out}) {
		my $fd = fileno($bridge->{pty_out});
		delete $pty_fd_to_vm{$fd} if defined $fd;
		eval { $main_select->remove($bridge->{pty_out}) };
	}
	terminate_process($bridge->{pid}, "bridge child for VM $vm_name") if $bridge->{pid};
	$bridge->{pty_in}->close()  if $bridge->{pty_in};
	$bridge->{pty_out}->close() if $bridge->{pty_out};
	delete $bridges{$vm_name};
	delete $restart_guard{$vm_name};
	delete $restart_backoff{$vm_name};
	if ($clear_watchers) {
		for my $sid (keys %sessions) {
			delete $sessions{$sid}{live_vms}{$vm_name};
			for my $token (keys %{ $sessions{$sid}{progress_subscriptions} }) {
				delete $sessions{$sid}{progress_subscriptions}{$token}
					if $sessions{$sid}{progress_subscriptions}{$token}{vm_name} eq $vm_name;
			}
		}
	}
}
sub request_bridge_restart {
	my ($vm_name, $reason) = @_;
	return unless exists $bridges{$vm_name};
	my $bridge = $bridges{$vm_name};
	return if $bridge->{restarting};
	return if $restart_guard{$vm_name};
	$restart_guard{$vm_name} = time();
	$bridge->{restarting} = 1;
	my $current_backoff = $restart_backoff{$vm_name} // $RESTART_BACKOFF_INITIAL;
	my $port = $bridge->{port};
	debug("Restart requested for $vm_name: $reason (backoff ${current_backoff}s)");
	stop_bridge($vm_name, 0);
	sleep($current_backoff);
	my $start_result = start_bridge($vm_name, $port, undef, undef);
	my $ok = ref($start_result) eq 'HASH' && $start_result->{success};
	if ($ok) {
		$restart_backoff{$vm_name} = $RESTART_BACKOFF_INITIAL;
	} else {
		my $next = $current_backoff * 2;
		$next = $RESTART_BACKOFF_MAX if $next > $RESTART_BACKOFF_MAX;
		$restart_backoff{$vm_name} = $next;
	}
	delete $restart_guard{$vm_name};
}
sub monitor_bridge {
	my ($vm_name, $fh) = @_;
	my $bridge = $bridges{$vm_name};
	return unless $bridge;
	my $buffer;
	my $bytes = sysread($bridge->{pty_out}, $buffer, 4096);
	if (defined $bytes && $bytes > 0) {
		push @{ $bridge->{buffer} }, \$buffer;
		$bridge->{buffer_bytes} += length($buffer);
		$bridge->{total_bytes_received} += length($buffer);
		while (@{ $bridge->{buffer} } > $RING_BUFFER_SIZE || $bridge->{buffer_bytes} > $MAX_BUFFER_BYTES) {
			my $removed_ref = shift @{ $bridge->{buffer} };
			$bridge->{buffer_bytes} -= length($$removed_ref) if defined $removed_ref;
		}
		my $uri = "vm://$vm_name/output";
		send_resource_updated_notification($uri);
		send_live_vm_output_notifications($vm_name, $buffer);
		return;
	}
	if (defined $bytes && $bytes == 0) {
		request_bridge_restart($vm_name, "PTY EOF");
		return;
	}
	if (!defined $bytes && !($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK})) {
		request_bridge_restart($vm_name, "PTY read error: $!");
		return;
	}
}
sub start_http_mcp_server {
	local $SIG{INT}  = \&cleanup;
	local $SIG{TERM} = \&cleanup;
	local $SIG{HUP}  = \&cleanup;
	local $SIG{QUIT} = \&cleanup;
	local $SIG{PIPE} = 'IGNORE';
	local $SIG{CHLD} = sub {
		while (waitpid(-1, WNOHANG) > 0) {}
		};
	my $server = IO::Socket::INET->new(
		LocalAddr => $HTTP_HOST,
		LocalPort => $HTTP_PORT,
		Proto     => 'tcp',
		Listen    => 100,
		Reuse     => 1,
		Blocking  => 0,
		) or die "Cannot listen on $HTTP_HOST:$HTTP_PORT: $!";
	set_nonblocking($server);
	$main_select->add($server);
	info_log("MCP Streamable HTTP server listening on http://$HTTP_HOST:$HTTP_PORT$MCP_PATH");
	while ($running) {
		my @ready = $main_select->can_read(0.05);
		for my $fh (@ready) {
			my $fd = fileno($fh);
			next unless defined $fd;
			if ($fd == fileno($server)) {
				accept_http_clients($server);
				next;
			}
			if (exists $pty_fd_to_vm{$fd}) {
				monitor_bridge($pty_fd_to_vm{$fd}, $fh);
				next;
			}
			if (exists $http_conns{$fd}) {
				handle_http_client_read($fd);
				next;
			}
		}
		send_sse_keepalives();
		flush_http_writes();
		sleep(0.001);
	}
}
sub cleanup {
	$running = 0;
	for my $vm (keys %bridges) {
		stop_bridge($vm, 1);
	}
	for my $fd (keys %http_conns) {
		close_http_client($fd);
	}
	%sessions = ();
	%pty_fd_to_vm = ();
	debug("Cleanup completed");
}