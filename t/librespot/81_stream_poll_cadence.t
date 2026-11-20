#!/usr/bin/perl
# 89-08 (ACC-02): the 5 s _streamAlivePoll keeps its cadence across the 60 s watchdog fan-out.
# Moved from the debug session file .planning/debug/89-browse-retry-stops-late.assets/red_poll_blackout.t.
# On the code before 89-08 cells 7 and 8 fail (latency 13.8 s, longest silence 15.0 s) because startHelper
# on an alive helper killed and re-armed a pending poll.
# The stub header is the one of t/librespot/79_audiokey_halt.t plus the extra FakeClient methods
# startHelper/initHelpers ask for.
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Unified/DaemonManager.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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
# LMS module stubs required to load DaemonManager.pm in isolation.
# DaemonManager.pm has never had test coverage before this plan (71-02) --
# it is intentionally absent from t/05_perl_syntax.t's @pm_files because a
# straight `perl -c` against a real LMS checkout fails on JSON::XS's XS
# binary not being installed in this sandbox (pre-existing environment gap,
# unrelated to this plan -- see 71-02-SUMMARY.md). Full isolated `require`
# below is a strictly stronger check than `perl -c` since it also executes
# the module's top-level statements.
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
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
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Task 2 (73-01): backed by a package hash so tests can control arbitrary
# pref keys (e.g. 'backend', 'cachedir') without a bespoke stub per key.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( cachedir => '/tmp/spoton-test-cachedir' );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set      { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client   { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
# 74b-03: a small in-memory store so the audio-key cells can seed
# spoton_audiokey_state_<account>; unset keys still read as undef.
our %STORE;
sub new    { return bless {}, shift }
sub get    { return $STORE{ $_[1] } }
sub set    { $STORE{ $_[1] } = $_[2] }
sub remove { delete $STORE{ $_[1] } }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
# 89-02: cstring answers the KEY so a cell can pin which string reached the player.
sub cstring { my ($client, $key) = @_; return $key }
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = \&cstring;
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
# Phase 82 Plan 44 (Revision 1): call-recording instead of a pure no-op --
# the new two-player isolation case below needs to inspect the
# $objRef argument each call was made with, which a bare no-op stub cannot
# provide.
# Phase 82 Plan 45 (WR-05, 82-REVIEW.md Zeile 109-110): @TIMERS added
# alongside the existing @KILL_CALLS/@SET_CALLS recorders -- both existing
# arrays keep pushing/filtering exactly as before (existing assertions
# unchanged) while @TIMERS additionally tracks live (objRef, when,
# coderef) entries so fire_due() can actually fire a registered timer.
# Identical idiom to t/30_soloist_daemon.t:192-215.
our @KILL_CALLS;
our @SET_CALLS;
our @TIMERS;
sub killTimers {
    push @KILL_CALLS, [@_];
    my ($obj, $cb) = @_;
    # Phase 82 Plan 45: 'eq', NOT '==' -- unlike t/30_soloist_daemon.t's
    # blessed-object $objRef (where '==' correctly compares identity via
    # address), DaemonManager.pm's package-level timers are keyed by plain
    # clientId strings (or the class name). Under '==', every non-numeric
    # MAC-like string numifies to 0, so '$_->[0] == $obj' would be TRUE for
    # every string objRef pair sharing a coderef -- killing one client's
    # timer would silently also kill every OTHER client's same-coderef
    # timer, exactly the cross-player leakage the existing Fall Isolation
    # (zwei Spieler) case already guards against for @KILL_CALLS via its
    # own 'eq'-based filter (see ~line 861 below).
    @TIMERS = grep { !($_->[0] eq $obj && $_->[2] == $cb) } @TIMERS;
}
sub setTimer {
    push @SET_CALLS, [@_];
    push @TIMERS, [@_];
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

# Stub: Slim::Networking::Select (Phase 83.3 plan 03: SoloistDaemon.pm now
# `use`s this at the top level for the D-06 smoke test's event-driven pipe
# read -- required for the module to load in this sandbox, even though this
# file never exercises smokeTest() itself)
write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
sub addRead    { }
sub removeRead { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
}
1;
END

# Task 2 (73-01): needed for the REAL Plugins::SpotOn::Soloist module (loaded
# below, not stubbed out) which `use`s this at compile time (_arch()).
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
1;
END

# Task 2 (73-01): needed for the REAL Plugins::SpotOn::Unified::SoloistDaemon
# module (isolated-require target below) which `use base qw(Slim::Utils::Accessor)`.
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

# Minimal stand-in -- DaemonManager.pm only needs the CACHE_VERSION constant
# and _pluginDataFor at load time. Task 2 (73-01): $FAKE_BASEDIR is settable
# per-test so ensureWsLib()'s vendor-fallback push resolves the REAL
# Plugins/SpotOn/Vendor tree (see the ensureWsLib block below).
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
our $FAKE_BASEDIR = 'test-basedir';
sub _pluginDataFor { return $FAKE_BASEDIR }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
# 74b WR-03: enough of a daemon for DaemonManager::startHelper to register one
# and for _streamAlivePoll to run its audio-key block against it. $TAIL is the
# stderr tail every instance reports; $ACCOUNT its account id; $HEALTH its
# last health snapshot (the GH #141 "actively streaming" input).
our $TAIL    = '';
our $ACCOUNT = 'ACCT0123456789abcdef';
our $HEALTH  = undef;
our $PORT    = undef;
sub new {
    my ($class, $mac) = @_;
    return bless { mac => $mac, alive => 1 }, $class;
}
# 84-08: DaemonManager keys its Soloist-only paths on backendName, not isa.
sub backendName { return 'librespot' }
sub mac                 { return $_[0]->{mac} }
sub alive               { return $_[0]->{alive} }
sub pid                 { return 4242 }
sub name                { return undef }
sub _accountId          { return $ACCOUNT }
sub _streamPort         { return $PORT }
sub _lastHealthSession  { return $HEALTH }
sub stderrTail          { return $TAIL }
sub stop                { $_[0]->{alive} = 0; return }
1;
END

# 74b WR-03: _streamAlivePoll asks LMS for the player behind the daemon; no
# player here, so _isStreamActive falls back to the health snapshot.
BEGIN {
    package Slim::Player::Client;
    our %BY_MAC;
    sub getClient { return $BY_MAC{ $_[0] // '' } }
}

# Phase 82 Plan 45 (WR-05): required by _pendingTrackRequestTimeout's
# `require Plugins::SpotOn::Status; Status->recordError(...)` call -- without
# this stub, the eval{} around that call swallows a load failure of the REAL
# module and the RECORDED-array assertions below have nothing to check
# against. Copied verbatim from t/30_soloist_daemon.t:220-241.
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our @RECORDED;
sub recordError {
    my $class = shift;
    push @RECORDED, [@_];
    shift @RECORDED while scalar @RECORDED > 30;
}
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;
    @RECORDED = grep {
        !(($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key)
    } @RECORDED;
}
sub hasError {
    my ($class, $module, $key, $level) = @_;
    return 0 unless defined $key;
    return scalar grep {
        ($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key
            && (!defined $level || ($_->[0] // '') eq $level)
    } @RECORDED;
}
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}
our $FAKE_ISWINDOWS = 0;
our $FAKE_ISMAC     = 0;
BEGIN {
    no warnings 'redefine';
    *main::ISWINDOWS   = sub () { $main::FAKE_ISWINDOWS };
    *main::ISMAC       = sub () { $main::FAKE_ISMAC };
}

# ============================================================
# 89-02 Task 1 (ACC-02 Browse half, ACC-03 player text): the fork's limit
# marker in a helper's stderr tail stops a Browse player once, tells the user
# on the player and in server.log. The REAL DaemonManager, Credentials and
# ProtocolHandler run over the stubs above; only LMS and the helper are fakes.
# ============================================================

# What ProtocolHandler.pm needs to load (same stubs as t/librespot/55).
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '192.0.2.7' }
1;
END
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL { my ($u) = @_; return ($u // '') =~ m{^\w+://([^/:]+)(?::(\d+))?(/.*)?$} ? ($1, $2 // 80, $3 // '/') : ('127.0.0.1', 80, '/') }
sub findbin           { }
sub addFindBinPaths   { }
1;
END
write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END
write_stub($stub_dir, 'Slim::Schema::RemoteTrack', <<'END');
package Slim::Schema::RemoteTrack;
sub fetch { return undef }
1;
END
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { return bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END
write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
sub new { my ($class, $args) = @_; return bless { %$args }, $class; }
1;
END

$::VERSION = '9.0.0';

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Unified::DaemonManager') or BAIL_OUT('DaemonManager.pm does not load');
require_ok('Plugins::SpotOn::Backend::Librespot')     or BAIL_OUT('Backend/Librespot.pm does not load');
require_ok('Plugins::SpotOn::API::Credentials') or BAIL_OUT('Credentials.pm does not load');
require_ok('Plugins::SpotOn::Backend')          or BAIL_OUT('Backend.pm does not load');
require_ok('Plugins::SpotOn::ProtocolHandler')  or BAIL_OUT('ProtocolHandler.pm does not load');

my $CRED = 'Plugins::SpotOn::API::Credentials';
my $PH   = 'Plugins::SpotOn::ProtocolHandler';
my $DM   = 'Plugins::SpotOn::Unified::DaemonManager';

# --- doubles -------------------------------------------------------------
our (@EVENTS, @WARNS);
{
    package FakeTrack;
    sub new { return bless { url => $_[1] }, $_[0] }
    sub url { return $_[0]{url} }

    package FakeSong;
    sub new   { return bless { url => $_[1] }, $_[0] }
    sub track { return FakeTrack->new($_[0]{url}) }

    package FakeClient;
    sub new {
        my ($class, $mac, $name) = @_;
        return bless { mac => $mac, name => $name, url => undef, exec => [], brief => [] }, $class;
    }
    sub id            { return $_[0]{mac} }
    sub name          { return $_[0]{name} }
    sub streamingSong { return $_[0]{url} ? FakeSong->new($_[0]{url}) : undef }
    sub playingSong   { return undef }
    sub isPlaying     { return 0 }
    sub isSynced      { return 0 }
    sub model         { return 'squeezebox' }
    sub master        { return undef }
    sub formats       { return () }
    sub execute       { my ($s, $cmd) = @_; push @{ $s->{exec} }, $cmd; push @main::EVENTS, 'exec:' . join(' ', @$cmd); }
    sub showBriefly   { my ($s, @a) = @_; push @{ $s->{brief} }, [@a]; push @main::EVENTS, 'brief'; }
}

{
    no warnings 'redefine';
    # server.log: record every warn line.
    *Slim::Utils::Log::warn = sub { shift; push @WARNS, join('', @_); };
    # killTimers on a fake client lands in the shared event log, in order with execute.
    my $origKill = \&Slim::Utils::Timers::killTimers;
    *Slim::Utils::Timers::killTimers = sub {
        my ($obj, $cb) = @_;
        if (Scalar::Util::blessed($obj) && $obj->isa('FakeClient')) {
            require B;
            push @EVENTS, 'kill:' . $obj->{mac} . ':' . B::svref_2object($cb)->GV->NAME;
        }
        return $origKill->(@_);
    };
}

# A missing sub must show up as a failing cell (not ok), never as a die that
# hides every later cell: the three seams are reached through eval wrappers.
sub lal     { my $r = eval { $CRED->lastAudioKeyLine(@_) }; return $r }
sub adv     { my $r = eval { $DM->audioKeyAdvice };         return $r }
sub advtext { my $r = eval { $DM->audioKeyAdviceText(@_) }; return $r }

my $L1 = 'PLUGIN_SPOTON_AUDIOKEY_PLAYER_L1';
my $L2 = 'PLUGIN_SPOTON_AUDIOKEY_PLAYER_L2';

sub marker {
    my ($ts, $n, $code) = @_;
    return "[2026-11-18T$ts" . "Z WARN  librespot_core::audio_key] Spotify refused audio keys for $n tracks in a row (code " . ($code // 1) . "), playback is paused\n";
}


# ============================================================
# startHelper() on an ALREADY-ALIVE helper re-arms the 5 s _streamAlivePoll (killTimers + setTimer(now+5),
# DaemonManager.pm "Unified daemon is always streaming when alive" block at the end of startHelper).
# initHelpers() (the 60 s watchdog) calls startHelper() for every player: the first at once, the 2nd..Nth through
# _staggeredStart at +3 s steps. So once a minute the pending poll tick is killed again and again until
# (N-1)*3+5 s after the watchdog; with 3 players the poll is silent for 15 s. A refused-key marker written inside
# that hole is reacted to up to 15 s late: the 89-05 Browse retry stopped one title late.
# Real DaemonManager (initHelpers, startHelper, _streamAlivePoll, _onAudioKeyHalt), fake clock, fake timers,
# three stub helpers; only LMS and the helper process are fakes. The marker offsets come from the 89-05 runs:
#   afternoon (10:35-10:36): marker 10:36:10.0, watchdog 10:36:12.79 -> 2.8 s before it, last poll before it 10:36:08.79
#   morning   (09:07-09:08): marker 09:08:14.0, watchdog 09:08:21.69 -> 7.7 s before it, last poll before it 09:08:17.69
# ============================================================
require Time::HiRes;
our $NOW = 1_800_000_000;
{ no warnings 'redefine', 'prototype'; *Time::HiRes::time = sub { $main::NOW }; }

{
    package Slim::Player::Client;
    our @ALL = ();
    sub clients { return @ALL }
    package Slim::Player::Sync;
    sub isSlave { return 0 }
    sub slaves  { return () }
}
{ no warnings 'redefine'; *Plugins::SpotOn::Plugin::_bitrateConfigForClient = sub { 160 }; }

require Plugins::SpotOn::Unified::Daemon;   # load the stub NOW: its lazy load would replace the overrides below
our %TAIL_OF;
{
    no warnings 'redefine';
    # the stub helper answers what startHelper compares an alive helper against, so no restart is provoked
    *Plugins::SpotOn::Unified::Daemon::stderrTail      = sub { return $main::TAIL_OF{ $_[0]->mac } // '' };
    *Plugins::SpotOn::Unified::Daemon::name            = sub { my $c = $Slim::Player::Client::BY_MAC{ $_[0]->mac }; return $c ? $c->name : undef };
    *Plugins::SpotOn::Unified::Daemon::_connectEnabled = sub { return 1 };
    *Plugins::SpotOn::Unified::Daemon::_passthrough    = sub { return 0 };
    *Plugins::SpotOn::Unified::Daemon::_bitrate        = sub { return 160 };
}

my @MACS    = ('aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02', 'aa:bb:cc:dd:ee:03');   # the VM rig has three players
my $REFUSED = $MACS[1];                                                           # vm-flac
my $acct    = 'ACCT0123456789abcdef';
my $tmpCache = tempdir(CLEANUP => 1);
make_path("$tmpCache/spoton/$acct");
open(my $cf, '>', "$tmpCache/spoton/$acct/credentials.json") or die "credentials.json: $!";
print $cf '{"username":"x"}';
close($cf);
local $Slim::Utils::Prefs::FAKE_VALUES{cachedir}              = $tmpCache;
local $Slim::Utils::Prefs::FAKE_VALUES{activeAccount}         = $acct;
local $Slim::Utils::Prefs::FAKE_VALUES{accounts}              = { $acct => { displayName => 'x' } };
local $Slim::Utils::Prefs::FAKE_VALUES{backend}               = 'librespot';
local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat}          = 'pcm';
local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect}  = 1;
%Slim::Utils::Cache::STORE = ();

my @clients = map { FakeClient->new($MACS[$_], "player$_") } 0 .. 2;
@Slim::Player::Client::ALL = @clients;
$Slim::Player::Client::BY_MAC{ $_->id } = $_ for @clients;
$clients[1]{url} = 'spoton://track:2cGxRwrMyEAp8dEbuZaVv6';   # vm-flac plays a Browse title

# every poll and every WARN with the fake time it happened at
my (@POLL_AT, @WARN_AT);
{
    no warnings 'redefine';
    *Slim::Utils::Log::warn = sub { shift; push @WARN_AT, [ $main::NOW, join('', @_) ]; };
}
my $POLL_CB = \&Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll;

# run every timer due up to $until in time order (a timer may arm new ones)
sub run_until {
    my ($until) = @_;
    die 'run_until: the fake clock would run backwards' if $until < $main::NOW;
    while (1) {
        my @due = sort { $a->[1] <=> $b->[1] } grep { $_->[1] <= $until } @Slim::Utils::Timers::TIMERS;
        last unless @due;
        my $t = $due[0];
        @Slim::Utils::Timers::TIMERS = grep { $_ != $t } @Slim::Utils::Timers::TIMERS;
        $main::NOW = $t->[1];
        push @POLL_AT, $main::NOW if $t->[2] == $POLL_CB;
        my ($obj, undef, $cb, @extra) = @$t;
        $cb->($obj, @extra);
    }
    $main::NOW = $until;
}

# W0 = the first initHelpers of the LMS instance (afternoon run: 10:34:12.79; the three daemon_start lines
# 10:34:12.89 / 15.90 / 18.90 show the 3 s stagger)
my $W0 = $NOW;
@Slim::Utils::Timers::TIMERS = ();
Plugins::SpotOn::Unified::DaemonManager::initHelpers();       # W0: helper 1 now, 2 at +3 s, 3 at +6 s
run_until($W0 + 7);

# --- scenario 1: the afternoon retry. The fork writes the marker into vm-flac's stderr 2.8 s before the watchdog.
my $marker_line = marker('09:36:10', 5);
my $W2 = $W0 + 120;                                           # the second 60 s watchdog after W0 (10:36:12.79)
run_until($W2 - 2.8);
$TAIL_OF{$REFUSED} = "noise\n$marker_line";
my $marker1_at = $main::NOW;
run_until($W0 + 170);
my @halt1 = grep { $_->[1] =~ /refused audio keys/ } @WARN_AT;

# --- scenario 2: the morning retry. A new marker line 7.7 s before the next watchdog (W0+180).
my $W3 = $W0 + 180;
run_until($W3 - 7.7);
$TAIL_OF{$REFUSED} = "noise\n$marker_line" . marker('09:39:05', 5);
my $marker2_at = $main::NOW;
run_until($W0 + 200);
my @halt2 = grep { $_->[1] =~ /refused audio keys/ } @WARN_AT;

# ---- assertions -------------------------------------------------------------
ok(scalar(@halt1) >= 1, 'setup: the afternoon marker is reacted to at all');
my $lat1 = @halt1 ? $halt1[0][0] - $marker1_at : 999;
printf "# afternoon phase: marker at W0+%.1f, reacted to at W0+%.1f -> latency %.1f s (a poll interval is 5 s)\n",
    $marker1_at - $W0, @halt1 ? $halt1[0][0] - $W0 : -1, $lat1;
cmp_ok($lat1, '<=', 5.5, 'poll_reacts_within_one_interval: a marker written just after a poll is reacted to by the next poll, also across the 60 s watchdog fan-out of three players');

my ($maxgap, $at) = (0, 0);
for my $i (1 .. $#POLL_AT) { my $g = $POLL_AT[$i] - $POLL_AT[$i-1]; if ($g > $maxgap) { $maxgap = $g; $at = $POLL_AT[$i-1] } }
printf "# %d polls in 200 s (a clean 5 s chain would have 40), longest silence %.1f s after the poll at W0+%.1f\n", scalar(@POLL_AT), $maxgap, $at - $W0;
cmp_ok($maxgap, '<=', 5.5, 'poll_never_silent_longer_than_one_interval: the watchdog fan-out (startHelper on alive helpers) must not postpone a pending poll');

# control: the same code reacts in time when the marker precedes the last poll before the watchdog (the morning phase)
my $lat2 = (@halt2 > @halt1) ? $halt2[-1][0] - $marker2_at : 999;
printf "# morning phase:   marker at W0+%.1f, reacted to at W0+%.1f -> latency %.1f s\n",
    $marker2_at - $W0, (@halt2 > @halt1) ? $halt2[-1][0] - $W0 : -1, $lat2;
cmp_ok($lat2, '<=', 5.5, 'control_morning_phase: a marker 7.7 s before the watchdog is reacted to by the last poll before it (green before 89-08 too, this is why the morning run passed)');

# ---- escape paths of the stamp (cells 10-14) --------------------------------
# 89-08 keeps a due-time stamp for the armed poll tick so that startHelper (the
# 60 s watchdog fan-out) never postpones it. These scenarios pin the ways the
# poll must still start when none runs: after stopHelper removed the last helper
# (10), after the poll ended on an empty registry inside a tick (11, 12) and
# after its timer was lost outside the arm sites (13, 14). Each scenario sits
# between two watchdogs.
my $DMP = 'Plugins::SpotOn::Unified::DaemonManager';
{ no warnings 'redefine'; *Plugins::SpotOn::Unified::Daemon::_stoppedDeliberately = sub { return 0 }; }

sub polls_between { my ($from, $to) = @_; return scalar grep { $_ > $from && $_ <= $to } @POLL_AT }
sub poll_armed    { return scalar grep { $_->[2] == $POLL_CB } @Slim::Utils::Timers::TIMERS }

# --- scenario 3: stopHelper removes the last helper (and ends the poll), a player comes back 1 s later
$DMP->stopHelper($_) for @MACS;
my $restart3 = $main::NOW + 1;
run_until($restart3);
$DMP->startHelper($MACS[0]);
run_until($restart3 + 5.5);
ok(polls_between($restart3, $restart3 + 5.5) >= 1,
    'poll_restarts_after_the_last_helper_stopped: a helper started 1 s after stopHelper removed the last one is polled within one interval');

# --- scenario 4: the poll empties the registry itself (credential crash of the only helper)
my $W4 = $W0 + 240;
run_until($W4 + 10);                                          # the fan-out of W4 restarted all three helpers
$DMP->stopHelper($_) for @MACS[1, 2];                         # one alive helper stays, so the timer stays
my ($crashed) = grep { $_->mac eq $MACS[0] } $DMP->helperInstances;
$crashed->{alive} = 0;
$TAIL_OF{ $MACS[0] } = "Bad credentials\n";
for (1 .. 30) {
    last if !scalar($DMP->helperInstances) && !poll_armed();
    run_until($main::NOW + 1);
}
my $emptyAt = $POLL_AT[-1];
ok(defined $emptyAt && !scalar($DMP->helperInstances) && !poll_armed(),
    q{setup: the poll's credential-crash path emptied the registry, and its next tick returned without re-arming});
Plugins::SpotOn::API::Credentials->clearNeedsPlaybackAuth($acct);   # the user paired again
$TAIL_OF{ $MACS[0] } = '';
run_until($emptyAt + 1);
$DMP->startHelper($MACS[0]);
run_until($emptyAt + 6.5);
ok(polls_between($emptyAt + 1, $emptyAt + 6.5) >= 1,
    'poll_restarts_after_the_registry_emptied: a helper started 1 s after the poll ended on an empty registry is polled within one interval');

# --- scenario 5: the poll timer is lost outside the arm sites
my $W6 = $W0 + 360;
run_until($W0 + 338);                                         # after the fan-out of W5 at W5 + 6; the pending tick is due 17 to 22 s before W6
my ($pending) = grep { $_->[2] == $POLL_CB } @Slim::Utils::Timers::TIMERS;
my $lostDue = $pending ? $pending->[1] : 0;
@Slim::Utils::Timers::TIMERS = grep { $_->[2] != $POLL_CB } @Slim::Utils::Timers::TIMERS;
my $lostAt = $main::NOW;
run_until($W6 + 6);
ok(polls_between($lostAt, $W6) == 0 && $W6 - $lostDue > 2 * 5 && $W6 - $lostDue < 6 * 5,
    'setup: the lost poll timer stays silent up to the next watchdog, which finds its stamp between two and six intervals overdue');
ok(polls_between($W6, $W6 + 5.5) >= 1,
    'poll_restarts_after_a_lost_timer: a poll timer lost outside the arm sites is armed again by the next watchdog fan-out (stamp more than two intervals overdue)');

done_testing();
