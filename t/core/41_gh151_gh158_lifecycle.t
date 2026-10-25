#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# ============================================================
# Phase 76-05 gap fill (Nyquist validation): GH-151 (power save/restore)
# and GH-158 (group pause-skip-play restart loop). Prior coverage
# (t/37_connect_lifecycle.t) is grep-gate only -- this test drives the
# real _connectEvent()/_restorePowerAfterConnect() code with a fake
# client/request pair, reusing the harness pattern from
# t/38_autoplay_gate.t.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Connect.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Connect.pm not present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
# 84-17: info lines are recorded (INFOLOG is switched on below) so the via /
# deferred log lines can be asserted; every other level stays silent.
our @LINES;
sub info  { my $self = shift; push @LINES, join('', @_); }
# 84.3-01: warn lines are recorded too (the context-end settle is a warn line).
our @WARNS;
sub warn  { my $self = shift; push @WARNS, join('', @_); }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( diagnosticMode => 0 );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless {}, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs' }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
# 84.3-01: a recorder (copied from t/soloist/44_soloist_control.t) -- our @TIMERS
# holds [$obj, $when, $cb, @extra_args]; fire_due($now) fires and removes every
# timer whose $when <= $now, in order. The 84-17 section below re-installs an
# equivalent setTimer/killTimers at runtime.
our @TIMERS;
sub setTimer {
    my ($obj, $when, $cb, @args) = @_;
    push @TIMERS, [$obj, $when, $cb, @args];
    return;
}
sub killTimers {
    my ($obj, $cb) = @_;
    @TIMERS = grep { !($_->[0] == $obj && $_->[2] == $cb) } @TIMERS;
    return;
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
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"} = sub {
        require JSON::PP;
        return JSON::PP->new->canonical->encode($_[0]);
    };
    *{"${caller}::from_json"} = sub {
        require JSON::PP;
        return JSON::PP->new->utf8(1)->decode($_[0]);
    };
}
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END

write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our @EXECUTED;
# 84.1-08 (CR-01): a registry keyed by coderef, exactly like LMS's own
# %listeners (Request.pm:797/:821) -- a second subscribe of the same
# coderef replaces the first, matching production semantics.
our %LISTENERS;
our $SUBSCRIBE_CALLS = 0;
# 84.3-01: a hook run after every execute() -- the LMS state-table double
# (fake_lms_rows) models "pause discarded while BUFFERING" by construction.
our $ON_EXECUTE;
sub new {
    my ($class, $clientid, $cmdArray) = @_;
    return bless { clientid => $clientid, cmd => $cmdArray, source => undef }, $class;
}
sub source {
    my $self = shift;
    $self->{source} = shift if @_;
    return $self->{source};
}
sub execute {
    my $self = shift;
    push @EXECUTED, $self;
    $ON_EXECUTE->($self) if $ON_EXECUTE;
    return 1;
}
sub notifyFromArray { }
sub subscribe {
    my ($coderef, $spec) = @_;
    $SUBSCRIBE_CALLS++;
    $LISTENERS{$coderef} = [ $coderef, $spec ];
}
sub unsubscribe {
    my ($coderef) = @_;
    delete $LISTENERS{$coderef};
}
sub addDispatch { }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $UPTIME = 30;   # well past RESTART_START_GRACE -- these tests are about
                    # GH-151/GH-158, not the restart gate (covered by t/38).
