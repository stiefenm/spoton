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
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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

sub remove {
    my (\$self, \$key) = \@_;
    delete \$_store{ \$self->{_ns} }{\$key};
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

# Stub: Plugins::SpotOn::API::SpClient (85-08, decision-D17 pathfinder-login5-plus-
# rootlist) -- getMadeForYou() drives _madeForYouFeed, _hasLogin5Creds() gates the
# Made For You entry of _homeFeed, getPlaylistItems() serves every playlist drill-
# down (Spotify-made 37i9 mixes included). Controllable via $next_has_login5,
# $next_mfy/$next_mfy_err and $next_playlist_items so success, empty-merge and
# error paths can all be exercised without a real SpClient.pm.
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
use constant TRACK_META_FORMAT => 2;   # 79-43 (D-33 FULL-3 CR-01): the format marker of the real module
use constant SPOTON_DEFAULT_CLIENT_ID => 'test-client-id-stub';
use constant SPCLIENT_RATE_LIMIT_KEY => 'spoton_spclient_rate_limit';   # WR-03: tied to SpClient.pm by a source check
our $next_has_login5        = 1;
our $next_mfy               = { items => [], source => 'pathfinder' };
our $next_mfy_err           = undef;
our $next_playlist_items    = { items => [], total => 0 };
our @mfy_calls              = ();
our @playlist_items_calls   = ();
our $next_top               = undef;
our $next_top_err           = undef;
our @top_calls              = ();
our $next_search            = {};
our $next_search_err        = undef;
our @search_calls           = ();
sub _hasLogin5Creds { return $next_has_login5 }
sub getMadeForYou {
    my ($class, $accountId, $cb) = @_;
    push @mfy_calls, [$accountId];
    $cb->($next_mfy, $next_mfy_err);
}
sub getPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    push @playlist_items_calls, [$accountId, $playlistId, $params];
    $cb->($next_playlist_items);
}
sub getTopTracks {
    my ($class, $accountId, $params, $cb) = @_;
    push @top_calls, [$accountId, $params];
    $cb->($next_top, $next_top_err);
}
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    push @search_calls, [$accountId, $params];
    $cb->($next_search, $next_search_err);
}
sub pageLimit { return 10 }
sub reset_calls {
    $next_top             = undef;
    $next_top_err         = undef;
    @top_calls            = ();
    $next_search          = {};
    $next_search_err      = undef;
    @search_calls         = ();
    $next_has_login5      = 1;
    $next_mfy             = { items => [], source => 'pathfinder' };
    $next_mfy_err         = undef;
    $next_playlist_items  = { items => [], total => 0 };
    @mfy_calls            = ();
    @playlist_items_calls = ();
}
1;
END

# 85-14 (D-01): the three TokenManager calls Plugin.pm still makes -- the login
# verdict (hasValidLogin) is controllable per account; everything that used to
# live here (needsReauth, accountNeedsMigration, ...) is deleted.
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our %valid = ();    # accountId => 0|1
our @valid_calls = ();
sub hasValidLogin { my ($class, $id) = @_; push @valid_calls, $id; return $valid{$id} ? 1 : 0 }
sub getActiveAccountName { return 'Test Account' }
sub getAccountIds { return () }
sub reset_stub { %valid = (); @valid_calls = (); }
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

