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

# Stub: File::Spec::Functions (delegates to real File::Spec)
write_stub($stub_dir, 'File::Spec::Functions', <<'END');
package File::Spec::Functions;
use parent 'Exporter';
use File::Spec ();
our @EXPORT_OK = qw(catdir catfile);
*catdir  = \&File::Spec::catdir;
*catfile = \&File::Spec::catfile;
1;
END

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
# with metadata containing artistId and albumId.
# Items: ARTIST_VIEW, ALBUM_VIEW, MANAGE_LIKE, ADD_TO_PLAYLIST
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
    });

    my $result = Plugins::SpotOn::Plugin::trackInfoMenu(
        $client, $url, {}, {}
    );

    ok( defined $result && ref($result) eq 'ARRAY',
        'CTX-04: trackInfoMenu returns arrayref for track URL with artistId+albumId' );

    is( scalar @$result, 4,
        'CTX-04: trackInfoMenu returns exactly 4 items for track with artistId and albumId' );

    my @names = map { $_->{name} } @$result;
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

done_testing();
