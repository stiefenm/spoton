#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use B ();

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
for my $m (qw(requestPause requestResume requestVolume requestSkip requestRestart requestTrack endForeignLeave
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

# 85-07 D-10: the status page ring recorder.
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our (@RECORDED, @CLEARED, %HAS);
sub recordError {
    my ($class, $level, $module, $message, $key) = @_;
    push @RECORDED, [ $level, $module, $message, $key ];
    $HAS{ $module . '|' . ($key // '') } = 1;
}
sub clearError {
    my ($class, $module, $key) = @_;
    push @CLEARED, [ $module, $key ];
    delete $HAS{ $module . '|' . ($key // '') };
}
sub hasError {
    my ($class, $module, $key) = @_;
    return $HAS{ $module . '|' . ($key // '') } ? 1 : 0;
}
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
                 Plugins::SpotOn::Soloist::Control Plugins::SpotOn::API::Client Plugins::SpotOn::Status
                 Plugins::SpotOn::Soloist Plugins::SpotOn::Soloist::Quality Plugins::SpotOn::Helper)) {
    require_ok($stub) or BAIL_OUT("Failed to load the $stub stub");
}
require_ok('Plugins::SpotOn::Backend')            or BAIL_OUT('Backend.pm does not load');
require_ok('Plugins::SpotOn::Backend::Librespot') or BAIL_OUT('Backend/Librespot.pm does not load');

my $MAC = 'aa:bb:cc:dd:ee:ff';
my $L   = 'Plugins::SpotOn::Backend::Librespot';

sub posts { return @Slim::Networking::SimpleAsyncHTTP::POSTS; }

{
    package Test::Helper;    # present()'s daemon object: alive, no WS socket
    sub alive { return 1; }
}

# Scenario switch: (a) daemon / Control present, (b) absent.
sub present {
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
    @Plugins::SpotOn::API::Client::CALLS       = ();
    @Plugins::SpotOn::Status::RECORDED         = ();
    @Plugins::SpotOn::Status::CLEARED          = ();
    %Plugins::SpotOn::Status::HAS              = ();
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
    ok($L->can('prereqState'), 'librespot role: prereqState exists');

    local ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY, $Plugins::SpotOn::Soloist::WSLIB);
    local @Slim::Utils::Log::WARN = ();

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY, $Plugins::SpotOn::Soloist::WSLIB) = ('/fake/soloist', 1, 1);

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY) = (undef, 1);

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY) = ('/fake/soloist', 0);

    ($Plugins::SpotOn::Soloist::GET, $Plugins::SpotOn::Soloist::HASKEY, $Plugins::SpotOn::Soloist::WSLIB) = ('/fake/soloist', 1, 0);

    is(eval { $L->prereqState }, 'librespot', "librespot prereqState -> 'librespot'");
}

# ------------------------------------------------------------
# Object shape
# ------------------------------------------------------------
for my $cls ($L) {
    my $be = $cls->new($MAC);
    isa_ok($be, $cls);
    is($be->mac, $MAC, "$cls: mac() returns the constructor mac");
    for my $m (qw(control notify query capabilities state streamUrl daemonClass)) {
        ok($be->can($m), "$cls: role method $m exists");
    }
}
is($L->new($MAC)->daemonClass, 'Plugins::SpotOn::Unified::Daemon',        'librespot daemonClass');

# ------------------------------------------------------------
# control(): implemented verbs (Task 1 tracer: pause, play)
# ------------------------------------------------------------
{
    present();
    my $be = $L->new($MAC);
    is($be->control('pause', isStop => 0, source => 'lms_pause'), 'ok', 'librespot pause (port present) -> ok');
    my @p = posts();
    is(scalar(@p), 1, 'librespot pause: exactly one POST');
    is($p[0]{url}, 'http://127.0.0.1:4242/control/pause', 'librespot pause: POST to http://127.0.0.1:<port>/control/pause');
    is_deeply($p[0]{rest}, ['Content-Type', 'application/json', '{}'], 'librespot pause: JSON body {}');
    is_deeply($p[0]{opts}, { timeout => 5 }, 'librespot pause: 5s timeout');
}
{
    present();
    is($L->new($MAC)->control('play'), 'ok', 'librespot play (port present) -> ok');
    is((posts())[0]{url}, 'http://127.0.0.1:4242/control/play', 'librespot play: POST to /control/play');
}
{
    absent();
    is($L->new($MAC)->control('pause', isStop => 0), 'down', 'librespot pause without stream port -> down');
    is($L->new($MAC)->control('play'), 'down', 'librespot play without stream port -> down');
    is(scalar(posts()), 0, 'librespot down: no POST');
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'librespot down: no Web API fallback either');
}
{
    present();
    $L->new($MAC)->control('pause', isStop => 0);
    (posts())[0]->fire_error('500 Internal Server Error', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0,
        'librespot pause POST failed: no Web API call (85-07 D-10, the fallback is gone)');
    is_deeply([ map { [ @$_[0 .. 1], $_->[3] ] } @Plugins::SpotOn::Status::RECORDED ], [ [ 'warn', 'Connect', "daemon_unreachable:$MAC" ] ],
        'librespot pause POST failed: one "Daemon nicht erreichbar" status entry keyed daemon_unreachable:<mac>');
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/^\Q$MAC\E: Daemon nicht erreichbar \(\/control\/pause\)$/,
        'librespot pause POST failed: message "<mac>: Daemon nicht erreichbar (<endpoint>)"');
}
{
    present();
    @Slim::Control::Request::SENT = ();
    $L->new($MAC)->control('pause', isStop => 0);
    (posts())[0]->fire_error('409 Conflict', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'librespot 409: no Web API fallback (GH #159)');
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, 'librespot 409: no status entry (deselected device, not a dead daemon)');
    is_deeply([ map { join(' ', @{ $_->{args} }) } @Slim::Control::Request::SENT ], ['stop'], 'librespot 409: stale stream ejected with [stop]');
    is($Slim::Control::Request::SENT[-1]{source}, 'Plugins::SpotOn::Connect',
        "librespot 409: the stop stays source-marked as Plugins::SpotOn::Connect (Connect.pm _onPause's loop guard)");
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
my %LS_POST = (
    play       => [ '/control/play',   '{}',             [] ],
    pause      => [ '/control/pause',  '{}',             [ isStop => 1 ] ],
    set_volume => [ '/control/volume', '{"volume":55}',  [ volume => 55.7 ] ],
    skip_next  => [ '/control/next',   '{}',             [ reason => 'jump+1' ] ],
    skip_prev  => [ '/control/prev',   '{}',             [ reason => 'jump-1' ] ],
);
for my $verb (sort keys %LS_POST) {
    my ($endpoint, $body, $args) = @{ $LS_POST{$verb} };
    present();
    is($L->new($MAC)->control($verb, @$args), 'ok', "librespot $verb (present) -> ok");
    my @p = posts();
    is(scalar(@p), 1, "librespot $verb: exactly one POST");
    is($p[0] && $p[0]{url}, "http://127.0.0.1:4242$endpoint", "librespot $verb: POST to $endpoint");
    is_deeply($p[0] && $p[0]{rest}, ['Content-Type', 'application/json', $body], "librespot $verb: body $body");
    absent();
    is($L->new($MAC)->control($verb, @$args), 'down', "librespot $verb (no stream port) -> down");
    is(scalar(posts()), 0, "librespot $verb down: no POST");
}
{
    present();
    $L->new($MAC)->control('set_volume', volume => 40);
    my ($pv) = posts();
    ok($pv, 'librespot set_volume: POST issued (fallback precondition)');
    $pv->fire_error('500 Internal Server Error', undef) if $pv;
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'librespot set_volume POST failed: no Web API call (85-07 D-10)');
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, 'librespot set_volume POST failed: the dead endpoint is reported on the status page');
    present();
    $L->new($MAC)->control('skip_next', reason => 'jump+1');
    my ($pn) = posts();
    ok($pn, 'librespot skip_next: POST issued (fallback precondition)');
    $pn->fire_error('500 Internal Server Error', undef) if $pn;
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'librespot skip_next POST failed: no Web API call');
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, 'librespot skip_next POST failed: reported on the status page too');
}
for my $verb (qw(restart)) {
    present();
    is($L->new($MAC)->control($verb, position_ms => 5000, reason => 'jump+0'), 'unsupported', "librespot $verb -> unsupported (present)");
    is(scalar(posts()), 0, "librespot $verb: no POST");
    absent();
    is($L->new($MAC)->control($verb), 'unsupported', "librespot $verb -> unsupported (absent)");
}
# 79-28 D-23: the binary has POST /control/seek {"position_ms": N} (unified.rs:1250-1255)
{
    present();
    is($L->new($MAC)->control('seek', position_ms => 5000), 'ok', '79-28 D-23 seek: control(seek, position_ms 5000) with a stream port -> ok');
    my @p = posts();
    is(scalar(@p), 1, '79-28 D-23 seek: exactly one POST');
    is($p[0] && $p[0]{url}, 'http://127.0.0.1:4242/control/seek', '79-28 D-23 seek: POST goes to /control/seek');
    is_deeply($p[0] && $p[0]{rest}, ['Content-Type', 'application/json', '{"position_ms":5000}'], '79-28 D-23 seek: body {"position_ms":5000}');
    absent();
    is($L->new($MAC)->control('seek', position_ms => 5000), 'down', '79-28 D-23 seek: no stream port -> down');
    is(scalar(posts()), 0, '79-28 D-23 seek: down sends no POST');
    present();
    is($L->new($MAC)->control('seek'), 'declined', '79-28 D-23 seek: position_ms missing -> declined');
    is($L->new($MAC)->control('seek', position_ms => 'abc'), 'declined', '79-28 D-23 seek: position_ms not a number -> declined');
    is(scalar(posts()), 0, '79-28 D-23 seek: declined sends no POST');
    is($L->new($MAC)->control('seek', position_ms => -250), 'ok', '79-28 D-23 seek: a negative position is accepted and clamped');
    my ($pn) = posts();
    is_deeply($pn && $pn->{rest}, ['Content-Type', 'application/json', '{"position_ms":0}'], '79-28 D-23 seek: a negative position is sent as 0');
    is($L->new($MAC)->capabilities->{connectSeekViaControl}, 1, '79-28 D-23 seek: capabilities connectSeekViaControl = 1');
}
# quick 261022-b22: the JSON stub above is JSON::PP, which encodes an IV that
# only has a private string slot as a number, while LMS loads JSON::XS 2.34,
# which quotes it. These cells apply the JSON::XS rule (string slot -> JSON
# string) with a file-local strict encoder plus a direct SVp_POK flag check.
sub b22_xs_encode {
    my ($h) = @_;
    my @pairs;
    for my $k (sort keys %$h) {
        # flags FIRST, on the hash element itself: formatting below stringifies
        # a copy, and a read after that would see our own string slot
        my $fl = B::svref_2object(\$h->{$k})->FLAGS;
        die "b22_xs_encode: undef or reference value for $k" if !defined($h->{$k}) || ref($h->{$k});
        my $v = $h->{$k};
        if ($fl & B::SVp_POK()) {
            push @pairs, qq("$k":"$v");
        }
        elsif ($fl & (B::SVp_IOK() | B::SVp_NOK())) {
            push @pairs, qq("$k":$v);
        }
        else {
            die "b22_xs_encode: unsupported value type for $k";
        }
    }
    return '{' . join(',', @pairs) . '}';
}
{
    my $iv = 72000;
    my $str = "${iv}ms";    # interpolation gives $iv a private string slot
    is(b22_xs_encode({ k => $iv }), '{"k":"72000"}', 'b22 encoder self-check: interpolated IV encodes as a JSON string');
    is(b22_xs_encode({ k => 0 + $iv }), '{"k":72000}', 'b22 encoder self-check: fresh sum encodes as a JSON number');
}
sub b22_seek_cell {
    my ($label, $input, $expected, $diag) = @_;
    present();
    my @pok;
    my $ret;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::Librespot::to_json = sub {
            push @pok, (B::svref_2object(\$_[0]{position_ms})->FLAGS & B::SVp_POK()) ? 1 : 0;
            return b22_xs_encode($_[0]);
        };
        local *Slim::Utils::Log::is_info = sub { 0 } if $diag;
        local $Slim::Utils::Prefs::FAKE{diagnosticMode} = 1 if $diag;
        $ret = $L->new($MAC)->control('seek', position_ms => $input);
    }
    my @p = posts();
    is($ret, 'ok', "b22 seek: $label -> ok");
    is_deeply($p[0] && $p[0]{rest}, ['Content-Type', 'application/json', $expected], "b22 seek: $label body position_ms is a JSON number");
    ok(@pok && !$pok[0], "b22 seek: $label position_ms has no string slot at to_json");
}
b22_seek_cell('72000',    72000,    '{"position_ms":72000}');
b22_seek_cell('str72000', '72000',  '{"position_ms":72000}');
b22_seek_cell('neg250',   -250,     '{"position_ms":0}');
b22_seek_cell('diag72000', 72000,   '{"position_ms":72000}', 1);
for my $c (['num50', 50], ['str50', '50']) {
    my ($label, $vol) = @$c;
    present();
    my $ret;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::Librespot::to_json = sub { return b22_xs_encode($_[0]); };
        $ret = $L->new($MAC)->control('set_volume', volume => $vol);
    }
    my @p = posts();
    is($ret, 'ok', "b22 volume guard: $label -> ok");
    is_deeply($p[0] && $p[0]{rest}, ['Content-Type', 'application/json', '{"volume":50}'], "b22 volume guard: $label body volume is a JSON number");
}
for my $scenario (\&present, \&absent) {
    $scenario->();
    my $song = Test::Song->new;
    my $ok = 0;
    is($L->new($MAC)->control('track', source => 'getNextTrack', url => 'spoton://track:abc', song => $song,
                              successCb => sub { $ok++ }), 'ok', 'librespot track(getNextTrack) -> ok');
    is($song->track->samplesize, 16, 'librespot track(getNextTrack): samplesize reset to 16 (stale 32 cleared)');
    is($ok, 1, 'librespot track(getNextTrack): successCb called once');
    is($L->new($MAC)->control('track', source => 'onStream', url => 'spoton://track:abc'), 'unsupported',
        'librespot track(onStream) -> unsupported');
}

