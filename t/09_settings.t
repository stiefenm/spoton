#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# ============================================================
# FakeSettingsResponse — minimal Slim::Web response double for exercising
# _pkceStoreAccount directly (Plan 51-03 Task 2): supports the header/code/
# content_type accessor calls made by _jsonResponse and _renderPkceResultPage.
# Plan 65-04: optional request => FakeSettingsRequest for handlers that read
# $response->request (e.g. _pkceStartHandler's Host/X-Forwarded-Proto).
# ============================================================
package FakeSettingsResponse;
sub new { my ($class, %args) = @_; return bless { headers => {}, %args }, $class }
sub header {
    my $self = shift;
    if (@_ == 2) { $self->{headers}{ $_[0] } = $_[1]; return $_[1]; }
    return $self->{headers}{ $_[0] };
}
sub code         { my $self = shift; $self->{code}         = $_[0] if @_; return $self->{code}; }
sub content_type { my $self = shift; $self->{content_type} = $_[0] if @_; return $self->{content_type}; }
sub request      { return $_[0]->{request} }

# ============================================================
# FakeSettingsRequest — minimal request double (Plan 65-04): header lookup
# for _pkceStartHandler's callback-URL assembly.
# ============================================================
package FakeSettingsRequest;
sub new { my ($class, %args) = @_; return bless { headers => {}, %args }, $class }
sub header  { my ($self, $name) = @_; return $self->{headers}{$name} }
sub content { return $_[0]->{content} }

package main;

# Create a temporary directory for LMS stubs
my $stub_dir = tempdir(CLEANUP => 1);
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
# logger() must also be installed into the caller's namespace: Settings.pm
# calls it as a method (Slim::Utils::Log->logger(...)), but Client.pm (pulled
# in transitively via the PKCE handlers) calls it as a bare imported function
# (use Slim::Utils::Log; ... logger('plugin.spoton')) — matches t/08's stub.
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
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info  { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn  { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
use parent 'Exporter';
our \@EXPORT_OK = qw(preferences);
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir', httpport => 9005 } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    return bless { _ns => \$self->{_ns} . '_client_' . (\$client // 'default') }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

# Stub: Slim::Utils::Timers
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_] }
sub killTimers { push @kill_calls, [@_] }
sub reset_calls { @set_calls = (); @kill_calls = () }
1;
END

