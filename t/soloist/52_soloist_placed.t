#!/usr/bin/perl
# Phase 83.3 plan 05 (D-08/D-09/D-10/D-11): behavioral coverage for the
# placed-binary fallback -- a fixed folder scanned by the watchdog,
# evaluated with exactly the renewal pipeline minus the download (extract
# -> version >= pin -> smoke test -> promote), priority over CDN renewal
# while valid, treated as absent when invalid or expired, and the shared
# lifecycleInFlight guard with the renewal engine. Mirrors t/49's harness
# (LMS module stubs, stateful Cache stub, SoloistDaemon smoke stub,
# DaemonManager stub) plus real tar/symlink fixtures under a real cachedir
# tempdir (t/26 pattern).
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
    die "system tar not available -- required for the placed-binary pipeline tests (84-09: die, never skip)\n";
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
# LMS module stubs (mirrors t/49_soloist_renewal.t)
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

# Timers stub -- needed because renewBinary() (exercised by cases 8/10/11)
# unconditionally registers a hard-timeout timer.
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

# SimpleAsyncHTTP stub -- Soloist.pm `use`s this unconditionally at the top
# level; renewBinary() (cases 8/10/11) issues a download through it. The
# placed-binary path itself never touches this (no network step). 83.3
# plan 12 (D-10, Case 16): 'success' mode ported verbatim from
# t/49_soloist_renewal.t :210-249 -- builds a REAL tar.gz fixture archive
# (a fake soloist script reporting $candidate_version) at the saveAs path
# before invoking cb, so the CDN half of Case 16 exercises a real
# extract/version-probe/smoke/promote pipeline, not a mock.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @created = ();
our $auto_mode = 'none';    # none | success | error
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
        $self->{ecb}->($self, 'simulated network error');
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
# $SMOKE_INFO. Records every path it was invoked with (call-count assertions
# below rely on this to prove the signature short-circuit / rejection
# ordering never re-runs a smoke test unnecessarily).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::SoloistDaemon', <<'END');
package Plugins::SpotOn::Unified::SoloistDaemon;
our @SMOKE_CALLS;
our $SMOKE_OK   = 1;
our $SMOKE_INFO = { days => 89, version => '1.3.8.70' };
sub smokeTest {
    my ($class, $path, $cb) = @_;
    push @SMOKE_CALLS, $path;
    $cb->($SMOKE_OK, $SMOKE_INFO);
}
sub reset_calls { @SMOKE_CALLS = (); }
1;
END

# DaemonManager stub -- counts onSoloistBinaryReplaced calls (_promoteCandidate
# notifies it on every successful promotion, placed or CDN).
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

# Writes an executable shell-script "soloist" binary (t/26/t/49 pattern).
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

# Builds a REAL tar.gz archive (flat, one 'soloist' member) at $archivePath.
sub build_archive {
    my ($archivePath, $version) = @_;
    my $srcDir = tempdir(CLEANUP => 1);
    write_fake_binary("$srcDir/soloist", $version);
    system('tar', 'czf', $archivePath, '-C', $srcDir, 'soloist');
}

sub reset_env {
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    Slim::Utils::Cache::reset_store();
    Slim::Utils::Timers::reset_timers();
    Plugins::SpotOn::Unified::SoloistDaemon::reset_calls();
    Plugins::SpotOn::Unified::DaemonManager::reset_calls();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    # A prior case's renewBinary('started') call (auto_mode 'none') never
    # got its download callback drained -- the shared lifecycleInFlight
    # guard is a package-level Perl variable, not cache state, so it must
    # be reset here explicitly or it leaks across cases.
    Plugins::SpotOn::Soloist::_setLifecycleInFlight(undef);
    preferences('plugin.spoton')->set('backend', 'soloist-' . $reset_counter++);

    my $spotonDir = catdir($cache_dir, 'spoton');
    remove_tree($spotonDir) if -d $spotonDir;

    # checkPlacedBinary()/renewBinary() both gate on backend eq 'soloist'.
    preferences('plugin.spoton')->set('backend', 'soloist');
}

sub bin_dir       { return catdir($cache_dir, 'spoton', 'soloist', 'x86_64-linux'); }
sub canonical_bin { return catfile(bin_dir(), 'soloist'); }
sub previous_bin  { return catfile(bin_dir(), 'previous', 'soloist'); }
sub manual_dir    { return catdir($cache_dir, 'spoton', 'soloist', 'manual'); }
sub staging_manual_dir { return catdir(bin_dir(), 'staging-manual'); }

sub seed_active_binary {
    my ($version) = @_;
    make_path(bin_dir());
    write_fake_binary(canonical_bin(), $version);
}

sub empty_manual_dir {
    remove_tree(manual_dir()) if -d manual_dir();
}

