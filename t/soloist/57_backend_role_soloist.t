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
# Phase 84-07 (SEAM-6.2): the backend role contract.
#
# Plugins::SpotOn::Backend (registry) + Backend::{Librespot,Soloist} (role
# objects). Every transport command of both backends flows through
# control($verb, %args) -> ok | declined | unsupported | down; notify/query
# exist on both from the first commit (frozen method names + vocabulary).
#
# Flat file for now; 84-09 moves it to t/core/. Per-file stubs (t/44
# convention) -- the role classes are loaded for real, everything they
# talk to (DaemonManager, Soloist::Control, SimpleAsyncHTTP) is a stub.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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
our (@INFO, @WARN);
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger   { return bless {}, 'Slim::Utils::Log' }
sub info     { shift; push @INFO, join('', @_); }
sub warn     { shift; push @WARN, join('', @_); }
sub error    { }
sub debug    { }
sub is_info  { 1 }
sub is_debug { 0 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
our %CLIENT;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless {}, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs::Client' }
package Slim::Utils::Prefs::Client;
sub get { my ($self, $key) = @_; return $Slim::Utils::Prefs::CLIENT{$key}; }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @POSTS;
sub new {
    my ($class, $ok, $err, $opts) = @_;
    return bless { ok => $ok, err => $err, opts => $opts }, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    $self->{url}  = $url;
    $self->{rest} = [@rest];
    push @POSTS, $self;
    return $self;
}
sub fire_error { my ($s, $error, $response) = @_; $s->{err}->($s, $error, $response); }
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

write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our @SENT;
sub new {
    my ($class, $id, $args) = @_;
    return bless { id => $id, args => [@{ $args || [] }], source => undef }, $class;
}
sub source  { my $s = shift; $s->{source} = shift if @_; return $s->{source}; }
sub execute { my $s = shift; push @SENT, { id => $s->{id}, args => [@{ $s->{args} }], source => $s->{source} }; }
1;
END

# DaemonManager: the two reads the librespot role makes.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $PORT;
our $HELPER;
sub streamPortForClient { return $PORT; }
sub helperForClient     { return $HELPER; }
# 84-08: the Soloist role's defer cases and URL gates read these.
our $PREREQ_STATE = 'soloist_ready';
our $RESOLVED     = 'pcm';
our @QUEUED;
sub backendPrereqState   { return $PREREQ_STATE; }
sub resolveSoloistFormat { return $RESOLVED; }
# 84-13 Task 2: the renewStatus reads.
our @HELPERS;
sub helperInstances       { return @HELPERS; }
sub pendingBinarySwitches { return {}; }
sub switchedAtFor         { return undef; }
sub soloistHealthFor      { return undef; }
sub crashStateSnapshot    { return undef; }
sub queuePendingTrackRequest {
    my ($class, $clientId, $uri, $posMs, $opts, $deadlineFor) = @_;
    push @QUEUED, [ $clientId, $uri, $posMs, $opts, ($deadlineFor ? $deadlineFor->($opts) : undef) ];
    return;
}
1;
END

# 84-08: canDirectStream's direct URLs use the LMS server address.
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '192.0.2.9'; }
1;
END

# Control: the per-mac registry (for_client) and the request primitives
# the Soloist role delegates to. $RET{<method>} is the return value
# (default 1); every call is recorded with its arguments.
write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Control', <<'END');
package Plugins::SpotOn::Soloist::Control;
our $CTL;
our %RET;
our @CALLS;
sub for_client { return $CTL; }
sub HOLD_CAP_S     { 60 }
sub HOLD_RECHECK_S { 5 }
sub HOLD_MAX_S     { 180 }
sub new {
    my ($class, $mode) = @_;
    return bless { mode => $mode // 'browse',
                   observed => { status => 'playing', track => 'spotify:track:abc', is_active => 1, paired => 1 },
                   wanted   => { position_ms => 4200 } }, $class;
}
sub mode     { return $_[0]->{mode}; }
sub observed { return $_[0]->{observed}; }
sub wanted   { return $_[0]->{wanted}; }
sub nextStreamGeneration { return ++$_[0]->{gen}; }    # 84-08: browse_proxy g=<gen>
for my $m (qw(requestQueue queueSnapshot requestPause requestResume requestVolume requestSkip requestRestart requestTrack endForeignLeave
               noteDuration noteSeekIntent noteMetadataMissing seekable consumeRestartAllowance consumeSeekIntent
               leaveBrowse leaveConnect clearHold _recordErrorOnce watchdogRing notePlaylistChanged)) {
    no strict 'refs';
    *{$m} = sub {
        my ($self, @args) = @_;
        push @CALLS, [ $m, @args ];
        return exists $RET{$m} ? $RET{$m} : 1;
    };
}
1;
END

