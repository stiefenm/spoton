---
phase: 76-connect-stabilization-flac24-integration
plan: 07
subsystem: audio
tags: [soloist, connect, fake-libpulse, skip, reconnect, instrumentation, cdp]

requires:
  - phase: 76-01
    provides: S32 shim (final ring/HTTP pipeline the measurements ran against)
  - phase: 76-04
    provides: resolveSoloistFormat + canDirectStream gating (routes Connect through the LMS transcode/proxy path)
  - phase: 76-05
    provides: final Connect.pm skip/session logic (skipInitiated dispatch site)
provides:
  - t0-t4 timestamped reconnect instrumentation in fake-libpulse.c (g_debug_trace-gated) and Connect.pm ([DIAG]-gated skip_dispatch bracket)
  - Live-measured verdict on WINDOWS #5 (8s reconnect gap): FIXED in the shipping pipeline — 5 runs, t1->t3 reconnect 0.13-0.88s
  - Host-test reconnect-after-flush regression guard (7/7 ok)
affects: [76-08 consolidated UAT, ROADMAP Window-5 cleanup, connect, fake-libpulse]

actuals:
  tokens: 3900
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "External log timestamping (tail -F + date +%%H:%%M:%%S.%%3N) + 20Hz ss port polling to measure live reconnect timing without deploying instrumented binaries"
    - "One-shot g_awaiting_first_drain flag (HTTP-thread-owned, same discipline as g_flush_disconnect) to stamp the first ring drain after a flush-disconnect"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c
    - Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0
    - Plugins/SpotOn/Connect.pm
    - .planning/WINDOWS.md

key-decisions:
  - "Live measurement performed WITHOUT deploying the new instrumentation: the dev LMS runs the plugin via symlink to the main checkout, which a worktree agent must not touch — external timestamping (timestamped tail of the daemon log, server.log [DIAG] ms stamps, 20Hz ss polling of the shim port) delivered the full timeline at <=100ms precision against the merged Wave-1/2 code"
  - "Verdict FIXED, not D-13 Known Issue: the 8.000s gap does not reproduce against the final pipeline; it belonged to the pre-76-04 direct-stream configuration (S16 shim, squeezelite direct GET, no soc-flc rule)"
  - "Did NOT run `gsd-tools windows fixed 5`: ledger id 5 is the GH #151 power-state check, not the 8s gap (the plan's reference predates the ledger's actual content) — appended entry 6 (ear-level UAT re-check) instead"
  - "Host test extended with a reconnect-after-flush assertion (7/7) even though the shim was exonerated — pins the shim's half of the skip-reconnect contract against regressions"

patterns-established:
  - "Reconnect timeline vocabulary: t0 pa_stream_flush -> t1 flush-disconnect -> t2 playlist-play dispatch -> t3 new /stream client attach -> t4 first ring drain"

requirements-completed: [D-12, D-13, WIN-5]

coverage:
  - id: D1
    description: "Timestamped t0-t4 reconnect instrumentation (fake-libpulse trace lines + Connect.pm skip_dispatch DIAG bracket), debug/diagnostic-gated"
    requirement: D-12
    verification:
      - kind: unit
        ref: "make -C Plugins/SpotOn/Bin/fake-libpulse test (7/7 ok, includes new reconnect-after-flush check)"
        status: pass
      - kind: unit
        ref: "prove -l t/ (37 files, 1744 tests)"
        status: pass
    human_judgment: false
  - id: D2
    description: "8s reconnect gap verdict: FIXED — 5 live CDP-driven skip runs against the shipping pipeline, reconnect (t1->t3) 0.13-0.88s, audio resume ~1s (LMS time tracking + realtime ring drain)"
    requirement: WIN-5
    verification:
      - kind: manual_procedural
        ref: "CDP skip runs 1-5, correlated daemon log / server.log / ss-poll timelines (this SUMMARY, Timeline table)"
        status: pass
    human_judgment: true
    rationale: "Audible confirmation by ear and the PCM-only-player direct-stream path are not reachable from this rig — pinned to consolidated Phase 76 UAT (WINDOWS ledger entry 6)"

