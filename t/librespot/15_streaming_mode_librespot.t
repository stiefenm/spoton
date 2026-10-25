#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: librespot half of t/15_streaming_mode.t --
# COMPAT-02 canDirectStream over the REAL Backend::Librespot streamUrl, reached
# through the DaemonManager stub's backendClass)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# Create temporary directories for LMS stubs and cache
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
# LMS Module Stubs (copied from t/11_track_history.t — the canonical
# analog for loading ProtocolHandler.pm with a complete stub set)
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
use parent 'Exporter';
our @EXPORT_OK = qw(logger addLogCategory);
my $_noop_logger = bless {}, 'Slim::Utils::Log';

sub addLogCategory { return $_noop_logger }
sub logger         { return $_noop_logger }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }

sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"}         = \&logger;
    *{"${caller}::addLogCategory"} = \&addLogCategory;
}
1;
END

# Stub: Slim::Utils::Prefs (with client() support for per-player prefs)
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
use parent 'Exporter';
our \@EXPORT_OK = qw(preferences);
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

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
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
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
sub setTimer   { }
sub killTimers { }
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

# Stub: JSON::XS (Plugin.pm uses 'use JSON::XS qw(encode_json)')
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

# Stub: Slim::Player::TranscodingHelper
write_stub($stub_dir, 'Slim::Player::TranscodingHelper', <<'END');
package Slim::Player::TranscodingHelper;
our %commandTable;
sub getConvertCommand2 { return ('command', 'type', 'F', 'T', 0, 1) }
sub Conversions { return \%commandTable }
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

# Stub: Slim::Utils::Network (needed by ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

# Stub: Slim::Utils::Versions (needed by ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

# Stub: Slim::Utils::Misc (needed by ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL { ('127.0.0.1', 80, '/stream') }
1;
END

# Stub: Slim::Control::Request
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our $notify_count = 0;
sub notifyFromArray { $notify_count++ }
sub subscribe   { }
sub unsubscribe { }
sub addDispatch { }
1;
END

# Stub: Slim::Music::Info
write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END

# Stub: Slim::Player::Protocols::HTTP
write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Plugins::SpotOn::API::SpClient with controllable $mock_track
# (re-pointed from a Plugins::SpotOn::API::Client stub in Phase 75 Plan 06 --
# ProtocolHandler.pm's _asyncRefetch now calls SpClient->getTrack, D-08)
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
our $mock_track = undef;
sub getTrack {
    my ($class, $account_id, $track_id, $cb) = @_;
    $cb->($mock_track);
}
sub AUTOLOAD { }
1;
END

# Stub: Plugins::SpotOn::Helper with controllable getCapability
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $helperCapabilities = {};
sub get { return '/usr/bin/false' }
sub init { }
sub getCapability {
    my ($class, $key) = @_;
    return $helperCapabilities->{$key} if $helperCapabilities && defined $helperCapabilities->{$key};
    return undef;
}
1;
END

# Stub: URI::Escape — not Perl core, bundled by LMS
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape);
sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge; return $s; }
1;
END

# Stub: Plugins::SpotOn::Unified::DaemonManager (COMPAT-02 — new for canDirectStream coverage)
# helperForClient always returns a live mock helper on a fixed stream port so the
# Browse/Connect branches in canDirectStream() construct a daemon HTTP URL.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
sub helperForClient { return bless {}, 'MockDaemonHelper' }
sub scheduleInit { }
sub resolvePassthroughForClient { return 0 }
# 84-08: ProtocolHandler reaches the backend through the role. The backend
# pref is unset here (librespot), so the factory hands out the REAL
# Backend::Librespot over helperForClient above -- the COMPAT-02 cells keep
# exercising the production URL logic, not a copy.
# 84-13: $BACKEND switches the factory to the real Soloist role for the
# Settings::Player cells (default librespot, as before).
our $BACKEND = 'Plugins::SpotOn::Backend::Librespot';
sub backendClass { (my $f = "$BACKEND.pm") =~ s{::}{/}g; require $f; return $BACKEND }
sub backendFor {
    my ($class, $c) = @_;
    return undef unless defined $c;
    return backendClass()->new(ref $c ? $c->id : $c);
}

