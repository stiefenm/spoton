package Plugins::SpotOn::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;
use Slim::Utils::Cache;
use Digest::MD5 qw(md5_hex);
use JSON::XS qw(encode_json);
use Time::HiRes;
use Time::Local qw(timelocal);
use File::Basename;
use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use constant KILL_PROCESS_INTERVAL => 3600;    # Hourly orphaned-process cleanup (STR-10)
use constant SPOTON_CACHE_VERSION  => 4;       # Bump to flush all SpotOn cache entries (D-01/D-02)
use constant FLUSH_BATCH           => 50;      # Items per event-loop tick in _flushDeferredMeta (FIX-01)

my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', SPOTON_CACHE_VERSION);

my %_playAllItemCache;
my %_pauseRequestedAt;
sub _evictPlayAllCache {
    my $now = time();
    delete @_playAllItemCache{ grep { $now - $_playAllItemCache{$_}{ts} > 120 } keys %_playAllItemCache };
}

# _flushDeferredMeta($context, $pending, $start)
# Background metadata cache writer — processes deferred cache->set calls from play-all
# done callbacks in batches of 50 items per event-loop tick, yielding between batches
# so audio prefetch / streaming I/O can be serviced between writes.
#
# Called via Slim::Utils::Timers::setTimer (first arg is the timer context, ignored).
# Each entry in @$pending is a hashref:
#   { url, title, artist, album, duration, cover, icon, track, client }
# where 'track' is the raw Spotify track hashref (for _extractTrackIds / encode_json)
# and 'client' is the LMS player object (for _bitrateForClient / _typeString).
#
# Design (FIX-01): separates the O(N) string-building path (fast, in done callback)
# from the O(N) SQLite INSERT path (deferred here), preventing event-loop starvation
# on large Liked Songs / playlist play-all operations.
sub _flushDeferredMeta {
    my (undef, $pending, $start) = @_;
    return unless $pending && @$pending && $start <= $#$pending;

    my $end = $start + FLUSH_BATCH - 1;
    $end = $#$pending if $end > $#$pending;

    for my $i ($start .. $end) {
        my $p = $pending->[$i] or next;
        my %trackIds = _extractTrackIds($p->{track});
        # Guard: client may have disconnected before flush completes
        my ($bitrate, $type);
        if ($p->{client} && $p->{client}->can('id')) {
            $bitrate = __PACKAGE__->_bitrateForClient($p->{client}) . 'k';
            $type    = __PACKAGE__->_typeString($p->{client}, 'Browse');
        } else {
            $bitrate = '320k';
            $type    = 'Spotify';
        }
        $cache->set(
            'spoton_meta_' . md5_hex($p->{url}),
            {
                title    => $p->{title},
                artist   => $p->{artist},
                album    => $p->{album},
                duration => $p->{duration},
                cover    => $p->{cover},
                icon     => $p->{icon},
                bitrate  => $bitrate,
                type     => $type,
                %trackIds,
            },
            604800
        );
    }

    if ($end < $#$pending) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), \&_flushDeferredMeta, $pending, $end + 1);
    }
}

my $log = Slim::Utils::Log->addLogCategory( {
    category     => 'plugin.spoton',
    defaultLevel => 'WARN',
    description  => 'PLUGIN_SPOTON',
    logGroups    => 'SCANNER',
} );

sub initPlugin {
    my $class = shift;

    if ( !main::TRANSCODING ) {
        $log->error('Transcoding is required for SpotOn to work');
        return;
    }

    $prefs->init({
        bitrate              => 320,
        normalization        => 0,     # STR-08: volume normalisation toggle, default off (D-06)
        binary               => '',    # custom binary override (LMS-10, Phase 6)
        accounts             => {},    # hash: accountId => { displayName => '...', spotifyUserId => '...' }
        activeAccount        => '',    # default active account ID (global fallback)
        enableSpotifyConnect => 1,     # CON-10: per-player Connect toggle, default on
        connectOggOverride   => 'auto', # D-05: OGG passthrough override ('auto'|'ogg'|'pcm')
        disableDiscovery     => 0,     # D-04: global discovery toggle, default on (Pitfall 4)
        enableAutoplay       => 1,     # D-08: Autoplay toggle, default on (controls Connect autoplay + DSTM)
        cacheSchemaVersion   => 0,     # D-02: migration marker — triggers cache clear on version bump
        diagnosticMode       => 0,     # #3: diagnostic logging toggle, default off
        streamingMode        => 'direct', # COMPAT-01: global streaming mode default (direct|proxy); per-player override lives in same-name client pref (GH #96)
    });

    # D-02: cacheSchemaVersion guard — log when cache namespace version was bumped
    if ( ($prefs->get('cacheSchemaVersion') || 0) < SPOTON_CACHE_VERSION ) {
        $log->info("SpotOn cache schema version changed - cache cleared by namespace version bump");
        $prefs->set('cacheSchemaVersion', SPOTON_CACHE_VERSION);
    }

    require Plugins::SpotOn::Helper;
    Plugins::SpotOn::Helper->init();

    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::API::Client;

    # Reset API client inflight counter (Pitfall 2 prevention — stale counter on reload)
    Plugins::SpotOn::API::Client->reset();

    # Start proactive token refresh timer — T-02-15: killTimers first to prevent duplicates
    if ( !main::SCANNER ) {
        Slim::Utils::Timers::killTimers($class, \&_refreshAllTokens);
        Slim::Utils::Timers::setTimer(
            $class,
            Time::HiRes::time() + 10,
            \&_refreshAllTokens
        );

        # Start orphaned-process cleanup timer (STR-10)
        Slim::Utils::Timers::killTimers($class, \&_killOrphanedProcesses);
        Slim::Utils::Timers::setTimer(
            $class,
            Time::HiRes::time() + KILL_PROCESS_INTERVAL,
            \&_killOrphanedProcesses
        );
    }

    $VERSION = $class->_pluginDataFor('version');

    Slim::Player::ProtocolHandlers->registerHandler(
        'spoton',
        'Plugins::SpotOn::ProtocolHandler'
    );

    # D-06: Register as DSTM provider (Don't Stop The Music).
    # Outside main::WEBUI guard — DSTM works headless too.
    # isEnabled check prevents crash if DSTM plugin is not installed.
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Plugins::SpotOn::DontStopTheMusic;
        Plugins::SpotOn::DontStopTheMusic->init();
    }

    if (main::WEBUI) {
        require Plugins::SpotOn::Settings;
        Plugins::SpotOn::Settings->new();

        require Plugins::SpotOn::Settings::Player;
        Plugins::SpotOn::Settings::Player->new();

        require Plugins::SpotOn::Status;
        Plugins::SpotOn::Status->new();

        # D-01: Auto-start ZeroConf Discovery if no credentials exist.
        # Deferred via timer to not block initPlugin.
        Slim::Utils::Timers::killTimers(undef, \&_autoStartDiscovery);
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&_autoStartDiscovery);

        # Start Unified daemon manager for all players.
        # 4s delay: allows player list to populate after LMS start.
        Slim::Utils::Timers::killTimers($class, \&_startUnifiedDaemons);
        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 4, \&_startUnifiedDaemons);

        # Restart Unified daemons when diagnosticMode changes so RUST_LOG and
        # stderr routing take effect immediately.
        $prefs->setChange( sub {
            if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
                require Plugins::SpotOn::Unified::DaemonManager;
                Plugins::SpotOn::Unified::DaemonManager->shutdown();
                Slim::Utils::Timers::killTimers('Plugins::SpotOn::Unified::DaemonManager', \&Plugins::SpotOn::Unified::DaemonManager::initHelpers);
                Slim::Utils::Timers::setTimer(
                    'Plugins::SpotOn::Unified::DaemonManager',
                    Time::HiRes::time() + 1,
                    \&Plugins::SpotOn::Unified::DaemonManager::initHelpers,
                );
            }
        }, 'diagnosticMode');
    }

    # Phase 27: Prefetch hang watchdog — detects when a Browse-mode track stalls
    # at the end because the next track's pipeline failed (unavailable, audio key
    # error, timeout). Forces skip after duration + 5s if player is still stuck.
    Slim::Control::Request::subscribe(\&_onNewSongWatchdog, [['playlist'], ['newsong']]);
    Slim::Control::Request::subscribe(\&_onModeChange, [['playlist'], ['pause']]);
    Slim::Control::Request::subscribe(\&_onPauseCommand, [['pause']]);

    _deployMaterialSkinIcon();

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'spoton',
        menu   => 'radios',
        is_app => 1,
        weight => 100,
        icon   => 'plugins/SpotOn/html/images/SpotOn_MTL_svg_spoton.png',
    );

    # D-01: Register Like/Unlike action in Track Info menu (LIB-01/LIB-02/LIB-03)
    # require (not use) — Slim::Menu::TrackInfo may not be available at compile time in all LMS contexts
    require Slim::Menu::TrackInfo;
    Slim::Menu::TrackInfo->registerInfoProvider( spotonTrackInfo => (
        after => 'top',
        func  => \&trackInfoMenu,
    ) );

    # GH-93: Override built-in URL display for spoton:// URLs.
    # Shows https://open.spotify.com/{type}/{id} as clickable weblink
    # instead of the raw spoton:// protocol URL.
    Slim::Menu::TrackInfo->registerInfoProvider( url => (
        parent => 'moreinfo',
        after  => 'lastplayed',
        func   => \&_infoUrl,
    ) );
}

sub shutdownPlugin {
    my $class = shift;

    require Plugins::SpotOn::Connect;
    Plugins::SpotOn::Connect->shutdown();

    # Unsubscribe watchdog registered in initPlugin — prevents duplicate handler
    # accumulation across plugin reloads (each reload calls shutdown then init).
    Slim::Control::Request::unsubscribe(\&_onNewSongWatchdog);
    Slim::Control::Request::unsubscribe(\&_onModeChange);
    Slim::Control::Request::unsubscribe(\&_onPauseCommand);

    for my $id (keys %_pauseRequestedAt) {
        next if $id eq '_reapplying';
        my $client = Slim::Player::Client::getClient($id);
        Slim::Utils::Timers::killTimers($client, \&_pauseGuardCheck) if $client;
    }
    %_pauseRequestedAt = ();

    if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->shutdown();
    }

    Slim::Utils::Timers::killTimers($class, \&_killOrphanedProcesses);
    Slim::Utils::Timers::killTimers($class, \&_refreshAllTokens);
    Slim::Utils::Timers::killTimers($class, \&_startUnifiedDaemons);
}

# Material Skin resolves app icons via /material/svg/{tag} from its own
# images dir, with a fallback to {prefs_dir}/material-skin/images/.
# Deploy our SVG there so the icon renders in the Material Skin grid.
sub _deployMaterialSkinIcon {
    my $src = catfile(dirname(__FILE__), 'HTML', 'EN', 'plugins', 'SpotOn',
                      'html', 'images', 'spoton_material.svg');
    return unless -e $src;

    my $destDir = catdir(Slim::Utils::Prefs::dir(), 'material-skin', 'images');
    my $dest    = catfile($destDir, 'spoton.svg');
    return if -e $dest && (stat($dest))[9] >= (stat($src))[9];

    eval {
        require File::Path;
        File::Path::make_path($destDir) unless -d $destDir;
        require File::Copy;
        File::Copy::copy($src, $dest);
    };
    $log->warn("Material Skin icon deploy failed: $@") if $@;
}

# _refreshAllTokens()
# Thin timer callback wrapper — Slim::Utils::Timers passes $class as first arg.
sub _refreshAllTokens {
    Plugins::SpotOn::API::TokenManager->refreshAllTokens();
}

# _autoStartDiscovery()
# D-01: Timer callback — auto-starts ZeroConf discovery if no credentials exist.
sub _autoStartDiscovery {
    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->autoStartDiscoveryIfNeeded();
}

# _startUnifiedDaemons()
# Phase 29: Timer callback — starts Unified daemon manager at LMS boot.
# 4s delay: after Connect and Browse timers to ensure player list populated.
sub _startUnifiedDaemons {
    require Plugins::SpotOn::Connect;
    Plugins::SpotOn::Connect->initConnectHandlers();
    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->init();
}

