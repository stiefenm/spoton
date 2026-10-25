#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
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

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);
my $base_dir  = tempdir(CLEANUP => 1);

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
# LMS Module Stubs required by Soloist.pm / SoloistDaemon.pm
# (mirrors t/26/t/27/t/28's harness)
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

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get { }
1;
END

my $stub_base_dir = $base_dir;
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<"END");
package Plugins::SpotOn::Plugin;
sub _pluginDataFor { return '$stub_base_dir' }
1;
END

# Needed for Plugins::SpotOn::Unified::SoloistDaemon (isolated require target
# below), which `use base qw(Slim::Utils::Accessor)`.
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
use Scalar::Util qw(weaken);
my %slot;
sub new { return bless [], shift }
sub mk_accessor {
    my ($class, $type, @names) = @_;
    no strict 'refs';
    for my $name (@names) {
        my $n = $slot{$class}{$name};
        if (!defined $n) {
            $n = keys %{ $slot{$class} };
            $slot{$class}{$name} = $n;
        }
        if ($type eq 'weak') {
            *{"${class}::${name}"} = sub {
                my $self = shift;
                if (@_) {
                    $self->[$n] = shift;
                    weaken($self->[$n]) if ref $self->[$n];
                }
                return $self->[$n];
            };
        }
        else {
            *{"${class}::${name}"} = sub {
                my $self = shift;
                $self->[$n] = shift if @_;
                return $self->[$n];
            };
        }
    }
}
1;
END

# 74b-04: minimal recording Cache stub, defined up front (a require that
# failed earlier in the run is never retried), used by the _parseExpiryDays
# offset-clamp cell.
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %SET;
sub new { bless {}, shift }
sub set { $SET{$_[1]} = $_[2] }
sub get { $SET{$_[1]} }
sub remove { delete $SET{$_[1]} }
1;
END

# WR-02 (82-12, 82-REVIEW.md, Fall C): @TIMERS bookkeeping added on top of
# the pre-existing no-op API (killTimers/setTimer still no-op for every
# EXISTING test here -- nothing reads @TIMERS elsewhere in this file) so
# the new "no orphaned timer" test can assert against the registry
# directly instead of only on "a new instance exists".
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @TIMERS;
sub setTimer {
    my ($obj, $when, $cb, @args) = @_;
    push @TIMERS, [$obj, $when, $cb, @args];
}
sub killTimers {
    my ($obj, $cb) = @_;
    @TIMERS = grep { !($_->[0] == $obj && $_->[2] == $cb) } @TIMERS;
}
# 260914-qn1 (Signature C, Fall d): fire_due($now) fires (and removes)
# every timer whose $when <= $now, in order -- identical shape to
# t/44_soloist_control.t:89-97.
sub fire_due {
    my ($now) = @_;
    my @due = grep { $_->[1] <= $now } @TIMERS;
    @TIMERS = grep { $_->[1] > $now } @TIMERS;
    for my $t (@due) {
        my ($obj, undef, $cb, @extra) = @$t;
        $cb->($obj, @extra);
    }
}
1;
END

# Task 1 (83.3-03, D-06): Slim::Networking::Select stub for the smoke test's
# event-driven pipe read -- records every addRead/removeRead call as
# ($fh, $cb) so a test can invoke the recorded callback directly (mirroring
# how the real LMS select() loop would call it once $fh becomes readable).
write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
our @ADD_READ_CALLS;
our @REMOVE_READ_CALLS;
sub addRead {
    my ($fh, $cb) = @_;
    push @ADD_READ_CALLS, [$fh, $cb];
}
sub removeRead {
    my ($fh) = @_;
    push @REMOVE_READ_CALLS, [$fh];
}
sub reset_calls { @ADD_READ_CALLS = (); @REMOVE_READ_CALLS = (); }
1;
END

# 260914-qn1 (Signature C, Fall d): errors[] recorder -- identical shape to
# t/44_soloist_control.t:275-303 (Control's own Status stub).
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our @RECORDED;
sub recordError {
    my $class = shift;
    push @RECORDED, [@_];
    shift @RECORDED while scalar @RECORDED > 30;
}
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;
    @RECORDED = grep {
        !(($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key)
    } @RECORDED;
}
sub hasError {
    my ($class, $module, $key) = @_;
    return 0 unless defined $key;
    return scalar grep {
        ($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key
    } @RECORDED;
}
1;
END

# Phase 74: Soloist.pm now `use`s JSON::XS::VersionOneAndTwo (auto-patch
# JSON parsing) -- stub it so `require Plugins::SpotOn::Soloist` still
# loads in this sandbox (delegates to JSON::PP, mirrors t/07/t/09/etc.).
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
}

unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Slim::Utils::OSDetect;
require Slim::Networking::SimpleAsyncHTTP;
require Plugins::SpotOn::Plugin;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist");

Plugins::SpotOn::Soloist::init();

# Force the arch path deterministically for the whole file.
$Slim::Utils::OSDetect::osArch = 'x86_64';

# ============================================================
# D-03 completion: the Phase-72 per-track launcher generator is retired --
# none of its symbols exist on the module anymore.
# ============================================================
{
    ok(!Plugins::SpotOn::Soloist->can('ensureLauncher'), "ensureLauncher() no longer exists (D-03 retirement)");
    ok(!Plugins::SpotOn::Soloist->can('_launcherScript'), "_launcherScript() no longer exists (D-03 retirement)");
    ok(!Plugins::SpotOn::Soloist->can('launcherPath'),    "launcherPath() no longer exists (D-03 retirement)");
    ok(!Plugins::SpotOn::Soloist->can('dataDir'),         "the Phase-72 shared dataDir() no longer exists (D-03 retirement)");
    ok(!Plugins::SpotOn::Soloist->can('isPaired'),         "the Phase-72 shared isPaired() no longer exists (D-03 retirement)");
}

# ============================================================
# Test: dataDirForClient() / cacheDirForClient() shapes (D-01/D-02) --
# mac cleaning (colons stripped) + players/<mac>/{data,cache} prefix.
# ============================================================
{
    my $dataDir = Plugins::SpotOn::Soloist::dataDirForClient('aa:bb:cc:dd:ee:ff');
    like($dataDir, qr{players/aabbccddeeff/data$}, "dataDirForClient() strips colons and nests under players/<mac>/data");

    my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient('aa:bb:cc:dd:ee:ff');
    like($cacheDir, qr{players/aabbccddeeff/cache$}, "cacheDirForClient() strips colons and nests under players/<mac>/cache");

    isnt($dataDir, $cacheDir, "data and cache dirs for the same player are distinct paths");

    my $dataDir2 = Plugins::SpotOn::Soloist::dataDirForClient('11:22:33:44:55:66');
    isnt($dataDir, $dataDir2, "different players get different data dirs");
}