# 85-07 Task 1 (D-09): Up Next comes from the playback backend. Core code
# reaches it only through DaemonManager->backendFor($client)->query('queue');
# this stub stands in for the seam. $next_queue (hashref | undef) is what
# the backend answers; undef = "no queue source" (librespot).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $next_queue = undef;
our @query_calls = ();
sub backendFor {
    my ($class, $clientOrMac) = @_;
    return undef unless defined $clientOrMac;
    return bless {}, 'Plugins::SpotOn::Unified::DaemonManager::StubBackend';
}
sub reset_backend { $next_queue = undef; @query_calls = (); }
package Plugins::SpotOn::Unified::DaemonManager::StubBackend;
sub query {
    my ($self, $what, %args) = @_;
    push @Plugins::SpotOn::Unified::DaemonManager::query_calls, $what;
    return $what eq 'queue' ? $Plugins::SpotOn::Unified::DaemonManager::next_queue : undef;
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
# 85-08 -- _homeFeed Made For You visibility (decision-D17 pathfinder-login5-plus-
# rootlist): listed whenever the account has login5-capable credentials, with no
# WebPlayer read deciding anything. Replaces the Phase 52 sp_dc state gate
# (empty / secrets_down / expired / valid), one-for-one.
# ============================================================
{
    my $client = MockClient->new('player-mfy');
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'mfy-account-id');

    # Test 6: no login5 credentials -- Made For You item hidden entirely.
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_has_login5 = 0;
    my $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    my @names = map { $_->{name}  } @{ $result->{items} };
    ok( !(grep { $_ eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @names),
        'CTX-06: _homeFeed hides Made For You when the account has no login5 credentials' );

    # Test 7: credentials present while the WebPlayer stub reports `empty` --
    # shown: no WebPlayer read decides it any more.
    $Plugins::SpotOn::API::SpClient::next_has_login5 = 1;
    $Plugins::SpotOn::API::WebPlayer::next_state = 'empty';
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    @names = map { $_->{name}  } @{ $result->{items} };
    ok( (grep { $_ eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @names),
        'CTX-07: _homeFeed shows Made For You with login5 credentials although the WebPlayer state is empty' );

    # Test 8: the item drills into _madeForYouFeed; the expired-state feed is gone.
    $Plugins::SpotOn::API::WebPlayer::next_state = 'expired';
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    my ($mfyItem) = grep { $_->{name} eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @{ $result->{items} };
    ok( defined $mfyItem, 'CTX-08: _homeFeed shows Made For You whatever the WebPlayer state says (no expired state)' );
    is( $mfyItem->{type}, 'link', 'CTX-08: Made For You item is a link item' );
    is( $mfyItem->{url}, \&Plugins::SpotOn::Plugin::_madeForYouFeed,
        'CTX-08: Made For You item drills into _madeForYouFeed' );
    ok( !defined &Plugins::SpotOn::Plugin::_madeForYouExpiredFeed,
        'CTX-08: _madeForYouExpiredFeed no longer exists' );

    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_mfy = { source => 'pathfinder', items => [
        { id => '37i9dQZF1abc', name => 'Test Playlist A', images => [] },
    ] };
    my $mfyResult;
    $mfyItem->{url}->($client, sub { $mfyResult = shift }, {});
    is( scalar(@Plugins::SpotOn::API::SpClient::mfy_calls), 1,
        'CTX-08: drilling into Made For You calls getMadeForYou exactly once' );
    is( $mfyResult->{items}[0]{type}, 'playlist',
        'CTX-08: the stubbed mixes come back as playlist items' );

    # Test 9: credentials present -- normal link item pointing at _madeForYouFeed.
    $Plugins::SpotOn::API::WebPlayer::next_state = 'valid';
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    ($mfyItem) = grep { $_->{name} eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @{ $result->{items} };
    ok( defined $mfyItem, 'CTX-09: _homeFeed shows Made For You with login5 credentials' );
    is( $mfyItem->{type}, 'link', 'CTX-09: Made For You item is a link item' );
    is( $mfyItem->{url}, \&Plugins::SpotOn::Plugin::_madeForYouFeed,
        'CTX-09: Made For You item drills into _madeForYouFeed' );
    Plugins::SpotOn::API::SpClient::reset_calls();
}

# ============================================================
# 85-08 -- source assertions (no WebPlayer gate, no cookie-state log lines,
# getMadeForYou behind the feed)
# ============================================================
{
    my $plugin_module = "$project_dir/Plugins/SpotOn/Plugin.pm";
    open(my $fh, '<', $plugin_module) or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);

    my ($homeBody) = $src =~ /(sub _homeFeed\b.*?)(?=\nsub \w|\z)/s;
    ok( defined $homeBody && $homeBody !~ /WebPlayer->state\(/,
        'Plugin.pm: _homeFeed no longer gates on WebPlayer->state' );
    ok( defined $homeBody && $homeBody =~ /_hasLogin5Creds/,
        'Plugin.pm: _homeFeed gates Made For You on SpClient->_hasLogin5Creds' );

    ok( $src !~ /Made For You hidden.*no sp_dc.*D-03/s,
        'Plugin.pm: the D-03 (no sp_dc) hidden log line is gone' );
    ok( $src !~ /Made For You hidden.*TOTP secrets unavailable.*D-05/s,
        'Plugin.pm: the D-05 (TOTP secrets) hidden log line is gone' );

    my ($mfyBody) = $src =~ /(sub _madeForYouFeed\b.*?)(?=\nsub \w|\z)/s;
    ok( defined $mfyBody, 'Plugin.pm: sub _madeForYouFeed found for scoped source assertions' );
    ok( $mfyBody =~ /getMadeForYou/,
        'Plugin.pm: _madeForYouFeed calls SpClient->getMadeForYou' );
    ok( $mfyBody !~ /getPersonalMixes/,
        'Plugin.pm: _madeForYouFeed no longer calls getPersonalMixes in its own body' );

    my $wp_items_calls = () = $src =~ /getWebPlayerPlaylistItems/g;
    is( $wp_items_calls, 0,
        'Plugin.pm: getWebPlayerPlaylistItems is not referenced any more' );
}

# ============================================================
# 85-08 -- getMadeForYou-backed _madeForYouFeed + the playlist drill-down
# through spclient playlist/v2 (decision-D17). Replaces the Phase 52
# pathfinderHome / getWebPlayerPlaylistItems cases, one-for-one.
# ============================================================
{
    my $client = MockClient->new('player-mfy2');
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'mfy-account-id-2');

    # Test 10: successful discovery -- items in the order getMadeForYou returned.
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_mfy = { source => 'pathfinder', items => [
        { id => '37i9dQZF1abc', name => 'Test Playlist A', images => [] },
        { id => '37i9dQZF1def', name => 'Test Playlist B', images => [] },
    ] };

    my $result;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $result = shift }, {});

    is( scalar(@Plugins::SpotOn::API::SpClient::mfy_calls), 1,
        'CTX-10: _madeForYouFeed calls SpClient->getMadeForYou exactly once' );
    is( scalar @{ $result->{items} }, 2,
        'CTX-10: two discovered playlists produce two OPML items' );
    is( $result->{items}[0]{type}, 'playlist', 'CTX-10: item type is playlist' );
    is( $result->{items}[0]{passthrough}[0]{playlistId}, '37i9dQZF1abc',
        'CTX-10: first item passthrough carries the discovered playlist ID' );
    ok( !exists $result->{items}[0]{passthrough}[0]{webPlayer},
        'CTX-10: item passthrough carries no webPlayer flag any more' );
    is( $result->{items}[0]{url}, \&Plugins::SpotOn::Plugin::_playlistFeed,
        'CTX-10: item drills into _playlistFeed' );

    # Test 11: selecting the item reads the tracks via getPlaylistItems (spclient
    # playlist/v2) with the 37i9 id; no Web-Player path exists any more.
    Plugins::SpotOn::API::SpClient::reset_calls();
    my $drillResult;
    $result->{items}[0]{url}->(
        $client, sub { $drillResult = shift }, {}, $result->{items}[0]{passthrough}[0]
    );
    is( scalar(@Plugins::SpotOn::API::SpClient::playlist_items_calls), 1,
        'CTX-11: playlist drill-down calls SpClient->getPlaylistItems exactly once' );
    is( $Plugins::SpotOn::API::SpClient::playlist_items_calls[0][1], '37i9dQZF1abc',
        'CTX-11: getPlaylistItems called with the discovered 37i9 playlist ID' );

    # Test 12: empty merge -- one graceful textarea item, not a die. The string
    # key is deliberately not pinned: the unreachable line is t/core/66's.
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_mfy = { source => 'pathfinder', items => [] };
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
    ok( defined $result->{items}[0]{name} && length $result->{items}[0]{name},
        'CTX-12: empty discovery item carries a non-empty text' );

    # Test 13: a failure from getMadeForYou -- one textarea item, and the raw
    # error reason is not reflected into the menu (Security V7/T-52-02).
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_mfy     = undef;
    $Plugins::SpotOn::API::SpClient::next_mfy_err = { error => 'no_credentials' };
    undef $result;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $result = shift }, {});
    is( scalar @{ $result->{items} }, 1,
        'CTX-13: a getMadeForYou failure renders exactly one item' );
    unlike( $result->{items}[0]{name}, qr/no_credentials/,
        'CTX-13: the raw error reason is not reflected into the menu' );

    Plugins::SpotOn::API::SpClient::reset_calls();
}

