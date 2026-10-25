#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Time::HiRes;

# Phase 82 Plan 06, Task 1 -- D-02/D-03: watchdogRing (Runde 1 Faelle
# (a)-(d), Runde 2 sichtbar). Harness copied 1:1 from t/44_soloist_control.t
# per project convention (stub set is per-file, t/31-style).

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Soloist/Control.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Soloist/Control.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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

# ============================================================
# LMS module stubs required to load Control.pm in isolation (t/31-style
# harness, copied per-file per project convention).
# ============================================================

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @WARNINGS;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { my $self = shift; push @WARNINGS, join('', @_); }
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
our %FAKE_VALUES = ( enableSpotifyConnect => 1 );
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

# Recorder -- our @TIMERS holds [$obj, $when, $cb, @extra_args]. fire_due($now)
# fires (and removes) every timer whose $when <= $now, in order.
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

# use base qw(Slim::Utils::Accessor) target. Array-based (blessed ARRAY refs,
# not hashes) to match the REAL Slim::Utils::Accessor contract -- CR-01.
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

# getClient() returns a recorder whose execute() pushes to a shared array --
# this is how tests observe the round-2 `playlist jump +1`.
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our @EXECUTED;
my %clients;
sub getClient {
    my ($mac) = @_;
    return undef unless defined $mac;
    return $clients{$mac} ||= bless { mac => $mac }, 'Slim::Player::Client::Recorder';
}
package Slim::Player::Client::Recorder;
sub execute {
    my ($self, $req) = @_;
    push @Slim::Player::Client::EXECUTED, $req;
}
sub id     { return $_[0]->{mac}; }
sub volume {
    my $self = shift;
    $self->{volume} = shift if @_;
    return $self->{volume};
}
# 84.1-02: _lmsSongIsOurs (called unconditionally from onEvent's
# _lmsPlaysOurs preamble, D-03) reads these off the client -- load-safety
# only, this file never exercises the ownership/playmode logic directly.
sub streamingSong { return undef; }
sub playingSong    { return undef; }
1;
END

write_stub($stub_dir, 'Slim::Player::Source', <<'END');
package Slim::Player::Source;
our $PLAYMODE = 'play';
our $INDEX = 0;
sub playmode { return $PLAYMODE; }
sub songTime { return 0; }
sub streamingSongIndex { return $INDEX; }
sub playingSongIndex   { return $INDEX; }
1;
END

write_stub($stub_dir, 'Slim::Player::Playlist', <<'END');
package Slim::Player::Playlist;
our @ENTRIES;
# 84.2-02: the repeat-aware lookahead reads track/repeat/shuffle (song is
# deprecated in LMS and kept here for older call sites only).
our $REPEAT = 0;
our $SHUFFLE = 0;
sub song    { my ($c, $i) = @_; return $ENTRIES[$i]; }
sub track   { $ENTRIES[$_[1]] }
sub count   { return scalar @ENTRIES; }
sub repeat  { $REPEAT }
sub shuffle { $SHUFFLE }
1;
END

# Records constructor callbacks + post($url) calls, and exposes a deferred-
# fire mode (t/29 convention) -- AUTO_FIRE 'ok' (default) fires the success
# callback synchronously inside post(), 'error' fires the error callback,
# 'defer' waits for the test to call fire_ok/fire_error manually.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @CALLS;
our $AUTO_FIRE = 'ok';
sub new {
    my ($class, $ok_cb, $err_cb, $opts) = @_;
    return bless { ok_cb => $ok_cb, err_cb => $err_cb, opts => $opts }, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    $self->{url} = $url;
    push @CALLS, $self;
    if ($AUTO_FIRE eq 'ok') {
        $self->fire_ok;
    }
    elsif ($AUTO_FIRE eq 'error') {
        $self->fire_error;
    }
    return $self;
}
sub fire_ok    { my $self = shift; $self->{ok_cb}->($self); }
sub fire_error { my $self = shift; $self->{err_cb}->($self, '500 Internal Server Error', undef); }
1;
END