# _killOrphanedProcesses($class)
# Cleans up orphaned librespot processes when no player is actively playing.
# Runs every KILL_PROCESS_INTERVAL seconds (STR-10).
# IMPORTANT: Slim::Player::Client is NOT explicitly imported — LMS autoloads it.
sub _killOrphanedProcesses {
    my ($class) = @_;

    Slim::Utils::Timers::killTimers($class, \&_killOrphanedProcesses);

    # CR-01/WR-04: Only check Spotify-playing clients (not all protocols).
    # This prevents false positives (non-Spotify playback blocking cleanup)
    # and reduces the race window during Spotify track transitions.
    my $isBusy = 0;
    my %activePids;
    for my $client (Slim::Player::Client::clients()) {
        my $song = $client->playingSong() || next;
        my $url  = $song->currentTrack() ? $song->currentTrack()->url : '';
        next unless $url =~ m{^spoton://};

        if ($client->isPlaying()) {
            main::DEBUGLOG && $log->is_debug && $log->debug("Spotify player " . $client->name() . " is busy, skipping orphan cleanup");
            $isBusy = 1;
        }

        # Track PIDs of active transcoding processes to protect them from kill.
        # M7: 'my $x = ... if ...' is undefined behavior in Perl (stale values
        # across iterations) — declare and assign separately.
        # Note: LMS Song objects have no transcodeProcess method under the
        # Unified daemon architecture — this guard is a defensive no-op there.
        my $pid;
        $pid = $song->transcodeProcess() if $song->can('transcodeProcess');
        $activePids{$pid} = 1 if $pid;
    }

    unless ($isBusy) {
        my ($helper) = Plugins::SpotOn::Helper->get();
        if ($helper) {
            # W2: The ZeroConf discovery process runs the same helper binary —
            # exclude its PID from orphan cleanup so a running discovery is
            # not killed mid-flow.
            my $discoveryPid;
            if ($INC{'Plugins/SpotOn/API/TokenManager.pm'}) {
                $discoveryPid = Plugins::SpotOn::API::TokenManager->discoveryPid;
            }
            eval {
                if (main::ISWINDOWS) {
                    my $name = basename($helper);
                    $name =~ s/[^A-Za-z0-9._-]//g;
                    if ($name) {
                        my %unifiedPids;
                        if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
                            %unifiedPids = map { $_ => 1 }
                                Plugins::SpotOn::Unified::DaemonManager->helperPids();
                        }
                        my @pids = map { /^"[^"]*","(\d+)"/ ? $1 : () }
                            `tasklist /FI "IMAGENAME eq $name" /FO CSV /NH 2>nul`;
                        for my $pid (@pids) {
                            next if $activePids{$pid};
                            next if $unifiedPids{$pid};
                            next if $discoveryPid && $pid == $discoveryPid;   # W2
                            kill 'KILL', $pid;
                            main::DEBUGLOG && $log->is_debug && $log->debug("Killed orphaned spoton process PID $pid (Windows)");
                        }
                    }
                } else {
                    # CR-01: Use PID-based kill to avoid killing active transcoding processes.
                    # Find all matching PIDs, exclude active ones, kill only orphans.
                    # CON-09: Exclude Unified daemon PIDs from orphan cleanup.
                    my %unifiedPids;
                    if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
                        %unifiedPids = map { $_ => 1 }
                            Plugins::SpotOn::Unified::DaemonManager->helperPids();
                    }

                    # M6: pgrep -f treats the pattern as an extended regex —
                    # quotemeta the helper path FIRST so dots and other
                    # metacharacters cannot match (and kill) foreign processes,
                    # THEN apply the single-quote shell escaping.
                    (my $safeHelper = quotemeta($helper)) =~ s/'/'\\''/g;
                    my @pids = map { /^\s*(\d+)/ ? $1 : () } `pgrep -f '$safeHelper'`;
                    for my $pid (@pids) {
                        next if $activePids{$pid};
                        next if $unifiedPids{$pid};    # CON-09: protect Unified daemon PIDs
                        next if $discoveryPid && $pid == $discoveryPid;   # W2
                        kill 'TERM', $pid;
                        main::DEBUGLOG && $log->is_debug && $log->debug("Killed orphaned spoton process PID $pid");
                    }
                }
            };
            $@ && $log->warn("Could not kill orphaned spoton processes: $@");
        }
    }

    # Always reschedule (even when $isBusy) to maintain hourly cleanup cycle
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + KILL_PROCESS_INTERVAL,
        \&_killOrphanedProcesses
    );
}

sub handleFeed {
    my ($client, $callback, $args) = @_;

    if ( !Plugins::SpotOn::Helper->get() ) {
        $callback->({
            items => [{
                name => cstring($client, 'PLUGIN_SPOTON_BINARY_MISSING'),
                type => 'textarea',
            }]
        });
        return;
    }

    my @items;

    # Rate-limit hint (D-12): show when either token flavor is throttled
    if ( $cache->get('spoton_rate_limit_own') || $cache->get('spoton_rate_limit_bundled') ) {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_RATE_LIMIT_HINT'),
            type => 'textarea',
        };
    }

    # Account switcher: only show when multiple accounts configured
    my $activeName = Plugins::SpotOn::API::TokenManager->getActiveAccountName($client);
    my $accountCount = scalar Plugins::SpotOn::API::TokenManager->getAccountIds();
    if ($activeName) {
        if ($accountCount > 1) {
            push @items, {
                name => cstring($client, 'PLUGIN_SPOTON_ACTIVE_ACCOUNT', $activeName),
                url  => \&_accountSwitcherFeed,
                type => 'link',
            };
        }

        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_HOME'),
            url  => \&_homeFeed,
            type => 'link',
        };
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_SEARCH'),
            url  => \&_searchFeed,
            type => 'search',
        };
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_LIBRARY'),
            url  => \&_libraryFeed,
            type => 'link',
        };
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_PODCASTS'),
            url  => \&_podcastsFeed,
            type => 'link',
        };
    } else {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_ACCOUNT_NONE'),
            type => 'textarea',
        };
    }

    $callback->({ items => \@items });
}

# _accountSwitcherFeed()
# Lists all configured accounts with selection triggering menu refresh.
sub _accountSwitcherFeed {
    my ($client, $callback, $args) = @_;

    my $accounts  = $prefs->get('accounts') || {};
    my $activeId  = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';

    my @items;
    for my $id (sort keys %{$accounts}) {
        my $name    = $accounts->{$id}{displayName} || $id;
        my $isActive = ($id eq $activeId);
        push @items, {
            name        => $name . ($isActive ? ' *' : ''),
            url         => \&_switchAccount,
            passthrough => [{ accountId => $id }],
            type        => 'link',
        };
    }

    $callback->({ items => \@items });
}

# _switchAccount()
# Updates per-client activeAccount preference and navigates back to root.
sub _switchAccount {
    my ($client, $callback, $args, $passthrough) = @_;

    my $accountId = $passthrough ? $passthrough->{accountId} : undef;
    my $name;

    if ($accountId && $client) {
        $prefs->client($client)->set('activeAccount', $accountId);
        $prefs->set('activeAccount', $accountId) unless $prefs->get('activeAccount');
        my $accounts = $prefs->get('accounts') || {};
        $name = $accounts->{$accountId}{displayName} if $accounts->{$accountId};
    }

    my $msg = $name
        ? cstring($client, 'PLUGIN_SPOTON_ACCOUNT_SWITCHED', $name)
        : 'OK';

    $callback->({ items => [
        {
            name => $msg,
            type => 'text',
        },
    ] });
}

# ============================================================
# Shared Helper Functions
# ============================================================

# _getAccountId($client)
# Returns the active account ID for the given player client.
# Falls back to global activeAccount pref, then empty string.
sub _getAccountId {
    my ($client) = @_;
    # H4: $prefs->client(undef) crashes — web UI browse without an active
    # player passes no client. Fall back to the global active account.
    return $prefs->get('activeAccount') || '' unless $client;
    return $prefs->client($client)->get('activeAccount')
        || $prefs->get('activeAccount')
        || '';
}

# ============================================================
# Like / Unlike (Phase 15)
# ============================================================

# _extractTrackIds($track)
# Extracts artist and album IDs from a Spotify track hash for cache storage.
# Returns a hash with keys: artistId (first artist), artistIds (JSON-encoded array
# of {id, name} pairs for all artists), albumId.
# Single source of truth — called from all cache write sites (WR-01).
sub _extractTrackIds {
    my ($track) = @_;
    my $artists   = $track->{artists} || [];
    my $artistId  = (@$artists && $artists->[0]{id}) ? $artists->[0]{id} : undef;
    my @named     = grep { $_->{id} && $_->{name} } @$artists;
    my $artistIds = @named ? encode_json([map { { id => $_->{id}, name => $_->{name} } } @named]) : undef;
    my $albumId   = ($track->{album} || {})->{id};
    return (artistId => $artistId, artistIds => $artistIds, albumId => $albumId);
}

