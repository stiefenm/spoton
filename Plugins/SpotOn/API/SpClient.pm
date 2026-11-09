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
# 79-61 (FULL-3 WR-05): after a confirmed 'unauthorized' (401 after the D-07a
# remint) the account's next 401s within this window are reported without a
# remint; a 2xx for the account lifts it. Kept in memory (no cache write per
# request); a restart forgets it, which only costs one D-07a remint.
use constant UNAUTH_MEMORY_TTL       => 60;
my %_unauthUntil;
sub _unauthMemory {
    my ($accountId) = @_;
    return 0 unless $accountId && $_unauthUntil{$accountId};
    return 1 if time() < $_unauthUntil{$accountId};
    delete $_unauthUntil{$accountId};
    return 0;
}
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

# 261110-k1b (#200): owners that are named without a lookup. Evidence: spike 016 raw libraryV3 data, user name
# spotify -> display name Spotify on 20 of 20 Spotify-owned playlists. A further entry only with its own measured
# evidence, one per entry. The account's own playlists are not in here (they compare against the user name).
use constant OWNER_FIXED_NAMES    => { spotify => 'Spotify' };

# 261110-k1b (#200): Library > Playlists gets its covers and owner display names from Pathfinder libraryV3 (50
# playlists per request) for the playlists the rootlist leaves without cover or with a foreign owner.
#   LIBRARY_LIST_*    merged list per account, the library-item-list tier (CLAUDE.md: 60 s)
#   PL_META_*         per playlist, key <id>_<rootlist revision hex or 'norev'>; the rootlist revision IS the libraryV3
#                     revisionId (measured on 96 of 96 matched playlists), so a changed playlist misses the key
#   OWNER_NAME_*      per owner user name; a name is kept 7 days, "no name" (negative) 1 day
#   LIBV3_PAGE_LIMIT  entries per libraryV3 page (the measured maximum)
#   LIBV3_MAX_PAGES   500 entries, the measured-safe bound per run
#   LIBV3_OFF_*       a structural libraryV3 failure (HTTP 400, errors[], unknown shape) pauses it for the account
#   LIBV3_BUDGET      261111-i1i: seconds from the first libraryV3 request until Library > Playlists is answered with what
#                     the pages read so far brought; the chain then runs on and fills only the caches
#   LIBV3_CAPPED_*    261111-j57: per account and playlist id, "never asked because the run stopped at LIBV3_MAX_PAGES";
#                     value { at => epoch of _libClock }, kept 24 h; it keeps the playlist from asking libraryV3 again. It
#                     carries no images key, so it is never read as a negative entry ("Spotify has nothing"). It is bound
#                     to the account on purpose (PL_META is not yet, GH #209)
use constant LIBRARY_LIST_KEY     => 'spoton_spclient_libpl_';
use constant LIBRARY_LIST_TTL     => 60;
use constant PL_META_KEY          => 'spoton_plmeta_';
use constant PL_META_TTL          => 86400;
use constant OWNER_NAME_KEY       => 'spoton_owner_name_';
use constant OWNER_NAME_TTL       => 7 * 86400;
use constant OWNER_NAME_NEG_TTL   => 86400;
use constant LIBV3_PAGE_LIMIT     => 50;
use constant LIBV3_MAX_PAGES      => 10;
use constant LIBV3_OFF_KEY        => 'spoton_libv3_off_';
use constant LIBV3_OFF_TTL        => 3600;
use constant LIBV3_RUN_STALE      => 300;   # a run older than this is not joined (a stuck run cannot block the account)
use constant LIBV3_BUDGET         => 10;
use constant LIBV3_WARN_INTERVAL  => 3600;   # at most one "libraryV3 answered HTTP 400" warning per hour
use constant LIBV3_CAPPED_KEY     => 'spoton_libv3_capped_';
use constant LIBV3_CAPPED_TTL     => 86400;
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

# 261110-is9: one Made for You run per account at a time. The first caller starts the run, a caller that arrives
# while it is still running only queues its callback ({ at => start time, cbs => [...] }); the one delivery
# answers every queued callback. Without it two menu openings during a cold build would start two runs (2 x 3
# Pathfinder requests and up to 2 x 13 name lookups, because the name cache is written when an answer arrives).
my %_mfyRuns;

# 261110-is9: when the last "item without a usable name" warning was written (unix time); the warning is
# process-wide and at most one per MFY_NAME_WARN_INTERVAL. reset() sets it back to 0.
my $_mfyNameWarnAt = 0;

# 261110-k1b: one libraryV3 merge per account at a time (account id -> { at => start time, cbs => [callbacks] });
# a second Library > Playlists opening during a cold run only queues its callback.
my %_libRuns;

# 261110-k1b: the last real libraryV3 run of any account, for libraryMetaStatus (the status page row). Plain values
# only: state (unknown | ok | fallback), at (epoch), since (start of the current fallback streak), reason, missing,
# skipped (261111-j57: the playlists in missing that lie beyond the libraryV3 page limit).
my %_libMeta = (state => 'unknown');
# when the last "libraryV3 answered HTTP 400" warning was written (epoch); at most one per LIBV3_WARN_INTERVAL
my $_libWarnAt;

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
    %_mfyRuns = ();
    $_mfyNameWarnAt = 0;
    %_libRuns = ();
    %_libMeta = (state => 'unknown');
    $_libWarnAt = undef;
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

# gate($class, $label, $run, $blocked) -- 79-61 (FULL-3 WR-03): the central
# spclient gate for requests that do not go through _request (Soloist's
# playback-settings calls): the same rate-limit key short-circuit and the
# same MAX_CONCURRENT_REQUESTS slot count as _request, shared with it.
# $run->($release) dispatches the request and MUST call $release once when it
# has answered; a slot that is never released is freed after GATE_MAX_HOLD
# seconds so a lost callback cannot deadlock all spclient traffic.
# $blocked->($why) runs instead of $run while a 429 backoff is active.
use constant GATE_MAX_HOLD => 60;
sub gate {
    my ($class, $label, $run, $blocked) = @_;

    if (my $retryUntil = $cache->get(SPCLIENT_RATE_LIMIT_KEY)) {
        if ($retryUntil - Time::HiRes::time() > 0) {
            main::INFOLOG && $log->info("SpClient: gated request $label short-circuited (cached rate limit)");
            $blocked->('rate_limited_local');
            return;
        }
    }

    if ($inflightCount >= MAX_CONCURRENT_REQUESTS) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.1,
            sub { $class->gate($label, $run, $blocked) });
        return;
    }

    $inflightCount++;
    $requestCount++;
    my $released = 0;
    my $release = sub { return if $released++; $inflightCount--; };
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + GATE_MAX_HOLD, sub {
        return if $released;
        $log->warn("SpClient: gated request $label never answered -- slot freed after " . GATE_MAX_HOLD . " s");
        $release->();
    });

    eval { $run->($release); 1 } or do {
        $log->error("SpClient: gated dispatch failed for $label: $@");
        $release->();
        $blocked->('internal_error');
    };
}

# noteRateLimit($class, $retryAfter) -- 79-61 (FULL-3 WR-03): a 429 seen by a
# gated caller sets the same rate key and counter as _doRequest's 429 path.
sub noteRateLimit {
    my ($class, $retryAfter) = @_;
    $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF unless defined $retryAfter && $retryAfter =~ /^\d+$/;
    $retryAfter = 1   if $retryAfter < 1;
    $retryAfter = 300 if $retryAfter > 300;
    $count429++;
    $cache->set(SPCLIENT_RATE_LIMIT_KEY, Time::HiRes::time() + $retryAfter, $retryAfter);
    $log->warn("SpClient: 429 rate limited for ${retryAfter}s (gated caller)");
}

