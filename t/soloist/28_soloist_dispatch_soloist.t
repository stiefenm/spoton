#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: soloist half of t/28_soloist_dispatch.t -- the
# REAL Soloist/SoloistDaemon/Backend::Soloist cells; the dispatch table over
# mocked roles is t/core/28_soloist_dispatch_core.t, the librespot answers
# t/librespot/28_soloist_dispatch_librespot.t)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# 79-25 (D-08, NA-x): which backend-side leg is this tree? The committed manifests
# tools/ci/amputation/<side>.files (entries under Plugins/SpotOn/) are the single source:
# all paths present = normal tree ('present'), none present = that side was removed on purpose
# ('amputated', the CI amputation leg), some present = broken checkout (die, never skip).
sub amputation_state {
    my ($root, $side) = @_;
    my $manifest = "$project_dir/tools/ci/amputation/$side.files";
    open(my $mfh, '<', $manifest)
        or die "$manifest: $! -- wrong project root or broken checkout (die, never skip)\n";
    my @paths;
    while (my $line = <$mfh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        next unless $line =~ m{^Plugins/SpotOn/};
        $line =~ s{/+\z}{};
        push @paths, $line;
    }
    close($mfh);
    die "$manifest holds no Plugins/SpotOn entries -- wrong project root or broken checkout (die, never skip)\n"
        unless @paths;
    my $here = grep { -e "$root/$_" } @paths;
    return 'present'   if $here == @paths;
    return 'amputated' if $here == 0;
    die "partial $side side ($here of " . scalar(@paths) . " paths present) -- broken checkout (die, never skip)\n";
}

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
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
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
sub new { return bless {}, shift }
# 84-08: DaemonManager keys its Soloist-only paths on backendName, not isa.
sub backendName { return 'librespot' }
1;
END

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
    my ($class, $module, $key) = @_;
    return 0 unless defined $key;
    return scalar grep {
        ($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key
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


unshift @INC, $stub_dir, $project_dir;

# Task 2 (73-01): the REAL Plugins::SpotOn::Soloist module is loaded (not a
# fake stand-in) so dataDirForClient/cacheDirForClient/readKey/ensureWsLib
# are exercised as actual production code. Only get()/hasKey() are
# monkey-patched afterward (glob assignment) so _backendPrereqState()'s
# three soloist-branch outcomes stay controllable per test case, exactly
# like the previous fake-package approach.
require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load the real Plugins::SpotOn::Soloist");

our $FAKE_BINARY  = undef;   # undef = missing; any true value = present
our $FAKE_HAS_KEY = 0;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Soloist::get    = sub { return $FAKE_BINARY };
    *Plugins::SpotOn::Soloist::hasKey = sub { return $FAKE_HAS_KEY };
}

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
require_ok('Plugins::SpotOn::Backend::Soloist')   or BAIL_OUT('Backend/Soloist.pm does not load');
our @ROLE_PREREQ_CALLS;
for my $pair ([ soloist => 'Plugins::SpotOn::Backend::Soloist' ]) {
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
# (b) backend 'soloist', binary+key present, Linux -> 'soloist_ready'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_ready',
        "backend 'soloist', binary+key present, Linux -> 'soloist_ready'"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, ['soloist'], "soloist ready: answered by Backend::Soloist->prereqState (84-12)");
}

# ============================================================
# (c) soloist, no binary -> 'soloist_missing_binary'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = undef;
    $FAKE_HAS_KEY = 1;   # key present is irrelevant -- binary checked first

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_missing_binary',
        "soloist, no binary -> 'soloist_missing_binary'"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, ['soloist'], 'soloist missing binary: answered by Backend::Soloist->prereqState (84-12)');
}

# ============================================================
# (d) soloist, binary present but no key -> 'soloist_missing_key'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 0;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_missing_key',
        "soloist, binary present, no key -> 'soloist_missing_key'"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, ['soloist'], 'soloist missing key: answered by Backend::Soloist->prereqState (84-12)');
}

# ============================================================
# Task 2 (D-01/D-02): per-player dir shapes (real Soloist.pm code)
# ============================================================
{
    my $dataDir = Plugins::SpotOn::Soloist::dataDirForClient('aa:bb:cc:dd:ee:ff');
    like($dataDir, qr{players/aabbccddeeff/data$}, "dataDirForClient() shape (D-01 per-player dir)");

    my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient('aa:bb:cc:dd:ee:ff');
    like($cacheDir, qr{players/aabbccddeeff/cache$}, "cacheDirForClient() shape (D-01 per-player dir)");
}

