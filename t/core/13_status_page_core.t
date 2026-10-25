#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use JSON::PP ();

# ============================================================
# FakeStatusResponse — minimal Slim::Web response double for exercising
# _statusDataHandler directly (Plan 52-03 Task 3): supports the
# header/code/content_type accessor calls made by _jsonResponse.
# ============================================================
package FakeStatusResponse;
sub new { return bless { headers => {} }, shift }
sub header {
    my $self = shift;
    if (@_ == 2) { $self->{headers}{ $_[0] } = $_[1]; return $_[1]; }
    return $self->{headers}{ $_[0] };
}
sub code         { my $self = shift; $self->{code}         = $_[0] if @_; return $self->{code}; }
sub content_type { my $self = shift; $self->{content_type} = $_[0] if @_; return $self->{content_type}; }

package main;

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# Create a temporary directory for LMS stubs
my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module
# ============================================================
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
# LMS Module Stubs
# ============================================================

# Stub: Log::Log4perl::Logger
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Log::Log4perl
write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Slim::Utils::Log
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info     { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn     { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error    { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug    { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init { }
sub get  { \$_store{\$_[0]->{_ns}}{\$_[1]} }
sub set  { \$_store{\$_[0]->{_ns}}{\$_[1]} = \$_[2] }
sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache (in-memory)
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

# Stub: Slim::Utils::Timers
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
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

# Stub: Slim::Web::Pages
write_stub($stub_dir, 'Slim::Web::Pages', <<'END');
package Slim::Web::Pages;
sub addPageFunction { }
sub addRawFunction  { }
1;
END

# Stub: URI::Escape (Client.pm dependency, not available in CI)
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape uri_escape_utf8);
sub uri_escape { $_[0] }
sub uri_escape_utf8 { $_[0] }
1;
END

# Stub: Slim::Web::HTTP
# addHTTPResponse records its call args so tests can inspect the JSON bytes
# written by _jsonResponse (Plan 52-03: madeForYou D-04 channel 3 check).
write_stub($stub_dir, 'Slim::Web::HTTP', <<'END');
package Slim::Web::HTTP;
our @http_responses = ();
sub addHTTPResponse { push @http_responses, [@_] }
sub filltemplatefile { \'' }
sub reset_calls { @http_responses = () }
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless { _success => $_[1], _error => $_[2] }, shift }
sub get  { }
sub post { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: JSON::XS::VersionOneAndTwo
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# Stub: Slim::Plugin::OPMLBased
write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new        { bless {}, shift }
sub initPlugin { }
sub _pluginDataFor { 'test-version' }
sub AUTOLOAD   { }
sub can        { 1 }
1;
END

# Stub: Time::HiRes
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
sub time  { CORE::time() }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: Slim::Player::Client. getClient() returns a fake client whose
# isPlaying()/isSynced() are fixed (Phase 82, T-7: _collectDaemons' paired/
# wsConnected gate needs $playing to start at 1 so the gate's zeroing is
# actually observable, not just "always 0 because no client").
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient {
    my ($mac) = @_;
    return Test::FakeStatusClient->new($mac);
}
sub AUTOLOAD { }
sub can { 1 }
1;

package Test::FakeStatusClient;
sub new { my ($class, $mac) = @_; return bless { mac => $mac }, $class; }
sub name      { return $_[0]->{mac} }
sub can       { my ($self, $method) = @_; return $method eq 'name' ? 1 : 0; }
sub isPlaying { return 1; }
sub isSynced  { return 0; }
1;
END

# Stub: Slim::Player::Playlist (Phase 82, T-7 -- see Slim::Player::Client
# stub above for why isPlaying()/url() are fixed rather than undef/off).
write_stub($stub_dir, 'Slim::Player::Playlist', <<'END');
package Slim::Player::Playlist;
sub url { return 'spoton://track:abc' }
1;
END

# Stub: Slim::Player::ProtocolHandlers
write_stub($stub_dir, 'Slim::Player::ProtocolHandlers', <<'END');
package Slim::Player::ProtocolHandlers;
sub registerHandler { }
1;
END

# Stub: Slim::Web::Settings
write_stub($stub_dir, 'Slim::Web::Settings', <<'END');
package Slim::Web::Settings;
sub new     { bless {}, shift }
sub handler { }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Slim::Web::HTTP::CSRF
write_stub($stub_dir, 'Slim::Web::HTTP::CSRF', <<'END');
package Slim::Web::HTTP::CSRF;
sub protectCommand { $_[1] }
sub protectName    { $_[1] }
sub protectURI     { $_[1] }
1;
END

# Stub: Slim::Formats::RemoteStream
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Stub: Slim::Utils::Strings
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub string  { }
sub cstring { }
1;
END

# Stub: Slim::Utils::Unicode
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

# Stub: Slim::Utils::Versions
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

# Stub: Slim::Utils::Misc
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub findbin { }
sub addFindBinPaths { }
1;
END

# Stub: Slim::Utils::OSDetect
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub OS      { 'unix' }
sub details { return { osArch => 'x86_64' } }
sub getOS   { return bless {}, 'Slim::Utils::OSDetect' }
sub decodeExternalHelperPath { $_[1] }
1;
END

# Stub: File::Spec::Functions
# catdir/catfile are inherited by File::Spec from File::Spec::Unix -- a
# direct typeglob alias (\&File::Spec::catdir) does not resolve inherited
# methods, so it must call through as a class method instead (Plan 66-02
# Task 2: exercising _collectAuthHealth directly now requires this path,
# via PKCE.pm's _accountDir -- previously latent because getAccountIds()
# always returned an empty list).
write_stub($stub_dir, 'File::Spec::Functions', <<'END');
package File::Spec::Functions;
use parent 'Exporter';
use File::Spec ();
our @EXPORT_OK = qw(catdir catfile);
sub catdir  { return File::Spec->catdir(@_); }
sub catfile { return File::Spec->catfile(@_); }
1;
END

# Stub: Slim::Utils::Accessor
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { bless {}, shift }
sub mk_accessor { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Control::Request
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
sub new { bless {}, shift }
sub addDispatch { }
sub subscribe { }
sub unsubscribe { }
sub notifyFromArray { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Music::Info
write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
sub setRemoteMetadata { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Player::Source
write_stub($stub_dir, 'Slim::Player::Source', <<'END');
package Slim::Player::Source;
sub songTime { 0 }
1;
END

# Stub: Slim::Player::Sync
write_stub($stub_dir, 'Slim::Player::Sync', <<'END');
package Slim::Player::Sync;
sub syncname { '' }
1;
END

# Stub: Plugins::SpotOn::Helper (needed by Status.pm _systemInfo)
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
sub get { return wantarray ? ('/usr/bin/spoton', '1.0.0-test') : '/usr/bin/spoton' }
sub getVersion { '1.0.0-test' }
sub getCapability { {} }
1;
END

# Stub: Plugins::SpotOn::Plugin (needed by Status.pm _systemInfo for _pluginDataFor)
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;   # M5: mirrors real Plugin.pm constant
sub _pluginDataFor { 'test-version' }
1;
END

# Stub: Plugins::SpotOn::Unified::DaemonManager (needed by Status.pm
# _collectDaemons). @HELPERS is controllable by tests (Phase 82, T-7
# paired/wsConnected coverage) -- defaults to empty like before.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our @HELPERS = ();
sub helperInstances { return @HELPERS }
# 84.1 plan 03 (D-04): Status.pm's _collectDaemons now reads these for its
# controlMode/health fields -- undef for every MAC in this stub (no test
# here exercises the health tick itself, only that the fields exist and
# stay undef/null for a helper the tick has never touched).
sub soloistHealthFor  { return undef }
sub crashStateSnapshot { return undef }
# 74b-03 (D-09): the status data handler re-asserts the standing conditions
# before it builds errors[]. Counter plus an order probe: the first call
# records an entry the response must already contain.
our $ASSERT_CALLS = 0;
sub assertStandingConditions {
    $ASSERT_CALLS++;
    Plugins::SpotOn::Status->recordError('error', 'Soloist', 'standing glibc test message', 'glibc')
        unless Plugins::SpotOn::Status->hasError('Soloist', 'glibc');
    return 1;
}
# 84-08 (SEAM-6.2): Status.pm reads paired/wsConnected/mode from the backend
# role's state(). This factory hands out the REAL role class per helper --
# Backend::Soloist for a SoloistDaemon-class helper, Backend::Librespot
# otherwise -- so every T-7/WR-05 cell below exercises the production state()
# logic over the Control/Soloist/WS doubles (assertions unchanged).
sub helperForClient {
    my ($class, $mac) = @_;
    $mac = $mac->id if ref $mac;
    my ($h) = grep { $_->mac eq $mac } @HELPERS;
    return ($h && $h->alive) ? $h : undef;
}
sub backendFor {
    my ($class, $mac) = @_;
    $mac = $mac->id if ref $mac;
    my ($h) = grep { $_->mac eq $mac } @HELPERS;
    my $role = ($h && $h->isa('Plugins::SpotOn::Unified::SoloistDaemon'))
        ? 'Plugins::SpotOn::Backend::Soloist' : 'Plugins::SpotOn::Backend::Librespot';
    (my $file = "$role.pm") =~ s{::}{/}g;
    require $file;
    return $role->new($mac);
}
1;
END

# Stub: Plugins::SpotOn::Unified::SoloistDaemon (Phase 82, T-7) -- a fake
# Soloist helper, blessed into the real class name so
# $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon') is true in
# Status.pm _collectDaemons, mirroring t/29_soloist_browse.t's pattern.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::SoloistDaemon', <<'END');
package Plugins::SpotOn::Unified::SoloistDaemon;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub mac                { return $_[0]->{mac} }
sub alive               { return $_[0]->{alive} }
sub pid                 { return $_[0]->{pid} }
sub uptime              { return $_[0]->{uptime} }
sub _connectEnabled     { return $_[0]->{connectEnabled} }
sub _streamPort         { return $_[0]->{streamPort} }
sub _lastHealthSession  { return $_[0]->{sessionHealth} }
sub _ws                 { return $_[0]->{ws} }
1;

package Test::FakeSoloistWS;
sub new { my ($class, $connected) = @_; return bless { connected => $connected }, $class; }
sub connected { return $_[0]->{connected} }
1;
END

# Stub: Plugins::SpotOn::Unified::Daemon (Phase 82, T-7) -- a fake
# librespot-style helper with no _ws method at all, so
# $helper->can('_ws') is false and the isa-check-before-_ws-access path in
# _collectDaemons is exercised for the non-Soloist case.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub mac                { return $_[0]->{mac} }
sub alive               { return $_[0]->{alive} }
sub pid                 { return $_[0]->{pid} }
sub uptime              { return $_[0]->{uptime} }
sub _connectEnabled     { return $_[0]->{connectEnabled} }
sub _streamPort         { return $_[0]->{streamPort} }
sub _lastHealthSession  { return $_[0]->{sessionHealth} }
1;
END

# Stub: Plugins::SpotOn::Soloist (Phase 82, T-7) -- isPairedForClient() is
# controllable by tests via %PAIRED, keyed by mac.
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
our %PAIRED = ();
sub isPairedForClient { return $PAIRED{$_[0]} // 0 }
1;
END

# Stub: Plugins::SpotOn::Soloist::Control (82-11, WR-05) -- for_client($mac)
# is controllable per test via %CONTROLS, keyed by mac -> a fake Control
# object exposing ->observed (hashref with paired/wsConnected keys, either
# of which may be legitimately absent -- "no auth_state yet"). Returns
# undef for any mac not registered, mirroring the real for_client's
# "no Control for this player" contract (WR-05 Fall D: the filesystem
# fallback path).
write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Control', <<'END');
package Plugins::SpotOn::Soloist::Control;
our %CONTROLS = ();
sub for_client { my ($class, $mac) = @_; return $CONTROLS{$mac}; }
sub new { my ($class, %args) = @_; return bless { observed => ($args{observed} || {}), mode => ($args{mode} // 'idle') }, $class; }
sub observed { return $_[0]->{observed}; }
# 84.1 plan 03 (D-04): Status.pm's _collectDaemons now reads ->mode for its
# controlMode field whenever a Control is registered for this MAC.
sub mode { return $_[0]->{mode}; }
1;
END

# Stub: Plugins::SpotOn::ProtocolHandler (needed by Status.pm
# _collectDaemons when a client is reported as playing a spoton: URL --
# avoids pulling in the real module's Slim::Formats::RemoteStream/
# Slim::Utils::Network dependency chain, which this harness does not stub).
write_stub($stub_dir, 'Plugins::SpotOn::ProtocolHandler', <<'END');
package Plugins::SpotOn::ProtocolHandler;
sub getMetadataFor { return {} }
1;
END

# Stub: Plugins::SpotOn::API::TokenManager (needed by Status.pm
# _collectTokens/_statusDataHandler's authHealth loop). @fake_account_ids is
# controllable by tests that need _statusDataHandler to iterate a fixture
# account (Plan 66-02 Task 2 D-08 coverage); defaults to empty like before.
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our @fake_account_ids = ();
our %fake_needs_reauth = ();
our %fake_needs_migration = ();
sub getAccountIds { return @fake_account_ids }
sub needsReauth { my ($class, $accountId) = @_; return $fake_needs_reauth{$accountId} // 0; }
sub accountNeedsMigration { my ($class, $accountId) = @_; return $fake_needs_migration{$accountId} // 0; }
1;
END

# Stub: Plugins::SpotOn::API::Credentials (needed by Status.pm
# _collectAuthHealth's playback indicator, Plan 66-02 Task 2 D-08). Every
# accessor is a controllable fixture keyed by accountId, mirroring the real
# module's passive-read contract (no outbound calls).
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our %fake_verify_credentials = ();   # accountId => hashref | undef
our %fake_needs_playback_auth = ();  # accountId => 0|1
our %fake_playback_auth_reason = (); # accountId => reason string
sub verifyCredentials {
    my ($class, $accountId) = @_;
    return $fake_verify_credentials{$accountId};
}
sub needsPlaybackAuth {
    my ($class, $accountId) = @_;
    return $fake_needs_playback_auth{$accountId} // 0;
}
sub playbackAuthReason {
    my ($class, $accountId) = @_;
    return $fake_playback_auth_reason{$accountId} // '';
}
1;
END

# (85-09: no WebPlayer stub -- Status.pm reads no WebPlayer state, decision-D17 is cookie-free)

# Stub: Plugins::SpotOn::API::Login5 (85-09: SpClient->statusSnapshot and
# Status.pm's auth-health login block read Login5->loginState, a passive
# per-account state; controllable fixture keyed by accountId).
write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
our %fake_login_state = ();   # accountId => 'ok' | 'invalid_credentials' | ...
sub loginState { my ($class, $accountId) = @_; return $fake_login_state{$accountId // ''} }
1;
END

# ============================================================
# Define main:: constants and set up include paths
# ============================================================
# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($stub_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# the shape of the real librespot state(): no pairing signals, alive from the helper
sub state {
    my $self = shift;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($self->{mac});
    return { mode => undef, status => undef, paired => undef, wsConnected => undef,
             alive => $helper ? 1 : 0, observedTrack => undef, active => undef };
}
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
sub state { return {} }
1;
END

use constant TRANSCODING => 0;
use constant WEBUI       => 0;
use constant SCANNER     => 0;
use constant INFOLOG     => 0;
use constant ISWINDOWS   => 0;
use constant ISMAC       => 0;
use constant PERFMON     => 0;
use constant DEBUGLOG    => 0;    # (84-09: core half -- the roles are the mocks above)

# Set $::VERSION for system info
$::VERSION = '9.0.0-test';

# Set up include paths: stubs first, then project root
unshift @INC, $stub_dir, $project_dir;

# Pre-load plugin stub so Status.pm can call _pluginDataFor
require Plugins::SpotOn::Plugin;

# ============================================================
# Tests
# ============================================================

plan tests => 68;   # 74b WR-01: +3 hasError level cells; 84-09: 57 before the split; 21 Soloist cells moved to t/soloist/13_status_page_soloist.t

# Test 1: Status.pm compiles
require_ok('Plugins::SpotOn::Status');

# Test 2: recordError pushes entries
Plugins::SpotOn::Status->recordError('warn', 'API', 'test error 1');
Plugins::SpotOn::Status->recordError('error', 'Connect', 'test error 2');
Plugins::SpotOn::Status->recordError('info', 'Token', 'test error 3');

my $history = Plugins::SpotOn::Status::_errorHistory();
is(scalar @$history, 3, 'recordError pushes 3 entries');

# Test 3: Ring-buffer trims at MAX_ERROR_HISTORY
for my $i (1..35) {
    Plugins::SpotOn::Status->recordError('warn', 'Test', "entry $i");
}
my $trimmed = Plugins::SpotOn::Status::_errorHistory();
is(scalar @$trimmed, 30, 'Ring-buffer trims at MAX_ERROR_HISTORY (30)');

# Test 4: Oldest entries trimmed correctly
# We had 3 initial + 35 = 38 total, should keep last 30
# The newest entry should be "entry 35", oldest kept should be "entry 9"
# (38 - 30 = 8 trimmed, so entries 1-5 from initial + entries 1-3 from loop... wait)
# Actually: initial 3 + 35 loop = 38 pushed. Keep last 30. Trimmed first 8.
# Ring buffer reverse: $trimmed->[0] is newest = "entry 35"
# $trimmed->[29] is oldest kept
is($trimmed->[0]{message}, 'entry 35', 'Newest entry is last pushed');

# Test 5: recordError stores correct fields
my $entry = $trimmed->[0];
ok(exists $entry->{ts}      && defined $entry->{ts},      'Entry has ts field');
ok(exists $entry->{level}   && $entry->{level} eq 'warn', 'Entry has level field');
ok(exists $entry->{module}  && $entry->{module} eq 'Test', 'Entry has module field');
ok(exists $entry->{message} && defined $entry->{message}, 'Entry has message field');

# Test 6: _errorHistory returns reverse order (newest first)
# Clear and push fresh
# We cannot clear the ring buffer directly, but we can push known values
# and check the last few entries in reverse
Plugins::SpotOn::Status->recordError('info', 'Order', 'alpha');
Plugins::SpotOn::Status->recordError('info', 'Order', 'bravo');
Plugins::SpotOn::Status->recordError('info', 'Order', 'charlie');
my $ordered = Plugins::SpotOn::Status::_errorHistory();
is($ordered->[0]{message}, 'charlie', '_errorHistory returns newest first');
is($ordered->[1]{message}, 'bravo',   '_errorHistory second element is second newest');

# Test 7: _systemInfo returns cached hash
my $sys1 = Plugins::SpotOn::Status::_systemInfo();
my $sys2 = Plugins::SpotOn::Status::_systemInfo();
is($sys1, $sys2, '_systemInfo returns same reference (cached)');

# Test 8: SpClient->statusSnapshot returns expected keys (85-09 D-13: the
# Web-API Client module is gone from the status page; B3 re-point, 85-15 deletes it)
require Plugins::SpotOn::API::SpClient;
my $snapshot = eval { Plugins::SpotOn::API::SpClient->statusSnapshot() } || {};
my @expected_keys = sort qw(apiRequestCount inflightCount api429Count rateLimited spclientHost lastErrorClass lastErrorAt login5);
my @actual_keys   = sort keys %$snapshot;
is_deeply(\@actual_keys, \@expected_keys, 'statusSnapshot has all 8 expected keys');

# Test 9: SpClient->reset resets the counters
eval { Plugins::SpotOn::API::SpClient->reset() };
my $after_reset = eval { Plugins::SpotOn::API::SpClient->statusSnapshot() } || {};
is($after_reset->{apiRequestCount}, 0, 'apiRequestCount is 0 after reset');

# ============================================================
# Test 10-12: _statusDataHandler includes madeForYou, eval-guarded and
# sourced from SpClient->madeForYouStatus (85-09 D-19: Pathfinder health, the
# decision-D17 pathfinder-login5-plus-rootlist id, cookie-free), with no
# token / username / cookie field in the response and no hashConfigured.
# ============================================================
my %MFY_NINE = (
    source         => 'pathfinder-login5-plus-rootlist',
    hashState      => 'ok',
    fallbackActive => 0,
    mixCount       => 7,
    last412At      => undef,
    last401At      => undef,
    last403At      => undef,
    lastScrapeAt   => undef,
    opsMissing     => [],
);
{
    no warnings 'redefine';
    *Plugins::SpotOn::API::SpClient::madeForYouStatus = sub { return { %MFY_NINE } };
}
require Slim::Web::HTTP;
@Slim::Web::HTTP::http_responses = ();
my $fake_response = FakeStatusResponse->new;
Plugins::SpotOn::Status::_statusDataHandler('fake_http_client', $fake_response);

ok(scalar(@Slim::Web::HTTP::http_responses), 'Test 10: _statusDataHandler produced an HTTP response');

my $bytesRef = $Slim::Web::HTTP::http_responses[-1][2];
my $statusData = eval { JSON::PP::decode_json($$bytesRef) };
ok($statusData && ref $statusData->{madeForYou} eq 'HASH' && ($statusData->{madeForYou}{mixCount} // -1) == 7,
    'Test 11: status data includes a madeForYou key sourced from SpClient->madeForYouStatus');

my @madeForYouKeys = $statusData && ref $statusData->{madeForYou} eq 'HASH'
    ? sort keys %{$statusData->{madeForYou}} : ();
is_deeply(\@madeForYouKeys, [sort keys %MFY_NINE],
    'Test 12: madeForYou carries exactly the nine D-19 keys -- no hashConfigured, no WebPlayer state, no token/username/cookie field');

# ============================================================
# Tests 13-19: _collectAuthHealth playback indicator (D-08, GH #147 plan
# 66-02 Task 2) -- direct-call coverage of the 6th auth-health indicator.
# ============================================================
require Plugins::SpotOn::API::Credentials;

# Fixture account WITH valid playback credentials, paired via ZeroConf.
%Plugins::SpotOn::API::Credentials::fake_verify_credentials = (
    fixtureAcct1 => { auth_type => 1, username => 'leaked_secret_username', auth_data => 'leaked_secret_auth_data_xyz' },
);
%Plugins::SpotOn::API::Credentials::fake_needs_playback_auth  = (fixtureAcct1 => 0);
%Plugins::SpotOn::API::Credentials::fake_playback_auth_reason = (fixtureAcct1 => '');

my $healthWithCreds = Plugins::SpotOn::Status::_collectAuthHealth('fixtureAcct1');
ok(ref $healthWithCreds eq 'HASH' && ref $healthWithCreds->{playback} eq 'HASH',
    'Test 13: _collectAuthHealth returns a playback block');

my @playbackKeys = sort keys %{$healthWithCreds->{playback}};
is_deeply(\@playbackKeys, [sort qw(hasCredentials needsAuth reason source)],
    'Test 14: playback block carries exactly hasCredentials/needsAuth/reason/source');

is($healthWithCreds->{playback}{hasCredentials}, 1,
    'Test 15: account with valid credentials.json reports hasCredentials 1');

# Fixture account WITHOUT any credentials.json (verifyCredentials returns undef).
my $healthNoCreds = Plugins::SpotOn::Status::_collectAuthHealth('fixtureAcct2');
is($healthNoCreds->{playback}{hasCredentials}, 0,
    'Test 16: account without credentials.json reports hasCredentials 0');

# ============================================================
# Tests 17-23: full _statusDataHandler response, D-08/T-66-05 -- the
# playback block must reach the browser through the same passive/no-secrets
# discipline as the other authHealth indicators, and must never leak the
# fixture's username/auth_data.
# ============================================================
@Plugins::SpotOn::API::TokenManager::fake_account_ids = ('fixtureAcct1', 'fixtureAcct2');
%Plugins::SpotOn::API::Login5::fake_login_state = (fixtureAcct1 => 'ok', fixtureAcct2 => 'invalid_credentials');

@Slim::Web::HTTP::http_responses = ();
my $fake_response2 = FakeStatusResponse->new;
Plugins::SpotOn::Status::_statusDataHandler('fake_http_client', $fake_response2);

my $bytesRef2 = $Slim::Web::HTTP::http_responses[-1][2];
my $jsonText  = $$bytesRef2;
my $statusData2 = eval { JSON::PP::decode_json($jsonText) };

ok($statusData2 && ref $statusData2->{authHealth} eq 'HASH' && $statusData2->{authHealth}{fixtureAcct1},
    'Test 17: full status payload includes authHealth for the fixture account');

is($statusData2->{authHealth}{fixtureAcct1}{playback}{hasCredentials}, 1,
    'Test 18: full payload playback block for fixtureAcct1 reports hasCredentials 1');

is($statusData2->{authHealth}{fixtureAcct1}{playback}{source}, '',
    'Test 19: fixtureAcct1 has no playbackCredSource pref set -- source defaults to empty string');

is($statusData2->{authHealth}{fixtureAcct2}{playback}{hasCredentials}, 0,
    'Test 20: full payload playback block for fixtureAcct2 (no credentials) reports hasCredentials 0');

unlike($jsonText, qr/auth_data/,
    'Test 21: serialized status payload never contains the literal "auth_data" key');

unlike($jsonText, qr/leaked_secret_auth_data_xyz/,
    'Test 22: serialized status payload never leaks the fixture credential value');

unlike($jsonText, qr/leaked_secret_username/,
    'Test 23: serialized status payload never leaks the fixture username');

# 85-09 D-13: the `api` block is SpClient->statusSnapshot (8 keys, no Web-API
# limits), and its login5 hash mirrors Login5->loginState per account.
is_deeply([ sort keys %{ $statusData2->{api} || {} } ], [ sort qw(apiRequestCount inflightCount api429Count rateLimited spclientHost lastErrorClass lastErrorAt login5) ],
    'Test 23a: status data api block is SpClient->statusSnapshot (8 keys, no apiLimits)');
is_deeply($statusData2->{api}{login5}, { fixtureAcct1 => 'ok', fixtureAcct2 => 'invalid_credentials' },
    'Test 23b: api.login5 mirrors Login5->loginState for each account');

# ============================================================
# 85-09 Task 2 (D-13, D-19, D-17): auth health on login5, no PKCE / migration /
# sp_dc indicator; Made-for-You card (warning row) -- the page JS is EXECUTED
# under Node with a synthetic DOM (precedent: t/core/42), not grepped.
# ============================================================
{
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    $prefs->set(accounts => { fixtureAcct1 => {}, fixtureAcct2 => { needsPairing => 1 } });
    %Plugins::SpotOn::API::Login5::fake_login_state = (fixtureAcct1 => 'ok', fixtureAcct2 => 'invalid_credentials');

    my $h1 = Plugins::SpotOn::Status::_collectAuthHealth('fixtureAcct1');
    my $h2 = Plugins::SpotOn::Status::_collectAuthHealth('fixtureAcct2');
    is_deeply($h1->{login}, { state => 'ok', hasCredentials => 1, needsPairing => 0 },
        'Test 24: auth health login block = login5 state, hasCredentials, needsPairing 0');
    is_deeply($h2->{login}, { state => 'invalid_credentials', hasCredentials => 0, needsPairing => 1 },
        'Test 25: auth health login block for an account with needsPairing and no credentials');
    is_deeply([ sort keys %$h1 ], [ sort qw(login connect audioKey playback) ],
        'Test 26: auth health keys are login/connect/audioKey/playback -- no pkce, spDc or migration key');
    %Plugins::SpotOn::API::Login5::fake_login_state = ();
    is(Plugins::SpotOn::Status::_collectAuthHealth('fixtureAcct1')->{login}{state}, 'unknown',
        "Test 27: a login5 state not observed yet reads 'unknown'");
}

my $NODE = do { my $n = `which node 2>/dev/null`; chomp $n; $n };
ok($NODE, 'Test 28: node is available for the status page JS cells');

my $STATUS_HTML = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/status.html";
my $page_js = do { open(my $fh, '<', $STATUS_HTML) or die "status.html: $!"; local $/; <$fh> };

sub extract_js_function {
    my ($src, $name) = @_;
    $src =~ /\bfunction\s+\Q$name\E\s*\(/g or die "function $name not found in status.html";
    my $start = $-[0];
    my $open  = index($src, '{', pos($src));
    my ($depth, $i) = (0, $open);
    for (; $i < length $src; $i++) {
        my $c = substr($src, $i, 1);
        $depth++ if $c eq '{';
        if ($c eq '}') { $depth--; last if $depth == 0 }
    }
    return substr($src, $start, $i - $start + 1);
}

sub run_page_render {
    my ($fn, @payloads) = @_;
    my $fns = join "\n", map { extract_js_function($page_js, $_) } qw(val createMetricRow formatRelTime formatUptime), $fn;
    my $json = JSON::PP->new->canonical->encode(\@payloads);
    my $harness = <<"NODE";
function El(tag) { return { tag: tag, className: '', textContent: '', children: [], appendChild: function(c) { this.children.push(c); return c; } }; }
var bodies = {};
global.document = {
    createElement: function(t) { return El(t); },
    getElementById: function(id) { if (!bodies[id]) bodies[id] = El('div'); return bodies[id]; }
};
$fns
var payloads = $json;
var out = payloads.map(function(p) {
    bodies = {};
    $fn(p);
    var rows = [];
    Object.keys(bodies).forEach(function(id) {
        bodies[id].children.forEach(function(r) {
            if (r.children.length === 2) rows.push([r.children[0].textContent, r.children[1].textContent, r.children[1].className]);
            else rows.push([r.children.length ? r.children[0].textContent : '', '', '']);
        });
    });
    return rows;
});
console.log(JSON.stringify(out));
NODE
    my $script = "$stub_dir/render_harness.js";
    open(my $o, '>', $script) or die; print $o $harness; close $o;
    my $raw = `"$NODE" "$script" 2>&1`;
    my $res = eval { JSON::PP::decode_json($raw) };
    die "node harness failed: $raw" unless $res;
    return $res;
}

sub row_of { my ($rows, $label) = @_; my ($r) = grep { $_->[0] eq $label } @$rows; return $r || [ '', '', '' ] }
sub mfy { return { madeForYou => { %MFY_NINE, @_ } } }

SKIP: {
    skip 'node unavailable (Test 28 reported it)', 12 unless $NODE;
    my $r = eval { run_page_render('renderMadeForYou',
        mfy(),
        mfy(fallbackActive => 1),
        mfy(hashState => 'op_missing', opsMissing => ['homeSection']),
        mfy(hashState => 'broken', last412At => 1700000000),
    ) } || do { diag("renderMadeForYou: $@"); [ [], [], [], [] ] };
    my ($ok, $fb, $om, $br) = @$r;

    ok(row_of($ok, 'Source')->[1] ne '' && row_of($ok, 'Warning')->[0] eq '', 'Test 29: healthy Made-for-You state renders the card and shows NO warning row (MUST-NOT)');
    my $fbw = row_of($fb, 'Warning');
    ok($fbw->[1] =~ /saved mixes only/i, 'Test 30: fallbackActive 1 shows the warning row "saved mixes only"');
    my $omw = row_of($om, 'Warning');
    ok($omw->[1] =~ /homeSection/, 'Test 31: hashState op_missing shows the warning row naming the missing operation');
    my $brw = row_of($br, 'Warning');
    ok($brw->[2] =~ /dot-dead/, 'Test 32: hashState broken shows the warning row in the dead colour');
    is(row_of($ok, 'Source')->[1], 'pathfinder-login5-plus-rootlist', 'Test 33: the Made-for-You card shows the source id');
    is(row_of($ok, 'Mixes listed')->[1], '7', 'Test 34: the Made-for-You card shows mixCount');
    is(row_of($fb, 'Rootlist fallback')->[1], 'Active', 'Test 35: fallbackActive 1 reads "Active" in the fallback row');
    like(row_of($br, 'Last 412')->[1], qr/ago|[0-9]/, 'Test 36: the last 412 time is rendered');
    ok(row_of($ok, 'Last 401')->[0] ne '' && row_of($ok, 'Last 403')->[0] ne '' && row_of($ok, 'Last hash scrape')->[0] ne '', 'Test 37: 401, 403 and scrape rows exist');
    is(row_of($om, 'Missing operations')->[1], 'homeSection', 'Test 38: opsMissing is listed');

    my $a = eval { run_page_render('renderAuthHealth', {
        authHealth => {
            acctOk  => { login => { state => 'ok', hasCredentials => 1, needsPairing => 0 },
                         playback => { hasCredentials => 1, source => 'zeroconf' }, connect => {}, audioKey => {} },
            acctBad => { login => { state => 'invalid_credentials', hasCredentials => 0, needsPairing => 1 },
                         playback => {}, connect => {}, audioKey => {} },
        },
    }) } || do { diag("renderAuthHealth: $@"); [ [] ] };
    my $rows = $a->[0];
    my @login = grep { $_->[0] eq 'Konto-Login (login5)' } @$rows;
    is(scalar(@login), 2, 'Test 39: one "Konto-Login (login5)" row per account');
    ok(@$rows > 0 && !(grep { $_->[0] =~ /sp_dc|Web API Token|Last API Call|Migration/ } @$rows),
        'Test 40: no sp_dc, Web API Token, Last API Call or Migration row in the auth card');
}
ok(!($page_js =~ /spDc|sp_dc/), 'Test 41: status.html has no sp_dc rendering left');
ok(!($page_js =~ /hashConfigured/), 'Test 42: status.html has no hashConfigured left');

require_ok('Slim::Player::Playlist');
require_ok('Plugins::SpotOn::ProtocolHandler');




# ============================================================
# 84-09: core half of t/13_status_page.t. The T-7/WR-05 cells (a)-(c) and
# Fall A-E need the REAL Backend::Soloist state() over the Control/Soloist
# doubles and live in t/soloist/13_status_page_soloist.t together with the
# six load-order require_ok's. Cell (d) stays here: Status' gate for a role
# that reports no pairing, with the librespot role mocked below.
# ============================================================
require Plugins::SpotOn::Unified::Daemon;           # the fake librespot helper (stub above)
require Plugins::SpotOn::Unified::DaemonManager;    # load the stub BEFORE the first `local @HELPERS` (its `our @HELPERS = ()` would stomp it)

# (d) librespot-style helper with no websocket accessor whatsoever (Phase
# 84 backend role) -> paired/wsConnected stay undef, playing is untouched
# by the T-7 gate because isSoloist is false -- proves the isa()-guard
# runs before the WS-transport accessor lookup, not after.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::Daemon->new(
            mac => 'aa:bb:cc:dd:ee:f4', alive => 1, pid => 114, uptime => 5,
            connectEnabled => 1, streamPort => 9004, sessionHealth => undef,
        ),
    );

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired},      undef, '_collectDaemons: librespot helper keeps playing, paired undef (paired field)');
    is($d->{wsConnected}, undef, '_collectDaemons: librespot helper keeps playing, paired undef (wsConnected field)');
    is($d->{playing},     1,     '_collectDaemons: librespot helper keeps playing, paired undef');
}







# ============================================================
# 84-19 F-04-02-CLAIM: a 'warn' ring entry (a one-shot "this happened"
# notice such as claim-conflict:<mac>) expires by itself after
# WARN_TTL_S (3600 s); an 'error' entry (a standing condition such as
# 'unpaired') does not. The clock is Status.pm's own _now() seam so the
# test needs no sleeping. The dedupe contract of Control._recordErrorOnce
# asks hasError(), so an expired warn must read as gone there too -- and
# a recurrence after expiry must be recordable again.
# ============================================================
{
    no warnings 'redefine';
    my $t = 1_000_000;
    local *Plugins::SpotOn::Status::_now = sub { $t };

    Plugins::SpotOn::Status->recordError('warn',  'Soloist', 'claim lost',   'aa:bb:cc:dd:ee:01:claim-conflict:x');
    Plugins::SpotOn::Status->recordError('error', 'Soloist', 'not paired',   'aa:bb:cc:dd:ee:01:unpaired');
    my $keyOf = sub { my ($k) = @_; scalar grep { ($_->{key} // '') eq $k } @{ Plugins::SpotOn::Status::_errorHistory() } };

    $t = 1_000_000 + 3599;
    is($keyOf->('aa:bb:cc:dd:ee:01:claim-conflict:x'), 1, "84-19 F-04-02-CLAIM: warn entry still listed one second before WARN_TTL_S");
    ok(Plugins::SpotOn::Status->hasError('Soloist', 'aa:bb:cc:dd:ee:01:claim-conflict:x'), "84-19 F-04-02-CLAIM: hasError still true before expiry");

    $t = 1_000_000 + 3600;
    is($keyOf->('aa:bb:cc:dd:ee:01:claim-conflict:x'), 0, "84-19 F-04-02-CLAIM: warn entry gone from errors[] once WARN_TTL_S has passed");
    ok(!Plugins::SpotOn::Status->hasError('Soloist', 'aa:bb:cc:dd:ee:01:claim-conflict:x'), "84-19 F-04-02-CLAIM: hasError false after expiry (Control's dedupe re-records)");
    is($keyOf->('aa:bb:cc:dd:ee:01:unpaired'), 1, "84-19 F-04-02-CLAIM: error-level entry does NOT expire (MUST-STAY)");

    Plugins::SpotOn::Status->recordError('warn', 'Soloist', 'claim lost again', 'aa:bb:cc:dd:ee:01:claim-conflict:x');
    is($keyOf->('aa:bb:cc:dd:ee:01:claim-conflict:x'), 1, "84-19 F-04-02-CLAIM: a recurrence after expiry is listed again (record-once not broken)");

    # 74b WR-01: the optional level argument of hasError separates a soft
    # warn from the standing error under the same key.
    ok(Plugins::SpotOn::Status->hasError('Soloist', 'aa:bb:cc:dd:ee:01:claim-conflict:x', 'warn'), "74b WR-01: hasError with level warn matches the warn entry");
    ok(!Plugins::SpotOn::Status->hasError('Soloist', 'aa:bb:cc:dd:ee:01:claim-conflict:x', 'error'), "74b WR-01: hasError with level error does not match a warn entry");
    ok(Plugins::SpotOn::Status->hasError('Soloist', 'aa:bb:cc:dd:ee:01:unpaired', 'error'), "74b WR-01: hasError with level error matches the error entry");
}

# ============================================================
# 74b-03 (D-09, T-74b-11): _statusDataHandler calls assertStandingConditions
# BEFORE errors[] is built, so an evicted or never-recorded standing entry is
# in the very response that asked. An 'error' entry survives WARN_TTL_S + 1
# on the status page; a 'warn' entry recorded at the same time does not.
# ============================================================
{
    no warnings 'redefine';
    my $t = 2_000_000;
    local *Plugins::SpotOn::Status::_now = sub { $t };
    Plugins::SpotOn::Status->clearError('Soloist', 'glibc');
    Plugins::SpotOn::Status->clearError('Soloist', '74b-03-warn-probe');
    ok(!Plugins::SpotOn::Status->hasError('Soloist', 'glibc'), "74b-03 D-09: precondition - no glibc entry in the ring before the request");
    Plugins::SpotOn::Status->recordError('warn', 'Soloist', 'one-shot notice', '74b-03-warn-probe');

    my $before = $Plugins::SpotOn::Unified::DaemonManager::ASSERT_CALLS;
    @Slim::Web::HTTP::http_responses = ();
    Plugins::SpotOn::Status::_statusDataHandler('fake_http_client', FakeStatusResponse->new);
    is($Plugins::SpotOn::Unified::DaemonManager::ASSERT_CALLS, $before + 1, "74b-03 D-09: the status data handler calls assertStandingConditions once per request");
    my $d1 = eval { JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[-1][2] }) } || {};
    my @k1 = map { $_->{key} // '' } @{ $d1->{errors} || [] };
    ok((grep { $_ eq 'glibc' } @k1), "74b-03 D-09: the entry asserted by the handler is already in the same response (assert runs before errors[] is built)");
    ok((grep { $_ eq '74b-03-warn-probe' } @k1), "74b-03 D-09: the warn entry is listed right after it was recorded");

    $t += Plugins::SpotOn::Status::WARN_TTL_S() + 1;
    @Slim::Web::HTTP::http_responses = ();
    Plugins::SpotOn::Status::_statusDataHandler('fake_http_client', FakeStatusResponse->new);
    my $d2 = eval { JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[-1][2] }) } || {};
    my @k2 = map { $_->{key} // '' } @{ $d2->{errors} || [] };
    ok((grep { $_ eq 'glibc' } @k2), "74b-03 D-09: the error entry is still listed WARN_TTL_S + 1 later (never expires)");
    ok(!(grep { $_ eq '74b-03-warn-probe' } @k2), "74b-03 D-09: the warn entry recorded at the same time is gone");
}
