#!/usr/bin/perl
# 73-02 gap closure: behavioral coverage for the exit-code-10 (build expiry)
# escalation path. 73-VALIDATION.md flagged this as PARTIAL -- only a
# structural grep existed (t/28 Task 2 <verify> checks the strings
# 'spoton_soloist_expired'/'soloist_build_expired' are present in the source,
# but nothing ever drove the real code path with a mocked exit-code-10 daemon
# and asserted the gate actually blocks a re-spawn). This test drives the
# real DaemonManager::_soloistExitCode / _handleSoloistBuildExpiry /
# startHelper functions against a stateful Cache stub.
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Time::HiRes qw(sleep);

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

# STATEFUL cache stub (unlike t/28's always-undef stub) -- this is the point
# of this test: DaemonManager's module-level $cache is a real
# Slim::Utils::Cache->new(...) singleton, and _handleSoloistBuildExpiry's
# ->set() must be observable by startHelper()'s ->get() gate check on the
# SAME object.
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

# Stub: Slim::Networking::Select (Phase 83.3 plan 03: SoloistDaemon.pm now
# `use`s this at the top level for the D-06 smoke test's event-driven pipe
# read -- required for the module to load in this sandbox, even though this
# file never exercises smokeTest() itself)
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
sub new { return bless {}, shift }
# 84-08: DaemonManager keys its Soloist-only paths on backendName, not isa.
sub backendName { return 'librespot' }
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

unshift @INC, $stub_dir, $project_dir;

# Phase 83.3 plan 15 (G-83.3-3): push the LMS-bundled EV/Proc::Background onto
# @INC at LOWEST priority -- the stub dir (unshifted above) stays first, so
# every OTHER test in this file keeps resolving against the lightweight
# stubs. Section 1b below is the only place that needs the REAL EV/
# Proc::Background pair (to reproduce libev's actual child-reaping race under
# LMS's own default loop); require() still resolves the stub dir's fake
# modules first for everything else because @INC is searched in order.
my $lmsCpan = '/usr/share/squeezeboxserver/CPAN';
my ($pv) = (sprintf('%vd', $^V) =~ /^(\d+\.\d+)/);
# Deviation (Rule 1/3): arch/$pv/ holds one subdirectory PER bundled XS
# module (Audio/, DBD/, DBI/, Image/, JSON/, x86_64-linux-thread-multi/), not
# a single arch dir -- a bare `glob(...*/)` non-deterministically picks
# whichever sorts first (observed: "Audio" before "x86_64..."), which has no
# EV.so and silently defeats $HAVE_REAL_EV below. Select the one directory
# that actually contains EV's compiled object.
my ($lmsArch) = grep { -f "$_/auto/EV/EV.so" } glob("$lmsCpan/arch/$pv/*/");
push @INC, $lmsCpan;
push @INC, $lmsArch if $lmsArch;

my $HAVE_REAL_EV = eval { require EV; require Proc::Background; 1 } ? 1 : 0;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load the real Plugins::SpotOn::Soloist");

our $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
our $FAKE_HAS_KEY = 1;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Soloist::get    = sub { return $FAKE_BINARY };
    *Plugins::SpotOn::Soloist::hasKey = sub { return $FAKE_HAS_KEY };
}

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");

