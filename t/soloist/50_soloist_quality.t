#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use POSIX qw();

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
# allClients: mirrors Namespace::allClients (Namespace.pm:240-253) -- one
# object per stored per-client namespace, carrying the player id in {clientid}
# (Client.pm:37-41), including players that are not connected.
sub allClients {
    my ($self) = @_;
    my $prefix = $self->{_ns} . '_client_';
    my @out;
    for my $key (sort keys %_store) {
        next unless index($key, $prefix) == 0;
        push @out, bless { _ns => $key, clientid => substr($key, length $prefix) }, 'Slim::Utils::Prefs';
    }
    return @out;
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
# (synchronous test execution, no event loop) and records the DELAY it was
# asked for (due time minus the frozen clock), so a test can pin the wait times.
# @hooks: one entry per setTimer call is shifted off and run (when it is a CODE
# ref) before the callback fires -- the way to change the world between two
# timer firings (e.g. a pairing that appears between two retries).
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @scheduled;
our @hooks;
our $hold_min;    # a delay >= this is recorded, but its callback is NOT run: that timer has not fired (yet)
our @held;
sub setTimer {
    my ($obj, $time, $cb, @args) = @_;
    push @scheduled, $time - Time::HiRes::time();
    if (defined $hold_min && $scheduled[-1] >= $hold_min) { push @held, $cb; return; }
    my $hook = shift @hooks;
    $hook->() if ref $hook eq 'CODE';
    $cb->(@args);
}
our @killed;
sub killTimers { push @killed, $_[1]; }
sub reset_timers { @scheduled = (); @hooks = (); @held = (); @killed = (); $hold_min = undef; }
1;
END

# Time::HiRes: a FROZEN clock the tests can move ($Time::HiRes::clock), so a
# delay is an exact number and the stale limit of the reconcile queue is
# reachable. Test2 already loaded the real module (a stub file in $stub_dir would
# never be required), so time() is redefined in place: it answers the frozen
# clock while one is set, else the real time. reset_all() sets it; the end of the
# file clears it.
BEGIN {
    require Time::HiRes;
    no warnings 'redefine';
    my $real = \&Time::HiRes::time;
    *Time::HiRes::time = sub () { defined $Time::HiRes::clock ? $Time::HiRes::clock : $real->() };
}

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

# Stub: Plugins::SpotOn::API::SpClient -- 79-61 (FULL-3 WR-03): the central
# spclient gate (shared concurrency cap and 429 key). Records every gated
# request; 'blocked' answers as a cached rate limit would.
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
our @gate_calls;
our $gate_mode = 'pass';   # pass | blocked
our $inflight  = 0;
our $max_inflight = 0;
our @rate_notes;
sub gate {
    my ($class, $label, $run, $blocked) = @_;
    push @gate_calls, $label;
    if ($gate_mode eq 'blocked') { $blocked->('rate_limited_local'); return; }
    $inflight++;
    $max_inflight = $inflight if $inflight > $max_inflight;
    my $released = 0;
    $run->(sub { return if $released++; $inflight--; });
}
sub noteRateLimit { my ($class, $retryAfter) = @_; push @rate_notes, $retryAfter; }
sub reset_gate { @gate_calls = (); $gate_mode = 'pass'; $inflight = 0; $max_inflight = 0; @rate_notes = (); }
1;
END

# Stub: Plugins::SpotOn::Soloist -- dataDirForClient returns a per-mac
# tempdir the test writes .device_id into.
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
use File::Temp qw(tempdir);
our %datadirs;
our %paired_unknown;    # clean mac => 1 -> isPairedForClient answers undef (unknown)
sub dataDirForClient {
    my ($mac) = @_;
    (my $clean = $mac || '') =~ s/://g;
    $datadirs{$clean} ||= tempdir(CLEANUP => 1);
    return $datadirs{$clean};
}
# Mirrors Soloist.pm:1710-1725 (isPairedForClient): undef = unknown, 0 = never
# paired, 1 = settings/Users holds at least one non-dot entry.
sub isPairedForClient {
    my ($mac) = @_;
    (my $clean = $mac || '') =~ s/://g;
    return undef if $paired_unknown{$clean};
    my $users = dataDirForClient($mac) . '/settings/Users';
    return 0 unless -d $users;
    my $dh;
    return undef unless opendir($dh, $users);
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return scalar(@entries) ? 1 : 0;
}
1;
END

# Stub: Plugins::SpotOn::Unified::DaemonManager -- deviceNameForClient and
# helperForClient (quick 261112-ca5 R3, BL-01: the Soloist daemon of a player and
# its logged_in state). %login_state: mac => what helperForClient answers for it.
#   (absent) / 'own'  the player's OWN alive daemon, logged in (the default: every
#                     flank-driven test is, by definition, a logged-in daemon)
#   'out'             the player's own daemon is alive but NOT logged in
#   'none'            no alive daemon for this player (stopped, expired, Sync slave
#                     without its own daemon, daemon in a restart)
#   'master'          the real helperForClient's Sync fallback (DaemonManager.pm:3542-
#                     3549): an alive, logged in daemon of ANOTHER player (the master)
#   'ws_dies'         R4/WR-01: an alive own daemon whose private _ws access dies (a
#                     renamed accessor, a missing method in the real class)
#   'state_bad'       R4/WR-01: an alive own daemon whose authState has another shape
#                     than a hash (the access dies under strict refs)
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $die_on_name = 0;    # a test sets it to make the name lookup (hence a write) die synchronously
our %login_state;
sub deviceNameForClient {
    my ($class, $client) = @_;
    die "stub: deviceNameForClient died\n" if $die_on_name;
    return $client->name;
}
sub helperForClient {
    my ($class, $c) = @_;
    my $mac  = ref $c ? $c->id : $c;
    my $mode = $login_state{$mac} // 'own';
    return undef if $mode eq 'none';
    return bless {
        mac       => ($mode eq 'master' ? '00:AA:00:00:00:99' : $mac),
        logged_in => ($mode eq 'out' ? 0 : 1),
        mode      => $mode,
    }, 'Plugins::SpotOn::Unified::DaemonManager::StubHelper';
}
package Plugins::SpotOn::Unified::DaemonManager::StubHelper;
sub alive     { 1 }
sub mac       { $_[0]->{mac} }
sub backendName { 'soloist' }
sub _ws {
    die "stub: _ws is gone\n" if $_[0]->{mode} eq 'ws_dies';
    return bless { logged_in => $_[0]->{logged_in}, mode => $_[0]->{mode} }, 'Plugins::SpotOn::Unified::DaemonManager::StubWS';
}
package Plugins::SpotOn::Unified::DaemonManager::StubWS;
sub authState { return 'not-a-hash' if $_[0]->{mode} eq 'state_bad'; return { logged_in => $_[0]->{logged_in} } }
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
our $defer   = 0;
our @pending = ();
# Per-read answer queue (ca5): a plain item is the success content of the next
# GetDeviceSettings answer; a HASH ref may carry before => CODE (run first, e.g.
# pairing the device between two reads), then error => '...' (error path) or
# content => '...' (success). An empty queue keeps the static read_* behaviour.
our @read_queue = ();
sub complete_next { my $p = shift @pending or return 0; $p->[0]->_answer($p->[1], $p->[2]); return 1; }

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

    # 79-61 (FULL-3 WR-03): deferred mode keeps the request open until
    # complete_next() answers it, so a test can count requests in flight.
    if ($defer) { push @pending, [ $self, $url, $isWrite ]; return; }
    $self->_answer($url, $isWrite);
    return;
}

