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

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load the real Plugins::SpotOn::Soloist");

our $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
our $FAKE_HAS_KEY = 1;
our @ROLLBACK_CALLS;
our $ROLLBACK_RESULT = [1, '1.3.8.68'];
our @RENEW_CALLS;
# 84.1 plan 03 (D-04, T-84.1-21): whether the current MAC has ever been
# paired in the Spotify app -- t/51 loads the REAL Soloist.pm (unlike its
# own isPairedForClient, which does a real opendir) and overrides by glob,
# same idiom as get/hasKey above. Defaults to paired (1); individual Cases
# `local` it to 0 to exercise the never-paired exemption.
our $PAIRED_ON_DISK = 1;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Soloist::get    = sub { return $FAKE_BINARY };
    *Plugins::SpotOn::Soloist::hasKey = sub { return $FAKE_HAS_KEY };
    *Plugins::SpotOn::Soloist::rollbackToPrevious = sub {
        my (%opts) = @_;
        push @ROLLBACK_CALLS, \%opts;
        return @$ROLLBACK_RESULT;
    };
    *Plugins::SpotOn::Soloist::renewBinary = sub {
        my (%opts) = @_;
        push @RENEW_CALLS, \%opts;
        return 'started';
    };
    *Plugins::SpotOn::Soloist::isPairedForClient = sub { return $PAIRED_ON_DISK; };
}

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");

require_ok('Plugins::SpotOn::Unified::SoloistDaemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistDaemon");

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

# Avoids the real, LMS-client-dependent SoloistDaemon::start() path entirely
# -- startHelper()'s construction branch calls this ::new() directly, and
# the REAL mk_accessor-built accessors (mac/_proc/alive) still work on the
# resulting object since we only replace the constructor, not the class.
# name() is set to match Slim::Player::Client::name() above so a later
# startHelper() call on this same still-alive helper (the 60s watchdog
# shape, Case 12 step 2b) takes the alive fall-through instead of the
# name-change restart gate.
# 84.1 plan 03 (D-04): _startTimes([time()]) mirrors what the REAL new()
# ends up with after its own start() pushes an entry (SoloistDaemon.pm:129
# -132) -- without it, uptime() dereferences an undef _startTimes and every
# alive Soloist helper here would crash the instant _soloistHealthTick (now
# called unconditionally from the poll's alive path) reads ->uptime.
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::SoloistDaemon::new = sub {
        my ($class, $id) = @_;
        my $self = bless [], $class;
        $self->mac($id);
        $self->name('Test Player');
        $self->_proc(Test::FakeProc->new(alive => 1));
        $self->_startTimes([ time() ]);
        return $self;
    };
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
# Task 1 (D-02): pending entry -> watchdog -> not playing -> stop/start ->
# switchedAt
# ============================================================

# Case 1: startHelper registers an alive Soloist helper; onSoloistBinary
# Replaced marks it pending.
{
    my $mac = 'aa:bb:cc:dd:ee:01';
    my $helper = $DM->startHelper($mac);
    ok($helper, "Case 1: startHelper registers an alive Soloist helper for $mac");

    $DM->onSoloistBinaryReplaced({ version => '1.3.8.70' });
    my $pending = $DM->pendingBinarySwitches;
    ok(exists $pending->{$mac}, "Case 1: pendingBinarySwitches has an entry for $mac");
    is($pending->{$mac}{version}, '1.3.8.70', "Case 1: the pending entry carries the new version");
}

# Case 2: stream active -- switch deferred, no stop/start, no switchedAt.
{
    my $mac = 'aa:bb:cc:dd:ee:01';
    $STREAM_ACTIVE = 1;

    my ($stop_before, $start_before) = ($STOP_CALLS, $START_CALLS);
    $DM->_processPendingSwitches;

    my $pending = $DM->pendingBinarySwitches;
    ok(exists $pending->{$mac}, "Case 2: entry remains pending while the stream is active");
    is($STOP_CALLS,  $stop_before,  "Case 2: stopHelper NOT called");
    is($START_CALLS, $start_before, "Case 2: startHelper NOT called");
    is($DM->switchedAtFor($mac), undef, "Case 2: switchedAtFor is still undef");
}

# Case 3: stream idle -- switch executes, entry gone, switchedAt recorded,
# crash state reset.
{
    my $mac = 'aa:bb:cc:dd:ee:01';
    $STREAM_ACTIVE = 0;

    my ($stop_before, $start_before) = ($STOP_CALLS, $START_CALLS);
    my $now_before = time();
    $DM->_processPendingSwitches;

    is($STOP_CALLS,  $stop_before + 1,  "Case 3: stopHelper called exactly once");
    is($START_CALLS, $start_before + 1, "Case 3: startHelper called exactly once");

    my $pending = $DM->pendingBinarySwitches;
    ok(!exists $pending->{$mac}, "Case 3: the pending entry is gone");

    my $switchedAt = $DM->switchedAtFor($mac);
    ok(defined $switchedAt, "Case 3: switchedAtFor is now defined");
    ok(abs($switchedAt - $now_before) <= 2, "Case 3: switchedAtFor is within 2s of now");

    my $state = $DM->_crashStateFor($mac);
    is($state->{count}, 0, "Case 3: crash state count reset to 0 by the switch");

    # Cleanup: stop the now-alive helper so it doesn't leak into later
    # cases' _streamAlivePoll()/rollback-fan-out assertions (test hygiene
    # only -- this hash has no reset_env() equivalent to call).
    $DM->stopHelper($mac);
}

# Case 4: a pending entry for a mac with no helper -- entry gone, switchedAt
# set, no stop/start.
{
    my $mac = 'aa:bb:cc:dd:ee:04';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.70' });
    # Simulate "no helper" WITHOUT touching %pendingBinarySwitch directly
    # (it's private): stopHelper removes the helper from %helperInstances
    # but never touches the pending-switch entry onSoloistBinaryReplaced
    # already recorded.
    $DM->stopHelper($mac);

    my ($stop_before, $start_before) = ($STOP_CALLS, $START_CALLS);
    $DM->_processPendingSwitches;

    my $pending = $DM->pendingBinarySwitches;
    ok(!exists $pending->{$mac}, "Case 4: the pending entry is gone");
    ok(defined $DM->switchedAtFor($mac), "Case 4: switchedAtFor is set even with no helper to restart");
    is($STOP_CALLS,  $stop_before,  "Case 4: stopHelper NOT called (no helper existed)");
    is($START_CALLS, $start_before, "Case 4: startHelper NOT called (no helper existed)");
}

# ============================================================
# Task 2 (D-07): _rollbackDue, noteStartupFailure, _rollbackAfterSwitch
# ============================================================

# Case 5: _rollbackDue() truth table (pure function). Phase 83.3 plan 13
# (D-07, WR-02): _rollbackDue reads switch_crashes, D-07's own counter --
# never the GH #147 backoff counter `count` (which the re-anchor must be
# free to leave untouched without ever re-arming a rollback by accident).
{
    my $now = time();
    is($DM->_rollbackDue({ switch_crashes => 3 }, $now - 100, $now), 1,
        "Case 5: switch_crashes=3, switched 100s ago -> due");
    is($DM->_rollbackDue({ switch_crashes => 3 }, $now - 1801, $now), 0,
        "Case 5: switch_crashes=3, switched 1801s ago -> NOT due (outside the window)");
    is($DM->_rollbackDue({ switch_crashes => 2 }, $now - 100, $now), 0,
        "Case 5: switch_crashes=2, switched 100s ago -> NOT due (below the crash threshold)");
    is($DM->_rollbackDue({ switch_crashes => 5 }, undef, $now), 0,
        "Case 5: switch_crashes=5, no switch recorded -> NOT due (nothing to roll back from)");
    is($DM->_rollbackDue({ count => 5, switch_crashes => 1 }, $now - 100, $now), 0,
        "Case 5: count=5 switch_crashes=1, switched 100s ago -> NOT due (a high backoff count alone never triggers criterion (b), WR-02)");
}

# Case 6: 3rd crash within 30 minutes of a switch triggers a rollback and
# skips this iteration's startHelper.
{
    my $mac = 'aa:bb:cc:dd:ee:06';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.70' });
    $DM->_processPendingSwitches;    # sets switchedAt{$mac} = now (Case 3 flow)
    ok(defined $DM->switchedAtFor($mac), "Case 6 setup: switchedAt recorded");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1

    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 2, last_crash_at => time() - 10, next_allowed_at => 0, switch_crashes => 2);

    my ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    # 84-12 Task 2: the rollback reaches the binary through the Soloist role.
    require Plugins::SpotOn::Backend::Soloist;
    my @roleRollback;
    my $origRb = Plugins::SpotOn::Backend::Soloist->can('rollbackBinary');
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::Soloist::rollbackBinary = sub {
            my ($cls, %a) = @_;
            push @roleRollback, $a{reason};
            return $origRb ? $origRb->($cls, %a) : (0, 'role_has_no_rollbackBinary');
        };
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    }
    is(scalar(@roleRollback), 1, "Case 6 (84-12): Backend::Soloist->rollbackBinary called exactly once");
    like($roleRollback[0] // '', qr/\S/, "Case 6 (84-12): rollbackBinary carries the reason");

    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1, "Case 6: rollback recorder called exactly once");
    is($START_CALLS, $start_before, "Case 6: startHelper NOT called in that iteration");
    is($DM->switchedAtFor($mac), undef, "Case 6: switchedAtFor cleared after the rollback");

    $DM->stopHelper($mac);    # test hygiene -- keep later cases' helper counts isolated
}

# Case 7: exit code 10 takes the D-03 renewal path, NOT the rollback path
# (structural exclusion -- classified before the backoff branch).
{
    my $mac = 'aa:bb:cc:dd:ee:07';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.70' });
    $DM->_processPendingSwitches;
    ok(defined $DM->switchedAtFor($mac), "Case 7 setup: switchedAt recorded");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 10 << 8, alive => 0));    # dead, rc=10

    my ($rb_before, $renew_before) = (scalar(@ROLLBACK_CALLS), scalar(@RENEW_CALLS));
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is(scalar(@RENEW_CALLS) - $renew_before, 1, "Case 7: exactly one renewBinary call (D-03)");
    is($RENEW_CALLS[-1]{reason}, 'exit10', "Case 7: the renewal reason is 'exit10'");
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 0, "Case 7: rollback recorder NOT called");

    # _handleSoloistBuildExpiry sets the 'never'-TTL expired flag -- clear it
    # (mirrors _versionCheck's real self-heal) so later cases' startHelper
    # calls still see backendPrereqState() == 'soloist_ready'.
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_expired');
}

# Case 8a: noteStartupFailure with a recent switch -- rollback called.
{
    my $mac = 'aa:bb:cc:dd:ee:08a';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.70' });
    $DM->_processPendingSwitches;
    $DM->stopHelper($mac);    # isolate: no alive helpers during the rollback fan-out below

    my $rb_before = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($mac, 'no_ws_port', time() + 100);
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1,
        "Case 8a: noteStartupFailure with a switch 100s ago triggers a rollback");
}

# Case 8b: noteStartupFailure with an old switch -- rollback NOT called.
{
    my $mac = 'aa:bb:cc:dd:ee:08b';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.70' });
    $DM->_processPendingSwitches;
    $DM->stopHelper($mac);

    my $rb_before = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($mac, 'no_ws_port', time() + 1801);
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 0,
        "Case 8b: noteStartupFailure with a switch 1801s ago does NOT trigger a rollback");
}

# Case 9: after a successful rollback, pendingBinarySwitches carries every
# OTHER alive Soloist helper (marked rollback => 1); the triggering
# (already-dead) helper is not marked.
{
    my $macOther   = 'aa:bb:cc:dd:ee:09a';
    my $macTrigger = 'aa:bb:cc:dd:ee:09b';
    $STREAM_ACTIVE = 1;    # defer the fan-out's own immediate switch so the
                           # pending map is still observable afterward

    $DM->startHelper($macOther);
    $DM->startHelper($macTrigger);

    # Mirrors production: _pollWsPort's on_exhausted already calls $self->
    # stop() before noteStartupFailure ever runs -- the triggering helper is
    # registered-but-dead by the time the fan-out loop runs.
    my ($triggerHelper) = grep { $_->mac eq $macTrigger } $DM->helperInstances;
    $triggerHelper->_proc(Test::FakeProc->new(alive => 0));

    $DM->_rollbackAfterSwitch($macTrigger, 'case 9 trigger');

    my $pending = $DM->pendingBinarySwitches;
    is(scalar(keys %$pending), 1, "Case 9: exactly one pending entry after the rollback");
    ok(exists $pending->{$macOther}, "Case 9: the OTHER alive helper is marked pending");
    is($pending->{$macOther}{rollback}, 1, "Case 9: the pending entry carries rollback => 1");
    ok(!exists $pending->{$macTrigger}, "Case 9: the triggering (dead) helper is NOT marked pending");

    $DM->stopHelper($macOther);
    $DM->stopHelper($macTrigger);
    $STREAM_ACTIVE = 0;
}

