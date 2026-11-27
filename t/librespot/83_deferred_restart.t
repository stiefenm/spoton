#!/usr/bin/perl
# 92-03 (GH #232, D-04..D-06): daemon setting changes wait while the player pulls audio
# A saved Connect switch / passthrough format / bitrate used to restart an alive daemon at once and cut the
# playing title; since 92-03 they follow the rule the name change always had (_isStreamActive -> deferred, the
# 60 s watchdog applies it once idle). D-05: Connect OFF while this player holds the Connect claim restarts now.
# The REAL DaemonManager, Backend::Librespot and ProtocolHandler run over the stubs of
# t/librespot/81_stream_poll_cadence.t (header copied verbatim); only LMS and the helper process are fakes.
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
    *main::INFOLOG     = sub () { 1 };
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

# Plugins::SpotOn::Connect: DaemonManager asks it for the claim (D-05). The real module needs half of LMS,
# so a double answers from a package variable; $CLAIMED is set per cell.
write_stub($stub_dir, 'Plugins::SpotOn::Connect', <<'END');
package Plugins::SpotOn::Connect;
our $CLAIMED = 0;
sub isSpotifyConnect { return $CLAIMED ? 1 : 0 }
1;
END

# --- doubles -------------------------------------------------------------
our (@INFOS, @STOPS, @STARTS);
{
    package DRTrack;
    sub new { return bless { url => $_[1] }, $_[0] }
    sub url { return $_[0]{url} }

    package DRSong;
    sub new   { return bless { url => $_[1] }, $_[0] }
    sub track { return DRTrack->new($_[0]{url}) }

    package DRClient;
    sub new {
        my ($class, $mac, $name) = @_;
        return bless { mac => $mac, name => $name, playing => 0 }, $class;
    }
    sub id          { return $_[0]{mac} }
    sub name        { return $_[0]{name} }
    sub isPlaying   { return $_[0]{playing} ? 1 : 0 }
    sub playingSong { return $_[0]{playing} ? DRSong->new('spoton://track:2cGxRwrMyEAp8dEbuZaVv6') : undef }
    sub streamingSong { return undef }
    sub isSynced    { return 0 }
    sub model       { return 'squeezebox' }
    sub master      { return undef }
    sub formats     { return () }

    # a Soloist-flavoured helper: only the name is compared for it
    package DRSoloistHelper;
    sub new         { return bless { mac => $_[1], name => $_[2], alive => 1 }, $_[0] }
    sub mac         { return $_[0]{mac} }
    sub name        { return $_[0]{name} }
    sub alive       { return $_[0]{alive} }
    sub backendName { return 'soloist' }
    sub _lastHealthSession { return undef }
    # a Soloist helper has no librespot spawn values: a call would show up as a die
    sub _connectEnabled { die 'soloist helper asked for _connectEnabled' }
    sub _passthrough    { die 'soloist helper asked for _passthrough' }
    sub _bitrate        { die 'soloist helper asked for _bitrate' }
}

our $WANT_BITRATE = 160;
{
    no warnings 'redefine';
    # server.log INFO lines
    *Slim::Utils::Log::info = sub { shift; push @INFOS, join('', @_); };
    *Plugins::SpotOn::Plugin::_bitrateConfigForClient = sub { return $main::WANT_BITRATE };

    require Plugins::SpotOn::Unified::Daemon;   # load the stub NOW: its lazy load would replace the overrides below
    # the stub helper answers its spawn values from its own hash, so a cell can pick them
    *Plugins::SpotOn::Unified::Daemon::new = sub {
        my ($class, $mac) = @_;
        return bless { mac => $mac, alive => 1, name => undef, connect => 1, passthrough => 0, bitrate => 160, health => undef }, $class;
    };
    *Plugins::SpotOn::Unified::Daemon::start                 = sub { $_[0]->{alive} = 1; return };
    *Plugins::SpotOn::Unified::Daemon::_stoppedDeliberately  = sub { return 0 };
    *Plugins::SpotOn::Unified::Daemon::name                  = sub { return $_[0]{name} };
    *Plugins::SpotOn::Unified::Daemon::_connectEnabled       = sub { return $_[0]{connect} };
    *Plugins::SpotOn::Unified::Daemon::_passthrough          = sub { return $_[0]{passthrough} };
    *Plugins::SpotOn::Unified::Daemon::_bitrate              = sub { return $_[0]{bitrate} };
    *Plugins::SpotOn::Unified::Daemon::_lastHealthSession    = sub { return $_[0]{health} };

    # count every stop / start the manager performs (a pure read must do neither)
    my $origStop = \&Plugins::SpotOn::Unified::DaemonManager::stopHelper;
    *Plugins::SpotOn::Unified::DaemonManager::stopHelper = sub { push @STOPS, $_[1]; return $origStop->(@_); };
}

