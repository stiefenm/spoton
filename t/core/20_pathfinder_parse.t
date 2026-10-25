#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# Temporary directory for LMS stubs
my $stub_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module
# ============================================================
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

# ============================================================
# LMS Module Stubs (minimal set -- only what API/Pathfinder.pm needs to
# compile; no HTTP dispatch is exercised by this file, only the pure parsers
# and source assertions. The HTTP behavior is t/core/66_made_for_you.t.)
# ============================================================

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
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info     { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn     { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error    { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug    { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

my $prefs_cache_dir = tempdir(CLEANUP => 1);
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
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
    return bless { _ns => \$self->{_ns} . '_client_' . (\$client // 'default') }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_] }
sub killTimers { push @kill_calls, [@_] }
sub reset_calls { @set_calls = (); @kill_calls = () }
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

write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: URI::Escape -- not Perl core, bundled by LMS
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape uri_escape_utf8);
sub uri_escape {
    my ($s) = @_;
    die "Can't escape multibyte character" if $s =~ /[^\x00-\xFF]/;
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
sub uri_escape_utf8 {
    my ($s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP -- not exercised by this file
# (only the pure Pathfinder parsers are tested), but required for
# Pathfinder.pm to compile.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new    { bless {}, shift }
sub get    { }
sub post   { }
sub put    { }
sub delete { }
1;
END

# ============================================================
# main:: constants
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# submodules resolve it via a fully-qualified call at load time.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

# ============================================================
# _subBody($source, $name)
# Extracts the body text of a top-level sub (column-0 `sub NAME {` through
# the line before the next column-0 `sub `) for scoped source assertions --
# mirrors the codebase's grep-style source-inspection tests (t/08 API-05/06).
# ============================================================
sub _subBody {
    my ($source, $name) = @_;
    my @lines = split /\n/, $source;
    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^sub \Q$name\E\b/) { $start = $i; last; }
    }
    return undef unless defined $start;
    my @body;
    for my $i ($start + 1 .. $#lines) {
        last if $lines[$i] =~ /^sub \w/;
        push @body, $lines[$i];
    }
    return join("\n", @body);
}

# ============================================================
# Fixture: the trimmed, redacted 85-04 capture set (shared with t/core/66)
# ============================================================
use JSON::PP ();
my $FX = do {
    my $f = "$project_dir/t/fixtures/pathfinder/85-04-trimmed.json";
    open(my $fh, '<:raw', $f) or BAIL_OUT("cannot read fixture $f: $!");
    local $/; JSON::PP->new->utf8->decode(<$fh>);
};

# ============================================================
# Tests: Pathfinder::_extractSectionItems (the per-item walk factored out of
# the deleted Client::_extractPathfinderIds, 85-08)
# ============================================================

my $pf_module     = "$project_dir/Plugins/SpotOn/API/Pathfinder.pm";
my $client_module = "$project_dir/Plugins/SpotOn/API/Client.pm";
my $PF = 'Plugins::SpotOn::API::Pathfinder';

sub section { my (@items) = @_; return { data => { homeSections => { sections => [ { sectionItems => { items => \@items } } ] } } }; }

SKIP: {
    skip "Pathfinder.pm not yet created", 29 unless -f $pf_module;

    require_ok('Plugins::SpotOn::API::Pathfinder')
        or BAIL_OUT("Failed to load Pathfinder.pm");

    # valid fixture -> items with uri; entries without a uri are dropped, the
    # typename travels with the item (filtering is SpClient->getMadeForYou's job)
    {
        my $items = $PF->_extractSectionItems(section(
            { uri => 'spotify:playlist:37i9dQZF1E39vTG1lmycOQ' },
            { content => { data => { uri => 'spotify:playlist:37i9dQZF1E37fO0f01qkyz', __typename => 'Playlist' } } },
            { uri => 'spotify:artist:someArtistId0000000000' },
            { uri => undef },
            { notAUri => 1 },
        ));
        is(scalar(@$items), 3, 'valid fixture: entries without a uri are dropped, the other three walked');
        is($items->[0]{uri}, 'spotify:playlist:37i9dQZF1E39vTG1lmycOQ', 'valid fixture: item-level uri read');
        is($items->[1]{uri}, 'spotify:playlist:37i9dQZF1E37fO0f01qkyz', 'valid fixture: content.data.uri read');
        is($items->[1]{typename}, 'Playlist', 'valid fixture: __typename travels with the item');
        is($items->[0]{typename}, '', 'valid fixture: a missing __typename is the empty string');
        ok(exists $items->[0]{name} && exists $items->[0]{images}, 'valid fixture: item has name and images keys');
    }

    # PlaylistResponseWrapper: name and images from content.data
    {
        my $items = $PF->_extractSectionItems(section(
            { uri => 'spotify:playlist:37i9dQZF1DXcBWIGoYBM5M',
              content => { data => { __typename => 'Playlist', name => 'Daily Mix 1', images => { items => [
                  { sources => [ { url => 'https://mosaic.scdn.co/daily1.jpg', width => 300, height => 300 } ] } ] } } } },
            { uri => 'spotify:playlist:37i9dQZF1EQnqst5TRe9Y9' },
        ));
        is(scalar(@$items), 2, 'metadata fixture: two items');
        is($items->[0]{name}, 'Daily Mix 1', 'metadata fixture: name extracted from content.data');
        is(scalar(@{ $items->[0]{images} }), 1, 'metadata fixture: images extracted from content.data');
        is($items->[0]{images}[0]{url}, 'https://mosaic.scdn.co/daily1.jpg', 'metadata fixture: image URL correct');
        is($items->[1]{name}, '', 'metadata fixture: no content.data leaves the name empty');
        is_deeply($items->[1]{images}, [], 'metadata fixture: no content.data returns empty images');
    }

    # The real homeSections envelope of the 85-04 capture set
    {
        my $mfy = $PF->_extractSectionItems($FX->{homeSection_mfy});
        is(scalar(@$mfy), 3, 'fixture homeSection_mfy: three items walked');
        is_deeply([ map { $_->{typename} } @$mfy ], [ ('Playlist') x 3 ], 'fixture homeSection_mfy: every item is a Playlist');
        ok((grep { $_->{uri} eq Plugins::SpotOn::API::Pathfinder::DJ_URI() } @$mfy), 'fixture homeSection_mfy: carries the DJ uri (filtered later by getMadeForYou)');
        my $top = $PF->_extractSectionItems($FX->{homeSection_topmix});
        is($top->[1]{name}, "Caf\x{e9}-Mix", 'fixture homeSection_topmix: a non-ASCII name decodes to characters');
        like($mfy->[0]{images}[0]{url}, qr{^https://}, 'fixture homeSection_mfy: image urls walked');
    }

    # Missing data.homeSections -> empty list, does not die.
    {
        my ($items, $lived);
        $lived = eval { $items = $PF->_extractSectionItems({ data => {} }); 1 };
        ok($lived, 'missing data.homeSections: extraction does not die');
        is_deeply($items, [], 'missing data.homeSections: returns empty list');
    }

    # Assorted malformed top-level shapes -> empty list, never dies.
    {
        my $all_lived = 1;
        for my $bad ( {}, { data => undef }, undef, 'not a hashref', [1, 2, 3] ) {
            my $items;
            my $lived = eval { $items = $PF->_extractSectionItems($bad); 1 };
            $all_lived &&= $lived;
            is_deeply($items, [], 'malformed top-level shape returns empty list: '
                . (defined $bad ? (ref($bad) || $bad) : 'undef'));
        }
        ok($all_lived, 'malformed top-level shapes: extraction never dies');
    }

    # Non-array sectionItems.items -> empty list, no die.
    {
        my $items = $PF->_extractSectionItems({ data => { homeSections => { sections => [ { sectionItems => { items => 'not-an-array' } } ] } } });
        is_deeply($items, [], 'non-array sectionItems.items: returns empty list');
    }

    # Top-level errors[] (PersistedQueryNotFound-style) carries no data -> empty.
    {
        my $items = $PF->_extractSectionItems({ errors => [ { message => 'PersistedQueryNotFound' } ] });
        is_deeply($items, [], 'errors[] response: returns empty list');
    }

    # sections is not an array
    {
        my $items = $PF->_extractSectionItems({ data => { homeSections => { sections => { not => 'an array' } } } });
        is_deeply($items, [], 'non-array sections: returns empty list');
    }
}

# ============================================================
# 85-08 Task 3: chunk-map parser, Top Tracks and search mappers on the
# trimmed 85-04 fixture (userTopContent, searchDesktop, searchTracks)
# ============================================================
SKIP: {
    skip "Pathfinder.pm not yet created", 36 unless -f $pf_module;
    require_ok('Plugins::SpotOn::API::Pathfinder');

    # --- chunk-map parser on the fixture excerpt (cut from the real main bundle) ---
    my $ex = $FX->{chunkmap_excerpt};
    my $map = $PF->_parseChunkMap($ex);
    ok($map && ref $map eq 'HASH', 'chunk-map parser on the fixture excerpt: a map is found');
    is($map->{prefix}, 'https://open.spotifycdn.com/cdn/build/web-player/', 'chunk-map parser: the CDN prefix (u.p) is read');
    is($map->{names}{7969}, 'xpui-routes-profile', 'chunk-map parser: id 7969 is xpui-routes-profile');
    ok((grep { $_ eq 'xpui-routes-search' } values %{ $map->{names} }), 'chunk-map parser: xpui-routes-search is in the id -> name map');
    ok(scalar(keys %{ $map->{hashes} }) > 100, 'chunk-map parser: the id -> chunk hash map is read (' . scalar(keys %{ $map->{hashes} }) . ' chunks)');
    my @urls = $PF->_chunkUrls($map);
    is(scalar(@urls), 2, 'chunk-map parser: exactly the two PF_CHUNKS URLs are built');
    ok((grep { m{/xpui-routes-profile\.[0-9a-f]+\.js\z} } @urls) && (grep { m{/xpui-routes-search\.[0-9a-f]+\.js\z} } @urls),
        'chunk-map parser: urls are <prefix><name>.<chunk hash>.js');
    ok(!(grep { index($_, 'https://open.spotifycdn.com/') != 0 } @urls), 'chunk-map parser: every chunk url lies under https://open.spotifycdn.com/ (T-85-31)');
    {
        # no reliance on the minified names: rename u -> r, e -> zz
        (my $renamed = $ex) =~ s/(\.u=)e=>/${1}zz=>/;
        $renamed =~ s/\[e\]/[zz]/g;
        $renamed =~ s/\|\|e\)/||zz)/;
        $renamed =~ s/\bu\.(u|p)=/r.$1=/g;
        my $m2 = $PF->_parseChunkMap($renamed);
        ok($m2 && $m2->{names}{7969} eq 'xpui-routes-profile', 'chunk-map parser: independent of the minified variable names');
    }
    {
        (my $evil = $ex) =~ s{https://open\.spotifycdn\.com/}{https://evil.example/}g;
        ok(!defined $PF->_parseChunkMap($evil), 'chunk-map parser: a prefix outside open.spotifycdn.com is refused');
        my $lived = eval { $PF->_parseChunkMap('garbage'); $PF->_parseChunkMap(undef); $PF->_parseChunkMap(''); 1 };
        ok($lived && !defined $PF->_parseChunkMap('garbage'), 'chunk-map parser: garbage and empty input give undef, never a die');
    }

    # --- userTopContent: data.me.profile.topTracks.items[].data ---
    my $utc = $FX->{userTopContent}{data}{me}{profile}{topTracks};
    my @top = map { Plugins::SpotOn::API::Pathfinder::_mapTrack($_) } @{ $utc->{items} };
    is(scalar(@top), 3, 'userTopContent: three tracks mapped');
    is($top[0]{id}, substr($utc->{items}[0]{data}{uri}, length('spotify:track:')), 'userTopContent: uri -> id');
    is($top[0]{name}, 'Track 1', 'userTopContent: name');
    is($top[0]{duration_ms}, 181000, 'userTopContent: duration.totalMilliseconds -> duration_ms');
    is($top[0]{artists}[0]{name}, 'Artist 1', 'userTopContent: artists.items[].profile.name');
    like($top[0]{artists}[0]{uri}, qr/^spotify:artist:/, 'userTopContent: artist uri kept');
    is($top[0]{album}{name}, 'Album 1', 'userTopContent: albumOfTrack.name');
    is(scalar(@{ $top[0]{album}{images} }), 3, 'userTopContent: albumOfTrack.coverArt.sources -> album.images');

    # --- searchDesktop sections ---
    my $v2 = $FX->{searchDesktop}{data}{searchV2};
    my @tr = map { Plugins::SpotOn::API::Pathfinder::_mapTrack($_) } @{ $v2->{tracksV2}{items} };
    is(scalar(@tr), 3, 'searchDesktop: tracksV2 items (wrapped in item.data) mapped');
    my @al = map { Plugins::SpotOn::API::Pathfinder::_mapAlbum($_) } @{ $v2->{albumsV2}{items} };
    is($al[0]{release_date}, '1959', 'searchDesktop: album date.year -> release_date');
    is($al[0]{artists}[0]{name}, 'Artist 1', 'searchDesktop: album artists.items[].profile.name');
    my @ar = map { Plugins::SpotOn::API::Pathfinder::_mapArtist($_) } @{ $v2->{artists}{items} };
    ok(scalar(@ar) == 3 && $ar[0]{name} eq 'Artist 1' && @{ $ar[0]{images} } == 2, 'searchDesktop: artist profile.name and visuals.avatarImage.sources');
    my @pl = map { Plugins::SpotOn::API::Pathfinder::_mapPlaylist($_) } @{ $v2->{playlists}{items} };
    ok(scalar(@pl) == 3 && $pl[0]{owner}{display_name} eq 'Spotify' && @{ $pl[0]{images} } == 1, 'searchDesktop: playlist ownerV2.data.name and images.items[].sources');
    my @sh = grep { defined } map { Plugins::SpotOn::API::Pathfinder::_mapShow($_) } @{ $v2->{podcasts}{items} };
    is(scalar(@sh), 2, 'searchDesktop: the GenericError podcast item is skipped');
    is($sh[0]{publisher}, 'Publisher 1', 'searchDesktop: show publisher.name');
    my @ep = map { Plugins::SpotOn::API::Pathfinder::_mapEpisode($_) } @{ $v2->{episodes}{items} };
    ok($ep[0]{show}{name} eq 'Show 1' && $ep[0]{release_date} eq '2026-05-21' && $ep[0]{duration_ms} == 1800001, 'searchDesktop: episode show, release_date and duration_ms');

    # --- searchTracks per-type envelope (RECONSTRUCTED from the searchDesktop tracksV2) ---
    my @st = map { Plugins::SpotOn::API::Pathfinder::_mapTrack($_) } @{ $FX->{searchTracks}{data}{searchV2}{tracksV2}{items} };
    is(scalar(@st), 3, 'searchTracks envelope: data.searchV2.tracksV2.items mapped');

    # --- malformed items never die ---
    my $all = 1;
    for my $bad (undef, 'x', [], {}, { data => {} }, { data => { uri => 'spotify:album:xxxxxxxxxxxxxxxxxxxxxx' } }, { item => { data => { __typename => 'GenericError' } } }) {
        my $r;
        $all &&= eval { $r = Plugins::SpotOn::API::Pathfinder::_mapTrack($bad); !defined $r };
    }
    ok($all, 'malformed track items: undef, no die');
    my $lived = eval { Plugins::SpotOn::API::Pathfinder::_mapSearchItem($_, undef) for qw(track album artist playlist show episode nope); 1 };
    ok($lived, 'malformed search items of every type: no die');
}

# ============================================================
# Source assertions (grep-style, mirrors t/08 API-05/API-06 convention)
# ============================================================
SKIP: {
    skip "Pathfinder.pm not yet created", 10 unless -f $pf_module;

    open(my $fh, '<', $pf_module) or BAIL_OUT("Cannot open $pf_module: $!");
    my $source = do { local $/; <$fh> };
    close($fh);

    like($source, qr/pathfinder\/v2\/query/, 'source: Pathfinder.pm names the Pathfinder endpoint');
    like($source, qr/\[0-9a-f\]\{64\}/, 'source: strict 64-hex persisted-query hash guard present (T-85-31)');
    like($source, qr/open\\\.spotifycdn\\\.com/, 'source: bundle URLs are restricted to open.spotifycdn.com');

    my $body = _subBody($source, '_attempt');
    if (defined $body) {
        like($body, qr/Login5->getToken/, 'source: Pathfinder takes its bearer from Login5->getToken');
        unlike($body, qr/TokenManager->getToken|WebPlayer->getToken/, 'source: Pathfinder never uses the PKCE or the Web-Player token');
    } else {
        fail('source: could not isolate Pathfinder::_attempt for scoped assertions') for 1 .. 2;
    }
    unlike($source, qr/TokenManager|API::WebPlayer|API::Client/, 'source: Pathfinder.pm does not reach TokenManager, WebPlayer or the Web API client');
    like($source, qr/spoton_wp_rate_limit/, 'source: Pathfinder uses the isolated rate-limit key, not spoton_rate_limit');
    unlike($source, qr/client-token/i, 'source: Pathfinder sends no client-token header');
    unlike($source, qr/'Cookie'|"Cookie"/, 'source: Pathfinder sets no Cookie header');
    like($source, qr/'User-Agent'\s*=>\s*PF_USER_AGENT/, 'source: the User-Agent is passed explicitly (Async/HTTP.pm init_header fills it only when absent)');
}

# Client.pm no longer defines the Pathfinder code (I4: survives 85-15, which
# deletes Client.pm -- the source is '' then, and the absence assertions hold).
{
    my $client_src = '';
    if (-f $client_module) {
        open(my $fh, '<', $client_module) or BAIL_OUT("Cannot open $client_module: $!");
        $client_src = do { local $/; <$fh> };
        close($fh);
    }
    unlike($client_src, qr/^sub pathfinderHome\b/m, 'source: Client.pm no longer defines pathfinderHome');
    unlike($client_src, qr/^sub getWebPlayerPlaylistItems\b/m, 'source: Client.pm no longer defines getWebPlayerPlaylistItems');
    unlike($client_src, qr/^sub _extractPathfinderIds\b/m, 'source: Client.pm no longer defines _extractPathfinderIds');
}

# SpClient keeps the strict playlist id guard on the items it hands to the menu
{
    my $sp = "$project_dir/Plugins/SpotOn/API/SpClient.pm";
    open(my $fh, '<', $sp) or BAIL_OUT("Cannot open $sp: $!");
    my $src = do { local $/; <$fh> };
    close($fh);
    my $mfy = _subBody($src, 'getMadeForYou');
    ok(defined $mfy && $mfy =~ /\[A-Za-z0-9\]\{1,40\}/, 'source: getMadeForYou validates every playlist id against the strict regex');
}

done_testing();
