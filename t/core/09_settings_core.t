#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: core half of t/09_settings.t -- Settings.pm over
# per-file MOCK roles; the Soloist-role cells are t/soloist/09_settings_soloist.t,
# the REAL-librespot cells t/librespot/09_settings_librespot.t)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# ============================================================
# FakeSettingsResponse — minimal Slim::Web response double for exercising
# the handlers directly (Plan 51-03 Task 2): supports the header/code/
# content_type accessor calls made by _jsonResponse.
# Plan 65-04: optional request => FakeSettingsRequest for handlers that read
# $response->request (e.g. _playerAuthStartHandler's CSRF header).
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
# for the handlers that read request headers (85-13: no PKCE handler left).
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
    # 84-13 (csrf cell): a namespace served from %_ns_store (server) is
    # written there too -- otherwise get() never sees the value.
    if (exists \$_ns_store{ \$self->{_ns} }) {
        \$_ns_store{ \$self->{_ns} }{\$key} = \$val;
        return;
    }
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
# 84.1-08 (WR-06, WR-03 notice): _formatHealthNotice reads getClient($mac)
# for the player name only, falling back to the bare MAC when it returns
# undef -- sufficient for these tests, which never assert on the name.
sub getClient { return undef; }
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
our %valid_login;    # 85-11: hasValidLogin override per account (Settings accountStepOk)
sub hasValidLogin { my ($class, $id) = @_; return $valid_login{$id} ? 1 : 0 }
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
    %valid_login = ();
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
sub PAIRING_WINDOW_SECONDS { return 300 }   # 85-10 (D-21)
# 85-11 (D-23): the settings handler takes the discover-folder intake first.
our $next_intake = [0, 'none'];
our $intake_calls = 0;
sub intakeDiscoverFolder { $intake_calls++; return @{ $next_intake } }
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
    $next_intake              = [0, 'none'];
    $intake_calls             = 0;
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
# Phase 83.3 plan 04 (D-02/D-07): Settings.pm's soloistPlayers/
# _soloistRenewStatusHandler builders now read these two directly.
our %fake_pending_switches = ();
our %fake_switched_at      = ();
# 84.1-08 (WR-06, WR-03 notice): a controllable soloistHealthFor() double,
# keyed by MAC -- $fake_health{$mac} is a plain hashref shaped like the
# real %soloistHealth record (last_reason, last_at) or absent entirely.
our %fake_health = ();
sub scheduleInit         { $schedule_init_calls++ }
sub helperInstances      { return @fake_helpers }
sub pendingBinarySwitches { return { %fake_pending_switches } }
sub switchedAtFor        { my ($class, $mac) = @_; return $fake_switched_at{$mac}; }
sub soloistHealthFor     { my ($class, $mac) = @_; return $fake_health{$mac}; }
# 84-13 (notice render cell): the soloistPlayers loop reads these per client.
sub helperForClient      { return undef; }
sub crashStateSnapshot   { return undef; }
# 84-07 (D-14): Settings.pm reads its soloistUnsupportedOS flag from the ONE
# platform site; this double mirrors the real rule over main::ISWINDOWS/ISMAC.
sub platformSupportsSoloist { return (main::ISWINDOWS() || main::ISMAC()) ? 0 : 1; }
# 84-08 (SEAM-6.2): Settings.pm reaches the active backend through the role
# registry -- these doubles mirror the real factory rule (D-14 platform
# force, validated pref, default librespot) over the stubbed prefs.
sub backendName {
    return 'librespot' unless platformSupportsSoloist();
    require Plugins::SpotOn::Backend;
    my $name = Slim::Utils::Prefs::preferences('plugin.spoton')->get('backend') // 'librespot';
    return (grep { $_ eq $name } Plugins::SpotOn::Backend::names()) ? $name : 'librespot';
}
sub backendClass { require Plugins::SpotOn::Backend; return Plugins::SpotOn::Backend::classFor(backendName()); }
# 74b-03 (D-07): the diagnostic bundle reads these three; test-controlled values.
our $fake_output = { chosen => 'auto', resolved => 'pcm', effective => 'pcm', type => 'soc', path => 'proxy', reason => '' };
our $fake_glibc = undef;
our $fake_glibc_problem = undef;
sub effectiveOutput      { return { %$fake_output } }
sub glibcVersion         { return $fake_glibc }
sub soloistGlibcProblem  { return $fake_glibc_problem }
sub reset_calls     {
    $schedule_init_calls = 0;
    @fake_helpers = ();
    %fake_pending_switches = ();
    %fake_switched_at      = ();
    %fake_health           = ();
}

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
# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($stub_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# Settings.pm reaches the roles through the registry: routes() at new(),
# settingsInfo() per registered backend, keyState/qualityInfo through
# backendClass(), bootstrap() for a saved available backend.
sub routes       { return [] }
sub settingsInfo { return 'ok' }
sub keyState     { return { supported => 0, present => 0 } }
sub storeKey     { return (0, 'unsupported') }
sub clearKey     { return 0 }
sub qualityInfo  { return { supported => 0, validLevels => [] } }
sub quality      { return 'unsupported' }
sub bootstrap    { return 'ok' }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
# 74b-03 (D-07): test-controlled values for the diagnostic bundle cells.
our %SETTINGS_INFO = ();
our $KEY_PRESENT = 0;
our $EFFECTIVE_LABEL = '';
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
sub routes       { return [] }
sub settingsInfo { my ($class, $p) = @_; %$p = (%$p, %SETTINGS_INFO); return 'ok' }
sub keyState     { return { supported => 1, present => $KEY_PRESENT } }
sub storeKey     { return (1) }
sub clearKey     { return 1 }
sub qualityInfo  { return { supported => 0, validLevels => [], (length $EFFECTIVE_LABEL ? (effectiveLabel => $EFFECTIVE_LABEL) : ()) } }
sub quality      { return 'unsupported' }
sub bootstrap    { return 'ok' }
1;
END

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

    # 85-13 (D-01): the re-auth banner (a PKCE notion) is replaced by the
    # pairing hint; no PKCE success path remains to clear a re-auth flag.
    ok($src !~ /anyAccountNeedsReauth/,       'Settings.pm: anyAccountNeedsReauth no longer checked in handler() (85-13)');
    ok($src =~ /paramRef->\{'warning'\}/,     q{Settings.pm: $paramRef->{'warning'} assignment present});
    ok($src !~ /clearNeedsReauth/,            'Settings.pm: clearNeedsReauth not called -- no PKCE success path (85-13)');

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

    # 85-13 (D-01, assumption A11): the Keymaster browser fallback was a PKCE
    # flow and is gone with it -- neither handler, nor the token-derivation
    # call it was the last user of, nor the PKCE store/finish chain remains.
    for my $gone (qw(_playerAuthBrowserStartHandler _playerAuthBrowserManualHandler _pkceStoreAccount)) {
        ok($src !~ /sub \Q$gone\E\b/,
            "Settings.pm: sub $gone removed (85-13)");
    }
    ok($src !~ /deriveCredentialsFromToken/,
        'Settings.pm: no deriveCredentialsFromToken call site remains (85-13, D-01)');
    ok($src !~ /settings\/pkce\/|playerauth\/browser/,
        'Settings.pm: names no pkce/* or playerauth/browser/* route (85-13, D-01)');

    # prefs() should NOT include clientId
    ok($src =~ /sub prefs[^}]+return[^}]+(?!clientId)[^}]+}/s,
        'Settings.pm: prefs() method exists');
    ok($src !~ /return \(\$prefs.*clientId/,
        'Settings.pm: prefs() does not return clientId');

    # 85-12 (decision-D17 pathfinder-login5-plus-rootlist, cookie-free): the
    # sp_dc save/state wiring of Plan 52-03 and the manual Pathfinder hash of
    # Plan 52-06 are gone from Settings.pm.
    ok($src !~ /WebPlayer/,
        'Settings.pm: names no WebPlayer module (85-12, D-17 cookie-free)');
    ok($src !~ /pref_spDc|spDcMasked|madeForYouState|storeSpDc|spDcMaskedPreview/,
        'Settings.pm: no sp_dc save block, no spDcMasked / madeForYouState param (85-12)');
    ok($src !~ /pref_pathfinderHash|pathfinderHash/,
        'Settings.pm: no manual Pathfinder hash save block or param (85-12, D-19)');
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
# 85-13 (D-01): the settings side of PKCE is deleted -- routes, handlers,
# Client-ID pref and template params. Replaces the Plan 65-01 / 66-01
# _pkceStoreAccount / _pkceClientId / _pkceStartHandler behavior tests
# one-for-one by absence assertions. Settings->new() is replayed through the
# same Tie::RegexpHash model as the Soloist renew routes (resolve_raw_route),
# so the unanchored raw route `login` (RESEARCH P10, T-85-28) is proven gone,
# not just "not literally registered".
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Slim::Web::Pages;
    Slim::Web::Pages::reset_calls();
    Plugins::SpotOn::Settings->new();
    my @registered = @Slim::Web::Pages::registered_raw;
    my $prefix = 'plugins/SpotOn/settings/';

    ok(scalar(@registered) > 0, '85-13: Settings->new() still registers raw routes');

    ok(!defined resolve_raw_route(\@registered, 'login'),
        'raw route login not registered');
    ok(!defined resolve_raw_route(\@registered, 'plugins/SpotOn/settings/xlogin-anything'),
        '85-13 (P10): no unanchored catch-all matches a path merely containing "login"');
    for my $gone (qw(pkce/start pkce/callback pkce/manual playerauth/browser/start playerauth/browser/manual)) {
        ok(!defined resolve_raw_route(\@registered, $prefix . $gone),
            "raw route $gone not registered");
    }
    ok(!(grep { $_->[0] =~ /login|pkce|browser/ } @registered),
        '85-13: no registered raw key mentions login, pkce or browser');

    for my $kept (qw(diagnosticBundle clearLogs playerauth/start playerauth/status playerauth/cancel)) {
        ok(defined resolve_raw_route(\@registered, $prefix . $kept),
            "raw route $kept still registered (85-13)");
    }

    for my $gone (qw(_pkceStartHandler _pkceCallbackHandler _pkceManualHandler
                     _playerAuthBrowserStartHandler _playerAuthBrowserManualHandler
                     _pkceLoadVerifierDataFromState _pkceFinishAuth _pkceStoreAccount
                     _pkceClientId _isPkceConfigured _renderPkceResultPage)) {
        ok(!defined &{"Plugins::SpotOn::Settings::$gone"}, "85-13: Settings::$gone is gone");
    }

    # Template params: none of the PKCE / Client-ID keys is handed to the page.
    {
        my $params = {};
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        for my $key (qw(customClientId clientIdMode reauthReason pkceConfigured
                        needsPkceReauth needsMigration redirectUri)) {
            ok(!exists $params->{$key}, "85-13: handler() no longer sets template param $key");
        }
    }

    # A stale settings page that still posts the Client-ID field stores nothing.
    {
        my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');
        $spotonPrefs->set('clientId', '');
        my $params = { saveSettings => 1, pref_clientId => 'customid1234customid1234customid' };
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        is($spotonPrefs->get('clientId') // '', '',
            '85-13: a posted pref_clientId is not stored (field and save block deleted)');
    }

    # The page warning is the pairing hint, driven by the accounts' needsPairing flag.
    {
        my $spotonPrefs    = Slim::Utils::Prefs::preferences('plugin.spoton');
        my $accountsBefore = $spotonPrefs->get('accounts');
        $spotonPrefs->set('accounts', { aaaa1111 => { displayName => 'A' } });
        my $params = {};
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        ok(!exists $params->{warning}, '85-13: no warning while no account needs pairing');

        $spotonPrefs->set('accounts', { aaaa1111 => { displayName => 'A' }, bbbb2222 => { displayName => 'B', needsPairing => 1 } });
        $params = {};
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        ok(exists $params->{warning}, '85-13: warning set when an account needs pairing');
        $spotonPrefs->set('accounts', $accountsBefore || {});
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

        # 85-13 (D-01): a re-auth flag (a PKCE notion) no longer raises the
        # page warning; the pairing hint does (see the needsPairing cases above).
        ok(!exists $param_ref->{'warning'},
            'reauth warning: a needs-reauth flag alone no longer sets the page warning (85-13)');
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
        for my $handler (qw(_clearLogsHandler _playerAuthStartHandler)) {
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
# 85-12 (decision-D17 pathfinder-login5-plus-rootlist, cookie-free; D-19):
# the sp_dc field and the manual Pathfinder hash field are gone. A stale
# settings page that still posts the two old fields stores nothing and does
# not die (T-85-53); the template gets no sp_dc / hash param.
# Replaces the Plan 52-03 / 52-06 sp_dc save, clear, pathfinderHash and
# madeForYouState cases (14 cases -> 10 below).
# ============================================================
SKIP: {
    skip "Settings.pm module required for the stale-form test", 10
        unless eval { require Plugins::SpotOn::Settings; 1 };

    no warnings 'once';    # the stub's package variables are written from here only

    require Plugins::SpotOn::API::WebPlayer;    # test stub: records calls if Settings ever reaches it

    my $spotonPrefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    $spotonPrefs->set('accounts', { spdcacct1 => { displayName => 'Test' } });
    $spotonPrefs->set('activeAccount', 'spdcacct1');
    $spotonPrefs->set('pathfinderHash', '');
    my $validHash = 'a1b2c3d4' x 8;

    # (a) a stale form posting both old fields stores nothing and does not die
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    my $died = !eval {
        Plugins::SpotOn::Settings->handler(
            undef, { saveSettings => 1, pref_spDc => 'AQDxAbCdEf1234567890', pref_pathfinderHash => $validHash },
            sub { }, undef, undef
        );
        1;
    };
    ok(!$died, '85-12 stale form: posting pref_spDc and pref_pathfinderHash does not die (T-85-53)');
    is(scalar(@Plugins::SpotOn::API::WebPlayer::store_spdc_calls), 0,
        '85-12 stale form: pref_spDc reaches no storeSpDc call');
    is($spotonPrefs->get('pathfinderHash'), '',
        '85-12 stale form: pref_pathfinderHash is not stored');
    ok(!exists $spotonPrefs->get('accounts')->{spdcacct1}{sp_dc},
        '85-12 stale form: no sp_dc lands in the account record');

    # (b) an empty stale field is as inert as a filled one
    Plugins::SpotOn::API::WebPlayer::reset_calls();
    $Plugins::SpotOn::API::WebPlayer::next_has_spdc = 1;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_spDc => '', pref_pathfinderHash => '' },
        sub { }, undef, undef
    );
    is(scalar(@Plugins::SpotOn::API::WebPlayer::store_spdc_calls), 0,
        '85-12 stale form: an empty pref_spDc clears nothing through WebPlayer either');

    # (c) the template params are gone, whatever the stub or the pref says
    $Plugins::SpotOn::API::WebPlayer::next_masked_preview = 'AQDx****';
    $Plugins::SpotOn::API::WebPlayer::next_state           = 'valid';
    $spotonPrefs->set('pathfinderHash', $validHash);
    my $param_ref = {};
    Plugins::SpotOn::Settings->handler(undef, $param_ref, sub { }, undef, undef);
    ok(!exists $param_ref->{spDcMasked},      '85-12 params: no spDcMasked');
    ok(!exists $param_ref->{madeForYouState}, '85-12 params: no madeForYouState');
    ok(!exists $param_ref->{pathfinderHash},  '85-12 params: no pathfinderHash (D-19)');
    $spotonPrefs->set('pathfinderHash', '');

    # (d) the settings page asks for neither (template)
    my $html_file = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
    open(my $hfh, '<:encoding(UTF-8)', $html_file) or die "Cannot open basic.html: $!";
    my $html = do { local $/; <$hfh> };
    close($hfh);
    ok($html !~ /pref_spDc|spDcMasked|madeForYouState|PLUGIN_SPOTON_(?:SP_DC|SETUP_SPDC|MFY_SECRETS_DOWN)/,
        '85-12 template: no sp_dc input, masked preview, status dots, how-to or secrets-down hint');
    ok($html !~ /pref_pathfinderHash|pathfinderHash|PLUGIN_SPOTON_(?:PATHFINDER_HASH|SETUP_PATHFINDER)/,
        '85-12 template: no manual Pathfinder hash field and no setup-guide step for it (D-19)');
}

# 85-12: every value basic.html renders into an attribute through a template
# variable keeps `| html` -- the removal must not leave a bare value behind
# (l.value is the one fixed-constant exception, the soloist quality levels).
{
    my $html_file = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
    open(my $hfh, '<:encoding(UTF-8)', $html_file) or die "Cannot open basic.html: $!";
    my $html = do { local $/; <$hfh> };
    close($hfh);
    my @bare = grep { !/\|\s*(?:html|string)\b/ && !/^\s*l\.value\s*$/ }
               $html =~ /value="\[%(.*?)%\]"/g;
    is(scalar(@bare), 0, '85-12: every value="[% ... %]" in basic.html keeps | html (or | string)')
        or diag("bare: @bare");
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
# Phase 83.3 plan 06 (live-check fix, Rule 1 -- bug), re-pointed in 84-13
# Task 2 (SEAM-6.2, B5/B6/W7): the renew routes are the Soloist role's
# routes() -- FULL LMS paths, status route FIRST -- registered by
# Settings->new() through one generic wrapper per entry (_csrfCheck unless
# the entry's method is 'GET', fail-closed; _jsonResponse around the role's
# plain-data answer). Slim::Web::Pages ties its %rawFunctions hash to
# Tie::RegexpHash, which matches BOTH inserts and lookups via UNANCHORED
# substring regex ("$key !~ m/$storedRegex/"), not literal string equality
# -- discovered live on lavender-UAT when POSTing
# /plugins/SpotOn/settings/soloistRenew returned the STATUS payload because
# 'soloistRenewStatus' (registered second, originally) silently overwrote
# 'soloistRenew's stored handler at add() time. resolve_raw_route()
# replicates Tie::RegexpHash's own add()/match() algorithm against the REAL
# registration order Settings->new() produces; BOTH paths are resolved
# through it and invoked -- never a handler sub called directly.
# ============================================================
sub resolve_raw_route {
    my ($registrations, $path) = @_;
    # Build the effective Tie::RegexpHash state by replaying add() in
    # registration order: a NEW key that matches an EXISTING stored
    # regex overwrites that slot's VALUE (Tie/RegexpHash.pm add()/_find()).
    my @keys;
    my @values;
    for my $reg (@$registrations) {
        my ($key, $value) = @$reg;
        my $found;
        for my $i (0 .. $#keys) {
            if ($key =~ m/$keys[$i]/) { $found = $i; last; }
        }
        if (defined $found) {
            $values[$found] = $value;
        } else {
            push @keys,   $key;
            push @values, $value;
        }
    }
    # match(): first stored regex (in insertion order) that the
    # REQUESTED path satisfies.
    for my $i (0 .. $#keys) {
        return $values[$i] if $path =~ m/$keys[$i]/;
    }
    return undef;
}

# ============================================================
# 84-13 Task 2 (P-CR-03, B6): the generic route wrapper inside `sub new`
# runs _csrfCheck for every entry whose method is not 'GET' (fail-closed:
# an unlabeled or misspelled method is still checked, never `eq 'POST'`).
# ============================================================
{
    my $settings_file = "$project_dir/Plugins/SpotOn/Settings.pm";
    open(my $fh, '<', $settings_file) or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);
    my ($newBody) = $src =~ /(\nsub new\b.*?)(?=\nsub \w|\z)/s;
    ok(defined $newBody && $newBody =~ /_csrfCheck/, 'P-CR-03 (84-13): the route wrapper in sub new calls _csrfCheck');
    ok(defined $newBody && $newBody =~ /ne\s+'GET'/, "P-CR-03 (84-13): the wrapper's csrf condition is the fail-closed `ne 'GET'` form");
    ok(defined $newBody && $newBody =~ /_jsonResponse/, 'P-CR-03 (84-13): the route wrapper answers through _jsonResponse');
    my $nonComment = join("\n", grep { !/^\s*#/ } split /\n/, $src);
    ok($nonComment !~ /formatQualityNotice\s*=>/ && $nonComment !~ /\{formatQualityNotice\}/ && $nonComment !~ /^sub _formatQualityNotice\b/m,
        '84-13 (W8): Settings.pm no longer defines or wires _formatQualityNotice (role-private now)');
    ok($nonComment !~ /^sub _soloistRenew(?:Status)?Handler\b/m, '84-13: the two renew handler subs are gone from Settings.pm');
}

# --- 84.1-08 WR-06 (D-04): _formatHealthNotice renders a date AND a
# clock time, not %H:%M alone ---
{
    my $mac   = 'aa:84:08:09:00:01';
    my $epoch = time() - 3600;
    $Plugins::SpotOn::Unified::DaemonManager::fake_health{$mac} =
        { last_reason => 'no_login', last_at => $epoch };

    my $expected = POSIX::strftime('%Y-%m-%d %H:%M', localtime($epoch));
    my $notice;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Settings::string = sub {
            my $key = shift;
            return $key eq 'PLUGIN_SPOTON_SOLOIST_HEALTH_RESTARTED' ? '%s|%s|%s' : $key;
        };
        $notice = Plugins::SpotOn::Settings::_formatHealthNotice($mac);
    }
    my @fields = split /\|/, $notice;
    is($fields[2], $expected, "84.1-08 WR-06: _formatHealthNotice renders a date and a clock time");

    %Plugins::SpotOn::Unified::DaemonManager::fake_health = ();
}

# --- 84.1-08 WR-03 notice (D-04): a ws_unreachable reason selects its
# own reason key, not the NO_LOGIN fallback every non-no_answer reason
# used to get ---
{
    my $mac = 'aa:84:08:09:00:02';
    $Plugins::SpotOn::Unified::DaemonManager::fake_health{$mac} =
        { last_reason => 'ws_unreachable', last_at => time() };

    my $notice;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Settings::string = sub {
            my $key = shift;
            return $key eq 'PLUGIN_SPOTON_SOLOIST_HEALTH_RESTARTED' ? '%s|%s|%s' : $key;
        };
        $notice = Plugins::SpotOn::Settings::_formatHealthNotice($mac);
    }
    my @fields = split /\|/, $notice;
    is($fields[1], 'PLUGIN_SPOTON_SOLOIST_HEALTH_REASON_WS_UNREACHABLE',
        "84.1-08 WR-03 notice: ws_unreachable maps to its own reason key");

    %Plugins::SpotOn::Unified::DaemonManager::fake_health = ();
}
# ============================================================
# 84-13 Task 1 (SEAM-6.2): availableBackends is Backend::available() --
# 84-09: the two cells over BOTH roles (per-file mocks here, so they hold in
# every amputated run); the key-block cells are in t/soloist/ and
# t/librespot/09_settings_*.t.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::Backend;
    my $params;
    # --- availableBackends template param ---
    $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is_deeply($params->{availableBackends}, [ Plugins::SpotOn::Backend::available() ],
        '84-13: availableBackends = Backend::available() on the full tree');
    is_deeply($params->{availableBackends}, [ 'librespot', 'soloist' ], '84-13: both backends offered on the full tree');
}