# ============================================================
# Task 2 (D-08): ensureWsLib() -- vendor fallback vs. bundled precedence
# ============================================================
{
    # (1) No bundled copy anywhere in @INC -- must fall back to the real
    # vendored Plugins/SpotOn/Vendor/Protocol/WebSocket/Client.pm tree.
    delete $INC{'Protocol/WebSocket/Client.pm'};
    delete $INC{'Protocol/WebSocket.pm'};

    local $Plugins::SpotOn::Plugin::FAKE_BASEDIR = "$project_dir/Plugins/SpotOn";

    my $ok = Plugins::SpotOn::Soloist::ensureWsLib();
    is($ok, 1, "ensureWsLib() loads the vendored Protocol::WebSocket::Client when no bundled copy is present");
    like($INC{'Protocol/WebSocket/Client.pm'} // '', qr{Vendor}, "loaded from the real Plugins/SpotOn/Vendor tree (D-08)");
}

{
    # (2) A bundled copy earlier in @INC (stub_dir precedes any vendor push)
    # must win -- push, not unshift, in ensureWsLib().
    delete $INC{'Protocol/WebSocket/Client.pm'};
    write_stub($stub_dir, 'Protocol::WebSocket::Client', <<'END');
package Protocol::WebSocket::Client;
sub new { bless {}, shift }
1;
END

    my $ok = Plugins::SpotOn::Soloist::ensureWsLib();
    is($ok, 1, "ensureWsLib() succeeds when an LMS-bundled copy is present");
    like($INC{'Protocol/WebSocket/Client.pm'} // '', qr{^\Q$stub_dir\E}, "prefers the bundled copy over the vendored fallback");
}

# ============================================================
# Task 2 (D-04): resolvePassthroughForClient() soloist short-circuit
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    my $fakeClient = bless {}, 'FakeClient';

    is(
        Plugins::SpotOn::Unified::DaemonManager->resolvePassthroughForClient($fakeClient),
        0,
        "resolvePassthroughForClient() returns 0 unconditionally when backend='soloist' (D-04)"
    );
}

# ============================================================
# Task 2 (D-05): SoloistDaemon.pm isolated-require + _spawnArgs()
# ============================================================
require_ok('Plugins::SpotOn::Unified::SoloistDaemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistDaemon");
# 84-08 (SEAM-6.2): Case 2's defer entry moved into the Soloist role
# (Backend::Soloist::deferTrackRequestForClient -> DaemonManager's store,
# queuePendingTrackRequest). Every cell below drives the REAL role class.
require_ok('Plugins::SpotOn::Backend::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Backend::Soloist");

{
    my @args = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', 'Living Room',
        '/fake/data', '/fake/cache', 40,
    );

    is_deeply(
        \@args,
        [ '/fake/soloist', '-n', 'Living Room', '-k', 'the-spak-key',
          '-D', '/fake/data', '-C', '/fake/cache', '-w', '127.0.0.1:0', '-i', 40 ],
        "_spawnArgs() builds the expected argv (D-05, T-73-01 -- hard-coded 127.0.0.1:0 bind)"
    );
}

# ============================================================
# Task 2 (73-04): Sync-group pinning for the soloist backend. Pattern 7 says
# the librespot sync machinery (initHelpers()'s slave-delegates-to-master
# branch, deviceNameForClient()'s suffix, and the sync-change handler's
# name-comparison restart) transfers 1:1 to SoloistDaemon, unmodified. This
# section PROVES it against the REAL DaemonManager module (not a stub of it).
#
# Minimal stand-ins for Slim::Player::Client / Slim::Player::Sync /
# Slim::Control::Request: DaemonManager.pm only ever calls these
# fully-qualified (never `use`s them), so a plain in-process package
# declaration is sufficient -- no stub file on disk needed.
# ============================================================
require Time::HiRes;    # real core module (t/31's own precedent) -- needed
                         # once initHelpers()/init() start evaluating timer args.

{
    package Test::SyncClient;
    sub new {
        my ($class, %args) = @_;
        return bless {
            id      => $args{id},
            name    => $args{name} // 'Player',
            synced  => $args{synced} // 0,
            master  => $args{master},
            model   => $args{model} // 'squeezebox',
            formats => $args{formats} // [],   # 76-04: per-instance for resolveSoloistFormat tests
        }, $class;
    }
    sub id          { return $_[0]->{id}; }
    sub name        { return $_[0]->{name}; }
    sub isSynced    { return $_[0]->{synced}; }
    sub master      { return $_[0]->{master}; }
    sub model       { return $_[0]->{model}; }
    sub volume      { return 40; }
    sub isPlaying   { return 0; }
    sub playingSong { return undef; }
    sub connected   { return 1; }
    sub formats     { return @{ $_[0]->{formats} || [] }; }
}

{
    package Slim::Player::Client;
    our @ALL_CLIENTS = ();
    our %BY_ID       = ();
    sub clients   { return @ALL_CLIENTS; }
    sub getClient { return $BY_ID{ $_[0] }; }
}

{
    package Slim::Player::Sync;
    our %SLAVE_OF = ();    # slaveId => masterId
    our @SLAVES   = ();    # 76-04: controllable member list for slaves()
    sub isSlave { return exists $SLAVE_OF{ $_[0]->id } ? 1 : 0; }
    sub slaves  { return @SLAVES; }    # default empty (matches the pre-76-04 stub)
}

{
    package Slim::Control::Request;
    our @SUBSCRIPTIONS = ();
    # 82-52 Task 1 (WR-03): @SUBSCRIPTIONS is append-only across every
    # init() call in this whole file (no entry is ever removed), so it
    # cannot prove whether unsubscribe() was actually called.
    # @UNSUBSCRIBE_CALLS is a real call-recorder for exactly that.
    our @UNSUBSCRIBE_CALLS = ();
    sub subscribe   { push @SUBSCRIPTIONS, [ $_[0], $_[1] ]; }
    sub unsubscribe { push @UNSUBSCRIBE_CALLS, $_[0]; }
}

{
    package Test::SyncRequest;
    sub new          { return bless { client => $_[1] }, $_[0]; }
    sub isNotCommand { return 0; }    # pretend it IS a ['sync'] command
    sub client       { return $_[0]->{client}; }
}

# Test double for SoloistDaemon's process-lifecycle methods only -- name()/
# mac() stay the REAL Slim::Utils::Accessor-generated accessors (mk_accessor
# ran for real at module-load time). CR-01 fix: the Accessor stub is now
# array-based (blessed ARRAY refs, matching real LMS), so this double must
# bless an ARRAY ref too -- the test-only "alive" flag can no longer live in
# a hash slot on $self, so it is tracked in a package-level hash keyed by mac
# instead. Blessed into the literal production package name (73-03-SUMMARY.md
# precedent) so every isa('...::SoloistDaemon') check in DaemonManager.pm
# still passes.
my (@NEW_CALLS, @STOP_CALLS, @STOPFORSYNC_CALLS, @DEFER_CALLS, @START_CALLS);
my %_TEST_ALIVE;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::SoloistDaemon::new = sub {
        my ($class, $id) = @_;
        push @NEW_CALLS, $id;
        my $self = bless [], $class;
        $self->mac($id);
        # 84.1 plan 03 (D-04): uptime() dereferences _startTimes->[-1] --
        # without this, the poll's now-unconditional Soloist health tick
        # (_soloistHealthTick, called from every alive Soloist helper's
        # branch) would crash the instant it read ->uptime on this double.
        $self->_startTimes([ time() ]);
        $_TEST_ALIVE{$id} = 1;
        return $self;
    };
    *Plugins::SpotOn::Unified::SoloistDaemon::alive = sub {
        return $_TEST_ALIVE{ $_[0]->mac } // 1;
    };
    *Plugins::SpotOn::Unified::SoloistDaemon::stop = sub {
        my $self = shift;
        push @STOP_CALLS, $self->mac;
        $_TEST_ALIVE{ $self->mac } = 0;
    };
    *Plugins::SpotOn::Unified::SoloistDaemon::stopForSync = sub {
        my $self = shift;
        push @STOPFORSYNC_CALLS, $self->mac;
        $_TEST_ALIVE{ $self->mac } = 0;
    };
    # Phase 82 Plan 44 (D-09/F2, Fall Handoff): records the hand-off
    # startHelper's construction site makes to a freshly-created daemon.
    *Plugins::SpotOn::Unified::SoloistDaemon::deferTrackRequest = sub {
        push @DEFER_CALLS, [ $_[0]->mac, @_[1..$#_] ];
    };
    # Phase 82 Plan 45 (WR-02): without this override, startHelper's
    # elsif(!alive) restart branch would call the REAL
    # SoloistDaemon::start on a bless([], ...) double with a fake binary
    # path -- the Restart-Handoff case below could not run at all.
    *Plugins::SpotOn::Unified::SoloistDaemon::start = sub {
        my $self = shift;
        push @START_CALLS, $self->mac;
        # Phase 82 Plan 49 (WR-01, 82-REVIEW.md Runde 11 Zeile 90-133):
        # consume an already-pending @DEFER_CALLS entry and fire its
        # errorCb here -- mirrors _shutdownExistingControl's real release
        # of an open deferral, which runs BEFORE the real start() proper.
        # Without this, the Restart-Handoff case below could not detect a
        # hand-off-before-start() ordering violation in startHelper's
        # elsif(!alive) branch -- all its assertions would stay green even
        # if that branch handed off BEFORE calling start().
        if (my $h = shift @DEFER_CALLS) {
            $h->[3]{errorCb}->('PROBLEM_OPENING', 'Soloist daemon shut down') if $h->[3]{errorCb};
        }
        $_TEST_ALIVE{ $self->mac } = 1;
    };
}

reset_all();
$FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
$FAKE_HAS_KEY = 1;
local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

my $master = Test::SyncClient->new(id => 'aa:bb:cc:dd:ee:01', name => 'Living Room', synced => 1);
my $slave  = Test::SyncClient->new(id => 'aa:bb:cc:dd:ee:02', name => 'Kitchen',      synced => 1, master => $master);

$Slim::Player::Client::BY_ID{ $master->id } = $master;
$Slim::Player::Client::BY_ID{ $slave->id }  = $slave;
@Slim::Player::Client::ALL_CLIENTS          = ( $slave, $master );
$Slim::Player::Sync::SLAVE_OF{ $slave->id } = $master->id;

# ============================================================
# (a) initHelpers() delegation: a synced client-pair stub (slave with
# master) -- the soloist evaluation path delegates the daemon to the
# master's MAC and stops any slave-tracked helper (mirrors the librespot
# flow, GH #143 mechanism unmodified for soloist).
# ============================================================
{
    # Pre-condition: the slave was previously a standalone soloist player
    # and already has its own tracked daemon (simulates "was solo, just got
    # synced" -- the scenario where a slave-tracked helper must be stopped).
    Plugins::SpotOn::Unified::DaemonManager->startHelper($slave);
    is(scalar(@NEW_CALLS), 1, "pre-condition: slave's standalone soloist daemon was created");

    @NEW_CALLS = ();    # isolate the delegation call below

    Plugins::SpotOn::Unified::DaemonManager::initHelpers();

    is_deeply(\@NEW_CALLS, [ $master->id ],
        "initHelpers() creates exactly one SoloistDaemon, keyed by the sync MASTER's mac (Pattern 7 delegation)");
    is_deeply(\@STOP_CALLS, [ $slave->id ],
        "initHelpers() stops the slave's own previously-tracked soloist daemon (Pattern 7)");

    my @remaining = map { $_->mac } Plugins::SpotOn::Unified::DaemonManager->helperInstances();
    is_deeply(\@remaining, [ $master->id ],
        "only the sync master's daemon remains registered after delegation");

    ok(Plugins::SpotOn::Unified::DaemonManager->helperForClient($slave->id),
        "helperForClient() resolves the slave's id to the master's daemon via the sync fallback");
}

# ============================================================
# (b) deviceNameForClient() suffix/cap + soloist start-path name consumption:
# a synced non-group client gets the localized suffix appended within the
# 60-char cap -- and the soloist start path (_spawnArgs) consumes exactly
# this name.
# ============================================================
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::DaemonManager::cstring = sub { return 'Sync Group'; };

    my $expectedName = Plugins::SpotOn::Unified::DaemonManager->deviceNameForClient($master);
    like($expectedName, qr/Sync Group$/,
        "deviceNameForClient() appends the localized sync-group suffix for a synced non-group client");
    ok(length($expectedName) <= 60, "deviceNameForClient() result stays within the 60-char cap");

    my @spawnArgs = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', $expectedName, '/fake/data', '/fake/cache', 40,
    );
    is($spawnArgs[2], $expectedName,
        "the soloist start path (_spawnArgs) consumes exactly deviceNameForClient()'s synced name");

    # ============================================================
    # (c) sync-change handler: the same name-comparison restart DaemonManager
    # uses for librespot also applies to a SoloistDaemon instance -- a
    # helper->name vs deviceNameForClient mismatch triggers stopForSync()
    # when idle.
    # ============================================================
    Plugins::SpotOn::Unified::DaemonManager->init();

    my ($syncEntry) = grep { ref($_->[1]) eq 'ARRAY' && ($_->[1][0][0] // '') eq 'sync' }
        @Slim::Control::Request::SUBSCRIPTIONS;
    ok($syncEntry, "DaemonManager->init() subscribed a ['sync'] request handler");

    my $masterHelper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($master->id);
    $masterHelper->name('Stale Old Name');    # real Slim::Utils::Accessor-generated accessor

    @STOPFORSYNC_CALLS = ();

    $syncEntry->[0]->( Test::SyncRequest->new($slave) );

    is_deeply(\@STOPFORSYNC_CALLS, [ $master->id ],
        "sync-change handler calls stopForSync() on a SoloistDaemon whose name no longer matches "
        . "deviceNameForClient (idle) -- GH #143 mechanism unmodified for soloist");
}

# ============================================================
# 76-04 Task 1 (D-06): resolveSoloistFormat() -- per-client resolution +
# sync-group flc aggregation. Pref reads go through the shared FAKE_VALUES
# hash (the Prefs stub's client() returns the same backing store), so the
# per-case streamFormat value is set via local -- inside a sync group the
# resolver reads the MASTER's pref only, so a single shared value is exact.
# Sync members are injected via @Slim::Player::Sync::SLAVES.
# ============================================================
{
    my $dm = 'Plugins::SpotOn::Unified::DaemonManager';

    # undef client -> safe 'pcm' default
    is($dm->resolveSoloistFormat(undef), 'pcm',
        "resolveSoloistFormat(undef client) -> 'pcm' (safe default)");

    # --- explicit formats (D-06, refined by 74b D-15) ---
    # explicit flac is a capability-checked choice now: a group member
    # without flc degrades the whole answer to 'pcm' (D-15); explicit pcm
    # and mp3 are returned as is (mp3 needs no flc, transcoding is LMS-side).
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'flac';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:01', formats => ['pcm']);  # NOT flc-capable
        is($dm->resolveSoloistFormat($c), 'pcm',
            "explicit streamFormat=flac on a player without flc -> 'pcm' (D-15 degrade)");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'flac';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:08', formats => ['flc', 'pcm']);
        is($dm->resolveSoloistFormat($c), 'flac',
            "explicit streamFormat=flac on an flc-capable player -> 'flac'");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'flac';
        my $m = Test::SyncClient->new(id => 'sync:41', synced => 1, formats => ['flc', 'pcm']);
        $m->{master} = $m;
        my $s = Test::SyncClient->new(id => 'sync:42', synced => 1, master => $m, formats => ['pcm']);
        local @Slim::Player::Sync::SLAVES = ($s);
        is($dm->resolveSoloistFormat($m), 'pcm',
            "explicit flac in a sync group whose slave lacks flc -> 'pcm' (D-15)");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'pcm';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:02', formats => ['flc', 'pcm']);
        is($dm->resolveSoloistFormat($c), 'pcm',
            "explicit streamFormat=pcm -> 'pcm' even on an flc-capable player");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'mp3';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:03', formats => ['flc', 'pcm', 'mp3']);
        is($dm->resolveSoloistFormat($c), 'mp3',
            "explicit streamFormat=mp3 -> 'mp3' even on an flc-capable player");
    }

    # --- 74b D-22: the path decision for Auto never depends on the staging
    # seam. Every cell runs once per autoFlacEnabled override (0 and 1) so no
    # cell depends on the shipped constant; the answers are identical.
    for my $staged (0, 1) {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { $staged };
        {
            local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
            local @Slim::Player::Sync::SLAVES = ();
            my $c = Test::SyncClient->new(id => "d22:a$staged", formats => ['flc', 'pcm']);
            is($dm->resolveSoloistFormat($c), 'flac',
                "D-22: auto on [flc,pcm] -> 'flac' (path decision unchanged) with autoFlacEnabled=$staged");
        }
        {
            local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
            local @Slim::Player::Sync::SLAVES = ();
            my $c = Test::SyncClient->new(id => "d22:b$staged", formats => ['pcm']);
            is($dm->resolveSoloistFormat($c), 'pcm',
                "D-22: auto on [pcm] -> 'pcm' with autoFlacEnabled=$staged");
        }
        {
            local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
            my $m = Test::SyncClient->new(id => "d22:c$staged", synced => 1, formats => ['flc', 'pcm']);
            $m->{master} = $m;
            my $s = Test::SyncClient->new(id => "d22:d$staged", synced => 1, master => $m, formats => ['pcm']);
            local @Slim::Player::Sync::SLAVES = ($s);
            is($dm->resolveSoloistFormat($m), 'pcm',
                "D-22: auto with a slave lacking flc -> 'pcm' with autoFlacEnabled=$staged");
        }
    }

    # --- groupSupportsFlac: the extracted group capability aggregation ---
    {
        local @Slim::Player::Sync::SLAVES = ();
        my $r = eval { $dm->groupSupportsFlac(undef) };
        is($r, 0, "groupSupportsFlac(undef client) -> 0");
        my $c = Test::SyncClient->new(id => 'gsf:01', formats => ['flc']);
        $r = eval { $dm->groupSupportsFlac($c) };
        is($r, 1, "groupSupportsFlac: single player with flc -> 1");
        my $n = Test::SyncClient->new(id => 'gsf:02', formats => ['pcm']);
        $r = eval { $dm->groupSupportsFlac($n) };
        is($r, 0, "groupSupportsFlac: single player without flc -> 0");
    }
    {
        my $m = Test::SyncClient->new(id => 'gsf:11', synced => 1, formats => ['flc']);
        $m->{master} = $m;
        my $s = Test::SyncClient->new(id => 'gsf:12', synced => 1, master => $m, formats => ['pcm']);
        local @Slim::Player::Sync::SLAVES = ($s);
        my $r = eval { $dm->groupSupportsFlac($m) };
        is($r, 0, "groupSupportsFlac: master [flc] + slave [pcm] -> 0");
        $r = eval { $dm->groupSupportsFlac($s) };
        is($r, 0, "groupSupportsFlac: asked on the slave, the group answer is the same -> 0");
    }

    # --- 'ogg' maps to auto (OGG is librespot-exclusive, D-07) ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'ogg';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:04', formats => ['ogg', 'flc', 'pcm']);
        is($dm->resolveSoloistFormat($c), 'flac',
            "streamFormat=ogg maps to auto under soloist -> 'flac' on an flc-capable player (D-07)");
    }

    # --- auto: capability-based, same idiom as the librespot ogg probe ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:05', formats => ['ogg', 'flc', 'aif', 'pcm', 'mp3']);
        is($dm->resolveSoloistFormat($c), 'flac',
            "auto + flc announced in formats() -> 'flac' (D-06 capability-based)");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:06', formats => ['pcm', 'mp3']);
        is($dm->resolveSoloistFormat($c), 'pcm',
            "auto without flc in formats() -> 'pcm'");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = undef;
        local @Slim::Player::Sync::SLAVES = ();
        my $c = Test::SyncClient->new(id => 'fmt:07', formats => ['flc', 'pcm']);
        is($dm->resolveSoloistFormat($c), 'flac',
            "unset streamFormat pref behaves like auto -> 'flac' on an flc-capable player");
    }

    # --- sync-group aggregation (D-06 mirror of the OGG aggregation) ---
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
        my $m = Test::SyncClient->new(id => 'sync:11', synced => 1, formats => ['flc', 'pcm']);
        $m->{master} = $m;    # LMS semantics: master() on the master returns itself
        my $s = Test::SyncClient->new(id => 'sync:12', synced => 1, master => $m, formats => ['pcm']);
        local @Slim::Player::Sync::SLAVES = ($s);
        is($dm->resolveSoloistFormat($m), 'pcm',
            "sync group: master resolves flac but one slave lacks flc -> whole group 'pcm' (D-06 downgrade)");
    }
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
        my $m = Test::SyncClient->new(id => 'sync:21', synced => 1, formats => ['flc', 'pcm']);
        $m->{master} = $m;
        my $s = Test::SyncClient->new(id => 'sync:22', synced => 1, master => $m, formats => ['flc', 'pcm']);
        local @Slim::Player::Sync::SLAVES = ($s);
        is($dm->resolveSoloistFormat($m), 'flac',
            "sync group: ALL members flc-capable -> 'flac'");
    }
    {
        # unsynced player never consults slaves -- a non-flc player in the
        # stub slave list must NOT downgrade a standalone player.
        local $Slim::Utils::Prefs::FAKE_VALUES{streamFormat} = 'auto';
        my $c      = Test::SyncClient->new(id => 'solo:31', synced => 0, formats => ['flc', 'pcm']);
        my $nonflc = Test::SyncClient->new(id => 'solo:32', formats => ['pcm']);
        local @Slim::Player::Sync::SLAVES = ($nonflc);    # would downgrade IF consulted
        is($dm->resolveSoloistFormat($c), 'flac',
            "unsynced player never consults slaves (stays 'flac' despite a non-flc entry in the slave stub)");
    }
}

