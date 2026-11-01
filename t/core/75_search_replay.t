#!/usr/bin/perl
use strict;
use warnings;
# t/core/75_search_replay.t -- 79-58, GH #168: a search result row opens exactly the item listed in that
# row. LMS XMLBrowser replays every intermediate level with index=<row>, quantity=1
# (Slim/Control/XMLBrowser.pm:515-517) and picks items->[row - offset] (:384); this test drives
# _searchTypeFeed / _podcastSearchTypeFeed the same way over the REAL Pathfinder mapper and a slice
# server, including a forced cache miss (woorszt's ask on GH #168), a page boundary and two accounts.
# Shared stubs: the t/core/23_search_history.t set (itself the t/core/14_context_menu.t:1-501 set);
# Digest::MD5 is NOT stubbed (cache keys must differ), Slim::Utils::Cache is an in-memory store that
# copies values (as the real cache serializes them) and records each TTL.
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info     { }
sub warn     { }
sub error    { }
sub debug    { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
use Storable ();
our %_store;
our %_ttl;
sub new    { bless {}, shift }
sub get    { my $v = $_store{$_[1]}; ref $v ? Storable::dclone($v) : $v }
sub set    { $_store{$_[1]} = ref $_[2] ? Storable::dclone($_[2]) : $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    for my $fn (@_) {
        *{"${caller}::${fn}"} = \&{$fn};
    }
}
sub string  { $_[-1] }
sub cstring { $_[-1] }
1;
END

write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
sub subscribe       { }
sub addDispatch     { }
sub executeRequest  { }
1;
END

write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new  { bless {}, shift }
sub initPlugin { }
sub can  { 1 }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::PluginManager', <<'END');
package Slim::Utils::PluginManager;
sub isEnabled { 1 }
1;
END

write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
sub encode_json { '{}' }
sub decode_json { {} }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

# Load the module and initialize prefs
require Plugins::SpotOn::Plugin;

require Plugins::SpotOn::API::SpClient;
require Plugins::SpotOn::API::Pathfinder;   # the REAL module (mapper + section handling)

my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->init({ recentSearches => [] });

{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my ($cls, $id) = @_; $id //= 'player1'; bless \$id, $cls }
    sub id  { ${$_[0]} }
    sub can { 0 }
    sub playingSong { return undef }
}

# ------------------------------------------------------------------------------------------------
# Slice server: per account, a raw Pathfinder item list per section. Spotify's ranking depends on
# the request shape (measured live on 2026-10-31: the (offset i, limit 1) replay of row 1 of the
# "Bach" artist list answered a different artist than the (0, 50) list page). The server models
# that: a request with limit < 10 sees the list rotated by one.
# ------------------------------------------------------------------------------------------------
my @calls;      # { acct, op, offset, limit }
my %servers;    # acct -> { <section> => [raw items] }
my %totalAt;    # acct -> { offset => totalCount reported for a request at that offset }
my %estimate;   # acct -> 1: totalCount is Spotify's estimate min(n, offset + 103), not the list length
my %shortAt;    # acct -> { offset => n }: the page at that offset answers only its first n items

my %OP_SECT = (searchArtists => 'artists', searchAlbums => 'albumsV2', searchTracks => 'tracksV2',
               searchPlaylists => 'playlists', searchPodcasts => 'podcasts');

{
    no warnings 'redefine';
    # production SpClient::search success path: delegate to Pathfinder->search (SpClient.pm:1618-1640)
    *Plugins::SpotOn::API::SpClient::search = sub {
        my ($class, $acct, $params, $cb) = @_;
        Plugins::SpotOn::API::Pathfinder->search($acct, $params, sub { $cb->(@_) });
    };
    *Plugins::SpotOn::API::Pathfinder::query = sub {
        my ($class, $acct, $op, $vars, $cb) = @_;
        push @calls, { acct => $acct, op => $op, offset => $vars->{offset}, limit => $vars->{limit} };
        my $srv = $servers{$acct} || {};
        my %v2;
        my @sects = $OP_SECT{$op} ? ($OP_SECT{$op})
                  : qw(tracksV2 albumsV2 artists playlists podcasts episodes);
        for my $sect (@sects) {
            my $raw = $srv->{$sect} || [];
            my @rank = @$raw;
            push @rank, shift @rank if @rank && $vars->{limit} < 10;    # shape-dependent ranking
            my $n  = scalar @rank;
            my $hi = $vars->{offset} + $vars->{limit} - 1;
            $hi = $n - 1 if $hi > $n - 1;
            my @s = $vars->{offset} <= $hi ? @rank[ $vars->{offset} .. $hi ] : ();
            my $short = ($shortAt{$acct} || {})->{ $vars->{offset} };
            splice(@s, $short) if defined $short && $short < @s;
            my $tc = ($totalAt{$acct} || {})->{ $vars->{offset} }
                  // ($estimate{$acct} ? ($vars->{offset} + 103 < $n ? $vars->{offset} + 103 : $n) : $n);
            $v2{$sect} = { totalCount => $tc, items => \@s };
        }
        $cb->({ data => { searchV2 => \%v2 } });
    };
}

my $genericError = { data => { __typename => 'GenericError' } };
sub rawArtist   { my $n = shift; { data => { __typename => 'Artist', uri => "spotify:artist:$n", profile => { name => "Name $n" } } } }
sub rawAlbum    { my $n = shift; { data => { __typename => 'Album', uri => "spotify:album:$n", name => "Name $n", artists => { items => [] } } } }
sub rawTrack    { my $n = shift; { item => { data => { __typename => 'Track', uri => "spotify:track:$n", name => "Name $n", artists => { items => [ { uri => 'spotify:artist:X', profile => { name => 'X' } } ] }, albumOfTrack => { uri => "spotify:album:L$n", name => "Album $n" } } } } }
sub rawPlaylist { my $n = shift; { data => { __typename => 'Playlist', uri => "spotify:playlist:$n", name => "Name $n" } } }
sub rawShow     { my $n = shift; { data => { __typename => 'Podcast', uri => "spotify:show:$n", name => "Name $n" } } }
sub rawEpisode  { my $n = shift; { data => { __typename => 'Episode', uri => "spotify:episode:$n", name => "Name $n" } } }

# A list of $n raw items for one section; slot 3 is a GenericError (Pathfinder cannot map it).
sub rawList {
    my ($fn, $prefix, $n) = @_;
    return [ map { $_ == 3 ? $genericError : $fn->("$prefix$_") } 0 .. $n - 1 ];
}

sub clientFor {
    my ($id, $acct) = @_;
    my $c = MockClient->new($id);
    $prefs->client($c)->set('activeAccount', $acct);
    return $c;
}

sub feedFor { $_[0] eq 'show' || $_[0] eq 'episode' ? \&Plugins::SpotOn::Plugin::_podcastSearchTypeFeed : \&Plugins::SpotOn::Plugin::_searchTypeFeed }

sub identity {
    my ($row) = @_;
    return 'UNDEF'  unless $row;
    return 'IGNORE' if $row->{ignore};
    return $row->{name} // 'NONAME';
}

# XMLBrowser model: list item at row p is items->[p - offset] (ignore rows keep their slot,
# Control/XMLBrowser.pm:1003-1022); the drill-down replays the feed with index=p, quantity=1 and picks
# items->[p - offset] (:384, :515-517).
sub listed {
    my ($client, $pt) = @_;
    my $list;
    feedFor($pt->{type})->($client, sub { $list = shift }, { index => 0, quantity => 200 }, $pt);
    my @rows = map { identity($_) } @{ $list->{items} || [] };
    return (\@rows, $list->{total});
}
sub opened {
    my ($client, $pt, $p) = @_;
    my $page;
    feedFor($pt->{type})->($client, sub { $page = shift }, { index => $p, quantity => 1 }, $pt);
    return identity($page->{items}[ $p - ($page->{offset} // 0) ]);
}
sub clearCache { Slim::Utils::Cache->new->clear }
sub searchCalls { scalar grep { $_->{op} =~ /^search/ } @calls }

is(Plugins::SpotOn::API::SpClient->pageLimit('search'), 50, 'precondition: the search page size L is 50');

# ================================================================================================
# Task 1: artist rows (the reporter's case)
# ================================================================================================
my $N = 120;
my $acctA = 'acct-a';
my $acctB = 'acct-b';
$servers{$acctA} = { artists => rawList(\&rawArtist, 'A', $N) };
$servers{$acctB} = { artists => rawList(\&rawArtist, 'B', $N) };
my $clientA = clientFor('player-a', $acctA);
my $clientB = clientFor('player-b', $acctB);

subtest 'artist rows replay the listed row (cache hit)' => sub {
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my ($rows, $total) = listed($clientA, $pt);
    is($total, $N, "the listing advertises the total ($N)");
    is($rows->[3], 'IGNORE', 'the unmappable entry at position 3 keeps its slot as an ignore row');
    is(scalar(@$rows), $N, 'the listing has one row per Spotify slot');
    my @listCalls = map { "$_->{offset}/$_->{limit}" } @calls;
    is_deeply(\@listCalls, [ '0/50', '50/50', '100/50' ], 'the listing fetches aligned pages of L=50');
    my $before = searchCalls();
    for my $p (0, 1, 3, 49, 50, $N - 1) {
        is(opened($clientA, $pt, $p), $rows->[$p], "artist row $p opens the listed row ($rows->[$p])");
    }
    is(searchCalls() - $before, 0, 'a replay within the cache time sends no search request');
};

subtest 'forced miss: the replay fetches the aligned page, never limit=1' => sub {
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my ($rows) = listed($clientA, $pt);
    clearCache();
    @calls = ();
    my $o = opened($clientA, $pt, 57);
    is(scalar(@calls), 1, 'the miss on row 57 sends exactly one request');
    is($calls[0]{offset}, 50, 'with offset floor(57 / 50) * 50 = 50');
    is($calls[0]{limit},  50, 'and limit L = 50 (never 1)');
    is($o, $rows->[57], "row 57 opens the listed row ($rows->[57])");
    ok(!grep({ $_->{limit} == 1 } @calls), 'no limit=1 request');
};

subtest 'page boundary: rows 49 and 50 after a miss on 50' => sub {
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my ($rows) = listed($clientA, $pt);
    clearCache();
    my $o50 = opened($clientA, $pt, 50);
    my $o49 = opened($clientA, $pt, 49);
    is($o50, $rows->[50], 'row 50 opens the listed row after the miss');
    is($o49, $rows->[49], 'row 49 opens the listed row (its own aligned page)');
    isnt($o49, $o50, 'rows 49 and 50 differ');
    my ($again) = listed($clientA, $pt);
    my %seen; my @dup = grep { $_ ne 'IGNORE' && $seen{$_}++ } @$again;
    is(scalar(@dup), 0, 'no row is duplicated after the miss (list rebuilt from aligned pages)');
    is_deeply($again, $rows, 'the rebuilt list equals the first listing');
};

subtest 'cache_is_per_account' => sub {
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my ($rowsA) = listed($clientA, $pt);
    @calls = ();
    my $oB = opened($clientB, $pt, 7);
    is(scalar(@calls), 1, 'cache_is_per_account: account B misses the list cached for account A (one request)');
    is($calls[0]{acct}, $acctB, 'cache_is_per_account: the request goes out for account B');
    is("$calls[0]{offset}/$calls[0]{limit}", '0/50', 'cache_is_per_account: aligned (0/50)');
    is($oB, 'Name B7', "cache_is_per_account: B's replay returns B's own row 7, not A's ($rowsA->[7])");
};

subtest 'fluctuating totals: a full page reporting less than its own end does not cut the list' => sub {
    # live 2026-10-31 ("Bach", 79-58 Task 1): Spotify answered 101 and 203 for the same artist list;
    # a listing whose page 50 reports totalCount 140 must still fetch page 150 and list 200 rows
    my $acctC = 'acct-c';
    $servers{$acctC} = { artists => rawList(\&rawArtist, 'C', 203) };
    $totalAt{$acctC} = { 50 => 140 };
    my $clientC = clientFor('player-c', $acctC);
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my ($rows, $total) = listed($clientC, $pt);
    is_deeply([ map { "$_->{offset}/$_->{limit}" } @calls ], [ '0/50', '50/50', '100/50', '150/50' ],
        'the listing fetches every aligned page up to 200');
    is(scalar(@$rows), 200, 'the listing has 200 rows');
    is($total, 203, 'the advertised total is the largest total seen (203)');
    ok(!grep({ $_ eq 'UNDEF' } @$rows), 'no row of the listing is missing');
    @calls = ();
    is(opened($clientC, $pt, 199), $rows->[199], "the last listed row (199) opens the listed row ($rows->[199])");
    is(scalar(@calls), 0, 'and needs no request');
    delete $totalAt{$acctC};
};

subtest 'estimated totals: a miss on a listed row is never bounded by an earlier estimate' => sub {
    # live 2026-10-31 ("Bach"): searchArtists reports totalCount as an estimate that grows with the
    # offset (101 at offset 0, 203 at 150, 303 at 200, 403 at 300); a listed row past an earlier
    # estimate must still open after a miss
    my $acctD = 'acct-d';
    $servers{$acctD} = { artists => rawList(\&rawArtist, 'D', 400) };
    $estimate{$acctD} = 1;
    my $clientD = clientFor('player-d', $acctD);
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my $list;
    Plugins::SpotOn::Plugin::_searchTypeFeed($clientD, sub { $list = shift }, { index => 0, quantity => 400 }, $pt);
    my @rows = map { identity($_) } @{ $list->{items} || [] };
    is(scalar(@rows), 400, 'a listing of 400 fills all 400 rows although page 0 estimated 103');
    is(scalar(@calls), 8, 'from eight aligned pages');
    clearCache(); @calls = ();
    is(opened($clientD, $pt, 1), $rows[1], 'after a miss, row 1 opens the listed row (page 0, estimate 103)');
    is(opened($clientD, $pt, 380), $rows[380], "after that, row 380 opens the listed row ($rows[380]), not bounded by 103");
    is_deeply([ map { "$_->{offset}/$_->{limit}" } @calls ], [ '0/50', '350/50' ], 'with one aligned request each');
    delete $estimate{$acctD};
};

# ================================================================================================
# Task 2: the other result types, podcasts, and the overview -> category -> row request count
# ================================================================================================
my %RAW = (album => [ \&rawAlbum, 'albumsV2' ], track => [ \&rawTrack, 'tracksV2' ], playlist => [ \&rawPlaylist, 'playlists' ],
           show => [ \&rawShow, 'podcasts' ], episode => [ \&rawEpisode, 'episodes' ]);

for my $type (qw(album track playlist show episode)) {
    subtest "$type rows replay the listed row, forced miss included" => sub {
        my $podcast = ($type eq 'show' || $type eq 'episode');
        my $n    = $podcast ? 50 : $N;       # R-5: shows/episodes stop at offset 50
        my $acct = "acct-$type";
        $servers{$acct} = { $RAW{$type}[1] => rawList($RAW{$type}[0], uc(substr($type, 0, 1)), $n) };
        my $client = clientFor("player-$type", $acct);
        my $pt = { query => 'bach', type => $type };
        clearCache(); @calls = ();
        my ($rows, $total) = listed($client, $pt);
        is($rows->[3], 'IGNORE', "$type: the unmappable entry at position 3 keeps its slot");
        is(scalar(@$rows), $n, "$type: one row per Spotify slot ($n)");
        my $before = searchCalls();
        my @probe = $podcast ? (0, 1, 3, 49) : (0, 1, 3, 49, 50, $n - 1);
        for my $p (@probe) {
            is(opened($client, $pt, $p), $rows->[$p], "$type row $p opens the listed row ($rows->[$p])");
        }
        is(searchCalls() - $before, 0, "$type: a replay within the cache time sends no search request");
        clearCache(); @calls = ();
        my $miss = $podcast ? 37 : 57;
        my $o = opened($client, $pt, $miss);
        my $want = $podcast ? '0/50' : '50/50';
        is_deeply([ map { "$_->{offset}/$_->{limit}" } @calls ], [ $want ], "$type: the miss on row $miss sends one aligned request ($want)");
        is($o, $rows->[$miss], "$type: row $miss opens the listed row after the miss");
    };
}

subtest 'overview -> category -> row: one overview search and one list search' => sub {
    my $acct = 'acct-ov';
    $servers{$acct} = {
        artists  => rawList(\&rawArtist, 'O', 40),
        tracksV2 => rawList(\&rawTrack, 'T', 40),
        albumsV2 => rawList(\&rawAlbum, 'L', 40),
        playlists => rawList(\&rawPlaylist, 'P', 40),
    };
    my $client = clientFor('player-ov', $acct);
    clearCache(); @calls = ();
    my ($ov, $lv, $rv);
    # open the overview
    Plugins::SpotOn::Plugin::_searchFeed($client, sub { $ov = shift }, { search => 'bach' });
    my ($art) = grep { ($_->{passthrough} && $_->{passthrough}[0]{type} // '') eq 'artist' } @{ $ov->{items} || [] };
    ok($art, 'the overview lists the Artists category');
    my $pt = $art ? $art->{passthrough}[0] : { query => 'bach', type => 'artist' };
    # open Artists: XMLBrowser replays the overview, then lists the category
    Plugins::SpotOn::Plugin::_searchFeed($client, sub { $ov = shift }, { search => 'bach', index => 3, quantity => 1 });
    Plugins::SpotOn::Plugin::_searchTypeFeed($client, sub { $lv = shift }, { index => 0, quantity => 200 }, $pt);
    # open row 1: the overview and the list are replayed
    Plugins::SpotOn::Plugin::_searchFeed($client, sub { $ov = shift }, { search => 'bach', index => 3, quantity => 1 });
    Plugins::SpotOn::Plugin::_searchTypeFeed($client, sub { $rv = shift }, { index => 1, quantity => 1 }, $pt);
    my @ops = map { "$_->{op}($_->{offset},$_->{limit})" } @calls;
    is(scalar(@calls), 2, 'overview -> Artists -> row 1 sends two search requests in total (' . join(' ', @ops) . ')');
    is($calls[0]{op}, 'searchDesktop', 'the first is the overview');
    is($calls[0]{limit}, 10, 'the overview asks for 10 items per type');
    is(identity($rv->{items}[1 - $rv->{offset}]), identity($lv->{items}[1]), 'row 1 opens the listed row');
};

subtest 'short pages: a short page inside the list keeps positions, a short last page ends it' => sub {
    # live 2026-10-31 ("Bach" albums): searchAlbums answered 47 items at offset 0 (totalCount past the
    # page) while offset 50 answered 40 more; the list must not end at 47, and row 50 must stay raw 50
    my $acctS = 'acct-short';
    $servers{$acctS} = { artists => rawList(\&rawArtist, 'S', 120) };
    $shortAt{$acctS} = { 0 => 47 };
    my $clientS = clientFor('player-short', $acctS);
    clearCache(); @calls = ();
    my $pt = { query => 'bach', type => 'artist' };
    my ($rows, $total) = listed($clientS, $pt);
    is_deeply([ map { "$_->{offset}/$_->{limit}" } @calls ], [ '0/50', '50/50', '100/50' ], 'the short page 0 does not end the listing');
    is(scalar(@$rows), 120, 'the listing keeps 120 positions');
    is_deeply([ @{$rows}[47 .. 49] ], [ 'IGNORE', 'IGNORE', 'IGNORE' ], 'rows 47-49 (missing from page 0) are ignore rows');
    is($rows->[50], 'Name S50', 'row 50 is Spotify offset 50');
    clearCache(); @calls = ();
    is(opened($clientS, $pt, 50), 'Name S50', 'after a miss, row 50 opens the listed row');
    is(opened($clientS, $pt, 46), $rows->[46], 'and row 46 the listed row of the short page');
    delete $shortAt{$acctS};

    # a genuinely short list: page 0 answers 20 and its totalCount says 20 -> one request, total 20
    my $acctT = 'acct-twenty';
    $servers{$acctT} = { artists => rawList(\&rawArtist, 'W', 20) };
    my $clientT = clientFor('player-twenty', $acctT);
    clearCache(); @calls = ();
    my ($rowsT, $totalT) = listed($clientT, $pt);
    is(scalar(@calls), 1, 'a 20-item list costs one request');
    is($totalT, 20, 'and advertises 20');
    is(scalar(@$rowsT), 20, 'with 20 rows');
};

subtest 'the list cache TTL is 300 s' => sub {
    clearCache();
    my $pt = { query => 'bach', type => 'artist' };
    listed($clientA, $pt);
    my @ttls = map { $Slim::Utils::Cache::_ttl{$_} } grep { /search/i } keys %Slim::Utils::Cache::_store;
    ok(@ttls >= 1, 'a search list entry was stored');
    ok(!grep({ !defined $_ || $_ > 300 || $_ <= 0 } @ttls), 'every search list entry expires within 300 s');
};

done_testing();