require_ok('Plugins::SpotOn::Unified::SoloistDaemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistDaemon");

# 84-12 Task 2: the exit-10 expiry handling lives in the Soloist role
# (Backend::Soloist->onDaemonExit returns an action word) and ONE generic
# DaemonManager dispatcher applies it (_applyExitAction). Every former
# direct _handleSoloistBuildExpiry call below goes through both.
require_ok('Plugins::SpotOn::Backend::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Backend::Soloist");
our @EXPIRE_ACTIONS;
sub expire_via_role {
    my ($helper) = @_;
    my $action = eval { Plugins::SpotOn::Backend::Soloist->onDaemonExit($helper, 10) };
    push @EXPIRE_ACTIONS, $action;
    return eval { Plugins::SpotOn::Unified::DaemonManager->_applyExitAction($helper, $action); 1 };
}

# ============================================================
# 1. _soloistExitCode() extracts exit code 10 from a dead Proc::Background
#    handle's wait() status word (status >> 8).
# ============================================================
{
    package Test::FakeProc;
    sub new   { my ($c, %a) = @_; return bless { %a }, $c; }
    sub wait  { return $_[0]->{status}; }
    sub alive { return $_[0]->{alive} // 0; }
    sub die   { }
    sub pid   { return 12345; }
}

{
    my $helper = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $helper->mac('aa:bb:cc:dd:ee:01');
    $helper->_proc(Test::FakeProc->new(status => 10 << 8, alive => 0));

    is(
        eval { Plugins::SpotOn::Backend::Soloist::_exitCode(
            $helper
        ) },
        10,
        "_soloistExitCode() decodes exit code 10 from the wait() status word"
    );
}

# ============================================================
# 1b. Real forked children under LMS's own EV loop (Phase 83.3 plan 15,
#     G-83.3-3): libev's default loop reaps every child via waitpid(-1) as
#     soon as it exits (EV.pm POD), so Proc::Background's own wait() finds
#     the process already gone and reports a fabricated (1, 0) -- Unix.pm
#     :185-187, "already reaped, exit status unknown". These cases drive
#     REAL Proc::Background-spawned children under a REAL EV::run loop
#     (both loaded from the LMS-bundled CPAN tree pushed onto @INC above)
#     to prove _watchExit/exitCode capture the real status before libev's
#     reaping can lose it. SKIP only when neither resolved (no LMS CPAN tree
#     on this host) -- the plan's gate asserts this section RAN, not skipped.
# ============================================================
SKIP: {
    skip "real EV/Proc::Background not available (tried $lmsCpan"
        . ($lmsArch ? " and $lmsArch" : ", no matching arch dir found") . ")", 10
        unless $HAVE_REAL_EV;

    can_ok('Plugins::SpotOn::Unified::SoloistDaemon', qw(_watchExit exitCode _exitStatus))
        or diag("RED: _watchExit/exitCode/_exitStatus not yet implemented on SoloistDaemon");

    # -- real child, EV loop: exit 10 is captured by the watcher before
    #    libev's own reaping can lose it (the pre-fix defect, reproduced) --
    {
        my $helper = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
        $helper->mac('aa:bb:cc:dd:ee:20');
        my $proc = Proc::Background->new({ 'die_upon_destroy' => 1 }, '/bin/sh', '-c', 'exit 10');

        ok(eval { $helper->_watchExit($proc); 1 }, "real child: _watchExit runs")
            or diag("RED: $@");

        if ($helper->can('_exitStatus')) {
            my $deadline = time + 5;
            my $tick = EV::timer(0.2, 0.2, sub {});
            EV::run(EV::RUN_ONCE()) while !defined(eval { $helper->_exitStatus }) && time < $deadline;
        }

        my $st = eval { $helper->_exitStatus };
        is(defined $st ? $st >> 8 : undef, 10,
            "real child: the EV::child watcher recorded exit status 10 before libev could lose it");

        my $code = eval {
            eval { Plugins::SpotOn::Backend::Soloist::_exitCode(
                $helper
            ) };
        };
        is($code, 10,
            "real child: _soloistExitCode() reports 10 via the watcher-recorded status");

        my $pbWait = eval { $proc->wait };
        is(defined $pbWait ? $pbWait >> 8 : undef, 0,
            "real child: Proc::Background's own wait() alone lost the status (0) -- documents why the watcher exists");
    }

    # -- Proc::Background reaps first (alive() called before the loop runs):
    #    exitCode() must fall back to Proc::Background's own wait() --
    {
        my $helper = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
        $helper->mac('aa:bb:cc:dd:ee:21');
        my $proc = Proc::Background->new({ 'die_upon_destroy' => 1 }, '/bin/sh', '-c', 'exit 10');

        ok(eval { $helper->_watchExit($proc); 1 }, "real child: Proc::Background reaps first -- _watchExit runs")
            or diag("RED: $@");

        sleep(0.3);
        $proc->alive;    # Proc::Background reaps the child HERE, before EV::run ever ran

        my $code = eval { $helper->exitCode($proc) };
        is($code, 10,
            "real child: Proc::Background reaps first -- exitCode() falls back to Proc::Background's wait() and still reports 10");

        my $st = eval { $helper->_exitStatus };
        ok(!defined $st,
            "real child: Proc::Background reaps first -- the watcher never fired, _exitStatus stays undef");
    }

    # -- exit 1 is not 10; a fresh _watchExit resets stale recorded state --
    {
        my $helper = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
        $helper->mac('aa:bb:cc:dd:ee:22');
        my $proc1 = Proc::Background->new({ 'die_upon_destroy' => 1 }, '/bin/sh', '-c', 'exit 1');

        ok(eval { $helper->_watchExit($proc1); 1 }, "real child: exit 1 is not 10 -- _watchExit runs")
            or diag("RED: $@");
        if ($helper->can('_exitStatus')) {
            my $deadline = time + 5;
            my $tick = EV::timer(0.2, 0.2, sub {});
            EV::run(EV::RUN_ONCE()) while !defined(eval { $helper->_exitStatus }) && time < $deadline;
        }
        my $code1 = eval { $helper->exitCode($proc1) };
        is($code1, 1,
            "real child: exit 1 is not 10 -- exitCode() reports 1, not a stale 10");

        my $proc2 = Proc::Background->new({ 'die_upon_destroy' => 1 }, '/bin/sh', '-c', 'exit 10');
        ok(eval { $helper->_watchExit($proc2); 1 },
            "real child: exit 1 is not 10 -- a second _watchExit on a new child resets recorded status")
            or diag("RED: $@");
        if ($helper->can('_exitStatus')) {
            my $deadline = time + 5;
            my $tick = EV::timer(0.2, 0.2, sub {});
            EV::run(EV::RUN_ONCE()) while !defined(eval { $helper->_exitStatus }) && time < $deadline;
        }
        my $code2 = eval { $helper->exitCode($proc2) };
        is($code2, 10,
            "real child: exit 1 is not 10 -- the second child's own exit code (10) is recorded, not the first child's leaking through");
    }
}

# ============================================================
# 1c. SoloistDaemon's _pollWsPort on_exhausted DEAD branch must classify
#     exit code 10 BEFORE D-07's startup-failure decision (Phase 83.3 plan
#     15, G-83.3-3 part (b) / Task 2) -- an expired build dying before it
#     ever announces ws.port is D-03's case, never D-07's rollback.
# ============================================================

{
    package Slim::Player::Client;
    sub getClient { return bless {}, 'Slim::Player::Client' }
    sub isSynced  { return 0; }
    sub name      { return 'Test Player 1c'; }
}

# -- exit 10 before ws.port: renews once, never calls noteStartupFailure,
#    and parks the daemon --
# Phase 83.3 plan 17 (WR-03): noteExpiredExit now refuses ANY unregistered
# helper, not only a stale/superseded one (see the unregistered block
# below) -- this exit-10 path funnels through noteExpiredExit, so the
# helper under test must be the CURRENTLY registered instance for its
# mac, exactly as production always has it (the timer that calls
# _pollWsPort only ever fires on the object startHelper already stored
# in %helperInstances). Registered the same way the stale-object test
# below does: via a real startHelper() call with SoloistDaemon::new
# overridden to hand back a controllable double.
{
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');

    my $mac1c1 = 'aa:bb:cc:dd:ee:30';
    my $helper;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::SoloistDaemon::new = sub {
            my ($class, $id) = @_;
            my $self = bless [], $class;
            $self->mac($id);
            $self->name('Test Player 1c1');
            $self->_wsPortPollAttempts(0);
            $self->_proc(Test::FakeProc->new(alive => 1));    # alive at registration time
            return $self;
        };
        # startHelper()'s own final check (`return $helper if ... alive`)
        # requires the helper to be ALIVE at registration time -- the exit
        # only happens below, after registration, exactly like t/51's
        # Case 16/19/20 pattern (construct alive, then swap _proc to dead).
        $helper = Plugins::SpotOn::Unified::DaemonManager->startHelper($mac1c1);
    }
    ok($helper, "before ws.port: exit-10 precondition -- startHelper registered a helper for $mac1c1");

    $helper->_proc(Test::FakeProc->new(status => 0, alive => 0));    # wait() returns 0 -- the libev-loss shape

    ok(eval { $helper->_exitStatus(10 << 8); 1 },
        "before ws.port: exit status recorded on the object (exit 10)");

    my (@renewCalls1c1, $nsfCalls1c1);
    $nsfCalls1c1 = 0;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @renewCalls1c1, \%opts;
        return 'started';
    };
    local *Plugins::SpotOn::Unified::DaemonManager::noteStartupFailure = sub { $nsfCalls1c1++; };

    # 84-12 Task 2 (W1): noteExpiredExit (the SoloistDaemon.pm exit-10-before-
    # ws.port caller) consults the helper's own role, once, with exit 10.
    my @ode1c1;
    my $origOde = Plugins::SpotOn::Backend::Soloist->can('onDaemonExit');
    local *Plugins::SpotOn::Backend::Soloist::onDaemonExit = sub {
        push @ode1c1, $_[2];
        return $origOde ? $origOde->(@_) : 'restart';
    };

    my $tempDir1c1 = tempdir(CLEANUP => 1);    # empty -- ws.port never written
    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($helper, $tempDir1c1);

    is(scalar(@renewCalls1c1), 1,
        "before ws.port: exit code 10 triggers exactly one renewal attempt");
    is($nsfCalls1c1, 0,
        "before ws.port: exit code 10 does NOT call noteStartupFailure");
    ok(Slim::Utils::Cache->new('spoton', 1)->get('spoton_soloist_expired'),
        "before ws.port: exit code 10 sets the park flag");
    is_deeply(\@ode1c1, [10],
        "84-12 (W1): noteExpiredExit consults Backend::Soloist->onDaemonExit exactly once, with exit 10");
    ok(!(grep { $_ == $helper } Plugins::SpotOn::Unified::DaemonManager->helperInstances),
        "84-12 (W1): the parked helper is deregistered (dispatcher stopHelper, no restart)");
}

# -- exit 1 (not 10) before ws.port: unchanged D-07 path -- noteStartupFailure
#    fires, no renewal, no park flag --
{
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');

    my $helper = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $helper->mac('aa:bb:cc:dd:ee:31');
    $helper->_wsPortPollAttempts(0);
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));

    ok(eval { $helper->_exitStatus(1 << 8); 1 },
        "before ws.port: exit status recorded on the object (exit 1)");

    my (@renewCalls1c2, $nsfCalls1c2);
    $nsfCalls1c2 = 0;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @renewCalls1c2, \%opts;
        return 'started';
    };
    local *Plugins::SpotOn::Unified::DaemonManager::noteStartupFailure = sub { $nsfCalls1c2++; };

    my $tempDir1c2 = tempdir(CLEANUP => 1);
    Plugins::SpotOn::Unified::SoloistDaemon::_pollWsPort($helper, $tempDir1c2);

    is($nsfCalls1c2, 1,
        "before ws.port: exit code 1 (not 10) calls noteStartupFailure exactly once");
    is(scalar(@renewCalls1c2), 0,
        "before ws.port: exit code 1 (not 10) does NOT trigger a renewal");
    ok(!Slim::Utils::Cache->new('spoton', 1)->get('spoton_soloist_expired'),
        "before ws.port: exit code 1 (not 10) does NOT set the park flag");
}