sub _infoUrl {
    my ($client, $url, $track) = @_;

    if ($url && $url =~ m{^spoton:(?://)?(\w+):([A-Za-z0-9]+)}) {
        my ($type, $id) = ($1, $2);
        my $weburl = "https://open.spotify.com/$type/$id";
        return {
            type    => 'text',
            name    => $weburl,
            label   => 'URL',
            weblink => $weburl,
        };
    }

    return Slim::Menu::TrackInfo::infoUrl($client, $url, $track);
}

sub trackInfoMenu {
    my ($client, $url, $track, $remoteMeta, $tags) = @_;

    my ($type, $id);
    if ($url && $url =~ m{^spoton:(?://)?track:([A-Za-z0-9]+)}) {
        $type = 'track';
        $id   = $1;
    } elsif ($url && $url =~ m{^spoton:(?://)?episode:([A-Za-z0-9]+)}) {
        $type = 'episode';
        $id   = $1;
    }
    return unless $type;

    my $accountId = _getAccountId($client);
    return unless $accountId;

    # CR-01: Normalize URL for cache lookup — cache is keyed on spoton:// (with //)
    # but LMS may pass spoton:track:ID (without //).
    my $cacheUrl = $url;
    if ($cacheUrl && $cacheUrl =~ m{^spoton:(?!//)}) {
        $cacheUrl =~ s{^spoton:}{spoton://};
    }
    my $meta = $cache->get('spoton_meta_' . md5_hex($cacheUrl)) || {};
    my @items;

    if ($type eq 'track') {
        if ($meta->{artistId}) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ARTIST_VIEW'),
                url         => \&_artistFeed,
                passthrough => [{ artistId => $meta->{artistId} }],
                type        => 'link',
            };
        }
        if ($meta->{albumId}) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ALBUM_VIEW'),
                url         => \&_albumFeed,
                passthrough => [{ albumId => $meta->{albumId} }],
                type        => 'link',
            };
        }
        push @items, {
            name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_LIKE'),
            url         => \&SpotOnManageLike,
            passthrough => [{ trackUri => "spotify:track:$id", accountId => $accountId }],
            type        => 'link',
            favorites   => 0,
        };
        push @items, {
            name        => cstring($client, 'PLUGIN_SPOTON_ADD_TO_PLAYLIST'),
            url         => \&SpotOnAddToPlaylist,
            passthrough => [{ spotifyUri => "spotify:track:$id", accountId => $accountId }],
            type        => 'link',
            favorites   => 0,
        };
    } else {
        if ($meta->{showId}) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_SHOW_VIEW'),
                url         => \&_showFeed,
                passthrough => [{ showId => $meta->{showId}, showName => $meta->{showName} }],
                type        => 'link',
            };
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_FOLLOW'),
                url         => \&SpotOnManageFollow,
                passthrough => [{ showUri => "spotify:show:$meta->{showId}", accountId => $accountId }],
                favorites   => 0,
            };
        }
        push @items, {
            name        => cstring($client, 'PLUGIN_SPOTON_ADD_TO_PLAYLIST'),
            url         => \&SpotOnAddToPlaylist,
            passthrough => [{ spotifyUri => "spotify:episode:$id", accountId => $accountId }],
            type        => 'link',
            favorites   => 0,
        };
    }

    return @items ? \@items : undef;
}

# SpotOnManageLike($client, $cb, $params, $args)
# Resolves liked state (cache-first, then API) and builds a dynamic Like/Unlike menu item.
# D-03: shows 'Like' or 'Unlike' based on current liked state.
# D-06: on-demand state check — no pre-fetch.
# D-07: 60s TTL cache — cache hit avoids API call.
sub SpotOnManageLike {
    my ($client, $cb, $params, $args) = @_;

    my $trackUri  = $args->{trackUri} // '';
    return unless $trackUri =~ /^spotify:track:[A-Za-z0-9]+$/;
    my $accountId = $args->{accountId};

    my $cacheKey = _likedCacheKey($accountId, $trackUri);

    my $buildMenu = sub {
        my ($isLiked) = @_;
        $cb->({ items => [{
            name        => cstring($client, $isLiked ? 'PLUGIN_SPOTON_UNLIKE' : 'PLUGIN_SPOTON_LIKE'),
            url         => $isLiked ? \&SpotOnUnlike : \&SpotOnLike,
            passthrough => [{ trackUri => $trackUri, accountId => $accountId, cacheKey => $cacheKey }],
            nextWindow  => 'grandparent',
        }] });
    };

    # D-07: Cache hit = zero delay (60s TTL)
    my $cached = $cache->get($cacheKey);
    if (defined $cached) {
        $buildMenu->($cached);
        return;
    }

    # D-06: On-demand API call only on cache miss
    Plugins::SpotOn::API::Client->checkTracks($accountId, [$trackUri], sub {
        my ($result, $err) = @_;
        my $isLiked = ($result && ref $result eq 'ARRAY' && $result->[0]) ? 1 : 0;
        $cache->set($cacheKey, $isLiked, 60) unless $err;
        $buildMenu->($isLiked);
    });
}

sub SpotOnLike {
    my ($client, $cb, $params, $args) = @_;
    _doLibraryAction($client, $cb, $args, 'saveTracks', 'PLUGIN_SPOTON_LIKED');
}

sub SpotOnUnlike {
    my ($client, $cb, $params, $args) = @_;
    _doLibraryAction($client, $cb, $args, 'removeTracks', 'PLUGIN_SPOTON_UNLIKED');
}

sub _likedCacheKey {
    my ($accountId, $trackUri) = @_;
    my ($trackId) = $trackUri =~ /^spotify:track:(.+)$/;
    return "spoton_liked_${accountId}_${trackId}";
}

my %_LIBRARY_API_METHODS = map { $_ => 1 } qw(saveTracks removeTracks saveShows removeShows);

sub _doLibraryAction {
    my ($client, $cb, $args, $apiMethod, $successKey, $opts) = @_;
    $opts //= {};

    die "Invalid API method: $apiMethod" unless $_LIBRARY_API_METHODS{$apiMethod};

    my $uri       = $args->{trackUri} // $args->{showUri};
    my $accountId = $args->{accountId};
    my $cacheKey  = $args->{cacheKey};
    my $errorKey  = $opts->{errorKey} // 'PLUGIN_SPOTON_LIKE_ERROR';
    my $saveMethod = $opts->{saveMethod} // 'saveTracks';

    Plugins::SpotOn::API::Client->$apiMethod($accountId, [$uri], sub {
        my ($result, $err) = @_;
        if ($err) {
            my $msg = (ref $err eq 'HASH' && $err->{code} && $err->{code} == 403)
                ? cstring($client, 'PLUGIN_SPOTON_LIKE_ERROR_SCOPE')
                : cstring($client, $errorKey);
            $cb->({ items => [{ name => $msg }] });
            return;
        }
        my $newState = ($apiMethod eq $saveMethod) ? 1 : 0;
        $cache->set($cacheKey, $newState, 60);
        $client->showBriefly({
            jive => { type => 'popupplay', text => [ cstring($client, $successKey) ] },
        }) if $client;
        $cb->({ items => [{
            name        => cstring($client, $successKey),
            $opts->{textarea} ? (type => 'textarea') : (nextWindow => 'grandparent'),
        }] });
    });
}


# ============================================================
# Follow / Unfollow Show (Phase 20)
# ============================================================

# SpotOnManageFollow($client, $cb, $params, $args)
# Resolves follow state (cache-first, then API) and builds a dynamic Follow/Unfollow menu item.
# T-20-01: showUri validated against spotify:show:[A-Za-z0-9]+ before any API call.
# D-07: 60s TTL cache — cache hit avoids API call.
sub SpotOnManageFollow {
    my ($client, $cb, $params, $args) = @_;

    my $showUri   = $args->{showUri} // '';
    return unless $showUri =~ /^spotify:show:[A-Za-z0-9]+$/;
    my $accountId = $args->{accountId};

    my $cacheKey = _followCacheKey($accountId, $showUri);

    my $buildMenu = sub {
        my ($isFollowed) = @_;
        $cb->({ items => [{
            name        => cstring($client, $isFollowed ? 'PLUGIN_SPOTON_UNFOLLOW_SHOW' : 'PLUGIN_SPOTON_FOLLOW_SHOW'),
            url         => $isFollowed ? \&SpotOnUnfollowShow : \&SpotOnFollowShow,
            passthrough => [{ showUri => $showUri, accountId => $accountId, cacheKey => $cacheKey }],
            nextWindow  => 'grandparent',
        }] });
    };

    # D-07: Cache hit = zero delay (60s TTL)
    my $cached = $cache->get($cacheKey);
    if (defined $cached) {
        $buildMenu->($cached);
        return;
    }

    # On-demand API call only on cache miss
    Plugins::SpotOn::API::Client->checkShows($accountId, [$showUri], sub {
        my ($result, $err) = @_;
        my $isFollowed = ($result && ref $result eq 'ARRAY' && $result->[0]) ? 1 : 0;
        $cache->set($cacheKey, $isFollowed, 60) unless $err;
        $buildMenu->($isFollowed);
    });
}

my %SHOW_LIBRARY_OPTS = (
    errorKey   => 'PLUGIN_SPOTON_SHOW_ACTION_ERROR',
    saveMethod => 'saveShows',
    textarea   => 1,
);

sub SpotOnFollowShow {
    my ($client, $cb, $params, $args) = @_;
    _doLibraryAction($client, $cb, $args, 'saveShows', 'PLUGIN_SPOTON_SHOW_FOLLOWED', \%SHOW_LIBRARY_OPTS);
}

sub SpotOnUnfollowShow {
    my ($client, $cb, $params, $args) = @_;
    _doLibraryAction($client, $cb, $args, 'removeShows', 'PLUGIN_SPOTON_SHOW_UNFOLLOWED', \%SHOW_LIBRARY_OPTS);
}

sub _followCacheKey {
    my ($accountId, $showUri) = @_;
    my ($showId) = $showUri =~ /^spotify:show:(.+)$/;
    return "spoton_followed_${accountId}_${showId}";
}


# ============================================================
# Add to Playlist (Phase 34)
# ============================================================

sub SpotOnAddToPlaylist {
    my ($client, $cb, $params, $args) = @_;

    my $spotifyUri = $args->{spotifyUri} // '';
    return unless $spotifyUri =~ /^spotify:(track|episode):[A-Za-z0-9]+$/;
    my $accountId = $args->{accountId};

    my $offset = $params->{index} || 0;
    my $qty    = $params->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    Plugins::SpotOn::API::Client->getUserPlaylists($accountId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my ($data, $err) = @_;
        unless ($data && $data->{items}) {
            $cb->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my @items;
        for my $pl (@{ $data->{items} }) {
            next unless $pl && $pl->{id};
            next if _isMadeForYou($pl);
            push @items, {
                name        => $pl->{name} // '',
                url         => \&_doAddToPlaylist,
                passthrough => [{ playlistId => $pl->{id}, playlistName => $pl->{name}, spotifyUri => $spotifyUri, accountId => $accountId }],
                image       => _largestImage($pl->{images}),
                line2       => ($pl->{owner} || {})->{display_name} // '',
                type        => 'link',
            };
        }

        $cb->({ items => \@items, offset => $offset, total => $data->{total} || 0 });
    });
}

sub _doAddToPlaylist {
    my ($client, $cb, $params, $args) = @_;

    my $playlistId   = $args->{playlistId};
    my $playlistName = $args->{playlistName} // '';
    my $spotifyUri   = $args->{spotifyUri};
    my $accountId    = $args->{accountId};

    Plugins::SpotOn::API::Client->addToPlaylist($accountId, $playlistId, [$spotifyUri], sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_ADD_TO_PLAYLIST_ERROR') }] });
            return;
        }
        $client->showBriefly({
            jive => { type => 'popupplay', text => [ sprintf(cstring($client, 'PLUGIN_SPOTON_ADDED_TO_PLAYLIST'), $playlistName) ] },
        }) if $client;
        $cb->({ items => [{
            name       => sprintf(cstring($client, 'PLUGIN_SPOTON_ADDED_TO_PLAYLIST'), $playlistName),
            nextWindow => 'grandparent',
        }] });
    });
}


# _largestImage($images_arrayref)
# Returns the URL of the largest image (by width) from a Spotify images array.
# Returns '' if the array is empty or undef.
# Per PATTERNS.md Artwork pattern and RESEARCH.md Pitfall 6.
sub _largestImage {
    my ($images) = @_;
    return '' unless ref $images eq 'ARRAY' && @{$images};
    my ($largest) = sort { ($b->{width} || 0) <=> ($a->{width} || 0) } @{$images};
    return $largest->{url} || '';
}

# Regex pattern for Spotify-generated personal mix playlists (D-06).
# Uses \s+ instead of literal spaces for whitespace variants.
# Both call sites (_madeForYouFeed and _userPlaylistsFeed)
# use _isMadeForYou — changing only this function is sufficient (Pitfall 4: single detection point).
my $PERSONAL_MIX_REGEX = qr/Daily\s+Mix|MixTape|Discover\s+Weekly|Mix\s+der\s+Woche|Release\s+Radar/i;

