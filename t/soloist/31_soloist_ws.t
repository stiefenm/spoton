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

my $module = "$project_dir/Plugins/SpotOn/Unified/SoloistWS.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Unified/SoloistWS.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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
# LMS module stubs required to load SoloistWS.pm in isolation. Phase 82-03:
# the transport cut removed SoloistWS's own use of Slim::Utils::Prefs,
# Slim::Utils::Cache, Plugins::SpotOn::Plugin and Slim::Player::Client (all
# of that lived in the removed _emit*/_on*-session handlers) -- this file's
# stub set shrinks accordingly. This is the Transport contract net: every
# decoded frame reaches `onEvent` raw, plus the two synthesized `_transport`
# pseudo-frames; Control (t/32, t/44) owns all session semantics.
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

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
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

# Task 3: _readPort resolves the per-player data-dir through
# Plugins::SpotOn::Soloist::dataDirForClient -- stubbed under a tempdir so
# no test touches the real players/ tree.
my $data_root = tempdir(CLEANUP => 1);
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<END);
package Plugins::SpotOn::Soloist;
sub dataDirForClient {
    my (\$mac) = \@_;
    (my \$clean = \$mac || '') =~ s/://g;
    return "$data_root/\$clean";
}
1;
END

# errors[] recorder -- Task 3's connect() failure path calls
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

# CI has no XS JSON -- delegate to core JSON::PP. 73-05 (D-05): from_json uses
# ->utf8(1) so the stub mirrors production octet semantics.
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

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 0 };
    *main::DEBUGLOG = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Unified::SoloistWS')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistWS");

require JSON::PP;