# -- stale object: noteExpiredExit refuses a helper that is not the
#    CURRENTLY registered instance for its mac --
{
    my $mac = 'aa:bb:cc:dd:ee:33';
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');

    my $registered;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::SoloistDaemon::new = sub {
            my ($class, $id) = @_;
            my $self = bless [], $class;
            $self->mac($id);
            $self->name('Test Player 1c');
            $self->_proc(Test::FakeProc->new(alive => 1));
            return $self;
        };
        $registered = Plugins::SpotOn::Unified::DaemonManager->startHelper($mac);
    }
    ok($registered,
        "before ws.port: stale-object precondition -- startHelper registered a live helper for $mac");

    my $stale = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $stale->mac($mac);

    my @renewCalls1c3;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @renewCalls1c3, \%opts;
        return 'started';
    };

    my $r;
    ok(eval { $r = Plugins::SpotOn::Unified::DaemonManager->noteExpiredExit($stale); 1 },
        "before ws.port: noteExpiredExit callable");
    is($r, 0,
        "before ws.port: noteExpiredExit refuses a stale (non-registered) object and returns 0");
    is(scalar(@renewCalls1c3), 0,
        "before ws.port: a stale object's noteExpiredExit triggers no renewal");

    Plugins::SpotOn::Unified::DaemonManager->stopHelper($mac);    # cleanup -- don't leak into later sections
}

