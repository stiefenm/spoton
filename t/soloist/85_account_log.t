#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Data::Dumper;
use Digest::MD5 qw(md5_hex);

# 90.1-02 (D-01, D-02, D-04): which account a Soloist daemon is signed in as, read
# from the daemon's OWN log (`logged in as <id>` / `logged out`). The module keeps
# only the 8-hex key (AccountMigration->accountIdFor) and the last 4 characters;
# the raw id never reaches an event or the reader state (T-90.1-03).
#
# CI-shaped: nothing here needs the LMS tree. AccountMigration is a per-file stub
# that records its calls (the real one needs the Slim cache and prefs stack);
# the stub's formula is the real one's body for an ASCII id.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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

write_stub($stub_dir, 'Plugins::SpotOn::API::AccountMigration', <<'END');
package Plugins::SpotOn::API::AccountMigration;
use Digest::MD5 qw(md5_hex);
our @CALLS;
sub accountIdFor {
    my ($class, $username) = @_;
    push @CALLS, $username;
    return undef unless defined $username && length $username;
    return substr(md5_hex($username), 0, 8);
}
1;
END

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Soloist::AccountLog')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist::AccountLog");
my $AL = 'Plugins::SpotOn::Soloist::AccountLog';

# Made-up ids, built from pieces so no id-shaped literal sits in this file.
my $FAKE28 = 'tst' . ('a1B2c3D4e5' x 2) . 'XYZ12';     # 28 characters
my $FAKE25 = 'tst' . ('a1B2c3D4e5' x 2) . '99';        # 25 characters
is(length $FAKE28, 28, 'fixture: the 28-character made-up id');
is(length $FAKE25, 25, 'fixture: the 25-character made-up id');

sub key_of { return substr(md5_hex($_[0]), 0, 8); }
sub dump_of { local $Data::Dumper::Sortkeys = 1; local $Data::Dumper::Useqq = 1; return Dumper(@_); }

# ------------------------------------------------------------------
# P1: the current build's line shape
# ------------------------------------------------------------------
{
    my $st = {};
    my @ev = $AL->parseText($st, "2026-11-20 12:07:18.718: logged in as $FAKE28\n");
    is(scalar(@ev), 1, '90.1-02 P1: one event for one login line');
    is($ev[0]{ev}, 'in', '90.1-02 P1: it is an in event');
    is($ev[0]{key}, key_of($FAKE28), '90.1-02 P1: key = accountIdFor of the id');
    is($ev[0]{short}, substr($FAKE28, -4), '90.1-02 P1: short = the last 4 characters');
    is_deeply($st->{last}, { key => key_of($FAKE28), short => substr($FAKE28, -4) },
        '90.1-02 P1: the reader state remembers the same pair');
    unlike(dump_of(\@ev, $st), qr/\Q$FAKE28\E/, '90.1-02 P1: the full id is nowhere in the event or the state');
    unlike(dump_of(\@ev, $st), qr/\Q@{[ substr($FAKE28, 0, 24) ]}\E/, '90.1-02 P1: nor its first 24 characters');
}

# ------------------------------------------------------------------
# P2: the older shape with an ANSI reset, and `logged out`
# ------------------------------------------------------------------
{
    my $st = {};
    my @ev = $AL->parseText($st, "11:08:38.854 I [f:415 ] logged in as $FAKE25\e[0m\n");
    is(scalar(@ev), 1, '90.1-02 P2: the older shape gives one event');
    is_deeply([ @{ $ev[0] }{qw(ev key short)} ], [ 'in', key_of($FAKE25), substr($FAKE25, -4) ],
        '90.1-02 P2: same pair, ANSI reset stripped');
    unlike(dump_of(\@ev, $st), qr/\Q$FAKE25\E/, '90.1-02 P2: the full id is nowhere');

    my @out = $AL->parseText($st, "2026-11-20 12:07:18.457: logged out\n");
    is(scalar(@out), 1, '90.1-02 P2: a logged out line gives one event');
    is($out[0]{ev}, 'out', '90.1-02 P2: it is an out event');
    ok(!defined $st->{last}, '90.1-02 P2: last is undef after logged out');

    my $st2 = {};
    my @crlf = $AL->parseText($st2, "2026-11-20 12:07:18.718: logged in as $FAKE28\r\n");
    is(scalar(@crlf), 1, '90.1-02 P2: a trailing CR is stripped');
}