# ============================================================
# Phase 83.3 plan 09 (D-07 gap 3): proof by evidence -- _generationProven,
# _markGenerationUnproven, _noteGenerationStart, _proveGenerations
# ============================================================

# Case 10 (corner 1, real material, legacy = proven): the actual live
# renewal record from 2026-09-26 (83.3-06-SUMMARY.md line 169) has no
# `proven` key at all -- it counts as proven by definition (USER DECISION),
# so a first start on it opens NO rollback window, however it is reached.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.79',
        previous_version     => '1.3.8.68',
        previous_expiry_days => 62,
        switched_at          => 1790385778,
        reason               => 'manual',
    }, 'never');

    my $mac = 'aa:bb:cc:dd:ee:10';
    $STREAM_ACTIVE = 0;
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 2, last_crash_at => 0, next_allowed_at => 0);

    $DM->startHelper($mac);
    is($DM->switchedAtFor($mac), undef,
        "Case 10: the real legacy record (no proven key) opens no rollback window on first start");
    is($state->{count}, 2, "Case 10: crash count untouched by the legacy-record start");

    my $rb_before = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($mac, 'no_ws_port', time() + 100);
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 0,
        "Case 10: noteStartupFailure triggers no rollback (no anchor was ever set)");

    is($DM->_proveGenerations(time() + 1801), 0,
        "Case 10: _proveGenerations returns 0 -- already proven, nothing to prove");
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    ok(!exists $gen->{proven}, "Case 10: the record still carries no proven key");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 11 (corner 2(a) + corner 4 + lost anchor): an unproven generation
# opens a rollback window on a first start however late after the
# promotion (here 2h); a rollback clears the in-memory anchor but the
# generation record stays unproven, and the player's very next start
# re-anchors -- also covers the LMS-restart-mid-window shape, where the
# in-memory anchor vanishes but the persisted proven => 0 survives.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 7200,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    my $mac = 'aa:bb:cc:dd:ee:11';
    $STREAM_ACTIVE = 0;
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 2, last_crash_at => 0, next_allowed_at => 0);

    my $now_before = time();
    $DM->startHelper($mac);
    my $switchedAt = $DM->switchedAtFor($mac);
    ok(defined $switchedAt, "Case 11: switchedAtFor defined after first start on an unproven generation 2h old");
    ok(defined $switchedAt && abs($switchedAt - $now_before) <= 2,
        "Case 11: the anchor is within 2s of now");
    is($state->{count}, 2, "Case 11: count untouched by the anchor (GH #147 backoff, WR-02)");
    is($state->{switch_crashes}, 0, "Case 11: switch_crashes reset to 0 by the anchor (D-07's own counter)");

    my $rb_before = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($mac, 'no_ws_port', time() + 100);
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1,
        "Case 11: a never-ready inside the window rolls back");

    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 11: the generation stays unproven after the rollback");

    $DM->stopHelper($mac);
    $DM->startHelper($mac);
    ok(defined $DM->switchedAtFor($mac),
        "Case 11: switchedAtFor is defined again after stop/start (anchor lost by the rollback's clear, generation still unproven)");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 11c (the stale-anchor scenario, both sides of the window): a restart
# after the window closed never inherits a stale anchor; a window run alive
# and uninterrupted from a fresh anchor is evidence a generation can be
# proven on.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 7200,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    my $mac = 'aa:bb:cc:dd:ee:1c';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 11c setup: fresh anchor A recorded on first start");

    $DM->_noteGenerationStart($mac, $A + 1799);
    is($DM->switchedAtFor($mac), $A,
        "Case 11c: a restart at anchor+1799 (inside the window) keeps the anchor -- exemption");

    $DM->stopHelper($mac);
    $DM->_noteGenerationStart($mac, $A + 1801);
    is($DM->switchedAtFor($mac), $A + 1801,
        "Case 11c: a restart at anchor+1801 (after the window closed) never inherits a stale anchor -- fresh anchor at A + 1801");
    my $state = $DM->_crashStateFor($mac);
    is($state->{count}, 0, "Case 11c: count untouched by the fresh anchor (never incremented in this case)");
    is($state->{switch_crashes}, 0, "Case 11c: switch_crashes reset to 0 by the fresh anchor (D-07's own counter)");

    is($DM->_proveGenerations($A + 1801 + 60), 0,
        "Case 11c: the first tick of the new window proves nothing (window not over, no alive helper)");
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 11c: still unproven after the first tick");

    $DM->startHelper($mac);    # real clock -- this very restart interrupts the fresh window
    is($DM->_proveGenerations($A + 1801 + 1801), 0,
        "Case 11c: the fresh window was interrupted by that very restart -- no proof");
    $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 11c: still unproven after the interrupted window");

    $DM->_noteGenerationStart($mac, $A + 3700);
    is($DM->switchedAtFor($mac), $A + 3700, "Case 11c: a new anchor at A + 3700");

    is($DM->_proveGenerations($A + 3700 + 1801), 1,
        "Case 11c: a window run alive and uninterrupted from its anchor proves the generation");
    $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 1, "Case 11c: the record now reads proven");
    is($gen->{proven_by}, $mac, "Case 11c: proven_by names the proving player");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 11b (stop + restart inside the window; criterion b): a restart
# inside the window neither re-anchors nor resets the crash counter, but
# DOES end proof eligibility -- no proof without an uninterrupted window.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 7200,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    my $mac = 'aa:bb:cc:dd:ee:1b';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 11b setup: anchor A recorded");
    my $state = $DM->_crashStateFor($mac);
    $state->{count} = 1;

    $DM->stopHelper($mac);
    $DM->startHelper($mac);
    is($DM->switchedAtFor($mac), $A, "Case 11b: a restart inside the window keeps the SAME anchor");
    is($state->{count}, 1, "Case 11b: a restart inside the window does not reset the crash counter");

    is($DM->_proveGenerations($A + 1801), 0,
        "Case 11b: no proof after a restart -- it ended eligibility even though the helper is alive");
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 11b: still unproven");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
    # Phase 83.3 plan 13 (D-07, WR-02): switch_crashes seeded alongside
    # count -- with the counter split, _rollbackDue reads switch_crashes
    # only; without seeding it here this poll would fall through to a
    # REAL startHelper()->start() call instead of the rollback path this
    # case exists to pin (deviation, see SUMMARY).
    %$state = (count => 2, last_crash_at => time() - 10, next_allowed_at => 0, switch_crashes => 2);

    my ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1,
        "Case 11b: criterion b fires for a player anchored 2h after promotion");
    is($START_CALLS, $start_before, "Case 11b: startHelper NOT called in that same iteration (rollback instead)");
    $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 11b: proven stays 0 after the rollback");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 12 (corner 3 and the proof lifecycle): a generation becomes proven
# only after an eligible anchored player runs alive and uninterrupted past
# the full window; once proven, later first starts (even a deferred pending
# switch) open no window at all.
{
    my $mac_c = 'aa:bb:cc:dd:ee:1c2';
    $STREAM_ACTIVE = 0;

    # Step 1: C starts BEFORE any generation record exists -- no anchor.
    $DM->startHelper($mac_c);
    ok(!defined $DM->switchedAtFor($mac_c), "Case 12 step 1: no record yet -- no anchor for C");

    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.80' });

    $STREAM_ACTIVE = 1;
    $DM->_processPendingSwitches;
    my $pending = $DM->pendingBinarySwitches;
    ok(exists $pending->{$mac_c}, "Case 12 step 1: C's switch is deferred while streaming");

    # Step 2: A anchors on its first start.
    my $mac_a = 'aa:bb:cc:dd:ee:1a';
    $DM->startHelper($mac_a);
    my $tA = $DM->switchedAtFor($mac_a);
    ok(defined $tA, "Case 12 step 2: A anchored at tA");

    # Step 2b: the 60s watchdog shape -- startHelper on an ALREADY alive,
    # name-unchanged helper must NOT touch the anchor or eligibility.
    my $start_before_2b = $START_CALLS;
    $DM->startHelper($mac_a);
    is($START_CALLS, $start_before_2b + 1, "Case 12 step 2b: startHelper was actually called again");
    is($DM->switchedAtFor($mac_a), $tA, "Case 12 step 2b: the watchdog call does not touch A's anchor");

    # Step 3: window not over yet.
    is($DM->_proveGenerations($tA + 1000), 0, "Case 12 step 3: window not over -- no proof");
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 12 step 3: still unproven");

    # Step 4: A dead at the tick -- no proof (alive required).
    my ($helperA) = grep { $_->mac eq $mac_a } $DM->helperInstances;
    $helperA->_proc(Test::FakeProc->new(alive => 0));
    is($DM->_proveGenerations($tA + 1801), 0, "Case 12 step 4: A not alive at the tick -- no proof");

    # Step 5: A alive again, window over -- proven.
    $helperA->_proc(Test::FakeProc->new(alive => 1));
    is($DM->_proveGenerations($tA + 1801), 1, "Case 12 step 5: A alive past the window -- proven");
    $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 1, "Case 12 step 5: record now reads proven");
    is($gen->{proven_by}, $mac_a, "Case 12 step 5: proven_by is A");
    ok(defined $gen->{proven_at}, "Case 12 step 5: proven_at is set");

    # Step 6: a fresh late player after proof -- no anchor, counter untouched.
    my $mac_b = 'aa:bb:cc:dd:ee:1e';
    my $state_b = $DM->_crashStateFor($mac_b);
    %$state_b = (count => 2, last_crash_at => 0, next_allowed_at => 0);
    $DM->startHelper($mac_b);
    ok(!defined $DM->switchedAtFor($mac_b), "Case 12 step 6: late player B (after proof) gets no anchor");
    is($state_b->{count}, 2, "Case 12 step 6: B's crash counter is untouched");

    # Step 7: the deferred pending switch executes now, but the generation
    # is already proven -- C is restarted but gets no anchor either.
    $STREAM_ACTIVE = 0;
    my ($stop_before_7, $start_before_7) = ($STOP_CALLS, $START_CALLS);
    $DM->_processPendingSwitches;
    is($STOP_CALLS,  $stop_before_7 + 1,  "Case 12 step 7: C is restarted (stop)");
    is($START_CALLS, $start_before_7 + 1, "Case 12 step 7: C is restarted (start)");
    $pending = $DM->pendingBinarySwitches;
    ok(!exists $pending->{$mac_c}, "Case 12 step 7: C's pending entry is gone");
    ok(!defined $DM->switchedAtFor($mac_c), "Case 12 step 7: C gets no anchor -- first start on a PROVEN build");

    # Step 8: no rollback for B (never anchored).
    my $rb_before_8 = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($mac_b, 'no_ws_port', time() + 100);
    is(scalar(@ROLLBACK_CALLS) - $rb_before_8, 0, "Case 12 step 8: no rollback for B (no anchor)");

    $DM->stopHelper($mac_a);
    $DM->stopHelper($mac_b);
    $DM->stopHelper($mac_c);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 12b (seen dead by the poll, poll restart, then alive): a restart via