# Soloist: request* delegation table (verb, args, expected Control call)

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

# unknown verb
for my $cls ($L) {
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
    absent();
    present();
    is($L->new($MAC)->notify('endForeignLeave', reason => 'lms-stop'), 'unsupported', 'librespot notify(endForeignLeave) -> unsupported');
}
for my $cls ($L) {
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
        absent();
        present();
        is($L->new($MAC)->notify($ev, @$args), 'unsupported', "librespot notify('$ev') -> unsupported");
        is(scalar(@Plugins::SpotOn::Soloist::Control::CALLS), 0, "librespot notify('$ev'): no Control call");
    }
    # claimLost: the loser's observed is_active drops to 0 (D-D2), no request.
    present();
    my $ctl = $Plugins::SpotOn::Soloist::Control::CTL;
    absent();
    is($L->new($MAC)->notify('claimLost'), 'unsupported', "librespot notify('claimLost') -> unsupported");
}

# 84-08 Task 3: bootstrap / quality / qualityInfo (class methods).
{
    for my $cls ($L) {
        ok($cls->can('bootstrap'), "$cls: bootstrap exists");
        ok($cls->can('settingsInfo'), "$cls: settingsInfo exists");
    }
    @Plugins::SpotOn::Soloist::INIT = (); @Plugins::SpotOn::Soloist::ENSURE = ();
    my $before = $Plugins::SpotOn::Helper::INIT;
    is($L->bootstrap, 'ok', 'librespot bootstrap -> ok');
    is($Plugins::SpotOn::Helper::INIT, $before + 1, 'librespot bootstrap: Helper->init called (binary-path registration, BLOCKER 3)');

    @Plugins::SpotOn::Soloist::Quality::APPLY = ();
    is($L->quality(scope => 'global', level => 2), 'unsupported', 'librespot quality -> unsupported');
    is($L->qualityInfo->{supported}, 0, 'librespot qualityInfo: supported 0');
}

