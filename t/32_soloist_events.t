#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Unified/SoloistWS.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Unified/SoloistWS.pm not yet present in this checkout';
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
# LMS module stubs required to load SoloistWS.pm in isolation. Copied from
# t/31_soloist_ws.t's harness (73-01/73-02 convention: copy the stub set per
# test file, not a shared helper module -- matches the pre-existing t/28
# pattern). This file is the D-06 event->spottyconnect mapping regression
# net: 73-03's Browse (Model B) logic is built directly against the
# emissions this table pins -- the mapping must not change silently.
# ============================================================

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
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
sub killTimers { }
sub setTimer   { }
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

write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
our @ADD_READ;
our @REMOVE_READ;
sub addRead    { push @ADD_READ, $_[0]; }
sub removeRead { push @REMOVE_READ, $_[0]; }
1;
END

# CI has no XS JSON -- delegate to core JSON::PP. 73-05 (D-05): from_json uses
# ->utf8(1) so the stub mirrors production octet semantics (JSON::XS's
# decode_json ALWAYS expects UTF-8 octets and dies on a UTF8-flagged
# character string containing non-ASCII text -- a plain ->decode would mask
# that behavior and let a broken _onMessage pass this harness).
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

require_ok('Plugins::SpotOn::Unified::SoloistWS')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistWS");

require JSON::PP;

# ------------------------------------------------------------------
# Minimal fake daemon (only alive()/name() are read by SoloistWS).
# ------------------------------------------------------------------
package Test::FakeDaemon;
sub new  { my ($class, %args) = @_; return bless { %args }, $class; }
sub alive { return $_[0]->{alive} // 1; }
sub name  { return $_[0]->{name}; }

package Test::FakeWsClient;
sub new   { return bless { writes => [] }, shift; }
sub write { my ($self, $buf) = @_; push @{ $self->{writes} }, $buf; }

package main;

# new_ws(%seed) -- fresh SoloistWS instance, seeded with any accessor state
# the row needs (lastTrackId, lastPositionMs/Ts, sessionActive, ...) so each
# table row is independent (no leaked state between rows).
sub new_ws {
    my (%seed) = @_;

    my $daemon = Test::FakeDaemon->new(name => 'Living Room');
    my $ws = Plugins::SpotOn::Unified::SoloistWS->new(
        daemon => $daemon,
        mac    => 'aa:bb:cc:dd:ee:ff',
        port   => 45678,
    );

    for my $key (keys %seed) {
        $ws->$key($seed{$key});
    }

    return $ws;
}

# run_fixtures($ws, @json_fixtures) -- feeds each fixture through _onMessage
# in order; returns the accumulated @Slim::Player::Client::EXECUTED array.
sub run_fixtures {
    my ($ws, @fixtures) = @_;
    @Slim::Player::Client::EXECUTED = ();
    for my $fixture (@fixtures) {
        $ws->_onMessage($fixture);
    }
    return [ @Slim::Player::Client::EXECUTED ];
}

local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;

# ============================================================
# D-06 event -> spottyconnect mapping table
# ============================================================

# --- track_changed: first (None -> Some) emits 'start' ---
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"track_changed","item":{"uri":"spotify:track:tid1"}}');
    is_deeply($got, [ [ 'spottyconnect', 'start', 'tid1', '' ] ],
        "track_changed (first, no prior track) emits 'start'");
}

# --- track_changed: subsequent (Track -> Track) emits 'change' with prev id ---
{
    my $ws = new_ws(lastTrackId => 'tid1');
    my $got = run_fixtures($ws, '{"type":"track_changed","item":{"uri":"spotify:track:tid2"}}');
    is_deeply($got, [ [ 'spottyconnect', 'change', 'tid2', 'tid1' ] ],
        "track_changed (subsequent, prior track known) emits 'change' with prev id");
}

# --- track_changed: same track re-announced (newId==prevId) is a no-op ---
{
    my $ws = new_ws(lastTrackId => 'tid1', sessionStarted => 1);
    my $got = run_fixtures($ws, '{"type":"track_changed","item":{"uri":"spotify:track:tid1"}}');
    is_deeply($got, [], "track_changed re-announcing the SAME track id emits nothing (no-op, not 'change')");
    is($ws->lastTrackId, 'tid1', "lastTrackId is unchanged by the same-track re-announcement");
}

# --- playback_changed: paused -> stop (stop-collapse, librespot parity) ---
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"playback_changed","status":"paused"}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', '', '' ] ],
        "playback_changed status=paused emits 'stop'");
}

# --- playback_changed: stopped -> stop (stop-collapse, librespot parity) ---
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"playback_changed","status":"stopped"}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', '', '' ] ],
        "playback_changed status=stopped emits 'stop'");
}

