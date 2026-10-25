#!/usr/bin/perl
# Phase 83.3 plan 03 (D-01/D-03/D-04/D-06/D-07 storage half): behavioral
# coverage for the renewal engine -- renewBinary()'s D-04 guard bypass, the
# full download -> extract -> version gate -> smoke test -> promote pipeline
# with exactly one kept previous generation, the shared lifecycleInFlight
# guard (including the hard-timeout fallback), and checkRenewalDue()'s
# <=14-day + daily-retry + exit-10 trigger cadence. Mirrors t/26's harness
# (LMS module stubs) plus a stateful Cache stub (t/33_soloist_expiry.t
# pattern) and a Timers stub that can actually fire a registered timer
# (t/30_soloist_daemon.t pattern).
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);
use File::Spec::Functions qw(catdir catfile);

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Soloist.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Soloist.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

unless (`tar --version 2>&1` && $? == 0) {
    die "system tar not available -- required for the renewal pipeline tests (84-09: die, never skip)\n";
}

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

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
# LMS module stubs (mirrors t/26_soloist_check.t)
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

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

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );
my \%_change_cbs;

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
    if (\$_change_cbs{ \$self->{_ns} }{\$key}) {
        \$_->(\$self, \$val) for \@{ \$_change_cbs{ \$self->{_ns} }{\$key} };
    }
}

sub client { return bless { _ns => \$_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }

sub setChange {
    my (\$self, \$cb, \$key) = \@_;
    push \@{ \$_change_cbs{ \$self->{_ns} }{\$key} }, \$cb;
}

sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
our $osArch = 'x86_64';
sub details { return { osArch => $osArch } }
sub OS      { 'unix' }
sub getOS   { return bless {}, 'Slim::Utils::OSDetect' }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END

# Stateful cache stub (t/33_soloist_expiry.t pattern) -- Soloist.pm's own
# _cache() helper instantiates a fresh object per call, so the state MUST
# live at the package level, not the object.
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %STORE;
sub new    { return bless {}, shift }
sub get    { my ($self, $k) = @_; return $STORE{$k}; }
sub set    { my ($self, $k, $v, $ttl) = @_; $STORE{$k} = $v; return 1; }
sub remove { my ($self, $k) = @_; delete $STORE{$k}; }
sub reset_store { %STORE = (); }
1;
END

# Timers stub that can actually fire a registered timer (t/30 pattern) --
# needed for case 7c (hard-timeout) and Task 2's cadence tests. Comparison
# uses 'eq' (not '=='): renewBinary's hard-timeout timer is registered
# against __PACKAGE__ (a plain string), not a blessed object.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @TIMERS;
sub setTimer {
    my ($obj, $when, $cb, @args) = @_;
    push @TIMERS, [$obj, $when, $cb, @args];
}
sub killTimers {
    my ($obj, $cb) = @_;
    @TIMERS = grep { !($_->[0] eq $obj && $_->[2] == $cb) } @TIMERS;
}
sub fire_due {
    my ($now) = @_;
    my @due = grep { $_->[1] <= $now } @TIMERS;
    @TIMERS = grep { $_->[1] > $now } @TIMERS;
    for my $t (@due) {
        my ($obj, undef, $cb, @extra) = @$t;
        $cb->($obj, @extra);
    }
}
sub reset_timers { @TIMERS = (); }
1;
END

# Controllable SimpleAsyncHTTP stub -- in success mode, builds a REAL
# tar.gz fixture archive (a fake soloist script reporting
# $candidate_version) at the saveAs path before invoking cb, exactly like
# t/26 Test 12's download-pipeline fixture, so _extractArchive/_versionProbe
# run against real bytes, not a mock.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @created = ();
our $auto_mode = 'none';    # none | success | error
our $auto_error = 'simulated network error';
our $candidate_version = '1.3.8.70';

sub new {
    my ($class, $cb, $ecb, $opts) = @_;
    my $self = bless { cb => $cb, ecb => $ecb, opts => $opts }, $class;
    push @created, $self;
    return $self;
}
sub get {
    my ($self, $url) = @_;
    $self->{url} = $url;
    if ($auto_mode eq 'success') {
        _build_fixture_archive($self->{opts}{saveAs}, $candidate_version);
        $self->{cb}->($self);
    } elsif ($auto_mode eq 'error') {
        $self->{ecb}->($self, $auto_error);
    }
    return;
}
sub content { '' }
sub reset_stub { @created = (); $auto_mode = 'none'; }

sub _build_fixture_archive {
    my ($archivePath, $version) = @_;
    require File::Temp;
    my $srcDir = File::Temp::tempdir(CLEANUP => 1);
    open(my $fh, '>', "$srcDir/soloist") or die "fixture write failed: $!";
    print $fh "#!/bin/sh\n";
    print $fh "if [ \"\$1\" = '--version' ]; then\n";
    print $fh "  echo 'soloist $version build 1 (20260101) (gabc123) (linux/x86_64)'\n";
    print $fh "  exit 0\n";
    print $fh "fi\n";
    print $fh "exit 1\n";
    close($fh);
    chmod(0755, "$srcDir/soloist");
    system('tar', 'czf', $archivePath, '-C', $srcDir, 'soloist');
}
1;
END

# SoloistDaemon stub -- smokeTest() calls cb SYNCHRONOUSLY with $SMOKE_OK/
# $SMOKE_INFO (unless $SMOKE_SYNC is false, for the hard-timeout case 7c).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::SoloistDaemon', <<'END');
package Plugins::SpotOn::Unified::SoloistDaemon;
our @SMOKE_CALLS;
our $SMOKE_OK   = 1;
our $SMOKE_INFO = { days => 89, version => '1.3.8.70' };
our $SMOKE_SYNC = 1;
sub smokeTest {
    my ($class, $path, $cb) = @_;
    push @SMOKE_CALLS, $path;
    $cb->($SMOKE_OK, $SMOKE_INFO) if $SMOKE_SYNC;
}
sub reset_calls { @SMOKE_CALLS = (); $SMOKE_SYNC = 1; }
1;
END

# DaemonManager stub -- counts onSoloistBinaryReplaced calls.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our @REPLACED_CALLS;
sub onSoloistBinaryReplaced { my ($class, $info) = @_; push @REPLACED_CALLS, $info; }
sub reset_calls { @REPLACED_CALLS = (); }
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
    *main::INFOLOG     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };    # 84-12: Backend::Soloist (onInitHelpers/rollbackBinary cells) compiles against it
}

unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Slim::Utils::OSDetect;
require Slim::Networking::SimpleAsyncHTTP;
require Slim::Utils::Timers;
require Slim::Utils::Cache;
require Plugins::SpotOn::Unified::SoloistDaemon;
require Plugins::SpotOn::Unified::DaemonManager;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist");

Plugins::SpotOn::Soloist::init();

my $reset_counter = 0;

# Writes an executable shell-script "soloist" binary (t/26 pattern).
sub write_fake_binary {
    my ($path, $reportedVersion) = @_;
    open(my $fh, '>', $path) or die "write_fake_binary: $!";
    print $fh "#!/bin/sh\n";
    print $fh "if [ \"\$1\" = '--version' ]; then\n";
    print $fh "  echo 'soloist $reportedVersion build 1787637711 (20260825) (gb24005ef46) (linux/x86_64)'\n";
    print $fh "  exit 0\n";
    print $fh "fi\n";
    print $fh "exit 1\n";
    close($fh);
    chmod(0755, $path);
}

# reset_env() -- clears every stateful stub AND the on-disk cache tree
# between cases (the renewal pipeline writes real files: staging/,
# previous/, the canonical binary), so no case can observe another case's
# leftovers. Also forces a fresh $binary/$version via the same 'backend'
# pref-change invalidation Soloist->init() wires up (t/26 reset_all idiom).
sub reset_env {
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    Slim::Utils::Cache::reset_store();
    Slim::Utils::Timers::reset_timers();
    Plugins::SpotOn::Unified::SoloistDaemon::reset_calls();
    Plugins::SpotOn::Unified::DaemonManager::reset_calls();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    my $spotonDir = catdir($cache_dir, 'spoton');
    remove_tree($spotonDir) if -d $spotonDir;
}

sub bin_dir       { return catdir($cache_dir, 'spoton', 'soloist', 'x86_64-linux'); }
sub canonical_bin { return catfile(bin_dir(), 'soloist'); }
sub previous_bin  { return catfile(bin_dir(), 'previous', 'soloist'); }

