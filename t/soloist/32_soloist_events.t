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
# LMS module stubs required to load Control.pm in isolation. Copied from
# t/44_soloist_control.t's harness (73-01/73-02/82-01 convention: copy the
# stub set per test file, not a shared helper module). Since 82-03, this
# file is the D-06 event->spottyconnect mapping table's regression net
# AGAINST Control->onEvent (was SoloistWS::_onMessage before this plan) --
# the mapping the Browse (Model B) and Connect (Phase 83) logic is built
# against must not change silently.
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

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
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
}
1;
END

# getClient() returns a recorder whose execute() pushes to a shared array
# -- this is how the tests observe spottyconnect emissions.
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
sub id { return $_[0]->{mac}; }
# 84.1-02: _lmsSongIsOurs (called unconditionally from onEvent's
# _lmsPlaysOurs preamble, D-03) reads these off the client -- load-safety
# only, same as this file's Slim::Player::Source stub note above: this
# file never exercises the ownership/playmode logic directly, so a
# permanent "no song" (undef) is correct here.
sub streamingSong { return undef; }
sub playingSong    { return undef; }
1;
END

# IN-03 (82-REVIEW.md, 82-10 Task 3): Control.pm now `use`s
# Slim::Player::Source and Slim::Player::Playlist explicitly (previously
# implicit, relying on the LMS core having already loaded them). This
# file requires the REAL Control.pm (unlike t/29/t/37's Control stubs) but
# never stubbed either module -- exactly the "another file kippt" case
# IN-03's fix names. Minimal stubs, same shape as t/44/t/45's: this file
# never exercises requestPause/requestResume/requestVolume/playmode
# directly, so only load-safety is needed here, not controllable playmode
# state.
write_stub($stub_dir, 'Slim::Player::Source', <<'END');
package Slim::Player::Source;
sub playmode { return 'play'; }
sub songTime { return 0; }
sub streamingSongIndex { return 0; }
sub playingSongIndex   { return 0; }
1;
END

write_stub($stub_dir, 'Slim::Player::Playlist', <<'END');
package Slim::Player::Playlist;
sub song  { return undef; }
sub count { return 0; }
1;
END

# Counts /boundary POSTs by PeerPort and hands back an in-memory filehandle
# (blessed glob) so `print $sock ...; close($sock);` in Control::onEvent's
# boundary path never touches a real socket (82-01 convention, t/44).
write_stub($stub_dir, 'IO::Socket::INET', <<'END');
package IO::Socket::INET;
our @CALLS;
sub new {
    my ($class, %args) = @_;
    push @CALLS, $args{PeerPort};
    open(my $fh, '>', \my $buf) or return undef;
    return bless $fh, $class;
}
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 0 };
    *main::DEBUGLOG = sub () { 0 };
}

# use base qw(Slim::Utils::Accessor) target. Array-based (blessed ARRAY refs,
# not hashes) to match the REAL Slim::Utils::Accessor contract -- CR-01: a
# hash-based stub previously masked a hash-deref-on-array-ref production bug
# that only this object shape would have caught.
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

unshift @INC, $stub_dir, $project_dir;

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");

require_ok('Slim::Player::Source')
    or BAIL_OUT("Failed to load the Slim::Player::Source stub");

require_ok('Slim::Player::Playlist')
    or BAIL_OUT("Failed to load the Slim::Player::Playlist stub");

require_ok('Plugins::SpotOn::Soloist::Control')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist::Control");

require JSON::PP;

# ------------------------------------------------------------------
# Test doubles (t/44 convention)
# ------------------------------------------------------------------

package Test::FakeDaemon;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub mac         { return $_[0]->{mac}; }
sub _ws         { return $_[0]->{ws}; }
sub _streamPort { return $_[0]->{streamPort}; }

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

