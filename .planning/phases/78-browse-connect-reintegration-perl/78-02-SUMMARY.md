---
phase: 78-browse-connect-reintegration-perl
plan: 02
subsystem: connect
tags: [bounded-model, echo-guard, browse-forwarding, tdd]
dependency_graph:
  requires: [78-01]
  provides: [echo-guard, bounded-browse-ws-criterion, currentSpotonTrackUrl-helper]
  affects: [Connect.pm, t/37_connect_lifecycle.t]
tech_stack:
  added: []
  patterns: [bounded-criterion, echo-confirmation-guard]
key_files:
  created: []
  modified:
    - Plugins/SpotOn/Connect.pm
    - t/37_connect_lifecycle.t
decisions:
  - "_soloistBrowseWs re-keyed to bounded criterion: isa-check + connected + !isSpotifyConnect + spoton://track: URL match (replaces browseSession accessor)"
  - "_currentSpotonTrackUrl factored as shared helper: streamingSong-first Phase 44 pattern, reusable by echo guard (this plan) and plan 78-04 ownership criterion"
  - "Echo guard placed immediately after trackId extraction, BEFORE restart gate / D-08 / playlist play — earliest possible no-op point"
  - "_onPause browse branch simplified: no grace window needed in bounded model (advance-echo pause is harmless, superseded by getNextTrack WS play)"
metrics:
  duration: 689s
  completed: "2026-09-01T07:08:46Z"
  tasks_completed: 2
  tasks_total: 2
  commits: 3
status: complete
actuals:
  tokens: 5033
  tasks: 2
  commits: 3
---

# Phase 78 Plan 02: Echo Guard + Bounded Browse Forwarding Summary

Re-keyed the Soloist Browse forwarding criterion from browseSession state-machine accessor to the bounded model, and added the echo/confirmation guard that prevents daemon-echoed start/change events from destroying the user's Browse playlist.

## What Was Built

### Task 1: Re-keyed _soloistBrowseWs and simplified _onPause/_onSeek

**`_currentSpotonTrackUrl($client)` helper (new):** Returns the current song URL if it matches `^spoton://(?:track|episode):`, using the Phase 44 track->url-first extraction pattern. Checks `streamingSong` before `playingSong` (during a track transition only streamingSong carries the new URL). Shared by `_soloistBrowseWs`, the echo guard, and plan 78-04's ownership criterion.

**`_soloistBrowseWs` re-keyed:** Replaced the `$ws->browseSession` condition with the bounded criterion: (a) helper isa `SoloistDaemon`, (b) `$ws->connected`, (c) `!isSpotifyConnect($client)`, (d) current song URL matches `^spoton://(?:track|episode):`. No browse-state accessors touched.

**`_onPause` browse branch simplified:** Plain pause/resume forwarding — unpause sends `play` (no uri = resume), pause and stop both send `pause`. Deleted: BROWSE_ADVANCE_GRACE constant, PLUGIN_SPOTON_SOLOIST_BROWSE source-skip, browseAdvanceTs grace window, endBrowseSession call. The bounded model makes advance-echo pause harmless (superseded by getNextTrack's WS play).

**`_onNewSong` WR-06 hook deleted:** The browse-end hook only called browseSession teardown, which is inert; leaving it would fire teardown logging on every Soloist track.

**`_onSeek` browse branch updated:** Removed PLUGIN_SPOTON_SOLOIST_BROWSE source-skip. Updated comment to document the bounded-model seek semantics (LMS restarts stream, WS seek runs in parallel, documented race per RESEARCH Pitfall 5).

### Task 2: Echo/confirmation guard in _connectEvent (TDD)

**'start' handler guard:** After `$trackId` extraction, before restart gate / D-08 stop / playlist play: if the helper is a SoloistDaemon AND `!isSpotifyConnect` AND `_currentSpotonTrackUrl` matches `spoton://(?:track|episode):<trackId>` — return immediately (no-op). This prevents the daemon's echoed track_changed for an LMS-initiated Browse play from collapsing the playlist to a single Connect entry (RESEARCH Pitfall 1).

**'change' handler guard:** Same check at the top of the change handler, before any metadata handling or stream reconnect logic.

**Backend scoping:** Both guards are conditioned on `SoloistDaemon` isa-check — the librespot Connect path has no such guard (it doesn't echo Browse plays).

**t/37 grep gates (7 new assertions):** Pin the echo guard's presence and source order in both handlers: `_currentSpotonTrackUrl` precedes D-08 and playlist play in start; precedes `_fetchTrackMetadata` in change; both reference SoloistDaemon.

## Commits

| # | Hash | Type | Description |
|---|------|------|-------------|
| 1 | e8468c1 | refactor | Re-key _soloistBrowseWs to bounded-model criterion and simplify browse forwarding |
| 2 | b05930c | test | Add failing echo-guard grep gates (TDD RED) |
| 3 | 72cf4bd | feat | Echo/confirmation guard in start and change handlers (TDD GREEN) |

## TDD Gate Compliance

- RED gate: `b05930c` — test(78-02) commit with 7 failing assertions
- GREEN gate: `72cf4bd` — feat(78-02) commit making all assertions pass
- REFACTOR gate: not needed (no duplication or cleanup required)

## Deviations from Plan

None — plan executed exactly as written.

## Test Results

```
Files=37, Tests=1827,  6 wallclock secs
Result: PASS
```

- t/37_connect_lifecycle.t: 39 tests (32 existing + 7 new echo-guard gates)
- t/05_perl_syntax.t: 18 tests (Connect.pm syntax OK)
- All 37 test files pass

## Verification Checklist

- [x] `grep -cE 'BROWSE_ADVANCE_GRACE|browseAdvanceTs|endBrowseSession|PLUGIN_SPOTON_SOLOIST_BROWSE' Connect.pm` == 0
- [x] `_soloistBrowseWs` checks isa(SoloistDaemon), connected, isSpotifyConnect, URL match — no browse-state accessor
- [x] `_currentSpotonTrackUrl` exists, inspects streamingSong and playingSong
- [x] `_bufferedBrowseSeek` still sends `sendCommand('seek', position_ms => ...)`
- [x] Librespot Connect paths untouched (diff confirms no hunks in Connect forwarding below browse branches)
- [x] Echo guard in start handler precedes restart gate, D-08, and playlist play
- [x] Echo guard in change handler precedes metadata handling
- [x] Both guards scoped to SoloistDaemon (isa-check)
- [x] Full suite green (1827 tests)

## Files Modified

| File | Lines Changed | Nature |
|------|--------------|--------|
| Plugins/SpotOn/Connect.pm | +188/-99 | Re-keyed criterion, echo guards, simplified forwarding |
| t/37_connect_lifecycle.t | +49 | Echo-guard grep gates |

## Self-Check: PASSED

- All source files present on disk
- All 3 commits found in git log
- SUMMARY.md written to phase directory
