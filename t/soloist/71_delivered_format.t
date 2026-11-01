#!/usr/bin/perl

# t/soloist/71_delivered_format.t
#
# 79-60 Task 1 (forum #333, beta.3 format label): Plugins::SpotOn::Soloist::DeliveredFormat
# reads what Spotify really delivered for a track from the Soloist daemon log.
# The fixture t/fixtures/soloist/delivered-format.log holds five REAL sink blocks
# (provenance: t/fixtures/soloist/README.md): an orphan sink whose track_uri line
# lies before the cut, Rosanna vorbis 160000, a prefetch sink followed by the
# ticker of the still playing track, flac 1400000 and flac 700000.
# Offline: no LMS, no daemon; Slim::Utils::Log and Slim::Utils::Prefs are stubs.

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/soloist/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $fixture = "$project_dir/t/fixtures/soloist/delivered-format.log";
die "$fixture missing -- broken checkout (die, never skip)\n" unless -f $fixture;

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

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
use Exporter 'import';
our @EXPORT = qw(logger);
sub logger { return bless {}, 'Slim::Utils::Log' }
sub is_debug { 0 }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
sub preferences { return bless { ns => \$_[0] }, 'Slim::Utils::Prefs' }
sub get { my (\$self, \$k) = \@_; return \$k eq 'cachedir' ? '$cache_dir' : undef }
1;
END

BEGIN { no warnings 'once'; *main::DEBUGLOG = sub () { 0 }; }

unshift @INC, $stub_dir, $project_dir;

my $M = 'Plugins::SpotOn::Soloist::DeliveredFormat';
my $loaded = eval { require Plugins::SpotOn::Soloist::DeliveredFormat; 1 };
ok($loaded, 'DeliveredFormat loads') or diag($@);

my $text = do { local $/; open(my $fh, '<', $fixture) or die $!; <$fh> };

my $ROSANNA = 'spotify:track:37BTh5g05cxBIRYMbw8g2T';
my $PREFETCH = 'spotify:track:5oiTnaEHK3OFDZIL8AIYwu';
my $TICKER  = 'spotify:track:7CRPXJt3IVC7V0VcM0PSQi';   # the ticker after the prefetch sink names this one
my $FLAC14  = 'spotify:track:1k1Bqnv2R0uJXQN4u6LKYt';
my $FLAC07  = 'spotify:track:5h5BrNPFvc4IXfCgnZJ2lT';
my $ORPHAN  = 'spotify:track:7GVUmCP00eSsqc4tzj1sDD';   # its track_uri line lies before the fixture's cut

# ------------------------------------------------------------
# parseLog on the real fixture
# ------------------------------------------------------------
my @recs = $loaded ? eval { $M->parseLog($text) } : ();
is(scalar(@recs), 4, 'five real sinks, four records: the orphan sink yields nothing');
is_deeply($recs[0], { uri => $ROSANNA, codec => 'vorbis', bitrate => 160000 }, 'Rosanna: vorbis 160000 bound to its track_uri');
is_deeply($recs[1], { uri => $PREFETCH, codec => 'vorbis', bitrate => 160000 },
    'prefetch sink: bound to the prepared track, not to the ticker line that follows');
is_deeply($recs[2], { uri => $FLAC14, codec => 'flac', bitrate => 1400000 }, 'flac 1400000');
is_deeply($recs[3], { uri => $FLAC07, codec => 'flac', bitrate => 700000 }, 'flac 700000');
ok(!(grep { $_->{uri} eq $ORPHAN || $_->{uri} eq $TICKER } @recs), 'no record for the orphan or the ticker track (no guess)');

# shape misses on real blocks: a removed codec line, a non-numeric bitrate
{
    (my $noCodec = $text) =~ s/^[^\n]*\]\s+codec: flac\n(?=[^\n]*bitrate: 1400000)//m;
    my @r = eval { $M->parseLog($noCodec) };
    ok(!(grep { $_->{uri} eq $FLAC14 } @r), 'codec line missing: no record for that track');
    is(scalar(@r), 3, 'codec line missing: the other three records stay');

    (my $badRate = $text) =~ s/bitrate: 700000 bits\/s/bitrate: unknown bits\/s/;
    my @r2 = eval { $M->parseLog($badRate) };
    ok(!(grep { $_->{uri} eq $FLAC07 } @r2), 'bitrate not a number: no record');
}

# incremental parse: split inside a line, state carried, same result
{
    my $state = {};
    my $cut   = index($text, 'codec: flac') + 3;
    my @a = eval { ($M->parseLog(substr($text, 0, $cut), $state), $M->parseLog(substr($text, $cut), $state), $M->parseLog("\n", $state)) };
    is_deeply(\@a, \@recs, 'incremental parse across a split line equals the one-shot parse');
}