sub uptime { return $UPTIME; }
sub helperForClient { return undef; }
# 84-07: Connect.pm reaches the daemon through the backend role. This
# per-file mock role has the Soloist shape (connectClaimGate 0), records
# every control()/notify() verb in @VERBS, and delegates to whatever
# Plugins::SpotOn::Soloist::Control->for_client returns -- so every
# `local *...::Control::for_client = sub { $ctl }` site below keeps driving
# its $ctl exactly as before (assertions unchanged).
our @VERBS;
sub backendFor { return bless { mac => (ref $_[1] ? $_[1]->id : $_[1]) }, 'Test::MockRole41'; }
package Test::MockRole41;
# 84-08: Connect.pm no longer `require`s Control itself -- the mock loads the
# Control stand-in on first use, exactly like the real Backend::Soloist.
sub _ctl { require Plugins::SpotOn::Soloist::Control; return Plugins::SpotOn::Soloist::Control->for_client($_[0]->{mac}); }
# 84-08 Task 3: the Soloist-shaped capabilities the moved Connect.pm sites
# read (connectEntry/claimOnStart/holdOnChange/readyReplaysLastTrack and the
# 84-17 hold timings from Control's constants).
sub capabilities {
    my $C = 'Plugins::SpotOn::Soloist::Control';
    return {
        connectClaimGate => 0, connectEntry => 'pertrack', claimOnStart => 0, holdOnChange => 1,
        readyReplaysLastTrack => 1,
        holdCapS     => ($C->can('HOLD_CAP_S')     ? $C->HOLD_CAP_S     : undef),
        holdRecheckS => ($C->can('HOLD_RECHECK_S') ? $C->HOLD_RECHECK_S : undef),
        holdMaxS     => ($C->can('HOLD_MAX_S')     ? $C->HOLD_MAX_S     : undef),
    };
}
sub state {
    my $c = $_[0]->_ctl;
    my $o = ($c && $c->can('observed')) ? ($c->observed || {}) : {};
    return { mode => ($c ? $c->mode : undef), status => $o->{status}, observedTrack => $o->{track},
             active => (defined $o->{is_active} ? ($o->{is_active} ? 1 : 0) : undef) };
}
sub control {
    my ($self, $verb, %a) = @_;
    push @Plugins::SpotOn::Unified::DaemonManager::VERBS, $verb;
    my $c = $self->_ctl or return 'down';
    my $rc = $verb eq 'pause'      ? $c->requestPause($a{isStop} ? 1 : 0)
           : $verb eq 'play'       ? $c->requestResume
           : $verb eq 'set_volume' ? $c->requestVolume(int($a{volume} // 0))
           : $verb eq 'skip_next'  ? $c->requestSkip('next', $a{reason})
           : $verb eq 'skip_prev'  ? $c->requestSkip('prev', $a{reason})
           : $verb eq 'restart'    ? $c->requestRestart($a{reason})
           : $verb eq 'seek'       ? (int($a{position_ms} // 0) == 0 ? $c->requestSkip('prev', 'time0') : 1)
           : return 'unsupported';
    return $rc ? 'ok' : 'declined';
}
# 84-08 Task 3: the Connect.pm notify events delegate to the Control
# stand-in exactly as Backend::Soloist does (so the `local for_client`
# sites below keep observing the same Control calls).
my %NOTIFY41 = (
    endForeignLeave     => sub { $_[0]->endForeignLeave($_[1]{reason}); },
    leaveBrowse         => sub { $_[0]->leaveBrowse; },
    leaveConnect        => sub { $_[0]->leaveConnect($_[1]{reason}); },
    clearHold           => sub { $_[0]->clearHold($_[1]{trackId}); },
    recordErrorOnce     => sub { $_[0]->_recordErrorOnce($_[1]{key}, $_[1]{level}, $_[1]{message}); },
    claimLost           => sub { $_[0]->observed->{is_active} = 0; },
    notePlaylistChanged => sub { $_[0]->notePlaylistChanged; },
    watchdogRing        => sub { $_[0]->watchdogRing($_[1]{url}); },
);
sub notify {
    my ($self, $event, %a) = @_;
    push @Plugins::SpotOn::Unified::DaemonManager::VERBS, "notify:$event";
    my $h = $NOTIFY41{$event} or return 'unsupported';
    my $c = $self->_ctl or return 'down';
    $h->($c, \%a);
    return 'ok';
}
sub query { return undef; }
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { return undef; }
1;
END

# 83.1-07 (Group C): _connectEvent now asks Control's mode once per event
# (the sharpened change/seek guards, the D-08 start guard, the resume
# re-entry). This harness has no SoloistDaemon (helperForClient => undef
# above), so no Control instance would ever be registered for this player
# either -- for_client => undef matches that same librespot-only scenario
# without pulling in the real Soloist/Control.pm (which would drag in real
# Slim::Player::Source/Playlist, unstubbed here by design: t/44/t/45 own
# that harness).
write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Control', <<'END');
package Plugins::SpotOn::Soloist::Control;
sub for_client { return undef; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 1 };    # 84-17: Slim::Utils::Log stub records info lines (@LINES)
    *main::DEBUGLOG = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");
require_ok('Slim::Control::Request')
    or BAIL_OUT("Failed to load the Slim::Control::Request stub");
require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the DaemonManager stub");
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");

require_ok('Plugins::SpotOn::Connect')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Connect");

package Test::FakeClient;
my $counter = 0;
sub new {
    my ($class, %args) = @_;
    $counter++;
    return bless {
        id         => "aa:bb:cc:dd:ee:$counter",
        pluginData => {},
        power      => 0,
        isPlaying  => 0,
        %args,
    }, $class;
}
sub id     { return $_[0]->{id}; }
sub master { return $_[0]; }
sub pluginData {
    my $self = shift;
    my $key  = shift;
    $self->{pluginData}{$key} = shift if @_;
    return $self->{pluginData}{$key};
}
sub power       { return $_[0]->{power}; }
sub isPlaying   { return $_[0]->{isPlaying}; }
sub isPaused    { return 0; }
sub playingSong { return undef; }
sub songElapsedSeconds { return 0; }

package Test::FakeRequest;
sub new {
    my ($class, $client, %params) = @_;
    return bless { client => $client, params => \%params }, $class;
}
sub client   { return $_[0]->{client}; }
sub getParam { return $_[0]->{params}{ $_[1] }; }

package main;

sub power_off_dispatched {
    return grep {
        $_->{cmd} && ref($_->{cmd}) eq 'ARRAY'
            && ($_->{cmd}[0] // '') eq 'power'
            && ($_->{cmd}[1] // '') eq '0'
    } @Slim::Control::Request::EXECUTED;
}

sub pause_unpause_dispatched {
    return grep {
        $_->{cmd} && ref($_->{cmd}) eq 'ARRAY'
            && ($_->{cmd}[0] // '') eq 'pause'
            && ($_->{cmd}[1] // '') eq '0'
    } @Slim::Control::Request::EXECUTED;
}

sub start_session {
    my ($client) = @_;
    @Slim::Control::Request::EXECUTED = ();
    my $request = Test::FakeRequest->new($client, _cmd => 'start', _p2 => undef);
    Plugins::SpotOn::Connect::_connectEvent($request);

    # Production clears the 'newTrack' transitional-window flag from
    # _finishNewTrack, invoked by the async metadata-fetch callback (H7).
    # These tests never issue a trackId, so no fetch is in flight -- clear
    # it here to simulate a session that is past its transitional window
    # (otherwise every subsequent 'stop'/'change' is swallowed by the H7
    # newTrack guard at the top of _connectEvent, unrelated to what these
    # tests exercise).
    $client->pluginData(newTrack => 0);
}

# ==================================================================
# GH-151 Scenario 1: player was OFF before the session -- session end
# ('inactive'-marked stop) must power it back OFF.
# ==================================================================
{
    my $client = Test::FakeClient->new(power => 0);
    start_session($client);
    is($client->pluginData('connectPrevPower'), 0,
        'GH-151: pre-Connect power state (off) saved on session start');

    @Slim::Control::Request::EXECUTED = ();
    my $stopReq = Test::FakeRequest->new($client, _cmd => 'stop', _p2 => 'inactive');
    Plugins::SpotOn::Connect::_connectEvent($stopReq);

    is(power_off_dispatched(), 1,
        'GH-151: session-end (inactive stop) restores power OFF for a player that was off before');
    is($client->pluginData('connectPrevPower'), undef,
        'GH-151: saved power flag is cleared after restore');
}

# ==================================================================
# GH-151 Scenario 2: player was ALREADY ON before the session -- session
# end must NOT power it off (ShairTunes prior art: never power ON, and
# never power OFF a player that was on before).
# ==================================================================
{
    my $client = Test::FakeClient->new(power => 1);
    start_session($client);
    is($client->pluginData('connectPrevPower'), 1,
        'GH-151: pre-Connect power state (on) saved on session start');

    @Slim::Control::Request::EXECUTED = ();
    my $stopReq = Test::FakeRequest->new($client, _cmd => 'stop', _p2 => 'inactive');
    Plugins::SpotOn::Connect::_connectEvent($stopReq);

    is(power_off_dispatched(), 0,
        'GH-151: session-end does NOT power off a player that was already on before the session');
}

# ==================================================================
# GH-158 Scenario 1: a genuine post-grace stop (Spotify-side pause) sets
# connectSessionPaused; a subsequent 'change' (skip while paused) must
# NOT force-unpause the player -- this is the fix for the group
# pause-skip-play restart loop (diag log: /stream GET while paused drove
# LMS's sync-group rebuffer machinery into a restart spiral).
# ==================================================================
{
    my $client = Test::FakeClient->new(power => 1, isPlaying => 0);
    start_session($client);

    # Bypass CONNECT_START_GRACE (12s) deterministically instead of sleeping.
    $client->pluginData(connectStartTime => 0);

    @Slim::Control::Request::EXECUTED = ();
    my $stopReq = Test::FakeRequest->new($client, _cmd => 'stop', _p2 => undef);
    Plugins::SpotOn::Connect::_connectEvent($stopReq);

    is($client->pluginData('connectSessionPaused'), 1,
        'GH-158: a genuine post-grace stop records the Spotify-side pause state');

    @Slim::Control::Request::EXECUTED = ();
    my $changeReq = Test::FakeRequest->new($client, _cmd => 'change', _p2 => 'newtrack123', _p3 => 'oldtrack456');
    Plugins::SpotOn::Connect::_connectEvent($changeReq);

    is(pause_unpause_dispatched(), 0,
        'GH-158: change handler does NOT force-unpause while connectSessionPaused is set (fixes the restart loop)');
}

# ==================================================================
# GH-158 Scenario 2 (non-regression): a 'change' event with NO tracked
# pause state (normal skip-while-playing scenario) still force-unpauses
# a stalled player -- the gate must not break the pre-existing recovery
# behavior.
# ==================================================================
{
    my $client = Test::FakeClient->new(power => 1, isPlaying => 0);
    start_session($client);
    # connectSessionPaused was cleared by start_session's 'start' handler;
    # no stop event fired, so it stays 0/false.

    @Slim::Control::Request::EXECUTED = ();
    my $changeReq = Test::FakeRequest->new($client, _cmd => 'change', _p2 => 'newtrack789', _p3 => 'oldtrack000');
    Plugins::SpotOn::Connect::_connectEvent($changeReq);

    is(pause_unpause_dispatched(), 1,
        'GH-158: change handler still force-unpauses when no Spotify-side pause was recorded (non-regression)');
}

# ==================================================================
# Debug session connect-seek-zeit-ab-null (2026-09-24, fix option A):
# ProtocolHandler::onStream now sets song->startOffset = seek target on
# the restart (t/29 "zeit-ab-null"). The daemon's later seek echo reaches
# the REAL CON-13 'seek' branch here, which must OVERWRITE absolutely
# (startOffset = position - player elapsed) -- never add to the value
# onStream left, or the clock would read 2*target. Drives the real
# _connectEvent with a song whose startOffset already holds the target.
# ==================================================================
package Test::FakeSongSO;
sub new         { my ($class, $so) = @_; return bless { so => $so }, $class; }
sub startOffset { my $self = shift; $self->{so} = shift if @_; return $self->{so}; }

package Test::FakeClientSong;
our @ISA = ('Test::FakeClient');
sub playingSong        { return $_[0]->{song}; }
sub songElapsedSeconds { return $_[0]->{elapsed}; }
# 84-26 F-24-2: the paused/controller view the resume branch and the change handler read
sub isPaused           { return $_[0]->{paused} ? 1 : 0; }
sub controller         { return $_[0]->{controller}; }

# 84-26 F-24-2: a StreamingController stub -- the two public streaming-state accessors, the streaming/playing
# song identity (the queued-next-song test) and a `jumpToTime` recorder of [ newtime, EXECUTED count at call time ]
# (the count proves the ORDER against the `['pause', 0]` the resume branch dispatches afterwards).
package Test::FakeController;
our @JUMPS;
sub new {
    my ($class, %a) = @_;
    return bless { streaming => 0, streamout => 0, streamingSong => undef, playingSong => undef, %a }, $class;
}
sub isStreaming   { return $_[0]->{streaming}; }
sub isStreamout   { return $_[0]->{streamout}; }
sub streamingSong { return $_[0]->{streamingSong}; }
sub playingSong   { return $_[0]->{playingSong}; }
sub jumpToTime {
    my ($self, $t) = @_;
    push @JUMPS, [ $t, scalar(@Slim::Control::Request::EXECUTED) ];
    return 1;
}

package main;

sub seek_echo {
    my ($client, $position) = @_;
    my $req = Test::FakeRequest->new($client, _cmd => 'seek', _p2 => $position);
    Plugins::SpotOn::Connect::_connectEvent($req);
}

# --- echo right after the restart: onStream left 150, echo 150.000 at
# player elapsed 0.07 -> 149.93 (clock = 150.00), not 299.93 ---
{
    my $song   = Test::FakeSongSO->new(150);
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => $song, elapsed => 0.07);
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');

    seek_echo($client, '150.000');
    is(sprintf('%.2f', $song->startOffset), '149.93',
        'zeit-ab-null: echo 150.000 at elapsed 0.07 over onStream\'s 150 -> startOffset 149.93 (absolute, no 2*target)');
    is(sprintf('%.2f', $song->startOffset + $client->songElapsedSeconds), '150.00',
        'zeit-ab-null: LMS clock after the echo = target (startOffset + elapsed = 150.00)');

    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- late echo: 20 s played since the restart, echo 170.000 -> 150.00
# (clock 170 = target + played), not 320 ---
{
    my $song   = Test::FakeSongSO->new(150);
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => $song, elapsed => 20);
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');

    seek_echo($client, '170.000');
    is(sprintf('%.2f', $song->startOffset), '150.00',
        'zeit-ab-null: late echo 170.000 at elapsed 20 over onStream\'s 150 -> startOffset 150.00 (clock = target + played)');

    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# ==================================================================
# 84.1-07 (D-02, C1-D02 edge 84.1-02-PLAN.md:35; revision 1, the accepted
# Mistral finding): empty/undef/spoton:// urls never leave connect, and a
# genuine foreign url does -- driven against the REAL _onNewSong (not just
# a t/37 source grep). N5 (revision 2) drives the REAL _onLmsStop.
# ==================================================================

package Test::FakeTrackD02;
sub new { my ($class, $url) = @_; return bless { url => $url }, $class; }
sub url { return $_[0]->{url}; }

package Test::FakeSongD02;
sub new {
    my ($class, %args) = @_;
    return bless { track => $args{track}, streamUrl => $args{streamUrl} }, $class;
}
sub track     { return $_[0]->{track}; }
sub streamUrl { return $_[0]->{streamUrl}; }

package Test::FakeRequestD02;
sub new    { my ($class, $client) = @_; return bless { client => $client }, $class; }
sub client { return $_[0]->{client}; }
sub source { return undef; }

# Test::FakeCtlD02 -- a tiny recording fake Control (mode + leaveConnect,
# and for N5 also endForeignLeave/requestPause). leaveConnect mirrors the
# REAL sub's order: calls the real releaseConnectClaim FIRST, then sets
# its own mode idle -- so the D-16 block below finds no claim, exactly as
# in production.
# observed{leftConnectForeign} is tracked too (WR-08, quick 260928-q2k):
# endForeignLeave deletes it, mirroring Control.pm:4893-4897, so W1..W3
# can assert on the marker itself, not only on the recorded call.
package Test::FakeCtlD02;
sub new {
    my ($class, %args) = @_;
    return bless {
        mode                  => ($args{mode} // 'connect'),
        client                => $args{client},
        leaveConnectCalls     => [],
        endForeignLeaveCalls  => [],
        requestPauseCalls     => [],
        observed              => ($args{observed} // {}),
    }, $class;
}
sub mode {
    my $self = shift;
    $self->{mode} = shift if @_;
    return $self->{mode};
}
sub leaveConnect {
    my ($self, $reason) = @_;
    push @{ $self->{leaveConnectCalls} }, $reason;
    Plugins::SpotOn::Connect->releaseConnectClaim($self->{client}, $reason);
    $self->{mode} = 'idle';
    return;
}
sub endForeignLeave {
    my ($self, $why) = @_;
    push @{ $self->{endForeignLeaveCalls} }, $why;
    delete $self->{observed}{leftConnectForeign};
    return;
}
sub requestPause {
    my ($self, @args) = @_;
    push @{ $self->{requestPauseCalls} }, [ @args ];
    return;
}

package main;

# Slim::Player::Source playmode stub (WR-08, quick 260928-q2k) -- mirrors
# t/45_soloist_control_watchdog.t:173-177. Default 'stop' = a genuine LMS
# stop, so the pre-existing N5/N7b/N7c/N7d cases (which never touch this)
# keep calling endForeignLeave exactly as before. Inline rather than
# write_stub: Connect.pm never `require`s this package, it calls the
# fully-qualified Slim::Player::Source::playmode($client) at run time, the
# way Control.pm's requestPause does (Control.pm:632).
package Slim::Player::Source;
our $PLAYMODE = 'stop';
sub playmode { return $PLAYMODE; }
package main;

# _d02_onNewSong(SONG) -- setup + the ONE real _onNewSong call, for_client
# overridden only for the duration of this call (local, scoped to the
# nested block). Returns ($client, $ctl); the caller asserts, then does
# its own end-of-block releaseConnectClaim cleanup (harmless no-op if
# leaveConnect already released it -- the same guard either way).
sub _d02_onNewSong {
    my (%args) = @_;
    # 84.1-08 (WR-02): the connect entry happens with NO song playing yet
    # -- bindConnectClaim's entry-song read must never see the song this
    # test is about to hand to _onNewSong as a "new" song. In LMS every
    # real content start creates its Song object AFTER the connect entry
    # (bindConnectClaim runs from the transfer/reconnect class, before any
    # song has played); the old helper set the song at construction, so
    # bindConnectClaim's entry-song capture (Task 2 Step 3) would have
    # wrongly captured the SAME object N4's genuine-foreign-url case later
    # hands to _onNewSong, exactly WR-02's positive case in disguise.
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    $client->pluginData(connectPrevPower => 0);
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');
    $client->{song} = $args{song};
    @Slim::Control::Request::EXECUTED = ();

    my $ctl = Test::FakeCtlD02->new(mode => 'connect', client => $client);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onNewSong(Test::FakeRequestD02->new($client));
    }
    return ($client, $ctl);
}

# --- 84.1-07 N1: no song object (playingSong undef) -- leaveConnect never
# called, claim stays bound, nothing executed ---
{
    my ($client, $ctl) = _d02_onNewSong(song => undef);
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 0, "84.1-07 N1: no song -- leaveConnect not called");
    is($ctl->mode, 'connect', "84.1-07 N1: mode unchanged");
    is(Plugins::SpotOn::Connect->isSpotifyConnect($client), 1, "84.1-07 N1: claim still bound");
    is_deeply(\@Slim::Control::Request::EXECUTED, [], "84.1-07 N1: nothing executed");
    is($client->pluginData('connectPrevPower'), 0, "84.1-07 N1: connectPrevPower untouched");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- 84.1-07 N2: a song whose track url and streamUrl are both undef, so
# the resolved url is empty -- same as N1 ---
{
    my $song = Test::FakeSongD02->new(track => Test::FakeTrackD02->new(undef), streamUrl => undef);
    my ($client, $ctl) = _d02_onNewSong(song => $song);
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 0, "84.1-07 N2: empty url -- leaveConnect not called");
    is($ctl->mode, 'connect', "84.1-07 N2: mode unchanged");
    is(Plugins::SpotOn::Connect->isSpotifyConnect($client), 1, "84.1-07 N2: claim still bound");
    is_deeply(\@Slim::Control::Request::EXECUTED, [], "84.1-07 N2: nothing executed");
    is($client->pluginData('connectPrevPower'), 0, "84.1-07 N2: connectPrevPower untouched");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- 84.1-07 N3: a spoton:// url -- ours; requestTrack owns spoton
# transitions, never leaveConnect ---
{
    my $song = Test::FakeSongD02->new(
        track     => Test::FakeTrackD02->new('spoton://track:4iV5W9uYEdYUVa79Axb7Rh'),
        streamUrl => undef,
    );
    my ($client, $ctl) = _d02_onNewSong(song => $song);
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 0, "84.1-07 N3: spoton:// url -- leaveConnect not called");
    is($ctl->mode, 'connect', "84.1-07 N3: mode unchanged");
    is(Plugins::SpotOn::Connect->isSpotifyConnect($client), 1, "84.1-07 N3: claim still bound");
    is_deeply(\@Slim::Control::Request::EXECUTED, [], "84.1-07 N3: nothing executed");
    is($client->pluginData('connectPrevPower'), 0, "84.1-07 N3: connectPrevPower untouched");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- 84.1-07 N4 (positive control): a genuine foreign url leaves once and
# discards the saved power state WITHOUT powering off (GH #151 parity) ---
{
    my $song = Test::FakeSongD02->new(
        track     => Test::FakeTrackD02->new('http://radio.example/1live.mp3'),
        streamUrl => undef,
    );
    my ($client, $ctl) = _d02_onNewSong(song => $song);
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 1, "84.1-07 N4: foreign url -- leaveConnect called exactly once");
    is($ctl->{leaveConnectCalls}[0], 'foreign-lms-content', "84.1-07 N4: reason is foreign-lms-content");
    is($ctl->mode, 'idle', "84.1-07 N4: mode idle after leaveConnect");
    is(Plugins::SpotOn::Connect->isSpotifyConnect($client), 0, "84.1-07 N4: claim released");
    is(power_off_dispatched(), 0, "84.1-07 N4: no power 0 dispatched (discard, not a power-off)");
    is($client->pluginData('connectPrevPower'), undef, "84.1-07 N4: connectPrevPower discarded (GH #151 parity)");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- 84.1-07 N5 (revision 2): the REAL _onLmsStop calls endForeignLeave
# in every mode while LMS's playmode is not 'play' (WR-08, quick
# 260928-q2k); requestPause only in browse (D-01(b) path, unchanged) ---
{
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'idle', client => $client);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onLmsStop(Test::FakeRequestD02->new($client));
    }
    is(scalar(@{ $ctl->{endForeignLeaveCalls} }), 1, "84.1-07 N5 (idle): endForeignLeave called exactly once");
    is($ctl->{endForeignLeaveCalls}[0], 'lms-stop', "84.1-07 N5 (idle): endForeignLeave('lms-stop')");
    is(scalar(@{ $ctl->{requestPauseCalls} }), 0, "84.1-07 N5 (idle): requestPause NOT called outside browse");
}
{
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'browse', client => $client);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onLmsStop(Test::FakeRequestD02->new($client));
    }
    is(scalar(@{ $ctl->{endForeignLeaveCalls} }), 1, "84.1-07 N5 (browse): endForeignLeave called exactly once");
    is($ctl->{endForeignLeaveCalls}[0], 'lms-stop', "84.1-07 N5 (browse): endForeignLeave('lms-stop')");
    is(scalar(@{ $ctl->{requestPauseCalls} }), 1, "84.1-07 N5 (browse): requestPause called exactly once");
    is_deeply($ctl->{requestPauseCalls}[0], [ 1 ], "84.1-07 N5 (browse): requestPause(1)");
}

# --- 84.1-08 N6 (WR-02, D-02): a title-change re-announce of the song
# playing AT CONNECT ENTRY keeps the session -- the client plays S_r when
# the claim is bound, then the REAL _onNewSong sees the SAME S_r object
# again (a title change: LMS reuses the Song, Info.pm:520-534). Pre-fix:
# leaveConnect is called. ---
{
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $S_r    = Test::FakeSongD02->new(
        track     => Test::FakeTrackD02->new('http://radio.example/1live.mp3'),
        streamUrl => undef,
    );
    $client->{song} = $S_r;
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');
    @Slim::Control::Request::EXECUTED = ();

    my $ctl = Test::FakeCtlD02->new(mode => 'connect', client => $client);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onNewSong(Test::FakeRequestD02->new($client));
    }
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 0,
        "84.1-08 N6: title-change re-announce of the connect-entry song -- leaveConnect not called");
    is($ctl->mode, 'connect', "84.1-08 N6: mode stays connect");
    is(Plugins::SpotOn::Connect->isSpotifyConnect($client), 1, "84.1-08 N6: claim stays bound");
    is_deeply(\@Slim::Control::Request::EXECUTED, [], "84.1-08 N6: nothing executed");

    # --- 84.1-08 N6b (WR-02): continue N6 -- the client now plays a NEW
    # S_r2 object with the SAME url (a re-started station). _onNewSong
    # calls leaveConnect exactly once with foreign-lms-content and
    # releases the claim: a re-started station is new content. ---
    my $S_r2 = Test::FakeSongD02->new(
        track     => Test::FakeTrackD02->new('http://radio.example/1live.mp3'),
        streamUrl => undef,
    );
    $client->{song} = $S_r2;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onNewSong(Test::FakeRequestD02->new($client));
    }
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 1,
        "84.1-08 N6b: same url, NEW Song object -- leaveConnect called exactly once");
    is($ctl->{leaveConnectCalls}[0], 'foreign-lms-content', "84.1-08 N6b: reason is foreign-lms-content");
    is($ctl->mode, 'idle', "84.1-08 N6b: mode idle after leaveConnect");
    is(Plugins::SpotOn::Connect->isSpotifyConnect($client), 0, "84.1-08 N6b: claim released");
}

# ==================================================================
# 84.1-08 (CR-01): a registry keyed by coderef exactly like LMS's own
# %listeners (Request.pm:797/:821, a second subscribe of the same coderef
# replaces the first) -- proves initConnectHandlers no longer subscribes
# one coderef twice for ['stop'] and ['playlist'],['clear'].
# ==================================================================

sub _lms_listeners_for {
    my (@cmd) = @_;
    my @matches;
    for my $entry (values %Slim::Control::Request::LISTENERS) {
        my ($coderef, $spec) = @$entry;
        my $ok = 1;
        for my $i (0 .. $#$spec) {
            my $term = $cmd[$i];
            unless (defined $term && grep { $_ eq $term } @{ $spec->[$i] }) {
                $ok = 0;
                last;
            }
        }
        push @matches, $coderef if $ok;
    }
    return @matches;
}

%Slim::Control::Request::LISTENERS  = ();
$Slim::Control::Request::SUBSCRIBE_CALLS = 0;
Plugins::SpotOn::Connect->initConnectHandlers;

# 84.1-08 N7a
{
    my @stop_listeners = _lms_listeners_for('stop');
    is(scalar(@stop_listeners), 1, "84.1-08 N7a: exactly one listener matches ('stop')");
}

# 84.1-08 N7b (D-01(b), browse)
{
    my ($stop_cr) = _lms_listeners_for('stop');
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'browse', client => $client);
    if ($stop_cr) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        $stop_cr->(Test::FakeRequestD02->new($client));
    }
    is_deeply($ctl->{endForeignLeaveCalls}, ['lms-stop'], "84.1-08 N7b: browse dispatch -- endForeignLeave('lms-stop')");
    is_deeply($ctl->{requestPauseCalls}, [ [1] ], "84.1-08 N7b: browse dispatch -- requestPause(1)");
}

