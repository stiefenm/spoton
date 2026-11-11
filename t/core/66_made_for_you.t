#!/usr/bin/perl
use strict;
use warnings;
no warnings "once";   # cross-package stub var access below (t/core/36 pattern)
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);
use JSON::PP ();

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

sub remove {
    my (\$self, \$key) = \@_;
    delete \$_store{ \$self->{_ns} }{\$key};
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


# ============================================================
# 85-08: Made for You, Top Tracks and search on Pathfinder (decision-D17
# pathfinder-login5-plus-rootlist, decision-D07 pathfinder, decision-SEARCH
# pathfinder-search). Real SpClient.pm + Pathfinder.pm + Plugin.pm against an
# in-memory SimpleAsyncHTTP stub; the fixture is the trimmed, redacted 85-04
# capture set (t/fixtures/pathfinder/85-04-trimmed.json).
# ============================================================

# --- logger that records, so the test can assert no secret reaches the log ---
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @LOG = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info     { push @LOG, ['info',  $_[1]] }
sub warn     { push @LOG, ['warn',  $_[1]] }
sub error    { push @LOG, ['error', $_[1]] }
sub debug    { push @LOG, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# --- SimpleAsyncHTTP: rule driven, can park responses (burst / coalesce) ---
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @requests = ();
our @rules    = ();      # [ qr/url/, $handler ]  handler: content | [content,...] | CODE($entry) -> ($code,$content,\%hdr)
our $hold_re  = undef;   # URLs matching this are parked in @held until release_one()
our @held     = ();
our $inflight = 0;
our $max_inflight = 0;

sub set_rule { my ($pat, $h) = @_; unshift @rules, [ $pat, $h ]; }
sub reset {
    @requests = (); @rules = (); @held = ();
    $hold_re = undef; $inflight = 0; $max_inflight = 0;
}
sub new { my ($class, $ok, $err, $opts) = @_; return bless { ok => $ok, err => $err, opts => $opts || {} }, $class; }
sub get  { _dispatch(shift, 'GET',  @_) }
sub post { _dispatch(shift, 'POST', @_) }

sub _dispatch {
    my ($self, $method, $url, @rest) = @_;
    my $body;
    $body = pop @rest if @rest % 2 == 1;
    my %headers = @rest;
    my $e = { method => $method, url => $url, headers => \%headers, body => $body, self => $self };
    push @requests, $e;
    # runaway guard: an unbounded retry must end in a failing assertion, not in memory exhaustion
    die "runaway: more than 60 requests since reset" if @requests > 60;

    if ($url =~ /apresolve\.spotify\.com/) {
        $self->{ok}->(bless { _content => '{"spclient":["test-spclient.example.com:443"]}', _code => 200 },
            'Slim::Networking::SimpleAsyncHTTP::Response');
        return;
    }
    if (defined $hold_re && $url =~ $hold_re) {
        push @held, $e;
        $inflight++;
        $max_inflight = $inflight if $inflight > $max_inflight;
        return;
    }
    _answer($e);
}

sub release_one {
    my $e = shift @held or return 0;
    $inflight--;
    _answer($e);
    return 1;
}

sub _answer {
    my ($e) = @_;
    my ($code, $content, $hdrs) = (404, '', {});
    for my $r (@rules) {
        next unless $e->{url} =~ $r->[0];
        my $h = $r->[1];
        if    (ref $h eq 'CODE')  { ($code, $content, $hdrs) = $h->($e) }
        elsif (ref $h eq 'ARRAY') { $content = @$h > 1 ? shift(@$h) : $h->[0]; $code = 200 }
        else                      { ($code, $content) = (200, $h) }
        last;
    }
    my $self = $e->{self};
    if ($code == 200) {
        $self->{ok}->(bless { _content => $content, _code => 200 }, 'Slim::Networking::SimpleAsyncHTTP::Response');
    }
    elsif ($code == 0) {
        $self->{err}->($self, 'Connect timed out', undef);
    }
    else {
        $self->{err}->($self, "$code error", bless { _code => $code, _headers => $hdrs || {} },
            'Slim::Networking::SimpleAsyncHTTP::MockResponse');
    }
}

package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{_content} }
sub code    { $_[0]->{_code} }

package Slim::Networking::SimpleAsyncHTTP::MockResponse;
sub code   { $_[0]->{_code} }
sub header { $_[0]->{_headers}{$_[1]} }
sub can    { 1 }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
our $mock_token = 'mock_login5_bearer_token';
our @getToken_calls = ();
sub getToken {
    my ($class, $accountId, $cb) = @_;
    push @getToken_calls, $accountId;
    $cb->($mock_token, undef);
}
sub reset_calls { @getToken_calls = () }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our $mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
sub verifyCredentials { return $mock_creds }
1;
END

# D-20: the Made-for-You feed never consults the playback backend. The seam
# dies while $forbid is set; _homeFeed legitimately asks it (Up Next).
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $forbid = 0;
our @backendFor_calls = ();
sub backendFor {
    my ($class, $clientOrMac) = @_;
    push @backendFor_calls, $clientOrMac;
    die "backendFor must not be called here (D-20)" if $forbid;
    return undef unless defined $clientOrMac;
    return bless {}, 'Plugins::SpotOn::Unified::DaemonManager::StubBackend';
}
package Plugins::SpotOn::Unified::DaemonManager::StubBackend;
sub query { return undef }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
# 85-14 (D-01): the only TokenManager call the OPML error branch still makes.
sub hasValidLogin { 1 }
1;
END

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

unshift @INC, $stub_dir, $project_dir;

{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my ($cls, $id) = @_; $id //= 'player1'; bless \$id, $cls }
    sub id  { ${$_[0]} }
    sub can { 0 }
    sub playingSong { return undef }
}

require Plugins::SpotOn::Helper;
require Plugins::SpotOn::API::Login5;          # stubs, loaded up front so reset_all() can reach their package variables
require Plugins::SpotOn::API::Credentials;
require Plugins::SpotOn::API::TokenManager;
require Plugins::SpotOn::Unified::DaemonManager;
require_ok('Plugins::SpotOn::Plugin') or BAIL_OUT('Failed to load Plugin.pm');

# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------
sub t_block {
    my ($name, $code) = @_;
    my $ok = eval { $code->(); 1 };
    unless ($ok) {
        my $e = $@; $e =~ s/\s+\z//;
        fail("$name: block died: $e");
    }
}

my $SP  = 'Plugins::SpotOn::API::SpClient';
my $PF  = 'Plugins::SpotOn::API::Pathfinder';
my $CK  = Slim::Utils::Cache->new();
my $JSON = JSON::PP->new->utf8->canonical;

my $SECTION_MFY = 'spotify:section:0JQ5DAUnp4wcj0bCb3wh3S';
my $SECTION_TOP = 'spotify:section:0JQ5DAnM3wGh0gz1MXnu89';
my $DJ_URI      = 'spotify:playlist:37i9dQZF1EYkqdzj48dyYq';
my $HASH_OLD    = 'a' x 64;
my $HASH_NEW    = 'b' x 64;

my $FX = do {
    my $f = "$project_dir/t/fixtures/pathfinder/85-04-trimmed.json";
    open(my $fh, '<:raw', $f) or BAIL_OUT("cannot read fixture $f: $!");
    local $/; JSON::PP->new->utf8->decode(<$fh>);
};

ok(eval { require Plugins::SpotOn::API::SpClient; 1 }, 'SpClient.pm loads') or diag $@;
my $pf_loaded = eval { require Plugins::SpotOn::API::Pathfinder; 1 };
ok($pf_loaded, 'Pathfinder.pm loads') or diag $@;

sub clone { $JSON->decode($JSON->encode($_[0])) }

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset();
    $CK->clear();
    @Slim::Utils::Log::LOG = ();
    $Plugins::SpotOn::Unified::DaemonManager::forbid = 0;
    @Plugins::SpotOn::Unified::DaemonManager::backendFor_calls = ();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
    $Plugins::SpotOn::API::Login5::mock_token = 'mock_login5_bearer_token';
    Plugins::SpotOn::API::Login5::reset_calls();
    Plugins::SpotOn::API::SpClient->reset();
    Plugins::SpotOn::API::Pathfinder->reset() if Plugins::SpotOn::API::Pathfinder->can('reset');
}

sub seed_hash { $CK->set('spoton_pf_hash_' . $_[0], $_[1]); }
sub pf_requests {
    return grep { $_->{url} =~ m{api-partner\.spotify\.com/pathfinder/v2/query} } @Slim::Networking::SimpleAsyncHTTP::requests;
}
sub pf_body { return JSON::PP->new->utf8->decode($_[0]{body}); }
sub http_rule { Slim::Networking::SimpleAsyncHTTP::set_rule(@_); }

# Pathfinder answers from the fixture: homeSection by section uri
sub pf_fixture_responder {
    return sub {
        my ($e) = @_;
        my $req = pf_body($e);
        if (($req->{operationName} // '') eq 'homeSection') {
            my $uri = $req->{variables}{uri} // '';
            my $fx  = $uri eq $SECTION_MFY ? $FX->{homeSection_mfy}
                    : $uri eq $SECTION_TOP ? $FX->{homeSection_topmix} : undef;
            return (200, $JSON->encode($fx)) if $fx;
        }
        return (200, '{"data":{}}');
    };
}

# web player page + one bundle; the bundle declares the ops the scrape caches
my $BUNDLE_URL = 'https://open.spotifycdn.com/cdn/build/web-player/web-player.TEST.js';
sub scrape_rules {
    my (%o) = @_;
    my $hash = $o{hash} // $HASH_NEW;
    my $html = '<html><script src="' . $BUNDLE_URL . '"></script>'
             . '<script src="http://open.spotifycdn.com/cdn/plain-http.js"></script>'
             . '<script src="https://evil.example/cdn/evil.js"></script></html>';
    http_rule(qr{^https://open\.spotify\.com/$}, $html);
    http_rule(qr{^\Q$BUNDLE_URL\E$},
        'x=[new i.l("home","query","' . $hash . '"),new i.l("homeSection","query","' . $hash . '"),'
        . 'new i.l("decoyShort","query","abc123"),new i.l("decoyUpper","query","' . ('A' x 64) . '")];');
}

# rootlist protobuf (fallback leg)
sub encode_rootlist_item { return Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $_[0]); }
sub encode_rootlist_decoration {
    my (%a) = @_;
    my $b = '';
    # 261110-k1b: revision (field 1), picture (attributes field 3), picture_size (attributes field 13, [[target, url], ...])
    $b .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $a{revision}) if defined $a{revision};
    if (defined $a{name} || defined $a{picture} || $a{picture_size}) {
        my $attrs = '';
        $attrs .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $a{name}) if defined $a{name};
        $attrs .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $a{picture}) if defined $a{picture};
        for my $ps (@{ $a{picture_size} || [] }) {
            $attrs .= Plugins::SpotOn::API::ProtobufLite::encode_field(13, 2, Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $ps->[0]) . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $ps->[1]));
        }
        $b .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $attrs);
    }
    $b .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 0, $a{track_count} // 0);
    $b .= Plugins::SpotOn::API::ProtobufLite::encode_field(5, 2, $a{owner}) if defined $a{owner};
    return $b;
}
sub rootlist_bytes {
    my (@pairs) = @_;    # ([uri, name], ...)
    my $list = '';
    $list .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, encode_rootlist_item($_->[0])) for @pairs;
    $list .= Plugins::SpotOn::API::ProtobufLite::encode_field(4, 2, encode_rootlist_decoration(name => $_->[1], owner => 'testuser', track_count => 5)) for @pairs;
    return Plugins::SpotOn::API::ProtobufLite::encode_field(5, 2, $list);
}
my @ROOTLIST = (
    ['spotify:playlist:37i9dQZF1E3a6pKpVe40mF', 'Daily Mix 1'],
    ['spotify:playlist:0000000000000000000001', 'My own list'],
    [$DJ_URI,                                   'DJ'],
    ['spotify:playlist:37i9dQZEVXcLuBdTdkGtju', 'Discover Weekly'],
    ['spotify:playlist:37i9dQZEVXbkoDWHZvXaFe', 'Release Radar'],
);
sub rootlist_rule { http_rule(qr{/playlist/v2/user/.+/rootlist}, rootlist_bytes(@ROOTLIST)); }

# 261110-k1b: a rootlist reply from hashes { id, name, owner, revision, picture, picture_size }
sub k1b_rootlist_bytes {
    my (@defs) = @_;
    my $list = '';
    for my $d (@defs) {
        $list .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, encode_rootlist_item('spotify:playlist:' . $d->{id}));
    }
    for my $d (@defs) {
        $list .= Plugins::SpotOn::API::ProtobufLite::encode_field(4, 2, encode_rootlist_decoration(
            name => $d->{name}, owner => $d->{owner}, track_count => $d->{tracks} // 5,
            (defined $d->{revision}     ? (revision => $d->{revision})         : ()),
            (defined $d->{picture}      ? (picture => $d->{picture})           : ()),
            ($d->{picture_size}         ? (picture_size => $d->{picture_size}) : ())));
    }
    return Plugins::SpotOn::API::ProtobufLite::encode_field(5, 2, $list);
}

# run getMadeForYou to completion
sub run_mfy {
    my ($acct) = @_;
    my ($res, $err, $called);
    Plugins::SpotOn::API::SpClient->getMadeForYou($acct // 'acct1', sub { ($res, $err) = @_; $called++ });
    return ($res, $err, $called);
}
sub names_of { return [ map { $_->{name} } @{ $_[0]{items} || [] } ]; }
sub uris_of  { return [ map { $_->{uri}  } @{ $_[0]{items} || [] } ]; }

# ============================================================
# PF query: the measured header set, no client token, no cookie (D-17)
# ============================================================
t_block('PF headers', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });

    my @pf = pf_requests();
    is(scalar(@pf), 1, 'PF headers: exactly one POST to the Pathfinder endpoint');
    ok($res && !$err, 'PF headers: the query answered with the decoded response');
    my $h = $pf[0]{headers};
    is($h->{'Authorization'}, 'Bearer mock_login5_bearer_token', 'PF headers: Authorization is the login5 bearer');
    is($h->{'User-Agent'}, Plugins::SpotOn::API::Pathfinder::PF_USER_AGENT(), 'PF headers: User-Agent equals PF_USER_AGENT (set explicitly)');
    like($h->{'User-Agent'}, qr{^Mozilla/5\.0 \(}, 'PF headers: the pinned User-Agent is the browser form beginning "Mozilla/5.0 ("');
    is($h->{'App-Platform'}, 'WebPlayer', 'PF headers: App-Platform WebPlayer');
    is($h->{'Origin'}, 'https://open.spotify.com', 'PF headers: Origin');
    is($h->{'Referer'}, 'https://open.spotify.com/', 'PF headers: Referer');
    is($h->{'spotify-app-version'}, Plugins::SpotOn::API::Pathfinder::PF_APP_VERSION(), 'PF headers: spotify-app-version equals PF_APP_VERSION');
    is($h->{'Content-Type'}, 'application/json;charset=UTF-8', 'PF headers: Content-Type');
    is($h->{'Accept'}, 'application/json', 'PF headers: Accept');
    ok(!(grep { lc($_) eq 'client-token' } keys %$h), 'PF headers: no client-token header');
    ok(!(grep { lc($_) eq 'cookie' } keys %$h), 'PF headers: no Cookie header');
    ok(!(grep { $_->[1] =~ /mock_login5_bearer_token/ } @Slim::Utils::Log::LOG), 'PF headers: the bearer never reaches the log');

    my $b = pf_body($pf[0]);
    is($b->{operationName}, 'homeSection', 'PF body: operationName');
    is($b->{extensions}{persistedQuery}{version}, 1, 'PF body: persistedQuery version 1');
    is($b->{extensions}{persistedQuery}{sha256Hash}, $HASH_OLD, 'PF body: sha256Hash is the cached hash of the op');
    is($b->{variables}{uri}, $SECTION_MFY, 'PF body: the section uri travels in the variables');
});

# ============================================================
# Cold hash cache: one scrape, https/CDN only, 64-hex triples only
# ============================================================
t_block('PF scrape', sub {
    reset_all();
    scrape_rules();
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });

    my @r = @Slim::Networking::SimpleAsyncHTTP::requests;
    my @page   = grep { $_->{url} eq 'https://open.spotify.com/' } @r;
    my @bundle = grep { $_->{url} eq $BUNDLE_URL } @r;
    is(scalar(@page), 1, 'PF scrape: the web player page is fetched once');
    is(scalar(@bundle), 1, 'PF scrape: the listed CDN bundle is fetched once');
    is(scalar(grep { $_->{url} =~ m{plain-http|evil\.example} } @r), 0, 'PF scrape: only https URLs under open.spotifycdn.com are fetched (T-85-31)');
    is($page[0]{headers}{'User-Agent'}, Plugins::SpotOn::API::Pathfinder::PF_USER_AGENT(), 'PF scrape: the page request carries the pinned User-Agent');
    ok(!(grep { lc($_) eq 'cookie' } keys %{ $page[0]{headers} }), 'PF scrape: the page request carries no Cookie header');
    is($CK->get('spoton_pf_hash_homeSection'), $HASH_NEW, 'PF scrape: the homeSection hash is cached');
    is($CK->get('spoton_pf_hash_home'), $HASH_NEW, 'PF scrape: the home hash is cached');
    ok(!defined $CK->get('spoton_pf_hash_decoyShort') && !defined $CK->get('spoton_pf_hash_decoyUpper'),
        'PF scrape: a triple whose hash is not 64 lowercase hex is never cached (T-85-31)');
    my @pf = pf_requests();
    is(scalar(@pf), 1, 'PF scrape: one query after the scrape');
    is(pf_body($pf[0])->{extensions}{persistedQuery}{sha256Hash}, $HASH_NEW, 'PF scrape: the query uses the scraped hash');
    ok($res && !$err, 'PF scrape: the query succeeds on the scraped hash');
});

# ============================================================
# Proactive burst prevention (P-01 / NFL-03)
# ============================================================
t_block('PF coalesce', sub {
    reset_all();
    scrape_rules();
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{^https://open\.spotify\.com/$};

    my @done;
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { push @done, 'a' });
    $PF->query('acct1', 'homeSection', { uri => $SECTION_TOP }, sub { push @done, 'b' });
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { push @done, 'c' });
    my $during = scalar(grep { $_->{url} eq 'https://open.spotify.com/' } @Slim::Networking::SimpleAsyncHTTP::requests);
    is(scalar(pf_requests()), 0, 'PF coalesce: no query is sent while the scrape runs');

    $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
    Slim::Networking::SimpleAsyncHTTP::release_one();

    my $pages = scalar(grep { $_->{url} eq 'https://open.spotify.com/' } @Slim::Networking::SimpleAsyncHTTP::requests);
    ok($during == 1 && $pages == 1 && scalar(@done) == 3 && scalar(pf_requests()) == 3,
        'PF coalesce: concurrent cold-cache queries share one scrape');
});

t_block('PF burst', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};

    my @order;
    for my $i (1 .. 5) {
        $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY, n => $i }, sub { push @order, $i });
    }
    my $first = scalar(@Slim::Networking::SimpleAsyncHTTP::held);
    while (Slim::Networking::SimpleAsyncHTTP::release_one()) { }

    ok($first == 2 && $Slim::Networking::SimpleAsyncHTTP::max_inflight <= 2
        && join(',', @order) eq '1,2,3,4,5' && scalar(pf_requests()) == 5,
        'PF burst: at most 2 in flight, rest queued');
    is($first, 2, 'PF burst: exactly PF_MAX_CONCURRENT (2) requests were outstanding at the start');
    is(join(',', @order), '1,2,3,4,5', 'PF burst: all five answered in order of issue');
});

# ============================================================
# isolated 429 pool and reset
# ============================================================
t_block('PF 429', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (429, '', { 'Retry-After' => '7' }) });

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });
    is($err->{error}, 'rate_limited', 'PF 429: the callback gets rate_limited');
    ok($CK->get('spoton_wp_rate_limit'), 'PF 429: Retry-After lands in PF_RATE_LIMIT_KEY (spoton_wp_rate_limit)');
    is($CK->ttl('spoton_wp_rate_limit'), 7, 'PF 429: the key lives for the Retry-After seconds');
    ok(!$CK->get('spoton_rate_limit'), 'PF 429: the Browse key spoton_rate_limit is untouched');

    my $before = scalar(pf_requests());
    my ($res2, $err2);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res2, $err2) = @_ });
    is(scalar(pf_requests()), $before, 'PF 429: while the key is set no request is sent');
    is($err2->{error}, 'rate_limited', 'PF 429: and the callback still gets rate_limited');
});

