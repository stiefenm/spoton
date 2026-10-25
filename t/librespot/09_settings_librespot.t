#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: librespot half of t/09_settings.t -- the cells
# that need the REAL Backend::Librespot: the D-17 librespot quality cells, the
# backend=librespot key block over an amputated Soloist side, the 84-08
# amputation render)
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

# Stub: Slim::Web::HTTP (for addHTTPResponse in the diagnostic bundle / JSON handlers; the PKCE result page is gone, 85-13)
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
sub PAIRING_WINDOW_SECONDS { return 300 }   # 85-11 (D-21): Settings.pm pairingWindowSeconds
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
unshift @INC, $stub_dir, $project_dir;

# Phase 71: pre-load the OSDetect stub -- Soloist.pm calls
# Slim::Utils::OSDetect::details() fully-qualified without its own require,
# relying on it already being loaded (true in the real LMS runtime where
# many other modules require it first; not automatic in this stub harness).
require Slim::Utils::OSDetect;

# ============================================================
# Settings.pm structure tests
# ============================================================
my $settings_module = "$project_dir/Plugins/SpotOn/Settings.pm";

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
# 84-08 (SEAM-6.2, T-84-28): the Settings page renders with the Soloist
# backend ABSENT (the §6.3.2 amputation shape) -- the former unguarded
# `require Plugins::SpotOn::Soloist` (:552) is gone; every registered
# backend fills its own keys through settingsInfo, an absent one is skipped.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $backendBefore = $prefs->get('backend');
    $prefs->set('backend', 'librespot');

    # Amputation: every Soloist-side module fails to load from here on.
    my @gone = grep { m{^Plugins/SpotOn/(?:Soloist(?:\.pm|/)|Backend/Soloist\.pm|Unified/SoloistDaemon\.pm)} } keys %INC;
    my %saved = map { $_ => $INC{$_} } @gone;
    delete @INC{@gone};
    my $hook = sub {
        my (undef, $file) = @_;
        die "amputated: $file\n" if $file =~ m{^Plugins/SpotOn/(?:Soloist(?:\.pm|/)|Backend/Soloist\.pm|Unified/SoloistDaemon\.pm)};
        return;
    };
    unshift @INC, $hook;

    ok(!eval { require Plugins::SpotOn::Soloist; 1 }, '84-08 amputation: Plugins::SpotOn::Soloist cannot be loaded (precondition)');

    my $params = {};
    my $lived = eval {
        Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
        1;
    };
    ok($lived, '84-08 amputation: Settings handler renders with the Soloist module absent (no die)') or diag($@);
    is($params->{binaryPath}, '/usr/bin/false', "84-08 amputation: the librespot role's settingsInfo fills binaryPath");
    is($params->{backend}, 'librespot', '84-08 amputation: backend pre-selection still rendered');
    ok(!exists $params->{soloistVersion}, '84-08 amputation: no Soloist keys from an absent backend');

    @INC = grep { !(ref $_ && $_ == $hook) } @INC;
    @INC{keys %saved} = values %saved;
    $prefs->set('backend', $backendBefore);
}
# ============================================================
# 83.3-02 / 84-08 (D-17), librespot cells (84-09: split out of the global
# soloistQuality block, now in t/soloist/09_settings_soloist.t): under
# librespot the REAL role answers qualityInfo supported 0 -- a posted level
# is neither stored nor sent.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    no warnings 'redefine', 'once';
    my $apply_calls = 0;
    local *Plugins::SpotOn::Soloist::Quality::applyChange = sub { $apply_calls++; };
    my $backendBefore = $prefs->get('backend');

    # 84-08 (D-17): under librespot the role has no quality control
    # (qualityInfo supported 0) -- a posted level is neither stored nor sent.
    $prefs->set('backend', 'librespot');
    $prefs->set('soloistQuality', 3);
    $apply_calls = 0;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistQuality => 4 },
        sub { }, undef, undef
    );
    is($prefs->get('soloistQuality'), 3, '84-08 D-17: librespot -- a posted soloistQuality is not stored (role unsupported)');
    is($apply_calls, 0, '84-08 D-17: librespot -- no applyChange call');

    $prefs->set('backend', $backendBefore);
}


