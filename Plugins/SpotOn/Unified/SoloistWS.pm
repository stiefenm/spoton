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
use Scalar::Util qw(blessed);
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

# Seconds; WR-01 -- the vendored Protocol::WebSocket::Client has no handshake
# timeout of its own. A daemon that accepts the TCP connect but never answers
# the WS handshake would otherwise leave this object waiting forever with
# connected() correctly still false (safe), but the dead socket never cleaned
# up and no reconnect ever scheduled.
use constant HANDSHAKE_TIMEOUT => 5;

# 73-03 Task 2 (D-03, RESEARCH Pattern 6, Modell B): seconds of remaining
# track duration at which the browse session seeds the next LMS-Spotify
# playlist entry into Soloist's own queue via add_to_queue. Chosen well
# inside the Task-1-DEFERRED-default takeover-gap assumption (<500ms) so
# the seed always lands long before the track actually ends.
use constant BROWSE_SEED_LEAD_SECONDS => 15;

__PACKAGE__->mk_accessor( rw => qw(
	mac
	port
	connected
	authState
	lastTrackId
	lastPositionMs
	lastPositionTs
	lastVolume
	lastCommand
	sessionActive
	browseSession
	browseCurrentUri
	browseSeededUri
	browseAdvancePending
	browseAdvanceTs
	reconnectDelay
	_sock
	_client
	_sockOpen
) );
# CR-01 fix: Slim::Utils::Accessor objects are blessed ARRAY refs (verified
# against the real LMS Slim/Utils/Accessor.pm), not hashes -- a plain 'rw'
# accessor plus a manual `weaken($self->{daemon})` was a hash dereference on
# an array ref and died on every real LMS. The 'weak' accessor type weakens
# the reference natively on every store, so no manual weaken() call is
# needed at all.
__PACKAGE__->mk_accessor( weak => qw( daemon ) );
# 73-03 Task 2: browseSession activates Model B (RESEARCH Pattern 6) -- a
# browse-managed session and a Connect session are mutually exclusive per
# player (the browseSession emit gate below, established in 73-01, is what
# enforces that mutual exclusion for spottyconnect translation).
# browseCurrentUri:      the spotify:track:/episode: URI LMS believes is
#                        currently playing (set by startBrowseTrack, and
#                        again on a successful seeded-match advance).
# browseSeededUri:       the URI queued ahead via add_to_queue for the
#                        current track, if any; cleared once track_changed
#                        confirms the transition (or a new track starts).
# browseAdvancePending:  set right before the source-marked
#                        ['playlist','index','+1'] request is executed on a
#                        seeded-match advance -- ProtocolHandler::getNextTrack
#                        reads+clears this to skip re-issuing `play` for a
#                        track Soloist is already playing (re-entry guard,
#                        T-73-11).
# browseAdvanceTs:       wallclock time of the last browse-advance/start
#                        request this module issued to LMS (CR-02) -- LMS
#                        internally stops the PREVIOUS playlist item during a
#                        playlist jump (or the very first play), generating
#                        an un-sourced stop/pause notification. The source
#                        marker on the ['playlist','index','+1'] request
#                        itself doesn't catch that internal notification, so
#                        Connect.pm's _onPause browse branch instead checks
#                        this timestamp (short grace window) before
#                        forwarding a pause to the daemon -- mirroring the
#                        Connect path's own connectStartTime grace period.
# _sockOpen:             WR-01 -- true from the moment the TCP socket is
#                        established until it is torn down, independent of
#                        `connected` (which is now true only once the WS
#                        handshake completes). _onClosed's re-entry guard
#                        checks THIS flag, not `connected`, so a socket that
#                        never completes the handshake still gets cleaned up
#                        and reconnected.

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

