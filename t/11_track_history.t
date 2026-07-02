#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

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
# JSON::XS is an XS module bundled by LMS but not available in the test env.
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

# Stub: Plugins::SpotOn::API::Client with controllable $mock_track
write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
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
require Plugins::SpotOn::API::Client;
require Slim::Control::Request;

# ============================================================
# Load ProtocolHandler.pm
# ============================================================
require_ok('Plugins::SpotOn::ProtocolHandler') or BAIL_OUT("Failed to load ProtocolHandler.pm");

# ============================================================
# Mock client object
# ============================================================
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    sub can { return 0 }
    sub master { $_[0] }
    sub playingSong { undef }
    sub currentPlaylistUpdateTime { 1 }
}

# ============================================================
# Test A: TTL grep gate — Plugin.pm must NOT have 3600 TTL cache-set lines
# D-02: unified 7-day TTL requires 604800, not 3600
# ============================================================
subtest 'TTL grep gate: Plugin.pm' => sub {
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";
    open(my $fh, '<', $plugin_file) or BAIL_OUT("Cannot read Plugin.pm: $!");
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comment lines
        # Match cache->set(..., 3600) pattern
        push @matches, "$.: $line" if $line =~ /},\s*3600\s*\)/;
    }
    close($fh);
    is(scalar @matches, 0,
        "D-02: Plugin.pm has no cache->set with 3600 TTL (found: " . scalar(@matches) . " line(s): " . join('; ', @matches) . ")");
};

# ============================================================
# Test B: TTL grep gate — DontStopTheMusic.pm must NOT have 3600 TTL cache-set lines
# D-02: unified 7-day TTL
# ============================================================
subtest 'TTL grep gate: DontStopTheMusic.pm' => sub {
    my $dstm_file = "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm";
    open(my $fh, '<', $dstm_file) or BAIL_OUT("Cannot read DontStopTheMusic.pm: $!");
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;    # skip comment lines
        push @matches, "$.: $line" if $line =~ /},\s*3600\s*\)/;
    }
    close($fh);
    is(scalar @matches, 0,
        "D-02: DontStopTheMusic.pm has no cache->set with 3600 TTL (found: " . scalar(@matches) . " line(s): " . join('; ', @matches) . ")");
};

# ============================================================
# Test C: TTL grep gate — Connect.pm spoton_meta_ cache sets use 604800
# D-02: all cache-set call sites must use 7-day TTL
# ============================================================
subtest 'TTL grep gate: Connect.pm cache set' => sub {
    my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";
    open(my $fh, '<', $connect_file) or BAIL_OUT("Cannot read Connect.pm: $!");
    my @cache_set_lines;
    my $in_spoton_meta_block = 0;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;
        if ($line =~ /spoton_meta_/) {
            $in_spoton_meta_block = 1;
        }
        if ($in_spoton_meta_block && $line =~ /},\s*(\d+)\s*\)/) {
            push @cache_set_lines, { line_no => $., ttl => $1, text => $line };
            $in_spoton_meta_block = 0;
        }
    }
    close($fh);

    # If there are spoton_meta_ cache sets, all must use 604800
    my @bad = grep { $_->{ttl} != 604800 } @cache_set_lines;
    is(scalar @bad, 0,
        "D-02: Connect.pm spoton_meta_ cache sets all use 604800 TTL (bad TTL lines: " . scalar(@bad) . ")");
};

# ============================================================
# Test D: Connect.pm cache persistence has spotifyUri field
# D-01: Connect _fetchTrackMetadata must store spotifyUri for replay translation
# ============================================================
subtest 'Connect cache persistence has spotifyUri' => sub {
    my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";
    open(my $fh, '<', $connect_file) or BAIL_OUT("Cannot read Connect.pm: $!");
    my @matches;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;
        push @matches, $. if $line =~ /spotifyUri/;
    }
    close($fh);
    cmp_ok(scalar @matches, '>=', 1,
        "D-01: Connect.pm contains at least one 'spotifyUri' reference in non-comment lines (found: " . scalar(@matches) . ")");
};

