#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

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

# Stub: Slim::Utils::Log
# Exports logger() into caller namespace so bare 'logger(...)' calls work
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
sub info     { }
sub warn     { }
sub error    { }
sub debug    { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# Exports preferences() into caller namespace; supports client() for per-player prefs
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
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

# Stub: Slim::Utils::Cache (in-memory, shared package store)
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
# Exports string() and cstring(); identity function (returns key as-is)
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub import {
    my $class = shift;
    my $caller = caller;
    my @requested = @_;
    no strict 'refs';
    for my $fn (@requested) {
        *{"${caller}::${fn}"} = \&{$fn};
    }
}
sub string  { $_[1] }
sub cstring { $_[1] }
1;
END

# Stub: Slim::Utils::Unicode
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

# Stub: Slim::Utils::Versions (imported by ProtocolHandler but not used directly)
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub new         { bless {}, shift }
sub compareVersions { 0 }
sub AUTOLOAD    { }
sub can         { 1 }
1;
END

# Stub: Slim::Utils::Network (provides serverAddr for ProtocolHandler)
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
sub hostName   { 'localhost' }
sub AUTOLOAD   { }
1;
END

# Stub: JSON::XS (delegating to JSON::PP — JSON::XS not available in test env)
write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
use JSON::PP ();
sub encode_json { JSON::PP::encode_json($_[0]) }
sub decode_json { JSON::PP::decode_json($_[0]) }
1;
END

# Stub: JSON::XS::VersionOneAndTwo (used by some LMS modules)
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# Stub: Time::HiRes (pass-through to real module)
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# File::Spec::Functions is a core module — no stub needed, use the real one.
# A previous stub broke File::Spec::catdir resolution when Credentials.pm
# was lazy-loaded after tests completed.

# Stub: Slim::Plugin::OPMLBased (base class for Plugin.pm)
write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new           { bless {}, shift }
sub initPlugin    { }
sub _pluginDataFor { }
sub AUTOLOAD      { }
sub can           { 1 }
1;
END

# Stub: Slim::Player::ProtocolHandlers
write_stub($stub_dir, 'Slim::Player::ProtocolHandlers', <<'END');
package Slim::Player::ProtocolHandlers;
sub registerHandler { }
1;
END

# Stub: Slim::Player::TranscodingHelper (used by Plugin.pm)
write_stub($stub_dir, 'Slim::Player::TranscodingHelper', <<'END');
package Slim::Player::TranscodingHelper;
our %commandTable;
sub getConvertCommand2 { return ('command', 'type', 'F', 'T', 0, 1) }
sub Conversions { return \%commandTable }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Formats::RemoteStream (base class for ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Stub: Slim::Menu::TrackInfo (registerInfoProvider — only needed if initPlugin is called)
write_stub($stub_dir, 'Slim::Menu::TrackInfo', <<'END');
package Slim::Menu::TrackInfo;
sub registerInfoProvider { }
sub menu { }
1;
END

# Stub: Plugins::SpotOn::Helper (used by _typeString in Plugin.pm; lazy-required)
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $helperCapabilities = {};
sub get  { return '/usr/bin/false' }
sub init { }
sub getCapability {
    my ($class, $key) = @_;
    return $helperCapabilities->{$key} if $helperCapabilities && defined $helperCapabilities->{$key};
    return undef;
}
1;
END

# Stub: URI::Escape (bundled by LMS; not in standard Perl)
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape);
sub uri_escape {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
1;
END

# Stub: Plugins::SpotOn::API::WebPlayer (Phase 52 Plan 04 -- state() gates
# Made For You visibility in _homeFeed; controllable via $next_state so
# every degradation branch (empty/secrets_down/expired/valid) can be driven
# from the test without depending on WebPlayer's real internals (Plan 01,
# out of this plan's scope).
write_stub($stub_dir, 'Plugins::SpotOn::API::WebPlayer', <<'END');
package Plugins::SpotOn::API::WebPlayer;
our $next_state = 'valid';
sub state { return $next_state }
1;
END

# Stub: Plugins::SpotOn::API::SpClient (Phase 52 Plan 04 -- pathfinderHome()/
# getWebPlayerPlaylistItems() drive the rewritten _madeForYouFeed and the
# webPlayer-flagged _playlistFeed drill-down; controllable via
# $next_pathfinder_ids/$next_pathfinder_err/$next_wp_items so success,
# empty-discovery, and error paths can all be exercised without a real
# SpClient.pm. Re-pointed from a Plugins::SpotOn::API::Client stub to this
# SpClient stub in Phase 75 Plan 06 (D-08 caller switch) -- pathfinderHome
# and getWebPlayerPlaylistItems are now SpClient passthrough delegations
# (Plan 06 Task 1), so the consumers call SpClient directly.
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
use constant SPOTON_DEFAULT_CLIENT_ID => 'test-client-id-stub';
our $next_pathfinder_ids   = [];
our $next_pathfinder_err   = undef;
our $next_wp_items         = { items => [], total => 0 };
our @pathfinder_home_calls = ();
our @wp_items_calls        = ();
sub pathfinderHome {
    my ($class, $accountId, $params, $cb) = @_;
    push @pathfinder_home_calls, [$accountId, $params];
    $cb->($next_pathfinder_ids, $next_pathfinder_err);
}
sub getWebPlayerPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    push @wp_items_calls, [$accountId, $playlistId, $params];
    $cb->($next_wp_items);
}
sub getPlaylistItems {
    # Should NEVER be called for a Made For You (37i9...) playlist drill-down
    # (Pitfall 3) -- present only so a regression would fail loudly rather
    # than autoloading into nothing.
    die 'getPlaylistItems must not be called for a webPlayer-flagged playlist (Pitfall 3)';
}
sub reset_calls {
    $next_pathfinder_ids   = [];
    $next_pathfinder_err   = undef;
    $next_wp_items         = { items => [], total => 0 };
    @pathfinder_home_calls = ();
    @wp_items_calls        = ();
}
1;
END

# Phase 76-06 gap fill (GH-135): stub for _upNextFeed's on-demand queue
# fetch. Controllable per-test via $next_queue_data/$next_queue_err.
write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
our $next_queue_data = undef;
our $next_queue_err  = undef;
our @get_queue_calls = ();
sub getQueue {
    my ($class, $accountId, $cb) = @_;
    push @get_queue_calls, $accountId;
    $cb->($next_queue_data, $next_queue_err);
}
sub reset_queue_calls {
    $next_queue_data = undef;
    $next_queue_err  = undef;
    @get_queue_calls = ();
}
1;
END

# ============================================================
# main:: constants (LMS constants needed by ProtocolHandler/Plugin)
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

# Add stub dir and project root to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load the Helper stub so lazy 'require Plugins::SpotOn::Helper' finds the stub.
require Plugins::SpotOn::Helper;

# Pre-load the SpClient stub (Phase 52 Plan 04, re-pointed Phase 75 Plan 06)
# -- Plugin.pm's _madeForYouFeed and _playlistFeed call
# Plugins::SpotOn::API::SpClient->... directly without a require in their own
# body (mirrors production, where initPlugin loads it once at startup).
require Plugins::SpotOn::API::SpClient;

# Pre-load the WebPlayer stub too (Phase 52 Plan 04) -- _homeFeed does its own
# lazy 'require ...::WebPlayer' on every call, but require only executes a
# module's top-level code (including its `our $next_state = 'valid'` default)
# on the FIRST load. Pre-loading here, before any test sets $next_state,
# avoids that first-call reset silently clobbering a value set beforehand.
require Plugins::SpotOn::API::WebPlayer;

# ============================================================
# Load Plugin.pm and ProtocolHandler.pm
# M5: Plugin.pm FIRST — it defines SPOTON_CACHE_VERSION, which submodules
# resolve at load time (mirrors production load order).
# ============================================================
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load Plugin.pm");

require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load ProtocolHandler.pm");

# ============================================================
# Mock client object
# A blessed scalar that stringifies predictably for prefs client() namespace.
# ============================================================
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my ($cls, $id) = @_; $id //= 'player1'; bless \$id, $cls }
    sub id  { ${$_[0]} }
    sub can { 0 }  # no master(), currentSongForUrl(), etc.
    sub playingSong { return undef }  # CTX-14: _trackItem -> _bitrateForClient reads this unconditionally
}

