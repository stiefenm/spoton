#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# ============================================================
# Phase 84 Plan 06 (D-08): librespot ProtocolHandler characterization.
#
# RESEARCH 84-RESEARCH.md section 2: only 3 of 55 test files were
# librespot-dedicated, so the backend seam (84-07..84-09) would move the
# librespot branches unproven. This file pins what ProtocolHandler.pm does
# TODAY under backend=librespot -- the current code is the oracle, not a
# desired design. D-08 "behaviour-identical" means the seam keeps exactly
# this.
#
# Never skipped: these tests characterize code that exists, so a
# missing module is a hard failure (silent-green trap 2, RESEARCH 2).
#
# SPOTON_MODULE_ROOT (default: the project root) points the test at a
# mutated COPY of Plugins/SpotOn for the mutation proofs recorded in the
# 84-06 SUMMARY -- every assertion group was shown red that way once.
#
# Root resolution is two levels while this file sits flat under t/;
# 84-09 moves it into t/librespot/ and switches to three levels.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $module_root = $ENV{SPOTON_MODULE_ROOT} || $project_dir;

for my $rel (qw(
    Plugins/SpotOn/ProtocolHandler.pm
    Plugins/SpotOn/Unified/DaemonManager.pm
)) {
    die "t/55: $module_root/$rel is missing -- characterization tests of "
      . "existing code must not skip\n" unless -f "$module_root/$rel";
}

my $stub_dir = tempdir(CLEANUP => 1);

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

# The logging / LMS-utility stubs are needed twice: once for the
# in-process ProtocolHandler load below, once for the DaemonManager
# subprocess (_backendPrereqState). One list, written into both dirs.
my @COMMON_STUBS = (
    ['Log::Log4perl::Logger', <<'END'],
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END
    ['Log::Log4perl', <<'END'],
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END
    ['Slim::Utils::Log', <<'END'],
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END
    ['Slim::Utils::Strings', <<'END'],
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
    *{"${caller}::string"}  = sub { '' };
}
1;
END
    ['Plugins::SpotOn::Plugin', <<'END'],
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END
);

write_stub($stub_dir, @$_) for @COMMON_STUBS;

# Prefs: global values in %FAKE, per-client values in %CLIENT (a plain
# hash keyed by pref name -- one client is enough for these cases).
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
our %CLIENT;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs::Client' }
sub setChange { }
package Slim::Utils::Prefs::Client;
sub get { my ($self, $key) = @_; return $Slim::Utils::Prefs::CLIENT{$key}; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %STORE;
sub new    { return bless {}, shift }
sub get    { my ($self, $key) = @_; return $STORE{$key}; }
sub set    { my ($self, $key, $val) = @_; $STORE{$key} = $val; }
sub remove { my ($self, $key) = @_; delete $STORE{$key}; }
1;
END

# serverAddr is deliberately NOT 127.0.0.1: canDirectStream builds the
# direct URL from it, new() hardcodes 127.0.0.1 (CR-05) -- the two must
# stay distinguishable.
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '192.0.2.7' }
1;
END

write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL         { return ('127.0.0.1', 80, '/') }
sub findbin           { }
sub addFindBinPaths   { }
1;
END

write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END

write_stub($stub_dir, 'Slim::Schema::RemoteTrack', <<'END');
package Slim::Schema::RemoteTrack;
sub fetch { return undef }
1;
END

