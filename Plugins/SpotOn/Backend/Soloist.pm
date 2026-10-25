package Plugins::SpotOn::Backend::Soloist;

# Phase 84-07 (SEAM-6.2): the Soloist implementation of the backend role.
#
# Soloist::Control IS the engine (§6.2: "Soloist::Control ist die
# Soloist-Implementierung der Rolle"); this class only translates the role
# vocabulary to Control's request primitives and back:
#   request* truthy -> 'ok', 0 -> 'declined' (Control refused on a
#   precondition it owns: mode, ownership, availableActions, ...),
#   no Control instance for this player -> 'down'.
#
# Soloist WITHOUT a Control instance (84-07 decision, confirmed by the user
# at Task 0 on 2026-10-11, "Just log \"down\""): control() returns 'down'
# and does NOTHING else -- no fallthrough into the librespot HTTP/Web-API
# path. The caller logs the outcome once at info.

use strict;
use warnings;

use Scalar::Util qw(weaken);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

sub new {
    my ($class, $mac) = @_;
    return bless { mac => $mac }, $class;
}

sub mac { return $_[0]->{mac}; }

sub daemonClass { return 'Plugins::SpotOn::Unified::SoloistDaemon'; }

sub client {
    my $self = shift;
    if (@_) {
        $self->{client} = shift;
        weaken($self->{client}) if ref $self->{client};
    }
    return $self->{client} if $self->{client};
    return Slim::Player::Client::getClient($self->{mac});
}

# _ctl -- this player's Control instance, or undef.
sub _ctl {
    my $self = shift;
    require Plugins::SpotOn::Soloist::Control;
    return Plugins::SpotOn::Soloist::Control->for_client($self->{mac});
}

# capabilitiesDefault() -- class method (84-08): the player-independent
# capability keys. ProtocolHandler::contentType has no client and reads
# this through DaemonManager->backendClass; capabilities() on an instance
# returns these merged with the remaining keys.
my %CAPABILITIES_DEFAULT = (
    contentType       => 'soc',
    samplesize        => 32,                    # D-04: raw S32LE from fake-libpulse's /stream
    samplerate        => 44100,
    channels          => 2,
    connectEntry      => 'pertrack',            # one LMS entry per Spotify track
    formats           => 'resolveSoloistFormat',
    deferTrack        => 1,
    connectClaimGate  => 0,                     # Control owns the classification (Befund 3)
    claimOnStart      => 0,                     # D-D1: bound only by Control's transfer class
    holdOnChange      => 1,                     # 84-17 change hold
    passthrough       => 0,                     # 84-12 (W6): raw PCM only, never Ogg passthrough
);

sub capabilitiesDefault { return { %CAPABILITIES_DEFAULT }; }

sub capabilities {
    require Plugins::SpotOn::Soloist::Control;
    return {
        %CAPABILITIES_DEFAULT,
        seekViaRestart    => 1,                     # D-B1: the LMS restart chain carries the seek
        connectSeekViaControl => 0,                 # 79-28 D-23: Soloist keeps the restart chain (D-B1), no /control/seek
        ownsQueueInBrowse => 0,                     # LMS owns the Browse playlist, Control follows it
        deaden            => [],
        # 84-08: Connect.pm's spottyconnect `ready` re-entry replays the LAST
        # announced track (eventTrackUri) as its own per-track entry instead
        # of a repeating connect-<ts> stream.
        readyReplaysLastTrack => 1,
        holdCapS          => Plugins::SpotOn::Soloist::Control::HOLD_CAP_S(),
        holdRecheckS      => Plugins::SpotOn::Soloist::Control::HOLD_RECHECK_S(),
        holdMaxS          => Plugins::SpotOn::Soloist::Control::HOLD_MAX_S(),
        # 84-13 (Settings::Player canAutoplay): pinned from today's player
        # page, which read the core Helper's `autoplay` capability for every
        # backend. The enableAutoplay pref it gates is consumed by the
        # librespot daemon only (Unified/Daemon.pm --autoplay).
        autoplay          => _helperAutoplay(),
    };
}

sub _helperAutoplay {
    my $cap = eval {
        require Plugins::SpotOn::Helper;
        Plugins::SpotOn::Helper->getCapability('autoplay');
    };
    return $cap ? 1 : 0;
}

# state() -> { mode status paired wsConnected alive observedTrack active }
# 84-08: paired / wsConnected carry the Status page's truth (82-11 WR-05):
# Control's observed field when it has made the observation, otherwise
# the filesystem pairing (settings/Users) resp. the daemon's live WS
# socket -- an unmade observation is not a statement, not even a false
# one. Both are always defined (0|1) for this backend; the librespot role
# answers undef ("no pairing concept"). alive = an alive daemon object.
sub state {
    my $self = shift;
    my $mac  = $self->{mac};
    my $ctl  = $self->_ctl;
    my $observed = $ctl ? ($ctl->observed || {}) : {};

    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($mac);

    my $paired = defined $observed->{paired} ? ($observed->{paired} ? 1 : 0) : do {
        # eval-guarded: a load failure in Soloist.pm must not take down a
        # status read -- fail closed (0), not silent.
        my $fs = eval {
            require Plugins::SpotOn::Soloist;
            Plugins::SpotOn::Soloist::isPairedForClient($mac) ? 1 : 0;
        } // 0;
        main::INFOLOG && $log->is_info && $log->info("Backend::Soloist: isPairedForClient failed for $mac: $@") if $@;
        $fs;
    };
    my $wsConnected = defined $observed->{wsConnected} ? ($observed->{wsConnected} ? 1 : 0) : do {
        my $ws = ($helper && $helper->can('_ws')) ? $helper->_ws : undef;
        ($ws && $ws->connected) ? 1 : 0;
    };

    return {
        mode          => $ctl ? $ctl->mode : undef,
        status        => $observed->{status},
        paired        => $paired,
        wsConnected   => $wsConnected,
        alive         => ($helper && $helper->alive) ? 1 : 0,
        observedTrack => $observed->{track},
        active        => defined $observed->{is_active} ? ($observed->{is_active} ? 1 : 0) : undef,
    };
}

sub _outcome { return $_[0] ? 'ok' : 'declined'; }

# control($verb, %args) -> ok | declined | unsupported | down
# Mapping (84-07 interfaces): play -> requestResume ; pause ->
# requestPause($isStop) ; set_volume -> requestVolume(int) ; skip_next|
# skip_prev -> requestSkip('next'|'prev', $reason) ; restart ->
# requestRestart($reason) ; seek -> position_ms == 0 ? requestSkip('prev',
# 'time0') : ok (acknowledgement only -- the LMS restart chain getSeekData
# -> onStream -> requestTrack carries the seek, D-B1) ; track(source
# getNextTrack) -> _trackFromGetNextTrack (requestTrack, or one of the
# three defer cases without a Control instance) ; track(source onStream)
# -> _trackFromOnStream (84-08: the moved onStream body).
my %VERBS = map { $_ => 1 } qw(play pause seek skip_next skip_prev set_volume track restart);