# the crash-backoff poll ends eligibility exactly like any other (re)start;
# a fresh anchor survived alive and uninterrupted still proves.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    my $mac = 'aa:bb:cc:dd:ee:2b';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 12b setup: anchor A recorded");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0);

    my ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is($state->{count}, 1, "Case 12b: the poll's restart counts as one crash");
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 0, "Case 12b: not enough crashes yet for a rollback");
    is($START_CALLS, $start_before + 1, "Case 12b: the poll restarted the helper via startHelper");

    is($DM->_proveGenerations($A + 1801), 0,
        "Case 12b: no proof -- the poll's restart ended eligibility even though the helper is alive again");
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 12b: still unproven after the poll restart");
    is($DM->switchedAtFor($mac), $A, "Case 12b: the anchor is unchanged (exemption)");
    is($state->{count}, 1, "Case 12b: the crash counter is unchanged");

    $DM->_noteGenerationStart($mac, $A + 1801);
    is($DM->switchedAtFor($mac), $A + 1801, "Case 12b: a fresh anchor after the window closed");
    is($state->{count}, 1, "Case 12b: count untouched by the fresh anchor (still 1 from the earlier poll crash, WR-02)");
    is($state->{switch_crashes}, 0, "Case 12b: switch_crashes reset to 0 by the fresh anchor (D-07's own counter)");

    is($DM->_proveGenerations($A + 1801 + 1801), 1,
        "Case 12b: a fresh late anchor survived alive and uninterrupted -- proven");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 12c (dead proc restarted DIRECTLY by startHelper, no poll -- the
# watchdog/_staggeredStart/_restartForHealth shape): a direct restart also
# ends eligibility while keeping anchor and counter, exactly like the
# poll's own restart in Case 12b.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    my $mac = 'aa:bb:cc:dd:ee:2c';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 12c setup: anchor A recorded");
    my $state = $DM->_crashStateFor($mac);
    is($state->{count}, 0, "Case 12c setup: crash counter starts at 0");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1 -- no poll runs

    my $start_before = $START_CALLS;
    $DM->startHelper($mac);
    is($START_CALLS, $start_before + 1, "Case 12c: startHelper restarted the dead helper directly");
    is($DM->switchedAtFor($mac), $A, "Case 12c: the anchor is kept by the exemption");
    is($state->{count}, 0, "Case 12c: nothing counted the crash -- counter untouched");

    is($DM->_proveGenerations($A + 1801), 0,
        "Case 12c: no proof -- the direct restart ended eligibility regardless of which caller triggered it");
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 12c: still unproven");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 12d (a new promotion inside an open window re-anchors): a NEWER
# generation promoted while an OLDER window is still open must re-anchor,
# not inherit the old generation's anchor.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    my $mac = 'aa:bb:cc:dd:ee:2d';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 12d setup: anchor A on generation G1");
    my $state = $DM->_crashStateFor($mac);
    $state->{count} = 2;
    $state->{switch_crashes} = 2;

    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.81',
        previous_version     => '1.3.8.80',
        previous_expiry_days => 59,
        switched_at          => time() - 5,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    $DM->_noteGenerationStart($mac, $A + 100);
    is($DM->switchedAtFor($mac), $A + 100,
        "Case 12d: a newer promotion inside the old window re-anchors -- different generation");
    is($state->{count}, 2, "Case 12d: count untouched by the re-anchor (GH #147 backoff, WR-02)");
    is($state->{switch_crashes}, 0, "Case 12d: switch_crashes reset to 0 by the re-anchor (D-07's own counter)");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
    %$state = (count => 2, last_crash_at => time() - 10, next_allowed_at => 0, switch_crashes => 2);

    my $rb_before = scalar(@ROLLBACK_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1, "Case 12d: criterion b fires on the NEW window");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 13 (stamps and guards): onSoloistBinaryReplaced is a no-op without a
# generation record; a promotion stamps even a legacy record unproven; a
# successful rollback re-stamps proven => 0.
{
    $STREAM_ACTIVE = 0;

    # No record at all -- onSoloistBinaryReplaced must not die and must not
    # create one out of thin air (t/51 Cases 1-9 rely on exactly this).
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
    $DM->onSoloistBinaryReplaced({ version => 'x' });
    ok(!defined Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation'),
        "Case 13: onSoloistBinaryReplaced with no record creates none");

    my $mac1 = 'aa:bb:cc:dd:ee:1d1';
    $DM->startHelper($mac1);
    ok(!defined $DM->switchedAtFor($mac1), "Case 13: no record -- startHelper anchors nothing");
    $DM->stopHelper($mac1);

    # A legacy record (no proven key) still gets stamped unproven by the
    # NEXT promotion -- _markGenerationUnproven works on it like any other.
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.81',
        previous_version     => '1.3.8.80',
        previous_expiry_days => 60,
        switched_at          => time() - 5,
        reason               => 'expiry',
    }, 'never');    # no `proven` key -- legacy shape (record written before this plan)
    $DM->onSoloistBinaryReplaced({ version => '1.3.8.81' });
    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 13: a promotion stamps even a legacy record proven => 0");

    my $mac2 = 'aa:bb:cc:dd:ee:1d2';
    $DM->startHelper($mac2);
    ok(defined $DM->switchedAtFor($mac2), "Case 13: the now-unproven record anchors the next start");

    # A successful rollback re-stamps proven => 0 too.
    $gen->{proven} = 1;
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', $gen, 'never');
    $DM->stopHelper($mac2);    # isolate: no alive helper in the rollback fan-out
    $DM->_rollbackAfterSwitch('aa:bb:cc:dd:ee:1f', 'case 13');
    $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen->{proven}, 0, "Case 13: a successful rollback re-stamps proven => 0");

    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# ============================================================
# Phase 83.3 plan 13 (D-07, WR-02, gap-closure round): 83.3-REVIEW.md
# :70-97. Plan 09's re-anchor reset the WHOLE crash state (count,
# last_crash_at, next_allowed_at, sharing GH #147's own backoff counter),
# so a crash-looping player with no rollback left never reached the 300s
# backoff cap -- it re-anchored to count=0 every ~40s forever instead.
# D-07 criterion (b) now counts on its own field, switch_crashes; the
# GH #147 backoff fields are never touched by a re-anchor; and a
# generation for which a rollback proved impossible (no_previous /
# previous_expired) is marked rollback_exhausted so it is never re-armed.
# ============================================================

# Case 14 (WR-02 tracer): a player on an unproven generation with NO
# previous generation to roll back to crashes repeatedly. count rises
# monotonically 1..8 across eight polls, the delay reaches CRASH_BACKOFF_MAX
# (300s), _rollbackAfterSwitch runs exactly once (poll 3), and no re-anchor
# ever re-opens a window on this exhausted generation again.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => undef,
        previous_expiry_days => undef,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local $ROLLBACK_RESULT = [0, 'no_previous'];

    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    my $mac = 'aa:bb:cc:dd:ee:14';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 14 setup: anchor A recorded on the no-previous generation");

    my $state = $DM->_crashStateFor($mac);
    is($state->{switch_crashes}, 0, "Case 14 setup: switch_crashes starts at 0");
    is($state->{count}, 0, "Case 14 setup: count starts at 0");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;

    my @counts;
    my $rollback_total = 0;

    for my $poll (1 .. 8) {
        $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
        $state->{next_allowed_at} = 0;

        my ($rb_before, $start_before, $now_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS, time());
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
        my $rb_delta    = scalar(@ROLLBACK_CALLS) - $rb_before;
        my $start_delta = $START_CALLS - $start_before;
        $rollback_total += $rb_delta;
        push @counts, $state->{count};

        if ($poll == 1) {
            is($state->{count}, 1, "Case 14 poll 1: count 1");
            is($state->{switch_crashes}, 1, "Case 14 poll 1: switch_crashes 1");
            is($rb_delta, 0, "Case 14 poll 1: no rollback yet");
            is($start_delta, 1, "Case 14 poll 1: restarted");
            ok(defined $DM->switchedAtFor($mac), "Case 14 poll 1: anchor A kept (exemption)");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 4 && $delay <= 5, "Case 14 poll 1: delay in [4,5], got $delay");
        }
        elsif ($poll == 2) {
            is($state->{count}, 2, "Case 14 poll 2: count 2");
            is($state->{switch_crashes}, 2, "Case 14 poll 2: switch_crashes 2");
            is($rb_delta, 0, "Case 14 poll 2: no rollback yet");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 9 && $delay <= 10, "Case 14 poll 2: delay in [9,10], got $delay");
        }
        elsif ($poll == 3) {
            is($state->{count}, 3, "Case 14 poll 3: count 3");
            is($state->{switch_crashes}, 3, "Case 14 poll 3: switch_crashes 3");
            is($rb_delta, 1, "Case 14 poll 3: rollback attempted exactly once");
            is($start_delta, 0, "Case 14 poll 3: NOT restarted (rollback branch skips startHelper)");
            is($DM->switchedAtFor($mac), undef, "Case 14 poll 3: switchedAtFor cleared by the impossible rollback");
            my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
            is($gen->{rollback_exhausted}, 1, "Case 14 poll 3: generation stamped rollback_exhausted");
            is($gen->{rollback_exhausted_detail}, 'no_previous', "Case 14 poll 3: exhausted detail is no_previous");
            is($gen->{proven}, 0, "Case 14 poll 3: generation still unproven (untouched by the failed rollback)");

            # 83.3-REVIEW round 2 (WR-02): a no_previous rollback must become
            # visible on the settings page, exactly like previous_expired
            # already is -- "only the notice remains" (D-07).
            my $renewal = Plugins::SpotOn::Soloist::renewalState();
            is($renewal->{phase}, 'rollback_impossible',
                "Case 14 poll 3 (WR-02): renewalState phase is rollback_impossible after a no_previous rollback");
            is($renewal->{detail}, 'no_previous',
                "Case 14 poll 3 (WR-02): renewalState detail is no_previous");
        }
        elsif ($poll == 4) {
            # RED on the unfixed code: the re-anchor inside startHelper's
            # restart branch reset count back to 0 here (WR-02 defect).
            is($state->{count}, 4, "Case 14 poll 4: count 4 -- the GH #147 backoff SURVIVES the re-anchor attempt (WR-02 fix)");
            is($state->{switch_crashes}, 4, "Case 14 poll 4: switch_crashes 4 (D-07's own counter keeps counting)");
            is($DM->switchedAtFor($mac), undef, "Case 14 poll 4: switchedAtFor STILL undef -- exhausted generation never re-anchors");
            is($rb_delta, 0, "Case 14 poll 4: no second rollback attempt");
            is($start_delta, 1, "Case 14 poll 4: restarted -- the backoff cadence continues even though no window reopened");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 39 && $delay <= 40, "Case 14 poll 4: delay in [39,40], got $delay");
        }
        elsif ($poll == 5) {
            is($state->{count}, 5, "Case 14 poll 5: count 5");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 79 && $delay <= 80, "Case 14 poll 5: delay in [79,80], got $delay");
        }
        elsif ($poll == 6) {
            is($state->{count}, 6, "Case 14 poll 6: count 6");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 159 && $delay <= 160, "Case 14 poll 6: delay in [159,160], got $delay");
        }
        elsif ($poll == 7) {
            is($state->{count}, 7, "Case 14 poll 7: count 7");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 299 && $delay <= 300, "Case 14 poll 7: delay capped at [299,300], got $delay");
        }
        elsif ($poll == 8) {
            is($state->{count}, 8, "Case 14 poll 8: count 8");
            my $delay = $state->{next_allowed_at} - $now_before;
            ok($delay >= 299 && $delay <= 300, "Case 14 poll 8: delay stays capped at [299,300], got $delay");
        }
    }

    is($rollback_total, 1, "Case 14: exactly one rollback attempt over all eight polls");

    my $strictly_increasing = 1;
    for my $i (1 .. $#counts) {
        $strictly_increasing = 0 if $counts[$i] <= $counts[$i - 1];
    }
    ok($strictly_increasing, "Case 14: count strictly increasing across all eight polls (@counts)");

    # Phase 83.3 plan 16 (G-83.3-5b): rewritten from the old "returns 0 --
    # no eligible anchor on an exhausted generation" pin. That assertion
    # codified the very defect G-83.3-5b names: an exhausted generation's
    # rollback stays terminally impossible (WR-02, poll 4's switchedAtFor
    # STILL undef above is unchanged), but the looping player itself ran
    # alive and uninterrupted since its last (poll 8) restart -- that is
    # exactly the evidence _proveGenerations exists to recognize.
    is($DM->_proveGenerations(time() + 1801), 1,
        "Case 14 (G-83.3-5b): _proveGenerations returns 1 -- an exhausted generation is still provable");
    my $gen_after_14 = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen_after_14->{proven}, 1, "Case 14 (G-83.3-5b): the record reads proven");
    is($gen_after_14->{proven_by}, $mac, "Case 14 (G-83.3-5b): proven_by is the looping player itself");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 14b (WR-02 opposite direction 1): rollback IS possible -- a
# successful rollback must never stamp rollback_exhausted, and the
# restored generation must still open a fresh window on the player's next
# start (Case 11's flow, pinned again here for the two-counter model).
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local $ROLLBACK_RESULT = [1, '1.3.8.68'];    # default -- Case 14's own `local` does not leak here

    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    my $mac = 'aa:bb:cc:dd:ee:14b';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 14b setup: anchor A recorded");

    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 2, switch_crashes => 2, last_crash_at => time() - 10, next_allowed_at => 0);

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1

    my ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1, "Case 14b: rollback attempted exactly once");
    is($START_CALLS, $start_before, "Case 14b: NOT restarted in that iteration (rollback branch skips startHelper)");

    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    ok(!exists $gen->{rollback_exhausted}, "Case 14b: a successful rollback does NOT stamp rollback_exhausted");
    is($gen->{proven}, 0, "Case 14b: the restored generation is stamped unproven (plan 09's success-branch behavior)");

    $DM->stopHelper($mac);
    $DM->startHelper($mac);
    ok(defined $DM->switchedAtFor($mac),
        "Case 14b: switchedAtFor is defined again -- the restored generation still opens a window (not exhausted)");
    is($state->{switch_crashes}, 0, "Case 14b: switch_crashes reset to 0 by the fresh anchor");
    is($state->{count}, 3, "Case 14b: count untouched by the fresh anchor (2 seeded + 1 from the crash poll)");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 14c (WR-02 opposite direction 2): a transient rollback_move_failed