# errors[] recorder -- Control's _recordErrorOnce calls
# Plugins::SpotOn::Status->recordError($level, $module, $message).
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our @RECORDED;
sub recordError {
    my $class = shift;
    push @RECORDED, [@_];
    # R3-WR02 Schritt 0: mirror the real Status.pm's MAX_ERROR_HISTORY=30
    # ring boundary -- same value as t/44's rebuilt stub.
    shift @RECORDED while scalar @RECORDED > 30;
}
# clearError (R3-WR02 Schritt 0): t/45 lacked this entirely -- add it so a
# tested clear path does not crash the stub, same module+key comparison
# as the real Status.pm.
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;
    @RECORDED = grep {
        !(($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key)
    } @RECORDED;
}
# hasError (R3-WR02 Schritt 0): same comparison as clearError, no state
# change.
sub hasError {
    my ($class, $module, $key) = @_;
    return 0 unless defined $key;
    return scalar grep {
        ($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key
    } @RECORDED;
}
1;
END

# Counts /boundary and /seek-arm POSTs by PeerPort and hands back an
# in-memory filehandle (blessed glob) so `print $sock ...; close($sock);`
# in Control's boundary/sync-arm paths never touches a real socket.
write_stub($stub_dir, 'IO::Socket::INET', <<'END');
package IO::Socket::INET;
our @CALLS;
our @REQUESTS;
our $FAIL = 0;
sub new {
    my ($class, %args) = @_;
    push @CALLS, $args{PeerPort};
    return undef if $FAIL;
    my $buf = '';
    open(my $fh, '>', \$buf) or return undef;
    push @REQUESTS, { PeerPort => $args{PeerPort}, bufref => \$buf };
    return bless $fh, $class;
}
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 0 };
    *main::DEBUGLOG = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");

require_ok('Slim::Player::Source')
    or BAIL_OUT("Failed to load the Slim::Player::Source stub");

require_ok('Slim::Player::Playlist')
    or BAIL_OUT("Failed to load the Slim::Player::Playlist stub");

require_ok('Slim::Networking::SimpleAsyncHTTP')
    or BAIL_OUT("Failed to load the Slim::Networking::SimpleAsyncHTTP stub");

require_ok('Plugins::SpotOn::Soloist::Control')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist::Control");

require JSON::PP;

# ------------------------------------------------------------------
# Test doubles
# ------------------------------------------------------------------