# Places a version-matched canonical binary (the "currently active" install)
# before a renewal is exercised against it.
sub seed_active_binary {
    my ($version) = @_;
    make_path(bin_dir());
    write_fake_binary(canonical_bin(), $version);
}

# ============================================================
# Task 1: renewal pipeline
# ============================================================

# Case 1: D-04 guard bypass + busy while in flight.
{
    reset_env();
    seed_active_binary('1.3.8.68');

    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r, 'started',
        "Case 1: renewBinary(manual) returns 'started' even though a valid binary is already cached (D-04 bypass)");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 1, "Case 1: a download was issued");

    my $r2 = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r2, 'busy', "Case 1: a second call while a renewal is in flight returns 'busy'");

    # Drain the still-in-flight renewal (auto_mode is 'none') so it cannot
    # leak into the next case.
    my $http = $Slim::Networking::SimpleAsyncHTTP::created[-1];
    $http->{ecb}->($http, 'test cleanup');
    is(Plugins::SpotOn::Soloist::lifecycleInFlight(), undef, "Case 1: guard cleared after the drained call finishes");
}

# Case 2: full success -- extract, smoke ok, promote, generation record,
# expiry cache rewritten, DaemonManager notified, staging gone, exit-10
# flag cleared.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired', { version => '1.3.8.68', at => time() }, 'never');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK     = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO   = { days => 89, version => '1.3.8.70' };

    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r, 'started', "Case 2: renewBinary returns 'started'");

    is(Plugins::SpotOn::Soloist::_versionProbe(previous_bin()), '1.3.8.68',
        "Case 2: previous/soloist reports the old version 1.3.8.68");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.70',
        "Case 2: canonical soloist reports the new version 1.3.8.70");

    my (undef, $activeVersion) = Plugins::SpotOn::Soloist::get();
    is($activeVersion, '1.3.8.70', "Case 2: get() returns the newly-promoted version");

    my $gen = Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_generation');
    is($gen->{previous_version}, '1.3.8.68', "Case 2: generation record previous_version is 1.3.8.68");
    ok(defined $gen->{switched_at}, "Case 2: generation record has switched_at");

    my $expiry = Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expiry_days');
    is($expiry->{days}, 89, "Case 2: spoton_soloist_expiry_days days is 89 (the smoke-tested new build)");

    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::REPLACED_CALLS), 1,
        "Case 2: onSoloistBinaryReplaced called exactly once");

    my $archInfo   = Plugins::SpotOn::Soloist::_arch();
    my $stagingDir = Plugins::SpotOn::Soloist::_stagingDir($archInfo);
    ok(!-d $stagingDir, "Case 2: staging dir gone after promotion");

    ok(!Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expired'),
        "Case 2: spoton_soloist_expired cleared by promotion's explicit _versionCheck activation");

    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done', "Case 2: renewalState phase is 'done'");
    ok(Plugins::SpotOn::Soloist::hasPreviousGeneration(), "Case 2: hasPreviousGeneration() is true");
}

# Case 3: candidate below the pinned minimum -- rejected before any smoke
# test, canonical untouched.
{
    reset_env();
    seed_active_binary('1.3.8.68');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.1';

    Plugins::SpotOn::Soloist::renewBinary(reason => 'expiry');

    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'failed', "Case 3: state is 'failed'");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'below_minimum', "Case 3: detail is 'below_minimum'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 3: canonical still reports 1.3.8.68");
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::REPLACED_CALLS), 0, "Case 3: DaemonManager never notified");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), 0, "Case 3: smokeTest never called");
}

# Case 4: smoke test fails -- canonical and previous both unchanged.
{
    reset_env();
    seed_active_binary('1.3.8.68');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK     = 0;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO   = { reason => 'no_expiry_line' };

    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');

    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'failed', "Case 4: state is 'failed'");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'no_expiry_line', "Case 4: detail is 'no_expiry_line'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 4: canonical unchanged");
    ok(!-e previous_bin(), "Case 4: previous/ was never populated");
}

# Case 5: same-version candidate -- discarded for an automatic reason,
# still smoke-tested and swapped for a manual one.
{
    reset_env();
    seed_active_binary('1.3.8.68');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.68';
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK     = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO   = { days => 90, version => '1.3.8.68' };

    Plugins::SpotOn::Soloist::renewBinary(reason => 'expiry');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'same_version',
        "Case 5: reason=expiry + same version -> 'same_version', retried tomorrow");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), 0,
        "Case 5: the automatic same-version short-circuit happens BEFORE the smoke test");

    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done',
        "Case 5: reason=manual + same version still runs the whole pipeline and swaps");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), 1,
        "Case 5: manual same-version DOES run the smoke test (button exercises the whole path)");
}