sub _answer {
    my ($self, $url, $isWrite) = @_;
    my $mode    = $isWrite ? $write_mode : $read_mode;
    my ($queued_content, $queued_error);

    if (!$isWrite && @read_queue) {
        my $item = shift @read_queue;
        if (ref $item eq 'HASH') {
            $item->{before}->() if ref $item->{before} eq 'CODE';
            if (defined $item->{error}) { $queued_error = $item->{error}; }
            else                        { $queued_content = $item->{content}; }
        }
        else { $queued_content = $item; }
        $mode = defined $queued_error ? 'error' : 'success';
    }

    $last_callback_error = undef;

    if ($mode eq 'success') {
        $self->{_code}    = 200;
        $self->{_mess}    = 'OK';
        $self->{_url}     = $url;
        $self->{_content} = $isWrite ? $write_content : (defined $queued_content ? $queued_content : $read_content);
        $self->{_headers} = HTTP::Headers->new(
            'grpc-status'  => ($isWrite ? $write_grpc_status  : $read_grpc_status),
            'grpc-message' => ($isWrite ? $write_grpc_message : $read_grpc_message),
        );
        eval { $self->{success_cb}->($self); 1 } or $last_callback_error = $@;
    }
    else {
        my $err = $isWrite ? $write_error : (defined $queued_error ? $queued_error : $read_error);
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
    @read_queue = ();
    $defer = 0; @pending = ();
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
    our @read_queue;
    package Plugins::SpotOn::Soloist;
    our %paired_unknown;
    package Plugins::SpotOn::Unified::DaemonManager;
    our $die_on_name;
    our %login_state;
    package Slim::Utils::Timers;
    our (@scheduled, @hooks, $hold_min, @held, @killed);
    package Time::HiRes;
    our $clock;
}

# Force-load the controllable stubs up front (Quality.pm runtime-requires
# them only when a code path is actually hit).
require_ok('Plugins::SpotOn::API::Login5')                   or BAIL_OUT('Failed to load Login5 stub');
require_ok('Plugins::SpotOn::API::SpClient')                 or BAIL_OUT('Failed to load SpClient gate stub');
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
    Plugins::SpotOn::API::SpClient::reset_gate();
    Slim::Utils::Prefs::reset_store();      # no per-client namespace survives a case boundary
    Slim::Utils::Cache->new()->clear();
    Plugins::SpotOn::API::Login5::reset_calls();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
    $Plugins::SpotOn::API::Login5::mock_fail_detail = undef;
    $Plugins::SpotOn::API::Login5::mock_token ='mock-login5-bearer-token-should-never-be-logged';
    @Slim::Utils::Log::logged = ();
    %Slim::Player::Client::clients = ();
    %Plugins::SpotOn::Soloist::paired_unknown = ();
    Slim::Utils::Timers::reset_timers();
    $Plugins::SpotOn::Unified::DaemonManager::die_on_name = 0;
    %Plugins::SpotOn::Unified::DaemonManager::login_state = ();
    $Time::HiRes::clock = POSIX::floor(CORE::time());
    $Q->_resetReconcileQueue if $Q->can('_resetReconcileQueue');
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

# pair_device($mac) -- the pairing fixture isPairedForClient reads: a user
# folder below dataDir/settings/Users (Soloist.pm:1710-1725).
sub pair_device {
    my ($mac) = @_;
    my $dir = Plugins::SpotOn::Soloist::dataDirForClient($mac) . '/settings/Users/x';
    make_path($dir) unless -d $dir;
    return $dir;
}

# vdev($client) -> the device id SoloistQualityVerifiedPaired must carry (WR-07).
sub vdev { return $Q->deviceIdForMac($_[0]->id) }

# uuid_in_body($req, $uuid) -> does a recorded request address this device?
sub uuid_in_body { my ($req, $uuid) = @_; return defined $req->{body} && index($req->{body}, $uuid) >= 0 ? 1 : 0 }

# req_counts() -> (reads, writes) among the recorded requests, by URL suffix.
sub req_counts {
    my @r = grep { $_->{url} =~ m{/GetDeviceSettings$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    my @w = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    return (scalar(@r), scalar(@w));
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
    pair_device($mac_old);    # R1: only a paired and logged-in device is written
    pair_device($mac_new);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(0);
    my $addr_old;
    {
        my $old = MockClient->new($mac_old, 'player-0-old');
        $Q->onLoginFlank($mac_old);
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
        $Slim::Networking::SimpleAsyncHTTP::read_mode   = 'error';
        $Slim::Networking::SimpleAsyncHTTP::read_error  = 'Connection refused';
        $Q->onLoginFlank($mac_new);
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
    pair_device($mac);    # ca5 W3: a PAIRED device keeps the old reset to the read-back
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
# Case 8: onLoginFlank (paired, logged in) -- R1: the wished level is written
# ONCE UNCONDITIONALLY (Automatic included, also when the server already reads
# the wish), D-12 no repeat once verified paired, pending retries
# ============================================================
subtest 'Case 8: onLoginFlank (paired) writes Automatic once, never again, unless pending' => sub {
    reset_all();
    my $mac = '00:AA:08:00:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'player-8');
    $prefs->set('soloistQuality', 0);

    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(0));

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 8 (first flank)');
    my ($reads, $writes) = req_counts();
    is($reads, 1, 'the first flank reads once (the read-back only -- no reconcile read any more)');
    is($writes, 1, 'the first flank writes Automatic exactly once, although the server already reads 0');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1, 'soloistQualityInitialised is set after the first write');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'soloistQualityVerifiedPaired is set (read-back matched, device paired)');
    is($prefs->client($client)->get('soloistQualityPending'), 0, 'soloistQualityPending is cleared');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 8 (second flank, no-op)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a second flank posts nothing, even though the server now holds 5 (D-12)');

    $prefs->client($client)->set('soloistQualityPending', 1);
    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 8 (pending retry)');
    ok(scalar(@Slim::Networking::SimpleAsyncHTTP::requests) > 0, 'onLoginFlank posts again once pending is set');
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
# Case 11 (CTX-4, W3): a rejection never marks the player verified and never
# resets a pref on a device without confirmed pairing; paired reconcile
# rejections reset nothing either; an unpaired flank posts NOTHING (R1: no
# read, no write -- only Pending).
# ============================================================
subtest 'Case 11: rejected reconcile keeps flag open and prefs unchanged; an unpaired flank posts nothing' => sub {
    reset_all();
    my $mac = '00:AA:11:00:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-11');
    $prefs->set('soloistQuality', 5);

    # (a) UNPAIRED: the flank neither reads nor writes; a later global change
    # that the server rejects must not reset the global pref (an unregistered
    # device must not tip everyone's wish).
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 11 (a, unpaired flank)');
    my (undef, $w) = req_counts();
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, '(a) an UNPAIRED flank posts no request at all (R1: not even a read)');
    is($w, 0, '(a) an UNPAIRED flank posts no write');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'), '(a) soloistQualityInitialised stays unset');
    ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), '(a) soloistQualityVerifiedPaired stays unset');
    is($prefs->client($client)->get('soloistQualityPending'), 1, '(a) pending is set (nur vormerken)');

    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('Case 11 (a, applyChange unpaired)');
    (undef, $w) = req_counts();
    is($w, 1, '(a) applyChange posts exactly one write');
    is($prefs->get('soloistQuality'), 5, '(a) the global pref STAYS 5 -- no reset on a device without confirmed pairing (W3)');
    is($prefs->client($client)->get('soloistQualityPending'), 1, '(a) pending stays set');
    is(($Q->noticeFor($mac) || {})->{kind}, 'rejected', '(a) notice kind is rejected');

    # (b) PAIRED: the reconcile write is refused -> flag open, no pref reset.
    pair_device($mac);
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 11 (b, paired rejected reconcile)');
    (undef, $w) = req_counts();
    is($w, 1, '(b) one write posted');
    is($prefs->get('soloistQuality'), 5, '(b) global pref stays 5 (the reconcile path resets no pref)');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'), '(b) soloistQualityInitialised stays unset');
    ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), '(b) soloistQualityVerifiedPaired stays unset');
    my $notice = $Q->noticeFor($mac) || {};
    is($notice->{kind}, 'rejected', '(b) notice kind is rejected');
    is($notice->{wanted}, 5, '(b) notice wanted 5');
    is($notice->{effective}, 3, '(b) notice effective 3');
    is($prefs->client($client)->get('soloistQualityRejectCount'), 1, '(b) soloistQualityRejectCount counts the rejection');

    # (c) fresh unpaired player whose reads would fail: still nothing is posted.
    reset_all();
    my $mac2 = '00:AA:11:00:00:02';
    write_device_id($mac2);
    my $client2 = MockClient->new($mac2, 'player-11b');
    $prefs->set('soloistQuality', 0);

    $Slim::Networking::SimpleAsyncHTTP::read_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::read_error = 'Connection refused';

    $Q->onLoginFlank($mac2);
    assert_cb_ok('Case 11 (c, unpaired flank, failing reads)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, '(c) an unpaired flank posts nothing');
    ok(!$prefs->client($client2)->get('soloistQualityInitialised'),
        '(c) an unpaired flank leaves soloistQualityInitialised unset');
    is($prefs->client($client2)->get('soloistQualityPending'), 1, '(c) pending is set so the next occasion retries');
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
    pair_device($mac);
    $prefs->set('soloistQuality', 5);

    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(3);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = '503 Service Unavailable';
    # WR-01 (R3): the failed write arms a retry timer (60 s). It has not fired in this
    # case -- the bounded retry itself is ca5-24..27.
    $Slim::Utils::Timers::hold_min = 60;

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 12 (503 first write)');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ 3, 60 ], 'the failed write arms the first retry (60 s) after the settle wait');

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
    is(scalar(@readReqs), 0, 'no GetDeviceSettings request at all (no reconcile read, no read-back after a transient write failure)');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 12 (pending retry succeeds)');

    my @writeReqs2 = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@writeReqs2), 1, 'exactly one new WriteDeviceValue request -- the pending retry fired');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1,
        'soloistQualityInitialised is set once the retry succeeds');
    is($prefs->client($client)->get('soloistQualityPending'), 0,
        'soloistQualityPending is cleared after the retry succeeds');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client),
        'soloistQualityVerifiedPaired is set once the retry is verified');
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
    pair_device($mac);
    $prefs->set('soloistQuality', 5);

    # R1: the unconditional write is refused, and the read after the refusal fails.
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    @Slim::Networking::SimpleAsyncHTTP::read_queue = ({ error => 'Connection refused' });
    $Slim::Utils::Timers::hold_min = 60;    # WR-01 (R3): the armed retry has not fired in this case

    $Q->onLoginFlank($mac);
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

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 15 (semantic refusal, succeeding read-back)');

    my @writeReqs = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@writeReqs), 1, 'exactly one new WriteDeviceValue posted -- the pending retry fired');
    is($prefs->get('soloistQuality'), 5, 'global pref STAYS 5 -- the reconcile path resets no pref (CTX-4)');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'),
        'soloistQualityInitialised stays unset -- a rejection never closes the flag (CTX-4)');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'soloistQualityPending stays set');
    # WR-04 (R3): the first refusal (its read-back failed) counts as well -- two refusals so far.
    is($prefs->client($client)->get('soloistQualityRejectCount'), 2, 'soloistQualityRejectCount counts both rejections, also the one whose read-back failed');
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
    pair_device($mac);
    $Slim::Networking::SimpleAsyncHTTP::read_content = $realBytes;

    my ($level, $err);
    $Q->read($mac, sub { ($level, $err) = @_; });
    assert_cb_ok('Case 17 (f) read() end-to-end');
    is($level, 0, 'W30: read() delivers level 0 for the real wire bytes');
    is($err, undef, 'W30: read() delivers no error (not parse_error) for the real wire bytes');

    # (g) onLoginFlank($mac) with global soloistQuality 0 and the real wire
    # bytes as the read-back -- the live defect this closes: the player must
    # end up initialised, not stuck pending forever.
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = $realBytes;
    $prefs->set('soloistQuality', 0);

    $Q->onLoginFlank($mac);
    assert_cb_ok('Case 17 (g) onLoginFlank with real wire bytes');
    is(join(',', req_counts()), '1,1',
        'W30: onLoginFlank posts one write (unconditional, R1) and one read-back for a real Automatic device');
    is($prefs->client($client)->get('soloistQualityInitialised'), 1,
        'W30: onLoginFlank marks soloistQualityInitialised after a real Automatic read-back');
    is($prefs->client($client)->get('soloistQualityPending'), 0,
        'W30: onLoginFlank clears soloistQualityPending after a real Automatic read-back');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client),
        'W30: onLoginFlank sets soloistQualityVerifiedPaired (read == wanted, device paired)');
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

    # (d) real network-failure shape (Login5.pm:343-348): R4/WR-02 flips this from no_token to unreachable
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { transient => 1 };
    ($ok, $err) = (undef, undef);
    $Q->write($mac2, 5, sub { ($ok, $err) = @_; });
    assert_cb_ok('Case 18 (d) write with transient mint failure');
    is($err->{class}, 'unreachable', 'R4/WR-02: mint_failed with { transient => 1 } (network failure or 5xx while minting) is unreachable, not no_token');
    is($err->{source}, 'login5_transient', 'R4/WR-02: and carries its own source (not the throttle source with the 300 s minimum)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'R4/WR-02: no POST is made without a token');

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

# ============================================================
# 79-61 (79-REVIEW-FULL-3 WR-03): the "one central throttle" invariant did
# not hold for playback-settings. Quality.pm posted straight through its own
# SimpleAsyncHTTP: no shared concurrency cap, a spclient 429 key did not stop
# it, its own 429 was forgotten, and applyChange(global) fired one write per
# player at once. Every Quality request now passes SpClient's gate, a 429 is
# recorded in the shared key, and a global change writes one player at a time.
# ============================================================
subtest '79-61 WR-03: playback-settings requests pass the central spclient gate' => sub {
    reset_all();
    my $mac = '00:AA:61:00:00:01';
    write_device_id($mac);
    MockClient->new($mac, 'player-61');

    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    is(scalar(@Plugins::SpotOn::API::SpClient::gate_calls), 1, 'a write passes the gate exactly once');
    like($Plugins::SpotOn::API::SpClient::gate_calls[0] // '', qr/WriteDeviceValue/, 'the gate label names the method');
    is($Plugins::SpotOn::API::SpClient::inflight, 0, 'the gate slot is released after the answer');

    my ($lvl, $rerr);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(3);
    $Q->read($mac, sub { ($lvl, $rerr) = @_; });
    is(scalar(@Plugins::SpotOn::API::SpClient::gate_calls), 2, 'a read passes the gate as well');
};

subtest '79-61 WR-03: a cached spclient rate limit stops the request before any HTTP' => sub {
    reset_all();
    my $mac = '00:AA:61:00:00:02';
    write_device_id($mac);
    MockClient->new($mac, 'player-61b');
    $Plugins::SpotOn::API::SpClient::gate_mode = 'blocked';
    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'no HTTP request while the shared rate limit holds');
    is(($err && $err->{class}) // 'none', 'unreachable', 'the blocked request is classified unreachable (pref kept, retried later)');
};

subtest '79-61 WR-03: a playback-settings 429 is recorded in the shared rate key' => sub {
    reset_all();
    my $mac = '00:AA:61:00:00:03';
    write_device_id($mac);
    MockClient->new($mac, 'player-61c');
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = '429 Too Many Requests';
    my ($ok, $err);
    $Q->write($mac, 5, sub { ($ok, $err) = @_; });
    is(scalar(@Plugins::SpotOn::API::SpClient::rate_notes), 1, 'the 429 is handed to SpClient->noteRateLimit');
    is(($err && $err->{class}) // 'none', 'unreachable', 'the 429 itself stays unreachable');
};

subtest '79-61 WR-03: applyChange(global) writes one player at a time' => sub {
    reset_all();
    my @macs = ('00:AA:61:00:01:01', '00:AA:61:00:01:02', '00:AA:61:00:01:03');
    for my $m (@macs) { write_device_id($m); MockClient->new($m, "p-$m"); }
    $prefs->set('soloistQuality', 0);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->applyChange(scope => 'global', level => 5);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::pending), 1, 'only one request is in flight right after a global change (not one per player)');

    my $answered = 0;
    while (Slim::Networking::SimpleAsyncHTTP::complete_next()) {
        $answered++;
        last if $answered > 20;
        ok(scalar(@Slim::Networking::SimpleAsyncHTTP::pending) <= 1, "after answer $answered at most one request is in flight");
    }
    my @writes = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@writes), 3, 'every player still gets its write');
    is($Plugins::SpotOn::API::SpClient::max_inflight, 1, 'the gate never held two Quality requests at once');
};

