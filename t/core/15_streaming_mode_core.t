#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: core half of t/15_streaming_mode.t -- COMPAT-01,
# the 84-21 presence-marker cells over a mocked role, i18n. COMPAT-02 is in
# t/librespot/15_streaming_mode_librespot.t, the 83.3-02/84-13 Soloist quality
# cells in t/soloist/15_streaming_mode_soloist.t)
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

# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($stub_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# Settings::Player asks the role for its quality table and capabilities;
# librespot has no Spotify quality control (supported => 0).
sub qualityInfo  { return { supported => 0, validLevels => [] } }
sub quality      { return 'unsupported' }
sub capabilities { return {} }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
sub qualityInfo  { return { supported => 0, validLevels => [] } }
sub quality      { return 'unsupported' }
sub capabilities { return {} }
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
# Group B: COMPAT-01 enum validation regex checks
#
# HONESTY NOTE (review finding): these assert a copy of the regex, not
# Settings/Player.pm handler execution — the per-player handler is covered
# by the grep acceptance criteria in Task 1 plus manual UAT. The GLOBAL
# handler gets real execution coverage in t/09_settings.t.
# ============================================================

subtest 'COMPAT-01: per-player streamingMode enum regex (global|direct|proxy)' => sub {
    my $re = qr/^(?:global|direct|proxy)$/;
    ok('global' =~ $re, 'per-player regex accepts global');
    ok('direct' =~ $re, 'per-player regex accepts direct');
    ok('proxy'  =~ $re, 'per-player regex accepts proxy');
    ok('bogus' !~ $re, 'per-player regex rejects an invalid value');
    ok(''      !~ $re, 'per-player regex rejects an empty string');
};

subtest 'COMPAT-01: global streamingMode enum regex (direct|proxy)' => sub {
    my $re = qr/^(?:direct|proxy)$/;
    ok('direct' =~ $re, 'global regex accepts direct');
    ok('proxy'  =~ $re, 'global regex accepts proxy');
    ok('global' !~ $re, 'global regex rejects "global" (not a valid global-scope value)');
    ok('bogus'  !~ $re, 'global regex rejects an invalid value');
    ok(''       !~ $re, 'global regex rejects an empty string');
};