sub new {
	my ($class, %args) = @_;

	my $self = $class->SUPER::new();

	$self->daemon($args{daemon});    # 'weak' accessor -- weakens on store, daemon owns the ws, not vice versa
	$self->mac($args{mac});
	$self->port($args{port});

	$self->connected(0);
	$self->_sockOpen(0);
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
	$self->_sockOpen(1);    # WR-01: socket lifecycle, independent of handshake completion

	$client->on(
		write   => sub { my $frame = $_[1]; my $s = $self->_sock; syswrite($s, $frame) if $s; },
		read    => sub { my $text  = $_[1]; $self->_onMessage($text); },
		error   => sub { my $err   = $_[1]; $self->_onWsError($err); },    # NEVER exit (Pitfall 1)
		ping    => sub { $_[0]->pong($_[1]); },                            # RFC 6455 keepalive
		eof     => sub { $self->_onClosed; },
		connect => sub {
			# WR-01: this fires only once the WS handshake actually completes
			# -- the vendored Protocol::WebSocket::Client::write() silently
			# drops frames with only a warn() while is_ready is false, so
			# connected(1) must NOT be set any earlier (a command sent in
			# that window would otherwise be reported as delivered while
			# actually being dropped, defeating the D-15 Web API fallback).
			Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);
			$self->connected(1);
			$self->reconnectDelay(RECONNECT_DELAY_MIN);    # WR-02: reset backoff after a successful (re)connect
			$self->sendCommand('get_auth_state');
		},
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

	# WR-01: the vendored client has no handshake timeout of its own -- a
	# daemon that accepts the TCP connect but never completes the WS
	# handshake would otherwise leave this socket open (and `connected`
	# correctly false) forever, with no reconnect ever scheduled.
	Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + HANDSHAKE_TIMEOUT, \&_handshakeTimeoutTimer);
}