# ============================================================
# ca5 (quick 261112-ca5, debug beta9-qualitaet-160k-lossless), reworked by R1
# (Nachbesserung 2026-11-12, rig finding: the daemon takes the level ONLY from
# the server-to-client push a WRITE on a paired, logged-in device triggers; a
# read says 5 while the daemon still plays Vorbis 160k).
# After the first confirmed pairing AND login the wished level is written ONCE
# UNCONDITIONALLY (no read first, no skip when the server already holds it),
# read-back verified; unpaired or not logged in: nothing is posted, only
# Pending; serial, capped, offline catch-up. Every call to API that the
# pre-fix tree lacks (onLoginFlank, RECONCILE_REJECT_CAP, ...) is guarded with
# can(), so a subtest fails with `not ok` instead of dying.
# ============================================================
# The timing and cap values are PINNED here on purpose (a test that reads them
# back from the module follows a mutated constant and proves nothing).
my $CAP    = 3;     # RECONCILE_REJECT_CAP
my $RETRY  = 3;     # LOGIN_RETRY_MAX
my $SETTLE = 3;     # LOGIN_SETTLE_S
my $WAIT   = 5;     # LOGIN_RETRY_S
my $STALE  = 120;   # RECONCILE_STALE_S

subtest 'ca5-1: an unpaired flank posts nothing; after pairing the next flank writes once' => sub {
    reset_all();
    my $mac = '00:AA:CA:01:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-ca5-1');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-1 (unpaired flank)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'unpaired flank: no request at all (no read, no write)');
    ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), 'unpaired flank: VerifiedPaired stays unset');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'unpaired flank: Pending is set (vormerken)');

    pair_device($mac);
    @Slim::Networking::SimpleAsyncHTTP::requests   = ();
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));
    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-1 (paired flank)');
    my ($r, $w) = req_counts();
    is($w, 1, 'after pairing: exactly one write');
    is($r, 1, 'after pairing: exactly one read (the read-back), no read before the write');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'after pairing: VerifiedPaired is 1');
    is($prefs->client($client)->get('soloistQualityPending'), 0, 'after pairing: Pending is 0');
};

subtest 'ca5-2: onDaemonReady alone posts nothing (not logged in yet); the logged_in flank writes' => sub {
    reset_all();
    my $mac = '00:AA:CA:02:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-ca5-2');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    ok($Q->can('onLoginFlank'), 'Quality offers onLoginFlank');

    $Q->onDaemonReady($mac);
    assert_cb_ok('ca5-2 (unpaired start)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'an unpaired daemon start posts nothing');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'an unpaired daemon start marks Pending');

    pair_device($mac);
    $Q->onDaemonReady($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0,
        'a PAIRED daemon start posts nothing either: the daemon is not logged in yet, the flank is the occasion');

    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));
    $Q->onLoginFlank($mac) if $Q->can('onLoginFlank');
    assert_cb_ok('ca5-2 (login flank)');
    my ($r, $w) = req_counts();
    is($w, 1, 'the flank after pairing: exactly one write');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'the flank sets VerifiedPaired');

    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    $Q->onLoginFlank($mac) if $Q->can('onLoginFlank');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a further flank sends zero requests');
    $Q->onDaemonReady($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a further daemon start sends zero requests');
};

subtest 'ca5-3: (D-12) verified paired -> no request from onDaemonReady or onLoginFlank, even if the server changed' => sub {
    reset_all();
    my $mac = '00:AA:CA:03:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'player-ca5-3');
    $prefs->set('soloistQuality', 5);
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-3 (verification)');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'precondition: VerifiedPaired is 1');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(2);    # the app changed it meanwhile
    $Q->onDaemonReady($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'onDaemonReady sends zero requests once verified paired');
    $Q->onLoginFlank($mac) if $Q->can('onLoginFlank');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'onLoginFlank sends zero requests once verified paired');
    is($prefs->get('soloistQuality'), 5, 'the global pref is still 5');
};

