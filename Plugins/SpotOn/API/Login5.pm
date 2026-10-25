package Plugins::SpotOn::API::Login5;

# login5 Bearer-token minting from stored credentials (D-04, Phase 75).
# Mirrors WebPlayer.pm's getToken/_mintToken lifecycle (cache -> mint ->
# in-flight coalescing, WR-06 eval-guarded drain) but mints against
# login5.spotify.com using the librespot Client ID, which Spike 009
# verified as challenge-free -- no HashCash solve, no client-token dance,
# just POST + parse. TokenManager.pm (PKCE) is untouched and unaware of
# this module (D-04).
#
# Security (V2/V7, T-75-01): the minted Bearer token, decoded auth_data
# bytes, and unmasked username/accountId are NEVER logged. _mask mirrors
# the discipline already established in Credentials.pm/TokenManager.pm.

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(decode_base64);
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

use Plugins::SpotOn::API::ProtobufLite;

# CID: librespot's public Client ID -- Spike 009 verified this mints a
# Bearer token directly (no HashCash challenge, no client-token header).
use constant LIBRESPOT_CLIENT_ID => '65b708073fc0480ea92a077233ca87bd';
use constant LOGIN5_URL          => 'https://login5.spotify.com/v3/login';
use constant REQUEST_TIMEOUT     => 30;

# Cache-TTL floor/buffer. The real TTL is ALWAYS derived from the login5
# response's own expires_in field (LoginOk field 4) -- never a hardcoded
# guess (RESEARCH.md A2). TOKEN_TTL_BUFFER shaves a safety margin off the
# server-advertised expiry so a cached token is never used past expiry;
# MIN_TOKEN_TTL is only a floor for pathologically short/zero expires_in.
use constant TOKEN_TTL_BUFFER => 60;
use constant MIN_TOKEN_TTL    => 60;

# LoginResponse.error (field 2) values, librespot login5.proto at the pinned
# commit 19959512 (also quoted in tools/spclient-smoke.pl). Anything else is
# reported as UNRECOGNIZED.
my %LOGIN_ERROR_NAME = (
    0 => 'UNKNOWN_ERROR',
    1 => 'INVALID_CREDENTIALS',
    2 => 'BAD_REQUEST',
    3 => 'UNSUPPORTED_LOGIN_PROTOCOL',
    4 => 'TIMEOUT',
    5 => 'UNKNOWN_IDENTIFIER',
    6 => 'TOO_MANY_ATTEMPTS',
    7 => 'INVALID_PHONENUMBER',
    8 => 'TRY_AGAIN_LATER',
);

# Only a credential-bound rejection marks the account invalid (D-06):
# INVALID_CREDENTIALS (1), and UNKNOWN_IDENTIFIER (5) -- login5 does not know
# the stored credential's identifier, so only a fresh pairing yields a working
# one. Every other code resolves plain mint_failed. In particular TIMEOUT (4),
# TOO_MANY_ATTEMPTS (6) and TRY_AGAIN_LATER (8) are NOT transient: the
# transient detail below (see $resolve, "{ transient => 1 }") is the
# network-failure channel; it drives the 60 s health retry and the
# DaemonManager->networkRecovered edge. A 60 s retry against a throttling
# answer would press login5 harder than it asked, and the recovery edge would
# schedule daemon restart checks for a condition that is not a network outage.
# The same holds for an HTTP status (WR-12): a 4xx (429 included) is login5's
# answer, not an outage; only a request that failed without any status (socket,
# connect, timeout) or a 5xx is transient.
my %INVALID_CREDENTIALS_ERROR = map { $_ => 1 } (1, 5);

# WR-11: TIMEOUT (4), TOO_MANY_ATTEMPTS (6), TRY_AGAIN_LATER (8) -- login5 asks
# to be left alone for a while; the negative cache uses the longer window.
my %THROTTLE_ERROR = map { $_ => 1 } (4, 6, 8);

