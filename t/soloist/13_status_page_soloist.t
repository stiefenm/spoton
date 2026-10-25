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

# ============================================================
# Define main:: constants and set up include paths
# ============================================================
use constant TRANSCODING => 0;
use constant WEBUI       => 0;
use constant SCANNER     => 0;
use constant INFOLOG     => 0;
use constant ISWINDOWS   => 0;
use constant ISMAC       => 0;
use constant PERFMON     => 0;
use constant DEBUGLOG    => 0;    # 84-08: the real Backend::Soloist role is compiled here

# Set $::VERSION for system info
$::VERSION = '9.0.0-test';

# Set up include paths: stubs first, then project root
unshift @INC, $stub_dir, $project_dir;

# Pre-load plugin stub so Status.pm can call _pluginDataFor
require Plugins::SpotOn::Plugin;

# ============================================================
# Tests
# ============================================================

plan tests => 22;   # 84-09: soloist half of t/13_status_page.t (T-7/WR-05 over the REAL Backend::Soloist state()); the rest is t/core/13_status_page_core.t

# Test 1: Status.pm compiles
require_ok('Plugins::SpotOn::Status');
# ============================================================
# Tests 24-38: _collectDaemons paired/wsConnected/playing gate (Phase 82,
# T-7 -- ROADMAP Task 7, todos/pending/ispaired-heuristik-falschpositiv.md).
# Fake helpers are `local`-ized into DaemonManager::@HELPERS / Soloist::
# %PAIRED per case, so earlier/later tests keep seeing the module defaults
# (empty helper list, no paired macs) once each block exits.
#
# Force-load the three fake-helper stubs (and, via the SoloistDaemon stub
# file, Test::FakeSoloistWS) BEFORE the first `local %...::PAIRED = (...)`
# below -- the Soloist.pm stub's `our %PAIRED = ();` line runs at require
# time, and if that require happens lazily inside _collectDaemons' own
# `require Plugins::SpotOn::Soloist` (called for the first time from
# *inside* a `local`-ized block), it would stomp the localized value right
# back to empty. Same class of ordering bug as 82-01-SUMMARY's
# SimpleAsyncHTTP/AUTO_FIRE finding.
# ============================================================
require_ok('Plugins::SpotOn::Soloist');
require_ok('Plugins::SpotOn::Soloist::Control');
require_ok('Plugins::SpotOn::Unified::SoloistDaemon');
require_ok('Plugins::SpotOn::Unified::Daemon');
require_ok('Slim::Player::Playlist');
require_ok('Plugins::SpotOn::ProtocolHandler');
require Plugins::SpotOn::Unified::DaemonManager;   # 84-09: load the stub BEFORE the first `local @HELPERS` -- in the unsplit file the core cells above loaded it

# (a) paired + WS connected -> playing 1, both fields true.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f1', alive => 1, pid => 111, uptime => 5,
            connectEnabled => 1, streamPort => 9001, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ('aa:bb:cc:dd:ee:f1' => 1);

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired},      1, '_collectDaemons: paired+ws -> playing 1 (paired field)');
    is($d->{wsConnected}, 1, '_collectDaemons: paired+ws -> playing 1 (wsConnected field)');
    is($d->{playing},     1, '_collectDaemons: paired+ws -> playing 1');
}

# (b) paired + WS disconnected -> playing 0.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f2', alive => 1, pid => 112, uptime => 5,
            connectEnabled => 1, streamPort => 9002, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(0),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ('aa:bb:cc:dd:ee:f2' => 1);

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired},      1, '_collectDaemons: ws down -> playing 0 (still reports paired)');
    is($d->{wsConnected}, 0, '_collectDaemons: ws down -> playing 0 (wsConnected field)');
    is($d->{playing},     0, '_collectDaemons: ws down -> playing 0');
}

# (c) unpaired + WS connected -> playing 0.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f3', alive => 1, pid => 113, uptime => 5,
            connectEnabled => 1, streamPort => 9003, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ();

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired},      0, '_collectDaemons: unpaired -> playing 0 (paired field)');
    is($d->{wsConnected}, 1, '_collectDaemons: unpaired -> playing 0 (WS transport itself is still up)');
    is($d->{playing},     0, '_collectDaemons: unpaired -> playing 0');
}