# ============================================================
# 85-10 Task 1 (D-05, D-21, T-85-13): playerauth/start is account-less. The
# handler reads no accountId, calls startPairing() with no argument, answers
# {status, deviceName, windowSeconds}, and a request without the CSRF header
# is refused before any pairing starts.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::API::Credentials;
    require Slim::Web::HTTP;
    require JSON::PP;
    my $serverPrefs = Slim::Utils::Prefs::preferences('server');

    my $nextStart;
    my $run = sub {
        my (%hdr) = @_;
        Plugins::SpotOn::API::Credentials::reset_calls();
        $Plugins::SpotOn::API::Credentials::next_start_pairing = $nextStart if $nextStart;
        @Slim::Web::HTTP::http_responses = ();
        my $response = FakeSettingsResponse->new(request => FakeSettingsRequest->new(headers => {%hdr}));
        Plugins::SpotOn::Settings::_playerAuthStartHandler('http_client_pa', $response);
        my $payload = eval { JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] }) } || {};
        return ($response, $payload);
    };

    $serverPrefs->set('csrfProtectionLevel', 1);

    my ($resp, $payload) = $run->('X-Requested-With' => 'XMLHttpRequest');
    is_deeply([ @{ $payload }{qw(status deviceName windowSeconds)} ], [ 'ok', 'SpotOn Authorization (Test)', 300 ],
        '85-10: playerauth/start with a valid CSRF header answers {ok, deviceName, windowSeconds=300}');
    ok(scalar(@Plugins::SpotOn::API::Credentials::start_pairing_calls) == 1
        && !defined $Plugins::SpotOn::API::Credentials::start_pairing_calls[0],
        '85-10: playerauth/start calls startPairing() without an account argument');

    ($resp, $payload) = $run->();
    is($resp->code, 403, '85-10: playerauth/start without the CSRF header is refused (403)');
    is(scalar(@Plugins::SpotOn::API::Credentials::start_pairing_calls), 0,
        '85-10: a refused playerauth/start never reaches startPairing');

    $serverPrefs->set('csrfProtectionLevel', 0);
    $nextStart = [0, 'just_paired'];
    ($resp, $payload) = $run->();
    $nextStart = undef;
    is_deeply([ @{ $payload }{qw(status reason)} ], [ 'error', 'just_paired' ],
        '85-10: a refusal reason from startPairing is passed through symbolically');
}

