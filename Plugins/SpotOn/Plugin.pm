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
use Scalar::Util qw(blessed);
use Time::HiRes;
use Time::Local qw(timelocal);
use File::Basename;
use File::Spec;
use File::Spec::Functions qw(catdir catfile);
use constant KILL_PROCESS_INTERVAL => 3600;    # Hourly orphaned-process cleanup (STR-10)
use constant SPOTON_CACHE_VERSION  => 4;       # Bump to flush all SpotOn cache entries (D-01/D-02)
use constant FLUSH_BATCH           => 50;      # Items per event-loop tick in _flushDeferredMeta (FIX-01)
use constant MAX_RECENT_SEARCHES   => 50;      # Maximum stored search history entries

my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', SPOTON_CACHE_VERSION);

my %_playAllItemCache;
my %_pauseRequestedAt;
# 79-32 (D-27): [playlist index, url] of the playing song at the moment the guard armed, per player id; compared in
# _pauseGuardCheck so a pause is never re-applied once the song changed after the pause request.
my %_pauseRequestedSong;
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
        require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
        $cache->set(
            'spoton_meta_' . md5_hex($p->{url}),
            {
                _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
                title    => $p->{title},
                artist   => $p->{artist},
                album    => $p->{album},
                duration => $p->{duration},
                cover    => $p->{cover},
                icon     => $p->{icon},
                year     => $p->{year} // '',
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
        enableAutoplay       => 1,     # D-08: Autoplay toggle, default on (Connect autoplay only — DSTM decoupled per GH #117)
        cacheSchemaVersion   => 0,     # D-02: migration marker — triggers cache clear on version bump
        diagnosticMode       => 0,     # #3: diagnostic logging toggle, default off
        streamingMode        => 'direct', # COMPAT-01: global streaming mode default (direct|proxy); per-player override lives in same-name client pref (GH #96)
        recentSearches => [],
        credProvenanceMigrated => 0,   # GH #147 plan 65-03: one-shot legacy-credential provenance migration marker
        authChainMigrated    => 0,     # 85-10 (D-02/D-03): one-shot account migration to the ZeroConf identity, set once the re-key journal is empty
        authChainRekeyPending => {},   # 85-10 (D-03): write-ahead re-key journal { oldId => newId }, finished by the next start
        spDcRemoved          => 0,     # 85-12 (decision-D17 cookie-free, D-19): one-shot wipe of stored sp_dc values and the manual Pathfinder hash pref
        pkceRemoved          => 0,     # 85-14 (D-01/D-02): one-shot wipe of every pkce_tokens.json, the clientId pref and the PKCE cache keys
        backend              => 'librespot', # D-08/Phase 71: playback daemon backend ('librespot'|'soloist'), default librespot
        soloistQuality       => 0,  # 83.3 D-13: Spotify streaming quality for the Soloist backend, global default Automatic; per-player override with 'global' sentinel in the same-name client pref
    });

    # D-02: cacheSchemaVersion guard — log when cache namespace version was bumped
    if ( ($prefs->get('cacheSchemaVersion') || 0) < SPOTON_CACHE_VERSION ) {
        $log->info("SpotOn cache schema version changed - cache cleared by namespace version bump");
        $prefs->set('cacheSchemaVersion', SPOTON_CACHE_VERSION);
    }

    require Plugins::SpotOn::Helper;
    Plugins::SpotOn::Helper->init();

    # 84-08 (SEAM-6.2): the active backend bootstraps itself through its
    # role -- the class comes from the registry by the validated backend
    # name, never named here. The Soloist role registers its `backend`
    # watcher (cached binary/version invalidation, Phase 71 D-08) and runs
    # ensureBinary() (download/version check, self-guarding, WR-07 in-flight
    # guard) on every boot outside the scanner -- the same cache-clear-then-
    # restart recovery case Phase 72 had; the librespot role registers its
    # binary paths (Helper->init, once-guarded inside Helper.pm).
    require Plugins::SpotOn::Backend;
    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Backend::classFor(Plugins::SpotOn::Unified::DaemonManager::backendName())->bootstrap();

    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::API::SpClient;
    require Plugins::SpotOn::API::Login5;

    # D-08: reset SpClient's own inflight counter/rate-limit/host caches and
    # Login5's token cache (Pitfall 2 prevention -- stale counter on reload).
    Plugins::SpotOn::API::SpClient->reset();
    Plugins::SpotOn::API::Login5->reset();
    # 85-08: Pathfinder's queue, in-flight count, scrape state and its 429 pool
    # key (PF_RATE_LIMIT_KEY). Since 85-15 deleted API/Client.pm, whose reset
    # used to clear the same key, this is the only startup clear of it.
    require Plugins::SpotOn::API::Pathfinder;
    Plugins::SpotOn::API::Pathfinder->reset();

    # 85-14 (D-01): the proactive PKCE token refresh timer (_refreshAllTokens)
    # is gone with the PKCE module.
    if ( !main::SCANNER ) {
        # 85-06 (D-05, RESEARCH P2): login5 health tick -- display-name repair
        # and the network-recovered edge. killTimers first so a plugin reload
        # never leaves two ticks pending; the tick re-arms itself.
        Slim::Utils::Timers::killTimers('Plugins::SpotOn::API::Login5', \&Plugins::SpotOn::API::Login5::healthTick);
        Slim::Utils::Timers::setTimer(
            'Plugins::SpotOn::API::Login5',
            Time::HiRes::time() + 20,
            \&Plugins::SpotOn::API::Login5::healthTick
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

        # Start Unified daemon manager for all players.
        # 4s delay: allows player list to populate after LMS start.
        Slim::Utils::Timers::killTimers($class, \&_startUnifiedDaemons);
        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 4, \&_startUnifiedDaemons);

        # Restart Unified daemons when diagnosticMode changes so RUST_LOG and
        # stderr routing take effect immediately.
        $prefs->setChange( sub {
            if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
                require Plugins::SpotOn::Unified::DaemonManager;
                Plugins::SpotOn::Unified::DaemonManager->shutdown('restart');
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
    # 79-27 D-20: a Browse track that starts playing is fetched fresh and its NowPlaying record rewritten.
    Slim::Control::Request::subscribe(\&_onNewSongRefreshMeta, [['playlist'], ['newsong']]);
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

    # Search history CLI — used by itemActions context menu on recent search entries
    #                                                           |requires Client
    #                                                           |  |is a Query
    #                                                           |  |  |has Tags
    #                                                           |  |  |  |Function to call
    #                                                           C  Q  T  F
    Slim::Control::Request::addDispatch(['spoton', 'recentsearches'],
                                                                [0, 1, 1, \&_recentSearchesCLI]
    );

    # GH #94: browse More menu routed through the TrackInfo framework so the
    # OPML context menu and the Now Playing TrackInfo menu render the same
    # item set (LMS standard items + every registered provider). Dispatched
    # by the `info` itemAction on _trackItem/_albumTrackItem/_episodeItem.
    Slim::Control::Request::addDispatch(['spotoninfo', 'items', '_index', '_quantity'],
                                                                [0, 1, 1, \&_trackInfoItemsCLI]
    );
}

sub shutdownPlugin {
    my $class = shift;

    # WR-04/WR-09: stop the Login5 health tick FIRST. It re-arms itself, so it
    # is latched off (a tick with a mint in flight has no timer to kill and
    # would re-arm from the mint callback) and the pending timer is killed --
    # before any of the shutdown calls below, none of which is eval-guarded.
    Slim::Utils::Timers::killTimers('Plugins::SpotOn::API::Login5', \&Plugins::SpotOn::API::Login5::healthTick);
    if ($INC{'Plugins/SpotOn/API/Login5.pm'}) {
        eval { Plugins::SpotOn::API::Login5->shutdown; 1 }
            or $log->warn("Login5 shutdown failed: $@");
    }

    require Plugins::SpotOn::Connect;
    Plugins::SpotOn::Connect->shutdown();

    # Unsubscribe watchdog registered in initPlugin — prevents duplicate handler
    # accumulation across plugin reloads (each reload calls shutdown then init).
    Slim::Control::Request::unsubscribe(\&_onNewSongWatchdog);
    Slim::Control::Request::unsubscribe(\&_onNewSongRefreshMeta);
    Slim::Control::Request::unsubscribe(\&_onModeChange);
    Slim::Control::Request::unsubscribe(\&_onPauseCommand);

    for my $id (keys %_pauseRequestedAt) {
        next if $id eq '_reapplying';
        my $client = Slim::Player::Client::getClient($id);
        Slim::Utils::Timers::killTimers($client, \&_pauseGuardCheck) if $client;
    }
    %_pauseRequestedAt = ();
    %_pauseRequestedSong = ();

    if ($INC{'Plugins/SpotOn/API/Credentials.pm'}) {
        Plugins::SpotOn::API::Credentials->cancelPairing();
    }

    if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->shutdown();
    }

    Slim::Utils::Timers::killTimers($class, \&_killOrphanedProcesses);
    Slim::Utils::Timers::killTimers($class, \&_startUnifiedDaemons);
}

# postinitPlugin($class)
# Called by LMS after all plugins have completed initPlugin. Registers
# SpotOn's Home Extras (scrolled "Recently Played" / "Top Tracks" rows)
# with Material Skin's home screen -- silent no-op when Material Skin is
# not installed or predates the registerHomeExtra API (GH #125).
sub postinitPlugin {
    my $class = shift;

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
        && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') )
    {
        eval { require Plugins::SpotOn::HomeExtras; };
        $log->error("Could not load SpotOn Home Extras: $@") if $@;
    }
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

# _startUnifiedDaemons()
# Phase 29: Timer callback — starts Unified daemon manager at LMS boot.
# 4s delay: after Connect and Browse timers to ensure player list populated.
sub _startUnifiedDaemons {
    require Plugins::SpotOn::Connect;
    Plugins::SpotOn::Connect->initConnectHandlers();

    # GH #147 plan 65-03 (scope item 6): one-shot provenance migration.
    # Runs exactly once, and BEFORE the first DaemonManager->init() below --
    # ordering matters: the playback-auth flags must exist before the first
    # startHelper evaluation, so no daemon ever launches against blockaded
    # legacy credentials (zero doomed starts on first boot after upgrade).
    # A credentials.json WITHOUT the playbackCredSource marker (written only
    # by the plan 65-02/65-03 install paths) is provably legacy token-derived
    # -- wrong provenance, rejected by Login5 since Aug 10, 2026. Accounts
    # without any credentials.json are skipped (nothing to invalidate; the
    # plan 65-01 startHelper missing-file path already handles them).
    if ( !$prefs->get('credProvenanceMigrated') ) {
        require Plugins::SpotOn::API::Credentials;
        my $accounts = $prefs->get('accounts') || {};
        for my $id (keys %{$accounts}) {
            next unless -f Plugins::SpotOn::API::Credentials->credentialsPathFor($id);
            next if $accounts->{$id}{playbackCredSource};
            Plugins::SpotOn::API::Credentials->markNeedsPlaybackAuth($id, 'legacy_token_derived');
            $log->info("Provenance migration: account " . substr($id, 0, 4) . '****'
                . " has legacy token-derived playback credentials -- flagged for re-authorization (GH #147)");
        }
        $prefs->set('credProvenanceMigrated', 1);
    }

    # 85-10 (D-02/D-03, decided by the user 2026-10-17: at LMS start): one-shot
    # account migration to the ZeroConf identity (id = md5 prefix of the
    # credentials.json username). Runs once, BEFORE the first DaemonManager->init()
    # so no playback helper starts against a stale account id. The marker is
    # set only when the journal is empty.
    #
    # WR-01: an interrupted re-key (journal entry) is finished on EVERY start,
    # independent of the marker -- a runtime re-key from DaemonManager can be
    # interrupted long after the one-shot ran. resumeJournal is a no-op on an
    # empty journal, and run() resumes it first as well.
    require Plugins::SpotOn::API::AccountMigration;
    eval { Plugins::SpotOn::API::AccountMigration->resumeJournal(); 1 }
        or $log->error("Auth chain journal resume failed: $@");
    unless ( $prefs->get('authChainMigrated') ) {
        eval { Plugins::SpotOn::API::AccountMigration->run(); 1 }
            or $log->error("Auth chain migration failed: $@");
        $prefs->set('authChainMigrated', 1)
            unless %{ $prefs->get('authChainRekeyPending') || {} };
    }

    # 85-12 (decision-D17 pathfinder-login5-plus-rootlist, cookie-free; T-85-30):
    # wipe the sp_dc values and the manual Pathfinder hash that older versions
    # stored. Once, and before the first init() so nothing starts with them.
    _removeSpDcOnce();

    # 85-11 (D-23): a credentials.json waiting in the discover folder becomes an
    # account now -- after the migration (so a freshly imported account is never
    # re-keyed by it) and before the first init(), so its daemon starts with the
    # first pass instead of waiting for the next one.
    require Plugins::SpotOn::API::Credentials;
    eval { Plugins::SpotOn::API::Credentials->intakeDiscoverFolder(); 1 }
        or $log->error("Discover folder intake failed: $@");

    # 85-14 (D-01/D-02, T-85-27): the PKCE module is gone, so its leftovers are
    # too: stored refresh tokens, the Client-ID pref and the token cache keys.
    # Once, after the account migration and the discover intake (both may still
    # look at the account dirs) and before the first init().
    _removePkceOnce();

    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->init();
}

# _removePkceOnce()
# 85-14 (D-01/D-02, T-85-27): deletes what the removed PKCE module left behind --
# every pkce_tokens.json (and an interrupted write's pkce_tokens.json.tmp.<pid>)
# under <cachedir>/spoton/ and its account directories, the stored 'clientId'
# pref, and the spoton_token_<id> / spoton_needs_reauth_<id> cache keys of every
# account -- then sets pkceRemoved. Idempotent: with the marker set a second call
# changes nothing. An account directory is only touched when its name is a plain
# id (no separators, dots or spaces) and it is a real directory, never a symlink,
# so a planted link cannot point the deletion elsewhere. credentials.json is
# never touched.
sub _removePkceOnce {
    return if $prefs->get('pkceRemoved');

    my $root = catdir(preferences('server')->get('cachedir'), 'spoton');
    my $accounts = $prefs->get('accounts');
    my %ids = ref $accounts eq 'HASH' ? map { $_ => 1 } keys %{$accounts} : ();

    my @dirs = ($root);
    if ( opendir(my $dh, $root) ) {
        for my $name ( readdir $dh ) {
            next unless $name =~ /\A[A-Za-z0-9_-]+\z/;
            my $dir = catdir($root, $name);
            next if -l $dir || !-d $dir;
            push @dirs, $dir;
        }
        closedir $dh;
    }

    my $removed = 0;
    for my $dir (@dirs) {
        next unless -d $dir && !-l $dir;
        opendir(my $dh, $dir) or next;
        for my $name ( readdir $dh ) {
            next unless $name =~ /\Apkce_tokens\.json(?:\.tmp\.\d+)?\z/;
            my $file = catfile($dir, $name);
            next if -l $file || !-f $file;
            $removed++ if unlink $file;
        }
        closedir $dh;
    }

    for my $id ( keys %ids ) {
        next unless defined $id && length $id;
        $cache->remove("spoton_token_${id}");
        $cache->remove("spoton_needs_reauth_${id}");
    }

    $prefs->remove('clientId');
    $prefs->set('pkceRemoved', 1);
    $log->info("PKCE cleanup: removed $removed stored token file(s), the Client-ID pref and the token cache keys");
    return;
}

# _removeSpDcOnce()
# 85-12 (decision-D17 pathfinder-login5-plus-rootlist is cookie-free; T-85-30,
# D-19): deletes accounts->{id}{sp_dc} for every account and the stored manual
# 'pathfinderHash' pref value that older versions kept, then sets spDcRemoved.
# Idempotent: with the marker set a second call changes nothing. Nothing reads
# either value any more, so a copy left in prefs.js would only be a stored secret.
sub _removeSpDcOnce {
    return if $prefs->get('spDcRemoved');

    my $accounts = $prefs->get('accounts');
    if ( ref $accounts eq 'HASH' ) {
        my $removed = 0;
        for my $id (keys %{$accounts}) {
            next unless ref $accounts->{$id} eq 'HASH' && exists $accounts->{$id}{sp_dc};
            delete $accounts->{$id}{sp_dc};
            $removed++;
        }
        if ($removed) {
            $prefs->set('accounts', $accounts);
            $log->info("Cookie-free cleanup: removed the stored sp_dc value from $removed account(s)");
        }
    }
    $prefs->remove('pathfinderHash');
    $prefs->set('spDcRemoved', 1);
    return;
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
        # CON-09: Exclude Unified daemon PIDs from orphan cleanup -- this
        # already includes every live daemon's PID, whatever its backend
        # (helperPids() iterates all helper instances), so the soloist
        # sweep below only ever kills genuine orphans.
        my %unifiedPids;
        if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
            %unifiedPids = map { $_ => 1 }
                Plugins::SpotOn::Unified::DaemonManager->helperPids();
        }

        # D-33 FULL-1 CR-01: the ZeroConf pairing helper is the same binary
        # as the swept helper (`--discover-once`) and lives only in
        # Credentials' %_pairing -- protect it for both the Unix and the
        # Windows branch, which read the same set.
        if ($INC{'Plugins/SpotOn/API/Credentials.pm'}) {
            my $pairingPid = Plugins::SpotOn::API::Credentials->pairingPid;
            $unifiedPids{$pairingPid} = 1 if $pairingPid;
        }

        my ($helper) = Plugins::SpotOn::Helper->get();
        _killOrphansForBinary($helper, \%activePids, \%unifiedPids) if $helper;

        # WR-09: orphan cleanup previously only targeted the librespot
        # helper binary name -- die_upon_destroy does not survive a
        # SIGKILLed/OOM-killed/crashed LMS, so a leftover soloist process
        # kept its per-player data-dir lock, WS port, and HTTP port. After
        # LMS restarted, the fresh spawn for the same player collided with
        # the survivor -- exactly the zombie-daemon/data-dir-lock failure
        # class this project (and Phase 73's Model B specifically) set out
        # to eliminate.
        # 84-13 (SEAM-6.2): every AVAILABLE backend's binary through its
        # role's binaryPath (class method, read-only -- 83.3 plan 08 gap 2,
        # WR-01: installedBinaryPath() for Soloist, never the activating
        # get()); available() already answers "is this side present". The
        # helper path swept just above is skipped, so no binary is swept
        # twice. eval-guarded: a failing read must not cost the hourly
        # reschedule below.
        require Plugins::SpotOn::Backend;
        for my $name (Plugins::SpotOn::Backend::available()) {
            my $path = eval { Plugins::SpotOn::Backend::classFor($name)->binaryPath };
            $log->warn("Orphan sweep: binaryPath of backend '$name' failed: $@") if $@;
            next unless defined $path && length $path;
            next if defined $helper && $path eq $helper;
            _killOrphansForBinary($path, \%activePids, \%unifiedPids);
        }
    }

    # Always reschedule (even when $isBusy) to maintain hourly cleanup cycle
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + KILL_PROCESS_INTERVAL,
        \&_killOrphanedProcesses
    );
}

