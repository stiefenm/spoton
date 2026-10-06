package Plugins::SpotOn::API::WebPlayer;

# Web-Player token lifecycle (D-06) -- fully independent from PKCE
# (TokenManager.pm) and Keymaster. Owns sp_dc storage, TOTP generation,
# the open.spotify.com/api/token mint, clienttoken.spotify.com acquisition,
# caching, in-flight coalescing, masking, and the multi-channel degradation
# state (D-03/D-04/D-05) consumed by Plugin.pm (OPML), Settings.pm, and
# Status.pm. TokenManager MUST NOT learn about Web-Player tokens (D-07).

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Digest::SHA qw(hmac_sha1);
use HTTP::Date qw(str2time);
require Plugins::SpotOn::Net;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

# Web-Player-scoped hosts (T-52-03) -- the sp_dc Cookie header is only ever
# attached to the TOKEN_URL request below (_requestToken). Never widen this
# set without re-auditing T-52-03.
use constant TOKEN_URL        => 'https://open.spotify.com/api/token';
use constant CLIENT_TOKEN_URL => 'https://clienttoken.spotify.com/v1/clienttoken';
use constant SERVER_TIME_URL  => 'https://open.spotify.com/';

use constant USER_AGENT => 'Mozilla/5.0 (X11; Linux x86_64) '
    . 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
use constant CLIENT_VERSION => '1.2.94.583.g60394bd5';

use constant TOKEN_EXPIRY_BUFFER => 60;    # seconds subtracted from mint TTL
use constant DEFAULT_TOKEN_TTL   => 3300;  # fallback TTL if expiry field is missing

# Degradation state enum (D-03/D-04/D-05, Open Question 3). Public query
# state($accountId)/statusSnapshot($accountId) are implemented below;
# _setState() is called from every mint transition so the cache stays in
# sync even when only getToken()/_mintToken() (not state()) is invoked.
use constant STATE_EMPTY        => 'empty';
use constant STATE_VALID        => 'valid';
use constant STATE_EXPIRED      => 'expired';
use constant STATE_SECRETS_DOWN => 'secrets_down';
use constant STATE_CACHE_TTL    => 300;    # 5 min pull-based state cache

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# Same shared cache instance/namespace as TokenManager.pm/PKCE.pm/Client.pm
# (cache version lives in Plugin.pm, single source of truth). Distinct key
# prefix spoton_wp_* keeps Web-Player entries out of PKCE's spoton_token_*
# namespace.
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# In-flight mint coalescing -- keyed by accountId, mirrors TokenManager's
# %_refreshInflight (H3/T-50-02 pattern): concurrent getToken() misses for
# the same account share a single mint HTTP chain.
my %_mintInflight;

# ============================================================
# TOTP (RFC 6238-derived, no base32 module -- RESEARCH Pitfall 1)
# ============================================================

# _totp($secret_bytes, $epoch)
# $secret_bytes: arrayref of ints 0..255 (validated SecretSource cipher).
# The reference algorithm base32-encodes the transformed decimal string
# then a TOTP library immediately base32-decodes it right back -- the two
# operations cancel, so the HMAC key is exactly the ASCII decimal
# concatenation of the transformed bytes. No CPAN base32/OATH module is
# needed (none is bundled with LMS -- CLAUDE.md forbids external deps).
sub _totp {
    my ($secret_bytes, $epoch) = @_;
    my @t = map { $secret_bytes->[$_] ^ (($_ % 33) + 9) } 0 .. $#$secret_bytes;
    my $key     = join('', @t);
    my $counter = int($epoch / 30);
    my $msg     = pack('N2', 0, $counter);
    my $hash    = hmac_sha1($msg, $key);
    my $off     = ord(substr($hash, -1)) & 0x0f;
    my $bin     = unpack('N', substr($hash, $off, 4)) & 0x7fffffff;
    return sprintf('%06d', $bin % 1_000_000);
}

# _mask($value)
# T-52-02/T-52-07: masked preview for log lines -- never log a full sp_dc,
# accountId, or token value. Copied verbatim from TokenManager.pm::_mask.
sub _mask {
    my ($value) = @_;
    return 'unknown' unless defined $value && length $value;
    return substr($value, 0, 4) . '****';
}