write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { return bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Records the args new() finally hands to the base class, so a test can
# read which URL the librespot Browse/Connect substitution produced.
write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
our @NEW_ARGS;
sub new {
    my ($class, $args) = @_;
    push @NEW_ARGS, $args;
    return bless { %$args }, $class;
}
1;
END

# 84-08: ProtocolHandler::new now reaches the REAL Backend::Librespot
# through backendFor; the role module imports these two at compile time
# (its HTTP sender is never exercised here).
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use JSON::PP ();
sub import {
    my $caller = caller;
    no strict 'refs';
    my $j = JSON::PP->new->canonical;
    *{"${caller}::to_json"}   = sub { $j->encode($_[0]) };
    *{"${caller}::from_json"} = sub { $j->decode($_[0]) };
}
1;
END
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { my ($c, @a) = @_; return bless { cb => [@a] }, $c; }
sub post { return; }
1;
END

# Controllable DaemonManager. $HELPER undef = no daemon; $PASSTHROUGH is
# the librespot boolean that formatOverride maps to 'son' | 'soc'.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $HELPER;
our $PASSTHROUGH = 0;
# 79-34 D-29: the served-passthrough answer contentTypeFor now asks for; undef = follow
# $PASSTHROUGH (existing cells), a defined value = the serving daemon's flag.
our $SERVED;
# 74b D-15: the group capability answer contentTypeFor asks for an explicit
# FLAC pref under librespot (the real one aggregates formats() over the
# master and its slaves).
our $GROUP_FLAC  = 1;
sub helperForClient             { return $HELPER; }
sub resolvePassthroughForClient { return $PASSTHROUGH; }
sub resolveServedPassthroughForClient { return defined $SERVED ? $SERVED : $PASSTHROUGH; }
sub groupSupportsFlac           { return $GROUP_FLAC; }
# 84-07: the backend role (84-08 wires ProtocolHandler to it); the real
# Backend::Librespot over this stub's helper.
sub backendFor {
    my ($class, $c) = @_;
    require Plugins::SpotOn::Backend::Librespot;
    return Plugins::SpotOn::Backend::Librespot->new(ref $c ? $c->id : $c);
}
# 84-08: contentType/formatOverride read the role CLASS (no client).
sub backendClass { require Plugins::SpotOn::Backend::Librespot; return 'Plugins::SpotOn::Backend::Librespot'; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
}
$::VERSION = '9.0.0';

unshift @INC, $stub_dir, $module_root;

require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");
require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load Plugins::SpotOn::ProtocolHandler");
require_ok('Slim::Player::Protocols::HTTP')
    or BAIL_OUT("Failed to load the Slim::Player::Protocols::HTTP stub");
require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the DaemonManager stub");

my $pkg = 'Plugins::SpotOn::ProtocolHandler';
my $DM  = 'Plugins::SpotOn::Unified::DaemonManager';

sub reset_state {
    %Slim::Utils::Prefs::FAKE   = (backend => 'librespot');
    %Slim::Utils::Prefs::CLIENT = ();
    %Slim::Utils::Cache::STORE  = ();
    @Slim::Player::Protocols::HTTP::NEW_ARGS = ();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER      = undef;
    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 0;
    $Plugins::SpotOn::Unified::DaemonManager::GROUP_FLAC  = 1;
}

# ------------------------------------------------------------
# Test doubles
# ------------------------------------------------------------
{
    package MockClient;
    sub new {
        my ($class, %a) = @_;
        return bless { id => ($a{id} // 'aa:bb:cc:dd:ee:01'), synced => ($a{synced} // 0) }, $class;
    }
    sub can      { return 0; }     # no ->master: the client is its own master
    sub isSynced { return $_[0]->{synced}; }
    sub id       { return $_[0]->{id}; }

    package MockHelper;             # a librespot helper: NOT a SoloistDaemon
    sub new {
        my ($class, %a) = @_;
        return bless { alive => 1, port => 4242, %a }, $class;
    }
    sub alive       { return $_[0]->{alive}; }
    sub _streamPort { return $_[0]->{port}; }

    package MockTrack;
    sub new {
        my ($class, %a) = @_;
        return bless { url => $a{url}, samplesize => $a{samplesize} }, $class;
    }
    sub url        { return $_[0]->{url}; }
    sub samplesize { my $s = shift; $s->{samplesize} = shift if @_; return $s->{samplesize}; }
    sub can        { my ($s, $m) = @_; return UNIVERSAL::can($s, $m); }

    package MockSong;
    sub new {
        my ($class, %a) = @_;
        return bless {
            client     => $a{client},
            track      => $a{track},
            seekdata   => $a{seekdata},
            startOffset => undef,
            duration   => undef,
        }, $class;
    }
    sub master      { return $_[0]->{client}; }
    sub track       { return $_[0]->{track}; }
    sub currentTrack { return $_[0]->{track}; }
    sub seekdata    { return $_[0]->{seekdata}; }
    sub startOffset { my $s = shift; $s->{startOffset} = shift if @_; return $s->{startOffset}; }
    sub duration    { my $s = shift; $s->{duration} = shift if @_; return $s->{duration}; }
}

# ============================================================
# A. contentType -- class default
# ============================================================
{
    reset_state();
    is($pkg->contentType(), 'son', "contentType() eq 'son' under backend=librespot");

    delete $Slim::Utils::Prefs::FAKE{backend};
    is($pkg->contentType(), 'son', "contentType() eq 'son' when the backend pref is unset (librespot is the default)");
}

# ============================================================
# B. getFormatForURL
# ============================================================
{
    reset_state();
    is($pkg->getFormatForURL('spoton://connect-1'), 'soc', "getFormatForURL(connect-N) eq 'soc'");
    is($pkg->getFormatForURL('http://h:1234/stream'), 'pcm', "getFormatForURL(http://h:port/stream) eq 'pcm'");
    is($pkg->getFormatForURL('http://h:1234/stream?x=1'), 'pcm', "getFormatForURL(.../stream?query) eq 'pcm' (word boundary after stream)");
    is($pkg->getFormatForURL('http://h:1234/track/x'), 'soc', "getFormatForURL(http://h:port/track/x) eq 'soc'");
    is($pkg->getFormatForURL('http://h:1234/episode/x'), 'soc', "getFormatForURL(http://h:port/episode/x) eq 'soc'");
    is($pkg->getFormatForURL('spoton://track:abc'), 'soc', "getFormatForURL(spoton://track:ID) eq 'soc'");
    is($pkg->getFormatForURL('spoton://episode:abc'), 'soc', "getFormatForURL(spoton://episode:ID) eq 'soc'");
    is($pkg->getFormatForURL(undef), 'soc', "getFormatForURL(undef) falls through to 'soc'");
}

# ============================================================
# C. formatOverride
# ============================================================
{
    reset_state();
    my $client = MockClient->new();
    my $song   = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://track:abc'));

    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 1;
    is($pkg->formatOverride($song), 'son', "formatOverride -> 'son' when resolvePassthroughForClient is true");

    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 0;
    is($pkg->formatOverride($song), 'soc', "formatOverride -> 'soc' when resolvePassthroughForClient is false");

    $Slim::Utils::Prefs::CLIENT{streamFormat} = 'mp3';
    is($pkg->formatOverride($song), 'smp', "formatOverride -> 'smp' for an explicit streamFormat=mp3 (no passthrough)");

    delete $Slim::Utils::Prefs::CLIENT{streamFormat};
    $Slim::Utils::Prefs::CLIENT{connectOggOverride} = 'mp3';
    is($pkg->formatOverride($song), 'smp', "formatOverride -> 'smp' via the legacy connectOggOverride=mp3 fallback");

    # 74b D-04 (code side) / D-15: an explicit FLAC pref routes to the
    # single-rule FLAC type 'sof' (16-bit input padded losslessly by
    # $SAMPLESIZE$) when every group member can play flc, and degrades to
    # 'soc' (PCM) when one cannot.
    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'flac');
    $Plugins::SpotOn::Unified::DaemonManager::GROUP_FLAC = 1;
    is($pkg->formatOverride($song), 'sof', "formatOverride -> 'sof' for streamFormat=flac with groupSupportsFlac 1 (74b D-04)");

    $Plugins::SpotOn::Unified::DaemonManager::GROUP_FLAC = 0;
    is($pkg->formatOverride($song), 'soc', "formatOverride -> 'soc' for streamFormat=flac with groupSupportsFlac 0 (74b D-15 degrade)");
    $Plugins::SpotOn::Unified::DaemonManager::GROUP_FLAC = 1;

    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'auto');
    is($pkg->formatOverride($song), 'soc', "formatOverride -> 'soc' for librespot Auto without passthrough (Auto unchanged)");

    # contentTypeFor is the shared mapping: its list answer carries the
    # resolver name and the resolved value formatOverride logs.
    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'flac');
    my ($t, $resolver, $resolved) = $pkg->contentTypeFor($client);
    is_deeply([$t, $resolver, $resolved], ['sof', 'resolveServedPassthroughForClient', 0],
        "contentTypeFor -> (sof, resolveServedPassthroughForClient, 0) for librespot streamFormat=flac");

    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'mp3');
    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 1;
    is($pkg->formatOverride($song), 'son', "formatOverride -> 'son' even with streamFormat=mp3 when passthrough is on (mp3 reroute only applies to 'soc')");
}