my $MAC  = 'aa:bb:cc:dd:ee:01';
my $acct = 'ACCT0123456789abcdef';
my $tmpCache = tempdir(CLEANUP => 1);
make_path("$tmpCache/spoton/$acct");
open(my $cf, '>', "$tmpCache/spoton/$acct/credentials.json") or die "credentials.json: $!";
print $cf '{"username":"x"}';
close($cf);
$Slim::Utils::Prefs::FAKE_VALUES{cachedir}              = $tmpCache;
$Slim::Utils::Prefs::FAKE_VALUES{activeAccount}         = $acct;
$Slim::Utils::Prefs::FAKE_VALUES{accounts}              = { $acct => { displayName => 'x' } };
$Slim::Utils::Prefs::FAKE_VALUES{backend}               = 'librespot';
$Slim::Utils::Prefs::FAKE_VALUES{streamFormat}          = 'pcm';
$Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect}  = 1;
%Slim::Utils::Cache::STORE = ();

my $client = DRClient->new($MAC, 'player0');
$Slim::Player::Client::BY_MAC{$MAC} = $client;

# A fresh alive helper spawned with name N, Connect 1, passthrough 0, bitrate 320 (the wanted ones are
# N, 1, 0, 160 unless a cell changes a pref), the client idle, nothing logged.
sub fresh_helper {
    my (%o) = @_;
    $DM->stopHelper($MAC);
    @Slim::Utils::Timers::TIMERS = ();
    $DM->startHelper($MAC);                      # registers a stub helper (new)
    my $h = $DM->helperForClient($client) or die 'no helper registered';
    $h->{name}        = $o{name}        // 'player0';
    $h->{connect}     = $o{connect}     // 1;
    $h->{passthrough} = $o{passthrough} // 0;
    $h->{bitrate}     = $o{bitrate}     // 160;
    $h->{health}      = $o{health};
    $client->{playing} = $o{playing} ? 1 : 0;
    $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = $o{wantConnect} // 1;
    $Slim::Utils::Prefs::FAKE_VALUES{streamFormat}         = $o{wantFormat}  // 'pcm';
    $WANT_BITRATE = $o{wantBitrate} // 160;
    $Plugins::SpotOn::Connect::CLAIMED = $o{claimed} ? 1 : 0;
    @INFOS = (); @STOPS = ();
    return $h;
}

# A missing sub must show up as a failing cell (not ok), never as a die that hides every later cell.
sub pending { my ($h) = @_; my %r = eval { $DM->_pendingChanges($h, $client) }; return $@ ? { DIED => "$@" } : \%r }
sub deferral_lines { my ($what) = @_; return scalar grep { /^\Q$what\E change for \Q$MAC\E deferred - stream active; watchdog will retry$/ } @INFOS }
sub restart_lines  { my ($what) = @_; return scalar grep { /^\Q$what\E changed for \Q$MAC\E .* - restarting daemon/ } @INFOS }

