#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Scalar::Util qw(refaddr blessed);

# ============================================================
# 87.1-02 (GH #210): SpotOn home rows hand XMLBrowser a menu tree that is
# not shared with the 60 s memo of HomeExtraBase and not shared between two
# returns. XMLBrowser writes items/offset/fetched/fetchSize/total into the
# tree it is given (XMLBrowser.pm 351, 384-385, 429-431, 1549-1569); a tree
# shared through the memo made a second item_id at the same level read an
# empty slice ("Leer" in Material).
#
# The Slim and MaterialSkin modules are not loaded: a stub class stands in
# for Plugins::MaterialSkin::HomeExtraBase, an @INC hook dies on any other
# Slim/ or Plugins/MaterialSkin/ module, and the five Plugins::SpotOn::Plugin
# feeds are fakes. A small stand-in walker models the writes XMLBrowser does
# (a MODEL; the rig walk with the real XMLBrowser is the other half of the
# proof, plan 87.1-02 task 1). No cell skips.
#
# Cells:
#   MC-1  copyMenu makes new HASH/ARRAY refs at every depth
#   MC-2  CODE refs and scalars are kept as they are
#   MC-3  blessed refs are shared, not copied
#   MC-4  the input is left unchanged
#   H210-1  walk L.Q.k lists playlist k
#   H210-2  walk L.Q.j right after it (|j-k| >= 2, same memo window) lists j
#   H210-3  walk L.Q.k again lists k
#   H210-4  a memo hit right after a walk carries no fetched/fetchSize at any depth
#   H210-5  per tag, three returns of one key share no HASH/ARRAY ref
#   MEMO-1  a second same-key call within 60 s does not call the feed
#   MEMO-2  another index or quantity calls the feed again (GH #133)
#   MEMO-3  textarea items are filtered
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
my $module      = "$project_dir/Plugins/SpotOn/HomeExtras.pm";
die "HomeExtras.pm not found at $module (die, never skip)\n" unless -f $module;

