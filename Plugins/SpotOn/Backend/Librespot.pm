package Plugins::SpotOn::Backend::Librespot;

# Phase 84-07 (SEAM-6.2): the librespot implementation of the backend role.
#
# Transport commands go to the librespot daemon's HTTP control endpoints
# (/control/play|pause|volume|next|prev), with the GH #159 409 rule. The
# sender was moved here from Connect.pm (_sendControlCommand) -- log texts
# and the source mark of the 409 stop are unchanged (t/56 characterization).
# 85-07 D-10: deadened -- when the endpoint is unreachable the failure is
# recorded on the status page ("Daemon nicht erreichbar"); there is no Web
# API fallback any more.
#
# librespot has no Control instance: notify() is 'unsupported', query() is
# undef ("no opinion"), state() has no mode.

use strict;
use warnings;

use Scalar::Util qw(blessed refaddr weaken);
use Time::HiRes ();
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

# The source mark Connect.pm's _onPause loop guard compares against
# (`$request->source eq __PACKAGE__` there). The 409 eject stop below must
# keep carrying Connect's package name, not this one, or _onPause would
# echo the stop back to the daemon (T-05-13 / T-76-05).
use constant CONNECT_SOURCE => 'Plugins::SpotOn::Connect';

# Capability constants; the player-independent subset is the class-level
# capabilitiesDefault (84-08).
my %CAPABILITIES = (
    contentType       => 'son',          # ProtocolHandler contentType's else-branch
    samplesize        => 16,
    samplerate        => 44100,
    channels          => 2,
    connectEntry      => 'repeating',    # spoton://connect-%u, one entry per session
    formats           => 'resolveServedPassthroughForClient',   # 79-34 D-29: the tag follows the serving daemon
    seekViaRestart    => 1,              # Browse seek = new /track/<id>?start_position=N stream
    ownsQueueInBrowse => 0,              # LMS owns the Browse playlist
    deferTrack        => 0,
    deaden            => [],
    connectClaimGate  => 1,              # handlers gate on isSpotifyConnect + the echo-suppression chain
    claimOnStart      => 1,              # generic spottyconnect `start` claims ownership
    holdOnChange      => 0,              # no 84-17 change hold
    holdCapS          => 0,
    holdRecheckS      => 0,
    holdMaxS          => 0,
    readyReplaysLastTrack => 0,          # `ready` re-enters through a fresh connect-<ts> stream
    connectSeekViaControl => 1,          # 79-28 D-23: an LMS seek in Connect is POSTed to /control/seek, no /stream restart
    claimPerAccount   => 0,              # 90.1 D-03: no account concept in this role, one claim as before
);

# verb -> /control/* endpoint, and the info line that sat next to each
# send in Connect.pm (text unchanged).
my %ENDPOINT = (
    play       => '/control/play',
    pause      => '/control/pause',
    set_volume => '/control/volume',
    skip_next  => '/control/next',
    skip_prev  => '/control/prev',
    seek       => '/control/seek',     # 79-28 D-23: the binary has it (unified.rs:1250-1255)
);
my %SEND_INFO = (
    play      => 'Got unpause event - forwarding to Connect binary via HTTP /control/play (D-14)',
    pause     => 'Got a pause event - forwarding to Connect binary via HTTP /control/pause (D-14)',
    skip_next => 'Connect mode: forwarding skip-next to binary /control/next (D-14)',
    skip_prev => 'Connect mode: forwarding skip-previous to binary /control/prev (D-14)',
);

# 88-06 (D-03): how long a pull-back (POST /control/transfer, answered 204 = dispatched)
# may wait for the session to arrive as a `start`/`change` before the open falls back
# to Browse. 8 s = ceil(1.5 x 5.33 s): 5.33 s is the accepted upper latency of a
# connect_transfer measured in phase 84 (STATE decision 2026-10-13), 1.5 is the margin.
use constant TRANSFER_WAIT_S => 8;

# 88 review WR-01: the recovering helper refuses every /control command with
# 503 + `Retry-After: 2` (unified.rs control_status). LMS has already applied
# the user's Play / Pause at that point, so a dropped command leaves LMS and
# Spotify apart (LMS paused while the recovery plays on; LMS streaming a paused
# session). The transport pair is retried through an LMS timer, never blocking:
#   - only /control/play and /control/pause (the two states that diverge
#     audibly); volume/seek/next/prev keep the drop, logged at warn
#   - the delay is the Retry-After when it is 1..CONTROL_RETRY_MAX_DELAY_S s,
#     else CONTROL_RETRY_DEFAULT_S
#   - at most CONTROL_RETRY_MAX retries per command (15 x 2 s = 30 s, the
#     helper's own RECOVERY_TRANSFER_MAX_AGE; a recovery ends inside it)
#   - the newest transport command wins: it voids a pending retry, and the 503
#     of an older command arms nothing (%_transportSeq)
#   - never for a player that plays another song by then (identity of the
#     playing Song, held weakly): a late retry must not eject other content
#     through the 409 branch
#   - never across the end of the Connect session it was issued in (88 review
#     rounds 2 and 3, user decisions 2026-11-18 "Verwerfen" and "Lueckenlos
#     fixen"). Three guarantees:
#       1. the claim state is sampled when the command is ISSUED (not when its
#          503 arrives) and travels with the record through the whole chain;
#       2. at due time a changed claim state drops the retry (`stop inactive`
#          reached LMS first; the Song object is the same afterwards, a late
#          Play would meet a 409);
#       3. a 409 on a retried Play that was armed under a claim ejects and
#          releases but never reopens the entry (the reopen is the
#          /control/transfer that pulls the session back from the device the
#          user moved to). This covers the cases where the 409 is the first
#          news of the session end: the retry sent in the race before LMS has
#          processed `stop inactive`, and a replaced helper (nothing releases
#          the claim then).
#     The stale pass-through (no claim when armed) keeps its retry and its
#     reopen. Accepted cost: a player whose claim was already dormant before
#     the press (kept by the restart gate, device not active) needs a second
#     Play, which then takes the ordinary 409 path.
# State: ONE record per player in its pluginData (connectControlRetry:
# endpoint, body, retries, song, claimed); a cleared record is written as 0.
use constant CONTROL_RETRY_MAX         => 15;
use constant CONTROL_RETRY_DEFAULT_S   => 2;
use constant CONTROL_RETRY_MAX_DELAY_S => 5;
my %RETRY_ENDPOINT = map { $_ => 1 } ('/control/play', '/control/pause');
my %_transportSeq;      # mac -> number of the newest play/pause command issued

