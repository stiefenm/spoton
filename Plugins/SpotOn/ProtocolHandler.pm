package Plugins::SpotOn::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Versions;
use Slim::Utils::Cache;
use Slim::Utils::Network;
use Digest::MD5 qw(md5_hex);
use Time::HiRes;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
my $CRLF  = "\x0d\x0a";

# D-05: debounce — one in-flight re-fetch per URL
our %_pendingRefetch;

# Guard against recursive setCurrentTitle -> getCurrentTitle -> getMetadataFor
our $_applyingCurrentTitle = 0;

sub _displayTitleFromMeta {
    my ($meta) = @_;
    return '' unless $meta && ref $meta eq 'HASH';
    return '' unless $meta->{title};
    return $meta->{artist}
        ? "$meta->{artist} - $meta->{title}"
        : $meta->{title};
}

sub _applyRuntimeMetadata {
    my ($client, $song, $logicalUrl, $meta) = @_;
    return unless $meta && ref $meta eq 'HASH';
    return unless $logicalUrl;

    $meta->{url} ||= $logicalUrl;

    if ($song) {
        if ($meta->{duration} && !($song->duration && $song->duration > 0)) {
            $song->duration($meta->{duration});
        }
    }

    # Phase 82 (Befund 2, D-04): a length that arrives asynchronously (the
    # API refetch, or a later getMetadataFor cache hit) releases a
    # T_meta-held successCb and promotes seekable back to 1. Delivered to
    # the backend role (84-08: notify('noteDuration'); a backend without a
    # player engine answers 'unsupported'). Best-effort -- eval-guarded:
    # $client here can be a lightweight test/UI double without a real
    # id(); metadata display must never crash on it.
    if ($client && $logicalUrl =~ m{^spoton://(?:track|episode):} && $meta->{duration}) {
        eval {
            require Plugins::SpotOn::Unified::DaemonManager;
            my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
            $be->notify('noteDuration', url => $logicalUrl, secs => $meta->{duration}) if $be;
            1;
        };
    }

    # Only set title for the actively playing song — getMetadataFor is called
    # for every queue entry, not just the current track
    return unless $song && $client && $meta->{title};
    my $playing = $client->playingSong || $client->streamingSong;
    return unless $playing && $playing == $song;
    return if $_applyingCurrentTitle;

    local $_applyingCurrentTitle = 1;
    require Slim::Music::Info;
    Slim::Music::Info::setCurrentTitle($logicalUrl, _displayTitleFromMeta($meta), $client);
}

# Track Connect URLs translated to Browse by getNextTrack
my %_translatedConnectUrls;

# Per-client retry state for transient Browse daemon 404s (audio-key throttle)
use constant MAX_BROWSE_404_RETRIES => 3;
use constant BROWSE_404_RETRY_DELAY => 2;   # seconds between retries
my %_browse404Retries;  # "$clientId|$trackUrl" => attempt_count

# Fable-5 review of quick-260910-upw (CR-01): every _asyncRefetch metadata-fetch
# failure -- not just the definitive ones -- must keep a per-url bound on the
# refetch cadence, or a fast-failing 5xx/no_token storms every status poll,
# throttled only by a reactive 429. Transient failures get this short TTL
# instead of the definitive case's 60s so a later success still lands promptly.
use constant META_REFETCH_TRANSIENT_TTL => 15;

# 84-08 (SEAM-6.2): the former runtime backend-pref check of Phase 72 D-01
# is gone. spoton:// URLs are unchanged across backends; every entry point
# below asks the backend role (DaemonManager->backendFor / backendClass)
# for what differs: content type, sample hints, URLs, the track request.

# _streamingModeIsProxy($client) -- WR-05: per-player streamingMode=proxy (or
# per-player 'global' resolving to a global streamingMode=proxy default,
# GH #96) forces LMS-relayed streaming. canDirectStream's COMPAT-02 gate,
# which runs before every backend's direct-URL answer (84-08: the former
# per-backend Browse branch that ran ahead of it is gone).
sub _streamingModeIsProxy {
    my ($client) = @_;
    return 0 unless $client;

    my $gateClient = $client->can('master') ? $client->master : $client;
    my $mode = $prefs->client($gateClient)->get('streamingMode') || 'global';
    if ($mode eq 'global') {
        $mode = $prefs->get('streamingMode') || 'direct';
    }
    return $mode eq 'proxy' ? 1 : 0;
}

# Phase 76 D-06 note: this class-level default is NOT the transcode-profile
# input -- Slim::Player::Song::open() (Song.pm:375-378) starts from
# Slim::Music::Info::contentType($track) but then unconditionally replaces
# it with our formatOverride($song) result, which is where the per-player
# resolver ('soc' vs 'smp' vs 'son') lives. Kept client-agnostic here on
# purpose: there is no client context at this call site -- hence the role
# CLASS default (84-08, capabilitiesDefault), never a per-player read.
sub contentType { Plugins::SpotOn::Unified::DaemonManager->backendClass->capabilitiesDefault->{contentType} }

sub isRemote    { 1 }

sub trackGain {
    my ($class, $client, $url) = @_;

    return unless $client && blessed $client;

    # librespot handles normalization — suppress LMS "Default Adjustment for
    # Remote Streams" so the two do not stack (GH #108).
    return if $prefs->get('normalization');

    my $cprefs = $serverPrefs->client($client);
    return $cprefs->get('replayGainMode') && $cprefs->get('remoteReplayGain');
}

# getFormatForURL($class, $url)
# Returns content type for a given URL:
# - 'soc' for Connect URLs (spoton://connect-*)
# - 'son' for single-track Browse URLs (default)
sub getFormatForURL {
    my ($class, $url) = @_;
    # Phase 73 D-03: every backend's Browse URL plays through the daemon's
    # HTTP endpoint -- the 'soc' PCM-direct/proxy family, the fall-through
    # default below (84-08 deleted the redundant per-backend branch; the
    # result is identical).
    return 'soc' if $url && $url =~ m{spoton://connect-};
    return 'pcm' if $url && $url =~ m{:\d+/stream\b};
    return 'soc' if $url && $url =~ m{:\d+/(?:track|episode)/};  # Phase 28: Browse daemon HTTP URLs
    return 'soc';
}

# contentTypeFor($class, $client)
# Returns ($type, $resolver, $resolved): the per-player stream content type
# (the INPUT side of the LMS transcoding key) plus the two facts it was
# derived from. The ONE mapping from "what the backend resolved" to "which
# convert rule LMS runs": formatOverride (playback) and
# DaemonManager->effectiveFormat/effectiveOutput (every display surface) both
# call it, so what the player page says is what playback does (74b D-08).
#
# Four types, each with exactly ONE rule in custom-convert.conf so the
# player's format-preference order (TranscodingHelper.pm:352-396) can never
# change the outcome (74b D-14):
#   'soc' pure PCM passthrough          (soc pcm * *)
#   'sof' FLAC 16 via the bundled tool  (sof flc * *)
#   'smp' MP3 via the lame tool         (smp mp3 * *, Phase 76 D-07)
#   'son' OGG passthrough               (son ogg * *)
#
# 84-08 (SEAM-6.2): the backend names its format resolver
# (capabilitiesDefault->{formats}); the core calls it on DaemonManager and
# maps the answer. A resolver answers EITHER a format name
# ('pcm'|'flac'|'mp3' -- Phase 76 D-06, the bounded /stream family) OR the
# OGG-passthrough boolean (D-04/D-05/D-08). Mapping:
#   'mp3'          -> 'smp'
#   'flac'         -> 'sof' for an explicit FLAC choice, otherwise 'soc'
#                     (74b D-22: under Soloist the resolver answers 'flac'
#                     for Auto on an flc group, which keeps the stream on
#                     the LMS proxy path; the delivered format stays PCM
#                     through the soc pcm rule until Auto is staged to FLAC)
#   passthrough 1  -> 'son'
#   boolean 0      -> 'soc', except the librespot per-player pref: mp3 ->
#                     'smp'
#   anything else  -> 'soc'
sub contentTypeFor {
    my ($class, $client) = @_;

    require Plugins::SpotOn::Unified::DaemonManager;

    my $resolver = Plugins::SpotOn::Unified::DaemonManager->backendClass->capabilitiesDefault->{formats};
    my $resolved = Plugins::SpotOn::Unified::DaemonManager->$resolver($client);
    $resolved = '' unless defined $resolved;

    # The stored per-player choice (WR-04 chain). Both callers pass the
    # master, the pref lives there.
    my $stored = sub {
        return 'auto' unless $client;
        return $prefs->client($client)->get('streamFormat')
            || $prefs->client($client)->get('connectOggOverride')
            || 'auto';
    };

    my $type;
    if ($resolved eq 'mp3') {
        $type = 'smp';
    }
    elsif ($resolved eq 'flac') {
        # Under Soloist the resolver already answered with a NAME. Re-reading
        # the pref to pick a type would undo a capability downgrade (a
        # downgrade answers 'pcm', never 'flac', RESEARCH Pitfall 3), so the
        # pref is consulted only here, where it separates an explicit FLAC
        # choice from Auto.
        if ($stored->() eq 'flac') {
            $type = 'sof';
        }
        else {
            # 74b D-16/D-22: Auto on an flc group. While the staging seam
            # answers false Auto keeps today's PCM delivery through the soc
            # pcm rule (the stream is on the proxy path either way, the
            # resolver's answer decided that); once it answers true the same
            # proxied stream is delivered as FLAC through the sof rule.
            # Asked only in this branch, never in the path resolver.
            $type = Plugins::SpotOn::Unified::DaemonManager->autoFlacEnabled ? 'sof' : 'soc';
        }
    }
    elsif ($resolved eq '1') {
        $type = 'son';
    }
    elsif ($resolved =~ /^(?:0)?$/) {
        # The librespot boolean answered (no name): the per-player pref picks
        # the single-rule forcing type -- without it 'soc' would let flc/pcm
        # beat mp3 in the player's format-preference order.
        $type = 'soc';
        my $pref = $stored->();
        if ($pref eq 'mp3') {
            $type = 'smp';
        }
        elsif ($pref eq 'flac') {
            # 74b D-04 (code side) / D-15: an explicit FLAC pref under
            # librespot rides the same sof rule (16-bit input is padded
            # losslessly by $SAMPLESIZE$) when every member of the player or
            # sync group can play flc, otherwise it degrades to PCM.
            # Librespot Auto stays unchanged ('son' or 'soc').
            $type = Plugins::SpotOn::Unified::DaemonManager->groupSupportsFlac($client) ? 'sof' : 'soc';
        }
    }
    else {
        $type = 'soc';
    }

    return ($type, $resolver, $resolved);
}

# formatOverride($class, $song)
# Returns the content type (INPUT side of transcoding key) for the current song:
# one of 'soc' (PCM), 'sof' (FLAC), 'smp' (MP3), 'son' (OGG passthrough), see
# contentTypeFor above (74b D-14). For Auto the resolver's 'flac' decides the
# PATH (proxy instead of direct), the type decides the delivered format (74b
# D-22).
#
# LMS Song.pm constructs the transcoding profile key as:
#   formatOverride-outputFormat-*-*  (e.g. soc-pcm-*-* or sof-flc-*-*)
sub formatOverride {
    my ($class, $song) = @_;

    my $client = $song->master;
    my $url = $song->track->url || '';

    my ($fmt, $resolver, $resolved) = $class->contentTypeFor($client);

    $log->warn("[DIAG] formatOverride: mac=" . ($client ? $client->id : 'none') . " url=$url result=$fmt resolver=$resolver resolved=$resolved") if $prefs->get('diagnosticMode');
    return $fmt;
}

# canDirectStreamSong($class, $client, $song)
# Override base class to append seek offset for Browse daemon HTTP URLs.
# Base class (HTTP.pm) returns $direct without seek awareness; we append
# ?start_position=N so the Browse daemon starts decoding at the right offset.
sub canDirectStreamSong {
    my ($class, $client, $song) = @_;

    my $url = $song->currentTrack->url || '';
    my $directUrl = $class->canDirectStream($client, $url);
    return 0 unless $directUrl;

    if ($directUrl =~ m{/(?:track|episode)/} && $song->seekdata && $song->seekdata->{'timeOffset'}) {
        my $offset = $song->seekdata->{'timeOffset'};
        $directUrl .= '?start_position=' . $offset;
        $song->startOffset($offset);
    }

    # Phase 82 (D-04, Befund 1): the &start=<offset> rewrite for the
    # bounded /stream/track?uri=...&g=<gen> URL is REMOVED -- Befund 1
    # established that this restart path never reaches getNextTrack
    # (0/30 seek_arm on LMS `time`, § S-03), so the rewrite it was meant to
    # feed was dead code from the start. Seek/rewind now reach the daemon
    # via canDoAction/getSeekData's marker -> onStream -> requestTrack.

    return $directUrl;
}

# canDirectStream($class, $client, $url)
# Returns HTTP URL for single Connect players, 0 for sync groups and non-Connect.
# D-06: canDirectStream returns HTTP URL for single players; sync groups use new() proxy.
# T-05-16: URL is constructed from Slim::Utils::Network::serverAddr() + daemon port —
# both LMS-controlled, no user input in URL.
sub canDirectStream {
    my ($class, $client, $url) = @_;

    return 0 unless $client;

    # COMPAT-02: per-player streamingMode=proxy (or per-player 'global' resolving
    # to a global streamingMode=proxy default) forces LMS-relayed streaming for
    # BOTH Browse and Connect (D-02) and for every backend (WR-05: it runs
    # before any backend's direct-URL answer) — one gate at the top, no
    # duplication. D-03: this gate is orthogonal to sync-group gating, which
    # the backend's streamUrl applies. D-05: this gate is orthogonal to
    # codec/transcoding format selection.
    # Known, accepted side effect (review finding): in proxy mode this gate
    # returns before the translated-Connect-URL cleanup further down, so an entry
    # can remain in %_translatedConnectUrls; if the user later switches back to
    # direct, one stale entry causes a single harmless extra return 0 (the proxy
    # path in new() absorbs it) — bounded and accepted, no mitigation needed.
    if (_streamingModeIsProxy($client)) {
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: 0 (streamingMode=proxy)"
        );
        return 0;
    }

    # 84-08 (SEAM-6.2): the direct URL itself comes from the backend role
    # (streamUrl browse_direct / connect_direct) -- librespot
    # http://<serverAddr>:<port>/<type>/<id> resp. /stream, the per-track
    # bounded /stream?uri=...&g=<gen> endpoint for the other backend -- with
    # the backend's own format/daemon/synced gates; undef there means 0 here
    # (Synced: new()'s proxy substitution handles it).
    # T-05-16: URLs are built from Slim::Utils::Network::serverAddr() + the
    # daemon port -- both LMS-controlled, no user input in the URL.
    if ($url && $url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$}) {
        require Plugins::SpotOn::Unified::DaemonManager;
        my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
        my $ds_url = $be ? $be->streamUrl($client, $url, 'browse_direct') : undef;
        return defined $ds_url ? $ds_url : 0;
    }

    # Connect URL: direct stream to the daemon's /stream
    if ($url && $url =~ m{spoton://connect-}) {
        # Translated history URL: translate to Browse, skip Direct Stream
        if (delete $_translatedConnectUrls{$url}) {
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (translated Connect history URL)"
            );
            return 0;
        }
        require Plugins::SpotOn::Unified::DaemonManager;
        my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
        my $ds_url = $be ? $be->streamUrl($client, $url, 'connect_direct') : undef;
        return defined $ds_url ? $ds_url : 0;
    }

    return 0;
}