# ============================================================
# Case 1: empty folder -- absent, folder created 0700
# ============================================================
{
    reset_env();
    ok(!-d manual_dir(), "Case 1 setup: manual dir does not exist yet");

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'absent', "Case 1: checkPlacedBinary returns 'absent' for an empty/missing folder");
    ok(-d manual_dir(), "Case 1: manual dir now exists");
    my @stat = stat(manual_dir());
    is($stat[2] & 07777, 0700, "Case 1: manual dir mode is 0700");
}

# ============================================================
# Case 2: real archive -> started; smoke ok days 80; promoted; previous
# holds the old binary; placed state active; generation reason placed;
# onSoloistBinaryReplaced count 1; staging-manual removed; archive stays.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 80, version => '1.3.8.70' };

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 2: checkPlacedBinary returns 'started'");

    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.70',
        "Case 2: canonical soloist reports the new placed version 1.3.8.70");
    is(Plugins::SpotOn::Soloist::_versionProbe(previous_bin()), '1.3.8.68',
        "Case 2: previous/soloist reports the old (CDN) version 1.3.8.68");

    my $state = Plugins::SpotOn::Soloist::placedState();
    is($state->{status}, 'active', "Case 2: placedState status is 'active'");
    is($state->{version}, '1.3.8.70', "Case 2: placedState version is 1.3.8.70");
    ok(defined $state->{signature} && length($state->{signature}), "Case 2: placedState has a signature");

    my $gen = Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_generation');
    is($gen->{reason}, 'placed', "Case 2: generation record reason is 'placed'");

    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::REPLACED_CALLS), 1,
        "Case 2: onSoloistBinaryReplaced called exactly once");

    ok(!-d staging_manual_dir(), "Case 2: staging-manual dir removed after promotion");
    ok(-f $archivePath, "Case 2: the archive itself is still in the manual folder (copied, not moved)");

    ok(Plugins::SpotOn::Soloist::_placedBinaryIsValid(), "Case 2: _placedBinaryIsValid() is true");
}

# ============================================================
# Case 3: same file again -- signature short-circuit, no re-smoke-test.
# ============================================================
{
    my $callsBefore = scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS);
    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'active', "Case 3: unchanged file -- checkPlacedBinary returns the cached status 'active'");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), $callsBefore,
        "Case 3: smokeTest call count unchanged (signature short-circuit, T-83.3-23)");
}

# ============================================================
# Case 4: bare 'soloist' script (after emptying the folder) -- promoted,
# the file in the folder untouched (copied, not moved).
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    empty_manual_dir();
    make_path(manual_dir());
    my $bareBinary = catfile(manual_dir(), 'soloist');
    write_fake_binary($bareBinary, '1.3.8.71');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 85, version => '1.3.8.71' };

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 4: bare binary -- checkPlacedBinary returns 'started'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.71',
        "Case 4: canonical now reports the placed bare-binary version 1.3.8.71");
    ok(-f $bareBinary, "Case 4: the file in the manual folder is untouched (copied, not moved)");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active', "Case 4: placedState is 'active'");
}

# ============================================================
# Case 5: a symlink named 'soloist' pointing outside the folder -- ignored
# (absent), nothing promoted.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    empty_manual_dir();
    make_path(manual_dir());

    # A real, valid Soloist-reporting binary living OUTSIDE the manual
    # folder (T-83.3-21: a symlink escape target).
    my $outsideDir = tempdir(CLEANUP => 1);
    my $outsideBinary = catfile($outsideDir, 'soloist');
    write_fake_binary($outsideBinary, '1.3.8.72');

    my $symlinkPath = catfile(manual_dir(), 'soloist');
    symlink($outsideBinary, $symlinkPath) or die "symlink failed: $!";
    ok(-l $symlinkPath, "Case 5 setup: the manual-dir entry is a symlink");

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'absent', "Case 5: a symlinked 'soloist' entry is ignored -- checkPlacedBinary returns 'absent'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68',
        "Case 5: canonical unchanged (nothing promoted)");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), 0,
        "Case 5: smokeTest never called for a symlink candidate");

    # NOTE on the MUST-FAIL mechanism (verified by hand during authoring,
    # documented rather than smoothed over -- same discipline as 83.3-03's
    # SUMMARY Case 6 discrepancy): temporarily commenting out this file's
    # `next if -l $full;` line does NOT by itself turn the assertions above
    # red for a symlink resolving OUTSIDE the folder -- realpath($full)
    # still resolves to $outsideBinary, which fails the containment check
    # (_pathIsWithin) on its own, so a SECOND, independent guard already
    # excludes it. Case 5b below isolates the `-l` exclusion's own unique
    # contribution: a symlink resolving INSIDE the folder, where containment
    # alone would otherwise accept it.
}

