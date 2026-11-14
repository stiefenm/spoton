#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# GH #32: the LMS library importer (Importer.pm) against a stubbed SpClient,
# Online Library base class and LMS schema. Covers the quota rules of #32
# (no request for a known album or an unchanged playlist, one call at a time,
# the first 429 stops the run), the keep-on-partial-read rule (nothing is
# deleted that could not be read), the attribute mapping and the default-on /
# no-polling wiring in Plugin.pm and install.xml.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
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

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our (@warnings, @infos, $infoOn);
sub import { my $caller = caller; no strict 'refs'; *{"${caller}::logger"} = \&logger; }
sub logger   { return bless {}, 'Slim::Utils::Log' }
sub warn     { push @warnings, $_[1] }
sub info     { push @infos, $_[1] }
sub is_info  { $infoOn ? 1 : 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %store;
sub import { my $caller = caller; no strict 'refs'; *{"${caller}::preferences"} = \&preferences; }
sub preferences { my $ns = ($_[0] eq 'Slim::Utils::Prefs') ? $_[1] : $_[0]; return bless { _ns => $ns }, 'Slim::Utils::Prefs'; }
sub get  { $store{$_[0]->{_ns}}{$_[1]} }
sub set  { $store{$_[0]->{_ns}}{$_[1]} = $_[2] }
sub init { my ($self, $h) = @_; $store{$self->{_ns}}{$_} //= $h->{$_} for keys %$h }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %store;
our %expiry;
sub new    { bless {}, shift }
sub get    { $store{$_[1]} }
sub set    { $store{$_[1]} = $_[2]; $expiry{$_[1]} = $_[3]; 1 }
sub remove { delete $store{$_[1]} }
sub clear  { %store = (); %expiry = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import { my $caller = caller; no strict 'refs'; *{"${caller}::string"} = sub { $_[0] }; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @paced;
sub setTimer { push @paced, $_[1]; $_[2]->() }   # the importer's pacing timer fires at once
1;
END

write_stub($stub_dir, 'Slim::Utils::Progress', <<'END');
package Slim::Utils::Progress;
sub new    { my ($c, $a) = @_; bless { total => $a->{total} }, $c }
sub total  { my $s = shift; $s->{total} = shift if @_; $s->{total} }
sub update { }
sub final  { }
1;
END

write_stub($stub_dir, 'Slim::Music::Import', <<'END');
package Slim::Music::Import;
our $playlistsOnly = 0;
our @ended;
sub scanPlaylistsOnly { $playlistsOnly }
sub endImporter { push @ended, $_[1] }
1;
END

# The Online Library base class: storeTracks / online_tracks bookkeeping recorded, deleteRemovedTracks
# reports what it WOULD delete (rows with the track prefix that nobody stored or kept).
write_stub($stub_dir, 'Slim::Plugin::OnlineLibraryBase', <<'END');
package Slim::Plugin::OnlineLibraryBase;
our (@stored, %online, $deleted, $ignorePlaylists);
sub initPlugin { 1 }
sub isImportEnabled { 1 }
sub ignorePlaylists { $ignorePlaylists ? 1 : 0 }
sub initOnlineTracksTable { %online = () }
sub storeTracks {
    my ($class, $tracks, $libraryId, $accountId) = @_;
    for my $t (@$tracks) {
        my %a = %$t;
        my $url = delete $a{url};
        $online{$url} = 1;
        $Slim::Schema::tracks{$url} = { %a, _comment => $accountId };
        push @stored, $url;
    }
}
sub deleteRemovedTracks {
    my $class = shift;
    my $prefix = $class->trackUriPrefix;
    $deleted = [ sort grep { index($_, $prefix) == 0 && !$online{$_} } keys %Slim::Schema::tracks ];
    delete $Slim::Schema::tracks{$_} for @$deleted;
}
1;
END

# LMS schema: %tracks holds the library rows (url => attributes), %playlists the playlist rows
# (url => [track urls]). The dbh understands exactly the statements Importer.pm sends.
write_stub($stub_dir, 'Slim::Schema', <<'END');
package Slim::Schema;
our (%tracks, %playlists, @dbDo);
sub forceCommit { }
sub dbh { bless {}, 'Slim::Schema::StubDbh' }
sub updateOrCreate {
    my ($class, $args) = @_;
    $playlists{ $args->{url} } = { attributes => $args->{attributes}, tracks => [] };
    return bless { url => $args->{url} }, 'Slim::Schema::StubPlaylist';
}
package Slim::Schema::StubPlaylist;
sub setTracks { $Slim::Schema::playlists{ $_[0]{url} }{tracks} = [ @{ $_[1] } ] }
package Slim::Schema::StubDbh;
sub do {
    my ($self, $sql, undef, @bind) = @_;
    push @Slim::Schema::dbDo, [ $sql, @bind ];
    if ($sql =~ /INSERT OR IGNORE INTO online_tracks/) {
        if ($sql =~ /album IN \(SELECT id FROM albums WHERE extid = \?\)/) {
            $Slim::Plugin::OnlineLibraryBase::online{$_} = 1
                for grep { ($tracks{$_}{ALBUM_EXTID} // '') eq $bind[0] } keys %tracks;
        }
        elsif ($sql =~ /AND url LIKE \?$/) {
            (my $p = $bind[0]) =~ s/%$//;
            $Slim::Plugin::OnlineLibraryBase::online{$_} = 1 for grep { index($_, $p) == 0 } keys %tracks;
        }
    }
    return 1;
}
sub selectall_arrayref {
    my ($self, $sql, undef, $like) = @_;
    (my $p = $like) =~ s/%$//;
    my $i = 0;
    return [ map { [ ++$i, $_ ] } sort grep { index($_, $p) == 0 } keys %playlists ];
}
sub selectrow_array {   # SELECT 1 FROM tracks WHERE url LIKE ? LIMIT 1 -- playlists are tracks rows in LMS
    my ($self, $sql, undef, $like) = @_;
    (my $p = $like) =~ s/%$//;
    return (grep { index($_, $p) == 0 } keys %playlists, keys %tracks) ? (1) : ();
}
sub prepare_cached { bless {}, 'Slim::Schema::StubSth' }
package Slim::Schema::StubSth;
sub execute {
    my ($self, $id) = @_;
    my @urls = sort grep { index($_, 'spoton://playlist:') == 0 } keys %Slim::Schema::playlists;
    delete $Slim::Schema::playlists{ $urls[$id - 1] } if $urls[$id - 1];
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
1;
END

write_stub($stub_dir, 'Slim::Networking::Async::HTTP', <<'END');
package Slim::Networking::Async::HTTP;
our ($jar, $inits) = (undef, 0);
sub cookie_jar { $jar }
sub init { $inits++; $jar = bless { autosave => 1, file => '/cache/cookies.dat' }, 'HTTP::Cookies' }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our %paired = (acct1 => 1);
sub verifyCredentials { return $paired{$_[1]} ? { username => "u_$_[1]", auth_data => 'x' } : undef }
1;
END

# SpClient: canned answers per method, every call recorded, answers synchronous (cache-hit shape,
# so the importer's EV loop is never entered). requestCount grows by one per answered call, except
# for the methods in %cacheHit (answered from SpClient's caches: no request is dispatched).
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
our (@calls, %answer, %cacheHit, $rateLimitedFor, $requests);
$requests = 0;
sub _answer {
    my ($name, $key, $cb) = @_;
    push @calls, "$name:$key";
    my $a = $answer{"$name:$key"} // $answer{$name};
    $a = $a->($key) if ref $a eq 'CODE';
    $requests++ unless $cacheHit{$name};
    $cb->(@{ $a || [ undef, { error => 'no_fixture' } ] });
}
sub getSavedAlbumUris    { _answer('saved',     $_[1], $_[2]) }
sub getAlbumWithTracks   { _answer('album',     $_[2], $_[3]) }
sub getAlbumTrackIds     { _answer('albumids',  $_[2], $_[3]) }
our $batchSize = 200;
sub trackBatchSize       { $batchSize }
# the fixtures keep the page shape ({ items => [...] }); getPlaylistIndex answers the bare list
sub getPlaylistIndex {
    my $cb = $_[2];
    _answer('playlists', $_[1], sub { my ($page, $err) = @_; $cb->($page ? $page->{items} : undef, $err) });
}
sub getPlaylistTrackUris { _answer('pltracks',  $_[2], $_[3]) }
sub prefetchTracks       { _answer('prefetch',  scalar @{ $_[2] }, $_[3]) }
sub rateLimitedFor { $rateLimitedFor || 0 }
sub requestCount   { $requests }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::SCANNER   = sub () { 1 };
    *main::INFOLOG   = sub () { 1 };   # the stub log's is_info decides ($Slim::Utils::Log::infoOn)
    *main::DEBUGLOG  = sub () { 0 };
    *main::WEBUI     = sub () { 0 };
    *main::ISWINDOWS = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

# the scanner has these loaded before any importer runs
require Slim::Music::Import;
require Slim::Utils::Progress;
require Slim::Schema;
require Plugins::SpotOn::API::SpClient;

require_ok('Plugins::SpotOn::Importer') or BAIL_OUT('Failed to load Importer.pm');
my $IMP = 'Plugins::SpotOn::Importer';

# ------------------------------------------------------------
# fixtures
# ------------------------------------------------------------
sub id22 { my $c = shift; return $c x 22 }
my ($A1, $A2, $A3) = map { id22($_) } qw(a b c);
my ($T1, $T2, $T3, $T4) = map { id22($_) } qw(1 2 3 4);
my ($P1, $P2) = map { id22($_) } qw(p q);

sub album_fixture {
    my ($id, %o) = @_;
    my @items = @{ $o{tracks} || [
        { id => $T1, name => 'One', duration_ms => 61000, disc_number => 1, track_number => 1, artists => [ { id => id22('x'), name => 'Band' } ] },
        { id => $T2, name => 'Two', duration_ms => 62000, disc_number => 1, track_number => 2, artists => [ { id => id22('x'), name => 'Band' }, { id => id22('y'), name => 'Guest' } ] },
    ] };
    return [ {
        id           => $id,
        name         => $o{name} || "Album $id",
        artists      => $o{artists} || [ { id => id22('x'), name => 'Band' } ],
        release_date => '2001-02-03',
        album_type   => $o{type} || 'album',
        images       => [ { url => 'https://i.scdn.co/image/aa11', width => 300 }, { url => 'https://i.scdn.co/image/bb22', width => 640 } ],
        tracks       => { items => \@items, total => $o{total} // scalar @items },
    } ];
}

sub reset_world {
    @Plugins::SpotOn::API::SpClient::calls = ();
    %Plugins::SpotOn::API::SpClient::answer = ();
    %Plugins::SpotOn::API::SpClient::cacheHit = ();
    $Plugins::SpotOn::API::SpClient::rateLimitedFor = 0;
    $Plugins::SpotOn::API::SpClient::batchSize = 200;
    @Slim::Plugin::OnlineLibraryBase::stored = ();
    $Slim::Plugin::OnlineLibraryBase::deleted = undef;
    $Slim::Plugin::OnlineLibraryBase::ignorePlaylists = 0;
    @Slim::Schema::dbDo = ();
    @Slim::Utils::Timers::paced = ();
    @Slim::Utils::Log::warnings = ();
    @Slim::Utils::Log::infos = ();
    $Slim::Utils::Log::infoOn = 0;
    $Slim::Music::Import::playlistsOnly = 0;
}

sub calls_of { my $p = shift; return grep { /^\Q$p\E:/ } @Plugins::SpotOn::API::SpClient::calls }

Slim::Utils::Prefs::preferences('plugin.spoton')->set('accounts', { acct1 => { displayName => 'A' }, acct2 => { displayName => 'B' } });
Slim::Utils::Prefs::preferences('server')->set('splitList', ';');
$Slim::Plugin::OnlineLibraryBase::online{dummy} = 1;

# ============================================================
# wiring
# ============================================================
{
    is($IMP->trackUriPrefix, 'spoton://track:', 'trackUriPrefix is the playable SpotOn track url');
    is_deeply([ $IMP->_accounts ], ['acct1'], '_accounts: only accounts with stored credentials are imported');

    open(my $fh, '<', "$project_dir/Plugins/SpotOn/install.xml") or die $!;
    my $xml = do { local $/; <$fh> };
    like($xml, qr{<importmodule>Plugins::SpotOn::Importer</importmodule>}, 'install.xml: the importer is the scanner module');
    like($xml, qr{<onlineLibrary>true</onlineLibrary>}, 'install.xml: SpotOn is an online library provider');

    open($fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $plugin = do { local $/; <$fh> };
    my ($pluginVersion) = $plugin =~ /use constant SPOTON_CACHE_VERSION\s*=>\s*(\d+)/;
    is($IMP->SPOTON_CACHE_VERSION, $pluginVersion, 'the scanner-side cache version mirrors Plugin.pm (shared cache)');
    unlike($plugin, qr/enable_PLUGIN_SPOTON_NAME\s*=>\s*0/, 'Plugin.pm: library import is not switched off by default (the Online Library plugin enables providers)');

    my ($needsUpdate) = $plugin =~ /(sub onlineLibraryNeedsUpdate \{.*?\n\})/s;
    ok($needsUpdate, 'Plugin.pm: onlineLibraryNeedsUpdate exists (makes SpotOn a listed provider)');
    unlike($needsUpdate // '', qr/SpClient|Pathfinder|SimpleAsyncHTTP|->get/, 'onlineLibraryNeedsUpdate sends no request (no background polling)');
    my $answer = eval "package NeedsUpdateProbe; $needsUpdate; my \$r = 'unset'; NeedsUpdateProbe->onlineLibraryNeedsUpdate(sub { \$r = shift }); \$r";
    is($answer, 0, 'onlineLibraryNeedsUpdate answers "no change" at once');
}

# ============================================================
# attribute mapping (pure)
# ============================================================
{
    my $rec = $IMP->_buildAlbumRecord(album_fixture($A1)->[0]);
    is($rec->{cover}, 'https://i.scdn.co/image/bb22', 'record: the widest cover');
    is($rec->{year}, 2001, 'record: year from release_date');
    ok(!$rec->{incomplete}, 'record: complete album');

    my @t = $IMP->_trackAttributes($rec, 1700000000);
    is(scalar @t, 2, 'attributes: one hash per track');
    is($t[0]{url}, "spoton://track:$T1", 'attributes: playable SpotOn url');
    is($t[0]{EXTID}, "spoton:track:$T1", 'attributes: spoton: track extid');
    is($t[0]{ALBUM_EXTID}, "spoton:album:$A1", 'attributes: spoton: album extid');
    is($t[0]{ARTIST}, 'Band', 'attributes: album artist is ARTIST');
    is($t[0]{ARTIST_EXTID}, 'spoton:artist:' . id22('x'), 'attributes: artist extid');
    ok(!exists $t[0]{TRACKARTIST}, 'attributes: no TRACKARTIST when the track artist is the album artist');
    is($t[1]{TRACKARTIST}, 'Band;Guest', 'attributes: guest artists as TRACKARTIST, joined by the split character');
    is($t[0]{SECS}, 61, 'attributes: duration in seconds');
    is($t[0]{TRACKNUM}, 1, 'attributes: track number');
    is($t[0]{TIMESTAMP}, 1700000000, 'attributes: added_at as TIMESTAMP');
    is($t[0]{RELEASETYPE}, 'Album', 'attributes: release type');
    ok(!exists $t[0]{DISC}, 'attributes: no DISC on a one-disc album');
    is($t[0]{CONTENT_TYPE}, 'soc', 'attributes: SpotOn content type');

    my $va = $IMP->_buildAlbumRecord(album_fixture($A2, type => 'compilation', artists => [ { id => id22('v'), name => 'Various Artists' } ],
        tracks => [ { id => $T3, name => 'Three', duration_ms => 1000, disc_number => 2, track_number => 1, artists => [ { id => id22('z'), name => 'Solo' } ] } ])->[0]);
    my ($c) = $IMP->_trackAttributes($va);
    is($c->{COMPILATION}, 1, 'compilation by Various Artists -> COMPILATION');
    is($c->{ARTIST}, 'Solo', 'compilation: the track artist is ARTIST');
    is_deeply([ @$c{qw(DISC DISCC)} ], [2, 2], 'multi-disc: DISC and DISCC');

    my $single = $IMP->_buildAlbumRecord(album_fixture($A3, type => 'single')->[0]);
    is(($IMP->_trackAttributes($single))[0]{RELEASETYPE}, 'Single', 'single -> Single');

    my $partial = $IMP->_buildAlbumRecord(album_fixture($A1, total => 5)->[0]);
    ok($partial->{incomplete}, 'record: fewer named tracks than the album has -> incomplete');

    is($IMP->can('_addedAt')->(1700000000123), 1700000000, '_addedAt: milliseconds are tolerated');
    ok(!defined $IMP->can('_addedAt')->('x'), '_addedAt: junk -> undef');
}

# ============================================================
# first scan: everything read once, records cached
# ============================================================
my %A = (saved => [ [ { uri => "spotify:album:$A1", added_at => 1700000000 }, { uri => "spotify:album:$A2", added_at => 1700000001 } ] ]);
{
    reset_world();
    Slim::Utils::Cache->new->clear;
    %Slim::Schema::tracks = ();
    %Slim::Schema::playlists = ();

    %Plugins::SpotOn::API::SpClient::answer = (
        %A,
        "albumids:$A1" => [ [ $T1, $T2 ] ],
        "albumids:$A2" => [ [ $T3 ] ],
        "album:$A1" => album_fixture($A1),
        "album:$A2" => album_fixture($A2, tracks => [ { id => $T3, name => 'Three', duration_ms => 1000, disc_number => 1, track_number => 1, artists => [] } ]),
        playlists   => [ { items => [ { id => $P1, name => 'Mix', revision => 'r1' }, { id => $P2, name => 'Old', revision => 'q1' } ] } ],
        "pltracks:$P1" => [ [ "spotify:track:$T1", "spotify:track:$T4" ] ],
        "pltracks:$P2" => [ [ "spotify:track:$T2" ] ],
        prefetch    => [ 3 ],
    );

    $IMP->startScan;

    is_deeply([ sort keys %Slim::Schema::tracks ], [ map { "spoton://track:$_" } sort ($T1, $T2, $T3) ], 'scan 1: every saved album track stored');
    is(scalar calls_of('album'), 2, 'scan 1: each album read once');
    is_deeply($Slim::Schema::playlists{"spoton://playlist:$P1"}{tracks}, [ "spoton://track:$T1", "spoton://track:$T4" ], 'scan 1: playlist tracks set');
    is($Slim::Schema::playlists{"spoton://playlist:$P1"}{attributes}{TITLE}, 'Spotify: Mix', 'scan 1: playlist title prefix');
    is($Slim::Schema::playlists{"spoton://playlist:$P1"}{attributes}{CONTENT_TYPE}, 'ssp', 'scan 1: playlist content type ssp');
    is_deeply([ @Plugins::SpotOn::API::SpClient::calls[0 .. 3] ], [ 'saved:acct1', "albumids:$A1", "albumids:$A2", 'prefetch:3' ],
        'scan 1: album layouts first, then the tracks of ALL new albums named in one batch');
    is_deeply([ calls_of('prefetch') ], [ 'prefetch:3', 'prefetch:3' ], 'scan 1: one batch for album tracks, one for playlist tracks');
    is(Slim::Networking::Async::HTTP->cookie_jar->{autosave}, 0, 'scan 1: the scanner gets a cookie jar that never writes the server\'s cookies.dat');
    is($Slim::Networking::Async::HTTP::inits, 1, 'scan 1: the jar is created once');
    is(scalar(@Slim::Utils::Timers::paced), scalar(@Plugins::SpotOn::API::SpClient::calls), 'scan 1: a pause after every call that reached the network');
    is_deeply(\@Slim::Music::Import::ended, [$IMP], 'scan 1: endImporter called');
    ok($Slim::Utils::Cache::store{"spoton_lib_album_$A1"}, 'scan 1: album record cached');
    cmp_ok($Slim::Utils::Cache::expiry{"spoton_lib_album_$A1"}, '>', time() + 29 * 86400, 'scan 1: record lives ~30+ days (absolute expiry)');
    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [], 'scan 1: nothing deleted');
}

# ============================================================
# second scan of an unchanged library: no album or playlist content request
# ============================================================
{
    reset_world();
    %Plugins::SpotOn::API::SpClient::answer = (
        %A,
        playlists => [ { items => [ { id => $P1, name => 'Mix', revision => 'r1' } ] } ],   # P2 unfollowed
        prefetch  => [ 2 ],
    );
    %Plugins::SpotOn::API::SpClient::cacheHit = (prefetch => 1);   # scan 1 named the playlist tracks
    $Slim::Utils::Log::infoOn = 1;

    $IMP->startScan;

    is(scalar calls_of('album'), 0, 'scan 2: known albums cost no request');
    is(scalar calls_of('albumids'), 0, 'scan 2: known albums need no layout');
    is($Slim::Networking::Async::HTTP::inits, 1, 'scan 2: an existing jar is kept');
    is(scalar calls_of('pltracks'), 0, 'scan 2: a playlist with the same revision costs no request');
    is(scalar(@Plugins::SpotOn::API::SpClient::calls), 3, 'scan 2: saved list + playlist list + one batched prefetch only');
    is(scalar keys %Slim::Schema::tracks, 3, 'scan 2: all tracks still there');
    ok($Slim::Schema::playlists{"spoton://playlist:$P1"}, 'scan 2: kept playlist stays');
    ok(!$Slim::Schema::playlists{"spoton://playlist:$P2"}, 'scan 2: a playlist no account lists any more is removed');
    my ($summary) = grep { /^Library import done:/ } @Slim::Utils::Log::infos;
    like($summary // '', qr/, Spotify requests: 2 \(albums 1, playlists 1\)$/,
        'scan 2: the summary line counts the Spotify requests per phase (saved list, playlist list)');
}

# ============================================================
# an album removed from Saved Albums goes; a changed playlist is re-read
# ============================================================
{
    reset_world();
    %Plugins::SpotOn::API::SpClient::answer = (
        saved     => [ [ { uri => "spotify:album:$A1", added_at => 1700000000 } ] ],
        playlists => [ { items => [ { id => $P1, name => 'Mix', revision => 'r2' } ] } ],
        "pltracks:$P1" => [ [ "spotify:track:$T4" ] ],
        prefetch  => [ 1 ],
    );

    $IMP->startScan;

    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [ "spoton://track:$T3" ], 'scan 3: the unsaved album\'s track is deleted');
    is(scalar calls_of('pltracks'), 1, 'scan 3: a new revision is read again');
    is_deeply($Slim::Schema::playlists{"spoton://playlist:$P1"}{tracks}, [ "spoton://track:$T4" ], 'scan 3: playlist updated');
}

# ============================================================
# rate limit: the first 429 stops all further requests, nothing unread is deleted
# ============================================================
{
    reset_world();
    Slim::Utils::Cache->new->remove("spoton_lib_album_$A1");
    %Slim::Schema::tracks = map { ("spoton://track:$_" => { ALBUM_EXTID => "spoton:album:$A1" }) } ($T1, $T2);
    %Plugins::SpotOn::API::SpClient::answer = (
        saved => [ [ { uri => "spotify:album:$A1" }, { uri => "spotify:album:$A2" } ] ],
        "albumids:$A1" => [ undef, { error => 'rate_limited', code => 429 } ],
        "album:$A2" => album_fixture($A2),
        playlists   => [ { items => [ { id => $P1, name => 'Mix', revision => 'r9' } ] } ],
    );
    $Slim::Schema::playlists{"spoton://playlist:$P1"} = { tracks => [ 'keep' ] };

    $IMP->startScan;

    is_deeply([ @Plugins::SpotOn::API::SpClient::calls ], [ 'saved:acct1', "albumids:$A1" ], '429: no request after the first 429 (A2 had a cached record, playlists not asked)');
    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [], '429: the unreadable album keeps its tracks');
    is_deeply($Slim::Schema::playlists{"spoton://playlist:$P1"}{tracks}, [ 'keep' ], '429: playlists keep their previous import');
    ok((grep { /no more Spotify requests/ } @Slim::Utils::Log::warnings), '429: logged once as a stop');
}

# ============================================================
# an active backoff (e.g. set by the server process) stops the run before any request
# ============================================================
{
    reset_world();
    $Plugins::SpotOn::API::SpClient::rateLimitedFor = 42;
    %Slim::Schema::tracks = map { ("spoton://track:$_" => {}) } ($T1, $T2);
    %Plugins::SpotOn::API::SpClient::answer = (%A);

    $IMP->startScan;

    is(scalar(@Plugins::SpotOn::API::SpClient::calls), 0, 'backoff: not a single request');
    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [], 'backoff: the unknown list keeps every SpotOn track');
}

# ============================================================
# a failed saved-albums list keeps everything; an empty list does not
# ============================================================
{
    reset_world();
    %Slim::Schema::tracks = map { ("spoton://track:$_" => {}) } ($T1);
    %Plugins::SpotOn::API::SpClient::answer = (saved => [ undef, { error => 'http_error', code => 500 } ], playlists => [ { items => [] } ]);
    $IMP->startScan;
    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [], 'list error: nothing deleted');

    reset_world();
    %Plugins::SpotOn::API::SpClient::answer = (saved => [ [] ], playlists => [ { items => [] } ]);
    $IMP->startScan;
    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [ "spoton://track:$T1" ], 'empty list: the tracks go (LMS\'s own empty-table guard is the base class\'s)');
}

# ============================================================
# playlist import switched off: the imported playlists are removed
# ============================================================
{
    reset_world();
    $Slim::Plugin::OnlineLibraryBase::ignorePlaylists = 1;
    $Slim::Schema::playlists{"spoton://playlist:$P1"} = { tracks => [] };
    %Plugins::SpotOn::API::SpClient::answer = (saved => [ [] ]);
    $IMP->startScan;
    is(scalar calls_of('playlists'), 0, 'playlists off: the playlist list is not read');
    ok(!$Slim::Schema::playlists{"spoton://playlist:$P1"}, 'playlists off: imported playlists removed');
}

# ============================================================
# an empty playlist list never removes the imported playlists -- the rule LMS applies to its online
# tracks (lms Slim/Plugin/OnlineLibraryBase.pm:86-90); switching the playlist import off still does (above)
# ============================================================
{
    reset_world();
    %Slim::Schema::playlists = ("spoton://playlist:$P1" => { tracks => [ "spoton://track:$T1" ] });
    %Plugins::SpotOn::API::SpClient::answer = (saved => [ [] ], playlists => [ { items => [] } ]);
    $IMP->startScan;
    ok($Slim::Schema::playlists{"spoton://playlist:$P1"}, 'empty playlist list: the imported playlist stays');
    is(scalar(grep { /no account lists a playlist any more/ } @Slim::Utils::Log::warnings), 1, 'empty playlist list: one warning');

    reset_world();
    %Plugins::SpotOn::API::SpClient::answer = (saved => [ [] ], playlists => [ { items => [ { id => 'not-an-id', name => 'Broken' } ] } ]);
    $IMP->startScan;
    ok($Slim::Schema::playlists{"spoton://playlist:$P1"}, 'a list without a usable playlist id counts as empty: the playlist stays');

    reset_world();
    %Slim::Schema::playlists = ();
    %Plugins::SpotOn::API::SpClient::answer = (saved => [ [] ], playlists => [ { items => [] } ]);
    $IMP->startScan;
    is(scalar(@Slim::Utils::Log::warnings), 0, 'no playlist imported and none listed: no warning');
}

# ============================================================
# track naming is split into trackBatchSize calls, one paced call each
# ============================================================
{
    reset_world();
    Slim::Utils::Cache->new->clear;
    %Slim::Schema::tracks = ();
    $Plugins::SpotOn::API::SpClient::batchSize = 2;
    %Plugins::SpotOn::API::SpClient::answer = (
        saved          => [ [ { uri => "spotify:album:$A1" }, { uri => "spotify:album:$A2" } ] ],
        "albumids:$A1" => [ [ $T1, $T2 ] ],
        "albumids:$A2" => [ [ $T3, $T1 ] ],
        "album:$A1"    => album_fixture($A1),
        "album:$A2"    => album_fixture($A2),
        prefetch       => sub { [ $_[0] ] },
    );
    $Slim::Plugin::OnlineLibraryBase::ignorePlaylists = 1;
    $IMP->startScan;
    is_deeply([ calls_of('prefetch') ], [ 'prefetch:2', 'prefetch:1' ], 'batching: 3 distinct ids in calls of trackBatchSize (2) -- duplicates named once');
}

# ============================================================
# an album that cannot be read (404) is asked once per scan and keeps its rows
# ============================================================
{
    reset_world();
    Slim::Utils::Cache->new->clear;
    %Slim::Schema::tracks = map { ("spoton://track:$_" => { ALBUM_EXTID => "spoton:album:$A3" }) } ($T4);
    %Plugins::SpotOn::API::SpClient::answer = (
        saved          => [ [ { uri => "spotify:album:$A3" } ] ],
        "albumids:$A3" => [ undef, { error => '404 Not Found', code => 404 } ],
    );
    $Slim::Plugin::OnlineLibraryBase::ignorePlaylists = 1;
    $IMP->startScan;
    is_deeply([ @Plugins::SpotOn::API::SpClient::calls ], [ 'saved:acct1', "albumids:$A3" ], 'unreadable album: one request, no second try in the same scan');
    is_deeply($Slim::Plugin::OnlineLibraryBase::deleted, [], 'unreadable album: its tracks stay');
}

# ============================================================
# a playlist that answers 404 is not asked again until its revision changes
# ============================================================
{
    reset_world();
    my %pl404 = (
        saved     => [ [] ],
        playlists => [ { items => [ { id => $P2, name => 'Made for you', revision => 'm1' } ] } ],
        "pltracks:$P2" => [ undef, { error => '404 Not Found', code => 404 } ],
    );
    %Plugins::SpotOn::API::SpClient::answer = %pl404;
    $IMP->startScan;
    is(scalar calls_of('pltracks'), 1, '404: asked once');
    ok(!$Slim::Schema::playlists{"spoton://playlist:$P2"}, '404: not stored');

    reset_world();
    %Plugins::SpotOn::API::SpClient::answer = %pl404;
    $IMP->startScan;
    is(scalar calls_of('pltracks'), 0, '404: same revision -> not asked again');

    reset_world();
    %Plugins::SpotOn::API::SpClient::answer = (%pl404, playlists => [ { items => [ { id => $P2, name => 'Made for you', revision => 'm2' } ] } ]);
    $IMP->startScan;
    is(scalar calls_of('pltracks'), 1, '404: a new revision is tried again');
}

done_testing();