duration: 30min
completed: 2026-08-29
status: complete
---

# Phase 76 Plan 07: Window 5 — 8s Reconnect Gap Debug Summary

**Live-measured the skip-reconnect timeline with 5 CDP-driven runs against the final Wave-1/2 pipeline: the historical 8.000s gap is GONE (t1->t3 reconnect 0.13–0.88s, audio resume ~1s) — it belonged to the pre-76-04 direct-stream configuration; t0–t4 instrumentation and a reconnect-after-flush host-test guard now ship for any recurrence.**

## Performance

- **Duration:** ~30 min
- **Started:** 2026-08-29T20:58:03Z
- **Completed:** 2026-08-29T21:25:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- **Verdict on WINDOWS #5 (D-12/D-13): FIXED in the shipping pipeline.** Five live Spotify-app skips (CDP-driven, real Soloist daemon, real squeezelite player, LMS restarted onto the merged Wave-1/2 code) all reconnected the audio stream in under 1 second — against a ≤3s target and an 8.000s historical baseline.
- **t0–t4 instrumentation ships:** fake-libpulse.c now stamps pa_stream_flush (t0), flush-disconnect close (t1), client takeover/attach (t3), write-error close, and the first ring drain after a flush-disconnect (t4) with wall-clock ms timestamps (g_debug_trace-gated, one line per skip — spam-safe at level 1). Connect.pm brackets the skip path's playlist-play dispatch with a [DIAG] ms timestamp (t2).
- **Shim exonerated and guarded:** new host-test assertion proves a client reconnecting right after a flush-disconnect attaches and receives fresh audio in 0ms (7/7 host tests green).

## Timeline Measurements (Task 1)

