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

1;
