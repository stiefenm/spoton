#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: soloist half of t/09_settings.t -- the cells over
# the REAL Soloist role / Soloist modules, incl. their Soloist-conditional SKIPs)
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
sub platformSupportsSoloist { return ($main::FAKE_ISWINDOWS || $main::FAKE_ISMAC || main::ISWINDOWS() || main::ISMAC()) ? 0 : 1; }
# 79-05 (D-12): the fit helper reads the ONE glibc floor comparison; this
# double mirrors the real rule over a test-controlled glibc version.
use constant SOLOIST_MIN_GLIBC => '2.38';
our $fake_glibc = '2.40';
sub glibcVersion { return $fake_glibc }
sub soloistGlibcOk {
    my $found = glibcVersion();
    return undef unless defined $found;
    my ($fMaj, $fMin) = split /\./, $found;
    my ($rMaj, $rMin) = split /\./, SOLOIST_MIN_GLIBC;
    return ($fMaj > $rMaj || ($fMaj == $rMaj && $fMin >= $rMin)) ? 1 : 0;
}
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
# 83.3-02 (D-12/D-13): Global soloistQuality handler save/validation --
# real handler-execution coverage of the global setting, mirroring the
# COMPAT-01 streamingMode block above. applyChange() is glob-overridden with
# a counter so this test never touches the network.
# ============================================================
SKIP: {
    skip "Settings.pm not yet updated with global soloistQuality handler", 7
        unless -f $settings_module && do {
            open(my $fh, '<', $settings_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /pref_soloistQuality/;
        };

    skip "Settings.pm and Quality.pm required for global soloistQuality test", 7
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist::Quality; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    no warnings 'redefine', 'once';
    my $apply_calls = 0;
    local *Plugins::SpotOn::Soloist::Quality::applyChange = sub { $apply_calls++; };

    # 84-08 (D-17): the save goes through the ACTIVE backend role
    # (backendClass()->qualityInfo / ->quality) -- the cells below run with
    # the backend that has the Spotify quality control selected.
    my $backendBefore = $prefs->get('backend');
    $prefs->set('backend', 'soloist');

    $prefs->set('soloistQuality', 0);
    $apply_calls = 0;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistQuality => 4 },
        sub { }, undef, undef
    );
    is($prefs->get('soloistQuality'), 4, '83.3-02: global soloistQuality handler persists valid value 4');
    is($apply_calls, 1, '83.3-02: global soloistQuality handler calls applyChange once on a real change');

    $apply_calls = 0;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistQuality => 'bogus' },
        sub { }, undef, undef
    );
    is($prefs->get('soloistQuality'), 0, '83.3-02: global soloistQuality handler falls back to 0 for an invalid value');
    is($apply_calls, 1, '83.3-02: falling back to 0 from 4 still counts as a change');

    $apply_calls = 0;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_soloistQuality => 0 },
        sub { }, undef, undef
    );
    is($apply_calls, 0, '83.3-02: posting the same value again does not call applyChange (change-detect)');

    $prefs->set('soloistQuality', 3);
    $apply_calls = 0;
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1 },
        sub { }, undef, undef
    );
    is($prefs->get('soloistQuality'), 3,
        '83.3-02: global soloistQuality handler leaves value untouched when pref_soloistQuality key absent');
    is($apply_calls, 0, '83.3-02: no applyChange call when the key is absent');

    # (84-09: the two librespot cells of this block -- a posted level is not
    # stored, no applyChange -- live in t/librespot/09_settings_librespot.t)
    $prefs->set('backend', $backendBefore);
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
    # 84-13 Task 1: the key block runs through the ACTIVE backend's role
    # (backendClass()->keyState/storeKey/clearKey) -- the key cells below
    # therefore run with backend=soloist (the cases above left librespot).
    $prefs->set('backend', 'soloist');
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
    $prefs->set('backend', 'librespot');
}

# ============================================================
# 84-13 Task 1 (SEAM-6.2, T-84-45, T-84-162): the key block and the backend
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

    # --- key store through the Soloist role (backend=soloist) ---
    $prefs->set('backend', 'soloist');
    my (@keyState, @store, @clear);
    my $present = 1;
    local *Plugins::SpotOn::Backend::Soloist::keyState = sub { push @keyState, 1; return { supported => 1, present => $present } };
    local *Plugins::SpotOn::Backend::Soloist::storeKey = sub { push @store, $_[1]; return (1) };
    local *Plugins::SpotOn::Backend::Soloist::clearKey = sub { push @clear, 1; return 1 };

    my $raw = 'zyxWVU987_-.zyxWVU987';
    @LOG = ();
    Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1, pref_soloistKey => $raw }, sub { }, undef, undef);
    is_deeply(\@store, [ $raw ], '84-13: POST pref_soloistKey calls the Soloist role storeKey with the raw value');
    ok(!(grep { defined $_ && index($_, 'zyxWVU987') >= 0 } @LOG), '84-13: the raw key never reaches the log (T-84-45)');
    ok(scalar(@keyState) >= 1, '84-13: the save path asks the role keyState (masked-resubmit guard)');

    @store = ();
    Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1, pref_soloistKey => Plugins::SpotOn::Settings::SOLOIST_KEY_MASKED_PREVIEW() }, sub { }, undef, undef);
    is(scalar(@store), 0, '84-13: the masked placeholder resubmit stores nothing (key present per keyState)');

    Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1, pref_soloistKey => '' }, sub { }, undef, undef);
    is(scalar(@clear), 1, '84-13: an empty submission with a key present calls the role clearKey');
    $present = 0; @clear = ();
    Plugins::SpotOn::Settings->handler(undef, { saveSettings => 1, pref_soloistKey => '' }, sub { }, undef, undef);
    is(scalar(@clear), 0, '84-13: an empty submission without a key does not call clearKey');

    # --- GET: the masked preview follows keyState->{present} ---
    $present = 1; @keyState = ();
    my $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($params->{soloistKeyMasked}, Plugins::SpotOn::Settings::SOLOIST_KEY_MASKED_PREVIEW(),
        '84-13: GET renders the masked preview when keyState->{present}');
    ok(scalar(@keyState) >= 1, '84-13: the GET render reads keyState (no direct Soloist hasKey)');
    $present = 0;
    $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($params->{soloistKeyMasked}, '', '84-13: GET renders no preview when keyState->{present} is 0');
    is($params->{soloistKeyMissing}, 1, '84-13: soloistKeyMissing follows keyState->{present}');

    # (84-09: the backend=librespot / amputated-Soloist cells of this block are in
    # t/librespot/09_settings_librespot.t; the two availableBackends cells over
    # both roles are in t/core/09_settings_core.t)
    $prefs->set('backend', $backendBefore);
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