# WR-11: a failed mint is remembered per account so user-driven requests do not
# re-POST to login5 on every click. MINT_DAMP_SECONDS is the default window for
# any failure after a login5 round-trip; a throttling answer (HTTP 429 with or
# without Retry-After, protobuf TIMEOUT/TOO_MANY_ATTEMPTS/TRY_AGAIN_LATER) uses
# THROTTLE_DAMP_SECONDS unless Retry-After says otherwise (clamped to
# MAX_DAMP_SECONDS). The health tick and forgetAccount() bypass/lift it.
use constant MINT_DAMP_SECONDS     => 15;
use constant THROTTLE_DAMP_SECONDS => 60;
use constant MAX_DAMP_SECONDS      => 300;

# Health tick (85-06, D-05 / RESEARCH P2): a forced mint for the active
# account every 45 minutes -- the cadence of the PKCE refresh timer it
# replaces (RESEARCH open question 3). The tick also repairs display names.
use constant HEALTH_TICK_SECONDS  => 2700;
use constant HEALTH_RETRY_SECONDS => 60;     # only after a transient failure

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# In-flight mint coalescing -- keyed by accountId, mirrors WebPlayer's
# %_mintInflight (WR-06 pattern): concurrent getToken() misses for the same
# account share a single login5 HTTP round-trip.
my %_mintInflight;

# WR-15: accountId => credential generation. forgetAccount() bumps it; a mint
# captures the generation it started with and, when the account was forgotten
# in the meantime, resolves its own callers but records no state and damps
# nothing (the verdict judged credentials that no longer exist). Monotonic:
# deliberately NOT cleared by reset(), so an old in-flight mint can never match
# a restarted counter.
my %_credGen;

# Last observed login state per account (85-06):
#   ok | invalid_credentials | no_credentials | transient
# Cleared by reset(); undef = not observed (or the last mint failed in a way
# that is none of the four, e.g. an unparsable answer).
my %_loginState;

# "The network is down" flag (RESEARCH P2, moved here from TokenManager's
# $_networkFailing): set by a tick whose mint failed transiently, cleared --
# with one DaemonManager->networkRecovered call -- by the next successful tick.
my $_networkFailing = 0;

# WR-11 negative cache: accountId => { until => epoch, reason, detail }.
my %_mintDamped;

# WR-09: set by shutdown(); a health tick whose mint is still in flight when the
# plugin shuts down must not re-arm itself from the mint callback. Cleared by
# reset() (initPlugin of a reload).
my $_shutdown = 0;

# _mask($value)
# T-75-01: masked preview for log lines -- never log a full accountId,
# username, or token value. Identical convention to Credentials.pm/_mask.
sub _mask {
    my ($value) = @_;
    return 'unknown' unless defined $value && length $value;
    return substr($value, 0, 4) . '****';
}

# reset($class)
# Clears in-flight mint queue. Called by Plugin.pm::initPlugin on startup
# to prevent stale coalescing state after plugin reload (plan 75-06 wiring).
sub reset {
    my ($class) = @_;
    %_mintInflight = ();
    %_loginState   = ();
    %_mintDamped   = ();
    $_networkFailing = 0;
    $_shutdown       = 0;
    main::INFOLOG && $log->info('Login5: mintInflight reset');
}

# shutdown($class)
# WR-09: called first thing by Plugin.pm::shutdownPlugin. Latches the health
# tick off (checked in _armHealthTimer) and kills a pending tick. killTimers
# alone is not enough: a tick whose mint is outstanding has no timer pending
# and would re-arm from the mint callback after the plugin is gone.
sub shutdown {
    my ($class) = @_;
    $_shutdown = 1;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&healthTick);
}

# forgetAccount($class, $accountId)
# WR-10: drops everything Login5 remembers about the credentials of one
# account -- the observed login state (an invalid_credentials verdict judged the
# OLD credentials) and the cached token minted with them. Called when the
# credentials change under the account: installAccountCredentials (same user
# paired again, same id) and TokenManager->removeAccount. Without it the stale
# verdict keeps hasValidLogin at 0 until the next health tick, and D-06 lets a
# second pairing take the active slot from a freshly re-paired account.
sub forgetAccount {
    my ($class, $accountId) = @_;
    return unless defined $accountId && length $accountId;
    delete $_loginState{$accountId};
    delete $_mintDamped{$accountId};
    # WR-15: a mint of the old credentials still in flight is orphaned: it
    # drains its own queue but writes no state, and new callers start a fresh
    # mint instead of coalescing onto it.
    $_credGen{$accountId}++;
    delete $_mintInflight{$accountId};
    $cache->remove("spoton_login5_token_${accountId}");
    main::INFOLOG && $log->info('Login5: forgot login state for account ' . _mask($accountId));
}