# _isMadeForYou($playlist_hashref)
# Returns true if the playlist is a Spotify-generated personal mix.
# Detection via name-matching (D-06) — replaces broken owner.id eq 'spotify' filter
# which fails in Dev Mode (Feb 2026: owner fields restricted).
sub _isMadeForYou {
    my ($playlist) = @_;
    return ($playlist->{name} // '') =~ $PERSONAL_MIX_REGEX;
}

# _trackItem($client, $track, $opts)
# Builds an OPML audio item hashref for a Spotify track.
# Per RESEARCH.md Pattern 3 and PATTERNS.md Track-Item pattern.
# D-06: url and play set to spotify:// URI for Play-Intent.
# D-07: items array carries context navigation (Artist view, Album view).
# FIX-01: $opts->{defer_cache} — arrayref to accumulate deferred metadata writes.
#   When set, skips the synchronous $cache->set and instead pushes a pending entry
#   onto the arrayref. Caller must call _flushDeferredMeta to write them in background.
#   Used by play-all done callbacks to avoid blocking the event loop with N SQLite writes.
sub _trackItem {
    my ($client, $track, $opts) = @_;
    my $title    = $track->{name} // '';
    my $artist   = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
    my $album    = $track->{album}{name} // '';
    my $image    = _largestImage($track->{album}{images});
    my $duration = ($track->{duration_ms} || 0) / 1000;

    # D-07: Build context navigation items for artist and album drill-down.
    # Only add links when IDs are available (simplified track objects may lack album).
    # UX-05: label-bearing text items MUST come first so XMLBrowser populates $details
    # and enables Play/Queue/Favorites buttons in the Default skin info view.
    my @contextItems;
    if ($artist) {
        push @contextItems, {
            name  => $artist,
            type  => 'text',
            label => 'ARTIST',
        };
    }
    if ($album) {
        push @contextItems, {
            name  => $album,
            type  => 'text',
            label => 'ALBUM',
        };
    }
    if ($track->{artists} && @{ $track->{artists} } && $track->{artists}[0]{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_ARTIST_VIEW'),
            url         => \&_artistFeed,
            passthrough => [{ artistId => $track->{artists}[0]{id} }],
            type        => 'link',
        };
    }
    if ($track->{album} && $track->{album}{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_ALBUM_VIEW'),
            url         => \&_albumFeed,
            passthrough => [{ albumId => $track->{album}{id} }],
            type        => 'link',
        };
    }

    if ($track->{uri} && $track->{uri} =~ /^spotify:track:[A-Za-z0-9]+$/) {
        my $accountId = _getAccountId($client);
        if ($accountId) {
            push @contextItems, {
                name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_LIKE'),
                url         => \&SpotOnManageLike,
                passthrough => [{ trackUri => $track->{uri}, accountId => $accountId }],
                type        => 'link',
            };
        }
    }

    # T-04.1-01: Extract path from Spotify URI to prevent double-prefix.
    # spotify:track:ID -> track:ID; fallback preserves original URI if no match.
    my ($track_path) = ($track->{uri} // '') =~ /^spotify:((?:track|episode):.+)/;
    $track_path //= ($track->{uri} // '');
    my $spoton_url = 'spoton://' . $track_path;

    # Cache metadata for getMetadataFor (STR-03): NowPlaying artwork + title display
    # D-02: 7-day TTL (604800s) so Browse tracks survive in history for a week
    # Store IDs so trackInfoMenu can build Artist/Album navigation without a live API call.
    # FIX-01: In play-all mode ($opts->{defer_cache} set), push to deferred list instead of
    # writing SQLite immediately — prevents event-loop blocking on N-item done callbacks.
    if (my $dc = $opts && ref $opts eq 'HASH' && $opts->{defer_cache}) {
        push @$dc, {
            url      => $spoton_url,
            title    => $title,
            artist   => $artist,
            album    => $album,
            duration => $duration,
            cover    => $image,
            icon     => $image,
            track    => $track,    # kept for _extractTrackIds (encode_json deferred to flush)
            client   => $client,
        };
    } else {
        my %trackIds = _extractTrackIds($track);
        $cache->set('spoton_meta_' . md5_hex($spoton_url), {
            title     => $title,
            artist    => $artist,
            album     => $album,
            duration  => $duration,
            cover     => $image,
            icon      => $image,
            bitrate   => __PACKAGE__->_bitrateForClient($client) . 'k',
            type      => __PACKAGE__->_typeString($client, 'Browse'),
            %trackIds,
        }, 604800);
    }

    my %item = (
        name          => "$title \x{2014} $artist",    # em-dash fallback for older clients
        title         => $title,
        artist        => $artist,
        album         => $album,
        line1         => $title,
        line2         => $artist . ($album ? " \x{2022} $album" : ''),
        url           => $spoton_url,
        play          => $spoton_url,
        on_select     => 'play',
        playall       => 1,    # Context queueing (D-09/D-10) — XMLBrowser enqueues all feed items
        image         => $image,
        duration      => $duration,
        type          => 'audio',
        # spoton:// URL for LMS Favorites playback
        favorites_url => $spoton_url,
    );
    $item{items} = \@contextItems if @contextItems;

    return \%item;
}

# _albumItem($client, $album)
# Builds an OPML link item for album navigation.
# url => \&_albumFeed is defined in Plan 03-03 (resolved at runtime by Perl).
sub _albumItem {
    my ($client, $album) = @_;
    my $firstArtist = ($album->{artists} && @{$album->{artists}})
        ? $album->{artists}[0]{name}
        : '';
    my $releaseDate = $album->{release_date} // '';
    my $line2 = $firstArtist . ($releaseDate ? " ($releaseDate)" : '');

    # spoton:// URL for LMS Favorites playback (explodePlaylist resolves to tracks)
    my $album_spoton = 'spoton://album:' . ($album->{id} // '');

    return {
        name          => $album->{name} // '',
        url           => \&_albumFeed,
        passthrough   => [{ albumId => $album->{id}, albumImages => $album->{images}, albumArtist => $firstArtist, albumName => $album->{name} }],
        image         => _largestImage($album->{images}),
        line2         => $line2,
        favorites_url => $album_spoton,
        type          => 'playlist',
    };
}

# _artistItem($client, $artist)
# Builds an OPML link item for artist navigation.
# url => \&_artistFeed is defined in Plan 03-03 (resolved at runtime by Perl).
sub _artistItem {
    my ($client, $artist) = @_;
    return {
        name        => $artist->{name} // '',
        url         => \&_artistFeed,               # defined in Plan 03-03
        passthrough => [{ artistId => $artist->{id} }],
        image       => _largestImage($artist->{images}),
        type        => 'link',
    };
}

# _playlistItem($client, $playlist)
# Builds an OPML link item for playlist navigation.
# url => \&_playlistFeed is defined in Plan 03-03 (resolved at runtime by Perl).
sub _playlistItem {
    my ($client, $playlist) = @_;
    # spoton:// URL for LMS Favorites playback (explodePlaylist resolves to tracks)
    my $pl_spoton = 'spoton://playlist:' . ($playlist->{id} // '');

    return {
        name          => $playlist->{name} // '',
        url           => \&_playlistFeed,
        passthrough   => [{ playlistId => $playlist->{id} }],
        image         => _largestImage($playlist->{images}),
        line2         => $playlist->{owner}{display_name} // '',
        favorites_url => $pl_spoton,
        type          => 'playlist',
    };
}

# ============================================================
# Home Feed (D-02)
# ============================================================

# _homeFeed($client, $callback, $args)
# Returns three navigation items: Recently Played, Made For You, Top Tracks.
# Per D-02: each item opens its own sub-feed.
sub _homeFeed {
    my ($client, $callback, $args) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_SPOTON_RECENTLY_PLAYED'),
            url  => \&_recentlyPlayedFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_MADE_FOR_YOU'),
            url  => \&_madeForYouFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_TOP_TRACKS'),
            url  => \&_topTracksFeed,
            type => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _recentlyPlayedFeed($client, $callback, $args)
# Fetches recently played tracks via cursor-based API (no offset — Pitfall 4).
# Single-page response; no total field.
sub _recentlyPlayedFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getRecentlyPlayed($accountId, { limit => 50 }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _trackItem($client, $_->{track}) } @{ $data->{items} || [] };
        $callback->({ items => \@items });
    });
}

# Priority tiers for Made For You sorting (matched against English names).
my @MFY_PRIORITY = (
    qr/^daylist$/i,
    qr/^Discover Weekly$/i,
    qr/^Release Radar$/i,
    qr/^Daily Mix \d+$/i,
    qr/^On Repeat$/i,
    qr/^Repeat Rewind$/i,
);

sub _madeForYouPriority {
    my ($name) = @_;
    for my $i (0 .. $#MFY_PRIORITY) {
        return $i if $name =~ $MFY_PRIORITY[$i];
    }
    return scalar @MFY_PRIORITY;
}

# _fetchAllPersonalMixes($accountId, $locale, $cb)
# Fetches all pages of personal mixes. $locale is optional (undef = user default).
# Calls $cb->(\@playlists) with valid (non-null) items from all pages.
sub _fetchAllPersonalMixes {
    my ($accountId, $locale, $cb) = @_;
    my %params = (limit => 50);
    $params{_locale} = $locale if $locale;

    Plugins::SpotOn::API::Client->getPersonalMixes($accountId, \%params, sub {
        my $data = shift;
        my $items = $data && $data->{playlists} ? $data->{playlists}{items} : [];
        my @valid = grep { $_ && $_->{id} && ($_->{name} // '') =~ /\S/ } @$items;
        my $total = $data && $data->{playlists} ? ($data->{playlists}{total} || 0) : 0;

        if ($total > 50) {
            my %p2 = (limit => 50, offset => 50);
            $p2{_locale} = $locale if $locale;
            Plugins::SpotOn::API::Client->getPersonalMixes($accountId, \%p2, sub {
                my $page2 = shift;
                if ($page2 && $page2->{playlists} && $page2->{playlists}{items}) {
                    push @valid, grep { $_ && $_->{id} && ($_->{name} // '') =~ /\S/ } @{ $page2->{playlists}{items} };
                }
                $cb->(\@valid);
            });
        } else {
            $cb->(\@valid);
        }
    });
}

# _madeForYouFeed($client, $callback, $args)
# Fetches personal mixes in two parallel requests: localized (for display) and
# English (for locale-independent sorting). Merges by playlist ID.
sub _madeForYouFeed {
    my ($client, $callback, $args) = @_;
    my $accountId = _getAccountId($client);

    my ($localized, %en_names);
    my $pending = 2;

    my $merge = sub {
        return if --$pending > 0;

        unless ($localized && @$localized) {
            $callback->({ items => [{ name => cstring($client,
                'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my @sorted = sort {
            _madeForYouPriority($en_names{$a->{id}} // $a->{name} // '')
            <=>
            _madeForYouPriority($en_names{$b->{id}} // $b->{name} // '')
        } @$localized;

        my @items = map { _playlistItem($client, $_) } @sorted;
        $callback->({ items => \@items });
    };

    _fetchAllPersonalMixes($accountId, undef, sub {
        $localized = shift;
        $merge->();
    });

    _fetchAllPersonalMixes($accountId, 'en', sub {
        my $en = shift || [];
        %en_names = map { $_->{id} => $_->{name} } @$en;
        $merge->();
    });
}

# _topTracksFeed($client, $callback, $args)
# Fetches user's top tracks with time_range=medium_term per D-05.
sub _topTracksFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getTopTracks($accountId, {
        time_range => 'medium_term',
        limit      => 50,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _trackItem($client, $_) } @{ $data->{items} || [] };
        $callback->({ items => \@items });
    });
}

# ============================================================
# Library Feed (D-03)
# ============================================================

# _libraryFeed($client, $callback, $args)
# Returns four navigation items: Liked Songs, Albums, Artists, Playlists.
# Per D-03: Made-For-You playlists excluded from Playlists entry.
sub _libraryFeed {
    my ($client, $callback, $args) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_SPOTON_LIKED_SONGS'),
            url  => \&_savedTracksFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
            url  => \&_savedAlbumsFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_ARTISTS'),
            url  => \&_followedArtistsFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_PLAYLISTS'),
            url  => \&_userPlaylistsFeed,
            type => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _savedTracksFeed($client, $callback, $args)
# Fetches user's liked tracks with LMS OPMLBased offset/limit pagination mapping.
# Per NAV-08: unconditional access (no gating).
# Per NAV-09: API default sort is added_at desc (recently added first).
# Per D-12: LMS index/quantity mapped to Spotify offset/limit.
# Play-all detection: if $qty >= 500 AND $offset == 0, fetches ALL tracks via _fetchAllPages.
sub _savedTracksFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;    # Spotify Library max = 50

    my $accountId = _getAccountId($client);

    my $cacheKey = "savedTracks:$accountId";

    if ($qty >= 500 && $offset == 0) {
        # Play-all mode: fetch all liked tracks via full pagination
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => sub {
                my ($acct, $params, $cb) = @_;
                Plugins::SpotOn::API::Client->getSavedTracks($acct, $params, $cb);
            },
            pageLimit    => 50,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems) = @_;
                # FIX-01: defer metadata cache writes to avoid blocking event loop
                # with N synchronous SQLite INSERTs before callback fires.
                my @deferredMeta;
                my @items = map  { _trackItem($client, $_->{track}, { defer_cache => \@deferredMeta }) }
                            grep { defined $_->{track} }
                            @{$allItems};
                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }
                $_playAllItemCache{$cacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
                # Flush deferred metadata cache writes in background (50 per event-loop tick).
                _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
            },
        });
    } elsif (my $cached = $_playAllItemCache{$cacheKey}) {
        if (time() - $cached->{ts} < 120 && $offset < scalar @{$cached->{items}}) {
            my $end = $offset + $qty - 1;
            $end = $#{ $cached->{items} } if $end > $#{ $cached->{items} };
            my @slice = @{ $cached->{items} }[$offset .. $end];
            $callback->({ items => \@slice, offset => $offset, total => scalar @{$cached->{items}} });
            return;
        }
        delete $_playAllItemCache{$cacheKey};
        goto &_savedTracksFeed;  # re-enter with same @_ after cache eviction
    } else {
        Plugins::SpotOn::API::Client->getSavedTracks($accountId, {
            offset => $offset,
            limit  => $limit,
        }, sub {
            my $data = shift;
            unless ($data) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }
            my @items = map { _trackItem($client, $_->{track}) } @{ $data->{items} || [] };
            $callback->({ items => \@items, offset => $offset, total => $data->{total} });
        });
    }
}

# _savedAlbumsFeed($client, $callback, $args)
# Fetches user's saved albums with LMS OPMLBased pagination mapping.
sub _savedAlbumsFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getSavedAlbums($accountId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _albumItem($client, $_->{album}) } @{ $data->{items} || [] };
        $callback->({ items => \@items, offset => $offset, total => $data->{total} });
    });
}

# _followedArtistsFeed($client, $callback, $args)
# Fetches ALL followed artists by chaining cursor-based API calls.
# Spotify's /me/following uses cursor pagination (no offset — Pitfall 4/7).
# We fetch 50 at a time until no more cursors remain, then return all at once.
sub _followedArtistsFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    _fetchAllFollowedArtists($client, $accountId, undef, [], sub {
        my ($allArtists) = @_;
        my @items = map { _artistItem($client, $_) } @{$allArtists};
        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }
        $callback->({ items => \@items });
    });
}

sub _fetchAllFollowedArtists {
    my ($client, $accountId, $after, $accumulated, $done) = @_;

    my %params = (limit => 50);
    $params{after} = $after if defined $after;

    Plugins::SpotOn::API::Client->getFollowedArtists($accountId, \%params, sub {
        my $data = shift;
        unless ($data) {
            $done->($accumulated);
            return;
        }
        my $artists = $data->{artists}{items} || [];
        push @{$accumulated}, @{$artists};

        my $nextCursor = $data->{artists}{cursors}{after} // '';
        if ($nextCursor ne '' && @{$artists} > 0) {
            _fetchAllFollowedArtists($client, $accountId, $nextCursor, $accumulated, $done);
        } else {
            $done->($accumulated);
        }
    });
}

# ============================================================
# Reusable Async Paginator (Play-All Full Pagination)
# ============================================================

# _fetchAllPages($args)
# Reusable async paginator for offset-based Spotify API endpoints.
# Fetches all pages recursively and calls $args->{done} with the full accumulated items.
#
# $args keys:
#   accountId    - Spotify account ID
#   apiFn        - coderef: $apiFn->($accountId, $params, $cb)
#                  $params contains offset and limit; $cb receives ($data)
#   pageLimit    - max items per API page (50 for tracks/albums/episodes, 100 for playlist items)
#   extractItems - coderef: $extractItems->($data) returns arrayref of raw items
#                  Default: sub { $_[0]->{items} || [] }
#   done         - callback: $done->(\@accumulated) called when all pages fetched
#
# T-25-01: Guards against infinite recursion — stops when current page returns 0 items,
# regardless of what the total field says. Prevents infinite loop on API inconsistencies.
sub _fetchAllPages {
    my ($args) = @_;

    _evictPlayAllCache();

    my $accountId    = $args->{accountId};
    my $apiFn        = $args->{apiFn};
    my $pageLimit    = $args->{pageLimit}    || 50;
    my $extractItems = $args->{extractItems} || sub { $_[0]->{items} || [] };
    my $done         = $args->{done};

    my @accumulated;

    my $fetchPage;
    $fetchPage = sub {
        my ($offset) = @_;
        $apiFn->($accountId, { offset => $offset, limit => $pageLimit }, sub {
            my $data = shift;
            unless ($data) {
                undef $fetchPage;
                $done->(\@accumulated);
                return;
            }
            my $items = $extractItems->($data);
            push @accumulated, @{$items};

            my $total = $data->{total} // 0;
            # T-25-01: stop if current page returned no items (prevents infinite loop)
            if (scalar(@accumulated) < $total && @{$items} > 0) {
                $fetchPage->(scalar(@accumulated));
            } else {
                undef $fetchPage;
                $done->(\@accumulated);
            }
        });
    };

    $fetchPage->(0);
}

# _userPlaylistsFeed($client, $callback, $args)
# Fetches user's playlists, excluding Made-For-You playlists (per D-03).
# Note: total from API includes Made-For-You playlists so displayed count may be
# slightly off — this is an accepted limitation documented in the plan (must_haves).
sub _userPlaylistsFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getUserPlaylists($accountId, {
        offset => $offset,
        limit  => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        # D-03: Exclude Made-For-You playlists from Library Playlists
        my @user  = grep { !_isMadeForYou($_) } @{ $data->{items} || [] };
        my @items = map  { _playlistItem($client, $_) } @user;
        $callback->({ items => \@items, offset => $offset, total => $data->{total} });
    });
}