# --- playback_changed: playing after a real pause (sessionPaused=1) emits
# 'resume' with position -- 73-05 (D-06 gap 1): resume is now gated on a
# real Paused->Playing transition, not emitted for every 'playing' status. ---
{
    my $ws = new_ws(lastTrackId => 'tid1', lastPositionMs => 42500, sessionPaused => 1);
    my $got = run_fixtures($ws, '{"type":"playback_changed","status":"playing"}');
    is_deeply($got, [ [ 'spottyconnect', 'resume', 'tid1', '42.500' ] ],
        "playback_changed status=playing after a real pause emits 'resume' with 3-decimal position");
    is($ws->sessionPaused, 0, "resume clears sessionPaused");
}

# --- 73-05 (D-06 gap 1): playback_changed playing with NO preceding
# paused/stopped status emits NO 'resume' -- the buffering->playing sequence
# after every track change must stay silent (track_changed start/change
# flow owns that transition; this used to spuriously fire resume at
# position 0 within ~60ms of every track change per the live UAT log). ---
{
    my $ws = new_ws(lastTrackId => 'tid1', lastPositionMs => 0);
    my $got = run_fixtures($ws, '{"type":"playback_changed","status":"playing"}');
    is_deeply($got, [], "playback_changed status=playing with no preceding pause emits no resume");
}

# --- 73-05 (D-06): playback_changed 'buffering' is a recognized no-op --
# not logged/treated as an unrecognized status, and never emits anything.
# Live-verified: the daemon sends this status between track transitions. ---
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"playback_changed","status":"buffering"}');
    is_deeply($got, [], "playback_changed status=buffering emits nothing (recognized no-op)");
}

# --- volume_changed: passthrough at both boundary values ---
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"volume_changed","volume":0}');
    is_deeply($got, [ [ 'spottyconnect', 'volume', 0, '' ] ], "volume_changed volume=0 passes through");
}
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"volume_changed","volume":100}');
    is_deeply($got, [ [ 'spottyconnect', 'volume', 100, '' ] ], "volume_changed volume=100 passes through");
}

# --- position_sync: 2s deviation -> nothing (within SEEK_THRESHOLD) ---
{
    my $ws = new_ws(lastPositionMs => 10000, lastPositionTs => Time::HiRes::time());
    my $got = run_fixtures($ws, '{"type":"position_sync","position_ms":12000}');
    is_deeply($got, [], "position_sync ~2s deviation emits nothing (within tolerance)");
}

# --- position_sync: 5s deviation -> seek with 3-decimal seconds ---
{
    my $ws = new_ws(lastPositionMs => 10000, lastPositionTs => Time::HiRes::time());
    my $got = run_fixtures($ws, '{"type":"position_sync","position_ms":15000}');
    is_deeply($got, [ [ 'spottyconnect', 'seek', '15.000', '' ] ],
        "position_sync ~5s deviation emits 'seek' with 3-decimal seconds");
}

# --- device_changed: active + track already known -> 'start' ---
{
    my $ws = new_ws(lastTrackId => 'tid9');
    my $got = run_fixtures($ws, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'start', 'tid9', '' ] ],
        "device_changed is_active=true (track known) emits 'start'");
    is($ws->sessionStarted, 1, "_emitStart sets sessionStarted after firing");
}

# --- device_changed: redundant is_active=true for already-started session ---
{
    my $ws = new_ws(lastTrackId => 'tid9', sessionStarted => 1);
    my $got = run_fixtures($ws, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'resume', '0.000', '' ] ],
        "device_changed is_active=true for an already-started session emits resume (no restart)");
}

# --- device_changed: inactive -> 'stop' (transfer away from Soloist) ---
{
    my $ws = new_ws(sessionActive => 1);
    my $got = run_fixtures($ws, '{"type":"device_changed","is_active":false}');
    is_deeply($got, [ [ 'spottyconnect', 'stop', '', '' ] ],
        "device_changed is_active=false emits 'stop'");
}

# --- auth_state: no player-state emission ---
{
    my $ws = new_ws();
    my $got = run_fixtures($ws, '{"type":"auth_state","logged_in":false,"is_active":false,"device_name":"Living Room"}');
    is_deeply($got, [], "auth_state emits no spottyconnect command");
}

# --- context_changed/options_changed/queue_changed: no emission (this plan's contract) ---
for my $type (qw(context_changed options_changed queue_changed)) {
    my $ws = new_ws();
    my $got = run_fixtures($ws, qq({"type":"$type","irrelevant":true}));
    is_deeply($got, [], "$type emits no spottyconnect command (not part of the Phase 73 core event set)");
}

# --- unknown type: no emission, no die ---
{
    my $ws = new_ws();
    my $got;
    ok(eval { $got = run_fixtures($ws, '{"type":"totally_unknown_event"}'); 1 },
        "unknown event type does not die: " . ($@ || ''));
    is_deeply($got, [], "unknown event type emits nothing");
}

