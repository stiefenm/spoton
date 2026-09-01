---
phase: 78-browse-connect-reintegration-perl
plan: 03
subsystem: unified/soloist-ws
tags: [removal, browse-sm, d-06, d-07, dead-code]
dependency_graph:
  requires: [78-01, 78-02]
  provides: [lean-soloist-ws, browse-sm-removed]
  affects: [78-04]
tech_stack:
  added: []
  patterns: [pure-deletion-refactor]
key_files:
  created: []
  modified:
    - Plugins/SpotOn/Unified/SoloistWS.pm
    - t/29_soloist_browse.t
    - t/31_soloist_ws.t
    - t/32_soloist_events.t
decisions:
  - "browseSession emit gate removed — echo discrimination lives in Connect.pm (78-02)"
  - "browse-only stubs (Source, Playlist, Control::Request, FakeSong) removed from t/31"
  - "Timers stub simplified to no-op (recording feature was only for D-17 gate tests)"
metrics:
  duration: 15min
  completed: 2026-09-01
status: complete
actuals:
  tokens: 3200
  tasks: 2
  commits: 2
---

# Phase 78 Plan 03: Browse State Machine Removal Summary

Remove the provably-dead browseSession state machine (~578 LOC) from SoloistWS.pm and its test blocks (~691 LOC from t/31) — the D-06 second commit of the inkrementelle Removal-Strategie. Plans 78-01 proved the bounded model works and 78-02 made it live-safe; the compensatory Phase-72/73/76 browse code is now dead (browseSession can never become 1: its only setter was the startBrowseTrack call removed from getNextTrack in 78-01).

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Remove browseSession state machine from SoloistWS.pm | ed34817 | SoloistWS.pm |
| 2 | Delete browse-SM test blocks + add ungated-emission case | f6bfc0d | t/29, t/31, t/32 |

## What Was Removed

### SoloistWS.pm (578 lines deleted)
- **7 accessors:** browseSession, browseCurrentUri, browseSeededUri, browseAdvancePending, browseAdvanceTs, browseReadyCb, browseTrackConfirmed
- **3 constants:** BROWSE_SEED_LEAD_SECONDS, BROWSE_READY_TIMEOUT, BROWSE_READY_CONFIRM
- **Full subs:** _onBrowseTrackChanged, _maybeSeedBrowseQueue, _hasNextPlaylistEntry, _nextBrowseSpotifyUri, _clientCurrentSpotifyUri, startBrowseTrack, endBrowseSession, waitForBrowseReady, _resolveBrowseReady, _clearBrowseReadyTimers, _browseReadyTimeoutTimer, _browseReadyConfirmTimer
- **Browse blocks within:** _onTrackChanged (routing), _onPlaybackChanged (Stage-B + stopped-advance), _onPositionSync (seeding + Stage-B), _onDeviceChanged (handover), _onClosed (resolve), _emitAllowed (gate)
- **Data:** %_BROWSE_END_SKIP_PAUSE hash, constructor init lines, comment blocks

### Tests (691 lines deleted)
- **t/31:** browseSession emit gate test, startBrowseTrack tests, seeded-match advance, Pitfall-4 correction, D-15 confirmation (A/B/C), device handover, track-end (with/without next entry), WR-06, pending-seed, position_sync seeding (4 cases), D-17 readiness gate (8 test blocks), timer helpers (pending_timers, fire_timer), new_gated_browse_ws helper
- **t/31 stubs:** Slim::Player::Source, Slim::Player::Playlist, Slim::Control::Request, Test::FakeSong, setPlayingSong — all browse-only
- **t/31 stub simplification:** Timers stub reduced from recording to no-op

## What Survives (Contract Intact)

- `_signalBoundary`: 2 call sites (track_changed + playback_changed 'stopped') + sub definition
- `lastTrackId`: unconditional dedup + update for every valid track_changed
- `skipInitiated`/`sessionPaused`/`deactivating`: all logic paths unchanged
- `sendCommand` URI validation regex gate
- `_emitAllowed` enableSpotifyConnect pref check
- `_onPlaybackState` reconciliation (track/position/volume drift correction)
- Reconnect/handshake timeout mechanics
- D-02 boundary trigger matrix tests (5 assertions in t/31)

## What Was Added

- **t/32:** One new test case asserting ungated emission — track_changed on non-Connect Soloist player always translates to spottyconnect emission (D-06 removal confirmation)

## Deviations from Plan

None — plan executed exactly as written.

## Verification

- `perl -c` via t/05_perl_syntax.t: PASS
- Case-insensitive grep for all inventoried browse-SM identifiers: 0 matches in SoloistWS.pm
- `grep -cF '$self->_signalBoundary'` >= 2, `grep -c 'sub _signalBoundary'` == 1
- `grep -c 'enableSpotifyConnect'` >= 1
- `prove -l t/`: Result: PASS (37 files, 1743 tests)
- `grep -rn browseSession Plugins/ t/` outside Connect.pm: 0 matches
- No librespot files touched (diff scope = SoloistWS.pm + 3 test files)

## Known Stubs

None.

## Self-Check: PASSED

- [x] ed34817 exists: `git log --oneline | grep ed34817` confirmed
- [x] f6bfc0d exists: `git log --oneline | grep f6bfc0d` confirmed
- [x] SoloistWS.pm exists and compiles (881 lines, down from 1458)
- [x] t/31 exists (946 lines, down from 1636)
- [x] t/32 exists with ungated-emission case
- [x] Full suite green