# requestString($self, $client, $url, $post, $seekdata)
# Override to suppress Range header for Connect proxy connections.
# The base class (HTTP.pm line 971) unconditionally adds "Range: bytes=0-".
# Sending Range to an infinite PCM stream endpoint may cause hyper to respond with
# 206 Partial Content, and triggers LMS's "Persistent service" reconnect path
# (HTTP.pm line 107: !$self->contentLength with Range present). For the binary's
# /stream endpoint, a plain GET without Range is the correct request.
# Non-stream URLs delegate to the base class unchanged (SUPER::requestString).
sub requestString {
    my ($self, $client, $url, $post, $seekdata) = @_;

    if ($url && $url =~ m{:\d+/(?:stream\b|(?:track|episode)/)}) {
        # Phase 28: also suppress Range for Browse daemon /track/ URLs (same reason as /stream).
        my ($server, $port, $path) = Slim::Utils::Misc::crackURL($url);
        my $host = ($port == 80) ? $server : "$server:$port";
        main::INFOLOG && $log->is_info && $log->info(
            "requestString: daemon proxy - plain GET (no Range) for $url"
        );
        return join($CRLF,
            "GET $path HTTP/1.0",
            "Accept: */*",
            "Cache-Control: no-cache",
            "Connection: close",
            "Host: $host",
            "", "",
        );
    }

    return $self->SUPER::requestString($client, $url, $post, $seekdata);
}

