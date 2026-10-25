#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use Cwd qw(abs_path);

# 85-14 (D-01): TokenManager is reduced to account bookkeeping. This file used
# to test the PKCE token cache, the refresh cycle, the re-auth flag and the
# migration detection; all of that is deleted with API/PKCE.pm. What is left is
# pinned below: the six surviving subs, the per-sub absence of everything that
# went, and the source-level guards.

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# Create a temporary directory for LMS stubs (CLEANUP on test exit)
my $stub_dir = tempdir(CLEANUP => 1);

# Cache dir for mock tests
my $cache_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module into the stub directory
# ============================================================
sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

# ============================================================
# LMS Module Stubs required by TokenManager.pm
# ============================================================

# Stub: Log::Log4perl::Logger
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Log::Log4perl
write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Slim::Utils::Log
# logger() is exported as a function when modules do 'use Slim::Utils::Log'
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @logged;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info  { push @logged, ['info',  $_[1]] }
sub warn  { push @logged, ['warn',  $_[1]] }
sub error { push @logged, ['error', $_[1]] }
sub debug { push @logged, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# Supports preferences('server')->get('cachedir') returning $cache_dir
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir', httpport => 9000, libraryname => 'TestServer' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    return bless { _ns => \$self->{_ns} . '_client_' . (\$client // 'default') }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache (in-memory)
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Credentials -- the two hasValidLogin inputs,
# controllable per account.
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our %verify    = ();    # accountId => hashref|undef  (verifyCredentials)
our %needsAuth = ();    # accountId => 0|1            (needsPlaybackAuth)
sub verifyCredentials  { my ($class, $id) = @_; return $verify{$id} }
sub needsPlaybackAuth  { my ($class, $id) = @_; return $needsAuth{$id} ? 1 : 0 }
sub reset_stub { %verify = (); %needsAuth = (); }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Login5 -- loginState only.
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
our %state = ();        # accountId => state string
sub loginState { my ($class, $id) = @_; return $state{$id} }
sub reset_stub { %state = (); }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::Unified::DaemonManager -- counts the restart pair
# removeAccount and _storeAccountPrefs may trigger.
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $shutdown_calls = 0;
our @shutdown_args  = ();
our $schedule_init_calls = 0;
sub shutdown     { shift; $shutdown_calls++; @shutdown_args = @_ }
sub scheduleInit { $schedule_init_calls++ }
sub reset_stub   { $shutdown_calls = 0; @shutdown_args = (); $schedule_init_calls = 0; }
1;
END

# ============================================================
# main:: constants (TRANSCODING, WEBUI, SCANNER, INFOLOG, etc.)
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# submodules resolve it via a fully-qualified call at load time. Production
# always compiles Plugin.pm first — provide the constant for standalone loads.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# ============================================================
# Add stub_dir and project_dir to @INC
# ============================================================
unshift @INC, $stub_dir, $project_dir;

# Load stub modules so their import() methods run and install functions
# into main:: namespace (e.g., preferences(), logger()), and so package
# globals (Credentials/Login5/DaemonManager stubs) exist before tests use them.
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Plugins::SpotOn::API::Credentials;
require Plugins::SpotOn::API::Login5;
require Plugins::SpotOn::Unified::DaemonManager;   # sets $INC, as in production (removeAccount checks it)

my $tm_module = "$project_dir/Plugins/SpotOn/API/TokenManager.pm";
ok(-f $tm_module, 'TokenManager.pm exists');

require_ok('Plugins::SpotOn::API::TokenManager')
    or BAIL_OUT("Failed to load TokenManager.pm");

my $TM = 'Plugins::SpotOn::API::TokenManager';
my $prefs = preferences('plugin.spoton');

sub reset_all {
    Slim::Utils::Cache->new()->clear();
    Plugins::SpotOn::API::Credentials::reset_stub();
    Plugins::SpotOn::API::Login5::reset_stub();
    Plugins::SpotOn::Unified::DaemonManager::reset_stub();
}

# --------------------------------------------------------
# D-01: the reduced surface. The six kept subs exist, everything that was the
# PKCE half is gone -- one named ok line per sub so the count cannot collapse.
# --------------------------------------------------------
for my $kept (qw(getAccountIds removeAccount getActiveAccountName _storeAccountPrefs hasValidLogin _mask)) {
    ok(defined &{"Plugins::SpotOn::API::TokenManager::$kept"}, "D-01: TokenManager still defines $kept");
}

for my $gone (qw(
    getToken clearCachedToken needsReauth reauthReason anyAccountNeedsReauth
    accountNeedsMigration anyAccountNeedsMigration clearNeedsReauth markNeedsReauth
    refreshAllTokens _refreshToken _fetchDisplayName _cacheToken _markNeedsReauth
    _getLmsServerName
)) {
    ok(!$TM->can($gone), "D-01: TokenManager no longer has $gone");
}

for my $constant (qw(TOKEN_EXPIRY_BUFFER TOKEN_REFRESH_TIMER SPOTIFY_ME_URL REAUTH_FLAG_PREFIX)) {
    ok(!$TM->can($constant), "D-01: TokenManager no longer has the constant $constant");
}

ok(!-e "$project_dir/Plugins/SpotOn/API/PKCE.pm", 'D-01: API/PKCE.pm is deleted');

# --------------------------------------------------------
# getAccountIds / getActiveAccountName (unchanged behavior)
# --------------------------------------------------------
{
    $prefs->set('accounts', {
        'acct_bbb' => { displayName => 'Bob',   spotifyUserId => 'bob456' },
        'acct_aaa' => { displayName => 'Alice', spotifyUserId => 'alice123' },
    });
    my @ids = $TM->getAccountIds();
    is(scalar(@ids), 2, 'getAccountIds returns 2 IDs for 2 seeded accounts');
    is_deeply(\@ids, [qw(acct_aaa acct_bbb)], 'getAccountIds returns the IDs sorted');
}

{
    $prefs->set('accounts', {
        'active_acct' => { displayName => 'Alice Spotify', spotifyUserId => 'alice' },
    });
    $prefs->set('activeAccount', 'active_acct');

    is($TM->getActiveAccountName(undef), 'Alice Spotify',
        'getActiveAccountName returns displayName of active account');

    $prefs->set('activeAccount', 'unknown_acct');
    ok(!defined $TM->getActiveAccountName(undef),
        'getActiveAccountName returns undef when the active id has no account entry');

    $prefs->set('activeAccount', '');
    ok(!defined $TM->getActiveAccountName(undef),
        'getActiveAccountName returns undef when no account is active');
}

# --------------------------------------------------------
# _mask (T-50-01): never the full id
# --------------------------------------------------------
{
    is(Plugins::SpotOn::API::TokenManager::_mask('abcdef12'), 'abcd****', '_mask keeps 4 characters and masks the rest');
    is(Plugins::SpotOn::API::TokenManager::_mask(undef), 'unknown', '_mask of undef is "unknown"');
    is(Plugins::SpotOn::API::TokenManager::_mask(''), 'unknown', '_mask of an empty id is "unknown"');
}

# --------------------------------------------------------
# removeAccount: prefs entry, credentials dir, active-account reset
# --------------------------------------------------------
{
    reset_all();
    $prefs->set('accounts', {
        'remove_me' => { displayName => 'Remove', spotifyUserId => 'removeme' },
        'keep_me'   => { displayName => 'Keep',   spotifyUserId => 'keepme' },
    });
    $prefs->set('activeAccount', 'keep_me');

    # M2: seed a credentials dir for the account
    my $acct_dir = catdir($cache_dir, 'spoton', 'remove_me');
    make_path($acct_dir);
    open(my $cfh, '>', catfile($acct_dir, 'credentials.json')) or die "seed creds: $!";
    print $cfh '{"auth_type":1,"username":"u","auth_data":"d"}';
    close($cfh);

    $TM->removeAccount('remove_me');

    my %accts = map { $_ => 1 } $TM->getAccountIds();
    ok(!exists $accts{remove_me}, 'removeAccount removes account from prefs');
    ok(exists $accts{keep_me}, 'removeAccount keeps the other account');
    ok(!-d $acct_dir, 'M2: removeAccount deletes the account credentials dir from disk');
    ok(-d catdir($cache_dir, 'spoton'), 'M2: shared spoton cache root is NOT removed');
    is($prefs->get('activeAccount'), 'keep_me', 'removeAccount leaves a different active account alone');
    is($Plugins::SpotOn::Unified::DaemonManager::shutdown_calls, 0,
        'removeAccount of a non-active account does not restart the daemons');
}

{
    reset_all();
    $prefs->set('accounts', { 'act_gone' => { displayName => 'Act', spotifyUserId => 'act' } });
    $prefs->set('activeAccount', 'act_gone');
    my $acct_dir = catdir($cache_dir, 'spoton', 'act_gone');
    make_path($acct_dir);

    $TM->removeAccount('act_gone');

    is($prefs->get('activeAccount'), '', 'removeAccount of the active account resets activeAccount');
    is($Plugins::SpotOn::Unified::DaemonManager::shutdown_calls, 1,
        'removeAccount of the active account stops the daemons once');
    is($Plugins::SpotOn::Unified::DaemonManager::shutdown_args[0], 'restart',
        'removeAccount stops the daemons with the restart reason');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 1,
        'removeAccount of the active account schedules a fresh init');
}

