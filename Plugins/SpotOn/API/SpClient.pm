package Plugins::SpotOn::API::SpClient;

# spclient.spotify.com HTTP layer + metadata/collection facade (D-03, Phase 75
# tracer; D-01/D-25 Phase 85). This module is the plugin's ONLY Spotify data
# transport: there is no Web API client behind it any more (API/Client.pm was
# deleted in 85-15), so an error from spclient reaches the caller as it is.
#
# The request pipeline (own inflight counter, own rate-limit cache key,
# double-callback guard/eval discipline) is isolated on purpose: a spclient
# 429 sets only SpClient's own key (D-03), and MAX_CONCURRENT_REQUESTS is
# deliberately low because the login5 (librespot CID) token shares a
# Spotify-side rate pool with the running librespot/Soloist daemon of the
# same account (D-09) -- a Browse burst here can trigger the Rapid-Skip
# audio-key throttle known error.
#
# Account gate (D-06): an account with login5-capable stored credentials
# (ZeroConf pairing / Soloist provenance) goes through spclient; an account
# without them gets cb->(undef, { error => 'no_credentials' }) at once and the
# plugin shows the "Konto koppeln" item. The one retry in the pipeline is a
# single 401-triggered token remint (D-07a) -- an expired Bearer token is
# standard token lifecycle; a SECOND 401 is reported as 'unauthorized'.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Math::BigInt;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;
use URI::Escape qw(uri_escape_utf8);

use Plugins::SpotOn::API::ProtobufLite;

# ------------------------------------------------------------
# Constants
# ------------------------------------------------------------
use constant SPCLIENT_RATE_LIMIT_KEY => 'spoton_spclient_rate_limit';   # D-03: own key, never spoton_rate_limit
use constant MAX_CONCURRENT_REQUESTS => 2;                              # D-09: low, shares the login5 rate pool with the daemon
use constant RATE_LIMIT_DEFAULT_BACKOFF => 5;
use constant REQUEST_TIMEOUT         => 30;
# 85-07 D-11 (T-85-25): getTrack retries a network-level failure (transport
# error / 5xx) after these delays in seconds -- two retries at most, every
# attempt through _request (own rate gate, concurrency cap).
use constant TRACK_META_RETRY_DELAYS => [1, 3];
# 79-27 (D-18, LIKED repair): a track list hydrates its uncached tracks with ONE
# `POST extended-metadata/v0/extended-metadata` per TRACK_BATCH_SIZE tracks instead of one
# `GET metadata/4/track/<hex>` per track. The size is MEASURED, not assumed:
# 79-27-PROBE.md EXTMETA_PROBE lines (50/100/200/500 entities, all HTTP 200 with every entity
# named, 94-155 ms) -> BATCH_DECISION=extended-metadata size=200 query=none (200 bounds the
# response, ~175 KB, against the 30 s REQUEST_TIMEOUT; 500 also passed). The bare path with the
# login5 bearer is accepted, so no query string is needed.
use constant TRACK_BATCH_SIZE        => 200;
use constant EXTMETA_PATH            => 'extended-metadata/v0/extended-metadata';
use constant EXTMETA_KIND_TRACK_V4   => 10;   # extension_kind.proto: ARTIST_V4=8 ALBUM_V4=9 TRACK_V4=10
# 79-27 (D-19): a metadata/4/track entry lives 90 days. The expiry is ABSOLUTE (time() + 90 days):
# Slim::Utils::DbCache::_canonicalize_expiration_time (DbCache.pm:214) reads any number above 2592000 as a
# unix time, so a numeric TTL of 7776000 would expire in 1970. A hit older than 30 days (the DbCache
# relative/absolute boundary) is renewed by a timer-driven drain of 50 entries per tick - never by a write
# inside the hit path (the FIX-01 problem: N synchronous SQLite INSERTs in one callback block LMS).
use constant TRACK_META_TTL          => 90 * 86400;
use constant TRACK_META_RENEW_AFTER  => 30 * 86400;
# 79-43 (D-33 FULL-3 CR-01): the format of a stored metadata/4/track value. _storeTrackMeta writes
# _spoton_fmt => TRACK_META_FORMAT; a read whose value lacks it or carries a lower one is a MISS at both readers
# (_request, _enrichTracks) and is fetched again, the refetch overwrites it. Format 2 = names are character
# strings (the batch decoder before 79-43 stored UTF-8 bytes for up to 90 days). Rejected alternatives:
#   bumping SPOTON_CACHE_VERSION - flushes every SpotOn entry (login5 tokens, migration journal, Soloist state);
#   a one-shot sweep of spoton_spclient_resp_* keys - DbCache lists no keys, and a sweep is migration code;
#   decoding in place on read - guesses the representation of every stored string.
use constant TRACK_META_FORMAT       => 2;
use constant RENEW_BATCH             => 50;
use constant APRESOLVE_URL           => 'https://apresolve.spotify.com/?type=spclient';
use constant SPCLIENT_FALLBACK_HOST  => 'gew4-spclient.spotify.com:443';
use constant HOST_CACHE_KEY          => 'spoton_spclient_host';
use constant HOST_CACHE_TTL          => 3600;
use constant BASE62_CHARSET          => '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

# collection/v2 (S-06/S-07, Phase 75 Plan 04 Task 1)
use constant COLLECTION_V2_CONTENT_TYPE => 'application/vnd.collection-v2.spotify.proto';
use constant COLLECTION_PAGE_LIMIT      => 200;
use constant COLLECTION_LIST_TTL        => 60;   # CLAUDE.md: library-item lists = 60s
use constant COLLECTION_MAX_PAGES       => 100;  # WR-03: 100 * 200 = 20k items, generous headroom

# playlist/v2 (D-14 add-to-playlist, protobuf both ways)
use constant PROTOBUF_CONTENT_TYPE => 'application/x-protobuf';

# context-resolve (Liked Songs) + recently-played (S-09, Phase 75 Plan 04 Task 3)
use constant LIKED_SONGS_LIST_TTL   => 60;   # same tier -- Liked Songs is a library list
use constant RECENTLY_PLAYED_ACCEPT => 'vnd.spotify/collection-favorites';  # S-09: protobuf-only, value is documentation

# SET_MAP: verified collection/v2 set names (Spike 009 S-07). Saved Albums
# live under the confusingly generic 'collection' set (NOT 'album', which
# 403s). pinned_playlists/saved_episodes are documented here even though no
# facade in this plan consumes them yet (full verified mapping per plan spec).
use constant SET_MAP => {
    albums           => 'collection',
    liked_tracks     => 'collection',   # D-14: tracks AND albums share this set -- never read set size as a track count
    artists          => 'artist',
    shows            => 'show',
    pinned_playlists => 'ylpin',
    saved_episodes   => 'listenlater',
};

# rootlist (S-10, protobuf-only user playlist library) + playlist/v2
# (JSON contents envelope) -- Phase 75 Plan 05.
use constant ROOTLIST_DECORATE     => 'revision,attributes,length,owner,timestamp';
use constant ROOTLIST_LIST_TTL     => 60;    # CLAUDE.md: library-item lists = 60s
use constant ROOTLIST_MAX_DEPTH    => 10;    # T-75-16/V5: bounded folder recursion
use constant PLAYLIST_ENVELOPE_TTL => 300;   # CLAUDE.md: playlist tracks = 300s tier

# Page limits (85-09, D-12): fixed values replace the Web-API endpoint probe.
# They equal what a default (bundled-ID) install used after its skipped probe
# (search 50, library 50, artist_albums 50, album_tracks 50, playlist_items
# 100), so no request volume changes. Custom
# client ids, whose unprobed defaults were lower (search 10, artist_albums 20),
# no longer exist after D-01. Search stays at 50: the web player itself sends
# 50 on result pages and Pathfinder search caps at 50; paging follows totalCount.
use constant PAGE_LIMITS => {
    search         => 50,
    library        => 50,
    artist_albums  => 50,
    album_tracks   => 50,
    playlist_items => 100,
};
use constant PAGE_LIMIT_DEFAULT => 50;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# Module-level concurrency counter -- own and isolated (D-03).
my $inflightCount = 0;

# Status counters (85-09, D-13): fed by _doRequest (dispatches, 429s) and the
# _request callback wrapper (last error). Read by statusSnapshot; zeroed by reset.
my $requestCount   = 0;
my $count429       = 0;
my $lastErrorClass = undef;
my $lastErrorAt    = undef;

# Last Made-for-You outcome (85-08, D-19): which source answered and how many
# mixes it listed, for madeForYouStatus (the status page, 85-09). WR-13:
# fallbackReason ('error' | 'empty') says WHY the rootlist was used, lastError
# the short reason of a failed section (never a token or a URL).
my %_mfy = (source => undef, mixCount => 0);

# 79-27 D-19: metadata/4/track hits that are due for renewal wait here (cache key -> the cached hash, FIFO
# in @_renewOrder, deduplicated by key) until the drain timer writes them back. $_renewTimerArmed keeps it at
# ONE timer however many hits queue up.
my %_renewPending;
my @_renewOrder;
my $_renewTimerArmed = 0;

# ============================================================
# Lifecycle
# ============================================================

# reset($class)
# Zeroes the inflight counter and clears the rate-limit/host caches. Called
# by Plugin.pm::initPlugin on startup (wired in plan 75-06) to prevent stale
# state after plugin reload.
sub reset {
    my ($class) = @_;
    $inflightCount = 0;
    $requestCount = 0;
    $count429 = 0;
    $lastErrorClass = undef;
    $lastErrorAt = undef;
    %_mfy = (source => undef, mixCount => 0);
    %_renewPending = ();
    @_renewOrder = ();
    $_renewTimerArmed = 0;
    $cache->remove(SPCLIENT_RATE_LIMIT_KEY);
    $cache->remove(HOST_CACHE_KEY);
    main::INFOLOG && $log->info('SpClient: reset');
}

# pageLimit($class, $kind)
# D-12 (85-09): items per page for a list kind (search | library | artist_albums |
# album_tracks | playlist_items); an unknown or undefined kind pages with 50.
sub pageLimit {
    my ($class, $kind) = @_;
    return PAGE_LIMITS->{ $kind // '' } // PAGE_LIMIT_DEFAULT;
}

# trackBatchSize($class)
# 79-27 D-18: entities per extended-metadata POST (the probed ceiling, see TRACK_BATCH_SIZE). Also the
# page size of the Liked Songs play-all fetch, so one page is exactly one batch.
sub trackBatchSize { return TRACK_BATCH_SIZE }

# statusSnapshot($class)
# D-13 (85-09): the spclient telemetry the status page and the diagnostic
# bundle read. Counters, host, last error class and the per-account login5
# state only -- no token, no username, no auth_data (T-85-29).
#   rateLimited  1 while the own rate key (SPCLIENT_RATE_LIMIT_KEY) is set
#   spclientHost the cached resolved host, undef before the first resolve
#   login5       { <accountId> => Login5->loginState (or undef) }
sub statusSnapshot {
    my ($class) = @_;

    my %login5;
    eval {
        require Plugins::SpotOn::API::TokenManager;
        require Plugins::SpotOn::API::Login5;
        for my $id (Plugins::SpotOn::API::TokenManager->getAccountIds()) {
            $login5{$id} = Plugins::SpotOn::API::Login5->loginState($id);
        }
        1;
    } or main::INFOLOG && $log->info("SpClient: statusSnapshot login5 read failed: $@");

    return {
        apiRequestCount => $requestCount,
        inflightCount   => $inflightCount,
        api429Count     => $count429,
        rateLimited     => $cache->get(SPCLIENT_RATE_LIMIT_KEY) ? 1 : 0,
        spclientHost    => $cache->get(HOST_CACHE_KEY),
        lastErrorClass  => $lastErrorClass,
        lastErrorAt     => $lastErrorAt,
        login5          => \%login5,
    };
}

# _noteError($err)
# Records the class of the last failed request for statusSnapshot: 'http_<code>'
# for an HTTP status, the error symbol for a named failure (rate_limited,
# invalid_credentials, parse_error, ...), 'transport_error' for a free-text
# transport message. Bounded vocabulary: nothing from a response body.
sub _noteError {
    my ($err) = @_;
    return unless ref $err eq 'HASH';
    my $sym = defined $err->{error} ? $err->{error} : '';
    $lastErrorClass = $err->{code}
        ? 'http_' . $err->{code}
        : ($sym =~ /^[a-z0-9_]{1,40}$/ ? $sym : 'transport_error');
    $lastErrorAt = int(Time::HiRes::time());
}

# ============================================================
# base62 <-> hex ID conversion (S-02)
# ============================================================
# Spotify's base62 track/album/artist IDs are 128-bit numbers -- native Perl
# ints (64-bit) overflow, so this MUST go through Math::BigInt.

# idToHex($class, $b62)
# Validates 22 chars of [0-9A-Za-z], returns a lowercase 32-hex-char string,
# or undef on any validation failure (wrong length, invalid charset).
sub idToHex {
    my ($class, $b62) = @_;
    return undef unless defined $b62 && length($b62) == 22;
    return undef unless $b62 =~ /^[0-9A-Za-z]{22}$/;

    my $charset = BASE62_CHARSET;
    my $n = Math::BigInt->new(0);
    for my $c (split //, $b62) {
        my $idx = index($charset, $c);
        return undef if $idx < 0;
        $n = $n * 62 + $idx;
    }

    my $hex = $n->as_hex;      # e.g. "0x1a2b3c"
    $hex =~ s/^0x//;
    $hex = ('0' x (32 - length($hex))) . $hex if length($hex) < 32;
    return lc($hex);
}

# hexToId($class, $hex)
# Exact inverse of idToHex -- 32 hex chars -> 22-char base62 string. Needed
# for shape normalization (spclient metadata gids back to Web-API ids).
sub hexToId {
    my ($class, $hex) = @_;
    return undef unless defined $hex && $hex =~ /^[0-9a-fA-F]{32}$/;

    my $charset = BASE62_CHARSET;
    my @alphabet = split //, $charset;
    my $n = Math::BigInt->new('0x' . $hex);

    my @digits;
    if ($n == 0) {
        push @digits, 0;
    }
    else {
        while ($n > 0) {
            my $rem = $n % 62;
            push @digits, $rem->numify;
            $n = ($n - $rem) / 62;
        }
    }

    my $out = join('', map { $alphabet[$_] } reverse @digits);
    $out = ('0' x (22 - length($out))) . $out if length($out) < 22;
    return $out;
}

# ============================================================
# Host resolution
# ============================================================

# _resolveHost($class, $cb)
# GETs apresolve for the nearest spclient node, caches the result 1h, and
# falls back to the known-good constant host on any failure (unreachable,
# malformed JSON, empty list) -- host resolution is never a hard blocker.
sub _resolveHost {
    my ($class, $cb) = @_;

    if (my $cached = $cache->get(HOST_CACHE_KEY)) {
        $cb->($cached);
        return;
    }

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http    = shift;
            my $content = $http->content // '';
            my $host    = SPCLIENT_FALLBACK_HOST;

            my $parsed = eval { from_json($content) };
            if (!$@ && $parsed && ref($parsed) eq 'HASH'
                && ref($parsed->{spclient}) eq 'ARRAY' && @{ $parsed->{spclient} })
            {
                $host = $parsed->{spclient}[0];
            }

            $cache->set(HOST_CACHE_KEY, $host, HOST_CACHE_TTL);
            $cb->($host);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("SpClient: apresolve failed, using fallback host: $error");
            $cb->(SPCLIENT_FALLBACK_HOST);
        },
        { timeout => 10 },
    )->get(APRESOLVE_URL);
}