# ============================================================
# Podcast Feeds (POD-01, POD-02, POD-03, NAV-01, NAV-02)
# ============================================================

# _podcastsFeed($client, $callback, $args)
# Top-level Podcasts menu container.
# Per NAV-01: top-level entry after Bibliothek.
# Shows two items: "Meine Podcasts" (link) and "Podcast-Suche" (search input).
sub _podcastsFeed {
    my ($client, $callback, $args) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_SPOTON_MY_PODCASTS'),
            url  => \&_savedShowsFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'PLUGIN_SPOTON_PODCAST_SEARCH'),
            url  => \&_podcastSearchFeed,
            type => 'search',
        },
    );

    $callback->({ items => \@items });
}

# _savedShowsFeed($client, $callback, $args)
# Paginated list of user's saved podcast shows.
# Per POD-01: uses getSavedShows with OPMLBased offset/limit pagination.
# Per D-03 (Pitfall 1): API response wraps show under {show} key.
sub _savedShowsFeed {
    my ($client, $callback, $args) = @_;

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;    # Spotify /me/shows max = 50

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getSavedShows($accountId, {
        offset   => $offset,
        limit    => $limit,
        _noCache => 1,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        # Pitfall 1: items are [{ added_at: "...", show: {...} }] — must unwrap {show}
        # CR-01: null-show guard — same pattern as _playlistFeed (line 1719-1721)
        my @items = map  { _showItem($client, $_->{show}) }
                    grep { defined $_->{show} }
                    @{ $data->{items} || [] };
        $callback->({ items => \@items, offset => $offset, total => $data->{total} });
    });
}

# _showItem($client, $show)
# Builds an OPML item for a podcast show.
# Per D-01: line2 = publisher. Per D-04: largest image.
# type='playlist' (not 'link') so LMS Default skin renders line2.
# Passthrough carries showImages for episode artwork fallback (D-08).
sub _showItem {
    my ($client, $show) = @_;
    my $name      = $show->{name}      // '';
    my $publisher = $show->{publisher} // '';
    # spoton:// URL for LMS Favorites playback (explodePlaylist resolves to episodes)
    my $show_spoton = 'spoton://show:' . ($show->{id} // '');

    return {
        name          => $name . ($publisher ? " \x{b7} $publisher" : ''),
        line1         => $name,
        line2         => $publisher,
        url           => \&_showFeed,
        passthrough   => [{ showId => $show->{id}, showUri => $show->{uri}, showImages => $show->{images}, showName => $name }],
        image         => _largestImage($show->{images}),
        favorites_url => $show_spoton,
        type          => 'playlist',
    };
}

# _showFeed($client, $callback, $args, $passthrough)
# Paginated episode list for a podcast show.
# Per POD-02: always uses getShowEpisodes (no embedded-episodes shortcut).
# Per Pitfall 2: response is { items, total } directly, not nested.
# Per D-09: API default order is newest first.
# Play-all detection: if $qty >= 500 AND $offset == 0, fetches ALL episodes via _fetchAllPages.
# In play-all mode, the Follow button is excluded (not a playable item).
sub _showFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $showId     = $passthrough->{showId}     // '';
    my $showUri    = $passthrough->{showUri}     // "spotify:show:$showId";
    my $showImages = $passthrough->{showImages};

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);
    my $hasFollowItem = ($accountId && $showUri =~ /^spotify:show:[A-Za-z0-9]+$/) ? 1 : 0;

    my $showCacheKey = "showEpisodes:$accountId:$showId";

    if ($qty >= 500 && $offset == 0) {
        # Play-all mode: fetch all episodes via full pagination, no Follow button
        my $showCtx = { images => $showImages, id => $showId, uri => $showUri, name => $passthrough->{showName} // '' };
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => sub {
                my ($acct, $params, $cb) = @_;
                Plugins::SpotOn::API::Client->getShowEpisodes($acct, $showId, $params, $cb);
            },
            pageLimit    => 50,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems) = @_;
                my @items = map { _episodeItem($client, $_, $showCtx) } @{$allItems};
                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }
                $_playAllItemCache{$showCacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
            },
        });
    } elsif (my $cached = $_playAllItemCache{$showCacheKey}) {
        if (time() - $cached->{ts} < 120 && $offset < scalar @{$cached->{items}}) {
            my $end = $offset + $qty - 1;
            $end = $#{ $cached->{items} } if $end > $#{ $cached->{items} };
            my @slice = @{ $cached->{items} }[$offset .. $end];
            $callback->({ items => \@slice, offset => $offset, total => scalar @{$cached->{items}} });
            return;
        }
        delete $_playAllItemCache{$showCacheKey};
        goto &_showFeed;  # re-enter with same @_ after cache eviction
    } else {
        # Offset correction: index 0 = Follow button, index N (N>0) = episode at API offset N-1
        my $apiOffset = ($hasFollowItem && $offset > 0) ? $offset - 1 : $offset;
        my $apiLimit  = ($hasFollowItem && $offset == 0 && $limit > 1) ? $limit - 1 : $limit;

        Plugins::SpotOn::API::Client->getShowEpisodes($accountId, $showId, {
            offset => $apiOffset,
            limit  => $apiLimit,
        }, sub {
            my $data = shift;
            unless ($data) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }
            my $showCtx = { images => $showImages, id => $showId, uri => $showUri, name => $passthrough->{showName} // '' };
            my @items = map { _episodeItem($client, $_, $showCtx) } @{ $data->{items} || [] };
            if (!@items && !$hasFollowItem) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            if ($hasFollowItem && $offset == 0) {
                unshift @items, {
                    name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_FOLLOW'),
                    url         => \&SpotOnManageFollow,
                    passthrough => [{ showUri => $showUri, accountId => $accountId }],
                    type        => 'link',
                    icon        => '/html/images/playlistadd.png',
                };
            }

            my $total = ($data->{total} // 0) + ($hasFollowItem ? 1 : 0);
            $callback->({ items => \@items, offset => $offset, total => $total });
        });
    }
}

