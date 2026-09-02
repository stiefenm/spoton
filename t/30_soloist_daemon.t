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

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Soloist.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Soloist.pm not yet present in this checkout';
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

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
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
# Test: isPairedForClient() heuristic -- false on empty/missing dir,
# true after any non-dot entry appears (mirrors the retired shared
# isPaired()'s heuristic, applied per player).
# ============================================================
{
    is(Plugins::SpotOn::Soloist::isPairedForClient('aa:bb:cc:dd:ee:01'), 0,
        "isPairedForClient() is false when the per-player data dir doesn't exist yet");

    my $mac = 'aa:bb:cc:dd:ee:02';
    my $dir = Plugins::SpotOn::Soloist::dataDirForClient($mac);
    make_path($dir);

    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 0,
        "isPairedForClient() is false on an empty (but existing) per-player data dir");

    open(my $fh, '>', "$dir/some-session-file") or die $!;
    print $fh 'fake-session-data';
    close($fh);

    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 1,
        "isPairedForClient() is true after a file appears in the per-player data dir");
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
1;
END
    require Plugins::SpotOn::Unified::SoloistWS;

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

done_testing();