# ============================================================
# Test: isPairedForClient() -- settings/Users/ non-empty (Phase 82, § S-10).
# Replaces the retired "any non-dot entry in the data dir" heuristic, which
# false-positived on a never-paired daemon's own startup artefacts.
# ============================================================
{
    is(Plugins::SpotOn::Soloist::isPairedForClient('aa:bb:cc:dd:ee:01'), 0,
        "isPairedForClient() is 0 when the per-player data dir does not exist");

    my $mac = 'aa:bb:cc:dd:ee:02';
    my $dir = Plugins::SpotOn::Soloist::dataDirForClient($mac);
    make_path($dir);

    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 0,
        "isPairedForClient() is 0 on an empty data dir");

    # S-10 false-positive case: only the daemon's own startup artefacts
    # exist (soloist.pid, ws.port, ws.addr, cache/, crashpad/) -- no
    # settings/ at all. The old heuristic (any non-dot entry) said 1 here;
    # the replacement must say 0.
    open(my $pidfh, '>', "$dir/soloist.pid") or die $!;
    print $pidfh '12345';
    close($pidfh);
    open(my $portfh, '>', "$dir/ws.port") or die $!;
    print $portfh '1234';
    close($portfh);
    open(my $addrfh, '>', "$dir/ws.addr") or die $!;
    print $addrfh '127.0.0.1';
    close($addrfh);
    make_path("$dir/cache", "$dir/crashpad");

    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 0,
        "isPairedForClient() is 0 when only daemon start artefacts exist (soloist.pid, ws.port, cache/, crashpad/) -- the S-10 false-positive case");

    make_path("$dir/settings/Users/testuser-user");
    open(my $prefsfh, '>', "$dir/settings/Users/testuser-user/prefs") or die $!;
    print $prefsfh 'core.clock_delta=0';
    close($prefsfh);

    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 1,
        "isPairedForClient() is 1 once settings/Users/<user>/prefs exists");

    my $mac2 = 'aa:bb:cc:dd:ee:03';
    my $dir2 = Plugins::SpotOn::Soloist::dataDirForClient($mac2);
    make_path("$dir2/settings/Users");

    is(Plugins::SpotOn::Soloist::isPairedForClient($mac2), 0,
        "isPairedForClient() is 0 when settings/Users exists but is empty");
}

# ============================================================
# Test: readKey() -- returns stored key content, undef when absent.
# ============================================================
{
    is(Plugins::SpotOn::Soloist::readKey(), undef, "readKey() returns undef when no spak-key is stored");

    my $KEY = 'spak_' . ('Z' x 40) . '_daemon_test_key';
    Plugins::SpotOn::Soloist->storeKey($KEY);

    is(Plugins::SpotOn::Soloist::readKey(), $KEY, "readKey() returns the stored spak-key content verbatim");

    Plugins::SpotOn::Soloist->clearKey();
    is(Plugins::SpotOn::Soloist::readKey(), undef, "readKey() returns undef again after clearKey()");
}

# ============================================================
# Test: Plugins::SpotOn::Unified::SoloistDaemon isolated-require + _spawnArgs()
# (D-05, T-73-01 -- hard-coded 127.0.0.1:0 WS bind, both per-player dirs)
# ============================================================
require_ok('Plugins::SpotOn::Unified::SoloistDaemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistDaemon");

{
    my $dataDir  = Plugins::SpotOn::Soloist::dataDirForClient('aa:bb:cc:dd:ee:ff');
    my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient('aa:bb:cc:dd:ee:ff');

    my @args = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', 'Living Room',
        $dataDir, $cacheDir, 40,
    );

    is_deeply(
        \@args,
        [ '/fake/soloist', '-n', 'Living Room', '-k', 'the-spak-key',
          '-D', $dataDir, '-C', $cacheDir, '-w', '127.0.0.1:0', '-i', 40 ],
        "_spawnArgs() builds the expected argv, carrying -w 127.0.0.1:0 and both per-player dirs (D-05)"
    );
}

# ============================================================
# Task 1 (83.2-01, D-03): _spawnArgs() optional 7th $verbose parameter --
# '-v' appended as the LAST element when the daemon runs with
# diagnosticMode on (D-03 measurement need, RESEARCH Sec 1: -v is a pure
# log-level switch, CHANGELOG-1.3.8.68.md's only CLI addition). Existing
# twelve-element ordering must stay unchanged so t/28 and the 6-arg case
# above keep passing.
# ============================================================
{
    my $dataDir  = Plugins::SpotOn::Soloist::dataDirForClient('aa:bb:cc:dd:ee:ff');
    my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient('aa:bb:cc:dd:ee:ff');

    my @args = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', 'Living Room',
        $dataDir, $cacheDir, 40, 1,
    );

    is_deeply(
        \@args,
        [ '/fake/soloist', '-n', 'Living Room', '-k', 'the-spak-key',
          '-D', $dataDir, '-C', $cacheDir, '-w', '127.0.0.1:0', '-i', 40, '-v' ],
        "_spawnArgs() with verbose=1 appends '-v' as the 14th and last element (D-03)"
    );
}

{
    my $dataDir  = Plugins::SpotOn::Soloist::dataDirForClient('aa:bb:cc:dd:ee:ff');
    my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient('aa:bb:cc:dd:ee:ff');

    my @args = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', 'Living Room',
        $dataDir, $cacheDir, 40, 0,
    );

    is_deeply(
        \@args,
        [ '/fake/soloist', '-n', 'Living Room', '-k', 'the-spak-key',
          '-D', $dataDir, '-C', $cacheDir, '-w', '127.0.0.1:0', '-i', 40 ],
        "_spawnArgs() with verbose=0 leaves the argv unchanged, no '-v' (D-03)"
    );
}

# ============================================================
# CR-S3 (Phase 77 Plan 02, RESEARCH Pitfall 4): first-ever coverage for
# _pollWsPort/_pollHttpPort. These two functions look structurally
# identical but diverge in failure semantics (WS calls stop() on
# exhaustion, HTTP does NOT -- WR-07 idle-daemon protection). These tests
# pin that divergence through the shared _pollPortScaffold() extraction.
#
# Instances are constructed directly via the stubbed Accessor::new (bless
# []) rather than SoloistDaemon->new(...), which would spawn a real
# process -- these tests exercise the poll functions in isolation.
# ============================================================

package Test::FakeDaemonProc;
sub new   { my ($class, $alive) = @_; return bless { alive => $alive }, $class; }
sub alive { return $_[0]->{alive}; }
sub die   { $_[0]->{alive} = 0; }

package main;

my $CRS3_MAX_ATTEMPTS = Plugins::SpotOn::Unified::SoloistDaemon::PORT_POLL_MAX_ATTEMPTS();

# Test 1: _pollWsPort exhausting max attempts with the process alive calls
# $self->stop() (failure semantics preserved).
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:10');
    $daemon->_proc(Test::FakeDaemonProc->new(1));
    $daemon->_wsPortPollAttempts(0);
    my $dataDir = tempdir(CLEANUP => 1);    # ws.port never written

    my $stopped = 0;
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::SoloistDaemon::stop = sub { $stopped++; };

    for (1 .. $CRS3_MAX_ATTEMPTS) {
        Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($daemon, $dataDir);
    }

    is($stopped, 1,
        "CR-S3: _pollWsPort exhausting max attempts with process alive calls stop() (failure semantics preserved)");
}

# Test 2: _pollHttpPort exhausting max attempts does NOT call stop() and
# leaves the daemon runnable (WR-07 idle-daemon protection preserved).
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:11');
    $daemon->_proc(Test::FakeDaemonProc->new(1));
    $daemon->_httpPortPollAttempts(0);

    my ($fh, $tmppath) = File::Temp::tempfile(UNLINK => 1);
    close($fh);    # empty file -- -s is false, port never "announced"
    $daemon->_httpPortTmpfile($tmppath);

    my $stopped = 0;
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::SoloistDaemon::stop = sub { $stopped++; };

    for (1 .. $CRS3_MAX_ATTEMPTS) {
        Plugins::SpotOn::Unified::SoloistDaemon::_pollHttpPort($daemon);
    }

    is($stopped, 0,
        "CR-S3: _pollHttpPort exhausting max attempts does NOT call stop() (WR-07 idle-daemon protection preserved)");
    ok(defined $daemon->_httpPortTmpfile,
        "CR-S3: exhausted HTTP-port poll leaves the tmpfile path intact -- daemon stays pollable on demand (WR-07)");
}

# Test 3: a port file appearing on attempt N (< max) resolves the poll
# successfully for both variants (scaffold reschedule-then-resolve works).

