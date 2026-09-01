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
# Phase 76-05 gap fill (Nyquist validation): behavioral coverage for the
# restart-autoplay provenance gate in Connect.pm's 'start' handler
# (constant RESTART_START_GRACE). Prior coverage (t/37_connect_lifecycle.t)
# is grep-gate only -- this test actually DRIVES _connectEvent() with a
# fake Slim::Control::Request/Client pair and asserts the dispatched
# commands, following the stub-package harness pattern established by
# t/32_soloist_events.t for isolating LMS-plugin code outside the server.
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

# Records every dispatched Slim::Control::Request so the test can assert
# whether a 'playlist play' command was (or was not) issued.
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

# Settable uptime so both branches of the RESTART_START_GRACE gate are
# reachable; helperForClient => undef routes 'start' down the librespot
# spoton://connect-<ts> path (no SoloistDaemon in this harness).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $UPTIME = 0;
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

require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");

require_ok('Slim::Control::Request')
    or BAIL_OUT("Failed to load the Slim::Control::Request stub");

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the DaemonManager stub");

require_ok('Plugins::SpotOn::Connect')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Connect");

# ------------------------------------------------------------------
# Fake player: only the accessors _connectEvent's 'start' branch reads.
# ------------------------------------------------------------------
package Test::FakeClient;
my $counter = 0;
sub new {
    my $class = shift;
    $counter++;
    return bless {
        id         => "aa:bb:cc:dd:ee:$counter",
        pluginData => {},
        power      => 1,
        isPlaying  => 0,
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
    my ($class, $client, $cmd, %params) = @_;
    return bless { client => $client, cmd => $cmd, params => \%params }, $class;
}
sub client   { return $_[0]->{client}; }
sub getParam { return $_[0]->{params}{ $_[1] }; }

package main;

sub playlist_play_dispatched {
    return grep {
        $_->{cmd} && ref($_->{cmd}) eq 'ARRAY'
            && ($_->{cmd}[0] // '') eq 'playlist'
            && ($_->{cmd}[1] // '') eq 'play'
    } @Slim::Control::Request::EXECUTED;
}

# ==================================================================
# Scenario 1: 'start' arrives at daemon uptime 2s (< RESTART_START_GRACE
# == 5) while the player is idle -- a restart re-announcement. Must NOT
# dispatch playlist play (the autoplay gate, ROADMAP: Auto-Play nach
# LMS-Restart).
# ==================================================================
{
    local $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 2;
    @Slim::Control::Request::EXECUTED = ();

    my $client  = Test::FakeClient->new();
    my $request = Test::FakeRequest->new($client, 'start', _cmd => 'start', _p2 => undef);
    $request->{params}{_cmd} = 'start';

    Plugins::SpotOn::Connect::_connectEvent($request);

    is(playlist_play_dispatched(), 0,
        'autoplay gate: no playlist play dispatched for a restart re-announcement (uptime 2s < grace, idle player)');
    is($client->pluginData('pendingConnect'), 0,
        'autoplay gate: pendingConnect is cleared on the suppressed branch');
}

# ==================================================================
# Scenario 2: 'start' arrives at daemon uptime 10s (> RESTART_START_GRACE)
# -- a genuine transfer well after daemon spawn. Playlist play MUST be
# dispatched (the gate must not suppress real transfers).
# ==================================================================
{
    local $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 10;
    @Slim::Control::Request::EXECUTED = ();

    my $client  = Test::FakeClient->new();
    my $request = Test::FakeRequest->new($client, 'start', _cmd => 'start', _p2 => undef);

    Plugins::SpotOn::Connect::_connectEvent($request);

    is(playlist_play_dispatched(), 1,
        'autoplay gate: a genuine transfer (uptime 10s > grace) still dispatches playlist play');
}

# ==================================================================
# Scenario 3: daemon-crash recovery exception -- 'start' arrives within
# the grace window (uptime 1s) but the player is ALREADY audibly playing.
# The gate must NOT suppress this (isPlaying exception, 76-05 SUMMARY).
# ==================================================================
{
    local $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 1;
    @Slim::Control::Request::EXECUTED = ();

    my $client = Test::FakeClient->new();
    $client->{isPlaying} = 1;
    my $request = Test::FakeRequest->new($client, 'start', _cmd => 'start', _p2 => undef);

    Plugins::SpotOn::Connect::_connectEvent($request);

    is(playlist_play_dispatched(), 1,
        'autoplay gate: an already-playing player within the grace window is NOT suppressed (crash-recovery exception)');
}

done_testing();
