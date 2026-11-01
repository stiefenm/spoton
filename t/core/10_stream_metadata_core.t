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

# 79-60 Task 2: _typeString became _formatLabel ("<Spotify side> \x{00B7} <LMS side>, SpotOn <mode>").
# The LMS-side cells below keep their intent through lmsPart(), the label without its Spotify side.
sub lmsPart {
    my $l = Plugins::SpotOn::Plugin->can('_formatLabel')
        ? scalar(eval { Plugins::SpotOn::Plugin->_formatLabel(@_) }) // ''
        : '';
    $l =~ s/\A.*? \x{00B7} //s;
    return $l;
}

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
    our %_playing;  # id => MockSong (79-60: the playing song for getMetadataFor/_displayMeta)
    sub can {
        my ($self, $method) = @_;
        return 1 if $method eq 'master' && $_master{${$self}};
        return 1 if $method eq 'currentSongForUrl' && $_playing{${$self}};
        return 0;
    }
    sub currentSongForUrl {
        my ($self, $url) = @_;
        my $s = $_playing{${$self}} or return undef;
        return $s->track->url eq $url ? $s : undef;
    }
    sub model   { return $_model{${$_[0]}}   // 'squeezelite' }
    sub formats { return @{ $_formats{${$_[0]}} // ['ogg','pcm','flc','mp3'] } }
    sub isSynced { return $_synced{${$_[0]}} // 0 }
    sub master  { return $_master{${$_[0]}} }
    sub playingSong { return $_playing{${$_[0]}} }
    sub id          { return ${$_[0]} }   # 79-60: DaemonManager->backendFor(\$client) keys the role by id
}
{
    package MockTrack;
    sub new { my ($class, %a) = @_; return bless { %a }, $class }
    sub url        { $_[0]->{url} }
    sub samplesize { $_[0]->{samplesize} = $_[1] if @_ > 1; $_[0]->{samplesize} }
    sub can        { my ($self, $m) = @_; return $m =~ /\A(?:url|samplesize)\z/ ? 1 : 0 }
}
{
    package MockSong;
    sub new { my ($class, %a) = @_; return bless { track => MockTrack->new(url => $a{url}, samplesize => $a{samplesize}), sb => $a{streambitrate} }, $class }
    sub track         { $_[0]->{track} }
    sub streambitrate { $_[0]->{sb} }
    sub duration      { $_[0]->{duration} = $_[1] if @_ > 1; $_[0]->{duration} }
    sub can           { my ($self, $m) = @_; return $m =~ /\A(?:track|streambitrate|duration)\z/ ? 1 : 0 }
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
    my $result = lmsPart($client, 'Connect');
    is($result, 'FLAC 16, SpotOn Connect',
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
    my $result = lmsPart($client, 'Browse');
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
    my $result = lmsPart($client, 'Browse');
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
    is(lmsPart($noflc, 'Connect'), 'PCM, SpotOn Connect',
        '74b-02 D-15: streamFormat=flac on a client without flc => "PCM, SpotOn Connect" (librespot)');

    # D-15, soloist
    $prefs_l->set('backend', 'soloist');
    is(lmsPart($noflc, 'Connect'), 'PCM, SpotOn Connect',
        '74b-02 D-15: streamFormat=flac on a client without flc => "PCM, SpotOn Connect" (soloist)');

    my $flc = MockClient->new('lbl_flc');
    setup_prefs(client => $flc, streamFormat => 'flac', formats => ['pcm', 'flc']);
    is(lmsPart($flc, 'Connect'), 'FLAC 16, SpotOn Connect',
        '74b-02 D-15: streamFormat=flac on a client with flc => "FLAC, SpotOn Connect" (soloist)');

    # D-22: Auto on a Soloist client with flc follows the staging seam (local
    # override; no cell reads the shipped constant)
    my $auto = MockClient->new('lbl_auto');
    setup_prefs(client => $auto, streamFormat => 'auto', formats => ['pcm', 'flc']);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 0 };
        is(lmsPart($auto, 'Browse'), 'PCM, SpotOn Browse',
            '74b-02 D-22: Auto on a Soloist client with flc while autoFlacEnabled is 0 => "PCM, SpotOn Browse"');
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 1 };
        is(lmsPart($auto, 'Browse'), 'FLAC 16, SpotOn Browse',
            '74b-02 D-22: Auto on a Soloist client with flc while autoFlacEnabled is 1 => "FLAC, SpotOn Browse"');
    }

    # explicit mp3 and pcm under soloist
    my $mp3 = MockClient->new('lbl_mp3');
    setup_prefs(client => $mp3, streamFormat => 'mp3', formats => ['pcm', 'flc', 'mp3']);
    is(lmsPart($mp3, 'Browse'), 'MP3, SpotOn Browse', '74b-02: soloist mp3 => "MP3, SpotOn Browse"');
    my $pcm = MockClient->new('lbl_pcm');
    setup_prefs(client => $pcm, streamFormat => 'pcm', formats => ['pcm', 'flc', 'mp3']);
    is(lmsPart($pcm, 'Browse'), 'PCM, SpotOn Browse', '74b-02: soloist pcm on an flc player => "PCM, SpotOn Browse"');

    # librespot ogg with passthrough is unchanged
    $prefs_l->set('backend', 'librespot');
    my $ogg = MockClient->new('lbl_ogg');
    setup_prefs(client => $ogg, streamFormat => 'ogg', passthrough => 1);
    is(lmsPart($ogg, 'Browse'), 'OGG, SpotOn Browse',
        '74b-02: librespot ogg with passthrough => "OGG, SpotOn Browse" (unchanged)');

    # undef client
    is(lmsPart(undef, 'Browse'), 'PCM, SpotOn Browse', '74b-02: undef client => "PCM, SpotOn Browse"');

    # a dying effectiveFormat falls back to PCM
    {
        no warnings 'redefine', 'once';
        local *Plugins::SpotOn::Unified::DaemonManager::effectiveFormat = sub { die "boom\n" };
        is(lmsPart($flc, 'Browse'), 'PCM, SpotOn Browse',
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
    my $result = lmsPart($client, 'Browse');
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
    my $result = lmsPart($client, 'Browse');
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
    my $result = lmsPart($client, 'Browse');
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
    my $result = lmsPart($client, 'Browse');
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
    my $result = lmsPart($master_client, 'Browse');
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
    my $result = lmsPart(undef, 'Browse');
    is($result, 'PCM, SpotOn Browse',
        'D-04: undef client => PCM (unknown player, conservative default)');
}

# ============================================================
# Test 8: _bitrateConfigForClient (79-60, was _bitrateForClient) — bitrateOverride 160 overrides global 320
# D-07: per-player bitrateOverride takes precedence
# ============================================================
{
    my $client = MockClient->new('player_override');
    setup_prefs(
        bitrate         => 320,
        client          => $client,
        bitrateOverride => 160,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateConfigForClient($client);
    is($result, 160,
        'D-07: bitrateOverride=160 overrides global 320');
}

# ============================================================
# Test 9: _bitrateConfigForClient — defaults to global bitrate
# ============================================================
{
    my $client = MockClient->new('player_global');
    setup_prefs(
        bitrate         => 320,
        client          => $client,
        bitrateOverride => undef,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateConfigForClient($client);
    is($result, 320,
        'D-07: no override => global bitrate 320');
}

# ============================================================
# Test 10: _bitrateConfigForClient — undef client uses global
# ============================================================
{
    setup_prefs(
        bitrate => 96,
    );
    my $result = Plugins::SpotOn::Plugin->_bitrateConfigForClient(undef);
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
    my $result = lmsPart($client, 'Browse');
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
    my $result = lmsPart($client, 'Connect');
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

# ============================================================
# 79-60 Task 1 (forum #333 A): the PLAYING song's format line. The mode follows
# the real source (Soloist Control mode / librespot Connect claim), the bitrate is
# never LMS's FLAC guess (guessBitrateFromFormat: 705600 -> "706k"), and the bit
# depth shown is the source's, while the track keeps the 32-bit transport width.
# The backend-side reads go through the role (query playingMode / deliveredFormat /
# qualityLevelKey); the last two are mocked at their Plugin seams so this
# core half runs on both CI legs; the real DeliveredFormat lives in t/soloist/71.
# ============================================================
{
    no warnings 'redefine', 'once';
    my $P = 'Plugins::SpotOn::Plugin';
    my $prefs_l = Slim::Utils::Prefs::preferences('plugin.spoton');
    $prefs_l->set('backend', 'soloist');
    require Plugins::SpotOn::ProtocolHandler;
    # the real SpClient does not load under this file's URI::Escape stub; ProtocolHandler's
    # _metaCurrent only needs its record-format constant (t/core/11 stubs it the same way)
    $INC{'Plugins/SpotOn/API/SpClient.pm'} //= __FILE__;
    *Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT = sub () { 2 }
        unless defined &Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT;
    require Digest::MD5;
    my $fmtMark = Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT();
    my $cache = Slim::Utils::Cache->new;

    my $url  = 'spoton://track:37BTh5g05cxBIRYMbw8g2T';
    my $flc  = MockClient->new('fmt60_flc');
    setup_prefs(client => $flc, streamFormat => 'flac', formats => ['pcm', 'flc']);
    my $song = MockSong->new(url => $url, samplesize => 32, streambitrate => 705600);
    $MockClient::_playing{'fmt60_flc'} = $song;
    $cache->set('spoton_meta_' . Digest::MD5::md5_hex($url), {
        _spoton_fmt => $fmtMark, title => 'Rosanna', artist => 'TOTO', album => 'Toto IV', duration => 331,
        bitrate => '706k', type => 'FLAC 16, SpotOn Browse',
    }, 604800);

    my $ctlMode = 'connect';
    # the mode comes from the backend role (the Backend::Soloist mock of this file answers
    # Control's mode); Plugin.pm names no Soloist module (amputation seam, t/core/14 CTX-20)
    local *Plugins::SpotOn::Backend::Soloist::query = sub { my ($self, $what) = @_; return $what eq 'playingMode' ? $ctlMode : undef };
    my $rec;   # the measured record the seam answers
    local *Plugins::SpotOn::Plugin::_deliveredFor = sub { return $rec };
    local *Plugins::SpotOn::Plugin::_settingLevelLabel = sub { return 'Lossless' };

    # Connect session, measured FLAC source
    $rec = { codec => 'flac', bitrate => 1400000 };
    my $m = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($flc, $url) } || {};
    # 79-67 (user decision 2026-10-31 "An Material anpassen"): type is the short LMS-side
    # codec, bitrate the measured Spotify side; the two-part label moved to the track info
    is($m->{type}, 'FLAC', '79-67: playing song, LMS FLAC => type "FLAC" (was the two-part label, now in the track info)');
    is($m->{bitrate}, '1400k', '79-67: measured flac 1400000 => bitrate "1400k" (the Spotify side)');
    isnt($m->{bitrate} // '', '706k', '79-67: streambitrate 705600 never reaches bitrate (no 706k guess)');
    is($m->{samplesize}, 16, '79-60: measured FLAC source => samplesize 16');
    is($song->track->samplesize, 32, '79-60: the track keeps the 32-bit transport width (transcoder unchanged)');

    # Browse session, measured vorbis source
    $ctlMode = 'browse';
    $rec = { codec => 'vorbis', bitrate => 160000 };
    $m = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($flc, $url) } || {};
    is($m->{type} . ' ' . ($m->{bitrate} // 'undef'), 'FLAC 160k', '79-67: Browse session, measured vorbis 160000 => type "FLAC", bitrate "160k"');
    ok(exists $m->{samplesize} && defined $m->{samplesize} && $m->{samplesize} eq '',
        '79-60: lossy source => samplesize "" (defined: wins over the track value in LMS status, not shown)');

    # no measurement (cached track): the setting, visibly marked
    $rec = undef;
    $m = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($flc, $url) } || {};
    is($m->{type} . ' [' . ($m->{bitrate} // 'undef') . ']', 'FLAC []', '79-67: no measurement => type "FLAC", bitrate "" (no number without a measurement)');
    is($m->{samplesize}, '', '79-60: no measurement => no bit depth claimed');

    # PCM: the exact rate of the transport width; MP3: the player's LMS limit
    my $pcm = MockClient->new('fmt60_pcm');
    setup_prefs(client => $pcm, streamFormat => 'pcm', formats => ['pcm', 'flc']);
    is(scalar eval { $P->_bitrateLabelForClient($pcm) }, '', '79-67: PCM under Soloist without a song => "" (the transport rate is not the Spotify side)');
    my $mp3 = MockClient->new('fmt60_mp3');
    setup_prefs(client => $mp3, streamFormat => 'mp3', formats => ['pcm', 'flc', 'mp3']);
    Slim::Utils::Prefs::preferences('server')->client($mp3)->set('maxBitrate', 192);
    is(scalar eval { $P->_bitrateLabelForClient($mp3) }, '', '79-67: MP3 with an LMS limit of 192 => "" in bitrate (the limit moved into the two-part label, C-1)');
    Slim::Utils::Prefs::preferences('server')->client($mp3)->set('maxBitrate', 0);
    is(scalar eval { $P->_bitrateLabelForClient($mp3) }, '', '79-60: MP3 without an LMS limit => "" (no number)');

    # a url that is NOT the playing song keeps the setting-based Browse label
    my $other = 'spoton://track:1k1Bqnv2R0uJXQN4u6LKYt';
    $cache->set('spoton_meta_' . Digest::MD5::md5_hex($other), {
        _spoton_fmt => $fmtMark, title => 'Other', artist => 'A', album => 'B', duration => 126,
    }, 604800);
    $ctlMode = 'connect';
    $m = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($flc, $other) } || {};
    is($m->{type}, 'FLAC', '79-67: a history/queue url that is not playing => type "FLAC" (sharpened from 79-60\'s "not labelled Connect")');
    ok(!exists $m->{samplesize}, '79-60: a url that is not playing gets no samplesize override');

    delete $MockClient::_playing{'fmt60_flc'};
    $prefs_l->set('backend', 'librespot');
}

# ============================================================
# 79-60 Task 2: the two-part label everywhere. Menu items are labelled without a
# song (setting-based, no log read); librespot shows its configured OGG rate; a
# Soloist label is either backed by a measured record or carries the setting
# marker (invariant over generated combinations); no caller appends 'k' to a
# bare number any more.
# ============================================================
{
    no warnings 'redefine', 'once';
    my $P = 'Plugins::SpotOn::Plugin';
    my $prefs_l = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $reads = 0;
    my $rec;
    local *Plugins::SpotOn::Plugin::_deliveredFor = sub { $reads++; return $rec };
    local *Plugins::SpotOn::Plugin::_settingLevelLabel = sub { return 'Lossless' };

    # menu item (no song), Soloist
    $prefs_l->set('backend', 'soloist');
    my $flc = MockClient->new('fmt60b_flc');
    setup_prefs(client => $flc, streamFormat => 'flac', formats => ['pcm', 'flc']);
    $rec = { codec => 'flac', bitrate => 1400000 };
    is(scalar eval { $P->_formatLabel($flc, 'Browse') }, "Lossless (PLUGIN_SPOTON_FORMAT_SETTING) \x{00B7} FLAC 16, SpotOn Browse",
        '79-60: menu item under Soloist => "<level> (<setting marker>) · FLAC 16, SpotOn Browse"');
    is($reads, 0, '79-60: a menu-item label (no song) reads no daemon log');

    # librespot: configured OGG rate, passthrough or PCM on the LMS side
    $prefs_l->set('backend', 'librespot');
    my $ogg = MockClient->new('fmt60b_ogg');
    setup_prefs(client => $ogg, bitrate => 320, streamFormat => 'ogg', passthrough => 1);
    is(scalar eval { $P->_formatLabel($ogg, 'Browse') }, "OGG 320k \x{00B7} OGG, SpotOn Browse", '79-60: librespot passthrough => "OGG 320k · OGG"');
    my $lpcm = MockClient->new('fmt60b_lpcm');
    setup_prefs(client => $lpcm, bitrate => 320, streamFormat => 'pcm', passthrough => 0);
    is(scalar eval { $P->_formatLabel($lpcm, 'Connect') }, "OGG 320k \x{00B7} PCM, SpotOn Connect", '79-60: librespot PCM => "OGG 320k · PCM, SpotOn Connect"');
    is(scalar eval { $P->_bitrateLabelForClient($ogg) }, '320k', '79-60: librespot OGG passthrough bitrate => "320k"');

    # invariant over generated combinations (Soloist song): measured => "<CODEC> <n>k ·", else the marker
    $prefs_l->set('backend', 'soloist');
    my $song = MockSong->new(url => 'spoton://track:1k1Bqnv2R0uJXQN4u6LKYt', samplesize => 32);
    my @recs = (undef, {}, { codec => 'flac' }, { codec => 'vorbis', bitrate => 0 }, { codec => 'aac', bitrate => 256000 },
                { codec => 'vorbis', bitrate => 160000 }, { codec => 'flac', bitrate => 1400000 }, { codec => 'flac', bitrate => 700000 },
                { codec => 'vorbis', bitrate => 96000 }, { codec => 'vorbis', bitrate => 320000 });
    my %C = (flac => 'FLAC', vorbis => 'OGG', mp3 => 'MP3');
    my @bad;
    for my $r (@recs) {
        for my $fmt (qw(flac pcm mp3)) {
            for my $mode (qw(Browse Connect)) {
                for my $withSong (0, 1) {
                    $rec = $r;
                    my $c = MockClient->new("fmt60b_inv_$fmt");
                    setup_prefs(client => $c, streamFormat => $fmt, formats => ['pcm', 'flc', 'mp3']);
                    my $l = scalar(eval { $P->_formatLabel($c, $mode, $withSong ? $song : undef) }) // '';
                    my $valid = $withSong && $r && $r->{codec} && $C{ $r->{codec} } && ($r->{bitrate} // 0) >= 1000;
                    my $ok = $valid
                        ? index($l, sprintf('%s %dk %s ', $C{ $r->{codec} }, int($r->{bitrate} / 1000 + 0.5), "\x{00B7}")) == 0
                        : index($l, '(PLUGIN_SPOTON_FORMAT_SETTING)') >= 0;
                    push @bad, "$fmt/$mode/song=$withSong/" . ($r ? join(',', map { "$_=$r->{$_}" } sort keys %$r) : 'undef') . " => '$l'" unless $ok;
                }
            }
        }
    }
    is(scalar(@bad), 0, '79-60 invariant: every Soloist label is measured or carries the setting marker') or diag(join("\n", @bad[0 .. ($#bad < 5 ? $#bad : 5)]));

    # no caller appends 'k' to a bare number, no _typeString caller remains
    my @hits;
    for my $f (glob("$project_dir/Plugins/SpotOn/*.pm"), glob("$project_dir/Plugins/SpotOn/*/*.pm")) {
        open(my $fh, '<', $f) or next;
        while (my $line = <$fh>) {
            next if $line =~ /^\s*#/;
            push @hits, "$f:$.: $line" if $line =~ /_bitrateForClient\([^)]*\)\s*\.\s*'k'/ || $line =~ /->_typeString\(/;
        }
        close $fh;
    }
    is(scalar(@hits), 0, "79-60: no caller appends 'k' to _bitrateForClient and none calls _typeString (the label functions own the 'k')") or diag(join('', @hits));
    # defined &, not can(): the OPMLBased stub answers every can()
    ok(!defined &Plugins::SpotOn::Plugin::_bitrateForClient, '79-60: _bitrateForClient (streambitrate, the 706k source) is gone');
    ok(!defined &Plugins::SpotOn::Plugin::_typeString, '79-60: _typeString is gone (replaced by _formatLabel)');

    $prefs_l->set('backend', 'librespot');
}

# ============================================================
# 79-67 (user decision 2026-10-31 "An Material anpassen", todo
# formatzeile-material-skin-79-60-nachbesserung): Material's formatTechInfo shows
# `type` only up to 4 characters and `bitrate` only when longer than 1 character.
# type = the short LMS-side codec, bitrate = the measured Spotify-side rate of the
# playing track (no number without a measurement), samplesize as in 79-60; the
# two-part label with the real mode moves into the track info (first item).
# ============================================================
{
    no warnings 'redefine', 'once';
    my $P = 'Plugins::SpotOn::Plugin';
    my $prefs_l = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $prevBackend = $prefs_l->get('backend');
    my $prevAccount = $prefs_l->get('activeAccount');
    require Plugins::SpotOn::ProtocolHandler;
    require Digest::MD5;
    my $fmtMark = Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT();
    my $cache   = Slim::Utils::Cache->new;
    my $url     = 'spoton://track:37BTh5g05cxBIRYMbw8g2T';
    my $other   = 'spoton://track:1k1Bqnv2R0uJXQN4u6LKYt';
    for my $u ($url, $other) {
        $cache->set('spoton_meta_' . Digest::MD5::md5_hex($u), {
            _spoton_fmt => $fmtMark, title => 'T', artist => 'A', album => 'B', duration => 300,
        }, 604800);
    }

    # backend-neutral formatting module: no Slim::*, no backend module
    my $dfp = "$project_dir/Plugins/SpotOn/DisplayFormat.pm";
    my $dsrc = -f $dfp ? do { local $/; open(my $fh, '<', $dfp) or die $!; <$fh> } : undef;
    ok(defined $dsrc, '79-67: Plugins/SpotOn/DisplayFormat.pm exists');
    my @dcode = grep { !/^\s*#/ } split /\n/, ($dsrc // '');
    ok(defined $dsrc && !(grep { /\bSlim::/ || /\b(?:Soloist|Librespot)\b/ || /\b(?:use|require)\s+Plugins::/ } @dcode),
        '79-67: DisplayFormat.pm names no Slim::* and no backend module');

    my $mode = 'browse';
    local *Plugins::SpotOn::Backend::Soloist::query   = sub { my ($s, $w) = @_; return $w eq 'playingMode' ? $mode : undef };
    local *Plugins::SpotOn::Backend::Librespot::query = sub { my ($s, $w) = @_; return $w eq 'playingMode' ? $mode : undef };
    # Soloist hands LMS a 32-bit transport: at HEAD the PCM bitrate read 2822k from it
    local *Plugins::SpotOn::Backend::Soloist::capabilitiesDefault = sub {
        return { formats => 'resolveSoloistFormat', contentType => 'soc', samplesize => 32 };
    };
    my $rec;
    local *Plugins::SpotOn::Plugin::_deliveredFor = sub {
        my (undef, undef, $s) = @_;
        return $s && ($prefs_l->get('backend') // '') eq 'soloist' ? $rec : undef;
    };
    local *Plugins::SpotOn::Plugin::_settingLevelLabel = sub { return 'Lossless' };

    # one row: set the player up, read getMetadataFor and the two-part label of the same song
    my $row = sub {
        my (%o) = @_;
        $prefs_l->set('backend', $o{backend});
        my $id = "fmt67_$o{name}";
        my $c  = MockClient->new($id);
        setup_prefs(client => $c, streamFormat => $o{fmt}, formats => $o{formats} // ['ogg', 'pcm', 'flc', 'mp3'],
            bitrate => $o{cfg} // 320, passthrough => $o{pt} // 0);
        Slim::Utils::Prefs::preferences('server')->client($c)->set('maxBitrate', $o{max} // 0);
        $rec  = $o{rec};
        $mode = $o{mode} // 'browse';
        my $song = MockSong->new(url => $url, samplesize => 32, streambitrate => 705600);
        if ($o{playing}) { $MockClient::_playing{$id} = $song } else { delete $MockClient::_playing{$id} }
        my $m = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($c, $url) } || {};
        my $label = scalar(eval { $P->_formatLabel($c, ($mode eq 'connect' ? 'Connect' : 'Browse'), $o{playing} ? $song : undef) }) // '';
        delete $MockClient::_playing{$id};
        return ($m, $label, $song);
    };
    my $show = sub { my ($m) = @_; return join(' | ', map { "$_=" . (exists $m->{$_} ? ($m->{$_} // 'undef') : 'ABSENT') } qw(type bitrate samplesize)) };

    # the target table of 79-67-PLAN.md, one row per line
    my @T = (
        [ 'sol_flac_700',  { backend => 'soloist', fmt => 'flac', rec => { codec => 'flac', bitrate => 700000 }, playing => 1 },
          'type=FLAC | bitrate=700k | samplesize=16', "FLAC 700k \x{00B7} FLAC 16, SpotOn Browse" ],
        [ 'sol_flac_160',  { backend => 'soloist', fmt => 'flac', rec => { codec => 'vorbis', bitrate => 160000 }, playing => 1 },
          'type=FLAC | bitrate=160k | samplesize=', "OGG 160k \x{00B7} FLAC 16, SpotOn Browse" ],
        [ 'sol_flac_none', { backend => 'soloist', fmt => 'flac', rec => undef, playing => 1 },
          'type=FLAC | bitrate= | samplesize=', "Lossless (PLUGIN_SPOTON_FORMAT_SETTING) \x{00B7} FLAC 16, SpotOn Browse" ],
        [ 'sol_pcm_160',   { backend => 'soloist', fmt => 'pcm', rec => { codec => 'vorbis', bitrate => 160000 }, playing => 1 },
          'type=PCM | bitrate=160k | samplesize=', "OGG 160k \x{00B7} PCM, SpotOn Browse" ],
        [ 'sol_pcm_1400',  { backend => 'soloist', fmt => 'pcm', rec => { codec => 'flac', bitrate => 1400000 }, playing => 1, mode => 'connect' },
          'type=PCM | bitrate=1400k | samplesize=16', "FLAC 1400k \x{00B7} PCM, SpotOn Connect" ],
        [ 'sol_pcm_none',  { backend => 'soloist', fmt => 'pcm', rec => undef, playing => 1 },
          'type=PCM | bitrate= | samplesize=', "Lossless (PLUGIN_SPOTON_FORMAT_SETTING) \x{00B7} PCM, SpotOn Browse" ],
        [ 'sol_mp3_160',   { backend => 'soloist', fmt => 'mp3', rec => { codec => 'vorbis', bitrate => 160000 }, playing => 1, max => 192 },
          'type=MP3 | bitrate=160k | samplesize=', "OGG 160k \x{00B7} MP3 192k, SpotOn Browse" ],
        [ 'lib_ogg_320',   { backend => 'librespot', fmt => 'ogg', pt => 1, cfg => 320, rec => undef, playing => 1 },
          'type=OGG | bitrate=320k | samplesize=', "OGG 320k \x{00B7} OGG, SpotOn Browse" ],
        [ 'lib_pcm_320',   { backend => 'librespot', fmt => 'pcm', pt => 0, cfg => 320, rec => undef, playing => 1, mode => 'connect' },
          'type=PCM | bitrate=320k | samplesize=', "OGG 320k \x{00B7} PCM, SpotOn Connect" ],
        [ 'sol_flac_notplaying', { backend => 'soloist', fmt => 'flac', rec => { codec => 'flac', bitrate => 1400000 }, playing => 0 },
          'type=FLAC | bitrate= | samplesize=ABSENT', "Lossless (PLUGIN_SPOTON_FORMAT_SETTING) \x{00B7} FLAC 16, SpotOn Browse" ],
        [ 'lib_ogg_notplaying',  { backend => 'librespot', fmt => 'ogg', pt => 1, cfg => 320, rec => undef, playing => 0 },
          'type=OGG | bitrate=320k | samplesize=ABSENT', "OGG 320k \x{00B7} OGG, SpotOn Browse" ],
    );
    for my $t (@T) {
        my ($name, $o, $want, $wantLabel) = @$t;
        my ($m, $label, $song) = $row->(name => $name, %$o);
        is($show->($m), $want, "79-67 target row $name: getMetadataFor => $want");
        is($label, $wantLabel, "79-67 target row $name: the two-part label is unchanged in content (C-1 for MP3)");
        is($song->track->samplesize, 32, "79-67 target row $name: the track keeps its transport samplesize") if $o->{playing};
    }

    # C-1: the MP3 limit is on the LMS side of the two-part label
    $prefs_l->set('backend', 'soloist');
    my $mp3 = MockClient->new('fmt67_mp3lim');
    setup_prefs(client => $mp3, streamFormat => 'mp3', formats => ['pcm', 'flc', 'mp3']);
    Slim::Utils::Prefs::preferences('server')->client($mp3)->set('maxBitrate', 192);
    is(lmsPart($mp3, 'Browse'), 'MP3 192k, SpotOn Browse', '79-67 C-1: MP3 with an LMS limit of 192 => LMS side "MP3 192k"');
    Slim::Utils::Prefs::preferences('server')->client($mp3)->set('maxBitrate', 0);
    is(lmsPart($mp3, 'Browse'), 'MP3, SpotOn Browse', '79-67 C-1: MP3 without an LMS limit => LMS side "MP3"');

    # invariant over backend x LMS format x record x playing
    my @bad;
    for my $be (qw(soloist librespot)) {
        for my $fmt (qw(flac pcm mp3 ogg)) {
            for my $r (undef, { codec => 'flac', bitrate => 1400000 }, { codec => 'flac', bitrate => 700000 }, { codec => 'vorbis', bitrate => 160000 }) {
                for my $pl (0, 1) {
                    my ($m, $label) = $row->(name => "inv_${be}_$fmt", backend => $be, fmt => $fmt, rec => $r, playing => $pl,
                        cfg => 320, pt => ($fmt eq 'ogg' ? 1 : 0), max => 192);
                    my $t = $m->{type} // 'undef';
                    my $b = $m->{bitrate} // '';
                    my @why;
                    push @why, "type=$t" unless $t =~ /\A(?:FLAC|PCM|MP3|OGG)\z/;
                    push @why, "bitrate=$b" unless $b eq '' || $b =~ /\A\d+k\z/;
                    push @why, "transport or guess bitrate=$b" if $b =~ /\A(?:2822k|1411k|706k)\z/;
                    if ($be eq 'soloist') {
                        my $backed = ($pl && $r) ? 1 : 0;
                        push @why, "backed=$backed but bitrate='$b'" if (($b ne '') ? 1 : 0) != $backed;
                        if ($b ne '') {
                            my ($n) = $label =~ /\A\S+ (\d+k) \x{00B7} /;
                            push @why, "label '$label' disagrees with bitrate $b" unless defined $n && $n eq $b;
                        }
                    }
                    push @bad, "$be/$fmt/rec=" . ($r ? "$r->{codec}:$r->{bitrate}" : 'none') . "/playing=$pl: @why" if @why;
                }
            }
        }
    }
    is(scalar(@bad), 0, '79-67 invariant: type is FLAC/PCM/MP3/OGG, bitrate is "" or "<n>k" and never 2822k/1411k/706k, under Soloist a number exactly when a measured record backs it and equal to the label\'s')
        or diag(join("\n", @bad[0 .. ($#bad < 7 ? $#bad : 7)]));

    # C-3: a spoton_meta record written before the restart (old two-part type, 2822k)
    $prefs_l->set('backend', 'soloist');
    my $stale = 'spoton://track:5h5BrNPFvc4IXfCgnZJ2lT';
    $cache->set('spoton_meta_' . Digest::MD5::md5_hex($stale), {
        _spoton_fmt => $fmtMark, title => 'S', artist => 'A', album => 'B', duration => 200,
        type => "Lossless (PLUGIN_SPOTON_FORMAT_SETTING) \x{00B7} PCM, SpotOn Browse", bitrate => '2822k',
    }, 604800);
    my $pc = MockClient->new('fmt67_stale');
    setup_prefs(client => $pc, streamFormat => 'pcm', formats => ['pcm', 'flc']);
    $rec = undef;
    my $sm = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($pc, $stale) } || {};
    is($show->($sm), 'type=PCM | bitrate= | samplesize=ABSENT', '79-67 C-3: a stale record (two-part type, 2822k), not playing => short type, no number');
    $MockClient::_playing{'fmt67_stale'} = MockSong->new(url => $stale, samplesize => 32);
    $rec = { codec => 'flac', bitrate => 700000 };
    $sm = eval { Plugins::SpotOn::ProtocolHandler->getMetadataFor($pc, $stale) } || {};
    is($show->($sm), 'type=PCM | bitrate=700k | samplesize=16', '79-67 C-3: a stale record of the playing song => short type, the measured rate');
    delete $MockClient::_playing{'fmt67_stale'};

    # the two-part label in the track info (PLACE67=trackinfo): first item, real mode
    $prefs_l->set('activeAccount', 'fmt67-account');
    my $ti = MockClient->new('fmt67_ti');
    setup_prefs(client => $ti, streamFormat => 'flac', formats => ['pcm', 'flc']);
    my $tsong = MockSong->new(url => $url, samplesize => 32);
    $MockClient::_playing{'fmt67_ti'} = $tsong;
    $mode = 'connect';
    $rec  = { codec => 'flac', bitrate => 1400000 };
    my $items = eval { Plugins::SpotOn::Plugin::trackInfoMenu($ti, $url, undef, {}) };
    is_deeply(ref $items eq 'ARRAY' ? $items->[0] : $items, { type => 'text', name => "FLAC 1400k \x{00B7} FLAC 16, SpotOn Connect" },
        '79-67: track info of the playing song (Soloist Connect, measured flac 1400000) => first item the two-part label');
    ok(ref $items eq 'ARRAY' && (grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_MANAGE_LIKE' } @$items), '79-67: the existing SpotOn track info items stay');
    (my $bare = $url) =~ s{^spoton://}{spoton:};
    $items = eval { Plugins::SpotOn::Plugin::trackInfoMenu($ti, $bare, undef, {}) };
    is(ref $items eq 'ARRAY' ? $items->[0]{name} : undef, "FLAC 1400k \x{00B7} FLAC 16, SpotOn Connect", '79-67: the spoton:track:<id> form finds the same playing song');
    $items = eval { Plugins::SpotOn::Plugin::trackInfoMenu($ti, $other, undef, {}) };
    is_deeply(ref $items eq 'ARRAY' ? $items->[0] : $items, { type => 'text', name => "Lossless (PLUGIN_SPOTON_FORMAT_SETTING) \x{00B7} FLAC 16, SpotOn Browse" },
        '79-67: track info of a url that is not playing => the setting-based label, SpotOn Browse');

    $prefs_l->set('backend', 'librespot');
    my $lc = MockClient->new('fmt67_lconn');
    setup_prefs(client => $lc, bitrate => 320, streamFormat => 'pcm', passthrough => 0);
    my $curl = 'spoton://connect-fmt67';
    $MockClient::_playing{'fmt67_lconn'} = MockSong->new(url => $curl, samplesize => 16);
    $mode = 'connect';
    $items = eval { Plugins::SpotOn::Plugin::trackInfoMenu($lc, $curl, undef, {}) };
    is_deeply($items, [ { type => 'text', name => "OGG 320k \x{00B7} PCM, SpotOn Connect" } ],
        '79-67: librespot spoton://connect- url of the playing song => the format item alone, SpotOn Connect');

    $prefs_l->set('activeAccount', undef);
    $items = eval { Plugins::SpotOn::Plugin::trackInfoMenu($lc, $curl, undef, {}) };
    is($items, undef, '79-67: connect url without an account => undef');
    delete $MockClient::_playing{'fmt67_lconn'};
    $prefs_l->set('backend', 'soloist');
    $items = eval { Plugins::SpotOn::Plugin::trackInfoMenu($ti, $url, undef, {}) };
    is($items, undef, '79-67: no account => undef as before (CTX-03)');
    delete $MockClient::_playing{'fmt67_ti'};

    # exactly one _formatLabel call site remains, inside _formatLineFor
    my @fl;
    for my $f (glob("$project_dir/Plugins/SpotOn/*.pm"), glob("$project_dir/Plugins/SpotOn/*/*.pm")) {
        open(my $fh, '<', $f) or next;
        my $sub = '';
        while (my $line = <$fh>) {
            $sub = $1 if $line =~ /^sub (\w+)/;
            next if $line =~ /^\s*#/;
            push @fl, "$f:$.:$sub" if $line =~ /->_formatLabel\(/;
        }
        close $fh;
    }
    is(scalar(@fl), 1, '79-67: exactly one non-comment ->_formatLabel( call site remains (planner baseline 10)') or diag(join("\n", @fl));
    like($fl[0] // '', qr/:_formatLineFor\z/, '79-67: that call site is inside _formatLineFor');

    $prefs_l->set('activeAccount', $prevAccount);
    $prefs_l->set('backend', $prevBackend);
}

# ============================================================
# 79-67 repair round (user decisions 2026-11-01 B1 "Nur Anzeige korrigieren" and C1
# "Echtes Format zeigen"): the LMS song info page read "Samplegröße: 32Bit" (the
# transport width, Slim/Menu/TrackInfo.pm infoSampleSize reads $track->samplesize)
# and "Dateiformat: soc" (infoContentType, the internal content type). SpotOn
# replaces the two core rows by name (as it does for `url`, GH-93): SpotOn urls get
# the real LMS-side format and the source bit depth; every other url gets the LMS
# core row unchanged. $track->samplesize and the soc content type stay.
# ============================================================
{
    no warnings 'redefine', 'once';
    my $P = 'Plugins::SpotOn::Plugin';
    my $prefs_l = Slim::Utils::Prefs::preferences('plugin.spoton');
    my $prevBackend = $prefs_l->get('backend');

    # the LMS core rows, as sentinels that record their arguments
    my @coreCalls;
    $INC{'Slim/Menu/TrackInfo.pm'} //= __FILE__;
    local *Slim::Menu::TrackInfo::infoContentType = sub { push @coreCalls, [ 'type', @_ ]; return { type => 'text', label => 'TYPE', name => 'CORE-TYPE' } };
    local *Slim::Menu::TrackInfo::infoSampleSize  = sub { push @coreCalls, [ 'samplesize', @_ ]; return { type => 'text', label => 'SAMPLESIZE', name => 'CORE-SAMPLESIZE' } };

    my $rec;
    local *Plugins::SpotOn::Plugin::_deliveredFor = sub {
        my (undef, undef, $s) = @_;
        return $s && ($prefs_l->get('backend') // '') eq 'soloist' ? $rec : undef;
    };
    local *Plugins::SpotOn::Backend::Soloist::query = sub { return undef };

    # defined &, not can(): the OPMLBased stub answers every can() (a missing sub would read undef = "no row")
    my $ct = sub { my @a = @_; return defined &Plugins::SpotOn::Plugin::_infoContentType ? scalar(eval { Plugins::SpotOn::Plugin::_infoContentType(@a) }) : 'NO-_infoContentType' };
    my $ss = sub { my @a = @_; return defined &Plugins::SpotOn::Plugin::_infoSampleSize ? scalar(eval { Plugins::SpotOn::Plugin::_infoSampleSize(@a) })  : 'NO-_infoSampleSize' };

    my $nm = sub { my ($r) = @_; return ref $r eq 'HASH' ? $r->{name} : $r };

    $prefs_l->set('backend', 'soloist');
    my $url  = 'spoton://track:2jvuMDqBK04WvCYYz5qjvG';
    my $flc  = MockClient->new('fmt67r_flc');
    setup_prefs(client => $flc, streamFormat => 'flac', formats => ['pcm', 'flc']);
    my $song = MockSong->new(url => $url, samplesize => 32);
    my $track = $song->track;
    $MockClient::_playing{'fmt67r_flc'} = $song;

    # C1: the real LMS-side format for SpotOn urls
    is_deeply($ct->($flc, $url, $track, {}), { type => 'text', label => 'TYPE', name => 'FLAC' }, '79-67 C1: SpotOn track, LMS FLAC => "Dateiformat: FLAC" (not soc)');
    (my $bare = $url) =~ s{^spoton://}{spoton:};
    is_deeply($ct->($flc, $bare, $track, {}), { type => 'text', label => 'TYPE', name => 'FLAC' }, '79-67 C1: the spoton:track:<id> form too');
    my $pcm = MockClient->new('fmt67r_pcm');
    setup_prefs(client => $pcm, streamFormat => 'pcm', formats => ['pcm', 'flc']);
    is($nm->($ct->($pcm, 'spoton://track:1k1Bqnv2R0uJXQN4u6LKYt', $track, {})), 'PCM', '79-67 C1: SpotOn track, LMS PCM => "PCM"');
    my $mp3 = MockClient->new('fmt67r_mp3');
    setup_prefs(client => $mp3, streamFormat => 'mp3', formats => ['pcm', 'flc', 'mp3']);
    is($nm->($ct->($mp3, 'spoton://episode:XYZ789', $track, {})), 'MP3', '79-67 C1: SpotOn episode, LMS MP3 => "MP3"');

    # B1: the source bit depth of the playing SpotOn song, else no row
    $rec = { codec => 'flac', bitrate => 1400000 };
    is_deeply($ss->($flc, $url, $track, {}), { type => 'text', label => 'SAMPLESIZE', name => '16BITS' }, '79-67 B1: playing SpotOn song, measured flac 1400000 => "16" + BITS (not 32)');
    $rec = { codec => 'flac', bitrate => 2500000 };
    is($nm->($ss->($flc, $url, $track, {})), '24BITS', '79-67 B1: measured flac above 2 Mbit/s => 24');
    $rec = { codec => 'vorbis', bitrate => 160000 };
    is($ss->($flc, $url, $track, {}), undef, '79-67 B1: lossy source => no Samplegröße row');
    $rec = undef;
    is($ss->($flc, $url, $track, {}), undef, '79-67 B1: no measurement => no Samplegröße row');
    $rec = { codec => 'flac', bitrate => 1400000 };
    is($ss->($flc, 'spoton://track:1k1Bqnv2R0uJXQN4u6LKYt', $track, {}), undef, '79-67 B1: a SpotOn url that is not playing => no row (no measurement claimed)');
    is($track->samplesize, 32, '79-67 B1: $track->samplesize stays the 32-bit transport width');

    # every other url: the LMS core row, called with the same arguments, returned unchanged
    for my $other ('file:///music/local/track.flac', 'http://radio.example/stream.mp3', 'tidal://12345.flc') {
        @coreCalls = ();
        my $lt = MockTrack->new(url => $other, samplesize => 24);
        my $rt = $ct->($flc, $other, $lt, { x => 1 }, { tag => 1 });
        my $rs = $ss->($flc, $other, $lt, { x => 1 }, { tag => 1 });
        is_deeply([ $rt, $rs ], [ { type => 'text', label => 'TYPE', name => 'CORE-TYPE' }, { type => 'text', label => 'SAMPLESIZE', name => 'CORE-SAMPLESIZE' } ],
            "79-67 B1/C1: $other gets the LMS core rows unchanged");
        is_deeply(\@coreCalls, [ [ 'type', $flc, $other, $lt, { x => 1 }, { tag => 1 } ], [ 'samplesize', $flc, $other, $lt, { x => 1 }, { tag => 1 } ] ],
            "79-67 B1/C1: $other - the core rows get the same arguments");
        is($lt->samplesize, 24, "79-67 B1: $other - the track samplesize is not touched");
    }
    # no player: no LMS side to show, the core row
    @coreCalls = ();
    is_deeply($ct->(undef, $url, $track, {}), { type => 'text', label => 'TYPE', name => 'CORE-TYPE' }, '79-67 C1: without a player the core row stays');

    # librespot: a lossy source, no bit depth claimed; the format row is the LMS side
    $prefs_l->set('backend', 'librespot');
    my $lo = MockClient->new('fmt67r_lib');
    setup_prefs(client => $lo, bitrate => 320, streamFormat => 'ogg', passthrough => 1, formats => ['ogg', 'pcm', 'flc', 'mp3']);
    $MockClient::_playing{'fmt67r_lib'} = $song;
    is($nm->($ct->($lo, $url, $track, {})), 'OGG', '79-67 C1: librespot OGG passthrough => "OGG"');
    is($ss->($lo, $url, $track, {}), undef, '79-67 B1: librespot (lossy source) => no Samplegröße row');
    delete $MockClient::_playing{'fmt67r_lib'};
    delete $MockClient::_playing{'fmt67r_flc'};

    # registration: the two core rows are replaced by name at the core positions
    my $src = do { local $/; open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!; <$fh> };
    like($src, qr/registerInfoProvider\(\s*type\s*=>\s*\(\s*parent\s*=>\s*'moreinfo',\s*after\s*=>\s*'tracknum',\s*func\s*=>\s*\\&_infoContentType,/,
        '79-67 C1: initPlugin replaces the core `type` row (parent moreinfo, after tracknum, as TrackInfo.pm registers it)');
    like($src, qr/registerInfoProvider\(\s*samplesize\s*=>\s*\(\s*parent\s*=>\s*'moreinfo',\s*after\s*=>\s*'samplerate',\s*func\s*=>\s*\\&_infoSampleSize,/,
        '79-67 B1: initPlugin replaces the core `samplesize` row (parent moreinfo, after samplerate, as TrackInfo.pm registers it)');

    $prefs_l->set('backend', $prevBackend);
}

done_testing();
