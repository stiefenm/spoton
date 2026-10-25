package Plugins::SpotOn::API::AccountMigration;

# Phase 85 plan 10 (D-02, D-03): one-way migration of existing accounts to the
# ZeroConf-first identity.
#
# The account id is the first 8 hex of md5(credentials.json username)
# (accountIdFor). An existing account whose credentials already hash to its id
# is kept silently (D-02); one whose credentials hash to another id is re-keyed
# (D-03); one without usable ZeroConf credentials gets needsPairing (the hint
# "Bitte Konto einmal koppeln") and nothing is deleted.
#
# Re-key order (T-85-16) -- the order is the crash-safety contract:
#   (1) ONE prefs change: new entry, old entry removed, global and per-player
#       activeAccount, journal entry authChainRekeyPending{old} = new, then
#       $prefs->savenow (the prefs file is written via .tmp + rename, atomic);
#   (2) rename of <cachedir>/spoton/<old> to <new>;
#   (3) removal of the old-id cache keys;
#   (4) journal entry deleted, $prefs->savenow.
# Plugin.pm resumes the journal (resumeJournal) on EVERY start, before
# DaemonManager->init(), independent of the one-shot authChainMigrated marker --
# a runtime re-key (DaemonManager->startHelper -> migrateAccount) can be
# interrupted long after the marker was set (WR-01). run() is the one-shot
# migration; it finishes the journal first too, which is idempotent. So a crash
# between any two steps ends in the same state as an uninterrupted run and no
# playback helper ever starts against a stale id. A credentials.json is never
# deleted for belonging to another id.
#
# A cache-version bump is deliberately not used for the key removal: it would
# also drop the never-TTL playback-auth flags that must survive (A13).

use strict;
use warnings;

use File::Spec::Functions qw(catdir);
use Digest::MD5 qw(md5_hex);
use Encode ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log         = logger('plugin.spoton');
my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $cache       = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# playbackCredSource values whose credentials are usable as they are.
use constant USABLE_SOURCES => { zeroconf => 1, keymaster => 1, discover => 1 };

# Collection set names used in spoton_spclient_coll_<id>_<set>. SpClient::SET_MAP
# is the source; this list only makes sure a failing load cannot leave keys behind.
my @FALLBACK_SETS = qw(collection artist show ylpin listenlater);

# The two side-effecting steps after the prefs save. Package variables so a test
# can make either one die (crash between steps) and observe the call order.
our $RENAME_STEP = \&_renameDir;
our $CACHE_STEP  = \&_removeCacheKeys;

# accountIdFor($class, $username) -> 8 hex | undef
# D-05: the single definition of the account id. Wide characters are UTF-8
# encoded first (md5_hex croaks on them); an ASCII username hashes unchanged.
sub accountIdFor {
    my ($class, $username) = @_;
    return undef unless defined $username && !ref $username && length $username;
    my $bytes = $username;
    $bytes = Encode::encode('UTF-8', $bytes) if utf8::is_utf8($bytes);
    return substr(md5_hex($bytes), 0, 8);
}

# run($class)
# Journal first (finish an interrupted re-key), then every account. A failing
# account is logged and does not stop the others; a failing journal entry stays
# in the journal and is retried at the next start.
sub run {
    my ($class) = @_;

    $class->_resumeJournal();

    my $accounts = $prefs->get('accounts') || {};
    for my $id (sort keys %{$accounts}) {
        eval { $class->migrateAccount($id); 1 } or do {
            my $err = $@ // ''; chomp $err;
            $log->error("Auth chain migration: account " . _mask($id) . " failed: $err");
        };
    }
    return;
}