# ------------------------------------------------------------
# 79-34 D-29: formatOverride over the SERVED answer (the serving daemon's flag, not the
# pref): $SERVED drives resolveServedPassthroughForClient, $PASSTHROUGH (the pref
# resolver) is set to the opposite so a regression to the pref reads wrong.
# ------------------------------------------------------------
{
    reset_state();
    my $client = MockClient->new();
    my $song   = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://track:abc'));
    local $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 1;
    local $Plugins::SpotOn::Unified::DaemonManager::SERVED      = 0;
    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'ogg');
    is($pkg->formatOverride($song), 'soc', "79-34 D-29: served flag 0 with streamFormat=ogg -> formatOverride 'soc' (a pcm daemon still serves, F1 shape)");

    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 0;
    $Plugins::SpotOn::Unified::DaemonManager::SERVED      = 1;
    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'pcm');
    is($pkg->formatOverride($song), 'son', "79-34 D-29: served flag 1 with streamFormat=pcm -> formatOverride 'son' (a passthrough daemon still serves, F4 shape)");

    $Plugins::SpotOn::Unified::DaemonManager::SERVED = 0;
    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'mp3');
    is($pkg->formatOverride($song), 'smp', "79-34 D-29: served flag 0 with streamFormat=mp3 -> 'smp' (mapping unchanged over the new resolver)");

    %Slim::Utils::Prefs::CLIENT = (streamFormat => 'flac');
    $Plugins::SpotOn::Unified::DaemonManager::GROUP_FLAC = 1;
    is($pkg->formatOverride($song), 'sof', "79-34 D-29: served flag 0 with streamFormat=flac and groupSupportsFlac 1 -> 'sof' (mapping unchanged over the new resolver)");
}