# must NOT exhaust the generation -- the next third switch crash retries
# the move under the surviving backoff instead of ending this generation's
# rollback chances for good (plan-check disposition).
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => '1.3.8.79',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local $ROLLBACK_RESULT = [0, 'rollback_move_failed'];

    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    my $mac = 'aa:bb:cc:dd:ee:14c';
    $STREAM_ACTIVE = 0;
    $DM->startHelper($mac);
    my $A = $DM->switchedAtFor($mac);
    ok(defined $A, "Case 14c setup: anchor A recorded");

    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 2, switch_crashes => 2, last_crash_at => time() - 10, next_allowed_at => 0);

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1

    my ($rb_before1, $start_before1) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is(scalar(@ROLLBACK_CALLS) - $rb_before1, 1, "Case 14c poll 1: rollback attempted");
    is($START_CALLS, $start_before1, "Case 14c poll 1: NOT restarted (rollback branch skips startHelper)");
    is($DM->switchedAtFor($mac), undef, "Case 14c poll 1: switchedAtFor cleared like every rollback outcome");
    is($state->{count}, 3, "Case 14c poll 1: count 3");

    my $gen = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    ok(!exists $gen->{rollback_exhausted}, "Case 14c: a transient move failure does NOT stamp rollback_exhausted");

    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # still dead
    $state->{next_allowed_at} = 0;

    my ($rb_before2, $start_before2) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is($START_CALLS, $start_before2 + 1, "Case 14c poll 2: restarted (re-anchor allowed -- not exhausted)");
    is(scalar(@ROLLBACK_CALLS) - $rb_before2, 0, "Case 14c poll 2: no second rollback attempt this iteration");
    ok(defined $DM->switchedAtFor($mac), "Case 14c poll 2: switchedAtFor defined again -- the retry re-anchors");
    is($state->{switch_crashes}, 0, "Case 14c poll 2: switch_crashes reset to 0 by the re-anchor");
    is($state->{count}, 4, "Case 14c poll 2: count 4 -- the backoff survives the retry path");

    is(scalar(@ROLLBACK_CALLS) - $rb_before1, 1, "Case 14c: exactly one rollback attempt over both polls");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 15 (WR-02: fresh generation after an exhausted one): the exhausted
# mark is scoped to G1 only -- G2, a genuinely NEW promotion, opens its own
# window even though G1 left a high backoff count behind on this player.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.80',
        previous_version     => undef,
        previous_expiry_days => undef,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
        rollback_exhausted   => 1,
    }, 'never');

    my $mac = 'aa:bb:cc:dd:ee:15';
    $STREAM_ACTIVE = 0;

    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    ok(!defined $DM->switchedAtFor($mac),
        "Case 15: an exhausted G1 opens no window on this player's first start (the guard, directly)");

    my $state = $DM->_crashStateFor($mac);
    $state->{count} = 7;    # backoff history accumulated on the exhausted generation

    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.81',
        previous_version     => '1.3.8.80',
        previous_expiry_days => 59,
        switched_at          => time() - 5,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');    # G2: fresh record, no rollback_exhausted key

    $DM->_noteGenerationStart($mac, time());
    ok(defined $DM->switchedAtFor($mac), "Case 15: G2 (a genuinely new generation) opens a window");
    is($state->{switch_crashes}, 0, "Case 15: switch_crashes reset to 0 by G2's anchor");
    is($state->{count}, 7, "Case 15: count untouched -- still 7 from the exhausted G1's history");

    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;

    # Round 1: one crash -- backoff count keeps rising, no rollback (a high
    # backoff count alone never triggers criterion (b)).
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));
    $state->{next_allowed_at} = 0;
    my ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{count}, 8, "Case 15 round 1: count 8");
    is($state->{switch_crashes}, 1, "Case 15 round 1: switch_crashes 1");
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 0,
        "Case 15 round 1: no rollback -- a high backoff count alone never triggers criterion (b)");
    is($START_CALLS, $start_before + 1, "Case 15 round 1: restarted (exemption keeps the anchor)");
    ok(defined $DM->switchedAtFor($mac), "Case 15 round 1: anchor kept (exemption)");

    # Round 2: second crash -- still below the threshold.
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));
    $state->{next_allowed_at} = 0;
    ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{switch_crashes}, 2, "Case 15 round 2: switch_crashes 2");
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 0, "Case 15 round 2: still no rollback");

    # Round 3: third switch crash -- G2 gets its window, rollback fires.
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));
    $state->{next_allowed_at} = 0;
    ($rb_before, $start_before) = (scalar(@ROLLBACK_CALLS), $START_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{switch_crashes}, 3, "Case 15 round 3: switch_crashes 3");
    is(scalar(@ROLLBACK_CALLS) - $rb_before, 1,
        "Case 15 round 3: a genuinely new generation gets its window and can roll back");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# ============================================================
# Phase 83.3 plan 16 (G-83.3-5): the 60s watchdog must not restart a
# crashed daemon while the 5s _streamAlivePoll owns a live incident -- the
# poll is the ONLY counted restart path during an incident (it always
# passes crash_restart => 1); a stale or never-crashed helper is still
# restarted by the watchdog directly, exactly as before.
# ============================================================

# Case 16 (a-d): watchdog suppression during a live crash incident, the
# poll's own bypass flag, and the stale-incident/never-crashed exemptions.
# Uses a real `Plugins::SpotOn::Unified::SoloistDaemon::start` override
# (not $START_CALLS, which only counts CALLS to DaemonManager::startHelper
# -- a suppressed call still counts there) so REAL restarts are observed
# independently of whether startHelper's dead-helper branch actually ran.
{
    my $mac = 'aa:bb:cc:dd:ee:16';
    $STREAM_ACTIVE = 0;

    my $real_starts = 0;
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $real_starts++;
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    ok($helper, "Case 16 setup: helper registered for $mac");
    is($real_starts, 0, "Case 16 setup: construction does not go through the ::start override");

    my $state = $DM->_crashStateFor($mac);
    my $now = time();
    %$state = (count => 3, switch_crashes => 0, last_crash_at => $now - 10, next_allowed_at => $now + 30);

    # Case 16a: helper dead, incident live (last_crash_at 10s ago, well
    # inside the 600s CRASH_BACKOFF_RESET_AFTER horizon) -- a direct
    # watchdog-shaped startHelper() call (no bypass flag) must NOT restart.
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
    $DM->startHelper($mac);
    is($real_starts, 0, "Case 16a: watchdog does not restart during a live incident");
    is($helper->alive, 0, "Case 16a: helper still dead");
    is($DM->switchedAtFor($mac), undef, "Case 16a: switchedAtFor untouched -- no _noteGenerationStart ran");
    is($state->{count}, 3, "Case 16a: crash count untouched by the suppressed call");

    # Case 16b: the poll's own bypass flag DOES restart it.
    $DM->startHelper($mac, { crash_restart => 1 });
    is($real_starts, 1, "Case 16b: the crash_restart bypass flag restarts the helper");
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    is($helper->alive, 1, "Case 16b: helper alive after the bypassed restart");

    # Case 16c: helper dead again, but the incident is now stale
    # (last_crash_at 601s ago) -- the watchdog restarts it directly, same
    # as before this plan (mirrors Case 12c's never-crashed exemption).
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
    $state->{last_crash_at} = $now - 601;
    $DM->startHelper($mac);
    is($real_starts, 2, "Case 16c: a stale (>600s) incident does not suppress the watchdog");

    # Case 16d: helper dead again; next_allowed_at is already in the past
    # (the backoff itself would allow a restart) but last_crash_at is only
    # 3s ago -- the <=5s hand-off window this plan closes. The poll, not
    # the watchdog, must own this restart.
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1
    $state->{last_crash_at}   = $now - 3;
    $state->{next_allowed_at} = $now - 1;
    $DM->startHelper($mac);
    is($real_starts, 2, "Case 16d: the hand-off window still suppresses the watchdog (no real start)");
    is($helper->alive, 0, "Case 16d: helper still dead");

    $DM->stopHelper($mac);
}

# ============================================================
# Phase 83.3 plan 16 (G-83.3-5b): a failed rollback for one player must
# not wipe another player's rollback anchor or proof clock; a successful
# rollback still clears everyone (plan 04 semantics, pinned again here);
# and a generation whose rollback is terminally exhausted (WR-02) stays
# provable by evidence like any other unproven generation.
# ============================================================

# Case 17 (a FAILED rollback scopes its clear to the failing player
# only): A and B both started on the same unproven generation; A's
# rollback fails (no_previous) -- only A's bookkeeping is cleared, B's
# anchor and proof clock survive and B can still prove the generation.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.90',
        previous_version     => undef,
        previous_expiry_days => undef,
        switched_at          => time() - 30,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local $ROLLBACK_RESULT = [0, 'no_previous'];

    my $macA = 'aa:bb:cc:dd:ee:17a';
    my $macB = 'aa:bb:cc:dd:ee:17b';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($macA);
    my $tA = $DM->switchedAtFor($macA);
    ok(defined $tA, "Case 17 setup: A anchored");

    $DM->startHelper($macB);
    my $tB = $DM->switchedAtFor($macB);
    ok(defined $tB, "Case 17 setup: B anchored");

    my ($helperB) = grep { $_->mac eq $macB } $DM->helperInstances;
    ok($helperB && $helperB->alive, "Case 17 setup: B's helper alive");

    $DM->_rollbackAfterSwitch($macA, 'test');

    is($DM->switchedAtFor($macA), undef, "Case 17: A's switchedAtFor cleared by its own failed rollback");
    is($DM->switchedAtFor($macB), $tB, "Case 17: B's switchedAtFor untouched by A's failed rollback");

    is($DM->_proveGenerations($tB + 1801), 1,
        "Case 17: B's proof clock survived A's failed rollback -- the generation is proven");
    my $gen17 = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen17->{proven}, 1, "Case 17: record reads proven");
    is($gen17->{proven_by}, $macB, "Case 17: proven_by is B");
    is($gen17->{rollback_exhausted}, 1, "Case 17: the record still carries rollback_exhausted from A's failed attempt");

    $DM->stopHelper($macA);
    $DM->stopHelper($macB);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 17b (a SUCCESSFUL rollback still clears everyone -- plan 04
# semantics, pinned again here for the scoped-clear model): the binary is
# shared, not per-player, so a successful swap resets every player's
# bookkeeping regardless of who triggered it.
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.90',
        previous_version     => '1.3.8.89',
        previous_expiry_days => 60,
        switched_at          => time() - 30,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local $ROLLBACK_RESULT = [1, '1.3.8.68'];

    my $macA = 'aa:bb:cc:dd:ee:17c';
    my $macB = 'aa:bb:cc:dd:ee:17d';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($macA);
    ok(defined $DM->switchedAtFor($macA), "Case 17b setup: A anchored");
    $DM->startHelper($macB);
    ok(defined $DM->switchedAtFor($macB), "Case 17b setup: B anchored");

    # Keep _rollbackAfterSwitch's own _processPendingSwitches call (the
    # $ok branch re-marks every alive helper pending and consumes it
    # immediately) from re-anchoring A/B on the just-restored generation
    # before this assertion runs -- streaming defers the switch, isolating
    # the check to the rollback's OWN clear.
    $STREAM_ACTIVE = 1;
    $DM->_rollbackAfterSwitch($macA, 'test');

    is($DM->switchedAtFor($macA), undef, "Case 17b: A's switchedAtFor cleared by the successful rollback");
    is($DM->switchedAtFor($macB), undef,
        "Case 17b: B's switchedAtFor ALSO cleared -- a successful rollback resets everyone (plan 04 semantics)");

    $STREAM_ACTIVE = 0;
    $DM->stopHelper($macA);
    $DM->stopHelper($macB);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 18 (an exhausted generation stays provable even though its
# rollback never fires again): rollback_exhausted generation; the
# player's first start opens NO rollback window but DOES open a proof
# window; a crash while looping neither re-arms the rollback nor wipes
# the proof clock; once proven, a later stop/start opens no NEW window at
# all (proven -> no eligibility, not even a phantom proof clock).
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.91',
        previous_version     => undef,
        previous_expiry_days => undef,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
        rollback_exhausted   => 1,
    }, 'never');

    my $real_starts_18 = 0;
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $real_starts_18++;
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    my $mac = 'aa:bb:cc:dd:ee:18';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($mac);
    is($DM->switchedAtFor($mac), undef, "Case 18: first start on an exhausted generation opens no rollback window");

    my $rb_before_18 = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($mac, 'x');
    is(scalar(@ROLLBACK_CALLS) - $rb_before_18, 0,
        "Case 18: noteStartupFailure calls no rollback -- no anchor, outside any window");

    my ($helper18) = grep { $_->mac eq $mac } $DM->helperInstances;
    my $state18 = $DM->_crashStateFor($mac);
    %$state18 = (count => 2, last_crash_at => time() - 10, next_allowed_at => 0, switch_crashes => 2);
    $helper18->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1

    $rb_before_18 = scalar(@ROLLBACK_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is(scalar(@ROLLBACK_CALLS) - $rb_before_18, 0,
        "Case 18: the crash poll calls no rollback either -- rollback_exhausted is terminal (WR-02)");
    is($real_starts_18, 1, "Case 18: the crash poll's own restart still happens (via the crash_restart bypass)");

    is($DM->_proveGenerations(time() + 1801), 1,
        "Case 18: the exhausted generation is proven by the looping player's clean window");
    my $gen18 = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen18->{proven}, 1, "Case 18: record reads proven");
    is($gen18->{proven_by}, $mac, "Case 18: proven_by names the looping player");

    $DM->stopHelper($mac);
    $DM->startHelper($mac);
    is($DM->switchedAtFor($mac), undef,
        "Case 18: switchedAtFor still undef after the proof -- a proven generation opens no window on the next start");
    is($DM->_proveGenerations(time() + 1801), 0,
        "Case 18: proven -> no eligibility, no phantom proof clock either");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# ============================================================
