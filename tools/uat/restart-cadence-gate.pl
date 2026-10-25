#!/usr/bin/perl
# tools/uat/restart-cadence-gate.pl -- Phase 83.3 plan 16 (G-83.3-5): proves
# the GH #147 backoff cap (300s between restarts) is reached and HELD, with
# no watchdog-driven ~40-60s restart series, from a real (or synthetic)
# server.log window.
#
# Restart evidence = lines whose stamp lies in [t0, t0+window] and contain
# BOTH the literal SoloistDaemon before-ws.port warn text
# "exited before announcing ws.port" AND the literal substring "mac=<MAC>".
# This is the ws.port poll's own dead-before-announce warn, fired once per
# restart attempt regardless of which observer (5s _streamAlivePoll or the
# ws.port poll itself) classified the death -- a reliable 1:1 marker of
# "this daemon just died and needed a restart" independent of exit code.
#
# Phase 83.3 plan 17 (IN-02): the marker above covers DIE-BEFORE-WS.PORT
# restarts only. A daemon that announced ws.port and later crashed produces
# no such warn at all -- that mid-run-crash case yields N=0 ->
# n_out_of_bounds, a FAIL in the safe direction, but the reason string alone
# does not say why. The poll's own restart line ("crashed for <mac> -
# restarting via startHelper") is INFO-level; this project's plugin.spoton
# category logs at WARN on every host this tool has been run against
# (verified: zero INFO lines in server.log), so that line is NOT adopted as
# a second marker -- it would never appear in production log capture and
# would give a false sense of coverage.
#
# Stamp format: `[YY-MM-DD HH:MM:SS.mmmm]` (server.log's own two-digit-year
# format) -- parsed via Time::Local::timelocal, matching this project's
# other log tooling (see runners/gap-15-exit10-live.sh's stamp_to_epoch).
#
# Formula:
#   - 3 <= N <= --max-starts restart warns in the window (mac-scoped, see
#     above).
#   - Among the SPACINGS between consecutive restarts, every spacing whose
#     LATER endpoint lies >= --settle seconds after t0 must be
#     >= --min-steady seconds, and there must be at least
#     --min-steady-count such spacings (the settled backoff-cap plateau).
#   - "rollback impossible" lines <= 1 (at most one failed-rollback notice)
#     -- Phase 83.3 plan 17 (IN-02): counted ONLY for lines that ALSO carry
#     "mac=$mac" -- another player's own failed rollback (WR-01: every
#     player runs its own, independent rollback decision) must not fail
#     THIS player's cadence measurement.
#   - "rolled back to" lines == 0 (a successful rollback would mean the
#     binary changed under this test -- never expected in this scenario)
#     -- same mac scoping as above.
#
# --selftest and --write-fixture FILE both build the SAME two-MAC fixture
# via fixture_lines($t0) -- ten before-ws.port restarts for the UAT mac
# (offsets 2,7,17,37,77,157,317,617,917,1217, the exact GH #147 backoff
# series reaching and holding the 300s cap) plus one rollback-impossible
# line for the UAT mac (offset 20), one rollback-impossible line for a
# DIFFERENT mac (offset 25), and one rolled-back-to line for that different
# mac (offset 30) -- the two extra lines exist to prove the mac scoping
# itself: this tool must PASS on the fixture (ROLLBACK_IMPOSSIBLE_LINES=1
# for the UAT mac, ROLLED_BACK_LINES=0), while the PRE-CHANGE (unscoped)
# tool FAILS it (2 and 1, both over the unscoped `<= 1` / `== 0` limits) --
# demonstrated externally by the live runner's dryrun step, which runs the
# pre-83.3-17 tool against this exact fixture before trusting the new one.
# t0 is fixed at 1790505209 (83.3-16's own live T0) so a captured fixture
# file and its printed FIXTURE_T0 always match across repeated runs.
#
# The real t5-log.txt archive (30 restarts, 60/45/15s steady-state spacing)
# remains the required negative/MUST-FAIL input for the CADENCE formula
# itself (unchanged by this plan), run externally by the live runner's
# `dryrun` subcommand before this tool is ever trusted live.
use strict;
use warnings;
use Getopt::Long;
use Time::Local;

my $log_file;
my $t0;
my $mac;
my $window           = 1260;
my $settle           = 400;
my $min_steady       = 240;
my $min_steady_count = 2;
my $max_starts       = 12;
my $selftest;
my $writeFixture;

