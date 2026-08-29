#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/ProtocolHandler.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/ProtocolHandler.pm not yet present in this checkout';
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

# ============================================================
# LMS module stubs required to load ProtocolHandler.pm in isolation
# (Phase 72 Wave-0 gap -- ProtocolHandler.pm has never had dedicated test
# coverage before that plan; t/28's write_stub pattern is copied verbatim).
#
# Phase 73-03 Task 3 (D-03, Modell B): rewritten for the persistent-daemon
# dispatch matrix -- soloist Browse now shares the SAME 'soc'/HTTP-/stream
# path as Connect (canDirectStream/new() resolve the daemon's HTTP /stream
# URL) instead of the retired per-track 'sol' transcoder profile.
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

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

# Controllable Prefs stub -- get() reads from a controllable %FAKE hash so
# individual test cases can flip 'backend' without touching the real
# Slim::Utils::Prefs machinery.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
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

write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '127.0.0.1' }
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

# Records constructor args (as a copied hash on the returned blessed object)
# so tests can inspect whether new() substituted the daemon /stream URL.
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

# Minimal stand-in -- ProtocolHandler.pm only needs the CACHE_VERSION
# constant at load time (Cache->new('spoton', SPOTON_CACHE_VERSION())).
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END

# 73-03 Task 3: controllable DaemonManager stub. $HELPER is undef (no
# daemon) by default; test cases assign a Test::FakeSoloistDaemon instance
# to simulate an alive daemon with a known stream port.
# 76-04 Task 2: $RESOLVED stubs resolveSoloistFormat (default 'pcm' so the
# pre-76-04 direct-stream assertions keep passing unchanged); $PASSTHROUGH
# stubs the librespot boolean for formatOverride coverage.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $HELPER;
our $RESOLVED    = 'pcm';
our $PASSTHROUGH = 0;
sub helperForClient             { return $HELPER; }
sub resolveSoloistFormat        { return $RESOLVED; }
sub resolvePassthroughForClient { return $PASSTHROUGH; }
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
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
}

# canSeek()'s LMS-version check compares $::VERSION -- fix it to a value the
# real Slim::Utils::Versions stub is happy with regardless (stub always
# returns 1), but set a plausible LMS version string for realism.
our $VERSION;
$::VERSION = '9.0.0';

unshift @INC, $stub_dir, $project_dir;

# ProtocolHandler.pm calls Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION()
# as a fully-qualified sub at load time -- pre-load the stub so Perl doesn't
# need an implicit require for it.
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Plugin stub");

require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load Plugins::SpotOn::ProtocolHandler");

# new()'s fallthrough calls Slim::Player::Protocols::HTTP->new($args) as a
# fully-qualified call, never require'd by ProtocolHandler.pm itself --
# pre-load the stub so that call resolves.
require_ok('Slim::Player::Protocols::HTTP')
    or BAIL_OUT("Failed to load Slim::Player::Protocols::HTTP stub");

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Unified::DaemonManager stub");

sub reset_backend {
    my ($value) = @_;
    if (defined $value) {
        $Slim::Utils::Prefs::FAKE{backend} = $value;
    } else {
        delete $Slim::Utils::Prefs::FAKE{backend};
    }
}

my $pkg = 'Plugins::SpotOn::ProtocolHandler';

