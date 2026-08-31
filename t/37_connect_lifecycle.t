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
# Phase 76-10: RC-2 stale-claim lifecycle (D-16)
# ------------------------------------------------------------

# 1. Restart-gate suppressed branch contains a pendingConnect clear.
# The RESTART_START_GRACE block logs "start_suppressed" and must clear
# pendingConnect before its return — a leaked flag lets change/seek handlers
# hijack subsequent Browse playback (metadata-bleed vector).
like($connect,
    qr/start_suppressed.*?pendingConnect\s*=>\s*0/s,
    'D-16: restart-gate suppressed branch clears pendingConnect before return');

# 2. _onNewSong CON-17 branch predicate includes a connect- URL match.
# The old predicate was isSpotifyConnect alone (identical to the release block
# below, making it dead code). Now requires BOTH the ownership claim AND a
# connect-* URL on the playing song.
like($connect,
    qr/isSpotifyConnect\(\$client\)\s*&&\s*\$url\s*=~\s*m\{spoton:\/\/connect-\}/,
    'D-16: CON-17 branch requires both isSpotifyConnect and connect-* URL');

# 3. _onPause contains the stale-claim guard: _isLiveConnectStream appears
# inside _onPause between the isSpotifyConnect gate and the forwarding calls.
my ($on_pause_block) = $connect =~ /(sub _onPause \{.*?\nsub )/s;
ok($on_pause_block, 'D-16: _onPause block parseable');
if ($on_pause_block) {
    like($on_pause_block,
        qr/isSpotifyConnect\(\$client\).*?_isLiveConnectStream\(\$client\).*?_sendControlCommand/s,
        'D-16: stale-claim guard (_isLiveConnectStream) sits between isSpotifyConnect gate and forwarding');
}

# 4. _isLiveConnectStream uses track->url before streamUrl (Phase 44 pin).
my ($helper_block) = $connect =~ /(sub _isLiveConnectStream \{.*?\})/s;
ok($helper_block, 'D-16: _isLiveConnectStream helper exists');
if ($helper_block) {
    like($helper_block,
        qr/track->url\s*\|\|\s*.*?streamUrl/s,
        'D-16: _isLiveConnectStream uses track->url before streamUrl (Phase 44 pattern)');
    like($helper_block,
        qr/spoton:\/\/connect-/,
        'D-16: _isLiveConnectStream checks for connect- URL pattern');
}

done_testing();
