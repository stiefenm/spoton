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
# GH #220: "Clear logs" unlinked the live <mac>-unified.log of a running
# librespot daemon; the daemon kept writing into the deleted inode, so no
# librespot log existed on disk until the next start and stderrTail read ''.
#
# Fix under test: the daemon ALWAYS opens its stderr log in append mode
# (_openStderrLog; non-diagnostic mode truncates explicitly at open), so a
# later truncation by Clear logs leaves no NUL-filled hole (the child's fd
# writes at EOF); stderrTail clamps a start offset beyond the file size.
#
# Lives under t/librespot: Unified/Daemon.pm is on the librespot side of
# the backend seam (tools/ci/amputation/librespot.files).
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Unified/Daemon.pm";
die "Plugins/SpotOn/Unified/Daemon.pm not present in this checkout (die, never skip)\n" unless -f $module;

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);
my $spoton    = "$cache_dir/spoton";
make_path($spoton);

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

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @WARN;
sub import {
    my $class = shift;
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

write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_ns_store = ( server => { cachedir => '$cache_dir' } );
sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}
sub preferences { my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0]; return bless { _ns => \$ns }, 'Slim::Utils::Prefs'; }
sub get { my (\$self, \$key) = \@_; return \$_ns_store{ \$self->{_ns} }{\$key}; }
sub set { my (\$self, \$key, \$val) = \@_; \$_ns_store{ \$self->{_ns} }{\$key} = \$val; }
sub client { return bless { _ns => 'client' }, 'Slim::Utils::Prefs'; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @SET;
sub killTimers { }
sub setTimer   { shift; push @SET, [@_]; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
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
        *{"${class}::${name}"} = sub {
            my $self = shift;
            $self->[$n] = shift if @_;
            return $self->[$n];
        };
    }
}
1;
END

{
    package FakeProc;
    sub new   { my ($c, %a) = @_; return bless { alive => 1, died => 0, %a }, $c }
    sub alive { return $_[0]{alive} }
    sub die   { $_[0]{died}++; $_[0]{alive} = 0; }
}

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG   = sub () { 0 };
    *main::ISWINDOWS = sub () { 0 };
    *main::ISMAC     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;    # 79-61 WR-01: the timeout path loads Unified/ProcStop.pm
require $module;

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "read $path: $!";
    binmode $fh;
    local $/;
    my $d = <$fh>;
    close $fh;
    return defined $d ? $d : '';
}

# The clearLogs primitive: open '+<' by path, truncate to 0.
sub truncate_by_path {
    my ($path) = @_;
    open(my $fh, '+<', $path) or die "open +< $path: $!";
    truncate($fh, 0) or die "truncate $path: $!";
    close $fh;
}

# Real child process holding a dup of $fh as its stderr: writes 1000 bytes,
# waits for a go line, then writes "after\n". The parent truncates the file
# between the two writes. Returns the file content afterwards.
sub run_child_with_truncate {
    my ($fh, $file) = @_;
    pipe(my $rd, my $wr) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $wr;
        open(STDERR, '>&', $fh) or POSIX::_exit(2);
        open(STDIN,  '<&', $rd) or POSIX::_exit(2);
        my $code = q{$SIG{ALRM} = sub { exit 3 }; alarm 10; syswrite(STDERR, 'x' x 1000); my $l = <STDIN>; syswrite(STDERR, "after\n");};
        { exec($^X, '-e', $code); }
        POSIX::_exit(4);
    }
    close $rd;
    for (1 .. 100) {
        last if (-s $file || 0) >= 1000;
        select(undef, undef, undef, 0.05);
    }
    my $size_before = -s $file || 0;
    truncate_by_path($file);
    syswrite($wr, "go\n");
    close $wr;
    waitpid($pid, 0);
    return ($size_before, slurp($file));
}

require POSIX;