# -- HTTP variant --
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:12');
    $daemon->_proc(Test::FakeDaemonProc->new(1));
    $daemon->_httpPortPollAttempts(0);

    my ($fh, $tmppath) = File::Temp::tempfile(UNLINK => 1);
    close($fh);
    $daemon->_httpPortTmpfile($tmppath);

    Plugins::SpotOn::Unified::SoloistDaemon::_pollHttpPort($daemon);
    is($daemon->_streamPort, undef,
        "CR-S3: _pollHttpPort attempt 1 (no port yet) does not resolve");
    ok(defined $daemon->_httpPortTmpfile,
        "CR-S3: _pollHttpPort attempt 1 reschedules, tmpfile path untouched");

    open(my $wfh, '>', $tmppath) or die $!;
    print $wfh "54321\n";
    close($wfh);

    Plugins::SpotOn::Unified::SoloistDaemon::_pollHttpPort($daemon);
    is($daemon->_streamPort, 54321,
        "CR-S3: _pollHttpPort resolves once the port file is written (scaffold reschedule works)");
    is($daemon->_httpPortTmpfile, undef,
        "CR-S3: _pollHttpPort success unlinks-and-clears the tmpfile (WR-07)");
    ok(!-f $tmppath, "CR-S3: _pollHttpPort success unlinks the tmpfile from disk");
}

# -- WS variant -- (stubs Plugins::SpotOn::Unified::SoloistWS so the
# on_found success body's require/new/connect never touches a real socket;
# the stub shadows the real module because $stub_dir precedes $project_dir
# in @INC)
{
    write_stub($stub_dir, 'Plugins::SpotOn::Unified::SoloistWS', <<'END');
package Plugins::SpotOn::Unified::SoloistWS;
our @NEW_CALLS;
sub new {
    my ($class, %args) = @_;
    push @NEW_CALLS, \%args;
    return bless { %args, connect_called => 0 }, $class;
}
sub connect { $_[0]->{connect_called}++; return 1; }
# Phase 82 Plan 01 Task 2: on_found now also does
# `$self->_ws->onEvent(sub { $ctl->onEvent(@_) });` before connect() -- this
# file-local stub is a test double for SoloistWS itself (not Control), so
# it just needs the accessor to exist, not do anything with the coderef.
sub onEvent    { my $self = shift; $self->{onEvent} = shift if @_; return $self->{onEvent}; }
sub disconnect { }
1;
END
    require Plugins::SpotOn::Unified::SoloistWS;

    # Phase 82 Plan 01 Task 2: Control recorder stub -- t/30 tests
    # SoloistDaemon's wiring, not Control's own state machine (that is
    # t/44_soloist_control.t's job), so a plain constructor recorder
    # suffices here.
    write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Control', <<'END');
package Plugins::SpotOn::Soloist::Control;
our @NEW_CALLS;
our @REQUESTTRACK_CALLS;
sub new {
    my ($class, %args) = @_;
    push @NEW_CALLS, \%args;
    return bless { %args }, $class;
}
sub onEvent  { }
sub shutdown { }
sub for_client { return undef; }
# 260914-qn1 (Signature C, Fall b): recorder for on_found's replay of a
# pending deferred track request through the freshly-built Control.
sub requestTrack { my $self = shift; push @REQUESTTRACK_CALLS, [@_]; }
1;
END
    require Plugins::SpotOn::Soloist::Control;

    # 83.3-02 (D-12b/D-13): on_found now also calls
    # Quality->onDaemonReady($mac) right after _parseExpiryDays -- stub
    # Quality itself (not its Slim::Player::Client/SimpleAsyncHTTP/Login5
    # dependency chain, which t/50_soloist_quality.t already covers
    # exhaustively) so this file keeps testing SoloistDaemon's wiring only.
    # The stub shadows the real module because $stub_dir precedes
    # $project_dir in @INC, same convention as SoloistWS/Control above.
    write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Quality', <<'END');
package Plugins::SpotOn::Soloist::Quality;
our @ON_DAEMON_READY_CALLS;
sub onDaemonReady { my ($class, $mac) = @_; push @ON_DAEMON_READY_CALLS, $mac; }
1;
END
    require Plugins::SpotOn::Soloist::Quality;

    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:13');
    $daemon->_proc(Test::FakeDaemonProc->new(1));
    $daemon->_wsPortPollAttempts(0);
    $daemon->_spawnTime(time() - 5);

    my $dataDir    = tempdir(CLEANUP => 1);
    my $wsPortFile = catfile($dataDir, 'ws.port');

    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($daemon, $dataDir);
    is($daemon->_wsPort, undef,
        "CR-S3: _pollWsPort attempt 1 (no ws.port file yet) does not resolve");

    open(my $wfh, '>', $wsPortFile) or die $!;
    print $wfh "23456\n";
    close($wfh);

    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($daemon, $dataDir);
    is($daemon->_wsPort, 23456,
        "CR-S3: _pollWsPort resolves once ws.port is written with a fresh mtime (scaffold reschedule works)");
    is(scalar(@Plugins::SpotOn::Unified::SoloistWS::NEW_CALLS), 1,
        "CR-S3: _pollWsPort success path constructs exactly one SoloistWS instance");
    is(scalar(@Plugins::SpotOn::Soloist::Control::NEW_CALLS), 1,
        "on_found constructs exactly one Control (Phase 82)");
    ok((ref($Plugins::SpotOn::Unified::SoloistWS::NEW_CALLS[0]) eq 'HASH'
            && ref($daemon->_ws->onEvent) eq 'CODE'),
        "on_found hands Control->onEvent to the ws");
    is_deeply(\@Plugins::SpotOn::Soloist::Quality::ON_DAEMON_READY_CALLS, ['aa:bb:cc:dd:ee:13'],
        "83.3-02: on_found calls Quality->onDaemonReady(mac) exactly once, after _parseExpiryDays");

    Plugins::SpotOn::Unified::SoloistDaemon::stop($daemon);
    is($daemon->_control, undef, "stop() clears _control");
}

# Test 4: _pollWsPort ignores a port file with mtime older than _spawnTime
# (stale-file guard stays WS-only).
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:14');
    $daemon->_proc(Test::FakeDaemonProc->new(1));
    $daemon->_wsPortPollAttempts(0);
    $daemon->_spawnTime(time() + 60);    # spawnTime "in the future" vs. the file's mtime below

    my $dataDir    = tempdir(CLEANUP => 1);
    my $wsPortFile = catfile($dataDir, 'ws.port');
    open(my $wfh, '>', $wsPortFile) or die $!;
    print $wfh "9999\n";
    close($wfh);    # mtime is "now" -- strictly before _spawnTime -- stale

    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($daemon, $dataDir);

    is($daemon->_wsPort, undef,
        "CR-S3: _pollWsPort ignores a port file with mtime older than _spawnTime (stale-file guard stays WS-only)");
}

# ============================================================
# 82-12 Task 3, WR-02 (82-REVIEW.md): start() tears down an existing
# Control/WS pair BEFORE building new ones -- the crash-respawn path calls
# start() without a preceding stop(), and without this teardown the old
# Control's watchdog timer used to survive to fire `playlist jump +1`
# against the NEW daemon up to WATCHDOG_ROUND_S later (D-02/D-03's blind
# jump, now from an instance nobody observes).
#
# start() does much more than the teardown (Proc::Background spawn,
# tempfile, env juggling, ...) -- these tests stub
# Slim::Player::Client::getClient to return undef, so start() warns "no
# client found" and returns IMMEDIATELY after the teardown call, without
# touching any of that. Proc::Background is stubbed too (not installed in
# this sandbox) purely so the unconditional `require Proc::Background;`
# a few lines above the client check does not abort the whole test file --
# nothing here calls Proc::Background->new.
# ============================================================