# _episodeItem($client, $episode, $showContext)
# Builds an OPML audio item for a podcast episode.
# $showContext: { images, id, uri, name } — from _showFeed passthrough or $episode->{show}.
# Dev Mode strips $episode->{show} from API responses, so callers pass show data explicitly.
sub _episodeItem {
    my ($client, $episode, $showContext) = @_;

    # Normalize showContext: accept old-style $showImages arrayref or new hashref
    if ($showContext && ref $showContext eq 'ARRAY') {
        $showContext = { images => $showContext };
    }
    $showContext //= {};

    my $title    = $episode->{name}         // '';
    my $duration = ($episode->{duration_ms} || 0) / 1000;
    my $date     = $episode->{release_date} // '';

    my $explicit_tag = ($episode->{explicit})
        ? ' [' . cstring($client, 'PLUGIN_SPOTON_EXPLICIT') . ']'
        : '';

    my $showName = $showContext->{name}   // $episode->{show}{name} // '';
    my $showId   = $showContext->{id}     // $episode->{show}{id}   // '';
    my $showUri  = $showContext->{uri}    // $episode->{show}{uri}  // '';

    my $image = _largestImage($episode->{images})
             || _largestImage($showContext->{images})
             || _largestImage($episode->{show}{images});

    my $line2 = _formatEpisodeLine2($client, $duration, $date);

    my ($ep_path) = ($episode->{uri} // '') =~ /^spotify:((?:track|episode):.+)/;
    $ep_path //= ($episode->{uri} // '');
    my $spoton_url = 'spoton://' . $ep_path;

    # Sub-items for XMLBrowser info view (like tracks have Artist/Album/Like)
    # UX-05: label-bearing text items MUST come first so XMLBrowser populates $details
    # and enables Play/Queue/Favorites buttons in the Default skin info view.
    my @contextItems;
    push @contextItems, {
        name  => $showName || cstring($client, 'PLUGIN_SPOTON_PODCASTS'),
        type  => 'text',
        label => 'ARTIST',
    };
    if ($showName) {
        push @contextItems, {
            name  => $showName,
            type  => 'text',
            label => 'ALBUM',
        };
    }
    if ($showId) {
        push @contextItems, {
            name        => $showName || 'Show',
            url         => \&_showFeed,
            passthrough => [{ showId => $showId, showUri => $showUri, showImages => $showContext->{images}, showName => $showName }],
            type        => 'link',
        };
    }
    if ($showUri =~ /^spotify:show:[A-Za-z0-9]+$/) {
        my $accountId = _getAccountId($client);
        if ($accountId) {
            push @contextItems, {
                name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_FOLLOW'),
                url         => \&SpotOnManageFollow,
                passthrough => [{ showUri => $showUri, accountId => $accountId }],
                type        => 'link',
                icon        => '/html/images/playlistadd.png',
            };
        }
    }
    # UX-04: Search result episodes lack showContext — add lazy-load sub-item to fetch show data
    if (!$showId && $episode->{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_SHOW_VIEW'),
            url         => \&_episodeInfoFeed,
            passthrough => [{ episodeId => $episode->{id}, episodeUri => $episode->{uri}, line2 => $line2, durationMs => $episode->{duration_ms} || 0 }],
            type        => 'link',
        };
    }
    # Duration/date as visible sub-item — songinfo hides the parent item's line2
    push @contextItems, { name => $line2, type => 'textarea' } if $line2;

    $cache->set('spoton_meta_' . md5_hex($spoton_url), {
        title    => $title,
        artist   => $showName,
        album    => $showName,
        duration => $duration,
        cover    => $image,
        icon     => $image,
        bitrate  => __PACKAGE__->_bitrateForClient($client) . 'k',
        type     => __PACKAGE__->_typeString($client, 'Browse'),
        showId   => $showId || undef,
        showName => $showName || undef,
    }, 604800);

    my %item = (
        name          => $title . $explicit_tag,
        title         => $title,
        artist        => $showName,
        album         => $showName,
        line1         => $title . $explicit_tag,
        line2         => $line2,
        url           => $spoton_url,
        play          => $spoton_url,
        on_select     => 'play',
        image         => $image,
        duration      => $duration,
        type          => 'audio',
        # spoton:// URL for LMS Favorites playback
        favorites_url => $spoton_url,
    );
    $item{items} = \@contextItems;

    return \%item;
}

# _episodeInfoFeed($client, $callback, $args, $passthrough)
# UX-04: Lazy-load show data for search result episodes that lack showContext.
# Fetches full episode via getEpisode, extracts show info, builds navigable sub-items.
# Also surfaces resume_point data when available (UX-02).
# T-21-01: episodeId validated against ^[A-Za-z0-9]{1,40}$ before API call.
sub _episodeInfoFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $episodeId  = $passthrough->{episodeId}  // '';
    my $episodeUri = $passthrough->{episodeUri} // '';
    my $line2      = $passthrough->{line2}      // '';
    my $durationMs = $passthrough->{durationMs} // 0;
    my $accountId  = _getAccountId($client);

    # T-21-01: Validate episodeId before forwarding to API
    unless ($episodeId =~ /^[A-Za-z0-9]{1,40}$/) {
        $callback->({ items => [{ name => $line2, type => 'textarea' }] });
        return;
    }

    # Helper closure: build sub-items from show context and optional resume point
    my $buildItems = sub {
        my ($showCtx, $resumePoint) = @_;
        my @items;

        if ($showCtx && $showCtx->{id}) {
            push @items, {
                name        => $showCtx->{name} || 'Show',
                url         => \&_showFeed,
                passthrough => [{ showId => $showCtx->{id}, showUri => $showCtx->{uri}, showImages => $showCtx->{images}, showName => $showCtx->{name} }],
                type        => 'link',
            };
        }

        if ($showCtx && ($showCtx->{uri} // '') =~ /^spotify:show:[A-Za-z0-9]+$/ && $accountId) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_MANAGE_FOLLOW'),
                url         => \&SpotOnManageFollow,
                passthrough => [{ showUri => $showCtx->{uri}, accountId => $accountId }],
                type        => 'link',
                icon        => '/html/images/playlistadd.png',
            };
        }

        # UX-02: Surface resume point status when available
        if ($resumePoint && $resumePoint->{fully_played}) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_RESUME_FINISHED'), type => 'textarea' };
        } elsif ($resumePoint && ($resumePoint->{resume_position_ms} // 0) > 0) {
            my $remaining = int(($durationMs - $resumePoint->{resume_position_ms}) / 60000);
            push @items, { name => sprintf(cstring($client, 'PLUGIN_SPOTON_RESUME_IN_PROGRESS'), $remaining), type => 'textarea' };
        }

        # Fallback: always have at least one sub-item
        push @items, { name => $line2, type => 'textarea' } unless @items;

        $callback->({ items => \@items });
    };

    # Cache check: avoid repeat API calls for the same episode
    my $cacheKey = "spoton_ep_show_$episodeId";
    if (my $cached = $cache->get($cacheKey)) {
        $buildItems->($cached, undef);
        return;
    }

    # Cache miss: fetch full episode to extract show context
    Plugins::SpotOn::API::Client->getEpisode($accountId, $episodeId, sub {
        my ($ep, $err) = @_;
        if ($ep && $ep->{show} && $ep->{show}{id}) {
            my $ctx = {
                id     => $ep->{show}{id},
                uri    => $ep->{show}{uri},
                name   => $ep->{show}{name},
                images => $ep->{show}{images},
            };
            $cache->set($cacheKey, $ctx, 300);
            my $resumePoint = $ep->{resume_point};
            $buildItems->($ctx, $resumePoint);
        } else {
            $buildItems->({}, undef);
        }
    });
}

# _formatEpisodeLine2($client, $duration_sec, $release_date)
# Builds the line2 string for episode items: "45 min · 12. Jun"
# Per D-05: duration + date separated by middle dot U+00B7.
# Per D-06: duration units via cstring (I18N-01).
# Per D-07: relative date via _formatRelativeDate.
sub _formatEpisodeLine2 {
    my ($client, $duration_sec, $release_date) = @_;

    # D-06: Human-readable duration via localized strings (I18N-01)
    my $dur_str = '';
    if ($duration_sec > 0) {
        my $hours = int($duration_sec / 3600);
        my $mins  = int(($duration_sec % 3600) / 60);
        if ($hours > 0) {
            $dur_str = sprintf(cstring($client, 'PLUGIN_SPOTON_DURATION_HM'), $hours, $mins);
        } else {
            $dur_str = sprintf(cstring($client, 'PLUGIN_SPOTON_DURATION_M'), $mins);
        }
    }

    # D-07: Relative or absolute date
    my $date_str = _formatRelativeDate($client, $release_date);

    # Combine with middle dot separator
    if ($dur_str && $date_str) {
        return "$dur_str \x{00B7} $date_str";
    }
    return $dur_str || $date_str || '';
}

# _formatRelativeDate($client, $iso_date)
# Converts an ISO date string (YYYY-MM-DD) to a relative or absolute localized date.
# Per D-07: "Today", "Yesterday", "N days ago", then "14. Jun", "14. Jun 2025".
# Per Pitfall 5: timelocal wrapped in eval; regex guard against partial dates.
# I18N-01: all user-visible strings via cstring().
sub _formatRelativeDate {
    my ($client, $iso_date) = @_;
    return '' unless $iso_date && $iso_date =~ /^(\d{4})-(\d{2})-(\d{2})/;

    my ($year, $month, $day) = ($1, $2, $3);
    $day   += 0;  # Strip leading zero for display ("03" -> 3)
    $month += 0;

    # Current date via localtime
    my @now         = localtime(time);
    my $today_year  = $now[5] + 1900;
    my $today_month = $now[4] + 1;
    my $today_day   = $now[3];

    # Delta in days (Pitfall 5: eval guard for invalid dates)
    my $ep_time    = eval { timelocal(0, 0, 12, $day, $month - 1, $year) } // 0;
    my $today_time = eval { timelocal(0, 0, 12, $today_day, $today_month - 1, $today_year) } // 0;
    my $delta_days = ($ep_time && $today_time)
        ? int(($today_time - $ep_time) / 86400)
        : -1;

    if ($delta_days == 0) { return cstring($client, 'PLUGIN_SPOTON_DATE_TODAY') }
    if ($delta_days == 1) { return cstring($client, 'PLUGIN_SPOTON_DATE_YESTERDAY') }
    if ($delta_days >= 2 && $delta_days <= 6) { return sprintf(cstring($client, 'PLUGIN_SPOTON_DATE_N_DAYS_AGO'), $delta_days) }

    # Absolute date with localized month abbreviations (I18N-01: via cstring)
    my $mon_str = cstring($client, "PLUGIN_SPOTON_MONTH_$month");

    if ($year == $today_year) {
        return "$day. $mon_str";
    } else {
        return "$day. $mon_str $year";
    }
}

# Podcast Search (NAV-03, SRC-01, SRC-02, SRC-03, D-10/D-11/D-12)

# _podcastSearchFeed($client, $callback, $args)
# Entry point for podcast text search. LMS passes query in $args->{search}.
# Per D-10: full search in Phase 19. Per D-11: separate Show/Episode result sections.
# Per D-12: limit=10 (Dev Mode). No top-result (simpler than global search).
sub _podcastSearchFeed {
    my ($client, $callback, $args) = @_;

    my $query = $args->{search} // '';
    if ($query eq '') {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
        return;
    }

    my $accountId = _getAccountId($client);

    # Single API call for combined show+episode counts
    Plugins::SpotOn::API::Client->search($accountId, {
        q      => $query,
        type   => 'show,episode',
        limit  => 50,
        offset => 0,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my @items;

        my $showsTotal    = $data->{shows}{total}    // 0;
        my $episodesTotal = $data->{episodes}{total} // 0;

        if ($showsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_SHOWS'),
                url         => \&_podcastSearchTypeFeed,
                passthrough => [{ query => $query, type => 'show' }],
                type        => 'link',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $showsTotal),
            };
        }
        if ($episodesTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_EPISODES'),
                url         => \&_podcastSearchTypeFeed,
                passthrough => [{ query => $query, type => 'episode' }],
                type        => 'link',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $episodesTotal),
            };
        }

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items });
    });
}

# _podcastSearchTypeFeed($client, $callback, $args, $passthrough)
# Typed search result list for shows or episodes.
# Per D-12: limit capped at 10 (Dev Mode). Dispatches to _showItem or _episodeItem.
# Per Pitfall 4: episode search results use $episode->{show}{images} as artwork fallback.
sub _podcastSearchTypeFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $query  = $passthrough->{query} // '';
    my $type   = $passthrough->{type}  // 'show';

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => $query,
        type   => $type,
        limit  => 50,
        offset => 0,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my %typeToKey = (show => 'shows', episode => 'episodes');
        my $key      = $typeToKey{$type} // "${type}s";
        my $typeData = $data->{$key} || {};
        my $results  = $typeData->{items} || [];

        my @items;
        if ($type eq 'show') {
            @items = map { _showItem($client, $_) } @{$results};
        } elsif ($type eq 'episode') {
            @items = map { _episodeItem($client, $_, undef) } @{$results};
        }

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items });
    });
}

# ============================================================
# Search Feeds (NAV-04, NAV-11, D-10)
# ============================================================

# _searchFeed($client, $callback, $args)
# Entry point for the Search type item. LMS passes the search query in $args->{search}.
# Per D-10: Top Result shown prominently above category sections.
# Categories with 0 results are hidden entirely (D-10).
# Per NAV-11: limit=10 per type (Dev Mode maximum).
sub _searchFeed {
    my ($client, $callback, $args) = @_;

    my $query = $args->{search} // '';
    if ($query eq '') {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
        return;
    }

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => $query,
        type   => 'track,album,artist,playlist',
        limit  => 50,
        offset => 0,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my @items;

        # D-10: Top Result — first track from search results, shown inline (not as sub-menu).
        my $trackItems = $data->{tracks}{items} || [];
        if (@{$trackItems}) {
            my $topTrack = $trackItems->[0];
            push @items, {
                name  => cstring($client, 'PLUGIN_SPOTON_TOP_RESULT'),
                items => [ _trackItem($client, $topTrack) ],
                type  => 'outline',
            };
        }

        # Category sections — skip those with 0 results (D-10).
        my $tracksTotal    = $data->{tracks}{total}    // 0;
        my $albumsTotal    = $data->{albums}{total}    // 0;
        my $artistsTotal   = $data->{artists}{total}   // 0;
        my $playlistsTotal = $data->{playlists}{total} // 0;

        if ($tracksTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_TRACKS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'track' }],
                type        => 'link',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $tracksTotal),
            };
        }
        if ($albumsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'album' }],
                type        => 'link',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $albumsTotal),
            };
        }
        if ($artistsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ARTISTS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'artist' }],
                type        => 'link',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $artistsTotal),
            };
        }
        if ($playlistsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_PLAYLISTS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'playlist' }],
                type        => 'link',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $playlistsTotal),
            };
        }

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items });
    });
}