# getToken($class, $accountId, $cb)
# Cache-first. cb->($token, undef) on success.
# cb->(undef, $reason) where $reason is one of:
#   no_credentials, invalid_credentials, mint_failed
sub getToken {
    my ($class, $accountId, $cb) = @_;

    my $cacheKey = "spoton_login5_token_${accountId}";
    if (my $cached = $cache->get($cacheKey)) {
        main::INFOLOG && $log->info('Login5: token cache hit for account ' . _mask($accountId));
        $cb->($cached, undef);
        return;
    }

    # WR-11: a recent failed mint is answered again without a new round-trip.
    # Only getToken (user-driven requests) is damped; the health tick calls
    # _mintToken directly and stays a deliberate forced retry.
    if (my $damped = $_mintDamped{$accountId}) {
        if ($damped->{until} > Time::HiRes::time()) {
            main::INFOLOG && $log->info('Login5: mint for account ' . _mask($accountId)
                . ' damped after a recent failure (' . $damped->{reason} . ')');
            $cb->(undef, $damped->{reason}, $damped->{detail} ? { %{ $damped->{detail} } } : undef);
            return;
        }
        delete $_mintDamped{$accountId};
    }

    $class->_mintToken($accountId, $cb);
}

# _dampFailedMint($accountId, $reason, $detail, $seconds)
# WR-11: remember a failed mint for $seconds (default MINT_DAMP_SECONDS).
sub _dampFailedMint {
    my ($accountId, $reason, $detail, $seconds) = @_;
    $seconds = MINT_DAMP_SECONDS unless defined $seconds && $seconds > 0;
    $seconds = MAX_DAMP_SECONDS if $seconds > MAX_DAMP_SECONDS;
    $_mintDamped{$accountId} = {
        until  => Time::HiRes::time() + $seconds,
        reason => $reason // 'mint_failed',
        detail => (ref($detail) eq 'HASH' ? { %$detail } : undef),
    };
}