# ============================================================
# Test 1: ProtocolHandler does NOT define trackInfoURL
# This is the permanent regression gate (RED before Task 2, GREEN after Task 2).
# ============================================================
# Use symbol table check instead of ->can() to avoid the stub's AUTOLOAD/can override.
# The base class stub (Slim::Formats::RemoteStream) defines 'sub can { 1 }' which
# returns true for any method name. Direct symbol table lookup bypasses that.
ok( !defined(&Plugins::SpotOn::ProtocolHandler::trackInfoURL),
    'CTX-01: trackInfoURL not defined in ProtocolHandler (regression gate)' );

# ============================================================
# Test 2: trackInfoMenu returns undef for non-spoton URLs
# The URL pattern check fails early — no prefs interaction needed.
# ============================================================
{
    my $client = MockClient->new('player-test2');
    my $result = Plugins::SpotOn::Plugin::trackInfoMenu(
        $client, 'http://example.com/test.mp3', {}, {}
    );
    is( $result, undef,
        'CTX-02: trackInfoMenu returns undef for non-spoton URLs' );
}

# ============================================================
# Test 3: trackInfoMenu returns undef when no accountId is available
# _getAccountId returns '' (falsy) because prefs have no activeAccount.
# ============================================================
{
    my $client = MockClient->new('player-test3');
    # Ensure global activeAccount pref is absent (undef)
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', undef);

    my $result = Plugins::SpotOn::Plugin::trackInfoMenu(
        $client, 'spoton://track:NOACCOUNTID', {}, {}
    );
    is( $result, undef,
        'CTX-03: trackInfoMenu returns undef when no accountId is available' );
}