# _killOrphansForBinary($binary, \%activePids, \%unifiedPids) -- WR-09:
# shared by the librespot-helper and soloist-binary sweeps in
# _killOrphanedProcesses above. Windows is a structural no-op for the
# soloist call today (soloist is Linux-only), but kept parallel to the Unix
# branch so the guard stays structural if that ever changes.
sub _killOrphansForBinary {
    my ($binary, $activePids, $unifiedPids) = @_;

    eval {
        if (main::ISWINDOWS) {
            my $name = basename($binary);
            $name =~ s/[^A-Za-z0-9._-]//g;
            if ($name) {
                my @pids = map { /^"[^"]*","(\d+)"/ ? $1 : () }
                    `tasklist /FI "IMAGENAME eq $name" /FO CSV /NH 2>nul`;
                for my $pid (@pids) {
                    next if $activePids->{$pid};
                    next if $unifiedPids->{$pid};
                    kill 'KILL', $pid;
                    main::DEBUGLOG && $log->is_debug && $log->debug("Killed orphaned spoton process PID $pid (Windows)");
                }
            }
        } else {
            # CR-01: Use PID-based kill to avoid killing active transcoding processes.
            # Find all matching PIDs, exclude active ones, kill only orphans.
            # M6: pgrep -f treats the pattern as an extended regex — quotemeta
            # the binary path FIRST so dots and other metacharacters cannot
            # match (and kill) foreign processes, THEN apply the single-quote
            # shell escaping.
            (my $safeBinary = quotemeta($binary)) =~ s/'/'\\''/g;
            my @pids = map { /^\s*(\d+)/ ? $1 : () } `pgrep -f '$safeBinary'`;
            for my $pid (@pids) {
                next if $activePids->{$pid};
                next if $unifiedPids->{$pid};    # CON-09: protect Unified daemon PIDs
                kill 'TERM', $pid;
                main::DEBUGLOG && $log->is_debug && $log->debug("Killed orphaned spoton process PID $pid");
            }
        }
    };
    $@ && $log->warn("Could not kill orphaned spoton processes ($binary): $@");
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

    # 85-14 (D-01, D-02): ONE pairing hint replaces the PKCE re-auth, v2.x
    # migration and playback-authorization hints. It shows when the ACTIVE
    # account (Browse/Library always operate on it) has no valid login -- no
    # verifiable credentials.json, a playback-auth flag, or a Login5 verdict of
    # invalid_credentials (TokenManager->hasValidLogin) -- or when the 85-10
    # migration marked it needsPairing. Only the hint changes: the rest of the
    # menu stays, because whatever still works for the account keeps working.
    require Plugins::SpotOn::API::TokenManager;
    my $activeAccountId = _getAccountId($client);
    if ($activeAccountId) {
        my $accounts = $prefs->get('accounts') || {};
        my $entry    = $accounts->{$activeAccountId};
        if ( ( ref $entry eq 'HASH' && $entry->{needsPairing} )
            || !Plugins::SpotOn::API::TokenManager->hasValidLogin($activeAccountId) )
        {
            push @items, {
                name => cstring($client, 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING'),
                type => 'textarea',
            };
        }
    }

    # Rate-limit hint (D-12): show while spclient is throttled. WR-03: the
    # source is SpClient's own 429 key (SPCLIENT_RATE_LIMIT_KEY, set in
    # SpClient::_request on a 429); the Client.pm key it used to read is gone.
    require Plugins::SpotOn::API::SpClient;
    if ( $cache->get( Plugins::SpotOn::API::SpClient::SPCLIENT_RATE_LIMIT_KEY() ) ) {
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
                name  => cstring($client, 'PLUGIN_SPOTON_ACTIVE_ACCOUNT', $activeName),
                url   => \&_accountSwitcherFeed,
                image => 'plugins/SpotOn/html/images/account.png',
                type  => 'link',
            };
        }

        push @items, {
            name  => cstring($client, 'PLUGIN_SPOTON_HOME'),
            url   => \&_homeFeed,
            image => 'plugins/SpotOn/html/images/home.png',
            type  => 'link',
        };
        push @items, {
            name  => cstring($client, 'PLUGIN_SPOTON_SEARCH'),
            url   => \&_searchPageFeed,
            image => 'plugins/SpotOn/html/images/search.png',
            type  => 'link',
        };
        push @items, {
            name  => cstring($client, 'PLUGIN_SPOTON_LIBRARY'),
            url   => \&_libraryFeed,
            image => 'html/images/musicfolder.png',
            type  => 'link',
        };
        push @items, {
            name  => cstring($client, 'PLUGIN_SPOTON_PODCASTS'),
            url   => \&_podcastsFeed,
            image => 'plugins/SpotOn/html/images/podcasts.png',
            type  => 'link',
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
# Lists all configured accounts.  Cross-client behavior (GH #136):
#
# - JiveLite: item-level nextWindow => 'parent' propagates into the
#   jive go action (Bug 13247) — switch executes, view navigates back
#   one level to a re-fetched main menu showing the new account name.
#
# - Material Skin: relies on text-click coercion (browse-resp.js:296-300)
#   which fires ONLY when the item has no 'type' key.  The coercion
#   executes _switchAccount server-side, shows the confirmation as a
#   toast, and refreshes the menu.  Adding type => 'link' (or any type)
#   here REGRESSES Material — it bypasses coercion and drills into the
#   confirmation as a new page.
#
# - Classic/Default web skin: ignores nextWindow, shows the text
#   confirmation page.  This matches Spotty/Qobuz (ecosystem standard).
#   Coderef feeds are never session-cached by XMLBrowser, so the next
#   navigation re-fetches with the new active account.
sub _accountSwitcherFeed {
    my ($client, $callback, $args) = @_;

    my $accounts  = $prefs->get('accounts') || {};
    my $activeId  = _getAccountId($client);

    my @items;
    for my $id (sort keys %{$accounts}) {
        my $name    = $accounts->{$id}{displayName} || $id;
        my $isActive = ($id eq $activeId);
        push @items, {
            name        => $name . ($isActive ? ' *' : ''),
            url         => \&_switchAccount,
            passthrough => [{ accountId => $id }],
            nextWindow  => 'parent',
        };
    }

    $callback->({ items => \@items });
}

# _switchAccount()
# Updates per-client activeAccount preference, refreshes Material Skin
# home rows (GH #139), and navigates back to root.
sub _switchAccount {
    my ($client, $callback, $args, $passthrough) = @_;

    my $accountId = $passthrough ? $passthrough->{accountId} : undef;
    my $name;

    if ($accountId && $client) {
        $prefs->client($client)->set('activeAccount', $accountId);
        $prefs->set('activeAccount', $accountId) unless $prefs->get('activeAccount');
        my $accounts = $prefs->get('accounts') || {};
        $name = $accounts->{$accountId}{displayName} if $accounts->{$accountId};

        # GH #139: Refresh Material Skin home rows after account switch.
        # Guard: HomeExtras.pm is only loaded when Material Skin is installed
        # (see postinitPlugin's guarded require).
        Plugins::SpotOn::HomeExtras::refresh() if $INC{'Plugins/SpotOn/HomeExtras.pm'};
    }

    my $msg = $name
        ? cstring($client, 'PLUGIN_SPOTON_ACCOUNT_SWITCHED', $name)
        : 'OK';

    # Belt-and-braces nextWindow for any client that drills into the
    # feed despite the item-level hint (GH #136).
    # No type key — matches Like/Unlike confirmation shape. With type => 'text',
    # Material Skin wraps the title in a <div> that renders as raw HTML in toasts.
    $callback->({ items => [
        {
            name       => $msg,
            nextWindow => 'grandparent',
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
    Plugins::SpotOn::API::SpClient->checkTracks($accountId, [$trackUri], sub {
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

    Plugins::SpotOn::API::SpClient->$apiMethod($accountId, [$uri], sub {
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
    Plugins::SpotOn::API::SpClient->checkShows($accountId, [$showUri], sub {
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

# SpotOnAddToPlaylist($client, $cb, $params, $args)
# GH #157: bounded multi-page fill so the picker lists up to a full
# JiveLite 210-item block instead of stalling at one API page (JVL-04).
sub SpotOnAddToPlaylist {
    my ($client, $cb, $params, $args) = @_;

    my $spotifyUri = $args->{spotifyUri} // '';
    return unless $spotifyUri =~ /^spotify:(track|episode):[A-Za-z0-9]+$/;
    my $accountId = $args->{accountId};

    my $offset = $params->{index} || 0;
    my $qty    = $params->{quantity} || 200;

    _fetchPages({
        accountId   => $accountId,
        apiFn       => sub {
            my ($acct, $params2, $cb2) = @_;
            Plugins::SpotOn::API::SpClient->getUserPlaylists($acct, $params2, $cb2);
        },
        pageLimit   => Plugins::SpotOn::API::SpClient->pageLimit('library'),
        startOffset => $offset,
        maxItems    => $qty,
        done        => sub {
            my ($allItems, $err, $total) = @_;
            if (!@$allItems && $err) {
                $cb->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my @items;
            for my $pl (@$allItems) {
                next unless $pl && $pl->{id};
                next if _isMadeForYou($pl);
                push @items, {
                    name        => $pl->{name} // '',
                    url         => \&_doAddToPlaylist,
                    passthrough => [{ playlistId => $pl->{id}, playlistName => $pl->{name}, spotifyUri => $spotifyUri, accountId => $accountId }],
                    image       => _largestImage($pl->{images}) || 'html/images/playlists.png',
                    line2       => ($pl->{owner} || {})->{display_name} // '',
                    type        => 'link',
                };
            }

            $cb->({ items => \@items, offset => $offset, total => $total });
        },
    });
}

sub _doAddToPlaylist {
    my ($client, $cb, $params, $args) = @_;

    my $playlistId   = $args->{playlistId};
    my $playlistName = $args->{playlistName} // '';
    my $spotifyUri   = $args->{spotifyUri};
    my $accountId    = $args->{accountId};

    Plugins::SpotOn::API::SpClient->addToPlaylist($accountId, $playlistId, [$spotifyUri], sub {
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

# _releaseYear($release_date)
# Extracts the 4-digit release year from a Spotify release_date string (YYYY, YYYY-MM, or YYYY-MM-DD).
# Returns '' when the input is undef or does not begin with four digits.
sub _releaseYear {
    my ($release_date) = @_;
    return '' unless $release_date && $release_date =~ /^(\d{4})/ && $1 > 0;
    return $1;
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

sub _normalizeLibraryItem {
	my ($item, $key) = @_;
	if (ref($item->{item}) eq 'HASH' && ref($item->{$key}) ne 'HASH') {
		$item->{$key} = $item->{item};
	}
	return $item;
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
    my $year     = _releaseYear($track->{album}{release_date});

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
    if ($year) {
        push @contextItems, {
            name  => $year,
            type  => 'text',
            label => 'YEAR',
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
    my ($track_path) = ($track->{uri} // '') =~ /^spotify:((?:track|episode):[A-Za-z0-9]+)$/;
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
            year     => $year,
            track    => $track,    # kept for _extractTrackIds (encode_json deferred to flush)
            client   => $client,
        };
    } else {
        my %trackIds = _extractTrackIds($track);
        require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
        $cache->set('spoton_meta_' . md5_hex($spoton_url), {
            _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
            title     => $title,
            artist    => $artist,
            album     => $album,
            duration  => $duration,
            cover     => $image,
            icon      => $image,
            year      => $year,
            bitrate   => __PACKAGE__->_bitrateForClient($client) . 'k',
            type      => __PACKAGE__->_typeString($client, 'Browse'),
            %trackIds,
        }, 604800);
    }

    my %item = (
        name            => "$title - $artist",    # plain title - artist fallback for older clients
        favorites_title => "$title - $artist",
        title           => $title,
        artist          => $artist,
        album           => $album,
        line1         => $title,
        line2         => $artist . ($album ? " \x{2022} $album" : ''),
        url           => $spoton_url,
        play          => $spoton_url,
        on_select     => 'play',
        playall       => 1,    # Context queueing (D-09/D-10) — XMLBrowser enqueues all feed items
        image         => $image || 'html/images/cover.png',
        duration      => $duration,
        type          => 'audio',
        # spoton:// URL for LMS Favorites playback
        favorites_url => $spoton_url,
        # GH #94: More menu routed through the TrackInfo framework -- one
        # menu source for browse and Now Playing. @contextItems stays as the
        # Default-skin drill-down (`items`); jive/Material clients use this.
        itemActions   => {
            info => {
                command     => ['spotoninfo', 'items'],
                fixedParams => { url => $spoton_url },
            },
        },
    );
    $item{items} = \@contextItems if @contextItems;

    return \%item;
}

# _authRequiredItem($client, $accountId, $err)
# Shared OPML error-branch helper (D-04 Channel 3, AUTH-07, Plan 03 Task 2).
# Called from the ~17 feed-function `unless ($data)` sites in place of the
# old hardcoded PLUGIN_SPOTON_NO_RESULTS item construction. Distinguishes
# "this account has to be paired" from a genuine empty result set.
# 85-14 (D-01): the PKCE re-auth / migration / revoked-Client-ID texts are gone.
# Pairing is needed when the error says there is no usable login
# (no_credentials, invalid_credentials, no_token) or the account has none
# (TokenManager->hasValidLogin).
# SECURITY (T-53-05, mirrors T-51-10/T-52-02): $err->{error} is matched
# against known constants, never interpolated into the returned name/string --
# only fixed, pre-translated cstring() keys are returned.
sub _authRequiredItem {
    my ($client, $accountId, $err) = @_;

    my $errCode = ($err && ref $err eq 'HASH') ? ($err->{error} // '') : '';

    # GH #155: surface rate-limit errors as a clear message instead of
    # the confusing "No results" that gives zero diagnostic clue.
    if ($errCode =~ /^rate_limited/) {
        return {
            name => cstring($client, 'PLUGIN_SPOTON_RATE_LIMITED'),
            type => 'textarea',
        };
    }

    require Plugins::SpotOn::API::TokenManager;

    my $stringKey = 'PLUGIN_SPOTON_NO_RESULTS';
    if ($errCode =~ /\A(?:no_credentials|invalid_credentials|no_token)\z/
        || !Plugins::SpotOn::API::TokenManager->hasValidLogin($accountId))
    {
        $stringKey = 'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING';
    }

    return {
        name => cstring($client, $stringKey),
        type => 'textarea',
    };
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
        passthrough   => [{ albumId => $album->{id}, albumImages => $album->{images}, albumArtist => $firstArtist, albumName => $album->{name}, albumReleaseDate => $releaseDate }],
        image         => _largestImage($album->{images}) || 'html/images/albums.png',
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
        image       => _largestImage($artist->{images}) || 'html/images/artists.png',
        type        => 'link',
    };
}

# _playlistItem($client, $playlist, $opts)
# Builds an OPML link item for playlist navigation.
# url => \&_playlistFeed is defined in Plan 03-03 (resolved at runtime by Perl).
# Every playlist -- Spotify-made 37i9 mixes included -- is read through spclient
# playlist/v2 (SpClient->getPlaylistItems), so there is no per-item routing flag.
sub _playlistItem {
    my ($client, $playlist, $opts) = @_;
    # spoton:// URL for LMS Favorites playback (explodePlaylist resolves to tracks)
    my $pl_spoton = 'spoton://playlist:' . ($playlist->{id} // '');

    return {
        name          => $playlist->{name} // '',
        url           => \&_playlistFeed,
        passthrough   => [{ playlistId => $playlist->{id} }],
        image         => _largestImage($playlist->{images}) || 'html/images/playlists.png',
        line2         => $playlist->{owner}{display_name} // '',
        favorites_url => $pl_spoton,
        type          => 'playlist',
    };
}

# ============================================================
# Home Feed (D-02)
# ============================================================

# _homeFeed($client, $callback, $args)
# Returns navigation items: Recently Played, (conditional) Up Next, Made For You,
# Top Tracks. Per D-02: each item opens its own sub-feed.
#
# Made For You (85-08, decision-D17 pathfinder-login5-plus-rootlist) is listed
# whenever the account has login5-capable credentials -- the same login5 bearer
# that Pathfinder uses -- and is hidden otherwise. There is no cookie state to
# degrade on: when Pathfinder fails, the feed itself falls back to the
# Spotify-made mixes of the rootlist, or says it is unreachable.
sub _homeFeed {
    my ($client, $callback, $args) = @_;

    my @items = (
        {
            name  => cstring($client, 'PLUGIN_SPOTON_RECENTLY_PLAYED'),
            url   => \&_recentlyPlayedFeed,
            type  => 'playlist',   # GH #161: flat track list -> playlist type for Play All / Add hover actions
            image => 'plugins/SpotOn/html/images/MTL_icon_history.png',
        },
    );

    # 85-07 D-09: Up Next exists only where the playback backend has a queue
    # source (the Soloist helper announces its queue). With librespot,
    # query('queue') is undef and the item is not shown.
    require Plugins::SpotOn::Unified::DaemonManager;
    my $backend = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    if ($backend && defined $backend->query('queue')) {
        push @items, {
            name  => cstring($client, 'PLUGIN_SPOTON_UP_NEXT'),
            url   => \&_upNextFeed,
            # GH #135: live-status list, deliberately NOT 'playlist' -- the
            # GH #161 convention does not apply here since Play All on an
            # already-playing Connect queue would double-play.
            type  => 'link',
            image => 'plugins/SpotOn/html/images/playlist.png',
        };
    }

    my $accountId = _getAccountId($client);
    if (Plugins::SpotOn::API::SpClient->_hasLogin5Creds($accountId)) {
        push @items, {
            name  => cstring($client, 'PLUGIN_SPOTON_MADE_FOR_YOU'),
            url   => \&_madeForYouFeed,
            type  => 'link',
            image => 'plugins/SpotOn/html/images/MTL_icon_auto_awesome.png',
        };
    } else {
        main::INFOLOG && $log->is_info && $log->info('Plugin: Made For You hidden -- no login5 credentials for the account');
    }

    push @items, {
        name  => cstring($client, 'PLUGIN_SPOTON_TOP_TRACKS'),
        url   => \&_topTracksFeed,
        type  => 'playlist',   # GH #161: flat track list -> playlist type for Play All / Add hover actions
        image => 'plugins/SpotOn/html/images/toptracks.png',
    };

    $callback->({ items => \@items });
}

# _recentlyPlayedFeed($client, $callback, $args)
# Fetches recently played tracks via cursor-based API (no offset — Pitfall 4).
# Single-page response; no total field.
sub _recentlyPlayedFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::SpClient->getRecentlyPlayed($accountId, { limit => Plugins::SpotOn::API::SpClient->pageLimit('library') }, sub {
        my ($data, $err) = @_;
        unless ($data) {
            $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
            return;
        }
        my @items = map  { _trackItem($client, $_->{track}) }
                    grep { defined $_->{track} }
                    map  { _normalizeLibraryItem($_, 'track') }
                    @{ $data->{items} || [] };
        $callback->({ items => \@items });
    });
}

# _upNextFeed($client, $callback, $args)
# GH #135: renders the Spotify Connect queue ("Up Next") -- the currently
# playing track followed by the upcoming tracks -- when the menu is opened.
# 85-07 D-09: the data comes from the playback helper through the backend
# role (query('queue')), never from the Web API: the Soloist daemon announces
# its queue itself and answers get_queue, the backend answers from that
# cache. This invocation is the ONLY trigger: no timers, no Request
# subscriptions, no polling (the helper-side request is rate limited to one
# per few seconds). With a backend that has no queue source (librespot) the
# Home item is not shown at all (see _homeFeed); a direct call renders the
# empty state. Single page, no pagination -- the queue is bounded (20).
sub _upNextFeed {
    my ($client, $callback, $args) = @_;

    require Plugins::SpotOn::Unified::DaemonManager;
    my $backend = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    my $queue   = $backend ? $backend->query('queue') : undef;

    # T-76-14: untrusted payload -- type-check every level before use. A
    # malformed answer, or an idle account, renders the empty state: "no
    # active session" is a normal condition here, not a failure.
    my $now = (ref $queue eq 'HASH' && ref $queue->{current} eq 'HASH') ? $queue->{current} : undef;
    my @queue = (ref $queue eq 'HASH' && ref $queue->{upcoming} eq 'ARRAY')
        ? grep { ref $_ eq 'HASH' && $_->{uri} } @{ $queue->{upcoming} }
        : ();

    my @items;
    if ($now && $now->{uri}) {
        # Rendering goes through the established _trackItem pipeline
        # (escaping/metadata handling); name-prefix with the LMS core
        # NOW_PLAYING string so the head row reads as "now playing".
        my $item = _trackItem($client, $now);
        $item->{name} = cstring($client, 'NOW_PLAYING') . ': ' . $item->{name};
        push @items, $item;
    }
    push @items, map { _trackItem($client, $_) } @queue;

    unless (@items) {
        $callback->({ items => [{
            name => cstring($client, 'PLUGIN_SPOTON_UP_NEXT_EMPTY'),
            type => 'textarea',
        }] });
        return;
    }

    $callback->({ items => \@items });
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

# _madeForYouFeed($client, $callback, $args)
# Made for You (85-08, decision-D17 pathfinder-login5-plus-rootlist): the
# user's Made-for-You hub from Pathfinder homeSection with SpotOn's own login5
# bearer (SpClient->getMadeForYou), in the order Pathfinder lists it; when
# Pathfinder fails, the Spotify-made mixes of the rootlist, sorted by
# @MFY_PRIORITY. The feed never consults the playback backend (D-20) and
# sends no browse/categories request (D-08).
sub _madeForYouFeed {
    my ($client, $callback, $args) = @_;
    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::SpClient->getMadeForYou($accountId, sub {
        my ($result, $err) = @_;

        # D-19: never a silent empty menu. Nothing to list -- Pathfinder and
        # the rootlist both came up empty, or the call failed -- says so; the
        # raw error reason is not reflected into the menu (Security V7/T-52-02).
        my $playlists = ($result && ref $result eq 'HASH') ? $result->{items} : undef;
        unless ($playlists && @$playlists) {
            # WR-13: Pathfinder answered and the rootlist holds no Spotify-made
            # mix either -- that is "nothing here", not "unreachable". The
            # unreachable line stays for a failed Pathfinder section and for an
            # error from the call itself.
            my $answeredEmpty = ($result && ref $result eq 'HASH' && !$result->{pathfinderError}) ? 1 : 0;
            $callback->({ items => [{
                name => cstring($client, $answeredEmpty ? 'PLUGIN_SPOTON_NO_RESULTS' : 'PLUGIN_SPOTON_MFY_HASH_BROKEN'),
                type => 'textarea',
            }] });
            return;
        }

        my @sorted = @$playlists;
        my @items;
        if (($result->{source} // '') eq 'rootlist-fallback') {
            @sorted = sort {
                _madeForYouPriority($a->{name}) <=> _madeForYouPriority($b->{name})
            } @sorted;
            # the marker line: this is the saved-mixes list, not the Spotify home
            push @items, {
                name => cstring($client, 'PLUGIN_SPOTON_MFY_FALLBACK'),
                type => 'textarea',
            };
        }

        push @items, map { _playlistItem($client, $_) } @sorted;

        $callback->({ items => \@items });
    });
}

# _topTracksFeed($client, $callback, $args)
# Fetches user's top tracks with time_range=medium_term per D-05.
sub _topTracksFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    Plugins::SpotOn::API::SpClient->getTopTracks($accountId, {
        time_range => 'medium_term',
        limit      => 50,
    }, sub {
        my ($data, $err) = @_;
        unless ($data) {
            # D-07 (85-08): top tracks come from Pathfinder only, and no
            # rootlist-style substitute exists -- say so, never an empty menu.
            # A rate limit keeps its own, more specific line.
            if ($err && ref $err eq 'HASH' && ($err->{error} || '') =~ /^rate_limited/) {
                $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
            } else {
                $callback->({ items => [{
                    name => cstring($client, 'PLUGIN_SPOTON_TOP_TRACKS_UNAVAILABLE'),
                    type => 'textarea',
                }] });
            }
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
            name  => cstring($client, 'PLUGIN_SPOTON_LIKED_SONGS'),
            url   => \&_savedTracksFeed,
            image => 'plugins/SpotOn/html/images/song.png',
            type  => 'playlist',   # GH #161: flat track list -> playlist type for Play All / Add hover actions
        },
        {
            name  => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
            url   => \&_savedAlbumsFeed,
            image => 'html/images/albums.png',
            type  => 'link',
        },
        {
            name  => cstring($client, 'PLUGIN_SPOTON_ARTISTS'),
            url   => \&_followedArtistsFeed,
            image => 'html/images/artists.png',
            type  => 'link',
        },
        {
            name  => cstring($client, 'PLUGIN_SPOTON_PLAYLISTS'),
            url   => \&_userPlaylistsFeed,
            image => 'html/images/playlists.png',
            type  => 'link',
        },
    );

    $callback->({ items => \@items });
}

# _savedTracksFeed($client, $callback, $args)
# Fetches user's liked tracks with LMS OPMLBased offset/limit pagination mapping.
# Per NAV-08: unconditional access (no gating).
# Per NAV-09: API default sort is added_at desc (recently added first).
# Per D-12: LMS index/quantity mapped to Spotify offset/limit.
# Play-all detection: if quantity is undef (CLI/Material Skin "Play now") OR
# $qty >= 500 (Classic/Web UI "Play All"), AND $offset == 0, fetches ALL tracks
# via _fetchAllPages (Option D, Phase 54 Plan 04).
# Else-branch: bounded multi-page fill via _fetchPages honoring the requested
# (offset, quantity) so JiveLite's ~210-item block requests get filled across
# multiple Spotify API pages instead of stalling at the 50-item API cap (GH #157).
sub _savedTracksFeed {
    my ($client, $callback, $args) = @_;

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my $cacheKey = "savedTracks:$accountId";

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getSavedTracks($acct, $params, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        # Play-all mode: fetch all liked tracks via full pagination
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            # 79-27 D-22: one page = one extended-metadata batch (trackBatchSize); play-all still loads
            # every page before the single callback.
            pageLimit    => Plugins::SpotOn::API::SpClient->trackBatchSize,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                # FIX-01: defer metadata cache writes to avoid blocking event loop
                # with N synchronous SQLite INSERTs before callback fires.
                my @deferredMeta;
                my @items = map  { _trackItem($client, $_->{track}, { defer_cache => \@deferredMeta }) }
                            grep { defined $_->{track} }
                            map  { _normalizeLibraryItem($_, 'track') }
                            @{$allItems};
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
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
        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            startOffset  => $offset,
            maxItems     => $qty,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }
                # FIX-01: defer metadata cache writes to avoid blocking event loop
                # with N synchronous SQLite INSERTs before callback fires.
                my @deferredMeta;
                my @items = map  { _trackItem($client, $_->{track}, { defer_cache => \@deferredMeta }) }
                            grep { defined $_->{track} }
                            map  { _normalizeLibraryItem($_, 'track') }
                            @{$allItems};
                $callback->({ items => \@items, offset => $offset, total => $total });
                # Flush deferred metadata cache writes in background (50 per event-loop tick).
                _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
            },
        });
    }
}

# _savedAlbumsFeed($client, $callback, $args)
# Fetches user's saved albums with LMS OPMLBased pagination mapping.
# Play-all detection (GH #121): same pattern as _artistAlbumsFeed — fetch all pages
# when quantity >= 500 to avoid LMS serving undef slots from cache.
sub _savedAlbumsFeed {
    my ($client, $callback, $args) = @_;

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my $cacheKey = "savedAlbums:$accountId";

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getSavedAlbums($acct, $params, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                my @items = map  { _albumItem($client, $_->{album}) }
                            grep { defined $_->{album} }
                            map  { _normalizeLibraryItem($_, 'album') }
                            @{$allItems};
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
                }
                $_playAllItemCache{$cacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
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
        goto &_savedAlbumsFeed;
    } else {
        # Bounded multi-page fill for fixed-size block clients (GH #157).
        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            startOffset  => $offset,
            maxItems     => $qty,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }
                my @items = map  { _albumItem($client, $_->{album}) }
                            grep { defined $_->{album} }
                            map  { _normalizeLibraryItem($_, 'album') }
                            @{$allItems};
                $callback->({ items => \@items, offset => $offset, total => $total });
            },
        });
    }
}

# _followedArtistsFeed($client, $callback, $args)
# Fetches ALL followed artists by chaining cursor-based API calls.
# Spotify's /me/following uses cursor pagination (no offset — Pitfall 4/7).
# We fetch 50 at a time until no more cursors remain, then return all at once.
sub _followedArtistsFeed {
    my ($client, $callback, $args) = @_;

    my $accountId = _getAccountId($client);

    _fetchAllFollowedArtists($client, $accountId, undef, [], sub {
        my ($allArtists, $err) = @_;
        my @items = map { _artistItem($client, $_) } @{$allArtists};
        if (!@items) {
            push @items, _authRequiredItem($client, $accountId, $err);
        }
        $callback->({ items => \@items });
    });
}

# _fetchAllFollowedArtists: on a fetch failure, $err is propagated up to
# $done (as the 2nd arg) so the caller's empty-result branch can distinguish
# "authentication required" from a genuine empty followed-artists list
# (Plan 03 Task 2 -- one of the 2 non-standard sites among the 17
# unless($data) call sites, since this internal paginator has no inline
# NO_RESULTS item of its own to substitute).
sub _fetchAllFollowedArtists {
    my ($client, $accountId, $after, $accumulated, $done) = @_;

    my %params = (limit => Plugins::SpotOn::API::SpClient->pageLimit('library'));
    $params{after} = $after if defined $after;

    Plugins::SpotOn::API::SpClient->getFollowedArtists($accountId, \%params, sub {
        my ($data, $err) = @_;
        unless ($data) {
            $done->($accumulated, $err);
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
# Reusable Async Paginator (Play-All Full Pagination + Bounded Fill)
# ============================================================

# _fetchPages($args)
# Generalized async paginator for offset-based Spotify API endpoints.
# Fetches pages recursively starting at $args->{startOffset}, stopping once
# $args->{maxItems} items are accumulated (or the API list is exhausted),
# and calls $args->{done} with the accumulated items.
#
# $args keys:
#   accountId    - Spotify account ID
#   apiFn        - coderef: $apiFn->($accountId, $params, $cb)
#                  $params contains offset and limit; $cb receives ($data, $err)
#   pageLimit    - max items per API page (50 for tracks/albums/episodes, 100 for
#                  playlist items). A falsy value (e.g. 0) never reaches the API —
#                  falls back to 50 (JVL-07).
#   extractItems - coderef: $extractItems->($data) returns arrayref of raw items
#                  Default: sub { $_[0]->{items} || [] }
#   extractTotal - coderef: $extractTotal->($data) returns the API's reported total
#                  Default: sub { $_[0]->{total} // 0 } -- override for endpoints
#                  whose total lives under a nested type key (e.g. search feeds).
#   startOffset  - offset to begin fetching from (default 0)
#   maxItems     - stop once this many items are accumulated (default undef = unbounded,
#                  i.e. play-all behavior identical to the former _fetchAllPages)
#   done         - callback: $done->(\@accumulated, $err, $safeTotal)
#                  $safeTotal is pre-clamped: on any partial/error/exhausted stop it
#                  never exceeds startOffset + scalar(@accumulated), so callers can pass
#                  it straight through to JiveLite without risking nil cache slots (JVL-06).
#
# T-25-01: Guards against infinite recursion — stops when current page returns 0 items,
# regardless of what the total field says. Prevents infinite loop on API inconsistencies.
# On a fetch failure, $err is propagated up to $done (as the 2nd arg) so
# callers' empty-result branch can distinguish "authentication required"
# from a genuine empty result set (Plan 03 Task 2 -- this shared paginator
# has no inline NO_RESULTS item of its own to substitute at its unless($data)
# site, unlike the 15 standard call sites).
sub _fetchPages {
    my ($args) = @_;

    _evictPlayAllCache();

    my $accountId    = $args->{accountId};
    my $apiFn        = $args->{apiFn};
    my $pageLimit    = $args->{pageLimit} || 50;    # JVL-07: never request limit=0
    my $extractItems = $args->{extractItems} || sub { $_[0]->{items} || [] };
    my $extractTotal = $args->{extractTotal} || sub { $_[0]->{total} // 0 };
    my $startOffset  = $args->{startOffset} // 0;
    my $maxItems     = $args->{maxItems};
    my $done         = $args->{done};

    if (defined $maxItems && $maxItems <= 0) {
        $done->([], undef, $startOffset);
        return;
    }

    my @accumulated;
    my $lastTotal = 0;

    my $fetchPage;
    $fetchPage = sub {
        my $requestOffset = $startOffset + scalar(@accumulated);
        my $requestLimit  = $pageLimit;
        if (defined $maxItems) {
            my $remaining = $maxItems - scalar(@accumulated);
            $requestLimit = $remaining if $remaining < $requestLimit;
        }
        $apiFn->($accountId, { offset => $requestOffset, limit => $requestLimit }, sub {
            my ($data, $err) = @_;
            unless ($data) {
                undef $fetchPage;
                $done->(\@accumulated, $err, $startOffset + scalar(@accumulated));
                return;
            }
            my $items = $extractItems->($data);
            my $itemCount = scalar(@{$items});
            push @accumulated, @{$items};

            # Overshoot trim: API may ignore a shrunk limit and return a full page.
            if (defined $maxItems && scalar(@accumulated) > $maxItems) {
                splice(@accumulated, $maxItems);
            }

            $lastTotal = $extractTotal->($data) // 0;

            my $reachedMax = defined($maxItems) && scalar(@accumulated) >= $maxItems;
            # T-25-01: stop if current page returned no items (prevents infinite loop)
            if (!$reachedMax && $itemCount > 0 && ($startOffset + scalar(@accumulated)) < $lastTotal) {
                $fetchPage->();
            } else {
                undef $fetchPage;
                my $safeTotal;
                if ($reachedMax) {
                    # Advertise the true API total (if larger) so JiveLite requests the next block.
                    my $filled = $startOffset + scalar(@accumulated);
                    $safeTotal = $lastTotal > $filled ? $lastTotal : $filled;
                } else {
                    # List exhausted, empty page, or shrunken list: clamp to what was delivered (JVL-06).
                    $safeTotal = $startOffset + scalar(@accumulated);
                }
                $done->(\@accumulated, undef, $safeTotal);
            }
        });
    };

    $fetchPage->();
}

# _fetchAllPages($args)
# Backward-compatible wrapper around _fetchPages for the 7 existing play-all
# call sites (unbounded fetch, 2-arg done callback -- the extra 3rd $safeTotal
# arg is simply ignored by callers that only destructure ($allItems, $err)).
sub _fetchAllPages {
    my ($args) = @_;
    _fetchPages($args);
}

# _userPlaylistsFeed($client, $callback, $args)
# Fetches user's playlists, excluding Made-For-You playlists (per D-03).
# Note: total from API includes Made-For-You playlists so displayed count may be
# slightly off — this is an accepted limitation documented in the plan (must_haves).
# Play-all detection (GH #121): same pattern as _artistAlbumsFeed — fetch all pages
# when quantity >= 500 to avoid LMS serving undef slots from cache.
sub _userPlaylistsFeed {
    my ($client, $callback, $args) = @_;

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my $cacheKey = "userPlaylists:$accountId";

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getUserPlaylists($acct, $params, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                my @user  = grep { !_isMadeForYou($_) } @{$allItems};
                my @items = map  { _playlistItem($client, $_) } @user;
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
                }
                $_playAllItemCache{$cacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
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
        goto &_userPlaylistsFeed;
    } else {
        # Bounded multi-page fill for fixed-size block clients (GH #157).
        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            startOffset  => $offset,
            maxItems     => $qty,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }
                # D-03: Exclude Made-For-You playlists from Library Playlists
                my @user  = grep { !_isMadeForYou($_) } @{$allItems};
                my @items = map  { _playlistItem($client, $_) } @user;
                $callback->({ items => \@items, offset => $offset, total => $total });
            },
        });
    }
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
            name  => cstring($client, 'PLUGIN_SPOTON_MY_PODCASTS'),
            url   => \&_savedShowsFeed,
            type  => 'link',
            image => 'plugins/SpotOn/html/images/podcasts.png',
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
# Play-all detection (GH #121): same pattern as _artistAlbumsFeed — fetch all pages
# when quantity >= 500 to avoid LMS serving undef slots from cache.
sub _savedShowsFeed {
    my ($client, $callback, $args) = @_;

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my $cacheKey = "savedShows:$accountId";

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getSavedShows($acct, { %$params, _noCache => 1 }, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                my @items = map  { _showItem($client, $_->{show}) }
                            grep { defined $_->{show} }
                            map  { _normalizeLibraryItem($_, 'show') }
                            @{$allItems};
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
                }
                $_playAllItemCache{$cacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
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
        goto &_savedShowsFeed;
    } else {
        # Bounded multi-page fill for fixed-size block clients (GH #157).
        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            startOffset  => $offset,
            maxItems     => $qty,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }
                # Pitfall 1: items are [{ added_at: "...", show: {...} }] — must unwrap {show}
                # CR-01: null-show guard — same pattern as _playlistFeed (line 1719-1721)
                my @items = map  { _showItem($client, $_->{show}) }
                            grep { defined $_->{show} }
                            map  { _normalizeLibraryItem($_, 'show') }
                            @{$allItems};
                $callback->({ items => \@items, offset => $offset, total => $total });
            },
        });
    }
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
        image         => _largestImage($show->{images}) || 'html/images/cover.png',
        favorites_url => $show_spoton,
        type          => 'playlist',
    };
}

# _showFeed($client, $callback, $args, $passthrough)
# Paginated episode list for a podcast show.
# Per POD-02: always uses getShowEpisodes (no embedded-episodes shortcut).
# Per Pitfall 2: response is { items, total } directly, not nested.
# Per D-09: API default order is newest first.
# Play-all detection: if quantity is undef (CLI/Material Skin "Play now") OR
# $qty >= 500 (Classic/Web UI "Play All"), AND $offset == 0, fetches ALL episodes
# via _fetchAllPages (Option D, Phase 54 Plan 04).
# In play-all mode, the Follow button is excluded (not a playable item).
sub _showFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $showId     = $passthrough->{showId}     // '';
    my $showUri    = $passthrough->{showUri}     // "spotify:show:$showId";
    my $showImages = $passthrough->{showImages};

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);
    my $hasFollowItem = ($accountId && $showUri =~ /^spotify:show:[A-Za-z0-9]+$/) ? 1 : 0;

    my $showCacheKey = "showEpisodes:$accountId:$showId";

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getShowEpisodes($acct, $showId, $params, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        # Play-all mode: fetch all episodes via full pagination, no Follow button
        my $showCtx = { images => $showImages, id => $showId, uri => $showUri, name => $passthrough->{showName} // '' };
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => 50,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                my @items = map { _episodeItem($client, $_, $showCtx) } @{$allItems};
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
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
        # Bounded multi-page fill for fixed-size block clients (GH #157).
        # Offset correction: index 0 = Follow button, index N (N>0) = episode at API offset N-1
        my $apiOffset  = ($hasFollowItem && $offset > 0) ? $offset - 1 : $offset;
        my $wantItems  = ($hasFollowItem && $offset == 0 && $qty > 1) ? $qty - 1 : $qty;

        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('library'),
            startOffset  => $apiOffset,
            maxItems     => $wantItems,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }
                my $showCtx = { images => $showImages, id => $showId, uri => $showUri, name => $passthrough->{showName} // '' };
                my @items = map { _episodeItem($client, $_, $showCtx) } @{$allItems};
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

                my $advertisedTotal = ($total // 0) + ($hasFollowItem ? 1 : 0);
                $callback->({ items => \@items, offset => $offset, total => $advertisedTotal });
            },
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

    my ($ep_path) = ($episode->{uri} // '') =~ /^spotify:((?:track|episode):[A-Za-z0-9]+)$/;
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

    require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
    $cache->set('spoton_meta_' . md5_hex($spoton_url), {
        _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
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
        name            => $title . $explicit_tag,
        favorites_title => $title . $explicit_tag,
        title           => $title,
        artist          => $showName,
        album           => $showName,
        line1         => $title . $explicit_tag,
        line2         => $line2,
        url           => $spoton_url,
        play          => $spoton_url,
        on_select     => 'play',
        image         => $image || 'html/images/cover.png',
        duration      => $duration,
        type          => 'audio',
        # spoton:// URL for LMS Favorites playback
        favorites_url => $spoton_url,
        # GH #94: More menu routed through the TrackInfo framework (episode
        # parity -- shows/episodes discrepancy called out in the issue).
        itemActions   => {
            info => {
                command     => ['spotoninfo', 'items'],
                fixedParams => { url => $spoton_url },
            },
        },
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
    Plugins::SpotOn::API::SpClient->getEpisode($accountId, $episodeId, sub {
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
# Totals come from single-type calls via _multiTypeSearch so overview counts match
# _podcastSearchTypeFeed drill-in totals (GH #130).
sub _podcastSearchFeed {
    my ($client, $callback, $args) = @_;

    my $query = $args->{search} // '';
    if ($query eq '') {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
        return;
    }

    my $accountId = _getAccountId($client);

    _multiTypeSearch($accountId, $query, ['show', 'episode'], sub {
        my ($results, $err) = @_;
        if ($err) {
            $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
            return;
        }

        my @items;

        my $showsTotal    = $results->{show}{total}    // 0;
        my $episodesTotal = $results->{episode}{total} // 0;
        # R-5: cap overview totals to match drill-in (50 for shows/episodes in Dev Mode)
        $showsTotal    = 50 if $showsTotal    > 50;
        $episodesTotal = 50 if $episodesTotal > 50;

        if ($showsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_SHOWS'),
                url         => \&_podcastSearchTypeFeed,
                passthrough => [{ query => $query, type => 'show' }],
                type        => 'link',
                image       => 'plugins/SpotOn/html/images/podcasts.png',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $showsTotal),
            };
        }
        if ($episodesTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_EPISODES'),
                url         => \&_podcastSearchTypeFeed,
                passthrough => [{ query => $query, type => 'episode' }],
                type        => 'link',
                image       => 'plugins/SpotOn/html/images/podcasts.png',
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
# Paginated drill-down into a single podcast search type (show or episode).
# Maps LMS index to API offset; returns offset/total for OPMLBased/XMLBrowser
# pagination (GH #130).
# Per D-12: limit capped at 10 (Dev Mode). Dispatches to _showItem or _episodeItem.
# Per Pitfall 4: episode search results use $episode->{show}{images} as artwork fallback.
# _podcastSearchTypeFeed($client, $callback, $args, $passthrough)
# GH #157: bounded multi-page fill for fixed-size JiveLite blocks — a
# 210-item block against Spotify's dev-mode search limit (10) needs up to
# 21 sequential calls; accepted per T-70-05, throttled by SpClient's
# central request gate.
sub _podcastSearchTypeFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $query  = $passthrough->{query} // '';
    my $type   = $passthrough->{type}  // 'show';
    my $offset = $args->{index}        // 0;
    my $qty    = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my %typeToKey = (show => 'shows', episode => 'episodes');
    my $key       = $typeToKey{$type} // "${type}s";

    _fetchPages({
        accountId    => $accountId,
        apiFn        => sub {
            my ($acct, $params, $cb) = @_;
            Plugins::SpotOn::API::SpClient->search($acct, {
                q      => $query,
                type   => $type,
                limit  => $params->{limit},
                offset => $params->{offset},
            }, $cb);
        },
        pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('search'),
        startOffset  => $offset,
        maxItems     => $qty,
        extractItems => sub { ($_[0]->{$key} || {})->{items} || [] },
        extractTotal => sub { ($_[0]->{$key} || {})->{total} },
        done         => sub {
            my ($allItems, $err, $total) = @_;
            if (!@$allItems && $err) {
                $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ], offset => $offset, total => 0 });
                return;
            }

            # R-4: map nameless entries to { ignore => 1 } placeholders instead of
            # filtering them out — XMLBrowser skips ignore-items and decrements
            # totalCount, so offset/total stay aligned with the API's paging.
            my @items = map {
                if (defined $_->{name} && $_->{name} =~ /\S/) {
                    ($type eq 'show') ? _showItem($client, $_) : _episodeItem($client, $_, undef);
                } else {
                    { ignore => 1 };
                }
            } @{$allItems};

            my $realCount = grep { !$_->{ignore} } @items;
            if (!$realCount && !$offset) {
                push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            # R-5: Spotify rejects offset >= 1000 for tracks/albums/artists/playlists,
            # but only >= 50 for shows/episodes in Dev Mode.
            my $maxOffset = ($type eq 'show' || $type eq 'episode') ? 50 : 1000;
            $total = $maxOffset if $total > $maxOffset;

            $callback->({ items => \@items, offset => $offset, total => $total });
        },
    });
}

# ============================================================
# Search Feeds (NAV-04, NAV-11, D-10)
# ============================================================

# _multiTypeSearch($accountId, $query, $types, $doneCb)
# Shared aggregator: ONE SpClient->search call with the comma-separated type
# list (one Pathfinder searchDesktop request for the whole overview, 85-08) and
# the merged results delivered to $doneCb.
#
# Contract:
#   $types   — arrayref of Spotify type names (e.g. ['track','album','artist','playlist'])
#   $doneCb  — called once with (\%results, $err, $limited).
#              %results is keyed by singular type name, each value is { total, items }.
#              $err is the search error, undef on success.
#              $limited is true when Pathfinder could not answer and only the
#              degraded (tracks only) result is delivered.
sub _multiTypeSearch {
    my ($accountId, $query, $types, $doneCb) = @_;

    # 85-08 (decision-SEARCH pathfinder-search): ONE call with the type list --
    # one searchDesktop request instead of one request per type (P-01 burst
    # prevention). The result is keyed by singular type name as before; the
    # third callback argument is true when Pathfinder could not answer and the
    # result is the degraded (tracks only) one.
    Plugins::SpotOn::API::SpClient->search($accountId, {
        q      => $query,
        type   => join(',', @$types),
        limit  => Plugins::SpotOn::API::SpClient->pageLimit('search'),
        offset => 0,
    }, sub {
        my ($data, $err) = @_;
        my %results;
        if ($data) {
            $results{$_} = $data->{"${_}s"} || {} for @$types;
        }
        $doneCb->(\%results, $data ? undef : $err, ($data && $data->{limited}) ? 1 : 0);
    });
}

# Search History Helpers
#
sub _recentSearches {
    my $list = $prefs->get('recentSearches');
    return [] unless ref $list eq 'ARRAY';
    return $list;
}

sub _addRecentSearch {
    my ($query) = @_;
    return unless defined $query && $query ne '';
    $query =~ s/^\s+|\s+$//g;
    return if $query eq '' || length($query) > 256;

    my $list = _recentSearches();

    return if @$list && $list->[-1] eq $query;

    $list = [ grep { $_ ne $query } @$list ];
    push @$list, $query;

    $list = [ @{$list}[ (-1 * MAX_RECENT_SEARCHES)..-1 ] ] if scalar @$list > MAX_RECENT_SEARCHES;

    $prefs->set('recentSearches', $list);
}

sub _searchPageFeed {
    my ($client, $callback, $args) = @_;

    if (($args->{search} // '') ne '') {
        _searchFeed($client, $callback, $args);
        return;
    }

    my $list = _recentSearches();
    my @items;

    push @items, {
        name  => cstring($client, 'PLUGIN_SPOTON_NEW_SEARCH'),
        type  => 'search',
        url   => \&_searchFeed,
    };

    for my $i ( reverse 0 .. $#$list ) {
        push @items, {
            name        => $list->[$i],
            type        => 'link',
            url         => \&_searchFromHistoryFeed,
            passthrough => [{ query => $list->[$i] }],
            cachetime   => 0,
            itemActions => {
                info => {
                    command     => ['spoton', 'recentsearches'],
                    fixedParams => { delete => $list->[$i] },
                },
            },
        };
    }

    if (@$list) {
        push @items, {
            name => cstring($client, 'PLUGIN_SPOTON_CLEAR_SEARCH_HISTORY'),
            type => 'link',
            url  => sub {
                my ($client, $cb) = @_;
                $prefs->set('recentSearches', []);
                _searchPageFeed($client, $cb, {});
            },
            nextWindow => 'refreshOrigin',
        };
    }

    $callback->({ items => \@items });
}

sub _recentSearchesCLI {
    my $request = shift;
    my $client  = $request->client;

    if ($request->isNotQuery([['spoton'], ['recentsearches']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $list = _recentSearches();

    if (defined(my $q = $request->getParam('delete'))) {
        unless (grep { $_ eq $q } @$list) {
            $request->setStatusBadParams();
            return;
        }

        my $items = [
            {
                text => cstring($client, 'DELETE') . cstring($client, 'COLON') . ' "' . $q . '"',
                actions => {
                    go => {
                        player => 0,
                        cmd    => ['spoton', 'recentsearches'],
                        params => { confirm_delete => $q },
                    },
                },
                nextWindow => 'parent',
            },
            {
                text => cstring($client, 'PLUGIN_SPOTON_CLEAR_SEARCH_HISTORY'),
                actions => {
                    go => {
                        player => 0,
                        cmd    => ['spoton', 'recentsearches'],
                        params => { deleteAll => 1 },
                    },
                },
                nextWindow => 'grandParent',
            },
        ];

        $request->addResult('offset', 0);
        $request->addResult('count', scalar @$items);
        $request->addResult('item_loop', $items);
    }
    elsif (defined(my $cq = $request->getParam('confirm_delete'))) {
        $prefs->set('recentSearches', [ grep { $_ ne $cq } @$list ]);
    }
    elsif (defined $request->getParam('deleteAll')) {
        $prefs->set('recentSearches', []);
    }
    else {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusDone;
}

# _trackInfoItemsCLI($request)
# GH #94: CLI backend for the browse items' `info` itemAction
# (['spotoninfo','items'] with a url fixedParam). Builds the SAME feed as
# the Now Playing More menu via Slim::Menu::TrackInfo->menu() -- LMS
# standard items (favorites, More Info, ...) plus every registered
# provider (spotonTrackInfo: Artist View / Album View / Like / Add to
# Playlist; GH-93 url override) -- and serves it through XMLBrowser.
#
# LMS 8.x gap bridged here: TrackInfo::menu() requires a track object, but
# Slim::Schema::RemoteTrack->fetch() is cache-only (RemoteTrack.pm), so a
# browse item that has never been PLAYED has no RemoteTrack yet and
# Slim::Schema->objectForUrl() returns undef. A RemoteTrack is therefore
# created on demand from the spoton_meta cache before building the menu --
# display data still flows from ProtocolHandler::getMetadataFor via the
# same cache, the object mainly has to exist.
sub _trackInfoItemsCLI {
    my $request = shift;

    if ($request->isNotQuery([['spotoninfo'], ['items']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $client = $request->client;
    my $url    = $request->getParam('url') || '';

    # T-76-08: spoton:// urls carry public track/episode ids only; strict
    # shape check before the url reaches Schema/TrackInfo.
    unless ($url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$}) {
        $request->setStatusBadParams();
        return;
    }

    require Slim::Schema;
    require Slim::Menu::TrackInfo;
    require Slim::Control::XMLBrowser;

    my $track = Slim::Schema->objectForUrl({ url => $url });
    unless (blessed($track)) {
        my $meta = $cache->get('spoton_meta_' . md5_hex($url)) || {};
        # 79-43 (D-33 FULL-3 CR-01): a record without the current format marker can hold the byte form of the
        # names (beta.1); it is the miss it would be without a record.
        require Plugins::SpotOn::API::SpClient;
        $meta = {} unless ($meta->{_spoton_fmt} // 0) >= Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT();
        $track = Slim::Schema->updateOrCreate({
            url        => $url,
            attributes => {
                title  => $meta->{title},
                artist => $meta->{artist},
                album  => $meta->{album},
                secs   => $meta->{duration},
            },
        });
    }

    unless (blessed($track)) {
        main::INFOLOG && $log->is_info && $log->info("spotoninfo: no track object for $url (GH #94)");
        $request->setStatusBadParams();
        return;
    }

    my $tags = {
        menuMode    => $request->getParam('menu') || 0,
        menuContext => $request->getParam('context') || 'normal',
    };

    my $feed = Slim::Menu::TrackInfo->menu($client, $url, $track, $tags);
    unless ($feed) {
        $request->setStatusBadParams();
        return;
    }

    Slim::Control::XMLBrowser::cliQuery('spotoninfo', $feed, $request);
}

# _searchFromHistoryFeed($client, $callback, $args, $passthrough)
# Thin shim that replays a recent search without re-adding it to history.
# Called when the user taps a history entry from _searchPageFeed.
sub _searchFromHistoryFeed {
    my ($client, $callback, $args, $passthrough) = @_;
    $args->{search} = $passthrough->{query} // '';
    $args->{_fromHistory} = 1;
    _searchFeed($client, $callback, $args);
}

# _searchFeed($client, $callback, $args)
# Entry point for the Search type item. LMS passes the search query in $args->{search}.
# Per D-10: Top Result shown prominently above category sections.
# Categories with 0 results are hidden entirely (D-10).
# Per NAV-11: limit=10 per type (Dev Mode maximum).
# Totals come from the same Pathfinder section as the _searchTypeFeed drill-in
# totals (GH #130); the whole overview is ONE searchDesktop request (P-01/NFL-03).
# When Pathfinder cannot answer, the overview says so (PLUGIN_SPOTON_SEARCH_LIMITED).
sub _searchFeed {
    my ($client, $callback, $args) = @_;

    my $query = $args->{search} // '';
    if ($query eq '') {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
        return;
    }

    my $accountId = _getAccountId($client);

    _multiTypeSearch($accountId, $query, ['track', 'album', 'artist', 'playlist'], sub {
        my ($results, $err, $limited) = @_;
        if ($err) {
            $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
            return;
        }

        my @items;

        # D-19-style visible line: search runs in the degraded (tracks only) mode.
        if ($limited) {
            push @items, {
                name => cstring($client, 'PLUGIN_SPOTON_SEARCH_LIMITED'),
                type => 'textarea',
            };
        }

        # D-10: Top Result — first track from search results, shown inline (not as sub-menu).
        my $trackItems = $results->{track}{items} || [];
        if (@{$trackItems}) {
            my $topTrack = $trackItems->[0];
            push @items, {
                name  => cstring($client, 'PLUGIN_SPOTON_TOP_RESULT'),
                items => [ _trackItem($client, $topTrack) ],
                type  => 'outline',
                image => 'plugins/SpotOn/html/images/search.png',
            };
        }

        # Category sections — skip those with 0 results (D-10).
        my $tracksTotal    = $results->{track}{total}     // 0;
        my $albumsTotal    = $results->{album}{total}     // 0;
        my $artistsTotal   = $results->{artist}{total}    // 0;
        my $playlistsTotal = $results->{playlist}{total}  // 0;
        # R-5: cap overview totals at 1000 (same as drill-in) to avoid count mismatch
        $tracksTotal    = 1000 if $tracksTotal    > 1000;
        $albumsTotal    = 1000 if $albumsTotal    > 1000;
        $artistsTotal   = 1000 if $artistsTotal   > 1000;
        $playlistsTotal = 1000 if $playlistsTotal > 1000;

        if ($tracksTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_TRACKS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'track' }],
                type        => 'link',
                image       => 'plugins/SpotOn/html/images/song.png',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $tracksTotal),
            };
        }
        if ($albumsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ALBUMS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'album' }],
                type        => 'link',
                image       => 'plugins/SpotOn/html/images/album.png',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $albumsTotal),
            };
        }
        if ($artistsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_ARTISTS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'artist' }],
                type        => 'link',
                image       => 'plugins/SpotOn/html/images/artist.png',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $artistsTotal),
            };
        }
        if ($playlistsTotal > 0) {
            push @items, {
                name        => cstring($client, 'PLUGIN_SPOTON_PLAYLISTS'),
                url         => \&_searchTypeFeed,
                passthrough => [{ query => $query, type => 'playlist' }],
                type        => 'link',
                image       => 'plugins/SpotOn/html/images/playlist.png',
                line2       => cstring($client, 'PLUGIN_SPOTON_N_RESULTS', $playlistsTotal),
            };
        }

        if (!grep { ($_->{type} // '') ne 'textarea' } @items) {
            push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
        } else {
            # Store successful search in history (skip if called from history replay)
            _addRecentSearch($query) unless $args->{_fromHistory};
        }

        $callback->({ items => \@items });
    });
}

# _searchTypeFeed($client, $callback, $args, $passthrough)
# Paginated drill-down into a single search type (track, album, artist, or playlist).
# Per NAV-11: limit capped at 10 (Dev Mode). Maps LMS index/quantity to offset/limit.
# _searchTypeFeed($client, $callback, $args, $passthrough)
# GH #157: bounded multi-page fill for fixed-size JiveLite blocks — a
# 210-item block against Spotify's dev-mode search limit (10) needs up to
# 21 sequential calls; accepted per T-70-05, throttled by SpClient's
# central request gate.
sub _searchTypeFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $query  = $passthrough->{query} // '';
    my $type   = $passthrough->{type}  // 'track';
    my $offset = $args->{index}        // 0;
    my $qty    = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my %typeToKey = (
        track    => 'tracks',
        album    => 'albums',
        artist   => 'artists',
        playlist => 'playlists',
    );
    my $key = $typeToKey{$type} // "${type}s";

    # 85-08: set when any page came from the degraded search (Pathfinder down)
    my $limited = 0;

    _fetchPages({
        accountId    => $accountId,
        apiFn        => sub {
            my ($acct, $params, $cb) = @_;
            Plugins::SpotOn::API::SpClient->search($acct, {
                q      => $query,
                type   => $type,
                limit  => $params->{limit},
                offset => $params->{offset},
            }, sub {
                my ($data, $e) = @_;
                $limited = 1 if $data && ref $data eq 'HASH' && $data->{limited};
                $cb->($data, $e);
            });
        },
        pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('search'),
        startOffset  => $offset,
        maxItems     => $qty,
        extractItems => sub { ($_[0]->{$key} || {})->{items} || [] },
        extractTotal => sub { ($_[0]->{$key} || {})->{total} },
        done         => sub {
            my ($allItems, $err, $total) = @_;
            if (!@$allItems && $err) {
                $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ], offset => $offset, total => 0 });
                return;
            }

            # R-4: map nameless entries to { ignore => 1 } placeholders instead of
            # filtering them out — XMLBrowser skips ignore-items and decrements
            # totalCount, so offset/total stay aligned with the API's paging.
            my %typeToItem = (
                track    => \&_trackItem,
                album    => \&_albumItem,
                artist   => \&_artistItem,
                playlist => \&_playlistItem,
            );
            my $itemFn = $typeToItem{$type} // \&_trackItem;

            my @items = map {
                (defined $_->{name} && $_->{name} =~ /\S/) ? $itemFn->($client, $_) : { ignore => 1 }
            } @{$allItems};

            my $realCount = grep { !$_->{ignore} } @items;
            if (!$realCount && !$offset) {
                # an empty page of the degraded search says why instead of "no results"
                push @items, { name => cstring($client, $limited ? 'PLUGIN_SPOTON_SEARCH_LIMITED' : 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
            }

            # R-5: Spotify search rejects offset >= 1000 — cap advertised total.
            $total = 1000 if $total > 1000;

            $callback->({ items => \@items, offset => $offset, total => $total });
        },
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
            image       => 'plugins/SpotOn/html/images/album.png',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_SINGLES'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'single' }],
            type        => 'link',
            image       => 'plugins/SpotOn/html/images/album.png',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_COMPILATIONS'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'compilation' }],
            type        => 'link',
            image       => 'plugins/SpotOn/html/images/album.png',
        },
        {
            name        => cstring($client, 'PLUGIN_SPOTON_APPEARS_ON'),
            url         => \&_artistAlbumsFeed,
            passthrough => [{ artistId => $artistId, includeGroups => 'appears_on' }],
            type        => 'link',
            image       => 'plugins/SpotOn/html/images/album.png',
        },
    );

    $callback->({ items => \@items });
}

# _artistAlbumsFeed($client, $callback, $args, $passthrough)
# Fetches paginated albums for an artist filtered by a SINGLE include_groups value.
# Per D-09/Pitfall 1: never combine include_groups values — issues separate request per type.
# Play-all detection (GH #121): Material Skin sends quantity=25000 which exceeds the
# artist_albums API limit (20). Without fetching all pages, LMS caches undef slots
# beyond the first page and serves empty items on scroll.
sub _artistAlbumsFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $artistId      = $passthrough->{artistId}      // '';
    my $includeGroups = $passthrough->{includeGroups} // 'album';

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);
    my $cacheKey  = "artistAlbums:$accountId:$artistId:$includeGroups";

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getArtistAlbums($acct, $artistId, {
            include_groups => $includeGroups,
            offset         => $params->{offset},
            limit          => $params->{limit},
        }, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('artist_albums'),
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                my @items = map { _albumItem($client, $_) } @{$allItems};
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
                }
                $_playAllItemCache{$cacheKey} = { items => \@items, ts => time() };
                $callback->({ items => \@items });
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
        goto &_artistAlbumsFeed;
    } else {
        # Bounded multi-page fill for fixed-size block clients (GH #157).
        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('artist_albums'),
            startOffset  => $offset,
            maxItems     => $qty,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }
                my @items = map { _albumItem($client, $_) } @{$allItems};
                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }
                $callback->({ items => \@items, offset => $offset, total => $total // 0 });
            },
        });
    }
}

# ============================================================
# Album Detail Feed (NAV-06)
# ============================================================

# _albumFeed($client, $callback, $args, $passthrough)
# Shows numbered tracklist for an album.
# Per NAV-06: line1 = "$track_number. $title", line2 = featuring artists (if differ from album artist).
# For index=0 (browse): uses tracks embedded in getAlbum response.
# For index>0 (browse): fetches separate getAlbumTracks page.
# Play-all detection: if quantity is undef (CLI/Material Skin "Play now") OR
# $qty >= 500 (Classic/Web UI "Play All"), AND $offset == 0, fetches ALL tracks
# via _fetchAllPages (Option D, Phase 54 Plan 04),
# seeding the accumulator with the first-page tracks already in the getAlbum response.
# Album artwork and artist are passed via passthrough for subsequent pages.
sub _albumFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $albumId          = $passthrough->{albumId}          // '';
    my $albumImages      = $passthrough->{albumImages};    # undef on first load
    my $albumArtist      = $passthrough->{albumArtist}      // '';
    my $albumName        = $passthrough->{albumName}        // '';    # WR-01: carried for metadata cache
    my $albumReleaseDate = $passthrough->{albumReleaseDate} // '';    # carried for release year in track metadata

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);
    my $albumCacheKey = "album:$accountId:$albumId";

    # GH #157: hoisted getAlbumTracks apiFn closure, shared by both browse
    # branches below (offset==0 continuation seed + offset>0 pages). The
    # play-all branch's inline paginator stays independent/untouched (JVL-08).
    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getAlbumTracks($acct, $albumId, $params, $cb);
    };

    if ($isPlayAll && $offset == 0) {
        # Play-all mode: first fetch full album for metadata + seed tracks, then paginate remaining
        Plugins::SpotOn::API::SpClient->getAlbum($accountId, $albumId, sub {
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
            my $albumRd     = $album->{release_date} // '';

            if ($total <= scalar(@{$seedTracks})) {
                # All tracks already in getAlbum response — no further API calls needed
                # FIX-01: defer metadata cache writes.
                my @deferredMeta;
                my @items = map { _albumTrackItem($client, $_, $images, $artist0, $albumNm, { defer_cache => \@deferredMeta, albumReleaseDate => $albumRd }) } @{$seedTracks};
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
                Plugins::SpotOn::API::SpClient->getAlbumTracks($accountId, $albumId, {
                    offset => $pageOffset,
                    limit  => Plugins::SpotOn::API::SpClient->pageLimit('album_tracks'),
                }, sub {
                    # NON-UNIFORM site (review finding #4): on fetch failure, fall back to
                    # any accumulated tracks from prior pages -- only replace the inner
                    # if (!@items) NO_RESULTS push with _authRequiredItem; the outer
                    # unless($data) block and the partial-result fallback itself are
                    # preserved exactly as before.
                    my ($data, $err) = @_;
                    unless ($data) {
                        undef $fetchPage;
                        # FIX-01: defer metadata cache writes.
                        my @deferredMeta;
                        my @items = map { _albumTrackItem($client, $_, $images, $artist0, $albumNm, { defer_cache => \@deferredMeta, albumReleaseDate => $albumRd }) } @accumulated;
                        if (!@items) {
                            push @items, _authRequiredItem($client, $accountId, $err);
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
                        my @items = map { _albumTrackItem($client, $_, $images, $artist0, $albumNm, { defer_cache => \@deferredMeta, albumReleaseDate => $albumRd }) } @accumulated;
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
        # GH #157: if quantity exceeds the embedded seed tracks and the album has
        # more, continue fetching via getAlbumTracks (embedded-seed + continuation).
        Plugins::SpotOn::API::SpClient->getAlbum($accountId, $albumId, sub {
            my $album = shift;
            unless ($album) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' }] });
                return;
            }

            my $images    = $album->{images}           || [];
            my $artist0   = ($album->{artists} && @{$album->{artists}}) ? $album->{artists}[0]{name} : '';
            my $total     = ($album->{tracks} && $album->{tracks}{total}) ? $album->{tracks}{total} : 0;
            my $tracks    = ($album->{tracks} && $album->{tracks}{items}) ? $album->{tracks}{items} : [];
            my $seedCount = scalar(@$tracks);

            if ($total <= $seedCount || $qty <= $seedCount) {
                # Embedded seed already covers the request -- no getAlbumTracks call needed.
                # WR-03: deliver at most $qty items (bounded-fill contract); total stays
                # the real album total so JiveLite can request the next block.
                my $deliver = ($qty < $seedCount) ? $qty : $seedCount;
                my @items = map { _albumTrackItem($client, $_, $images, $artist0, $album->{name}, { albumReleaseDate => $album->{release_date} // '' }) } @{$tracks}[0 .. $deliver - 1];

                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }

                $callback->({ items => \@items, offset => 0, total => $total });
                return;
            }

            # JiveLite case: quantity (up to 210) exceeds the <=50 embedded tracks
            # and the album has more -- continue from where the seed left off.
            my @deferredMeta;
            _fetchPages({
                accountId   => $accountId,
                apiFn       => $apiFn,
                pageLimit   => Plugins::SpotOn::API::SpClient->pageLimit('album_tracks'),
                startOffset => $seedCount,
                maxItems    => $qty - $seedCount,
                done        => sub {
                    my ($fetched, $err, $combinedTotal) = @_;
                    # WR-01: the embedded seed (@$tracks) is always non-empty here, so
                    # test the continuation result itself -- surface auth errors only
                    # when the getAlbumTracks fill failed and delivered nothing.
                    if (!@$fetched && $err) {
                        $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                        return;
                    }
                    # FIX-01: defer metadata cache writes.
                    my @items = map { _albumTrackItem($client, $_, $images, $artist0, $album->{name}, { defer_cache => \@deferredMeta, albumReleaseDate => $album->{release_date} // '' }) } (@$tracks, @$fetched);

                    if (!@items) {
                        push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                    }

                    $callback->({ items => \@items, offset => 0, total => $combinedTotal });
                    _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
                },
            });
        });
    } else {
        # Subsequent browse pages: bounded multi-page fill via getAlbumTracks (GH #157).
        _fetchPages({
            accountId   => $accountId,
            apiFn       => $apiFn,
            pageLimit   => Plugins::SpotOn::API::SpClient->pageLimit('album_tracks'),
            startOffset => $offset,
            maxItems    => $qty,
            done        => sub {
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }

                # FIX-01: defer metadata cache writes.
                my @deferredMeta;
                my @items = map { _albumTrackItem($client, $_, $albumImages, $albumArtist, $albumName, { defer_cache => \@deferredMeta, albumReleaseDate => $albumReleaseDate }) } @$allItems;

                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }

                $callback->({ items => \@items, offset => $offset, total => $total });
                _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
            },
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
    my $year      = (ref $opts eq 'HASH' && $opts->{albumReleaseDate})
                        ? _releaseYear($opts->{albumReleaseDate})
                        : '';

    # Show featuring artists in line2 only when they differ from album's primary artist.
    my $line2 = ($artists && $artists ne ($albumArtist // '')) ? $artists : '';

    # Context navigation: artist view (no album view — already in album context).
    # UX-05: label-bearing text items MUST come first so XMLBrowser populates $details
    # and enables Play/Queue/Favorites buttons in the Default skin info view.
    my @contextItems;
    if ($artists) {
        push @contextItems, {
            name  => $artists,
            type  => 'text',
            label => 'ARTIST',
        };
    }
    if ($albumName) {
        push @contextItems, {
            name  => $albumName,
            type  => 'text',
            label => 'ALBUM',
        };
    }
    if ($year) {
        push @contextItems, {
            name  => $year,
            type  => 'text',
            label => 'YEAR',
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

    # T-04.1-01: Extract path from Spotify URI to prevent double-prefix.
    # spotify:track:ID -> track:ID; fallback preserves original URI if no match.
    my ($track_path) = ($track->{uri} // '') =~ /^spotify:((?:track|episode):[A-Za-z0-9]+)$/;
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
            year     => $year,
            track    => $track,
            client   => $client,
        };
    } else {
        my %trackIds = _extractTrackIds($track);
        require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
        $cache->set('spoton_meta_' . md5_hex($spoton_url), {
            _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
            title    => $title,
            artist   => $artists,
            album    => $albumName,
            duration => $duration,
            cover    => $image,
            icon     => $image,
            year     => $year,
            bitrate  => __PACKAGE__->_bitrateForClient($client) . 'k',
            type     => __PACKAGE__->_typeString($client, 'Browse'),
            %trackIds,
        }, 604800);
    }

    my %item = (
        name            => ($trackNum ? "$trackNum. " : '') . $title,
        favorites_title => ($trackNum ? "$trackNum. " : '') . $title,
        title           => $title,
        artist          => $artists,
        album           => $albumName || '',
        line1     => ($trackNum ? "$trackNum. " : '') . $title,
        line2     => $line2,
        url       => $spoton_url,
        play      => $spoton_url,
        on_select => 'play',
        playall   => 1,    # Context queueing for album track tap (D-09)
        image     => $image || 'html/images/cover.png',
        duration  => $duration,
        type      => 'audio',
        # GH #94: More menu routed through the TrackInfo framework -- one
        # menu source for browse and Now Playing.
        itemActions => {
            info => {
                command     => ['spotoninfo', 'items'],
                fixedParams => { url => $spoton_url },
            },
        },
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
# Play-all detection: if quantity is undef (CLI/Material Skin "Play now") OR
# $qty >= 500 (Classic/Web UI "Play All"), AND $offset == 0, fetches ALL tracks
# via _fetchAllPages (Option D, Phase 54 Plan 04).
# Every playlist, Spotify-made 37i9 mixes included, is read through spclient
# playlist/v2 (SpClient->getPlaylistItems, 85-08).
sub _playlistFeed {
    my ($client, $callback, $args, $passthrough) = @_;

    my $playlistId = $passthrough->{playlistId} // '';

    my $offset    = $args->{index}    // 0;
    my $isPlayAll = !defined($args->{quantity}) || ($args->{quantity} >= 500);
    my $qty       = $args->{quantity} || 200;

    my $accountId = _getAccountId($client);

    my $apiFn = sub {
        my ($acct, $params, $cb) = @_;
        Plugins::SpotOn::API::SpClient->getPlaylistItems($acct, $playlistId, $params, $cb);
    };

    my $plCacheKey = "playlist:$accountId:$playlistId";

    if ($isPlayAll && $offset == 0) {
        # Play-all mode: fetch all playlist tracks via full pagination
        _fetchAllPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => 100,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                my ($allItems, $err) = @_;
                # T-03-10: Skip null track entries (local files in playlists return null track objects).
                # FIX-01: defer metadata cache writes to avoid blocking event loop with N SQLite INSERTs.
                my @deferredMeta;
                my @items = map  { _trackItem($client, $_->{track}, { defer_cache => \@deferredMeta }) }
                            grep { defined $_->{track} }
                            map  { _normalizeLibraryItem($_, 'track') }
                            @{$allItems};
                if (!@items) {
                    push @items, _authRequiredItem($client, $accountId, $err);
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
        # Bounded multi-page fill for fixed-size block clients (GH #157).
        _fetchPages({
            accountId    => $accountId,
            apiFn        => $apiFn,
            pageLimit    => Plugins::SpotOn::API::SpClient->pageLimit('playlist_items'),
            startOffset  => $offset,
            maxItems     => $qty,
            extractItems => sub { $_[0]->{items} || [] },
            done         => sub {
                # NON-UNIFORM site (review finding #4): the error source is
                # spclient playlist/v2 here, not the Web API.
                # _authRequiredItem still works correctly here -- it checks
                # accountNeedsMigration/needsReauth state, not the error source.
                # Existing graceful-degradation behavior (no partial-cache
                # fallback at this site) is otherwise unchanged.
                my ($allItems, $err, $total) = @_;
                if (!@$allItems && $err) {
                    $callback->({ items => [ _authRequiredItem($client, $accountId, $err) ] });
                    return;
                }

                # T-03-10: Skip null track entries (local files in playlists return null track objects).
                # FIX-01: defer metadata cache writes to avoid blocking event loop with up to 210 SQLite INSERTs.
                my @deferredMeta;
                my @items = map  { _trackItem($client, $_->{track}, { defer_cache => \@deferredMeta }) }
                            grep { defined $_->{track} }
                            map  { _normalizeLibraryItem($_, 'track') }
                            @{$allItems};

                if (!@items) {
                    push @items, { name => cstring($client, 'PLUGIN_SPOTON_NO_RESULTS'), type => 'textarea' };
                }

                $callback->({ items => \@items, offset => $offset, total => $total // 0 });
                _flushDeferredMeta(undef, \@deferredMeta, 0) if @deferredMeta;
            },
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

    my $fmt;

    # 74b-02 (D-08, supersedes WR-03 / D-09): the label comes from the SAME
    # mapping playback uses (DaemonManager->effectiveFormat ->
    # ProtocolHandler->contentTypeFor), so the type written into every
    # spoton_meta_* cache entry is what LMS will really stream: a FLAC choice
    # the player cannot play (D-15) and Auto before the 74b-06 flip are
    # labelled PCM, sync-group downgrades included. The cheap read is used on
    # purpose: _typeString runs once per menu item, and effectiveOutput's
    # checkBin diagnosis would log a warning per item when lame is missing.
    # Eval-guarded: an undef client or a resolver that cannot run labels PCM.
    if ($client) {
        my $effective = eval {
            require Plugins::SpotOn::Unified::DaemonManager;
            (Plugins::SpotOn::Unified::DaemonManager->effectiveFormat($client))[0];
        };
        if ($@) {
            main::INFOLOG && $log->is_info && $log->info("effectiveFormat failed: $@");
            $fmt = 'pcm';
        }
        else {
            $fmt = $effective || 'pcm';
        }
    }
    else {
        $fmt = 'pcm';
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
            $log->warn("[DIAG] Watchdog: newsong but playingSong=undef (streamingSong=$sUrl) - deferring 0.5s");
        }
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, sub {
            my $c = shift;
            my $s = $c->playingSong() || return;
            my $u = $s->track->url || '';
            return unless $u =~ m{^spoton://(?!connect-)};
            # Pitfall 3: under D-04, spoton://track: URLs match both Browse
            # and Connect.  The URL gate no longer encodes Browse-vs-Connect;
            # guard against watchdog arming on a Connect session.
            # 83.1-07: verified correct after claim binding (plan 02) --
            # the URL scheme still does not discriminate, D-C3 group B.
            require Plugins::SpotOn::Connect;
            return if Plugins::SpotOn::Connect->isSpotifyConnect($c);
            my $d = $s->duration || 0;
            $log->warn("[DIAG] Watchdog: deferred newsong url=$u duration=${d}s") if $prefs->get('diagnosticMode');
            return unless $d > 0;
            Slim::Utils::Timers::setTimer($c, Time::HiRes::time() + 10, \&_prefetchWatchdog);
        });
        return;
    }
    my $url = $song->track->url || '';

    return unless $url =~ m{^spoton://(?!connect-)};
    # Pitfall 3: under D-04, spoton://track: URLs match both Browse
    # and Connect.  Guard against watchdog arming on a Connect session.
    # 83.1-07: verified correct after claim binding (plan 02) -- the URL
    # scheme still does not discriminate, D-C3 group B.
    require Plugins::SpotOn::Connect;
    return if Plugins::SpotOn::Connect->isSpotifyConnect($client);

    my $duration = $song->duration || 0;

    $log->warn("[DIAG] Watchdog: newsong url=$url duration=${duration}s") if $prefs->get('diagnosticMode');

    return unless $duration > 0;

    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + 10,
        \&_prefetchWatchdog,
    );
}

# ============================================================
# Fresh metadata on track start (79-27 D-20)
# ============================================================
# A track list is hydrated from a cache that lives 90 days (D-19), so a renamed track would show its old title
# in NowPlaying. When a Browse track starts, that ONE track is fetched fresh (SpClient->getTrack with
# { refresh => 1 }: no cache read, the result overwrites the entry) and an existing spoton_meta_<md5 url> record
# gets the fresh title/artist/album/duration/cover/icon; its other fields (type, bitrate, ids, year) stay.
#   - Connect sessions are skipped: Connect.pm _fetchTrackMetadata refreshes those track starts itself.
#   - spoton://connect-* and spoton://episode:* never match (only spoton://track:<22 base62> does).
#   - Debounced per track id for META_REFRESH_DEBOUNCE seconds (T-79-91: no storm from repeated newsong events).
#   - A sync group fires newsong per member; only the master asks (one fetch per track start).
use constant META_REFRESH_DEBOUNCE => 60;
my %_metaRefreshedAt;

sub _onNewSongRefreshMeta {
    my $request = shift;
    my $client = $request->client() || return;
    _refreshMetaForClient($client->master || $client, 0);
}

sub _refreshMetaForClient {
    my ($client, $deferred) = @_;

    my $song = $client->playingSong();
    unless ($song) {
        # newsong can fire before playingSong is set (the watchdog above has the same case): look once more shortly after
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, sub { _refreshMetaForClient($_[0], 1) }) unless $deferred;
        return;
    }
    my $url  = ($song->track && $song->track->url) || '';
    my ($trackId) = $url =~ m{^spoton://track:([0-9A-Za-z]{22})\z} or return;

    require Plugins::SpotOn::Connect;
    return if Plugins::SpotOn::Connect->isSpotifyConnect($client);

    my $now = time();
    if (keys %_metaRefreshedAt > 200) {
        delete @_metaRefreshedAt{ grep { $now - $_metaRefreshedAt{$_} >= META_REFRESH_DEBOUNCE } keys %_metaRefreshedAt };
    }
    return if defined $_metaRefreshedAt{$trackId} && $now - $_metaRefreshedAt{$trackId} < META_REFRESH_DEBOUNCE;
    $_metaRefreshedAt{$trackId} = $now;

    require Plugins::SpotOn::API::SpClient;
    Plugins::SpotOn::API::SpClient->getTrack(_getAccountId($client), $trackId, sub {
        my ($track, $err) = @_;

        unless ($track && !$err) {
            main::INFOLOG && $log->is_info && $log->info(
                "Track start refresh for $trackId failed (" . (ref $err eq 'HASH' ? ($err->{error} // '?') : '?') . ") - cached metadata kept"
            );
            return;
        }

        my $key = 'spoton_meta_' . md5_hex($url);
        my $rec = $cache->get($key) or return;   # no NowPlaying record yet -> nothing to refresh
        my $image = _largestImage(($track->{album} || {})->{images});

        my %fresh = (
            %$rec,
            title    => $track->{name} // $rec->{title},
            artist   => join(', ', map { $_->{name} } @{ $track->{artists} || [] }),
            album    => ($track->{album} || {})->{name} // '',
            duration => ($track->{duration_ms} || 0) / 1000,
            _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),   # 79-43: the names above are fresh characters
        );
        $fresh{cover} = $fresh{icon} = $image if $image;
        $cache->set($key, \%fresh, 604800);
    }, { refresh => 1 });
}

sub _onModeChange {
    my $request = shift;
    my $client = $request->client() || return;
    my $id = $client->id;
    my $song = $client->playingSong();
    my $url = $song ? ($song->track->url || '') : 'none';
    return unless $url =~ m{^spoton://(?!connect-)};
    # Pitfall 3: under D-04, spoton://track: URLs match both Browse
    # and Connect.  Guard against pause-guard on a Connect session.
    # 83.1-07: verified correct after claim binding (plan 02) -- the URL
    # scheme still does not discriminate, D-C3 group B.
    require Plugins::SpotOn::Connect;
    return if Plugins::SpotOn::Connect->isSpotifyConnect($client);
    my $mode = Slim::Player::Source::playmode($client) || '?';

    if ($mode eq 'pause' && !$_pauseRequestedAt{_reapplying}) {
        $_pauseRequestedAt{$id} = Time::HiRes::time();
        $_pauseRequestedSong{$id} = [ $song->index, $url ];    # 79-32 D-27
        Slim::Utils::Timers::killTimers($client, \&_pauseGuardCheck);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2.5, \&_pauseGuardCheck);
    } elsif ($mode eq 'play') {
        delete $_pauseRequestedAt{$id};
        delete $_pauseRequestedSong{$id};
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
        delete $_pauseRequestedSong{$id};
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
    # Pitfall 3: under D-04, spoton://track: URLs match both Browse and
    # Connect.  Integrate the Connect check into the cleanup gate so the
    # pending-state delete still runs when the URL is wrong or Connect.
    # 83.1-07: verified correct after claim binding (plan 02) -- the URL
    # scheme still does not discriminate, D-C3 group B.
    require Plugins::SpotOn::Connect;
    unless ($url =~ m{^spoton://(?!connect-)}
            && !Plugins::SpotOn::Connect->isSpotifyConnect($client))
    {
        delete $_pauseRequestedAt{$id};
        delete $_pauseRequestedSong{$id};
        return;
    }

    # 79-32 (D-27): the guard exists for a pause swallowed on the SAME song (459c1dfd). Once the playing song changed after
    # the pause request (a skip, a replaced playlist) a Play is the user's, not a swallowed pause: drop the guard and never
    # re-apply. [index, url] instead of the Song object: a resume may rebuild the object for the same title.
    my $req = $_pauseRequestedSong{$id};
    if ($req) {
        my $now = $song->index;
        if (!defined $now || !defined $req->[0] || $now != $req->[0] || $url ne $req->[1]) {
            delete $_pauseRequestedAt{$id};
            delete $_pauseRequestedSong{$id};
            $log->warn(sprintf('[DIAG] PauseGuard: dropped, song changed since the pause request (%s:%s -> %s:%s) mac=%s',
                $req->[0] // '?', $req->[1], $now // '?', $url, $id)) if $prefs->get('diagnosticMode');
            return;
        }
    }

    my $mode = Slim::Player::Source::playmode($client) || '';
    my $age = Time::HiRes::time() - $_pauseRequestedAt{$id};

    if ($mode eq 'play') {
        $log->warn("[DIAG] PauseGuard: re-applying pause (swallowed ${age}s ago) mac=$id") if $prefs->get('diagnosticMode');
        delete $_pauseRequestedAt{$id};
        delete $_pauseRequestedSong{$id};
        $_pauseRequestedAt{_reapplying} = 1;
        Slim::Control::Request::executeRequest($client, ['pause', '1']);
        delete $_pauseRequestedAt{_reapplying};
    } elsif ($age < 5.0) {
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1.0, \&_pauseGuardCheck);
    } else {
        delete $_pauseRequestedAt{$id};
        delete $_pauseRequestedSong{$id};
    }
}

sub _prefetchWatchdog {
    my $client = shift;
    return unless $client;

    my $song = $client->playingSong() || return;
    my $url = $song->track->url || '';
    return unless $url =~ m{^spoton://(?!connect-)};
    # Pitfall 3: under D-04, spoton://track: URLs match both Browse
    # and Connect.  Guard against watchdog arming on a Connect session.
    # 83.1-07: verified correct after claim binding (plan 02) -- the URL
    # scheme still does not discriminate, D-C3 group B.
    require Plugins::SpotOn::Connect;
    return if Plugins::SpotOn::Connect->isSpotifyConnect($client);
    return unless Slim::Player::Source::playmode($client) eq 'play';

    # Guard 1: playmode 'play' includes BUFFERING — after an LMS restart
    # with squeezelite still connected, STMt play-point data refers to the
    # previous stream (or is jiffies-extrapolation garbage) until the new
    # track reaches PLAYING. isPlaying(1) is false during BUFFERING.
    unless ($client->isPlaying(1)) {
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&_prefetchWatchdog);
        return;
    }

    my $duration = $song->duration || 0;
    return unless $duration > 0;

    my $rawElapsed = $client->songElapsedSeconds() || 0;
    my $startOffset = $song->startOffset || 0;
    my $elapsed = $rawElapsed + $startOffset;

    # Guard 2: the 2s poll cadence catches a real near-end hang within
    # ~3s of crossing duration-3, so elapsed > duration+30 cannot come
    # from real playback of this track.
    if ($elapsed > $duration + 30) {
        $log->warn("Prefetch watchdog: implausible elapsed ${elapsed}s for ${duration}s track - ignoring stale play point");
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&_prefetchWatchdog);
        return;
    }

    if ($elapsed >= $duration - 3) {
        my $id = $client->id;
        $_watchdogTriggerUrl{$id} = $url;
        $log->warn("[DIAG] Watchdog: near end (elapsed=${elapsed}s, duration=${duration}s) - arming 10s hang check") if $prefs->get('diagnosticMode');
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

    # Pitfall 3: _prefetchHangCheck has no URL gate — it fires from a
    # timer armed by _prefetchWatchdog.  Guard against the race where the
    # session becomes Connect between _prefetchWatchdog arming the timer
    # and this callback firing (trigger state already consumed above so
    # the pending state is cleaned up regardless).
    # 83.1-07 (D-C3 group B): verified correct after claim binding (plan
    # 02) -- for a Control-backed (Soloist) player this guard is now
    # defense-in-depth (watchdogRing itself also gates on mode='browse'),
    # but for a librespot player (no Control instance) it remains the ONLY
    # brake against a blind `playlist jump +1` landing on a live Connect
    # session -- KEEP.
    require Plugins::SpotOn::Connect;
    return if Plugins::SpotOn::Connect->isSpotifyConnect($client);

    my $song = $client->playingSong();
    my $currentUrl = $song ? ($song->track->url || '') : '';

    if ($currentUrl eq $triggerUrl && Slim::Player::Source::playmode($client) eq 'play') {
        # D-02/D-03 (82-06): the watchdog is a timer, never a second
        # decider (S-01 Setup B: the blind jump below overwrote the
        # daemon's own result in 6/6 runs before it reached LMS). On a
        # player with a player engine, hand the ring to it and let its
        # reconcile primitives decide (84-08: notify('watchdogRing') on the
        # backend role); the jump below is UNCHANGED for 'unsupported'
        # (librespot) and 'down' (no engine instance). The warn text is
        # kept verbatim: extract-run.pl's watchdog Runde-1 category
        # (quick-260923-hgj) and t/46 match it.
        require Plugins::SpotOn::Unified::DaemonManager;
        if (Plugins::SpotOn::Unified::DaemonManager->backendFor($client)->notify('watchdogRing', url => $triggerUrl) eq 'ok') {
            $log->warn("Prefetch watchdog: still on same track after 10s past end - handing to Soloist::Control (D-02)");
            return;
        }
        $log->warn("Prefetch watchdog: still on same track after 10s past end - forcing skip");
        $client->execute(['playlist', 'jump', '+1']);
    }
}

1;