# ------------------------------------------------------------------
# Minimal fake daemon (alive()/name() read by SoloistWS; mac()/_spawnTime()
# added in Task 3 for the ws.port freshness contract).
# ------------------------------------------------------------------
package Test::FakeDaemon;
sub new        { my ($class, %args) = @_; return bless { %args }, $class; }
sub alive      { return $_[0]->{alive} // 1; }
sub name       { return $_[0]->{name}; }
sub mac        { return $_[0]->{mac}; }
sub _spawnTime { return $_[0]->{_spawnTime}; }

package Test::FakeWsClient;
sub new   { return bless { writes => [] }, shift; }
sub write { my ($self, $buf) = @_; push @{ $self->{writes} }, $buf; }

package main;

sub new_ws {
    my (%args) = @_;
    my $daemon = Test::FakeDaemon->new(name => ($args{name} // 'Living Room'), alive => ($args{alive} // 1));
    return Plugins::SpotOn::Unified::SoloistWS->new(
        daemon => $daemon,
        mac    => 'aa:bb:cc:dd:ee:ff',
        port   => 45678,
    );
}

# new_ws_with_daemon(%args) -- Task 3: unlike new_ws() (which returns only
# $ws, letting the FakeDaemon's weak backref die the instant it returns),
# the ws.port freshness tests need $daemon (mac, _spawnTime) alive for the
# whole test -- returns ($ws, $daemon); the caller's scope holds the
# STRONG reference to $daemon.
sub new_ws_with_daemon {
    my (%args) = @_;
    my $daemon = Test::FakeDaemon->new(
        name       => ($args{name} // 'Living Room'),
        alive      => ($args{alive} // 1),
        mac        => ($args{mac} // 'aa:bb:cc:dd:ee:ff'),
        _spawnTime => $args{_spawnTime},
    );
    my $ws = Plugins::SpotOn::Unified::SoloistWS->new(
        daemon => $daemon,
        mac    => $daemon->mac,
        port   => ($args{port} // 45678),
    );
    return ($ws, $daemon);
}

# write_port_file($mac, $content, $mtime) -- writes $data_root/<mac>/ws.port
# with $content, then optionally backdates its mtime (utime) so
# staleness (T-77-04) is directly testable without a real spawn/respawn.
sub write_port_file {
    my ($mac, $content, $mtime) = @_;
    (my $clean = $mac) =~ s/://g;
    my $dir = "$data_root/$clean";
    make_path($dir) unless -d $dir;
    open(my $fh, '>', "$dir/ws.port") or die "cannot write ws.port: $!";
    print $fh $content;
    close($fh);
    utime($mtime, $mtime, "$dir/ws.port") if defined $mtime;
}

# ============================================================
# raw forwarding: every decoded frame type reaches onEvent, unmodified --
# the Transport contract this whole module exists to keep (82-03).
# ============================================================
{
    my @received;
    my $ws = new_ws();
    $ws->onEvent(sub { push @received, $_[0]->{type}; });

    my @frames = (
        '{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"Living Room"}',
        '{"type":"track_changed","item":{"uri":"spotify:track:abc"}}',
        '{"type":"playback_changed","status":"playing"}',
        '{"type":"position_sync","position":{"position_ms":1000,"timestamp_ms":0,"speed":1}}',
        '{"type":"playback_state","item":{"uri":"spotify:track:abc"},"status":"playing"}',
        '{"type":"volume_changed","volume":50}',
        '{"type":"device_changed","is_active":true}',
        '{"type":"command_result","command":"play"}',
        '{"type":"context_changed"}',
        '{"type":"queue_changed"}',
        '{"type":"options_changed"}',
        '{"type":"error","message":"boom"}',
    );
    $ws->_onMessage($_) for @frames;

    is_deeply(
        \@received,
        [qw(auth_state track_changed playback_changed position_sync playback_state
            volume_changed device_changed command_result context_changed queue_changed
            options_changed error)],
        "raw forwarding: every frame type reaches onEvent (auth_state, track_changed, "
        . "playback_changed, position_sync, playback_state, volume_changed, device_changed, "
        . "command_result, context_changed, queue_changed, options_changed, error)"
    );
}

# ============================================================
# no onEvent consumer: frame dropped without die
# ============================================================
{
    my $ws = new_ws();    # onEvent left unset
    ok(eval { $ws->_onMessage('{"type":"track_changed","item":{"uri":"spotify:track:abc"}}'); 1 },
        "no onEvent consumer: frame dropped without die: " . ($@ || ''));
}

# ============================================================
# error frame: warns with lastCommand and is still forwarded
# ============================================================
{
    my @received;
    my $ws = new_ws();
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->lastCommand('play');

    my @warnings;
    no warnings 'redefine';
    local *Slim::Utils::Log::warn = sub { shift; push @warnings, join('', @_); };

    $ws->_onMessage('{"type":"error","message":"boom"}');

    ok((grep { /last command 'play'/ } @warnings), "error frame: warns with lastCommand and is still forwarded");
    is(scalar(@received), 1, "error frame: is still forwarded to onEvent");
    is($received[0]{type}, 'error', "error frame: forwarded payload type is error");
}

# ============================================================
# auth_state device_name mismatch: disconnect() runs (T-73-04). WR-02
# (82-REVIEW.md, 82-12): disconnect() now reports the same `_transport
# closed` pseudo-frame _onClosed does -- this mismatch path calls
# disconnect() while the socket WAS open, so Control learns about the
# transport loss here too, same as any other disconnect() call.
# ============================================================
{
    my @received;
    # Constructed inline (not via new_ws()) so this scope holds a STRONG
    # reference to $daemon -- Control's/SoloistWS's `daemon` accessor is
    # 'weak' and would otherwise let it get garbage-collected the instant
    # new_ws() returns, silently disabling the T-73-04 name comparison.
    my $daemon = Test::FakeDaemon->new(name => 'Living Room', alive => 1);
    my $ws = Plugins::SpotOn::Unified::SoloistWS->new(daemon => $daemon, mac => 'aa:bb:cc:dd:ee:ff', port => 45678);
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->_sockOpen(1);
    $ws->connected(1);

    $ws->_onMessage('{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"Someone Else"}');

    is_deeply(\@received, [ { type => '_transport', state => 'closed' } ],
        "auth_state device_name mismatch: disconnect() now reports the transport loss (WR-02)");
    is($ws->connected, 0, "auth_state device_name mismatch: disconnect() cleared connected");
}

# ============================================================
# _onClosed forwards _transport closed once
# ============================================================
{
    my @received;
    my $ws = new_ws(alive => 0);    # alive=>0: _scheduleReconnect no-ops, no timer bookkeeping needed
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->_sockOpen(1);

    $ws->_onClosed;

    is_deeply(\@received, [ { type => '_transport', state => 'closed' } ],
        "_onClosed forwards _transport closed once");
}

# ============================================================
# 82-12 Task 3, WR-02 (82-REVIEW.md): disconnect() reports the same
# `_transport closed` pseudo-frame _onClosed does -- Control must not be
# able to tell a deliberate disconnect from a connection loss.
# ============================================================

# --- WR-02: Fall D -- disconnect() on an OPEN socket reports exactly one
# _transport closed ---
{
    my @received;
    my $ws = new_ws(alive => 0);
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->_sockOpen(1);

    $ws->disconnect;

    is_deeply(\@received, [ { type => '_transport', state => 'closed' } ],
        "WR-02: Fall D -- disconnect() forwards _transport closed once");
    is($ws->_sockOpen, 0, "WR-02: Fall D -- disconnect() clears _sockOpen");
}

# --- WR-02: Fall D (negative) -- disconnect() on a socket that was never
# open reports nothing (nothing to lose) ---
{
    my @received;
    my $ws = new_ws(alive => 0);
    $ws->onEvent(sub { push @received, $_[0]; });

    $ws->disconnect;

    is_deeply(\@received, [], "WR-02: Fall D -- disconnect() on an already-closed socket reports nothing");
}

# --- WR-02: Fall E -- disconnect() followed by _onClosed does not double-
# report; the existing _sockOpen gate in _onClosed covers both orders ---
{
    my @received;
    my $ws = new_ws(alive => 0);
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->_sockOpen(1);

    $ws->disconnect;
    $ws->_onClosed;

    is_deeply(\@received, [ { type => '_transport', state => 'closed' } ],
        "WR-02: Fall E -- disconnect() then _onClosed() reports exactly one _transport closed, not two");
}

# --- WR-02: Fall E (reverse order) -- _onClosed followed by disconnect()
# also does not double-report ---
{
    my @received;
    my $ws = new_ws(alive => 0);
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->_sockOpen(1);

    $ws->_onClosed;
    $ws->disconnect;

    is_deeply(\@received, [ { type => '_transport', state => 'closed' } ],
        "WR-02: Fall E (reverse) -- _onClosed() then disconnect() reports exactly one _transport closed, not two");
}

# ============================================================
# _onHandshakeOk forwards _transport open and resets attempts
# ============================================================
{
    my @received;
    my $ws = new_ws();
    $ws->onEvent(sub { push @received, $_[0]; });
    $ws->_attempts(5);
    $ws->_unreachableReported(1);
    $ws->reconnectDelay(16);

    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);

    $ws->_onHandshakeOk;

    is($ws->connected, 1, "_onHandshakeOk sets connected");
    is($ws->reconnectDelay, 1, "_onHandshakeOk resets reconnectDelay to RECONNECT_DELAY_MIN");
    is($ws->_attempts, 0, "_onHandshakeOk forwards _transport open and resets attempts");
    is($ws->_unreachableReported, 0, "_onHandshakeOk resets _unreachableReported");
    is_deeply($received[0], { type => '_transport', state => 'open' }, "_onHandshakeOk forwards _transport open");

    my $sent = JSON::PP->new->decode($fakeClient->{writes}[-1]);
    is($sent->{command}, 'get_auth_state', "_onHandshakeOk sends get_auth_state");
}

# ============================================================
# CR-03: _onHandshakeOk sends get_auth_state BEFORE the _transport open
# callback fires -- the Pairing-Frage must be on the wire before the
# Control-side reconcile the '_transport open' frame triggers can build on
# any state (82-11 Task 1).
# ============================================================
{
    my $ws = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);

    my $writesAtOpen;
    $ws->onEvent(sub {
        my ($msg) = @_;
        if ($msg->{type} eq '_transport' && ($msg->{state} // '') eq 'open') {
            $writesAtOpen = scalar(@{ $fakeClient->{writes} });
        }
    });

    $ws->_onHandshakeOk;

    is($writesAtOpen, 1,
        "CR-03: get_auth_state is already on the wire when the _transport open callback fires");
}

# ============================================================
# sendCommand: no pendingPlayConfirm side effect (the flag is retired)
# ============================================================
{
    my $ws = new_ws();
    ok(!$ws->can('pendingPlayConfirm'), "sendCommand: no pendingPlayConfirm side effect");
}

# ============================================================
# auth_state (no mismatch): Transport keeps a best-effort authState mirror
# for Settings/Debug -- no further action, no emission (Control owns
# semantics since 82-03).
# ============================================================
{
    my $ws = new_ws();
    $ws->_onMessage('{"type":"auth_state","logged_in":true,"is_active":false,"device_name":"Living Room"}');

    is($ws->authState->{logged_in}, 1, "auth_state updates the authState mirror: logged_in");
    is($ws->authState->{is_active}, 0, "auth_state updates the authState mirror: is_active");
    is($ws->authState->{device_name}, 'Living Room', "auth_state updates the authState mirror: device_name");
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
# sendCommand() full command-map serialization (Phase 73-02 D-06)
# ============================================================
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my @cases = (
        [ 'pause',        {},                                  { type => 'command', command => 'pause' } ],
        [ 'play',         {},                                  { type => 'command', command => 'play' } ],
        [ 'skip_next',    {},                                  { type => 'command', command => 'skip_next' } ],
        [ 'skip_prev',    {},                                  { type => 'command', command => 'skip_prev' } ],
        [ 'seek',         { position_ms => 15000 },            { type => 'command', command => 'seek', position_ms => 15000 } ],
        [ 'set_volume',   { volume => 42 },                     { type => 'command', command => 'set_volume', volume => 42 } ],
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
        is_deeply($parsed, $expected, "sendCommand('$command') serializes the expected envelope");
    }
}

# ============================================================
# T-22-01/T-73-07: an invalid uri is refused, never sent
# ============================================================
{
    my $ws         = new_ws();
    my $fakeClient = Test::FakeWsClient->new;
    $ws->_client($fakeClient);
    $ws->connected(1);

    my $ok = $ws->sendCommand('add_to_queue', uri => 'not-a-spotify-uri');
    is($ok, 0, "invalid uri is refused, never sent (T-22-01)");
    is(scalar @{ $fakeClient->{writes} }, 0, "invalid uri never reaches the wire");
}

# ============================================================
# 73-05 wire-format fixes -- inbound: the UTF-8 bridge still stands even
# though the position/session semantics that used to be asserted here moved
# to Control (t/32/t/44).
# ============================================================
{
    my @received;
    my $ws = new_ws();
    $ws->onEvent(sub { push @received, $_[0]; });

    my $item_name = "Caf\x{e9}";
    my $json_text = qq({"type":"playback_state","item":{"uri":"spotify:track:utf8test","name":"$item_name"},"position":{"position_ms":6112,"speed":1,"timestamp_ms":123},"is_active":true,"status":"playing"});
    utf8::upgrade($json_text);    # force the utf8 flag ON, matching Frame::next's Encode::decode output
    ok(utf8::is_utf8($json_text), "test setup: json_text has the utf8 flag set (character-string form)");

    ok(eval { $ws->_onMessage($json_text); 1 },
        "_onMessage on a UTF8-flagged character string does not die: " . ($@ || ''));
    is($received[0]{position}{position_ms}, 6112,
        "_onMessage on character-string input with non-ASCII metadata forwards position.position_ms intact");
}

# Regression: plain-octet input (no utf8 flag) still parses and forwards.
{
    my @received;
    my $ws = new_ws();
    $ws->onEvent(sub { push @received, $_[0]; });

    my $json_text = '{"type":"playback_state","item":{"uri":"spotify:track:octettest"},"position":{"position_ms":5000,"speed":1,"timestamp_ms":123},"is_active":true,"status":"playing"}';
    ok(!utf8::is_utf8($json_text), "test setup: json_text has no utf8 flag (plain octet form)");

    ok(eval { $ws->_onMessage($json_text); 1 },
        "_onMessage on plain-octet input does not die: " . ($@ || ''));
    is($received[0]{position}{position_ms}, 5000,
        "_onMessage on plain-octet input still forwards position.position_ms (no regression)");
}

# sendCommand(): a position_ms/volume value that arrives already stringified
# must still serialize as a bare JSON number, never a quoted string (UAT gap 2).
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
# Task 3 (T-2/T-77-04): _readPort direct unit tests -- fresh/stale/
# unparseable/missing, against a tempdir-backed dataDirForClient stub.
# ============================================================

{
    my ($ws, $daemon) = new_ws_with_daemon(mac => 'ff:ff:ff:ff:ff:03', _spawnTime => time() - 10);
    write_port_file($daemon->mac, "9999\n", time());
    is($ws->_readPort, 9999, "_readPort: fresh file with mtime >= spawnTime -> port read");
}

{
    my ($ws, $daemon) = new_ws_with_daemon(mac => 'ff:ff:ff:ff:ff:04', _spawnTime => time());
    write_port_file($daemon->mac, "9999\n", time() - 100);
    is($ws->_readPort, undef, "_readPort: stale file (utime spawnTime-100) -> undef");
}

{
    my ($ws, $daemon) = new_ws_with_daemon(mac => 'ff:ff:ff:ff:ff:05', _spawnTime => time() - 10);
    write_port_file($daemon->mac, "not-a-number\n", time());
    is($ws->_readPort, undef, "_readPort: unparseable content -> undef");
}

{
    my ($ws, $daemon) = new_ws_with_daemon(mac => 'ff:ff:ff:ff:ff:06', _spawnTime => time() - 10);
    # no ws.port file written at all for this mac
    is($ws->_readPort, undef, "_readPort: missing file -> undef");
}

# ============================================================
# Task 3: connect() refreshes the port from ws.port BEFORE dialing -- the
# constructor value (45678, unused here) is only the startup value.
# ============================================================
{
    my ($ws, $daemon) = new_ws_with_daemon(mac => 'ee:ee:ee:ee:ee:02', port => 45678, _spawnTime => time() - 10);
    write_port_file($daemon->mac, "1\n", time());    # port 1 is privileged -- connect refuses instantly

    $ws->connect;

    is($ws->port, 1, "connect refreshes port from file before dialing");
}

# ============================================================
# Task 3 (T-2): a persistent outage (reconnectDelay at RECONNECT_DELAY_MAX)
# records exactly ONE errors[] entry; a second failed attempt at the same
# delay records nothing more; _onHandshakeOk's reset re-arms the channel
# for the NEXT outage.
# ============================================================
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ws, $daemon) = new_ws_with_daemon(mac => 'dd:dd:dd:dd:dd:01', port => 1);    # no ws.port file -> port stays 1 (privileged, refused)
    $ws->reconnectDelay(30);    # RECONNECT_DELAY_MAX

    $ws->connect;

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1,
        "unreachable: reconnectDelay at RECONNECT_DELAY_MAX -> exactly one recordError");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'error', "unreachable: recorded level is 'error'");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "unreachable: recorded module is 'Soloist'");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/WS unreachable after \d+ attempts/,
        "unreachable: recorded message names the attempt count");

    $ws->reconnectDelay(30);
    $ws->connect;
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1,
        "unreachable: a second failed attempt at the same delay still records exactly one entry (dedupe)");

    $ws->_onHandshakeOk;
    is($ws->_attempts, 0, "_onHandshakeOk resets _attempts and _unreachableReported");
    is($ws->_unreachableReported, 0, "_onHandshakeOk resets _unreachableReported");

    $ws->reconnectDelay(30);
    $ws->connect;
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 2,
        "unreachable: a fresh outage after the _onHandshakeOk reset records a second, separate entry");
}

# ============================================================
# Task 3: disconnect() (explicit stop) does not touch the outage
# bookkeeping -- an intentional stop is not an unreachable daemon.
# ============================================================
{
    my ($ws) = new_ws_with_daemon(mac => 'dd:dd:dd:dd:dd:07');
    $ws->_attempts(3);
    $ws->_unreachableReported(1);

    $ws->disconnect;

    is($ws->_attempts, 3, "disconnect: does not touch _attempts");
    is($ws->_unreachableReported, 1, "disconnect: does not touch _unreachableReported");
}

done_testing();
