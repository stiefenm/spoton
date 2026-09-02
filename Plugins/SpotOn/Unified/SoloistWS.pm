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
	sessionPaused
	sessionStarted
	skipInitiated
	deactivating
	reconnectDelay
	pendingPlayConfirm
	soloistBrowseActive
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
# sessionStarted:        true once _emitStart has fired; prevents redundant
#                        'start' on device re-activation mid-session.
# skipInitiated:         260827-of9 (~30s Connect-skip audio delay): true
#                        when a track_changed arrives while sessionPaused was
#                        already true -- i.e. the daemon had already reported
#                        stopped/paused (a Spotify-app-initiated skip) BEFORE
#                        the new track announced itself, as opposed to a
#                        gapless transition (sessionPaused stays 0 throughout).
#                        Connect.pm's `change` handler reads this flag to
#                        decide whether to force a stream reconnect (playlist
#                        play spoton://connect-<ts>) so squeezelite abandons
#                        the stale buffered audio instead of draining 10-20s
#                        of it. Consumed (reset to 0) by Connect.pm once read.
# sessionPaused:         73-05 (D-06 gap 1, RESEARCH Pitfall 5): true while
#                        the daemon believes playback is paused/stopped --
#                        set by playback_changed('paused'/'stopped'), by a
#                        playback_state snapshot's status field, and by a
#                        position_sync frame's speed:0. Gates 'resume'
#                        emission to real Paused->Playing transitions only
#                        (every 'playing' status used to emit 'resume'
#                        unconditionally, including the buffering->playing
#                        sequence after every track change) and freezes the
#                        wallclock position extrapolation while paused (the
#                        expected position IS the pause position -- it does
#                        not advance just because time passes).
# deactivating:          260827-jqa (transfer-away/back position drift):
#                        set the instant _onDeviceChanged(is_active:false)
#                        begins tearing down the session, cleared the instant
#                        _onDeviceChanged(is_active:true) reactivates it.
#                        _onPlaybackChanged reads this to suppress a bogus
#                        stopped->playing blip that otherwise arrives from the
#                        daemon mid-transfer-away and would emit a spurious
#                        'resume' with a stale/corrupted position.
# _sockOpen:             WR-01 -- true from the moment the TCP socket is
#                        established until it is torn down, independent of
#                        `connected` (which is now true only once the WS
#                        handshake completes). _onClosed's re-entry guard
#                        checks THIS flag, not `connected`, so a socket that
#                        never completes the handshake still gets cleaned up
#                        and reconnected.
# soloistBrowseActive:   KE: browse-connect-gating (replaces the 78-02/78-04
#                        per-event echo guards, which raced against LMS
#                        state that had not yet settled -- see debug session
#                        .planning/debug/resolved/browse-connect-gating.md).
#                        Explicit state, not derived: set(1) ONLY by
#                        ProtocolHandler::getNextTrack right before it sends
#                        a WS 'play uri=...' command for a Browse-commanded
#                        track (never true for a genuine Connect echo -- a
#                        Connect-issued playlist play always targets a track
#                        the daemon already reports via lastTrackId, so
#                        getNextTrack's EOF-advance skip fires instead and
#                        never touches this flag). Stays true across a whole
#                        Browse session (album auto-advance never re-sends
#                        WS play -- the daemon's own queue advances and
#                        getNextTrack just confirms via lastTrackId). Cleared
#                        ONLY by _onDeviceChanged(is_active:true) below -- the
#                        authoritative Spotify-Connect-protocol signal for a
#                        genuine App-initiated transfer TO this device
#                        (73-RESEARCH.md "Transfer ZU Soloist"), never fired
#                        by Browse's own local WS play/pause commands. While
#                        true, _emit() below suppresses EVERY daemon->
#                        Connect.pm translation -- each one is either an echo
#                        of our own command or an internal auto-advance
#                        within the queue Browse seeded, never a genuine
#                        Connect event.

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
	$self->sessionPaused(0);
	$self->sessionStarted(0);
	$self->skipInitiated(0);
	$self->deactivating(0);
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

	# 73-05 (D-06): coerce known numeric params to fresh IVs before to_json.
	# A scalar that has ever been used in string context (e.g. interpolated
	# into a DIAG log line upstream) can be serialized as a quoted JSON
	# string by a JSON encoder that prefers a cached PV over IOK -- the
	# daemon rejects a quoted position_ms with "invalid JSON or missing
	# required fields" (UAT gap 2, live-verified against the soloist WS
	# port). Single choke point here covers Connect.pm's Connect-seek path
	# AND _bufferedBrowseSeek's browse-seek path. Do NOT apply this to the
	# `enabled` scalar-ref booleans (\1/\0) used elsewhere in this module --
	# int() must only ever touch position_ms and volume.
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

	# T-73-09 (repudiation -- silent {type:error} replies): kept 1-deep, no
	# queue. Enough for the error handler below to log which command a
	# terse daemon error response was actually reacting to.
	$self->lastCommand($command);

	# D-01: arm pendingPlayConfirm so the next track_changed skips
	# _signalBoundary (the first track_changed after a play is a
	# confirmation, not a track transition — no boundary to plant).
	$self->pendingPlayConfirm(1) if $command eq 'play';

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

	# 73-05 (D-05): the vendored Protocol::WebSocket::Frame::next dispatches
	# Encode::decode('UTF-8', $bytes) -- a decoded CHARACTER string -- while
	# from_json (JSON::XS::decode_json via VersionOneAndTwo) always expects
	# UTF-8 OCTETS. Without this bridge, every frame containing non-ASCII
	# metadata (i.e. every playback_state snapshot with a real track/artist
	# name) fails decode as "malformed UTF-8 character in JSON string" and is
	# silently dropped -- the root cause of UAT gap 1 (lastPositionMs never
	# updates, so resume always starts at 0). utf8::encode/utf8::is_utf8 are
	# Perl core (no new imports, Windows-safe).
	utf8::encode($json_text) if utf8::is_utf8($json_text);

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
		# 260827-jqa: clear the deactivation guard FIRST -- this is a genuine
		# re-activation (whether transfer-back or a reconnect mid-session),
		# so any bogus stopped->playing blip suppression from a prior
		# transfer-away must not leak into this new active period.
		$self->deactivating(0);

		# KE: browse-connect-gating -- device_changed(is_active:true) is the
		# authoritative Connect-protocol signal for a genuine App-initiated
		# transfer to this device (never fired by Browse's own local play/
		# pause commands). Clear the browse gate BEFORE any emission below
		# so this genuine transfer is never swallowed by the browse
		# suppression in _emit().
		if ($self->soloistBrowseActive) {
			main::INFOLOG && $log->is_info && $log->info(
				"SoloistWS: genuine Connect transfer-in -- clearing soloistBrowseActive ("
				. ($self->mac // '?') . ")"
			);
			$self->soloistBrowseActive(0);
		}

		# 260827-jqa (Fix B): capture BEFORE _emitStart, which sets this flag
		# to 1 as a side effect -- reading it afterward would make the seek
		# below fire on first activation too.
		my $wasAlreadyStarted = $self->sessionStarted;

		$self->sessionActive(1);
		# Reconnect mid-session: track_changed may already have arrived.
		# _emitStart is idempotent (sessionStarted guard).
		$self->_emitStart($self->lastTrackId) if defined $self->lastTrackId;

		# Re-activation: sync position and resume playback.
		if ($wasAlreadyStarted) {
			if (defined $self->lastPositionMs) {
				my $posSec = sprintf('%.3f', $self->lastPositionMs / 1000);
				main::INFOLOG && $log->is_info && $log->info(
					"SoloistWS: re-activation position sync -- seeking to ${posSec}s ("
					. ($self->mac // '?') . ")"
				);
				$self->_emit('seek', $posSec);
			}
			# The deactivation guard suppressed playback events that arrived
			# before this device_changed — emit resume so LMS unpauses.
			$self->sessionPaused(0);
			$self->_emit('resume', defined $self->lastPositionMs
				? sprintf('%.3f', $self->lastPositionMs / 1000) : '0.000');
		}
	}
	else {
		# 260827-jqa (Fix A -- deactivation guard): set BEFORE sessionActive/
		# _emit('stop') below so _onPlaybackChanged can immediately suppress
		# any bogus stopped->playing blip the daemon sends mid-transfer-away.
		$self->deactivating(1);

		$self->sessionActive(0);
		# GH #151: mark this stop as the SESSION-END signal (device deselected
		# in the Spotify app / transfer-away / disconnect) -- distinct from the
		# plain pause 'stop' emitted by _onPlaybackChanged. Connect.pm's stop
		# handler uses the 'inactive' marker to run the power-state restore.
		$self->_emit('stop', 'inactive');
	}
}