# ============================================================
# Capability router (D-06/D-07)
# ============================================================

# _hasLogin5Creds($class, $accountId)
# The account-usable gate (85-15, D-01): does this account have login5-capable
# stored credentials (ZeroConf pairing / Soloist provenance)? Every public
# method answers cb->(undef, { error => 'no_credentials' }) at once when it
# does not -- there is no second transport behind spclient any more, so an
# unpaired account reaches the feeds as an error and the plugin turns it into
# the "Konto koppeln" item (Plugin.pm _authRequiredItem).
sub _hasLogin5Creds {
    my ($class, $accountId) = @_;
    return 0 unless $accountId;

    require Plugins::SpotOn::API::Credentials;
    my $creds = Plugins::SpotOn::API::Credentials->verifyCredentials($accountId);
    return $creds ? 1 : 0;
}

# _username($class, $accountId)
# The Spotify canonical username from stored credentials -- ALWAYS the
# source for collection/v2, context-resolve, recently-played, and rootlist
# username fields (RESEARCH.md username-source rule). NEVER read from prefs
# spotifyUserId, which may differ from the credentials.json username
# depending on provenance (A5).
sub _username {
    my ($class, $accountId) = @_;
    require Plugins::SpotOn::API::Credentials;
    my $creds = Plugins::SpotOn::API::Credentials->verifyCredentials($accountId);
    return ($creds && ref($creds) eq 'HASH') ? $creds->{username} : undef;
}

# getDisplayName($class, $accountId, $cb)
# D-05 (Phase 85): the account's display name from the user-profile-view
# profile (S-08, the tested call; the `name` key is present, 85-03 D05).
# cb->($name) with a trimmed non-empty string, or cb->(undef) on an empty or
# non-string name, any error, or missing credentials (no request is sent
# then). There is deliberately no fallback to the Web API: callers keep the
# user id as the display name when this answers undef.
sub getDisplayName {
    my ($class, $accountId, $cb) = @_;

    my $username = $class->_username($accountId);
    unless ($username) {
        main::INFOLOG && $log->info('SpClient: getDisplayName without stored credentials -- nothing to look up');
        $cb->(undef);
        return;
    }

    $class->_request('get', 'user-profile-view/v3/profile/' . uri_escape_utf8($username), {
        _accountId => $accountId,
        _accept    => 'application/json',
        _noCache   => 1,
    }, sub {
        my ($result, $err) = @_;

        if ($err || !$result || ref($result) ne 'HASH') {
            $cb->(undef);
            return;
        }

        my $name = $result->{name};
        if (!defined $name || ref $name) {
            $cb->(undef);
            return;
        }
        $name =~ s/\A\s+|\s+\z//g;
        $cb->(length $name ? $name : undef);
    });
}

# ============================================================
# Core request pipeline (D-03)
# ============================================================

# _request($class, $method, $path, $params, $cb)
# Rate-limit gate (own key) -> response cache check -> concurrency cap ->
# double-callback-guarded dispatch to _doRequest.
sub _request {
    my ($class, $method, $path, $params, $cb) = @_;

    my $cleanPath = $path;
    $cleanPath =~ s{^/}{};

    if (my $retryUntil = $cache->get(SPCLIENT_RATE_LIMIT_KEY)) {
        my $remaining = $retryUntil - Time::HiRes::time();
        if ($remaining > 0) {
            main::INFOLOG && $log->info("SpClient: request to " . _logPath($cleanPath) . " short-circuited (cached rate limit)");
            $cb->(undef, { error => 'rate_limited_local', code => 429 });
            return;
        }
    }

    my $accountId = $params->{_accountId} // '';
    unless ($params->{_noCache}) {
        my $cacheKey = "spoton_spclient_resp_${accountId}_${cleanPath}";
        $params->{_cacheKey} = $cacheKey;
        # 79-27 D-20: _refreshCache skips the READ only (a track that starts playing is fetched fresh) and keeps
        # the write below, so the fresh result overwrites the entry. _noCache, by contrast, skips both.
        my $cached = $params->{_refreshCache} ? undef : $cache->get($cacheKey);
        # 79-43 (D-33 FULL-3 CR-01): a track value without the current format marker is a miss, decided BEFORE
        # _noteTrackHit so it is never queued for renewal; the refetch below overwrites it.
        undef $cached if $cached && $cleanPath =~ m{^metadata/4/track/} && !$class->_trackMetaCurrent($cached);
        if ($cached) {
            main::INFOLOG && $log->info("SpClient: cache hit for " . _logPath($cleanPath));
            $class->_noteTrackHit($cacheKey, $cached) if $cleanPath =~ m{^metadata/4/track/};
            $cb->($cached);
            return;
        }
    }

    if ($inflightCount >= MAX_CONCURRENT_REQUESTS) {
        Slim::Utils::Timers::setTimer(
            undef,
            Time::HiRes::time() + 0.1,
            sub { $class->_request($method, $cleanPath, $params, $cb) },
        );
        return;
    }

    $inflightCount++;
    my $userCbCalled = 0;
    my $userCb = sub {
        return if $userCbCalled++;
        $inflightCount--;
        _noteError($_[1]) if !defined $_[0];
        $cb->(@_);
    };

    # H1: eval-guarded -- any die after $inflightCount++ must exit through
    # $userCb (the single decrement point with double-call guard), or the
    # counter leaks and all spclient traffic deadlocks.
    eval {
        $class->_doRequest($method, $cleanPath, $params, $userCb);
        1;
    } or do {
        $log->error("SpClient: dispatch failed for " . _logPath($cleanPath) . ": $@");
        $userCb->(undef, { error => 'internal_error' });
    };
}

# _logPath($path) -- 79-43 (D-33 FULL-3 WR-01): the request path as it may appear in a log line. The username
# (profile/<u>, spotify:user:<u>, /user/<u>, raw or URI-escaped) and everything after spotify:search: are masked;
# the request path, the cache key and the request itself are never changed - only what is logged.
sub _logPath {
    my ($p) = @_;
    return '' unless defined $p;
    $p =~ s{(profile/|spotify:user:|/user/)[^/:?]+}{$1****}g;
    $p =~ s{spotify:search:.*}{spotify:search:****}s;
    return $p;
}

