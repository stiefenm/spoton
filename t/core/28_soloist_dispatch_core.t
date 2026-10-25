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


# 84-09: core half of t/28_soloist_dispatch.t -- the _backendPrereqState /
# backendName dispatch of the REAL DaemonManager over mocked roles: which role
# is consulted (or none: unknown name, platform force), the `_missing_module`
# state and the available() fallback. The real-role answers are in
# t/librespot/28_soloist_dispatch_librespot.t and t/soloist/28_soloist_dispatch_soloist.t.
my $role_dir = tempdir(CLEANUP => 1);
# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($role_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
sub prereqState { return 'librespot' }
1;
END

write_stub($role_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
sub prereqState { return 'soloist' }
1;
END

unshift @INC, $stub_dir, $role_dir, $project_dir;

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
# each role's prereqState is wrapped by a recorder (the mock's method answers).
# 84-09 (core half): the two roles are the per-file MOCKS from $role_dir;
# the recorder below wraps their prereqState exactly as it wraps the real ones
# in t/librespot/ and t/soloist/28_soloist_dispatch_*.t -- these cells test
# DaemonManager's dispatch (which role is consulted, or none), not the roles.
require Plugins::SpotOn::Backend;
Plugins::SpotOn::Backend::classFor($_) for qw(soloist librespot);
our @ROLE_PREREQ_CALLS;
for my $pair ([ soloist => 'Plugins::SpotOn::Backend::Soloist' ], [ librespot => 'Plugins::SpotOn::Backend::Librespot' ]) {
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
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('bogus-value'),
        'librespot',
        "unknown backend value -> 'librespot' (fail-safe fallback, T-71-05)"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, [], 'unknown backend value: no role consulted (T-71-05 fail-safe stays in core, 84-12)');
}

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
# (e) soloist on ISWINDOWS/ISMAC -> 'soloist_unsupported_os'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = '/fake/soloist';
    $FAKE_HAS_KEY = 1;
    $FAKE_ISWINDOWS = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_unsupported_os',
        "soloist on ISWINDOWS (even with binary+key present) -> 'soloist_unsupported_os'"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, [], 'soloist on ISWINDOWS: platform check stays in core, role not consulted (84-12)');
}

{
    reset_all();
    $FAKE_BINARY  = '/fake/soloist';
    $FAKE_HAS_KEY = 1;
    $FAKE_ISMAC = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_unsupported_os',
        "soloist on ISMAC (even with binary+key present) -> 'soloist_unsupported_os'"
    );
    is_deeply(\@ROLE_PREREQ_CALLS, [], 'soloist on ISMAC: platform check stays in core, role not consulted (84-12)');
}

reset_all();

# ============================================================
# 84-12 Task 1 (W5, revision 11): a REGISTERED backend whose role module
# does not load. _backendPrereqState reports '<name>_missing_module' (the
# one new state), and backendName() with pref=soloist falls back to the
# first available() backend, logged once. Runs against a module-root copy
# without Backend/Soloist.pm (the real DaemonManager is loaded here, which
# is why these cells live in t/28 and not in t/57, whose DaemonManager is a
# stub). 84-09: core half -- the surviving role is the librespot mock.
# ============================================================
{
    reset_all();
    my $copy_root = tempdir(CLEANUP => 1);
    make_path("$copy_root/Plugins/SpotOn/Backend");
    # 84-09 (core half): the real registry, the librespot MOCK role (no real
    # backend module is read), and no Soloist role at all.
    for my $pair (['Plugins/SpotOn/Backend.pm', $project_dir], ['Plugins/SpotOn/Backend/Librespot.pm', $role_dir]) {
        my ($rel, $from) = @$pair;
        open(my $in,  '<', "$from/$rel") or die "read $rel: $!";
        open(my $out, '>', "$copy_root/$rel")   or die "write $rel: $!";
        print $out do { local $/; <$in> };
        close $out;
    }

    local @INC = ($stub_dir, $copy_root, grep { $_ ne $project_dir && $_ ne $stub_dir && $_ ne $role_dir } @INC);
    my $saved = delete $INC{'Plugins/SpotOn/Backend/Soloist.pm'};
    local %Plugins::SpotOn::Backend::UNAVAILABLE = ();
    my @warns;
    no warnings 'redefine';
    local *Slim::Utils::Log::warn = sub { shift; push @warns, join('', @_); };

    $FAKE_BINARY  = '/fake/soloist';
    $FAKE_HAS_KEY = 1;
    is(Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'), 'soloist_missing_module',
       "absent Soloist role: _backendPrereqState('soloist') -> 'soloist_missing_module'");
    is(Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('bogus-value'), 'librespot',
       "absent Soloist role: an unregistered name still -> 'librespot' (T-71-05 fail-safe unchanged)");
    is(Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('librespot'), 'librespot',
       "absent Soloist role: librespot still -> 'librespot'");

    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    @warns = ();
    my $n1 = Plugins::SpotOn::Unified::DaemonManager::backendName();
    my $n2 = Plugins::SpotOn::Unified::DaemonManager::backendName();
    is($n1, 'librespot', 'absent Soloist role, pref soloist: backendName() falls back to librespot');
    is($n2, 'librespot', 'absent Soloist role, pref soloist: a second backendName() call gives librespot too');
    is(scalar(grep { /fall(?:s|ing)? back/i } @warns), 1,
       'absent Soloist role: the backendName fallback is logged exactly once');
    is(eval { Plugins::SpotOn::Unified::DaemonManager::backendClass() }, 'Plugins::SpotOn::Backend::Librespot',
       'absent Soloist role: backendClass() hands out the Librespot role (no die)');

    $INC{'Plugins/SpotOn/Backend/Soloist.pm'} = $saved;
    reset_all();
}
# With both modules present, pref soloist -> soloist again (no sticky fallback).
{
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    is(Plugins::SpotOn::Unified::DaemonManager::backendName(), 'soloist',
       'both role modules present, pref soloist: backendName() eq soloist');
}

done_testing();
