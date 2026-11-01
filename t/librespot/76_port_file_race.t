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
# 79-61 (79-REVIEW-FULL-2 WR-07): _pollPortFile deletes the port files of
# other daemons still starting. On completion each librespot daemon's poll
# unlinked every spoton-port-* file in the cache dir, not only its own; a
# second daemon starting 3 s later lost its freshly written port file, timed
# out after 10 s and was killed as a crash.
#
# The poll must remove only its own port file. Leftovers of a daemon that
# crashed or whose unlink failed (Windows keeps the FD open) are still
# swept, but only when older than any announcement window can be (60 s).
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

sub daemon_with {
    my ($portFile) = @_;
    my $d = Plugins::SpotOn::Unified::Daemon->Slim::Utils::Accessor::new();
    $d->mac('aa:bb:cc:dd:ee:01');
    $d->name('Test Player');
    $d->_proc(FakeProc->new);
    $d->_portTmpfile($portFile);
    $d->_portPollAttempts(0);
    return $d;
}

# --- Test 1-4: daemon A completes while daemon B is still announcing -------
{
    my $ownA   = "$spoton/spoton-port-AAAA";
    my $freshB = "$spoton/spoton-port-BBBB";   # daemon B, started 3 s later
    my $oldC   = "$spoton/spoton-port-CCCC";   # leftover of a crashed daemon

    write_file($ownA, "stream_port=41001\n");
    write_file($freshB, "");                   # B's tempfile, not written yet
    write_file($oldC, "stream_port=41999\n");
    my $past = time() - 120;
    utime($past, $past, $oldC) or die "utime: $!";

    my $a = daemon_with($ownA);
    $a->_pollPortFile;

    is($a->_streamPort, 41001, 'Test 1: daemon A reads its own announced port');
    ok(!-e $ownA, 'Test 2: daemon A removes its own port file on completion');
    ok(-e $freshB, 'Test 3: daemon A does not remove the port file of daemon B that is still starting (WR-07)');
    ok(!-e $oldC, 'Test 4: a port file older than 60 s (crashed daemon) is still swept');

    # B announces after A's completion and must still find its file.
    write_file($freshB, "stream_port=41002\n") if -e $freshB;
    my $b = daemon_with($freshB);
    $b->_pollPortFile;
    is($b->_streamPort, 41002, 'Test 5: daemon B reads its port after A completed (no timeout, no kill)');
    is($b->_proc->{died}, 0, 'Test 6: daemon B is not killed as "did not announce"');
    ok(!-e $freshB, 'Test 7: daemon B removes its own port file');
}

# --- Test 8-9: a timeout still cleans only its own file ---------------------
{
    my $own   = "$spoton/spoton-port-DDDD";
    my $other = "$spoton/spoton-port-EEEE";
    write_file($own, "");
    write_file($other, "");
    my $d = daemon_with($own);
    $d->_portPollAttempts(Plugins::SpotOn::Unified::Daemon::PORT_POLL_MAX_ATTEMPTS());
    $d->_pollPortFile;
    ok(!-e $own, 'Test 8: on timeout the daemon removes its own empty port file');
    ok(-e $other, 'Test 9: on timeout another daemon\'s fresh port file stays');
}

done_testing();
