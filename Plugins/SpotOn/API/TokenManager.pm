package Plugins::SpotOn::API::TokenManager;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;

use File::Spec::Functions qw(catdir catfile);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Constants
use constant TOKEN_EXPIRY_BUFFER   => 300;       # Refresh 5 min before expiry
use constant TOKEN_REFRESH_TIMER   => 45 * 60;   # 45 minute proactive refresh cycle
use constant SPOTIFY_ME_URL        => 'https://api.spotify.com/v1/me';
# M1: cache flag prefix for the persistent (TTL 'never') re-auth marker (D-08).
use constant REAUTH_FLAG_PREFIX    => 'spoton_needs_reauth_';

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# H3: In-flight refresh coalescing — keyed by accountId (no flavor, D-04).
# Each value is an arrayref of pending callbacks. Concurrent cache misses for
# the same account share a single PKCE::refreshAccessToken call, preventing
# a Refresh Token Rotation race (T-50-02).
my %_refreshInflight;

# ============================================================
# Public class methods
# ============================================================

# getToken($class, $accountId, $cb)
# Checks cache first; falls back to _refreshToken (PKCE-native) on miss.
# M-4: short-circuits with $cb->(undef) when the account is flagged
# needsReauth -- prevents a repeated HTTP POST to Spotify's token endpoint
# after a confirmed permanent refresh failure (every Browse click would
# otherwise re-trigger loadTokens + refreshAccessToken).
sub getToken {
    my ($class, $accountId, $cb) = @_;

    if ($class->needsReauth($accountId)) {
        main::INFOLOG && $log->info("TokenManager: short-circuit for account "
            . _mask($accountId) . " -- needsReauth flag set (M-4)");
        $cb->(undef);
        return;
    }

    my $cacheKey = "spoton_token_${accountId}";
    if (my $cached = $cache->get($cacheKey)) {
        main::INFOLOG && $log->info("TokenManager: cache hit for account " . _mask($accountId));
        # D-01: getToken is the single choke point every real API call passes
        # through (all Client.pm call sites obtain a token here before making
        # a request) -- the correct measurement point for "last API call".
        # 24h TTL: a dormant account's timestamp naturally expires rather than
        # showing stale "recent activity" forever.
        $cache->set("spoton_last_api_call_${accountId}", time(), 86400);
        $cb->($cached);
        return;
    }

    $class->_refreshToken($accountId, $cb);
}

sub clearCachedToken {
    my ($class, $accountId) = @_;
    $cache->remove("spoton_token_${accountId}");
    $cache->remove(REAUTH_FLAG_PREFIX . $accountId);
}

# removeAccount($class, $accountId)
# Removes account from prefs and cache. Single token cache key (no flavor,
# D-04) plus the re-auth flag are both cleared.
sub removeAccount {
    my ($class, $accountId) = @_;

    # Remove from prefs
    my $accounts = $prefs->get('accounts') || {};
    delete $accounts->{$accountId};
    $prefs->set('accounts', $accounts);

    # D-04: single cache key, no flavor suffix.
    $cache->remove("spoton_token_${accountId}");
    $cache->remove(REAUTH_FLAG_PREFIX . $accountId);

    # M2: Remove the account's credentials directory from disk — a "removed"
    # account must not leave its Spotify credentials/pkce_tokens.json behind.
    # Safety: only the per-ACCOUNT dir, never the shared spoton cache root —
    # assert the path ends in the accountId segment before removing.
    if ($accountId) {
        my $serverPrefs = preferences('server');
        my $acctDir = catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
        if (-d $acctDir && $acctDir =~ m{[/\\]\Q$accountId\E$}) {
            require File::Path;
            # WR-07: remove_tree does not die on failure by default — it carps
            # and returns the count. Use the { error => \$errs } form and fall
            # back to a directory-existence check for full coverage (M2).
            File::Path::remove_tree($acctDir, { error => \my $errs });
            if ($errs && @$errs) {
                $log->warn("TokenManager: failed to fully remove credentials dir for "
                    . _mask($accountId) . ": " . join('; ', map { join(': ', %$_) } @$errs));
            } elsif (-d $acctDir) {
                $log->warn("TokenManager: credentials dir for " . _mask($accountId) . " still present after removal");
            } else {
                main::INFOLOG && $log->info("TokenManager: removed credentials dir for account " . _mask($accountId));
            }
        }
    }

    # Clear active account if it was this one
    my $active = $prefs->get('activeAccount') || '';
    if ($active eq $accountId) {
        $prefs->set('activeAccount', '');

        # Stop all daemons — they're running with stale credentials
        if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
            require Plugins::SpotOn::Unified::DaemonManager;
            Plugins::SpotOn::Unified::DaemonManager->shutdown();
            Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
        }
    }

    main::INFOLOG && $log->info("TokenManager: account " . _mask($accountId) . " removed");
}

