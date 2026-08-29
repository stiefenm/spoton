package Plugins::SpotOn::API::SpClient;

# spclient.spotify.com HTTP layer + capability-router facade (D-03/D-06/D-07,
# Phase 75 tracer). Fully standalone: NO compile-time dependency on Client.pm
# (D-03) -- Client.pm is runtime-require'd only inside the fallback paths, so
# this module can be loaded and its non-network subs (idToHex/hexToId,
# _normalizeTrack) exercised without ever touching Client.pm.
#
# Pipeline is a clone of Client.pm::_request/_doRequest (own inflight
# counter, own rate-limit cache key, same double-callback guard/eval
# discipline) but isolated: a spclient 429 must NEVER touch
# 'spoton_rate_limit' (D-03), and MAX_CONCURRENT_REQUESTS is more
# conservative than Client.pm's because the login5 (librespot CID) token
# shares a Spotify-side rate pool with the running librespot/Soloist daemon
# of the same account (D-09) -- a Browse burst here can trigger the
# Rapid-Skip audio-key throttle known error.
#
# Router (D-06/D-07): capability-based, not backend-based. An account with
# login5-capable stored credentials (ZeroConf/Keymaster/Soloist provenance)
# goes through spclient; a PKCE-only account, or any spclient-path failure,
# falls back to Client.pm transparently. The one exception is a single
# 401-triggered token remint retry (D-07a, user-approved refinement of D-07)
# -- an expired Bearer token is standard token lifecycle, not a spclient
# API failure; a SECOND 401 falls back immediately like any other error.

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
use constant MAX_CONCURRENT_REQUESTS => 2;                              # D-09: more conservative than Client.pm's 3
use constant RATE_LIMIT_DEFAULT_BACKOFF => 5;
use constant REQUEST_TIMEOUT         => 30;
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

# context-resolve (Liked Songs) + recently-played (S-09, Phase 75 Plan 04 Task 3)
use constant LIKED_SONGS_LIST_TTL   => 60;   # same tier -- Liked Songs is a library list
use constant RECENTLY_PLAYED_ACCEPT => 'vnd.spotify/collection-favorites';  # S-09: protobuf-only, value is documentation

# SET_MAP: verified collection/v2 set names (Spike 009 S-07). Saved Albums
# live under the confusingly generic 'collection' set (NOT 'album', which
# 403s). pinned_playlists/saved_episodes are documented here even though no
# facade in this plan consumes them yet (full verified mapping per plan spec).
use constant SET_MAP => {
    albums           => 'collection',
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

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# Module-level concurrency counter -- own, isolated from Client.pm's (D-03).
my $inflightCount = 0;

# ============================================================
# Lifecycle
# ============================================================

# reset($class)
# Zeroes the inflight counter and clears the rate-limit/host caches. Called
# by Plugin.pm::initPlugin on startup (wired in plan 75-06) to prevent stale
# state after plugin reload -- mirrors Client.pm->reset.
sub reset {
    my ($class) = @_;
    $inflightCount = 0;
    $cache->remove(SPCLIENT_RATE_LIMIT_KEY);
    $cache->remove(HOST_CACHE_KEY);
    main::INFOLOG && $log->info('SpClient: reset');
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
# D-06 routing criterion: does this account have login5-capable stored
# credentials (ZeroConf/Keymaster/Soloist provenance)?
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

# _isFallbackError($class, $err)
# D-07: any spclient-path failure classifies as fallback-to-Client.pm --
# HTTP 4xx/5xx, transport errors, and the local pre-flight short-circuits
# (no_token/no_credentials/rate_limited_local). There is no spclient retry
# beyond the single internal 401 remint (D-07a) handled inside _doRequest.
sub _isFallbackError {
    my ($class, $err) = @_;
    return 0 unless $err && ref($err) eq 'HASH';

    my $code = $err->{code} || 0;
    return 1 if $code >= 400 && $code < 600;

    my $reason = $err->{error} // '';
    return 1 if $reason =~ /^(?:no_token|no_credentials|invalid_credentials|mint_failed|rate_limited_local|internal_error|parse_error|unauthorized)$/;

    return 0;
}

# ============================================================
# Core request pipeline (Client.pm::_request/_doRequest clone, D-03)
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
            main::INFOLOG && $log->info("SpClient: request to $cleanPath short-circuited (cached rate limit)");
            $cb->(undef, { error => 'rate_limited_local', code => 429 });
            return;
        }
    }

    my $accountId = $params->{_accountId} // '';
    unless ($params->{_noCache}) {
        my $cacheKey = "spoton_spclient_resp_${accountId}_${cleanPath}";
        $params->{_cacheKey} = $cacheKey;
        if (my $cached = $cache->get($cacheKey)) {
            main::INFOLOG && $log->info("SpClient: cache hit for $cleanPath");
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
        $cb->(@_);
    };

    # H1: eval-guarded -- any die after $inflightCount++ must exit through
    # $userCb (the single decrement point with double-call guard), or the
    # counter leaks and all spclient traffic deadlocks.
    eval {
        $class->_doRequest($method, $cleanPath, $params, $userCb);
        1;
    } or do {
        $log->error("SpClient: dispatch failed for $cleanPath: $@");
        $userCb->(undef, { error => 'internal_error' });
    };
}