# ------------------------------------------------------------------
# P3: partial line, oversize id, fakepulse line
# ------------------------------------------------------------------
{
    my $st = {};
    my $cut = 12;
    my @a = $AL->parseText($st, "2026-11-20 12:07:18.718: logged in as " . substr($FAKE28, 0, $cut));
    is(scalar(@a), 0, '90.1-02 P3: the first half of a line gives nothing');
    my @b = $AL->parseText($st, substr($FAKE28, $cut) . "\n");
    is(scalar(@b), 1, '90.1-02 P3: the second half completes exactly one event');
    is($b[0]{key}, key_of($FAKE28), '90.1-02 P3: the key is that of the whole id, not of the first half');

    my $st2 = {};
    my @big = $AL->parseText($st2, "x: logged in as " . ('a' x 130) . "\n");
    is(scalar(@big), 0, '90.1-02 P3: an id longer than 128 characters gives nothing');
    ok(!defined $st2->{last}, '90.1-02 P3: and leaves last undef');

    my @fp = $AL->parseText($st2, "[fakepulse] logged in as $FAKE28\n");
    is(scalar(@fp), 0, '90.1-02 P3: a fakepulse line gives nothing');

    my @mid = $AL->parseText($st2, "2026-11-20 12:07:18.718: user logged in as $FAKE28 and more\n");
    is(scalar(@mid), 0, '90.1-02 P3: the pattern is anchored at the end of the line');
}

# ------------------------------------------------------------------
# P4: advance on a real file
# ------------------------------------------------------------------
{
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/aabbccddee01-soloist.log";
    my $put = sub { my ($mode, $text) = @_; open(my $fh, $mode, $file) or die "$file: $!"; print $fh $text; close $fh; };

    $put->('>', "2026-11-19 10:00:00.000: logged in as $FAKE25\nsome older daemon run\n");
    my $start = -s $file;
    $put->('>>', "2026-11-20 12:07:18.718: logged in as $FAKE28\n");

    my $st = { file => $file, start => $start, pos => $start };
    my $n = $AL->advance($st);
    ok($n > 0, '90.1-02 P4: advance reads the new bytes');
    is_deeply($st->{last}, { key => key_of($FAKE28), short => substr($FAKE28, -4) },
        '90.1-02 P4: the login after the start offset is the one found, not the older one before it');
    is($st->{pos}, -s $file, '90.1-02 P4: pos moved to the end');
    is($AL->advance($st), 0, '90.1-02 P4: a second call without new bytes reads nothing');

    $put->('>>', "2026-11-20 12:09:00.000: logged in as $FAKE25\n");
    $AL->advance($st);
    is($st->{last}{key}, key_of($FAKE25), '90.1-02 P4: a later appended login is picked up on the next call');
    $put->('>>', "2026-11-20 12:10:00.000: logged out\n");
    $AL->advance($st);
    ok(!defined $st->{last}, '90.1-02 P4: a later logged out clears last');

    # shrink: the file is cut under us (log cap), pos clamps to the new size
    $put->('>', "2026-11-20 12:11:00.000: logged in as $FAKE28\n");
    my $small = -s $file;
    ok($small < $st->{pos}, 'fixture: the file is now shorter than pos');
    $AL->advance($st);
    is($st->{last}{key}, key_of($FAKE28), '90.1-02 P4: after a shrink the reader starts over from 0 and finds the login');
    is($st->{pos}, $small, '90.1-02 P4: pos is the new end');

    # bound: never more than READ_MAX per call
    my $max = $AL->READ_MAX;
    is($max, 262144, '90.1-02 P4: READ_MAX is 256 KiB');
    $put->('>', join('', (("x" x 99) . "\n") x int(($max + 500) / 100 + 1)));
    $put->('>>', "2026-11-20 12:12:00.000: logged in as $FAKE25\n");
    my $big = { file => $file, start => 0, pos => 0 };
    my $n1 = $AL->advance($big);
    is($n1, $max, '90.1-02 P4: the first call reads exactly READ_MAX');
    ok(!defined $big->{last}, '90.1-02 P4: the login line beyond the window is not seen yet');
    my $n2 = $AL->advance($big);
    ok($n2 > 0 && $n2 < $max, '90.1-02 P4: the second call reads the rest');
    is($big->{last}{key}, key_of($FAKE25), '90.1-02 P4: and finds the login');

    # a missing file is no event and no error
    my $none = { file => "$dir/nope.log", start => 0, pos => 0 };
    is($AL->advance($none), 0, '90.1-02 P4: a missing file reads nothing');
}

done_testing();