# getAccountIds($class)
# Returns list of known account IDs in sorted order.
# Sorted to stabilize every consumer iteration (Status auth-health
# collection, Settings account list).  Display determinism itself
# lives in status.html's Object.keys().sort() (GH #138).
sub getAccountIds {
    my ($class) = @_;
    my $accounts = $prefs->get('accounts') || {};
    my @ids = sort keys %{$accounts};
    return @ids;
}

# getActiveAccountName($class, $client)
# Returns displayName of active account, or undef.
sub getActiveAccountName {
    my ($class, $client) = @_;

    my $activeId;
    if ($client) {
        $activeId = $prefs->client($client)->get('activeAccount');
    }
    $activeId ||= $prefs->get('activeAccount');

    return undef unless $activeId;

    my $accounts = $prefs->get('accounts') || {};
    return $accounts->{$activeId} ? $accounts->{$activeId}{displayName} : undef;
}

# needsReauth($class, $accountId)
# Public query: returns 1 if the account's persistent re-auth flag is set,
# 0 otherwise. Read by Plugin.pm handleFeed() (Channel 1) and Settings.pm
# handler() (Channel 2) -- wired in Plan 03.
sub needsReauth {
    my ($class, $accountId) = @_;
    return $cache->get(REAUTH_FLAG_PREFIX . $accountId) ? 1 : 0;
}

# reauthReason($class, $accountId)
# Public query (D-06): returns the reason string stored in the {reason, ts}
# hashref written by _markNeedsReauth() for this account's persistent
# re-auth flag, or undef if no flag is set. Lets Plugin.pm/Settings.pm
# distinguish bundled_id_unavailable (default/bundled Client ID rejected) from
# custom_id_invalid or other reasons (e.g. invalid_grant/token_rejected) for
# targeted display messaging.
sub reauthReason {
    my ($class, $accountId) = @_;
    my $flag = $cache->get(REAUTH_FLAG_PREFIX . $accountId);
    return undef unless $flag && ref $flag eq 'HASH';
    return $flag->{reason};
}

# anyAccountNeedsReauth($class)
# Public query: returns 1 if ANY known account needs re-auth. Used for the
# OPML-menu-wide warning item (Channel 1) and Settings-page-wide banner
# (Channel 2).
sub anyAccountNeedsReauth {
    my ($class) = @_;
    for my $id ($class->getAccountIds()) {
        return 1 if $class->needsReauth($id);
    }
    return 0;
}

# accountNeedsMigration($class, $accountId)
# Public query (D-05, AUTH-07): proactive, filesystem-based detection of
# v2.x ZeroConf accounts that have never completed PKCE auth -- distinct
# from needsReauth (which only fires reactively after a failed refresh).
# Formula: credentials.json exists AND pkce_tokens.json does not. Composes
# two existing primitives (never adds a new raw -f/stat call, per
# PATTERNS.md): Credentials->credentialsPathFor() for the existence check,
# PKCE::loadTokens() for the absence check (falsy on any absence/parse
# failure). Deliberately does NOT use Credentials->verifyCredentials() --
# a credentials.json with a non-standard auth_type still indicates a v2.x
# user who needs to migrate.
sub accountNeedsMigration {
    my ($class, $accountId) = @_;
    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::API::PKCE;

    return 0 unless -f Plugins::SpotOn::API::Credentials->credentialsPathFor($accountId);
    return Plugins::SpotOn::API::PKCE::loadTokens($accountId) ? 0 : 1;
}