# 84-08 Task 3: the Soloist module's pairing read (state() fallback) and the
# Quality module (D-17 quality() delegation) -- recorders only.
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
our $PAIRED = 0;
our (@INIT, @ENSURE);
sub isPairedForClient { return $PAIRED; }
sub init              { push @INIT, 1; }
sub ensureBinary      { push @ENSURE, 1; }
# 84-12 Task 1: the prereq reads Backend::Soloist::prereqState makes.
our ($GET, $HASKEY, $WSLIB) = (undef, 0, 1);
our $GETCALLS = 0;
sub get         { $GETCALLS++; return $GET; }
sub hasKey      { return $HASKEY; }
sub ensureWsLib { return $WSLIB; }
# 84-12 Task 2: the lifecycle reads/writes the Soloist role hooks make.
our (@ORDER, @ROLLBACK);
our @ROLLBACK_RET = (1, '1.3.8.68');
sub checkPlacedBinary { push @ORDER, 'placed';  return 'absent'; }
sub checkRenewalDue   { push @ORDER, 'renewal'; return 'not_due'; }
sub rollbackToPrevious { my %a = @_; push @ROLLBACK, {%a}; return @ROLLBACK_RET; }
our @RENEWAL_STATE;
sub _setRenewalState  { my %a = @_; push @RENEWAL_STATE, {%a}; }
# 84-13 Task 1: the key store the Soloist role delegates to (storeKey is a
# class method in Soloist.pm, hasKey/clearKey are plain functions).
our (@STORE, @CLEAR);
our @STORE_RET = (1);
sub storeKey { my ($class, $key) = @_; push @STORE, $key; return @STORE_RET; }
sub clearKey { push @CLEAR, 1; return 1; }
# 84-13 Task 2: renew route bodies + the read-only binary path (WR-01).
our @RENEW;
our $INSTALLED = '/fake/cache/soloist/x86_64-linux/soloist';
sub renewBinary         { my %a = @_; push @RENEW, {%a}; return 'started'; }
sub activeVersion       { return '1.3.8.70'; }
sub renewalState        { return { phase => 'idle' }; }
sub expiryDaysRemaining { return 40; }
sub placedState         { return { status => 'absent' }; }
sub manualDir           { return '/fake/cache/soloist/manual'; }
sub installedBinaryPath { return $INSTALLED; }
1;
END
write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Quality', <<'END');
package Plugins::SpotOn::Soloist::Quality;
our @APPLY;
use constant SUPPORTED_LEVELS => (0, 2, 3, 4, 5);
sub applyChange { my ($class, %a) = @_; push @APPLY, {%a}; return 1; }
# 84-13 Task 2: the per-player reads qualityInfo($client) makes.
our ($EFF, $CACHED, $NOTICE, $DEVICE) = (5, { level => 4 }, undef, 'dev-uuid');
my %LBL = map { $_ => "Q$_" } 0 .. 6;
sub levels                  { return [ map { { value => $_, string => "Q$_" } } (SUPPORTED_LEVELS) ]; }
sub isValidLevel            { my ($c, $v) = @_; return (defined $v && $v =~ /^(?:0|2|3|4|5)$/) ? 1 : 0; }
sub isStorableLevel         { my ($c, $v) = @_; return (defined $v && $v =~ /^[0-6]$/) ? 1 : 0; }
sub labelFor                { my ($c, $l) = @_; return defined $l ? ($LBL{$l} // '') : ''; }
sub deviceIdForMac          { return $DEVICE; }
sub effectiveCached         { return $CACHED; }
sub effectiveLevelForClient { return $EFF; }
sub noticeFor               { return $NOTICE; }
1;
END
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import { my $caller = caller; no strict 'refs'; *{"${caller}::string"} = \&string; }
our %S = (PLUGIN_SPOTON_SOLOIST_QUALITY_REJECTED => 'REJ[%s>%s]');
sub string { my ($k) = @_; return exists $S{$k} ? $S{$k} : "S:$k"; }
1;
END
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $INIT = 0;
sub init { $INIT++; }
# 84-12 Task 2 (W6): the librespot passthrough capability read.
our %CAP = (passthrough => 1);
sub getCapability { my ($c, $k) = @_; return $CAP{$k}; }
# 84-13 Task 2: the librespot binaryPath reads (init before get).
our @ORDER;
our $PATH = '/fake/Bin/x86_64-linux/spoton';
{ no warnings 'redefine'; my $i = \&init; *init = sub { push @ORDER, 'init'; $i->(@_) }; }
sub get { push @ORDER, 'get'; return wantarray ? ($PATH, '0.8.0') : $PATH; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
our @CALLS;
sub playerPause  { my ($c, @a) = @_; push @CALLS, ['playerPause',  @a[0 .. $#a - 1]]; }
sub playerPlay   { my ($c, @a) = @_; push @CALLS, ['playerPlay',   @a[0 .. $#a - 1]]; }
sub playerVolume { my ($c, @a) = @_; push @CALLS, ['playerVolume', @a[0 .. $#a - 1]]; }
sub playerSeek   { my ($c, @a) = @_; push @CALLS, ['playerSeek',   @a[0 .. $#a - 1]]; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 1 };
    *main::DEBUGLOG = sub () { 0 };
    *main::SCANNER  = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

for my $stub (qw(Slim::Player::Client Slim::Control::Request Plugins::SpotOn::Unified::DaemonManager Slim::Utils::Network
                 Plugins::SpotOn::Soloist::Control Plugins::SpotOn::API::Client
                 Plugins::SpotOn::Soloist Plugins::SpotOn::Soloist::Quality Plugins::SpotOn::Helper)) {
    require_ok($stub) or BAIL_OUT("Failed to load the $stub stub");
}
require_ok('Plugins::SpotOn::Backend')            or BAIL_OUT('Backend.pm does not load');
require_ok('Plugins::SpotOn::Backend::Soloist')   or BAIL_OUT('Backend/Soloist.pm does not load');

my $MAC = 'aa:bb:cc:dd:ee:ff';
my $S   = 'Plugins::SpotOn::Backend::Soloist';

sub posts { return @Slim::Networking::SimpleAsyncHTTP::POSTS; }

{
    package Test::Helper;    # present()'s daemon object: alive, no WS socket
    sub alive { return 1; }
}

# Scenario switch: (a) daemon / Control present, (b) absent.
sub present {
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
    @Plugins::SpotOn::API::Client::CALLS       = ();
    @Plugins::SpotOn::Soloist::Control::CALLS  = ();
    %Plugins::SpotOn::Soloist::Control::RET    = ();
    $Plugins::SpotOn::Unified::DaemonManager::PORT   = 4242;
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = bless {}, 'Test::Helper';
    $Plugins::SpotOn::Soloist::Control::CTL = Plugins::SpotOn::Soloist::Control->new('connect');
    @Plugins::SpotOn::Unified::DaemonManager::QUEUED       = ();
    $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = 'soloist_ready';
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED     = 'pcm';
    @Plugins::SpotOn::Unified::SoloistDaemon::DEFERRED    = ();
    %Slim::Utils::Prefs::CLIENT = ();
}
sub absent {
    present();
    $Plugins::SpotOn::Unified::DaemonManager::PORT   = undef;
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    $Plugins::SpotOn::Soloist::Control::CTL          = undef;
}

# ------------------------------------------------------------
# 84-12 Task 1: prereqState() table through the role (the Soloist prereq
# reads moved out of DaemonManager::_backendPrereqState).
# ------------------------------------------------------------
{
    ok($S->can('prereqState'), 'soloist role: prereqState exists');

    local ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY, $Plugins::SpotOn::Soloist::WSLIB);
    local @Slim::Utils::Log::WARN = ();

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY, $Plugins::SpotOn::Soloist::WSLIB) = ('/fake/soloist', 1, 1);
    is(eval { $S->prereqState }, 'soloist_ready', 'soloist prereqState: binary + key -> soloist_ready');
    is(scalar(grep { /Protocol::WebSocket unavailable/ } @Slim::Utils::Log::WARN), 0, 'soloist prereqState: WS lib present -> no warning');

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY) = (undef, 1);
    is(eval { $S->prereqState }, 'soloist_missing_binary', 'soloist prereqState: no binary -> soloist_missing_binary');

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY) = ('/fake/soloist', 0);
    is(eval { $S->prereqState }, 'soloist_missing_key', 'soloist prereqState: binary, no key -> soloist_missing_key');

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY, $Plugins::SpotOn::Soloist::WSLIB) = ('/fake/soloist', 1, 0);
    is(eval { $S->prereqState }, 'soloist_ready', 'soloist prereqState: WS lib missing still -> soloist_ready (warning only)');
    is(scalar(grep { /Protocol::WebSocket unavailable/ } @Slim::Utils::Log::WARN), 1,
       'soloist prereqState: WS lib missing -> the Protocol::WebSocket warning is logged by the role');
}

# ------------------------------------------------------------
# Object shape
# ------------------------------------------------------------
for my $cls ($S) {
    my $be = $cls->new($MAC);
    isa_ok($be, $cls);
    is($be->mac, $MAC, "$cls: mac() returns the constructor mac");
    for my $m (qw(control notify query capabilities state streamUrl daemonClass)) {
        ok($be->can($m), "$cls: role method $m exists");
    }
}
is($S->new($MAC)->daemonClass, 'Plugins::SpotOn::Unified::SoloistDaemon', 'soloist daemonClass');

{
    present();
    my $be = $S->new($MAC);
    is($be->control('pause', isStop => 0), 'ok', 'soloist pause (Control present, requestPause truthy) -> ok');
    is($be->control('pause', isStop => 1), 'ok', 'soloist stop -> ok');
    is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ ['requestPause', 0], ['requestPause', 1] ],
        'soloist pause passes isStop through to requestPause (0, then 1)');
    @Plugins::SpotOn::Soloist::Control::CALLS = ();
    is($be->control('play', source => 'lms_pause'), 'ok', 'soloist play (requestResume truthy) -> ok');
    is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ ['requestResume'] ], 'soloist play -> requestResume');
    $Plugins::SpotOn::Soloist::Control::RET{requestPause}  = 0;
    $Plugins::SpotOn::Soloist::Control::RET{requestResume} = 0;
    is($be->control('pause', isStop => 0), 'declined', 'soloist pause with requestPause 0 -> declined');
    is($be->control('play'), 'declined', 'soloist play with requestResume 0 -> declined');
    is(scalar(posts()), 0, 'soloist: never an HTTP POST');
}
{
    absent();
    my $be = $S->new($MAC);
    is($be->control('pause', isStop => 0), 'down', 'soloist pause without a Control instance -> down');
    is($be->control('play'), 'down', 'soloist play without a Control instance -> down');
    is(scalar(@Plugins::SpotOn::Soloist::Control::CALLS), 0, 'soloist down: no request* call');
    is(scalar(posts()), 0, 'soloist down: no HTTP POST, no fallthrough into the librespot path');
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'soloist down: no Web API fallback');
}

# ------------------------------------------------------------
# 84-07 Task 2: the full verb table.
# ------------------------------------------------------------
{
    package Test::Track;
    sub new        { return bless { samplesize => 32 }, shift; }
    sub can        { return $_[1] eq 'samplesize' ? \&samplesize : UNIVERSAL::can(@_); }
    sub samplesize { my $s = shift; $s->{samplesize} = shift if @_; return $s->{samplesize}; }
    package Test::Song;
    sub new   { return bless { track => Test::Track->new }, shift; }
    sub track { return $_[0]->{track}; }
}

# librespot: the five HTTP verbs -> endpoint + body

# Soloist: request* delegation table (verb, args, expected Control call)
my @SO = (
    [ 'play',       [],                         [ 'requestResume' ] ],
    [ 'pause',      [ isStop => 0 ],            [ 'requestPause', 0 ] ],
    [ 'pause',      [ isStop => 1 ],            [ 'requestPause', 1 ] ],
    [ 'set_volume', [ volume => 55.7 ],         [ 'requestVolume', 55 ] ],
    [ 'skip_next',  [ reason => 'jump+1' ],     [ 'requestSkip', 'next', 'jump+1' ] ],
    [ 'skip_prev',  [ reason => 'jump-1' ],     [ 'requestSkip', 'prev', 'jump-1' ] ],
    [ 'restart',    [ reason => 'jump+0' ],     [ 'requestRestart', 'jump+0' ] ],
    [ 'seek',       [ position_ms => 0 ],       [ 'requestSkip', 'prev', 'time0' ] ],
);
for my $row (@SO) {
    my ($verb, $args, $call) = @$row;
    my $label = "soloist $verb(" . join(',', @$args) . ')';
    present();
    is($S->new($MAC)->control($verb, @$args), 'ok', "$label (request* truthy) -> ok");
    is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ $call ], "$label -> " . join(' ', @$call));
    present();
    $Plugins::SpotOn::Soloist::Control::RET{ $call->[0] } = 0;
    is($S->new($MAC)->control($verb, @$args), 'declined', "$label ($call->[0] returns 0) -> declined");
    absent();
    is($S->new($MAC)->control($verb, @$args), 'down', "$label (no Control) -> down");
    is(scalar(@Plugins::SpotOn::Soloist::Control::CALLS), 0, "$label down: no Control call");
}
{
    present();
    is($S->new($MAC)->control('seek', position_ms => 30000), 'ok', 'soloist seek N > 0 -> ok (acknowledgement, D-B1)');
    is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [], 'soloist seek N > 0: NO Control call (the LMS restart chain carries the seek)');
}
{
    present();
    my $song = Test::Song->new;
    is($S->new($MAC)->control('track', source => 'getNextTrack', url => 'spoton://track:abc', position_ms => 1500,
                              song => $song, duration => 200, successCb => sub {}, errorCb => sub {}), 'ok',
        'soloist track(getNextTrack) with Control -> ok');
    my ($c) = @Plugins::SpotOn::Soloist::Control::CALLS;
    is($c->[0], 'requestTrack', 'soloist track(getNextTrack) -> requestTrack');
    is($c->[1], 'spoton://track:abc', 'soloist track(getNextTrack): url passed');
    is($c->[2], 1500, 'soloist track(getNextTrack): position_ms passed');
    is($c->[3]{source}, 'getNextTrack', 'soloist track(getNextTrack): source getNextTrack');
    is(ref $c->[3]{successCb}, 'CODE', 'soloist track(getNextTrack): successCb passed');
}

# ------------------------------------------------------------
# 84-08 Task 2: control('track', source => 'getNextTrack') without a
# Control instance -- the three defer cases moved from ProtocolHandler.
# ------------------------------------------------------------
{
    package Plugins::SpotOn::Unified::SoloistDaemon;    # Case 1's daemon class (never loaded for real here)
    our @DEFERRED;
    sub new { return bless {}, shift; }
    sub deferTrackRequest { my $s = shift; push @DEFERRED, [@_]; return 1; }
}
{
    # Case 1: a daemon object of the Soloist class exists, Control not built yet
    absent();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = Plugins::SpotOn::Unified::SoloistDaemon->new;
    my ($ok, $err) = (0, 0);
    is($S->new($MAC)->control('track', source => 'getNextTrack', url => 'spoton://track:abc', position_ms => 900,
                              duration => 200, successCb => sub { $ok++ }, errorCb => sub { $err++ }), 'ok',
        'soloist track(getNextTrack), daemon without Control (Case 1) -> ok (deferred)');
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::DEFERRED), 1, 'Case 1: exactly one deferTrackRequest on the daemon');
    my ($d) = @Plugins::SpotOn::Unified::SoloistDaemon::DEFERRED;
    $d ||= [];
    is_deeply([ @{$d}[0, 1] ], [ 'spoton://track:abc', 900 ], 'Case 1: uri + position_ms passed to the daemon');
    is($d->[2]{source}, 'getNextTrack', 'Case 1: source getNextTrack');
    is($d->[2]{origin}, 'lms', "Case 1: origin 'lms' (no Connect marker)");
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::QUEUED), 0, 'Case 1: nothing queued on DaemonManager');
    is($ok + $err, 0, 'Case 1: neither callback fired yet');

    # Case 1 negative: a daemon of the OTHER class is no Case 1
    absent();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = bless {}, 'Plugins::SpotOn::Unified::Daemon';
    $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = 'soloist_missing_binary';
    my @e;
    is($S->new($MAC)->control('track', source => 'getNextTrack', url => 'spoton://track:abc',
                              errorCb => sub { @e = @_ }), 'down',
        'soloist track(getNextTrack), librespot-class helper + not ready -> down');
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::DEFERRED), 0, 'Case 1 negative: no deferTrackRequest on a librespot-class helper');

    # Case 2: no daemon, prereqs ready -> the package-level anchor
    absent();
    my $opts;
    is($S->new($MAC)->control('track', source => 'getNextTrack', url => 'spoton://episode:ep1', position_ms => 0,
                              successCb => sub {}, errorCb => sub {}), 'ok',
        'soloist track(getNextTrack), no daemon + soloist_ready (Case 2) -> ok (deferred)');
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::QUEUED), 1, 'Case 2: exactly one queued request on DaemonManager');
    my ($q) = @Plugins::SpotOn::Unified::DaemonManager::QUEUED;
    $q ||= [];
    is_deeply([ @{$q}[0, 1, 2] ], [ $MAC, 'spoton://episode:ep1', 0 ], 'Case 2: clientId, uri, position_ms');
    ok(defined $q->[4] && $q->[4] > time(), 'Case 2: the DeferBudget deadline is computed by the role (future epoch)');
    is($q->[3]{deferDeadline}, $q->[4], 'Case 2: deadline lands in opts->{deferDeadline} (DeferBudget::deadlineFor)');

    # Case 3: every non-ready state -> errorCb with the mapped message
    my %MSG = (
        soloist_unsupported_os => 'Soloist is not supported on this platform (Windows/macOS)',
        soloist_missing_binary => 'Soloist binary not installed',
        soloist_missing_key    => 'Soloist not authorized (missing key)',
        soloist_build_expired  => 'Soloist build has expired - please update the plugin',
        something_else         => 'Soloist daemon not ready',
    );
    for my $state (sort keys %MSG) {
        absent();
        $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = $state;
        my @err;
        is($S->new($MAC)->control('track', source => 'getNextTrack', url => 'spoton://track:abc',
                                  successCb => sub {}, errorCb => sub { @err = @_ }), 'down',
            "Case 3 ($state) -> down");
        is_deeply(\@err, [ 'PROBLEM_OPENING', $MSG{$state} ], "Case 3 ($state): errorCb(PROBLEM_OPENING, mapped message)");
        is(scalar(@Plugins::SpotOn::Unified::DaemonManager::QUEUED), 0, "Case 3 ($state): nothing queued");
    }
}