# ============================================================
# 85-11 Task 1 (D-24, D-21, D-02): template params of the two-step setup
# block. pairingWindowSeconds comes from Credentials, accountStepOk from
# TokenManager->hasValidLogin over all accounts, needsPairingAccounts from the
# accounts' needsPairing flag (set by the 85-10 migration), playerStepOk is 1
# on the librespot backend (the account pairing covers playback).
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::API::TokenManager;
    my $prefs          = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $accountsBefore = $prefs->get('accounts');
    my $activeBefore   = $prefs->get('activeAccount');
    my $backendBefore  = $prefs->get('backend');
    $prefs->set('backend', 'librespot');
    $prefs->set('accounts', {
        aaaa1111 => { displayName => 'Alice', spotifyUserId => 'alice' },
        bbbb2222 => { displayName => 'Bob',   spotifyUserId => 'bob', needsPairing => 1 },
    });
    $prefs->set('activeAccount', 'aaaa1111');

    {
        local %Plugins::SpotOn::API::TokenManager::valid_login = ();
        my $params = {};
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        is($params->{pairingWindowSeconds}, 300,
            '85-11: pairingWindowSeconds is the Credentials pairing window (300)');
        is($params->{accountStepOk}, 0,
            '85-11: accountStepOk is 0 while no account has a valid login');
        is_deeply($params->{needsPairingAccounts}, [ 'bbbb2222' ],
            '85-11: needsPairingAccounts lists exactly the flagged accounts');
        is($params->{playerStepOk}, 1,
            '85-11: playerStepOk is 1 on the librespot backend (step 2 not needed)');
    }
    {
        local %Plugins::SpotOn::API::TokenManager::valid_login = ( bbbb2222 => 1 );
        my $params = {};
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        is($params->{accountStepOk}, 1,
            '85-11: accountStepOk is 1 as soon as ANY account has a valid login');
    }

    $prefs->set('accounts', $accountsBefore || {});
    $prefs->set('activeAccount', $activeBefore // '');
    $prefs->set('backend', $backendBefore);
}

