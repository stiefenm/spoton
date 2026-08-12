#!/usr/bin/perl
# GH #147 plan 65-02: ZeroConf pairing state machine unit tests
# (startPairing / pairingStatus / cancelPairing / _installPairedCredentials).
# Scaffolding cloned from t/16_credentials.t (write_stub pattern).
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

# Stub: Slim::Utils::Log -- records every log line so masking assertions can
# scan the full run for leaked usernames.
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
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @logged, $_[1] if defined $_[1]; }
sub warn  { push @logged, $_[1] if defined $_[1]; }
sub error { push @logged, $_[1] if defined $_[1]; }
sub debug { push @logged, $_[1] if defined $_[1]; }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
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

# Stub: Slim::Utils::Cache (playback-auth flag storage -- in-memory)
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

# Stub: Slim::Utils::Timers -- QUEUE-BASED (unlike t/16's synchronous stub):
# timers are recorded and only run when the test calls fire_all(). This lets
# the pairing state machine sit in 'waiting' across assertions (an alive
# Proc::Background + synchronous timers would recurse forever).
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @pending = ();
sub setTimer {
    my ($obj, $time, $cb, @args) = @_;
    push @pending, [$obj, $cb, \@args];
}
sub killTimers {
    my ($obj, $cb) = @_;
    @pending = grep { !($_->[0] == $obj && $_->[1] == $cb) } @pending;
}
# Fires all CURRENTLY pending timers once; re-armed timers stay queued.
sub fire_all {
    my @batch = @pending;
    @pending = ();
    for my $t (@batch) {
        $t->[1]->($t->[0], @{ $t->[2] });
    }
}
sub reset_calls { @pending = () }
1;
END

# Stub: Time::HiRes
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

# Stub: Proc::Background -- records spawns; alive() configurable; keeps the
# last created object so tests can flip {alive} to simulate helper exit.
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our @spawns = ();
our $next_alive = 0;
our $new_dies = 0;   # when true, new() throws (spawn_failed simulation)
our $last_proc;

sub new {
    my $class = shift;
    my $opts  = shift; # options hashref -- not recorded
    my @args  = @_;
    die "simulated spawn failure\n" if $new_dies;
    push @spawns, [@args];
    $last_proc = bless { alive => $next_alive, died => 0 }, $class;
    return $last_proc;
}
sub alive { return $_[0]->{alive} }
sub die   { $_[0]->{alive} = 0; $_[0]->{died} = 1; }

sub reset_stub {
    @spawns     = ();
    $next_alive = 0;
    $new_dies   = 0;
    $last_proc  = undef;
}
1;
END

# Stub: Plugins::SpotOn::Helper -- discover-once capability present by default
my $fake_helper_path = "$cache_dir/fake-spoton";
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<"END");
package Plugins::SpotOn::Helper;
our \$fake_path = '$fake_helper_path';
our \%caps = ('token-login' => 1, 'token-env' => 1, 'discover-once' => 1);

sub get { return \$fake_path }
sub getCapability {
    my (\$class, \$key) = \@_;
    return \$caps{\$key};
}
sub reset_stub {
    \$fake_path = '$fake_helper_path';
    \%caps = ('token-login' => 1, 'token-env' => 1, 'discover-once' => 1);
}
1;
END

# Stub: Slim::Utils::Misc -- getLibraryName for the pairing device name
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
our $library_name = 'Test Library';
sub getLibraryName { return $library_name }
1;
END

# Stub: Plugins::SpotOn::Unified::DaemonManager -- scheduleInit counter
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $schedule_init_calls = 0;
sub scheduleInit { $schedule_init_calls++ }
sub reset_calls  { $schedule_init_calls = 0 }
1;
END

# ============================================================
# main:: constants
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 1 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION lives in Plugin.pm (single source of truth) --
# provide the constant for standalone loads (same pattern as t/16).
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# ============================================================
# Add stub_dir and project_dir to @INC (stub_dir first)
# ============================================================
unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Slim::Utils::Timers;
require Proc::Background;
require Plugins::SpotOn::Helper;
require Plugins::SpotOn::Unified::DaemonManager;
require JSON::PP;