# ============================================================
# Test 4: trackInfoMenu returns 4-item arrayref for a track URL
# with metadata containing artistId, albumId, and year.
# Items: ARTIST_VIEW, ALBUM_VIEW, MANAGE_LIKE, ADD_TO_PLAYLIST
# (YEAR is NOT a separate item — LMS's built-in infoYear provider
# renders it automatically from remoteMeta->{year} / $track->year)
# ============================================================
{
    my $client  = MockClient->new('player-test4');
    my $url     = 'spoton://track:ABC123';

    # Set global accountId (used by _getAccountId fallback)
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'test-account-id');

    # Seed cache with track metadata (key matches trackInfoMenu cache lookup)
    my $cache_key = 'spoton_meta_' . md5_hex($url);
    Slim::Utils::Cache->new()->set($cache_key, {
        title    => 'Test Track Title',
        artist   => 'Test Artist',
        album    => 'Test Album',
        artistId => 'artistABC',
        albumId  => 'albumDEF',
        duration => 240,
        year     => '2021',
    });

    my $result = Plugins::SpotOn::Plugin::trackInfoMenu(
        $client, $url, {}, {}
    );

    ok( defined $result && ref($result) eq 'ARRAY',
        'CTX-04: trackInfoMenu returns arrayref for track URL with artistId+albumId' );

    is( scalar @$result, 4,
        'CTX-04: trackInfoMenu returns exactly 4 items for track with artistId and albumId' );

    my @names  = map { $_->{name}  } @$result;
    ok( (grep { $_ eq 'PLUGIN_SPOTON_ARTIST_VIEW' } @names),
        'CTX-04: item list includes PLUGIN_SPOTON_ARTIST_VIEW' );
    ok( (grep { $_ eq 'PLUGIN_SPOTON_ALBUM_VIEW' } @names),
        'CTX-04: item list includes PLUGIN_SPOTON_ALBUM_VIEW' );
    ok( (grep { $_ eq 'PLUGIN_SPOTON_MANAGE_LIKE' } @names),
        'CTX-04: item list includes PLUGIN_SPOTON_MANAGE_LIKE' );
    ok( (grep { $_ eq 'PLUGIN_SPOTON_ADD_TO_PLAYLIST' } @names),
        'CTX-04: item list includes PLUGIN_SPOTON_ADD_TO_PLAYLIST' );
}

