---
phase: 78-browse-connect-reintegration-perl
plan: 04
subsystem: connect-lifecycle
status: complete
tags: [D-04, ownership, watchdog, connect, soloist, bounded]

dependency_graph:
  requires: [78-02, 78-03]
  provides: [D-04-dispatch, soloist-ownership, watchdog-connect-safe]
  affects: [Connect.pm, Plugin.pm, t/37]

tech_stack:
  added: []
  patterns: [backend-dispatch, ownership-criterion, connect-guard]

key_files:
  created: []
  modified:
    - Plugins/SpotOn/Connect.pm
    - Plugins/SpotOn/Plugin.pm
    - t/37_connect_lifecycle.t

decisions:
  - D-04 dispatches spoton://track:ID for Soloist at all four Connect sites; librespot keeps spoton://connect-%u byte-identical
  - Soloist change handler bypasses skipInitiated path; D-05 flush-disconnect delivers EOF
  - _isSoloistOwnedSong uses lastTrackId comparison as ownership criterion
  - D-16 release re-keyed to check both connect- URL and Soloist ownership before releasing
  - _pauseGuardCheck integrates Connect check into existing unless-cleanup condition

metrics:
  duration_seconds: 639
  completed: "2026-09-01T07:38:19Z"
  tasks: 3
  commits: 4
  files_changed: 3
  insertions: 341
  deletions: 68

estimate:
  tokens: 85000
  confidence: low

actuals:
  tokens: 85250
  tasks: 3
  commits: 4
---

# Phase 78 Plan 04: D-04 Connect Track URLs, Ownership Criterion, Watchdog Guards Summary

Soloist Connect switched to per-track bounded spoton://track:ID playlist entries at all four dispatch sites, with a new daemon-track ownership criterion replacing every connect-URL live-check, and Phase-27 watchdog guards preventing double-skips on the new URL shape.

## Completed Tasks

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | D-04 backend-dispatched spoton://track:ID at four sites | 8c0cbb3 | Connect.pm |
| 2 | Soloist ownership criterion _isSoloistOwnedSong + re-keyed D-16 | 12c23e1 | Connect.pm |
| 3 (RED) | Failing tests for D-04, ownership, watchdog gates | 8bf3178 | t/37_connect_lifecycle.t |
| 3 (GREEN) | isSpotifyConnect guard at five watchdog subs | d1bbc3a | Plugin.pm |

## Implementation Details

### Task 1: D-04 Backend-Dispatched Track URLs

All four Connect playlist-play dispatch sites (resume re-entry, start, change, ready) now use backend dispatch:
- **SoloistDaemon**: dispatches `spoton://track:$trackId` -- same audio contract as Browse
- **librespot**: byte-identical `sprintf("spoton://connect-%u", $ts)` -- repeating-stream preserved

The Soloist 'change' handler is architecturally different: EVERY track change dispatches a new `playlist play spoton://track:$newTrackId` entry. The skipInitiated reconnect special-path is bypassed for Soloist because D-05 flush-disconnect delivers the EOF. The librespot 'change' handler (skipInitiated reconnect) stays byte-identical.

RESTART_START_GRACE suppression block is textually unchanged except for the D-04 URL branch in the non-suppressed path.

### Task 2: Soloist Ownership Criterion

**`_isSoloistOwnedSong($client)`**: Returns true iff:
1. Helper isa SoloistDaemon with connected WS
2. `lastTrackId` is defined
3. Current song URL matches `spoton://track:<lastTrackId>` or `episode:<lastTrackId>`

Re-keyed consumers (7 call sites):
- **_isLiveConnectStream**: extended -- returns true for Soloist-owned songs (D-04 sessions have no connect- URL)
- **D-16 stale-claim release** in _onNewSong: releases only when NOT connect-URL AND NOT Soloist-owned (prevents Pitfall 2 claim drop)
- **CON-17 progress branch**: accepts both connect-URL and Soloist-owned
- **D-08 mutual-exclusion stop**: skips Soloist-owned songs (Connect re-start must not stop its own session)
- **resume actuallyInConnect**: includes Soloist-owned as "on Connect stream"
- **_restorePowerAfterConnect** (GH-#151): accepts Soloist-owned songs

`stop 'inactive'` path stays byte-identical -- authoritative session-end release.

### Task 3: Watchdog Guards + t/37 Rewrite (TDD)

Six `isSpotifyConnect` guard insertions across five subs:
1. **_onNewSongWatchdog** deferred-timer closure: `return if ... isSpotifyConnect($c)`
2. **_onNewSongWatchdog** main body: `return if ... isSpotifyConnect($client)`
3. **_onModeChange**: `return if ... isSpotifyConnect($client)`
4. **_pauseGuardCheck**: integrated into `unless` cleanup condition
5. **_prefetchWatchdog**: `return if ... isSpotifyConnect($client)`
6. **_prefetchHangCheck**: `return if ... isSpotifyConnect($client)` after trigger-url consumption

t/37 rewritten: obsolete D-16 URL-criterion tests replaced with D-04 dual-backend dispatch gates, ownership-criterion gates, and watchdog-guard gates (47 tests total). Existing restart-gate, GH-#151, GH-#158, metadata-bleed, and echo-guard tests unchanged.

## Deviations from Plan

None -- plan executed exactly as written.

## Verification Results

- `prove -l t/` (37 files, 1765 tests): **Result: PASS**
- `grep -c 'spoton://track:\$' Connect.pm`: present (Soloist dispatch literal)
- `grep -c 'spoton://connect-%u' Connect.pm`: 5 (4 dispatches + 1 DIAG log -- librespot intact)
- `grep -c '_isSoloistOwnedSong' Connect.pm`: 10 (>= 6 required)
- `grep -c 'isSpotifyConnect' Plugin.pm`: 6 (>= 6 required)
- No librespot-only branch outcome altered (connect-%u dispatches, isRepeatingStream, repeating-stream lifecycle byte-identical)

## TDD Gate Compliance

- RED commit: `8bf3178` (test) -- 6 watchdog gate tests failing as expected
- GREEN commit: `d1bbc3a` (feat) -- all 47 t/37 tests passing
- No REFACTOR needed (code clean)

## Self-Check: PASSED

- [x] Connect.pm exists and passes syntax
- [x] Plugin.pm exists and passes syntax
- [x] t/37_connect_lifecycle.t exists and passes
- [x] All 4 commits verified in git log
- [x] Full test suite passes