# ============================================================
# Case 5b: a symlink named 'soloist' resolving INSIDE the folder -- still
# ignored. Unlike Case 5 (where containment alone already excludes an
# outside target), THIS scenario isolates the `-l` exclusion as the ONLY
# guard standing between "ignored" and "promoted" (containment passes,
# since the resolved target lives inside manual_dir() too).
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    empty_manual_dir();
    make_path(manual_dir());

    my $insideBinary = catfile(manual_dir(), 'soloist-real');
    write_fake_binary($insideBinary, '1.3.8.73');

    my $symlinkPath = catfile(manual_dir(), 'soloist');
    symlink($insideBinary, $symlinkPath) or die "symlink failed: $!";

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'absent', "Case 5b: a symlink resolving INSIDE the folder is still ignored (the -l guard, not containment, excludes it)");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 5b: canonical unchanged");

    # MUST-FAIL dry run (verified by hand, reverted immediately): commenting
    # out `next if -l $full;` in _scanManualDir turns BOTH assertions above
    # `not ok` -- containment passes for this target (it resolves inside
    # manual_dir()), so only the `-l` exclusion was standing in the way; with
    # it removed the symlink is accepted as a binary candidate, smoke-tested,
    # and promoted, changing 'absent' to 'started' and the canonical version
    # to 1.3.8.73:
    #   not ok - Case 5b: a symlink resolving INSIDE the folder is still ignored (the -l guard, not containment, excludes it)
    #   not ok - Case 5b: canonical unchanged
    # Reverted immediately; `prove t/52_soloist_placed.t` green again on the
    # restored code.
}

# ============================================================
# Case 6: candidate below the pinned minimum -- rejected, canonical
# unchanged.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    empty_manual_dir();
    make_path(manual_dir());
    write_fake_binary(catfile(manual_dir(), 'soloist'), '1.3.8.1');

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 6: checkPlacedBinary returns 'started'");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'rejected', "Case 6: placedState status is 'rejected'");
    is(Plugins::SpotOn::Soloist::placedState()->{reason}, 'below_minimum', "Case 6: reason is 'below_minimum'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 6: canonical unchanged");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), 0, "Case 6: smokeTest never called");
}

# ============================================================
# Case 7: smoke test fails -- rejected with the smoke stub's own reason.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    empty_manual_dir();
    make_path(manual_dir());
    write_fake_binary(catfile(manual_dir(), 'soloist'), '1.3.8.71');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 0;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { reason => 'no_expiry_line' };

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 7: checkPlacedBinary returns 'started'");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'rejected', "Case 7: placedState status is 'rejected'");
    is(Plugins::SpotOn::Soloist::placedState()->{reason}, 'no_expiry_line', "Case 7: reason is 'no_expiry_line'");
    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68', "Case 7: canonical unchanged");
}

# ============================================================
# Case 8: a valid placed binary blocks renewBinary() for EVERY reason
# (D-09), including manual.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 80, version => '1.3.8.70' };
    Plugins::SpotOn::Soloist::checkPlacedBinary();
    ok(Plugins::SpotOn::Soloist::_placedBinaryIsValid(), "Case 8 setup: placed binary is valid (days 80)");

    my $r1 = Plugins::SpotOn::Soloist::renewBinary(reason => 'expiry');
    is($r1, 'blocked:placed_binary_active', "Case 8: renewBinary(reason => 'expiry') is blocked (D-09)");

    my $r2 = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r2, 'blocked:placed_binary_active', "Case 8: renewBinary(reason => 'manual') is ALSO blocked (D-09 -- all reasons)");

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 0, "Case 8: no download was ever attempted");
}

# ============================================================
# Case 9 (repaired 83.3-10): the placed binary's own remaining lifetime
# runs out -- checkRenewalDue() flips it to 'expired' and lets renewal
# through. The original setup smoke-tested a 1-day candidate directly into
# 'active'; Task 1's 83.3-10 fix now REJECTS a candidate that low AT
# EVALUATION (Case 13), so this case seeds via an 80-day promotion instead
# and ages the reading past 0 -- the <= 0 wording and flow are unchanged.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 80, version => '1.3.8.70' };
    Plugins::SpotOn::Soloist::checkPlacedBinary();
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active', "Case 9 setup: placed binary is active (80 days left)");

    # Age the expiry reading past 0 without a real wait (WR-10 arithmetic).
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days',
        { days => 80, checked_at => time() - 81 * 86400 }, 'never');    # 80 - 81 elapsed -> adjusted <= 0

    my @renew_calls;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my %opts = @_;
        push @renew_calls, \%opts;
        return 'started';
    };

    my $due = Plugins::SpotOn::Soloist::checkRenewalDue();
    my $state9 = Plugins::SpotOn::Soloist::placedState();
    is($state9->{status}, 'expired', "Case 9: checkRenewalDue() flips the placed state to 'expired' (D-10)");
    is($state9->{reason}, 'expired', "Case 9: reason is 'expired' at <= 0 days (unchanged wording)");
    is($due, 'started', "Case 9: checkRenewalDue() reaches the renewal recorder once the placed binary is expired");
    is(scalar(@renew_calls), 1, "Case 9: exactly one renewBinary call recorded");
}