# _searchTypeFeed($client, $callback, $args, $passthrough)
# Paginated drill-down into a single search type (track, album, artist, or playlist).
# Per NAV-11: limit capped at 10 (Dev Mode). Maps LMS index/quantity to offset/limit.
sub _searchTypeFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $query  = $passthrough->{query} // '';
    my $type   = $passthrough->{type}  // 'track';

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->search($accountId, {
        q      => $query,
        type   => $type,
        limit  => 50,
        offset => 0,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }

        my %typeToKey = (
            track    => 'tracks',
            album    => 'albums',
            artist   => 'artists',
            playlist => 'playlists',
        );
        my $key       = $typeToKey{$type} // "${type}s";
        my $typeData  = $data->{$key} || {};
        my $resultItems = $typeData->{items} || [];

        my @valid = grep { $_->{name} && $_->{name} =~ /\S/ } @{$resultItems};

        my @items;
        if ($type eq 'track') {
            @items = map { _trackItem($client, $_) } @valid;
        } elsif ($type eq 'album') {
            @items = map { _albumItem($client, $_) } @valid;
        } elsif ($type eq 'artist') {
            @items = map { _artistItem($client, $_) } @valid;
        } elsif ($type eq 'playlist') {
            @items = map { _playlistItem($client, $_) } @valid;
        }

        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }

        $callback->({ items => \@items });
    });
}

# ============================================================
# Artist Detail Feeds (NAV-05, D-09)
# ============================================================

# _artistFeed($client, $callback, $args, $passthrough)
# Returns four navigation sections for an artist's discography.
# Per D-09: Albums, Singles, Compilations, Appears On — NO Top Tracks, NO Related Artists
# (both removed in Dev Mode as of Feb 2026 / Nov 2024).
sub _artistFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $artistId = $passthrough->{artistId} // '';

    my @items = (
        {
            name        => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'album' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_SINGLES'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'single' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_COMPILATIONS'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'compilation' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_APPEARS_ON'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'appears_on' }],
            type        => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _artistAlbumsFeed($client, $callback, $args, $passthrough)
# Fetches paginated albums for an artist filtered by a SINGLE include_groups value.
# Per D-09/Pitfall 1: never combine include_groups values — issues separate request per type.
sub _artistAlbumsFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $artistId      = $passthrough->{artistId}      // '';
    my $includeGroups = $passthrough->{includeGroups} // 'album';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::Client->getArtistAlbums($accountId, $artistId, {
        include_groups => $includeGroups,
        offset         => $offset,
        limit          => $limit,
    }, sub {
        my $data = shift;
        unless ($data) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
            return;
        }
        my @items = map { _albumItem($client, $_) } @{ $data->{items} || [] };
        if (!@items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        }
        $callback->({ items => \@items, offset => $offset, total => $data->{total} // 0 });
    });
}

# ============================================================
# Album Detail Feed (NAV-06)
# ============================================================

# _albumFeed($client, $callback, $args, $passthrough)
# Shows numbered tracklist for an album.
# Per NAV-06: line1 = "$track_number. $title", line2 = featuring artists (if differ from album artist).
# For index=0 (browse): uses tracks embedded in getAlbum response.
# For index>0 (browse): fetches separate getAlbumTracks page.
# Play-all detection: if $qty >= 500 AND $offset == 0, fetches ALL tracks via _fetchAllPages,
# seeding the accumulator with the first-page tracks already in the getAlbum response.
# Album artwork and artist are passed via passthrough for subsequent pages.
sub _albumFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $albumId      = $passthrough->{albumId}      // '';
    my $albumImages  = $passthrough->{albumImages};    # undef on first load
    my $albumArtist  = $passthrough->{albumArtist}  // '';
    my $albumName    = $passthrough->{albumName}    // '';    # WR-01: carried for metadata cache

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 50 ? 50 : $qty;

    my $accountId = _getAccountId($client);
    my $albumCacheKey = "album:$accountId:$albumId";

    if ($qty >= 500 && $offset == 0) {
        # Play-all mode: first fetch full album for metadata + seed tracks, then paginate remaining
        Plugins::SpotOn::API::Client->getAlbum($accountId, $albumId, sub {
            my $album = shift;
            unless ($album) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my $images      = $album->{images}           || [];
            my $artist0     = ($album->{artists} && @{$album->{artists}}) ? $album->{artists}[0]{name} : '';
            my $total       = ($album->{tracks} && $album->{tracks}{total}) ? $album->{tracks}{total} : 0;
            my $seedTracks  = ($album->{tracks} && $album->{tracks}{items}) ? $album->{tracks}{items} : [];
            my $albumNm     = $album->{name} // '';

            if ($total <= scalar(@{$seedTracks})) {
                # All tracks already in getAlbum response — no further API calls needed
                # FIX-01: defer metadata cache writes.
                my @deferredMeta;
                my @items = map { _albumTrackItem($client, $_, $images, $artist0, $albumNm, { defer_cache => \@deferredMeta }) } @{$seedTracks};
                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }
                $_playAllItemCache{$albumCacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
                _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
                return;
            }

            # Seed accumulator with first-page tracks from getAlbum, then fetch remaining pages
            my @accumulated = @{$seedTracks};
            my $startOffset = scalar(@accumulated);

            my $fetchPage;
            $fetchPage = sub {
                my ($pageOffset) = @_;
                Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, {
                    offset => $pageOffset,
                    limit  => 50,
                }, sub {
                    my $data = shift;
                    unless ($data) {
                        undef $fetchPage;
                        # FIX-01: defer metadata cache writes.
                        my @deferredMeta;
                        my @items = map { _albumTrackItem($client, $_, $images, $artist0, $albumNm, { defer_cache => \@deferredMeta }) } @accumulated;
                        if (!@items) {
                            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                        }
                        $_playAllItemCache{$albumCacheKey} = { items => \@items, ts => time() };
                        $callback->({ items => \@items });
                        _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
                        return;
                    }
                    my $pageItems = $data->{items} || [];
                    push @accumulated, @{$pageItems};
                    # T-25-01: stop if current page returned no items
                    if (scalar(@accumulated) < $total && @{$pageItems} > 0) {
                        $fetchPage->(scalar(@accumulated));
                    } else {
                        undef $fetchPage;
                        # FIX-01: defer metadata cache writes.
                        my @deferredMeta;
                        my @items = map { _albumTrackItem($client, $_, $images, $artist0, $albumNm, { defer_cache => \@deferredMeta }) } @accumulated;
                        if (!@items) {
                            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                        }
                        $_playAllItemCache{$albumCacheKey} = { items => \@items, ts => time() };
                        $callback->({ items => \@items });
                        _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
                    }
                });
            };
            $fetchPage->($startOffset);
        });
    } elsif (my $cached = $_playAllItemCache{$albumCacheKey}) {
        if (time() - $cached->{ts} < 120 && $offset < scalar @{$cached->{items}}) {
            my $end = $offset + $qty - 1;
            $end = $#{ $cached->{items} } if $end > $#{ $cached->{items} };
            my @slice = @{ $cached->{items} }[$offset .. $end];
            $callback->({ items => \@slice, offset => $offset, total => scalar @{$cached->{items}} });
            return;
        }
        delete $_playAllItemCache{$albumCacheKey};
        goto &_albumFeed;  # re-enter with same @_ after cache eviction
    } elsif ($offset == 0) {
        # Initial browse load: fetch full album (includes first page of tracks in tracks.items).
        Plugins::SpotOn::API::Client->getAlbum($accountId, $albumId, sub {
            my $album = shift;
            unless ($album) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my $images   = $album->{images}           || [];
            my $artist0  = ($album->{artists} && @{$album->{artists}}) ? $album->{artists}[0]{name} : '';
            my $total    = ($album->{tracks} && $album->{tracks}{total}) ? $album->{tracks}{total} : 0;
            my $tracks   = ($album->{tracks} && $album->{tracks}{items}) ? $album->{tracks}{items} : [];

            my @items = map { _albumTrackItem($client, $_, $images, $artist0, $album->{name}) } @{$tracks};

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, offset => 0, total => $total });
        });
    } else {
        # Subsequent browse pages: use getAlbumTracks with correct offset.
        Plugins::SpotOn::API::Client->getAlbumTracks($accountId, $albumId, {
            offset => $offset,
            limit  => $limit,
        }, sub {
            my $data = shift;
            unless ($data) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my @items = map { _albumTrackItem($client, $_, $albumImages, $albumArtist, $albumName) } @{ $data->{items} || [] };

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, offset => $offset, total => $data->{total} // 0 });
        });
    }
}