# ============================================================
# Plugins::SpotOn::API::WebPlayer::SecretSource (D-01 pluggable secret source)
# ============================================================
# Thin, config-selectable indirection over the TOTP secret feed. Today only
# the xyloflake/spot-secrets-go community JSON is implemented; the shape
# (getSecret($cb)) is designed so a future self-hosted source (deferred per
# CONTEXT.md) can be swapped in without touching TOTP or token code.
package Plugins::SpotOn::API::WebPlayer::SecretSource;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
require Plugins::SpotOn::Net;

use constant SECRET_URL => 'https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json';
use constant CACHE_KEY      => 'spoton_wp_secret';
use constant CACHE_TTL      => 6 * 3600;   # a few hours -- avoid per-mint refetch (RESEARCH Pattern 3)
use constant MAX_CIPHER_LEN => 64;         # bound untrusted array length (T-52-01)

# NOTE: $log and $cache are the SAME lexicals declared in the enclosing
# Plugins::SpotOn::API::WebPlayer package above -- a bare `package NAME;`
# statement (no block) does not open a new lexical scope in Perl, so they
# remain visible here. Re-declaring them with `my` would only shadow the
# originals and trigger a "masks earlier declaration" warning; reusing
# them keeps this package on the single shared cache/log instance.

# getSecret($class, $cb, $opts)
# cb->({ version => $int, cipher => [ints 0..255] }) on success.
# cb->(undef, 'unreachable') on ANY anomaly -- non-JSON, wrong shape,
# out-of-range values, unreachable host. NEVER dies, NEVER evals the
# fetched payload, NEVER treats the bytes as anything but TOTP input
# (T-52-01). $opts->{forceRefresh} bypasses the cache (Pitfall 2 retry).
sub getSecret {
    my ($class, $cb, $opts) = @_;
    $opts ||= {};

    unless ($opts->{forceRefresh}) {
        if (my $cached = $cache->get(CACHE_KEY)) {
            $cb->($cached);
            return;
        }
    }

    Plugins::SpotOn::Net->http(
        sub {
            my $http   = shift;
            my $result = $class->_parseAndValidate($http->content);
            unless ($result) {
                $log->warn('WebPlayer::SecretSource: xyloflake payload failed strict validation (T-52-01/D-05)');
                $cb->(undef, 'unreachable');
                return;
            }
            $cache->set(CACHE_KEY, $result, CACHE_TTL);
            $cb->($result);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("WebPlayer::SecretSource: fetch failed: $error (D-05)");
            $cb->(undef, 'unreachable');
        },
        { timeout => 30 }
    )->get(SECRET_URL());
}

# _parseAndValidate($class, $jsonStr)
# Pure function -- exposed for direct unit testing without live HTTP
# (Perl has no true sub privacy; the leading underscore is a naming
# convention only). Strictly validates untrusted xyloflake JSON (T-52-01):
# must decode to a hashref with at least one key; EVERY candidate key must
# be a positive integer and EVERY candidate value must be an arrayref of
# integers in 0..255 within MAX_CIPHER_LEN -- a single anomaly anywhere in
# the payload rejects the WHOLE payload (fail-closed) rather than silently
# falling back to a lower/different version. Selects the highest valid
# numeric version. Never eval's the payload, never dies.
sub _parseAndValidate {
    my ($class, $jsonStr) = @_;
    return undef unless defined $jsonStr && length $jsonStr;

    my $decoded = eval { from_json($jsonStr) };
    return undef if $@ || !$decoded || ref($decoded) ne 'HASH';
    return undef unless %$decoded;

    my $bestVersion;
    my $bestCipher;

    for my $key (sort keys %$decoded) {
        return undef unless $key =~ /^\d+$/;
        my $version = $key + 0;
        return undef unless $version > 0;

        my $value = $decoded->{$key};
        return undef unless ref($value) eq 'ARRAY';
        return undef unless @$value > 0 && @$value <= MAX_CIPHER_LEN;

        for my $b (@$value) {
            return undef unless defined $b && $b =~ /^-?\d+$/ && $b >= 0 && $b <= 255;
        }

        if (!defined $bestVersion || $version > $bestVersion) {
            $bestVersion = $version;
            $bestCipher  = $value;
        }
    }

    return undef unless defined $bestVersion;
    return { version => $bestVersion, cipher => $bestCipher };
}

