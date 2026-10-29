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
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Soloist/Quality.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Soloist/Quality.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

my $stub_dir = tempdir(CLEANUP => 1);

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
# LMS Module Stubs (t/26/t/36 patterns)
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Slim::Utils::Log -- collects every logged line so tests can assert no
# line ever contains the bearer token (T-83.3-06).
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @logged = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @logged, $_[1] if defined $_[1]; }
sub warn  { push @logged, $_[1] if defined $_[1]; }
sub error { push @logged, $_[1] if defined $_[1]; }
sub debug { push @logged, $_[1] if defined $_[1]; }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs -- global + per-client() namespaced store. Keys
# per-client by the PLAYER ID ($client->id, the MAC), exactly like the real
# Slim::Utils::Prefs::Namespace::client (Namespace.pm:220) -- never by the
# stringified ref. A ref string is a memory address, and Perl hands the
# address of a MockClient freed at a subtest boundary to the next one
# blessed; keyed by address, that fresh player inherited an earlier case's
# soloistQualityInitialised=1/soloistQualityPending=0 and onDaemonReady
# returned early (debug ci-quality-case11-flake: CI red twice on Case 11,
# locally ~1 % per run on Cases 14/17). reset_store() wipes every namespace;
# reset_all() calls it so nothing survives a subtest boundary either way.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
my %_store;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences {
    my $ns = ($_[0] eq 'Slim::Utils::Prefs') ? $_[1] : $_[0];
    return bless { _ns => $ns }, 'Slim::Utils::Prefs';
}
sub get { my ($self, $key) = @_; return $_store{$self->{_ns}}{$key}; }
sub set { my ($self, $key, $val) = @_; $_store{$self->{_ns}}{$key} = $val; }
sub client {
    my ($self, $client) = @_;
    my $id = ref $client ? $client->id : ($client // 'default');
    return bless { _ns => $self->{_ns} . '_client_' . $id }, 'Slim::Utils::Prefs';
}
sub reset_store { %_store = (); }
sub setChange { }
sub AUTOLOAD { }
1;
END

# Stub: Slim::Utils::Cache -- stateful (t/33 pattern).
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

# Stub: Slim::Utils::Timers -- setTimer runs the callback immediately
# (synchronous test execution, no event loop).
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer {
    my ($obj, $time, $cb, @args) = @_;
    $cb->(@args);
}
sub killTimers { }
1;
END

write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: Slim::Utils::Strings -- Backend::Soloist::qualityInfo renders labels
# through it (74b-02 wanted cell); the key itself is the rendered text.
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub string { return "S:" . ($_[0] // '') }
1;
END

# Stub: Slim::Player::Client -- registry populated by MockClient->new below.
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our %clients;   # mac => client object
sub getClient { my ($mac) = @_; return $clients{$mac || ''}; }
sub clients   { return values %clients; }
1;
END

# Stub: Plugins::SpotOn::API::Login5 -- controllable getToken (t/36 pattern).
write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
our $mock_token = 'mock-login5-bearer-token-should-never-be-logged';
our $mock_fail_reason;
our $mock_fail_detail;
our @getToken_calls = ();
sub getToken {
    my ($class, $accountId, $cb) = @_;
    push @getToken_calls, $accountId;
    if ($mock_fail_reason) {
        $cb->(undef, $mock_fail_reason, $mock_fail_detail);
        return;
    }
    $cb->($mock_token, undef);
}
sub reset_calls { @getToken_calls = () }
1;
END

# Stub: Plugins::SpotOn::Soloist -- dataDirForClient returns a per-mac
# tempdir the test writes .device_id into.
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
use File::Temp qw(tempdir);
our %datadirs;
sub dataDirForClient {
    my ($mac) = @_;
    (my $clean = $mac || '') =~ s/://g;
    $datadirs{$clean} ||= tempdir(CLEANUP => 1);
    return $datadirs{$clean};
}
1;
END

# Stub: Plugins::SpotOn::Unified::DaemonManager -- deviceNameForClient.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
sub deviceNameForClient {
    my ($class, $client) = @_;
    return $client->name;
}
1;
END

# Stub: HTTP::Headers / HTTP::Response -- the SimpleAsyncHTTP stub below
# builds its trailer headers and its error response from them. They are LWP
# modules, not core Perl: locally they resolved from the system LMS/distro in
# /usr/share/perl5, on CI (cpanm installs only Crypt::OpenSSL::Random,
# HTTP::Date, URI) they do not exist (84-10 CI follow-up). Only the surface
# Quality.pm touches: Headers->new(k => v, ...) + ->header($name), matched
# case-insensitively like the real module; Response->new($code) + ->code.
write_stub($stub_dir, 'HTTP::Headers', <<'END');
package HTTP::Headers;
sub new {
    my ($class, @kv) = @_;
    my %h;
    while (@kv) { my ($k, $v) = splice(@kv, 0, 2); $h{lc $k} = $v; }
    return bless { h => \%h }, $class;
}
sub header { return $_[0]->{h}->{lc $_[1]} }
1;
END

write_stub($stub_dir, 'HTTP::Response', <<'END');
package HTTP::Response;
sub new  { my ($class, $code) = @_; return bless { code => $code }, $class }
sub code { $_[0]->{code} }
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP -- per-RPC (Write vs Read)
# controllable success/error responses. Mirrors the REAL onBody/onError
# contract (SimpleAsyncHTTP.pm:103-139): the success callback receives the
# SimpleAsyncHTTP instance itself (onBody:134 `$self->cb->( $self )`), with
# code/mess/headers copied onto it from the inner response (onBody:113-115);
# there is no separate ->response object and no ->response accessor on it.
# Both callback invocations run inside eval, mirroring the Select loop's own
# eval around every callback (Select.pm:118-131) -- a callback that dies
# shows up here as $last_callback_error, exactly like it shows up as a
# swallowed die in server.log on the real system.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
use HTTP::Headers;
use HTTP::Response;

our @requests = ();
our $last_callback_error;

our $write_mode         = 'success';   # success | error
our $write_grpc_status  = 0;
our $write_grpc_message = '';
our $write_content      = '';
our $write_error        = '';

our $read_mode          = 'success';
our $read_grpc_status   = 0;
our $read_grpc_message  = '';
our $read_content       = '';
our $read_error         = '';

sub new {
    my ($class, $successCb, $errorCb, $opts) = @_;
    return bless { success_cb => $successCb, error_cb => $errorCb, opts => $opts || {} }, $class;
}

sub post {
    my ($self, $url, @rest) = @_;
    my $body;
    if (@rest % 2 == 1) { $body = pop @rest; }
    my %headers = @rest;
    push @requests, { url => $url, headers => \%headers, body => $body };

    my $isWrite = ($url =~ m{/WriteDeviceValue$}) ? 1 : 0;
    my $mode    = $isWrite ? $write_mode : $read_mode;

    # 79-43 Q3: a transport-layer die (HTTP::Message "content must be bytes") escapes post() like the real one
    die "HTTP::Message content must be bytes at /stub/HTTP/Message.pm line 1\n" if $mode eq 'die';

    $last_callback_error = undef;

    if ($mode eq 'success') {
        $self->{_code}    = 200;
        $self->{_mess}    = 'OK';
        $self->{_url}     = $url;
        $self->{_content} = $isWrite ? $write_content : $read_content;
        $self->{_headers} = HTTP::Headers->new(
            'grpc-status'  => ($isWrite ? $write_grpc_status  : $read_grpc_status),
            'grpc-message' => ($isWrite ? $write_grpc_message : $read_grpc_message),
        );
        eval { $self->{success_cb}->($self); 1 } or $last_callback_error = $@;
    }
    else {
        my $err = $isWrite ? $write_error : $read_error;
        eval { $self->{error_cb}->($self, $err, HTTP::Response->new(0)); 1 } or $last_callback_error = $@;
    }
    return;
}

sub code       { $_[0]->{_code} }
sub content    { $_[0]->{_content} }
sub contentRef { my $c = $_[0]->{_content}; return \$c; }
sub mess       { $_[0]->{_mess} // 'OK' }
sub url        { $_[0]->{_url} }
sub headers    { $_[0]->{_headers} }

sub reset_stub {
    @requests = ();
    $last_callback_error = undef;
    $write_mode = 'success'; $write_grpc_status = 0; $write_grpc_message = ''; $write_content = ''; $write_error = '';
    $read_mode  = 'success'; $read_grpc_status  = 0; $read_grpc_message  = ''; $read_content  = ''; $read_error  = '';
}
1;
END

# Plugin.pm's cache-version constant (single source of truth in production;
# Plugin.pm is always compiled first there -- Quality.pm is runtime-required).
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 1 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

# IN-04: Slim::Networking::SimpleAsyncHTTP's `our $last_callback_error` /
# `our $read_error` are declared inside the stub package above (write_stub,
# compiled at BEGIN-time via `eval`/`require`-equivalent load), but this file
# also mentions those same fully-qualified globals directly (e.g.
# $Slim::Networking::SimpleAsyncHTTP::last_callback_error in assert_cb_ok()
# below, $Slim::Networking::SimpleAsyncHTTP::read_error in Case 15). Because
# the stub's `our` declaration and this file's direct mention are compiled in
# different compilation units, `prove` sees each global mentioned only once
# per unit and warns "used only once" -- a second, compile-time mention here
# is what silences the warning without a blanket `no warnings 'once'` (which
# would also hide a real typo'd global name).
{
    package Slim::Networking::SimpleAsyncHTTP;
    our ($last_callback_error, $read_error);
}

# Force-load the controllable stubs up front (Quality.pm runtime-requires
# them only when a code path is actually hit).
require_ok('Plugins::SpotOn::API::Login5')                   or BAIL_OUT('Failed to load Login5 stub');
require_ok('Plugins::SpotOn::Soloist')                        or BAIL_OUT('Failed to load Soloist stub');
require_ok('Plugins::SpotOn::Unified::DaemonManager')         or BAIL_OUT('Failed to load DaemonManager stub');
require_ok('Slim::Player::Client')                            or BAIL_OUT('Failed to load Slim::Player::Client stub');
require_ok('Plugins::SpotOn::API::ProtobufLite')              or BAIL_OUT('Failed to load the REAL ProtobufLite.pm');

require_ok('Plugins::SpotOn::Soloist::Quality') or BAIL_OUT('Failed to load Quality.pm');

my $Q = 'Plugins::SpotOn::Soloist::Quality';

# f($field, $wire, $data) -- plain-function wrapper (spike probe.pl idiom):
# ProtobufLite's encode_field is NOT a method (no leading class arg), so an
# arrow call would shift every argument by one and silently corrupt the
# encoding -- always call it as a plain function.
sub f { return Plugins::SpotOn::API::ProtobufLite::encode_field(@_); }

# ============================================================
# Test fixtures
# ============================================================

package MockClient;
sub new {
    my ($class, $mac, $name) = @_;
    my $self = bless { mac => $mac, name => $name // $mac }, $class;
    $Slim::Player::Client::clients{$mac} = $self;
    return $self;
}
sub id   { $_[0]->{mac} }
sub name { $_[0]->{name} }
1;

package main;

my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

# assert_cb_ok($testname) -- proves the success/error callback the stub just
# invoked ran to completion without dying, mirroring the Select loop's own
# eval around every SimpleAsyncHTTP callback (Select.pm:118-131). Against the
# unfixed Quality.pm this is the assertion that turns the live "Can't locate
# object method \"response\"" die into a quotable `not ok` line instead of an
# uncaught script-level crash.
sub assert_cb_ok {
    my ($testname) = @_;
    is($Slim::Networking::SimpleAsyncHTTP::last_callback_error, undef,
        "$testname: success callback completed (Select-loop eval mirror)");
}

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    Slim::Utils::Prefs::reset_store();      # no per-client namespace survives a case boundary
    Slim::Utils::Cache->new()->clear();
    Plugins::SpotOn::API::Login5::reset_calls();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
    $Plugins::SpotOn::API::Login5::mock_fail_detail = undef;
    $Plugins::SpotOn::API::Login5::mock_token ='mock-login5-bearer-token-should-never-be-logged';
    @Slim::Utils::Log::logged = ();
    %Slim::Player::Client::clients = ();
    $prefs->set('backend', 'soloist');
    $prefs->set('soloistQuality', 0);
}

# WINDOWS #30 (W30): the real 64-byte GetDeviceSettings response captured
# against lavender-UAT's real device via the independent read-only probe.pl
# query (~/SynologyDrive/dev/spoton-messdaten/83.3-14-live-260927-1116/probe-read-post-hoc.txt).
# Its settings sub-message (top-level field 2) is the 6-byte tail
# "1206100160016801" = field 2 varint 1, field 12 varint 1, field 13 varint 1
# -- field 1 (the level) is ABSENT because the device's effective level is 0
# (Automatic), proto3's default-value-omission signature.
my $REAL_READ_AUTOMATIC_HEX = '0a360a340a2437633933353962392d653637362d346339362d616233642d366130663332326633306261120c6c6176656e6465722d5541541206100160016801';

# build_content($level) -- the same GetDeviceSettings response shape a real
# spclient answer decodes to (RESEARCH Code Examples): 1:{1:{1:id,2:name}}
# 2:{1:level,2:1,12:1,13:1} -- only the fields _decodeLevel reads are needed.
# W30: a real proto3 server never serialises field 1 when $level is its
# default (0) -- omit it here too, so Case 8's onDaemonReady(global=0) flow
# exercises the real default-case wire shape instead of an explicit "1 0 = 0"
# encoding no live server would ever send.
sub build_content {
    my ($level) = @_;
    my $settingsMsg = ($level ? f(1, 0, $level) : '') . f(2, 0, 1);
    my $descriptor = f(1, 2, 'dev-id') . f(2, 2, 'dev-name');
    my $devicesMsg = f(1, 2, $descriptor);
    return f(1, 2, $devicesMsg) . f(2, 2, $settingsMsg);
}

sub write_device_id {
    my ($mac, $uuid) = @_;
    $uuid //= '7c9359b9-e676-4c96-ab3d-6a0f322f30ba';
    my $dir = Plugins::SpotOn::Soloist::dataDirForClient($mac);
    open(my $fh, '>', "$dir/.device_id") or die "Cannot write .device_id: $!";
    print $fh "$uuid\n";
    close($fh);
    return $uuid;
}

# ============================================================
# Case 0 (debug ci-quality-case11-flake): the Prefs stub's per-client
# namespace follows the PLAYER ID, never the object's address, and
# reset_all() wipes it. Before this fix the key was the stringified ref;
# Perl recycles a freed MockClient's address for the next one blessed, so a
# fresh player inherited an earlier case's soloistQualityInitialised=1 and
# onDaemonReady returned early (CI: Case 11 twice; locally Cases 14/17).
# ============================================================
subtest 'Case 0: per-client prefs are keyed by player id and wiped by reset_all' => sub {
    reset_all();

    # (a) identity: two live objects for the same MAC share one namespace, a
    # different MAC does not -- a stub keyed by "$client" fails this.
    my $a = MockClient->new('00:AA:00:00:00:01', 'player-0a');
    my $b = bless { mac => '00:AA:00:00:00:01', name => 'player-0b' }, 'MockClient';
    my $c = MockClient->new('00:AA:00:00:00:02', 'player-0c');
    isnt("$a", "$b", 'precondition: two distinct live objects for the same MAC');
    $prefs->client($a)->set('soloistQualityInitialised', 1);
    is($prefs->client($b)->get('soloistQualityInitialised'), 1,
        'same MAC, other object -> same namespace (keyed by ->id like Namespace.pm:220)');
    ok(!$prefs->client($c)->get('soloistQualityInitialised'), 'other MAC -> other namespace');

    # (b) the live defect shape: a player whose first daemon start succeeded
    # is freed (as every case boundary frees the previous case's client), its
    # address is recycled for a NEW player, and that player's UNREACHABLE
    # first start must still end pending -- never pre-initialised.
    my $mac_old = '00:AA:00:00:00:03';
    my $mac_new = '00:AA:00:00:00:04';
    write_device_id($mac_old);
    write_device_id($mac_new);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(0);
    my $addr_old;
    {
        my $old = MockClient->new($mac_old, 'player-0-old');
        $Q->onDaemonReady($mac_old);
        assert_cb_ok('Case 0 (old player, verified first start)');
        is($prefs->client($old)->get('soloistQualityInitialised'), 1, 'old player is initialised');
        $addr_old = "$old";
        delete $Slim::Player::Client::clients{$mac_old};
    }
    my $new = MockClient->new($mac_new, 'player-0-new');
    SKIP: {
        skip "allocator did not recycle the old player's address ($addr_old) for the new one ($new); inheritance path not exercised in this run", 4
            unless "$new" eq $addr_old;
        pass('precondition: the new player sits on the old player\'s recycled address');
        $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
        $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
        $Q->onDaemonReady($mac_new);
        assert_cb_ok('Case 0 (new player, unreachable first start)');
        ok(!$prefs->client($new)->get('soloistQualityInitialised'),
            'recycled address: the new player does NOT inherit soloistQualityInitialised');
        is($prefs->client($new)->get('soloistQualityPending'), 1,
            'recycled address: the new player ends pending (its write never reached the server)');
    }

    # (c) reset_all() wipes every per-client namespace -- a reset_all without
    # reset_store() fails this.
    reset_all();
    ok(!defined $prefs->client($a)->get('soloistQualityInitialised'), 'reset_all wipes per-client prefs');
};

# ============================================================
# Case 1: wire encoders match the spike's exact bytes
# ============================================================
subtest 'Case 1: _encodeWrite/_encodeRead match the spike wire format' => sub {
    reset_all();

    my $id    = '7c9359b9-e676-4c96-ab3d-6a0f322f30ba';
    my $name  = 'lavender-UAT';
    my $level = 5;

    my $descriptor = f(1, 2, $id) . f(2, 2, $name);
    my $expectedWrite = f(1, 2, $descriptor)
        . f(2, 2, f(1, 0, 1) . f(2, 2, f(3, 0, $level)));

    my $actualWrite = $Q->_encodeWrite($id, $name, $level);
    is($actualWrite, $expectedWrite, '_encodeWrite matches the spike-equivalent expression built with the real ProtobufLite');
    is(substr($actualWrite, 0, 1), chr(0x0a), '_encodeWrite starts with tag byte 0x0a (field 1, wire 2)');

    my $expectedRead = f(1, 2, f(1, 2, $descriptor));
    is($Q->_encodeRead($id, $name), $expectedRead, '_encodeRead matches f(1,2,f(1,2,descriptor))');
};

# ============================================================
# Case 2: _decodeLevel
# ============================================================
subtest 'Case 2: _decodeLevel' => sub {
    my $inner = f(1, 0, 6) . f(2, 0, 1);
    my $content = f(1, 2, 'x') . f(2, 2, $inner);
    is($Q->_decodeLevel($content), 6, '_decodeLevel extracts field 1 of the embedded field-2 message');

    is($Q->_decodeLevel("\xff\xff\xff"), undef, '_decodeLevel returns undef for garbage bytes');
};

# ============================================================
# Case 3: write() posts to WriteDeviceValue with the right headers, and no
# log line ever contains the token (T-83.3-06).
# ============================================================
subtest 'Case 3: write() request shape + token never logged' => sub {
    reset_all();
    my $mac = '00:AA:03:00:00:01';
    write_device_id($mac);
    MockClient->new($mac, 'player-3');

    $Slim::Networking::SimpleAsyncHTTP::write_content = '';
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 0;

    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 3');

    ok($ok, 'write() succeeds');
    my $req = $Slim::Networking::SimpleAsyncHTTP::requests[-1];
    like($req->{url}, qr{/WriteDeviceValue$}, 'posts to a URL ending /WriteDeviceValue');
    like($req->{headers}{Authorization}, qr{^Bearer }, 'Authorization header starts with "Bearer "');
    is($req->{headers}{'Content-Type'}, 'application/x-protobuf', 'Content-Type is application/x-protobuf');

    my $token = $Plugins::SpotOn::API::Login5::mock_token;
    ok(!(grep { index($_, $token) >= 0 } @Slim::Utils::Log::logged),
        'no collected log line contains the bearer token');
};

# ============================================================
# Case 4: grpc-status != 0 on a 200 response -> rejected
# ============================================================
subtest 'Case 4: grpc-status 7 on HTTP 200 classifies as rejected' => sub {
    reset_all();
    my $mac = '00:AA:04:00:00:01';
    write_device_id($mac);
    MockClient->new($mac, 'player-4');

    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;

    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 4');

    ok(!$ok, 'write() fails when grpc-status is non-zero');
    is($err->{class}, 'rejected', 'error class is rejected');
    is($err->{grpc}, 7, 'grpc status is captured');
};

# ============================================================
# Case 5: error classification -- HTTP code vs. no code vs. login5 mint failure
# ============================================================
subtest 'Case 5: error classification (rejected/unreachable/no_token)' => sub {
    reset_all();
    my $mac = '00:AA:05:00:00:01';
    write_device_id($mac);
    MockClient->new($mac, 'player-5');

    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = '503 Service Unavailable';
    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 5 (503)');
    is($err->{class}, 'unreachable', '503 Service Unavailable classifies as unreachable (transient), not rejected');
    is($err->{http}, 503, 'HTTP code 503 is still captured for the log/notice even though the class changed');

    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
    ($ok, $err) = (undef, undef);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 5 (connection refused)');
    is($err->{class}, 'unreachable', 'no HTTP code in the error string classifies as unreachable');

    $Slim::Networking::SimpleAsyncHTTP::write_mode = 'success';
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    ($ok, $err) = (undef, undef);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 5 (no_token, no post reached)');
    is($err->{class}, 'no_token', 'a login5 mint failure classifies as no_token');
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
};

# ============================================================
# Case 6: applyChange(global) rejected -> pref reset to the read-back value
# ============================================================
subtest 'Case 6: applyChange(global, 5) rejected -> pref corrected to read-back 3' => sub {
    reset_all();
    my $mac = '00:AA:06:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-6');
    $prefs->set('soloistQuality', 0);

    $Slim::Networking::SimpleAsyncHTTP::write_content = '';
    $Slim::Networking::SimpleAsyncHTTP::read_content   = build_content(3);

    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('Case 6');

    is($prefs->get('soloistQuality'), 3, 'global pref corrected to the read-back effective value (3)');
    my $notice = $Q->noticeFor($mac);
    is($notice->{kind}, 'rejected', 'notice kind is rejected');
    is($notice->{wanted}, 5, 'notice records the wanted level (5)');
    is($notice->{effective}, 3, 'notice records the effective level (3)');
};

# ============================================================
# Case 7: applyChange(global) unreachable -> pref kept, pending set
# ============================================================
subtest 'Case 7: applyChange(global, 5) unreachable -> pref kept, pending set' => sub {
    reset_all();
    my $mac = '00:AA:07:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-7');
    $prefs->set('soloistQuality', 5);

    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';

    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('Case 7');

    is($prefs->get('soloistQuality'), 5, 'global pref stays at 5 (unreachable never corrects)');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'client soloistQualityPending is set');
    my $notice = $Q->noticeFor($mac);
    is($notice->{kind}, 'unreachable', 'notice kind is unreachable');
};

# ============================================================
# Case 8: onDaemonReady -- D-13 first start, D-12 no repeat, pending retries
# ============================================================
subtest 'Case 8: onDaemonReady writes once, never again, unless pending' => sub {
    reset_all();
    my $mac = '00:AA:08:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-8');
    $prefs->set('soloistQuality', 0);

    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(0);

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 8 (first start)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 2, 'first onDaemonReady posts exactly once (write + read-back)');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1, 'soloistQualityInitialised is set after first start');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(0);
    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 8 (second start, no-op)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a second onDaemonReady posts nothing (D-12)');

    $prefs->client($client)->set('soloistQualityPending', 1);
    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 8 (pending retry)');
    ok(scalar(@Slim::Networking::SimpleAsyncHTTP::requests) > 0, 'onDaemonReady posts again once pending is set');
};

