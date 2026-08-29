---
phase: 76-connect-stabilization-flac24-integration
plan: "05"
subsystem: connect
tags: [perl, connect-lifecycle, pluginData, spirc, soloist-ws, sync-groups]

# Dependency graph
requires:
  - phase: 76-02
    provides: "#159 409-eject + #131 buffer latency + #128 relay resync — the fixed baseline this plan's #158 fix layers on (same file, Connect.pm)"
  - phase: 73-soloist-connect-mode
    provides: SoloistWS event->spottyconnect mapping (t/32 pinned emission table) extended with the 'inactive' session-end marker
provides:
  - Restart-autoplay provenance gate — 'start' events within RESTART_START_GRACE (5s) of the daemon's own (re)spawn with an idle player suppress the playlist play (session stays visible + manually resumable)
  - "'inactive'-marked stop as the cross-backend Connect session-end signal (SoloistWS device_changed is_active:false + librespot SessionDisconnected)"
  - GH-151 power save/restore — pluginData connectPrevPower saved before the session powers the player on, restored (power-off dispatch) at session end
  - GH-158 fix — connectSessionPaused tracking gates the change-handler force-unpause so skip-while-paused no longer streams against a paused source
affects: [76-08-uat, connect, librespot-binary-release]

# Actuals (#2632) — pairs with the plan's `estimate` to calibrate future estimates.
actuals:
  tokens: 6100
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Provenance gating via DaemonManager->uptime(): daemon-spawn adjacency distinguishes a restored dormant session from a user-initiated transfer"
    - "Event-marker vocabulary extension: stop _p2='inactive' distinguishes session end from pause without a new verb (both backends)"
    - "connectSessionPaused pluginData mirrors the Spotify-side pause state on the LMS side (set by post-grace stops, cleared by start/resume/unpause/session-end)"

key-files:
  created:
    - t/37_connect_lifecycle.t
  modified:
    - Plugins/SpotOn/Connect.pm
    - Plugins/SpotOn/Unified/SoloistWS.pm
    - librespot-spoton/src/connect.rs
    - t/32_soloist_events.t

key-decisions:
  - "Restart gate anchors on daemon uptime (< 5s) + idle player, NOT on a paused/playing discriminator — at 'start' time the playback_state snapshot has not arrived yet (race), while all 7 captured re-announcements arrived at uptime < 1s"
  - "isPlaying exception in the restart gate preserves daemon-crash mid-playback recovery (an audibly-playing player resuming is not a 'self-start')"
  - "Session end is NOT the plain 'stop' (that verb means pause OR stop) — the daemon marks the authoritative deactivation with _p2='inactive'; plan's assumption that the ~1169 stop handler IS the session-end path was verified false and corrected"
  - "GH-158 root cause is the change-handler force-unpause firing while Spotify is paused — not the RESEARCH Pitfall-4 soloist skipInitiated hypothesis (the reporter runs librespot; skipInitiated never fires there)"
  - "GH-151 save sites exclude the suppressed-restart branch: only code paths that actually power the player on (start playlist play, resume re-entry) save the pre-Connect state — prevents powering off a player the session never activated"

patterns-established:
  - "Grep-gate regression net (t/37) for Connect.pm changes — Connect.pm still has no isolated unit harness (73-03 D4), source assertions pin the three lifecycle fixes"

requirements: [GH-151, GH-158, CONNECT-AUTOPLAY]

# Metrics
duration: 22min
completed: 2026-08-29
status: complete
---

# Phase 76 Plan 05: Connect Lifecycle Fixes Summary

**One-liner:** Restart-autoplay suppressed via daemon-spawn provenance gate (live-log evidence, 4 captured incidents), GH #151 power save/restore wired to a new 'inactive' session-end stop marker on both backends, GH #158 group restart-loop fixed by gating the change-handler force-unpause on tracked Spotify-side pause state.