t_block('PF reset', sub {
    reset_all();
    $CK->set('spoton_wp_rate_limit', 1, 300);
    ok(defined $CK->get('spoton_wp_rate_limit'), 'PF reset: precondition, the key is set');
    $PF->reset();
    ok(!defined $CK->get('spoton_wp_rate_limit'), 'PF reset: Pathfinder->reset clears PF_RATE_LIMIT_KEY');

    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($init) = $src =~ /(sub initPlugin\b.*?)(?=\nsub \w)/s;
    ok(defined $init && $init =~ /API::Pathfinder->reset\(\)/ && $init =~ /require Plugins::SpotOn::API::Pathfinder/,
        'PF reset: rate-limit key cleared, wired in initPlugin');
});

# ============================================================
# Cookie-free: LMS' shared cookie jar must not carry Spotify cookies
# ============================================================
t_block('PF cookies', sub {
    {
        package FakeJar;
        sub new { bless { c => [ ['.spotify.com', '/', 'sp_t', 'x'], ['open.spotify.com', '/', 'sp_landing', 'y'], ['example.org', '/', 'keep', 'z'] ] }, shift }
        sub scan { my ($s, $cb) = @_; $cb->(0, $_->[2], $_->[3], $_->[1], $_->[0], undef, 0, 0, 0, 0, {}) for @{ $s->{c} }; }
        sub clear { my ($s, $d, $p, $k) = @_; @{ $s->{c} } = grep { !($_->[0] eq $d && $_->[1] eq $p && $_->[2] eq $k) } @{ $s->{c} }; }
        package Slim::Networking::Async::HTTP;
        our $JAR = FakeJar->new;
        sub cookie_jar { $JAR }
    }
    local $INC{'Slim/Networking/Async/HTTP.pm'} = 1;

    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { });

    my @left = map { $_->[2] } @{ $Slim::Networking::Async::HTTP::JAR->{c} };
    is_deeply(\@left, ['keep'], 'PF cookies: Spotify cookies are dropped from the LMS jar before the query, others stay');
});

# ============================================================
# getMadeForYou: two homeSection queries, filtered, merged, de-duplicated
# ============================================================
t_block('MFY source', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    seed_hash('home', $HASH_OLD);    # 79-59: op home is asked too; this fixture's home carries no rows
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());

    my ($res, $err, $called) = run_mfy();
    my @all = pf_requests();
    is(scalar(grep { pf_body($_)->{operationName} eq 'home' } @all), 1, 'MFY: one home query is issued (79-59)');
    my @pf = grep { pf_body($_)->{operationName} eq 'homeSection' } @all;
    is(scalar(@pf), 2, 'MFY: exactly two homeSection queries are issued');
    is_deeply([ map { pf_body($_)->{operationName} } @pf ], ['homeSection', 'homeSection'], 'MFY: both queries are homeSection');
    is_deeply([ map { pf_body($_)->{variables}{uri} } @pf ], [$SECTION_MFY, $SECTION_TOP], 'MFY: uri SECTION_MFY first, then SECTION_TOPMIX');
    ok($res && !$err && $called == 1, 'MFY: the callback runs exactly once with a result');
    is($res->{source}, 'pathfinder', 'MFY: source is pathfinder');
    is_deeply(uris_of($res), [
        'spotify:playlist:37i9dQZEVXbkoDWHZvXaFe',
        'spotify:playlist:37i9dQZF1E3a6pKpVe40mF',
        'spotify:playlist:37i9dQZF1EQqA6klNdJvwx',
        'spotify:playlist:37i9dQZF1EIXOF8cnjfC36',
        'spotify:playlist:37i9dQZF1EQn4jwNIohw50',
    ], 'MFY: merged in section order, MFY section first');
    ok(!(grep { $_ eq $DJ_URI } @{ uris_of($res) }), 'MFY: DJ never appears (Pathfinder path)');
    ok((grep { $_ eq "Caf\x{e9}-Mix" } @{ names_of($res) }), 'MFY: a non-ASCII mix name survives as characters (UTF-8)');
    ok(!(grep { !defined $_->{id} || $_->{id} !~ /^[A-Za-z0-9]{1,40}$/ } @{ $res->{items} }), 'MFY: every item carries a validated playlist id');
});

t_block('MFY filter', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    my $mfy = clone($FX->{homeSection_mfy});
    my $top = clone($FX->{homeSection_topmix});
    my $dup = clone($FX->{homeSection_mfy}{data}{homeSections}{sections}[0]{sectionItems}{items}[2]);   # Daily Mix 1 again
    my $alb = { uri => 'spotify:album:0000000000000000000001',
                content => { data => { __typename => 'Album', uri => 'spotify:album:0000000000000000000001', name => 'An Album' } } };
    unshift @{ $top->{data}{homeSections}{sections}[0]{sectionItems}{items} }, $dup, $alb;
    http_rule(qr{pathfinder/v2/query}, sub {
        my $uri = pf_body($_[0])->{variables}{uri};
        return (200, $JSON->encode($uri eq $SECTION_MFY ? $mfy : $top));
    });
    my ($res) = run_mfy();
    my @u = @{ uris_of($res) };
    is(scalar(grep { $_ eq 'spotify:playlist:37i9dQZF1E3a6pKpVe40mF' } @u), 1, 'MFY: an item present in both sections is listed once (de-duplicated by uri)');
    ok(!(grep { /spotify:album:/ } @u), 'MFY: items whose __typename is not Playlist are dropped');
    ok(!(grep { $_ eq $DJ_URI } @u), 'MFY: DJ dropped on the Pathfinder path');
    is($u[0], 'spotify:playlist:37i9dQZEVXbkoDWHZvXaFe', 'MFY: the Pathfinder order is kept');
});

# ============================================================
# rootlist fallback (D-17: Spotify-made 37i9 mixes of the user's rootlist)
# ============================================================
t_block('MFY fallback', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    rootlist_rule();

    my ($res, $err) = run_mfy();
    ok($res && !$err, 'MFY fallback: a result is delivered when both sections fail');
    is($res->{source}, 'rootlist-fallback', 'MFY fallback: source is rootlist-fallback');
    is_deeply(uris_of($res), [
        'spotify:playlist:37i9dQZF1E3a6pKpVe40mF',
        'spotify:playlist:37i9dQZEVXcLuBdTdkGtju',
        'spotify:playlist:37i9dQZEVXbkoDWHZvXaFe',
    ], 'MFY fallback: only spotify:playlist:37i9dQZ mixes of the rootlist, in rootlist order');
    ok(!(grep { $_ eq $DJ_URI } @{ uris_of($res) }), 'MFY fallback: DJ dropped on the rootlist fallback');
    ok(!(grep { $_ eq 'My own list' } @{ names_of($res) }), 'MFY fallback: a user playlist is not a Made-for-You mix');
    is(scalar(grep { $_->{url} =~ m{/rootlist} } @Slim::Networking::SimpleAsyncHTTP::requests), 1, 'MFY fallback: one rootlist request');
});

t_block('MFY fallback on empty', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    my $empty = clone($FX->{homeSection_mfy});
    $empty->{data}{homeSections}{sections}[0]{sectionItems}{items} = [];
    http_rule(qr{pathfinder/v2/query}, sub { return (200, $JSON->encode($empty)) });
    rootlist_rule();
    my ($res) = run_mfy();
    is($res->{source}, 'rootlist-fallback', 'MFY fallback: an empty merged list also switches to the rootlist');
});

# WR-13: the status page and the menu must tell WHY the saved mixes are shown.
# A Pathfinder answer that carries no Playlist items is not a transport failure
# ("Pathfinder is not answering"); the per-section errors are kept, not dropped.
t_block('WR-13 healthy-empty vs error', sub {
    # (a) both sections answered 200, no Playlist items: rootlist mixes are still
    # shown (D-17), but the status says "empty", not "error", and no error is recorded
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    seed_hash('home', $HASH_OLD);    # 79-59: op home answers too (no rows)
    my $empty = clone($FX->{homeSection_mfy});
    $empty->{data}{homeSections}{sections}[0]{sectionItems}{items} = [];
    http_rule(qr{pathfinder/v2/query}, sub { return (200, $JSON->encode($empty)) });
    rootlist_rule();
    my ($res) = run_mfy();
    is($res->{source}, 'rootlist-fallback', 'WR-13: a healthy-empty Pathfinder answer still lists the saved mixes (D-17)');
    my $st = $SP->madeForYouStatus();
    is($st->{fallbackActive}, 1, 'WR-13 empty: the rootlist is in use');
    is($st->{fallbackReason}, 'empty', 'WR-13 empty: the reason is "empty" (Pathfinder answered), not a transport failure');
    ok(!defined $st->{lastError}, 'WR-13 empty: no error is recorded');

    # (b) both sections failed: reason "error", the section error is exposed
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    rootlist_rule();
    ($res) = run_mfy();
    $st = $SP->madeForYouStatus();
    is($st->{fallbackActive}, 1, 'WR-13 error: the rootlist is in use');
    is($st->{fallbackReason}, 'error', 'WR-13 error: the reason is "error"');
    ok(defined $st->{lastError} && $st->{lastError} =~ /\A[A-Za-z0-9_ .\-]{1,60}\z/,
        'WR-13 error: lastError carries the (short, plain) section error: ' . ($st->{lastError} // 'undef'));

    # (c) one section failed, the other answered with mixes: no fallback, error still visible
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub {
        my $uri = pf_body($_[0])->{variables}{uri};
        return $uri eq $SECTION_MFY ? (200, $JSON->encode($FX->{homeSection_mfy})) : (500, '');
    });
    ($res) = run_mfy();
    $st = $SP->madeForYouStatus();
    is($res->{source}, 'pathfinder', 'WR-13 partial: the answering section is used');
    is($st->{fallbackActive}, 0, 'WR-13 partial: no fallback');
    ok(!defined $st->{fallbackReason}, 'WR-13 partial: no fallback reason');
});

t_block('WR-13 menu text', sub {
    my $client = MockClient->new('player-wr13');
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');
    my $noPlaylists = clone($FX->{homeSection_mfy});
    $noPlaylists->{data}{homeSections}{sections}[0]{sectionItems}{items} = [];
    my $unrelated = rootlist_bytes(['spotify:playlist:0000000000000000000001', 'My own list']);

    # Pathfinder answered, the rootlist has no Spotify-made mix either: "No results"
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    seed_hash('home', $HASH_OLD);    # 79-59: op home answers too (no rows)
    http_rule(qr{pathfinder/v2/query}, sub { return (200, $JSON->encode($noPlaylists)) });
    http_rule(qr{/playlist/v2/user/.+/rootlist}, $unrelated);
    my $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    my @i = @{ $out->{items} || [] };
    ok(scalar(@i) == 1 && $i[0]{type} eq 'textarea' && $i[0]{name} eq 'PLUGIN_SPOTON_NO_RESULTS',
        'WR-13: Pathfinder answered and nothing is saved: "No results", not "unreachable"');

    # Pathfinder failed AND the rootlist has nothing: still "unreachable"
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    http_rule(qr{/playlist/v2/user/.+/rootlist}, $unrelated);
    undef $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    @i = @{ $out->{items} || [] };
    ok(scalar(@i) == 1 && $i[0]{name} eq 'PLUGIN_SPOTON_MFY_HASH_BROKEN',
        'WR-13: Pathfinder failed and nothing is saved: still "unreachable"');
});

t_block('WR-13 status page text', sub {
    # The page logic is client-side JS; pin the reason branch and the error row
    # on the template (the data contract above is the behavioural proof).
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/status.html") or die "status.html: $!";
    my $html = do { local $/; <$fh> };
    close($fh);
    ok($html =~ /m\.fallbackReason === 'empty'\s*\?\s*'Showing saved mixes only \(Pathfinder answered without any Made for You playlists/,
        'WR-13: status.html does not claim "not answering" for fallbackReason empty');
    ok($html =~ /createMetricRow\('Last Pathfinder error', val\(m\.lastError\)\)/,
        'WR-13: status.html shows lastError');
});

t_block('MFY no credentials', sub {
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    my ($res, $err) = run_mfy();
    ok(!defined $res && ($err->{error} // '') eq 'no_credentials', 'MFY: no login5 credentials answer (undef, {error => no_credentials})');
    is(scalar(grep { $_->{url} !~ /apresolve/ } @Slim::Networking::SimpleAsyncHTTP::requests), 0, 'MFY: and no request is sent');
});

# ============================================================
# The menu: Plugin::_madeForYouFeed / _homeFeed
# ============================================================
t_block('MFY feed', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');

    my $client = MockClient->new('player-mfy');
    $Plugins::SpotOn::Unified::DaemonManager::forbid = 1;
    my $out;
    my $lived = eval { Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {}); 1 };
    $Plugins::SpotOn::Unified::DaemonManager::forbid = 0;

    ok($lived && $out, 'D-20: the Made-for-You feed completes while backendFor dies if asked');
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::backendFor_calls), 0, 'D-20: no backendFor call in the Made-for-You feed path');
    is(scalar(grep { $_->{url} =~ m{browse/categories} } @Slim::Networking::SimpleAsyncHTTP::requests), 0, 'D-08: the feed sends no browse/categories request');

    my @items = @{ $out->{items} || [] };
    is(scalar(@items), 5, 'MFY feed: five mixes listed');
    is($items[0]{type}, 'playlist', 'MFY feed: items are playlist items');
    is($items[0]{url}, \&Plugins::SpotOn::Plugin::_playlistFeed, 'MFY feed: items drill into _playlistFeed');
    is($items[0]{passthrough}[0]{playlistId}, '37i9dQZEVXbkoDWHZvXaFe', 'MFY feed: passthrough carries the playlist id');
    ok(!exists $items[0]{passthrough}[0]{webPlayer}, 'MFY feed: the webPlayer flag is gone');
    is($items[0]{name}, 'Release Radar', 'MFY feed: the Pathfinder order is kept (no priority sort on this path)');

    # opening a mix: spclient playlist/v2, never api-partner
    my $pfBefore = scalar(pf_requests());
    http_rule(qr{/playlist/v2/playlist/37i9dQZEVXbkoDWHZvXaFe}, '{"contents":{"items":[]},"length":0}');
    my $drill;
    $items[0]{url}->($client, sub { $drill = shift }, {}, $items[0]{passthrough}[0]);
    ok($drill, 'MFY feed: opening a mix answers');
    is(scalar(grep { $_->{url} =~ m{/playlist/v2/playlist/37i9dQZEVXbkoDWHZvXaFe} } @Slim::Networking::SimpleAsyncHTTP::requests), 1,
        'MFY feed: a mix is read through spclient playlist/v2');
    is(scalar(pf_requests()), $pfBefore, 'MFY feed: no request goes to api-partner for playlist contents');
});

t_block('MFY home entry', sub {
    reset_all();
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');
    my $client = MockClient->new('player-home');

    my $r;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $r = shift }, {});
    my ($mfy) = grep { $_->{name} eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @{ $r->{items} };
    ok($mfy && $mfy->{url} == \&Plugins::SpotOn::Plugin::_madeForYouFeed, 'Home: Made for You is listed when login5 credentials exist');
    ok(!$INC{'Plugins/SpotOn/API/WebPlayer.pm'}, 'Home: listing it does not load the WebPlayer module');

    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    undef $r;
    Plugins::SpotOn::Plugin::_homeFeed($client, sub { $r = shift }, {});
    ok(!(grep { $_->{name} eq 'PLUGIN_SPOTON_MADE_FOR_YOU' } @{ $r->{items} }), 'Home: Made for You is hidden without login5 credentials');
});

t_block('spDcRemoved one-shot', sub {
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    $prefs->set('spDcRemoved', 0);
    $prefs->set('pathfinderHash', 'c' x 64);
    $prefs->set('accounts', {
        aaaa1111 => { displayName => 'A', sp_dc => 'cookie-a', playbackCredSource => 'zeroconf' },
        bbbb2222 => { displayName => 'B', sp_dc => 'cookie-b' },
        cccc3333 => { displayName => 'C' },
    });

    Plugins::SpotOn::Plugin::_removeSpDcOnce();
    my $acc = $prefs->get('accounts');
    is(join(',', map { exists $acc->{$_}{sp_dc} ? "$_:sp_dc" : "$_:-" } sort keys %$acc), 'aaaa1111:-,bbbb2222:-,cccc3333:-',
        'spDcRemoved: one-shot, idempotent -- every stored sp_dc is deleted');
    is($acc->{aaaa1111}{displayName} . '|' . $acc->{aaaa1111}{playbackCredSource}, 'A|zeroconf',
        'spDcRemoved: the rest of the account record is untouched');
    ok(!defined $prefs->get('pathfinderHash'), 'spDcRemoved: the stored manual hash pref value is deleted (D-19)');
    is($prefs->get('spDcRemoved'), 1, 'spDcRemoved: the marker is set');

    # a second run changes nothing: a value that appears afterwards survives
    $prefs->get('accounts')->{cccc3333}{sp_dc} = 'late';
    $prefs->set('pathfinderHash', 'd' x 64);
    Plugins::SpotOn::Plugin::_removeSpDcOnce();
    is($prefs->get('accounts')->{cccc3333}{sp_dc}, 'late', 'spDcRemoved: a second run is a no-op (accounts)');
    is($prefs->get('pathfinderHash'), 'd' x 64, 'spDcRemoved: a second run is a no-op (hash pref)');

    # source: default + wiring after authChainMigrated, before DaemonManager->init()
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    ok($src =~ /spDcRemoved\s*=>\s*0/, 'spDcRemoved: Plugin.pm gives the pref a default of 0');
    my ($body) = $src =~ /(sub _startUnifiedDaemons \{.*?\n\})/s;
    $body //= '';
    my $mig  = index($body, "get('authChainMigrated')");
    my $call = index($body, '_removeSpDcOnce()');
    my $init = rindex($body, 'DaemonManager->init()');
    ok($mig > 0 && $call > $mig && $init > $call, 'spDcRemoved: _startUnifiedDaemons runs the one-shot after the authChainMigrated block and before DaemonManager->init()');
});

t_block('MFY sources', sub {
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($body) = $src =~ /(sub _madeForYouFeed\b.*?)(?=\nsub \w)/s;
    ok(defined $body && $body !~ /backendFor/, 'D-20: _madeForYouFeed names no backendFor');
    ok(defined $body && $body !~ /getPersonalMixes|browse\/categories/, 'D-08: _madeForYouFeed uses neither getPersonalMixes nor browse/categories');
    ok($src !~ /sub _madeForYouExpiredFeed\b/, 'Plugin.pm: _madeForYouExpiredFeed is gone');
    my ($init) = $src =~ /(sub initPlugin\b.*?)(?=\nsub \w)/s;
    ok(defined $init && $init !~ /WebPlayer/,
        '85-12: initPlugin neither loads nor resets the WebPlayer module (D-17 cookie-free)');
    ok($src !~ /API::WebPlayer\b/, '85-12: Plugin.pm names no API::WebPlayer anywhere');

    opendir(my $dh, "$project_dir/Plugins/SpotOn") or die $!;
    my @leak;
    my @dirs = ("$project_dir/Plugins/SpotOn");
    while (my $d = shift @dirs) {
        opendir(my $dh2, $d) or next;
        for my $f (grep { !/^\./ } readdir $dh2) {
            my $p = "$d/$f";
            if (-d $p) { push @dirs, $p; next; }
            next unless $f =~ /\.pm$/;
            open(my $in, '<', $p) or next;
            local $/; my $t = <$in>; close $in;
            push @leak, $p if $t =~ /api-partner\.spotify\.com/ && $p !~ m{/API/Pathfinder\.pm$};
        }
    }
    is_deeply(\@leak, [], 'api-partner.spotify.com is named only in API/Pathfinder.pm');
});