# 84-13 Task 1 (SEAM-6.2): the Soloist key store is a role capability --
# keyState() -> { supported, present }, storeKey($raw) -> (ok, reason),
# clearKey(). The librespot role answers "unsupported" and never reaches
# the Soloist module.
{
    for my $cls ($L) {
        ok($cls->can($_), "$cls: key-store method $_ exists (84-13)") for qw(keyState storeKey clearKey);
    }
    local $Plugins::SpotOn::Soloist::HASKEY = 1;
    $Plugins::SpotOn::Soloist::HASKEY = 0;

    my $raw = 'abcDEF123_-.abcDEF123';
    @Plugins::SpotOn::Soloist::STORE = ();
    @Slim::Utils::Log::INFO = (); @Slim::Utils::Log::WARN = ();
    @Plugins::SpotOn::Soloist::CLEAR = ();

    is_deeply(scalar(eval { $L->keyState }), { supported => 0, present => 0 }, 'librespot keyState: { supported => 0, present => 0 }');
    @Plugins::SpotOn::Soloist::STORE = (); @Plugins::SpotOn::Soloist::CLEAR = ();
    my @lr = eval { $L->storeKey($raw) };
    is_deeply(\@lr, [ 0, 'unsupported' ], "librespot storeKey -> (0, 'unsupported')");
    eval { $L->clearKey };
    is(scalar(@Plugins::SpotOn::Soloist::STORE) + scalar(@Plugins::SpotOn::Soloist::CLEAR), 0,
        'librespot storeKey/clearKey never reach the Soloist module');
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
        absent();
        present();
        is($L->new($MAC)->notify($ev, @$args), 'unsupported', "librespot notify('$ev') -> unsupported");
        is(scalar(@Plugins::SpotOn::Soloist::Control::CALLS), 0, "librespot notify('$ev'): no Control call");
    }
    for my $what (qw(seekable consumeRestartAllowance)) {
        present();
        $Plugins::SpotOn::Soloist::Control::RET{$what} = 1;
        present();
        $Plugins::SpotOn::Soloist::Control::RET{$what} = 0;
        absent();
        present();
        is($L->new($MAC)->query($what, url => 'spoton://track:a'), undef, "librespot query('$what') -> undef (no opinion)");
    }
}
present();
is($L->new($MAC)->query('wantedPositionMs'), undef, "librespot query('wantedPositionMs') -> undef (no opinion)");
# 85-07 D-09: with librespot there is no queue source -- the Up Next item is hidden
is($L->new($MAC)->query('queue'), undef, "librespot query('queue') -> undef (85-07 D-09: no queue source, the Up Next item is hidden)");
absent();

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

    is($L->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://track:abc'),
        'http://127.0.0.1:4711/track/abc', 'librespot streamUrl(browse_proxy): http://127.0.0.1:<port>/track/<id>');
    my $song = Test::SeekSong->new(track => Test::UrlTrack->new('spoton://episode:ep1'), seekdata => { timeOffset => 12 });
    is($L->new($MAC)->streamUrl($cl, $song, 'browse_proxy'),
        'http://127.0.0.1:4711/episode/ep1?start_position=12', 'librespot streamUrl(browse_proxy): song url + ?start_position=N');
    is($song->startOffset, 12, 'librespot streamUrl(browse_proxy): sets the song startOffset for a seek');

    $Plugins::SpotOn::Soloist::Control::CTL->{gen} = 6;
    $Plugins::SpotOn::Soloist::Control::CTL = undef;

    for my $cls ($L) {
        is($cls->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://connect-1'), undef,
            "$cls: streamUrl(browse_proxy) -> undef for a non-Browse URL");
        is($cls->new($MAC)->streamUrl(undef, undef, 'browse_proxy', url => 'spoton://track:abc'), undef,
            "$cls: streamUrl(browse_proxy) -> undef without a client");
    }

    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    for my $cls ($L) {
        is($cls->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://track:abc'), undef,
            "$cls: streamUrl(browse_proxy) -> undef when no daemon");
    }
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = Test::StreamHelper->new(port => 4711, alive => 0);
    for my $cls ($L) {
        is($cls->new($MAC)->streamUrl($cl, undef, 'browse_proxy', url => 'spoton://track:abc'), undef,
            "$cls: streamUrl(browse_proxy) -> undef when the daemon is not alive");
    }
}