# migrateAccount($class, $accountId) -> 'kept' | 'rekeyed' | 'needs_pairing' | 'refused' | 'skipped'
# One account. Also called by DaemonManager::startHelper when the active
# account's credentials.json does not match its entry (instead of deleting it).
sub migrateAccount {
    my ($class, $accountId) = @_;

    return 'skipped' unless _validId($accountId);

    my $accounts = $prefs->get('accounts') || {};
    my $entry    = $accounts->{$accountId};
    return 'skipped' unless ref $entry eq 'HASH';

    require Plugins::SpotOn::API::Credentials;
    my $creds = Plugins::SpotOn::API::Credentials->verifyCredentials($accountId);
    my $usable = $creds
        && USABLE_SOURCES->{ $entry->{playbackCredSource} // '' }
        && !Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId);

    unless ($usable) {
        _markNeedsPairing($accountId);
        return 'needs_pairing';
    }

    my $username = $creds->{username};
    my $newId    = $class->accountIdFor($username);

    if (defined $newId && $newId eq $accountId) {
        $entry->{spotifyUserId} = $username;
        delete $entry->{needsPairing};
        $prefs->set('accounts', $accounts);
        $log->warn("Auth chain migration: account " . _mask($accountId) . " kept (same id)");
        return 'kept';
    }

    return $class->rekeyAccount($accountId, $newId, $username);
}