# ------------------------------------------------------------
# 84-08 Task 2: control('track', source => 'onStream') -- the moved onStream body.
# ------------------------------------------------------------
{
    package Test::OSTrack;
    sub new { return bless { url => $_[1] }, $_[0]; }
    sub url { return $_[0]->{url}; }
    package Test::OSSong;
    sub new         { my ($c, %a) = @_; return bless { %a }, $c; }
    sub track       { return $_[0]->{track}; }
    sub seekdata    { return $_[0]->{seekdata}; }
    sub duration    { return $_[0]->{duration}; }
    sub startOffset { my $s = shift; $s->{startOffset} = shift if @_; return $s->{startOffset}; }
}
{
    my $U = 'spoton://track:abc';
    # (a) seekdata -> requestTrack seek 1 at timeOffset*1000, startOffset set
    present();
    my $song = Test::OSSong->new(track => Test::OSTrack->new($U), seekdata => { timeOffset => 42.5 }, duration => 300);
    is($S->new($MAC)->control('track', source => 'onStream', url => $U, song => $song, duration => 300), 'ok',
        'soloist track(onStream) with Control -> ok');
    my @c = @Plugins::SpotOn::Soloist::Control::CALLS;
    my ($rt) = grep { $_->[0] eq 'requestTrack' } @c;
    $rt ||= [];
    is_deeply([ @{$rt}[1, 2] ], [ $U, 42500 ], 'onStream seekdata: requestTrack(url, timeOffset*1000)');
    is_deeply({ map { $_ => $rt->[3]{$_} } qw(source seek duration) }, { source => 'onStream', seek => 1, duration => 300 },
        'onStream seekdata: opts source onStream, seek 1, duration');
    is($song->startOffset, 42.5, "onStream seekdata: the song's startOffset is set to the seek target");
    is(($c[-1] // [])->[0], 'consumeSeekIntent', 'onStream seekdata: the marker is cleared AFTER requestTrack (IN-01)');

    # (b) no seekdata, marker present -> marker position, seek 1
    present();
    $Plugins::SpotOn::Soloist::Control::RET{consumeSeekIntent} = 0;
    $song = Test::OSSong->new(track => Test::OSTrack->new($U), duration => 300);
    $S->new($MAC)->control('track', source => 'onStream', url => $U, song => $song, duration => 300);
    ($rt) = grep { $_->[0] eq 'requestTrack' } @Plugins::SpotOn::Soloist::Control::CALLS;
    $rt ||= [];
    is_deeply([ $rt->[2], $rt->[3]{seek} ], [ 0, 1 ], 'onStream marker (rewind target 0): requestTrack(url, 0) with seek 1');
    is($song->startOffset, undef, 'onStream marker: startOffset untouched');

    # (c) neither -> position 0, seek 0
    present();
    $Plugins::SpotOn::Soloist::Control::RET{consumeSeekIntent} = undef;
    $S->new($MAC)->control('track', source => 'onStream', url => $U, song => $song, duration => 300);
    ($rt) = grep { $_->[0] eq 'requestTrack' } @Plugins::SpotOn::Soloist::Control::CALLS;
    $rt ||= [];
    is_deeply([ $rt->[2], $rt->[3]{seek} ], [ 0, 0 ], 'onStream neither seekdata nor marker: requestTrack(url, 0) seek 0');

    # (d) no Control -> down, no call
    absent();
    is($S->new($MAC)->control('track', source => 'onStream', url => $U, song => $song), 'down', 'soloist track(onStream) without Control -> down');
    is(scalar(@Plugins::SpotOn::Soloist::Control::CALLS), 0, 'onStream without Control: no Control call');
}

# unknown verb
for my $cls ($S) {
    present();
    is($cls->new($MAC)->control('frobnicate'), 'unsupported', "$cls: control('frobnicate') -> unsupported (present)");
    is($cls->new($MAC)->control(undef), 'unsupported', "$cls: control(undef) -> unsupported");
    absent();
    is($cls->new($MAC)->control('frobnicate'), 'unsupported', "$cls: control('frobnicate') -> unsupported (absent)");
}

# ------------------------------------------------------------
# notify() / query()
# ------------------------------------------------------------
{
    present();
    is($S->new($MAC)->notify('endForeignLeave', reason => 'lms-stop'), 'ok', 'soloist notify(endForeignLeave) -> ok');
    is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ [ 'endForeignLeave', 'lms-stop' ] ],
        "soloist notify(endForeignLeave) -> Control endForeignLeave('lms-stop')");
    absent();
    is($S->new($MAC)->notify('endForeignLeave', reason => 'lms-stop'), 'down', 'soloist notify(endForeignLeave) without Control -> down');
    present();
}
for my $cls ($S) {
    present();
    is($cls->new($MAC)->notify('frobnicate'), 'unsupported', "$cls: unknown notify event -> unsupported");
}