# ============================================================
# 85-08 Task 3 -- Top Tracks and search menus on Pathfinder
# (decision-D07 pathfinder, decision-SEARCH pathfinder-search)
# ============================================================
{
    my $client = MockClient->new('player-pf3');
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'pf3-account');
    my $track = sub {
        my ($n) = @_;
        return { id => "T$n", uri => "spotify:track:T$n", name => "Track $n", duration_ms => 180000,
                 artists => [ { id => "A$n", name => "Artist $n" } ],
                 album => { id => "B$n", name => "Album $n", images => [] } };
    };

    # --- Top Tracks ---
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_top = { items => [ $track->(1), $track->(2) ], total => 2 };
    my $r;
    Plugins::SpotOn::Plugin::_topTracksFeed($client, sub { $r = shift }, {});
    is( scalar @{ $r->{items} }, 2, 'CTX-TOP: _topTracksFeed lists the tracks getTopTracks returned' );
    is( $Plugins::SpotOn::API::SpClient::top_calls[0][1]{time_range}, 'medium_term', 'CTX-TOP: the menu asks for medium_term (MID_TERM)' );

    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_top_err = { error => 'hash_broken' };
    undef $r;
    Plugins::SpotOn::Plugin::_topTracksFeed($client, sub { $r = shift }, {});
    ok( scalar(@{ $r->{items} }) == 1 && $r->{items}[0]{type} eq 'textarea' && $r->{items}[0]{name} eq 'PLUGIN_SPOTON_TOP_TRACKS_UNAVAILABLE',
        'CTX-TOP: Top Tracks unavailable line when getTopTracks fails (no silent empty menu)' );

    # --- search overview: one call with the type list ---
    Plugins::SpotOn::API::SpClient::reset_calls();
    $Plugins::SpotOn::API::SpClient::next_search = {
        tracks    => { items => [ $track->(1) ], total => 12 },
        albums    => { items => [], total => 3 },
        artists   => { items => [], total => 0 },
        playlists => { items => [], total => 4 },
    };
    undef $r;
    Plugins::SpotOn::Plugin::_searchFeed($client, sub { $r = shift }, { search => 'jazz' });
    ok( scalar(@Plugins::SpotOn::API::SpClient::search_calls) == 1
        && $Plugins::SpotOn::API::SpClient::search_calls[0][1]{type} eq 'track,album,artist,playlist',
        'CTX-SEARCH: the overview issues ONE SpClient->search call with the type list (one request instead of four)' );
    my @names = map { $_->{name} } @{ $r->{items} };
    ok( (grep { $_ eq 'PLUGIN_SPOTON_TOP_RESULT' } @names) && (grep { $_ eq 'PLUGIN_SPOTON_ALBUMS' } @names) && (grep { $_ eq 'PLUGIN_SPOTON_PLAYLISTS' } @names)
        && !(grep { $_ eq 'PLUGIN_SPOTON_ARTISTS' } @names),
        'CTX-SEARCH: top result and the non-empty sections are listed, empty sections skipped (D-10)' );
    ok( $names[0] ne 'PLUGIN_SPOTON_SEARCH_LIMITED', 'CTX-SEARCH: no limited line when Pathfinder answered' );

    # --- limited ---
    $Plugins::SpotOn::API::SpClient::next_search = { limited => 1, tracks => { items => [ $track->(1) ], total => 5 },
                                                      albums => { items => [], total => 0 }, artists => { items => [], total => 0 }, playlists => { items => [], total => 0 } };
    undef $r;
    Plugins::SpotOn::Plugin::_searchFeed($client, sub { $r = shift }, { search => 'jazz' });
    ok( $r->{items}[0]{type} eq 'textarea' && $r->{items}[0]{name} eq 'PLUGIN_SPOTON_SEARCH_LIMITED',
        'CTX-SEARCH: the limited line comes first when search is limited (tracks only)' );

    $Plugins::SpotOn::API::SpClient::next_search = { limited => 1, albums => { items => [], total => 0 } };
    undef $r;
    Plugins::SpotOn::Plugin::_searchTypeFeed($client, sub { $r = shift }, { index => 0, quantity => 10 }, { query => 'jazz', type => 'album' });
    ok( scalar(@{ $r->{items} }) == 1 && $r->{items}[0]{name} eq 'PLUGIN_SPOTON_SEARCH_LIMITED',
        'CTX-SEARCH: an empty limited type page shows the limited line instead of "no results"' );

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