# _logPath($path) -- 79-43 (D-33 FULL-3 WR-01): the request path as it may appear in a log line. The username
# (profile/<u>, spotify:user:<u>, /user/<u>, raw or URI-escaped), everything after spotify:search: and the
# account bound id of a 37i9dQZF1E or 37i9dQZEVX playlist under playlist/v2/playlist/ are masked;
# the request path, the cache key and the request itself are never changed - only what is logged.
sub _logPath {
    my ($p) = @_;
    return '' unless defined $p;
    $p =~ s{(profile/|spotify:user:|/user/)[^/:?]+}{$1****}g;
    $p =~ s{spotify:search:.*}{spotify:search:****}s;
    # 261110-nu9 (I1), 261111-i1i (UR8-2): the Made for You mixes (37i9dQZF1E...) and Discover Weekly / Release Radar
    # (37i9dQZEVX...) are generated per account, their id is account bound
    $p =~ s{(playlist/v2/playlist/37i9dQZ(?:F1E|EVX))[A-Za-z0-9]+}{$1****}g;
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

                    # 79-61 (FULL-3 WR-05): a 2xx proves the account's token
                    # works again -- lift the unauthorized memory.
                    delete $_unauthUntil{$accountId} if $accountId;

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
                        # 79-61 (FULL-3 WR-05): an account confirmed
                        # unauthorized within UNAUTH_MEMORY_TTL gets no
                        # remint and keeps its cached token -- otherwise every
                        # request costs one login5 mint while spclient keeps
                        # rejecting the bearer. D-07a's one remint per request
                        # still applies once the memory has lapsed or a 2xx
                        # lifted it.
                        if (_unauthMemory($accountId)) {
                            $log->warn("SpClient: 401 for " . _logPath($cleanPath) . " -- account confirmed unauthorized less than " . UNAUTH_MEMORY_TTL . " s ago, no remint");
                            $userCb->(undef, { error => 'unauthorized', code => 401 });
                            return;
                        }

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
                        $_unauthUntil{$accountId} = time() + UNAUTH_MEMORY_TTL if $accountId;
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
# 79-71 (GH #167, D-38): all three run on Pathfinder (API/Pathfinder.pm: queryShowMetadataV2, queryPodcastEpisodes /
# queryBookChapters, getEpisodeOrChapter). spclient metadata/4/show and metadata/4/episode answer 404 (triage
# retest-4.0, spikes 013/014), so no such request is made any more. Signatures and result shapes are unchanged:
# getShow -> { id, uri, name, publisher, images, description, kind }, getShowEpisodes -> { items, total, offset, limit }
# (as getAlbumTracks), getEpisode -> the episode hash. The show metadata is cached 24 h (spoton_pf_show_<id>) and the
# show kind 30 d (spoton_pf_showkind_<id>), so a second list page costs only the list request.
# ============================================================

use constant PF_SHOW_TTL     => 24 * 3600;
use constant PF_SHOWKIND_TTL => 30 * 86400;

# _pfFacadeError($class, $err)
# 79-71 (D-38): the error mapping of the Pathfinder-backed facades (getEpisode, getShow, getShowEpisodes). ONLY a
# Pathfinder `__typename: NotFound` is SpotOn's not-found ({ error => 'not_found', code => 404 }: the definitive case
# ProtocolHandler's refetch locks the item for). Every other Pathfinder failure (graphql_error, parse_error, http_error
# with any code incl. a 404 of the endpoint, rate_limited, unauthorized, ua_gate, hash_broken, op_missing,
# internal_error, unknown_shape, no_token) is transient: { error => 'pathfinder_unavailable', pf_error => <original> }
# WITHOUT a code, so the refetch takes its short transient TTL and never marks the item missing (T-79-304).
sub _pfFacadeError {
    my ($class, $err) = @_;
    my $e = (ref($err) eq 'HASH' && defined $err->{error} && !ref $err->{error}) ? $err->{error} : '';
    return { error => 'not_found', code => 404 } if $e eq 'not_found';
    return { error => 'invalid_id' }             if $e eq 'invalid_id';
    my %out = ( error => 'pathfinder_unavailable', pf_error => (length $e ? $e : 'unknown') );
    $out{pf_code} = $err->{code} if ref($err) eq 'HASH' && defined $err->{code} && !ref $err->{code};
    return \%out;
}

# getEpisode($class, $accountId, $episodeId, $cb)
# 79-71 (GH #167, D-38): on Pathfinder (getEpisodeOrChapter) -- spclient metadata/4/episode answers 404. $cb->(\%episode)
# with id, uri, name, duration_ms, explicit, release_date, images and show { id, uri, name, images } (an audiobook
# chapter carries its book as the show), or $cb->(undef, \%err) per _pfFacadeError.
sub getEpisode {
    my ($class, $accountId, $episodeId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getEpisode without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    unless ($class->idToHex($episodeId)) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;
    Plugins::SpotOn::API::Pathfinder->episodeOrChapter($accountId, $episodeId, sub {
        my ($episode, $err) = @_;
        if ($episode) {
            $cb->($episode);
            return;
        }
        $cb->(undef, $class->_pfFacadeError($err));
    });
}

# getShow($class, $accountId, $showId, $cb)
# $cb->(\%show) or $cb->(undef, \%err) per _pfFacadeError. The kind ('podcast' | 'audiobook') rides in the hash and is
# cached separately for getShowEpisodes.
sub getShow {
    my ($class, $accountId, $showId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getShow without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    unless ($class->idToHex($showId)) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    my $showKey = "spoton_pf_show_$showId";
    if (my $cached = $cache->get($showKey)) {
        $cb->($cached);
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;
    Plugins::SpotOn::API::Pathfinder->showMetadata($accountId, $showId, sub {
        my ($show, $err) = @_;
        unless ($show) {
            $cb->(undef, $class->_pfFacadeError($err));
            return;
        }
        $cache->set($showKey, $show, PF_SHOW_TTL);
        $cache->set("spoton_pf_showkind_$showId", $show->{kind}, PF_SHOWKIND_TTL) if $show->{kind};
        $cb->($show);
    });
}

# getShowEpisodes($class, $accountId, $showId, $params, $cb)
# One page { items, total, offset, limit } of a show's episodes, or of an audiobook's chapters (the kind decides the
# Pathfinder operation). The kind comes from the cache; the first page of a show not seen yet asks getShow first.
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

    unless ($class->idToHex($showId)) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;
    my $list = sub {
        my ($kind) = @_;
        Plugins::SpotOn::API::Pathfinder->showEpisodes($accountId, $showId, $kind, { offset => $offset, limit => $limit }, sub {
            my ($page, $err) = @_;
            unless ($page) {
                $cb->(undef, $class->_pfFacadeError($err));
                return;
            }
            $cb->($page);
        });
    };

    if (my $kind = $cache->get("spoton_pf_showkind_$showId")) {
        $list->($kind);
        return;
    }
    $class->getShow($accountId, $showId, sub {
        my ($show, $err) = @_;
        unless ($show) {
            $cb->(undef, $err);
            return;
        }
        $list->($show->{kind});
    });
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
# live under the collection/v2 set 'show' (S-07). The collection holds only the
# show uris, so the requested slice is named through getShow (Pathfinder, 79-71):
# the 24 h show cache keeps repeats free and Pathfinder's queue throttles the
# rest. A show whose request fails keeps its slot as a minimal id/uri stub
# (CR-01), so one broken show never hides the others and the slot count
# survives (85-15, D-01).
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

        my @results   = (undef) x scalar(@$slice);
        my $remaining = scalar @$slice;
        for my $i (0 .. $#$slice) {
            my $entry = $slice->[$i];
            my ($id)  = ($entry->{uri} // '') =~ /^spotify:show:(.+)$/;
            my $stub  = { id => $id, uri => ($entry->{uri} // 'spotify:show:'), name => undef };
            my $finish = sub {
                my ($show) = @_;
                $results[$i] = { added_at => $entry->{added_at}, show => ($show || $stub) };
                $cb->({ items => \@results, total => $total, offset => $offset, limit => $limit })
                    if --$remaining == 0;
            };
            unless ($id && $class->idToHex($id)) {
                $finish->(undef);
                next;
            }
            $class->getShow($accountId, $id, sub { $finish->($_[0]) });
        }
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

        my $playlists = $class->_parseRootlist($raw, $username);
        unless ($playlists) {
            $cb->(undef, { error => 'parse_error' });
            return;
        }

        $cache->set($cacheKey, $playlists, ROOTLIST_LIST_TTL);
        $cb->($playlists, undef);
    });
}

# _imageUrlAllowed($url)
# 261110-k1b (T-k1b-01): an image URL from the rootlist or libraryV3 becomes a fetch of LMS' image proxy, so only
# https on a *.scdn.co or *.spotifycdn.com host is accepted (not http, not a foreign host, not a suffix trick
# such as i.scdn.co.evil.example).
sub _imageUrlAllowed {
    my ($class, $url) = @_;
    return 0 unless defined $url && !ref($url);
    return $url =~ m{\Ahttps://[A-Za-z0-9.-]+\.(?:scdn\.co|spotifycdn\.com)/} ? 1 : 0;
}

# _parseRootlist($class, $bytes, $selfUsername)
# Decodes the rootlist response. The live server wraps the actual item list
# in field 5 (ListContent), NOT in field 1 (which is a 24-byte revision
# hash). Items are flat in field 5.3 (each with URI in sub-field 1);
# decorated metadata is in field 5.4 (name in .2.1, owner in .5, length
# in .3), paired by index. Returns undef on parse failure; an absent or
# empty item list returns an empty arrayref.
# 261110-k1b (#200): covers from the attributes: picture (field 3, exactly 20 bytes -> i.scdn.co/image/<hex>) and
# picture_size (field 13, url in sub-field 2; kept in received order, only when _imageUrlAllowed). The owner line:
# the account's own playlists (owner == $selfUsername) leave display_name empty, a user name in OWNER_FIXED_NAMES
# shows its fixed name, every other owner shows the user name until the libraryV3 merge (_libraryPlaylists) knows
# the display name. owner.id keeps the raw user name. Mosaic covers and display names are not in the rootlist.
sub _parseRootlist {
    my ($class, $bytes, $selfUsername) = @_;

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

        my ($name, $ownerUsername, $trackCount, $picture, $revision, @pictureSizes);
        if ($i <= $#decorations) {
            my $decoFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($decorations[$i]);
            if ($decoFields) {
                $ownerUsername = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 5);
                $trackCount   = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 3);
                # the playlist's revision (field 1): lowercase hex, it keys the per-playlist libraryV3 cache
                my $rev = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 1);
                $revision = lc(unpack('H*', $rev)) if defined $rev && length($rev) >= 1 && length($rev) <= 64;
                if (defined(my $attrBytes = Plugins::SpotOn::API::ProtobufLite::field_first($decoFields, 2))) {
                    my $attrFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($attrBytes);
                    if ($attrFields) {
                        $name    = Plugins::SpotOn::API::ProtobufLite::field_first($attrFields, 1);
                        $picture = Plugins::SpotOn::API::ProtobufLite::field_first($attrFields, 3);
                        for my $psBytes (@{ $attrFields->{13} || [] }) {
                            my $psFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($psBytes) or next;
                            my $psUrl    = Plugins::SpotOn::API::ProtobufLite::field_first($psFields, 2);
                            push @pictureSizes, $psUrl if defined $psUrl;
                        }
                    }
                }
            }
        }

        # 85-16: protobuf strings are UTF-8 bytes; decode them to characters like the JSON paths deliver
        # them, otherwise LMS shows "T\xc3\x83\xc2\xbcrk..." for names with umlauts.
        utf8::decode($name)          if defined $name;
        utf8::decode($ownerUsername) if defined $ownerUsername;

        my @images;
        if (defined $picture && length($picture) == 20) {
            push @images, { url => 'https://i.scdn.co/image/' . lc(unpack('H*', $picture)) };
        }
        for my $url (@pictureSizes) {
            next unless $class->_imageUrlAllowed($url);
            next if grep { $_->{url} eq $url } @images;
            push @images, { url => $url };
        }

        my $owner;
        if ($ownerUsername) {
            my $shown = (defined $selfUsername && $ownerUsername eq $selfUsername) ? ''
                      : exists OWNER_FIXED_NAMES->{$ownerUsername}                 ? OWNER_FIXED_NAMES->{$ownerUsername}
                      :                                                              $ownerUsername;
            $owner = { id => $ownerUsername, display_name => $shown };
        }

        push @playlists, {
            id       => $id,
            uri      => $uri,
            name     => $name // '',
            owner    => $owner,
            tracks   => { total => $trackCount // 0 },
            images   => \@images,
            revision => $revision,
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

# _allowedImages(\@images)
# The images of a libraryV3 playlist (or of a cached entry) that pass _imageUrlAllowed, as fresh hashes.
sub _allowedImages {
    my ($class, $images) = @_;
    return () unless ref($images) eq 'ARRAY';
    return map { +{ url => $_->{url}, width => $_->{width}, height => $_->{height} } }
           grep { ref($_) eq 'HASH' && $class->_imageUrlAllowed($_->{url}) } @$images;
}

# _libraryPlaylists($class, $accountId, $cb)
# 261110-k1b (#200): the account's playlists as _rootlistPlaylists delivers them, plus what only Pathfinder libraryV3
# knows: a cover for every playlist the rootlist has none for (the covers Spotify assembles from album art) and the
# owner's display name for every other user's playlist. cb->(\@playlists, undef) or cb->(undef, $err) (the rootlist's).
#   - a hit of the 60 s merged list answers at once; a second opening during a cold run joins it (one run per account)
#   - the rootlist entries are never changed (they are cached): every playlist is a copy with its own images and owner
#   - a playlist "needs" libraryV3 when it has no cover and no per-playlist cache entry, or when it is a foreign
#     playlist with neither an owner name nor a per-playlist entry; with nothing needed (or libraryV3 switched off)
#     there is no request at all
#   - pages of 50 one after the other through Pathfinder->libraryPlaylists (its queue and its own 429 pool), until
#     everything needed was seen, the library ends, or LIBV3_MAX_PAGES pages were read
#   - any failure keeps what was applied and leaves the rest in the rootlist state; no negative entries are written
#     after a failure; a structural one (HTTP 400, errors[], unknown shape) also switches libraryV3 off for an hour
#   - 261111-j57: no negative entries at the page limit either: the playlists a run stopped at LIBV3_MAX_PAGES never
#     asked for get a page-limit marker instead (24 h, per account). It keeps them from asking again and lets them count
#     as missing in the status
#   - 261111-i1i: LIBV3_BUDGET seconds after the first libraryV3 request the open is answered with the pages read so
#     far (no negative entry, no off key). The chain runs on, one page after the other, and writes only the caches,
#     never the delivered list. The run stays registered meanwhile: a further open is answered at once with the
#     delivered list and starts no second chain (LIBV3_RUN_STALE stays the emergency brake). At the chain end without
#     a failure the list key is removed and the run released, so the next open builds the full list from the caches;
#     after a failure (261111-j57) the key stays for the rest of its 60 s, so a further open is answered at once and
#     does not wait for the budget again. The status row is written at the chain end. The timer starts only after the
#     rootlist answered: a hanging rootlist request is not covered by the budget.
# Logs carry counts only, never a name or an id.
sub _libraryPlaylists {
    my ($class, $accountId, $cb) = @_;

    my $listKey = LIBRARY_LIST_KEY . $accountId;
    if (my $cached = $cache->get($listKey)) {
        $cb->($cached, undef);
        return;
    }

    my $now = $class->_libClock();
    my $run = $_libRuns{$accountId};
    if ($run && ($now - $run->{at}) < LIBV3_RUN_STALE) {
        if ($run->{list}) {
            # the budget already delivered: answer with that list, the chain in the background stays the only one
            eval { $cb->($run->{list}, undef); 1 } or $log->error("SpClient: library playlists callback died: $@");
            return;
        }
        push @{ $run->{cbs} }, $cb;
        return;
    }
    $run = $_libRuns{$accountId} = { at => $now, cbs => [ $cb ] };

    my $answer = sub {
        my @args = @_;
        my @waiters = splice @{ $run->{cbs} };
        for my $waiter (@waiters) {
            eval { $waiter->(@args); 1 } or $log->error("SpClient: library playlists callback died: $@");
        }
    };
    my $deliver = sub {
        my @args = @_;
        delete $_libRuns{$accountId} if ($_libRuns{$accountId} // 0) == $run;
        $answer->(@args);
    };
    # the budget ran out: answer the waiters, keep the run registered (the chain is still going)
    my $early = sub {
        my ($list) = @_;
        $run->{list} = $list;
        $answer->($list, undef);
    };
    # the chain ended after the budget: only unregister
    my $release = sub {
        delete $_libRuns{$accountId} if ($_libRuns{$accountId} // 0) == $run;
    };

    my $started = eval {
        $class->_rootlistPlaylists($accountId, sub {
            my ($playlists, $err) = @_;
            if ($err) {
                $deliver->(undef, $err);
                return;
            }
            $class->_libraryMerge($accountId, $playlists, $listKey, $deliver, $early, $release);
        });
        1;
    };
    unless ($started) {
        $log->error("SpClient: library playlists failed to start: $@");
        $deliver->(undef, { error => 'internal_error' });
    }
    return;
}

# _libCapKey($class, $accountId, $playlistId): the page-limit marker key (the only place that builds it)
sub _libCapKey { my ($class, $accountId, $id) = @_; return LIBV3_CAPPED_KEY . $accountId . '_' . $id; }

# _libClock($class): the clock of the library run (a seam for tests)
sub _libClock { return time(); }

# _libraryMerge($class, $accountId, \@rootlist, $listKey, $deliver, $early, $release)
# The second half of _libraryPlaylists (see there): classify, serve from the caches, page through libraryV3,
# apply, cache, deliver. Exactly one of: $deliver->(\@merged, undef) once when the chain ends inside the budget, or
# $early->(\@copy) once at the budget plus $release->() once when the chain ends later.
sub _libraryMerge {
    my ($class, $accountId, $playlists, $listKey, $deliver, $early, $release) = @_;

    my $self = $class->_username($accountId);
    $self = '' unless defined $self;
    my $now = $class->_libClock();

    my @out;       # the copies, in rootlist order
    my %need;      # playlist id -> [ index in @out ] of the playlists that need libraryV3
    my %kind;      # index -> self | fixed | foreign | none
    my %negMeta;   # index -> 1 when this playlist's per-playlist entry is negative (no cover: Spotify has nothing)
    my %capIdx;    # index -> 1 when this playlist lies beyond the libraryV3 page limit (261111-j57): kept from asking by a
                   # marker, or never asked by this run because it stopped at LIBV3_MAX_PAGES
    for my $pl (@$playlists) {
        my %c = %$pl;
        $c{images} = [ map { +{ %$_ } } @{ $pl->{images} || [] } ];
        $c{owner}  = $pl->{owner} ? { %{ $pl->{owner} } } : undef;
        my $ownerId = $c{owner} ? ($c{owner}{id} // '') : '';
        my $kind = !length($ownerId)                  ? 'none'
                 : $ownerId eq $self                  ? 'self'
                 : exists OWNER_FIXED_NAMES->{$ownerId} ? 'fixed'
                 :                                      'foreign';

        my $meta  = $cache->get(PL_META_KEY . $pl->{id} . '_' . ($pl->{revision} // 'norev'));
        my $owner = $kind eq 'foreign' ? $cache->get(OWNER_NAME_KEY . $ownerId) : undef;
        if (!@{ $c{images} } && ref($meta) eq 'HASH') {
            $c{images} = [ $class->_allowedImages($meta->{images}) ];
        }
        if (ref($owner) eq 'HASH' && length($owner->{name} // '')) {
            $c{owner}{display_name} = $owner->{name};
        }

        push @out, \%c;
        $kind{$#out} = $kind;
        $negMeta{$#out} = 1 if ref($meta) eq 'HASH' && !@{ $meta->{images} || [] };   # a negative entry of an earlier run
        # 261111-j57: a playlist the last run never asked because it stopped at LIBV3_MAX_PAGES carries a page-limit
        # marker (24 h) and stays out of %need; the marker is read only when libraryV3 would be asked otherwise
        my $wantsLib = ((!@{ $c{images} } && !$meta) || ($kind eq 'foreign' && !$owner && !$meta)) ? 1 : 0;
        my $capMark  = $wantsLib ? $cache->get($class->_libCapKey($accountId, $pl->{id})) : undef;
        my $capOk = ref($capMark) eq 'HASH' && defined($capMark->{at}) && ($now - $capMark->{at}) < LIBV3_CAPPED_TTL;
        $capIdx{$#out} = 1 if $capOk;
        if ($wantsLib && !$capOk) {
            push @{ $need{ $pl->{id} } }, $#out;
        }
    }

    my $finishList = sub {
        $cache->set($listKey, \@out, LIBRARY_LIST_TTL);
        $deliver->(\@out, undef);
    };

    if (!%need || $cache->get(LIBV3_OFF_KEY . $accountId)) {
        main::INFOLOG && $log->info('SpClient: library playlists: ' . scalar(@out) . ' entries, ' . scalar(keys %need)
            . ' need libraryV3, ' . ($cache->get(LIBV3_OFF_KEY . $accountId) ? 'libraryV3 is paused' : 'no request'));
        $finishList->();
        return;
    }

    require Plugins::SpotOn::API::Pathfinder;

    my (%seen, $failure);
    my ($offset, $pages) = (0, 0);
    my ($done, $cut, $budgetCb, $capped);

    # $apply->($partial): $partial is the budget cut: what the pages read so far brought, nothing negative (the pages
    # not read yet may still know the playlist) and no off key / end-of-run log (the chain is not over). Also nothing
    # negative when $capped (the run stopped at LIBV3_MAX_PAGES): those playlists get the page-limit marker instead
    my $apply = sub {
        my ($partial) = @_;
        for my $id (keys %need) {
            for my $idx (@{ $need{$id} }) {
                my $c   = $out[$idx];
                my $key = PL_META_KEY . $id . '_' . ($playlists->[$idx]{revision} // 'norev');
                if (my $it = $seen{$id}) {
                    my @img = $class->_allowedImages($it->{images});
                    $c->{images} = [ map { +{ %$_ } } @img ] unless @{ $c->{images} };
                    my $name = ref($it->{owner}) eq 'HASH' ? ($it->{owner}{display_name} // '') : '';
                    $c->{owner}{display_name} = $name if $kind{$idx} eq 'foreign' && length $name;
                    $cache->set($key, { images => [ @img ] }, PL_META_TTL);
                    $negMeta{$idx} = 1 unless @img;   # the entry just written is negative (no allowed image)
                }
                elsif (!$failure && !$partial && $capped) {
                    # the run stopped at LIBV3_MAX_PAGES and never asked for this playlist: no negative entry (Spotify may
                    # well have it), but a page-limit marker so the next open does not ask the same 10 pages again
                    $cache->set($class->_libCapKey($accountId, $id), { at => $class->_libClock() }, LIBV3_CAPPED_TTL);
                    $capIdx{$idx} = 1;
                }
                elsif (!$failure && !$partial) {
                    $cache->set($key, { images => [] }, PL_META_TTL);   # the library has no such playlist (negative)
                    $negMeta{$idx} = 1;
                }
            }
        }
        return if $partial;
        if ($failure) {
            my $code = ref($failure) eq 'HASH' ? ($failure->{code} // 0) : 0;
            my $name = ref($failure) eq 'HASH' ? ($failure->{error} // '') : '';
            if ($code == 400 || $name =~ /\A(?:graphql_error|unknown_shape|parse_error)\z/) {
                $cache->set(LIBV3_OFF_KEY . $accountId, 1, LIBV3_OFF_TTL);
            }
            main::INFOLOG && $log->info('SpClient: library playlists: libraryV3 failed (' . ($code ? "HTTP $code" : _plainError($failure))
                . ") after $pages page(s), the rootlist state stays for the rest");
        }
        else {
            main::INFOLOG && $log->info('SpClient: library playlists: ' . scalar(@out) . ' entries, ' . scalar(keys %need)
                . " needed libraryV3, $pages page(s)" . ($capped ? ', stopped at the page limit' : ''));
        }
    };

    my $finish = sub {
        return if $done++;
        Slim::Utils::Timers::killTimers(undef, $budgetCb) if $budgetCb;
        undef $budgetCb;
        $apply->();
        my ($missing, $skipped) = (0, 0);
        unless ($failure) {
            for my $idx (0 .. $#out) {
                my $c = $out[$idx];
                my ($named, $ownerNeg) = (1, 0);
                if (($kind{$idx} // '') eq 'foreign') {
                    my $o = $cache->get(OWNER_NAME_KEY . $c->{owner}{id});
                    $named    = (ref($o) eq 'HASH' && length($o->{name} // '')) ? 1 : 0;
                    $ownerNeg = (ref($o) eq 'HASH' && defined($o->{name}) && !length($o->{name})) ? 1 : 0;
                }
                # a negative entry (Spotify has nothing) is not "missing": 261111-i1i UR8-3
                my $neg = $negMeta{$idx} ? 1 : 0;
                my $isMissing = ((!@{ $c->{images} } && !$neg) || (!$named && !$ownerNeg && !$neg)) ? 1 : 0;
                $missing++ if $isMissing;
                $skipped++ if $isMissing && $capIdx{$idx};   # a subset of missing: the part beyond the page limit
            }
        }
        $class->_libRecord($failure, $missing, $skipped);
        if ($cut) {
            # the budget already delivered a list: without a failure it is dropped, so the next open builds the full one
            # from the caches. After a failure (261111-j57) it stays until its LIBRARY_LIST_TTL runs out: a further open is
            # answered at once instead of starting a new chain that waits up to LIBV3_BUDGET again
            $cache->remove($listKey) unless $failure;
            main::INFOLOG && $log->info('SpClient: library playlists: background chain ended after ' . $pages . ' page(s), '
                . scalar(grep { $seen{$_} } keys %need) . ' of ' . scalar(keys %need) . ' playlists needing libraryV3 were seen');
            $release->();
        }
        else {
            $finishList->();
        }
    };

    # The budget: LIBV3_BUDGET seconds after the first page was requested the waiters get what the pages read so far
    # brought. The delivered list is a copy: the chain goes on with its private @out and writes only the caches.
    $budgetCb = sub {
        return if $done || $cut;
        $cut = 1;
        eval { $apply->(1); 1 } or $log->error("SpClient: library playlists budget apply failed: $@");
        my @copy = map {
            my %c = %$_;
            $c{images} = [ map { +{ %$_ } } @{ $_->{images} || [] } ];
            $c{owner}  = $_->{owner} ? { %{ $_->{owner} } } : undef;
            \%c;
        } @out;
        $cache->set($listKey, \@copy, LIBRARY_LIST_TTL);
        main::INFOLOG && $log->info('SpClient: library playlists: budget reached after ' . $pages . ' page(s), '
            . scalar(grep { $seen{$_} } keys %need) . ' of ' . scalar(keys %need) . ' playlists needing libraryV3 were seen, '
            . 'the rest follows in the background');
        $early->(\@copy);
    };

    my $step;
    $step = sub {
        my $ok = eval {
            Plugins::SpotOn::API::Pathfinder->libraryPlaylists($accountId, { offset => $offset, limit => LIBV3_PAGE_LIMIT }, sub {
                my ($page, $err) = @_;
                $pages++;
                my $handled = eval {
                    if ($err || !$page) {
                        $failure = $err || { error => 'no_page' };
                        $step = undef;
                        $finish->();
                        return 1;
                    }
                    for my $it (@{ $page->{items} || [] }) {
                        $seen{ $it->{id} } //= $it;
                        my $o   = ref($it->{owner}) eq 'HASH' ? $it->{owner} : next;
                        my $oid = $o->{id} // '';
                        next if !length($oid) || $oid eq $self || exists OWNER_FIXED_NAMES->{$oid};
                        my $nm  = $o->{display_name} // '';
                        if (length $nm) {
                            $cache->set(OWNER_NAME_KEY . $oid, { name => $nm }, OWNER_NAME_TTL);
                        }
                        else {
                            my $cur = $cache->get(OWNER_NAME_KEY . $oid);
                            $cache->set(OWNER_NAME_KEY . $oid, { name => '' }, OWNER_NAME_NEG_TTL)
                                unless ref($cur) eq 'HASH' && length($cur->{name} // '');
                        }
                    }
                    $offset += LIBV3_PAGE_LIMIT;
                    my $open = grep { !$seen{$_} } keys %need;
                    my $libEnded = (!$page->{rawCount} || (defined $page->{total} && $offset >= $page->{total})) ? 1 : 0;
                    if (!$open || $libEnded || $pages >= LIBV3_MAX_PAGES) {
                        # 261111-j57: stopped by the page limit only when something is still open and the library goes on
                        $capped = 1 if $open && !$libEnded;
                        $step = undef;
                        $finish->();
                        return 1;
                    }
                    $step->();
                    1;
                };
                unless ($handled) {
                    $log->error("SpClient: library playlists page handling failed: $@");
                    $failure ||= { error => 'internal_error' };
                    if ($step) { $step = undef; $finish->(); }
                }
            });
            1;
        };
        unless ($ok) {
            $log->error("SpClient: library playlists request failed: $@");
            $failure ||= { error => 'internal_error' };
            $step = undef;
            $finish->();
        }
    };
    # started after the rootlist answered: a hanging rootlist request is not covered by the budget
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + LIBV3_BUDGET, $budgetCb);
    $step->();
    return;
}

# _libRecord($class, $failure, $missing, $skipped)
# Notes the end of a run that called libraryV3 for libraryMetaStatus: ok (with the number of playlists still without
# cover or owner name that carry no negative entry: what Spotify has nothing for is not missing; and skipped, the part
# of those that lies beyond the page limit: never asked by this run or kept from asking by a marker, a subset of missing)
# or fallback (since = the start of the streak, reason = 'HTTP <code>' or the plain error name).
# A 400 also writes the one warning per hour. No name and no id is ever stored or logged.
sub _libRecord {
    my ($class, $failure, $missing, $skipped) = @_;
    my $now = $class->_libClock();

    unless ($failure) {
        %_libMeta = (state => 'ok', at => $now, since => undef, reason => undef, missing => $missing // 0, skipped => $skipped // 0);
        return;
    }

    my $code   = ref($failure) eq 'HASH' ? ($failure->{code} // 0) : 0;
    my $reason = $code ? "HTTP $code" : _plainError($failure);
    my $since  = (($_libMeta{state} // '') eq 'fallback' && defined $_libMeta{since}) ? $_libMeta{since} : $now;
    %_libMeta = (state => 'fallback', at => $now, since => $since, reason => $reason, missing => undef, skipped => undef);

    if ($code == 400 && (!defined $_libWarnAt || ($now - $_libWarnAt) >= LIBV3_WARN_INTERVAL)) {
        $_libWarnAt = $now;
        $log->warn('SpClient: Library playlists -- libraryV3 answered HTTP 400; covers and owner names come from the '
            . 'playlist list only, for one hour (at most one such warning per hour)');
    }
    return;
}

# libraryMetaStatus($class)
# The status page row "Library metadata": exactly seven plain keys, no name, no id, no token. state is 'unknown'
# (no libraryV3 run yet), 'ok' or 'fallback'; at the epoch of the last real run; since the start of the current
# fallback streak (fallback only); reason 'HTTP <code>' or a plain error name (fallback only); missing the number of
# playlists still without cover or resolved owner name after the last ok run; skipped (261111-j57) how many of those
# lie beyond the page limit (never asked or kept from asking by a marker, a subset of missing, ok only); limit the
# number of library entries one run reads (LIBV3_MAX_PAGES x LIBV3_PAGE_LIMIT). Counts only. Process-wide: the last
# run of any account. A call served from a cache or blocked by the off key does not change it.
sub libraryMetaStatus {
    my ($class) = @_;
    return {
        state   => $_libMeta{state} // 'unknown',
        at      => $_libMeta{at},
        since   => $_libMeta{since},
        reason  => $_libMeta{reason},
        missing => $_libMeta{missing},
        skipped => $_libMeta{skipped},
        limit   => LIBV3_MAX_PAGES * LIBV3_PAGE_LIMIT,
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

    $class->_libraryPlaylists($accountId, sub {
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
# Radio (GH #82)
# ============================================================
# Spotify's own radios, through the requests its clients send (librespot-core
# spclient.rs get_radio_for_track / get_apollo_station), with SpotOn's login5
# bearer -- not the Web API /recommendations that #82 found gone. Measured
# 2026-11-09 (seed: a track of a saved album):
#   inspiredby-mix/v2/seed_to_playlist/<seed>?response-format=json
#     -> { mediaItems: [{ uri }], total }
#     track seed  -> spotify:playlist:37i9dQZF1E8..., "<track> - radio" (format inspiredby-mix), 50 tracks
#     artist seed -> "<artist> - radio" (37i9dQZF1E4...), 50 tracks
#     album seed  -> the same playlist as its artist seed (Spotify has no album radio)
#     playlist    -> spotify:station:playlist:<id>, a station, not a playlist
#   radio-apollo/v3/stations/<seed>?autoplay=false&count=N
#     -> { tracks: [{ uri, ... }], title, next_page_url, ... }
# A radio playlist is an ordinary playlist (playlist/v2 reads it, the
# existing feeds play it); a station is read through radio-apollo.
# Requests happen only when a radio is opened -- the menu entries are lazy.

use constant RADIO_SEED_TTL      => 6 * 3600;   # seed -> radio playlist id; Spotify refreshes the playlist's contents itself
use constant RADIO_STATION_TTL   => 300;        # station track list, the browse tier (CLAUDE.md)
use constant RADIO_STATION_COUNT => 50;         # what a radio playlist holds

# radioSeedType($class, $seedUri) -> 'track' | 'artist' | 'album' | 'playlist',
# or undef for anything else. The seed is spliced into a request path and a
# cache key, so only these exact shapes pass (WR-04 discipline).
sub radioSeedType {
    my ($class, $seed) = @_;
    return undef unless defined $seed && !ref $seed;
    return $seed =~ /\Aspotify:(track|artist|album|playlist):[0-9A-Za-z]{22}\z/ ? $1 : undef;
}

# getRadio($class, $accountId, $seedUri, $cb)
# The radio Spotify offers for a seed: cb->({ playlistId, uri }) when it is a
# radio playlist, cb->({ station => $seedUri }) when Spotify answers with a
# station (playlist seeds), cb->(undef, { error => 'no_radio' }) when it names
# neither, or cb->(undef, $err) for a failed request. One request per seed and
# RADIO_SEED_TTL; a cache hit sends nothing.
sub getRadio {
    my ($class, $accountId, $seed, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: getRadio without stored credentials');
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    unless ($class->radioSeedType($seed)) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    my $cacheKey = "spoton_radio_${accountId}_$seed";
    if (my $cached = $cache->get($cacheKey)) {
        $cb->($cached);
        return;
    }

    $class->_request('get', "inspiredby-mix/v2/seed_to_playlist/$seed?response-format=json", {
        _accountId => $accountId,
        _accept    => 'application/json',
        _noCache   => 1,   # the seed -> radio answer is cached below
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my $items = (ref $result eq 'HASH' && ref $result->{mediaItems} eq 'ARRAY') ? $result->{mediaItems} : [];
        my $uri   = (ref $items->[0] eq 'HASH' && defined $items->[0]{uri} && !ref $items->[0]{uri}) ? $items->[0]{uri} : '';

        my $radio;
        if ($uri =~ /\Aspotify:playlist:([0-9A-Za-z]{22})\z/) {
            $radio = { playlistId => $1, uri => $uri };
        }
        elsif ($uri =~ /\Aspotify:station:/) {
            $radio = { station => $seed };
        }
        else {
            main::INFOLOG && $log->info('SpClient: no radio for ' . $class->radioSeedType($seed) . ' seed');
            $cb->(undef, { error => 'no_radio' });
            return;
        }

        $cache->set($cacheKey, $radio, RADIO_SEED_TTL);
        $cb->($radio);
    });
}

# getRadioStationTracks($class, $accountId, $seedUri, $params, $cb)
# A station's tracks from radio-apollo (RADIO_STATION_COUNT of them, the list
# cached RADIO_STATION_TTL so paging sees one list), sliced per
# $params->{offset}/{limit} (defaults 0/50) and named through _enrichTracks.
# Result shape = getPlaylistItems: { items => [{ track }], total, offset,
# limit, next, title }. cb->(undef, $err) for a failed request.
sub getRadioStationTracks {
    my ($class, $accountId, $seed, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // RADIO_STATION_COUNT;

    unless ($class->_hasLogin5Creds($accountId)) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    unless ($class->radioSeedType($seed)) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    my $deliver = sub {
        my ($station) = @_;
        my ($slice, $total) = $class->_sliceAsPage($station->{trackIds} || [], $offset, $limit);
        $class->_enrichTracks($accountId, $slice, sub {
            my ($tracks) = @_;
            $cb->({
                items  => [ map { { track => $_ } } @$tracks ],
                total  => $total,
                offset => $offset,
                limit  => $limit,
                next   => (($offset + $limit) < $total) ? 1 : undef,
                title  => $station->{title},
            });
        });
    };

    my $cacheKey = "spoton_radio_station_${accountId}_$seed";
    if (my $cached = $cache->get($cacheKey)) {
        $deliver->($cached);
        return;
    }

    $class->_request('get', "radio-apollo/v3/stations/$seed?autoplay=false&count=" . RADIO_STATION_COUNT, {
        _accountId => $accountId,
        _accept    => 'application/json',
        _noCache   => 1,   # the station list is cached below
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            $cb->(undef, $err);
            return;
        }

        my @trackIds = map { (ref $_ eq 'HASH' && ($_->{uri} // '') =~ /\Aspotify:track:([0-9A-Za-z]{22})\z/) ? $1 : () }
                       @{ (ref $result eq 'HASH' && ref $result->{tracks} eq 'ARRAY') ? $result->{tracks} : [] };
        my $title = (ref $result eq 'HASH' && defined $result->{title} && !ref $result->{title}) ? $result->{title} : undef;

        my $station = { trackIds => \@trackIds, title => $title };
        $cache->set($cacheKey, $station, RADIO_STATION_TTL) if @trackIds;
        $deliver->($station);
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
# Made for You on Pathfinder (85-08, decision-D17 pathfinder-login5-plus-rootlist;
# 79-59, GH #180: the whole home)
# ============================================================
# Three Pathfinder queries in parallel with SpotOn's own login5 bearer,
# cookie-free (API/Pathfinder.pm): op home (every row of the Spotify home) and
# the two homeSection queries SpotOn read before (SECTION_MFY, SECTION_TOPMIX;
# they answer more mixes of their row than home does). When every source
# fails or yields nothing, the Spotify-made spotify:playlist:37i9dQZ mixes of
# the user's rootlist are shown instead. DJ never appears (not a playlist,
# spclient answers 404). No backend is consulted (D-20) and no
# browse/categories request is sent (D-08).
#
# Which home lists are kept (79-59, user decision 2026-10-31 "Regel ja, aber
# ohne Radios"): a Playlist whose id starts with 37i9dQZF1E or 37i9dQZEVX,
# whose attributes carry madeFor.username, and whose format is not
# inspiredby-mix (the artist radios). No title list and no format allow-list,
# so a new kind of personal list appears without a code change. The id prefix
# is an observed, undocumented Spotify convention: if Spotify changes it,
# lists go missing, but wrong ones are never added. The two homeSection rows
# keep their old rule (Playlist, not DJ) and lose only inspiredby-mix.
#
# Layout (user decision "Feste oben, Rest in Ordnern"): daylist, Daily Mixes,
# Discover Weekly, Release Radar on top (by format); the lists of untitled
# rows below them; then one folder per Spotify row title, in Spotify's order
# (rows that share a title share a folder). Each list appears once, at its
# first place. Without a home answer the list stays flat, as before.

use constant MFY_TOP_FORMATS  => [ 'daylist', 'daily-mix', 'discover-weekly', 'release-radar' ];
use constant MFY_RADIO_FORMAT => 'inspiredby-mix';
# 79-59: the menu is fetched again on every descent (LMS keeps no browse
# session for coderef menus), and the Spotify home answers differently on
# every request (rows come and go, one-item rows rotate) -- without a cache a
# folder or list opened from the menu could be a different one than the one
# shown. A complete answer is kept for the browse tier (CLAUDE.md: 300 s);
# an answer with a failed source is not kept, the next open asks again;
# an answer whose name lookups were cut short is kept for MFY_LIST_PARTIAL_TTL.
use constant MFY_LIST_TTL     => 300;
# 261110-nu9: a build cut short by the budget or a 429 stop is kept for this short time, so reopening the menu
# does not repeat the three Pathfinder requests and the lookups at once (a pathfinder failure keeps nothing)
use constant MFY_LIST_PARTIAL_TTL => 60;
use constant MFY_LIST_KEY     => 'spoton_mfy_list_';
# 261110-is9 (spike 018): a list Pathfinder sends without a name is looked up by id, bounded. At most
# MFY_NAME_PARALLEL lookups are in flight (SpClient's own MAX_CONCURRENT_REQUESTS, so a build never takes more
# than the shared pool) and one build starts at most MFY_NAME_MAX_LOOKUPS (the most nameless entries expected
# per view, the 13 "Your top mixes"; it bounds a cold view even if Spotify drops every name).
use constant MFY_NAME_PARALLEL    => 2;
use constant MFY_NAME_MAX_LOOKUPS => 13;
# a run that has not answered after this long is not joined any more (a stuck run must not block the account)
use constant MFY_RUN_STALE        => 60;
# The name cache, key spoton_mfy_name_<playlist id> -> { name }. A found name lives 30 days: the name of a
# generated list id is stable (spike 018: identical across repeats), and the plugin already keeps metadata
# that long (TRACK_META_TTL, PF_SHOWKIND_TTL, Pathfinder's PF_HASH_TTL); a 3600 s tier would repeat up to 13
# lookups an hour on exactly the accounts that need them. 2592000 s is the largest value DbCache still reads
# as relative. A failed lookup is kept for 1 hour, so a list that cannot be named is not asked for on every
# menu opening. No account and no locale in the key: playlist ids are global, and a locale in the key would
# ask again after every per-read language flip. Every name homeSection delivers seeds or overwrites the entry.
use constant MFY_NAME_KEY           => 'spoton_mfy_name_';
use constant MFY_NAME_TTL           => 30 * 86400;
use constant MFY_NAME_NEG_TTL       => 3600;
# the menu is delivered after this many seconds even when lookups are still out (a hanging network must not
# hold the menu; REQUEST_TIMEOUT is 30 s per request)
use constant MFY_NAME_BUDGET        => 5;
# at most one "item without a usable name" warning per this many seconds, process-wide
use constant MFY_NAME_WARN_INTERVAL => 3600;

# getMadeForYou($class, $accountId, $cb)
# cb->({ items => [{ id, uri, name, images }, ...], source => 'pathfinder' |
# 'rootlist-fallback', layout => { top => [...], loose => [...],
# folders => [{ title, items => [...] }] } }) or cb->(undef, $err). items is
# the flat menu order; layout is present only when op home answered with rows.
# No login5 credentials answer (undef, { error => 'no_credentials' }) without
# a request. A name of '' means "unknown" (the feed labels it, 261110-is9):
# the id is never used as a name; an item that arrives without a name is
# looked up by _resolveMfyNames before the list is delivered.
sub getMadeForYou {
    my ($class, $accountId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        $cb->(undef, { error => 'no_credentials' });
        return;
    }

    my $listKey = MFY_LIST_KEY . $accountId;
    if (my $kept = $cache->get($listKey)) {
        if (ref($kept) eq 'HASH' && ref($kept->{items}) eq 'ARRAY' && @{ $kept->{items} }) {
            %_mfy = (source => 'pathfinder', mixCount => scalar(@{ $kept->{items} }), lastError => undef);
            $cb->($kept);
            return;
        }
    }

    # 261110-is9: join a run that is already building this account's list
    my $run = $_mfyRuns{$accountId};
    if ($run && time() - $run->{at} < MFY_RUN_STALE) {
        push @{ $run->{cbs} }, $cb;
        return;
    }
    $run = $_mfyRuns{$accountId} = { at => time(), cbs => [ $cb ] };
    my $answered = 0;
    $cb = sub {
        return if $answered++;
        delete $_mfyRuns{$accountId} if ($_mfyRuns{$accountId} || 0) == $run;
        for my $waiting (@{ $run->{cbs} }) {
            eval { $waiting->(@_); 1 } or $log->error("SpClient: a Made for You callback died: $@");
        }
    };

    require Plugins::SpotOn::API::Pathfinder;
    my $djUri    = Plugins::SpotOn::API::Pathfinder::DJ_URI();
    my @sections = (
        Plugins::SpotOn::API::Pathfinder::SECTION_MFY(),
        Plugins::SpotOn::API::Pathfinder::SECTION_TOPMIX(),
    );
    my @sectionNames = ('mfy', 'topmix');

    # Initialised BEFORE the first request: a callback may fire synchronously.
    my $remaining = scalar(@sections) + 1;
    my (@got, @errs, $homeRows, $homeErr);

    my $finish = sub {
        my $usable = sub {
            my ($it, $personal) = @_;
            return undef unless ref($it) eq 'HASH';
            my $uri = $it->{uri};
            return undef unless defined $uri && !ref($uri);
            return undef if $uri eq $djUri;
            return undef unless ($it->{typename} // '') eq 'Playlist';
            return undef unless $uri =~ /\Aspotify:playlist:([A-Za-z0-9]{1,40})\z/;
            my $id = $1;
            return undef if ($it->{format} // '') eq MFY_RADIO_FORMAT;
            if ($personal) {
                return undef unless $id =~ /\A37i9dQZ(?:F1E|EVX)/;
                return undef unless $it->{madeFor};
            }
            return {
                id     => $id,
                uri    => $uri,
                name   => (defined $it->{name} && !ref($it->{name}) && length $it->{name}) ? $it->{name} : '',
                images => $it->{images} || [],
                format => $it->{format} // '',
            };
        };

        # rows: home's rows in Spotify order; the homeSection items join the
        # row with the same uri (after home's items), else a row of their own
        my @rows;
        my %rowOf;
        my $haveHome = (ref($homeRows) eq 'ARRAY' && @$homeRows) ? 1 : 0;
        if ($haveHome) {
            for my $r (@$homeRows) {
                next unless ref($r) eq 'HASH';
                my $row = { uri => $r->{uri}, title => $r->{title} // '', entries => [] };
                push @{ $row->{entries} }, [ $_, 1 ] for @{ $r->{items} || [] };
                $rowOf{ $r->{uri} } //= $row;
                push @rows, $row;
            }
        }
        for my $i (0 .. $#sections) {
            my $row = $rowOf{ $sections[$i] };
            unless ($row) {
                $row = { uri => $sections[$i], title => '', entries => [] };
                $rowOf{ $sections[$i] } = $row;
                push @rows, $row;
            }
            push @{ $row->{entries} }, [ $_, 0 ] for @{ $got[$i] || [] };
        }

        # Each list appears once, at its first place (79-59 dedupe invariant). A later copy
        # that carries a name gives it to a first copy that has none (261110-is9).
        my (@merged, %kept, @placed, %recorded, @noName);
        for my $row (@rows) {
            for my $e (@{ $row->{entries} }) {
                my $m = $usable->($e->[0], $e->[1]) or next;
                # what Pathfinder sent in place of a name, kept once per list for the warning below
                if (!length $m->{name} && !$recorded{ $m->{uri} }++) {
                    my $src = $e->[0];
                    my $t = $src->{nameType} // 'unknown';
                    my $k = $src->{dataKeys} // '';
                    push @noName, {
                        uri    => $m->{uri},
                        family => substr($m->{id}, 0, 11),
                        type   => ($t =~ /\A[A-Za-z0-9_:{},]{1,400}\z/ ? $t : 'unknown'),
                        keys   => ($k =~ /\A[A-Za-z0-9_,]{0,400}\z/ ? $k : ''),
                    };
                }
                if (my $first = $kept{ $m->{uri} }) {
                    if (!length $first->{name} && length $m->{name}) {
                        $first->{name} = $m->{name};
                        $first->{images} = $m->{images} if !@{ $first->{images} } && @{ $m->{images} };
                    }
                    next;
                }
                $kept{ $m->{uri} } = $m;
                push @placed, [ $m, $row ];
            }
        }

        my $layout;
        if ($haveHome) {
            my @tops = @{ MFY_TOP_FORMATS() };
            my %tier = map { $tops[$_] => $_ } 0 .. $#tops;
            my (@top, @loose, @folders, %folderOf);
            for my $p (@placed) {
                my ($m, $row) = @$p;
                if (exists $tier{ $m->{format} }) {
                    push @top, $m;
                }
                elsif (!length $row->{title}) {
                    push @loose, $m;
                }
                else {
                    my $f = $folderOf{ $row->{title} };
                    unless ($f) {
                        $f = $folderOf{ $row->{title} } = { title => $row->{title}, items => [] };
                        push @folders, $f;
                    }
                    push @{ $f->{items} }, $m;
                }
            }
            # stable by tier: Spotify's order inside a tier (Daily Mix 1..n)
            my %pos; @pos{ map { $_->{uri} } @top } = 0 .. $#top;
            @top = sort { $tier{ $a->{format} } <=> $tier{ $b->{format} } || $pos{ $a->{uri} } <=> $pos{ $b->{uri} } } @top;
            @merged = (@top, @loose, map { @{ $_->{items} } } @folders);
            $layout = { top => \@top, loose => \@loose, folders => \@folders };
        }
        else {
            @merged = map { $_->[0] } @placed;
        }
        delete $_->{format} for @merged;

        # WR-13: keep the reason a source failed, and (79-59) name the source.
        # A Pathfinder answer that merely carries no Playlist items is NOT a
        # transport failure; the status page and the menu must not blame the
        # transport for it.
        my @failed = (($homeErr ? [ 'home', $homeErr ] : ()),
                      map { $errs[$_] ? [ $sectionNames[$_], $errs[$_] ] : () } 0 .. $#sections);
        my $pfFailed  = @failed ? 1 : 0;
        my $lastError = @failed ? $failed[0][0] . ' ' . _plainError($failed[0][1]) : undef;

        if (@merged) {
            # delivery: the list is kept when every source answered (300 s when every lookup ended, 60 s when cut short)
            # recorded lists that the dedup already named (a later copy carried the name), counted before any lookup
            my $dupCount = scalar(grep { length $kept{ $_->{uri} }{name} } @noName);
            my $deliver = sub {
                my ($complete, $counts) = @_;
                $counts ||= {};
                $class->_warnNamelessMfy(\@noName, $dupCount, $counts);
                %_mfy = (source => 'pathfinder', mixCount => scalar(@merged), lastError => $lastError);
                my $result = { items => \@merged, source => 'pathfinder', ($layout ? (layout => $layout) : ()) };
                $cache->set($listKey, $result, $complete ? MFY_LIST_TTL : MFY_LIST_PARTIAL_TTL) if !$pfFailed;
                $cb->($result);
            };
            # every name homeSection delivers seeds or overwrites its name cache entry (no request)
            for my $m (grep { length $_->{name} } @merged) {
                my $c = $cache->get(MFY_NAME_KEY . $m->{id});
                next if ref($c) eq 'HASH' && defined $c->{name} && $c->{name} eq $m->{name};
                $cache->set(MFY_NAME_KEY . $m->{id}, { name => $m->{name} }, MFY_NAME_TTL);
            }
            my @nameless = grep { !length $_->{name} } @merged;
            if (@nameless) {
                $class->_resolveMfyNames($accountId, \@nameless, sub { $deliver->(@_) });
            }
            else {
                $deliver->(1);
            }
            return;
        }

        # Pathfinder yielded nothing (D-17: the rootlist 37i9 mixes take over,
        # whether the sources failed or merely listed no playlists).
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
                    name   => (defined $pl->{name} && length $pl->{name}) ? $pl->{name} : '',
                    images => [],
                };
            }
            $_mfy{mixCount} = scalar(@mixes);
            # pathfinderError: the menu says "unreachable" only when Pathfinder
            # really failed; "no results" when it answered and nothing is saved.
            $cb->({ items => \@mixes, source => 'rootlist-fallback', pathfinderError => $pfFailed });
        });
    };

    Plugins::SpotOn::API::Pathfinder->home($accountId, sub {
        my ($rows, $err) = @_;
        $homeRows = $rows;
        $homeErr  = $err;
        $finish->() if --$remaining == 0;
    });
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

# _resolveMfyNames($class, $accountId, $items, $done)
# 261110-is9 (spike 018): names for the items Pathfinder sent without one.
# Order per item: the name cache (a found name; a failed lookup of the last
# hour leaves the item unnamed without a request), then spclient
# playlist/v2/playlist/{id} as JSON, attributes.name, read through
# _playlistEnvelope (the measured request: Accept application/json, the shared
# gate, the 429 key and the 300 s envelope cache, so the envelope a lookup
# fetched also serves a list the user opens within 300 s), then Pathfinder
# playlistName (op fetchPlaylist). Bounds: the first MFY_NAME_MAX_LOOKUPS
# cache misses form the queue, at most MFY_NAME_PARALLEL are in flight and each
# starts only when a slot frees; the rest stay ''. A 429 from either source
# stops the build (nothing new starts, neither the next queue entry nor the
# Pathfinder step of an answer that arrives later; no cache entry for the
# stopped items).
# One timer ends the wait after MFY_NAME_BUDGET seconds. $done->($complete,
# \%counts) fires exactly once (counts: cache, playlist, pathfinder);
# $complete is 0 when the budget or a 429 cut the build short. After $done has
# fired no lookup starts (neither a queue entry nor a Pathfinder step), and an
# answer still out only writes the name cache, never the delivered items.
sub _resolveMfyNames {
    my ($class, $accountId, $items, $done) = @_;

    my %counts = (cache => 0, playlist => 0, pathfinder => 0);
    my @queue;
    for my $item (@$items) {
        my $c = $cache->get(MFY_NAME_KEY . $item->{id});
        if (ref($c) eq 'HASH' && defined $c->{name} && !ref($c->{name})) {
            if (length $c->{name}) {
                $item->{name} = $c->{name};
                $counts{cache}++;
            }
            next;
        }
        push @queue, $item;
    }
    splice(@queue, MFY_NAME_MAX_LOOKUPS) if @queue > MFY_NAME_MAX_LOOKUPS;

    unless (@queue) {
        $done->(1, \%counts);
        return;
    }

    my ($active, $finished, $stopped, $next, $budgetCb) = (0, 0, 0);
    my $finish = sub {
        my ($complete) = @_;
        return if $finished++;
        Slim::Utils::Timers::killTimers(undef, $budgetCb) if $budgetCb;
        undef $budgetCb;
        undef $next;    # breaks the closure cycle
        $done->($complete, \%counts);
    };
    $budgetCb = sub { $finish->(0) };
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + MFY_NAME_BUDGET, $budgetCb);

    # a lookup ended: free its slot and start the next one
    my $settle = sub { $active--; $next->() if $next; };
    # a name was found: the cache always, the item only while the build is still open
    my $named = sub {
        my ($item, $name, $source) = @_;
        $cache->set(MFY_NAME_KEY . $item->{id}, { name => $name }, MFY_NAME_TTL);
        return if $finished;
        $item->{name} = $name;
        $counts{$source}++;
    };
    my $usableName = sub { return (defined $_[0] && !ref($_[0]) && $_[0] =~ /\S/) ? 1 : 0 };

    $next = sub {
        return if $finished;
        my $item = $stopped ? undef : shift @queue;
        unless ($item) {
            $finish->($stopped ? 0 : 1) unless $active;
            return;
        }
        $active++;
        $class->_playlistEnvelope($accountId, $item->{id}, sub {
            my ($env, $err) = @_;
            my $attr = (ref($env) eq 'HASH' && ref($env->{attributes}) eq 'HASH') ? $env->{attributes} : {};
            if ($usableName->($attr->{name})) {
                $named->($item, $attr->{name}, 'playlist');
                $settle->();
                return;
            }
            if (ref($err) eq 'HASH' && ($err->{code} // 0) == 429) {
                $stopped = 1;
                $settle->();
                return;
            }
            # the budget or a 429 ended the build while this answer was out: no new request
            if ($finished || $stopped) {
                $settle->();
                return;
            }
            Plugins::SpotOn::API::Pathfinder->playlistName($accountId, $item->{id}, sub {
                my ($pname, $perr) = @_;
                if ($usableName->($pname)) {
                    $named->($item, $pname, 'pathfinder');
                }
                elsif (ref($perr) eq 'HASH' && ($perr->{code} // 0) == 429) {
                    $stopped = 1;
                }
                else {
                    $cache->set(MFY_NAME_KEY . $item->{id}, { name => '' }, MFY_NAME_NEG_TTL);
                }
                $settle->();
            });
        });
    };
    for (1 .. MFY_NAME_PARALLEL) {
        last if $finished || !$next;
        $next->();
    }
    return;
}

# _warnNamelessMfy($class, $noName, $dupCount, $counts)
# 261110-is9 (A1): one warning, at most once per MFY_NAME_WARN_INTERVAL
# (process-wide), when Pathfinder sent items without a usable name: the raw
# name types, the 11-character id families, the data key names of the first
# item and how the name resolution went. Type, key and family names and counts
# only: never a user name, a token or a full playlist id.
sub _warnNamelessMfy {
    my ($class, $noName, $dupCount, $counts) = @_;
    return unless @$noName;
    return if time() - $_mfyNameWarnAt < MFY_NAME_WARN_INTERVAL;
    $_mfyNameWarnAt = time();

    my (%types, %families);
    $types{ $_->{type} }++       for @$noName;
    $families{ $_->{family} }++  for @$noName;
    my ($cache_n, $pl_n, $pf_n) = map { $counts->{$_} // 0 } qw(cache playlist pathfinder);
    my $unresolved = scalar(@$noName) - $dupCount - $cache_n - $pl_n - $pf_n;
    $unresolved = 0 if $unresolved < 0;

    $log->warn('SpClient: Made for You -- ' . scalar(@$noName) . ' item(s) without a usable name from Pathfinder; raw name types: '
        . join(', ', map { "$_=$types{$_}" } sort keys %types)
        . '; id families: ' . join(', ', map { "$_=$families{$_}" } sort keys %families)
        . '; data keys: ' . $noName->[0]{keys}
        . "; resolved: duplicate=$dupCount, cache=$cache_n, playlist=$pl_n, pathfinder=$pf_n, unresolved=$unresolved"
        . ' (next such warning at the earliest in ' . MFY_NAME_WARN_INTERVAL . ' s)');
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