# Phase 83.3 plan 17 (CR-01, WR-02): a helper stopped ON PURPOSE by the
# sync path (stopForSync) must never be booked as a crash by the 5s poll,
# and the watchdog-shaped startHelper() dead-helper gate must let a
# flagged helper through even while a crash incident is live for its MAC
# -- but the flag must be consumed by that restart, so a LATER real death
# of the same helper is gated and counted exactly as Case 16a.
# ============================================================

# Case 19 (a-c)
{
    my $mac = 'aa:bb:cc:dd:ee:19';
    $STREAM_ACTIVE = 0;

    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.92',
        previous_version     => '1.3.8.89',
        previous_expiry_days => 60,
        switched_at          => time() - 60,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    my $real_starts_19 = 0;
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $real_starts_19++;
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    ok($helper, "Case 19 setup: helper registered for $mac");
    ok(defined $DM->switchedAtFor($mac), "Case 19 setup: anchored (switchedAtFor defined)");

    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 1, switch_crashes => 2, last_crash_at => time() - 10, next_allowed_at => 0);

    can_ok($helper, '_stoppedDeliberately');
    ok(eval { $helper->stopForSync; 1 }, "Case 19 setup: stopForSync callable")
        or diag("stopForSync died: $@");

    # Test::FakeProc's die() is a no-op -- install a dead FakeProc ourselves.
    # status 15 (no left shift) -- a signalled process, exitCode() (>>8) is 0,
    # not 10 -- matches a real SIGTERM'd process, never an expired-build exit.
    $helper->_proc(Test::FakeProc->new(status => 15, alive => 0));
    my $flag_after_stopForSync = eval { $helper->_stoppedDeliberately };
    is($flag_after_stopForSync, 1,
        "Case 19 setup: stopForSync flags the helper as deliberately stopped");

    # Case 19a: the 5s poll must skip a flagged dead helper entirely --
    # no crash bookkeeping, no rollback, no restart of its own.
    my $rb_before_19a       = scalar(@ROLLBACK_CALLS);
    my $last_crash_before   = $state->{last_crash_at};
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is(scalar(@ROLLBACK_CALLS) - $rb_before_19a, 0,
        "Case 19a: no rollback booked for the deliberately-stopped helper");
    is($state->{count}, 1, "Case 19a: crash count untouched by the poll");
    is($state->{switch_crashes}, 2, "Case 19a: switch_crashes untouched by the poll");
    is($state->{last_crash_at}, $last_crash_before, "Case 19a: last_crash_at untouched by the poll");
    is($real_starts_19, 0, "Case 19a: the poll performs no real start for a flagged helper");
    is($helper->alive, 0, "Case 19a: helper still dead after the poll");

    # Case 19b: the watchdog-shaped startHelper() call DOES restart it
    # despite the live incident, because the deliberate-stop flag bypasses
    # the gate -- and the flag is consumed immediately before start().
    $DM->startHelper($mac);
    is($real_starts_19, 1, "Case 19b: the flagged helper is restarted despite a live incident");
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    is($helper->alive, 1, "Case 19b: helper alive after the restart");
    is($state->{count}, 1, "Case 19b: crash count unchanged by the flagged restart");
    is($state->{switch_crashes}, 2, "Case 19b: switch_crashes unchanged by the flagged restart");
    my $flag_after_restart = eval { $helper->_stoppedDeliberately };
    is($flag_after_restart, 0, "Case 19b: flag consumed by the restart");

    # Case 19c: the SAME helper's later REAL death must still be gated
    # (Case 16a semantics -- the poll, not the watchdog, owns this restart)
    # and counted as a genuine crash -- the flag does not leak protection
    # onto a death it never covered.
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1 -- a REAL crash
    $DM->startHelper($mac);
    is($real_starts_19, 1,
        "Case 19c: the incident gate still holds for a real crash (no unauthorized restart)");

    my $rb_before_19c = scalar(@ROLLBACK_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{count}, 2, "Case 19c: crash count incremented for the real death");
    is($state->{switch_crashes}, 3, "Case 19c: switch_crashes reaches the rollback threshold");
    is(scalar(@ROLLBACK_CALLS) - $rb_before_19c, 1,
        "Case 19c: exactly one rollback attempted for the real crash");

    $DM->stopHelper($mac);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 21 (a suppressed watchdog restart re-arms the 5s poll after another
# player's stopHelper killed it -- WR-02's other half: the poll must
# always be running while a live incident depends on it).
{
    my $macA = 'aa:bb:cc:dd:ee:21a';
    my $macB = 'aa:bb:cc:dd:ee:21b';
    $STREAM_ACTIVE = 0;

    my $real_starts_21 = 0;
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $real_starts_21++;
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($macA);
    my ($helperA) = grep { $_->mac eq $macA } $DM->helperInstances;
    ok($helperA, "Case 21: helper A registered");

    $DM->startHelper($macB);
    my ($helperB) = grep { $_->mac eq $macB } $DM->helperInstances;
    ok($helperB && $helperB->alive, "Case 21: helper B registered and alive");

    my $stateA = $DM->_crashStateFor($macA);
    %$stateA = (count => 1, switch_crashes => 0, last_crash_at => time() - 10, next_allowed_at => 0);
    $helperA->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1 -- live incident
    my $tA_before = $DM->switchedAtFor($macA);

    my @setTimerCalls;
    my @killTimerCalls;
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer   = sub { push @setTimerCalls, [@_]; };
        local *Slim::Utils::Timers::killTimers = sub { push @killTimerCalls, [@_]; };

        $DM->stopHelper($macB);
        my @killedPoll = grep { @$_ && $_->[-1] == \&Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll }
            @killTimerCalls;
        ok(scalar(@killedPoll) >= 1,
            "Case 21: stopHelper(B) kills the poll timer (no alive helper left)");

        @setTimerCalls  = ();
        @killTimerCalls = ();

        $DM->startHelper($macA);
        is($real_starts_21, 0, "Case 21: A is not restarted by the suppressed watchdog-shaped call");

        my @rearmed = grep { @$_ && $_->[-1] == \&Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll }
            @setTimerCalls;
        is(scalar(@rearmed), 1, "Case 21: exactly one poll re-arm setTimer call");
    }

    is($stateA->{count}, 1, "Case 21: A's crash count unchanged by the suppressed call");
    is($DM->switchedAtFor($macA), $tA_before, "Case 21: A's switchedAtFor unchanged");

    $DM->stopHelper($macA);
    $DM->stopHelper($macB);
}

# ============================================================
# Phase 83.3 plan 17 (WR-01, WR-03): once a generation record carries
# rollback_exhausted, no player's rollback is ever re-run or re-armed on
# it -- decided once, in _rollbackAfterSwitch, from the record. WR-03:
# stopHelper cancels a dead helper's port polls too (not just an alive
# helper's), making the "double-handling is structurally impossible"
# claim actually true.
# ============================================================

# Case 20 (a-c)
{
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', {
        active_version       => '1.3.8.93',
        previous_version     => undef,
        previous_expiry_days => undef,
        switched_at          => time() - 30,
        reason               => 'expiry',
        proven               => 0,
    }, 'never');

    local $ROLLBACK_RESULT = [0, 'no_previous'];

    my $macA = 'aa:bb:cc:dd:ee:20a';
    my $macB = 'aa:bb:cc:dd:ee:20b';
    my $macC = 'aa:bb:cc:dd:ee:20c';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($macA);
    ok(defined $DM->switchedAtFor($macA), "Case 20 setup: A anchored");
    $DM->startHelper($macB);
    my $tB = $DM->switchedAtFor($macB);
    ok(defined $tB, "Case 20 setup: B anchored");
    $DM->startHelper($macC);
    ok(defined $DM->switchedAtFor($macC), "Case 20 setup: C anchored");

    my ($helperB) = grep { $_->mac eq $macB } $DM->helperInstances;

    # A's own failed rollback exhausts the generation (plan 16 shape,
    # pinned again here as the precondition for the rest of this case).
    $DM->_rollbackAfterSwitch($macA, 'test');
    is($DM->switchedAtFor($macA), undef, "Case 20 setup: A's own failed rollback clears its anchor");

    my $gen20setup = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen20setup->{rollback_exhausted}, 1, "Case 20 setup: generation now exhausted");

    # C is not exercised again until Case 20b's noteStartupFailure check,
    # which reads %switchedAt directly and does not need C registered --
    # stop it NOW so it cannot interfere as a stray alive/anchored/eligible
    # candidate in Case 20a's _proveGenerations() call below (isolation
    # only; %switchedAt/%anchoredGeneration/%proofEligible/%proofSince are
    # untouched by stopHelper).
    $DM->stopHelper($macC);

    # A same-second re-stamp would otherwise be invisible -- push the
    # exhaustion timestamp into the past so a LATER re-stamp (the WR-01
    # defect) becomes observable, then capture it for later comparison.
    $gen20setup->{rollback_exhausted_at} = time() - 100;
    Slim::Utils::Cache->new('spoton', 4)->set('spoton_soloist_generation', $gen20setup, 'never');
    my $exhausted_at_before = $gen20setup->{rollback_exhausted_at};

    # Case 20a: B crashes a third time within its own window -- the guard
    # must fire for EVERY player, not just the one whose failed rollback
    # exhausted the generation.
    my $stateB = $DM->_crashStateFor($macB);
    %$stateB = (count => 2, switch_crashes => 2, last_crash_at => time() - 10, next_allowed_at => 0);
    $helperB->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1

    my $rb_before_20a = scalar(@ROLLBACK_CALLS);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is(scalar(@ROLLBACK_CALLS) - $rb_before_20a, 0,
        "Case 20a: no rollback re-run for B on an exhausted generation");

    my $gen20a = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen20a->{rollback_exhausted_at}, $exhausted_at_before,
        "Case 20a: rollback_exhausted_at not re-stamped");
    is($DM->switchedAtFor($macB), undef,
        "Case 20a: B's own anchor cleared by the guard (no rollback attempted)");

    # B's proof clock, eligibility and anchoredGeneration survive the
    # guard -- set alive directly (not via startHelper, which would
    # re-anchor it) and prove the generation.
    $helperB->_proc(Test::FakeProc->new(alive => 1));
    is($DM->_proveGenerations($tB + 1801), 1,
        "Case 20a: B's proof clock survived the guard -- the generation is proven");
    my $gen20a2 = Slim::Utils::Cache->new('spoton', 4)->get('spoton_soloist_generation');
    is($gen20a2->{proven}, 1, "Case 20a: record reads proven");
    is($gen20a2->{proven_by}, $macB, "Case 20a: proven_by is B");

    # Case 20b: C's own startup failure (never crashed, never restarted) --
    # same guard, same outcome, for a THIRD player, via a different caller.
    my $rb_before_20b = scalar(@ROLLBACK_CALLS);
    $DM->noteStartupFailure($macC, 'x');
    is(scalar(@ROLLBACK_CALLS) - $rb_before_20b, 0,
        "Case 20b: no rollback for C either -- exhausted generation");
    is($DM->switchedAtFor($macC), undef, "Case 20b: C's own anchor cleared by the guard");

    $DM->stopHelper($macA);
    $DM->stopHelper($macB);

    # Case 20c: _processPendingSwitches must write NO anchor for a pending
    # switch consumed on an exhausted generation -- neither the alive
    # branch (player idle, restarted in place) nor the dead branch
    # (player already down when the switch is consumed).
    my $macD = 'aa:bb:cc:dd:ee:20d';
    my $macE = 'aa:bb:cc:dd:ee:20e';

    $DM->startHelper($macD);
    is($DM->switchedAtFor($macD), undef,
        "Case 20c setup: D anchored proof-only (no rollback window, exhausted generation)");

    $DM->onSoloistBinaryReplaced({ version => '1.3.8.94', reason => 'test' });
    $DM->_processPendingSwitches;
    is($DM->switchedAtFor($macD), undef,
        "Case 20c: D's alive branch (restarted in place) writes no anchor on an exhausted generation");
    $DM->stopHelper($macD);

    $DM->startHelper($macE);
    is($DM->switchedAtFor($macE), undef,
        "Case 20c setup: E anchored proof-only (no rollback window, exhausted generation)");

    $DM->onSoloistBinaryReplaced({ version => '1.3.8.95', reason => 'test2' });
    my ($helperE) = grep { $_->mac eq $macE } $DM->helperInstances;
    $helperE->_proc(Test::FakeProc->new(alive => 0));    # dead before the switch is consumed
    $DM->_processPendingSwitches;
    is($DM->switchedAtFor($macE), undef,
        "Case 20c: E's dead branch (no daemon to interrupt) writes no anchor on an exhausted generation");
    ok(!exists $DM->pendingBinarySwitches->{$macE},
        "Case 20c: E's pending entry consumed");

    $DM->stopHelper($macE);
    Slim::Utils::Cache->new('spoton', 4)->remove('spoton_soloist_generation');
}