# Connect.pm's volume debounce window, quoted in the [DIAG] volume line.
use constant VOLUME_DEBOUNCE => 0.5;
# ... and its seek debounce (Connect.pm SEEK_DEBOUNCE), quoted in the [DIAG] seek line.
use constant SEEK_DEBOUNCE => 0.3;

sub new {
    my ($class, $mac) = @_;
    return bless { mac => $mac }, $class;
}

sub mac { return $_[0]->{mac}; }

sub daemonClass { return 'Plugins::SpotOn::Unified::Daemon'; }

# client([$client]) -- the (master) client object DaemonManager::backendFor
# last resolved for this mac, held weakly; falls back to the LMS registry.
sub client {
    my $self = shift;
    if (@_) {
        $self->{client} = shift;
        weaken($self->{client}) if ref $self->{client};
    }
    return $self->{client} if $self->{client};
    return Slim::Player::Client::getClient($self->{mac});
}

# capabilitiesDefault() -- class method (84-08): the player-independent
# keys of the table above (ProtocolHandler::contentType has no client);
# capabilities() on an instance returns the whole table.
# 84-12 (W6): `passthrough` is the one DYNAMIC key -- whether the installed
# librespot binary was built with the passthrough-decoder feature (Ogg
# passthrough). It is read from the Helper on demand (lazy, eval-guarded:
# 0 when the Helper or its capability probe is unavailable); every other
# key of the table stays static. DaemonManager::resolvePassthroughForClient
# reads it through backendClass()->capabilitiesDefault.
my @DEFAULT_KEYS = qw(contentType samplesize samplerate channels connectEntry formats deferTrack
                      connectClaimGate claimOnStart holdOnChange passthrough claimPerAccount);

sub _passthroughCapability {
    my $cap = eval {
        require Plugins::SpotOn::Helper;
        Plugins::SpotOn::Helper->getCapability('passthrough');
    };
    return $cap ? 1 : 0;
}

sub capabilitiesDefault {
    my %def = map { $_ => $CAPABILITIES{$_} } @DEFAULT_KEYS;
    $def{passthrough} = _passthroughCapability();
    return \%def;
}

sub capabilities {
    my %caps = %CAPABILITIES;
    $caps{deaden}      = [ @{ $CAPABILITIES{deaden} } ];
    $caps{passthrough} = _passthroughCapability();
    # 84-13: the binary's Connect autoplay support (--autoplay on|off), read
    # by Settings::Player for its Autoplay checkbox (lazy, eval-guarded).
    $caps{autoplay}    = _helperCapability('autoplay');
    return \%caps;
}

sub _helperCapability {
    my ($key) = @_;
    my $cap = eval {
        require Plugins::SpotOn::Helper;
        Plugins::SpotOn::Helper->getCapability($key);
    };
    return $cap ? 1 : 0;
}

sub state {
    my $self = shift;
    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($self->{mac});
    return {
        mode          => undef,
        status        => undef,
        paired        => undef,
        wsConnected   => undef,
        alive         => $helper ? 1 : 0,
        observedTrack => undef,
        active        => undef,
        account       => undef,    # 90.1-02 D-03: no account concept in this role
    };
}