# ============================================================
# Task 1: one comparison site _pendingChanges, bitrate through the guard
# ============================================================
{
    my $h = fresh_helper(bitrate => 320, wantBitrate => 160);
    my $before = scalar(@INFOS);
    my $got = pending($h);
    is_deeply($got, { bitrate => 160 }, 'PC-1: _pendingChanges answers exactly the bitrate that differs');
    is(scalar(@STOPS), 0, 'PC-1: _pendingChanges stops nothing');
    is(scalar(@INFOS), 0, 'PC-1: _pendingChanges logs nothing');
    ok($DM->helperForClient($client) == $h, 'PC-1: _pendingChanges leaves the helper registered');

    $h->{bitrate} = 160;
    is_deeply(pending($h), {}, 'PC-1: all values equal -> an empty hash');

    # the other three keys, each on its own
    $h->{name} = 'old name';
    is_deeply(pending($h), { name => 'player0' }, 'PC-1: name differs -> { name => <wanted> }');
    $h->{name} = 'player0'; $h->{connect} = 0;
    is_deeply(pending($h), { connect => 1 }, 'PC-1: Connect switch differs -> { connect => <wanted> }');
    $h->{connect} = 1; $h->{passthrough} = 1;
    is_deeply(pending($h), { passthrough => 0 }, 'PC-1: format differs -> { passthrough => <wanted> }');
}

{
    my $sh = DRSoloistHelper->new($MAC, 'player0');
    is_deeply(pending($sh), {}, 'PC-2: a Soloist helper with the wanted name -> empty, the librespot accessors are never asked');
    $sh->{name} = 'old name';
    is_deeply(pending($sh), { name => 'player0' }, 'PC-2: a Soloist helper compares the name only');
    $WANT_BITRATE = 320;
    is_deeply(pending($sh), { name => 'player0' }, 'PC-2: whatever the librespot accessors say');
    $WANT_BITRATE = 160;
}

{   # DR-1: bitrate changed while the client plays a spoton title -> deferred, helper kept
    my $h = fresh_helper(bitrate => 320, wantBitrate => 160, playing => 1);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-1: the helper is kept (same instance)');
    is(scalar(@STOPS), 0, 'DR-1: stopHelper not called');
    is(deferral_lines('Bitrate'), 1, 'DR-1: one deferral INFO line');
    is(restart_lines('Bitrate'), 0, 'DR-1: no restart line');
}

{   # DR-2: client stopped, no fresh health snapshot -> restarted now
    my $h = fresh_helper(bitrate => 320, wantBitrate => 160, playing => 0);
    $DM->startHelper($MAC);
    is(scalar(@STOPS), 1, 'DR-2: stopHelper called once');
    ok($DM->helperForClient($client) != $h, 'DR-2: the old helper is replaced');
    is(restart_lines('Bitrate'), 1, 'DR-2: the existing restart line');
    is(deferral_lines('Bitrate'), 0, 'DR-2: no deferral line');
}

{   # DR-3: bitrate unchanged and stream active -> neither deferral nor restart
    my $h = fresh_helper(bitrate => 160, wantBitrate => 160, playing => 1);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-3: the helper is kept');
    is(scalar(@STOPS), 0, 'DR-3: stopHelper not called');
    is(scalar(grep { /deferred|restarting/ } @INFOS), 0, 'DR-3: no deferral and no restart line every tick');
}

# ============================================================
# Task 2: Connect switch and passthrough format through the same guard; D-05; served format pinned
# ============================================================
{   # DR-4: Connect wanted ON (was OFF), stream active -> deferred
    my $h = fresh_helper(connect => 0, wantConnect => 1, playing => 1);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-4: the helper is kept');
    is(scalar(@STOPS), 0, 'DR-4: stopHelper not called');
    is(deferral_lines('Connect toggle'), 1, 'DR-4: one Connect toggle deferral line');
}

{   # DR-5: Connect wanted OFF, stream active, no claim (Browse only) -> deferred
    my $h = fresh_helper(connect => 1, wantConnect => 0, playing => 1, claimed => 0);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-5: Connect OFF without the claim: the helper is kept');
    is(scalar(@STOPS), 0, 'DR-5: stopHelper not called');
    is(deferral_lines('Connect toggle'), 1, 'DR-5: one Connect toggle deferral line');
}

{   # DR-6 (D-05): Connect wanted OFF, stream active, the claim is held -> restart now
    my $h = fresh_helper(connect => 1, wantConnect => 0, playing => 1, claimed => 1);
    $DM->startHelper($MAC);
    is(scalar(@STOPS), 1, 'DR-6: D-05 - Connect OFF with the claim held stops the daemon at once');
    ok($DM->helperForClient($client) != $h, 'DR-6: the old helper is replaced');
    is(scalar(grep { /^Connect toggle changed for \Q$MAC\E \(was 1, now 0\) - Connect session active, restarting now \(D-05\)$/ } @INFOS), 1,
        'DR-6: the restart line names the Connect session (D-05)');
    is(deferral_lines('Connect toggle'), 0, 'DR-6: no deferral line');
}