# ============================================================
# 79-39 Task 3 (D-32 F2): pairedAccounts is the sorted list of account ids
# whose login chain is usable (TokenManager->hasValidLogin), and accountStepOk
# is 1 exactly when that list is not empty. Step 1 of the setup block shows
# "Gekoppelt: <names>" from it instead of repeating the call to action.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::API::TokenManager;
    my $prefs          = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $accountsBefore = $prefs->get('accounts');
    my $activeBefore   = $prefs->get('activeAccount');
    my $backendBefore  = $prefs->get('backend');
    $prefs->set('backend', 'librespot');
    $prefs->set('accounts', {
        cccc3333 => { displayName => 'Carol', spotifyUserId => 'carol' },
        aaaa1111 => { displayName => 'Alice', spotifyUserId => 'alice' },
        bbbb2222 => { displayName => 'Bob',   spotifyUserId => 'bob' },
    });
    $prefs->set('activeAccount', 'aaaa1111');

    my @cases = (
        [ {},                                         [],                       0, 'no valid login' ],
        [ { bbbb2222 => 1 },                          [ 'bbbb2222' ],           1, 'one valid login' ],
        [ { cccc3333 => 1, aaaa1111 => 1 },           [ 'aaaa1111', 'cccc3333' ], 1, 'two valid logins, sorted' ],
        [ { cccc3333 => 1, aaaa1111 => 1, bbbb2222 => 1 }, [ 'aaaa1111', 'bbbb2222', 'cccc3333' ], 1, 'all valid' ],
    );
    for my $c (@cases) {
        my ($valid, $want, $stepOk, $label) = @$c;
        local %Plugins::SpotOn::API::TokenManager::valid_login = %$valid;
        my $params = {};
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        is_deeply($params->{pairedAccounts}, $want,
            "79-39: pairedAccounts is the sorted list of accounts with a valid login ($label)");
        is($params->{accountStepOk}, $stepOk,
            "79-39: accountStepOk is $stepOk exactly when pairedAccounts is " . ($stepOk ? 'not empty' : 'empty') . " ($label)");
    }

    $prefs->set('accounts', $accountsBefore || {});
    $prefs->set('activeAccount', $activeBefore // '');
    $prefs->set('backend', $backendBefore);
}