# ============================================================
# D-19: a web-player release no longer silently empties Made for You -- the
# hash heals itself once, falls back visibly, or says it is unreachable.
# ============================================================
sub page_gets {
    return scalar(grep { $_->{url} eq 'https://open.spotify.com/' } @Slim::Networking::SimpleAsyncHTTP::requests);
}

# 412 unless the request carries $ok_hash, otherwise the fixture answers
sub pf_responder_by_hash {
    my ($ok_hash) = @_;
    my $ok = pf_fixture_responder();
    return sub {
        my ($e) = @_;
        my $h = pf_body($e)->{extensions}{persistedQuery}{sha256Hash};
        return (412, '') unless $h eq $ok_hash;
        return $ok->($e);
    };
}

t_block('D-19 412', sub {
    reset_all();
    scrape_rules(hash => $HASH_NEW);
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, pf_responder_by_hash($HASH_NEW));

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });
    my @pf = pf_requests();

    ok(page_gets() == 1 && scalar(@pf) == 2 && $res && !$err
        && pf_body($pf[0])->{extensions}{persistedQuery}{sha256Hash} eq $HASH_OLD
        && pf_body($pf[1])->{extensions}{persistedQuery}{sha256Hash} eq $HASH_NEW,
        'D-19 412: exactly one rescrape and one retry');
    is($CK->get('spoton_pf_hash_homeSection'), $HASH_NEW, 'D-19 412: the healed hash replaces the rejected one in the cache');
    my $h = $PF->healthSnapshot();
    ok(defined $h->{last412At} && $h->{hashState} eq 'ok' && defined $h->{lastScrapeAt},
        'D-19 412: healthSnapshot records last412At / lastScrapeAt and hashState ok once healed');
});

t_block('D-19 412 twice', sub {
    reset_all();
    scrape_rules(hash => $HASH_NEW);
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (412, '') });

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });

    ok(page_gets() == 1 && scalar(pf_requests()) == 2 && !$res && ($err->{error} // '') eq 'hash_broken'
        && $PF->healthSnapshot()->{hashState} eq 'broken',
        'D-19 412 twice: hash_broken, hashState broken, still one rescrape and one retry');
});

t_block('D-19 cooldown', sub {
    reset_all();
    scrape_rules(hash => $HASH_NEW);
    seed_hash('homeSection', $HASH_OLD);
    my $now = 1_800_000_000;
    no warnings 'redefine';
    local *Time::HiRes::time = sub { $now };

    # a scrape that does not heal: 412, rescrape, 412 again
    http_rule(qr{pathfinder/v2/query}, sub { return (412, '') });
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { });
    is(page_gets(), 1, 'D-19 cooldown: the first 412 costs exactly one scrape');

    my $posts = scalar(pf_requests());
    my ($res, $err);
    $now += 5;
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });
    ok(page_gets() == 1 && scalar(pf_requests()) == $posts && ($err->{error} // '') eq 'hash_broken',
        'D-19 cooldown: no rescrape inside the window');

    $now += 601;
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { });
    is(page_gets(), 1, 'D-19 cooldown: a scrape that did not heal waits PF_BROKEN_RETRY_S, not PF_RESCRAPE_COOLDOWN_S');

    $now += 3600;
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { });
    is(page_gets(), 2, 'D-19 cooldown: after PF_BROKEN_RETRY_S one more scrape is allowed');
});

t_block('D-19 cooldown healed', sub {
    reset_all();
    scrape_rules(hash => $HASH_NEW);
    seed_hash('homeSection', $HASH_OLD);
    my $now = 1_800_000_000;
    no warnings 'redefine';
    local *Time::HiRes::time = sub { $now };

    http_rule(qr{pathfinder/v2/query}, pf_responder_by_hash($HASH_NEW));
    my ($res0, $err0);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res0, $err0) = @_ });
    ok($res0 && !$err0 && page_gets() == 1, 'D-19 cooldown: the first rotation heals with one scrape');

    # rotated again right away: the hash the cache holds is rejected
    Slim::Networking::SimpleAsyncHTTP::reset();
    scrape_rules(hash => $HASH_NEW);
    http_rule(qr{pathfinder/v2/query}, sub { return (412, '') });
    $now += 100;
    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });
    ok(page_gets() == 0 && ($err->{error} // '') eq 'hash_broken',
        'D-19 cooldown: a healed scrape waits PF_RESCRAPE_COOLDOWN_S (no rescrape 100 s later)');

    seed_hash('homeSection', $HASH_NEW);
    $now += 601;
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { });
    is(page_gets(), 1, 'D-19 cooldown: after PF_RESCRAPE_COOLDOWN_S a 412 may rescrape again');
});

t_block('D-19 op missing', sub {
    reset_all();
    scrape_rules(hash => $HASH_NEW);      # the bundle declares home / homeSection only
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());

    my ($res, $err);
    $PF->query('acct1', 'userTopContent', { includeTopTracks => \1 }, sub { ($res, $err) = @_ });

    my $h = $PF->healthSnapshot();
    ok(scalar(pf_requests()) == 0 && ($err->{error} // '') eq 'op_missing' && $h->{hashState} eq 'op_missing'
        && (grep { $_ eq 'userTopContent' } @{ $h->{opsMissing} }),
        'D-19 op missing: no request, state op_missing');

    # asking again inside the window neither scrapes nor sends
    my ($res2, $err2);
    $PF->query('acct1', 'userTopContent', { includeTopTracks => \1 }, sub { ($res2, $err2) = @_ });
    ok(page_gets() == 1 && scalar(pf_requests()) == 0 && ($err2->{error} // '') eq 'op_missing',
        'D-19 op missing: asked again, still no scrape and no request');
});

t_block('D-19 401', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    $CK->set('spoton_login5_token_acct1', 'stale-token');
    my $n = 0;
    my $ok = pf_fixture_responder();
    http_rule(qr{pathfinder/v2/query}, sub { return $n++ == 0 ? (401, '') : $ok->($_[0]) });

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });
    ok($res && !$err && scalar(@Plugins::SpotOn::API::Login5::getToken_calls) == 2 && scalar(pf_requests()) == 2
        && !defined $CK->get('spoton_login5_token_acct1'),
        'D-19 401: exactly one re-mint');

    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (401, '') });
    my ($res2, $err2);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res2, $err2) = @_ });
    ok(!$res2 && ($err2->{error} // '') eq 'unauthorized' && scalar(@Plugins::SpotOn::API::Login5::getToken_calls) == 2
        && scalar(pf_requests()) == 2 && defined $PF->healthSnapshot()->{last401At},
        'D-19 401 twice: error unauthorized after one re-mint, last401At set');
});

t_block('D-19 403', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (403, '') });

    my ($res, $err);
    $PF->query('acct1', 'homeSection', { uri => $SECTION_MFY }, sub { ($res, $err) = @_ });
    ok(!$res && ($err->{error} // '') eq 'ua_gate' && scalar(pf_requests()) == 1
        && scalar(@Plugins::SpotOn::API::Login5::getToken_calls) == 1
        && defined $PF->healthSnapshot()->{last403At},
        'D-19 403: ua_gate, no retry');
});