# 84-08 Task 3: the Connect.pm / Plugin.pm notify sites (84-07 table). Each
# event: Soloist with Control -> ok + the Control call; without -> down;
# librespot -> unsupported and nothing called.
{
    my %EV3 = (
        leaveBrowse         => [ [],                                         [ 'leaveBrowse' ] ],
        leaveConnect        => [ [ reason => 'foreign-lms-content' ],        [ 'leaveConnect', 'foreign-lms-content' ] ],
        clearHold           => [ [ trackId => 'T1' ],                        [ 'clearHold', 'T1' ] ],
        recordErrorOnce     => [ [ key => 'k', level => 'warn', message => 'm' ], [ '_recordErrorOnce', 'k', 'warn', 'm' ] ],
        watchdogRing        => [ [ url => 'spoton://track:a' ],              [ 'watchdogRing', 'spoton://track:a' ] ],
        notePlaylistChanged => [ [],                                         [ 'notePlaylistChanged' ] ],
    );
    for my $ev (sort keys %EV3) {
        my ($args, $call) = @{ $EV3{$ev} };
        present();
        is($S->new($MAC)->notify($ev, @$args), 'ok', "soloist notify('$ev') -> ok");
        is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ $call ], "soloist notify('$ev') -> Control " . join(' ', @$call));
        absent();
        is($S->new($MAC)->notify($ev, @$args), 'down', "soloist notify('$ev') without Control -> down");
        present();
    }
    # claimLost: the loser's observed is_active drops to 0 (D-D2), no request.
    present();
    my $ctl = $Plugins::SpotOn::Soloist::Control::CTL;
    is($ctl->observed->{is_active}, 1, 'claimLost precondition: is_active 1');
    is($S->new($MAC)->notify('claimLost', reason => 'last-message-wins'), 'ok', "soloist notify('claimLost') -> ok");
    is($ctl->observed->{is_active}, 0, "soloist notify('claimLost') -> Control observed.is_active = 0");
    is(scalar(@Plugins::SpotOn::Soloist::Control::CALLS), 0, "soloist notify('claimLost'): no request primitive called");
    absent();
    is($S->new($MAC)->notify('claimLost'), 'down', "soloist notify('claimLost') without Control -> down");
}

