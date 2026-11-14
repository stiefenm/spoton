package Plugins::SpotOn::Importer;

# LMS online library integration (GH #32): imports the paired accounts' Saved
# Albums as library albums and their playlists as LMS playlists, so Spotify
# content shows up in "My Music", in the unified search and in the "Music
# without online duplicates" view of the Online Music Library plugin.
#
# Loaded by the scanner through install.xml <importmodule>; the server never
# runs startScan. The import follows the quota rules of #32:
#   * lazy: it runs only inside the scans scanner.pl runs: a rescan,
#     "Clear library and rescan everything", "rescan playlists" (playlists
#     only) and "rescan onlinelibrary". A single-folder scan does not
#     register it (OnlineLibraryBase::initPlugin). Plugin.pm's
#     onlineLibraryNeedsUpdate answers "no change" without a request, so the
#     Online Library plugin's hourly poll costs nothing and SpotOn's answer
#     never starts a scan;
#   * incremental and cache-driven: an imported album is kept as a record in
#     the SpotOn cache (ALBUM_RECORD_DAYS plus a per-album spread), a playlist
#     as its track list keyed on the playlist revision (PLAYLIST_RECORD_DAYS),
#     and track names come from SpClient's 90-day per-track cache that Browse
#     fills too. A rescan of an unchanged library costs one collection/v2
#     page per 200 items of the collection (Saved Albums share it with Liked
#     Songs) plus one rootlist request per account. A first import reads each
#     new album's layout once and names the tracks of all new albums
#     together, 200 per request;
#   * gentle: one SpClient call at a time, REQUEST_SPACING seconds after
#     every call that went to the network, and the first 429 (or an active
#     backoff from the server process -- the rate key lives in the shared
#     cache) stops the network part of the run. Whatever could not be read
#     keeps its rows from the previous import; nothing is deleted on a
#     partial read, and when no account lists a playlist, the imported
#     playlists stay (the rule LMS applies to its online tracks).
#
# Spotify ids stay public base62 ids. Track urls are SpotOn's playable
# spoton://track:<id> form; the external ids use the "spoton:" prefix the
# Online Library plugin derives from trackUriPrefix (library stats, service
# emblem), so SpotOn rows never collide with Spotty's "spotify:" rows.

use strict;
use warnings;

# can't `use base`: the base class only exists when the Online Library plugin is installed (LMS 8+)
BEGIN {
    eval {
        require Slim::Plugin::OnlineLibraryBase;
        our @ISA = qw(Slim::Plugin::OnlineLibraryBase);
    };
}

# The scanner loads this module without Plugin.pm, but every SpotOn module that
# opens the shared cache reads its version from Plugin.pm (M5). Mirror the
# value for the scanner only; t/core/80_library_importer.t keeps it equal to
# Plugin.pm's.
use constant SPOTON_CACHE_VERSION => 4;
BEGIN {
    no strict 'refs';
    *{'Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION'} = \&SPOTON_CACHE_VERSION
        unless defined &{'Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION'};
}

use Digest::MD5 qw(md5);
use List::Util qw(max);
use Time::HiRes;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use constant TRACK_URL_PREFIX    => 'spoton://track:';
use constant PLAYLIST_URL_PREFIX => 'spoton://playlist:';
use constant EXTID_PREFIX        => 'spoton:';
use constant PLAYLIST_PREFIX     => 'Spotify: ';      # Spotty's convention, LMS users know it
use constant GENRE               => 'Spotify';        # ditto; an Online Library genre mapping adds its genre next to it
use constant CONTENT_TYPE        => 'soc';            # ProtocolHandler->getFormatForURL; formatOverride decides at play time

use constant ALBUM_RECORD_DAYS    => 30;   # an imported album is re-read after 30..39 days
use constant ALBUM_RECORD_SPREAD  => 10;   # days, per album -- the records do not expire on the same scan
use constant INCOMPLETE_DAYS      => 1;    # an album with unnamed tracks is retried on the next day's scan
use constant PLAYLIST_RECORD_DAYS => 30;   # a playlist whose revision did not change is not read again within 30 days
use constant RECORD_FORMAT        => 1;
use constant REQUEST_SPACING      => 0.25; # seconds after a call that reached the network
use constant AWAIT_TIMEOUT        => 180;  # seconds for one SpClient call (it can hold several requests)

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', SPOTON_CACHE_VERSION);