# Case 5b: same-version candidate with reason=exit10 -- failed, not silently
# discarded (the CDN itself is still serving the expired build).
{
    reset_env();
    seed_active_binary('1.3.8.68');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.68';

    Plugins::SpotOn::Soloist::renewBinary(reason => 'exit10');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'failed',
        "Case 5b: reason=exit10 + same version -> 'failed', not 'same_version'");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'CDN still serves the expired build',
        "Case 5b: detail names the CDN specifically");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), 0,
        "Case 5b: no smoke test for the exit10 same-version failure");
}

# Case 5c (G-83.3-6b): a detail-less terminal phase, or a new attempt in
# progress, must never show the previous attempt's detail. Four sub-blocks:
# (a) failed -> done, (b) failed -> same_version, (c) failed -> new attempt
# in progress, (d) a concurrent writer's detail must not survive a later
# detail-less terminal phase. SMOKE_OK/SMOKE_INFO are set with `local` in
# each sub-block so Case 6 still inherits exactly what Case 5b left there
# (reset_calls does not reset these two globals).

# Case 5c(a): failed (exit10) -> a manual retry with a new version reaches
# 'done'.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 89, version => '1.3.8.70' };

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.68';
    Plugins::SpotOn::Soloist::renewBinary(reason => 'exit10');
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'CDN still serves the expired build',
        "Case 5c(a): precondition -- failed exit10 attempt carries the CDN detail");

    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';
    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done',
        "Case 5c(a): manual renewal after the failed attempt reaches 'done'");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, undef,
        "Case 5c(a): 'done' carries no stale detail from the failed attempt (G-83.3-6b)");
}

# Case 5c(b): failed (exit10) -> a later automatic same-version retry
# reaches 'same_version'.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 89, version => '1.3.8.70' };

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.68';
    Plugins::SpotOn::Soloist::renewBinary(reason => 'exit10');
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'CDN still serves the expired build',
        "Case 5c(b): precondition -- failed exit10 attempt carries the CDN detail");

    Plugins::SpotOn::Soloist::renewBinary(reason => 'expiry');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'same_version',
        "Case 5c(b): a same-version automatic retry after the failed attempt reaches 'same_version'");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, undef,
        "Case 5c(b): 'same_version' carries no stale detail from the failed attempt (G-83.3-6b)");
}

# Case 5c(c): failed (exit10) -> a new attempt in progress ('downloading')
# must show no detail from the previous attempt; its own eventual failure
# still records its own detail.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 89, version => '1.3.8.70' };

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.68';
    Plugins::SpotOn::Soloist::renewBinary(reason => 'exit10');
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'CDN still serves the expired build',
        "Case 5c(c): precondition -- failed exit10 attempt carries the CDN detail");

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'none';
    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r, 'started', "Case 5c(c): a new attempt after the failed one starts");
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'downloading',
        "Case 5c(c): the new attempt is 'downloading'");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, undef,
        "Case 5c(c): a new attempt in progress ('downloading') shows no detail from the previous attempt (G-83.3-6b)");

    my $http = $Slim::Networking::SimpleAsyncHTTP::created[-1];
    $http->{ecb}->($http, 'test cleanup');
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'download_failed:test cleanup',
        "Case 5c(c): a detail-carrying terminal phase still records its own detail");
}

# Case 5c(d): a concurrent writer (mirrors DaemonManager.pm:1635's
# rollback_impossible write) sets a detail while a renewal is in flight;
# that detail must not survive the run's own detail-less terminal phase.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    local $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 89, version => '1.3.8.70' };

    # auto_mode stays 'none' (the reset_env default) -- the download stays
    # pending until we drive it home explicitly below.
    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');

    Plugins::SpotOn::Soloist::_setRenewalState(phase => 'rollback_impossible', detail => 'no_previous');

    my $http = $Slim::Networking::SimpleAsyncHTTP::created[-1];
    Slim::Networking::SimpleAsyncHTTP::_build_fixture_archive($http->{opts}{saveAs}, '1.3.8.70');
    $http->{cb}->($http);

    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done',
        "Case 5c(d): the run completes as 'done' despite the concurrent writer");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, undef,
        "Case 5c(d): 'done' clears a detail written mid-flight by a concurrent writer (G-83.3-6b)");
}

