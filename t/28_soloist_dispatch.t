#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Unified/DaemonManager.pm not yet present in this checkout';
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

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { return undef }
sub set      { }
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
sub killTimers { }
sub setTimer   { }
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

# Minimal stand-in -- DaemonManager.pm only needs the CACHE_VERSION constant
# and _pluginDataFor at load time; both real callers (startHelper's later
# body, Plugin.pm itself) are out of scope for this dispatch-only test.
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
sub new { return bless {}, shift }
1;
END

# Controllable Soloist stub -- $FAKE_BINARY/$FAKE_HAS_KEY are toggled per
# test case below to drive _backendPrereqState()'s three soloist-branch
# outcomes without touching the real Soloist.pm (already covered by t/26/27).
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
our $FAKE_BINARY  = undef;   # undef = missing; any true value = present
our $FAKE_HAS_KEY = 0;
sub get    { return $FAKE_BINARY }
sub hasKey { return $FAKE_HAS_KEY }
1;
END

# ============================================================
# main:: constants -- fixed ones via `use constant` (bareword-callable
# under strict subs), OS flags as real subs reading a togglable package
# variable so individual test cases can flip ISWINDOWS/ISMAC at runtime.
# ============================================================
our $FAKE_ISWINDOWS = 0;
our $FAKE_ISMAC     = 0;

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { $main::FAKE_ISWINDOWS };
    *main::ISMAC       = sub () { $main::FAKE_ISMAC };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");

# Pre-load the Soloist stub so _backendPrereqState()'s own lazy
# `require Plugins::SpotOn::Soloist` (which runs on its first soloist-branch
# call below) is a %INC no-op -- otherwise that require would re-execute the
# stub's `our $FAKE_BINARY = undef;` init line and clobber whatever value a
# test case just set immediately beforehand.
require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist stub");

sub reset_all {
    $Plugins::SpotOn::Soloist::FAKE_BINARY  = undef;
    $Plugins::SpotOn::Soloist::FAKE_HAS_KEY = 0;
    $FAKE_ISWINDOWS = 0;
    $FAKE_ISMAC     = 0;
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
}

{
    reset_all();
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState(undef),
        'librespot',
        "undef backend -> 'librespot' (fail-safe fallback)"
    );
}

# ============================================================
# (b) backend 'soloist', binary+key present, Linux -> 'soloist_ready'
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::Soloist::FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $Plugins::SpotOn::Soloist::FAKE_HAS_KEY = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_ready',
        "backend 'soloist', binary+key present, Linux -> 'soloist_ready'"
    );
}

# ============================================================
# (c) soloist, no binary -> 'soloist_missing_binary'
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::Soloist::FAKE_BINARY  = undef;
    $Plugins::SpotOn::Soloist::FAKE_HAS_KEY = 1;   # key present is irrelevant -- binary checked first

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_missing_binary',
        "soloist, no binary -> 'soloist_missing_binary'"
    );
}

# ============================================================
# (d) soloist, binary present but no key -> 'soloist_missing_key'
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::Soloist::FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $Plugins::SpotOn::Soloist::FAKE_HAS_KEY = 0;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_missing_key',
        "soloist, binary present, no key -> 'soloist_missing_key'"
    );
}

# ============================================================
# (e) soloist on ISWINDOWS/ISMAC -> 'soloist_unsupported_os'
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::Soloist::FAKE_BINARY  = '/fake/soloist';
    $Plugins::SpotOn::Soloist::FAKE_HAS_KEY = 1;
    $FAKE_ISWINDOWS = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_unsupported_os',
        "soloist on ISWINDOWS (even with binary+key present) -> 'soloist_unsupported_os'"
    );
}

{
    reset_all();
    $Plugins::SpotOn::Soloist::FAKE_BINARY  = '/fake/soloist';
    $Plugins::SpotOn::Soloist::FAKE_HAS_KEY = 1;
    $FAKE_ISMAC = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_unsupported_os',
        "soloist on ISMAC (even with binary+key present) -> 'soloist_unsupported_os'"
    );
}

done_testing();
