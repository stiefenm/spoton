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

use Scalar::Util qw(blessed weaken);
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
                      connectClaimGate claimOnStart holdOnChange passthrough);

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

sub query { return undef; }

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
    my ($self, $endpoint, $body) = @_;
    my $mac = $self->{mac};
    return 0 unless $mac;

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
