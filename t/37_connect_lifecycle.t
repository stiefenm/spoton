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

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";
my $ws_file      = "$project_dir/Plugins/SpotOn/Unified/SoloistWS.pm";

plan skip_all => 'Connect.pm not present in this checkout' unless -f $connect_file;

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

# SoloistWS marks the transfer-away stop as the session-end signal.
SKIP: {
    skip 'SoloistWS.pm not present', 1 unless $ws;
    like($ws, qr/_emit\('stop',\s*'inactive'\)/,
        "GH #151: SoloistWS device_changed(is_active:false) emits the 'inactive' session-end marker");
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
if ($start_d04_block) {
    like($start_d04_block,
        qr/SoloistDaemon.*?spoton:\/\/track:/s,
        'D-04 start: Soloist branch dispatches spoton://track: URL');
    like($start_d04_block,
        qr/spoton:\/\/connect-%u/,
        'D-04 start: librespot branch still uses spoton://connect-%u');
}

# Gate 2: 'change' block has dual-backend dispatch; the Soloist branch
# contains no skipInitiated reference (D-05 flush-disconnect delivers EOF).
my ($change_d04_block) = $connect =~ /(# -+\n\s+# Change:.*?)(?=# -+\n\s+# Stop:)/s;
ok($change_d04_block, 'D-04 change: handler block parseable');
if ($change_d04_block) {
    like($change_d04_block,
        qr/SoloistDaemon.*?spoton:\/\/track:/s,
        'D-04 change: Soloist branch dispatches spoton://track: URL');
    like($change_d04_block,
        qr/spoton:\/\/connect-%u/,
        'D-04 change: librespot branch still uses spoton://connect-%u');
    # Extract the Soloist-specific change block: from SoloistDaemon to the
    # 'return;' that ends it, before the librespot code.  Check that the
    # Soloist branch does not USE skipInitiated in code (comments mentioning
    # it for rationale are fine -- strip comments before checking).
    my ($soloist_change) = $change_d04_block =~
        /(SoloistDaemon.*?spoton:\/\/track:.*?return;)/s;
    if ($soloist_change) {
        # Strip comment lines for the assertion: we care about code, not docs.
        (my $soloist_code = $soloist_change) =~ s/^\s*#.*$//gm;
        unlike($soloist_code, qr/skipInitiated/,
            'D-04 change: Soloist branch code does not reference skipInitiated');
    }
}

# ------------------------------------------------------------
# Phase 78-04: Ownership criterion (_isSoloistOwnedSong)
# replaces D-16 URL-criterion tests
# ------------------------------------------------------------

# 1. _isSoloistOwnedSong helper exists and uses lastTrackId.
like($connect,
    qr/sub _isSoloistOwnedSong\b/,
    'ownership: _isSoloistOwnedSong helper defined');
my ($ownership_block) = $connect =~ /(sub _isSoloistOwnedSong \{.*?\n\})/s;
ok($ownership_block, 'ownership: _isSoloistOwnedSong block parseable');
if ($ownership_block) {
    like($ownership_block,
        qr/lastTrackId/,
        'ownership: _isSoloistOwnedSong references lastTrackId');
    like($ownership_block,
        qr/SoloistDaemon/,
        'ownership: _isSoloistOwnedSong checks for SoloistDaemon');
}

# 2. D-16 release block references _isSoloistOwnedSong (no longer keys on
# URL-scheme test alone).
like($connect,
    qr/_isSoloistOwnedSong\(\$client\)/,
    'ownership: _isSoloistOwnedSong is called with $client');

# 3. _isLiveConnectStream is extended to check Soloist ownership.
my ($live_connect_block) = $connect =~ /(sub _isLiveConnectStream \{.*?\n\})/s;
ok($live_connect_block, 'ownership: _isLiveConnectStream block parseable');
if ($live_connect_block) {
    like($live_connect_block,
        qr/_isSoloistOwnedSong/,
        'ownership: _isLiveConnectStream checks _isSoloistOwnedSong for Soloist path');
    like($live_connect_block,
        qr/spoton:\/\/connect-/,
        'ownership: _isLiveConnectStream still checks connect- URL for librespot path');
}

# 4. Restart-gate suppressed branch still clears pendingConnect (unchanged).
like($connect,
    qr/start_suppressed.*?pendingConnect\s*=>\s*0/s,
    'D-16: restart-gate suppressed branch clears pendingConnect before return');

# 5. _onPause D-16 stale-claim guard still uses _isLiveConnectStream.
my ($on_pause_block) = $connect =~ /(sub _onPause \{.*?\nsub )/s;
ok($on_pause_block, 'D-16: _onPause block parseable');
if ($on_pause_block) {
    like($on_pause_block,
        qr/isSpotifyConnect\(\$client\).*?_isLiveConnectStream\(\$client\).*?_sendControlCommand/s,
        'D-16: stale-claim guard (_isLiveConnectStream) sits between isSpotifyConnect gate and forwarding');
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
# Phase 78-02: echo/confirmation guard in _connectEvent start/change
#
# When the Soloist daemon echoes a track_changed for a track that LMS
# itself started (Browse play -> WS play -> track_changed -> spottyconnect
# start), the echo guard must no-op: no playlist play, no claim.  The
# guard compares the announced track against _currentSpotonTrackUrl.
# ------------------------------------------------------------

# Gate 1: 'start' handler echo guard precedes D-08 stop dispatch and
# playlist play dispatch.  Use the comment block "# Start:" as anchor
# to skip the earlier pendingConnect-setup `$cmd eq 'start'` block.
my ($start_block) = $connect =~ /(# -+\n\s+# Start:.*?)(?=# -+\n\s+# Change:)/s;
ok($start_block, 'echo guard: start handler block parseable');
if ($start_block) {
    # The echo guard must appear (via _currentSpotonTrackUrl call) BEFORE
    # the D-08 mutual-exclusion stop dispatch and BEFORE playlist play.
    like($start_block,
        qr/_currentSpotonTrackUrl.*?D-08.*?'playlist',\s*'play'/s,
        'echo guard: _currentSpotonTrackUrl check precedes D-08 stop and playlist play in start handler');

    # The guard must be scoped to the Soloist backend (SoloistDaemon isa-check).
    like($start_block,
        qr/SoloistDaemon.*?_currentSpotonTrackUrl/s,
        'echo guard: start handler guard is scoped to SoloistDaemon backend');
}

# Gate 2: 'change' handler echo guard is present before metadata handling.
my ($change_block) = $connect =~ /(# -+\n\s+# Change:.*?)(?=# -+\n\s+# Stop:)/s;
ok($change_block, 'echo guard: change handler block parseable');
if ($change_block) {
    like($change_block,
        qr/_currentSpotonTrackUrl/,
        'echo guard: change handler contains _currentSpotonTrackUrl check');

    # The guard must precede the _fetchTrackMetadata call.
    like($change_block,
        qr/_currentSpotonTrackUrl.*?_fetchTrackMetadata/s,
        'echo guard: change handler guard precedes metadata handling');

    # Backend scoping: SoloistDaemon isa-check in the guard.
    like($change_block,
        qr/SoloistDaemon.*?_currentSpotonTrackUrl/s,
        'echo guard: change handler guard is scoped to SoloistDaemon backend');
}

# Gate 3: existing tests still pass (regression net) — covered by the
# assertions above and the unchanged tests below.

done_testing();