# ============================================================
# Phase 82 Plan 44 (D-09, Runde 44): DaemonManager's new package-level
# %pendingTrackRequests anchor -- Fall Handoff, the Verdraengung case
# below, and Fall Isolation (zwei Spieler, closes the $objRef Blocker-Fix).
# ============================================================

# --- Fall Handoff: a package-level deferral registered BEFORE any daemon
# object exists must be handed off to the freshly-constructed
# SoloistDaemon inside startHelper's single construction site (F2).
# Muss-Fehlschlag-Probe: removing the hand-off hook in startHelper leaves
# @DEFER_CALLS empty. ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:10';
    my $client   = Test::SyncClient->new(id => $clientId, name => 'Handoff Room');
    $Slim::Player::Client::BY_ID{$clientId} = $client;

    @NEW_CALLS   = ();
    @DEFER_CALLS = ();

    my $opts = { successCb => sub { }, errorCb => sub { } };
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:handoff', 0, $opts);

    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);

    is(scalar(@DEFER_CALLS), 1, "Fall Handoff: exactly one deferTrackRequest hand-off call after startHelper's construction site");
    is_deeply($DEFER_CALLS[0], [ $clientId, 'spoton://track:handoff', 0, $opts ], "Fall Handoff: the hand-off carries the ORIGINAL clientId/uri/posMs/opts unchanged");
}

# --- Verdraengung (Fall 5 convention): a second deferTrackRequestForClient for the
# SAME clientId supersedes the first -- the first's errorCb fires with
# ('PROBLEM_OPENING','superseded'). Muss-Fehlschlag-Probe: removing the
# `delete $pendingTrackRequests{$clientId}`-Verdraengungspruefung leaves
# the first errorCb never fired. ---
{
    reset_all();
    my $clientId = 'aa:bb:cc:dd:ee:11';
    my @errorCalls;
    my $optsFirst  = { errorCb => sub { push @errorCalls, [@_]; } };
    my $optsSecond = { errorCb => sub { } };

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:one', 0, $optsFirst);
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:two', 0, $optsSecond);

    is_deeply($errorCalls[0], [ 'PROBLEM_OPENING', 'superseded' ], "Fall 5 (Verdraengung): the FIRST deferral's errorCb fires with 'superseded' when a second one for the same clientId arrives");
}