# Test 16: populated queue -- the playing track renders first (NOW_PLAYING
# prefixed), followed by each upcoming track in order. 85-07 D-09: the data
# comes from the backend role (query('queue')); the Web API queue stub is
# never called.
require Plugins::SpotOn::Unified::DaemonManager;
{
    Plugins::SpotOn::API::Client::reset_queue_calls();
    Plugins::SpotOn::Unified::DaemonManager::reset_backend();
    $Plugins::SpotOn::Unified::DaemonManager::next_queue = {
        current  => { name => 'Now Song', artists => [{ name => 'Now Artist' }], uri => 'spotify:track:NOW1' },
        upcoming => [
            { name => 'Next Song A', artists => [{ name => 'Artist A' }], uri => 'spotify:track:NEXTA' },
            { name => 'Next Song B', artists => [{ name => 'Artist B' }], uri => 'spotify:track:NEXTB' },
        ],
    };

    my $client = MockClient->new('player-upnext1');
    my $result;
    Plugins::SpotOn::Plugin::_upNextFeed($client, sub { $result = shift }, {});

    is( scalar(@Plugins::SpotOn::API::Client::get_queue_calls), 0,
        'CTX-16: _upNextFeed never calls the Web API queue (85-07 D-09: Up Next comes from the playback helper)' );
    is_deeply( \@Plugins::SpotOn::Unified::DaemonManager::query_calls, ['queue'],
        'CTX-16: _upNextFeed asks the backend role exactly once: query(queue)' );
    is( scalar @{ $result->{items} }, 3,
        'CTX-16: populated queue renders 3 items (now playing + 2 queued)' );
    like( $result->{items}[0]{name}, qr/Now Song/,
        'CTX-16: first item is the currently-playing track' );
    like( $result->{items}[1]{name}, qr/Next Song A/,
        'CTX-16: second item is the first queued track, in order' );
    like( $result->{items}[2]{name}, qr/Next Song B/,
        'CTX-16: third item is the second queued track, in order' );
}

