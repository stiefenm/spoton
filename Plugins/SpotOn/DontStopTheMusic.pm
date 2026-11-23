package Plugins::SpotOn::DontStopTheMusic;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);
use List::Util qw(min);
use Time::HiRes;

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('plugin.spoton');   # 90.1-06 FINDING_FOR_06: a function, not a method (Log.pm 281-284)
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

use constant DSTM_MAX_TRACKS       => 10;
use constant DSTM_POOL_INJECT      => 3;
use constant DSTM_SEARCH_STAGGER_S => 0.2;
use constant DSTM_POOL_TTL         => 1800;
use constant DSTM_RECENT_TTL       => 86400;
use constant DSTM_RECENT_MAX       => 30;
use constant DSTM_TAG_TTL          => 604800;

sub init {
    Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
        'PLUGIN_SPOTON_RECOMMENDATIONS',
        \&dontStopTheMusic
    );
}

# connectSessionActive($client) -> 1 while the Spotify app controls this
# player through a Soloist Connect session (the role's state mode is
# 'connect'), else 0. 90.1-06 / GH #234 / D-13: both layers rest on it,
# SpotOn's own provider (no recommendations then) and Plugin->disableDSTM
# (LMS's conflict hook, DSTM arms no timer then). The librespot role
# answers mode undef and so never counts. Eval-guarded (T-90.1-14): any
# failure answers 0, so a broken role can never switch DSTM off for good.
# 90.1 review WR-04: the mode alone is not enough. A foreign title started
# from LMS leaves connect in Connect.pm's _onNewSong, and DSTM's own
# `playlist newsong` listener may run before it (LMS calls the listeners in
# hash order). So the app does not control the player while LMS's current
# song (the playing one, else the streaming one) is not a spoton:// url; no
# song at all keeps the mode's answer.
sub connectSessionActive {
    my ($client) = @_;
    return 0 unless $client;
    my $active = eval {
        require Plugins::SpotOn::Unified::DaemonManager;
        my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
        return 0 unless $be && (($be->state || {})->{mode} // '') eq 'connect';
        my $song = ($client->can('playingSong') && $client->playingSong)
                || ($client->can('streamingSong') && $client->streamingSong);
        my $track = ($song && ref($song) && $song->can('track')) ? $song->track : undef;
        my $url   = ($track && ref($track) && $track->can('url')) ? ($track->url // '') : '';
        (length $url && $url !~ m{^spoton://}) ? 0 : 1;
    };
    return $active ? 1 : 0;
}

sub _dstmTagKey {
    my ($artist, $title) = @_;
    return 'spoton_dstm_tag_' . md5_hex(encode_utf8(lc($artist // '') . '|' . lc($title // '')));
}

sub dontStopTheMusic {
    my ($client, $cb) = @_;

    # 90.1-06 / GH #234, D-13 layer 1: while the Spotify app controls this
    # player through a Soloist Connect session, recommend nothing and do no
    # work (not even read the seeds). Plugin->disableDSTM normally keeps DSTM
    # from calling here at all, and since the 90.1 review (WR-03) the claim
    # bind of every session entry kills a DSTM timer armed before the session
    # (Connect.pm bindConnectClaim), so this is the last line, not the main
    # one. Note what an empty answer means to LMS: with RandomPlay enabled
    # (its default) and another DSTM provider than RandomPlay, LMS's DSTM
    # appends `randomplay://track` instead (DSTM Plugin.pm, the branch after
    # the track branch). Not calling $cb is no way out either: DSTM's
    # pluginData('active') would stay set and DSTM would be dead for the
    # player. D-14 accepts an appended entry; nothing is deleted.
    if (connectSessionActive($client)) {
        main::INFOLOG && $log->info('DSTM: no recommendations while the Spotify app controls ' . $client->id . ' (D-13)');
        $cb->($client);
        return;
    }

    my $seedTracks =Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 20);

    if (!$seedTracks || !ref $seedTracks || !scalar @$seedTracks) {
        $cb->($client);
        return;
    }

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';
    unless ($accountId) {
        $cb->($client);
        return;
    }

    require Plugins::SpotOn::API::SpClient;

    # Build seed exclusion set from current playlist (D3: prevent self-queueing)
    my %seedExclude;
    foreach my $track (@$seedTracks) {
        next unless $track->{artist} && $track->{title};
        $seedExclude{_dstmTagKey($track->{artist}, $track->{title})} = 1;
    }

    # D4: extract first artist name, handling "Tyler, The Creator" etc.
    # by checking if the full joined string itself is a single artist
    # (i.e. no actual multi-artist separator). Heuristic: if the track
    # has artist metadata with a single name matching the full string, use it.
    my (@seedArtists, %seen);
    foreach my $track (@$seedTracks) {
        next unless $track->{artist};
        next if $cache->get(_dstmTagKey($track->{artist}, $track->{title}));
        my $artistName = $track->{artist};
        # The joined string has " — Artist" appended by LMS getMixableProperties
        # from the title field. The raw artist is before any " — ".
        # However, getMixableProperties provides {artist} directly, already joined.
        # Split only when we see the pattern "Name1, Name2" where Name2 starts
        # with uppercase (multi-artist), not "Tyler, The Creator" patterns.
        if ($artistName =~ /^([^,]+),\s+([a-z])/) {
            # Lowercase after comma: likely part of one name (e.g. "Tyler, The Creator")
            # keep full name
        } elsif ($artistName =~ /^([^,]+),/) {
            $artistName = $1;
        }
        next unless $artistName && !$seen{lc $artistName}++;
        push @seedArtists, $artistName;
    }

    _shuffle(\@seedArtists);
    splice @seedArtists, 3 if @seedArtists > 3;

    _withDiversityPool($accountId, sub {
        my ($pool) = @_;

        if (@seedArtists) {
            main::INFOLOG && $log->info("SpotOn DSTM: mixing from artists: " . join(', ', @seedArtists));
            _searchArtists($client, $accountId, \@seedArtists, 0, [], $pool, \%seedExclude, $cb);
        }
        else {
            main::INFOLOG && $log->info("SpotOn DSTM: no organic seeds, using pool only");
            _finalizeResults($client, [], $pool, \%seedExclude, $cb);
        }
    });
}

sub _withDiversityPool {
    my ($accountId, $cb) = @_;
    my $key = 'spoton_dstm_pool_' . $accountId;
    my $pool = $cache->get($key);
    if ($pool && ref $pool eq 'ARRAY' && @$pool) {
        return $cb->($pool);
    }
    Plugins::SpotOn::API::SpClient->getTopTracks($accountId, {
        time_range => 'medium_term',
        limit      => 50,
    }, sub {
        my $result = shift;
        $pool = ($result && $result->{items}) ? $result->{items} : [];
        $cache->set($key, $pool, DSTM_POOL_TTL) if @$pool;
        $cb->($pool);
    });
}

sub _searchArtists {
    my ($client, $accountId, $artists, $idx, $allTracks, $pool, $seedExclude, $cb) = @_;

    if ($idx >= scalar @$artists) {
        _finalizeResults($client, $allTracks, $pool, $seedExclude, $cb);
        return;
    }

    my $artist = $artists->[$idx];
    my $limit  = Plugins::SpotOn::API::SpClient->pageLimit('search') || 10;
    my $perArtist = int(DSTM_MAX_TRACKS / scalar(@$artists)) + 1;
    $limit = min($limit, $perArtist);
    my $offset = int(rand(3)) * $perArtist;

    # D5: escape quotes in artist names
    (my $safeArtist = $artist) =~ s/"//g;

    Plugins::SpotOn::API::SpClient->search($accountId, {
        q      => sprintf('artist:"%s"', $safeArtist),
        type   => 'track',
        limit  => $limit,
        offset => $offset,
    }, sub {
        my $result = shift;
        # 79-58: search keeps nameless slots {} for unmappable or other-artist rows; skip them here
        # so an all-slot page still counts as empty for the D6 retry
        my $tracks = ($result && $result->{tracks} && $result->{tracks}{items})
            ? [ grep { ref $_ eq 'HASH' && $_->{uri} } @{ $result->{tracks}{items} } ] : [];

        # D6: only retry on successful-but-empty, not on errors
        if (!@$tracks && $offset > 0 && $result && $result->{tracks}) {
            Plugins::SpotOn::API::SpClient->search($accountId, {
                q      => sprintf('artist:"%s"', $safeArtist),
                type   => 'track',
                limit  => $limit,
                offset => 0,
            }, sub {
                my $result2 = shift;
                my $tracks2 = ($result2 && $result2->{tracks} && $result2->{tracks}{items})
                    ? [ grep { ref $_ eq 'HASH' && $_->{uri} } @{ $result2->{tracks}{items} } ] : [];
                push @$allTracks, @$tracks2;
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + DSTM_SEARCH_STAGGER_S,
                    sub { _searchArtists($client, $accountId, $artists, $idx + 1, $allTracks, $pool, $seedExclude, $cb) });
            });
            return;
        }

        push @$allTracks, @$tracks;

        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + DSTM_SEARCH_STAGGER_S,
            sub { _searchArtists($client, $accountId, $artists, $idx + 1, $allTracks, $pool, $seedExclude, $cb) });
    });
}

sub _finalizeResults {
    my ($client, $allTracks, $pool, $seedExclude, $cb) = @_;

    # 90.1 review WR-03 (b): the fetch chain (getTopTracks, up to three searches
    # 0.2 s apart) takes seconds. A Connect session that began inside that
    # window gets no SpotOn tracks appended (an empty answer, see the note in
    # dontStopTheMusic about what LMS makes of it).
    if (connectSessionActive($client)) {
        main::INFOLOG && $log->info('DSTM: recommendations dropped, the Spotify app controls ' . $client->id
            . ' since the fetch began (D-13)');
        $cb->($client);
        return;
    }

    my $clientId = $client->id();
    my $recentKey = 'spoton_dstm_recent_' . $clientId;
    my $recentUris = $cache->get($recentKey) || [];
    my %recentSet = map { $_ => 1 } @$recentUris;

    # D2: intra-batch URI dedupe + D3: exclude seed tracks
    my (%seenUri, @filtered);
    for my $t (@$allTracks) {
        next unless $t->{uri} && $t->{uri} =~ /(track:[a-z0-9]+)/i;
        my $uri = "spoton://$1";
        next if $seenUri{$uri}++;
        next if $recentSet{$uri};
        my $artist = join(', ', map { $_->{name} } @{$t->{artists} || []});
        next if $seedExclude->{_dstmTagKey($artist, $t->{name})};
        push @filtered, $t;
    }

    # Inject diversity pool tracks
    if ($pool && @$pool) {
        my %searchArtists;
        for my $t (@filtered) {
            for my $a (@{$t->{artists} || []}) {
                $searchArtists{lc($a->{name})}++ if $a->{name};
            }
        }

        my $injected = 0;
        my @poolShuffled = @$pool;
        _shuffle(\@poolShuffled);
        for my $t (@poolShuffled) {
            last if $injected >= DSTM_POOL_INJECT;
            next unless $t->{uri} && $t->{uri} =~ /(track:[a-z0-9]+)/i;
            my $uri = "spoton://$1";
            next if $seenUri{$uri}++ || $recentSet{$uri};
            my $artist = join(', ', map { $_->{name} } @{$t->{artists} || []});
            next if $seedExclude->{_dstmTagKey($artist, $t->{name})};
            my $primaryArtist = ($t->{artists} && @{$t->{artists}}) ? lc($t->{artists}[0]{name} // '') : '';
            next if $primaryArtist && $searchArtists{$primaryArtist};
            push @filtered, $t;
            $injected++;
        }
    }

    unless (@filtered) {
        $cb->($client);
        return;
    }

    _shuffle(\@filtered);
    splice @filtered, DSTM_MAX_TRACKS if @filtered > DSTM_MAX_TRACKS;

    my @uris = _cacheAndExtractUris(\@filtered);

    push @$recentUris, @uris;
    splice @$recentUris, 0, (@$recentUris - DSTM_RECENT_MAX) if @$recentUris > DSTM_RECENT_MAX;
    $cache->set($recentKey, $recentUris, DSTM_RECENT_TTL);

    if (@uris) {
        main::INFOLOG && $log->info("SpotOn DSTM: queuing " . scalar(@uris) . " tracks");
        $cb->($client, \@uris);
    }
    else {
        $cb->($client);
    }
}

sub _cacheAndExtractUris {
    my ($tracks) = @_;
    my @uris;

    require Plugins::SpotOn::Plugin;
    my $type_str = Plugins::SpotOn::Plugin->_typeShortForClient(undef);

    for my $track (@$tracks) {
        next unless $track->{uri} && $track->{uri} =~ /(track:[a-z0-9]+)/i;
        my $uri = "spoton://$1";

        my $artist = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
        my $images = $track->{album}{images} || [];
        my $image  = @$images ? (sort { ($b->{width}||0) <=> ($a->{width}||0) } @$images)[0]->{url} : '';
        my $year   = Plugins::SpotOn::Plugin::_releaseYear(($track->{album} || {})->{release_date});

        my %trackIds = Plugins::SpotOn::Plugin::_extractTrackIds($track);
        require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
        $cache->set('spoton_meta_' . md5_hex($uri), {
            _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
            title    => $track->{name} // '',
            artist   => $artist,
            album    => $track->{album}{name} // '',
            duration => ($track->{duration_ms} || 0) / 1000,
            cover    => $image,
            icon     => $image,
            year     => $year,
            bitrate  => Plugins::SpotOn::Plugin->_bitrateLabelForClient(undef),
            type     => $type_str,
            %trackIds,
        }, 604800);

        $cache->set(_dstmTagKey($artist, $track->{name}), 1, DSTM_TAG_TTL);

        push @uris, $uri;
    }

    return @uris;
}

sub _shuffle {
    my ($arr) = @_;
    for my $i (reverse 1 .. $#$arr) {
        my $j = int(rand($i + 1));
        @$arr[$i, $j] = @$arr[$j, $i];
    }
}

1;
