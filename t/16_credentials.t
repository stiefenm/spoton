#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use File::Spec::Functions qw(catdir catfile);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Create a temporary directory for LMS stubs (CLEANUP on test exit)
my $stub_dir = tempdir(CLEANUP => 1);

# Cache dir for mock tests (Slim::Utils::Prefs->preferences('server')->get('cachedir'))
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
# LMS Module Stubs required by Credentials.pm
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
# logger() is exported as a function when modules do 'use Slim::Utils::Log'.
# Records every info/warn/error/debug message into a package-global @logged
# array so Test 12 (T-29-07) can assert the access token never appears in
# any log line across the whole test run.
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @logged = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory {
    return bless {}, 'Slim::Utils::Log';
}
sub logger {
    return bless {}, 'Slim::Utils::Log';
}
sub info  { push @logged, $_[1] if defined $_[1]; }
sub warn  { push @logged, $_[1] if defined $_[1]; }
sub error { push @logged, $_[1] if defined $_[1]; }
sub debug { push @logged, $_[1] if defined $_[1]; }
sub is_info  { 1 }   # IN-04: enable so info-level log lines execute for token-leak test
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# preferences('server')->get('cachedir') returns a tempdir; preferences('plugin.spoton')
# is backed by a generic per-namespace hash (get/set) so 'accounts'/'activeAccount' work.
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

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

sub client { return bless { _ns => \$_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }
sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache (GH #147: Credentials.pm stores the persistent
# playback-auth flag here -- in-memory hash with set/get/remove, TTL ignored)
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

# Stub: Slim::Utils::Timers
# setTimer($obj, $when, $cb, @args) invokes $cb->($obj ? $obj : (), @args)
# SYNCHRONOUSLY so the poll loop runs to completion inside the test (no real
# event loop here). killTimers is a no-op. The Proc::Background stub defaults
# alive() to false on the FIRST poll, so this never recurses.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer {
    my ($obj, $time, $cb, @args) = @_;
    push @set_calls, [@_];
    $cb->(($obj ? ($obj) : ()), @args) if ref $cb eq 'CODE';
}
sub killTimers { push @kill_calls, [@_]; }
sub reset_calls { @set_calls = (); @kill_calls = (); }
1;
END

# Stub: Time::HiRes (pass through to real Time::HiRes/CORE::time)
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: JSON::XS::VersionOneAndTwo (delegates to JSON::PP)
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# ============================================================
# Stub: Proc::Background
# Records every spawn's args (minus the leading options hashref) into a
# package-global @spawns array for the invocation-contract test (Test 11).
# alive() defaults to FALSE from the very first poll (configurable via
# $next_alive) so the synchronous timer stub above never recurses.
# ============================================================
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our @spawns = ();
our $next_alive = 0;
our $new_dies = 0;   # when true, new() throws (spawn_failed simulation)
our $on_new;         # WR-04: optional coderef called with @args after spawn

sub new {
    my $class = shift;
    my $opts  = shift; # options hashref (die_upon_destroy, etc.) -- not recorded
    my @args  = @_;
    die "simulated spawn failure\n" if $new_dies;
    push @spawns, [@args];
    # WR-04: run side-effect callback (e.g. write credentials.json) to simulate
    # the subprocess's output — needed because deriveCredentials now unlinks
    # the pre-existing file before spawning.
    $on_new->(@args) if $on_new;
    return bless { alive => $next_alive }, $class;
}
sub alive { return $_[0]->{alive} }
sub die   { $_[0]->{alive} = 0; }

sub reset_stub {
    @spawns     = ();
    $next_alive = 0;
    $new_dies   = 0;
    $on_new     = undef;
}
1;
END

# ============================================================
# Stub: Plugins::SpotOn::Helper
# get() returns a configurable fake binary path (default: a path under the
# cache dir). getCapability($key) reads a configurable package-global %caps
# (default: token-login => 1).
# ============================================================
my $fake_helper_path = "$cache_dir/fake-spoton";
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<"END");
package Plugins::SpotOn::Helper;
our \$fake_path = '$fake_helper_path';
our \%caps = ('token-login' => 1, 'token-env' => 1);

sub get { return \$fake_path }
sub getCapability {
    my (\$class, \$key) = \@_;
    return \$caps{\$key};
}
sub reset_stub {
    \$fake_path = '$fake_helper_path';
    \%caps = ('token-login' => 1, 'token-env' => 1);
}
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::TokenManager
# getToken($class, $accountId, $cb) invokes $cb with a configurable
# package-global $next_token (default 'tok-fresh'). Supports deferred
# resolution (fire_pending_tokens) for the coalescing test (Test 6), mirroring
# t/07_token_manager.t's PKCE::refreshAccessToken_defer/fire_pending shape.
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our @getToken_calls   = ();
our $next_token       = 'tok-fresh';
our $defer_getToken   = 0;
our @getToken_pending = ();