# ============================================================
# Test 5: trackInfoMenu returns 3-item arrayref for an episode URL
# with metadata containing showId and showName.
# Items: SHOW_VIEW, MANAGE_FOLLOW, ADD_TO_PLAYLIST
# ============================================================
{
    my $client = MockClient->new('player-test5');
    my $url    = 'spoton://episode:XYZ789';

    # accountId still set from Test 4
    # Seed cache with episode metadata
    my $cache_key = 'spoton_meta_' . md5_hex($url);
    Slim::Utils::Cache->new()->set($cache_key, {
        title    => 'Test Episode Title',
        artist   => 'Test Show Name',
        showId   => 'show123',
        showName => 'Test Podcast Show',
        duration => 3600,
    });

    my $result = Plugins::SpotOn::Plugin::trackInfoMenu(
        $client, $url, {}, {}
    );

    ok( defined $result && ref($result) eq 'ARRAY',
        'CTX-05: trackInfoMenu returns arrayref for episode URL with showId' );

    is( scalar @$result, 3,
        'CTX-05: trackInfoMenu returns exactly 3 items for episode with showId' );

    my @names = map { $_->{name} } @$result;
    ok( (grep { $_ eq 'PLUGIN_SPOTON_SHOW_VIEW' } @names),
        'CTX-05: item list includes PLUGIN_SPOTON_SHOW_VIEW' );
    ok( (grep { $_ eq 'PLUGIN_SPOTON_MANAGE_FOLLOW' } @names),
        'CTX-05: item list includes PLUGIN_SPOTON_MANAGE_FOLLOW' );
    ok( (grep { $_ eq 'PLUGIN_SPOTON_ADD_TO_PLAYLIST' } @names),
        'CTX-05: item list includes PLUGIN_SPOTON_ADD_TO_PLAYLIST' );
}