# ------------------------------------------------------------
# 84-13 Task 2 (SEAM-6.2): routes / renewNow / renewStatus / binaryPath /
# qualityInfo($client) / quality(scope => 'player') / capabilities autoplay
# ------------------------------------------------------------
{
    for my $cls ($L) {
        ok($cls->can($_), "$cls: role method $_ exists (84-13)") for qw(routes renewNow renewStatus binaryPath qualityInfo quality);
    }
    is_deeply(scalar(eval { $L->routes }), [], 'librespot routes(): []');

    @Plugins::SpotOn::Soloist::RENEW = ();
    is_deeply(scalar(eval { $L->renewNow(reason => 'manual') }), { status => 'unsupported' }, 'librespot renewNow -> { status => unsupported }');

    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = ();
    is_deeply(scalar(eval { $L->renewStatus() }), { supported => 0 }, 'librespot renewStatus -> { supported => 0 }');

    $Plugins::SpotOn::Soloist::GETCALLS = 0;
    @Plugins::SpotOn::Helper::ORDER = ();
    is(eval { $L->binaryPath }, $Plugins::SpotOn::Helper::PATH, 'librespot binaryPath (class method): the Helper->get path');
    is_deeply(\@Plugins::SpotOn::Helper::ORDER, [ 'init', 'get' ], 'librespot binaryPath: Helper->init (once-guarded in Helper.pm) before Helper->get');

    # qualityInfo($client): the Player page's quality block from the role
    my $qc = Test::SClient->new;
    local $Plugins::SpotOn::Soloist::Quality::NOTICE = { kind => 'rejected', wanted => 5, effective => 3 };
    local %Slim::Utils::Prefs::CLIENT = (soloistQuality => 'global');
    $Plugins::SpotOn::Soloist::Quality::NOTICE = { kind => 'no_token' };
    $Plugins::SpotOn::Soloist::Quality::NOTICE = undef;
    is_deeply(scalar(eval { $L->qualityInfo($qc) }), { supported => 0, validLevels => [] }, 'librespot qualityInfo($client): supported 0');

    @Plugins::SpotOn::Soloist::Quality::APPLY = ();
    @Plugins::SpotOn::Soloist::Quality::APPLY = ();
    my $slave = Test::SClient->new(id => '11:22:33:44:55:66');
    is(eval { $L->new($MAC)->quality(scope => 'player', level => 2) }, 'unsupported', "librespot quality(scope => 'player') -> unsupported");

    # autoplay capability: pinned from today's Player.pm (Helper->getCapability('autoplay'))
    for my $v (1, 0) {
        local %Plugins::SpotOn::Helper::CAP = (passthrough => 1, autoplay => $v);
        is($L->new($MAC)->capabilities->{autoplay}, $v, "librespot capabilities autoplay follows the Helper capability ($v)");
    }
}