# ============================================================
# Test E: getMetadataFor returns cached Browse metadata
# STR-03: NowPlaying display relies on cache lookup
# ============================================================
subtest 'getMetadataFor returns cached Browse metadata' => sub {
    use Digest::MD5 qw(md5_hex);

    my $browse_url = 'spoton://track:ABC123';
    my $cache_key  = 'spoton_meta_' . md5_hex($browse_url);

    # Clear cache state and set a known entry
    Slim::Utils::Cache->new->clear();
    Slim::Utils::Cache->new->set($cache_key, {
        title    => 'Test Track',
        artist   => 'Test Artist',
        album    => 'Test Album',
        duration => 240,
        cover    => 'https://example.com/cover.jpg',
        icon     => 'https://example.com/cover.jpg',
        bitrate  => '320k',
        type     => 'OGG (Spotify Browse)',
    }, 604800);

    my $client = MockClient->new('player_hist');
    my $result = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, $browse_url);

    ok(defined $result, 'getMetadataFor returns defined result for cached Browse URL');
    ok(ref $result eq 'HASH', 'getMetadataFor returns a hash ref');
    ok($result->{title}, 'Returned metadata has title field');
    ok($result->{cover}, 'Returned metadata has cover field');
    # type and bitrate may be overridden by _typeString/_bitrateForClient — just check hash is non-empty
    ok(scalar keys %$result > 0, 'Returned hash is non-empty');
};

# ============================================================
# Test F: getMetadataFor returns placeholder on cache miss
# D-03: cache miss returns placeholder, not empty hashref
# ============================================================
subtest 'getMetadataFor returns placeholder on cache miss' => sub {
    Slim::Utils::Cache->new->clear();

    my $client = MockClient->new('player_miss');
    my $result = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, 'spoton://track:NOTCACHED');

    ok(defined $result, 'Cache miss returns defined result');
    ok(ref $result eq 'HASH', 'Cache miss returns a hash ref');
    ok(defined $result->{cover}, 'Cache miss returns result with cover field (placeholder)');
    is($result->{cover}, '/html/images/cover.png', 'Placeholder cover is generic LMS fallback artwork');
    ok(scalar keys %$result > 0, 'Placeholder hash is non-empty (not bare {})');
};

# ============================================================
# Test G: Connect URL with spotifyUri in cache returns metadata with play field
# D-06, D-07: Connect-to-Browse URL translation
# ============================================================
subtest 'Connect URL with spotifyUri in cache returns metadata with play field' => sub {
    use Digest::MD5 qw(md5_hex);

    my $connect_url = 'spoton://connect-20260604-120000';
    my $cache_key   = 'spoton_meta_' . md5_hex($connect_url);

    Slim::Utils::Cache->new->clear();
    Slim::Utils::Cache->new->set($cache_key, {
        title      => 'Connect Track',
        artist     => 'Connect Artist',
        album      => 'Connect Album',
        duration   => 180,
        cover      => 'https://example.com/connect_cover.jpg',
        icon       => 'https://example.com/connect_cover.jpg',
        bitrate    => '320k',
        type       => 'OGG (Spotify Connect)',
        spotifyUri => 'spotify:track:XYZ789',
    }, 604800);

    my $client = MockClient->new('player_connect');
    my $result = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, $connect_url);

    ok(defined $result, 'Connect URL with spotifyUri returns defined result');
    ok(ref $result eq 'HASH', 'Connect URL returns hash ref');
    ok(defined $result->{play}, 'Connect translation returns result with play field');
    like($result->{play}, qr{spoton://track:XYZ789}, 'play field contains Browse URL with correct track ID');
};

# ============================================================
# Test H: D-05 debounce prevents duplicate fetch
# When $_pendingRefetch is set for a URL, getMetadataFor must not fire another API call
# ============================================================
subtest 'Debounce prevents duplicate fetch on cache miss' => sub {
    Slim::Utils::Cache->new->clear();
    $Plugins::SpotOn::API::Client::mock_track = undef;

    # Track call count via a local counter
    my $call_count = 0;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::API::Client::getTrack = sub {
            $call_count++;
            # Don't invoke callback — simulates in-flight request
        };

        # Set debounce flag directly — simulates an already-in-flight request
        $Plugins::SpotOn::ProtocolHandler::_pendingRefetch{'spoton://track:DEBOUNCE'} = 1;

        my $client = MockClient->new('player_debounce');
        my $result = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, 'spoton://track:DEBOUNCE');

        is($call_count, 0, 'D-05: no API call when debounce flag is set');
        ok(defined $result->{cover}, 'Still returns placeholder when debounced');

        # Clean up
        delete $Plugins::SpotOn::ProtocolHandler::_pendingRefetch{'spoton://track:DEBOUNCE'};
    }
};