subtest 'ca5-4: a persistently rejecting device is retried at most RECONCILE_REJECT_CAP times, prefs untouched' => sub {
    reset_all();
    my $mac = '00:AA:CA:04:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'player-ca5-4');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);

    my $writes = 0;
    my $lastRequests;
    for my $i (1 .. $CAP + 1) {
        @Slim::Networking::SimpleAsyncHTTP::requests = ();
        $Q->onLoginFlank($mac);
        my (undef, $w) = req_counts();
        $writes += $w;
        $lastRequests = scalar(@Slim::Networking::SimpleAsyncHTTP::requests);
    }
    assert_cb_ok('ca5-4');
    is($writes, $CAP, "exactly RECONCILE_REJECT_CAP ($CAP) writes over " . ($CAP + 1) . ' flanks');
    is($lastRequests, 0, 'the flank after the cap is reached sends zero requests');
    is($prefs->get('soloistQuality'), 5, 'the global pref stays 5');
    is($prefs->client($client)->get('soloistQualityRejectCount'), $CAP, 'soloistQualityRejectCount == cap');
    ok(!$prefs->client($client)->get('soloistQualityInitialised'), 'soloistQualityInitialised stays unset');
};

subtest 'ca5-5: (CTX-7) an existing player (Initialised 1, no new flag) is written ONCE after the update, even when the server already holds the wish' => sub {
    reset_all();
    $prefs->set('soloistQuality', 5);

    # (a) server already holds the wish: the unconditional write still happens
    my $mac = '00:AA:CA:05:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'player-ca5-5a');
    $prefs->client($client)->set('soloistQualityInitialised', 1);
    $prefs->client($client)->set('soloistQualityPending', 0);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-5 (a)');
    my ($r, $w) = req_counts();
    is($w, 1, '(a) exactly one write after the update (one-off exception to D-12), although the server holds 5');
    is($r, 1, '(a) one read: the read-back');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), '(a) VerifiedPaired is 1');
    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    $Q->onLoginFlank($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, '(a) the second flank sends zero requests');

    # (b) the coffee shape: server 2, wish 5
    my $mac2 = '00:AA:CA:05:00:02';
    write_device_id($mac2);
    pair_device($mac2);
    my $client2 = MockClient->new($mac2, 'player-ca5-5b');
    $prefs->client($client2)->set('soloistQualityInitialised', 1);
    $prefs->client($client2)->set('soloistQualityPending', 0);
    @Slim::Networking::SimpleAsyncHTTP::requests   = ();
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));

    $Q->onLoginFlank($mac2);
    assert_cb_ok('ca5-5 (b)');
    ($r, $w) = req_counts();
    is($w, 1, '(b) server 2, wish 5: exactly one write');
    is($prefs->client($client2)->get('soloistQualityVerifiedPaired'), vdev($client2), '(b) VerifiedPaired is 1');
};

subtest 'ca5-6: (CTX-5) a global change marks offline players without own level pending; they catch up when online' => sub {
    reset_all();
    my $p  = '00:AA:CA:06:00:01';
    my $o1 = '00:AA:CA:06:00:02';
    my $o2 = '00:AA:CA:06:00:03';
    write_device_id($p);
    pair_device($p);
    MockClient->new($p, 'player-ca5-6p');
    for my $o ($o1, $o2) {
        $prefs->client($o)->set('soloistQualityVerifiedPaired', 1);
        $prefs->client($o)->set('soloistQualityPending', 0);
    }
    $prefs->client($o2)->set('soloistQuality', 4);
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('ca5-6 (applyChange)');
    is($prefs->client($o1)->get('soloistQualityPending'), 1, 'offline player following global: Pending 1');
    is($prefs->client($o2)->get('soloistQualityPending'), 0, 'offline player with an own level: Pending stays 0');

    write_device_id($o1);
    pair_device($o1);
    my $c1 = MockClient->new($o1, 'player-ca5-6o1');
    @Slim::Networking::SimpleAsyncHTTP::requests   = ();
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));
    $Q->onLoginFlank($o1);
    assert_cb_ok('ca5-6 (catch-up)');
    my (undef, $w) = req_counts();
    is($w, 1, 'the player coming online writes once');
    is($prefs->client($c1)->get('soloistQualityPending'), 0, 'catch-up: Pending 0');
    is($prefs->client($c1)->get('soloistQualityVerifiedPaired'), vdev($c1), 'catch-up: VerifiedPaired 1');
};

subtest 'ca5-7: reconcile is serial across players' => sub {
    reset_all();
    my @macs = ('00:AA:CA:07:00:01', '00:AA:CA:07:00:02');
    my @clients;
    for my $m (@macs) { write_device_id($m); pair_device($m); push @clients, MockClient->new($m, "player-ca5-7-$m"); }
    $prefs->set('soloistQuality', 5);
    @Slim::Networking::SimpleAsyncHTTP::read_queue = map { build_content($_) } (5, 5);
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->onLoginFlank($macs[0]);
    $Q->onLoginFlank($macs[1]);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::pending), 1, 'exactly one request in flight after two flanks');

    my $answered = 0;
    while (Slim::Networking::SimpleAsyncHTTP::complete_next()) {
        $answered++;
        last if $answered > 30;
        ok(scalar(@Slim::Networking::SimpleAsyncHTTP::pending) <= 1, "after answer $answered at most one request is in flight");
    }
    my (undef, $w) = req_counts();
    is($w, 2, 'both players get their write');
    is($Plugins::SpotOn::API::SpClient::max_inflight, 1, 'the gate never held two Quality requests at once');
    is($prefs->client($_)->get('soloistQualityVerifiedPaired'), vdev($_), 'VerifiedPaired carries the device id for ' . $_->name) for @clients;
};

subtest 'ca5-8: pairing state unknown (undef) never writes and never verifies' => sub {
    reset_all();
    my $mac = '00:AA:CA:08:00:01';
    write_device_id($mac);
    pair_device($mac);    # the folder exists, but isPairedForClient answers undef (opendir failed)
    (my $clean = $mac) =~ s/://g;
    $Plugins::SpotOn::Soloist::paired_unknown{$clean} = 1;
    my $client = MockClient->new($mac, 'player-ca5-8');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(2);

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-8');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'unknown pairing state: no request at all');
    ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), 'unknown pairing state: VerifiedPaired stays unset');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'unknown pairing state: Pending 1');
};

subtest 'ca5-9: (W2) a flank that finds the device unpaired retries at most LOGIN_RETRY_MAX times, at the set waits' => sub {
    reset_all();
    my $mac = '00:AA:CA:09:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-ca5-9');
    $prefs->set('soloistQuality', 5);
    ok($Q->can('onLoginFlank'), 'Quality offers onLoginFlank');
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));
    # the pairing folder shows up between the first attempt and the first retry
    @Slim::Utils::Timers::hooks = (undef, sub { pair_device($mac) });

    $Q->onLoginFlank($mac) if $Q->can('onLoginFlank');
    assert_cb_ok('ca5-9 (flank, pairing appears between two attempts)');
    my ($r, $w) = req_counts();
    is($w, 1, 'exactly one write once the pairing shows up');
    is($r, 1, 'one read: the read-back (the unpaired attempt posted nothing)');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'VerifiedPaired carries the device id');
    my $READBACK = 1;    # READBACK_DELAY_S
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, $WAIT, $READBACK ],
        'timers: the settle wait, one retry wait, then the read-back delay of the write -- exactly the set values');

    # A device that never gets paired: no request, the settle wait plus LOGIN_RETRY_MAX retries.
    my $mac2 = '00:AA:CA:09:00:02';
    write_device_id($mac2);
    my $client2 = MockClient->new($mac2, 'player-ca5-9b');
    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    Slim::Utils::Timers::reset_timers();
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(2);
    $Q->onLoginFlank($mac2) if $Q->can('onLoginFlank');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a never-paired device: no request at all');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, ($WAIT) x $RETRY ],
        'a never-paired device: the settle wait plus LOGIN_RETRY_MAX retries at the set wait, then it stops');
    is($prefs->client($client2)->get('soloistQualityPending'), 1, 'a never-paired device stays Pending');
};

subtest 'ca5-10: (W3) a rejection on an unconfirmed device never resets the global pref (applyChange path)' => sub {
    reset_all();
    my $mac = '00:AA:CA:10:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-ca5-10');
    $prefs->set('soloistQuality', 5);    # Settings.pm stores the new value before it calls applyChange

    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);

    $Q->applyChange(scope => 'global', level => 5);
    assert_cb_ok('ca5-10');
    my (undef, $w) = req_counts();
    is($w, 1, 'exactly one write');
    is($prefs->get('soloistQuality'), 5, 'the global pref STAYS 5');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'Pending 1');
    my $notice = $Q->noticeFor($mac) || {};
    is($notice->{kind}, 'rejected', 'notice kind is rejected');
    is($notice->{wanted}, 5, 'notice wanted 5');
    is($notice->{effective}, 3, 'notice effective 3');
};

subtest 'ca5-11: (R1) the server already reads the wish and the daemon still plays 160k: the paired, logged-in flank writes anyway' => sub {
    reset_all();
    my $mac = '00:AA:CA:11:00:01';
    write_device_id($mac);
    my $client = MockClient->new($mac, 'player-ca5-11');
    $prefs->set('soloistQuality', 5);
    # the rig shape: GetDeviceSettings says 5 although the daemon never got the push
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Q->onLoginFlank($mac);    # not paired yet
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'not paired: nothing posted');

    pair_device($mac);
    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-11');
    my @w = grep { $_->{url} =~ m{/WriteDeviceValue$} } @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@w), 1, 'exactly one write although the server already reads the wish');
    is(scalar(grep { $_->{url} =~ m{/GetDeviceSettings$} } @Slim::Networking::SimpleAsyncHTTP::requests), 1,
        'the only read is the read-back AFTER the write');
    my $firstUrl = $Slim::Networking::SimpleAsyncHTTP::requests[0]{url} // '';
    like($firstUrl, qr{/WriteDeviceValue$}, 'the first request is the write (no read first)');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'VerifiedPaired is set only after the verified write');
};