# new_control(%seed) -- fresh Test::FakeDaemon + Test::FakeWs + Control
# instance, seeded with mode/observed/wanted/pending as each row needs (so
# each table row is independent -- no leaked state between rows). Returns
# ($ctl, $daemon, $ws): Control's `daemon` accessor is 'weak' (mirrors
# SoloistWS.pm CR-01) -- the CALLER must keep $daemon (and transitively
# $ws) alive in its own scope for the duration of the test.
sub new_control {
    my (%seed) = @_;

    my $ws = Test::FakeWs->new(
        connected    => ($seed{ws_connected}  // 1),
        send_success => ($seed{send_success}  // 1),
    );
    my $daemon = Test::FakeDaemon->new(
        mac        => ($seed{mac} // 'aa:bb:cc:dd:ee:ff'),
        ws         => $ws,
        streamPort => ($seed{stream_port} // 0),
    );

    my $ctl = Plugins::SpotOn::Soloist::Control->new(daemon => $daemon, mac => $daemon->mac);

    $ctl->mode($seed{mode}) if defined $seed{mode};
    if ($seed{observed}) {
        $ctl->observed({ %{ $ctl->observed }, %{ $seed{observed} } });
    }
    $ctl->wanted($seed{wanted})   if defined $seed{wanted};
    $ctl->pending($seed{pending}) if defined $seed{pending};

    return ($ctl, $daemon, $ws);
}

# run_fixtures($ctl, @json_fixtures) -- decodes each raw wire-frame string
# and feeds it through onEvent in order (this is Control's contract: it
# takes already-decoded HASHes, SoloistWS's _onMessage does the JSON
# decoding -- Task 2). A frame that fails to decode to a HASH is silently
# skipped, matching the transport's own tolerant forwarding contract.
# Returns the accumulated @Slim::Player::Client::EXECUTED array.
sub run_fixtures {
    my ($ctl, @fixtures) = @_;
    @Slim::Player::Client::EXECUTED = ();
    for my $fixture (@fixtures) {
        my $decoded = eval { JSON::PP->new->utf8(1)->decode($fixture) };
        next unless ref($decoded) eq 'HASH';
        $ctl->onEvent($decoded);
    }
    return [ @Slim::Player::Client::EXECUTED ];
}

sub decode_frame {
    my ($text) = @_;
    return JSON::PP->new->utf8(1)->decode($text);
}

# load_fixture($name) -- 81-02 (D-15 fixture convention, t/fixtures/soloist/
# README.md): reads t/fixtures/soloist/$name from disk. $name carries its
# own extension so both fixture forms work through the same loader. A
# ".json" file is a single raw wire frame -- returns its trimmed text,
# ready to feed straight into run_fixtures(). A ".jsonl" file is a
# time-ordered spike recording -- returns the list of all non-"#"-comment
# lines (raw frame text), in order. Dies loudly if the fixture is absent:
# a silently-skipped fixture would let test coverage regress unnoticed.
sub load_fixture {
    my ($name) = @_;
    my $path = "$project_dir/t/fixtures/soloist/$name";
    open(my $fh, '<', $path) or die "fixture $name missing";
    binmode($fh);
    my @lines = <$fh>;
    close($fh);
    chomp @lines;
    if ($name =~ /\.jsonl$/) {
        return grep { defined($_) && length($_) && $_ !~ /^#/ } @lines;
    }
    my $text = join('', @lines);
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;

# ============================================================
# D-06 event -> spottyconnect mapping table, now against Control->onEvent
# (since 82-03; SoloistWS before that). Every row that expects an emission
# seeds mode => 'connect' -- Prinzip 3.1(3): mode is policy, and only a
# connect session may ever reach Connect.pm.
# ============================================================

# --- track_changed: first (no prior track) emits 'start' ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $got = run_fixtures($ctl, '{"type":"track_changed","item":{"uri":"spotify:track:tid1"}}');
    is_deeply($got, [ [ 'spottyconnect', 'start', 'tid1', '' ] ],
        "track_changed (first, no prior track) emits 'start'");
}

# --- track_changed: subsequent (Track -> Track) emits 'change' with prev id ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { track => 'spotify:track:tid1', startEmittedFor => 'spotify:track:tid1' });
    my $got = run_fixtures($ctl, '{"type":"track_changed","item":{"uri":"spotify:track:tid2"}}');
    is_deeply($got, [ [ 'spottyconnect', 'change', 'tid2', 'tid1' ] ],
        "track_changed (subsequent, prior track known) emits 'change' with prev id");
}

# --- track_changed: same track re-announced (newId==prevId) is a no-op,
# but observed.status is still updated to 'playing' (82-03 addition). ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { track => 'spotify:track:tid1', startEmittedFor => 'spotify:track:tid1' });
    my $got = run_fixtures($ctl, '{"type":"track_changed","item":{"uri":"spotify:track:tid1"}}');
    is_deeply($got, [], "track_changed re-announcing the SAME track id emits nothing (no-op, not 'change')");
    is($ctl->observed->{track}, 'spotify:track:tid1', "observed.track is unchanged by the same-track re-announcement");
    is($ctl->observed->{status}, 'playing', "observed.status is set to playing by the same-track re-announcement");
}

# --- playback_changed: paused -> stop (stop-collapse, librespot parity) ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1, status => 'playing' });
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"paused"}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', '', '' ] ],
        "playback_changed status=paused emits 'stop'");
}