# Stub: Slim::Utils::Strings
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub string  { join(' ', grep { defined } @_[1..$#_]) }
sub cstring { join(' ', grep { defined } @_[1..$#_]) }
1;
END

# Stub: Slim::Utils::Unicode
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

# Stub: Slim::Utils::OSDetect (Phase 71 -- Settings.pm handler() now requires
# the real Plugins::SpotOn::Soloist module, whose _arch() calls
# Slim::Utils::OSDetect::details() fully-qualified without an explicit
# require, relying on it already being loaded elsewhere -- true in the real
# LMS runtime, not in this stub harness).
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64' } }
1;
END

# Stub: JSON::XS (real module unavailable in this sandbox; Plugin.pm's
# `use JSON::XS qw(encode_json)` is only reached when Settings.pm's
# backend=='soloist' soloistPlayers block requires Plugin.pm — exercised by
# the SOLO-BYOK backend-whitelist tests below).
write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
use JSON::PP ();
sub encode_json { JSON::PP::encode_json($_[0]) }
sub decode_json { JSON::PP::decode_json($_[0]) }
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

# Stub: Time::HiRes
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Note: File::Spec::Functions is a core module — no stub needed.
# The real File::Spec::Functions provides catdir/catfile as exported functions.

# Stub: Slim::Plugin::OPMLBased
write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new        { bless {}, shift }
sub initPlugin { }
sub _pluginDataFor { }
sub AUTOLOAD   { }
sub can        { 1 }
1;
END

# Stub: Slim::Player::ProtocolHandlers
write_stub($stub_dir, 'Slim::Player::ProtocolHandlers', <<'END');
package Slim::Player::ProtocolHandlers;
sub registerHandler { }
1;
END

# Stub: Slim::Player::Client
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our @_mock_clients = ();
sub clients { return @_mock_clients }
sub set_mock_clients { @_mock_clients = @_ }
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

# Stub: Slim::Web::Pages (for addRawFunction)
write_stub($stub_dir, 'Slim::Web::Pages', <<'END');
package Slim::Web::Pages;
our @registered_raw = ();
sub addRawFunction { push @registered_raw, [$_[1], $_[2]] }
sub reset_calls    { @registered_raw = () }
1;
END

# Stub: Slim::Web::HTTP (for addHTTPResponse in the diagnostic bundle / PKCE result handlers)
write_stub($stub_dir, 'Slim::Web::HTTP', <<'END');
package Slim::Web::HTTP;
our @http_responses = ();
sub addHTTPResponse { push @http_responses, [@_] }
sub reset_calls     { @http_responses = () }
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

# Stub: Slim::Networking::SimpleAsyncHTTP
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get  { }
sub post { }
1;
END

# Stub: Plugins::SpotOn::Helper (needed by Settings.pm)
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
sub get { return '/usr/bin/false' }
sub init { }
1;
END

# Stub: Plugins::SpotOn::API::TokenManager (PKCE-native re-auth query API — Plan 50-01/50-03)
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our %needs_reauth;
our @clear_reauth_calls = ();
our @store_account_prefs_calls = ();
our $needs_migration = 0;    # Plan 03 Task 3: Settings.pm migration banner (D-04 Channel 2)
our %account_needs_migration;    # Plan 54-02: per-account override for _collectAuthHealth tests
our %reauth_reason;    # Plan 55-02 (D-06): per-account reauthReason override
sub anyAccountNeedsReauth { return (grep { $_ } values %needs_reauth) ? 1 : 0 }
sub anyAccountNeedsMigration { return $needs_migration ? 1 : 0 }
sub accountNeedsMigration { my ($class, $id) = @_; return $account_needs_migration{$id} ? 1 : 0 }
sub needsReauth        { my ($class, $id) = @_; return $needs_reauth{$id} ? 1 : 0 }
sub reauthReason        { my ($class, $id) = @_; return $reauth_reason{$id} }
sub clearNeedsReauth    { my ($class, $id) = @_; push @clear_reauth_calls, $id; delete $needs_reauth{$id} }
sub removeAccount     { }
sub getAccountIds     { return () }
# _storeAccountPrefs — minimal re-implementation of the real TokenManager
# behavior (Plan 51-03 Task 2): stores the account, sets activeAccount only
# if none is set yet (mirrors the $needsDaemonStart first-account-only
# conditional that Pitfall 6 documents), then invokes the no-arg callback.
sub _storeAccountPrefs {
    my ($class, $accountId, $spotifyUserId, $displayName, $cb) = @_;
    push @store_account_prefs_calls, $accountId;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} = { displayName => $displayName, spotifyUserId => $spotifyUserId };
    $prefs->set('accounts', $accounts);
    $prefs->set('activeAccount', $accountId) unless $prefs->get('activeAccount');
    $cb->();
}
sub reset_calls {
    %needs_reauth = ();
    @clear_reauth_calls = ();
    @store_account_prefs_calls = ();
    %account_needs_migration = ();
    %reauth_reason = ();
}
1;
END

# Stub: Plugins::SpotOn::API::Credentials — since Plan 65-01 (GH #147 D-04)
# the derivation path has NO production callers; the counter below is a
# regression guard asserting _pkceStoreAccount never calls it again.
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our $next_derive_ok = 1;
our $derive_call_count = 0;
our $last_derive_account;
sub deriveCredentials {
    my ($class, $accountId, $cb) = @_;
    $derive_call_count++;
    $last_derive_account = $accountId;
    $cb->($next_derive_ok, $next_derive_ok ? undef : 'derivation_failed');
}
# GH #147 plan 65-04: recording stub for the user-initiated Keymaster-token
# derivation path (_pkceStoreAccount auto-derive tail + playerauth browser
# fallback). Records (accountId, accessToken) per call; result configurable.
our @derive_from_token_calls  = ();
our $next_derive_from_token   = [1, undef];
sub deriveCredentialsFromToken {
    my ($class, $accountId, $accessToken, $cb) = @_;
    push @derive_from_token_calls, [$accountId, $accessToken];
    $cb->(@{ $next_derive_from_token });
}
# WR-02: clearRateLimit stub (called by _pkceStoreAccount before deriveCredentials)
sub clearRateLimit { }
# GH #147 plan 65-02: handler() playbackAuthState/pairingDeviceName params +
# playerauth endpoints consume the pairing API.
our $next_needs_playback_auth = 0;
our $next_pairing_status      = { state => 'idle', accountId => undef };
our @start_pairing_calls      = ();
our $next_start_pairing       = [1, undef];
our $cancel_pairing_calls     = 0;
sub needsPlaybackAuth  { return $next_needs_playback_auth }
sub credentialsPathFor {
    my ($class, $accountId) = @_;
    require Slim::Utils::Prefs;
    require File::Spec;
    return File::Spec->catfile(
        Slim::Utils::Prefs::preferences('server')->get('cachedir'),
        'spoton', $accountId, 'credentials.json');
}
sub pairingDeviceName { return 'SpotOn Authorization (Test)' }
sub startPairing {
    my ($class, $accountId) = @_;
    push @start_pairing_calls, $accountId;
    return @{ $next_start_pairing };
}
sub pairingStatus { return $next_pairing_status }
sub cancelPairing { $cancel_pairing_calls++ }
sub reset_calls {
    $next_derive_ok = 1;
    $derive_call_count = 0;
    $last_derive_account = undef;
    @derive_from_token_calls  = ();
    $next_derive_from_token   = [1, undef];
    $next_needs_playback_auth = 0;
    $next_pairing_status      = { state => 'idle', accountId => undef };
    @start_pairing_calls      = ();
    $next_start_pairing       = [1, undef];
    $cancel_pairing_calls     = 0;
}
1;
END

# Stub: Plugins::SpotOn::Unified::DaemonManager (scheduleInit called on pref
# save; helperInstances + FakeHelper added for Plan 54-02's Auth Health
# Dashboard aggregation test -- a controllable fixture list of fake daemon
# helper objects exposing the same _accountId/alive/pid/uptime accessors as
# the real Unified::Daemon.pm).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $schedule_init_calls = 0;
our @fake_helpers = ();
sub scheduleInit    { $schedule_init_calls++ }
sub helperInstances { return @fake_helpers }
sub reset_calls     { $schedule_init_calls = 0; @fake_helpers = () }

package Plugins::SpotOn::Unified::DaemonManager::FakeHelper;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub _accountId { return $_[0]->{_accountId} }
sub alive      { return $_[0]->{alive} }
sub pid        { return $_[0]->{pid} }
sub uptime     { return $_[0]->{uptime} }
1;
END

# Stub: Plugins::SpotOn::API::WebPlayer (D-06/D-08/D-09 sp_dc storage + state
# consumed by Settings.pm — Plan 52-03). storeSpDc records calls instead of
# writing prefs so tests can assert on the call args without depending on
# WebPlayer's real internal storage layout (Plan 52-01, out of this plan's scope).
write_stub($stub_dir, 'Plugins::SpotOn::API::WebPlayer', <<'END');
package Plugins::SpotOn::API::WebPlayer;
our @store_spdc_calls      = ();
our $next_masked_preview   = '';
our $next_state             = 'empty';
our $next_has_spdc          = 0;
sub storeSpDc {
    my ($class, $accountId, $spdc) = @_;
    push @store_spdc_calls, [$accountId, $spdc];
    return 1;
}
sub spDcMaskedPreview { return $next_masked_preview }
sub state             { return $next_state }
sub hasSpDc           { return $next_has_spdc }
sub reset_calls {
    @store_spdc_calls    = ();
    $next_masked_preview = '';
    $next_state           = 'empty';
    $next_has_spdc        = 0;
}
1;
END


# Stub: URI — not Perl core, bundled by LMS. Settings.pm uses URI->new()->query_form
# for PKCE callback query-string parsing.
write_stub($stub_dir, 'URI', <<'END');
package URI;
sub new {
    my ($class, $str) = @_;
    return bless { _str => $str // '' }, $class;
}
sub query_form {
    my ($self) = @_;
    my $q = $self->{_str};
    $q =~ s/^[^?]*\?//;  # strip everything before ?
    return map { my ($k,$v) = split /=/, $_, 2; ($k // '', $v // '') } split /&/, ($q // '');
}
1;
END

# Stub: URI::Escape — not Perl core, bundled by LMS
# uri_escape_utf8 is needed too: Settings.pm's PKCE handlers pull in the real
# Plugins::SpotOn::API::Client (for SPOTON_DEFAULT_CLIENT_ID), which imports
# both symbols from URI::Escape.
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape uri_escape_utf8);
sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge; return $s; }
sub uri_escape_utf8 {
    my ($s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
1;
END

# ============================================================
# main:: constants
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# submodules resolve it via a fully-qualified call at load time. Production
# always compiles Plugin.pm first — provide the constant for standalone loads
# (Settings.pm's PKCE handlers pull in the real Client.pm/PKCE.pm, matching
# the pattern already used by t/08_api_client.t).
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Phase 71: pre-load the OSDetect stub -- Soloist.pm calls
# Slim::Utils::OSDetect::details() fully-qualified without its own require,
# relying on it already being loaded (true in the real LMS runtime where
# many other modules require it first; not automatic in this stub harness).
require Slim::Utils::OSDetect;

# ============================================================
# AUTH-04: Filesystem permission tests (immediate — no module required)
# These test the chmod 0700/0600 behavior at the filesystem level.
# ============================================================
{
    my $acct_tmpdir = tempdir(CLEANUP => 1);

    # Create a fake credentials.json
    my $cred_file = "$acct_tmpdir/credentials.json";
    open(my $fh, '>', $cred_file) or die "Cannot create credentials.json: $!";
    print $fh '{"username":"testuser"}';
    close($fh);

    chmod 0700, $acct_tmpdir;
    chmod 0600, $cred_file;

    my @stat_dir  = stat($acct_tmpdir);
    my @stat_cred = stat($cred_file);

    is($stat_dir[2]  & 07777, 0700, 'AUTH-04: chmod 0700 on account cache directory works');
    is($stat_cred[2] & 07777, 0600, 'AUTH-04: chmod 0600 on credentials.json works');
}

# ============================================================
# AUTH-05: Two separate account subdirectories (immediate filesystem test)
# Simulates what TokenManager->addAccount creates
# ============================================================
{
    my $base_dir   = tempdir(CLEANUP => 1);
    my $account_id_1 = 'abcd1234';
    my $account_id_2 = 'ef567890';

    my $dir_1 = "$base_dir/$account_id_1";
    my $dir_2 = "$base_dir/$account_id_2";

    make_path($dir_1);
    make_path($dir_2);

    ok(-d $dir_1, "AUTH-05: Account 1 subdirectory ($account_id_1) exists");
    ok(-d $dir_2, "AUTH-05: Account 2 subdirectory ($account_id_2) exists");
    isnt($dir_1, $dir_2, 'AUTH-05: Account subdirectories are distinct paths');
}

# ============================================================
# Settings.pm structure tests
# ============================================================
my $settings_module = "$project_dir/Plugins/SpotOn/Settings.pm";

SKIP: {
    skip "Settings.pm not found", 1 unless -f $settings_module;

    open(my $fh, '<', $settings_module) or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);

    # PLAN 03 acceptance criteria: no OAuth artifacts (clientId is legitimate — custom Client-ID pref from Phase 04.4)
    ok($src !~ /startOAuth/,         'Settings.pm: no startOAuth reference');
    # Phase 53 Plan 03 (D-13): redirectUri is now a legitimate $paramRef entry,
    # sourced from the single PKCE::GITHUB_PAGES_REDIRECT_URI constant for the
    # Client-ID setup wizard -- distinct from the old hand-rolled OAuth
    # redirect_uri assembly this guard originally banned. buildRedirectUri
    # (the old hand-rolled assembly function) remains banned.
    ok($src !~ /buildRedirectUri/,   'Settings.pm: no buildRedirectUri reference');

    # Plan 50-03 acceptance criteria: ZeroConf discovery-as-auth code removed (D-01, M-3)
    ok($src !~ /sub _discoveryStatusHandler/, 'Settings.pm: _discoveryStatusHandler removed');
    ok($src !~ /sub _discoveryStartHandler/,  'Settings.pm: _discoveryStartHandler removed');
    ok($src !~ /sub _discoveryStopHandler/,   'Settings.pm: _discoveryStopHandler removed');
    ok($src !~ /\bstartDiscovery\b/,          'Settings.pm: no startDiscovery call site');
    ok($src !~ /\bstopDiscovery\b/,           'Settings.pm: no stopDiscovery call site');
    ok($src !~ /discoveryRunning/,            'Settings.pm: no discoveryRunning template param');
    ok($src !~ /sub _isDiscoveryRunning/,     'Settings.pm: _isDiscoveryRunning removed');
    ok($src !~ /sub _autoSetupAccount/,       'Settings.pm: _autoSetupAccount removed (M-3)');
    ok($src !~ /__DISCOVER__/,                'Settings.pm: __DISCOVER__ fallback block removed (M-3)');
    ok($src =~ /to_json/,                     'Settings.pm: to_json used in AJAX handler');
    ok($src =~ /addHTTPResponse/,             'Settings.pm: addHTTPResponse used in AJAX handler');

    # D-08 Channel 2: re-auth warning wiring
    ok($src =~ /anyAccountNeedsReauth/,       'Settings.pm: anyAccountNeedsReauth checked in handler()');
    ok($src =~ /paramRef->\{'warning'\}/,     q{Settings.pm: $paramRef->{'warning'} assignment present});
    ok($src =~ /clearNeedsReauth/,            'Settings.pm: clearNeedsReauth called on successful PKCE auth');

    # GH #147 D-04 (Plan 65-01): the eager derivation call site is removed --
    # PKCE auth must never mint playback credentials from the access token
    # (Login5 rejects wrong-provenance credentials). Whole-file guard: no
    # automatic derivation call site may remain anywhere in Settings.pm.
    # Plan 65-03 exception: deriveCredentialsFromToken is the USER-INITIATED
    # Keymaster browser fallback (correct provenance, staging + D-01
    # validation) -- the negative lookahead permits exactly that identifier
    # while still banning the legacy deriveCredentials(...) call.
    ok($src !~ /deriveCredentials(?!FromToken)/,
        'Settings.pm: no automatic derivation call site remains (GH #147 D-04)');

    # Plan 66-01 (D-04): the uncommitted 65-05 session workarounds (temp-
    # account pending-userId marker + its background resolution retry sub)
    # must never reappear -- whole-file guard.
    ok($src !~ /_pending_/,
        'Settings.pm: no pending-account marker remains (66-01 D-04)');
    ok($src !~ /_pkceResolvePendingAccount/,
        'Settings.pm: no pending-account resolution sub remains (66-01 D-04)');

    # GH #147 plan 65-03 (T-65-13): the browser-fallback handlers must never
    # persist the Keymaster token pair -- no token-storage call may appear in
    # either handler body (comments excluded).
    for my $handler (qw(_playerAuthBrowserStartHandler _playerAuthBrowserManualHandler)) {
        my ($body) = $src =~ /(sub \Q$handler\E\b.*?)(?=\nsub \w|\z)/s;
        my $code = join("\n", grep { !/^\s*#/ } split /\n/, ($body // ''));
        ok(defined $body && $code !~ /storeTokens/,
            "Settings.pm: $handler never persists tokens (T-65-13)");
    }
    # And exactly this fallback flow must consume deriveCredentialsFromToken.
    my ($browser_manual_body) = $src =~ /(sub _playerAuthBrowserManualHandler\b.*?)(?=\nsub \w|\z)/s;
    ok(defined $browser_manual_body && $browser_manual_body =~ /deriveCredentialsFromToken/,
        'Settings.pm: browser/manual handler derives via deriveCredentialsFromToken (GH #147 plan 65-03)');

    # GH #147: _pkceStoreAccount's AJAX response signals the separate
    # playback-authorization step to the caller.
    my ($pkce_store_body) = $src =~ /(sub _pkceStoreAccount\b.*?)(?=\nsub \w|\z)/s;
    ok(defined $pkce_store_body && $pkce_store_body =~ /playbackAuthRequired/,
        'Settings.pm: _pkceStoreAccount JSON response carries playbackAuthRequired (GH #147)');

    # prefs() should NOT include clientId
    ok($src =~ /sub prefs[^}]+return[^}]+(?!clientId)[^}]+}/s,
        'Settings.pm: prefs() method exists');
    ok($src !~ /return \(\$prefs.*clientId/,
        'Settings.pm: prefs() does not return clientId');

    # D-08/D-09: sp_dc save/state wiring (Plan 52-03)
    ok($src =~ /WebPlayer->storeSpDc/,
        'Settings.pm: pref_spDc save routes through WebPlayer->storeSpDc');
    ok($src =~ /WebPlayer->spDcMaskedPreview/,
        'Settings.pm: spDcMasked template param sourced from WebPlayer->spDcMaskedPreview');
    ok($src =~ /WebPlayer->state/,
        'Settings.pm: madeForYouState template param sourced from WebPlayer->state');
    ok($src !~ /\$prefs->set\(\s*'sp_?[Dd]c'/,
        'Settings.pm: sp_dc is never written to a flat $prefs->set key');
}

# ============================================================
# AUTH-06: Account switch updates preference
# ============================================================
SKIP: {
    skip "Settings.pm not yet updated with switchAccount handler", 2
        unless -f $settings_module && do {
            open(my $fh, '<', $settings_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /switchAccount/;
        };

    require Slim::Player::Client;
    require_ok('Plugins::SpotOn::Settings')
        or BAIL_OUT("Failed to load Settings.pm");

    # Simulate an account switch: Settings->handler should update activeAccount pref
    {
        my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
        $prefs->init({ accounts => { 'abc12345' => { displayName => 'Test' } }, activeAccount => '' });

        my $param_ref = { saveSettings => 1, switchAccount => 'abc12345' };

        # Call handler — we don't need a real $client or HTTP objects for this test
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },  # callback
            undef, undef
        );

        my $active = $prefs->get('activeAccount');
        is($active, 'abc12345',
            'AUTH-06: Account switch via handler updates activeAccount preference to new ID');
    }
}

# ============================================================
# GH #147 D-04 (Plan 65-01): PKCE auth completes WITHOUT credential
# derivation. Exercises the real _pkceStoreAccount directly against stubbed
# Credentials/DaemonManager/TokenManager collaborators. Runs after AUTH-06
# (which depends on a pristine 'accounts'/'activeAccount' prefs state via
# its own init() call) since this block deliberately mutates both keys.
# ============================================================
SKIP: {
    skip "Settings.pm module required for PKCE store-account test", 6
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::Unified::DaemonManager;
    require Slim::Web::HTTP;
    require JSON::PP;

    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    {
        $spotonPrefs->set('accounts', {});
        $spotonPrefs->set('activeAccount', 'existingacct');

        $Plugins::SpotOn::API::Credentials::derive_call_count            = 0;
        $Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls     = 0;
        @Plugins::SpotOn::API::TokenManager::store_account_prefs_calls    = ();
        @Slim::Web::HTTP::http_responses                                  = ();

        my $response = FakeSettingsResponse->new;
        Plugins::SpotOn::Settings::_pkceStoreAccount(
            'http_client_a', $response,
            { access_token => 'tok1', refresh_token => 'rtok1', expires_in => 3600, scope => 'x' },
            'client123', 'spotifyUserA', 'Test User A', 1,
        );

        is($Plugins::SpotOn::API::Credentials::derive_call_count, 0,
            'Plan65-01 D-04: _pkceStoreAccount never calls the derivation path (GH #147)');
        is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 1,
            'Plan65-01: scheduleInit still fires unconditionally (Pitfall 6 regression guard)');
        is(scalar(@Plugins::SpotOn::API::TokenManager::store_account_prefs_calls), 1,
            'Plan65-01: _storeAccountPrefs invoked exactly once for the flow');

        my $storedAccountId = $Plugins::SpotOn::API::TokenManager::store_account_prefs_calls[0];
        ok($storedAccountId && exists $spotonPrefs->get('accounts')->{$storedAccountId},
            'Plan65-01: account creation completed without derivation');

        # AJAX response carries the playback-auth signal for the JS caller.
        my $payload = eval {
            JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] });
        } || {};
        is($payload->{playbackAuthRequired}, 1,
            'Plan65-01: JSON response has playbackAuthRequired=1 (GH #147)');
        is($payload->{connectReady}, 0,
            'Plan65-01: JSON response has connectReady=0 (playback not yet authorized)');
    }
}

# ============================================================
# GH #147 plan 66-01 (a): _pkceClientId resolves to the bundled ncspot
# Extended-Quota client_id when no custom Client ID is configured (D-01,
# Keymaster retired as PKCE default).
# ============================================================
SKIP: {
    skip "Settings.pm module required for _pkceClientId test", 3
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::Client;
    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    $spotonPrefs->set('clientId', '');
    my $defaultId = Plugins::SpotOn::Settings::_pkceClientId();
    like($defaultId, qr/^d420a117/,
        'Plan66-01: empty clientId pref resolves to the d420a117-prefixed ncspot ID');
    is($defaultId, Plugins::SpotOn::API::Client::SPOTON_DEFAULT_CLIENT_ID(),
        'Plan66-01: _pkceClientId default matches Client::SPOTON_DEFAULT_CLIENT_ID');

    $spotonPrefs->set('clientId', 'customid1234customid1234customid');
    is(Plugins::SpotOn::Settings::_pkceClientId(), 'customid1234customid1234customid',
        'Plan66-01: custom clientId pref wins over the bundled default');

    $spotonPrefs->set('clientId', '');
}

# ============================================================
# GH #147 plan 66-01 (b): pkce/start payload — default mode carries the
# bundled ncspot Extended-Quota client_id and the dynamic loopback-to-LMS
# redirect (stubbed httpport 9005, unchanged since 65-04); custom mode keeps
# the GitHub Pages relay.
# ============================================================
SKIP: {
    skip "Settings.pm module required for pkce/start payload test", 6
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Slim::Web::HTTP;
    require JSON::PP;
    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    # Default (bundled ncspot) mode
    $spotonPrefs->set('clientId', '');
    @Slim::Web::HTTP::http_responses = ();
    my $response = FakeSettingsResponse->new(
        request => FakeSettingsRequest->new(headers => { Host => 'lms.local:9005' }));
    Plugins::SpotOn::Settings::_pkceStartHandler('http_client_pkce', $response);

    my $payload = eval {
        JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] });
    } || {};
    like($payload->{url}, qr/client_id=d420a117a32841c2b3474932e49fb54b/,
        'Plan66-01: default-mode auth URL carries the bundled ncspot client_id');
    like($payload->{url},
        qr{redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A9005%2Flogin},
        'Plan66-01: default-mode redirect_uri is the dynamic loopback /login (unchanged)');
    is($payload->{bundled}, 1,
        'Plan66-01: bundled payload field is 1');
    ok($payload->{nonce},
        'Plan66-01: pkce/start payload still carries a nonce');

    # Custom mode keeps the GitHub Pages relay
    $spotonPrefs->set('clientId', 'customid1234customid1234customid');
    @Slim::Web::HTTP::http_responses = ();
    $response = FakeSettingsResponse->new(
        request => FakeSettingsRequest->new(headers => {}));
    Plugins::SpotOn::Settings::_pkceStartHandler('http_client_pkce', $response);

    $payload = eval {
        JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] });
    } || {};
    like($payload->{url}, qr/client_id=customid1234customid1234customid/,
        'Plan66-01: custom-mode auth URL carries the custom client_id');
    like($payload->{url}, qr{redirect_uri=https%3A%2F%2Fstiefenm\.github\.io%2Fspoton%2Fauth%2F},
        'Plan66-01: custom-mode redirect_uri stays the GitHub Pages relay');

    $spotonPrefs->set('clientId', '');
}

