package Plugins::SpotOn::Unified::SoloistWS;

# Phase 73 Plan 01 (D-05/D-06, RESEARCH Pattern 2/3): a slim WebSocket client
# for the Soloist per-player control API, built exactly on the session-
# verified Pattern-2 skeleton (Protocol::WebSocket::Client 0.26 +
# Slim::Networking::Select::addRead) -- deliberately NOT the other WS client
# already bundled with LMS (Slim::Networking:: namespace, "Simple" prefix),
# whose error handler calls exit() and would kill the entire LMS process on
# a single WS protocol error (RESEARCH Pitfall 1, T-73-03).
#
# Translates Soloist's native WS event vocabulary into the existing
# `spottyconnect` command set Connect.pm already consumes from the
# librespot daemon (start/change/stop/volume/seek/resume) -- Connect.pm
# itself is untouched; years of edge-case handling (CON-11 grace period,
# H6 stale-session guards, track translation/history) are reused as-is
# (RESEARCH "Don't Hand-Roll").

use strict;
use warnings;

use base qw(Slim::Utils::Accessor);

use IO::Socket::INET;
use Scalar::Util qw(weaken);
use Time::HiRes;

use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::Select;

# Reconnect backoff (RESEARCH Pattern 2): WS connection loss is NOT daemon
# death -- doubling backoff while the daemon process stays alive; the
# alive-poll (_streamAlivePoll) owns process-level crash recovery.
use constant RECONNECT_DELAY_MIN => 1;
use constant RECONNECT_DELAY_MAX => 30;

# Seconds; position_sync jump tolerance before treated as a real seek
# (RESEARCH Pitfall 5 -- decode-ahead position drift). Mirrors Connect.pm's
# own SEEK_THRESHOLD philosophy for the librespot path.
use constant SEEK_THRESHOLD => 3;

__PACKAGE__->mk_accessor( rw => qw(
	daemon
	mac
	port
	connected
	authState
	lastTrackId
	lastPositionMs
	lastPositionTs
	sessionActive
	browseSession
	reconnectDelay
	_sock
	_client
) );
# NOTE: browseSession is always 0 in this plan -- 73-03 activates
# browse-managed sessions (Model B, RESEARCH Pattern 6).

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

sub new {
	my ($class, %args) = @_;

	my $self = $class->SUPER::new();

	$self->daemon($args{daemon});
	weaken($self->{daemon}) if $self->{daemon};    # the daemon owns the ws, not vice versa
	$self->mac($args{mac});
	$self->port($args{port});

	$self->connected(0);
	$self->authState({});
	$self->sessionActive(0);
	$self->browseSession(0);
	$self->reconnectDelay(RECONNECT_DELAY_MIN);

	return $self;
}

sub connect {
	my $self = shift;

	# Localhost, sub-5ms per live probe (RESEARCH Pattern 2) -- an
	# eval-guarded short blocking connect is acceptable here.
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
		$self->_scheduleReconnect;
		return;
	}

	require Protocol::WebSocket::Client;
	my $port   = $self->port;
	my $client = Protocol::WebSocket::Client->new(url => "ws://127.0.0.1:$port");

	$self->_sock($sock);
	$self->_client($client);

	$client->on(
		write   => sub { my $frame = $_[1]; my $s = $self->_sock; syswrite($s, $frame) if $s; },
		read    => sub { my $text  = $_[1]; $self->_onMessage($text); },
		error   => sub { my $err   = $_[1]; $self->_onWsError($err); },    # NEVER exit (Pitfall 1)
		ping    => sub { $_[0]->pong($_[1]); },                            # RFC 6455 keepalive
		eof     => sub { $self->_onClosed; },
		connect => sub { $self->sendCommand('get_auth_state'); },
	);

	$client->connect;

	# Feeds handshake bytes AND frames -- Protocol::WebSocket::Client::read()
	# routes internally until the handshake completes, then dispatches
	# decoded frames to on_read (RESEARCH Pattern 2, no blocking loop needed).
	Slim::Networking::Select::addRead($sock, sub {
		my $n = sysread($sock, my $buf, 16384);
		if (!defined $n || $n == 0) {
			$self->_onClosed;
			return;
		}
		$client->read($buf);
	});

	$self->connected(1);
}

sub disconnect {
	my $self = shift;

	Slim::Utils::Timers::killTimers($self, \&_reconnectTimer);

	if (my $sock = $self->_sock) {
		Slim::Networking::Select::removeRead($sock);
		close($sock);
	}

	$self->_sock(undef);
	$self->_client(undef);
	$self->connected(0);
}