# ============================================================
# 84-21 Task 1 (D-31 (2)): the three checkbox prefs (enableSpotifyConnect,
# disableDiscovery, enableAutoplay) are written ONLY when their `has_*`
# presence marker is posted. A browser omits an unchecked checkbox, so
# "pref_ absent" alone cannot tell "unchecked" from "field not on this form"
# -- the one-field POST that muted lavender-UAT for two days (a partial
# form flipped all three). Same handler call form as Group B.1 above.
# ============================================================
{
    # 84-09 (core half): Settings::Player is core and must load -- no
    # backend-conditional SKIP here. The backend role is the per-file mock
    # above (qualityInfo -> supported 0), so the handler never reaches a
    # Soloist module and needs no Soloist::Quality::applyChange override.
    require Plugins::SpotOn::Settings::Player;

    my $set3 = sub {
        my ($c, $conn, $disc, $auto) = @_;
        $prefs->client($c)->set('enableSpotifyConnect', $conn);
        $prefs->client($c)->set('disableDiscovery',     $disc);
        $prefs->client($c)->set('enableAutoplay',       $auto);
    };
    my $get3 = sub {
        my ($c) = @_;
        return join('/', map { $prefs->client($c)->get($_) // 'undef' }
            qw(enableSpotifyConnect disableDiscovery enableAutoplay));
    };

    # one-field POST: no has_* marker -> all three untouched
    my $c1 = MockClient->new('gate84211');
    $set3->($c1, 1, 0, 1);
    Plugins::SpotOn::Settings::Player->handler(
        $c1, { saveSettings => 1, pref_soloistQuality => 'global' }, sub { }, undef, undef);
    is($get3->($c1), '1/0/1', '84-21 D-31(2): a one-field POST leaves enableSpotifyConnect/disableDiscovery/enableAutoplay as they were');

    # full form, Connect box unchecked (marker present, pref_ absent)
    my $c2 = MockClient->new('gate84212');
    $set3->($c2, 1, 0, 1);
    Plugins::SpotOn::Settings::Player->handler(
        $c2, { saveSettings => 1,
               has_enableSpotifyConnect => 1,
               has_enableDiscovery => 1, pref_enableDiscovery => 1,
               has_enableAutoplay => 1,  pref_enableAutoplay => 1 },
        sub { }, undef, undef);
    is($get3->($c2), '0/0/1', '84-21 D-31(2): full form with the Connect box unchecked (marker, no pref_) turns Connect off');

    # crash-loop form: discovery box disabled -> its marker is not rendered
    my $c3 = MockClient->new('gate84213');
    $set3->($c3, 0, 0, 1);
    Plugins::SpotOn::Settings::Player->handler(
        $c3, { saveSettings => 1,
               has_enableSpotifyConnect => 1, pref_enableSpotifyConnect => 1,
               has_enableAutoplay => 1 },
        sub { }, undef, undef);
    is($get3->($c3), '1/0/0', '84-21 D-31(2): crash-loop form (no discovery marker) leaves disableDiscovery, turns autoplay off, Connect on');

    # discovery marker with the box checked / unchecked
    my $c4 = MockClient->new('gate84214');
    $set3->($c4, 1, 1, 1);
    Plugins::SpotOn::Settings::Player->handler(
        $c4, { saveSettings => 1, has_enableDiscovery => 1, pref_enableDiscovery => 1 }, sub { }, undef, undef);
    is($get3->($c4), '1/0/1', '84-21 D-31(2): discovery marker + checked box clears disableDiscovery, others untouched');
    Plugins::SpotOn::Settings::Player->handler(
        $c4, { saveSettings => 1, has_enableDiscovery => 1 }, sub { }, undef, undef);
    is($get3->($c4), '1/1/1', '84-21 D-31(2): discovery marker + unchecked box sets disableDiscovery, others untouched');

    # template: one hidden presence field per rendered checkbox, same condition
    my $tpl = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html";
    my $html = do { open(my $fh, '<', $tpl) or die "$tpl: $!"; local $/; <$fh> };
    for my $n (qw(enableSpotifyConnect enableDiscovery enableAutoplay)) {
        like($html, qr/<input type="hidden" name="has_$n" value="1"\s*\/?>/,
            "84-21 D-31(2): player.html carries the hidden has_$n input");
    }
    # line-order assertions on the template text: the marker sits after the
    # condition's opener and no `[% END %]` closes it before the marker
    my $inside = sub {
        my ($opener, $marker) = @_;
        my $o = index($html, $opener);
        my $m = index($html, $marker);
        return 0 if $o < 0 || $m < $o;
        return index(substr($html, $o, $m - $o), '[% END %]') < 0 ? 1 : 0;
    };
    {
        # autoplay: the whole WRAPPER (its own END comes after the marker) sits inside the IF
        my $o = index($html, '[% IF canAutoplay %]');
        my $m = index($html, 'name="has_enableAutoplay"');
        my $c = index($html, 'name="pref_enableAutoplay"');
        ok($o >= 0 && $m > $o && $c > $o,
            '84-21 D-31(2): has_enableAutoplay and its checkbox both sit after the `[% IF canAutoplay %]` opener (same block)');
    }
    ok($inside->('[% UNLESS discoveryByCrashLoop %]', 'name="has_enableDiscovery"'),
        '84-21 D-31(2): has_enableDiscovery sits inside an open `[% UNLESS discoveryByCrashLoop %]` block');
}

# ============================================================
# Group C: i18n coverage — all 7 PLUGIN_SPOTON_STREAMING_MODE* keys exist
# with exactly the 11 required locale lines before the next blank line.
# ============================================================

subtest 'i18n: PLUGIN_SPOTON_STREAMING_MODE* keys have all 11 locales' => sub {
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";
    open(my $fh, '<', $strings_file) or BAIL_OUT("Cannot read strings.txt: $!");
    my @lines = <$fh>;
    close($fh);

    my @required_keys = qw(
        PLUGIN_SPOTON_STREAMING_MODE
        PLUGIN_SPOTON_STREAMING_MODE_DESC
        PLUGIN_SPOTON_STREAMING_MODE_DIRECT
        PLUGIN_SPOTON_STREAMING_MODE_PROXY
        PLUGIN_SPOTON_STREAMING_MODE_USE_GLOBAL
        PLUGIN_SPOTON_STREAMING_MODE_GLOBAL
        PLUGIN_SPOTON_STREAMING_MODE_GLOBAL_DESC
    );
    my @required_locales = sort qw(CS DA DE EN ES FR IT NL NO PL SV);

    for my $key (@required_keys) {
        my $found_idx;
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            chomp $line;
            if ($line eq $key) {
                $found_idx = $i;
                last;
            }
        }
        ok(defined $found_idx, "i18n: $key exists as a line-anchored key header");
        next unless defined $found_idx;

        my %locales_seen;
        my $i = $found_idx + 1;
        while ($i <= $#lines) {
            my $line = $lines[$i];
            chomp $line;
            last if $line eq '';
            if ($line =~ /^\t([A-Z]{2})\t/) {
                $locales_seen{$1} = 1;
            }
            $i++;
        }
        is(join(',', sort keys %locales_seen), join(',', @required_locales),
            "i18n: $key has exactly the 11 required locale lines");
    }
};

done_testing();