# ============================================================
# D. canDirectStream (librespot paths)
# ============================================================
{
    reset_state();
    my $client = MockClient->new();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(port => 4242);

    is($pkg->canDirectStream(undef, 'spoton://connect-1'), 0, 'canDirectStream: no client -> 0');

    # --- Connect URL ---
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 'http://192.0.2.7:4242/stream',
        'canDirectStream: Connect URL, alive helper, unsynced, auto format -> http://<serverAddr>:<port>/stream');

    $Slim::Utils::Prefs::CLIENT{streamFormat} = 'ogg';
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 'http://192.0.2.7:4242/stream',
        "canDirectStream: streamFormat=ogg is not in ^(?:pcm|flac|mp3)\$ -> direct URL");

    for my $fmt (qw(pcm flac mp3)) {
        $Slim::Utils::Prefs::CLIENT{streamFormat} = $fmt;
        is($pkg->canDirectStream($client, 'spoton://connect-1'), 0,
            "canDirectStream: streamFormat=$fmt forces transcoding -> 0");
    }

    %Slim::Utils::Prefs::CLIENT = (connectOggOverride => 'mp3');
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 0,
        'canDirectStream: legacy connectOggOverride=mp3 forces transcoding -> 0');
    %Slim::Utils::Prefs::CLIENT = ();

    my $synced = MockClient->new(synced => 1);
    is($pkg->canDirectStream($synced, 'spoton://connect-1'), 0,
        'canDirectStream: synced player -> 0 (new() proxy handles it)');

    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(alive => 0);
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 0, 'canDirectStream: helper not alive -> 0');

    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(port => undef);
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 0, 'canDirectStream: helper without stream port -> 0');

    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 0, 'canDirectStream: no helper -> 0');

    # --- streamingMode=proxy gate (COMPAT-02) ---
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(port => 4242);
    $Slim::Utils::Prefs::CLIENT{streamingMode} = 'proxy';
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 0, 'canDirectStream: per-player streamingMode=proxy -> 0 (Connect)');
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0, 'canDirectStream: per-player streamingMode=proxy -> 0 (Browse)');

    $Slim::Utils::Prefs::CLIENT{streamingMode} = 'global';
    $Slim::Utils::Prefs::FAKE{streamingMode}   = 'proxy';
    is($pkg->canDirectStream($client, 'spoton://connect-1'), 0, "canDirectStream: per-player 'global' resolving to global proxy -> 0");
    %Slim::Utils::Prefs::CLIENT = ();
    delete $Slim::Utils::Prefs::FAKE{streamingMode};

    # --- Browse URL: direct stream to the daemon's /<type>/<id> ---
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 'http://192.0.2.7:4242/track/abc123',
        'canDirectStream: Browse track URL -> http://<serverAddr>:<port>/track/<id>');
    is($pkg->canDirectStream($client, 'spoton://episode:ep9'), 'http://192.0.2.7:4242/episode/ep9',
        'canDirectStream: Browse episode URL -> .../episode/<id>');
    is($pkg->canDirectStream($synced, 'spoton://track:abc123'), 0, 'canDirectStream: Browse URL on a synced player -> 0');
    # 84-08 (control check 2026-10-11): a dead helper that still carries a
    # stream port -> 0 (the role's browse_direct answers undef).
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(alive => 0, port => 4242);
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0, 'canDirectStream: Browse URL with a dead helper (port still set) -> 0');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(port => 4242);

    is($pkg->canDirectStream($client, 'http://example.invalid/x.mp3'), 0, 'canDirectStream: foreign URL -> 0');
}