# control($verb, %args) -> ok | declined | unsupported | down
#   play/pause/set_volume/skip_next/skip_prev -> HTTP /control/* (ok when a
#     POST was issued, down without a stream port)
#   seek (79-28 D-23) -> POST /control/seek {"position_ms":N}; the binary has
#     the endpoint (unified.rs:1250-1255). 'declined' without a numeric
#     position_ms (no POST), a negative value is sent as 0
#   restart -> unsupported (no HTTP endpoint; Connect.pm's +0 jump
#     falls back to skip_prev on anything but ok)
#   track(source getNextTrack) -> the samplesize(16) reset + successCb (the
#     ProtocolHandler getNextTrack librespot elsif; 84-08 rewires the caller)
#   track(source onStream) -> unsupported (onStream does nothing for a
#     player without Control)
sub control {
    my ($self, $verb, %args) = @_;
    $verb //= '';

    if (my $endpoint = $ENDPOINT{$verb}) {
        my $body;
        if ($verb eq 'set_volume') {
            my $volume = $args{volume} // 0;
            main::INFOLOG && $log->is_info && $log->info(
                "Forwarding volume to Connect binary: $volume (D-14)"
            );
            $log->warn("[DIAG] volume_to_binary: mac=" . $self->{mac} . " volume=$volume debounced=" . VOLUME_DEBOUNCE . "s") if $prefs->get('diagnosticMode');
            $body = { volume => int($volume) };
        }
        elsif ($verb eq 'seek') {
            my $position = $args{position_ms};
            return 'declined' unless defined $position && !ref $position && $position =~ /^-?\d+(?:\.\d+)?$/;
            my $ms = int($position);
            $ms = 0 if $ms < 0;
            main::INFOLOG && $log->is_info && $log->info(
                "Forwarding seek to Connect binary: ${ms}ms (D-14)"
            );
            $log->warn("[DIAG] seek_to_binary: mac=" . $self->{mac} . " position_ms=$ms debounced=" . SEEK_DEBOUNCE . "s") if $prefs->get('diagnosticMode');
            # the INFO and [DIAG] interpolation above gives $ms a string slot; LMS's JSON::XS 2.34 then sends it as a JSON string (seen in 79-28 run 2) - quick 261022-b22
            $body = { position_ms => 0 + $ms };
        }
        elsif (my $line = $SEND_INFO{$verb}) {
            main::INFOLOG && $log->is_info && $log->info($line);
        }
        return $self->_sendControlCommand($endpoint, $body) ? 'ok' : 'down';
    }

    if ($verb eq 'track') {
        my $source = $args{source} // '';
        return 'unsupported' unless $source eq 'getNextTrack';

        # CR-01 (Phase 76 review): librespot browse path -- explicitly reset
        # the samplesize hint instead of relying on "never set". The shared
        # RemoteTrack keeps a stale 32 from a prior soloist playback
        # otherwise (backend switch without LMS restart), misframing the
        # daemon's S16LE stream in both the transcode ($SAMPLESIZE$) and
        # direct (strm pcmsamplesize) paths.
        my $url  = $args{url} // '';
        my $song = $args{song};
        if ($song && $url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$}) {
            my $track = $song->track;
            if ($track) {
                $track->samplesize(16) if $track->can('samplesize');
            }
        }
        $args{successCb}->() if ref $args{successCb} eq 'CODE';
        return 'ok';
    }

    return 'unsupported';
}

sub notify { return 'unsupported'; }

# query($what, %args) -> scalar | undef. 79-60: 'playingMode' (client => $client) ->
# 'connect' | 'browse' from the librespot Connect claim, for the Now Playing label
# (Plugin::_playingMode); every other question: no opinion.
sub query {
    my ($self, $what, %args) = @_;
    if (($what // '') eq 'playingMode') {
        return undef unless $args{client};
        my $isConnect = eval { require Plugins::SpotOn::Connect; Plugins::SpotOn::Connect->isSpotifyConnect($args{client}) };
        return $isConnect ? 'connect' : 'browse';
    }
    return undef;
}

# streamUrl($client, $songOrUrl, $kind) -> url | undef
# The librespot halves of ProtocolHandler's URL choices, moved here
# behaviour-identically; 84-08 wires ProtocolHandler to them. The generic
# gates stay with the caller: canDirectStream's streamingMode=proxy gate
# (it runs before both branches) and the translated-history-URL cleanup.
#   browse_direct  canDirectStream's Browse branch: http://<serverAddr>:<port>/<type>/<id>
#                  (undef without an alive daemon/stream port or when synced)
#   connect_direct canDirectStream's Connect branch, librespot side:
#                  undef when streamFormat/connectOggOverride forces
#                  transcoding (pcm|flac|mp3), else http://<serverAddr>:<port>/stream
#                  (undef without daemon/port or when synced)
#   browse_proxy   new()'s former (b2) sync-group proxy block:
#                  http://127.0.0.1:<port>/<type>/<id>[?start_position=N],
#                  sets the song's startOffset for a seek (undef without daemon)
# %opts: url => the exact url LMS opened (ProtocolHandler::new passes it).
sub streamUrl {
    my ($self, $client, $song, $kind, %opts) = @_;
    return undef unless $client;
    $kind //= '';

    # $opts{url} (84-08): the exact url LMS opened, handed in by
    # ProtocolHandler::new; otherwise the song's track url or $song itself.
    my $url = $opts{url};
    $url = ref $song ? (($song->can('track') && $song->track) ? $song->track->url : undef) : $song
        unless defined $url;
    $client = $client->master if $client->can('master') && $client->master;

    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
    my $port   = ($helper && $helper->alive) ? $helper->_streamPort : undef;

    if ($kind eq 'browse_direct') {
        return undef unless $url && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$};
        my ($contentType, $trackId) = ($1, $2);
        return undef unless $port;
        if ($client->isSynced()) {
            $log->warn("[DIAG] canDirectStream: unified browse url=$url result=0 reason=synced") if $prefs->get('diagnosticMode');
            return undef;   # Synced: new() proxy handles
        }
        my $host   = Slim::Utils::Network::serverAddr();
        my $ds_url = "http://$host:" . $port . "/$contentType/$trackId";
        $log->warn("[DIAG] canDirectStream: unified browse url=$ds_url") if $prefs->get('diagnosticMode');
        return $ds_url;
    }

    if ($kind eq 'connect_direct') {
        # Per-player streamFormat: pcm/flac/mp3 force transcoding (librespot)
        my $fmt = $prefs->client($client)->get('streamFormat')
               || $prefs->client($client)->get('connectOggOverride')
               || 'auto';
        if ($fmt =~ /^(?:pcm|flac|mp3)$/) {
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (streamFormat=$fmt forces transcoding)"
            );
            return undef;
        }
        return undef unless $port;
        if ($client->isSynced()) {
            $log->warn("[DIAG] canDirectStream: unified connect result=0 reason=synced") if $prefs->get('diagnosticMode');
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (player is synced)"
            );
            return undef;
        }
        my $host   = Slim::Utils::Network::serverAddr();
        my $ds_url = "http://$host:" . $port . "/stream";
        $log->warn("[DIAG] canDirectStream: unified connect url=$ds_url") if $prefs->get('diagnosticMode');
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: $ds_url"
        );
        return $ds_url;
    }

    if ($kind eq 'browse_proxy') {
        return undef unless $url && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$};
        my ($contentType, $trackId) = ($1, $2);
        # No daemon/port -> undef; ProtocolHandler::new logs the
        # "Browse URL but no active unified daemon" line once (84-08).
        return undef unless $port;
        # CR-05 (82-25): hardcoded, not the auto-detected host IP -- LMS
        # itself is the HTTP client here and the daemon always runs locally.
        my $httpUrl = "http://127.0.0.1:" . $port . "/$contentType/$trackId";
        if (ref $song && $song->can('seekdata') && $song->seekdata && $song->seekdata->{'timeOffset'}) {
            my $offset = $song->seekdata->{'timeOffset'};
            $httpUrl .= '?start_position=' . $offset;
            $song->startOffset($offset);
        }
        $log->warn("[DIAG] unified_browse_sync_proxy: mac=" . $client->id . " http_url=$httpUrl") if $prefs->get('diagnosticMode');
        return $httpUrl;
    }

    return undef;
}