# ============================================================
# R2 (Nachbesserung 2026-11-12, review 261112-ca5-REVIEW.md)
# ============================================================
my $UA    = '11111111-1111-4111-8111-111111111111';
my $UB    = '22222222-2222-4222-8222-222222222222';

# writes_to($uuid) -> the recorded WriteDeviceValue requests addressed to this device
sub writes_to {
    my ($uuid) = @_;
    return grep { $_->{url} =~ m{/WriteDeviceValue$} && uuid_in_body($_, $uuid) } @Slim::Networking::SimpleAsyncHTTP::requests;
}

subtest 'ca5-12: (WR-01) a lost answer frees the SAME player again after RECONCILE_STALE_S; the late answer of the abandoned run leaves the queue alone' => sub {
    reset_all();
    my ($mA, $mB) = ('00:AA:CA:12:00:01', '00:AA:CA:12:00:02');
    write_device_id($mA, $UA);
    write_device_id($mB, $UB);
    pair_device($_) for ($mA, $mB);
    MockClient->new($mA, 'p-ca5-12a');
    MockClient->new($mB, 'p-ca5-12b');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->onLoginFlank($mA);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::pending), 1, 'run 1 of A is in flight (its answer stays out for now)');

    $Q->onLoginFlank($mA);
    is(scalar(writes_to($UA)), 1, 'inside the stale limit the same player is NOT queued a second time');

    $Time::HiRes::clock += $STALE + 1;
    $Q->onLoginFlank($mA);
    is(scalar(writes_to($UA)), 2, 'after the stale limit the same player is reconciled again (run 2)');

    $Q->onLoginFlank($mB);    # queued behind run 2
    is(scalar(writes_to($UB)), 0, 'B waits behind the running run 2');

    # FIFO: P1 = write A run 1, P2 = write A run 2 -> their read-backs P3 (run 1), P4 (run 2) follow
    Slim::Networking::SimpleAsyncHTTP::complete_next() for 1 .. 2;
    Slim::Networking::SimpleAsyncHTTP::complete_next();    # P3: read-back of the abandoned run 1
    is(scalar(writes_to($UB)), 0, 'the late answer of the abandoned run does not start B (generation check)');
    Slim::Networking::SimpleAsyncHTTP::complete_next();    # P4: read-back of run 2
    ok(scalar(writes_to($UB)) >= 1, 'run 2 finishing starts B');
};

subtest 'ca5-13: (WR-08) one player enqueued three times is reconciled once while its first run is open' => sub {
    reset_all();
    my $mA = '00:AA:CA:13:00:01';
    write_device_id($mA, $UA);
    pair_device($mA);
    MockClient->new($mA, 'p-ca5-13');
    $prefs->set('soloistQuality', 5);
    # a rejecting device keeps the reconcile open: only the dedupe mark can stop runs 2 and 3
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->onLoginFlank($mA) for 1 .. 3;
    my $guard = 0;
    $guard++ while Slim::Networking::SimpleAsyncHTTP::complete_next() && $guard < 30;
    is(scalar(writes_to($UA)), 1, 'exactly one write for three enqueues of the same player');
};

subtest 'ca5-14: (WR-08) a queued player that was verified meanwhile is not written (re-check at dequeue)' => sub {
    reset_all();
    my ($mA, $mB) = ('00:AA:CA:14:00:01', '00:AA:CA:14:00:02');
    write_device_id($mA, $UA);
    write_device_id($mB, $UB);
    pair_device($_) for ($mA, $mB);
    MockClient->new($mA, 'p-ca5-14a');
    my $cB = MockClient->new($mB, 'p-ca5-14b');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->onLoginFlank($mA);
    $Q->onLoginFlank($mB);    # queued behind A
    $prefs->client($cB)->set('soloistQualityVerifiedPaired', vdev($cB));    # closed meanwhile (e.g. a user change)
    $prefs->client($cB)->set('soloistQualityPending', 0);
    my $guard = 0;
    $guard++ while Slim::Networking::SimpleAsyncHTTP::complete_next() && $guard < 30;
    is(scalar(writes_to($UA)), 1, 'A is written');
    is(scalar(writes_to($UB)), 0, 'B, closed while it waited, is not written');
};

subtest 'ca5-15: (WR-08) the rejection cap is lifted by a user change (client scope, global scope, offline players) and by a verified write' => sub {
    reset_all();
    my ($mC, $mF, $mO, $mV) = ('00:AA:CA:15:00:01', '00:AA:CA:15:00:02', '00:AA:CA:15:00:03', '00:AA:CA:15:00:04');
    write_device_id($mC);
    write_device_id($mF);
    my $cC = MockClient->new($mC, 'p-ca5-15c');
    my $cF = MockClient->new($mF, 'p-ca5-15f');
    $prefs->client($cC)->set('soloistQuality', 4);    # own level
    $prefs->set('soloistQuality', 5);
    $prefs->client($_)->set('soloistQualityRejectCount', $CAP) for ($cC, $cF);
    $prefs->client($mO)->set('soloistQualityRejectCount', $CAP);    # offline, follows global
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';       # transient: nothing but the reset touches the count
    $Slim::Networking::SimpleAsyncHTTP::write_error = '503 Service Unavailable';

    $Q->applyChange(scope => 'client', client => $cC, level => 4);
    is($prefs->client($cC)->get('soloistQualityRejectCount'), 0, 'applyChange(client) lifts the cap of that player');
    is($prefs->client($cF)->get('soloistQualityRejectCount'), $CAP, '... and leaves the others alone');

    $Q->applyChange(scope => 'global', level => 5);
    is($prefs->client($cF)->get('soloistQualityRejectCount'), 0, 'applyChange(global) lifts the cap of an online follower');
    is($prefs->client($mO)->get('soloistQualityRejectCount'), 0, 'applyChange(global) lifts the cap of an offline follower');
    is($prefs->client($mO)->get('soloistQualityPending'), 1, '... and marks it Pending');

    # a verified write lifts it as well
    reset_all();
    write_device_id($mV);
    pair_device($mV);
    my $cV = MockClient->new($mV, 'p-ca5-15v');
    $prefs->set('soloistQuality', 5);
    $prefs->client($cV)->set('soloistQualityRejectCount', $CAP - 1);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Q->onLoginFlank($mV);
    is($prefs->client($cV)->get('soloistQualityVerifiedPaired'), vdev($cV), 'precondition: the write was verified');
    is($prefs->client($cV)->get('soloistQualityRejectCount'), 0, 'a verified write resets the rejection count');
};

subtest 'ca5-16: (WR-02) the wish is formed when the player is written, not when it was queued' => sub {
    reset_all();
    my ($mA, $mB) = ('00:AA:CA:16:00:01', '00:AA:CA:16:00:02');
    write_device_id($mA, $UA);
    write_device_id($mB, $UB);
    pair_device($_) for ($mA, $mB);
    MockClient->new($mA, 'p-ca5-16a');
    MockClient->new($mB, 'p-ca5-16b');
    $prefs->set('soloistQuality', 5);
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5), build_content(3));
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->onLoginFlank($mA);
    $Q->onLoginFlank($mB);    # queued with the wish 5 ...
    $prefs->set('soloistQuality', 3);    # ... the user chooses 3 while A is still on the wire
    my $guard = 0;
    $guard++ while Slim::Networking::SimpleAsyncHTTP::complete_next() && $guard < 30;
    my ($wA) = writes_to($UA);
    my ($wB) = writes_to($UB);
    is($wA->{body}, $Q->_encodeWrite($UA, 'p-ca5-16a', 5), 'A, already on the wire, carries 5');
    is($wB->{body}, $Q->_encodeWrite($UB, 'p-ca5-16b', 3), 'B carries the CURRENT wish 3');
};

subtest 'ca5-17: (WR-07) the flag is bound to the device id; a new .device_id is reconciled again' => sub {
    reset_all();
    my $mac = '00:AA:CA:17:00:01';
    my $uuid1 = write_device_id($mac, $UA);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-17');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Q->onLoginFlank($mac);
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), $UA, 'the flag carries the device id');
    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    $Q->onLoginFlank($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'same device id: no request');

    write_device_id($mac, $UB);    # the data folder was set aside: a NEW device the server has never seen
    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    $Q->onLoginFlank($mac);
    is(scalar(writes_to($UB)), 1, 'a new device id is written once');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), $UB, 'the flag now carries the new device id');

    # a flag value without a device id (an interim build stored 1) costs one write, then it is bound
    $prefs->client($client)->set('soloistQualityVerifiedPaired', 1);
    $prefs->client($client)->set('soloistQualityPending', 0);
    @Slim::Networking::SimpleAsyncHTTP::requests = ();
    $Q->onLoginFlank($mac);
    is(scalar(writes_to($UB)), 1, 'a legacy flag value 1 is reconciled once');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), $UB, '... and bound to the device id');
};