# ============================================================
# 85-11 Task 1 (D-24, D-21, D-01 UI half, T-85-22): the settings template.
# The PKCE / Client-ID / Keymaster-fallback UI is gone, the pairing button
# sits OUTSIDE the librespot-fields block (both backends see it), the page
# returns by GET navigation, and every string key the new block renders is
# defined.
# ============================================================
{
    my $html_file = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
    open(my $fh, '<:encoding(UTF-8)', $html_file) or die "Cannot open basic.html: $!";
    my $html = do { local $/; <$fh> };
    close($fh);
    open(my $sfh, '<:encoding(UTF-8)', "$project_dir/Plugins/SpotOn/strings.txt") or die $!;
    my $strings = do { local $/; <$sfh> };
    close($sfh);

    for my $gone (qw(pkceConnectBtn pref_clientId playerAuthBrowserStartBtn spotonPkceStart
                     spotonPkceManual needsPkceReauth needsMigration spotonPlayerAuthBrowser)) {
        ok($html !~ /\Q$gone\E/, "85-11: basic.html no longer contains '$gone'");
    }
    ok($html !~ /window\.location\.reload\(\)/, '85-11: basic.html never calls window.location.reload()');
    ok($html =~ /window\.location\.href = window\.location\.pathname/,
        '85-11: success returns by GET navigation (3fd1632 layer 1)');

    my $btn  = index($html, 'id="accountPairStartBtn"');
    my $lib  = index($html, 'id="librespot-fields"');
    ok($btn >= 0 && $lib >= 0 && $btn < $lib,
        '85-11: accountPairStartBtn sits before (outside) the librespot-fields block');
    my $open = () = substr($html, 0, $btn) =~ /<div id="librespot-fields"/g;
    ok($open == 0, '85-11: no librespot-fields div is open at the pairing button');
    ok($html =~ /id="account-pair-countdown"/, '85-11: the countdown element is on the page');

    my %seen;
    $seen{$_}++ for $html =~ /'(PLUGIN_SPOTON_(?:STEP_[A-Z_]+|ACCOUNT_PAIR_[A-Z_]+|ACCOUNT_NEEDS_PAIRING|DISCOVER_[A-Z_]+))'/g;
    ok(keys(%seen) >= 9, '85-11: the page renders at least 9 of the new keys (got ' . scalar(keys %seen) . ')');
    for my $k (sort keys %seen) {
        ok($strings =~ /^\Q$k\E$/m, "85-11: $k is defined in strings.txt");
    }

    ok($html =~ /accounts\.\$id\.displayName \| html/, '85-11: the account display name is HTML-escaped (T-85-22)');
    ok($html !~ /accounts\.\$id\.displayName(?! \| html)/, '85-11: no account display name is rendered unescaped');
}

# ============================================================
# 85-11 Task 2 (D-23): the settings handler takes the discover-folder intake
# on every page load and hands its verdict to the template as discoverResult
# (imported) / discoverError (refused). (0, 'none') -- nothing dropped -- is
# silent. The intake runs even for a saveSettings request (3fd1632 layer 2).
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::API::Credentials;

    Plugins::SpotOn::API::Credentials::reset_calls();
    my $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($Plugins::SpotOn::API::Credentials::intake_calls, 1, '85-11: the handler calls intakeDiscoverFolder once per page load');
    is_deeply([ @{$params}{qw(discoverResult discoverError)} ], [ 0, '' ],
        '85-11: nothing dropped -> no notice (discoverResult 0, discoverError empty)');

    Plugins::SpotOn::API::Credentials::reset_calls();
    $Plugins::SpotOn::API::Credentials::next_intake = [ 1, 'abcd1234' ];
    $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is_deeply([ @{$params}{qw(discoverResult discoverError)} ], [ 1, '' ],
        '85-11: an imported file -> discoverResult 1');

    Plugins::SpotOn::API::Credentials::reset_calls();
    $Plugins::SpotOn::API::Credentials::next_intake = [ 0, 'invalid_credentials' ];
    $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is_deeply([ @{$params}{qw(discoverResult discoverError)} ], [ 0, 'invalid_credentials' ],
        '85-11: a refused file -> discoverError carries the symbolic reason');

    Plugins::SpotOn::API::Credentials::reset_calls();
    $params = { saveSettings => 1 };
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($Plugins::SpotOn::API::Credentials::intake_calls, 1, '85-11: the intake also runs for a saveSettings request');
}

# ============================================================
# 74b-04 Task 1 (T-74b-12): saving the basic settings page must not blank
# binary / normalization / bitrate, and a tampered bitrate never reaches the
# prefs. The shared Slim::Web::Settings stub has an empty handler, so these
# cells override it locally with a faithful mimic of the LMS base handler
# (/usr/share/perl5/Slim/Web/Settings.pm:150-171): for every name returned by
# the class's prefs(), on saveSettings it stores pref_NAME unconditionally.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    my $p = Slim::Utils::Prefs::preferences('plugin.spoton');

    no warnings 'redefine';
    local *Slim::Web::Settings::handler = sub {
        my ($class, $client, $paramRef) = @_;
        my ($prefsClass, @names) = $class->prefs($client);
        for my $name (@names) {
            $prefsClass->set($name, $paramRef->{'pref_' . $name}) if $paramRef->{saveSettings};
            $paramRef->{prefs}{'pref_' . $name} = $prefsClass->get($name);
        }
        return;
    };

    my @names = Plugins::SpotOn::Settings->prefs();
    is_deeply([ @names[1 .. $#names] ], [ 'bitrate', 'normalization', 'diagnosticMode' ],
        '74b-04: prefs() lists bitrate, normalization, diagnosticMode and no binary');

    $p->set('binary', '/opt/test/spoton');
    $p->set('bitrate', 160);
    $p->set('normalization', 1);
    Plugins::SpotOn::Settings->handler(undef,
        { saveSettings => 1, pref_bitrate => 160, pref_normalization => 1 }, sub { }, undef, undef);
    is($p->get('binary'), '/opt/test/spoton', '74b-04: a save keeps the custom binary path');
    is($p->get('bitrate'), 160, '74b-04: a save with pref_bitrate 160 keeps bitrate 160');
    is($p->get('normalization'), 1, '74b-04: a save with the box checked keeps normalization 1');

    $p->set('binary', '/opt/test/spoton');
    $p->set('bitrate', 160);
    $p->set('normalization', 1);
    Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1 }, sub { }, undef, undef);
    is($p->get('binary'), '/opt/test/spoton', '74b-04: a POST without the librespot fields keeps the binary path');
    is($p->get('bitrate'), 160, '74b-04: a POST without pref_bitrate keeps the stored bitrate (not 320)');
    is($p->get('normalization'), 0, '74b-04: an unchecked normalization box stores 0 (checkbox semantics)');

    $p->set('bitrate', 160);
    Plugins::SpotOn::Settings->handler(undef,
        { saveSettings => 1, pref_bitrate => '999; rm -rf' }, sub { }, undef, undef);
    is($p->get('bitrate'), 320, '74b-04: a tampered pref_bitrate is stored as 320, never the raw string');

    my $params = { saveSettings => 1, pref_bitrate => 96, pref_normalization => 'on' };
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($p->get('bitrate'), 96, '74b-04: a valid bitrate 96 is stored');
    is($params->{pref_bitrate}, 96, '74b-04: the sanitized bitrate is written back into pref_bitrate');
    is($params->{pref_normalization}, 1, '74b-04: the sanitized 0/1 is written back into pref_normalization');
}