# --- playback_changed: stopped -> stop (stop-collapse, librespot parity) ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1, status => 'playing' });
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"stopped"}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', '', '' ] ],
        "playback_changed status=stopped emits 'stop'");
}

# --- playback_changed: playing after a real pause (prior status paused)
# emits 'resume' with position -- 73-05 (D-06 gap 1). ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect',
        observed => { is_active => 1, track => 'spotify:track:tid1', status => 'paused', anchor => { position_ms => 42500 } });
    # 79-51 runaway D1: the resume is released by the frame that decides it -- here the same-title playback_state that
    # follows the playing frame (E3); the contract (one resume tid1 42.500, one get_state) is unchanged.
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"playing"}',
        '{"type":"playback_state","status":"playing","item":{"uri":"spotify:track:tid1"}}');
    is_deeply($got, [ [ 'spottyconnect', 'resume', 'tid1', '42.500' ] ],
        "playback_changed status=playing after a real pause emits 'resume' with 3-decimal position");
    is_deeply($ws->sent, [ [ 'get_state', {} ] ],
        "playback_changed resume sends get_state for post-resume reconciliation");
}

# --- 73-05 (D-06 gap 1): playback_changed playing with NO preceding
# paused/stopped status emits NO 'resume'. ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1, track => 'spotify:track:tid1' });
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"playing"}');
    is_deeply($got, [], "playback_changed status=playing with no preceding pause emits no resume");
}

# --- 73-05 (D-06): playback_changed 'buffering' is a recognized no-op. ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1 });
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"buffering"}');
    is_deeply($got, [], "playback_changed status=buffering emits nothing (recognized no-op)");
}

# --- volume_changed: passthrough at both boundary values (live delta,
# unconditional in connect -- not a snapshot-mismatch check). ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $got = run_fixtures($ctl, '{"type":"volume_changed","volume":0}');
    is_deeply($got, [ [ 'spottyconnect', 'volume', 0, '' ] ], "volume_changed volume=0 passes through");
}
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $got = run_fixtures($ctl, '{"type":"volume_changed","volume":100}');
    is_deeply($got, [ [ 'spottyconnect', 'volume', 100, '' ] ], "volume_changed volume=100 passes through");
}

# --- position_sync (NESTED form -- the daemon never sends the flat form):
# 2s deviation -> nothing (within SEEK_THRESHOLD) ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { anchor => { position_ms => 10000, seen_at => time() } });
    my $got = run_fixtures($ctl, '{"type":"position_sync","position":{"position_ms":12000,"timestamp_ms":0,"speed":1}}');
    is_deeply($got, [], "position_sync ~2s deviation emits nothing (within tolerance)");
}

# --- position_sync (NESTED form): 5s deviation -> seek with 3-decimal seconds ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { anchor => { position_ms => 10000, seen_at => time() } });
    my $got = run_fixtures($ctl, '{"type":"position_sync","position":{"position_ms":15000,"timestamp_ms":0,"speed":1}}');
    is_deeply($got, [ [ 'spottyconnect', 'seek', '15.000', '' ] ],
        "position_sync ~5s deviation emits 'seek' with 3-decimal seconds");
}