require_ok('Plugins::SpotOn::API::Credentials')
    or BAIL_OUT("Failed to load Plugins::SpotOn::API::Credentials");

# ============================================================
# Test helpers
# ============================================================

sub account_dir  { catdir($cache_dir, 'spoton', $_[0]) }
sub staging_dir  { catdir(account_dir($_[0]), 'pairing-tmp') }
sub live_file    { catfile(account_dir($_[0]), 'credentials.json') }
sub staging_file { catfile(staging_dir($_[0]), 'credentials.json') }

# Write a credentials.json into an arbitrary directory.
sub write_creds {
    my ($dir, $data) = @_;
    make_path($dir) unless -d $dir;
    my $file = catfile($dir, 'credentials.json');
    open(my $fh, '>', $file) or die "write_creds: $!";
    print $fh JSON::PP::encode_json($data);
    close($fh);
    return $file;
}

sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "slurp: $!";
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub reset_all {
    Proc::Background::reset_stub();
    Plugins::SpotOn::Helper::reset_stub();
    Plugins::SpotOn::Unified::DaemonManager::reset_calls();
    Slim::Utils::Timers::reset_calls();
    Plugins::SpotOn::API::Credentials->cancelPairing();
    $Slim::Utils::Misc::library_name = 'Test Library';
}

my $CREDS = Plugins::SpotOn::API::Credentials::;

# ============================================================
# Scenario (a): startPairing refuses unknown_account
# ============================================================
{
    reset_all();
    preferences('plugin.spoton')->set('accounts', {});

    my ($ok, $reason) = $CREDS->startPairing('nope1234');
    is($ok, 0, 'a: unknown account resolves ok=0');
    is($reason, 'unknown_account', 'a: unknown account resolves reason=unknown_account');
    is(scalar(@Proc::Background::spawns), 0, 'a: no spawn attempted for unknown account');
    is($CREDS->pairingStatus()->{state}, 'idle', 'a: pairing state stays idle');
}

