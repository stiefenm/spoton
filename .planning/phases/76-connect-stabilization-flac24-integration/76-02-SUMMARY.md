---
phase: 76-connect-stabilization-flac24-integration
plan: "02"
subsystem: connect
tags: [rust, librespot, spirc, hyper, perl, simpleasynchttp, sync-groups]

# Dependency graph
requires:
  - phase: 58-connect-position-sync
    provides: needs_position_sync mechanism + "seek" notify vocabulary reused for the GH-128 relay-start resync
  - phase: 63-sync-group-daemon-stability
    provides: GH-143 decision (sync-membership changes must not bounce daemons) constraining the GH-131 fix to spawn-time
provides:
  - 409 CONFLICT contract for /control transport commands dropped while the device is not the active Connect target (GH-159, Rust side)
  - Connect.pm 409-aware error handling — stop/eject instead of Web API fallback, control_cmd_rejected [DIAG] marker (GH-159, Perl side)
  - --buffer-latency-ms 5000 spawn arg for synced non-group players (GH-131)
  - Relay-start position resync — PositionAnchor + LMS::resync_position_at_relay_start() pushing a fresh seek notify the moment /stream serves audio (GH-128)
affects: [76-08-uat, connect, librespot-binary-release]

# Actuals (#2632) — pairs with the plan's `estimate` to calibrate future estimates.
actuals:
  tokens: 8100
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "control_status(): extracted pure fn for HTTP status mapping so handler logic is unit-testable without a hyper server"
    - "PositionAnchor: position-carrying PlayerEvents maintain a shared (pos, Instant, playing) anchor; consumers extrapolate at 1x wall clock"
    - "spirc_active lifecycle: SessionConnected/Playing/TrackChanged => true, SessionDisconnected => false (all four dispatchers)"

key-files:
  created: []
  modified:
    - librespot-spoton/src/unified.rs
    - librespot-spoton/src/connect.rs
    - Plugins/SpotOn/Connect.pm
    - Plugins/SpotOn/Unified/Daemon.pm

key-decisions:
  - "GH-159 detection uses the spirc_active flag (cleared on SessionDisconnected), NOT result.is_none() — the fork's Spirc channel send succeeds even while Not Active, so the issue's suggested arm-only fix would never fire in the actual repro"
  - "/control still dispatches the command while inactive (Spirc safely ignores it) — only the status changes, minimizing behavioral surface"
  - "GH-128 primary candidate implemented as direct emission (same 'seek' notify the needs_position_sync mechanism uses) instead of setting the flag — no later Playing event is guaranteed to consume a flag after relay start"
  - "PositionAnchor cleared on TrackChanged so a relay reconnect between track change and the next Playing event performs NO resync rather than a wrong one"
  - "GH-131 uses 5000 ms (low end of issue's 5000-10000 range) — satisfies LMS's hardcoded 5s rebuffer threshold, keeps Spotify-app transport latency acceptable"

patterns-established:
  - "control_status(spirc_active, result_present, cmd): 409 for inactive transport cmds, 204 dispatched, 422 volume/seek parse failure, 404 unknown"
  - "relay_resync_position_ms(): pure extrapolation with paused-skip and <=1s guard mirroring needs_position_sync's secs > 1.0"

requirements-completed: [GH-159, GH-131, GH-128]

# Coverage metadata (#1602)
coverage:
  - id: D1
    description: "Inactive-Spirc /control play/pause/next/prev return 409 CONFLICT; active commands still 204; volume/seek 422 unchanged"
    requirement: GH-159
    verification:
      - kind: unit
        ref: "librespot-spoton/src/unified.rs#control_status_tests (5 tests: inactive_transport_is_409, active_dispatched_transport_is_204, result_absent_transport_is_409, volume_seek_unchanged, unknown_command_is_404)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Connect.pm ejects the stale stream on 409 (source-marked stop, no Web API fallback, control_cmd_rejected marker) — live repro: deselect while paused, press Play, LMS stops within ~5s"
    requirement: GH-159
    verification:
      - kind: unit
        ref: "prove -l t/ (982 tests, includes 05_perl_syntax.t)"
        status: pass
    human_judgment: true
    rationale: "End-to-end 409 path needs a rebuilt daemon binary + live Spotify app deselect — routed to consolidated Phase 76 UAT (76-08)"
  - id: D3
    description: "Sync-group master daemons spawn with --buffer-latency-ms 5000; stutter-free Connect playback on the dev sync group"
    requirement: GH-131
    verification:
      - kind: unit
        ref: "prove -l t/05_perl_syntax.t"
        status: pass
    human_judgment: true
    rationale: "Stutter behavior (3+ min continuous playback on two squeezelite instances) is only observable live — routed to 76-08 UAT"
  - id: D4
    description: "Mid-song Connect handoff: LMS receives a fresh position notification at relay start; Spotify-app vs LMS bar divergence <= ~2s"
    requirement: GH-128
    verification:
      - kind: unit
        ref: "librespot-spoton/src/connect.rs#relay_resync_tests (4 tests: playing_anchor_extrapolates_by_elapsed, paused_anchor_is_skipped, missing_anchor_is_skipped, near_zero_position_is_skipped)"
        status: pass
    human_judgment: true
    rationale: "Progress-bar divergence during a real handoff needs the Spotify app + live LMS — routed to 76-08 UAT"

