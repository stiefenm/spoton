package Plugins::SpotOn::API::PKCE;

use strict;
use warnings;

use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64 decode_base64);
use Crypt::OpenSSL::Random;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape);
use File::Spec::Functions qw(catdir catfile);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# Perl 5.10-safe base64url (MIME::Base64 < 3.11 lacks encode_base64url).
sub _encode_base64url {
    my $encoded = encode_base64($_[0], '');
    $encoded =~ tr|+/=|-_|d;
    return $encoded;
}

sub _decode_base64url {
    my $s = $_[0];
    $s =~ tr|-_|+/|;
    my $pad = length($s) % 4;
    $s .= '=' x (4 - $pad) if $pad;
    return decode_base64($s);
}

# ============================================================
# Constants
# ============================================================

# GitHub Pages static relay — registered as the redirect_uri in the Spotify
# Developer App. Bridges the OAuth callback back to the user's local LMS
# instance (edge cases A-D from urknall #176). Used for custom (own) Client ID.
use constant GITHUB_PAGES_REDIRECT_URI => 'https://stiefenm.github.io/spoton/auth/';

# Fixed loopback redirect URI used by the playerauth browser fallback
# (GH #147 plan 65-03). Spotify allows any port for loopback IPs (RFC 8252).
# Fixed port 18764: high port, no IANA registration, simpler for copy-paste
# UX and SSH tunnel docs. The account PKCE flow uses the dynamic
# loopbackCallbackRedirectUri() below instead (plan 65-04).
use constant LOOPBACK_REDIRECT_URI => 'http://127.0.0.1:18764/login';

# Spotify's internal Keymaster client_id — the provenance Login5 now requires
# for stored playback credentials (GH #147, D-02 secondary path). Access
# tokens minted with this client_id (scope: streaming, loopback redirect
# only — Spotify rejects non-loopback redirect URIs for it, gotcha 4) yield
# --token-login credentials that Login5 accepts (Music Assistant recipe,
# commit ec639766). Same value the Rust side uses as DISCOVERY_CLIENT_ID
# (main.rs); duplicated deliberately: D-03 forbids Rust changes and Perl
# cannot read Rust constants.
use constant KEYMASTER_CLIENT_ID => '65b708073fc0480ea92a077233ca87bd';

# 15 OAuth scopes required for Browse/Library/Player + credential derivation.
# 'streaming' is CRITICAL — without it, credential derivation (token-login)
# fails at the AP handshake (see credential-bridge.md).
use constant PKCE_SCOPES => [qw(
    streaming
    user-read-recently-played
    user-top-read
    user-library-read
    user-library-modify
    user-follow-read
    user-read-playback-state
    user-modify-playback-state
    user-read-currently-playing
    user-read-playback-position
    playlist-read-private
    playlist-modify-public
    playlist-modify-private
    user-read-email
    user-read-private
)];

use constant PKCE_VERIFIER_TTL => 600;              # 10 minutes — generous for auth flow completion
use constant PKCE_TOKEN_FILE   => 'pkce_tokens.json';