# rekeyAccount($class, $oldId, $newId, $username) -> 'rekeyed' | 'refused' | 'skipped'
sub rekeyAccount {
    my ($class, $oldId, $newId, $username) = @_;

    return 'skipped' unless _validId($oldId) && _validId($newId) && $oldId ne $newId;

    my $accounts = $prefs->get('accounts') || {};
    my $oldEntry = $accounts->{$oldId};
    return 'skipped' unless ref $oldEntry eq 'HASH';

    # (0) refusal: the target directory already holds credentials of another
    # user (or of a file that cannot be read) -- never overwritten, never deleted.
    require Plugins::SpotOn::API::Credentials;
    my $targetFile = Plugins::SpotOn::API::Credentials->credentialsPathFor($newId);
    if (-e $targetFile) {
        my $target = Plugins::SpotOn::API::Credentials->verifyCredentials($newId);
        unless ($target && ($target->{username} // '') eq $username) {
            _markNeedsPairing($oldId, 1);
            $log->warn("Auth chain migration: account " . _mask($oldId)
                . " re-key refused (target belongs to another user)");
            return 'refused';
        }
    }

    # (1) one prefs change incl. the journal entry, saved atomically.
    my $newEntry = { %{$oldEntry} };
    if (ref $accounts->{$newId} eq 'HASH') {
        # The same user already has an account under the new id: its fields win.
        $newEntry = { %{$newEntry}, %{ $accounts->{$newId} } };
    }
    $newEntry->{spotifyUserId} = $username;
    delete $newEntry->{needsPairing};

    delete $accounts->{$oldId};
    $accounts->{$newId} = $newEntry;
    $prefs->set('accounts', $accounts);

    $prefs->set('activeAccount', $newId) if ($prefs->get('activeAccount') // '') eq $oldId;
    for my $clientPrefs ($prefs->allClients) {
        $clientPrefs->set('activeAccount', $newId)
            if ($clientPrefs->get('activeAccount') // '') eq $oldId;
    }

    my $journal = $prefs->get('authChainRekeyPending');
    $journal = {} unless ref $journal eq 'HASH';
    $journal->{$oldId} = $newId;
    $prefs->set('authChainRekeyPending', $journal);
    $prefs->savenow;

    # (2)-(4)
    $class->_finishRekey($oldId, $newId);

    $log->warn("Auth chain migration: account " . _mask($oldId) . " re-keyed to " . _mask($newId));
    return 'rekeyed';
}

# --- internals ---------------------------------------------------------

# Steps (2)-(4) for one journal entry.
sub _finishRekey {
    my ($class, $oldId, $newId) = @_;

    $RENAME_STEP->($oldId, $newId);
    $CACHE_STEP->($oldId);
    _clearJournalEntry($oldId);
}

# resumeJournal($class) (WR-01)
# Public: finish every interrupted re-key (steps 2-4) and nothing else -- no
# per-account migration. Plugin.pm calls it on every start; a no-op on an empty
# journal.
sub resumeJournal {
    my ($class) = @_;
    return $class->_resumeJournal();
}

sub _resumeJournal {
    my ($class) = @_;

    my $journal = $prefs->get('authChainRekeyPending');
    return unless ref $journal eq 'HASH' && %{$journal};

    for my $oldId (sort keys %{$journal}) {
        my $newId = $journal->{$oldId};

        unless (_validId($oldId) && _validId($newId)) {
            # An id that is not 8 hex is never used in a path.
            $log->warn("Auth chain migration: journal entry (invalid id) dropped");
            _clearJournalEntry($oldId);
            next;
        }

        eval { $class->_finishRekey($oldId, $newId); 1 } or do {
            my $err = $@ // ''; chomp $err;
            $log->error("Auth chain migration: re-key of " . _mask($oldId) . " to " . _mask($newId)
                . " not finished, retried at the next start: $err");
            next;
        };
        $log->warn("Auth chain migration: account " . _mask($oldId) . " re-keyed to "
            . _mask($newId) . " (resumed)");
    }
}

sub _clearJournalEntry {
    my ($oldId) = @_;

    my $journal = $prefs->get('authChainRekeyPending');
    $journal = {} unless ref $journal eq 'HASH';
    delete $journal->{$oldId};
    $prefs->set('authChainRekeyPending', $journal);
    $prefs->savenow;
}

# Step (2): <cachedir>/spoton/<old> -> <new>, only when old exists and new does
# not. Dies on a failed rename so the journal entry stays and the next start
# tries again.
sub _renameDir {
    my ($oldId, $newId) = @_;

    my $from = _accountDir($oldId);
    my $to   = _accountDir($newId);

    return 0 unless -d $from;    # already moved (resume after the rename)
    if (-e $to) {
        main::INFOLOG && $log->info("Auth chain migration: " . _mask($newId)
            . " directory already exists -- " . _mask($oldId) . " directory left in place");
        return 0;
    }
    rename($from, $to) or die "rename of account directory failed: $!\n";
    return 1;
}

# Step (3): the old-id cache keys (RESEARCH section 4 table of account-keyed state).
sub _removeCacheKeys {
    my ($oldId) = @_;

    require Plugins::SpotOn::API::Credentials;

    my @keys = map { $_ . $oldId } qw(
        spoton_token_
        spoton_needs_reauth_
        spoton_login5_token_
        spoton_last_api_call_
        spoton_spclient_liked_
        spoton_wp_token_
        spoton_wp_client_token_
        spoton_wp_state_
    );
    # A flagged account keeps its never-TTL playback-auth flag.
    push @keys, 'spoton_needs_playback_auth_' . $oldId
        unless Plugins::SpotOn::API::Credentials->needsPlaybackAuth($oldId);
    push @keys, map { "spoton_spclient_coll_${oldId}_$_" } _setNames();

    $cache->remove($_) for @keys;
}

sub _setNames {
    my %seen;
    my $map = eval {
        require Plugins::SpotOn::API::SpClient;
        Plugins::SpotOn::API::SpClient::SET_MAP();
    };
    my @names = ref $map eq 'HASH' ? values %{$map} : ();
    return sort grep { defined $_ && !$seen{$_}++ } (@names, @FALLBACK_SETS);
}

# needsPairing: set once, logged once (DaemonManager calls migrateAccount on
# every start attempt of a mismatching account).
sub _markNeedsPairing {
    my ($accountId, $quiet) = @_;

    my $accounts = $prefs->get('accounts') || {};
    my $entry    = $accounts->{$accountId};
    return unless ref $entry eq 'HASH';
    return if $entry->{needsPairing};

    $entry->{needsPairing} = 1;
    $prefs->set('accounts', $accounts);
    $log->warn("Auth chain migration: account " . _mask($accountId) . " needs pairing") unless $quiet;
}

sub _validId {
    my ($id) = @_;
    return (defined $id && !ref $id && $id =~ /\A[0-9a-f]{8}\z/) ? 1 : 0;
}

sub _accountDir {
    my ($accountId) = @_;
    return catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
}

sub _mask {
    my ($accountId) = @_;
    return 'unknown' unless defined $accountId && length $accountId;
    return substr($accountId, 0, 4) . '****';
}

1;