# Task 1 (83.3-03, D-06): extended beyond the original bare-bless stub --
# the smoke test below needs `new` to record its args (so a test can inspect
# the argv/opts a real spawn would have received) and return a
# Test::FakeSmokeProc with settable alive/wait (status word, i.e. rc << 8)
# and a counted `die`, plus a $SPAWN_DIE switch that makes `new` die (proves
# smokeTest's spawn-failure branch). None of the EXISTING tests below this
# point ever reach Proc::Background->new (start() bails out earlier on "no
# client found"), so this extension is purely additive.
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our $SPAWN_DIE = 0;
our @NEW_CALLS;
sub new {
    my ($class, $opts, @args) = @_;
    die "Proc::Background::SPAWN_DIE: simulated spawn failure\n" if $SPAWN_DIE;
    my $proc = Test::FakeSmokeProc->new($opts);
    push @NEW_CALLS, { opts => $opts, args => [@args], proc => $proc };
    return $proc;
}
sub reset_calls { @NEW_CALLS = (); $SPAWN_DIE = 0; }

# Test::FakeSmokeProc -- unlike the bare-bless stub the pre-83.3-03 tests
# used (never reached, since start() bails before Proc::Background->new),
# this one actually dup()s the stdout handle it was given (mirroring what a
# REAL fork()+exec() child does with its inherited fd) -- smokeTest()
# legitimately closes its own copy of the pipe write-end right after
# spawning (matching production behavior against a real child), so a test
# needs its OWN independent fd to write "child output" into after that
# point. write_handle() exposes that dup so a test can feed bytes into the
# same pipe the module's sysread() reads from.
package Test::FakeSmokeProc;
sub new {
    my ($class, $opts) = @_;
    my $self = bless { alive => 1, status => 0, die_count => 0 }, $class;
    if ($opts && $opts->{stdout}) {
        open(my $dup, '>&', $opts->{stdout}) or warn "Test::FakeSmokeProc: dup failed: $!";
        $self->{stdout_dup} = $dup;
    }
    return $self;
}
sub alive        { return $_[0]->{alive}; }
sub wait         { return $_[0]->{status}; }
sub die          { $_[0]->{alive} = 0; $_[0]->{die_count}++; }
sub die_count    { return $_[0]->{die_count}; }
sub pid          { return 99999; }
sub write_handle { return $_[0]->{stdout_dup}; }
sub set_alive    { $_[0]->{alive}  = $_[1]; }
sub set_status   { $_[0]->{status} = $_[1]; }
1;
END
require Proc::Background;

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { return undef; }
1;
END
require Slim::Player::Client;

# --- WR-02: Fall A -- start() on a Helper with an existing Control AND an
# existing WS: shutdown()/disconnect() run, Control BEFORE WS, both
# before start() bails out on "no client found" ---
{
    my @order;
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Control::shutdown    = sub { push @order, 'control_shutdown'; };
    local *Plugins::SpotOn::Unified::SoloistWS::disconnect = sub { push @order, 'ws_disconnect'; };

    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:20');
    my $oldControl = Plugins::SpotOn::Soloist::Control->new(mac => $daemon->mac);
    my $oldWs      = Plugins::SpotOn::Unified::SoloistWS->new(mac => $daemon->mac);
    $daemon->_control($oldControl);
    $daemon->_ws($oldWs);

    Plugins::SpotOn::Unified::SoloistDaemon::start($daemon);

    is_deeply(\@order, [ 'control_shutdown', 'ws_disconnect' ],
        "WR-02: Fall A -- start() tears down the old Control before the old WS, both before returning");
    is($daemon->_control, undef, "WR-02: Fall A -- _control is undef after the teardown");
    is($daemon->_ws, undef, "WR-02: Fall A -- _ws is undef after the teardown");
}

# --- WR-02: Fall B -- start() on a fresh Helper without _control/_ws:
# nothing to tear down, no error ---
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:21');

    my $ok = eval { Plugins::SpotOn::Unified::SoloistDaemon::start($daemon); 1 };
    ok($ok, "WR-02: Fall B -- start() on a fresh Helper (no _control/_ws) does not die" . ($ok ? '' : ": $@"));
    is($daemon->_control, undef, "WR-02: Fall B -- _control stays undef");
    is($daemon->_ws, undef, "WR-02: Fall B -- _ws stays undef");
}

# --- WR-02: Fall C -- no orphaned timer: the OLD Control's own armed
# timer is gone from the registry after the respawn teardown runs -- not
# merely "a new instance exists" (see the @TIMERS enhancement above) ---
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Control::shutdown = sub {
        my $self = shift;
        Slim::Utils::Timers::killTimers($self, \&Test::WR02FakeWatchdog::fire);
    };

    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:22');
    my $oldControl = Plugins::SpotOn::Soloist::Control->new(mac => $daemon->mac);
    $daemon->_control($oldControl);

    # Simulate the old Control's own armed watchdog-style timer
    # (WATCHDOG_ROUND_S, Control.pm), registered against the OLD instance.
    Slim::Utils::Timers::setTimer($oldControl, time() + 10, \&Test::WR02FakeWatchdog::fire);
    ok((grep { $_->[0] == $oldControl } @Slim::Utils::Timers::TIMERS),
        "WR-02: Fall C -- precondition: the old Control's timer is registered before the respawn");

    Plugins::SpotOn::Unified::SoloistDaemon::start($daemon);

    ok(!(grep { $_->[0] == $oldControl } @Slim::Utils::Timers::TIMERS),
        "WR-02: Fall C -- no timer entry points at the OLD Control instance after the respawn teardown");
}

# ============================================================
# Signature C (260914-qn1): SoloistDaemon-level deferral
# ============================================================

# Fall a (unit-level, mirrors Control's own Schritt-1 assertions): a direct
# deferTrackRequest call sets _pendingTrackRequest, neither callback fires.
# Must-fail proof: a no-op deferTrackRequest (or one that does not set the
# field) leaves _pendingTrackRequest undef -- this assertion goes red.
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:30');

    my ($success_called, $error_called);
    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:sigc01', 1500, {
        successCb => sub { $success_called = 1; },
        errorCb   => sub { $error_called = 1; },
    });

    ok(defined $daemon->_pendingTrackRequest, "Fall a: _pendingTrackRequest is set after deferTrackRequest");
    ok(!$success_called, "Fall a: successCb does not fire on defer");
    ok(!$error_called, "Fall a: errorCb does not fire on defer");

    # Cleanup: this Fall's deferral is deliberately left unresolved (its
    # own precondition) -- kill the timer explicitly so it does not bleed
    # into Fall d's fire_due(now+TTL+1) sweep below (global registry, not
    # scoped per-Fall).
    Slim::Utils::Timers::killTimers($daemon, \&Plugins::SpotOn::Unified::SoloistDaemon::_pendingTrackTimeout);
}

# Fall a-2 (Fall-5 supersession, same convention as Control.pm:818-821): a
# second deferTrackRequest on the SAME daemon before the first resolves
# supersedes it. Must-fail proof: without the killTimers+supersede step,
# the first request's errorCb stays silent and two timer entries end up
# pointing at $daemon (the @Slim::Utils::Timers::TIMERS grep count for this
# daemon goes to 2, not 1) -- both assertions below go red.
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:31');

    my ($first_error_count, @first_error_args);
    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:sigc02a', 0, {
        errorCb => sub { $first_error_count++; @first_error_args = @_; },
    });
    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:sigc02b', 0, {
        errorCb => sub { },
    });

    is($first_error_count, 1, "Fall a-2: the FIRST request's errorCb fires exactly once on supersession");
    is_deeply(\@first_error_args, ['PROBLEM_OPENING', 'superseded'], "Fall a-2: the FIRST request's errorCb fires with PROBLEM_OPENING/superseded");
    is($daemon->_pendingTrackRequest->{uri}, 'spoton://track:sigc02b', "Fall a-2: the SECOND request is now the one held in _pendingTrackRequest");
    is(scalar(grep { $_->[0] == $daemon } @Slim::Utils::Timers::TIMERS), 1, "Fall a-2: only ONE timer entry points at this daemon (the old one was killed)");

    # Cleanup: the SECOND request's timer is a deliberately-unresolved
    # precondition of THIS Fall (it is never meant to fire here) -- left
    # armed it would bleed into Fall d's fire_due(now+TTL+1) sweep below
    # (a global timer registry, not scoped per-Fall) and double-count its
    # Status::RECORDED entry. Kill it explicitly once this Fall's own
    # assertions are done with it.
    Slim::Utils::Timers::killTimers($daemon, \&Plugins::SpotOn::Unified::SoloistDaemon::_pendingTrackTimeout);
}