# ------------------------------------------------------------
# capabilities(): the full key set and the pinned values
# ------------------------------------------------------------
my @CAP_KEYS = qw(contentType samplesize samplerate channels connectEntry formats seekViaRestart
                  ownsQueueInBrowse deferTrack deaden connectClaimGate claimOnStart holdOnChange
                  holdCapS holdRecheckS holdMaxS readyReplaysLastTrack passthrough autoplay connectSeekViaControl);
for my $cls ($L) {
    my $caps = $cls->new($MAC)->capabilities;
    is(ref $caps, 'HASH', "$cls: capabilities() is a hashref");
    is_deeply([ sort keys %$caps ], [ sort @CAP_KEYS ], "$cls: capabilities() has exactly the contract key set");
    is(ref $caps->{deaden}, 'ARRAY', "$cls: deaden is an arrayref");
}
my %LS_CAPS = (contentType => 'son', samplesize => 16, samplerate => 44100, channels => 2, connectEntry => 'repeating',
               deferTrack => 0, connectClaimGate => 1, claimOnStart => 1, holdOnChange => 0,
               holdCapS => 0, holdRecheckS => 0, holdMaxS => 0, readyReplaysLastTrack => 0,
               passthrough => 1);    # 84-12 W6: from the Helper stub (getCapability passthrough = 1)