# --------------------------------------------------------
# hasValidLogin (85-10 D-06): the three inputs, each able to make it false
# --------------------------------------------------------
{
    reset_all();
    is($TM->hasValidLogin(undef), 0, 'hasValidLogin: undef id has no login');
    is($TM->hasValidLogin(''),    0, 'hasValidLogin: empty id has no login');
    is($TM->hasValidLogin('nocreds'), 0, 'hasValidLogin: no verifiable credentials.json => 0');

    $Plugins::SpotOn::API::Credentials::verify{good} = { username => 'u' };
    is($TM->hasValidLogin('good'), 1, 'hasValidLogin: verifiable credentials, no flag, no Login5 verdict => 1');

    $Plugins::SpotOn::API::Credentials::needsAuth{good} = 1;
    is($TM->hasValidLogin('good'), 0, 'hasValidLogin: a needsPlaybackAuth flag => 0');
    $Plugins::SpotOn::API::Credentials::needsAuth{good} = 0;

    $Plugins::SpotOn::API::Login5::state{good} = 'invalid_credentials';
    is($TM->hasValidLogin('good'), 0, 'hasValidLogin: Login5 invalid_credentials => 0');

    $Plugins::SpotOn::API::Login5::state{good} = 'ok';
    is($TM->hasValidLogin('good'), 1, 'hasValidLogin: a healthy Login5 state keeps it valid');
}