# ============================================================
# E. canDirectStreamSong -- seek offset on the Browse daemon URL
# ============================================================
{
    reset_state();
    my $client = MockClient->new();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(port => 4242);

    my $song = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://track:abc123'),
                             seekdata => { timeOffset => 42 });
    is($pkg->canDirectStreamSong($client, $song), 'http://192.0.2.7:4242/track/abc123?start_position=42',
        'canDirectStreamSong: Browse daemon URL gets ?start_position=<timeOffset>');
    is($song->startOffset, 42, 'canDirectStreamSong: startOffset is set to the seek offset');

    my $noSeek = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://track:abc123'));
    is($pkg->canDirectStreamSong($client, $noSeek), 'http://192.0.2.7:4242/track/abc123',
        'canDirectStreamSong: no seekdata -> plain daemon URL, no query');

    my $conn = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://connect-5'),
                             seekdata => { timeOffset => 42 });
    is($pkg->canDirectStreamSong($client, $conn), 'http://192.0.2.7:4242/stream',
        'canDirectStreamSong: Connect /stream URL never gets a start_position');
}

# ============================================================
# F. new() -- librespot URL substitution
# ============================================================
{
    reset_state();
    my $client = MockClient->new();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(port => 4242);

    my $song = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://track:abc'),
                             seekdata => { timeOffset => 17 });
    $pkg->new({ url => 'spoton://track:abc', client => $client, song => $song });
    is($Slim::Player::Protocols::HTTP::NEW_ARGS[-1]{url}, 'http://127.0.0.1:4242/track/abc?start_position=17',
        'new(): Browse track URL -> http://127.0.0.1:<port>/track/<id>?start_position=<N> (hardcoded loopback, CR-05)');
    is($song->startOffset, 17, 'new(): startOffset is set from seekdata->timeOffset');

    @Slim::Player::Protocols::HTTP::NEW_ARGS = ();
    my $plain = MockSong->new(client => $client, track => MockTrack->new(url => 'spoton://track:abc'));
    $pkg->new({ url => 'spoton://track:abc', client => $client, song => $plain });
    is($Slim::Player::Protocols::HTTP::NEW_ARGS[-1]{url}, 'http://127.0.0.1:4242/track/abc',
        'new(): Browse track URL without seekdata -> no query string');
    is($plain->startOffset, undef, 'new(): startOffset untouched without seekdata');

    $pkg->new({ url => 'spoton://episode:ep9', client => $client });
    is($Slim::Player::Protocols::HTTP::NEW_ARGS[-1]{url}, 'http://127.0.0.1:4242/episode/ep9',
        'new(): Browse episode URL -> .../episode/<id>');

    $pkg->new({ url => 'spoton://connect-99', client => $client });
    is($Slim::Player::Protocols::HTTP::NEW_ARGS[-1]{url}, 'http://127.0.0.1:4242/stream',
        'new(): Connect URL -> http://127.0.0.1:<port>/stream (sync-group proxy)');

    $pkg->new({ url => 'http://example.invalid/a.mp3', client => $client });
    is($Slim::Player::Protocols::HTTP::NEW_ARGS[-1]{url}, 'http://example.invalid/a.mp3',
        'new(): foreign URL falls through unchanged');

    # No alive daemon -> undef, and the base class is never reached.
    @Slim::Player::Protocols::HTTP::NEW_ARGS = ();
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new(alive => 0);
    my $r1 = $pkg->new({ url => 'spoton://track:abc', client => $client });
    ok(!defined $r1, 'new(): Browse URL with no alive daemon -> undef');
    my $r2 = $pkg->new({ url => 'spoton://connect-99', client => $client });
    ok(!defined $r2, 'new(): Connect URL with no alive daemon -> undef');
    is(scalar(@Slim::Player::Protocols::HTTP::NEW_ARGS), 0, 'new(): base class HTTP->new is not called when the daemon is missing');
}