# ============================================================
# Mock client -- can('master') always false (single-player scenario: the
# ternary `$client->can('master') ? $client->master : $client` in
# ProtocolHandler.pm then just uses $client itself), isSynced()
# per-instance controllable.
# ============================================================
{
    package MockClient;
    sub new {
        my ($class, %args) = @_;
        return bless { id => ($args{id} // 'player1'), synced => ($args{synced} // 0) }, $class;
    }
    sub can      { return 0; }
    sub isSynced { return $_[0]->{synced}; }
    sub id       { return $_[0]->{id}; }
}

# 73-03 Task 3: test double for the persistent SoloistDaemon helper.
# Blessed into the REAL class name (Scalar::Util::blessed trickery, per the
# plan) so any future isa() check against it behaves like production code
# would; ProtocolHandler.pm itself only calls alive()/_streamPort()/_ws().
{
    package Plugins::SpotOn::Unified::SoloistDaemon;
    sub new {
        my ($class, %args) = @_;
        return bless { %args }, $class;
    }
    sub alive       { return $_[0]->{alive} // 1; }
    sub _streamPort { return $_[0]->{port}; }
    sub _ws         { return $_[0]->{ws}; }
}

# Fake SoloistWS double -- only the fields ProtocolHandler.pm's soloist
# browse paths read (connected/browseAdvancePending/browseSession) plus a
# recorder for startBrowseTrack (getNextTrack dispatch coverage).
{
    package Test::FakeSoloistWs;
    sub new {
        my ($class, %args) = @_;
        return bless { connected => 1, browseSession => 0, browseAdvancePending => 0, started => [], %args }, $class;
    }
    sub connected             { return $_[0]->{connected}; }
    sub browseSession         { my $self = shift; $self->{browseSession} = shift if @_; return $self->{browseSession}; }
    sub browseAdvancePending  { my $self = shift; $self->{browseAdvancePending} = shift if @_; return $self->{browseAdvancePending}; }
    sub startBrowseTrack      { my ($self, $uri, $client) = @_; push @{ $self->{started} }, $uri; return 1; }
}

# ============================================================
# backend = 'soloist' (D-03, Modell B): daemon alive, unsynced player --
# canDirectStream returns the daemon's HTTP /stream URL directly.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);

    is($pkg->contentType(), 'soc', "contentType() eq 'soc' when backend=soloist (D-03)");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend=soloist (D-03)");
    is($pkg->getFormatForURL('spoton://episode:abc123'), 'soc',
        "getFormatForURL(episode) eq 'soc' when backend=soloist (D-03)");

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDirectStream($client, 'spoton://track:abc123');
    like($result, qr{^http://127\.0\.0\.1:39755/stream$},
        "canDirectStream() returns the daemon /stream URL for an unsynced soloist browse client (D-03)");

    ok($pkg->canSeek($client), "canSeek() truthy when backend=soloist (D-03 lifts the Phase-72 hard 0)");

    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => $client });
    ok(defined $streamObj, "new({url => spoton://track:..., unsynced}) is defined when backend=soloist");
    is($streamObj->{url}, 'spoton://track:abc123',
        "new() leaves the url untouched for an unsynced soloist browse client (falls through unchanged)");
}

# ============================================================
# backend = 'soloist', synced player -- canDirectStream returns 0 (proxy
# handles it); new() substitutes the daemon /stream URL.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);

    my $client = MockClient->new(synced => 1);

    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 for a synced soloist browse client (D-03 -- new() proxy handles it)");

    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => $client });
    ok(defined $streamObj, "new({url => spoton://track:..., synced}) is defined when backend=soloist");
    like($streamObj->{url}, qr{^http://127\.0\.0\.1:39755/stream$},
        "new() substitutes the daemon /stream URL for a synced soloist browse client (D-03 sync-group proxy)");
}

# ============================================================
# backend = 'soloist', no daemon alive -- canDirectStream falls back to 0.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;

    my $client = MockClient->new(synced => 0);
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 when no soloist daemon is alive (daemon backoff owns recovery)");
}

