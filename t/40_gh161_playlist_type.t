#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# ============================================================
# Phase 76-03 gap fill (Nyquist validation): GH-161 -- Recently Played,
# Liked Songs, and Top Tracks menu entries must be type => 'playlist'
# (flat track lists get Play All / Add to Queue hover actions in Material
# Skin); Made For You and Up Next (GH-135, a live-status list) must stay
# type => 'link'. Prior coverage was a syntax-only gate
# (t/05_perl_syntax.t) -- this pins the actual menu-item shape.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);
my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";

plan skip_all => 'Plugin.pm not present in this checkout' unless -f $plugin_file;

open(my $fh, '<', $plugin_file) or die "Cannot read $plugin_file: $!";
local $/;
my $src = <$fh>;
close($fh);

# Each menu-item hash is a `{ ... url => \&_feedSub, ... }` block; extract
# by anchoring on the url line and scanning forward/backward for the
# enclosing braces (items span a handful of lines, no nested hashes).
sub item_block_for {
    my ($feed_sub) = @_;
    my ($block) = $src =~ /(\{[^{}]*?url\s*=>\s*\\&\Q$feed_sub\E[^{}]*?\})/s;
    return $block;
}

for my $case (
    ['_recentlyPlayedFeed', 'playlist', 'Recently Played'],
    ['_savedTracksFeed',    'playlist', 'Liked Songs'],
    ['_topTracksFeed',      'playlist', 'Top Tracks'],
    ['_madeForYouFeed',     'link',     'Made For You (valid state)'],
    ['_madeForYouExpiredFeed', 'link',  'Made For You (expired state)'],
    ['_upNextFeed',         'link',     'Up Next (GH-135, live-status list)'],
) {
    my ($sub, $expected_type, $label) = @$case;
    my $block = item_block_for($sub);
    ok($block, "GH-161: menu item block for $label ($sub) found") or next;
    like($block, qr/type\s*=>\s*'\Q$expected_type\E'/,
        "GH-161: $label carries type => '$expected_type'");
}

# Negative pin: Made For You must NEVER be 'playlist' (Play All on an
# intermediate playlist-of-playlists level would be wrong).
for my $sub (qw(_madeForYouFeed _madeForYouExpiredFeed)) {
    my $block = item_block_for($sub);
    next unless $block;
    unlike($block, qr/type\s*=>\s*'playlist'/,
        "GH-161: $sub is never type => 'playlist'");
}

done_testing();