# _mintToken($class, $accountId, $cb)
# In-flight coalescing (WR-06 eval-guarded drain) then the mint chain:
# verifyCredentials -> build LoginRequest protobuf -> POST login5 -> parse
# LoginOk -> cache -> resolve.
sub _mintToken {
    my ($class, $accountId, $cb) = @_;

    if ($_mintInflight{$accountId}) {
        main::INFOLOG && $log->info('Login5: coalescing mint for account ' . _mask($accountId));
        push @{ $_mintInflight{$accountId} }, $cb;
        return;
    }
    my $queue = [$cb];
    $_mintInflight{$accountId} = $queue;
    my $gen   = $_credGen{$accountId} // 0;
    my $stale = sub { ($_credGen{$accountId} // 0) != $gen };

    # $detail (third argument) is { transient => 1 } for a network failure or
    # a 5xx and undef otherwise (WR-12); two-argument consumers ignore it.
    my $resolve = sub {
        my ($token, $reason, $detail) = @_;
        _recordLoginState($accountId, $token, $reason, $detail) unless $stale->();
        # WR-15: release only OUR queue; after forgetAccount the slot may hold
        # the queue of a newer mint.
        delete $_mintInflight{$accountId}
            if $_mintInflight{$accountId} && $_mintInflight{$accountId} == $queue;
        for my $qcb (splice @{$queue}) {
            eval { $qcb->($token, $reason, $detail); 1 }
                or $log->error("Login5: mint callback died: $@");
        }
    };

    # WR-11: outcomes that came from the login5 round-trip (HTTP success or
    # failure) feed the negative cache; a success lifts it. $dampSeconds is
    # optional. The local failures below (no credentials, undecodable
    # auth_data, a die in the credential check) send nothing and are not damped.
    my $resolveHttp = sub {
        my ($token, $reason, $detail, $dampSeconds) = @_;
        # WR-15: a mint of forgotten credentials neither lifts nor sets the damping.
        # WR-17: nor does it cache its token. The write is skipped, never undone
        # afterwards: a remove here would delete the NEW mint's token when the
        # old mint resolves last. _handleResponse hands the TTL up in $detail.
        if ($stale->()) { }
        elsif ($token) {
            $cache->set("spoton_login5_token_${accountId}", $token,
                ($detail && ref $detail eq 'HASH' && $detail->{ttl}) || MIN_TOKEN_TTL);
            delete $_mintDamped{$accountId};
        }
        else { _dampFailedMint($accountId, $reason, $detail, $dampSeconds) }
        # the ttl is internal: callers of a success get no detail
        $resolve->($token, $reason, $token ? undef : $detail);
    };

    # WR-02: the credential check runs inside an eval. A die here would leave
    # $_mintInflight{$accountId} set for good, and every later mint for the
    # account would queue behind it and hold a SpClient request slot. A die
    # releases the slot through $resolve (mint_failed).
    my $creds;
    my $checked = eval {
        require Plugins::SpotOn::API::Credentials;
        $creds = Plugins::SpotOn::API::Credentials->verifyCredentials($accountId);
        1;
    };
    unless ($checked) {
        my $err    = defined $@ ? "$@" : 'unknown error';
        my $masked = _mask($accountId);
        # T-75-01: a file path in the error text can carry the account id.
        $err =~ s/\Q$accountId\E/$masked/g if defined $accountId && length $accountId;
        $err =~ s/\s+\z//;
        $log->error("Login5: credential check died for account $masked: $err");
        $resolve->(undef, 'mint_failed');
        return;
    }
    unless ($creds) {
        main::INFOLOG && $log->info('Login5: no stored credentials for account ' . _mask($accountId) . ' (D-06 router will fall back)');
        $resolve->(undef, 'no_credentials');
        return;
    }

    my $username      = $creds->{username};
    my $authDataBytes = eval { decode_base64($creds->{auth_data}) };
    unless (defined $authDataBytes && length $authDataBytes) {
        $log->error('Login5: failed to decode auth_data for account ' . _mask($accountId));
        $resolve->(undef, 'mint_failed');
        return;
    }

    # Stable per-account device id (RESEARCH Open Question 2 resolution) --
    # deterministic, no MAC address needed.
    my $deviceId = md5_hex("spoton-login5-${accountId}");

    my $clientInfo = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, LIBRESPOT_CLIENT_ID)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $deviceId);
    my $storedCred = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $username)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $authDataBytes);
    my $body = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $clientInfo)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(100, 2, $storedCred);

    main::INFOLOG && $log->info('Login5: minting token for account ' . _mask($accountId));

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $httpResp = shift;
            my $content  = $httpResp->content // '';
            $class->_handleResponse($accountId, $content, $resolveHttp);
        },
        sub {
            my ($httpResp, $error, $response) = @_;
            $error = 'unknown error' unless defined $error;
            my $code = _httpErrorCode($error, $response);
            $log->warn('Login5: HTTP error minting token for account ' . _mask($accountId) . ": $error");
            # WR-12: LMS routes every non-2xx status through this same callback
            # as a socket failure. transient = the request itself failed (no
            # status) or the server did (5xx); a 4xx (429 included) is a
            # deterministic answer and never a network outage.
            # WR-14: deterministic only when login5 actually answered 4xx. A
            # 2xx/3xx response object next to an error text is a failure AFTER
            # the header line (Async/HTTP.pm _http_socket_error), i.e. a
            # network failure.
            my $detail = ($code >= 400 && $code < 500) ? undef : { transient => 1 };
            # WR-11: a 429 is damped for Retry-After when the server sent one.
            my $damp;
            if ($code == 429) {
                $damp = THROTTLE_DAMP_SECONDS;
                my $after = ($response && ref $response && eval { $response->can('header') })
                    ? eval { $response->header('Retry-After') } : undef;
                $damp = $after + 0 if defined $after && $after =~ /\A[0-9]{1,6}\z/ && $after > 0;
                # WR-16: carry the 429 and the retry window to the caller (the
                # damped replay copies the detail), so the menu can say
                # "rate limited" instead of "No results". Not transient: a
                # throttle answer is no network outage (WR-12).
                # WR-18: throttled => 1 is the transport-independent flag the
                # consumers test; the protobuf throttle answers carry it too.
                $detail = { throttled => 1, code => 429, retryAfter => ($damp > MAX_DAMP_SECONDS ? MAX_DAMP_SECONDS : $damp) };
            }
            $resolveHttp->(undef, 'mint_failed', $detail, $damp);
        },
        { timeout => REQUEST_TIMEOUT },
    );

    eval {
        $http->post(
            LOGIN5_URL,
            'Content-Type' => 'application/x-protobuf',
            'Accept'       => 'application/x-protobuf',
            $body,
        );
        1;
    } or do {
        $log->error("Login5: HTTP dispatch failed: $@");
        $resolve->(undef, 'mint_failed');
    };
}