# Test 17: nothing playing, nothing queued (an empty answer) -- renders
# exactly one textarea item with the empty-state string, not an error.
{
    Plugins::SpotOn::API::Client::reset_queue_calls();
    Plugins::SpotOn::Unified::DaemonManager::reset_backend();
    $Plugins::SpotOn::Unified::DaemonManager::next_queue = { current => undef, upcoming => [] };

    my $client = MockClient->new('player-upnext2');
    my $result;
    Plugins::SpotOn::Plugin::_upNextFeed($client, sub { $result = shift }, {});

    is( scalar @{ $result->{items} }, 1,
        'CTX-17: no active session renders exactly one item' );
    is( $result->{items}[0]{type}, 'textarea',
        'CTX-17: empty-state item type is textarea' );
    is( $result->{items}[0]{name}, 'PLUGIN_SPOTON_UP_NEXT_EMPTY',
        'CTX-17: empty-state item uses the dedicated empty-state string' );
    is( scalar(@Plugins::SpotOn::API::Client::get_queue_calls), 0,
        'CTX-17: the Web API queue stub is never called' );
}

# Test 18: malformed answer (T-76-14 -- untrusted payload, now from the
# helper cache) does not die and still renders the empty state.
{
    Plugins::SpotOn::API::Client::reset_queue_calls();
    Plugins::SpotOn::Unified::DaemonManager::reset_backend();
    $Plugins::SpotOn::Unified::DaemonManager::next_queue = { current => 'not-a-hash', upcoming => 'not-an-array' };

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

# Test 19 (85-07 D-09): the _homeFeed Up Next item is shown only when the
# backend has a queue source (query('queue') defined); with librespot
# (undef) the item is hidden.
{
    Plugins::SpotOn::Unified::DaemonManager::reset_backend();
    my $client = MockClient->new('player-upnext4');
    $Plugins::SpotOn::API::WebPlayer::next_state = 'valid';

    $Plugins::SpotOn::Unified::DaemonManager::next_queue = { current => undef, upcoming => [] };
    my $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    ok( (grep { $_->{name} eq 'PLUGIN_SPOTON_UP_NEXT' } @{ $result->{items} }),
        'CTX-19: _homeFeed shows Up Next when the backend answers query(queue) (Soloist)' );

    $Plugins::SpotOn::Unified::DaemonManager::next_queue = undef;
    undef $result;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $result = shift }, {});
    ok( !(grep { $_->{name} eq 'PLUGIN_SPOTON_UP_NEXT' } @{ $result->{items} }),
        'CTX-19: _homeFeed hides Up Next when the backend has no queue source (librespot)' );
    ok( (grep { $_->{name} eq 'PLUGIN_SPOTON_RECENTLY_PLAYED' } @{ $result->{items} }),
        'CTX-19: the other Home items are unaffected' );
}

# Test 20 (85-07 D-09 seam): Plugin.pm reaches the queue only through the
# backend role -- no Web API queue call, no Soloist module named.
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);
    my ($body) = $src =~ /(sub _upNextFeed\b.*?)(?=\nsub \w|\z)/s;
    ok( defined $body && $body !~ /getQueue/, 'CTX-20: _upNextFeed does not mention the Web API queue call' );
    ok( defined $body && $body =~ /backendFor\(\$client\)/ && $body =~ /->query\('queue'\)/, "CTX-20: _upNextFeed reads the queue through backendFor(\$client)->query('queue')" );
    ok( $src !~ /Plugins::SpotOn::Soloist|Backend::Soloist/, 'CTX-20: Plugin.pm names no Soloist module (amputation seam)' );
}

