---
phase: 78-browse-connect-reintegration-perl
plan: 01
subsystem: playback
tags: [protocolhandler, soloist, bounded-endpoint, fake-libpulse, websocket, browse]

requires:
  - phase: 77-bounded-endpoint-spike
    provides: fake-libpulse bounded serving (POST /boundary, flush-disconnect, ring buffer)

provides:
  - Spike-2 baseline committed (fake-libpulse.c, libpulse.so.0, _signalBoundary, metadata-bleed guard)
  - Bounded per-track URL form (canDirectStream + new() proxy)
  - Gate-free getNextTrack with lastTrackId/isSpotifyConnect no-play branches
  - D-02 boundary on raw 'stopped' in _onPlaybackChanged
  - LMS-native seek-restart for Soloist Browse (getSeekData fall-through)
  - Rewritten t/29 bounded-model tests + t/31 D-02 boundary tests

affects: [78-02, 78-03, 78-04]

actuals:
  tokens: 17478
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Bounded URL form: /stream/track?uri=spotify:TYPE:ID&start=OFFSET"
    - "Gate-free getNextTrack: lastTrackId comparison replaces browseAdvancePending re-entry guard"
    - "Dual _signalBoundary: track_changed + raw 'stopped' covers both mid-session and session-end"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/ProtocolHandler.pm
    - Plugins/SpotOn/Unified/SoloistWS.pm
    - Plugins/SpotOn/Unified/SoloistDaemon.pm
    - Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c
    - Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0
    - Plugins/SpotOn/Connect.pm
    - t/29_soloist_browse.t
    - t/31_soloist_ws.t
    - t/37_connect_lifecycle.t

key-decisions:
  - "SPOTON_BOUNDARY_SPIKE env var removed from SoloistDaemon.pm; C-side getenv guard stays inert for future diagnostics"
  - "Seek offset handled by canDirectStreamSong URL substitution (not in canDirectStream itself, which lacks $song access)"
  - "getSeekData Soloist-Browse undef branch removed -- LMS-native seek-restart is the wanted mechanism for bounded serving"
  - "_hasActiveSoloistBrowseSession deleted entirely (sole consumer was canDoAction rew suppression)"

patterns-established:
  - "Bounded URL: http://host:PORT/stream/track?uri=spotify:TYPE:ID&start=OFFSET -- C ignores path/query, params are Perl-side URL uniqueness"
  - "No-play branch: if Connect owns the player or lastTrackId matches, skip sendCommand play (daemon already sequencing)"
  - "D-02 boundary: _signalBoundary on raw status 'stopped', never 'paused', never while deactivating"

requirements-completed: [D-01, D-02, D-03, D-05, D-07]

coverage:
  - id: D1
    description: "Spike-2 baseline committed: fake-libpulse bounded serving, _signalBoundary, metadata-bleed guard"
    requirement: ""
    verification:
      - kind: unit
        ref: "t/05_perl_syntax.t"
        status: pass
    human_judgment: false
  - id: D2
    description: "canDirectStream returns bounded URL /stream/track?uri=spotify:TYPE:ID&start=0"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#canDirectStream bounded per-track URL"
        status: pass
    human_judgment: false
  - id: D3
    description: "canDirectStreamSong seek offset substitution for bounded URL"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#canDirectStreamSong seek offset"
        status: pass
    human_judgment: false
  - id: D4
    description: "Gate-free getNextTrack sends play via sendCommand, sync successCb"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#getNextTrack gate-free dispatch"
        status: pass
    human_judgment: false
  - id: D5
    description: "getNextTrack no-play on lastTrackId match (EOF-advance no-op)"
    requirement: "D-01"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#lastTrackId match skips play"
        status: pass
    human_judgment: false
  - id: D6
    description: "getNextTrack no-play on isSpotifyConnect (Connect ownership)"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#isSpotifyConnect skips play"
        status: pass
    human_judgment: false
  - id: D7
    description: "getNextTrack errorCb on sendCommand failure"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#sendCommand failure errorCb"
        status: pass
    human_judgment: false
  - id: D8
    description: "getFormatForURL maps bounded URL to 'pcm' (soc pcm * * rule covers it)"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#getFormatForURL bounded URL pcm"
        status: pass
    human_judgment: false
  - id: D9
    description: "_signalBoundary fires on track_changed and raw 'stopped', not 'paused', not while deactivating"
    requirement: "D-02"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t#D-02 boundary trigger matrix"
        status: pass
    human_judgment: false
  - id: D10
    description: "LMS-native seek-restart for Soloist Browse (getSeekData fall-through)"
    requirement: "D-05"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t#canDirectStreamSong seek offset"
        status: pass
    human_judgment: false
  - id: D11
    description: "End-to-end bounded Browse path: playlist play -> getNextTrack -> bounded HTTP -> boundary close -> EOF"
    verification: []
    human_judgment: true
    rationale: "Requires live LMS + Soloist daemon + Spotify account for E2E audio verification; deferred to plan 78-02/78-04 UAT"

