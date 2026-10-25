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

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 1 };
    *main::DEBUGLOG = sub () { 0 };
    *main::SCANNER  = sub () { 0 };
}

# 84-09: core half of t/57_backend_role.t -- the registry (names, classFor,
# available, the absent-role case) over per-file MOCK role classes, and the
# Connect.pm side of the events contract. The real-role verb/capability/
# lifecycle cells are t/librespot/ and t/soloist/57_backend_role_*.t.
my $role_dir = tempdir(CLEANUP => 1);
# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $role_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($role_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }

1;
END

write_stub($role_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }

1;
END

unshift @INC, $stub_dir, $role_dir, $project_dir;

# 84-09 (core half): only the LMS/core doubles -- the Soloist-module stubs and
# both REAL role classes belong to t/soloist/ and t/librespot/57_backend_role_*.t.
for my $stub (qw(Slim::Player::Client Slim::Control::Request Plugins::SpotOn::Unified::DaemonManager Slim::Utils::Network
                 Plugins::SpotOn::API::Client Plugins::SpotOn::Helper)) {
    require_ok($stub) or BAIL_OUT("Failed to load the $stub stub");
}
require_ok('Plugins::SpotOn::Backend')            or BAIL_OUT('Backend.pm does not load');

my $L   = 'Plugins::SpotOn::Backend::Librespot';
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
# Registry
# ------------------------------------------------------------
is_deeply([ Plugins::SpotOn::Backend::names() ], [qw(librespot soloist)], 'names() is (librespot soloist)');
is(Plugins::SpotOn::Backend::classFor('librespot'), $L, "classFor('librespot') -> Backend::Librespot");
is(Plugins::SpotOn::Backend::classFor('soloist'),   $S, "classFor('soloist') -> Backend::Soloist");
ok(!eval { Plugins::SpotOn::Backend::classFor('nope'); 1 }, "classFor('nope') dies");
like($@, qr/unknown backend/i, 'classFor dies with an "unknown backend" message');

# ------------------------------------------------------------
# 84-12 Task 1 (W5, revision 11): registry robustness. available() lists the
# registered names whose module loads; classFor keeps DYING on an unknown
# name and on a known name whose module does not load. The absent-module
# case runs against a module-root copy that lacks Backend/Soloist.pm.
# ------------------------------------------------------------
{
    ok(Plugins::SpotOn::Backend->can('available'), 'registry: available() exists');
    my @all = eval { Plugins::SpotOn::Backend::available() };
    is_deeply(\@all, [qw(librespot soloist)], 'available() lists both backends when both modules load');

    my $copy_root = tempdir(CLEANUP => 1);
    make_path("$copy_root/Plugins/SpotOn/Backend");
    # 84-09 (core half): the real registry and the librespot MOCK role -- no
    # real backend module is read.
    for my $pair (['Plugins/SpotOn/Backend.pm', $project_dir], ['Plugins/SpotOn/Backend/Librespot.pm', $role_dir]) {
        my ($rel, $from) = @$pair;
        open(my $in,  '<', "$from/$rel") or die "read $rel: $!";
        open(my $out, '>', "$copy_root/$rel")   or die "write $rel: $!";
        print $out do { local $/; <$in> };
        close $out;
    }
    ok(!-e "$copy_root/Plugins/SpotOn/Backend/Soloist.pm", 'module-root copy lacks Backend/Soloist.pm');

    local @INC = ($stub_dir, $copy_root);
    my $saved = delete $INC{'Plugins/SpotOn/Backend/Soloist.pm'};
    local %Plugins::SpotOn::Backend::UNAVAILABLE = ();
    local @Slim::Utils::Log::WARN = ();

    my @avail1 = eval { Plugins::SpotOn::Backend::available() };
    my @avail2 = eval { Plugins::SpotOn::Backend::available() };
    is_deeply(\@avail1, ['librespot'], 'absent Soloist role: available() lists only librespot');
    is_deeply(\@avail2, ['librespot'], 'absent Soloist role: a second available() call gives the same list');
    is(scalar(grep { /soloist/ } @Slim::Utils::Log::WARN), 1,
       'absent Soloist role: available() warns exactly once for the failing name');

    ok(!eval { Plugins::SpotOn::Backend::classFor('soloist'); 1 }, "absent Soloist role: classFor('soloist') dies");
    like($@, qr/Can't locate/, "absent Soloist role: classFor('soloist') dies with Can't locate");
    ok(!eval { Plugins::SpotOn::Backend::classFor('nope'); 1 }, "absent Soloist role: classFor('nope') still dies");
    like($@, qr/unknown backend/i, 'absent Soloist role: unknown name still dies with "unknown backend"');
    is(Plugins::SpotOn::Backend::classFor('librespot'), $L, "absent Soloist role: classFor('librespot') still loads");

    $INC{'Plugins/SpotOn/Backend/Soloist.pm'} = $saved;
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

# ------------------------------------------------------------
# capabilities(): the full key set and the pinned values
# ------------------------------------------------------------
my %LS_CAPS = (contentType => 'son', samplesize => 16, samplerate => 44100, channels => 2, connectEntry => 'repeating',
               deferTrack => 0, connectClaimGate => 1, claimOnStart => 1, holdOnChange => 0,
               holdCapS => 0, holdRecheckS => 0, holdMaxS => 0, readyReplaysLastTrack => 0,
               passthrough => 1);    # 84-12 W6: from the Helper stub (getCapability passthrough = 1)

# ------------------------------------------------------------
# 84-08 Task 2: capabilitiesDefault() -- the class-level, player-independent
# keys (the one contract member 84-08 adds; contentType's caller has no
# client). capabilities() on an instance = the default merged with the rest.
# ------------------------------------------------------------

# ------------------------------------------------------------
# events contract: both backends emit only the seven spottyconnect verbs.
# Regex over source, verb literal only (_emit takes an optional 4th/5th
# argument since 84-17 -- the argument count is never pinned).
# ------------------------------------------------------------
my @SEVEN = qw(change ready resume seek start stop volume);
sub slurp { my $f = shift; open(my $fh, '<', $f) or die "$f: $!"; local $/; return <$fh>; }
my $connect_src = slurp("$project_dir/Plugins/SpotOn/Connect.pm");
my ($ce) = $connect_src =~ /(sub _connectEvent \{.*?\n\})\n/s;
ok($ce, 'events: _connectEvent body parseable');
my %handled = map { $_ => 1 } (($ce // '') =~ /\$cmd eq '([a-z_]+)'/g);
is_deeply([ sort keys %handled ], \@SEVEN, '_connectEvent dispatches exactly the seven spottyconnect verbs');

done_testing();