# Metrics
duration: 17min
completed: "2026-08-29"
status: complete
---

# Phase 76 Plan 02: Rust Connect Fixes Summary

**409 contract for Spirc-inactive control commands (with SessionDisconnected-driven spirc_active tracking — the issue's suggested arm-only fix would never have fired), Perl-side stop/eject on 409, --buffer-latency-ms 5000 for synced players, and a relay-start position resync anchored to the moment /stream actually serves audio.**

## Performance

- **Duration:** ~17 min
- **Started:** 2026-08-29T20:00:41Z
- **Completed:** 2026-08-29T20:17:30Z
- **Tasks:** 3/3
- **Files modified:** 4

## Accomplishments

- **GH-159 (Rust):** `/control/{play,pause,next,prev}` now returns 409 CONFLICT when the device is not the active Connect target. `control_status()` extracted as a testable pure function; `spirc_active` is now cleared on `PlayerEvent::SessionDisconnected` in all four event dispatchers (main + no-LMS + both reconnect-respawn variants).
- **GH-159 (Perl):** `_sendControlCommand`'s error callback branches on 409 before the D-15 Web API fallback: warn log, `control_cmd_rejected` [DIAG] marker, source-marked `stop` dispatch to eject the stale stream, and explicitly NO Web API fallback (which would act on the user's actually-active device). All other error codes keep the fallback byte-for-byte.
- **GH-131:** `Daemon.pm` pushes `--buffer-latency-ms 5000` for `isSynced() && model ne 'group'` players, with the spawn-time limitation documented (no restart-on-sync-change per Phase 63 / GH #143).
- **GH-128:** `PositionAnchor` (position_ms, Instant, playing) maintained from Playing/Paused/Seeked/PositionCorrection events, cleared on TrackChanged/Stopped; at the `/stream` "relay starting" point (unified.rs:790-803) the relay spawns `LMS::resync_position_at_relay_start()`, which extrapolates the anchor to "now" and pushes the same `seek` notify the Phase 58 mechanism uses — so LMS's first trusted position corresponds to when audio actually flows.
- 9 new Rust unit tests (5 status-mapping + 4 resync extrapolation); `cargo test` 11/11, `prove -l t/` 982/982 green.

## Task Commits

Each task was committed atomically:

1. **Task 1: unified.rs — 409 for inactive-Spirc control commands (#159) + Rust test** - `7a5074a` (fix)
2. **Task 2: Connect.pm — 409-aware control error handling (#159 Perl side)** - `951bd75` (fix)
3. **Task 3: Daemon.pm --buffer-latency-ms (#131) + relay-start position resync (#128)** - `b2ab6b6` (fix)

## Files Created/Modified

- `librespot-spoton/src/unified.rs` - `control_status()` mapping fn + 409 arm (distinct from the H11 /stream supersession 409), SessionDisconnected → `spirc_active=false` in all 4 dispatchers, relay-start resync trigger at the "relay starting" point (lines 790-803), `lms_notify` plumbing, `control_status_tests` module
- `librespot-spoton/src/connect.rs` - `PositionAnchor` struct, `relay_resync_position_ms()` pure fn, anchor maintenance in `handle_player_event`, `LMS::resync_position_at_relay_start()`, `relay_resync_tests` module
- `Plugins/SpotOn/Connect.pm` - 409 branch in `_sendControlCommand` error callback (stop/eject, `control_cmd_rejected` marker, no fallback)
- `Plugins/SpotOn/Unified/Daemon.pm` - conditional `--buffer-latency-ms 5000` spawn arg for synced non-group players

## Decisions Made

- **spirc_active over result.is_none() for GH-159:** Verified in the pinned fork (stiefenm/librespot @ 4abb7cc) that `spirc.play()` only errors when the command channel is closed — the "will be ignored while Not Active" drop happens asynchronously inside the Spirc task AFTER a successful send. The issue's proposed arm-only change would therefore never fire in the actual repro. Fix: track activity via `SessionDisconnected` (which the fork's `handle_disconnect()` emits on every became-inactive path) and feed it into the status decision. The `(false, transport)` arm ALSO maps to 409 (handle gone / channel closed — equally "not an active target").
- **Command still dispatched while inactive:** Spirc safely ignores it; skipping dispatch would add a behavioral change with no benefit and a worse failure mode if the flag were momentarily stale.
- **Direct seek emission for GH-128** instead of arming `needs_position_sync`: the flag is only consumed by a subsequent Playing event, and none is guaranteed after relay start (Playing fires on start/un-pause/seek/underrun — not on relay attach). Direct emission uses the identical wire vocabulary (`seek`, seconds with 3 decimals) consumed by Connect.pm's CON-13 startOffset path.
- **Anchor cleared on TrackChanged:** prevents replaying the previous track's position onto a new track when the relay reconnects during a track transition (OGG-mode relays reconnect per track) — no resync is safer than a wrong one; the `<= 1s` guard additionally suppresses fresh-start jitter.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Plan's Task 1 root-cause premise corrected during the mandated verification step**
- **Found during:** Task 1 (unified.rs 409 mapping)
- **Issue:** The plan (following GH #159's analysis) assumed `result` is `None` for the four transport commands on the Spirc-inactive path. Reading the pinned fork showed the channel send SUCCEEDS while Not Active (`result = Some(())` → the `(true, _)` arm → 204), so changing only the `(false, …)` arm would not fix the reported repro.
- **Fix:** Implemented the status decision on the `spirc_active` flag and added the missing `SessionDisconnected → spirc_active=false` transitions in all four event dispatchers (previously the flag was never cleared on device deselect). The `(false, transport)` arm still maps to 409 as planned (second None path: handle gone / channel closed), and this is documented in the `control_status()` doc comment as the plan required.
- **Files modified:** librespot-spoton/src/unified.rs
- **Verification:** `cargo test` — `inactive_transport_is_409` asserts the flag-driven 409; `result_absent_transport_is_409` asserts the plan's original arm
- **Committed in:** `7a5074a` (part of task commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — the plan's Task 1 explicitly instructed verifying the None-producing paths before changing, so this is the anticipated branch of the task, executed with a wider but still task-scoped fix)
**Impact on plan:** Required for GH-159 to actually be fixed in the live repro. No scope creep beyond unified.rs.

## Issues Encountered

None — build and both test suites green on first run after each task.

## User Setup Required

None - no external service configuration required. Note: the Rust changes ship via CI binary rebuild at the next tag; for live UAT (76-08) a local `cargo build` deploy to the dev LMS is used.

## Next Phase Readiness

- All three issue-numbered behaviors are code-complete with automated gates green.
- Live-UAT entries queued for the consolidated Phase 76 UAT (76-08):
  1. **#159:** Connect playback → pause → deselect device in Spotify app → press Play from Material Skin → LMS must stop/eject within ~5s (server.log shows `control_cmd_rejected`); re-selecting restores control.
  2. **#131:** Connect playback on the dev sync group (two squeezelite instances) plays 3+ minutes without the 1s-play/10-20s-pause cycle.
  3. **#128:** Start in Spotify app, transfer mid-song; after buffer fill the app playhead and LMS UI diverge by <= ~2s (daemon log shows the "resyncing LMS position" line at relay start).
- Requires daemon binary rebuild before UAT (`cargo build` local deploy or CI).

## Self-Check: PASSED

- `librespot-spoton/src/unified.rs` — FOUND
- `librespot-spoton/src/connect.rs` — FOUND
- `Plugins/SpotOn/Connect.pm` — FOUND
- `Plugins/SpotOn/Unified/Daemon.pm` — FOUND
- Commit `7a5074a` — FOUND
- Commit `951bd75` — FOUND
- Commit `b2ab6b6` — FOUND
- `cargo test`: 11 passed / 0 failed; `prove -l t/`: 982 tests, Result: PASS

---
*Phase: 76-connect-stabilization-flac24-integration*
*Completed: 2026-08-29*
