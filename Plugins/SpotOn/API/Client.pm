package Plugins::SpotOn::API::Client;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Exporter 'import';
our @EXPORT_OK = qw(SPOTON_DEFAULT_CLIENT_ID);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Constants
use constant RATE_LIMIT_DEFAULT_BACKOFF => 5;
use constant MAX_CONCURRENT_REQUESTS    => 3;
use constant API_BASE                   => 'https://api.spotify.com/v1';
use constant REQUEST_TIMEOUT            => 30;
use constant PERSONAL_MIX_CATEGORY      => '0JQ5DAt0tbjZptfcdMSKl3';
# Source: Spotty API.pm:18 (verified: michaelherger/Spotty-Plugin/API.pm)

use constant SPOTON_DEFAULT_CLIENT_ID => 'd420a117a32841c2b3474932e49fb54b';

# ------------------------------------------------------------
# Web-Player-scoped request constants (Phase 52, D-07)
# ------------------------------------------------------------
# pathfinderHome() and getWebPlayerPlaylistItems() route traffic through the
# Web-Player token (Plugins::SpotOn::API::WebPlayer->getToken), NEVER
# TokenManager->getToken, and isolate their rate-limit state under a
# distinct cache key so a Pathfinder/37i9 429 never sets the Browse
# spoton_rate_limit flag (Pitfall 5, T-52-04).
use constant WP_RATE_LIMIT_KEY     => 'spoton_wp_rate_limit';
use constant WP_GQL_HASH_CACHE_KEY => 'spoton_wp_gql_hash';
use constant PATHFINDER_URL        => 'https://api-partner.spotify.com/pathfinder/v2/query';

# PATHFINDER_HOME_HASH_DEFAULT: persisted-query sha256Hash for the Pathfinder
# "home" GraphQL operation. UNVERIFIED PLACEHOLDER -- RESEARCH Open Question 1 /
# Assumption A4 (LOW confidence): no reliable public feed for this hash was
# found during this phase's research (rotates with every web-player release).
# Must be captured from a live web-player session (DevTools Network tab ->
# pathfinder/v2/query request -> extensions.persistedQuery.sha256Hash) and
# pasted into the "Pathfinder Query Hash (Advanced)" field under Settings ->
# Made For You (Plan 52-06 / CR-01 fix), which stores it in the
# pathfinderHash pref -- read prefs-first by pathfinderHome() below. Until an
# admin configures a real hash, a pathfinderHome() call will most likely
# receive a PersistedQueryNotFound errors[] response and degrade to an empty
# result -- the designed fail-safe (Pitfall 4), not a bug.
use constant PATHFINDER_HOME_HASH_DEFAULT => 'REPLACE_WITH_LIVE_CAPTURED_HOME_PERSISTED_QUERY_HASH';
use constant PATHFINDER_PLAYLIST_HASH    => 'a65e12194ed5fc443a1cdebed5fabe33ca5b07b987185d63c72483867ad13cb4';

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# Module-level concurrency counter.
# Must be reset to 0 in Plugin.pm::initPlugin via Client->reset()
# to prevent stale counter after plugin reload (Pitfall 2 from RESEARCH.md).
my $inflightCount = 0;

# API telemetry counters (Phase 32 — Status Page)
my $apiRequestCount = 0;
my $api429Count     = 0;

# API limit detection — probed once per startup, conservative defaults until then.
# Spotify enforces per-app maximums that vary by Client ID (Dev Mode).
# artist_albums/album_tracks are separate namespaces from library — #118 root
# cause was reusing the library limit (50) for artist/albums, which Dev Mode
# caps differently (observed 400 above ~20-45 depending on Client ID).
my %_detectedLimits = (
    search         => 10,
    library        => 50,
    artist_albums  => 20,
    album_tracks   => 50,
    playlist_items => 100,
);
my %_blockedEndpoints;
my $_limitsProbed = 0;
my $_limitsLastProbed = 0;
use constant REPROBE_COOLDOWN_S => 3600 * 6;

# ============================================================
# Public class methods
# ============================================================

# reset($class)
# Resets the inflight and telemetry counters. Called by Plugin.pm::initPlugin on startup.
sub reset {
    my ($class) = @_;
    $inflightCount  = 0;
    $apiRequestCount = 0;
    $api429Count     = 0;
    %_detectedLimits = (
        search => 10, library => 50, artist_albums => 20,
        album_tracks => 50, playlist_items => 100,
    );
    %_blockedEndpoints = ();
    $_limitsProbed      = 0;
    $_limitsLastProbed  = 0;
    main::INFOLOG && $log->info("Client: counters and limit detection reset");
}

sub getLimit {
    my ($class, $endpointClass) = @_;
    return 0 if $_blockedEndpoints{$endpointClass};
    return $_detectedLimits{$endpointClass} // 50;
}

sub limitsProbed { return $_limitsProbed }