# Case 6: a second successful renewal keeps exactly ONE previous generation
# (the one immediately before the latest swap, not the original).
{
    reset_env();
    seed_active_binary('1.3.8.68');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';
    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done', "Case 6: first renewal (68 -> 70) succeeds");

    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.71';
    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done', "Case 6: second renewal (70 -> 71) succeeds");

    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.71', "Case 6: canonical is now 1.3.8.71");
    is(Plugins::SpotOn::Soloist::_versionProbe(previous_bin()), '1.3.8.70',
        "Case 6: previous/ holds the version JUST before the latest swap (70) -- the original (68) is gone (exactly one generation kept)");

    # MUST-FAIL dry run (verified by hand during authoring, reverted
    # immediately): short-circuiting _promoteCandidate's "move the current
    # canonical into previous/ before the swap" step (the actual mechanism
    # that keeps exactly one generation) turns the assertion above
    # `not ok` -- previous/ then keeps reporting whatever it held before
    # promotion instead of the version just swapped out. The
    # `remove_tree(_previousDir)` call one line above it is defense against
    # a stale multi-file previous/ dir (e.g. a prior interrupted run); with
    # a single-file previous/soloist target, File::Copy::move()'s own
    # destination-overwrite semantics already keep exactly one file there
    # even without it, so removing that specific line does not move this
    # assertion by itself -- the move step above is the one this test
    # actually pins.
}

# Case 7: unsupported architecture -- functionally identical to the
# Windows/macOS path (both make _arch() return undef; RESEARCH's ARCH_MAP
# has no Windows/macOS entry to begin with, so simulating via an
# unrecognized osArch exercises the exact same `unless $archInfo` branch).
{
    reset_env();
    $Slim::Utils::OSDetect::osArch = 'totally-unknown-arch';

    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r, 'unsupported', "Case 7: renewBinary returns 'unsupported' when _arch() cannot resolve an architecture");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 0, "Case 7: no download attempted");
}

# Case 7b: _finishRenewal is idempotent -- a second call after completion
# is a no-op (cb already fired exactly once, guard already cleared).
{
    reset_env();
    seed_active_binary('1.3.8.68');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';

    my @cb_calls;
    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual', cb => sub { push @cb_calls, [@_]; });
    is(scalar(@cb_calls), 1, "Case 7b: cb fired exactly once from the normal completion");
    is(Plugins::SpotOn::Soloist::lifecycleInFlight(), undef, "Case 7b: lifecycleInFlight cleared after completion");

    my $again = Plugins::SpotOn::Soloist::_finishRenewal('done', undef);
    is($again, 0, "Case 7b: a second _finishRenewal call after completion is a no-op (returns false)");
    is(scalar(@cb_calls), 1, "Case 7b: cb still fired only once");
}

# Case 7c: the smoke stub NEVER calls its cb -- the hard-timeout timer
# fires, finalizing as failed/'stalled', clearing the guard, firing cb once.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_SYNC   = 0;

    my @cb_calls;
    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual', cb => sub { push @cb_calls, [@_]; });
    is($r, 'started', "Case 7c: renewBinary returns 'started'");
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'smoke',
        "Case 7c: state is stuck at 'smoke' because the stub never calls back");
    is(Plugins::SpotOn::Soloist::lifecycleInFlight(), 'renewal', "Case 7c: guard still held while stalled");
    is(scalar(@cb_calls), 0, "Case 7c: cb has not fired yet");

    Slim::Utils::Timers::fire_due(time() + 86400);

    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'failed', "Case 7c: state is 'failed' after the hard timeout");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'stalled', "Case 7c: detail is 'stalled'");
    is(Plugins::SpotOn::Soloist::lifecycleInFlight(), undef, "Case 7c: guard cleared by the hard timeout");
    is(scalar(@cb_calls), 1, "Case 7c: cb fired exactly once");
}