package MockDaemonHelper;
sub alive       { 1 }
sub _streamPort { 39755 }
1;
END

# ============================================================
# 83.3-02: stubs needed to load and exercise Settings::Player->handler()'s
# real soloistQuality save block (Quality.pm's applyChange is glob-overridden
# in the test itself, so none of these are ever hit by a real network call --
# they only need to make Settings::Player.pm and Quality.pm LOADABLE).
# ============================================================

write_stub($stub_dir, 'Slim::Web::Settings', <<'END');
package Slim::Web::Settings;
sub new     { bless {}, shift }
sub handler { }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Slim::Web::HTTP::CSRF', <<'END');
package Slim::Web::HTTP::CSRF;
sub protectCommand { $_[1] }
sub protectName    { $_[1] }
sub protectURI     { $_[1] }
1;
END

write_stub($stub_dir, 'Slim::Utils::PluginManager', <<'END');
package Slim::Utils::PluginManager;
sub isEnabled { 0 }
1;
END

# Minimal -- Quality.pm's `use Slim::Player::Client;` only needs the module to
# be loadable; getClient/clients are never invoked by the applyChange-
# overridden test path below.
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our %clients;
sub getClient { my ($mac) = @_; return $clients{$mac || ''}; }
sub clients   { return values %clients; }
1;
END

# Minimal -- same reasoning: Quality.pm's `use` only needs it loadable.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { return bless {}, shift }
sub post { }
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
# always compiles Plugin.pm first — provide the constant for standalone loads.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load stubs so subsequent `require` calls inside ProtocolHandler.pm find the stubs.
require Plugins::SpotOn::Helper;
require Plugins::SpotOn::API::SpClient;
require Plugins::SpotOn::Unified::DaemonManager;
require Slim::Control::Request;
require Slim::Web::Settings;
require Slim::Web::HTTP::CSRF;
require Slim::Utils::PluginManager;
require Slim::Player::Client;
require Slim::Networking::SimpleAsyncHTTP;

# ============================================================
# Load ProtocolHandler.pm
# ============================================================
require_ok('Plugins::SpotOn::ProtocolHandler') or BAIL_OUT("Failed to load ProtocolHandler.pm");

# ============================================================
# Mock client object — extended from t/11_track_history.t's MockClient with
# isSynced (canDirectStream Browse/Connect branches call it directly) and an
# explicit id() accessor for readability in per-case setup below.
# ============================================================
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    sub can { return 0 }
    sub master { $_[0] }
    sub isSynced { 0 }
    sub id { ${$_[0]} }
    sub playingSong { undef }
    sub currentPlaylistUpdateTime { 1 }
}

my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

# ============================================================
# Group A: COMPAT-02 canDirectStream proxy gate + global resolution (GH #96)
# Each case uses a FRESH MockClient id — the Prefs stub keys per-client
# namespaces by id and has no remove method, so reusing an id would leak
# state between cases.
# ============================================================

subtest 'COMPAT-02: per-player proxy forces canDirectStream=0 for Browse URL' => sub {
    my $client = MockClient->new('gateA1');
    $prefs->client($client)->set('streamingMode', 'proxy');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    is($result, 0, 'per-player streamingMode=proxy returns 0 for Browse URL');
};

subtest 'COMPAT-02: per-player proxy forces canDirectStream=0 for Connect URL' => sub {
    my $client = MockClient->new('gateA2');
    $prefs->client($client)->set('streamingMode', 'proxy');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://connect-20260703-test');
    is($result, 0, 'per-player streamingMode=proxy returns 0 for Connect URL');
};