sub probeEndpointLimits {
    my ($class, $accountId, $doneCb, %opts) = @_;
    return $doneCb->() if $_limitsProbed && !$opts{force};
    # Skip probe while rate-limited — probe calls would 429 and extend the window
    if ($cache->get('spoton_rate_limit') && !$opts{force}) {
        main::INFOLOG && $log->info("Client: limit probe deferred (rate-limited), keeping defaults");
        return $doneCb->();
    }
    # C1: clear blocked endpoints on forced re-probe so healed endpoints are re-discovered
    %_blockedEndpoints = () if $opts{force};
    $_limitsProbed = 0;

    my @classes = (
        { name => 'search',         path => 'search',    extra => { q => 'test', type => 'track' }, doc_max => 50 },
        { name => 'library',        path => 'me/tracks',  extra => {},                               doc_max => 50 },
        { name => 'artist_albums',  path => undef,        extra => {},                               doc_max => 50 },
        { name => 'album_tracks',   path => undef,        extra => {},                               doc_max => 50 },
        { name => 'playlist_items', path => undef,        extra => {},                               doc_max => 100 },
    );

    # Seed IDs for the classes that need a real object to probe against
    # (artist_albums, album_tracks, playlist_items) -- #118 root cause was
    # deriving these heuristically instead of hitting the real endpoint.
    my ($seedArtistId, $seedAlbumId, $seedPlaylistId);

    my $probeIdx = 0;
    my $probeNext;
    $probeNext = sub {
        if ($probeIdx >= scalar @classes) {
            $_limitsProbed = 1;
            $_limitsLastProbed = time();
            main::INFOLOG && $log->info(sprintf(
                "Client: API limits detected — search=%d library=%d artist_albums=%d album_tracks=%d playlist_items=%d",
                $_detectedLimits{search}, $_detectedLimits{library}, $_detectedLimits{artist_albums},
                $_detectedLimits{album_tracks}, $_detectedLimits{playlist_items}
            ));
            undef $probeNext;
            $doneCb->();
            return;
        }

        my $cls = $classes[$probeIdx++];

        # Resolve dynamic path from seed IDs collected from earlier classes.
        # If no seed is available (e.g. user has no playlists), skip this
        # probe entirely and keep the class' current default.
        unless ($cls->{path}) {
            my $seedId = $cls->{name} eq 'artist_albums'  ? $seedArtistId
                       : $cls->{name} eq 'album_tracks'   ? $seedAlbumId
                       : $cls->{name} eq 'playlist_items' ? $seedPlaylistId
                       :                                    undef;
            unless ($seedId) {
                main::INFOLOG && $log->info("Client: limit probe $cls->{name} skipped (no seed ID available), keeping default $_detectedLimits{$cls->{name}}");
                $probeNext->();
                return;
            }
            $cls->{path} = $cls->{name} eq 'artist_albums' ? "artists/$seedId/albums"
                         : $cls->{name} eq 'album_tracks'  ? "albums/$seedId/tracks"
                         :                                    "playlists/$seedId/items";
        }

        # After search/library complete (success, blocked, or skip), fetch the
        # seed IDs those two classes provide for the remaining classes, then
        # advance. Every other class advances straight to $probeNext.
        my $advance = sub {
            if ($cls->{name} eq 'search') {
                _fetchSearchSeed($accountId, sub {
                    ($seedArtistId, $seedAlbumId) = @_;
                    $probeNext->();
                });
                return;
            }
            if ($cls->{name} eq 'library') {
                _fetchPlaylistSeed($accountId, sub {
                    ($seedPlaylistId) = @_;
                    $probeNext->();
                });
                return;
            }
            $probeNext->();
        };

        _binarySearchLimit($accountId, $cls->{path}, $cls->{extra}, 1, $cls->{doc_max}, sub {
            my ($limit, $status) = @_;

            # Only a 401 (auth failure) aborts the ENTIRE remaining chain --
            # everything else (403 blocked, 429/timeout/network skip) isolates
            # to this class only and continues probing the rest.
            if ($status && $status eq 'auth_abort') {
                main::INFOLOG && $log->info("Client: limit probe aborted (401 unauthorized), keeping defaults for remaining classes");
                # C2: restore probed state so lazy re-probe remains functional
                $_limitsProbed = 1;
                undef $probeNext;
                $doneCb->();
                return;
            }

            if ($status && $status eq 'blocked') {
                $_blockedEndpoints{$cls->{name}} = 1;
                $log->warn("Client: limit probe $cls->{name} blocked (403) — endpoint unavailable for this Client ID, keeping default limit $_detectedLimits{$cls->{name}}");
                $advance->();
                return;
            }

            if ($status && $status eq 'skip') {
                main::INFOLOG && $log->info("Client: limit probe $cls->{name} skipped (transient error), keeping default $_detectedLimits{$cls->{name}}");
                $advance->();
                return;
            }

            $_detectedLimits{$cls->{name}} = $limit;
            main::INFOLOG && $log->info("Client: limit probe $cls->{name} = $limit");
            $advance->();
        });
    };

    $probeNext->();
}

# _classifyProbeError($code)
# Classifies a non-success HTTP status from a limit probe request into one of:
#   'retry'      - 400 (limit too high) -- binary search continues
#   'blocked'    - 403 -- endpoint unavailable for this Client ID, limit=0
#   'auth_abort' - 401 -- permanent auth failure, abort the entire probe chain
#   'skip'       - anything else (429, timeout, network, unknown) -- keep the
#                  class' current default and move to the next class
sub _classifyProbeError {
    my ($code) = @_;
    return 'retry'      if $code == 400;
    return 'blocked'    if $code == 403;
    return 'auth_abort' if $code == 401;
    return 'skip';
}

sub _binarySearchLimit {
    my ($accountId, $path, $extra, $low, $high, $doneCb) = @_;

    __PACKAGE__->_request('get', $path, {
        _accountId  => $accountId,
        _noCache    => 1,
        _probeCall  => 1,
        limit       => $high,
        %{ $extra || {} },
    }, sub {
        my ($result, $err) = @_;
        if ($result && !$err) {
            $doneCb->($high);
            return;
        }
        my $code = ($err && ref $err eq 'HASH') ? ($err->{code} || 0) : 0;
        my $kind = _classifyProbeError($code);
        if ($kind eq 'auth_abort') {
            $doneCb->(undef, 'auth_abort');
            return;
        }
        if ($kind eq 'blocked') {
            $doneCb->(0, 'blocked');
            return;
        }
        if ($kind eq 'skip') {
            $doneCb->($low, 'skip');
            return;
        }
        if ($high <= $low) {
            $doneCb->($low);
            return;
        }
        _doBinarySearch($accountId, $path, $extra, $low, $high, $doneCb);
    });
}

sub _doBinarySearch {
    my ($accountId, $path, $extra, $low, $high, $doneCb) = @_;

    if ($high - $low <= 1) {
        $doneCb->($low);
        return;
    }

    my $mid = int(($low + $high) / 2);

    __PACKAGE__->_request('get', $path, {
        _accountId  => $accountId,
        _noCache    => 1,
        _probeCall  => 1,
        limit       => $mid,
        %{ $extra || {} },
    }, sub {
        my ($result, $err) = @_;
        if ($result && !$err) {
            _doBinarySearch($accountId, $path, $extra, $mid, $high, $doneCb);
            return;
        }
        my $code = ($err && ref $err eq 'HASH') ? ($err->{code} || 0) : 0;
        my $kind = _classifyProbeError($code);
        if ($kind eq 'auth_abort') {
            $doneCb->(undef, 'auth_abort');
            return;
        }
        if ($kind eq 'blocked') {
            $doneCb->(0, 'blocked');
            return;
        }
        if ($kind eq 'skip') {
            $doneCb->($low, 'skip');
            return;
        }
        _doBinarySearch($accountId, $path, $extra, $low, $mid, $doneCb);
    });
}

# _fetchSearchSeed($accountId, $cb)
# Issues a real search request (limit=1) to obtain a live artist ID and album
# ID for seeding the artist_albums / album_tracks probe classes -- #118 root
# cause was deriving these heuristically instead of probing a real object.
# $cb->($artistId, $albumId) -- either may be undef if missing from the response
# (e.g. no search results, unexpected shape). Never dies.
sub _fetchSearchSeed {
    my ($accountId, $cb) = @_;
    __PACKAGE__->_request('get', 'search', {
        _accountId => $accountId,
        _noCache   => 1,
        _probeCall => 1,
        q          => 'test',
        type       => 'track',
        limit      => 1,
    }, sub {
        my ($result, $err) = @_;
        if ($err || !$result) {
            $cb->(undef, undef);
            return;
        }
        my $track     = eval { $result->{tracks}{items}[0] } || undef;
        my $artistId  = eval { $track->{artists}[0]{id} } || undef;
        my $albumId   = eval { $track->{album}{id} } || undef;
        $cb->($artistId, $albumId);
    });
}

# _fetchPlaylistSeed($accountId, $cb)
# Issues a real me/playlists request (limit=1) to obtain a live playlist ID
# for seeding the playlist_items probe class against a real playlist instead
# of deriving it heuristically. $cb->($playlistId) -- undef if the user has
# no playlists. Never dies.
sub _fetchPlaylistSeed {
    my ($accountId, $cb) = @_;
    __PACKAGE__->_request('get', 'me/playlists', {
        _accountId => $accountId,
        _noCache   => 1,
        _probeCall => 1,
        limit      => 1,
    }, sub {
        my ($result, $err) = @_;
        if ($err || !$result) {
            $cb->(undef);
            return;
        }
        my $playlistId = eval { $result->{items}[0]{id} } || undef;
        $cb->($playlistId);
    });
}