sub _onClosed {
	my $self = shift;

	return unless $self->connected;    # already handled

	main::INFOLOG && $log->is_info && $log->info(
		"SoloistWS: connection lost for " . ($self->mac // '?')
	);

	if (my $sock = $self->_sock) {
		Slim::Networking::Select::removeRead($sock);
		close($sock);
	}
	$self->_sock(undef);
	$self->_client(undef);
	$self->connected(0);

	$self->_scheduleReconnect;
}

# WS loss is NOT daemon death (RESEARCH Pattern 2) -- removeRead + timer
# retry with doubling backoff while the daemon process stays alive; give up
# silently once it's dead (the alive-poll owns process recovery).
sub _scheduleReconnect {
	my $self = shift;

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

# _onWsError($self, $err) -- Pitfall 1: the module this class deliberately
# avoids has an on(error) handler that calls exit(), taking the whole LMS
# process down on a single WS protocol error. This handler NEVER dies/exits
# -- log + reconnect.
sub _onWsError {
	my ($self, $err) = @_;
	$log->warn("SoloistWS: protocol error for " . ($self->mac // '?') . ": " . ($err // 'unknown'));
	$self->_onClosed;
}

# sendCommand($command, %params) -- returns 0 (with a debug log) when not
# connected; callers (73-02) fall back to the Web API control path.
sub sendCommand {
	my ($self, $command, %params) = @_;

	my $client = $self->_client;
	unless ($client && $self->connected) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: sendCommand($command) dropped -- not connected (" . ($self->mac // '?') . ")"
		);
		return 0;
	}

	$client->write(to_json({ type => 'command', command => $command, %params }));
	return 1;
}

# _onMessage($json_text) -- V5/T-73-03: never die on malformed input, this
# runs inside the single LMS process. Dispatches on $msg->{type}.
sub _onMessage {
	my ($self, $json_text) = @_;

	my $msg = eval { from_json($json_text) };
	if ($@ || ref($msg) ne 'HASH') {
		$log->warn("SoloistWS: malformed JSON from daemon (" . ($self->mac // '?') . "): " . ($@ || 'not a JSON object'));
		return;
	}

	my $type = $msg->{type};
	return unless defined $type;

	if ($type eq 'auth_state') {
		return $self->_onAuthState($msg);
	}
	if ($type eq 'device_changed') {
		return $self->_onDeviceChanged($msg);
	}
	if ($type eq 'track_changed') {
		return $self->_onTrackChanged($msg);
	}
	if ($type eq 'playback_changed') {
		return $self->_onPlaybackChanged($msg);
	}
	if ($type eq 'volume_changed') {
		return $self->_onVolumeChanged($msg);
	}
	if ($type eq 'position_sync') {
		return $self->_onPositionSync($msg);
	}
	if ($type eq 'playback_state') {
		return $self->_onPlaybackState($msg);
	}
	if ($type eq 'error') {
		$log->warn("SoloistWS: daemon reported error (" . ($self->mac // '?') . "): " . ($msg->{message} // 'unknown'));
		return;
	}

	# context_changed/options_changed/queue_changed/command_result: debug-log
	# only in this plan -- not part of the Phase 73 core event set
	# (queue_changed is consumed by 73-03 for the browse queue-seed
	# confirmation). Logged at debug so field-name corrections (A4) are
	# cheap during UAT.
	main::DEBUGLOG && $log->is_debug && $log->debug(
		"SoloistWS: unhandled event type '$type' (" . ($self->mac // '?') . ")"
	);
}

sub _onAuthState {
	my ($self, $msg) = @_;

	# T-73-04 (spoofing plausibility check, defense-in-depth on top of the
	# Pitfall-2 stale-ws.port mitigation in SoloistDaemon): a stale ws.port
	# pointing at a foreign process would announce an unexpected
	# device_name -- warn loudly and disconnect rather than trust events
	# from a process we didn't spawn.
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

	$self->authState({
		logged_in   => $msg->{logged_in} ? 1 : 0,
		is_active   => $msg->{is_active} ? 1 : 0,
		device_name => $msg->{device_name},
	});

	# Per-mac status snapshot for Settings (73-04). Best-effort -- never
	# lets a cache hiccup break event processing.
	eval {
		require Slim::Utils::Cache;
		require Plugins::SpotOn::Plugin;
		my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
		(my $macClean = $self->mac || '') =~ s/://g;
		$cache->set("spoton_soloist_ws_$macClean", {
			logged_in   => $msg->{logged_in} ? 1 : 0,
			is_active   => $msg->{is_active} ? 1 : 0,
			device_name => $msg->{device_name},
			seen_at     => time(),
		}, 3600);
		1;
	};
}

sub _onDeviceChanged {
	my ($self, $msg) = @_;

	if ($msg->{is_active}) {
		$self->sessionActive(1);
		# Reconnect mid-session: track_changed may already have arrived.
		$self->_emitStart($self->lastTrackId) if defined $self->lastTrackId;
	}
	else {
		$self->sessionActive(0);
		$self->_emit('stop');
	}
}

sub _onTrackChanged {
	my ($self, $msg) = @_;

	my $uri = $msg->{item} && $msg->{item}{uri};
	main::DEBUGLOG && $log->is_debug && $log->debug(
		"SoloistWS: track_changed raw event (" . ($self->mac // '?') . "): " . ($uri // 'no uri')
	);

	return unless defined $uri;
	# T-22-01 discipline: validate before any id reaches an LMS command.
	return unless $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/;
	my $newId = $1;

	my $prevId = $self->lastTrackId;
	$self->lastTrackId($newId);

	if (!defined $prevId) {
		$self->_emitStart($newId);
	}
	else {
		$self->_emit('change', $newId, $prevId);
	}
}

sub _onPlaybackChanged {
	my ($self, $msg) = @_;

	my $status = $msg->{status} // '';

	if ($status eq 'playing') {
		my $posSec = defined $self->lastPositionMs
			? sprintf('%.3f', $self->lastPositionMs / 1000)
			: '0.000';
		$self->_emit('resume', $self->lastTrackId, $posSec);
	}
	elsif ($status eq 'paused' || $status eq 'stopped') {
		# librespot collapses Paused+Stopped identically -- Connect.pm has
		# no 'pause' verb (RESEARCH Pattern 3).
		$self->_emit('stop');
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: unrecognized playback_changed status '$status' (" . ($self->mac // '?') . ")"
		);
	}
}

sub _onVolumeChanged {
	my ($self, $msg) = @_;
	return unless defined $msg->{volume};
	$self->_emit('volume', $msg->{volume});
}

sub _onPositionSync {
	my ($self, $msg) = @_;

	my $posMs = $msg->{position_ms};
	return unless defined $posMs;

	my $now = Time::HiRes::time();

	if (defined $self->lastPositionMs && defined $self->lastPositionTs) {
		my $expectedMs = $self->lastPositionMs + (($now - $self->lastPositionTs) * 1000);
		my $deltaSec   = abs($posMs - $expectedMs) / 1000;
		if ($deltaSec > SEEK_THRESHOLD) {
			$self->_emit('seek', sprintf('%.3f', $posMs / 1000));
		}
	}

	$self->lastPositionMs($posMs);
	$self->lastPositionTs($now);
}

# Snapshot on connect / get_state response -- initial resync after a WS
# (re)connect (position/track/volume), and, if the daemon is already active
# and playing, runs the start flow (covers the case where LMS-side WS
# reconnected but the Connect session on Soloist's side never dropped).
sub _onPlaybackState {
	my ($self, $msg) = @_;

	my $item = $msg->{item};
	my $uri  = $item && $item->{uri};
	if (defined $uri && $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/) {
		$self->lastTrackId($1);
	}

	if (defined $msg->{position}) {
		my $posMs = ref($msg->{position}) eq 'HASH' ? $msg->{position}{position_ms} : $msg->{position};
		if (defined $posMs) {
			$self->lastPositionMs($posMs);
			$self->lastPositionTs(Time::HiRes::time());
		}
	}

	if ($msg->{is_active} && ($msg->{status} // '') eq 'playing' && !$self->sessionActive) {
		$self->sessionActive(1);
		$self->_emitStart($self->lastTrackId) if defined $self->lastTrackId;
	}
}

sub _emitStart {
	my ($self, $trackId) = @_;
	$self->_emit('start', $trackId, '');
}

# _emit($cmd, $p2, $p3) -- dispatches ['spottyconnect', $cmd, $p2, $p3] on
# this player's client, the exact vocabulary Connect.pm's addDispatch
# consumes. Two gates before ANY Connect emission (RESEARCH Pattern 3):
sub _emit {
	my ($self, $cmd, $p2, $p3) = @_;

	return unless $self->_emitAllowed;

	my $client = Slim::Player::Client::getClient($self->mac);
	return unless $client;

	$client->execute(['spottyconnect', $cmd, $p2 // '', $p3 // '']);
}

sub _emitAllowed {
	my $self = shift;

	# (b) browseSession reserves browse-managed sessions (73-03).
	return 0 if $self->browseSession;

	my $client = Slim::Player::Client::getClient($self->mac);
	return 0 unless $client;

	# (a) per-player Connect toggle -- soloist has no discovery-off flag, so
	# the toggle is enforced here at the event boundary. The device stays
	# VISIBLE in the Spotify app's picker regardless; only the LMS-side
	# reaction is gated.
	my $enabled = $prefs->client($client)->get('enableSpotifyConnect')
		// $prefs->get('enableSpotifyConnect');
	return $enabled ? 1 : 0;
}

1;