# ============================================================
# Case 9: effectiveLevelForClient precedence
# ============================================================
subtest 'Case 9: effectiveLevelForClient precedence' => sub {
    reset_all();
    my $mac = '00:AA:09:00:00:01';
    my $client = MockClient->new($mac, 'player-9');

    $prefs->set('soloistQuality', 5);
    $prefs->client($client)->set('soloistQuality', 4);
    is($Q->effectiveLevelForClient($client), 4, 'client override (4) beats global (5)');

    $prefs->client($client)->set('soloistQuality', 'global');
    is($Q->effectiveLevelForClient($client), 5, "client 'global' sentinel yields the global value");

    $prefs->client($client)->set('soloistQuality', 6);
    is($Q->effectiveLevelForClient($client), 6, 'a stored 6 (post D-14-reset/app choice) is honoured even though never offered');
};

# ============================================================
# Case 10: missing .device_id -- no_device_id, applyChange skips silently
# ============================================================
subtest 'Case 10: missing .device_id -> no_device_id, applyChange never posts' => sub {
    reset_all();
    my $mac = '00:AA:10:00:00:01';
    # deliberately no write_device_id() call -- Soloist stub still returns a
    # (fresh, empty) tempdir, but no .device_id file exists inside it.
    my $client = MockClient->new($mac, 'player-10');
    $prefs->set('soloistQuality', 0);

    my ($level, $err);
    $Q->read($mac, sub { ($level, $err) = @_; });
    ok(!defined $level, 'read() returns no level');
    is($err->{class}, 'no_device_id', 'read() errs no_device_id');

    $Q->applyChange(scope => 'global', level => 5);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'applyChange skips a target with no device id (no POST at all)');
};