package Test::FakeDaemon;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub mac         { return $_[0]->{mac}; }
sub _ws         { return $_[0]->{ws}; }
sub _streamPort { return $_[0]->{streamPort}; }
sub uptime      { return $_[0]->{uptime} // 100; }

package Test::FakeWs;
sub new {
    my ($class, %args) = @_;
    return bless {
        connected    => ($args{connected} // 1),
        send_success => ($args{send_success} // 1),
        sent         => [],
        %args,
    }, $class;
}
sub sendCommand {
    my ($self, $cmd, %p) = @_;
    push @{ $self->{sent} }, [ $cmd, \%p ];
    return $self->{send_success};
}
sub sent { return $_[0]->{sent}; }

package main;

# fresh_control(%given) -- constructs a fresh Test::FakeDaemon + Test::FakeWs
# + Control instance. Returns ($ctl, $daemon, $ws): Control's `daemon`
# accessor is 'weak' (CR-01) -- the CALLER must keep $daemon (and,
# transitively, $ws) alive in its own scope for the duration of the test.
sub fresh_control {
    my (%given) = @_;

    my $ws = Test::FakeWs->new(
        connected    => ($given{ws_connected}  // 1),
        send_success => ($given{send_success}  // 1),
    );
    my $daemon = Test::FakeDaemon->new(
        mac        => ($given{mac} // 'aa:bb:cc:dd:ee:ff'),
        ws         => $ws,
        streamPort => ($given{streamPort} // 39755),
        uptime     => ($given{uptime} // 100),
    );

    my $ctl = Plugins::SpotOn::Soloist::Control->new(daemon => $daemon, mac => $daemon->mac);

    $ctl->mode($given{mode})         if defined $given{mode};
    $ctl->observed($given{observed}) if defined $given{observed};
    $ctl->pending($given{pending})   if defined $given{pending};
    $ctl->wanted($given{wanted})     if defined $given{wanted};

    return ($ctl, $daemon, $ws);
}

my $TID = 'spotify:track:11dFghVXANMlKmJXsNCbNl';    # same convention as t/44

# ============================================================
# Phase 82 Plan 06, Task 1: watchdogRing Runde 1 (a)-(d), Runde 2 sichtbar
# (D-02/D-03). _prefetchHangCheck's timer (Plugin.pm, unchanged) calls
# watchdogRing instead of deciding for itself -- these rows exercise the
# reconcile-driven decision, not the Plugin.pm timer plumbing (that is
# t/37's job).
# ============================================================

# --- 84-08 (SEAM-6.2): the Plugin.pm timer reaches watchdogRing through the
# backend role -- _prefetchHangCheck asks notify('watchdogRing', url =>) and
# keeps its `playlist jump +1` for any other outcome (librespot
# 'unsupported', no engine 'down'); Backend::Soloist maps the event onto
# Control's watchdogRing(url). (Behaviour cells: t/37's role harness.) ---
{
    my $slurp = sub { open(my $fh, '<', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close($fh); $t };
    my $root = $project_dir;   # 84-09: the file-scope root (was dirname(__FILE__)/.., one level too shallow after the move)
    my ($hang) = $slurp->("$root/Plugins/SpotOn/Plugin.pm") =~ /(sub _prefetchHangCheck \{.*?\n\})\n/s;
    my $hangCode = join "\n", grep { !/^\s*#/ } split /\n/, ($hang // '');
    like($hangCode, qr/->notify\('watchdogRing', url => \$triggerUrl\) eq 'ok'\) \{.*?return;\s*\}.*?\['playlist', 'jump', '\+1'\]/s,
        "84-08: _prefetchHangCheck hands the ring to notify('watchdogRing') and keeps the jump +1 fallback");
    unlike($hangCode, qr/for_client|Plugins::SpotOn::Soloist/, '84-08: _prefetchHangCheck names no player-engine class');
    like($slurp->("$root/Plugins/SpotOn/Backend/Soloist.pm"),
        qr/watchdogRing\s*=>\s*sub \{ my \(\$ctl, %a\) = \@_; \$ctl->watchdogRing\(\$a\{url\}\); \}/,
        "84-08: Backend::Soloist maps notify('watchdogRing', url =>) onto Control->watchdogRing(url)");
}

# --- round 1 (a): daemon advanced -> boundary posted again, round-2 timer
# set, no jump ---
{
    @Slim::Utils::Timers::TIMERS    = ();
    @IO::Socket::INET::CALLS        = ();
    @Slim::Player::Client::EXECUTED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:30',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:otherXYZ99', status => 'playing' },
    );

    $ctl->watchdogRing($TID);

    is(scalar(@IO::Socket::INET::CALLS), 1, "round 1 (a): daemon advanced -- boundary posted again");
    is_deeply($ws->sent, [], "round 1 (a): daemon advanced -- no command dispatched to the daemon");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "round 1 (a): daemon advanced -- no jump");
    is($ctl->observed->{watchdogReason}, 'daemon advanced to spotify:track:otherXYZ99',
        "round 1 (a): watchdogReason names the daemon's actual track");
    is(scalar(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), 1,
        "round 1 (a): round-2 timer set");
}

# --- round 1 (b): daemon still playing -> timer set, nothing sent ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:31',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->watchdogRing($TID);

    is_deeply($ws->sent, [], "round 1 (b): daemon still playing -- nothing sent");
    is($ctl->observed->{watchdogReason}, 'daemon still playing (LMS clock ahead or ring stall)',
        "round 1 (b): watchdogReason recorded");
    is(scalar(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), 1,
        "round 1 (b): round-2 timer set");
}

# --- round 1 (c): daemon paused -> ['play',{}] sent, timer set ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:32',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused' },
    );

    $ctl->watchdogRing($TID);

    is_deeply($ws->sent, [ [ 'play', {} ] ], "round 1 (c): daemon paused -- ['play',{}] sent");
    is($ctl->observed->{watchdogReason}, 'daemon idle/paused', "round 1 (c): watchdogReason recorded");
    is(scalar(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), 1,
        "round 1 (c): round-2 timer set");
}

# --- 84.2-02 round 1 (c'): D-15 -- the daemon is paused at a context end
# SpotOn already planted the boundary for (observed.contextEndPlanted eq
# the ringing uri) -> NO play (the ~10 s replay of the wrapped title from
# 0:00 is gone), reason recorded, round-2 timer still armed as the
# non-audible safety net ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:3c',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused', contextEndPlanted => $TID },
    );

    $ctl->watchdogRing($TID);

    is_deeply($ws->sent, [], "84.2-02 round 1 (c'): context end planted -- no play sent");
    is($ctl->observed->{watchdogReason}, 'context end (no successor)', "84.2-02 round 1 (c'): watchdogReason recorded");
    is(scalar(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), 1,
        "84.2-02 round 1 (c'): exactly one round-2 timer set");
}

# --- round 1 (d): ws down -> immediate round 2: jump +1 executed, exactly
# one ('warn','Soloist',qr/watchdog forced skip \(round 2: ws down\)/) ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:33',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 0, meta => {} },
    );

    $ctl->watchdogRing($TID);

    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'playlist', 'jump', '+1' ] ],
        "round 1 (d): ws down -- immediate round 2: jump +1 executed");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1,
        "round 1 (d): ws down -- exactly one recordError");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'warn', "round 1 (d): recordError level is warn");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "round 1 (d): recordError module is Soloist");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/watchdog forced skip \(round 2: ws down\)/,
        "round 1 (d): recordError message matches round 2 ws-down signature");
    ok((grep { /watchdog forced skip \(round 2: ws down\)/ } @Slim::Utils::Log::WARNINGS),
        "round 1 (d): warn logged");
}

