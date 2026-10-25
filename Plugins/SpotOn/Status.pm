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

# 84-19 F-04-02-CLAIM: a 'warn' entry is a one-shot "this happened" notice
# (claim-conflict, refused-action, watchdog, 429 ...) whose condition is
# over by itself; left in the ring it reads as a standing fault for the
# rest of the LMS session. It expires WARN_TTL_S after it was recorded.
# 'error' entries (a standing condition such as 'unpaired') keep their
# lifetime: they leave only through clearError or ring eviction.
use constant WARN_TTL_S => 3600;

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

# _now() -- the clock seam (t/13 overrides it; no sleeping in tests).
sub _now { return time() }

# _expireWarnings() -- drops 'warn' entries older than WARN_TTL_S. Called
# from every reader (and the writer), so an expired entry is never visible
# and hasError() -- which Control._recordErrorOnce asks before trusting its
# dedupe lock -- reports it gone, letting a recurrence be recorded again.
sub _expireWarnings {
    my $now = _now();
    @_errorHistory = grep {
        !(($_->{level} // '') eq 'warn' && ($now - ($_->{ts} // $now)) >= WARN_TTL_S)
    } @_errorHistory;
}

sub recordError {
    my ($class, $level, $module, $message, $key) = @_;

    _expireWarnings();
    push @_errorHistory, {
        ts      => _now(),
        level   => $level,
        module  => $module,
        message => $message,
        (defined $key ? (key => $key) : ()),
    };

    # Trim oldest entries beyond MAX_ERROR_HISTORY
    shift @_errorHistory while scalar @_errorHistory > MAX_ERROR_HISTORY;
}

# clearError($class, $module, $key) -- 82-11 (Todo
# errors-startup-falschmeldung-nicht-paired): the ring above is
# intentionally thin (MAX_ERROR_HISTORY) and has no dedupe -- every write
# therefore needs a NAMED removal path, or a transient condition (a daemon
# still restoring its session at LMS startup, a drift retry that later
# catches up) becomes indistinguishable from a permanent one for the rest
# of the LMS session. Removes every entry whose module AND key both match
# $key; a no-op when nothing matches (e.g. $key undef, or a foreign
# module/key pair).
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;

    @_errorHistory = grep {
        !(($_->{module} // '') eq $module && defined($_->{key}) && $_->{key} eq $key)
    } @_errorHistory;
}

# hasError($class, $module, $key) -- 82-28 (WR-02, Review Runde 3): a pure
# query, no state change, same module+key comparison as clearError. The
# ring is the source of truth for whether an entry is still visible;
# Control.pm's _recordErrorOnce dedupe lock (observed->{errorsReported})
# does not know when the ring above has evicted an entry via
# MAX_ERROR_HISTORY's shift, so the lock can outlive the entry it mirrors.
# This lets the caller ask the ring directly instead of trusting a lock
# that may be stale.
# 74b WR-01: an optional $level narrows the match to entries of that level
# (a standing 'warn' under a key must not read as the 'error' under it).
sub hasError {
    my ($class, $module, $key, $level) = @_;
    return 0 unless defined $key;

    _expireWarnings();
    return scalar grep {
        ($_->{module} // '') eq $module && defined($_->{key}) && $_->{key} eq $key
            && (!defined $level || ($_->{level} // '') eq $level)
    } @_errorHistory;
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
    require Plugins::SpotOn::API::SpClient;
    $data{api} = eval { Plugins::SpotOn::API::SpClient->statusSnapshot() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: statusSnapshot failed: $@");
    }

    # --- Standing conditions (74b-03, D-09): re-assert before the list is
    # read, so an entry evicted from the ring (or lost with an LMS restart)
    # is back in this very response. can-guarded so a DaemonManager that
    # predates the method (or a test double) keeps working.
    eval {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->assertStandingConditions()
            if Plugins::SpotOn::Unified::DaemonManager->can('assertStandingConditions');
        1;
    } or main::INFOLOG && $log->is_info && $log->info("Status: assertStandingConditions failed: $@");

    # --- Errors (newest first) ---
    $data{errors} = eval { _errorHistory() } // [];

    # --- Tokens ---
    $data{tokens} = eval { _collectTokens() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _collectTokens failed: $@");
    }

    # --- Made For You: the Pathfinder health (85-09, D-19; decision-D17
    # pathfinder-login5-plus-rootlist is cookie-free, so no WebPlayer state
    # here). SpClient->madeForYouStatus carries eleven plain keys, no secret.
    $data{madeForYou} = eval { Plugins::SpotOn::API::SpClient->madeForYouStatus() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: madeForYouStatus failed: $@");
    }

    # --- System info (D-05: cached, computed once) ---
    $data{system} = eval { _systemInfo() } // {};
    if ($@) {
        main::INFOLOG && $log->is_info && $log->info("Status: _systemInfo failed: $@");
    }

    # --- Auth Health (D-01/D-02/D-03, moved from Settings.pm) — per-account
    # 4-indicator aggregation (login5, connect, audio key, playback). Every read inside _collectAuthHealth is a
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

        # T-7 (Phase 82): paired/wsConnected are signals of a backend with a
        # pairing concept -- the librespot role (Backend::Librespot, Phase
        # 84) has neither settings/Users nor a WS transport, so both stay
        # undef for it and $playing is untouched by the gate below.
        # 84-08 (SEAM-6.2): read from the backend role's state(). For the
        # backend that has them they are always defined (0|1) and carry the
        # SAME truth its player engine's reconcile decisions run on (82-11
        # WR-05: the observed field when the engine made the observation,
        # else the filesystem pairing / the live WS socket -- an unmade
        # observation is not a statement, not even a false one). Eval-
        # guarded: a load failure must not take the status page down.
        my $st = eval {
            Plugins::SpotOn::Unified::DaemonManager->backendFor($mac)->state;
        } || {};
        main::INFOLOG && $log->is_info && $log->info("Status: backend state failed for $mac: $@") if $@;
        my $paired      = $st->{paired};
        my $wsConnected = $st->{wsConnected};
        my $hasPairing  = defined $paired ? 1 : 0;

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

        # T-7 (Phase 82): a Soloist daemon that is unpaired or whose WS
        # path is dead is not actually playing -- even if LMS itself says
        # isPlaying (todos *ispaired-heuristik-falschpositiv*,
        # *soloistws-veralteter-ws-port-nach-respawn*). 82-11 WR-05: $paired/
        # $wsConnected above carry the player engine's own observation when
        # it made one -- this gate blocks the display on the SAME signal
        # that blocks requests, not on an independent filesystem read that
        # could (and live did) disagree.
        $playing = 0 if $hasPairing && !($paired && $wsConnected);

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
            paired         => $paired,
            wsConnected    => $wsConnected,
            # 84.1 plan 03 (D-04/D-05/D-06): controlMode/health exist only
            # for the backend with a player engine (undef for librespot --
            # its state has no mode, and soloistHealthFor only ever gets
            # vivified by DaemonManager's Soloist health tick).
            controlMode    => $st->{mode},
            health         => $hasPairing
                ? Plugins::SpotOn::Unified::DaemonManager->soloistHealthFor($mac)
                : undef,
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
# D-13 (85-09): passive, read-only aggregation of the per-account auth chain
# health indicators consumed by the Status page's Auth Health card
# (status.html). Every value here comes from a cache/prefs/accessor query --
# this helper NEVER makes an outbound HTTP/API call (T-54-02/T-54-06 threat
# mitigation). Returns a hashref with keys: login, connect, audioKey,
# playback. Self-contained (require's its own collaborators) rather than
# relying on _statusDataHandler's requires.
# ============================================================
sub _collectAuthHealth {
    my ($accountId) = @_;

    require Plugins::SpotOn::API::Login5;
    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::Unified::DaemonManager;

    my %health;

    # 1. Account login (login5, D-13): the last state a mint observed
    # ('ok' | 'invalid_credentials' | 'no_credentials' | 'transient', else
    # 'unknown'), whether usable credentials exist, and whether the account
    # still has to be paired (85-10 sets needsPairing). Never the username or
    # auth_data (T-85-29).
    my $acct = ($prefs->get('accounts') || {})->{$accountId} || {};
    $health{login} = {
        state          => Plugins::SpotOn::API::Login5->loginState($accountId) // 'unknown',
        hasCredentials => (Plugins::SpotOn::API::Credentials->verifyCredentials($accountId) ? 1 : 0),
        needsPairing   => ($acct->{needsPairing} ? 1 : 0),
    };

    # 2. Connect Status -- a single account may drive multiple daemons
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

    # 3. Audio-Key Cohort (D-02, passive) -- innocent-until-proven-guilty
    # default 'ok'. 'throttled' has a 600s TTL and auto-clears back to 'ok'
    # (absence = ok); 'denied' persists permanently (TTL 'never', written by
    # DaemonManager Plan 54-01).
    $health{audioKey} = {
        state => $cache->get("spoton_audiokey_state_" . $accountId) || 'ok',
    };

    # 4. Playback Credentials (D-08, GH #147 plan 66-02) -- the librespot
    # playback credentials, the other half of the chain next to the login5
    # state above: "can this account actually stream". hasCredentials is a
    # passive local file read (verifyCredentials never touches the network);
    # source is the provenance marker written by _installPairedCredentials
    # ('zeroconf' | 'keymaster' | '' for unset/legacy accounts). Never include
    # username or auth_data from the credentials file in this payload (T-66-05).
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
    _expireWarnings();
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
