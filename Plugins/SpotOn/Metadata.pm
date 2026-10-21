package Plugins::SpotOn::Metadata;

use strict;
use warnings;

# Validate the daemon wire shape before either playback path consumes it.
# Optional identifiers must remain scalars because LMS uses them in menu URLs.
sub validTrack {
    my ($info, $trackId) = @_;
    return 0 unless ref($info) eq 'HASH'
        && !ref($info->{uri}) && ($info->{uri} || '') eq "spotify:track:$trackId"
        && !ref($info->{name}) && length($info->{name} || '')
        && defined($info->{duration_ms}) && !ref($info->{duration_ms})
        && $info->{duration_ms} =~ /^\d+$/
        && ref($info->{artists}) eq 'ARRAY';
    for my $artist (@{$info->{artists}}) {
        return 0 unless ref($artist) eq 'HASH' && defined($artist->{name})
            && !ref($artist->{name}) && !ref($artist->{id});
    }
    my $album = $info->{album};
    return 0 unless ref($album) eq 'HASH' && !ref($album->{name})
        && !ref($album->{id}) && !ref($album->{release_date})
        && ref($album->{images}) eq 'ARRAY';
    for my $image (@{$album->{images}}) {
        return 0 unless ref($image) eq 'HASH' && defined($image->{url}) && !ref($image->{url});
        for my $dimension (qw(width height)) {
            return 0 if ref($image->{$dimension})
                || (defined($image->{$dimension}) && $image->{$dimension} !~ /^-?\d+$/);
        }
    }
    return 1;
}

# Fill only missing optional details; callers must supply caches for the same track.
# Playback fields always come from the fresh payload, never the previous song.
sub preserveDetails {
    my ($fresh, @previous) = @_;
    for my $old (@previous) {
        next unless ref($old) eq 'HASH';
        for my $key (qw(artistId artistIds albumId year)) {
            $fresh->{$key} = $old->{$key}
                if !length($fresh->{$key} || '') && length($old->{$key} || '');
        }
    }
    return $fresh;
}

1;
