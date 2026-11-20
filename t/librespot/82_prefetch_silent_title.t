#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# 89-10 (ACC-02): a Browse 404 for the next title is deferred to the end of the playing title only when that
# title has produced audio. On the code before 89-10 the cells silent_title, silent_title_retries,
# silent_title_says_why and silent_title_chain fail: handleDirectError parked the 404 for the full length of a
# title LMS held as playing although its stream had ended with 0 bytes (run 89-05 of 2026-11-19 12:22,
# 275.386 s; debug session 89-refused-track-plays-silent). The stub header is the one of
# t/librespot/79_audiokey_halt.t (its lines 10 to 408).

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


# --- doubles: a player as LMS holds it while the next title is being fetched ---
our @WARNS;
{
    package FakeTrack;
    sub new { return bless { url => $_[1] }, $_[0] }
    sub url { return $_[0]{url} }

    package FakeSong;
    sub new       { return bless { url => $_[1] }, $_[0] }
    sub track     { return FakeTrack->new($_[0]{url}) }
    sub streamUrl { return $_[0]{url} }

    package FakeController;
    sub new                 { my ($c, %a) = @_; return bless {%a}, $c }
    sub playingSongDuration { return $_[0]{duration} }
    sub playingSongElapsed  { return $_[0]{elapsed} }

    package FakeClient;
    sub new {
        my ($class, %a) = @_;
        return bless { %a, exec => [], failed => [] }, $class;
    }
    sub id                   { return $_[0]{mac} }
    sub name                 { return 'vm-flac' }
    sub streamingSong        { return $_[0]{streaming} }
    sub playingSong          { return $_[0]{playing} }
    sub controller           { return $_[0]{controller} }
    sub outputBufferFullness { return $_[0]{output} }
    sub execute              { my ($s, $cmd) = @_; push @{ $s->{exec} }, join(' ', @$cmd); }
    sub failedDirectStream   { my ($s, @a) = @_; push @{ $s->{failed} }, [@a]; }
}
{
    no warnings 'redefine';
    *Slim::Utils::Log::warn = sub { shift; push @WARNS, join('', @_); };
}

require Time::HiRes;

my $SKIP_CB  = \&Plugins::SpotOn::ProtocolHandler::_skipUnavailable;
my $RETRY_CB = \&Plugins::SpotOn::ProtocolHandler::_retryStream;

# One cell: LMS holds `playing` (title 0) as the playing song and `streaming` (title 1) as the
# streaming song; the helper answers 404 for title 1. Returns what the plugin armed for the player.
sub cell {
    my (%a) = @_;
    my $playing   = FakeSong->new('http://192.0.2.10:41933/track/TITLE0AAAAAAAAAAAAAAAA');
    my $streaming = FakeSong->new('http://192.0.2.10:41933/track/TITLE1BBBBBBBBBBBBBBBB');
    my $client = FakeClient->new(
        mac        => $a{mac},
        playing    => $playing,
        streaming  => $streaming,
        output     => $a{output},
        controller => FakeController->new(duration => $a{duration}, elapsed => $a{elapsed}),
    );
    @WARNS = ();
    @Slim::Utils::Timers::TIMERS = ();
    my $t0 = Time::HiRes::time();
    $PH->handleDirectError($client, $streaming->streamUrl, 404, 'HTTP/1.0 404 Not Found');
    my @mine  = grep { $_->[0] eq $client } @Slim::Utils::Timers::TIMERS;
    my $delay = @mine ? $mine[0][1] - $t0 : undef;
    my $kind  = !@mine                   ? 'none'
              : $mine[0][2] == $SKIP_CB  ? 'skip'
              : $mine[0][2] == $RETRY_CB ? 'retry'
              :                            'other';
    diag(sprintf('cell %s: playing elapsed=%s of %s s, output buffer=%s -> timers=%d kind=%s delay=%s s, warn=%s, failedDirectStream=%d',
        $a{name}, $a{elapsed}, $a{duration}, defined $a{output} ? $a{output} : 'undef', scalar(@mine), $kind,
        defined $delay ? sprintf('%.3f', $delay) : 'none', join(' | ', @WARNS) || 'none', scalar @{ $client->{failed} }));
    return { timers => scalar(@mine), kind => $kind, delay => $delay, warns => join(' | ', @WARNS), client => $client };
}

