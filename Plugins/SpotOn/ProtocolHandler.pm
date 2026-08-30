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

# _streamingModeIsProxy($client) -- WR-05: per-player streamingMode=proxy (or
# per-player 'global' resolving to a global streamingMode=proxy default,
# GH #96) forces LMS-relayed streaming. Shared by canDirectStream's COMPAT-02
# gate, its soloist-Browse branch (which used to return a direct URL BEFORE
# that gate ever ran, silently bypassing the per-player preference), and
# new()'s soloist-Browse sync-group proxy substitution.
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
# purpose: there is no client context at this call site.
sub contentType { _useSoloist() ? 'soc' : 'son' }

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
    # Phase 73 D-03: soloist Browse now plays through the persistent daemon's
    # HTTP /stream endpoint -- the same 'soc' PCM-direct/proxy family as
    # librespot -- instead of the retired per-track 'sol' transcoder profile
    # (conf cleanup: 73-04). Kept as an explicit branch (even though 'soc' is
    # also the fall-through default below) so the D-03 intent survives
    # independent of the URL-shape branches below.
    return 'soc' if _useSoloist() && $url && $url =~ m{^spoton://(?:track|episode):};
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

    require Plugins::SpotOn::Unified::DaemonManager;

    # Phase 73 D-03 / Phase 76 D-06+D-07: the whole soloist family (Browse
    # AND Connect, HTTP /stream, Modell B) shares the 'soc' daemon-proxy
    # content type -- EXCEPT explicit MP3, which routes to the single-rule
    # 'smp' type. Rationale: TranscodingHelper picks the output format by
    # iterating the PLAYER's format-preference order (TranscodingHelper.pm:
    # 352-386) -- under 'soc', flc always beats mp3 on flc-capable players,
    # so a 'soc mp3' rule could never win there. 'smp' has exactly one rule
    # (smp mp3 * *, [lame]) so profile matching can only land on MP3 --
    # the same forcing idiom as 'son' (ogg-only).
    if (_useSoloist()) {
        my $resolved = Plugins::SpotOn::Unified::DaemonManager->resolveSoloistFormat($client);
        my $type = $resolved eq 'mp3' ? 'smp' : 'soc';
        $log->warn("[DIAG] formatOverride: mac=" . ($client ? $client->id : 'none') . " url=$url result=$type (soloist resolved=$resolved)") if $prefs->get('diagnosticMode');
        return $type;
    }

    my $fmt = Plugins::SpotOn::Unified::DaemonManager->resolvePassthroughForClient($client)
            ? 'son' : 'soc';

    # Phase 76 D-07: explicit MP3 under librespot routes to 'smp' too (the
    # pref regex in canDirectStream already allows mp3 for librespot) --
    # without this, 'soc' would let flc/pcm beat mp3 in the player's
    # format-preference order and the explicit choice would never take
    # effect on flc-capable players.
    if ($fmt eq 'soc' && $client) {
        my $pref = $prefs->client($client)->get('streamFormat')
                || $prefs->client($client)->get('connectOggOverride')
                || 'auto';
        $fmt = 'smp' if $pref eq 'mp3';
    }

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

    # D-03 (Phase 73, Modell B): soloist Browse now plays through the
    # persistent daemon's HTTP /stream endpoint -- the SAME endpoint Connect
    # uses (the daemon has exactly one fake-libpulse HTTP server, not a
    # per-track URL scheme) -- instead of the retired per-track 'sol'
    # transcoder path. Placed before the streamingMode gate below so this
    # check needs no per-client pref stubs. Connect URLs (spoton://connect-)
    # are handled by their own branch further down, untouched.
    if (_useSoloist() && $url && $url =~ m{^spoton://(?:track|episode):}) {
        my $browseClient = $client->can('master') ? $client->master : $client;

        # WR-05: this branch returns before the COMPAT-02 streamingMode gate
        # further down ever runs -- evaluate the same proxy resolution here
        # so a player configured with streamingMode=proxy (e.g. the GH #96
        # WiiM metadata workaround) does not silently direct-stream anyway.
        if (_streamingModeIsProxy($browseClient)) {
            $log->warn("[DIAG] canDirectStream: soloist browse url=$url result=0 reason=streamingMode_proxy") if $prefs->get('diagnosticMode');
            return 0;   # new()'s soloist sync-group proxy block handles substitution
        }

        require Plugins::SpotOn::Unified::DaemonManager;

        # Phase 76 D-06: the resolved soloist format gates direct-vs-transcode
        # (mirror of the librespot "streamFormat forces transcoding" branch in
        # the Connect block below). Only resolved 'pcm' keeps the direct
        # raw-S32 /stream URL (strm samplesize 32, 76-01); 'flac'/'mp3'
        # return 0 so LMS opens the stream itself and runs the soc/smp
        # transcode rule.
        {
            my $resolved = Plugins::SpotOn::Unified::DaemonManager->resolveSoloistFormat($browseClient);
            if ($resolved ne 'pcm') {
                $log->warn("[DIAG] canDirectStream: soloist browse url=$url result=0 reason=resolved_format_$resolved") if $prefs->get('diagnosticMode');
                return 0;
            }
        }

        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($browseClient);
        if ($helper && $helper->alive && $helper->_streamPort) {
            if ($browseClient->isSynced()) {
                $log->warn("[DIAG] canDirectStream: soloist browse url=$url result=0 reason=synced") if $prefs->get('diagnosticMode');
                return 0;   # Synced: new() proxy handles
            }
            my $host   = Slim::Utils::Network::serverAddr();
            my $ds_url = "http://$host:" . $helper->_streamPort . "/stream";
            $log->warn("[DIAG] canDirectStream: soloist browse url=$ds_url") if $prefs->get('diagnosticMode');
            return $ds_url;
        }
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: soloist browse — no alive daemon/stream port for "
            . ($browseClient ? $browseClient->id : '?')
        );
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
    if (_streamingModeIsProxy($client)) {
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: 0 (streamingMode=proxy)"
        );
        return 0;
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
        if (_useSoloist()) {
            # Phase 76 D-06: backend-dispatched gating -- the soloist resolver
            # replaces the raw pref check below (which treats explicit pcm as
            # "force transcoding"; under soloist explicit pcm KEEPS the direct
            # raw-S32 /stream path). Only 'flac'/'mp3' force the LMS-side
            # transcode pipeline.
            require Plugins::SpotOn::Unified::DaemonManager;
            my $resolved = Plugins::SpotOn::Unified::DaemonManager->resolveSoloistFormat($connectClient);
            if ($resolved ne 'pcm') {
                $log->warn("[DIAG] canDirectStream: unified connect result=0 reason=resolved_format_$resolved") if $prefs->get('diagnosticMode');
                main::INFOLOG && $log->is_info && $log->info(
                    "canDirectStream: 0 (soloist resolved format=$resolved forces transcoding)"
                );
                return 0;
            }
        }
        else {
            # Per-player streamFormat: pcm/flac/mp3 force transcoding (librespot)
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

    # (b3) D-03 (Phase 73, Modell B): soloist Browse sync-group proxy —
    # mirrors the Connect (b) block below verbatim (same /stream endpoint,
    # same daemon, same proxy pattern) since soloist Browse plays through
    # the identical HTTP /stream server Connect uses. Unsynced, non-proxy
    # soloist browse clients need no substitution here — canDirectStream()
    # above already returns the direct /stream URL for them. WR-05: also
    # substitute for an UNSYNCED player in streamingMode=proxy, since
    # canDirectStream() now returns 0 for that case too instead of a direct URL.
    if (_useSoloist() && $url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$} && $url !~ m{spoton://connect-}) {
        my $client = $args->{client};
        if ($client) {
            $client = $client->master if $client->can('master');
            if ($client->isSynced() || _streamingModeIsProxy($client)) {
                require Plugins::SpotOn::Unified::DaemonManager;
                my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
                if ($helper && $helper->alive && $helper->_streamPort) {
                    my $host    = Slim::Utils::Network::serverAddr();
                    my $httpUrl = "http://$host:" . $helper->_streamPort . "/stream";
                    $log->warn("[DIAG] soloist_browse_sync_proxy: mac=" . $client->id . " http_url=$httpUrl") if $prefs->get('diagnosticMode');
                    $args = { %$args, url => $httpUrl };
                } else {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Soloist browse URL but no active daemon for " . $client->id . " — returning undef"
                    );
                    return undef;
                }
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
            # D-08 (Phase 76): a live Soloist Connect session streams raw
            # S32LE from fake-libpulse's /stream (D-04) -- hint 32 so the
            # soc-flc rule's $SAMPLESIZE$ substitutes correctly. librespot
            # Connect PCM stays S16LE and must EXPLICITLY reset the hint to
            # 16 (CR-01): RemoteTrack objects are cached in-memory by URL
            # (Slim::Schema::RemoteTrack %Cache) and survive a backend
            # switch within one LMS uptime, so a stale samplesize(32) from a
            # prior soloist playback would misframe librespot's S16LE stream
            # (transcode: $SAMPLESIZE$=32; direct: strm pcmsamplesize '3').
            if (_useSoloist()) {
                my $track = $song->track;
                if ($track) {
                    $track->samplesize(32)    if $track->can('samplesize');
                    $track->samplerate(44100) if $track->can('samplerate');
                    $track->channels(2)       if $track->can('channels');
                }
            }
            else {
                my $track = $song->track;
                if ($track) {
                    $track->samplesize(16) if $track->can('samplesize');
                }
            }
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

    # D-08 (Phase 76): Soloist emits raw S32LE/44100/stereo PCM via
    # fake-libpulse's HTTP /stream -- D-04 upgraded the ring from S16LE to
    # S32LE to preserve the full float32 precision, so the hint is now 32.
    # It drives both the strm-frame pcm_sample_sizes mapping (32 => '3',
    # Squeezebox.pm:1129) and the $SAMPLESIZE$ substitution in the soc-flc
    # convert rule ($track->samplesize || 16, TranscodingHelper.pm:449).
    # librespot soc paths (S16LE) must EXPLICITLY reset the hint to 16
    # (CR-01, elsif below): RemoteTrack objects are cached in-memory by URL
    # and survive a backend switch within one LMS uptime, so relying on the
    # "never set" 16 default would leave a stale 32 from a prior soloist
    # playback in place.
    if (_useSoloist() && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$}) {
        my ($type, $id) = ($1, $2);
        my $track = $song->track;
        if ($track) {
            $track->samplesize(32)    if $track->can('samplesize');
            $track->samplerate(44100) if $track->can('samplerate');
            $track->channels(2)       if $track->can('channels');
        }

        # D-03 (Phase 73, Modell B): dispatch the actual play command to the
        # persistent daemon over WS. browseAdvancePending is set by
        # SoloistWS when THIS getNextTrack re-entry is the LMS-side mirror
        # of a track_changed the daemon already transitioned into (seeded
        # gapless advance, T-73-11 re-entry guard) -- Soloist is already
        # playing this track, so issuing another `play` would restart audio
        # that doesn't need restarting.
        my $client = $song->master;
        require Plugins::SpotOn::Unified::DaemonManager;
        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
        my $ws = ($helper && $helper->can('_ws')) ? $helper->_ws : undef;

        unless ($ws && $ws->connected) {
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: soloist browse -- WS not connected for " . ($client ? $client->id : '?')
            );
            $errorCb->('PROBLEM_OPENING', 'Soloist daemon not ready');
            return;
        }

        # WR-04: only honor the re-entry guard when the requested URI matches
        # browseCurrentUri (the track Soloist actually transitioned into) --
        # consuming the flag unconditionally for whatever track getNextTrack
        # happens to be called with meant a user skip racing a seeded advance
        # could swallow the play command for the user's own chosen track.
        # Cleared unconditionally on every entry so it can never leak into a
        # later, unrelated getNextTrack call (e.g. via the WS-not-connected
        # error path above, which previously left it set).
        my $pending = $ws->browseAdvancePending;
        $ws->browseAdvancePending(0);

        if ($pending && ($ws->browseCurrentUri // '') eq "spotify:$type:$id") {
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: soloist browse advance re-entry for $url -- skipping play (already playing)"
            );
        }
        else {
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: soloist browse -- startBrowseTrack(spotify:$type:$id)"
            );
            # WR-03: check startBrowseTrack's return value -- a failed send
            # (not connected / pre-handshake drop / write error) must not
            # proceed to open /stream and play silence over a browse session
            # that never actually started on the daemon side.
            unless ($ws->startBrowseTrack("spotify:$type:$id", $client)) {
                $errorCb->('PROBLEM_OPENING', 'Soloist daemon send failed');
                return;
            }
        }
    }
    elsif ($url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$}) {
        # CR-01 (Phase 76 review): librespot browse path -- explicitly reset
        # the samplesize hint instead of relying on "never set". The shared
        # RemoteTrack keeps a stale 32 from a prior soloist playback
        # otherwise (backend switch without LMS restart), misframing the
        # daemon's S16LE stream in both the transcode ($SAMPLESIZE$) and
        # direct (strm pcmsamplesize) paths.
        my $track = $song->track;
        if ($track) {
            $track->samplesize(16) if $track->can('samplesize');
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
                    limit  => Plugins::SpotOn::API::SpClient->getLimit('library'),
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
                limit  => Plugins::SpotOn::API::SpClient->getLimit('playlist_items'),
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
                limit  => Plugins::SpotOn::API::SpClient->getLimit('library'),
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
    # D-03 (Phase 73, Modell B): soloist Browse now supports seek via the
    # daemon's WS `seek` command (the persistent daemon lifted the
    # Phase-72 hard 0 -- single-track mode had no seek/offset flag at all).
    # Both backends fall through to the same LMS-version gate.
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub canTranscodeSeek {
    my ($class, $client) = @_;
    # Unified daemon: seek is handled via ?start_position=N in canDirectStreamSong,
    # not via $START$ in the transcoding command. Returning 0 keeps canDoSeek at 1
    # so streamMode 'I' stays in the profile search and soc-pcm-*-* matches.
    # 0 is also the correct answer on the soloist path (D-03): seek there is
    # WS-based now (getSeekData returns undef + Connect.pm-style forwarding
    # for the browse session, 73-03 Task 3) -- there is no transcoding-side
    # $START$ template to fill for soloist either.
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

    # D-03 (Phase 73, Modell B): soloist Browse seek is also WS-based --
    # the browse session forwards the seek to Soloist itself
    # (Connect.pm-style soloist-browse forwarding, 73-03 Task 3). Suppress
    # the LMS-side stream restart here too (same GH #129 pattern as the
    # Connect branch above) so the daemon's own `seek` command is what
    # actually moves the position, not an LMS-side /stream reconnect.
    if (_useSoloist() && $song) {
        my $songUrl = $song->track ? ($song->track->url || '') : '';
        return undef if $songUrl =~ m{^spoton://(?:track|episode):};
    }

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

    if ($action eq 'rew'
        && (Plugins::SpotOn::Connect->isSpotifyConnect($client) || _hasActiveSoloistBrowseSession($client)))
    {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Connect/soloist-browse mode: blocking LMS-side restart for 'rew' (seek-to-0 handled by binary)"
        );
        return 0;
    }

    return 1;
}

# _hasActiveSoloistBrowseSession($client) -- 73-03 Task 2 (D-03): true when
# this client's soloist daemon WS is currently running a browse-managed
# session. Used to extend the GH #129 seek-to-0 restart suppression
# (canDoAction('rew')) to soloist Browse the same way it already covers
# Connect.
sub _hasActiveSoloistBrowseSession {
    my ($client) = @_;
    return 0 unless _useSoloist() && $client;

    my $browseClient = $client->can('master') ? $client->master : $client;
    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($browseClient);
    my $ws = ($helper && $helper->can('_ws')) ? $helper->_ws : undef;

    return ($ws && $ws->browseSession) ? 1 : 0;
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
        Plugins::SpotOn::API::SpClient->getEpisode($accountId, $episodeId, $fetchCb);
    } else {
        Plugins::SpotOn::API::SpClient->getTrack($accountId, $trackId, $fetchCb);
    }
}

sub _largestImage { Plugins::SpotOn::Plugin::_largestImage(@_) }

1;
