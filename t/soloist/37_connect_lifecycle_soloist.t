#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# ============================================================
# Phase 76-05: Connect lifecycle source assertions (grep gates).
#
# Connect.pm has no isolated unit harness (Phase 73-03 D4), so these
# regression nets pin the three 76-05 fixes at the source level, following
# the established grep-gate idiom from t/10_stream_metadata.t:
#
#   1. Restart-autoplay provenance gate (ROADMAP: no self-starting audio
#      after an LMS restart re-announces a dormant Connect session)
#   2. GH #151 power-state save/restore across the Connect session
#   3. GH #158 pause-skip-play loop: change handler must not force-unpause
#      while the Spotify session itself is paused
# ============================================================

# 84-09: soloist half of t/37_connect_lifecycle.t -- the source nets over
# Soloist/Control.pm and Unified/SoloistWS.pm (the rest: t/core/ and
# t/librespot/37_connect_lifecycle_*.t).
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $connect_file  = "$project_dir/Plugins/SpotOn/Connect.pm";
my $ws_file       = "$project_dir/Plugins/SpotOn/Unified/SoloistWS.pm";
my $handler_file  = "$project_dir/Plugins/SpotOn/ProtocolHandler.pm";
my $control_file  = "$project_dir/Plugins/SpotOn/Soloist/Control.pm";

die "Connect.pm not present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n" unless -f $connect_file;

sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot read $file: $!";
    local $/;
    my $src = <$fh>;
    close($fh);
    return $src;
}

my $connect = slurp($connect_file);
my $ws      = -f $ws_file ? slurp($ws_file) : '';
my $handler = -f $handler_file ? slurp($handler_file) : '';
my $control = -f $control_file ? slurp($control_file) : '';

# The suppress branch must NOT dispatch playlist play but must keep the
# metadata fetch (session stays visible / manually resumable).

# ------------------------------------------------------------
# Task 2: GH #151 power save/restore
# ------------------------------------------------------------



# Control marks the transfer-away stop as the session-end signal (82-03:
# moved 1:1 out of SoloistWS's device_changed handler into Control::onEvent).
SKIP: {
    skip 'Control.pm not present', 1 unless $control;
    like($control, qr/_emit\('stop',\s*'inactive'\)/,
        "GH #151: Control device_changed(is_active:false) emits the 'inactive' session-end marker");
}


# ------------------------------------------------------------
# Phase 78-04: D-04 dual-backend dispatch (spoton://track: for
# Soloist, spoton://connect-%u for librespot)
# ------------------------------------------------------------

# Gate 1: 'start' block dispatches spoton://track: in a SoloistDaemon
# isa-branch AND still contains the literal spoton://connect-%u sprintf
# (librespot branch).
# 84-08 (SEAM-6.2): the URL choice moved into ONE helper keyed on the
# role's connectEntry -- the start block takes its URL from _playUrlFor and
# keys the per-track extras on the spoton://track: shape of that URL.

# Gate 2: 'change' block has dual-backend dispatch; the Soloist branch
# contains no skipInitiated reference (D-05 flush-disconnect delivers EOF).

