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
# LMS module stubs required to load SoloistWS.pm in isolation (t/28-style
# harness). IO::Socket::INET/Scalar::Util/Time::HiRes are real core
# modules and load unstubbed -- only used inside connect(), which these
# tests do not exercise (that path is the Task-3 human-check E2E).
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

# Task 3 (73-01): backed by a package hash so tests can flip
# 'enableSpotifyConnect' to cover both emit gates without a bespoke stub.
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
sub setTimer   { }
sub killTimers { }
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
sub id { return $_[0]->{mac}; }
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

# SoloistWS.pm calls Slim::Player::Client::getClient() as a fully-qualified
# function (no `use`/`require`, matching Daemon.pm/DaemonManager.pm
# convention -- the real module is always already loaded elsewhere in the
# live LMS process). The stub must be force-loaded here for the isolated
# test harness.
require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");

require_ok('Plugins::SpotOn::Unified::SoloistWS')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistWS");

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

sub new_ws {
    my $daemon = Test::FakeDaemon->new(name => 'Living Room');
    return Plugins::SpotOn::Unified::SoloistWS->new(
        daemon => $daemon,
        mac    => 'aa:bb:cc:dd:ee:ff',
        port   => 45678,
    );
}

# ============================================================
# auth_state -- updates exposed auth state, emits NO spottyconnect command
# ============================================================
{
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();

    $ws->_onMessage('{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"Living Room"}');

    is($ws->authState->{logged_in}, 1, "auth_state updates logged_in");
    is($ws->authState->{is_active}, 0, "auth_state updates is_active");
    is($ws->authState->{device_name}, 'Living Room', "auth_state updates device_name");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "auth_state emits no spottyconnect command");
}

# ============================================================
# Malformed JSON and {"type":"error",...} are logged without dying
# ============================================================
{
    my $ws = new_ws();

    ok(eval { $ws->_onMessage('{not valid json this is not even close'); 1 },
        "malformed JSON does not die: " . ($@ || ''));

    ok(eval { $ws->_onMessage('{"type":"error","message":"command requires authentication"}'); 1 },
        "error event does not die: " . ($@ || ''));
}

# ============================================================
# device_changed{is_active:true} + track_changed{...} -> spottyconnect start
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();

    $ws->_onMessage('{"type":"device_changed","is_active":true}');
    $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:abc"}}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'start', 'abc', '' ] ],
        "device_changed(active) + track_changed emits spottyconnect start"
    );
}

# ============================================================
# playback_changed: paused AND stopped both collapse to 'stop'
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();

    $ws->_onMessage('{"type":"playback_changed","status":"paused"}');
    $ws->_onMessage('{"type":"playback_changed","status":"stopped"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'stop', '', '' ], [ 'spottyconnect', 'stop', '', '' ] ],
        "playback_changed paused AND stopped both emit 'stop' (librespot collapse parity)"
    );
}

# ============================================================
# sendCommand('get_auth_state') writes the expected JSON (parsed compare)
# ============================================================
{
    my $ws = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my $ok = $ws->sendCommand('get_auth_state');
    is($ok, 1, "sendCommand() reports success when connected");

    my $sent = $fakeClient->{writes}[-1];
    ok(defined $sent, "sendCommand() wrote a frame payload");

    require JSON::PP;
    my $parsed = JSON::PP->new->decode($sent);
    is_deeply(
        $parsed,
        { type => 'command', command => 'get_auth_state' },
        "sendCommand() serializes the expected command envelope"
    );
}

# sendCommand() when not connected -- returns 0, no write attempted.
{
    my $ws = new_ws();
    is($ws->sendCommand('pause'), 0, "sendCommand() returns 0 when not connected");
}

# ============================================================
# Emit gate: enableSpotifyConnect off -> no spottyconnect emission
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 0;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();

    $ws->_onMessage('{"type":"device_changed","is_active":true}');
    $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:xyz"}}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [],
        "enableSpotifyConnect=0 gates off all spottyconnect emission"
    );
}