# ============================================================
# Scenario (b): startPairing refuses when already waiting; spawn contract
# ============================================================
{
    reset_all();
    preferences('plugin.spoton')->set('accounts', {
        acct1111 => { spotifyUserId => 'userA' },
    });
    $Proc::Background::next_alive = 1;   # helper stays alive (mDNS announcing)

    my ($ok, $reason) = $CREDS->startPairing('acct1111');
    is($ok, 1, 'b: first startPairing succeeds');
    is($reason, undef, 'b: first startPairing has no failure reason');
    is($CREDS->pairingStatus()->{state}, 'waiting', 'b: state is waiting after start');
    is($CREDS->pairingStatus()->{accountId}, 'acct1111', 'b: status reports the pairing accountId');

    # Spawn contract: -n <name> --cache <staging> --discover-once
    is(scalar(@Proc::Background::spawns), 1, 'b: exactly one spawn recorded');
    my @args = @{ $Proc::Background::spawns[0] };
    ok((grep { $_ eq '--discover-once' } @args), 'b: spawn args contain --discover-once');
    ok((grep { $_ eq '--cache' } @args), 'b: spawn args contain --cache');
    ok((grep { $_ eq staging_dir('acct1111') } @args),
        'b: spawn cache dir is the pairing-tmp STAGING dir, not the live account dir');
    my ($name_idx) = grep { $args[$_] eq '-n' } 0..$#args;
    ok(defined $name_idx && $args[$name_idx + 1] =~ /^SpotOn Authorization \(/,
        'b: -n device name starts with "SpotOn Authorization (" (gotcha 1)');

    # Second start while waiting -> already_running, no second spawn
    my ($ok2, $reason2) = $CREDS->startPairing('acct1111');
    is($ok2, 0, 'b: second startPairing while waiting resolves ok=0');
    is($reason2, 'already_running', 'b: second startPairing resolves reason=already_running');
    is(scalar(@Proc::Background::spawns), 1, 'b: no second spawn while waiting');

    # Poll while alive within timeout -> re-arms, still waiting
    Slim::Utils::Timers::fire_all();
    is($CREDS->pairingStatus()->{state}, 'waiting', 'b: still waiting while helper is alive');
    is(scalar(@Slim::Utils::Timers::pending), 1, 'b: poll timer re-armed');

    # cancelPairing: kills helper, cleans staging, state -> idle
    $CREDS->cancelPairing();
    is($CREDS->pairingStatus()->{state}, 'idle', 'b: state is idle after cancel');
    is($Proc::Background::last_proc->{died}, 1, 'b: cancel killed the helper process');
    ok(!-d staging_dir('acct1111'), 'b: staging dir removed on cancel');
    is(scalar(@Slim::Utils::Timers::pending), 0, 'b: poll timer killed on cancel');

    # cancelPairing is idempotent when idle
    ok($CREDS->cancelPairing(), 'b: cancelPairing is safely callable again when idle');
}

# ============================================================
# Scenario (b2): full happy-path round trip through the poll loop
# waiting -> helper writes staging file + exits -> success
# ============================================================
{
    reset_all();
    preferences('plugin.spoton')->set('accounts', {
        acct2222 => { spotifyUserId => 'userA' },
    });
    $Proc::Background::next_alive = 1;

    my ($ok) = $CREDS->startPairing('acct2222');
    is($ok, 1, 'b2: pairing started');

    # Spotify app hands over credentials; helper writes the file and exits.
    write_creds(staging_dir('acct2222'),
        { username => 'userA', auth_type => 1, auth_data => 'QUJD' });
    $Proc::Background::last_proc->{alive} = 0;

    Slim::Utils::Timers::fire_all();

    is($CREDS->pairingStatus()->{state}, 'success', 'b2: state is success after helper exit with valid file');
    ok(-f live_file('acct2222'), 'b2: credentials.json installed into the live account dir');
    ok(!-e staging_file('acct2222'), 'b2: staging credentials.json is gone');
    ok(!-d staging_dir('acct2222'), 'b2: staging dir cleaned up');
    my $accounts = preferences('plugin.spoton')->get('accounts');
    is($accounts->{acct2222}{playbackCredSource}, 'zeroconf',
        'b2: zeroconf provenance recorded on the account');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 1,
        'b2: DaemonManager scheduleInit called once');
}

# ============================================================
# Scenario (b3): helper exits WITHOUT a credentials file -> failed
# ============================================================
{
    reset_all();
    preferences('plugin.spoton')->set('accounts', {
        acct3333 => { spotifyUserId => 'userA' },
    });
    $Proc::Background::next_alive = 1;

    $CREDS->startPairing('acct3333');
    $Proc::Background::last_proc->{alive} = 0;   # exit, no file written
    Slim::Utils::Timers::fire_all();

    is($CREDS->pairingStatus()->{state}, 'failed', 'b3: state is failed when helper exits without a file');
    ok(!-f live_file('acct3333'), 'b3: no live credentials.json appears');
    ok(!-d staging_dir('acct3333'), 'b3: staging dir cleaned up after failure');
}