# ============================================================
# G. getNextTrack -- samplesize(16) reset on the librespot Browse path
# ============================================================
{
    reset_state();
    my $client = MockClient->new();

    for my $url ('spoton://track:abc123', 'spoton://episode:ep9') {
        my $track = MockTrack->new(url => $url, samplesize => 32);   # stale soloist hint
        my $song  = MockSong->new(client => $client, track => $track);
        my ($ok, $err) = (0, 0);
        $pkg->getNextTrack($song, sub { $ok++ }, sub { $err++ });
        is($track->samplesize, 16, "getNextTrack($url): stale samplesize 32 is reset to 16 (CR-01)");
        is("$ok/$err", '1/0', "getNextTrack($url): successCb called once, errorCb not");
    }

    my $other = MockTrack->new(url => 'http://example.invalid/a.mp3', samplesize => 32);
    my ($ok, $err) = (0, 0);
    $pkg->getNextTrack(MockSong->new(client => $client, track => $other), sub { $ok++ }, sub { $err++ });
    is($other->samplesize, 32, 'getNextTrack: a non-spoton URL leaves samplesize alone');
    is("$ok/$err", '1/0', 'getNextTrack: non-spoton URL still calls successCb once');
}

# ============================================================
# H. _backendPrereqState -- real DaemonManager.pm, separate process
#
# The in-process DaemonManager above is a stub (the ProtocolHandler tests
# need it controllable), so the real module is loaded in a child perl with
# its own minimal stub set. Only the librespot branch is characterized:
# it returns before touching Soloist.pm, so no further stubs are needed.
# ============================================================
{
    my $dm_stub_dir = tempdir(CLEANUP => 1);
    write_stub($dm_stub_dir, @$_) for @COMMON_STUBS;

    write_stub($dm_stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
sub import { my $caller = caller; no strict 'refs'; *{"${caller}::preferences"} = \&preferences; }
sub preferences { return bless {}, 'Slim::Utils::Prefs' }
sub get { return '/tmp/spoton-test-cachedir' }
sub set { }
sub client { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END
    write_stub($dm_stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new { return bless {}, shift }
sub get { return undef }
sub set { }
sub remove { }
1;
END
    write_stub($dm_stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer { }
1;
END
    write_stub($dm_stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END
    write_stub($dm_stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
}
1;
END
    write_stub($dm_stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
sub new { return bless {}, shift }
1;
END

    my $child = <<'PERL';
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 }; *main::WEBUI = sub () { 0 };
    *main::SCANNER = sub () { 0 }; *main::INFOLOG = sub () { 0 };
    *main::DEBUGLOG = sub () { 0 }; *main::PERFMON = sub () { 0 };
    *main::ISWINDOWS = sub () { 0 }; *main::ISMAC = sub () { 0 };
}
require Plugins::SpotOn::Unified::DaemonManager or die;
for my $b ('librespot', 'bogus-value', undef) {
    my $r = Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState($b);
    print 'STATE[', (defined $b ? $b : 'undef'), ']=', $r, "\n";
}
PERL
    my $out = '';
    {
        local $ENV{SPOTON_MODULE_ROOT};
        open(my $ph, '-|', $^X, "-I$dm_stub_dir", "-I$module_root", '-e', $child)
            or die "cannot start child perl: $!";
        local $/;
        $out = <$ph>;
        close($ph);
    }
    is(($out =~ /^STATE\[librespot\]=(\S+)$/m)[0], 'librespot',
        "_backendPrereqState('librespot') eq 'librespot' (real DaemonManager.pm)");
    is(($out =~ /^STATE\[undef\]=(\S+)$/m)[0], 'librespot',
        "_backendPrereqState(undef) eq 'librespot' (default backend)");
    is(($out =~ /^STATE\[bogus-value\]=(\S+)$/m)[0], 'librespot',
        "_backendPrereqState('bogus-value') eq 'librespot' (fail-safe fallback)");
}

done_testing();
