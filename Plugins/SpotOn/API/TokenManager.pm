package Plugins::SpotOn::API::TokenManager;

# 85-14 (D-01): account bookkeeping only. The PKCE token cache, the refresh
# cycle, the re-auth flag and the migration detection are gone with
# API/PKCE.pm; an account's identity is its ZeroConf credentials.json (85-10)
# and its Web-API bearer comes from Login5 / SpClient, not from here.

use strict;
use warnings;

use File::Spec::Functions qw(catdir);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# Kept although no surviving sub reads it: t/core/12 counts this Cache module
# among the plugin's cache instances, and 85-15 re-pins that count together
# with the Client.pm deletion. M5: cache version lives in Plugin.pm (single
# source of truth); Plugin.pm is always compiled first in production.
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# ============================================================
# Public class methods
# ============================================================

# removeAccount($class, $accountId)
# Removes the account from prefs and its credentials directory from disk, and
# stops the daemons when it was the active account. (The token cache keys of the
# deleted PKCE era are removed once by Plugin.pm's pkceRemoved cleanup.)
sub removeAccount {
    my ($class, $accountId) = @_;

    # Remove from prefs
    my $accounts = $prefs->get('accounts') || {};
    delete $accounts->{$accountId};
    $prefs->set('accounts', $accounts);

    # WR-10: the credentials are going away, so is Login5's verdict on them --
    # otherwise pairing the same user again (same id) inherits an
    # invalid_credentials state that judged the removed credentials.
    if ($accountId) {
        eval {
            require Plugins::SpotOn::API::Login5;
            Plugins::SpotOn::API::Login5->forgetAccount($accountId);
            1;
        } or $log->warn("TokenManager: could not reset the login5 state for " . _mask($accountId) . ": $@");
    }

    # M2: Remove the account's credentials directory from disk — a "removed"
    # account must not leave its Spotify credentials.json behind.
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
            Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');
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

# ============================================================
# Login state and account record
# ============================================================

# hasValidLogin($class, $accountId) -> 1|0
# 85-10 (D-06): does this account have a usable playback login? Usable means:
# a verifiable credentials.json, no persistent needsPlaybackAuth flag, and
# Login5 has not reported invalid_credentials for it. An unknown or empty id
# has none. Read-only; used to decide whether a new pairing takes over the
# active account.
sub hasValidLogin {
    my ($class, $accountId) = @_;
    return 0 unless defined $accountId && length $accountId;

    require Plugins::SpotOn::API::Credentials;
    return 0 unless Plugins::SpotOn::API::Credentials->verifyCredentials($accountId);
    return 0 if Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId);

    my $state = eval {
        require Plugins::SpotOn::API::Login5;
        Plugins::SpotOn::API::Login5->loginState($accountId);
    };
    return 0 if defined $state && $state eq 'invalid_credentials';
    return 1;
}

# _storeAccountPrefs($class, $accountId, $spotifyUserId, $displayName, $cb, $opts)
# Stores account in prefs, activates it when the active account is missing or
# has no valid login (D-06), calls $cb->($accountId).
#
# D-06: the new account becomes the global activeAccount when none is set OR the
# current one has no valid login (hasValidLogin) -- a working active account is
# never taken over (D-04). Every per-client activeAccount that pointed at the
# replaced account follows (RESEARCH P7); per-client prefs pointing elsewhere
# stay. $opts->{noSchedule}: the caller schedules the daemon init itself.
sub _storeAccountPrefs {
    my ($class, $accountId, $spotifyUserId, $displayName, $cb, $opts) = @_;
    $opts ||= {};

    my $accounts = $prefs->get('accounts') || {};
    my $entry = $accounts->{$accountId} ||= {};
    $entry->{displayName}   = $displayName;
    $entry->{spotifyUserId} = $spotifyUserId;
    $prefs->set('accounts', $accounts);

    my $previous = $prefs->get('activeAccount') || '';
    my $activate = !$previous
        || ($previous ne $accountId && !$class->hasValidLogin($previous));

    if ($activate) {
        $prefs->set('activeAccount', $accountId);

        if ($previous && defined &Slim::Player::Client::clients) {
            for my $c (Slim::Player::Client::clients()) {
                my $clientPrefs = $prefs->client($c);
                if (($clientPrefs->get('activeAccount') // '') eq $previous) {
                    $clientPrefs->set('activeAccount', $accountId);
                }
            }
        }
    }

    # 85-10 (T-85-15): the display name is not logged -- for a ZeroConf account it
    # defaults to the Spotify username until a profile name arrives.
    main::INFOLOG && $log->info(
        "TokenManager: account " . _mask($accountId) . " stored");

    # Trigger daemon start when a different account was activated
    if ($activate && !$opts->{noSchedule}) {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
    }
    $log->warn("[DIAG] account_stored: account=" . _mask($accountId) . " display_name_len=" . length($displayName // '') . " is_active=" . (($prefs->get('activeAccount') || '') eq $accountId ? 1 : 0)) if $prefs->get('diagnosticMode');
    $cb->($accountId);
}

# _mask($accountId)
# T-50-01: masked accountId for log lines -- never log full account IDs or
# any token value.
sub _mask {
    my ($accountId) = @_;
    return 'unknown' unless defined $accountId && length $accountId;
    return substr($accountId, 0, 4) . '****';
}

1;