# _doRequest($class, $method, $cleanPath, $params, $userCb)
# Fetches a login5 Bearer token, resolves the spclient host, issues the HTTP
# call, and normalizes response/error -- including the single D-07a 401
# remint retry.
sub _doRequest {
    my ($class, $method, $cleanPath, $params, $userCb) = @_;

    my $accountId = $params->{_accountId};

    require Plugins::SpotOn::API::Login5;
    Plugins::SpotOn::API::Login5->getToken($accountId, sub {
        my ($token, $reason) = @_;

        unless ($token) {
            main::INFOLOG && $log->info('SpClient: no login5 token for account (reason=' . ($reason // '?') . ')');
            $userCb->(undef, { error => $reason || 'no_token' });
            return;
        }

        $class->_resolveHost(sub {
            my ($host) = @_;

            my $url    = "https://$host/$cleanPath";
            my $accept = $params->{_accept} || 'application/json';

            # T-02-10: never log the Authorization header value -- path+method only.
            main::INFOLOG && $log->info("SpClient: $method $cleanPath");

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
                            $log->error("SpClient: JSON parse error for $cleanPath: $@");
                            $userCb->(undef, { error => 'parse_error' });
                            return;
                        }
                    }

                    unless ($params->{_noCache}) {
                        my $ttl = $class->_cacheTTL($cleanPath);
                        if ($ttl > 0) {
                            my $cacheKey = $params->{_cacheKey} || "spoton_spclient_resp_$cleanPath";
                            $cache->set($cacheKey, $result, $ttl);
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
                        my $retryAfter = RATE_LIMIT_DEFAULT_BACKOFF;
                        if ($response && ref $response && $response->can('header')) {
                            my $headerVal = $response->header('Retry-After');
                            $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                        }
                        $retryAfter = 1   if $retryAfter < 1;
                        $retryAfter = 300 if $retryAfter > 300;

                        # D-03: own rate key -- never touches spoton_rate_limit.
                        $cache->set(SPCLIENT_RATE_LIMIT_KEY, Time::HiRes::time() + $retryAfter, $retryAfter);
                        $log->warn("SpClient: 429 rate limited for ${retryAfter}s on $cleanPath");

                        $userCb->(undef, { error => 'rate_limited', code => 429 });
                        return;
                    }

                    if ($code == 401) {
                        $cache->remove("spoton_login5_token_${accountId}") if $accountId;

                        # D-07a: exactly one remint retry on the FIRST 401 --
                        # refreshing an expired Bearer token is standard token
                        # lifecycle, not a spclient API failure. A second 401
                        # means the account cannot authenticate right now and
                        # falls back to Client.pm immediately (D-07).
                        if (!$params->{_retried401}) {
                            $log->warn("SpClient: 401 for $cleanPath, retrying once with a fresh token (D-07a)");
                            $params->{_retried401} = 1;
                            eval {
                                $class->_doRequest($method, $cleanPath, $params, $userCb);
                                1;
                            } or do {
                                $log->error("SpClient: 401 retry dispatch failed for $cleanPath: $@");
                                $userCb->(undef, { error => 'internal_error' });
                            };
                            return;
                        }

                        $log->warn("SpClient: 401 for $cleanPath after remint retry -- falling back to Client.pm");
                        $userCb->(undef, { error => 'unauthorized', code => 401 });
                        return;
                    }

                    $log->error("SpClient: HTTP $code error for $cleanPath: $error");
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
                $log->error("SpClient: HTTP dispatch failed for $cleanPath: $@");
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
    return 3600 if $path =~ m{^metadata/4/};
    return 300  if $path =~ m{^context-resolve/};
    return 0;
}

# ============================================================
# getTrack facade (D-06/D-07 tracer)
# ============================================================

# getTrack($class, $accountId, $trackId, $cb)
# Same cb contract as Client.pm::getTrack: cb->($result) on success,
# cb->(undef, $err) on error. No login5-capable creds -> immediate Client.pm
# delegation (D-06). A fallback-classified spclient error -> Client.pm
# delegation (D-07) so a spclient outage (GH #147-style) degrades invisibly.
sub getTrack {
    my ($class, $accountId, $trackId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getTrack to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getTrack($accountId, $trackId, $cb);
        return;
    }

    my $hexId = $class->idToHex($trackId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->_request('get', "metadata/4/track/$hexId", {
        _accountId => $accountId,
        _accept    => 'application/json',
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getTrack error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getTrack($accountId, $trackId, $cb);
                return;
            }
            $cb->(undef, $err);
            return;
        }

        $cb->($class->_normalizeTrack($result));
    });
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

# _spFacade($class, $path, $params, $normalize, $fallback, $cb)
# Shared D-07 request/normalize/fallback pattern reused by every metadata/4
# facade method below (album/artist/show/episode/search). Issues the
# spclient request; on success, hands the raw result to $normalize->($result,
# $cb) (which itself calls $cb -- may be sync or async, e.g. getAlbumTracks'
# enrichment pass); on a fallback-classified error (D-07), invokes
# $fallback->($cb) (delegates to the Client.pm method of the same name); on
# a non-fallback error, delivers the error as-is.
sub _spFacade {
    my ($class, $path, $params, $normalize, $fallback, $cb) = @_;

    $class->_request('get', $path, $params, sub {
        my ($result, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info("SpClient: error for $path, falling back to Client.pm (D-07): "
                    . ($err->{error} // '?'));
                $fallback->($cb);
                return;
            }
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

# _enrichTracks($class, $accountId, \@trackIds, $cb)
# Track-specific wrapper around _enrichMeta -- the reusable enrichment
# helper for search (this plan) and collection/playlist plans (75-04/75-05).
sub _enrichTracks {
    my ($class, $accountId, $trackIds, $cb) = @_;
    $class->_enrichMeta($accountId, $trackIds, 'track', '_normalizeTrack', $cb);
}

# ============================================================
# getAlbum / getAlbumTracks facades (D-06/D-07, S-04)
# ============================================================

# getAlbum($class, $accountId, $albumId, $cb)
# Same cb contract as Client.pm::getAlbum. No login5-capable creds -> Client
# delegation (D-06). Track names are NOT available in metadata/4/album
# (S-04) -- tracks.items is intentionally left empty; getAlbumTracks owns
# per-track enrichment.
sub getAlbum {
    my ($class, $accountId, $albumId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getAlbum to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getAlbum($accountId, $albumId, $cb);
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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getAlbum($accountId, $albumId, $fcb);
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
# per $params->{offset}/{limit} (defaults 0/50, matching Client.pm), and
# enriches ONLY the requested slice via _enrichTracks (lazy, D-09) -- a
# first-page call against a larger album issues exactly limit-many
# metadata/4/track requests, not one per album track.
sub getAlbumTracks {
    my ($class, $accountId, $albumId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getAlbumTracks to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, $params, $cb);
        return;
    }

    my $hexId = $class->idToHex($albumId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    # WR-01: named so the normalize closure below can reuse the SAME
    # fallback on an empty/malformed spclient success body (routes through
    # the identical Client.pm delegation every other spclient error already
    # uses, instead of dying inside the SimpleAsyncHTTP success callback).
    my $fallback = sub {
        my ($fcb) = @_;
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, $params, $fcb);
    };

    $class->_spFacade(
        "metadata/4/album/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            unless ($meta && ref($meta) eq 'HASH') {
                $fallback->($fcb);
                return;
            }

            my @gids;
            for my $disc (@{ $meta->{disc} || [] }) {
                for my $track (@{ $disc->{track} || [] }) {
                    push @gids, $track->{gid} if $track->{gid};
                }
            }

            my $total = scalar @gids;
            my $end   = $offset + $limit - 1;
            $end = $total - 1 if $end > $total - 1;
            my @sliceGids = ($offset < $total && $offset <= $end) ? @gids[$offset .. $end] : ();
            my @sliceIds  = map { $class->hexToId($_) } @sliceGids;

            $class->_enrichTracks($accountId, \@sliceIds, sub {
                my ($tracks) = @_;
                $fcb->({ items => $tracks, total => $total, offset => $offset, limit => $limit });
            });
        },
        $fallback,
        $cb,
    );
}

# ============================================================
# getArtist / getArtistAlbums facades (D-06/D-07)
# ============================================================

# getArtist($class, $accountId, $artistId, $cb)
# Same cb contract as Client.pm::getArtist.
sub getArtist {
    my ($class, $accountId, $artistId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getArtist to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getArtist($accountId, $artistId, $cb);
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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getArtist($accountId, $artistId, $fcb);
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
# arrays (each group entry wraps an album[] array) into a single Web-API
# album-stub list, sliced per $params->{offset}/{limit}. No per-album
# metadata calls -- embedded gid+name is all Plugin.pm's _albumItem/
# _artistAlbumsFeed consume.
sub getArtistAlbums {
    my ($class, $accountId, $artistId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 20;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getArtistAlbums to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getArtistAlbums($accountId, $artistId, $params, $cb);
        return;
    }

    my $hexId = $class->idToHex($artistId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    # WR-01: see getAlbumTracks for the named-fallback-reuse rationale.
    my $fallback = sub {
        my ($fcb) = @_;
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getArtistAlbums($accountId, $artistId, $params, $fcb);
    };

    $class->_spFacade(
        "metadata/4/artist/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            unless ($meta && ref($meta) eq 'HASH') {
                $fallback->($fcb);
                return;
            }

            my @albums;
            for my $groupKey (qw(album_group single_group compilation_group)) {
                for my $group (@{ $meta->{$groupKey} || [] }) {
                    for my $album (@{ $group->{album} || [] }) {
                        my $norm = $class->_normalizeAlbumStub($album);
                        push @albums, $norm if $norm;
                    }
                }
            }

            my $total = scalar @albums;
            my $end   = $offset + $limit - 1;
            $end = $total - 1 if $end > $total - 1;
            my @slice = ($offset < $total && $offset <= $end) ? @albums[$offset .. $end] : ();

            $fcb->({ items => \@slice, total => $total, offset => $offset, limit => $limit });
        },
        $fallback,
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
# invisibly to Client.pm; live verification is mandatory phase UAT.
# ============================================================

# getShow($class, $accountId, $showId, $cb)
sub getShow {
    my ($class, $accountId, $showId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getShow to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getShow($accountId, $showId, $cb);
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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getShow($accountId, $showId, $fcb);
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
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getShowEpisodes to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getShowEpisodes($accountId, $showId, $params, $cb);
        return;
    }

    my $hexId = $class->idToHex($showId);
    unless ($hexId) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    # WR-01: see getAlbumTracks for the named-fallback-reuse rationale.
    my $fallback = sub {
        my ($fcb) = @_;
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getShowEpisodes($accountId, $showId, $params, $fcb);
    };

    $class->_spFacade(
        "metadata/4/show/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;
            unless ($meta && ref($meta) eq 'HASH') {
                $fallback->($fcb);
                return;
            }

            my @gids = map { $_->{gid} } grep { $_->{gid} } @{ $meta->{episode} || [] };

            my $total = scalar @gids;
            my $end   = $offset + $limit - 1;
            $end = $total - 1 if $end > $total - 1;
            my @sliceGids = ($offset < $total && $offset <= $end) ? @gids[$offset .. $end] : ();
            my @sliceIds  = map { $class->hexToId($_) } @sliceGids;

            $class->_enrichMeta($accountId, \@sliceIds, 'episode', '_normalizeEpisode', sub {
                my ($episodes) = @_;
                $fcb->({ items => $episodes, total => $total, offset => $offset, limit => $limit });
            });
        },
        $fallback,
        $cb,
    );
}

# getEpisode($class, $accountId, $episodeId, $cb)
sub getEpisode {
    my ($class, $accountId, $episodeId, $cb) = @_;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getEpisode to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getEpisode($accountId, $episodeId, $cb);
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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getEpisode($accountId, $episodeId, $fcb);
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
# search router (D-06/D-07, S-05)
# ============================================================

# search($class, $accountId, $params, $cb)
# Client-identical signature/contract. Routing:
#   - type eq 'track' AND login5-capable account: context-resolve/v1
#     (20 track URIs, no offset support) -> lazy _enrichTracks on the
#     requested slice -> Web-API tracks.items shape.
#   - offset >= 20 (context-resolve's hard ceiling) OR offset beyond the
#     actual returned URI count: delegate to Client.pm (S-05 -- Web API
#     supports deeper offset paging, context-resolve does not; this is how
#     DSTM's/JiveLite's paging loop keeps working past the first 20).
#   - any other type value, OR a PKCE-only account: delegate to Client.pm
#     unchanged (S-05: context-resolve has no multi-type search).
#   - D-07: any context-resolve error -> Client.pm delegation.
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $type = $params->{type} // '';

    my $fallbackToClient = sub {
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->search($accountId, $params, $cb);
    };

    unless ($type eq 'track' && $class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: search delegating to Client.pm (multi-type or PKCE-only, S-05/D-06)');
        $fallbackToClient->();
        return;
    }

    my $query  = $params->{q}      // '';
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 10;

    # context-resolve returns at most 20 results (S-05) -- an offset at or
    # beyond that hard ceiling can never be satisfied here, so skip straight
    # to Client.pm without a wasted spclient call.
    if ($offset >= 20) {
        main::INFOLOG && $log->info('SpClient: search offset >= context-resolve ceiling, delegating to Client.pm (S-05)');
        $fallbackToClient->();
        return;
    }

    my $path = 'context-resolve/v1/spotify:search:' . uri_escape_utf8($query);

    $class->_request('get', $path, {
        _accountId => $accountId,
        _accept    => 'application/json',
    }, sub {
        my ($result, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: search context-resolve error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                $fallbackToClient->();
                return;
            }
            $cb->(undef, $err);
            return;
        }

        my @uris;
        if ($result && ref($result) eq 'HASH' && ref($result->{pages}) eq 'ARRAY') {
            my $page = $result->{pages}[0] || {};
            @uris = map { $_->{uri} } grep { ref($_) eq 'HASH' && $_->{uri} } @{ $page->{tracks} || [] };
        }

        if ($offset >= scalar(@uris)) {
            main::INFOLOG && $log->info('SpClient: search offset beyond context-resolve result count, delegating to Client.pm (S-05)');
            $fallbackToClient->();
            return;
        }

        my @trackIds = map { /^spotify:track:(.+)$/ ? $1 : () } @uris;
        my $end = $offset + $limit - 1;
        $end = $#trackIds if $end > $#trackIds;
        my @sliceIds = @trackIds[$offset .. $end];

        $class->_enrichTracks($accountId, \@sliceIds, sub {
            my ($tracks) = @_;
            $cb->({ tracks => { items => $tracks, total => scalar(@trackIds), limit => $limit, offset => $offset } });
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
# (COLLECTION_MAX_PAGES), which aborts as a fallback-classified error since
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
# Same cb contract as Client.pm::getSavedAlbums. Saved Albums live under the
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
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getSavedAlbums to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getSavedAlbums($accountId, $params, $cb);
        return;
    }

    $class->_collectionAll($accountId, SET_MAP->{albums}, sub {
        my ($list, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getSavedAlbums collection/v2 error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getSavedAlbums($accountId, $params, $cb);
                return;
            }
            $cb->(undef, $err);
            return;
        }

        my ($slice, $total) = $class->_sliceAsPage($list, $offset, $limit);

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
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getFollowedArtists to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getFollowedArtists($accountId, $params, $cb);
        return;
    }

    $class->_collectionAll($accountId, SET_MAP->{artists}, sub {
        my ($list, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getFollowedArtists collection/v2 error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getFollowedArtists($accountId, $params, $cb);
                return;
            }
            $cb->(undef, $err);
            return;
        }

        $list ||= [];
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
# Same offset/limit contract as Client.pm::getSavedShows. Saved Shows live
# under the collection/v2 set 'show' (S-07). metadata/4/show is
# spike-unverified (see the getShow/getShowEpisodes block above) -- rather
# than risk N per-item Client.pm fallback roundtrips if the endpoint is
# broadly broken for this account, the FIRST slice item's metadata fetch is
# probed first; a fallback-classified error there routes the WHOLE call to
# Client.pm in one shot. Only once the probe succeeds (or the slice is
# empty) does the remaining slice get enriched normally.
sub getSavedShows {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getSavedShows to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getSavedShows($accountId, $params, $cb);
        return;
    }

    # WR-02: honor $params->{_noCache} (Plugin.pm:2088's call shape) --
    # bypasses (without disabling) the 60s collection/v2 list cache on
    # demand.
    $class->_collectionAll($accountId, SET_MAP->{shows}, sub {
        my ($list, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getSavedShows collection/v2 error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getSavedShows($accountId, $params, $cb);
                return;
            }
            $cb->(undef, $err);
            return;
        }

        my ($slice, $total) = $class->_sliceAsPage($list, $offset, $limit);

        unless (@$slice) {
            $cb->({ items => [], total => $total, offset => $offset, limit => $limit });
            return;
        }

        my ($firstId) = (($slice->[0]{uri} // '')) =~ /^spotify:show:(.+)$/;
        my $firstHex  = $firstId ? $class->idToHex($firstId) : undef;

        my $afterProbe = sub {
            my ($firstResult, $firstErr) = @_;

            if ($firstErr && $class->_isFallbackError($firstErr)) {
                main::INFOLOG && $log->info('SpClient: getSavedShows metadata/4/show probe failed, '
                    . 'delegating the WHOLE call to Client.pm (D-07, avoids N per-item fallbacks)');
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getSavedShows($accountId, $params, $cb);
                return;
            }

            my @rest = (@$slice > 1) ? @{$slice}[1 .. $#$slice] : ();
            $class->_enrichCollectionSlice($accountId, \@rest, 'show', '_normalizeShow', 'show', sub {
                my ($restItems) = @_;

                my @items;
                unless ($firstErr) {
                    my $normFirst = $class->_normalizeShow($firstResult);
                    push @items, { added_at => $slice->[0]{added_at}, show => $normFirst } if $normFirst;
                }
                push @items, @$restItems;

                $cb->({ items => \@items, total => $total, offset => $offset, limit => $limit });
            });
        };

        unless ($firstHex) {
            $afterProbe->(undef, { error => 'invalid_id' });
            return;
        }

        $class->_request('get', "metadata/4/show/$firstHex", {
            _accountId => $accountId,
            _accept    => 'application/json',
        }, sub {
            my ($result, $err) = @_;
            $afterProbe->($result, $err);
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
# Same cb contract as Client.pm::getSavedTracks ({ items => [{track=>...}],
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
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getSavedTracks to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getSavedTracks($accountId, $params, $cb);
        return;
    }

    $class->_likedSongsUris($accountId, sub {
        my ($uris, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getSavedTracks context-resolve error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getSavedTracks($accountId, $params, $cb);
                return;
            }
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
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getRecentlyPlayed to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getRecentlyPlayed($accountId, $params, $cb);
        return;
    }

    my $username = $class->_username($accountId);
    unless ($username) {
        main::INFOLOG && $log->info('SpClient: no credentials username, delegating getRecentlyPlayed to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getRecentlyPlayed($accountId, $params, $cb);
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
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getRecentlyPlayed error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getRecentlyPlayed($accountId, $params, $cb);
                return;
            }
            $cb->(undef, $err);
            return;
        }

        my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($raw);
        unless ($fields) {
            main::INFOLOG && $log->info('SpClient: getRecentlyPlayed protobuf parse failure, falling back to Client.pm (T-75-12)');
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getRecentlyPlayed($accountId, $params, $cb);
            return;
        }

        my @trackUris;
        my %lastPlayed;
        for my $ctxBytes (@{ $fields->{1} || [] }) {
            my $ctxFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($ctxBytes);
            next unless $ctxFields;

            my $uri = Plugins::SpotOn::API::ProtobufLite::field_first($ctxFields, 1);
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
# rootlist endpoint (S-10 -- Accept header has no effect, always protobuf,
# unlike playlist/v2/playlist/{id}). cb->(\@playlists, undef) on success,
# cb->(undef, $err) on a request-level OR protobuf-parse failure (the
# latter reported as {error=>'parse_error'}, already fallback-classified by
# _isFallbackError -- T-75-12, never a crash on malformed bytes).
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
# Decodes the rootlist Response message (proto/rootlist_request.proto:
# Response.root is a Folder, field 1) and flattens the nested
# Folder->Item->{Playlist|Folder} tree into a flat arrayref of normalized
# playlist entries, in tree order (top-level items first, nested-folder
# playlists after). Returns undef on any top-level protobuf parse failure;
# an absent root Folder returns an empty arrayref (a rootlist response with
# zero playlists is not an error).
sub _parseRootlist {
    my ($class, $bytes) = @_;

    my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($bytes);
    return undef unless $fields;

    my $rootBytes = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 1);   # Response.root (Folder)
    return [] unless defined $rootBytes;

    my @playlists;
    $class->_flattenRootlistFolder($rootBytes, \@playlists, 0);
    return \@playlists;
}

# _flattenRootlistFolder($class, $folderBytes, \@playlists, $depth)
# Recursively walks a Folder message's repeated Item field (field 1),
# collecting normalized Playlist entries (Item.playlist, field 3) and
# recursing into nested Folder entries (Item.folder, field 2). T-75-16/V5:
# $depth is bounded at ROOTLIST_MAX_DEPTH -- a pathological/adversarial
# fixture with arbitrarily deep folder nesting cannot recurse unboundedly;
# anything beyond the cap is silently dropped rather than exhausting the
# call stack. A folder/item whose bytes fail to parse is skipped, never a
# die (Pitfall 6: untrusted network protobuf).
sub _flattenRootlistFolder {
    my ($class, $folderBytes, $playlists, $depth) = @_;
    return if $depth > ROOTLIST_MAX_DEPTH;

    my $folderFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($folderBytes);
    return unless $folderFields;

    for my $itemBytes (@{ $folderFields->{1} || [] }) {   # Folder.item (repeated Item)
        my $itemFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($itemBytes);
        next unless $itemFields;

        if (defined(my $plBytes = Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 3))) {   # Item.playlist
            my $norm = $class->_normalizePlaylistMeta($plBytes);
            push @$playlists, $norm if $norm;
        }
        elsif (defined(my $subFolderBytes = Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 2))) {   # Item.folder
            $class->_flattenRootlistFolder($subFolderBytes, $playlists, $depth + 1);
        }
    }
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
# Same cb contract as Client.pm::getUserPlaylists ({ items => [...], total,
# offset, limit }). No login5-capable creds -> Client delegation (D-06). A
# rootlist request/parse failure (fallback-classified, including the
# dedicated parse_error case, T-75-12) -> Client delegation (D-07).
sub getUserPlaylists {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};
    my $offset = $params->{offset} // 0;
    my $limit  = $params->{limit}  // 50;

    unless ($class->_hasLogin5Creds($accountId)) {
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getUserPlaylists to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getUserPlaylists($accountId, $params, $cb);
        return;
    }

    $class->_rootlistPlaylists($accountId, sub {
        my ($playlists, $err) = @_;

        if ($err) {
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getUserPlaylists rootlist error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getUserPlaylists($accountId, $params, $cb);
                return;
            }
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
# Same cb contract/signature as Client.pm::getPlaylistItems, INCLUDING the
# plain params-hashref variant ProtocolHandler.pm's explodePlaylist uses
# (no distinct opts arg -- Client.pm's own getPlaylistItems takes exactly
# this 5-arg shape, verified in read_first). The playlist/v2 envelope
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
        main::INFOLOG && $log->info('SpClient: no login5-capable credentials, delegating getPlaylistItems to Client.pm (D-06)');
        require Plugins::SpotOn::API::Client;
        Plugins::SpotOn::API::Client->getPlaylistItems($accountId, $playlistId, $params, $cb);
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
            if ($class->_isFallbackError($err)) {
                main::INFOLOG && $log->info('SpClient: getPlaylistItems playlist/v2 error, falling back to Client.pm (D-07): '
                    . ($err->{error} // '?'));
                require Plugins::SpotOn::API::Client;
                Plugins::SpotOn::API::Client->getPlaylistItems($accountId, $playlistId, $params, $cb);
                return;
            }
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
# Web-API-only passthrough delegations (Phase 75 Plan 06, Task 1)
# ============================================================
# These 13 methods have NO spclient equivalent that this plan's callers can
# rely on, so SpClient forwards them to Client.pm unchanged -- each is a
# one-line runtime-require + delegate, preserving the exact class-method
# calling convention and full argument list (including hashref opts). This
# makes SpClient a COMPLETE drop-in for every non-player Client.pm method
# the four browse consumers (Plugin.pm/ProtocolHandler.pm/Connect.pm/
# DontStopTheMusic.pm) use, so plan 75-06 Task 2's caller switch is a
# mechanical rename -- "Caller muessen idealerweise nur den Import aendern"
# (75-CONTEXT).
#
# Rationale per method:
#   - saveTracks/removeTracks/checkTracks/saveShows/removeShows/checkShows/
#     addToPlaylist: library WRITE/contains operations stay on the Web API
#     because collection/v2's write surface is untested and explicitly
#     deferred (75-CONTEXT Deferred Ideas) -- spclient READS are unified,
#     writes are not, in this phase.
#   - getTopTracks/getPersonalMixes/pathfinderHome/getWebPlayerPlaylistItems:
#     no spclient equivalent exists in the verified Spike-009 endpoint
#     catalog -- these stay Web-API/Web-Player-token-backed exactly as
#     Client.pm already implements them.
#   - getMe: a plain /me profile fetch has no spclient equivalent either;
#     delegated unchanged.
#   - getLimit: probe-detected endpoint limits are Client.pm-owned state
#     (%_detectedLimits/%_blockedEndpoints); probe-machinery cleanup is
#     deferred to Phase 76/77, so SpClient reads through rather than
#     duplicating the probe cache.

sub getLimit {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->getLimit(@_);
}

sub getMe {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->getMe(@_);
}

sub getTopTracks {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->getTopTracks(@_);
}

sub getPersonalMixes {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->getPersonalMixes(@_);
}

sub saveTracks {
    my $class = shift;
    # WR-02: invalidate the Liked Songs list cache so it's visible on the
    # very next getSavedTracks fetch, instead of staying stale for up to
    # 60s. Peeks $_[0] as the accountId without consuming @_ -- Client.pm
    # still gets the full original argument list.
    my $accountId = $_[0];
    $cache->remove("spoton_spclient_liked_${accountId}") if defined $accountId;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->saveTracks(@_);
}

sub removeTracks {
    my $class = shift;
    my $accountId = $_[0];
    $cache->remove("spoton_spclient_liked_${accountId}") if defined $accountId;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->removeTracks(@_);
}

sub checkTracks {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->checkTracks(@_);
}

sub saveShows {
    my $class = shift;
    # WR-02: invalidate the Saved Shows collection/v2 list cache so it's
    # visible on the very next getSavedShows fetch (matches the same
    # visible-on-next-fetch guarantee as the Liked Songs invalidation above).
    my $accountId = $_[0];
    $cache->remove("spoton_spclient_coll_${accountId}_" . SET_MAP->{shows}) if defined $accountId;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->saveShows(@_);
}

sub removeShows {
    my $class = shift;
    my $accountId = $_[0];
    $cache->remove("spoton_spclient_coll_${accountId}_" . SET_MAP->{shows}) if defined $accountId;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->removeShows(@_);
}

sub checkShows {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->checkShows(@_);
}

sub addToPlaylist {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->addToPlaylist(@_);
}

sub getWebPlayerPlaylistItems {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->getWebPlayerPlaylistItems(@_);
}

sub pathfinderHome {
    my $class = shift;
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->pathfinderHome(@_);
}

1;
