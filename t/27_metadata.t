use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";
use Plugins::SpotOn::Metadata;

# Fresh copies isolate malformed-field cases from one another.
sub track {
    return { uri => 'spotify:track:A', name => 'Title', duration_ms => 123000,
        artists => [{ name => 'Artist', id => 'artist-id' }],
        album => { name => 'Album', images => [{url => 'cover', width => 640}] } };
}
ok(Plugins::SpotOn::Metadata::validTrack(track(), 'A'), 'Accepts daemon track');
ok(!Plugins::SpotOn::Metadata::validTrack(track(), 'B'), 'Rejects different track');
for my $field (qw(duration_ms name uri artists album)) {
    my $info = track();
    $info->{$field} = $field eq 'artists' ? {} : [];
    ok(!Plugins::SpotOn::Metadata::validTrack($info, 'A'), "Rejects invalid $field");
}
for my $field (qw(url width height)) {
    my $info = track();
    $info->{album}{images}[0]{$field} = {};
    ok(!Plugins::SpotOn::Metadata::validTrack($info, 'A'), "Rejects invalid artwork $field");
}
my $info = track();
$info->{artists}[0]{id} = [];
ok(!Plugins::SpotOn::Metadata::validTrack($info, 'A'), 'Rejects reference-valued artist ID');
my $fresh = { title => 'New', artistId => 'new-id', year => '' };
Plugins::SpotOn::Metadata::preserveDetails($fresh,
    { title => 'Old', artistId => 'old-id', albumId => 'album-id', year => '2001' });
is_deeply($fresh, {title => 'New', artistId => 'new-id', albumId => 'album-id', year => '2001'},
    'Preserves missing details without overwriting fresh playback fields or IDs');
done_testing;