# ============================================================
# Scenario (c): _installPairedCredentials happy path (direct call)
# ============================================================
{
    reset_all();
    my $acct = 'acct4444';
    preferences('plugin.spoton')->set('accounts', {
        $acct => { spotifyUserId => 'userA' },
    });
    # Flag the account first so we can assert the install clears it.
    $CREDS->markNeedsPlaybackAuth($acct, 'credential_error');
    is($CREDS->needsPlaybackAuth($acct), 1, 'c: precondition -- account flagged');

    my $staging = staging_dir($acct);
    write_creds($staging, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });

    my ($ok, $reason) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'zeroconf');

    is($ok, 1, 'c: install resolves ok=1');
    is($reason, undef, 'c: install has no failure reason');
    ok(-f live_file($acct), 'c: credentials.json installed into the account dir');
    ok(!-e staging_file($acct), 'c: staging file moved away (rename)');

    SKIP: {
        skip 'file mode assertion not meaningful on Windows', 1 if $^O eq 'MSWin32';
        my $mode = (stat(live_file($acct)))[2] & 07777;
        is($mode, 0600, 'c: installed credentials.json is chmod 0600 (T-51-03)');
    }

    my $accounts = preferences('plugin.spoton')->get('accounts');
    is($accounts->{$acct}{playbackCredSource}, 'zeroconf', 'c: provenance marker set');
    is($CREDS->needsPlaybackAuth($acct), 0, 'c: playback-auth flag cleared');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 1,
        'c: DaemonManager scheduleInit called once');
}

# ============================================================
# Scenario (c2): the shared finalizer records the given source verbatim
# (plan 65-03 reuses it with source='keymaster')
# ============================================================
{
    reset_all();
    my $acct = 'acct4455';
    preferences('plugin.spoton')->set('accounts', {
        $acct => { spotifyUserId => 'userA' },
    });
    my $staging = staging_dir($acct);
    write_creds($staging, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });

    my ($ok) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'keymaster');

    is($ok, 1, 'c2: install with source=keymaster resolves ok=1');
    my $accounts = preferences('plugin.spoton')->get('accounts');
    is($accounts->{$acct}{playbackCredSource}, 'keymaster',
        'c2: provenance marker records the passed source (finalizer is source-agnostic)');
}

# ============================================================
# Scenario (d): D-01 mismatch -- wrong username rejected, live file untouched
# ============================================================
{
    reset_all();
    my $acct = 'acct5555';
    preferences('plugin.spoton')->set('accounts', {
        $acct => { spotifyUserId => 'userA' },
    });

    # Pre-existing LIVE credentials.json that must survive byte-identically.
    write_creds(account_dir($acct),
        { username => 'userA', auth_type => 1, auth_data => 'T1JJRw==' });
    my $live_before = slurp(live_file($acct));

    my $staging = staging_dir($acct);
    write_creds($staging,
        { username => 'userB_full_secret', auth_type => 1, auth_data => 'QUJD' });

    my ($ok, $reason) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'zeroconf');

    is($ok, 0, 'd: mismatched username resolves ok=0');
    is($reason, 'account_mismatch', 'd: mismatched username resolves reason=account_mismatch');
    is(slurp(live_file($acct)), $live_before,
        'd: pre-existing live credentials.json is byte-identical (D-01)');

    my $accounts = preferences('plugin.spoton')->get('accounts');
    ok(!exists $accounts->{$acct}{playbackCredSource},
        'd: no provenance marker written on mismatch');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 0,
        'd: scheduleInit NOT called on mismatch');

    # T-65-07: mismatch warn line masks BOTH usernames (first 3 chars + ****)
    my @leaks = grep { /userB_full_secret/ } @Slim::Utils::Log::logged;
    is(scalar(@leaks), 0, 'd: no log line contains the full mismatched username');
    ok((grep { /use\*\*\*\*/ } @Slim::Utils::Log::logged),
        'd: mismatch warn line contains the masked username form');
}

# ============================================================
# Scenario (d2): fail-closed when the account has no spotifyUserId
# ============================================================
{
    reset_all();
    my $acct = 'acct5566';
    preferences('plugin.spoton')->set('accounts', { $acct => {} });

    my $staging = staging_dir($acct);
    write_creds($staging, { username => 'userA', auth_type => 1, auth_data => 'QUJD' });

    my ($ok, $reason) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'zeroconf');

    is($ok, 0, 'd2: unknown expected user resolves ok=0 (fail-closed)');
    is($reason, 'account_mismatch', 'd2: unknown expected user resolves reason=account_mismatch');
    ok(!-f live_file($acct), 'd2: nothing installed');
}