GetOptions(
    'log=s'             => \$log_file,
    't0=i'              => \$t0,
    'mac=s'             => \$mac,
    'window=i'          => \$window,
    'settle=i'          => \$settle,
    'min-steady=i'      => \$min_steady,
    'min-steady-count=i' => \$min_steady_count,
    'max-starts=i'      => \$max_starts,
    'selftest'          => \$selftest,
    'write-fixture=s'   => \$writeFixture,
) or die usage();

# Fixed T0 for the shared two-MAC fixture (83.3-16's own live restart-cadence
# T0) -- see the header comment above.
use constant FIXTURE_T0  => 1_790_505_209;
use constant FIXTURE_UAT => '02:00:00:5a:11:01';
use constant FIXTURE_PA  => '02:00:00:5a:11:03';

if ($writeFixture) {
    exit run_write_fixture($writeFixture);
}

if ($selftest) {
    exit run_selftest();
}

die usage() unless defined $log_file && defined $t0 && defined $mac;

my @lines = read_lines($log_file);
exit evaluate(\@lines, $t0, $mac, $window, $settle, $min_steady, $min_steady_count, $max_starts);

sub usage {
    return "usage: $0 --log FILE --t0 EPOCH --mac MAC "
        . "[--window 1260] [--settle 400] [--min-steady 240] "
        . "[--min-steady-count 2] [--max-starts 12] | --selftest "
        . "| --write-fixture FILE\n";
}

sub read_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open $file: $!\n";
    my @l = <$fh>;
    close($fh);
    return @l;
}