# ---------------------------------------------------------------------------
# The HTTP control sender (moved from Connect.pm::_sendControlCommand).
# Returns 1 when a POST was issued, 0 when there is no stream port (no POST
# and no status entry in that case, exactly as before). 85-07 D-10: a failed
# POST is reported through _reportDaemonUnreachable and nothing else; a
# successful one clears that report.
# ---------------------------------------------------------------------------
sub _sendControlCommand {
    my ($self, $endpoint, $body, %args) = @_;
    my $mac = $self->{mac};
    return 0 unless $mac;

    # 88 review WR-01: a new play/pause is the newest intent - a pending retry
    # of an older one is void. The retry itself ($args{retry}) keeps the number
    # of the command it repeats.
    # 88 review round 3 R3-WR-01: the claim state is taken HERE, when the command is
    # issued (a retry keeps the state of its first attempt), not when its 503 arrives -
    # the session may end in between, and a 503 that is processed after `stop inactive`
    # would otherwise record "no claim" and pass as a stale pass-through.
    my ($seq, $claimedAtIssue);
    if ($RETRY_ENDPOINT{$endpoint}) {
        if ($args{retry}) {
            $seq = $_transportSeq{$mac} // 0;
            $claimedAtIssue = $args{retry}{claimed} ? 1 : 0;
        }
        else {
            $seq = ++$_transportSeq{$mac};
            $self->_dropControlRetry('superseded by ' . $endpoint);
            # require only with a client: role-level callers (t/57) run without one and
            # without the Connect module loaded
            $claimedAtIssue = 0;
            if (my $c = $self->client) {
                require Plugins::SpotOn::Connect;
                $claimedAtIssue = Plugins::SpotOn::Connect->isSpotifyConnect($c) ? 1 : 0;
            }
        }
    }

    require Plugins::SpotOn::Unified::DaemonManager;

    my $port = Plugins::SpotOn::Unified::DaemonManager->streamPortForClient($mac);
    unless ($port) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: no stream port for " . $mac . ", skipping $endpoint"
        );
        return 0;
    }

    my $url      = "http://127.0.0.1:$port$endpoint";
    my $jsonBody = $body ? eval { to_json($body) } : '{}';

    main::INFOLOG && $log->is_info && $log->info(
        "_sendControlCommand: POST $url ($jsonBody)"
    );
    $log->warn("[DIAG] control_cmd_sent: mac=" . $mac . " endpoint=$endpoint body=$jsonBody") if $prefs->get('diagnosticMode');

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("_sendControlCommand: $endpoint OK");
            $log->warn("[DIAG] control_cmd_ok: mac=" . $mac . " endpoint=$endpoint") if $prefs->get('diagnosticMode');
            $self->_clearDaemonUnreachable;
        },
        sub {
            my ($http, $error, $response) = @_;

            # GH #159: the daemon answers 409 Conflict when Spirc dropped the
            # command because this device is no longer the active Connect
            # target (deselected in the Spotify app). SimpleAsyncHTTP routes
            # every non-2xx/3xx response through this error callback; the
            # response object (third arg, newer LMS) carries the code, and
            # $error holds the status line ("409 Conflict") as a fallback for
            # LMS versions whose onError only passes two args.
            my $code = ($response && blessed($response) && $response->can('code'))
                ? ($response->code || 0) : 0;
            $code ||= ($error && $error =~ /^(\d{3})\b/) ? $1 : 0;

            # 88-06 (D-07 item 7): 503 WITH a Retry-After header is the recovering
            # helper (88-04: `Retry-After: 2`, unified.rs). Nothing is wrong with the
            # session or the daemon: no eject, no daemon-unreachable entry, no
            # transfer. A 503 WITHOUT the header (the poisoned Spirc mutex,
            # unified.rs:1811, or an LMS whose onError passes no response object)
            # stays a failure and takes the _reportDaemonUnreachable path below.
            if ($code == 503) {
                my $retryAfter = ($response && blessed($response) && $response->can('header'))
                    ? $response->header('Retry-After') : undef;
                if (defined $retryAfter && length $retryAfter) {
                    main::INFOLOG && $log->is_info && $log->info(
                        "_sendControlCommand: $endpoint - daemon recovering (Retry-After $retryAfter) for " . $mac
                    );
                    # 88 review WR-01: play/pause are retried after the Retry-After
                    $self->_armControlRetry($endpoint, $body, $retryAfter, $seq, $args{retry}, $claimedAtIssue);
                    return;
                }
            }

            if ($code == 409) {
                $log->warn(
                    "_sendControlCommand: $endpoint rejected for " . $mac
                    . " - device is not the active Connect target (GH #159); ejecting stale stream"
                );
                $log->warn("[DIAG] control_cmd_rejected: mac=" . $mac . " endpoint=$endpoint code=409") if $prefs->get('diagnosticMode');

                # Eject the stale stream so LMS leaves BUFFERING-STREAMING
                # instead of hanging until the device is re-selected.
                # The Connect source mark prevents _onPause from echoing the
                # stop back to the daemon (T-05-13 / T-76-05).
                my $stopReq = Slim::Control::Request->new($mac, ['stop']);
                $stopReq->source(CONNECT_SOURCE);
                $stopReq->execute();

                # 88 review CR-01: the 409 is the daemon's authoritative statement
                # that the session is not on this device, so a claim this player
                # still holds is stale (nothing releases it when the helper process
                # is replaced: health restart, crash backoff, a killed helper). It
                # goes BEFORE the reopen below: with the claim held, getNextTrack
                # takes the claim-holder branch and opens the dead /stream relay of
                # the player's own live entry (BUFFERING at 0:00, the GH #159 state
                # this eject exists to prevent). releaseConnectClaim only clears the
                # claim when THIS player holds it; another player's claim (D-05) is
                # untouched.
                if (my $claimClient = $self->client) {
                    require Plugins::SpotOn::Connect;
                    Plugins::SpotOn::Connect->releaseConnectClaim($claimClient, 'daemon-409');
                }

                # 88-06 (D-03): a PLAY (the unpause of the stale stream) means the
                # user wants to hear this player again. LMS reopens the player's own
                # Connect entry (`play` from the stopped state goes through
                # StreamingController::_StopGetNext and ProtocolHandler::getNextTrack),
                # and that open is the ONE place that tries the pull-back
                # (transferBack) before it translates to Browse. This branch never
                # sends /control/transfer itself: one Play gesture causes at most one
                # transfer (T-88-12). Same source mark as the stop, so _onPause does
                # not echo the reopen to the daemon. pause/next/prev keep the eject only.
                # R3-WR-01: NOT for a retried Play that was armed under a claim. The
                # retry is only sent while the Connect session of the command is on; a
                # 409 on it is the helper's own statement that the session ended in the
                # meantime (recovery over and device deselected, or the helper replaced),
                # so the reopen would be the late pull-back from the device the user
                # moved to. Eject and release only; the stale pass-through (no claim
                # when armed) keeps its reopen = the designed GH #223 gesture.
                if ($endpoint eq '/control/play' && !($args{retry} && $args{retry}{claimed})) {
                    my $playReq = Slim::Control::Request->new($mac, ['play']);
                    $playReq->source(CONNECT_SOURCE);
                    $playReq->execute();
                }

                # Deliberately NO Web API call here: a Web API PUT would act
                # on the user's actually-active device — exactly wrong for a
                # command meant for this (deselected) player.
                return;
            }

            $self->_reportDaemonUnreachable($endpoint, $error);
        },
        { timeout => 5 }
    );

    $http->post($url, 'Content-Type' => 'application/json', $jsonBody);
    return 1;
}