# --- round 2: after fire_due(+10s) without resolution -> jump +1,
# recordError once, warn logged ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:34',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused' },
    );

    $ctl->watchdogRing($TID);    # round 1 (c): dispatch('play'), round-2 timer armed

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "round 2: no jump yet right after round 1");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 11);

    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'playlist', 'jump', '+1' ] ],
        "round 2: after fire_due(+10s) without resolution -- jump +1");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "round 2: recordError once");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/watchdog forced skip \(round 2: daemon idle\/paused\)/,
        "round 2: recordError message names round 1's reason");
    ok((grep { /watchdog forced skip \(round 2: daemon idle\/paused\)/ } @Slim::Utils::Log::WARNINGS),
        "round 2: warn logged");
}

# --- round 2 cancelled: requestTrack(other) before fire -> no jump, no
# recordError ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my $OTHER = 'spotify:track:otherNEW1xy';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:35',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => { $OTHER => { duration => 200 } }, track => $TID, status => 'paused' },
    );

    $ctl->watchdogRing($TID);
    ok(defined $ctl->observed->{watchdogReason},
        "round 2 cancelled: watchdogReason set after round 1");

    $ctl->requestTrack($OTHER, 0, {});

    ok(!defined $ctl->observed->{watchdogReason},
        "round 2 cancelled: requestTrack(other) clears watchdogReason");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 11);

    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "round 2 cancelled: requestTrack(other) before fire -- no jump");
    # 82-23 WR-04 (direct consequence, not a regression in this test's own
    # subject): requestTrack($OTHER) above dispatches a `play` WITH a uri
    # (unlike watchdogRing's own bare `play`), which arms a T1 timer; no
    # echo for $OTHER ever arrives in this test, so the SAME fire_due(+11)
    # call that used to only prove "no watchdog round-2 recordError" now
    # also legitimately fires T1 and writes t1:<$OTHER> -- a real,
    # independent errors[] entry, not the round-2 watchdog signature this
    # test exists to rule out. Assert on the absence of a round-2 entry
    # specifically, not on the whole ring staying empty.
    ok(!(grep { $_->[2] =~ /watchdog forced skip/ } @Plugins::SpotOn::Status::RECORDED),
        "round 2 cancelled: requestTrack(other) before fire -- no watchdog round-2 recordError");
}

# --- ring ignored when wanted.uri ne trigger (LMS already advanced) ---
{
    @Slim::Utils::Timers::TIMERS = ();
    @Slim::Player::Client::EXECUTED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:36',
        mode     => 'browse',
        wanted   => { uri => 'spotify:track:aDifferentOne99', playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->watchdogRing($TID);

    is(scalar(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), 0,
        "ring ignored when wanted.uri ne trigger (LMS already advanced) -- no round-2 timer set");
    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "ring ignored when wanted.uri ne trigger (LMS already advanced) -- no jump");
}

# --- ring ignored in mode connect ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:37',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:otherXYZ99', status => 'playing' },
    );

    $ctl->watchdogRing($TID);

    is(scalar(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), 0,
        "ring ignored in mode connect -- no round-2 timer set");
}

# --- errors dedupe: two rings same uri -> one recordError ---
{
    @Slim::Utils::Timers::TIMERS = ();
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:38',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 0, meta => {} },
    );

    $ctl->watchdogRing($TID);    # ws down -> round 2 immediately, one recordError
    $ctl->watchdogRing($TID);    # ws still down -> round 2 again, SAME uri

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1,
        "errors dedupe: two rings same uri -- one recordError");
    is_deeply(\@Slim::Player::Client::EXECUTED,
        [ [ 'playlist', 'jump', '+1' ], [ 'playlist', 'jump', '+1' ] ],
        "errors dedupe: two rings same uri -- jump still executes each round 2 (only errors[] is deduped)");
}

# ============================================================
# 83.1-03 Task 1: connect watchdog -- one rung after CONNECT_WATCHDOG_S s of
# counted silence (D-A1/D-A3), clock paused during the handshake (D-A4),
# hands over ONCE to the plan-02 ladder (_connectResync) which continues at
# the ticker's own cadence (D-A3 Nachtrag P2-B2).
# ============================================================