# Case 9b (84-12 Task 2): the watchdog tick's placed-binary + renewal-due pair
# now runs inside the Soloist role (Backend::Soloist->onInitHelpers, called by
# DaemonManager::initHelpers through backendClass()). One call = one tick:
# the placed check FIRST (D-09: a valid placed binary must block a renewal
# decided in the same pass), then the renewal check, each exactly once.
{
    reset_env();
    seed_active_binary('1.3.8.68');

    require Plugins::SpotOn::Backend::Soloist;
    my @order;
    my $origPlaced  = \&Plugins::SpotOn::Soloist::checkPlacedBinary;
    my $origRenewal = \&Plugins::SpotOn::Soloist::checkRenewalDue;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::checkPlacedBinary = sub { push @order, 'placed';  goto &$origPlaced; };
    local *Plugins::SpotOn::Soloist::checkRenewalDue   = sub { push @order, 'renewal'; goto &$origRenewal; };

    ok(eval { Plugins::SpotOn::Backend::Soloist->onInitHelpers; 1 }, "Case 9b (84-12): Backend::Soloist->onInitHelpers runs");
    is_deeply(\@order, [qw(placed renewal)],
        "Case 9b (84-12): one tick = placed-binary check then renewal-due, exactly once each");
}

# ============================================================
# Case 10: folder emptied -- absent, renewBinary(reason => 'manual')
# returns 'started' again (D-10: an absent placed binary never blocks).
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    empty_manual_dir();

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'absent', "Case 10: emptied folder -- checkPlacedBinary returns 'absent'");
    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(), "Case 10: _placedBinaryIsValid() is false");

    my $r2 = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r2, 'started', "Case 10: renewBinary(reason => 'manual') returns 'started' (no placed binary blocking)");
}

# ============================================================
# Case 11: rollbackToPrevious() after a placed promotion -- placed state
# flips to rejected/rolled_back, _placedBinaryIsValid() false, renewal
# unblocked, and the SAME unchanged file is not re-evaluated (signature
# short-circuit returns 'rejected' without a smoke test).
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days', { days => 80, checked_at => time() }, 'never');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 89, version => '1.3.8.70' };
    Plugins::SpotOn::Soloist::checkPlacedBinary();
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active', "Case 11 setup: placed binary promoted and active");

    my ($ok, $detail) = Plugins::SpotOn::Soloist::rollbackToPrevious(reason => 't');
    is($ok, 1, "Case 11: rollbackToPrevious returns true");
    is($detail, '1.3.8.68', "Case 11: rolled back to the previous (CDN) version 1.3.8.68");

    my $state = Plugins::SpotOn::Soloist::placedState();
    is($state->{status}, 'rejected', "Case 11: placedState status is 'rejected' after the rollback");
    is($state->{reason}, 'rolled_back', "Case 11: placedState reason is 'rolled_back'");
    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(), "Case 11: _placedBinaryIsValid() is false after rollback");

    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'expiry');
    ok($r ne 'blocked:placed_binary_active', "Case 11: renewBinary(reason => 'expiry') is no longer blocked");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 1, "Case 11: a real renewal download was issued");
    # Drain it so it doesn't leak into a later test.
    my $http = $Slim::Networking::SimpleAsyncHTTP::created[-1];
    $http->{ecb}->($http, 'test cleanup');

    my $callsBefore = scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS);
    my $r2 = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r2, 'rejected', "Case 11: checkPlacedBinary on the SAME unchanged file returns 'rejected' (signature short-circuit)");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), $callsBefore,
        "Case 11: no new smoke test for the unchanged, already-rejected file");
}

# ============================================================
# Case 12: guard sharing -- lifecycleInFlight is the SAME flag for both
# paths; no second in-flight guard exists.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');

    Plugins::SpotOn::Soloist::_setLifecycleInFlight('renewal');
    is(Plugins::SpotOn::Soloist::checkPlacedBinary(), 'in_flight',
        "Case 12: checkPlacedBinary returns 'in_flight' while a renewal holds the shared guard");

    Plugins::SpotOn::Soloist::_setLifecycleInFlight('placed');
    is(Plugins::SpotOn::Soloist::renewBinary(reason => 'manual'), 'busy',
        "Case 12: renewBinary returns 'busy' while a placed-binary check holds the shared guard");

    Plugins::SpotOn::Soloist::_setLifecycleInFlight(undef);
    isnt(Plugins::SpotOn::Soloist::checkPlacedBinary(), 'in_flight',
        "Case 12: checkPlacedBinary proceeds once the guard is cleared");
    is(Plugins::SpotOn::Soloist::lifecycleInFlight(), undef,
        "Case 12: guard cleared again after the (empty-folder) placed check completes");

    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($r, 'started', "Case 12: renewBinary proceeds once the guard is cleared");
    my $http = $Slim::Networking::SimpleAsyncHTTP::created[-1];
    $http->{ecb}->($http, 'test cleanup');    # drain, don't leak
}