# _httpErrorCode($error, $response)
# The HTTP status behind a SimpleAsyncHTTP error callback, 0 when the request
# itself failed. LMS (Slim::Networking::Async::HTTP) passes the status line
# ("429 Too Many Requests") as $error and the HTTP::Response as $response for a
# non-2xx answer; a socket/connect/timeout failure has neither a status-line
# error nor a response.
sub _httpErrorCode {
    my ($error, $response) = @_;
    my $code = 0;
    $code = $1 if defined $error && $error =~ /^(\d{3})\b/;
    if (!$code && $response && ref $response && eval { $response->can('code') }) {
        $code = eval { $response->code } || 0;
    }
    return $code + 0;
}

# _handleResponse($class, $accountId, $content, $resolve)
# Parses the login5 LoginOk/error response (2-level protobuf, S-01) and
# resolves the in-flight queue.
sub _handleResponse {
    my ($class, $accountId, $content, $resolve) = @_;

    my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($content);
    unless ($fields) {
        $log->error('Login5: failed to parse login5 response for account ' . _mask($accountId));
        $resolve->(undef, 'mint_failed');
        return;
    }

    # librespot login5.proto (pinned commit 19959512, quoted in
    # tools/spclient-smoke.pl:672-678):
    #   LoginResponse{ ok = 1, error = 2, challenges = 3, login_context = 5 }
    # field 2 (varint) = LoginError (see %LOGIN_ERROR_NAME). A field 2 that is
    # not a plain decimal number is malformed: no numeric comparison on it.
    my $errorCode = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 2);
    if (defined $errorCode) {
        unless (!ref($errorCode) && $errorCode =~ /\A[0-9]{1,10}\z/) {
            $log->warn('Login5: malformed error field in response for account ' . _mask($accountId));
            $resolve->(undef, 'mint_failed');
            return;
        }
        if ($errorCode != 0) {
            my $name   = $LOGIN_ERROR_NAME{$errorCode + 0} // 'UNRECOGNIZED';
            my $reason = $INVALID_CREDENTIALS_ERROR{$errorCode + 0} ? 'invalid_credentials' : 'mint_failed';
            $log->warn("Login5: login5 answered $name ($errorCode) for account " . _mask($accountId) . " -> $reason");
            # WR-18: the protobuf throttle answers surface like the HTTP 429:
            # the detail flags them (the damped replay copies it) so the menu
            # and the quality settings can say "rate limited" instead of "No
            # results" / "missing credentials". Not transient: no network
            # outage (WR-12), the login state is still cleared.
            if ($THROTTLE_ERROR{$errorCode + 0}) {
                $resolve->(undef, $reason,
                    { throttled => 1, loginError => $errorCode + 0, retryAfter => THROTTLE_DAMP_SECONDS },
                    THROTTLE_DAMP_SECONDS);
                return;
            }
            $resolve->(undef, $reason);
            return;
        }
    }

    # field 3 (len) = Challenges. The librespot CID is verified
    # challenge-free (Spike 009) -- receiving one here means Spotify changed
    # behavior server-side; treat as a mint failure rather than attempting to
    # solve a challenge we don't implement.
    if (defined Plugins::SpotOn::API::ProtobufLite::field_first($fields, 3)) {
        $log->warn('Login5: unexpected challenge in response for account ' . _mask($accountId)
            . ' (librespot CID is expected to be challenge-free)');
        $resolve->(undef, 'mint_failed');
        return;
    }

    my $loginOkBytes = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 1);
    unless (defined $loginOkBytes) {
        $log->error('Login5: no LoginOk payload in response for account ' . _mask($accountId));
        $resolve->(undef, 'mint_failed');
        return;
    }

    # S-01: the outer LoginOk (field 1) is itself length-delimited and, for a
    # real ~700+ byte response, requires a multi-byte varint length. A parser
    # that only reads one length byte truncates the token to ~31 chars here.
    my $inner = Plugins::SpotOn::API::ProtobufLite::parse_fields($loginOkBytes);
    unless ($inner) {
        $log->error('Login5: failed to parse LoginOk payload for account ' . _mask($accountId));
        $resolve->(undef, 'mint_failed');
        return;
    }

    my $accessToken = Plugins::SpotOn::API::ProtobufLite::field_first($inner, 2);
    my $expiresIn   = Plugins::SpotOn::API::ProtobufLite::field_first($inner, 4);

    unless (defined $accessToken && length $accessToken) {
        $log->error('Login5: no access_token in LoginOk for account ' . _mask($accountId));
        $resolve->(undef, 'mint_failed');
        return;
    }

    # A2: TTL is ALWAYS derived from the real expires_in field, never a
    # hardcoded 3600 guess.
    my $ttl = (defined $expiresIn && $expiresIn > 0)
        ? ($expiresIn - TOKEN_TTL_BUFFER)
        : MIN_TOKEN_TTL;
    $ttl = MIN_TOKEN_TTL if $ttl < MIN_TOKEN_TTL;

    # WR-17: the cache write happens in the caller's non-stale success branch
    # ($resolveHttp), which takes the TTL from the detail.
    main::INFOLOG && $log->info('Login5: minted token for account ' . _mask($accountId)
        . " (ttl=${ttl}s, len=" . length($accessToken) . ')');

    $resolve->($accessToken, undef, { ttl => $ttl });
}

