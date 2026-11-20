#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# ============================================================
# 88-04 Task 2 (GH #207, D-07/D-08): the Perl health check must not restart a
# helper that reports `recovering:true` on /health.
#
# The helper rebuilds a dropped AP session itself (librespot-spoton/src/unified.rs).
# While it does, /health reports session_valid=false and idle_secs climbs; the
# GH #149 rule in DaemonManager::_onHealthResponse (session_valid=false AND
# idle_secs > 30) would kill the helper in the middle of the recovery. The
# backstop stays unchanged for every other case.
#
# Lives under t/librespot: Unified/DaemonManager.pm is on the librespot side of
# the backend seam. SPOTON_MODULE_ROOT points the test at a mutated copy of the
# module for the mutation proof recorded in the 88-04 SUMMARY. Never skipped:
# a missing module dies.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $module_root = $ENV{SPOTON_MODULE_ROOT} || $project_dir;

my $module = "$module_root/Plugins/SpotOn/Unified/DaemonManager.pm";
die "t/78: $module is missing (die, never skip)\n" unless -f $module;

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

# --- LMS / CPAN stubs: nothing of the LMS tree is needed (CI has none) -------
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use JSON::PP ();
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::from_json"} = sub { JSON::PP->new->utf8->decode($_[0]) };
    *{"${caller}::to_json"}   = sub { JSON::PP->new->utf8->encode($_[0]) };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @WARN;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { shift; push @WARN, join('', @_); }
sub error { }
sub debug { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless {}, 'Slim::Utils::Prefs' }
sub get { undef }
sub set { }
sub client { return bless {}, 'Slim::Utils::Prefs' }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new { return bless {}, shift }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { return $_[-1] };
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
1;
END

# The real Plugin.pm drags in the whole LMS plugin tree; DaemonManager only
# needs the package to exist at load time.
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
sub SPOTON_CACHE_VERSION { 1 }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG   = sub () { 0 };
    *main::DEBUGLOG  = sub () { 0 };
    *main::ISWINDOWS = sub () { 0 };
    *main::ISMAC     = sub () { 0 };
    *main::SCANNER   = sub () { 0 };
}

# The stub dir wins over $module_root for the stubbed packages only (it holds no
# Plugins::SpotOn::Unified::DaemonManager); the module itself comes from
# $module_root.
unshift @INC, $stub_dir, $module_root;
require Plugins::SpotOn::Unified::DaemonManager;

my $dm = 'Plugins::SpotOn::Unified::DaemonManager';

# --- doubles -----------------------------------------------------------------
{
    package FakeHelper;
    sub new { my ($c, %a) = @_; return bless { alive => 1, mac => '02:00:00:88:04:01', %a }, $c }
    sub alive { return $_[0]{alive} }
    sub mac   { return $_[0]{mac} }
    sub pid   { return $_[0]{pid} }
    sub _lastHealthSession { my $s = shift; $s->{health} = shift if @_; return $s->{health} }
}
{
    package FakeHttp;
    sub new { my ($c, $body) = @_; return bless { body => $body }, $c }
    sub content { return $_[0]{body} }
    sub error   { return $_[0]{error} }
}