# --- Fall Isolation (zwei Spieler): closes the Blocker-Fix
# (required_property: "jede Spieler-eigene aeussere 20s-Frist ist
# unabhaengig durchsetzbar; ein Hand-off fuer Spieler A darf Spieler Bs
# Timer nie loeschen"). Reset FIRST (Revision 2, Warnung 2) -- Fall
# Handoff and the Verdraengung case above already populated
# @KILL_CALLS/@SET_CALLS with entries for the SAME coderef
# (\&_pendingTrackRequestTimeout), just different $objRef values. ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientIdA = 'aa:bb:cc:dd:ee:20';
    my $clientIdB = 'aa:bb:cc:dd:ee:21';
    my $clientB   = Test::SyncClient->new(id => $clientIdB, name => 'Isolation Room B');
    $Slim::Player::Client::BY_ID{$clientIdB} = $clientB;

    @Slim::Utils::Timers::KILL_CALLS = ();
    @Slim::Utils::Timers::SET_CALLS  = ();

    my $optsA = { errorCb => sub { } };
    my $optsB = { errorCb => sub { } };
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientIdA, 'spoton://track:a', 0, $optsA);
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientIdB, 'spoton://track:b', 0, $optsB);

    is(scalar(@Slim::Utils::Timers::SET_CALLS), 2, "Fall Isolation: genau zwei setTimer-Aufrufe nach A und B");
    is($Slim::Utils::Timers::SET_CALLS[0][0], $clientIdA, "Fall Isolation: erster setTimer-Aufruf traegt clientIdA");
    is($Slim::Utils::Timers::SET_CALLS[1][0], $clientIdB, "Fall Isolation: zweiter setTimer-Aufruf traegt clientIdB");

    # Nur Bs Handoff ausloesen, nicht As.
    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientIdB);

    # Revision (Ausfuehrung, dokumentiert als Deviation im SUMMARY): die
    # rohe Gesamtzahl der killTimers-Aufrufe nach startHelper($clientIdB)
    # ist NICHT 1 -- startHelper's bestehender, von diesem Plan unveraenderter
    # Stream-Watchdog-Aktivierungscode (DaemonManager.pm, "Same fast-poll
    # activation") ruft IMMER zusaetzlich killTimers($class,
    # \&_streamAlivePoll) auf, sobald ein Helfer alive ist -- unabhaengig
    # von diesem Plan. Ein Tor, das die rohe Gesamtzahl auf 1 verankert,
    # waere ein "Tor, das nicht bestehen kann" (.continue-here.md
    # Anti-Pattern). Gefiltert auf $objRef=$clientIdB isoliert genau den
    # Aufruf, den dieser Fall pruefen soll, und bleibt gegenueber dem
    # unabhaengigen _streamAlivePoll-Aufruf blind.
    my @clientBKills = grep { $_->[0] eq $clientIdB } @Slim::Utils::Timers::KILL_CALLS;
    is(scalar(@clientBKills), 1, "Fall Isolation: genau ein killTimers-Aufruf mit \$objRef=clientIdB nach Bs Handoff");
    is($clientBKills[0][1], \&Plugins::SpotOn::Unified::DaemonManager::_pendingTrackRequestTimeout, "Fall Isolation: dieser killTimers-Aufruf gilt _pendingTrackRequestTimeout");

    # Muss-Fehlschlag-Probe (die Blocker-Regression selbst): ein Rueckbau
    # des Hand-off-Hooks auf killTimers($class, \&_pendingTrackRequestTimeout)
    # (Revision 0) liesse @clientBKills LEER (der Klassenname ist nicht
    # $clientIdB) -- genau diese Assertion wird dann rot, waehrend die
    # rohe Gesamtzahl unveraendert bliebe (die Count-Assertion allein
    # faengt diese Regression nicht -- Begruendung fuer die zweite,
    # objRef-spezifische Assertion oben). Gefiltert auf DENSELBEN Coderef
    # (\&_pendingTrackRequestTimeout), NICHT nur auf $objRef=Klassenname --
    # der bestehende, von diesem Plan unveraenderte _streamAlivePoll-Aufruf
    # traegt den Klassennamen legitim als $objRef unter einem ANDEREN
    # Coderef und wuerde eine reine $objRef-Filterung faelschlich rot
    # machen.
    my @classKeyedPendingKills = grep {
        $_->[0] eq 'Plugins::SpotOn::Unified::DaemonManager'
            && $_->[1] == \&Plugins::SpotOn::Unified::DaemonManager::_pendingTrackRequestTimeout
    } @Slim::Utils::Timers::KILL_CALLS;
    is(scalar(@classKeyedPendingKills), 0, "Fall Isolation: kein _pendingTrackRequestTimeout-killTimers-Aufruf traegt den Klassennamen als \$objRef (Blocker-Fix)");
}

# ============================================================
# Phase 82 Plan 45 (gap closure, WR-01/WR-02/WR-05): the three new cases
# below close the two asymmetric exits of the %pendingTrackRequests
# package-level anchor (82-VERIFICATION.md gaps[0]) and prove the timer
# stub above can now actually fire a registered timer (82-REVIEW.md Zeile
# 109-110).
# ============================================================

# --- Fall Restart-Handoff (WR-02, 82-VERIFICATION.md gaps[0].missing[0]):
# a package-level deferral registered for a client whose SoloistDaemon is
# already constructed but reports alive=false (simulates a crash outside
# stopHelper -- exactly the path _streamAlivePoll observes) must be handed
# off to the (re-)started daemon in startHelper's elsif(!alive) branch,
# not only its if(!helper) construction branch. Muss-Fehlschlag-Probe:
# removing the _handOffPendingTrackRequest call from the elsif branch
# leaves @DEFER_CALLS empty. ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:30';
    my $client   = Test::SyncClient->new(id => $clientId, name => 'Restart Room');
    $Slim::Player::Client::BY_ID{$clientId} = $client;

    @NEW_CALLS   = ();
    @START_CALLS = ();
    @DEFER_CALLS = ();

    # First call constructs the daemon (if(!helper) branch).
    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);
    is(scalar(@NEW_CALLS), 1, "Restart-Handoff: erster startHelper-Aufruf konstruiert den Daemon");

    # Simulate a crash outside stopHelper (the path _streamAlivePoll takes).
    $_TEST_ALIVE{$clientId} = 0;

    my @errorCalls;
    my $opts = { successCb => sub { }, errorCb => sub { push @errorCalls, [@_] } };
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:restart', 0, $opts);

    # Second call runs the elsif(!$helper->alive) restart branch.
    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);

    is(scalar(@START_CALLS), 1, "Restart-Handoff: zweiter startHelper-Aufruf lief in den elsif(!alive)-Restart-Zweig");
    is(scalar(@DEFER_CALLS), 1, "Restart-Handoff: genau ein deferTrackRequest-Hand-off nach dem Neustart (WR-02)");
    is_deeply($DEFER_CALLS[0], [ $clientId, 'spoton://track:restart', 0, $opts ], "Restart-Handoff: der Hand-off traegt die ORIGINALEN uri/posMs/opts unveraendert");
    # WR-01 (82-REVIEW.md Runde 11 Zeile 90-133): the fixed start() stub
    # above consumes an already-pending @DEFER_CALLS entry and fires its
    # errorCb -- on the correctly-ordered elsif branch (hand-off AFTER
    # start()) @DEFER_CALLS is still empty when start() runs, so errorCb
    # must NOT fire. Muss-Fehlschlag-Probe: swapping the hand-off/start()
    # order in DaemonManager.pm makes this assertion (or a neighbor) red.
    is(scalar(@errorCalls), 0, "Restart-Handoff: errorCb NOT fired -- hand-off ran AFTER start()");
}

# --- Fall WR-02 (82-REVIEW.md Runde 11, Zeile 90-133): eine Zurueckstellung
# fuer einen Client OHNE jede Helfer-Instanz darf keinen vollen,
# nicht-inactive-only DaemonManager->shutdown mehr ueberleben --
# shutdown()s Nicht-inactive-only-Zweig iterierte bisher nur
# %helperInstances und liess einen helferlosen Paketebenen-Eintrag
# unangetastet. Gegenprobe: der nachfolgende startHelper-Aufruf muss den
# Konstruktionszweig tatsaechlich erreichen (@NEW_CALLS==1), sonst waere
# @DEFER_CALLS==0 aus dem falschen Grund gruen (BY_ID-Registrierung noetig,
# sonst bricht startHelper am getClient-undef-Ausstieg ab, VOR jeder
# Konstruktion). Muss-Fehlschlag-Probe: shutdown() OHNE die neue
# _releasePendingTrackRequest-Zeile laesst @errorCalls leer. ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;

    my $clientId = 'aa:bb:cc:dd:ee:35';
    my @errorCalls;
    my $opts = { successCb => sub { }, errorCb => sub { push @errorCalls, [@_] } };

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:wr02', 0, $opts);

    Plugins::SpotOn::Unified::DaemonManager->shutdown;

    is(scalar(@errorCalls), 1, "WR-02: errorCb feuert genau einmal fuer eine helferlose Zurueckstellung bei shutdown");
    is_deeply($errorCalls[0], ['PROBLEM_OPENING', 'Soloist daemon shut down'], "WR-02: mit dem shutdown-eigenen Grundtext");

    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    @NEW_CALLS   = ();
    @DEFER_CALLS = ();
    $Slim::Player::Client::BY_ID{$clientId} = Test::SyncClient->new(id => $clientId, name => 'WR-02 Room');

    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);

    is(scalar(@NEW_CALLS), 1, "WR-02: zweiter startHelper erreichte den Konstruktionszweig");
    is(scalar(@DEFER_CALLS), 0, "WR-02: kein Hand-off mehr nach shutdown -- der Anker ist leer");
}

# Phase 82 Plan 50 (WR-04-Marker-Reset fuer die fuenf folgenden Faelle): der
# obige volle shutdown()-Aufruf setzt seit Task 2 den neuen $shuttingDown-
# Marker. Ohne diesen Re-Init wuerde er fuer den REST der Datei gesetzt
# bleiben (kein anderer Reset zwischen t/28-Faellen) und die fuenf
# nachfolgenden Faelle (TTL-Feuern, Isolation-Feuern, stopHelper-Freigabe,
# D-12, Kettenfall) regressieren lassen -- simuliert einen echten
# LMS-Re-Init-Zyklus nach einem Shutdown (der bereits bestehende erste
# init()-Aufruf oben beweist, dass ein zweiter im selben Prozess sicher ist).
Plugins::SpotOn::Unified::DaemonManager->init();

