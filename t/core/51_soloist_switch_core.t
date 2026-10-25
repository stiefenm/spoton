#!/usr/bin/perl
# Phase 83.3 plan 04: behavioral coverage for the D-02 "switch only while
# idle" gate (_processPendingSwitches, consuming plan 03's
# %pendingBinarySwitch) and the D-07 automatic rollback (_rollbackDue,
# noteStartupFailure, _rollbackAfterSwitch). Mirrors t/33_soloist_expiry.t's
# stub set (a real DaemonManager.pm driven against a stateful Cache stub)
# plus glob-overrides of SoloistDaemon::new (avoids the real, LMS-client-
# dependent start() path) and _isStreamActive (a settable flag instead of a
# real client/health snapshot).
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Unified/DaemonManager.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

my $stub_dir = tempdir(CLEANUP => 1);

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
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( cachedir => '/tmp/spoton-test-cachedir', backend => 'soloist' );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set      { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client   { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

# STATEFUL cache stub (t/33 pattern) -- DaemonManager's module-level $cache
# is a real Slim::Utils::Cache->new(...) singleton, and _handleSoloistBuild
# Expiry's ->set() must be observable by startHelper()'s ->get() gate.
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %STORE;
sub new    { return bless {}, shift }
sub get    { my ($self, $k) = @_; return $STORE{$k}; }
sub set    { my ($self, $k, $v, $ttl) = @_; $STORE{$k} = $v; }
sub remove { my ($self, $k) = @_; delete $STORE{$k}; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
1;
END

# Phase 83.3 plan 03: SoloistDaemon.pm `use`s this at the top level for the
# D-06 smoke test's event-driven pipe read -- required for the module to
# load in this sandbox even though this file never exercises smokeTest().
write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
sub addRead    { }
sub removeRead { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
1;
END

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
        *{"${class}::${name}"} = sub {
            my $self = shift;
            $self->[$n] = shift if @_;
            return $self->[$n];
        };
    }
}
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
our $FAKE_BASEDIR = 'test-basedir';
sub _pluginDataFor { return $FAKE_BASEDIR }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
# 84-12 Task 2 (W2): a registrable librespot double -- startHelper's
# librespot branch constructs it, _streamAlivePoll's exit branch reads
# stderrTail. $TAIL is the tail every instance reports; alive is per object.
our $TAIL = '';
sub new   { my ($class, $mac) = @_; return bless { mac => $mac, alive => 1 }, $class }
# 84-08: DaemonManager keys its Soloist-only paths on backendName, not isa.
sub backendName { return 'librespot' }
sub mac   { return $_[0]->{mac} }
sub alive { my $s = shift; $s->{alive} = shift if @_; return $s->{alive} }
sub start { $_[0]->{alive} = 1; $_[0]->{starts}++; return 1 }
sub stop  { $_[0]->{alive} = 0; return 1 }
sub stderrTail { return $TAIL }
sub _stoppedDeliberately { my $s = shift; $s->{sd} = shift if @_; return $s->{sd} }
sub AUTOLOAD { return undef }
sub DESTROY { }
1;
END

# 84-12 Task 2 (W2): the credential classification the librespot exit branch
# makes BEFORE any role dispatch (GH #147) -- switchable per cell.
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our $IS_CRED_ERROR = 0;
sub isCredentialError     { return $IS_CRED_ERROR }
sub needsPlaybackAuth     { return 0 }
sub markNeedsPlaybackAuth { return 1 }
sub accountMismatch       { return 0 }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}
our $FAKE_ISWINDOWS = 0;
our $FAKE_ISMAC     = 0;
BEGIN {
    no warnings 'redefine';
    *main::ISWINDOWS   = sub () { $main::FAKE_ISWINDOWS };
    *main::ISMAC       = sub () { $main::FAKE_ISMAC };
}

# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($stub_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# DaemonManager's librespot start/exit path asks the role for these.
sub daemonClass  { return 'Plugins::SpotOn::Unified::Daemon' }
sub prereqState  { return 'librespot' }
sub bootstrap    { return 'ok' }
sub onDaemonExit { return 'restart' }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
sub daemonClass  { return 'Plugins::SpotOn::Unified::SoloistDaemon' }
sub prereqState  { return 'soloist' }
1;
END

unshift @INC, $stub_dir, $project_dir;

# 84-09: core half of t/51_soloist_switch.t -- DaemonManager's librespot exit
# path (W2) over a mocked role. The Soloist switch/health cells are
# t/soloist/51_soloist_switch_soloist.t.
require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");

# ============================================================
# Test doubles
# ============================================================

{
    package Test::FakeProc;
    sub new   { my ($c, %a) = @_; return bless { %a }, $c; }
    sub wait  { return $_[0]->{status}; }
    sub alive { return $_[0]->{alive} // 0; }
    # 84.1 plan 03 (D-04): _soloistHealthTick's stop calls the REAL
    # SoloistDaemon::stop, which calls $self->_proc->die if alive -- must
    # actually flip alive to 0 or the tick's `!$helper->alive` assumption
    # (and the poll's next-tick dead-branch classification) never fires.
    sub die   { $_[0]->{alive} = 0; }
    sub pid   { return 12345; }
}

# startHelper()'s soloist branch needs a truthy client for ANY mac -- since
# _isStreamActive is overridden wholesale below, most of the client object's
# fields are never inspected. isSynced/name ARE inspected by
# deviceNameForClient() -- Phase 83.3 plan 09: a watchdog startHelper() call
# on an ALREADY-alive, name-unchanged helper (t/51 Case 12 step 2b) must
# reach the "alive fall-through" without tripping the name-change restart
# gate, which needs $client->isSynced()/name() to actually answer.
# 84.1 plan 03 (D-05): isPlaying/songElapsedSeconds/playingSong back the
# rising-LMS-time guard -- package globals so individual tests can `local`
# them without touching every other case's client stub.
our $IS_PLAYING = 0;
our $ELAPSED    = 0;
our $SONG_URL   = 'spoton://track:0000000000000000000000';
# 84.1-08 (WR-05, D-05): LMS returns the SAME Song object for one playing
# song -- a package-global so individual tests can swap in a NEW object
# (Case 28b) while every other case gets the same stable default.
our $PLAYING_SONG = bless {}, 'Test::FakePlayingSong';
{
    package Slim::Player::Client;
    sub getClient          { return bless {}, 'Slim::Player::Client' }
    sub isSynced            { return 0; }
    sub name                { return 'Test Player'; }
    sub isPlaying           { return $main::IS_PLAYING; }
    sub songElapsedSeconds  { return $main::ELAPSED; }
    sub playingSong         { return $main::PLAYING_SONG; }
}
{
    package Test::FakePlayingSong;
    sub track { return bless {}, 'Test::FakeTrack'; }
}
{
    package Test::FakeTrack;
    sub url { return $main::SONG_URL; }
}

# 84.1 plan 03 (D-04): a minimal Control double for _soloistHealthTick --
# only `observed` (a plain hashref the test manipulates directly) and
# `_execute` (records probe intents) are ever touched by the tick.
# @Test::FakeControl::EXECUTED is a plain package global (no `our` needed --
# it is used only via its fully-qualified name, both here and by callers).
{
    package Test::FakeControl;
    sub new      { my ($c, %a) = @_; return bless { %a }, $c; }
    sub observed { return $_[0]->{observed}; }
    sub _execute {
        my ($self, $intents) = @_;
        push @Test::FakeControl::EXECUTED, @$intents;
    }
}

our $STREAM_ACTIVE = 0;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::DaemonManager::_isStreamActive = sub { return $STREAM_ACTIVE; };
}

# Counting wrappers around DaemonManager::stopHelper/startHelper that still
# call the originals -- lets tests observe how many (re)starts actually
# happened without needing to peek at the private %helperInstances hash.
our $STOP_CALLS  = 0;
our $START_CALLS = 0;
{
    my $orig_stop  = \&Plugins::SpotOn::Unified::DaemonManager::stopHelper;
    my $orig_start = \&Plugins::SpotOn::Unified::DaemonManager::startHelper;
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::DaemonManager::stopHelper = sub {
        $STOP_CALLS++;
        goto &$orig_stop;
    };
    *Plugins::SpotOn::Unified::DaemonManager::startHelper = sub {
        $START_CALLS++;
        goto &$orig_start;
    };
}

my $DM = 'Plugins::SpotOn::Unified::DaemonManager';
# ============================================================
# 84-12 Task 2 (W2, revision 11): a dying LIBRESPOT helper. The credential
# check (GH #147, _handleCredentialCrash) stays AHEAD of the role dispatch:
# (i)  a non-credential tail -> Backend::Librespot->onDaemonExit consulted
#      exactly once, then the generic counted restart path runs;
# (ii) a credential tail -> _handleCredentialCrash runs and onDaemonExit is
#      NOT consulted.
# The helper is registered through startHelper's real librespot branch
# (backend=librespot, a credentials.json in a scratch cachedir).
# ============================================================
{
    # 84-09 (core half): the librespot role is the per-file MOCK (onDaemonExit ->
    # 'restart'); these cells pin DaemonManager's exit path, not the role. The
    # same cells over the REAL role: t/librespot/51_soloist_switch_librespot.t.
    require Plugins::SpotOn::Backend;
    Plugins::SpotOn::Backend::classFor('librespot');

    my $cachedir = tempdir(CLEANUP => 1);
    make_path("$cachedir/spoton");
    open(my $cf, '>', "$cachedir/spoton/credentials.json") or die "credentials.json: $!";
    print $cf '{}';
    close $cf;

    local $Slim::Utils::Prefs::FAKE_VALUES{backend}       = 'librespot';
    local $Slim::Utils::Prefs::FAKE_VALUES{cachedir}      = $cachedir;
    local $Slim::Utils::Prefs::FAKE_VALUES{activeAccount} = undef;

    my (@ode, @credCrash);
    my $origOde  = Plugins::SpotOn::Backend::Librespot->can('onDaemonExit');
    my $origCred = \&Plugins::SpotOn::Unified::DaemonManager::_handleCredentialCrash;
    no warnings 'redefine';
    local *Plugins::SpotOn::Backend::Librespot::onDaemonExit = sub {
        push @ode, $_[1]->mac;
        return $origOde ? $origOde->(@_) : 'restart';
    };
    local *Plugins::SpotOn::Unified::DaemonManager::_handleCredentialCrash = sub {
        push @credCrash, $_[1]->mac;
        goto &$origCred;
    };

    # (i) non-credential tail
    {
        my $mac = 'aa:bb:cc:dd:ee:51';
        my $helper = $DM->startHelper($mac);
        ok($helper && $helper->backendName eq 'librespot', "W2 (i) setup: startHelper registered a librespot helper for $mac");
        local $Plugins::SpotOn::Unified::Daemon::TAIL = 'thread main panicked: something unrelated';
        local $Plugins::SpotOn::API::Credentials::IS_CRED_ERROR = 0;
        $helper->alive(0);
        (@ode, @credCrash) = ();
        my $countBefore = $DM->_crashStateFor($mac)->{count} // 0;

        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

        is_deeply(\@ode, [$mac], "W2 (i): a non-credential librespot exit consults Backend::Librespot->onDaemonExit exactly once");
        is_deeply(\@credCrash, [], "W2 (i): no credential-crash handling for a non-credential tail");
        is($DM->_crashStateFor($mac)->{count}, $countBefore + 1,
            "W2 (i): the generic counted restart path ran (crash count +1, GH #147 backoff)");
        $DM->stopHelper($mac);
    }

    # (ii) credential tail
    {
        my $mac = 'aa:bb:cc:dd:ee:52';
        my $helper = $DM->startHelper($mac);
        ok($helper && $helper->backendName eq 'librespot', "W2 (ii) setup: startHelper registered a librespot helper for $mac");
        local $Plugins::SpotOn::Unified::Daemon::TAIL = 'Login5 rejected stored credentials';
        local $Plugins::SpotOn::API::Credentials::IS_CRED_ERROR = 1;
        $helper->alive(0);
        (@ode, @credCrash) = ();
        my $countBefore = $DM->_crashStateFor($mac)->{count} // 0;

        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

        is_deeply(\@credCrash, [$mac], "W2 (ii): a credential tail runs _handleCredentialCrash (GH #147)");
        is_deeply(\@ode, [], "W2 (ii): onDaemonExit is NOT consulted for a credential crash (the check stays ahead of the dispatch)");
        is($DM->_crashStateFor($mac)->{count} // 0, $countBefore, "W2 (ii): no counted restart for a credential crash");
        $DM->stopHelper($mac);
    }
}

done_testing();