# handleDirectError($class, $client, $url, $response, $status_line)
# Called by Squeezebox2::directHeaders when the direct stream returns a non-2xx/3xx status.
# For Browse daemon 404: retry up to MAX_BROWSE_404_RETRIES times with a delay before skipping.
# Transient 404s (audio-key throttle from Spotify) often resolve within seconds.
sub handleDirectError {
    my ($class, $client, $url, $response, $status_line) = @_;

    if ($response == 404 && $url && $url =~ m{:\d+/(?:track|episode)/}) {
        my $streaming = $client->streamingSong();
        my $playing   = $client->playingSong();
        if ($streaming && $playing && $streaming != $playing) {
            # Prefetch context: current track still playing, schedule skip at track end
            my $remaining = ($client->controller()->playingSongDuration() || 0)
                          - ($client->controller()->playingSongElapsed() || 0);
            $remaining = 1 if $remaining < 1;
            $log->warn("Browse daemon 404 for $url - prefetch context, scheduling skip in ${remaining}s");
            # M9: pass the failing URL — playback state can change before the
            # timer fires, and _skipUnavailable must not skip the wrong track.
            Slim::Utils::Timers::killTimers($client, \&_skipUnavailable);
            Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining, \&_skipUnavailable, $url);
            return;
        }

        # Play context: retry before skipping (audio-key throttle resilience)
        my $retryKey = $client->id . '|' . $url;
        my $attempt  = ($_browse404Retries{$retryKey} || 0) + 1;
        $_browse404Retries{$retryKey} = $attempt;

        if ($attempt <= MAX_BROWSE_404_RETRIES) {
            $log->warn("Browse daemon 404 for $url - retry $attempt/" . MAX_BROWSE_404_RETRIES
                      . " in " . BROWSE_404_RETRY_DELAY . "s");
            Slim::Utils::Timers::killTimers($client, \&_retryStream);
            Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + BROWSE_404_RETRY_DELAY,
                \&_retryStream);
            return;
        }

        # Exhausted retries — skip to next track and clean up
        $log->warn("Browse daemon 404 for $url - $attempt attempts exhausted, skipping to next track");
        if ($INC{'Plugins/SpotOn/Status.pm'}) {
            Plugins::SpotOn::Status->recordError('warn', 'Browse', "404 retries exhausted, skipping track");
        }
        delete $_browse404Retries{$retryKey};
        Slim::Utils::Timers::killTimers($client, \&_retryStream);
        Slim::Utils::Timers::killTimers($client, \&_skipUnavailable);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.1, \&_skipUnavailable, $url);   # M9
        return;
    }

    $client->failedDirectStream($status_line);
}

# _retryStream($client)
# Re-triggers playback of the current track after a transient 404.
# Uses 'playlist index' with the current index to force a fresh stream attempt,
# which re-enters canDirectStream → handleDirectError if still 404.
sub _retryStream {
    my $client = shift;
    my $idx = Slim::Player::Source::streamingSongIndex($client) // 0;
    $log->info("Retrying stream for playlist index $idx");
    $client->execute(['playlist', 'index', $idx]);
}

sub _skipUnavailable {
    my ($client, $url) = @_;

    # M9: playback state may have changed between scheduling and firing
    # (manual skip, new track, stop) — a late skip would kill the WRONG track.
    # Only skip if the streaming song still matches the 404'd URL.
    if ($url) {
        my $streaming = $client->streamingSong();
        my $streamUrl = '';
        if ($streaming) {
            $streamUrl = $streaming->streamUrl
                || ($streaming->track ? ($streaming->track->url || '') : '')
                || '';
        }
        unless ($streaming && $streamUrl eq $url) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "_skipUnavailable: streaming song changed (now: "
                . ($streamUrl || 'none') . ") - dropping stale skip for $url (M9)");
            return;
        }
    }

    # Clean up any leftover retry state for this client
    my $prefix = $client->id . '|';
    delete @_browse404Retries{ grep { index($_, $prefix) == 0 } keys %_browse404Retries };
    $client->execute(['playlist', 'index', '+1']);
}

# canEnhanceHTTP($self, $client, $url)
# Override to return 0 for Connect proxy stream URLs.
# The base class returns $prefs->get('useEnhancedHTTP') which may be non-zero.
# For infinite PCM streams the "Enhanced/Persistent" path (HTTP.pm line 107)
# causes immediate disconnection via range-based reconnections against an
# infinite body. Returning 0 forces LMS to use the normal non-enhanced path.
# Non-stream URLs delegate to the base class unchanged (SUPER::canEnhanceHTTP).
sub canEnhanceHTTP {
    my ($self, $client, $url) = @_;

    if ($url && $url =~ m{:\d+/(?:stream\b|(?:track|episode)/)}) {
        # Phase 28: also return 0 for Browse daemon /track/ URLs (same reason as /stream).
        $log->warn("[DIAG] canEnhanceHTTP: url=$url result=0 reason=daemon_proxy_infinite_stream") if $prefs->get('diagnosticMode');
        main::INFOLOG && $log->is_info && $log->info(
            "canEnhanceHTTP: daemon proxy - returning 0 for $url"
        );
        return 0;
    }

    return $self->SUPER::canEnhanceHTTP($client, $url);
}

# new($class, $args)
# Two responsibilities:
# (a) D-08 Browse→Connect mutual exclusion: son:// URL starting while Connect is active
#     → stop the Connect daemon before returning normal stream object
# (b) D-06 Sync-group proxy: spoton://connect-* URL for synced players
#     → substitute HTTP URL so all sync members get audio from binary's HTTP server
#
# Note: DaemonManager require is on-demand (not at top level) per plan acceptance criteria.
sub new {
    my ($class, $args) = @_;

    my $url = $args->{url} || '';

    # (a) D-08: spoton:// (Browse/single-track) URL while Connect is active.
    # Unified daemon handles Browse/Connect mutual exclusion internally via D-09/D-10 ActiveMode mutex.
    if ($url =~ m{^spoton://(?!connect-)}) {
        my $client = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            main::INFOLOG && $log->is_info && $log->info(
                "D-08: Browse URL - unified daemon handles mode transition for " . $client->id
            );
        }
    }

    # (b2/b3) Browse URL substitution through the backend role (84-08,
    # SEAM-6.2). new() is only called when canDirectStream() returned 0, so
    # a spoton://track|episode URL always needs the daemon's HTTP endpoint:
    # synced players (sync-group proxy), proxy mode and the transcode path.
    # The role builds the URL -- librespot /<type>/<id>[?start_position=N]
    # (sets the song's startOffset for a seek), the per-track bounded
    # endpoint for the other backend -- and answers undef without an alive
    # daemon + stream port. The url LMS opened is passed explicitly: the
    # role must not re-derive it from the song (Song::open uses
    # `$redir || $track->url`). T-28-08: the regex below only lets an
    # already-validated [A-Za-z0-9]+ id through.
    if ($url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$}) {
        my $client = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            require Plugins::SpotOn::Unified::DaemonManager;
            my $be   = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
            my $url2 = $be ? $be->streamUrl($client, $args->{song}, 'browse_proxy', url => $url) : undef;
            unless (defined $url2) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Browse URL but no active unified daemon for " . $client->id . " - returning undef"
                );
                return undef;
            }
            $args = { %$args, url => $url2 };
        }
    }

    # (b) D-06: spoton://connect-* URL — substitute HTTP stream URL for sync-group proxy
    if ($url =~ m{spoton://connect-}) {
        my $client = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            require Plugins::SpotOn::Unified::DaemonManager;
            my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
            if ($helper && $helper->alive && $helper->_streamPort) {
                # CR-05 (82-25): hardcoded, not the auto-detected host IP --
                # see the (b2) block above for the full rationale.
                my $host    = '127.0.0.1';
                my $httpUrl = 'http://' . $host . ':' . $helper->_streamPort . '/stream';
                $log->warn("[DIAG] unified_connect_sync_proxy: mac=" . $client->id . " http_url=$httpUrl") if $prefs->get('diagnosticMode');
                $args = { %$args, url => $httpUrl };
            } else {
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect URL but no active unified daemon for " . ($client ? $client->id : '?') . " - returning undef"
                );
                return undef;
            }
        }
    }

    return Slim::Player::Protocols::HTTP->new($args);
}