# ============================================================
# Task 2: checkRenewalDue() trigger cadence
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    preferences('plugin.spoton')->set('backend', 'soloist');

    my @renew_calls;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my %opts = @_;
        push @renew_calls, \%opts;
        return 'started';
    };

    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days', { days => 15, checked_at => time() }, 'never');
    is(Plugins::SpotOn::Soloist::checkRenewalDue(), 'not_due', "Task2: days 15 is not due");
    is(scalar(@renew_calls), 0, "Task2: no renewBinary call at days 15");

    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days', { days => 14, checked_at => time() }, 'never');
    is(Plugins::SpotOn::Soloist::checkRenewalDue(), 'started', "Task2: days 14 triggers a renewal (MUST-FAIL: RENEWAL_TRIGGER_DAYS=13 turns this not_due -- verified by hand, reverted)");
    is(scalar(@renew_calls), 1, "Task2: exactly one renewBinary call");
    is($renew_calls[0]{reason}, 'expiry', "Task2: reason is 'expiry'");

    # checkRenewalDue's daily-retry gate reads renewalState()->{last_attempt_at}
    # -- since renewBinary is stubbed here (never touches renewalState),
    # simulate the side effect a real call would have recorded.
    Plugins::SpotOn::Soloist::_setRenewalState(last_attempt_at => time());
    is(Plugins::SpotOn::Soloist::checkRenewalDue(), 'retry_wait', "Task2: immediately again is retry_wait");
    is(scalar(@renew_calls), 1, "Task2: still exactly one renewBinary call");

    Plugins::SpotOn::Soloist::_setRenewalState(last_attempt_at => time() - 86401);
    is(Plugins::SpotOn::Soloist::checkRenewalDue(), 'started', "Task2: past the daily retry floor triggers again");
    is(scalar(@renew_calls), 2, "Task2: second renewBinary call");

    Plugins::SpotOn::Soloist::_setRenewalState(last_attempt_at => time() - 86401);
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired', { version => '1.3.8.68', at => time() }, 'never');
    Plugins::SpotOn::Soloist::checkRenewalDue();
    is($renew_calls[-1]{reason}, 'exit10', "Task2: the exit10 flag takes reason priority over the expiry-days trigger");
    Plugins::SpotOn::Soloist::_cache()->remove('spoton_soloist_expired');

    preferences('plugin.spoton')->set('backend', 'librespot');
    is(Plugins::SpotOn::Soloist::checkRenewalDue(), 'not_soloist', "Task2: backend=librespot is not_soloist");
}

# ============================================================
# Phase 83.3 plan 04 (D-07): rollbackToPrevious()
# ============================================================

# Case 8: after a real promotion (68 -> 70), rollbackToPrevious() swaps the
# kept previous generation back in.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    # Seed a positive expiry reading BEFORE the promotion -- mirrors a
    # realistic running daemon (oldDays would otherwise be undef on a
    # from-scratch test env, which correctly fails closed to
    # 'previous_expired'; this case exercises the SUCCESS path instead).
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days', { days => 80, checked_at => time() }, 'never');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.70';
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK     = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO   = { days => 89, version => '1.3.8.70' };

    Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done', "Case 8 setup: promotion 68 -> 70 succeeds");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.70', "Case 8 setup: canonical is now 1.3.8.70");
    is(Plugins::SpotOn::Soloist::_versionProbe(previous_bin()), '1.3.8.68', "Case 8 setup: previous is 1.3.8.68");

    my ($ok, $detail) = Plugins::SpotOn::Soloist::rollbackToPrevious(reason => 't');
    is($ok, 1, "Case 8: rollbackToPrevious returns true");
    is($detail, '1.3.8.68', "Case 8: rollbackToPrevious returns the restored version 1.3.8.68");

    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68',
        "Case 8: canonical now reports the restored version 1.3.8.68");
    ok(!-e previous_bin(), "Case 8: previous/soloist is gone (moved back into place)");

    my (undef, $activeVersion) = Plugins::SpotOn::Soloist::get();
    is($activeVersion, '1.3.8.68', "Case 8: get() returns the rolled-back version");

    my $gen = Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_generation');
    is($gen->{rolled_back_from}, '1.3.8.70', "Case 8: generation record has rolled_back_from 1.3.8.70");
    is($gen->{previous_version}, undef, "Case 8: generation record has no previous_version after a rollback");

    my $state = Plugins::SpotOn::Soloist::renewalState();
    is($state->{phase}, 'rolled_back', "Case 8: renewalState phase is 'rolled_back'");
    ok(defined $state->{last_attempt_at}, "Case 8: renewalState has last_attempt_at set");
    is($state->{to_version}, '1.3.8.68', "Case 8: renewalState to_version is 1.3.8.68");
    is($state->{from_version}, '1.3.8.70', "Case 8: renewalState from_version is 1.3.8.70");
}