# anyAccountNeedsMigration($class)
# Public query: returns 1 if ANY known account needs migration (D-05).
# Convenience aggregate for Settings.pm's global migration banner (Channel 2,
# checks all accounts) -- mirrors anyAccountNeedsReauth's shape. OPML's
# per-render migration hint (Channel 1) calls accountNeedsMigration directly
# for the single active account instead (deliberate asymmetry, see 53-03
# review finding: OPML always operates on the active account).
sub anyAccountNeedsMigration {
    my ($class) = @_;
    for my $id ($class->getAccountIds()) {
        return 1 if $class->accountNeedsMigration($id);
    }
    return 0;
}

# clearNeedsReauth($class, $accountId)
# PUBLIC method (no underscore prefix, L-6) -- cross-module API. Called from
# _refreshToken() on successful refresh, and from Settings.pm's
# _pkceStoreAccount() (Plan 03) immediately after a fresh PKCE re-auth,
# rather than waiting for the next 45-minute refresh cycle to self-heal.
sub clearNeedsReauth {
    my ($class, $accountId) = @_;
    $cache->remove(REAUTH_FLAG_PREFIX . $accountId);
}

# markNeedsReauth($class, $accountId, $reason)
# PUBLIC method (no underscore prefix) -- cross-module API, mirrors the
# clearNeedsReauth convention above. Thin delegating wrapper around the
# private _markNeedsReauth implementation (Phase 50 D-08 4-channel
# escalation) -- called by DaemonManager's D-03/D-04 crash-recovery flow
# (_handleCredentialCrash) when a credential re-derivation permanently
# fails. Never duplicates the notification plumbing; the private method
# remains the single implementation.
sub markNeedsReauth {
    my ($class, $accountId, $reason) = @_;
    $class->_markNeedsReauth($accountId, $reason);
}

# refreshAllTokens($class)
# M-5: Calls _refreshToken() DIRECTLY (bypassing getToken's cache check) so
# the proactive refresh cycle always exchanges a fresh token, not a cache
# hit no-op. This also keeps the refresh_token alive against Spotify's
# 6-month inactivity expiry. D-07: only accounts with a loadable
# pkce_tokens.json are refreshed -- accounts without one (pre-PKCE-migration,
# or stale prefs entries) are skipped at INFO level, not flagged as expired
# (Pitfall 3). Preserves the displayName-repair branch (M-5).
sub refreshAllTokens {
    my ($class) = @_;

    require Plugins::SpotOn::API::PKCE;

    my $accounts = $prefs->get('accounts') || {};
    my @ids = $class->getAccountIds();
    for my $id (@ids) {
        my $acct = $accounts->{$id} || {};

        unless (Plugins::SpotOn::API::PKCE::loadTokens($id)) {
            main::INFOLOG && $log->info("TokenManager: account " . _mask($id)
                . " skipped -- no PKCE tokens (pre-migration account)");
            next;
        }

        # WR-03: respect M-4 needsReauth flag — permanently rejected accounts
        # must not be retried on the 45-min cycle (cleared via clearNeedsReauth
        # on successful re-auth).
        if ($class->needsReauth($id)) {
            main::INFOLOG && $log->info("TokenManager: account " . _mask($id)
                . " skipped -- needsReauth flag set");
            next;
        }

        my $needsDisplayName = $acct->{displayName}
            && $acct->{spotifyUserId}
            && $acct->{displayName} eq $acct->{spotifyUserId};

        if ($needsDisplayName) {
            $class->_fetchDisplayName($id, $acct->{spotifyUserId}, sub {
                main::INFOLOG && $log->info("TokenManager: updated displayName for " . _mask($id));
            });
        } else {
            $class->_refreshToken($id, sub {
                my $token = shift;
                main::INFOLOG && $log->info("TokenManager: refreshed token for account " . _mask($id))
                    if $token;
                unless ($token) {
                    $log->error("TokenManager: failed to refresh token for account " . _mask($id));
                }
            });
        }
    }

    # Re-arm timer (AUTH-05 timer continuity)
    Slim::Utils::Timers::killTimers($class, \&refreshAllTokens);
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + TOKEN_REFRESH_TIMER,
        \&refreshAllTokens
    );
}