# ---------------------------------------------------------------------------
# 88 review WR-01: the bounded retry of a play/pause the recovering helper
# refused (see CONTROL_RETRY_MAX above).
# ---------------------------------------------------------------------------

# _armControlRetry($endpoint, $body, $retryAfter, $seq, $prev, $claimedAtIssue) --
# called from the 503 + Retry-After branch. $seq is the command's number (undef
# for a non-transport endpoint), $prev the record of the retry that was just
# refused again (undef for the first attempt), $claimedAtIssue the claim state
# sampled when the first attempt was issued (R3-WR-01).
sub _armControlRetry {
    my ($self, $endpoint, $body, $retryAfter, $seq, $prev, $claimedAtIssue) = @_;
    my $mac = $self->{mac};

    unless ($RETRY_ENDPOINT{$endpoint}) {
        $log->warn("_sendControlCommand: $endpoint dropped for $mac - daemon recovering, only play/pause are retried");
        return;
    }
    if (!defined $seq || $seq != ($_transportSeq{$mac} // 0)) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: $endpoint not retried for $mac - a newer play/pause was issued"
        );
        return;
    }

    my $client = $self->client or return;
    $client = $client->master if $client->can('master') && $client->master;

    my $retries = $prev ? ($prev->{retries} || 0) : 0;
    if ($retries >= CONTROL_RETRY_MAX) {
        $log->warn("_sendControlCommand: $endpoint not delivered to $mac - daemon still recovering after $retries retries");
        return;
    }
    my $song = $prev ? $prev->{song} : ($client->can('playingSong') ? $client->playingSong : undef);
    unless ($song) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: $endpoint not retried for $mac - no playing song to tie the retry to"
        );
        return;
    }

    my $delay = (defined $retryAfter && $retryAfter =~ /^\d+$/
                 && $retryAfter >= 1 && $retryAfter <= CONTROL_RETRY_MAX_DELAY_S)
        ? $retryAfter : CONTROL_RETRY_DEFAULT_S;

    # the claim state of the FIRST attempt, as sampled when the command was issued,
    # travels with the record (R2-WR-01, R3-WR-01)
    my $claimed = $prev ? $prev->{claimed} : ($claimedAtIssue ? 1 : 0);
    my $rec = { endpoint => $endpoint, body => $body, retries => $retries + 1, song => $song, claimed => $claimed };
    weaken($rec->{song});
    $client->pluginData(connectControlRetry => $rec);

    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers($client, \&_controlRetryDue);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $delay, \&_controlRetryDue, $self);
    main::INFOLOG && $log->is_info && $log->info(
        "_sendControlCommand: $endpoint retry " . $rec->{retries} . "/" . CONTROL_RETRY_MAX . " in $delay s for $mac"
    );
    return;
}