# ============================================================
# Case 11 (bonus): first-start REJECTED still marks initialised; the
# unreachable variant leaves it unset and pending.
# ============================================================
subtest 'Case 11: first-start rejected vs unreachable' => sub {
    reset_all();
    my $mac = '00:AA:11:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-11');
    $prefs->set('soloistQuality', 0);

    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 11 (rejected first start)');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1,
        'a REJECTED first start still sets soloistQualityInitialised (server answered)');
    is($prefs->get('soloistQuality'), 3, 'global pref reset to the read-back effective value (3)');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 11 (second start after rejected, no-op)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a second onDaemonReady after a rejected first start posts nothing');

    # Unreachable variant on a fresh player -- marker stays unset, pending set.
    reset_all();
    my $mac2 = '00:AA:11:00:00:02';
    write_device_id($mac2);
    my $client2 = MockClient->new($mac2, 'player-11b');
    $prefs->set('soloistQuality', 0);

    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';

    $Q->onDaemonReady($mac2);
    assert_cb_ok('Case 11 (unreachable variant)');
    ok(!$prefs->client($client2)->get('soloistQualityInitialised'),
        'an UNREACHABLE first start leaves soloistQualityInitialised unset');
    is($prefs->client($client2)->get('soloistQualityPending'), 1, 'pending is set so the next occasion retries');
};

