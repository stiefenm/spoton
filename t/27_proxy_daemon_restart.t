#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Network proxy: the running Unified daemon follows the proxy setting
# (spec 2.3 "apply on change: daemons restart", 2.4 fail-closed).
# Loads the real Unified::DaemonManager and Unified::Daemon; only LMS and
# Proc::Background are stubbed (the fake Proc::Background records spawns).

my $cachedir;
BEGIN { $cachedir = tempdir(CLEANUP => 1) }

BEGIN {
    *main::INFOLOG   = sub () { 1 };
    *main::DEBUGLOG  = sub () { 0 };
    *main::ISWINDOWS = sub () { 0 };

    package Slim::Utils::Log;
    our @logged;    # [level, message]
    sub logger { return bless {}, 'Slim::Utils::Log' }
    for my $lvl (qw(error warn info debug)) {
        no strict 'refs';
        *{"Slim::Utils::Log::$lvl"} = sub { push @logged, [$lvl, $_[1]] };
    }
    sub is_info  { 1 }
    sub is_debug { 0 }
    sub import { no strict 'refs'; *{caller() . '::logger'} = \&logger }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package Slim::Utils::Prefs;
    our %store;
    sub preferences { my $ns = $_[0] eq __PACKAGE__ ? $_[1] : $_[0]; bless { ns => $ns }, __PACKAGE__ }
    sub get    { $store{ $_[0]{ns} }{ $_[1] } }
    sub set    { $store{ $_[0]{ns} }{ $_[1] } = $_[2] }
    sub client { bless { ns => $_[0]{ns} . ':' . $_[1]->id }, __PACKAGE__ }
    sub import { no strict 'refs'; *{caller() . '::preferences'} = \&preferences }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package Slim::Utils::Timers;
    sub killTimers { }
    sub setTimer   { }
    $INC{'Slim/Utils/Timers.pm'} = 1;

    package Slim::Utils::Cache;
    sub new { bless {}, shift }
    $INC{'Slim/Utils/Cache.pm'} = 1;

    package Slim::Utils::Strings;
    sub cstring { $_[1] }
    sub import { no strict 'refs'; *{caller() . '::cstring'} = \&cstring }
    $INC{'Slim/Utils/Strings.pm'} = 1;

    package JSON::XS::VersionOneAndTwo;
    sub import { no strict 'refs'; my $c = caller; *{"${c}::from_json"} = sub { {} }; *{"${c}::to_json"} = sub { '{}' } }
    $INC{'JSON/XS/VersionOneAndTwo.pm'} = 1;

    package Slim::Utils::Accessor;
    sub new { bless {}, shift }
    sub mk_accessor {
        my ($class, $type, @names) = @_;
        no strict 'refs';
        for my $n (@names) {
            *{"${class}::$n"} = sub { my $s = shift; $s->{$n} = shift if @_; $s->{$n} };
        }
    }
    $INC{'Slim/Utils/Accessor.pm'} = 1;

    package Slim::Networking::SimpleAsyncHTTP;
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;

    package Slim::Utils::Network;
    sub serverAddr { '192.0.2.10' }

    package FakeClient;
    sub new        { bless { id => $_[1], playing => 0 }, $_[0] }
    sub id         { $_[0]{id} }
    sub name       { 'Kitchen' }
    sub model      { 'squeezelite' }
    sub isSynced   { 0 }
    sub master     { undef }
    sub formats    { ('pcm', 'flc') }
    sub volume     { 50 }
    sub isPlaying  { $_[0]{playing} }
    sub playingSong {
        my $self = shift;
        return unless $self->{playing};
        return bless {}, 'FakeSong';
    }
    package FakeSong;  sub track { bless {}, 'FakeTrack' }
    package FakeTrack; sub url   { 'spoton://track:1' }

    package Slim::Player::Client;
    our %clients;
    sub getClient { $clients{ ref $_[0] ? $_[0]->id : $_[0] } }
    sub clients   { values %clients }

    package Plugins::SpotOn::Helper;
    our %caps;
    sub get           { '/fake/spoton' }
    sub getCapability { $caps{ $_[1] } }
    $INC{'Plugins/SpotOn/Helper.pm'} = 1;

    package Plugins::SpotOn::Plugin;
    sub SPOTON_CACHE_VERSION   { 1 }
    sub _bitrateConfigForClient { 320 }
    $INC{'Plugins/SpotOn/Plugin.pm'} = 1;

    # Fake Proc::Background: records every spawn (argv), process "dies" on die.
    package Proc::Background;
    our @spawned;
    my $pid = 1000;
    sub new {
        my ($class, $opts, $path, @args) = @_;
        push @spawned, [@args];
        return bless { alive => 1, pid => ++$pid }, $class;
    }
    sub alive { $_[0]{alive} }
    sub die   { $_[0]{alive} = 0; 1 }
    sub pid   { $_[0]{pid} }
    $INC{'Proc/Background.pm'} = 1;
}

use FindBin qw($Bin);
use lib "$Bin/..";

use Plugins::SpotOn::Unified::DaemonManager;
use Plugins::SpotOn::Unified::Daemon;

my $DM  = 'Plugins::SpotOn::Unified::DaemonManager';
my $MAC = 'aa:bb:cc:dd:ee:01';

make_path("$cachedir/spoton");
{ open my $fh, '>', "$cachedir/spoton/credentials.json" or die $!; print $fh '{}'; close $fh }
Slim::Utils::Prefs::preferences('server')->set(cachedir => $cachedir);
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->set(activeAccount => '');
$prefs->set(enableSpotifyConnect => 0);

my $client = $Slim::Player::Client::clients{$MAC} = FakeClient->new($MAC);
$Plugins::SpotOn::Helper::caps{proxy} = 1;