# -- unregistered: noteExpiredExit refuses a helper whose mac has NO
#    registration at all (not merely a stale/superseded one) --
{
    my $mac = 'aa:bb:cc:dd:ee:34';
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');

    my $unregistered = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $unregistered->mac($mac);

    my @renewCallsUnreg;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @renewCallsUnreg, \%opts;
        return 'started';
    };

    my $r;
    ok(eval { $r = Plugins::SpotOn::Unified::DaemonManager->noteExpiredExit($unregistered); 1 },
        "before ws.port: noteExpiredExit callable on an unregistered helper");
    is($r, 0,
        "before ws.port: noteExpiredExit refuses an unregistered helper and returns 0");
    is(scalar(@renewCallsUnreg), 0,
        "before ws.port: an unregistered helper triggers no renewal");
    ok(!Slim::Utils::Cache->new('spoton', 1)->get('spoton_soloist_expired'),
        "before ws.port: an unregistered helper sets no park flag");
}

# ============================================================
# 2. _handleSoloistBuildExpiry() sets the 'never'-TTL escalation flag and
#    stops the daemon (real stopHelper -- registered via %helperInstances
#    which is only reachable through startHelper(), so we drive it that way
#    below in step 3 instead of poking the private hash directly).
# ============================================================
{
    my $mac = 'aa:bb:cc:dd:ee:02';
    my $helper = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $helper->mac($mac);
    $helper->_proc(Test::FakeProc->new(status => 10 << 8, alive => 0));

    # Phase 83.3 plan 03 (D-03): _handleSoloistBuildExpiry now also starts a
    # renewal immediately. Glob-override the real renewBinary (rather than
    # letting it run for real against the stubbed SimpleAsyncHTTP, which
    # would leave a renewal permanently "downloading" in this file's Cache
    # stub) so this step can assert the exit10 trigger in isolation.
    our @RENEW_CALLS;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @RENEW_CALLS, \%opts;
        return 'started';
    };

    main::expire_via_role($helper);

    # No accessor is exported for the private $cache singleton -- its effect
    # is asserted the way production code observes it: through
    # startHelper()'s gate below (step 3), which is the actual behavioral
    # requirement (gap 1a: "block re-spawn").
    is($EXPIRE_ACTIONS[-1], 'renew', "84-12: Backend::Soloist->onDaemonExit(exit 10) answers 'renew' (park + one renewal attempt, no restart series)");

    is(scalar(@RENEW_CALLS), 1,
        "83.3-03 (D-03): _handleSoloistBuildExpiry triggers exactly one renewal attempt");
    is($RENEW_CALLS[0]{reason}, 'exit10',
        "83.3-03 (D-03): the triggered renewal carries reason => 'exit10'");

    # ============================================================
    # 83.3 plan 08 (gap 2, WR-01): the exit-10 trigger now routes through
    # checkRenewalDue(), so it obeys the same daily RENEWAL_RETRY_S floor as
    # every other renewal path -- a repeat exit-10 within 24h of the last
    # attempt must NOT start a second download; the daemon stays down.
    # ============================================================
    Plugins::SpotOn::Soloist::_setRenewalState(last_attempt_at => time());
    main::expire_via_role($helper);
    is(scalar(@RENEW_CALLS), 1,
        "83.3-08 (gap 2): a second exit-10 within the daily retry floor triggers NO second download");

    Plugins::SpotOn::Soloist::_setRenewalState(last_attempt_at => time() - 86401);
    main::expire_via_role($helper);
    is(scalar(@RENEW_CALLS), 2,
        "83.3-08 (gap 2): past the daily retry floor, a repeat exit-10 DOES start another attempt");
    is($RENEW_CALLS[-1]{reason}, 'exit10',
        "83.3-08 (gap 2): the throttled retry still carries reason => 'exit10'");

    # ============================================================
    # 83.3-11 (D-03, WR-01, gap-closure round 2): the exit-10 that SETS the
    # park flag must renew immediately even when a D-01 daily same_version
    # attempt stamped last_attempt_at within the last hour -- this is the
    # REALISTIC sequence on the day the build genuinely expires (14 days of
    # daily same_version attempts precede it), not the "no attempt in 24h"
    # case the assertions above exercise.
    # ============================================================
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');
    Plugins::SpotOn::Soloist::_setRenewalState(phase => 'same_version', last_attempt_at => time() - 3600);

    my $before = scalar(@RENEW_CALLS);
    main::expire_via_role($helper);
    is(scalar(@RENEW_CALLS) - $before, 1,
        "83.3-11 (D-03, WR-01): exit-10 after a fresh D-01 attempt still renews immediately (flag-transition bypass)");
    is($RENEW_CALLS[-1]{reason}, 'exit10',
        "83.3-11 (D-03, WR-01): the immediate bypass renewal carries reason => 'exit10'");

    # Opposite-direction pin (plan 08's loop fix must stay in force): an
    # immediate repeat with the flag now SET must NOT start a second
    # download -- the one-hour-old last_attempt_at from above is untouched
    # (the t/33 renewBinary recorder never writes last_attempt_at), so the
    # floor is still closed on this second call.
    main::expire_via_role($helper);
    is(scalar(@RENEW_CALLS) - $before, 1,
        "83.3-11 (D-03, WR-01): an immediate repeat with the flag already set does NOT start a second download");

    is(Plugins::SpotOn::Soloist::checkRenewalDue(), 'retry_wait',
        "83.3-11 (D-03, WR-01): a watchdog-shaped checkRenewalDue() call (no options) still respects the daily floor while the flag is set");

    # ============================================================
    # 83.3-REVIEW round 2 (WR-01, round-1 IN-02 re-issued): a park-flag
    # record with version => undef (the fixed DaemonManager write --
    # 'unknown' is no longer stored in the record) must NOT be cleared by a
    # read-only _versionCheck() probe of the SAME file (matching mtime).
    # Before the fix, DaemonManager stored the STRING 'unknown' and
    # Soloist::_versionCheck compared it unconditionally
    # ('unknown' ne '1.3.8.70' is always true), clearing the flag on every
    # probe and re-arming plan 11's one-shot bypass on every watchdog tick --
    # exactly the un-throttled download loop plan 08 intended to close.
    # ============================================================
    {
        my $probe_dir  = tempdir(CLEANUP => 1);
        my $same_file  = "$probe_dir/soloist";
        open(my $fh, '>', $same_file) or die "cannot write fake binary: $!";
        print $fh "#!/bin/sh\n";
        print $fh "if [ \"\$1\" = '--version' ]; then\n";
        print $fh "  echo 'soloist 1.3.8.70 build 1790143294 (20260923) (g5c3a2053ac) (linux/x86_64)'\n";
        print $fh "  exit 0\n";
        print $fh "fi\n";
        print $fh "exit 1\n";
        close($fh);
        chmod(0755, $same_file);
        my $same_mtime = (stat($same_file))[9];

        my $flagcache = Slim::Utils::Cache->new('spoton', 1);

        # Case A: version => undef (the fixed write), SAME mtime -> the probe
        # must NOT clear the flag.
        $flagcache->set('spoton_soloist_expired',
            { version => undef, mtime => $same_mtime, at => time() }, 'never');
        ok(Plugins::SpotOn::Soloist::_versionCheck($same_file),
            "WR-01: _versionCheck() accepts the probed binary (version 1.3.8.70, above the x86_64 pin)");
        ok($flagcache->get('spoton_soloist_expired'),
            "WR-01: a version=>undef flag record survives a same-mtime re-probe of the SAME file (fix: no placeholder comparison)");

        # Opposite-direction pin: a DEFINED, genuinely differing version must
        # still clear the flag -- the fix must not become "never clears while
        # a version is present but stale".
        $flagcache->set('spoton_soloist_expired',
            { version => '1.3.8.60', mtime => $same_mtime, at => time() }, 'never');
        ok(Plugins::SpotOn::Soloist::_versionCheck($same_file),
            "WR-01 opposite-direction: probe still accepts the binary");
        ok(!$flagcache->get('spoton_soloist_expired'),
            "WR-01 opposite-direction: a flag with a DEFINED, genuinely differing version is still cleared");

        # Opposite-direction pin: version => undef but a DIFFERENT mtime (a
        # replaced file) must still clear -- the mtime arm of the OR must keep
        # working when the version field can't tell files apart.
        $flagcache->set('spoton_soloist_expired',
            { version => undef, mtime => $same_mtime - 1, at => time() }, 'never');
        ok(Plugins::SpotOn::Soloist::_versionCheck($same_file),
            "WR-01 opposite-direction: probe still accepts the binary");
        ok(!$flagcache->get('spoton_soloist_expired'),
            "WR-01 opposite-direction: a version=>undef flag with a DIFFERENT mtime is still cleared (replaced file)");

        # Restore the SAME-mtime, version=>undef record (flag "still set", as
        # Case A leaves it) and confirm the end-to-end consequence: a repeat
        # _handleSoloistBuildExpiry() call sees $wasParked=1, passes
        # bypass_retry_floor=>0, and issues NO further renewBinary call --
        # before the fix, Case A above would have cleared the flag, so this
        # call would have seen $wasParked=0 and bypassed the floor again
        # (plan 08's un-throttled loop, one CDN download per watchdog tick).
        $flagcache->set('spoton_soloist_expired',
            { version => undef, mtime => $same_mtime, at => time() }, 'never');
        my $before_wr01 = scalar(@RENEW_CALLS);
        main::expire_via_role($helper);
        is(scalar(@RENEW_CALLS) - $before_wr01, 0,
            "WR-01: with the flag surviving the probe, a repeat exit-10 triggers NO renewal (loop closed)");
    }
}