# ============================================================
# 74b-04 Task 2: clear logs and the shown log size include the Soloist logs.
# A live Soloist log is truncated, never unlinked (the running daemon keeps its
# append-mode file handle; an unlinked file would swallow its output).
# ============================================================
{
    require Plugins::SpotOn::Settings;
    my $spotonDir = File::Spec->catdir(Slim::Utils::Prefs::preferences('server')->get('cachedir'), 'spoton');
    make_path($spotonDir);
    for my $old (glob("$spotonDir/*-connect.log"), glob("$spotonDir/*-unified.log"), glob("$spotonDir/*-soloist.log*")) {
        unlink $old;
    }
    my $write = sub { my ($f, $n) = @_; open(my $fh, '>', $f) or die "$f: $!"; print $fh 'x' x $n; close($fh); };

    # connectLogSize counts the soloist files (3000 + 2000 = 5000 B -> 4.9 KB)
    $write->("$spotonDir/74b4-soloist.log", 3000);
    $write->("$spotonDir/74b4-soloist.log.1", 2000);
    my $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($params->{connectLogSize}, '4.9 KB', '74b-04: connectLogSize counts *-soloist.log and *-soloist.log.1');

    # clearLogs: soloist live log truncated to 0, .1 removed, count covers all
    $write->("$spotonDir/74b4-connect.log", 10);
    $write->("$spotonDir/74b4-unified.log", 10);
    $write->("$spotonDir/74b4-soloist.log.1.tmp", 10);    # 74b WR-02: leftover of a failed tail copy
    @Slim::Web::HTTP::http_responses = ();
    my $res = FakeSettingsResponse->new();
    Plugins::SpotOn::Settings::_clearLogsHandler(undef, $res);
    my $payload = eval { JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] }) } || {};
    ok(-e "$spotonDir/74b4-soloist.log" && -z "$spotonDir/74b4-soloist.log",
        '74b-04: clearLogs truncates the live soloist log to size 0 (never unlinks it)');
    ok(!-e "$spotonDir/74b4-soloist.log.1", '74b-04: clearLogs removes the soloist .1 generation');
    ok(!-e "$spotonDir/74b4-connect.log" && !-e "$spotonDir/74b4-unified.log",
        '74b-04: clearLogs still removes connect and unified logs');
    ok(!-e "$spotonDir/74b4-soloist.log.1.tmp", '74b WR-02: clearLogs removes a leftover soloist .1.tmp');
    is($payload->{deleted}, 5, '74b-04: the deleted count covers soloist, soloist.1, soloist.1.tmp, connect and unified');
}

