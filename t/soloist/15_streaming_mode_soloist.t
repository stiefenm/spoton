#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: soloist half of t/15_streaming_mode.t --
# 83.3-02 per-player soloistQuality and the 84-13 render cells over the REAL
# Backend::Soloist role)
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
# 74b-02: effectiveOutput seam for the Settings::Player render cells. A
# hashref answers as the resolver would; a plain string makes the call die;
# undef answers undef (every pre-74b cell, which never set it).
our $EFFECTIVE;
sub effectiveOutput {
    my ($class, $c) = @_;
    die $EFFECTIVE if defined $EFFECTIVE && !ref $EFFECTIVE;
    return $EFFECTIVE;
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

# Stub: Slim::Utils::OSDetect -- Quality.pm::deviceIdForMac runtime-requires
# the REAL Plugins::SpotOn::Soloist, whose `use Slim::Utils::OSDetect`
# (Soloist.pm:40) must resolve without a system LMS in @INC (CI has none; the
# 84-10 CI follow-up found it loading from /usr/share/perl5 locally). Same
# shape as t/librespot/51's stub.
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
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
# Group B.1: 83.3-02 (D-12/D-13) -- REAL Settings::Player->handler() execution
# for the per-player soloistQuality override. Unlike Group B's regex-only
# copies above, this loads and calls the actual handler. Quality.pm's
# applyChange() is glob-overridden with a counter (same technique as
# t/09_settings.t's global-scope soloistQuality test) so no network stub
# chain is needed.
# ============================================================
SKIP: {
    my $player_module = "$project_dir/Plugins/SpotOn/Settings/Player.pm";
    skip "Settings/Player.pm not yet updated with soloistQuality handler", 5
        unless -f $player_module && do {
            open(my $fh, '<', $player_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /pref_soloistQuality/;
        };

    skip "Settings::Player and Quality.pm required for per-player soloistQuality test", 5
        unless eval { require Plugins::SpotOn::Settings::Player; require Plugins::SpotOn::Soloist::Quality; 1 };

    no warnings 'redefine', 'once';
    my $apply_calls = 0;
    local *Plugins::SpotOn::Soloist::Quality::applyChange = sub { $apply_calls++; };
    # 84-13 Task 2: the per-player quality save goes through the player's
    # backend role (backendFor($client)->qualityInfo / ->quality) -- these
    # cells run with the Soloist role active.
    local $Plugins::SpotOn::Unified::DaemonManager::BACKEND = 'Plugins::SpotOn::Backend::Soloist';

    my $qClient = MockClient->new('gateQ1');
    $prefs->client($qClient)->set('soloistQuality', 'global');

    $apply_calls = 0;
    Plugins::SpotOn::Settings::Player->handler(
        $qClient, { saveSettings => 1, pref_soloistQuality => '5' },
        sub { }, undef, undef
    );
    is($prefs->client($qClient)->get('soloistQuality'), 5, "83.3-02: per-player handler persists valid value '5'");
    is($apply_calls, 1, '83.3-02: per-player handler calls applyChange once on a real change');

    $apply_calls = 0;
    Plugins::SpotOn::Settings::Player->handler(
        $qClient, { saveSettings => 1, pref_soloistQuality => '6' },
        sub { }, undef, undef
    );
    is($prefs->client($qClient)->get('soloistQuality'), 'global',
        "83.3-02: per-player handler falls back to 'global' for an invalid select value ('6' is never posted)");

    $apply_calls = 0;
    Plugins::SpotOn::Settings::Player->handler(
        $qClient, { saveSettings => 1, pref_soloistQuality => 'global' },
        sub { }, undef, undef
    );
    is($apply_calls, 0, "83.3-02: posting 'global' when already 'global' does not call applyChange (change-detect)");

    $apply_calls = 0;
    Plugins::SpotOn::Settings::Player->handler(
        $qClient, { saveSettings => 1, pref_soloistQuality => '4' },
        sub { }, undef, undef
    );
    is($apply_calls, 1, '83.3-02: changing away from global calls applyChange once');
}

# ============================================================
# 84-13 Task 2 (SEAM-6.2, D-17 second half): Settings::Player renders the
# per-player quality block from backendFor($client)->qualityInfo($client)
# and the autoplay flag from ->capabilities->{autoplay}; it names no
# backend package (Soloist::Quality, Helper) itself.
# ============================================================
SKIP: {
    skip "Settings::Player required for the 84-13 render cells", 7
        unless eval { require Plugins::SpotOn::Settings::Player; require Plugins::SpotOn::Backend; 1 };

    no warnings 'redefine', 'once';
    local $Plugins::SpotOn::Unified::DaemonManager::BACKEND = 'Plugins::SpotOn::Backend::Soloist';
    require Plugins::SpotOn::Backend::Soloist;
    my @qi;
    my $QI = { supported => 1, validLevels => [0, 2, 3, 4, 5],
               levels => [ { value => 0, label => 'L0' }, { value => 5, label => 'L5' } ],
               stored => 'global', storedLabel => '', effective => 4, effectiveLabel => 'L4',
               differs => 1, deviceKnown => 1, noticeText => 'NOTICE-FROM-ROLE' };
    local *Plugins::SpotOn::Backend::Soloist::qualityInfo = sub { push @qi, $_[1]; return { %$QI } };
    local *Plugins::SpotOn::Backend::Soloist::capabilities = sub { return { autoplay => 1 } };
    $prefs->set('backend', 'soloist');

    my $rc = MockClient->new('gate8413r1');
    my $p = {};
    my $lived = eval { Plugins::SpotOn::Settings::Player->handler($rc, $p, sub { }, undef, undef); 1 };
    ok($lived, '84-13: soloist player page renders') or diag($@);
    is(scalar(@qi), 1, '84-13: the render asks the role qualityInfo($client) once');
    is_deeply($p->{soloistQualityLevels}, $QI->{levels}, '84-13: levels/labels come from qualityInfo');
    is($p->{soloistQualityEffective}, 4, '84-13: effective level from qualityInfo');
    is($p->{soloistQualityEffectiveLabel}, 'L4', '84-13: effective label from qualityInfo');
    is($p->{soloistQualityNotice}, 'NOTICE-FROM-ROLE', '84-13: noticeText from qualityInfo (formatted in the role)');
    is($p->{canAutoplay}, 1, '84-13: canAutoplay from backendFor($client)->capabilities->{autoplay}');
    # (84-09: the two librespot-player-page cells of this block need the REAL
    # Backend::Librespot and live in t/librespot/15_streaming_mode_librespot.t)

}

# ============================================================
# 74b-02 Task 1 (D-08, D-10, D-15, D-11/D-18): Settings::Player prints what the
# player really receives. The texts come from the REAL strings.txt (EN values);
# the resolver answer is the effectiveOutput seam of the DaemonManager mock
# (the resolver itself is proven in t/soloist/59_effective_output.t).
# ============================================================
SKIP: {
    skip "Settings::Player required for the 74b-02 render cells", 23
        unless eval { require Plugins::SpotOn::Settings::Player; require Plugins::SpotOn::Backend; 1 };

    no warnings 'redefine', 'once';

    # EN texts straight from strings.txt: "KEY" line, then "\tEN\tvalue".
    my %EN;
    {
        open(my $fh, '<:encoding(UTF-8)', "$project_dir/Plugins/SpotOn/strings.txt") or die "strings.txt: $!";
        my $key = '';
        while (my $l = <$fh>) {
            chomp $l;
            if ($l =~ /^(PLUGIN_SPOTON_\w+)$/) { $key = $1; next }
            $EN{$key} = $1 if $key && $l =~ /^\tEN\t(.*)$/;
        }
    }
    # Expected texts: a key missing from strings.txt must fail the cell, never
    # compare undef with undef.
    my $X = sub { defined $EN{$_[0]} ? $EN{$_[0]} : "<<no such string $_[0]>>" };
    my $FLAC = $X->('PLUGIN_SPOTON_STREAM_FORMAT_FLAC');
    ok(defined $EN{"PLUGIN_SPOTON_STREAM_FORMAT_$_"}, "74b-02: strings.txt has an EN value for PLUGIN_SPOTON_STREAM_FORMAT_$_")
        for qw(LINE VIA_DIRECT VIA_PROXY REASON_NO_FLC REASON_NO_LAME REASON_RULE MP3_NOTE);
    local *Plugins::SpotOn::Settings::Player::string = sub { $EN{$_[0]} // "MISSING:$_[0]" };

    local $Plugins::SpotOn::Unified::DaemonManager::BACKEND = 'Plugins::SpotOn::Backend::Soloist';
    require Plugins::SpotOn::Backend::Soloist;
    my $QI = { supported => 1, validLevels => [0, 2, 3, 4, 5], levels => [], stored => 'global',
               storedLabel => '', effective => undef, effectiveLabel => '', differs => 0,
               deviceKnown => 1, noticeText => '', wanted => 0 };
    local *Plugins::SpotOn::Backend::Soloist::qualityInfo = sub { return { %$QI } };
    local *Plugins::SpotOn::Backend::Soloist::capabilities = sub { return { autoplay => 1 } };
    $prefs->set('backend', 'soloist');

    my $n = 0;
    my $render = sub {
        my ($choice, $eff, $wanted, $supported) = @_;
        my $c = MockClient->new('gate74b02x' . $n++);
        $prefs->client($c)->set('streamFormat', $choice);
        local $Plugins::SpotOn::Unified::DaemonManager::EFFECTIVE = $eff;
        local $QI->{wanted}    = $wanted // 0;
        local $QI->{supported} = defined $supported ? $supported : 1;
        my $p = {};
        my $lived = eval { Plugins::SpotOn::Settings::Player->handler($c, $p, sub { }, undef, undef); 1 };
        return ($p, $lived, $@);
    };

    # D-22: an flc player on Auto while AUTO_FLAC is 0 -> PCM via proxy
    my ($p, $lived, $err) = $render->('auto', { chosen => 'auto', resolved => 'flac', effective => 'pcm', type => 'soc', path => 'proxy', reason => '' });
    ok($lived, '74b-02: page renders with an effectiveOutput answer') or diag($err);
    is($p->{streamFormatEffective}, 'This player receives: Automatic -> PCM via proxy',
        '74b-02 D-08/D-22: Auto on an flc player (AUTO_FLAC 0) reads Auto -> PCM via proxy');
    ok(!exists $p->{streamFormatReason} || $p->{streamFormatReason} eq '', '74b-02: no reason for a honoured Auto');
    ok(!$p->{streamFormatNote}, '74b-02: no MP3 note for PCM');

    # after the 74b-06 flip
    ($p) = $render->('auto', { chosen => 'auto', resolved => 'flac', effective => 'flac', type => 'sof', path => 'proxy', reason => '' });
    is($p->{streamFormatEffective}, "This player receives: Automatic -> $FLAC via proxy",
        '74b-02 D-08: Auto after the flip reads Auto -> <FLAC label> via proxy');

    # direct path word
    ($p) = $render->('pcm', { chosen => 'pcm', resolved => 'pcm', effective => 'pcm', type => 'soc', path => 'direct', reason => '' });
    is($p->{streamFormatEffective}, 'This player receives: PCM -> PCM direct', '74b-02: path direct prints the direct word');

    # path none: no path word and no trailing blank
    ($p) = $render->('pcm', { chosen => 'pcm', resolved => 'pcm', effective => 'pcm', type => 'soc', path => 'none', reason => '' });
    is($p->{streamFormatEffective}, 'This player receives: PCM -> PCM', '74b-02: path none prints no path word');

    # D-15: explicit FLAC degraded
    ($p) = $render->('flac', { chosen => 'flac', resolved => 'pcm', effective => 'pcm', type => 'soc', path => 'proxy', reason => 'flac_no_flc' });
    is($p->{streamFormatReason}, $X->('PLUGIN_SPOTON_STREAM_FORMAT_REASON_NO_FLC'), '74b-02 D-15: flac_no_flc -> the NO_FLC text');
    like($p->{streamFormatReason}, qr/^FLAC not possible: the player has no FLAC, sending PCM$/, '74b-02 D-15: the page says so, no error wording');
    is($p->{streamFormatEffective}, "This player receives: $FLAC -> PCM via proxy", '74b-02 D-15: the chosen label is the FLAC option label (its text, FLAC 16, is pinned in t/core/02_strings.t)');

    # D-10: MP3 without lame stays selectable, the page asks to install it
    ($p) = $render->('mp3', { chosen => 'mp3', resolved => 'mp3', effective => 'mp3', type => 'smp', path => 'proxy', reason => 'no_lame' });
    is($p->{streamFormatReason}, $X->('PLUGIN_SPOTON_STREAM_FORMAT_REASON_NO_LAME'), '74b-02 D-10: no_lame -> the NO_LAME text');
    is($p->{streamFormat}, 'mp3', '74b-02 D-10: the MP3 choice is kept (no fallback)');

    # rule_unavailable names the effective label
    ($p) = $render->('flac', { chosen => 'flac', resolved => 'flac', effective => 'flac', type => 'sof', path => 'proxy', reason => 'rule_unavailable' });
    is($p->{streamFormatReason}, sprintf($X->('PLUGIN_SPOTON_STREAM_FORMAT_REASON_RULE'), $FLAC),
        '74b-02: rule_unavailable -> REASON_RULE naming the effective label');

    # D-11/D-18 MP3 note matrix
    my $mp3 = { chosen => 'mp3', resolved => 'mp3', effective => 'mp3', type => 'smp', path => 'proxy', reason => '' };
    ($p) = $render->('mp3', $mp3, 5);
    is($p->{streamFormatNote}, $X->('PLUGIN_SPOTON_STREAM_FORMAT_MP3_NOTE'), '74b-02 D-11: mp3 + explicit Lossless (5) -> note');
    ($p) = $render->('mp3', $mp3, 4);
    is($p->{streamFormatNote}, $X->('PLUGIN_SPOTON_STREAM_FORMAT_MP3_NOTE'), '74b-02 D-11: mp3 + Very high (4) -> note');
    ($p) = $render->('mp3', $mp3, 0);
    ok(!$p->{streamFormatNote}, '74b-02 D-18: mp3 + Automatic (0) -> no note');
    ($p) = $render->('flac', { chosen => 'flac', resolved => 'flac', effective => 'flac', type => 'sof', path => 'proxy', reason => '' }, 5);
    ok(!$p->{streamFormatNote}, '74b-02 D-11: effective flac + Lossless -> no note');
    ($p) = $render->('mp3', $mp3, 5, 0);
    ok(!$p->{streamFormatNote}, '74b-02: librespot-style qualityInfo (supported 0) -> no note');

    # a failing resolver read must not take the page down
    ($p, $lived, $err) = $render->('auto', 'effectiveOutput boom');
    ok($lived, '74b-02: a dying effectiveOutput still returns the page') or diag($err);
    ok(!defined $p->{streamFormatEffective}, '74b-02: ... without the effective-format line');

    # D-06 (negative): the template gains no backend field, prints the new params through html
    open(my $th, '<', "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html") or die $!;
    my $tpl = do { local $/; <$th> };
    close $th;
    my @new = $tpl =~ /\[%\s*(streamFormat(?:Effective|Reason|Note))\s*\|\s*html\s*%\]/g;
    is_deeply([ sort @new ], [ qw(streamFormatEffective streamFormatNote streamFormatReason) ],
        '74b-02: the template prints the three new params through the html filter');
    unlike($tpl, qr/pref_backend/, '74b-02 D-06: the player page gains no backend field');
}

done_testing();