package Plugins::SpotOn::API::WebPlayer;

# ============================================================
# sp_dc storage (D-06/D-09) -- owned exclusively by WebPlayer, never
# written to a flat/global key. Mirrors the `accounts` prefs hash pattern
# used by TokenManager.pm/PKCE.pm.
# ============================================================

# storeSpDc($class, $accountId, $spdc)
# Persists sp_dc under accounts->{$accountId}->{sp_dc}. Invalidates any
# cached token/client-token/state for the account so a re-pasted sp_dc
# takes effect on the next getToken() call. Returns 1 on success, 0 when
# $accountId is missing (validation result per Task 2 spec).
sub storeSpDc {
    my ($class, $accountId, $spdc) = @_;
    return 0 unless $accountId;

    $spdc = '' unless defined $spdc;
    $spdc =~ s/^\s+|\s+$//g;

    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} ||= {};
    $accounts->{$accountId}->{sp_dc} = $spdc;
    $prefs->set('accounts', $accounts);

    $cache->remove("spoton_wp_token_${accountId}");
    $cache->remove("spoton_wp_client_token_${accountId}");
    $cache->remove("spoton_wp_state_${accountId}");

    main::INFOLOG && $log->info('WebPlayer: sp_dc stored for account ' . _mask($accountId)
        . ' (' . _mask($spdc) . ')');

    return 1;
}

# hasSpDc($class, $accountId)
sub hasSpDc {
    my ($class, $accountId) = @_;
    my $spdc = _loadSpDc($accountId);
    return ($spdc && length $spdc) ? 1 : 0;
}

# spDcMaskedPreview($class, $accountId)
# Never returns the raw value (T-52-02/Pitfall 7) -- masked preview only,
# for Settings.pm rendering.
sub spDcMaskedPreview {
    my ($class, $accountId) = @_;
    my $spdc = _loadSpDc($accountId);
    return '' unless $spdc && length $spdc;
    return _mask($spdc);
}

# _loadSpDc($accountId)
sub _loadSpDc {
    my ($accountId) = @_;
    return undef unless $accountId;
    my $accounts = $prefs->get('accounts') || {};
    return $accounts->{$accountId} ? $accounts->{$accountId}->{sp_dc} : undef;
}

# reset($class)
# Clears in-flight mint queue. Called by Plugin.pm::initPlugin on startup
# to prevent stale coalescing state after plugin reload.
sub reset {
    my ($class) = @_;
    %_mintInflight = ();
    main::INFOLOG && $log->info('WebPlayer: mintInflight reset');
}

# ============================================================
# Token lifecycle -- getToken (D-07 single entry point)
# ============================================================

# getToken($class, $accountId, $cb)
# Cache-first, mirrors TokenManager::getToken's shape. Short-circuits
# BEFORE any mint attempt when sp_dc is absent (D-03) -- the SecretSource
# failure short-circuit (D-05) happens inside _mintToken since a secret
# fetch is required either way.
# cb->({ access_token => ..., client_token => ... }, undef) on success.
# cb->(undef, $reason) where $reason is one of no_spdc, no_secrets,
# expired, mint_failed.
sub getToken {
    my ($class, $accountId, $cb) = @_;

    my $cacheKey = "spoton_wp_token_${accountId}";
    if (my $cached = $cache->get($cacheKey)) {
        main::INFOLOG && $log->info('WebPlayer: token cache hit for account ' . _mask($accountId));
        $cb->($cached, undef);
        return;
    }

    unless (_loadSpDc($accountId)) {
        main::INFOLOG && $log->info('WebPlayer: no sp_dc configured for account '
            . _mask($accountId) . ' (D-03)');
        _setState($accountId, STATE_EMPTY);
        $cb->(undef, 'no_spdc');
        return;
    }

    $class->_mintToken($accountId, $cb);
}