# ============================================================
# Phase 52 Plan 04, Task 1 -- _homeFeed Made For You visibility gating
# (D-03/D-04/D-05, the OPML degradation channel)
# ============================================================
{
    my $client = MockClient->new('player-mfy');
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'mfy-account-id');

    # Test 6: state=empty (D-03) -- Made For You item hidden entirely.
    $Plugins::SpotOn::API::WebPlayer::next_state = 'empty';
    my $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    my @names = map { $_->{name} } @{ $result->{items} };
    ok( !(grep { $_ eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @names),
        'CTX-06: _homeFeed hides Made For You when WebPlayer state is empty (D-03)' );

    # Test 7: state=secrets_down (D-05) -- also hidden entirely, distinct cause.
    $Plugins::SpotOn::API::WebPlayer::next_state = 'secrets_down';
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    @names = map { $_->{name} } @{ $result->{items} };
    ok( !(grep { $_ eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @names),
        'CTX-07: _homeFeed hides Made For You when WebPlayer state is secrets_down (D-05)' );

    # Test 8: state=expired (D-04) -- item shown, drills into the expired-hint feed.
    $Plugins::SpotOn::API::WebPlayer::next_state = 'expired';
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    my ($mfyItem) = grep { $_->{name} eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @{ $result->{items} };
    ok( defined $mfyItem, 'CTX-08: _homeFeed shows Made For You when WebPlayer state is expired (D-04)' );
    is( $mfyItem->{type}, 'link', 'CTX-08: expired-state Made For You item is a link item' );
    is( $mfyItem->{url}, \&Plugins::SpotOn::Plugin::_madeForYouExpiredFeed,
        'CTX-08: expired-state Made For You item drills into _madeForYouExpiredFeed' );

    my $expiredResult;
    $mfyItem->{url}->($client, sub { $expiredResult = shift }, {});
    is( scalar @{ $expiredResult->{items} }, 1,
        'CTX-08: expired hint feed returns exactly one item' );
    is( $expiredResult->{items}[0]{name}, 'PLUGIN_SPOTON_SP_DC_EXPIRED_HINT',
        'CTX-08: expired hint feed renders PLUGIN_SPOTON_SP_DC_EXPIRED_HINT' );
    is( $expiredResult->{items}[0]{type}, 'textarea',
        'CTX-08: expired hint item type is textarea' );

    # Test 9: state=valid -- normal link item pointing at _madeForYouFeed.
    $Plugins::SpotOn::API::WebPlayer::next_state = 'valid';
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    ($mfyItem) = grep { $_->{name} eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @{ $result->{items} };
    ok( defined $mfyItem, 'CTX-09: _homeFeed shows Made For You when WebPlayer state is valid' );
    is( $mfyItem->{type}, 'link', 'CTX-09: valid-state Made For You item is a link item' );
    is( $mfyItem->{url}, \&Plugins::SpotOn::Plugin::_madeForYouFeed,
        'CTX-09: valid-state Made For You item drills into _madeForYouFeed' );
}

# ============================================================
# Phase 52 Plan 04, Task 1 -- source assertions (distinct log lines,
# WebPlayer->state gate presence)
# ============================================================
{
    my $plugin_module = "$project_dir/Plugins/SpotOn/Plugin.pm";
    open(my $fh, '<', $plugin_module) or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);

    my $state_calls = () = $src =~ /WebPlayer->state\(/g;
    ok( $state_calls >= 1, 'Plugin.pm: _homeFeed gates on WebPlayer->state' );

    ok( $src =~ /Made For You hidden.*no sp_dc.*D-03/s,
        'Plugin.pm: distinct D-03 (empty) log line present' );
    ok( $src =~ /Made For You hidden.*TOTP secrets unavailable.*D-05/s,
        'Plugin.pm: distinct D-05 (secrets_down) log line present' );

    my ($mfyBody) = $src =~ /(sub _madeForYouFeed\b.*?)(?=\nsub \w|\z)/s;
    ok( defined $mfyBody, 'Plugin.pm: sub _madeForYouFeed found for scoped source assertions' );
    ok( $mfyBody =~ /pathfinderHome/,
        'Plugin.pm: _madeForYouFeed calls Client->pathfinderHome' );
    ok( $mfyBody !~ /getPersonalMixes/,
        'Plugin.pm: _madeForYouFeed no longer calls getPersonalMixes in its own body' );

    my $wp_items_calls = () = $src =~ /getWebPlayerPlaylistItems/g;
    ok( $wp_items_calls >= 1,
        'Plugin.pm: getWebPlayerPlaylistItems referenced (playlist drill-down)' );
}

# ============================================================
# Phase 52 Plan 04, Task 2 -- Pathfinder-backed _madeForYouFeed +
# webPlayer-flagged playlist drill-down (D-07, Pitfall 3)
# ============================================================
{
    my $client = MockClient->new('player-mfy2');
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'mfy-account-id-2');

    # Test 10: successful discovery -- items built via the webPlayer-flagged
    # _playlistItem, in pathfinderHome's returned order (stable sort, no
    # name metadata to discriminate -- RESEARCH A1).
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_pathfinder_ids = [
        { id => '37i9dQZF1abc', name => 'Test Playlist A', images => [] },
        { id => '37i9dQZF1def', name => 'Test Playlist B', images => [] },
    ];
    $Plugins::SpotOn::API::SpClient::next_pathfinder_err = undef;

    my $result;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $result = shift }, {});

    is( scalar(@Plugins::SpotOn::API::SpClient::pathfinder_home_calls), 1,
        'CTX-10: _madeForYouFeed calls Client->pathfinderHome exactly once' );
    is( scalar @{ $result->{items} }, 2,
        'CTX-10: two discovered playlists produce two OPML items' );
    is( $result->{items}[0]{type}, 'playlist', 'CTX-10: item type is playlist' );
    is( $result->{items}[0]{passthrough}[0]{playlistId}, '37i9dQZF1abc',
        'CTX-10: first item passthrough carries the discovered playlist ID' );
    is( $result->{items}[0]{passthrough}[0]{webPlayer}, 1,
        'CTX-10: item passthrough sets webPlayer=1 (Pitfall 3)' );
    is( $result->{items}[0]{url}, \&Plugins::SpotOn::Plugin::_playlistFeed,
        'CTX-10: item drills into _playlistFeed' );

    # Test 11: selecting the item fetches tracks via getWebPlayerPlaylistItems,
    # never getPlaylistItems (Pitfall 3 -- the stub dies if that were called).
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_wp_items = { items => [], total => 0 };
    my $drillResult;
    $result->{items}[0]{url}->(
        $client, sub { $drillResult = shift }, {}, $result->{items}[0]{passthrough}[0]
    );
    is( scalar(@Plugins::SpotOn::API::SpClient::wp_items_calls), 1,
        'CTX-11: playlist drill-down calls Client->getWebPlayerPlaylistItems exactly once' );
    is( $Plugins::SpotOn::API::SpClient::wp_items_calls[0][1], '37i9dQZF1abc',
        'CTX-11: getWebPlayerPlaylistItems called with the discovered playlist ID' );

    # Test 12: empty discovery -- one graceful textarea item, not a die.
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_pathfinder_ids = [];
    $Plugins::SpotOn::API::SpClient::next_pathfinder_err = undef;
    undef $result;
    eval {
        Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $result = shift }, {});
        1;
    } or do {
        fail("CTX-12: _madeForYouFeed died on empty discovery: $@");
    };
    is( scalar @{ $result->{items} }, 1,
        'CTX-12: empty discovery renders exactly one item' );
    is( $result->{items}[0]{type}, 'textarea',
        'CTX-12: empty discovery item type is textarea' );
    is( $result->{items}[0]{name}, 'PLUGIN_SPOTON_NO_RESULTS',
        'CTX-12: empty discovery falls back to the generic NO_RESULTS string' );

    # Test 13: no_secrets failure -- distinct secrets-down message, not the
    # raw error reason reflected into the menu (Security V7/T-52-02).
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_pathfinder_ids = undef;
    $Plugins::SpotOn::API::SpClient::next_pathfinder_err = { error => 'no_secrets' };
    undef $result;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $result = shift }, {});
    is( scalar @{ $result->{items} }, 1,
        'CTX-13: no_secrets failure renders exactly one item' );
    is( $result->{items}[0]{name}, 'PLUGIN_SPOTON_MFY_SECRETS_DOWN',
        'CTX-13: no_secrets failure renders the distinct secrets-down message' );

    Plugins::SpotOn::API::SpClient::reset_calls();
}