# Fall-0 (value gate, 82-44/D-12): superseded -- PENDING_TRACK_TTL_S no
# longer holds an independent 25s value; it delegates to
# Plugins::SpotOn::Unified::DeferBudget::TOTAL_DEFER_BUDGET_S, the ONE 20s
# budget shared with Control::WS_RETRY_TTL_S (D-12). This gate now asserts
# the exact value. Must-fail proof: a revert to
# `Time::HiRes::time() + 25` in SoloistDaemon.pm (bypassing DeferBudget)
# turns this red while leaving Fall d below green (proving THIS gate, not
# that one, catches the regression).
{
    is(Plugins::SpotOn::Unified::SoloistDaemon::PENDING_TRACK_TTL_S(), 20, "Fall-0: PENDING_TRACK_TTL_S == 20 (82-44/D-12, EIN Gesamtbudget statt der bisherigen Einzel-TTL 25)");
}

# --- D-12 (82-46 Task 2, WR-04, DeferBudget direkt): deadlineFor liest
# eine bereits gesetzte deferDeadline weiter, statt sie neu zu berechnen;
# ein leerer Hashref bekommt beim ersten Aufruf eine Frist, ein zweiter
# Aufruf auf DEMSELBEN Hashref liefert dieselbe Frist zurueck (kein
# Neuberechnen bei wiederholter Weiterreichung). Muss-Fehlschlag (M-E,
# mechanisch in diesem Plans <verify> vorgefuehrt): ein Rueckbau von
# `//=` auf `=` in DeferBudget.pm laesst die erste Assertion hier rot
# fallen (42 wird ignoriert, eine frische Zeit kommt zurueck). ---
{
    require Plugins::SpotOn::Unified::DeferBudget;

    is(Plugins::SpotOn::Unified::DeferBudget::deadlineFor({ deferDeadline => 42 }), 42,
        "D-12: deadlineFor liest eine vorgesetzte deferDeadline anstatt neu zu rechnen (M-E)");

    my $o = {};
    my $d = Plugins::SpotOn::Unified::DeferBudget::deadlineFor($o);
    is(Plugins::SpotOn::Unified::DeferBudget::deadlineFor($o), $d,
        "D-12: ein zweiter deadlineFor-Aufruf auf DEMSELBEN Hashref liefert dieselbe Frist zurueck");
    is($o->{deferDeadline}, $d,
        "D-12: deadlineFor persistiert die berechnete Frist in \$opts");
}

# --- D-12 (82-46 Task 2, WR-04, SoloistDaemon als Verbraucher):
# deferTrackRequest liest eine vorgesetzte deferDeadline aus $opts,
# statt selbst Time::HiRes::time()+PENDING_TRACK_TTL_S zu rechnen.
# Muss-Fehlschlag (M-O, namentlich benannt, nicht in diesem Plans
# <verify> mechanisch vorgefuehrt -- s. SUMMARY): ein Rueckbau von
# SoloistDaemon.pm's `deadlineFor($opts)`-Aufruf auf eine unabhaengige
# `Time::HiRes::time() + PENDING_TRACK_TTL_S`-Berechnung laesst die
# Assertion unten rot fallen (der Timer-Eintrag traegt dann eine
# FRISCHE Zeit statt der vorgesetzten 1234567890.5). ---
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:46');

    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:d12', 0, {
        errorCb => sub { }, deferDeadline => 1234567890.5,
    });

    my ($entry) = grep { $_->[0] == $daemon } @Slim::Utils::Timers::TIMERS;
    is($entry->[1], 1234567890.5,
        "D-12: SoloistDaemon liest die vorgesetzte Frist anstatt sie selbst zu berechnen (M-O)");

    # Cleanup: same convention as Fall a/a-2 above -- do not leave this
    # Fall's own timer armed for Fall d's later fire_due() sweep.
    Slim::Utils::Timers::killTimers($daemon, \&Plugins::SpotOn::Unified::SoloistDaemon::_pendingTrackTimeout);
}

# Fall b (on_found resolves the deferral): build a daemon exactly like the
# earlier "Test 3" WS-variant setup. Must-fail proof: removing the
# on_found replay insertion leaves @REQUESTTRACK_CALLS empty and
# _pendingTrackRequest still set after _pollWsPort resolves.
{
    @Plugins::SpotOn::Soloist::Control::REQUESTTRACK_CALLS = ();

    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:32');
    $daemon->_proc(Test::FakeDaemonProc->new(1));
    $daemon->_wsPortPollAttempts(0);
    $daemon->_spawnTime(time() - 5);

    my $successCb = sub { };
    my $errorCb   = sub { };
    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:sigc03', 4200, {
        successCb => $successCb, errorCb => $errorCb,
    });

    my $dataDir    = tempdir(CLEANUP => 1);
    my $wsPortFile = catfile($dataDir, 'ws.port');

    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($daemon, $dataDir);

    open(my $wfh, '>', $wsPortFile) or die $!;
    print $wfh "34567\n";
    close($wfh);

    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($daemon, $dataDir);

    is(scalar(@Plugins::SpotOn::Soloist::Control::REQUESTTRACK_CALLS), 1, "Fall b: exactly one Control->requestTrack call after on_found resolves");
    is($Plugins::SpotOn::Soloist::Control::REQUESTTRACK_CALLS[0][0], 'spoton://track:sigc03', "Fall b: the replayed call carries the deferred uri");
    is($Plugins::SpotOn::Soloist::Control::REQUESTTRACK_CALLS[0][1], 4200, "Fall b: the replayed call carries the deferred posMs");
    ok($Plugins::SpotOn::Soloist::Control::REQUESTTRACK_CALLS[0][2]{successCb} == $successCb, "Fall b: the replayed call carries the SAME successCb reference (not a copy)");
    ok($Plugins::SpotOn::Soloist::Control::REQUESTTRACK_CALLS[0][2]{errorCb} == $errorCb, "Fall b: the replayed call carries the SAME errorCb reference (not a copy)");
    is($daemon->_pendingTrackRequest, undef, "Fall b: _pendingTrackRequest is undef after on_found resolves it");
}

# Fall d (TTL fallback, mirrors t/44:5245-5277 almost exactly): must-fail
# proof: a _pendingTrackTimeout that fires errorCb but skips the
# recordError call passes the errorCb assertion but fails the RECORDED
# count assertion -- both must be present, not just one.
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:33');

    my ($success_called, $error_called, @error_args);
    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:sigc04', 0, {
        successCb => sub { $success_called = 1; },
        errorCb   => sub { $error_called++; @error_args = @_; },
    });
    ok(defined $daemon->_pendingTrackRequest, "Fall d: precondition -- deferred before the TTL fires");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + Plugins::SpotOn::Unified::SoloistDaemon::PENDING_TRACK_TTL_S() + 1);

    is($daemon->_pendingTrackRequest, undef, "Fall d: _pendingTrackRequest is undef after the TTL fires");
    ok(!$success_called, "Fall d: successCb never fires on TTL expiry");
    ok($error_called, "Fall d: errorCb fires on TTL expiry");
    is_deeply(\@error_args, ['PROBLEM_OPENING', 'Soloist daemon not ready'], "Fall d: errorCb fires with the exact unchanged error shape");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "Fall d: exactly one Status errors[] entry recorded");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'warn', "Fall d: RECORDED entry level is warn");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "Fall d: RECORDED entry module is Soloist");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/timed out/, "Fall d: RECORDED entry message mentions timed out");
}