# --- 84-02 (cluster 4, D-21): a frozen daemon position is not an app-side seek.
# The daemon reports position 0:00 / the entry position for minutes while
# LMS' own stream keeps running (fakepulse-timing-buffer.md "uncork delay";
# live 2026-09-30 11:40:49.0975: a playback_state answer to get_state carried
# 0.13 s 8.9 s after the title began -> `seek 0.0` -> startOffset -7.33, the
# LMS clock jumped back 7.3 s for the rest of the title; l2-proof run 11:04:41
# and 11:05:41: 45.1 s repeated every 60 s). A frame that repeats the prior
# anchor's own raw position while the rebased expectation has moved on is that
# stale report, not a seek; a genuine app seek differs from the anchor.
# F-a  (RED pre-fix)   position_sync == anchor raw position, anchor 10 s old -> no seek
# F-a2 (RED pre-fix)   the same through a playback_state frame
# F-b  (guard only)    position_sync far from the anchor and the expectation -> seek
# F-c  (guard only)    position_sync equal to the anchor while the anchor is FRESH -> nothing (as before)
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect',
        observed => { status => 'playing', anchor => { position_ms => 45100, seen_at => time() - 10 } });
    my $got = run_fixtures($ctl, '{"type":"position_sync","position":{"position_ms":45100,"timestamp_ms":0,"speed":1}}');
    is_deeply($got, [], "84-02 F-a: position_sync repeating the anchor's raw position after 10 s emits no seek (frozen daemon report)");
}
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect',
        observed => { status => 'playing', track => 'spotify:track:tid1', is_active => 1, startEmittedFor => 'spotify:track:tid1',
                      anchor => { position_ms => 130, seen_at => time() - 7.5 } });
    my $got = run_fixtures($ctl, '{"type":"playback_state","status":"playing","is_active":true,"item":{"uri":"spotify:track:tid1"},"position":{"position_ms":130,"timestamp_ms":0,"speed":1}}');
    is_deeply([ grep { $_->[1] eq 'seek' } @$got ], [],
        "84-02 F-a2: playback_state repeating the anchor's raw position (0.13 s) after 7.5 s emits no seek");
}
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect',
        observed => { status => 'playing', anchor => { position_ms => 45100, seen_at => time() - 10 } });
    my $got = run_fixtures($ctl, '{"type":"position_sync","position":{"position_ms":12000,"timestamp_ms":0,"speed":1}}');
    is_deeply($got, [ [ 'spottyconnect', 'seek', '12.000', '' ] ],
        "84-02 F-b (guard only): a position_sync far from both the anchor and the expectation still emits seek");
}
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect',
        observed => { status => 'playing', anchor => { position_ms => 45100, seen_at => time() } });
    my $got = run_fixtures($ctl, '{"type":"position_sync","position":{"position_ms":45100,"timestamp_ms":0,"speed":1}}');
    is_deeply($got, [], "84-02 F-c (guard only): position_sync equal to a fresh anchor emits nothing (within tolerance, as before)");
}

# --- device_changed: active + track already known (first activation from
# idle, no prior session) -> 'start' ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'idle', observed => { track => 'spotify:track:tid9' });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'start', 'tid9', '' ] ],
        "device_changed is_active=true (track known, first activation) emits 'start'");
    is($ctl->mode, 'connect', "device_changed is_active=true transfers idle -> connect");
    is($ctl->observed->{startEmittedFor}, 'spotify:track:tid9', "_emitStart sets startEmittedFor after firing");
}

# --- device_changed: redundant is_active=true for an already-started
# session (startEmittedFor set, but no position) emits resume at 0. ---
# Bugfix (getnexttrack-url-seek-position, 2026-09-22): this assertion used
# to encode the bug itself -- 'resume' with the position in the trackId
# slot (p2) and an empty position slot (p3). Corrected to match the
# receiver contract in Connect.pm's resume handler (_p2=trackId,
# _p3=position) and the sibling playback_changed 'resume' call/test above
# (line ~412: [ 'spottyconnect', 'resume', 'tid1', '42.500' ]).
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'idle', observed => { track => 'spotify:track:tid9', startEmittedFor => 'spotify:track:tid9' });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'resume', 'tid9', '0.000' ] ],
        "device_changed is_active=true for an already-started session emits resume with the track ID (not the position) in p2, no restart, no seek");
}