# --- Fall TTL-Feuern (WR-05, 82-REVIEW.md Zeile 109-110): the timer stub
# can now actually fire a registered timer. This proves the ALREADY-correct
# TTL exit (_pendingTrackRequestTimeout) end-to-end -- no production-code
# change is required here, it closes the M-D blind spot (the errorCb line
# in _pendingTrackRequestTimeout was previously unreachable by any test
# because no stub could fire a registered timer). ---
{
    reset_all();
    my $clientId = 'aa:bb:cc:dd:ee:40';
    my @errorCalls;
    my $uri  = 'spoton://track:ttl';
    my $opts = { errorCb => sub { push @errorCalls, [@_]; } };

    @Plugins::SpotOn::Status::RECORDED = ();

    # @Slim::Utils::Timers::TIMERS is a package-global test double, shared
    # across every case above -- several earlier cases (Verdraengung's
    # superseding second deferral, Restart-Handoff on the pre-fix tree)
    # leave their own outer timer registered and never fired/killed.
    # fire_due() below fires EVERY due entry, so without this reset those
    # cross-case leftovers would also fire here and inflate
    # @Plugins::SpotOn::Status::RECORDED beyond this case's own one entry.
    @Slim::Utils::Timers::TIMERS = ();

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, $uri, 0, $opts);

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 21);

    is_deeply($errorCalls[0], [ 'PROBLEM_OPENING', 'Soloist daemon not ready' ], "TTL-Feuern: errorCb feuert mit dem TTL-Text nach fire_due(+21)");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "TTL-Feuern: genau ein Status->recordError-Eintrag");
    is($Plugins::SpotOn::Status::RECORDED[0][3], "$clientId:pending-track-outer:$uri", "TTL-Feuern: der recordError-Schluessel traegt clientId+uri");

    # %pendingTrackRequests must be empty after the fire -- proven
    # indirectly (the hash is package-lexical, not test-visible): a second
    # startHelper() for the SAME clientId would hand off a leftover entry
    # if one still existed.
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    my $client = Test::SyncClient->new(id => $clientId, name => 'TTL Room');
    $Slim::Player::Client::BY_ID{$clientId} = $client;
    @NEW_CALLS   = ();
    @DEFER_CALLS = ();

    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);

    # WR-03 (82-REVIEW.md Runde 11 Zeile 90-133): asserts the construction
    # branch was actually REACHED, not just that no hand-off occurred --
    # an early exit from startHelper (e.g. the backend-prereq gate) would
    # otherwise be indistinguishable from a correctly-drained anchor.
    is(scalar(@NEW_CALLS), 1, "TTL-Feuern: der zweite startHelper-Aufruf erreichte den Konstruktionszweig");
    is(scalar(@DEFER_CALLS), 0, "TTL-Feuern: %pendingTrackRequests ist nach dem Feuern leer (kein Hand-off am zweiten startHelper-Aufruf)");
}

# --- Fall Isolation-Feuern (WR-05, kombiniert mit dem bereits korrekten
# Hand-off am Konstruktionszweig): zwei ausstehende Paketebenen-
# Zurueckstellungen (A, B). startHelper(B) haengt Bs Zurueckstellung an den
# neu konstruierten Daemon durch (killt Bs Timer dabei) -- fire_due(+21)
# darf danach NUR noch As errorCb feuern, nicht Bs (B hat inzwischen einen
# Daemon und keinen offenen Paketebenen-Eintrag mehr). ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientIdA = 'aa:bb:cc:dd:ee:50';
    my $clientIdB = 'aa:bb:cc:dd:ee:51';
    my $clientB   = Test::SyncClient->new(id => $clientIdB, name => 'Isolation Feuern B');
    $Slim::Player::Client::BY_ID{$clientIdB} = $clientB;

    # See the identical reset+comment in Fall TTL-Feuern above -- same
    # cross-case leftover-timer hazard for this case's own fire_due() call.
    @Slim::Utils::Timers::TIMERS = ();

    my (@errorCallsA, @errorCallsB);
    my $optsA = { errorCb => sub { push @errorCallsA, [@_]; } };
    my $optsB = { errorCb => sub { push @errorCallsB, [@_]; } };

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientIdA, 'spoton://track:iso-a', 0, $optsA);
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientIdB, 'spoton://track:iso-b', 0, $optsB);

    @NEW_CALLS   = ();
    @DEFER_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientIdB);
    is(scalar(@DEFER_CALLS), 1, "Isolation-Feuern: startHelper(B) haengt Bs Zurueckstellung an den neuen Daemon durch");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 21);

    is(scalar(@errorCallsA), 1, "Isolation-Feuern: As errorCb feuert genau einmal nach fire_due(+21)");
    is(scalar(@errorCallsB), 0, "Isolation-Feuern: Bs errorCb feuert NICHT (B hat einen Daemon, keinen offenen Paketebenen-Eintrag mehr)");
}

# --- Fall stopHelper-Freigabe (WR-01, 82-VERIFICATION.md gaps[0].missing[1]):
# stopHelper must release an open outer deferral with the same errorCb
# discipline deferTrackRequestForClient's own Fall-5 supersession and
# SoloistDaemon::_shutdownExistingControl already use -- today it only
# delete+killTimers, silently discarding the caller's callback (M-C,
# 82-REVIEW.md Zeile 68 "unentdeckt"). Muss-Fehlschlag-Probe: reverting to
# the old delete+killTimers-only block leaves the errorCb assertion red. ---
{
    reset_all();
    my $clientId = 'aa:bb:cc:dd:ee:60';
    my @errorCalls;
    my $opts = { errorCb => sub { push @errorCalls, [@_]; } };

    @Slim::Utils::Timers::KILL_CALLS = ();

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:stop', 0, $opts);

    Plugins::SpotOn::Unified::DaemonManager->stopHelper($clientId);

    is(scalar(@errorCalls), 1, "stopHelper-Freigabe: errorCb feuert genau einmal");
    is_deeply($errorCalls[0], [ 'PROBLEM_OPENING', 'Soloist daemon shut down' ], "stopHelper-Freigabe: errorCb traegt den stopHelper-Text (WR-01)");

    my @clientKills = grep {
        $_->[0] eq $clientId
            && $_->[1] == \&Plugins::SpotOn::Unified::DaemonManager::_pendingTrackRequestTimeout
    } @Slim::Utils::Timers::KILL_CALLS;
    is(scalar(@clientKills), 1, "stopHelper-Freigabe: genau ein killTimers-Aufruf fuer \$clientId/_pendingTrackRequestTimeout");
}

# --- D-12 (82-46 Task 2, WR-04, DaemonManager als Verbraucher):
# deferTrackRequestForClient liest eine vorgesetzte deferDeadline aus
# $opts, statt selbst eine neue Frist zu berechnen -- derselbe
# geteilte deadlineFor-Aufruf, den auch SoloistDaemon und Control
# nutzen (M-E deckt diese Stelle bereits mit ab, keine eigene
# unabhaengige Berechnung existiert hier zum Zurueckbauen). ---
{
    reset_all();
    @Slim::Utils::Timers::SET_CALLS = ();

    my $clientId = 'aa:bb:cc:dd:ee:70';
    my $opts = { errorCb => sub { }, deferDeadline => 1234567890.5 };

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:d12', 0, $opts);

    is($Slim::Utils::Timers::SET_CALLS[0][1], 1234567890.5,
        "D-12: deferTrackRequestForClient liest die vorgesetzte Frist anstatt sie selbst zu berechnen");
}

# --- Kettenfall (D-12, 82-46 Task 2, WR-02-Hand-off aus 82-45
# wiederverwendet): eine Zurueckstellung OHNE vorgesetzte deferDeadline
# registrieren -- DaemonManager berechnet die EINE Frist selbst
# (deferTrackRequestForClient). startHelper's Konstruktionszweig
# (_handOffPendingTrackRequest, WR-02) muss diese Frist unveraendert an
# SoloistDaemon::deferTrackRequest weiterreichen, nicht neu rechnen.
# Muss-Fehlschlag: ein Rueckbau, der die Frist am Hand-off neu
# berechnet statt sie durchzureichen, laesst die zweite Assertion rot
# fallen (die beiden Fristen liefen dann auseinander). ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:71';
    my $client   = Test::SyncClient->new(id => $clientId, name => 'D-12 Kette');
    $Slim::Player::Client::BY_ID{$clientId} = $client;

    @NEW_CALLS   = ();
    @DEFER_CALLS = ();
    @Slim::Utils::Timers::SET_CALLS = ();

    my $opts = { successCb => sub { }, errorCb => sub { } };
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:d12-kette', 0, $opts);

    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);

    is(scalar(@DEFER_CALLS), 1, "D-12 Kette: exakt ein Hand-off nach der Konstruktion");
    is($DEFER_CALLS[0][3]{deferDeadline}, $Slim::Utils::Timers::SET_CALLS[0][1],
        "D-12 Kette: dieselbe, einmalig berechnete Frist reist unveraendert von der Paketebene zur Instanzebene");
}

# --- Fall WR-04 (82-REVIEW.md Zeile 50-91, 82-VERIFICATION.md gaps[0],
# Richtung B): ein reentranter deferTrackRequestForClient-Wiedereintritt
# WAEHREND desselben vollen shutdown()-Durchlaufs darf keinen zweiten
# Paketebenen-Eintrag/-Timer mehr anlegen. Simuliert hier direkt den von
# 82-REVIEW.md beschriebenen LMS-Wiedereintritt (stopHelper -> errorCb ->
# Control::shutdown meldet ab -> zweiter Wiedereintritt ueber
# ProtocolHandler Fall 2 -> deferTrackRequestForClient), ohne die volle
# stopHelper/Control-Kette nachzubilden -- reiner Testcode, wie schon die
# Verifikation selbst. Muss-Fehlschlag-Probe (gegen den heutigen,
# ungeschuetzten Baum): innerErrorCalls bleibt 0 (kein Guard weist den
# reentranten Aufruf ab), der Timer-Gegenprobe nach shutdown() zeigt einen
# verbleibenden Timer, und @DEFER_CALLS zeigt einen Hand-off nach dem
# spaeteren startHelper -- WR-02s Klasse ueber die Reentranz wiedereingefuehrt.
# Nach Plan 51 Task 1s Rueckbau auf die einmalige for-keys-Momentaufnahme
# neu verortet (82-VERIFICATION.md Runde 8 Advisory, 82-REVIEW.md Runde 13
# WR-02): die Guard-Diskriminierung dieses Falls haengt jetzt direkt an der
# unten stehenden @armedForClient-Zaehlung, nicht mehr (nur noch zufaellig)
# an der Wechselwirkung mit einer bestimmten Drain-Schleifenform. ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:80';
    @Slim::Utils::Timers::TIMERS = ();

    my @innerErrorCalls;
    my $innerOpts = { errorCb => sub { push @innerErrorCalls, [@_]; } };

    my @outerErrorCalls;
    my $reentered = 0;
    my $outerOpts = {
        successCb => sub { },
        errorCb   => sub {
            push @outerErrorCalls, [@_];
            unless ($reentered++) {
                Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient(
                    $clientId, 'spoton://track:wr04-reentrant', 0, $innerOpts
                );
            }
        },
    };

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:wr04-outer', 0, $outerOpts);

    # Draeniert nebenbei auch den offenen D-12-Eintrag aa:bb:cc:dd:ee:70 mit --
    # harmlos, dessen errorCb ist ein No-op, hier nur benannt statt
    # stillschweigend mitgenommen (Info-Befund, task_completeness).
    Plugins::SpotOn::Unified::DaemonManager->shutdown;

    is(scalar(@outerErrorCalls), 1, "WR-04: die aeussere Zurueckstellung wird genau einmal freigegeben");
    is(scalar(@innerErrorCalls), 1, "WR-04: der reentrante Wiedereintritt wird SOFORT vom Shutdown-Marker abgewiesen, nicht als neuer Eintrag uebernommen");
    is_deeply($innerErrorCalls[0], ['PROBLEM_OPENING', 'Soloist daemon shut down'], "WR-04: der reentrante Aufruf traegt denselben shutdown-Text wie die aeussere Freigabe");

    my @clientTimersAfterShutdown = grep { $_->[0] eq $clientId } @Slim::Utils::Timers::TIMERS;
    is(scalar(@clientTimersAfterShutdown), 0, "WR-04: kein verbleibender _pendingTrackRequestTimeout-Timer fuer \$clientId unmittelbar nach shutdown (VOR jedem spaeteren startHelper)");

    my @armedForClient = grep { $_->[0] eq $clientId && $_->[2] == \&Plugins::SpotOn::Unified::DaemonManager::_pendingTrackRequestTimeout } @Slim::Utils::Timers::SET_CALLS;
    is(scalar(@armedForClient), 1, "WR-04: waehrend shutdown wurde fuer \$clientId nur EIN _pendingTrackRequestTimeout-Timer armiert (Guard, nicht die Drain-Form, verhindert eine zweite Anlage)");

    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    @NEW_CALLS   = ();
    @DEFER_CALLS = ();
    $Slim::Player::Client::BY_ID{$clientId} = Test::SyncClient->new(id => $clientId, name => 'WR-04 Room');

    Plugins::SpotOn::Unified::DaemonManager->startHelper($clientId);

    is(scalar(@NEW_CALLS), 1, "WR-04: startHelper nach shutdown erreichte den Konstruktionszweig");
    is(scalar(@DEFER_CALLS), 0, "WR-04: kein Hand-off mehr nach shutdown -- der reentrante Eintrag ueberlebt NICHT (Gegenprobe zum WR-02-Muster)");
}