# Fall e (teardown release, mirrors the WR-02 block's own shape): must-fail
# proof: without Task 1 step 6, errorCb never fires and the timer survives
# teardown -- both assertions below go red.
{
    my $daemon = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $daemon->mac('aa:bb:cc:dd:ee:34');

    my ($error_called, @error_args);
    Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest($daemon, 'spoton://track:sigc05', 0, {
        errorCb => sub { $error_called++; @error_args = @_; },
    });

    ok((grep { $_->[0] == $daemon } @Slim::Utils::Timers::TIMERS),
        "Fall e: precondition -- a timer is registered against this daemon before teardown");

    Plugins::SpotOn::Unified::SoloistDaemon::_shutdownExistingControl($daemon);

    is($daemon->_pendingTrackRequest, undef, "Fall e: _pendingTrackRequest is undef after teardown");
    ok($error_called, "Fall e: errorCb fires on teardown");
    is_deeply(\@error_args, ['PROBLEM_OPENING', 'Soloist daemon shut down'], "Fall e: errorCb fires with PROBLEM_OPENING/Soloist daemon shut down");
    ok(!(grep { $_->[0] == $daemon } @Slim::Utils::Timers::TIMERS),
        "Fall e: no timer entry still points at this daemon after teardown");
}

# ============================================================
# Task 1 (83.3-03, D-06): _smokeVerdict() table -- pure classifier, no I/O.
# ============================================================
{
    my $class = 'Plugins::SpotOn::Unified::SoloistDaemon';
    my $MAX   = Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_POLL_MAX_ATTEMPTS();

    my @cases = (
        [ "soloist 1.3.8.70 build 1 (20260101) (gabc123) (linux/x86_64)\nclient expires in 89 days\n",
          1, undef, 3, [ 'found', 89, '1.3.8.70' ], "found (days 89, version parsed)" ],
        [ '', 0, 10, 5, [ 'expired' ], "expired (dead, rc 10)" ],
        [ '', 0, 1,  5, [ 'exited', 1 ], "exited (dead, rc 1)" ],
        [ '', 1, undef, $MAX, [ 'timeout' ], "timeout (alive, attempts $MAX)" ],
        [ '', 1, undef, 3, [ 'pending' ], "pending (alive, attempts 3, no line)" ],
    );

    for my $case (@cases) {
        my ($head, $alive, $exitCode, $attempts, $expected, $desc) = @$case;
        my @got = $class->_smokeVerdict($head, $alive, $exitCode, $attempts);
        is_deeply(\@got, $expected, "_smokeVerdict: $desc");
    }
}

# ============================================================
# Task 1 (83.3-03, D-06): smokeTest() branch tests -- drives the REAL sub
# against the extended Proc::Background stub + the Select stub above.
# readKey()/_rootDir() are glob-overridden so no real spak-key or a real
# player's cache dir is ever touched -- every smoke dir lives under a fresh
# tempdir, never a real player's dir (Soloist.pm anti-pattern).
# ============================================================

# _fire_last_timer() -- fires (and removes) the MOST RECENTLY registered
# timer directly, rather than Slim::Utils::Timers::fire_due()'s "any timer
# whose $when has passed" sweep -- the smoke test's own poll timer is the
# only one alive at each of these points, but firing by identity (not by
# wall-clock $when) keeps these tests immune to any unrelated leftover
# timer entry elsewhere in this large file.
sub _fire_last_timer {
    my $entry = $Slim::Utils::Timers::TIMERS[-1];
    return unless $entry;
    my ($obj, undef, $cb, @extra) = @$entry;
    @Slim::Utils::Timers::TIMERS = grep { $_ != $entry } @Slim::Utils::Timers::TIMERS;
    $cb->($obj, @extra);
}

# -- found --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    is(scalar(@Slim::Networking::Select::ADD_READ_CALLS), 1,
        "smokeTest: found -- addRead registered exactly once");

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    my $wfh  = $proc->write_handle;
    ok(defined $wfh, "smokeTest: found -- FakeSmokeProc dup'd the stdout pipe handle");

    syswrite($wfh, "soloist 1.3.8.70 build 1 (20260101) (gabc123) (linux/x86_64)\nclient expires in 89 days\n");

    my $readCb = $Slim::Networking::Select::ADD_READ_CALLS[-1][1];
    $readCb->();

    is($cb_calls, 1, "smokeTest: found -- cb fires exactly once");
    ok($cb_ok, "smokeTest: found -- cb ok=1");
    is($cb_info->{days}, 89, "smokeTest: found -- days parsed from the banner line");
    is($cb_info->{version}, '1.3.8.70', "smokeTest: found -- version parsed from the banner line");
    is($cb_info->{ready_seen_before_kill}, 0, "smokeTest: found -- no 'ready,' line seen before the kill");
    is($proc->die_count, 1, "smokeTest: found -- proc->die() called exactly once");
    ok((scalar(@Slim::Networking::Select::REMOVE_READ_CALLS) >= 1), "smokeTest: found -- removeRead called");
    my @leftover = glob("$tmpRoot/smoke/*");
    is(scalar(@leftover), 0, "smokeTest: found -- smoke dir removed");
}

# -- found, variant: a 'ready,' line precedes the expiry line --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    my $wfh  = $proc->write_handle;
    syswrite($wfh, "soloist 1.3.8.70 build 1 (20260101) (gabc123) (linux/x86_64)\nready, ...\nclient expires in 89 days\n");

    my $readCb = $Slim::Networking::Select::ADD_READ_CALLS[-1][1];
    $readCb->();

    is($cb_calls, 1, "smokeTest: found+ready -- cb fires exactly once");
    is($cb_info->{ready_seen_before_kill}, 1, "smokeTest: found+ready -- ready_seen_before_kill is 1 when 'ready,' precedes the kill");
}

# -- Phase 83.3 plan 15 (G-83.3-3): smokeTest() arms the exit-status watcher
#    exactly once per spawn. Glob-overridden here purely to COUNT
#    invocations against the real smokeTest() code path -- this harness
#    never loads the LMS-bundled EV, so the real _watchExit would no-op
#    (return 0) anyway; the override just makes the call itself observable.
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    my $watchCalls = 0;
    local *Plugins::SpotOn::Unified::SoloistDaemon::_watchExit = sub { $watchCalls++; return 0; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    $proc->set_alive(0);
    $proc->set_status(1 << 8);
    _fire_last_timer();

    is($cb_calls, 1, "smokeTest: _watchExit wiring -- cb fires exactly once");
    is($watchCalls, 1, "smokeTest: _watchExit is armed exactly once per spawn");
}

# -- expired --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    $proc->set_alive(0);
    $proc->set_status(10 << 8);

    _fire_last_timer();

    is($cb_calls, 1, "smokeTest: expired -- cb fires exactly once");
    ok(!$cb_ok, "smokeTest: expired -- cb ok=0");
    is($cb_info->{reason}, 'expired', "smokeTest: expired -- reason is 'expired'");
    ok((scalar(@Slim::Networking::Select::REMOVE_READ_CALLS) >= 1), "smokeTest: expired -- removeRead called");
    my @leftover = glob("$tmpRoot/smoke/*");
    is(scalar(@leftover), 0, "smokeTest: expired -- smoke dir removed");
}