for my $k (sort keys %LS_CAPS) {
    is($L->new($MAC)->capabilities->{$k}, $LS_CAPS{$k}, "librespot capabilities $k = $LS_CAPS{$k}");
}
{
    my $c = $L->new($MAC)->capabilities;
    $c->{connectClaimGate} = 99;
    is($L->new($MAC)->capabilities->{connectClaimGate}, 1, 'capabilities() returns a copy (caller mutation does not leak)');
}

# ------------------------------------------------------------
# 84-08 Task 2: capabilitiesDefault() -- the class-level, player-independent
# keys (the one contract member 84-08 adds; contentType's caller has no
# client). capabilities() on an instance = the default merged with the rest.
# ------------------------------------------------------------
my @DEFAULT_KEYS = qw(contentType samplesize samplerate channels connectEntry formats deferTrack
                      connectClaimGate claimOnStart holdOnChange passthrough);
for my $cls ($L) {
    ok($cls->can('capabilitiesDefault'), "$cls: capabilitiesDefault exists");
    my $def = $cls->can('capabilitiesDefault') ? $cls->capabilitiesDefault : {};
    is_deeply([ sort keys %$def ], [ sort @DEFAULT_KEYS ], "$cls: capabilitiesDefault has exactly the player-independent keys");
    my $caps = $cls->new($MAC)->capabilities;
    is_deeply({ map { $_ => $caps->{$_} } @DEFAULT_KEYS }, $def, "$cls: capabilities() carries capabilitiesDefault's values");
    my %rest = map { $_ => 1 } grep { !exists $def->{$_} } keys %$caps;
    is_deeply([ sort(keys %$def, keys %rest) ], [ sort keys %$caps ], "$cls: capabilities() = capabilitiesDefault + per-player keys (key-set compare)");
}
is($L->capabilitiesDefault->{formats}, 'resolveServedPassthroughForClient', 'librespot formats = the served-passthrough resolver name (79-34 D-29)');
is($L->capabilitiesDefault->{contentType}, 'son', 'librespot capabilitiesDefault contentType son');