# Case 22 (stopHelper cancels a dead helper's port polls, not only an
# alive helper's -- the WR-03 mechanism that makes noteExpiredExit's
# stale-object guard the actual single-shot safeguard).
{
    my $mac = 'aa:bb:cc:dd:ee:22';
    $STREAM_ACTIVE = 0;

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    ok($helper, "Case 22: helper registered");
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));    # dead, rc=1

    my $cancelCalls = 0;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::SoloistDaemon::_cancelPortPolls = sub { $cancelCalls++; };
        $DM->stopHelper($mac);
    }
    is($cancelCalls, 1, "Case 22: stopHelper cancels a dead helper's port polls exactly once");

    my ($stillRegistered) = grep { $_->mac eq $mac } $DM->helperInstances;
    ok(!$stillRegistered, "Case 22: helper no longer registered after stopHelper");
}

# ============================================================
# 84.1 plan 03 (D-04/D-05/D-06): Soloist health -- an alive-but-not-doing-
# its-job daemon is stopped by _soloistHealthTick (called from the alive
# path of _streamAlivePoll) and restarted/counted by the SAME poll's
# existing dead-branch crash classification, never by a second restart
# owner (G-83.3-5).
# ============================================================

# Case 23a (login deadline -> health stop -> crash poll restarts, count 1)
# and Case 23e (a no_login health stop never feeds D-07 criterion (b)).
{
    my $mac = 'aa:bb:cc:dd:ee:23a';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    my $start_before = $START_CALLS;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok(!$helper->alive, "Case 23a: a never-logged-in daemon past the login deadline is stopped");
    is($DM->soloistHealthFor($mac)->{last_reason}, 'no_login', "Case 23a: health record shows no_login");
    is($DM->soloistHealthFor($mac)->{restarts}, 1, "Case 23a: health restarts counter is 1");
    is($START_CALLS, $start_before, "Case 23a: the tick itself never restarts (stop-only)");

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{count}, 1, "Case 23a: the crash poll's dead branch counts it as crash #1");
    ok($state->{next_allowed_at} > time() - 1, "Case 23a: a backoff delay was armed");
    is($START_CALLS, $start_before + 1, "Case 23a: the poll's crash branch restarted the helper");

    is($state->{switch_crashes}, 0, "Case 23e: a no_login health stop never feeds D-07 criterion (b)");
    ok(!defined $helper->_healthStopReason, "Case 23e: the marker is cleared by the dead branch");

    $DM->stopHelper($mac);
}

# Case 23b (boundary: exactly 29s uptime is NOT yet a violation)
{
    my $mac = 'aa:bb:cc:dd:ee:23b';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 29 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok($helper->alive, "Case 23b: 29s uptime is not yet a login-deadline violation");
    ok(!defined $DM->soloistHealthFor($mac), "Case 23b: no health record created");
    is($state->{count}, 0, "Case 23b: no crash counted");

    $DM->stopHelper($mac);
}

# Case 23c (concurrency: a helper that crashed on its own before the tick
# ever ran is classified exactly once by the poll's existing dead branch --
# a health stop and a concurrent crash can never produce two restarts).
{
    my $mac = 'aa:bb:cc:dd:ee:23c';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    # Dead BEFORE the poll ever runs -- the tick never sees this helper alive.
    $helper->_proc(Test::FakeProc->new(status => 1 << 8, alive => 0));

    my $start_before = $START_CALLS;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is($state->{count}, 1, "Case 23c: exactly one crash counted");
    ok(!defined $DM->soloistHealthFor($mac),
        "Case 23c: no health-tick record -- the tick never ran on an already-dead helper");
    is($START_CALLS, $start_before + 1, "Case 23c: the poll restarted it once");

    $DM->stopHelper($mac);
}

# Case 23d (never-paired exemption, T-84.1-21): a daemon that has never
# been paired in the Spotify app (no settings/Users/ on disk) is never
# stopped by the login deadline, however long it stays not-logged-in.
{
    my $mac = 'aa:bb:cc:dd:ee:23d';
    local $PAIRED_ON_DISK = 0;

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    my ($stop_before, $start_before) = ($STOP_CALLS, $START_CALLS);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23d: a never-paired daemon is never stopped by the login deadline");
    ok(!defined $DM->soloistHealthFor($mac), "Case 23d: no health record for a never-paired daemon");
    is($state->{count}, 0, "Case 23d: no crash counted");
    is($STOP_CALLS, $stop_before, "Case 23d: DaemonManager::stopHelper was never called");
    is($START_CALLS, $start_before, "Case 23d: DaemonManager::startHelper was never called again");

    # A second tick changes nothing -- no restart loop for a legitimately
    # unpaired player.
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23d: still alive after a second tick");
    is($STOP_CALLS, $stop_before, "Case 23d: still no stopHelper call after a second tick");

    $DM->stopHelper($mac);
}

# Case 23f (streak cap, T-84.1-21): a previously-paired daemon gets at most
# SOLOIST_NO_LOGIN_MAX_RESTARTS (3) consecutive no_login restarts; a login
# resets the streak.
{
    my $mac = 'aa:bb:cc:dd:ee:23f';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    for my $cycle (1 .. 3) {
        $helper->_startTimes([ time() - 31 ]);
        $helper->_control(Test::FakeControl->new(observed => {}));
        $state->{next_allowed_at} = 0;    # let the poll restart immediately
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();    # tick -> stopped
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();    # tick -> restarted
    }

    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    ok($helper->alive, "Case 23f: helper alive after three no_login restarts");
    is($DM->soloistHealthFor($mac)->{restarts}, 3, "Case 23f: three health restarts recorded");
    is($DM->soloistHealthFor($mac)->{no_login_streak}, 3, "Case 23f: no_login streak reached the cap");

    # A fourth unhealthy tick (still not logged in, still past the login
    # deadline from cycle 3's setup) hits the exhausted-streak branch --
    # no stop, no loop.
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23f: streak-exhausted daemon is left alone, not stopped a fourth time");
    is($DM->soloistHealthFor($mac)->{restarts}, 3, "Case 23f: restarts unchanged by the exhausted tick");

    # A seen login resets the streak. _control was cleared to undef by the
    # last stop() (SoloistDaemon::_shutdownExistingControl) -- a fresh
    # double, now reporting logged_in, stands in for the daemon actually
    # answering.
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1 }));
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($DM->soloistHealthFor($mac)->{no_login_streak}, 0, "Case 23f: a seen login resets the streak");

    $DM->stopHelper($mac);
}

# ============================================================
# 84-19 F-18-01 + F-18-02 (ONE change): network recovery. Login5->healthTick's
# (85-06; 85-14 deleted the PKCE refresh that used to own this edge) transient
# failure -> success edge calls DaemonManager->networkRecovered; the
# next health tick of each ALIVE, paired, NOT-playing, not-just-started
# Soloist daemon stops it with reason network_recovered (the crash poll
# restarts it, G-83.3-5), and the exhausted no_login give-up is re-armed.
# A playing daemon is never touched. The edge is observable only through
# Login5's health tick (no new probe): the stuck daemon's local state (logged_in,
# ws up, answering) looks healthy.
# ============================================================

# Case 23g (F-18-01): a paired daemon that gave up after
# SOLOIST_NO_LOGIN_MAX_RESTARTS no_login restarts is re-armed and restarted
# when the network comes back.
{
    my $mac = 'aa:bb:cc:dd:ee:23g';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $IS_PLAYING = 0;

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    for my $cycle (1 .. 3) {
        $helper->_startTimes([ time() - 31 ]);
        $helper->_control(Test::FakeControl->new(observed => {}));
        $state->{next_allowed_at} = 0;
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();    # stopped
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();    # restarted
    }
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23g: precondition -- exhausted daemon is left alone");
    is($DM->soloistHealthFor($mac)->{no_login_streak}, 3, "Case 23g: precondition -- streak exhausted");

    can_ok($DM, 'networkRecovered');
    eval { $DM->networkRecovered; 1 };
    my $start_before = $START_CALLS;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok(!$helper->alive, "Case 23g: network recovery stops the exhausted no_login daemon (give-up re-armed)");
    is($DM->soloistHealthFor($mac)->{last_reason}, 'network_recovered',
        "Case 23g: health record shows network_recovered");
    is($DM->soloistHealthFor($mac)->{no_login_streak} // 0, 0,
        "Case 23g: the exhausted no_login streak is cleared by the recovery edge");
    is($START_CALLS, $start_before, "Case 23g: the tick itself never restarts (stop-only)");

    $state->{next_allowed_at} = 0;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($START_CALLS, $start_before + 1, "Case 23g: the crash poll restarted it (single restart owner)");

    $DM->stopHelper($mac);
}

# Case 23h (F-18-02): a logged-in, WS-connected, answering (locally healthy)
# idle daemon -- the stuck-uplink state looks exactly like this -- is
# restarted once on the recovery edge; without an edge it is left alone.
{
    my $mac = 'aa:bb:cc:dd:ee:23h';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $IS_PLAYING = 0;

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    my $healthy = sub {
        $helper->_startTimes([ time() - 3600 ]);
        $helper->_control(Test::FakeControl->new(
            observed => { logged_in => 1, wsConnected => 1, authStateAt => time() }));
        $helper->_healthProbeSentAt(time() - 2);
    };
    $healthy->();
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23h: without a recovery edge a healthy idle daemon is left alone");

    eval { $DM->networkRecovered; 1 };
    my $start_before = $START_CALLS;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok(!$helper->alive, "Case 23h: network recovery stops a logged-in idle daemon (stuck uplink)");
    is($DM->soloistHealthFor($mac) && $DM->soloistHealthFor($mac)->{last_reason}, 'network_recovered',
        "Case 23h: health record shows network_recovered");
    is($START_CALLS, $start_before, "Case 23h: the tick itself never restarts (stop-only)");

    $state->{next_allowed_at} = 0;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($START_CALLS, $start_before + 1, "Case 23h: the crash poll restarted it once");

    # Case 23k (rate limit): a second edge right after the restart does not
    # stop the daemon again (no restart storm on a flapping network).
    ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $healthy->();
    eval { $DM->networkRecovered; 1 };
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23k: a second edge within the rate-limit window never restarts again");
    is(($DM->soloistHealthFor($mac) // {})->{restarts}, 1, "Case 23k: still exactly one health restart");

    $DM->stopHelper($mac);
}

# Case 23n (84-08, SEAM-6.2): networkRecovered selects the daemons by
# backendName, not by class -- an alive helper that answers 'librespot' is
# skipped, the same object answering 'soloist' is marked. Mutation evidence
# (84-08 SUMMARY): `eq 'soloist'` -> `eq 'soloistt'` in a scratch copy of
# DaemonManager.pm turns the positive cell red.
{
    my $mac = 'aa:bb:cc:dd:ee:23n';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    ok($helper && $helper->alive, 'Case 23n: precondition -- one alive daemon');
    my $others = do {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::SoloistDaemon::backendName = sub { 'librespot' };
        $DM->networkRecovered;
    };
    is($others, 0, "Case 23n: networkRecovered skips an alive helper whose backendName is 'librespot'");
    is($DM->networkRecovered, 1, "Case 23n: the same helper answering 'soloist' is marked (one health check)");
    $DM->stopHelper($mac);
}

# Case 23i: a daemon that is playing a SpotOn title is NEVER restarted by the
# recovery edge, and the edge is consumed -- it does not fire later once
# playback stops.
{
    my $mac = 'aa:bb:cc:dd:ee:23i';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 3600 ]);
    $helper->_control(Test::FakeControl->new(
        observed => { logged_in => 1, wsConnected => 1, authStateAt => time() }));
    $helper->_healthProbeSentAt(time() - 2);

    $IS_PLAYING = 1;
    $ELAPSED    = 50;
    # Seed the D-05 sample so its rising-time deferral cannot be what spares
    # the daemon: same song, time not rising -- an ordinary unhealthy
    # incident WOULD be stopped here.
    $helper->_healthLmsTime(50);
    $helper->_healthLmsSong($PLAYING_SONG);
    eval { $DM->networkRecovered; 1 };
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23i: a playing daemon is never restarted by the recovery edge");
    ok(!defined $DM->soloistHealthFor($mac), "Case 23i: no health stop recorded for the playing daemon");

    $IS_PLAYING = 0;
    $helper->_healthProbeSentAt(time() - 2);
    $helper->_control->observed->{authStateAt} = time();
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23i: the edge was consumed -- no deferred restart once playback stopped");

    $DM->stopHelper($mac);
}