# 84-08 Task 3: bootstrap / quality / qualityInfo (class methods).
{
    for my $cls ($S) {
        ok($cls->can('bootstrap'), "$cls: bootstrap exists");
        ok($cls->can('settingsInfo'), "$cls: settingsInfo exists");
    }
    @Plugins::SpotOn::Soloist::INIT = (); @Plugins::SpotOn::Soloist::ENSURE = ();
    is($S->bootstrap, 'ok', 'soloist bootstrap -> ok');
    is($S->bootstrap, 'ok', 'soloist bootstrap again -> ok');
    is(scalar(@Plugins::SpotOn::Soloist::INIT), 1, 'soloist bootstrap: Soloist->init once (its backend watcher is registered once)');
    is(scalar(@Plugins::SpotOn::Soloist::ENSURE), 2, 'soloist bootstrap: ensureBinary on every call (self-guarding)');
    my $before = $Plugins::SpotOn::Helper::INIT;

    @Plugins::SpotOn::Soloist::Quality::APPLY = ();
    is($S->quality(scope => 'global', level => 2), 'ok', "soloist quality(scope => 'global', level => 2) -> ok");
    is_deeply(\@Plugins::SpotOn::Soloist::Quality::APPLY, [ { scope => 'global', level => 2 } ],
        'soloist quality: Soloist::Quality->applyChange(scope => global, level => 2) (D-17)');
    is_deeply($S->qualityInfo, { supported => 1, validLevels => [ 0, 2, 3, 4, 5 ] }, 'soloist qualityInfo: supported, the five valid levels');
}

# 84-13 Task 1 (SEAM-6.2): the Soloist key store is a role capability --
# keyState() -> { supported, present }, storeKey($raw) -> (ok, reason),
# clearKey(). The librespot role answers "unsupported" and never reaches
# the Soloist module.
{
    for my $cls ($S) {
        ok($cls->can($_), "$cls: key-store method $_ exists (84-13)") for qw(keyState storeKey clearKey);
    }
    local $Plugins::SpotOn::Soloist::HASKEY = 1;
    is_deeply(scalar(eval { $S->keyState }), { supported => 1, present => 1 }, 'soloist keyState: supported, key present');
    $Plugins::SpotOn::Soloist::HASKEY = 0;
    is_deeply(scalar(eval { $S->keyState }), { supported => 1, present => 0 }, 'soloist keyState: supported, no key');

    my $raw = 'abcDEF123_-.abcDEF123';
    @Plugins::SpotOn::Soloist::STORE = ();
    @Slim::Utils::Log::INFO = (); @Slim::Utils::Log::WARN = ();
    my @r = eval { $S->storeKey($raw) };
    is($r[0], 1, 'soloist storeKey: ok on a successful write');
    is_deeply(\@Plugins::SpotOn::Soloist::STORE, [ $raw ], 'soloist storeKey: Soloist->storeKey gets the raw value unchanged');
    ok(!(grep { index($_, 'abcDEF123') >= 0 } @Slim::Utils::Log::INFO, @Slim::Utils::Log::WARN),
        'soloist storeKey: no key fragment in the log (T-84-45)');
    {
        local @Plugins::SpotOn::Soloist::STORE_RET = (0, 'write_failed');
        my @f = eval { $S->storeKey($raw) };
        is_deeply(\@f, [ 0, 'write_failed' ], 'soloist storeKey: a failed write answers (0, write_failed)');
    }
    @Plugins::SpotOn::Soloist::CLEAR = ();
    eval { $S->clearKey };
    is(scalar(@Plugins::SpotOn::Soloist::CLEAR), 1, 'soloist clearKey: Soloist::clearKey called once');
    @Plugins::SpotOn::Soloist::STORE = (); @Plugins::SpotOn::Soloist::CLEAR = ();
}

# 84-08 Task 2: the ProtocolHandler notify/query sites (84-07 table)
{
    my %EV = (
        noteDuration        => [ [ url => 'spoton://track:a', secs => 211 ], [ 'noteDuration', 'spoton://track:a', 211 ] ],
        noteSeekIntent      => [ [ url => 'spoton://track:a', target_ms => 7000 ], [ 'noteSeekIntent', 'spoton://track:a', 7000 ] ],
        noteMetadataMissing => [ [ url => 'spoton://track:a' ], [ 'noteMetadataMissing', 'spoton://track:a' ] ],
    );
    for my $ev (sort keys %EV) {
        my ($args, $call) = @{ $EV{$ev} };
        present();
        is($S->new($MAC)->notify($ev, @$args), 'ok', "soloist notify('$ev') -> ok");
        is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ $call ], "soloist notify('$ev') -> Control " . join(' ', @$call));
        absent();
        is($S->new($MAC)->notify($ev, @$args), 'down', "soloist notify('$ev') without Control -> down");
        present();
    }
    for my $what (qw(seekable consumeRestartAllowance)) {
        present();
        $Plugins::SpotOn::Soloist::Control::RET{$what} = 1;
        is($S->new($MAC)->query($what, url => 'spoton://track:a'), 1, "soloist query('$what') -> Control value 1");
        is_deeply(\@Plugins::SpotOn::Soloist::Control::CALLS, [ [ $what, 'spoton://track:a' ] ], "soloist query('$what') -> Control $what(url)");
        present();
        $Plugins::SpotOn::Soloist::Control::RET{$what} = 0;
        is($S->new($MAC)->query($what, url => 'spoton://track:a'), 0, "soloist query('$what') -> Control value 0");
        absent();
        is($S->new($MAC)->query($what, url => 'spoton://track:a'), undef, "soloist query('$what') without Control -> undef");
        present();
    }
}
present();
is($S->new($MAC)->query('wantedPositionMs'), 4200, "soloist query('wantedPositionMs') -> Control wanted.position_ms");
absent();
is($S->new($MAC)->query('wantedPositionMs'), undef, "soloist query('wantedPositionMs') without Control -> undef");

# 85-07 Task 1 (D-09): query('queue') -> { current, upcoming } from the helper
{
    present();
    my $snap = { current => { uri => 'spotify:track:CUR', name => 'Cur' }, upcoming => [ { uri => 'spotify:track:N1', name => 'N1' } ] };
    $Plugins::SpotOn::Soloist::Control::RET{queueSnapshot} = $snap;
    @Plugins::SpotOn::Soloist::Control::CALLS = ();
    my $q = $S->new($MAC)->query('queue');
    is_deeply($q, $snap, "soloist query('queue') -> Control queueSnapshot (85-07 D-09)");
    isnt($q, $snap, "soloist query('queue') returns a copy, not Control's own hash");
    isnt($q->{upcoming}, $snap->{upcoming}, "soloist query('queue'): the upcoming list is a copy too");
    is_deeply([ map { $_->[0] } @Plugins::SpotOn::Soloist::Control::CALLS ], [ 'requestQueue', 'queueSnapshot' ],
        "soloist query('queue') asks the helper (requestQueue) and then reads the cache (queueSnapshot)");
    delete $Plugins::SpotOn::Soloist::Control::RET{queueSnapshot};
    absent();
    is_deeply($S->new($MAC)->query('queue'), { current => undef, upcoming => [] },
        "soloist query('queue') without a Control instance -> empty queue, not undef (the item stays visible, 85-07 D-09)");
    present();
}

