#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# 89-07: a controllable clock for the D-20 cells; unset, time() is the real clock.
# Installed before DaemonManager is required, so its time() calls see it.
our $FAKE_NOW;
BEGIN { *CORE::GLOBAL::time = sub () { defined $main::FAKE_NOW ? $main::FAKE_NOW : CORE::time() }; }

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Unified/DaemonManager.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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
# LMS module stubs required to load DaemonManager.pm in isolation.
# DaemonManager.pm has never had test coverage before this plan (71-02) --
# it is intentionally absent from t/05_perl_syntax.t's @pm_files because a
# straight `perl -c` against a real LMS checkout fails on JSON::XS's XS
# binary not being installed in this sandbox (pre-existing environment gap,
# unrelated to this plan -- see 71-02-SUMMARY.md). Full isolated `require`
# below is a strictly stronger check than `perl -c` since it also executes
# the module's top-level statements.
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

# Task 2 (73-01): backed by a package hash so tests can control arbitrary
# pref keys (e.g. 'backend', 'cachedir') without a bespoke stub per key.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( cachedir => '/tmp/spoton-test-cachedir' );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set      { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client   { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
# 89-02: in-memory store that also remembers the TTL of each set and appends
# every write to the shared call log main::CALLS (order of cache and ring writes).
our (%STORE, %TTL);
sub new    { return bless {}, shift }
sub get    { return $STORE{ $_[1] } }
sub set    { $STORE{ $_[1] } = $_[2]; $TTL{ $_[1] } = $_[3]; push @main::CALLS, 'cache:set:' . $_[1]; }
sub remove { delete $STORE{ $_[1] }; delete $TTL{ $_[1] }; push @main::CALLS, 'cache:remove:' . $_[1]; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub cstring { my ($client, $key) = @_; return $key }
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = \&cstring;
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
# Phase 82 Plan 44 (Revision 1): call-recording instead of a pure no-op --
# the new two-player isolation case below needs to inspect the
# $objRef argument each call was made with, which a bare no-op stub cannot
# provide.
# Phase 82 Plan 45 (WR-05, 82-REVIEW.md Zeile 109-110): @TIMERS added
# alongside the existing @KILL_CALLS/@SET_CALLS recorders -- both existing
# arrays keep pushing/filtering exactly as before (existing assertions
# unchanged) while @TIMERS additionally tracks live (objRef, when,
# coderef) entries so fire_due() can actually fire a registered timer.
# Identical idiom to t/30_soloist_daemon.t:192-215.
our @KILL_CALLS;
our @SET_CALLS;
our @TIMERS;
sub killTimers {
    push @KILL_CALLS, [@_];
    my ($obj, $cb) = @_;
    # Phase 82 Plan 45: 'eq', NOT '==' -- unlike t/30_soloist_daemon.t's
    # blessed-object $objRef (where '==' correctly compares identity via
    # address), DaemonManager.pm's package-level timers are keyed by plain
    # clientId strings (or the class name). Under '==', every non-numeric
    # MAC-like string numifies to 0, so '$_->[0] == $obj' would be TRUE for
    # every string objRef pair sharing a coderef -- killing one client's
    # timer would silently also kill every OTHER client's same-coderef
    # timer, exactly the cross-player leakage the existing Fall Isolation
    # (zwei Spieler) case already guards against for @KILL_CALLS via its
    # own 'eq'-based filter (see ~line 861 below).
    @TIMERS = grep { !($_->[0] eq $obj && $_->[2] == $cb) } @TIMERS;
}
sub setTimer {
    push @SET_CALLS, [@_];
    push @TIMERS, [@_];
}
sub fire_due {
    my ($now) = @_;
    my @due = grep { $_->[1] <= $now } @TIMERS;
    @TIMERS = grep { $_->[1] > $now } @TIMERS;
    for my $t (@due) {
        my ($obj, undef, $cb, @extra) = @$t;
        $cb->($obj, @extra);
    }
}
1;
END

# Stub: Slim::Networking::Select (Phase 83.3 plan 03: SoloistDaemon.pm now
# `use`s this at the top level for the D-06 smoke test's event-driven pipe
# read -- required for the module to load in this sandbox, even though this
# file never exercises smokeTest() itself)
write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
sub addRead    { }
sub removeRead { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
# 89-02: every GET is recorded (url + the two callbacks) so a cell answers it
# with a body, an error, or leaves it pending.
our @GETS;
sub new  { my ($c, $ok, $err, $opts) = @_; return bless { ok => $ok, err => $err, opts => $opts }, $c }
sub get  { my ($self, $url) = @_; push @GETS, { url => $url, ok => $self->{ok}, err => $self->{err}, opts => $self->{opts} }; return; }
sub post { }
package Slim::Networking::SimpleAsyncHTTP::Resp;
sub new     { return bless { body => $_[1] }, $_[0] }
sub content { return $_[0]{body} }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use JSON::PP ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { JSON::PP->new->utf8->canonical->encode($_[0]) };
    *{"${caller}::from_json"} = sub { JSON::PP->new->utf8->decode($_[0]) };
}
1;
END

# Task 2 (73-01): needed for the REAL Plugins::SpotOn::Soloist module (loaded
# below, not stubbed out) which `use`s this at compile time (_arch()).
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
1;
END

# Task 2 (73-01): needed for the REAL Plugins::SpotOn::Unified::SoloistDaemon
# module (isolated-require target below) which `use base qw(Slim::Utils::Accessor)`.
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
use Scalar::Util qw(weaken);
my %slot;
sub new { return bless [], shift }
sub mk_accessor {
    my ($class, $type, @names) = @_;
    no strict 'refs';
    for my $name (@names) {
        my $n = $slot{$class}{$name};
        if (!defined $n) {
            $n = keys %{ $slot{$class} };
            $slot{$class}{$name} = $n;
        }
        if ($type eq 'weak') {
            *{"${class}::${name}"} = sub {
                my $self = shift;
                if (@_) {
                    $self->[$n] = shift;
                    weaken($self->[$n]) if ref $self->[$n];
                }
                return $self->[$n];
            };
        }
        else {
            *{"${class}::${name}"} = sub {
                my $self = shift;
                $self->[$n] = shift if @_;
                return $self->[$n];
            };
        }
    }
}
1;
END

# Minimal stand-in -- DaemonManager.pm only needs the CACHE_VERSION constant
# and _pluginDataFor at load time. Task 2 (73-01): $FAKE_BASEDIR is settable
# per-test so ensureWsLib()'s vendor-fallback push resolves the REAL
# Plugins/SpotOn/Vendor tree (see the ensureWsLib block below).
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
our $FAKE_BASEDIR = 'test-basedir';
sub _pluginDataFor { return $FAKE_BASEDIR }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
# 74b WR-03: enough of a daemon for DaemonManager::startHelper to register one
# and for _streamAlivePoll to run its audio-key block against it. $TAIL is the
# stderr tail every instance reports; $ACCOUNT its account id; $HEALTH its
# last health snapshot (the GH #141 "actively streaming" input).
our $TAIL    = '';
our $ACCOUNT = 'ACCT0123456789abcdef';
our $HEALTH  = undef;
our $PORT    = undef;
sub new {
    my ($class, $mac) = @_;
    return bless { mac => $mac, alive => 1 }, $class;
}
# 84-08: DaemonManager keys its Soloist-only paths on backendName, not isa.
sub backendName { return 'librespot' }
sub mac                 { return $_[0]->{mac} }
sub alive               { return $_[0]->{alive} }
# 89 review WR-03: an instance key `pid` stands for a restart of the same object.
sub pid                 { return exists $_[0]{pid} ? $_[0]{pid} : 4242 }
sub name                { return undef }
sub _accountId          { return $ACCOUNT }
sub _streamPort         { return $PORT }
# 89-07: the instance keys `health` and `tail` (set by the sibling cells) win over the globals;
# every older cell sets neither key, so it reads $HEALTH and $TAIL exactly as before.
sub _lastHealthSession  { return exists $_[0]{health}? $_[0]{health} : $HEALTH }
sub stderrTail          { return exists $_[0]{tail} ? $_[0]{tail} : $TAIL }
sub _healthCheckCount   { my $s = shift; $s->{hc} = shift if @_; return $s->{hc} }
sub stop                { $_[0]->{alive} = 0; return }
1;
END

# 74b WR-03: _streamAlivePoll asks LMS for the player behind the daemon; no
# player here, so _isStreamActive falls back to the health snapshot.
BEGIN {
    package Slim::Player::Client;
    our %BY_MAC;
    sub getClient { return $BY_MAC{ $_[0] // '' } }
}

# Phase 82 Plan 45 (WR-05): required by _pendingTrackRequestTimeout's
# `require Plugins::SpotOn::Status; Status->recordError(...)` call -- without
# this stub, the eval{} around that call swallows a load failure of the REAL
# module and the RECORDED-array assertions below have nothing to check
# against. Copied verbatim from t/30_soloist_daemon.t:220-241.
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our @RECORDED;
sub recordError {
    my $class = shift;
    push @main::CALLS, 'ring:record:' . ($_[3] // '');
    push @RECORDED, [@_];
    shift @RECORDED while scalar @RECORDED > 30;
}
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;
    push @main::CALLS, 'ring:clear:' . $key;
    @RECORDED = grep {
        !(($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key)
    } @RECORDED;
}
sub hasError {
    my ($class, $module, $key, $level) = @_;
    return 0 unless defined $key;
    return scalar grep {
        ($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key
            && (!defined $level || ($_->[0] // '') eq $level)
    } @RECORDED;
}
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 1 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}
our $FAKE_ISWINDOWS = 0;
our $FAKE_ISMAC     = 0;
BEGIN {
    no warnings 'redefine';
    *main::ISWINDOWS   = sub () { $main::FAKE_ISWINDOWS };
    *main::ISMAC       = sub () { $main::FAKE_ISMAC };
}

# ============================================================
# 89-02 Task 2 (ACC-03, D-09): a refused audio key is filed under the account
# that is REALLY in the session. The helper's /health says who that is (a
# masked username plus its length); Perl compares it with the credentials.json
# username of the paired account (the A5 rule of SpClient::_username, never the
# prefs user id). Only a positive match gets the permanent 'never' entry; every
# other denial is a finite guest entry naming the player. REAL DaemonManager
# and Credentials over the stubs above.
# ============================================================

use Encode ();
use JSON::PP ();

$::VERSION = '9.0.0';
unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Unified::DaemonManager') or BAIL_OUT('DaemonManager.pm does not load');
require_ok('Plugins::SpotOn::Backend::Librespot')     or BAIL_OUT('Backend/Librespot.pm does not load');
require_ok('Plugins::SpotOn::API::Credentials')       or BAIL_OUT('Credentials.pm does not load');
require_ok('Plugins::SpotOn::Backend')                or BAIL_OUT('Backend.pm does not load');

our (@CALLS, @INFOS, @WARNS, %CREDS);
{
    no warnings 'redefine';
    *Slim::Utils::Log::info = sub { shift; push @INFOS, join('', @_); };
    *Slim::Utils::Log::warn = sub { shift; push @WARNS, join('', @_); };
    # A planted credentials.json: a key that exists answers (undef = no valid credentials),
    # any other account asks the real module.
    my $orig = \&Plugins::SpotOn::API::Credentials::verifyCredentials;
    *Plugins::SpotOn::API::Credentials::verifyCredentials = sub {
        my ($class, $acct) = @_;
        return $CREDS{$acct} if exists $CREDS{$acct};
        return $orig->(@_);
    };
}

{
    package FakeClient;
    sub new           { return bless { mac => $_[1], name => $_[2] }, $_[0] }
    sub id            { return $_[0]{mac} }
    sub name          { return $_[0]{name} }
    sub streamingSong { return undef }
    sub playingSong   { return undef }
    sub isPlaying     { return 0 }
    sub execute       { }
    sub showBriefly   { }
}

my $DM   = 'Plugins::SpotOn::Unified::DaemonManager';
my $acct = 'ACCT0123456789abcdef';
my $mac  = 'aa:bb:cc:dd:ee:80';
my $GUEST_KEY = "spoton_audiokey_guest_$mac";
my $STATE_KEY = "spoton_audiokey_state_$acct";

my @ALL;        # every text any scenario produced (cell no_full_id)

sub health_body {
    my (%f) = @_;
    return JSON::PP->new->utf8->canonical->encode({%f});
}
sub ring_for {
    my ($key) = @_;
    return grep { ($_->[1] // '') eq 'Connect' && ($_->[3] // '') eq $key } @Plugins::SpotOn::Status::RECORDED;
}
sub denial {
    my ($n) = @_;
    return sprintf("[2026-11-18T10:00:%02dZ ERROR librespot_core::audio_key] error audio key 0 1\n", $n);
}

{
    my $tmpCache = tempdir(CLEANUP => 1);
    make_path("$tmpCache/spoton/$acct");
    open(my $cf, '>', "$tmpCache/spoton/$acct/credentials.json") or die "credentials.json: $!";
    print $cf '{"username":"x"}';
    close($cf);

    local $Slim::Utils::Prefs::FAKE_VALUES{cachedir}      = $tmpCache;
    local $Slim::Utils::Prefs::FAKE_VALUES{activeAccount} = $acct;
    local $Slim::Utils::Prefs::FAKE_VALUES{accounts}      = { $acct => { displayName => 'x' } };
    local $Slim::Utils::Prefs::FAKE_VALUES{backend}       = 'librespot';

    my $client = FakeClient->new($mac, 'Kitchen');
    my $helper;

    my $fresh = sub {
        $DM->stopHelper($mac);
        %Slim::Utils::Cache::STORE = ();
        %Slim::Utils::Cache::TTL   = ();
        @Plugins::SpotOn::Status::RECORDED = ();
        @Slim::Networking::SimpleAsyncHTTP::GETS = ();
        @CALLS = (); @INFOS = (); @WARNS = ();
        %CREDS = ();
        $helper = $DM->startHelper($mac);
        $helper->_healthCheckCount(0);
        $Slim::Player::Client::BY_MAC{$mac} = $client;
        $Plugins::SpotOn::Unified::Daemon::PORT = 4242;
        return;
    };
    my $poll = sub {
        my ($tail) = @_;
        $helper->_healthCheckCount(0);      # never the 12th tick of the plain health probe
        local $Plugins::SpotOn::Unified::Daemon::TAIL = $tail;
        Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
        return;
    };
    my $harvest = sub {
        push @ALL, (map { $_->[2] // '' } @Plugins::SpotOn::Status::RECORDED), @WARNS, @INFOS,
                   (map { defined $_ ? $_ : '' } values %Slim::Utils::Cache::STORE);
        return;
    };
    my $answer = sub {
        my ($i, $body) = @_;
        my $g = $Slim::Networking::SimpleAsyncHTTP::GETS[$i];
        return 0 unless $g && $g->{ok};      # RED: no GET was made (also guards autovivified slots)
        if (defined $body) { $g->{ok}->(Slim::Networking::SimpleAsyncHTTP::Resp->new($body)) }
        else               { $g->{err}->(Slim::Networking::SimpleAsyncHTTP::Resp->new(''), 'connection refused') }
        $harvest->();
        return 1;
    };
    my $isGuest = sub {
        my ($label) = @_;
        ok(exists $Slim::Utils::Cache::STORE{$GUEST_KEY}, "$label: guest key set");
        is($Slim::Utils::Cache::TTL{$GUEST_KEY}, 3600, "$label: guest key TTL 3600");
        ok(!exists $Slim::Utils::Cache::STORE{$STATE_KEY}, "$label: the paired key is untouched");
    };
    my $good = health_body(session_user => 'abcd****', session_user_len => 10, audio_key_denials => 5);

    # paired_match
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(1));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 1, 'paired_match: one GET after the denial line');
    is((@Slim::Networking::SimpleAsyncHTTP::GETS ? $Slim::Networking::SimpleAsyncHTTP::GETS[0]{url} : '') // '', 'http://127.0.0.1:4242/health', 'paired_match: the GET goes to 127.0.0.1 on the stream port');
    is((@Slim::Networking::SimpleAsyncHTTP::GETS ? $Slim::Networking::SimpleAsyncHTTP::GETS[0]{opts}{timeout} : undef), 5, 'paired_match: timeout 5');
    $answer->(0, $good);
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'paired_match: the paired account is denied');
    is($Slim::Utils::Cache::TTL{$STATE_KEY}, 'never', 'paired_match: with TTL never');
    ok(!exists $Slim::Utils::Cache::STORE{$GUEST_KEY}, 'paired_match: no guest key');
    my @e = ring_for("audiokey:$acct");
    is(scalar @e, 1, 'paired_match: one ring entry');
    is($e[0][0] // '', 'error', 'paired_match: level error');
    like($e[0][2] // '', qr/^Account ACCT\*\*\*\* cannot play with librespot: Spotify refuses its audio keys\. .+ \(AesKeyError 0x0001\)$/,
        'paired_match: the paired status text with the masked account id');
    my ($headline) = ($e[0][2] // '') =~ /^(.*?audio keys\.)/;
    cmp_ok(length($headline // ''), '<=', 80, 'paired_match: the headline sentence is at most 80 characters (status.html cuts at 80)');
    is(length($headline // ''), 76, 'paired_match: ... and is 76 characters for an 8-character mask');
    ok(scalar(grep { /filed as paired/ } @INFOS) == 1, 'paired_match: one INFO line, filed as paired');

    # a5_prefs_id_is_not_used
    $fresh->();
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{accounts} = { $acct => { spotifyUserId => 'abcdefgh12' } };
        $CREDS{$acct} = { username => 'zzzzyyyy99' };
        $poll->(denial(2));
        $answer->(0, $good);
        $isGuest->('a5_prefs_id_is_not_used (prefs id would match, credentials do not)');
    }
    $fresh->();
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{accounts} = { $acct => { spotifyUserId => 'qqqqqqqq' } };
        $CREDS{$acct} = { username => 'abcdefgh12' };
        $poll->(denial(3));
        $answer->(0, $good);
        is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'a5_prefs_id_is_not_used: credentials match, a different prefs id does not matter');
    }

    # no_credentials_is_guest
    $fresh->();
    $CREDS{$acct} = undef;
    $poll->(denial(4));
    $answer->(0, $good);
    $isGuest->('no_credentials_is_guest');

    # guest_other_prefix
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(5));
    $answer->(0, health_body(session_user => 'zzzz****', session_user_len => 10, audio_key_denials => 2));
    $isGuest->('guest_other_prefix');
    @e = ring_for("audiokey:guest:$mac");
    is(scalar @e, 1, 'guest_other_prefix: one warn entry keyed audiokey:guest:<mac>');
    is($e[0][0] // '', 'warn', 'guest_other_prefix: level warn');
    like($e[0][2] // '', qr/^Player Kitchen: account zzzz\*\*\*\* cannot play with librespot: Spotify refuses its audio keys\. .+ \(AesKeyError 0x0001\)$/,
        'guest_other_prefix: the guest-known text names the player and the masked guest');
    is(scalar(ring_for("audiokey:$acct")), 0, 'guest_other_prefix: no entry under the paired account');
    like(join("\n", @INFOS), qr/filed as guest \(zzzz\*\*\*\*\)/, 'guest_other_prefix: INFO line filed as guest with the masked token');

    # guest_same_prefix_other_length
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(6));
    $answer->(0, health_body(session_user => 'abcd****', session_user_len => 11, audio_key_denials => 2));
    $isGuest->('guest_same_prefix_other_length');

    # unknown_on_error
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(7));
    $answer->(0, undef);
    $isGuest->('unknown_on_error');
    @e = ring_for("audiokey:guest:$mac");
    like($e[0][2] // '', qr/^Player Kitchen: the account playing on it cannot play with librespot: /, 'unknown_on_error: the guest-unknown text');
    unlike($e[0][2] // '', qr/\*\*\*\*/, 'unknown_on_error: no mask token');
    like(join("\n", @INFOS), qr/filed as unknown(?! \()/, 'unknown_on_error: INFO line filed as unknown, no token');

    # the remaining unknowns
    my %bad = (
        unknown_on_missing_field => health_body(session_user => 'abcd****', audio_key_denials => 5),
        unknown_on_zero_denials  => health_body(session_user => 'abcd****', session_user_len => 10, audio_key_denials => 0),
        unknown_on_empty_user    => health_body(session_user => '', session_user_len => 0, audio_key_denials => 5),
        unknown_on_malformed     => '{not json',
        unknown_on_no_mask       => health_body(session_user => 'abcdefgh12', session_user_len => 10, audio_key_denials => 5),
        unknown_on_text_len      => health_body(session_user => 'abcd****', session_user_len => 'ten', audio_key_denials => 5),
    );
    my $n = 10;
    for my $name (sort keys %bad) {
        $fresh->();
        $CREDS{$acct} = { username => 'abcdefgh12' };
        $poll->(denial($n++));
        $answer->(0, $bad{$name});
        $isGuest->($name);
    }
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $Plugins::SpotOn::Unified::Daemon::PORT = undef;
    $poll->(denial(30));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 0, 'unknown_without_stream_port: no GET');
    $isGuest->('unknown_without_stream_port');

    # multibyte_match: four non-ASCII letters, 9 code points; the file holds UTF-8 bytes
    $fresh->();
    my $name9 = "\x{e4}\x{f6}\x{fc}\x{df}abcde";
    $CREDS{$acct} = { username => Encode::encode('UTF-8', $name9) };
    $poll->(denial(31));
    $answer->(0, health_body(session_user => "\x{e4}\x{f6}\x{fc}\x{df}****", session_user_len => 9, audio_key_denials => 3));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'multibyte_match: code points on both sides, a byte count would not match');

    # 89 review WR-02: the helper keeps min(4, L - 2) code points, so a short
    # name arrives with a shorter prefix or none ("****"); the match compares
    # as many code points as the prefix holds, plus the length.
    my $short = 34;
    for my $c (
        [ 'short_name_paired',              'abc', 'a****', 3, 'paired' ],
        [ 'short_name_fully_masked_paired', 'ab',  '****',  2, 'paired' ],
        [ 'short_name_other_prefix_guest',  'abc', 'z****', 3, 'guest'  ],
        [ 'short_name_other_length_guest',  'ab',  '****',  3, 'guest'  ],
    ) {
        my ($label, $user, $shown, $len, $want) = @$c;
        $fresh->();
        $CREDS{$acct} = { username => $user };
        $poll->(denial($short++));
        $answer->(0, health_body(session_user => $shown, session_user_len => $len, audio_key_denials => 2));
        if ($want eq 'paired') {
            is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', "$label: filed as paired");
        }
        else {
            $isGuest->($label);
        }
    }

    # guest_refresh_and_order: two filings, one ring entry, clear -> record -> cache set each time
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(32));
    $answer->(0, health_body(session_user => 'zzzz****', session_user_len => 10, audio_key_denials => 2));
    $poll->(denial(33));
    $answer->(1, health_body(session_user => 'zzzz****', session_user_len => 10, audio_key_denials => 3));
    is(scalar(ring_for("audiokey:guest:$mac")), 1, 'guest_refresh_and_order: the ring holds exactly one guest entry');
    my @gcalls = grep { /audiokey:guest:\Q$mac\E|\Q$GUEST_KEY\E/ } @CALLS;
    is_deeply(\@gcalls, [ ("ring:clear:audiokey:guest:$mac", "ring:record:audiokey:guest:$mac", "cache:set:$GUEST_KEY") x 2 ],
        'guest_refresh_and_order: every filing is clearError, recordError, then the cache set (ring entry first)');

    # guest_ttl_equals_warn_ttl
    {
        my $dm = do { local (@ARGV, $/) = ("$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm"); <> };
        my $st = do { local (@ARGV, $/) = ("$project_dir/Plugins/SpotOn/Status.pm"); <> };
        my ($g) = $dm =~ /AUDIOKEY_GUEST_TTL_S\s*=>\s*(\d+)/;
        my ($w) = $st =~ /WARN_TTL_S\s*=>\s*(\d+)/;
        is($g, $w, 'guest_ttl_equals_warn_ttl: the guest TTL constant equals Status WARN_TTL_S');
        is($g, 3600, 'guest_ttl_equals_warn_ttl: and is 3600');
    }

    # one_get_per_new_denial_line
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(40));
    $poll->(denial(40));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 1, 'one_get_per_new_denial_line: a pending GET and the same tail -> still one');
    $poll->(denial(41));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 1, 'one_get_per_new_denial_line: a new line while the GET is pending -> still one');
    $answer->(0, $good);
    $poll->(denial(40));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 1, 'one_get_per_new_denial_line: the answered line polled again -> no GET');
    $poll->(denial(42));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 2, 'one_get_per_new_denial_line: a new denial line after the answer -> a second GET');
    $answer->(1, $good);

    # 89 review WR-03: the /health answer belongs to the process that was asked.
    # The dead-helper branch of startHelper restarts the SAME object; an answer
    # (or an error) that lands after that is not filed against the new process.
    # stale_answer_after_restart_is_dropped
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(50));
    $helper->{pid} = 4243;
    Plugins::SpotOn::Unified::DaemonManager::_clearAudioKeyMarks($mac);
    $poll->(denial(51));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 2, 'stale_answer_after_restart_is_dropped setup: the new process asked once more');
    $answer->(0, $good);
    ok(!exists $Slim::Utils::Cache::STORE{$STATE_KEY}, 'stale_answer_after_restart_is_dropped: the old answer files no paired denial');
    ok(!exists $Slim::Utils::Cache::STORE{$GUEST_KEY}, 'stale_answer_after_restart_is_dropped: and no guest entry');
    $poll->(denial(52));
    is(scalar @Slim::Networking::SimpleAsyncHTTP::GETS, 2, 'stale_answer_after_restart_is_dropped: the new GET is still in flight, no third GET');
    $answer->(1, $good);
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'stale_answer_after_restart_is_dropped: the new process answer is filed');

    # stale_error_after_restart_is_dropped
    $fresh->();
    $CREDS{$acct} = { username => 'abcdefgh12' };
    $poll->(denial(53));
    $helper->{pid} = 4243;
    $answer->(0, undef);
    ok(!exists $Slim::Utils::Cache::STORE{$GUEST_KEY}, 'stale_error_after_restart_is_dropped: no guest entry for a process that never saw the denial');
    is(scalar(ring_for("audiokey:guest:$mac")), 0, 'stale_error_after_restart_is_dropped: no guest ring entry');

    # migration
    {
        $fresh->();
        $DM->_reportAudioKeyState($acct, 'denied');
        $Slim::Utils::Cache::STORE{$STATE_KEY} = 'denied';
        is(scalar(ring_for("audiokey:$acct")), 1, 'migration setup: a poisoned ring entry');
        eval { $DM->_migrateAudioKeyAttribution() };
        ok(!exists $Slim::Utils::Cache::STORE{$STATE_KEY}, 'migration: the spoton_audiokey_state_<account> entry is gone');
        is(scalar(ring_for("audiokey:$acct")), 0, 'migration: its status entry is gone');
        ok($Slim::Utils::Cache::STORE{spoton_audiokey_attrib_v89}, 'migration: the guard key is set');
        is($Slim::Utils::Cache::TTL{spoton_audiokey_attrib_v89}, 'never', 'migration: with TTL never');
        $Slim::Utils::Cache::STORE{$STATE_KEY} = 'denied';
        $DM->_reportAudioKeyState($acct, 'denied');
        eval { $DM->_migrateAudioKeyAttribution() };
        is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'migration: one-shot, a later entry is left alone');
        is(scalar(ring_for("audiokey:$acct")), 1, 'migration: one-shot, a later ring entry is left alone');

        my $src = do { local (@ARGV, $/) = ("$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm"); <> };
        my ($init) = $src =~ /(sub initHelpers \{.*?)\nsub /s;
        $init //= '';
        $init =~ s/^\s*#.*$//mg;          # code lines only, a comment may name either sub
        my $m = index($init, '_migrateAudioKeyAttribution');
        my $a = index($init, 'assertStandingConditions');
        ok($m >= 0 && $a >= 0 && $m < $a, 'migration: initHelpers runs the migration before assertStandingConditions');
        like($src, qr/spoton_audiokey_attrib_v89/, 'migration: the guard key name');
    }

    # gh141_escape_kept
    $fresh->();
    $Slim::Utils::Cache::STORE{$STATE_KEY} = 'denied';
    $DM->_reportAudioKeyState($acct, 'denied');
    {
        local $Plugins::SpotOn::Unified::Daemon::HEALTH = { idle_secs => 1, checked_at => time() };
        $poll->('');
    }
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'gh141_escape_kept: a clean tail on an actively streaming daemon still clears the cached paired denied');
    is(scalar(ring_for("audiokey:$acct")), 0, 'gh141_escape_kept: and its ring entry');


    # ---- 89-07: a paired denial filed by one helper survives clean sibling helpers ----
    # Siblings are two more helpers of the same account, each with a FakeClient, a clean
    # tail and a fresh health snapshot (a clean, streaming sibling in the GH #141 branch).
    my @SIB = ('aa:bb:cc:dd:ee:81', 'aa:bb:cc:dd:ee:82');
    my %SIBH;
    my $sibUp = sub {
        for my $m (@SIB) {
            my $h = $SIBH{$m} = $DM->startHelper($m);
            $h->{tail} = ''; $h->{health} = { idle_secs => 1, checked_at => time() };
            $Slim::Player::Client::BY_MAC{$m} = FakeClient->new($m, "Sib $m");
        }
    };
    my $sibDown = sub { for my $m (@SIB) { $DM->stopHelper($m); delete $Slim::Player::Client::BY_MAC{$m}; } };
    my $sresp = sub { Slim::Networking::SimpleAsyncHTTP::Resp->new(health_body(status => 'ok', session_valid => 1, session_age_secs => 60, idle_secs => 1, audio_key_denials => 0, session_user => $_[0], session_user_len => 10)) };
    my $resp = sub { Slim::Networking::SimpleAsyncHTTP::Resp->new(health_body(status => 'ok', session_valid => 1, session_age_secs => 60, idle_secs => 1, audio_key_denials => $_[0])) };

    # sibling_keeps_paired_denial
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(50)); $answer->(0, $good);
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', "sibling_keeps_paired_denial: the refused helper's denial is filed as paired");
    is($DM->_isStreamActive($SIBH{$SIB[0]}, $Slim::Player::Client::BY_MAC{$SIB[0]}) ? 1 : 0, 1, 'sibling_keeps_paired_denial: a clean sibling counts as streaming, so it reaches the gh141 branch');
    $poll->(denial(50)); $poll->(denial(50));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'sibling_keeps_paired_denial: the paired denied survives two polls over the clean streaming siblings');
    is(scalar(ring_for("audiokey:$acct")), 1, 'sibling_keeps_paired_denial: and its paired status entry');
    $sibDown->();

    # gh141_without_paired_denial_clears
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $Slim::Utils::Cache::STORE{$STATE_KEY} = 'denied'; $DM->_reportAudioKeyState($acct, 'denied');
    $poll->('');
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'gh141_without_paired_denial_clears: no helper holds a paired denial, a clean streaming sibling clears the stale denied');
    is(scalar(ring_for("audiokey:$acct")), 0, 'gh141_without_paired_denial_clears: and its status entry');
    $sibDown->();

    # key_granted_reopens_gh141
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(51)); $answer->(0, $good);
    $poll->('');
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', "key_granted_reopens_gh141: the refused helper's own clean tail keeps the denied while no /health of it reported 0");
    $DM->_onHealthResponse($helper, $resp->(3)); $poll->('');
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'key_granted_reopens_gh141: a /health count of 3 keeps the denied');
    $DM->_onHealthResponse($helper, $resp->(0)); $poll->('');
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'key_granted_reopens_gh141: a /health count of 0 (a key was granted, D-14) lets the gh141 clear end the denied');
    is(scalar(ring_for("audiokey:$acct")), 0, 'key_granted_reopens_gh141: and its status entry');
    $sibDown->();

    # restart_drops_the_mark_until_next_refusal
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(52)); $answer->(0, $good);
    $DM->stopHelper($mac); $helper = $DM->startHelper($mac); $helper->_healthCheckCount(0);
    $poll->('');
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'restart_drops_the_mark_until_next_refusal: a restarted helper no longer holds the denied (D-07: it returns with the next refusal)');
    $poll->(denial(53)); $answer->(1, $good);
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'restart_drops_the_mark_until_next_refusal: the next refused title files the paired denied again');
    $poll->(denial(53));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'restart_drops_the_mark_until_next_refusal: and the clean siblings keep it');
    $sibDown->();

    # guest_refusal_does_not_hold_paired
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(54)); $answer->(0, health_body(session_user => 'zzzz****', session_user_len => 10, audio_key_denials => 2));
    $Slim::Utils::Cache::STORE{$STATE_KEY} = 'denied'; $DM->_reportAudioKeyState($acct, 'denied');
    $poll->(denial(54));
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'guest_refusal_does_not_hold_paired: a guest refusal on one player does not hold a stale paired denied');
    ok(exists $Slim::Utils::Cache::STORE{$GUEST_KEY} && scalar(ring_for("audiokey:guest:$mac")) == 1, 'guest_refusal_does_not_hold_paired: the guest key and its ring entry are not touched by the gh141 clear');
    $sibDown->();

    # live_sibling_playback_clears_paired_denial
    {
        package PlayingClient; our @ISA = ('FakeClient');
        sub isPlaying { 1 }
        sub playingSong { return bless {}, 'PlayingSong' }
        package PlayingSong; sub track { return bless {}, 'PlayingTrack' }
        package PlayingTrack; sub url { 'spoton://track:4uLU6hMCjMI75M1A2tKUQC' }
    }
    {
    local $main::FAKE_NOW = 1_800_000_000;
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(55)); $answer->(0, $good);
    $Slim::Player::Client::BY_MAC{$SIB[0]} = PlayingClient->new($SIB[0], 'Sib live');
    $poll->(denial(55));
    $main::FAKE_NOW += 5; $DM->_onHealthResponse($SIBH{$SIB[0]}, $sresp->('abcd****'));
    $main::FAKE_NOW += 5; $poll->(denial(55));
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'live_sibling_playback_clears_paired_denial: a sibling whose LMS player really plays a SpotOn title clears the paired denied although the refused helper holds its mark');
    is(scalar(ring_for("audiokey:$acct")), 0, 'live_sibling_playback_clears_paired_denial: and its status entry');
    $sibDown->();
    }

    # live_guest_playback_keeps_paired_denial (D-20)
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(56)); $answer->(0, $good);
    $Slim::Player::Client::BY_MAC{$SIB[0]} = PlayingClient->new($SIB[0], 'Sib live');
    $poll->(denial(56));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'live_guest_playback_keeps_paired_denial: a sibling playing live without a /health of its session keeps the paired denied (fail closed)');
    $DM->_onHealthResponse($SIBH{$SIB[0]}, $sresp->('zzzz****'));
    $poll->(denial(56));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'live_guest_playback_keeps_paired_denial: a sibling playing live with a guest session keeps the paired denied (D-20)');
    is(scalar(ring_for("audiokey:$acct")), 1, 'live_guest_playback_keeps_paired_denial: and its status entry');
    $sibDown->();

    # live_evidence_must_follow_playback_start (D-20 amendment)
    {
    local $main::FAKE_NOW = 1_800_000_000;
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(57)); $answer->(0, $good);
    $main::FAKE_NOW += 5; $DM->_onHealthResponse($SIBH{$SIB[0]}, $sresp->('abcd****'));
    $main::FAKE_NOW += 5; $Slim::Player::Client::BY_MAC{$SIB[0]} = PlayingClient->new($SIB[0], 'Sib live'); $poll->(denial(57));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'live_evidence_must_follow_playback_start: paired session evidence from before the playback start keeps the paired denied');
    $main::FAKE_NOW += 5; $DM->_onHealthResponse($SIBH{$SIB[0]}, $sresp->('abcd****'));
    $main::FAKE_NOW += 5; $poll->(denial(57));
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'live_evidence_must_follow_playback_start: a paired /health after the playback start lets the next poll clear the denied');
    is(scalar(ring_for("audiokey:$acct")), 0, 'live_evidence_must_follow_playback_start: and its status entry');
    $sibDown->();
    }

    # live_evidence_older_than_120s_keeps_paired_denial
    {
    local $main::FAKE_NOW = 1_800_000_000;
    $fresh->(); $CREDS{$acct} = { username => 'abcdefgh12' }; $sibUp->();
    $poll->(denial(58)); $answer->(0, $good);
    $main::FAKE_NOW += 5; $Slim::Player::Client::BY_MAC{$SIB[0]} = PlayingClient->new($SIB[0], 'Sib live'); $poll->(denial(58));
    $main::FAKE_NOW += 5; $DM->_onHealthResponse($SIBH{$SIB[0]}, $sresp->('abcd****'));
    $main::FAKE_NOW += 121; $poll->(denial(58));
    is($Slim::Utils::Cache::STORE{$STATE_KEY}, 'denied', 'live_evidence_older_than_120s_keeps_paired_denial: paired evidence 121 s old keeps the paired denied');
    $main::FAKE_NOW += 1; $DM->_onHealthResponse($SIBH{$SIB[0]}, $sresp->('abcd****'));
    $main::FAKE_NOW += 1; $poll->(denial(58));
    ok(!defined $Slim::Utils::Cache::STORE{$STATE_KEY}, 'live_evidence_older_than_120s_keeps_paired_denial: a fresh paired /health ends it at the next poll');
    $sibDown->();
    }
    # ---- end 89-07 ----

    # platform_texts
    my $A_MAC  = 'There is no way out on this system (macOS or Windows). On a Linux server this account plays with the Soloist backend, for example LMS in Docker, in a VM or on a small Linux machine.';
    my $A_SOLO = 'Select the Soloist backend in the SpotOn settings.';
    my $A_NONE = 'Soloist is not available on this system.';
    {
        package FakeRole; our $FIT = 1; sub platformFit { return $FIT }
    }
    my $paired_text = sub {
        @Plugins::SpotOn::Status::RECORDED = ();
        $DM->_reportAudioKeyState($acct, 'denied');
        my @r = ring_for("audiokey:$acct");
        return $r[0][2] // '';
    };
    $fresh->();
    {
        local $main::FAKE_ISMAC = 1;
        like($paired_text->(), qr/\Q$A_MAC\E \(AesKeyError 0x0001\)$/, 'platform_texts: macOS paired text carries the no-way-out sentence');
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::available = sub { return ('librespot', 'soloist') };
        local *Plugins::SpotOn::Backend::classFor  = sub { return 'FakeRole' };
        local $FakeRole::FIT = 1;
        like($paired_text->(), qr/\Q$A_SOLO\E \(AesKeyError 0x0001\)$/, 'platform_texts: Linux with Soloist paired text carries the select-Soloist sentence');
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Backend::available = sub { return ('librespot') };
        like($paired_text->(), qr/\Q$A_NONE\E \(AesKeyError 0x0001\)$/, 'platform_texts: Linux without Soloist paired text carries the not-available sentence');
    }

    # no_full_id: nothing any scenario recorded, logged or cached holds a full id or name
    ok(scalar(@ALL) > 20, 'no_full_id: the scenarios produced texts to scan (' . scalar(@ALL) . ')');
    my @leak = grep { /abcdefgh12|zzzzyyyy99|\Q$acct\E/ } @ALL;
    is_deeply(\@leak, [], 'no_full_id: no recorded message, warn, log line or cache value contains a full account id or username');
    my @dash = grep { /[\x{2013}\x{2014}]/ } @ALL;
    is_deeply(\@dash, [], 'no_full_id: no en or em dash in any produced text');

    $DM->stopHelper($mac);
    %Slim::Utils::Cache::STORE = ();
    @Plugins::SpotOn::Status::RECORDED = ();
}

done_testing();