# ============================================================
# T-22-01: track_changed with a non-matching URI is dropped, not emitted
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();

    $ws->_onMessage('{"type":"track_changed","item":{"uri":"not-a-spotify-uri"}}');

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "track_changed with invalid URI is dropped (T-22-01)");
    is($ws->lastTrackId, undef, "lastTrackId untouched by invalid URI");
}

# ============================================================
# Phase 73-02 Task 1 (D-06): sendCommand() full command-map serialization
# ============================================================
{
    require JSON::PP;

    my @cases = (
        [ 'pause',        {},                                    { type => 'command', command => 'pause' } ],
        [ 'play',         {},                                    { type => 'command', command => 'play' } ],
        [ 'skip_next',    {},                                    { type => 'command', command => 'skip_next' } ],
        [ 'skip_prev',    {},                                    { type => 'command', command => 'skip_prev' } ],
        [ 'seek',         { position_ms => 15000 },              { type => 'command', command => 'seek', position_ms => 15000 } ],
        [ 'set_volume',   { volume => 42 },                      { type => 'command', command => 'set_volume', volume => 42 } ],
        [ 'add_to_queue', { uri => 'spotify:track:abc123' },     { type => 'command', command => 'add_to_queue', uri => 'spotify:track:abc123' } ],
        [ 'get_state',    {},                                    { type => 'command', command => 'get_state' } ],
        [ 'get_queue',    {},                                    { type => 'command', command => 'get_queue' } ],
        [ 'activate',     {},                                    { type => 'command', command => 'activate' } ],
        [ 'deactivate',   {},                                    { type => 'command', command => 'deactivate' } ],
    );

    for my $case (@cases) {
        my ($command, $params, $expected) = @$case;

        my $ws         = new_ws();
        my $fakeClient = Test::FakeWsClient->new;
        $ws->_client($fakeClient);
        $ws->connected(1);

        my $ok = $ws->sendCommand($command, %$params);
        is($ok, 1, "sendCommand('$command') reports success");

        my $parsed = JSON::PP->new->decode($fakeClient->{writes}[-1]);
        is_deeply($parsed, $expected, "sendCommand('$command') serializes the expected envelope");
    }
}

# add_to_queue with a non-track/episode URI is refused before the wire (T-22-01/T-73-07)
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my $ok = $ws->sendCommand('add_to_queue', uri => 'spotify:playlist:notallowed');
    is($ok, 0, "sendCommand('add_to_queue', uri => playlist-uri) is refused");
    is(scalar(@{ $fakeClient->{writes} }), 0, "refused command never reaches the wire");
}

# ============================================================
# Phase 73-02 Task 1 (Pitfall 6): sendRepeatMode() two-command matrix
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

# sendShuffle() serialization
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    $ws->sendShuffle(1);
    my $parsed = JSON::PP->new->decode($fakeClient->{writes}[-1]);
    is($parsed->{command}, 'set_shuffle', "sendShuffle(1) sends set_shuffle");
    is(($parsed->{enabled} ? 1 : 0), 1, "sendShuffle(1) enabled=true");

    $ws->sendShuffle(0);
    $parsed = JSON::PP->new->decode($fakeClient->{writes}[-1]);
    is(($parsed->{enabled} ? 1 : 0), 0, "sendShuffle(0) enabled=false");
}

# ============================================================
# Phase 73-02 Task 1 (D-05): reconnect resync -- logged_in auth_state
# triggers get_state
# ============================================================
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    $ws->_onMessage('{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"Living Room"}');

    my @getStateWrites = grep {
        JSON::PP->new->decode($_)->{command} eq 'get_state'
    } @{ $fakeClient->{writes} };
    is(scalar(@getStateWrites), 1, "logged_in auth_state triggers exactly one get_state request");
}