sub _cw_timers {
    return grep { $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 } @Slim::Utils::Timers::TIMERS;
}

my $TID2 = 'spotify:track:22eFghVXANMlKmJXsNCbNl';

# --- 83.1-03 connect watchdog (a): mode connect, _emitStart -> exactly one
# timer for _watchdogRound2 armed, connectWatchdog.uri == the emitted uri,
# no rung-1 action (ws->sent empty). ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83a',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing', is_active => 1 },
    );

    $ctl->_emitStart('11dFghVXANMlKmJXsNCbNl');

    my @timers = _cw_timers();
    is(scalar(@timers), 1, "83.1-03 connect watchdog (a): exactly one _watchdogRound2 timer armed on _emitStart");
    is($ctl->observed->{connectWatchdog}{uri}, $TID,
        "83.1-03 connect watchdog (a): connectWatchdog.uri set to the emitted uri");
    is_deeply(\@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'start', '11dFghVXANMlKmJXsNCbNl', '' ] ],
        "83.1-03 connect watchdog (a): the one execute is 'start' -- no rung 1 action");
    is_deeply($ws->sent, [], "83.1-03 connect watchdog (a): ws->sent empty (no rung 1 action)");
}

# --- 83.1-03 connect watchdog (b)/(c): 9.9s (one tick before the recorded
# deadline) -- nothing; at the deadline (10.0s) -- fires exactly once via
# _connectResync('watchdog'), writes the watchdog:<uri> errors[] entry, and
# does NOT re-arm (D-A3 Nachtrag P2-B2: one firing per incident). Uses the
# ACTUAL recorded timer deadline (not an independently-computed wall-clock
# offset) so the boundary assertion is immune to inter-call clock jitter --
# t/45's own fire_due($now) stub fires every timer with $when <= $now
# (T2/boundary: the comparison is `<=`, so firing exactly AT the recorded
# deadline is the "10.0s: due" case and one tick before it is "9.9s: not
# due"). ---
my ($sharedCtl, $sharedWs, $deadline);
{
    # NOTE: (b)/(c)/(g) share this ONE `local` scope deliberately -- (g)
    # continues on the SAME $ctl and needs the SAME playmode stub value
    # ('stop') that made (c)'s _connectResync fire in the first place.
    # `local` would otherwise revert to the default 'play' the instant this
    # block's enclosing scope ended, which made _checkSplitBrain's reset
    # branch delete the record on (g)'s very first sighting.
    local $Slim::Player::Source::PLAYMODE = 'stop';
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83bc',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing', is_active => 1 },
    );
    $sharedCtl = $ctl;
    $sharedWs  = $ws;

    $ctl->_emitStart('11dFghVXANMlKmJXsNCbNl');
    my ($timer) = _cw_timers();
    ok($timer, "83.1-03 connect watchdog (b) setup: timer armed after start");
    $deadline = $timer->[1];

    @Slim::Player::Client::EXECUTED = ();    # clear the 'start' execute -- only (c) onward matters below

    Slim::Utils::Timers::fire_due($deadline - 0.1);
    is(scalar(@Slim::Player::Client::EXECUTED), 0, "83.1-03 connect watchdog (b): 9.9s -- nothing fired");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-03 connect watchdog (b): 9.9s -- no errors[] entry");
    is_deeply($ws->sent, [], "83.1-03 connect watchdog (b): 9.9s -- nothing sent to the daemon");
    is(scalar(_cw_timers()), 1, "83.1-03 connect watchdog (b): 9.9s -- timer still armed");

    Slim::Utils::Timers::fire_due($deadline);
    is(scalar(@Slim::Player::Client::EXECUTED), 1, "83.1-03 connect watchdog (c): 10.0s -- exactly one spottyconnect execute");
    is($Slim::Player::Client::EXECUTED[0][1], 'change', "83.1-03 connect watchdog (c): the execute is a 'change'");
    ok(!(grep { $_->[0] eq 'playlist' } @Slim::Player::Client::EXECUTED),
        "83.1-03 connect watchdog (c): no playlist jump +1 in EXECUTED");
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-03 connect watchdog (c): _connectResync created the record, attempts=1");
    is($ctl->observed->{splitBrain}{reason}, 'watchdog', "83.1-03 connect watchdog (c): reason recorded as watchdog");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "83.1-03 connect watchdog (c): exactly one errors[] entry");
    like($Plugins::SpotOn::Status::RECORDED[0][3], qr/watchdog:/, "83.1-03 connect watchdog (c): errors[] key is watchdog:<uri>");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/nicht binnen 10 s wieder geoeffnet/,
        "83.1-03 connect watchdog (c): message matches the re-open-failure text");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/Versuch 1 von 2/,
        "83.1-03 connect watchdog (c): message names attempt 1 of 2");
    unlike($Plugins::SpotOn::Status::RECORDED[0][2], qr/LMS steht, Daemon spielt/,
        "83.1-03 connect watchdog (c): message does NOT claim LMS steht, Daemon spielt");
    is($ctl->observed->{connectWatchdog}, undef, "83.1-03 connect watchdog (c): connectWatchdog deleted");

    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (c): NO _watchdogRound2 timer after the fire (no re-arm)");

    Slim::Utils::Timers::fire_due($deadline + 20.0);
    Slim::Utils::Timers::fire_due($deadline + 60.0);
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-03 connect watchdog (c): attempts stays 1 -- no re-arm at +20s/+60s");
    ok(!(grep { $_->[0] eq 'pause' } @{ $ws->sent }), "83.1-03 connect watchdog (c): ws->sent contains no pause");

    # --- 83.1-03 connect watchdog (g): continuing from (c) on the SAME $ctl
    # (ONE incident, ONE shared attempts counter) -- the ladder continues at
    # the ticker's own cadence: two sightings -> attempt 2 (second
    # spottyconnect change); two more sightings -> D-05 Notausgang (pause);
    # exactly two spottyconnect change executes in total (watchdog once +
    # ticker once); no _watchdogRound2 timer at any point; no endless
    # nachziehen loop. ---
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is(scalar(@Slim::Player::Client::EXECUTED), 1,
        "83.1-03 connect watchdog (g): no new execute after only ONE ticker sighting (needs two)");

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}{attempts}, 2, "83.1-03 connect watchdog (g): attempts now 2 (ONE shared counter)");
    is(scalar(@Slim::Player::Client::EXECUTED), 2, "83.1-03 connect watchdog (g): second spottyconnect change execute");
    my ($secondEntry) = grep { defined($_->[3]) && $_->[3] =~ /split-brain:/ } @Plugins::SpotOn::Status::RECORDED;
    ok($secondEntry, "83.1-03 connect watchdog (g): split-brain:<uri> errors[] entry recorded");
    like($secondEntry->[2], qr/Versuch 2 von 2/, "83.1-03 connect watchdog (g): names attempt 2 of 2") if $secondEntry;
    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (g): still no _watchdogRound2 timer after the second nachziehen");

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });

    is_deeply($ws->sent->[-1], [ 'pause', {} ], "83.1-03 connect watchdog (g): ws sent ends with pause (Notausgang)");
    is($ctl->wanted->{playing}, 0, "83.1-03 connect watchdog (g): wanted.playing cleared to 0 (Notausgang)");
    is($ctl->observed->{splitBrain}, undef, "83.1-03 connect watchdog (g): splitBrain record deleted after the halt");
    is(scalar(@Slim::Player::Client::EXECUTED), 2,
        "83.1-03 connect watchdog (g): exactly two spottyconnect change executes in total (watchdog once + ticker once)");
    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (g): no _watchdogRound2 timer at any point");

    Slim::Utils::Timers::fire_due($deadline + 120.0);
    is(scalar(@Slim::Player::Client::EXECUTED), 2,
        "83.1-03 connect watchdog (g): fire_due(+120s) fires nothing -- no endless nachziehen loop");
}