# ANSI codes as the live log carries them
{
    (my $ansi = $text) =~ s/^(\d\d:\d\d:\d\d\.\d{3} I )/\e[0;32m$1\e[0m/mg;
    my @r = eval { $M->parseLog($ansi) };
    is(scalar(@r), 4, 'ANSI-coloured lines parse the same');
}

# ------------------------------------------------------------
# noteSongStart / deliveredFor on a growing log file
# ------------------------------------------------------------
my $MAC  = '02:00:00:5a:11:01';
my $logf = "$cache_dir/spoton/0200005a1101-soloist.log";
make_path("$cache_dir/spoton");

sub write_log { my ($mode, $data) = @_; open(my $fh, $mode, $logf) or die $!; print $fh $data; close $fh; }

{
    eval { $M->_reset };
    write_log('>', '');
    is(scalar eval { $M->logPathFor($MAC) }, $logf, 'logPathFor: <cachedir>/spoton/<mac without colons>-soloist.log');
    eval { $M->noteSongStart($MAC, $ROSANNA) };
    is(scalar eval { $M->deliveredFor($MAC, $ROSANNA) }, undef, 'nothing logged yet: undef (the caller shows the setting)');
    write_log('>>', $text);
    is_deeply(scalar eval { $M->deliveredFor($MAC, $ROSANNA) }, { codec => 'vorbis', bitrate => 160000 }, 'appended block found by the incremental read');
    is_deeply(scalar eval { $M->deliveredFor($MAC, $FLAC14) }, { codec => 'flac', bitrate => 1400000 }, 'a second track of the same slice');
    is(scalar eval { $M->deliveredFor($MAC, $ORPHAN) }, undef, 'the orphan track: undef');
}

# the window starts BACK_OFF before the size at song start: a sink logged
# shortly BEFORE LMS started the song (Connect, prefetch) is found
{
    eval { $M->_reset };
    write_log('>', ('x' x 200_000) . "\n" . $text);
    eval { $M->noteSongStart($MAC, $FLAC07) };
    is_deeply(scalar eval { $M->deliveredFor($MAC, $FLAC07) }, { codec => 'flac', bitrate => 700000 }, 'sink just before the song start is inside the window');
}

# the 256 KiB bound: a sink logged beyond READ_MAX after the window start is never read
{
    eval { $M->_reset };
    write_log('>', '');
    eval { $M->noteSongStart($MAC, $FLAC14) };
    write_log('>>', ('y' x (256 * 1024 + 10)) . "\n" . $text);
    is(scalar eval { $M->deliveredFor($MAC, $FLAC14) }, undef, 'a sink beyond the 256 KiB window is not read');
    is(scalar eval { $M->READ_MAX }, 256 * 1024, 'READ_MAX is 256 KiB');
}

# same uri again (seek, rewind): the window and its record are kept
{
    eval { $M->_reset };
    write_log('>', $text);
    eval { $M->noteSongStart($MAC, $ROSANNA) };
    my $first = eval { $M->deliveredFor($MAC, $ROSANNA) };
    write_log('>', '');    # truncated (log cap) after the record was read
    eval { $M->noteSongStart($MAC, $ROSANNA) };
    is_deeply(scalar eval { $M->deliveredFor($MAC, $ROSANNA) }, $first, 'repeated noteSongStart for the same uri keeps the record');
}

# memo bound: at most MEMO_MAX windows
{
    eval { $M->_reset };
    write_log('>', $text);
    eval { $M->noteSongStart($MAC, $ROSANNA); $M->deliveredFor($MAC, $ROSANNA) };
    for my $i (1 .. 60) { eval { $M->noteSongStart($MAC, sprintf('spotify:track:Filler%016d', $i)) } }
    is(scalar eval { $M->_windowCount }, 50, 'at most 50 windows are kept (MEMO_MAX)');
    is(scalar eval { $M->deliveredFor($MAC, 'spotify:track:Filler0000000000000060') }, undef, 'the newest window is kept');
    is(scalar eval { $M->_hasWindow($MAC, $ROSANNA) }, 0, 'the oldest window was evicted');
}

# ------------------------------------------------------------
# 79-67 (Material format line): Plugins::SpotOn::DisplayFormat rounds the REAL
# fixture records into the bitrate field and the Spotify side of the two-part
# label (one rounding for both). No record, no number.
# ------------------------------------------------------------
{
    my $D = 'Plugins::SpotOn::DisplayFormat';
    my $dl = eval { require Plugins::SpotOn::DisplayFormat; 1 };
    ok($dl, '79-67: Plugins::SpotOn::DisplayFormat loads') or diag($@);
    my $rl = sub { my ($r) = @_; return $dl && $D->can('rateLabel') ? scalar(eval { $D->rateLabel($r) }) : 'NO-rateLabel' };
    my $cs = sub { my ($f) = @_; return $dl && $D->can('codecShort') ? scalar(eval { $D->codecShort($f) }) : 'NO-codecShort' };

    is_deeply([ map { $rl->($_) } @recs ], [ '160k', '160k', '1400k', '700k' ],
        '79-67: rateLabel of the four real parseLog records => 160k, 160k, 1400k, 700k');
    my ($orphanRec) = grep { $_->{uri} eq $ORPHAN } @recs;
    my ($tickerRec) = grep { $_->{uri} eq $TICKER } @recs;
    is($rl->($orphanRec), '', '79-67: the orphan track has no record => rateLabel ""');
    is($rl->($tickerRec), '', '79-67: the ticker track has no record => rateLabel ""');
    my %noCodec = %{ $recs[2] // {} }; delete $noCodec{codec};
    is($rl->(\%noCodec), '', '79-67: a record without codec => rateLabel ""');
    my %badRate = (%{ $recs[3] // {} }, bitrate => 'unknown');
    is($rl->(\%badRate), '', '79-67: a non-numeric bitrate => rateLabel ""');
    is($rl->({ codec => 'aac', bitrate => 256000 }), '', '79-67: an unknown codec => rateLabel ""');
    is($rl->({ codec => 'vorbis', bitrate => 999 }), '', '79-67: a bitrate under 1000 => rateLabel ""');

    is_deeply([ map { $cs->($_) } qw(flac pcm mp3 ogg) ], [ qw(FLAC PCM MP3 OGG) ], '79-67: codecShort flac/pcm/mp3/ogg => FLAC/PCM/MP3/OGG');
    is_deeply([ map { $cs->($_) } ('vorbis', 'aac', '', undef) ], [ '', '', '', '' ], '79-67: codecShort of anything else => ""');
}

done_testing();