# --- the menu: visible lines, never a silent empty list ---
t_block('D-19 fallback', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    rootlist_rule();
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');

    my $client = MockClient->new('player-fb');
    my $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    my @i = @{ $out->{items} || [] };

    ok(@i && $i[0]{type} eq 'textarea' && $i[0]{name} eq 'PLUGIN_SPOTON_MFY_FALLBACK',
        'D-19 fallback: marker line first');
    is_deeply([ map { $_->{name} } @i[1 .. $#i] ], ['Discover Weekly', 'Release Radar', 'Daily Mix 1'],
        'D-19 fallback: the saved mixes follow, sorted by @MFY_PRIORITY');
    is($i[1]{type}, 'playlist', 'D-19 fallback: the mixes are playlist items');
});

t_block('D-19 fallback empty', sub {
    reset_all();
    seed_hash('homeSection', $HASH_OLD);
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    http_rule(qr{/playlist/v2/user/.+/rootlist}, rootlist_bytes(['spotify:playlist:0000000000000000000001', 'My own list']));
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');

    my $client = MockClient->new('player-fb2');
    my $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    my @i = @{ $out->{items} || [] };
    ok(scalar(@i) == 1 && $i[0]{type} eq 'textarea' && $i[0]{name} eq 'PLUGIN_SPOTON_MFY_HASH_BROKEN',
        'D-19 fallback empty: unreachable line');

    # no credentials at all: still one visible line, never an empty list
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    undef $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    ok(scalar(@{ $out->{items} || [] }) == 1 && $out->{items}[0]{name} eq 'PLUGIN_SPOTON_MFY_HASH_BROKEN',
        'D-19 fallback empty: an error from getMadeForYou also ends in the unreachable line');
});

# ============================================================
# Chunk-map scrape (85-08 Task 3): userTopContent and the search ops live in
# route chunks named by the main bundle's webpack chunk map
# ============================================================
t_block('PF chunks', sub {
    reset_all();
    my $map  = $PF->_parseChunkMap($FX->{chunkmap_excerpt});
    my @urls = $PF->_chunkUrls($map);
    my ($profile) = grep { /xpui-routes-profile/ } @urls;
    my ($search)  = grep { /xpui-routes-search/ } @urls;
    my %h = (userTopContent => 'c' x 64, searchDesktop => 'd' x 64, searchTracks => 'e' x 64,
             searchAlbums => '1' x 64, searchArtists => '2' x 64, searchPlaylists => '3' x 64, searchPodcasts => '4' x 64);

    http_rule(qr{^https://open\.spotify\.com/$}, '<script src="' . $BUNDLE_URL . '"></script>');
    http_rule(qr{^\Q$BUNDLE_URL\E$}, 'x=[new i.l("homeSection","query","' . $HASH_NEW . '")];' . "\n" . $FX->{chunkmap_excerpt});
    http_rule(qr{^\Q$profile\E$}, 'a=[new i.l("userTopContent","query","' . $h{userTopContent} . '")];');
    http_rule(qr{^\Q$search\E$}, 'b=[' . join(',', map { 'new i.l("' . $_ . '","query","' . $h{$_} . '")' } grep { /^search/ } sort keys %h) . '];');

    my $ok;
    $PF->refreshHashes(sub { ($ok) = @_ });
    my @r = map { $_->{url} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is_deeply([ grep { $_ eq $profile || $_ eq $search } @r ], [ $profile, $search ],
        'PF chunks: the route chunks xpui-routes-profile and xpui-routes-search are fetched via the chunk map, profile first');
    is_deeply({ map { $_ => $CK->get("spoton_pf_hash_$_") } keys %h }, \%h,
        'PF chunks: userTopContent, searchDesktop, searchTracks, searchAlbums, searchArtists, searchPlaylists and searchPodcasts hashes are cached like the home hash');
    is($CK->get('spoton_pf_hash_homeSection'), $HASH_NEW, 'PF chunks: the page bundle hash is cached too');
    ok($ok, 'PF chunks: the scrape reports success');

    # a prefix outside the CDN: no chunk is fetched
    reset_all();
    (my $evil = $FX->{chunkmap_excerpt}) =~ s{https://open\.spotifycdn\.com/}{https://evil.example/}g;
    http_rule(qr{^https://open\.spotify\.com/$}, '<script src="' . $BUNDLE_URL . '"></script>');
    http_rule(qr{^\Q$BUNDLE_URL\E$}, 'x=[new i.l("homeSection","query","' . $HASH_NEW . '")];' . "\n" . $evil);
    $PF->refreshHashes(sub { });
    is(scalar(grep { $_->{url} =~ m{evil\.example|xpui-routes} } @Slim::Networking::SimpleAsyncHTTP::requests), 0,
        'PF chunks: a chunk-map prefix outside https://open.spotifycdn.com/ fetches no chunk (T-85-31)');
});

# ============================================================
# Top Tracks and search through the whole stack on a cold hash cache
# ============================================================
t_block('PF top and search end to end', sub {
    reset_all();
    my $map  = $PF->_parseChunkMap($FX->{chunkmap_excerpt});
    my @urls = $PF->_chunkUrls($map);
    my ($profile) = grep { /xpui-routes-profile/ } @urls;
    my ($search)  = grep { /xpui-routes-search/ } @urls;
    http_rule(qr{^https://open\.spotify\.com/$}, '<script src="' . $BUNDLE_URL . '"></script>');
    http_rule(qr{^\Q$BUNDLE_URL\E$}, $FX->{chunkmap_excerpt});
    http_rule(qr{^\Q$profile\E$}, 'a=[new i.l("userTopContent","query","' . ('c' x 64) . '")];');
    http_rule(qr{^\Q$search\E$}, 'b=[new i.l("searchDesktop","query","' . ('d' x 64) . '")];');
    http_rule(qr{pathfinder/v2/query}, sub {
        my $op = pf_body($_[0])->{operationName};
        return (200, $JSON->encode($FX->{userTopContent})) if $op eq 'userTopContent';
        return (200, $JSON->encode($FX->{searchDesktop}))  if $op eq 'searchDesktop';
        return (200, '{"data":{}}');
    });

    my ($top, $terr);
    $SP->getTopTracks('acct1', { time_range => 'medium_term', limit => 50 }, sub { ($top, $terr) = @_ });
    ok($top && scalar(@{ $top->{items} }) == 3 && !$terr, 'PF top: getTopTracks scrapes the profile chunk once and answers from userTopContent');

    my ($res, $err);
    $SP->search('acct1', { q => 'jazz', type => 'track,album,artist,playlist', limit => 10 }, sub { ($res, $err) = @_ });
    ok($res && scalar(@{ $res->{tracks}{items} }) == 3 && !$res->{limited}, 'PF search: a multi-type search answers from one searchDesktop request');
    is(scalar(grep { $_->{url} eq 'https://open.spotify.com/' } @Slim::Networking::SimpleAsyncHTTP::requests), 1,
        'PF top and search: the cold cache cost exactly one scrape for both');
});

# ============================================================
# 79-59 (GH #180): the daylist and the account's other personal lists from
# the whole home (op home), by the user's rule (MIX59_CHOSEN=rule:personal-non-radio):
# id prefix 37i9dQZF1E or 37i9dQZEVX, madeFor.username present, format not
# inspiredby-mix. Layout: daylist, Daily Mixes, Discover Weekly, Release Radar
# on top, the rest in one folder per Spotify row (Spotify's title, Spotify's
# order), untitled rows' lists below the top entries. Fixture: the trimmed real
# replies t/fixtures/pathfinder/79-59-made-for-you.json.
# ============================================================
my $FX59 = do {
    my $f = "$project_dir/t/fixtures/pathfinder/79-59-made-for-you.json";
    open(my $fh, '<:raw', $f) or BAIL_OUT("cannot read fixture $f: $!");
    local $/; JSON::PP->new->utf8->decode(<$fh>);
};
my $DAYLIST59 = 'spotify:playlist:37i9dQZF1EP6YuccBxUcC1';
my $FUNWO59   = 'spotify:playlist:37i9dQZF1EIdBKZUQJyqDm';
my $SOUL59    = 'spotify:playlist:37i9dQZF1EQntZpEGgfBif';
my @TOP59 = (
    $DAYLIST59,
    'spotify:playlist:37i9dQZF1E3a6pKpVe40mF', 'spotify:playlist:37i9dQZF1E3agjx7jh6NAH',
    'spotify:playlist:37i9dQZF1E36NB7mrxWwbJ', 'spotify:playlist:37i9dQZF1E36AMXEwzycvH',
    'spotify:playlist:37i9dQZF1E35inxxG3M2aK', 'spotify:playlist:37i9dQZF1E37VP7CF6t3aw',
    'spotify:playlist:37i9dQZEVXcLuBdTdkGtju',
    'spotify:playlist:37i9dQZEVXbkoDWHZvXaFe',
);

# every Playlist item of a home reply, as [uri, format, madeFor, sectionTitle]
sub fx59_playlists {
    my ($home) = @_;
    my @out;
    for my $s (@{ $home->{data}{home}{sectionContainer}{sections}{items} }) {
        my $t = (($s->{data} || {})->{title} || {})->{transformedLabel};
        for my $it (@{ $s->{sectionItems}{items} }) {
            my $d = (($it->{content} || {})->{data}) || {};
            next unless ($d->{__typename} // '') eq 'Playlist';
            my $mf = grep { $_->{key} eq 'madeFor.username' } @{ $d->{attributes} || [] };
            push @out, [ $d->{uri}, $d->{format} // '', $mf ? 1 : 0, $t ];
        }
    }
    return @out;
}

sub pf59_responder {
    my (%o) = @_;
    my $home = $o{home} // $FX59->{home};
    my $top  = $o{topmix} // $FX59->{homeSection_topmix};
    my $mfy  = $o{mfy} // $FX59->{homeSection_mfy};
    return sub {
        my $req = pf_body($_[0]);
        my $op  = $req->{operationName} // '';
        if ($op eq 'home') {
            return $o{home_fail} ? (500, '') : (200, $JSON->encode($home));
        }
        if ($op eq 'homeSection') {
            return (500, '') if $o{sections_fail};
            my $uri = $req->{variables}{uri} // '';
            return (200, $JSON->encode($uri eq $SECTION_MFY ? $mfy : $uri eq $SECTION_TOP ? $top : { data => {} }));
        }
        return (200, '{"data":{}}');
    };
}
sub seed59 { seed_hash('homeSection', $HASH_OLD); seed_hash('home', $HASH_OLD); }
sub layout_uris {
    my ($l) = @_;
    return ([ map { $_->{uri} } @{ $l->{top} || [] } ], [ map { $_->{uri} } @{ $l->{loose} || [] } ],
            [ map { [ $_->{title}, [ map { $_->{uri} } @{ $_->{items} } ] ] } @{ $l->{folders} || [] } ]);
}

t_block('79-59 MFY home op', sub {
    reset_all();
    seed59();
    http_rule(qr{pathfinder/v2/query}, pf59_responder());

    my ($res, $err, $called) = run_mfy();
    my @ops = map { pf_body($_)->{operationName} } pf_requests();
    is_deeply([ sort @ops ], [ 'home', 'homeSection', 'homeSection' ], '79-59: one home query and the two homeSection queries');
    my ($homeReq) = grep { pf_body($_)->{operationName} eq 'home' } pf_requests();
    is($homeReq && pf_body($homeReq)->{variables}{sectionItemsLimit}, 50, '79-59: the home query uses the measured sectionItemsLimit 50');
    ok($res && !$err && $called == 1 && $res->{source} eq 'pathfinder', '79-59: one pathfinder result');

    my @u = @{ uris_of($res) };
    is(scalar(grep { $_ eq $DAYLIST59 } @u), 1, '79-59: the daylist is listed exactly once (GH #180)');
    my %c; $c{$_}++ for @u;
    is(scalar(grep { $c{$_} > 1 } keys %c), 0, '79-59: no uri is listed twice');
    ok(!(grep { $_ eq $DJ_URI } @u), '79-59: DJ stays out');

    my @pl = fx59_playlists($FX59->{home});
    my @radios = map { $_->[0] } grep { $_->[1] eq 'inspiredby-mix' } @pl;
    my @edMf   = map { $_->[0] } grep { $_->[0] =~ /37i9dQZF1D/ && $_->[2] } @pl;
    my @user   = map { $_->[0] } grep { $_->[0] !~ /37i9dQ/ } @pl;
    ok(@radios >= 3 && @edMf >= 2 && @user >= 1, '79-59: the fixture carries radios, editorial lists with madeFor and user playlists');
    my %in = map { $_ => 1 } @u;
    is(scalar(grep { $in{$_} } @radios), 0, '79-59: no artist radio (format inspiredby-mix) is listed');
    is(scalar(grep { $in{$_} } @edMf), 0, '79-59: no editorial list is listed, even when it carries madeFor');
    is(scalar(grep { $in{$_} } @user), 0, '79-59: no user or neutralised playlist is listed');
    my @kept = map { $_->[0] } grep { $_->[0] =~ /\Aspotify:playlist:37i9dQZ(?:F1E|EVX)/ && $_->[2] && $_->[1] ne 'inspiredby-mix' } @pl;
    is(scalar(grep { !$in{$_} } @kept), 0, '79-59: every personal non-radio list of the home is listed');

    my $l = $res->{layout};
    ok(ref $l eq 'HASH', '79-59: the result carries a layout');
    my ($top, $loose, $folders) = layout_uris($l);
    is_deeply($top, \@TOP59, '79-59: on top daylist, Daily Mix 1-6, Discover Weekly, Release Radar (in that order)');
    is_deeply($loose, [ $FUNWO59 ], '79-59: a list from the untitled row sits below the top entries');
    is_deeply([ map { $_->[0] } @$folders ], [ 'Your top mixes', 'Made for you' ], '79-59: one folder per contributing Spotify row, Spotify title, Spotify order');
    my ($tm) = grep { $_->[0] eq 'Your top mixes' } @$folders;
    my @homeTop = map { $_->[0] } grep { ($_->[3] // '') eq 'Your top mixes' } @pl;
    is_deeply([ @{ $tm->[1] }[0 .. $#homeTop] ], \@homeTop, '79-59: the top-mixes folder starts with the home row in Spotify order');
    my @legacyTop = map { $_->{content}{data}{uri} } @{ $FX59->{homeSection_topmix}{data}{homeSections}{sections}[0]{sectionItems}{items} };
    my %tmIn = map { $_ => 1 } @{ $tm->[1] };
    is(scalar(grep { !$tmIn{$_} } @legacyTop), 0, '79-59: every mix SECTION_TOPMIX answers still appears (nothing of today drops out)');
    my ($mf) = grep { $_->[0] eq 'Made for you' } @$folders;
    is_deeply($mf->[1], [ $SOUL59 ], '79-59: two rows titled "Made for you" share one folder; a list shown elsewhere is not repeated');
    is_deeply([ @u ], [ @$top, @$loose, map { @{ $_->[1] } } @$folders ], '79-59: items is the flat menu order (top, loose, folders)');
    is($SP->madeForYouStatus()->{mixCount}, scalar(@u), '79-59: the status page counts every listed list');
});

t_block('79-59 MFY generic rule', sub {
    reset_all();
    seed59();
    my $home = clone($FX59->{home});
    my $row = $home->{data}{home}{sectionContainer}{sections}{items}[4];   # Your top mixes
    my $mk = sub {
        my ($id, $fmt, $mf, $name) = @_;
        my $uri = "spotify:playlist:$id";
        return { uri => $uri, content => { data => { __typename => 'Playlist', uri => $uri, name => $name,
            ($fmt ? (format => $fmt) : ()),
            attributes => [ $mf ? ({ key => 'madeFor.username', value => 'listener' }) : () ] } } };
    };
    push @{ $row->{sectionItems}{items} },
        $mk->('37i9dQZF1E99NEWKINDxx01', 'future-kind', 1, 'New Kind'),
        $mk->('37i9dQZF1E99NOMADExxx02', 'topic-mix',   0, 'No madeFor'),
        $mk->('37i9dQZF1DX99EDITORxx03', 'editorial',   1, 'Editorial with madeFor'),
        $mk->('37i9dQZEVX99RADIOxxxx04', 'inspiredby-mix', 1, 'A Radio');
    http_rule(qr{pathfinder/v2/query}, pf59_responder(home => $home));
    my ($res) = run_mfy();
    my %in = map { $_ => 1 } @{ uris_of($res) };
    ok($in{'spotify:playlist:37i9dQZF1E99NEWKINDxx01'}, '79-59 rule: a personal list of a format SpotOn does not know is listed (no allow-list)');
    ok(!$in{'spotify:playlist:37i9dQZF1E99NOMADExxx02'}, '79-59 rule: a 37i9dQZF1E list without madeFor.username is not listed');
    ok(!$in{'spotify:playlist:37i9dQZF1DX99EDITORxx03'}, '79-59 rule: madeFor alone is not enough (editorial id prefix)');
    ok(!$in{'spotify:playlist:37i9dQZEVX99RADIOxxxx04'}, '79-59 rule: format inspiredby-mix stays out under any prefix');
});

t_block('79-59 MFY source failures', sub {
    # home fails: the two sections list their items as before, flat, and lastError names the home query
    reset_all();
    seed59();
    http_rule(qr{pathfinder/v2/query}, pf59_responder(home_fail => 1));
    my ($res) = run_mfy();
    is($res->{source}, 'pathfinder', '79-59: home failed, the sections still answer');
    ok(!$res->{layout}, '79-59: without the home reply the list stays flat (today\'s form)');
    my @legacy = grep { $_ ne $DJ_URI } map { $_->{content}{data}{uri} }
        map { @{ $_->{data}{homeSections}{sections}[0]{sectionItems}{items} } } ($FX59->{homeSection_mfy}, $FX59->{homeSection_topmix});
    my %s; @legacy = grep { !$s{$_}++ } @legacy;
    is_deeply(uris_of($res), \@legacy, '79-59: the flat list is SECTION_MFY then SECTION_TOPMIX, de-duplicated');
    like($SP->madeForYouStatus()->{lastError} // '', qr/\Ahome\b/, '79-59: lastError names the failed source (home)');

    # the sections fail, home answers: the full layout from home alone
    reset_all();
    seed59();
    http_rule(qr{pathfinder/v2/query}, pf59_responder(sections_fail => 1));
    ($res) = run_mfy();
    my ($top) = layout_uris($res->{layout} || {});
    is_deeply($top, \@TOP59, '79-59: the sections failed, home alone fills the layout');
    ok(defined $SP->madeForYouStatus()->{lastError}, '79-59: and the section error stays visible');

    # everything fails: the rootlist fallback, unchanged rule
    reset_all();
    seed59();
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    rootlist_rule();
    ($res) = run_mfy();
    is($res->{source}, 'rootlist-fallback', '79-59: the rootlist fallback only when every source yields nothing');
});

t_block('79-59 MFY feed folders', sub {
    reset_all();
    seed59();
    http_rule(qr{pathfinder/v2/query}, pf59_responder());
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');
    my $client = MockClient->new('player-mfy59');
    my $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    my @items = @{ $out->{items} || [] };
    is_deeply([ map { $_->{passthrough}[0]{playlistId} } @items[0 .. 9] ],
        [ map { (split /:/)[2] } @TOP59, $FUNWO59 ], '79-59 feed: the top entries and the untitled-row list come first, as playlists');
    my @folders = grep { !$_->{passthrough} } @items;
    is_deeply([ map { $_->{name} } @folders ], [ 'Your top mixes', 'Made for you' ], '79-59 feed: then one folder per row, named by Spotify');
    ok(!(grep { ref $_->{items} ne 'ARRAY' || !@{ $_->{items} } } @folders), '79-59 feed: every folder holds its lists');
    ok(!(grep { ($_->{type} // '') ne 'playlist' } map { @{ $_->{items} } } @folders), '79-59 feed: folder entries are playlist items');
    is(scalar(@items), 10 + scalar(@folders), '79-59 feed: nothing else on the top level');
});

# ============================================================
# 79-59 Task 3: the dedupe invariant of the assumption-delta block. An item
# that two sources list appears once, at its first place in Spotify's row
# order (within a row, home's items before a homeSection's extras); checked
# for each source pair: home+topmix, home+mfy, mfy+topmix (home absent).
# ============================================================
t_block('79-59 MFY dedupe invariant', sub {
    my $mix = sub {
        my ($id, $fmt, $name) = @_;
        my $uri = "spotify:playlist:$id";
        return { uri => $uri, content => { data => { __typename => 'Playlist', uri => $uri, name => $name,
            format => $fmt, attributes => [ { key => 'madeFor.username', value => 'listener' } ] } } };
    };
    my $hsItems = sub { $_[0]{data}{homeSections}{sections}[0]{sectionItems}{items} };
    my $row = sub {
        my ($home, $uri) = @_;
        my ($r) = grep { $_->{uri} eq $uri } @{ $home->{data}{home}{sectionContainer}{sections}{items} };
        return $r->{sectionItems}{items};
    };
    my $count = sub { my ($res, $u) = @_; scalar grep { $_ eq $u } @{ uris_of($res) } };
    my $where = sub {
        my ($res, $u) = @_;
        my $l = $res->{layout} || {};
        for my $k (qw(top loose)) { return $k if grep { $_->{uri} eq $u } @{ $l->{$k} || [] } }
        for my $f (@{ $l->{folders} || [] }) { return "folder:$f->{title}" if grep { $_->{uri} eq $u } @{ $f->{items} } }
        return 'none';
    };

    # home + topmix: a mix in home's top-mixes row and in SECTION_TOPMIX
    reset_all(); seed59();
    my $home = clone($FX59->{home});
    my $top  = clone($FX59->{homeSection_topmix});
    my $X = $mix->('37i9dQZF1EQ99INVHTxxx01', 'topic-mix', 'Inv HT');
    push @{ $row->($home, $SECTION_TOP) }, $X;
    unshift @{ $hsItems->($top) }, clone($X);
    http_rule(qr{pathfinder/v2/query}, pf59_responder(home => $home, topmix => $top));
    my ($res) = run_mfy();
    my $u = $X->{uri};
    is($count->($res, $u), 1, 'invariant home+topmix: listed once');
    my ($f) = grep { $_->{title} eq 'Your top mixes' } @{ $res->{layout}{folders} };
    my @fu = map { $_->{uri} } @{ $f->{items} };
    my $nHome = scalar(@{ $row->($home, $SECTION_TOP) }) - 1;   # the row before $X: 10 home mixes
    is($fu[$nHome], $u, 'invariant home+topmix: at its place in home\'s row, not where SECTION_TOPMIX put it (first)');

    # home + mfy: a mix in home's top-mixes row and in SECTION_MFY: row 2 (the MFY row) comes first in Spotify's order
    reset_all(); seed59();
    $home = clone($FX59->{home});
    my $mfy = clone($FX59->{homeSection_mfy});
    my $Y = $mix->('37i9dQZF1EQ99INVHMxxx02', 'topic-mix', 'Inv HM');
    push @{ $row->($home, $SECTION_TOP) }, $Y;
    push @{ $hsItems->($mfy) }, clone($Y);
    http_rule(qr{pathfinder/v2/query}, pf59_responder(home => $home, mfy => $mfy));
    ($res) = run_mfy();
    is($count->($res, $Y->{uri}), 1, 'invariant home+mfy: listed once');
    is($where->($res, $Y->{uri}), 'folder:Made For Listener', 'invariant home+mfy: at its first place in row order (the MFY row before the top-mixes row)');
    my ($tmf) = grep { $_->{title} eq 'Your top mixes' } @{ $res->{layout}{folders} };
    ok(!(grep { $_->{uri} eq $Y->{uri} } @{ $tmf->{items} }), 'invariant home+mfy: and not again in the later row');

    # mfy + topmix, home absent: the flat list keeps SECTION_MFY's place
    reset_all(); seed59();
    $mfy = clone($FX59->{homeSection_mfy});
    $top = clone($FX59->{homeSection_topmix});
    my $Z = $mix->('37i9dQZF1EQ99INVMTxxx03', 'topic-mix', 'Inv MT');
    push @{ $hsItems->($mfy) }, $Z;
    unshift @{ $hsItems->($top) }, clone($Z);
    http_rule(qr{pathfinder/v2/query}, pf59_responder(home_fail => 1, mfy => $mfy, topmix => $top));
    ($res) = run_mfy();
    my @flat = @{ uris_of($res) };
    is($count->($res, $Z->{uri}), 1, 'invariant mfy+topmix: listed once');
    my $nMfy = scalar(grep { $_->{content}{data}{uri} ne $DJ_URI } @{ $hsItems->($mfy) }) - 1;
    is($flat[$nMfy], $Z->{uri}, 'invariant mfy+topmix: at the end of the SECTION_MFY part, not at the head of SECTION_TOPMIX');
});

# 79-59 Task 3: the Made For You list is kept for the browse tier only
# (300 s), so the menu a user descends into is the one LMS showed (LMS fetches
# coderef menus again on every descent, and the Spotify home answers
# differently per request); an answer with a failed source is not kept; the
# lists' tracks follow the 300 s playlist envelope cache.
t_block('79-59 MFY list cache', sub {
    reset_all(); seed59();
    my $n = 0;
    my $base = pf59_responder();
    http_rule(qr{pathfinder/v2/query}, sub {
        my $req = pf_body($_[0]);
        return $base->($_[0]) unless ($req->{operationName} // '') eq 'home';
        # every home request answers a different one-item row, as live
        my $home = clone($FX59->{home});
        my $r = $home->{data}{home}{sectionContainer}{sections}{items}[5]{sectionItems}{items}[0]{content}{data};
        $n++;
        $r->{uri} = 'spotify:playlist:37i9dQZF1EQ99ROTATExx' . sprintf('%02d', $n);
        return (200, $JSON->encode($home));
    });
    my ($r1) = run_mfy();
    my $p1 = scalar(pf_requests());
    my ($r2) = run_mfy();
    is(scalar(pf_requests()), $p1, '79-59 cache: a second open within the TTL sends no Pathfinder request');
    is_deeply(uris_of($r2), uris_of($r1), '79-59 cache: and shows the same lists in the same places (stable menu indices)');
    ok($CK->ttl('spoton_mfy_list_acct1') > 0 && $CK->ttl('spoton_mfy_list_acct1') <= 300, '79-59 cache: kept at most 300 s (browse tier)');
    is(Plugins::SpotOn::API::SpClient::MFY_LIST_TTL(), 300, '79-59 cache: MFY_LIST_TTL is 300');
    $CK->remove('spoton_mfy_list_acct1');
    my ($r3) = run_mfy();
    ok(scalar(pf_requests()) > $p1 && !(grep { $_ eq 'spotify:playlist:37i9dQZF1EQ99ROTATExx01' } @{ uris_of($r3) }),
        '79-59 cache: after it expires the next open reads the home again');
    is(Plugins::SpotOn::API::SpClient::PLAYLIST_ENVELOPE_TTL(), 300, '79-59 cache: a list\'s tracks follow the 300 s playlist envelope cache');

    # a failed source: shown, not kept
    reset_all(); seed59();
    http_rule(qr{pathfinder/v2/query}, pf59_responder(home_fail => 1));
    my ($f1) = run_mfy();
    ok($f1 && @{ $f1->{items} } && !defined $CK->get('spoton_mfy_list_acct1'), '79-59 cache: an answer with a failed source is not kept');
});

# ============================================================
# 261110-is9: a Made for You entry whose Pathfinder name is empty gets its name
# from spclient playlist/v2 (through _playlistEnvelope), else from Pathfinder
# fetchPlaylist, else a label -- never its playlist id. Lookups are bounded
# (13 per build, 2 in flight, 5 s budget, stop on 429) and cached (30 days, 1
# hour negative). Helpers first; the blocks follow below.
# ============================================================
sub is9_setup { reset_all(); seed59(); seed_hash('fetchPlaylist', $HASH_OLD); }

sub is9_mix {
    my ($id, %o) = @_;
    my $uri = "spotify:playlist:$id";
    my %d = (__typename => 'Playlist', uri => $uri, format => $o{format} // 'topic-mix',
             attributes => [ { key => 'madeFor.username', value => 'listener' } ]);
    if    (exists $o{name}) { $d{name} = $o{name} }
    elsif (!$o{noname})     { $d{name} = "Named $id" }
    return { uri => $uri, content => { data => \%d } };
}

sub is9_hs_items { return $_[0]{data}{homeSections}{sections}[0]{sectionItems}{items}; }
sub is9_topmix {
    my (@items) = @_;
    my $t = clone($FX59->{homeSection_topmix});
    push @{ is9_hs_items($t) }, @items;
    return $t;
}

sub is9_pv2 {
    my ($names, %o) = @_;
    http_rule(qr{/playlist/v2/playlist/}, sub {
        my ($e) = @_;
        my ($id) = $e->{url} =~ m{/playlist/v2/playlist/([^/?#]+)};
        return ($o{code}, '', $o{code} == 429 ? { 'Retry-After' => 30 } : {}) if $o{code};
        return (200, $JSON->encode({ attributes => { name => $names->{$id} } })) if defined $id && exists $names->{$id};
        return (404, '');
    });
}

sub is9_pf {
    my (%o) = @_;
    my %rest = %o; delete $rest{fetch};
    my $base = pf59_responder(%rest);
    http_rule(qr{pathfinder/v2/query}, sub {
        my $req = pf_body($_[0]);
        if (($req->{operationName} // '') eq 'fetchPlaylist') {
            my ($id) = (($req->{variables} || {})->{uri} // '') =~ /:([^:]+)\z/;
            my $r = (defined $id && ref($o{fetch}) eq 'HASH') ? $o{fetch}{$id} : undef;
            return (200, defined $r ? (ref $r ? $JSON->encode($r) : $r) : '{"data":{}}');
        }
        return $base->($_[0]);
    });
}

sub is9_pv2_ids {
    return map { $_->{url} =~ m{/playlist/v2/playlist/([^/?#]+)} ? $1 : () }
           grep { $_->{url} =~ m{/playlist/v2/playlist/} } @Slim::Networking::SimpleAsyncHTTP::requests;
}
sub is9_fetch_reqs { return grep { (pf_body($_)->{operationName} // '') eq 'fetchPlaylist' } pf_requests(); }
sub is9_item {
    my ($res, $id) = @_;
    my ($it) = grep { $_->{id} eq $id } @{ ($res || {})->{items} || [] };
    return $it;
}
sub is9_feed {
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('activeAccount', 'acct1');
    my $client = MockClient->new('player-is9');
    my $out;
    Plugins::SpotOn::Plugin::_madeForYouFeed($client, sub { $out = shift }, {});
    my @pl;
    for my $it (@{ ($out || {})->{items} || [] }) {
        if (ref $it->{items} eq 'ARRAY') { push @pl, @{ $it->{items} } }
        else                             { push @pl, $it }
    }
    return map { [ $_->{passthrough}[0]{playlistId}, $_->{name} ] } grep { ref $_->{passthrough} eq 'ARRAY' } @pl;
}
sub is9_feed_name {
    my ($id, @feed) = @_;
    my ($e) = grep { $_->[0] eq $id } @feed;
    return $e ? $e->[1] : undef;
}

t_block('is9 MFY name resolution', sub {
    # --- resolve: nameless items get their name from playlist/v2 ---
    my ($R1, $R2) = ('37i9dQZF1EQ99IS9RESxx01', '37i9dQZF1EQ99IS9RESxx02');
    is9_setup();
    is9_pv2({ $R1 => 'Classic Rock Mix', $R2 => 'Hip Hop Mix' });
    is9_pf(topmix => is9_topmix(is9_mix($R1, name => ''), is9_mix($R2, noname => 1)));
    my ($res, $err, $called) = run_mfy();
    ok($res && !$err && $called == 1 && ($res->{source} // '') eq 'pathfinder', 'is9 T1 resolve: one pathfinder result, callback once');
    my ($i1, $i2) = (is9_item($res, $R1), is9_item($res, $R2));
    is($i1 ? $i1->{name} : undef, 'Classic Rock Mix', 'is9 T1 resolve: an empty name is replaced by the playlist/v2 name');
    is($i2 ? $i2->{name} : undef, 'Hip Hop Mix', 'is9 T1 resolve: a missing name is replaced by the playlist/v2 name');
    is_deeply([ sort { $a cmp $b } is9_pv2_ids() ], [ sort { $a cmp $b } ($R1, $R2) ], 'is9 T1 resolve: exactly one playlist/v2 request per nameless item');
    my @pv = grep { $_->{url} =~ m{/playlist/v2/playlist/} } @Slim::Networking::SimpleAsyncHTTP::requests;
    ok(@pv && !(grep { ($_->{headers}{Accept} // '') ne 'application/json' } @pv), 'is9 T1 resolve: every playlist/v2 request asks for application/json');
    ok(!(grep { $_ ne $R1 && $_ ne $R2 } is9_pv2_ids()), 'is9 T1 resolve: no playlist/v2 request for an item that has a name');
    my ($tf) = grep { $_->{title} eq 'Your top mixes' } @{ ($res && $res->{layout} || {})->{folders} || [] };
    my @tu = $tf ? map { $_->{id} } @{ $tf->{items} } : ();
    is_deeply([ @tu >= 2 ? @tu[-2, -1] : () ], [ $R1, $R2 ], 'is9 T1 resolve: both sit at the end of the folder Your top mixes, in order');

    # --- dedup: the named copy wins, the first copy keeps its place ---
    my $X = '37i9dQZF1EQ99IS9DUPxx03';
    is9_setup();
    my $home = clone($FX59->{home});
    my ($row) = grep { $_->{uri} eq $SECTION_TOP } @{ $home->{data}{home}{sectionContainer}{sections}{items} };
    push @{ $row->{sectionItems}{items} }, is9_mix($X, name => '');
    my $nHome = scalar(@{ $row->{sectionItems}{items} }) - 1;
    my $top = is9_topmix();
    unshift @{ is9_hs_items($top) }, is9_mix($X, name => 'Named Dup');
    is9_pf(home => $home, topmix => $top);
    ($res) = run_mfy();
    is(scalar(grep { $_ eq "spotify:playlist:$X" } @{ uris_of($res) }), 1, 'is9 T1 dedup: the doubly listed mix appears once');
    my $dx = is9_item($res, $X);
    is($dx ? $dx->{name} : undef, 'Named Dup', 'is9 T1 dedup: it shows the name of the copy that has one');
    ($tf) = grep { $_->{title} eq 'Your top mixes' } @{ ($res && $res->{layout} || {})->{folders} || [] };
    is($tf && $tf->{items}[$nHome] ? $tf->{items}[$nHome]{id} : undef, $X, 'is9 T1 dedup: and keeps the first copy\'s place in home\'s row');
    is(scalar(is9_pv2_ids()), 0, 'is9 T1 dedup: no playlist/v2 request was needed');

    # --- label: nothing found, never the id ---
    my $L1 = '37i9dQZF1EQ99IS9LBLxx04';
    is9_setup();
    is9_pf(topmix => is9_topmix(is9_mix($L1, name => '')));
    ($res, $err, $called) = run_mfy();
    my $l1 = is9_item($res, $L1);
    is($l1 ? $l1->{name} : undef, '', 'is9 T1 label: a name that cannot be found stays empty in the result');
    ok($res && !(grep { $_->{name} eq $_->{id} } @{ $res->{items} || [] }), 'is9 T1 label: no result item carries its playlist id as the name');
    is($called, 1, 'is9 T1 label: the callback fires once');
    my @feed = is9_feed();
    is(is9_feed_name($L1, @feed), 'PLUGIN_SPOTON_MFY_UNNAMED', 'is9 T1 label: the feed labels the nameless entry');
    ok(@feed && !(grep { $_->[0] eq $_->[1] } @feed), 'is9 T1 label: no feed entry is named like its playlist id');
    my $soulName = is9_feed_name((split /:/, $SOUL59)[2], @feed);
    ok(defined $soulName && length $soulName && $soulName ne 'PLUGIN_SPOTON_MFY_UNNAMED', 'is9 T1 label: a named entry keeps its name');

    # --- fallback: the rootlist leg labels an empty name too ---
    my $RL = '37i9dQZF1E99IS9RLTxxx05';
    is9_setup();
    http_rule(qr{pathfinder/v2/query}, sub { return (500, '') });
    http_rule(qr{/playlist/v2/user/.+/rootlist}, rootlist_bytes(@ROOTLIST, [ "spotify:playlist:$RL", '' ]));
    ($res) = run_mfy();
    is(($res || {})->{source}, 'rootlist-fallback', 'is9 T1 fallback: every Pathfinder source failed, the rootlist answers');
    my $rl = is9_item($res, $RL);
    is($rl ? $rl->{name} : undef, '', 'is9 T1 fallback: a rootlist entry without a name stays empty in the result');
    @feed = is9_feed();
    is(is9_feed_name($RL, @feed), 'PLUGIN_SPOTON_MFY_UNNAMED', 'is9 T1 fallback: and the feed labels it');

    # --- burst: at most 13 lookups, 2 in flight ---
    my @B = map { sprintf('37i9dQZF1EQ99IS9BURxx%02d', $_) } 1 .. 15;
    is9_setup();
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @B));
    is9_pv2({ map { $B[$_ - 1] => sprintf('Burst %02d', $_) } 1 .. 15 });
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{/playlist/v2/playlist/};
    ($res, $called) = (undef, 0);   # the answer arrives later: capture it by closure, not through run_mfy's return values
    $SP->getMadeForYou('acct1', sub { ($res) = @_; $called++ });
    ok(scalar(@Slim::Networking::SimpleAsyncHTTP::held) == 2 && !$called, 'is9 T1 burst: two lookups start, the rest waits for a free slot, the callback has not fired');
    1 while Slim::Networking::SimpleAsyncHTTP::release_one();
    is($Slim::Networking::SimpleAsyncHTTP::max_inflight, 2, 'is9 T1 burst: never more than 2 lookups in flight');
    is(scalar(is9_pv2_ids()), 13, 'is9 T1 burst: 15 nameless items cost exactly 13 lookups');
    is($called, 1, 'is9 T1 burst: the callback fires once');
    my @got = map { my $it = is9_item($res, $_); $it ? $it->{name} : '<missing>' } @B;
    is_deeply(\@got, [ (map { sprintf('Burst %02d', $_) } 1 .. 13), '', '' ], 'is9 T1 burst: the first 13 carry their names, the last two stay empty');
    my ($cPar, $cMax) = ($SP->can('MFY_NAME_PARALLEL'), $SP->can('MFY_NAME_MAX_LOOKUPS'));
    is_deeply([ $cPar ? $cPar->() : undef, $cMax ? $cMax->() : undef ], [ 2, 13 ], 'is9 T1 burst: MFY_NAME_PARALLEL is 2 and MFY_NAME_MAX_LOOKUPS is 13');

    # --- coalesce: two callers during one cold run share the run ---
    is9_setup();
    is9_pf();
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
    my @cc;
    for my $i (0, 1) { $SP->getMadeForYou('acct1', sub { $cc[$i]++ }) }
    1 while Slim::Networking::SimpleAsyncHTTP::release_one();
    is_deeply([ scalar(pf_requests()), $cc[0] // 0, $cc[1] // 0 ], [ 3, 1, 1 ],
        'is9 T1 burst: two callers during one cold run cost 3 Pathfinder requests and each callback fires once');
});

# ------------------------------------------------------------
# is9 T2: name cache, Pathfinder fetchPlaylist step, 5 s budget, 429 stop
# ------------------------------------------------------------
sub is9_nkey { return 'spoton_mfy_name_' . $_[0]; }
sub is9_fetch_for { my ($id) = @_; return scalar(grep { (pf_body($_)->{variables}{uri} // '') eq "spotify:playlist:$id" } is9_fetch_reqs()); }
sub is9_pv2_for   { my ($id) = @_; return scalar(grep { $_ eq $id } is9_pv2_ids()); }
sub is9_clear_requests { @Slim::Networking::SimpleAsyncHTTP::requests = (); }
sub is9_const { my $c = $SP->can($_[0]); return $c ? $c->() : undef; }

t_block('is9 MFY name cache, Pathfinder step and budget', sub {
    # --- cache A: a found name is kept 30 days, homeSection names seed the cache, a hit sends no request ---
    my $C1 = '37i9dQZF1EQ99IS9CACxx01';
    is9_setup();
    is9_pv2({ $C1 => 'Classic Rock Mix' });
    is9_pf(topmix => is9_topmix(is9_mix($C1, name => '')));
    my ($res) = run_mfy();
    my $e = $CK->get(is9_nkey($C1));
    ok(ref $e eq 'HASH' && ($e->{name} // '') eq 'Classic Rock Mix', 'is9 T2 cache: a looked-up name is kept under spoton_mfy_name_<id>');
    is($CK->ttl(is9_nkey($C1)), 2592000, 'is9 T2 cache: for 30 days');
    my $soulId = (split /:/, $SOUL59)[2];
    my $soul = is9_item($res, $soulId);
    my $se = $CK->get(is9_nkey($soulId));
    ok($soul && length($soul->{name}) && ref $se eq 'HASH' && ($se->{name} // '') eq $soul->{name}, 'is9 T2 cache: a name homeSection delivers seeds the cache');
    $CK->remove('spoton_mfy_list_acct1');
    $CK->remove("spoton_spclient_plenv_acct1_$C1");    # the 300 s envelope cache must not hide a missing name cache
    is9_clear_requests();
    ($res) = run_mfy();
    is(scalar(is9_pv2_ids()), 0, 'is9 T2 cache: a second build sends no playlist/v2 request (cache hit)');
    my $c1 = is9_item($res, $C1);
    is($c1 ? $c1->{name} : undef, 'Classic Rock Mix', 'is9 T2 cache: and still shows the name');

    # --- cache B (the Pi case): named in one build, nameless in the next ---
    my $S = '37i9dQZF1EQ99IS9CACxx05';
    is9_setup();
    is9_pf(topmix => is9_topmix(is9_mix($S, name => 'Seen Before')));
    run_mfy();
    $CK->remove('spoton_mfy_list_acct1');
    is9_clear_requests();
    is9_pf(topmix => is9_topmix(is9_mix($S, name => '')));
    ($res) = run_mfy();
    my $sb = is9_item($res, $S);
    is($sb ? $sb->{name} : undef, 'Seen Before', 'is9 T2 cache: a mix named in one build and nameless in the next keeps its name');
    is(is9_pv2_for($S) + is9_fetch_for($S), 0, 'is9 T2 cache: without any request');

    # --- cache C: preset entries, overwrite by homeSection, negative entry ---
    my ($C2, $N, $C3) = ('37i9dQZF1EQ99IS9CACxx02', '37i9dQZF1EQ99IS9CACxx03', '37i9dQZF1EQ99IS9CACxx04');
    is9_setup();
    $CK->set(is9_nkey($C2), { name => 'Cached Name' }, 2592000);
    $CK->set(is9_nkey($N),  { name => 'Stale Name' },  2592000);
    is9_pf(topmix => is9_topmix(is9_mix($C2, name => ''), is9_mix($N, name => 'Fresh Name'), is9_mix($C3, name => '')));
    ($res) = run_mfy();
    my $cc2 = is9_item($res, $C2);
    is($cc2 ? $cc2->{name} : undef, 'Cached Name', 'is9 T2 cache: a cached name names a nameless item');
    is(is9_pv2_for($C2) + is9_fetch_for($C2), 0, 'is9 T2 cache: and costs no request');
    my $nn = $CK->get(is9_nkey($N));
    ok(ref $nn eq 'HASH' && ($nn->{name} // '') eq 'Fresh Name', 'is9 T2 cache: a name homeSection delivers overwrites a stale entry');
    my $neg = $CK->get(is9_nkey($C3));
    ok(ref $neg eq 'HASH' && defined $neg->{name} && $neg->{name} eq '' && ($CK->ttl(is9_nkey($C3)) // 0) == 3600, 'is9 T2 cache: a failed lookup is kept as an empty entry for 1 hour');
    $CK->remove('spoton_mfy_list_acct1');
    is9_clear_requests();
    run_mfy();
    is(is9_pv2_for($C3) + is9_fetch_for($C3), 0, 'is9 T2 cache: the negative entry stops further lookups');
    is_deeply([ is9_const('MFY_NAME_TTL'), is9_const('MFY_NAME_NEG_TTL') ], [ 2592000, 3600 ], 'is9 T2 cache: MFY_NAME_TTL is 2592000 and MFY_NAME_NEG_TTL is 3600');

    # --- pathfinder: the second source ---
    my ($F1, $F2) = ('37i9dQZF1EQ99IS9PFBxx01', '37i9dQZF1EQ99IS9PFBxx02');
    is9_setup();
    is9_pf(topmix => is9_topmix(is9_mix($F1, name => ''), is9_mix($F2, name => '')),
        fetch => {
            $F1 => { data => { playlistV2 => { __typename => 'Playlist', uri => "spotify:playlist:$F1", name => 'PF Mix' } } },
            $F2 => { data => { playlistV2 => { __typename => 'NotFound', name => 'Not This' } } },
        });
    ($res) = run_mfy();
    my ($f1, $f2) = (is9_item($res, $F1), is9_item($res, $F2));
    is($f1 ? $f1->{name} : undef, 'PF Mix', 'is9 T2 pathfinder: playlist/v2 has no name, fetchPlaylist names the item');
    my @fr = is9_fetch_reqs();
    is(scalar(@fr), 2, 'is9 T2 pathfinder: exactly one fetchPlaylist request per item');
    my ($fq) = grep { (pf_body($_)->{variables}{uri} // '') eq "spotify:playlist:$F1" } @fr;
    my $fv = $fq ? pf_body($fq)->{variables} : {};
    ok($fq && $fv->{offset} == 0 && $fv->{limit} == 1 && defined $fv->{enableWatchFeedEntrypoint} && !$fv->{enableWatchFeedEntrypoint},
        'is9 T2 pathfinder: the query carries uri, offset 0, limit 1 and enableWatchFeedEntrypoint false');
    is($f2 ? $f2->{name} : undef, '', 'is9 T2 pathfinder: an answer that is not a Playlist gives no name');
    my $P1 = '37i9dQZF1EQ99IS9PFBxx03';
    is9_setup();
    is9_pv2({ $P1 => 'From PV2' });
    is9_pf(topmix => is9_topmix(is9_mix($P1, name => '')));
    run_mfy();
    is(scalar(is9_fetch_reqs()), 0, 'is9 T2 pathfinder: no fetchPlaylist request when playlist/v2 names the item');

    # --- budget: 5 s, the callback fires once, a cut-short build is not kept ---
    my @G = map { sprintf('37i9dQZF1EQ99IS9BUDxx%02d', $_) } 1 .. 3;
    is9_setup();
    is9_pv2({ map { $G[$_ - 1] => "Name G$_" } 1 .. 3 });
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @G));
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{/playlist/v2/playlist/};
    my @timers;
    my ($bres, $called) = (undef, 0);
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @timers, [ $_[1], $_[2] ] };
        $SP->getMadeForYou('acct1', sub { ($bres) = @_; $called++ });
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 5)) <= 1.5 } @timers;
        ok($bt && !$called, 'is9 T2 budget: a timer 5 s ahead was set and the callback has not fired');
        $bt->[1]->() if $bt;
        my @gn = map { my $it = is9_item($bres, $_); $it ? $it->{name} : '<missing>' } @G;
        ok($bt && $called == 1 && !(grep { $_ ne '' } @gn), 'is9 T2 budget: the timer delivers the list, the unresolved names are empty');
        ok($called == 1 && defined $CK->get('spoton_mfy_list_acct1') && ($CK->ttl('spoton_mfy_list_acct1') // 0) == 60, 'is9 T2 budget: a build cut short by the budget is kept in the list cache for 60 s only (nu9 W1)');
        1 while Slim::Networking::SimpleAsyncHTTP::release_one();
        is_deeply([ $called, scalar(is9_pv2_ids()) ], [ 1, 2 ], 'is9 T2 budget: the late answers neither call back again nor start a third lookup');
        my @ge = map { $CK->get(is9_nkey($_)) } @G[0, 1];
        ok(2 == grep({ ref $_ eq 'HASH' && ($_->{name} // '') =~ /\AName G[12]\z/ } @ge), 'is9 T2 budget: the late answers still fill the name cache');
    }
    is(is9_const('MFY_NAME_BUDGET'), 5, 'is9 T2 budget: MFY_NAME_BUDGET is 5');

    # --- ratelimit: a 429 stops the build ---
    my @RL = map { sprintf('37i9dQZF1EQ99IS9RLMxx%02d', $_) } 1 .. 3;
    is9_setup();
    is9_pv2({}, code => 429);
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @RL));
    run_mfy();
    is_deeply([ scalar(is9_pv2_ids()), scalar(is9_fetch_reqs()) ], [ 1, 0 ], 'is9 T2 ratelimit: after a 429 no further lookup starts, from either source');
    ok(defined $CK->get('spoton_mfy_list_acct1') && ($CK->ttl('spoton_mfy_list_acct1') // 0) == 60, 'is9 T2 ratelimit: and the build is kept in the list cache for 60 s only (nu9 W1)');
    ok(!(grep { defined $CK->get(is9_nkey($_)) } @RL), 'is9 T2 ratelimit: the stopped items get no name cache entry, positive or negative');
});

t_block('is9 MFY empty name diagnosis', sub {
    # --- nametype: Pathfinder says WHAT it sent in place of a name ---
    my $mk = sub {
        my ($id, %o) = @_;
        my %d = (__typename => 'Playlist', uri => "spotify:playlist:$id");
        $d{name} = $o{name} if exists $o{name};
        return { content => { data => \%d } };
    };
    my $env = { data => { homeSections => { sections => [ { sectionItems => { items => [
        $mk->('i1', name => 'Named'),
        $mk->('i2'),
        $mk->('i3', name => undef),
        $mk->('i4', name => ''),
        $mk->('i5', name => { transformedLabel => 'a', translatedBaseText => 'b' }),
        $mk->('i6', name => ['x']),
    ] } } ] } } };
    my @it = @{ $PF->_extractSectionItems($env) };
    ok(@it == 6 && !exists $it[0]{nameType}, 'is9 T2 nametype: a usable name carries no nameType');
    is(@it > 1 ? $it[1]{nameType} : undef, 'missing', 'is9 T2 nametype: no name key is "missing"');
    is(@it > 2 ? $it[2]{nameType} : undef, 'null', 'is9 T2 nametype: an undef name is "null"');
    is(@it > 3 ? $it[3]{nameType} : undef, 'empty', 'is9 T2 nametype: an empty string is "empty"');
    is(@it > 4 ? $it[4]{nameType} : undef, 'HASH{transformedLabel,translatedBaseText}', 'is9 T2 nametype: a hash names its keys, never its values');
    is(@it > 5 ? $it[5]{nameType} : undef, 'ARRAY', 'is9 T2 nametype: an array is "ARRAY"');
    is(@it > 1 ? $it[1]{dataKeys} : undef, '__typename,uri', 'is9 T2 nametype: dataKeys lists the key names of the item data');
    is(@it > 4 ? $it[4]{name} : undef, '', 'is9 T2 nametype: the name stays an empty string for a reference');

    # --- warn: one warning per hour that says what Spotify sent ---
    my ($WA, $WB) = ('37i9dQZF1EQ99IS9WARNx01', '37i9dQZF1EQ99IS9WARNx02');
    my $warns = sub { scalar grep { $_->[0] eq 'warn' && $_->[1] =~ /without a usable name/ } @Slim::Utils::Log::LOG };
    is9_setup();
    is9_pf(topmix => is9_topmix(is9_mix($WA, noname => 1),
        is9_mix($WB, name => { transformedLabel => 'a', translatedBaseText => 'b' })));
    my ($res, $err, $called) = run_mfy();
    ok($res && !$err && $called == 1 && ($res->{source} // '') eq 'pathfinder', 'is9 T2 warn: the build answers once from pathfinder');
    my @w = grep { $_->[0] eq 'warn' && $_->[1] =~ /without a usable name/ } @Slim::Utils::Log::LOG;
    is(scalar(@w), 1, 'is9 T2 warn: exactly one warning for the nameless items');
    my $w = @w ? $w[0][1] : undef;
    ok(defined $w && index($w, 'missing=1') >= 0, 'is9 T2 warn: it counts the missing name');
    ok(defined $w && index($w, 'HASH{transformedLabel,translatedBaseText}=1') >= 0, 'is9 T2 warn: and the hash name with its key names');
    ok(defined $w && index($w, '37i9dQZF1EQ=2') >= 0, 'is9 T2 warn: the id family is the first 11 characters');
    ok(defined $w && index($w, 'resolved: duplicate=0, cache=0, playlist=0, pathfinder=0, unresolved=2') >= 0, 'is9 T2 warn: and says how many lookups helped');
    ok(defined $w && $w !~ /testuser|listener|IS9WARN/, 'is9 T2 warn: it names no user, no madeFor value and no full playlist id');
    my ($ra, $rb) = (is9_item($res, $WA), is9_item($res, $WB));
    ok($ra && $rb && $ra->{name} eq '' && $rb->{name} eq '', 'is9 T2 warn: the unresolved items stay empty');
    $CK->remove('spoton_mfy_list_acct1');
    run_mfy();
    is($warns->(), 1, 'is9 T2 warn: a second build within the hour adds no second warning');
    $SP->reset();
    $CK->remove('spoton_mfy_list_acct1');
    run_mfy();
    is($warns->(), 2, 'is9 T2 warn: after a reset the next build warns again');
    is(is9_const('MFY_NAME_WARN_INTERVAL'), 3600, 'is9 T2 warn: MFY_NAME_WARN_INTERVAL is 3600');
    is9_setup();
    http_rule(qr{pathfinder/v2/query}, pf59_responder());
    run_mfy();
    is($warns->(), 0, 'is9 T2 warn: a build in which every item has a name logs no such warning');

    # the counts in the warning follow the sources: one name from the cache, one from playlist/v2, one duplicate, one unresolved
    my ($WC, $WP, $WD, $WU) = map { "37i9dQZF1EQ99IS9WARNy0$_" } 1 .. 4;
    is9_setup();
    $CK->set(is9_nkey($WC), { name => 'Cached W' }, 2592000);
    is9_pv2({ $WP => 'PV2 W' });
    my $wt = is9_topmix(is9_mix($WC, name => ''), is9_mix($WP, name => ''), is9_mix($WD, name => ''), is9_mix($WU, name => ''));
    push @{ is9_hs_items($wt) }, is9_mix($WD, name => 'Dup W');
    is9_pf(topmix => $wt);
    run_mfy();
    my ($w2) = map { $_->[1] } grep { $_->[0] eq 'warn' && $_->[1] =~ /without a usable name/ } @Slim::Utils::Log::LOG;
    ok(defined $w2 && index($w2, 'resolved: duplicate=1, cache=1, playlist=1, pathfinder=0, unresolved=1') >= 0,
        'is9 T2 warn: the counts split the names by source (a name found by a lookup is not a duplicate)');
});

# ============================================================
# 261110-k1b (#200) Task 1: Library > Playlists covers from the rootlist and the owner line, end to end
# ============================================================
t_block('k1b T1 e2e', sub {
    reset_all();
    seed_hash('libraryV3', $HASH_OLD);
    # inert in Task 1 (the rootlist-only path); keeps this block rootlist-only once libraryV3 exists
    http_rule(qr{pathfinder/v2/query}, sub { return (400, '{"errors":[]}') });
    my $pic = 'ab67706c0000da84' . ('cc' x 12);
    my $psz = 'https://i.scdn.co/image/ab67616d0000b273' . ('dd' x 12);
    http_rule(qr{/playlist/v2/user/.+/rootlist}, k1b_rootlist_bytes(
        { id => 'k1bT1e2eOwn00000000001', name => 'Own List',     owner => 'testuser',    picture => pack('H*', $pic) },
        { id => 'k1bT1e2eSpo00000000002', name => 'Spotify List', owner => 'spotify',     picture_size => [ [ 'default', $psz ] ] },
        { id => 'k1bT1e2eFor00000000003', name => 'Foreign List', owner => 'someoneelse' },
    ));
    my ($res, $err);
    eval { Plugins::SpotOn::API::SpClient->getUserPlaylists('acct1', {}, sub { ($res, $err) = @_ }); 1 } or diag "k1b T1 e2e: died: $@";
    my @m = map { Plugins::SpotOn::Plugin::_playlistItem(undef, $_) } @{ ($res && $res->{items}) || [] };
    my ($own, $spo, $for) = map { $m[$_] || {} } 0 .. 2;
    is($own->{image}, 'https://i.scdn.co/image/' . $pic, 'k1b T1 e2e: the own playlist shows its picture cover');
    is($spo->{image}, $psz, 'k1b T1 e2e: the Spotify playlist shows its first picture_size cover');
    is($for->{image}, 'html/images/playlists.png', 'k1b T1 e2e: a playlist without any cover keeps the generic icon');
    is($own->{line2}, '', 'k1b T1 e2e: the own playlist has an empty second line');
    is($spo->{line2}, 'Spotify', 'k1b T1 e2e: the Spotify playlist reads Spotify');
    is($for->{line2}, 'someoneelse', 'k1b T1 e2e: a foreign owner shows the user name');
});

# ============================================================
# 261110-k1b (#200) Task 2: libraryV3 covers and owner names (anonymized spike-016 replies)
# ============================================================
my $K1B = do {
    my $f = "$project_dir/t/fixtures/pathfinder/k1b-libraryV3.json";
    open(my $fh, '<:raw', $f) or BAIL_OUT("cannot read fixture $f: $!");
    local $/; JSON::PP->new->utf8->decode(<$fh>);
};
my $K1B_400_BODY = '{"errors":[{"message":"invalid input value at `$features[2]`: found JSON string for GraphQL type `LibraryFeature!`","extensions":{"name":"features","code":"VALIDATION_INVALID_TYPE_VARIABLE"}}]}';

sub k1b_defs {
    my ($fx) = @_;
    return [ map {
        my ($id) = $_->{uri} =~ /\Aspotify:playlist:(.+)\z/;
        +{ id => $id, name => $_->{name}, owner => $_->{owner},
           (defined $_->{revision} ? (revision => pack('H*', $_->{revision})) : ()),
           (defined $_->{picture}  ? (picture  => pack('H*', $_->{picture}))  : ()),
           picture_size => $_->{picture_size} };
    } @{ $fx->{rootlist} } ];
}
# the fixture's libraryV3 playlists: uri -> item data, uri -> page offset
sub k1b_pages {
    my ($fx) = @_;
    my (%data, %off);
    for my $o (0, 50) {
        for my $it (@{ $fx->{pages}{$o}{data}{me}{libraryV3}{items} }) {
            my $d = $it->{item}{data};
            next unless ($d->{__typename} // '') eq 'Playlist';
            $data{ $d->{uri} } = $d;
            $off{ $d->{uri} }  = $o;
        }
    }
    return (\%data, \%off);
}
sub k1b_has_cover { my ($r) = @_; return (defined $r->{picture} || @{ $r->{picture_size} || [] }) ? 1 : 0; }
sub k1b_foreign   { my ($r) = @_; return (defined $r->{owner} && $r->{owner} ne 'testuser' && $r->{owner} ne 'spotify') ? 1 : 0; }

sub k1b_empty_page {
    my ($off, $total) = @_;
    return { data => { me => { libraryV3 => { items => [], totalCount => $total, pagingInfo => { limit => 50, offset => $off } } } } };
}
# a page of 50 playlists that are in nobody's rootlist
sub k1b_unrelated_page {
    my ($off, $total) = @_;
    my @items = map {
        my $id = 'k1bUn' . sprintf('%017d', $off + $_);
        +{ depth => 0, item => { __typename => 'PlaylistResponseWrapper', _uri => "spotify:playlist:$id", data => {
            __typename => 'Playlist', uri => "spotify:playlist:$id", name => 'Unrelated', revisionId => 'AAAA',
            images => { items => [ { sources => [ { url => 'https://i.scdn.co/image/' . ('0' x 40), width => undef, height => undef } ] } ] },
            ownerV2 => { data => { __typename => 'User', username => 'testuser', name => 'Test User', uri => 'spotify:user:testuser' } },
        } } };
    } 0 .. 49;
    return { data => { me => { libraryV3 => { __typename => 'LibraryPage', items => \@items, totalCount => $total, pagingInfo => { limit => 50, offset => $off } } } } };
}
# answers libraryV3 by variables.offset from the fixture pages, else an empty page with the same totalCount;
# %o: all => sub($e, $offset) -> (code, body, hdrs) for every offset, override => { offset => sub($e) }
sub k1b_pf_rule {
    my ($fx, %o) = @_;
    my $total = $fx->{pages}{0}{data}{me}{libraryV3}{totalCount};
    return sub {
        my ($e) = @_;
        my $req = pf_body($e);
        return (200, '{"data":{}}') unless ($req->{operationName} // '') eq 'libraryV3';
        my $off = $req->{variables}{offset} // 0;
        return $o{override}{$off}->($e) if $o{override} && $o{override}{$off};
        return $o{all}->($e, $off)      if $o{all};
        my $pg = $fx->{pages}{$off} // k1b_empty_page($off, $total);
        return (200, $JSON->encode($pg));
    };
}
# the rootlist and Pathfinder rules for one scenario; returns the fixture used
sub k1b_setup {
    my (%o) = @_;
    my $fx = $o{fx} // clone($K1B);
    reset_all();
    seed_hash('libraryV3', $HASH_OLD) unless $o{nohash};
    http_rule(qr{/playlist/v2/user/.+/rootlist}, k1b_rootlist_bytes(@{ $o{defs} // k1b_defs($fx) }));
    http_rule(qr{pathfinder/v2/query}, k1b_pf_rule($fx, %o)) unless $o{nopf};
    return $fx;
}
sub k1b_run {
    my ($acct) = @_;
    my ($res, $err, $n);
    $SP->getUserPlaylists($acct // 'acct1', { limit => 500 }, sub { ($res, $err) = @_; $n++ });
    return ($res, $err, $n // 0);
}
sub k1b_rl_reqs  { return grep { $_->{url} =~ m{/rootlist} } @Slim::Networking::SimpleAsyncHTTP::requests; }
sub k1b_all_reqs { return scalar grep { $_->{url} !~ /apresolve/ } @Slim::Networking::SimpleAsyncHTTP::requests; }
sub k1b_drop_lists { my ($acct) = @_; $CK->remove('spoton_spclient_libpl_' . ($acct // 'acct1')); $CK->remove('spoton_spclient_rootlist_' . ($acct // 'acct1')); }
sub k1b_rev_key { my ($r) = @_; my ($id) = $r->{uri} =~ /\Aspotify:playlist:(.+)\z/; return "spoton_plmeta_${id}_" . ($r->{revision} // 'norev'); }
sub k1b_stats {
    my ($res) = @_;
    my @it = @{ ($res && $res->{items}) || [] };
    return {
        n      => scalar(@it),
        covers => scalar(grep { @{ $_->{images} || [] } } @it),
        own    => scalar(grep { ($_->{owner}{id} // '') eq 'testuser' && ($_->{owner}{display_name} // 'x') eq '' } @it),
        spo    => scalar(grep { ($_->{owner}{id} // '') eq 'spotify' && ($_->{owner}{display_name} // '') eq 'Spotify' } @it),
        asuser => scalar(grep { ($_->{owner}{id} // '') !~ /\A(?:testuser|spotify)\z/ && ($_->{owner}{display_name} // '') eq ($_->{owner}{id} // '?') } @it),
    };
}

t_block('k1b T2 page', sub {
    my $fx = k1b_setup();
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
    my ($res, $err, $n);
    $SP->getUserPlaylists('acct1', { limit => 500 }, sub { ($res, $err) = @_; $n++ });
    my $guard = 0;
    while (Slim::Networking::SimpleAsyncHTTP::release_one()) { last if ++$guard > 30 }
    my @pf = pf_requests();
    is(scalar(@pf), 2, 'k1b T2 page: a cold open of the 97 playlist fixture sends exactly 2 Pathfinder requests');
    is(join(',', map { pf_body($_)->{operationName} // '?' } @pf), 'libraryV3,libraryV3', 'k1b T2 page: both are libraryV3');
    is(join(',', map { pf_body($_)->{variables}{offset} // '?' } @pf), '0,50', 'k1b T2 page: offsets 0 and 50');
    is(join(',', map { pf_body($_)->{variables}{limit} // '?' } @pf), '50,50', 'k1b T2 page: limit 50 per page');
    my $want = '{"expandedFolders":[],"features":["LIKED_SONGS","YOUR_EPISODES_V2"],"filters":["Playlists"],"flatten":false,"folderUri":null,'
             . '"includeFoldersWhenFlattening":true,"limit":50,"offset":0,"order":null,"textFilter":""}';
    is(@pf ? $JSON->encode(pf_body($pf[0])->{variables}) : '', $want, 'k1b T2 page: the variables are the measured set (booleans as JSON booleans)');
    is($Slim::Networking::SimpleAsyncHTTP::max_inflight, 1, 'k1b T2 page: the pages go one after the other (never more than 1 in flight)');
    ok($n == 1 && $res && $res->{total} == 97, 'k1b T2 page: the open is answered once with the 97 playlists');

    # early stop: the only playlist that needs libraryV3 sits on page 0
    my (undef, $off) = k1b_pages($fx);
    my ($lone) = grep { !k1b_has_cover($_) && $_->{owner} eq 'testuser' && ($off->{ $_->{uri} } // -1) == 0 } @{ $fx->{rootlist} };
    my @defs = @{ k1b_defs($fx) }[ grep { k1b_has_cover($fx->{rootlist}[$_]) && !k1b_foreign($fx->{rootlist}[$_]) } 0 .. $#{ $fx->{rootlist} } ];
    @defs = @defs[0 .. 1];
    my ($loneDef) = grep { 'spotify:playlist:' . $_->{id} eq ($lone ? $lone->{uri} : '') } @{ k1b_defs($fx) };
    k1b_setup(fx => $fx, defs => [ @defs, ($loneDef ? $loneDef : ()) ]);
    k1b_run();
    is(scalar(pf_requests()), 1, 'k1b T2 page: it stops after page 0 when everything needed was seen there');

    # page cap: a playlist that no page ever returns, 5000 entries claimed
    # 261111-j57: the clock is a seam (the page-limit marker lives 24 h); no negative entry at the cap, an account-bound marker
    my $T = 1_700_100_000;
    no warnings 'redefine';
    local *Plugins::SpotOn::API::SpClient::_libClock = sub { $T };
    my $nameless = { id => 'k1bMissing0000000000001', name => 'Nowhere', owner => 'testuser' };
    my $NK = 'spoton_plmeta_k1bMissing0000000000001_norev';
    my $MK = 'spoton_libv3_capped_acct1_k1bMissing0000000000001';
    k1b_setup(fx => $fx, defs => [ $nameless ], all => sub { my ($e, $o) = @_; return (200, $JSON->encode(k1b_unrelated_page($o, 5000))) });
    my ($r2) = k1b_run();
    is(scalar(pf_requests()), 10, 'k1b T2 page: at most 10 pages are fetched');
    ok(!defined $CK->get($NK), 'j57 cap: the playlist beyond the page limit gets no negative entry');
    my $mk = $CK->get($MK);
    ok(ref $mk eq 'HASH' && ($mk->{at} // 0) == $T && ($CK->ttl($MK) // 0) == 86400, 'j57 cap: it gets a page-limit marker of the account for 24 h');
    my $sc = $SP->libraryMetaStatus() || {};
    is(join(',', $sc->{state} // '?', $sc->{missing} // '?'), 'ok,1', 'j57 cap: the status counts the never-queried playlist as missing (ok,1)');
    is(join(',', $sc->{skipped} // '?', $sc->{limit} // '?'), '1,500', 'j57 skipped: the capped run counts the never-queried playlist as skipped and names the limit (1,500)');
    k1b_drop_lists();
    my $before = scalar(pf_requests());
    my ($r3) = k1b_run();
    is(scalar(pf_requests()) - $before, 0, 'k1b T2 page: the playlist no page returned has a page-limit marker, the next open asks for no page');
    is(scalar(@{ ($r3 && $r3->{items}[0]{images}) || ['x'] }), 0, 'k1b T2 page: and it keeps the generic icon (no images)');
    my $b6 = scalar(pf_requests());
    k1b_run('acct2');
    is(scalar(pf_requests()) - $b6, 10, 'j57 cap: the marker belongs to the account: another account still asks libraryV3 (10 pages)');
    $T += 86400;
    k1b_drop_lists();
    my $b1 = scalar(pf_requests());
    k1b_run();
    my $mk2 = $CK->get($MK);
    ok(scalar(pf_requests()) - $b1 == 10 && ref $mk2 eq 'HASH' && ($mk2->{at} // 0) == $T,
        'j57 cap: after 24 h (clock seam) the next open asks libraryV3 again (10 pages) and renews the marker');

    # a later run that the marker keeps from asking: the marker renewed above is valid. The rootlist is now the marked
    # playlist plus one that sits on fixture page 0 (NOT k1b_setup: it would clear the cache and the marker)
    my ($pgE, $offE) = k1b_pages($fx);
    my ($recE) = grep { !k1b_has_cover($_) && ($offE->{ $_->{uri} } // -1) == 0 } @{ $fx->{rootlist} };
    my ($defE) = grep { 'spotify:playlist:' . $_->{id} eq $recE->{uri} } @{ k1b_defs($fx) };
    http_rule(qr{/playlist/v2/user/.+/rootlist}, k1b_rootlist_bytes($nameless, $defE));
    http_rule(qr{pathfinder/v2/query}, k1b_pf_rule($fx, override => { 0 => sub { return (200, $JSON->encode($fx->{pages}{0})) } },
        all => sub { my ($e, $o) = @_; return (200, $JSON->encode(k1b_unrelated_page($o, 5000))) }));
    k1b_drop_lists();
    my $b3 = scalar(pf_requests());
    k1b_run();
    my $s3 = $SP->libraryMetaStatus() || {};
    is(join(',', scalar(pf_requests()) - $b3, $s3->{state} // '?', $s3->{missing} // '?', $s3->{skipped} // '?'), '1,ok,1,1',
        'j57 skipped: a later run that the marker keeps from asking counts the marked playlist in missing and skipped (1 page, ok,1,1)');

    # a library that ends exactly on the 10th page is read completely: negative entry, no marker
    k1b_setup(fx => $fx, defs => [ $nameless ], all => sub { my ($e, $o) = @_; return (200, $JSON->encode(k1b_unrelated_page($o, 500))) });
    k1b_run();
    my $s4 = $SP->libraryMetaStatus() || {};
    ok(scalar(pf_requests()) == 10 && defined $CK->get($NK) && !defined $CK->get($MK) && join(',', $s4->{state} // '?', $s4->{missing} // '?') eq 'ok,0',
        'j57 cap: a library that ends on the 10th page is read completely (10 pages, negative entry, no marker, status ok,0)');
    is($s4->{skipped} // '?', 0, 'j57 skipped: a library that ends on the 10th page skips nothing (0)');

    # a hit on a page before the limit is still applied
    my ($pg, $off) = k1b_pages($fx);
    my ($seenRec) = grep { !k1b_has_cover($_) && ($off->{ $_->{uri} } // -1) == 0 } @{ $fx->{rootlist} };
    my ($seenDef) = grep { 'spotify:playlist:' . $_->{id} eq $seenRec->{uri} } @{ k1b_defs($fx) };
    k1b_setup(fx => $fx, defs => [ $nameless, $seenDef ],
        override => { 0 => sub { return (200, $JSON->encode($fx->{pages}{0})) } },
        all => sub { my ($e, $o) = @_; return (200, $JSON->encode(k1b_unrelated_page($o, 5000))) });
    my ($r5) = k1b_run();
    my $m5 = $CK->get(k1b_rev_key($seenRec));
    my ($sid) = $seenRec->{uri} =~ /\Aspotify:playlist:(.+)\z/;
    ok(scalar(pf_requests()) == 10 && $r5 && @{ $r5->{items}[1]{images} || [] } >= 1 && ref $m5 eq 'HASH' && @{ $m5->{images} || [] } >= 1
        && !defined $CK->get("spoton_libv3_capped_acct1_$sid"),
        'j57 cap: a hit on a page before the limit is still applied (cover in the list, positive entry, no marker)');
});

t_block('k1b T2 merge', sub {
    my $fx = k1b_setup();
    my ($res, $err, $n) = k1b_run();
    my @it = @{ ($res && $res->{items}) || [] };
    my ($pg) = k1b_pages($fx);
    my $st = k1b_stats($res);
    is(join(',', $res ? $res->{total} : 'undef', scalar(@it)), '97,97', 'k1b T2 merge: 97 playlists');
    is_deeply([ map { $_->{uri} } @it ], [ map { $_->{uri} } @{ $fx->{rootlist} } ], 'k1b T2 merge: in rootlist order');
    is($st->{covers}, 97, 'k1b T2 merge: a cover on 97 of 97');
    is($st->{own}, 47, 'k1b T2 merge: the own owner line is empty on 47');
    is($st->{spo}, 20, 'k1b T2 merge: Spotify on 20');
    my $named = 0;
    for my $i (0 .. $#it) {
        my $r = $fx->{rootlist}[$i];
        next unless k1b_foreign($r);
        my $want = $pg->{ $r->{uri} } ? $pg->{ $r->{uri} }{ownerV2}{data}{name} : undef;
        $named++ if defined $want && length $want && ($it[$i]{owner}{display_name} // '') eq $want;
    }
    is($named, 30, 'k1b T2 merge: each of the 30 foreign playlists shows the libraryV3 owner name');
    my $eq = 0;
    for my $r (grep { k1b_foreign($_) } @{ $fx->{rootlist} }) {
        my $d = $pg->{ $r->{uri} } or next;
        next unless $d->{ownerV2}{data}{name} eq $d->{ownerV2}{data}{username};
        my $o = $CK->get('spoton_owner_name_' . $r->{owner});
        $eq++ if ref($o) eq 'HASH' && ($o->{name} // '') eq $r->{owner} && ($CK->ttl('spoton_owner_name_' . $r->{owner}) // 0) == 604800;
    }
    is($eq, 11, 'k1b T2 merge: the 11 playlists whose display name equals the user name are positive owner entries');
    ok(!(grep { !$SP->_imageUrlAllowed($_->{url}) } map { @{ $_->{images} || [] } } @it), 'k1b T2 merge: every image url is allowed (https, scdn.co or spotifycdn.com)');
    my $cached = $CK->get('spoton_spclient_rootlist_acct1') || [];
    my $untouched = 0;
    for my $i (0 .. $#{ $fx->{rootlist} }) {
        $untouched++ if !k1b_has_cover($fx->{rootlist}[$i]) && $cached->[$i] && !@{ $cached->[$i]{images} || ['x'] };
    }
    is($untouched, 38, 'k1b T2 merge: the cached rootlist entries of the 38 cover-less playlists still have no images (copies, no mutation)');
});

t_block('k1b T2 cache', sub {
    my $fx = k1b_setup();
    k1b_run();
    my $before = k1b_all_reqs();
    my ($res2) = k1b_run();
    is(k1b_all_reqs() - $before, 0, 'k1b T2 cache: a second open within 60 s sends no request of any kind');
    is($CK->ttl('spoton_spclient_libpl_acct1'), 60, 'k1b T2 cache: the merged list is kept for 60 s');
    my (undef, $off) = k1b_pages($fx);
    my ($cl) = grep { !k1b_has_cover($_) } @{ $fx->{rootlist} };
    is($CK->ttl(k1b_rev_key($cl)), 86400, 'k1b T2 cache: a playlist entry is kept for 1 day, keyed with the rootlist revision');
    my ($fo) = grep { k1b_foreign($_) } @{ $fx->{rootlist} };
    is($CK->ttl('spoton_owner_name_' . $fo->{owner}), 604800, 'k1b T2 cache: an owner name is kept for 7 days');

    k1b_drop_lists();
    my ($r0, $p0) = (scalar(k1b_rl_reqs()), scalar(pf_requests()));
    k1b_run();
    is(scalar(k1b_rl_reqs()) - $r0, 1, 'k1b T2 cache: after the 60 s caches expire the open costs one rootlist request');
    is(scalar(pf_requests()) - $p0, 0, 'k1b T2 cache: and no libraryV3 request while no revision changed');

    # one playlist on page 0 gets a new revision (it changed)
    my ($chg) = grep { !k1b_has_cover($_) && ($off->{ $_->{uri} } // -1) == 0 } @{ $fx->{rootlist} };
    my $fx2 = clone($fx);
    for my $r (@{ $fx2->{rootlist} }) { $r->{revision} = unpack('H*', 'k1bChangedRevisionBytes!') if $r->{uri} eq $chg->{uri}; }
    http_rule(qr{/playlist/v2/user/.+/rootlist}, k1b_rootlist_bytes(@{ k1b_defs($fx2) }));
    k1b_drop_lists();
    $p0 = scalar(pf_requests());
    k1b_run();
    is(scalar(pf_requests()) - $p0, 1, 'k1b T2 cache: a changed revision of one playlist on page 0 costs exactly one libraryV3 request');

    # a foreign owner whose libraryV3 name is empty: negative owner entry, the line keeps the user name
    my $fx3 = clone($K1B);
    my ($fo3) = grep { k1b_foreign($_) } @{ $fx3->{rootlist} };
    for my $o (0, 50) {
        for my $it (@{ $fx3->{pages}{$o}{data}{me}{libraryV3}{items} }) {
            my $o3 = $it->{item}{data}{ownerV2}{data};
            $o3->{name} = '' if $o3 && ($o3->{username} // '') eq $fo3->{owner};
        }
    }
    k1b_setup(fx => $fx3);
    my ($res3) = k1b_run();
    is_deeply($CK->get('spoton_owner_name_' . $fo3->{owner}), { name => '' }, 'k1b T2 cache: an owner without a display name is a negative owner entry');
    is($CK->ttl('spoton_owner_name_' . $fo3->{owner}), 86400, 'k1b T2 cache: kept for 1 day');
    my ($i3) = grep { $fx3->{rootlist}[$_]{uri} eq $fo3->{uri} } 0 .. $#{ $fx3->{rootlist} };
    is($res3 && defined $i3 ? $res3->{items}[$i3]{owner}{display_name} : undef, $fo3->{owner}, 'k1b T2 cache: and the line keeps the user name');
});

t_block('k1b T2 400', sub {
    my $fx = k1b_setup(all => sub { return (400, $K1B_400_BODY) });
    my ($res) = k1b_run();
    my $st = k1b_stats($res);
    is($st->{covers}, 59, 'k1b T2 400: a 400 leaves the rootlist covers (59 of 97)');
    is($st->{asuser}, 30, 'k1b T2 400: the 30 foreign playlists show the user name');
    is($st->{own}, 47, 'k1b T2 400: own lines stay empty (47)');
    is($st->{spo}, 20, 'k1b T2 400: Spotify stays Spotify (20)');
    is(scalar(pf_requests()), 1, 'k1b T2 400: exactly one Pathfinder request');
    is($CK->ttl('spoton_libv3_off_acct1'), 3600, 'k1b T2 400: libraryV3 is switched off for this account for 3600 s');
    my $keys = grep { defined $CK->get(k1b_rev_key($_)) } @{ $fx->{rootlist} };
    is($keys, 0, 'k1b T2 400: no playlist entry is written');
    k1b_drop_lists();
    my $before = scalar(pf_requests());
    k1b_run();
    is(scalar(pf_requests()) - $before, 0, 'k1b T2 400: the next open within the hour sends no Pathfinder request');

    k1b_setup(all => sub { return (429, '', { 'Retry-After' => 7 }) });
    my ($r429) = k1b_run();
    my $s429 = k1b_stats($r429);
    is(join(',', @{$s429}{qw(covers asuser own spo)}), '59,30,47,20', 'k1b T2 400: a 429 gives the same values');
    ok(!defined $CK->get('spoton_libv3_off_acct1'), 'k1b T2 400: and does not switch libraryV3 off');

    k1b_setup(all => sub { return (200, '{"errors":[{"message":"x"}]}') });
    k1b_run();
    is($CK->ttl('spoton_libv3_off_acct1'), 3600, 'k1b T2 400: an errors[] reply switches libraryV3 off as well');

    my $fx5 = k1b_setup(override => { 50 => sub { return (500, '') } });
    my ($r500) = k1b_run();
    my ($pg, $off) = k1b_pages($fx5);
    my $cl0 = scalar grep { !k1b_has_cover($_) && ($off->{ $_->{uri} } // -1) == 0 } @{ $fx5->{rootlist} };
    is(k1b_stats($r500)->{covers}, 59 + $cl0, 'k1b T2 400: a 500 on page 50 keeps what page 0 delivered, the rest stays in the rootlist state');
    ok(!defined $CK->get('spoton_libv3_off_acct1') && !(grep { defined $CK->get(k1b_rev_key($_)) && !@{ $CK->get(k1b_rev_key($_))->{images} || [] } } @{ $fx5->{rootlist} }),
        'k1b T2 400: a 500 sets no off key and writes no negative entry');
});

t_block('k1b T2 coalesce', sub {
    k1b_setup();
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
    my (@r1, @r2, $c1, $c2);
    $SP->getUserPlaylists('acct1', { limit => 500 }, sub { @r1 = @_; $c1++ });
    $SP->getUserPlaylists('acct1', { limit => 500 }, sub { @r2 = @_; $c2++ });
    is(join(',', scalar(k1b_rl_reqs()), scalar(@Slim::Networking::SimpleAsyncHTTP::held)), '1,1',
        'k1b T2 coalesce: two opens before any answer: one rootlist request and one parked Pathfinder request');
    my $guard = 0;
    while (Slim::Networking::SimpleAsyncHTTP::release_one()) { last if ++$guard > 30 }
    is(join(',', $c1 // 0, $c2 // 0), '1,1', 'k1b T2 coalesce: each callback fires exactly once');
    ok($r1[0] && $r2[0] && $JSON->encode($r1[0]) eq $JSON->encode($r2[0]) && $r1[0]{total} == 97, 'k1b T2 coalesce: both get the same 97 playlists');
});

t_block('k1b T2 opmissing', sub {
    my $fx = k1b_setup(nohash => 1, nopf => 1);
    scrape_rules();
    my ($res, $err, $n) = k1b_run();
    my $want = $SP->_parseRootlist(k1b_rootlist_bytes(@{ k1b_defs($fx) }), 'testuser');
    ok($n == 1 && $res && $JSON->encode($res->{items}) eq $JSON->encode($want), 'k1b T2 opmissing: without the op the result is the rootlist state');
    my $h = $PF->healthSnapshot();
    ok((grep { $_ eq 'libraryV3' } @{ $h->{opsMissing} || [] }), 'k1b T2 opmissing: libraryV3 shows in opsMissing');
});

# ============================================================
# 261110-k1b (#200) Task 3: the library metadata status (SpClient->libraryMetaStatus) and the WARN on a 400
# ============================================================
t_block('k1b T3 status', sub {
    my $T = 1_700_000_000;
    no warnings 'redefine';
    local *Plugins::SpotOn::API::SpClient::_libClock = sub { $T };
    my $st = sub { return $SP->can('libraryMetaStatus') ? $SP->libraryMetaStatus() : undef };
    my $ok_rule = sub { my ($fx) = @_; http_rule(qr{pathfinder/v2/query}, k1b_pf_rule($fx)); };

    # A: unknown before any run, ok after the full fixture, a merged-list hit leaves it alone
    my $fx = k1b_setup();
    is_deeply($st->(), { state => 'unknown', at => undef, since => undef, reason => undef, missing => undef, skipped => undef, limit => 500 },
        'k1b T3 status: before any run the state is unknown and the other keys are empty (the limit is 500)');
    k1b_run();
    is_deeply($st->(), { state => 'ok', at => $T, since => undef, reason => undef, missing => 0, skipped => 0, limit => 500 },
        'k1b T3 status: the full fixture run is ok at the run time, since empty, nothing missing (the 11 equal-name owners count as resolved)');
    $T += 10;
    k1b_run();
    is(($st->() || {})->{at}, $T - 10, 'k1b T3 status: a merged-list hit leaves the time of the last real run alone');

    # B: a cover-less playlist libraryV3 never returns
    my $defs = k1b_defs($fx);
    push @$defs, +{ id => 'k1bExtra0000000000000001', name => 'Extra', owner => 'testuser' };
    k1b_setup(fx => $fx, defs => $defs);
    $T = 1_700_001_000;
    k1b_run();
    my $b = $st->() || {};
    # 261111-i1i UR8-3: the playlist libraryV3 never returns gets a negative entry, and a negative entry is not "missing"
    # (Spotify has nothing); the old expectation here was ok,1
    is(join(',', $b->{state} // '?', $b->{missing} // '?'), 'ok,0',
        'i1i missing: a cover-less playlist libraryV3 did not return has a negative entry and is not counted (deliberate change of the k1b expectation ok,1)');

    # B4: the negative entry of that earlier run still keeps the playlist out of the count (this run asks page 0 only)
    my (undef, $offB) = k1b_pages($fx);
    my ($chgB) = grep { !k1b_has_cover($_) && ($offB->{ $_->{uri} } // -1) == 0 } @{ $fx->{rootlist} };
    my $fxB = clone($fx);
    for my $r (@{ $fxB->{rootlist} }) { $r->{revision} = unpack('H*', 'k1bChangedRevisionBytes!') if $r->{uri} eq $chgB->{uri}; }
    my $defsB = k1b_defs($fxB);
    push @$defsB, +{ id => 'k1bExtra0000000000000001', name => 'Extra', owner => 'testuser' };
    http_rule(qr{/playlist/v2/user/.+/rootlist}, k1b_rootlist_bytes(@$defsB));
    k1b_drop_lists();
    $T = 1_700_001_500;
    k1b_run();
    my $b4 = $st->() || {};
    is(join(',', $b4->{state} // '?', $b4->{missing} // '?'), 'ok,0', 'i1i missing: a negative entry from an earlier run still keeps the playlist out of the count');

    # B2: every playlist of an owner with a negative owner entry (libraryV3 has no display name) is excused
    my $fxO = clone($K1B);
    my ($foO) = grep { k1b_foreign($_) } @{ $fxO->{rootlist} };
    for my $o (0, 50) {
        for my $it (@{ $fxO->{pages}{$o}{data}{me}{libraryV3}{items} }) {
            my $oO = $it->{item}{data}{ownerV2}{data};
            $oO->{name} = '' if $oO && ($oO->{username} // '') eq $foO->{owner};
        }
    }
    k1b_setup(fx => $fxO);
    k1b_run();
    my $b2 = $st->() || {};
    is(join(',', $b2->{state} // '?', $b2->{missing} // '?'), 'ok,0', 'i1i missing: playlists of an owner with a negative owner entry are not counted');

    # B3: a foreign playlist with a positive per-playlist entry is never looked up: no owner name and no negative entry
    # of any kind, so it is still counted (and the own cover-less one libraryV3 does not return is excused)
    my $fxS = clone($K1B);
    my $defsS = k1b_defs($fxS);
    push @$defsS, +{ id => 'k1bExtra0000000000000002', name => 'Extra', owner => 'testuser' };
    push @$defsS, +{ id => 'k1bSeeded00000000000001', name => 'Seeded', owner => 'k1bnobodyowner',
                     picture => pack('H*', 'ab67706c0000da84' . ('cc' x 12)) };
    k1b_setup(fx => $fxS, defs => $defsS);
    $CK->set('spoton_plmeta_k1bSeeded00000000000001_norev',
        { images => [ { url => 'https://i.scdn.co/image/ab67706c0000da84' . ('cc' x 12), width => undef, height => undef } ] }, 86400);
    k1b_run();
    my $b3 = $st->() || {};
    is(join(',', $b3->{state} // '?', $b3->{missing} // '?'), 'ok,1',
        'i1i missing: a foreign playlist without owner name and without any negative entry is still counted');

    # C: 400 -> fallback, a second 400 keeps since, an off-key call leaves it, an ok run ends the streak
    k1b_setup(fx => $fx, all => sub { return (400, $K1B_400_BODY) });
    my ($T2, $T3, $T4, $T5) = (1_700_002_000, 1_700_002_500, 1_700_002_600, 1_700_003_000);
    $T = $T2;
    k1b_run();
    is_deeply($st->(), { state => 'fallback', at => $T2, since => $T2, reason => 'HTTP 400', missing => undef, skipped => undef, limit => 500 },
        'k1b T3 status: a 400 is fallback since now, reason HTTP 400');
    $T = $T3;
    $CK->remove('spoton_libv3_off_acct1'); k1b_drop_lists();
    k1b_run();
    my $c2 = $st->() || {};
    is(join(',', $c2->{state} // '?', $c2->{since} // '?', $c2->{at} // '?'), "fallback,$T2,$T3", 'k1b T3 status: a second 400 keeps the start of the streak');
    $T = $T4;
    k1b_drop_lists();
    k1b_run();
    is(($st->() || {})->{at}, $T3, 'k1b T3 status: a call blocked by the off key leaves the status alone');
    $ok_rule->($fx);
    $CK->remove('spoton_libv3_off_acct1'); k1b_drop_lists();
    $T = $T5;
    k1b_run();
    is_deeply($st->(), { state => 'ok', at => $T5, since => undef, reason => undef, missing => 0, skipped => 0, limit => 500 }, 'k1b T3 status: an ok run after the fallback ends the streak');
    my $json = $JSON->encode($st->() || {});
    ok($json !~ /testuser|owner0|Owner Name|Playlist /, 'k1b T3 status: the status carries no user name, owner name or playlist name');

    # D: a 500 names its code
    k1b_setup(fx => $fx, all => sub { return (500, '') });
    $T = 1_700_004_000;
    k1b_run();
    my $d = $st->() || {};
    is(join(',', $d->{state} // '?', $d->{reason} // '?', $d->{since} // '?'), "fallback,HTTP 500,$T", 'k1b T3 status: a 500 is fallback with the reason HTTP 500');
});

t_block('k1b T3 warn', sub {
    my $T = 1_700_000_000;
    no warnings 'redefine';
    local *Plugins::SpotOn::API::SpClient::_libClock = sub { $T };
    my $warns = sub { return grep { $_->[0] eq 'warn' && $_->[1] =~ /libraryV3/ && $_->[1] =~ /HTTP 400/ } @Slim::Utils::Log::LOG };

    my $fx = k1b_setup(all => sub { return (400, $K1B_400_BODY) });
    k1b_run();
    is(scalar($warns->()), 1, 'k1b T3 warn: the first 400 writes one warning');
    $T += 100;
    $CK->remove('spoton_libv3_off_acct1'); k1b_drop_lists();
    k1b_run();
    is(scalar($warns->()), 1, 'k1b T3 warn: a second 400 within the hour writes none');
    $T += 3501;
    $CK->remove('spoton_libv3_off_acct1'); k1b_drop_lists();
    k1b_run();
    is(scalar($warns->()), 2, 'k1b T3 warn: a 400 an hour later writes the next one');
    http_rule(qr{pathfinder/v2/query}, k1b_pf_rule($fx, all => sub { return (500, '') }));
    $T += 4000;
    $CK->remove('spoton_libv3_off_acct1'); k1b_drop_lists();
    k1b_run();
    is(scalar($warns->()), 2, 'k1b T3 warn: a 500 writes no such warning');
    ok(!(grep { $_->[0] eq 'warn' && $_->[1] =~ /testuser|owner0|Owner Name/ } @Slim::Utils::Log::LOG), 'k1b T3 warn: no warning carries a user name or an owner name');
});

# ============================================================
# 261110-k1b (#200) real material, env-gated: SPOTON_K1B_REAL names a directory with rootlist.bin and the libraryV3
# replies pf-libv3-b.out (offset 0) and pf-libv3-c.out (offset 50) of spike 016. The material holds real user names:
# the assertions carry counts only, never a name, an id or a url.
# ============================================================
SKIP: {
    my $real = $ENV{SPOTON_K1B_REAL};
    skip 'SPOTON_K1B_REAL is not set', 12 unless defined $real && length($real) && -d $real;
    t_block('k1b real', sub {
        my $slurp = sub { open(my $fh, '<:raw', $_[0]) or die "cannot read $_[0]: $!"; local $/; return scalar <$fh>; };
        my $bytes = $slurp->("$real/rootlist.bin");
        my %page  = map { my $t = $slurp->("$real/$_->[1]"); $t =~ s/^[^{]*//s; ($_->[0] => $t) } ([ 0 => 'pf-libv3-b.out' ], [ 50 => 'pf-libv3-c.out' ]);
        my $total = JSON::PP->new->utf8->decode($page{0})->{data}{me}{libraryV3}{totalCount};

        # the account's user name: the most frequent rootlist owner
        my %cnt;
        $cnt{ $_->{owner}{id} }++ for grep { $_->{owner} } @{ $SP->_parseRootlist($bytes, undef) || [] };
        my ($self) = sort { $cnt{$b} <=> $cnt{$a} || $a cmp $b } keys %cnt;

        # the expected owner name per playlist, from the two pages
        my %want;
        for my $o (0, 50) {
            for my $it (@{ JSON::PP->new->utf8->decode($page{$o})->{data}{me}{libraryV3}{items} }) {
                my $d = $it->{item}{data};
                next unless ($d->{__typename} // '') eq 'Playlist';
                $want{ $d->{uri} } = $d->{ownerV2}{data}{name};
            }
        }

        my $setup = sub {
            my ($pf) = @_;
            reset_all();
            $Plugins::SpotOn::API::Credentials::mock_creds = { username => $self, auth_data => 'ZGF0YQ==' };
            seed_hash('libraryV3', $HASH_OLD);
            http_rule(qr{/playlist/v2/user/.+/rootlist}, $bytes);
            http_rule(qr{pathfinder/v2/query}, $pf);
        };
        my $stats = sub {
            my ($res) = @_;
            my @it = @{ ($res && $res->{items}) || [] };
            my @foreign = grep { ($_->{owner}{id} // '') ne $self && ($_->{owner}{id} // '') ne 'spotify' } @it;
            return {
                n       => scalar(@it),
                covers  => scalar(grep { @{ $_->{images} || [] } } @it),
                own     => scalar(grep { ($_->{owner}{id} // '') eq $self && ($_->{owner}{display_name} // 'x') eq '' } @it),
                spo     => scalar(grep { ($_->{owner}{id} // '') eq 'spotify' && ($_->{owner}{display_name} // '') eq 'Spotify' } @it),
                foreign => scalar(@foreign),
                named   => scalar(grep { length($_->{owner}{display_name} // '') } @foreign),
                fromPg  => scalar(grep { defined $want{ $_->{uri} } && $_->{owner}{display_name} eq $want{ $_->{uri} } } @foreign),
                asuser  => scalar(grep { $_->{owner}{display_name} eq $_->{owner}{id} } @foreign),
            };
        };

        # success leg
        $setup->(sub {
            my ($e) = @_;
            my $off = pf_body($e)->{variables}{offset} // 0;
            return (200, $page{$off}) if $page{$off};
            return (200, $JSON->encode(k1b_empty_page($off, $total)));
        });
        my ($res) = k1b_run();
        my $s = $stats->($res);
        is($s->{n}, 97, 'k1b real: 97 playlists');
        is($s->{covers}, 97, 'k1b real: a cover on 97 of 97');
        is($s->{own}, 47, 'k1b real: an empty owner line on 47 own playlists');
        is($s->{spo}, 20, 'k1b real: Spotify on 20');
        is($s->{named}, 30, 'k1b real: 30 foreign playlists with a non-empty owner name');
        is($s->{fromPg}, 30, 'k1b real: 30 foreign playlists show the owner name of the libraryV3 page');
        is(scalar(pf_requests()), 2, 'k1b real: 2 Pathfinder requests');
        is(($SP->libraryMetaStatus() || {})->{missing}, 0, 'k1b real: the status counts 0 playlists missing a cover or an owner name');

        # forced 400 leg
        $setup->(sub { return (400, '{"errors":[]}') });
        my ($res4) = k1b_run();
        my $s4 = $stats->($res4);
        is($s4->{covers}, 59, 'k1b real: with a 400 the rootlist covers remain (59 of 97)');
        is($s4->{asuser}, 30, 'k1b real: with a 400 the 30 foreign playlists show the user name');
        is(scalar(pf_requests()), 1, 'k1b real: with a 400 exactly one Pathfinder request');
        my $m = $SP->libraryMetaStatus() || {};
        is(join(',', $m->{state} // '?', $m->{reason} // '?'), 'fallback,HTTP 400', 'k1b real: with a 400 the status is fallback, reason HTTP 400');
    });
}

# ============================================================
# 261110-nu9 (Fable review of the beta.8 range): W1 an incomplete build keeps its
# list for 60 s, W2 no Pathfinder lookup starts after the budget or a 429 stop.
# ============================================================
sub nu9_all_reqs { return scalar grep { $_->{url} !~ /apresolve/ } @Slim::Networking::SimpleAsyncHTTP::requests; }

t_block('nu9 MFY short list cache and no lookup after the stop', sub {
    is(is9_const('MFY_LIST_PARTIAL_TTL'), 60, 'nu9 W1: MFY_LIST_PARTIAL_TTL is 60');

    # --- W1 complete build: unchanged 300 s ---
    my $W0 = '37i9dQZF1EQ99NU9W1Cxx01';
    is9_setup();
    is9_pv2({ $W0 => 'Complete Name' });
    is9_pf(topmix => is9_topmix(is9_mix($W0, name => '')));
    run_mfy();
    is($CK->ttl('spoton_mfy_list_acct1'), 300, 'nu9 W1 complete: a complete build with a lookup keeps its list for 300 s');

    # --- W1 budget: cached 60 s, the second opening sends no request ---
    my @B = map { sprintf('37i9dQZF1EQ99NU9BUDxx%02d', $_) } 1 .. 3;
    is9_setup();
    is9_pv2({ map { $B[$_ - 1] => "Name B$_" } 1 .. 3 });
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @B));
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{/playlist/v2/playlist/};
    my @timers;
    my ($bres, $bcalled) = (undef, 0);
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @timers, [ $_[1], $_[2] ] };
        $SP->getMadeForYou('acct1', sub { ($bres) = @_; $bcalled++ });
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 5)) <= 1.5 } @timers;
        $bt->[1]->() if $bt;
    }
    ok($bcalled == 1, 'nu9 W1 budget: the budget delivered the list');
    is($CK->ttl('spoton_mfy_list_acct1'), 60, 'nu9 W1 budget: the list of the cut-short build is cached with a TTL of 60');
    $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
    1 while Slim::Networking::SimpleAsyncHTTP::release_one();
    is9_clear_requests();
    my ($again, undef, $acalled) = run_mfy();
    ok($acalled == 1 && $again && @{ $again->{items} || [] }, 'nu9 W1 budget: a second menu opening inside the TTL is answered');
    is(nu9_all_reqs(), 0, 'nu9 W1 budget: and makes 0 new requests (no Pathfinder, no playlist/v2)');

    # --- W1 429: cached 60 s, the second opening sends no request ---
    my @L = map { sprintf('37i9dQZF1EQ99NU9RLMxx%02d', $_) } 1 .. 3;
    is9_setup();
    is9_pv2({}, code => 429);
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @L));
    run_mfy();
    is($CK->ttl('spoton_mfy_list_acct1'), 60, 'nu9 W1 ratelimit: the list of the 429-stopped build is cached with a TTL of 60');
    is9_clear_requests();
    run_mfy();
    is(nu9_all_reqs(), 0, 'nu9 W1 ratelimit: a second menu opening inside the TTL makes 0 new requests');

    # --- W2 budget: a late playlist/v2 answer without a name starts no fetchPlaylist ---
    my @D = map { sprintf('37i9dQZF1EQ99NU9LBDxx%02d', $_) } 1 .. 3;
    is9_setup();
    is9_pv2({});    # 404, no name
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @D),
        fetch => { map { $_ => { data => { playlistV2 => { __typename => 'Playlist', uri => "spotify:playlist:$_", name => "PF $_" } } } } @D });
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{/playlist/v2/playlist/};
    @timers = ();
    my ($dres, $dcalled) = (undef, 0);
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @timers, [ $_[1], $_[2] ] };
        $SP->getMadeForYou('acct1', sub { ($dres) = @_; $dcalled++ });
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 5)) <= 1.5 } @timers;
        $bt->[1]->() if $bt;
        $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
        1 while Slim::Networking::SimpleAsyncHTTP::release_one();
    }
    is($dcalled, 1, 'nu9 W2 budget: the callback fired once');
    is(scalar(is9_fetch_reqs()), 0, 'nu9 W2 budget: a late playlist/v2 answer without a name starts no Pathfinder fetchPlaylist request');

    # --- W2 ratelimit: another lookup caused the 429 stop, a nameless answer after it starts no fetchPlaylist ---
    my @E = map { sprintf('37i9dQZF1EQ99NU9LRLxx%02d', $_) } 1 .. 3;
    is9_setup();
    http_rule(qr{/playlist/v2/playlist/}, sub {
        my ($e) = @_;
        my ($id) = $e->{url} =~ m{/playlist/v2/playlist/([^/?#]+)};
        return (429, '', { 'Retry-After' => 30 }) if defined $id && $id eq $E[0];
        return (404, '');
    });
    is9_pf(topmix => is9_topmix(map { is9_mix($_, name => '') } @E),
        fetch => { map { $_ => { data => { playlistV2 => { __typename => 'Playlist', uri => "spotify:playlist:$_", name => "PF $_" } } } } @E });
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{/playlist/v2/playlist/};
    my ($eres, $ecalled) = (undef, 0);
    $SP->getMadeForYou('acct1', sub { ($eres) = @_; $ecalled++ });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::held), 2, 'nu9 W2 ratelimit: two lookups are parked');
    Slim::Networking::SimpleAsyncHTTP::release_one();    # the 429 one
    Slim::Networking::SimpleAsyncHTTP::release_one();    # a 404 answer after the stop
    $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
    is($ecalled, 1, 'nu9 W2 ratelimit: the callback fired once after both answers');
    is(scalar(is9_fetch_reqs()), 0, 'nu9 W2 ratelimit: a nameless playlist/v2 answer after the 429 stop starts no Pathfinder fetchPlaylist request');
});

# ============================================================
# 261111-i1i (UR8-1): Library > Playlists answers after at most LIBV3_BUDGET (10 s); the libraryV3 chain runs on in
# the background and fills only the caches
# ============================================================
t_block('i1i budget', sub {
    # reference: the full run without any budget cut
    k1b_setup();
    my ($ref) = k1b_run();
    my $refJson = $ref ? $JSON->encode($ref->{items}) : '<no reference>';

    my $fx = k1b_setup();
    my ($pg, $off) = k1b_pages($fx);
    my $cl0 = scalar grep { !k1b_has_cover($_) && ($off->{ $_->{uri} } // -1) == 0 } @{ $fx->{rootlist} };
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
    my $LK = 'spoton_spclient_libpl_acct1';
    my $open = sub {
        my $r = { n => 0 };
        $SP->getUserPlaylists('acct1', { limit => 500 }, sub { ($r->{res}, $r->{err}) = @_; $r->{n}++ });
        return $r;
    };
    my $st = sub { return $SP->libraryMetaStatus() };

    my @timers;
    my ($o1, $o2);
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @timers, [ $_[1], $_[2] ] };
        $o1 = $open->();
        Slim::Networking::SimpleAsyncHTTP::release_one();    # page 0 answers, page 50 is requested and parked
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 10)) <= 1.5 } @timers;
        my @offs = map { pf_body($_)->{variables}{offset} // '?' } pf_requests();
        ok($bt && !$o1->{n} && scalar(@Slim::Networking::SimpleAsyncHTTP::held) == 1 && join(',', @offs) eq '0,50',
            'i1i budget: a timer 10 s ahead was set and the callback has not fired while page 50 is parked');

        # the budget runs out
        $bt->[1]->() if $bt;
        my $res = $o1->{res};
        ok($o1->{n} == 1 && $res && $res->{total} == 97, 'i1i budget: the timer delivers the list once with all 97 playlists');
        is($res ? k1b_stats($res)->{covers} : -1, 59 + $cl0, 'i1i budget: the page 0 playlists show their cover, the others stay without one');
        my @fo = grep { k1b_foreign($fx->{rootlist}[$_]) && ($off->{ $fx->{rootlist}[$_]{uri} } // -1) != 0 } 0 .. $#{ $fx->{rootlist} };
        ok($res && @fo && !(grep { ($res->{items}[$_]{owner}{display_name} // '') ne $fx->{rootlist}[$_]{owner} } @fo),
            'i1i budget: foreign playlists not on page 0 keep the user name');
        my $late = grep { ($off->{ $_->{uri} } // -1) != 0 && defined $CK->get(k1b_rev_key($_)) } @{ $fx->{rootlist} };
        ok(!$late && !defined $CK->get('spoton_libv3_off_acct1'),
            'i1i budget: no playlist entry for a playlist not seen yet and no off key');
        is($CK->ttl($LK), 60, 'i1i budget: the delivered list is cached for 60 s');
        is(($st->() || {})->{state}, 'unknown', 'i1i budget: the status is not written before the background chain ends');

        # a second open inside 60 s: from the list cache
        my $p0 = scalar(pf_requests());
        $o2 = $open->();
        ok($o2->{n} == 1 && $o2->{res} && $o2->{res}{total} == 97 && scalar(pf_requests()) == $p0,
            'i1i budget: a second open inside 60 s is answered at once without a libraryV3 request');

        # the late answer of page 50
        $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
        my $g = 0;
        while (Slim::Networking::SimpleAsyncHTTP::release_one()) { last if ++$g > 30 }
        ok($o1->{n} == 1 && $o2->{n} == 1, 'i1i budget: the late page 50 answer calls no callback again');
        is($res ? k1b_stats($res)->{covers} : -1, 59 + $cl0, 'i1i budget: the late answer does not change the list that was delivered');
        my @cl = grep { !k1b_has_cover($_) && exists $off->{ $_->{uri} } } @{ $fx->{rootlist} };
        ok(@cl && !(grep { my $m = $CK->get(k1b_rev_key($_)); !(ref $m eq 'HASH' && @{ $m->{images} || [] } >= 1) } @cl)
                && !defined $CK->get('spoton_libv3_off_acct1'),
            'i1i budget: the late answer fills the playlist cache and sets no off key');
        ok(!defined $CK->get($LK), 'i1i budget: the chain end drops the delivered list from the cache');
        my $sb = $st->() || {};
        is(join(',', $sb->{state} // '?', $sb->{missing} // '?'), 'ok,0', 'i1i budget: the status is written at the chain end (ok, 0 missing)');
        is($Slim::Networking::SimpleAsyncHTTP::max_inflight, 1, 'i1i budget: the background chain stays serial (never more than 1 libraryV3 request open)');

        # the next open: everything from the caches
        my $before = k1b_all_reqs();
        my ($r16, undef, $n16) = k1b_run();
        ok($n16 == 1 && k1b_stats($r16)->{covers} == 97 && k1b_all_reqs() == $before,
            'i1i budget: the next open shows all 97 covers without a request');
        ok($r16 && $JSON->encode($r16->{items}) eq $refJson, 'i1i budget: the next open shows the same list as a run without the budget');
    }

    # the 60 s ran out while the chain still runs: the open joins it and is answered with the delivered list
    # (own scenario since 261111-j57: the main scenario above no longer removes the list key by hand, so its chain-end
    # assertions can only pass through the removal in SpClient)
    k1b_setup();
    $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
    {
        no warnings 'redefine';
        my @t3;
        local *Slim::Utils::Timers::setTimer = sub { push @t3, [ $_[1], $_[2] ] };
        my $j1 = $open->();
        Slim::Networking::SimpleAsyncHTTP::release_one();    # page 0 answers, page 50 is requested and parked
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 10)) <= 1.5 } @t3;
        $bt->[1]->() if $bt;                                  # the budget runs out: the list is delivered
        # this simulates the 60 s expiry of the delivered list; nothing after it depends on the key's absence
        $CK->remove($LK);
        my ($rl0, $p1) = (scalar(k1b_rl_reqs()), scalar(pf_requests()));
        my $j3 = $open->();
        ok($bt && $j3->{n} == 1 && $j3->{res} && $j3->{res}{total} == 97 && scalar(pf_requests()) == $p1 && scalar(k1b_rl_reqs()) == $rl0,
            'i1i budget: an open after the list cache expired joins the running chain: answered at once, 0 new libraryV3 requests');
        $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
        my $g = 0;
        while (Slim::Networking::SimpleAsyncHTTP::release_one()) { last if ++$g > 30 }
        ok($j1->{n} == 1 && $j3->{n} == 1, 'j57 harden: the late answer calls neither the first nor the joined open a second time');
    }

    # one-shot guard: the chain ends inside the budget, the timer fires afterwards
    k1b_setup();
    my @t2;
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @t2, [ $_[1], $_[2] ] };
        my $o = $open->();
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 10)) <= 1.5 } @t2;
        my $p0 = scalar(pf_requests());
        $bt->[1]->() if $bt;
        ok($bt && $o->{n} == 1 && defined $CK->get($LK) && ($st->() || {})->{state} eq 'ok' && scalar(pf_requests()) == $p0,
            'i1i budget: a timer that fires after the chain ended changes nothing');
    }

    # 261111-j57: the same timer fires with counting wrappers around the cache: a watcher without its $done check would
    # apply and write again (the first assertion above cannot see that: the list key is written once either way)
    k1b_setup();
    my @t4;
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @t4, [ $_[1], $_[2] ] };
        my $o = $open->();
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 10)) <= 1.5 } @t4;
        my ($sets, $rems) = (0, 0);
        {
            my $os = \&Slim::Utils::Cache::set;
            my $or = \&Slim::Utils::Cache::remove;
            local *Slim::Utils::Cache::set    = sub { $sets++; goto &$os };
            local *Slim::Utils::Cache::remove = sub { $rems++; goto &$or };
            $bt->[1]->() if $bt;
        }
        ok($bt && $o->{n} == 1 && $sets == 0 && $rems == 0,
            'j57 harden: a timer that fires after the chain ended writes nothing to the cache (0 set, 0 remove)');
    }

    # 261111-j57: a libraryV3 call that answers at once (Pathfinder's local 429 short circuit does that) and then dies
    # lands in the unless ($ok) branch of the page step, which ends the run a second time; the one-shot guard of the
    # chain end keeps that second end from recording a fallback over the finished ok run
    k1b_setup();
    {
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { };
        local *Plugins::SpotOn::API::Pathfinder::libraryPlaylists = sub {
            my $cb = $_[3];
            $cb->({ items => [], total => 0, rawCount => 0 }, undef);
            die "j57 test: libraryV3 died after answering\n";
        };
        my $o = $open->();
        my $sh = $st->() || {};
        ok($o->{n} == 1 && ($sh->{state} // '') eq 'ok',
            'j57 harden: a libraryV3 call that answers at once and then dies ends the run once (one callback, status stays ok)');
    }
});

# ============================================================
# 261111-j57 (W2): a background chain that ends with a failure keeps the delivered list, so the next open inside its 60 s
# is answered at once instead of starting a new chain that waits for the budget again
# ============================================================
for my $case ([503, {}], [429, { 'Retry-After' => 30 }]) {
    my ($code, $hdrs) = @$case;
    t_block("j57 bgfail $code", sub {
        k1b_setup();
        my $LK = 'spoton_spclient_libpl_acct1';
        $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
        my $open = sub {
            my $r = { n => 0 };
            $SP->getUserPlaylists('acct1', { limit => 500 }, sub { ($r->{res}, $r->{err}) = @_; $r->{n}++ });
            return $r;
        };
        my @timers;
        no warnings 'redefine';
        local *Slim::Utils::Timers::setTimer = sub { push @timers, [ $_[1], $_[2] ] };
        my $o1 = $open->();
        Slim::Networking::SimpleAsyncHTTP::release_one();    # page 0 answers, page 50 is requested and parked
        my ($bt) = grep { ref $_->[1] eq 'CODE' && abs($_->[0] - (time() + 10)) <= 1.5 } @timers;
        $bt->[1]->() if $bt;                                  # the budget runs out: the list is delivered
        # the background chain now fails
        http_rule(qr{pathfinder/v2/query}, sub { return ($code, '', $hdrs) });
        $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
        my $g = 0;
        while (Slim::Networking::SimpleAsyncHTTP::release_one()) { last if ++$g > 30 }
        ok(defined $CK->get($LK), "j57 bgfail $code: the failed background chain keeps the delivered list in the cache");
        my $st = $SP->libraryMetaStatus() || {};
        is(join(',', $st->{state} // '?', $st->{reason} // '?'), "fallback,HTTP $code", "j57 bgfail $code: the status reads fallback (HTTP $code)");

        # the next open inside the 60 s: from the delivered list, no libraryV3 call, no rootlist request
        $Slim::Networking::SimpleAsyncHTTP::hold_re = qr{pathfinder/v2/query};
        my $orig  = \&Plugins::SpotOn::API::Pathfinder::libraryPlaylists;
        my $calls = 0;
        local *Plugins::SpotOn::API::Pathfinder::libraryPlaylists = sub { $calls++; goto &$orig };
        my $rl0 = scalar(k1b_rl_reqs());
        my $o2  = $open->();
        ok($o2->{n} == 1 && $o2->{res} && $o2->{res}{total} == 97 && $calls == 0 && scalar(k1b_rl_reqs()) == $rl0,
            "j57 bgfail $code: the next open is answered at once from the delivered list (0 libraryV3 calls, 0 rootlist requests)");
        $Slim::Networking::SimpleAsyncHTTP::hold_re = undef;
        $g = 0;
        while (Slim::Networking::SimpleAsyncHTTP::release_one()) { last if ++$g > 30 }
    });
}

done_testing();