my $log = logger('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# ============================================================
# PKCE crypto
# ============================================================

# generateCodeVerifier()
# Returns a cryptographically random code_verifier per RFC 7636 section 4.1
# (43-128 chars, unreserved URI characters only: A-Z a-z 0-9 - . _ ~).
# base64url encoding without padding satisfies this character set.
sub generateCodeVerifier {
    my $bytes    = Crypt::OpenSSL::Random::random_bytes(64);
    return _encode_base64url($bytes);
}

# generateCodeChallenge($verifier)
# Returns the S256 code_challenge: base64url(SHA-256(verifier)), no padding.
sub generateCodeChallenge {
    my ($verifier) = @_;
    return _encode_base64url(sha256($verifier));
}

# ============================================================
# State parameter (bridges GitHub Pages relay -> LMS callback)
# ============================================================

# buildState($callbackUrl, $nonce)
# Encodes { callback_url, nonce } as base64url(JSON), no padding.
# The relay page decodes this to know where to redirect the browser.
sub buildState {
    my ($callbackUrl, $nonce) = @_;
    my $json  = to_json({ callback_url => $callbackUrl, nonce => $nonce });
    return _encode_base64url($json);
}

# parseState($stateStr)
# Decodes a state string built by buildState(). Returns the hashref, or
# undef (with a warning logged) if decoding/parsing fails for any reason.
sub parseState {
    my ($stateStr) = @_;
    my $data = eval {
        my $json = _decode_base64url($stateStr);
        from_json($json);
    };
    if ($@ || !$data) {
        $log->warn("PKCE: failed to parse state parameter: $@");
        return undef;
    }
    return $data;
}

# ============================================================
# OAuth endpoints
# ============================================================

# loopbackCallbackRedirectUri()
# Dynamic loopback redirect URI pointing at LMS's own pkce/callback endpoint
# (GH #147 plan 65-04). Keymaster accepts ANY 127.0.0.1 redirect URI (spike
# 2026-08-13), so the redirect can target the real _pkceCallbackHandler:
# when the browser runs on the LMS host, the redirect completes the flow
# automatically; otherwise the user copy-pastes the URL from the address
# bar into the manual fallback field. Reads the live LMS httpport so the
# URI stays correct across port changes.
sub loopbackCallbackRedirectUri {
    return 'http://127.0.0.1:' . (preferences('server')->get('httpport') || 9000)
        . '/plugins/SpotOn/settings/pkce/callback';
}

# buildAuthorizationUrl($clientId, $codeChallenge, $stateStr, $redirectUri, $scopes)
# Returns the full Spotify authorization URL for the browser to open.
# $redirectUri is caller-supplied (D-02): GITHUB_PAGES_REDIRECT_URI for a
# custom Client ID, loopbackCallbackRedirectUri() for the default account
# flow (plan 65-04), LOOPBACK_REDIRECT_URI for the playerauth browser
# fallback. The redirect used at exchange is guaranteed byte-identical to
# the one used here because both handlers read redirect_uri from the
# enriched verifier cache entry (phase-49 D-04 discipline).
# $scopes is an optional arrayref (GH #147 plan 65-03: the Keymaster browser
# fallback requests ['streaming'] only); when omitted, behavior is identical
# to before — the full PKCE_SCOPES list is used, so existing callers are
# unchanged.
sub buildAuthorizationUrl {
    my ($clientId, $codeChallenge, $stateStr, $redirectUri, $scopes) = @_;

    my $scope = join(' ', @{ $scopes || PKCE_SCOPES() });

    my $url = 'https://accounts.spotify.com/authorize'
        . '?client_id=' . uri_escape($clientId)
        . '&response_type=code'
        . '&redirect_uri=' . uri_escape($redirectUri)
        . '&scope=' . uri_escape($scope)
        . '&code_challenge_method=S256'
        . '&code_challenge=' . uri_escape($codeChallenge)
        . '&state=' . uri_escape($stateStr);

    return $url;
}

# exchangeCode($code, $clientId, $codeVerifier, $redirectUri, $cb)
# POSTs to Spotify's token endpoint to exchange an authorization code for
# access_token + refresh_token. No client_secret — PKCE replaces it with
# the code_verifier proof. $redirectUri MUST match the value used in
# buildAuthorizationUrl for this flow (D-02/D-04 -- callers read it back
# from the enriched verifier cache, not from live prefs, to stay race-free
# across a mode switch mid-flow). $cb->($tokenData) on success,
# $cb->(undef, $errorMsg) on failure.
sub exchangeCode {
    my ($code, $clientId, $codeVerifier, $redirectUri, $cb) = @_;

    my $maskedClient = substr($clientId, 0, 8) . '...';
    main::INFOLOG && $log->info("PKCE: exchanging authorization code [client_id=$maskedClient]");

    my $body = join('&',
        'grant_type=authorization_code',
        'code=' . uri_escape($code),
        'redirect_uri=' . uri_escape($redirectUri),
        'client_id=' . uri_escape($clientId),
        'code_verifier=' . uri_escape($codeVerifier),
    );

    require Slim::Networking::SimpleAsyncHTTP;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $tokenData = eval { from_json($http->content) };
            if ($@ || !$tokenData || !$tokenData->{access_token}) {
                $log->error("PKCE: token exchange response parse failed: $@");
                $cb->(undef, 'parse_error');
                return;
            }
            main::INFOLOG && $log->info("PKCE: token exchange succeeded [client_id=$maskedClient]");
            $cb->($tokenData);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("PKCE: token exchange HTTP error [client_id=$maskedClient]: $error");
            $cb->(undef, $error);
        },
        { timeout => 30 }
    )->post(
        'https://accounts.spotify.com/api/token',
        'Content-Type' => 'application/x-www-form-urlencoded',
        $body,
    );
}