# ============================================================
# 84-13 Task 1 (SEAM-6.2, T-84-45, T-84-162), librespot cells (84-09: split
# out of the key block in t/soloist/09_settings_soloist.t): the key block and the backend
# save reach a backend only through the registry -- backendClass()->keyState/
# storeKey/clearKey, the save enum from Backend::available(), bootstrap only
# for an available name, basic.html's options from availableBackends.
# ============================================================
{
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::Backend;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $backendBefore = $prefs->get('backend');

    my $SOLOIST_RE = qr{^Plugins/SpotOn/(?:Soloist(?:\.pm|/)|Backend/Soloist\.pm|Unified/SoloistDaemon\.pm)};
    my $amputated = sub {    # runs $code with every Soloist-side module unloadable
        my ($code) = @_;
        my @gone  = grep { $_ =~ $SOLOIST_RE } keys %INC;
        my %saved = map { $_ => $INC{$_} } @gone;
        delete @INC{@gone};
        my $hook = sub { my (undef, $file) = @_; die "amputated: $file\n" if $file =~ $SOLOIST_RE; return; };
        unshift @INC, $hook;
        local %Plugins::SpotOn::Backend::UNAVAILABLE = ();
        my @r = eval { $code->() };
        my $err = $@;
        @INC = grep { !(ref $_ && $_ == $hook) } @INC;
        @INC{keys %saved} = values %saved;
        die $err if $err;
        return @r;
    };
    my @LOG;
    no warnings 'redefine', 'once';
    local *Slim::Utils::Log::info  = sub { push @LOG, $_[1] };
    local *Slim::Utils::Log::warn  = sub { push @LOG, $_[1] };
    local *Slim::Utils::Log::error = sub { push @LOG, $_[1] };
    local *Slim::Utils::Log::debug = sub { push @LOG, $_[1] };

    # 84-09: the raw key and the Soloist-role storeKey recorder of the (now
    # soloist-half) key-store cells -- kept so 'storeKey is never called' stays
    # observable here; the glob is set without loading any Soloist module.
    my $raw = 'zyxWVU987_-.zyxWVU987';
    my @store;
    local *Plugins::SpotOn::Backend::Soloist::storeKey = sub { push @store, $_[1]; return (1) };

    # --- backend=librespot: no key handling, no Soloist module loaded ---
    $prefs->set('backend', 'librespot');
    @store = ();
    my ($lived, $soloistLoaded) = $amputated->(sub {
        my $ok = eval {
            Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1, pref_soloistKey => $raw }, sub { }, undef, undef);
            1;
        };
        diag($@) unless $ok;
        return ($ok ? 1 : 0, (exists $INC{'Plugins/SpotOn/Soloist.pm'} ? 1 : 0));
    });
    ok($lived, '84-13: backend=librespot + amputated Soloist side: a key POST does not die');
    is($soloistLoaded, 0, '84-13: backend=librespot: the key block loads no Soloist module');
    is(scalar(@store), 0, '84-13: backend=librespot: the Soloist role storeKey is never called');

    # --- B3 (T-84-162): the save enum is available(), bootstrap only for an available name ---
    $Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls = 0;
    my ($saveLived) = $amputated->(sub {
        my $ok = eval {
            Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1, pref_backend => 'soloist' }, sub { }, undef, undef);
            1;
        };
        diag($@) unless $ok;
        return ($ok ? 1 : 0);
    });
    ok($saveLived, '84-13 B3: POST pref_backend=soloist with the Soloist role absent does not die');
    is($prefs->get('backend'), 'librespot', '84-13 B3: an unavailable backend name is saved as librespot');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 2,
        '84-13 B3: the save reaches the backend block scheduleInit (normalization + backend = 2)');

    my ($ampParams) = $amputated->(sub {
        my $p = {};
        Plugins::SpotOn::Settings->handler(undef, $p, sub { }, undef, undef);
        return $p;
    });
    is_deeply($ampParams->{availableBackends}, [ 'librespot' ], '84-13: only librespot offered with the Soloist side absent');

    # 79-05 (D-12, k8): the hint-key POST and a crafted switch POST over an
    # amputated Soloist side store nothing, do not die, backend stays librespot.
    @store = ();
    $prefs->set('backend', 'librespot');
    my ($hkLived, $hkSoloistLoaded, $hkParams) = $amputated->(sub {
        my $p = { saveSettings => 1, pref_backend => 'librespot', soloistHintKey => 'hintTok_ABCD-1234.efgh', switchBackendSoloist => 1 };
        my $ok = eval { Plugins::SpotOn::Settings->handler(undef, $p, sub { }, undef, undef); 1 };
        diag($@) unless $ok;
        return ($ok ? 1 : 0, (exists $INC{'Plugins/SpotOn/Soloist.pm'} ? 1 : 0), $p);
    });
    ok($hkLived, '79-05 k8: amputated Soloist side: a hint-key + switch POST does not die');
    is($hkSoloistLoaded, 0, '79-05 k8: ... and loads no Soloist module');
    is(scalar(@store), 0, '79-05 k8: ... the hint key is stored nowhere');
    is($prefs->get('backend'), 'librespot', '79-05 k8: ... the backend stays librespot');
    ok(!$hkParams->{soloistSwitchOffer}, '79-05 k8: ... no switch offer is rendered');
    ok(!$hkParams->{soloistHint}, '79-05 k8: ... no hint is rendered');
    ok(!exists $hkParams->{soloistHintKey}, '79-05 k8: ... the raw hint value does not stay in $paramRef');

    $prefs->set('backend', $backendBefore);
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

done_testing();