# logged_in:false auth_state does NOT trigger get_state
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    $ws->_onMessage('{"type":"auth_state","logged_in":false,"is_active":false,"device_name":"Living Room"}');

    is(scalar(@{ $fakeClient->{writes} }), 0, "logged_in:false auth_state sends no get_state request");
}

# ============================================================
# Phase 73-02 Task 1 (D-05, Pitfall 5): playback_state snapshot
# reconciliation -- position tolerance
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastTrackId('abc');
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 1);    # ~1s elapsed -> expected ~11000ms

    # Snapshot reports a position ~6s beyond the expected extrapolation -- over tolerance.
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:abc"},"position":{"position_ms":17000},"is_active":true,"status":"playing"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '17.000', '' ] ],
        "playback_state snapshot >3s off the extrapolated position emits one seek"
    );
}

{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastTrackId('abc');
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 1);    # expected ~11000ms

    # Snapshot within tolerance (~11500ms, ~0.5s over the extrapolated position).
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:abc"},"position":{"position_ms":11500},"is_active":true,"status":"playing"}');

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "playback_state snapshot within tolerance emits nothing");
}

# playback_state track-mismatch reconciliation: an active session whose
# snapshot reports a DIFFERENT track than we last knew emits 'change'
# without waiting for a track_changed event that may never re-arrive.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastTrackId('oldtrack');

    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:newtrack"},"is_active":true,"status":"playing"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'change', 'newtrack', 'oldtrack' ] ],
        "playback_state snapshot with a mismatched track emits 'change'"
    );
    is($ws->lastTrackId, 'newtrack', "lastTrackId updated to the snapshot's track");
}

# playback_state volume-mismatch reconciliation
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastVolume(30);

    $ws->_onMessage('{"type":"playback_state","volume":55,"is_active":true,"status":"playing"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'volume', 55, '' ] ],
        "playback_state snapshot with a mismatched volume emits 'volume'"
    );
}

# A cold snapshot (no prior baseline, session not yet active) never emits a
# correction -- there is nothing yet to have drifted from.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();

    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:cold"},"position":{"position_ms":9999},"volume":10,"is_active":false,"status":"stopped"}');

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "cold playback_state snapshot (no active session) emits no correction");
    is($ws->lastTrackId, 'cold', "cold snapshot still seeds lastTrackId for future reconciliation");
}

# ============================================================
# Task 1 (73-02): sendCommand() full command-map serialization -- each
# produces exactly {"type":"command","command":...} plus the documented
# extra keys, nothing more (RESEARCH Pattern 3 command table).
# ============================================================
{
    require JSON::PP;

    my $ws = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my @cases = (
        [ 'pause',        {},                                  { type => 'command', command => 'pause' } ],
        [ 'play',         {},                                  { type => 'command', command => 'play' } ],
        [ 'skip_next',    {},                                  { type => 'command', command => 'skip_next' } ],
        [ 'skip_prev',    {},                                  { type => 'command', command => 'skip_prev' } ],
        [ 'seek',         { position_ms => 12345 },            { type => 'command', command => 'seek', position_ms => 12345 } ],
        [ 'set_volume',   { volume => 50 },                     { type => 'command', command => 'set_volume', volume => 50 } ],
        [ 'add_to_queue', { uri => 'spotify:track:abc123' },    { type => 'command', command => 'add_to_queue', uri => 'spotify:track:abc123' } ],
        [ 'get_state',    {},                                  { type => 'command', command => 'get_state' } ],
        [ 'get_queue',    {},                                  { type => 'command', command => 'get_queue' } ],
        [ 'activate',     {},                                  { type => 'command', command => 'activate' } ],
        [ 'deactivate',   {},                                  { type => 'command', command => 'deactivate' } ],
    );

    for my $case (@cases) {
        my ($command, $params, $expected) = @$case;
        my $ok = $ws->sendCommand($command, %$params);
        is($ok, 1, "sendCommand('$command') reports success");

        my $parsed = JSON::PP->new->decode($fakeClient->{writes}[-1]);
        is_deeply($parsed, $expected, "sendCommand('$command') serializes exactly the expected envelope");
    }
}

