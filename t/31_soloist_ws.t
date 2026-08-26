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

# CI has no XS JSON -- delegate to core JSON::PP.
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
        return JSON::PP->new->decode($_[0]);
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

# use base qw(Slim::Utils::Accessor) target.
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { return bless {}, shift }
sub mk_accessor {
    my ($class, $type, @names) = @_;
    no strict 'refs';
    for my $name (@names) {
        *{"${class}::${name}"} = sub {
            my $self = shift;
            $self->{$name} = shift if @_;
            return $self->{$name};
        };
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
# Emit gate: browseSession=1 -> no spottyconnect emission (73-03 reserves this)
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    @Slim::Player::Client::EXECUTED = ();
    my $ws = new_ws();
    $ws->browseSession(1);

    $ws->_onMessage('{"type":"playback_changed","status":"paused"}');

    is_deeply(
        \@Slim::Player::Client::EXECUTED,
        [],
        "browseSession=1 gates off spottyconnect emission (73-03 reserves browse-managed sessions)"
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

done_testing();