# ============================================================
# 82-11 Task 3, WR-05: one pairing truth -- _collectDaemons asks
# Control->for_client($mac) first (eval-guarded like the existing
# isPairedForClient call above it) and only falls back to the filesystem
# when no Control is registered. None of the (a)-(d) cases above register
# a Control, so they already prove the fallback path (WR-05 Fall D) --
# this block only adds the cases where a Control IS registered.
# ============================================================

# (WR-05 Fall A) Control says paired, filesystem says not -- Control wins.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f5', alive => 1, pid => 115, uptime => 40,
            connectEnabled => 1, streamPort => 9005, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ();    # filesystem: NOT paired
    local %Plugins::SpotOn::Soloist::Control::CONTROLS = (
        'aa:bb:cc:dd:ee:f5' => Plugins::SpotOn::Soloist::Control->new(
            observed => { paired => 1, wsConnected => 1 },
        ),
    );

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired}, 1, "WR-05: Fall A -- Control says paired, filesystem says not -- Control wins");
}

# (WR-05 Fall B) Control says NOT paired, filesystem says paired -- the
# live-observed divergence ("paired:1/wsConnected:1 in the filesystem
# signal, daemon not paired in the ring" per 82-VERIFICATION.md). playing
# is gated by the SAME truth that blocks requests.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f6', alive => 1, pid => 116, uptime => 40,
            connectEnabled => 1, streamPort => 9006, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ('aa:bb:cc:dd:ee:f6' => 1);    # filesystem: paired
    local %Plugins::SpotOn::Soloist::Control::CONTROLS = (
        'aa:bb:cc:dd:ee:f6' => Plugins::SpotOn::Soloist::Control->new(
            observed => { paired => 0, wsConnected => 1 },
        ),
    );

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired},  0, "WR-05: Fall B -- Control says NOT paired, filesystem says paired -- Control wins");
    is($d->{playing}, 0, "WR-05: Fall B -- playing gated by the same Control truth that blocks requests");
}

# (WR-05 Fall C) Control registered but observed.paired undefined (no
# auth_state yet) -- an undefined observation is not a statement; the
# filesystem value passes through.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f7', alive => 1, pid => 117, uptime => 8,
            connectEnabled => 1, streamPort => 9007, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ('aa:bb:cc:dd:ee:f7' => 1);    # filesystem: paired
    local %Plugins::SpotOn::Soloist::Control::CONTROLS = (
        'aa:bb:cc:dd:ee:f7' => Plugins::SpotOn::Soloist::Control->new(
            observed => { wsConnected => 1 },    # paired: not yet observed
        ),
    );

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired}, 1, "WR-05: Fall C -- Control's paired is undefined -- filesystem value passes through");
}

# (WR-05 Fall D) No Control registered for this mac -- filesystem and
# _ws->connected are read exactly as before. Cases (a)-(d) above already
# prove this (none of them register a Control); this is a lightweight,
# explicitly-labeled confirmation alongside them.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f9', alive => 1, pid => 119, uptime => 40,
            connectEnabled => 1, streamPort => 9009, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ('aa:bb:cc:dd:ee:f9' => 1);
    # No Control registered for this mac -- %CONTROLS stays at its default.

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{paired}, 1, "WR-05: Fall D -- no Control registered -- filesystem value used, same as cases (a)-(d)");
}

# (WR-05 Fall E) Control's wsConnected wins over a connected socket stub --
# the field that gates the display is the same one that blocks requests.
{
    local @Plugins::SpotOn::Unified::DaemonManager::HELPERS = (
        Plugins::SpotOn::Unified::SoloistDaemon->new(
            mac => 'aa:bb:cc:dd:ee:f8', alive => 1, pid => 118, uptime => 40,
            connectEnabled => 1, streamPort => 9008, sessionHealth => undef,
            ws => Test::FakeSoloistWS->new(1),    # socket stub itself reports connected
        ),
    );
    local %Plugins::SpotOn::Soloist::PAIRED = ('aa:bb:cc:dd:ee:f8' => 1);
    local %Plugins::SpotOn::Soloist::Control::CONTROLS = (
        'aa:bb:cc:dd:ee:f8' => Plugins::SpotOn::Soloist::Control->new(
            observed => { paired => 1, wsConnected => 0 },    # Control says the transport is down
        ),
    );

    my $daemons = Plugins::SpotOn::Status::_collectDaemons();
    my $d = $daemons->[0];
    is($d->{wsConnected}, 0, "WR-05: Fall E -- Control's wsConnected wins over a connected socket stub");
}