# ============================================================
# Task 1 (73-02): T-22-01/T-73-07 -- an invalid uri is refused, never sent
# ============================================================
{
    my $ws = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my $ok = $ws->sendCommand('add_to_queue', uri => 'not-a-spotify-uri');
    is($ok, 0, "sendCommand('add_to_queue') with an invalid uri is refused (T-22-01)");
    is(scalar @{ $fakeClient->{writes} }, 0, "invalid uri never reaches the wire");
}

# ============================================================
# Task 1 (73-02): sendRepeatMode() two-command matrix (Pitfall 6 footnote,
# NOT the contradictory table): off=(false,false), context=(true,false),
# track=(false,true).
# ============================================================
{
    require JSON::PP;
    my %matrix = (
        off     => [0, 0],
        context => [1, 0],
        track   => [0, 1],
    );

    for my $mode (qw(off context track)) {
        my $ws = new_ws();
        my $fakeClient = Test::FakeWsClient->new;
        $ws->_client($fakeClient);
        $ws->connected(1);

        my $ok = $ws->sendRepeatMode($mode);
        is($ok, 1, "sendRepeatMode('$mode') reports success");
        is(scalar @{ $fakeClient->{writes} }, 2, "sendRepeatMode('$mode') sends exactly two commands");

        my $p1 = JSON::PP->new->decode($fakeClient->{writes}[0]);
        my $p2 = JSON::PP->new->decode($fakeClient->{writes}[1]);

        is($p1->{command}, 'set_repeat_context', "sendRepeatMode('$mode') first command is set_repeat_context");
        is($p2->{command}, 'set_repeat_track', "sendRepeatMode('$mode') second command is set_repeat_track");

        my ($wantContext, $wantTrack) = @{ $matrix{$mode} };
        is($p1->{enabled} ? 1 : 0, $wantContext, "sendRepeatMode('$mode') set_repeat_context enabled=$wantContext");
        is($p2->{enabled} ? 1 : 0, $wantTrack, "sendRepeatMode('$mode') set_repeat_track enabled=$wantTrack");
    }
}

# ============================================================
# Task 1 (73-02): reconnect resync -- auth_state{logged_in:true} triggers
# get_state; playback_state snapshot reconciliation obeys the SEEK_THRESHOLD
# tolerance (both outcomes).
# ============================================================
{
    require JSON::PP;
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;

    my $ws = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    # Pre-existing active session (as if it survived a WS drop) with a known
    # position baseline established 5s ago.
    $ws->sessionActive(1);
    $ws->lastTrackId('abc');
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 5);

    # Simulated reconnect: daemon reports an authenticated session.
    $ws->_onMessage('{"type":"auth_state","logged_in":true,"is_active":true,"device_name":"Living Room"}');

    my @sentCommands = map { JSON::PP->new->decode($_)->{command} } @{ $fakeClient->{writes} };
    ok((grep { $_ eq 'get_state' } @sentCommands), "auth_state{logged_in:true} triggers get_state (reconnect resync)");

    # Snapshot within tolerance (expected ~15000ms after 5s elapsed, actual
    # 15200ms -- 0.2s deviation) -- no seek emitted.
    @Slim::Player::Client::EXECUTED = ();
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:abc"},"position":{"position_ms":15200},"volume":50,"is_active":true,"status":"playing"}');
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "playback_state snapshot within tolerance (<=3s) emits no seek");

    # Snapshot with a large jump (>3s deviation) -- emits exactly one seek.
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 5);
    @Slim::Player::Client::EXECUTED = ();
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:abc"},"position":{"position_ms":40000},"volume":50,"is_active":true,"status":"playing"}');
    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '40.000', '' ] ],
        "playback_state snapshot beyond tolerance (>3s) emits exactly one seek"
    );
}

