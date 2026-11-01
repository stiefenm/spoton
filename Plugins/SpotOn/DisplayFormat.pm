package Plugins::SpotOn::DisplayFormat;

# Plugins::SpotOn::DisplayFormat -- the pure formatting of SpotOn's format fields
# (79-67, forum #333, user decision "An Material anpassen").
#
# Material Skin's formatTechInfo shows `bitrate` only when it is longer than one
# character and `type` only when it is at most four characters long. So `type`
# carries the short LMS-side codec (codecShort) and `bitrate` the rate Spotify
# delivered for the playing track (rateLabel). The Spotify side of the two-part
# label uses the same rateLabel, so the field and the label cannot disagree.
#
# Backend-neutral on purpose: no Slim::*, no backend module. t/soloist/71 runs
# the real fixture records through it without loading Plugin.pm.

use strict;
use warnings;

my %RATED_CODEC = map { $_ => 1 } qw(flac vorbis mp3);
my %CODEC_SHORT = (flac => 'FLAC', pcm => 'PCM', mp3 => 'MP3', ogg => 'OGG');

# rateLabel($class, $rec) -> '<n>k' | ''
# $rec is a measured record { codec, bitrate } (Soloist::DeliveredFormat). A
# record with codec flac, vorbis or mp3 and an integer bitrate of at least 1000
# bits/s gives the rate rounded to kbit/s; anything else gives '' (no number
# without a measurement, never a guess).
sub rateLabel {
    my ($class, $rec) = @_;
    return '' unless ref $rec eq 'HASH';
    my $codec = $rec->{codec};
    my $bps   = $rec->{bitrate};
    return '' unless defined $codec && $RATED_CODEC{$codec};
    return '' unless defined $bps && $bps =~ /\A[0-9]+\z/ && $bps >= 1000;
    return int($bps / 1000 + 0.5) . 'k';
}

# codecShort($class, $fmt) -> FLAC | PCM | MP3 | OGG | ''
# $fmt is the LMS-side stream format (ogg|flac|mp3|pcm); anything else gives ''.
sub codecShort {
    my ($class, $fmt) = @_;
    return '' unless defined $fmt;
    return $CODEC_SHORT{$fmt} // '';
}

1;