my @restarts;
{
    no warnings 'redefine';
    no strict 'refs';
    *{"${dm}::_restartForHealth"} = sub { shift; push @restarts, [ @_[1 .. $#_] ]; };
}

sub run_health {
    my ($json) = @_;
    @restarts = ();
    my $helper = FakeHelper->new;
    $dm->_onHealthResponse($helper, FakeHttp->new($json));
    return scalar @restarts;
}

# Cell 1: the helper is rebuilding the session itself - do NOT restart it.
is(
    run_health('{"status":"ok","session_valid":false,"session_age_secs":100,"idle_secs":60,"recovering":true}'),
    0,
    'cell 1: session_valid=false, idle_secs=60, recovering=true -> no health restart'
);

# Cell 2: the same health reading without `recovering` is the GH #149 backstop.
is(
    run_health('{"status":"ok","session_valid":false,"session_age_secs":100,"idle_secs":60}'),
    1,
    'cell 2: same reading without recovering -> one health restart'
);
is_deeply(
    $restarts[0],
    ['session_valid=false'],
    'cell 2: the restart carries the unchanged reason'
);

# Cell 3 (harness sanity): an explicit recovering:false behaves like the absent flag.
is(
    run_health('{"status":"ok","session_valid":false,"session_age_secs":100,"idle_secs":60,"recovering":false}'),
    1,
    'cell 3: recovering=false -> one health restart'
);

# Cell 4 (harness sanity): a healthy session never restarts, recovering or not.
is(
    run_health('{"status":"ok","session_valid":true,"session_age_secs":100,"idle_secs":60,"recovering":false}'),
    0,
    'cell 4: a valid session is not restarted'
);

# ------------------------------------------------------------
# 88 review WR-03: `recovering:true` must not switch the health restart off without a
# bound. The helper's own recovery is bounded (unified.rs), but a helper that reports
# `recovering:true` for longer than RECOVERING_MAX_S is stuck (the rebuild is awaited
# inline in its main loop) and the GH #149 rule applies again. The clock starts with the
# first health response that reports the recovery, per helper process.
# ------------------------------------------------------------
my $REC = '{"status":"ok","session_valid":false,"session_age_secs":100,"idle_secs":60,"recovering":true}';
my $OK  = '{"status":"ok","session_valid":true,"session_age_secs":100,"idle_secs":60,"recovering":false}';

sub health_on {
    my ($helper, $json) = @_;
    @restarts = ();
    $dm->_onHealthResponse($helper, FakeHttp->new($json));
    return scalar @restarts;
}
# move the helper's "recovering since" stamp $s seconds into the past
sub age_recovery {
    my ($helper, $s) = @_;
    my $h = $helper->_lastHealthSession;
    $h->{recovering_since} -= $s if ref $h eq 'HASH' && defined $h->{recovering_since};
    return;
}

my $max = $dm->can('RECOVERING_MAX_S') ? $dm->RECOVERING_MAX_S : undef;
ok(defined $max && $max >= 30 && $max <= 120, 'cell 5: RECOVERING_MAX_S exists and is a bound in the range of one recovery (30..120 s)');
$max //= 60;

{
    # Cell 5: the first report starts the clock and does not restart
    my $h = FakeHelper->new(pid => 4711);
    is(health_on($h, $REC), 0, 'cell 5: first recovering:true -> no health restart');
    my $since = (ref $h->_lastHealthSession eq 'HASH') ? $h->_lastHealthSession->{recovering_since} : undef;
    ok(defined $since && abs(time() - $since) <= 2, 'cell 5: ... and the start of the recovery is stamped on the helper');

    # Cell 6: still recovering inside the bound -> no restart
    age_recovery($h, $max - 5);
    is(health_on($h, $REC), 0, 'cell 6: recovering for less than RECOVERING_MAX_S -> still no health restart');

    # Cell 7: still recovering past the bound -> the GH #149 backstop applies again
    age_recovery($h, 10);
    is(health_on($h, $REC), 1, 'cell 7: recovering for longer than RECOVERING_MAX_S -> one health restart');
    like($restarts[0][0] // '', qr/^session_valid=false \(recovering for \d+s\)$/,
        'cell 7: the restart reason names the overlong recovery');
}

{
    # Cell 8: a finished recovery clears the stamp; a LATER recovery starts a new clock
    my $h = FakeHelper->new(pid => 4711);
    health_on($h, $REC);
    age_recovery($h, $max + 100);
    is(health_on($h, $OK), 0, 'cell 8: the recovery ended (recovering:false, valid session) -> no restart');
    ok(!defined $h->_lastHealthSession->{recovering_since}, 'cell 8: ... and the stamp is cleared');
    is(health_on($h, $REC), 0, 'cell 8: a later recovery is not judged by the old stamp');
}

{
    # Cell 9: a replaced helper process does not inherit the stamp of the old one
    my $h = FakeHelper->new(pid => 4711);
    health_on($h, $REC);
    age_recovery($h, $max + 100);
    $h->{pid} = 4712;
    is(health_on($h, $REC), 0, 'cell 9: recovering:true of a NEW process (other pid) starts its own clock');
}

{
    # Cell 10: a failed health poll in between does not reset the clock
    my $h = FakeHelper->new(pid => 4711);
    health_on($h, $REC);
    age_recovery($h, $max + 5);
    $dm->_onHealthError($h, FakeHttp->new(undef));
    is(health_on($h, $REC), 1, 'cell 10: the stamp survives a failed health poll -> restart past the bound');
}

{
    # Cell 11: the bound only lifts the recovering exemption - the idle guard of GH #149 stays
    my $h = FakeHelper->new(pid => 4711);
    health_on($h, $REC);
    age_recovery($h, $max + 5);
    is(health_on($h, '{"status":"ok","session_valid":false,"session_age_secs":100,"idle_secs":5,"recovering":true}'),
        0, 'cell 11: past the bound but idle_secs <= 30 (audio still flows) -> no restart');
}

done_testing();