# ============================================================
# Private methods
# ============================================================

# _refreshToken($class, $accountId, $cb)
# PKCE-native refresh: loadTokens -> refreshAccessToken -> storeTokens
# (rotated refresh_token) -> _cacheToken -> $cb. No subprocess (AUTH-05).
# H3: in-flight coalescing -- concurrent callers for the same accountId
# queue their callbacks and share a single refreshAccessToken call.
sub _refreshToken {
    my ($class, $accountId, $cb) = @_;

    if ($_refreshInflight{$accountId}) {
        main::INFOLOG && $log->info("TokenManager: coalescing refresh for account " . _mask($accountId));
        push @{ $_refreshInflight{$accountId} }, $cb;
        return;
    }
    $_refreshInflight{$accountId} = [$cb];

    # Drains ALL queued callbacks with the same result. The key is deleted
    # BEFORE invoking callbacks so a callback that re-triggers a refresh
    # does not self-coalesce into a dead entry.
    my $resolve = sub {
        my ($token) = @_;
        my $queue = delete $_refreshInflight{$accountId} || [];
        # WR-06: eval-guard each callback — one dying consumer must not starve
        # remaining waiters or leak Client.pm's inflight counter.
        for my $qcb (@{$queue}) {
            eval { $qcb->($token); 1 }
                or $log->error("TokenManager: refresh callback died: $@");
        }
    };

    require Plugins::SpotOn::API::PKCE;

    my $stored = Plugins::SpotOn::API::PKCE::loadTokens($accountId);
    unless ($stored && $stored->{refresh_token}) {
        $log->error("TokenManager: no refresh_token on disk for account " . _mask($accountId));
        $class->_markNeedsReauth($accountId, 'no_refresh_token');
        $resolve->(undef);
        return;
    }

    # PKCE spec: refresh must use the ISSUING client_id — the stored
    # per-token client_id always wins (pre-migration accounts hold tokens
    # minted with the retired bundled default or a custom ID; those still
    # rotate fine). Final fallback is the Keymaster ID, the default PKCE
    # identity since plan 65-04.
    my $clientId = $stored->{client_id}
        || $prefs->get('clientId')
        || Plugins::SpotOn::API::PKCE::KEYMASTER_CLIENT_ID();

    Plugins::SpotOn::API::PKCE::refreshAccessToken($stored->{refresh_token}, $clientId, sub {
        my ($tokenData, $err, $errorDetail) = @_;

        unless ($tokenData) {
            $errorDetail ||= {};
            my $httpCode   = $errorDetail->{http_code}  || 0;
            my $oauthError = $errorDetail->{oauth_error};

            $log->error("TokenManager: PKCE refresh failed for account " . _mask($accountId)
                . ": " . ($err // 'unknown'));

            # D-06: invalid_client means the Client ID itself was rejected
            # (revoked or unknown) -- Spotify returns this on HTTP 401. This
            # is distinct from invalid_grant (the user revoked SpotOn's
            # access) and needs a targeted message: if the rejected ID is
            # the user's configured custom ID, tell them it's invalid;
            # anything else (Keymaster default or a retired bundled ID
            # stored with an old token) maps to bundled_id_unavailable.
            # Checked BEFORE the invalid_grant/400 branch below.
            if ($oauthError && $oauthError eq 'invalid_client') {
                my $customId = $prefs->get('clientId') || '';
                my $reason = ($customId && $clientId eq $customId)
                    ? 'custom_id_invalid'
                    : 'bundled_id_unavailable';
                $class->_markNeedsReauth($accountId, $reason);
            }
            # M-6: HTTP 400 on the token endpoint is practically always a
            # permanent rejection (invalid_grant is the RFC 6749 standard
            # signal), even when the response body could not be parsed into
            # a recognizable oauth_error string -- treat both cases as
            # permanent. Non-400 failures (timeout, 5xx, DNS) are transient
            # and must NOT flip the persistent needsReauth flag (Pitfall 1).
            elsif (($oauthError && $oauthError eq 'invalid_grant') || $httpCode == 400) {
                $class->_markNeedsReauth($accountId, $oauthError || 'token_rejected');
            } else {
                main::INFOLOG && $log->info("TokenManager: transient refresh failure for account "
                    . _mask($accountId) . " -- not flagging re-auth");
            }

            $resolve->(undef);
            return;
        }

        # Refresh Token Rotation (Spike 003) — MUST persist the NEW refresh_token.
        my $ok = Plugins::SpotOn::API::PKCE::storeTokens($accountId, {
            access_token  => $tokenData->{access_token},
            refresh_token => $tokenData->{refresh_token} || $stored->{refresh_token},
            expires_at    => time() + ($tokenData->{expires_in} || 3600),
            client_id     => $clientId,
            scope         => $tokenData->{scope},
        });

        unless ($ok) {
            $log->error("TokenManager: rotated refresh_token persistence FAILED for account "
                . _mask($accountId) . " -- user must re-auth");
            $class->_markNeedsReauth($accountId, 'persist_failed');
            # Still deliver the access_token for THIS request — it's valid
            # for ~1h — but the account is flagged because the next refresh
            # cycle will fail once the on-disk refresh_token is stale.
        } else {
            $class->clearNeedsReauth($accountId);
        }

        $class->_cacheToken($accountId, $tokenData->{access_token}, $tokenData->{expires_in});
        $resolve->($tokenData->{access_token});
    });
}

# _fetchDisplayName($class, $accountId, $spotifyUserId, $cb)
# L-1: 3-arg signature preserved -- callers (refreshAllTokens, Settings.pm)
# pass $spotifyUserId as a fallback display name. Gets a token via getToken
# (2-arg, cache-or-refresh), then GET /me for display_name.
sub _fetchDisplayName {
    my ($class, $accountId, $spotifyUserId, $cb) = @_;

    $class->getToken($accountId, sub {
        my $accessToken = shift;

        unless ($accessToken) {
            # Fallback: use spotifyUserId as display name
            $log->warn("TokenManager: could not get token for /me — using userId as displayName");
            $class->_storeAccountPrefs($accountId, $spotifyUserId, $spotifyUserId, $cb);
            return;
        }

        # Need SimpleAsyncHTTP for this single /me call
        require Slim::Networking::SimpleAsyncHTTP;

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http    = shift;
                my $profile = eval { from_json($http->content) };
                if ($@ || !$profile) {
                    $log->warn("TokenManager: /me JSON parse failed for " . _mask($accountId) . " — using userId");
                    $class->_storeAccountPrefs($accountId, $spotifyUserId, $spotifyUserId, $cb);
                    return;
                }
                my $displayName = $profile->{display_name} || $spotifyUserId || 'Unknown';
                $class->_storeAccountPrefs($accountId, $spotifyUserId, $displayName, $cb);
            },
            sub {
                my ($http, $error) = @_;
                $log->warn("TokenManager: /me HTTP error for " . _mask($accountId) . ": $error — using userId");
                $class->_storeAccountPrefs($accountId, $spotifyUserId, $spotifyUserId, $cb);
            },
            { timeout => 30 }
        )->get(
            SPOTIFY_ME_URL,
            'Authorization' => "Bearer $accessToken",
            'Accept'        => 'application/json',
        );
    });
}