# -- exited --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    $proc->set_alive(0);
    $proc->set_status(1 << 8);

    _fire_last_timer();

    is($cb_calls, 1, "smokeTest: exited -- cb fires exactly once");
    ok(!$cb_ok, "smokeTest: exited -- cb ok=0");
    is($cb_info->{reason}, 'exited_rc_1', "smokeTest: exited -- reason is 'exited_rc_1'");
    ok((scalar(@Slim::Networking::Select::REMOVE_READ_CALLS) >= 1), "smokeTest: exited -- removeRead called");
    my @leftover = glob("$tmpRoot/smoke/*");
    is(scalar(@leftover), 0, "smokeTest: exited -- smoke dir removed");
}

# -- timeout --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    my $maxAttempts = Plugins::SpotOn::Unified::SoloistDaemon::SMOKE_POLL_MAX_ATTEMPTS();
    for (1 .. $maxAttempts) {
        last if $cb_calls;
        _fire_last_timer();
    }

    is($cb_calls, 1, "smokeTest: timeout -- cb fires exactly once");
    ok(!$cb_ok, "smokeTest: timeout -- cb ok=0");
    is($cb_info->{reason}, 'no_expiry_line', "smokeTest: timeout -- reason is 'no_expiry_line'");
    is($proc->die_count, 1, "smokeTest: timeout -- proc->die() called exactly once (kills the stuck process)");
    my @leftover = glob("$tmpRoot/smoke/*");
    is(scalar(@leftover), 0, "smokeTest: timeout -- smoke dir removed");
}

# -- spawn_failed --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();
    $Proc::Background::SPAWN_DIE = 1;

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    $Proc::Background::SPAWN_DIE = 0;

    is($cb_calls, 1, "smokeTest: spawn_failed -- cb fires exactly once");
    ok(!$cb_ok, "smokeTest: spawn_failed -- cb ok=0");
    is($cb_info->{reason}, 'spawn_failed', "smokeTest: spawn_failed -- reason is 'spawn_failed'");
    is(scalar(@Slim::Networking::Select::ADD_READ_CALLS), 0,
        "smokeTest: spawn_failed -- no addRead ever registered (the watcher never existed)");
    my @leftover = glob("$tmpRoot/smoke/*");
    is(scalar(@leftover), 0, "smokeTest: spawn_failed -- smoke dir removed");
}

# -- end-of-stream: writer closed with no data, THEN the poll observes the exit --
{
    my $tmpRoot = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::readKey  = sub { return 'fake-spak-key-83-3-03'; };
    local *Plugins::SpotOn::Soloist::_rootDir = sub { return $tmpRoot; };

    Proc::Background::reset_calls();
    Slim::Networking::Select::reset_calls();

    my ($cb_ok, $cb_info, $cb_calls) = (undef, undef, 0);
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest('/fake/candidate/soloist', sub {
        ($cb_ok, $cb_info) = @_;
        $cb_calls++;
    });

    my $proc = $Proc::Background::NEW_CALLS[-1]{proc};
    my $wfh  = $proc->write_handle;
    close($wfh);    # writer end closed without writing anything -- real EOF on $rd

    my $readCb = $Slim::Networking::Select::ADD_READ_CALLS[-1][1];
    $readCb->();

    is($cb_calls, 0, "smokeTest: end-of-stream -- EOF alone does not fire cb yet (verdict left to the poll)");
    is(scalar(@Slim::Networking::Select::REMOVE_READ_CALLS), 1,
        "smokeTest: end-of-stream -- removeRead called exactly once, directly from the read callback");

    $proc->set_alive(0);
    $proc->set_status(1 << 8);
    _fire_last_timer();

    is($cb_calls, 1, "smokeTest: end-of-stream -- cb fires exactly once once the fallback poll observes the exit");
    ok(!$cb_ok, "smokeTest: end-of-stream -- cb ok=0");
    is($cb_info->{reason}, 'exited_rc_1', "smokeTest: end-of-stream -- reason is 'exited_rc_1'");
    my @leftover = glob("$tmpRoot/smoke/*");
    is(scalar(@leftover), 0, "smokeTest: end-of-stream -- smoke dir removed");
}