# ============================================================
# 83.3-REVIEW round 2 (WR-03): the exit-10 bypass decision must survive a
# die() inside noteActiveBinaryExpired() -- the park-flag TRANSITION
# ($cache->set() inside _handleSoloistBuildExpiry) is already committed by
# the time noteActiveBinaryExpired() runs, so a die there must not cost the
# bypass. Opposite-direction pin (plan 08's loop must not return): a REPEAT
# exit-10 with the flag already set must still respect the retry floor even
# though noteActiveBinaryExpired() dies again.
# ============================================================
{
    my $mac2    = 'aa:bb:cc:dd:ee:07';
    my $helper2 = bless [], 'Plugins::SpotOn::Unified::SoloistDaemon';
    $helper2->mac($mac2);
    $helper2->_proc(Test::FakeProc->new(status => 10 << 8, alive => 0));

    # Start from a clean park flag and a CLOSED retry floor (recent
    # same_version attempt) -- the realistic "build genuinely expired"
    # sequence, so only the transition bypass can explain a renewBinary call.
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');
    Plugins::SpotOn::Soloist::_setRenewalState(phase => 'same_version', last_attempt_at => time() - 3600);

    our @RENEW_CALLS_WR03;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @RENEW_CALLS_WR03, \%opts;
        return 'started';
    };
    local *Plugins::SpotOn::Soloist::noteActiveBinaryExpired = sub {
        die "simulated noteActiveBinaryExpired failure (WR-03)\n";
    };

    main::expire_via_role($helper2);
    is(scalar(@RENEW_CALLS_WR03), 1,
        "WR-03: a first exit-10 still bypasses the retry floor and renews immediately even though noteActiveBinaryExpired() died");

    main::expire_via_role($helper2);
    is(scalar(@RENEW_CALLS_WR03), 1,
        "WR-03 opposite-direction: a repeat exit-10 (flag already set) still respects the floor even though noteActiveBinaryExpired() died again (plan 08's loop does not return)");
}