# statusSnapshot($class)
# Returns a hashref with current API telemetry for the Status Page.
sub statusSnapshot {
    my $class = shift;
    return {
        inflightCount   => $inflightCount,
        apiRequestCount => $apiRequestCount,
        api429Count     => $api429Count,
        rateLimited     => $cache->get('spoton_rate_limit') ? 1 : 0,
        wpRateLimited   => $cache->get(WP_RATE_LIMIT_KEY) ? 1 : 0,
        apiLimits         => { %_detectedLimits },
        blockedEndpoints  => { %_blockedEndpoints },
        limitsProbed      => $_limitsProbed,
        limitsLastProbed  => $_limitsLastProbed,
    };
}

# getMe($class, $accountId, $cb)
# Fetches the current user profile (/me).
# $cb->($result) on success; $cb->(undef, $err) on failure.
# Phase 2 implements only this endpoint (D-15). Browse/Search/Library come in Phase 3.
sub getMe {
    my ($class, $accountId, $cb) = @_;
    $class->_request('get', 'me', { _accountId => $accountId, _noCache => 1 }, $cb);
}

# ============================================================
# Browse / Search / Library API methods (Phase 3)
# ============================================================

# search($class, $accountId, $params, $cb)
# Searches Spotify. q is the search query; type defaults to "track,album,artist,playlist";
# limit capped at detected maximum (probed on startup, conservative default 10).
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    my $max = $_detectedLimits{search};
    my $limit = $params->{limit} // $max;
    $limit = $max if $limit > $max;
    $class->_request('get', 'search', {
        _accountId => $accountId,
        q          => $params->{q} // '',
        type       => $params->{type}   // 'track,album,artist,playlist',
        limit      => $limit,
        offset     => $params->{offset} // 0,
    }, $cb);
}

# getRecentlyPlayed($class, $accountId, $params, $cb)
# Fetches recently played tracks (/me/player/recently-played).
# Cursor-based — no offset parameter (Pitfall 4).
sub getRecentlyPlayed {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/player/recently-played', {
        _accountId => $accountId,
        _noCache   => 1,
        limit      => $params->{limit} // 50,
    }, $cb);
}

# getTopTracks($class, $accountId, $params, $cb)
# Fetches user's top tracks (/me/top/tracks).
# time_range defaults to "medium_term" (D-05).
sub getTopTracks {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/top/tracks', {
        _accountId => $accountId,
        time_range => $params->{time_range} // 'medium_term',
        limit      => $params->{limit}      // 50,
    }, $cb);
}

# getSavedTracks($class, $accountId, $params, $cb)
# Fetches user's saved (liked) tracks (/me/tracks).
# Offset-paginated; max limit 50.
sub getSavedTracks {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/tracks', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getSavedAlbums($class, $accountId, $params, $cb)
# Fetches user's saved albums (/me/albums).
# Offset-paginated; max limit 50.
sub getSavedAlbums {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/albums', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getFollowedArtists($class, $accountId, $params, $cb)
# Fetches followed artists (/me/following?type=artist).
# Cursor-based (no offset); type=artist is hardcoded (Pitfall 2 — requires user-follow-read scope).
sub getFollowedArtists {
    my ($class, $accountId, $params, $cb) = @_;
    my %reqParams = (
        _accountId => $accountId,
        type       => 'artist',
        limit      => $params->{limit} // 50,
    );
    $reqParams{after} = $params->{after} if defined $params->{after};
    $class->_request('get', 'me/following', \%reqParams, $cb);
}

# getSavedShows($class, $accountId, $params, $cb)
# Fetches user's saved shows (/me/shows). Offset-paginated; max limit 50.
# Scope: user-library-read. Token-routing: me/* hard guard -> own.
sub getSavedShows {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/shows', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
        ($params->{_noCache} ? (_noCache => 1) : ()),
    }, $cb);
}