# _recordLoginState($accountId, $token, $reason, $detail)
# Maps a mint outcome to the state loginState() reports. Any other failure
# (unparsable answer, unexpected challenge, undecodable auth_data) clears the
# state: it is not known to be ok and is none of the other three.
sub _recordLoginState {
    my ($accountId, $token, $reason, $detail) = @_;
    if ($token) {
        $_loginState{$accountId} = 'ok';
    }
    elsif (defined $reason && ($reason eq 'invalid_credentials' || $reason eq 'no_credentials')) {
        $_loginState{$accountId} = $reason;
    }
    elsif ($detail && ref($detail) eq 'HASH' && $detail->{transient}) {
        $_loginState{$accountId} = 'transient';
    }
    else {
        delete $_loginState{$accountId};
    }
}

# loginState($class, $accountId)
# Last login state observed by a mint for this account (85-06):
# 'ok' | 'invalid_credentials' | 'no_credentials' | 'transient' | undef (not
# observed). The input the auth switch (85-10, hasValidLogin) and the status
# page (85-09) read.
sub loginState {
    my ($class, $accountId) = @_;
    return undef unless defined $accountId && length $accountId;
    return $_loginState{$accountId};
}

# ============================================================
# Health tick (85-06, D-05, RESEARCH P2)
# ============================================================

