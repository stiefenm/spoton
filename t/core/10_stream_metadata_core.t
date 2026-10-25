#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: core half of t/10_stream_metadata.t; the two
# passthrough=1 cells that need the real Backend::Librespot capability live in
# t/librespot/10_stream_metadata_librespot.t)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# 79-25 (D-08, NA-x): which backend-side leg is this tree? The committed manifests
# tools/ci/amputation/<side>.files (entries under Plugins/SpotOn/) are the single source:
# all paths present = normal tree ('present'), none present = that side was removed on purpose
# ('amputated', the CI amputation leg), some present = broken checkout (die, never skip).
sub amputation_state {
    my ($root, $side) = @_;
    my $manifest = "$project_dir/tools/ci/amputation/$side.files";
    open(my $mfh, '<', $manifest)
        or die "$manifest: $! -- wrong project root or broken checkout (die, never skip)\n";
    my @paths;
    while (my $line = <$mfh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        next unless $line =~ m{^Plugins/SpotOn/};
        $line =~ s{/+\z}{};
        push @paths, $line;
    }
    close($mfh);
    die "$manifest holds no Plugins/SpotOn entries -- wrong project root or broken checkout (die, never skip)\n"
        unless @paths;
    my $here = grep { -e "$root/$_" } @paths;
    return 'present'   if $here == @paths;
    return 'amputated' if $here == 0;
    die "partial $side side ($here of " . scalar(@paths) . " paths present) -- broken checkout (die, never skip)\n";
}

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

# Stub: Slim::Utils::Log (exports logger() for all consumers)
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use Exporter 'import';
our @EXPORT = qw(logger logWarning logError logBacktrace);
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless { _calls => [] }, 'Slim::Utils::Log' }
sub logWarning { }
sub logError   { }
sub logBacktrace { }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
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

# Stub: Slim::Utils::Versions (needed by ProtocolHandler.pm; CI has no LMS tree)
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

# Stub: JSON::XS (Plugin.pm uses 'use JSON::XS qw(encode_json)')
# JSON::XS is an XS module bundled by LMS but not available in the test env.
# Delegate to JSON::PP (pure-Perl equivalent) so stubs stay test-env clean.
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
# 74b-02: counting checkBin. It reports lame as missing, like a server without
# the tool; the label path must never reach it (a diagnosis per menu item
# would log one warning per item).
our $checkBinCalls = 0;
sub checkBin { $checkBinCalls++; $@ = 'lame'; return 0 }
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

# Stub: Slim::Utils::Accessor — hash-based replacement for LMS array-based accessor
# Needed when Daemon.pm is loaded via DaemonManager.pm cascade
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { return bless {}, ref($_[0]) || $_[0] }
sub mk_accessor {
    my $class = shift;
    my $type  = shift;
    for my $attr (@_) {
        no strict 'refs';
        *{"${class}::${attr}"} = sub {
            $_[0]->{$attr} = $_[1] if @_ > 1;
            return $_[0]->{$attr};
        };
    }
}
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP — DaemonManager.pm uses at module level
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