# ============================================================
# Case 12: transient write failure (503) on first start -- keeps pref,
# sets pending, leaves initialised unset; the next daemon start retries.
# ============================================================
subtest 'Case 12: 503 on first-start write keeps pref, sets pending, retries next start' => sub {
    reset_all();
    my $mac = '00:AA:12:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-12');
    $prefs->set('soloistQuality', 5);

    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = '503 Service Unavailable';

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 12 (503 first start)');

    is($prefs->get('soloistQuality'), 5, 'global pref stays at 5 after a transient write failure');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'),
        'soloistQualityInitialised stays unset after a transient write failure');
    is($prefs->client($client)->get('soloistQualityPending'), 1,
        'soloistQualityPending is set so the next occasion retries');
    my $notice = $Q->noticeFor($mac);
    is($notice->{kind}, 'unreachable', 'notice kind is unreachable for a transient write failure');

    my @writeReqs = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    my @readReqs  = grep { $_->{url} =~ m{/GetDeviceSettings$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@writeReqs), 1, 'exactly one WriteDeviceValue request was posted');
    is(scalar(@readReqs), 0, 'zero GetDeviceSettings requests -- no read-back after a transient write failure');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 12 (pending retry succeeds)');

    my @writeReqs2 = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@writeReqs2), 1, 'exactly one new WriteDeviceValue request -- the pending retry fired');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1,
        'soloistQualityInitialised is set once the retry succeeds');
    is($prefs->client($client)->get('soloistQualityPending'), 0,
        'soloistQualityPending is cleared after the retry succeeds');
    ok(!$Q->noticeFor($mac), 'notice is cleared after the retry succeeds');
};