# Case 9: a previous generation exists but its wall-clock-adjusted remaining
# lifetime is <= 0 -- rollback refused, nothing moves, only the notice
# (rollback_impossible) is recorded.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(catdir(bin_dir(), 'previous'));
    write_fake_binary(previous_bin(), '1.3.8.67');
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_generation', {
        active_version       => '1.3.8.68',
        previous_version     => '1.3.8.67',
        previous_expiry_days => 0,
        switched_at          => time(),
        reason               => 'manual',
    }, 'never');

    my ($ok, $detail) = Plugins::SpotOn::Soloist::rollbackToPrevious(reason => 't');
    is($ok, 0, "Case 9: rollbackToPrevious returns false when previous_expiry_days is 0");
    is($detail, 'previous_expired', "Case 9: detail is 'previous_expired'");

    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68',
        "Case 9: canonical still reports 1.3.8.68 (nothing moved)");
    ok(-e previous_bin(), "Case 9: previous/soloist is still present (nothing moved)");

    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'rollback_impossible',
        "Case 9: renewalState phase is 'rollback_impossible'");
}

# Case 10: no previous generation on disk at all.
{
    reset_env();
    seed_active_binary('1.3.8.68');

    my ($ok, $detail) = Plugins::SpotOn::Soloist::rollbackToPrevious(reason => 't');
    is($ok, 0, "Case 10: rollbackToPrevious returns false with no previous generation on disk");
    is($detail, 'no_previous', "Case 10: detail is 'no_previous'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 10: canonical unchanged");
}

# Case 10b (84-12 Task 2): the same no_previous outcome reached through the
# Soloist role -- Backend::Soloist->rollbackBinary returns rollbackToPrevious's
# (ok, detail) and itself stamps the terminal 'rollback_impossible' notice
# that DaemonManager::_rollbackAfterSwitch used to write (83.3-REVIEW round 2,
# WR-02: no_previous returns from rollbackToPrevious without a stamp).
{
    reset_env();
    seed_active_binary('1.3.8.68');
    Plugins::SpotOn::Soloist::_setRenewalState(phase => 'done', detail => undef);

    require Plugins::SpotOn::Backend::Soloist;
    my ($ok, $detail) = eval { Plugins::SpotOn::Backend::Soloist->rollbackBinary(reason => 't') };
    is($ok, 0, "Case 10b (84-12): rollbackBinary through the role returns false with no previous generation");
    is($detail, 'no_previous', "Case 10b (84-12): rollbackBinary through the role returns detail 'no_previous'");
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'rollback_impossible',
        "Case 10b (84-12): the role stamps renewalState phase 'rollback_impossible' for no_previous");
    is(Plugins::SpotOn::Soloist::renewalState()->{detail}, 'no_previous',
        "Case 10b (84-12): the stamp carries detail 'no_previous'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 10b (84-12): canonical unchanged");
}

# ============================================================
# Phase 83.3 plan 08 (D-01/D-03 gap 2, WR-01): the exit-10 park flag
# survives a read-only re-probe of the SAME expired binary (e.g. the very
# first get() after an LMS restart); it is cleared only when the probed
# binary genuinely differs (version or mtime) from the one recorded.
#
# "restart idiom": simulate an LMS restart by resetting only the in-process
# $binary/$version via the same 'backend' pref-change hook Soloist->init()
# wires up -- NOT reset_env(), which also wipes the on-disk cache (including
# the flag under test).
# ============================================================

# Case 11a: same binary, same mtime -- flag must survive.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    my $expiredMtime = (stat(canonical_bin()))[9];
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired',
        { version => '1.3.8.68', mtime => $expiredMtime, at => time() }, 'never');

    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    my ($bin, $ver) = Plugins::SpotOn::Soloist::get();
    is($bin, canonical_bin(), "Case 11a: get() still returns the canonical path (binary is still activatable)");
    is($ver, '1.3.8.68', "Case 11a: get() still reports 1.3.8.68");
    ok(Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expired'),
        "Case 11a: the park flag survives a read-only re-probe of the SAME expired binary");
}