# ============================================================
# GH #147 plan 66-01 (c): _pkceStoreAccount performs ZERO derivation for ANY
# client_id (D-02) — neither a bundled-default-ID token nor a custom-ID
# token ever calls deriveCredentialsFromToken/deriveCredentials. The JSON
# response for an account without a stubbed credentials.json honestly
# reports playbackAuthRequired=1/connectReady=0 (ZeroConf pairing required).
# ============================================================
SKIP: {
    skip "Settings.pm module required for zero-derivation tail test", 8
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::API::Client;
    require Plugins::SpotOn::Unified::DaemonManager;
    require Slim::Web::HTTP;
    require JSON::PP;

    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $bundledId    = Plugins::SpotOn::API::Client::SPOTON_DEFAULT_CLIENT_ID();

    # (c1) Bundled-default-ID token records ZERO derive calls
    {
        $spotonPrefs->set('accounts', {});
        $spotonPrefs->set('activeAccount', 'existingacct');
        Plugins::SpotOn::API::Credentials::reset_calls();
        $Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls = 0;
        @Slim::Web::HTTP::http_responses = ();

        my $response = FakeSettingsResponse->new;
        Plugins::SpotOn::Settings::_pkceStoreAccount(
            'http_client_bundled', $response,
            { access_token => 'bundledtok1', refresh_token => 'bundledrtok1', expires_in => 3600, scope => 'x' },
            $bundledId, 'spotifyUserBundled', 'Bundled User', 1,
        );

        is(scalar(@Plugins::SpotOn::API::Credentials::derive_from_token_calls), 0,
            'Plan66-01: bundled-ID path records ZERO deriveCredentialsFromToken calls (D-02)');
        is($Plugins::SpotOn::API::Credentials::derive_call_count, 0,
            'Plan66-01: bundled-ID path records ZERO legacy deriveCredentials calls (D-02)');

        my $payload = eval {
            JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] });
        } || {};
        is($payload->{connectReady}, 0,
            'Plan66-01: bundled-ID fresh account -> connectReady=0 (honest state)');
        is($payload->{playbackAuthRequired}, 1,
            'Plan66-01: bundled-ID fresh account -> playbackAuthRequired=1 (ZeroConf pairing required)');
    }

    # (c2) Custom clientId path also records ZERO derive calls (D-02)
    {
        Plugins::SpotOn::API::Credentials::reset_calls();
        @Slim::Web::HTTP::http_responses = ();

        my $response = FakeSettingsResponse->new;
        Plugins::SpotOn::Settings::_pkceStoreAccount(
            'http_client_cust', $response,
            { access_token => 'custtok1', refresh_token => 'custrtok1', expires_in => 3600, scope => 'x' },
            'someCustomClient1234567890abcdef', 'spotifyUserC', 'Custom User', 1,
        );

        is(scalar(@Plugins::SpotOn::API::Credentials::derive_from_token_calls), 0,
            'Plan66-01: custom-clientId path records ZERO deriveCredentialsFromToken calls (D-02)');
        is($Plugins::SpotOn::API::Credentials::derive_call_count, 0,
            'Plan66-01: custom-clientId path records ZERO legacy deriveCredentials calls (D-02)');

        my $payload = eval {
            JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] });
        } || {};
        is($payload->{playbackAuthRequired}, 1,
            'Plan66-01: custom-clientId path responds playbackAuthRequired=1');
    }
}