# refreshAccessToken($refreshToken, $clientId, $cb)
# POSTs to Spotify's token endpoint to refresh an access_token. Spotify
# rotates the refresh_token on every call — the response includes a NEW
# refresh_token that the caller MUST persist atomically (storeTokens).
# $cb->($tokenData) on success.
# $cb->(undef, $errorMsg, $errorDetail) on failure -- $errorDetail is a
# hashref { http_code => $code, oauth_error => $str_or_undef } so callers
# (TokenManager) can distinguish a permanent revocation (400/invalid_grant)
# from a transient network failure (timeout/5xx) without re-deriving HTTP
# status parsing themselves.
sub refreshAccessToken {
    my ($refreshToken, $clientId, $cb) = @_;

    my $maskedClient = substr($clientId, 0, 8) . '...';
    main::INFOLOG && $log->info("PKCE: refreshing access token [client_id=$maskedClient]");

    my $body = join('&',
        'grant_type=refresh_token',
        'refresh_token=' . uri_escape($refreshToken),
        'client_id=' . uri_escape($clientId),
    );

    require Slim::Networking::SimpleAsyncHTTP;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $tokenData = eval { from_json($http->content) };
            if ($@ || !$tokenData || !$tokenData->{access_token}) {
                $log->error("PKCE: token refresh response parse failed: $@");
                $cb->(undef, 'parse_error');
                return;
            }
            main::INFOLOG && $log->info("PKCE: token refresh succeeded [client_id=$maskedClient]");
            $cb->($tokenData);
        },
        sub {
            # SimpleAsyncHTTP's ecb fires as ->ecb->($self, $error, $http->response)
            # (Slim/Networking/SimpleAsyncHTTP.pm:96) -- $response is the raw HTTP
            # response object, distinct from $http (the SimpleAsyncHTTP instance).
            my ($http, $error, $response) = @_;

            my $code = ($response && ref $response && $response->can('code'))
                ? ($response->code || 0) : 0;

            # A 400 or 401 from the token endpoint carries a JSON body with the
            # OAuth error type (RFC 6749), e.g. {"error":"invalid_grant",...} or
            # {"error":"invalid_client",...} (Spotify returns 401 for a revoked
            # or unknown client_id -- D-06). Try the response object first (most
            # likely to hold the body on a definitive HTTP error), then fall
            # back to $http->content for robustness.
            my $oauthError;
            if ($code == 400 || $code == 401) {
                my $rawBody;
                if ($response && ref $response && $response->can('content')) {
                    $rawBody = eval { $response->content };
                }
                if (!defined $rawBody || $rawBody eq '') {
                    $rawBody = eval { $http->content };
                }
                if (defined $rawBody && $rawBody ne '') {
                    my $errBody = eval { from_json($rawBody) };
                    $oauthError = $errBody->{error}
                        if !$@ && $errBody && ref $errBody eq 'HASH';
                }
            }

            my $errorDetail = { http_code => $code, oauth_error => $oauthError };

            $log->error("PKCE: token refresh HTTP error [client_id=$maskedClient]: $error");
            $cb->(undef, $error, $errorDetail);
        },
        { timeout => 30 }
    )->post(
        'https://accounts.spotify.com/api/token',
        'Content-Type' => 'application/x-www-form-urlencoded',
        $body,
    );
}

# ============================================================
# Token persistence (atomic write-then-rename, chmod 0600)
# ============================================================