# Case 11b: same version, bumped mtime (a replaced copy of the same pinned
# version) -- flag clears.
{
    reset_env();
    seed_active_binary('1.3.8.68');
    my $oldMtime = (stat(canonical_bin()))[9];
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired',
        { version => '1.3.8.68', mtime => $oldMtime, at => time() }, 'never');

    write_fake_binary(canonical_bin(), '1.3.8.68');
    utime($oldMtime + 5, $oldMtime + 5, canonical_bin());

    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    my ($bin, $ver) = Plugins::SpotOn::Soloist::get();
    is($ver, '1.3.8.68', "Case 11b: get() still returns 1.3.8.68");
    ok(!Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expired'),
        "Case 11b: a replaced copy of the same version (different mtime) clears the park flag");
}

# Case 11c: legacy flag record with no mtime field at all -- cleared once
# (one-time self-heal for records written before this plan).
{
    reset_env();
    seed_active_binary('1.3.8.68');
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired',
        { version => '1.3.8.68', at => time() }, 'never');

    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    my ($bin, $ver) = Plugins::SpotOn::Soloist::get();
    is($ver, '1.3.8.68', "Case 11c: get() returns 1.3.8.68");
    ok(!Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expired'),
        "Case 11c: a legacy flag record without mtime is cleared once (one-time self-heal)");
}

# Case 11d (real material): a canonical binary whose --version output is the
# verbatim live banner from 83.3-LIVE-CHECKS.md:20 (1.3.8.79) -- genuinely
# different version than the parked one clears the flag.
{
    reset_env();
    make_path(bin_dir());
    open(my $fh, '>', canonical_bin()) or die "Case 11d write_fake_binary: $!";
    print $fh "#!/bin/sh\n";
    print $fh "if [ \"\$1\" = '--version' ]; then\n";
    print $fh "  echo 'soloist 1.3.8.79 build 1790380866 (20260926) (g5c3a2053ac) (linux/x86_64)'\n";
    print $fh "  exit 0\n";
    print $fh "fi\n";
    print $fh "exit 1\n";
    close($fh);
    chmod(0755, canonical_bin());

    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired',
        { version => '1.3.8.68', mtime => 1, at => time() }, 'never');

    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    my ($bin, $ver) = Plugins::SpotOn::Soloist::get();
    is($ver, '1.3.8.79', "Case 11d: get() reports the newer live version 1.3.8.79 (real --version banner)");
    ok(!Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expired'),
        "Case 11d: a genuinely different version clears the park flag");
}

# ============================================================
# Phase 83.3 plan 08 (D-01/D-03 gap 2, WR-01), Task 2: side-effect-free
# read accessors -- activeVersion()/installedBinaryPath() never call the
# activating get(), never touch $binary/$version, never write the cache.
# ============================================================

# Case 12a: a still-parked, still-activatable binary -- activeVersion()
# reports its version WITHOUT activating it (the flag survives; a following
# installedBinaryPath() still resolves the canonical path).
{
    reset_env();
    seed_active_binary('1.3.8.68');
    my $mtime = (stat(canonical_bin()))[9];
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expired',
        { version => '1.3.8.68', mtime => $mtime, at => time() }, 'never');

    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    is(Plugins::SpotOn::Soloist::activeVersion(), '1.3.8.68',
        "Case 12a: activeVersion() reports the parked binary's version");
    ok(Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_expired'),
        "Case 12a: activeVersion() alone never touches the park flag (no activation)");
    is(Plugins::SpotOn::Soloist::installedBinaryPath(), canonical_bin(),
        "Case 12a: installedBinaryPath() still resolves the canonical path");
}

# Case 12b: a below-pin binary -- activeVersion() and get() agree it is not
# activatable (both undef) -- same "activatable" semantics either way.
{
    reset_env();
    seed_active_binary('1.3.8.1');

    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);

    is(Plugins::SpotOn::Soloist::activeVersion(), undef,
        "Case 12b: activeVersion() returns undef for a below-pin binary");
    my (undef, $ver) = Plugins::SpotOn::Soloist::get();
    is($ver, undef, "Case 12b: get() also returns undef for the same below-pin binary");
}

done_testing();