# 84.1-08 N7c (D-01 clarification: a stop in connect stays a session pause)
{
    my ($stop_cr) = _lms_listeners_for('stop');
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'connect', client => $client);
    if ($stop_cr) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        $stop_cr->(Test::FakeRequestD02->new($client));
    }
    is(scalar(@{ $ctl->{endForeignLeaveCalls} }), 1, "84.1-08 N7c: connect dispatch -- endForeignLeave called once");
    is(scalar(@{ $ctl->{requestPauseCalls} }), 0, "84.1-08 N7c: connect dispatch -- requestPause not called");
}

# 84.1-08 N7d
{
    my @clear_listeners = _lms_listeners_for('playlist', 'clear');
    is(scalar(@clear_listeners), 1, "84.1-08 N7d: exactly one listener matches ('playlist','clear')");
    my ($clear_cr) = @clear_listeners;
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'browse', client => $client);
    if ($clear_cr) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        $clear_cr->(Test::FakeRequestD02->new($client));
    }
    is_deeply($ctl->{endForeignLeaveCalls}, ['lms-stop'], "84.1-08 N7d: playlist-clear dispatch in browse -- endForeignLeave('lms-stop')");
    is_deeply($ctl->{requestPauseCalls}, [ [1] ], "84.1-08 N7d: playlist-clear dispatch in browse -- requestPause(1)");
}

# 84.1-08 N7e: no subscribe overwrote another
{
    my $entries = scalar(keys %Slim::Control::Request::LISTENERS);
    is($entries, $Slim::Control::Request::SUBSCRIBE_CALLS,
        "84.1-08 N7e: registry entry count equals subscribe call count (no coderef overwrite)");
}

# --- q2k-WR08 W1..W3 (quick 260928-q2k, 84.1-REVIEW.md:55-86): the REAL
# `stop` listener must clear leftConnectForeign only when LMS's playmode
# is not 'play' (WR-08, D-02). W1/W2 replay the review's step 2 -- LMS's
# own internal `['playlist','stop']` on a station change arrives with
# playmode already 'play', so the D-02 hold marker must survive; W3 is
# the control case, a genuine stop (playmode 'stop') still clears it.

# q2k-WR08 W1 (idle, D-02 step 2): playmode 'play' -- marker must survive
{
    my ($stop_cr) = _lms_listeners_for('stop');
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'idle', client => $client, observed => { leftConnectForeign => 1 });
    local $Slim::Player::Source::PLAYMODE = 'play';
    if ($stop_cr) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        $stop_cr->(Test::FakeRequestD02->new($client));
    }
    is_deeply($ctl->{endForeignLeaveCalls}, [], "q2k-WR08 W1: idle, playmode play -- endForeignLeave NOT called");
    is($ctl->{observed}{leftConnectForeign}, 1, "q2k-WR08 W1: idle, playmode play -- leftConnectForeign marker survives");
    is(scalar(@{ $ctl->{requestPauseCalls} }), 0, "q2k-WR08 W1: idle, playmode play -- requestPause not called");
}

# q2k-WR08 W2 (browse, D-01(b) unchanged): playmode 'play' -- marker must
# survive; requestPause(1) still fires (its own playmode rule, Befund 3,
# not this guard's business)
{
    my ($stop_cr) = _lms_listeners_for('stop');
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'browse', client => $client, observed => { leftConnectForeign => 1 });
    local $Slim::Player::Source::PLAYMODE = 'play';
    if ($stop_cr) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        $stop_cr->(Test::FakeRequestD02->new($client));
    }
    is_deeply($ctl->{endForeignLeaveCalls}, [], "q2k-WR08 W2: browse, playmode play -- endForeignLeave NOT called");
    is($ctl->{observed}{leftConnectForeign}, 1, "q2k-WR08 W2: browse, playmode play -- leftConnectForeign marker survives");
    is_deeply($ctl->{requestPauseCalls}, [ [1] ], "q2k-WR08 W2: browse, playmode play -- requestPause(1) still called");
}

# q2k-WR08 W3 (control): playmode 'stop' -- genuine LMS stop still clears
# the marker as before
{
    my ($stop_cr) = _lms_listeners_for('stop');
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => undef);
    my $ctl    = Test::FakeCtlD02->new(mode => 'idle', client => $client, observed => { leftConnectForeign => 1 });
    local $Slim::Player::Source::PLAYMODE = 'stop';
    if ($stop_cr) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        $stop_cr->(Test::FakeRequestD02->new($client));
    }
    is_deeply($ctl->{endForeignLeaveCalls}, ['lms-stop'], "q2k-WR08 W3: idle, playmode stop -- endForeignLeave('lms-stop') called");
    is($ctl->{observed}{leftConnectForeign}, undef, "q2k-WR08 W3: idle, playmode stop -- leftConnectForeign marker cleared");
    is(scalar(@{ $ctl->{requestPauseCalls} }), 0, "q2k-WR08 W3: idle, playmode stop -- requestPause not called");
}

# 84.1-08 N7f
Plugins::SpotOn::Connect->shutdown;
{
    my @stop_listeners  = _lms_listeners_for('stop');
    my @clear_listeners = _lms_listeners_for('playlist', 'clear');
    is(scalar(@stop_listeners), 0, "84.1-08 N7f: after shutdown no listener matches ('stop')");
    is(scalar(@clear_listeners), 0, "84.1-08 N7f: after shutdown no listener matches ('playlist','clear')");
}


# ==================================================================
# 84-02 (cluster 4, D-21): the LMS clock after an app `next`.
#
# Frozen mechanism (todo connect-app-skip-lms-uhr-negativer-startoffset,
# 2026-09-24 23:45:18.7586..7672; also 84-01's L1 runs: `adjusted startOffset
# to -13.14 / -12.82` right after every early boundary): the Soloist `change`
# handler dispatches `playlist play spoton://track:<new>`; the daemon's zero
# `seek` echo arrives 8 ms later, when LMS already holds the NEW song object
# but squeezelite still reports the OLD stream's elapsed (87.5 s).
# `startOffset = position - elapsed` = -87.5 made the clock sit at 0.0 for
# ~88 s. LMS clock = song->startOffset + songElapsedSeconds, clamped at 0
# (StreamingController.pm:1719-1747); songElapsedSeconds counts from the
# CURRENT stream start, so a value larger than the time since the new stream
# was dispatched cannot belong to it.
#
# C4-a  (RED pre-fix)  seek echo 0.000 after a Soloist change, stale elapsed 87.5
#                      -> startOffset >= 0 (expected 0; pre-fix -87.5)
# C4-a2 (RED pre-fix)  the same with a `resume` echo (the verb sequence at a
#                      normal boundary is seek,resume)
# C4-b  (guard only)   resume P=120 right after a (re)start, elapsed 0.4 -> P - 0.4
# C4-c  (RED pre-fix)  transfer-in: `start` carries the app position (Control
#                      passes anchor->{position_ms}); the first clock read is P
# C4-c2 (RED pre-fix)  the same while the player still reports the previous
#                      session's stream elapsed (61 s)
# C4-l  (guard only)   librespot entry (no Soloist dispatch marker): the old
#                      arithmetic is unchanged -- elapsed 87.5 stays subtracted
# ==================================================================

package Plugins::SpotOn::Unified::SoloistDaemon;
sub new         { return bless {}, shift; }
sub alive       { return 1; }
sub _streamPort { return 4711; }

package Test::FakeClientSong;
sub playPoint { return undef; }   # the Soloist change handler resets it

package Test::FakeTrackC4;
sub new { my ($class, $url) = @_; return bless { url => $url }, $class; }
sub url { return $_[0]->{url}; }