# ============================================================
# Phase 73-05 Task 1 (D-05/D-06): wire-format fixes -- inbound
# character-string JSON, outbound numeric params.
# ============================================================

# _onMessage fed a UTF8-flagged CHARACTER string (as the vendored
# Protocol::WebSocket::Frame::next returns -- Encode::decode('UTF-8', ...))
# containing non-ASCII item metadata parses successfully and updates
# lastPositionMs. Before the utf8::encode bridge, from_json (octet-mode,
# mirrored by the stub's ->utf8(1)->decode above) dies on this input and the
# frame is dropped -- exactly the malformed-JSON-drop bug that stalls
# lastPositionMs at its pre-pause value (UAT gap 1).
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    my $ws = new_ws();

    my $item_name = "Caf\x{e9}";
    my $json_text = qq({"type":"playback_state","item":{"uri":"spotify:track:utf8test","name":"$item_name"},"position":{"position_ms":6112,"speed":1,"timestamp_ms":123},"is_active":true,"status":"playing"});
    utf8::upgrade($json_text);    # force the utf8 flag ON, matching Frame::next's Encode::decode output
    ok(utf8::is_utf8($json_text), "test setup: json_text has the utf8 flag set (character-string form)");

    ok(eval { $ws->_onMessage($json_text); 1 },
        "_onMessage on a UTF8-flagged character string does not die: " . ($@ || ''));
    is($ws->lastPositionMs, 6112,
        "_onMessage on character-string input with non-ASCII metadata updates lastPositionMs from position.position_ms");
}

# Regression: plain-octet input (no utf8 flag -- the pre-existing test
# shape) still parses exactly as before the fix.
{
    my $ws = new_ws();
    my $json_text = '{"type":"playback_state","item":{"uri":"spotify:track:octettest"},"position":{"position_ms":5000,"speed":1,"timestamp_ms":123},"is_active":true,"status":"playing"}';
    ok(!utf8::is_utf8($json_text), "test setup: json_text has no utf8 flag (plain octet form)");

    ok(eval { $ws->_onMessage($json_text); 1 },
        "_onMessage on plain-octet input does not die: " . ($@ || ''));
    is($ws->lastPositionMs, 5000,
        "_onMessage on plain-octet input still updates lastPositionMs (no regression)");
}

# sendCommand(): a position_ms/volume value that arrives already stringified
# (e.g. threaded through a DIAG log interpolation upstream, a pure PV scalar
# with no IOK flag -- Devel::Peek-verified reproduction of the dualvar
# quoting risk JSON encoders exhibit for previously-stringified scalars)
# must still serialize as a bare JSON number, never a quoted string. The
# daemon rejects a quoted position_ms with "invalid JSON or missing
# required fields" (UAT gap 2).
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my $stringifiedPos = sprintf('%d', 145791.4);    # "145791" -- pure string, no IOK

    $ws->sendCommand('seek', position_ms => $stringifiedPos);
    my $sent = $fakeClient->{writes}[-1];
    unlike($sent, qr/"position_ms":"145791"/,
        "sendCommand('seek') does not quote a previously-stringified position_ms");
    like($sent, qr/"position_ms":145791\b/,
        "sendCommand('seek') serializes position_ms as a bare number");
}

{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my $stringifiedVol = sprintf('%d', 42);    # "42" -- pure string, no IOK

    $ws->sendCommand('set_volume', volume => $stringifiedVol);
    my $sent = $fakeClient->{writes}[-1];
    unlike($sent, qr/"volume":"42"/,
        "sendCommand('set_volume') does not quote a previously-stringified volume");
    like($sent, qr/"volume":42\b/,
        "sendCommand('set_volume') serializes volume as a bare number");
}

# ============================================================
# Phase 73-05 Task 2 (D-06, RESEARCH Pitfall 5): pause-aware position
# baseline + resume emission gating.
# ============================================================