# ============================================================
# 74b-03 Task 3 (D-07): the diagnostic bundle at the Soloist state - backend,
# Soloist version and expiry, stored stream quality, glibc, per-player
# effective format and path; the Soloist logs are included; every log tail
# and the server.log extract are redacted (T-74b-07); access stays 403
# without diagnosticMode (T-74b-10).
# ============================================================
{
    package FakeBundleClient;
    sub new  { my ($c, %a) = @_; return bless {%a}, $c }
    sub name  { $_[0]{name} }
    sub id    { $_[0]{id} }
    sub model { $_[0]{model} // 'squeezelite' }
}

{
    require Plugins::SpotOn::Settings;
    my $p     = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $srv   = Slim::Utils::Prefs::preferences('server');
    # The bundle header reads the LMS version and the plugin version.
    no warnings 'redefine';
    local $main::VERSION = '9.1.1-test';
    local *Plugins::SpotOn::Plugin::_pluginDataFor = sub { '9.9.9-test' };
    my $spotonDir = File::Spec->catdir($srv->get('cachedir'), 'spoton');
    make_path($spotonDir);
    for my $old (glob("$spotonDir/*-connect.log"), glob("$spotonDir/*-unified.log"), glob("$spotonDir/*-soloist.log*")) {
        unlink $old;
    }
    my $write = sub { my ($f, $text) = @_; open(my $fh, '>', $f) or die "$f: $!"; print $fh $text; close($fh); };

    # Fixture logs. The secrets are obviously fake marker values.
    $write->("$spotonDir/0200005a1101-soloist.log",
        "boot\n74b-marker-line\nauth spak_SEEDED74bSECRET end\nAuthorization: Bearer abc.DEF-123\nauth_data=SEEDEDAUTHDATA74b tail\n");
    $write->("$spotonDir/0200005a1101-soloist.log.1", "74b-gen1-marker-line\n");
    $write->("$spotonDir/0200005a1102-unified.log", "unified line spak_UNIFIEDSECRET74b here\n");
    my $logdir = tempdir(CLEANUP => 1);
    $write->("$logdir/server.log", "[x] SpotOn: token spak_SERVERLOGSECRET74b seen\nunrelated line\n");
    $srv->set('logdir', $logdir);

    Slim::Player::Client::set_mock_clients(FakeBundleClient->new(name => 'Kitchen', id => '02:00:00:5a:11:01'));

    my $bundle = sub {
        @Slim::Web::HTTP::http_responses = ();
        my $res = FakeSettingsResponse->new();
        Plugins::SpotOn::Settings::_diagnosticBundleHandler(undef, $res);
        my $ref = $Slim::Web::HTTP::http_responses[0][2];
        return ($res, $ref ? $$ref : '');
    };

    # --- backend soloist -------------------------------------------------
    $p->set('diagnosticMode', 1);
    $p->set('backend', 'soloist');
    $p->set('soloistQuality', 4);
    %Plugins::SpotOn::Backend::Soloist::SETTINGS_INFO = (
        soloistVersion => '1.3.8.68', soloistMissing => 0, soloistExpiryDays => 41,
        soloistExpiryText => 'expires in 41 days', soloistExpired => 0,
    );
    $Plugins::SpotOn::Backend::Soloist::KEY_PRESENT = 1;
    $Plugins::SpotOn::Backend::Soloist::EFFECTIVE_LABEL = 'High (320 kbit/s)';
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = '2.36';
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc_problem = 'Soloist cannot run on this system: glibc 2.36 found';
    $Plugins::SpotOn::Unified::DaemonManager::fake_output = { chosen => 'flac', resolved => 'flac', effective => 'flac', type => 'sof', path => 'proxy', reason => '' };

    my ($res, $body) = $bundle->();
    is($res->code, 200, '74b-03 D-07: the bundle answers 200 with diagnosticMode on');
    like($body, qr/^Backend: soloist$/m, '74b-03 D-07: header names the backend');
    like($body, qr/Soloist version: 1\.3\.8\.68/, '74b-03 D-07: header names the Soloist version');
    like($body, qr/Soloist expiry: expires in 41 days/, '74b-03 D-07: header names the Soloist expiry');
    like($body, qr/Soloist key: present/, '74b-03 D-07: header names the key state, never the key');
    like($body, qr/Spotify quality \(stored\): 4/, '74b-03 D-07: header names the stored stream quality');
    like($body, qr/^glibc: 2\.36$/m, '74b-03 D-07: header names the glibc version');
    like($body, qr/glibc check: Soloist cannot run on this system/, '74b-03 D-07: header carries the glibc problem message');
    like($body, qr/Kitchen \| 02:00:00:5a:11:01 \|.*chosen=flac.*effective=flac.*type=sof.*path=proxy/, '74b-03 D-07: the player line carries chosen/effective/type/path');
    like($body, qr/quality=High \(320 kbit\/s\)/, '74b-03 D-07: the player line carries the effective quality label under soloist');
    unlike($body, qr/reason=/, '74b-03 D-07: no reason= when none is set');
    unlike($body, qr/Bitrate:/, '74b-03 D-07: no Bitrate line under soloist');
    unlike($body, qr/Normalization:/, '74b-03 D-07: no Normalization line under soloist');
    like($body, qr/--- Log: 0200005a1101-soloist\.log ---/, '74b-03 D-07: the live Soloist log is included');
    like($body, qr/74b-marker-line/, '74b-03 D-07: the Soloist log tail is in the bundle');
    unlike($body, qr/74b-gen1-marker-line/, '74b-03 D-07: the .1 generation stays out of the bundle');
    like($body, qr/\[REDACTED\]/, '74b-03 T-74b-07: redaction marks are present');
    unlike($body, qr/spak_SEEDED74bSECRET/, '74b-03 T-74b-07: the seeded spak_ token is not in the bundle');
    unlike($body, qr/abc\.DEF-123/, '74b-03 T-74b-07: the Bearer token is not in the bundle');
    unlike($body, qr/SEEDEDAUTHDATA74b/, '74b-03 T-74b-07: the auth_data value is not in the bundle');
    unlike($body, qr/spak_UNIFIEDSECRET74b/, '74b-03 T-74b-07: a token in a unified log is redacted too');
    unlike($body, qr/spak_SERVERLOGSECRET74b/, '74b-03 T-74b-07: a token in the server.log extract is redacted');
    like($body, qr/SpotOn: token \[REDACTED\] seen/, '74b-03 T-74b-07: the server.log line survives with the token replaced');

    # reason and ok message
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = '2.43';
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc_problem = undef;
    $Plugins::SpotOn::Unified::DaemonManager::fake_output = { chosen => 'flac', resolved => 'pcm', effective => 'pcm', type => 'soc', path => 'proxy', reason => 'flac_no_flc' };
    (undef, $body) = $bundle->();
    like($body, qr/glibc check: ok/, '74b-03 D-07: glibc check reads ok on a fine system');
    like($body, qr/chosen=flac effective=pcm.*reason=flac_no_flc/, '74b-03 D-07: the reason is appended when set');

    # --- backend librespot -----------------------------------------------
    $p->set('backend', 'librespot');
    (undef, $body) = $bundle->();
    like($body, qr/^Backend: librespot$/m, '74b-03 D-07: header names the librespot backend');
    like($body, qr/Bitrate:/, '74b-03 D-07: Bitrate appears under librespot');
    like($body, qr/Normalization:/, '74b-03 D-07: Normalization appears under librespot');
    unlike($body, qr/Soloist version:|Soloist expiry:|Soloist key:|Spotify quality \(stored\):/, '74b-03 D-07: no Soloist-only header lines under librespot');
    unlike($body, qr/quality=/, '74b-03 D-07: no per-player quality under librespot');

    # --- 79-24 RF-74b-IN-03: the glibc check line says what was checked ----
    # librespot backend (also every platform without Soloist): glibc is detected
    # and there is no problem message, but the Soloist glibc check did not apply.
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = '2.43';
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc_problem = undef;
    $p->set('backend', 'librespot');
    (undef, $body) = $bundle->();
    like($body, qr/^glibc check: not applicable \(backend librespot\)$/m, '79-24 IN-03: librespot backend reads "not applicable (backend librespot)"');
    unlike($body, qr/glibc check: ok/, '79-24 IN-03: librespot backend never reads "glibc check: ok"');

    # soloist backend, glibc not detectable: the check could not run.
    $p->set('backend', 'soloist');
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = undef;
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc_problem = undef;
    (undef, $body) = $bundle->();
    like($body, qr/^glibc check: not run \(glibc not detected\)$/m, '79-24 IN-03: soloist with undetectable glibc reads "not run (glibc not detected)"');
    unlike($body, qr/glibc check: ok/, '79-24 IN-03: soloist with undetectable glibc never reads "glibc check: ok"');

    # soloist backend, glibc fine / glibc problem: the two existing 74b-03 cells
    # stay the oracle; these two pin the same branches under the 79-24 prefix.
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = '2.43';
    (undef, $body) = $bundle->();
    like($body, qr/^glibc check: ok$/m, '79-24 IN-03: soloist with a fine glibc still reads "ok"');
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = '2.36';
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc_problem = 'Soloist cannot run on this system: glibc 2.36 found';
    (undef, $body) = $bundle->();
    like($body, qr/^glibc check: Soloist cannot run on this system: glibc 2\.36 found$/m, '79-24 IN-03: soloist with a problem keeps its message');

    # restore what the access cells below expect
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = '2.43';
    $Plugins::SpotOn::Unified::DaemonManager::fake_glibc_problem = undef;
    $p->set('backend', 'librespot');

    # --- access ------------------------------------------------------------
    $p->set('diagnosticMode', 0);
    ($res, $body) = $bundle->();
    is($res->code, 403, '74b-03 T-74b-10: the bundle stays 403 without diagnosticMode');
    unlike($body, qr/74b-marker-line|Backend:/, '74b-03 T-74b-10: a 403 carries no bundle content');

    # --- redaction primitive ---------------------------------------------------
    is(Plugins::SpotOn::Settings::_redactBundleText("a spak_ABC-def_1 b Bearer x.y-z c auth_data=QQ d"),
       "a [REDACTED] b [REDACTED] c [REDACTED] d", '74b-03 T-74b-07: _redactBundleText replaces all three token shapes');
    is(Plugins::SpotOn::Settings::_redactBundleText("plain text"), "plain text", '74b-03 T-74b-07: text without a secret is unchanged');

    # --- source pins -----------------------------------------------------------
    open(my $sfh, '<', "$project_dir/Plugins/SpotOn/Settings.pm") or die $!;
    my $ssrc = do { local $/; <$sfh> };
    close $sfh;
    like($ssrc, qr/spak_\[A-Za-z0-9_-\]\*\|auth_data\[\^ \]\*\|Bearer \[A-Za-z0-9\._-\]\+/, '74b-03 T-74b-07: the redaction pattern is the repo pattern of tools/uat/extract-run.pl');

    $srv->set('logdir', undef);
    Slim::Player::Client::set_mock_clients();
    $p->set('diagnosticMode', 0);
    $p->set('backend', 'librespot');
}


# ============================================================
# 79-43 (D-33 FULL-3 WR-01): the diagnostic bundle carries no Spotify username. Every stored spotifyUserId is
# redacted (raw, UTF-8 bytes and URI-escaped) over the whole bundle, header and log extracts; the display-name
# fallback shows the masked form. The spak_/auth_data/Bearer redaction is unchanged (B2).
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Encode;
    my $p   = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $srv = Slim::Utils::Prefs::preferences('server');
    no warnings 'redefine';
    local $main::VERSION = '9.1.1-test';
    local *Plugins::SpotOn::Plugin::_pluginDataFor = sub { '9.9.9-test' };
    my $spotonDir = File::Spec->catdir($srv->get('cachedir'), 'spoton');
    make_path($spotonDir);
    for my $old (glob("$spotonDir/*-connect.log"), glob("$spotonDir/*-unified.log"), glob("$spotonDir/*-soloist.log*")) {
        unlink $old;
    }
    my $write = sub { my ($f, $text) = @_; open(my $fh, '>', $f) or die "$f: $!"; print $fh $text; close($fh); };
    my $uid    = "j\x{fc}rgen.m";
    my $uidUtf = Encode::encode('UTF-8', $uid);           # how a log file holds it
    my $uidEsc = 'j%C3%BCrgen.m';                          # uri_escape_utf8, as in a spclient path
    $write->("$spotonDir/0200005a1143-soloist.log", "boot\n[soloist] authenticated as $uidUtf ok\nauth spak_B2SECRET43 end\n");
    my $logdir = tempdir(CLEANUP => 1);
    $write->("$logdir/server.log", "[x] SpotOn: SpClient: HTTP 503 error for user-profile-view/v3/profile/$uidEsc: 503\n[x] SpotOn: Bearer abc.B2-43 seen\n[x] SpotOn: rootlist for playlist/v2/user/other.user/rootlist\n");
    $srv->set('logdir', $logdir);
    Slim::Player::Client::set_mock_clients(FakeBundleClient->new(name => 'Kitchen', id => '02:00:00:5a:11:43'));
    my $accountsBefore = $p->get('accounts');
    my $activeBefore   = $p->get('activeAccount');
    $p->set('accounts', { b1430001 => { spotifyUserId => $uid }, b1430002 => { spotifyUserId => 'other.user', displayName => 'Other' } });
    $p->set('activeAccount', 'b1430001');
    $p->set('diagnosticMode', 1);
    $p->set('backend', 'librespot');

    @Slim::Web::HTTP::http_responses = ();
    my $res = FakeSettingsResponse->new();
    Plugins::SpotOn::Settings::_diagnosticBundleHandler(undef, $res);
    my $ref  = $Slim::Web::HTTP::http_responses[0][2];
    my $body = $ref ? $$ref : '';
    my $text = eval { Encode::decode('UTF-8', $body) } // '';

    is($res->code, 200, '79-43 B1: the bundle answers 200');
    my ($dn) = $text =~ /^  Display name: (.*)$/m;
    is($dn // 'no display name line', "j\x{fc}r****", '79-43 B1 (D-33 FULL-3 WR-01): the display-name fallback shows the masked form (first three characters plus ****)');
    unlike($text, qr/\Q$uid\E/, '79-43 B1: the raw spotifyUserId appears nowhere in the bundle');
    unlike($text, qr/\Q$uidUtf\E/, '79-43 B1: its UTF-8 byte form (as a log file holds it) appears nowhere');
    unlike($body, qr/\Q$uidUtf\E/, '79-43 B1: ... not even in the encoded body');
    unlike($text, qr/\Q$uidEsc\E/i, '79-43 B1: its URI-escaped form appears nowhere');
    unlike($text, qr/other\.user/, '79-43 B1: a second stored account id is redacted too');
    like($text, qr/authenticated as \[REDACTED\] ok/, '79-43 B1: the daemon log line survives with the user replaced');
    like($text, qr{profile/\[REDACTED\]: 503}, '79-43 B1: the server.log line survives with the escaped user replaced');
    unlike($text, qr/spak_B2SECRET43|abc\.B2-43/, '79-43 B2: the spak_ and Bearer redaction is unchanged');

    $p->set('accounts', $accountsBefore);
    $p->set('activeAccount', $activeBefore);
    $srv->set('logdir', undef);
    Slim::Player::Client::set_mock_clients();
    $p->set('diagnosticMode', 0);
    unlink "$spotonDir/0200005a1143-soloist.log";
}

# ============================================================
# 79-44 (D-33 review WR-04): the bundle redaction replaces the user id as a TOKEN, not as a substring anywhere. A short
# id ("max") used to eat HOLD_MAX_S, Maxwell and maximum (substring, case-insensitive) and garble the user's one support
# artifact. The id still disappears where it stands alone (also after a slash, in a log line, in its URI-escaped form in
# either hex case), and the other accounts' ids stay redacted.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Encode;
    my $p   = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $srv = Slim::Utils::Prefs::preferences('server');
    no warnings 'redefine';
    local $main::VERSION = '9.1.1-test';
    local *Plugins::SpotOn::Plugin::_pluginDataFor = sub { '9.9.9-test' };
    my $spotonDir = File::Spec->catdir($srv->get('cachedir'), 'spoton');
    make_path($spotonDir);
    for my $old (glob("$spotonDir/*-connect.log"), glob("$spotonDir/*-unified.log"), glob("$spotonDir/*-soloist.log*")) {
        unlink $old;
    }
    my $write = sub { my ($f, $text) = @_; open(my $fh, '>', $f) or die "$f: $!"; print $fh $text; close($fh); };
    my $uid    = 'max';
    my $uid2   = "j\x{fc}rgen.m";
    my $uid2Lo = 'j%c3%bcrgen.m';                          # the same escape in lower-case hex
    $write->("$spotonDir/0200005a1144-soloist.log", "boot\nHOLD_MAX_S=180 Maxwell maximum smax max_ready\n[soloist] authenticated as max ok\nuser/max/playlists\n");
    my $logdir = tempdir(CLEANUP => 1);
    $write->("$logdir/server.log", "[x] SpotOn: SpClient: HTTP 503 error for profile/$uid2Lo: 503\n[x] SpotOn: Thomas Maximilian HOLD_MAX_S Max end\n");
    $srv->set('logdir', $logdir);
    Slim::Player::Client::set_mock_clients(FakeBundleClient->new(name => 'Kitchen', id => '02:00:00:5a:11:44'));
    my $accountsBefore = $p->get('accounts');
    my $activeBefore   = $p->get('activeAccount');
    $p->set('accounts', { b1440001 => { spotifyUserId => $uid }, b1440002 => { spotifyUserId => $uid2 } });
    $p->set('activeAccount', 'b1440001');
    $p->set('diagnosticMode', 1);
    $p->set('backend', 'librespot');

    @Slim::Web::HTTP::http_responses = ();
    my $res = FakeSettingsResponse->new();
    Plugins::SpotOn::Settings::_diagnosticBundleHandler(undef, $res);
    my $ref  = $Slim::Web::HTTP::http_responses[0][2];
    my $body = $ref ? $$ref : '';
    my $text = eval { Encode::decode('UTF-8', $body) } // '';

    is($res->code, 200, '79-44 WR-04: the bundle answers 200');
    like($text, qr/HOLD_MAX_S=180 Maxwell maximum smax max_ready/, '79-44 WR-04: a short id does not garble words that merely contain it (HOLD_MAX_S, Maxwell, maximum, smax, max_ready)');
    like($text, qr/Thomas Maximilian HOLD_MAX_S Max end/, '79-44 WR-04: ... nor the server.log extract, and the id is case-sensitive (a capital "Max" is not the id "max")');
    like($text, qr/authenticated as \[REDACTED\] ok/, '79-44 WR-04: the id standing alone in a log line is still redacted');
    like($text, qr{user/\[REDACTED\]/playlists}, '79-44 WR-04: ... and after a slash in a path');
    like($text, qr{profile/\[REDACTED\]: 503}, '79-44 WR-04: the lower-case hex URI escape of the other account is still redacted');
    unlike($text, qr/\bmax\b/, '79-44 WR-04: the bare id appears nowhere as a token');

    $p->set('accounts', $accountsBefore);
    $p->set('activeAccount', $activeBefore);
    $srv->set('logdir', undef);
    Slim::Player::Client::set_mock_clients();
    $p->set('diagnosticMode', 0);
    unlink "$spotonDir/0200005a1144-soloist.log";
}

done_testing();