sub getToken {
    my ($class, $accountId, $cb) = @_;
    push @getToken_calls, $accountId;

    if ($defer_getToken) {
        push @getToken_pending, $cb;
        return;
    }
    $cb->($next_token);
}

# Fires all queued (deferred) getToken callbacks with the current $next_token.
sub fire_pending_tokens {
    my @cbs = @getToken_pending;
    @getToken_pending = ();
    $_->($next_token) for @cbs;
}

sub reset_stub {
    @getToken_calls   = ();
    $next_token       = 'tok-fresh';
    $defer_getToken   = 0;
    @getToken_pending = ();
}
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
    # IN-04: INFOLOG=1 so info-level log lines execute and are captured
    # by the token-leak assertion (Test 12, T-29-07). With INFOLOG=0,
    # every main::INFOLOG && $log->info(...) was short-circuited, and a
    # token leak in an info-level line would pass silently.
    *main::INFOLOG     = sub () { 1 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# Credentials.pm resolves it via a fully-qualified call at load time (GH #147
# playback-auth flag cache). Production always compiles Plugin.pm first --
# provide the constant for standalone loads (same pattern as t/09_settings.t).
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# ============================================================
# Add stub_dir and project_dir to @INC (stub_dir first so our stubs shadow
# real modules, e.g. Plugins::SpotOn::Helper / TokenManager)
# ============================================================
unshift @INC, $stub_dir, $project_dir;

# Load stub modules so their import() methods run and install functions into
# main:: namespace (preferences(), logger()), and so package globals exist
# before tests manipulate them.
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Proc::Background;
require Plugins::SpotOn::Helper;
require Plugins::SpotOn::API::TokenManager;

# ============================================================
# Load the module under test (RED: this MUST fail until Task 2 creates it)
# ============================================================
require_ok('Plugins::SpotOn::API::Credentials')
    or BAIL_OUT("Failed to load Plugins::SpotOn::API::Credentials");

# ============================================================
# Test helpers
# ============================================================

# Seed a credentials.json file for $accountId under the cache dir.
sub seed_credentials {
    my ($accountId, $data) = @_;
    my $dir = catdir($cache_dir, 'spoton', $accountId);
    make_path($dir) unless -d $dir;
    my $file = catfile($dir, 'credentials.json');
    open(my $fh, '>', $file) or die "seed_credentials: $!";
    print $fh JSON::PP::encode_json($data);
    close($fh);
    return $file;
}

sub seed_corrupt_credentials {
    my ($accountId) = @_;
    my $dir = catdir($cache_dir, 'spoton', $accountId);
    make_path($dir) unless -d $dir;
    my $file = catfile($dir, 'credentials.json');
    open(my $fh, '>', $file) or die "seed_corrupt_credentials: $!";
    print $fh '{ this is not valid json ]]]';
    close($fh);
    return $file;
}

sub reset_all {
    Proc::Background::reset_stub();
    Plugins::SpotOn::Helper::reset_stub();
    Plugins::SpotOn::API::TokenManager::reset_stub();
    Slim::Utils::Timers::reset_calls();
}

require JSON::PP;

# ============================================================
# Test 1: Happy path -- fresh token + subprocess exit + valid credentials.json
# WR-04: deriveCredentials now unlinks pre-existing credentials.json before
# spawning, so we use the Proc::Background on_new callback to simulate the
# subprocess writing the file (instead of pre-seeding before the call).
# ============================================================
{
    reset_all();
    my $accountId = 'acct_happy';
    my $creds_data = { username => 'userA', auth_type => 1, auth_data => 'QUJD' };
    # Ensure account dir exists
    make_path(catdir($cache_dir, 'spoton', $accountId));
    # Subprocess writes credentials.json on spawn
    $Proc::Background::on_new = sub { seed_credentials($accountId, $creds_data) };

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        ($ok, $reason) = @_;
    });

    is($ok, 1, 'Test 1: happy path resolves ok=1');
    is($reason, undef, 'Test 1: happy path resolves with no failure reason');

    my $credFile = catfile($cache_dir, 'spoton', $accountId, 'credentials.json');
    SKIP: {
        skip 'file mode assertion not meaningful on Windows', 1 if $^O eq 'MSWin32';
        my $mode = (stat($credFile))[2] & 07777;
        is($mode, 0600, 'Test 1: credentials.json is chmod 0600 after successful derivation');
    }
}