# ============================================================
# 85-14 Task 2 (D-01, D-02): pairing hints in the OPML menu
# ============================================================
require Plugins::SpotOn::API::TokenManager;
my $p14 = Slim::Utils::Prefs::preferences('plugin.spoton');

sub feed_items {
    my ($client) = @_;
    my $out;
    Plugins::SpotOn::Plugin::handleFeed($client, sub { $out = shift }, {});
    return @{ $out->{items} || [] };
}
my @gone_hints = qw(PLUGIN_SPOTON_MIGRATION_REQUIRED PLUGIN_SPOTON_REAUTH_REQUIRED
                    PLUGIN_SPOTON_PLAYBACK_AUTH_REQUIRED PLUGIN_SPOTON_BUNDLED_ID_REVOKED
                    PLUGIN_SPOTON_AUTH_REQUIRED);

# CTX-21: an active account without a valid login gets exactly one pairing hint
{
    Plugins::SpotOn::API::TokenManager::reset_stub();
    Slim::Utils::Cache->new()->clear();
    $p14->set('accounts', { acctpair1 => { displayName => 'P', spotifyUserId => 'p' } });
    $p14->set('activeAccount', 'acctpair1');
    my $client = MockClient->new('player-pair1');

    my @items = feed_items($client);
    my @hint = grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING' } @items;
    is(scalar(@hint), 1, 'CTX-21: an active account without a valid login shows exactly one pairing hint');
    is($hint[0]{type}, 'textarea', 'CTX-21: the pairing hint is a textarea item');
    my %names = map { ($_->{name} // '') => 1 } @items;
    is(scalar(grep { $names{$_} } @gone_hints), 0,
        'CTX-21: no PKCE / migration / reauth / playback-auth hint accompanies it');
}

# CTX-22: a valid login and no needsPairing flag -> no hint at all
{
    Plugins::SpotOn::API::TokenManager::reset_stub();
    $Plugins::SpotOn::API::TokenManager::valid{acctpair2} = 1;
    $p14->set('accounts', { acctpair2 => { displayName => 'P', spotifyUserId => 'p' } });
    $p14->set('activeAccount', 'acctpair2');

    my @items = feed_items(MockClient->new('player-pair2'));
    is(scalar(grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING' } @items), 0,
        'CTX-22: an active account with a valid login shows no pairing hint');
}

# WR-03: the rate-limit hint follows the key SpClient writes on a 429
{
    my $hint = sub { scalar grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_RATE_LIMIT_HINT' } @_ };
    my $mk = sub {
        my ($id) = @_;
        Plugins::SpotOn::API::TokenManager::reset_stub();
        Slim::Utils::Cache->new()->clear();
        $Plugins::SpotOn::API::TokenManager::valid{$id} = 1;     # valid login: the pairing hint stays out of the way
        $p14->set('accounts', { $id => { displayName => 'R', spotifyUserId => 'r' } });
        $p14->set('activeAccount', $id);
        return MockClient->new("player-$id");
    };

    require Plugins::SpotOn::API::SpClient;
    my $cache = Slim::Utils::Cache->new();

    my $c1 = $mk->('acctrate1');
    $cache->set(Plugins::SpotOn::API::SpClient::SPCLIENT_RATE_LIMIT_KEY(), Time::HiRes::time() + 30, 30);
    my @items = feed_items($c1);
    is($hint->(@items), 1, 'WR-03: with the SpClient 429 key set the feed shows exactly one rate-limit hint');
    my ($h) = grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_RATE_LIMIT_HINT' } @items;
    is($h ? $h->{type} : 'none', 'textarea', 'WR-03: the rate-limit hint is a textarea item');

    my $c2 = $mk->('acctrate2');
    $cache->set('spoton_rate_limit', Time::HiRes::time() + 30, 30);    # the retired Client.pm key
    is($hint->(feed_items($c2)), 0, 'WR-03: the retired spoton_rate_limit key no longer drives the hint');

    my $c3 = $mk->('acctrate3');
    is($hint->(feed_items($c3)), 0, 'WR-03: with no rate-limit key set the feed shows no hint');

    open(my $fh, '<', "$project_dir/Plugins/SpotOn/API/SpClient.pm") or die $!;
    my $spsrc = do { local $/; <$fh> };
    close($fh);
    my ($declared) = $spsrc =~ /use constant SPCLIENT_RATE_LIMIT_KEY\s*=>\s*'([^']+)'/;
    is(Plugins::SpotOn::API::SpClient::SPCLIENT_RATE_LIMIT_KEY(), $declared // 'undeclared',
        'WR-03: the stub constant equals the key SpClient.pm declares');
    Slim::Utils::Cache->new()->clear();
}

# CTX-23: the migration's needsPairing flag shows the hint even when a login looks valid,
# and still exactly once when both conditions hold
{
    Plugins::SpotOn::API::TokenManager::reset_stub();
    $Plugins::SpotOn::API::TokenManager::valid{acctpair3} = 1;
    $p14->set('accounts', { acctpair3 => { displayName => 'P', spotifyUserId => 'p', needsPairing => 1 } });
    $p14->set('activeAccount', 'acctpair3');
    is(scalar(grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING' } feed_items(MockClient->new('player-pair3'))), 1,
        'CTX-23: a needsPairing account shows the pairing hint');

    $Plugins::SpotOn::API::TokenManager::valid{acctpair3} = 0;
    is(scalar(grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING' } feed_items(MockClient->new('player-pair3'))), 1,
        'CTX-23: needsPairing AND no valid login still shows exactly one hint');
}

# CTX-24: no active account -> no hint (the settings page owns first-time setup)
{
    Plugins::SpotOn::API::TokenManager::reset_stub();
    $p14->set('accounts', {});
    $p14->set('activeAccount', '');
    is(scalar(grep { ($_->{name} // '') eq 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING' } feed_items(MockClient->new('player-pair4'))), 0,
        'CTX-24: no active account shows no pairing hint');
}

# CTX-25: _authRequiredItem
{
    Plugins::SpotOn::API::TokenManager::reset_stub();
    my $item = sub {
        my ($err, $accountId) = @_;
        return Plugins::SpotOn::Plugin::_authRequiredItem(MockClient->new('player-auth'), $accountId, $err);
    };

    $Plugins::SpotOn::API::TokenManager::valid{authok} = 1;
    for my $code (qw(no_credentials invalid_credentials no_token)) {
        is($item->({ error => $code }, 'authok')->{name}, 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING',
            "CTX-25: error $code maps to the pairing hint even with a valid login");
    }
    is($item->(undef, 'authbad')->{name}, 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING',
        'CTX-25: an account without a valid login maps to the pairing hint');
    is($item->(undef, 'authok')->{name}, 'PLUGIN_SPOTON_NO_RESULTS',
        'CTX-25: a valid login and no error is a genuine empty result');
    is($item->({ error => 'internal_error' }, 'authok')->{name}, 'PLUGIN_SPOTON_NO_RESULTS',
        'CTX-25: an unrelated error with a valid login stays "no results"');
    is($item->({ error => 'rate_limited' }, 'authbad')->{name}, 'PLUGIN_SPOTON_RATE_LIMITED',
        'CTX-25: rate_limited wins over the pairing hint (unchanged)');
    is($item->({ error => 'rate_limited_local' }, 'authok')->{name}, 'PLUGIN_SPOTON_RATE_LIMITED',
        'CTX-25: rate_limited_local is unchanged too');
    is($item->({ error => 'no_token' }, 'authok')->{type}, 'textarea', 'CTX-25: the hint is a textarea item');
}

# CTX-26: the source carries no PKCE / migration / reauth reference in these subs
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);
    my ($auth) = $src =~ /(sub _authRequiredItem\b.*?)(?=\nsub \w|\z)/s;
    my ($feed) = $src =~ /(sub handleFeed\b.*?)(?=\nsub \w|\z)/s;
    my $code = join("\n", grep { !/^\s*#/ } split /\n/, ($auth // '') . "\n" . ($feed // ''));
    ok(length $code, 'CTX-26: handleFeed and _authRequiredItem were found in the source');
    unlike($code, qr/PKCE|accountNeedsMigration|anyAccountNeedsReauth|needsReauth|reauthReason|BUNDLED_ID_REVOKED|REAUTH_REQUIRED|MIGRATION_REQUIRED/,
        'CTX-26: handleFeed and _authRequiredItem name no PKCE / migration / reauth thing');
}

# ============================================================
# CTX-27: pkceRemoved one-shot (T-85-27, D-01/D-02)
# ============================================================
{
    my $spoton_dir = File::Spec->catdir($cache_dir, 'spoton');
    my $mk = sub {
        my ($rel, $content) = @_;
        my $f = File::Spec->catfile($spoton_dir, split m{/}, $rel);
        my ($vol, $dirs) = File::Spec->splitpath($f);
        make_path($dirs) unless -d $dirs;
        open(my $out, '>', $f) or die "$f: $!";
        print $out $content;
        close($out);
        return $f;
    };

    my @acct_files = (
        $mk->('aaaa1111/pkce_tokens.json',           '{"refresh_token":"r1"}'),
        $mk->('bbbb2222/pkce_tokens.json',           '{"refresh_token":"r2"}'),
        $mk->('bbbb2222/pkce_tokens.json.tmp.4242',  '{"refresh_token":"partial"}'),
        $mk->('pkce_tokens.json',                    '{"refresh_token":"legacy-flat"}'),
    );
    my $keep_creds = $mk->('aaaa1111/credentials.json', '{"auth_type":1,"username":"u","auth_data":"d"}');
    my $odd_name   = $mk->('odd name/pkce_tokens.json', '{"refresh_token":"odd"}');

    # a symlinked "account" directory that points outside: never followed
    my $outside = File::Temp::tempdir(CLEANUP => 1);
    open(my $of, '>', "$outside/pkce_tokens.json") or die $!;
    print $of '{"refresh_token":"outside"}';
    close($of);
    my $link = File::Spec->catdir($spoton_dir, 'cccc3333');
    my $linked = symlink($outside, $link);

    $p14->set('accounts', {
        aaaa1111 => { displayName => 'A', spotifyUserId => 'a' },
        bbbb2222 => { displayName => 'B', spotifyUserId => 'b' },
    });
    $p14->set('clientId', 'a-custom-client-id');
    $p14->set('pkceRemoved', 0);
    my $c14 = Slim::Utils::Cache->new();
    $c14->set($_, 'x') for qw(spoton_token_aaaa1111 spoton_needs_reauth_aaaa1111 spoton_token_bbbb2222 spoton_needs_reauth_bbbb2222);
    $c14->set('spoton_resp_keepme', 'y');

    ok(Plugins::SpotOn::Plugin->can('_removePkceOnce'), 'CTX-27: Plugin.pm defines _removePkceOnce');
    Plugins::SpotOn::Plugin::_removePkceOnce() if Plugins::SpotOn::Plugin->can('_removePkceOnce');

    is(scalar(grep { -e $_ } @acct_files), 0, 'CTX-27: every pkce_tokens.json (account dirs, leftover .tmp, legacy flat) is deleted');
    ok(-f $keep_creds, 'CTX-27: credentials.json next to a deleted token file survives');
    ok(-f $odd_name, 'CTX-27: a directory whose name is not a plain account id is left alone (ids are regex-checked)');
    SKIP: {
        skip 'symlink not available', 1 unless $linked;
        ok(-f "$outside/pkce_tokens.json", 'CTX-27: a symlinked account directory is never followed');
    }
    ok(!defined $p14->get('clientId'), 'CTX-27: the clientId pref is removed');
    is(scalar(grep { defined $c14->get($_) } qw(spoton_token_aaaa1111 spoton_needs_reauth_aaaa1111 spoton_token_bbbb2222 spoton_needs_reauth_bbbb2222)), 0,
        'CTX-27: the spoton_token_ / spoton_needs_reauth_ cache keys of every account are removed');
    is($c14->get('spoton_resp_keepme'), 'y', 'CTX-27: unrelated cache keys are untouched');
    is($p14->get('pkceRemoved'), 1, 'CTX-27: the pkceRemoved marker is set');

    # idempotency: with the marker set a second run changes nothing
    my $again = $mk->('aaaa1111/pkce_tokens.json', '{"refresh_token":"late"}');
    $p14->set('clientId', 'late-client-id');
    Plugins::SpotOn::Plugin::_removePkceOnce() if Plugins::SpotOn::Plugin->can('_removePkceOnce');
    ok(-f $again && $p14->get('clientId') eq 'late-client-id',
        'CTX-27: the one-shot is idempotent -- a second run is a no-op (file and pref untouched)');

    # wiring in the source: a default of 0 and the call between the intake and init()
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);
    like($src, qr/pkceRemoved\s*=>\s*0/, 'CTX-27: pkceRemoved is initialised to 0 in $prefs->init');
    my ($body) = $src =~ /(sub _startUnifiedDaemons\b.*?)(?=\nsub \w|\z)/s;
    $body = join("\n", grep { !/^\s*#/ } split /\n/, $body // '');    # comments name init() too
    my ($i_auth, $i_pkce, $i_init) = map { length $body ? index($body, $_) : -1 }
        ("'authChainMigrated'", '_removePkceOnce()', 'DaemonManager->init()');
    ok($i_auth >= 0 && $i_pkce > $i_auth && $i_init > $i_pkce,
        'CTX-27: _startUnifiedDaemons runs _removePkceOnce after authChainMigrated and before DaemonManager->init()');
}

Plugins::SpotOn::API::Client::reset_queue_calls();

done_testing();