# ============================================================
# Case 13a (83.3-10, WR-04 placed-path, D-10): a placed candidate whose
# smoke test reports <= RENEWAL_TRIGGER_DAYS (14) remaining days is
# rejected at evaluation, never promoted, does not block renewal, and is
# not re-evaluated on the unchanged file. Synthetic days value -- no
# archived capture of a <= 14-day build exists (see Case 13b below for the
# real-material passing control).
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 3, version => '1.3.8.70' };

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 13a: checkPlacedBinary returns 'started'");

    my $state = Plugins::SpotOn::Soloist::placedState();
    is($state->{status}, 'rejected', "Case 13a: status rejected");
    is($state->{reason}, 'expires_soon:3', "Case 13a: reason is 'expires_soon:3'");

    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.68',
        "Case 13a: canonical unchanged (nothing promoted)");
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::REPLACED_CALLS), 0,
        "Case 13a: onSoloistBinaryReplaced never called");
    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(), "Case 13a: _placedBinaryIsValid() is 0");

    my $r2 = Plugins::SpotOn::Soloist::renewBinary(reason => 'expiry');
    ok($r2 ne 'blocked:placed_binary_active',
        "Case 13a: renewBinary(reason => 'expiry') is not blocked by the rejected placed binary");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 1,
        "Case 13a: renewal recorder reached (a real renewal download was issued)");
    my $http = $Slim::Networking::SimpleAsyncHTTP::created[-1];
    $http->{ecb}->($http, 'test cleanup');    # drain, don't leak

    my $callsBefore = scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS);
    my $r3 = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r3, 'rejected', "Case 13a: second check on the unchanged file returns the cached 'rejected' status");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), $callsBefore,
        "Case 13a: no new smoke test for the unchanged, already-rejected file");
}

# ============================================================
# Case 13b (real-material control): the manual folder emptied and refilled
# with a bare 'soloist' script whose --version banner is the VERBATIM live
# banner captured in 83.3-LIVE-CHECKS.md:20 (commit g5c3a2053ac) and a real
# smoke days value of 89 (83.3-LIVE-CHECKS.md:21) -- the real, passing
# control for Case 13a's synthetic rejection above.
# ============================================================
{
    empty_manual_dir();
    make_path(manual_dir());
    my $liveBinary = catfile(manual_dir(), 'soloist');
    open(my $fh, '>', $liveBinary) or die "Case 13b: cannot write live binary fixture: $!";
    print $fh "#!/bin/sh\n";
    print $fh "if [ \"\$1\" = '--version' ]; then\n";
    print $fh "  echo 'soloist 1.3.8.79 build 1790380866 (20260926) (g5c3a2053ac) (linux/x86_64)'\n";
    print $fh "  exit 0\n";
    print $fh "fi\n";
    print $fh "exit 1\n";
    close($fh);
    chmod(0755, $liveBinary);

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 89, version => '1.3.8.79' };

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 13b: checkPlacedBinary returns 'started'");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 13b: the real 89-day live build (verbatim banner, commit g5c3a2053ac) is promoted and active -- passing control");
}

# ============================================================
# Case 14 (83.3-10, boundary at evaluation): days == RENEWAL_TRIGGER_DAYS
# (14) is rejected; a fresh candidate (different content -> different
# signature) with days == 15 (one past the boundary) is promoted/active.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 14, version => '1.3.8.70' };

    my $r = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r, 'started', "Case 14: checkPlacedBinary returns 'started' (14 days)");
    my $state14a = Plugins::SpotOn::Soloist::placedState();
    is($state14a->{status}, 'rejected', "Case 14: 14 days remaining -- boundary is rejected");
    is($state14a->{reason}, 'expires_soon:14', "Case 14: reason is 'expires_soon:14'");

    # A different candidate (a differently-NAMED archive -- a same-second
    # rebuild of this trivial fixture can produce an identical size/mtime
    # for the old filename, which would leave the signature unchanged and
    # falsely short-circuit; a distinct filename guarantees a distinct
    # signature) with one more day (15) must be promoted.
    empty_manual_dir();
    make_path(manual_dir());
    my $archivePath2 = catfile(manual_dir(), 'soloist_release_x86_64_v2.tar.gz');
    build_archive($archivePath2, '1.3.8.71');
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 15, version => '1.3.8.71' };

    my $r2 = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r2, 'started', "Case 14: checkPlacedBinary returns 'started' (15 days)");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 14: 15 days remaining -- one past the boundary is active");
}