# Sequence: baseline at 100000ms -> playback_changed('paused') -> a
# playback_state snapshot arrives WHILE paused at the unchanged pause
# position (emits no correction) -> playback_changed('playing') emits
# 'resume' with the pause-position baseline AND sends get_state for
# post-resume reconciliation (UAT gap 1: resume must not start at 0).
{
    require JSON::PP;
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;

    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    $ws->sessionActive(1);
    $ws->lastTrackId('trackpause');
    $ws->lastPositionMs(100000);
    $ws->lastPositionTs(Time::HiRes::time());

    @Slim::Player::Client::EXECUTED = ();
    $ws->_onMessage('{"type":"playback_changed","status":"paused"}');
    is($ws->sessionPaused, 1, "playback_changed(paused) sets sessionPaused");

    $fakeClient->{writes} = [];
    @Slim::Player::Client::EXECUTED = ();
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:trackpause"},"position":{"position_ms":100000,"speed":0,"timestamp_ms":1},"is_active":true,"status":"paused"}');
    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "playback_state snapshot at the unchanged pause position emits no correction");

    @Slim::Player::Client::EXECUTED = ();
    $fakeClient->{writes} = [];
    $ws->_onMessage('{"type":"playback_changed","status":"playing"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'resume', 'trackpause', '100.000' ] ],
        "playback_changed(playing) after a real pause emits resume at the pause-position baseline"
    );
    is($ws->sessionPaused, 0, "resume clears sessionPaused");

    my @sentCommands = map { JSON::PP->new->decode($_)->{command} } @{ $fakeClient->{writes} };
    ok((grep { $_ eq 'get_state' } @sentCommands),
        "resume sends a get_state command for post-resume reconciliation");
}

# While paused, a playback_state snapshot at the unchanged pause position
# arriving MORE than SEEK_THRESHOLD seconds after the pause emits NO 'seek'
# -- the wallclock extrapolation must be frozen while paused (before this
# fix, expectedMs would extrapolate forward across the paused interval and
# wrongly treat the still-paused position as a >3s drift).
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastTrackId('frozen');
    $ws->lastPositionMs(50000);
    $ws->lastPositionTs(Time::HiRes::time() - 10);    # 10s "ago" -- non-frozen extrapolation would expect ~60000ms

    $ws->_onMessage('{"type":"playback_changed","status":"paused"}');

    @Slim::Player::Client::EXECUTED = ();
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:frozen"},"position":{"position_ms":50000,"speed":0,"timestamp_ms":1},"is_active":true,"status":"paused"}');

    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "playback_state snapshot at the pause position after >SEEK_THRESHOLD elapsed emits no seek (frozen baseline while paused)");
}

# While paused, a position_sync carrying speed:0 (the daemon's own signal
# that it's paused) and a position far from the baseline -- an app-side seek
# performed while paused -- still emits 'seek' with the new position.
# sessionPaused must be derivable from the position_sync frame's speed
# field alone (no preceding playback_changed('paused') required).
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastPositionMs(50000);
    $ws->lastPositionTs(Time::HiRes::time() - 20);    # 20s "ago"

    $ws->_onMessage('{"type":"position_sync","position_ms":80000,"speed":0}');

    is($ws->sessionPaused, 1, "position_sync with speed=0 sets sessionPaused");
    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '80.000', '' ] ],
        "position_sync with speed=0 and a position far from baseline emits seek (app-side seek while paused)"
    );
}