# getNextTrack($class, $song, $successCb, $errorCb)
# Called by StreamingController before transcoding pipeline starts.
# Translates dead Connect history URLs to Browse URLs so the binary
# receives a valid spoton://track:ID instead of spoton://connect-TIMESTAMP.
sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    # Scope-fence deviation (83-03-EXEC, Nutzerentscheidung, 2026-09-22):
    # unbedingte Eintrittsprotokollierung, VOR jedem Zweig -- die fuenf
    # bereits vorhandenen $log->info(...)-Aufrufe im Rumpf decken nur
    # Sonderpfade ab (tote Connect-URL-Uebersetzung, Deferral); der normale
    # Erfolgspfad einer live Connect-Session (isSpotifyConnect==wahr, weiter
    # unten) hatte bislang KEINE Protokollierung auf jedem Level. Exaktes
    # Idiom der sechs bestehenden [DIAG]-Zeilen dieser Datei (u.a. :187,
    # :206, :263, :284, :292, :311), kein neuer Mechanismus, kein neues Gate.
    $log->warn("[DIAG] getNextTrack: mac=" . ($song->master ? $song->master->id : 'none') . " url=" . ($song->track->url || '')) if $prefs->get('diagnosticMode');

    my $url = $song->track->url || '';
    if ($url =~ m{spoton://connect-}) {
        my $client = $song->master;

        # Dead history URL check FIRST — takes priority over active Connect session.
        # A history URL has a cached spotifyUri (written by _fetchTrackMetadata after
        # the original Connect playback). Translate to Browse regardless of whether
        # the phone is still connected.
        my $meta = $cache->get('spoton_meta_' . md5_hex($url));
        if ($meta && $meta->{spotifyUri}
            && $meta->{spotifyUri} =~ m/^spotify:track:([A-Za-z0-9]+)$/) {
            my $browseUrl = "spoton://track:$1";
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: translating dead Connect URL to $browseUrl"
            );
            $song->streamUrl($browseUrl);
            if (keys %_translatedConnectUrls >= 200) {
                delete $_translatedConnectUrls{(keys %_translatedConnectUrls)[0]};
            }
            $_translatedConnectUrls{$url} = 1;

            # Set duration from cached metadata for the translated Browse URL
            my $browseMeta = $cache->get('spoton_meta_' . md5_hex($browseUrl));
            if ($browseMeta && $browseMeta->{duration} && $browseMeta->{duration} > 0) {
                $song->duration($browseMeta->{duration});
            }

            $successCb->();
            return;
        }

        # No cached spotifyUri — either a live Connect session or an untranslatable URL
        require Plugins::SpotOn::Connect;
        if (Plugins::SpotOn::Connect->isSpotifyConnect($client)) {
            # D-08 (Phase 76) / CR-01: the sample-size hint comes from the
            # backend role, set EXPLICITLY for every backend (S32LE from
            # fake-libpulse's /stream, S16LE from librespot) so the $SAMPLESIZE$
            # of the sof FLAC rule and the smp MP3 rule (74b D-14) and the
            # strm pcmsamplesize frame the stream correctly: RemoteTrack objects are cached in-memory by
            # URL (Slim::Schema::RemoteTrack %Cache) and survive a backend
            # switch within one LMS uptime, so a stale hint from the other
            # backend would otherwise misframe the stream (transcode:
            # $SAMPLESIZE$; direct: strm pcmsamplesize).
            require Plugins::SpotOn::Unified::DaemonManager;
            _applySampleHints($song, Plugins::SpotOn::Unified::DaemonManager->backendClass->capabilitiesDefault);
            $successCb->();
            return;
        }

        main::INFOLOG && $log->is_info && $log->info(
            "getNextTrack: dead Connect URL with no cached spotifyUri - cannot translate"
        );
        $errorCb->('PROBLEM_OPENING', 'No cached track ID for Connect history URL');
        return;
    }

    # Set duration from cached metadata for Browse URLs before transcoding starts.
    # This gives LMS the earliest possible duration information for the seek bar.
    my $browseMeta = $cache->get('spoton_meta_' . md5_hex($url));
    if ($browseMeta && $browseMeta->{duration} && $browseMeta->{duration} > 0) {
        $song->duration($browseMeta->{duration});
    }

    # spoton://track|episode Browse URL: the backend role takes the track
    # request (84-08, SEAM-6.2). The sample hints come from its
    # capabilities and are set EXPLICITLY for every backend (D-08 Phase 76:
    # raw S32LE/44100/stereo from fake-libpulse's /stream, D-04; CR-01:
    # librespot S16LE -- RemoteTrack objects are cached in-memory by URL
    # and survive a backend switch within one LMS uptime, so relying on a
    # "never set" default would leave the other backend's hint in place).
    # They drive both the strm-frame pcm_sample_sizes mapping
    # (Squeezebox.pm:1129) and the $SAMPLESIZE$ substitution in the sof FLAC
    # and smp MP3 convert rules (74b D-14, TranscodingHelper.pm:449).
    #
    # control('track', source => 'getNextTrack') owns the callbacks: the
    # player engine's request (or its deferral while the daemon is still
    # coming up, or the named prerequisite failure), or librespot's direct
    # successCb. The position travels as ms (seekdata timeOffset).
    if ($url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$}) {
        my $client = $song->master;
        require Plugins::SpotOn::Unified::DaemonManager;
        my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
        unless ($be) {
            $successCb->();
            return;
        }

        _applySampleHints($song, $be->capabilities);

        my $posMs = ($song->can('seekdata') && $song->seekdata && defined $song->seekdata->{timeOffset})
            ? int($song->seekdata->{timeOffset} * 1000)
            : 0;

        $be->control('track', source => 'getNextTrack',
            url => $url, position_ms => $posMs, song => $song, duration => $song->duration,
            successCb => $successCb, errorCb => $errorCb,
        );

        # Clean slate on Browse entry (Phase 83.1 D-D1): the release happens
        # AFTER the player engine has decided, not before. Its own
        # connect->browse handoff already flips the mode to 'browse' for a
        # foreign uri from getNextTrack; a real in-session getNextTrack
        # (mode still 'connect') keeps its claim. No engine instance (a
        # deferred request, or a backend without one: state mode undef) ->
        # nothing to release.
        my $mode = $be->state->{mode};
        Plugins::SpotOn::Connect->releaseConnectClaim($client, 'browse-entry') if defined $mode && $mode ne 'connect';

        return;
    }

    $successCb->();
}

# _applySampleHints($song, $caps) -- the backend's samplesize/samplerate/
# channels on the song's RemoteTrack (84-08; each `can`-guarded as before).
sub _applySampleHints {
    my ($song, $caps) = @_;
    my $track = $song->track or return;
    $track->samplesize($caps->{samplesize}) if $caps->{samplesize} && $track->can('samplesize');
    $track->samplerate($caps->{samplerate}) if $caps->{samplerate} && $track->can('samplerate');
    $track->channels($caps->{channels})     if $caps->{channels}   && $track->can('channels');
}

# onStream($class, $player, $song)
# D-05: verified against LMS 9.1.1 (StreamingController.pm:1311-1327; byte-
# identical with tag 9.1.1, see 82-RESEARCH.md § D-07) -- called for EVERY
# stream start (play, EOF/skip, seek N, rewind, reconnect, sync members),
# per player, right after Song::open, immediately before $player->play.
# There is no callback and $player->play runs in the SAME synchronous LMS
# command (Pitfall 2) -- Control arms synchronously when it dispatches from
# here (requestTrack's source => 'onStream').
#
# This is THE consumer for both absicht-erfassende markers (Befund 1/3,
# D-04): getNextTrack remains the entry point for ordinary title changes;
# a restart triggered by canDoAction('rew')/getSeekData (rewind, seek N,
# _Continue reconnect) is NEVER visible to getNextTrack (Befund 1 -- LMS's
# _JumpToTime bypasses it entirely) and reaches Control only here. Without
# a marker or seekdata, this call is the idempotent twin of getNextTrack
# for the SAME title (Befund 1 point 3) -- requestTrack's own idempotency
# absorbs the double entry.
sub onStream {
    my ($class, $player, $song) = @_;

    my $master = $song->master or return;
    # Sync-Mitglieder: onStream is called once per player in the group
    # (A4); only the master requests -- a player engine exists only for
    # the master anyway (the role resolves the master too, but this avoids
    # a second, redundant track request per synced player).
    return unless $player && $player->id eq $master->id;

    my $url = $song->track ? ($song->track->url || '') : '';
    return unless $url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$};

    # 84-08 (SEAM-6.2): the seekdata/marker/startOffset/track-request body
    # lives in the backend role (control('track', source => 'onStream'));
    # a backend without a player engine answers 'unsupported' before any
    # work, exactly the former "no engine -> return".
    require Plugins::SpotOn::Unified::DaemonManager;
    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($master) or return;
    $be->control('track', source => 'onStream', url => $url, song => $song, duration => $song->duration);
    return;
}