sub initPlugin {
    my $class = shift;

    return unless $class->can('isImportEnabled');   # no Online Library plugin (LMS < 8)
    return $class->SUPER::initPlugin(@_);
}

sub trackUriPrefix { TRACK_URL_PREFIX }

# ============================================================
# Scan entry point (scanner process)
# ============================================================

sub startScan { if (main::SCANNER) {
    my $class = shift;

    $class->_prepareAsyncHTTP;
    require Plugins::SpotOn::API::SpClient;

    my @accounts = $class->_accounts;
    if (@accounts) {
        $class->initOnlineTracksTable();

        my $run = { accounts => scalar @accounts };

        # The Spotify requests of each phase go into the summary line, so the cost of a scan can be read
        # from scanner.log without counting request lines. SpClient's requestCount counts the spclient
        # dispatches of this process: cache hits and the rate-limit short-circuit are not counted.
        my $atStart = Plugins::SpotOn::API::SpClient->requestCount;

        if (!Slim::Music::Import->scanPlaylistsOnly()) {
            $class->scanAlbums(\@accounts, $run);
        }

        my $afterAlbums = Plugins::SpotOn::API::SpClient->requestCount;

        if (!($class->can('ignorePlaylists') && $class->ignorePlaylists)) {
            $class->scanPlaylists(\@accounts, $run);
        }
        else {
            $class->_deleteStalePlaylists({});   # playlist import switched off: remove the imported ones
        }

        my $atEnd = Plugins::SpotOn::API::SpClient->requestCount;

        $class->deleteRemovedTracks();

        main::INFOLOG && $log->is_info && $log->info(sprintf(
            'Library import done: %d albums (%d read from Spotify), %d playlists (%d read), '
                . 'Spotify requests: %d (albums %d, playlists %d)%s',
            $run->{albums} || 0, $run->{albumsRead} || 0, $run->{playlists} || 0, $run->{playlistsRead} || 0,
            $atEnd - $atStart, $afterAlbums - $atStart, $atEnd - $afterAlbums,
            $run->{stopped} ? " -- stopped early ($run->{stopped}), the rest keeps its previous import" : ''));
    }
    else {
        main::INFOLOG && $log->is_info && $log->info('Library import: no paired account with stored credentials');
    }

    Slim::Music::Import->endImporter($class);
} }

# _prepareAsyncHTTP($class) -- SpClient talks through LMS's async HTTP stack,
# which the scanner loads but never initialises:
#   * Slim::Networking::Async calls Slim::Utils::Network, loaded only by the
#     server;
#   * Slim::Networking::Async::HTTP skips the cookie header in the scanner
#     (`if (!main::SCANNER)`), but still extracts response cookies into the
#     jar its init() creates -- undefined in the scanner, so every response
#     dies there. The scanner gets the jar with autosave off: it reads the
#     server's cookies.dat once and never writes it.
sub _prepareAsyncHTTP {
    require Slim::Utils::Network;
    require Slim::Networking::Async::HTTP;

    return if Slim::Networking::Async::HTTP->cookie_jar;

    Slim::Networking::Async::HTTP::init();
    if (my $jar = Slim::Networking::Async::HTTP->cookie_jar) {
        $jar->{autosave} = 0;   # HTTP::Cookies saves on DESTROY only when this is set
    }
}

# _accounts($class) -> the account ids with login5-capable stored credentials
# (the accounts every spclient call needs, SpClient::_hasLogin5Creds).
sub _accounts {
    my ($class) = @_;
    require Plugins::SpotOn::API::Credentials;
    my $accounts = $prefs->get('accounts') || {};
    return grep { Plugins::SpotOn::API::Credentials->verifyCredentials($_) }
           sort keys %{ ref $accounts eq 'HASH' ? $accounts : {} };
}

# ============================================================
# Saved Albums
# ============================================================