# --- L1: control - a plain-write fd leaves a NUL hole after truncation -----
{
    my $file = "$spoton/l1.log";
    open(my $fh, '>', $file) or die $!;
    my ($before, $content) = run_child_with_truncate($fh, $file);
    close $fh;
    is($before, 1000, 'L1 control: child wrote 1000 bytes before the truncation');
    ok(($content =~ tr/\0//) > 0, 'L1 control: plain-write fd + truncate leaves NUL bytes (harness can see a hole)');
}

# --- L2: helper exists ------------------------------------------------------
ok(Plugins::SpotOn::Unified::Daemon->can('_openStderrLog'), 'L2: Daemon has _openStderrLog');

{
    # A missing helper yields failing cells, not a skip and not a die.
    no warnings 'redefine';
    my $open_helper = Plugins::SpotOn::Unified::Daemon->can('_openStderrLog') || sub { undef };

    # --- L3a: non-diagnostic open empties a pre-filled log ------------------
    {
        my $file = "$spoton/l3a.log";
        write_file($file, 'y' x 40);
        my $fh = $open_helper->($file, 0);
        ok($fh, 'L3a: _openStderrLog returns a handle (non-diagnostic)');
        is(-s $file, 0, 'L3a: non-diagnostic open truncates the log to 0');
        close $fh if $fh;
    }

    # --- L3b: diagnostic open keeps earlier runs ----------------------------
    {
        my $file = "$spoton/l3b.log";
        write_file($file, 'y' x 40);
        my $fh = $open_helper->($file, 1);
        ok($fh, 'L3b: _openStderrLog returns a handle (diagnostic)');
        is(-s $file, 40, 'L3b: diagnostic open keeps the 40 earlier bytes');
        close $fh if $fh;
    }

    # --- L4: helper fd leaves no hole after truncation, both modes ----------
    for my $diag (0, 1) {
        my $file = "$spoton/l4-$diag.log";
        my $fh = $open_helper->($file, $diag);
        if (!$fh) { fail("L4 diag=$diag: no handle from _openStderrLog"); next; }
        my ($before, $content) = run_child_with_truncate($fh, $file);
        close $fh;
        is($before, 1000, "L4 diag=$diag: child wrote 1000 bytes before the truncation");
        is($content, "after\n", "L4 diag=$diag: file holds exactly the line written after the truncation");
        is(($content =~ tr/\0//), 0, "L4 diag=$diag: no NUL bytes in the log");
    }
}

# --- L5: start() goes through the helper, no inline mode ternary -----------
{
    my $src = slurp($module);
    my ($body) = $src =~ /(\nsub start \{.*?)(?=\n(?:# [^\n]*\n)*sub \w)/s;
    ok(defined $body && $body =~ /_openStderrLog\(/,
        'L5: start() obtains the stderr handle from _openStderrLog(');
    ok(defined $body && $body !~ /\?\s*'>>'\s*:\s*'>'/,
        'L5: start() has no ternary choosing between append and plain write');
}

# --- T1/T2: stderrTail after a truncation under the running daemon ---------
sub tail_daemon {
    my ($file) = @_;
    my $d = Plugins::SpotOn::Unified::Daemon->Slim::Utils::Accessor::new();
    $d->mac('aa:bb:cc:dd:ee:01');
    $d->name('Test Player');
    $d->_stderrFile($file);
    $d->_stderrStartOffset(-s $file);
    return $d;
}

sub append_file {
    my ($path, $content) = @_;
    open(my $fh, '>>', $path) or die "append $path: $!";
    print $fh $content;
    close $fh;
}

# T1: truncated below the recorded start offset (Clear logs, GH #220)
{
    my $file = "$spoton/t1.log";
    write_file($file, "old line\n" x 200);
    my $d = tail_daemon($file);
    truncate_by_path($file);
    append_file($file, "Bad credentials\n");
    is($d->stderrTail(8192), "Bad credentials\n",
        'T1: stderrTail returns the new content after a truncation below the start offset');
}

# T2: guard (WR-03) - earlier runs below the offset stay hidden
{
    my $file = "$spoton/t2.log";
    write_file($file, "old run\n" x 100);
    my $d = tail_daemon($file);
    append_file($file, "new run\n");
    is($d->stderrTail(8192), "new run\n",
        'T2: stderrTail still hides bytes from earlier runs below the start offset');
}

done_testing();