# ============================================================
# Case 15 (rewritten 83.3-12, D-10/WR-04, gap-closure round 2): an
# ALREADY-ACTIVE placed binary whose wall-clock-adjusted remaining days
# fall to <= RENEWAL_TRIGGER_DAYS (13) stays 'active' through a watchdog
# tick (checkRenewalDue) -- the plan-10 tick-time flip to
# rejected/expires_soon:<N> is gone (that collapsed the settings-hint
# window to a single tick and mislabeled the running, installed build as
# "ignored"). _placedBinaryIsValid() is already 0 BEFORE the tick fires
# (the manual button must not be blocked either -- unchanged from plan 10),
# a recorded renewal reaches the recorder exactly once with reason
# 'expiry', and a subsequent checkPlacedBinary() on the unchanged file
# short-circuits to the (still active) cached status with no new smoke
# call.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 80, version => '1.3.8.70' };
    Plugins::SpotOn::Soloist::checkPlacedBinary();
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 15 setup: placed binary promoted and active (80 days)");

    # Age the reading: 80 - 67 elapsed days -> adjusted 13 (<= threshold, > 0).
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days',
        { days => 80, checked_at => time() - 67 * 86400 }, 'never');
    is(Plugins::SpotOn::Soloist::expiryDaysRemaining(), 13,
        "Case 15 setup: expiryDaysRemaining() adjusted to 13");

    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(),
        "Case 15: _placedBinaryIsValid() is 0 BEFORE the tick (13 days <= threshold) -- the manual button must not be blocked");

    my @renew_calls;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my %opts = @_;
        push @renew_calls, \%opts;
        return 'started';
    };

    my $due = Plugins::SpotOn::Soloist::checkRenewalDue();
    my $state15 = Plugins::SpotOn::Soloist::placedState();
    is($state15->{status}, 'active',
        "Case 15: checkRenewalDue() leaves the placed state 'active' (D-10 two-stage rule -- no tick-time flip in 1..RENEWAL_TRIGGER_DAYS)");
    ok(!defined $state15->{reason}, "Case 15: reason is still not defined after the tick");
    is($due, 'started', "Case 15: checkRenewalDue() reaches the renewal recorder");
    is(scalar(@renew_calls), 1, "Case 15: exactly one renewBinary call recorded");
    is($renew_calls[0]{reason}, 'expiry', "Case 15: recorded call reason is 'expiry'");

    # Settings' soloistExpiryHint inputs: both true -- the warning renders
    # for the whole window, not just one tick.
    ok(Plugins::SpotOn::Soloist::expiryDaysRemaining() <= 14,
        "Case 15: hint input 1 (days <= 14) is true");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 15: hint input 2 (status active) is true");

    my $callsBefore = scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS);
    my $r2 = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r2, 'active', "Case 15: a subsequent checkPlacedBinary() on the unchanged file returns the cached 'active' status");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), $callsBefore,
        "Case 15: no new smoke call for the unchanged file");
}