sub _onTrackChanged {
	my ($self, $msg) = @_;

	# WR-08: `item` payload shapes are unconfirmed (A4) -- guard against a
	# non-HASH item (scalar/array) dying with "Not a HASH reference", which
	# would abort processing of every remaining frame in this read burst.
	my $uri = (ref($msg->{item}) eq 'HASH') ? $msg->{item}{uri} : undef;
	main::DEBUGLOG && $log->is_debug && $log->debug(
		"SoloistWS: track_changed raw event (" . ($self->mac // '?') . "): " . ($uri // 'no uri')
	);

	# Phase 77 Spike 2 (Bounded Endpoint Prototype): plant a boundary marker
	# in fake-libpulse's ring buffer at the CURRENT write position, before
	# any of this method's downstream classification/return logic below.
	# track_changed is the ONLY track-boundary signal available (Spike 1
	# finding, .planning/quick/260831-boundary-spike-instrument/SUMMARY.md
	# -- Soloist's PA lifecycle is silent across track transitions, one
	# pa_stream reused for the whole session).
	# D-01: the FIRST track_changed after a WS 'play' command is a
	# confirmation, not a track transition — skip the boundary so the
	# first track serves unbounded.
	if ($self->pendingPlayConfirm) {
		$self->pendingPlayConfirm(0);
		main::INFOLOG && $log->is_info && $log->info(
			"SoloistWS: skipping boundary for play-confirm track_changed (" . ($self->mac // '?') . ")"
		);
	} else {
		$self->_signalBoundary;
	}

	return unless defined $uri;
	# T-22-01 discipline: validate before any id reaches an LMS command.
	return unless $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/;
	my $newId = $1;

	my $prevId = $self->lastTrackId;

	# Same-track re-announcement (e.g. device re-activation) — not a real transition.
	return if defined $prevId && $newId eq $prevId;

	$self->lastTrackId($newId);

	# 260827-of9: if the daemon already believed playback was paused/stopped
	# BEFORE this track_changed arrived, this is a Spotify-app-initiated skip
	# (as opposed to a gapless transition, where sessionPaused stays 0 the
	# whole time) -- flag it so Connect.pm's `change` handler can force a
	# stream reconnect. MUST be read before the sessionPaused(0) reset below.
	$self->skipInitiated(1) if $self->sessionPaused;

	# A track change is not a paused state — clear so the next 'playing'
	# event is not misread as a resume (which would fire get_state back
	# at the daemon and corrupt Spotify's progress bar).
	$self->sessionPaused(0);

	if (!defined $prevId) {
		$self->_emitStart($newId);
	}
	else {
		$self->_emit('change', $newId, $prevId);
	}
}

# _signalBoundary($self) -- Phase 77 Spike 2 (Bounded Endpoint Prototype).
#
# Fire-and-forget loopback POST to fake-libpulse's /boundary control
# endpoint, on the SAME daemon process's HTTP stream port (127.0.0.1-only
# surface -- the streaming port itself is LAN-exposed for LMS players, but
# this control request only ever originates from this process, same as the
# WS control connection in connect() above). Plants a marker at the ring
# buffer's current write position so the bounded HTTP serve loop can close
# the socket there (= real EOF for LMS auto-advance).
#
# Synchronous, eval-guarded, short-timeout -- same discipline as connect()'s
# blocking IO::Socket::INET probe (sub-5ms on localhost per RESEARCH Pattern
# 2). Silently no-ops if the daemon or its HTTP stream port aren't resolved
# yet (e.g. still starting up): a missed boundary just means that one track
# won't get a bounded EOF, not a crash -- acceptable fail-open behavior for
# this prototype.
sub _signalBoundary {
	my $self = shift;

	my $daemon = $self->daemon or return;
	my $httpPort = $daemon->_streamPort or return;

	eval {
		my $sock = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $httpPort,
			Proto    => 'tcp',
			Timeout  => 0.1,
		);
		if ($sock) {
			print $sock "POST /boundary HTTP/1.0\r\nConnection: close\r\n\r\n";
			close($sock);
		}
	};
	if ($@) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: boundary signal failed (" . ($self->mac // '?') . "): $@"
		);
	}
}