# _mintToken($class, $accountId, $cb)
# In-flight coalescing (WR-06 eval-guarded drain) then the async chain:
# server time -> secret -> TOTP -> api/token -> client-token -> cache.
sub _mintToken {
    my ($class, $accountId, $cb) = @_;

    if ($_mintInflight{$accountId}) {
        main::INFOLOG && $log->info('WebPlayer: coalescing mint for account ' . _mask($accountId));
        push @{ $_mintInflight{$accountId} }, $cb;
        return;
    }
    $_mintInflight{$accountId} = [$cb];

    my $resolve = sub {
        my ($token, $reason) = @_;
        my $queue = delete $_mintInflight{$accountId} || [];
        for my $qcb (@{$queue}) {
            eval { $qcb->($token, $reason); 1 }
                or $log->error("WebPlayer: mint callback died: $@");
        }
    };

    my $spdc = _loadSpDc($accountId);
    unless ($spdc && length $spdc) {
        _setState($accountId, STATE_EMPTY);
        $resolve->(undef, 'no_spdc');
        return;
    }

    eval {
        Plugins::SpotOn::API::WebPlayer::SecretSource->getSecret(sub {
            my ($secret) = @_;
            unless ($secret) {
                main::INFOLOG && $log->info('WebPlayer: SecretSource unreachable for account '
                    . _mask($accountId) . ' (D-05)');
                _setState($accountId, STATE_SECRETS_DOWN);
                $resolve->(undef, 'no_secrets');
                return;
            }

            $class->_serverTime(sub {
                my ($epoch) = @_;
                $class->_requestToken($accountId, $spdc, $secret, $epoch, 0, $resolve);
            });
        });
        1;
    } or do {
        $log->error("WebPlayer: mint chain died for account " . _mask($accountId) . ": $@");
        $resolve->(undef, 'mint_failed');
    };
}

# _requestToken($class, $accountId, $spdc, $secret, $epoch, $isRetry, $resolve)
# GET open.spotify.com/api/token with the TOTP + Cookie header. On a
# totpVerExpired-style failure, force-refresh the secret and retry exactly
# once (Pitfall 2). On 400/401 -> 'expired' (D-04). Cookie header is NEVER
# logged (T-52-02).
sub _requestToken {
    my ($class, $accountId, $spdc, $secret, $epoch, $isRetry, $resolve) = @_;

    my $otp     = _totp($secret->{cipher}, $epoch);
    my $version = $secret->{version};

    my $url = TOKEN_URL()
        . '?reason=transport&productType=web-player'
        . '&totp=' . $otp . '&totpServer=' . $otp . '&totpVer=' . $version;

    Plugins::SpotOn::Net->http(
        sub {
            my $http      = shift;
            my $content   = $http->content // '';
            my $tokenData = eval { from_json($content) };
            if ($@ || !$tokenData || !$tokenData->{accessToken}) {
                if (!$isRetry && $content =~ /totpVerExpired/i) {
                    main::INFOLOG && $log->info('WebPlayer: totpVerExpired in 200 body for account '
                        . _mask($accountId) . ' -- forcing secret refresh (Pitfall 2)');
                    Plugins::SpotOn::API::WebPlayer::SecretSource->getSecret(sub {
                        my ($freshSecret) = @_;
                        unless ($freshSecret) {
                            _setState($accountId, STATE_SECRETS_DOWN);
                            $resolve->(undef, 'no_secrets');
                            return;
                        }
                        $class->_requestToken($accountId, $spdc, $freshSecret, $epoch, 1, $resolve);
                    }, { forceRefresh => 1 });
                    return;
                }
                $log->error('WebPlayer: token mint response parse failed for account '
                    . _mask($accountId) . ": $@");
                $resolve->(undef, 'mint_failed');
                return;
            }

            $class->_clientToken($tokenData->{clientId}, sub {
                my ($clientToken) = @_;

                unless ($clientToken) {
                    $log->warn('WebPlayer: client-token mint failed for account '
                        . _mask($accountId) . ' -- not caching partial result');
                    $resolve->(undef, 'mint_failed');
                    return;
                }

                my $result = {
                    access_token => $tokenData->{accessToken},
                    client_token => $clientToken,
                };

                $class->_cacheToken($accountId, $result, $tokenData->{accessTokenExpirationTimestampMs});
                _setState($accountId, STATE_VALID);
                $resolve->($result, undef);
            });
        },
        sub {
            my ($http, $error, $response) = @_;

            my $code = ($response && ref $response && $response->can('code'))
                ? ($response->code || 0) : 0;

            my $body;
            if ($response && ref $response && $response->can('content')) {
                $body = eval { $response->content };
            }
            $body = eval { $http->content } unless defined $body && length $body;

            my $looksVerExpired = defined $body && $body =~ /totpVerExpired/i;

            if ($looksVerExpired && !$isRetry) {
                main::INFOLOG && $log->info('WebPlayer: totpVerExpired for account '
                    . _mask($accountId) . ' -- forcing secret refresh and retrying once (Pitfall 2)');
                Plugins::SpotOn::API::WebPlayer::SecretSource->getSecret(sub {
                    my ($freshSecret) = @_;
                    unless ($freshSecret) {
                        _setState($accountId, STATE_SECRETS_DOWN);
                        $resolve->(undef, 'no_secrets');
                        return;
                    }
                    $class->_requestToken($accountId, $spdc, $freshSecret, $epoch, 1, $resolve);
                }, { forceRefresh => 1 });
                return;
            }

            if ($code == 401 || $code == 400) {
                $log->warn('WebPlayer: token mint expired/rejected for account '
                    . _mask($accountId) . " (D-04): http_code=$code");
                _setState($accountId, STATE_EXPIRED);
                $resolve->(undef, 'expired');
                return;
            }

            $log->error('WebPlayer: token mint HTTP error for account ' . _mask($accountId) . ": $error");
            # Transient failure -- do not overwrite a previously cached state (CR-02 fix)
            $resolve->(undef, 'mint_failed');
        },
        { timeout => 30 }
    )->get(
        $url,
        'User-Agent'   => USER_AGENT,
        'Accept'       => 'application/json',
        'Referer'      => 'https://open.spotify.com/',
        'App-Platform' => 'WebPlayer',
        'Cookie'       => "sp_dc=$spdc",   # NEVER log this header (T-52-02)
    );
}