duration: 13min
completed: 2026-09-01
status: complete
---

# Phase 78 Plan 01: Bounded Browse Tracer Summary

**Spike-2 baseline committed + ProtocolHandler switched to bounded /stream/track URL + D-02 boundary on 'stopped' + gate-free getNextTrack with lastTrackId/Connect no-play + tests rewritten for bounded model**

## Performance

- **Duration:** 13 min
- **Started:** 2026-09-01T06:38:46Z
- **Completed:** 2026-09-01T06:51:57Z
- **Tasks:** 3
- **Files modified:** 8

## Accomplishments

- Committed the Phase 77 Spike-2 baseline (fake-libpulse.c bounded serving, SoloistWS _signalBoundary, Connect.pm metadata-bleed guard, t/37 test block) and retired the SPOTON_BOUNDARY_SPIKE env var
- Switched ProtocolHandler canDirectStream + new() proxy to bounded per-track URL form `/stream/track?uri=spotify:TYPE:ID&start=OFFSET`
- Replaced the D-17/WR-04 readiness gate + re-entry guard in getNextTrack with a gate-free path: lastTrackId comparison and isSpotifyConnect ownership check determine whether to send WS play, then synchronous successCb
- Added D-02 _signalBoundary trigger on raw 'stopped' in _onPlaybackChanged (natural track/session end plants boundary for clean EOF)
- Enabled LMS-native seek-restart for Soloist Browse (getSeekData falls through to timeOffset, canDoAction 'rew' suppression removed)
- Rewrote t/29 FakeSoloistWs for bounded model, added 7 new getNextTrack dispatch tests, 1 getFormatForURL test, 1 seek test
- Added D-02 boundary trigger matrix to t/31 (4 cases: track_changed, stopped, paused, deactivating)
- Full suite: 37 files, 1820 tests, Result: PASS

## Task Commits

Each task was committed atomically:

1. **Task 1: Commit Spike-2 baseline and retire spike env var** - `e62557b` (feat)
2. **Task 2: Bounded Browse end-to-end -- /stream/track URL + D-02 boundary** - `61c56c2` (feat)
3. **Task 3: Rewrite t/29 + add D-02 boundary tests to t/31** - `fb44509` (test)

## Files Created/Modified

- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` - Ring buffer, POST /boundary, bounded serving, flush-disconnect (spike baseline)
- `Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0` - Compiled spike binary
- `Plugins/SpotOn/Connect.pm` - Metadata-bleed guard (spike baseline)
- `Plugins/SpotOn/Unified/SoloistDaemon.pm` - SPOTON_BOUNDARY_SPIKE env var removed
- `Plugins/SpotOn/Unified/SoloistWS.pm` - _signalBoundary on track_changed (spike) + D-02 on raw 'stopped' (new)
- `Plugins/SpotOn/ProtocolHandler.pm` - Bounded URL in canDirectStream/new(), gate-free getNextTrack, seek fall-through, _hasActiveSoloistBrowseSession deleted
- `t/29_soloist_browse.t` - FakeSoloistWs rewritten, bounded URL assertions, getNextTrack dispatch tests
- `t/31_soloist_ws.t` - D-02 boundary trigger matrix (4 cases)
- `t/37_connect_lifecycle.t` - Metadata-bleed test block (spike baseline)

## Decisions Made

- SPOTON_BOUNDARY_SPIKE env var removed from SoloistDaemon.pm; the C-side getenv guard stays inert and re-activatable by hand for future diagnostics
- Seek offset applied by canDirectStreamSong via URL substitution (`s/&start=\d+/&start=$offset/`), not in canDirectStream itself (which lacks $song access) -- this keeps the seek-append idiom next to the existing librespot seek-append
- _hasActiveSoloistBrowseSession sub deleted entirely -- its sole consumer was the canDoAction 'rew' suppression, which is now correctly removed for Soloist Browse (LMS-native seek-restart is the wanted mechanism)
- librespot branches in ProtocolHandler.pm remain byte-identical (Windows constraint)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- Worktree was branched from clean HEAD; spike changes existed only in main repo's working tree -- resolved by copying files from main repo into worktree before Task 1 commit
- `perl -c` cannot verify ProtocolHandler.pm/SoloistWS.pm in isolation (missing LMS deps) -- used `prove -l t/05_perl_syntax.t` for syntax verification throughout

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Bounded Browse tracer path is committed and tested; the browseSession machinery is provably dead (D-06 evidence: getNextTrack no longer calls startBrowseTrack/waitForBrowseReady, t/29 no longer exercises those paths)
- Plan 78-02 can proceed: Connect.pm echo guard, pause/seek forwarding, and Plugin.pm watchdog guards
- Plan 78-03 can proceed: removal of ~470 LOC browseSession code from SoloistWS.pm
- Live UAT deferred to after wave 2 (plan 78-02 supplies the Connect.pm echo guard and pause/seek forwarding a live session needs)

---
*Phase: 78-browse-connect-reintegration-perl*
*Completed: 2026-09-01*
