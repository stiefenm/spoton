package Plugins::SpotOn::Unified::ProcStop;

# 79-61 (79-REVIEW-FULL-2 WR-01): stop a daemon process without blocking the
# LMS event loop.
#
# Proc::Background's die() with no arguments runs the kill sequence
# TERM 2 TERM 8 KILL 3 KILL 7 and, after each signal, a BLOCKING waitpid
# bounded only by an alarm: a daemon that does not react to SIGTERM held the
# whole server for 10 s before the first SIGKILL. (A zero delay in that
# sequence is not a way out: Proc::Background::Unix::_waitpid then calls a
# plain blocking waitpid(pid, 0).)
#
# terminate() sends the same signals with the same bound, but one at a time:
# die('TERM') / die('KILL') with a single signal and no delay returns at
# once, and Slim::Utils::Timers drives the next step. The timer list holds
# the process object until it is gone, so its DESTROY (autoterminate, the
# blocking default sequence) never runs while it is alive -- autoterminate
# is switched off for a process handed to terminate().
#
# A process that exits on the first TERM within the non-blocking check is
# reported gone at once (onGone runs synchronously) -- the normal case.
#
# A second terminate() for a process that is already exiting under the same
# key arms no second chain but keeps its onGone: every caller's callback runs
# once when the process is gone, first caller first (79-63 R1, 79-REVIEW-BETA3
# WR-01 -- stop() then stopForSync() inside the window lost the sync-group
# restart). A callback that dies is logged and does not drop the next one.
#
# terminatingFor($key) tells DaemonManager that the previous process of a
# player (key = MAC) is still exiting, so a new daemon for the same player is
# not spawned on top of it (same data dir, same Connect device id).
#
# $SYNC (local'ised by DaemonManager's permanent shutdown) keeps the old
# blocking die(): at LMS shutdown nothing plays any more and no daemon may be
# left behind.
#
# No Slim module is loaded at compile time (t/core/05 compiles every core
# module; the LMS-free form of Unified/HostEnv.pm).

use strict;
use warnings;

use Scalar::Util ();
use Time::HiRes ();

# [seconds after the previous step, signal to send then (undef = give up)]
my @STEPS = (
    [ 2, 'TERM' ],
    [ 8, 'KILL' ],
    [ 3, 'KILL' ],
    [ 7, undef  ],
);

our $SYNC = 0;

my %terminating;    # key => process object still exiting
my %moreOnGone;     # refaddr(process) => [ onGone of later terminate() calls ]

sub _log {
    my ($level, $msg) = @_;
    my $log = eval { require Slim::Utils::Log; Slim::Utils::Log::logger('plugin.spoton') };
    $log->$level($msg) if $log;
}

# terminate($class, $proc, key => $mac, label => 'Soloist daemon', onGone => $cb)
# Returns 1 when the process is gone on return, 0 while it is still exiting.
sub terminate {
    my ($class, $proc, %o) = @_;

    my $key    = $o{key};
    my $onGone = $o{onGone};
    my $label  = $o{label} // 'daemon';

    unless ($proc && $proc->alive) {
        $onGone->() if $onGone;
        return 1;
    }

    if ($SYNC) {
        $proc->die;
        $onGone->() if $onGone;
        return $proc->alive ? 0 : 1;
    }

    # already exiting under our control: no second chain, but this caller's
    # onGone runs with the first one's (_finish)
    if (defined $key && $terminating{$key} && $terminating{$key} == $proc) {
        push @{ $moreOnGone{ Scalar::Util::refaddr($proc) } }, $onGone if $onGone;
        return 0;
    }

    eval { $proc->autoterminate(0) if $proc->can('autoterminate'); 1 };

    $proc->die('TERM');
    unless ($proc->alive) {
        $onGone->() if $onGone;
        return 1;
    }

    $terminating{$key} = $proc if defined $key;
    _schedule($proc, 0, $key, $label, $onGone);
    return 0;
}

sub _schedule {
    my ($proc, $i, $key, $label, $onGone) = @_;
    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer($proc, Time::HiRes::time() + $STEPS[$i][0],
        \&_step, $i, $key, $label, $onGone);
}

sub _step {
    my ($proc, $i, $key, $label, $onGone) = @_;

    unless ($proc->alive) {
        _finish($proc, $key, $onGone);
        return;
    }

    my $sig = $STEPS[$i][1];
    unless (defined $sig) {
        _log('error', "SpotOn: $label (pid " . ($proc->pid // '?') . ") still alive after the TERM-then-KILL bound -- giving up");
        _finish($proc, $key, $onGone);
        return;
    }

    _log('warn', "SpotOn: $label (pid " . ($proc->pid // '?') . ") has not exited -- sending $sig");
    $proc->die($sig);
    unless ($proc->alive) {
        _finish($proc, $key, $onGone);
        return;
    }
    _schedule($proc, $i + 1, $key, $label, $onGone);
}

sub _finish {
    my ($proc, $key, $onGone) = @_;
    delete $terminating{$key}
        if defined $key && $terminating{$key} && $terminating{$key} == $proc;
    # kept by refaddr, not under the key: terminatingFor() may already have
    # dropped the key of a process that exited between two steps
    my $more = delete $moreOnGone{ Scalar::Util::refaddr($proc) } || [];
    for my $cb (grep { $_ } $onGone, @$more) {
        next if eval { $cb->(); 1 };
        my $err = $@ // '';
        $err =~ s/\s+\z//;
        _log('error', "SpotOn: onGone callback for pid " . ($proc->pid // '?') . " failed: $err");
    }
}

# terminatingFor($class, $key) -- 1 while the process registered under $key
# by terminate() is still alive.
sub terminatingFor {
    my ($class, $key) = @_;
    return 0 unless defined $key;
    my $proc = $terminating{$key} or return 0;
    return 1 if $proc->alive;
    delete $terminating{$key};
    return 0;
}

1;