# Is the result the deferred skip of the prefetch branch, about $want seconds out?
sub is_deferred {
    my ($r, $want) = @_;
    return $r->{timers} == 1 && $r->{kind} eq 'skip' && abs(($r->{delay} // 0) - $want) < 0.5
        && $r->{warns} =~ /prefetch context, scheduling skip in/ && $r->{warns} !~ /retry \d\/3/;
}

# Control: a real prefetch. The playing title sounds and is 10.386 s from its end; the skip belongs there.
{
    my $r = cell(name => 'control_playing', mac => '02:00:00:86:00:0a', duration => 275.386, elapsed => 265.000, output => 352_800);
    ok(is_deferred($r, 10.386),
        'control_playing: a 404 for the next title while the playing title sounds (elapsed 265 s) is deferred to its end (10.386 s)');
}

# Control: the playing title has just started. LMS still reads elapsed 0, but the player reports
# decoded audio waiting in its output buffer, so the title sounds or is about to.
{
    my $r = cell(name => 'control_just_started', mac => '02:00:00:86:00:0b', duration => 275.386, elapsed => 0, output => 352_800);
    ok(is_deferred($r, 275.386),
        'control_just_started: a playing title at elapsed 0 with decoded audio in the output buffer keeps the deferred skip (275.386 s)');
}

# Control: the playing title has played and its output buffer reads empty (the tail of a title).
{
    my $r = cell(name => 'control_played_buffer_empty', mac => '02:00:00:86:00:0c', duration => 275.386, elapsed => 265.000, output => 0);
    ok(is_deferred($r, 10.386),
        'control_played_buffer_empty: a title that has played (elapsed 265 s) keeps the deferred skip with an empty output buffer too');
}

# Control: the player has not reported its output buffer yet (undef). Nothing proves silence.
{
    my $r = cell(name => 'control_unknown_buffer', mac => '02:00:00:86:00:0d', duration => 275.386, elapsed => 0, output => undef);
    ok(is_deferred($r, 275.386),
        'control_unknown_buffer: elapsed 0 without an output buffer report keeps the deferred skip (nothing proves silence)');
}

# The shape of run 1222: LMS holds title 0 as playing, but its stream ended with 0 bytes
# (elapsed 0 s, nothing decoded). The 404 for title 1 must not park the player for the whole
# length of a title that never sounded: it is handled as play context (retry 1/3 after 2 s).
{
    my $r = cell(name => 'silent_title', mac => '02:00:00:86:00:0e', duration => 275.386, elapsed => 0, output => 0);
    ok($r->{timers} == 1 && ($r->{delay} // 999) <= 10,
        'silent_title: a 404 for the next title while the playing title has no audio (elapsed 0 s, output buffer 0) is not deferred by the title length');
    ok($r->{timers} == 1 && $r->{kind} eq 'retry' && abs(($r->{delay} // 0) - 2) < 0.5 && $r->{warns} =~ m{retry 1/3 in 2s},
        'silent_title_retries: the 404 is handled as play context, retry 1/3 after 2 s');
    like($r->{warns}, qr/the playing title has no audio \(elapsed 0 s, output buffer 0\)/,
        'silent_title_says_why: one WARN names the reason and the two readings');
    is(scalar @{ $r->{client}{failed} }, 0, 'silent_title_keeps_the_stream_open: failedDirectStream is not called');
}

# The retry chain that follows is the play-context one: three more 404s for the same title on the
# same player exhaust it and arm the skip 0.1 s out.
{
    my $playing   = FakeSong->new('http://192.0.2.10:41933/track/TITLE0AAAAAAAAAAAAAAAA');
    my $streaming = FakeSong->new('http://192.0.2.10:41933/track/TITLE1BBBBBBBBBBBBBBBB');
    my $client = FakeClient->new(
        mac => '02:00:00:86:00:0f', playing => $playing, streaming => $streaming, output => 0,
        controller => FakeController->new(duration => 275.386, elapsed => 0),
    );
    @WARNS = ();
    @Slim::Utils::Timers::TIMERS = ();
    my $t0 = Time::HiRes::time();
    $PH->handleDirectError($client, $streaming->streamUrl, 404, 'HTTP/1.0 404 Not Found') for 1 .. 4;
    my @mine = grep { $_->[0] eq $client } @Slim::Utils::Timers::TIMERS;
    my $all  = join(' | ', @WARNS);
    diag("cell silent_title_chain: warn=$all");
    ok(@mine == 1 && $mine[0][2] == $SKIP_CB && ($mine[0][1] - $t0) < 1
        && $all =~ m{retry 1/3 in 2s.*retry 2/3 in 2s.*retry 3/3 in 2s.*4 attempts exhausted, skipping to next track}
        && $all !~ /prefetch context/,
        'silent_title_chain: four 404s on a silent playing title run the whole play-context chain (3 retries, then the skip)');
}

done_testing();