# ============================================================
# D-02 (Phase 78): _signalBoundary trigger matrix
# track_changed -> fires; raw 'stopped' -> fires;
# 'paused' -> does NOT fire; 'stopped' during deactivation -> does NOT fire
# ============================================================
{
    # Override _signalBoundary with a counter (no actual I/O in tests).
    my $boundary_count = 0;
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::SoloistWS::_signalBoundary = sub {
        $boundary_count++;
    };

    # --- track_changed fires boundary ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
        @Slim::Player::Client::EXECUTED = ();
        $boundary_count = 0;
        my $ws = new_ws();
        $ws->_onMessage('{"type":"device_changed","is_active":true}');
        $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:abc"}}');
        is($boundary_count, 1,
            "D-02: _signalBoundary fires on track_changed");
    }

    # --- raw 'stopped' fires boundary ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
        @Slim::Player::Client::EXECUTED = ();
        $boundary_count = 0;
        my $ws = new_ws();
        $ws->_onMessage('{"type":"device_changed","is_active":true}');
        $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:abc"}}');
        $boundary_count = 0;  # reset after track_changed's boundary
        $ws->_onMessage('{"type":"playback_changed","status":"stopped"}');
        is($boundary_count, 1,
            "D-02: _signalBoundary fires on raw 'stopped' status");
    }

    # --- raw 'paused' does NOT fire boundary ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
        @Slim::Player::Client::EXECUTED = ();
        $boundary_count = 0;
        my $ws = new_ws();
        $ws->_onMessage('{"type":"device_changed","is_active":true}');
        $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:abc"}}');
        $boundary_count = 0;  # reset after track_changed's boundary
        $ws->_onMessage('{"type":"playback_changed","status":"paused"}');
        is($boundary_count, 0,
            "D-02: _signalBoundary does NOT fire on 'paused' (pause is not track end)");
    }

    # --- 'stopped' during deactivation does NOT fire boundary ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
        @Slim::Player::Client::EXECUTED = ();
        $boundary_count = 0;
        my $ws = new_ws();
        $ws->_onMessage('{"type":"device_changed","is_active":true}');
        $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:abc"}}');
        # Deactivate (transfer away)
        $ws->_onMessage('{"type":"device_changed","is_active":false}');
        $boundary_count = 0;  # reset
        $ws->_onMessage('{"type":"playback_changed","status":"stopped"}');
        is($boundary_count, 0,
            "D-02: _signalBoundary does NOT fire on 'stopped' during deactivation");
    }
}

# ============================================================
# 73-VALIDATION gap closure: sessionPaused is documented (73-05-SUMMARY.md)
# as derived from THREE independent signals -- playback_changed status,
# playback_state snapshot status, and position_sync speed. The existing
# tests above pin (1) playback_changed and (3) position_sync directly
# setting sessionPaused, but (2) a raw playback_state snapshot's own
# status field driving sessionPaused (independent of any preceding
# playback_changed) was never asserted on its own -- only observed
# indirectly through the frozen-extrapolation seek-suppression behavior.
# This closes that gap with a direct assertion on the accessor value, plus
# a convergence check that a later signal can flip it back.
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;

    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastTrackId('convtrack');
    $ws->lastPositionMs(1000);
    $ws->lastPositionTs(Time::HiRes::time());

    is($ws->sessionPaused, 0, "sessionPaused starts false on a fresh SoloistWS instance");

    # Signal 2 (playback_state snapshot status) sets sessionPaused=1 with
    # NO preceding playback_changed('paused') -- this is the un-pinned case.
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:convtrack"},"position":{"position_ms":1000,"speed":0,"timestamp_ms":1},"is_active":true,"status":"paused"}');
    is($ws->sessionPaused, 1,
        "playback_state snapshot status='paused' alone sets sessionPaused (signal 2 of 3, previously unpinned)");

    # The SAME signal source (playback_state) flips it back to 0 on the next
    # snapshot reporting status='playing' -- proves convergence is live, not
    # a one-shot latch.
    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:convtrack"},"position":{"position_ms":1000,"speed":1,"timestamp_ms":1},"is_active":true,"status":"playing"}');
    is($ws->sessionPaused, 0,
        "playback_state snapshot status='playing' clears sessionPaused (same signal source, both directions)");

    # Cross-signal convergence: position_sync (signal 3) can re-assert pause
    # after playback_state (signal 2) last cleared it -- all three signals
    # write the SAME accessor, none is authoritative-but-stale.
    $ws->_onMessage('{"type":"position_sync","position_ms":1000,"speed":0}');
    is($ws->sessionPaused, 1,
        "position_sync speed=0 (signal 3) re-asserts sessionPaused after playback_state (signal 2) last cleared it");

    # And playback_changed (signal 1) can clear what position_sync just set --
    # closes the loop across all three signal sources on one instance.
    $ws->_onMessage('{"type":"playback_changed","status":"playing"}');
    is($ws->sessionPaused, 0,
        "playback_changed status='playing' (signal 1) clears sessionPaused after position_sync (signal 3) last set it");
}

