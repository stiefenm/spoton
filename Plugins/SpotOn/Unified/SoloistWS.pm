package Plugins::SpotOn::Unified::SoloistWS;

# Transport only (Phase 82-03): socket, handshake, reconnect with fresh
# ws.port (Task 3), frame parsing, JSON, lastCommand. Session semantics
# live in Plugins::SpotOn::Soloist::Control -- every decoded frame reaches
# `onEvent` raw, plus two synthesized `_transport` pseudo-frames for
# connection open/close (Prinzip 3.1(5)). Built on Protocol::WebSocket::
# Client 0.26, not LMS's own "Simple"-prefixed client (Pitfall 1, T-73-03).
#
# LOC policy (Phase 82-40): the 82-03 hard ceiling of <=340 total lines was
# exceeded (363) purely by bugfix-history comments accumulated since the
# transport-only cut (WR-01, CR-01, CR-03, T-73-04, T-73-05, T-73-09,
# T-77-04, T-22-01) -- no new session state, wrapper, or handler was added.
# Measured composition at time of this decision: 363 total lines, 248 code
# lines (neither blank nor comment-only), 69 comment lines, 46 blank lines.
# The code-only count (248) is still below the original 82-03 target of
# ~280, so the ceiling is raised rather than the file trimmed: total <=400
# lines, code-only <=280 lines. Both figures are enforced as a committed
# regression guard in t/37_connect_lifecycle.t (SoloistWS LOC assertions),
# not merely documented here in prose.

use strict;
use warnings;

use base qw(Slim::Utils::Accessor);
use IO::Socket::INET;
use Scalar::Util qw(blessed);
use Time::HiRes;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Networking::Select;

# Reconnect backoff (doubling) -- WS loss is NOT daemon death; the
# alive-poll (_streamAlivePoll) owns process-level crash recovery.
use constant RECONNECT_DELAY_MIN => 1;
use constant RECONNECT_DELAY_MAX => 30;

# Seconds; WR-01 -- the vendored client has no handshake timeout of its own.
use constant HANDSHAKE_TIMEOUT => 5;

__PACKAGE__->mk_accessor( rw => qw(
	mac
	port
	connected
	authState
	lastCommand
	reconnectDelay
	onEvent
	_sock
	_client
	_sockOpen
	_attempts
	_unreachableReported
) );
# CR-01: blessed ARRAY refs, not hashes. _sockOpen: true from TCP connect
# until teardown (independent of `connected`/handshake). _attempts/
# _unreachableReported: T-2 (Task 3) outage bookkeeping, reset by _onHandshakeOk.
__PACKAGE__->mk_accessor( weak => qw( daemon ) );

my $log = logger('plugin.spoton');

sub new {
	my ($class, %args) = @_;
	my $self = $class->SUPER::new();
	$self->daemon($args{daemon});    # 'weak' -- daemon owns the ws, not vice versa
	$self->mac($args{mac});
	$self->port($args{port});
	$self->connected(0);
	$self->_sockOpen(0);
	$self->authState({});
	$self->reconnectDelay(RECONNECT_DELAY_MIN);
	$self->_attempts(0);
	$self->_unreachableReported(0);
	return $self;
}

sub connect {
	my $self = shift;

	# T-2/T-77-04: the constructor port is only the startup value -- a
	# daemon respawn is only found by re-reading the file every attempt.
	my $fresh = $self->_readPort;
	$self->port($fresh) if defined $fresh;

	# Localhost, sub-5ms per live probe -- eval-guarded blocking connect.
	my $sock = eval {
		IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $self->port,
			Proto    => 'tcp',
			Timeout  => 2,
		);
	};
	unless ($sock) {
		$log->warn("SoloistWS: connect failed for " . ($self->mac // '?') . ": " . ($@ || $! || 'unknown error'));
		$self->_attempts(($self->_attempts || 0) + 1);
		# T-2: one errors[] channel for the whole Soloist backend (82-03
		# discretion) -- module label 'Soloist' on purpose, not 'SoloistWS';
		# the Transport origin is in the message text below, not the label.
		if ($self->reconnectDelay >= RECONNECT_DELAY_MAX && !$self->_unreachableReported) {
			$self->_unreachableReported(1);
			eval {
				require Plugins::SpotOn::Status;
				Plugins::SpotOn::Status->recordError('error', 'Soloist', sprintf(
					'%s: WS unreachable after %d attempts (port %s)',
					$self->mac // '?', $self->_attempts, $self->port // '?'
				));
				1;
			} or $log->warn("SoloistWS: errors[] report failed: $@");
		}
		$self->_scheduleReconnect;
		return;
	}

	require Protocol::WebSocket::Client;
	my $port   = $self->port;
	my $client = Protocol::WebSocket::Client->new(url => "ws://127.0.0.1:$port");
	$self->_sock($sock);
	$self->_client($client);
	$self->_sockOpen(1);    # WR-01: socket lifecycle, independent of handshake completion

	$client->on(
		write   => sub { my $frame = $_[1]; my $s = $self->_sock; syswrite($s, $frame) if $s; },
		read    => sub { my $text  = $_[1]; $self->_onMessage($text); },
		error   => sub { my $err   = $_[1]; $self->_onWsError($err); },    # NEVER exit (Pitfall 1)
		ping    => sub { $_[0]->pong($_[1]); },                            # RFC 6455 keepalive
		eof     => sub { $self->_onClosed; },
		connect => sub { $self->_onHandshakeOk },
	);

	$client->connect;

	# Feeds handshake bytes AND frames -- read() routes internally until the
	# handshake completes, then dispatches decoded frames to on_read.
	Slim::Networking::Select::addRead($sock, sub {
		my $n = sysread($sock, my $buf, 16384);
		if (!defined $n || $n == 0) {
			$self->_onClosed;
			return;
		}
		$client->read($buf);
	});

	Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + HANDSHAKE_TIMEOUT, \&_handshakeTimeoutTimer);
}