# Case 23j: a never-paired daemon (nothing to reconnect) and a daemon that
# only just started (its own login deadline governs it) are left alone.
{
    my $mac = 'aa:bb:cc:dd:ee:23j';
    $IS_PLAYING = 0;
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    {
        local $PAIRED_ON_DISK = 0;
        $helper->_startTimes([ time() - 3600 ]);
        $helper->_control(Test::FakeControl->new(
            observed => { logged_in => 1, wsConnected => 1, authStateAt => time() }));
        $helper->_healthProbeSentAt(time() - 2);
        eval { $DM->networkRecovered; 1 };
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
        ok($helper->alive, "Case 23j: a never-paired daemon is not restarted by the recovery edge");
    }

    $helper->_startTimes([ time() - 5 ]);
    $helper->_control(Test::FakeControl->new(
        observed => { logged_in => 1, wsConnected => 1, authStateAt => time() }));
    $helper->_healthProbeSentAt(time() - 2);
    eval { $DM->networkRecovered; 1 };
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 23j: a daemon younger than the login deadline is not restarted by the edge");

    $DM->stopHelper($mac);
}

# Case 24a (answer deadline -> health stop -> crash poll restarts) and the
# probe-cadence behavior (send once, never re-probe while outstanding).
{
    my $mac = 'aa:bb:cc:dd:ee:24a';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 }));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    @Test::FakeControl::EXECUTED = ();
    $IS_PLAYING = 0;

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    is(scalar(@Test::FakeControl::EXECUTED), 1, "Case 24a: first tick sends exactly one probe intent");
    is_deeply($Test::FakeControl::EXECUTED[0], { op => 'probe', cmd => 'get_auth_state' },
        "Case 24a: the probe intent matches get_auth_state");
    ok(defined $helper->_healthProbeSentAt, "Case 24a: _healthProbeSentAt is set");
    ok($helper->alive, "Case 24a: helper still alive right after sending the probe");

    $helper->_healthProbeSentAt(time() - 6);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok(!$helper->alive, "Case 24a: a daemon that never answers within the deadline is stopped");
    is($DM->soloistHealthFor($mac)->{last_reason}, 'no_answer', "Case 24a: health record shows no_answer");
    is(scalar(@Test::FakeControl::EXECUTED), 1, "Case 24a: no re-probe while one was outstanding");

    $DM->stopHelper($mac);
}

# Case 24b (D-05 defers a would-be no_answer stop while LMS time rises) and
# Case 24c (the deferred stop still fires once time stops rising, and a
# no_answer health stop counts like a crash for D-07 criterion (b), unlike
# Case 23e's no_login).
{
    my $mac = 'aa:bb:cc:dd:ee:24b';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 }));
    $helper->_healthProbeSentAt(time() - 6);    # already outstanding, past the answer deadline
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    $IS_PLAYING = 1;

    $ELAPSED = 10;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 24b: first sample -- deferred, not yet stopped");
    ok(defined $helper->_healthUnhealthySince, "Case 24b: unhealthy_since is set by the first deferred tick");
    ok(!defined $DM->soloistHealthFor($mac), "Case 24b: nothing counted by a deferred tick");

    $ELAPSED = 12;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "Case 24b: rising LMS time defers the stop a second time");
    ok(defined $helper->_healthUnhealthySince, "Case 24b: unhealthy_since stays set, not cleared by rising time");
    ok(!defined $DM->soloistHealthFor($mac), "Case 24b: still nothing counted");

    # Case 24c: ELAPSED unchanged (not rising) -- the deferred stop fires.
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok(!$helper->alive, "Case 24c: the stop fires once LMS time stops rising");
    is($DM->soloistHealthFor($mac)->{last_reason}, 'no_answer', "Case 24c: health record shows no_answer");

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{count}, 1, "Case 24c: the crash poll's dead branch counts it as crash #1");
    is($state->{switch_crashes}, 1,
        "Case 24c: a no_answer health stop counts like a crash for D-07 criterion (b)");

    $DM->stopHelper($mac);
    $IS_PLAYING = 0;
}

# Case 24d (an answer that arrives before the deadline clears the unhealthy
# state -- no stop).
{
    my $mac = 'aa:bb:cc:dd:ee:24d';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 });
    $helper->_control($ctl);
    $helper->_healthProbeSentAt(time() - 3);
    $helper->_healthUnhealthySince(time());
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    $ctl->observed->{authStateAt} = time();
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok($helper->alive, "Case 24d: an answer before the deadline means no stop");
    ok(!defined $helper->_healthUnhealthySince, "Case 24d: unhealthy_since is cleared by the answer");

    $DM->stopHelper($mac);
}

# Case 24e (boundary: exactly 5s outstanding is NOT yet a violation -- the
# comparison is strict `>`, never `>=`; 24a's 6s already proves the stop
# side of the boundary).
{
    my $mac = 'aa:bb:cc:dd:ee:24e';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 }));
    $helper->_healthProbeSentAt(time() - 5);
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok($helper->alive, "Case 24e: exactly 5s outstanding is not yet a violation");

    $DM->stopHelper($mac);
}

# Region-scoped negative gate (T-84.1-03/G-83.3-5): _soloistHealthTick must
# never itself call startHelper/stopHelper -- the poll's dead branch is the
# single restart owner.
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm")
        or die "cannot read DaemonManager.pm: $!";
    local $/;
    my $src = <$fh>;
    close($fh);

    my ($tickBody) = $src =~ /^sub _soloistHealthTick \{(.*?)^sub \w/ms;
    ok(defined $tickBody, "source gate: found _soloistHealthTick's body");
    ok($tickBody !~ /\bstartHelper\(/, "source gate: _soloistHealthTick never calls startHelper(");
    ok($tickBody !~ /\bstopHelper\(/, "source gate: _soloistHealthTick never calls stopHelper(");
}

# Case 25 (Task 3): soloistHealthFor()/crashStateSnapshot() shapes -- a
# read-only, never-vivifying copy for the latter -- plus source assertions
# that the notice surface (Settings.pm/strings.txt) actually exists.
{
    my $mac = 'aa:bb:cc:dd:ee:25';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };

    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    my $health = $DM->soloistHealthFor($mac);
    is($health->{restarts}, 1, "Case 25: soloistHealthFor restarts is 1");
    is($health->{last_reason}, 'no_login', "Case 25: soloistHealthFor last_reason is no_login");
    ok(defined $health->{last_at} && $health->{last_at} <= time() && $health->{last_at} > time() - 5,
        "Case 25: soloistHealthFor last_at is a fresh epoch");
    ok(!defined $health->{unhealthy_since}, "Case 25: soloistHealthFor unhealthy_since is undef");

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    my $snap1 = $DM->crashStateSnapshot($mac);
    is($snap1->{count}, 1, "Case 25: crashStateSnapshot count is 1");
    $snap1->{count} = 999;    # mutate the COPY
    my $snap2 = $DM->crashStateSnapshot($mac);
    is($snap2->{count}, 1, "Case 25: mutating a returned snapshot does not change the next one (it is a copy)");

    ok(!defined $DM->crashStateSnapshot('never-seen-mac-25'),
        "Case 25: crashStateSnapshot on a never-seen MAC is undef");
    is(Plugins::SpotOn::Unified::DaemonManager::_crashIncidentLive('never-seen-mac-25', time()), 0,
        "Case 25: crashStateSnapshot never vivifies -- _crashIncidentLive still reads 0 afterwards");

    $DM->stopHelper($mac);
}

# Case 25 source assertions: the notice surface actually exists. 84-08: the
# per-player row is built by the Soloist role's settingsInfo; Settings.pm
# hands it its _formatHealthNotice formatter.
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Settings.pm")
        or die "cannot read Settings.pm: $!";
    local $/;
    my $src = <$fh>;
    close($fh);
    open(my $rfh, '<', "$project_dir/Plugins/SpotOn/Backend/Soloist.pm")
        or die "cannot read Backend/Soloist.pm: $!";
    my $role = <$rfh>;
    close($rfh);
    ok($role =~ /healthNotice\s*=>\s*\$fmt\{formatHealthNotice\}/, "Case 25: the Soloist role's settingsInfo fills healthNotice (84-08)");
    ok($src =~ /formatHealthNotice\s*=>\s*\\&_formatHealthNotice/, "Case 25: Settings.pm hands its _formatHealthNotice to settingsInfo (84-08)");
    ok($src =~ /_formatHealthNotice/, "Case 25: Settings.pm contains _formatHealthNotice");
}
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/strings.txt")
        or die "cannot read strings.txt: $!";
    my @lines = <$fh>;
    close($fh);
    my $count = 0;
    my $in_block = 0;
    for my $line (@lines) {
        if ($line =~ /^PLUGIN_SPOTON_SOLOIST_HEALTH_RESTARTED$/) { $in_block = 1; next; }
        if ($in_block && $line =~ /^[A-Z_]/) { last; }
        $count++ if $in_block && $line =~ /^\t/;
    }
    is($count, 11, "Case 25: strings.txt has exactly 11 language lines under PLUGIN_SPOTON_SOLOIST_HEALTH_RESTARTED");
}

# ============================================================
# 84.1-08 (WR-03..WR-06, IN-05): no probe/stamp/answer-deadline without a
# connected WS; a logged-in daemon whose WS stays down past SoloistWS's own
# reconnect backoff cap restarts as ws_unreachable; the login deadline runs
# from the later of spawn and logout; the D-05 samples are per-incident and
# per-song; the restart notice ages out; a tick exception cannot stop the
# poll.
# ============================================================

# 84.1-08 Case 26 setup: parse SoloistWS's own RECONNECT_DELAY_MAX so the
# FakeWS double used below can never drift from the product constant.
my $CAP_84108;
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Unified/SoloistWS.pm")
        or die "cannot read SoloistWS.pm: $!";
    local $/;
    my $src = <$fh>;
    close($fh);
    ($CAP_84108) = $src =~ /^use constant RECONNECT_DELAY_MAX => (\d+);/m;
}
ok(defined $CAP_84108, "84.1-08 Case 26: SoloistWS cap parsed");

{
    package Test::FakeWS;
    sub new {
        my ($class, %args) = @_;
        return bless {
            connected      => ($args{connected} // 1),
            reconnectDelay => ($args{reconnectDelay} // 1),
        }, $class;
    }
    sub connected      { my $self = shift; $self->{connected}      = shift if @_; return $self->{connected}; }
    sub reconnectDelay { my $self = shift; $self->{reconnectDelay} = shift if @_; return $self->{reconnectDelay}; }
    sub RECONNECT_DELAY_MAX { return $CAP_84108; }
}

# --- 84.1-08 Case 26 (WR-03, D-04): no probe, stamp or answer deadline
# without a connected WS -- an outage in progress (reconnectDelay 16,
# below the cap) ---
{
    my $mac = 'aa:bb:cc:dd:ee:26';
    # A pre-fix run of this case can still stop the helper (the defect
    # this case is about), and the crash poll's dead branch would then
    # restart it for real on the NEXT poll below -- override start() so
    # that path never touches the real Proc::Background-backed daemon
    # spawn, on either the RED or the GREEN run.
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 0 });
    $helper->_control($ctl);
    $helper->_ws(Test::FakeWS->new(connected => 0, reconnectDelay => 16));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    @Test::FakeControl::EXECUTED = ();

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is(scalar(@Test::FakeControl::EXECUTED), 0, "84.1-08 Case 26a: no probe intent sent while the WS is down");
    ok(!defined $helper->_healthProbeSentAt, "84.1-08 Case 26a: _healthProbeSentAt stays undef");
    ok($helper->alive, "84.1-08 Case 26a: helper stays alive");

    $helper->_healthProbeSentAt(time() - 6);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 26b: a stale outstanding stamp made moot by the WS drop does not stop the helper");
    ok(!defined $DM->soloistHealthFor($mac), "84.1-08 Case 26b: no health record");
    ok(!defined $helper->_healthProbeSentAt, "84.1-08 Case 26b: the stale stamp is dropped");

    $ctl->observed->{wsConnected} = 1;
    # Pre-fix code may have already stopped the helper in 26b (it ignores
    # wsConnected entirely), which tears down _ws as part of a real stop() --
    # re-attach defensively so this step never dereferences undef on either
    # the RED or the GREEN run.
    $helper->_ws(Test::FakeWS->new(connected => 0, reconnectDelay => 16)) unless $helper->_ws;
    $helper->_ws->connected(1);
    $helper->_ws->reconnectDelay(1);
    @Test::FakeControl::EXECUTED = ();
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is(scalar(@Test::FakeControl::EXECUTED), 1, "84.1-08 Case 26c: the WS reconnecting resumes exactly one probe");
    ok(defined $helper->_healthProbeSentAt, "84.1-08 Case 26c: the probe is stamped again");

    $DM->stopHelper($mac);
}