# ============================================================
# Test 2: credentials.json with auth_type 3 (token auth, not stored) -> failure
# ============================================================
{
    reset_all();
    my $accountId = 'acct_authtype3';
    seed_credentials($accountId, { username => 'userA', auth_type => 3, auth_data => 'QUJD' });

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        ($ok, $reason) = @_;
    });

    is($ok, 0, 'Test 2: auth_type=3 (not stored) resolves ok=0');
    is($reason, 'derivation_failed', 'Test 2: auth_type=3 resolves reason=derivation_failed');
}

# ============================================================
# Test 3: no credentials.json at all, and corrupt/truncated JSON
# ============================================================
{
    reset_all();
    my $accountId = 'acct_nofile';
    # deliberately do NOT seed any credentials.json

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        ($ok, $reason) = @_;
    });

    is($ok, 0, 'Test 3a: missing credentials.json resolves ok=0');
    is($reason, 'derivation_failed', 'Test 3a: missing credentials.json resolves reason=derivation_failed');
}
{
    reset_all();
    my $accountId = 'acct_corrupt';
    seed_corrupt_credentials($accountId);

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        ($ok, $reason) = @_;
    });

    is($ok, 0, 'Test 3b: corrupt credentials.json resolves ok=0');
    is($reason, 'derivation_failed', 'Test 3b: corrupt credentials.json resolves reason=derivation_failed');
}

# ============================================================
# Test 4: TokenManager->getToken callback with undef -> no_token, no spawn
# ============================================================
{
    reset_all();
    my $accountId = 'acct_notoken';
    $Plugins::SpotOn::API::TokenManager::next_token = undef;

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        ($ok, $reason) = @_;
    });

    is($ok, 0, 'Test 4: undef token resolves ok=0');
    is($reason, 'no_token', 'Test 4: undef token resolves reason=no_token');
    is(scalar(@Proc::Background::spawns), 0, 'Test 4: Proc::Background->new was never called');
}

# ============================================================
# Test 5: Helper getCapability('token-login') falsy -> binary_too_old, no spawn
# ============================================================
{
    reset_all();
    my $accountId = 'acct_oldbinary';
    $Plugins::SpotOn::Helper::caps{'token-login'} = 0;

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        ($ok, $reason) = @_;
    });

    is($ok, 0, 'Test 5: missing token-login capability resolves ok=0');
    is($reason, 'binary_too_old', 'Test 5: missing token-login capability resolves reason=binary_too_old');
    is(scalar(@Proc::Background::spawns), 0, 'Test 5: no spawn attempted when binary lacks capability');
}

# ============================================================
# Test 6: Coalescing -- two concurrent calls for the same account share one
# Proc::Background spawn; both callbacks resolve; a dying first callback does
# not starve the second (WR-06 eval-guard).
# ============================================================
{
    reset_all();
    my $accountId = 'acct_coalesce';
    # WR-04: use on_new callback to simulate subprocess writing credentials.json
    make_path(catdir($cache_dir, 'spoton', $accountId));
    $Proc::Background::on_new = sub {
        seed_credentials($accountId, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });
    };
    $Plugins::SpotOn::API::TokenManager::defer_getToken = 1;

    my @results;
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        die "simulated callback death\n";
    });
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub {
        push @results, [@_];
    });

    is(scalar(@Proc::Background::spawns), 0,
        'Test 6: no spawn yet -- both calls are queued behind the deferred getToken');
    is(scalar(@results), 0, 'Test 6: neither callback has fired before the in-flight derivation resolves');

    Plugins::SpotOn::API::TokenManager::fire_pending_tokens();

    is(scalar(@Proc::Background::spawns), 1,
        'Test 6: exactly ONE Proc::Background spawn for two coalesced callers');
    is(scalar(@results), 1,
        'Test 6: the second (surviving) callback still resolves despite the first dying');
    is($results[0][0], 1, 'Test 6: surviving callback receives ok=1');
}

