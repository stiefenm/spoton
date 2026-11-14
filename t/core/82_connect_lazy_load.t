#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Symbol ();

# ============================================================
# Connect.pm is loaded late: the first `require Plugins::SpotOn::Connect` in
# a normal start is Plugin::_startUnifiedDaemons, a timer 4 s after
# initPlugin. LMS can call the protocol handler before that. Live on
# 2026-11-14, 3.4 s after LMS finished its init, a sync group member's HELO
# (Squeezebox::reconnect -> StreamingController::playerActive ->
# _JumpToTime) asked canDoAction('rew'), which died with `Can't locate object
# method "isSpotifyConnect" via package "Plugins::SpotOn::Connect"`; the
# group stayed at "play", time 0, until stop + play.
#
# Every protocol handler entry point that asks Connect must load it itself.
# This file loads the REAL ProtocolHandler.pm and the REAL Connect.pm (no
# Connect stub, unlike t/soloist/29, which preloads one and so cannot see a
# missing require), starts each case with Connect unloaded, and checks
#   - canDoAction('rew')           (both backends: Connect is asked first)
#   - getSeekData                  (librespot shape: connectSeekViaControl 1)
#   - getNextTrack's Browse entry  (the browse-entry claim release)
# neither die nor answer differently from the same call with Connect loaded,
# with and without a Connect claim.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
for my $m (qw(ProtocolHandler Connect)) {
    die "Plugins/SpotOn/$m.pm not present in this checkout (die, never skip)\n"
        unless -f "$project_dir/Plugins/SpotOn/$m.pm";
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
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger   { return bless {}, 'Slim::Utils::Log' }
sub info     { }
sub warn     { }
sub error    { }
sub debug    { }
sub is_info  { 0 }
sub is_debug { 0 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless {}, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs' }
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

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { join(' ', grep { defined } @_[1..$#_]) };
    *{"${caller}::string"}  = sub { join(' ', grep { defined } @_[1..$#_]) };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '192.0.2.9' }
1;
END

write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new { return bless {}, shift }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use JSON::PP ();
sub import {
    my $caller = caller;
    no strict 'refs';
    my $j = JSON::PP->new->canonical;
    *{"${caller}::to_json"}   = sub { $j->encode($_[0]) };
    *{"${caller}::from_json"} = sub { $j->decode($_[0]) };
}
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { return undef }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
1;
END

# DaemonManager: backendFor hands out $ROLE, a per-case object with the
# backend role contract (Plugins/SpotOn/Backend.pm: new/mac/control/notify/
# query/capabilities/state). The two shapes below are what the real roles
# answer while no player engine exists yet -- the state of the first seconds
# after a restart: librespot never has one (mode undef, query undef);
# Soloist has none until its daemon starts (query('seekable') and
# query('consumeRestartAllowance') undef, mode undef).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $ROLE;
sub backendFor { return $ROLE; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 0 };
    *main::DEBUGLOG = sub () { 0 };
    *main::SCANNER  = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

# Production compiles Plugin.pm before anything else; ProtocolHandler.pm and
# Connect.pm read SPOTON_CACHE_VERSION from it at load time.
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");
require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load ProtocolHandler.pm");

my $PH = 'Plugins::SpotOn::ProtocolHandler';

# ------------------------------------------------------------
# Fakes. Only methods the real classes have, with their real semantics.
# ------------------------------------------------------------
package Test::Role82;
sub new {
    my ($class, %args) = @_;
    return bless { mac => $args{mac}, caps => { %{ $args{caps} || {} } },
                   mode => $args{mode}, calls => [] }, $class;
}
sub mac          { return $_[0]->{mac}; }
sub capabilities { return { %{ $_[0]->{caps} } }; }
sub state        { return { mode => $_[0]->{mode} }; }
sub query        { my ($s, $what) = @_; push @{ $s->{calls} }, "query:$what"; return undef; }
sub notify       { my ($s, $what) = @_; push @{ $s->{calls} }, "notify:$what"; return 'unsupported'; }
sub control      { my ($s, $verb) = @_; push @{ $s->{calls} }, "control:$verb"; return 'ok'; }

# Slim::Player::Client: an unsynced player is its own master
# (Client.pm:1346 master -> controller->master).
package Test::FakeClient82;
sub new { return bless { id => $_[1], pluginData => {} }, $_[0]; }
sub id     { return $_[0]->{id}; }
sub master { return $_[0]; }
# Client.pm:1237: an undef value is a read, not a write.
sub pluginData {
    my $self = shift;
    my $key  = shift;
    $self->{pluginData}{$key} = $_[0] if @_ && defined $_[0];
    return $self->{pluginData}{$key};
}
sub playingSong { return undef; }

# Slim::Player::Song (track/master/duration/seekdata accessors, Song.pm:58/729-731/779)
# and Slim::Schema::RemoteTrack (url; samplesize/samplerate/channels accessors).
package Test::FakeTrack82;
sub new { return bless { url => $_[1] }, $_[0]; }
sub url { return $_[0]->{url}; }
for my $f (qw(samplesize samplerate channels)) {
    no strict 'refs';
    *{$f} = sub { my $s = shift; $s->{$f} = shift if @_; return $s->{$f}; };
}
package Test::FakeSong82;
sub new {
    my ($class, %a) = @_;
    return bless { master => $a{master}, track => Test::FakeTrack82->new($a{url}) }, $class;
}
sub master   { return $_[0]->{master}; }
sub track    { return $_[0]->{track}; }
sub duration { my $s = shift; $s->{duration} = shift if @_; return $s->{duration}; }
sub seekdata { my $s = shift; $s->{seekdata} = shift if @_; return $s->{seekdata}; }

package main;

my $URL = 'spoton://track:abc123';

# The state of the first 4 s after a restart: Connect.pm not compiled at all.
sub unload_connect {
    Symbol::delete_package('Plugins::SpotOn::Connect');
    delete $INC{'Plugins/SpotOn/Connect.pm'};
}

sub connect_loaded { return $INC{'Plugins/SpotOn/Connect.pm'} ? 1 : 0; }

sub soloist_shape {
    return Test::Role82->new(mac => $_[0], caps => { connectSeekViaControl => 0 }, mode => $_[1]);
}
sub librespot_shape {
    return Test::Role82->new(mac => $_[0], caps => { connectSeekViaControl => 1 }, mode => undef);
}

ok(!connect_loaded(), 'loading ProtocolHandler.pm does not load Connect.pm (the state before the 4 s timer)');
ok(!Plugins::SpotOn::Connect->can('isSpotifyConnect'), 'isSpotifyConnect is not defined yet');

# ------------------------------------------------------------
# canDoAction('rew'): LMS asks before it restarts the current title
# (_JumpToTime: time 0, unknown duration, a new sync member).
# ------------------------------------------------------------
for my $shape (['soloist', \&soloist_shape], ['librespot', \&librespot_shape]) {
    my ($name, $make) = @$shape;
    unload_connect();
    my $client = Test::FakeClient82->new("00:00:00:00:82:0" . ($name eq 'soloist' ? 1 : 2));
    local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $make->($client->id);

    my $cold;
    my $lived = eval { $cold = $PH->canDoAction($client, $URL, 'rew'); 1 };
    ok($lived, "$name: canDoAction('rew') with Connect.pm not loaded does not die")
        or diag("died: $@");
    ok(connect_loaded(), "$name: canDoAction('rew') loaded Connect.pm itself");

    my $warm = $PH->canDoAction($client, $URL, 'rew');
    is($cold, 1, "$name: canDoAction('rew') without a Connect claim -> 1 (LMS restarts the title)");
    is($cold, $warm, "$name: canDoAction('rew') answers the same with Connect.pm loaded");

    # The Connect guard still works once loaded: a claimed player blocks the
    # LMS-side restart (GH #129); without an engine there is no restart allowance.
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'test');
    is($PH->canDoAction($client, $URL, 'rew'), 0, "$name: canDoAction('rew') with a Connect claim -> 0 (unchanged)");
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');

    unload_connect();
    is($PH->canDoAction($client, $URL, 'pause'), 1, "$name: canDoAction('pause') -> 1");
    is($PH->canDoAction($client, $URL, 'stop'),  1, "$name: canDoAction('stop') -> 1");
}

# ------------------------------------------------------------
# getSeekData: the librespot shape asks Connect (connectSeekViaControl 1);
# the Soloist shape never does, but must not depend on the load order either.
# ------------------------------------------------------------
for my $shape (['librespot', \&librespot_shape, undef], ['soloist', \&soloist_shape, { timeOffset => 30 }]) {
    my ($name, $make, $claimed) = @$shape;
    unload_connect();
    my $client = Test::FakeClient82->new("00:00:00:00:82:1" . ($name eq 'soloist' ? 1 : 2));
    my $song   = Test::FakeSong82->new(master => $client, url => $URL);
    local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $make->($client->id);

    my $cold;
    my $lived = eval { $cold = $PH->getSeekData($client, $song, 30); 1 };
    ok($lived, "$name: getSeekData with Connect.pm not loaded does not die")
        or diag("died: $@");

    require Plugins::SpotOn::Connect;
    my $warm = $PH->getSeekData($client, $song, 30);
    is_deeply($cold, { timeOffset => 30 }, "$name: getSeekData without a Connect claim -> { timeOffset => 30 }");
    is_deeply($cold, $warm, "$name: getSeekData answers the same with Connect.pm loaded");

    # librespot: a Connect seek goes over /control/seek, LMS must not restart
    # (undef); Soloist keeps the restart chain ({ timeOffset }).
    Plugins::SpotOn::Connect->bindConnectClaim($client, 'test');
    is_deeply($PH->getSeekData($client, $song, 30), $claimed,
        "$name: getSeekData with a Connect claim -> " . (defined $claimed ? '{ timeOffset => 30 }' : 'undef') . ' (unchanged)');
    Plugins::SpotOn::Connect->releaseConnectClaim($client, 'test');
}

# ------------------------------------------------------------
# getNextTrack, Browse entry: the claim release after the backend took the
# track request. Today only a Soloist player engine reports a mode, and
# engines start after the 4 s timer has loaded Connect.pm; the release must
# not rely on that order.
# ------------------------------------------------------------
{
    unload_connect();
    my $client = Test::FakeClient82->new('00:00:00:00:82:21');
    my $song   = Test::FakeSong82->new(master => $client, url => $URL);
    my $role   = soloist_shape($client->id, 'browse');
    local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $role;
    $client->pluginData(connectOwnPlayUri => 'spotify:track:abc123');

    my $lived = eval { $PH->getNextTrack($song, sub { }, sub { }); 1 };
    ok($lived, "getNextTrack (Browse entry) with Connect.pm not loaded does not die")
        or diag("died: $@");
    ok(scalar(grep { $_ eq 'control:track' } @{ $role->{calls} }), 'getNextTrack handed the track request to the backend role');
    is($client->pluginData('connectOwnPlayUri'), '', 'getNextTrack released the Connect claim state (browse-entry)');
}

done_testing();