# --- 83.1-03 connect watchdog (h): new incident -- after a watchdog fire
# (attempts==1, no timer), a daemon track_changed frame for a NEW uri
# $TID2 (foreign-track branch, no pending/expectEcho) -> Control emits
# `change` with no origin -> exactly one fresh _watchdogRound2 timer with
# connectWatchdog.uri == $TID2 (a daemon/user-driven emission for a NEW uri
# is always a new incident -- the plan-02 record resets on the uri change,
# even with a stale record for the OLD uri still present). ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83h',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'playing', is_active => 1,
            startEmittedFor => $TID,
        },
    );

    $ctl->_connectResync('watchdog');    # reach "attempts=1, no timer" -- same shape as post-(c)
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-03 connect watchdog (h) setup: one attempt recorded, no timer");
    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (h) setup: no timer after the watchdog fire");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID2 } });

    my @timers = _cw_timers();
    is(scalar(@timers), 1, "83.1-03 connect watchdog (h): exactly one fresh timer armed for the new uri");
    is($ctl->observed->{connectWatchdog}{uri}, $TID2, "83.1-03 connect watchdog (h): connectWatchdog.uri is the NEW uri");
}

# --- 83.1-03 connect watchdog (h') same-uri variant (D-A3 Nachtrag P2-B2,
# checker r3 W1): after a watchdog fire (attempts==1, splitBrain.uri ==
# $TID), a daemon-driven `change` emission (no origin) for the SAME uri
# during the open incident must NOT arm a fresh clock -- only a NEW uri
# (h above) or the ticker's own escalation may continue the incident.
# Exercised directly at the _emit arming-hook boundary (the guard this
# case protects), matching the (a)/(c) convention of calling _emit/
# _emitStart directly rather than through a full onEvent dispatch. ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83hp',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'playing', is_active => 1,
            startEmittedFor => $TID,
        },
    );

    $ctl->_connectResync('watchdog');    # attempts=1, splitBrain.uri == $TID, no timer
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-03 connect watchdog (h') setup: one attempt recorded");
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    # A daemon-driven change for the SAME uri, no origin -- the open
    # incident (splitBrain.uri eq this uri, attempts >= 1) must suppress
    # the arm.
    $ctl->_emit('change', '11dFghVXANMlKmJXsNCbNl', '');

    is(scalar(_cw_timers()), 0,
        "83.1-03 connect watchdog (h'): no _watchdogRound2 timer after a same-uri daemon change during an open incident");
    is($ctl->observed->{connectWatchdog}, undef, "83.1-03 connect watchdog (h'): connectWatchdog absent");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 20);
    is($ctl->observed->{splitBrain}{attempts}, 1,
        "83.1-03 connect watchdog (h'): attempts stays 1 -- fire_due(+10/+20) fires nothing from the watchdog");
    ok(!(grep { defined($_->[3]) && $_->[3] =~ /watchdog:\Q$TID\E$/ } @Plugins::SpotOn::Status::RECORDED),
        "83.1-03 connect watchdog (h'): no second watchdog:<uri> errors[] entry");
    ok(!(grep { $_->[0] eq 'pause' } @{ $ws->sent }),
        "83.1-03 connect watchdog (h'): ws sent no pause");
}