sub spawns   { scalar @Proc::Background::spawned }
sub lastArgs { join ' ', @{ $Proc::Background::spawned[-1] || [] } }
sub purl     { $_[0]->can("_proxyUrl") ? $_[0]->_proxyUrl : "<no accessor>" }
sub errors   { grep { $_->[0] eq 'error' && $_->[1] =~ /proxy/ } @Slim::Utils::Log::logged }

# ---------------------------------------------------------------------------
# DaemonManager::startHelper: an alive daemon follows proxy changes
# ---------------------------------------------------------------------------

# started without a proxy
$prefs->set(networkProxy => '');
my $h0 = $DM->startHelper($MAC);
ok($h0 && $h0->alive, 'no proxy: daemon started');
is(spawns(), 1, 'no proxy: one spawn');
unlike(lastArgs(), qr/--proxy/, 'no proxy: no --proxy argument');
is(purl($h0), '', 'Daemon records the proxy it started with (none)');

# proxy set -> restarted with --proxy, even while a SpotOn stream is playing
# (routing/security change: no "idle" guard)
$client->{playing} = 1;
$prefs->set(networkProxy => 'http://p:3128');
my $h1 = $DM->startHelper($MAC);
ok(!$h0->alive, 'proxy set: old daemon stopped');
is(spawns(), 2, 'proxy set: daemon restarted');
like(lastArgs(), qr/--proxy http:\/\/p:3128/, 'proxy set: new daemon gets --proxy');
ok($h1 && $h1->alive, 'proxy set: new daemon alive');
is(purl($h1), 'http://p:3128', 'Daemon records the proxy url');
$client->{playing} = 0;

# same proxy (different spelling, same normalised url) -> untouched
$prefs->set(networkProxy => ' HTTP://P:3128/ ');
my $h2 = $DM->startHelper($MAC);
is(spawns(), 2, 'same proxy: no restart');
ok($h2 == $h1 && $h1->alive, 'same proxy: same daemon still running');

# proxy changed to another one -> restarted
$prefs->set(networkProxy => 'http://q:8080');
my $h3 = $DM->startHelper($MAC);
is(spawns(), 3, 'other proxy: restarted');
like(lastArgs(), qr/--proxy http:\/\/q:8080/, 'other proxy: new url passed');
ok(!$h1->alive, 'other proxy: old daemon stopped');

# proxy cleared -> restarted direct
$prefs->set(networkProxy => '');
my $h4 = $DM->startHelper($MAC);
is(spawns(), 4, 'proxy cleared: restarted');
unlike(lastArgs(), qr/--proxy/, 'proxy cleared: no --proxy argument');
ok(!$h3->alive, 'proxy cleared: proxied daemon stopped');
is(purl($h4), '', 'proxy cleared: Daemon records no proxy');

# proxy set but the binary cannot take --proxy -> stopped, not restarted
$prefs->set(networkProxy => 'http://p:3128');
$Plugins::SpotOn::Helper::caps{proxy} = undef;
@Slim::Utils::Log::logged = ();
my $h5 = $DM->startHelper($MAC);
ok(!$h4->alive, 'blocked: running daemon stopped');
is(spawns(), 4, 'blocked: no new spawn');
ok(!$h5, 'blocked: startHelper returns no helper');
is(scalar(errors()), 1, 'blocked: one ERROR logged');

# watchdog passes while blocked: still nothing spawned, no repeated ERROR
$DM->startHelper($MAC) for 1 .. 3;
is(spawns(), 4, 'blocked: watchdog passes do not spawn');
is(scalar(errors()), 1, 'blocked: ERROR logged once per state change, not per pass');

# unblocked -> starts again; re-blocked -> one fresh ERROR
$Plugins::SpotOn::Helper::caps{proxy} = 1;
my $h6 = $DM->startHelper($MAC);
ok($h6 && $h6->alive, 'unblocked: daemon starts');
is(spawns(), 5, 'unblocked: spawned');
like(lastArgs(), qr/--proxy http:\/\/p:3128/, 'unblocked: with --proxy');
$Plugins::SpotOn::Helper::caps{proxy} = undef;
@Slim::Utils::Log::logged = ();
$DM->startHelper($MAC) for 1 .. 2;
ok(!$h6->alive, 're-blocked: stopped');
is(scalar(errors()), 1, 're-blocked: ERROR logged again once');
$Plugins::SpotOn::Helper::caps{proxy} = 1;
$DM->stopHelper($MAC);

# ---------------------------------------------------------------------------
# Daemon::start fail-closed branch
# ---------------------------------------------------------------------------
{
    my $mac2 = 'aa:bb:cc:dd:ee:02';
    $Slim::Player::Client::clients{$mac2} = FakeClient->new($mac2);
    $prefs->set(networkProxy => 'http://p:3128');
    $Plugins::SpotOn::Helper::caps{proxy} = undef;
    my $before = spawns();
    my $d = Plugins::SpotOn::Unified::Daemon->new($mac2);
    is(spawns(), $before, 'Daemon::start blocked: no spawn');
    ok(!$d->alive, 'Daemon::start blocked: not alive');
    ok(!defined $d->_proc, 'Daemon::start blocked: no process');
    ok(!defined $d->name && !defined $d->cache && !defined purl($d),
        'Daemon::start blocked: state untouched (name, cache, proxy)');
    is_deeply($d->_startTimes, [], 'Daemon::start blocked: no crash-loop start recorded');

    $Plugins::SpotOn::Helper::caps{proxy} = 1;
    $d->start;
    ok($d->alive, 'Daemon::start unblocked: spawned');
    is(purl($d), 'http://p:3128', 'Daemon::start: _proxyUrl set');
    $d->stop;
}

done_testing;
