#!/usr/bin/perl
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
    sub new       { return bless { url => $_[1], stream => $_[2] }, $_[0] }
    sub track     { return FakeTrack->new($_[0]{url}) }
    sub streamUrl { return $_[0]{stream} }

    package FakeClient;
    sub new {
        my ($class, $mac, $name) = @_;
        return bless { mac => $mac, name => $name, url => undef, exec => [], brief => [] }, $class;
    }
    sub id            { return $_[0]{mac} }
    sub name          { return $_[0]{name} }
    sub streamingSong { return $_[0]{url} ? FakeSong->new($_[0]{url}, $_[0]{stream}) : undef }
    sub playingSong   { return undef }
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

# --- lastAudioKeyLine ----------------------------------------------------
{
    my $a = marker('10:00:00', 5);
    my $b = marker('10:00:07', 6);
    is((lal("noise\n$a$b", 'halt') // '') . "\n", $b, 'lastAudioKeyLine halt: two marker lines -> the second whole line');
    is(lal("noise\nmore noise\n", 'halt'), undef, 'lastAudioKeyLine halt: no marker -> undef');
    is(lal(undef, 'halt'), undef, 'lastAudioKeyLine halt: undef text -> undef');
    is(lal("x error audio key 0 1 first\ny error audio key 0 2\nz error audio key 0 1 last\n", 'denied'),
        'z error audio key 0 1 last', 'lastAudioKeyLine denied: the last "error audio key 0 1" line');
    is(lal("error audio key 0 2\n", 'denied'), undef, 'lastAudioKeyLine denied: code 2 is no denial');
    my $long = marker('10:00:09', 5);
    chomp $long;
    $long .= 'x' x 400;
    is(length(lal("$long\n", 'halt')), 300, 'lastAudioKeyLine: a 400+ character line comes back as 300 characters');
    is(lal("$a", 'bogus'), undef, 'lastAudioKeyLine: unknown kind -> undef');
}

# --- the poll over a registered stub daemon ------------------------------
{
    my $mac  = 'aa:bb:cc:dd:ee:79';
    my $acct = 'ACCT0123456789abcdef';
    my $tmpCache = tempdir(CLEANUP => 1);
    make_path("$tmpCache/spoton/$acct");
    open(my $cf, '>', "$tmpCache/spoton/$acct/credentials.json") or die "credentials.json: $!";
    print $cf '{"username":"x"}';
    close($cf);

    local $Slim::Utils::Prefs::FAKE_VALUES{cachedir}      = $tmpCache;
    local $Slim::Utils::Prefs::FAKE_VALUES{activeAccount} = $acct;
    local $Slim::Utils::Prefs::FAKE_VALUES{accounts}      = { $acct => { displayName => 'x' } };
    local $Slim::Utils::Prefs::FAKE_VALUES{backend}       = 'librespot';
    %Slim::Utils::Cache::STORE = ();

    my $helper = $DM->startHelper($mac);
    ok($helper && $helper->mac eq $mac, 'setup: startHelper registered a stub daemon for the poll');

    my $client = FakeClient->new($mac, 'Kitchen');
    $Slim::Player::Client::BY_MAC{$mac} = $client;

    my $reset = sub { @EVENTS = (); @WARNS = (); $client->{exec} = []; $client->{brief} = []; @Slim::Utils::Timers::KILL_CALLS = (); };
    my $poll  = sub {
        my ($tail) = @_;
        local $Plugins::SpotOn::Unified::Daemon::TAIL = $tail;
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
        return;
    };
    my $stops = sub { scalar grep { $_ eq 'exec:stop' } @EVENTS };
    my @haltWarns = (sub { grep { /refused audio keys/ } @WARNS });

    # browse_stops_once_per_marker
    $client->{url} = 'spoton://track:4uLU6hMCjMI75M1A2tKUQC';
    $reset->();
    my $m1 = marker('10:00:00', 5);
    $poll->($m1);
    is($stops->(), 1, 'browse_stops_once_per_marker: exactly one LMS stop');
    my @kills = grep { /^kill:/ } @EVENTS;
    is_deeply([ sort @kills ], [ sort("kill:$mac:_retryStream", "kill:$mac:_skipUnavailable") ],
        'browse_stops_once_per_marker: _retryStream and _skipUnavailable timers cancelled on that client');
    my ($stopAt) = grep { $EVENTS[$_] eq 'exec:stop' } 0 .. $#EVENTS;
    my @killAt = grep { $EVENTS[$_] =~ /^kill:/ } 0 .. $#EVENTS;
    ok((@killAt == 2 && defined $stopAt && !grep { $_ > $stopAt } @killAt), 'browse_stops_once_per_marker: both timer cancels come before the stop');
    is(scalar @{ $client->{brief} }, 1, 'browse_stops_once_per_marker: one showBriefly');
    my ($args, $opts) = @{ $client->{brief}[0] || [{}, {}] };
    is_deeply($args->{line}, [ $L1, $L2 ], 'browse_stops_once_per_marker: line carries L1 and L2');
    is($args->{jive}{type}, 'popupplay', 'browse_stops_once_per_marker: jive type popupplay');
    is_deeply($args->{jive}{text}, [ $L1, $L2 ], 'browse_stops_once_per_marker: jive text carries L1 and L2');
    is($opts->{duration}, 6, 'browse_stops_once_per_marker: duration 6');
    my @w = grep { /refused audio keys/ } @WARNS;
    is(scalar @w, 1, 'browse_stops_once_per_marker: one server.log warn');
    like($w[0] // '', qr/^SpotOn: player Kitchen stopped after 5 tracks in a row with refused audio keys - the account playing on it cannot play with librespot\. /,
        'browse_stops_once_per_marker: warn names player, stopped, count');
    unlike($w[0] // '', qr/ACCT|\*\*\*\*|https?:/, 'browse_stops_once_per_marker: no account id, no link in the warn');

    # same_tail_again_does_nothing
    $reset->();
    $poll->($m1);
    is($stops->(), 0, 'same_tail_again_does_nothing: no stop');
    is(scalar @{ $client->{brief} }, 0, 'same_tail_again_does_nothing: no popup');
    is(scalar(grep { /refused audio keys/ } @WARNS), 0, 'same_tail_again_does_nothing: no warn');

    # new_marker_acts_again
    $reset->();
    $poll->($m1 . marker('10:00:12', 5));
    is($stops->(), 1, 'new_marker_acts_again: one more stop');
    is(scalar @{ $client->{brief} }, 1, 'new_marker_acts_again: one more popup');
    is(scalar(grep { /refused audio keys/ } @WARNS), 1, 'new_marker_acts_again: one more warn');

    # episode_url_is_browse
    $client->{url} = 'spoton://episode:1234567890abcdefABCDEF';
    $reset->();
    $poll->(marker('10:01:00', 5));
    is($stops->(), 1, 'episode_url_is_browse: an episode is stopped like a track');

    # connect_url_is_not_stopped
    $client->{url} = 'spoton://connect-aa-bb-cc-dd-ee-79';
    $reset->();
    $poll->(marker('10:02:00', 7));
    is($stops->(), 0, 'connect_url_is_not_stopped: no LMS stop');
    is(scalar(grep { /^kill:/ } @EVENTS), 0, 'connect_url_is_not_stopped: no killTimers on the client');
    is(scalar @{ $client->{brief} }, 1, 'connect_url_is_not_stopped: the popup still shows');
    @w = grep { /refused audio keys/ } @WARNS;
    is(scalar @w, 1, 'connect_url_is_not_stopped: one warn');
    like($w[0] // '', qr/^SpotOn: player Kitchen paused after 7 tracks in a row with refused audio keys - /, 'connect_url_is_not_stopped: warn says paused after 7 tracks');

    # 89 review WR-01: a dead Connect history entry translated to Browse (88-06,
    # ProtocolHandler::_openDeadConnectUrl sets streamUrl spoton://track:<id>) is
    # Browse playback, as in Connect.pm _playsOwnLiveConnectStream: it is stopped.
    $client->{url}    = 'spoton://connect-1763000000';
    $client->{stream} = 'spoton://track:4uLU6hMCjMI75M1A2tKUQC';
    $reset->();
    $poll->(marker('10:02:15', 5));
    is($stops->(), 1, 'translated_connect_entry_is_browse: exactly one LMS stop');
    is_deeply([ sort grep { /^kill:/ } @EVENTS ], [ sort("kill:$mac:_retryStream", "kill:$mac:_skipUnavailable") ],
        'translated_connect_entry_is_browse: retry and skip timers cancelled on that client');
    @w = grep { /refused audio keys/ } @WARNS;
    like($w[0] // '', qr/^SpotOn: player Kitchen stopped after 5 tracks in a row/, 'translated_connect_entry_is_browse: warn says stopped');
    delete $client->{stream};

    # no stream song at all: popup and warn, no stop (not a Browse URL)
    $client->{url} = undef;
    $reset->();
    $poll->(marker('10:02:30', 5));
    is($stops->(), 0, 'no song: nothing to stop');
    is(scalar(grep { /refused audio keys/ } @WARNS), 1, 'no song: still one warn');

    # no_client_still_logs
    delete $Slim::Player::Client::BY_MAC{$mac};
    $reset->();
    my $died = !eval { $poll->(marker('10:03:00', 5)); 1 };
    ok(!$died, 'no_client_still_logs: no die');
    @w = grep { /refused audio keys/ } @WARNS;
    is(scalar @w, 1, 'no_client_still_logs: the warn is logged');
    like($w[0] // '', qr/^SpotOn: player \Q$mac\E paused after 5 tracks/, 'no_client_still_logs: the mac stands in for the name');
    $Slim::Player::Client::BY_MAC{$mac} = $client;

    # advice_by_platform
    my $A_MAC  = 'There is no way out on this system (macOS or Windows). On a Linux server this account plays with the Soloist backend, for example LMS in Docker, in a VM or on a small Linux machine.';
    my $A_SOLO = 'Select the Soloist backend in the SpotOn settings.';
    my $A_NONE = 'Soloist is not available on this system.';
    {
        package FakeRole; our $FIT = 1; sub platformFit { return $FIT }
    }
    my $advice_warn = sub {
        my ($ts) = @_;
        $reset->();
        $poll->(marker($ts, 5));
        my ($x) = grep { /refused audio keys/ } @WARNS;
        return $x // '';
    };
    {
        no warnings 'redefine';
        local $main::FAKE_ISMAC = 1;
        like($advice_warn->('10:04:00'), qr/\Q$A_MAC\E$/, 'advice_by_platform: macOS -> the no-way-out text, last in the warn');
        is(adv(), 'linux_server', 'advice_by_platform: macOS -> linux_server');
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::available = sub { return ('librespot', 'soloist') };
        local *Plugins::SpotOn::Backend::classFor  = sub { return 'FakeRole' };
        local $FakeRole::FIT = 1;
        like($advice_warn->('10:05:00'), qr/\Q$A_SOLO\E$/, 'advice_by_platform: Linux, soloist available and fit -> the select-Soloist text');
        is(adv(), 'soloist', 'advice_by_platform: soloist');
        $FakeRole::FIT = 0;
        like($advice_warn->('10:06:00'), qr/\Q$A_NONE\E$/, 'advice_by_platform: Linux, soloist available but platformFit false -> unavailable text');
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::available = sub { return ('librespot') };
        local *Plugins::SpotOn::Backend::classFor  = sub { return 'FakeRole' };
        local $FakeRole::FIT = 1;
        like($advice_warn->('10:07:00'), qr/\Q$A_NONE\E$/, 'advice_by_platform: Linux without soloist in available() -> unavailable text');
        is(adv(), 'unavailable', 'advice_by_platform: unavailable');
    }
    is(advtext('soloist'),      $A_SOLO, 'audioKeyAdviceText: soloist');
    is(advtext('linux_server'), $A_MAC,  'audioKeyAdviceText: linux_server');
    is(advtext('unavailable'),  $A_NONE, 'audioKeyAdviceText: unavailable');
    is(advtext('whatever'),     $A_NONE, 'audioKeyAdviceText: unknown value -> the unavailable sentence');

    # D-07: no fail-fast, the marker handling stores nothing a later play could read
    ok(!(grep { /audiokey/ } keys %Slim::Utils::Cache::STORE), 'D-07: the marker handling writes no audio-key cache key');

    # cancelBrowseRetries resets the per-client retry counter and the timers (the real ProtocolHandler)
    {
        my $c2 = FakeClient->new('aa:bb:cc:dd:ee:7a', 'Den');
        my $url = 'http://127.0.0.1:4242/track/4uLU6hMCjMI75M1A2tKUQC';
        @WARNS = ();
        @Slim::Utils::Timers::TIMERS = ();
        $PH->handleDirectError($c2, $url, 404, 'HTTP/1.0 404');
        $PH->handleDirectError($c2, $url, 404, 'HTTP/1.0 404');
        like(join("\n", @WARNS), qr{retry 2/3}, 'cancelBrowseRetries setup: two 404s count to retry 2/3');
        eval { $PH->cancelBrowseRetries($c2) };
        is(scalar(grep { $_->[0] eq $c2 } @Slim::Utils::Timers::TIMERS), 0, 'cancelBrowseRetries: the pending retry timer is gone');
        @WARNS = ();
        $PH->handleDirectError($c2, $url, 404, 'HTTP/1.0 404');
        like(join("\n", @WARNS), qr{retry 1/3}, 'cancelBrowseRetries: the retry counter starts again at 1');
        eval { $PH->cancelBrowseRetries($c2) };
    }

    $DM->stopHelper($mac);
    %Slim::Utils::Cache::STORE = ();
}

# --- the fork's RUST_LOG lets the marker through --------------------------
{
    my $daemon = do { local (@ARGV, $/) = ("$project_dir/Plugins/SpotOn/Unified/Daemon.pm"); <> };
    like($daemon, qr/'spoton=info,librespot=warn'/, "rust_log_lets_the_marker_through: Daemon.pm keeps the 'spoton=info,librespot=warn' filter (89-03 pins the helper side)");
}

# --- player strings --------------------------------------------------------
{
    my $raw = do { open(my $fh, '<:encoding(UTF-8)', "$project_dir/Plugins/SpotOn/strings.txt") or die "strings.txt: $!"; local $/; <$fh> };
    my @langs = qw(CS DA DE EN ES FR IT NL NO PL SV);
    for my $key ($L1, $L2) {
        my ($block) = $raw =~ /^\Q$key\E\r?\n((?:\t.*\r?\n?)+)/m;
        ok(defined $block, "player_strings: $key exists");
        my %t = map { /^\t(\w+)\t(.*?)\r?$/ ? ($1 => $2) : () } split /\n/, ($block // '');
        is_deeply([ sort keys %t ], [ sort @langs ], "player_strings: $key has exactly the eleven languages");
        my $max = $key eq $L1 ? 48 : 32;
        my @long = grep { length($t{$_}) > $max } keys %t;
        is_deeply(\@long, [], "player_strings: $key at most $max code points in every language");
        my @dash = grep { $t{$_} =~ /[\x{2013}\x{2014}]/ } keys %t;
        is_deeply(\@dash, [], "player_strings: $key has no en or em dash");
        my @empty = grep { $t{$_} !~ /\S/ } keys %t;
        is_deeply(\@empty, [], "player_strings: $key has no empty text");
    }
    my ($b1) = $raw =~ /^\Q$L1\E\r?\n((?:\t.*\r?\n?)+)/m;
    my ($b2) = $raw =~ /^\Q$L2\E\r?\n((?:\t.*\r?\n?)+)/m;
    like($b1 // '', qr/^\tEN\tSpotify: this account cannot play here$/m, 'player_strings: L1 EN text exact');
    like($b2 // '', qr/^\tEN\tSee SpotOn settings$/m, 'player_strings: L2 EN text exact');
    like($b1 // '', qr/^\tDE\tSpotify: Dieses Konto kann hier nicht spielen$/m, 'player_strings: L1 DE text exact');
    like($b2 // '', qr/^\tDE\tSiehe SpotOn-Einstellungen$/m, 'player_strings: L2 DE text exact');
}

# --- 89-12: the stop message reaches Material Skin ----------------------------
# Gap of the 89-05 eye check (2026-11-19): the message went out through
# showBriefly only, which Material has not shown since 2.10.2. _onAudioKeyHalt is
# called directly with a helper double. Material is "enabled" through the two LMS
# entry points Plugins::SpotOn::PlayerMessage asks, both doubles of this block:
# Slim::Utils::PluginManager->isEnabled and Slim::Control::Request::notifyFromArray.
{
    package Helper12;
    sub new { return bless { mac => $_[1] }, $_[0] }
    sub mac { return $_[0]{mac} }
}
{
    my $mac    = 'aa:bb:cc:dd:ee:12';
    my $client = FakeClient->new($mac, 'Study');
    local $Slim::Player::Client::BY_MAC{$mac} = $client;

    my (@notes, $material);
    no warnings 'redefine';
    local *Slim::Utils::PluginManager::isEnabled   = sub { return ($_[1] // '') eq 'Plugins::MaterialSkin::Plugin' ? $material : undef };
    local *Slim::Control::Request::notifyFromArray = sub { push @notes, [@_]; return };

    my $halt = sub {
        my ($ts, $url) = @_;
        @notes = (); @WARNS = (); @EVENTS = ();
        $client->{brief} = []; $client->{exec} = []; $client->{url} = $url;
        my $ok = eval { Plugins::SpotOn::Unified::DaemonManager::_onAudioKeyHalt(Helper12->new($mac), marker($ts, 5)); 1 };
        return $ok ? '' : ($@ || 'died');
    };
    my $BROWSE  = 'spoton://track:4uLU6hMCjMI75M1A2tKUQC';
    my $CONNECT = 'spoton://connect-aa-bb-cc-dd-ee-12';

    $material = { version => '6.4.9' };
    is($halt->('10:12:00', $BROWSE), '', 'halt_material_no_die: the stop runs through with Material enabled');
    is(scalar @notes, 1, 'halt_material_one_notification: the stop sends one Material notification');
    is_deeply($notes[0], [ undef, [ 'material-skin', 'notification', 'info', "$L1 - $L2", undef, $mac, 15 ] ],
        'halt_material_shape: both lines joined for that player, 15 s, as info for Material 6.4.9');
    my ($args, $opts) = @{ $client->{brief}[0] || [ {}, {} ] };
    is_deeply([ scalar @{ $client->{brief} }, $args->{line}, $args->{jive}, $opts ],
        [ 1, [ $L1, $L2 ], { type => 'popupplay', text => [ $L1, $L2 ] }, { duration => 6 } ],
        'halt_material_keeps_the_display: one showBriefly with line, jive popup and duration 6 as before');
    is(scalar(grep { /player message failed|Material notification failed/ } @WARNS), 0,
        'halt_material_no_failure_line: server.log holds no failure line');

    $material = { version => '6.5.0' };
    $halt->('10:12:10', $BROWSE);
    is(($notes[0] ? $notes[0][1][2] : undef) // 'none', 'error',
        'halt_material_650_is_error: a Material that shows an error text gets the error type');

    $material = { version => '6.4.9' };
    $halt->('10:12:20', $CONNECT);
    is(scalar @notes, 1, 'halt_material_connect: a paused Connect player gets the notification too');

    $material = { version => '6.4.9' };
    {
        local *FakeClient::showBriefly = sub { die "display boom\n" };
        $halt->('10:12:25', $BROWSE);
    }
    is_deeply([ scalar @notes, scalar(grep { /^SpotOn: refused-key player message failed on \Q$mac\E: display boom/ } @WARNS) ], [ 1, 1 ],
        'halt_display_dies: the failure line is logged as before and the notification still goes out');

    $material = undef;
    my $died = $halt->('10:12:30', $BROWSE);
    is_deeply([ $died, scalar @notes, scalar @{ $client->{brief} } ], [ '', 0, 1 ],
        'halt_no_material: without the Material plugin nothing is sent, nothing dies, the display call stays');
}

done_testing();
