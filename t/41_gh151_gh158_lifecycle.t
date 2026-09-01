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
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Connect.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Connect.pm not present in this checkout';
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
    return 1;
}
sub notifyFromArray { }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $UPTIME = 30;   # well past RESTART_START_GRACE -- these tests are about
                    # GH-151/GH-158, not the restart gate (covered by t/38).
sub uptime { return $UPTIME; }
sub helperForClient { return undef; }
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { return undef; }
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

done_testing();