# --- 83.1-03 connect watchdog (d): after (a)-shaped arm, LMS confirmed the
# re-open (requestTrack for the SAME uri, source getNextTrack, still
# connect) -> timer gone, connectWatchdog deleted, mode stays connect
# (not a handoff -- the uri matches). ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83d',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing', is_active => 1 },
    );

    $ctl->_emitStart('11dFghVXANMlKmJXsNCbNl');
    is(scalar(_cw_timers()), 1, "83.1-03 connect watchdog (d) setup: timer armed after start");

    # 84.2-05: origin => 'connect' -- LMS confirmed Connect's OWN re-open (what
    # D-A1/D-A3 describe). With `status => 'playing'` the case would also pass
    # unmarked via signal (d); the key documents the producer.
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', origin => 'connect' });

    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (d): timer gone after LMS confirmed the re-open");
    is($ctl->observed->{connectWatchdog}, undef, "83.1-03 connect watchdog (d): connectWatchdog record deleted");
    is($ctl->mode, 'connect', "83.1-03 connect watchdog (d): mode stays connect (same uri -- not a handoff)");
}

# --- 84.2-05 (d2): the dormant shape -- the daemon sits PAUSED on the title,
# nothing plays, and LMS opens that same uri WITHOUT Connect's dispatch marker
# (producer P12: a user's Browse play into a dormant session). The two-signal
# same-uri rule hands over to browse and the watchdog a dormant session's
# _emitStart armed must not survive into browse. ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83e',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused', is_active => 1 },
    );

    $ctl->_emitStart('11dFghVXANMlKmJXsNCbNl');
    is(scalar(_cw_timers()), 1, "84.2-05 (d2) setup: timer armed after start");

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack' });

    is(scalar(_cw_timers()), 0, "84.2-05 (d2): timer gone after the dormant handoff");
    is($ctl->observed->{connectWatchdog}, undef, "84.2-05 (d2): connectWatchdog record deleted");
    is($ctl->mode, 'browse', "84.2-05 (d2): an unmarked LMS play of the daemon's paused title hands over to browse");
}