# ============================================================
# COMPAT-01: Global streamingMode handler save/validation (GH #96 scope
# extension) — real handler-execution coverage of the global setting.
# ============================================================
SKIP: {
    skip "Settings.pm not yet updated with global streamingMode handler", 3
        unless -f $settings_module && do {
            open(my $fh, '<', $settings_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /pref_streamingMode/;
        };

    skip "Settings.pm module required for global streamingMode test", 3
        unless eval { require Plugins::SpotOn::Settings; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_streamingMode => 'proxy' },
        sub { }, undef, undef
    );
    is($prefs->get('streamingMode'), 'proxy',
        'COMPAT-01: global streamingMode handler persists valid "proxy" value');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_streamingMode => 'bogus' },
        sub { }, undef, undef
    );
    is($prefs->get('streamingMode'), 'direct',
        'COMPAT-01: global streamingMode handler falls back to "direct" for invalid value');

    # Set a known sentinel value directly, then verify a saveSettings call with
    # no pref_streamingMode key leaves it untouched (defined-check guard, T-47-05).
    $prefs->set('streamingMode', 'proxy');
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1 },
        sub { }, undef, undef
    );
    is($prefs->get('streamingMode'), 'proxy',
        'COMPAT-01: global streamingMode handler leaves value untouched when pref_streamingMode key absent');
}