sub scanAlbums { if (main::SCANNER) {
    my ($class, $accounts, $run) = @_;

    my $progress = Slim::Utils::Progress->new({
        type  => 'importer',
        name  => 'plugin_spoton_albums',
        total => scalar @$accounts,
        every => 1,
    });

    for my $accountId (@$accounts) {
        my $accountTag = $run->{accounts} > 1 ? EXTID_PREFIX . "account:$accountId" : undef;

        $progress->update(string('PLUGIN_SPOTON_PROGRESS_READ_ALBUMS'));

        my ($saved, $err) = $run->{stopped} ? (undef, { error => $run->{stopped} })
                                            : $class->_call(sub {
            Plugins::SpotOn::API::SpClient->getSavedAlbumUris($accountId, $_[0]);
        });

        unless ($saved) {
            $class->_noteError($run, $err, 'Saved Albums list');
            # the list is unknown: every SpotOn track survives this scan
            $class->_keepTracks(q{url LIKE ?}, TRACK_URL_PREFIX . '%');
            next;
        }

        $progress->total($progress->total + scalar @$saved);

        $class->_warmAlbums($accountId, [ map { $_->{uri} =~ /^spotify:album:(.+)$/ ? $1 : () } @$saved ], $run);

        for my $item (@$saved) {
            my ($albumId) = $item->{uri} =~ /^spotify:album:(.+)$/;
            my $record = $class->_albumRecord($accountId, $albumId, $run);

            unless ($record) {
                $class->_keepTracks(q{album IN (SELECT id FROM albums WHERE extid = ?)}, EXTID_PREFIX . "album:$albumId");
                next;
            }

            $progress->update($record->{name});
            main::SCANNER && Slim::Schema->forceCommit;

            $class->storeTracks([ $class->_trackAttributes($record, _addedAt($item->{added_at})) ], undef, $accountTag);
            $run->{albums}++;
        }

        main::SCANNER && Slim::Schema->forceCommit;
    }

    $progress->final;
    main::SCANNER && Slim::Schema->forceCommit;
} }

# _warmAlbums($class, $accountId, \@albumIds, $run) -- for the albums that
# have no record yet: reads each album's track layout (one metadata/4/album
# request, kept in SpClient's response cache), then names all their tracks
# in batches of trackBatchSize ACROSS albums. _albumRecord's
# getAlbumWithTracks then finds both in the caches. A first import of N
# albums with T tracks costs N + ceil(T / 200) requests instead of 2 N.
sub _warmAlbums {
    my ($class, $accountId, $albumIds, $run) = @_;

    my @trackIds;
    for my $albumId (@$albumIds) {
        last if $run->{stopped};
        next if $class->_cachedAlbumRecord($albumId);

        my ($ids, $err) = $class->_call(sub {
            Plugins::SpotOn::API::SpClient->getAlbumTrackIds($accountId, $albumId, $_[0]);
        });
        if ($ids) {
            push @trackIds, @$ids;
        }
        else {
            $class->_noteError($run, $err, "album $albumId");
            $run->{unreadable}{$albumId} = 1;   # not asked a second time in this scan
        }
    }

    $class->_prefetch($accountId, \@trackIds, $run, 'album track names');
}

# _prefetch($class, $accountId, \@trackIds, $run, $what) -- names tracks into
# SpClient's per-track cache, one paced call per trackBatchSize ids (so one
# request per call at most; cached tracks cost nothing).
sub _prefetch {
    my ($class, $accountId, $trackIds, $run, $what) = @_;

    my %seen;
    my @ids  = grep { !$seen{$_}++ } @$trackIds;
    my $size = Plugins::SpotOn::API::SpClient->can('trackBatchSize')
        ? Plugins::SpotOn::API::SpClient->trackBatchSize : 200;

    while (@ids && !$run->{stopped}) {
        my @chunk = splice(@ids, 0, $size);
        my (undef, $err) = $class->_call(sub {
            Plugins::SpotOn::API::SpClient->prefetchTracks($accountId, \@chunk, $_[0]);
        });
        $class->_noteError($run, $err, $what) if $err;
        # a batch that failed for a rate limit leaves its tracks unnamed; rateLimitedFor stops the run
        $class->_noteError($run, { error => 'rate_limited_local' }, $what)
            if Plugins::SpotOn::API::SpClient->rateLimitedFor > 0;
    }
}