# stamp_to_epoch($line) -- parses the leading `[YY-MM-DD HH:MM:SS.mmmm]`
# stamp into an epoch via Time::Local (assumes 20YY, matches server.log's
# actual range). Returns undef on any parse failure -- never dies, a line
# with no leading stamp (a wrapped/continuation line) is simply skipped.
sub stamp_to_epoch {
    my ($line) = @_;
    return undef unless $line =~ /^\[(\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.\d+\]/;
    my ($yy, $mo, $d, $h, $mi, $s) = ($1, $2, $3, $4, $5, $6);
    my $epoch = eval { Time::Local::timelocal($s, $mi, $h, $d, $mo - 1, 2000 + $yy) };
    return $@ ? undef : $epoch;
}

sub evaluate {
    my ($lines, $t0, $mac, $window, $settle, $min_steady, $min_steady_count, $max_starts) = @_;

    my @offsets;
    my $rollback_impossible = 0;
    my $rolled_back         = 0;

    for my $line (@$lines) {
        my $epoch = stamp_to_epoch($line);
        next unless defined $epoch;
        next if $epoch < $t0 || $epoch > $t0 + $window;

        if (index($line, 'exited before announcing ws.port') >= 0
            && index($line, "mac=$mac") >= 0)
        {
            push @offsets, $epoch - $t0;
        }
        # Phase 83.3 plan 17 (IN-02): both rollback counters are scoped to
        # THIS player's mac -- another player's own independent rollback
        # decision (WR-01: decided per-player, from the shared generation
        # record) must not fail this player's cadence measurement.
        $rollback_impossible++
            if index($line, 'rollback impossible') >= 0 && index($line, "mac=$mac") >= 0;
        $rolled_back++
            if index($line, 'rolled back to') >= 0 && index($line, "mac=$mac") >= 0;
    }

    my $n = scalar @offsets;

    my @spacings;
    for my $i (1 .. $#offsets) {
        push @spacings, $offsets[$i] - $offsets[$i - 1];
    }

    my @steady;
    for my $i (0 .. $#spacings) {
        my $later_endpoint = $offsets[$i + 1];
        next unless $later_endpoint >= $settle;
        push @steady, $spacings[$i];
    }
    my $steady_all_ok   = (scalar(grep { $_ < $min_steady } @steady) == 0);
    my $steady_count_ok = (scalar(@steady) >= $min_steady_count);

    print "N=$n\n";
    print "OFFSETS=" . join(',', @offsets) . "\n";
    print "SPACINGS=" . join(',', @spacings) . "\n";
    print "STEADY_SPACINGS=" . join(',', @steady) . "\n";
    print "ROLLBACK_IMPOSSIBLE_LINES=$rollback_impossible\n";
    print "ROLLED_BACK_LINES=$rolled_back\n";

    my @reasons;
    push @reasons, "n_out_of_bounds($n,3..$max_starts)" unless $n >= 3 && $n <= $max_starts;
    push @reasons, "steady_spacing_below_min" unless $steady_all_ok;
    push @reasons, "steady_spacing_count_below_min(" . scalar(@steady) . "<$min_steady_count)"
        unless $steady_count_ok;
    push @reasons, "rollback_impossible_lines_exceeded($rollback_impossible)" if $rollback_impossible > 1;
    push @reasons, "rolled_back_lines_present($rolled_back)" if $rolled_back > 0;

    if (@reasons) {
        print "RESULT: FAIL " . join(';', @reasons) . "\n";
        return 1;
    }
    else {
        print "RESULT: PASS\n";
        return 0;
    }
}

# fixture_lines($t0) -- Phase 83.3 plan 17 (IN-02): the ONE fixture builder
# shared by --selftest and --write-fixture. Ten before-ws.port restart warns
# for the UAT mac at offsets 2,7,17,37,77,157,317,617,917,1217 (spacings
# 5,10,20,40,80,160,300,300,300 -- the exact GH #147 backoff series reaching
# and holding the 300s cap), plus:
#   - offset 20: a rollback-impossible line for the UAT mac itself (this
#     player's own failed rollback -- the ONE line the new tool counts).
#   - offset 25: a rollback-impossible line for a DIFFERENT mac (pa) -- must
#     NOT count toward the UAT mac's ROLLBACK_IMPOSSIBLE_LINES under the new
#     (scoped) tool, but DOES count under the pre-83.3-17 (unscoped) tool --
#     this is the line that proves the scoping fix actually matters.
#   - offset 30: a rolled-back-to line for that SAME different mac -- same
#     proof, for the ROLLED_BACK_LINES counter.
sub fixture_lines {
    my ($t0) = @_;
    my @offsets = (2, 7, 17, 37, 77, 157, 317, 617, 917, 1217);

    my @lines;
    for my $off (@offsets) {
        push @lines,
            fmt_line($t0 + $off)
            . " Plugins::SpotOn::Unified::SoloistDaemon::__ANON__ (474) "
            . "SpotOn Soloist daemon exited before announcing ws.port (mac=" . FIXTURE_UAT . ")\n";
    }

    push @lines,
        fmt_line($t0 + 20)
        . " Plugins::SpotOn::Unified::DaemonManager::_rollbackAfterSwitch (0) "
        . "Soloist: rollback impossible (no_previous) after: startup failure: "
        . "exited_before_ws_port -- notice only (mac=" . FIXTURE_UAT . ")\n";

    push @lines,
        fmt_line($t0 + 25)
        . " Plugins::SpotOn::Unified::DaemonManager::_rollbackAfterSwitch (0) "
        . "Soloist: rollback impossible (no_previous) after: startup failure: "
        . "exited_before_ws_port -- notice only (mac=" . FIXTURE_PA . ")\n";

    push @lines,
        fmt_line($t0 + 30)
        . " Plugins::SpotOn::Unified::DaemonManager::_rollbackAfterSwitch (0) "
        . "Soloist: rolled back to 1.3.8.79 after: switch crash #3 (backoff crash #3) "
        . "within 1800s of the switch (mac=" . FIXTURE_PA . ")\n";

    return @lines;
}

# run_selftest() -- the formula's POSITIVE fixture, now the SHARED two-MAC
# fixture (fixture_lines) rather than a single-MAC 10-line-only fixture:
# checks both the cadence formula (still PASS) AND the mac-scoping fix
# itself in one gate (ROLLBACK_IMPOSSIBLE_LINES=1, ROLLED_BACK_LINES=0 for
# the UAT mac -- the pre-83.3-17 tool reports 2 and 1 on this SAME input,
# demonstrated externally by the live runner's dryrun step).
sub run_selftest {
    my $t0  = FIXTURE_T0;
    my $mac = FIXTURE_UAT;
    my @synthetic = fixture_lines($t0);
    return evaluate(\@synthetic, $t0, $mac, 1260, 400, 240, 2, 12);
}

# run_write_fixture($file) -- writes fixture_lines(FIXTURE_T0) verbatim to
# $file and prints FIXTURE_T0/FIXTURE_MAC so a caller (the live runner's
# dryrun step, or an ad-hoc pre-change-tool comparison) can drive both the
# new and the pre-change tool against the IDENTICAL fixture file.
sub run_write_fixture {
    my ($file) = @_;
    my $t0 = FIXTURE_T0;
    my @synthetic = fixture_lines($t0);

    open(my $fh, '>', $file) or die "Cannot write $file: $!\n";
    print $fh @synthetic;
    close($fh);

    print "FIXTURE_T0=$t0\n";
    print "FIXTURE_MAC=" . FIXTURE_UAT . "\n";
    return 0;
}

sub fmt_line {
    my ($epoch) = @_;
    my ($s, $mi, $h, $d, $mo, $y) = (localtime($epoch))[0 .. 5];
    return sprintf('[%02d-%02d-%02d %02d:%02d:%02d.0000]', $y - 100, $mo + 1, $d, $h, $mi, $s);
}