# ============================================================
# CR-S1 (Phase 77 Plan 02): _detectSeek() extraction equivalence rows --
# both call sites delegate to the same helper; behavior must be byte-for-
# byte identical to pre-refactor (PATTERNS "CR-S1 helper extraction").
# ============================================================

# Test 1: position_sync drift >SEEK_THRESHOLD emits 'seek' via _detectSeek
# (no sessionActive required at this call site -- matches pre-refactor).
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 1);    # expected ~11000ms

    $ws->_onMessage('{"type":"position_sync","position_ms":20000}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '20.000', '' ] ],
        "CR-S1: position_sync drift >SEEK_THRESHOLD emits seek via _detectSeek (no sessionActive needed)"
    );
}

# Test 2: the same deviation arriving via playback_state WITH sessionActive
# set still emits 'seek' -- same helper, same formatted position.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 1);    # expected ~11000ms

    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:crs1"},"position":{"position_ms":20000},"is_active":true,"status":"playing"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '20.000', '' ] ],
        "CR-S1: playback_state drift >SEEK_THRESHOLD with sessionActive emits seek via _detectSeek (same helper as position_sync)"
    );
}

# Test 3: guard divergence stays at the call sites, not inside _detectSeek --
# playback_state drift WITHOUT sessionActive does NOT emit; position_sync
# drift WITHOUT sessionActive DOES emit (no guard was added to that path).
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    # sessionActive intentionally left false/default.
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 1);

    $ws->_onMessage('{"type":"playback_state","item":{"uri":"spotify:track:crs1"},"position":{"position_ms":20000},"is_active":false,"status":"playing"}');
    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "CR-S1: playback_state drift without sessionActive emits nothing (call-site guard preserved)");
}
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    # sessionActive intentionally left false/default.
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 1);

    $ws->_onMessage('{"type":"position_sync","position_ms":20000}');
    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '20.000', '' ] ],
        "CR-S1: position_sync drift without sessionActive still emits seek (no guard added to this call site)"
    );
}

# Test 4: sessionPaused=true freezes the baseline inside _detectSeek --
# elapsedMs contribution is 0 regardless of large wallclock elapsed.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->sessionActive(1);
    $ws->sessionPaused(1);
    $ws->lastPositionMs(10000);
    $ws->lastPositionTs(Time::HiRes::time() - 30);   # 30s "ago" -- ignored while paused

    # Position within SEEK_THRESHOLD of the FROZEN baseline (10000ms, not the
    # ~40000ms it would extrapolate to unpaused) -- no seek.
    $ws->_onMessage('{"type":"position_sync","position_ms":10500,"speed":0}');
    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "CR-S1: sessionPaused=true freezes the baseline inside _detectSeek (elapsedMs contribution is 0)");

    # Same paused instance, but the reported position IS far from the frozen
    # baseline -- still emits, proving the frozen baseline is compared, not
    # simply suppressed.
    $ws->_onMessage('{"type":"position_sync","position_ms":50000,"speed":0}');
    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [ [ 'spottyconnect', 'seek', '50.000', '' ] ],
        "CR-S1: sessionPaused=true still emits seek when position is far from the frozen baseline"
    );
}

done_testing();
