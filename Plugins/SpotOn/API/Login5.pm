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

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# In-flight mint coalescing -- keyed by accountId, mirrors WebPlayer's
# %_mintInflight (WR-06 pattern): concurrent getToken() misses for the same
# account share a single login5 HTTP round-trip.
my %_mintInflight;

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
    main::INFOLOG && $log->info('Login5: mintInflight reset');
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

    $class->_mintToken($accountId, $cb);
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
    $_mintInflight{$accountId} = [$cb];

    my $resolve = sub {
        my ($token, $reason) = @_;
        my $queue = delete $_mintInflight{$accountId} || [];
        for my $qcb (@{$queue}) {
            eval { $qcb->($token, $reason); 1 }
                or $log->error("Login5: mint callback died: $@");
        }
    };

    require Plugins::SpotOn::API::Credentials;
    my $creds = Plugins::SpotOn::API::Credentials->verifyCredentials($accountId);
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
            $class->_handleResponse($accountId, $content, $resolve);
        },
        sub {
            my ($httpResp, $error) = @_;
            $log->warn('Login5: HTTP error minting token for account ' . _mask($accountId) . ": $error");
            $resolve->(undef, 'mint_failed');
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

    # field 3 (varint) = error code: 1=UNKNOWN, 2=INVALID_CREDENTIALS, 3=BAD_REQUEST
    my $errorCode = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 3);
    if (defined $errorCode && $errorCode != 0) {
        my $reason = ($errorCode == 2) ? 'invalid_credentials' : 'mint_failed';
        $log->warn("Login5: error code $errorCode for account " . _mask($accountId) . " ($reason)");
        $resolve->(undef, $reason);
        return;
    }

    # field 2 (len) = HashCash challenge. The librespot CID is verified
    # challenge-free (Spike 009) -- receiving one here means Spotify changed
    # behavior server-side; treat as a mint failure rather than attempting to
    # solve a challenge we don't implement.
    if (defined Plugins::SpotOn::API::ProtobufLite::field_first($fields, 2)) {
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

    my $cacheKey = "spoton_login5_token_${accountId}";
    $cache->set($cacheKey, $accessToken, $ttl);

    main::INFOLOG && $log->info('Login5: minted token for account ' . _mask($accountId)
        . " (ttl=${ttl}s, len=" . length($accessToken) . ')');

    $resolve->($accessToken, undef);
}

1;