{   # DR-6b: Connect ON with the claim held is not the D-05 case (the claim does not matter there)
    my $h = fresh_helper(connect => 0, wantConnect => 1, playing => 1, claimed => 1);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-6b: Connect ON waits even with the claim held');
    is(deferral_lines('Connect toggle'), 1, 'DR-6b: deferral line');
}

{   # DR-6c: Connect switch idle -> restarted by the ordinary rule
    my $h = fresh_helper(connect => 0, wantConnect => 1, playing => 0);
    $DM->startHelper($MAC);
    is(scalar(@STOPS), 1, 'DR-6c: idle Connect switch change restarts');
    is(restart_lines('Connect toggle'), 1, 'DR-6c: the existing restart line');
}

{   # DR-7: passthrough wanted 1 (was 0): deferred while active, restarted when idle
    my $h = fresh_helper(passthrough => 0, wantFormat => 'ogg', playing => 1);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-7: stream active - the helper is kept');
    is(scalar(@STOPS), 0, 'DR-7: stopHelper not called');
    is(deferral_lines('Passthrough format'), 1, 'DR-7: one Passthrough format deferral line');

    # DR-9 (D-04 format): during the deferral LMS keeps the running daemon's format
    is($DM->resolvePassthroughForClient($client), 1, 'DR-9: setup - the saved pref resolves to passthrough');
    is($DM->resolveServedPassthroughForClient($client), 0, 'DR-9: the served format is the running helper\'s flag (0), not the pref');
    my ($type) = $PH->contentTypeFor($client);
    is($type, 'soc', 'DR-9: contentTypeFor keeps the PCM content type of the running daemon');

    my $h2 = fresh_helper(passthrough => 0, wantFormat => 'ogg', playing => 0);
    $DM->startHelper($MAC);
    is(scalar(@STOPS), 1, 'DR-7: idle - the passthrough change restarts');
    is(restart_lines('Passthrough format'), 1, 'DR-7: the existing restart line');
}

{   # DR-8: two changes at once while active -> both deferred, no stop
    my $h = fresh_helper(passthrough => 0, wantFormat => 'ogg', bitrate => 320, wantBitrate => 160, playing => 1);
    $DM->startHelper($MAC);
    ok($DM->helperForClient($client) == $h, 'DR-8: the helper is kept');
    is(scalar(@STOPS), 0, 'DR-8: stopHelper never called');
    is(deferral_lines('Passthrough format'), 1, 'DR-8: passthrough deferred');
    is(deferral_lines('Bitrate'), 1, 'DR-8: bitrate deferred');
}

# ============================================================
# Task 3: pendingRestartReasons (pure read) and the wording keys of the settings-page note
# ============================================================
our @STARTS_SEEN;
{
    no warnings 'redefine';
    my $origStart = \&Plugins::SpotOn::Unified::DaemonManager::startHelper;
    *Plugins::SpotOn::Unified::DaemonManager::startHelper = sub { push @STARTS_SEEN, $_[1]; return $origStart->(@_); };
}
sub reasons { my @r = eval { $DM->pendingRestartReasons($client) }; return $@ ? [ "DIED: $@" ] : \@r }