# ============================================================
# Case 13: HTTP classification table (transient vs semantic)
# ============================================================
subtest 'Case 13: HTTP classification table (transient vs semantic)' => sub {
    reset_all();
    my $mac = '00:AA:13:00:00:01';
    write_device_id($mac);
    MockClient->new($mac, 'player-13');

    my @unreachable_cases = (
        [ '401 Unauthorized',           401 ],
        [ '408 Request Timeout',        408 ],
        [ '429 Too Many Requests',      429 ],
        [ '500 Internal Server Error',  500 ],
        [ '502 Bad Gateway',            502 ],
        [ '503 Service Unavailable',    503 ],
        [ 'Connection refused',         undef ],
    );
    for my $case (@unreachable_cases) {
        my ($errStr, $expectHttp) = @$case;
        $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
        $Slim::Networking::SimpleAsyncHTTP::write_error = $errStr;
        my ($ok, $err);
        $Q->write($mac, 5, sub { ($ok, $err) = @_; });
        assert_cb_ok("Case 13 ('$errStr')");
        is($err->{class}, 'unreachable', "'$errStr' classifies as unreachable");
        is($err->{http}, $expectHttp, "'$errStr': http code is " . (defined $expectHttp ? $expectHttp : 'undef'));
    }

    my @rejected_cases = (
        [ '400 Bad Request',          400 ],
        [ '403 Forbidden',            403 ],
        [ '404 Not Found',            404 ],
        [ '412 Precondition Failed',  412 ],
    );
    for my $case (@rejected_cases) {
        my ($errStr, $expectHttp) = @$case;
        $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
        $Slim::Networking::SimpleAsyncHTTP::write_error = $errStr;
        my ($ok, $err);
        $Q->write($mac, 5, sub { ($ok, $err) = @_; });
        assert_cb_ok("Case 13 ('$errStr')");
        is($err->{class}, 'rejected', "'$errStr' classifies as rejected");
        is($err->{http}, $expectHttp, "'$errStr': http code is $expectHttp");
    }

    # Direct calls of the pure classifier (no I/O).
    is($Q->_classifyHttpError(401), 'unreachable', 'direct: 401 -> unreachable');
    is($Q->_classifyHttpError(429), 'unreachable', 'direct: 429 -> unreachable');
    is($Q->_classifyHttpError(500), 'unreachable', 'direct: 500 -> unreachable');
    is($Q->_classifyHttpError(undef), 'unreachable', 'direct: undef -> unreachable');
    is($Q->_classifyHttpError(400), 'rejected', 'direct: 400 -> rejected');
    is($Q->_classifyHttpError(412), 'rejected', 'direct: 412 -> rejected');
};