# saveTracks($class, $accountId, $uris, $cb)
# Saves tracks to the user's library (PUT /me/library?uris=...).
# D-12: Uses unified library endpoint with full Spotify URIs (e.g. spotify:track:ID).
# Response: 200 OK with empty body — handled by empty-body guard in _doRequest.
# Scope: user-library-modify
sub saveTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('put', 'me/library', {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

# removeTracks($class, $accountId, $uris, $cb)
# Removes tracks from the user's library (DELETE /me/library?uris=...).
# D-13: Uses unified library endpoint with full Spotify URIs.
# Response: 200 OK with empty body — handled by empty-body guard in _doRequest.
# Scope: user-library-modify
sub removeTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('delete', 'me/library', {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

# checkTracks($class, $accountId, $uris, $cb)
# Checks if tracks are saved in the user's library (GET /me/library/contains?uris=...).
# D-14: Response is an array of booleans, e.g. [true] or [false].
# _noCache => 1: caching is managed manually in Plugin.pm with 60s TTL (D-07, Pitfall 2).
# Scope: user-library-read
sub checkTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('get', 'me/library/contains', {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

sub _extractShowIds {
    return join(',', map { /^spotify:show:(.+)$/ ? $1 : $_ } @{$_[0] || []});
}

# saveShows($class, $accountId, $uris, $cb)
# Saves shows to the user's library (PUT /me/shows?ids=...).
# Uses old-style endpoint consistent with GET /me/shows listing.
# The unified PUT /me/library saves to a different store that GET /me/shows does not read.
# Response: 200 OK with empty body — handled by empty-body guard in _doRequest.
# Scope: user-library-modify
sub saveShows {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('put', 'me/shows', {
        _accountId => $accountId,
        _noCache   => 1,
        ids        => _extractShowIds($uris),
    }, $cb);
}

# removeShows($class, $accountId, $uris, $cb)
# Removes shows from the user's library (DELETE /me/shows?ids=...).
# Uses old-style endpoint consistent with GET /me/shows listing.
# Response: 200 OK with empty body — handled by empty-body guard in _doRequest.
# Scope: user-library-modify
sub removeShows {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('delete', 'me/shows', {
        _accountId => $accountId,
        _noCache   => 1,
        ids        => _extractShowIds($uris),
    }, $cb);
}

# checkShows($class, $accountId, $uris, $cb)
# Checks if shows are saved in the user's library (GET /me/shows/contains?ids=...).
# Uses old-style endpoint consistent with GET /me/shows listing.
# Response is an array of booleans, e.g. [true] or [false].
# _noCache => 1: caching is managed manually in Plugin.pm with 60s TTL (D-07, Pitfall 2).
# Scope: user-library-read
sub checkShows {
    my ($class, $accountId, $uris, $cb) = @_;
    $class->_request('get', 'me/shows/contains', {
        _accountId => $accountId,
        _noCache   => 1,
        ids        => _extractShowIds($uris),
    }, $cb);
}

# getUserPlaylists($class, $accountId, $params, $cb)
# Fetches user's playlists (/me/playlists).
# Offset-paginated; max limit 50.
sub getUserPlaylists {
    my ($class, $accountId, $params, $cb) = @_;
    $class->_request('get', 'me/playlists', {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# addToPlaylist($class, $accountId, $playlistId, $uris, $cb)
# Adds items to a playlist (POST /playlists/{playlistId}/items?uris=...).
# $uris: arrayref of full Spotify URIs (spotify:track:ID or spotify:episode:ID).
# Response: {"snapshot_id": "..."} — parsed normally.
# Scope: playlist-modify-public, playlist-modify-private
sub addToPlaylist {
    my ($class, $accountId, $playlistId, $uris, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $playlistId && $playlistId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('post', "playlists/$playlistId/items", {
        _accountId => $accountId,
        _noCache   => 1,
        uris       => join(',', @{$uris || []}),
    }, $cb);
}

# getPersonalMixes($class, $accountId, $params, $cb)
# Fetches Spotify personal mix playlists via the browse/categories endpoint (D-05).
# Source: Spotty API.pm categoryPlaylists pattern.
# Response structure: {playlists: {items: [...]}} — NOT {items: [...]}.
# Cache TTL: 300s (browse/ path — see _cacheTTL line 396).
sub getPersonalMixes {
    my ($class, $accountId, $params, $cb) = @_;
    my %reqParams = (
        _accountId => $accountId,
        limit      => $params->{limit} // 50,
    );
    $reqParams{offset}  = $params->{offset}  if $params->{offset};
    $reqParams{_locale}  = $params->{_locale}  if $params->{_locale};
    $class->_request('get',
        'browse/categories/' . PERSONAL_MIX_CATEGORY . '/playlists',
        \%reqParams,
        $cb
    );
}

# getArtist($class, $accountId, $artistId, $cb)
# Fetches a single artist by ID (/artists/{artistId}).
sub getArtist {
    my ($class, $accountId, $artistId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $artistId && $artistId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "artists/$artistId", { _accountId => $accountId }, $cb);
}

# getArtistAlbums($class, $accountId, $artistId, $params, $cb)
# Fetches albums for an artist (/artists/{artistId}/albums).
# Per D-09: include_groups takes a SINGLE value per call (album|single|compilation|appears_on).
# Combined values break pagination — callers issue separate requests per type.
sub getArtistAlbums {
    my ($class, $accountId, $artistId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $artistId && $artistId =~ /^[A-Za-z0-9]{1,40}$/;
    # Defense-in-depth clamp to the detected artist_albums limit (#118: this
    # namespace is capped differently from library and must not reuse it).
    my $max = $_detectedLimits{artist_albums};
    my $limit = $params->{limit} // $max;
    $limit = $max if $limit > $max;
    my %reqParams = (
        _accountId     => $accountId,
        offset         => $params->{offset} // 0,
        limit          => $limit,
    );
    $reqParams{include_groups} = $params->{include_groups}
        if defined $params->{include_groups};
    $class->_request('get', "artists/$artistId/albums", \%reqParams, $cb);
}

# getAlbum($class, $accountId, $albumId, $cb)
# Fetches album metadata including first page of tracks (/albums/{albumId}).
sub getAlbum {
    my ($class, $accountId, $albumId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $albumId && $albumId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "albums/$albumId", { _accountId => $accountId }, $cb);
}

# getAlbumTracks($class, $accountId, $albumId, $params, $cb)
# Fetches paginated track list for an album (/albums/{albumId}/tracks).
# Offset-paginated; max limit 50.
sub getAlbumTracks {
    my ($class, $accountId, $albumId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $albumId && $albumId =~ /^[A-Za-z0-9]{1,40}$/;
    # Defense-in-depth clamp to the detected album_tracks limit.
    my $max = $_detectedLimits{album_tracks};
    my $limit = $params->{limit} // $max;
    $limit = $max if $limit > $max;
    $class->_request('get', "albums/$albumId/tracks", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $limit,
    }, $cb);
}

# getShow($class, $accountId, $showId, $cb)
# Fetches show metadata (/shows/{id}). Scope: user-read-playback-position.
sub getShow {
    my ($class, $accountId, $showId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $showId && $showId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "shows/$showId", { _accountId => $accountId }, $cb);
}

# getShowEpisodes($class, $accountId, $showId, $params, $cb)
# Fetches paginated episode list for a show (/shows/{id}/episodes).
# Offset-paginated; max limit 50. Cache TTL: 60s (D-01).
sub getShowEpisodes {
    my ($class, $accountId, $showId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $showId && $showId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "shows/$showId/episodes", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 50,
    }, $cb);
}

# getEpisode($class, $accountId, $episodeId, $cb)
# Fetches a single episode by ID (/episodes/{id}). Scope: user-read-playback-position.
sub getEpisode {
    my ($class, $accountId, $episodeId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $episodeId && $episodeId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "episodes/$episodeId", { _accountId => $accountId }, $cb);
}

# getPlaylistItems($class, $accountId, $playlistId, $params, $cb)
# Fetches paginated items for a playlist (/playlists/{playlistId}/items).
# Uses /items path — NOT /tracks (Pitfall 3: Feb 2026 rename).
# Offset-paginated; max limit 100.
sub getPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $playlistId && $playlistId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "playlists/$playlistId/items", {
        _accountId => $accountId,
        offset     => $params->{offset} // 0,
        limit      => $params->{limit}  // 100,
    }, $cb);
}

# ============================================================
# Web-Player-scoped methods (Phase 52, D-07) -- Pathfinder discovery +
# 37i9... playlist access. Route through WebPlayer->getToken, NEVER
# TokenManager->getToken, and isolate rate-limit state under
# WP_RATE_LIMIT_KEY (Pitfall 5, T-52-04). Dev-Mode PKCE tokens 404 on ALL
# Spotify-owned (37i9...) playlists regardless of ID validity (Pitfall 3).
# ============================================================

# pathfinderHome($class, $accountId, $params, $cb)
# Discovers algorithmic ("Made for You") playlist IDs -- Daily Mix, Discover
# Weekly, Release Radar, Daylist, genre mixes -- via the Pathfinder "home"
# GraphQL query (POST api-partner.spotify.com/pathfinder/v2/query). Uses
# ONLY the Web-Player token from WebPlayer->getToken (D-07).
# $cb->(\@ids, undef) on success (possibly an empty arrayref).
# $cb->(undef, { error => $reason }) on hard failure: no_spdc / no_secrets /
# expired / mint_failed (propagated from WebPlayer->getToken), or an HTTP/
# rate_limited/parse error from this request itself.
# A PersistedQueryNotFound / top-level errors[] response is NOT a hard
# failure -- it degrades to $cb->([], undef) with a distinct log line
# (Pitfall 4) so Browse is never affected by GraphQL hash rotation.
sub pathfinderHome {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};

    # Isolated Web-Player rate pool (Pitfall 5, T-52-04) -- never the shared
    # 'spoton_rate_limit' key checked by _request().
    if ($cache->get(WP_RATE_LIMIT_KEY)) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    require Plugins::SpotOn::API::WebPlayer;
    Plugins::SpotOn::API::WebPlayer->getToken($accountId, sub {
        my ($tokenHash, $reason) = @_;
        unless ($tokenHash && $tokenHash->{access_token}) {
            main::INFOLOG && $log->info('Client: pathfinderHome no Web-Player token (reason='
                . ($reason || 'unknown') . ')');
            $cb->(undef, { error => $reason || 'no_token' });
            return;
        }

        # GraphQL persisted-query hash is refreshable config (Pitfall 4):
        # read from prefs first (persistent, survives cache clears and
        # restarts; admin-configurable via Settings -- Plan 52-06 / CR-01
        # fix), falling back to the shipped placeholder default.
        my $prefHash = $prefs->get('pathfinderHash');
        my $hash = (defined $prefHash && length $prefHash) ? $prefHash : PATHFINDER_HOME_HASH_DEFAULT;

        my $body = eval { to_json({
            operationName => 'home',
            variables     => {
                homeEndUserIntegration       => 'INTEGRATION_WEB_PLAYER',
                timeZone                     => $params->{timeZone} || 'Europe/Berlin',
                sp_t                         => '',
                facet                        => '',
                sectionItemsLimit            => 10,
                includeEpisodeContentRatingsV2 => JSON::XS::true(),
            },
            extensions => {
                persistedQuery => {
                    version    => 1,
                    sha256Hash => $hash,
                },
            },
        }) };
        unless (defined $body) {
            $log->error("Client: pathfinderHome request body build failed: $@");
            $cb->(undef, { error => 'internal_error' });
            return;
        }

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http    = shift;
                my $content = $http->content // '';
                my $result  = eval { from_json($content) };
                if ($@ || ref($result) ne 'HASH') {
                    $log->error("Client: pathfinderHome JSON parse error: $@");
                    $cb->(undef, { error => 'parse_error' });
                    return;
                }

                my ($playlists, $degraded) = $class->_extractPathfinderIds($result);
                if ($degraded) {
                    main::INFOLOG && $log->info('Client: pathfinderHome degraded -- '
                        . 'errors[] in response (persisted-query hash rotation? Pitfall 4)');
                }

                $cb->($playlists, undef);
            },
            sub {
                # Error callback -- 429 (isolated WP pool), 401, generic
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;

                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 1   if $retryAfter < 1;
                    $retryAfter = 300 if $retryAfter > 300;

                    # Isolated Web-Player rate-limit key -- MUST NOT be
                    # 'spoton_rate_limit' (Pitfall 5, T-52-04).
                    $cache->set(WP_RATE_LIMIT_KEY, 1, $retryAfter);
                    $api429Count++;
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('warn', 'API', '429 on pathfinder/v2/query');
                    }
                    $log->warn("Client: pathfinderHome 429 rate limited for ${retryAfter}s (Web-Player pool)");
                    $cb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                if ($code == 401) {
                    $cache->remove("spoton_wp_token_${accountId}") if $accountId;
                    $log->warn('Client: pathfinderHome 401 unauthorized (Web-Player token invalidated)');
                    $cb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                # T-52-08: never log Authorization/client-token header values
                $log->error("Client: pathfinderHome HTTP $code error: $error");
                if ($INC{'Plugins/SpotOn/Status.pm'}) {
                    Plugins::SpotOn::Status->recordError('error', 'API', "HTTP $code for pathfinder/v2/query");
                }
                $cb->(undef, { error => $error, code => $code });
            },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        );

        $apiRequestCount++;
        $http->post(
            PATHFINDER_URL,
            'Authorization'        => "Bearer $tokenHash->{access_token}",
            'client-token'         => ($tokenHash->{client_token} // ''),
            'Content-Type'         => 'application/json;charset=UTF-8',
            'Accept'               => 'application/json',
            'App-Platform'         => 'WebPlayer',
            'Origin'               => 'https://open.spotify.com',
            'Referer'              => 'https://open.spotify.com/',
            'spotify-app-version'  => Plugins::SpotOn::API::WebPlayer::CLIENT_VERSION(),
            $body,
        );
    });
}

# _extractPathfinderIds($class, $result)
# Defensive multi-level parse of a Pathfinder "home" GraphQL response body.
# Walks data.home.sectionContainer.sections.items[] ->
# sectionItems.items[] -> playlist URIs, keeps only spotify:playlist:37i9...,
# and extracts name + images from content.data (PlaylistResponseWrapper).
# Returns ($playlistsArrayRef, $degraded) -- each entry is a hashref
# {id, name, images} ready for _playlistItem. $degraded is true when the
# response carries a top-level errors[] array (Pitfall 4).
sub _extractPathfinderIds {
    my ($class, $result) = @_;
    my @playlists;

    return (\@playlists, 0) unless $result && ref($result) eq 'HASH';

    if (ref($result->{errors}) eq 'ARRAY' && @{$result->{errors}}) {
        return (\@playlists, 1);
    }

    my $home = ($result->{data} && ref($result->{data}) eq 'HASH')
        ? $result->{data}->{home} : undef;
    return (\@playlists, 0) unless $home && ref($home) eq 'HASH';

    my $sectionContainer = $home->{sectionContainer};
    return (\@playlists, 0) unless $sectionContainer && ref($sectionContainer) eq 'HASH';

    my $sections = $sectionContainer->{sections};
    return (\@playlists, 0) unless $sections && ref($sections) eq 'HASH';

    my $sectionList = $sections->{items};
    return (\@playlists, 0) unless ref($sectionList) eq 'ARRAY';

    my %seen;
    for my $section (@$sectionList) {
        next unless $section && ref($section) eq 'HASH';
        my $itemsWrapper = $section->{sectionItems};
        next unless $itemsWrapper && ref($itemsWrapper) eq 'HASH';
        my $items = $itemsWrapper->{items};
        next unless ref($items) eq 'ARRAY';

        for my $item (@$items) {
            next unless $item && ref($item) eq 'HASH';
            my $uri = _pathfinderItemUri($item);
            next unless defined $uri && !ref($uri);
            next unless $uri =~ /^spotify:playlist:(37i9[A-Za-z0-9]*)$/;
            my $id = $1;
            next unless $id =~ /^[A-Za-z0-9]{1,40}$/;
            next if $seen{$id}++;

            my $name   = $id;
            my $images = [];
            my $contentData = ($item->{content} && ref($item->{content}) eq 'HASH')
                ? $item->{content}{data} : undef;
            if ($contentData && ref($contentData) eq 'HASH') {
                $name = $contentData->{name} if defined $contentData->{name}
                    && !ref($contentData->{name}) && length($contentData->{name});
                $images = _pathfinderImagesToRest($contentData->{images});
            }

            push @playlists, { id => $id, name => $name, images => $images };
        }
    }

    return (\@playlists, 0);
}

# _pathfinderItemUri($item)
# A1 (MEDIUM confidence): the exact nesting of the playlist URI within a
# sectionItems entry is unverified against a live response. Checks the most
# plausible shapes defensively; returns undef (never dies) on anything
# unexpected.
sub _pathfinderItemUri {
    my ($item) = @_;
    return $item->{uri} if defined $item->{uri} && !ref($item->{uri});
    for my $key (qw(content data)) {
        my $nested = $item->{$key};
        next unless $nested && ref($nested) eq 'HASH';
        return $nested->{uri} if defined $nested->{uri} && !ref($nested->{uri});
    }
    return undef;
}

sub _pathfinderCoverArtToImages {
    my ($coverArt) = @_;
    return [] unless $coverArt && ref($coverArt) eq 'HASH';
    my $sources = $coverArt->{sources};
    return [] unless ref($sources) eq 'ARRAY';
    my @images;
    for my $s (@$sources) {
        next unless $s && ref($s) eq 'HASH' && $s->{url};
        push @images, { url => $s->{url}, width => $s->{width}, height => $s->{height} };
    }
    return \@images;
}

sub _pathfinderImagesToRest {
    my ($images) = @_;
    return [] unless $images && ref($images) eq 'HASH';
    my $imageItems = $images->{items};
    return [] unless ref($imageItems) eq 'ARRAY';
    my @result;
    for my $item (@$imageItems) {
        next unless $item && ref($item) eq 'HASH';
        my $sources = $item->{sources};
        next unless ref($sources) eq 'ARRAY';
        for my $s (@$sources) {
            next unless $s && ref($s) eq 'HASH' && $s->{url};
            push @result, { url => $s->{url}, width => $s->{width}, height => $s->{height} };
        }
    }
    return \@result;
}

sub _transformPlaylistContents {
    my ($class, $result) = @_;

    my $playlist = ($result->{data} && ref($result->{data}) eq 'HASH')
        ? $result->{data}{playlistV2} : undef;
    return undef unless $playlist && ref($playlist) eq 'HASH';

    my $content = $playlist->{content};
    return undef unless $content && ref($content) eq 'HASH';

    my $totalCount = $content->{totalCount} // 0;
    my $rawItems   = $content->{items};
    return { items => [], total => $totalCount } unless ref($rawItems) eq 'ARRAY';

    my @items;
    for my $entry (@$rawItems) {
        next unless $entry && ref($entry) eq 'HASH';
        my $itemV2 = $entry->{itemV2};
        next unless $itemV2 && ref($itemV2) eq 'HASH';
        my $trackData = $itemV2->{data};
        next unless $trackData && ref($trackData) eq 'HASH';

        my $uri = $trackData->{uri} // '';
        unless ($uri =~ /^spotify:track:([A-Za-z0-9]+)$/) {
            push @items, { track => undef };
            next;
        }
        my $trackId = $1;

        my @artists;
        if ($trackData->{artists} && ref($trackData->{artists}) eq 'HASH') {
            my $artistItems = $trackData->{artists}{items};
            if (ref($artistItems) eq 'ARRAY') {
                for my $a (@$artistItems) {
                    next unless $a && ref($a) eq 'HASH';
                    my $aUri = $a->{uri} // '';
                    my $aId  = ($aUri =~ /^spotify:artist:([A-Za-z0-9]+)$/) ? $1 : '';
                    my $name = ($a->{profile} && ref($a->{profile}) eq 'HASH')
                        ? ($a->{profile}{name} // '') : '';
                    push @artists, { name => $name, id => $aId, uri => $aUri };
                }
            }
        }

        my %album;
        my $albumData = $trackData->{albumOfTrack};
        if ($albumData && ref($albumData) eq 'HASH') {
            my $albumUri = $albumData->{uri} // '';
            my $albumId  = ($albumUri =~ /^spotify:album:([A-Za-z0-9]+)$/) ? $1 : '';
            %album = (
                name   => $albumData->{name} // '',
                id     => $albumId,
                uri    => $albumUri,
                images => _pathfinderCoverArtToImages($albumData->{coverArt}),
            );
        }

        my $durationMs = 0;
        if ($trackData->{trackDuration} && ref($trackData->{trackDuration}) eq 'HASH') {
            $durationMs = $trackData->{trackDuration}{totalMilliseconds} // 0;
        }

        push @items, {
            track => {
                id          => $trackId,
                name        => $trackData->{name} // '',
                uri         => $uri,
                artists     => \@artists,
                album       => \%album,
                duration_ms => $durationMs + 0,
            },
        };
    }

    return { items => \@items, total => $totalCount };
}

# getWebPlayerPlaylistItems($class, $accountId, $playlistId, $params, $cb)
# Fetches paginated items for a Spotify-owned (37i9...) playlist via
# Pathfinder GraphQL (fetchPlaylistContents) using the Web-Player bearer
# token (D-07, Pitfall 3). Transforms the GraphQL response to the same
# REST-compatible {items => [{track => ...}], total => N} shape so
# _playlistFeed/_fetchAllPages work unchanged.
sub getWebPlayerPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    $params ||= {};

    return $cb->(undef, { error => 'invalid_id' })
        unless $playlistId && $playlistId =~ /^[A-Za-z0-9]{1,40}$/;

    if ($cache->get(WP_RATE_LIMIT_KEY)) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    require Plugins::SpotOn::API::WebPlayer;
    Plugins::SpotOn::API::WebPlayer->getToken($accountId, sub {
        my ($tokenHash, $reason) = @_;
        unless ($tokenHash && $tokenHash->{access_token}) {
            main::INFOLOG && $log->info('Client: getWebPlayerPlaylistItems no Web-Player token (reason='
                . ($reason || 'unknown') . ')');
            $cb->(undef, { error => $reason || 'no_token' });
            return;
        }

        my $offset = $params->{offset} // 0;
        my $limit  = $params->{limit}  // 100;

        my $body = eval { to_json({
            operationName => 'fetchPlaylistContents',
            variables     => {
                uri    => "spotify:playlist:$playlistId",
                offset => $offset + 0,
                limit  => $limit + 0,
            },
            extensions => {
                persistedQuery => {
                    version    => 1,
                    sha256Hash => PATHFINDER_PLAYLIST_HASH,
                },
            },
        }) };
        unless (defined $body) {
            $log->error("Client: getWebPlayerPlaylistItems request body build failed: $@");
            $cb->(undef, { error => 'internal_error' });
            return;
        }

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http    = shift;
                my $content = $http->content // '';
                my $result  = eval { from_json($content) };
                if ($@ || ref($result) ne 'HASH') {
                    $log->error("Client: getWebPlayerPlaylistItems JSON parse error: $@");
                    $cb->(undef, { error => 'parse_error' });
                    return;
                }

                if (ref($result->{errors}) eq 'ARRAY' && @{$result->{errors}}) {
                    $log->warn('Client: getWebPlayerPlaylistItems GraphQL errors in response');
                    $cb->(undef, { error => 'graphql_error' });
                    return;
                }

                my $transformed = $class->_transformPlaylistContents($result);
                $cb->($transformed);
            },
            sub {
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;

                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 1   if $retryAfter < 1;
                    $retryAfter = 300 if $retryAfter > 300;

                    $cache->set(WP_RATE_LIMIT_KEY, 1, $retryAfter);
                    $api429Count++;
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('warn', 'API', '429 on pathfinder fetchPlaylistContents');
                    }
                    $log->warn("Client: getWebPlayerPlaylistItems 429 rate limited for ${retryAfter}s (Web-Player pool)");
                    $cb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                if ($code == 401) {
                    $cache->remove("spoton_wp_token_${accountId}") if $accountId;
                    $log->warn('Client: getWebPlayerPlaylistItems 401 unauthorized (Web-Player token invalidated)');
                    $cb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                $log->error("Client: getWebPlayerPlaylistItems HTTP $code error: $error");
                if ($INC{'Plugins/SpotOn/Status.pm'}) {
                    Plugins::SpotOn::Status->recordError('error', 'API', "HTTP $code for pathfinder fetchPlaylistContents");
                }
                $cb->(undef, { error => $error, code => $code });
            },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        );

        $apiRequestCount++;
        $http->post(
            PATHFINDER_URL,
            'Authorization'        => "Bearer $tokenHash->{access_token}",
            'client-token'         => ($tokenHash->{client_token} // ''),
            'Content-Type'         => 'application/json;charset=UTF-8',
            'Accept'               => 'application/json',
            'App-Platform'         => 'WebPlayer',
            'Origin'               => 'https://open.spotify.com',
            'Referer'              => 'https://open.spotify.com/',
            'spotify-app-version'  => Plugins::SpotOn::API::WebPlayer::CLIENT_VERSION(),
            $body,
        );
    });
}

# getTrack($class, $accountId, $trackId, $cb)
# Fetches a single track by ID (/tracks/{trackId}).
# Used by Connect.pm for metadata fetch after start/change events (D-13).
# Track endpoint is available in dev mode (batch GET /tracks removed, but GET /tracks/{id} works).
sub getTrack {
    my ($class, $accountId, $trackId, $cb) = @_;
    return $cb->(undef, { error => 'invalid_id' })
        unless $trackId && $trackId =~ /^[A-Za-z0-9]{1,40}$/;
    $class->_request('get', "tracks/$trackId", { _accountId => $accountId }, $cb);
}

# ============================================================
# Player Control API methods (D-15 Web API fallback for Connect)
# ============================================================
# These are used as fallback when binary HTTP control endpoints are unreachable.
# Primary control path is POST /control/* on the binary (D-14).

# playerPause($class, $accountId, $cb)
# Pauses playback on the active device (PUT /me/player/pause).
sub playerPause {
    my ($class, $accountId, $cb) = @_;
    $class->_request('put', 'me/player/pause', {
        _accountId => $accountId,
        _noCache   => 1,
    }, $cb);
}

# playerPlay($class, $accountId, $cb)
# Resumes playback on the active device (PUT /me/player/play).
sub playerPlay {
    my ($class, $accountId, $cb) = @_;
    $class->_request('put', 'me/player/play', {
        _accountId => $accountId,
        _noCache   => 1,
    }, $cb);
}

# playerVolume($class, $accountId, $volumePct, $cb)
# Sets volume on the active device (PUT /me/player/volume?volume_percent=N).
sub playerVolume {
    my ($class, $accountId, $volumePct, $cb) = @_;
    $class->_request('put', 'me/player/volume', {
        _accountId      => $accountId,
        _noCache        => 1,
        volume_percent  => int($volumePct),
    }, $cb);
}

# playerSeek($class, $accountId, $positionMs, $cb)
# Seeks to position in current track (PUT /me/player/seek?position_ms=N).
sub playerSeek {
    my ($class, $accountId, $positionMs, $cb) = @_;
    $class->_request('put', 'me/player/seek', {
        _accountId  => $accountId,
        _noCache    => 1,
        position_ms => int($positionMs),
    }, $cb);
}

# ============================================================
# Core request pipeline
# ============================================================

# _request($class, $method, $path, $params, $cb)
# Central HTTP egress point. All Spotify API calls go through here (API-01).
#
# Request pipeline (D-04: single PKCE token per account, no flavor routing):
#   1. Strip leading slash from path
#   2. Rate-limit check (single key, no flavor suffix)
#   3. Response cache check (unless _noCache) (API-03)
#   4. Concurrency cap (API-02) — defer via timer
#   5. Increment inflight counter; wrap $cb in double-callback guard
#   6. Dispatch to _doRequest
sub _request {
    my ($class, $method, $path, $params, $cb) = @_;

    # Step 1: Strip leading slash
    my $cleanPath = $path;
    $cleanPath =~ s{^/}{};

    # Step 2: Rate-limit check — single key, no flavor suffix (D-04).
    if ($cache->get('spoton_rate_limit')) {
        $cb->(undef, { error => 'rate_limited', code => 429 });
        return;
    }

    # Step 3: Concurrency cap (API-02, Pitfall 6).
    if ($inflightCount >= MAX_CONCURRENT_REQUESTS) {
        Slim::Utils::Timers::setTimer(
            undef,
            Time::HiRes::time() + 0.1,
            sub { $class->_request($method, $cleanPath, $params, $cb) }
        );
        return;
    }

    # Step 4: Increment inflight counter and wrap $cb in double-callback guard.
    # $inflightCount is decremented exactly once per request by $userCb.
    $inflightCount++;
    $apiRequestCount++;
    my $userCbCalled = 0;
    my $userCb = sub {
        return if $userCbCalled++;
        $inflightCount--;
        $cb->(@_);
    };

    # Step 5: Dispatch to request handler.
    # H1: eval-guarded — any die after $inflightCount++ must exit through $userCb
    # (the single decrement point with double-call guard), or the counter leaks
    # until MAX_CONCURRENT_REQUESTS is reached and all API traffic deadlocks.
    eval {
        $class->_doRequest($method, $cleanPath, $params, $userCb);
        1;
    } or do {
        $log->error("Client: dispatch failed for $cleanPath: $@");
        $userCb->(undef, { error => 'internal_error' });
    };
}

# _doRequest($class, $method, $cleanPath, $params, $userCb)
# Executes a single PKCE-token-authenticated HTTP request: builds the request URL
# and cache key, checks the response cache, fetches/refreshes the account's PKCE
# token, issues the HTTP call, normalizes the response/error, and invokes $userCb.
# Source: Spotty-NG API.pm:1595-1703 adapted (flavor/bundled-retry dispatch removed
# by Phase 50 D-04 — single PKCE token per account, no fallback recursion).
sub _doRequest {
    my ($class, $method, $cleanPath, $params, $userCb) = @_;

    my $accountId = $params->{_accountId};

    # M1/H1c: Build URL, query string, and cache key BEFORE any token fetch.
    # A cache hit must never trigger a token fetch.
    # eval-guarded: uri_escape_utf8 or interpolation dies must exit via $userCb.
    # CR-01: Include accountId to prevent multi-account cache contamination.
    my ($url, $queryStr);
    my $built = eval {
        $url = API_BASE . "/$cleanPath";
        my @queryParts;
        for my $key (sort keys %{$params}) {
            next if $key =~ /^_/;
            push @queryParts, "$key=" . uri_escape_utf8($params->{$key});
        }
        $queryStr = join('&', @queryParts);
        if ($queryStr) {
            $url .= '?' . $queryStr;
        }
        1;
    };
    unless ($built) {
        $log->error("Client: request build failed for $cleanPath: $@");
        $userCb->(undef, { error => 'internal_error' });
        return;
    }

    unless ($params->{_noCache}) {
        my $cacheKey = $queryStr
            ? "spoton_resp_${accountId}_${cleanPath}?${queryStr}"
            : "spoton_resp_${accountId}_${cleanPath}";
        $cacheKey .= "_locale=$params->{_locale}" if $params->{_locale};
        $params->{_cacheKey} = $cacheKey;
        if (my $cached = $cache->get($cacheKey)) {
            main::INFOLOG && $log->info("Client: cache hit for $cleanPath (no token fetch needed)");
            $userCb->($cached);
            return;
        }
    }

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->getToken($accountId, sub {
        my $token = shift;

        unless ($token) {
            main::INFOLOG && $log->info("Client: no token available for account $accountId");
            $userCb->(undef, { error => 'no_token' });
            return;
        }

        # T-02-10: Never log Authorization header value — only URL path and method
        main::INFOLOG && $log->info("Client: $method $cleanPath");

        my $reqStartTime = Time::HiRes::time();
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                # Success callback — parse JSON and cache
                my $http = shift;
                my $reqDuration = Time::HiRes::time() - $reqStartTime;
                if ($reqDuration > 2 && $prefs->get('diagnosticMode')) {
                    $log->warn(sprintf("[DIAG] api_slow: endpoint=%s duration=%.1fs", $cleanPath, $reqDuration));
                }
                my $content = $http->content // '';

                # Pitfall 6: PUT/DELETE /me/library returns 200 OK with empty body.
                # from_json('') throws an exception — treat empty/whitespace body as
                # success with undef result (not a parse error). Contract: $err is undef.
                my $result;
                if ($content =~ /\S/) {
                    $result = eval { from_json($content) };
                    if ($@) {
                        $log->error("Client: JSON parse error for $cleanPath: $@");
                        if ($INC{'Plugins/SpotOn/Status.pm'}) {
                            Plugins::SpotOn::Status->recordError('error', 'API', "JSON parse error for $cleanPath");
                        }
                        $userCb->(undef, { error => 'parse_error' });
                        return;
                    }
                }

                # Cache response with domain-specific TTL (API-03).
                unless ($params->{_noCache}) {
                    my $ttl = $class->_cacheTTL($cleanPath);
                    if ($ttl > 0) {
                        my $cacheKey = $params->{_cacheKey} || "spoton_resp_$cleanPath";
                        $cache->set($cacheKey, $result, $ttl);
                        main::INFOLOG && $log->info("Client: cached $cleanPath for ${ttl}s");
                    }
                }

                $userCb->($result);
            },
            sub {
                # Error callback — handle 429, 401, and generic errors
                my ($http, $error, $response) = @_;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;
                if (!$code && $error && $error =~ /^(\d{3})\b/) {
                    $code = $1;
                }

                if ($code == 429) {
                    my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                    if ($response && ref $response && $response->can('header')) {
                        my $headerVal = $response->header('Retry-After');
                        # T-02-08: Cap Retry-After at 300s to prevent self-DoS
                        $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                    }
                    $retryAfter = 1   if $retryAfter < 1;
                    $retryAfter = 300 if $retryAfter > 300;

                    # Single rate-limit key — no flavor suffix (D-04).
                    $cache->set('spoton_rate_limit', 1, $retryAfter);
                    $api429Count++;
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('warn', 'API', "429 on $cleanPath");
                    }
                    $log->warn("Client: 429 rate limited for ${retryAfter}s on $cleanPath");
                    $log->warn("[DIAG] api_429: endpoint=$cleanPath retry_after=${retryAfter}s") if $prefs->get('diagnosticMode');
                    $userCb->(undef, { error => 'rate_limited', code => 429 });
                    return;
                }

                # 401: Invalidate the account's token cache
                if ($code == 401) {
                    $cache->remove("spoton_token_${accountId}") if $accountId;
                    $log->warn("Client: 401 unauthorized for $cleanPath (token invalidated)");
                    $log->warn("[DIAG] api_401: endpoint=$cleanPath account=" . substr($accountId || '', 0, 4) . "****") if $prefs->get('diagnosticMode');
                    $userCb->(undef, { error => 'unauthorized', code => 401 });
                    return;
                }

                # T-02-10: Log only status code and path, never token value
                my $detail = '';
                if ($code == 400 && $response && ref $response && $response->can('content')) {
                    my $body = eval { from_json($response->content) };
                    $detail = $body->{error}{message} // '' if $body && $body->{error};
                }

                # Lazy re-probe: a limit-related 400 on a non-probe request may
                # indicate server-side limit changes. Trigger re-probe if cooldown expired.
                if ($code == 400 && !$params->{_probeCall}
                    && $_limitsProbed
                    && $detail =~ /limit|offset/i
                    && !$cache->get('spoton_rate_limit')
                    && (time() - $_limitsLastProbed) > REPROBE_COOLDOWN_S)
                {
                    $log->warn("Client: 400 on $cleanPath (limit-related) — triggering lazy limit re-probe");
                    $class->probeEndpointLimits($accountId, sub {}, force => 1);
                }

                unless ($params->{_probeCall}) {
                    $log->error("Client: HTTP $code error for $cleanPath: $error" . ($detail ? " ($detail)" : ''));
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        my $msg = "HTTP $code for $cleanPath";
                        $msg .= ": $detail" if $detail;
                        Plugins::SpotOn::Status->recordError('error', 'API', $msg);
                    }
                    $log->warn("[DIAG] api_error: endpoint=$cleanPath code=$code error=$error detail=$detail") if $prefs->get('diagnosticMode');
                }
                $userCb->(undef, { error => $error, code => $code });
            },
            { timeout => REQUEST_TIMEOUT, cache => 0 }
        );

        my @headers = (
            'Authorization' => "Bearer $token",
            'Accept'        => 'application/json',
        );
        push @headers, 'Accept-Language' => $params->{_locale} if $params->{_locale};

        # D-04: PUT/POST requests require Content-Length header to avoid 411 Length Required.
        # The Spotify Web API rejects body-less PUT/POST without an explicit Content-Length: 0.
        # Applies to: playerPause, playerPlay, playerVolume, playerSeek Web API fallback calls.
        # Pattern from Spotty-NG API.pm:1907-1909.
        if (uc($method) eq 'PUT' || uc($method) eq 'POST') {
            push @headers, 'Content-Length' => 0;
        }

        # H1c: this closure runs inside the async getToken callback — a die here
        # would escape the eval in _request and leak $inflightCount. Route it
        # through $userCb (double-call guard makes a late duplicate harmless).
        eval {
            $http->$method($url, @headers);
            1;
        } or do {
            $log->error("Client: HTTP dispatch failed for $cleanPath: $@");
            $userCb->(undef, { error => 'internal_error' });
        };
    });
}

# _cacheTTL($path)
# Returns the appropriate cache TTL in seconds for a given API path.
# Based on CLAUDE.md domain-specific cache TTL guidelines.
sub _cacheTTL {
    my ($class, $path) = @_;

    # Playback state: never cache (always live) — also covers me/player/recently-played
    return 0 if $path =~ /^me\/player/;

    # User profile: always fresh
    return 0 if $path eq 'me';

    # Episode lists: 60s (D-01 locked) -- must precede general shows/ rule
    return 60 if $path =~ /^shows\/[^\/]+\/episodes/;

    # Library items: 60 seconds (tracks, albums, top, following, playlists, shows)
    return 60 if $path =~ /^me\/(?:tracks|albums|top|following|playlists|shows)/;

    # Single episode: 300s (on-demand, fresher resume_point)
    return 300 if $path =~ /^episodes\/[^\/]+/;

    # Track/album/artist/show metadata: 3600 seconds (1 hour)
    return 3600 if $path =~ /^(?:tracks|albums|artists|shows)\//;

    # Search results: 300 seconds (5 minutes, same as browse tier)
    return 300 if $path =~ /^search/;

    # Playlists and browse data: 300 seconds (5 minutes)
    return 300 if $path =~ /^(?:playlists|browse)\//;

    # Default: no cache for unknown paths
    return 0;
}

1;