# ============================================================
# Case 17 (83.3-12, D-10/WR-04 boundary, gap-closure round 2): the SAME
# constant (RENEWAL_TRIGGER_DAYS = 14) gates both Settings' warning window
# and _placedBinaryIsValid()'s renewal-unblock threshold, so the two
# windows coincide exactly. At 15 days (one past the boundary): the placed
# binary is valid, D-09 blocks a real manual renewBinary() for ALL reasons,
# and checkRenewalDue() itself is 'not_due' (D-01 not triggered -- days is
# above the trigger). At 14 days (the boundary itself): the placed binary
# is no longer valid, checkRenewalDue() reaches the recorder, and the
# status stays 'active' throughout (D-10 first stage).
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 80, version => '1.3.8.70' };
    Plugins::SpotOn::Soloist::checkPlacedBinary();
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 17 setup: placed binary promoted and active (80 days)");

    # --- 15-day half: one past the boundary -- still valid, still blocks. ---
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days',
        { days => 80, checked_at => time() - 65 * 86400 }, 'never');
    is(Plugins::SpotOn::Soloist::expiryDaysRemaining(), 15,
        "Case 17 setup: expiryDaysRemaining() adjusted to 15");

    ok(Plugins::SpotOn::Soloist::_placedBinaryIsValid(),
        "Case 17: _placedBinaryIsValid() is 1 at 15 days (one past the boundary)");

    my $dueAt15 = Plugins::SpotOn::Soloist::checkRenewalDue();
    is($dueAt15, 'not_due', "Case 17: checkRenewalDue() is 'not_due' at 15 days (15 > RENEWAL_TRIGGER_DAYS, D-01 not triggered)");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active', "Case 17: status still 'active' at 15 days");

    my $createdBefore15 = scalar(@Slim::Networking::SimpleAsyncHTTP::created);
    my $rManual15 = Plugins::SpotOn::Soloist::renewBinary(reason => 'manual');
    is($rManual15, 'blocked:placed_binary_active',
        "Case 17: a real manual renewBinary() is blocked at 15 days (D-09: a valid placed binary rests renewal for ALL reasons)");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), $createdBefore15,
        "Case 17: no download was issued for the blocked manual renewal at 15 days");

    ok(Plugins::SpotOn::Soloist::expiryDaysRemaining() <= 14 ? 0 : 1,
        "Case 17: Settings hint input 1 (days <= 14) is false at 15 days -- no hint");

    # --- 14-day half: the boundary itself -- no longer valid, renewal reached. ---
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days',
        { days => 80, checked_at => time() - 66 * 86400 }, 'never');
    is(Plugins::SpotOn::Soloist::expiryDaysRemaining(), 14,
        "Case 17 setup: expiryDaysRemaining() adjusted to 14 (the boundary)");

    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(),
        "Case 17: _placedBinaryIsValid() is 0 at 14 days (the boundary itself)");

    my @renew_calls17;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my %opts = @_;
        push @renew_calls17, \%opts;
        return 'started';
    };

    my $dueAt14 = Plugins::SpotOn::Soloist::checkRenewalDue();
    is($dueAt14, 'started', "Case 17: checkRenewalDue() reaches the renewal recorder at 14 days");
    is(scalar(@renew_calls17), 1, "Case 17: exactly one renewBinary call recorded at 14 days");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 17: status still 'active' at 14 days (D-10 first stage: renewal reached, status unflipped)");

    ok(Plugins::SpotOn::Soloist::expiryDaysRemaining() <= 14,
        "Case 17: Settings hint input 1 (days <= 14) is true at 14 days -- hint renders");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 17: Settings hint input 2 (status active) is true at 14 days");
}