# _doRequest($class, $method, $cleanPath, $params, $userCb)
# Fetches a login5 Bearer token, resolves the spclient host, issues the HTTP
# call, and normalizes response/error -- including the single D-07a 401
# remint retry.
sub _doRequest {
    my ($class, $method, $cleanPath, $params, $userCb) = @_;

    my $accountId = $params->{_accountId};

    $requestCount++;

    require Plugins::SpotOn::API::Login5;
    Plugins::SpotOn::API::Login5->getToken($accountId, sub {
        my ($token, $reason, $detail) = @_;

        unless ($token) {
            main::INFOLOG && $log->info('SpClient: no login5 token for account (reason=' . ($reason // '?') . ')');
            # WR-16/WR-18: a login5 throttle (HTTP 429 or a protobuf
            # TIMEOUT/TOO_MANY_ATTEMPTS/TRY_AGAIN_LATER) is a rate limit, not
            # "no token".
            my $err = ($detail && ref $detail eq 'HASH' && ($detail->{throttled} || ($detail->{code} // 0) == 429))
                ? { error => 'rate_limited', code => 429, source => 'login5' }
                : { error => $reason || 'no_token' };
            $userCb->(undef, $err);
            return;
        }

        $class->_resolveHost(sub {
            my ($host) = @_;

            my $url    = "https://$host/$cleanPath";
            my $accept = $params->{_accept} || 'application/json';

            # T-02-10: never log the Authorization header value -- path+method only.
            main::INFOLOG && $log->info("SpClient: $method " . _logPath($cleanPath));

            my $http = Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $httpResp = shift;
                    my $content  = $httpResp->content // '';

                    my $result;
                    if ($params->{_raw}) {
                        $result = $content;
                    }
                    elsif ($content =~ /\S/) {
                        $result = eval { from_json($content) };
                        if ($@) {
                            $log->error("SpClient: JSON parse error for " . _logPath($cleanPath) . ": $@");
                            $userCb->(undef, { error => 'parse_error' });
                            return;
                        }
                    }

                    unless ($params->{_noCache}) {
                        my $ttl = $class->_cacheTTL($cleanPath);
                        if ($ttl > 0) {
                            my $cacheKey = $params->{_cacheKey} || "spoton_spclient_resp_$cleanPath";
                            if ($cleanPath =~ m{^metadata/4/track/([0-9a-f]{32})$} && ref($result) eq 'HASH') {
                                $class->_storeTrackMeta($cacheKey, $1, $result);   # 79-27 D-19: stamp + 90-day absolute expiry
                            }
                            else {
                                $cache->set($cacheKey, $result, $ttl);
                            }
                        }
                    }

                    $userCb->($result);
                },
                sub {
                    my ($httpResp, $error, $response) = @_;

                    my $code = ($response && ref $response && $response->can('code'))
                        ? ($response->code || 0) : 0;
                    if (!$code && $error && $error =~ /^(\d{3})\b/) {
                        $code = $1;
                    }

                    if ($code == 429) {
                        $count429++;
                        my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                        if ($response && ref $response && $response->can('header')) {
                            my $headerVal = $response->header('Retry-After');
                            $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                        }
                        $retryAfter = 1   if $retryAfter < 1;
                        $retryAfter = 300 if $retryAfter > 300;

                        # D-03: own rate key -- never touches spoton_rate_limit.
                        $cache->set(SPCLIENT_RATE_LIMIT_KEY, Time::HiRes::time() + $retryAfter, $retryAfter);
                        $log->warn("SpClient: 429 rate limited for ${retryAfter}s on " . _logPath($cleanPath));

                        $userCb->(undef, { error => 'rate_limited', code => 429 });
                        return;
                    }

                    if ($code == 401) {
                        $cache->remove("spoton_login5_token_${accountId}") if $accountId;

                        # D-07a: exactly one remint retry on the FIRST 401 --
                        # refreshing an expired Bearer token is standard token
                        # lifecycle, not a spclient API failure. A second 401
                        # means the account cannot authenticate right now and
                        # is reported as 'unauthorized' at once (D-07a).
                        if (!$params->{_retried401}) {
                            $log->warn("SpClient: 401 for " . _logPath($cleanPath) . ", retrying once with a fresh token (D-07a)");
                            $params->{_retried401} = 1;
                            eval {
                                $class->_doRequest($method, $cleanPath, $params, $userCb);
                                1;
                            } or do {
                                $log->error("SpClient: 401 retry dispatch failed for " . _logPath($cleanPath) . ": $@");
                                $userCb->(undef, { error => 'internal_error' });
                            };
                            return;
                        }

                        $log->warn("SpClient: 401 for " . _logPath($cleanPath) . " after remint retry -- reporting unauthorized");
                        $userCb->(undef, { error => 'unauthorized', code => 401 });
                        return;
                    }

                    $log->error("SpClient: HTTP $code error for " . _logPath($cleanPath) . ": " . _logPath($error));   # an error text can carry the URL
                    $userCb->(undef, { error => $error, code => $code });
                },
                { timeout => REQUEST_TIMEOUT, cache => 0 },
            );

            my @headers = (
                'Authorization' => "Bearer $token",
                'Accept'        => $accept,
            );
            # collection/v2 (S-06) needs Content-Type AND Accept set to the
            # exact same vendor string -- any other Content-Type is a 400.
            push @headers, 'Content-Type' => $params->{_contentType} if defined $params->{_contentType};

            # POST bodies (collection/v2 PageRequest protobuf) are appended
            # as the final argument -- SimpleHTTP::Base treats an odd-length
            # arg list as (headers..., content).
            my @callArgs = @headers;
            push @callArgs, $params->{_body} if defined $params->{_body};

            eval {
                $http->$method($url, @callArgs);
                1;
            } or do {
                $log->error("SpClient: HTTP dispatch failed for " . _logPath($cleanPath) . ": $@");
                $userCb->(undef, { error => 'internal_error' });
            };
        });
    });
}

# _cacheTTL($class, $path)
# Domain-specific cache TTLs (CLAUDE.md guidance). Only metadata/4 is used
# by this plan's getTrack facade; context-resolve/search TTLs are here for
# plans 75-02/75-04/75-05 to reuse without re-deriving the table.
sub _cacheTTL {
    my ($class, $path) = @_;
    # 79-27 D-19: a track lives 90 days, as an ABSOLUTE expiry (see TRACK_META_TTL). Checked BEFORE the generic
    # metadata/4/ line; album/artist/show/episode keep 3600 s.
    return time() + TRACK_META_TTL if $path =~ m{^metadata/4/track/};
    return 3600 if $path =~ m{^metadata/4/};
    return 300  if $path =~ m{^context-resolve/};
    return 0;
}

# ============================================================
# getTrack facade (D-06/D-07 tracer)
# ============================================================

# getTrack($class, $accountId, $trackId, $cb)
# cb contract: cb->($result) on success,
# cb->(undef, $err) on error. 85-07 D-11: spclient is the ONLY metadata
# source -- no credentials answer cb->(undef, {error => 'no_credentials'})
# at once, and an error never falls back to the Web API. A network-level
# failure (code 0 transport error such as "Connect timed out", or code >= 500)
# is retried after TRACK_META_RETRY_DELAYS (1 s, 3 s) and only then reported;
# every other error (404, 401 after its remint, 429, ...) goes to the callback
# immediately, so callers can tell "not found" from "could not ask".
sub getTrack {
    my ($class, $accountId, $trackId, $cb, $opts) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getTrack without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($trackId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_getTrackAttempt($accountId, $hexId, $cb, 0, $opts);
}

# _getTrackAttempt($class, $accountId, $hexId, $cb, $attempt) -- one try of
# getTrack; $attempt counts the retries already made.
sub _getTrackAttempt {
    my ($class, $accountId, $hexId, $cb, $attempt, $opts) = @_;

    $class->_request('get', "metadata/4/track/$hexId", {
        _accountId    => $accountId,
        _accept       => 'application/json',
        # 79-27 D-20: { refresh => 1 } fetches fresh and overwrites the cache entry (a track that starts playing)
        ($opts && ref $opts eq 'HASH' && $opts->{refresh} ? (_refreshCache => 1) : ()),
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            my $delays = TRACK_META_RETRY_DELAYS;
            if ($class->_isTransientNetworkError($err) && $attempt < scalar(@$delays)) {
                my $delay = $delays->[$attempt];
                main::INFOLOG && $log->info("SpClient: getTrack network error ("
                    . ($err->{error} // '?') . "), retry " . ($attempt + 1) . " in ${delay}s");
                Slim::Utils::Timers::setTimer(
                    undef,
                    Time::HiRes::time() + $delay,
                    sub { $class->_getTrackAttempt($accountId, $hexId, $cb, $attempt + 1, $opts) },
                );
                return;
            }
            $cb->(undef, $err);
            return;
        }

        $cb->($class->_normalizeTrack($result));
    });
}

# _isTransientNetworkError($class, $err) -- D-11/P5: a timeout looks like a
# 404 only to a careless classifier. Transient = the request itself failed
# (code 0 from _doRequest's error callback, e.g. "Connect timed out") or the
# server did (code >= 500). Errors without a `code` key (no_token,
# internal_error, ...) and rate limits are NOT retried here.
sub _isTransientNetworkError {
    my ($class, $err) = @_;
    return 0 unless $err && ref($err) eq 'HASH' && defined $err->{code};
    return ($err->{code} == 0 || $err->{code} >= 500) ? 1 : 0;
}

# _normalizeTrack($class, $meta)
# Maps spclient metadata/4/track JSON to the Web-API track shape callers
# already consume (Pitfall 6 / Discretion: pure normalization, callers
# unchanged). Missing fields degrade to undef/[] -- never dies on absent
# keys (untrusted network JSON).
sub _normalizeTrack {
    my ($class, $meta) = @_;
    return undef unless $meta && ref($meta) eq 'HASH';

    my $id  = $meta->{gid} ? $class->hexToId($meta->{gid}) : undef;
    my $uri = $id ? "spotify:track:$id" : undef;

    my @artists;
    for my $a (@{ $meta->{artist} || [] }) {
        my $artistId = ($a->{gid}) ? $class->hexToId($a->{gid}) : undef;
        push @artists, {
            id   => $artistId,
            uri  => $artistId ? "spotify:artist:$artistId" : undef,
            name => $a->{name},
        };
    }

    my $album      = $meta->{album} || {};
    my $albumId    = $album->{gid} ? $class->hexToId($album->{gid}) : undef;
    my $coverGroup = $album->{cover_group} || {};

    my @images;
    for my $img (@{ $coverGroup->{image} || [] }) {
        push @images, {
            url    => 'https://i.scdn.co/image/' . ($img->{file_id} // ''),
            width  => $img->{width},
            height => $img->{height},
        };
    }

    return {
        id          => $id,
        uri         => $uri,
        name        => $meta->{name},
        duration_ms => $meta->{duration},
        explicit    => $meta->{explicit} ? 1 : 0,
        popularity  => $meta->{popularity},
        artists     => \@artists,
        album       => {
            id     => $albumId,
            uri    => $albumId ? "spotify:album:$albumId" : undef,
            name   => $album->{name},
            images => \@images,
        },
    };
}

# ============================================================
# Shared helpers (Phase 75 Plan 02)
# ============================================================

# _imagesFromGroup($class, $group)
# Maps a spclient cover_group/portrait_group {image:[{file_id,width,height}]}
# structure to Web-API-shaped image objects. Missing/malformed groups yield
# an empty arrayref -- Pitfall 6: never dies on absent/unexpected JSON keys.
sub _imagesFromGroup {
    my ($class, $group) = @_;
    my @images;
    for my $img (@{ ($group && ref($group) eq 'HASH') ? ($group->{image} || []) : [] }) {
        push @images, {
            url    => 'https://i.scdn.co/image/' . ($img->{file_id} // ''),
            width  => $img->{width},
            height => $img->{height},
        };
    }
    return \@images;
}

# _formatDate($class, $date)
# Maps spclient's {year,month,day} date struct to a Web-API "YYYY-MM-DD"
# string. Missing month/day (partial-precision releases) default to 01.
# No year at all -> undef (callers already guard optional release_date/
# release_year fields).
sub _formatDate {
    my ($class, $date) = @_;
    return undef unless $date && ref($date) eq 'HASH' && $date->{year};
    return sprintf('%04d-%02d-%02d', $date->{year}, $date->{month} || 1, $date->{day} || 1);
}

# _spFacade($class, $path, $params, $normalize, $cb)
# Shared request/normalize pattern reused by every metadata/4 facade method
# below (album/artist/show/episode). Issues the spclient request; on success,
# hands the raw result to $normalize->($result, $cb) (which itself calls $cb
# -- may be sync or async, e.g. getAlbumTracks' enrichment pass); on an error
# delivers it to the caller as-is. There is no fallback transport (85-15,
# D-01): the caller sees the spclient error and decides how to show it.
sub _spFacade {
    my ($class, $path, $params, $normalize, $cb) = @_;

    $class->_request('get', $path, $params, sub {
        my ($result, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        $normalize->($result, $cb);
    });
}

# _enrichMeta($class, $accountId, \@ids, $metaType, $normalizeMethod, $cb)
# Generic fan-out enrichment: resolves N base62 ids to normalized objects via
# GET metadata/4/$metaType/{hex} per id, THROUGH _request (so the cap-2
# concurrency gate and the 3600s response cache apply -- D-09: bursts are
# serialized, repeats are cache hits). Preserves input order internally,
# tolerates individual failures by substituting undef, and filters undefs
# from the final result before calling back once with the arrayref.
sub _enrichMeta {
    my ($class, $accountId, $ids, $metaType, $normalizeMethod, $cb) = @_;
    $ids ||= [];

    unless (@$ids) {
        $cb->([]);
        return;
    }

    my @results   = (undef) x scalar(@$ids);
    my $remaining = scalar @$ids;

    for my $i (0 .. $#$ids) {
        my $id    = $ids->[$i];
        my $hexId = $class->idToHex($id);

        # CR-01: a failed idToHex/metadata-fetch never drops the slot -- a
        # minimal id/uri stub is substituted instead, so
        # scalar(@results) == scalar(@$ids) ALWAYS holds regardless of
        # individual failures (429s/timeouts under load, the D-09 degraded
        # mode this facade is designed to tolerate). Dropping items here
        # desyncs every offset-advance-by-returned-count caller
        # (_fetchPages/_albumFeed play-all/explodePlaylist).
        my $stub = { id => $id, uri => "spotify:$metaType:$id", name => undef };

        my $finish = sub {
            my ($val) = @_;
            $results[$i] = $val || $stub;
            if (--$remaining == 0) {
                $cb->(\@results);
            }
        };

        unless ($hexId) {
            $finish->(undef);
            next;
        }

        $class->_request('get', "metadata/4/$metaType/$hexId", {
            _accountId => $accountId,
            _accept    => 'application/json',
        }, sub {
            my ($result, $err) = @_;
            $finish->($err ? undef : $class->$normalizeMethod($result));
        });
    }
}

# _trackStub($id) -- the minimal id/uri stub that keeps a failed slot in place (CR-01).
sub _trackStub {
    my ($class, $id) = @_;
    return { id => $id, uri => "spotify:track:$id", name => undef };
}

# _trackCacheKey($class, $accountId, $hexId) -- the per-track response cache key; the very key
# _request uses for GET metadata/4/track/<hex>, so getTrack, _asyncRefetch and the batch share it.
sub _trackCacheKey {
    my ($class, $accountId, $hexId) = @_;
    return "spoton_spclient_resp_${accountId}_metadata/4/track/$hexId";
}

# _enrichTracks($class, $accountId, \@trackIds, $cb)
# 79-27 D-18/D-21: the shared hydration path of every track list (album tracks, search context tracks,
# Liked Songs, playlist items). Cached tracks are taken from the per-track cache; the misses (deduplicated,
# input order) travel in chunks of TRACK_BATCH_SIZE as ONE extended-metadata POST each, through _request
# (rate key, 401 remint, concurrency cap 2 -- no second queue). Calls back ONCE with results in input order and
# scalar(@results) == scalar(@$trackIds) ALWAYS (CR-01): an invalid id, a failed chunk, a 404 entity or a
# nameless entity is the id/uri stub in its own slot, never a dropped item.
sub _enrichTracks {
    my ($class, $accountId, $trackIds, $cb) = @_;
    $trackIds ||= [];

    unless (@$trackIds) {
        $cb->([]);
        return;
    }

    my @results = (undef) x scalar(@$trackIds);
    my %slots;     # hex -> [slot indexes] of the misses
    my @missOrder; # [id, hex] unique, input order

    for my $i (0 .. $#$trackIds) {
        my $id    = $trackIds->[$i];
        my $hexId = $class->idToHex($id);
        unless ($hexId) {
            $results[$i] = $class->_trackStub($id);
            next;
        }

        my $cacheKey = $class->_trackCacheKey($accountId, $hexId);
        my $cached = $cache->get($cacheKey);
        undef $cached if $cached && !$class->_trackMetaCurrent($cached);   # 79-43: unmarked = miss, before _noteTrackHit
        if ($cached) {
            $class->_noteTrackHit($cacheKey, $cached);   # 79-27 D-19: a due entry is renewed by the drain, not here
            $results[$i] = $class->_normalizeTrack($cached) || $class->_trackStub($id);
            next;
        }

        push @missOrder, [$id, $hexId] unless $slots{$hexId};
        push @{ $slots{$hexId} }, $i;
    }

    unless (@missOrder) {
        $cb->(\@results);
        return;
    }

    my @chunks;
    push @chunks, [ splice(@missOrder, 0, TRACK_BATCH_SIZE) ] while @missOrder;
    my $pending = scalar @chunks;

    for my $chunk (@chunks) {
        $class->_fetchTrackChunk($accountId, $chunk, 0, sub {
            my ($byHex) = @_;
            for my $m (@$chunk) {
                my ($id, $hexId) = @$m;
                my $track = $byHex ? $byHex->{$hexId} : undef;
                $results[$_] = $track || $class->_trackStub($id) for @{ $slots{$hexId} };
            }
            $cb->(\@results) if --$pending == 0;
        });
    }
}

# _fetchTrackChunk($class, $accountId, \@chunk, $attempt, $cb)
# One extended-metadata POST for [[id, hex], ...]; cb->(\%normalizedTrackByHex) -- empty on any failure (the
# caller stubs the slots). A network-level failure (_isTransientNetworkError) is retried after
# TRACK_META_RETRY_DELAYS like _getTrackAttempt; a 404/429/401 or a malformed body ends the chunk at once.
sub _fetchTrackChunk {
    my ($class, $accountId, $chunk, $attempt, $cb) = @_;

    my $query = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 0, EXTMETA_KIND_TRACK_V4);
    my $body  = join '', map {
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2,
            Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, 'spotify:track:' . $_->[0])
          . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $query))
    } @$chunk;

    $class->_request('post', EXTMETA_PATH, {
        _accountId   => $accountId,
        _accept      => PROTOBUF_CONTENT_TYPE,
        _contentType => PROTOBUF_CONTENT_TYPE,
        _body        => $body,
        _raw         => 1,
        _noCache     => 1,   # the per-track entries below are this path's cache, not one blob per chunk
    }, sub {
        my ($raw, $err) = @_;

        if ($err) {
            my $delays = TRACK_META_RETRY_DELAYS;
            if ($class->_isTransientNetworkError($err) && $attempt < scalar(@$delays)) {
                my $delay = $delays->[$attempt];
                main::INFOLOG && $log->info("SpClient: extended-metadata network error ("
                    . ($err->{error} // '?') . "), retry " . ($attempt + 1) . " in ${delay}s");
                Slim::Utils::Timers::setTimer(
                    undef,
                    Time::HiRes::time() + $delay,
                    sub { $class->_fetchTrackChunk($accountId, $chunk, $attempt + 1, $cb) },
                );
                return;
            }
            main::INFOLOG && $log->info('SpClient: extended-metadata chunk failed (' . ($err->{error} // '?') . '), '
                . scalar(@$chunk) . ' tracks stubbed');
            $cb->({});
            return;
        }

        my $byUri = eval { $class->_decodeExtendedTracks($raw) };
        unless ($byUri) {
            $log->warn('SpClient: extended-metadata response not decodable, ' . scalar(@$chunk) . ' tracks stubbed');
            $cb->({});
            return;
        }

        my %byHex;
        for my $m (@$chunk) {
            my ($id, $hexId) = @$m;
            my $meta = $byUri->{"spotify:track:$id"} or next;
            $meta->{gid} = $hexId unless defined $meta->{gid} && length $meta->{gid};
            $class->_storeTrackMeta($class->_trackCacheKey($accountId, $hexId), $hexId, $meta);
            my $norm = $class->_normalizeTrack($meta) or next;
            $byHex{$hexId} = $norm;
        }
        $cb->(\%byHex);
    });
}

# _storeTrackMeta($class, $cacheKey, $hexId, $meta) -- the one write of a metadata/4/track result.
# 79-27 D-19: stores a shallow copy with its own _spoton_cached_at stamp (the age lives inside the value -
# DbCache has no touch API and get() never returns the expiry) and the 90-day absolute expiry.
sub _storeTrackMeta {
    my ($class, $cacheKey, $hexId, $meta) = @_;
    return unless ref($meta) eq 'HASH';
    my $ttl = $class->_cacheTTL("metadata/4/track/$hexId");
    $cache->set($cacheKey, { %$meta, _spoton_cached_at => time(), _spoton_fmt => TRACK_META_FORMAT }, $ttl) if $ttl > 0;
}

# _trackMetaCurrent($class, $value) -- 79-43 (D-33 FULL-3 CR-01): true when a cached metadata/4/track value carries
# the current format marker (_spoton_fmt >= TRACK_META_FORMAT). Anything else is a miss at every reader.
sub _trackMetaCurrent {
    my ($class, $value) = @_;
    return 0 unless ref($value) eq 'HASH';
    my $fmt = $value->{_spoton_fmt};
    return (defined $fmt && $fmt =~ /\A\d+\z/ && $fmt >= TRACK_META_FORMAT) ? 1 : 0;
}

# _noteTrackHit($class, $cacheKey, $value) -- 79-27 D-19: called from every metadata/4/track cache HIT. An
# entry with no stamp (written before this change) or a stamp older than TRACK_META_RENEW_AFTER is queued
# (deduplicated by key) and ONE drain timer is armed; nothing is written here.
sub _noteTrackHit {
    my ($class, $cacheKey, $value) = @_;
    return unless ref($value) eq 'HASH';

    my $at = $value->{_spoton_cached_at};
    return if defined $at && $at =~ /\A\d+\z/ && (time() - $at) <= TRACK_META_RENEW_AFTER;
    return if exists $_renewPending{$cacheKey};

    $_renewPending{$cacheKey} = $value;
    push @_renewOrder, $cacheKey;
    $class->_armRenewDrain;
}

sub _armRenewDrain {
    my ($class) = @_;
    return if $_renewTimerArmed;
    $_renewTimerArmed = 1;
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), \&_flushTrackRenewals);
}

# _flushTrackRenewals() -- the drain: RENEW_BATCH entries per timer tick (the Plugin.pm _flushDeferredMeta
# pattern), each written back with a fresh stamp and the 90-day absolute expiry; re-arms while entries remain.
sub _flushTrackRenewals {
    my $class = __PACKAGE__;
    $_renewTimerArmed = 0;

    my $n = 0;
    while (@_renewOrder && $n < RENEW_BATCH) {
        my $key   = shift @_renewOrder;
        my $value = delete $_renewPending{$key} or next;
        next unless $key =~ m{metadata/4/track/([0-9a-f]{32})\z};
        next unless $class->_trackMetaCurrent($value);   # 79-43: never stamp the marker on an old-format value
        $class->_storeTrackMeta($key, $1, $value);
        $n++;
    }

    $class->_armRenewDrain if @_renewOrder;
}

# _decodeExtendedTracks($class, $raw) -> { entity_uri => JSON-shaped track hash } or undef (malformed).
# BatchedExtensionResponse { extended_metadata = 2 { extension_data = 3 { header = 1 { status_code = 1 },
# entity_uri = 2, extension_data = 3 Any { value = 2 = Track } } } }. Pairing is by entity_uri (the order of
# the answer is not guaranteed); an entity whose status_code is not 2xx, or whose Track has no name, is left
# out so the caller stubs it. Bounded parsing only (ProtobufLite returns undef on malformed bytes).
sub _decodeExtendedTracks {
    my ($class, $raw) = @_;
    return undef unless defined $raw && length $raw;

    my $top = Plugins::SpotOn::API::ProtobufLite::parse_fields($raw) or return undef;
    return undef unless $top->{2};

    my %byUri;
    for my $arrBytes (@{ $top->{2} }) {
        my $arr = Plugins::SpotOn::API::ProtobufLite::parse_fields($arrBytes) or next;
        for my $dataBytes (@{ $arr->{3} || [] }) {
            my $e = Plugins::SpotOn::API::ProtobufLite::parse_fields($dataBytes) or next;

            my $uri = Plugins::SpotOn::API::ProtobufLite::field_first($e, 2);
            next unless defined $uri && length $uri;

            if (defined(my $hdrBytes = Plugins::SpotOn::API::ProtobufLite::field_first($e, 1))) {
                my $hdr    = Plugins::SpotOn::API::ProtobufLite::parse_fields($hdrBytes);
                my $status = $hdr ? Plugins::SpotOn::API::ProtobufLite::field_first($hdr, 1) : undef;
                next if defined $status && ($status < 200 || $status > 299);
            }

            my $any = Plugins::SpotOn::API::ProtobufLite::parse_fields(
                Plugins::SpotOn::API::ProtobufLite::field_first($e, 3) // '') or next;
            my $meta = $class->_decodeTrackMessage(Plugins::SpotOn::API::ProtobufLite::field_first($any, 2));
            next unless $meta && defined $meta->{name} && length $meta->{name};

            $byUri{$uri} = $meta;
        }
    }
    return \%byUri;
}

# _decodeTrackMessage($class, $bytes) -> the hash GET metadata/4/track/<hex> returns as JSON (gid hex, name,
# duration, explicit, popularity, artist[], album { gid, name, cover_group { image[] } }) so one normalizer
# (_normalizeTrack) and one cache shape serve both paths. metadata.proto: Track { gid=1 name=2 album=3 artist=4
# duration=7 popularity=8 explicit=9 }, Album { gid=1 name=2 cover_group=17 }, ImageGroup { image=1 },
# Image { file_id=1 width=3 height=4 }, Artist { gid=1 name=2 }. duration/popularity/width/height are sint32
# (zigzag); gid/file_id are raw bytes -> hex.
sub _decodeTrackMessage {
    my ($class, $bytes) = @_;
    my $PB = 'Plugins::SpotOn::API::ProtobufLite';
    my $t = $PB->can('parse_fields')->($bytes) or return undef;

    my $hex = sub { my $b = shift; return (defined $b && length $b) ? unpack('H*', $b) : undef };
    # 79-43 (D-33 FULL-3 CR-01, the 85-16 rootlist rule of _parseRootlist): protobuf strings arrive as UTF-8
    # bytes; names leave this decoder as Perl character strings, exactly like the JSON path's.
    my $str = sub { my $s = shift; utf8::decode($s) if defined $s; return $s };

    my %m;
    $m{gid}  = $hex->($PB->can('field_first')->($t, 1));
    $m{name} = $str->($PB->can('field_first')->($t, 2));

    my $dur = $PB->can('decode_zigzag')->($PB->can('field_first')->($t, 7));
    $m{duration} = $dur if defined $dur;
    my $pop = $PB->can('decode_zigzag')->($PB->can('field_first')->($t, 8));
    $m{popularity} = $pop if defined $pop;
    $m{explicit} = $PB->can('field_first')->($t, 9) ? 1 : 0;

    my @artists;
    for my $aBytes (@{ $t->{4} || [] }) {
        my $a = $PB->can('parse_fields')->($aBytes) or next;
        push @artists, { gid => $hex->($PB->can('field_first')->($a, 1)), name => $str->($PB->can('field_first')->($a, 2)) };
    }
    $m{artist} = \@artists;

    my %album;
    if (defined(my $alBytes = $PB->can('field_first')->($t, 3))) {
        if (my $al = $PB->can('parse_fields')->($alBytes)) {
            $album{gid}  = $hex->($PB->can('field_first')->($al, 1));
            $album{name} = $str->($PB->can('field_first')->($al, 2));
            if (defined(my $cgBytes = $PB->can('field_first')->($al, 17))) {
                my $cg = $PB->can('parse_fields')->($cgBytes) || {};
                my @images;
                for my $imgBytes (@{ $cg->{1} || [] }) {
                    my $img = $PB->can('parse_fields')->($imgBytes) or next;
                    push @images, {
                        file_id => $hex->($PB->can('field_first')->($img, 1)),
                        width   => $PB->can('decode_zigzag')->($PB->can('field_first')->($img, 3)),
                        height  => $PB->can('decode_zigzag')->($PB->can('field_first')->($img, 4)),
                    };
                }
                $album{cover_group} = { image => \@images };
            }
        }
    }
    $m{album} = \%album;

    return \%m;
}

# ============================================================
# getAlbum / getAlbumTracks facades (D-06/D-07, S-04)
# ============================================================

# getAlbum($class, $accountId, $albumId, $cb)
# cb->($album) or cb->(undef, $err). No login5-capable creds ->
# no_credentials (D-06). Track names are NOT available in metadata/4/album
# (S-04) -- tracks.items is intentionally left empty; getAlbumTracks owns
# per-track enrichment.
sub getAlbum {
    my ($class, $accountId, $albumId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getAlbum without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($albumId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/album/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            $fcb->($class->_normalizeAlbum($meta));
        },
        $cb,
    );
}

# _normalizeAlbum($class, $meta)
# Maps spclient metadata/4/album JSON to the Web-API album shape. label and
# popularity are Dev-Mode-removed fields spclient still delivers (value-add).
# tracks.items is always empty (S-04) -- see getAlbumTracks.
sub _normalizeAlbum {
    my ($class, $meta) = @_;
    return undef unless $meta && ref($meta) eq 'HASH';

    my $id = $meta->{gid} ? $class->hexToId($meta->{gid}) : undef;

    my @artists;
    for my $a (@{ $meta->{artist} || [] }) {
        my $artistId = $a->{gid} ? $class->hexToId($a->{gid}) : undef;
        push @artists, {
            id   => $artistId,
            uri  => $artistId ? "spotify:artist:$artistId" : undef,
            name => $a->{name},
        };
    }

    my $totalTracks = 0;
    for my $disc (@{ $meta->{disc} || [] }) {
        $totalTracks += scalar(@{ $disc->{track} || [] });
    }

    return {
        id           => $id,
        uri          => $id ? "spotify:album:$id" : undef,
        name         => $meta->{name},
        artists      => \@artists,
        release_date => $class->_formatDate($meta->{date}),
        label        => $meta->{label},
        popularity   => $meta->{popularity},
        images       => $class->_imagesFromGroup($meta->{cover_group}),
        total_tracks => $totalTracks,
        tracks       => { items => [], total => $totalTracks },
    };
}

# getAlbumTracks($class, $accountId, $albumId, $params, $cb)
# Flattens metadata/4/album's disc[].track[] gids (disc/track order), slices
# per $params->{offset}/{limit} (defaults 0/50), and
# enriches ONLY the requested slice via _enrichTracks (lazy, D-09) -- a
# first-page call against a larger album issues exactly limit-many
# metadata/4/track requests, not one per album track.
sub getAlbumTracks {
    my ($class, $accountId, $albumId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getAlbumTracks without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($albumId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/album/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            unless ($meta && ref($meta) eq 'HASH') {
                $fcb->(undef, { error => 'parse_error' });
                return;
            }

            my @gids;
            for my $disc (@{ $meta->{disc} || [] }) {
                for my $track (@{ $disc->{track} || [] }) {
                    push @gids, $track->{gid} if $track->{gid};
                }
            }

            my ($sliceGids, $total) = $class->_sliceAsPage(\@gids, $offset, $limit);
            my @sliceIds = map { $class->hexToId($_) } @$sliceGids;

            $class->_enrichTracks($accountId, \@sliceIds, sub {
                my ($tracks) = @_;
                $fcb->({ items => $tracks, total => $total, offset => $offset, limit => $limit });
            });
        },
        $cb,
    );
}

# ============================================================
# getArtist / getArtistAlbums facades (D-06/D-07)
# ============================================================

# getArtist($class, $accountId, $artistId, $cb)
# cb->($artist) or cb->(undef, $err).
sub getArtist {
    my ($class, $accountId, $artistId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getArtist without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($artistId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/artist/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            $fcb->($class->_normalizeArtist($meta));
        },
        $cb,
    );
}

# _normalizeArtist($class, $meta)
# Maps spclient metadata/4/artist JSON to the Web-API artist shape. Images
# come from portrait_group (falls back to no images if absent). genres is
# always [] -- spclient artist metadata carries no genre taxonomy.
sub _normalizeArtist {
    my ($class, $meta) = @_;
    return undef unless $meta && ref($meta) eq 'HASH';

    my $id = $meta->{gid} ? $class->hexToId($meta->{gid}) : undef;

    return {
        id         => $id,
        uri        => $id ? "spotify:artist:$id" : undef,
        name       => $meta->{name},
        popularity => $meta->{popularity},
        images     => $class->_imagesFromGroup($meta->{portrait_group}),
        genres     => [],
    };
}

# _normalizeAlbumStub($class, $meta)
# Minimal Web-API album stub {id, uri, name, images} from an album entry
# embedded inside an artist's album_group/single_group/compilation_group --
# these entries only carry gid+name (+ optionally cover_group), so no
# additional metadata call is issued per album (matches what _albumItem in
# Plugin.pm actually renders: name+id, with images optional-safe).
sub _normalizeAlbumStub {
    my ($class, $meta) = @_;
    return undef unless $meta && ref($meta) eq 'HASH';

    my $id = $meta->{gid} ? $class->hexToId($meta->{gid}) : undef;

    return {
        id     => $id,
        uri    => $id ? "spotify:album:$id" : undef,
        name   => $meta->{name},
        images => $class->_imagesFromGroup($meta->{cover_group}),
    };
}

# getArtistAlbums($class, $accountId, $artistId, $params, $cb)
# Flattens artist metadata's album_group/single_group/compilation_group
# arrays (each group entry wraps an album[] array with gid-only entries)
# into a single Web-API album list. spclient's artist metadata only
# embeds gid per album (no name/cover), so the requested page is enriched
# via metadata/4/album per album.
sub getArtistAlbums {
    my ($class, $accountId, $artistId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 20;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getArtistAlbums without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($artistId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/artist/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            unless ($meta && ref($meta) eq 'HASH') {
                $fcb->(undef, { error => 'parse_error' });
                return;
            }

            my @albumIds;
            for my $groupKey (qw(album_group single_group compilation_group)) {
                for my $group (@{ $meta->{$groupKey} || [] }) {
                    for my $album (@{ $group->{album} || [] }) {
                        next unless $album && ref($album) eq 'HASH' && $album->{gid};
                        my $id = $class->hexToId($album->{gid});
                        push @albumIds, $id if $id;
                    }
                }
            }

            my $total = scalar @albumIds;
            my ($slicedRef) = $class->_sliceAsPage(\@albumIds, $offset, $limit);

            $class->_enrichMeta($accountId, $slicedRef, 'album', '_normalizeAlbum', sub {
                my ($enriched) = @_;
                $fcb->({ items => $enriched, total => $total, offset => $offset, limit => $limit });
            });
        },
        $cb,
    );
}

# ============================================================
# getShow / getShowEpisodes / getEpisode facades (D-06/D-07)
# NOTE: metadata/4/show and metadata/4/episode were NOT exercised in Spike
# 009 (S-04..S-11 cover track/album/artist/context-resolve/collection/
# recently-played/playlists only) -- shapes below are the best-effort mirror
# of the verified album/track pattern (show ~ album, episode ~ track,
# getShowEpisodes ~ getAlbumTracks). D-07 means ANY 4xx/5xx degrades
# is reported to the caller as an error; live verification is mandatory phase UAT.
# ============================================================

# getShow($class, $accountId, $showId, $cb)
sub getShow {
    my ($class, $accountId, $showId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getShow without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($showId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/show/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            $fcb->($class->_normalizeShow($meta));
        },
        $cb,
    );
}

# _normalizeShow($class, $meta)
# publisher is best-effort (spike-unverified field name) -- callers already
# guard optional fields (Plugin.pm's _showItem defaults publisher to '').
sub _normalizeShow {
    my ($class, $meta) = @_;
    return undef unless $meta && ref($meta) eq 'HASH';

    my $id = $meta->{gid} ? $class->hexToId($meta->{gid}) : undef;

    return {
        id             => $id,
        uri            => $id ? "spotify:show:$id" : undef,
        name           => $meta->{name},
        description    => $meta->{description},
        publisher      => $meta->{publisher},
        images         => $class->_imagesFromGroup($meta->{cover_image} || $meta->{cover_group}),
        total_episodes => scalar(@{ $meta->{episode} || [] }),
    };
}

# getShowEpisodes($class, $accountId, $showId, $params, $cb)
# Mirrors getAlbumTracks: flattens the show metadata's embedded episode gid
# list, slices per offset/limit, enriches ONLY the slice via
# metadata/4/episode/{hex} (lazy, D-09).
sub getShowEpisodes {
    my ($class, $accountId, $showId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getShowEpisodes without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($showId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/show/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            unless ($meta && ref($meta) eq 'HASH') {
                $fcb->(undef, { error => 'parse_error' });
                return;
            }

            my @gids = map { $_->{gid} } grep { $_->{gid} } @{ $meta->{episode} || [] };

            my ($sliceGids, $total) = $class->_sliceAsPage(\@gids, $offset, $limit);
            my @sliceIds = map { $class->hexToId($_) } @$sliceGids;

            $class->_enrichMeta($accountId, \@sliceIds, 'episode', '_normalizeEpisode', sub {
                my ($episodes) = @_;
                $fcb->({ items => $episodes, total => $total, offset => $offset, limit => $limit });
            });
        },
        $cb,
    );
}

# getEpisode($class, $accountId, $episodeId, $cb)
sub getEpisode {
    my ($class, $accountId, $episodeId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getEpisode without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $hexId = $class->idToHex($episodeId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_spFacade(
        "metadata/4/episode/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            $fcb->($class->_normalizeEpisode($meta));
        },
        $cb,
    );
}

# _normalizeEpisode($class, $meta)
# Mirrors _normalizeTrack's shape (duration_ms, explicit, images) plus
# release_date. resume_point/show are not present in spclient episode
# metadata -- normalized to undef (callers already guard these as optional,
# per _episodeInfoFeed/_episodeItem's existing undef-tolerant handling).
sub _normalizeEpisode {
    my ($class, $meta) = @_;
    return undef unless $meta && ref($meta) eq 'HASH';

    my $id = $meta->{gid} ? $class->hexToId($meta->{gid}) : undef;

    return {
        id           => $id,
        uri          => $id ? "spotify:episode:$id" : undef,
        name         => $meta->{name},
        duration_ms  => $meta->{duration},
        explicit     => $meta->{explicit} ? 1 : 0,
        release_date => $class->_formatDate($meta->{date}),
        images       => $class->_imagesFromGroup($meta->{cover_group}),
    };
}

# ============================================================
# search on Pathfinder (85-08, decision-SEARCH pathfinder-search)
# ============================================================

# search($class, $accountId, $params, $cb)
# Same cb contract as before: cb->({ tracks => {items,total,offset,limit}, ... })
# in the Web-API shape (keys tracks / albums / artists / playlists / shows /
# episodes for the requested types) or cb->(undef, $err). Every search runs on
# Pathfinder (API/Pathfinder.pm search): one per-type op for a single type, ONE
# searchDesktop request for a type list. No login5 credentials answer
# (undef, { error => 'no_credentials' }) without a request.
#
# Degraded mode: when Pathfinder cannot answer (hash_broken, op_missing,
# ua_gate, 401 after the re-mint, rate_limited, transport) the TRACK results of
# offset < 20 come from the context-resolve path (S-05, 20 uris, no offset
# support); every other type and deeper offset answers an empty page. The result
# then carries limited => 1 and the search menu says so.
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};

    unless ($class->_hasLogin5Creds($accountId)) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;
    Plugins::SpotOn::API::Pathfinder->search($accountId, $params, sub {
        my ($result, $err) = @_;
        if ($result) {
            $cb->($result);
            return;
        }
        if ($err && ($err->{error} // '') =~ /^invalid_/) {
            $cb->(undef, $err);
            return;
        }
        main::INFOLOG && $log->info('SpClient: Pathfinder search failed (' . (($err && $err->{error}) // '?') . '), degraded mode');
        $class->_searchDegraded($accountId, $params, $cb);
    });
    return;
}

# _searchDegraded($class, $accountId, $params, $cb) -- see search()
sub _searchDegraded {
    my ($class, $accountId, $params, $cb) = @_;

    my %key = (track => 'tracks', album => 'albums', artist => 'artists', playlist => 'playlists', show => 'shows', episode => 'episodes');
    my (@types, %seen);
    for my $t (split /,/, ($params->{type} // '')) {
        $t =~ s/\A\s+|\s+\z//g;
        push @types, $t if exists $key{$t} && !$seen{$t}++;
    }

    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 10;

    my %out = (limited => 1);
    $out{ $key{$_} } = { items => [], total => 0, limit => $limit, offset => $offset } for @types;

    unless ($seen{track} && $offset < 20) {
        $cb->(\%out);
        return;
    }

    $class->_searchContextTracks($accountId, $params->{q} // '', $offset, $limit, sub {
        my ($section, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $out{tracks} = $section;
        $cb->(\%out);
    });
}

# _searchContextTracks($class, $accountId, $query, $offset, $limit, $cb)
# context-resolve/v1 (20 track URIs, no offset support) -> lazy _enrichTracks
# of the requested slice. cb->(\%tracksSection) or cb->(undef, $err).
sub _searchContextTracks {
    my ($class, $accountId, $query, $offset, $limit, $cb) = @_;

    my $path = 'context-resolve/v1/spotify:search:' . uri_escape_utf8($query);

    $class->_request('get', $path, {
        _accountId => $accountId,
        _accept    => 'application/json',
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my @uris;
        if ($result && ref($result) eq 'HASH' && ref($result->{pages}) eq 'ARRAY') {
            my $page = $result->{pages}[0] || {};
            @uris = map { $_->{uri} } grep { ref($_) eq 'HASH' && $_->{uri} } @{ $page->{tracks} || [] };
        }

        # Window 6 (WINDOWS.md #6): filter BEFORE the count guard -- the slice
        # below operates on the track-filtered list.
        my @trackIds = map { /^spotify:track:(.+)$/ ? $1 : () } @uris;

        if ($offset >= scalar(@trackIds)) {
            $cb->({ items => [], total => scalar(@trackIds), limit => $limit, offset => $offset });
            return;
        }

        my $end = $offset + $limit - 1;
        $end = $#trackIds if $end > $#trackIds;
        my @sliceIds = @trackIds[$offset .. $end];

        $class->_enrichTracks($accountId, \@sliceIds, sub {
            my ($tracks) = @_;
            $cb->({ items => $tracks, total => scalar(@trackIds), limit => $limit, offset => $offset });
        });
    });
}

# ============================================================
# collection/v2 plumbing (D-08, S-06/S-07, A1) + getSavedAlbums
# Phase 75 Plan 04 Task 1
# ============================================================

# _collectionPage($class, $accountId, $set, $pageToken, $limit, $cb)
# One collection/v2/paging POST. Body is a hand-encoded PageRequest
# (username=1, set=2, pagination_token=3 -- OMITTED entirely when empty,
# limit=4 varint). Content-Type AND Accept are both set to the exact
# vendor string (S-06 -- any other value is a 400). Response is decoded as
# a PageResponse: field 1 is the repeated CollectionItem list (A1 --
# ProtobufLite's parse_fields already collects every occurrence into an
# arrayref, so all items across a single page survive, not just the last).
# cb->(\@items, $nextPageToken, undef) on success, cb->(undef, undef, $err)
# on failure. Each item is { uri, added_at } -- is_removed tombstones are
# filtered out here so callers never see them (S-08: added_at is for
# relative sort only, never render as a date).
sub _collectionPage {
    my ($class, $accountId, $set, $pageToken, $limit, $cb) = @_;

    my $username = $class->_username($accountId);
    unless ($username) {
        $cb->(undef, undef, { error => 'no_credentials' });
        return;
    }

    my $body = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $username)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $set);
    $body .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $pageToken)
        if defined $pageToken && length $pageToken;
    $body .= Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, $limit // COLLECTION_PAGE_LIMIT);

    $class->_request('post', 'collection/v2/paging', {
        _accountId   => $accountId,
        _accept      => COLLECTION_V2_CONTENT_TYPE,
        _contentType => COLLECTION_V2_CONTENT_TYPE,
        _body        => $body,
        _raw         => 1,
        _noCache     => 1,   # A1/pagination: caller (_collectionAll) owns list-level caching
    }, sub {
        my ($raw, $err) = @_;

        if ($err) {
            $cb->(undef, undef, $err);
            return;
        }

        my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($raw);
        unless ($fields) {
            $cb->(undef, undef, { error => 'parse_error' });
            return;
        }

        my @items;
        for my $itemBytes (@{ $fields->{1} || [] }) {
            my $itemFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($itemBytes);
            next unless $itemFields;

            my $isRemoved = Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 3);
            next if $isRemoved;

            push @items, {
                uri      => Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 1),
                added_at => Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 2),
            };
        }

        my $nextPageToken = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 2) // '';
        $cb->(\@items, $nextPageToken, undef);
    });
}

# _collectionAll($class, $accountId, $set, $cb, $noCache)
# Paginates _collectionPage until next_page_token is empty, accumulating
# every page's items. The FULL accumulated list is cached 60s per
# account+set (T-75-15: accountId in the cache key prevents cross-account
# bleed) -- callers slice/enrich only what they need (_sliceAsPage), never
# re-fetching collection/v2 on every OPML page turn within the TTL window.
# cb->(\@items, undef) on success, cb->(undef, $err) on the first page-fetch
# failure (T-75-12: a malformed/erroring page routes through D-07 at the
# facade level, never a crash here).
#
# $noCache (WR-02, optional 5th arg): when true, skips ONLY the initial
# cache read -- the fresh result is still written to the 60s cache
# afterward, refreshing it for other callers. This is a bypass-on-demand,
# not a cache-disable, matching Plugin.pm:2088's getSavedShows({ _noCache =>
# 1 }) call, which expects fresh data without permanently disabling the
# list cache for everyone else.
#
# WR-03: bounded by two independent guards so a malformed/adversarial
# spclient response can never loop forever -- (1) a hard page cap
# (COLLECTION_MAX_PAGES), which aborts as an error since
# real accumulated data cannot be trusted complete; (2) a repeated-
# page-token guard, which treats the server echoing back the SAME token it
# was just given as a normal end-of-list (real data already accumulated is
# not discarded as an error).
sub _collectionAll {
    my ($class, $accountId, $set, $cb, $noCache) = @_;

    my $cacheKey = "spoton_spclient_coll_${accountId}_${set}";
    unless ($noCache) {
        if (my $cached = $cache->get($cacheKey)) {
            $cb->($cached, undef);
            return;
        }
    }

    my @accumulated;
    my $pages = 0;
    my $fetchPage;
    $fetchPage = sub {
        my ($pageToken) = @_;

        if (++$pages > COLLECTION_MAX_PAGES) {
            undef $fetchPage;
            $log->error('SpClient: _collectionAll aborted after ' . COLLECTION_MAX_PAGES
                . " pages for set=$set (WR-03 page cap -- malformed/adversarial next_page_token?)");
            $cb->(undef, { error => 'parse_error' });
            return;
        }

        $class->_collectionPage($accountId, $set, $pageToken, COLLECTION_PAGE_LIMIT, sub {
            my ($items, $nextPageToken, $err) = @_;

            if ($err) {
                undef $fetchPage;
                $cb->(undef, $err);
                return;
            }

            push @accumulated, @{ $items || [] };

            my $isRepeatedToken = defined($nextPageToken) && length($nextPageToken)
                && defined($pageToken) && length($pageToken)
                && $nextPageToken eq $pageToken;

            if ($isRepeatedToken) {
                $log->warn("SpClient: _collectionAll saw a repeated next_page_token for set=$set"
                    . ' -- treating as end-of-list (WR-03)');
                undef $fetchPage;
                $cache->set($cacheKey, \@accumulated, COLLECTION_LIST_TTL);
                $cb->(\@accumulated, undef);
                return;
            }

            if (defined $nextPageToken && length $nextPageToken) {
                $fetchPage->($nextPageToken);
            } else {
                undef $fetchPage;
                $cache->set($cacheKey, \@accumulated, COLLECTION_LIST_TTL);
                $cb->(\@accumulated, undef);
            }
        });
    };
    $fetchPage->(undef);
}

# _sliceAsPage($class, \@list, $offset, $limit)
# Offset/limit slice of an already-complete in-memory list. Returns
# (\@slice, $total) -- $total is always the FULL list length, matching the
# Web-API pagination contract callers expect (offset/limit against a known
# total) even though spclient itself delivered the whole list, not a page.
sub _sliceAsPage {
    my ($class, $list, $offset, $limit) = @_;
    $list ||= [];
    my $total = scalar @$list;
    my $end   = $offset + $limit - 1;
    $end = $total - 1 if $end > $total - 1;
    my @slice = ($offset < $total && $offset <= $end) ? @$list[$offset .. $end] : ();
    return (\@slice, $total);
}

# _enrichCollectionSlice($class, $accountId, \@slice, $metaType, $normalizeMethod, $wrapKey, $cb)
# Fetches metadata/4/$metaType/{hex} for each { uri, added_at } slice entry
# (THROUGH _request, so the cap-2 gate and 3600s response cache apply --
# D-09) and re-pairs each successful result with its ORIGINAL added_at
# (order-preserving pairing, unlike _enrichMeta's plain id-in/object-out
# shape which would lose the added_at association). Failed/undef
# normalizations are dropped. cb->(\@items) where each item is
# { added_at => ..., $wrapKey => $normalizedObject }.
sub _enrichCollectionSlice {
    my ($class, $accountId, $slice, $metaType, $normalizeMethod, $wrapKey, $cb) = @_;
    $slice ||= [];

    unless (@$slice) {
        $cb->([]);
        return;
    }

    my @results   = (undef) x scalar(@$slice);
    my $remaining = scalar @$slice;

    for my $i (0 .. $#$slice) {
        my $entry = $slice->[$i];
        my ($id)  = ($entry->{uri} // '') =~ /^spotify:\Q$metaType\E:(.+)$/;
        my $hexId = $id ? $class->idToHex($id) : undef;

        # CR-01: substitute a minimal stub (re-paired with the original
        # added_at) instead of dropping the slot on failure -- identical
        # discipline to _enrichMeta above, keeping scalar(@results) ==
        # scalar(@$slice) always.
        my $stub = { id => $id, uri => ($entry->{uri} // "spotify:$metaType:"), name => undef };

        my $finish = sub {
            my ($val) = @_;
            $results[$i] = { added_at => $entry->{added_at}, $wrapKey => ($val || $stub) };
            if (--$remaining == 0) {
                $cb->(\@results);
            }
        };

        unless ($hexId) {
            $finish->(undef);
            next;
        }

        $class->_request('get', "metadata/4/$metaType/$hexId", {
            _accountId => $accountId,
            _accept    => 'application/json',
        }, sub {
            my ($result, $err) = @_;
            $finish->($err ? undef : $class->$normalizeMethod($result));
        });
    }
}

# getSavedAlbums($class, $accountId, $params, $cb)
# cb->({ items => [...], total }) or cb->(undef, $err). Saved Albums live under the
# collection/v2 set 'collection' (S-07 -- the intuitive name 'album' 403s).
# Full list is fetched/cached once (_collectionAll), then only the
# requested offset/limit slice is enriched with real album metadata
# (D-09 burst avoidance).
sub getSavedAlbums {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getSavedAlbums without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    $class->_collectionAll($accountId, SET_MAP->{albums}, sub {
        my ($list, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my @albumsOnly = grep { ($_->{uri} // '') =~ /^spotify:album:/ } @$list;
        my ($slice, $total) = $class->_sliceAsPage(\@albumsOnly, $offset, $limit);

        $class->_enrichCollectionSlice($accountId, $slice, 'album', '_normalizeAlbum', 'album', sub {
            my ($items) = @_;
            $cb->({
                items  => $items,
                total  => $total,
                offset => $offset,
                limit  => $limit,
                next   => (($offset + $limit) < $total) ? 1 : undef,
            });
        });
    });
}

# ============================================================
# getFollowedArtists + getSavedShows (Phase 75 Plan 04 Task 2)
# ============================================================

# getFollowedArtists($class, $accountId, $params, $cb)
# Web-API's /me/following is cursor-based (Pitfall 4); collection/v2's
# 'artist' set is a plain list. This emulates the cursor contract
# _fetchAllFollowedArtists actually consumes (loops on cursors.after until
# empty/absent): $params->{after} is treated as the URI-derived id of the
# LAST artist returned by the previous call -- its position is resolved in
# the cached full list and iteration continues from position+1. An absent
# `after` starts from the beginning.
sub getFollowedArtists {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $limit = $params->{limit} // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getFollowedArtists without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    $class->_collectionAll($accountId, SET_MAP->{artists}, sub {
        my ($list, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        $list ||= [];
        my @artistsOnly = grep { ($_->{uri} // '') =~ /^spotify:artist:/ } @$list;
        $list = \@artistsOnly;
        my $startIdx = 0;
        if (defined $params->{after} && length $params->{after}) {
            my $afterUri = 'spotify:artist:' . $params->{after};
            my $pos = -1;
            for my $i (0 .. $#$list) {
                if (($list->[$i]{uri} // '') eq $afterUri) {
                    $pos = $i;
                    last;
                }
            }
            # Cursor not found (stale/foreign cursor) -- treat as exhausted
            # rather than restarting from the beginning (avoids duplicate
            # items on a stale cursor).
            $startIdx = ($pos >= 0) ? $pos + 1 : scalar(@$list);
        }

        my $end = $startIdx + $limit - 1;
        $end = $#$list if $end > $#$list;
        my @slice = ($startIdx <= $end && $startIdx < scalar(@$list)) ? @$list[$startIdx .. $end] : ();

        my @artistIds = map { /^spotify:artist:(.+)$/ ? $1 : () } map { $_->{uri} } @slice;

        $class->_enrichMeta($accountId, \@artistIds, 'artist', '_normalizeArtist', sub {
            my ($artists) = @_;

            my $hasMore = ($startIdx + scalar(@slice)) < scalar(@$list);
            my $afterCursor;
            if ($hasMore && @slice) {
                ($afterCursor) = (($slice[-1]{uri} // '')) =~ /^spotify:artist:(.+)$/;
            }

            $cb->({
                artists => {
                    items   => $artists,
                    total   => scalar(@$list),
                    cursors => { after => $afterCursor },
                },
            });
        });
    });
}

# getSavedShows($class, $accountId, $params, $cb)
# Same offset/limit contract as the other saved-collection feeds. Saved Shows
# live under the collection/v2 set 'show' (S-07). The requested slice is
# enriched with metadata/4/show per item through _enrichCollectionSlice; an
# item whose metadata fetch fails keeps its slot as a minimal id/uri stub
# (CR-01), so one broken show never hides the others and there is no second
# transport to hand the whole call to (85-15, D-01).
sub getSavedShows {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getSavedShows without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    # WR-02: honor $params->{_noCache} (Plugin.pm:2088's call shape) --
    # bypasses (without disabling) the 60s collection/v2 list cache on
    # demand.
    $class->_collectionAll($accountId, SET_MAP->{shows}, sub {
        my ($list, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my @showsOnly = grep { ($_->{uri} // '') =~ /^spotify:show:/ } @$list;
        my ($slice, $total) = $class->_sliceAsPage(\@showsOnly, $offset, $limit);

        unless (@$slice) {
            $cb->({ items => [], total => $total, offset => $offset, limit => $limit });
            return;
        }

        $class->_enrichCollectionSlice($accountId, $slice, 'show', '_normalizeShow', 'show', sub {
            my ($items) = @_;
            $cb->({ items => $items, total => $total, offset => $offset, limit => $limit });
        });
    }, $params->{_noCache});
}

# ============================================================
# getSavedTracks (Liked Songs, no paging) + getRecentlyPlayed (S-09)
# Phase 75 Plan 04 Task 3
# ============================================================

# _likedSongsUris($class, $accountId, $cb)
# Fetches (and caches 60s per account) the FULL Liked Songs URI list via
# context-resolve/v1/spotify:user:{username}:collection -- the headline
# spclient win: ALL liked tracks in one response, no Spotify-side 50-item
# paging (unlike Web API's /me/tracks). username comes from
# verifyCredentials (_username), NEVER prefs spotifyUserId (A5).
sub _likedSongsUris {
    my ($class, $accountId, $cb) = @_;

    my $cacheKey = "spoton_spclient_liked_${accountId}";
    if (my $cached = $cache->get($cacheKey)) {
        $cb->($cached, undef);
        return;
    }

    my $username = $class->_username($accountId);
    unless ($username) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $path = 'context-resolve/v1/spotify:user:' . uri_escape_utf8($username) . ':collection';

    $class->_request('get', $path, {
        _accountId => $accountId,
        _accept    => 'application/json',
        _noCache   => 1,   # this module owns the 60s list-level cache below
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my @uris;
        if ($result && ref($result) eq 'HASH' && ref($result->{pages}) eq 'ARRAY') {
            for my $page (@{ $result->{pages} }) {
                push @uris, map { $_->{uri} }
                            grep { ref($_) eq 'HASH' && $_->{uri} }
                            @{ (ref($page) eq 'HASH' ? $page->{tracks} : []) || [] };
            }
        }

        $cache->set($cacheKey, \@uris, LIKED_SONGS_LIST_TTL);
        $cb->(\@uris, undef);
    });
}

# getSavedTracks($class, $accountId, $params, $cb)
# cb contract: ({ items => [{track=>...}],
# total, offset, limit }, matching _normalizeLibraryItem/_savedTracksFeed's
# consumption). Decision (recorded per plan): NO play-all-specific shortcut
# -- _savedTracksFeed's play-all branch calls this SAME method repeatedly
# via _fetchAllPages with successive offset/limit windows and feeds every
# page through _trackItem, which needs full track fields (name/artists/
# album/duration_ms), not just uri+id. The already-complete URI list
# (_likedSongsUris, cached 60s) makes every page just a slice + enrichment
# call -- no repeated Spotify-side pagination regardless of mode.
sub getSavedTracks {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getSavedTracks without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    $class->_likedSongsUris($accountId, sub {
        my ($uris, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my ($slice, $total) = $class->_sliceAsPage($uris, $offset, $limit);
        my @trackIds = map { /^spotify:track:(.+)$/ ? $1 : () } @$slice;

        $class->_enrichTracks($accountId, \@trackIds, sub {
            my ($tracks) = @_;
            my @items = map { { track => $_ } } @$tracks;
            $cb->({
                items  => \@items,
                total  => $total,
                offset => $offset,
                limit  => $limit,
                next   => (($offset + $limit) < $total) ? 1 : undef,
            });
        });
    });
}

# getRecentlyPlayed($class, $accountId, $params, $cb)
# recently-played/v3 is protobuf-ONLY (S-09 -- Accept: application/json has
# no effect). Decoded via ProtobufLite as a flat RecentlyPlayed message
# (repeated Context contexts=1; each Context: uri=1, lastPlayedTime=2
# int64/varint -- recently_played_backend.proto). The endpoint mixes track/
# album/playlist/artist/show/episode contexts; only spotify:track: URIs are
# kept (Plugin.pm's _recentlyPlayedFeed renders tracks only). username comes
# from verifyCredentials (_username), NEVER prefs (A5).
sub getRecentlyPlayed {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $limit = $params->{limit} // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getRecentlyPlayed without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $username = $class->_username($accountId);
    unless ($username) {
        main::INFOLOG && $log->info('SpClient: getRecentlyPlayed without a credentials username');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $path = 'recently-played/v3/user/' . uri_escape_utf8($username) . '/recently-played';

    $class->_request('get', $path, {
        _accountId => $accountId,
        _accept    => RECENTLY_PLAYED_ACCEPT,
        _raw       => 1,
        _noCache   => 1,
    }, sub {
        my ($raw, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($raw);
        unless ($fields) {
            main::INFOLOG && $log->info('SpClient: getRecentlyPlayed protobuf parse failure (T-75-12)');
            $cb->(undef, { error => 'parse_error' });
            return;
        }

        my @trackUris;
        my %lastPlayed;
        for my $ctxBytes (@{ $fields->{1} || [] }) {
            my $ctxFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($ctxBytes);
            next unless $ctxFields;

            # 85-16 (live finding): the real entry is { 1 = CONTEXT uri (playlist/album/artist), 2 = played-at
            # ms, 3 = the TRACK uri }. Reading only field 1 matched no entry on live data, so Home > Recently
            # Played was empty (the Client.pm hand-over of 85-15 had hidden it). Field 3 first; a track URI
            # in field 1 (the layout the Phase 75 fixture modelled) stays accepted.
            my $uri = Plugins::SpotOn::API::ProtobufLite::field_first($ctxFields, 3);
            $uri = Plugins::SpotOn::API::ProtobufLite::field_first($ctxFields, 1)
                unless $uri && $uri =~ /^spotify:track:/;
            next unless $uri && $uri =~ /^spotify:track:/;

            push @trackUris, $uri;
            $lastPlayed{$uri} = Plugins::SpotOn::API::ProtobufLite::field_first($ctxFields, 2);
        }

        my $end = $limit - 1;
        $end = $#trackUris if $end > $#trackUris;
        my @sliceUris = (@trackUris && $end >= 0) ? @trackUris[0 .. $end] : ();

        unless (@sliceUris) {
            $cb->({ items => [] });
            return;
        }

        # Pair each enriched track with its ORIGINAL request uri's
        # lastPlayedTime (not the enriched object's own uri, which may be a
        # canonicalized/relinked uri that differs from the recently-played
        # context's uri) -- order-preserving, individual-failure-tolerant,
        # same shape discipline as _enrichCollectionSlice.
        my @results   = (undef) x scalar(@sliceUris);
        my $remaining = scalar @sliceUris;

        for my $i (0 .. $#sliceUris) {
            my $uri   = $sliceUris[$i];
            my ($id)  = $uri =~ /^spotify:track:(.+)$/;
            my $hexId = $id ? $class->idToHex($id) : undef;

            my $finish = sub {
                my ($val) = @_;
                $results[$i] = $val ? { track => $val, played_at => $lastPlayed{$uri} } : undef;
                if (--$remaining == 0) {
                    $cb->({ items => [ grep { defined } @results ] });
                }
            };

            unless ($hexId) {
                $finish->(undef);
                next;
            }

            $class->_request('get', "metadata/4/track/$hexId", {
                _accountId => $accountId,
                _accept    => 'application/json',
            }, sub {
                my ($result, $err) = @_;
                $finish->($err ? undef : $class->_normalizeTrack($result));
            });
        }
    });
}

# ============================================================
# getUserPlaylists (rootlist, protobuf-only, S-10)
# Phase 75 Plan 05 Task 1
# ============================================================

# _rootlistPlaylists($class, $accountId, $cb)
# Fetches (and caches 60s per account -- CLAUDE.md's library-item-list tier)
# the user's FULLY FLATTENED playlist library via the protobuf-only
# rootlist endpoint (S-10 measured "Accept has no effect, always protobuf";
# the live server of 2026-10-17 answers Accept: application/json with a JSON
# body, so the request names protobuf explicitly -- 85-16). cb->(\@playlists, undef) on success,
# cb->(undef, $err) on a request-level OR protobuf-parse failure (the
# latter reported as {error=>'parse_error'} -- T-75-12, never a crash on
# malformed bytes).
sub _rootlistPlaylists {
    my ($class, $accountId, $cb) = @_;

    my $cacheKey = "spoton_spclient_rootlist_${accountId}";
    if (my $cached = $cache->get($cacheKey)) {
        $cb->($cached, undef);
        return;
    }

    my $username = $class->_username($accountId);
    unless ($username) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $path = 'playlist/v2/user/' . uri_escape_utf8($username) . '/rootlist?decorate=' . ROOTLIST_DECORATE;

    $class->_request('get', $path, {
        _accountId => $accountId,
        # 85-16: the server honours Accept here after all -- application/json gets a (gzip) JSON body
        # that _parseRootlist cannot read (parse_error, an empty Library -> Playlists). Ask for protobuf.
        _accept    => PROTOBUF_CONTENT_TYPE,
        _raw       => 1,
        _noCache   => 1,   # this module owns the 60s list-level cache below
    }, sub {
        my ($raw, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my $playlists = $class->_parseRootlist($raw);
        unless ($playlists) {
            $cb->(undef, { error => 'parse_error' });
            return;
        }

        $cache->set($cacheKey, $playlists, ROOTLIST_LIST_TTL);
        $cb->($playlists, undef);
    });
}

# _parseRootlist($class, $bytes)
# Decodes the rootlist response. The live server wraps the actual item list
# in field 5 (ListContent), NOT in field 1 (which is a 24-byte revision
# hash). Items are flat in field 5.3 (each with URI in sub-field 1);
# decorated metadata is in field 5.4 (name in .2.1, owner in .5, length
# in .3), paired by index. Returns undef on parse failure; an absent or
# empty item list returns an empty arrayref.
sub _parseRootlist {
    my ($class, $bytes) = @_;

    my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($bytes);
    return undef unless $fields;

    my $listBytes = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 5);
    return [] unless defined $listBytes;

    my $listFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($listBytes);
    return [] unless $listFields;

    my @items       = @{ $listFields->{3} || [] };
    my @decorations = @{ $listFields->{4} || [] };

    my @playlists;
    for my $i (0 .. $#items) {
        my $itemFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($items[$i]);
        next unless $itemFields;

        my $uri = Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 1);
        next unless defined $uri && $uri =~ /^spotify:playlist:(.+)$/;
        my $id = $1;

        my ($name, $ownerUsername, $trackCount);
        if ($i <= $#decorations) {
            my $decoFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($decorations[$i]);
            if ($decoFields) {
                $ownerUsername = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 5);
                $trackCount   = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 3);
                if (defined(my $attrBytes = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 2))) {
                    my $attrFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($attrBytes);
                    $name = Plugins::SpotOn::API::ProtobufLite::field_first($attrFields, 1) if $attrFields;
                }
            }
        }

        # 85-16: protobuf strings are UTF-8 bytes; decode them to characters like the JSON paths deliver
        # them, otherwise LMS shows "T\xc3\x83\xc2\xbcrk..." for names with umlauts.
        utf8::decode($name)          if defined $name;
        utf8::decode($ownerUsername) if defined $ownerUsername;

        push @playlists, {
            id     => $id,
            uri    => $uri,
            name   => $name // '',
            owner  => $ownerUsername ? { display_name => $ownerUsername } : undef,
            tracks => { total => $trackCount // 0 },
            images => [],
        };
    }

    return \@playlists;
}

# _normalizePlaylistMeta($class, $plBytes)
# Decodes a single Playlist message (row_id=1, playlist_metadata=2) into a
# Web-API-shaped playlist stub: { id, uri, name, owner, images }. The
# decorated PlaylistMetadata submessage carries link(1)/name(2)/owner(3);
# owner is a User submessage (username=2/display_name=3). Prefers
# PlaylistMetadata.link as the canonical URI source (Spotify's own
# spotify:playlist:{id} convention) and falls back to row_id -- either
# already a full spotify:playlist: URI, or a bare base62 id to derive one
# from. Degrades to undef (dropped by the caller) only if NEITHER yields
# anything usable, never dies on missing/malformed submessages (Pitfall 6).
sub _normalizePlaylistMeta {
    my ($class, $plBytes) = @_;

    my $plFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($plBytes);
    return undef unless $plFields;

    my $rowId     = Plugins::SpotOn::API::ProtobufLite::field_first($plFields, 1);   # Playlist.row_id
    my $metaBytes = Plugins::SpotOn::API::ProtobufLite::field_first($plFields, 2);   # Playlist.playlist_metadata

    my ($link, $name, $ownerUsername, $ownerDisplayName);
    if (defined $metaBytes) {
        my $metaFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($metaBytes);
        if ($metaFields) {
            $link = Plugins::SpotOn::API::ProtobufLite::field_first($metaFields, 1);   # PlaylistMetadata.link
            $name = Plugins::SpotOn::API::ProtobufLite::field_first($metaFields, 2);   # PlaylistMetadata.name

            if (defined(my $ownerBytes = Plugins::SpotOn::API::ProtobufLite::field_first($metaFields, 3))) {   # PlaylistMetadata.owner
                my $ownerFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($ownerBytes);
                if ($ownerFields) {
                    $ownerUsername    = Plugins::SpotOn::API::ProtobufLite::field_first($ownerFields, 2);   # User.username
                    $ownerDisplayName = Plugins::SpotOn::API::ProtobufLite::field_first($ownerFields, 3);   # User.display_name
                }
            }
        }
    }

    my $uri;
    for my $candidate ($link, $rowId) {
        next unless defined $candidate && length $candidate;
        if ($candidate =~ /^spotify:playlist:/) {
            $uri = $candidate;
            last;
        }
    }
    unless ($uri) {
        return undef unless defined $rowId && length $rowId;
        $uri = "spotify:playlist:$rowId";
    }

    my ($id) = $uri =~ /^spotify:playlist:(.+)$/;

    return {
        id     => $id,
        uri    => $uri,
        name   => $name // '',
        owner  => $ownerUsername ? { display_name => $ownerDisplayName // $ownerUsername } : undef,
        images => [],
    };
}

# getUserPlaylists($class, $accountId, $params, $cb)
# cb contract: ({ items => [...], total, offset, limit }) or (undef, $err).
# No login5-capable creds -> no_credentials (D-06). A rootlist request/parse
# failure (including the dedicated parse_error case, T-75-12) is passed
# through to the caller unchanged.
sub getUserPlaylists {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getUserPlaylists without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    $class->_rootlistPlaylists($accountId, sub {
        my ($playlists, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my ($slice, $total) = $class->_sliceAsPage($playlists, $offset, $limit);
        $cb->({ items => $slice, total => $total, offset => $offset, limit => $limit });
    });
}

# ============================================================
# getPlaylistItems (playlist/v2, JSON) with sliced enrichment
# Phase 75 Plan 05 Task 2
# ============================================================

# _playlistEnvelope($class, $accountId, $playlistId, $cb)
# Fetches (and caches 300s per account+playlist -- CLAUDE.md's playlist-
# tracks tier) the FULL playlist/v2 envelope: { revision, length,
# attributes, contents: { items: [{uri, attributes}, ...] } }. Unlike
# rootlist, playlist/v2/playlist/{id} honors Accept: application/json
# (spike RESULTS.md S-10 note). cb->($envelope, undef) on success,
# cb->(undef, $err) on a request-level failure -- errors bubble up
# unclassified for the caller to apply D-07.
sub _playlistEnvelope {
    my ($class, $accountId, $playlistId, $cb) = @_;

    my $cacheKey = "spoton_spclient_plenv_${accountId}_${playlistId}";
    if (my $cached = $cache->get($cacheKey)) {
        $cb->($cached, undef);
        return;
    }

    $class->_request('get', "playlist/v2/playlist/$playlistId", {
        _accountId => $accountId,
        _accept    => 'application/json',
        _noCache   => 1,   # this module owns the 300s envelope cache below
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        $cache->set($cacheKey, $result, PLAYLIST_ENVELOPE_TTL);
        $cb->($result, undef);
    });
}

# getPlaylistItems($class, $accountId, $playlistId, $params, $cb)
# 5-arg shape, INCLUDING the plain params-hashref variant
# ProtocolHandler.pm's explodePlaylist uses (no distinct opts arg). The
# playlist/v2 envelope
# (cached 300s) carries contents.items[] with track URIs but NO track
# names (mirrors S-04's album-tracks limitation) -- only the requested
# offset/limit slice is enriched via _enrichTracks (lazy, D-09), riding the
# shared 3600s track cache. Result shape { items => [{track=>...}], total,
# offset, limit, next } is identical to getSavedTracks -- a superset of
# what ProtocolHandler's resolution path needs (uri/id) and exactly what
# _playlistFeed/_trackItem consume.
sub getPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 100;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getPlaylistItems without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    # WR-04: unlike track/album/artist/show/episode ids (converted via
    # idToHex), playlist ids are used directly as base62 in the spclient URL
    # path -- validate charset/length BEFORE _playlistEnvelope ever splices
    # $playlistId into the request path or the cache key, so a malformed or
    # user-influenced value (LMS favorites URLs, CLI playlist args, OPML
    # passthrough params) can never redirect the request or pollute the
    # cache-key namespace.
    unless (defined $playlistId && $playlistId =~ /^[0-9A-Za-z]{22}$/) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_playlistEnvelope($accountId, $playlistId, sub {
        my ($envelope, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my @contentItems = ($envelope && ref($envelope) eq 'HASH' && ref($envelope->{contents}) eq 'HASH')
            ? @{ $envelope->{contents}{items} || [] } : ();
        my @uris = map { $_->{uri} } grep { ref($_) eq 'HASH' && $_->{uri} } @contentItems;

        # CR-01: filter to track URIs BEFORE slicing (non-track playlist
        # entries -- episodes, local files -- must never be sliced into the
        # window or counted toward total), and derive $total from
        # _sliceAsPage's count of the FILTERED list so window arithmetic and
        # `total` always agree -- restores the offset-advance-by-
        # returned-count contract every caller (_fetchPages/_albumFeed
        # play-all/explodePlaylist) depends on.
        my @trackUris = grep { /^spotify:track:/ } @uris;
        my ($sliceUris, $total) = $class->_sliceAsPage(\@trackUris, $offset, $limit);
        my @trackIds = map { /^spotify:track:(.+)$/ ? $1 : () } @$sliceUris;

        $class->_enrichTracks($accountId, \@trackIds, sub {
            my ($tracks) = @_;
            my @items = map { { track => $_ } } @$tracks;
            $cb->({
                items  => \@items,
                total  => $total,
                offset => $offset,
                limit  => $limit,
                next   => (($offset + $limit) < $total) ? 1 : undef,
            });
        });
    });
}

# ============================================================
# Pathfinder-backed feeds and removed Web-API methods
# ============================================================
# 85-15 (D-01, D-08): the former Web-API-only passthroughs are gone. getMe
# (a plain /me profile fetch; the display name comes from getDisplayName) and
# getPersonalMixes (browse/categories, D-08) have no caller and no spclient
# equivalent -- they were deleted together with API/Client.pm. The Pathfinder
# paths (getTopTracks, search, getMadeForYou) are native SpClient subs.
# The page limits are the fixed PAGE_LIMITS constant (85-09, D-12).

# getTopTracks($class, $accountId, $params, $cb)
# 85-08 (decision-D07 pathfinder): Spotify's own ranking from the Pathfinder
# userTopContent op with SpotOn's login5 bearer, cookie-free. $params: time_range (short_term | medium_term |
# long_term), limit (<= 50), offset. cb->({ items => [track...], total }) with
# every track in the Web-API shape, or cb->(undef, $err).
sub getTopTracks {
    my ($class, $accountId, $params, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;
    Plugins::SpotOn::API::Pathfinder->topTracks($accountId, $params, $cb);
    return;
}

# ============================================================
# D-14 library writes over collection/v2 (Phase 85 plan 85-05)
# ============================================================
# Account-modifying requests: ALL go through _request (central throttle,
# P-01, own rate key, 2 in flight, 429 backoff). The username only ever comes
# from credentials.json (_username), is only placed inside the protobuf body
# and is never logged. An empty 200 body is success: cb->(undef, undef).

# _validItemUri($uri) -- canonical spotify:<type>:<base62 id> only; anything
# else would be sent verbatim into the account write.
sub _validItemUri {
    my ($uri) = @_;
    return (defined $uri && !ref($uri) && $uri =~ /\Aspotify:[a-z]{1,16}:[A-Za-z0-9]{1,40}\z/) ? 1 : 0;
}

# _collectionWrite($class, $accountId, $set, $uris, $remove, $cb)
# WriteRequest{username=1, set=2, items=3 CollectionItem{uri=1, added_at=2
# (add only), is_removed=3 (remove only)}}.
sub _collectionWrite {
    my ($class, $accountId, $set, $uris, $remove, $cb) = @_;

    my $username = $class->_username($accountId);
    unless ($username) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }
    unless (ref($uris) eq 'ARRAY' && @$uris && !grep { !_validItemUri($_) } @$uris) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    my $now  = time();
    my $body = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $username)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $set);
    for my $uri (@$uris) {
        my $item = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $uri);
        $item .= $remove
            ? Plugins::SpotOn::API::ProtobufLite::encode_field(3, 0, 1)
            : Plugins::SpotOn::API::ProtobufLite::encode_field(2, 0, $now);
        $body .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $item);
    }

    $class->_request('post', 'collection/v2/write', {
        _accountId   => $accountId,
        _accept      => COLLECTION_V2_CONTENT_TYPE,
        _contentType => COLLECTION_V2_CONTENT_TYPE,
        _body        => $body,
        _raw         => 1,
        _noCache     => 1,
    }, sub {
        my ($raw, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $cb->(undef, undef);
    });
}

# _collectionContains($class, $accountId, $set, $uris, $cb)
# ContainsRequest{username=1, set=2, items=3{uri=1}} -> cb->(\@bool, undef)
# with one 0/1 per requested uri, or cb->(undef, $err).
sub _collectionContains {
    my ($class, $accountId, $set, $uris, $cb) = @_;

    my $username = $class->_username($accountId);
    unless ($username) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }
    unless (ref($uris) eq 'ARRAY' && @$uris && !grep { !_validItemUri($_) } @$uris) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    my $body = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $username)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $set);
    for my $uri (@$uris) {
        $body .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2,
            Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $uri));
    }
    my $expected = scalar @$uris;

    $class->_request('post', 'collection/v2/contains', {
        _accountId   => $accountId,
        _accept      => COLLECTION_V2_CONTENT_TYPE,
        _contentType => COLLECTION_V2_CONTENT_TYPE,
        _body        => $body,
        _raw         => 1,
        _noCache     => 1,   # callers (Plugin.pm) own the 60s state cache
    }, sub {
        my ($raw, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $found = _decodeContains($raw, $expected);
        unless ($found) {
            $cb->(undef, { error => 'parse_error' });
            return;
        }
        $cb->($found, undef);
    });
}

# _decodeContains($raw, $expected)
# ContainsResponse{found=1 repeated bool}. proto3 normally packs the bools
# (measured in the 85-03 D14 spike: "0a 01 00" for one answer) -- one
# length-delimited field 1 whose bytes are the 0/1 values; unpacked repeated
# varints are accepted as well. The answer count MUST equal the request
# count. Returns an arrayref of 0/1, or undef -- never dies (spclient bytes
# are untrusted).
sub _decodeContains {
    my ($raw, $expected) = @_;
    return undef unless defined $raw && defined $expected && $expected > 0;

    my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($raw);
    return undef unless $fields;

    my @found;
    for my $v (@{ $fields->{1} || [] }) {
        if ($v =~ /\A\d+\z/) {                       # unpacked: plain varint
            push @found, ($v ? 1 : 0);
        }
        else {                                       # packed: one byte per bool
            for my $byte (split //, $v) {
                my $n = ord($byte);
                return undef if $n > 1;
                push @found, $n;
            }
        }
        return undef if @found > 1000;
    }
    return @found == $expected ? \@found : undef;
}

# Liked Songs: tracks live in the collection/v2 set 'collection'
# (SET_MAP->{liked_tracks}). The list cache is dropped before AND after the
# write so neither an in-flight list fetch nor a late callback can leave a
# stale list (WR-02: visible on the very next getSavedTracks).
sub saveTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    return $class->_trackWrite($accountId, $uris, 0, $cb);
}

sub removeTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    return $class->_trackWrite($accountId, $uris, 1, $cb);
}

sub _trackWrite {
    my ($class, $accountId, $uris, $remove, $cb) = @_;
    my $key = "spoton_spclient_liked_${accountId}";
    $cache->remove($key) if defined $accountId;
    $class->_collectionWrite($accountId, SET_MAP->{liked_tracks}, $uris, $remove, sub {
        $cache->remove($key) if defined $accountId;
        $cb->(@_);
    });
}

sub checkTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    return $class->_collectionContains($accountId, SET_MAP->{liked_tracks}, $uris, $cb);
}

# Shows: collection/v2 set 'show' (SET_MAP->{shows}); the Saved Shows list
# cache is dropped before AND after the write (WR-02).
sub saveShows {
    my ($class, $accountId, $uris, $cb) = @_;
    return $class->_showWrite($accountId, $uris, 0, $cb);
}

sub removeShows {
    my ($class, $accountId, $uris, $cb) = @_;
    return $class->_showWrite($accountId, $uris, 1, $cb);
}

sub _showWrite {
    my ($class, $accountId, $uris, $remove, $cb) = @_;
    my $key = "spoton_spclient_coll_${accountId}_" . SET_MAP->{shows};
    $cache->remove($key) if defined $accountId;
    $class->_collectionWrite($accountId, SET_MAP->{shows}, $uris, $remove, sub {
        $cache->remove($key) if defined $accountId;
        $cb->(@_);
    });
}

sub checkShows {
    my ($class, $accountId, $uris, $cb) = @_;
    return $class->_collectionContains($accountId, SET_MAP->{shows}, $uris, $cb);
}

# ------------------------------------------------------------
# Add to playlist: revision read + ListChanges ADD (D-14)
# ------------------------------------------------------------

# _validPlaylistId($id) -- same shape the Web-API wrapper enforced.
sub _validPlaylistId {
    my ($id) = @_;
    return (defined $id && !ref($id) && $id =~ /\A[A-Za-z0-9]{1,40}\z/) ? 1 : 0;
}

# _playlistRevision($class, $accountId, $playlistId, $cb)
# GET playlist/v2/playlist/<id>?decorate=revision&from=0&length=1 WITHOUT a
# JSON Accept (protobuf SelectedListContent; revision = field 1, bytes).
# cb->($revisionBytes, undef) | cb->(undef, $err).
sub _playlistRevision {
    my ($class, $accountId, $playlistId, $cb) = @_;

    $class->_request('get', "playlist/v2/playlist/$playlistId?decorate=revision&from=0&length=1", {
        _accountId => $accountId,
        _accept    => PROTOBUF_CONTENT_TYPE,
        _raw       => 1,
        _noCache   => 1,
    }, sub {
        my ($raw, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $fields   = Plugins::SpotOn::API::ProtobufLite::parse_fields($raw);
        my $revision = $fields ? Plugins::SpotOn::API::ProtobufLite::field_first($fields, 1) : undef;
        unless (defined $revision && length $revision) {
            $cb->(undef, { error => 'parse_error' });
            return;
        }
        $cb->($revision, undef);
    });
}

# _playlistChanges($class, $accountId, $playlistId, $revision, $uris, $cb)
# POST playlist/v2/playlist/<id>/changes, ListChanges{base_revision=1,
# deltas=2 Delta{ops=2 Op{kind=1 (ADD=2), add=2 Add{items=2{uri=1},
# add_last=4}}, info=4 ChangeInfo{user=1, timestamp=2 (ms)}}}.
# cb->(undef, undef) on success | cb->(undef, $err). NEVER retries itself:
# a replayed change would add the track twice.
sub _playlistChanges {
    my ($class, $accountId, $playlistId, $revision, $uris, $cb) = @_;

    my $username = $class->_username($accountId);
    unless ($username) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $add = '';
    for my $uri (@$uris) {
        $add .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2,
            Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $uri));
    }
    $add .= Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 1);                     # add_last

    my $op   = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 0, 2)                   # kind = ADD
             . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $add);
    my $info = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $username)
             . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 0, int(Time::HiRes::time() * 1000));
    my $delta = Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $op)
              . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 2, $info);
    my $body  = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $revision)
              . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $delta);

    $class->_request('post', "playlist/v2/playlist/$playlistId/changes", {
        _accountId   => $accountId,
        _accept      => '*/*',
        _contentType => PROTOBUF_CONTENT_TYPE,
        _body        => $body,
        _raw         => 1,
        _noCache     => 1,
    }, sub {
        my ($raw, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $cb->(undef, undef);
    });
}