# ============================================================
# Repeat matrix: sendRepeatMode's two-command matrix (Pitfall 6 footnote)
# ============================================================
{
    my @cases = (
        [ 'off',     0, 0 ],
        [ 'context', 1, 0 ],
        [ 'track',   0, 1 ],
    );

    for my $case (@cases) {
        my ($mode, $wantContext, $wantTrack) = @$case;

        my $ws         = new_ws();
        my $fakeClient = Test::FakeWsClient->new;
        $ws->_client($fakeClient);
        $ws->connected(1);

        my $ok = $ws->sendRepeatMode($mode);
        is($ok, 1, "sendRepeatMode('$mode') reports success");
        is(scalar(@{ $fakeClient->{writes} }), 2, "sendRepeatMode('$mode') emits exactly two commands");

        my $p1 = JSON::PP->new->decode($fakeClient->{writes}[0]);
        my $p2 = JSON::PP->new->decode($fakeClient->{writes}[1]);

        is($p1->{command}, 'set_repeat_context', "sendRepeatMode('$mode') first command is set_repeat_context");
        is(($p1->{enabled} ? 1 : 0), $wantContext, "sendRepeatMode('$mode') set_repeat_context enabled=$wantContext");
        is($p2->{command}, 'set_repeat_track', "sendRepeatMode('$mode') second command is set_repeat_track");
        is(($p2->{enabled} ? 1 : 0), $wantTrack, "sendRepeatMode('$mode') set_repeat_track enabled=$wantTrack");
    }
}

# ============================================================
# Gating rows
# ============================================================

# Connect toggle off -> zero emissions for a full event burst.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 0;

    my $ws  = new_ws(lastTrackId => 'tid1');
    my $got = run_fixtures(
        $ws,
        '{"type":"device_changed","is_active":true}',
        '{"type":"track_changed","item":{"uri":"spotify:track:tid2"}}',
        '{"type":"playback_changed","status":"playing"}',
        '{"type":"volume_changed","volume":50}',
        '{"type":"position_sync","position_ms":99999}',
        '{"type":"device_changed","is_active":false}',
    );

    is_deeply($got, [], "enableSpotifyConnect=0 gates off ALL spottyconnect emission for a full event burst");
}

# Malformed JSON burst -> zero emissions, zero deaths.
{
    my $ws = new_ws();
    my $got;
    ok(eval {
        $got = run_fixtures(
            $ws,
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
# Transfer-away/back position drift regression (GH debug 260827)
# ============================================================

# --- Test 1: bogus blip suppression during transfer-away ---
{
    my $ws = new_ws(
        sessionActive  => 1,
        lastTrackId    => 'tid1',
        lastPositionMs => 6111,
        sessionPaused  => 0,
        sessionStarted => 1,
    );
    my $got = run_fixtures(
        $ws,
        '{"type":"device_changed","is_active":false}',
        '{"type":"playback_changed","status":"stopped"}',
        '{"type":"playback_changed","status":"playing"}',
    );
    is_deeply($got, [ [ 'spottyconnect', 'stop', '', '' ] ],
        "transfer-away: only the device_changed stop is emitted -- the stopped/playing blips produce nothing");
    is($ws->deactivating, 1, "deactivating stays 1 after transfer-away with no re-activation");
}

# --- Test 2: re-activation position sync (re-activation with known position) ---
{
    my $ws = new_ws(
        sessionActive  => 0,
        sessionStarted => 1,
        lastTrackId    => 'tid1',
        lastPositionMs => 40000,
    );
    my $got = run_fixtures($ws, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'seek', '40.000', '' ], [ 'spottyconnect', 'resume', '40.000', '' ] ],
        "re-activation with sessionStarted=1 emits seek + resume with daemon position, no 'start'");
    is($ws->deactivating, 0, "deactivating is cleared by re-activation");
}

# --- Test 3: first activation does NOT emit seek ---
{
    my $ws = new_ws(lastTrackId => 'tid1', lastPositionMs => 5000);
    my $got = run_fixtures($ws, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'start', 'tid1', '' ] ],
        "first activation (sessionStarted=0) emits only 'start', no seek");
}

# --- Test 4: re-activation without position emits no seek ---
{
    my $ws = new_ws(sessionStarted => 1, lastTrackId => 'tid1');
    my $got = run_fixtures($ws, '{"type":"device_changed","is_active":true}');
    is_deeply($got, [ [ 'spottyconnect', 'resume', '0.000', '' ] ],
        "re-activation with sessionStarted=1 but no lastPositionMs emits resume at 0 (no seek, but still resumes)");
}

# --- Test 5: normal pause->resume unaffected by deactivation guard ---
{
    my $ws = new_ws(
        sessionActive  => 1,
        sessionStarted => 1,
        lastTrackId    => 'tid1',
        lastPositionMs => 30000,
        sessionPaused  => 1,
    );
    my $got = run_fixtures($ws, '{"type":"playback_changed","status":"playing"}');
    is_deeply($got, [ [ 'spottyconnect', 'resume', 'tid1', '30.000' ] ],
        "normal pause->resume cycle (deactivating=0) still emits 'resume' with position");
}

done_testing();