# ============================================================
# Case 16 (83.3-12, D-10/WR-04 tracer, gap-closure round): an
# ALREADY-ACTIVE placed binary at 10 days stays active through a watchdog
# tick (the two-stage rule -- no tick-time state flip in 1..
# RENEWAL_TRIGGER_DAYS), Settings' soloistExpiryHint inputs
# (expiryDaysRemaining() <= 14 AND placedStatus eq 'active') both true both
# before and after the tick (no TT-render harness exists in this repo, so
# the hint is asserted through its two literal inputs), while a REAL CDN
# renewal runs underneath via _placedBinaryIsValid()'s own threshold (not a
# status change) and, once it promotes 1.3.8.71 through the SimpleAsyncHTTP
# stub's 'success' mode, the placed state flips to rejected/
# superseded:1.3.8.71 -- Settings must never claim a placed binary is
# active while the CDN build is the installed one.
# ============================================================
{
    reset_env();
    seed_active_binary('1.3.8.68');
    make_path(manual_dir());
    my $archivePath = catfile(manual_dir(), 'soloist_release_x86_64.tar.gz');
    build_archive($archivePath, '1.3.8.70');

    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_OK   = 1;
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO = { days => 80, version => '1.3.8.70' };
    Plugins::SpotOn::Soloist::checkPlacedBinary();
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 16 setup: placed binary promoted and active (80 days)");

    # Age the reading: 80 - 70 elapsed days -> adjusted 10.
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days',
        { days => 80, checked_at => time() - 70 * 86400 }, 'never');
    is(Plugins::SpotOn::Soloist::expiryDaysRemaining(), 10,
        "Case 16 setup: expiryDaysRemaining() adjusted to 10");

    # Settings' soloistExpiryHint inputs BEFORE the tick.
    ok(Plugins::SpotOn::Soloist::expiryDaysRemaining() <= 14,
        "Case 16: hint input 1 (days <= 14) is true BEFORE the tick");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 16: hint input 2 (status active) is true BEFORE the tick");

    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(),
        "Case 16: _placedBinaryIsValid() is 0 at 10 days (unchanged plan-10 threshold; renewal is un-blocked without any status flip)");

    # First sub-step: a recorded (non-real) renewal tick -- proves the tick
    # itself does not flip the placed state, scoped to this inner block so
    # the real renewBinary is restored immediately afterward for the CDN
    # half below.
    {
        my @renew_calls;
        no warnings 'redefine', 'once';
        local *Plugins::SpotOn::Soloist::renewBinary = sub {
            my %opts = @_;
            push @renew_calls, \%opts;
            return 'started';
        };

        my $due = Plugins::SpotOn::Soloist::checkRenewalDue();
        is($due, 'started', "Case 16: checkRenewalDue() reaches the renewal recorder (10 days, reason expiry)");
        is(scalar(@renew_calls), 1, "Case 16: exactly one renewBinary call recorded");
        is($renew_calls[0]{reason}, 'expiry', "Case 16: recorded call reason is 'expiry'");
    }

    my $stateAfterTick = Plugins::SpotOn::Soloist::placedState();
    is($stateAfterTick->{status}, 'active',
        "Case 16: placed state is STILL 'active' after the tick (D-10 two-stage rule -- no flip in 1..RENEWAL_TRIGGER_DAYS)");
    ok(!defined $stateAfterTick->{reason}, "Case 16: reason is still not defined after the tick");

    # Settings' soloistExpiryHint inputs AFTER the tick -- unchanged from
    # before it (the whole point of the two-stage rule).
    ok(Plugins::SpotOn::Soloist::expiryDaysRemaining() <= 14,
        "Case 16: hint input 1 (days <= 14) is still true AFTER the tick");
    is(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 16: hint input 2 (status active) is still true AFTER the tick");

    # Second sub-step: a REAL CDN renewal, through the SimpleAsyncHTTP
    # stub's 'success' mode (ported from t/49), promoting 1.3.8.71.
    $Slim::Networking::SimpleAsyncHTTP::auto_mode         = 'success';
    $Slim::Networking::SimpleAsyncHTTP::candidate_version = '1.3.8.71';
    $Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_INFO  = { days => 89, version => '1.3.8.71' };
    Plugins::SpotOn::Soloist::_setRenewalState(last_attempt_at => 0);

    my $replacedBefore = scalar(@Plugins::SpotOn::Unified::DaemonManager::REPLACED_CALLS);
    my $due2 = Plugins::SpotOn::Soloist::checkRenewalDue();
    is($due2, 'started', "Case 16: the real CDN renewal starts (10 days, not blocked by the inactive-for-threshold placed binary)");

    is(Plugins::SpotOn::Soloist::_versionProbe(canonical_bin()), '1.3.8.71',
        "Case 16: canonical soloist reports the newly-promoted CDN version 1.3.8.71");
    is(Plugins::SpotOn::Soloist::_versionProbe(previous_bin()), '1.3.8.70',
        "Case 16: previous/soloist reports the superseded placed version 1.3.8.70");

    my $gen = Plugins::SpotOn::Soloist::_cache()->get('spoton_soloist_generation');
    is($gen->{reason}, 'expiry', "Case 16: generation record reason is 'expiry' (CDN renewal, not 'placed')");
    is($gen->{active_version}, '1.3.8.71', "Case 16: generation record active_version is 1.3.8.71");

    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::REPLACED_CALLS), $replacedBefore + 1,
        "Case 16: onSoloistBinaryReplaced called exactly once more for the CDN promotion");
    is(Plugins::SpotOn::Soloist::renewalState()->{phase}, 'done', "Case 16: renewalState phase is 'done'");
    is(Plugins::SpotOn::Soloist::expiryDaysRemaining(), 89, "Case 16: expiryDaysRemaining() now reports the new CDN build's 89 days");

    my $stateAfterPromotion = Plugins::SpotOn::Soloist::placedState();
    is($stateAfterPromotion->{status}, 'rejected',
        "Case 16: placed state flips to 'rejected' once the CDN build replaced it (D-10 second stage)");
    is($stateAfterPromotion->{reason}, 'superseded:1.3.8.71',
        "Case 16: reason is 'superseded:1.3.8.71'");
    ok(defined $stateAfterPromotion->{signature} && length($stateAfterPromotion->{signature}),
        "Case 16: placed state signature is still defined (merge, not reset)");
    is($stateAfterPromotion->{version}, '1.3.8.70',
        "Case 16: placed state version is still '1.3.8.70' (the superseded placed build, not the new CDN one)");

    ok(!Plugins::SpotOn::Soloist::_placedBinaryIsValid(),
        "Case 16: _placedBinaryIsValid() is 0 after the promotion");

    ok(!(Plugins::SpotOn::Soloist::expiryDaysRemaining() <= 14),
        "Case 16: Settings hint input 1 is now false (89 days)");
    isnt(Plugins::SpotOn::Soloist::placedState()->{status}, 'active',
        "Case 16: Settings hint input 2 is now false (status no longer active) -- soloistExpiryHint would be 0");

    # Unchanged file: signature short-circuit, no new smoke call.
    my $callsBefore16 = scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS);
    my $r16 = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r16, 'rejected', "Case 16: checkPlacedBinary() on the unchanged file returns the cached 'rejected' status");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_CALLS), $callsBefore16,
        "Case 16: no new smoke test for the unchanged, already-superseded file");

    # Emptying the folder afterwards -- full reset back to 'absent'.
    empty_manual_dir();
    my $r16b = Plugins::SpotOn::Soloist::checkPlacedBinary();
    is($r16b, 'absent', "Case 16: emptying the manual folder resets to 'absent'");
}

done_testing();