subtest 'ca5-18: (WR-03) the rejected notice records whether the pref was really reset' => sub {
    # (a) reconcile path: nothing is reset
    reset_all();
    my $mac = '00:AA:CA:18:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-18a');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);
    $Q->onLoginFlank($mac);
    my $n = $Q->noticeFor($mac) || {};
    is($n->{kind}, 'rejected', '(a) reconcile: notice kind rejected');
    ok(defined $n->{reset} && !$n->{reset}, '(a) reconcile: reset is defined and false (the pref was NOT reset)');
    is($prefs->get('soloistQuality'), 5, '(a) the pref stays 5');

    # (b) applyChange on a paired device: the pref IS reset
    reset_all();
    write_device_id($mac);
    pair_device($mac);
    $client = MockClient->new($mac, 'p-ca5-18b');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);
    $Q->applyChange(scope => 'global', level => 5);
    $n = $Q->noticeFor($mac) || {};
    is($prefs->get('soloistQuality'), 3, '(b) applyChange paired: the pref is reset to 3');
    is($n->{reset}, 1, '(b) applyChange paired: reset is 1');

    # (c) applyChange on an unpaired device: nothing is reset (a fresh player: the
    # data dir of $mac is paired by now)
    reset_all();
    $mac = '00:AA:CA:18:00:03';
    write_device_id($mac);
    $client = MockClient->new($mac, 'p-ca5-18c');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_content      = build_content(3);
    $Q->applyChange(scope => 'global', level => 5);
    $n = $Q->noticeFor($mac) || {};
    is($prefs->get('soloistQuality'), 5, '(c) applyChange unpaired: the pref stays 5');
    ok(defined $n->{reset} && !$n->{reset}, '(c) applyChange unpaired: reset is defined and false');
};

subtest 'ca5-19: (IN-04) a flank budget does not outlive a run that never started' => sub {
    reset_all();
    ok($Q->can('_flankRetriesFor'), 'Quality offers the test hook _flankRetriesFor');
    my $retries = sub { $Q->can('_flankRetriesFor') ? $Q->_flankRetriesFor($_[0]) : 'no-hook' };
    $prefs->set('soloistQuality', 5);

    my $m1 = '00:AA:CA:19:00:01';
    write_device_id($m1);
    MockClient->new($m1, 'p-ca5-19a');
    @Slim::Utils::Timers::hooks = (sub { delete $Slim::Player::Client::clients{$m1} });
    $Q->onLoginFlank($m1);
    is($retries->($m1), undef, 'the player vanished before the settle timer fired: no budget left');

    my $m2 = '00:AA:CA:19:00:02';
    write_device_id($m2);
    MockClient->new($m2, 'p-ca5-19b');
    @Slim::Utils::Timers::hooks = (sub { $prefs->set('backend', 'librespot') });
    $Q->onLoginFlank($m2);
    $prefs->set('backend', 'soloist');
    is($retries->($m2), undef, 'the backend changed before the timer fired: no budget left');

    my $m3 = '00:AA:CA:19:00:03';
    write_device_id($m3);
    my $c3 = MockClient->new($m3, 'p-ca5-19c');
    @Slim::Utils::Timers::hooks = (sub {
        $prefs->client($c3)->set('soloistQualityVerifiedPaired', vdev($c3));
        $prefs->client($c3)->set('soloistQualityPending', 0);
    });
    $Q->onLoginFlank($m3);
    is($retries->($m3), undef, 'the reconcile closed before the timer fired: no budget left');
};

subtest 'ca5-20: (WR-01) a synchronous die inside a reconcile does not escape and does not block the queue' => sub {
    reset_all();
    my ($mA, $mB) = ('00:AA:CA:20:00:01', '00:AA:CA:20:00:02');
    write_device_id($mA, $UA);
    write_device_id($mB, $UB);
    pair_device($_) for ($mA, $mB);
    MockClient->new($mA, 'p-ca5-20a');
    MockClient->new($mB, 'p-ca5-20b');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

    $Plugins::SpotOn::Unified::DaemonManager::die_on_name = 1;
    my $lived = eval { $Q->onLoginFlank($mA); 1 };
    ok($lived, 'the die does not escape the occasion') or diag($@);
    $Plugins::SpotOn::Unified::DaemonManager::die_on_name = 0;

    $Q->onLoginFlank($mB);
    is(scalar(writes_to($UB)), 1, 'the queue is free right away: B is written without waiting for the stale limit');
};

subtest 'ca5-21: the reconcile writes the EFFECTIVE level: an own level beats global, an own Automatic is written too' => sub {
    reset_all();
    my @p = (
        [ '00:AA:CA:21:00:01', '33333333-3333-4333-8333-333333333333', 'p-ca5-21a', 4 ],
        [ '00:AA:CA:21:00:02', '44444444-4444-4444-8444-444444444444', 'p-ca5-21b', 0 ],
        [ '00:AA:CA:21:00:03', '55555555-5555-4555-8555-555555555555', 'p-ca5-21c', 'global' ],
    );
    $prefs->set('soloistQuality', 5);
    for my $x (@p) {
        my ($mac, $uuid, $name, $own) = @$x;
        write_device_id($mac, $uuid);
        pair_device($mac);
        my $c = MockClient->new($mac, $name);
        $prefs->client($c)->set('soloistQuality', $own);
        $Slim::Networking::SimpleAsyncHTTP::read_content = build_content($own eq 'global' ? 5 : $own);
        $Q->onLoginFlank($mac);
        my ($w) = writes_to($uuid);
        my $want = $own eq 'global' ? 5 : $own;
        is(($w || {})->{body}, $Q->_encodeWrite($uuid, $name, $want), "$name: the write carries level $want (own '$own', global 5)");
    }
};

# ============================================================
# R3 (Nachbesserung 2026-11-12, review 261112-ca5-REVIEW-2.md): BL-01, WR-01,
# WR-04. The three retry waits are PINNED here, never read back from the module.
# ============================================================
my @UNREACH   = (60, 300, 900);    # UNREACHABLE_RETRY_S
my $RATE_MIN  = 300;               # a 429-class failure never retries sooner than this

# set_login($mac, $mode) -- what the DaemonManager stub answers for this player.
sub set_login { $Plugins::SpotOn::Unified::DaemonManager::login_state{ $_[0] } = $_[1]; }

subtest 'ca5-22: (BL-01, WR-05) applyChange closes the reconcile only for a paired player whose OWN daemon is logged in' => sub {
    my @cases = (
        [ 'a: paired, no alive daemon at all',                          'none',   1, 0 ],
        [ 'b: paired, own daemon alive but not logged in',              'out',    1, 0 ],
        [ 'c: Sync slave, helperForClient falls back to the master',    'master', 1, 0 ],
        [ 'd: UNPAIRED, own daemon logged in',                          'own',    0, 0 ],
        [ 'e: paired, own daemon logged in (positive control)',         'own',    1, 1 ],
    );
    my $n = 0;
    for my $c (@cases) {
        my ($label, $mode, $paired, $closes) = @$c;
        reset_all();
        $n++;
        my $mac = sprintf('00:AA:CA:22:00:%02X', $n);
        write_device_id($mac);
        pair_device($mac) if $paired;
        my $client = MockClient->new($mac, "p-ca5-22-$n");
        set_login($mac, $mode);
        $prefs->set('soloistQuality', 5);
        $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);

        $Q->applyChange(scope => 'global', level => 5);
        assert_cb_ok("ca5-22 $label");
        my (undef, $w) = req_counts();
        is($w, 1, "$label: the change is written");
        if ($closes) {
            is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), "$label: the flag is closed");
            is($prefs->client($client)->get('soloistQualityPending'), 0, "$label: nothing pending");
            next;
        }
        ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), "$label: the flag stays OPEN (the push reached no logged-in daemon)");
        is($prefs->client($client)->get('soloistQualityPending'), 1, "$label: Pending is set");

        # the next flank of a logged-in daemon of this player writes by itself
        set_login($mac, 'own');
        pair_device($mac);
        Slim::Networking::SimpleAsyncHTTP::reset_stub();
        @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));
        $Q->onLoginFlank($mac);
        (undef, $w) = req_counts();
        is($w, 1, "$label: the later flank writes once");
        is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), "$label: and closes the flag");
    }
};

subtest 'ca5-23: (BL-01, probe b) a verified player stays reconcilable when a later change runs without a logged-in daemon' => sub {
    reset_all();
    my $mac = '00:AA:CA:23:00:01';
    my $uuid = write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-23');
    $prefs->set('soloistQuality', 5);
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(5));
    $Q->onLoginFlank($mac);
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'precondition: verified');

    set_login($mac, 'none');
    $prefs->set('soloistQuality', 3);
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(3);
    $Q->applyChange(scope => 'global', level => 3);
    assert_cb_ok('ca5-23 (change without a daemon)');
    is(scalar(writes_to($uuid)), 1, 'the change is written');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'Pending is set: nobody took the push');

    set_login($mac, 'own');
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    @Slim::Networking::SimpleAsyncHTTP::read_queue = (build_content(3));
    $Q->onLoginFlank($mac);
    my ($w) = writes_to($uuid);
    is(($w || {})->{body}, $Q->_encodeWrite($uuid, 'p-ca5-23', 3), 'the next flank writes the NEW level 3');
    is($prefs->client($client)->get('soloistQualityPending'), 0, 'and closes it');
};

subtest 'ca5-24: (WR-01) a transient failure of the write after the flank is retried at most three times (60/300/900 s), then it stops' => sub {
    reset_all();
    my $mac = '00:AA:CA:24:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-24');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-24');
    my (undef, $w) = req_counts();
    is($w, 1 + 3, 'one write after the flank plus three retries');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, @UNREACH ],
        'timers: the settle wait, then exactly the three retry waits, none after the last (no permanent timer)');
    is(scalar(@Plugins::SpotOn::API::SpClient::gate_calls), 4, 'every write goes through the spclient gate');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'Pending stays set');
    ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), 'the flag stays open');

    # a new flank is a new occasion with a fresh budget
    Slim::Utils::Timers::reset_timers();
    $Q->onLoginFlank($mac);
    (undef, $w) = req_counts();
    is($w, 8, 'the next flank writes again, with its own three retries');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, @UNREACH ], 'the same waits again');
};