# --- device_changed: re-activation with a known position emits seek+resume,
# no 'start' (transfer-away/back position drift regression, GH 260827). ---
# Bugfix (getnexttrack-url-seek-position, 2026-09-22): see note above --
# resume's p2 must carry the track ID, not the position.
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'idle',
        observed => { track => 'spotify:track:tid1', startEmittedFor => 'spotify:track:tid1', anchor => { position_ms => 40000 } });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'seek', '40.000', '' ], [ 'spottyconnect', 'resume', 'tid1', '40.000' ] ],
        "re-activation with a known position emits seek + resume with track ID in p2 and daemon position in p3, no 'start'");
}

# --- device_changed: re-activation where the track ID cannot be parsed from
# observed.track (malformed/missing URI) -- resume must still carry an
# EMPTY track-ID slot, never let the position drift into it (regression
# guard: this is the exact defect getnexttrack-url-seek-position found --
# a missing/unparseable track ID must not silently become the position
# value in p2). ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'idle',
        observed => { track => undef, startEmittedFor => 'spotify:track:tid1', anchor => { position_ms => 40000 } });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'seek', '40.000', '' ], [ 'spottyconnect', 'resume', '', '40.000' ] ],
        "re-activation with no parseable track ID emits resume with an EMPTY p2, never the position value");
}

# --- device_changed: inactive -> session-end-marked 'stop' (transfer away,
# GH #151), only when mode was connect. ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1 });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":false}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', 'inactive', '' ] ],
        "device_changed is_active=false emits 'stop' with the 'inactive' session-end marker (GH #151)");
    is($ctl->mode, 'idle', "device_changed is_active=false transfers connect -> idle");
}

# --- auth_state: no player-state emission, but a logged_in snapshot
# dispatches exactly one get_state (73-02 D-05 reconnect resync). ---
{
    my ($ctl, $daemon, $ws) = new_control();
    my $got = run_fixtures($ctl, '{"type":"auth_state","logged_in":false,"is_active":false,"device_name":"Living Room"}');
    is_deeply($got, [], "auth_state logged_in=false emits no spottyconnect command");
    is_deeply($ws->sent, [], "auth_state logged_in=false sends no get_state");
}
{
    my ($ctl, $daemon, $ws) = new_control();
    my $got = run_fixtures($ctl, '{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"Living Room"}');
    is_deeply($got, [], "auth_state logged_in=true emits no spottyconnect command");
    is_deeply($ws->sent, [ [ 'get_state', {} ] ], "auth_state logged_in=true sent [['get_state',{}]]");
}

# --- context_changed/options_changed/queue_changed: no emission (this
# plan's contract -- unchanged since 82-01). ---
for my $type (qw(context_changed options_changed queue_changed)) {
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $got = run_fixtures($ctl, qq({"type":"$type","irrelevant":true}));
    is_deeply($got, [], "$type emits no spottyconnect command (not part of the core event set)");
}

# --- unknown type: no emission, no die ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $got;
    ok(eval { $got = run_fixtures($ctl, '{"type":"totally_unknown_event"}'); 1 },
        "unknown event type does not die: " . ($@ || ''));
    is_deeply($got, [], "unknown event type emits nothing");
}

# ============================================================
# Gating rows
# ============================================================

# Connect toggle off -> zero emissions for a full event burst, even in connect.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 0;

    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1, track => 'spotify:track:tid1', status => 'paused', anchor => { position_ms => 1000, seen_at => time() } });
    my $got = run_fixtures(
        $ctl,
        '{"type":"track_changed","item":{"uri":"spotify:track:tid2"}}',
        '{"type":"playback_changed","status":"playing"}',
        '{"type":"volume_changed","volume":50}',
        '{"type":"position_sync","position":{"position_ms":99999,"timestamp_ms":0,"speed":1}}',
        '{"type":"device_changed","is_active":false}',
    );

    is_deeply($got, [], "enableSpotifyConnect=0 gates off ALL spottyconnect emission for a full event burst");
}

# Malformed JSON burst -> zero emissions, zero deaths.
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $got;
    ok(eval {
        $got = run_fixtures(
            $ctl,
            '{not valid json at all',
            '{"type":',
            '[]',
            'null',
            '',
            '{"type":"track_changed","item":{"uri":"not-a-spotify-uri"}}',
        );
        1;
    }, "malformed JSON burst does not die: " . ($@ || ''));
    is_deeply($got, [], "malformed JSON burst emits nothing");
}