# _handshakeTimeoutTimer($self) -- WR-01: fires HANDSHAKE_TIMEOUT seconds
# after a TCP connect if the WS handshake ('connect' callback above) never
# completed. No-op if it already did (timer is killed there).
sub _handshakeTimeoutTimer {
	my $self = shift;
	return if $self->connected;

	$log->warn("SoloistWS: WS handshake timed out for " . ($self->mac // '?'));
	$self->_onClosed;
}

sub disconnect {
	my $self = shift;

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
}

sub _onClosed {
	my $self = shift;

	return unless $self->_sockOpen;    # already handled -- WR-01: gate on socket lifecycle, not handshake state

	main::INFOLOG && $log->is_info && $log->info(
		"SoloistWS: connection lost for " . ($self->mac // '?')
	);

	Slim::Utils::Timers::killTimers($self, \&_handshakeTimeoutTimer);

	if (my $sock = $self->_sock) {
		Slim::Networking::Select::removeRead($sock);
		close($sock);
	}
	$self->_sock(undef);
	$self->_client(undef);
	$self->connected(0);
	$self->_sockOpen(0);

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
#
# T-22-01/T-73-07 discipline: any command carrying a `uri` param
# (add_to_queue, play-with-uri) is validated against the track/episode URI
# shape before it ever reaches the wire -- a malformed or attacker-controlled
# URI is refused rather than forwarded to the daemon.
sub sendCommand {
	my ($self, $command, %params) = @_;

	if (defined $params{uri} && $params{uri} !~ /^spotify:(?:track|episode):[A-Za-z0-9]+$/) {
		$log->warn("SoloistWS: refusing to send '$command' with invalid uri (" . ($self->mac // '?') . "): " . $params{uri});
		return 0;
	}

	my $client = $self->_client;
	unless ($client && $self->connected) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: sendCommand($command) dropped -- not connected (" . ($self->mac // '?') . ")"
		);
		return 0;
	}

	# T-73-09 (repudiation -- silent {type:error} replies): kept 1-deep, no
	# queue. Enough for the error handler below to log which command a
	# terse daemon error response was actually reacting to.
	$self->lastCommand($command);

	$client->write(to_json({ type => 'command', command => $command, %params }));
	return 1;
}

# sendRepeatMode($mode) -- RESEARCH Pitfall 6: set_repeat_context and
# set_repeat_track are independent toggles; the official WS docs table lists
# a self-contradictory row for 'track' mode and corrects itself in a
# footnote. This follows the FOOTNOTE, not the table:
#   off     => (context: false, track: false)
#   context => (context: true,  track: false)
#   track   => (context: false, track: true)
# Two sequential commands -- there is no combined/atomic repeat command in
# the wire vocabulary. Any unrecognized $mode is treated as 'off'
# (fail-safe -- never silently arms track-repeat on a typo).
sub sendRepeatMode {
	my ($self, $mode) = @_;

	my ($context, $track) = (0, 0);
	if (($mode // '') eq 'context') {
		($context, $track) = (1, 0);
	}
	elsif (($mode // '') eq 'track') {
		($context, $track) = (0, 1);
	}

	my $r1 = $self->sendCommand('set_repeat_context', enabled => ($context ? \1 : \0));
	my $r2 = $self->sendCommand('set_repeat_track',   enabled => ($track   ? \1 : \0));
	return $r1 && $r2;
}

# sendShuffle($bool) -- set_shuffle {enabled}.
sub sendShuffle {
	my ($self, $enabled) = @_;
	return $self->sendCommand('set_shuffle', enabled => ($enabled ? \1 : \0));
}

# NOTE: activate/deactivate need no dedicated wrapper -- the generic
# sendCommand() above already covers them (`sendCommand('activate')` /
# `sendCommand('deactivate')`). They are the LMS-initiated-transfer escape
# hatch (RESEARCH Pattern 4) and are deliberately left unwired in this plan;
# transfer-playback in Phase 73 is entirely App/Cloud-driven (D-07).

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
	if ($type eq 'command_result') {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: command_result for '" . ($msg->{command} // $self->lastCommand // '?')
			. "' (" . ($self->mac // '?') . ")"
		);
		return;
	}
	if ($type eq 'error') {
		# T-73-09 (repudiation): silent {type:error} replies otherwise give no
		# clue which command failed -- the 1-deep lastCommand context makes
		# the warn actionable in a log without needing a full request queue.
		$log->warn("SoloistWS: daemon reported error (" . ($self->mac // '?')
			. ", last command '" . ($self->lastCommand // 'unknown') . "'): "
			. ($msg->{message} // 'unknown'));
		return;
	}

	# context_changed/options_changed/queue_changed: debug-log only in this
	# plan -- not part of the Phase 73 core event set (queue_changed is
	# consumed by 73-03 for the browse queue-seed confirmation). Logged at
	# debug so field-name corrections (A4) are cheap during UAT.
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

	# Phase 73-02 (D-05 reconnect resync): auth_state arrives both
	# unsolicited on every (re)connect and as the reply to our own
	# get_auth_state poll -- either way, once we know the session is
	# logged in, request a fresh get_state snapshot. The playback_state
	# handler below reconciles track/position/volume against whatever this
	# WS client still believes, closing the drift window opened while the
	# connection was down.
	$self->sendCommand('get_state') if $msg->{logged_in};

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
		# 73-03: is_active:false while a browse session is running means the
		# Spotify app stole the device (transfer-in) -- end the browse
		# session (D-08 spirit: a browse session and a Connect session are
		# mutually exclusive per player) so the incoming Connect flow is not
		# fighting a live browse advance/seed state.
		if ($self->browseSession) {
			main::INFOLOG && $log->is_info && $log->info(
				"SoloistWS: device_changed(is_active:false) during browse session -- app took over, handing off to Connect ("
				. ($self->mac // '?') . ")"
			);
			$self->endBrowseSession('handover');
		}
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

	# 73-03: browse-session events never reach the Connect translation --
	# route to the Model-B advance/correction state machine instead.
	if ($self->browseSession) {
		return $self->_onBrowseTrackChanged($uri);
	}

	my $prevId = $self->lastTrackId;
	$self->lastTrackId($newId);

	if (!defined $prevId) {
		$self->_emitStart($newId);
	}
	else {
		$self->_emit('change', $newId, $prevId);
	}
}

# _onBrowseTrackChanged($self, $uri) -- 73-03 Task 2 (D-03, RESEARCH Pattern
# 6 Modell B, Pitfall 4): the advance/correction state machine for a
# track_changed arriving during a browse session.
sub _onBrowseTrackChanged {
	my ($self, $uri) = @_;

	my $client = Slim::Player::Client::getClient($self->mac);
	unless ($client) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: browse track_changed but no client for " . ($self->mac // '?')
		);
		return;
	}

	my $seeded = $self->browseSeededUri;

	if (defined $seeded && $uri eq $seeded) {
		# Expected gapless transition: Soloist advanced into the queue entry
		# we seeded ahead of time. Advance the REAL LMS playlist to match --
		# source-marked so Connect.pm/other subscribers can recognize this as
		# our own request (T-73-11 re-entry guard: browseAdvancePending tells
		# ProtocolHandler::getNextTrack that Soloist is already playing this
		# track, so it must not re-issue `play`).
		main::INFOLOG && $log->is_info && $log->info(
			"SoloistWS: browse track_changed matched seeded uri $uri -- advancing LMS playlist ("
			. ($self->mac // '?') . ")"
		);

		$self->browseAdvancePending(1);
		$self->browseCurrentUri($uri);
		$self->browseSeededUri(undef);
		# CR-02: LMS internally stops the previous playlist item during this
		# jump, generating an un-sourced stop/pause notification -- record
		# the timestamp so Connect.pm's _onPause browse branch can suppress
		# forwarding that internal event as a real pause (see browseAdvanceTs).
		$self->browseAdvanceTs(Time::HiRes::time());

		my $req = Slim::Control::Request->new($client->id, ['playlist', 'index', '+1']);
		$req->source('PLUGIN_SPOTON_SOLOIST_BROWSE');
		$req->execute();
		return;
	}

	# Pitfall 4: an unrequested/unexpected URI -- Soloist autoplay (or
	# session drift) started something LMS never asked for. NEVER let this
	# free-run: if LMS's playlist still has content ahead, force Soloist
	# back onto the track LMS currently expects (browseCurrentUri) without
	# touching the LMS playlist pointer (only the seeded-match branch above
	# is allowed to move it); if LMS's queue is exhausted, there is nothing
	# left to correct back to -- pause and end the session cleanly.
	if (_hasNextPlaylistEntry($client)) {
		my $expected = $self->browseCurrentUri;
		$log->warn(sprintf(
			"SoloistWS: browse track_changed unexpected uri %s (expected %s) -- correcting (Pitfall 4, mac=%s)",
			$uri, ($expected // '?'), ($self->mac // '?')
		));
		$self->browseSeededUri(undef);
		$self->sendCommand('play', uri => $expected) if defined $expected;
	}
	else {
		$log->warn(
			"SoloistWS: browse track_changed unexpected uri $uri with no next LMS track -- pausing, ending session (Pitfall 4, mac="
			. ($self->mac // '?') . ")"
		);
		$self->endBrowseSession('queue_end');
	}
}

sub _onPlaybackChanged {
	my ($self, $msg) = @_;

	my $status = $msg->{status} // '';

	if ($self->browseSession) {
		# Task-1-DEFERRED default: a 'stopped' status with no seed sent means
		# Soloist reached the natural end of the track it was asked to play
		# (no queued follow-up). End the browse session WITHOUT sending
		# pause (Soloist already stopped on its own) and let LMS advance its
		# own playlist normally -- getNextTrack decides what happens next
		# (a fresh startBrowseTrack for another Spotify entry, or native
		# playback of a non-Spotify entry). A mid-track 'paused' status
		# during a browse session needs no handling here -- LMS-originated
		# pause/unpause forwarding is Connect.pm's job (Task 3).
		if ($status eq 'stopped' && !defined $self->browseSeededUri) {
			my $client = Slim::Player::Client::getClient($self->mac);
			main::INFOLOG && $log->is_info && $log->info(
				"SoloistWS: browse track ended with no seed -- ending session, advancing LMS normally ("
				. ($self->mac // '?') . ")"
			);
			$self->endBrowseSession('track_end');
			if ($client && _hasNextPlaylistEntry($client)) {
				my $req = Slim::Control::Request->new($client->id, ['playlist', 'index', '+1']);
				$req->source('PLUGIN_SPOTON_SOLOIST_BROWSE');
				$req->execute();
			}
		}
		return;   # browse-session events never reach the Connect translation
	}

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

	$self->_maybeSeedBrowseQueue($posMs) if $self->browseSession;

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

# _maybeSeedBrowseQueue($self, $posMs) -- 73-03 Task 2 (D-03, RESEARCH
# Pattern 6 Modell B): fires on every position_sync while a browse session
# is active. Once <BROWSE_SEED_LEAD_SECONDS remain in the current track and
# no seed has been sent yet, look up the client's NEXT LMS playlist entry;
# if (and only if) it is a spoton://track|episode: URL, queue it ahead via
# add_to_queue so Soloist can transition into it gaplessly. A non-Spotify
# next entry (radio/local) or end-of-playlist sends no seed -- Soloist will
# stop naturally at track end (Task-1-DEFERRED default), which
# _onPlaybackChanged's 'stopped'-with-no-seed branch above turns into a
# normal LMS-driven advance.
sub _maybeSeedBrowseQueue {
	my ($self, $posMs) = @_;

	return if defined $self->browseSeededUri;   # already seeded this track

	my $client = Slim::Player::Client::getClient($self->mac);
	return unless $client;

	my $song = $client->can('playingSong') ? $client->playingSong : undef;
	my $durationSec = ($song && $song->can('duration')) ? ($song->duration || 0) : 0;
	return unless $durationSec > 0;

	my $remaining = $durationSec - ($posMs / 1000);
	return unless $remaining < BROWSE_SEED_LEAD_SECONDS;

	my $nextUri = _nextBrowseSpotifyUri($client);
	unless (defined $nextUri) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: browse seeding -- next LMS entry is not a Spotify track/episode (or end of playlist), no seed sent ("
			. ($self->mac // '?') . ")"
		);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info(
		"SoloistWS: browse seeding queue with $nextUri (remaining=" . sprintf('%.1f', $remaining) . "s, mac="
		. ($self->mac // '?') . ")"
	);
	$self->browseSeededUri($nextUri) if $self->sendCommand('add_to_queue', uri => $nextUri);
}

# _hasNextPlaylistEntry($client) -- true if the LMS playlist has an entry
# (of ANY type -- Spotify or not) after the currently streaming index.
sub _hasNextPlaylistEntry {
	my ($client) = @_;
	return 0 unless $client;

	my $idx = Slim::Player::Source::streamingSongIndex($client);
	return 0 unless defined $idx;

	my $total = Slim::Player::Playlist::count($client);
	return 0 unless defined $total;

	return (($idx + 1) < $total) ? 1 : 0;
}

# _nextBrowseSpotifyUri($client) -- the spotify:track:/episode: URI for the
# LMS playlist entry after the currently streaming index, or undef if that
# entry does not exist or is not a spoton:// Browse URL (radio, local file,
# end of playlist).
sub _nextBrowseSpotifyUri {
	my ($client) = @_;
	return undef unless _hasNextPlaylistEntry($client);

	my $idx   = Slim::Player::Source::streamingSongIndex($client);
	my $track = Slim::Player::Playlist::track($client, $idx + 1);
	return undef unless $track;

	my $url = (blessed($track) && $track->can('url')) ? $track->url : $track;
	return undef unless defined $url;
	return undef unless $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$};
	return "spotify:$1:$2";
}

# startBrowseTrack($self, $uri, $client) -- 73-03 Task 2 (D-03, RESEARCH
# Pattern 6 Modell B): begins a browse-managed session for a single
# spotify:track:/episode: URI. Called from ProtocolHandler::getNextTrack.
# Entering a browse session EXPLICITLY suppresses Connect-event translation
# via the browseSession emit gate (73-01) -- a browse session and a Connect
# session are mutually exclusive per player.
sub startBrowseTrack {
	my ($self, $uri, $client) = @_;

	return 0 unless defined $uri && $uri =~ /^spotify:(?:track|episode):[A-Za-z0-9]+$/;

	$self->browseSession(1);
	$self->browseCurrentUri($uri);
	$self->browseSeededUri(undef);
	$self->browseAdvancePending(0);
	# CR-02: a fresh browse play also triggers an internal stop of the
	# previous item -- today that pause is immediately overridden by this
	# same play, but it is a race, not a guarantee. Same grace timestamp as
	# the seeded-advance path above.
	$self->browseAdvanceTs(Time::HiRes::time());

	main::INFOLOG && $log->is_info && $log->info(
		"SoloistWS: startBrowseTrack($uri) for " . ($self->mac // '?')
	);

	my $sent = $self->sendCommand('play', uri => $uri);
	unless ($sent) {
		# WR-03: the send failed (not connected / pre-handshake drop / write
		# error) -- roll back the browse state set above. Without this,
		# browseSession stays 1 (suppressing all Connect translation via
		# _emitAllowed) while LMS proceeds to open /stream and play silence,
		# a stuck state that persists until some other path ends the session.
		$log->warn("SoloistWS: startBrowseTrack($uri) send failed for " . ($self->mac // '?') . " -- rolling back browse state");
		$self->browseSession(0);
		$self->browseCurrentUri(undef);
		$self->browseAdvanceTs(0);
	}
	return $sent;
}

# Reasons that skip the `pause` send in endBrowseSession(): 'track_end'
# (Soloist already stopped on its own -- Task-1-DEFERRED default) and
# 'handover' (an active Connect session is taking over transport; pausing
# here would fight it). Every other reason (e.g. 'queue_end', the Pitfall-4
# no-next-track correction branch) sends pause -- there is no other session
# about to take over from the ended browse session in those cases.
my %_BROWSE_END_SKIP_PAUSE = (handover => 1, track_end => 1);

# endBrowseSession($self, $reason) -- clears all browse state.
sub endBrowseSession {
	my ($self, $reason) = @_;

	return unless $self->browseSession;

	main::INFOLOG && $log->is_info && $log->info(
		"SoloistWS: endBrowseSession('" . ($reason // '') . "') for " . ($self->mac // '?')
	);

	$self->browseSession(0);
	$self->browseCurrentUri(undef);
	$self->browseSeededUri(undef);
	$self->browseAdvancePending(0);

	$self->sendCommand('pause') unless $_BROWSE_END_SKIP_PAUSE{$reason // ''};
}

# Snapshot on connect / get_state response -- initial resync after a WS
# (re)connect (position/track/volume), and, if the daemon is already active
# and playing, runs the start flow (covers the case where LMS-side WS
# reconnected but the Connect session on Soloist's side never dropped).
#
# Reconciliation (RESEARCH Pitfall 5 philosophy, D-05): when a session was
# already active before this snapshot arrived, the snapshot is compared
# against what this WS client still believes rather than blindly trusted --
# a track mismatch emits 'change' (a track_changed event may never re-arrive
# for a track that was already playing across the drop), a volume mismatch
# emits 'volume', and a position mismatch beyond SEEK_THRESHOLD (extrapolated
# from the last known position + wallclock elapsed, same tolerance as
# _onPositionSync) emits 'seek'. A cold snapshot (no prior baseline) never
# emits a correction -- there is nothing yet to have drifted from.
sub _onPlaybackState {
	my ($self, $msg) = @_;

	my $item = $msg->{item};
	my $uri  = $item && $item->{uri};
	my $newId;
	if (defined $uri && $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/) {
		$newId = $1;
	}

	my $prevId = $self->lastTrackId;
	if ($self->sessionActive && defined $newId && defined $prevId && $newId ne $prevId) {
		$self->_emit('change', $newId, $prevId);
	}
	$self->lastTrackId($newId) if defined $newId;

	my $posMs;
	if (defined $msg->{position}) {
		$posMs = ref($msg->{position}) eq 'HASH' ? $msg->{position}{position_ms} : $msg->{position};
	}
	if (defined $posMs) {
		my $now = Time::HiRes::time();
		if ($self->sessionActive && defined $self->lastPositionMs && defined $self->lastPositionTs) {
			my $expectedMs = $self->lastPositionMs + (($now - $self->lastPositionTs) * 1000);
			my $deltaSec   = abs($posMs - $expectedMs) / 1000;
			if ($deltaSec > SEEK_THRESHOLD) {
				$self->_emit('seek', sprintf('%.3f', $posMs / 1000));
			}
		}
		$self->lastPositionMs($posMs);
		$self->lastPositionTs($now);
	}

	if (defined $msg->{volume}) {
		if ($self->sessionActive && defined $self->lastVolume && $msg->{volume} != $self->lastVolume) {
			$self->_emit('volume', $msg->{volume});
		}
		$self->lastVolume($msg->{volume});
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