{   # PR-1: live branch / snapshot branch / neither / no helper; never stops or starts
    my $h = fresh_helper(bitrate => 320, wantBitrate => 160, playing => 1);
    @STARTS_SEEN = ();
    is_deeply(reasons(), [ { branch => 'live', reasons => ['bitrate'] } ],
        'PR-1: a SpotOn title plays and the bitrate differs -> live branch, reasons [bitrate]');

    $h = fresh_helper(bitrate => 320, wantBitrate => 160, playing => 0, health => { idle_secs => 10, checked_at => time() });
    @STARTS_SEEN = ();
    is_deeply(reasons(), [ { branch => 'snapshot', reasons => ['bitrate'] } ],
        'PR-1: nothing plays but the fresh health snapshot counts the daemon as busy -> snapshot branch');

    $h = fresh_helper(bitrate => 320, wantBitrate => 160, playing => 0);
    @STARTS_SEEN = ();
    is_deeply(reasons(), [], 'PR-1: neither live nor snapshot -> nothing (the watchdog restarts it, no note)');

    $h = fresh_helper(bitrate => 160, wantBitrate => 160, playing => 1);
    is_deeply(reasons(), [], 'PR-1: nothing differs -> nothing');

    $DM->stopHelper($MAC);
    @STOPS = (); @STARTS_SEEN = ();
    is_deeply(reasons(), [], 'PR-1: no helper alive -> nothing');

    $h = fresh_helper(bitrate => 320, wantBitrate => 160, playing => 1);
    @STARTS_SEEN = ();
    my $r = reasons();
    is(scalar(@STOPS), 0,        'PR-1: the predicate never calls stopHelper');
    is(scalar(@STARTS_SEEN), 0,  'PR-1: the predicate never calls startHelper');
    ok($DM->helperForClient($client) == $h, 'PR-1: the helper stays registered');
}

{   # PR-2: D-05 is not a pending note; other reasons stay
    my $h = fresh_helper(connect => 1, wantConnect => 0, playing => 1, claimed => 1);
    is_deeply(reasons(), [], 'PR-2: Connect OFF with the claim held restarts at once -> no note');

    $h = fresh_helper(connect => 1, wantConnect => 0, playing => 1, claimed => 0);
    is_deeply(reasons(), [ { branch => 'live', reasons => ['connect'] } ], 'PR-2: Connect OFF without the claim waits -> note');

    $h = fresh_helper(connect => 1, wantConnect => 0, bitrate => 320, wantBitrate => 160, playing => 1, claimed => 1);
    # 92-08 WR-02: startHelper stops the whole daemon in the D-05 case (the fresh spawn carries every wanted value),
    # so nothing waits and no "keeps playing" note may be shown, whatever else changed
    is_deeply(reasons(), [], 'PR-2: Connect OFF with the claim AND a bitrate change -> no note (D-05 restarts the whole daemon now)');
}

# 92-08 WR-01: a synced slave's settings page asks about the daemon of the sync MASTER. The daemon belongs to the
# player it was spawned for, so the comparison runs against that player, not against the slave.
{
    package DRSyncedClient;
    our @ISA = ('DRClient');
    sub new {
        my ($class, $mac, $name, $master) = @_;
        my $self = DRClient::new($class, $mac, $name);
        $self->{master} = $master;
        return $self;
    }
    sub isSynced { return 1 }
    sub master   { return $_[0]{master} || $_[0] }
}
{   # PR-6: synced slave
    my ($MM, $SM) = ('aa:bb:cc:dd:ee:02', 'aa:bb:cc:dd:ee:03');
    my $master = DRSyncedClient->new($MM, 'player0');
    my $slave  = DRSyncedClient->new($SM, 'kitchen', $master);
    $Slim::Player::Client::BY_MAC{$MM} = $master;
    $Slim::Player::Client::BY_MAC{$SM} = $slave;
    $DM->stopHelper($MM);
    $DM->startHelper($MM);                       # the stub helper lives under the master MAC
    my $h = $DM->helperForClient($master) or die 'no helper for the sync master';
    $h->{name} = $DM->deviceNameForClient($master);
    $h->{connect} = 1; $h->{passthrough} = 0; $h->{bitrate} = 160; $h->{health} = undef;
    $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    $Slim::Utils::Prefs::FAKE_VALUES{streamFormat}         = 'pcm';
    $WANT_BITRATE = 160;
    $Plugins::SpotOn::Connect::CLAIMED = 0;
    $master->{playing} = 1; $slave->{playing} = 1;
    @STOPS = (); @STARTS_SEEN = ();

    my @rm = eval { $DM->pendingRestartReasons($master) };
    my @rs = eval { $DM->pendingRestartReasons($slave) };
    is_deeply(\@rm, [], 'PR-6: nothing changed, the group plays -> no note on the sync master');
    ok($DM->helperForClient($slave) == $h, 'PR-6: the slave resolves to the master daemon (sync fallback)');
    is_deeply(\@rs, [], 'PR-6: nothing changed, the group plays -> no note on the synced slave either (WR-01)');

    $h->{bitrate} = 320;                         # a real pending change of the daemon
    @rs = eval { $DM->pendingRestartReasons($slave) };
    is_deeply(\@rs, [ { branch => 'live', reasons => ['bitrate'] } ], 'PR-6: a real pending change is still shown on the slave');
    is(scalar(@STOPS) + scalar(@STARTS_SEEN), 0, 'PR-6: the predicate stops and starts nothing');

    $DM->stopHelper($MM);
    delete $Slim::Player::Client::BY_MAC{$MM}; delete $Slim::Player::Client::BY_MAC{$SM};
    @STOPS = (); @STARTS_SEEN = ();
}

