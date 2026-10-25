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

# 84-09: core half of t/37_connect_lifecycle.t -- the Connect.pm / ProtocolHandler.pm
# source nets and the role harness over Test::RoleMock. The Soloist/Control.pm and
# SoloistWS.pm nets (incl. their Control/SoloistWS-conditional SKIPs) are
# t/soloist/37_connect_lifecycle_soloist.t; the Backend/Librespot.pm
# _sendControlCommand nets are t/librespot/37_connect_lifecycle_librespot.t.
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $connect_file  = "$project_dir/Plugins/SpotOn/Connect.pm";
my $handler_file  = "$project_dir/Plugins/SpotOn/ProtocolHandler.pm";

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
my $handler = -f $handler_file ? slurp($handler_file) : '';

# ------------------------------------------------------------
# Task 1: restart-autoplay gate
# ------------------------------------------------------------

like($connect, qr/use constant RESTART_START_GRACE\s*=>/,
    'restart gate: RESTART_START_GRACE constant defined');

like($connect,
    qr/uptime\(\$client->id\).*?\n.*?RESTART_START_GRACE/s,
    'restart gate: start handler consults daemon uptime against RESTART_START_GRACE');

# The suppress branch must NOT dispatch playlist play but must keep the
# metadata fetch (session stays visible / manually resumable).
my ($suppress_block) = $connect =~ /(\$daemonUptime < RESTART_START_GRACE\).*?return;)/s;
ok($suppress_block, 'restart gate: suppress branch exists and returns early');
if ($suppress_block) {
    unlike($suppress_block, qr/'playlist',\s*'play'/,
        'restart gate: suppress branch does NOT dispatch playlist play');
    like($suppress_block, qr/_fetchTrackMetadata/,
        'restart gate: suppress branch still fetches metadata (session stays visible)');
}

# ------------------------------------------------------------
# Task 2: GH #151 power save/restore
# ------------------------------------------------------------

my @save_sites = $connect =~ /(connectPrevPower => \(\$client->power \? 1 : 0\))/g;
cmp_ok(scalar(@save_sites), '>=', 2,
    'GH #151: at least two save sites (start handler + resume re-entry)');

like($connect, qr/sub _restorePowerAfterConnect/,
    'GH #151: restore helper exists');

my ($restore_block) = $connect =~ /(sub _restorePowerAfterConnect \{.*?\n\})/s;
ok($restore_block, 'GH #151: restore helper block parseable');
if ($restore_block) {
    like($restore_block, qr/\['power',\s*0\]/,
        'GH #151: restore dispatches a power-off request');
    like($restore_block, qr/source\(__PACKAGE__\)/,
        'GH #151: power-off request is source-marked (no event echo)');
    like($restore_block, qr/connectPrevPower => undef/,
        'GH #151: saved state is always cleared');
}

# The restore call must live in the session-end ('inactive'-marked stop)
# branch — NOT the newTrack track-transition stop ignore.
like($connect,
    qr/eq 'inactive'\).*?_restorePowerAfterConnect\(\$client\)/s,
    "GH #151: restore is wired to the 'inactive' session-end stop branch");
my ($newtrack_stop_block) = $connect =~
    /(if \(\$cmd eq 'stop' && \$client->pluginData\('newTrack'\)\) \{.*?\n    \})/s;
ok($newtrack_stop_block, 'GH #151: newTrack transitional-stop branch parseable');
if ($newtrack_stop_block) {
    unlike($newtrack_stop_block, qr/_restorePowerAfterConnect/,
        'GH #151: restore is NOT wired into the newTrack transitional-stop branch');
}

# ------------------------------------------------------------
# Task 3: GH #158 pause-skip-play loop
# ------------------------------------------------------------

like($connect,
    qr/!\$client->isPlaying && __PACKAGE__->isSpotifyConnect\(\$client\)\s*\n\s*&& !\$client->pluginData\('connectSessionPaused'\)/,
    'GH #158: change-handler force-unpause is gated on connectSessionPaused');

like($connect,
    qr/connectSessionPaused => 1/,
    'GH #158: stop handler records the Spotify-side pause state');

my @clear_sites = $connect =~ /(connectSessionPaused => 0)/g;
cmp_ok(scalar(@clear_sites), '>=', 4,
    'GH #158: pause state cleared on start/resume/unpause/session-end paths');

# ------------------------------------------------------------
# Phase 78-04: D-04 dual-backend dispatch (spoton://track: for
# Soloist, spoton://connect-%u for librespot)
# ------------------------------------------------------------