# ============================================================
# Phase 76-03 gap fill (Nyquist validation): GH-94 browse context menu
# parity. Prior coverage (this file, pre-76) only exercised trackInfoMenu's
# provider items (Artist/Album/Like); it never asserted the routing change
# itself -- that _trackItem's `info` itemAction dispatches through the
# TrackInfo framework (['spotoninfo','items']) instead of a hand-rolled
# item list, so browse More and Now Playing More share one menu source.
# ============================================================

# Test 14: _trackItem's `info` itemAction routes through the CLI backend
# that calls Slim::Menu::TrackInfo->menu() (_trackInfoItemsCLI), carrying
# the spoton:// url as a fixedParam -- NOT a hand-rolled duplicate list.
{
    my $client = MockClient->new('player-test14');
    my $track  = {
        name        => 'GH94 Song',
        artists     => [ { name => 'GH94 Artist', id => 'art94' } ],
        album       => { name => 'GH94 Album', id => 'alb94', images => [] },
        duration_ms => 123000,
        uri         => 'spotify:track:GH94TRACKID',
    };

    my $item = Plugins::SpotOn::Plugin::_trackItem($client, $track);

    ok( exists $item->{itemActions}{info},
        'CTX-14: _trackItem carries an info itemAction' );
    is_deeply( $item->{itemActions}{info}{command}, ['spotoninfo', 'items'],
        'CTX-14: info itemAction dispatches the spotoninfo/items CLI command (GH-94 routing)' );
    is( $item->{itemActions}{info}{fixedParams}{url}, 'spoton://track:GH94TRACKID',
        'CTX-14: info itemAction carries the item\'s own spoton:// url as fixedParams' );
}

# Test 15: the CLI backend (_trackInfoItemsCLI) is wired to the
# ['spotoninfo','items'] request slot in initPlugin's addDispatch table --
# same command name Test 14 pins on the item side, closing the loop
# between item construction and command registration.
{
    my $plugin_src_file = "$project_dir/Plugins/SpotOn/Plugin.pm";
    open(my $pfh, '<', $plugin_src_file) or die "Cannot read $plugin_src_file: $!";
    local $/;
    my $plugin_src = <$pfh>;
    close($pfh);

    like( $plugin_src, qr/addDispatch\(\s*\[\s*'spotoninfo',\s*'items'[^\]]*\][^;]*?_trackInfoItemsCLI/s,
        'CTX-15: spotoninfo/items CLI command is registered against _trackInfoItemsCLI' );
}