# _dropControlRetry($why) -- void the pending retry of the player, if any.
sub _dropControlRetry {
    my ($self, $why) = @_;
    my $client = $self->client or return;
    $client = $client->master if $client->can('master') && $client->master;
    my $rec = $client->pluginData('connectControlRetry');
    return unless ref $rec eq 'HASH';
    $client->pluginData(connectControlRetry => 0);
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers($client, \&_controlRetryDue);
    main::INFOLOG && $log->is_info && $log->info(
        "_sendControlCommand: pending " . $rec->{endpoint} . " retry dropped for " . $self->{mac} . " ($why)"
    );
    return;
}

# the retry timer: ($client, $role)
sub _controlRetryDue {
    my ($client, $self) = @_;
    return unless $client && $self;
    my $rec = $client->pluginData('connectControlRetry');
    return unless ref $rec eq 'HASH';
    $client->pluginData(connectControlRetry => 0);

    # the retry belongs to the song that played when the command was issued
    my $now = $client->can('playingSong') ? $client->playingSong : undef;
    unless ($rec->{song} && $now && refaddr($now) == refaddr($rec->{song})) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: " . $rec->{endpoint} . " retry dropped for " . $self->{mac} . " (the player plays something else)"
        );
        return;
    }
    # R2-WR-01: the Connect session of the command ended (or began) meanwhile - a late
    # retry must not reach the helper, whose 409 would reopen the entry and pull the
    # session back
    require Plugins::SpotOn::Connect;
    if ((Plugins::SpotOn::Connect->isSpotifyConnect($client) ? 1 : 0) != ($rec->{claimed} // 0)) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: " . $rec->{endpoint} . " retry dropped for " . $self->{mac} . " (the Connect session ended meanwhile)"
        );
        return;
    }
    $self->_sendControlCommand($rec->{endpoint}, $rec->{body}, retry => $rec);
    return;
}

# ---------------------------------------------------------------------------
# 88-06 (D-03, D-04, D-05): the pull-back. ProtocolHandler::getNextTrack is the
# ONLY caller of transferBack (the open of the player's own last Connect entry
# as an explicit Play). The helper's POST /control/transfer (88-05) answers 204
# = dispatched; success is not awaited there, it shows up later as the
# `start`/`change` Connect.pm receives and reports through transferConfirmed.
# After a takeover it requested, the helper itself sends `play` (88-05), so
# nothing here sends /control/play.
#
# State: ONE record per player in its pluginData (connectTransferPending:
# waiter list, started). A second request while a record is pending sends no
# second POST and shares the outcome. A cleared record is written as 0 (LMS's
# pluginData does not write undef).
# ---------------------------------------------------------------------------