## Task 1 — Restart-autoplay gate (ROADMAP: Auto-Play nach LMS-Restart)

### Captured root-cause event sequence (live server.log, dev box, 2026-08-29)

Four independent incidents in `/var/log/squeezeboxserver/server.log` (18:11, 18:18, 18:23, 18:26 restarts; plus three more daemon-respawn incidents in server.log.1.gz from 08-27). The 18:18 window:

```
18:18:40.408  DaemonManager::stopHelper — Shutting down Unified daemon (pid 342315)   <- LMS stopping
18:18:41.952  main::init — Starting Lyrion Music Server v9.2.0                        <- LMS restart
18:18:47.491  DaemonManager::startHelper — Need to create Soloist daemon
18:18:47.497  SoloistDaemon::start                                                     <- daemon (re)spawn
18:18:47.615  ws.port announced: 41211
18:18:47.926  SoloistWS::_onTrackChanged — track_changed spotify:track:0TmAb8...       <- dormant session re-announced
18:18:47.926  Got spottyconnect event: start                                           <- 0.43s after spawn, NO user action
18:18:47.927  ProtocolHandler::explodePlaylist — spoton://connect-1788020327926        <- playlist play dispatched = AUTOPLAY
18:18:47.934  formatOverride -> soc; canDirectStream -> http://…/stream                <- LMS starts streaming audio
18:18:47.972  Got spottyconnect event: stop                                            <- the REAL (paused) session state
18:18:47.973  "Ignoring spurious stop during Connect session setup grace period"       <- swallowed by CONNECT_START_GRACE
```

**Triggering event:** the daemon (re)spawn re-announces the existing dormant Spirc session as `track_changed` with no previous track → `SoloistWS::_emitStart` fires `start` → Connect.pm's start handler unconditionally dispatched `playlist play spoton://connect-<ts>`. The daemon's follow-up `stop` (the actual paused state) lands 45ms later inside CONNECT_START_GRACE and is discarded → player plays while the Spotify app shows paused.

### Fix

`Connect.pm` start handler (§1091-1128): if the `start` arrives at daemon uptime > 0 and < `RESTART_START_GRACE` (5s, constant §31-42) while the player is idle, suppress the playlist play — info-log the suppression, keep the ownership claim, eventTrackUri and metadata fetch so the session stays visible and manually resumable (a later app play arrives as `resume`, whose not-on-Connect-stream branch re-enters via playlist play normally). All captured re-announcements arrived at uptime < 1s; a genuine transfer needs the daemon connected to Spotify *plus* a human tap and cannot land inside the window. The `!$client->isPlaying` exception preserves daemon-crash mid-playback auto-recovery. Explicitly unrelated to `pref_enableAutoplay` (DSTM).

**Non-regression:** skipInitiated playlist-play (QT 260827-of9) is in the change handler — untouched; 76-02 paths untouched; fresh transfers occur at daemon uptime well above 5s (device only transferable after the daemon has been up and cluster-registered).

## Task 2 — GH #151 power save/restore

**Session-end verification (plan asked to verify):** the plan's "session-end stop handler at approx. 1169" is in fact the *pause-forwarding* stop handler — the wire vocabulary collapses Paused and Stopped into one un-marked `stop` (librespot has no 'pause' verb). Restoring power there would power players off on every app pause. The genuine session-end signals are `SoloistWS::_onDeviceChanged(is_active:false)` (soloist) and `PlayerEvent::SessionDisconnected` (librespot) — both now emit `stop` with `_p2='inactive'`.