# explodePlaylist($class, $client, $uri, $cb)
# Resolves spoton:// container URIs (album, playlist, show) into lists of individual
# playable track/episode URLs. Called by LMS when playing from Favorites.
# Single tracks/episodes pass through unchanged.
# T-22-01: regex-validated ID extraction — only [A-Za-z0-9]+ IDs reach API calls.
# T-22-02: pagination bounded by API total; max 50/100 per page.
sub explodePlaylist {
    my ($class, $client, $uri, $cb) = @_;

    main::INFOLOG && $log->is_info && $log->info("explodePlaylist: $uri");

    # Single track — pass through unchanged
    if ($uri =~ m{^spoton://track:[A-Za-z0-9]+$}) {
        $cb->([$uri]);
        return;
    }

    # Single episode — pass through unchanged
    if ($uri =~ m{^spoton://episode:[A-Za-z0-9]+$}) {
        $cb->([$uri]);
        return;
    }

    # Album — fetch album info (name, images) + tracks, pre-cache metadata
    if ($uri =~ m{^spoton://album:([A-Za-z0-9]+)$}) {
        my $albumId = $1;
        require Plugins::SpotOn::Plugin;
        my $accountId = Plugins::SpotOn::Plugin::_getAccountId($client);
        require Plugins::SpotOn::API::SpClient;

        Plugins::SpotOn::API::SpClient->getAlbum($accountId, $albumId, sub {
            my ($album, $err) = @_;
            unless ($album && $album->{name}) {
                main::INFOLOG && $log->is_info && $log->info(
                    "explodePlaylist: album $albumId fetch failed"
                );
                $cb->({ items => [] });
                return;
            }

            my $albumName        = $album->{name} || '';
            my $albumCover       = _largestImage($album->{images}) || '/html/images/cover.png';
            my $albumReleaseDate = $album->{release_date} // '';
            my $tracksData       = $album->{tracks} || {};
            my $total            = $tracksData->{total} || 0;

            # H5: pagination offsets and completion checks must count RAW page
            # items. @allItems is filtered (tracks without an id are skipped),
            # so using it as the API offset shifts every subsequent page back
            # by one per skipped track — re-fetching duplicates.
            my @allItems;
            my $fetched = scalar(@{ $tracksData->{items} || [] });
            for my $track (@{ $tracksData->{items} || [] }) {
                next unless $track && $track->{id};
                my $item = _buildExplodedTrackItem($track, $albumName, $albumCover);
                push @allItems, $item;
                _cacheExplodedTrack($item->{url}, $track, $albumName, $albumCover, $albumId, $albumReleaseDate);
            }

            if ($fetched >= $total) {
                main::INFOLOG && $log->is_info && $log->info(
                    "explodePlaylist: album $albumId => " . scalar(@allItems) . " tracks"
                );
                $cb->({ items => \@allItems });
                return;
            }

            my $fetchPage;
            $fetchPage = sub {
                my ($offset) = @_;
                Plugins::SpotOn::API::SpClient->getAlbumTracks($accountId, $albumId, {
                    offset => $offset,
                    limit  => Plugins::SpotOn::API::SpClient->pageLimit('library'),
                }, sub {
                    my ($data, $err) = @_;
                    unless ($data && $data->{items}) {
                        undef $fetchPage;
                        $cb->({ items => \@allItems });
                        return;
                    }
                    $fetched += scalar(@{ $data->{items} });   # H5: raw count
                    for my $track (@{ $data->{items} }) {
                        next unless $track && $track->{id};
                        my $item = _buildExplodedTrackItem($track, $albumName, $albumCover);
                        push @allItems, $item;
                        _cacheExplodedTrack($item->{url}, $track, $albumName, $albumCover, $albumId, $albumReleaseDate);
                    }
                    if ($fetched < $total && @{ $data->{items} }) {
                        $fetchPage->($fetched);
                    } else {
                        undef $fetchPage;
                        main::INFOLOG && $log->is_info && $log->info(
                            "explodePlaylist: album $albumId => " . scalar(@allItems) . " tracks"
                        );
                        $cb->({ items => \@allItems });
                    }
                });
            };
            $fetchPage->($fetched);
        });
        return;
    }

    # Playlist — fetch all tracks via recursive page fetch
    if ($uri =~ m{^spoton://playlist:([A-Za-z0-9]+)$}) {
        my $playlistId = $1;
        require Plugins::SpotOn::Plugin;
        my $accountId = Plugins::SpotOn::Plugin::_getAccountId($client);
        require Plugins::SpotOn::API::SpClient;

        my @allItems;
        my $fetchPage;
        $fetchPage = sub {
            my ($offset) = @_;
            Plugins::SpotOn::API::SpClient->getPlaylistItems($accountId, $playlistId, {
                offset => $offset,
                limit  => Plugins::SpotOn::API::SpClient->pageLimit('playlist_items'),
            }, sub {
                my ($data, $err) = @_;
                unless ($data && $data->{items}) {
                    undef $fetchPage;
                    main::INFOLOG && $log->is_info && $log->info(
                        "explodePlaylist: playlist $playlistId => " . scalar(@allItems) . " tracks"
                    );
                    $cb->({ items => \@allItems });
                    return;
                }
                for my $plItem (@{ $data->{items} }) {
                    next unless $plItem;
                    Plugins::SpotOn::Plugin::_normalizeLibraryItem($plItem, 'track');
                    next unless $plItem->{track} && $plItem->{track}{id};
                    my $track = $plItem->{track};
                    my $albumInfo = $track->{album} || {};
                    my $albumName  = $albumInfo->{name};
                    my $albumCover = _largestImage($albumInfo->{images});
                    my $opmlItem = _buildExplodedTrackItem($track, $albumName, $albumCover);
                    push @allItems, $opmlItem;
                    _cacheExplodedTrack($opmlItem->{url}, $track,
                        $albumName, $albumCover, $albumInfo->{id});
                }
                my $total = $data->{total} || 0;
                if (scalar(@allItems) < $total && @{ $data->{items} }) {
                    $fetchPage->($offset + scalar(@{ $data->{items} }));
                } else {
                    undef $fetchPage;
                    main::INFOLOG && $log->is_info && $log->info(
                        "explodePlaylist: playlist $playlistId => " . scalar(@allItems) . " tracks"
                    );
                    $cb->({ items => \@allItems });
                }
            });
        };
        $fetchPage->(0);
        return;
    }

    # Show — fetch all episodes via recursive page fetch
    if ($uri =~ m{^spoton://show:([A-Za-z0-9]+)$}) {
        my $showId = $1;
        require Plugins::SpotOn::Plugin;
        my $accountId = Plugins::SpotOn::Plugin::_getAccountId($client);
        require Plugins::SpotOn::API::SpClient;

        my @allItems;
        my $total = 0;
        my $fetchPage;
        $fetchPage = sub {
            my ($offset) = @_;
            Plugins::SpotOn::API::SpClient->getShowEpisodes($accountId, $showId, {
                offset => $offset,
                limit  => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            }, sub {
                my ($data, $err) = @_;
                unless ($data && $data->{items}) {
                    undef $fetchPage;
                    main::INFOLOG && $log->is_info && $log->info(
                        "explodePlaylist: show $showId => " . scalar(@allItems) . " episodes"
                    );
                    $cb->({ items => \@allItems });
                    return;
                }
                $total = $data->{total} || 0;
                my $pageItems = $data->{items};
                for my $ep (@{$pageItems}) {
                    next unless $ep && $ep->{id};
                    my $opmlItem = _buildExplodedEpisodeItem($ep);
                    push @allItems, $opmlItem;
                    _cacheExplodedEpisode($opmlItem->{url}, $ep);
                }
                if (scalar(@allItems) < $total && @{$pageItems} > 0) {
                    $fetchPage->($offset + scalar(@{$pageItems}));
                } else {
                    undef $fetchPage;
                    main::INFOLOG && $log->is_info && $log->info(
                        "explodePlaylist: show $showId => " . scalar(@allItems) . " episodes"
                    );
                    $cb->({ items => \@allItems });
                }
            });
        };
        $fetchPage->(0);
        return;
    }

    # Default: pass through unchanged
    $cb->([$uri]);
}

sub parseDirectHeaders {
    my ($class, $client, $url, @headers) = @_;

    my $song = $client->streamingSong();
    if ($song) {
        my $meta = $class->getMetadataFor($client, $url);
        if ($meta && $meta->{duration}) {
            $song->duration($meta->{duration});
        }

        # Finding 2: Set startOffset from ?start_position=N so LMS progress bar
        # reflects the actual playback position after seeking via Browse HTTP.
        if ($url && $url =~ /start_position=([\d.]+)/) {
            $song->startOffset($1 + 0);
        }
    }

    return Slim::Player::Protocols::HTTP->parseDirectHeaders($client, $url, @headers);
}

sub isRepeatingStream {
    my (undef, $song) = @_;
    return unless $song;
    my $url = $song->track->url || '';
    return $url =~ m{spoton://connect-} ? 1 : 0;
}

sub canSeek {
    my ($class, $client) = @_;
    # Both backends (librespot + soloist) support seek. librespot uses
    # ?start_position=N in canDirectStreamSong; soloist uses LMS-native
    # seek-restart with &start=N in the bounded URL (D-03 Phase 78).
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub canTranscodeSeek {
    my ($class, $client) = @_;
    # Unified daemon: seek is handled via URL query parameters in
    # canDirectStreamSong (?start_position=N for librespot, &start=N
    # substitution for soloist bounded URLs), not via $START$ in the
    # transcoding command. Returning 0 keeps canDoSeek at 1 so streamMode
    # 'I' stays in the profile search and soc-pcm-*-* matches.
    return 0;
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;

    # 83.1-04 (D-B1): a Soloist connect session takes the SAME seekable/
    # noteSeekIntent/{timeOffset} path as browse. The restart chain
    # (_JumpToTime's _Stop+_Stream -> getNextTrack's same-uri handoff ->
    # onStream(seek=1) -> Control::requestTrack -> _reconcilePlan's connect
    # seek row -> arm + `send seek`, never a `play` with a uri) is the ONE seek
    # path for Soloist connect (Prinzip 3.1(4)).
    #
    # 79-28 D-23: a librespot connect seek travels over POST /control/seek
    # (Connect.pm _onSeek -> _forwardLibrespotSeek -> Backend::Librespot) and
    # the daemon's flush carries the jump, so LMS must NOT restart /stream:
    # undef here (GH #129 behaviour, restored behind the backend capability
    # connectSeekViaControl; Soloist reports 0 and keeps the restart chain).
    #
    # Known accepted paths that still restart the stream (59-REVIEW R-2/R-3):
    # - Pause -> seek -> unpause: _JumpPaused stores resumeTime (canSeek=1),
    #   unpause calls _JumpToTime with restartIfNoSeek=1 which bypasses this
    #   undef. Harmless: the binary already seeked, and the /stream reconnect
    #   re-enters the mid-song-connect path where CON-13 adjusts startOffset.
    #   Seek-to-0 while paused IS suppressed via canDoAction('rew').
    # - Seek beyond track duration (CLI only): LMS _Skip fires before
    #   getSeekData. No handler hook exists; accepted as known limitation.

    # Phase 82 (D-04, Befund 1/3): the second absicht-erfassende marker --
    # onStream is the only consumer. seekable=0 (Befund 2: no known
    # duration, or a confirmed 404) makes LMS itself skip the restart
    # (undef here means _JumpToTime returns without a _Stop/_Stream).
    # 84-08: asked through the backend role -- query('seekable') undef is
    # "no opinion" (no player engine), then no marker either.
    require Plugins::SpotOn::Unified::DaemonManager;
    if (my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client)) {
        return undef if $be->capabilities->{connectSeekViaControl}
            && Plugins::SpotOn::Connect->isSpotifyConnect($client);
        my $url = $song->track->url;
        my $seekable = $be->query('seekable', url => $url);
        return undef if defined $seekable && !$seekable;
        $be->notify('noteSeekIntent', url => $url, target_ms => int($newtime * 1000)) if defined $seekable;
    }

    return { timeOffset => $newtime };
}

# canDoAction($class, $client, $url, $action)
# Connect mode (R-1, GH #129, kept per 83.1-04 plan-04 decision): block
# LMS-side track restart on seek-to-0. In connect, restart-at-0 can arrive
# from three distinct LMS sources -- an exact `time 0`, a `playlist jump -1`
# on the one-entry playlist, and a `jump +0` -- and LMS must not restart the
# stream for ANY of them: (a) `jump -1`/`+0` must become `skip_prev`
# (D-B2, Connect.pm::_onPlaylistJump -> Control::requestSkip), not an
# LMS-side track restart; (b) a REFUSED `skip_prev` (D-B4: the daemon's own
# `available_actions` lacks it) must leave NOTHING changed -- an LMS-side
# restart already fired would violate that; (c) restart-at-0 in connect is
# the daemon's own `skip_prev` semantics anyway (Spotify: a `time 0` inside
# the first ~3s of a track goes to the PREVIOUS track), never LMS's local
# concept of "rewind this stream". `_onSeek` (Connect.pm) routes an exact
# `time 0` to `requestSkip('prev', 'time0')`; the ['time'] event still
# fires and reaches that handler regardless of this guard -- returning 0 for
# 'rew' only suppresses the LMS-SIDE _Stop+_Stream restart in both
# _JumpToTime (playing) and _JumpPaused (paused). Track restart via
# prev-button: _onPlaylistJump forwards playlist jump -1 to
# Control::requestSkip('prev', ...), the same D-B2 route; `jump +0` see the
# 1B paragraph below.
# All other actions ('stop', 'pause', 'fwd') must stay allowed (return 1).
#
# Debug session connect-skip-prev-ton-bleibt (2026-09-24), user decision
# 1B -- DEVIATION from D-B2 for `jump +0`: the block above stays for every
# restart-at-0 LMS asks about on its own (`time 0`, `jump -1`, and LMS' own
# first call for `jump +0`, which arrives here BEFORE the `playlist jump`
# notification tells _onPlaylistJump which one it was). Exactly one
# restart passes: the one Control::requestRestart asks for itself once
# _onPlaylistJump knows it was `+0` -- its one-shot allowance for this url
# (consumeRestartAllowance) lets it fall through to the rewind marker
# below (seekable check + noteSeekIntent(url, 0)), so LMS restarts the
# stream and onStream arms `seek 0` (the D-B1 restart chain).
sub canDoAction {
    my ($class, $client, $url, $action) = @_;

    if ($action eq 'rew' && Plugins::SpotOn::Connect->isSpotifyConnect($client)) {
        # 84-08: the one-shot restart allowance is the player engine's
        # (query('consumeRestartAllowance'), read-and-clear); no engine ->
        # undef -> blocked, as before.
        require Plugins::SpotOn::Unified::DaemonManager;
        my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
        unless ($be && $be->query('consumeRestartAllowance', url => $url)) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Connect mode: blocking LMS-side restart for 'rew' (seek-to-0 handled by requestSkip, D-B2)"
            );
            return 0;
        }
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Connect mode: LMS-side restart for 'rew' allowed -- jump +0 from the start via the seek path (1B)"
        );
    }

    # Phase 82 (D-04, Befund 1/3): 'rew' sets only a marker; the consumer is
    # onStream. No command is EVER sent from here -- the UPnP MediaRenderer
    # probe (AVTransport.pm:945) and _JumpPaused (player paused, ziel 0)
    # call this WITHOUT a restart following, so a marker set here must be
    # allowed to expire/leak-clear rather than assume a stream restart is
    # coming (SEEK_INTENT_TTL, Control::consumeSeekIntent).
    if ($action eq 'rew') {
        require Plugins::SpotOn::Unified::DaemonManager;
        if (my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client)) {
            my $seekable = $be->query('seekable', url => $url);
            return 0 if defined $seekable && !$seekable;
            $be->notify('noteSeekIntent', url => $url, target_ms => 0) if defined $seekable;
        }
    }

    return 1;
}

# getMetadataFor($class, $client, $url)
# Returns cached track metadata for NowPlaying display (artwork, title, artist, album,
# duration, bitrate, type).
# - For Connect streams: uses song pluginData('info') set by Connect.pm _fetchTrackMetadata
# - For Browse streams: uses cache populated by Plugin.pm _trackItem/_albumTrackItem
# Cache key: 'spoton_meta_' + md5_hex(url). TTL: 3600s.
# Per STR-03: LMS calls this to populate the NowPlaying display.
sub getMetadataFor {
    my ($class, $client, $url, undef, $song) = @_;

    if (ref $url) {
        main::DEBUGLOG && $log->is_debug && $log->debug("getMetadataFor: url is " . ref($url) . ", stringifying");
        $url = "$url";
    }

    # Spotty pattern: fall back to currentSongForUrl when $song is not passed.
    # Must happen BEFORE any early returns so $song->duration can be set below.
    if ($client && !$song && $client->can('currentSongForUrl')) {
        $song = $client->currentSongForUrl($url);
    }

    # For Connect streams: try pluginData info first (set by Connect.pm _fetchTrackMetadata)
    # M8: only when the playing song IS the requested URL — a lookup for a
    # DIFFERENT connect- URL (history entry, stale queue item) must not get the
    # live session's metadata (bleed). Non-matching URLs fall through to the
    # cache-based history lookup below.
    if ($url && $url =~ m{spoton://connect-} && $client) {
        $client = $client->master if $client->can('master');
        my $connectSong = $client->playingSong();
        if ($connectSong
            && $connectSong->track
            && $connectSong->track->url
            && $connectSong->track->url eq $url
            && (my $info = $connectSong->pluginData('info'))) {
            return $info;
        }
    }

    # D-06, D-07: Connect history URL translation — cache hit with spotifyUri
    # History items don't have an active playingSong, so we reach here for connect- URLs
    # that were cached by _fetchTrackMetadata in Connect.pm.
    if ($url && $url =~ m{spoton://connect-}) {
        my $connect_meta = $cache->get('spoton_meta_' . md5_hex($url));
        undef $connect_meta unless _metaCurrent($connect_meta);   # 79-43: unmarked = miss (refetch heals it)
        if ($connect_meta && $connect_meta->{spotifyUri}
            && $connect_meta->{spotifyUri} =~ m/^spotify:track:([A-Za-z0-9]+)$/) {
            my $trackId    = $1;
            my $browseUrl  = "spoton://track:$trackId";
            # D-07: return Browse mode label — Connect origin is invisible to the user
            require Plugins::SpotOn::Plugin;
            if ($client) {
                return { %$connect_meta,
                    type    => Plugins::SpotOn::Plugin->_typeString($client, 'Browse'),
                    bitrate => Plugins::SpotOn::Plugin->_bitrateForClient($client) . 'k',
                    play    => $browseUrl,
                };
            }
            return { %$connect_meta, play => $browseUrl };
        }
        # No cached spotifyUri — fall through to async re-fetch path below
    }

    # Normalize: cache is keyed on spoton://track:ID but LMS may pass spoton:track:ID
    my $canonical = $url;
    if ($canonical && $canonical =~ m{^spoton:(?!//)}) {
        $canonical =~ s{^spoton:}{spoton://};
    }

    # COMPAT-03: canonicalize daemon HTTP URLs (direct-stream or proxy path) to
    # the same spoton://{type}:{id} cache key used by Browse. D-07: only
    # /track/{ID} and /episode/{ID} — /stream (Connect) has no track ID and is
    # served via pluginData('info'), not this cache. Must tolerate a trailing
    # ?start_position=N (seek offset, appended by canDirectStreamSong and the
    # new() sync-group proxy path) — without the optional group, canonicalization
    # silently fails on every seeked playback.
    if ($canonical && $canonical =~ m{^https?://[^/]+/(track|episode)/([A-Za-z0-9]+)(?:\?.*)?$}) {
        $canonical = "spoton://$1:$2";
    }

    # 79-43 (D-33 FULL-3 CR-01): a record without the current format marker can hold the byte form of the names
    # (beta.1, 7-day TTL); it takes the miss path below (placeholder plus async refetch, which writes it anew).
    my $meta = $cache->get('spoton_meta_' . md5_hex($canonical));
    undef $meta unless _metaCurrent($meta);

    # Fallback: try original URL if normalization didn't help
    if (!$meta && $canonical ne $url) {
        $meta = $cache->get('spoton_meta_' . md5_hex($url));
        undef $meta unless _metaCurrent($meta);
    }

    # D-03, D-04, D-05: cache miss — return placeholder immediately, fire async re-fetch
    unless ($meta) {
        _asyncRefetch($class, $client, $url, $canonical);
        return _placeholderMeta($url);
    }

    # Spotty pattern: propagate duration to $song object so LMS seek bar works.
    # Guard: only set when not already set to >0 (prevents overwrite on repeated calls).
    if ($song && $meta && $meta->{duration}
        && !($song->duration && $song->duration > 0)) {
        $song->duration($meta->{duration});
    }

    # Propagate metadata to RemoteTrack object for LMS songinfo and favorites:
    # - secs: infoDuration reads $track->secs, not $song->duration
    # - title: favorites uses $track->name (→ $track->title), falls back to URL
    if ($meta && eval { require Slim::Schema::RemoteTrack; 1 }) {
        my $track = Slim::Schema::RemoteTrack->fetch($canonical)
                 || Slim::Schema::RemoteTrack->fetch($url);
        if ($track) {
            if ($meta->{duration} && $track->can('secs')
                && !($track->secs && $track->secs > 0)) {
                $track->secs($meta->{duration});
            }
            if ($meta->{title} && $track->can('title') && !$track->title) {
                my $display = $meta->{artist}
                    ? "$meta->{title} - $meta->{artist}"
                    : $meta->{title};
                $track->title($display);
            }
            if ($meta->{year} && $track->can('year') && !$track->year) {
                $track->year($meta->{year});
            }
        }
    }

    if ($client) {
        require Plugins::SpotOn::Plugin;
        return { %$meta,
            type    => Plugins::SpotOn::Plugin->_typeString($client, 'Browse'),
            bitrate => Plugins::SpotOn::Plugin->_bitrateForClient($client) . 'k',
        };
    }

    return $meta;
}

sub getIcon {
    my ($class, $url) = @_;

    if ($url) {
        my $canonical = $url;
        if ($canonical =~ m{^spoton:(?!//)}) {
            $canonical =~ s{^spoton:}{spoton://};
        }
        # COMPAT-03: same HTTP-to-spoton canonicalization as getMetadataFor(), so
        # icon lookups for daemon HTTP URLs hit the same cache entry.
        if ($canonical =~ m{^https?://[^/]+/(track|episode)/([A-Za-z0-9]+)(?:\?.*)?$}) {
            $canonical = "spoton://$1:$2";
        }
        my $meta = $cache->get('spoton_meta_' . md5_hex($canonical));
        return $meta->{cover} if $meta && $meta->{cover} && $meta->{cover} ne '/html/images/cover.png';
    }

    return 'plugins/SpotOn/html/images/SpotOn_MTL_svg_spoton.png';
}

sub _buildExplodedTrackItem {
    my ($track, $albumName, $albumCover) = @_;
    my $title   = $track->{name} || '';
    my $artist  = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
    my $url     = 'spoton://track:' . $track->{id};
    return {
        name     => "$title - $artist",
        title    => $title,
        artist   => $artist,
        album    => $albumName || '',
        line1    => $title,
        line2    => $artist . ($albumName ? " \x{2022} $albumName" : ''),
        url      => $url,
        play     => $url,
        image    => $albumCover || '/html/images/cover.png',
        duration => ($track->{duration_ms} || 0) / 1000,
        type     => 'audio',
    };
}

sub _buildExplodedEpisodeItem {
    my ($ep) = @_;
    my $show  = $ep->{show} || {};
    my $title = $ep->{name} || '';
    my $cover = _largestImage($ep->{images})
             || _largestImage($show->{images})
             || '/html/images/cover.png';
    my $url   = 'spoton://episode:' . $ep->{id};
    return {
        name     => $title,
        title    => $title,
        artist   => $show->{name} || '',
        album    => $show->{name} || '',
        line1    => $title,
        line2    => $show->{name} || '',
        url      => $url,
        play     => $url,
        image    => $cover,
        duration => ($ep->{duration_ms} || 0) / 1000,
        type     => 'audio',
    };
}

sub _cacheExplodedTrack {
    my ($trackUrl, $track, $albumName, $albumCover, $albumId, $albumReleaseDate) = @_;
    require Plugins::SpotOn::Plugin;
    my %ids = Plugins::SpotOn::Plugin::_extractTrackIds($track);
    $ids{albumId} = $albumId if defined $albumId;    # explicit album context overrides
    my $year = Plugins::SpotOn::Plugin::_releaseYear(
        $albumReleaseDate // ($track->{album} || {})->{release_date}
    );
    require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
    $cache->set('spoton_meta_' . md5_hex($trackUrl), {
        _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
        title     => $track->{name} || '',
        artist    => join(', ', map { $_->{name} } @{ $track->{artists} || [] }),
        album     => $albumName || '',
        duration  => ($track->{duration_ms} || 0) / 1000,
        cover     => $albumCover || '/html/images/cover.png',
        icon      => $albumCover || '/html/images/cover.png',
        year      => $year,
        %ids,
    }, 3600);
}

sub _cacheExplodedEpisode {
    my ($epUrl, $ep) = @_;
    my $show  = $ep->{show} || {};
    my $cover = _largestImage($ep->{images})
             || _largestImage($show->{images})
             || '/html/images/cover.png';
    require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
    $cache->set('spoton_meta_' . md5_hex($epUrl), {
        _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
        title    => $ep->{name} || '',
        artist   => $show->{name} || '',
        album    => $show->{name} || '',
        duration => ($ep->{duration_ms} || 0) / 1000,
        cover    => $cover,
        icon     => $cover,
        showId   => $show->{id},
        showName => $show->{name},
    }, 3600);
}

# _placeholderMeta($url)
# Returns minimal metadata for immediate display while async re-fetch is in progress.
# D-03: cache miss returns placeholder, not empty hashref.
sub _placeholderMeta {
    my ($url) = @_;
    my $title = ($url && $url =~ m{spoton://(?:track|episode):}) ? 'Loading...' : '';
    return {
        cover => '/html/images/cover.png',
        icon  => '/html/images/cover.png',
        title => $title,
    };
}

# _asyncRefetch($class, $client, $url, $canonical)
# Fires an async API::SpClient->getTrack call for a cache-miss URL.
# D-04: extracts track ID from Browse URL or from cached spotifyUri for Connect URLs.
# D-05: debounce via %_pendingRefetch — one in-flight re-fetch per URL.
# Pitfall 4: delete from debounce hash is the FIRST action in the callback.
# Pitfall 3: Connect re-fetch stores result under Browse URL cache key.
sub _asyncRefetch {
    my ($class, $client, $url, $canonical) = @_;

    # D-05: debounce — skip if already fetching this URL
    return unless $url;
    return if $_pendingRefetch{$url};

    # Phase 82 (Befund 2 / Pitfall 10): the metadata fetch for this exact url
    # failed within the last 60s (definitive) or 15s (transient) -- without
    # this short-circuit, every status poll (Material Skin: every 1-5s)
    # re-fires API requests against the app-wide 30s rate window (CLAUDE.md
    # § Rate Limits) for a title that will not resolve right now
    # (server.log:989-1009, measured -- not a timing corner).
    return if $cache->get('spoton_meta_neg_' . md5_hex($url));

    # Extract track/episode ID from Browse URL or from cached connect entry's spotifyUri
    my ($trackId, $episodeId);
    if ($canonical && $canonical =~ m{spoton://track:([A-Za-z0-9]+)}) {
        $trackId = $1;
    } elsif ($canonical && $canonical =~ m{spoton://episode:([A-Za-z0-9]+)}) {
        $episodeId = $1;
    } elsif ($url && $url =~ m{spoton://connect-}) {
        my $connect_meta = $cache->get('spoton_meta_' . md5_hex($url));
        if ($connect_meta && $connect_meta->{spotifyUri}
            && $connect_meta->{spotifyUri} =~ m/^spotify:track:([A-Za-z0-9]+)$/) {
            $trackId = $1;
        }
    }
    return unless $trackId || $episodeId;

    # Resolve accountId — T-11-03: only alphanumeric IDs reach here
    my $accountId;
    if ($client) {
        $accountId = $prefs->client($client)->get('activeAccount')
                  || $prefs->get('activeAccount')
                  || '';
    } else {
        $accountId = $prefs->get('activeAccount') || '';
    }

    # D-05: mark in-flight
    $_pendingRefetch{$url} = 1;

    require Plugins::SpotOn::API::SpClient;

    my $fetchCb = sub {
        my ($info, $err) = @_;

        # Pitfall 4: ALWAYS clear debounce first — even on error
        delete $_pendingRefetch{$url};

        unless ($info && $info->{name}) {
            # Quick 260910-upw + Fable-5 review of df80cdb (CR-01/WR-01),
            # 85-07 D-11: classify what the failure means for seek.
            #   - a real HTTP 404 from spclient (the only metadata source):
            #     this id has no metadata, the length will never arrive.
            #     Only this case fail-closes seek: noteMetadataMissing marks
            #     the uri non-seekable (canDoAction/getSeekData refuse the
            #     LMS-side restart) and surfaces exactly one errors[] entry.
            #   - anything else -- a transport error (code 0, "Connect timed
            #     out"), 5xx, no_token, 400, invalid_id -- says nothing about
            #     whether the title has metadata: no notify, and a later
            #     success can still resolve it (a WLAN hiccup must not cost a
            #     title its seek for the session, P5).
            #
            # CR-01: EVERY failure still keeps a per-url bound on the refetch
            # cadence via the negative cache. Without this, a fast-failing
            # 5xx/no_token/connect-timeout refetches on every status poll
            # (Material Skin: every 1-5s), throttled only by a reactive 429
            # -- exactly the "429 bursts" this project's core value forbids.
            # Transient failures get a short TTL (META_REFETCH_TRANSIENT_TTL)
            # so a later success still lands promptly; 404, 400 and
            # invalid_id (structurally permanent) keep the 60s bound.
            my ($code, $reason) = (0, '');
            if ($err && ref($err) eq 'HASH') {
                $code   = $err->{code}  || 0;
                $reason = $err->{error} // '';
            }

            my $definitive = ($code == 404);
            my $permanent  = ($definitive || $code == 400 || $reason eq 'invalid_id');

            $cache->set('spoton_meta_neg_' . md5_hex($url), 1,
                $permanent ? 60 : META_REFETCH_TRANSIENT_TTL);

            if ($definitive && $client) {
                # Best-effort -- see _applyRuntimeMetadata's identical guard.
                eval {
                    require Plugins::SpotOn::Unified::DaemonManager;
                    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
                    $be->notify('noteMetadataMissing', url => $canonical || $url) if $be;
                    1;
                };
            }
            return;
        }

        my $title    = $info->{name};
        my $duration = ($info->{duration_ms} || 0) / 1000;
        my ($artist, $album, $cover, $year);

        if ($episodeId) {
            $artist = ($info->{show} || {})->{name} || '';
            $album  = ($info->{show} || {})->{name} || '';
            $cover  = _largestImage($info->{images})
                   || _largestImage(($info->{show} || {})->{images})
                   || '/html/images/cover.png';
            $year   = '';
        } else {
            $artist = join(', ', map { $_->{name} } @{ $info->{artists} || [] });
            $album  = ($info->{album} || {})->{name} || '';
            $cover  = _largestImage(($info->{album} || {})->{images})
                   || '/html/images/cover.png';
            require Plugins::SpotOn::Plugin;
            $year   = Plugins::SpotOn::Plugin::_releaseYear(($info->{album} || {})->{release_date});
        }

        my %new_meta = (
            _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),   # 79-43 (D-33 FULL-3 CR-01)
            title    => $title,
            artist   => $artist,
            album    => $album,
            duration => $duration,
            cover    => $cover,
            icon     => $cover,
            year     => $year,
        );

        if ($episodeId) {
            my $show = $info->{show} || {};
            $new_meta{showId}   = $show->{id};
            $new_meta{showName} = $show->{name};
        } else {
            require Plugins::SpotOn::Plugin;
            my %ids = Plugins::SpotOn::Plugin::_extractTrackIds($info);
            @new_meta{keys %ids} = values %ids;
        }

        # Pitfall 3: for Connect URLs, store under Browse URL key so future lookups find it
        my $cacheUrl = ($url && $url =~ m{spoton://connect-})
            ? "spoton://track:$trackId"
            : $canonical;

        $cache->set('spoton_meta_' . md5_hex($cacheUrl), \%new_meta, 604800);

        # 79-43 (D-33 FULL-3 CR-01): a Connect history record that was read without the current marker is healed
        # in place - its names are replaced by the fresh ones, everything else (spotifyUri, type, bitrate) stays.
        if ($url && $url =~ m{spoton://connect-}) {
            my $histKey = 'spoton_meta_' . md5_hex($url);
            my $hist    = $cache->get($histKey);
            if (ref($hist) eq 'HASH' && !_metaCurrent($hist)) {
                $cache->set($histKey, {
                    %$hist,
                    map { $_ => $new_meta{$_} } qw(_spoton_fmt title artist album duration cover icon year),
                }, 604800);
            }
        }

        $new_meta{url} ||= $cacheUrl;
        my $refetchSong;
        if ($client && $client->can('currentSongForUrl')) {
            $refetchSong = $client->currentSongForUrl($url)
                        || $client->currentSongForUrl($cacheUrl);
        }
        _applyRuntimeMetadata($client, $refetchSong, $cacheUrl, \%new_meta);

        # Notify LMS to refresh NowPlaying display
        if ($client) {
            require Slim::Control::Request;
            $client->currentPlaylistUpdateTime(Time::HiRes::time())
                if $client->can('currentPlaylistUpdateTime');
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        }
    };

    if ($episodeId) {
        Plugins::SpotOn::API::SpClient->getEpisode($accountId, $episodeId, $fetchCb);
    } else {
        Plugins::SpotOn::API::SpClient->getTrack($accountId, $trackId, $fetchCb);
    }
}

sub _largestImage { Plugins::SpotOn::Plugin::_largestImage(@_) }

# _metaCurrent($meta) -- 79-43 (D-33 FULL-3 CR-01): true when a spoton_meta record carries the current format
# marker (_spoton_fmt >= SpClient's TRACK_META_FORMAT). A record without it can hold the byte form of the names;
# every reader that SHOWS names treats it as a miss. Readers of other fields (cover, duration, spotifyUri) do not ask.
sub _metaCurrent {
    my ($meta) = @_;
    return 0 unless ref($meta) eq 'HASH';
    my $fmt = $meta->{_spoton_fmt};
    require Plugins::SpotOn::API::SpClient;
    return (defined $fmt && $fmt =~ /\A\d+\z/ && $fmt >= Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT()) ? 1 : 0;
}

1;