# ============================================================
# 82-03 mode-table rows: the seven Browse/Connect/Transfer rows the plan
# mandates, replacing the retired soloistBrowseActive Browse-Gate-Block.
# ============================================================

# --- mode browse: track_changed foreign -> emitted [], boundary 1 ---
{
    @IO::Socket::INET::CALLS = ();
    my ($ctl, $daemon, $ws) = new_control(mode => 'browse', stream_port => 39755);
    my $got = run_fixtures($ctl, '{"type":"track_changed","item":{"uri":"spotify:track:tid1"}}');
    is_deeply($got, [], "mode browse: track_changed foreign -> emitted [], boundary 1");
    is(scalar(@IO::Socket::INET::CALLS), 1, "mode browse: track_changed plants exactly one boundary");
    is($ctl->observed->{track}, 'spotify:track:tid1', "mode browse: observed.track still updates");
}

# --- mode browse: playback_changed paused -> emitted [] ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'browse', observed => { is_active => 1, status => 'playing', track => 'spotify:track:tid1' });
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"paused"}');
    is_deeply($got, [], "mode browse: playback_changed paused -> emitted []");
    is($ctl->observed->{status}, 'paused', "mode browse: observed.status still updates");
}

# --- mode browse: playback_state is_active true -> mode stays browse, emitted [] ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'browse');
    my $got = run_fixtures($ctl,
        '{"type":"playback_state","item":{"uri":"spotify:track:tidX"},"status":"playing","is_active":true}');
    is_deeply($got, [], "mode browse: playback_state is_active true -> mode stays browse, emitted []");
    is($ctl->mode, 'browse', "mode browse: playback_state does not switch mode (only device_changed transfers, Prinzip Transfer)");
}

# --- mode browse: device_changed is_active true -> mode connect, emitted [start ...] ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'browse', observed => { track => 'spotify:track:tid7' });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'start', 'tid7', '' ] ],
        "mode browse: device_changed is_active true -> mode connect, emitted [start ...]");
    is($ctl->mode, 'connect', "mode browse: device_changed is_active true transfers browse -> connect");
}

# --- mode connect: device_changed is_active false -> emitted [stop inactive], mode idle ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect', observed => { is_active => 1 });
    my $got = run_fixtures($ctl, '{"type":"device_changed","is_active":false}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', 'inactive', '' ] ],
        "mode connect: device_changed is_active false -> emitted [stop inactive], mode idle");
    is($ctl->mode, 'idle', "mode connect: device_changed is_active false transfers connect -> idle");
}

# --- mode idle after transfer-away: playback_changed playing -> emitted []
# (blip) -- the daemon sends a bogus stopped->playing straggler mid-
# transfer-away; the idle+!is_active blip rule swallows it. ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'idle', observed => { is_active => 0 });
    my $got = run_fixtures($ctl, '{"type":"playback_changed","status":"playing"}');
    is_deeply($got, [], "mode idle after transfer-away: playback_changed playing -> emitted [] (blip)");
    is($ctl->observed->{status}, 'playing', "mode idle after transfer-away: observed.status is still recorded");
}

# --- transport closed then playback_state snapshot in connect -> change,
# not start (T-1 flagged assumption: mode/startEmittedFor survive
# _transportClosed, so the reconnect snapshot must not re-announce 'start'). ---
{
    my ($ctl, $daemon, $ws) = new_control(mode => 'connect',
        observed => { track => 'spotify:track:oldid', startEmittedFor => 'spotify:track:oldid', status => 'playing', is_active => 1 });

    run_fixtures($ctl, '{"type":"_transport","state":"closed"}');
    is($ctl->mode, 'connect', "transport closed: mode survives the transport loss");
    is($ctl->observed->{startEmittedFor}, 'spotify:track:oldid', "transport closed: startEmittedFor survives the transport loss");
    is($ctl->observed->{track}, undef, "transport closed: observed.track is cleared");

    my $got = run_fixtures($ctl,
        '{"type":"playback_state","item":{"uri":"spotify:track:newid"},"status":"playing","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'change', 'newid', 'oldid' ] ],
        "transport closed then playback_state snapshot in connect -> change, not start");
}