# ============================================================
# 74b-04 Task 2 (T-74b-13, T-74b-15): the Soloist log is bounded. Rotation at
# start (above 10 MB -> .1; above the 50 MB cap -> only the last 5 MB in .1,
# so an already huge log never survives whole), a runtime cap, an offset clamp
# for stderrTail/_parseExpiryDays after any truncation, and an append-mode
# open. Fixtures are SPARSE files in a tempdir (seek, then write a known
# pattern) - never multi-GB, never the real log.
# ============================================================
{
    my $D  = 'Plugins::SpotOn::Unified::SoloistDaemon';
    my $MB = 1024 * 1024;

    is($D->can('LOG_ROTATE_AT_START_BYTES') ? $D->LOG_ROTATE_AT_START_BYTES : undef, 10 * $MB,
        '74b-04: LOG_ROTATE_AT_START_BYTES is 10 MB');
    is($D->can('LOG_RUNTIME_CAP_BYTES') ? $D->LOG_RUNTIME_CAP_BYTES : undef, 50 * $MB,
        '74b-04: LOG_RUNTIME_CAP_BYTES is 50 MB');
    is($D->can('LOG_KEEP_TAIL_BYTES') ? $D->LOG_KEEP_TAIL_BYTES : undef, 5 * $MB,
        '74b-04: LOG_KEEP_TAIL_BYTES is 5 MB');
    is($D->can('LOG_CAP_INTERVAL') ? $D->LOG_CAP_INTERVAL : undef, 30,
        '74b-04: LOG_CAP_INTERVAL is 30 s');

    # build a sparse log: $head bytes of marker at offset 0, then $tail_mb
    # megabytes of pattern ending at $total_mb (one distinct letter per MB).
    my $build = sub {
        my ($path, $total_mb, $pattern_mb) = @_;
        open(my $fh, '>:raw', $path) or die "build $path: $!";
        print $fh "HEADMARK";
        seek($fh, ($total_mb - $pattern_mb) * $MB, 0);
        for my $i (0 .. $pattern_mb - 1) {
            print $fh chr(ord('A') + $i) x $MB;
        }
        close($fh);
    };
    my $slurp = sub {
        my ($path, $from, $len) = @_;
        open(my $fh, '<:raw', $path) or return undef;
        seek($fh, $from // 0, 0);
        local $/;
        my $d = defined $len ? do { read($fh, my $b, $len); $b } : <$fh>;
        close($fh);
        return $d;
    };

    # ---- rotate at start: 11 MB -> .1 whole, previous .1 replaced
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $file = "$dir/x-soloist.log";
        $build->($file, 11, 1);
        open(my $o, '>', "$file.1") or die; print $o "PREVIOUS"; close($o);
        eval { $D->_rotateLogAtStart($file); 1 };
        ok(!$@ && -f "$file.1" && (-s "$file.1") == 11 * $MB,
            '74b-04: _rotateLogAtStart moves an 11 MB log whole to .1 (replacing the previous .1)');
        is($slurp->("$file.1", 0, 8), 'HEADMARK', '74b-04: the rotated .1 holds the old bytes');
        ok(!-e $file || -z $file, '74b-04: the live file is gone or empty after the start rotation');
    }

    # ---- below the start threshold: untouched
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $file = "$dir/x-soloist.log";
        $build->($file, 9, 1);
        eval { $D->_rotateLogAtStart($file); 1 };
        ok(-s $file == 9 * $MB && !-e "$file.1", '74b-04: a 9 MB log is left untouched at start');
    }

    # ---- oversize fixture: 51 MB log (first start with the cap code)
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $file = "$dir/x-soloist.log";
        $build->($file, 51, 6);
        my $expectTail = $slurp->($file, 46 * $MB, 5 * $MB);
        open(my $o, '>', "$file.1") or die; print $o "PREVIOUS"; close($o);
        eval { $D->_rotateLogAtStart($file); 1 };
        is(-s "$file.1", 5 * $MB, 'oversize: .1 is exactly LOG_KEEP_TAIL_BYTES for a log above the runtime cap');
        ok(defined $slurp->("$file.1") && $slurp->("$file.1") eq $expectTail,
            'oversize: .1 equals the last 5 MB of the original (not the whole log)');
        ok(!-e $file || -z $file, 'oversize: the live file is gone or empty');
    }

    # ---- _capLogNow
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $file = "$dir/x-soloist.log";
        $build->($file, 51, 6);
        my $expectTail = $slurp->($file, 46 * $MB, 5 * $MB);
        my $daemon = bless [], $D;
        $daemon->_stderrFile($file);
        $daemon->_stderrStartOffset(777);
        eval { $daemon->_capLogNow; 1 };
        is(-s $file, 0, '74b-04: _capLogNow truncates a 51 MB live log to 0');
        is(-s "$file.1", 5 * $MB, '74b-04: _capLogNow keeps exactly LOG_KEEP_TAIL_BYTES in .1');
        ok(defined $slurp->("$file.1") && $slurp->("$file.1") eq $expectTail,
            '74b-04: _capLogNow .1 equals the last 5 MB of the original');
        is($daemon->_stderrStartOffset, 0, '74b-04: _capLogNow resets _stderrStartOffset to 0');

        my $file2 = "$dir/y-soloist.log";
        $build->($file2, 49, 1);
        my $d2 = bless [], $D;
        $d2->_stderrFile($file2);
        $d2->_stderrStartOffset(5);
        eval { $d2->_capLogNow; 1 };
        ok(-s $file2 == 49 * $MB && !-e "$file2.1" && $d2->_stderrStartOffset == 5,
            '74b-04: _capLogNow leaves a 49 MB log untouched');
    }

    # ---- _copyLogTail (74b WR-02): a failed copy must not leave <dest>.tmp
    {
        my $dir = tempdir(CLEANUP => 1);
        my $src = "$dir/src.log";
        open(my $o, '>:raw', $src) or die; print $o 'abcdefghij' x 10; close($o);
        my $copy = $D->can('_copyLogTail');    # a plain function, not a method

        # success: the last 30 bytes land in dest, no .tmp stays
        my $dest = "$dir/ok.log.1";
        is($copy->($src, $dest, 30), 1, '74b WR-02: _copyLogTail reports success');
        is($slurp->($dest), 'abcdefghij' x 3, '74b WR-02: _copyLogTail writes the last N bytes');
        ok(!-e "$dest.tmp", '74b WR-02: a successful copy leaves no .tmp behind');

        # failure after the temp file exists: dest is a directory, so the
        # final rename fails
        my $badDest = "$dir/bad.log.1";
        mkdir $badDest or die "mkdir $badDest: $!";
        is($copy->($src, $badDest, 30), 0, '74b WR-02: _copyLogTail reports failure when the rename fails');
        ok(!-e "$badDest.tmp", '74b WR-02: a failed copy removes its .tmp (rename failure path)');
        ok(-d $badDest, '74b WR-02: the failed copy leaves the destination as it was');

        # failure before the temp file exists: nothing to leave behind either
        is($copy->("$dir/missing.log", "$dir/miss.log.1", 30), 0, '74b WR-02: _copyLogTail reports failure for a missing source');
        ok(!-e "$dir/miss.log.1.tmp" && !-e "$dir/miss.log.1", '74b WR-02: a missing source leaves neither .tmp nor dest');
    }

    # ---- _logCapTick: alive -> caps and re-arms; dead -> neither
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $file = "$dir/x-soloist.log";
        $build->($file, 51, 6);
        my $daemon = bless [], $D;
        $daemon->_stderrFile($file);
        $daemon->_proc(Test::FakeDaemonProc->new(0));
        @Slim::Utils::Timers::TIMERS = ();
        eval { Plugins::SpotOn::Unified::SoloistDaemon::_logCapTick($daemon); 1 };
        ok(-s $file == 51 * $MB && !@Slim::Utils::Timers::TIMERS,
            '74b-04: _logCapTick on a dead daemon neither caps nor re-arms');

        $daemon->_proc(Test::FakeDaemonProc->new(1));
        eval { Plugins::SpotOn::Unified::SoloistDaemon::_logCapTick($daemon); 1 };
        is(-s $file, 0, '74b-04: _logCapTick on a live daemon caps the log');
        my @armed = grep { $_->[2] == \&Plugins::SpotOn::Unified::SoloistDaemon::_logCapTick } @Slim::Utils::Timers::TIMERS;
        is(scalar(@armed), 1, '74b-04: _logCapTick re-arms itself exactly once');

        # stop() and stopForSync() kill the cap timer
        my $d3 = bless [], $D;
        $d3->mac('aa:bb:cc:dd:ee:74');
        $d3->_proc(Test::FakeDaemonProc->new(1));
        Slim::Utils::Timers::setTimer($d3, time() + 30, \&Plugins::SpotOn::Unified::SoloistDaemon::_logCapTick);
        $d3->stop;
        ok(!(grep { $_->[0] == $d3 } @Slim::Utils::Timers::TIMERS), '74b-04: stop() kills the cap timer');

        my $d4 = bless [], $D;
        $d4->mac('aa:bb:cc:dd:ee:75');
        $d4->_proc(Test::FakeDaemonProc->new(1));
        Slim::Utils::Timers::setTimer($d4, time() + 30, \&Plugins::SpotOn::Unified::SoloistDaemon::_logCapTick);
        $d4->stopForSync;
        ok(!(grep { $_->[0] == $d4 } @Slim::Utils::Timers::TIMERS), '74b-04: stopForSync() kills the cap timer');
    }

    # ---- stderrTail recovers after an external truncate (offset clamp)
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $file = "$dir/x-soloist.log";
        open(my $o, '>', $file) or die; print $o ("old line\n" x 200); close($o);
        my $daemon = bless [], $D;
        $daemon->_stderrFile($file);
        $daemon->_stderrStartOffset(-s $file);
        open($o, '>', $file) or die; close($o);                 # external truncate to 0
        open($o, '>>', $file) or die; print $o "fresh line\n"; close($o);
        is($daemon->stderrTail(8192), "fresh line\n",
            '74b-04: stderrTail returns the new content after a truncate (offset clamped to the file size)');

        # _parseExpiryDays shares the clamp
        no warnings 'once';
        *Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION = sub { 1 };
        $daemon->_stderrStartOffset(100000);
        open($o, '>', $file) or die; print $o "client expires in 42 days\n"; close($o);
        $daemon->_parseExpiryDays;
        is($Slim::Utils::Cache::SET{spoton_soloist_expiry_days} && $Slim::Utils::Cache::SET{spoton_soloist_expiry_days}{days}, 42,
            '74b-04: _parseExpiryDays reads from 0 when the start offset lies beyond the file size');
    }

    # ---- start() opens the log in append mode whatever diagnosticMode is
    # (source pin: start() cannot be driven in this harness, getClient is undef)
    {
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Unified/SoloistDaemon.pm") or die $!;
        my $src = do { local $/; <$fh> };
        close($fh);
        my ($body) = $src =~ /(\nsub start \{.*?)(?=\n(?:# [^\n]*\n)*sub \w)/s;
        ok(defined $body && $body =~ /open\(\$stderr_fh,\s*'>>'/ && $body !~ /\?\s*'>>'\s*:\s*'>'/,
            '74b-04: start() opens the Soloist log with >> unconditionally');
        ok(defined $body && $body =~ /_rotateLogAtStart/ && $body =~ /_logCapTick/,
            '74b-04: start() rotates before the open and arms the cap timer');
    }
}

done_testing();