{   # PR-3: name; Soloist helper ignores its librespot accessors
    my $h = fresh_helper(name => 'old name', playing => 1);
    is_deeply(reasons(), [ { branch => 'live', reasons => ['name'] } ], 'PR-3: name differs and the stream is active -> [name]');

    my $sh = DRSoloistHelper->new($MAC, 'old name');
    $client->{playing} = 1;
    $WANT_BITRATE = 320;
    my @r = do { no warnings 'redefine'; local *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { return $sh }; eval { $DM->pendingRestartReasons($client) } };
    is_deeply(\@r, [ { branch => 'live', reasons => ['name'] } ], 'PR-3: a Soloist helper -> [name] only');
    $WANT_BITRATE = 160;
}

# PR-5: template, strings, wording
{
    my $html = do { open(my $fh, '<', "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html") or die "player.html: $!"; local $/; <$fh> };
    like($html, qr/\[% IF restartDeferred == 'live' %\]\s*<p[^>]*>\[% 'PLUGIN_SPOTON_PLAYER_RESTART_DEFERRED_LIVE' \| string %\]<\/p>\s*\[% ELSIF restartDeferred %\]\s*<p[^>]*>\[% 'PLUGIN_SPOTON_PLAYER_RESTART_DEFERRED_IDLE' \| string %\]<\/p>\s*\[% END %\]/,
        'PR-5: player.html shows the LIVE wording for restartDeferred == live and the IDLE wording otherwise');

    my $str = do { open(my $fh, '<:encoding(UTF-8)', "$project_dir/Plugins/SpotOn/strings.txt") or die "strings.txt: $!"; local $/; <$fh> };
    my @langs = qw(CS DA DE EN ES FR IT NL NO PL SV);
    for my $k (qw(PLUGIN_SPOTON_PLAYER_RESTART_DEFERRED_LIVE PLUGIN_SPOTON_PLAYER_RESTART_DEFERRED_IDLE)) {
        my ($block) = $str =~ /^\Q$k\E\n((?:\t[A-Z]{2}\t[^\n]*\n)+)/m;
        ok(defined $block, "PR-5: strings.txt has $k") or next;
        my @have = $block =~ /^\t([A-Z]{2})\t/mg;
        is(join(',', @have), join(',', @langs), "PR-5: $k carries the 11 languages in file order");
        unlike($block, qr/\x{2014}|\x{2013}/, "PR-5: $k has no long or medium dash");
        unlike($block, qr/once playback/i, "PR-5: $k does not promise 'once playback'");
    }
    my ($live) = $str =~ /^PLUGIN_SPOTON_PLAYER_RESTART_DEFERRED_LIVE\n((?:\t[A-Z]{2}\t[^\n]*\n)+)/m;
    my ($idle) = $str =~ /^PLUGIN_SPOTON_PLAYER_RESTART_DEFERRED_IDLE\n((?:\t[A-Z]{2}\t[^\n]*\n)+)/m;
    like($live // '', qr/^\tEN\tA saved change is waiting: the title playing now keeps playing, and the change is applied after a few minutes without playback on this player\.$/m, 'PR-5: LIVE EN text');
    like($idle // '', qr/^\tEN\tA saved change is waiting: it is applied after a few minutes without playback on this player\.$/m, 'PR-5: IDLE EN text');
    unlike($idle // '', qr/\bplaying\b|spielt|title|Titel/i, 'PR-5: the IDLE wording names no playing title');
}

# ======== end of Task 1 cells ========

done_testing();