# storeTokens($accountId, $tokenData)
# Atomically persists $tokenData (access_token, refresh_token, expires_at,
# client_id, scope) to {cachedir}/spoton/{accountId}/pkce_tokens.json.
# Write-then-rename avoids partial writes if the process dies mid-write.
# Returns 1 on success, 0 on failure.
sub storeTokens {
    my ($accountId, $tokenData) = @_;

    my $dir = _accountDir($accountId);
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir, { mode => 0700 });
    }

    my $target = catfile($dir, PKCE_TOKEN_FILE);
    my $tmp    = "$target.tmp.$$";

    my $maskedAccount = substr($accountId, 0, 4) . '****';

    my $ok = eval {
        require Fcntl;
        unlink($tmp) if -e $tmp;
        sysopen(my $fh, $tmp, Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL(), 0600)
            or die "sysopen failed: $!";
        print $fh to_json($tokenData);
        close($fh) or die "close failed: $!";
        rename($tmp, $target) or die "rename failed: $!";
        1;
    };

    if (!$ok) {
        $log->error("PKCE: storeTokens failed for account $maskedAccount: $@");
        unlink($tmp) if -e $tmp;
        return 0;
    }

    main::INFOLOG && $log->info("PKCE: tokens stored for account $maskedAccount");
    return 1;
}

# loadTokens($accountId)
# Reads and JSON-decodes pkce_tokens.json for the given account.
# Returns the hashref, or undef if the file is missing or unparseable.
sub deleteTokens {
    my ($accountId) = @_;
    my $target = catfile(_accountDir($accountId), PKCE_TOKEN_FILE);
    if (-f $target) {
        unlink $target;
        my $masked = substr($accountId, 0, 4) . '****';
        main::INFOLOG && $log->info("PKCE: tokens deleted for account $masked");
        return 1;
    }
    return 0;
}

sub loadTokens {
    my ($accountId) = @_;

    my $target = catfile(_accountDir($accountId), PKCE_TOKEN_FILE);
    return undef unless -f $target;

    my $maskedAccount = substr($accountId, 0, 4) . '****';

    my $data = eval {
        open(my $fh, '<', $target) or die "open failed: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        from_json($json);
    };

    if ($@ || !$data) {
        $log->error("PKCE: loadTokens failed for account $maskedAccount: $@");
        return undef;
    }

    return $data;
}

# ============================================================
# Verifier cache (bridges the /pkce/start -> /pkce/callback HTTP boundary)
# ============================================================

# storeVerifier($nonce, $data)
# Caches PKCE flow state under a nonce-keyed cache entry with a 10-minute
# TTL. $data is a hashref { verifier, redirect_uri, client_id } (D-04) --
# not a bare verifier string. Carrying redirect_uri and client_id alongside
# the verifier makes exchangeCode() race-free if the user switches between
# bundled/custom Client ID mode mid-flow (the callback/manual handler reads
# these cached values instead of re-deriving them from live prefs at
# callback time). The verifier NEVER leaves LMS (edge case A) — it is
# retrieved again only by loadAndDeleteVerifier() in the same process.
# $cache->set stores the hashref directly -- LMS DbCache serializes Perl
# structures via Storable.
sub storeVerifier {
    my ($nonce, $data) = @_;
    $cache->set("spoton_pkce_verifier_$nonce", $data, PKCE_VERIFIER_TTL);
}

# loadAndDeleteVerifier($nonce)
# Retrieves the { verifier, redirect_uri, client_id } hashref for $nonce and
# immediately removes the cache entry (one-time use — prevents replay,
# T-49-05). Returns the hashref, or undef if not found/expired.
sub loadAndDeleteVerifier {
    my ($nonce) = @_;
    my $key      = "spoton_pkce_verifier_$nonce";
    my $verifier = $cache->get($key);
    $cache->remove($key);
    return $verifier;
}

# ============================================================
# Private helpers
# ============================================================

# _accountDir($accountId)
# Same directory structure as TokenManager.pm uses:
# {cachedir}/spoton/{accountId}
sub _accountDir {
    my ($accountId) = @_;
    return catdir(preferences('server')->get('cachedir'), 'spoton', $accountId);
}

1;