# ============================================================
# Phase 76-06 gap fill (Nyquist validation): GH-135 Up Next OPML feed.
# Prior coverage was i18n (t/02) + syntax only -- this drives the real
# _upNextFeed() with a stubbed API::Client->getQueue and asserts the
# rendered OPML item shape for the populated, empty, and rate-limited
# cases.
# ============================================================

require Plugins::SpotOn::API::Client;

# Test 16: populated queue -- currently_playing renders first (NOW_PLAYING
# prefixed), followed by each queued track in order.
{
    Plugins::SpotOn::API::Client::reset_queue_calls();
    $Plugins::SpotOn::API::Client::next_queue_data = {
        currently_playing => { name => 'Now Song', artists => [{ name => 'Now Artist' }], uri => 'spotify:track:NOW1' },
        queue => [
            { name => 'Next Song A', artists => [{ name => 'Artist A' }], uri => 'spotify:track:NEXTA' },
            { name => 'Next Song B', artists => [{ name => 'Artist B' }], uri => 'spotify:track:NEXTB' },
        ],
    };

    my $client = MockClient->new('player-upnext1');
    my $result;
    Plugins::SpotOn::Plugin::_upNextFeed($client, sub { $result = shift }, {});

    is( scalar(@Plugins::SpotOn::API::Client::get_queue_calls), 1,
        'CTX-16: _upNextFeed calls API::Client->getQueue exactly once (on-demand, GH-135)' );
    is( scalar @{ $result->{items} }, 3,
        'CTX-16: populated queue renders 3 items (now playing + 2 queued)' );
    like( $result->{items}[0]{name}, qr/Now Song/,
        'CTX-16: first item is the currently-playing track' );
    like( $result->{items}[1]{name}, qr/Next Song A/,
        'CTX-16: second item is the first queued track, in order' );
    like( $result->{items}[2]{name}, qr/Next Song B/,
        'CTX-16: third item is the second queued track, in order' );
}

# Test 17: no active session (empty/malformed payload) -- renders exactly
# one textarea item with the empty-state string, not an error.
{
    Plugins::SpotOn::API::Client::reset_queue_calls();
    $Plugins::SpotOn::API::Client::next_queue_data = { currently_playing => undef, queue => [] };

    my $client = MockClient->new('player-upnext2');
    my $result;
    Plugins::SpotOn::Plugin::_upNextFeed($client, sub { $result = shift }, {});

    is( scalar @{ $result->{items} }, 1,
        'CTX-17: no active session renders exactly one item' );
    is( $result->{items}[0]{type}, 'textarea',
        'CTX-17: empty-state item type is textarea' );
    is( $result->{items}[0]{name}, 'PLUGIN_SPOTON_UP_NEXT_EMPTY',
        'CTX-17: empty-state item uses the dedicated empty-state string' );
}

# Test 18: malformed payload (T-76-14 -- untrusted API response) does not
# die and still renders the empty state.
{
    Plugins::SpotOn::API::Client::reset_queue_calls();
    $Plugins::SpotOn::API::Client::next_queue_data = { currently_playing => 'not-a-hash', queue => 'not-an-array' };

    my $client = MockClient->new('player-upnext3');
    my $result;
    eval {
        Plugins::SpotOn::Plugin::_upNextFeed($client, sub { $result = shift }, {});
        1;
    } or fail("CTX-18: _upNextFeed died on a malformed queue payload: $@");
    is( scalar @{ $result->{items} }, 1,
        'CTX-18: malformed payload still renders exactly one (empty-state) item, not a crash' );
    is( $result->{items}[0]{type}, 'textarea',
        'CTX-18: malformed payload renders the textarea empty-state, not partial/garbage items' );
}

Plugins::SpotOn::API::Client::reset_queue_calls();

done_testing();