- **Save sites** (first save wins until a real session end clears it): start handler §1136-1141 and resume re-entry §989-994 — both immediately before the playlist play that powers the player on. The suppressed-restart branch deliberately does NOT save (the session has not activated the player).
- **Restore site:** stop handler `'inactive'` branch §1314-1334 (BEFORE the newTrack/grace suppressions — an authoritative daemon-side state, not a transitional stop; the newTrack transitional-stop ignore at §1073 does NOT restore, asserted by t/37). Pauses the stream first (mirrors plain-stop behavior), then `_restorePowerAfterConnect` (§1435+): only powers OFF (Slim::Control::Request `['power', 0]` with `source(__PACKAGE__)`), always clears the flag, skips (with log) when the player is meanwhile playing something that is not the Connect stream.
- **Edge cases:** repeated transfers away/back — first save wins; user starts other playback — `_onNewSong` discards the saved state without powering off (§507-513); sync groups — `_connectEvent` normalizes to the master (the daemon's player), each player with its own session handled individually.
- **librespot parity:** `librespot-spoton/src/connect.rs` gains a `SessionDisconnected` arm emitting `notify("stop", "inactive")` — rides along with the 76-02 Rust rebuild. `cargo check` clean.

**Open UX question for UAT (GH #151 comment):** a community member asked for this to be opt-in (automations hang off player power state; transient deactivations would cut speakers). Current implementation is always-on per plan scope with the playing-something-else guard; if the user wants a pref, that is a Phase-77 settings item — to be decided at UAT.

## Task 3 — GH #158 group pause-skip-play restart loop

### Loop mechanism (diag log `spoton-diag-20260827-080712.txt`, group daemon `0200aa392021-unified.log`)

The reporter runs the LIBRESPOT backend (group player + 2 squeezeesp32 members) — RESEARCH Pitfall 4's soloist skipInitiated hypothesis does not apply (skipInitiated never fires for librespot daemons). The actual sequence:

```
06:06:36  transfer in -> TrackChanged (start) -> Playing -> /stream GET, relay starts     OK
06:06:53  endpoint: pause -> Paused -> 'stop' -> Connect.pm pauses the group              OK
06:06:56  endpoint: skip_next -> Loading <Out Of The Dark> -> TrackChanged (change)
06:06:56  Paused: current_track=Some(0TLZ...)          <- Spotify is STILL paused after the skip
06:06:56  /stream: GET request received                <- LMS opened a NEW stream while everything is paused
06:06:56  /stream: relay_active was true — taking over (old relay likely stale)
06:06:59  endpoint: resume -> Playing (position_ms=0)  <- user presses play 3s later
```

The `/stream` GET at 06:06:56 — while librespot is paused and delivering **no data** — is the smoking gun: Connect.pm's change handler ("Ensure player is playing") unconditionally dispatched `['pause', 0]` on the paused group. Unpausing a group against a paused (data-less) source drives LMS's sync-group rebuffer machinery (`_Rebuffer` pauses the whole group, waits for a fill that never comes, restarts the stream) — each restart resets the song ("song seems to start over and over", music never starts).

### Fix

Track the Spotify-side pause state as pluginData `connectSessionPaused`: set by genuine post-grace `stop` events (§1360), cleared on session start (§1147), resume (§1001, §1047), LMS-side unpause forward (§648), skipInitiated reconnect (§1275) and session end (§1326). The change-handler force-unpause (§1242-1254) now requires `!connectSessionPaused` — a skip-while-paused updates metadata/startOffset but leaves the group paused; the user's play arrives as `resume` and unpauses through the existing (position-synced) path.

**Non-regression analysis:**
- QT-12 soloist skip recovery (~1.16s live-verified): the skipInitiated block issues its own playlist play and bypasses the gate — unchanged.
- librespot skip-while-playing (Paused underrun blip → change): the daemon's `was_paused` mechanism sends `resume` on the next Playing event, which unpauses via the resume handler — recovery moves from the change handler to the resume echo (marginally later, position-synced).
- Normal group/gapless playback: gate only acts when the player is not playing AND the session is flagged paused.
- 76-02 (#159/#131/#128): untouched code paths.

**Repro status:** before-fix behavior is fully evidenced by the attached diag log (above). A live sync-group repro against the fixed baseline was not runnable from this isolated worktree (deploy target is the main checkout / shared live LMS) — recorded in `.planning/WINDOWS.md` (#3) and pinned to the consolidated Phase 76 UAT (76-08): pause → skip → play on the dev sync group must resume on the new track within a few seconds, no repeated `playlist play spoton://connect-` dispatches in server.log.

## Deviations from Plan

### Auto-fixed / adjusted

**1. [Rule 1 - Bug] Session-end hook relocated from the plain stop handler to a new 'inactive'-marked stop**
- **Found during:** Task 2 (plan step "verify it is the session-end path")
- **Issue:** the plan's assumed session-end site (stop handler ~1169) fires on every app pause — restoring power there would power players off mid-listening
- **Fix:** SoloistWS marks the `device_changed(is_active:false)` stop with `_p2='inactive'`; Connect.pm restores only on that marker
- **Files modified:** Plugins/SpotOn/Unified/SoloistWS.pm, Plugins/SpotOn/Connect.pm
- **Commit:** d574c83

**2. [Rule 2 - Missing critical functionality] librespot-side session-end signal added (connect.rs)**
- **Found during:** Task 2
- **Issue:** librespot forwards no distinct event on SessionDisconnected — GH #151 would silently not work on the librespot backend (the plan's file list covered only Perl/tests)
- **Fix:** `SessionDisconnected` arm in connect.rs emits `notify("stop", "inactive")`; requires the librespot-spoton rebuild already pending from 76-02
- **Files modified:** librespot-spoton/src/connect.rs
- **Commit:** d574c83

**3. [Deviation - environment] Live repros executed as log-forensics instead of interactive dev-box runs**
- **Found during:** Tasks 1 and 3
- **Issue:** this plan ran as a parallel worktree executor; the live LMS loads the plugin from the main checkout (`/var/lib/squeezeboxserver/Plugins/SpotOn -> /home/sti/spoton/Plugins/SpotOn`), so worktree code cannot be live-tested, and restarting the shared LMS mid-wave would disturb sibling executors
- **Resolution:** Task 1's before-fix evidence came from four live incidents already in server.log (the exact scenario, captured with timestamps); Task 3's from the issue's diag log. After-fix live verification is pinned to the consolidated Phase 76 UAT (76-08) and recorded in `.planning/WINDOWS.md` entries #2-#4 — consistent with the plan's own note that "the live behaviors are pinned as human-checks harvested into the consolidated Phase 76 UAT (D-11)"

## Authentication Gates

None.

## Known Stubs

None — no placeholder values, no unwired data paths. The three fixes are complete implementations; only their live verification is deferred (WINDOWS #2-#4, UAT 76-08).

## Verification

- `prove -l t/` — **PASS** (37 files, 1702 tests, includes new t/37_connect_lifecycle.t and updated t/32 emission table)
- `cargo check` (librespot-spoton) — clean (2 pre-existing dead-code warnings, untouched)
- Task acceptance greps: `grep -c 'connectPrevPower' Connect.pm` = 10 (save sites §989/§1136, restore §1435+); restore dispatch uses Slim::Control::Request + source(__PACKAGE__); restore lives in the 'inactive' session-end branch (§1314-1334), not the newTrack transitional stop (§1073)

## Threat Flags

None — no new network endpoints, auth paths, or trust-boundary changes. T-76-11 mitigation implemented as registered (power-off only with saved off-state + not-playing-something-else guard + source-marked dispatch); T-76-12 mitigation implemented (provenance-scoped gate), live both-directions check pinned to UAT 76-08.

## Self-Check: PASSED

- FOUND: Plugins/SpotOn/Connect.pm (all three fixes present, greps verified)
- FOUND: t/37_connect_lifecycle.t
- FOUND: commit f9d010c (Task 1)
- FOUND: commit d574c83 (Task 2)
- FOUND: commit eed3fd1 (Task 3)