# ============================================================
# Scenario (e): invalid staging file rejected (auth_type 0 / missing fields / corrupt)
# ============================================================
{
    reset_all();
    my $acct = 'acct6666';
    preferences('plugin.spoton')->set('accounts', {
        $acct => { spotifyUserId => 'userA' },
    });

    my $staging = staging_dir($acct);

    write_creds($staging, { username => 'userA', auth_type => 0, auth_data => 'QUJD' });
    my ($ok1, $reason1) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'zeroconf');
    is($ok1, 0, 'e: auth_type=0 resolves ok=0');
    is($reason1, 'invalid_credentials', 'e: auth_type=0 resolves reason=invalid_credentials');

    write_creds($staging, { username => 'userA', auth_type => 1, auth_data => '' });
    my ($ok2, $reason2) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'zeroconf');
    is($ok2, 0, 'e: empty auth_data resolves ok=0');
    is($reason2, 'invalid_credentials', 'e: empty auth_data resolves reason=invalid_credentials');

    # Corrupt JSON
    make_path($staging) unless -d $staging;
    open(my $fh, '>', staging_file($acct)) or die $!;
    print $fh '{ not json ]]]';
    close($fh);
    my ($ok3, $reason3) = Plugins::SpotOn::API::Credentials::_installPairedCredentials(
        $acct, $staging, 'zeroconf');
    is($ok3, 0, 'e: corrupt JSON resolves ok=0');
    is($reason3, 'invalid_credentials', 'e: corrupt JSON resolves reason=invalid_credentials');

    ok(!-f live_file($acct), 'e: nothing installed from invalid staging files');
}

# ============================================================
# Scenario (f): pairing device name contract (gotcha 1)
# ============================================================
{
    reset_all();
    my $name = $CREDS->pairingDeviceName();
    like($name, qr/^SpotOn Authorization \(/,
        'f: device name starts with "SpotOn Authorization ("');
    ok(length($name) <= 60, 'f: device name is <= 60 chars');
    like($name, qr/Test Library/, 'f: device name contains the library name');

    # Truncation with an oversized library name
    $Slim::Utils::Misc::library_name = 'X' x 200;
    my $long = $CREDS->pairingDeviceName();
    is(length($long), 60, 'f: oversized library name truncated to exactly 60 chars');

    # Fallback when the library name is empty
    $Slim::Utils::Misc::library_name = '';
    is($CREDS->pairingDeviceName(), 'SpotOn Authorization (LMS)',
        'f: empty library name falls back to LMS');
}

# ============================================================
# Scenario (g): capability / binary gates
# ============================================================
{
    reset_all();
    preferences('plugin.spoton')->set('accounts', {
        acct7777 => { spotifyUserId => 'userA' },
    });

    $Plugins::SpotOn::Helper::caps{'discover-once'} = 0;
    my ($ok, $reason) = $CREDS->startPairing('acct7777');
    is($ok, 0, 'g: missing discover-once capability resolves ok=0');
    is($reason, 'no_capability', 'g: missing discover-once capability resolves reason=no_capability');

    Plugins::SpotOn::Helper::reset_stub();
    $Plugins::SpotOn::Helper::fake_path = '';
    my ($ok2, $reason2) = $CREDS->startPairing('acct7777');
    is($ok2, 0, 'g: missing binary resolves ok=0');
    is($reason2, 'no_binary', 'g: missing binary resolves reason=no_binary');

    Plugins::SpotOn::Helper::reset_stub();
    $Proc::Background::new_dies = 1;
    my ($ok3, $reason3) = $CREDS->startPairing('acct7777');
    is($ok3, 0, 'g: spawn failure resolves ok=0');
    is($reason3, 'spawn_failed', 'g: spawn failure resolves reason=spawn_failed');
    is($CREDS->pairingStatus()->{state}, 'idle', 'g: state stays idle after spawn failure');
}

done_testing();
