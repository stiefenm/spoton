#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

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
# 74b-03: a small in-memory store so the audio-key cells can seed
# spoton_audiokey_state_<account>; unset keys still read as undef.
our %STORE;
sub new    { return bless {}, shift }
sub get    { return $STORE{ $_[1] } }
sub set    { $STORE{ $_[1] } = $_[2] }
sub remove { delete $STORE{ $_[1] } }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
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
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
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
sub new {
    my ($class, $mac) = @_;
    return bless { mac => $mac, alive => 1 }, $class;
}
# 84-08: DaemonManager keys its Soloist-only paths on backendName, not isa.
sub backendName { return 'librespot' }
sub mac                 { return $_[0]->{mac} }
sub alive               { return $_[0]->{alive} }
sub pid                 { return 4242 }
sub name                { return undef }
sub _accountId          { return $ACCOUNT }
sub _streamPort         { return undef }
sub _lastHealthSession  { return $HEALTH }
sub stderrTail          { return $TAIL }
sub stop                { $_[0]->{alive} = 0; return }
1;
END

# 74b WR-03: _streamAlivePoll asks LMS for the player behind the daemon; no
# player here, so _isStreamActive falls back to the health snapshot.
BEGIN {
    package Slim::Player::Client;
    sub getClient { return undef }
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
    push @RECORDED, [@_];
    shift @RECORDED while scalar @RECORDED > 30;
}
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;
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
    *main::INFOLOG     = sub () { 0 };
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


# 84-09: librespot half of t/28_soloist_dispatch.t -- the REAL
# Backend::Librespot answers _backendPrereqState for librespot / undef.
# (No Soloist module is loaded here; the dispatch table over mocks is
# t/core/28_soloist_dispatch_core.t.)
unshift @INC, $stub_dir, $project_dir;

our $FAKE_BINARY  = undef;   # undef = missing; any true value = present
our $FAKE_HAS_KEY = 0;

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");

# 82-52 Task 2 (WR-04): turns the Slim::Utils::Log stub's no-op error()
# into a real call-recorder, exactly analogous to the
# Plugins::SpotOn::Soloist::get/hasKey overrides above -- the module is
# already loaded by require_ok() above, so the glob assignment sticks.
my @LOG_ERROR_CALLS;
{
    no warnings 'redefine';
    *Slim::Utils::Log::error = sub { shift; push @LOG_ERROR_CALLS, [@_]; };
}

# 84-12 Task 1: the nine _backendPrereqState cells run THROUGH the role --
# each role's prereqState is wrapped by a recorder (the real method, when it
# exists, still answers; the Soloist get/hasKey stubs above sit behind it).
require_ok('Plugins::SpotOn::Backend::Librespot') or BAIL_OUT('Backend/Librespot.pm does not load');
our @ROLE_PREREQ_CALLS;
for my $pair ([ librespot => 'Plugins::SpotOn::Backend::Librespot' ]) {
    my ($name, $cls) = @$pair;
    my $orig = $cls->can('prereqState');
    no strict 'refs';
    no warnings 'redefine';
    *{"${cls}::prereqState"} = sub {
        push @ROLE_PREREQ_CALLS, $name;
        return $orig ? $orig->(@_) : "${name}_role_has_no_prereqState";
    };
}

sub reset_all {
    $FAKE_BINARY  = undef;
    $FAKE_HAS_KEY = 0;
    $FAKE_ISWINDOWS = 0;
    $FAKE_ISMAC     = 0;
    @ROLE_PREREQ_CALLS = ();
}

# ============================================================
# (a) backend 'librespot' -> 'librespot' (default/unmodified path)
# ============================================================
{
    reset_all();
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('librespot'),
        'librespot',
        "backend 'librespot' -> 'librespot'"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, ['librespot'], "backend 'librespot': answered by Backend::Librespot->prereqState (84-12)");
}

# Unknown/tampered pref values fall back to 'librespot' (T-71-05) --
# same code path as the plain 'librespot' case, worth asserting explicitly.
{
    reset_all();
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState(undef),
        'librespot',
        "undef backend -> 'librespot' (fail-safe fallback)"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, ['librespot'], 'undef backend: defaults to librespot, answered by its role (84-12)');
}

