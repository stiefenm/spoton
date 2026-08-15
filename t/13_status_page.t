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
my $project_dir = dirname($test_dir);

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

# Stub: Slim::Player::Client
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { undef }
sub AUTOLOAD { }
sub can { 1 }
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

# Stub: Plugins::SpotOn::Unified::DaemonManager (needed by Status.pm _collectDaemons)
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
sub helperInstances { () }
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

# Stub: Plugins::SpotOn::API::WebPlayer (needed by Status.pm madeForYou
# collector -- Plan 52-03, D-04 channel 3). Returns a fixed no-credentials
# snapshot shape matching the real WebPlayer->statusSnapshot contract.
write_stub($stub_dir, 'Plugins::SpotOn::API::WebPlayer', <<'END');
package Plugins::SpotOn::API::WebPlayer;
sub statusSnapshot {
    return { state => 'valid', spDcPresent => 1, spDcMasked => 'AQDx****' };
}
# Needed by Status.pm _collectAuthHealth's spDc indicator (Plan 66-02 Task 2:
# now exercised directly, previously latent -- see TokenManager stub note).
sub state         { return 'empty' }
sub spDcMaskedPreview { return '' }
1;
END

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

# Set $::VERSION for system info
$::VERSION = '9.0.0-test';

# Set up include paths: stubs first, then project root
unshift @INC, $stub_dir, $project_dir;

# Pre-load plugin stub so Status.pm can call _pluginDataFor
require Plugins::SpotOn::Plugin;

# ============================================================
# Tests
# ============================================================

plan tests => 27;

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

# Test 8: Client->statusSnapshot returns expected keys
require Plugins::SpotOn::API::Client;
my $snapshot = Plugins::SpotOn::API::Client->statusSnapshot();
my @expected_keys = sort qw(inflightCount apiRequestCount api429Count rateLimited wpRateLimited apiLimits blockedEndpoints limitsProbed limitsLastProbed);
my @actual_keys   = sort keys %$snapshot;
is_deeply(\@actual_keys, \@expected_keys, 'statusSnapshot has all 9 expected keys');

# Test 9: Client->reset resets new counters
Plugins::SpotOn::API::Client->reset();
my $after_reset = Plugins::SpotOn::API::Client->statusSnapshot();
is($after_reset->{apiRequestCount}, 0, 'apiRequestCount is 0 after reset');

# ============================================================
# Test 10-12: _statusDataHandler includes madeForYou (D-04 channel 3),
# eval-guarded and sourced from a stubbed WebPlayer->statusSnapshot, with
# no raw credential/token/secret fields leaking into the response (Plan 52-03).
# ============================================================
require Plugins::SpotOn::API::WebPlayer;
require Slim::Web::HTTP;
@Slim::Web::HTTP::http_responses = ();
my $fake_response = FakeStatusResponse->new;
Plugins::SpotOn::Status::_statusDataHandler('fake_http_client', $fake_response);

ok(scalar(@Slim::Web::HTTP::http_responses), 'Test 10: _statusDataHandler produced an HTTP response');

my $bytesRef = $Slim::Web::HTTP::http_responses[-1][2];
my $statusData = eval { JSON::PP::decode_json($$bytesRef) };
ok($statusData && exists $statusData->{madeForYou},
    'Test 11: status data includes a madeForYou key sourced from WebPlayer->statusSnapshot');

my @madeForYouKeys = $statusData && ref $statusData->{madeForYou} eq 'HASH'
    ? sort keys %{$statusData->{madeForYou}} : ();
is_deeply(\@madeForYouKeys, [sort qw(state spDcPresent spDcMasked hashConfigured)],
    'Test 12: madeForYou carries only state/spDcPresent/spDcMasked/hashConfigured -- no access_token/client_token/raw sp_dc fields');

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