sub _onPlaybackChanged {
	my ($self, $msg) = @_;

	my $status = $msg->{status} // '';

	# 260827-jqa (Fix A -- deactivation guard): the daemon sends a bogus
	# stopped->playing blip during transfer-away (device_changed
	# is_active:false already emitted the real 'stop') -- suppress
	# playing/stopped/paused status entirely while deactivating so it can
	# never reach the resume or stop logic below with a corrupted
	# startOffset. Re-activation (_onDeviceChanged is_active:true) clears
	# this flag as its first action, so this guard cannot leak past a
	# genuine transfer-back.
	if ($self->deactivating && ($status eq 'playing' || $status eq 'stopped' || $status eq 'paused')) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: suppressing playback_changed '$status' during deactivation (" . ($self->mac // '?') . ")"
		);
		return;
	}

	# D-02 (Phase 78): natural track/session end plants a boundary marker
	# so the bounded serve closes with a clean EOF instead of leaving the
	# connection open into LMS's ~10s retry timeout. ONLY 'stopped' --
	# 'paused' is NOT a track end (Pause != EOF). Hangs on the RAW
	# $msg->{status}, never the collapsed Paused+Stopped _emit('stop')
	# translation below.
	$self->_signalBoundary if $status eq 'stopped';

	if ($status eq 'playing') {
		# 73-05 (D-06 gap 1): resume must only be emitted for a REAL
		# Paused->Playing transition -- every 'playing' status used to emit
		# 'resume' unconditionally, including the buffering->playing
		# sequence fired after every track change (live UAT log: resume with
		# position=0.000 within ~60ms of every track_changed 'change'). The
		# track_changed start/change flow owns the track-start transition.
		if ($self->sessionPaused) {
			my $posSec = defined $self->lastPositionMs
				? sprintf('%.3f', $self->lastPositionMs / 1000)
				: '0.000';
			$self->_emit('resume', $self->lastTrackId, $posSec);

			# The baseline value IS the pause position; the wallclock anchor
			# must restart at resume so the next extrapolation does not
			# count the paused interval as elapsed playback time.
			$self->lastPositionTs(Time::HiRes::time());
			$self->sessionPaused(0);

			# Post-resume reconciliation: any residual drift is caught
			# through the existing tolerance-gated seek path once the
			# get_state reply (a playback_state snapshot) arrives.
			$self->sendCommand('get_state');
		}
	}
	elsif ($status eq 'paused' || $status eq 'stopped') {
		# librespot collapses Paused+Stopped identically -- Connect.pm has
		# no 'pause' verb (RESEARCH Pattern 3).
		$self->sessionPaused(1);
		$self->_emit('stop');
	}
	elsif ($status eq 'buffering') {
		# Live-verified: the daemon sends 'buffering' between track
		# transitions -- a recognized no-op, not an unrecognized status.
		main::DEBUGLOG && $log->is_debug && $log->debug(
			"SoloistWS: playback_changed 'buffering' (recognized no-op, " . ($self->mac // '?') . ")"
		);
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

	# 73-05 (D-06, Pitfall 5): speed 0 is the daemon's own signal that
	# playback is currently paused -- update sessionPaused directly from
	# this field so a position_sync frame alone (with no preceding
	# playback_changed event) can freeze the extrapolation correctly.
	if (defined $msg->{speed}) {
		$self->sessionPaused($msg->{speed} ? 0 : 1);
	}

	my $now = Time::HiRes::time();

	# CR-S1 (Phase 77 Plan 02): drift detection extracted to a shared helper
	# below -- _onPositionSync does NOT require sessionActive (guard stays
	# here, not inside the helper; see _onPlaybackState for the divergent
	# guard).
	if (defined $self->lastPositionMs && defined $self->lastPositionTs) {
		$self->_detectSeek($posMs, $now);
	}

	$self->lastPositionMs($posMs);
	$self->lastPositionTs($now);
}

# CR-S1 (Phase 77 Plan 02, PATTERNS "CR-S1 helper extraction"):
# shared drift computation, extracted from the byte-for-byte identical
# blocks that used to live inline in _onPositionSync and _onPlaybackState.
#
# Frozen baseline while paused: the expected position IS the last known
# position -- it must not advance with wallclock time just because the app
# hasn't moved (the elapsed paused interval is not elapsed PLAYBACK time).
#
# CRITICAL (PATTERNS-verified divergence): the guards that decide WHETHER
# to call this helper stay at the two call sites, not inside it --
# _onPositionSync's guard never checks sessionActive; _onPlaybackState's
# guard additionally requires $self->sessionActive. Do not add a
# sessionActive check in here.
sub _detectSeek {
	my ($self, $posMs, $now) = @_;

	my $elapsedMs  = $self->sessionPaused ? 0 : (($now - $self->lastPositionTs) * 1000);
	my $expectedMs = $self->lastPositionMs + $elapsedMs;
	my $deltaSec   = abs($posMs - $expectedMs) / 1000;
	if ($deltaSec > SEEK_THRESHOLD) {
		$self->_emit('seek', sprintf('%.3f', $posMs / 1000));
	}
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

	# WR-08: guard against a non-HASH item, mirroring the `position` handling
	# just below (already ref-checked).
	my $item = $msg->{item};
	my $uri  = (ref($item) eq 'HASH') ? $item->{uri} : undef;
	my $newId;
	if (defined $uri && $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/) {
		$newId = $1;
	}

	my $prevId = $self->lastTrackId;
	if ($self->sessionActive && defined $newId && defined $prevId && $newId ne $prevId) {
		$self->_emit('change', $newId, $prevId);
	}
	$self->lastTrackId($newId) if defined $newId;

	# 73-05 (D-06, Pitfall 5): derive sessionPaused from this snapshot's own
	# status field BEFORE the position reconciliation below, so the frozen-
	# elapsed rule applies to the very snapshot that reports the pause.
	# other/absent status leaves sessionPaused untouched (no signal either way).
	my $snapshotStatus = $msg->{status};
	if (defined $snapshotStatus) {
		if ($snapshotStatus eq 'paused' || $snapshotStatus eq 'stopped') {
			$self->sessionPaused(1);
		}
		elsif ($snapshotStatus eq 'playing') {
			$self->sessionPaused(0);
		}
	}

	my $posMs;
	if (defined $msg->{position}) {
		$posMs = ref($msg->{position}) eq 'HASH' ? $msg->{position}{position_ms} : $msg->{position};
	}
	if (defined $posMs) {
		my $now = Time::HiRes::time();
		# CR-S1: same helper as _onPositionSync, but this call site's guard
		# additionally requires sessionActive (divergence from
		# _onPositionSync, preserved deliberately).
		if ($self->sessionActive && defined $self->lastPositionMs && defined $self->lastPositionTs) {
			$self->_detectSeek($posMs, $now);
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

	# Fire at most once per WS-client lifetime — new object on genuine restart.
	return if $self->sessionStarted;
	$self->sessionStarted(1);

	$self->_emit('start', $trackId, '');
}

# _emit($cmd, $p2, $p3) -- dispatches ['spottyconnect', $cmd, $p2, $p3] on
# this player's client, the exact vocabulary Connect.pm's addDispatch
# consumes. Two gates before ANY Connect emission (RESEARCH Pattern 3):
sub _emit {
	my ($self, $cmd, $p2, $p3) = @_;

	return unless $self->_emitAllowed;

	# KE: browse-connect-gating -- while Browse is actively driving this
	# daemon session (soloistBrowseActive), every daemon event is either an
	# echo of our own command or an internal auto-advance within the queue
	# Browse seeded -- never a genuine Connect event. Suppress at the
	# source instead of trying to discriminate downstream in Connect.pm
	# against LMS song state that has not necessarily settled yet (the
	# race that made the 78-02/78-04 per-event echo guards unreliable).
	if ($self->soloistBrowseActive) {
		main::INFOLOG && $log->is_info && $log->info(
			"SoloistWS: suppressing spottyconnect '$cmd' -- Soloist Browse session active ("
			. ($self->mac // '?') . ")"
		);
		return;
	}

	my $client = Slim::Player::Client::getClient($self->mac);
	return unless $client;

	$client->execute(['spottyconnect', $cmd, $p2 // '', $p3 // '']);
}

sub _emitAllowed {
	my $self = shift;

	my $client = Slim::Player::Client::getClient($self->mac);
	return 0 unless $client;

	# Per-player Connect toggle -- soloist has no discovery-off flag, so
	# the toggle is enforced here at the event boundary. The device stays
	# VISIBLE in the Spotify app's picker regardless; only the LMS-side
	# reaction is gated.
	my $enabled = $prefs->client($client)->get('enableSpotifyConnect')
		// $prefs->get('enableSpotifyConnect');
	return $enabled ? 1 : 0;
}

1;