# addToPlaylist($class, $accountId, $playlistId, $uris, $cb)
# Callers keep the old ($result, $err) contract. 409 = the playlist moved
# between our revision read and the change: ONE re-read + ONE retry. 5xx and
# transport errors are never retried (non-idempotent, T-85-09).
sub addToPlaylist {
    my ($class, $accountId, $playlistId, $uris, $cb) = @_;

    unless (_validPlaylistId($playlistId)
        && ref($uris) eq 'ARRAY' && @$uris && !grep { !_validItemUri($_) } @$uris) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }
    $class->_addToPlaylistAttempt($accountId, $playlistId, $uris, 0, $cb);
}

sub _addToPlaylistAttempt {
    my ($class, $accountId, $playlistId, $uris, $retried, $cb) = @_;

    $class->_playlistRevision($accountId, $playlistId, sub {
        my ($revision, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $class->_playlistChanges($accountId, $playlistId, $revision, $uris, sub {
            my (undef, $cerr) = @_;
            if ($cerr) {
                if (!$retried && ref($cerr) eq 'HASH' && ($cerr->{code} || 0) == 409) {
                    $class->_addToPlaylistAttempt($accountId, $playlistId, $uris, 1, $cb);
                    return;
                }
                $cb->(undef, $cerr);
                return;
            }
            # The playlist envelope cache (300s) would hide the new item.
            $cache->remove("spoton_spclient_plenv_${accountId}_${playlistId}");
            $cb->(undef, undef);
        });
    });
}

# ============================================================
# Made for You on Pathfinder (85-08, decision-D17 pathfinder-login5-plus-rootlist)
# ============================================================
# Two homeSection queries (SECTION_MFY, then SECTION_TOPMIX) with SpotOn's own
# login5 bearer, cookie-free (API/Pathfinder.pm). When both sections fail or
# yield nothing, the Spotify-made spotify:playlist:37i9dQZ mixes of the user's
# rootlist are shown instead. DJ never appears on either path (not a playlist,
# spclient answers 404). No backend is consulted (D-20) and no browse/categories
# request is sent (D-08).

# getMadeForYou($class, $accountId, $cb)
# cb->({ items => [{ id, uri, name, images }, ...], source => 'pathfinder' |
# 'rootlist-fallback' }) or cb->(undef, $err). No login5 credentials answer
# (undef, { error => 'no_credentials' }) without a request.
sub getMadeForYou {
    my ($class, $accountId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;
    my $djUri    = Plugins::SpotOn::API::Pathfinder::DJ_URI();
    my @sections = (
        Plugins::SpotOn::API::Pathfinder::SECTION_MFY(),
        Plugins::SpotOn::API::Pathfinder::SECTION_TOPMIX(),
    );

    # Initialised BEFORE the first request: a callback may fire synchronously.
    my $remaining = scalar @sections;
    my (@got, @errs);

    my $finish = sub {
        my (@merged, %seen);
        for my $items (@got) {
            for my $it (@{ $items || [] }) {
                next unless ref($it) eq 'HASH';
                my $uri = $it->{uri};
                next if $uri eq $djUri;
                next unless ($it->{typename} // '') eq 'Playlist';
                next unless $uri =~ /\Aspotify:playlist:([A-Za-z0-9]{1,40})\z/;
                my $id = $1;
                next if $seen{$uri}++;
                push @merged, {
                    id     => $id,
                    uri    => $uri,
                    name   => (defined $it->{name} && length $it->{name}) ? $it->{name} : $id,
                    images => $it->{images} || [],
                };
            }
        }

        # WR-13: keep the reason a section failed. A Pathfinder answer that
        # merely carries no Playlist items is NOT a transport failure; the
        # status page and the menu must not blame the transport for it.
        my ($firstErr) = grep { $_ } @errs;
        my $pfFailed   = $firstErr ? 1 : 0;
        my $lastError  = $firstErr ? _plainError($firstErr) : undef;

        if (@merged) {
            %_mfy = (source => 'pathfinder', mixCount => scalar(@merged), lastError => $lastError);
            $cb->({ items => \@merged, source => 'pathfinder' });
            return;
        }

        # Pathfinder yielded nothing (D-17: the rootlist 37i9 mixes take over,
        # whether the sections failed or merely listed no playlists).
        %_mfy = (source => 'rootlist-fallback', mixCount => 0,
                 fallbackReason => ($pfFailed ? 'error' : 'empty'), lastError => $lastError);

        main::INFOLOG && $log->info('SpClient: Made for You -- Pathfinder yielded nothing, using the rootlist 37i9 mixes (D-17)');
        $class->_rootlistPlaylists($accountId, sub {
            my ($playlists, $err) = @_;
            if ($err || ref($playlists) ne 'ARRAY') {
                $cb->(undef, $err || { error => 'rootlist_failed' });
                return;
            }
            my @mixes;
            for my $pl (@$playlists) {
                next unless ref($pl) eq 'HASH' && defined $pl->{uri};
                next if $pl->{uri} eq $djUri;
                next unless $pl->{uri} =~ /\Aspotify:playlist:37i9dQZ[A-Za-z0-9]*\z/;
                next unless defined $pl->{id} && $pl->{id} =~ /\A[A-Za-z0-9]{1,40}\z/;
                push @mixes, {
                    id     => $pl->{id},
                    uri    => $pl->{uri},
                    name   => (defined $pl->{name} && length $pl->{name}) ? $pl->{name} : $pl->{id},
                    images => [],
                };
            }
            $_mfy{mixCount} = scalar(@mixes);
            # pathfinderError: the menu says "unreachable" only when Pathfinder
            # really failed; "no results" when it answered and nothing is saved.
            $cb->({ items => \@mixes, source => 'rootlist-fallback', pathfinderError => $pfFailed });
        });
    };

    for my $i (0 .. $#sections) {
        Plugins::SpotOn::API::Pathfinder->homeSection($accountId, $sections[$i], sub {
            my ($items, $err) = @_;
            $got[$i]  = $items;
            $errs[$i] = $err;    # WR-13: keep the reason
            $finish->() if --$remaining == 0;
        });
    }
    return;
}

# _plainError($err)
# WR-13: a short, plain reason out of an error hashref for the status page --
# [A-Za-z0-9_ .-] only, at most 60 characters; anything else is 'error'.
sub _plainError {
    my ($err) = @_;
    my $e = (ref($err) eq 'HASH') ? $err->{error} : $err;
    return 'error' unless defined $e && !ref($e) && $e =~ /\A[A-Za-z0-9_ .\-]{1,60}\z/;
    return $e;
}

# madeForYouStatus($class)
# The Made-for-You status contract for the status page (85-09), D-19:
# { source, hashState, fallbackActive, fallbackReason, lastError, mixCount,
# last412At, last401At, last403At, lastScrapeAt, opsMissing }. Nothing secret: no token, no username.
#   source         the decision-D17 id, constant
#   hashState      ok | broken | op_missing | unknown (Pathfinder health)
#   fallbackActive 1 when the last getMadeForYou answered from the rootlist
#   fallbackReason (WR-13) 'error' when a Pathfinder section failed, 'empty' when
#                  Pathfinder answered without Playlist items; undef otherwise
#   lastError      (WR-13) short plain reason of the last failed section, or undef
#   mixCount       how many mixes that last call listed
sub madeForYouStatus {
    my ($class) = @_;
    require Plugins::SpotOn::API::Pathfinder;
    my $h = Plugins::SpotOn::API::Pathfinder->healthSnapshot();
    return {
        source         => 'pathfinder-login5-plus-rootlist',
        hashState      => $h->{hashState},
        fallbackActive => (($_mfy{source} // '') eq 'rootlist-fallback') ? 1 : 0,
        mixCount       => $_mfy{mixCount} // 0,
        fallbackReason => (($_mfy{source} // '') eq 'rootlist-fallback') ? $_mfy{fallbackReason} : undef,
        lastError      => $_mfy{lastError},
        last412At      => $h->{last412At},
        last401At      => $h->{last401At},
        last403At      => $h->{last403At},
        lastScrapeAt   => $h->{lastScrapeAt},
        opsMissing     => [ @{ $h->{opsMissing} || [] } ],
    };
}

1;
