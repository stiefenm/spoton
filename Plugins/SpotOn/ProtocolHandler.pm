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

# _useSoloist() -- Phase 72 D-01: pure runtime backend-pref check. spoton://
# URLs are unchanged across backends; every entry point below branches on
# this instead of the URL shape.
sub _useSoloist { ($prefs->get('backend') || 'librespot') eq 'soloist' }

sub contentType { _useSoloist() ? 'sol' : 'son' }

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
    # Phase 72 D-02/D-03: soloist branch first — ahead of the URL-shape
    # branches below — so Browse spoton:// URLs route to the sol-* transcoder
    # profile instead of the daemon-proxy 'soc' default.
    return 'sol' if _useSoloist() && $url && $url =~ m{^spoton://(?:track|episode):};
    return 'soc' if $url && $url =~ m{spoton://connect-};
    return 'pcm' if $url && $url =~ m{:\d+/stream\b};
    return 'soc' if $url && $url =~ m{:\d+/(?:track|episode)/};  # Phase 28: Browse daemon HTTP URLs
    return 'soc';
}

# formatOverride($class, $song)
# Returns the content type (INPUT side of transcoding key) for the current song.
# 'son' (SpotOn Native) when daemon sends OGG passthrough, 'soc' (SpotOn Coded) for PCM.
#
# LMS Song.pm constructs the transcoding profile key as:
#   formatOverride-outputFormat-*-*  (e.g. soc-pcm-*-* or son-ogg-*-*)
sub formatOverride {
    my ($class, $song) = @_;

    my $client = $song->master;
    my $url = $song->track->url || '';

    # Phase 72 D-02/D-03: without this branch, LMS Song.pm would build a
    # son-*/soc-* profile key for a soloist-backed Browse URL and no sol-*
    # rule would ever match (silent playback failure).
    if (_useSoloist() && $url =~ m{^spoton://(?:track|episode):}) {
        $log->warn("[DIAG] formatOverride: mac=" . ($client ? $client->id : 'none') . " url=$url result=sol (soloist)") if $prefs->get('diagnosticMode');
        return 'sol';
    }

    require Plugins::SpotOn::Unified::DaemonManager;
    my $fmt = Plugins::SpotOn::Unified::DaemonManager->resolvePassthroughForClient($client)
            ? 'son' : 'soc';

    $log->warn("[DIAG] formatOverride: mac=" . ($client ? $client->id : 'none') . " url=$url result=$fmt") if $prefs->get('diagnosticMode');
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

    # D-03: soloist has no HTTP-serving daemon for Browse — LMS must use the
    # sol-* transcoder path (custom-convert.conf) instead. Placed before the
    # streamingMode gate below so this check needs no per-client pref stubs.
    # Connect URLs (spoton://connect-) are deliberately untouched (Phase 73).
    if (_useSoloist() && $url && $url =~ m{^spoton://(?:track|episode):}) {
        $log->warn("[DIAG] canDirectStream: url=$url result=0 reason=soloist_transcoder_path") if $prefs->get('diagnosticMode');
        return 0;
    }

    # COMPAT-02: per-player streamingMode=proxy (or per-player 'global' resolving
    # to a global streamingMode=proxy default) forces LMS-relayed streaming for
    # BOTH Browse and Connect (D-02) — one gate at the top covers both branches
    # below, no duplication. D-03: this gate is orthogonal to sync-group gating,
    # which already happens independently inside the Browse/Connect branches.
    # D-05: this gate is orthogonal to codec/transcoding format selection.
    # Known, accepted side effect (review finding): in proxy mode this gate
    # returns before the translated-Connect-URL cleanup further down, so an entry
    # can remain in %_translatedConnectUrls; if the user later switches back to
    # direct, one stale entry causes a single harmless extra return 0 (the proxy
    # path in new() absorbs it) — bounded and accepted, no mitigation needed.
    {
        my $gateClient = $client->can('master') ? $client->master : $client;
        my $mode = $prefs->client($gateClient)->get('streamingMode') || 'global';
        if ($mode eq 'global') {
            # GH #96: per-player unset/global resolves against the global default
            $mode = $prefs->get('streamingMode') || 'direct';
        }
        if ($mode eq 'proxy') {
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (streamingMode=proxy)"
            );
            return 0;
        }
    }

    # Browse URL: direct stream to unified daemon /track/{id}
    if ($url && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$}) {
        my $contentType = $1;
        my $trackId = $2;
        my $browseClient = $client->can('master') ? $client->master : $client;
        require Plugins::SpotOn::Unified::DaemonManager;
        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($browseClient);
        if ($helper && $helper->alive && $helper->_streamPort) {
            if ($browseClient->isSynced()) {
                $log->warn("[DIAG] canDirectStream: unified browse url=$url result=0 reason=synced") if $prefs->get('diagnosticMode');
                return 0;   # Synced: new() proxy handles
            }
            my $host   = Slim::Utils::Network::serverAddr();
            my $ds_url = "http://$host:" . $helper->_streamPort . "/$contentType/$trackId";
            $log->warn("[DIAG] canDirectStream: unified browse url=$ds_url") if $prefs->get('diagnosticMode');
            return $ds_url;
        }
    }

    # Connect URL: direct stream to unified daemon /stream
    if ($url && $url =~ m{spoton://connect-}) {
        # Translated history URL: translate to Browse, skip Direct Stream
        if (delete $_translatedConnectUrls{$url}) {
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (translated Connect history URL)"
            );
            return 0;
        }
        my $connectClient = $client->can('master') ? $client->master : $client;
        # Per-player streamFormat: pcm/flac/mp3 force transcoding
        {
            my $fmt = $prefs->client($connectClient)->get('streamFormat')
                   || $prefs->client($connectClient)->get('connectOggOverride')
                   || 'auto';
            if ($fmt =~ /^(?:pcm|flac|mp3)$/) {
                main::INFOLOG && $log->is_info && $log->info(
                    "canDirectStream: 0 (streamFormat=$fmt forces transcoding)"
                );
                return 0;
            }
        }
        require Plugins::SpotOn::Unified::DaemonManager;
        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($connectClient);
        if ($helper && $helper->alive && $helper->_streamPort) {
            if ($connectClient->isSynced()) {
                $log->warn("[DIAG] canDirectStream: unified connect result=0 reason=synced") if $prefs->get('diagnosticMode');
                main::INFOLOG && $log->is_info && $log->info(
                    "canDirectStream: 0 (player is synced)"
                );
                return 0;
            }
            my $host   = Slim::Utils::Network::serverAddr();
            my $ds_url = "http://$host:" . $helper->_streamPort . "/stream";
            $log->warn("[DIAG] canDirectStream: unified connect url=$ds_url") if $prefs->get('diagnosticMode');
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: $ds_url"
            );
            return $ds_url;
        }
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
            "requestString: daemon proxy — plain GET (no Range) for $url"
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
            $log->warn("Browse daemon 404 for $url — prefetch context, scheduling skip in ${remaining}s");
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
            $log->warn("Browse daemon 404 for $url — retry $attempt/" . MAX_BROWSE_404_RETRIES
                      . " in " . BROWSE_404_RETRY_DELAY . "s");
            Slim::Utils::Timers::killTimers($client, \&_retryStream);
            Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + BROWSE_404_RETRY_DELAY,
                \&_retryStream);
            return;
        }

        # Exhausted retries — skip to next track and clean up
        $log->warn("Browse daemon 404 for $url — $attempt attempts exhausted, skipping to next track");
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
                . ($streamUrl || 'none') . ") — dropping stale skip for $url (M9)");
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
            "canEnhanceHTTP: daemon proxy — returning 0 for $url"
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
                "D-08: Browse URL — unified daemon handles mode transition for " . $client->id
            );
        }
    }

    # (b2) Browse sync-group proxy — substitute Unified daemon HTTP URL for synced players.
    # T-28-08: trackId extracted via [A-Za-z0-9]+ regex from already-validated spoton:// URL.
    # D-03: soloist has no unified daemon for Browse -- there is never a
    # daemon to proxy through, so this block must not run on the soloist
    # path (it would otherwise return undef whenever no daemon is alive).
    # Guarded out entirely so the URL falls straight through to the final
    # Slim::Player::Protocols::HTTP->new($args) below, unchanged -- exactly
    # what the pre-Phase-30 transcoder-model handler did (f93c9d2: browse
    # URLs reached HTTP->new() untouched; the `R` capability convert rule
    # consumes $URL$ itself, so this stream object carries no audio data).
    if (!_useSoloist() && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$} && $url !~ m{spoton://connect-}) {
        my $contentType = $1;
        my $trackId = $2;
        my $client  = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            require Plugins::SpotOn::Unified::DaemonManager;
            my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
            if ($helper && $helper->alive && $helper->_streamPort) {
                my $host    = Slim::Utils::Network::serverAddr();
                my $httpUrl = "http://$host:" . $helper->_streamPort . "/$contentType/$trackId";
                my $song = $args->{song};
                if ($song && $song->seekdata && $song->seekdata->{'timeOffset'}) {
                    my $offset = $song->seekdata->{'timeOffset'};
                    $httpUrl .= '?start_position=' . $offset;
                    $song->startOffset($offset);
                }
                $log->warn("[DIAG] unified_browse_sync_proxy: mac=" . $client->id . " http_url=$httpUrl") if $prefs->get('diagnosticMode');
                $args = { %$args, url => $httpUrl };
            } else {
                main::INFOLOG && $log->is_info && $log->info(
                    "Browse URL but no active unified daemon for " . ($client ? $client->id : '?') . " — returning undef"
                );
                return undef;
            }
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
                my $host    = Slim::Utils::Network::serverAddr();
                my $httpUrl = 'http://' . $host . ':' . $helper->_streamPort . '/stream';
                $log->warn("[DIAG] unified_connect_sync_proxy: mac=" . $client->id . " http_url=$httpUrl") if $prefs->get('diagnosticMode');
                $args = { %$args, url => $httpUrl };
            } else {
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect URL but no active unified daemon for " . ($client ? $client->id : '?') . " — returning undef"
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
            $successCb->();
            return;
        }

        main::INFOLOG && $log->is_info && $log->info(
            "getNextTrack: dead Connect URL with no cached spotifyUri — cannot translate"
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

    # D-04/Pitfall-2: Soloist emits raw S32LE/44100/stereo PCM. Without these
    # hints the sol-pcm profile would be announced as 16-bit and produce
    # garbage; the flc target is self-describing (--bps=32 in the convert
    # rule) and unaffected by this.
    if (_useSoloist() && $url =~ m{^spoton://(?:track|episode):}) {
        my $track = $song->track;
        if ($track) {
            $track->samplesize(32)    if $track->can('samplesize');
            $track->samplerate(44100) if $track->can('samplerate');
            $track->channels(2)       if $track->can('channels');
        }
    }

    $successCb->();
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
        require Plugins::SpotOn::API::Client;

        Plugins::SpotOn::API::Client->getAlbum($accountId, $albumId, sub {
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
                Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, {
                    offset => $offset,
                    limit  => Plugins::SpotOn::API::Client->getLimit('library'),
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
        require Plugins::SpotOn::API::Client;

        my @allItems;
        my $fetchPage;
        $fetchPage = sub {
            my ($offset) = @_;
            Plugins::SpotOn::API::Client->getPlaylistItems($accountId, $playlistId, {
                offset => $offset,
                limit  => Plugins::SpotOn::API::Client->getLimit('playlist_items'),
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
        require Plugins::SpotOn::API::Client;

        my @allItems;
        my $total = 0;
        my $fetchPage;
        $fetchPage = sub {
            my ($offset) = @_;
            Plugins::SpotOn::API::Client->getShowEpisodes($accountId, $showId, {
                offset => $offset,
                limit  => Plugins::SpotOn::API::Client->getLimit('library'),
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
    # Pitfall 3: soloist single-track mode has no seek/offset flag at all --
    # advertising seekability would make the seek bar restart tracks.
    # Browse-seek for soloist revisits in Phase 74 raw-capture work.
    return 0 if _useSoloist();
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub canTranscodeSeek {
    my ($class, $client) = @_;
    # Unified daemon: seek is handled via ?start_position=N in canDirectStreamSong,
    # not via $START$ in the transcoding command. Returning 0 keeps canDoSeek at 1
    # so streamMode 'I' stays in the profile search and soc-pcm-*-* matches.
    # 0 is also the correct answer on the soloist path (Pitfall 3) -- Soloist
    # has no --start-position flag to template into the sol-* convert rules;
    # canSeek()=0 above already prevents seek entry on that path.
    return 0;
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;

    # Connect mode (GH #129): return undef so _JumpToTime suppresses the
    # LMS-side stream restart (_Stop + _Stream would tear down /stream).
    # The ['time'] event still fires and Connect::_onSeek forwards the seek
    # to the binary via /control/seek.
    #
    # Known accepted paths that still restart the stream (59-REVIEW R-2/R-3):
    # - Pause -> seek -> unpause: _JumpPaused stores resumeTime (canSeek=1),
    #   unpause calls _JumpToTime with restartIfNoSeek=1 which bypasses this
    #   undef. Harmless: the binary already seeked, and the /stream reconnect
    #   re-enters the mid-song-connect path where CON-13 adjusts startOffset.
    #   Seek-to-0 while paused IS suppressed via canDoAction('rew').
    # - Seek beyond track duration (CLI only): LMS _Skip fires before
    #   getSeekData. No handler hook exists; accepted as known limitation.
    return undef if Plugins::SpotOn::Connect->isSpotifyConnect($client);

    return { timeOffset => $newtime };
}

# canDoAction($class, $client, $url, $action)
# Connect mode (R-1, GH #129): block LMS-side track restart on seek-to-0.
# _JumpToTime special-cases newtime == 0 BEFORE getSeekData and would
# _Stop + _Stream the Connect stream. Returning 0 for 'rew' suppresses the
# restart in both _JumpToTime (playing) and _JumpPaused (paused); the
# ['time'] event still fires and _onSeek forwards seek-to-0 to the binary.
# Track restart via prev-button is unaffected: _onPlaylistJump forwards
# playlist jump -1/+0 to /control/prev.
# All other actions ('stop', 'pause', 'fwd') must stay allowed (return 1).
sub canDoAction {
    my ($class, $client, $url, $action) = @_;

    if ($action eq 'rew' && Plugins::SpotOn::Connect->isSpotifyConnect($client)) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Connect mode: blocking LMS-side restart for 'rew' (seek-to-0 handled by binary)"
        );
        return 0;
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

    my $meta = $cache->get('spoton_meta_' . md5_hex($canonical));

    # Fallback: try original URL if normalization didn't help
    if (!$meta && $canonical ne $url) {
        $meta = $cache->get('spoton_meta_' . md5_hex($url));
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
                    ? "$meta->{title} \x{2014} $meta->{artist}"
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
    $cache->set('spoton_meta_' . md5_hex($trackUrl), {
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
    $cache->set('spoton_meta_' . md5_hex($epUrl), {
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
# Fires an async API::Client->getTrack call for a cache-miss URL.
# D-04: extracts track ID from Browse URL or from cached spotifyUri for Connect URLs.
# D-05: debounce via %_pendingRefetch — one in-flight re-fetch per URL.
# Pitfall 4: delete from debounce hash is the FIRST action in the callback.
# Pitfall 3: Connect re-fetch stores result under Browse URL cache key.
sub _asyncRefetch {
    my ($class, $client, $url, $canonical) = @_;

    # D-05: debounce — skip if already fetching this URL
    return unless $url;
    return if $_pendingRefetch{$url};

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

    require Plugins::SpotOn::API::Client;

    my $fetchCb = sub {
        my ($info) = @_;

        # Pitfall 4: ALWAYS clear debounce first — even on error
        delete $_pendingRefetch{$url};

        return unless $info && $info->{name};

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
        Plugins::SpotOn::API::Client->getEpisode($accountId, $episodeId, $fetchCb);
    } else {
        Plugins::SpotOn::API::Client->getTrack($accountId, $trackId, $fetchCb);
    }
}

sub _largestImage { Plugins::SpotOn::Plugin::_largestImage(@_) }

1;