# ============================================================
# 3. THE GAP: startHelper() must refuse to spawn while the expiry flag is
#    set -- this is the actual re-spawn-blocking behavior UAT gap 1a asked
#    for. Prereqs are otherwise fully satisfied (binary present, key
#    present, Linux) so if the gate did NOT block, startHelper would
#    proceed straight into daemon creation.
# ============================================================
{
    my $result = Plugins::SpotOn::Unified::DaemonManager->startHelper('aa:bb:cc:dd:ee:03');

    is(
        $result,
        undef,
        "startHelper() refuses to spawn a new Soloist daemon once the exit-code-10 escalation flag is set (gap 1a: re-spawn blocked)"
    );
}

# ============================================================
# 4. Confirm the gate is SPECIFICALLY the expiry flag, not just "soloist
#    always refuses" -- clearing the flag (simulating Soloist::_versionCheck's
#    self-heal) must let startHelper's prereq check reach 'soloist_ready'
#    again. We don't drive a full daemon spawn (requires a live client +
#    real port polling); we assert the prereq classification directly,
#    which is the exact same code path startHelper's gate reads.
# ============================================================
{
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_ready',
        "prereq state is 'soloist_ready' before any expiry flag is set (control case)"
    );
}

# ============================================================
# 5. Phase 82 Plan 44 (D-09/D-10/D-11, Runde 44) -- the NEW public
#    backendPrereqState($class,$backend) wrapper, unlike the private
#    _backendPrereqState checked above, DOES consult the
#    spoton_soloist_expired cache flag (it moved that ternary out of
#    startHelper's inline body, see DaemonManager.pm). At this point in
#    the file the flag is still SET from step 2's
#    _handleSoloistBuildExpiry call -- Fall Expired asserts that.
#    Must-fail proof: a backendPrereqState that just forwarded to
#    _backendPrereqState (skipping the cache check) would make Fall
#    Expired red (it would return 'soloist_ready' instead of
#    'soloist_build_expired').
# ============================================================
{
    is(
        Plugins::SpotOn::Unified::DaemonManager->backendPrereqState('soloist'),
        'soloist_build_expired',
        "Fall Expired: backendPrereqState('soloist') == 'soloist_build_expired' while the cache flag is set"
    );
}

# ============================================================
# 6. Same wrapper, flag cleared (simulating Soloist::_versionCheck's
#    self-heal) -- must fall through to the plain prereq check and report
#    'soloist_ready' again, same as step 4's control case for the private
#    function.
# ============================================================
{
    Slim::Utils::Cache->new('spoton', 1)->remove('spoton_soloist_expired');
    is(
        Plugins::SpotOn::Unified::DaemonManager->backendPrereqState('soloist'),
        'soloist_ready',
        "Fall Ready: backendPrereqState('soloist') == 'soloist_ready' once the cache flag is cleared"
    );
}

done_testing();
