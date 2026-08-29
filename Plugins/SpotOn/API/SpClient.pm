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

            eval {
                $http->$method($url, @headers);
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
        my $hexId = $class->idToHex($ids->[$i]);

        my $finish = sub {
            my ($val) = @_;
            $results[$i] = $val;
            if (--$remaining == 0) {
                $cb->([ grep { defined } @results ]);
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

    $class->_spFacade(
        "metadata/4/album/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;

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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, $params, $fcb);
        },
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

    $class->_spFacade(
        "metadata/4/artist/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;

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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getArtistAlbums($accountId, $artistId, $params, $fcb);
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

    $class->_spFacade(
        "metadata/4/show/$hexId",
        { _accountId => $accountId, _accept => 'application/json' },
        sub {
            my ($meta, $fcb) = @_;

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
        sub {
            my ($fcb) = @_;
            require Plugins::SpotOn::API::Client;
            Plugins::SpotOn::API::Client->getShowEpisodes($accountId, $showId, $params, $fcb);
        },
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

1;