subtest 'ca5-25: (WR-01) the retry that succeeds closes the reconcile and nothing is retried after it' => sub {
    reset_all();
    my $mac = '00:AA:CA:25:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-25');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'HTTP 503';
    @Slim::Utils::Timers::hooks = (undef, sub {
        $Slim::Networking::SimpleAsyncHTTP::write_mode   = 'success';
        $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    });

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-25');
    my (undef, $w) = req_counts();
    is($w, 2, 'the failed write and the one retry');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, $UNREACH[0], 1 ], 'timers: settle, the first retry wait, the read-back; no further retry');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'VerifiedPaired is set');
    is($prefs->client($client)->get('soloistQualityPending'), 0, 'Pending is cleared');

    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Q->onLoginFlank($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'a further flank posts nothing');
};

subtest 'ca5-26: (WR-01) a 429-class failure (gate lock, login5 throttle) waits at least 300 s and posts nothing inside the lock' => sub {
    reset_all();
    my $mac = '00:AA:CA:26:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-26');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::SpClient::gate_mode = 'blocked';
    @Slim::Utils::Timers::hooks = (undef, sub {
        $Plugins::SpotOn::API::SpClient::gate_mode       = 'pass';
        $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    });

    $Q->onLoginFlank($mac);
    assert_cb_ok('ca5-26 (gate lock)');
    my ($r, $w) = req_counts();
    is($w, 1, 'one HTTP write only: the first attempt was stopped by the gate, no HTTP');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, $RATE_MIN, 1 ], 'timers: settle, a 300 s wait (not 60), the read-back');
    is(scalar(@Plugins::SpotOn::API::SpClient::gate_calls), 3, 'blocked write, retried write, read-back: all through the gate');
    is($prefs->client($client)->get('soloistQualityVerifiedPaired'), vdev($client), 'the retry after the lock closes the reconcile');

    # login5 throttle: the same minimum
    reset_all();
    my $mac2 = '00:AA:CA:26:00:02';
    write_device_id($mac2);
    pair_device($mac2);
    MockClient->new($mac2, 'p-ca5-26b');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'throttled';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { throttled => 1 };
    @Slim::Utils::Timers::hooks = (undef, sub { $Plugins::SpotOn::API::Login5::mock_fail_reason = undef; $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5); });
    $Q->onLoginFlank($mac2);
    is($Slim::Utils::Timers::scheduled[1], $RATE_MIN, 'login5 throttle: the first retry waits 300 s as well');
};

subtest 'ca5-27: (WR-01, BL-01) a retry (and a flank attempt) is dropped when the player has no logged-in daemon of its own any more' => sub {
    reset_all();
    my $mac = '00:AA:CA:27:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-27');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
    @Slim::Utils::Timers::hooks = (undef, sub { set_login($mac, 'out') });

    $Q->onLoginFlank($mac);
    my (undef, $w) = req_counts();
    is($w, 1, 'the daemon logged out before the retry: the retry posts nothing');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, $UNREACH[0] ], 'no further retry is scheduled');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'Pending stays set for the next flank');

    reset_all();
    my $mac2 = '00:AA:CA:27:00:02';
    write_device_id($mac2);
    pair_device($mac2);
    MockClient->new($mac2, 'p-ca5-27b');
    $prefs->set('soloistQuality', 5);
    @Slim::Utils::Timers::hooks = (sub { set_login($mac2, 'none') });
    $Q->onLoginFlank($mac2);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'no daemon at the first attempt: nothing is posted');
};

subtest 'ca5-28: (WR-04) a rejected write whose read-back fails counts against the cap; no empty rejected notice' => sub {
    reset_all();
    my $mac = '00:AA:CA:28:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-28');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::read_error = 'Connection refused';

    $Q->onLoginFlank($mac) for 1 .. 10;
    my (undef, $w) = req_counts();
    is($w, $CAP, 'ten flanks write at most RECONCILE_REJECT_CAP times');
    is($prefs->client($client)->get('soloistQualityRejectCount'), $CAP, 'the rejections were counted');
    isnt(($Q->noticeFor($mac) || {})->{kind}, 'rejected', 'no value-less rejected notice');

    # the read-back is refused semantically as well
    reset_all();
    my $mac2 = '00:AA:CA:28:00:02';
    write_device_id($mac2);
    pair_device($mac2);
    my $client2 = MockClient->new($mac2, 'p-ca5-28b');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_grpc_status  = 7;
    $Q->onLoginFlank($mac2);
    my $notice = $Q->noticeFor($mac2) || {};
    ok($notice->{kind} ne 'rejected' || defined $notice->{wanted}, 'a double refusal leaves no rejected notice without wanted/effective')
        or diag(explain($notice));
    is($prefs->client($client2)->get('soloistQualityRejectCount'), 1, 'and it is counted once');

    # the settings path never counts
    reset_all();
    my $mac3 = '00:AA:CA:28:00:03';
    write_device_id($mac3);
    pair_device($mac3);
    my $client3 = MockClient->new($mac3, 'p-ca5-28c');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_grpc_status = 7;
    $Slim::Networking::SimpleAsyncHTTP::read_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::read_error = 'Connection refused';
    $Q->applyChange(scope => 'global', level => 5);
    is($prefs->client($client3)->get('soloistQualityRejectCount') || 0, 0, 'applyChange does not count against the reconcile cap');
};

# ============================================================
# WR-05 (R3): the conditions the reviewer's mutations of e86aed6b left alive.
# (The condition of _markVerified is pinned by ca5-22.)
# ============================================================
subtest 'ca5-29: (WR-05) no flank attempt for another backend; a switch away from Soloist during a wait stops the attempt' => sub {
    reset_all();
    my $mac = '00:AA:CA:29:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-29');
    $prefs->set('soloistQuality', 5);

    $prefs->set('backend', 'librespot');
    $Q->onLoginFlank($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'librespot backend: the flank posts nothing');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [], 'librespot backend: not even a settle timer is armed');
    $Q->onDaemonReady($mac);
    ok(!$prefs->client($client)->get('soloistQualityPending'), 'librespot backend: onDaemonReady does not mark Pending either');

    # the backend changes while the settle timer waits
    $prefs->set('backend', 'soloist');
    Slim::Utils::Timers::reset_timers();
    @Slim::Utils::Timers::hooks = (sub { $prefs->set('backend', 'librespot') });
    $Q->onLoginFlank($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'switched to librespot during the settle wait: nothing is posted');

    # ... and while the retry timer waits
    $prefs->set('backend', 'soloist');
    Slim::Utils::Timers::reset_timers();
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
    @Slim::Utils::Timers::hooks = (undef, sub { $prefs->set('backend', 'librespot') });
    $Q->onLoginFlank($mac);
    my (undef, $w) = req_counts();
    is($w, 1, 'switched to librespot during the retry wait: only the first write was posted');
};

subtest 'ca5-30: (WR-05) the stale limit of the queue is exactly RECONCILE_STALE_S: not yet at 119 s, free at 120 s' => sub {
    reset_all();
    my $mac = '00:AA:CA:30:00:01';
    write_device_id($mac, $UA);
    pair_device($mac);
    MockClient->new($mac, 'p-ca5-30');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Slim::Networking::SimpleAsyncHTTP::defer = 1;

    $Q->onLoginFlank($mac);
    is(scalar(writes_to($UA)), 1, 'run 1 is in flight, its answer stays out');
    $Time::HiRes::clock += $STALE - 1;
    $Q->onLoginFlank($mac);
    is(scalar(writes_to($UA)), 1, 'at 119 s the same player is NOT queued again');
    $Time::HiRes::clock += 1;
    $Q->onLoginFlank($mac);
    is(scalar(writes_to($UA)), 2, 'at 120 s the same player is reconciled again');
};

subtest 'ca5-31: (WR-05) a run that reports back twice starts the next player only once' => sub {
    reset_all();
    my (@started, @dones);
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Quality::_reconcileOne = sub {
            my ($class, $mac, $done) = @_;
            push @started, $mac;
            push @dones, $done;
        };
        $Q->_enqueueReconcile($_) for ('A', 'B', 'C');
        is_deeply([ @started ], ['A'], 'only A runs, B and C wait');
        $dones[0]->();
        is_deeply([ @started ], [ 'A', 'B' ], 'A reports back: B starts');
        $dones[0]->();
        is_deeply([ @started ], [ 'A', 'B' ], 'A reports back a second time: C does NOT start while B still runs');
        $dones[1]->();
        is_deeply([ @started ], [ 'A', 'B', 'C' ], 'B reports back: C starts');
    }
    $Q->_resetReconcileQueue;
};

subtest 'ca5-32: (WR-01) the retry state does not outlive the occasion it belongs to' => sub {
    reset_all();
    ok($Q->can('_unreachableTriesFor'), 'Quality offers the test hook _unreachableTriesFor');
    my $tries = sub { $Q->can('_unreachableTriesFor') ? $Q->_unreachableTriesFor($_[0]) : 'no-hook' };

    # (a) a retry waits for its timer; a verified settings change closes the reconcile meanwhile
    my $m1 = '00:AA:CA:32:00:01';
    write_device_id($m1);
    pair_device($m1);
    MockClient->new($m1, 'p-ca5-32a');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
    $Slim::Utils::Timers::hold_min = 60;
    $Q->onLoginFlank($m1);
    is($tries->($m1), 1, 'the failed write used one retry');
    is(scalar(@Slim::Utils::Timers::held), 1, 'one retry timer waits');
    $Slim::Networking::SimpleAsyncHTTP::write_mode   = 'success';
    $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    $Q->applyChange(scope => 'global', level => 5);
    is($tries->($m1), undef, 'the verified change dropped the retry budget');
    is_deeply([ @Slim::Utils::Timers::killed ], [ @Slim::Utils::Timers::held ], 'and killed the waiting retry timer');

    # (b) the retry timer fires after the player is gone
    reset_all();
    my $m2 = '00:AA:CA:32:00:02';
    write_device_id($m2);
    pair_device($m2);
    MockClient->new($m2, 'p-ca5-32b');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
    $Slim::Utils::Timers::hold_min = 60;
    $Q->onLoginFlank($m2);
    is($tries->($m2), 1, 'the failed write used one retry');
    delete $Slim::Player::Client::clients{$m2};
    $Slim::Utils::Timers::held[0]->();
    is($tries->($m2), undef, 'the retry that no longer applies leaves no budget behind');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1, 'and posts nothing');
};