# ============================================================
# D-08 Channel 2: Settings page re-auth warning banner test
# ============================================================
SKIP: {
    skip "Settings.pm module required for reauth warning test", 2
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::TokenManager;

    {
        local %Plugins::SpotOn::API::TokenManager::needs_reauth = ();

        my $param_ref = {};
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },
            undef, undef
        );

        # NOTE: use exists() rather than truthiness — the shared Slim::Utils::Strings
        # test stub treats string() like cstring() (drops the first arg as if it were
        # a $client), so a single-arg string('KEY') call resolves to '' here, not the
        # real translated text. What we're verifying is whether handler() assigned the
        # key at all, not its stubbed content.
        ok(!exists $param_ref->{'warning'},
            'reauth warning: not set when no account needs reauth');
    }

    {
        local %Plugins::SpotOn::API::TokenManager::needs_reauth = ( abc12345 => 1 );

        my $param_ref = {};
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },
            undef, undef
        );

        ok(exists $param_ref->{'warning'},
            'reauth warning: set when an account needs reauth');
    }
}

# ============================================================
# i18n: All PLUGIN_SPOTON_ACCOUNT_* string keys exist in strings.txt
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 11 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        # Sentinel: if PLUGIN_SPOTON_ACTIVE_ACCOUNT is not present, Phase 2 strings
        # have not been added yet — skip entire block.
        skip "Phase 2 strings not yet added to strings.txt (Plan 02-03 will add them)", 11
            unless $content =~ /^PLUGIN_SPOTON_ACTIVE_ACCOUNT\s*$/m;

        # These are Phase 2 strings (Plans 02-03 era): guaranteed present once
        # PLUGIN_SPOTON_ACTIVE_ACCOUNT sentinel passes.
        # Plan 03 ZeroConf-specific strings are tested in the separate block below.
        my @required_keys = qw(
            PLUGIN_SPOTON_ACCOUNT_SETTINGS
            PLUGIN_SPOTON_ACTIVE_ACCOUNT
            PLUGIN_SPOTON_RATE_LIMIT_HINT
            PLUGIN_SPOTON_ACCOUNT_NONE
            PLUGIN_SPOTON_ACCOUNT_ACTIVE
            PLUGIN_SPOTON_ACCOUNT_SWITCH
            PLUGIN_SPOTON_ACCOUNT_REMOVE
            PLUGIN_SPOTON_ADD_ANOTHER
            PLUGIN_SPOTON_ACCOUNT_REMOVE_CONFIRM
        );

        for my $key (@required_keys) {
            ok($content =~ /^\Q$key\E\s*$/m,
                "i18n: $key exists in strings.txt");
        }
    }
}