# transferBack(on_fallback => CODE, on_confirmed => CODE) -> 1 | 0
#   0: no alive daemon with a stream port (or no client) - no side effect, the
#      caller keeps today's behaviour. 1: a transfer is in flight (new or
#      shared); exactly one of the two callbacks runs later:
#   on_fallback('refused:<code>' | 'timeout')   at once on a refusal / HTTP
#      error, or when TRANSFER_WAIT_S passed without start/change
#   on_confirmed($cmd, $issuedPlay)             one main-loop tick after the
#      start/change handler finished (transferConfirmed)
sub transferBack {
    my ($self, %args) = @_;
    my $mac = $self->{mac};
    return 0 unless $mac;
    return 0 unless ref $args{on_fallback} eq 'CODE' && ref $args{on_confirmed} eq 'CODE';

    my $client = $self->client;
    return 0 unless $client;
    $client = $client->master if $client->can('master') && $client->master;

    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($mac);
    my $port   = ($helper && $helper->alive) ? $helper->_streamPort : undef;
    return 0 unless $port;

    my $waiter  = { on_fallback => $args{on_fallback}, on_confirmed => $args{on_confirmed} };
    my $pending = $client->pluginData('connectTransferPending');
    if (ref $pending eq 'HASH') {
        push @{ $pending->{waiters} }, $waiter;
        main::INFOLOG && $log->is_info && $log->info(
            "transfer-back already pending for $mac - sharing the outcome (" . scalar(@{ $pending->{waiters} }) . " waiters)"
        );
        return 1;
    }

    $pending = { started => Time::HiRes::time(), waiters => [ $waiter ] };
    $client->pluginData(connectTransferPending => $pending);

    my $url = "http://127.0.0.1:$port/control/transfer";
    main::INFOLOG && $log->is_info && $log->info("transfer-back: POST $url for $mac");
    $log->warn("[DIAG] control_cmd_sent: mac=" . $mac . " endpoint=/control/transfer body={}") if $prefs->get('diagnosticMode');

    weaken(my $weakClient = $client);
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            # 204: dispatched. The record may already be gone (the session's start can
            # arrive before this callback is processed) - then nothing is armed.
            my $c = $weakClient or return;
            my $cur = $c->pluginData('connectTransferPending');
            return unless ref $cur eq 'HASH' && $cur == $pending;
            require Slim::Utils::Timers;
            Slim::Utils::Timers::setTimer($c, Time::HiRes::time() + TRANSFER_WAIT_S, \&_transferTimeout);
        },
        sub {
            my ($http, $error, $response) = @_;
            my $code = ($response && blessed($response) && $response->can('code'))
                ? ($response->code || 0) : 0;
            $code ||= ($error && $error =~ /^(\d{3})\b/) ? $1 : 0;
            my $c = $weakClient or return;
            my $cur = $c->pluginData('connectTransferPending');
            return unless ref $cur eq 'HASH' && $cur == $pending;
            $c->pluginData(connectTransferPending => 0);
            my $why = 'refused:' . ($code || 'error');
            main::INFOLOG && $log->is_info && $log->info("transfer-back for $mac refused ($why)");
            _runWaiters($cur->{waiters}, 'on_fallback', $why);
        },
        { timeout => 5 }
    );
    $http->post($url, 'Content-Type' => 'application/json', '{}');
    return 1;
}

# transferPending($class_or_role, $client) -> 1 | 0 -- a pull-back is in flight for the
# player (88 review WR-05: Connect.pm's `change` handler binds the claim only then).
sub transferPending {
    my ($class, $client) = @_;
    return 0 unless $client;
    $client = $client->master if $client->can('master') && $client->master;
    return ref $client->pluginData('connectTransferPending') eq 'HASH' ? 1 : 0;
}