SKIP: {
    skip "Settings.pm/Soloist.pm module required for the renew-route tests", 14
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; require Plugins::SpotOn::Backend::Soloist;
                      require Slim::Web::HTTP; require Slim::Web::Pages; require JSON::PP; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $backendBefore = $prefs->get('backend');
    # W7: registered for every AVAILABLE backend, whatever the pref says.
    $prefs->set('backend', 'librespot');

    my $RENEW  = 'plugins/SpotOn/settings/soloistRenew';
    my $STATUS = 'plugins/SpotOn/settings/soloistRenewStatus';

    Slim::Web::Pages::reset_calls();
    Plugins::SpotOn::Settings->new();
    my @registered = @Slim::Web::Pages::registered_raw;
    ok(scalar(@registered) > 0, '83.3-06: Settings->new() registers at least one raw route');
    # 85-13 (D-01, RESEARCH P10): the unanchored raw route `login` and the PKCE /
    # browser-fallback routes are gone from the registration order Settings->new() produces.
    ok(!defined resolve_raw_route(\@registered, 'login'), '85-13: raw route login not registered');
    ok(!(grep { $_->[0] =~ /pkce|browser/ } @registered), '85-13: no pkce/* or playerauth/browser/* raw route registered');
    my @renewRegs = grep { $_->[0] eq $RENEW || $_->[0] eq $STATUS } @registered;
    is_deeply([ map { $_->[0] } @renewRegs ], [ $STATUS, $RENEW ],
        '84-13: both renew routes registered with backend=librespot, status path FIRST (83.3 order lesson)');

    my $renew_handler  = resolve_raw_route(\@registered, $RENEW);
    my $status_handler = resolve_raw_route(\@registered, $STATUS);
    ok(ref $renew_handler eq 'CODE' && ref $status_handler eq 'CODE', '84-13: both paths resolve to a handler');
    isnt($renew_handler, $status_handler, '83.3-06: the two routes never resolve to the same handler');

    my (@fired, @renew_calls);
    no warnings 'redefine', 'once';
    my $origNow    = Plugins::SpotOn::Backend::Soloist->can('renewNow');
    my $origStatus = Plugins::SpotOn::Backend::Soloist->can('renewStatus');
    local *Plugins::SpotOn::Backend::Soloist::renewNow    = sub { push @fired, 'renewNow';    goto &$origNow };
    local *Plugins::SpotOn::Backend::Soloist::renewStatus = sub { push @fired, 'renewStatus'; goto &$origStatus };
    local *Plugins::SpotOn::Soloist::renewBinary = sub { my (%o) = @_; push @renew_calls, \%o; return 'started' };

    # renew (POST) with the XHR header
    @Slim::Web::HTTP::http_responses = ();
    my $xhr = FakeSettingsResponse->new(request => FakeSettingsRequest->new(headers => { 'X-Requested-With' => 'XMLHttpRequest' }));
    eval { $renew_handler->('http_client_renew', $xhr) };
    is_deeply(\@fired, [ 'renewNow' ], '84-13: the resolved soloistRenew route fires the role renewNow');
    is(scalar(@renew_calls), 1, '83.3-03: the renew route calls renewBinary exactly once');
    is(($renew_calls[0] || {})->{reason}, 'manual', '83.3-03: the renew route always passes reason => "manual"');
    my $payload = eval { JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] }) } || {};
    is($payload->{status}, 'started', '83.3-03: JSON response body carries {"status":"started"}');

    # status (GET), no header needed
    @fired = (); @Slim::Web::HTTP::http_responses = ();
    eval { $status_handler->('http_client_status', FakeSettingsResponse->new) };
    is_deeply(\@fired, [ 'renewStatus' ], '84-13: the resolved soloistRenewStatus route fires the role renewStatus');
    my $status = eval { JSON::PP::decode_json(${ $Slim::Web::HTTP::http_responses[0][2] }) } || {};
    is_deeply([ sort keys %$status ],
              [ sort qw(renewal generation active_version expiry_days pending_switches players placed manual_dir) ],
              '84-13: the status body carries the eight renewStatus keys');

    # amputation: only librespot available -> no renew route, nothing dies
    my $SOLOIST_RE = qr{^Plugins/SpotOn/(?:Soloist(?:\.pm|/)|Backend/Soloist\.pm|Unified/SoloistDaemon\.pm)};
    my @gone  = grep { $_ =~ $SOLOIST_RE } keys %INC;
    my %saved = map { $_ => $INC{$_} } @gone;
    delete @INC{@gone};
    my $hook = sub { my (undef, $file) = @_; die "amputated: $file\n" if $file =~ $SOLOIST_RE; return; };
    unshift @INC, $hook;
    my $ampOk;
    {
        local %Plugins::SpotOn::Backend::UNAVAILABLE = ();
        Slim::Web::Pages::reset_calls();
        $ampOk = eval { Plugins::SpotOn::Settings->new(); 1 };
    }
    my @ampRegs = grep { $_->[0] =~ /soloistRenew/ } @Slim::Web::Pages::registered_raw;
    @INC = grep { !(ref $_ && $_ == $hook) } @INC;
    @INC{keys %saved} = values %saved;
    ok($ampOk, '84-13: Settings->new() with the Soloist side absent does not die') or diag($@);
    is(scalar(@ampRegs), 0, '84-13: with only librespot available no renew route is registered');

    $prefs->set('backend', $backendBefore);
}

