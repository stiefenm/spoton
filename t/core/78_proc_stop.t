#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# ============================================================
# 79-61 (79-REVIEW-FULL-2 WR-01): Unified/ProcStop.pm -- the non-blocking
# TERM-then-KILL stop of a daemon process. Unit cells over a fake process
# object (no fork here; the real-child form is t/soloist/30's WR-01 block):
#   - a process that exits on the first TERM is gone at once (onGone sync)
#   - one that ignores TERM gets TERM again at +2 s, KILL at +10 s, KILL at
#     +13 s, and is given up at +20 s -- the bound of Proc::Background's
#     default sequence, one timer step at a time
#   - every signal is a single-signal die($sig) (non-blocking), never die()
#   - autoterminate is switched off, terminatingFor($key) reports the player
#   - $SYNC keeps the old blocking die() (permanent LMS shutdown)
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
my $module = "$project_dir/Plugins/SpotOn/Unified/ProcStop.pm";
die "ProcStop.pm not found at $module (die, never skip)\n" unless -f $module;

my $stub_dir = tempdir(CLEANUP => 1);
sub write_stub {
    my ($pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $stub_dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "stub $pkg: $!";
    print $fh $code;
    close $fh;
}
write_stub('Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @TIMERS;
sub setTimer { my ($obj, $when, $cb, @args) = @_; push @TIMERS, [$obj, $when, $cb, @args]; }
sub killTimers { }
sub fire_next { my $t = shift @TIMERS or return 0; my ($obj, $when, $cb, @a) = @$t; $cb->($obj, @a); return $when; }
1;
END
write_stub('Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @LINES;
sub logger { return bless {}, 'Slim::Utils::Log' }
sub warn  { push @LINES, ['warn', $_[1]] }
sub error { push @LINES, ['error', $_[1]] }
sub info  { }
1;
END
unshift @INC, $stub_dir;
require $module;
my $PS = 'Plugins::SpotOn::Unified::ProcStop';

{
    package FakeProc;
    # exitOn: the signal that ends it ('TERM' | 'KILL' | 'never')
    sub new { my ($c, %a) = @_; return bless { alive => 1, signals => [], dies => 0, autoterminate => 1, %a }, $c }
    sub alive { $_[0]{alive} }
    sub pid   { 4242 }
    sub autoterminate { my $s = shift; $s->{autoterminate} = $_[0] ? 1 : 0 if @_; $s->{autoterminate} }
    sub die {
        my ($s, @seq) = @_;
        if (!@seq) { $s->{blocking_die}++; $s->{alive} = 0; return 1; }
        push @{ $s->{signals} }, @seq;
        $s->{alive} = 0 if ($s->{exitOn} // '') eq $seq[0];
        $s->{alive} = 0 if $seq[0] eq 'KILL' && ($s->{exitOn} // '') ne 'never';
        return !$s->{alive};
    }
}

# (1) exits on the first TERM
{
    @Slim::Utils::Timers::TIMERS = ();
    my $p = FakeProc->new(exitOn => 'TERM');
    my $gone = 0;
    my $r = $PS->terminate($p, key => 'aa:01', onGone => sub { $gone++ });
    is($r, 1, 'a process that exits on TERM is reported gone at once');
    is($gone, 1, 'onGone runs synchronously in the normal case');
    is_deeply($p->{signals}, ['TERM'], 'exactly one TERM, sent as a single-signal die (non-blocking)');
    is($p->{blocking_die} // 0, 0, 'the blocking default die() is never called');
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, 'no escalation timer');
    ok(!$PS->terminatingFor('aa:01'), 'not registered as terminating');
}

# (2) ignores TERM, dies on KILL
{
    @Slim::Utils::Timers::TIMERS = ();
    my $p = FakeProc->new(exitOn => 'KILL');
    my $gone = 0;
    my $r = $PS->terminate($p, key => 'aa:02', onGone => sub { $gone++ });
    is($r, 0, 'a TERM-ignoring process is reported still exiting');
    is($gone, 0, 'onGone waits');
    is($p->autoterminate, 0, 'autoterminate is switched off (DESTROY never runs the blocking sequence)');
    ok($PS->terminatingFor('aa:02'), 'the player is registered as terminating');
    is($PS->terminate($p, key => 'aa:02'), 0, 'a second terminate of the same process is a no-op');
    is(scalar(@Slim::Utils::Timers::TIMERS), 1, '... and arms no second chain');

    require Time::HiRes;
    cmp_ok(abs(($Slim::Utils::Timers::TIMERS[0][1] - Time::HiRes::time()) - 2), '<', 0.5, 'the second TERM is armed 2 s after the first');
    Slim::Utils::Timers::fire_next();    # +2 s: TERM again
    is_deeply($p->{signals}, ['TERM', 'TERM'], 'second step: TERM again');
    cmp_ok(abs(($Slim::Utils::Timers::TIMERS[0][1] - Time::HiRes::time()) - 8), '<', 0.5, 'the KILL step is armed 8 s after the second TERM (+10 s in total)');
    Slim::Utils::Timers::fire_next();    # +10 s: KILL
    is_deeply($p->{signals}, ['TERM', 'TERM', 'KILL'], 'third step: KILL');
    ok(!$p->alive, 'KILL ends it');
    is($gone, 1, 'onGone runs once the process is gone');
    ok(!$PS->terminatingFor('aa:02'), 'the registration is cleared');
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, 'no timer left');
}

# (3) survives everything: given up after the bound, logged as error
{
    @Slim::Utils::Timers::TIMERS = ();
    @Slim::Utils::Log::LINES = ();
    my $p = FakeProc->new(exitOn => 'never');
    my $gone = 0;
    $PS->terminate($p, key => 'aa:03', onGone => sub { $gone++ });
    my $steps = 0;
    $steps++ while Slim::Utils::Timers::fire_next() && $steps < 10;
    is_deeply($p->{signals}, [qw(TERM TERM KILL KILL)], 'TERM, TERM, KILL, KILL -- the default sequence of Proc::Background');
    is($steps, 4, 'four timer steps (+2, +10, +13, +20 s)');
    ok((grep { $_->[0] eq 'error' && $_->[1] =~ /giving up/ } @Slim::Utils::Log::LINES), 'giving up is logged as an error');
    is($gone, 1, 'onGone runs at the end of the bound even if the process survived');
    ok(!$PS->terminatingFor('aa:03') || $p->alive, 'the registration of a given-up process is dropped');
}

# (4) $SYNC: the old blocking stop
{
    @Slim::Utils::Timers::TIMERS = ();
    my $p = FakeProc->new(exitOn => 'never');
    local $Plugins::SpotOn::Unified::ProcStop::SYNC = 1;
    my $gone = 0;
    $PS->terminate($p, key => 'aa:04', onGone => sub { $gone++ });
    is($p->{blocking_die} // 0, 1, '$SYNC: the blocking default die() runs (permanent LMS shutdown)');
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, '$SYNC: no timer');
    is($gone, 1, '$SYNC: onGone runs');
}

# (5) a dead process
{
    my $p = FakeProc->new(alive => 0);
    my $gone = 0;
    is($PS->terminate($p, key => 'aa:05', onGone => sub { $gone++ }), 1, 'a dead process is gone at once');
    is($gone, 1, '... and onGone runs');
    is($PS->terminate(undef, onGone => sub { $gone++ }), 1, 'no process at all is gone at once');
}

# (6) 79-63 R1 (79-REVIEW-BETA3 WR-01): a second terminate() for a process that
# is already exiting keeps its own onGone. stop() then stopForSync() for the
# same player inside the TERM-then-KILL window hands in two callbacks (the
# second one is the sync-group restart); both run exactly once when the
# process is gone, first caller first, and no second chain is armed.
{
    @Slim::Utils::Timers::TIMERS = ();
    my $p = FakeProc->new(exitOn => 'KILL');
    my @order;
    is($PS->terminate($p, key => 'aa:06', onGone => sub { push @order, 'first' }), 0, 'WR-01: first terminate -> still exiting');
    is($PS->terminate($p, key => 'aa:06', onGone => sub { push @order, 'second' }), 0, 'WR-01: second terminate of the same process -> still exiting');
    is(scalar(@Slim::Utils::Timers::TIMERS), 1, 'WR-01: the second call arms no second chain');
    is_deeply(\@order, [], 'WR-01: no callback before the process is gone');
    Slim::Utils::Timers::fire_next();    # +2 s: TERM again, still alive
    is_deeply(\@order, [], 'WR-01: still no callback while it is alive');
    Slim::Utils::Timers::fire_next();    # +10 s: KILL ends it
    ok(!$p->alive, 'WR-01: KILL ends it');
    is_deeply(\@order, ['first', 'second'], 'WR-01: both callbacks ran exactly once, first caller first');
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, 'WR-01: no timer left');
    ok(!$PS->terminatingFor('aa:06'), 'WR-01: the registration is cleared');

    # the same chain again after terminatingFor() has already dropped the
    # dead process (DaemonManager polls it every 0.25 s): the second callback
    # must not hang on the dropped registration
    @Slim::Utils::Timers::TIMERS = ();
    my $q = FakeProc->new(exitOn => 'never');
    my @order2;
    $PS->terminate($q, key => 'aa:07', onGone => sub { push @order2, 'first' });
    $PS->terminate($q, key => 'aa:07', onGone => sub { push @order2, 'second' });
    $q->{alive} = 0;                      # exits between two steps
    ok(!$PS->terminatingFor('aa:07'), 'WR-01: terminatingFor drops the dead process first');
    Slim::Utils::Timers::fire_next();
    is_deeply(\@order2, ['first', 'second'], 'WR-01: both callbacks still run after terminatingFor dropped the registration');

    # a callback that dies does not take the next caller's callback with it
    @Slim::Utils::Timers::TIMERS = ();
    my $r = FakeProc->new(exitOn => 'KILL');
    my @order3;
    $PS->terminate($r, key => 'aa:08', onGone => sub { push @order3, 'first'; die "boom\n" });
    $PS->terminate($r, key => 'aa:08', onGone => sub { push @order3, 'second' });
    eval { Slim::Utils::Timers::fire_next(); Slim::Utils::Timers::fire_next(); 1 };
    is_deeply(\@order3, ['first', 'second'], 'WR-01: a dying first callback does not drop the second');
}

done_testing();