my $stub_dir = tempdir(CLEANUP => 1);
sub write_stub {
    my ($pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $stub_dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "stub $pkg: $!";
    print $fh $code;
    close $fh;
}

# The base class of the SpotOn home rows: records what each row registers.
write_stub('Plugins::MaterialSkin::HomeExtraBase', <<'END');
package Plugins::MaterialSkin::HomeExtraBase;
our @registered;
sub initPlugin { my ($class, %args) = @_; push @registered, { %args }; 1 }
1;
END

# Hermetic: no Slim:: and no Plugins::MaterialSkin:: module without a stub, so
# the file reads the same on a dev host with an LMS tree and on CI without one.
BEGIN {
    unshift @INC, sub {
        my (undef, $f) = @_;
        return unless $f =~ m{^(?:Slim|Plugins/MaterialSkin)/};
        return if -f "$main::STUB_DIR_FOR_HOOK/$f";
        die "t/79: no stub for LMS module $f -- must not reach an installed LMS\n";
    };
}
$main::STUB_DIR_FOR_HOOK = $stub_dir;
unshift @INC, $stub_dir, $project_dir;

# ---- fakes for the five wrapped feeds --------------------------------------
{
    package FakeClient;
    sub new { bless { id => $_[1] }, $_[0] }
    sub id  { $_[0]{id} }
}

my %CALLS;
my @PLAYLISTS = map { "PL$_" } 0 .. 4;
my $QTY       = 25000;

{
    package Plugins::SpotOn::Plugin;

    sub _pluginDataFor { 'icon.png' }

    # Playlists level: honours index/quantity, as the real playlists feed does.
    sub _fake_playlists_level {
        my ($client, $cb, $args) = @_;
        $CALLS{playlists_level}++;
        my $idx = $args->{index}    // 0;
        my $q   = $args->{quantity} // scalar @PLAYLISTS;
        my $end = $idx + $q - 1;
        $end = $#PLAYLISTS if $end > $#PLAYLISTS;
        my @slice = map { _fake_playlist_item($_) } $idx .. $end;
        $cb->({ items => \@slice, offset => $idx, total => scalar @PLAYLISTS });
    }

    sub _fake_playlist_item {
        my ($n) = @_;
        my $name = $PLAYLISTS[$n];
        return {
            name => $name,
            type => 'playlist',
            url  => sub {
                my ($client, $cb, $args) = @_;
                $CALLS{playlist_tracks}++;
                $cb->({
                    items  => [ map { { name => "$name-t$_", type => 'audio', url => "spoton://track:$name$_" } } 1 .. 3 ],
                    offset => 0,
                    total  => 3,
                });
            },
        };
    }

    # Library level: returns all its items, as a small list level does.
    sub _fake_library_level {
        my ($client, $cb, $args) = @_;
        $CALLS{library_level}++;
        $cb->({
            items => [
                { name => 'Liked Songs', type => 'playlist', url => sub { $_[1]->({ items => [] }) } },
                { name => 'Albums',      type => 'link',     url => sub { $_[1]->({ items => [] }) } },
                { name => 'Artists',     type => 'link',     url => sub { $_[1]->({ items => [] }) } },
                { name => 'Playlists',   type => 'link',     url => \&_fake_playlists_level },
            ],
            offset => 0,
            total  => 4,
        });
    }

    # Top level of the main menu: Library is index 2, a textarea item rides at the end.
    sub handleFeed {
        my ($client, $cb, $args) = @_;
        $CALLS{MainMenu}++;
        $cb->({
            title => 'SpotOn',
            items => [
                { name => 'Home',      type => 'link' },
                { name => 'Search',    type => 'search', url => sub { $_[1]->({ items => [] }) } },
                { name => 'Library',   type => 'link',   url => \&_fake_library_level },
                { name => 'Podcasts',  type => 'link',   url => sub { $_[1]->({ items => [] }) } },
                { name => 'junk hint', type => 'textarea' },
            ],
        });
    }

    # The other four rows: a tree with nested HASH/ARRAY at several depths.
    sub _fake_generic {
        my ($tag) = @_;
        return sub {
            my ($client, $cb, $args) = @_;
            $CALLS{$tag}++;
            $cb->({
                title   => $tag,
                actions => { more => { cmd => ['a', 'b'] } },
                items   => [
                    { name => "$tag one", type => 'audio', url => "spoton://track:1",
                      actions => { go => { params => [1, 2] } } },
                    { name => "$tag two", type => 'link', url => sub { $_[1]->({ items => [] }) },
                      items => [ { name => 'inline', actions => { x => { y => [3] } } } ] },
                    { name => "$tag hint", type => 'textarea' },
                ],
            });
        };
    }
    {
        no warnings 'once';
        *_userPlaylistsFeed   = _fake_generic('Playlists');
        *_recentlyPlayedFeed  = _fake_generic('RecentlyPlayed');
        *_topTracksFeed       = _fake_generic('TopTracks');
        *_madeForYouFeed      = _fake_generic('MadeForYou');
    }
}

# ---- load the unit under test ------------------------------------------------
require Plugins::SpotOn::HomeExtras;

my %FEED;
for my $r (@Plugins::MaterialSkin::HomeExtraBase::registered) {
    (my $tag = $r->{tag}) =~ s/^SpotOnExtras//;
    $FEED{$tag} = $r->{feed};
}
is_deeply([ sort keys %FEED ], [ sort qw(MainMenu Playlists RecentlyPlayed TopTracks MadeForYou) ],
    'setup: the five home rows registered a wrapped feed');

my $have_mc = eval { require Plugins::SpotOn::MenuCopy; 1 } ? 1 : 0;
sub cm { $have_mc ? Plugins::SpotOn::MenuCopy::copyMenu(@_) : undef }

# ---- helpers -------------------------------------------------------------------
# All HASH/ARRAY refaddrs reachable from a structure (CODE refs and blessed refs excluded).
sub refs_of {
    my ($n, $acc) = @_;
    $acc ||= {};
    return $acc unless ref $n;
    return $acc if blessed($n);
    if (ref $n eq 'ARRAY') {
        $acc->{ refaddr $n } = 1;
        refs_of($_, $acc) for @$n;
    }
    elsif (ref $n eq 'HASH') {
        $acc->{ refaddr $n } = 1;
        refs_of($_, $acc) for values %$n;
    }
    return $acc;
}

sub overlap {
    my ($a, $b) = @_;
    return scalar grep { exists $b->{$_} } keys %$a;
}

sub has_key_anywhere {
    my ($n, @keys) = @_;
    return 0 unless ref $n && !blessed($n);
    if (ref $n eq 'ARRAY') {
        for (@$n) { return 1 if has_key_anywhere($_, @keys) }
        return 0;
    }
    if (ref $n eq 'HASH') {
        for my $k (@keys) { return 1 if exists $n->{$k} }
        for (values %$n) { return 1 if has_key_anywhere($_, @keys) }
    }
    return 0;
}

# Stand-in for XMLBrowser's item_id walk (see header). Index list = the item_id
# levels; the top coderef gets index = first index and quantity 1, intermediate
# levels get the next index and quantity 1, the leaf gets index 0 and the
# requested quantity; after a fetch the result is written into the live item.
sub walk {
    my ($feed, $index, $Q, $client) = @_;
    my @index  = @$index;
    my $levels = scalar @index;

    my $top;
    $feed->($client, sub { $top = shift }, { index => $index[0], quantity => 1, params => {} });
    return () unless $top;

    $top->{type} ||= 'opml';
    my $sub = $top;
    $sub->{offset} ||= 0;

    my $depth = 0;
    for my $i (@index) {
        $depth++;
        $sub = $sub->{items}->[ $i - $sub->{offset} ];
        return () unless $sub;
        $sub->{offset} ||= 0;

        delete $sub->{fetched} if $sub->{fetched} && $sub->{fetchSize} && $sub->{fetchSize} < $Q;

        if (ref $sub->{url} eq 'CODE' && !$sub->{fetched}) {
            my %args = $depth < $levels
                ? (index => $index[$depth], quantity => 1)
                : (index => 0,              quantity => $Q);
            my $res;
            $sub->{url}->($client, sub { $res = shift }, \%args);
            $sub->{items}     = $res->{items};
            $sub->{fetched}   = 1;
            $sub->{fetchSize} = $Q;
            $sub->{total}     = $res->{total};
            $sub->{offset}    = $res->{offset};
        }
    }
    return map { $_->{name} } @{ $sub->{items} || [] };
}

sub call_feed {
    my ($tag, $client, $args) = @_;
    my $res;
    $FEED{$tag}->($client, sub { $res = shift }, $args);
    return $res;
}

# ---- MC: copyMenu ---------------------------------------------------------------
sub build_sample {
    return {
        a => [ { b => 1 }, [ 2, 3 ], 'str' ],
        c => { d => { e => [] } },
        n => 42,
        u => undef,
    };
}

{
    my $in  = build_sample();
    my $out = $have_mc ? cm($in) : undef;
    my $ov  = $have_mc ? overlap(refs_of($in), refs_of($out)) : -1;
    ok($have_mc && $ov == 0 && is_deeply_quiet($in, $out),
        "MC-1: copyMenu makes new HASH/ARRAY refs at every depth (shared=$ov)");
}

sub is_deeply_quiet {
    my ($x, $y) = @_;
    require Data::Dumper;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Indent   = 0;
    return Data::Dumper::Dumper($x) eq Data::Dumper::Dumper($y);
}

{
    my $code = sub { 'child' };
    my $in   = { url => $code, items => [ { url => $code, name => 'x', n => 7, u => undef } ] };
    my $out  = $have_mc ? cm($in) : undef;
    ok($have_mc
        && refaddr($out->{url}) == refaddr($code)
        && refaddr($out->{items}[0]{url}) == refaddr($code)
        && $out->{items}[0]{name} eq 'x'
        && $out->{items}[0]{n} == 7
        && !defined $out->{items}[0]{u},
        'MC-2: copyMenu keeps CODE refs and scalars');
}

{
    my $obj = bless { x => 1 }, 'Some::Object';
    my $arr = bless [ 1, 2 ], 'Some::List';
    my $in  = { o => $obj, l => $arr, plain => { o2 => $obj } };
    my $out = $have_mc ? cm($in) : undef;
    ok($have_mc
        && refaddr($out->{o}) == refaddr($obj)
        && refaddr($out->{l}) == refaddr($arr)
        && refaddr($out->{plain}{o2}) == refaddr($obj)
        && refaddr($out->{plain}) != refaddr($in->{plain}),
        'MC-3: copyMenu shares blessed refs, copies the plain containers around them');
}

{
    my $in   = build_sample();
    my $twin = build_sample();
    if ($have_mc) {
        my $out = cm($in);
        $out->{a}[0]{b} = 'changed';
        push @{ $out->{a} }, 'more';
        $out->{c}{d}{e}[0] = 'x';
    }
    ok($have_mc && is_deeply_quiet($in, $twin),
        'MC-4: copyMenu leaves its input unchanged, also after the copy is written to');
}

# ---- H210: the XMLBrowser walk over the wrapped MainMenu feed -----------------------
{
    my $client = FakeClient->new('00:00:00:00:00:10');
    my ($L, $Q, $k, $j) = (2, 3, 3, 1);    # |j-k| = 2: j = k-1 would alias items->[-1] onto k

    my @n1 = walk($FEED{MainMenu}, [ $L, $Q, $k ], $QTY, $client);
    is_deeply(\@n1, [ map { "PL$k-t$_" } 1 .. 3 ], "H210-1: walk L.Q.$k lists playlist $k");

    my @n2 = walk($FEED{MainMenu}, [ $L, $Q, $j ], $QTY, $client);
    is_deeply(\@n2, [ map { "PL$j-t$_" } 1 .. 3 ],
        "H210-2: walk L.Q.$j right after it lists playlist $j (memo window, same top-level key)");

    my @n3 = walk($FEED{MainMenu}, [ $L, $Q, $k ], $QTY, $client);
    is_deeply(\@n3, [ map { "PL$k-t$_" } 1 .. 3 ], "H210-3: walk L.Q.$k again lists playlist $k");
}

{
    my $client = FakeClient->new('00:00:00:00:00:11');
    my @n = walk($FEED{MainMenu}, [ 2, 3, 3 ], $QTY, $client);
    my $hit = call_feed('MainMenu', $client, { index => 2, quantity => 1, params => {} });
    ok(scalar(@n) == 3 && $hit && !has_key_anywhere($hit, 'fetched', 'fetchSize'),
        'H210-4: a memo hit right after a walk carries no fetched/fetchSize at any depth');
}

for my $tag (qw(MainMenu Playlists RecentlyPlayed TopTracks MadeForYou)) {
    my $client = FakeClient->new("00:00:00:00:51:$tag");
    my @r = map { call_feed($tag, $client, { index => 0, quantity => 5, params => {} }) } 1 .. 3;
    my @s = map { refs_of($_) } @r;
    my $shared = 0;
    $shared += overlap($s[0], $s[1]) + overlap($s[0], $s[2]) + overlap($s[1], $s[2]);
    ok(@r == 3 && !grep({ !$_ } @r) && keys(%{ $s[0] }) > 2 && $shared == 0,
        "H210-5: $tag, three returns of one key share no HASH/ARRAY ref (shared=$shared)");
}

# ---- MEMO: the memo still saves requests, keys unchanged ---------------------------------
{
    my $client = FakeClient->new('00:00:00:00:00:20');
    %CALLS = ();
    call_feed('Playlists', $client, { index => 0, quantity => 10, params => {} });
    my $after_first = $CALLS{Playlists} || 0;
    call_feed('Playlists', $client, { index => 0, quantity => 10, params => {} });
    my $after_second = $CALLS{Playlists} || 0;
    ok($after_first == 1 && $after_second == 1,
        "MEMO-1: a second same-key call within 60 s does not call the feed (calls $after_first, $after_second)");

    call_feed('Playlists', $client, { index => 10, quantity => 10, params => {} });
    my $after_index = $CALLS{Playlists} || 0;
    call_feed('Playlists', $client, { index => 0, quantity => 5, params => {} });
    my $after_qty = $CALLS{Playlists} || 0;
    ok($after_index == 2 && $after_qty == 3,
        "MEMO-2: another index or quantity calls the feed again (calls $after_index, $after_qty)");
}

{
    my $client = FakeClient->new('00:00:00:00:00:30');
    my $raw;
    Plugins::SpotOn::Plugin::handleFeed($client, sub { $raw = shift }, {});
    my $raw_text = scalar grep { ($_->{type} || '') eq 'textarea' } @{ $raw->{items} };
    my $res = call_feed('MainMenu', $client, { index => 0, quantity => 10, params => {} });
    my $left = scalar grep { ($_->{type} || '') eq 'textarea' } @{ $res->{items} };
    ok($raw_text >= 1 && $left == 0 && @{ $res->{items} } == @{ $raw->{items} } - $raw_text,
        'MEMO-3: textarea items are filtered from the returned tree');
}

done_testing();