# _storeAccountPrefs($class, $accountId, $spotifyUserId, $displayName, $cb)
# Stores account in prefs, sets activeAccount if none, calls $cb->($accountId).
sub _storeAccountPrefs {
    my ($class, $accountId, $spotifyUserId, $displayName, $cb) = @_;

    my $accounts = $prefs->get('accounts') || {};
    my $entry = $accounts->{$accountId} ||= {};
    $entry->{displayName}   = $displayName;
    $entry->{spotifyUserId} = $spotifyUserId;
    $prefs->set('accounts', $accounts);

    # Set as active account if none currently set
    my $needsDaemonStart = !$prefs->get('activeAccount');
    unless ($prefs->get('activeAccount')) {
        $prefs->set('activeAccount', $accountId);
    }

    main::INFOLOG && $log->info(
        "TokenManager: account " . _mask($accountId) . " stored (displayName=$displayName)");

    # Trigger daemon start when a fresh account was activated
    if ($needsDaemonStart) {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
    }
    $log->warn("[DIAG] account_stored: account=" . _mask($accountId) . " display_name=$displayName is_active=" . (($prefs->get('activeAccount') || '') eq $accountId ? 1 : 0)) if $prefs->get('diagnosticMode');
    $cb->($accountId);
}

# _cacheToken($class, $accountId, $accessToken, $expiresIn)
# D-04: no flavor param. Caches the access token under a single
# per-account key with TTL = expiresIn - TOKEN_EXPIRY_BUFFER.
# Never logs the token value itself — only accountId and TTL.
sub _cacheToken {
    my ($class, $accountId, $accessToken, $expiresIn) = @_;

    $expiresIn //= 3600;
    my $ttl = $expiresIn > TOKEN_EXPIRY_BUFFER
        ? $expiresIn - TOKEN_EXPIRY_BUFFER
        : ($expiresIn > 60 ? $expiresIn : 60);

    $cache->set("spoton_token_${accountId}", $accessToken, $ttl);
    main::INFOLOG && $log->info(
        "TokenManager: token cached for account " . _mask($accountId) . ", TTL ${ttl}s");
}