# Stub: Slim::Player::Sync — resolver uses slaves() for D-08 sync-group aggregation
write_stub($stub_dir, 'Slim::Player::Sync', <<'END');
package Slim::Player::Sync;
our %_slaves;
sub slaves {
    my $master = shift;
    my $id = "$master";
    return @{ $_slaves{$id} // [] };
}
sub isSlave  { 0 }
sub syncname { ref $_[0] ? "$_[0]" : ($_[0] // '') }
1;
END

# Stub: Slim::Utils::Network — Daemon.pm start() references serverAddr
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

# Stub: Slim::Player::Client — DaemonManager runtime calls (not needed for resolver)
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { undef }
sub clients   { () }
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

# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($stub_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# resolvePassthroughForClient reads backendClass()->capabilitiesDefault;
# the mock answers the Helper stub's passthrough capability, so the player /
# sync-group cells below exercise DaemonManager's resolver, not the role.
# 74b-02: ProtocolHandler->contentTypeFor names the resolver from this key and
# ProtocolHandler::contentType reads contentType; the values mirror the real
# Backend::Librespot (son, resolvePassthroughForClient).
sub capabilitiesDefault { return { passthrough => (Plugins::SpotOn::Helper->getCapability('passthrough') ? 1 : 0), formats => 'resolvePassthroughForClient', contentType => 'son' } }
sub binaryPath { return '/usr/bin/false' }
sub daemonClass { return 'Plugins::SpotOn::Unified::Daemon' }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# 74b-02: the values mirror the real Backend::Soloist (soc, resolveSoloistFormat).
sub capabilitiesDefault { return { formats => 'resolveSoloistFormat', contentType => 'soc' } }
sub binaryPath { return undef }
sub daemonClass { return 'Plugins::SpotOn::Unified::SoloistDaemon' }
1;
END

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load the Helper stub so _typeString's require finds the stub, not the real module.
# The stub uses a package variable ($helperCapabilities) that tests can control.
require Plugins::SpotOn::Helper;

# Pre-load Slim::Player::Sync stub so the resolver's sync-group iteration works.
# The stub provides a controllable slaves() function for D-08 sync-group tests.
require Slim::Player::Sync;

# ============================================================
# Load Plugin.pm
# ============================================================
require_ok('Plugins::SpotOn::Plugin') or BAIL_OUT("Failed to load Plugin.pm");

# ============================================================
# Mock client object
# ============================================================
# A blessed hashref that the Prefs stub can stringify for client() namespace.
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} }, fallback => 1;
    our %_model;    # id => model string, default 'squeezelite'
    our %_formats;  # id => arrayref, default ['ogg','pcm','flc','mp3'] (LMS' FLAC code is 'flc', not 'flac')
    our %_synced;   # id => boolean
    our %_master;   # id => MockClient instance or undef
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    sub can {
        my ($self, $method) = @_;
        return 1 if $method eq 'master' && $_master{${$self}};
        return 0;
    }
    sub model   { return $_model{${$_[0]}}   // 'squeezelite' }
    sub formats { return @{ $_formats{${$_[0]}} // ['ogg','pcm','flc','mp3'] } }
    sub isSynced { return $_synced{${$_[0]}} // 0 }
    sub master  { return $_master{${$_[0]}} }
    sub playingSong { undef }
}

# ============================================================
# Helper to set prefs for a test case
# ============================================================
sub setup_prefs {
    my (%opts) = @_;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    # Global prefs
    $prefs->set('bitrate', $opts{bitrate}) if exists $opts{bitrate};

    # Per-player prefs (if client provided)
    if ($opts{client}) {
        my $cp = $prefs->client($opts{client});
        $cp->set('bitrateOverride', $opts{bitrateOverride}) if exists $opts{bitrateOverride};
        $cp->set('streamFormat', $opts{streamFormat}) if exists $opts{streamFormat};
        $cp->set('connectOggOverride', $opts{connectOggOverride}) if exists $opts{connectOggOverride};

        # MockClient per-instance state (keyed by stringified client id)
        my $id = "${$opts{client}}";
        $MockClient::_model{$id}   = $opts{model}   if exists $opts{model};
        $MockClient::_formats{$id} = $opts{formats}  if exists $opts{formats};
        $MockClient::_synced{$id}  = $opts{synced}   if exists $opts{synced};
        $MockClient::_master{$id}  = $opts{master_client} if exists $opts{master_client};

        # Slim::Player::Sync slave list for sync-group tests (D-08)
        if (exists $opts{sync_slaves}) {
            $Slim::Player::Sync::_slaves{$id} = $opts{sync_slaves};
        }
    }

    # Helper passthrough capability
    if (exists $opts{passthrough}) {
        $Plugins::SpotOn::Helper::helperCapabilities = { passthrough => $opts{passthrough} };
    }
}


# ============================================================
# 74b-02 Task 2: reachability. _typeString now labels from
# DaemonManager->effectiveFormat -> ProtocolHandler->contentTypeFor, which
# names its resolver from backendClass->capabilitiesDefault->{formats}. The
# REAL chain must be reachable with the two role mocks of this file: this cell
# calls effectiveFormat itself (not through _typeString, whose eval would turn
# a die into a silent PCM label) and puts any die text into the message.
# ============================================================
{
    my $prefs_r = Slim::Utils::Prefs::preferences('plugin.spoton');
    # Plugin.pm requires DaemonManager lazily (inside _typeString); load it
    # the same way and surface a load failure in the cell message.
    my $loaded = eval { require Plugins::SpotOn::Unified::DaemonManager; 1 };
    ok($loaded, '74b-02 reachability: the real DaemonManager (and with it the real ProtocolHandler) loads in this harness') or diag($@);

    my $sc = MockClient->new('reach_soloist');
    setup_prefs(client => $sc, streamFormat => 'flac', formats => ['flc', 'pcm']);
    $prefs_r->set('backend', 'soloist');
    my @r = eval { Plugins::SpotOn::Unified::DaemonManager->effectiveFormat($sc) };
    my $died = $@ ? "died: $@" : 'no die';
    is_deeply(\@r, ['flac', 'sof', 'resolveSoloistFormat', 'flac'],
        "74b-02 reachability: effectiveFormat on a Soloist client with flc and streamFormat=flac ($died)");

    $prefs_r->set('backend', 'librespot');
    my $lc = MockClient->new('reach_librespot');
    setup_prefs(client => $lc, streamFormat => 'auto', passthrough => 1);
    @r = eval { Plugins::SpotOn::Unified::DaemonManager->effectiveFormat($lc) };
    $died = $@ ? "died: $@" : 'no die';
    is($r[2], 'resolvePassthroughForClient',
        "74b-02 reachability: effectiveFormat under librespot names resolvePassthroughForClient ($died)");
}

# ============================================================
# Test 2: _typeString with streamFormat=flac, mode=Connect
# ============================================================
{
    my $client = MockClient->new('player_flac');
    setup_prefs(
        client       => $client,
        streamFormat => 'flac',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Connect');
    is($result, 'FLAC, SpotOn Connect',
        'META-02: streamFormat=flac => "FLAC, SpotOn Connect"');
}

# ============================================================
# Test 3: _typeString with streamFormat=mp3
# ============================================================
{
    my $client = MockClient->new('player_mp3');
    setup_prefs(
        client       => $client,
        streamFormat => 'mp3',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'MP3, SpotOn Browse',
        'META-02: streamFormat=mp3 => "MP3, SpotOn Browse"');
}

# ============================================================
# Test 4: _typeString with streamFormat=pcm
# ============================================================
{
    my $client = MockClient->new('player_pcm');
    setup_prefs(
        client       => $client,
        streamFormat => 'pcm',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'META-02: streamFormat=pcm => "PCM, SpotOn Browse"');
}


# ============================================================
# 74b-02 Task 2: labels come from the playback mapping (effectiveFormat), so a
# degraded FLAC choice and Auto before the flip are labelled PCM. Real
# DaemonManager + ProtocolHandler; the only overrides are the D-22 staging seam
# and the one dying effectiveFormat of the eval-fallback cell.
# ============================================================
{
    my $prefs_l = Slim::Utils::Prefs::preferences('plugin.spoton');
    $prefs_l->set('backend', 'librespot');
    # load the counting checkBin stub so its counter is defined (and so
    # DaemonManager::effectiveOutput, were it reached, would find a checkBin)
    require Slim::Player::TranscodingHelper;
    $Slim::Player::TranscodingHelper::checkBinCalls = 0;

    # D-15, librespot: explicit FLAC on a client without flc is PCM
    my $noflc = MockClient->new('lbl_noflc');
    setup_prefs(client => $noflc, streamFormat => 'flac', formats => ['ogg', 'pcm', 'mp3']);
    is(Plugins::SpotOn::Plugin->_typeString($noflc, 'Connect'), 'PCM, SpotOn Connect',
        '74b-02 D-15: streamFormat=flac on a client without flc => "PCM, SpotOn Connect" (librespot)');

    # D-15, soloist
    $prefs_l->set('backend', 'soloist');
    is(Plugins::SpotOn::Plugin->_typeString($noflc, 'Connect'), 'PCM, SpotOn Connect',
        '74b-02 D-15: streamFormat=flac on a client without flc => "PCM, SpotOn Connect" (soloist)');

    my $flc = MockClient->new('lbl_flc');
    setup_prefs(client => $flc, streamFormat => 'flac', formats => ['pcm', 'flc']);
    is(Plugins::SpotOn::Plugin->_typeString($flc, 'Connect'), 'FLAC, SpotOn Connect',
        '74b-02 D-15: streamFormat=flac on a client with flc => "FLAC, SpotOn Connect" (soloist)');

    # D-22: Auto on a Soloist client with flc follows the staging seam (local
    # override; no cell reads the shipped constant)
    my $auto = MockClient->new('lbl_auto');
    setup_prefs(client => $auto, streamFormat => 'auto', formats => ['pcm', 'flc']);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 0 };
        is(Plugins::SpotOn::Plugin->_typeString($auto, 'Browse'), 'PCM, SpotOn Browse',
            '74b-02 D-22: Auto on a Soloist client with flc while autoFlacEnabled is 0 => "PCM, SpotOn Browse"');
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 1 };
        is(Plugins::SpotOn::Plugin->_typeString($auto, 'Browse'), 'FLAC, SpotOn Browse',
            '74b-02 D-22: Auto on a Soloist client with flc while autoFlacEnabled is 1 => "FLAC, SpotOn Browse"');
    }

    # explicit mp3 and pcm under soloist
    my $mp3 = MockClient->new('lbl_mp3');
    setup_prefs(client => $mp3, streamFormat => 'mp3', formats => ['pcm', 'flc', 'mp3']);
    is(Plugins::SpotOn::Plugin->_typeString($mp3, 'Browse'), 'MP3, SpotOn Browse', '74b-02: soloist mp3 => "MP3, SpotOn Browse"');
    my $pcm = MockClient->new('lbl_pcm');
    setup_prefs(client => $pcm, streamFormat => 'pcm', formats => ['pcm', 'flc', 'mp3']);
    is(Plugins::SpotOn::Plugin->_typeString($pcm, 'Browse'), 'PCM, SpotOn Browse', '74b-02: soloist pcm on an flc player => "PCM, SpotOn Browse"');

    # librespot ogg with passthrough is unchanged
    $prefs_l->set('backend', 'librespot');
    my $ogg = MockClient->new('lbl_ogg');
    setup_prefs(client => $ogg, streamFormat => 'ogg', passthrough => 1);
    is(Plugins::SpotOn::Plugin->_typeString($ogg, 'Browse'), 'OGG, SpotOn Browse',
        '74b-02: librespot ogg with passthrough => "OGG, SpotOn Browse" (unchanged)');

    # undef client
    is(Plugins::SpotOn::Plugin->_typeString(undef, 'Browse'), 'PCM, SpotOn Browse', '74b-02: undef client => "PCM, SpotOn Browse"');

    # a dying effectiveFormat falls back to PCM
    {
        no warnings 'redefine', 'once';
        local *Plugins::SpotOn::Unified::DaemonManager::effectiveFormat = sub { die "boom\n" };
        is(Plugins::SpotOn::Plugin->_typeString($flc, 'Browse'), 'PCM, SpotOn Browse',
            '74b-02: a dying effectiveFormat => "PCM, SpotOn Browse" (eval fallback)');
    }

    # No diagnosis per menu item: the counting checkBin saw none of the label
    # cells above (lame is "missing" there, a warning per item would follow).
    is($Slim::Player::TranscodingHelper::checkBinCalls, 0,
        '74b-02: no checkBin call while labelling (mp3 with lame missing included)');
}


# ============================================================
# Test 6: _typeString with streamFormat=auto + passthrough=0
# D-05: auto resolves to PCM when passthrough capability is false
# ============================================================
{
    my $client = MockClient->new('player_auto_nopt');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 0,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-05: streamFormat=auto + passthrough=0 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6a: Player without ogg in formats + auto + passthrough=1 => PCM
# D-04: passthrough requires ogg in player-announced formats
# ============================================================
{
    my $client = MockClient->new('player_hw_auto');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 1,
        model        => 'squeezebox2',
        formats      => ['pcm', 'flac', 'mp3'],
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04/OGG-02: player without ogg format + auto + passthrough=1 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6b: squeezelite + auto + passthrough=0 (binary lacks capability)
# ============================================================
{
    my $client = MockClient->new('player_sl_nopt');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 0,
        model        => 'squeezelite',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: squeezelite + auto + passthrough=0 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6c: squeezelite + auto + passthrough=1 but formats excludes ogg
# Simulates squeezelite started with -e ogg
# ============================================================
{
    my $client = MockClient->new('player_sl_noogg');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 1,
        model        => 'squeezelite',
        formats      => ['pcm', 'flac', 'mp3'],
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: squeezelite without ogg in formats + auto + passthrough=1 => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 6d: Sync-group mixed capability => PCM for entire group
# D-08: PCM fallback when any sync member cannot decode OGG
# ============================================================
{
    my $master_client = MockClient->new('player_sync_master');
    my $slave_client  = MockClient->new('player_sync_slave');

    # Master: squeezelite with OGG capability
    setup_prefs(
        client       => $master_client,
        streamFormat => 'auto',
        passthrough  => 1,
        model        => 'squeezelite',
        synced       => 1,
        master_client => $master_client,  # master points to itself
        sync_slaves  => [$slave_client],  # Slim::Player::Sync::slaves() returns this
    );
    # Slave: player without ogg format (not OGG-capable)
    setup_prefs(
        client       => $slave_client,
        streamFormat => 'auto',
        model        => 'squeezebox2',
        formats      => ['pcm', 'flac', 'mp3'],
        synced       => 1,
        master_client => $master_client,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($master_client, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-08: sync-group with mixed formats (squeezelite+ogg master + no-ogg slave) => "PCM, SpotOn Browse"');
}

# ============================================================
# Test 7: _typeString with undef client (global prefs only, no crash)
# D-04: undef client = unknown player = PCM (conservative default)
# ============================================================
{
    setup_prefs(
        passthrough => 1,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString(undef, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: undef client => PCM (unknown player, conservative default)');
}

# ============================================================
# Test 8: _bitrateForClient — bitrateOverride 160 overrides global 320
# D-07: per-player bitrateOverride takes precedence
# ============================================================
{
    my $client = MockClient->new('player_override');
    setup_prefs(
        bitrate         => 320,
        client          => $client,
        bitrateOverride => 160,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateForClient($client);
    is($result, 160,
        'D-07: bitrateOverride=160 overrides global 320');
}

# ============================================================
# Test 9: _bitrateForClient — defaults to global bitrate
# ============================================================
{
    my $client = MockClient->new('player_global');
    setup_prefs(
        bitrate         => 320,
        client          => $client,
        bitrateOverride => undef,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateForClient($client);
    is($result, 320,
        'D-07: no override => global bitrate 320');
}

# ============================================================
# Test 10: _bitrateForClient — undef client uses global
# ============================================================
{
    setup_prefs(
        bitrate => 96,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateForClient(undef);
    is($result, 96,
        'D-07: undef client => global bitrate 96');
}

# ============================================================
# Test 11: D-02 -- mode label always present (Browse)
# ============================================================
{
    my $client = MockClient->new('player_mode_browse');
    setup_prefs(
        bitrate      => 320,
        client       => $client,
        streamFormat => 'ogg',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    like($result, qr/SpotOn Browse$/,
        'D-02: mode label "SpotOn Browse" always present at end');
}

# ============================================================
# Test 12: D-02 -- mode label always present (Connect)
# ============================================================
{
    my $client = MockClient->new('player_mode_connect');
    setup_prefs(
        bitrate      => 320,
        client       => $client,
        streamFormat => 'ogg',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Connect');
    like($result, qr/SpotOn Connect$/,
        'D-02: mode label "SpotOn Connect" always present at end');
}

# ============================================================
# Grep Gate: no remaining literal "type => 'Spotify'" in Plugin.pm
# (excluding test files and comments)
# ============================================================
{
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";
    open(my $fh, '<', $plugin_file) or die "Cannot read Plugin.pm: $!";
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comments
        push @matches, $. if $line =~ /type\s*=>\s*'Spotify'/;
    }
    close($fh);
    is(scalar @matches, 0,
        "Grep gate: no remaining literal \"type => 'Spotify'\" in Plugin.pm (found at lines: "
        . join(', ', @matches) . ')');
}

# ============================================================
# Grep Gate: no remaining literal "type => 'Spotify'" in DontStopTheMusic.pm
# (excluding comments)
# ============================================================
{
    my $dstm_file = "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm";
    open(my $fh, '<', $dstm_file) or die "Cannot read DontStopTheMusic.pm: $!";
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comments
        push @matches, $. if $line =~ /type\s*=>\s*'Spotify'/;
    }
    close($fh);
    is(scalar @matches, 0,
        "Grep gate: no remaining literal \"type => 'Spotify'\" in DontStopTheMusic.pm (found at lines: "
        . join(', ', @matches) . ')');
}

# ============================================================
# Grep Gate: no remaining literal "Ogg Vorbis (Spotify)" in Connect.pm
# (excluding comments)
# ============================================================
{
    my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";
    open(my $fh, '<', $connect_file) or die "Cannot read Connect.pm: $!";
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comments
        push @matches, $. if $line =~ /Ogg Vorbis \(Spotify\)/;
    }
    close($fh);
    is(scalar @matches, 0,
        "Grep gate: no remaining literal \"Ogg Vorbis (Spotify)\" in Connect.pm (found at lines: "
        . join(', ', @matches) . ')');
}

# ============================================================
# 84-13 Task 2 (SEAM-6.2): the hourly orphan sweep. Its librespot half
# (Helper->get, unchanged core-to-core) sweeps the helper path; its Soloist
# half is a loop over Backend::available() -> classFor($_)->binaryPath that
# skips undef and the helper path already swept -- no `$INC{Soloist.pm}`
# guard, no backend package name in Plugin.pm. Registry and roles are
# doubles here (the real binaryPath answers are pinned in t/57).
# ============================================================
{
    package T10::SweepRoleL;
    sub binaryPath { return '/usr/bin/false' }    # == the Helper stub's get() path
    package T10::SweepRoleS;
    sub binaryPath { return '/fake/soloist/x86_64-linux/soloist' }
    package T10::SweepRoleU;
    sub binaryPath { return undef }
    package main;

    require Plugins::SpotOn::Backend;
    require Slim::Player::Client;     # the stub: clients() -> () (no busy player)
    require Slim::Utils::Timers;
    my @swept;
    my @available;
    my %class = (librespot => 'T10::SweepRoleL', soloist => 'T10::SweepRoleS', none => 'T10::SweepRoleU');
    no warnings 'redefine', 'once';
    local *Plugins::SpotOn::Plugin::_killOrphansForBinary = sub { push @swept, $_[0] };
    local *Plugins::SpotOn::Backend::available = sub { return @available };
    local *Plugins::SpotOn::Backend::classFor  = sub { my $n = @_ > 1 ? $_[1] : $_[0]; return $class{$n} };
    local *Plugins::SpotOn::Backend::Soloist::binaryPath = sub { return '/fake/soloist/x86_64-linux/soloist' };
    local *Plugins::SpotOn::Soloist::installedBinaryPath = sub { return '/fake/soloist/x86_64-linux/soloist' };
    local $INC{'Plugins/SpotOn/Soloist.pm'} = $INC{'Plugins/SpotOn/Soloist.pm'};

    @available = qw(librespot soloist); @swept = ();
    Plugins::SpotOn::Plugin->_killOrphanedProcesses();
    is_deeply(\@swept, [ '/usr/bin/false', '/fake/soloist/x86_64-linux/soloist' ],
        '84-13 sweep: both backends available -> helper path once (librespot half), Soloist binaryPath once (available() loop)');

    @available = qw(librespot); @swept = ();
    delete $INC{'Plugins/SpotOn/Soloist.pm'};
    Plugins::SpotOn::Plugin->_killOrphanedProcesses();
    is_deeply(\@swept, [ '/usr/bin/false' ], '84-13 sweep: only librespot available -> exactly one sweep (the helper path)');

    @available = qw(librespot soloist none); @swept = ();
    $INC{'Plugins/SpotOn/Soloist.pm'} = 'stub';
    Plugins::SpotOn::Plugin->_killOrphanedProcesses();
    is(scalar(grep { $_ eq '/usr/bin/false' } @swept), 1, '84-13 sweep: the helper path is never swept twice');
    ok(!(grep { !defined } @swept), '84-13 sweep: an undef binaryPath is skipped');
}

# ============================================================
# 85-07 D-11: metadata only via spclient; only a real HTTP 404 fails seek
# closed. Source gates over the three senders of noteMetadataMissing (the
# behavioural cases live in t/soloist/29 and t/soloist/44).
# ============================================================
{
    my $slurp = sub { open(my $fh, '<', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close($fh); return $t };
    my $ph = $slurp->("$project_dir/Plugins/SpotOn/ProtocolHandler.pm");
    my ($defLine) = $ph =~ /^(.*\bmy \$definitive\b.*)$/m;
    ok(defined $defLine && $defLine =~ /== 404/ && $defLine !~ /== 400|invalid_id/,
        "85-07 D-11: ProtocolHandler's notify classifier is the real 404 alone (400 / invalid_id keep only the 60s negative cache)");
    like($ph, qr/\$code == 400 \|\| \$reason eq 'invalid_id'/, "85-07 D-11: the 60s negative-cache classifier still covers 400 and invalid_id");
    unlike($ph, qr/fallback source|both sources/, "85-07 D-11: ProtocolHandler no longer talks about a fallback metadata source");

    # 79-25 (NA-3): Control.pm belongs to the soloist side. On the soloist-removed CI leg it is
    # gone on purpose; the cell then asserts the absence (same cell count, nothing skipped). A
    # tree missing only Control.pm is a broken checkout and dies in amputation_state().
    my $soloist_state = amputation_state($project_dir, 'soloist');
    # the manifest lists Soloist/ as a directory, so a tree that lost only Control.pm still counts
    # the directory as present: the file this cell reads is checked on its own
    die "partial soloist side (Plugins/SpotOn/Soloist/Control.pm missing, the rest present) -- broken checkout (die, never skip)\n"
        if $soloist_state eq 'present' && !-f "$project_dir/Plugins/SpotOn/Soloist/Control.pm";
    if ($soloist_state eq 'present') {
        my $ctl = $slurp->("$project_dir/Plugins/SpotOn/Soloist/Control.pm");
        my ($tMeta) = $ctl =~ /(^sub _tMetaFire\b.*?^\})/ms;
        ok(defined $tMeta && $tMeta !~ /noteMetadataMissing/, "85-07 D-11: Control::_tMetaFire does not disable seek");
    }
    else {
        ok(!-e "$project_dir/Plugins/SpotOn/Soloist/Control.pm",
            "85-07 D-11: soloist side amputated -- Control.pm is not in this tree (leg check)");
    }

    my $sp = $slurp->("$project_dir/Plugins/SpotOn/API/SpClient.pm");
    my ($getTrack) = $sp =~ /(^sub getTrack\b.*?^\})/ms;
    ok(defined $getTrack && $getTrack !~ /API::Client|_delegateToClient|_isFallbackError/, "85-07 D-11: SpClient::getTrack never reaches Client.pm");

    my $cn = $slurp->("$project_dir/Plugins/SpotOn/Connect.pm");
    my ($fetch) = $cn =~ /(^sub _fetchTrackMetadata\b.*?^\})/ms;
    ok(defined $fetch && $fetch !~ /noteMetadataMissing/, "85-07 D-11: Connect::_fetchTrackMetadata is not a sender of noteMetadataMissing");
    unlike($cn, qr/falling back to Client\.pm's own-token path/, "85-07 D-11: Connect.pm's metadata comment no longer promises a Web API fallback");
}

done_testing();