# ============================================================
# i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT contains %s in both DE and EN
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 2 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my @lines = <$fh>;
        close($fh);

        # Find the PLUGIN_SPOTON_ACTIVE_ACCOUNT block
        my ($in_block, %translations) = (0);
        for my $line (@lines) {
            chomp $line;
            if ($line =~ /^PLUGIN_SPOTON_ACTIVE_ACCOUNT\s*$/) {
                $in_block = 1;
                next;
            }
            last if $in_block && $line =~ /^\S/;  # next key starts
            if ($in_block && $line =~ /^\s+(DE|EN)\s+(.+)$/) {
                $translations{$1} = $2;
            }
        }

        skip "PLUGIN_SPOTON_ACTIVE_ACCOUNT not in strings.txt yet (Plan 02-03 will add it)", 2
            unless %translations;

        like($translations{DE} // '', qr/%s/,
            'i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT DE translation contains %s placeholder');
        like($translations{EN} // '', qr/%s/,
            'i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT EN translation contains %s placeholder');
    }
}

# ============================================================
# PLAN 03 strings.txt: ZeroConf strings present (no PKCE strings)
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 8 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        # Sentinel: if PLUGIN_SPOTON_ZEROCONF_SETUP is not present, Plan 03
        # strings have not been added yet.
        skip "Plan 03 ZeroConf strings not yet added to strings.txt", 8
            unless $content =~ /^PLUGIN_SPOTON_ZEROCONF_SETUP\s*$/m;

        # ZeroConf strings must exist
        for my $key (qw(
            PLUGIN_SPOTON_ZEROCONF_SETUP
            PLUGIN_SPOTON_ZEROCONF_STEP1
            PLUGIN_SPOTON_WAITING_FOR_CONNECTION
            PLUGIN_SPOTON_START_DISCOVERY
            PLUGIN_SPOTON_STOP_DISCOVERY
        )) {
            ok($content =~ /^\Q$key\E\s*$/m, "Plan03 i18n: $key in strings.txt");
        }

        # PKCE strings must NOT exist
        ok($content !~ /^PLUGIN_SPOTON_CLIENT_ID_LABEL\s*$/m,
            'Plan03 i18n: PLUGIN_SPOTON_CLIENT_ID_LABEL removed from strings.txt');
        ok($content !~ /^PLUGIN_SPOTON_CLIENT_ID_HINT\s*$/m,
            'Plan03 i18n: PLUGIN_SPOTON_CLIENT_ID_HINT removed from strings.txt');
        ok($content !~ /^PLUGIN_SPOTON_SETUP_WIZARD\s*$/m,
            'Plan03 i18n: PLUGIN_SPOTON_SETUP_WIZARD removed from strings.txt');
    }
}