# --- Fall WR-04-Restart (82-REVIEW.md Runde 14 WR-01, Advisory): der
# Reentranz-Guard ($shuttingDown) ist auf dem 'restart'-Pfad -- dem
# einzigen, den die beiden Produktions-Aufrufer benutzen -- bisher durch
# KEINEN Test gedeckt. Faengt dieselben zwei bereits gemessenen
# Mutationsproben wie das Review (mB: Guard-Setzen um 'restart'
# erweitert, mE: Freigabezeile an den Blockanfang statt ans Blockende
# verschoben). NICHT woertlich aus der Review-Vorlage uebernommen: die
# Vorlage beginnt direkt mit reset_all(), OHNE eigenen init()-Aufruf --
# auf dem heutigen Zustand von t/28 endet das direkt vorausgehende Fall
# WR-04 mit einem modus-losen, permanenten shutdown(), der $shuttingDown
# dauerhaft latcht (nichts danach setzt ihn zurueck). Ohne einen frischen
# init()-Aufruf hier waere der AEUSSERE deferTrackRequestForClient-Aufruf
# dieses Falls bereits VOR jedem shutdown('restart') synchron abgewiesen
# -- die dritte Zusicherung ("nur EIN Timer armiert") laese dann
# got:'0'/expected:'1' SELBST AUF DEM BEREITS GEFIXTEN BAUM (vom Planner
# gemessen) -- ein Tor, das nicht bestehen kann. Der init()-Aufruf unten
# ist die notwendige Korrektur, identisches Determinismus-Muster wie vor
# Fall WR-03-Permanent. ---
{
    Plugins::SpotOn::Unified::DaemonManager->init();

    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:83';
    @Slim::Utils::Timers::TIMERS = ();

    my (@innerErrorCalls, @outerErrorCalls);
    my $reentered = 0;

    my $innerOpts = { errorCb => sub { push @innerErrorCalls, [@_] } };
    my $outerOpts = {
        errorCb => sub {
            push @outerErrorCalls, [@_];
            Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:wr04r-reentrant', 0, $innerOpts) unless $reentered++;
        },
    };

    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient($clientId, 'spoton://track:wr04r-outer', 0, $outerOpts);
    Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');

    is(scalar(@innerErrorCalls), 1, "WR-04-Restart: der reentrante Wiedereintritt wird auch unter shutdown('restart') SOFORT abgewiesen");
    is_deeply($innerErrorCalls[0], ['PROBLEM_OPENING', 'Soloist daemon shut down'], "WR-04-Restart: mit dem shutdown-eigenen Grundtext");

    my @armed = grep { $_->[0] eq $clientId && $_->[2] == \&Plugins::SpotOn::Unified::DaemonManager::_pendingTrackRequestTimeout } @Slim::Utils::Timers::SET_CALLS;
    is(scalar(@armed), 1, "WR-04-Restart: waehrend shutdown('restart') nur EIN Timer fuer \$clientId armiert");
}

# --- Fall WR-03-Restart (82-REVIEW.md Runde 13 WR-03, 82-VERIFICATION.md
# Runde 8 gaps[1]): shutdown('restart') muss eine LEGITIME, NICHT-
# reentrante Zurueckstellung, die in der asynchronen Luecke VOR
# initHelpers() eintrifft, queuen statt dauerhaft abweisen -- den beiden
# echten Produktions-Neustart-Aufrufern (TokenManager::removeAccount,
# Plugin.pm's diagnosticMode-Handler) vorbehalten. Ersetzt den frueheren,
# in seiner Bedeutung ueberholten Resume-Fall (82-50-PLAN.md Task 2):
# dessen Vor-Resume-Zusicherung hatte die
# GEGENTEILIGE Bedeutung (Abweisung als gewuenscht) -- shutdown('restart')
# behandelt den Marker anders als ein modus-loser Aufruf, also wird
# waehrend der Restart-Luecke gequeued, nicht abgewiesen. ---
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:81';
    @Slim::Utils::Timers::TIMERS = ();

    Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');

    # Waehrend der Restart-Luecke (VOR initHelpers()): eine frische,
    # nicht-reentrante Zurueckstellung MUSS queuen, nicht abgewiesen werden.
    my @duringGapErrorCalls;
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient(
        $clientId, 'spoton://track:wr03-during-gap', 0,
        { errorCb => sub { push @duringGapErrorCalls, [@_]; } }
    );
    is(scalar(@duringGapErrorCalls), 0, "WR-03: shutdown('restart') laesst eine Zurueckstellung waehrend der Restart-Luecke queuen, nicht abweisen (Case-2-Fenster vor initHelpers())");

    my @clientTimersDuringGap = grep { $_->[0] eq $clientId } @Slim::Utils::Timers::TIMERS;
    is(scalar(@clientTimersDuringGap), 1, "WR-03: die waehrend der Restart-Luecke registrierte Zurueckstellung erhielt ihren regulaeren TTL-Timer (Beleg fuer Queuing, nicht Abweisung)");

    # Der echte Wiederaufnahmepfad: initHelpers() (beide Produktions-
    # Aufrufer erreichen NUR das, keiner ruft init() erneut).
    Plugins::SpotOn::Unified::DaemonManager::initHelpers();

    my @resumeErrorCalls;
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient(
        $clientId, 'spoton://track:wr03-after-resume', 0,
        { errorCb => sub { push @resumeErrorCalls, [@_]; } }
    );
    is(scalar(@resumeErrorCalls), 0, "WR-03: nach initHelpers() (der tatsaechlichen Wiederaufnahme) registriert ein weiterer Aufruf ebenfalls normal -- der Marker bleibt nach dem Restart-Fenster durchgehend offen");

    # Aufraeumen: die beiden waehrend dieses Falls registrierten offenen
    # Zurueckstellungen freigeben (modus-los, reines Aufraeumen -- derselbe
    # Zweck wie im fruehereren Fall, jetzt fuer zwei statt einer).
    Plugins::SpotOn::Unified::DaemonManager->shutdown;
}

# --- Fall WR-03-Permanent (82-REVIEW.md Runde 13 WR-03, Regressionssperre):
# eine echte DAUERHAFTE Abschaltung (shutdownPlugin-Form, kein Modus) muss
# weiterhin dauerhaft abweisen -- die Restart-Ausnahme gilt NICHT fuer die
# permanente Form. Sperrt explizit gegen die naheliegende Fehllesung
# "jeder shutdown() queued jetzt". Eigenstaendig, unabhaengig vom
# Restzustand aus Block A (deshalb der eigene init()-Aufruf zu Beginn,
# dasselbe Re-Init-Muster wie vor Fall WR-02 oben). ---
{
    Plugins::SpotOn::Unified::DaemonManager->init();

    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

    my $clientId = 'aa:bb:cc:dd:ee:82';
    @Slim::Utils::Timers::TIMERS = ();

    Plugins::SpotOn::Unified::DaemonManager->shutdown;

    my @permanentErrorCalls;
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient(
        $clientId, 'spoton://track:wr03-permanent', 0,
        { errorCb => sub { push @permanentErrorCalls, [@_]; } }
    );
    is(scalar(@permanentErrorCalls), 1, "WR-03-Permanent: ein dauerhafter shutdown() (shutdownPlugin-Form, ohne Modus) weist eine Zurueckstellung im Vor-Resume-Fenster weiterhin ab -- die Restart-Ausnahme gilt NICHT fuer die permanente Abschaltung");
    is_deeply($permanentErrorCalls[0], ['PROBLEM_OPENING', 'Soloist daemon shut down'], "WR-03-Permanent: mit dem shutdown-eigenen Grundtext");

    # 82-52 Task 4 (WR-02, Advisory): die initHelpers()-Rueckfallebene
    # ($shuttingDown = 0; in initHelpers(), DaemonManager.pm)
    # hatte mit dem Ersetzen von Fall "WR-04-Resume" durch "WR-03-Restart"/
    # "WR-03-Permanent" (Plan 51) ihr eigenes Tor verloren -- die
    # Code-Eigenschaft selbst war unveraendert und korrekt, nur die
    # spezifische Testdiskriminierung fehlte.
    Plugins::SpotOn::Unified::DaemonManager::initHelpers();

    my @afterResumeErrorCalls;
    Plugins::SpotOn::Backend::Soloist->deferTrackRequestForClient(
        $clientId, 'spoton://track:wr03-permanent-resumed', 0,
        { errorCb => sub { push @afterResumeErrorCalls, [@_] } }
    );
    is(scalar(@afterResumeErrorCalls), 0, "WR-03-Permanent: initHelpers() (Watchdog/Client-Ereignis) hebt auch die permanente Sperre wieder auf -- Rueckfallebene traegt");

    Plugins::SpotOn::Unified::DaemonManager->shutdown;
}

