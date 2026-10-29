#!/usr/bin/perl
# t/core/74_meta_record_heal.t -- 79-43 (D-33 FULL-3 CR-01, orchestrator decision on the spoton_meta records):
# a spoton_meta_* record written before 79-43 can hold the byte form of a name for 7 days. Every writer that
# stores title, artist or album stamps _spoton_fmt = TRACK_META_FORMAT; getMetadataFor and every other display
# reader treat an unmarked record as a miss (placeholder plus async refetch); readers of other fields keep working.
# The stub bootstrap is the one of t/core/11_track_history.t (dashes replaced, SpClient stub with a call log).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
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

# Stub: Plugins::SpotOn::API::SpClient with controllable $mock_track
# (re-pointed from a Plugins::SpotOn::API::Client stub in Phase 75 Plan 06 --
# ProtocolHandler.pm's _asyncRefetch now calls SpClient->getTrack, D-08)
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
use constant TRACK_META_FORMAT => 2;   # 79-43: the format marker of the real module (API/SpClient.pm)
our $mock_track = undef;
our @getTrack_calls = ();
sub getTrack {
    my ($class, $account_id, $track_id, $cb) = @_;
    push @getTrack_calls, $track_id;
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

# Stub: URI::Escape - not Perl core, bundled by LMS
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
# always compiles Plugin.pm first - provide the constant for standalone loads.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load stubs so subsequent `require` calls inside ProtocolHandler.pm find the stubs.
require Plugins::SpotOn::Helper;
require Plugins::SpotOn::API::SpClient;
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

use Digest::MD5 qw(md5_hex);
require Plugins::SpotOn::Plugin;   # production compiles Plugin.pm first (its helpers serve the refetch path)
my $PH    = 'Plugins::SpotOn::ProtocolHandler';
my $FMT   = Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT();
my $BYTES = "F\xc3\xbcr Elise";   # the byte form beta.1 stored (UTF-8 bytes, no flag)
my $CHARS = "F\x{fc}r Elise";
my $c     = Slim::Utils::Cache->new;
sub rec { my (%o) = @_; return { title => $BYTES, artist => "Bj\xc3\xb6rk", album => "Caf\xc3\xa9", duration => 200,
    cover => 'https://i.scdn.co/image/abc', icon => 'https://i.scdn.co/image/abc', %o } }
sub reset43 { $c->clear(); @Plugins::SpotOn::API::SpClient::getTrack_calls = (); $Plugins::SpotOn::API::SpClient::mock_track = undef;
    %Plugins::SpotOn::ProtocolHandler::_pendingRefetch = () }
my $TRACK = { id => 'G3TRACK', name => $CHARS, artists => [ { name => "Bj\x{f6}rk" } ],
    album => { name => "Caf\x{e9} \x{2615}", images => [ { url => 'https://i.scdn.co/image/abc', width => 640 } ], release_date => '2001-01-01' },
    duration_ms => 200000 };

# G1: an unmarked record holding the byte form -> the placeholder is returned and _asyncRefetch fires, as on a miss
{
    reset43();
    my $url = 'spoton://track:G1TRACK';
    $c->set('spoton_meta_' . md5_hex($url), rec(), 604800);
    my $r = $PH->getMetadataFor(undef, $url);
    is(($r->{title} // 'undef') . '|' . scalar(@Plugins::SpotOn::API::SpClient::getTrack_calls), 'Loading...|1',
        '79-43 G1 (D-33 FULL-3 CR-01): getMetadataFor treats an unmarked byte-form record as a miss (placeholder, one refetch)');
    unlike($r->{title} // '', qr/\xc3/, '79-43 G1: ... and never returns the byte form');
}

# G2: a marked record is returned as today, no refetch
{
    reset43();
    my $url = 'spoton://track:G2TRACK';
    $c->set('spoton_meta_' . md5_hex($url), rec(title => $CHARS, _spoton_fmt => $FMT), 604800);
    my $r = $PH->getMetadataFor(undef, $url);
    is(($r->{title} // 'undef') . '|' . scalar(@Plugins::SpotOn::API::SpClient::getTrack_calls), "$CHARS|0",
        '79-43 G2: a marked record is returned as today with no refetch');
}

# G3 (runtime): the ProtocolHandler writers stamp the marker - the async refetch result, the exploded track and episode
{
    reset43();
    $Plugins::SpotOn::API::SpClient::mock_track = $TRACK;
    my $url = 'spoton://track:G3TRACK';
    $PH->getMetadataFor(undef, $url);
    my $st = $c->get('spoton_meta_' . md5_hex($url)) || {};
    is(($st->{_spoton_fmt} // 'none') . '|' . ($st->{title} // 'undef'), "$FMT|$CHARS",
        '79-43 G3: the record written by the async refetch carries _spoton_fmt = TRACK_META_FORMAT');
    my $r = $PH->getMetadataFor(undef, $url);
    is(($r->{title} // 'undef') . '|' . scalar(@Plugins::SpotOn::API::SpClient::getTrack_calls), "$CHARS|1",
        '79-43 G3: ... so the next getMetadataFor is a hit (no second refetch)');

    reset43();
    Plugins::SpotOn::ProtocolHandler::_cacheExplodedTrack('spoton://track:G3EXPL', $TRACK, "Caf\x{e9}", undef, undef, '2001-01-01');
    Plugins::SpotOn::ProtocolHandler::_cacheExplodedEpisode('spoton://episode:G3EPI',
        { name => $CHARS, duration_ms => 1000, show => { id => 'S1', name => "Bj\x{f6}rk" }, images => [] });
    is(join('|', map { ($c->get('spoton_meta_' . md5_hex($_)) || {})->{_spoton_fmt} // 'none' } 'spoton://track:G3EXPL', 'spoton://episode:G3EPI'),
        "$FMT|$FMT", '79-43 G3: _cacheExplodedTrack and _cacheExplodedEpisode stamp the marker');
}

# G3 (static): every sub in Plugins/** that stores a spoton_meta_ record with names stamps _spoton_fmt
{
    my (@subs, @missing);
    for my $f (qw(Plugin.pm ProtocolHandler.pm Connect.pm DontStopTheMusic.pm)) {
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/$f") or die "$f: $!";
        my ($sub, %body, %writes) = ('(file)');
        my @lines = <$fh>;
        close $fh;
        for my $i (0 .. $#lines) {
            $sub = $1 if $lines[$i] =~ /^sub (\w+)/;
            $body{$sub} .= $lines[$i];
            # a cache set whose key is spoton_meta_ (not spoton_meta_neg_), on this line or the next
            my $two = $lines[$i] . ($lines[$i + 1] // '');
            if ($lines[$i] =~ /\$cache->set\(/ && $two =~ /'spoton_meta_'\s*\.\s*md5_hex/) { $writes{$sub} = 1 }
            if ($lines[$i] =~ /\$cache->set\(\$key, \\%fresh/) { $writes{$sub} = 1 }   # the track-start refresh merge
        }
        for my $s (sort keys %writes) {
            push @subs, "$f:$s";
            push @missing, "$f:$s" unless $body{$s} =~ /_spoton_fmt\s*=>\s*Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT\(\)/;
        }
    }
    cmp_ok(scalar(@subs), '>=', 10, '79-43 G3 static: the audit finds the ten spoton_meta writer subs (' . join(',', @subs) . ')');
    is(join(',', @missing), '', '79-43 G3 static: every spoton_meta writer sub stamps _spoton_fmt => TRACK_META_FORMAT()');
}

# G4: readers of non-name fields keep working on an unmarked record
{
    reset43();
    my $url = 'spoton://track:G4TRACK';
    $c->set('spoton_meta_' . md5_hex($url), rec(cover => 'https://i.scdn.co/image/g4'), 604800);
    is($PH->getIcon($url), 'https://i.scdn.co/image/g4', '79-43 G4: getIcon reads the cover of an unmarked record (no name shown)');

    # an unmarked Connect history record: its spotifyUri still drives the refetch, the browse record is written
    # marked and the history record itself is healed in place (names decoded, marker set, spotifyUri kept)
    reset43();
    $Plugins::SpotOn::API::SpClient::mock_track = { %$TRACK, id => 'G4CONN' };
    my $curl = 'spoton://connect-20261026-130000';
    $c->set('spoton_meta_' . md5_hex($curl), rec(spotifyUri => 'spotify:track:G4CONN', type => 'OGG (Spotify Connect)'), 604800);
    my $r = $PH->getMetadataFor(undef, $curl);
    my $hist  = $c->get('spoton_meta_' . md5_hex($curl)) || {};
    my $brows = $c->get('spoton_meta_' . md5_hex('spoton://track:G4CONN')) || {};
    is(join('|', $Plugins::SpotOn::API::SpClient::getTrack_calls[0] // 'none', $brows->{_spoton_fmt} // 'none'), "G4CONN|$FMT",
        '79-43 G4: an unmarked Connect history record still yields its spotifyUri for the refetch (browse record written marked)');
    is(join('|', $hist->{_spoton_fmt} // 'none', $hist->{title} // 'undef', $hist->{spotifyUri} // 'undef'), "$FMT|$CHARS|spotify:track:G4CONN",
        '79-43 G4: ... and the history record is healed in place (marker, decoded title, spotifyUri kept)');
}

# Plugin.pm display reader (_trackInfoItemsCLI builds a track from title/artist/album): static check of the marker test
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my ($sub, $body) = ('', '');
    while (my $l = <$fh>) { $sub = $1 if $l =~ /^sub (\w+)/; $body .= $l if $sub eq '_trackInfoItemsCLI' }
    close $fh;
    like($body, qr/_spoton_fmt.*TRACK_META_FORMAT\(\)/s, '79-43: _trackInfoItemsCLI treats a record without the current marker as a miss');
}

done_testing();