# ============================================================
# R4 (REVIEW-3): WR-01 the login guard must not fail silently; WR-02 a transient
# login5 minting failure is retried like any other transient failure.
# ============================================================

# log_lines($re) -> the captured log lines matching $re.
sub log_lines { my ($re) = @_; return grep { $_ =~ $re } @Slim::Utils::Log::logged; }

subtest 'ca5-33: (R4 WR-01 a, d) an error inside the login guard is logged and fails closed: no request, no die' => sub {
    my $n = 0;
    for my $c ([ 'ws_dies', qr/_ws is gone/ ], [ 'state_bad', qr/Can't use string/ ]) {
        my ($mode, $why) = @$c;
        reset_all();
        $n++;
        my $mac = sprintf('00:AA:CA:33:00:%02X', $n);
        write_device_id($mac);
        pair_device($mac);
        my $client = MockClient->new($mac, "p-ca5-33-$n");
        set_login($mac, $mode);
        $prefs->set('soloistQuality', 5);

        my $lived = eval { $Q->onLoginFlank($mac); 1 };
        ok($lived, "$mode: the broken access does not escape the occasion") or diag($@);
        is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, "$mode: fail closed, nothing is posted");
        ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), "$mode: the flag stays open");
        my @l = log_lines(qr/login state of \Q$mac\E unknown: /);
        is(scalar(@l), 1, "$mode: the error of the guard is logged once, naming the player")
            or diag(join "\n", @Slim::Utils::Log::logged);
        like($l[0] // '', $why, "$mode: and carries the reason (\$@), not just 'unknown'");
    }

    # a missing daemon is a normal state, not an error: no 'unknown' line
    reset_all();
    my $mac = '00:AA:CA:33:00:09';
    write_device_id($mac);
    pair_device($mac);
    MockClient->new($mac, 'p-ca5-33-none');
    set_login($mac, 'none');
    $prefs->set('soloistQuality', 5);
    $Q->onLoginFlank($mac);
    is(scalar(log_lines(qr/login state of .* unknown/)), 0, 'no daemon: no error line (it is a state, not a failure)');
};

subtest 'ca5-34: (R4 WR-01 b) a flank attempt dropped for want of a login leaves an INFO line "skipped_no_login"' => sub {
    my $n = 0;
    for my $mode ('none', 'out', 'master') {
        reset_all();
        $n++;
        my $mac = sprintf('00:AA:CA:34:00:%02X', $n);
        write_device_id($mac);
        pair_device($mac);
        MockClient->new($mac, "p-ca5-34-$n");
        set_login($mac, $mode);
        $prefs->set('soloistQuality', 5);
        $Q->onLoginFlank($mac);
        is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, "$mode: nothing posted");
        my @l = log_lines(qr/^SpotOn quality reconcile \(mac=\Q$mac\E\): .* -> skipped_no_login$/);
        is(scalar(@l), 1, "$mode: one 'skipped_no_login' line in the usual reconcile line shape")
            or diag(join "\n", @Slim::Utils::Log::logged);
    }

    # the retry that finds the daemon gone says so as well
    reset_all();
    my $mac = '00:AA:CA:34:00:09';
    write_device_id($mac);
    pair_device($mac);
    MockClient->new($mac, 'p-ca5-34-retry');
    $prefs->set('soloistQuality', 5);
    $Slim::Networking::SimpleAsyncHTTP::write_mode  = 'error';
    $Slim::Networking::SimpleAsyncHTTP::write_error = 'Connection refused';
    @Slim::Utils::Timers::hooks = (undef, sub { set_login($mac, 'out') });
    $Q->onLoginFlank($mac);
    is(scalar(log_lines(qr/mac=\Q$mac\E\): .* -> skipped_no_login$/)), 1, 'retry without a login: the drop is visible too');

    # no line when the attempt is dropped for another reason, or when it writes
    reset_all();
    my ($mG, $mV, $mO) = ('00:AA:CA:34:00:0A', '00:AA:CA:34:00:0B', '00:AA:CA:34:00:0C');
    for ($mV, $mO) { write_device_id($_); pair_device($_); }
    MockClient->new($_, "p-ca5-34-$_") for ($mV, $mO);
    $prefs->set('soloistQuality', 5);
    set_login($_, 'out') for ($mG, $mV);
    # a verified player does not need a reconcile (D-12): its flank is no attempt at all
    my $cV = $Slim::Player::Client::clients{$mV};
    $prefs->client($cV)->set('soloistQualityVerifiedPaired', $Q->deviceIdForMac($mV));
    $Q->_attemptReconcile($mG);    # the player is gone
    $Q->_attemptReconcile($mV);    # nothing to reconcile
    $prefs->set('backend', 'librespot');
    $Q->_attemptReconcile($mO);    # another backend
    $prefs->set('backend', 'soloist');
    is(scalar(log_lines(qr/skipped_no_login/)), 0, 'gone player, closed reconcile, other backend: no skipped_no_login line');
    $Q->onLoginFlank($mO);
    is(scalar(log_lines(qr/skipped_no_login/)), 0, 'a logged-in daemon writes and logs no skipped_no_login');
    is(scalar(log_lines(qr/mac=\Q$mO\E\): .* -> write$/)), 1, 'but the usual write line');
};

subtest 'ca5-35: (R4 WR-02) a transient login5 failure while minting the token is retried (60/300/900 s) like any transient failure' => sub {
    reset_all();
    my $mac = '00:AA:CA:35:00:01';
    write_device_id($mac);
    pair_device($mac);
    my $client = MockClient->new($mac, 'p-ca5-35');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { transient => 1 };

    $Q->onLoginFlank($mac);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'no HTTP without a token');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, @UNREACH ],
        'timers: the settle wait, then the three retry waits; the first retry is NOT delayed to the 300 s throttle minimum');
    is(scalar(@Plugins::SpotOn::API::Login5::getToken_calls), 4, 'one token attempt after the flank plus three retries');
    is(scalar(@Plugins::SpotOn::API::SpClient::gate_calls), 4, 'every attempt goes through the spclient gate');
    is($prefs->client($client)->get('soloistQualityPending'), 1, 'Pending stays set');
    ok(!$prefs->client($client)->get('soloistQualityVerifiedPaired'), 'the flag stays open');
    is($Q->noticeFor($mac)->{kind}, 'unreachable', 'the notice says "unreachable", not "authorize playback first"');

    # the retry succeeds once the network is back
    reset_all();
    my $mac2 = '00:AA:CA:35:00:02';
    write_device_id($mac2);
    pair_device($mac2);
    my $client2 = MockClient->new($mac2, 'p-ca5-35b');
    $prefs->set('soloistQuality', 5);
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { transient => 1 };
    @Slim::Utils::Timers::hooks = (undef, sub {
        $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
        $Slim::Networking::SimpleAsyncHTTP::read_content = build_content(5);
    });
    $Q->onLoginFlank($mac2);
    assert_cb_ok('ca5-35 (retry after the network is back)');
    my (undef, $w) = req_counts();
    is($w, 1, 'the retry writes once');
    is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE, $UNREACH[0], 1 ], 'timers: settle, first retry wait, read-back; nothing further');
    is($prefs->client($client2)->get('soloistQualityVerifiedPaired'), vdev($client2), 'the reconcile is closed');
};

subtest 'ca5-36: (R4 WR-02) a token failure that is NOT transient stays no_token and is not retried' => sub {
    my $n = 0;
    for my $c (
        [ 'invalid_credentials, no detail', 'invalid_credentials', undef ],
        [ 'mint_failed, code 400',          'mint_failed',         { code => 400 } ],
        [ 'mint_failed, transient => 0',    'mint_failed',         { transient => 0 } ],
        [ 'mint_failed, empty detail',      'mint_failed',         {} ],
    ) {
        my ($label, $reason, $detail) = @$c;
        reset_all();
        $n++;
        my $mac = sprintf('00:AA:CA:36:00:%02X', $n);
        write_device_id($mac);
        pair_device($mac);
        my $client = MockClient->new($mac, "p-ca5-36-$n");
        $prefs->set('soloistQuality', 5);
        $Plugins::SpotOn::API::Login5::mock_fail_reason = $reason;
        $Plugins::SpotOn::API::Login5::mock_fail_detail = $detail;

        $Q->onLoginFlank($mac);
        is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, "$label: no HTTP");
        is_deeply([ @Slim::Utils::Timers::scheduled ], [ $SETTLE ], "$label: only the settle wait, no retry timer");
        is($Q->_unreachableTriesFor($mac), undef, "$label: no retry budget used");
        is($Q->noticeFor($mac)->{kind}, 'no_token', "$label: the notice stays no_token");
    }
};

$Time::HiRes::clock = undef;
done_testing();