subtest 'COMPAT-02: per-player direct overrides a global proxy default' => sub {
    $prefs->set('streamingMode', 'proxy');
    my $client = MockClient->new('gateA3');
    $prefs->client($client)->set('streamingMode', 'direct');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    ok($result, 'per-player direct overrides a global proxy default (truthy result)');
    like($result, qr{/track/ABC123}, 'result is the daemon HTTP URL for the requested track');
};

subtest 'COMPAT-02: per-player explicit global resolves against a global proxy default' => sub {
    $prefs->set('streamingMode', 'proxy');
    my $client = MockClient->new('gateA4');
    $prefs->client($client)->set('streamingMode', 'global');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    is($result, 0, 'per-player global explicitly resolves against a global proxy default -> 0');
};

subtest 'COMPAT-02: per-player unset resolves against a global proxy default' => sub {
    $prefs->set('streamingMode', 'proxy');
    my $client = MockClient->new('gateA5');
    # No per-player streamingMode pref set at all — unset behaves as 'global'

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    is($result, 0, 'per-player unset resolves against a global proxy default -> 0');
};

subtest 'COMPAT-02: all-unset defaults to direct (regression — default behavior unchanged)' => sub {
    # Explicitly clear the global default to simulate a totally fresh install
    $prefs->set('streamingMode', undef);
    my $client = MockClient->new('gateA6');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    ok($result, 'all prefs unset returns truthy daemon HTTP URL (default behavior unchanged)');
    like($result, qr{/track/ABC123}, 'result contains /track/ABC123');
};

subtest 'COMPAT-02: per-player global resolves against a global direct default' => sub {
    $prefs->set('streamingMode', 'direct');
    my $client = MockClient->new('gateA7');
    $prefs->client($client)->set('streamingMode', 'global');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    ok($result, 'per-player global resolves against a global direct default -> truthy');
};

# ============================================================
# 84-13 Task 2 (moved here by 84-09 from the Settings::Player render block,
# now in t/soloist/15_streaming_mode_soloist.t): a librespot player page has
# no quality section and saves/renders with the Soloist modules absent --
# over the REAL Backend::Librespot role (qualityInfo -> supported 0).
# ============================================================
{
    require Plugins::SpotOn::Settings::Player;
    require Plugins::SpotOn::Backend;
    no warnings 'redefine', 'once';
    # librespot player: no quality section, also with the Soloist module absent
    local $Plugins::SpotOn::Unified::DaemonManager::BACKEND = 'Plugins::SpotOn::Backend::Librespot';
    $prefs->set('backend', 'librespot');
    my $RE = qr{^Plugins/SpotOn/(?:Soloist(?:\.pm|/)|Backend/Soloist\.pm|Unified/SoloistDaemon\.pm)};
    my @gone  = grep { $_ =~ $RE } keys %INC;
    my %saved = map { $_ => $INC{$_} } @gone;
    delete @INC{@gone};
    my $hook = sub { my (undef, $file) = @_; die "amputated: $file\n" if $file =~ $RE; return; };
    unshift @INC, $hook;
    my $lp = {};
    my $llived = eval { Plugins::SpotOn::Settings::Player->handler(MockClient->new('gate8413r2'),
        { saveSettings => 1, pref_soloistQuality => '5' }, sub { }, undef, undef); 1 };
    my $lerr = $@;
    my $rlived = eval { Plugins::SpotOn::Settings::Player->handler(MockClient->new('gate8413r3'), $lp, sub { }, undef, undef); 1 };
    my $rerr = $@;
    @INC = grep { !(ref $_ && $_ == $hook) } @INC;
    @INC{keys %saved} = values %saved;
    ok($llived && $rlived, '84-13: librespot player page saves and renders with the Soloist module absent (no die)')
        or diag("save: $lerr render: $rerr");
    ok(!exists $lp->{soloistQualityLevels}, '84-13: librespot player page has no quality section');
}

done_testing();