# ============================================================
# Test 7: D-05 rate limiting -- 3 failures within the window -> 4th call is
# rate_limited with no spawn. A fresh account (post-reset) is not affected.
# ============================================================
{
    reset_all();
    my $accountId = 'acct_ratelimit';

    for my $i (1..3) {
        my ($ok, $reason);
        Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { ($ok, $reason) = @_ });
        is($ok, 0, "Test 7: failure attempt $i resolves ok=0");
        is($reason, 'derivation_failed', "Test 7: failure attempt $i resolves reason=derivation_failed");
    }

    my $spawnsBefore = scalar(@Proc::Background::spawns);
    my ($ok4, $reason4);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { ($ok4, $reason4) = @_ });

    is($ok4, 0, 'Test 7: 4th call after 3 failures resolves ok=0');
    is($reason4, 'rate_limited', 'Test 7: 4th call after 3 failures resolves reason=rate_limited');
    is(scalar(@Proc::Background::spawns), $spawnsBefore,
        'Test 7: rate-limited call does not spawn a new subprocess');
}
{
    # A successful derivation resets the failure counter -- a subsequent
    # single failure on the SAME account must not immediately trigger
    # rate_limited (which would only happen if the counter were not reset).
    reset_all();
    my $accountId = 'acct_ratelimit_reset';

    # 2 failures (below MAX_DERIVE_FAILURES=3threshold)
    for my $i (1..2) {
        Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { });
    }

    # A success clears the failure counter — WR-04: use on_new callback
    $Proc::Background::on_new = sub {
        seed_credentials($accountId, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });
    };
    my ($okSuccess);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { $okSuccess = shift });
    is($okSuccess, 1, 'Test 7 reset: 3rd attempt (after seeding valid creds) succeeds');

    # Clear the on_new callback so the next attempt fails (no credentials written)
    $Proc::Background::on_new = undef;

    my ($ok, $reason);
    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { ($ok, $reason) = @_ });
    is($ok, 0, 'Test 7 reset: next failure after success resolves ok=0');
    is($reason, 'derivation_failed',
        'Test 7 reset: next failure after success is derivation_failed, NOT rate_limited (counter was reset)');
}

# ============================================================
# Test 8: D-08 accountMismatch
# ============================================================
{
    reset_all();
    my $accountId = 'acct_mismatch';
    seed_credentials($accountId, { username => 'userB', auth_type => 1, auth_data => 'QUJD' });
    preferences('plugin.spoton')->set('accounts', {
        $accountId => { spotifyUserId => 'userA' },
    });

    is(Plugins::SpotOn::API::Credentials->accountMismatch($accountId), 1,
        'Test 8: accountMismatch returns 1 when credentials.json username differs from PKCE spotifyUserId');
}
{
    reset_all();
    my $accountId = 'acct_match';
    seed_credentials($accountId, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });
    preferences('plugin.spoton')->set('accounts', {
        $accountId => { spotifyUserId => 'userA' },
    });

    is(Plugins::SpotOn::API::Credentials->accountMismatch($accountId), 0,
        'Test 8: accountMismatch returns 0 when usernames match');
}
{
    reset_all();
    my $accountId = 'acct_mismatch_absent';
    preferences('plugin.spoton')->set('accounts', {
        $accountId => { spotifyUserId => 'userA' },
    });
    # no credentials.json seeded at all

    is(Plugins::SpotOn::API::Credentials->accountMismatch($accountId), 0,
        'Test 8: accountMismatch returns 0 when credentials.json is absent');
}
{
    reset_all();
    my $accountId = 'acct_mismatch_corrupt';
    seed_corrupt_credentials($accountId);
    preferences('plugin.spoton')->set('accounts', {
        $accountId => { spotifyUserId => 'userA' },
    });

    is(Plugins::SpotOn::API::Credentials->accountMismatch($accountId), 0,
        'Test 8: accountMismatch returns 0 when credentials.json is unparseable');
}

# ============================================================
# Test 9: D-03 isCredentialError
# ============================================================
{
    is(Plugins::SpotOn::API::Credentials->isCredentialError('Login failed with reason: Bad credentials'), 1,
        'Test 9: isCredentialError matches "Bad credentials"');
    is(Plugins::SpotOn::API::Credentials->isCredentialError('Login failed with reason: Could not validate credentials'), 1,
        'Test 9: isCredentialError matches "Could not validate credentials"');
    is(Plugins::SpotOn::API::Credentials->isCredentialError("No cached credentials in '/some/dir'. Run --authenticate or --discover-once first."), 1,
        'Test 9: isCredentialError matches lines starting with "No cached credentials in"');
    # GH #147: Login5 provenance blockade signatures (Aug 10, 2026)
    is(Plugins::SpotOn::API::Credentials->isCredentialError('Login failed with reason: INVALID_CREDENTIALS'), 1,
        'Test 9: isCredentialError matches Login5 "INVALID_CREDENTIALS" (GH #147)');
    is(Plugins::SpotOn::API::Credentials->isCredentialError('Connection failed: Login request was denied'), 1,
        'Test 9: isCredentialError matches "Login request was denied" (GH #147)');
    is(Plugins::SpotOn::API::Credentials->isCredentialError('thread main panicked at src/main.rs:42'), 0,
        'Test 9: isCredentialError does NOT match a generic panic line');
}