# ============================================================
# 84-13 Task 2 (B6, T-84-161, control-check W2): the renew POST still passes
# Settings' _csrfCheck -- driven from @registered_raw with the REAL routes()
# of Backend::Soloist (only renewBinary stubbed, no role double). Needs a
# server-namespace pref write: the prefs stub's `set` writes %_ns_store for
# a namespace it already serves (otherwise csrfProtectionLevel is ignored,
# _csrfCheck returns 1 before the header check and the 403 is unreachable).
# ============================================================
SKIP: {
    skip "Settings.pm/Soloist.pm module required for the renew csrf test", 7
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; require Plugins::SpotOn::Backend::Soloist;
                      require Slim::Web::HTTP; require Slim::Web::Pages; 1 };

    Slim::Web::Pages::reset_calls();
    Plugins::SpotOn::Settings->new();
    my @registered = @Slim::Web::Pages::registered_raw;
    my $renew  = resolve_raw_route(\@registered, 'plugins/SpotOn/settings/soloistRenew');
    my $status = resolve_raw_route(\@registered, 'plugins/SpotOn/settings/soloistRenewStatus');

    my $nowCalls = 0;
    no warnings 'redefine', 'once';
    my $origNow = Plugins::SpotOn::Backend::Soloist->can('renewNow');
    local *Plugins::SpotOn::Backend::Soloist::renewNow = sub { $nowCalls++; goto &$origNow };
    local *Plugins::SpotOn::Soloist::renewBinary = sub { return 'started' };

    my $server = Slim::Utils::Prefs::preferences('server');
    $server->set('csrfProtectionLevel', 1);
    is($server->get('csrfProtectionLevel'), 1, '84-13 csrf: harness precondition -- csrfProtectionLevel=1 is readable');

    @Slim::Web::HTTP::http_responses = ();
    my $noHdr = FakeSettingsResponse->new(request => FakeSettingsRequest->new);
    eval { $renew->('http_client_csrf', $noHdr) };
    is($noHdr->code, 403, '84-13 csrf: renew POST without X-Requested-With -> 403 (T-84-161)');
    is($nowCalls, 0, '84-13 csrf: the role renewNow is never reached without the header');

    my $withHdr = FakeSettingsResponse->new(request => FakeSettingsRequest->new(headers => { 'X-Requested-With' => 'XMLHttpRequest' }));
    eval { $renew->('http_client_csrf', $withHdr) };
    is($nowCalls, 1, '84-13 csrf: with the header the role renewNow runs once');
    is($withHdr->code, 200, '84-13 csrf: with the header the answer is 200 (_jsonResponse)');

    my $get = FakeSettingsResponse->new(request => FakeSettingsRequest->new);
    eval { $status->('http_client_csrf', $get) };
    is($get->code, 200, '84-13 csrf: the status GET answers through _jsonResponse without the header (no 403)');
    is($get->content_type, 'application/json', '84-13 csrf: the status GET answer is JSON');

    $server->set('csrfProtectionLevel', 0);
}

# ============================================================
# 84-13 Task 2 (W8): the soloist settings render with the Soloist role
# PRESENT fills the per-player quality notice from the role-private
# formatter (Settings.pm no longer passes one).
# ============================================================
SKIP: {
    skip "Settings.pm/Soloist.pm module required for the notice render test", 4
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; require Plugins::SpotOn::Soloist::Quality;
                      require Plugins::SpotOn::Backend::Soloist; 1 };
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $backendBefore = $prefs->get('backend');
    $prefs->set('backend', 'soloist');

    {
        package T09::NoticeClient;
        sub new  { return bless { id => 'aa:84:13:00:00:01' }, shift }
        sub id   { return $_[0]->{id} }
        sub name { return 'notice-player' }
    }
    my $nc = T09::NoticeClient->new;
    Slim::Player::Client::set_mock_clients($nc);

    my @fmt;
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::Quality::refreshEffective = sub { };
    local *Plugins::SpotOn::Soloist::Quality::noticeFor = sub { return { kind => 'no_token' } };
    local *Plugins::SpotOn::Soloist::activeVersion = sub { return '1.3.8.70' };
    local *Plugins::SpotOn::Soloist::get = sub { die "84-13: the settings render must not call the activating get()" };
    local *Plugins::SpotOn::Backend::Soloist::_formatQualityNotice = sub { push @fmt, $_[0]; return 'NOTICE:' . (($_[0] || {})->{kind} // '') };

    my $params = {};
    my $lived = eval { Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef); 1 };
    ok($lived, '84-13 notice: the soloist settings render lives with the Soloist role present') or diag($@);
    is(scalar(@{ $params->{soloistPlayers} || [] }), 1, '84-13 notice: one soloistPlayers row');
    is_deeply(\@fmt, [ { kind => 'no_token' } ], '84-13 notice: the role-private formatter receives the noticeFor() hashref');
    is(($params->{soloistPlayers}[0] || {})->{qualityNotice}, 'NOTICE:no_token', '84-13 notice: qualityNotice is filled from the role');

    Slim::Player::Client::set_mock_clients();
    $prefs->set('backend', $backendBefore);
}