# ============================================================
# P-CR-03: CSRF guard on write endpoints
# ============================================================
{
    my $settings_file = "$project_dir/Plugins/SpotOn/Settings.pm";
    my $html_file     = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";

    SKIP: {
        skip "Settings.pm not found", 4 unless -f $settings_file;

        open(my $fh, '<', $settings_file) or die $!;
        my $src = do { local $/; <$fh> };
        close($fh);

        # 1. _csrfCheck sub is defined
        ok($src =~ /sub _csrfCheck\b/, 'P-CR-03: _csrfCheck helper defined in Settings.pm');

        # 2-3. Write handlers call _csrfCheck
        # Extract each handler body (from sub declaration to next sub or end of file)
        # and verify _csrfCheck is called within it.
        for my $handler (qw(_clearLogsHandler _pkceStartHandler)) {
            my ($body) = $src =~ /(sub \Q$handler\E\b.*?)(?=\nsub \w|\z)/s;
            ok(defined $body && $body =~ /_csrfCheck/,
                "P-CR-03: $handler calls _csrfCheck");
        }

        # 4. _diagnosticBundleHandler does NOT call _csrfCheck (read-only, gated by diagnosticMode)
        my ($diag_body) = $src =~ /(sub _diagnosticBundleHandler\b.*?)(?=\nsub \w|\z)/s;
        ok(defined $diag_body && $diag_body !~ /_csrfCheck/,
            'P-CR-03: _diagnosticBundleHandler does NOT call _csrfCheck (read-only)');
    }

    SKIP: {
        skip "basic.html not found", 1 unless -f $html_file;

        open(my $fh, '<', $html_file) or die $!;
        my $html = do { local $/; <$fh> };
        close($fh);

        # 7. basic.html contains X-Requested-With in AJAX calls
        my @matches = ($html =~ /X-Requested-With/g);
        ok(scalar @matches >= 3,
            'P-CR-03: basic.html has X-Requested-With in >= 3 AJAX calls (got ' . scalar(@matches) . ')');
    }
}

# ============================================================
# Plan 52-03: sp_dc save routes through WebPlayer->storeSpDc (D-08/D-09)
# ============================================================
SKIP: {
    skip "Settings.pm module required for sp_dc save test", 4
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::WebPlayer;

    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    $spotonPrefs->set('accounts', { spdcacct1 => { displayName => 'Test' } });
    $spotonPrefs->set('activeAccount', 'spdcacct1');

    # (a) Saving a fresh sp_dc value routes through WebPlayer->storeSpDc,
    # with the sanitized value (not the masked preview).
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_spDc => 'AQDxAbCdEf1234567890' },
        sub { }, undef, undef
    );
    is(scalar(@Plugins::SpotOn::API::WebPlayer::store_spdc_calls), 1,
        'Plan52-03: saving pref_spDc calls WebPlayer->storeSpDc exactly once');
    is($Plugins::SpotOn::API::WebPlayer::store_spdc_calls[0][0], 'spdcacct1',
        'Plan52-03: storeSpDc called with the active accountId');
    is($Plugins::SpotOn::API::WebPlayer::store_spdc_calls[0][1], 'AQDxAbCdEf1234567890',
        'Plan52-03: storeSpDc receives the sanitized raw value (not masked)');

    # (b) Resubmitting the current masked preview (user did not edit the
    # field) must NOT overwrite the stored cookie.
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    $Plugins::SpotOn::API::WebPlayer::next_masked_preview = 'AQDx****';
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_spDc => 'AQDx****' },
        sub { }, undef, undef
    );
    is(scalar(@Plugins::SpotOn::API::WebPlayer::store_spdc_calls), 0,
        'Plan52-03: resubmitting the masked preview does not call storeSpDc again');
}

# ============================================================
# Plan 52-06 gap closure: empty sp_dc submission clears stored cookie (WR-03)
# ============================================================
SKIP: {
    skip "Settings.pm module required for sp_dc clear test", 3
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::WebPlayer;

    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    $spotonPrefs->set('accounts', { spdcacct1 => { displayName => 'Test' } });
    $spotonPrefs->set('activeAccount', 'spdcacct1');

    # (a) A previously stored cookie exists (hasSpDc => 1) and the user
    # submits an empty pref_spDc -- storeSpDc(accountId, '') must be called
    # exactly once to clear it.
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    $Plugins::SpotOn::API::WebPlayer::next_masked_preview = 'AQDx****';
    $Plugins::SpotOn::API::WebPlayer::next_has_spdc        = 1;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_spDc => '' },
        sub { }, undef, undef
    );
    is(scalar(@Plugins::SpotOn::API::WebPlayer::store_spdc_calls), 1,
        'Plan52-06: empty pref_spDc with a stored cookie calls storeSpDc exactly once');
    is_deeply($Plugins::SpotOn::API::WebPlayer::store_spdc_calls[0], ['spdcacct1', ''],
        'Plan52-06: storeSpDc called with (accountId, empty string) to clear');

    # (b) No stored cookie (hasSpDc => 0) -- empty submission must NOT call
    # storeSpDc (avoid pointless calls on accounts that never had sp_dc).
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    $Plugins::SpotOn::API::WebPlayer::next_has_spdc = 0;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_spDc => '' },
        sub { }, undef, undef
    );
    is(scalar(@Plugins::SpotOn::API::WebPlayer::store_spdc_calls), 0,
        'Plan52-06: empty pref_spDc with no stored cookie does not call storeSpDc');
}

# ============================================================
# Plan 52-06 gap closure: pathfinderHash pref stored via Settings
# ============================================================
SKIP: {
    skip "Settings.pm module required for pathfinderHash pref test", 4
        unless eval { require Plugins::SpotOn::Settings; 1 };

    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    # (a) A valid 64-hex-char hash is stored as submitted.
    my $validHash = 'a1b2c3d4' x 8;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_pathfinderHash => $validHash },
        sub { }, undef, undef
    );
    is($spotonPrefs->get('pathfinderHash'), $validHash,
        'Plan52-06: pathfinderHash pref stored with valid hex input');

    # (b) Non-hex characters are stripped before storage.
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_pathfinderHash => 'zzZZ' . $validHash . '!!' },
        sub { }, undef, undef
    );
    is($spotonPrefs->get('pathfinderHash'), $validHash,
        'Plan52-06: pathfinderHash pref strips non-hex characters from input');

    # (c) Empty submission clears the pref.
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_pathfinderHash => '' },
        sub { }, undef, undef
    );
    is($spotonPrefs->get('pathfinderHash'), '',
        'Plan52-06: empty pref_pathfinderHash clears the stored hash');

    # (d) Template param pathfinderHash is populated from prefs (no saveSettings).
    $spotonPrefs->set('pathfinderHash', $validHash);
    my $param_ref = {};
    Plugins::SpotOn::Settings->handler(
        undef, $param_ref,
        sub { }, undef, undef
    );
    is($param_ref->{pathfinderHash}, $validHash,
        'Plan52-06: template param pathfinderHash populated from prefs');
}

