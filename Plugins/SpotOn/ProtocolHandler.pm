package Plugins::SpotOn::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

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
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
my $CRLF  = "\x0d\x0a";

# D-05: debounce — one in-flight re-fetch per URL
our %_pendingRefetch;

# Track Connect URLs translated to Browse by getNextTrack
my %_translatedConnectUrls;

# Per-client retry state for transient Browse daemon 404s (audio-key throttle)
use constant MAX_BROWSE_404_RETRIES => 3;
use constant BROWSE_404_RETRY_DELAY => 2;   # seconds between retries
my %_browse404Retries;  # "$clientId|$trackUrl" => attempt_count

sub contentType { 'son' }

sub isRemote    { 1 }

# getFormatForURL($class, $url)
# Returns content type for a given URL:
# - 'soc' for Connect URLs (spoton://connect-*)
# - 'son' for single-track Browse URLs (default)
sub getFormatForURL {
    my ($class, $url) = @_;
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
    if ($url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$} && $url !~ m{spoton://connect-}) {
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

            my $albumName  = $album->{name} || '';
            my $albumCover = _largestImage($album->{images}) || '/html/images/cover.png';
            my $tracksData = $album->{tracks} || {};
            my $total      = $tracksData->{total} || 0;

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
                _cacheExplodedTrack($item->{url}, $track, $albumName, $albumCover, $albumId);
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
                    limit  => 50,
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
                        _cacheExplodedTrack($item->{url}, $track, $albumName, $albumCover, $albumId);
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
                limit  => 100,
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
                    next unless $plItem && $plItem->{track} && $plItem->{track}{id};
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
                limit  => 50,
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
    if ($client) {
        my $song = $client->playingSong();
        my $url = $song ? ($song->track->url || '') : '';
        return 0 if $url =~ m{spoton://connect-};
    }
    return Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
}

sub canTranscodeSeek {
    my ($class, $client) = @_;
    if ($client) {
        my $song = $client->playingSong();
        my $url = $song ? ($song->track->url || '') : '';
        return 0 if $url =~ m{spoton://connect-};
    }
    # Unified daemon: seek is handled via ?start_position=N in canDirectStreamSong,
    # not via $START$ in the transcoding command. Returning 0 keeps canDoSeek at 1
    # so streamMode 'I' stays in the profile search and soc-pcm-*-* matches.
    return 0;
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
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
    my ($trackUrl, $track, $albumName, $albumCover, $albumId) = @_;
    require Plugins::SpotOn::Plugin;
    my %ids = Plugins::SpotOn::Plugin::_extractTrackIds($track);
    $ids{albumId} = $albumId if defined $albumId;    # explicit album context overrides
    $cache->set('spoton_meta_' . md5_hex($trackUrl), {
        title     => $track->{name} || '',
        artist    => join(', ', map { $_->{name} } @{ $track->{artists} || [] }),
        album     => $albumName || '',
        duration  => ($track->{duration_ms} || 0) / 1000,
        cover     => $albumCover || '/html/images/cover.png',
        icon      => $albumCover || '/html/images/cover.png',
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
        album    => '',
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
        my ($artist, $album, $cover);

        if ($episodeId) {
            $artist = ($info->{show} || {})->{name} || '';
            $album  = '';
            $cover  = _largestImage($info->{images})
                   || _largestImage(($info->{show} || {})->{images})
                   || '/html/images/cover.png';
        } else {
            $artist = join(', ', map { $_->{name} } @{ $info->{artists} || [] });
            $album  = ($info->{album} || {})->{name} || '';
            $cover  = _largestImage(($info->{album} || {})->{images})
                   || '/html/images/cover.png';
        }

        my %new_meta = (
            title    => $title,
            artist   => $artist,
            album    => $album,
            duration => $duration,
            cover    => $cover,
            icon     => $cover,
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