# ------------------------------------------------------------
# 84-12 Task 2 (W6): passthrough is the one dynamic default key -- librespot
# reads it from the Helper (lazy, eval-guarded), soloist pins 0.
# ------------------------------------------------------------
{
    local %Plugins::SpotOn::Helper::CAP = (passthrough => 1);
    is($L->capabilitiesDefault->{passthrough}, 1, 'librespot capabilitiesDefault passthrough follows the Helper capability (1)');
    is($L->new($MAC)->capabilities->{passthrough}, 1, 'librespot capabilities() carries the same passthrough value (1)');
    %Plugins::SpotOn::Helper::CAP = (passthrough => 0);
    is($L->capabilitiesDefault->{passthrough}, 0, 'librespot capabilitiesDefault passthrough follows the Helper capability (0)');
    is($L->new($MAC)->capabilities->{passthrough}, 0, 'librespot capabilities() carries the same passthrough value (0)');
}

# ------------------------------------------------------------
# 84-12 Task 2: lifecycle hooks exist on BOTH roles (a missing method would
# be a production die in DaemonManager), with the librespot answers
# restart / no-op / unsupported / undef.
# ------------------------------------------------------------
for my $cls ($L) {
    for my $m (qw(onDaemonExit onInitHelpers rollbackBinary pairedForMac prereqState capabilitiesDefault)) {
        ok($cls->can($m), "$cls: lifecycle hook $m exists");
    }
}
{
    my $dead = bless {}, 'Test::Helper';
    is(eval { $L->onDaemonExit($dead, 1) },  'restart', "librespot onDaemonExit(exit 1) -> 'restart'");
    is(eval { $L->onDaemonExit($dead, 10) }, 'restart', "librespot onDaemonExit(exit 10) -> 'restart' (no expiry concept)");

    local @Plugins::SpotOn::Soloist::ORDER = ();
    ok(eval { $L->onInitHelpers; 1 }, 'librespot onInitHelpers runs (no-op)');
    is_deeply(\@Plugins::SpotOn::Soloist::ORDER, [], 'librespot onInitHelpers touches no Soloist check');

    local @Plugins::SpotOn::Soloist::ROLLBACK = ();
    my @lr = eval { $L->rollbackBinary(reason => 'why') };
    is($lr[1], 'unsupported', "librespot rollbackBinary -> (0, 'unsupported')");
    ok(!$lr[0], 'librespot rollbackBinary: not ok');
    is_deeply(\@Plugins::SpotOn::Soloist::ROLLBACK, [], 'librespot rollbackBinary never reaches the Soloist rollback');

    local @Plugins::SpotOn::Soloist::RENEWAL_STATE = ();
    local @Plugins::SpotOn::Soloist::ROLLBACK_RET = (0, 'no_previous');
    @Plugins::SpotOn::Soloist::RENEWAL_STATE = ();
    @Plugins::SpotOn::Soloist::ROLLBACK_RET = (0, 'rollback_move_failed');

    local $Plugins::SpotOn::Soloist::PAIRED = 1;
    $Plugins::SpotOn::Soloist::PAIRED = 0;
    ok(!defined(eval { $L->pairedForMac($MAC) }), 'librespot pairedForMac -> undef (no pairing concept)');
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

    # librespot browse_direct: the REAL direct URL (84-07 Deviation 4)
    is($L->new($MAC)->streamUrl($cl, 'spoton://track:abc', 'browse_direct'), 'http://192.0.2.9:4711/track/abc',
        'librespot browse_direct: http://<serverAddr>:<port>/track/<id> (unsynced, alive, port)');
    is($L->new($MAC)->streamUrl($cl, 'spoton://episode:e1', 'browse_direct'), 'http://192.0.2.9:4711/episode/e1',
        'librespot browse_direct: /episode/<id>');
    is($L->new($MAC)->streamUrl($syn, 'spoton://track:abc', 'browse_direct'), undef, 'librespot browse_direct: undef when synced');

    # soloist browse_direct: the bounded /stream URL only for resolved pcm, unsynced
    $Plugins::SpotOn::Soloist::Control::CTL->{gen} = 2;
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';

    # connect_direct
    is($L->new($MAC)->streamUrl($cl, 'spoton://connect-5', 'connect_direct'), 'http://192.0.2.9:4711/stream',
        'librespot connect_direct: http://<serverAddr>:<port>/stream');
    $Slim::Utils::Prefs::CLIENT{streamFormat} = 'flac';
    is($L->new($MAC)->streamUrl($cl, 'spoton://connect-5', 'connect_direct'), undef, 'librespot connect_direct: undef when streamFormat forces transcoding');
    %Slim::Utils::Prefs::CLIENT = ();
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    for my $cls ($L) {
        is($cls->new($MAC)->streamUrl($syn, 'spoton://connect-5', 'connect_direct'), undef, "$cls connect_direct: undef when synced");
    }

    # no daemon / dead daemon -> undef for every direct kind
    for my $h (undef, Test::StreamHelper->new(port => 4711, alive => 0)) {
        $Plugins::SpotOn::Unified::DaemonManager::HELPER = $h;
        my $tag = $h ? 'dead daemon' : 'no daemon';
        for my $cls ($L) {
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
    my $st = $L->new($MAC)->state;
    is($st->{mode}, undef, 'librespot state: mode undef');
    is($st->{alive}, 1, 'librespot state: alive 1 with a live helper');
    is($st->{active}, undef, 'librespot state: active undef');
}
absent();
is($L->new($MAC)->state->{alive}, 0, 'librespot state: alive 0 without a helper');
# 84-08 (Status semantics, 82-11 WR-05): the observed field wins when made,
# else the filesystem pairing / the live WS socket; librespot: undef.
{
    present();
    $Plugins::SpotOn::Soloist::Control::CTL->observed->{wsConnected} = 1;
    $Plugins::SpotOn::Soloist::Control::CTL->observed->{paired} = 0;
    local $Plugins::SpotOn::Soloist::PAIRED = 1;
    absent();
    $Plugins::SpotOn::Soloist::PAIRED = 0;
    is($L->new($MAC)->state->{paired}, undef, 'librespot state: paired undef (no pairing concept)');
    is($L->new($MAC)->state->{wsConnected}, undef, 'librespot state: wsConnected undef');
}

# ------------------------------------------------------------
# events contract: both backends emit only the seven spottyconnect verbs.
# Regex over source, verb literal only (_emit takes an optional 4th/5th
# argument since 84-17 -- the argument count is never pinned).
# ------------------------------------------------------------
sub slurp { my $f = shift; open(my $fh, '<', $f) or die "$f: $!"; local $/; return <$fh>; }

done_testing();