# ============================================================
# Case 14: grpc classification table (transient vs semantic)
# ============================================================
subtest 'Case 14: grpc classification table (transient vs semantic)' => sub {
    reset_all();
    my $mac = '00:AA:14:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-14');
    $prefs->set('soloistQuality', 5);

    for my $status (1, 4, 8, 13, 14, 16) {
        $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = $status;
        my ($ok, $err);
        $Q->write($mac, 5, sub { ($ok, $err) = @_; });
        assert_cb_ok("Case 14 (grpc $status)");
        is($err->{class}, 'unreachable', "grpc status $status classifies as unreachable");
        is($err->{grpc}, $status, "grpc status $status is captured");
    }

    for my $status (3, 7, 9) {
        $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = $status;
        my ($ok, $err);
        $Q->write($mac, 5, sub { ($ok, $err) = @_; });
        assert_cb_ok("Case 14 (grpc $status)");
        is($err->{class}, 'rejected', "grpc status $status classifies as rejected");
    }

    # Direct calls of the pure classifier (no I/O).
    is($Q->_classifyGrpcStatus(14), 'unreachable', 'direct: grpc 14 -> unreachable');
    is($Q->_classifyGrpcStatus(7), 'rejected', 'direct: grpc 7 -> rejected');

    reset_all();
    write_device_id($mac);
    $client = MockClient->new($mac, 'player-14');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 14;

    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('Case 14 (applyChange, transient grpc)');

    is($prefs->get('soloistQuality'), 5, 'global pref stays at 5 after a transient grpc write failure');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'client soloistQualityPending is set');
    my $notice = $Q->noticeFor($mac);
    is($notice->{kind}, 'unreachable', 'notice kind is unreachable for a transient grpc write failure');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'), 'soloistQualityInitialised stays unset');
};

# ============================================================
# Case 15: semantic refusal (grpc 7), failing then succeeding read-back on
# real spike-012 bytes -- a refusal without a known effective value must
# never mark the player initialised (D-14).
# ============================================================
subtest 'Case 15: semantic refusal with failing then succeeding read-back (real spike-012 bytes)' => sub {
    reset_all();
    my $mac = '00:AA:15:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-15');
    $prefs->set('soloistQuality', 5);

    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::read_error = 'Connection refused';

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 15 (semantic refusal, failing read-back)');

    is($prefs->get('soloistQuality'), 5, 'global pref stays at 5 when the read-back after a semantic refusal fails');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'),
        'soloistQualityInitialised stays unset -- no effective value exists to reset to');
    is($prefs->client($client)->get('soloistQualityPending'), 1,
        'soloistQualityPending is set so the next occasion retries');
    my $notice = $Q->noticeFor($mac);
    is($notice->{kind}, 'unreachable',
        'notice kind is unreachable, NOT rejected -- a failed read-back leaves no effective value to correct to');

    # Real 66-byte GetDeviceSettings response captured from spclient on
    # lavender-UAT (spike 012, read-before.txt) -- decodes to level 6.
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::read_content = pack('H*',
        '0a360a340a2437633933353962392d653637362d346339362d616233642d366130663332326633306261120c6c6176656e6465722d55415412080806100160016801');

    my $expectedLevel = $Q->_decodeLevel($Slim::Networking::SimpleAsyncHTTP::read_content);

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 15 (semantic refusal, succeeding read-back)');

    my @writeReqs = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@writeReqs), 1, 'exactly one new WriteDeviceValue posted -- the pending retry fired');
    is($prefs->get('soloistQuality'), $expectedLevel, 'global pref reset to the real decoded read-back value');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1,
        'soloistQualityInitialised is set once an effective value is known');
    is($prefs->client($client)->get('soloistQualityPending'), 0, 'soloistQualityPending is cleared');
    $notice = $Q->noticeFor($mac);
    is($notice->{kind}, 'rejected', 'notice kind is rejected once an effective value is known');
    is($notice->{wanted}, 5, 'notice records the wanted level (5)');
    is($notice->{effective}, $expectedLevel, 'notice records the real decoded effective level');
};

# ============================================================
# Case 16: a non-numeric grpc-status trailer is treated as absent -- the
# body is delivered as a success, no die, no warning (G-83.3-1b).
# ============================================================
subtest 'Case 16: non-numeric grpc-status trailer is treated as absent' => sub {
    reset_all();
    my $mac = '00:AA:16:00:00:01';
    write_device_id($mac);
    MockClient->new($mac, 'player-16');

    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 'abc';
    $Slim::Networking::SimpleAsyncHTTP::write_content     = build_content(6);

    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 16 (non-numeric grpc-status)');

    ok($ok, 'write() succeeds when grpc-status is non-numeric (treated as absent, not as an error)');
    ok(!defined($err), 'no error object is passed when grpc-status is non-numeric');
};