# ============================================================
# 74b-03 Task 2 (D-09): the librespot audio-key refusal and throttling are
# status-page entries. denied = standing 'error' (module Connect, key
# audiokey:ACCOUNT) that points to Soloist; throttled = 'warn' that expires;
# timeout = transient, nothing. The account id appears only masked (T-74b-09).
# ============================================================
{
    my $DM   = 'Plugins::SpotOn::Unified::DaemonManager';
    my $acct = 'ACCT0123456789abcdef';
    my $key  = "audiokey:$acct";
    my $entries = sub {
        return [ grep { ($_->[1] // '') eq 'Connect' && ($_->[3] // '') eq $key } @Plugins::SpotOn::Status::RECORDED ];
    };

    can_ok($DM, qw(_reportAudioKeyState assertStandingConditions));

    @Plugins::SpotOn::Status::RECORDED = ();
    $DM->_reportAudioKeyState($acct, 'denied');
    my $e = $entries->();
    is(scalar(@$e), 1, "74b-03 D-09: denied records one entry");
    is($e->[0][0], 'error', "74b-03 D-09: denied is level error (standing)");
    is($e->[0][1], 'Connect', "74b-03 D-09: denied is module Connect");
    like($e->[0][2] // '', qr/ACCT\*\*\*\*/, "74b-03 D-09 T-74b-09: the account appears as first four characters plus ****");
    unlike($e->[0][2] // '', qr/\Q$acct\E/, "74b-03 D-09 T-74b-09: the message does not contain the full account id");
    like($e->[0][2] // '', qr/Soloist/, "74b-03 D-09: the message points to the Soloist backend");
    like($e->[0][2] // '', qr/AesKeyError 0x0001/, "74b-03 D-09: the message names AesKeyError 0x0001");
    unlike($e->[0][2] // '', qr/\x{2014}|\x{2013}/, "74b-03 D-09: no em or en dash in the message");
    $DM->_reportAudioKeyState($acct, 'denied');
    is(scalar(@{ $entries->() }), 1, "74b-03 D-09: a repeated denied call keeps one entry");

    $DM->_reportAudioKeyState($acct, undef);
    is(scalar(@{ $entries->() }), 0, "74b-03 D-09: undef clears the entry for that key");

    $DM->_reportAudioKeyState($acct, 'throttled');
    $e = $entries->();
    is(scalar(@$e), 1, "74b-03 D-09: throttled records one entry");
    is($e->[0][0], 'warn', "74b-03 D-09: throttled is level warn (expires)");
    $DM->_reportAudioKeyState($acct, 'throttled');
    is(scalar(@{ $entries->() }), 1, "74b-03 D-09: a repeated throttled call keeps one entry");
    $DM->_reportAudioKeyState($acct, undef);

    # WR-01 (74b review): a standing throttled warn must not swallow the
    # permanent denied error recorded under the same key.
    $DM->_reportAudioKeyState($acct, 'throttled');
    $DM->_reportAudioKeyState($acct, 'denied');
    $e = $entries->();
    is(scalar(@$e), 1, "74b WR-01: throttled then denied leaves exactly one entry for the key");
    is($e->[0][0] // '', 'error', "74b WR-01: that entry is the denied error, not the throttled warn");
    like($e->[0][2] // '', qr/ACCT\*\*\*\*/, "74b WR-01: the replacing denied entry keeps the masked account id");
    unlike($e->[0][2] // '', qr/\Q$acct\E/, "74b WR-01: the replacing denied entry does not contain the full account id");
    $DM->_reportAudioKeyState($acct, 'denied');
    is(scalar(@{ $entries->() }), 1, "74b WR-01: a repeated denied call after the replacement keeps one entry");
    $DM->_reportAudioKeyState($acct, 'throttled');
    $e = $entries->();
    is(scalar(@$e), 1, "74b WR-01: a later throttled call does not add to a standing denied");
    is($e->[0][0] // '', 'error', "74b WR-01: the standing denied error survives a later throttled call");
    $DM->_reportAudioKeyState($acct, undef);

    $DM->_reportAudioKeyState($acct, 'timeout');
    is(scalar(@{ $entries->() }), 0, "74b-03 D-09: timeout (transient, GH #150) records nothing");
    $DM->_reportAudioKeyState(undef, 'denied');
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "74b-03 D-09: no account, no entry");

    # assertStandingConditions, backend librespot, accounts from prefs
    local $Slim::Utils::Prefs::FAKE_VALUES{accounts} = { $acct => { displayName => 'x' } };
    local $Slim::Utils::Prefs::FAKE_VALUES{backend}  = 'librespot';
    %Slim::Utils::Cache::STORE = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    $Slim::Utils::Cache::STORE{"spoton_audiokey_state_$acct"} = 'denied';
    $DM->assertStandingConditions();
    $e = $entries->();
    is(scalar(@$e), 1, "74b-03 D-09 T-74b-11: a cached denied state is re-asserted into an empty ring");
    is($e->[0][0], 'error', "74b-03 D-09: the re-asserted denied entry is an error");
    $DM->assertStandingConditions();
    is(scalar(@{ $entries->() }), 1, "74b-03 D-09: re-asserting twice keeps one entry");

    delete $Slim::Utils::Cache::STORE{"spoton_audiokey_state_$acct"};
    $DM->assertStandingConditions();
    is(scalar(@{ $entries->() }), 0, "74b-03 D-09: an empty cache state clears the entry");

    $Slim::Utils::Cache::STORE{"spoton_audiokey_state_$acct"} = 'throttled';
    @Plugins::SpotOn::Status::RECORDED = ();
    $DM->assertStandingConditions();
    is(scalar(@{ $entries->() }), 0, "74b-03 D-09: a throttled state is not re-asserted (one-shot warn)");
    Plugins::SpotOn::Status->recordError('warn', 'Connect', 'throttled earlier', $key);
    $DM->assertStandingConditions();
    is(scalar(@{ $entries->() }), 1, "74b-03 D-09: a standing throttled warn is left alone while the cache says throttled");

    # WR-03 (74b review): _streamAlivePoll must never let a softer classifier
    # answer displace a cached, permanent 'denied'. Driven through the real
    # poll with a registered stub daemon; the cache stub keeps no TTLs, so the
    # cache VALUE is what is asserted.
    {
        my $mac      = 'aa:bb:cc:dd:ee:74';
        my $cacheKey = "spoton_audiokey_state_$acct";
        my $tmpCache = tempdir(CLEANUP => 1);
        make_path("$tmpCache/spoton/$acct");
        open(my $cf, '>', "$tmpCache/spoton/$acct/credentials.json") or die "credentials.json: $!";
        print $cf '{"username":"x"}';
        close($cf);

        local $Slim::Utils::Prefs::FAKE_VALUES{cachedir}      = $tmpCache;
        local $Slim::Utils::Prefs::FAKE_VALUES{activeAccount} = $acct;
        local $Slim::Utils::Prefs::FAKE_VALUES{accounts}      = { $acct => { displayName => 'x' } };
        local $Slim::Utils::Prefs::FAKE_VALUES{backend}       = 'librespot';
        %Slim::Utils::Cache::STORE = ();

        my $helper = $DM->startHelper($mac);
        ok($helper && $helper->mac eq $mac, "74b WR-03 setup: startHelper registered a stub daemon for the poll");

        my $poll = sub {
            my ($tail, $cached) = @_;
            local $Plugins::SpotOn::Unified::Daemon::TAIL = $tail;
            @Plugins::SpotOn::Status::RECORDED = ();
            %Slim::Utils::Cache::STORE = ();
            if (defined $cached) {
                $Slim::Utils::Cache::STORE{$cacheKey} = $cached;
                # the ring a standing denied would have: what the poll recorded on the transition
                $DM->_reportAudioKeyState($acct, $cached) if $cached ne 'ok';
            }
            Plugins::SpotOn::Unified::DaemonManager::_streamAlivePoll();
            return;
        };

        $poll->('error audio key 0 2', 'denied');
        is($Slim::Utils::Cache::STORE{$cacheKey}, 'denied', "74b WR-03: cached denied + throttled classification keeps the cache at denied");
        $e = $entries->();
        is(scalar(@$e), 1, "74b WR-03: cached denied + throttled leaves exactly one ring entry");
        is($e->[0][0] // '', 'error', "74b WR-03: that ring entry is still the standing denied error");

        $poll->('Audio key response timeout', 'denied');
        is($Slim::Utils::Cache::STORE{$cacheKey}, 'denied', "74b WR-03: cached denied + timeout classification keeps the cache at denied");
        $e = $entries->();
        is(scalar(@$e), 1, "74b WR-03: cached denied + timeout leaves exactly one ring entry");
        is($e->[0][0] // '', 'error', "74b WR-03: that ring entry is still the standing denied error after a timeout");

        # unchanged behaviour around the guard
        $poll->('error audio key 0 2', undef);
        is($Slim::Utils::Cache::STORE{$cacheKey}, 'throttled', "74b WR-03: no cached state + throttled classification still caches throttled");
        $e = $entries->();
        is(scalar(@$e) . '/' . ($e->[0][0] // ''), '1/warn', "74b WR-03: ... and records the throttled warn");

        $poll->('Audio key response timeout', undef);
        is($Slim::Utils::Cache::STORE{$cacheKey}, 'timeout', "74b WR-03: no cached state + timeout classification still caches timeout");

        $poll->('error audio key 0 2', 'timeout');
        is($Slim::Utils::Cache::STORE{$cacheKey}, 'throttled', "74b WR-03: cached timeout is still replaced by throttled");

        $poll->('error audio key 0 1', 'throttled');
        is($Slim::Utils::Cache::STORE{$cacheKey}, 'denied', "74b WR-03: cached throttled is still replaced by denied");
        $e = $entries->();
        is(scalar(@$e) . '/' . ($e->[0][0] // ''), '1/error', "74b WR-03: ... and the ring ends with one denied error");

        # GH #141: the one deliberate way out of denied -- no error signature in
        # the tail while the account is actively streaming.
        {
            local $Plugins::SpotOn::Unified::Daemon::HEALTH = { idle_secs => 1, checked_at => time() };
            $poll->('', 'denied');
            ok(!defined $Slim::Utils::Cache::STORE{$cacheKey}, "74b WR-03 GH #141: a clean tail on an actively streaming daemon still clears the cached denied");
            is(scalar(@{ $entries->() }), 0, "74b WR-03 GH #141: ... and clears the ring entry");
        }
        {
            local $Plugins::SpotOn::Unified::Daemon::HEALTH = { idle_secs => 9999, checked_at => time() };
            $poll->('', 'denied');
            is($Slim::Utils::Cache::STORE{$cacheKey}, 'denied', "74b WR-03 GH #141: a clean tail on an idle daemon keeps the cached denied");
            is(scalar(@{ $entries->() }), 1, "74b WR-03 GH #141: ... and keeps the ring entry");
        }

        Plugins::SpotOn::Unified::DaemonManager->stopHelper($mac);
        %Slim::Utils::Cache::STORE = ();
        @Plugins::SpotOn::Status::RECORDED = ();
    }

    # source pin: the poll reports on the transition and on the GH #141 clear
    my $src = do { local (@ARGV, $/) = ($module); <> };
    my ($poll) = $src =~ /(sub _streamAlivePoll \{.*?)\nsub /s;
    $poll //= '';
    like($poll, qr/\$cache->set\(\$cacheKey, 'denied', 'never'\);\s*\$class->_reportAudioKeyState\(\$helper->_accountId, 'denied'\)/,
        "74b-03 D-09: _streamAlivePoll reports denied right after the cache set");
    like($poll, qr/\$cache->set\(\$cacheKey, 'throttled', 600\);\s*\$class->_reportAudioKeyState\(\$helper->_accountId, 'throttled'\)/,
        "74b-03 D-09: _streamAlivePoll reports throttled right after the cache set");
    like($poll, qr/\$cache->remove\("spoton_audiokey_state_" \. \$helper->_accountId\);\s*\$class->_reportAudioKeyState\(\$helper->_accountId, undef\)/,
        "74b-03 D-09: _streamAlivePoll clears the entry in the GH #141 branch");
    is(scalar(() = $poll =~ /_reportAudioKeyState/g), 3, "74b-03 D-09: exactly three report calls in the poll (denied, throttled, GH #141 clear)");

    @Plugins::SpotOn::Status::RECORDED = ();
    %Slim::Utils::Cache::STORE = ();
}

done_testing();