# Gate 1: 'start' block dispatches spoton://track: in a SoloistDaemon
# isa-branch AND still contains the literal spoton://connect-%u sprintf
# (librespot branch).
my ($start_d04_block) = $connect =~ /(# -+\n\s+# Start:.*?)(?=# -+\n\s+# Change:)/s;
ok($start_d04_block, 'D-04 start: handler block parseable');
# 84-08 (SEAM-6.2): the URL choice moved into ONE helper keyed on the
# role's connectEntry -- the start block takes its URL from _playUrlFor and
# keys the per-track extras on the spoton://track: shape of that URL.
my ($play_url_for) = $connect =~ /(sub _playUrlFor \{.*?\n\})/s;
ok($play_url_for, '84-08: _playUrlFor block parseable');
if ($start_d04_block) {
    like($start_d04_block,
        qr/my \$startPlayUrl = _playUrlFor\(\$client, \$trackId\);.*?\$startPlayUrl =~ m\{\^spoton:\/\/track:\}/s,
        'D-04 start: the per-track (spoton://track:) URL comes from _playUrlFor (84-08)');
}
if ($play_url_for) {
    like($play_url_for,
        qr/"spoton:\/\/track:\$trackId"\s*\n\s*if \$trackId && \(_liveCaps\(\$client\)->\{connectEntry\} \/\/ ''\) eq 'pertrack';/,
        "D-04 (84-08): _playUrlFor gives spoton://track:<id> only for connectEntry 'pertrack' with a track id");
    like($play_url_for,
        qr/spoton:\/\/connect-%u/,
        'D-04 start: the repeating backend still uses spoton://connect-%u (in _playUrlFor, 84-08)');
}

# Gate 2: 'change' block has dual-backend dispatch; the Soloist branch
# contains no skipInitiated reference (D-05 flush-disconnect delivers EOF).
my ($change_d04_block) = $connect =~ /(# -+\n\s+# Change:.*?)(?=# -+\n\s+# Stop:)/s;
ok($change_d04_block, 'D-04 change: handler block parseable');
if ($change_d04_block) {
    like($change_d04_block,
        qr/\(_liveCaps\(\$client\)->\{connectEntry\} \/\/ ''\) eq 'pertrack' && \$newTrackId\) \{.*?spoton:\/\/track:/s,
        'D-04 change: the per-track (connectEntry pertrack) branch dispatches spoton://track: URL (84-08)');
    like($change_d04_block,
        qr/_fetchTrackMetadata\(\$client,\s*\$newTrackId\)/,
        'D-04 change: librespot branch still fetches metadata for the new track');
    # 82-05: the ONLY spoton://connect-%u construction that used to live in
    # this block was inside the 260827-of9 skipInitiated reconnect
    # special-path, which RESEARCH confirmed unreachable in EVERY
    # configuration (Soloist already `return`s above; librespot's flag
    # lookup always returned undef) -- deleted, not relocated. The
    # librespot 'change' path never constructed its own URL outside that
    # dead branch.
    unlike($change_d04_block,
        qr/spoton:\/\/connect-%u/,
        'D-04 change: the dead skipInitiated reconnect block (and its URL construction) is gone');
    # Extract the Soloist-specific change block: from SoloistDaemon to the
    # 'return;' that ends it, before the librespot code.  Check that the
    # Soloist branch does not USE skipInitiated in code (comments mentioning
    # it for rationale are fine -- strip comments before checking).
    my ($soloist_change) = $change_d04_block =~
        /(eq 'pertrack' && \$newTrackId\) \{.*?spoton:\/\/track:.*?return;)/s;
    if ($soloist_change) {
        # Strip comment lines for the assertion: we care about code, not docs.
        (my $soloist_code = $soloist_change) =~ s/^\s*#.*$//gm;
        unlike($soloist_code, qr/skipInitiated/,
            'D-04 change: Soloist branch code does not reference skipInitiated');
    }
}

# ------------------------------------------------------------
# 83.1-07 Task 2 (Group A, ROADMAP Task 6): the Phase 78-04 ownership
# heuristics (the Soloist track-ID URL-matching helper and its live-stream
# wrapper) are gone -- every former call site now asks Control's own mode
# directly (Control->for_client ... ->mode eq 'connect'), since the claim
# is bound by the transfer class (plan 02) rather than inferred from the
# daemon's lastTrackId.
# ------------------------------------------------------------

unlike($connect, qr/sub _isSoloistOwnedSong\b/,
    '83.1-07: _isSoloistOwnedSong is deleted');
unlike($connect, qr/_isSoloistOwnedSong/,
    '83.1-07: no remaining reference to _isSoloistOwnedSong anywhere in Connect.pm');
unlike($connect, qr/sub _isLiveConnectStream\b/,
    '83.1-07: _isLiveConnectStream is deleted');
unlike($connect, qr/_isLiveConnectStream/,
    '83.1-07: no remaining reference to _isLiveConnectStream anywhere in Connect.pm');
unlike($connect, qr/sub _releaseConnectClaim\b/,
    '83.1-07: the _releaseConnectClaim alias is deleted');
unlike($connect, qr/_releaseConnectClaim/,
    '83.1-07: no remaining reference to _releaseConnectClaim anywhere in Connect.pm');

# Restart-gate suppressed branch still clears pendingConnect (unchanged).
like($connect,
    qr/start_suppressed.*?pendingConnect\s*=>\s*0/s,
    'D-16: restart-gate suppressed branch clears pendingConnect before return');

# _onPause D-16 stale-claim guard: 83.1-07 inlines the librespot-only
# live-connect-stream check instead of calling the deleted helper. 84-07:
# the chain is gated by the role's connectClaimGate capability (librespot
# only) and the forwarding is the single role call after it.
my ($on_pause_block) = $connect =~ /(sub _onPause \{.*?\nsub )/s;
ok($on_pause_block, 'D-16: _onPause block parseable');
if ($on_pause_block) {
    like($on_pause_block,
        qr/connectClaimGate\}\) \{.*?isSpotifyConnect\(\$client\).*?isLiveConnectStream.*?\$be->control\(\$verb/s,
        '83.1-07/84-07: stale-claim guard (inlined live-connect-stream check) sits inside the connectClaimGate block, between the isSpotifyConnect gate and the role call');
}

# ------------------------------------------------------------
# Phase 78-04: Watchdog Connect guards (Plugin.pm)
#
# Each of the five watchdog subs must contain at least one
# isSpotifyConnect reference; _onNewSongWatchdog must contain
# two (main body + deferred-timer closure).
# ------------------------------------------------------------

my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";
SKIP: {
    skip 'Plugin.pm not present', 7 unless -f $plugin_file;
    my $plugin = slurp($plugin_file);

    # Extract each watchdog sub by name (greedy up to next ^sub or end).
    my ($newsong_wd)  = $plugin =~ /(sub _onNewSongWatchdog \{.*?)(?=\nsub )/s;
    my ($modechange)  = $plugin =~ /(sub _onModeChange \{.*?)(?=\nsub )/s;
    my ($pauseguard)  = $plugin =~ /(sub _pauseGuardCheck \{.*?)(?=\nsub )/s;
    my ($prefetch_wd) = $plugin =~ /(sub _prefetchWatchdog \{.*?)(?=\nsub )/s;
    my ($hang_check)  = $plugin =~ /(sub _prefetchHangCheck \{.*?)(?=\n(?:sub |1;))/s;

    ok($newsong_wd,  'watchdog: _onNewSongWatchdog extracted');
    ok($modechange,  'watchdog: _onModeChange extracted');
    ok($pauseguard,  'watchdog: _pauseGuardCheck extracted');
    ok($prefetch_wd, 'watchdog: _prefetchWatchdog extracted');
    ok($hang_check,  'watchdog: _prefetchHangCheck extracted');

    # Each sub must reference isSpotifyConnect (the Connect guard).
    for my $pair (
        [$newsong_wd,  '_onNewSongWatchdog'],
        [$modechange,  '_onModeChange'],
        [$pauseguard,  '_pauseGuardCheck'],
        [$prefetch_wd, '_prefetchWatchdog'],
        [$hang_check,  '_prefetchHangCheck'],
    ) {
        my ($body, $name) = @$pair;
        SKIP: {
            skip "$name not extracted", 1 unless $body;
            like($body, qr/isSpotifyConnect/,
                "watchdog: $name contains isSpotifyConnect guard");
        }
    }

    # _onNewSongWatchdog must contain TWO isSpotifyConnect references:
    # one in the main body and one in the deferred-timer closure.
    SKIP: {
        skip '_onNewSongWatchdog not extracted', 1 unless $newsong_wd;
        my @matches = $newsong_wd =~ /(isSpotifyConnect)/g;
        cmp_ok(scalar(@matches), '>=', 2,
            'watchdog: _onNewSongWatchdog contains isSpotifyConnect at least twice (body + closure)');
    }

    # PLUGIN_ISSPOTIFYCONNECT_KEEP = 6 -- 83.1-07 Task 2 Group B (D-C3): all
    # six isSpotifyConnect call sites in Plugin.pm (_onNewSongWatchdog
    # deferred-closure, _onNewSongWatchdog
    # main body, _onModeChange, _pauseGuardCheck, _prefetchWatchdog,
    # _prefetchHangCheck) were individually reviewed and KEPT after the
    # claim-binding rewrite (plan 02) -- the URL scheme still does not
    # discriminate Browse from Connect (both use spoton://track:ID since
    # D-04), so the guard's original purpose still holds at every site.
    # This count pins that KEEP verdict: 6 KEEP rows in 83.1-GUARDS.md, 6
    # call sites in the source, no more, no less.
    # 79-27 D-20 adds ONE reviewed site on top of the six: _refreshMetaForClient (the playlist newsong refresh
    # subscriber) skips Connect sessions with the same guard, because Connect.pm _fetchTrackMetadata refreshes those
    # track starts itself and spoton://track: urls do not discriminate Browse from Connect either (D-04).
    my $isspotifyconnect_count = () = $plugin =~ /isSpotifyConnect/g;
    is($isspotifyconnect_count, 7,
        '83.1-07: Plugin.pm has exactly 7 isSpotifyConnect call sites (6 D-C3 group B KEEP + the 79-27 D-20 refresh guard)');
}


# ------------------------------------------------------------
# browse-stale-metadata-elapsed: _fetchTrackMetadata callback must not
# bleed a Connect track's title/duration onto a Browse song that took
# over playingSong() while the async getTrack() API call was in flight
# (e.g. a session-restore fetch racing a `playlist play spoton://track:`
# issued right after an LMS restart).
# ------------------------------------------------------------

my ($fetch_block) = $connect =~ /(sub _fetchTrackMetadata \{.*?\n1;)/s;
ok($fetch_block, 'metadata-bleed: _fetchTrackMetadata block parseable');
if ($fetch_block) {
    # Guard exists: bail out unless playingSong is still a Connect stream.
    like($fetch_block,
        qr/\$songUrl\s*=~\s*m\{spoton:\/\/connect-\}/,
        'metadata-bleed: guard checks playingSong URL is still spoton://connect-*');

    # Guard sits AFTER playingSong() is fetched but BEFORE the title is
    # read from $trackInfo (i.e. before any mutation of $song/duration/title).
    like($fetch_block,
        qr/playingSong\(\).*?songUrl\s*=~\s*m\{spoton:\/\/connect-\}.*?my\s+\$title\s*=\s*\$trackInfo->\{name\}/s,
        'metadata-bleed: guard runs before title/duration are read from the (possibly stale) response');

    # Discard path still satisfies H7 (every exit path clears newTrack) and
    # nudges clients to re-query the now-correct metadata.
    my ($discard_block) = $fetch_block =~ /(unless\s*\(\$songUrl\s*=~\s*m\{spoton:\/\/connect-\}\)\s*\{.*?\n\s*\})/s;
    ok($discard_block, 'metadata-bleed: discard branch parseable');
    if ($discard_block) {
        like($discard_block, qr/notifyFromArray/,
            'metadata-bleed: discard branch still fires newmetadata notify');
        like($discard_block, qr/_finishNewTrack\(\$client\)/,
            'metadata-bleed: discard branch still clears newTrack flag (H7)');
        unlike($discard_block, qr/\$song->duration/,
            'metadata-bleed: discard branch does not touch $song->duration');
    }
}

# ------------------------------------------------------------
# Phase 82 Task 4/6 (Plan 05): _onPause/_onVolume/_bufferedSetVolume/
# _onSeek/_onPlaylistJump route Browse over Control; the H6 volume guard
# and the two Soloist finders are gone.
# ------------------------------------------------------------

# 84-07: re-pointed to the backend role and scoped to the _onPause sub
# (the old file-spanning `sub _onPause.*?...` patterns could match text in
# later subs). Browse/connect on Soloist reach Control through the role's
# control() (Backend::Soloist -> requestPause/requestResume, t/57).
{
    my ($op) = $connect =~ /(sub _onPause \{.*?\n\})\n/s;
    my $op_code = join("\n", grep { !/^\s*#/ } split /\n/, ($op // ''));
    like($op_code, qr/DaemonManager->backendFor\(\$client\)/,
        '_onPause obtains the backend role (backendFor) for the player');
    like($op_code, qr/\$isUnpause \? 'play' : 'pause'/,
        "_onPause maps unpause -> control('play'), pause/stop -> control('pause')");
    like($op_code, qr/backendFor\(\$client\).*?isSpotifyConnect/s,
        '_onPause consults the role before the Connect gate');
}

# 84-07 Task 2: re-pointed to the role (sub-scoped).
{
    my ($bv) = $connect =~ /(sub _bufferedSetVolume \{.*?\n\})\n/s;
    my $bv_code = join("\n", grep { !/^\s*#/ } split /\n/, ($bv // ''));
    like($bv_code, qr/->control\('set_volume', volume => int\(\$volume\)\)/,
        "_bufferedSetVolume sends control('set_volume', volume => int) through the role");
}

like($connect, qr/sub _onSeek.*?observer/s,
    '_onSeek documents itself as an observer in browse');
my ($on_seek_body) = $connect =~ /(sub _onSeek.*?)\nsub /s;
unlike($on_seek_body, qr/requestTrack|sendCommand/,
    '_onSeek never commands in browse');

unlike($connect, qr/\(H6\)|Dropping Connect volume event for non-Connect player/,
    'H6 guard removed (D-06)');

unlike($connect, qr/sub _soloistBrowseWs|sub _soloistConnectWs/,
    '_soloistBrowseWs/_soloistConnectWs finders are gone');

unlike($connect, qr/\b(?:sessionActive|sessionStarted|sessionPaused|deactivating|skipInitiated|pendingPlayConfirm|soloistBrowseActive)\b/,
    'Connect.pm carries none of the seven session flags');

# Gate 4: existing tests still pass (regression net) — covered by the
# assertions above and the unchanged tests below.

# ------------------------------------------------------------
# 83.1-02 Task 1 (D-D1): claim binding by the transfer class.
# ------------------------------------------------------------

like($connect, qr/sub bindConnectClaim\b/,
    "83.1-02: bindConnectClaim sub exists");
like($connect, qr/sub releaseConnectClaim\b/,
    "83.1-02: releaseConnectClaim sub exists");

# The 'start' branch must contain no UNCONDITIONAL claim write -- the write
# `$_activeConnectPlayer = $client->id;` sits ONLY inside the non-Soloist
# (librespot) branch of the isa-check, never unguarded at the top level.
my ($start_block_02) = $connect =~ /(if \(\$cmd eq 'start'\) \{.*?\n    \})/s;
ok($start_block_02, "83.1-02: 'start' branch block parseable");
if ($start_block_02) {
    like($start_block_02, qr/my \$startCaps = _liveCaps\(\$client\);\s*\n\s*if \(%\$startCaps && !\$startCaps->\{claimOnStart\}\) \{/,
        "83.1-02: 'start' branch resolves the running daemon's role and checks claimOnStart (84-08, D-D1)");
    like($start_block_02, qr/unclean source start/,
        "83.1-02: 'start' branch logs the D-D2 unclean-source case for a Soloist helper");
    # The literal write must appear strictly AFTER the isa-check's `else` --
    # i.e. it is not reachable for a Soloist helper.
    my ($non_soloist_start) = $start_block_02 =~ /(else \{.*?\n        \})/s;
    ok($non_soloist_start, "83.1-02: 'start' branch has a non-Soloist else arm");
    if ($non_soloist_start) {
        like($non_soloist_start, qr/\$_activeConnectPlayer = \$client->id/,
            "83.1-02: the claim write lives in the non-Soloist else arm");
    }
}

# getNextTrack's ProtocolHandler.pm release: the literal appears AFTER
# requestTrack(, guarded by mode ne 'connect'.
SKIP: {
    skip 'ProtocolHandler.pm not present', 2 unless $handler;

    # 84-08: the track request is control('track', source => 'getNextTrack')
    # on the backend role; the release still follows it in the core.
    my ($soloist_getnexttrack) = $handler =~ /(->control\('track', source => 'getNextTrack',.*?releaseConnectClaim.*?\n\s*return;)/s;
    ok($soloist_getnexttrack, "83.1-02: getNextTrack's requestTrack->releaseConnectClaim region parseable");
    if ($soloist_getnexttrack) {
        like($soloist_getnexttrack, qr/mode ne 'connect'/,
            "83.1-02: the Browse-entry release is guarded by mode ne 'connect'");
    }

    unlike($handler, qr/my \$wasConnect/,
        "83.1-02: the old pre-requestTrack wasConnect/_releaseConnectClaim block is gone");
}
like($connect, qr/last message wins/, "83.1-02: Connect.pm D-D2 conflict log text present");




# ------------------------------------------------------------
# 83.1-03 Task 2 (D-08): requestPause/requestResume/requestVolume routed
# through Control for BOTH modes; Connect.pm's _onPause/_bufferedSetVolume
# no longer gate the Control call on mode ne 'connect' -- the
# _sendControlCommand fallthrough is reached only when no Control exists
# (librespot).
# ------------------------------------------------------------

my ($on_pause_block_03) = $connect =~ /(sub _onPause \{.*?\nsub )/s;
ok($on_pause_block_03, "83.1-03: _onPause block parseable");
if ($on_pause_block_03) {
    unlike($on_pause_block_03, qr/mode ne 'connect'/,
        "83.1-03: _onPause no longer gates the Control call on mode ne 'connect'");

    # 84-07: the Control call and the HTTP fallthrough became ONE role call;
    # the librespot-only chain sits in the connectClaimGate block in front.
    my $op03_code = join("\n", grep { !/^\s*#/ } split /\n/, $on_pause_block_03);
    my $gateIdx = index($op03_code, 'if ($be->capabilities->{connectClaimGate}) {');
    my $callIdx = index($op03_code, "\$be->control(\$verb, isStop => \$isStop");
    ok($gateIdx >= 0, "84-07: _onPause gates the librespot-only chain on capabilities->{connectClaimGate}");
    ok($callIdx >= 0, "84-07: _onPause sends the command through \$be->control(\$verb, isStop => \$isStop, ...)");
    ok($gateIdx >= 0 && $callIdx >= 0 && $gateIdx < $callIdx,
        "84-07: the role call sits AFTER the connectClaimGate block (a Soloist player reaches it without the chain)");
    unlike($op03_code, qr/->request(?:Pause|Resume)\b|_sendControlCommand\(/,
        "84-07: no requestPause/requestResume call and no HTTP send left in _onPause");
    is(scalar(() = $op03_code =~ /->control\(/g), 1, '84-07: _onPause has exactly one control() call');
}

my ($buffered_vol_block_03) = $connect =~ /(sub _bufferedSetVolume \{.*?\n\})/s;
ok($buffered_vol_block_03, "83.1-03: _bufferedSetVolume block parseable");
if ($buffered_vol_block_03) {
    unlike($buffered_vol_block_03, qr/mode ne 'connect'/,
        "83.1-03: _bufferedSetVolume no longer gates the Control call on mode ne 'connect'");
}

# ------------------------------------------------------------
# 84.2-02 (CAUSE-2, D-08): an LMS playlist change in browse re-evaluates the
# prefetch. The subscription has its OWN coderef (LMS keys listeners by
# coderef, 84.1-08 CR-01) and is torn down in shutdown; the lookahead reads
# Playlist::track (Playlist::song is deprecated in LMS and logs a WARN per
# call, Pitfall 10).
# ------------------------------------------------------------

like($connect, qr/subscribe\(\\&_onLmsPlaylistChanged,\s*\[\['playlist'\],\s*\['add',\s*'insert',\s*'addtracks',\s*'inserttracks',\s*'move',\s*'delete',\s*'repeat',\s*'shuffle'\]\]\)/,
    "84.2-02: Connect.pm subscribes _onLmsPlaylistChanged to the playlist-change commands");
like($connect, qr/unsubscribe\(\\&_onLmsPlaylistChanged\)/,
    "84.2-02: Connect.pm unsubscribes _onLmsPlaylistChanged in shutdown");

# ------------------------------------------------------------
# 83.1-04 Task 1 (D-B1): connect seek runs through the restart chain
# (getSeekData -> onStream -> Control::requestTrack -> the connect seek row
# in _reconcilePlan's Seek-Pfad); the LMS-side ['time'] WS bypass for N > 0
# is gone from _onSeek. canDoAction's connect 'rew' block is KEPT (plan-04
# decision: restart-at-0 now routes through requestSkip('prev'), not
# through an LMS-side stream restart).
# ------------------------------------------------------------

my ($get_seek_data_block) = $handler =~ /(sub getSeekData \{.*?\n\})/s;
ok($get_seek_data_block, "83.1-04: getSeekData block parseable");
if ($get_seek_data_block) {
    unlike($get_seek_data_block, qr/^\s*return undef if Plugins::SpotOn::Connect->isSpotifyConnect/m,
        "79-28: getSeekData returns undef for connect only behind connectSeekViaControl (librespot /control/seek; Soloist keeps {timeOffset})");
    like($get_seek_data_block, qr/connectSeekViaControl/,
        "79-28: getSeekData names the capability connectSeekViaControl");
}

my ($can_do_action_block) = $handler =~ /(sub canDoAction \{.*?\n\})/s;
ok($can_do_action_block, "83.1-04: canDoAction block parseable");
if ($can_do_action_block) {
    like($can_do_action_block, qr/'rew' && Plugins::SpotOn::Connect->isSpotifyConnect/,
        "83.1-04: canDoAction keeps the connect 'rew' block (plan-04 decision)");
}

my ($on_seek_block_04) = $connect =~ /(sub _onSeek \{.*?\n\})/s;
ok($on_seek_block_04, "83.1-04: _onSeek block parseable");
if ($on_seek_block_04) {
    # Non-comment lines only (the same discipline as the shell verify gate's
    # own `grep -v '^\s*#'`) -- _onSeek's own doc comments legitimately NAME
    # _bufferedSeek/sub _bufferedSeek while explaining it is no longer
    # called from here.
    my $on_seek_code = join("\n", grep { !/^\s*#/ } split /\n/, $on_seek_block_04);
    unlike($on_seek_code, qr/_bufferedSeek/, "83.1-04: _onSeek no longer routes to _bufferedSeek");
    # 84-07 Task 2: ONE call form for every position; the 0 -> requestSkip('prev','time0')
    # mapping lives in Backend::Soloist (t/57), never a skip_prev from Connect.pm.
    like($on_seek_code, qr/->control\('seek', position_ms => int\(\$position \* 1000\)\)/,
        "84-07: _onSeek sends control('seek', position_ms => int(\$position * 1000))");
    unlike($on_seek_code, qr/skip_prev|requestSkip/,
        "84-07: _onSeek never calls skip_prev / requestSkip itself");
}

# ------------------------------------------------------------
# 83.1-04 Task 2 (D-B2/D-B4): _onPlaylistJump routes both directions
# through Control::requestSkip; the D-B4 available_actions precondition is
# implemented in Control.pm.
# ------------------------------------------------------------

my ($on_jump_block_04) = $connect =~ /(sub _onPlaylistJump \{.*?\n\})/s;
ok($on_jump_block_04, "83.1-04: _onPlaylistJump block parseable");
if ($on_jump_block_04) {
    my $on_jump_code = join("\n", grep { !/^\s*#/ } split /\n/, $on_jump_block_04);
    # 84-07 Task 2: both backends through the role.
    is(scalar(() = $on_jump_code =~ /->control\('skip_next'/g), 1,
        "84-07: _onPlaylistJump routes +1 through control('skip_next' exactly once");
    is(scalar(() = $on_jump_code =~ /->control\('skip_prev'/g), 1,
        "84-07: _onPlaylistJump has exactly one control('skip_prev' call site (jump -1 and the jump +0 fallback)");
    like($on_jump_code, qr/my \$gate = \$be->capabilities->\{connectClaimGate\};.*?if \(\$gate\) \{.*?connectPauseTs/s,
        "84-07: the librespot connectPauseTs write sits behind capabilities->{connectClaimGate}");
    unlike($on_jump_code, qr/_sendControlCommand\(|->request(?:Skip|Restart)\b/,
        "84-07: no HTTP send and no request* call left in _onPlaylistJump");
}

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
    sub capabilities { return { connectClaimGate => $_[0]->{gate}, connectSeekViaControl => ($_[0]->{seekcap} // 0) }; }
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

    # 79-28 D-23: the librespot connect seek debounce records its timers.
    package Slim::Utils::Timers;
    our (@SET, @KILL);
    sub killTimers { push @KILL, [@_]; }
    sub setTimer   { push @SET,  [@_]; }

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
for my $name (qw(_onPause _onLmsStop _bufferedSetVolume _onSeek _forwardLibrespotSeek _onPlaylistJump)) {
    ($role_src{$name}) = $connect =~ /(sub \Q$name\E \{.*?\n\})\n/s;
}
my $role_compiled = !grep { !defined } values %role_src;
$role_compiled &&= eval(
    "package Test::RoleHarness;\n"
    . "use strict; use warnings; use Time::HiRes;\n"
    . "use constant CONNECT_START_GRACE => 12;\n"
    . "use constant VOLUME_DEBOUNCE => 0.5;\n"
    . "use constant SEEK_DEBOUNCE => 0.3;\n"
    . "our \$SPOTIFY_CONNECT = 0;\n"
    . "my \$log   = Test::RoleLog->new;\n"
    . "my \$prefs = Test::RolePrefs->new;\n"
    . "my \$_activeConnectPlayer;\n"
    . "sub isSpotifyConnect { return \$SPOTIFY_CONNECT; }\n"
    . "sub _holdCancel { return; }\n"
    . "sub _isDeadHistoryUrl { return 0; }\n"
    . "sub _seekPositionFromRequest { return \$_[1]->getParam('_newvalue'); }\n"
    # a leftover direct HTTP send (the pre-84-07 route) counts as a POST
    . "sub _sendControlCommand { \$Slim::Networking::SimpleAsyncHTTP::NEW++; return; }\n"
    . join("\n", map { $role_src{$_} } sort keys %role_src) . "\n1;"
);
ok($role_compiled, "84-07: the real _onPause/_onLmsStop/_bufferedSetVolume/_onSeek/_forwardLibrespotSeek/_onPlaylistJump compile in the role harness")
    or diag($@);

my $MAC37 = '02:00:00:5a:11:01';
sub role_reset {
    @Test::RoleLog::INFO = ();
    $Slim::Control::Request::NEW = 0;
    $Slim::Networking::SimpleAsyncHTTP::NEW = 0;
    $Plugins::SpotOn::API::Client::CALLS = 0;
    $Test::RoleHarness::SPOTIFY_CONNECT = 0;
    @Slim::Utils::Timers::SET = ();
    @Slim::Utils::Timers::KILL = ();
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

my $jump_compiled = $role_compiled;
my $jump_run = sub {
    my ($role, $index) = @_;
    role_run($role, '_onPlaylistJump', params => { _index => $index });
    return $role->{calls};
};

if ($jump_compiled) {
    # jump +0, restart route available -> restart only, NO skip_prev.
    is_deeply($jump_run->(Test::RoleMock->new(), '+0'),
        [ [ 'restart', { reason => 'jump+0' } ] ],
        "1B: connect jump +0 -> control('restart', reason => 'jump+0') and no skip_prev (LMS decides: from the start)");

    # jump +0, restart declined (paused / not seekable / other title) -> the old skip_prev route.
    is_deeply($jump_run->(Test::RoleMock->new(outcome => { restart => 'declined' }), '+0'),
        [ [ 'restart', { reason => 'jump+0' } ], [ 'skip_prev', { reason => 'jump+0' } ] ],
        "1B: connect jump +0 with restart declined -> falls back to control('skip_prev', reason => 'jump+0')");

    # jump -1 -> skip_prev only, restart never asked.
    is_deeply($jump_run->(Test::RoleMock->new(), '-1'),
        [ [ 'skip_prev', { reason => 'jump-1' } ] ],
        "1B: connect jump -1 -> control('skip_prev', reason => 'jump-1') only (a real previous goes to Spotify)");

    # jump +1 -> skip_next only (unchanged).
    is_deeply($jump_run->(Test::RoleMock->new(), '+1'),
        [ [ 'skip_next', { reason => 'jump+1' } ] ],
        "1B: connect jump +1 -> control('skip_next', reason => 'jump+1') only (unchanged)");

    # browse: no role call at all (unchanged).
    is_deeply($jump_run->(Test::RoleMock->new(mode => 'browse'), '+0'),
        [],
        "1B: browse jump +0 -> no control() call (browse code unchanged)");
}

if ($on_jump_block_04) {
    my $on_jump_code = join("\n", grep { !/^\s*#/ } split /\n/, $on_jump_block_04);
    is(scalar(() = $on_jump_code =~ /->control\('restart', reason => 'jump\+0'\)/g), 1,
        "1B/84-07: _onPlaylistJump asks control('restart', reason => 'jump+0') exactly once");
}
if ($can_do_action_block) {
    like($can_do_action_block, qr/query\('consumeRestartAllowance', url => \$url\)/,
        "1B: canDoAction's connect 'rew' block lets a Control restart allowance through (84-08: via the role's query)");
}

# ------------------------------------------------------------
# 83.1-06 Task 2 (D-C1 code walk): the connect advance path chain after
# plans 02/03's claim-binding and _onPause-bypass changes. No guard, no
# dispatch and no resume-rescue literal was removed (D-C1 ordering: plan 07
# removes guards, not this plan) -- and the walk's four-suppression table
# (_onPause's connectPauseTs echo, connectStartTime grace, player-switch
# guard, dead-history guard, all documented at Connect.pm's own comment
# above the `if ($ctl) { ... }` bypass) is each covered by a named Control
# primitive, verified here by literal presence.
# ------------------------------------------------------------
like($connect, qr/Dropping Connect change event for non-Connect player/,
    '83.1-06: the connect-guard drop literal is still present (not removed -- D-C1 ordering)');
like($connect, qr/Track change: /,
    '83.1-06: the D-04 dispatch line (`Track change: `) is present, past the guard');
like($connect, qr/Resume while not on Connect stream/,
    '83.1-06: the resume re-entry literal is still present (the accidental rescue path stays until plan 07)');

my ($change_block) = $connect =~ /(if \(\$cmd eq 'change'\) \{.*?\n    \})/s;
ok($change_block, '83.1-06: the change-handler block is parseable');
if ($change_block) {
    my $change_code = join("\n", grep { !/^\s*#/ } split /\n/, $change_block);
    like($change_code, qr/'playlist',\s*'play'/,
        "83.1-06: the change handler's D-04 dispatch block still sends 'playlist play' after the guard passes");
}

# ------------------------------------------------------------
# 83.1-07 Task 1 (ROADMAP Task 6): the Soloist WS branch of
# _sendControlCommand and _bufferedSeek are gone -- only the librespot HTTP
# path remains, reached only when no Control instance exists for the
# player.
# ------------------------------------------------------------
# 84-07 Task 2: the sender moved to Backend/Librespot.pm; Connect.pm has none left.
unlike($connect, qr/^sub _sendControl(?:Command|Fallback)\b/m,
    '84-07: Connect.pm no longer defines _sendControlCommand / _sendControlFallback');
unlike($connect, qr/^sub _bufferedSeek/m,
    "79-28: the GH 129 helper name stays deleted; the librespot connect seek goes through _forwardLibrespotSeek -> control('seek')");
unlike($connect, qr/_bufferedSeek/,
    '79-28: no remaining reference to the deleted GH 129 helper name anywhere in Connect.pm');
like($connect, qr/^sub _forwardLibrespotSeek/m,
    "79-28: Connect.pm defines _forwardLibrespotSeek (the debounced librespot connect seek forward)");

# ------------------------------------------------------------
# 83.1-07 Task 2 Group C (EIGENTUMSFRAGE point 3): the change/seek guards
# in _connectEvent are sharpened (claim AND Control mode), never removed;
# the resume re-entry stays.
# ------------------------------------------------------------
like($connect, qr/if \(defined \$ctlMode->\(\) && \$ctlMode->\(\) ne 'connect'\) \{/,
    "83.1-07: the sharpened guard checks Control's mode (84-08: through the role's state)");
like($connect, qr/Connect claim vs Control mode disagree/,
    '83.1-07: the D-D2 disagree warn literal is present');
my @disagree_sites = $connect =~ /(Connect claim vs Control mode disagree)/g;
cmp_ok(scalar(@disagree_sites), '>=', 2,
    '83.1-07: the disagree warn appears at both the seek and the change guard');
like($connect, qr/Resume while not on Connect stream/,
    '83.1-07: the resume re-entry literal is still present (EIGENTUMSFRAGE point 3: stays)');

# ------------------------------------------------------------
# 84.1-02 Task 1 (D-01(b)): a bare `stop` on an already-stopped player, and
# a `playlist clear`, are notified even when StreamingController takes no
# real transition (no `playlist stop`) -- the notification-independent-of-
# state trigger D-01(b) needs. _onLmsStop mirrors _onPause's shape (source
# skip, mode guard) but only ever calls requestPause(1), never resume.
# ------------------------------------------------------------
like($connect, qr/subscribe\(\\&_onLmsStop, \[\['stop'\]\]\)/,
    "84.1-02: subscribes _onLmsStop to a bare ['stop']");
like($connect, qr/subscribe\(\\&_onLmsClear, \[\['playlist'\], \['clear'\]\]\)/,
    "84.1-02/84.1-08 CR-01: subscribes _onLmsClear to ['playlist'],['clear']");

my ($on_lms_stop_block) = $connect =~ /(sub _onLmsStop \{.*?\n\})/s;
ok($on_lms_stop_block, '84.1-02: _onLmsStop block parseable');
if ($on_lms_stop_block) {
    like($on_lms_stop_block, qr/source eq __PACKAGE__/,
        '84.1-02: _onLmsStop skips its own source-marked requests (loop prevention)');
    like($on_lms_stop_block, qr/\{mode\} eq 'browse'/,
        "84.1-02: _onLmsStop only acts while the backend is in browse mode (D-01 clarification: connect stays a session pause)");
    like($on_lms_stop_block, qr/->control\('pause', isStop => 1/,
        "84.1-02/84-07: _onLmsStop calls control('pause', isStop => 1)");
    unlike($on_lms_stop_block, qr/requestResume/,
        '84.1-02: _onLmsStop never calls requestResume');
}

# ------------------------------------------------------------
# 84.1-07 (D-02): source gates for the leave path -- placement before
# CON-17, the exact guard text, the GH #151 discard, leaveConnect's own
# order and no-dispatch shape, the T-84.1-29 re-adoption guard on the
# reconnect `if`, and the marker's clear points (revision 2). These pin
# source shape; Task 2's mutation proofs (t/44/t/41 behaviour) are the
# can-fail evidence for what a source grep alone cannot catch.
# ------------------------------------------------------------

my ($on_new_song) = $connect =~ /(sub _onNewSong \{.*?\n\})/s;
ok($on_new_song, '84.1-07 G1: _onNewSong block parseable');

if ($on_new_song) {
    like($on_new_song, qr/notify\('leaveConnect', reason => 'foreign-lms-content'\)/,
        "84.1-07 G2: _onNewSong calls leaveConnect('foreign-lms-content') (84-08: notify on the role)");

    my $guard_text = q{($mode->() // '') eq 'connect' && $url =~ /\S/ && $url !~ m{^spoton://}};
    ok((index($on_new_song, $guard_text) >= 0),
        "84.1-07 G3: the exact D-02 guard text is present");

    # G4: 'CON-17' also appears earlier in this region, inside the
    # pre-existing D-16 doc comment ("Shared by WR-06, CON-17, ...") --
    # match the early-return block's OWN header, not the bare substring,
    # so a stray comment mention can never satisfy this gate.
    my $leave_idx = index($on_new_song, "notify('leaveConnect', reason => 'foreign-lms-content')");
    my $con17_idx = index($on_new_song, '# CON-17: Apply stored progress');
    ok(($leave_idx >= 0 && $con17_idx >= 0 && $leave_idx < $con17_idx),
        "84.1-07 G4: leaveConnect runs BEFORE the CON-17 early-return block "
        . "(which returns early while mode is connect -- why D-16 never fired pre-fix)");

    my $discard_idx = index($on_new_song, 'connectPrevPower => undef');
    ok(($discard_idx >= 0 && $leave_idx >= 0 && $con17_idx >= 0
            && $discard_idx > $leave_idx && $discard_idx < $con17_idx),
        "84.1-07 G5: the GH #151 discard (connectPrevPower => undef) sits between the leaveConnect call and CON-17");
}



# G8 (revision 2, marker lifetime): the marker never outlives its
# post-leave episode -- same-line clears at requestTrack and the
# transfer-in, plus the explicit endForeignLeave clear point for an LMS
# stop / playlist clear.

my ($on_lms_stop_d02_block) = $connect =~ /(sub _onLmsStop \{.*?\n\})/s;
ok($on_lms_stop_d02_block, '84.1-07 G8: Connect.pm _onLmsStop block parseable');
if ($on_lms_stop_d02_block) {
    my $end_idx    = index($on_lms_stop_d02_block, "notify('endForeignLeave', reason => 'lms-stop')");
    my $browse_idx = index($on_lms_stop_d02_block, "{mode} eq 'browse'");
    ok(($end_idx >= 0 && $browse_idx >= 0 && $end_idx < $browse_idx),
        "84.1-07 G8: endForeignLeave runs before the browse-only check in _onLmsStop");
}

# ------------------------------------------------------------
# 84.1-08 (CR-01): a distinct coderef for the playlist-clear subscription,
# so LMS's coderef-keyed %listeners (Request.pm:797) keeps both entries
# instead of the second silently replacing the first.
# ------------------------------------------------------------
my ($on_lms_clear_block) = $connect =~ /(sub _onLmsClear \{.*?\n\})/s;
ok($on_lms_clear_block, '84.1-08 C1: _onLmsClear block parseable');
if ($on_lms_clear_block) {
    ok((index($on_lms_clear_block, '_onLmsStop(') >= 0), "84.1-08 C1: _onLmsClear calls _onLmsStop(");
    ok((index($on_lms_clear_block, q{'playlist clear'}) >= 0), "84.1-08 C1: _onLmsClear passes 'playlist clear'");
}

my ($shutdown_block_c2) = $connect =~ /(sub shutdown \{.*?\n\})/s;
ok($shutdown_block_c2, '84.1-08 C2: shutdown block parseable');
if ($shutdown_block_c2) {
    ok((index($shutdown_block_c2, q{unsubscribe(\&_onLmsStop)}) >= 0), "84.1-08 C2: shutdown unsubscribes _onLmsStop");
    ok((index($shutdown_block_c2, q{unsubscribe(\&_onLmsClear)}) >= 0), "84.1-08 C2: shutdown unsubscribes _onLmsClear");
}

my ($init_block_c3) = $connect =~ /(sub initConnectHandlers \{.*?\n\})/s;
ok($init_block_c3, '84.1-08 C3: initConnectHandlers block parseable');
if ($init_block_c3) {
    my @coderef_names = $init_block_c3 =~ /subscribe\(\\&([A-Za-z_]+)/g;
    my %seen;
    my @dupes = grep { $seen{$_}++ } @coderef_names;
    is(scalar(@dupes), 0, "84.1-08 C3: no duplicate coderef in initConnectHandlers subscriptions (found: @dupes)");
}

my ($on_lms_stop_block_c4) = $connect =~ /(sub _onLmsStop \{.*?\n\})/s;
ok($on_lms_stop_block_c4, '84.1-08 C4: _onLmsStop block parseable');
if ($on_lms_stop_block_c4) {
    ok((index($on_lms_stop_block_c4, 'notification -- mode=') >= 0), "84.1-08 C4: _onLmsStop logs 'notification -- mode='");
    ok((index($on_lms_stop_block_c4, q{$cmd //= 'stop';}) >= 0), "84.1-08 C4: _onLmsStop defaults its command label to 'stop'");
}

# G10: WR-02's discriminator placement and its no-clock/weak-reference
# shape.
my ($on_new_song_g10) = $connect =~ /(sub _onNewSong \{.*?\n\})/s;
ok($on_new_song_g10, '84.1-08 G10: _onNewSong block parseable');
if ($on_new_song_g10) {
    my $guard_idx = index($on_new_song_g10, q{($mode->() // '') eq 'connect' && $url =~ /\S/ && $url !~ m{^spoton://}});
    my $entry_idx = index($on_new_song_g10, '_isConnectEntrySong(');
    my $leave_idx = index($on_new_song_g10, "notify('leaveConnect', reason => 'foreign-lms-content')");
    ok(($guard_idx >= 0 && $entry_idx >= 0 && $leave_idx >= 0 && $entry_idx > $guard_idx && $entry_idx < $leave_idx),
        "84.1-08 G10: _isConnectEntrySong( appears after the D-02 guard text and before leaveConnect('foreign-lms-content')");
}

my ($entry_song_block) = $connect =~ /(sub _isConnectEntrySong \{.*?\n\})/s;
ok($entry_song_block, '84.1-08 G10: _isConnectEntrySong block parseable');
if ($entry_song_block) {
    unlike($entry_song_block, qr/Time::HiRes|time\(\)/,
        "84.1-08 G10: _isConnectEntrySong reads no clock (Pitfall 4 -- identity, never a time window)");
}

my ($bind_claim_block) = $connect =~ /(sub bindConnectClaim \{.*?\n\})/s;
ok($bind_claim_block, '84.1-08 G10: bindConnectClaim block parseable');
if ($bind_claim_block) {
    like($bind_claim_block, qr/playingSong/, "84.1-08 G10: bindConnectClaim reads playingSong");
    like($bind_claim_block, qr/weaken\(/, "84.1-08 G10: bindConnectClaim stores the entry song weakly");
}

# G11: the IN-04 no-WS-connection notice sits before the deactivate probe,
# and the existing G6 forbidden-token assertion stays green.

# ------------------------------------------------------------
# 84-02 (cluster 4, D-21): startOffset arithmetic must never use the OLD
# stream's elapsed on a per-track Soloist entry. The behavioural cases C4-a,
# C4-a2, C4-b, C4-c, C4-l drive the real handlers in t/41 (the harness lives
# there); these are the source-level nets that keep the three startOffset
# writers on the one helper and keep both Soloist dispatch sites marking the
# stream dispatch time the helper measures against.
# ------------------------------------------------------------

like($connect, qr/use constant STREAM_ELAPSED_SLACK\s*=>/,
    '84-02 C4: STREAM_ELAPSED_SLACK constant defined (the named window for a plausible stream elapsed)');

my ($elapsed_helper) = $connect =~ /(sub _streamElapsedSeconds \{.*?\n\})/s;
ok($elapsed_helper, '84-02 C4: _streamElapsedSeconds helper block parseable');
if ($elapsed_helper) {
    like($elapsed_helper, qr/connectStreamDispatchTs/,
        '84-02 C4: the helper measures against the Soloist stream dispatch time');
    like($elapsed_helper, qr/songElapsedSeconds/,
        '84-02 C4: the helper wraps the player elapsed read');
}

my @startoffset_writers = $connect =~ /my \$elapsed = _streamElapsedSeconds\(\$client\);\s*\n\s*\$song->startOffset\(/g;
cmp_ok(scalar(@startoffset_writers), '>=', 3,
    '84-02 C4: seek, resume and the CON-17 progress path compute startOffset through _streamElapsedSeconds');

my @dispatch_marks = $connect =~ /pluginData\(connectStreamDispatchTs => Time::HiRes::time\(\)\)/g;
cmp_ok(scalar(@dispatch_marks), '>=', 3,
    '84-02 C4: all three Soloist dispatch sites (start, change, resume re-entry) mark the stream dispatch time before playlist play');

# the change handler's own startOffset write stays on the OLD song with the raw elapsed (unchanged)
like($connect, qr/\$song->startOffset\(0 - \$elapsed\);/,
    '84-02 C4: the change handler still resets the old song via startOffset(0 - elapsed) (unchanged)');

# the start handler reads the transfer-in position (Control passes it as _p3)
like($connect, qr/my \$startPosition\s*=\s*\$request->getParam\('_p3'\)/,
    '84-02 C4-c: the start handler reads the transfer-in position parameter (_p3) into $startPosition');


# ------------------------------------------------------------
# 84-07 Task 2: every transport command reaches its daemon through the
# backend role -- runtime cells over the REAL handlers (role harness above).
# ------------------------------------------------------------
if ($role_compiled) {
    # --- librespot-shaped role (connectClaimGate 1; restart unsupported) ---
    role_reset();
    my $ls = Test::RoleMock->new(mode => undef, gate => 1, outcome => { restart => 'unsupported' });
    $Test::RoleHarness::SPOTIFY_CONNECT = 1;
    my $lc = Test::JumpClient->new($MAC37);
    role_run($ls, '_onPlaylistJump', client => $lc, params => { _index => '+0' });
    is_deeply($ls->{calls}, [ [ 'restart', { reason => 'jump+0' } ], [ 'skip_prev', { reason => 'jump+0' } ] ],
        "84-07: librespot jump +0 -> restart (unsupported) -> skip_prev (today's /control/prev)");
    ok(defined $lc->pluginData('connectPauseTs') && Time::HiRes::time() - $lc->pluginData('connectPauseTs') < 2,
        '84-07: librespot jump stamps connectPauseTs (echo suppression kept behind connectClaimGate)');
    role_reset();
    my $ls2 = Test::RoleMock->new(mode => undef, gate => 1);
    my $lc2 = Test::JumpClient->new($MAC37);
    role_run($ls2, '_onPlaylistJump', client => $lc2, params => { _index => '+1' });
    is_deeply($ls2->{calls}, [], '84-07: librespot jump without a Connect claim -> isSpotifyConnect gate returns early, no control()');
    ok(!defined $lc2->pluginData('connectPauseTs'), '84-07: ... and no connectPauseTs write');

    # --- _onLmsStop ---
    for my $pm ('stop', 'play') {
        role_reset();
        local $Slim::Player::Source::PLAYMODE = $pm;
        my $r = role_run(Test::RoleMock->new(mode => 'browse'), '_onLmsStop');
        is_deeply($r->{calls}, [ [ 'pause', { isStop => 1, source => 'lms_stop' } ] ],
            "84-07: _onLmsStop in browse (playmode $pm) -> control('pause', isStop => 1, source => 'lms_stop')");
        is_deeply($r->{notes}, $pm eq 'play' ? [] : [ [ 'endForeignLeave', { reason => 'lms-stop' } ] ],
            "84-07: _onLmsStop in browse (playmode $pm) -> notify('endForeignLeave') only when playmode ne play");
    }
    {
        role_reset();
        local $Slim::Player::Source::PLAYMODE = 'stop';
        my $r = role_run(Test::RoleMock->new(mode => 'connect'), '_onLmsStop');
        is_deeply($r->{calls}, [], "84-07 NEGATIVE: _onLmsStop in connect -> NO control('pause') (browse-only rule kept)");
        is_deeply($r->{notes}, [ [ 'endForeignLeave', { reason => 'lms-stop' } ] ],
            "84-07: _onLmsStop in connect, playmode stop -> notify('endForeignLeave') still fires");
        role_reset();
        my $u = role_run(Test::RoleMock->new(mode => undef, gate => 1), '_onLmsStop');
        is_deeply([ $u->{calls}, $u->{notes} ], [ [], [] ], '84-07: _onLmsStop with mode undef (librespot shape) -> nothing');
    }

    # --- _onSeek ---
    {
        role_reset();
        my $r = role_run(Test::RoleMock->new(mode => 'connect'), '_onSeek', params => { _newvalue => 0 });
        is_deeply($r->{calls}, [ [ 'seek', { position_ms => 0 } ] ], "84-07: _onSeek connect time 0 -> control('seek', position_ms => 0)");
        role_reset();
        $r = role_run(Test::RoleMock->new(mode => 'connect'), '_onSeek', params => { _newvalue => 12.5 });
        is_deeply($r->{calls}, [ [ 'seek', { position_ms => 12500 } ] ], "84-07: _onSeek connect time 12.5 -> control('seek', position_ms => 12500)");
        ok(!grep({ $_->[0] eq 'skip_prev' } @{ $r->{calls} }), '84-07: _onSeek never calls skip_prev (the role maps 0)');
        role_reset();
        $r = role_run(Test::RoleMock->new(mode => 'browse', wanted => 4200), '_onSeek', params => { _newvalue => 3 });
        is_deeply($r->{calls}, [], '84-07: _onSeek in browse -> observer only, no control()');
        is_deeply($r->{queries}, ['wantedPositionMs'], "84-07: _onSeek in browse reads query('wantedPositionMs') for its observer line");
        role_reset();
        $Test::RoleHarness::SPOTIFY_CONNECT = 1;
        $r = role_run(Test::RoleMock->new(mode => undef, gate => 1), '_onSeek', params => { _newvalue => 5 });
        is_deeply($r->{calls}, [], '79-28 D-23 seek: _onSeek on librespot without connectSeekViaControl -> no control() (gate 1, capability 0)');
        is(scalar(@Slim::Utils::Timers::SET), 0, '79-28 D-23 seek: gate 1 without the capability arms no debounce timer');
        role_reset();
        $Test::RoleHarness::SPOTIFY_CONNECT = 1;
        my $cap = Test::RoleMock->new(mode => undef, gate => 1, seekcap => 1);
        $r = role_run($cap, '_onSeek', params => { _newvalue => 5 });
        is(scalar(@Slim::Utils::Timers::SET), 1, '79-28 D-23 seek: gate 1 with connectSeekViaControl arms one debounce timer');
        is_deeply($r->{calls}, [], '79-28 D-23 seek: nothing is sent before the debounce timer fires');
        my $tm = $Slim::Utils::Timers::SET[0];
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $cap;
        $tm->[2]->($tm->[0], $tm->[3]);
        is_deeply($cap->{calls}, [ [ 'seek', { position_ms => 5000 } ] ],
            "79-28 D-23 seek: firing the timer calls control('seek', position_ms => 5000)");
        role_reset();
        $r = role_run(Test::RoleMock->new(mode => undef, gate => 1, seekcap => 1), '_onSeek', params => { _newvalue => 5 });
        is(scalar(@Slim::Utils::Timers::SET), 0, '79-28 D-23 seek: a player without the Connect claim arms no timer');
    }

    # --- _bufferedSetVolume ---
    {
        role_reset();
        my $r = Test::RoleMock->new(mode => 'browse');
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $r;
        Test::RoleHarness::_bufferedSetVolume(Test::JumpClient->new($MAC37), 55.7);
        is_deeply($r->{calls}, [ [ 'set_volume', { volume => 55 } ] ], "84-07: _bufferedSetVolume -> control('set_volume', volume => 55)");
    }

    # --- Soloist WITHOUT a Control instance (84-07 decision, user 2026-10-11:
    #     log "down", no fallthrough into the librespot HTTP/Web-API path) ---
    {
        role_reset();
        $Test::RoleHarness::SPOTIFY_CONNECT = 1;    # a stale claim exists
        my $r = role_run(Test::RoleMock->new(mode => undef, gate => 0, outcome => { pause => 'down' }),
                         '_onPause', cmd => ['playlist', 'pause'], params => { _newvalue => 1 });
        is_deeply(verbs($r), ['pause'], "84-07 NEGATIVE: Soloist without Control: _onPause -> exactly one control('pause')");
        is($Slim::Networking::SimpleAsyncHTTP::NEW, 0, '84-07 NEGATIVE: ... no HTTP POST');
        is($Plugins::SpotOn::API::Client::CALLS, 0, '84-07 NEGATIVE: ... no Web API fallback');
        is($Slim::Control::Request::NEW, 0, '84-07 NEGATIVE: ... no LMS stop request');
        is(scalar(grep { /control\(pause\) -> down/ } @Test::RoleLog::INFO), 1, "84-07 NEGATIVE: ... one info line with the verb and 'down'");
    }
    for my $case ([ '_onSeek', { _newvalue => 0 } ], [ '_onSeek', { _newvalue => 30 } ],
                  [ '_onPlaylistJump', { _index => '+1' } ], [ '_onPlaylistJump', { _index => '+0' } ],
                  [ '_onPlaylistJump', { _index => '-1' } ]) {
        my ($h, $params) = @$case;
        my $label = "$h(" . join(',', %$params) . ')';
        role_reset();
        $Test::RoleHarness::SPOTIFY_CONNECT = 1;
        my $r = role_run(Test::RoleMock->new(mode => undef, gate => 0, outcome => { map { $_ => 'down' } qw(seek skip_next skip_prev restart) }),
                         $h, params => $params);
        is_deeply($r->{calls}, [], "84-07 NEGATIVE: Soloist without Control: $label -> NO control() call");
        is($Slim::Networking::SimpleAsyncHTTP::NEW + $Plugins::SpotOn::API::Client::CALLS + $Slim::Control::Request::NEW, 0,
            "84-07 NEGATIVE: Soloist without Control: $label -> no POST, no fallback, no stop");
        is(scalar(grep { /-> down/ } @Test::RoleLog::INFO), 0, "84-07 NEGATIVE: Soloist without Control: $label -> no 'down' info line");
    }
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
for my $name (qw(_liveCaps _playUrlFor bindConnectClaim _onLmsPlaylistChanged _holdCaps _holdCap _holdRecheck _holdMax _holdClose)) {
    ($src3{$name}) = $connect =~ /(sub \Q$name\E \{.*?\n\})\n/s;
    ($src3{$name}) = $connect =~ /^(sub \Q$name\E .*?\})$/m unless $src3{$name};
}
my ($hang_src) = slurp("$project_dir/Plugins/SpotOn/Plugin.pm") =~ /(sub _prefetchHangCheck \{.*?\n\})\n/s;
$src3{_prefetchHangCheck} = $hang_src;
my @missing3 = grep { !defined $src3{$_} } sort keys %src3;
ok(!@missing3, '84-08: Task 3 handler sources extracted') or diag("missing: @missing3");
my $h3 = !@missing3 && eval(
    "package Test::RoleHarness3;\n"
    . "use strict; use warnings; use Time::HiRes; use Scalar::Util qw(weaken);\n"
    . "my \$log = Test::RoleLog3->new;\n"
    . "my (\$_activeConnectPlayer, \$_lastBindAt, %_connectEntrySong, %_hold, %_watchdogTriggerUrl);\n"
    . "sub setActive  { \$_activeConnectPlayer = \$_[0]; }\n"
    . "sub getActive  { return \$_activeConnectPlayer; }\n"
    . "sub setHold    { \$_hold{ \$_[0] } = \$_[1]; }\n"
    . "sub setTrigger { \$_watchdogTriggerUrl{ \$_[0] } = \$_[1]; }\n"
    . join("\n", map { $src3{$_} } sort keys %src3) . "\n1;"
);
ok($h3, '84-08: the real Task 3 handlers compile in the role harness') or diag($@);

if ($h3) {
    my $DM = 'Plugins::SpotOn::Unified::DaemonManager';

    # --- _playUrlFor / _liveCaps on capabilities->{connectEntry} ---
    {
        local $Plugins::SpotOn::Unified::DaemonManager::HELPER = 1;
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(caps => { connectEntry => 'pertrack' });
        my $c = Test::Client3->new('aa:00:00:00:00:01');
        is(Test::RoleHarness3::_playUrlFor($c, 'abc123'), 'spoton://track:abc123', "84-08 _playUrlFor: connectEntry pertrack + track id -> spoton://track:<id>");
        like(Test::RoleHarness3::_playUrlFor($c, ''), qr/^spoton:\/\/connect-\d+$/, '84-08 _playUrlFor: pertrack without a track id -> spoton://connect-<ms>');
        $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(caps => { connectEntry => 'repeating' });
        like(Test::RoleHarness3::_playUrlFor($c, 'abc123'), qr/^spoton:\/\/connect-\d+$/, '84-08 _playUrlFor: connectEntry repeating -> spoton://connect-<ms>');
        $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(caps => { connectEntry => 'pertrack' });
        $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
        like(Test::RoleHarness3::_playUrlFor($c, 'abc123'), qr/^spoton:\/\/connect-\d+$/, '84-08 _playUrlFor: no running daemon -> the generic connect-<ms> path (as before)');
        is_deeply(Test::RoleHarness3::_liveCaps($c), {}, '84-08 _liveCaps: no running daemon -> {}');
    }

    # --- bindConnectClaim: the claim-conflict truth table on the OLD role ---
    for my $case (
        [ 'connect + active 1 (unclean)', { mode => 'connect', active => 1 }, 1 ],
        [ 'connect + active 0 (clean)',   { mode => 'connect', active => 0 }, 0 ],
        [ 'librespot shape (mode undef)', { mode => undef,     active => undef }, 0 ],
        [ 'browse + active 1 (clean)',    { mode => 'browse',  active => 1 }, 0 ],
    ) {
        my ($label, $st, $unclean) = @$case;
        my $old = Test::Client3->new('aa:00:00:00:00:0a');
        my $new = Test::Client3->new('aa:00:00:00:00:0b');
        local %Slim::Player::Client::BY_ID = ($old->id => $old);
        my $oldRole = Test::RoleMock3->new(st => $st);
        my $newRole = Test::RoleMock3->new(st => { mode => 'connect', active => 1 });
        local %Plugins::SpotOn::Unified::DaemonManager::ROLES = ($old->id => $oldRole, $new->id => $newRole);
        @Test::RoleLog3::WARN = ();
        Test::RoleHarness3::setActive($old->id);
        Test::RoleHarness3::bindConnectClaim('Plugins::SpotOn::Connect', $new, 'transfer');
        my @ev = map { $_->[0] } @{ $oldRole->{notes} };
        if ($unclean) {
            is_deeply(\@ev, [ 'recordErrorOnce', 'claimLost' ], "84-08 bindConnectClaim $label: recordErrorOnce + claimLost on the OLD role");
            is($oldRole->{notes}[0][1]{key}, 'claim-conflict:' . $old->id, "84-08 bindConnectClaim $label: errors[] key claim-conflict:<old>");
            is($oldRole->{notes}[1][1]{reason}, 'last-message-wins', "84-08 bindConnectClaim $label: claimLost reason last-message-wins");
            is(scalar(grep { /still reports an active session/ } @Test::RoleLog3::WARN), 1, "84-08 bindConnectClaim $label: one warn");
        }
        else {
            is_deeply(\@ev, [], "84-08 bindConnectClaim $label: nothing recorded on the old role (clean path)");
            is(scalar(@Test::RoleLog3::WARN), 0, "84-08 bindConnectClaim $label: no warn");
        }
        is_deeply($newRole->{notes}, [], "84-08 bindConnectClaim $label: the NEW role is never notified");
        is(Test::RoleHarness3::getActive(), $new->id, "84-08 bindConnectClaim $label: the claim moves to the new player");
    }

    # --- _onLmsPlaylistChanged: notify only in browse ---
    for my $case ([ 'browse', 1 ], [ 'connect', 0 ], [ undef, 0 ]) {
        my ($mode, $want) = @$case;
        my $c = Test::Client3->new('aa:00:00:00:00:0c');
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(st => { mode => $mode });
        Test::RoleHarness3::_onLmsPlaylistChanged(Test::JumpRequest->new(client => $c, source => 'x'));
        is(scalar(grep { $_->[0] eq 'notePlaylistChanged' } @{ $Plugins::SpotOn::Unified::DaemonManager::ROLE->{notes} }), $want,
            "84-08 _onLmsPlaylistChanged mode=" . ($mode // 'undef') . ": notify('notePlaylistChanged') x$want");
    }
    {
        my $c = Test::Client3->new('aa:00:00:00:00:0d');
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(st => { mode => 'browse' });
        # __PACKAGE__ of the compiled handler is the harness package
        Test::RoleHarness3::_onLmsPlaylistChanged(Test::JumpRequest->new(client => $c, source => 'Test::RoleHarness3'));
        is_deeply($Plugins::SpotOn::Unified::DaemonManager::ROLE->{notes}, [], '84-08 _onLmsPlaylistChanged: own source mark -> nothing (loop prevention)');
    }

    # --- the hold timings and _holdClose through the role ---
    {
        my $c = Test::Client3->new('aa:00:00:00:00:0e');
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(caps => { holdCapS => 1, holdRecheckS => 1, holdMaxS => 3 });
        is_deeply([ Test::RoleHarness3::_holdCap($c), Test::RoleHarness3::_holdRecheck($c), Test::RoleHarness3::_holdMax($c) ], [ 1, 1, 3 ],
            '84-08 hold timings: _holdCap/_holdRecheck/_holdMax read holdCapS/holdRecheckS/holdMaxS from the role');
        Test::RoleHarness3::setHold($c->id, { uri => 'spoton://track:T1', trackId => 'T1' });
        no warnings 'redefine', 'once';
        local *Slim::Utils::Timers::killTimers = sub { };
        Test::RoleHarness3::_holdClose($c, 'test');
        is_deeply($Plugins::SpotOn::Unified::DaemonManager::ROLE->{notes}, [ [ 'clearHold', { trackId => 'T1' } ] ],
            "84-08 _holdClose: notify('clearHold', trackId => <id>) on the role");
    }

    # --- Plugin.pm _prefetchHangCheck: the watchdog hand-off ---
    for my $case ([ 'player engine (ok)', 'ok', 0 ], [ 'librespot (unsupported)', 'unsupported', 1 ], [ 'no engine (down)', 'down', 1 ]) {
        my ($label, $outcome, $jumps) = @$case;
        my $url = 'spoton://track:hang1';
        my $c = Test::Client3->new('aa:00:00:00:00:0f', song => Test::Song3->new($url));
        local $Plugins::SpotOn::Unified::DaemonManager::ROLE = Test::RoleMock3->new(outcome => { watchdogRing => $outcome });
        local $Slim::Player::Source::PLAYMODE = 'play';
        @Test::RoleLog3::WARN = ();
        Test::RoleHarness3::setTrigger($c->id, $url);
        Test::RoleHarness3::_prefetchHangCheck($c);
        is_deeply($Plugins::SpotOn::Unified::DaemonManager::ROLE->{notes}, [ [ 'watchdogRing', { url => $url } ] ],
            "84-08 _prefetchHangCheck $label: notify('watchdogRing', url => <trigger>) on the role");
        is(scalar(grep { $_->[0] eq 'playlist' && $_->[1] eq 'jump' && $_->[2] eq '+1' } @{ $c->{executed} }), $jumps,
            "84-08 _prefetchHangCheck $label: playlist jump +1 x$jumps");
        is(scalar(grep { /handing to Soloist::Control/ } @Test::RoleLog3::WARN), $jumps ? 0 : 1,
            "84-08 _prefetchHangCheck $label: the hand-off warn (extract-run category text) only on ok");
    }
}

# 84.2-05 start site keeps the one-shot marker (revision 8, delta re-check
# warning 2): _playUrlFor changes where the URL comes from, not the stamp.
like($connect, qr/^[ \t]*\$client->pluginData\(connectOwnPlayUri => \$startPlayUrl\)/m,
    '84.2-05 start site keeps the one-shot marker');

done_testing();