# --- 84.1-08 Case 26d (WR-03 ws_unreachable, D-04) and Case 26g (D-07
# criterion (b) unchanged -- a ws_unreachable health stop counts like a
# crash, exactly as Case 24c already proves for no_answer) ---
{
    my $mac = 'aa:bb:cc:dd:ee:26d';
    # Case 26g's second poll restarts this helper for real once it is
    # correctly stopped (post-fix) -- keep it off the real Proc::Background
    # spawn path, same as the Case 26(a-c) block above.
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 0 }));
    $helper->_ws(Test::FakeWS->new(connected => 0, reconnectDelay => $CAP_84108));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    $IS_PLAYING = 0;

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();

    ok(!$helper->alive, "84.1-08 Case 26d: a WS down at the reconnect cap stops the helper");
    my $health26d = $DM->soloistHealthFor($mac) || {};
    is($health26d->{last_reason}, 'ws_unreachable', "84.1-08 Case 26d: health record shows ws_unreachable");
    is($health26d->{restarts}, 1, "84.1-08 Case 26d: restarts is 1");

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    is($state->{count}, 1, "84.1-08 Case 26g: the crash poll's dead branch counts it as crash #1");
    is($state->{switch_crashes}, 1,
        "84.1-08 Case 26g: a ws_unreachable health stop counts like a crash for D-07 criterion (b)");

    $DM->stopHelper($mac);
}

# --- 84.1-08 Case 26e (below the cap, D-04/D-06): nothing is restarted
# before SoloistWS's own cap, and no WS object at all is the same as one
# that has not reached it ---
{
    my $mac = 'aa:bb:cc:dd:ee:26e';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 0 }));
    $helper->_ws(Test::FakeWS->new(connected => 0, reconnectDelay => 16));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    $IS_PLAYING = 0;

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 26e: below the reconnect cap, the helper stays alive");
    ok(!defined $DM->soloistHealthFor($mac), "84.1-08 Case 26e: no health record below the cap");

    $helper->_ws(undef);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 26e: no WS object at all -- helper stays alive");
    ok(!defined $DM->soloistHealthFor($mac), "84.1-08 Case 26e: still no health record with no WS object");

    $DM->stopHelper($mac);
}

# --- 84.1-08 Case 26f (D-05 on the new reason): a ws_unreachable stop
# during our playback defers while LMS time rises and fires only once it
# stops rising, exactly like no_login and no_answer ---
{
    my $mac = 'aa:bb:cc:dd:ee:26f';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 0 }));
    $helper->_ws(Test::FakeWS->new(connected => 0, reconnectDelay => $CAP_84108));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    $IS_PLAYING = 1;
    $PLAYING_SONG = bless {}, 'Test::FakePlayingSong';

    $ELAPSED = 10;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 26f: ELAPSED 10 -- deferred");
    is($helper->_healthLmsTime, 10, "84.1-08 Case 26f: _healthLmsTime is 10");

    $ELAPSED = 12;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 26f: ELAPSED 12 -- still deferred (rising)");

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok(!$helper->alive, "84.1-08 Case 26f: ELAPSED unchanged -- the stop fires");
    is((($DM->soloistHealthFor($mac) || {})->{last_reason}), 'ws_unreachable', "84.1-08 Case 26f: last_reason is ws_unreachable");

    $DM->stopHelper($mac);
    $IS_PLAYING = 0;
    $PLAYING_SONG = bless {}, 'Test::FakePlayingSong';
}

# --- 84.1-08 Case 27 (WR-04, D-04/D-06): the login deadline runs from the
# LATER of spawn and logout ---
{
    my $mac = 'aa:bb:cc:dd:ee:27a';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 3600 ]);
    $helper->_control(Test::FakeControl->new(
        observed => { logged_in => 0, wsConnected => 1, loggedOutAt => time() - 10 }));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 27a: a logout 10s ago still holds the 30s grace -- no stop");

    $DM->stopHelper($mac);
}
{
    my $mac = 'aa:bb:cc:dd:ee:27b';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 3600 ]);
    $helper->_control(Test::FakeControl->new(
        observed => { logged_in => 0, wsConnected => 1, loggedOutAt => time() - 31 }));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok(!$helper->alive, "84.1-08 Case 27b: a logout 31s ago past the 30s grace -- stopped");
    is($DM->soloistHealthFor($mac)->{last_reason}, 'no_login', "84.1-08 Case 27b: last_reason is no_login");

    $DM->stopHelper($mac);
}
{
    my $mac = 'aa:bb:cc:dd:ee:27c';
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 3600 ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 0, wsConnected => 1 }));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok(!$helper->alive, "84.1-08 Case 27c: never logged in -- stopped at uptime 3600, as before");
    is($DM->soloistHealthFor($mac)->{last_reason}, 'no_login', "84.1-08 Case 27c: last_reason is no_login");

    $DM->stopHelper($mac);
}

# --- 84.1-08 Case 28 (WR-05, D-05): the D-05 sample lives for one
# incident and one Song, never compared across either ---
{
    my $mac = 'aa:bb:cc:dd:ee:28a';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 });
    $helper->_control($ctl);
    $helper->_healthProbeSentAt(time() - 6);
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    $IS_PLAYING = 1;
    $PLAYING_SONG = bless {}, 'Test::FakePlayingSong';

    $ELAPSED = 200;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 28a: deferred at ELAPSED 200");
    is($helper->_healthLmsTime, 200, "84.1-08 Case 28a: _healthLmsTime is 200");

    # An answer arrives -- no reason this tick, the sample is cleared.
    $ctl->observed->{authStateAt} = time();
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 28a: an answer clears the incident");
    ok(!defined $helper->_healthLmsTime, "84.1-08 Case 28a: _healthLmsTime is undef after the answer");

    # A genuinely new incident (a fresh overdue probe) on the SAME song, at
    # a LOWER elapsed value -- it is a first sample, not compared to 200.
    $ctl->observed->{authStateAt} = time() - 100;
    $helper->_healthProbeSentAt(time() - 6);
    $ELAPSED = 30;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 28a: a new incident at ELAPSED 30 is a first sample -- deferred, not stopped");
    is($helper->_healthLmsTime, 30, "84.1-08 Case 28a: _healthLmsTime is the new first sample (30)");

    $DM->stopHelper($mac);
    $IS_PLAYING = 0;
}
{
    my $mac = 'aa:bb:cc:dd:ee:28b';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 120 ]);
    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 });
    $helper->_control($ctl);
    $helper->_healthProbeSentAt(time() - 6);
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    $IS_PLAYING = 1;
    my $songA = bless {}, 'Test::FakePlayingSong';
    $PLAYING_SONG = $songA;

    $ELAPSED = 250;
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 28b: deferred at ELAPSED 250 on song A");

    my $songB = bless {}, 'Test::FakePlayingSong';
    $PLAYING_SONG = $songB;
    $ELAPSED = 3;
    $helper->_healthProbeSentAt(time() - 6);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok($helper->alive, "84.1-08 Case 28b: a NEW song object at a LOWER elapsed value is still a first sample -- deferred");
    is($helper->_healthLmsTime, 3, "84.1-08 Case 28b: _healthLmsTime is 3 (song B's first sample)");

    $helper->_healthProbeSentAt(time() - 6);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    ok(!$helper->alive, "84.1-08 Case 28b: ELAPSED unchanged on song B -- the stop fires (a frozen stream is still stopped)");
    ok(!defined $helper->_healthLmsTime, "84.1-08 Case 28c: _healthLmsTime is undef after the health stop");
    ok(!defined $helper->_healthLmsSong, "84.1-08 Case 28c: _healthLmsSong is undef after the health stop");

    $DM->stopHelper($mac);
    $IS_PLAYING = 0;
    $PLAYING_SONG = bless {}, 'Test::FakePlayingSong';
}

# --- 84.1-08 Case 29 (WR-06, D-04): the restart notice ages out once the
# daemon has been logged in, WS-connected and answering for
# CRASH_BACKOFF_RESET_AFTER seconds since the stop. Calls
# _soloistHealthExpireNotice DIRECTLY (not through _soloistHealthTick) --
# WR-06 is tested in isolation from WR-03's own probe/deadline logic,
# which a fabricated _healthProbeSentAt/authStateAt pair could otherwise
# trip into a fresh no_answer/ws_unreachable stop of its own. ---
{
    my $mac = 'aa:bb:cc:dd:ee:29';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);

    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    my $T = $DM->soloistHealthFor($mac)->{last_at};
    ok(defined $T, "84.1-08 Case 29 setup: a no_login health stop created a record");

    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1, authStateAt => $T + 10 });
    $DM->_soloistHealthExpireNotice($mac, $ctl, $T + 601);
    ok(!defined $DM->soloistHealthFor($mac),
        "84.1-08 Case 29: the notice ages out after 600s logged in, connected and answering");

    $DM->stopHelper($mac);
}
# Negative controls (WR-06), each on its own fresh no_login-stop record.
{
    my $mac = 'aa:bb:cc:dd:ee:29n1';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    my $T = $DM->soloistHealthFor($mac)->{last_at};

    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1, authStateAt => $T + 10 });
    $DM->_soloistHealthExpireNotice($mac, $ctl, $T + 100);
    ok(defined $DM->soloistHealthFor($mac), "84.1-08 Case 29 negative control (now T+100): the notice is kept");

    $DM->stopHelper($mac);
}
{
    my $mac = 'aa:bb:cc:dd:ee:29n2';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    my $T = $DM->soloistHealthFor($mac)->{last_at};

    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1, authStateAt => $T - 1 });
    $DM->_soloistHealthExpireNotice($mac, $ctl, $T + 601);
    ok(defined $DM->soloistHealthFor($mac),
        "84.1-08 Case 29 negative control (authStateAt T-1, no answer since the stop): the notice is kept");

    $DM->stopHelper($mac);
}
{
    my $mac = 'aa:bb:cc:dd:ee:29n3';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() - 31 ]);
    $helper->_control(Test::FakeControl->new(observed => {}));
    my $state = $DM->_crashStateFor($mac);
    %$state = (count => 0, last_crash_at => 0, next_allowed_at => 0, switch_crashes => 0);
    Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
    my $T = $DM->soloistHealthFor($mac)->{last_at};

    my $ctl = Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 0, authStateAt => $T + 10 });
    $DM->_soloistHealthExpireNotice($mac, $ctl, $T + 601);
    ok(defined $DM->soloistHealthFor($mac), "84.1-08 Case 29 negative control (wsConnected 0): the notice is kept");

    $DM->stopHelper($mac);
}

# --- 84.1-08 Case 30 (IN-05, D-04): an exception from _soloistHealthTick
# is caught, WARN-logged, and the 5s _streamAlivePoll still re-arms ---
{
    my $mac = 'aa:bb:cc:dd:ee:30';
    local *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        $_[0]->_proc(Test::FakeProc->new(alive => 1));
        1;
    };
    $DM->startHelper($mac);
    my ($helper) = grep { $_->mac eq $mac } $DM->helperInstances;
    $helper->_startTimes([ time() ]);
    $helper->_control(Test::FakeControl->new(observed => { logged_in => 1, wsConnected => 1 }));

    my @setTimerCalls;
    my @warnCalls;
    my $ok;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::_soloistHealthTick = sub { die "boom (Case 30)\n"; };
        local *Slim::Utils::Timers::setTimer = sub { push @setTimerCalls, [@_]; };
        local *Slim::Utils::Log::warn        = sub { my $self = shift; push @warnCalls, join('', @_); };
        $ok = eval { Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll(); 1 };
    }
    ok($ok, "84.1-08 Case 30: _streamAlivePoll does not die when _soloistHealthTick throws");
    my @rearmed = grep { @$_ && $_->[-1] == \&Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll } @setTimerCalls;
    ok(scalar(@rearmed) >= 1, "84.1-08 Case 30: the poll still re-arms its own timer");
    ok((grep { /health tick failed/ } @warnCalls), "84.1-08 Case 30: a WARN line matches 'health tick failed'");

    $DM->stopHelper($mac);
}

# (84-09: the W2 librespot-exit cells of this file are
# t/librespot/51_soloist_switch_librespot.t over the REAL Backend::Librespot and
# t/core/51_soloist_switch_core.t over a mocked role.)

done_testing();