# --- Fall Modus-Validierung (82-REVIEW.md Runde 14 WR-04): ein
# unbekannter, definierter shutdown()-Modus (z.B. ein Tippfehler) muss
# $log->error() mit dem woertlichen Modus-String melden, statt still in
# die permanente Form zu fallen. Der Kontrollfluss selbst bleibt
# unveraendert -- ein unbekannter Modus faellt weiterhin (wie zuvor) in
# die permanente Form, nur jetzt mit einem Diagnosehinweis. ---
{
    reset_all();
    @LOG_ERROR_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');
    is(scalar(@LOG_ERROR_CALLS), 0, "Modus-Validierung: ein bekannter Modus ('restart') loggt keinen Fehler");

    @LOG_ERROR_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->shutdown('inactive-only');
    is(scalar(@LOG_ERROR_CALLS), 0, "Modus-Validierung: der Minutenmodus 'inactive-only' (aufgerufen aus initHelpers()) loggt keinen Fehler");

    @LOG_ERROR_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->shutdown('Restart');
    is(scalar(@LOG_ERROR_CALLS), 1, "Modus-Validierung: ein unbekannter Modus loggt genau einen \$log->error()-Aufruf");
    ok((defined $LOG_ERROR_CALLS[0][0] && index($LOG_ERROR_CALLS[0][0], 'Restart') >= 0), "Modus-Validierung: die Fehlermeldung nennt den unbekannten Modus-String woertlich");
}

# --- Fall WR-03-Subscriptions (82-VERIFICATION.md Runde 9 gaps[0],
# 82-REVIEW.md Runde 14 WR-03): shutdown('restart') darf die Client-/
# Sync-Subscriptions NICHT abmelden -- nur init() (laut Plugin.pm:419
# genau EINMAL pro LMS-Prozess) meldet sie je wieder an; beide echten
# Neustart-Aufrufer (TokenManager::removeAccount, Plugin.pm's
# diagnosticMode-Handler) erreichen ausschliesslich initHelpers(), das
# NICHT erneut subscribe() aufruft. Ein dauerhafter (modus-loser)
# shutdown() muss dagegen weiterhin BEIDE Handler abmelden -- die
# Restart-Ausnahme gilt NUR fuer 'restart'. ---
{
    Plugins::SpotOn::Unified::DaemonManager->init();
    my @registered = map { "$_->[0]" } @Slim::Control::Request::SUBSCRIPTIONS[-2, -1];

    @Slim::Control::Request::UNSUBSCRIBE_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');
    is(scalar(@Slim::Control::Request::UNSUBSCRIBE_CALLS), 0, "WR-03-Subscriptions: shutdown('restart') meldet die Client-/Sync-Handler NICHT ab -- niemand sonst wuerde sie wieder anmelden");

    @Slim::Control::Request::UNSUBSCRIBE_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->shutdown;
    is(scalar(@Slim::Control::Request::UNSUBSCRIBE_CALLS), 2, "WR-03-Subscriptions: ein dauerhafter (modus-loser) shutdown() meldet beide Handler weiterhin ab");
    is_deeply([ sort map { "$_" } @Slim::Control::Request::UNSUBSCRIBE_CALLS ], [ sort @registered ], "WR-03-Subscriptions: abgemeldet wird genau das von init() registrierte Paar (Identitaet, nicht nur Anzahl)");
}

# --- Fall WR-02-Idempotent (82-REVIEW.md Runde 15 WR-02): init() muss
# ein bereits registriertes $clientSubRef/$syncSubRef-Paar abmelden,
# bevor es ein neues zuweist/abonniert -- sonst haengen die alten
# Coderefs nach einem zweiten init()-Aufruf im selben Prozess
# unerreichbar und unabmeldbar in Slim::Control::Request. ---
{
    Plugins::SpotOn::Unified::DaemonManager->init();
    my @survivors = map { "$_->[0]" } @Slim::Control::Request::SUBSCRIPTIONS[-2, -1];
    Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');

    @Slim::Control::Request::UNSUBSCRIBE_CALLS = ();
    Plugins::SpotOn::Unified::DaemonManager->init();
    my @fresh = map { "$_->[0]" } @Slim::Control::Request::SUBSCRIPTIONS[-2, -1];
    is(scalar(@Slim::Control::Request::UNSUBSCRIBE_CALLS), 2, "WR-02-Idempotent: init() nach shutdown('restart') meldet das ueberlebende Paar ab, bevor es neu subscribt");
    is_deeply([ sort map { "$_" } @Slim::Control::Request::UNSUBSCRIBE_CALLS ], [ sort @survivors ], "WR-02-Idempotent: abgemeldet wird genau das ueberlebende Paar (Identitaet, nicht nur Anzahl)");
    my %unsubscribed = map { ("$_" => 1) } @Slim::Control::Request::UNSUBSCRIBE_CALLS;
    is(scalar(grep { $unsubscribed{$_} } @fresh), 0, "WR-02-Idempotent: das frisch subscribte Paar bleibt registriert -- Abmeldung liegt VOR dem subscribe()");

    Plugins::SpotOn::Unified::DaemonManager->shutdown;
}