package Test::FakeSongC4;
sub new {
    my ($class, %a) = @_;
    return bless { so => ($a{so} // 0), url => ($a{url} // 'spoton://track:NEWNEWNEWNEWNEWNEWNEWN') }, $class;
}
sub startOffset { my $self = shift; $self->{so} = shift if @_; return $self->{so}; }
sub track       { return Test::FakeTrackC4->new($_[0]->{url}); }
sub streamUrl   { return $_[0]->{url}; }
sub pluginData  { return { title => 'live' }; }

package main;

my $c4_soloist = Plugins::SpotOn::Unified::SoloistDaemon->new;

sub c4_client {
    my (%a) = @_;
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => 1, song => $a{song}, elapsed => $a{elapsed});
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');
    return $client;
}

sub c4_change {
    my ($client) = @_;
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
    @Slim::Control::Request::EXECUTED = ();
    Plugins::SpotOn::Connect::_connectEvent(
        Test::FakeRequest->new($client, _cmd => 'change', _p2 => '5Awt99LSbIaTmWkoOFhP03', _p3 => '1bcCUnCiOttYRh7AfoihFH'));
}

sub c4_play_dispatched {
    return grep {
        $_->{cmd} && ref($_->{cmd}) eq 'ARRAY' && ($_->{cmd}[0] // '') eq 'playlist' && ($_->{cmd}[1] // '') eq 'play'
    } @Slim::Control::Request::EXECUTED;
}

# --- C4-a ---
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH');
    my $client = c4_client(song => $old, elapsed => 87.5);
    c4_change($client);
    is(scalar(c4_play_dispatched()), 1, 'C4-a setup: the Soloist change dispatched exactly one playlist play');
    my $new = Test::FakeSongC4->new(url => 'spoton://track:5Awt99LSbIaTmWkoOFhP03');   # LMS opened the new Song
    $client->{song} = $new;
    seek_echo($client, '0.000');
    cmp_ok($new->startOffset, '>=', 0,
        'C4-a: seek echo 0.000 after a change, player still reporting the old stream\'s elapsed 87.5 -> startOffset not negative');
    is(sprintf('%.2f', $new->startOffset), '0.00',
        'C4-a: the new song\'s clock starts at 0 (startOffset 0; pre-fix -87.50)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- C4-a2 ---
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://connect-1790000000000');
    my $client = c4_client(song => $old, elapsed => 87.5);
    c4_change($client);
    my $new = Test::FakeSongC4->new(url => 'spoton://connect-1790000000001');
    $client->{song} = $new;
    Plugins::SpotOn::Connect::_connectEvent(
        Test::FakeRequest->new($client, _cmd => 'resume', _p2 => '5Awt99LSbIaTmWkoOFhP03', _p3 => '0.000'));
    cmp_ok($new->startOffset, '>=', 0,
        'C4-a2: resume echo 0.000 after a change with the old stream\'s elapsed 87.5 -> startOffset not negative');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- C4-b (guard only): a plausible elapsed (0.4 s into a just-(re)started stream) is still subtracted ---
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://connect-1790000000000');
    my $client = c4_client(song => $old, elapsed => 0.4);
    c4_change($client);
    my $new = Test::FakeSongC4->new(url => 'spoton://connect-1790000000001');
    $client->{song} = $new;
    Plugins::SpotOn::Connect::_connectEvent(
        Test::FakeRequest->new($client, _cmd => 'resume', _p2 => '5Awt99LSbIaTmWkoOFhP03', _p3 => '120.000'));
    is(sprintf('%.2f', $new->startOffset), '119.60',
        'C4-b (guard only): resume P=120 at stream elapsed 0.4 -> startOffset 119.60 (unchanged arithmetic)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- C4-l (guard only): librespot entry, no Soloist dispatch marker -> old arithmetic ---
{
    my $song   = Test::FakeSongC4->new(so => 0);
    my $client = c4_client(song => $song, elapsed => 87.5);
    seek_echo($client, '0.000');
    is(sprintf('%.2f', $song->startOffset), '-87.50',
        'C4-l (guard only): no Soloist dispatch marker (librespot repeating stream) -> startOffset = position - elapsed, unchanged');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- C4-r (RED pre-fix): the reactivation transfer-in (seek + resume, LMS holds no song yet): the
# `seek` echo finds no song to adjust and is dropped; the `resume` re-entry dispatches the
# playlist play WITHOUT its position (live 2026-09-30 11:59:30.289, l2-proof empty run:
# verbs seek,resume, POS_LMS_FIRST_S=0 while the app was at 47 s). The re-entry hands the
# position to _onNewSong exactly like `start` does. ---
{
    my $client = c4_client(song => undef, elapsed => 0);
    $client->pluginData(connectPrevPower => 0);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
        seek_echo($client, '47.000');        # no song: nothing to adjust, nothing stored
        @Slim::Control::Request::EXECUTED = ();
        Plugins::SpotOn::Connect::_connectEvent(
            Test::FakeRequest->new($client, _cmd => 'resume', _p2 => '7jmHyHMEqm9MJWiMAneF05', _p3 => '47.000'));
    }
    is(scalar(c4_play_dispatched()), 1, 'C4-r setup: the resume re-entry dispatched exactly one playlist play');
    my $new = Test::FakeSongC4->new(url => 'spoton://track:7jmHyHMEqm9MJWiMAneF05');
    $client->{song} = $new;
    my $ctl = Test::FakeCtlD02->new(mode => 'connect', client => $client);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onNewSong(Test::FakeRequestD02->new($client));
    }
    cmp_ok(abs($new->startOffset - 47), '<=', 1.0,
        'C4-r: the resume re-entry hands the app position 47 s to the new song\'s clock (got ' . sprintf('%.2f', $new->startOffset) . '; pre-fix 0)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# ==================================================================
# 84-26 F-24-2 Connect (C6, 84-24): a transfer-in after away-and-back resumed at LMS's stale
# `resumeTime` (31.2 s) instead of the daemon's 53.4 s. The resume branch unpaused a PAUSED-IDLE
# player (stream gone) with a plain ['pause', 0]; StreamingController's `_JumpOrResume` (the IDLE
# column of the Pause/Resume rows, SC:138/:145) turns that into a seek to `resumeTime`, and the seek
# chain forwarded the LMS-originated figure to the daemon as a user seek. Repair: set LMS's resume
# position to the daemon's BEFORE the unpause (controller->jumpToTime while PAUSED -> `_JumpPaused`
# sets resumeTime, SC:166/:1051-1090), and skip the stale startOffset write on that path. Excluded:
# playing/streaming players (the live unpause, `_Resume` column), no/sub-second position, and
# PAUSED-TRACKWAIT (a queued next song). Sibling: the change handler's unpause on the same state is
# skipped for the Soloist backend (the `playlist play` that follows re-opens the new title).
# ==================================================================
sub f242_client {
    my (%a) = @_;
    my $client = Test::FakeClientSong->new(
        power => 1, isPlaying => ($a{playing} ? 1 : 0), paused => ($a{paused} // 1),
        song => $a{song}, elapsed => ($a{elapsed} // 28.195),
        controller => Test::FakeController->new(%{ $a{ctl} || {} }),
    );
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');
    return $client;
}

sub f242_resume {
    my ($client, $position) = @_;
    @Slim::Control::Request::EXECUTED = ();
    @Test::FakeController::JUMPS      = ();
    @Slim::Utils::Log::LINES          = ();
    Plugins::SpotOn::Connect::_connectEvent(
        Test::FakeRequest->new($client, _cmd => 'resume', _p2 => '5Awt99LSbIaTmWkoOFhP03', _p3 => $position));
}

sub f242_song { return Test::FakeSongC4->new(url => 'spoton://connect-1790000000001', so => 0); }

# Fall A: paused client, stream gone, a paused song at elapsed 28.195, resume at 53.386 -> one jumpToTime(53.386)
# BEFORE the single ['pause', 0]
{
    my $client = f242_client(song => f242_song());
    f242_resume($client, '53.386');
    is(scalar(@Test::FakeController::JUMPS), 1, '84-26 F-24-2 Connect Fall A: exactly one jumpToTime call');
    is($Test::FakeController::JUMPS[0][0], '53.386', '84-26 F-24-2 Connect Fall A: LMS resume position = the daemon position');
    is($Test::FakeController::JUMPS[0][1], 0, '84-26 F-24-2 Connect Fall A: the jump precedes every dispatched request (EXECUTED count 0)');
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall A: the unpause is still dispatched exactly once, after the jump');
    is(scalar(grep { /resume while LMS paused with the stream gone/ } @Slim::Utils::Log::LINES), 1,
        '84-26 F-24-2 Connect Fall A: one INFO line names the jump');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall B (guard): a playing client -- no jump, the unpause as today
{
    my $client = f242_client(song => f242_song(), paused => 0, playing => 1);
    f242_resume($client, '53.386');
    is(scalar(@Test::FakeController::JUMPS), 0, '84-26 F-24-2 Connect Fall B: a playing client never jumps');
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall B: the unpause as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall C (guard): paused but the stream is alive (PAUSED-STREAMING: the live unpause, `_Resume` column) -- no jump
{
    my $client = f242_client(song => f242_song(), ctl => { streaming => 1 });
    f242_resume($client, '53.386');
    is(scalar(@Test::FakeController::JUMPS), 0, '84-26 F-24-2 Connect Fall C: paused with a live stream never jumps');
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall C: the unpause as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall D (guard): no position carried -- no jump
{
    my $client = f242_client(song => f242_song());
    f242_resume($client, '');
    is(scalar(@Test::FakeController::JUMPS), 0, '84-26 F-24-2 Connect Fall D: without a position there is nothing to jump to');
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall D: the unpause as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall E: the stale startOffset write (position - the OLD stream's elapsed) is skipped when the jump was taken
{
    my $song   = f242_song();
    my $client = f242_client(song => $song);
    is($song->startOffset, 0, '84-26 F-24-2 Connect Fall E setup: startOffset 0 before the event');
    f242_resume($client, '53.386');
    is($song->startOffset, 0, '84-26 F-24-2 Connect Fall E: startOffset UNCHANGED after the event (today 53.386 - 28.195 = 25.191)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall F (guard): PAUSED-TRACKWAIT shape -- the controller holds a queued NEXT song (streamingSong != playingSong): no jump
{
    my $playing  = f242_song();
    my $queued   = Test::FakeSongC4->new(url => 'spoton://track:NEXTNEXTNEXTNEXTNEXTNEX');
    my $client   = f242_client(song => $playing, ctl => { streamingSong => $queued, playingSong => $playing });
    f242_resume($client, '53.386');
    is(scalar(@Test::FakeController::JUMPS), 0, '84-26 F-24-2 Connect Fall F: a queued next song (TRACKWAIT shape) never jumps');
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall F: the unpause as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall H (the floor, guard against a `> 0` implementation): a sub-second reset figure never jumps (jumpToTime(0.112) would restart the title)
{
    my $client = f242_client(song => f242_song());
    f242_resume($client, '0.112');
    is(scalar(@Test::FakeController::JUMPS), 0, '84-26 F-24-2 Connect Fall H: a sub-second position (below the 1000 ms floor) never jumps');
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall H: the unpause as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall G (the change-handler sibling): a `change` on a paused Soloist client with the stream gone and no remembered
# Spotify-side pause -- the unpause is skipped (the `playlist play` re-opens the NEW title), exactly one `playlist play`
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH');
    my $client = f242_client(song => $old);
    @Test::FakeController::JUMPS = ();
    @Slim::Utils::Log::LINES     = ();
    c4_change($client);
    is(scalar(pause_unpause_dispatched()), 0, '84-26 F-24-2 Connect Fall G: the change handler does not unpause a paused Soloist client with the stream gone');
    is(scalar(c4_play_dispatched()), 1, '84-26 F-24-2 Connect Fall G: exactly one playlist play re-opens the new title');
    is(scalar(grep { /change while LMS paused with the stream gone/ } @Slim::Utils::Log::LINES), 1,
        '84-26 F-24-2 Connect Fall G: one INFO line names the skip');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall G2 (guard): the same change while LMS is merely stopped (not paused) -- the unpause as today
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH');
    my $client = f242_client(song => $old, paused => 0);
    c4_change($client);
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall G2: a stopped (not paused) client is still unpaused as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall G3 (guard): a paused client but the stream is alive -- the unpause as today
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH');
    my $client = f242_client(song => $old, ctl => { streaming => 1 });
    c4_change($client);
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall G3: a paused client with a live stream is unpaused as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall G4 (guard): no new track id (empty _p2) -- no `playlist play` follows, so the unpause stays
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH');
    my $client = f242_client(song => $old);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
        @Slim::Control::Request::EXECUTED = ();
        Plugins::SpotOn::Connect::_connectEvent(
            Test::FakeRequest->new($client, _cmd => 'change', _p2 => '', _p3 => '1bcCUnCiOttYRh7AfoihFH'));
    }
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall G4: without a new track id the unpause stays');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# Fall G5 (guard): the librespot path (no Soloist helper) stays byte-identical -- its repeating stream needs the re-open
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://connect-1790000000000');
    my $client = f242_client(song => $old);
    @Slim::Control::Request::EXECUTED = ();
    Plugins::SpotOn::Connect::_connectEvent(
        Test::FakeRequest->new($client, _cmd => 'change', _p2 => '5Awt99LSbIaTmWkoOFhP03', _p3 => '1bcCUnCiOttYRh7AfoihFH'));
    is(scalar(pause_unpause_dispatched()), 1, '84-26 F-24-2 Connect Fall G5: the librespot path unpauses as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- C4-c / C4-c2: transfer-in display half ---
for my $case ([ 'C4-c', 0 ], [ 'C4-c2', 61 ]) {
    my ($name, $elapsed) = @$case;
    my $client = c4_client(song => undef, elapsed => $elapsed);
    $client->pluginData(connectPrevPower => 0);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
        @Slim::Control::Request::EXECUTED = ();
        Plugins::SpotOn::Connect::_connectEvent(
            Test::FakeRequest->new($client, _cmd => 'start', _p2 => '1G391cbiT3v3Cywg8T7DM1', _p3 => '44.600'));
    }
    is(scalar(c4_play_dispatched()), 1, "$name setup: the start dispatched exactly one playlist play");
    my $new = Test::FakeSongC4->new(url => 'spoton://track:1G391cbiT3v3Cywg8T7DM1');
    $client->{song} = $new;
    my $ctl = Test::FakeCtlD02->new(mode => 'connect', client => $client);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onNewSong(Test::FakeRequestD02->new($client));
    }
    my $clock = $new->startOffset + 0;   # first LMS clock read: the new stream has played 0 s
    cmp_ok(abs($clock - 44.6), '<=', 1.0,
        "$name: first clock read equals the app position 44.6 within 1 s (got " . sprintf('%.2f', $clock) . "; pre-fix 0)");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# ==================================================================
# 84-17 Task 1 (tracer): the audio shim's own classification of a title
# change (`via=live|departed|none|timeout|unknown`, read by Soloist::Control
# from the POST /boundary reply) arrives as the `change`'s 4th positional
# (`_p4`); Control marks the seek that echoes a just-changed item `deferred`
# (`_p4` of `seek`). In THIS task Connect only LOGS both and behaves exactly
# as before; the hold on `live` and the dropping of `deferred` positions
# are Task 2 (these cases flip there: C-a and C-c are marked below).
#
# C-a  (UPDATED in Task 2)           change with _p4=live logs `via=live`; it no longer
#                                    issues the immediate `playlist play` (the hold, H-a)
# C-b  (guard)                       change without _p4 (librespot path) logs
#                                    `via=none` and issues `playlist play`
# C-c  (updated in Task 2)           seek with _p4=deferred is logged as such; handled as
#                                    today while NO hold is open (dropped during a hold: H-e)
# ==================================================================
sub c84_17_lines { return grep { /Track change:|marked deferred/ } @Slim::Utils::Log::LINES; }

# --- C-a ---
{
    # 84-17 Task 2: this guard FLIPPED -- a `live` change is now held (no
    # immediate `playlist play`, see H-a); the via is logged as before.
    my $old    = Test::FakeSongH->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH', duration => 200);
    my $client = c4_client(song => $old, elapsed => 87.5);
    @Slim::Utils::Log::LINES = ();
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
        @Slim::Control::Request::EXECUTED = ();
        Plugins::SpotOn::Connect::_connectEvent(
            Test::FakeRequest->new($client, _cmd => 'change', _p2 => '5Awt99LSbIaTmWkoOFhP03', _p3 => '1bcCUnCiOttYRh7AfoihFH', _p4 => 'live'));
    }
    my @l = c84_17_lines();
    is(scalar(@l), 1, '84-17 C-a: exactly one `Track change:` line');
    like($l[0], qr/^Track change: 1bcCUnCiOttYRh7AfoihFH -> 5Awt99LSbIaTmWkoOFhP03 via=live$/,
        '84-17 C-a: a change with _p4=live logs the via');
    is(scalar(c4_play_dispatched()), 0,
        '84-17 C-a (updated in Task 2): a `live` change no longer issues the immediate `playlist play` (the hold, H-a)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
    @Slim::Utils::Timers::TIMERS = () if @Slim::Utils::Timers::TIMERS;
}

# --- C-b ---
{
    my $old    = Test::FakeSongC4->new(url => 'spoton://track:1bcCUnCiOttYRh7AfoihFH');
    my $client = c4_client(song => $old, elapsed => 0.4);
    @Slim::Utils::Log::LINES = ();
    c4_change($client);    # no _p4: the librespot path / a nachziehen re-emit
    my @l = c84_17_lines();
    like($l[0] // '', qr/^Track change: 1bcCUnCiOttYRh7AfoihFH -> 5Awt99LSbIaTmWkoOFhP03 via=none$/,
        '84-17 C-b: a change without _p4 logs `via=none`');
    is(scalar(c4_play_dispatched()), 1, '84-17 C-b (guard): a change without _p4 issues `playlist play` (librespot path unchanged)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- C-c ---
{
    my $song   = Test::FakeSongC4->new(so => 0);
    my $client = c4_client(song => $song, elapsed => 10);
    @Slim::Utils::Log::LINES = ();
    Plugins::SpotOn::Connect::_connectEvent(
        Test::FakeRequest->new($client, _cmd => 'seek', _p2 => '12.500', _p4 => 'deferred'));
    my @l = c84_17_lines();
    is(scalar(grep { /marked deferred/ } @l), 1, '84-17 C-c: a seek with _p4=deferred is logged as such');
    is(sprintf('%.2f', $song->startOffset), '2.50',
        '84-17 C-c (updated in Task 2): with NO hold open a `deferred` seek is still handled as today (startOffset = position - elapsed); dropping it needs an open hold, see H-e');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}


# ==================================================================
# 84-17 Task 2 -- the hold on `via=live` (shape B), driven against the REAL
# Connect.pm handlers. Shape and rules: 84-L1-ATTRIBUTION.md
# `## 84-17 hold design`.
#
# A `live` change (the audio shim saw the OLD title still streaming = a
# natural end) must NOT issue `playlist play` (that is what makes LMS `_Stop`
# and the player flush the 12-37 s tail it still holds): the new title is
# inserted as the NEXT playlist entry (`playlist insert`), LMS advances by
# itself, the newsong of the deferred item closes the hold and prunes the old
# entry by its recorded index. Everything else keeps today's immediate path.
#
# H-a  hold: no `playlist play`, `playlist insert <new>`, `hold opened` line,
#      the playing song's startOffset untouched (the change handler's own
#      reset is skipped), the newsong closes it: `playlist delete <idx>`,
#      new song at 0 untouched by anything seen during the hold
# H-b  (guard) departed/none/unknown/timeout/absent -> immediate `playlist play`
# H-c  cancellation set, and what does NOT cancel
# H-d  the safety timer: ONE rule, fixed precedence d1, d4, d3, d2 (the clock
#      is never read)
# H-e  a frame far ahead of the audible end also defers; every `seek ...
#      deferred` and `resume <deferredId> <pos>` is dropped, never written
# H-g  a `change` without via (a nachziehen re-emit) cancels the hold, no
#      second hold, immediate `playlist play`
# H-i  the hold only when LMS's own advance will open the deferred item
#
# The harness: a Timers recorder with fire helpers, a Time::HiRes::time
# override (the cap/re-check/ceiling tests advance time by firing the
# recorded timers), a Slim::Player::Playlist stub (settable repeat, entries),
# Slim::Player::Source::playingSongIndex/playmode, and a recording fake
# Control carrying the HOLD_* constants and clearHold.
# ==================================================================

# The Timers recorder is installed at RUNTIME below (the stub module is
# loaded by Connect.pm's `use` before this code runs; a compile-time sub
# here would be clobbered by it).
{
    no warnings 'redefine';
    @Slim::Utils::Timers::TIMERS = ();
    *Slim::Utils::Timers::setTimer   = sub { my ($obj, $when, $cb, @a) = @_; push @Slim::Utils::Timers::TIMERS, [ $obj, $when, $cb, @a ]; return; };
    *Slim::Utils::Timers::killTimers = sub { my ($obj, $cb) = @_; @Slim::Utils::Timers::TIMERS = grep { !($_->[0] == $obj && $_->[2] == $cb) } @Slim::Utils::Timers::TIMERS; return; };
}

{
    package Slim::Player::Playlist;
    our @ENTRIES;
    our $REPEAT = 0;
    sub repeat { return $REPEAT; }
    sub shuffle { return 0; }
    sub song {
        my ($c, $i) = @_;
        return undef unless defined $ENTRIES[$i];
        return Test::HoldEntry->new($ENTRIES[$i]);
    }

    package Test::HoldEntry;
    sub new { my ($class, $url) = @_; return bless { url => $url }, $class; }
    sub url { return $_[0]->{url}; }

    package Slim::Player::Source;
    our $INDEX = 0;
    sub playingSongIndex { return $INDEX; }
    sub songTime { return 0; }

    package Plugins::SpotOn::Soloist::Control;
    sub HOLD_CAP_S     () { 60 }
    sub HOLD_RECHECK_S () { 5 }
    sub HOLD_MAX_S     () { 180 }

    package Test::FakeSongH;
    sub new {
        my ($class, %a) = @_;
        return bless { so => ($a{so} // 0), url => $a{url}, duration => $a{duration} }, $class;
    }
    sub startOffset { my $self = shift; $self->{so} = shift if @_; return $self->{so}; }
    sub track       { return Test::FakeTrackC4->new($_[0]->{url}); }
    sub streamUrl   { return $_[0]->{url}; }
    sub pluginData  { return { title => 'live' }; }
    sub duration    { return $_[0]->{duration}; }

    package Test::FakeCtlH;
    our @ISA = ('Test::FakeCtlD02');
    sub new {
        my ($class, %a) = @_;
        my $self = Test::FakeCtlD02::new($class, %a);
        $self->{clearHoldCalls} = [];
        $self->{skipCalls}      = [];
        $self->{observed}       = { track => "spotify:track:5Awt99LSbIaTmWkoOFhP03" };
        return $self;
    }
    sub observed       { return $_[0]->{observed}; }
    sub clearHold      { my ($self, @a) = @_; push @{ $self->{clearHoldCalls} }, [ @a ]; return; }
    sub requestSkip    { my ($self, @a) = @_; push @{ $self->{skipCalls} }, [ @a ]; return 1; }
    sub requestRestart { return 0; }

    package Test::FakeRequestH;
    sub new {
        my ($class, $client, %p) = @_;
        return bless { client => $client, params => { %p }, source => undef }, $class;
    }
    sub client   { return $_[0]->{client}; }
    sub source   { return $_[0]->{source}; }
    sub getParam { return $_[0]->{params}{ $_[1] }; }
    sub isCommand { return 0; }
}

my $H_NOW = 1_790_000_000.0;
my $H_REAL_TIME = \&Time::HiRes::time;
{
    no warnings 'redefine';
    *Time::HiRes::time = sub { return $H_NOW; };
}

my $H_CTL;
my $H_OLD = '1bcCUnCiOttYRh7AfoihFH';
my $H_NEW = '5Awt99LSbIaTmWkoOFhP03';
my $H_NEX = '7jmHyHMEqm9MJWiMAneF05';

# h_setup(%o) -> ($client, $ctl, $old): a Connect session on a Soloist player,
# the OLD title playing (duration 200 s unless told otherwise).
sub h_setup {
    my (%o) = @_;
    my $old = Test::FakeSongH->new(
        url      => "spoton://track:$H_OLD",
        so       => ($o{so} // 12.34),
        duration => (exists $o{duration} ? $o{duration} : 200),
    );
    my $client = Test::FakeClientSong->new(power => 1, isPlaying => ($o{isPlaying} // 1), song => $old, elapsed => ($o{elapsed} // 10));
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'transfer');
    $client->pluginData(connectPrevPower => 0);
    $client->pluginData(connectSessionPaused => 0);
    my $ctl = Test::FakeCtlH->new(mode => 'connect', client => $client);
    $H_CTL = $ctl;
    @Slim::Utils::Timers::TIMERS    = ();
    @Slim::Control::Request::EXECUTED = ();
    @Slim::Player::Playlist::ENTRIES  = ("spoton://track:$H_OLD");
    $Slim::Player::Playlist::REPEAT   = ($o{repeat} // 0);
    $Slim::Player::Source::INDEX      = 0;
    $Slim::Player::Source::PLAYMODE   = 'play';
    @Slim::Utils::Log::LINES          = ();
    $H_NOW = 1_790_000_000.0;
    return ($client, $ctl, $old);
}

# h_event($client, $ctl, \&handler, %params) -- ONE real handler call with the
# Soloist helper and the fake Control in place.
sub h_event {
    my ($client, $ctl, $code, %p) = @_;
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { $c4_soloist };
    local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
    my $req = Test::FakeRequestH->new($client, %p);
    $code->($req);
}

sub h_connect { my ($c, $k, %p) = @_; h_event($c, $k, \&Plugins::SpotOn::Connect::_connectEvent, %p); }

sub h_change {
    my ($c, $k, $new, $via) = @_;
    h_connect($c, $k, _cmd => 'change', _p2 => $new, _p3 => $H_OLD, (defined $via ? (_p4 => $via) : ()));
}

sub h_cmds {
    my ($pred) = @_;
    return grep {
        $_->{cmd} && ref($_->{cmd}) eq 'ARRAY' && $pred->(@{ $_->{cmd} })
    } @Slim::Control::Request::EXECUTED;
}
sub h_plays   { return h_cmds(sub { ($_[0] // '') eq 'playlist' && ($_[1] // '') eq 'play' }); }
sub h_inserts { return h_cmds(sub { ($_[0] // '') eq 'playlist' && ($_[1] // '') eq 'insert' }); }
sub h_deletes { return h_cmds(sub { ($_[0] // '') eq 'playlist' && ($_[1] // '') eq 'delete' }); }
sub h_log     { my $re = shift; return grep { /$re/ } @Slim::Utils::Log::LINES; }

# the hold's own timer (the killTimers/setTimer identity is Connect::_holdCheck)
sub h_timers { return scalar(@Slim::Utils::Timers::TIMERS); }
sub h_fire_at {
    my ($t) = @_;
    $H_NOW = $t;
    my ($tm) = sort { $a->[1] <=> $b->[1] } @Slim::Utils::Timers::TIMERS;
    return 0 unless $tm;
    @Slim::Utils::Timers::TIMERS = grep { $_ != $tm } @Slim::Utils::Timers::TIMERS;
    my ($obj, undef, $cb, @a) = @$tm;
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Control::for_client = sub { $H_CTL };    # timer callbacks look Control up themselves
    $cb->($obj, @a);
    return 1;
}

# deferred item landed in the playlist as LMS would after `playlist insert`
sub h_lms_inserted { push @Slim::Player::Playlist::ENTRIES, "spoton://track:$H_NEW" if @Slim::Player::Playlist::ENTRIES == 1; }

# --- H-a ---
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');

    is(scalar(h_plays()), 0, '84-17 H-a: a `live` change issues NO `playlist play` (the immediate play is what cuts the tail)');
    my @ins = h_inserts();
    is(scalar(@ins), 1, '84-17 H-a: exactly one `playlist insert`');
    is_deeply($ins[0]{cmd}, [ 'playlist', 'insert', "spoton://track:$H_NEW" ],
        '84-17 H-a: the new title is inserted as the NEXT playlist entry (play-next insert)');
    is($ins[0]{source}, 'Plugins::SpotOn::Connect', '84-17 H-a: the insert is source-marked (our own request)');
    my @opened = h_log(qr/^Connect: hold opened uri=spoton:\/\/track:\Q$H_NEW\E cap_at=\d+ max_at=\d+ /);
    is(scalar(@opened), 1, '84-17 H-a: `Connect: hold opened uri=<new> cap_at=<t> max_at=<t>` is logged');
    like($opened[0] // '', qr/cap_at=1790000060 max_at=1790000180/, '84-17 H-a: cap_at = now + HOLD_CAP_S, max_at = now + HOLD_MAX_S');
    is($client->pluginData('connectOwnPlayUri'), "spoton://track:$H_NEW",
        '84.2-05 H-a: _holdOpen stamps the one-shot dispatch marker with the deferred uri (the LMS advance of the inserted item reads it as origin connect)');
    is(sprintf('%.2f', $old->startOffset), '12.34',
        '84-17 H-a: the playing song\'s startOffset is UNCHANGED (the change handler\'s own reset at the frame is skipped; pre-fix it became -10)');
    is(h_timers(), 1, '84-17 H-a: the cap re-check timer is armed');
    is($Slim::Utils::Timers::TIMERS[0][1], 1_790_000_060, '84-17 H-a: ... at HOLD_CAP_S');

    # LMS advanced by itself: the newsong of the deferred item
    h_lms_inserted();
    my $new = Test::FakeSongH->new(url => "spoton://track:$H_NEW", so => 0, duration => 180);
    $client->{song} = $new;
    $client->pluginData(progress => 77);    # stale progress must not reach the new song
    @Slim::Control::Request::EXECUTED = ();
    h_event($client, $ctl, \&Plugins::SpotOn::Connect::_onNewSong);

    is(scalar(h_log(qr/^Connect: hold closed by newsong /)), 1, '84-17 H-a: `Connect: hold closed by newsong` is logged');
    my @del = h_deletes();
    is(scalar(@del), 1, '84-17 H-a: the previous item is pruned (one `playlist delete`)');
    is_deeply($del[0]{cmd}, [ 'playlist', 'delete', 0 ], '84-17 H-a: ... by its recorded index (the playing index at insert time), I3');
    is(sprintf('%.2f', $new->startOffset), '0.00', '84-17 H-a: the new song starts at 0 -- nothing from the hold was applied to it');
    is($client->pluginData('progress'), 0, '84-17 H-a: no progress carried into the new song (N5)');
    is(h_timers(), 0, '84-17 H-a: the re-check timer is killed by the newsong');
    is_deeply($ctl->{clearHoldCalls}, [ [ $H_NEW ] ], '84-17 H-a: Control\'s clearHold ran for the deferred title');
    is(scalar(h_plays()), 0, '84-17 H-a: and still no `playlist play` anywhere');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- H-b (guard only) ---
for my $via ('departed', 'none', 'unknown', 'timeout', undef) {
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, $via);
    my $label = defined $via ? $via : 'absent';
    is(scalar(h_plays()), 1, "84-17 H-b (guard, passes pre- and post-fix): via=$label -> the immediate `playlist play`");
    is(scalar(h_inserts()), 0, "84-17 H-b (guard): via=$label -> no insert, no hold");
    is(h_timers(), 0, "84-17 H-b (guard): via=$label -> no hold timer");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- H-c: cancellation set ---
# Each case opens a hold, lets LMS insert the deferred item, fires the event,
# then checks: the deferred entry was removed (`playlist delete <idx+1>`), the
# hold closed `cancel:<reason>`, Control's clearHold ran, the cap timer is
# gone and NO late `playlist play` ever fires.
my %h_cancel = (
    start       => sub { my ($c, $k) = @_; h_connect($c, $k, _cmd => 'start', _p2 => $H_NEX, _p3 => '1.000'); },
    session_end => sub { my ($c, $k) = @_; h_connect($c, $k, _cmd => 'stop', _p2 => 'inactive'); },
    lms_seek    => sub { my ($c, $k) = @_; h_event($c, $k, \&Plugins::SpotOn::Connect::_onSeek, _newvalue => 50); },
    lms_jump    => sub { my ($c, $k) = @_; h_event($c, $k, \&Plugins::SpotOn::Connect::_onPlaylistJump, _index => '+1'); },
    lms_stop    => sub { my ($c, $k) = @_; h_event($c, $k, \&Plugins::SpotOn::Connect::_onLmsStop); },
    'foreign-newsong' => sub {
        my ($c, $k) = @_;
        $c->{song} = Test::FakeSongH->new(url => "spoton://track:$H_NEX", so => 0, duration => 180);
        h_event($c, $k, \&Plugins::SpotOn::Connect::_onNewSong);
    },
);
for my $reason (sort keys %h_cancel) {
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    $client->pluginData(connectStartTime => 0);
    $h_cancel{$reason}->($client, $ctl);
    my $plays_after_event = scalar(h_plays());

    is(scalar(h_log(qr/^Connect: hold closed by cancel:\Q$reason\E /)), 1,
        "84-17 H-c: $reason cancels the hold (`Connect: hold closed by cancel:$reason`)");
    my @del = h_deletes();
    is_deeply([ map { $_->{cmd}[2] } @del ], [ 1 ], "84-17 H-c: $reason removes the deferred playlist entry (index playing+1)");
    is(h_timers(), 0, "84-17 H-c: $reason kills the cap timer");
    is_deeply($ctl->{clearHoldCalls}, [ [ $H_NEW ] ], "84-17 H-c: $reason runs Control's clearHold");
    # 84.2-05: the real _holdClose clears the unconsumed hold marker. `start` is
    # VACUOUS (its new dispatch re-stamps its own url after the cancel; the isnt
    # documents the reason and pins nothing).
    my $hm = $client->pluginData('connectOwnPlayUri');
    if ($reason eq 'start') {
        isnt($hm // '', "spoton://track:$H_NEW", "84.2-05 H-c: $reason drops the cancelled hold's marker (the new start dispatch stamps its own url)");
    }
    else {
        is($hm, '', "84.2-05 H-c: $reason clears the unconsumed hold marker (the real _holdClose)");
    }
    h_fire_at(1_790_000_100);
    is(scalar(h_plays()), $plays_after_event, "84-17 H-c: no late `playlist play` fires after $reason (the hold timer is gone)");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# a second change: non-live replaces the playlist (immediate play) and cancels
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    h_change($client, $ctl, $H_NEX, 'departed');
    is(scalar(h_log(qr/^Connect: hold closed by cancel:change /)), 1, '84-17 H-c: a second (departed) change cancels the hold');
    is(scalar(h_plays()), 1, '84-17 H-c: ... and takes the immediate `playlist play` (which replaces the playlist, the deferred entry goes with it)');
    is(h_timers(), 0, '84-17 H-c: ... no hold timer left');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
# a second LIVE change replaces the deferred entry and re-arms the cap
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    $H_NOW += 20;
    h_change($client, $ctl, $H_NEX, 'live');
    my @del = h_deletes();
    is_deeply([ map { $_->{cmd}[2] } @del ], [ 1 ], '84-17 H-c: a second live change removes the older deferred entry first');
    my @ins = h_inserts();
    is_deeply($ins[0]{cmd}, [ 'playlist', 'insert', "spoton://track:$H_NEX" ], '84-17 H-c: ... then inserts the new one');
    is(h_timers(), 1, '84-17 H-c: exactly one cap timer (re-armed, not doubled)');
    is($Slim::Utils::Timers::TIMERS[0][1], 1_790_000_080, '84-17 H-c: ... from the new change');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# what does NOT cancel: a plain stop (the app's pause), a daemon seek/resume,
# volume. Written so it fails on a naive hold that cancels on ANY seek.
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    @Slim::Utils::Log::LINES = ();
    $client->pluginData(connectStartTime => 0);
    $client->pluginData(newTrack => 0);
    h_connect($client, $ctl, _cmd => 'stop');                                                        # the app's pause
    h_connect($client, $ctl, _cmd => 'seek', _p2 => '242.603', _p4 => 'deferred');                   # the daemon's end-of-write pair
    h_connect($client, $ctl, _cmd => 'resume', _p2 => $H_NEW, _p3 => '242.605', _p4 => 'deferred');
    h_connect($client, $ctl, _cmd => 'volume', _p2 => 33);
    is(scalar(h_log(qr/^Connect: hold closed by/)), 0,
        '84-17 H-c: a plain stop (the app\'s pause), a daemon seek/resume and a volume do NOT cancel the hold');
    is(h_timers(), 1, '84-17 H-c: the cap timer is still armed after them');
    is(scalar(h_deletes()), 0, '84-17 H-c: the deferred entry is still in the playlist');
    is_deeply($ctl->{clearHoldCalls}, [], '84-17 H-c: Control\'s record is untouched');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- H-d: the safety timer -- ONE rule, fixed precedence d1, d4, d3, d2 ---
# d1: the player stopped (the tail drained, LMS did not advance) -> ONE fallback play at the cap
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    $Slim::Player::Source::PLAYMODE = 'stop';
    h_fire_at(1_790_000_060);
    my @p = h_plays();
    is(scalar(@p), 1, '84-17 H-d d1: LMS stopped at the cap -> exactly ONE fallback `playlist play`');
    is_deeply($p[0]{cmd}, [ 'playlist', 'play', "spoton://track:$H_NEW" ], '84-17 H-d d1: ... of the deferred item');
    is(scalar(h_log(qr/^Connect: hold closed by cap reason=lms_stopped /)), 1, '84-17 H-d d1: `hold closed by cap reason=lms_stopped`');
    is_deeply($ctl->{clearHoldCalls}, [ [ $H_NEW ] ], '84-17 H-d d1: clearHold runs (before the fallback play)');
    is(h_timers(), 0, '84-17 H-d d1: no timer left');
    h_fire_at(1_790_000_200);
    is(scalar(h_plays()), 1, '84-17 H-d d1: and it never fires twice');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
# d2: LMS still plays the old url -> NO play at the cap, re-armed every HOLD_RECHECK_S
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    h_fire_at(1_790_000_060);
    is(scalar(h_plays()), 0, '84-17 H-d d2: LMS still plays the old title at the cap -> NO play (pre-fix draft played blindly)');
    is(h_timers(), 1, '84-17 H-d d2: re-armed');
    is($Slim::Utils::Timers::TIMERS[0][1], 1_790_000_065, '84-17 H-d d2: ... every HOLD_RECHECK_S (5 s)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
# d3: the ceiling -- 180 s of accumulated PLAYING time on the old url -> play (reason=ceiling)
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    my $t = 1_790_000_060;
    my $played_at;
    while ($t <= 1_790_000_400) {
        h_fire_at($t);
        if (h_plays()) { $played_at = $t; last; }
        $t += 5;
    }
    is($played_at, 1_790_000_180, '84-17 H-d d3: the ceiling plays after 180 s of PLAYING time (not before)');
    is(scalar(h_log(qr/^Connect: hold closed by cap reason=ceiling /)), 1, '84-17 H-d d3: `hold closed by cap reason=ceiling`');
    is(scalar(h_plays()), 1, '84-17 H-d d3: exactly one play');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
# d4a: the app's pause (connectSessionPaused, GH #158) -- never plays, at the cap and past 180 s
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    $client->pluginData(connectSessionPaused => 1);
    $Slim::Player::Source::PLAYMODE = 'pause';
    for (my $t = 1_790_000_060; $t <= 1_790_000_400; $t += 5) { h_fire_at($t); }
    is(scalar(h_plays()), 0, '84-17 H-d d4a: the app\'s pause at the cap and past 180 s NEVER plays');
    is(h_timers(), 1, '84-17 H-d d4a: the timer keeps re-arming indefinitely');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
# d4b: an LMS-side user pause (playmode pause, connectSessionPaused 0) -- never plays; after the resume the ceiling resumes its count
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    h_fire_at(1_790_000_060);                      # playing: 60 s counted
    $Slim::Player::Source::PLAYMODE = 'pause';
    for (my $t = 1_790_000_065; $t <= 1_790_000_300; $t += 5) { h_fire_at($t); }
    is(scalar(h_plays()), 0, '84-17 H-d d4b: an LMS-side user pause at the cap and past 180 s NEVER plays (pre-fix: played at 180 s)');
    $Slim::Player::Source::PLAYMODE = 'play';      # resumed
    h_fire_at(1_790_000_305);
    is(scalar(h_plays()), 0, '84-17 H-d d4b: after the resume the ceiling continues with its OLD count (60 s + 5), no play yet');
    my $played_at;
    for (my $t = 1_790_000_310; $t <= 1_790_000_600; $t += 5) { h_fire_at($t); if (h_plays()) { $played_at = $t; last; } }
    is($played_at, 1_790_000_420, '84-17 H-d d4b: ... and plays only when 180 s of PLAYING time have accumulated');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- H-e: far ahead of the audible end, and dropped positions ---
{
    my ($client, $ctl, $old) = h_setup(elapsed => 42, duration => 200);    # the LMS clock 42 s into a 200 s title
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    is(scalar(h_plays()), 0, '84-17 H-e: a `live` frame far ahead of the audible end also defers (no `playlist play`)');
    @Slim::Control::Request::EXECUTED = ();
    h_fire_at(1_790_000_060);
    is(scalar(h_plays()), 0, '84-17 H-e: ... and the cap timer re-checks instead of playing while LMS still plays the old item');

    # every seek ... deferred and every resume <deferredId> <pos> is dropped
    @Slim::Utils::Log::LINES = ();
    $client->pluginData(connectStartTime => 0);
    h_connect($client, $ctl, _cmd => 'seek', _p2 => '242.603', _p4 => 'deferred');
    h_connect($client, $ctl, _cmd => 'resume', _p2 => $H_NEW, _p3 => '242.605', _p4 => 'deferred');
    h_connect($client, $ctl, _cmd => 'seek', _p2 => '12.000', _p4 => 'deferred');                     # a later re-anchor pair
    h_connect($client, $ctl, _cmd => 'resume', _p2 => $H_NEW, _p3 => '12.100');                       # a storm resume, unmarked id match
    is(sprintf('%.2f', $old->startOffset), '12.34',
        '84-17 H-e: the playing song\'s startOffset never changes during the hold (pre-fix: -10 .. +232)');
    is(scalar(h_log(qr/^Connect: deferred position dropped pos=/)), 4, '84-17 H-e: one `Connect: deferred position dropped pos=<p>` line each');
    is($client->pluginData('progress') // 0, 0, '84-17 H-e: nothing is stored for the new song');
    ok(scalar(grep { $_->{cmd}[0] eq 'pause' && $_->{cmd}[1] eq '0' } @Slim::Control::Request::EXECUTED),
        '84-17 H-e: the resume\'s [pause, 0] stays (a no-op on a playing player)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
# the marker without a hold changes nothing (a deferred seek with no hold is handled as today)
{
    my ($client, $ctl, $old) = h_setup(so => 0, elapsed => 10);
    h_connect($client, $ctl, _cmd => 'seek', _p2 => '12.500', _p4 => 'deferred');
    is(sprintf('%.2f', $old->startOffset), '2.50', '84-17 H-e: a `seek ... deferred` while NO hold is open is applied as today');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- H-g: a change without via (a nachziehen re-emit) while a hold is open ---
{
    my ($client, $ctl, $old) = h_setup();
    h_change($client, $ctl, $H_NEW, 'live');
    h_lms_inserted();
    @Slim::Control::Request::EXECUTED = ();
    h_change($client, $ctl, $H_NEW, undef);
    is(scalar(h_log(qr/^Connect: hold closed by cancel:change /)), 1, '84-17 H-g: a change without via cancels the hold');
    is(scalar(h_plays()), 1, '84-17 H-g: ... and takes the immediate `playlist play` (the safe direction)');
    is(h_timers(), 0, '84-17 H-g: no second hold');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# --- H-i: the hold only when LMS's own advance will open the deferred item ---
{
    my ($client, $ctl, $old) = h_setup(repeat => 1);
    h_change($client, $ctl, $H_NEW, 'live');
    is(scalar(h_log(qr/^Connect: hold skipped reason=repeat_one /)), 1, '84-17 H-i: repeat-one -> `Connect: hold skipped reason=repeat_one`');
    is(scalar(h_plays()), 1, '84-17 H-i: repeat-one takes the immediate `playlist play` (LMS would re-open the OLD url)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
for my $dur (undef, 0) {
    my ($client, $ctl, $old) = h_setup(duration => $dur);
    h_change($client, $ctl, $H_NEW, 'live');
    my $label = defined $dur ? $dur : 'undef';
    is(scalar(h_log(qr/^Connect: hold skipped reason=no_duration /)), 1, "84-17 H-i: duration $label -> `hold skipped reason=no_duration`");
    is(scalar(h_plays()), 1, "84-17 H-i: duration $label takes the immediate `playlist play` (the radio-retry branch would re-stream the OLD url)");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
for my $rep (0, 2) {
    my ($client, $ctl, $old) = h_setup(repeat => $rep);
    h_change($client, $ctl, $H_NEW, 'live');
    is(scalar(h_plays()), 0, "84-17 H-i: repeat $rep with a duration > 0 holds");
    is(scalar(h_inserts()), 1, "84-17 H-i: repeat $rep inserts the deferred item");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}
{
    my ($client, $ctl, $old) = h_setup(isPlaying => 0);
    h_change($client, $ctl, $H_NEW, 'live');
    is(scalar(h_log(qr/^Connect: hold skipped reason=not_playing /)), 1, '84-17 H-i: a paused/stopped LMS has no tail -> `hold skipped reason=not_playing`');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

{
    no warnings 'redefine';
    *Time::HiRes::time = $H_REAL_TIME;
}

# ==================================================================
# 84.3-01 (D-01..D-07, D-11): the Connect context-end settle. LMS discards the
# context-end pause while it rebuffers (StreamingController Pause row
# BUFFERING -> _NoOp, SC:133-139) and stays BUFFERING; Connect.pm must settle
# that state with ONE source-marked ['stop'] -- and only that state.
# Test::FakeLms is a small LMS state-table double: fake_lms_rows (installed as
# $Slim::Control::Request::ON_EXECUTE) turns a pause into PAUSED only when LMS
# was PLAYING, so "pause discarded" is modelled by construction, not by hand.
# ==================================================================
package Test::FakeLmsController;
sub new         { my ($class, $lms) = @_; return bless { lms => $lms }, $class; }
# SC:1697-1702: buffering() is 2 for a rebuffer, 1 for an initial buffering.
sub buffering   { my $l = $_[0]->{lms}; return $l->{state} eq 'BUFFERING' ? ($l->{rebuffering} ? 2 : 1) : 0; }
sub playingSongElapsed  { return $_[0]->{lms}->{elapsed}; }
sub playingSongDuration { return $_[0]->{lms}->{duration}; }

package Test::FakeLms;
our @ISA = ('Test::FakeClient');
our %REG;
sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(power => 1, state => 'PLAYING', rebuffering => 0, fullness => 0,
        elapsed => 0, duration => 0, url => '', synced => 0, @_);
    $REG{ $self->{id} } = $self;
    return $self;
}
sub isPlaying {
    my ($self, $really) = @_;
    return ($self->{state} eq 'PLAYING' ? 1 : 0) if $really;
    return ($self->{state} ne 'STOPPED' && $self->{state} ne 'PAUSED') ? 1 : 0;
}
sub isPaused     { return $_[0]->{state} eq 'PAUSED'  ? 1 : 0; }
sub isStopped    { return $_[0]->{state} eq 'STOPPED' ? 1 : 0; }
sub isSynced     { return $_[0]->{synced} ? 1 : 0; }
sub bufferFullness { return $_[0]->{fullness}; }
sub controller   { return Test::FakeLmsController->new($_[0]); }
sub playingSong  { return length($_[0]->{url}) ? Test::FakeSongC4->new(url => $_[0]->{url}) : undef; }
sub songElapsedSeconds { return $_[0]->{elapsed}; }

package main;

sub fake_lms_rows {
    my ($req) = @_;
    my $lms = $Test::FakeLms::REG{ $req->{clientid} } or return;
    my $c = $req->{cmd} || [];
    if (($c->[0] // '') eq 'pause' && ($c->[1] // '') eq '1') {
        $lms->{state} = 'PAUSED' if $lms->{state} eq 'PLAYING';    # BUFFERING: Pause row _NoOp
    }
    elsif (($c->[0] // '') eq 'stop') {
        $lms->{state} = 'STOPPED';                                  # Stop row _Stop
    }
}

sub settle_stops {
    return grep { ref($_->{cmd}) eq 'ARRAY' && ($_->{cmd}[0] // '') eq 'stop' } @Slim::Control::Request::EXECUTED;
}
sub settle_warns { return grep { index($_, 'Connect: context-end settle -- ') == 0 } @Slim::Utils::Log::WARNS; }
sub check_infos  { return grep { index($_, 'Connect: context-end check -- ')  == 0 } @Slim::Utils::Log::LINES; }
sub settle_timers {
    my ($client) = @_;
    my $cb = Plugins::SpotOn::Connect->can('_settleFire');
    return () unless $cb;
    return grep { $_->[0] == $client && $_->[2] == $cb } @Slim::Utils::Timers::TIMERS;
}
sub n_settle_timers { my @t = settle_timers($_[0]); return scalar(@t); }
sub n_settle_stops  { my @t = settle_stops();       return scalar(@t); }

sub s_lms {
    my (%a) = @_;
    my $lms = Test::FakeLms->new(%a);
    start_session($lms);
    Plugins::SpotOn::Connect->bindConnectClaim($lms, 'transfer');
    $lms->pluginData(connectStartTime => 0);     # past CONNECT_START_GRACE
    $lms->pluginData(newTrack => 0);
    @Slim::Control::Request::EXECUTED = ();
    @Slim::Utils::Log::WARNS = ();
    @Slim::Utils::Log::LINES = ();
    @Slim::Utils::Timers::TIMERS = ();
    return $lms;
}

sub s_event {
    my ($lms, %p) = @_;
    local $Slim::Control::Request::ON_EXECUTE = \&fake_lms_rows;
    Plugins::SpotOn::Connect::_connectEvent(Test::FakeRequest->new($lms, %p));
}

sub s_idx {   # index of the first executed request matching cmd[0] (and cmd[1] when given), or -1
    my ($c0, $c1) = @_;
    for my $i (0 .. $#Slim::Control::Request::EXECUTED) {
        my $c = $Slim::Control::Request::EXECUTED[$i]{cmd};
        next unless ref($c) eq 'ARRAY' && ($c->[0] // '') eq $c0;
        next if defined $c1 && ($c->[1] // '') ne $c1;
        return $i;
    }
    return -1;
}

my $S_URL = 'spoton://track:5oiTnaEHK3OFDZIL8AIYwu';

# --- S1: the run13 race, real values (server.log.2026-10-13.gz lines 35083-35104:
# 01:14:41.0023 playerOutputUnderrun decoder 3896 / output 0, OutputUnderrun in
# PLAYING-STREAMING -> _Rebuffer, 01:14:41.0457 `Pause in BUFFERING-STREAMING ->
# _NoOp`; LMS clock 118.491 + 82.624 = 201.115, duration 201.142) ---
{
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 3896,
        elapsed => 201.115, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    my @stops = settle_stops();
    my @w     = settle_warns();
    is(scalar(@stops), 1, '84.3 S1: real-run13 -- the stuck context end settles with exactly one stop');
    is($stops[0] ? $stops[0]->source : undef, 'Plugins::SpotOn::Connect',
        '84.3 S1: real-run13 -- the stop is source-marked (Plugins::SpotOn::Connect)');
    ok(s_idx('pause', '1') >= 0 && s_idx('stop') > s_idx('pause', '1'),
        '84.3 S1: real-run13 -- the stop comes after the [pause,1]');
    is(scalar(@w), 1, '84.3 S1: real-run13 -- exactly one settle warn line');
    like($w[0] // '', qr/via=immediate songTime=201\.115 duration=201\.142 fullness=3896/,
        '84.3 S1: real-run13 -- the warn line carries via/songTime/duration/fullness');
    is($lms->pluginData('connectSessionPaused'), 1, '84.3 S1: real-run13 -- connectSessionPaused stays 1');
    my @bad = grep {
        my $c = $_->{cmd};
        ref($c) eq 'ARRAY' && ( ($c->[0] // '') eq 'power'
            || (($c->[0] // '') eq 'playlist' && ($c->[1] // '') eq 'clear')
            || (($c->[0] // '') eq 'pause' && ($c->[1] // '') eq '0') )
    } @Slim::Control::Request::EXECUTED;
    is(scalar(@bad) + n_settle_timers($lms), 0,
        '84.3 S1: real-run13 -- no playlist clear, power or unpause request and no grace timer');
    ok($lms->{state} eq 'STOPPED' && Plugins::SpotOn::Connect->isSpotifyConnect($lms),
        '84.3 S1: real-run13 -- LMS ends STOPPED and the Connect claim stays bound');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S2: the 2026-10-09 20:34 race, real values (server.log.2026-10-09.gz lines
# 84563-84583: 20:34:12.0035 playerOutputUnderrun decoder 848 / output 0,
# 20:34:12.4239 `Pause in BUFFERING-STREAMING -> _NoOp`; clock 140.1 + 63.581 =
# 203.681 capped by playingSongElapsed to the duration 201.142) ---
{
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 848,
        elapsed => 201.142, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    my @w = settle_warns();
    is(n_settle_stops(), 1, '84.3 S2: real-2034 -- the capped-clock race settles with one stop');
    like($w[0] // '', qr/via=immediate songTime=201\.142 duration=201\.142 fullness=848/,
        '84.3 S2: real-2034 -- the warn line carries the capped clock and fullness 848');
    is($lms->pluginData('connectSessionPaused'), 1, '84.3 S2: real-2034 -- connectSessionPaused stays 1');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S3: the honoured context-end pause, real values (run8: server.log.2026-10-09.gz
# lines 93726-93757: 21:09:27.9899 `Pause in PLAYING-STREAMING -> _Pause`, decoder
# 3800 / output 0; status series last row `pause 201.142`) ---
{
    my $lms = s_lms(state => 'PLAYING', rebuffering => 0, fullness => 3800,
        elapsed => 201.142, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    my @ci = check_infos();
    is(n_settle_stops(), 0, '84.3 S3: real-run8 -- an honoured pause issues no stop');
    is(n_settle_timers($lms), 0, '84.3 S3: real-run8 -- an honoured pause arms no timer');
    ok(scalar(@ci) == 1 && $ci[0] =~ /no settle \(pause_honoured\)/,
        '84.3 S3: real-run8 -- exactly one check info `no settle (pause_honoured)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# ==================================================================
# 84.3-01 Task 2 (D-02, D-05): the grace re-check, the cancel sites and every
# must-NOT case. None of S4-S10 replays a real recording: every name carries
# `synthetic --` so a PASS cannot be read as real-material proof.
# ==================================================================
package Test::FakeStopReq93;
sub new    { my ($class, %a) = @_; return bless {%a}, $class; }
sub client { return $_[0]->{client}; }
sub source { return $_[0]->{source}; }

# Test::FakeCtlS93 -- FakeCtlD02 plus the `observed` accessor the backend role's state() reads
# (observedTrack / status): without it a connect-mode double never reports an observed track.
package Test::FakeCtlS93;
our @ISA = ('Test::FakeCtlD02');
sub observed { return $_[0]->{observed}; }

package main;

sub s_event_ctl {   # one event with a FakeCtlD02 behind Control->for_client
    my ($lms, $ctl, %p) = @_;
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
    s_event($lms, %p);
}

sub s_arm {   # the S5 grace state: BUFFERING (not rebuffering), clock near the end
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 0, fullness => 3896,
        elapsed => 200.9, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    return $lms;
}

sub s_stuck {   # what the seek echo + the lingering rebuffer look like at fire time
    my ($lms) = @_;
    $lms->{elapsed} = 0;
    $lms->{rebuffering} = 1;
}

sub s_fire { Slim::Utils::Timers::fire_due(Time::HiRes::time() + 2); }

sub n_infos { my ($re) = @_; my @i = grep { $_ =~ $re } check_infos(); return scalar(@i); }

# --- S4: a stuck rebuffer mid-title never settles (D-04) ---
{
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 3896,
        elapsed => 120.0, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    is(n_settle_stops(), 0, '84.3 S4: synthetic -- a stuck rebuffer at 120.0 of 201.142 s sends no stop');
    is(n_settle_timers($lms), 0, '84.3 S4: synthetic -- ... and arms no grace timer');
    is(n_infos(qr/no settle \(not_context_end\)/), 1, '84.3 S4: synthetic -- ... check info `no settle (not_context_end)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S5: playing-but-not-stuck at the context end -> ONE grace timer, then one stop from the snapshot ---
{
    my $t0  = Time::HiRes::time();
    my $lms = s_arm();
    my $t1  = Time::HiRes::time();
    my @tm  = settle_timers($lms);
    is(n_settle_stops(), 0, '84.3 S5: synthetic -- no stop at the immediate check (LMS not stuck yet)');
    is(scalar(@tm), 1, '84.3 S5: synthetic -- exactly one grace timer is armed');
    ok(@tm && $tm[0][1] >= $t0 + 1.5 && $tm[0][1] <= $t1 + 1.5,
        '84.3 S5: synthetic -- ... due SETTLE_GRACE_S = 1.5 s after the stop');
    s_stuck($lms);    # clock zeroed on purpose (KF-3), rebuffer now stuck
    s_fire();
    my @stops = settle_stops();
    my @w     = settle_warns();
    is(scalar(@stops), 1, '84.3 S5: synthetic -- the grace fire settles with exactly one stop');
    is($stops[0] ? $stops[0]->source : undef, 'Plugins::SpotOn::Connect', '84.3 S5: synthetic -- ... source-marked');
    like($w[0] // '', qr/via=grace songTime=200\.900 duration=201\.142 fullness=3896/,
        '84.3 S5: synthetic -- ... the warn line is `via=grace` with the SNAPSHOT clock 200.900, not the zeroed LMS clock');
    @Slim::Control::Request::EXECUTED = ();
    s_fire();
    is(n_settle_stops(), 0, '84.3 S5: synthetic -- a second fire settles nothing');
    ok(!$lms->pluginData('connectCtxEnd'), '84.3 S5: synthetic -- connectCtxEnd is cleared');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S6a: a resume event cancels the armed grace timer (the timer-presence assertion is what turns red
# when the cancel site is missing -- the fire-time veto alone would hide it) ---
{
    my $lms = s_arm();
    my $ctl = Test::FakeCtlS93->new(mode => 'connect', client => $lms,
        observed => { track => 'spotify:track:5oiTnaEHK3OFDZIL8AIYwu', status => 'playing' });
    s_event_ctl($lms, $ctl, _cmd => 'resume', _p2 => '5oiTnaEHK3OFDZIL8AIYwu', _p3 => '0.000');
    is(n_settle_timers($lms), 0, '84.3 S6a: synthetic -- right after the resume event no grace timer is left');
    ok(!$lms->pluginData('connectCtxEnd'), '84.3 S6a: synthetic -- ... and the snapshot is cleared');
    s_stuck($lms);
    @Slim::Control::Request::EXECUTED = ();
    s_fire();
    is(n_settle_stops(), 0, '84.3 S6a: synthetic -- ... and a later fire sends no stop');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S6b-e: the fire-time veto, each from the S5 armed state with exactly one thing changed ---
{
    my $lms = s_arm();
    s_stuck($lms);
    $lms->{url} = 'spoton://track:4iV5W9uYEdYUVa79Axb7Rh';
    s_fire();
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped \(url_changed\)/) == 1,
        '84.3 S6b: synthetic -- url changed before the fire: no stop, `grace skipped (url_changed)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}
{
    my $lms = s_arm();
    s_stuck($lms);
    $lms->{state} = 'PAUSED';
    s_fire();
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped \(not_stuck\)/) == 1,
        '84.3 S6c: synthetic -- LMS paused before the fire: no stop, `grace skipped (not_stuck)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}
{
    my $lms = s_arm();
    s_stuck($lms);
    $lms->pluginData(connectSessionPaused => 0);
    s_fire();
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped \(session_resumed\)/) == 1,
        '84.3 S6d: synthetic -- connectSessionPaused 0 before the fire: no stop, `grace skipped (session_resumed)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}
{
    my $lms = s_arm();
    s_stuck($lms);
    $lms->{fullness} = 9000;
    s_fire();
    # 84.3-rev WR-01: the FIRST data_arriving is a one-time re-arm, not a verdict (the terminal
    # `grace skipped (data_arriving)` is the second one, S11b)
    ok(n_settle_stops() == 0 && n_infos(qr/grace re-armed \(data_arriving\)/) == 1,
        '84.3 S6e: synthetic -- buffer fullness grew before the fire: no stop, `grace re-armed (data_arriving)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S11 (84.3-REVIEW WR-01): the arm-time fullness is a small start-buffering reading, the fire sees
# the larger post-underrun residue. The first data_arriving re-arms ONCE with the current fullness as
# the new baseline; the second fire settles because the rebuffer persists with unchanged fullness ---
{
    my $lms = s_arm();                       # arm baseline 3896
    $lms->{fullness} = 9000;                 # grew arm -> fire 1
    s_stuck($lms);
    s_fire();                                # fire 1
    my $ctx = $lms->pluginData('connectCtxEnd');
    ok(n_settle_stops() == 0 && n_infos(qr/grace re-armed \(data_arriving\)/) == 1,
        '84.3 S11: synthetic -- fire 1 sees grown fullness: no stop, one `grace re-armed (data_arriving)`');
    # 84.3-rev IN-05: the re-arm line carries old and new fullness, so a re-armed settle keeps the
    # stop-instant reading in the log
    is(n_infos(qr/grace re-armed \(data_arriving\) fullness=3896->9000 /), 1,
        '84.3 S11: synthetic -- ... the re-arm line logs `fullness=3896->9000` (stop-instant -> fire 1)');
    is(n_settle_timers($lms), 1, '84.3 S11: synthetic -- ... exactly one timer is left (D-02: at most one per client)');
    ok(ref($ctx) eq 'HASH' && $ctx->{rearmed} && $ctx->{fullness} == 9000,
        '84.3 S11: synthetic -- ... the snapshot is re-armed with the current fullness 9000 as the new baseline');
    s_fire();                                # fire 2: unchanged, rebuffer persists
    my @stops = settle_stops();
    my @w     = settle_warns();
    is(scalar(@stops), 1, '84.3 S11: synthetic -- fire 2 (fullness unchanged, rebuffer persists) settles with exactly one stop');
    is($stops[0] ? $stops[0]->source : undef, 'Plugins::SpotOn::Connect', '84.3 S11: synthetic -- ... source-marked');
    like($w[0] // '', qr/via=grace songTime=200\.900 duration=201\.142 fullness=9000/,
        '84.3 S11: synthetic -- ... the warn line is `via=grace` with the snapshot clock and the re-armed fullness');
    is(n_settle_timers($lms), 0, '84.3 S11: synthetic -- ... no timer is left');
    ok(!$lms->pluginData('connectCtxEnd'), '84.3 S11: synthetic -- ... connectCtxEnd is cleared');
    @Slim::Control::Request::EXECUTED = ();
    s_fire();
    is(n_settle_stops(), 0, '84.3 S11: synthetic -- a further fire settles nothing');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S11b: fullness grows again on fire 2 -> a second data_arriving stays terminal ("LMS is recovering") ---
{
    my $lms = s_arm();
    $lms->{fullness} = 9000;
    s_stuck($lms);
    s_fire();                                # fire 1: re-arm
    $lms->{fullness} = 12000;                # grew again fire 1 -> fire 2
    s_fire();                                # fire 2
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped \(data_arriving\)/) == 1,
        '84.3 S11b: synthetic -- fullness grows again on fire 2: no stop, terminal `grace skipped (data_arriving)`');
    is(n_infos(qr/grace re-armed/), 1, '84.3 S11b: synthetic -- ... and it was re-armed only once');
    is(n_settle_timers($lms), 0, '84.3 S11b: synthetic -- ... no timer is left');
    ok(!$lms->pluginData('connectCtxEnd'), '84.3 S11b: synthetic -- ... connectCtxEnd is cleared');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S11c: a cancel site (the resume event) between fire 1 and fire 2 kills the RE-ARMED timer ---
{
    my $lms = s_arm();
    $lms->{fullness} = 9000;
    s_stuck($lms);
    s_fire();                                # fire 1: re-arm
    is(n_settle_timers($lms), 1, '84.3 S11c: synthetic -- (setup) the re-armed timer is pending');
    my $ctl = Test::FakeCtlS93->new(mode => 'connect', client => $lms,
        observed => { track => 'spotify:track:5oiTnaEHK3OFDZIL8AIYwu', status => 'playing' });
    s_event_ctl($lms, $ctl, _cmd => 'resume', _p2 => '5oiTnaEHK3OFDZIL8AIYwu', _p3 => '0.000');
    is(n_settle_timers($lms), 0, '84.3 S11c: synthetic -- the resume event cancels the re-armed timer');
    ok(!$lms->pluginData('connectCtxEnd'), '84.3 S11c: synthetic -- ... and clears the snapshot');
    s_stuck($lms);
    @Slim::Control::Request::EXECUTED = ();
    s_fire();
    is(n_settle_stops(), 0, '84.3 S11c: synthetic -- ... so a later fire sends no stop');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S11d: the D-05 vetoes apply on the SECOND fire exactly as on the first (url changed, LMS paused) ---
{
    my $lms = s_arm();
    $lms->{fullness} = 9000;
    s_stuck($lms);
    s_fire();
    $lms->{url} = 'spoton://track:4iV5W9uYEdYUVa79Axb7Rh';
    s_fire();
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped \(url_changed\)/) == 1,
        '84.3 S11d: synthetic -- url changed before fire 2: no stop, `grace skipped (url_changed)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}
{
    my $lms = s_arm();
    $lms->{fullness} = 9000;
    s_stuck($lms);
    s_fire();
    $lms->{state} = 'PAUSED';
    s_fire();
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped \(not_stuck\)/) == 1,
        '84.3 S11d: synthetic -- LMS paused before fire 2: no stop, `grace skipped (not_stuck)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S12 (84.3-REVIEW IN-02): a grace timer is armed, then a second stop event of the SAME title settles
# immediately (LMS now rebuffering, clock still at the title end). The immediate settle cancels the
# pending grace timer: no stray fire after STOPPED, no stale snapshot, no second skip line ---
{
    my $lms = s_arm();
    is(n_settle_timers($lms), 1, '84.3 S12: synthetic -- (setup) the first stop event armed one grace timer');
    $lms->{rebuffering} = 1;                 # LMS has meanwhile rebuffered; clock stays at 200.9
    s_event($lms, _cmd => 'stop');           # second stop event -> immediate settle
    is(n_settle_stops(), 1, '84.3 S12: synthetic -- the second stop event settles immediately with one stop');
    is(n_settle_timers($lms), 0, '84.3 S12: synthetic -- ... and the earlier-armed grace timer is cancelled');
    ok(!$lms->pluginData('connectCtxEnd'), '84.3 S12: synthetic -- ... and no stale snapshot is left');
    @Slim::Control::Request::EXECUTED = ();
    @Slim::Utils::Log::LINES = ();
    s_fire();
    ok(n_settle_stops() == 0 && n_infos(qr/grace skipped/) == 0,
        '84.3 S12: synthetic -- ... so a later fire sends no stop and logs no `grace skipped`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S13 (84.3-REVIEW IN-03): the armed snapshot carries ONE fullness field (the stop-instant
# value the settle warn line prints and the fire veto compares); no duplicate `fullnessAtArm` ---
{
    my $lms = s_arm();
    my $ctx = $lms->pluginData('connectCtxEnd');
    ok(ref($ctx) eq 'HASH', '84.3 S13: synthetic -- (setup) the grace arm stores a snapshot hashref');
    is(ref($ctx) eq 'HASH' ? $ctx->{fullness} : undef, 3896,
        '84.3 S13: synthetic -- the snapshot carries the stop-instant fullness 3896 in `fullness`');
    ok(ref($ctx) eq 'HASH' && !exists $ctx->{fullnessAtArm},
        '84.3 S13: synthetic -- ... and no duplicate `fullnessAtArm` field');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S7: a second stop event after the settle does nothing (idempotence, KF-8/OQ-2) ---
{
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 3896,
        elapsed => 201.115, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    is(n_settle_stops(), 1, '84.3 S7: synthetic -- (setup) the first stop event settled once');
    @Slim::Control::Request::EXECUTED = ();
    s_event($lms, _cmd => 'stop');
    is(n_settle_stops(), 0, '84.3 S7: synthetic -- a second stop event with LMS STOPPED sends no second stop');
    is(n_settle_timers($lms), 0, '84.3 S7: synthetic -- ... and arms no timer');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S8 / S8b: only the duration (resp. the sync group) holds the settle back ---
for my $dur (undef, 0) {
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 3896,
        elapsed => 201.115, duration => $dur, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    my $d = defined $dur ? $dur : 'undef';
    ok(n_settle_stops() == 0 && n_infos(qr/no settle \(duration_unknown\)/) == 1,
        "84.3 S8: synthetic -- duration $d at the title end: no stop, `no settle (duration_unknown)`");
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}
{
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 3896,
        elapsed => 201.115, duration => 201.142, url => $S_URL, synced => 1);
    s_event($lms, _cmd => 'stop');
    ok(n_settle_stops() == 0 && n_infos(qr/no settle \(synced\)/) == 1,
        '84.3 S8b: synthetic -- a synced player at the title end: no stop, `no settle (synced)`');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S9 / S9b: the settle's own stop is invisible to _onLmsStop; the derived unmarked
# ['playlist','stop'] leaves Control in connect (KF-8). The second case shows the same double
# DOES react to an unmarked stop, so the first one is not vacuous. ---
{
    my $lms = s_lms(state => 'BUFFERING', rebuffering => 1, fullness => 3896,
        elapsed => 201.115, duration => 201.142, url => $S_URL);
    s_event($lms, _cmd => 'stop');
    my ($own) = settle_stops();
    my $ctl   = Test::FakeCtlD02->new(mode => 'connect', client => $lms);
    my $verbs = scalar(@Plugins::SpotOn::Unified::DaemonManager::VERBS);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        Plugins::SpotOn::Connect::_onLmsStop(Test::FakeStopReq93->new(client => $lms, source => ($own ? $own->source : undef)));
    }
    ok($own && $own->source eq 'Plugins::SpotOn::Connect', '84.3 S9: synthetic -- (setup) the settle stop is source-marked');
    is(scalar(@{ $ctl->{leaveConnectCalls} }) + scalar(@{ $ctl->{endForeignLeaveCalls} }) + scalar(@{ $ctl->{requestPauseCalls} }), 0,
        '84.3 S9: synthetic -- the own stop reaches _onLmsStop: no leaveConnect, endForeignLeave or requestPause');
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::VERBS), $verbs, '84.3 S9: synthetic -- ... and no backend verb is recorded');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}
{
    my $lms = s_lms(state => 'STOPPED', url => $S_URL);
    my $ctl = Test::FakeCtlD02->new(mode => 'connect', client => $lms);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::for_client = sub { $ctl };
        local $Slim::Player::Source::PLAYMODE = 'stop';
        Plugins::SpotOn::Connect::_onLmsStop(Test::FakeStopReq93->new(client => $lms, source => undef));
    }
    is(scalar(@{ $ctl->{leaveConnectCalls} }), 0, '84.3 S9b: synthetic -- the derived unmarked stop does not leaveConnect');
    is(scalar(@{ $ctl->{requestPauseCalls} }), 0, '84.3 S9b: synthetic -- ... nor requestPause from _onLmsStop');
    is($ctl->mode, 'connect', '84.3 S9b: synthetic -- ... Control stays in connect');
    ok(scalar(@{ $ctl->{endForeignLeaveCalls} }) <= 1, '84.3 S9b: synthetic -- ... endForeignLeave at most once (a marker delete)');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

# --- S10 (KF-1): the app's Play on the STOPPED player takes the PLAIN resume path ---
{
    my $lms = s_lms(state => 'STOPPED', url => $S_URL);
    $lms->pluginData(connectSessionPaused => 1);
    my $ctl = Test::FakeCtlS93->new(mode => 'connect', client => $lms,
        observed => { track => 'spotify:track:5oiTnaEHK3OFDZIL8AIYwu', status => 'playing' });
    s_event_ctl($lms, $ctl, _cmd => 'resume', _p2 => '5oiTnaEHK3OFDZIL8AIYwu', _p3 => '0.000');
    my @un = grep { ref($_->{cmd}) eq 'ARRAY' && ($_->{cmd}[0] // '') eq 'pause' && ($_->{cmd}[1] // '') eq '0' } @Slim::Control::Request::EXECUTED;
    my @pl = grep { ref($_->{cmd}) eq 'ARRAY' && ($_->{cmd}[0] // '') eq 'playlist' && ($_->{cmd}[1] // '') eq 'play' } @Slim::Control::Request::EXECUTED;
    is(scalar(@un), 1, '84.3 S10: synthetic -- the app Play after a settled stop sends exactly one [pause,0]');
    is($un[0] ? $un[0]->source : undef, 'Plugins::SpotOn::Connect', '84.3 S10: synthetic -- ... source-marked');
    is(scalar(@pl), 0, '84.3 S10: synthetic -- ... and no `playlist play` re-entry');
    is($lms->pluginData('connectSessionPaused'), 0, '84.3 S10: synthetic -- ... connectSessionPaused is 0 again');
    Plugins::SpotOn::Connect->releaseConnectClaim($lms, 'test');
}

done_testing();