# _markNeedsReauth($class, $accountId, $reason)
# D-08 4-channel re-auth notification (Channels 3+4 fire here; Channels 1+2
# are pull-based, read via needsReauth()/anyAccountNeedsReauth() -- wired in
# Plan 03).
# M-1: the third argument to $cache->set MUST be the string 'never' --
# Slim::Utils::DbCache's DEFAULT_EXPIRES_TIME is 1 hour, so an omitted TTL
# would silently expire the flag after an hour, not persist it.
sub _markNeedsReauth {
    my ($class, $accountId, $reason) = @_;

    $cache->set(REAUTH_FLAG_PREFIX . $accountId, { reason => $reason, ts => time() }, 'never');

    # Channel 3: Health Panel
    if ($INC{'Plugins/SpotOn/Status.pm'}) {
        Plugins::SpotOn::Status->recordError('error', 'Auth',
            "PKCE refresh failed for account " . _mask($accountId) . " ($reason) — re-authentication required");
    }

    # Channel 4: Log (WARN level, per D-08 exact wording)
    $log->warn("TokenManager: PKCE refresh failed for account " . _mask($accountId) . " — re-authentication required");

    # Channels 1 (OPML) and 2 (Settings) are PULL-based -- they read
    # needsReauth($accountId) at render time. No push needed here.
}

# _mask($accountId)
# T-50-01: masked accountId for log lines -- never log full account IDs or
# any token value.
sub _mask {
    my ($accountId) = @_;
    return 'unknown' unless defined $accountId && length $accountId;
    return substr($accountId, 0, 4) . '****';
}

# _getLmsServerName()
# Returns LMS server name from preferences('server')->get('libraryname'),
# with Sys::Hostname fallback, truncated to 60 chars.
# Per RESEARCH Pattern 5: Spotify device name limit.
sub _getLmsServerName {
    my $serverPrefs = preferences('server');
    my $name = $serverPrefs->get('libraryname') || '';
    unless ($name) {
        require Sys::Hostname;
        $name = eval { Sys::Hostname::hostname() } || 'Lyrion Music Server';
    }
    return substr($name, 0, 60);
}

1;