sub _cachedAlbumRecord {
    my ($class, $albumId) = @_;
    my $record = $cache->get("spoton_lib_album_$albumId");
    return (ref $record eq 'HASH' && ($record->{_fmt} || 0) == RECORD_FORMAT) ? $record : undef;
}

# _albumRecord($class, $accountId, $albumId, $run) -> the cached album record,
# or a freshly read one (then cached), or undef when it cannot be read now.
sub _albumRecord {
    my ($class, $accountId, $albumId, $run) = @_;

    my $key    = "spoton_lib_album_$albumId";
    my $record = $class->_cachedAlbumRecord($albumId);
    return $record if $record;

    return undef if $run->{stopped} || $run->{unreadable}{$albumId};

    my ($album, $err) = $class->_call(sub {
        Plugins::SpotOn::API::SpClient->getAlbumWithTracks($accountId, $albumId, $_[0]);
    });

    unless ($album && $album->{tracks} && @{ $album->{tracks}{items} || [] }) {
        $class->_noteError($run, $err || { error => 'no_tracks' }, "album $albumId");
        return undef;
    }
    $run->{albumsRead}++;

    $record = $class->_buildAlbumRecord($album);
    my $days = $record->{incomplete}
        ? INCOMPLETE_DAYS
        : ALBUM_RECORD_DAYS + (unpack('N', md5($albumId)) % ALBUM_RECORD_SPREAD);
    $cache->set($key, $record, time() + $days * 86400);   # absolute expiry (DbCache reads > 30 days as a timestamp)

    return $record;
}