# ============================================================
# Plan 52-03: template params spDcMasked / madeForYouState (D-04/D-08)
# ============================================================
SKIP: {
    skip "Settings.pm module required for madeForYouState param test", 3
        unless eval { require Plugins::SpotOn::Settings; 1 };

    require Plugins::SpotOn::API::WebPlayer;
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    is($Plugins::SpotOn::API::WebPlayer::next_state, 'empty',
        'Plan52-03: WebPlayer stub next_state defaults to empty after reset_calls');
    $Plugins::SpotOn::API::WebPlayer::next_masked_preview = 'AQDx****';
    $Plugins::SpotOn::API::WebPlayer::next_state           = 'valid';

    my $param_ref = {};
    Plugins::SpotOn::Settings->handler(
        undef, $param_ref,
        sub { }, undef, undef
    );

    is($param_ref->{spDcMasked}, 'AQDx****',
        'Plan52-03: template param spDcMasked populated from WebPlayer->spDcMaskedPreview');
    is($param_ref->{madeForYouState}, 'valid',
        'Plan52-03: template param madeForYouState populated from WebPlayer->state');
}

# ============================================================
# Auth Health Dashboard -- moved to Status.pm (260717 quick task). The
# dashboard's runtime behavior (JSON wiring, _collectAuthHealth fixture
# coverage) now lives in t/13_status_page.t alongside the rest of the
# Status page. This is just a regression guard confirming Settings.pm no
# longer owns any of it, and that Status.pm picked up _collectAuthHealth.
# ============================================================
{
    SKIP: {
        skip "Settings.pm not found", 2 unless -f $settings_module;

        open(my $fh, '<', $settings_module) or die $!;
        my $src = do { local $/; <$fh> };
        close($fh);

        ok($src !~ /sub _collectAuthHealth\b/,
            'Settings.pm no longer defines _collectAuthHealth (moved to Status.pm)');
        ok($src !~ /authHealth/,
            'Settings.pm no longer references authHealth (moved to Status.pm)');
    }

    my $status_module = "$project_dir/Plugins/SpotOn/Status.pm";
    SKIP: {
        skip "Status.pm not found", 1 unless -f $status_module;

        open(my $fh, '<', $status_module) or die $!;
        my $src = do { local $/; <$fh> };
        close($fh);

        ok($src =~ /sub _collectAuthHealth\b/,
            'Status.pm defines _collectAuthHealth (moved from Settings.pm)');
    }
}

# ============================================================
# Gap SOLO-BYOK (71-03): backend pref whitelist, spak-key format
# validation, and the storeKey()/clearKey() wiring were only exercised
# indirectly (perl -c / grep in the plan's own verify block). These tests
# drive Settings->handler() end-to-end against the real Soloist module
# (unshifted onto @INC above) and assert on-disk/pref state, not just that
# the handler ran without dying.
# ============================================================
SKIP: {
    skip "Settings.pm/Soloist.pm module required for backend/spak-key save tests", 11
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    # --- (a) backend pref whitelist ---
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_backend => 'soloist' },
        sub { }, undef, undef
    );
    is($prefs->get('backend'), 'soloist',
        'SOLO-BYOK: valid pref_backend "soloist" is persisted');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_backend => 'evil; rm -rf /' },
        sub { }, undef, undef
    );
    is($prefs->get('backend'), 'librespot',
        'SOLO-BYOK: invalid/tampered pref_backend value falls back to "librespot" (T-71-05)');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_backend => 'LIBRESPOT' },
        sub { }, undef, undef
    );
    is($prefs->get('backend'), 'librespot',
        'SOLO-BYOK: case-mismatched pref_backend value is rejected, not case-normalized');

    # --- (b) spak-key format validation ---
    Plugins::SpotOn::Soloist::clearKey() if Plugins::SpotOn::Soloist::hasKey();

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistKey => 'short' },
        sub { }, undef, undef
    );
    ok(!Plugins::SpotOn::Soloist::hasKey(),
        'SOLO-BYOK: spak-key shorter than the 16-char minimum is rejected, not stored');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistKey => "abcd1234\nrm -rf /" },
        sub { }, undef, undef
    );
    ok(!Plugins::SpotOn::Soloist::hasKey(),
        'SOLO-BYOK: spak-key containing a newline/shell metacharacter is rejected, not stored');

    # --- (c) valid key triggers storeKey() and is persisted to disk ---
    my $valid_key = 'abcDEF123_-.abcDEF123';    # 22 chars, allowed charset
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistKey => $valid_key },
        sub { }, undef, undef
    );
    ok(Plugins::SpotOn::Soloist::hasKey(),
        'SOLO-BYOK: valid spak-key triggers storeKey() and hasKey() reflects it');

    my $keyPath = Plugins::SpotOn::Soloist::keyPath();
    ok(-f $keyPath, 'SOLO-BYOK: valid spak-key is actually written to keyPath() on disk');

    open(my $kfh, '<', $keyPath) or die "cannot read $keyPath: $!";
    my $on_disk = do { local $/; <$kfh> };
    close($kfh);
    is($on_disk, $valid_key, 'SOLO-BYOK: on-disk spak-key content matches the submitted value exactly');

    # --- masked-preview resubmit must not clear the just-stored key ---
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistKey => Plugins::SpotOn::Settings::SOLOIST_KEY_MASKED_PREVIEW() },
        sub { }, undef, undef
    );
    ok(Plugins::SpotOn::Soloist::hasKey(),
        'SOLO-BYOK: resubmitting the masked placeholder does not clear the stored key');

    # --- empty submission clears an existing key (WR-03) ---
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistKey => '' },
        sub { }, undef, undef
    );
    ok(!Plugins::SpotOn::Soloist::hasKey(),
        'SOLO-BYOK: empty pref_soloistKey submission clears a previously stored key');
    ok(!-f $keyPath,
        'SOLO-BYOK: clearing the key also removes the on-disk keyPath() file');

    # cleanup for any later tests reusing this same $cache_dir
    Plugins::SpotOn::Soloist::clearKey() if Plugins::SpotOn::Soloist::hasKey();
}

done_testing();