# ============================================================
# Case 17: proto3 default omission decodes to level 0 (WINDOWS #30)
# ============================================================
subtest 'Case 17: proto3 default omission decodes to level 0 (WINDOWS #30)' => sub {
    # (a) the real wire bytes captured from lavender-UAT's real device.
    my $realBytes = pack('H*', $REAL_READ_AUTOMATIC_HEX);
    my $realLevel = $Q->_decodeLevel($realBytes);
    ok(defined $realLevel, 'W30: real wire bytes decode to a defined level');
    is($realLevel, 0, 'W30: real wire bytes decode to level 0 (Automatic)');

    # (b) synthetic top-level message whose settings sub-message carries only
    # fields 2/12/13 -- no field 1 at all.
    my $syntheticInner = f(2, 0, 1) . f(12, 0, 1) . f(13, 0, 1);
    my $syntheticTop   = f(1, 2, 'x') . f(2, 2, $syntheticInner);
    is($Q->_decodeLevel($syntheticTop), 0,
        'W30: synthetic fields 2/12/13-only settings message decodes to 0');

    # (c) an explicit field 1 = 0 still decodes to 0 (not merely "absent ->
    # 0" -- a genuinely-present zero must also read as 0).
    my $explicitZero = f(1, 2, 'x') . f(2, 2, f(1, 0, 0) . f(2, 0, 1));
    is($Q->_decodeLevel($explicitZero), 0,
        'W30: explicit field 1 = 0 decodes to 0');

    # (d) top-level message WITHOUT a settings sub-message (field 2) at all
    # stays a parse error -- the over-correction guard (mutation m2 pins
    # this): a genuinely missing answer must never read as Automatic.
    my $noSettingsMsg = f(1, 2, 'x');
    is($Q->_decodeLevel($noSettingsMsg), undef,
        'W30: no settings message (field 2 absent) stays undef (parse error)');

    # (e) garbage bytes -- kept from Case 2, restated here under the W30
    # naming for this subtest's own evidence trail.
    is($Q->_decodeLevel("\xff\xff\xff"), undef, 'W30: garbage bytes -> undef');

    # (h) settings message PRESENT but its own bytes are unparseable (a
    # truncated varint) -- the inner-parse guard (mutation m4 pins this):
    # an unparseable settings message must never read as Automatic either.
    my $unparseableInner = f(1, 2, 'x') . f(2, 2, "\xff\xff");
    is($Q->_decodeLevel($unparseableInner), undef,
        'W30: settings message present but unparseable -> undef');

    # (f) read($mac, cb) end-to-end: the real wire bytes must deliver
    # (0, undef) to the callback, never { class => 'parse_error' }.
    reset_all();
    my $mac = '00:AA:17:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-17');
    $Slim::Networking::SimpleAsyncHTTP::read_content = $realBytes;

    my ($level, $err);
    $Q->read($mac, sub { ($level, $err) = @_; });
    assert_cb_ok('Case 17 (f) read() end-to-end');
    is($level, 0, 'W30: read() delivers level 0 for the real wire bytes');
    is($err, undef, 'W30: read() delivers no error (not parse_error) for the real wire bytes');

    # (g) onDaemonReady($mac) with global soloistQuality 0 and the real wire
    # bytes as the read-back -- the live defect this closes: the player must
    # end up initialised, not stuck pending forever.
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = $realBytes;
    $prefs->set('soloistQuality', 0);

    $Q->onDaemonReady($mac);
    assert_cb_ok('Case 17 (g) onDaemonReady with real wire bytes');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 2,
        'W30: onDaemonReady posts exactly two requests (write + read-back) for a real Automatic device');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1,
        'W30: onDaemonReady marks soloistQualityInitialised after a real Automatic read-back');
    is($prefs->client($client)->get('soloistQualityPending'), 0,
        'W30: onDaemonReady clears soloistQualityPending after a real Automatic read-back');
};