# _buildAlbumRecord($class, $album) -> the compact album record the cache
# keeps: only what _trackAttributes needs. Pure, unit-tested.
sub _buildAlbumRecord {
    my ($class, $album) = @_;

    my @tracks = map { +{
        id      => $_->{id},
        name    => $_->{name},
        ms      => $_->{duration_ms},
        disc    => $_->{disc_number} || 1,
        num     => $_->{track_number},
        artists => [ map { +{ id => $_->{id}, name => $_->{name} } } grep { $_->{name} } @{ $_->{artists} || [] } ],
    } } grep { $_->{id} } @{ $album->{tracks}{items} || [] };

    my $total = $album->{tracks}{total} || $album->{total_tracks} || scalar @tracks;

    return {
        _fmt       => RECORD_FORMAT,
        id         => $album->{id},
        name       => $album->{name},
        artists    => [ map { +{ id => $_->{id}, name => $_->{name} } } grep { $_->{name} } @{ $album->{artists} || [] } ],
        year       => (($album->{release_date} // '') =~ /^(\d{4})/ && $1 > 0) ? $1 : undef,
        type       => $album->{album_type} || '',
        cover      => _largestImage($album->{images}),
        discs      => max(1, map { $_->{disc} } @tracks),
        total      => $total,
        incomplete => (@tracks < $total) ? 1 : 0,
        tracks     => \@tracks,
    };
}

# _trackAttributes($class, $record, $addedAt) -> the storeTracks attribute
# hashes of one album record. Album artists are ARTIST (the album is filed
# under them), a track's own artists are TRACKARTIST when they differ. A
# compilation by several artists (or by "Various Artists") is a COMPILATION
# with the track artists as ARTIST. Pure, unit-tested.
sub _trackAttributes {
    my ($class, $record, $addedAt) = @_;

    my $split = substr(preferences('server')->get('splitList') // '', 0, 1);
    my $join  = sub {
        my ($list, $field) = @_;
        my @v = map { $_->{$field} } @$list;
        return length $split ? join($split, @v) : $v[0];
    };
    my $extids = sub { [ map { +{ %$_, id => EXTID_PREFIX . "artist:$_->{id}" } } grep { $_->{id} } @{ $_[0] } ] };

    my @albumArtists  = @{ $record->{artists} || [] };
    my $isCompilation = $record->{type} eq 'compilation'
        && (@albumArtists > 1 || grep { lc($_->{name}) eq 'various artists' } @albumArtists) ? 1 : 0;

    my $releaseType = { single => 'Single', ep => 'EP' }->{ $record->{type} } || 'Album';

    my @out;
    for my $t (@{ $record->{tracks} || [] }) {
        my @trackArtists = @{ $t->{artists} || [] };
        @trackArtists = @albumArtists unless @trackArtists;
        my @primary = $isCompilation ? @trackArtists : (@albumArtists ? @albumArtists : @trackArtists);

        my %attr = (
            url          => TRACK_URL_PREFIX . $t->{id},
            EXTID        => EXTID_PREFIX . "track:$t->{id}",
            TITLE        => $t->{name},
            ARTIST       => $join->(\@primary, 'name'),
            ALBUM        => $record->{name},
            ALBUM_EXTID  => EXTID_PREFIX . "album:$record->{id}",
            TRACKNUM     => $t->{num},
            SECS         => defined $t->{ms} ? $t->{ms} / 1000 : undef,
            COVER        => $record->{cover} || undef,
            GENRE        => GENRE,
            RELEASETYPE  => $releaseType,
            AUDIO        => 1,
            CONTENT_TYPE => CONTENT_TYPE,
        );

        my $primaryExtids = $extids->(\@primary);
        $attr{ARTIST_EXTID} = $join->($primaryExtids, 'id') if @$primaryExtids == @primary;

        my $trackArtistNames = $join->(\@trackArtists, 'name');
        $attr{TRACKARTIST}  = $trackArtistNames if !$isCompilation && $trackArtistNames ne ($attr{ARTIST} // '');
        $attr{COMPILATION}  = 1 if $isCompilation;
        $attr{YEAR}         = $record->{year} if $record->{year};
        $attr{TIMESTAMP}    = $addedAt if $addedAt;
        if ($record->{discs} > 1) {
            $attr{DISC}  = $t->{disc};
            $attr{DISCC} = $record->{discs};
        }

        delete $attr{$_} for grep { !defined $attr{$_} } keys %attr;
        push @out, \%attr;
    }

    return @out;
}

# ============================================================
# Playlists
# ============================================================

sub scanPlaylists { if (main::SCANNER) {
    my ($class, $accounts, $run) = @_;

    my $progress = Slim::Utils::Progress->new({
        type  => 'importer',
        name  => 'plugin_spoton_playlists',
        total => scalar @$accounts,
        every => 1,
    });

    my %keep;          # playlist url => 1: stays in the library
    my $complete = 1;  # every account's playlist list was read -> stale playlists may go

    for my $accountId (@$accounts) {
        $progress->update(string('PLUGIN_SPOTON_PROGRESS_READ_PLAYLISTS'));

        my ($list, $err) = $run->{stopped} ? (undef, { error => $run->{stopped} })
                                           : $class->_call(sub {
            Plugins::SpotOn::API::SpClient->getPlaylistIndex($accountId, $_[0]);
        });

        unless (ref $list eq 'ARRAY') {
            $class->_noteError($run, $err, 'playlist list');
            $complete = 0;
            next;
        }

        my @playlists = grep { $_->{id} && $_->{id} =~ /^[0-9A-Za-z]{22}$/ } @$list;
        $progress->total($progress->total + scalar @playlists);

        my (@toStore, %prefetch);
        for my $pl (@playlists) {
            my $url = PLAYLIST_URL_PREFIX . $pl->{id};
            next if $keep{$url};   # already stored for another account
            $keep{$url} = 1;

            my $trackIds = $class->_playlistTrackIds($accountId, $pl, $run);
            next unless $trackIds;   # not readable now: the playlist keeps its previous tracks

            push @toStore, [ $pl, $trackIds ];
            $prefetch{$_} = 1 for @$trackIds;
        }

        # Name the playlist tracks into the per-track cache in batches (cache hits cost nothing), so an
        # imported playlist opened later needs no metadata request per track.
        if (%prefetch) {
            $progress->update(string('PLUGIN_SPOTON_PROGRESS_READ_TRACKS'));
            $class->_prefetch($accountId, [ sort keys %prefetch ], $run, 'playlist track names');
        }

        for my $entry (@toStore) {
            my ($pl, $trackIds) = @$entry;
            $progress->update($pl->{name});
            $class->_storePlaylist($pl, $trackIds);
            $run->{playlists}++;
            Slim::Schema->forceCommit;
        }
    }

    # LMS keeps the online tracks when a scan finds none but the library had some ("most likely due to
    # some failure", OnlineLibraryBase::deleteRemovedTracks). Same rule for the playlists: _parseRootlist
    # answers [] for a rootlist without a usable list (an empty 200 body is one), and that must not remove
    # every imported playlist. Someone who really unfollowed every playlist keeps the rows until "Don't
    # import playlists" or "Clear library and rescan everything". The playlist rows do not record the
    # account, so the rule is for all accounts together.
    if ($complete && !%keep && $class->_hasImportedPlaylists) {
        $log->warn('Library import: no account lists a playlist any more, but SpotOn playlists are imported -- '
            . 'keeping them (most likely a failed read)');
        $complete = 0;
    }

    $class->_deleteStalePlaylists(\%keep) if $complete;

    $progress->final;
    Slim::Schema->forceCommit;
} }

# _playlistTrackIds($class, $accountId, $playlist, $run) -> [track ids] from
# the record of the same revision, or freshly read (then recorded), or undef.
sub _playlistTrackIds {
    my ($class, $accountId, $pl, $run) = @_;

    my $key    = "spoton_lib_playlist_${accountId}_$pl->{id}";
    my $record = $cache->get($key);
    if (ref $record eq 'HASH' && ($record->{_fmt} || 0) == RECORD_FORMAT
        && defined $pl->{revision} && defined $record->{revision} && $record->{revision} eq $pl->{revision})
    {
        return $record->{notFound} ? undef : $record->{tracks};
    }

    return undef if $run->{stopped};

    my ($uris, $err) = $class->_call(sub {
        Plugins::SpotOn::API::SpClient->getPlaylistTrackUris($accountId, $pl->{id}, $_[0]);
    });

    unless ($uris) {
        $class->_noteError($run, $err, "playlist $pl->{id}");
        # Some Spotify-made playlists in the rootlist answer 404 on playlist/v2. Remember that for the
        # revision, so every rescan does not ask again; a new revision is tried once more.
        if (ref $err eq 'HASH' && ($err->{code} // 0) == 404 && defined $pl->{revision}) {
            $cache->set($key, { _fmt => RECORD_FORMAT, revision => $pl->{revision}, notFound => 1 },
                time() + PLAYLIST_RECORD_DAYS * 86400);
        }
        return undef;
    }
    $run->{playlistsRead}++;

    my @ids = map { /^spotify:track:(.+)$/ ? $1 : () } @$uris;
    $cache->set($key, { _fmt => RECORD_FORMAT, revision => $pl->{revision}, tracks => \@ids },
        time() + PLAYLIST_RECORD_DAYS * 86400) if defined $pl->{revision};

    return \@ids;
}

sub _storePlaylist {
    my ($class, $pl, $trackIds) = @_;

    my $playlistObj = Slim::Schema->updateOrCreate({
        url             => PLAYLIST_URL_PREFIX . $pl->{id},
        playlist        => 1,
        integrateRemote => 1,
        attributes      => {
            TITLE        => PLAYLIST_PREFIX . (length($pl->{name} // '') ? $pl->{name} : $pl->{id}),
            AUDIO        => 1,
            EXTID        => EXTID_PREFIX . "playlist:$pl->{id}",
            CONTENT_TYPE => 'ssp',
        },
    }) or return;

    $playlistObj->setTracks([ map { TRACK_URL_PREFIX . $_ } @$trackIds ]);
}

# _hasImportedPlaylists($class) -> 1 when the library holds an imported
# SpotOn playlist.
sub _hasImportedPlaylists {
    my ($class) = @_;
    my ($found) = Slim::Schema->dbh->selectrow_array(
        q{SELECT 1 FROM tracks WHERE url LIKE ? LIMIT 1}, undef, PLAYLIST_URL_PREFIX . '%');
    return $found ? 1 : 0;
}

# _deleteStalePlaylists($class, \%keep) -- removes imported playlists that no
# account lists any more. Deleting the tracks row cascades to playlist_track
# (PRAGMA foreign_keys = ON). Runs only after every playlist list was read.
sub _deleteStalePlaylists {
    my ($class, $keep) = @_;

    my $dbh  = Slim::Schema->dbh;
    my $rows = $dbh->selectall_arrayref(q{SELECT id, url FROM tracks WHERE url LIKE ?}, undef, PLAYLIST_URL_PREFIX . '%') || [];
    my $sth  = $dbh->prepare_cached(q{DELETE FROM tracks WHERE id = ?});

    for my $row (@$rows) {
        next if $keep->{ $row->[1] };
        main::INFOLOG && $log->is_info && $log->info("Library import: removing playlist $row->[1]");
        $sth->execute($row->[0]);
    }
}

# ============================================================
# Helpers
# ============================================================

# _keepTracks($class, $where, @bind) -- marks the SpotOn tracks matching
# $where as still present, so deleteRemovedTracks leaves them alone when
# their album (or the whole list) could not be read in this scan.
sub _keepTracks {
    my ($class, $where, @bind) = @_;
    return if $main::wipe;   # a wipe scan has no previous rows and no online_tracks table
    Slim::Schema->dbh->do(
        qq{INSERT OR IGNORE INTO online_tracks (url) SELECT url FROM tracks WHERE url LIKE '${\ TRACK_URL_PREFIX}%' AND $where},
        undef, @bind,
    );
}

# _noteError($class, $run, $err, $what) -- logs a failed read. A rate limit,
# an active backoff or an account that cannot authenticate stops the network
# part of the run: the remaining albums and playlists keep their previous
# import and the next scan continues.
sub _noteError {
    my ($class, $run, $err, $what) = @_;

    my $code  = (ref $err eq 'HASH' && defined $err->{error}) ? $err->{error} : 'unknown';
    my $stops = $code =~ /^(?:rate_limited|rate_limited_local|unauthorized|no_token|invalid_credentials|mint_failed|timeout)$/
        || (ref $err eq 'HASH' && ($err->{code} // 0) == 429)
        || Plugins::SpotOn::API::SpClient->rateLimitedFor > 0;

    if ($stops && !$run->{stopped}) {
        $run->{stopped} = $code;
        $log->warn("Library import: $what failed ($code) -- no more Spotify requests in this scan, "
            . 'the rest of the library keeps its previous import');
    }
    elsif (!$stops) {
        $log->warn("Library import: $what failed ($code)");
    }
}

# _call($class, $start) -> the callback arguments of one SpClient call.
# The scanner has no event loop: this runs LMS's EV loop until the call has
# answered (sockets and Slim::Utils::Timers are EV watchers), bounded by
# AWAIT_TIMEOUT, and paces after a call that reached the network.
sub _call {
    my ($class, $start) = @_;

    if (my $left = Plugins::SpotOn::API::SpClient->rateLimitedFor) {
        return (undef, { error => 'rate_limited_local', code => 429 });
    }

    my $before = Plugins::SpotOn::API::SpClient->requestCount;
    my @result = $class->_await($start, AWAIT_TIMEOUT);
    if (Plugins::SpotOn::API::SpClient->requestCount > $before) {
        $class->_await(sub { my $done = shift; Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + REQUEST_SPACING, sub { $done->() }) }, 5);
    }

    return @result;
}

sub _await {
    my ($class, $start, $timeout) = @_;

    my ($done, @result);
    $start->(sub { @result = @_; $done = 1 });
    return @result if $done;   # answered from a cache

    require EV;

    # a periodic no-op watcher keeps EV::run(RUN_ONCE) from spinning when nothing else is pending
    my $tick     = EV::timer(0.2, 0.2, sub { });
    my $deadline = Time::HiRes::time() + $timeout;
    while (!$done) {
        if (Time::HiRes::time() > $deadline) {
            $log->warn("Library import: no answer within ${timeout}s");
            return (undef, { error => 'timeout' });
        }
        EV::run(EV::RUN_ONCE());
    }

    return @result;
}

# collection/v2 added_at: seconds since the epoch (milliseconds are tolerated)
sub _addedAt {
    my ($v) = @_;
    return undef unless defined $v && !ref $v && $v =~ /\A\d+\z/ && $v > 0;
    return $v > 100_000_000_000 ? int($v / 1000) : $v + 0;
}

sub _largestImage {
    my ($images) = @_;
    return '' unless ref $images eq 'ARRAY' && @$images;
    my ($largest) = sort { ($b->{width} || 0) <=> ($a->{width} || 0) } @$images;
    return ($largest && $largest->{url} && $largest->{url} =~ m{/image/[0-9a-f]+\z}) ? $largest->{url} : '';
}

1;
