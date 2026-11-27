#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP ();

# 93-03 (D-08 Wave 0): the real frames of a refused title, one fixture per failure
# class, and the SHAPE each recording shows. Plan 93-04 builds its never-played
# detector and its RED Control cases (t/soloist/44) on these facts, so this file
# pins what the recordings contain, not what a detector should do.
#
#   class A  d51-error-advance-m1c3.frames   the daemon skips the refused title itself:
#                                            a track_changed to another uri follows
#   class B  d51-refused-start-m1.frames     the start is refused: track_changed to X, then
#                                            paused at position 0, NEVER playing, no position
#                                            rise, no further track_changed in the window
#   class R  d51-refused-no-successor.frames the rig recording (only when it reproduced)
#
# Hand-copied loader: the d50_frames form of t/soloist/44_soloist_control.t (README form 2:
# a `#ts=<HH:MM:SS.mmm> epoch=<float>` line before every frame, other `#` lines are comments).
# A missing fixture dies - it is never skipped (79-79 W3).

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# d51_frames($name) -> ( [ epoch, decoded frame, has_ts_line ], ... )
sub d51_frames {
    my ($name) = @_;
    open(my $fh, '<', "$project_dir/t/fixtures/soloist/$name") or die "fixture $name missing";
    binmode($fh);
    my (@out, $ep);
    while (my $l = <$fh>) {
        chomp $l;
        next unless length $l;
        if ($l =~ /^#ts=\S+ epoch=([0-9.]+)/) { $ep = $1; next; }
        next if $l =~ /^#/;
        push @out, [ $ep, JSON::PP->new->utf8(1)->decode($l), defined $ep ];
        undef $ep;    # every frame needs its own ts line
    }
    close($fh);
    return @out;
}

# d51_shape(@frames) -> the facts a detector would have to read from the stream
sub d51_shape {
    my (@fx) = @_;
    my %s = (
        n             => scalar(@fx),
        all_ts        => (scalar(grep { !$_->[2] } @fx) ? 0 : 1),
        first_type    => ($fx[0] ? $fx[0][1]{type} : ''),
        status_seq    => [],
        playing_seen  => 0,
        positions     => [],
        speeds        => [],
        track_changes => [],
        span_s        => (@fx ? $fx[-1][0] - $fx[0][0] : 0),
    );
    for my $e (@fx) {
        my $f = $e->[1];
        my $t = $f->{type} // '';
        if ($t eq 'track_changed') {
            push @{ $s{track_changes} }, $f->{item}{uri};
        }
        if ($t eq 'playback_changed' || $t eq 'playback_state') {
            my $st = $f->{status} // '';
            push @{ $s{status_seq} }, $st unless @{ $s{status_seq} } && $s{status_seq}[-1] eq $st;
            $s{playing_seen} = 1 if $st eq 'playing';
        }
        if ($t eq 'position_sync' || ($t eq 'playback_state' && $f->{position})) {
            push @{ $s{positions} }, $f->{position}{position_ms};
            push @{ $s{speeds} },    $f->{position}{speed};
        }
    }
    return \%s;
}

# ------------------------------------------------------------
# 93-03 D08-A: class A (m1-c3 frames 29-44). The refused title is dropped by the daemon
# itself; the frames show a track_changed to ANOTHER uri right behind the refusal window,
# buffering, then playing for that successor. Not a hang: it stays out of the detector.
# ------------------------------------------------------------
subtest '93-03 D08-A: class A error advance - a track_changed to another uri follows, then playing' => sub {
    my @fx = d51_frames('d51-error-advance-m1c3.frames');
    my $s  = d51_shape(@fx);
    cmp_ok($s->{n}, '>=', 10, '93-03 D08-A: the fixture decodes to a real frame run');
    ok($s->{all_ts}, '93-03 D08-A: every frame has its #ts= line');
    is($s->{first_type}, 'track_changed', '93-03 D08-A: the run starts with the track_changed of the title that is then refused');
    my @tc = @{ $s->{track_changes} };
    is(scalar(@tc), 2, '93-03 D08-A: two track_changed frames: the refused title and its successor');
    isnt($tc[1], $tc[0], '93-03 D08-A: the second track_changed names ANOTHER uri (the error advance)');
    is($tc[1], 'spotify:track:0s8bYUlveIQJMrwiIDHb7f', '93-03 D08-A: the successor is the title the daemon log names');
    my @after = grep { ($_->[1]{type} // '') eq 'playback_state' && ($_->[1]{item}{uri} // '') eq $tc[1] } @fx;
    is($after[-1][1]{status}, 'playing', '93-03 D08-A: the successor ends up playing');
    ok($s->{span_s} < 2, '93-03 D08-A: the whole advance lies inside two seconds (not a hang)');
};

# ------------------------------------------------------------
# 93-03 D08-B: class B (m1-c3 skip k6, frames 83-87; alternative k11 = 134-138 has the
# same shape). The shape the recording ACTUALLY shows: track_changed to X, then paused
# frames for X at position 0, NO playing frame for X, the position never rises, no further
# track_changed. The window runs from the command to the harness's next command (20 s
# later, frames outside this file): that length is the window_s field of the record
# (93-03-D08-RECORDING.md), not a frame fact, so it is not asserted here.
# ------------------------------------------------------------
subtest '93-03 D08-B: class B refused start - track_changed to X, paused at 0, never playing' => sub {
    my @fx = d51_frames('d51-refused-start-m1.frames');
    my $s  = d51_shape(@fx);
    cmp_ok($s->{n}, '>=', 4, '93-03 D08-B: the fixture decodes to the frames after the refused start');
    ok($s->{all_ts}, '93-03 D08-B: every frame has its #ts= line');
    is($s->{first_type}, 'track_changed', '93-03 D08-B: the first frame is the track_changed to X');
    my $x = $fx[0][1]{item}{uri};
    like($x, qr/^spotify:track:[A-Za-z0-9]{22}$/, '93-03 D08-B: X is a track uri');
    is_deeply($s->{status_seq}, ['paused'], '93-03 D08-B: the only status in the window is paused (no buffering, no playing)');
    ok(!$s->{playing_seen}, '93-03 D08-B: no frame reports playing for X');
    my @ps = grep { ($_->[1]{type} // '') eq 'playback_state' } @fx;
    ok(scalar(@ps) >= 1, '93-03 D08-B: a playback_state frame is there');
    is($ps[-1][1]{item}{uri}, $x, '93-03 D08-B: the paused playback_state names X');
    is($ps[-1][1]{status}, 'paused', '93-03 D08-B: ... and it is paused');
    is_deeply([ grep { $_ != 0 } @{ $s->{positions} } ], [], '93-03 D08-B: position_ms stays 0 in every position frame (no rise)');
    is_deeply([ grep { $_ != 0 } @{ $s->{speeds} } ],    [], '93-03 D08-B: speed stays 0 (nothing advances)');
    is(scalar(@{ $s->{track_changes} }), 1, '93-03 D08-B: no further track_changed in the window');
    ok($s->{span_s} < 1, '93-03 D08-B: all frames arrive within one second of the command (what follows is the next harness command)');
};

done_testing();