# healthTick($class)
# Forced mint (bypasses the token cache) for the global active account, then
# the display-name repair, then re-arm. Called by the timer armed in
# Plugin.pm::initPlugin (first tick +20 s) with the package name as the timer
# "self"; re-arms itself: HEALTH_RETRY_SECONDS after a transient failure,
# HEALTH_TICK_SECONDS otherwise.
#
# The "network recovered" edge (RESEARCH P2, the transient/permanent split
# of TokenManager::_refreshToken): a transient failure sets $_networkFailing,
# the next success clears it and calls DaemonManager->networkRecovered once.
# invalid_credentials / no_credentials are permanent, they neither set the
# flag nor fire the edge. DaemonManager->networkRecovered is idempotent
# bookkeeping, so the PKCE refresh may fire the same edge until 85-14.
sub healthTick {
    my ($class) = @_;

    my $armed = 0;
    my $arm = sub {
        my ($delay) = @_;
        return if $armed++;
        $class->_armHealthTimer($delay // HEALTH_TICK_SECONDS);
    };

    my $accountId = $prefs->get('activeAccount') || '';
    unless ($accountId) {
        main::INFOLOG && $log->info('Login5: health tick without an active account -- nothing to mint');
        $arm->();
        return;
    }

    eval {
        $class->_mintToken($accountId, sub {
            my ($token, $reason, $detail) = @_;

            my $transient = (!$token && ref($detail) eq 'HASH' && $detail->{transient}) ? 1 : 0;

            # Whatever happens below, the tick must re-arm: one dying consumer
            # would otherwise end the health chain for good.
            eval {
                if ($token) {
                    if ($_networkFailing) {
                        $_networkFailing = 0;
                        eval {
                            require Plugins::SpotOn::Unified::DaemonManager;
                            Plugins::SpotOn::Unified::DaemonManager->networkRecovered;
                            1;
                        } or $log->warn("Login5: network recovery notice to DaemonManager failed: $@");
                    }
                    eval { $class->_repairDisplayNames; 1 }
                        or $log->warn("Login5: display-name repair died: $@");
                }
                elsif ($transient) {
                    main::INFOLOG && $log->info('Login5: transient health-tick failure -- retrying in '
                        . HEALTH_RETRY_SECONDS . 's');
                    $_networkFailing = 1;
                }
                1;
            } or $log->warn("Login5: health tick handler died: $@");

            $arm->($transient ? HEALTH_RETRY_SECONDS : HEALTH_TICK_SECONDS);
        });
        1;
    } or do {
        $log->warn("Login5: health tick mint died: $@");
        $arm->();
    };
}

# _armHealthTimer($class, $delaySeconds)
# killTimers-then-setTimer (T-02-15 idiom) -- exactly one pending tick.
# The timer "self" is the package name so Plugin.pm can kill the same timer.
sub _armHealthTimer {
    my ($class, $delay) = @_;
    return if $_shutdown;    # WR-09
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&healthTick);
    Slim::Utils::Timers::setTimer(__PACKAGE__, Time::HiRes::time() + $delay, \&healthTick);
}

# _repairDisplayNames($class)
# D-05: every account whose displayName still equals its spotifyUserId (the
# placeholder stored when no name was known) gets exactly one
# SpClient->getDisplayName lookup. A non-empty answer is stored as plain text
# (T-85-43: templates render it with `| html`); an undef answer changes
# nothing. Independent of PKCE.
sub _repairDisplayNames {
    my ($class) = @_;

    my $accounts = $prefs->get('accounts') || {};
    my @todo = grep {
        my $a = $accounts->{$_};
        ref($a) eq 'HASH' && $a->{displayName} && $a->{spotifyUserId}
            && $a->{displayName} eq $a->{spotifyUserId};
    } sort keys %$accounts;
    return unless @todo;

    require Plugins::SpotOn::API::SpClient;
    for my $id (@todo) {
        my $userId = $accounts->{$id}{spotifyUserId};
        eval {
            Plugins::SpotOn::API::SpClient->getDisplayName($id, sub {
                my ($name) = @_;
                return unless defined $name && !ref $name && length $name;

                # Re-read: the prefs may have changed while the lookup ran.
                my $current = $prefs->get('accounts') || {};
                my $entry   = $current->{$id};
                return unless ref($entry) eq 'HASH';
                return unless defined $entry->{displayName} && $entry->{displayName} eq $userId;

                $entry->{displayName} = $name;
                $prefs->set('accounts', $current);
                main::INFOLOG && $log->info('Login5: repaired display name for account ' . _mask($id));
            });
            1;
        } or $log->warn('Login5: display-name lookup died for account ' . _mask($id) . ": $@");
    }
}

1;
