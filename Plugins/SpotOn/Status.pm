package Plugins::SpotOn::Status;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# D-01/D-02/D-03 Auth Health Dashboard (moved from Settings.pm): shared cache
# instance for passive reads of the audio-key cohort state and last-API-call
# timestamps written by TokenManager.pm/DaemonManager.pm. Same instantiation
# pattern as those modules (single source of truth: Plugin.pm
# SPOTON_CACHE_VERSION; Plugin.pm always compiles before Status.pm in
# production, matching the M5 convention documented in TokenManager.pm).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# Ring-buffer for recent errors (newest at end; returned in reverse order)
my @_errorHistory;
use constant MAX_ERROR_HISTORY => 30;

# System info cache (D-03): loaded once per LMS session
my $_systemInfo;

# ============================================================
# Constructor
# ============================================================

sub new {
    my $class = shift;

    require Slim::Web::Pages;

    # Register status.html as a page function so LMS serves and TT-processes it
    Slim::Web::Pages->addPageFunction(
        'plugins/SpotOn/status.html',
        \&_statusPageHandler
    );

    # Register JSON data endpoint
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/status/data',
        \&_statusDataHandler
    );

    return bless {}, $class;
}

# ============================================================
# Public class method: recordError
# ============================================================

sub recordError {
    my ($class, $level, $module, $message) = @_;

    push @_errorHistory, {
        ts      => time(),
        level   => $level,
        module  => $module,
        message => $message,
    };

    # Trim oldest entries beyond MAX_ERROR_HISTORY
    shift @_errorHistory while scalar @_errorHistory > MAX_ERROR_HISTORY;
}

# ============================================================
# Handler: /plugins/SpotOn/status.html (TT page)
# ============================================================

sub _statusPageHandler {
    my ($client, $params) = @_;
    return Slim::Web::HTTP::filltemplatefile('plugins/SpotOn/status.html', $params);
}

# ============================================================
# Handler: /plugins/SpotOn/status/data
# ============================================================

sub _statusDataHandler {
    my ($httpClient, $response) = @_;

    # No CSRF check — read-only endpoint (D-12)

    my %data;

    # Each collector is eval-guarded so a broken module or missing method
    # at startup returns partial data rather than crashing the handler (CR-01).

    # --- Daemons ---
    $data{daemons} = eval { _collectDaemons() } // [];
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _collectDaemons failed: $@");
    }

    # --- API telemetry ---
    require Plugins::SpotOn::API::Client;
    $data{api} = eval { Plugins::SpotOn::API::Client->statusSnapshot() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: statusSnapshot failed: $@");
    }

    # --- Errors (newest first) ---
    $data{errors} = eval { _errorHistory() } // [];

    # --- Tokens ---
    $data{tokens} = eval { _collectTokens() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _collectTokens failed: $@");
    }

    # --- Made For You (Web-Player) state (D-04 channel 3) ---
    require Plugins::SpotOn::API::WebPlayer;
    $data{madeForYou} = eval { Plugins::SpotOn::API::WebPlayer->statusSnapshot() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: WebPlayer statusSnapshot failed: $@");
    }

    # CR-01 gap closure (Plan 52-06): hashConfigured lets the Status page
    # distinguish "Pathfinder hash not set" (admin action needed) from other
    # Made For You degradation states. Reads the pref directly -- no need to
    # require Client.pm for this.
    $data{madeForYou}{hashConfigured} = (length($prefs->get('pathfinderHash') || '') > 0) ? 1 : 0;

    # --- System info (D-05: cached, computed once) ---
    $data{system} = eval { _systemInfo() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _systemInfo failed: $@");
    }

    # --- Auth Health (D-01/D-02/D-03, moved from Settings.pm) — per-account
    # 5-indicator aggregation. Every read inside _collectAuthHealth is a
    # passive cache/prefs/accessor query -- zero outbound API calls triggered
    # by page render (T-54-02/T-54-06).
    require Plugins::SpotOn::API::TokenManager;
    my %authHealth;
    for my $id (Plugins::SpotOn::API::TokenManager->getAccountIds()) {
        $authHealth{$id} = eval { _collectAuthHealth($id) } // {};
        if ($@) {
            main::INFOLOG && $log->is_info && $log->info("Status: _collectAuthHealth($id) failed: $@");
        }
    }
    $data{authHealth} = \%authHealth;

    _jsonResponse($httpClient, $response, \%data);
}

# ============================================================
# Data collectors
# ============================================================

sub _collectDaemons {
    my @daemons;

    require Plugins::SpotOn::Unified::DaemonManager;
    require Slim::Player::Client;
    for my $helper (Plugins::SpotOn::Unified::DaemonManager->helperInstances()) {
        my $mac  = $helper->mac;
        my $name = $mac;

        my $client = Slim::Player::Client::getClient($mac);
        $name = $client->name if $client && $client->can('name');

        my $playing      = 0;
        my $currentTrack = undef;
        my $syncGroup    = undef;

        if ($client) {
            # Playback status: only report when playing a SpotOn track
            if ($client->isPlaying) {
                my $url = Slim::Player::Playlist::url($client) || '';
                if ($url =~ /^spoton:/) {
                    $playing = 1;
                    require Plugins::SpotOn::ProtocolHandler;
                    my $meta = Plugins::SpotOn::ProtocolHandler->getMetadataFor($client, $url);
                    $currentTrack = $meta->{title} if $meta && $meta->{title};
                }
            }

            # Sync group members
            if ($client->isSynced()) {
                my @members;
                for my $peer ($client->syncGroupActiveMembers()) {
                    push @members, $peer->name if $peer->id ne $mac;
                }
                $syncGroup = \@members if @members;
            }
        }

        push @daemons, {
            mac            => $mac,
            name           => $name,
            alive          => $helper->alive ? 1 : 0,
            pid            => $helper->pid || 0,
            uptime         => int($helper->uptime || 0),
            connectEnabled => $helper->_connectEnabled ? 1 : 0,
            streamPort     => $helper->_streamPort // undef,
            playing        => $playing,
            currentTrack   => $currentTrack,
            syncGroup      => $syncGroup,
            sessionHealth  => $helper->_lastHealthSession,
        };
    }

    return \@daemons;
}