# ============================================================
# backend = 'librespot' (pre-phase behavior unchanged) -- regression net
# for BOTH backends per Task 3 acceptance criteria.
# ============================================================
{
    reset_backend('librespot');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);

    is($pkg->contentType(), 'son', "contentType() eq 'son' when backend=librespot");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend=librespot (pre-phase behavior)");

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDirectStream($client, 'spoton://track:abc123');
    like($result, qr{^http://127\.0\.0\.1:39755/track/abc123$},
        "canDirectStream() returns the daemon /track/{id} URL for an unsynced librespot browse client (unchanged)");

    my $syncedClient = MockClient->new(synced => 1);
    is($pkg->canDirectStream($syncedClient, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 for a synced librespot browse client (unchanged -- new() proxy handles it)");

    ok($pkg->canSeek($client), "canSeek() truthy when backend=librespot");
}

# ============================================================
# backend unset (default -> librespot behavior)
# ============================================================
{
    reset_backend(undef);

    is($pkg->contentType(), 'son', "contentType() eq 'son' when backend is unset (default librespot)");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend is unset (default librespot)");

    ok($pkg->canSeek(MockClient->new), "canSeek() truthy when backend is unset (default librespot)");
}

# ============================================================
# 76-04 Task 2 (D-06/D-07): resolver-gated canDirectStream + formatOverride
# smp routing. The DaemonManager stub's $RESOLVED controls the resolver.
# ============================================================
{
    package MockTrack;
    sub new { return bless { url => $_[1] }, $_[0]; }
    sub url { return $_[0]->{url}; }
}
{
    package MockSong;
    sub new    { my ($class, %args) = @_; return bless { %args }, $class; }
    sub master { return $_[0]->{master}; }
    sub track  { return $_[0]->{track}; }
}

# --- soloist browse: resolved pcm -> direct URL, resolved flac/mp3 -> 0 ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    like($pkg->canDirectStream($client, 'spoton://track:abc123'),
        qr{^http://127\.0\.0\.1:39755/stream$},
        "soloist browse: resolved 'pcm' keeps the direct /stream URL (D-06)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "soloist browse: resolved 'flac' returns 0 (LMS opens the stream and runs the soc transcode rule)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'mp3';
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "soloist browse: resolved 'mp3' returns 0 (forces the smp transcode pipeline)");
}

# --- soloist connect: same gating on the unified connect block ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    like($pkg->canDirectStream($client, 'spoton://connect-1234567890'),
        qr{^http://127\.0\.0\.1:39755/stream$},
        "soloist connect: resolved 'pcm' keeps the direct /stream URL (D-06)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    is($pkg->canDirectStream($client, 'spoton://connect-1234567890'), 0,
        "soloist connect: resolved 'flac' returns 0 (forces the LMS-side transcode pipeline)");
}

# --- librespot connect: explicit pref check unchanged (D-14 regression pin) ---
{
    reset_backend('librespot');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local $Slim::Utils::Prefs::FAKE{streamFormat} = 'mp3';
    is($pkg->canDirectStream($client, 'spoton://connect-1234567890'), 0,
        "librespot connect: explicit streamFormat=mp3 still forces transcoding (unchanged, D-14)");

    $Slim::Utils::Prefs::FAKE{streamFormat} = 'auto';
    like($pkg->canDirectStream($client, 'spoton://connect-1234567890'),
        qr{^http://127\.0\.0\.1:39755/stream$},
        "librespot connect: streamFormat=auto keeps the direct /stream URL (unchanged, D-14)");
}

# --- formatOverride: smp routing (D-07) ---
{
    my $client = MockClient->new(synced => 0);
    my $song = MockSong->new(
        master => $client,
        track  => MockTrack->new('spoton://track:abc123'),
    );

    reset_backend('soloist');
    local $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'mp3';
    is($pkg->formatOverride($song), 'smp',
        "formatOverride: soloist resolved 'mp3' -> 'smp' (single-rule forcing type, D-07)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    is($pkg->formatOverride($song), 'soc',
        "formatOverride: soloist resolved 'flac' -> 'soc' (auto FLAC selection stays with TranscodingHelper, D-05)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    is($pkg->formatOverride($song), 'soc',
        "formatOverride: soloist resolved 'pcm' -> 'soc'");

    # librespot: explicit mp3 pref routes to 'smp' too; auto stays 'soc';
    # passthrough stays 'son' (untouched by the smp branch).
    reset_backend('librespot');
    my $connectSong = MockSong->new(
        master => $client,
        track  => MockTrack->new('spoton://connect-1234567890'),
    );
    local $Slim::Utils::Prefs::FAKE{streamFormat} = 'mp3';
    local $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 0;
    is($pkg->formatOverride($connectSong), 'smp',
        "formatOverride: librespot explicit streamFormat=mp3 -> 'smp' (D-07)");

    $Slim::Utils::Prefs::FAKE{streamFormat} = 'auto';
    is($pkg->formatOverride($connectSong), 'soc',
        "formatOverride: librespot streamFormat=auto without passthrough -> 'soc' (unchanged)");

    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 1;
    is($pkg->formatOverride($connectSong), 'son',
        "formatOverride: librespot passthrough -> 'son' (unchanged, D-14)");
}

done_testing();