sub control {
    my ($self, $verb, %args) = @_;
    $verb //= '';
    return 'unsupported' unless $VERBS{$verb};

    if ($verb eq 'track') {
        my $source = $args{source} // '';
        return $self->_trackFromGetNextTrack(%args) if $source eq 'getNextTrack';
        return $self->_trackFromOnStream(%args)     if $source eq 'onStream';
        return 'unsupported';
    }

    my $ctl = $self->_ctl;
    unless ($ctl) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Backend::Soloist: control($verb) for " . ($self->{mac} // '?') . " -- no Control instance (down)"
        );
        return 'down';
    }

    if ($verb eq 'pause')      { return _outcome($ctl->requestPause($args{isStop} ? 1 : 0)); }
    if ($verb eq 'play')       { return _outcome($ctl->requestResume); }
    if ($verb eq 'set_volume') { return _outcome($ctl->requestVolume(int($args{volume} // 0))); }
    if ($verb eq 'skip_next')  { return _outcome($ctl->requestSkip('next', $args{reason})); }
    if ($verb eq 'skip_prev')  { return _outcome($ctl->requestSkip('prev', $args{reason})); }
    if ($verb eq 'restart')    { return _outcome($ctl->requestRestart($args{reason})); }

    if ($verb eq 'seek') {
        return _outcome($ctl->requestSkip('prev', 'time0')) if int($args{position_ms} // 0) == 0;
        return 'ok';
    }

    return 'unsupported';
}

# _trackFromGetNextTrack(%args) -- ProtocolHandler::getNextTrack's Soloist
# Browse block, moved here in 84-08 (SEAM-6.2) together with the 84.2-05
# one-shot marker and the three defer cases. Args: url, position_ms, song,
# duration, successCb, errorCb.
#
# Phase 82 Plan 01 (Neuausrichtung §3.1(4)): the ONLY entry point for a
# Browse track/position change is Control->requestTrack -- the core sends
# no WS command itself and reads no WS state (T-1, T-3). Command
# classification (resume/prefetch-hit/mismatch/arm) all lives in Control.
sub _trackFromGetNextTrack {
    my ($self, %args) = @_;
    my $url  = $args{url} // '';
    my $song = $args{song};
    my $client = ($song && $song->can('master') && $song->master) || $self->client;
    my $mac    = $client ? $client->id : $self->{mac};

    # 84.2-05 (debug b6-prefetch-b7-africa-replay): `origin` from Connect.pm's
    # one-shot dispatch marker (client pluginData connectOwnPlayUri, stamped at
    # its own `playlist play` sites and in _holdOpen). Consumed here by EVERY
    # getNextTrack of this client whatever its url -- a stale marker for
    # another title never survives; 'connect' only when it names this url, 'lms'
    # otherwise. Control's same-uri connect rule reads it. Seekdata is no signal
    # (an LMS-UI seek re-streams the open song through onStream). The `can`
    # guard keeps stub clients without pluginData alive.
    my $ownPlay = ($client && $client->can('pluginData')) ? $client->pluginData('connectOwnPlayUri') : undef;
    $client->pluginData(connectOwnPlayUri => '') if defined $ownPlay && length $ownPlay;
    my $origin = (defined $ownPlay && length $ownPlay && $ownPlay eq $url) ? 'connect' : 'lms';

    my $posMs = int($args{position_ms} // 0);

    # 79-33 (D-28 F3, LABELS-SKIP): LMS gets a once-only success/error pair for
    # every getNextTrack. One shared flag: whichever callback fires first wins,
    # any later fire (the same one again, or the other one) is dropped, so a
    # Control-internal double fire can never reach LMS's _nextTrackError and
    # make it skip a title that was already accepted. An undefined original
    # stays undefined.
    my $fired  = 0;
    my $origOk = ref $args{successCb} eq 'CODE' ? $args{successCb} : undef;
    my $origEr = ref $args{errorCb}   eq 'CODE' ? $args{errorCb}   : undef;
    my $onceOk = $origOk ? sub { return if $fired; $fired = 1; return $origOk->(@_); } : undef;
    my $onceEr = $origEr ? sub { return if $fired; $fired = 1; return $origEr->(@_); } : undef;

    my %opts = (
        successCb => $onceOk, errorCb => $onceEr, source => 'getNextTrack',
        duration  => $args{duration}, origin => $origin,
    );

    my $ctl = $self->_ctl;
    unless ($ctl) {
        # Phase 82 Plan 44 (D-09/D-10/D-11, Runde 44): three cases, in
        # this order.
        require Plugins::SpotOn::Unified::DaemonManager;
        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($mac);

        # Case 1 (Zustand c, F5): a daemon OBJECT of this backend already
        # exists but its Control instance has not been built yet
        # (Control->new only runs once _pollWsPort's on_found fires).
        # 260914-qn1's deferral -- structurally unchanged (82-CONTEXT.md
        # D-09 "Verhaeltnis zu 260914-qn1"); its deadline comes from
        # DeferBudget::deadlineFor inside the daemon's deferTrackRequest.
        if ($helper && $helper->isa($self->daemonClass)) {
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: soloist browse -> deferring on SoloistDaemon (Signature C, Control not built yet; mac="
                . ($mac // '?') . ")"
            );
            $helper->deferTrackRequest($url, $posMs, \%opts);
            return 'ok';
        }

        # Case 2 (Zustaende a/b, F1 -- the actual Signatur-C fix, D-09/
        # D-10): no daemon object exists AT ALL for this player yet. Ask
        # DaemonManager for SPAWN-CAPABILITY (not helper existence) -- the
        # criterion the Messrunde-5 measurement identified as the one that
        # decides "will a daemon ever come", ~1,97s after an LMS restart,
        # ~2,5s before startHelper can run for the first time.
        my $state = Plugins::SpotOn::Unified::DaemonManager->backendPrereqState('soloist');

        if ($state eq 'soloist_ready') {
            main::INFOLOG && $log->is_info && $log->info(
                "getNextTrack: soloist browse -> deferring on DaemonManager (Signature C outer anchor, no daemon object yet; mac="
                . ($mac // '?') . ")"
            );
            ref($self)->deferTrackRequestForClient($mac, $url, $posMs, \%opts);
            return 'ok';
        }

        # Case 3 (D-11): the state is known and it is NOT 'soloist_ready'
        # -- no daemon will ever come for this player. Name the concrete
        # reason instead of a generic message.
        $onceEr->('PROBLEM_OPENING', _prereqFailureMessage($state)) if $onceEr;    # 79-33 (D-28 F3): once-only pair
        return 'down';
    }

    main::INFOLOG && $log->is_info && $log->info(
        "getNextTrack: soloist browse -> Control->requestTrack($url, $posMs) (mac="
        . ($mac // '?') . ") origin=$origin"
    );

    return _outcome($ctl->requestTrack($url, $posMs, \%opts));
}

# _trackFromOnStream(%args) -- ProtocolHandler::onStream's body after its
# master/url guards, moved here verbatim in 84-08. Args: url, song,
# duration. No Control instance -> 'down' and nothing else (the former
# `for_client or return`).
#
# onStream is THE consumer for both absicht-erfassende markers (Befund 1/3,
# D-04): a restart triggered by canDoAction('rew')/getSeekData (rewind,
# seek N, _Continue reconnect) is never visible to getNextTrack (Befund 1
# -- LMS's _JumpToTime bypasses it) and reaches Control only here. Without
# a marker or seekdata this call is the idempotent twin of getNextTrack for
# the SAME title -- requestTrack's own idempotency absorbs the double entry.
sub _trackFromOnStream {
    my ($self, %args) = @_;
    my $url  = $args{url} // '';
    my $song = $args{song};

    my $ctl = $self->_ctl or return 'down';

    my ($pos, $seek);
    if ($song && $song->can('seekdata') && $song->seekdata && defined $song->seekdata->{timeOffset}) {
        # Seek N (getSeekData's return value, Song::open's own "last
        # chance" re-application -- Song.pm:381).
        $pos  = int($song->seekdata->{timeOffset} * 1000);
        $seek = 1;

        # Debug session connect-seek-zeit-ab-null (2026-09-24): set LMS'
        # clock to the seek target HERE. Song::open resets startOffset to 0
        # on every (re)open ("handlers will set this if necessary") and LMS'
        # clock is startOffset + the player's elapsed time
        # (StreamingController::playingSongElapsed) -- it does NOT start at
        # N by itself. LMS' own handlers do the same (HTTP.pm requestString
        # "Fix progress bar", File.pm). Without it the clock ran from 0:00
        # after every browse seek and after every connect seek whose daemon
        # echo was suppressed. In connect, the daemon's echo (Connect.pm
        # CON-13 'seek': startOffset = position - elapsed) still overwrites
        # this absolutely when it comes -- never added on top. Only the
        # seekdata branch: the marker branch below is rewind (target 0 ==
        # Song::open's reset), and the clock only moves when a seek
        # actually goes out (no Control -> returned above).
        $song->startOffset($song->seekdata->{timeOffset});
    }
    else {
        # Rewind (canDoAction('rew')) or a plain restart with no marker --
        # consumeSeekIntent reads AND clears; undef on expiry/uri-mismatch
        # (Befund 3 (a)/(b)/(d): UPnP probe, _JumpPaused, Open-Fehler).
        my $marker = $ctl->consumeSeekIntent($url);
        if (defined $marker) {
            $pos  = $marker;
            $seek = 1;
        }
    }

    main::INFOLOG && $log->is_info && $log->info(
        "onStream: $url pos=" . ($pos // 0) . " seek=" . ($seek ? 1 : 0)
        . " (mac=" . ($self->{mac} // '?') . ")"
    );

    $ctl->requestTrack($url, $pos // 0, {
        source => 'onStream', seek => ($seek ? 1 : 0), duration => $args{duration},
    });

    # IN-01 (82-REVIEW.md): a seek-intent marker must NEVER survive
    # onStream, on EITHER branch above -- the seekdata branch never itself
    # reads the marker, so a same-uri marker set via noteSeekIntent stayed
    # armed for up to its TTL otherwise. This must run AFTER requestTrack:
    # requestTrack deliberately keeps a marker matching the requested uri
    # alive across its own state update ("kept seek intent"), so onStream
    # is the last consumer in the chain, not a competing one.
    $ctl->consumeSeekIntent($url);
    return 'ok';
}

# Phase 82 Plan 44 (D-11, Runde 44): the four non-ready states
# DaemonManager::backendPrereqState can report for this backend -- each
# maps to a concrete, user-facing reason. Unknown states fall back to the
# generic text. Moved from ProtocolHandler.pm with Case 3 (84-08).
my %PREREQ_FAILURE_MESSAGES = (
    soloist_unsupported_os => 'Soloist is not supported on this platform (Windows/macOS)',
    soloist_missing_binary => 'Soloist binary not installed',
    soloist_missing_key    => 'Soloist not authorized (missing key)',
    soloist_build_expired  => 'Soloist build has expired - please update the plugin',
);

sub _prereqFailureMessage {
    my ($state) = @_;
    return $PREREQ_FAILURE_MESSAGES{$state // ''} // 'Soloist daemon not ready';
}

# prereqState() -- class method (84-12, SEAM-6.2): this backend's own
# prerequisites, moved from DaemonManager::_backendPrereqState, which keeps
# the platform check (platformSupportsSoloist, the ONE platform site) and
# the expiry-cache wrapper and asks the role for the rest.
# Returns 'soloist_ready' | 'soloist_missing_binary' | 'soloist_missing_key'.
# get() is one of the two legitimate ACTIVATION sites (Soloist.pm:get).
sub prereqState {
    require Plugins::SpotOn::Soloist;

    return 'soloist_missing_binary' unless Plugins::SpotOn::Soloist->get();
    return 'soloist_missing_key'    unless Plugins::SpotOn::Soloist->hasKey();

    # D-08 (user decision, resolves RESEARCH Open Question 3): Protocol::
    # WebSocket 0.26 is vendored in the plugin zip -- Soloist Connect runs
    # on LMS 8.0+, no version gate. ensureWsLib() prefers an LMS-bundled
    # copy (9.1+; the Debian split-layout Pitfall 8 is a bundle concern
    # only) and falls back to Plugins/SpotOn/Vendor/. On a correctly
    # installed plugin zip this require cannot fail; eval-guard anyway so a
    # mutilated install degrades to a single warning rather than a die, and
    # SoloistDaemon::start's own require-guard (via SoloistWS) keeps the
    # daemon from spawning a WS client it can't use. No new prereq state --
    # a broken install without the vendor tree is not a state a user can
    # act on beyond reinstalling the plugin.
    unless (eval { Plugins::SpotOn::Soloist::ensureWsLib() }) {
        $log->warn('Soloist: Protocol::WebSocket unavailable (neither LMS-bundled nor vendored copy loaded) - Connect events will not be received');
    }

    return 'soloist_ready';
}

# ---------------------------------------------------------------------------
# 84-12 (SEAM-6.2): DaemonManager lifecycle hooks. DaemonManager reaches
# these only through the role (backendClass() or, for a dying helper, the
# helper's OWN role via Backend::classFor($helper->backendName)); it names
# no Soloist package. Every hook exists on Backend::Librespot as well.
# ---------------------------------------------------------------------------

sub _cache {
    require Slim::Utils::Cache;
    require Plugins::SpotOn::Plugin;
    return Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
}

# _exitCode($helper) -- best-effort accessor for a dead daemon's process exit
# code (73-02, Pitfall 7 escalation; moved from DaemonManager::_soloistExitCode
# in 84-12). Phase 83.3 plan 15 (G-83.3-3 root cause): LMS runs libev's
# default event loop (Slim::Networking::IO::Select uses EV::loop), and
# libev's own childcb reaps every child via waitpid(-1) as soon as it exits
# (EV.pm POD). A raw Proc::Background->wait() read on an already-reaped
# process then hits ECHILD and fabricates "(1, 0) -- already reaped, exit
# status unknown" (Proc::Background::Unix.pm:185-187). SoloistDaemon arms an
# EV::child watcher at spawn time (_watchExit) that captures the real status
# before libev's reaping can lose it; exitCode() reads that recorded status
# first, falling back to Proc::Background's own wait() only when the watcher
# never fired. Returns undef on any failure -- callers must not treat undef
# as "not expired", only as "unknown", and fall through to the generic
# backoff path.
sub _exitCode {
    my ($helper) = @_;
    return undef unless $helper && $helper->can('exitCode');
    return $helper->exitCode;
}

# onDaemonExit($helper, $exitCode) -> 'restart' | 'park' | 'renew'
# The action word DaemonManager's ONE generic dispatcher (_applyExitAction)
# applies to a dead daemon:
#   restart -- today's counted GH #147 crash backoff (the generic path)
#   park    -- stop for good, no restart
#   renew   -- this role has made its one renewal attempt; stop for good,
#              no restart (the renewal's promotion restarts the daemon)
# $exitCode undef = read it from the helper (_exitCode). Exit code 10 is an
# expired build (renew); every other or unknown code is 'restart'.
#
# Pitfall 7 (RESEARCH): soloist builds expire 90 days after creation and
# subsequently exit with code 10 on every launch -- this is permanent, not
# transient, so feeding it to the generic CRASH_BACKOFF path would restart
# it forever (5s, 10s, 20s ... 300s, indefinitely) for a binary that can
# never succeed again. Escalates a 'never'-TTL cache flag (mirrors
# DaemonManager::_handleCredentialCrash's stay-down discipline) -- cleared
# only when Soloist::_versionCheck next activates a binary DIFFERING
# (version or mtime) from the one recorded (83.3 plan 08, gap 2/WR-01: no
# longer cleared by a read-only re-probe of the same expired file).
# DaemonManager::backendPrereqState reports the synthetic
# 'soloist_build_expired' state while the flag is set, so startHelper and the
# 60s watchdog cannot resurrect the daemon. The renewal trigger routes
# through checkRenewalDue(); 83.3 plan 11 (D-03, WR-01, gap-closure round
# 2): the exit-10 that SETS the flag (the park-flag TRANSITION) bypasses
# checkRenewalDue's daily RENEWAL_RETRY_S floor exactly once, so "renew
# immediately" holds even right after a D-01 daily same_version attempt; a
# repeat exit-10 while the flag is already set obeys the floor same as the
# watchdog tick.
#
# 84-12: moved from DaemonManager::_handleSoloistBuildExpiry. The one
# ordering difference: the daemon is now stopped by the dispatcher AFTER this
# returns (it used to be stopped between the flag write and
# noteActiveBinaryExpired); every step here is synchronous and touches only
# the cache, the placed/renewal state and the (asynchronous) download, none
# of which reads the helper registry.
sub onDaemonExit {
    my ($class, $helper, $exitCode) = @_;

    $exitCode = _exitCode($helper) unless defined $exitCode;
    return 'restart' unless defined $exitCode && $exitCode == 10;

    require Plugins::SpotOn::Soloist;
    my $cache = _cache();
    my $mac   = $helper->mac // '?';

    # 83.3 D-03: the pin is now a lower bound, not an exact version -- the
    # RUNNING build's own reported version is the honest thing to name in
    # the message, not the pin. 83.3 plan 08 (gap 2, WR-01): read via the
    # side-effect-free activeVersion() -- an informational read, not an
    # activation site.
    my $runningVersion = Plugins::SpotOn::Soloist::activeVersion();
    my $version = $runningVersion // 'unknown';

    # 83.3 plan 11 (D-03, WR-01): read the park flag ONCE into a lexical,
    # before the $cache->set() below establishes the transition -- both the
    # warn-line gate and the bypass decision must observe the SAME pre-set
    # value. $firstExit10 is true only for the exit-10 that SETS the flag
    # (absent -> set); a repeat exit-10 while it is already set is false.
    my $wasParked   = $cache->get('spoton_soloist_expired') ? 1 : 0;
    my $firstExit10 = $wasParked ? 0 : 1;

    unless ($wasParked) {
        $log->warn(
            "SpotOn Soloist daemon for $mac exited with code 10 -- "
            . "this build (version $version) has expired (90-day lifetime). "
            . "Attempting CDN renewal now (83.3 D-03); the daemon restarts "
            . "automatically once a fresh build passes the smoke test, otherwise "
            . "it stays down and Settings shows the reason."
        );
    }

    # 83.3 plan 08 (gap 2, WR-01): record the installed binary's mtime
    # alongside the version -- Soloist::_versionCheck's conditional flag
    # clear needs it to tell "the same expired file re-probed" apart from
    # "a replaced copy of the same version". An absent installed path yields
    # mtime undef rather than passing undef straight into stat().
    # 83.3-REVIEW round 2 (WR-01): store the REAL $runningVersion (undef
    # stays undef), never the 'unknown' placeholder of the warn line above.
    my $installedPath  = Plugins::SpotOn::Soloist::installedBinaryPath();
    my $installedMtime = $installedPath ? (stat($installedPath))[9] : undef;
    $cache->set('spoton_soloist_expired',
        { version => $runningVersion, mtime => $installedMtime, at => time() }, 'never');

    # Phase 83.3 plan 05 (D-10): an exit-10 placed binary must stop blocking
    # renewal in THIS same handling pass -- called before checkRenewalDue so
    # the D-09 guard never sees a now-stale 'active' placed state for the
    # build that just expired. 83.3-REVIEW round 2 (WR-03): its OWN eval,
    # separate from checkRenewalDue below -- the park-flag TRANSITION is
    # already committed, so a die here must not cost $firstExit10's one-shot
    # bypass.
    eval { Plugins::SpotOn::Soloist::noteActiveBinaryExpired(); 1 }
        or $log->warn("Soloist: noteActiveBinaryExpired failed: " . ($@ || 'unknown error'));

    # 83.3 plan 11 (D-03, WR-01, gap-closure round 2): the exit-10 that SETS
    # the flag bypasses checkRenewalDue's daily floor via
    # bypass_retry_floor => $firstExit10; a repeat exit-10 while the flag is
    # already set passes 0 and obeys the floor same as the watchdog tick --
    # this cannot become plan 08's un-throttled loop because the flag is
    # cleared only by _versionCheck activating a binary that DIFFERS
    # (version or mtime) from the one recorded.
    my $r = eval { Plugins::SpotOn::Soloist::checkRenewalDue(bypass_retry_floor => $firstExit10) };
    if (defined $r) {
        main::INFOLOG && $log->is_info && $log->info("Soloist: exit-10 renewal check: $r (bypass=$firstExit10)");
    }
    else {
        $log->warn("Soloist: exit-10 renewal trigger failed: " . ($@ || 'unknown error'));
    }

    return 'renew';
}

# onInitHelpers() -- class method: the Soloist part of DaemonManager's 60s
# watchdog tick, moved from DaemonManager::initHelpers in 84-12.
# Phase 83.3 plan 03 (D-01): the renewal trigger -- <=14 days remaining or a
# standing exit-10 escalation flag starts a renewal (daily retry floor lives
# inside checkRenewalDue itself), so a long-running LMS process eventually
# renews Soloist without any user action.
# Phase 83.3 plan 05 (D-09): the placed-binary check runs BEFORE the renewal
# check on the SAME tick -- a valid placed binary must block a renewal
# decision made in this same pass, not the next one.
# Each check is eval-guarded on its own: a failure must never abort the rest
# of initHelpers' per-player daemon bookkeeping.
sub onInitHelpers {
    eval {
        require Plugins::SpotOn::Soloist;
        my $p = Plugins::SpotOn::Soloist::checkPlacedBinary();
        main::DEBUGLOG && $log->is_debug && $log->debug("Soloist placed-binary check: $p");
        1;
    } or $log->warn("Soloist placed-binary check failed: " . ($@ || 'unknown error'));

    eval {
        require Plugins::SpotOn::Soloist;
        my $r = Plugins::SpotOn::Soloist::checkRenewalDue();
        main::DEBUGLOG && $log->is_debug && $log->debug("Soloist renewal check: $r");
        1;
    } or $log->warn("Soloist renewal check failed: " . ($@ || 'unknown error'));

    return 'ok';
}

# rollbackBinary(reason => $why) -> ($ok, $detail) -- class method: swap the
# kept previous binary generation back in (Soloist::rollbackToPrevious).
# DaemonManager::_rollbackAfterSwitch decides WHEN (D-07) and fans the
# restart out; the binary and its renewal-state notice are this side's.
# 83.3-REVIEW round 2 (WR-02, moved from _rollbackAfterSwitch in 84-12): the
# two TERMINAL failures (no_previous, previous_expired) get the SAME D-07
# notice ("only the notice remains") -- rollbackToPrevious already stamps it
# for previous_expired, but no_previous returns from its early-return guards
# without touching renewalState() at all, so the settings page kept showing
# whatever phase preceded the crash. Idempotent for previous_expired.
# rollback_move_failed (transient) is deliberately excluded.
sub rollbackBinary {
    my ($class, %args) = @_;
    require Plugins::SpotOn::Soloist;
    my ($ok, $detail) = Plugins::SpotOn::Soloist::rollbackToPrevious(reason => $args{reason});

    if (!$ok && defined $detail && ($detail eq 'no_previous' || $detail eq 'previous_expired')) {
        Plugins::SpotOn::Soloist::_setRenewalState(
            phase  => 'rollback_impossible',
            detail => $detail,
        );
    }
    return ($ok, $detail);
}

# pairedForMac($mac) -> 1 | 0 -- class method: has this player's daemon ever
# been paired in the Spotify app (settings/Users in its data dir)? Read-only,
# never vivifies state. The librespot role answers undef (no pairing
# concept).
sub pairedForMac {
    my ($class, $mac) = @_;
    require Plugins::SpotOn::Soloist;
    return Plugins::SpotOn::Soloist::isPairedForClient($mac) ? 1 : 0;
}

# deferTrackRequestForClient($class, $clientId, $uri, $posMs, $opts)
# Phase 82 Plan 44 (D-09/D-10/D-12, Runde 44): Case 2's entry -- registers
# a requestTrack that arrived before ANY daemon object existed for
# $clientId (Zustaende a/b from F1/F5), to be replayed once startHelper's
# construction site hands it to the daemon's own instance-level mechanism.
# Moved from DaemonManager in 84-08 with its DeferBudget require; the
# outer store itself (shutdown guard, Fall-5 supersession, the per-client
# timer and the startHelper/stopHelper/shutdown hand-off and releases)
# stays in DaemonManager, which owns the daemon lifecycle
# (queuePendingTrackRequest). The deadline is computed at the same point
# as before -- after the shutdown guard and the supersession -- through
# the code ref handed over here.
sub deferTrackRequestForClient {
    my ($class, $clientId, $uri, $posMs, $opts) = @_;
    require Plugins::SpotOn::Unified::DaemonManager;
    require Plugins::SpotOn::Unified::DeferBudget;
    Plugins::SpotOn::Unified::DaemonManager->queuePendingTrackRequest(
        $clientId, $uri, $posMs, $opts, \&Plugins::SpotOn::Unified::DeferBudget::deadlineFor
    );
    return;
}

# notify($event, %args) -> ok | unsupported | down
# 84-07 Task 2: endForeignLeave (Connect.pm _onLmsStop). 84-08 Task 2: the
# ProtocolHandler sites noteDuration (_applyRuntimeMetadata),
# noteSeekIntent (getSeekData / canDoAction('rew')) and
# noteMetadataMissing (_asyncRefetch). 84-08 Task 3: leaveBrowse /
# leaveConnect (_onNewSong), clearHold (_holdClose), recordErrorOnce +
# claimLost (bindConnectClaim, on the OLD player's role), watchdogRing
# (Plugin.pm _prefetchHangCheck), notePlaylistChanged
# (_onLmsPlaylistChanged). No Control instance -> 'down', nothing else.
my %NOTIFY = (
    endForeignLeave     => sub { my ($ctl, %a) = @_; $ctl->endForeignLeave($a{reason}); },
    noteDuration        => sub { my ($ctl, %a) = @_; $ctl->noteDuration($a{url}, $a{secs}); },
    noteSeekIntent      => sub { my ($ctl, %a) = @_; $ctl->noteSeekIntent($a{url}, $a{target_ms}); },
    noteMetadataMissing => sub { my ($ctl, %a) = @_; $ctl->noteMetadataMissing($a{url}); },
    # 84-08 Task 3: the Connect.pm / Plugin.pm sites (84-07 mapping table).
    leaveBrowse         => sub { my ($ctl, %a) = @_; $ctl->leaveBrowse; },
    leaveConnect        => sub { my ($ctl, %a) = @_; $ctl->leaveConnect($a{reason}); },
    clearHold           => sub { my ($ctl, %a) = @_; $ctl->clearHold($a{trackId}); },
    recordErrorOnce     => sub { my ($ctl, %a) = @_; $ctl->_recordErrorOnce($a{key}, $a{level}, $a{message}); },
    # D-D2: the loser of a last-message-wins claim merely lost the claim --
    # its OWN daemon reports is_active:false itself; no stop is emitted.
    claimLost           => sub { my ($ctl, %a) = @_; $ctl->observed->{is_active} = 0; },
    watchdogRing        => sub { my ($ctl, %a) = @_; $ctl->watchdogRing($a{url}); },
    notePlaylistChanged => sub { my ($ctl, %a) = @_; $ctl->notePlaylistChanged; },
);

sub notify {
    my ($self, $event, %args) = @_;
    my $handler = defined $event ? $NOTIFY{$event} : undef;
    return 'unsupported' unless $handler;

    my $ctl = $self->_ctl or return 'down';
    $handler->($ctl, %args);
    return 'ok';
}

# query($what, %args) -> scalar | undef
# 84-07 Task 2: wantedPositionMs (Connect.pm _onSeek's browse observer
# line). 84-08 Task 2: seekable (getSeekData / canDoAction('rew'), 1|0)
# and consumeRestartAllowance (canDoAction('rew') in connect, read-and-
# clear, 1|0). No Control instance -> undef ("no opinion").
# 85-07 D-09: 'queue' -> { current => entry|undef, upcoming => [entry...] },
# the Up Next menu's source (a copy). It asks the helper for a fresh queue
# (rate limited inside Control) and answers from what it has cached; without
# a Control instance the answer is the EMPTY queue, not undef -- undef would
# mean "this backend has no queue source" and hide the menu item.
sub query {
    my ($self, $what, %args) = @_;
    $what //= '';
    if ($what eq 'queue') {
        my $ctl = $self->_ctl or return { current => undef, upcoming => [] };
        $ctl->requestQueue;
        my $snap = $ctl->queueSnapshot;
        return {
            current  => (ref($snap) eq 'HASH' && ref($snap->{current}) eq 'HASH' ? { %{ $snap->{current} } } : undef),
            upcoming => (ref($snap) eq 'HASH' && ref($snap->{upcoming}) eq 'ARRAY' ? [ map { ref($_) eq 'HASH' ? { %$_ } : $_ } @{ $snap->{upcoming} } ] : []),
        };
    }
    if ($what eq 'wantedPositionMs') {
        my $ctl = $self->_ctl or return undef;
        my $wanted = $ctl->wanted || {};
        return $wanted->{position_ms};
    }
    if ($what eq 'seekable') {
        my $ctl = $self->_ctl or return undef;
        return $ctl->seekable($args{url}) ? 1 : 0;
    }
    if ($what eq 'consumeRestartAllowance') {
        my $ctl = $self->_ctl or return undef;
        return $ctl->consumeRestartAllowance($args{url}) ? 1 : 0;
    }
    return undef;
}

# streamUrl($client, $songOrUrl, $kind, %opts) -> url | undef
# The Soloist halves of ProtocolHandler's URL choices (84-08). The URL is
# $opts{url} when the caller passes it (ProtocolHandler::new hands in the
# exact url LMS opened -- Song::open's `$redir || $track->url`), else the
# song's track url, else $songOrUrl itself.
#   browse_proxy  new()'s former (b3) block, moved verbatim (Phase 73 D-03,
#                 Modell B): new() runs only when canDirectStream answered
#                 0, so a spoton://track|episode URL always needs the
#                 daemon's /stream?uri=spotify:<type>:<id>&g=<gen> endpoint
#                 -- synced players, proxy mode and the transcode path
#                 (resolved format flac/mp3, 76-04). undef without an alive
#                 daemon + stream port (the caller logs it once).
#   browse_direct canDirectStream's former Soloist Browse branch (Phase 73
#                 D-03, Modell B): the same bounded /stream URL on the LMS
#                 server address, ONLY for a resolved 'pcm' format on an
#                 unsynced player with an alive daemon + port; undef
#                 otherwise (new() then substitutes). The streamingMode=
#                 proxy gate runs in the caller before this.
#   connect_direct canDirectStream's Connect branch, Soloist side: the
#                 resolved format gates direct-vs-transcode (only 'pcm'
#                 keeps the direct raw-S32 /stream URL), then the generic
#                 daemon/synced rules.
sub streamUrl {
    my ($self, $client, $song, $kind, %opts) = @_;
    return undef unless $client;
    $kind //= '';

    my $url = $opts{url};
    $url = ref $song ? (($song->can('track') && $song->track) ? $song->track->url : undef) : $song
        unless defined $url;
    $client = $client->master if $client->can('master') && $client->master;

    if ($kind eq 'browse_proxy') {
        return undef unless $url && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$};
        my ($type, $id) = ($1, $2);

        require Plugins::SpotOn::Unified::DaemonManager;
        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
        return undef unless $helper && $helper->alive && $helper->_streamPort;

        # CR-05 (82-25): hardcoded, not the auto-detected host IP -- LMS is
        # the HTTP client, the daemon always runs locally, and the address
        # cache never re-detects after a network change.
        my $host = '127.0.0.1';
        # Phase 82 (D-01 Folge D): the g=<gen> decoration, same counter as
        # the direct-stream URL (Kante 1: both count up, both harmless,
        # only uniqueness matters, [ASSUMED -- A1]).
        my $gen = do {
            require Plugins::SpotOn::Soloist::Control;
            my $c = Plugins::SpotOn::Soloist::Control->for_client($client);
            $c ? $c->nextStreamGeneration : 0;
        };
        my $httpUrl = "http://$host:" . $helper->_streamPort . "/stream?uri=spotify:$type:$id&g=$gen";
        $log->warn("[DIAG] browse_proxy: mac=" . $client->id . " http_url=$httpUrl") if $prefs->get('diagnosticMode');
        return $httpUrl;
    }

    if ($kind eq 'browse_direct') {
        return undef unless $url && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$};
        my ($type, $id) = ($1, $2);

        require Plugins::SpotOn::Unified::DaemonManager;

        # Phase 76 D-06: the resolved format gates direct-vs-transcode. Only
        # resolved 'pcm' keeps the direct raw-S32 /stream URL (strm
        # samplesize 32, 76-01); 'flac'/'mp3' answer undef so LMS opens the
        # stream itself, through the proxy, and runs the type
        # ProtocolHandler->contentTypeFor picked: sof for an explicit FLAC
        # (and for Auto after the AUTO_FLAC flip), the soc pcm passthrough
        # for Auto while AUTO_FLAC is 0 (that is today's path and delivery,
        # 74b D-22), the smp rule for 'mp3'.
        my $resolved = Plugins::SpotOn::Unified::DaemonManager->resolveSoloistFormat($client);
        if ($resolved ne 'pcm') {
            $log->warn("[DIAG] canDirectStream: soloist browse url=$url result=0 reason=resolved_format_$resolved") if $prefs->get('diagnosticMode');
            return undef;
        }

        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
        if ($helper && $helper->alive && $helper->_streamPort) {
            if ($client->isSynced()) {
                $log->warn("[DIAG] canDirectStream: soloist browse url=$url result=0 reason=synced") if $prefs->get('diagnosticMode');
                return undef;   # Synced: new() proxy handles
            }
            my $host = Slim::Utils::Network::serverAddr();
            # Phase 82 (D-01 Folge D): g=<gen> is a pure Perl decoration for
            # LMS URL-uniqueness per stream start ([ASSUMED -- A1]) -- the C
            # side answers any GET on the port regardless of path/query
            # (fake-libpulse.c:1033-1080). Seek offset no longer travels in
            # the URL (Befund 1) -- the daemon learns it via onStream's
            # marker consumption instead.
            my $gen = do {
                require Plugins::SpotOn::Soloist::Control;
                my $c = Plugins::SpotOn::Soloist::Control->for_client($client);
                $c ? $c->nextStreamGeneration : 0;
            };
            my $ds_url = "http://$host:" . $helper->_streamPort . "/stream?uri=spotify:$type:$id&g=$gen";
            $log->warn("[DIAG] canDirectStream: soloist browse url=$ds_url") if $prefs->get('diagnosticMode');
            return $ds_url;
        }
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: soloist browse - no alive daemon/stream port for " . $client->id
        );
        return undef;
    }

    if ($kind eq 'connect_direct') {
        require Plugins::SpotOn::Unified::DaemonManager;
        # Phase 76 D-06: the soloist resolver replaces librespot's raw pref
        # check (under soloist explicit pcm KEEPS the direct raw-S32
        # /stream path); 'flac'/'mp3' answer undef so LMS opens the stream
        # through the proxy and runs the type contentTypeFor picked (sof,
        # the soc pcm passthrough for Auto while AUTO_FLAC is 0, or smp;
        # 74b D-14, D-22).
        my $resolved = Plugins::SpotOn::Unified::DaemonManager->resolveSoloistFormat($client);
        if ($resolved ne 'pcm') {
            $log->warn("[DIAG] canDirectStream: unified connect result=0 reason=resolved_format_$resolved") if $prefs->get('diagnosticMode');
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (soloist resolved format=$resolved forces transcoding)"
            );
            return undef;
        }
        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
        return undef unless $helper && $helper->alive && $helper->_streamPort;
        if ($client->isSynced()) {
            $log->warn("[DIAG] canDirectStream: unified connect result=0 reason=synced") if $prefs->get('diagnosticMode');
            main::INFOLOG && $log->is_info && $log->info(
                "canDirectStream: 0 (player is synced)"
            );
            return undef;
        }
        my $host   = Slim::Utils::Network::serverAddr();
        my $ds_url = "http://$host:" . $helper->_streamPort . "/stream";
        $log->warn("[DIAG] canDirectStream: unified connect url=$ds_url") if $prefs->get('diagnosticMode');
        main::INFOLOG && $log->is_info && $log->info(
            "canDirectStream: $ds_url"
        );
        return $ds_url;
    }

    return undef;
}


# ---------------------------------------------------------------------------
# 84-08 Task 3: lifecycle and settings hooks (class methods).
# ---------------------------------------------------------------------------

# bootstrap() -- Plugin.pm initPlugin (the active backend) and Settings'
# backend save (the newly selected one). Soloist->init registers the
# `backend` watcher that drops the cached binary/version on a switch --
# once per LMS run; ensureBinary() (download/version check, self-guarding,
# WR-07 in-flight guard) runs on every call outside the scanner.
my $_initDone;
sub bootstrap {
    require Plugins::SpotOn::Soloist;
    Plugins::SpotOn::Soloist->init() unless $_initDone++;
    Plugins::SpotOn::Soloist::ensureBinary() if !main::SCANNER;
    return 'ok';
}

# quality(scope => 'global'|..., level => $n) -- D-17: the Spotify streaming
# quality write goes through the backend role, never a direct
# Soloist::Quality call from core.
# 84-13 (D-17 second half): scope => 'player' is Settings::Player's
# per-player save -- the client comes from the role instance
# (backendFor($client)) or $args{client}; the level written is the one the
# Quality module resolves for that player after the pref save (today's
# Player.pm call, moved: applyChange(scope => client, level =>
# effectiveLevelForClient)).
sub quality {
    my ($self, %args) = @_;
    require Plugins::SpotOn::Soloist::Quality;
    my $Q = 'Plugins::SpotOn::Soloist::Quality';
    if (($args{scope} // '') eq 'player') {
        my $client = $args{client} || (ref $self ? $self->client : undef);
        return 'unsupported' unless $client;
        $Q->applyChange(scope => 'client', client => $client, level => $Q->effectiveLevelForClient($client));
        return 'ok';
    }
    $Q->applyChange(%args);
    return 'ok';
}

# qualityInfo([$client]) -> { supported => 1, validLevels => [...] } -- what
# Settings' save path validates a posted level against (Quality::
# isValidLevel's set). 84-13: with a $client it also carries the per-player
# block of the player settings page, labels already rendered:
#   levels         [ { value, label } ]  the select's options
#   stored         the player's soloistQuality pref ('global' or a level)
#   storedLabel    label of a stored level the select never offers (1/6), else ''
#   effective      server-side level last read (cache) or undef
#   effectiveLabel its label or ''
#   differs        effective != the level SpotOn would write
#   wanted         the level SpotOn would write (Quality->effectiveLevelForClient:
#                  the per-player pref, else the global one). 74b-02 D-18: the
#                  player page's MP3 note needs the level the user explicitly
#                  chose, not the cached effective one; core modules read it
#                  here and never call Soloist::Quality themselves.
#   deviceKnown    the daemon wrote its device id (a write is possible)
#   noticeText     the formatted quality notice ('' when none)
sub qualityInfo {
    my ($class, $client) = @_;
    require Plugins::SpotOn::Soloist::Quality;
    my $Q = 'Plugins::SpotOn::Soloist::Quality';
    my $info = { supported => 1, validLevels => [ Plugins::SpotOn::Soloist::Quality::SUPPORTED_LEVELS() ] };
    return $info unless $client;

    require Slim::Utils::Strings;
    my $string = \&Slim::Utils::Strings::string;
    my $mac    = $client->id;
    my $stored = $prefs->client($client)->get('soloistQuality') || 'global';
    my $cached = $Q->effectiveCached($mac);
    my $effective = $cached ? $cached->{level} : undef;
    my $wanted    = $Q->effectiveLevelForClient($client);

    $info->{levels} = [ map { { value => $_->{value}, label => $string->($_->{string}) } } @{ $Q->levels() } ];
    $info->{stored} = $stored;
    $info->{storedLabel} = ($stored ne 'global' && $Q->isStorableLevel($stored) && !$Q->isValidLevel($stored))
        ? $string->($Q->labelFor($stored)) : '';
    $info->{deviceKnown}    = $Q->deviceIdForMac($mac) ? 1 : 0;
    $info->{effective}      = $effective;
    $info->{effectiveLabel} = defined $effective ? $string->($Q->labelFor($effective)) : '';
    $info->{differs}        = (defined $effective && $effective != $wanted) ? 1 : 0;
    $info->{wanted}         = $wanted;
    $info->{noticeText}     = _formatQualityNotice($Q->noticeFor($mac));
    return $info;
}

# _formatQualityNotice($notice) -- role-private (moved from Settings.pm in
# 84-13, W8): renders a Quality->noticeFor() hashref (83.3 D-14) into the
# pre-formatted text the settings rows show, or '' when there is no notice.
sub _formatQualityNotice {
    my ($notice) = @_;
    return '' unless $notice && $notice->{kind};

    require Slim::Utils::Strings;
    require Plugins::SpotOn::Soloist::Quality;
    my $string = \&Slim::Utils::Strings::string;
    my $Q      = 'Plugins::SpotOn::Soloist::Quality';

    if ($notice->{kind} eq 'rejected') {
        my $wantedLabel    = $string->($Q->labelFor($notice->{wanted}));
        my $effectiveLabel = defined $notice->{effective}
            ? $string->($Q->labelFor($notice->{effective}))
            : '?';
        return sprintf($string->('PLUGIN_SPOTON_SOLOIST_QUALITY_REJECTED'), $wantedLabel, $effectiveLabel);
    }
    if ($notice->{kind} eq 'no_token') {
        return $string->('PLUGIN_SPOTON_SOLOIST_QUALITY_NO_TOKEN');
    }
    return $string->('PLUGIN_SPOTON_SOLOIST_QUALITY_UNREACHABLE');
}

# 84-13 Task 2 (SEAM-6.2, B5/B6/W7): the renewal routes of the settings page.
# Settings registers every available backend's routes() through ONE generic
# wrapper per entry (_csrfCheck unless the method is 'GET', _jsonResponse
# around the answer) -- the role never sees the HTTP objects. Paths are the
# FULL LMS paths basic.html calls; the status route comes FIRST (83.3: a
# path that is a prefix of a registered one clobbers it, Tie::RegexpHash).
sub routes {
    my ($class) = @_;
    return [
        { path => 'plugins/SpotOn/settings/soloistRenewStatus', method => 'GET',  handler => sub { $class->renewStatus() } },
        { path => 'plugins/SpotOn/settings/soloistRenew',       method => 'POST', handler => sub { $class->renewNow(reason => 'manual') } },
    ];
}

# renewNow(reason => ...) -> { status => <renewBinary answer> } (83.3 D-04).
sub renewNow {
    my ($class, %args) = @_;
    require Plugins::SpotOn::Soloist;
    my $r = Plugins::SpotOn::Soloist::renewBinary(reason => $args{reason});
    return { status => $r };
}

# renewStatus() -> the 5 s status poll's plain hashref (83.3 D-04/D-07/
# D-08..D-10, 84.1-03): renewal, generation, active_version, expiry_days,
# pending_switches, players, placed, manual_dir. Informational read --
# activeVersion(), never the activating get() (WR-01).
sub renewStatus {
    my ($class) = @_;
    require Plugins::SpotOn::Soloist;
    require Plugins::SpotOn::Unified::DaemonManager;
    my $DM = 'Plugins::SpotOn::Unified::DaemonManager';

    my $generation = eval {
        require Slim::Utils::Cache;
        require Plugins::SpotOn::Plugin;
        Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION())
            ->get('spoton_soloist_generation');
    };

    my $activeVersion   = Plugins::SpotOn::Soloist::activeVersion();
    my $pendingSwitches = $DM->pendingBinarySwitches;

    my @players;
    for my $helper ($DM->helperInstances) {
        next unless $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon');
        my $mac    = $helper->mac;
        my $client = Slim::Player::Client::getClient($mac);
        push @players, {
            mac            => $mac,
            name           => $client ? $client->name : ($helper->name || ''),
            alive          => $helper->alive ? 1 : 0,
            pid            => $helper->pid,
            # Phase 83.3 plan 04 (D-02/D-07): plan 06's machine gate reads
            # switched_at to confirm a live switch actually happened.
            switched_at    => $DM->switchedAtFor($mac),
            switch_pending => (exists $pendingSwitches->{$mac}) ? 1 : 0,
            # 84.1 plan 03 (D-04/D-05/D-06): the plan-04 live gate's own
            # instrument -- health/crash are undef -> JSON null for a MAC
            # the tick/backoff has never touched (never vivified).
            control_mode   => eval { $class->new($mac)->state->{mode} },
            health         => $DM->soloistHealthFor($mac),
            crash          => $DM->crashStateSnapshot($mac),
        };
    }

    return {
        renewal          => Plugins::SpotOn::Soloist::renewalState(),
        generation       => $generation,
        active_version   => $activeVersion,
        expiry_days      => Plugins::SpotOn::Soloist::expiryDaysRemaining(),
        pending_switches => $DM->pendingBinarySwitches,
        players          => \@players,
        placed           => Plugins::SpotOn::Soloist::placedState(),
        manual_dir       => Plugins::SpotOn::Soloist::manualDir(),
    };
}

# binaryPath() -- class method, kept ONLY for Plugin.pm's hourly orphan
# sweep (its sole core consumer after 84-13). Read-only (WR-01):
# installedBinaryPath(), never the activating get() / version check.
sub binaryPath {
    require Plugins::SpotOn::Soloist;
    return Plugins::SpotOn::Soloist::installedBinaryPath();
}

# 84-13 Task 1 (SEAM-6.2, T-71-02/T-84-45): the spak-key store as a role
# capability. Settings' key block reaches it only through backendClass().
# The raw key passes through unchanged and is NEVER logged -- only the
# outcome (ok / reason) is.
#   keyState()      -> { supported => 1, present => 0|1 }
#   storeKey($raw)  -> (1) | (0, $reason)    ($reason e.g. write_failed)
#   clearKey()      -> 1
sub keyState {
    require Plugins::SpotOn::Soloist;
    return { supported => 1, present => (Plugins::SpotOn::Soloist::hasKey() ? 1 : 0) };
}

sub storeKey {
    my ($class, $raw) = @_;
    require Plugins::SpotOn::Soloist;
    my ($ok, $reason) = Plugins::SpotOn::Soloist->storeKey($raw);
    main::INFOLOG && $log->is_info && $log->info('Backend::Soloist: storeKey -> ' . ($ok ? 'ok' : ($reason // 'failed')));
    return $ok ? (1) : (0, $reason);
}

sub clearKey {
    require Plugins::SpotOn::Soloist;
    Plugins::SpotOn::Soloist::clearKey();
    return 1;
}

# platformFit() -- 79-05 (D-12): true when Soloist CAN run on this system:
# a Soloist platform (the one site, DaemonManager->platformSupportsSoloist),
# an architecture SpotOn ships a build for (expectedVersion is defined) and a
# detected glibc at or above the floor (DaemonManager->soloistGlibcOk). A glibc
# that cannot be detected (musl, probe missing) counts as unfit: the hint must
# never point to a backend that cannot start. No platform check of its own.
sub platformFit {
    require Plugins::SpotOn::Soloist;
    require Plugins::SpotOn::Unified::DaemonManager;
    return 0 unless Plugins::SpotOn::Unified::DaemonManager->platformSupportsSoloist;
    return 0 unless defined Plugins::SpotOn::Soloist::expectedVersion();
    return Plugins::SpotOn::Unified::DaemonManager->soloistGlibcOk ? 1 : 0;
}

# settingsInfo($paramRef, %fmt) -- fills the Soloist template keys of the
# Settings page (moved from Settings.pm::handler in 84-08; the values and
# their conditions are unchanged). Settings calls every registered
# backend's settingsInfo -- the soloist-fields div is rendered hidden under
# librespot and shown by the backend select's listener, so its status
# lines need these keys whatever backend is saved. %fmt carries Settings'
# own formatters/constants: formatHealthNotice, keyMaskedPreview (84-13:
# the quality notice is formatted by the role-private _formatQualityNotice).
sub settingsInfo {
    my ($class, $paramRef, %fmt) = @_;

    require Slim::Utils::Strings;
    my $string = \&Slim::Utils::Strings::string;

    # D-08/D-09 (Phase 71): the four soloist* flags drive the conditional
    # status lines inside div#soloist-fields (unsupported OS / binary
    # missing / key missing / version-ready), covering all D-09 degraded
    # states while activation itself always stays possible.
    require Plugins::SpotOn::Soloist;
    # 84-07 (D-14, SEAM-6.3.5): the platform decision lives in ONE place,
    # DaemonManager::platformSupportsSoloist -- no local platform check here.
    require Plugins::SpotOn::Unified::DaemonManager;
    $paramRef->{soloistUnsupportedOS} = Plugins::SpotOn::Unified::DaemonManager->platformSupportsSoloist ? 0 : 1;
    # 83.3 plan 08 (gap 2, WR-01): the settings render is an informational
    # read site -- activeVersion(), never the activating get(). Same
    # "activatable" semantics: undef for below-pin/absent, exactly as before.
    my $soloistVersion                = Plugins::SpotOn::Soloist::activeVersion();
    $paramRef->{soloistVersion}       = $soloistVersion || '';
    $paramRef->{soloistMissing}       = defined $soloistVersion ? 0 : 1;
    my $soloistHasKey                 = $class->keyState->{present} ? 1 : 0;
    $paramRef->{soloistKeyMissing}    = $soloistHasKey ? 0 : 1;
    # T-71-02: fixed placeholder only when a key is stored -- the raw key is
    # never read back (Soloist.pm exposes no accessor for it).
    $paramRef->{soloistKeyMasked}     = $soloistHasKey ? ($fmt{keyMaskedPreview} // '') : '';

    # 79-05 (D-12): the default backend stays librespot; on a fit platform with
    # librespot saved and no key stored the page hints that Soloist exists. The
    # flags are computed here, BEFORE the early return below, because that
    # return is for the saved backend soloist -- the hint is for librespot.
    my $savedBackend = $prefs->get('backend') || 'librespot';
    $paramRef->{soloistHint} = ($savedBackend eq 'librespot' && !$soloistHasKey && $class->platformFit) ? 1 : 0;
    $paramRef->{soloistSwitchOffer} = ($savedBackend eq 'librespot' && $soloistHasKey && $class->platformFit) ? 1 : 0;

    # D-01/D-02 (Phase 73 Task 3): per-player daemon/pairing status for the
    # Settings status table -- one row per connected player. Only computed
    # when backend=soloist (avoids iterating every connected client + a
    # cache lookup per player on a pure-librespot install).
    $paramRef->{soloistPlayers} = [];
    return 'ok' unless (($prefs->get('backend') || 'librespot') eq 'soloist');

    require Slim::Utils::Cache;
    require Plugins::SpotOn::Plugin;
    require Plugins::SpotOn::Soloist::Quality;
    my $Q = 'Plugins::SpotOn::Soloist::Quality';
    my $wsCache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
    # Phase 83.3 plan 04 (D-02/D-07): pending-switch map, read once per
    # request (host-wide keyed by mac).
    my $pendingSwitches = Plugins::SpotOn::Unified::DaemonManager->pendingBinarySwitches;

    # 83.3 D-12/D-13/D-15: global streaming-quality select + hint.
    my $storedGlobalQuality = $prefs->get('soloistQuality') // 0;
    $paramRef->{soloistQuality} = $storedGlobalQuality;
    $paramRef->{soloistQualityLevels} = [
        map { { value => $_->{value}, label => $string->($_->{string}) } }
        @{ $Q->levels() }
    ];
    # A stored 1 (Low) or 6 (Lossless 24-bit) is never offered by the
    # select -- it can only get there via a D-14 reset or an app-side
    # choice observed on read-back; show it as a disabled, pre-selected
    # extra option instead of silently defaulting the select away from it.
    # Bare label only -- the template applies
    # PLUGIN_SPOTON_SOLOIST_QUALITY_SET_IN_APP via the `string` filter.
    $paramRef->{soloistQualityStoredLabel} =
        ($Q->isStorableLevel($storedGlobalQuality) && !$Q->isValidLevel($storedGlobalQuality))
        ? $string->($Q->labelFor($storedGlobalQuality))
        : '';

    for my $c (Slim::Player::Client::clients()) {
        my $mac = $c->id;
        (my $macClean = $mac || '') =~ s/://g;

        my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($c);
        my $daemonAlive = ($helper && $helper->alive && $helper->backendName eq 'soloist') ? 1 : 0;

        # T-73-13: only booleans/names cross into the template -- no
        # spak-key, no data-dir paths (those stay host-local).
        my $wsState = $wsCache->get("spoton_soloist_ws_$macClean");

        # 83.3 D-12: the effective server-side quality (may differ from what
        # SpotOn last wrote, if changed via the app). Shows the cached value
        # now and refreshes async when missing/stale.
        my $qCached = $Q->effectiveCached($mac);
        if (!$qCached || !defined $qCached->{checked_at}
                || (time() - $qCached->{checked_at}) >= Plugins::SpotOn::Soloist::Quality::EFFECTIVE_TTL()) {
            $Q->refreshEffective($mac);
        }
        my $qEffective = $qCached ? $qCached->{level} : undef;
        my $qWanted    = $Q->effectiveLevelForClient($c);

        push @{ $paramRef->{soloistPlayers} }, {
            name        => $c->name,
            mac         => $mac,
            paired      => Plugins::SpotOn::Soloist::isPairedForClient($mac) ? 1 : 0,
            daemonAlive => $daemonAlive,
            loggedIn    => ($wsState && $wsState->{logged_in}) ? 1 : 0,
            isActive    => ($wsState && $wsState->{is_active}) ? 1 : 0,
            qualityEffective      => $qEffective,
            qualityEffectiveLabel => defined $qEffective
                ? $string->($Q->labelFor($qEffective)) : '',
            qualityDiffers        => (defined $qEffective && $qEffective != $qWanted) ? 1 : 0,
            qualityNotice         => _formatQualityNotice($Q->noticeFor($mac)),
            # Phase 83.3 plan 04 (D-02/D-07): switch-pending indicator +
            # last-switch timestamp for this player.
            switchPending         => (exists $pendingSwitches->{$mac}) ? 1 : 0,
            switchedAt            => Plugins::SpotOn::Unified::DaemonManager->switchedAtFor($mac),
            # 84.1 plan 03 (D-04/D-05/D-06): the health-tick's own notice +
            # the Control mode instrument the live plans poll.
            healthNotice          => $fmt{formatHealthNotice} ? $fmt{formatHealthNotice}->($mac) : '',
            controlMode           => do { my $ctl = eval { $class->new($mac)->_ctl }; $ctl ? $ctl->mode : ''; },
        };
    }

    # D-09/Pitfall 7: build-expiry warning -- read once here, not per-player
    # (the pinned soloist binary is shared host-wide). 83.3 plan 03: the
    # WR-10 wallclock arithmetic lives in Soloist::expiryDaysRemaining().
    $paramRef->{soloistExpiryDays} = Plugins::SpotOn::Soloist::expiryDaysRemaining();
    $paramRef->{soloistExpiryWarn} = (defined $paramRef->{soloistExpiryDays} && $paramRef->{soloistExpiryDays} <= 14) ? 1 : 0;
    $paramRef->{soloistExpired}    = $wsCache->get('spoton_soloist_expired') ? 1 : 0;
    # Pre-formatted display text (string() -- no $client here).
    $paramRef->{soloistExpiryText} = defined $paramRef->{soloistExpiryDays}
        ? sprintf($string->('PLUGIN_SPOTON_SOLOIST_EXPIRY_DAYS'), $paramRef->{soloistExpiryDays})
        : '';

    # 83.3 D-05: neutral "Soloist <version>, expires in N days" info line --
    # a version newer than the pin is logged only (versionAheadOfPin).
    $paramRef->{soloistVersionAheadOfPin} = Plugins::SpotOn::Soloist::versionAheadOfPin();
    $paramRef->{soloistInfoLine} = (defined $paramRef->{soloistExpiryDays} && $soloistVersion)
        ? sprintf($string->('PLUGIN_SPOTON_SOLOIST_INFO_LINE'), $soloistVersion, $paramRef->{soloistExpiryDays})
        : '';

    # 83.3 D-04/D-16: renewal state + the pre-formatted status text the
    # template shows next to the "Renew Soloist now" button, and the
    # download page link + terms sentence.
    my $renewal = Plugins::SpotOn::Soloist::renewalState();
    my $phase   = $renewal->{phase} || 'idle';
    my $renewalText = '';
    if ($phase =~ /^(?:downloading|extracting|smoke|promoting)$/) {
        $renewalText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_RENEWAL_RUNNING'), $phase);
    }
    elsif ($phase eq 'done') {
        $renewalText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_RENEWAL_DONE'), $soloistVersion || '?');
    }
    elsif ($phase eq 'same_version') {
        $renewalText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_RENEWAL_SAME_VERSION'), $soloistVersion || '?');
    }
    elsif ($phase eq 'failed') {
        $renewalText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_RENEWAL_FAILED'), $renewal->{detail} || 'unknown');
    }
    elsif ($phase eq 'rolled_back') {
        # Phase 83.3 plan 04 (D-07): $renewal->{detail} carries the
        # human-readable "why" _rollbackAfterSwitch passed as `reason`.
        $renewalText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_ROLLED_BACK'),
            $renewal->{from_version} || '?', $renewal->{to_version} || '?', $renewal->{detail} || '?');
    }
    elsif ($phase eq 'rollback_impossible') {
        $renewalText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_ROLLBACK_IMPOSSIBLE'), $renewal->{detail} || 'unknown');
    }
    elsif ($phase eq 'blocked') {
        # Phase 83.3 plan 05 (D-09): renewBinary() short-circuits while a
        # valid placed binary is active.
        $renewalText = $string->('PLUGIN_SPOTON_SOLOIST_RENEWAL_BLOCKED_PLACED');
    }
    $paramRef->{soloistRenewal} = { %$renewal, text => $renewalText };
    $paramRef->{soloistDownloadUrl} = Plugins::SpotOn::Soloist::SOLOIST_DOWNLOAD_PAGE();

    # 83.3 D-08/D-09/D-10/D-11 (plan 05): the placed-binary fallback folder
    # (host-wide, the exact instruction the user needs -- D-08, not a leak)
    # and its current evaluation state.
    $paramRef->{soloistManualDir} = Plugins::SpotOn::Soloist::manualDir();

    my $placed = Plugins::SpotOn::Soloist::placedState();
    my $placedText = '';
    my $placedStatus = $placed->{status} || 'absent';
    if ($placedStatus eq 'active') {
        $placedText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_MANUAL_ACTIVE'), $placed->{version} || '?');
    }
    elsif ($placedStatus eq 'rejected') {
        $placedText = sprintf($string->('PLUGIN_SPOTON_SOLOIST_MANUAL_REJECTED'), $placed->{reason} || 'unknown');
    }
    elsif ($placedStatus eq 'expired') {
        $placedText = $string->('PLUGIN_SPOTON_SOLOIST_MANUAL_EXPIRED');
    }
    elsif ($placedStatus eq 'checking') {
        $placedText = $string->('PLUGIN_SPOTON_SOLOIST_MANUAL_CHECKING');
    }
    $paramRef->{soloistPlaced} = { %$placed, text => $placedText };

    # D-10: the 14-day placed-build expiry hint takes over the SAME
    # soloistExpiryWarn flag/threshold as the CDN build's own warning.
    $paramRef->{soloistExpiryHint} = ($paramRef->{soloistExpiryWarn} && $placedStatus eq 'active') ? 1 : 0;

    return 'ok';
}

1;