# ============================================================
# 74b-03 Task 1 (D-09): glibc below 2.38 under the Soloist backend is one
# standing 'error' entry (module Soloist, key glibc). Message only: the
# start path, backendName and platformSupportsSoloist stay untouched.
# The probe argv lists are the @GLIBC_PROBES seam; every case points them
# at a tiny executable fake script in a tempdir, so no real tool runs.
# ============================================================
{
    my @REAL_PROBES = @Plugins::SpotOn::Unified::DaemonManager::GLIBC_PROBES;   # restored at the end
    my $pdir = tempdir(CLEANUP => 1);
    my $nProbe = 0;
    my $fake = sub {
        my ($stdout) = @_;
        my $path = "$pdir/probe" . (++$nProbe) . ".sh";
        open(my $fh, '>', $path) or die "probe: $!";
        print $fh "#!/bin/sh\n";
        print $fh (length $stdout ? "printf '%s\\n' '$stdout'\n" : "exit 0\n");
        close $fh;
        chmod 0755, $path;
        return $path;
    };
    my $DM = 'Plugins::SpotOn::Unified::DaemonManager';
    my $glibcEntries = sub {
        return [ grep { ($_->[1] // '') eq 'Soloist' && ($_->[3] // '') eq 'glibc' } @Plugins::SpotOn::Status::RECORDED ];
    };
    my $setup = sub {
        my ($getconfOut, $lddOut) = @_;
        @Plugins::SpotOn::Status::RECORDED = ();
        @Plugins::SpotOn::Unified::DaemonManager::GLIBC_PROBES = (
            [ $fake->($getconfOut) ],
            [ $fake->($lddOut) ],
        );
        $DM->_resetGlibcCache();
    };

    can_ok($DM, qw(glibcVersion soloistGlibcProblem assertStandingConditions _resetGlibcCache));
    is(Plugins::SpotOn::Unified::DaemonManager::SOLOIST_MIN_GLIBC(), '2.38', "74b-03 D-09: SOLOIST_MIN_GLIBC is 2.38");

    {
        local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

        $setup->('glibc 2.36', '');
        is($DM->glibcVersion(), '2.36', "74b-03 D-09: getconf line 'glibc 2.36' parses to 2.36");
        $DM->assertStandingConditions();
        my $e = $glibcEntries->();
        is(scalar(@$e), 1, "74b-03 D-09: glibc 2.36 under soloist records exactly one entry");
        is($e->[0][0], 'error', "74b-03 D-09: the glibc entry is level error (standing, never expires)");
        is($e->[0][1], 'Soloist', "74b-03 D-09: module Soloist");
        like($e->[0][2] // '', qr/2\.36/, "74b-03 D-09: message names the detected version");
        like($e->[0][2] // '', qr/2\.38/, "74b-03 D-09: message names the required version");
        like($e->[0][2] // '', qr/Debian 13/, "74b-03 D-09: message names 'Raspberry Pi OS Trixie / Debian 13 or newer'");
        unlike($e->[0][2] // '', qr/\x{2014}|\x{2013}/, "74b-03 D-09: message holds no em or en dash");
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 1, "74b-03 D-09: a second call records no duplicate");

        @Plugins::SpotOn::Status::RECORDED = ();
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 1, "74b-03 D-09 T-74b-11: the entry is re-asserted into an emptied (evicted) ring");

        # the probe result is cached for the process lifetime: a changed
        # probe is not re-run until _resetGlibcCache
        @Plugins::SpotOn::Unified::DaemonManager::GLIBC_PROBES = ([ $fake->('glibc 2.40') ]);
        is($DM->glibcVersion(), '2.36', "74b-03 D-09: glibcVersion is cached for the process lifetime");

        # an existing entry is cleared once the version is fine
        $setup->('glibc 2.38', '');
        Plugins::SpotOn::Status->recordError('error', 'Soloist', 'stale glibc message', 'glibc');
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 0, "74b-03 D-09: glibc 2.38 (the minimum) is fine and clears an existing entry");

        $setup->('glibc 2.43', '');
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 0, "74b-03 D-09: glibc 2.43 records nothing");

        # numeric major/minor comparison, not string: 2.4 is below 2.38
        $setup->('glibc 2.4', '');
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 1, "74b-03 D-09: version compare is numeric per component (2.4 < 2.38)");

        # ldd fallback when getconf prints nothing
        $setup->('', 'ldd (Debian GLIBC 2.36-9+deb12u4) 2.36');
        is($DM->glibcVersion(), '2.36', "74b-03 D-09: ldd line naming GLIBC and ending in MAJOR.MINOR is accepted");
        $setup->('', 'ldd (GNU libc) 2.35');
        is($DM->glibcVersion(), '2.35', "74b-03 D-09: ldd line 'GNU libc' is accepted");

        # musl: no guess, no entry
        $setup->('', 'musl libc (x86_64)');
        is($DM->glibcVersion(), undef, "74b-03 D-09: musl ldd output yields no version");
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 0, "74b-03 D-09: musl records no entry (no guess)");

        # an unrelated tool line with a trailing number is not a glibc version
        $setup->('', 'ldd (some other loader) 9.9');
        is($DM->glibcVersion(), undef, "74b-03 D-09: an ldd line that does not name GLIBC or GNU libc is ignored");

        # the message is a message only: the start path decisions stay
        $setup->('glibc 2.36', '');
        is($DM->backendName(), 'soloist', "74b-03 D-09: backendName stays soloist on an old glibc (no automatic fallback)");
        ok($DM->platformSupportsSoloist(), "74b-03 D-09: platformSupportsSoloist unchanged on an old glibc");
        is($DM->soloistGlibcProblem() =~ /2\.36/ ? 1 : 0, 1, "74b-03 D-09: soloistGlibcProblem returns the message for 2.36");
        $setup->('glibc 2.43', '');
        is($DM->soloistGlibcProblem(), undef, "74b-03 D-09: soloistGlibcProblem is undef on 2.43");
    }

    # backend librespot -> no entry
    # 79-25 (NA-1): on the librespot-removed CI leg the librespot backend is not in the tree and
    # backendName() falls back to the first available role (84-12 W5): soloist. The two cells
    # then assert that fallback instead; a tree that lost only Backend/Librespot.pm dies in
    # amputation_state(), it is never read as a leg.
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'librespot';
        $setup->('glibc 2.36', '');
        $DM->assertStandingConditions();
        if (amputation_state($project_dir, 'librespot') eq 'present') {
            is(scalar(@{ $glibcEntries->() }), 0, "74b-03 D-09: backend librespot records no glibc entry");
            is($DM->soloistGlibcProblem(), undef, "74b-03 D-09: soloistGlibcProblem is undef under librespot");
        }
        else {
            is($DM->backendName(), 'soloist',
                "74b-03 D-09: librespot side amputated -- backend pref librespot falls back to soloist (84-12 W5)");
            is(scalar(@{ $glibcEntries->() }), 1,
                "74b-03 D-09: librespot side amputated -- the fallback soloist backend records the glibc entry");
        }
    }

    # platform without Soloist -> no entry
    {
        local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
        local $main::FAKE_ISWINDOWS = 1;
        $setup->('glibc 2.36', '');
        $DM->assertStandingConditions();
        is(scalar(@{ $glibcEntries->() }), 0, "74b-03 D-09: a platform without Soloist records no glibc entry");
    }

    # 79-05 (D-12): soloistGlibcOk() is the one glibc floor comparison (the
    # settings hint reuses it; soloistGlibcProblem calls it): 1 / 0 / undef.
    {
        my $glibcOk = sub { return $DM->can('soloistGlibcOk') ? $DM->soloistGlibcOk() : 'MISSING-METHOD' };
        $setup->('glibc 2.36', '');
        is($glibcOk->(), 0, "79-05 D-12: glibc 2.36 is below the floor -> 0");
        $setup->('glibc 2.38', '');
        is($glibcOk->(), 1, "79-05 D-12: glibc 2.38 (the floor) -> 1");
        $setup->('glibc 2.40', '');
        is($glibcOk->(), 1, "79-05 D-12: glibc 2.40 -> 1");
        $setup->('glibc 2.4', '');
        is($glibcOk->(), 0, "79-05 D-12: 2.4 is below 2.38 (numeric per component) -> 0");
        $setup->('', 'musl libc (x86_64)');
        is($glibcOk->(), undef, "79-05 D-12: not detectable (musl) -> undef");
        # soloistGlibcProblem keeps its behaviour on top of it
        {
            local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
            $setup->('glibc 2.36', '');
            like($DM->soloistGlibcProblem() // '', qr/2\.36/, "79-05 D-12: soloistGlibcProblem message unchanged at 2.36");
            $setup->('glibc 2.40', '');
            is($DM->soloistGlibcProblem(), undef, "79-05 D-12: soloistGlibcProblem undef at 2.40");
            $setup->('', 'musl libc (x86_64)');
            is($DM->soloistGlibcProblem(), undef, "79-05 D-12: soloistGlibcProblem undef when not detectable");
        }
    }

    # T-74b-08: the probe never goes through a shell
    {
        my $cwd = tempdir(CLEANUP => 1);
        my $script = $fake->('glibc 2.36');
        @Plugins::SpotOn::Unified::DaemonManager::GLIBC_PROBES = ([ $script, '; touch PWNED_FILE' ]);
        $DM->_resetGlibcCache();
        require Cwd;
        my $here = Cwd::getcwd();
        chdir $cwd or die "chdir: $!";
        my $v = $DM->glibcVersion();
        chdir $here or die "chdir back: $!";
        is($v, '2.36', "74b-03 T-74b-08: the argv probe still runs with a hostile second element");
        ok(!-e "$cwd/PWNED_FILE", "74b-03 T-74b-08: a shell metacharacter in the probe argv creates no PWNED_FILE (no shell)");
    }

    # the real probes are the documented argv lists
    {
        # restore the production seam value by re-reading it from a fresh interpreter view
        my $src = do { local (@ARGV, $/) = ($module); <> };
        like($src, qr/our\s+\@GLIBC_PROBES\s*=\s*\(\s*\[\s*'getconf'\s*,\s*'GNU_LIBC_VERSION'\s*\]\s*,\s*\[\s*'ldd'\s*,\s*'--version'\s*\]\s*\)/,
            "74b-03 T-74b-08: the shipped probes are the fixed argv lists getconf GNU_LIBC_VERSION and ldd --version");
        my ($body) = $src =~ /(sub initHelpers \{.*?)\nsub /s;
        like($body // '', qr/assertStandingConditions/, "74b-03 T-74b-11: initHelpers re-asserts the standing conditions");
    }

    @Plugins::SpotOn::Unified::DaemonManager::GLIBC_PROBES = @REAL_PROBES;
    $DM->_resetGlibcCache();
    @Plugins::SpotOn::Status::RECORDED = ();
}

# 74b-03 Task 2 (D-09): under the Soloist backend a librespot audio-key
# entry is stale by definition - assertStandingConditions clears it for every
# account in the prefs.
{
    my $DM = 'Plugins::SpotOn::Unified::DaemonManager';
    local $Slim::Utils::Prefs::FAKE_VALUES{backend}  = 'soloist';
    local $Slim::Utils::Prefs::FAKE_VALUES{accounts} = { 'ACCTsoloist0001' => {}, 'ACCTsoloist0002' => {} };
    @Plugins::SpotOn::Status::RECORDED = ();
    Plugins::SpotOn::Status->recordError('error', 'Connect', 'stale denied', 'audiokey:ACCTsoloist0001');
    Plugins::SpotOn::Status->recordError('warn',  'Connect', 'stale throttled', 'audiokey:ACCTsoloist0002');
    Plugins::SpotOn::Status->recordError('warn',  'Connect', 'unrelated', 'daemon_unreachable:aa');
    $DM->assertStandingConditions();
    is_deeply([ map { $_->[3] } @Plugins::SpotOn::Status::RECORDED ], [ 'daemon_unreachable:aa' ],
        "74b-03 D-09: backend soloist clears every audiokey entry and leaves unrelated entries alone");
    @Plugins::SpotOn::Status::RECORDED = ();
}

# ============================================================
# 74b-03 Task 3 (T-74b-25): the boot-time orphan sweep removes the Soloist
# logs (MAC-soloist.log and MAC-soloist.log.1) of players that are gone, behind
# the same connected-client check and 300 s mtime guard as MAC-unified.log.
# A connected player's log, a fresh orphan and a non-MAC name stay.
# ============================================================
{
    my $cache = tempdir(CLEANUP => 1);
    my $dir   = "$cache/spoton";
    make_path($dir);
    local $Slim::Utils::Prefs::FAKE_VALUES{cachedir} = $cache;

    my $touch = sub {
        my ($name, $age) = @_;
        open(my $fh, '>', "$dir/$name") or die "$name: $!";
        print $fh "x\n";
        close $fh;
        my $t = time() - $age;
        utime($t, $t, "$dir/$name") or die "utime $name: $!";
    };
    my %expect = (
        'aabbccddeeff-soloist.log'    => [ 400, 0 ],
        'aabbccddeeff-soloist.log.1'  => [ 400, 0 ],
        'aabbccddeeff-soloist.log.1.tmp' => [ 400, 0 ],
        '112233445566-soloist.log.1.tmp' => [ 10,  1 ],
        '0200005a1101-soloist.log.1.tmp' => [ 400, 1 ],
        'aabbccddeeff-unified.log'    => [ 400, 0 ],
        '112233445566-soloist.log'    => [ 10,  1 ],
        '112233445566-unified.log'    => [ 10,  1 ],
        '0200005a1101-soloist.log'    => [ 400, 1 ],
        'notamac-soloist.log'         => [ 400, 1 ],
    );
    $touch->($_, $expect{$_}[0]) for keys %expect;

    local $Slim::Player::Client::BY_ID{'02:00:00:5a:11:01'} = Test::SyncClient->new(id => '02:00:00:5a:11:01');
    Plugins::SpotOn::Unified::DaemonManager::_cleanupOrphanedLogs();

    for my $name (sort keys %expect) {
        my $kept = $expect{$name}[1];
        my $why  = $name =~ /^aabb/ ? "stale orphan, no client"
                 : $name =~ /^1122/ ? "fresh orphan (under the 300 s guard)"
                 : $name =~ /^0200/ ? "connected player"
                 :                    "non-MAC name";
        is(-e "$dir/$name" ? 1 : 0, $kept, "74b-03 T-74b-25: $name " . ($kept ? 'stays' : 'is removed') . " ($why)");
    }
}

done_testing();
