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
    if (defined $a{name}) {
        $b .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $a{name}));
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
    http_rule(qr{pathfinder/v2/query}, pf_fixture_responder());

    my ($res, $err, $called) = run_mfy();
    my @pf = pf_requests();
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

done_testing();