# ------------------------------------------------------------
# 84-08 Task 1: streamUrl($client, $song, 'browse_proxy', url => ...) on
# both backends -- the URL shapes ProtocolHandler::new used to build.
# ------------------------------------------------------------
{
    package Test::StreamHelper;
    sub new         { my ($c, %a) = @_; return bless { %a }, $c; }
    sub alive       { return $_[0]->{alive} // 1; }
    sub _streamPort { return $_[0]->{port}; }
    package Test::SClient;
    sub new      { my ($c, %a) = @_; return bless { id => 'aa:bb:cc:dd:ee:ff', synced => 0, %a }, $c; }
    sub id       { return $_[0]->{id}; }
    sub isSynced { return $_[0]->{synced}; }
    package Test::UrlTrack;
    sub new { return bless { url => $_[1] }, $_[0]; }
    sub url { return $_[0]->{url}; }
    package Test::SeekSong;
    sub new         { my ($c, %a) = @_; return bless { %a }, $c; }
    sub track       { return $_[0]->{track}; }
    sub seekdata    { return $_[0]->{seekdata}; }
    sub startOffset { my $s = shift; $s->{startOffset} = shift if @_; return $s->{startOffset}; }
}
{
    present();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = Test::StreamHelper->new(port => 4711);
    my $cl = Test::SClient->new;
    my $song = Test::SeekSong->new(track => Test::UrlTrack->new('spoton://episode:ep1'), seekdata => { timeOffset => 12 });

    $Plugins::SpotOn::Soloist::Control::CTL->{gen} = 6;
    is($S->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://track:abc'),
        'http://127.0.0.1:4711/stream?uri=spotify:track:abc&g=7', 'soloist streamUrl(browse_proxy): /stream?uri=spotify:track:<id>&g=<next gen>');
    $Plugins::SpotOn::Soloist::Control::CTL = undef;
    is($S->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://episode:ep1'),
        'http://127.0.0.1:4711/stream?uri=spotify:episode:ep1&g=0', 'soloist streamUrl(browse_proxy): g=0 without Control');

    for my $cls ($S) {
        is($cls->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://connect-1'), undef,
            "$cls: streamUrl(browse_proxy) -> undef for a non-Browse URL");
        is($cls->new($MAC)->streamUrl(undef, undef, 'browse_proxy', url => 'spoton://track:abc'), undef,
            "$cls: streamUrl(browse_proxy) -> undef without a client");
    }

    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    for my $cls ($S) {
        is($cls->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://track:abc'), undef,
            "$cls: streamUrl(browse_proxy) -> undef when no daemon");
    }
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = Test::StreamHelper->new(port => 4711, alive => 0);
    for my $cls ($S) {
        is($cls->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://track:abc'), undef,
            "$cls: streamUrl(browse_proxy) -> undef when the daemon is not alive");
    }
}

# ------------------------------------------------------------
# 84-13 Task 2 (SEAM-6.2): routes / renewNow / renewStatus / binaryPath /
# qualityInfo($client) / quality(scope => 'player') / capabilities autoplay
# ------------------------------------------------------------
{
    for my $cls ($S) {
        ok($cls->can($_), "$cls: role method $_ exists (84-13)") for qw(routes renewNow renewStatus binaryPath qualityInfo quality);
    }
    my $routes = eval { $S->routes } || [];
    is_deeply([ map { $_->{path} } @$routes ],
              [ 'plugins/SpotOn/settings/soloistRenewStatus', 'plugins/SpotOn/settings/soloistRenew' ],
              'soloist routes(): the FULL LMS paths, status route FIRST (83.3 registration-order lesson)');
    is_deeply([ map { $_->{method} } @$routes ], [ 'GET', 'POST' ], 'soloist routes(): GET status, POST renew');
    ok(!(grep { ref $_->{handler} ne 'CODE' } @$routes), 'soloist routes(): every entry carries a handler coderef');

    @Plugins::SpotOn::Soloist::RENEW = ();
    is_deeply(scalar(eval { $S->renewNow(reason => 'manual') }), { status => 'started' }, "soloist renewNow(reason => 'manual') -> { status => 'started' }");
    is_deeply(\@Plugins::SpotOn::Soloist::RENEW, [ { reason => 'manual' } ], 'soloist renewNow: Soloist::renewBinary(reason => manual) once');

    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = ();
    my $st = eval { $S->renewStatus() };
    is(ref $st, 'HASH', 'soloist renewStatus() returns a plain hashref (no HTTP objects)');
    is_deeply([ sort keys %{ $st || {} } ],
              [ sort qw(renewal generation active_version expiry_days pending_switches players placed manual_dir) ],
              'soloist renewStatus(): exactly the eight status keys');
    is(($st || {})->{active_version}, '1.3.8.70', 'soloist renewStatus(): active_version from activeVersion() (WR-01, never get())');

    $Plugins::SpotOn::Soloist::GETCALLS = 0;
    is(eval { $S->binaryPath }, $Plugins::SpotOn::Soloist::INSTALLED, 'soloist binaryPath (class method): installedBinaryPath()');
    is($Plugins::SpotOn::Soloist::GETCALLS, 0, 'soloist binaryPath: the activating get() is never called (WR-01)');
    @Plugins::SpotOn::Helper::ORDER = ();

    # qualityInfo($client): the Player page's quality block from the role
    my $qc = Test::SClient->new;
    local $Plugins::SpotOn::Soloist::Quality::NOTICE = { kind => 'rejected', wanted => 5, effective => 3 };
    local %Slim::Utils::Prefs::CLIENT = (soloistQuality => 'global');
    my $qi = eval { $S->qualityInfo($qc) } || {};
    is($qi->{supported}, 1, 'soloist qualityInfo($client): supported');
    is_deeply($qi->{validLevels}, [ 0, 2, 3, 4, 5 ], 'soloist qualityInfo($client): keeps validLevels');
    is_deeply($qi->{levels}, [ map { { value => $_, label => "S:Q$_" } } (0, 2, 3, 4, 5) ], 'soloist qualityInfo($client): levels with rendered labels');
    is($qi->{stored}, 'global', 'soloist qualityInfo($client): stored per-player value');
    is($qi->{effective}, 4, 'soloist qualityInfo($client): effective level from the cache');
    is($qi->{effectiveLabel}, 'S:Q4', 'soloist qualityInfo($client): effective label rendered');
    is($qi->{differs}, 1, 'soloist qualityInfo($client): effective (4) differs from wanted (5)');
    is($qi->{deviceKnown}, 1, 'soloist qualityInfo($client): deviceKnown from deviceIdForMac');
    is($qi->{noticeText}, 'REJ[S:Q5>S:Q3]', 'soloist qualityInfo($client): noticeText already formatted (labels resolved in the role)');
    ok(defined &Plugins::SpotOn::Backend::Soloist::_formatQualityNotice, 'the notice formatter lives on as the role-private Backend::Soloist::_formatQualityNotice');
    $Plugins::SpotOn::Soloist::Quality::NOTICE = { kind => 'no_token' };
    is(eval { $S->qualityInfo($qc)->{noticeText} }, 'S:PLUGIN_SPOTON_SOLOIST_QUALITY_NO_TOKEN', 'soloist noticeText: no_token');
    $Plugins::SpotOn::Soloist::Quality::NOTICE = undef;
    is(eval { $S->qualityInfo($qc)->{noticeText} }, '', 'soloist noticeText: empty without a notice');

    @Plugins::SpotOn::Soloist::Quality::APPLY = ();
    my $role = $S->new($MAC);
    $role->client($qc);
    is(eval { $role->quality(scope => 'player', level => 'global') }, 'ok', "soloist quality(scope => 'player') -> ok");
    is_deeply(\@Plugins::SpotOn::Soloist::Quality::APPLY, [ { scope => 'client', client => $qc, level => 5 } ],
        "soloist quality(scope => 'player'): applyChange(scope => client, level => effectiveLevelForClient) -- today's Player.pm call");
    @Plugins::SpotOn::Soloist::Quality::APPLY = ();
    my $slave = Test::SClient->new(id => '11:22:33:44:55:66');
    $role->quality(scope => 'player', client => $slave, level => 2);
    is(($Plugins::SpotOn::Soloist::Quality::APPLY[0] || {})->{client}, $slave,
        "soloist quality(scope => 'player', client => X): an explicit client wins over the role's (sync slave -> master role)");

    # autoplay capability: pinned from today's Player.pm (Helper->getCapability('autoplay'))
    for my $v (1, 0) {
        local %Plugins::SpotOn::Helper::CAP = (passthrough => 1, autoplay => $v);
        is($S->new($MAC)->capabilities->{autoplay}, $v, "soloist capabilities autoplay = today's Player.pm value: the Helper capability ($v)");
    }
}

# ------------------------------------------------------------
# capabilities(): the full key set and the pinned values
# ------------------------------------------------------------
my @CAP_KEYS = qw(contentType samplesize samplerate channels connectEntry formats seekViaRestart
                  ownsQueueInBrowse deferTrack deaden connectClaimGate claimOnStart holdOnChange
                  holdCapS holdRecheckS holdMaxS readyReplaysLastTrack passthrough autoplay connectSeekViaControl);
for my $cls ($S) {
    my $caps = $cls->new($MAC)->capabilities;
    is(ref $caps, 'HASH', "$cls: capabilities() is a hashref");
    is_deeply([ sort keys %$caps ], [ sort @CAP_KEYS ], "$cls: capabilities() has exactly the contract key set");
    is(ref $caps->{deaden}, 'ARRAY', "$cls: deaden is an arrayref");
}
my %LS_CAPS = (contentType => 'son', samplesize => 16, samplerate => 44100, channels => 2, connectEntry => 'repeating',
               deferTrack => 0, connectClaimGate => 1, claimOnStart => 1, holdOnChange => 0,
               holdCapS => 0, holdRecheckS => 0, holdMaxS => 0, readyReplaysLastTrack => 0,
               passthrough => 1);    # 84-12 W6: from the Helper stub (getCapability passthrough = 1)
my %SO_CAPS = (passthrough => 0, readyReplaysLastTrack => 1, formats => 'resolveSoloistFormat', contentType => 'soc', samplesize => 32, samplerate => 44100, channels => 2, connectEntry => 'pertrack',
               deferTrack => 1, connectClaimGate => 0, claimOnStart => 0, holdOnChange => 1,
               holdCapS     => Plugins::SpotOn::Soloist::Control::HOLD_CAP_S(),
               holdRecheckS => Plugins::SpotOn::Soloist::Control::HOLD_RECHECK_S(),
               holdMaxS     => Plugins::SpotOn::Soloist::Control::HOLD_MAX_S());
for my $k (sort keys %SO_CAPS) {
    is($S->new($MAC)->capabilities->{$k}, $SO_CAPS{$k}, "soloist capabilities $k = $SO_CAPS{$k}");
}
is_deeply([ @SO_CAPS{qw(holdCapS holdRecheckS holdMaxS)} ], [ 60, 5, 180 ], 'soloist hold constants are 60/5/180 (read from Control)');
is($S->new($MAC)->capabilities->{connectSeekViaControl}, 0, '79-28 D-23 seek: soloist capabilities connectSeekViaControl = 0 (D-B1 restart chain)');

# ------------------------------------------------------------
# 84-08 Task 2: capabilitiesDefault() -- the class-level, player-independent
# keys (the one contract member 84-08 adds; contentType's caller has no
# client). capabilities() on an instance = the default merged with the rest.
# ------------------------------------------------------------
my @DEFAULT_KEYS = qw(contentType samplesize samplerate channels connectEntry formats deferTrack
                      connectClaimGate claimOnStart holdOnChange passthrough);
for my $cls ($S) {
    ok($cls->can('capabilitiesDefault'), "$cls: capabilitiesDefault exists");
    my $def = $cls->can('capabilitiesDefault') ? $cls->capabilitiesDefault : {};
    is_deeply([ sort keys %$def ], [ sort @DEFAULT_KEYS ], "$cls: capabilitiesDefault has exactly the player-independent keys");
    my $caps = $cls->new($MAC)->capabilities;
    is_deeply({ map { $_ => $caps->{$_} } @DEFAULT_KEYS }, $def, "$cls: capabilities() carries capabilitiesDefault's values");
    my %rest = map { $_ => 1 } grep { !exists $def->{$_} } keys %$caps;
    is_deeply([ sort(keys %$def, keys %rest) ], [ sort keys %$caps ], "$cls: capabilities() = capabilitiesDefault + per-player keys (key-set compare)");
}
is($S->capabilitiesDefault->{formats}, 'resolveSoloistFormat', 'soloist formats = the soloist resolver name');
is($S->capabilitiesDefault->{contentType}, 'soc', 'soloist capabilitiesDefault contentType soc');

# ------------------------------------------------------------
# 84-12 Task 2 (W6): passthrough is the one dynamic default key -- librespot
# reads it from the Helper (lazy, eval-guarded), soloist pins 0.
# ------------------------------------------------------------
{
    local %Plugins::SpotOn::Helper::CAP = (passthrough => 1);
    %Plugins::SpotOn::Helper::CAP = (passthrough => 0);
    is($S->capabilitiesDefault->{passthrough}, 0, 'soloist capabilitiesDefault passthrough is 0');
}

# ------------------------------------------------------------
# 84-12 Task 2: lifecycle hooks exist on BOTH roles (a missing method would
# be a production die in DaemonManager), with the librespot answers
# restart / no-op / unsupported / undef.
# ------------------------------------------------------------
for my $cls ($S) {
    for my $m (qw(onDaemonExit onInitHelpers rollbackBinary pairedForMac prereqState capabilitiesDefault)) {
        ok($cls->can($m), "$cls: lifecycle hook $m exists");
    }
}
{
    my $dead = bless {}, 'Test::Helper';
    is(eval { $S->onDaemonExit($dead, 1) },  'restart', "soloist onDaemonExit(exit 1) -> 'restart'");
    is(eval { $S->onDaemonExit($dead, undef) }, 'restart', "soloist onDaemonExit(unknown exit code) -> 'restart'");

    local @Plugins::SpotOn::Soloist::ORDER = ();
    ok(eval { $S->onInitHelpers; 1 }, 'soloist onInitHelpers runs');
    is_deeply(\@Plugins::SpotOn::Soloist::ORDER, [qw(placed renewal)],
        'soloist onInitHelpers: placed-binary check then renewal-due, exactly once each');

    local @Plugins::SpotOn::Soloist::ROLLBACK = ();
    my @sr = eval { $S->rollbackBinary(reason => 'why') };
    is_deeply(\@sr, [1, '1.3.8.68'], 'soloist rollbackBinary returns rollbackToPrevious\'s (ok, detail)');
    is_deeply(\@Plugins::SpotOn::Soloist::ROLLBACK, [ { reason => 'why' } ], 'soloist rollbackBinary: rollbackToPrevious called once with the reason');

    local @Plugins::SpotOn::Soloist::RENEWAL_STATE = ();
    local @Plugins::SpotOn::Soloist::ROLLBACK_RET = (0, 'no_previous');
    my @nr = eval { $S->rollbackBinary(reason => 'why2') };
    is_deeply(\@nr, [0, 'no_previous'], 'soloist rollbackBinary: a terminal failure is returned unchanged');
    is_deeply(\@Plugins::SpotOn::Soloist::RENEWAL_STATE, [ { phase => 'rollback_impossible', detail => 'no_previous' } ],
        'soloist rollbackBinary: a terminal failure (no_previous) stamps rollback_impossible inside the role');
    @Plugins::SpotOn::Soloist::RENEWAL_STATE = ();
    @Plugins::SpotOn::Soloist::ROLLBACK_RET = (0, 'rollback_move_failed');
    eval { $S->rollbackBinary(reason => 'why3') };
    is_deeply(\@Plugins::SpotOn::Soloist::RENEWAL_STATE, [], 'soloist rollbackBinary: a transient failure stamps nothing');

    local $Plugins::SpotOn::Soloist::PAIRED = 1;
    is(eval { $S->pairedForMac($MAC) }, 1, 'soloist pairedForMac: paired on disk -> 1');
    $Plugins::SpotOn::Soloist::PAIRED = 0;
    is(eval { $S->pairedForMac($MAC) }, 0, 'soloist pairedForMac: not paired -> 0');
}

# ------------------------------------------------------------
# 84-08 Task 2: streamUrl browse_direct / connect_direct -- canDirectStream's
# backend halves. The streamingMode=proxy gate and the translated-history
# cleanup stay in ProtocolHandler (not tested here).
# ------------------------------------------------------------
{
    present();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = Test::StreamHelper->new(port => 4711);
    my $cl  = Test::SClient->new;
    my $syn = Test::SClient->new(synced => 1);

    # soloist browse_direct: the bounded /stream URL only for resolved pcm, unsynced
    $Plugins::SpotOn::Soloist::Control::CTL->{gen} = 2;
    is($S->new($MAC)->streamUrl($cl, 'spoton://track:abc', 'browse_direct'), 'http://192.0.2.9:4711/stream?uri=spotify:track:abc&g=3',
        'soloist browse_direct: http://<serverAddr>:<port>/stream?uri=spotify:track:<id>&g=<gen> (pcm, unsynced)');
    is($S->new($MAC)->streamUrl($syn, 'spoton://track:abc', 'browse_direct'), undef, 'soloist browse_direct: undef when synced');
    for my $fmt (qw(flac mp3)) {
        $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = $fmt;
        is($S->new($MAC)->streamUrl($cl, 'spoton://track:abc', 'browse_direct'), undef, "soloist browse_direct: undef when resolved=$fmt");
    }
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    $Slim::Utils::Prefs::CLIENT{streamFormat} = 'flac';
    %Slim::Utils::Prefs::CLIENT = ();
    is($S->new($MAC)->streamUrl($cl, 'spoton://connect-5', 'connect_direct'), 'http://192.0.2.9:4711/stream',
        'soloist connect_direct: http://<serverAddr>:<port>/stream (resolved pcm)');
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    is($S->new($MAC)->streamUrl($cl, 'spoton://connect-5', 'connect_direct'), undef, 'soloist connect_direct: undef when resolved=flac');
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    for my $cls ($S) {
        is($cls->new($MAC)->streamUrl($syn, 'spoton://connect-5', 'connect_direct'), undef, "$cls connect_direct: undef when synced");
    }

    # no daemon / dead daemon -> undef for every direct kind
    for my $h (undef, Test::StreamHelper->new(port => 4711, alive => 0)) {
        $Plugins::SpotOn::Unified::DaemonManager::HELPER = $h;
        my $tag = $h ? 'dead daemon' : 'no daemon';
        for my $cls ($S) {
            is($cls->new($MAC)->streamUrl($cl, 'spoton://track:abc', 'browse_direct'), undef, "$cls browse_direct: undef ($tag)");
            is($cls->new($MAC)->streamUrl($cl, 'spoton://connect-5', 'connect_direct'), undef, "$cls connect_direct: undef ($tag)");
        }
    }
}

# ------------------------------------------------------------
# state()
# ------------------------------------------------------------
present();
{
    my $so = $S->new($MAC)->state;
    is($so->{mode}, 'connect', 'soloist state: mode from Control');
    is($so->{status}, 'playing', 'soloist state: status from Control observed.status');
    is($so->{observedTrack}, 'spotify:track:abc', 'soloist state: observedTrack from Control observed.track');
    is($so->{active}, 1, 'soloist state: active from Control observed.is_active');
}
absent();
is($S->new($MAC)->state->{mode}, undef, 'soloist state without Control: mode undef');
# 84-08 (Status semantics, 82-11 WR-05): the observed field wins when made,
# else the filesystem pairing / the live WS socket; librespot: undef.
{
    present();
    my $so = $S->new($MAC)->state;
    is($so->{paired}, 1, 'soloist state: paired from Control observed.paired');
    is($so->{wsConnected}, 0, 'soloist state: wsConnected 0 without an observed value and without a WS socket');
    $Plugins::SpotOn::Soloist::Control::CTL->observed->{wsConnected} = 1;
    is($S->new($MAC)->state->{wsConnected}, 1, 'soloist state: wsConnected from Control observed.wsConnected');
    $Plugins::SpotOn::Soloist::Control::CTL->observed->{paired} = 0;
    local $Plugins::SpotOn::Soloist::PAIRED = 1;
    is($S->new($MAC)->state->{paired}, 0, 'soloist state: an observed paired 0 wins over the filesystem');
    absent();
    is($S->new($MAC)->state->{paired}, 1, 'soloist state without Control: paired from the filesystem (isPairedForClient)');
    $Plugins::SpotOn::Soloist::PAIRED = 0;
    is($S->new($MAC)->state->{paired}, 0, 'soloist state without Control, not paired on disk: paired 0 (defined)');
}

# ------------------------------------------------------------
# events contract: both backends emit only the seven spottyconnect verbs.
# Regex over source, verb literal only (_emit takes an optional 4th/5th
# argument since 84-17 -- the argument count is never pinned).
# ------------------------------------------------------------
my @SEVEN = qw(change ready resume seek start stop volume);
sub slurp { my $f = shift; open(my $fh, '<', $f) or die "$f: $!"; local $/; return <$fh>; }
my $control_src = slurp("$project_dir/Plugins/SpotOn/Soloist/Control.pm");
my @emits = $control_src =~ /^[^#\n]*_emit\('([a-z_]+)'/mg;
cmp_ok(scalar(@emits), '>=', 7, 'events: at least 7 literal _emit call sites in Control.pm (an empty sweep cannot pass)');
my %seven = map { $_ => 1 } @SEVEN;
is_deeply([ grep { !$seven{$_} } @emits ], [], 'events: every Control _emit verb is one of the seven');
like($control_src, qr/\('spottyconnect', \$cmd/, "events: Control's _emit dispatches through ['spottyconnect', \$cmd, ...]");

done_testing();