# ============================================================
# Case 18 (quick-261018-ife): a login5 HTTP 429 is a throttle, not a missing
# authorization. getToken's third callback arg carries code => 429 (live and
# damped replay); Quality maps exactly that to 'unreachable'. Every other
# token failure stays 'no_token'.
# ============================================================
subtest 'Case 18: login5 429 -> unreachable (pref kept, pending set); other mint failures stay no_token' => sub {
    # (a) 429 via write()
    reset_all();
    my $mac = '00:AA:18:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-18');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { code => 429, retryAfter => 30 };

    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 18 (a) write with login5 429');
    is($err->{class}, 'unreachable', 'login5 429 classifies as unreachable, not no_token');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'login5 429: no POST is made');

    # (b) 429 via applyChange()
    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('Case 18 (b) applyChange with login5 429');
    is($prefs->get('soloistQuality'), 5, 'login5 429: global pref stays at 5');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'login5 429: client soloistQualityPending is set');
    is($Q->noticeFor($mac)->{kind}, 'unreachable', 'login5 429: notice kind is unreachable, not no_token');

    # (c) invalid_credentials, no detail
    reset_all();
    my $mac2 = '00:AA:18:00:00:02';
    write_device_id($mac2);
    MockClient->new($mac2, 'player-18b');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'invalid_credentials';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = undef;

    ($ok, $err) = (undef, undef);
    $Q->write($mac2, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 18 (c) write with invalid_credentials');
    is($err->{class}, 'no_token', 'invalid_credentials without detail stays no_token');
    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('Case 18 (c) applyChange with invalid_credentials');
    is($Q->noticeFor($mac2)->{kind}, 'no_token', 'invalid_credentials: notice kind stays no_token');

    # (d) real network-failure shape (Login5.pm:340)
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { transient => 1 };
    ($ok, $err) = (undef, undef);
    $Q->write($mac2, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 18 (d) write with transient mint failure');
    is($err->{class}, 'no_token', 'mint_failed with { transient => 1 } stays no_token');

    # (e) a non-429 code pins the exact == 429 comparison
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { code => 400 };
    ($ok, $err) = (undef, undef);
    $Q->write($mac2, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 18 (e) write with code 400');
    is($err->{class}, 'no_token', 'mint_failed with { code => 400 } stays no_token');

    # (f) hygiene
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
    $Plugins::SpotOn::API::Login5::mock_fail_detail = undef;
};

# ============================================================
# Case 19 (WR-18): the protobuf throttle answers of login5 (LoginError 4/6/8,
# detail { throttled => 1 }) are the same throttle as the HTTP 429 and map to
# 'unreachable' as well; a falsy flag stays no_token.
# ============================================================
subtest 'Case 19: login5 protobuf throttle -> unreachable (pref kept, pending set)' => sub {
    my $n = 0;
    for my $le (4, 6, 8) {
        reset_all();
        my $mac = sprintf('00:AA:19:00:00:%02X', ++$n);
        write_device_id($mac);
        my $client = MockClient->new($mac, "player-19-$le");
        $prefs->set('soloistQuality', 5);
        $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
        $Plugins::SpotOn::API::Login5::mock_fail_detail = { throttled => 1, loginError => $le, retryAfter => 60 };

        my ($ok, $err);
        $Q->write($mac, 5, sub { ($ok, $err) = @_; });
        assert_cb_ok("Case 19 write with LoginError $le");
        is($err->{class}, 'unreachable', "LoginError $le classifies as unreachable, not no_token");
        is($err->{source}, 'login5', "LoginError $le names login5 as the source");
        is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, "LoginError $le: no POST is made");

        $Q->applyChange(scope => 'global', level => 5);
        assert_cb_ok("Case 19 applyChange with LoginError $le");
        is($prefs->get('soloistQuality'), 5, "LoginError $le: global pref stays at 5");
        is($prefs->client($client)->get('soloistQualityPending'), 1, "LoginError $le: client soloistQualityPending is set");
        is($Q->noticeFor($mac)->{kind}, 'unreachable', "LoginError $le: notice kind is unreachable, not no_token");
    }

    reset_all();
    my $mac = '00:AA:19:00:00:FF';
    write_device_id($mac);
    MockClient->new($mac, 'player-19-off');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { throttled => 0 };
    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 19 write with throttled => 0');
    is($err->{class}, 'no_token', 'throttled => 0 stays no_token');

    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
    $Plugins::SpotOn::API::Login5::mock_fail_detail = undef;
};

# ============================================================
# Case 19 (74b-02 D-18): the role exposes the level SpotOn would write
# (qualityInfo->{wanted}), so the player page can tell an explicit Lossless /
# Very high source from Automatic without a core module calling Quality.
# ============================================================
subtest 'Case 19: qualityInfo($client)->{wanted} is the level SpotOn writes' => sub {
    reset_all();
    my $client = MockClient->new('00:AA:19:00:00:01', 'player-19');
    require_ok('Plugins::SpotOn::Backend::Soloist');
    my $S = 'Plugins::SpotOn::Backend::Soloist';

    $prefs->set('soloistQuality', 4);
    $prefs->client($client)->set('soloistQuality', '5');
    my $qi = eval { $S->qualityInfo($client) } || {};
    is($qi->{wanted}, 5, "per-player stored '5' -> wanted 5");
    is($qi->{wanted}, $Q->effectiveLevelForClient($client), "wanted equals Quality->effectiveLevelForClient (per-player '5')");

    $prefs->client($client)->set('soloistQuality', 'global');
    $qi = eval { $S->qualityInfo($client) } || {};
    is($qi->{wanted}, 4, "stored 'global' -> wanted is the global level (4)");
    is($qi->{wanted}, $Q->effectiveLevelForClient($client), "wanted equals Quality->effectiveLevelForClient ('global')");

    $prefs->set('soloistQuality', 0);
    $qi = eval { $S->qualityInfo($client) } || {};
    is($qi->{wanted}, 0, "global Automatic -> wanted 0 (no MP3 note)");
};


# ============================================================
# 79-43 (D-33 FULL-3 WR-02): the device name is a character string from LMS; the quality request carries it
# as UTF-8 in both Perl representations, and a transport die in the POST is a classified error.
# ============================================================
subtest '79-43 Q1-Q3: device name as UTF-8, POST guarded' => sub {
    reset_all();
    my $id      = '7c9359b9-e676-4c96-ab3d-6a0f322f30ba';
    my $latin1  = "K\x{fc}che";                    # stored as Latin-1 internally (not flagged)
    my $upgraded = $latin1; utf8::upgrade($upgraded);
    my $w1 = $Q->_encodeWrite($id, $latin1, 5);
    my $w2 = $Q->_encodeWrite($id, $upgraded, 5);
    is(unpack('H*', $w1), unpack('H*', $w2), '79-43 Q1 (D-33 FULL-3 WR-02): _encodeWrite gives byte-identical bodies for both representations of "K\x{fc}che"');
    ok(index($w1, "\x12\x06K\xc3\xbcche") >= 0, '79-43 Q1: ... carrying the name as UTF-8 with length byte 6');
    ok(index($Q->_encodeRead($id, $latin1), "\x12\x06K\xc3\xbcche") >= 0, '79-43 Q1: _encodeRead carries the Latin-1 representation as UTF-8 too');

    reset_all();
    my $mac = '00:AA:43:00:00:02';
    write_device_id($mac);
    MockClient->new($mac, "B\x{fc}ro \x{2615}");
    my ($ok, $err);
    my $lived = eval { $Q->write($mac, 5, sub { ($ok, $err) = @_; }); 1 };
    my $req = $Slim::Networking::SimpleAsyncHTTP::requests[-1] || {};
    ok($lived && $ok, '79-43 Q2: a write for "B\x{fc}ro \x{2615}" does not die and succeeds');
    is(defined $req->{body} ? (utf8::is_utf8($req->{body}) ? 1 : 0) : 'nobody', 0, '79-43 Q2: the posted body is bytes (utf8::is_utf8 0)');
    ok(defined $req->{body} && index($req->{body}, "B\xc3\xbcro \xe2\x98\x95") >= 0, '79-43 Q2: ... with the name as UTF-8');

    reset_all();
    my $mac3 = '00:AA:43:00:00:03';
    write_device_id($mac3);
    MockClient->new($mac3, 'player-43');
    $Slim::Networking::SimpleAsyncHTTP::write_mode = 'die';
    ($ok, $err) = (undef, undef);
    my $escaped;
    eval { $Q->_request('WriteDeviceValue', 'x', sub { ($ok, $err) = @_; }); 1 } or $escaped = $@;
    is($escaped // 'none', 'none', '79-43 Q3: a die inside the POST does not escape to the caller');
    is(($err && $err->{class}) // 'none', 'unreachable', '79-43 Q3: the callback gets class unreachable');
    like(($err && $err->{error}) // '', qr/content must be bytes/, '79-43 Q3: ... with the error text');
};

done_testing();