# ============================================================
# Phase 83.3 plan 03 (D-05): handler() template param soloistInfoLine --
# neutral "Soloist <version>, expires in N days" line, formatted from the
# real Soloist::expiryDaysRemaining() (not a duplicated inline arithmetic).
# ============================================================
SKIP: {
    skip "Settings.pm/Soloist.pm module required for the soloistInfoLine test", 1
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $prevBackend = $prefs->get('backend') || 'librespot';

    # 83.3 plan 08 (gap 2, WR-01): the settings render is an informational
    # read site -- it must use the side-effect-free activeVersion() /
    # installedBinaryPath() accessors, never the activating get(). Stubbing
    # get() to die proves the render path never calls it.
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::get = sub {
        die "83.3-08: the settings render must not call the activating get()";
    };
    local *Plugins::SpotOn::Soloist::activeVersion = sub { return '1.3.8.70' };
    local *Plugins::SpotOn::Soloist::installedBinaryPath = sub {
        return '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    };

    $prefs->set('backend', 'soloist');
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days', { days => 40, checked_at => time() }, 'never');

    my $paramRef = {};
    Plugins::SpotOn::Settings->handler(undef, $paramRef, sub { }, undef, undef);

    # NOTE: this harness's Slim::Utils::Strings stub (line ~186 above)
    # returns '' for a bare string('KEY') call with no extra args (it only
    # joins args PAST the key), so sprintf(string('...'), ...) always
    # renders '' here regardless of correctness -- the exact sentence is
    # covered by the strings.txt content check below instead. What this
    # harness CAN prove is the wiring: expiryDaysRemaining() (not a
    # duplicated inline calculation) feeds the param, and the info line is
    # populated (present) whenever both inputs are available.
    is($paramRef->{soloistExpiryDays}, 40,
        '83.3-03: soloistExpiryDays is populated via the shared Soloist::expiryDaysRemaining() (not inline arithmetic)');
    ok(defined $paramRef->{soloistInfoLine} && length($paramRef->{soloistInfoLine}) == 0,
        '83.3-03: soloistInfoLine is defined (empty string is this stub\'s sprintf(\'\',...) artifact, see NOTE)');
    is($paramRef->{soloistDownloadUrl}, Plugins::SpotOn::Soloist::SOLOIST_DOWNLOAD_PAGE(),
        '83.3-03: soloistDownloadUrl matches the SOLOIST_DOWNLOAD_PAGE constant');

    $prefs->set('backend', $prevBackend);
}

# ============================================================
# Phase 83.3 plan 05 (D-08/D-09/D-10): handler() template params
# soloistManualDir/soloistPlaced/soloistExpiryHint -- the placed-binary
# fallback folder path and its evaluation state.
# ============================================================
SKIP: {
    skip "Settings.pm/Soloist.pm module required for the placed-binary wiring test", 1
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $prevBackend = $prefs->get('backend') || 'librespot';

    # 83.3 plan 08 (gap 2, WR-01): same die-stub as above -- the settings
    # render must never call the activating get().
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::get = sub {
        die "83.3-08: the settings render must not call the activating get()";
    };
    local *Plugins::SpotOn::Soloist::activeVersion = sub { return '1.3.8.70' };
    local *Plugins::SpotOn::Soloist::installedBinaryPath = sub {
        return '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    };

    $prefs->set('backend', 'soloist');

    # absent (default): soloistPlaced.text is '', soloistExpiryHint is 0.
    Plugins::SpotOn::Soloist::_cache()->remove('spoton_soloist_placed_state');
    Plugins::SpotOn::Soloist::_cache()->remove('spoton_soloist_expiry_days');

    my $paramRef = {};
    Plugins::SpotOn::Settings->handler(undef, $paramRef, sub { }, undef, undef);

    like($paramRef->{soloistManualDir}, qr{/spoton/soloist/manual\z},
        '83.3-05: soloistManualDir ends with /spoton/soloist/manual (Plugins::SpotOn::Soloist::manualDir())');
    is($paramRef->{soloistPlaced}{status}, 'absent', '83.3-05: soloistPlaced.status defaults to absent');
    is($paramRef->{soloistPlaced}{text}, '', '83.3-05: soloistPlaced.text is empty for status absent');
    is($paramRef->{soloistExpiryHint}, 0, '83.3-05: soloistExpiryHint gate is 0 when no placed binary is active');

    # active + within the 14-day warn threshold: soloistExpiryHint gate
    # flips to 1 (the template does the %s substitution itself).
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_placed_state',
        { status => 'active', version => '1.3.8.70', signature => 'x:1:1' }, 'never');
    Plugins::SpotOn::Soloist::_cache()->set('spoton_soloist_expiry_days',
        { days => 10, checked_at => time() }, 'never');

    $paramRef = {};
    Plugins::SpotOn::Settings->handler(undef, $paramRef, sub { }, undef, undef);

    is($paramRef->{soloistPlaced}{status}, 'active', '83.3-05: soloistPlaced.status is active');
    # Same harness limitation documented for soloistInfoLine above: this
    # file's Slim::Utils::Strings stub returns '' for a bare string('KEY')
    # call, so sprintf('', ...) always renders '' here regardless of
    # correctness -- what this proves is the WIRING (a status of 'active'
    # reaches the sprintf call at all), not the sentence text (covered by
    # the strings.txt content check instead).
    ok(defined $paramRef->{soloistPlaced}{text}, '83.3-05: soloistPlaced.text is defined for status active (see NOTE)');
    is($paramRef->{soloistExpiryHint}, 1,
        '83.3-05: soloistExpiryHint gate is 1 when a placed binary is active AND within the warn threshold');

    Plugins::SpotOn::Soloist::_cache()->remove('spoton_soloist_placed_state');
    Plugins::SpotOn::Soloist::_cache()->remove('spoton_soloist_expiry_days');
    $prefs->set('backend', $prevBackend);
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

# 85-11 (D-24 step 2): on the Soloist backend playerStepOk is 0 while any
# listed player is not paired and 1 once every listed player is.
SKIP: {
    skip "Settings.pm/Soloist.pm module required for the playerStepOk test", 3
        unless eval { require Plugins::SpotOn::Settings; require Plugins::SpotOn::Soloist; require Plugins::SpotOn::Soloist::Quality;
                      require Plugins::SpotOn::Backend::Soloist; 1 };
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $backendBefore = $prefs->get('backend');
    $prefs->set('backend', 'soloist');

    {
        package T09::StepClient;
        sub new  { return bless { id => $_[1] }, $_[0] }
        sub id   { return $_[0]->{id} }
        sub name { return 'step-' . $_[0]->{id} }
    }
    Slim::Player::Client::set_mock_clients(T09::StepClient->new('aa:85:11:00:00:01'),
                                           T09::StepClient->new('aa:85:11:00:00:02'));
    my %paired = ('aa:85:11:00:00:01' => 1, 'aa:85:11:00:00:02' => 0);
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Soloist::Quality::refreshEffective = sub { };
    local *Plugins::SpotOn::Soloist::activeVersion = sub { return '1.3.8.70' };
    local *Plugins::SpotOn::Soloist::isPairedForClient = sub { return $paired{ $_[0] } };

    my $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is(scalar(@{ $params->{soloistPlayers} || [] }), 2, '85-11: two listed Soloist players');
    is($params->{playerStepOk}, 0, '85-11: playerStepOk is 0 while one listed player is not paired');
    $paired{'aa:85:11:00:00:02'} = 1;
    $params = {};
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    is($params->{playerStepOk}, 1, '85-11: playerStepOk is 1 once every listed player is paired');

    Slim::Player::Client::set_mock_clients();
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

# ============================================================
# 79-05 (D-12, revised 2026-10-19/20): the default backend stays librespot;
# on a fit platform (Linux, arch in @ARCH_MAP, glibc >= 2.38) the settings
# page shows a Soloist hint while librespot is active and no key is stored.
# d12_env() runs $code with a controlled platform / glibc / arch / backend /
# key state over the REAL Soloist role (keyState, storeKey, bootstrap are
# counted doubles; nothing touches the disk or the network).
# ============================================================
our %D12;
sub d12_env {
    my ($o, $code) = @_;
    require Plugins::SpotOn::Settings;
    require Plugins::SpotOn::Backend;
    require Plugins::SpotOn::Backend::Soloist;
    require Plugins::SpotOn::Soloist::Quality;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $backendBefore = $prefs->get('backend');
    $prefs->set('backend', $o->{backend} // 'librespot');

    no warnings 'redefine', 'once';
    # t/soloist also runs in the tree with the librespot side amputated (CI
    # leg "Amputation librespot"). The librespot-active cells need the
    # librespot role's key-store answer (keyState supported 0, nothing else),
    # so a minimal stand-in is installed there; with the real role on disk
    # nothing is replaced.
    local $INC{'Plugins/SpotOn/Backend/Librespot.pm'} = $INC{'Plugins/SpotOn/Backend/Librespot.pm'};
    if (!eval { require Plugins::SpotOn::Backend::Librespot; 1 }) {
        $INC{'Plugins/SpotOn/Backend/Librespot.pm'} = 'stand-in';
        local $@;
        *Plugins::SpotOn::Backend::Librespot::keyState     = sub { return { supported => 0, present => 0 } };
        *Plugins::SpotOn::Backend::Librespot::storeKey     = sub { return (0, 'unsupported') };
        *Plugins::SpotOn::Backend::Librespot::clearKey     = sub { return 0 };
        *Plugins::SpotOn::Backend::Librespot::bootstrap    = sub { return 'ok' };
        *Plugins::SpotOn::Backend::Librespot::settingsInfo = sub { return 'ok' };
        *Plugins::SpotOn::Backend::Librespot::qualityInfo  = sub { return { supported => 0, validLevels => [] } };
    }
    local %Plugins::SpotOn::Backend::UNAVAILABLE = ();
    %D12 = (present => ($o->{present} ? 1 : 0), store => [], clear => 0, bootstrap => 0, log => []);
    my $arch = $o->{arch} // 'x86_64';
    local $Plugins::SpotOn::Unified::DaemonManager::fake_glibc = exists $o->{glibc} ? $o->{glibc} : '2.40';
    local $main::FAKE_ISWINDOWS = $o->{win} ? 1 : 0;
    local $main::FAKE_ISMAC     = $o->{mac} ? 1 : 0;
    local *Slim::Utils::OSDetect::details = sub { return { osArch => $arch } };
    local *Plugins::SpotOn::Backend::Soloist::keyState = sub { return { supported => 1, present => $D12{present} } };
    local *Plugins::SpotOn::Backend::Soloist::storeKey = sub { push @{ $D12{store} }, $_[1]; $D12{present} = 1; return (1) };
    local *Plugins::SpotOn::Backend::Soloist::clearKey = sub { $D12{clear}++; $D12{present} = 0; return 1 };
    local *Plugins::SpotOn::Backend::Soloist::bootstrap = sub { $D12{bootstrap}++; return 'ok' };
    local *Plugins::SpotOn::Soloist::Quality::refreshEffective = sub { };
    local *Plugins::SpotOn::Soloist::activeVersion = sub { return '1.3.8.70' };
    local *Slim::Utils::Log::info  = sub { push @{ $D12{log} }, $_[1] };
    local *Slim::Utils::Log::warn  = sub { push @{ $D12{log} }, $_[1] };
    local *Slim::Utils::Log::error = sub { push @{ $D12{log} }, $_[1] };
    local *Slim::Utils::Log::debug = sub { push @{ $D12{log} }, $_[1] };
    Plugins::SpotOn::Unified::DaemonManager::reset_calls();

    my @r = eval { $code->($prefs) };
    my $err = $@;
    $prefs->set('backend', $backendBefore);
    die $err if $err;
    return @r;
}
sub d12_render {
    my (%post) = @_;
    my $params = { %post };
    Plugins::SpotOn::Settings->handler(undef, $params, sub { }, undef, undef);
    return $params;
}

{
    my $DM_PKG = 'Plugins::SpotOn::Unified::DaemonManager';
    my @fit = (backend => 'librespot', present => 0);

    d12_env({ @fit }, sub {
        my $p = d12_render();
        is($p->{soloistHint}, 1, '79-05 D-12: fit Linux (x86_64, glibc 2.40), librespot, no key -> soloistHint 1');
        is($p->{soloistSwitchOffer}, 0, '79-05 D-12: ... and no switch offer yet (no key)');
    });
    d12_env({ backend => 'soloist', present => 0 }, sub {
        my $p = d12_render();
        is($p->{soloistHint}, 0, '79-05 D-12: backend soloist -> soloistHint 0');
        is($p->{soloistSwitchOffer}, 0, '79-05 D-12: backend soloist -> soloistSwitchOffer 0');
    });
    d12_env({ @fit, glibc => '2.36' }, sub {
        is(d12_render()->{soloistHint}, 0, '79-05 D-12: glibc 2.36 -> no hint');
    });
    d12_env({ @fit, glibc => undef }, sub {
        is(d12_render()->{soloistHint}, 0, '79-05 D-12: glibc not detectable -> no hint (counts as unfit)');
    });
    d12_env({ @fit, win => 1 }, sub {
        is(d12_render()->{soloistHint}, 0, '79-05 D-12: Windows -> no hint');
    });
    d12_env({ @fit, arch => 'riscv64' }, sub {
        is(d12_render()->{soloistHint}, 0, '79-05 D-12: unknown arch -> no hint');
    });

    # the platform decision keeps its one site: the fit helper calls it
    d12_env({ @fit }, sub {
        my $calls = 0;
        no warnings 'redefine';
        no strict 'refs';
        my $orig = \&{"${DM_PKG}::platformSupportsSoloist"};
        local *{"${DM_PKG}::platformSupportsSoloist"} = sub { $calls++; return $orig->(@_) };
        d12_render();
        ok($calls >= 1, '79-05 D-12: the hint decision goes through DaemonManager->platformSupportsSoloist');
    });

    # template: the hint block sits between the backend select and div#soloist-fields
    {
        my $html = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
        open(my $fh, '<', $html) or die "basic.html: $!";
        my @lines = <$fh>;
        close $fh;
        my ($sel, $hint, $fields);
        for my $i (0 .. $#lines) {
            $sel    //= $i if $lines[$i] =~ /name="pref_backend"/;
            $hint   //= $i if $lines[$i] =~ /IF soloistHint %\]/;
            $fields //= $i if $lines[$i] =~ /id="soloist-fields"/;
        }
        ok(defined $hint, '79-05 D-12: basic.html carries a soloistHint block');
        ok(defined $sel && defined $hint && defined $fields && $sel < $hint && $hint < $fields,
            '79-05 D-12: the hint block sits after the backend select and before div#soloist-fields (outside the hidden div)');
    }
}

# ============================================================
# 79-05 Task 2 (D-12, user decision 2026-10-20 "Schluesselfeld im Hinweis"):
# the hint carries its own key input (soloistHintKey). A key POSTed there
# while librespot is active is stored through the Soloist role's key store;
# the backend stays librespot, no Soloist bootstrap runs, no extra
# scheduleInit. Once a key is stored the page offers the switch; only the
# user's click (switchBackendSoloist) switches, and the server re-checks
# availability, fit and key before it sets backend soloist.
# ============================================================
{
    my $TOKEN = 'hintTok_ABCD-1234.efgh';       # 22 chars, inside the key charset
    my $DM    = 'Plugins::SpotOn::Unified::DaemonManager';
    my $sched = sub { no strict 'refs'; return ${"${DM}::schedule_init_calls"} };
    my $blob  = sub {                           # every scalar value of $paramRef, flattened
        my ($d) = @_;
        my @todo = ($d); my @out;
        while (@todo) {
            my $x = shift @todo;
            if    (ref $x eq 'HASH')  { push @todo, values %$x }
            elsif (ref $x eq 'ARRAY') { push @todo, @$x }
            elsif (defined $x && !ref $x) { push @out, $x }
        }
        return join("\n", @out);
    };

    # k1 + k2: POST with a hint key under librespot, then the next render offers the switch
    d12_env({ backend => 'librespot', present => 0 }, sub {
        my ($prefs) = @_;
        d12_render(saveSettings => 1, pref_backend => 'librespot', pref_soloistKey => '');
        my $baseline = $sched->();
        $D12{present} = 0; @{ $D12{store} } = ();
        Plugins::SpotOn::Unified::DaemonManager::reset_calls();

        my $p = d12_render(saveSettings => 1, pref_backend => 'librespot', pref_soloistKey => '',
                           soloistHintKey => "  $TOKEN  ");
        is_deeply($D12{store}, [ $TOKEN ], 'k1: the hint key is stored once through the Soloist role, trimmed');
        is($prefs->get('backend'), 'librespot', 'k1: the backend pref stays librespot');
        is($D12{bootstrap}, 0, 'k1: no Soloist bootstrap ran');
        is(Plugins::SpotOn::Unified::DaemonManager->backendName(), 'librespot', 'k1: backendName still names librespot');
        is($sched->(), $baseline, 'k1: scheduleInit count equals the same POST without the hint key (no extra restart)');
        is($p->{soloistHint}, 0, 'k2: the render after the store reads soloistHint 0');
        is($p->{soloistSwitchOffer}, 1, 'k2: ... and soloistSwitchOffer 1');

        # k7: the raw token stays out of $paramRef and the log
        unlike($blob->($p), qr/\Q$TOKEN\E/, 'k7: the raw token appears in no $paramRef value');
        ok(!exists $p->{soloistHintKey}, 'k7: soloistHintKey is removed from $paramRef');
        ok(!(grep { defined $_ && index($_, 'hintTok_ABCD') >= 0 } @{ $D12{log} }), 'k7: the raw token never reaches the log');
    });

    # k3: invalid tokens store nothing and warn KEY_INVALID
    for my $bad ('short-123', 'has space and bad!chars_0123456789', 'semi;colon_0123456789abcd') {
        d12_env({ backend => 'librespot', present => 0 }, sub {
            no warnings 'redefine', 'once';
            local *Plugins::SpotOn::Settings::string = sub { return 'STR:' . $_[0] };
            my $p = d12_render(saveSettings => 1, pref_backend => 'librespot', soloistHintKey => $bad);
            is(scalar @{ $D12{store} }, 0, "k3: invalid hint key '$bad' stores nothing");
            is($p->{warning}, 'STR:PLUGIN_SPOTON_SOLOIST_KEY_INVALID', "k3: ... and warns KEY_INVALID");
        });
    }

    # k4: an empty or whitespace-only hint field never stores or clears
    for my $empty ('', '   ') {
        d12_env({ backend => 'librespot', present => 1 }, sub {
            d12_render(saveSettings => 1, pref_backend => 'librespot', pref_soloistKey => Plugins::SpotOn::Settings::SOLOIST_KEY_MASKED_PREVIEW(), soloistHintKey => $empty);
            is(scalar @{ $D12{store} }, 0, "k4: empty hint field (" . length($empty) . " chars) stores nothing");
            is($D12{clear}, 0, "k4: ... and clears nothing");
            is($D12{present}, 1, "k4: ... the stored key survives");
        });
    }

    # k5: unfit platforms store nothing and render no hint
    for my $unfit ([ 'Windows', win => 1 ], [ 'glibc 2.36', glibc => '2.36' ]) {
        my ($label, @o) = @$unfit;
        d12_env({ backend => 'librespot', present => 0, @o }, sub {
            my $p = d12_render(saveSettings => 1, pref_backend => 'librespot', soloistHintKey => $TOKEN);
            is(scalar @{ $D12{store} }, 0, "k5: $label: a hint-key POST stores nothing");
            is($p->{soloistHint}, 0, "k5: $label: the render has soloistHint 0");
        });
    }

    # k6: under backend soloist the existing path stays; an empty pref_soloistKey falls back to the hint value
    d12_env({ backend => 'soloist', present => 0 }, sub {
        d12_render(saveSettings => 1, pref_backend => 'soloist', pref_soloistKey => '', soloistHintKey => $TOKEN);
        is_deeply($D12{store}, [ $TOKEN ], 'k6: backend soloist, empty pref_soloistKey: the hint value is stored once');
    });
    d12_env({ backend => 'soloist', present => 0 }, sub {
        my $other = 'prefKey_ZYXW-9876.abcd';
        d12_render(saveSettings => 1, pref_backend => 'soloist', pref_soloistKey => $other, soloistHintKey => $TOKEN);
        is_deeply($D12{store}, [ $other ], 'k6: a non-empty pref_soloistKey wins over the hint value');
    });

    # switch offer: flag matrix
    d12_env({ backend => 'librespot', present => 1 }, sub {
        my $p = d12_render();
        is($p->{soloistSwitchOffer}, 1, 'offer: fit + librespot + key -> soloistSwitchOffer 1');
        is($p->{soloistHint}, 0, 'offer: ... and soloistHint 0');
    });
    d12_env({ backend => 'soloist', present => 1 }, sub {
        is(d12_render()->{soloistSwitchOffer}, 0, 'offer: backend soloist -> no offer');
    });
    d12_env({ backend => 'librespot', present => 1, glibc => '2.36' }, sub {
        is(d12_render()->{soloistSwitchOffer}, 0, 'offer: unfit (glibc 2.36) -> no offer');
    });

    # switch POST
    d12_env({ backend => 'librespot', present => 1 }, sub {
        my ($prefs) = @_;
        my $p = d12_render(saveSettings => 1, switchBackendSoloist => 1, pref_backend => 'librespot',
                           pref_soloistKey => Plugins::SpotOn::Settings::SOLOIST_KEY_MASKED_PREVIEW());
        is($prefs->get('backend'), 'soloist', 'switch: fit + key -> backend becomes soloist');
        is($D12{bootstrap}, 1, 'switch: the soloist role bootstrap ran once');
        is($sched->(), 2, 'switch: scheduleInit ran (normalization + backend)');
        is($D12{present}, 1, 'switch: the stored key survives (masked resubmit does not clear)');
        is(scalar @{ $D12{store} }, 0, 'switch: nothing re-stored');
        is($D12{clear}, 0, 'switch: nothing cleared');
    });
    d12_env({ backend => 'librespot', present => 0 }, sub {
        my ($prefs) = @_;
        d12_render(saveSettings => 1, switchBackendSoloist => 1, pref_backend => 'librespot');
        is($prefs->get('backend'), 'librespot', 'switch: no key -> backend stays librespot');
        is($D12{bootstrap}, 0, 'switch: no key -> nothing bootstrapped');
    });
    d12_env({ backend => 'librespot', present => 1, glibc => '2.36' }, sub {
        my ($prefs) = @_;
        d12_render(saveSettings => 1, switchBackendSoloist => 1);
        is($prefs->get('backend'), 'librespot', 'switch: unfit platform -> crafted POST changes nothing');
        is($D12{bootstrap}, 0, 'switch: unfit -> nothing bootstrapped');
    });
    d12_env({ backend => 'librespot', present => 1 }, sub {
        my ($prefs) = @_;
        local %Plugins::SpotOn::Backend::UNAVAILABLE = (soloist => 'amputated for the test');
        d12_render(saveSettings => 1, switchBackendSoloist => 1);
        is($prefs->get('backend'), 'librespot', "switch: 'soloist' not in available() -> backend stays librespot");
        is($D12{bootstrap}, 0, "switch: ... nothing bootstrapped");
    });
    # one POST with the hint key and the switch, no key yet: key stored, switch ignored
    d12_env({ backend => 'librespot', present => 0 }, sub {
        my ($prefs) = @_;
        my $p = d12_render(saveSettings => 1, switchBackendSoloist => 1, pref_backend => 'librespot', soloistHintKey => $TOKEN);
        is_deeply($D12{store}, [ $TOKEN ], 'both: the hint key is stored');
        is($prefs->get('backend'), 'librespot', 'both: the switch is ignored (no key when the switch branch ran)');
        is($p->{soloistSwitchOffer}, 1, 'both: the offer appears on the same render');
    });

    # template: the hint input and the offer sit in the hint block
    {
        my $html = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
        open(my $fh, '<', $html) or die "basic.html: $!";
        my @lines = <$fh>;
        close $fh;
        my ($if, $input, $elsif, $fields, $offerInput, @inputs, $prefKey);
        for my $i (0 .. $#lines) {
            $if     //= $i if $lines[$i] =~ /IF soloistHint %\]/;
            if ($lines[$i] =~ /name="soloistHintKey"/) { $input //= $i; push @inputs, $i }
            $elsif  //= $i if $lines[$i] =~ /ELSIF soloistSwitchOffer %\]/;
            $offerInput //= $i if $lines[$i] =~ /name="switchBackendSoloist"/;
            $fields //= $i if $lines[$i] =~ /id="soloist-fields"/;
            $prefKey++ if $lines[$i] =~ /name="pref_soloistKey"/;
        }
        is(scalar @inputs, 1, 'tpl: exactly one soloistHintKey input');
        ok(defined $if && defined $input && defined $fields && $if < $input && $input < $fields,
            'tpl: the soloistHintKey input sits on its own line below the IF line and above div#soloist-fields');
        ok(defined $elsif && defined $offerInput && $input < $elsif && $elsif < $offerInput && $offerInput < $fields,
            'tpl: the ELSIF offer branch with the switchBackendSoloist input follows the hint input');
        is($prefKey, 1, 'tpl: name="pref_soloistKey" still exactly once');
        like(join('', @lines), qr/name="switchBackendSoloist"[^>]*disabled/, 'tpl: the switch input is posted only after the button enables it');
    }
}

# ============================================================
# 79-05 Task 3 (D-12): the unfit matrix. Where Soloist cannot run (Windows,
# macOS, glibc below 2.38, glibc not detectable, an architecture without a
# shipped build) and under backend soloist, neither hint nor offer is shown
# for either key state, a crafted switch POST changes nothing, and (on the
# five unfit platforms) a crafted hint-key POST stores nothing.
# ============================================================
{
    my $TOKEN = 'hintTok_ABCD-1234.efgh';
    my @rows = (
        [ 'Windows',               { win   => 1 },            1 ],
        [ 'macOS',                 { mac   => 1 },            1 ],
        [ 'Linux glibc 2.36',      { glibc => '2.36' },       1 ],
        [ 'Linux glibc undetected',{ glibc => undef },        1 ],
        [ 'Linux unknown arch',    { arch  => 'riscv64' },    1 ],
        [ 'Linux fit, backend soloist', { backend => 'soloist' }, 0 ],
    );
    for my $row (@rows) {
        my ($label, $env, $unfit) = @$row;
        my $backend = $env->{backend} // 'librespot';
        for my $present (0, 1) {
            my $cell = "$label, key " . ($present ? 'present' : 'absent');
            d12_env({ %$env, backend => $backend, present => $present }, sub {
                my ($prefs) = @_;
                my $p = d12_render();
                is($p->{soloistHint}, 0, "79-05 matrix: $cell: no hint");
                is($p->{soloistSwitchOffer}, 0, "79-05 matrix: $cell: no offer");

                d12_render(saveSettings => 1, switchBackendSoloist => 1, pref_backend => $backend);
                is($prefs->get('backend'), $backend, "79-05 matrix: $cell: a crafted switch POST leaves the backend $backend");
                if ($unfit) {
                    is($D12{bootstrap}, 0, "79-05 matrix: $cell: ... and bootstraps nothing");
                    d12_render(saveSettings => 1, pref_backend => $backend, soloistHintKey => $TOKEN);
                    is(scalar @{ $D12{store} }, 0, "79-05 matrix: $cell: a crafted hint-key POST stores nothing");
                }
            });
        }
    }
}

done_testing();