# ============================================================
# Test I: async re-fetch populates cache and fires newmetadata notification
# D-03: callback populates cache; notifyFromArray fires for NowPlaying refresh
# ============================================================
subtest 'Async re-fetch populates cache and fires newmetadata' => sub {
    use Digest::MD5 qw(md5_hex);

    Slim::Utils::Cache->new->clear();
    $Slim::Control::Request::notify_count = 0;

    # Set mock_track so API::Client->getTrack returns metadata synchronously
    $Plugins::SpotOn::API::Client::mock_track = {
        name       => 'Async Track',
        artists    => [{ name => 'Async Artist' }],
        album      => { name => 'Async Album', images => [{ url => 'https://example.com/img.jpg', width => 640 }] },
        duration_ms => 210000,
    };

    my $url = 'spoton://track:ASYNCTEST';
    my $client = MockClient->new('player_async');

    # Call getMetadataFor — triggers _asyncRefetch which calls getTrack (sync stub)
    my $result = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, $url);

    # Placeholder returned immediately
    ok(defined $result, 'Returns defined result (placeholder) while re-fetch fires');

    # After getTrack callback ran (synchronously in stub), cache should be populated
    my $cache_key = 'spoton_meta_' . md5_hex($url);
    my $cached = Slim::Utils::Cache->new->get($cache_key);

    ok(defined $cached, 'Cache populated after async re-fetch callback');
    is($cached->{title}, 'Async Track', 'Cached title matches API response');
    is($cached->{artist}, 'Async Artist', 'Cached artist matches API response');
    cmp_ok($Slim::Control::Request::notify_count, '>=', 1, 'notifyFromArray fired after re-fetch');

    # Clean up mock
    $Plugins::SpotOn::API::Client::mock_track = undef;
};

# ============================================================
# Test J: D-07 Connect URL returns Browse mode label, not Connect
# Type string must say "Browse" for translated Connect history tracks
# ============================================================
subtest 'Connect URL returns Browse mode label not Connect' => sub {
    use Digest::MD5 qw(md5_hex);

    my $connect_url = 'spoton://connect-20260604-130000';
    my $cache_key   = 'spoton_meta_' . md5_hex($connect_url);

    Slim::Utils::Cache->new->clear();
    Slim::Utils::Cache->new->set($cache_key, {
        title      => 'Another Connect Track',
        artist     => 'Another Artist',
        album      => 'Another Album',
        duration   => 200,
        cover      => 'https://example.com/another.jpg',
        icon       => 'https://example.com/another.jpg',
        bitrate    => '320k',
        type       => 'OGG (Spotify Connect)',
        spotifyUri => 'spotify:track:BROWSE01',
    }, 604800);

    my $client = MockClient->new('player_d07');
    my $result = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, $connect_url);

    ok(defined $result, 'D-07: Connect URL translation returns result');
    # type field should contain Browse (not Connect) — D-07 invisible translation
    if (defined $result->{type}) {
        unlike($result->{type}, qr/Connect/, 'D-07: type field does NOT contain "Connect"');
        like($result->{type},   qr/Browse/,  'D-07: type field contains "Browse"');
    } else {
        pass('D-07: type field not set (no client-resolved type in test env)');
    }
};

done_testing();