# _clientToken($class, $clientId, $cb)
# POST clienttoken.spotify.com/v1/clienttoken. cb->($token) or cb->(undef)
# on any failure -- a missing client-token degrades the caller to
# 'mint_failed' rather than dying.
sub _clientToken {
    my ($class, $clientId, $cb) = @_;

    unless ($clientId) {
        $log->warn('WebPlayer: no clientId in token response, skipping client-token mint');
        $cb->(undef);
        return;
    }

    my $body = to_json({
        client_data => {
            client_version => CLIENT_VERSION,
            client_id      => $clientId,
            js_sdk_data    => {
                device_brand => '',
                device_id    => '',
                device_model => '',
                device_type  => '',
                os           => '',
                os_version   => '',
            },
        },
    });

    Plugins::SpotOn::Net->http(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };
            if ($@ || !$data || !$data->{granted_token} || !$data->{granted_token}->{token}) {
                my $code = $http->response ? $http->response->code : '?';
                my $len  = length($http->content // '');
                $log->warn("WebPlayer: client-token response parse failed (HTTP $code, ${len}B): $@");
                $cb->(undef);
                return;
            }
            $cb->($data->{granted_token}->{token});
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("WebPlayer: client-token HTTP error: $error");
            $cb->(undef);
        },
        { timeout => 30 }
    )->post(
        CLIENT_TOKEN_URL(),
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json',
        $body,
    );
}

# _serverTime($class, $cb)
# HEAD open.spotify.com/, read the Date response header (Pitfall 6 clock
# skew mitigation). Falls back to the local clock on any failure -- never
# blocks the mint chain on this being unavailable.
sub _serverTime {
    my ($class, $cb) = @_;

    Plugins::SpotOn::Net->http(
        sub {
            my $http  = shift;
            my $date  = eval { $http->headers ? $http->headers->header('Date') : undef };
            my $epoch = (!$@ && $date) ? str2time($date) : undef;
            $cb->($epoch || time());
        },
        sub {
            $cb->(time());
        },
        { timeout => 10 }
    )->head(SERVER_TIME_URL());
}