# --------------------------------------------------------
# _storeAccountPrefs (85-10 D-06 / D-04): record the account, activate only when
# the active one is missing or has no valid login
# --------------------------------------------------------
{
    reset_all();
    $prefs->set('accounts', {});
    $prefs->set('activeAccount', '');

    my $got;
    $TM->_storeAccountPrefs('newacct1', 'newuser', 'New User', sub { $got = shift });
    is($got, 'newacct1', '_storeAccountPrefs calls back with the account id');
    my $accounts = $prefs->get('accounts');
    is($accounts->{newacct1}{displayName}, 'New User', '_storeAccountPrefs stores the display name');
    is($accounts->{newacct1}{spotifyUserId}, 'newuser', '_storeAccountPrefs stores the spotifyUserId');
    is($prefs->get('activeAccount'), 'newacct1', '_storeAccountPrefs activates the first account');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 1,
        '_storeAccountPrefs schedules the daemon init after an activation');
}

{
    reset_all();
    $Plugins::SpotOn::API::Credentials::verify{workingone} = { username => 'u' };
    $prefs->set('accounts', { workingone => { displayName => 'W', spotifyUserId => 'w' } });
    $prefs->set('activeAccount', 'workingone');

    $TM->_storeAccountPrefs('second01', 'second', 'Second', sub { });
    is($prefs->get('activeAccount'), 'workingone',
        '_storeAccountPrefs never takes over a working active account (D-04)');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 0,
        '_storeAccountPrefs schedules nothing when no account was activated');
    ok(exists $prefs->get('accounts')->{second01}, '_storeAccountPrefs still records the second account');
}

{
    reset_all();
    # active account without a valid login (no verifiable credentials)
    $prefs->set('accounts', { brokenone => { displayName => 'B', spotifyUserId => 'b' } });
    $prefs->set('activeAccount', 'brokenone');

    $TM->_storeAccountPrefs('third001', 'third', 'Third', sub { }, { noSchedule => 1 });
    is($prefs->get('activeAccount'), 'third001',
        '_storeAccountPrefs replaces an active account that has no valid login (D-06)');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 0,
        '_storeAccountPrefs honours noSchedule');
}

# --------------------------------------------------------
# Source-level guards
# --------------------------------------------------------
{
    open(my $src_fh, '<', $tm_module) or die "cannot read $tm_module: $!";
    local $/;
    my $source = <$src_fh>;
    close($src_fh);

    my $code = join("\n", grep { !/^\s*#/ } split /\n/, $source);

    # (F) Permanent regression guard (review finding #5, AUTH-07): the retired
    # Keymaster HTTP token service must never come back.
    my @hits = ($code =~ /keymaster/gi);
    is(scalar(@hits), 0,
        'AUTH-07 regression guard: TokenManager.pm has no keymaster reference in non-comment code');

    unlike($code, qr/PKCE/i, 'D-01: TokenManager.pm names PKCE nowhere in non-comment code');
    unlike($code, qr/refresh_token|access_token|pkce_tokens/,
        'D-01: TokenManager.pm handles no token material');
    unlike($code, qr/SimpleAsyncHTTP/, 'D-01: TokenManager.pm makes no HTTP request (the /me lookup is gone)');
    unlike($code, qr/spoton_token_|spoton_needs_reauth_/,
        'D-01: TokenManager.pm touches neither the token nor the re-auth cache keys');
}

done_testing();