sub _collectTokens {
    require Plugins::SpotOn::API::TokenManager;
    return {
        accountCount => scalar(Plugins::SpotOn::API::TokenManager->getAccountIds()),
    };
}

# ============================================================
# _collectAuthHealth($accountId)
# D-01/D-02/D-03/D-08 (moved from Settings.pm): passive, read-only
# aggregation of the 6 per-account auth chain health indicators consumed by
# the Status page's Auth Health card (status.html). Every value here comes
# from a cache/prefs/accessor query -- this helper NEVER makes an outbound
# HTTP/API call (T-54-02/T-54-06 threat mitigation). Returns a hashref with
# keys: pkce, spDc, connect, migration, audioKey, playback. Self-contained
# (require's its own collaborators) rather than relying on
# _statusDataHandler's requires.
# ============================================================
sub _collectAuthHealth {
    my ($accountId) = @_;

    require Plugins::SpotOn::API::PKCE;
    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::API::WebPlayer;
    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::Unified::DaemonManager;

    my %health;

    # 1. PKCE Status (D-01) -- token present, refresh valid, last API call time.
    $health{pkce} = {
        hasToken    => Plugins::SpotOn::API::PKCE::loadTokens($accountId) ? 1 : 0,
        needsReauth => Plugins::SpotOn::API::TokenManager->needsReauth($accountId),
        lastApiCall => $cache->get("spoton_last_api_call_" . $accountId) || undef,
    };

    # 2. sp_dc Cookie Status (Made For You, D-04/D-08) -- masked preview only,
    # never the raw cookie (T-54-02).
    $health{spDc} = {
        state         => Plugins::SpotOn::API::WebPlayer->state($accountId),
        maskedPreview => Plugins::SpotOn::API::WebPlayer->spDcMaskedPreview($accountId),
    };

    # 3. Connect Status -- a single account may drive multiple daemons
    # (multi-player setups). Report the first alive helper for this account,
    # falling back to the first helper found at all if none are alive.
    my @matching = grep { ($_->_accountId || '') eq $accountId }
        Plugins::SpotOn::Unified::DaemonManager->helperInstances();
    my ($chosen) = grep { $_->alive } @matching;
    $chosen ||= $matching[0];

    my %connect = (alive => 0, pid => 0, uptime => 0);
    if ($chosen) {
        %connect = (
            alive  => $chosen->alive ? 1 : 0,
            pid    => $chosen->pid || 0,
            uptime => int($chosen->uptime || 0),
        );
    }
    $health{connect} = \%connect;

    # 4. Migration Status (D-05) -- v2.x ZeroConf accounts without PKCE tokens.
    $health{migration} = {
        needed => Plugins::SpotOn::API::TokenManager->accountNeedsMigration($accountId),
    };

    # 5. Audio-Key Cohort (D-02, passive) -- innocent-until-proven-guilty
    # default 'ok' (matches needsReauth/WebPlayer::state defaults). 'throttled'
    # has a 600s TTL and auto-clears back to 'ok' (absence = ok); 'denied'
    # persists permanently (TTL 'never', written by DaemonManager Plan 54-01).
    $health{audioKey} = {
        state => $cache->get("spoton_audiokey_state_" . $accountId) || 'ok',
    };

    # 6. Playback Credentials (D-08, GH #147 plan 66-02) -- the Web API
    # token (indicator 1 above) and the librespot playback credentials are
    # two independent halves of SpotOn's auth chain; this indicator answers
    # "can this account actually stream" separately from "can this account
    # call the Web API". hasCredentials is a passive local file read
    # (verifyCredentials never touches the network); source is the
    # provenance marker written by _installPairedCredentials ('zeroconf' |
    # 'keymaster' | '' for unset/legacy accounts). Never include username or
    # auth_data from the credentials file in this payload (T-66-05).
    my $accountsPref = $prefs->get('accounts') || {};
    $health{playback} = {
        hasCredentials => (Plugins::SpotOn::API::Credentials->verifyCredentials($accountId) ? 1 : 0),
        needsAuth      => Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId),
        reason         => Plugins::SpotOn::API::Credentials->playbackAuthReason($accountId),
        source         => ($accountsPref->{$accountId} && $accountsPref->{$accountId}{playbackCredSource}) || '',
    };

    return \%health;
}

sub _errorHistory {
    return [ reverse @_errorHistory ];
}

sub getErrorHistory {
    return _errorHistory();
}

sub _systemInfo {
    return $_systemInfo if $_systemInfo;

    require Plugins::SpotOn::Helper;
    require Plugins::SpotOn::Plugin;
    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    $_systemInfo = {
        pluginVersion => Plugins::SpotOn::Plugin->_pluginDataFor('version') || 'unknown',
        binaryVersion => $helperVersion || 'unknown',
        lmsVersion    => $::VERSION,
        perlVersion   => $],
        os            => $^O,
    };

    return $_systemInfo;
}

# ============================================================
# JSON response helper (verbatim from Settings.pm lines 466-475)
# ============================================================

sub _jsonResponse {
    my ($httpClient, $response, $data, $code) = @_;
    $code //= 200;
    my $bytes = to_json($data);
    $response->header('Content-Length' => length($bytes));
    $response->code($code);
    $response->header('Connection' => 'close');
    $response->content_type('application/json');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

1;