Measured live on the dev LMS (restarted at 23:08 local to load the merged Wave-1/2 code) via externally timestamped daemon-log tail (±2ms vs. soloist's own stamps), server.log [DIAG] lines, and 20Hz `ss` polling of the shim HTTP port (45483). All times local (CEST), 2026-08-29.

| Run | Mode / path | t_click (CDP) | t0 flush | t1 flush-disc | t2 dispatch | t3 new client | t1→t3 | click→t3 |
|-----|-------------|--------------|----------|---------------|-------------|---------------|-------|----------|
| 1 | flac / skipInitiated playlist-play | 23:11:44.261 | 44.428 | 44.464 | 44.520–.569 | 44.637 | **0.17s** | 0.38s |
| 2 | flac / LMS EOF-restart | 23:13:20.862 | 21.010 | 21.050 | n/a (getNextTrack 21.614) | 21.677 | **0.63s** | 0.82s |
| 3 | flac / LMS EOF-restart | 23:13:59.661 | 59.757 | 59.801 | n/a (getNextTrack 00.504) | 00.554 | **0.75s** | 0.89s |
| 4 | pcm / LMS EOF-restart | 23:14:37.652 | 37.754 | 37.790 | n/a (getNextTrack 38.593) | 38.672 | **0.88s** | 1.02s |
| 5 | pcm / pause→skip, skipInitiated | 23:16:10.812 | 10.922 | 10.955 | 11.020–.056 | 11.084 | **0.13s** | 0.27s |

- **t4 (first ring drain):** back-computed from read_index deltas at the next TIMING sample, drain start coincides with t3 within poll granularity (≤90ms) in every run; drain proceeds at exactly realtime rate (352,800 B/s S32LE) — the reconnected client is served immediately.
- **Audio resumption:** LMS player `time` tracking shows playback of the new track starting ~0.7–1.0s after the skip click (e.g. run 1: time=49.9s at click+51s; run 3: time=13.7s at click+14.4s). Spotify's own progress bar advanced (after its known, separate stuck-corked lag). Squeezelite debug logs were unavailable (squeezelite-pulseaudio not started with debug flags) — ear-level confirmation is pinned to the consolidated Phase 76 UAT.

### Owning-hop verdict (D-12)

**The ~8s gap no longer exists in the shipping pipeline; historically it was hop t2→t3 (LMS/player-side new-stream open) in the pre-Wave configuration.** Evidence:

1. **QT-12 (2026-08-27, pre-76-01/-04/-05):** playlist play landed at skip+1.16s, but the new /stream client attached 8.000s after flush-disconnect → the missing ~7s sat between LMS's dispatch and the new GET. That environment was **direct streaming**: S16 shim, no `soc flc` rule, canDirectStream returned the daemon URL, squeezelite opened the GET itself.
2. **Today (final pipeline):** every Connect skip routes through the LMS proxy — squeezelite (formats incl. `flc`) matches the 76-03 `soc flc * *` sox profile (command ≠ '-', so LMS never direct-streams; Slim::Player::Song §469), and ProtocolHandler::new substitutes the /stream URL. LMS's own HTTP client reconnects in 0.13–0.88s on both dispatch paths.
3. **Two recovery paths observed, both fast:** (a) skipInitiated → playlist play → fresh stream open (runs 1, 5 — fires when sessionPaused preceded track_changed); (b) when skipInitiated does NOT fire (runs 2–4, active-playback skips with no preceding pause), the flush-disconnect itself acts as stream-EOF and LMS's track-advance re-opens the stream ~0.6–0.9s later via the dead-Connect-URL translation in getNextTrack. The QT-12 flush-disconnect mechanism is therefore load-bearing for both paths.
4. **Shim (hop b) exonerated:** host-test reconnect-after-flush check attaches + drains in 0ms; live t3→t4 ≈ 0.

Residual (not reproducible on this rig): a player WITHOUT `flc` capability would take the `soc pcm * *` '-' profile → direct streaming → the squeezelite-side reconnect behavior of the QT-12 era. Flagged in WINDOWS ledger entry 6 together with the ear-level check; the shipped t0–t4 instrumentation makes any recurrence immediately measurable from logs.

## Task Commits

1. **Task 1: Instrument every hop + capture live timeline** - `c47063c` (feat) — instrumentation + rebuild; timeline captured live (5 runs, table above)
2. **Task 2: Fix owning hop or document (FIXED branch)** - `f374cdf` (test) — reconnect-after-flush host-test guard, WINDOWS ledger entry 6

## Files Created/Modified

- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — ms-timestamped trace lines (t0/t1/t3/t4 + takeover/write-error closes, g_debug_trace-gated); `g_awaiting_first_drain` one-shot flag; new reconnect-after-flush host-test block (7/7)
- `Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0` — rebuilt from the instrumented source
- `Plugins/SpotOn/Connect.pm` — [DIAG] skip_dispatch / skip_dispatch_done ms bracket around the skip path's playlist-play dispatch (t2)
- `.planning/WINDOWS.md` — entry 6 appended (76-07 UAT re-check: ear-level + PCM-only direct path)

## Decisions Made

- **Measure without deploying:** the dev LMS loads the plugin via symlink to the main checkout, which this worktree agent must not modify. Main checkout and worktree were verified byte-identical for the measured files (Wave-1/2 merged), so an LMS restart + external timestamping (timestamped `tail -F` of the daemon log, server.log ms stamps, 20Hz `ss` polling) measured the exact shipping pipeline with ≤100ms precision — sufficient for an 8-second question by two orders of magnitude.
- **FIXED, not D-13:** documented the gap as resolved rather than a Known Issue; TROUBLESHOOTING.md deliberately untouched (Known-Issue entry only belongs to the not-taken D-13 branch).
- **Kept all new instrumentation:** level-1 lines fire once per skip cycle — no spam; they are the permanent measuring stick for this class of bug.

## Deviations from Plan

**1. [Rule 3 - Blocking] Plan's `windows fixed 5` targets the wrong ledger entry — not executed**
- **Found during:** Task 2
- **Issue:** The plan (authored before the ledger was populated) says to mark "WINDOWS.md #5" fixed via `gsd-tools windows fixed 5`. The actual ledger was created today by Wave-1/2 agents; its id 5 is the GH #151 power-state check. Running the command would have closed an unrelated open verify.
- **Fix:** Skipped the command; appended ledger entry 6 recording this plan's outstanding human-check (ear-level skip verification + PCM-only-player direct path) so the ship gate still sees it. The ROADMAP "Window 5" line item is 76-08's cleanup territory (this agent must not touch ROADMAP.md) — **76-08 should mark ROADMAP's Window-5 item as fixed-and-verified, citing this SUMMARY.**
- **Files modified:** .planning/WINDOWS.md
- **Committed in:** f374cdf

**2. [Rule 1 - Environment] Live LMS was running pre-Wave code — restarted before measuring**
- **Found during:** Task 1 precondition/setup
- **Issue:** LMS had been started at 18:26, before the Wave-1/2 merges landed in the main checkout (22:30/22:56) — measurements would have run against the OLD pipeline, violating the plan's Wave-3 rationale.
- **Fix:** `sudo systemctl restart lyrionmusicserver` (sanctioned dev-box operation); verified the respawned Soloist daemon (pid 534664) loaded the merged S32 shim.
- **Files modified:** none

---

**Total deviations:** 2 (1 wrong-target command skipped, 1 environment fix)
**Impact on plan:** No scope creep; deviation 1 prevented corrupting an unrelated ledger entry.

## Issues Encountered

- The skipInitiated heuristic (QT-12) only fires when the daemon announces a pause before track_changed — 3 of 5 real app-skips took the other path (flush-disconnect → LMS EOF-restart). Both paths recover sub-second, so this is an observation, not a defect; noted for future work on GH #158/#131 sync-group behavior.
- The known, separate "stuck corked" issue (fakepulse-timing-buffer, tracked in `.planning/debug/fakepulse-timing-buffer.md`) was visible again during setup (Spotify progress bar at 0:00 while audio flowed; corked=1 in TIMING lines). Unrelated to the reconnect gap — playback and skips worked throughout; it self-resolved as before.
- Test-rig notes for the next session: Spotify Desktop needed `--remote-debugging-port` + `--remote-allow-origins='*'` (RESEARCH Pitfall 7 confirmed); the spotify-control skill's `tools/spotify-cdp.js` is still absent — the ad-hoc python websocket-client fallback (scratchpad `cdp.py`) worked. The CDP instance was killed after the session (threat model T-76-15).

## Known Stubs

None — no stubbed code. The single unrun verification (ear-level audible check + PCM-only direct path) is recorded in `.planning/WINDOWS.md` entry 6 and pinned to the consolidated Phase 76 UAT.

## Threat Flags

None — no new network/auth/file surface. New trace lines log timestamps, fds, and byte counts only (T-76-16 mitigation applied); the CDP `--remote-allow-origins=*` flag was test-session-only and the instance was killed (T-76-15).

## Next Phase Readiness

- 76-08 (consolidated UAT + ROADMAP cleanup) can mark the ROADMAP "Window 5 8s-Gap" item fixed, citing the measurements here, and should include one ear-level Skip-Next check (WINDOWS ledger entry 6) in the UAT run.
- The t0–t4 instrumentation is live in the committed shim/Connect.pm — any future reconnect regression is measurable from logs alone (enable diagnosticMode + SPOTON_FAKEPULSE_DEBUG, both already standard on the dev rig).

## Self-Check: PASSED

- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — FOUND
- `Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0` — FOUND
- `Plugins/SpotOn/Connect.pm` — FOUND
- `.planning/WINDOWS.md` — FOUND
- Commit `c47063c` — FOUND
- Commit `f374cdf` — FOUND
- `make -C Plugins/SpotOn/Bin/fake-libpulse test` — 7/7 ok (>=6 required)
- `prove -l t/` — 37 files, 1744 tests, all passing

---
*Phase: 76-connect-stabilization-flac24-integration*
*Completed: 2026-08-29*