# _cacheToken($class, $accountId, $tokenHash, $expiresAtMs)
# TTL derived from accessTokenExpirationTimestampMs minus a safety buffer
# (mirrors TokenManager::_cacheToken). Never logs the token value itself.
sub _cacheToken {
    my ($class, $accountId, $tokenHash, $expiresAtMs) = @_;

    my $ttl = DEFAULT_TOKEN_TTL;
    if ($expiresAtMs && $expiresAtMs =~ /^\d+$/) {
        my $secondsLeft = int($expiresAtMs / 1000) - time();
        $ttl = $secondsLeft > TOKEN_EXPIRY_BUFFER
            ? $secondsLeft - TOKEN_EXPIRY_BUFFER
            : ($secondsLeft > 30 ? $secondsLeft : 30);
    }

    $cache->set("spoton_wp_token_${accountId}", $tokenHash, $ttl);
    main::INFOLOG && $log->info(
        'WebPlayer: token cached for account ' . _mask($accountId) . ", TTL ${ttl}s");
}

# _setState($accountId, $state)
# Cache-backed write side of the D-03/D-04/D-05 degradation enum, called
# from every mint transition (getToken/_mintToken/_requestToken). Three
# DISTINCT log call sites (one per cause) so empty/secrets_down/expired
# are separable in a diagnostic bundle -- empty and secrets_down at INFO,
# expired at WARN (D-04 is the one state that needs user attention).
sub _setState {
    my ($accountId, $state) = @_;
    return unless $accountId && $state;

    $cache->set("spoton_wp_state_${accountId}", $state, STATE_CACHE_TTL);

    if ($state eq STATE_EXPIRED) {
        $log->warn('WebPlayer: account ' . _mask($accountId) . ' sp_dc expired (D-04)');
    } elsif ($state eq STATE_SECRETS_DOWN) {
        main::INFOLOG && $log->info('WebPlayer: account ' . _mask($accountId)
            . ' TOTP secrets unavailable (D-05)');
    } elsif ($state eq STATE_EMPTY) {
        main::INFOLOG && $log->info('WebPlayer: account ' . _mask($accountId)
            . ' has no sp_dc configured (D-03)');
    }
}

# ============================================================
# Degradation state query (D-03/D-04/D-05, Open Question 3)
# ============================================================

# state($class, $accountId)
# Public pull-based query, modelled on TokenManager::needsReauth --
# cache-first, "innocent until proven guilty" default (a fresh sp_dc with
# no cached negative state reads as 'valid', matching needsReauth's
# default-to-fine semantics). Consumed by Plugin.pm (OPML, D-03/D-04),
# Settings.pm (D-04/D-08 status indicator), and Status.pm (D-04).
# Always returns exactly one of: empty | valid | expired | secrets_down.
#
# Derivation:
#   1. no sp_dc                                -> empty (D-03)
#   2. a token is cached                       -> valid (trumps any stale
#                                                  negative state below)
#   3. cached state says expired               -> expired (D-04)
#   4. cached state says secrets_down          -> secrets_down (D-05)
#   5. sp_dc present, nothing negative cached  -> valid (default)
sub state {
    my ($class, $accountId) = @_;
    return STATE_EMPTY unless $accountId;

    unless (_loadSpDc($accountId)) {
        _setState($accountId, STATE_EMPTY);
        return STATE_EMPTY;
    }

    if ($cache->get("spoton_wp_token_${accountId}")) {
        return STATE_VALID;
    }

    my $cachedState = $cache->get("spoton_wp_state_${accountId}") || '';
    return $cachedState if $cachedState eq STATE_EXPIRED || $cachedState eq STATE_SECRETS_DOWN;

    return STATE_VALID;
}

# statusSnapshot($class, $accountId)
# Plain hashref with NO token/secret/cookie values -- modelled on
# Client::statusSnapshot. Feeds Settings.pm (D-08) and Status.pm (D-04).
# Defaults to the active account when $accountId is omitted.
sub statusSnapshot {
    my ($class, $accountId) = @_;
    $accountId ||= $prefs->get('activeAccount');

    return { state => STATE_EMPTY, spDcPresent => 0, spDcMasked => '' } unless $accountId;

    my $spdc = _loadSpDc($accountId);
    return {
        state       => $class->state($accountId),
        spDcPresent => ($spdc && length $spdc) ? 1 : 0,
        spDcMasked  => ($spdc && length $spdc) ? _mask($spdc) : '',
    };
}

1;