# _onHandshakeOk($self) -- WR-01: fires only once the handshake completes
# (the vendored client drops frames while not ready). Extracted from the
# anonymous `connect =>` callback (82-03) so it is directly testable.
sub _onHandshakeOk {
	my $self = shift;
	Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);
	$self->connected(1);
	$self->reconnectDelay(RECONNECT_DELAY_MIN);    # WR-02: reset backoff after a successful (re)connect
	$self->_attempts(0);
	$self->_unreachableReported(0);

	# CR-03 (82-REVIEW.md, closed 82-11): get_auth_state MUST be on the wire
	# BEFORE the _transport open callback fires -- that callback triggers a
	# Control-side reconcile on the Control side, and the pairing question
	# has to be asked before any reconcile can build on an answer nobody
	# requested yet.
	$self->sendCommand('get_auth_state');
	if (my $cb = $self->onEvent) {
		$cb->({ type => '_transport', state => 'open' });
	}
}

# _handshakeTimeoutTimer($self) -- WR-01: fires HANDSHAKE_TIMEOUT seconds
# after connect if the handshake never completed. No-op if it already did.
sub _handshakeTimeoutTimer {
	my $self = shift;
	return if $self->connected;
	$log->warn("SoloistWS: WS handshake timed out for " . ($self->mac // '?'));
	$self->_onClosed;
}

# disconnect($self) -- WR-02 (82-REVIEW.md): reports the SAME `_transport
# closed` pseudo-frame _onClosed reports, sharing its socket-lifecycle
# gate (`_sockOpen`, captured as $wasOpen BEFORE the teardown below clears
# it) so a deliberate disconnect() and a natural _onClosed() -- in either
# order -- never both fire the message: whichever runs first flips
# _sockOpen to 0, and the second sees it already closed. Before this fix,
# a deliberate disconnect left Control's observed.wsConnected stuck at 1
# -- `_reconcile` ran the mismatch branch instead of the transport branch,
# and the watchdog believed the connection was still alive. No reconnect
# is scheduled here (unlike _onClosed) -- the caller disconnected on
# purpose; an automatic reconnect would override that intent.
sub disconnect {
	my $self = shift;

	my $wasOpen = $self->_sockOpen;

	Slim::Utils::Timers::killTimers($self, \&_reconnectTimer);
	Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);

	if (my $sock = $self->_sock) {
		Slim::Networking::Select::removeRead($sock);
		close($sock);
	}
	$self->_sock(undef);
	$self->_client(undef);
	$self->connected(0);
	$self->_sockOpen(0);

	if ($wasOpen && (my $cb = $self->onEvent)) {
		$cb->({ type => '_transport', state => 'closed' });
	}
}

sub _onClosed {
	my $self = shift;
	return unless $self->_sockOpen;    # already handled -- gate on socket lifecycle, not handshake state

	main::INFOLOG && $log->is_info && $log->info("SoloistWS: connection lost for " . ($self->mac // '?'));
	Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);

	if (my $sock = $self->_sock) {
		Slim::Networking::Select::removeRead($sock);
		close($sock);
	}
	$self->_sock(undef);
	$self->_client(undef);
	$self->connected(0);
	$self->_sockOpen(0);

	# Phase 82-03: forward the loss as a pseudo-frame BEFORE scheduling the
	# reconnect -- Control classifies transport loss like any other event.
	if (my $cb = $self->onEvent) {
		$cb->({ type => '_transport', state => 'closed' });
	}

	$self->_scheduleReconnect;
}

# WS loss is NOT daemon death -- retry with doubling backoff while the
# daemon process stays alive; give up silently once it's dead.
sub _scheduleReconnect {
	my $self   = shift;
	my $daemon = $self->daemon;
	return unless $daemon && $daemon->alive;

	my $delay = $self->reconnectDelay || RECONNECT_DELAY_MIN;
	Slim::Utils::Timers::killTimers($self, \&_reconnectTimer);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $delay, \&_reconnectTimer);

	my $next = $delay * 2;
	$self->reconnectDelay($next > RECONNECT_DELAY_MAX ? RECONNECT_DELAY_MAX : $next);
}

sub _reconnectTimer {
	my $self = shift;
	$self->connect;
}

# _onWsError($self, $err) -- Pitfall 1: NEVER dies/exits -- log + reconnect.
sub _onWsError {
	my ($self, $err) = @_;
	$log->warn("SoloistWS: protocol error for " . ($self->mac // '?') . ": " . ($err // 'unknown'));
	$self->_onClosed;
}

# _readPort($self) -- T-77-04: mtime < spawn = a leftover from a PREVIOUS
# process, never read as this run's port. `_spawnTime` undef (hand-started
# daemon, D-09 mechanics) accepts every file -- documented, narrow limit.
sub _readPort {
	my $self   = shift;
	my $daemon = $self->daemon or return undef;
	require Plugins::SpotOn::Soloist;
	require File::Spec;

	my $file = File::Spec->catfile(Plugins::SpotOn::Soloist::dataDirForClient($self->mac), 'ws.port');
	my @st  = stat($file) or return undef;
	my $ref = $daemon->can('_spawnTime') ? ($daemon->_spawnTime || 0) : 0;
	return undef if ($st[9] || 0) < $ref;

	open(my $fh, '<', $file) or return undef;
	my $line = readline($fh);
	close($fh);
	return (defined $line && $line =~ /^(\d+)\s*$/) ? $1 + 0 : undef;
}

# sendCommand($command, %params) -- returns 0 when not connected. T-22-01/
# T-73-07: any `uri` param is validated against the track/episode shape
# before it reaches the wire.
sub sendCommand {
	my ($self, $command, %params) = @_;

	if (defined $params{uri} && $params{uri} !~ /^spotify:(?:track|episode):[A-Za-z0-9]+$/) {
		$log->warn("SoloistWS: refusing to send '$command' with invalid uri (" . ($self->mac // '?') . "): " . $params{uri});
		return 0;
	}

	# 73-05 (D-06): a previously-stringified scalar can serialize as a
	# quoted JSON string; the daemon rejects a quoted position_ms (UAT gap 2).
	for my $numericParam (qw(position_ms volume)) {
		$params{$numericParam} = int($params{$numericParam}) if defined $params{$numericParam};
	}

	my $client = $self->_client;
	unless ($client && $self->connected) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: sendCommand($command) dropped -- not connected (" . ($self->mac // '?') . ")"
		);
		return 0;
	}
	# T-73-09: 1-deep, no queue -- enough for _onMessage's error handler to
	# name which command a terse daemon error was reacting to.
	$self->lastCommand($command);
	$client->write(to_json({ type => 'command', command => $command, %params }));
	return 1;
}

# _onMessage($json_text) -- V5/T-73-03: never die on malformed input.
# Decodes the frame and hands it RAW to `onEvent` (Phase 82-03 transport
# cut). Two Transport concerns stay here: (a) T-73-04 peer-trust on
# auth_state; (b) the auth_state accessor mirror for Settings/Debug.
sub _onMessage {
	my ($self, $json_text) = @_;
	# 73-05: Frame::next decodes to a CHARACTER string, from_json wants
	# UTF-8 OCTETS -- without this bridge non-ASCII metadata is dropped.
	utf8::encode($json_text) if utf8::is_utf8($json_text);

	my $msg = eval { from_json($json_text) };
	if ($@ || ref($msg) ne 'HASH') {
		$log->warn("SoloistWS: malformed JSON from daemon (" . ($self->mac // '?') . "): " . ($@ || 'not a JSON object'));
		return;
	}

	my $type = $msg->{type};
	return unless defined $type;

	if ($type eq 'auth_state') {
		# T-73-04: a stale ws.port pointing at a foreign process would
		# announce an unexpected device_name -- disconnect rather than
		# trust a process we didn't spawn (peer-trust, stays Transport).
		my $daemon = $self->daemon;
		if ($daemon && defined $msg->{device_name} && length($msg->{device_name})
			&& defined $daemon->name && $msg->{device_name} ne $daemon->name)
		{
			$log->warn(sprintf(
				"SoloistWS: auth_state device_name mismatch for %s (expected '%s', got '%s') -- disconnecting (T-73-04)",
				$self->mac // '?', $daemon->name, $msg->{device_name}
			));
			$self->disconnect;
			return;
		}
		# Best-effort mirror for Settings/Debug -- Control (82-03) owns the
		# cache snapshot and the get_state reconnect-resync dispatch now.
		$self->authState({
			logged_in   => $msg->{logged_in} ? 1 : 0,
			is_active   => $msg->{is_active} ? 1 : 0,
			device_name => $msg->{device_name},
		});
	}
	elsif ($type eq 'error') {
		# T-73-09: names which command failed via lastCommand. Still
		# forwarded to onEvent below -- Control classifies it.
		$log->warn("SoloistWS: daemon reported error (" . ($self->mac // '?')
			. ", last command '" . ($self->lastCommand // 'unknown') . "'): "
			. ($msg->{message} // 'unknown'));
	}
	if (my $cb = $self->onEvent) {
		$cb->($msg);
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: no onEvent consumer, frame '$type' dropped (" . ($self->mac // '?') . ")"
		);
	}
}

1;