# --- 83.1-03 connect watchdog (e): D-A4 -- the clock pauses across a
# `_transport closed` .. `auth_state logged_in` handshake, preserving the
# remaining budget to the millisecond (never reset to the full
# CONNECT_WATCHDOG_S, never rounded to whole seconds). Time::HiRes::time is
# locally overridden for deterministic arithmetic -- a real-clock test of
# an exact millisecond value would be inherently flaky. ---
{
    @Slim::Utils::Timers::TIMERS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:83e',
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing', is_active => 1 },
    );

    my $t0 = 1_700_000_000.0;    # arbitrary fixed epoch base -- deterministic arithmetic only
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0; };
        $ctl->_emitStart('11dFghVXANMlKmJXsNCbNl');    # arms at t0, deadline = t0+10
    }

    my ($timer) = _cw_timers();
    ok($timer, "83.1-03 connect watchdog (e) setup: timer armed");
    is($timer->[1], $t0 + 10, "83.1-03 connect watchdog (e) setup: deadline is arm-time + CONNECT_WATCHDOG_S (10s)");

    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0 + 4.0; };
        $ctl->onEvent({ type => '_transport', state => 'closed' });
    }

    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (e): timer gone after transport closed");
    ok($ctl->observed->{connectWatchdog}, "83.1-03 connect watchdog (e): connectWatchdog record survives the pause");
    is($ctl->observed->{connectWatchdog}{remaining_ms}, 6000,
        "83.1-03 connect watchdog (e): remaining_ms is 6000 (10s deadline minus 4s elapsed)");
    like($ctl->observed->{connectWatchdog}{remaining_ms}, qr/^\d+$/,
        "83.1-03 connect watchdog (e): remaining_ms is an integer number of milliseconds");

    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0 + 9.0; };
        $ctl->onEvent({ type => '_transport', state => 'open' });
        $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    }

    my ($timer2) = _cw_timers();
    ok($timer2, "83.1-03 connect watchdog (e): timer present after resume");
    is($timer2->[1], $t0 + 9.0 + 6.0,
        "83.1-03 connect watchdog (e): resumed deadline == resume-time + remaining (T2/precision, not reset to the full 10s)");
    ok(!defined $ctl->observed->{connectWatchdog}{remaining_ms},
        "83.1-03 connect watchdog (e): remaining_ms cleared once resumed");

    Slim::Utils::Timers::fire_due($t0 + 14.9);
    is(scalar(_cw_timers()), 1, "83.1-03 connect watchdog (e): fire_due at t0+14.9 (one tick before) -- not yet due");

    Slim::Utils::Timers::fire_due($t0 + 15.0);
    is(scalar(_cw_timers()), 0, "83.1-03 connect watchdog (e): fire_due at t0+15.0 (9s resume + 6s remaining) -- fires");
}

# --- 84.2-REVIEW WR-01: repeat-one forced skip. A planted context end
# (Autoplay OFF), the prefetch watchdog rings before LMS re-opens, branch
# (c)-planted refuses the play and arms round 2; then LMS re-requests the
# SAME uri (repeat-one wrap, source getNextTrack) -- a new play generation.
# The still-armed round 2 must NOT fire `playlist jump +1` (~10 s into the
# replay) nor write a `watchdog forced skip` errors[] entry. ---
{
    @Slim::Utils::Timers::TIMERS       = ();
    @Slim::Player::Client::EXECUTED    = ();
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:3d',
        mode     => 'browse',
        wanted   => { uri => $TID, playing => 1 },
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => $TID,
                      status => 'paused', contextEndPlanted => $TID },
    );

    $ctl->watchdogRing($TID);    # (c)-planted: no play, round 2 armed
    is_deeply($ws->sent, [], "WR-01 setup: planted context end -- ring sends no play");
    is(scalar(grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 }
              @Slim::Utils::Timers::TIMERS), 1,
        "WR-01 setup: round-2 timer armed by the planted ring");

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack' });    # repeat-one re-request, same uri

    is(scalar(grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 }
              @Slim::Utils::Timers::TIMERS), 0,
        "WR-01: same-uri re-request after a plant kills the round-2 timer");
    ok(!defined $ctl->observed->{watchdogReason},
        "WR-01: same-uri re-request after a plant clears watchdogReason");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 11);

    ok(!(grep { $_->[0] eq 'playlist' && ($_->[1] // '') eq 'jump' } @Slim::Player::Client::EXECUTED),
        "WR-01: no playlist jump +1 into the repeat-one replay");
    ok(!(grep { $_->[2] =~ /watchdog forced skip/ } @Plugins::SpotOn::Status::RECORDED),
        "WR-01: no watchdog forced skip errors[] entry");
}

# --- 83.1-03 connect watchdog (f): every existing browse case above still
# passes unchanged -- this file's own test count simply grows with these
# new cases (no browse assertion above was touched). ---

done_testing();