# ============================================================
# Test 10: credentialsPathFor is account-scoped (Pitfall 4)
# ============================================================
{
    my $accountId = 'acct_pathcheck';
    my $path = Plugins::SpotOn::API::Credentials->credentialsPathFor($accountId);
    like($path, qr{\Q$accountId\E[\\/]credentials\.json$},
        'Test 10: credentialsPathFor ends with <accountId>/credentials.json (account-scoped, never the flat dir)');
}

# ============================================================
# Test 11: invocation contract -- recorded spawn args
# CR-01: when token-env capability is present, the token goes via env var
# (SPOTON_TOKEN), NOT as --token argv.
# ============================================================
{
    reset_all();
    my $accountId = 'acct_invocation';
    seed_credentials($accountId, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });

    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { });

    is(scalar(@Proc::Background::spawns), 1, 'Test 11: exactly one spawn recorded');
    my @args = @{ $Proc::Background::spawns[0] };
    ok((grep { $_ eq '--token-login' } @args), 'Test 11: spawn args contain --token-login');
    # CR-01: with token-env capability, --token and the token value must NOT
    # appear in argv (world-readable via /proc/<pid>/cmdline).
    ok(!(grep { $_ eq '--token' } @args), 'Test 11: spawn args do NOT contain --token (token-env capability)');
    ok(!(grep { $_ eq 'tok-fresh' } @args), 'Test 11: spawn args do NOT contain the token value (CR-01 env var path)');
    ok((grep { $_ eq '--cache' } @args), 'Test 11: spawn args contain --cache');
    my $expectedDir = catdir($cache_dir, 'spoton', $accountId);
    ok((grep { $_ eq $expectedDir } @args), 'Test 11: spawn args contain the account-scoped cache dir');
}
# Test 11b: fallback -- without token-env capability, --token argv is used
{
    reset_all();
    $Plugins::SpotOn::Helper::caps{'token-env'} = 0;
    my $accountId = 'acct_invocation_fallback';
    seed_credentials($accountId, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });

    Plugins::SpotOn::API::Credentials->deriveCredentials($accountId, sub { });

    is(scalar(@Proc::Background::spawns), 1, 'Test 11b: exactly one spawn recorded');
    my @args = @{ $Proc::Background::spawns[0] };
    ok((grep { $_ eq '--token-login' } @args), 'Test 11b: spawn args contain --token-login');
    ok((grep { $_ eq '--token' } @args), 'Test 11b: spawn args contain --token (no token-env capability)');
    ok((grep { $_ eq 'tok-fresh' } @args), 'Test 11b: spawn args contain the token value (fallback path)');
}

# ============================================================
# Test 13 (GH #147): playback-auth flag roundtrip
# mark -> needsPlaybackAuth==1 -> playbackAuthReason eq 'credential_error'
# -> clear -> needsPlaybackAuth==0
# ============================================================
{
    my $accountId = 'acct_playback_auth';

    is(Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId), 0,
        'Test 13: needsPlaybackAuth is 0 before marking');
    is(Plugins::SpotOn::API::Credentials->playbackAuthReason($accountId), '',
        'Test 13: playbackAuthReason is empty string before marking');

    Plugins::SpotOn::API::Credentials->markNeedsPlaybackAuth($accountId, 'credential_error');

    is(Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId), 1,
        'Test 13: needsPlaybackAuth is 1 after marking');
    is(Plugins::SpotOn::API::Credentials->playbackAuthReason($accountId), 'credential_error',
        'Test 13: playbackAuthReason returns the stored reason');

    Plugins::SpotOn::API::Credentials->clearNeedsPlaybackAuth($accountId);

    is(Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId), 0,
        'Test 13: needsPlaybackAuth is 0 after clearing');
    is(Plugins::SpotOn::API::Credentials->playbackAuthReason($accountId), '',
        'Test 13: playbackAuthReason returns empty string after clearing');

    # Accounts are isolated: marking one account never flags another.
    Plugins::SpotOn::API::Credentials->markNeedsPlaybackAuth('acct_other', 'credential_error');
    is(Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId), 0,
        'Test 13: flag is per-account (marking another account does not flag this one)');
    Plugins::SpotOn::API::Credentials->clearNeedsPlaybackAuth('acct_other');
}

# ============================================================
# Test 12 (T-29-07): no logged line ever contains the full token value
# ============================================================
{
    my @offending = grep { /tok-fresh/ } @Slim::Utils::Log::logged;
    is(scalar(@offending), 0,
        'Test 12: no captured log line contains the full access token value (T-29-07)');
}

done_testing();