# ============================================================
# 81-02 (D-15 fixture acceptance): fixtures loaded from disk via
# load_fixture(), fed through onEvent, plus a redaction test over the whole
# t/fixtures/soloist/ directory (T-81-06). Additive only.
# ============================================================

# --- auth_state.json (paired, logged_in:true) through onEvent: no die, and
# the fields onEvent is documented to set. ---
{
    my ($ctl, $daemon, $ws) = new_control();
    my $fixture = load_fixture('auth_state.json');
    my $ok = eval { run_fixtures($ctl, $fixture); 1 };
    ok($ok, "fixture auth_state.json: onEvent does not die") or diag($@);
    is($ctl->observed->{logged_in}, 1, "fixture auth_state.json: onEvent sets observed.logged_in");
    is($ctl->observed->{paired}, 1, "fixture auth_state.json: onEvent sets observed.paired");
    is_deeply($ws->sent, [ [ 'get_state', {} ] ], "fixture auth_state.json: logged_in:true dispatches get_state");
}

# --- error.json ("command requires authentication") through onEvent: no
# die, no spottyconnect emission, and exactly one errors[] entry. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $fixture = load_fixture('error.json');
    my $got = eval { run_fixtures($ctl, $fixture) };
    ok(!$@, "fixture error.json: onEvent does not die") or diag($@);
    is_deeply($got, [], "fixture error.json: no spottyconnect command is executed");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "fixture error.json: exactly one errors[] entry recorded");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/not paired/, "fixture error.json: recorded message mentions 'not paired'");
}

# --- Every line from the S-01 "pure daemon" spike recordings (81-01), in
# order, through onEvent: well-formed wire frames, no die. No assertion on
# which (if any) spottyconnect commands fall out of any given line -- that
# mapping is 82/83's Neufassung, not this plan's concern (prohibition 3). ---
for my $jsonl (qw(s01-pure-daemon-play.jsonl s01-pure-daemon-queue.jsonl)) {
    my @lines = load_fixture($jsonl);
    ok(scalar(@lines) > 0, "fixture $jsonl: at least one frame line loaded");

    my ($ctl, $daemon, $ws) = new_control(mode => 'connect');
    my $i = 0;
    for my $line (@lines) {
        $i++;
        like($line, qr/^\{"type":"/, "fixture $jsonl line $i is a well-formed wire frame");
        my $ok = eval {
            my $decoded = decode_frame($line);
            $ctl->onEvent($decoded) if ref($decoded) eq 'HASH';
            1;
        };
        ok($ok, "fixture $jsonl line $i does not die through onEvent") or diag($@);
    }
}

# --- Redaction (T-81-06): no fixture file may carry the soloist app key
# or a session auth payload. Iterates the directory itself (opendir, not a
# hand-written file list) so any fixture added later is covered for free. ---
{
    my $fixture_dir = "$project_dir/t/fixtures/soloist";
    opendir(my $dh, $fixture_dir) or die "cannot open $fixture_dir: $!";
    my @files = grep { $_ ne '.' && $_ ne '..' && -f "$fixture_dir/$_" } readdir($dh);
    closedir($dh);
    ok(scalar(@files) > 0, "fixture redaction: at least one file found in t/fixtures/soloist/");
    for my $file (sort @files) {
        open(my $fh, '<', "$fixture_dir/$file") or die "cannot open $fixture_dir/$file: $!";
        binmode($fh);
        local $/;
        my $raw = <$fh>;
        close($fh);
        unlike($raw, qr/auth_data/, "fixture redaction: $file does not contain 'auth_data'");
        unlike($raw, qr/spak_/,     "fixture redaction: $file does not contain 'spak_'");
        unlike($raw, qr/Bearer /,   "fixture redaction: $file does not contain 'Bearer '");
    }
}

# --- README.md documents the daemon version every fixture was captured against. ---
{
    my $readme_path = "$project_dir/t/fixtures/soloist/README.md";
    ok(-f $readme_path, "fixture redaction: t/fixtures/soloist/README.md exists");
    open(my $fh, '<', $readme_path) or die "cannot open $readme_path: $!";
    local $/;
    my $readme = <$fh>;
    close($fh);
    like($readme, qr/1\.3\.7\.489/, "fixture redaction: README.md names the daemon version 1.3.7.489");
}

done_testing();