# _onPause D-16 stale-claim guard: 83.1-07 inlines the librespot-only
# live-connect-stream check instead of calling the deleted helper. 84-07:
# the chain is gated by the role's connectClaimGate capability (librespot
# only) and the forwarding is the single role call after it.
my ($on_pause_block) = $connect =~ /(sub _onPause \{.*?\nsub )/s;

# ------------------------------------------------------------
# Phase 78-04: Watchdog Connect guards (Plugin.pm)
#
# Each of the five watchdog subs must contain at least one
# isSpotifyConnect reference; _onNewSongWatchdog must contain
# two (main body + deferred-timer closure).
# ------------------------------------------------------------



# ------------------------------------------------------------
# browse-stale-metadata-elapsed: _fetchTrackMetadata callback must not
# bleed a Connect track's title/duration onto a Browse song that took
# over playingSong() while the async getTrack() API call was in flight
# (e.g. a session-restore fetch racing a `playlist play spoton://track:`
# issued right after an LMS restart).
# ------------------------------------------------------------

my ($fetch_block) = $connect =~ /(sub _fetchTrackMetadata \{.*?\n1;)/s;

# ------------------------------------------------------------
# Phase 82-03: the seven session flags (sessionActive/sessionStarted/
# sessionPaused/deactivating/skipInitiated/pendingPlayConfirm/
# soloistBrowseActive) that used to live spread across SoloistWS.pm are
# retired -- SoloistWS is transport-only, forwarding every decoded frame
# raw to `onEvent`; Plugins::SpotOn::Soloist::Control (t/32, t/44) is now
# the single place that classifies events and emits spottyconnect.
# ------------------------------------------------------------
SKIP: {
    skip 'SoloistWS.pm not present', 6 unless $ws;

    unlike($ws, qr/\b(?:sessionActive|sessionStarted|sessionPaused|deactivating|skipInitiated|pendingPlayConfirm|soloistBrowseActive)\b/,
        'SoloistWS carries none of the seven session flags (Phase 82)');
    unlike($ws, qr/\bsub _emit\b|\bsub _on(?:AuthState|DeviceChanged|TrackChanged|PlaybackChanged|VolumeChanged|PositionSync|PlaybackState)\b/,
        'SoloistWS has no event handlers');
    like($ws, qr/onEvent/,
        'SoloistWS forwards to onEvent');
    unlike($ws, qr/spottyconnect/,
        'SoloistWS never emits spottyconnect');

    # Phase 82-40: LOC-policy regression guard. Total ceiling raised from
    # the exceeded 82-03 value (340) to 400; code-only ceiling (excluding
    # blank and comment-only lines) stays tight at 280 -- see the header
    # comment in SoloistWS.pm for the measured composition this is based on.
    my @ws_lines     = split /\n/, $ws;
    my $ws_total_loc = scalar(@ws_lines);
    my @ws_code_lines = grep { !/^\s*$/ && !/^\s*#/ } @ws_lines;
    my $ws_code_loc   = scalar(@ws_code_lines);

    cmp_ok($ws_total_loc, '<=', 400,
        'SoloistWS: Gesamt-LOC innerhalb der 82-40-Schranke (<=400)');
    cmp_ok($ws_code_loc, '<=', 280,
        'SoloistWS: Code-only-LOC innerhalb der 82-40-Schranke (<=280)');
}

# Gate 3 (Phase 82 Plan 01): soloistBrowseActive itself is retired from
# ProtocolHandler.pm -- getNextTrack's Browse dispatch delegates entirely
# to the player engine's requestTrack and sends no WS command of its own
# any more (T-1, T-3). 84-08 (SEAM-6.2): the delegation goes through the
# backend role -- ProtocolHandler calls control('track', source =>
# 'getNextTrack'), Backend::Soloist hands it to Control's requestTrack.
SKIP: {
    skip 'ProtocolHandler.pm not present', 3 unless $handler;

    like($handler, qr/->control\('track', source => 'getNextTrack'/,
        'getNextTrack delegates to the backend role (84-08)');
    like(slurp("$project_dir/Plugins/SpotOn/Backend/Soloist.pm"),
        qr/sub _trackFromGetNextTrack \{.*?\$ctl->requestTrack\(\$url, \$posMs,/s,
        'getNextTrack delegates to Control (inside Backend::Soloist, 84-08)');
    unlike($handler, qr/sendCommand\(/,
        'ProtocolHandler sends no WS command itself');
}

# The 'start' branch must contain no UNCONDITIONAL claim write -- the write
# `$_activeConnectPlayer = $client->id;` sits ONLY inside the non-Soloist
# (librespot) branch of the isa-check, never unguarded at the top level.

# ------------------------------------------------------------
# 83.1-02 Task 2 (D-D2/D-D3/D-04/D-05): split-brain ladder + conflict log.
# ------------------------------------------------------------

like($control, qr/^use constant SPLIT_BRAIN_MAX_ATTEMPTS => 2;/m,
    "83.1-02: SPLIT_BRAIN_MAX_ATTEMPTS constant is 2 (D-05: zweimal nicht)");
like($control, qr/sub _checkSplitBrain\b/, "83.1-02: _checkSplitBrain sub exists");
like($control, qr/sub _connectResync\b/, "83.1-02: _connectResync sub exists");
like($control, qr/'split-brain:'/, "83.1-02: split-brain: errors[] key literal present");
like($control, qr/'split-brain-halt:'/, "83.1-02: split-brain-halt: errors[] key literal present");
like($control, qr/LMS und Daemon uneinig/, "83.1-02: split-brain message text present");
like($control, qr/wieder geoeffnet/, "83.1-02: watchdog message text present");
like($control, qr/Notausgang/, "83.1-02: Notausgang message text present");

my ($connect_resync_block) = $control =~ /(sub _connectResync \{.*?\n\})/s;
ok($connect_resync_block, "83.1-02: _connectResync block parseable");
if ($connect_resync_block) {
    (my $cr_code = $connect_resync_block) =~ s/^\s*#.*$//gm;
    like($cr_code, qr/'watchdog:'/, "83.1-02: _connectResync itself writes the watchdog: key (not _watchdogRound2)");
    like($cr_code, qr/splitBrain\}\s*\|\|=/, "83.1-02: _connectResync creates the record when absent");
    like($cr_code, qr/'nachziehen'/, "83.1-02: _connectResync's re-emit carries origin 'nachziehen'");
}

my ($check_split_brain_block) = $control =~ /(sub _checkSplitBrain \{.*?\n\})/s;
ok($check_split_brain_block, "83.1-02: _checkSplitBrain block parseable");
if ($check_split_brain_block) {
    (my $csb_code = $check_split_brain_block) =~ s/^\s*#.*$//gm;
    like($csb_code, qr/mode eq 'connect'/, "83.1-02: _checkSplitBrain gates on mode eq 'connect' (D-A2)");
}

# BEFORE input that makes this gate red (checker-round dry run, per
# 83.1-02-PLAN.md's acceptance criteria): a _connectResync that re-emits
# _emit('change', $id, $prevId) WITHOUT the 'nachziehen' origin must fail
# the origin-literal check above -- confirmed by temporarily stripping the
# 4th argument from a copy of the extracted block and checking the same
# regex fails.
if ($connect_resync_block) {
    (my $regressed = $connect_resync_block) =~ s/,\s*'nachziehen'\)/)/;
    unlike($regressed, qr/'nachziehen'\)/,
        "83.1-02: dry-run -- stripping the origin argument makes the origin-literal check fail (gate can go red)");
}

my ($emit_block) = $control =~ /(sub _emit \{.*?\n\})/s;
ok($emit_block, "83.1-02: _emit block parseable");
if ($emit_block) {
    like($emit_block, qr/\$origin/, "83.1-02: _emit accepts a 5th \$origin argument");
}

# ------------------------------------------------------------
# 83.1-03 Task 2 (D-08): requestPause/requestResume/requestVolume routed
# through Control for BOTH modes; Connect.pm's _onPause/_bufferedSetVolume
# no longer gate the Control call on mode ne 'connect' -- the
# _sendControlCommand fallthrough is reached only when no Control exists
# (librespot).
# ------------------------------------------------------------

my ($on_pause_block_03) = $connect =~ /(sub _onPause \{.*?\nsub )/s;


like($control, qr/sub requestPause \{.*?mode eq 'connect'/s,
    "83.1-03: requestPause carries a connect row");
like($control, qr/sub requestResume \{.*?mode eq 'connect'/s,
    "83.1-03: requestResume carries a connect row");
like($control, qr/sub requestVolume \{.*?mode eq 'connect'/s,
    "83.1-03: requestVolume carries a connect row");

# ------------------------------------------------------------
# 83.1-03 Task 3 (EIGENTUMSFRAGE point 1/5): the Connect ownership
# invariant is written down and gated; _prefetchNext and its call site are
# untouched.
# ------------------------------------------------------------

like($control, qr/_prefetchNext if \$self->mode eq 'browse'/,
    "83.1-03 invariant: the _prefetchNext call site (point 5) is unchanged");
like($control, qr/never sends `play`\/`play uri` on its own/,
    "83.1-03 invariant: the _transport open branch's ownership comment survives");
like($control, qr/TEILENTSCHEID connect=Daemon-Eigentuemer/,
    "83.1-03 invariant: the Connect ownership invariant block exists");
like($control, qr/^sub notePlaylistChanged/m,
    "84.2-02: Control.pm defines notePlaylistChanged");
like($control, qr/Slim::Player::Playlist::track\(/,
    "84.2-02: the prefetch lookahead reads Playlist::track");
unlike($control, qr/Slim::Player::Playlist::song\(/,
    "84.2-02: the deprecated Playlist::song is no longer called (Pitfall 10)");

# ------------------------------------------------------------
# 83.1-04 Task 1 (D-B1): connect seek runs through the restart chain
# (getSeekData -> onStream -> Control::requestTrack -> the connect seek row
# in _reconcilePlan's Seek-Pfad); the LMS-side ['time'] WS bypass for N > 0
# is gone from _onSeek. canDoAction's connect 'rew' block is KEPT (plan-04
# decision: restart-at-0 now routes through requestSkip('prev'), not
# through an LMS-side stream restart).
# ------------------------------------------------------------




like($control, qr/sub requestSkip \{/, "83.1-04: Control.pm defines requestSkip");

# ------------------------------------------------------------
# 83.1-04 Task 2 (D-B2/D-B4): _onPlaylistJump routes both directions
# through Control::requestSkip; the D-B4 available_actions precondition is
# implemented in Control.pm.
# ------------------------------------------------------------


like($control, qr/vorbedingung_actions_unbekannt/, "83.1-04: D-B4 -- a never-seen available_actions field is refused");
like($control, qr/'refused-action:'/, "83.1-04: D-B4 -- refusals are recorded under the refused-action: errors[] key");

unlike($control, qr/requestSkip not yet routed/, "83.1-04: the Task 1 stub text is gone");

# ------------------------------------------------------------
# Debug session connect-skip-prev-ton-bleibt (2026-09-24), user decision
# 1B -- DEVIATION from D-B2 for `jump +0`: LMS decides. `jump +0` (the LMS
# "previous" button more than 5 s into the title) restarts the title from
# 0 through the seek path (Control::requestRestart); only a real `jump -1`
# goes to Spotify as skip_prev. Where the restart route cannot run
# (requestRestart returns 0), `jump +0` keeps the old skip_prev route.
#
# Connect.pm has no unit harness (Phase 73-03 D4), so the REAL
# _onPlaylistJump source is extracted from the file and compiled into a
# scratch package against recording stubs -- the assertions run the
# routing code itself, not a regex over it.
# ------------------------------------------------------------
# 84-07 Task 2: the harness drives the REAL handlers against a mock
# backend role (DaemonManager->backendFor) instead of a Control stub --
# Connect.pm no longer asks Control directly for any transport command.
{
    package Test::RoleMock;
    sub new {
        my ($class, %args) = @_;
        return bless { mode => 'connect', gate => 0, outcome => {}, calls => [], notes => [], queries => [], %args }, $class;
    }
    sub state        { return { mode => $_[0]->{mode} }; }
    sub capabilities { return { connectClaimGate => $_[0]->{gate} }; }
    sub control {
        my ($self, $verb, %args) = @_;
        push @{ $self->{calls} }, [ $verb, {%args} ];
        return exists $self->{outcome}{$verb} ? $self->{outcome}{$verb} : 'ok';
    }
    sub notify {
        my ($self, $event, %args) = @_;
        push @{ $self->{notes} }, [ $event, {%args} ];
        return 'ok';
    }
    sub query {
        my ($self, $what, %args) = @_;
        push @{ $self->{queries} }, $what;
        return $self->{wanted};
    }

    package Test::JumpClient;
    sub new        { return bless { id => $_[1], pd => {} }, $_[0]; }
    sub master     { return $_[0]; }
    sub id         { return $_[0]->{id}; }
    sub pluginData { my ($s, $k, $v) = @_; $s->{pd}{$k} = $v if @_ > 2; return $s->{pd}{$k}; }
    sub playingSong { return undef; }

    package Test::JumpRequest;
    sub new      { my ($class, %args) = @_; return bless {%args}, $class; }
    sub source   { return $_[0]->{source}; }
    sub client   { return $_[0]->{client}; }
    sub getParam { return $_[0]->{params}{ $_[1] }; }
    sub isCommand {
        my ($self, $spec) = @_;
        my $cmd = $self->{cmd} || [];
        for my $i (0 .. $#$spec) {
            return 0 unless defined $cmd->[$i] && grep { $_ eq $cmd->[$i] } @{ $spec->[$i] };
        }
        return 1;
    }

    package Test::RoleLog;
    our @INFO;
    sub new      { return bless {}, shift; }
    sub info     { shift; push @INFO, join('', @_); }
    sub debug    { }
    sub warn     { }
    sub is_info  { 1 }
    sub is_debug { 0 }

    package Test::RolePrefs;
    sub new { return bless {}, shift; }
    sub get { return undef; }

    # Stand-ins (never the real modules in this file): the handlers'
    # `require`s must find them in %INC; the side-effect channels count.
    package Plugins::SpotOn::Unified::DaemonManager;
    our $ROLE;
    # 84-08 Task 3: per-client roles (bindConnectClaim asks the OLD player's
    # role) and the running-daemon probe _liveCaps reads.
    our %ROLES;
    our $HELPER = 1;
    sub backendFor {
        my ($class, $c) = @_;
        my $id = ref $c ? $c->id : $c;
        return (defined $id && exists $ROLES{$id}) ? $ROLES{$id} : $ROLE;
    }
    sub helperForClient { return $HELPER; }

    package Slim::Player::Source;
    our $PLAYMODE = 'stop';
    sub playmode { return $PLAYMODE; }

    package Slim::Control::Request;
    our $NEW = 0;
    sub new { $NEW++; return bless {}, shift; }
    sub source { }
    sub execute { }

    package Slim::Networking::SimpleAsyncHTTP;
    our $NEW = 0;
    sub new  { $NEW++; return bless {}, shift; }
    sub post { }

    package Plugins::SpotOn::API::Client;
    our $CALLS = 0;
    sub AUTOLOAD { $CALLS++; }

    # Control is never reached through these handlers any more; the
    # stand-in (no instance for any player) keeps a stray `require` from
    # dying and would make a direct Control route visible as "no call".
    package Plugins::SpotOn::Soloist::Control;
    sub for_client { return undef; }
}
$INC{'Plugins/SpotOn/Unified/DaemonManager.pm'} = __FILE__;
$INC{'Plugins/SpotOn/Soloist/Control.pm'}       = __FILE__;
{
    no strict 'refs';
    *{'main::INFOLOG'}  = sub () { 1 } unless defined &main::INFOLOG;
    *{'main::DEBUGLOG'} = sub () { 0 } unless defined &main::DEBUGLOG;
}

my %role_src;
for my $name (qw(_onPause _onLmsStop _bufferedSetVolume _onSeek _onPlaylistJump _accountKeyOf _perAccount _claimGroupPeers)) {
    ($role_src{$name}) = $connect =~ /(sub \Q$name\E \{.*?\n\})\n/s;
}
my $role_compiled = !grep { !defined } values %role_src;
$role_compiled &&= eval(
    "package Test::RoleHarness;\n"
    . "use strict; use warnings; use Time::HiRes;\n"
    . "use constant CONNECT_START_GRACE => 12;\n"
    . "use constant VOLUME_DEBOUNCE => 0.5;\n"
    . "our \$SPOTIFY_CONNECT = 0;\n"
    . "my \$log   = Test::RoleLog->new;\n"
    . "my \$prefs = Test::RolePrefs->new;\n"
    . "my %_claim;\n"
    . "sub isSpotifyConnect { return \$SPOTIFY_CONNECT; }\n"
    . "sub _holdCancel { return; }\n"
    . "sub _isDeadHistoryUrl { return 0; }\n"
    . "sub _seekPositionFromRequest { return \$_[1]->getParam('_newvalue'); }\n"
    # a leftover direct HTTP send (the pre-84-07 route) counts as a POST
    . "sub _sendControlCommand { \$Slim::Networking::SimpleAsyncHTTP::NEW++; return; }\n"
    . join("\n", map { $role_src{$_} } sort keys %role_src) . "\n1;"
);

my $MAC37 = '02:00:00:5a:11:01';
sub role_reset {
    @Test::RoleLog::INFO = ();
    $Slim::Control::Request::NEW = 0;
    $Slim::Networking::SimpleAsyncHTTP::NEW = 0;
    $Plugins::SpotOn::API::Client::CALLS = 0;
    $Test::RoleHarness::SPOTIFY_CONNECT = 0;
}
sub role_run {
    my ($role, $handler, %req) = @_;
    local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $role;
    my $client = $req{client} || Test::JumpClient->new($MAC37);
    no strict 'refs';
    &{"Test::RoleHarness::$handler"}(Test::JumpRequest->new(client => $client, %req));
    return $role;
}
sub verbs { return [ map { $_->[0] } @{ $_[0]->{calls} } ]; }

my $jump_run = sub {
    my ($role, $index) = @_;
    role_run($role, '_onPlaylistJump', params => { _index => $index });
    return $role->{calls};
};
like($control, qr/sub requestRestart \{/, "1B: Control.pm defines requestRestart");
like($control, qr/sub consumeRestartAllowance \{/, "1B: Control.pm defines consumeRestartAllowance");


like($control, qr/historic pause\/stop notification, LMS already playing again -- ignored/,
    '83.1-06: requestPause\'s historic-notification check (Befund 3) covers the LMS-internal-stop-before-play echo -- '
    . 'the same purpose the _onPause fallthrough\'s connectPauseTs<1s AND connectStartTime<3s grace windows exist for');
like($control, qr/sub _lmsSongIsOurs \{/,
    '83.1-06: Control.pm defines _lmsSongIsOurs -- the URL-scheme ownership check requestPause/requestResume '
    . 'consult (covers the _onPause fallthrough\'s dead-history guard: a spoton://connect-* history URL is never '
    . 'spoton://track:/episode:, so _lmsSongIsOurs returns 0 and nothing is forwarded)');
like($control, qr/sub for_client \{/,
    '83.1-06: Control.pm defines for_client (per-MAC registry lookup) -- covers the _onPause fallthrough\'s '
    . 'player-switch guard structurally: each player dispatches through its OWN Control instance/MAC, never '
    . 'through the shared %_claim package hash the librespot-only fallthrough consults');

# ------------------------------------------------------------
# 83.1-07 Task 1 (ROADMAP Task 6): the Soloist WS branch of
# _sendControlCommand and _bufferedSeek are gone -- only the librespot HTTP
# path remains, reached only when no Control instance exists for the
# player.
# ------------------------------------------------------------
# 84-07 Task 2: the sender moved to Backend/Librespot.pm; Connect.pm has none left.


# ------------------------------------------------------------
# 84.1-07 (D-02): source gates for the leave path -- placement before
# CON-17, the exact guard text, the GH #151 discard, leaveConnect's own
# order and no-dispatch shape, the T-84.1-29 re-adoption guard on the
# reconnect `if`, and the marker's clear points (revision 2). These pin
# source shape; Task 2's mutation proofs (t/44/t/41 behaviour) are the
# can-fail evidence for what a source grep alone cannot catch.
# ------------------------------------------------------------


my ($leave_connect) = $control =~ /(sub leaveConnect \{.*?\n\})/s;
ok($leave_connect, '84.1-07 G6: leaveConnect block parseable');
if ($leave_connect) {
    my $leave_connect_code = join("\n", grep { !/^\s*#/ } split /\n/, $leave_connect);

    for my $token (qw(releaseConnectClaim _cancelConnectWatchdog startEmittedFor)) {
        ok((index($leave_connect_code, $token) >= 0), "84.1-07 G6: leaveConnect references $token");
    }
    ok((index($leave_connect_code, "mode('idle')") >= 0), "84.1-07 G6: leaveConnect sets mode('idle')");
    ok((index($leave_connect_code, "cmd => 'deactivate'") >= 0), "84.1-07 G6: leaveConnect sends the deactivate probe");

    my $mode_idx    = index($leave_connect_code, "mode('idle')");
    my $release_idx = index($leave_connect_code, 'releaseConnectClaim');
    my $deact_idx   = index($leave_connect_code, "cmd => 'deactivate'");
    ok(($deact_idx > $mode_idx && $deact_idx > $release_idx),
        "84.1-07 G6: the deactivate probe comes after both mode('idle') and releaseConnectClaim");

    unlike($leave_connect_code, qr/_emit\(|_dispatch\(|'(pause|play|seek)'/,
        "84.1-07 G6: leaveConnect carries none of Task 1's forbidden playback tokens (no emission/dispatch/pause|play|seek)");
}

like($control, qr/eq 'idle' && !\$self->_holdAfterForeignLeave\) \{/,
    "84.1-07 G7: the T-84.1-29 guard sits inside the reconnect-adoption condition, same line");

my ($hold_block) = $control =~ /(sub _holdAfterForeignLeave \{.*?\n\})/s;
ok($hold_block, '84.1-07 G7: _holdAfterForeignLeave block parseable');
if ($hold_block) {
    my $hold_code = join("\n", grep { !/^\s*#/ } split /\n/, $hold_block);
    like($hold_code, qr/leftConnectForeign/, "84.1-07 G7: _holdAfterForeignLeave references leftConnectForeign");
    like($hold_code, qr/_lmsSongIsOurs/, "84.1-07 G7: _holdAfterForeignLeave references _lmsSongIsOurs");
    unlike($hold_code, qr/Time::HiRes|time\(\)/,
        "84.1-07 G7: no clock read -- a pending-state marker plus a url class, never a time window (Pitfall 4)");
}

# G8 (revision 2, marker lifetime): the marker never outlives its
# post-leave episode -- same-line clears at requestTrack and the
# transfer-in, plus the explicit endForeignLeave clear point for an LMS
# stop / playlist clear.
my @marker_clear_sites = $control =~
    /(delete \$self->observed->\{leftBrowseUri\}; delete \$self->observed->\{leftConnectForeign\};)/g;
# D-34 (79-48): the transfer-in body moved into the shared _enterConnectSession
# (three callers); its clear of the marker is the `fresh` branch there. The
# same-line clear that remains is requestTrack's.
is(scalar(@marker_clear_sites), 1,
    "84.1-07 G8: the marker's same-line clear appears once (requestTrack); the transfer-in clears it in _enterConnectSession");
{
    my ($enter_block) = $control =~ /(sub _enterConnectSession \{.*?\n\}\n)/s;
    ok($enter_block, "84.1-07 G8 (D-34): _enterConnectSession block parseable");
    my $enter_code = join("\n", grep { !/^\s*#/ } split /\n/, ($enter_block // ''));
    like($enter_code, qr/if \(\$o\{fresh\}\) \{\s*delete \$self->observed->\{leftConnectForeign\};/,
        "84.1-07 G8 (D-34): a fresh session (the transfer-in, the takeover) clears leftConnectForeign in the shared sub");
    like($control, qr/_enterConnectSession\('transfer-in', fresh => 1\)/,
        "84.1-07 G8 (D-34): the device_changed transfer-in calls the shared sub as a fresh session");
}

ok((index($control, 'sub endForeignLeave') >= 0), "84.1-07 G8: Control.pm defines endForeignLeave");


# ------------------------------------------------------------
# 84.1-08 (CR-01): a distinct coderef for the playlist-clear subscription,
# so LMS's coderef-keyed %listeners (Request.pm:797) keeps both entries
# instead of the second silently replacing the first.
# ------------------------------------------------------------




# ------------------------------------------------------------
# 84.1-08 (WR-01, WR-02, WR-04, IN-04): three same-line edits in
# Control.pm (leftBrowseUri clear at any-mode is_active:0 and at the
# reconnect adoption, loggedOutAt stamp), the WR-02 discriminator in
# Connect.pm, and the IN-04 no-WS-connection notice in leaveConnect.
# ------------------------------------------------------------

# G9: the two WR-01 same-line clears, and the WR-04 stamp on the same
# line as the existing logged_in assignment.
{
    # D-34 (79-48): the reconnect adoption's mode flip and marker clear live in the
    # shared _enterConnectSession now (callers: reconnect adoption, transfer-in, takeover).
    my @reconnect_calls = $control =~ /(_enterConnectSession\('reconnect-to-connect'\))/g;
    is(scalar(@reconnect_calls), 1,
        "84.1-08 G9: the reconnect adoption enters connect through the shared sub exactly once");
    my ($enter_block) = $control =~ /(sub _enterConnectSession \{.*?\n\}\n)/s;
    my $enter_code = join("\n", grep { !/^\s*#/ } split /\n/, ($enter_block // ''));
    like($enter_code, qr/\$self->mode\('connect'\);.*delete \$self->observed->\{leftBrowseUri\};/s,
        "84.1-08 G9: the shared sub flips the mode to connect and clears leftBrowseUri");

    my @anymode_clear = $control =~
        /(\$self->observed->\{is_active\} = 0; delete \$self->observed->\{leftBrowseUri\};)/g;
    is(scalar(@anymode_clear), 1,
        "84.1-08 G9: is_active = 0; delete leftBrowseUri; appears once (any-mode session-loss clear)");

    my ($logged_in_line) = $control =~
        /(^.*\$self->observed->\{logged_in\} = \$msg->\{logged_in\} \? 1 : 0;.*$)/m;
    ok($logged_in_line, "84.1-08 G9: the logged_in assignment line is parseable");
    like($logged_in_line, qr/loggedOutAt/,
        "84.1-08 G9: the line holding the logged_in assignment also holds loggedOutAt");
}

# ------------------------------------------------------------
# 90.1-07 (GH #225, D-10): the app wake, source gates. Adapted from
# patapovich's AW-G1..G6 (PR #226); AW-G5 is inverted for D-11 (no
# split-brain stand-down in _checkSplitBrain).
# ------------------------------------------------------------
{
    require Digest::SHA;
    my $strip = sub { join("\n", grep { !/^\s*#/ } split /\n/, ($_[0] // '')) };
    my @wake_enter = $control =~ /(_enterConnectSession\('app-wake', fresh => 1, newSession => 1\))/g;
    is(scalar(@wake_enter), 1, "90.1-07 AWG1: the app wake enters connect through the shared sub once, fresh + newSession");
    my @restored = $control =~ /(_emitStart\(\$tid, undef, 'restored'\))/g;
    is(scalar(@restored), 1, "90.1-07 AWG1: the restored start of the reconnect adoption is still there, once");
    like($control, qr/my \$wake = \$self->_appWakeAfterBrowse;.*?bindConnectClaim\(\$bindClient, \$wake \? 'app-wake' : 'reconnect'\)/s,
        "90.1-07 AWG1: the wake verdict is read BEFORE the bind (leftBrowseUri is deleted by _enterConnectSession)");
    like($control, qr/_refreshAccount\('reconnect'\);\s*\n(?:\s*#[^\n]*\n)*\s*my \$wake = \$self->_appWakeAfterBrowse;/,
        "90.1-07 AWG1: ... and after the 90.1-02 account refresh");
    like($control, qr/"Control: app wake after a Browse stop on "/, "90.1-07 AWG1: the INFO line names the wake");

    my ($aw_block) = $control =~ /(sub _appWakeAfterBrowse \{.*?\n\})/s;
    ok($aw_block, "90.1-07 AWG2: _appWakeAfterBrowse block parseable");
    my $aw_code = $strip->($aw_block);
    like($aw_code, qr/$_/, "90.1-07 AWG2: _appWakeAfterBrowse references $_") for qw(wakeEdge leftBrowseUri _ownEchoOpen playmode _lmsSongIsOurs);
    unlike($aw_code, qr/Time::HiRes|time\(\)/, "90.1-07 AWG2: no clock read of its own (the only window is _ownEchoOpen)");
    (my $regressed = $aw_code) =~ s/\s*return undef if \$self->_ownEchoOpen;//;
    unlike($regressed, qr/_ownEchoOpen/, "90.1-07 AWG2: dry run -- dropping the echo exclusion makes the gate above go red");

    my ($nrs_block) = $control =~ /(sub _noteReportedStatus \{.*?\n\})/s;
    ok($nrs_block, "90.1-07 AWG3: _noteReportedStatus block parseable");
    unlike($strip->($nrs_block), qr/buffering/, "90.1-07 AWG3: buffering is never a reported status (an autoplay advance passes through it)");
    my ($exec_block) = $control =~ /(sub _execute \{.*?\n\})/s;
    like($strip->($exec_block), qr/delete \$self->observed->\{wakeEdge\};/, "90.1-07 AWG3: an own command retires the wake edge (_execute)");
    my ($tc_block) = $control =~ /(sub _transportClosed \{.*?\n\})/s;
    like($strip->($tc_block), qr/reportedStatus wakeEdge/, "90.1-07 AWG3: a transport close drops the reported status and the edge");

    my ($guard) = $control =~ /(# fremder-autoplay-waechter.*?autoplayPaused\} = \$uri;)/s;
    ok($guard, "90.1-07 AWG4: the autoplay guard block parseable");
    unlike($guard // '', qr/wakeEdge|reportedStatus|asStart|_appWake/, "90.1-07 AWG4: the autoplay guard is untouched by the app wake");

    # D-11: _checkSplitBrain stays byte-identical to its 90.1-07 base (a9ef1772); the digest below is
    # `git show a9ef1772:Plugins/SpotOn/Soloist/Control.pm | perl -ne 'print if /^sub _checkSplitBrain\b/../^\}/' | sha256sum`.
    my $csb_text = join('', grep { /^sub _checkSplitBrain\b/ .. /^\}/ } map { "$_\n" } split /\n/, $control);
    is(Digest::SHA::sha256_hex($csb_text), 'b92b2cc042d791efdcb3f457dac6f8a2c5e896c6ead808306e2640e532395c71',
        "90.1-07 AWG5 (D-11): _checkSplitBrain is unchanged against the plan's base");
    unlike($strip->($csb_text), qr/_ownEchoOpen|asStart/, "90.1-07 AWG5 (D-11): no echo or held-start stand-down in _checkSplitBrain");
    my ($ccr) = $control =~ /(sub _connectResync \{.*?\n\})/s;
    my $ccr_code = $strip->($ccr);
    my ($i_hold, $i_sb) = map { index($ccr_code, $_) } ('{resumeDue}{asStart}', 'my $sb = ');
    ok($i_hold >= 0 && $i_hold < $i_sb, "90.1-07 AWG5: the held app-wake start holds the rung in _connectResync, before the attempt is counted");

    my ($aos) = $control =~ /(sub _adoptedOnStaleStop \{.*?\n\})/s;
    my $aos_code = $strip->($aos);
    like($aos_code, qr/sessionEntry/, "90.1-07 AWG6: the stale-stop start conversion is limited to adopted sessions (sessionEntry)");
    like($aos_code, qr/reconnect-to-connect\|app-wake/, "90.1-07 AWG6: ... the reconnect adoption and the app wake only");
    my ($rdr) = $control =~ /(sub _resumeDueRelease \{.*?\n\})/s;
    like($strip->($rdr), qr/\$why ne 'new title' && \$self->_adoptedOnStaleStop/, "90.1-07 AWG6: a 'new title' resume release is never converted");
    like($ccr_code, qr/_adoptedOnStaleStop/, "90.1-07 AWG6: the ladder rung uses the same predicate");
}

# G10: WR-02's discriminator placement and its no-clock/weak-reference
# shape.



# G11: the IN-04 no-WS-connection notice sits before the deactivate probe,
# and the existing G6 forbidden-token assertion stays green.
my ($leave_connect_g11) = $control =~ /(sub leaveConnect \{.*?\n\})/s;
ok($leave_connect_g11, '84.1-08 G11: leaveConnect block parseable');
if ($leave_connect_g11) {
    my $leave_connect_g11_code = join("\n", grep { !/^\s*#/ } split /\n/, $leave_connect_g11);

    like($leave_connect_g11_code, qr/leaveConnect without a WS connection -- deactivate not sent/,
        "84.1-08 G11: leaveConnect logs the no-WS-connection notice");
    like($leave_connect_g11_code, qr/wsConnected/,
        "84.1-08 G11: the notice branch reads wsConnected");

    my $notice_idx  = index($leave_connect_g11_code, 'leaveConnect without a WS connection -- deactivate not sent');
    my $wsconn_idx  = index($leave_connect_g11_code, 'wsConnected');
    my $deact_idx11 = index($leave_connect_g11_code, "cmd => 'deactivate'");
    ok(($notice_idx >= 0 && $wsconn_idx >= 0 && $deact_idx11 >= 0
            && $notice_idx < $deact_idx11 && $wsconn_idx < $deact_idx11),
        "84.1-08 G11: the notice text and the wsConnected read both sit before the deactivate probe");

    unlike($leave_connect_g11_code, qr/_emit\(|_dispatch\(|'(pause|play|seek)'/,
        "84.1-08 G11: leaveConnect still carries none of Task 1's forbidden playback tokens");
}




# ------------------------------------------------------------
# 84-08 Task 3 (SEAM-6.2): the REAL Connect.pm/Plugin.pm handler sources
# that moved onto the role, compiled into a scratch package against
# recording mock roles (same discipline as the 84-07 harness above).
# ------------------------------------------------------------
{
    package Test::RoleMock3;
    sub new {
        my ($class, %a) = @_;
        return bless { st => {}, caps => {}, notes => [], outcome => {}, %a }, $class;
    }
    sub state        { return { %{ $_[0]->{st} } }; }
    sub capabilities { return { %{ $_[0]->{caps} } }; }
    sub notify {
        my ($self, $event, %args) = @_;
        push @{ $self->{notes} }, [ $event, {%args} ];
        return exists $self->{outcome}{$event} ? $self->{outcome}{$event} : 'ok';
    }
    sub control { return 'unsupported'; }

    package Test::RoleLog3;
    our (@INFO, @WARN);
    sub new      { return bless {}, shift; }
    sub info     { shift; push @INFO, join('', @_); }
    sub warn     { shift; push @WARN, join('', @_); }
    sub debug    { }
    sub is_info  { 1 }
    sub is_debug { 0 }

    package Test::Client3;
    sub new        { my ($c, $id, %a) = @_; return bless { id => $id, pd => {}, executed => [], %a }, $c; }
    sub id         { return $_[0]->{id}; }
    sub master     { return $_[0]; }
    sub pluginData { my ($s, $k, $v) = @_; $s->{pd}{$k} = $v if @_ > 2; return $s->{pd}{$k}; }
    sub playingSong { return $_[0]->{song}; }
    sub execute    { my ($s, $cmd) = @_; push @{ $s->{executed} }, [ @$cmd ]; }

    package Test::Song3;
    sub new   { return bless { url => $_[1] }, $_[0]; }
    sub track { return $_[0]; }
    sub url   { return $_[0]->{url}; }

    package Slim::Player::Client;
    our %BY_ID;
    sub getClient { return $BY_ID{ $_[0] }; }

    package Plugins::SpotOn::Connect;
    our $IS_CONNECT = 0;
    sub isSpotifyConnect { return $IS_CONNECT; }
}
$INC{'Plugins/SpotOn/Connect.pm'} = __FILE__;

my %src3;
for my $name (qw(_liveCaps _itemUri _itemUrl _playUrlFor bindConnectClaim _accountKeyOf _perAccount _claimGroupPeers _claimSet _onLmsPlaylistChanged _holdCaps _holdCap _holdRecheck _holdMax _holdClose)) {
    ($src3{$name}) = $connect =~ /(sub \Q$name\E \{.*?\n\})\n/s;
    ($src3{$name}) = $connect =~ /^(sub \Q$name\E .*?\})$/m unless $src3{$name};
}
my ($hang_src) = slurp("$project_dir/Plugins/SpotOn/Plugin.pm") =~ /(sub _prefetchHangCheck \{.*?\n\})\n/s;
$src3{_prefetchHangCheck} = $hang_src;
my @missing3 = grep { !defined $src3{$_} } sort keys %src3;
my $h3 = !@missing3 && eval(
    "package Test::RoleHarness3;\n"
    . "use strict; use warnings; use Time::HiRes; use Scalar::Util qw(weaken);\n"
    . "my \$log = Test::RoleLog3->new;\n"
    . "my (%_claim, \$_lastBindAt, %_connectEntrySong, %_hold, %_watchdogTriggerUrl);\n"
    . "sub setActive  { %_claim = (); \$_claim{ \$_[0] } = 1 if defined \$_[0]; }\n"
    . "sub addActive  { \$_claim{ \$_[0] } = 1; }\n"
    . "sub dropActive { delete \$_claim{ \$_[0] }; }\n"
    . "sub getActive  { my \@k = sort keys %_claim; return wantarray ? \@k : \$k[0]; }\n"
    . "sub setHold    { \$_hold{ \$_[0] } = \$_[1]; }\n"
    . "sub setTrigger { \$_watchdogTriggerUrl{ \$_[0] } = \$_[1]; }\n"
    . join("\n", map { $src3{$_} } sort keys %src3) . "\n1;"
);

# ------------------------------------------------------------
# 90.1-03 (D-02 / invariant): the unknown account never releases anybody, and
# the claim set keeps its shape over any sequence of bind / start / resume /
# release: no two holders share a known account key (claimPerAccount 1), at
# most one holder (claimPerAccount 0).
# ------------------------------------------------------------
ok($h3, '90.1-03: the claim-set subs compile in the role harness') or diag($@);
if ($h3) {
    my $acct = sub { defined $_[0] ? { key => $_[0], short => '1234' } : undef };

    # S1 (D-02): an unknown key never releases; a key that becomes known does
    {
        my $p1 = Test::Client3->new('aa:00:00:00:00:21');
        my $p2 = Test::Client3->new('aa:00:00:00:00:22');
        my $r1 = Test::RoleMock3->new(st => { mode => 'connect', active => 1, account => $acct->('aaaaaaaa') }, caps => { claimPerAccount => 1 });
        my $r2 = Test::RoleMock3->new(st => { mode => 'connect', active => 1, account => undef },               caps => { claimPerAccount => 1 });
        local %Slim::Player::Client::BY_ID = ($p1->id => $p1, $p2->id => $p2);
        local %Plugins::SpotOn::Unified::DaemonManager::ROLES = ($p1->id => $r1, $p2->id => $r2);
        @Test::RoleLog3::WARN = ();
        Test::RoleHarness3::setActive($p1->id);
        Test::RoleHarness3::bindConnectClaim('Plugins::SpotOn::Connect', $p2, 'transfer');
        is_deeply([ Test::RoleHarness3::getActive() ], [ $p1->id, $p2->id ], '90.1-03 S1: P2 with an unknown account binds: both hold');
        is(scalar(@Test::RoleLog3::WARN), 0, '90.1-03 S1: no warning');
        is_deeply($r1->{notes}, [], '90.1-03 S1: P1\'s role was not notified');

        $r2->{st}{account} = $acct->('aaaaaaaa');
        Test::RoleHarness3::bindConnectClaim('Plugins::SpotOn::Connect', $p2, 'transfer');
        is_deeply([ Test::RoleHarness3::getActive() ], [ $p2->id ], '90.1-03 S1: once P2\'s key is X and it binds again, P1 is released');
        is_deeply([ map { $_->[0] } @{ $r1->{notes} } ], [ 'recordErrorOnce', 'claimLost' ], '90.1-03 S1: ... with recordErrorOnce + claimLost on P1\'s role');
    }

    # S2: the silent writers (start, resume) drop only the holders of the SAME known account
    for my $why (qw(start resume)) {
        for my $case ([ 'other account', 'bbbbbbbb', 1 ], [ 'unknown account', undef, 1 ], [ 'same account', 'aaaaaaaa', 0 ]) {
            my ($label, $key2, $keeps) = @$case;
            my $p1 = Test::Client3->new('aa:00:00:00:00:31');
            my $p2 = Test::Client3->new('aa:00:00:00:00:32');
            my $r1 = Test::RoleMock3->new(st => { mode => 'connect', active => 1, account => $acct->('aaaaaaaa') }, caps => { claimPerAccount => 1 });
            my $r2 = Test::RoleMock3->new(st => { mode => 'connect', active => 1, account => $acct->($key2) },     caps => { claimPerAccount => 1 });
            local %Slim::Player::Client::BY_ID = ($p1->id => $p1, $p2->id => $p2);
            local %Plugins::SpotOn::Unified::DaemonManager::ROLES = ($p1->id => $r1, $p2->id => $r2);
            Test::RoleHarness3::setActive($p1->id);
            Test::RoleHarness3::_claimSet($p2, $why);
            is_deeply([ Test::RoleHarness3::getActive() ], ($keeps ? [ $p1->id, $p2->id ] : [ $p2->id ]),
                "90.1-03 S2 $why ($label): " . ($keeps ? 'both hold' : 'P1 is dropped silently'));
            is_deeply([ @{ $r1->{notes} }, @{ $r2->{notes} } ], [], "90.1-03 S2 $why ($label): nobody is notified");
        }
    }

    # INV: a fixed pseudo-random sequence of 200 operations, for both capability values
    for my $perAcct (1, 0) {
        my %key = (A => 'aaaaaaaa', B => 'aaaaaaaa', C => 'bbbbbbbb', D => undef, E => undef);
        my (%cl, %role, %roles);
        my $i = 40;
        for my $n (sort keys %key) {
            $cl{$n}    = Test::Client3->new(sprintf('aa:00:00:00:00:%02x', $i++));
            $role{$n}  = Test::RoleMock3->new(st => { mode => 'connect', active => 1, account => $acct->($key{$n}) }, caps => { claimPerAccount => $perAcct });
            $roles{ $cl{$n}->id } = $role{$n};
        }
        my %nameOf = map { $cl{$_}->id => $_ } keys %cl;
        local %Slim::Player::Client::BY_ID = map { $cl{$_}->id => $cl{$_} } keys %cl;
        local %Plugins::SpotOn::Unified::DaemonManager::ROLES = %roles;
        Test::RoleHarness3::setActive(undef);
        my $seed = 9013;
        my $rnd  = sub { $seed = ($seed * 1103515245 + 12345) % 2147483648; return $seed >> 16; };
        my @names = sort keys %key;
        my ($bad, $maxHolders, %ops) = (undef, 0);
        for my $step (1 .. 200) {
            my $n  = $names[ $rnd->() % @names ];
            my $op = (qw(bind start resume release))[ $rnd->() % 4 ];
            $ops{$op}++;
            if    ($op eq 'bind')    { Test::RoleHarness3::bindConnectClaim('Plugins::SpotOn::Connect', $cl{$n}, 'transfer'); }
            elsif ($op eq 'start')   { Test::RoleHarness3::_claimSet($cl{$n}, 'start'); }
            elsif ($op eq 'resume')  { Test::RoleHarness3::_claimSet($cl{$n}, 'resume'); }
            else                     { Test::RoleHarness3::dropActive($cl{$n}->id); }
            my @h = Test::RoleHarness3::getActive();
            $maxHolders = @h if @h > $maxHolders;
            if ($op ne 'release' && !grep { $_ eq $cl{$n}->id } @h) { $bad //= "step $step: $op of $n left no claim for it"; }
            if (!$perAcct) {
                $bad //= "step $step: " . scalar(@h) . " holders under claimPerAccount 0" if @h > 1;
            }
            else {
                my %seen;
                for my $id (@h) {
                    my $k = $key{ $nameOf{$id} } // next;
                    $bad //= "step $step: two holders of account $k" if $seen{$k}++;
                }
            }
        }
        is($bad, undef, "90.1-03 INV: claimPerAccount $perAcct: the invariant holds over 200 operations");
        is($ops{bind} + $ops{start} + $ops{resume} + $ops{release}, 200, "90.1-03 INV: claimPerAccount $perAcct: 200 operations ran");
        if ($perAcct) { cmp_ok($maxHolders, '>=', 3, '90.1-03 INV: claimPerAccount 1: the sequence really reached several holders (not vacuous)'); }
        else          { is($maxHolders, 1, '90.1-03 INV: claimPerAccount 0: never more than one holder, and one was reached'); }
    }
}

done_testing();