# _albumTrackItem($client, $track, $albumImages, $albumArtist, $albumName)
# Builds a track item in album context.
# line1: "$track_number. $title" per NAV-06.
# line2: featuring artists — shown only if they differ from the album's primary artist.
# Album images passed from the getAlbum call since simplified track objects lack images.
# WR-01: $albumName passed from caller for metadata cache (simplified track objects lack album name).
# FIX-01: $opts->{defer_cache} — same deferred write protocol as _trackItem.
sub _albumTrackItem {
    my ($client, $track, $albumImages, $albumArtist, $albumName, $opts) = @_;

    my $trackNum  = $track->{track_number} // '';
    my $title     = $track->{name}         // '';
    my $artists   = join(', ', map { $_->{name} } @{ $track->{artists} || [] });
    my $image     = _largestImage($albumImages);
    my $duration  = ($track->{duration_ms} || 0) / 1000;

    # Show featuring artists in line2 only when they differ from album's primary artist.
    my $line2 = ($artists && $artists ne ($albumArtist // '')) ? $artists : '';

    # Context navigation: artist view (no album view — already in album context).
    my @contextItems;
    if ($track->{artists} && @{ $track->{artists} } && $track->{artists}[0]{id}) {
        push @contextItems, {
            name        => cstring($client, 'PLUGIN_SPOTON_ARTIST_VIEW'),
            url         => \&_artistFeed,
            passthrough => [{ artistId => $track->{artists}[0]{id} }],
            type        => 'link',
        };
    }

    # T-04.1-01: Extract path from Spotify URI to prevent double-prefix.
    # spotify:track:ID -> track:ID; fallback preserves original URI if no match.
    my ($track_path) = ($track->{uri} // '') =~ /^spotify:((?:track|episode):.+)/;
    $track_path //= ($track->{uri} // '');
    my $spoton_url = 'spoton://' . $track_path;

    # Cache metadata for getMetadataFor (STR-03): NowPlaying artwork + title display.
    # WR-01: Album name passed from caller; fallback to empty if undef (e.g., future callers).
    $albumName //= '';
    # D-02: 7-day TTL (604800s) so Browse tracks survive in history for a week
    # WR-01: include artist/album IDs so trackInfoMenu can build navigation items.
    # FIX-01: defer to background flush when in play-all mode.
    if (my $dc = $opts && ref $opts eq 'HASH' && $opts->{defer_cache}) {
        push @$dc, {
            url      => $spoton_url,
            title    => $title,
            artist   => $artists,
            album    => $albumName,
            duration => $duration,
            cover    => $image,
            icon     => $image,
            track    => $track,
            client   => $client,
        };
    } else {
        my %trackIds = _extractTrackIds($track);
        $cache->set('spoton_meta_' . md5_hex($spoton_url), {
            title    => $title,
            artist   => $artists,
            album    => $albumName,
            duration => $duration,
            cover    => $image,
            icon     => $image,
            bitrate  => __PACKAGE__->_bitrateForClient($client) . 'k',
            type     => __PACKAGE__->_typeString($client, 'Browse'),
            %trackIds,
        }, 604800);
    }

    my %item = (
        name      => ($trackNum ? "$trackNum. " : '') . $title,
        title     => $title,
        artist    => $artists,
        album     => $albumName || '',
        line1     => ($trackNum ? "$trackNum. " : '') . $title,
        line2     => $line2,
        url       => $spoton_url,
        play      => $spoton_url,
        on_select => 'play',
        playall   => 1,    # Context queueing for album track tap (D-09)
        image     => $image,
        duration  => $duration,
        type      => 'audio',
    );
    $item{items} = \@contextItems if @contextItems;

    return \%item;
}

# ============================================================
# Playlist Detail Feed (NAV-07)
# ============================================================

# _playlistFeed($client, $callback, $args, $passthrough)
# Shows paginated track list for a playlist.
# Per NAV-07: maps LMS index/quantity to Spotify offset/limit (cap 100).
# Null track entries (local files) are skipped per T-03-10.
# Made-For-You 403 fallback: undef $data returns NO_RESULTS textarea (graceful).
# Play-all detection: if $qty >= 500 AND $offset == 0, fetches ALL tracks via _fetchAllPages.
sub _playlistFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $playlistId = $passthrough->{playlistId} // '';

    my $offset = $args->{index}    || 0;
    my $qty    = $args->{quantity} || 200;
    my $limit  = $qty > 100 ? 100 : $qty;    # Spotify playlist items max = 100

    my $accountId = _getAccountId($client);

    my $plCacheKey = "playlist:$accountId:$playlistId";

    if ($qty >= 500 && $offset == 0) {
        # Play-all mode: fetch all playlist tracks via full pagination
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => sub {
                my ($acct, $params, $cb) = @_;
                Plugins::SpotOn::API::Client->getPlaylistItems($acct, $playlistId, $params, $cb);
            },
            pageLimit    => 100,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems) = @_;
                # T-03-10: Skip null track entries (local files in playlists return null track objects).
                # FIX-01: defer metadata cache writes to avoid blocking event loop with N SQLite INSERTs.
                my @deferredMeta;
                my @items = map  { _trackItem($client, $_->{track}, { defer_cache => \@deferredMeta }) }
                            grep { defined $_->{track} }
                            @{$allItems};
                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }
                $_playAllItemCache{$plCacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
                _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
            },
        });
    } elsif (my $cached = $_playAllItemCache{$plCacheKey}) {
        if (time() - $cached->{ts} < 120 && $offset < scalar @{$cached->{items}}) {
            my $end = $offset + $qty - 1;
            $end = $#{ $cached->{items} } if $end > $#{ $cached->{items} };
            my @slice = @{ $cached->{items} }[$offset .. $end];
            $callback->({ items => \@slice, offset => $offset, total => scalar @{$cached->{items}} });
            return;
        }
        delete $_playAllItemCache{$plCacheKey};
        goto &_playlistFeed;  # re-enter with same @_ after cache eviction
    } else {
        Plugins::SpotOn::API::Client->getPlaylistItems($accountId, $playlistId, {
            offset => $offset,
            limit  => $limit,
        }, sub {
            my $data = shift;
            unless ($data) {
                # Made-For-You 403 or other error — graceful fallback per RESEARCH Open Question 2.
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            # T-03-10: Skip null track entries (local files in playlists return null track objects).
            my @items = map  { _trackItem($client, $_->{track}) }
                        grep { defined $_->{track} }
                        @{ $data->{items} || [] };

            if (!@items) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            $callback->({ items => \@items, offset => $offset, total => $data->{total} // 0 });
        });
    }
}


# ============================================================
# Transcoding Engine (STR-01 through STR-08, LMS-11)
# ============================================================

sub _bitrateForClient {
    my ($class, $client) = @_;

    $client = $client->master if $client && $client->can('master');

    # Issue #97: prefer actual stream bitrate from LMS when available
    if ($client) {
        my $song = $client->playingSong();
        if ($song) {
            # streambitrate is set by LMS from the audio stream header
            my $streamBitrate = $song->streambitrate();
            if ($streamBitrate && $streamBitrate > 0) {
                # LMS reports bps, convert to kbps and round to nearest Spotify tier
                my $kbps = int($streamBitrate / 1000 + 0.5);
                return $kbps if $kbps > 0;
            }
        }
    }

    # Fallback: configured preference
    my $bitrate = $prefs->get('bitrate') || 320;
    if ($client) {
        my $override = $prefs->client($client)->get('bitrateOverride');
        $bitrate = $override if $override && $override =~ /^(?:96|160|320)$/;
    }

    return $bitrate;
}

# Return the configured bitrate preference (for daemon startup, not display)
sub _bitrateConfigForClient {
    my ($class, $client) = @_;

    $client = $client->master if $client && $client->can('master');

    my $bitrate = $prefs->get('bitrate') || 320;
    if ($client) {
        my $override = $prefs->client($client)->get('bitrateOverride');
        $bitrate = $override if $override && $override =~ /^(?:96|160|320)$/;
    }

    return $bitrate;
}

sub _typeString {
    my ($class, $client, $mode) = @_;

    $client = $client->master if $client && $client->can('master');

    my $fmt = $client
        ? ($prefs->client($client)->get('streamFormat')
           || $prefs->client($client)->get('connectOggOverride')
           || 'auto')
        : 'auto';

    # D-09: resolve via shared capability resolver for formats where
    # sync-group aggregation can change the actual daemon output.
    # 'auto': resolver determines OGG vs PCM based on player capabilities.
    # 'ogg': resolver catches sync-group downgrade (explicit OGG + hardware slave → PCM).
    # pcm/flac/mp3: always PCM in unified daemon, no sync-group concern.
    if ($fmt eq 'auto' || $fmt eq 'ogg') {
        if ($client) {
            eval {
                require Plugins::SpotOn::Unified::DaemonManager;
                $fmt = Plugins::SpotOn::Unified::DaemonManager->resolvePassthroughForClient($client)
                     ? 'ogg' : 'pcm';
            };
            if ($@) {
                main::INFOLOG && $log->is_info && $log->info("resolvePassthroughForClient failed: $@");
                $fmt = 'pcm';
            }
        } else {
            $fmt = 'pcm';
        }
    }

    my %LABEL = (ogg => 'OGG', flac => 'FLAC', mp3 => 'MP3', pcm => 'PCM');
    my $fmtLabel = $LABEL{$fmt} || uc($fmt);

    return "${fmtLabel}, SpotOn ${mode}";
}

# ============================================================
# Prefetch Hang Watchdog (Phase 27)
# ============================================================

my %_watchdogTriggerUrl;

sub _onNewSongWatchdog {
    my $request = shift;
    my $client = $request->client() || return;
    my $id = $client->id;

    Slim::Utils::Timers::killTimers($client, \&_prefetchWatchdog);
    Slim::Utils::Timers::killTimers($client, \&_prefetchHangCheck);
    delete $_watchdogTriggerUrl{$id};

    my $song = $client->playingSong();
    if (!$song) {
        if ($prefs->get('diagnosticMode')) {
            my $streaming = $client->streamingSong();
            my $sUrl = $streaming ? ($streaming->track->url || '?') : 'none';
            $log->warn("[DIAG] Watchdog: newsong but playingSong=undef (streamingSong=$sUrl) — deferring 0.5s");
        }
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, sub {
            my $c = shift;
            my $s = $c->playingSong() || return;
            my $u = $s->track->url || '';
            return unless $u =~ m{^spoton://(?!connect-)};
            my $d = $s->duration || 0;
            $log->warn("[DIAG] Watchdog: deferred newsong url=$u duration=${d}s") if $prefs->get('diagnosticMode');
            return unless $d > 0;
            Slim::Utils::Timers::setTimer($c, Time::HiRes::time() + 10, \&_prefetchWatchdog);
        });
        return;
    }
    my $url = $song->track->url || '';

    return unless $url =~ m{^spoton://(?!connect-)};

    my $duration = $song->duration || 0;

    $log->warn("[DIAG] Watchdog: newsong url=$url duration=${duration}s") if $prefs->get('diagnosticMode');

    return unless $duration > 0;

    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + 10,
        \&_prefetchWatchdog,
    );
}

sub _onModeChange {
    my $request = shift;
    my $client = $request->client() || return;
    my $id = $client->id;
    my $song = $client->playingSong();
    my $url = $song ? ($song->track->url || '') : 'none';
    return unless $url =~ m{^spoton://(?!connect-)};
    my $mode = Slim::Player::Source::playmode($client) || '?';

    if ($mode eq 'pause' && !$_pauseRequestedAt{_reapplying}) {
        $_pauseRequestedAt{$id} = Time::HiRes::time();
        Slim::Utils::Timers::killTimers($client, \&_pauseGuardCheck);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2.5, \&_pauseGuardCheck);
    } elsif ($mode eq 'play') {
        delete $_pauseRequestedAt{$id};
        Slim::Utils::Timers::killTimers($client, \&_pauseGuardCheck);
    }

    if ($prefs->get('diagnosticMode')) {
        my $guard = exists $_pauseRequestedAt{$id} ? sprintf("%.1fs ago", Time::HiRes::time() - $_pauseRequestedAt{$id}) : 'none';
        $log->warn("[DIAG] ModeChange: mode=$mode url=$url pauseGuard=$guard");
    }
}

sub _onPauseCommand {
    my $request = shift;
    my $client = $request->client() || return;
    my $id = $client->id;
    return unless exists $_pauseRequestedAt{$id};
    my $newvalue = $request->getRequest(1);
    if (defined $newvalue && $newvalue eq '0') {
        delete $_pauseRequestedAt{$id};
        Slim::Utils::Timers::killTimers($client, \&_pauseGuardCheck);
    }
}

sub _pauseGuardCheck {
    my $client = shift;
    return unless $client;
    my $id = $client->id;
    return unless exists $_pauseRequestedAt{$id};

    my $song = $client->playingSong();
    my $url = $song ? ($song->track->url || '') : '';
    unless ($url =~ m{^spoton://(?!connect-)}) {
        delete $_pauseRequestedAt{$id};
        return;
    }

    my $mode = Slim::Player::Source::playmode($client) || '';
    my $age = Time::HiRes::time() - $_pauseRequestedAt{$id};

    if ($mode eq 'play') {
        $log->warn("[DIAG] PauseGuard: re-applying pause (swallowed ${age}s ago)") if $prefs->get('diagnosticMode');
        delete $_pauseRequestedAt{$id};
        $_pauseRequestedAt{_reapplying} = 1;
        Slim::Control::Request::executeRequest($client, ['pause', '1']);
        delete $_pauseRequestedAt{_reapplying};
    } elsif ($age < 5.0) {
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1.0, \&_pauseGuardCheck);
    } else {
        delete $_pauseRequestedAt{$id};
    }
}

sub _prefetchWatchdog {
    my $client = shift;
    return unless $client;

    my $song = $client->playingSong() || return;
    my $url = $song->track->url || '';
    return unless $url =~ m{^spoton://(?!connect-)};
    return unless Slim::Player::Source::playmode($client) eq 'play';

    my $duration = $song->duration || 0;
    return unless $duration > 0;

    my $rawElapsed = $client->songElapsedSeconds() || 0;
    my $startOffset = $song->startOffset || 0;
    my $elapsed = $rawElapsed + $startOffset;

    if ($elapsed >= $duration - 3) {
        my $id = $client->id;
        $_watchdogTriggerUrl{$id} = $url;
        $log->warn("[DIAG] Watchdog: near end (elapsed=${elapsed}s, duration=${duration}s) — arming 10s hang check") if $prefs->get('diagnosticMode');
        Slim::Utils::Timers::setTimer(
            $client,
            Time::HiRes::time() + 10,
            \&_prefetchHangCheck,
        );
        return;
    }

    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + 2,
        \&_prefetchWatchdog,
    );
}

sub _prefetchHangCheck {
    my $client = shift;
    return unless $client;
    my $id = $client->id;

    my $triggerUrl = delete $_watchdogTriggerUrl{$id} || return;

    my $song = $client->playingSong();
    my $currentUrl = $song ? ($song->track->url || '') : '';

    if ($currentUrl eq $triggerUrl && Slim::Player::Source::playmode($client) eq 'play') {
        $log->warn("Prefetch watchdog: still on same track after 10s past end — forcing skip");
        $client->execute(['playlist', 'jump', '+1']);
    }
}

1;