# transferConfirmed($class_or_role, $client, $cmd, $issuedPlay) -- Connect.pm reports the
# session's arrival on $client (`start` / `change`) and whether its handler issued its own
# `playlist play` ($issuedPlay). A no-op unless a transfer is pending for the player. The waiters
# run from a zero-delay timer: after the calling handler finished its own commands.
sub transferConfirmed {
    my ($class, $client, $cmd, $issuedPlay) = @_;
    return unless $client;
    $client = $client->master if $client->can('master') && $client->master;

    my $pending = $client->pluginData('connectTransferPending');
    return unless ref $pending eq 'HASH';

    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers($client, \&_transferTimeout);
    $client->pluginData(connectTransferPending => 0);
    main::INFOLOG && $log->is_info && $log->info("transfer-back confirmed by " . ($cmd // '?'));

    Slim::Utils::Timers::setTimer($client, Time::HiRes::time(), \&_deliverConfirmed,
        $pending->{waiters}, $cmd, $issuedPlay ? 1 : 0);
    return;
}

# the TRANSFER_WAIT_S timer
sub _transferTimeout {
    my ($client) = @_;
    return unless $client;
    my $pending = $client->pluginData('connectTransferPending');
    return unless ref $pending eq 'HASH';
    $client->pluginData(connectTransferPending => 0);
    main::INFOLOG && $log->is_info && $log->info(
        "transfer-back: no start/change within " . TRANSFER_WAIT_S . " s - falling back"
    );
    _runWaiters($pending->{waiters}, 'on_fallback', 'timeout');
    return;
}

# the zero-delay timer transferConfirmed arms
sub _deliverConfirmed {
    my ($client, $waiters, $cmd, $issuedPlay) = @_;
    _runWaiters($waiters, 'on_confirmed', $cmd, $issuedPlay);
    return;
}

# one waiter's failure must not keep the others from their outcome
sub _runWaiters {
    my ($waiters, $which, @args) = @_;
    for my $w (@{ $waiters || [] }) {
        eval { $w->{$which}->(@args); 1 } or $log->warn("transfer-back: $which waiter failed: $@");
    }
    return;
}

# _reportDaemonUnreachable($endpoint, $error) -- 85-07 D-10 (T-85-26): the
# control endpoint of this player's daemon did not answer. One status-page
# entry per player (dedupe key daemon_unreachable:<mac>; a repeat while the
# entry stands records nothing), no Web API call.
sub _reportDaemonUnreachable {
    my ($self, $endpoint, $error) = @_;
    my $mac = $self->{mac};
    $error //= '';

    $log->warn("[DIAG] control_cmd_fail: mac=" . $mac . " endpoint=$endpoint error=$error fallback=none") if $prefs->get('diagnosticMode');
    main::INFOLOG && $log->is_info && $log->info(
        "_sendControlCommand: $endpoint failed ($error) - daemon not reachable, recorded on the status page"
    );

    my $key = 'daemon_unreachable:' . $mac;
    eval {
        require Plugins::SpotOn::Status;
        Plugins::SpotOn::Status->recordError('warn', 'Connect', "$mac: Daemon nicht erreichbar ($endpoint)", $key)
            unless Plugins::SpotOn::Status->hasError('Connect', $key);
        1;
    } or $log->warn("_sendControlCommand: recordError failed for $mac: $@");
    return;
}

# _clearDaemonUnreachable() -- the next successful control POST proves the
# endpoint answers again. Deliberately reads no argument of the HTTP success
# callback it is called from (t/core/53 counts that site as argument-less).
sub _clearDaemonUnreachable {
    my ($self) = @_;
    my $mac = $self->{mac};
    eval {
        require Plugins::SpotOn::Status;
        Plugins::SpotOn::Status->clearError('Connect', 'daemon_unreachable:' . $mac);
        1;
    } or $log->warn("_sendControlCommand: clearError failed for $mac: $@");
    return;
}


# ---------------------------------------------------------------------------
# 84-08 Task 3: lifecycle and settings hooks (class methods).
# ---------------------------------------------------------------------------

# bootstrap() -- the librespot binary-path registration (BLOCKER 3): the
# daemon's Helper->get (Unified/Daemon.pm), Status and Settings never pass
# through the Credentials auth path, so the Bin/x86_64-win64 (Windows),
# Bin/darwin (macOS) and aarch64 -> armhf-linux fallback paths must be
# registered here. Helper->init is once-guarded inside Helper.pm (ONE guard
# shared by every caller), so a second bootstrap never registers twice.
sub bootstrap {
    require Plugins::SpotOn::Helper;
    Plugins::SpotOn::Helper->init();
    return 'ok';
}

# prereqState() -- class method (84-12, SEAM-6.2): librespot has no
# prerequisite gate of its own (the binary lookup happens in the daemon's
# start); the answer is the constant 'librespot', exactly what
# DaemonManager::_backendPrereqState returned for it before the move.
sub prereqState { return 'librespot'; }

# 84-12 (SEAM-6.2): DaemonManager lifecycle hooks -- the librespot answers.
# Both roles implement every hook explicitly (a missing method would be a
# production die in DaemonManager).
#   onDaemonExit  -> 'restart' (today's generic counted crash backoff; the
#                    GH #147 credential check runs in DaemonManager BEFORE
#                    this is consulted)
#   onInitHelpers -> no-op (no binary renewal/placement of its own)
#   rollbackBinary-> (0, 'unsupported') (no binary generations)
#   pairedForMac  -> undef (no pairing concept)
sub onDaemonExit   { return 'restart'; }
sub onInitHelpers  { return 'ok'; }
sub rollbackBinary { return (0, 'unsupported'); }
sub pairedForMac   { return undef; }

# accountIdForHelper($class, $helper) -> account id | ''
# authHealthListsPlayers($class) -> 0
# 79-63 R1 (79-REVIEW-BETA3 CR-01): Status.pm's Auth Health Connect row asks
# the helper's own role instead of naming a daemon class (core names no
# backend module). A librespot daemon carries its account (_accountId); the
# row lists no players (the 79-60 rule, unchanged).
sub accountIdForHelper {
    my ($class, $helper) = @_;
    return '' unless $helper && $helper->can('_accountId');
    return $helper->_accountId || '';
}
sub authHealthListsPlayers { return 0; }

# quality / qualityInfo -- the Spotify streaming-quality control (D-17) is a
# Soloist feature; librespot has none.
sub quality     { return 'unsupported'; }
sub qualityInfo { return { supported => 0, validLevels => [] }; }

# 84-13 Task 2: settings-page routes and binary renewal are Soloist
# features -- librespot registers no route and answers "unsupported".
sub routes      { return []; }
sub renewNow    { return { status => 'unsupported' }; }
sub renewStatus { return { supported => 0 }; }

# binaryPath() -- class method, kept ONLY for Plugin.pm's hourly orphan
# sweep: the Helper->get path (Helper->init first; once-guarded inside
# Helper.pm). The sweep skips it as the path its librespot half already
# swept.
sub binaryPath {
    require Plugins::SpotOn::Helper;
    Plugins::SpotOn::Helper->init();
    my ($path) = Plugins::SpotOn::Helper->get();
    return $path;
}

# keyState / storeKey / clearKey -- the spak-key store (84-13 Task 1) is a
# Soloist capability; librespot has none and never touches the Soloist
# module.
sub keyState { return { supported => 0, present => 0 }; }
sub storeKey { return (0, 'unsupported'); }
sub clearKey { return 0; }

# settingsInfo($paramRef, %fmt) -- the librespot binary status of the
# Settings page (moved from Settings.pm::handler in 84-08, values and
# condition unchanged). D-07: the binary-missing hint is librespot-specific
# state -- under backend=soloist it lives inside the hidden
# #librespot-fields group, so a soloist-only install (no librespot binary
# ever fetched) must not surface a red warning for a binary it will never
# need.
sub settingsInfo {
    my ($class, $paramRef, %fmt) = @_;
    require Plugins::SpotOn::Helper;
    require Slim::Utils::Strings;
    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();
    $paramRef->{helperMissing} = Slim::Utils::Strings::string('PLUGIN_SPOTON_BINARY_MISSING')
        if !$helperPath && (($prefs->get('backend') || 'librespot') ne 'soloist');
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';
    return 'ok';
}

1;
