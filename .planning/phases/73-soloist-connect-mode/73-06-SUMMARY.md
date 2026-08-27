---
phase: 73-soloist-connect-mode
plan: 06
subsystem: soloist-audio-transport
tags: [c, pthreads, fake-libpulse, ring-buffer, soloist, gap-closure]

# Dependency graph
requires:
  - phase: 73-soloist-connect-mode (73-01)
    provides: fake-libpulse.c HTTP streaming mode (D-04) -- ring buffer, /stream server, _stream_refresh_timing
provides:
  - "pa_stream_flush real ring flush: discards all buffered ring bytes and wakes any producer blocked on ring space, host-test-verified"
  - "_ring_flush(ring_buffer_t*) helper reusable by any future flush-adjacent path"
affects: []

actuals:
  tokens: 2600
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "Ring-buffer flush = reset tail=head, fill=0 under the existing lock + broadcast the existing space_avail condvar -- no allocation, no new blocking path, matches the file's existing _ring_push/_ring_pop_timed locking discipline"
    - "HTTP-mode-only guard on pa_stream_flush (g_http_mode check) preserves the non-HTTP (Phase 71/72 synchronous-forward) path's existing no-op behavior byte-for-byte"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c
    - Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0

key-decisions:
  - "Flush test reuses the already-connected /stream client from the existing conversion check (per plan) by toggling g_ring.client_connected directly (same direct-struct-access technique already used by the drop-oldest and writable_size tests later in the file), rather than opening a new connection -- keeps the test faithful to the plan's 'reusing its already-connected /stream client' instruction while still preventing the second (to-be-flushed) pattern from draining out before the flush can be observed."
  - "_stream_refresh_timing(s) is called immediately after _ring_flush inside pa_stream_flush (not left to the next natural pa_stream_get_timing_info/pa_stream_update_timing_info call) so Soloist's read_index catches up to write_index synchronously with the flush, matching the plan's stated rationale (read_index lag is what produces the stuck-at-0/1s Spotify progress symptom)."

requirements-completed: [D-04]

coverage:
  - id: D1
    description: "pa_stream_flush discards all audio currently buffered in the ring; a subsequent GET /stream client only ever receives bytes written after the flush"
    requirement: "D-04"
    verification:
      - kind: unit
        ref: "fake-libpulse.c FAKE_LIBPULSE_TEST main() -- flush test: writes a second pattern, flushes, writes a third pattern, confirms only the third pattern's S16LE bytes are ever served over /stream"
        status: pass
    human_judgment: false
  - id: D2
    description: "A flush wakes any pa_stream_write blocked on ring space, and pa_stream_writable_size reports full capacity again immediately after flush"
    requirement: "D-04"
    verification:
      - kind: unit
        ref: "fake-libpulse.c FAKE_LIBPULSE_TEST main() -- flush test: writable_size shrinks after the unread second-pattern write, then reports RING_CAPACITY again immediately after pa_stream_flush"
        status: pass
    human_judgment: false
  - id: D3
    description: "The flush success callback fires exactly once per pa_stream_flush call"
    requirement: "D-04"
    verification:
      - kind: unit
        ref: "fake-libpulse.c FAKE_LIBPULSE_TEST main() -- flush test: static counter callback asserted == 1 after the flush call"
        status: pass
    human_judgment: false
  - id: D4
    description: "Live UAT re-verification: an app-side Skip Next no longer drains ~4s of stale prior-track PCM, and the Spotify app's progress bar no longer sits at 0/1s for the first seconds of a new track"
    verification: []
    human_judgment: true
    rationale: "Requires rebuilding libpulse.so.0 natively, deploying to the running dev LMS + Soloist daemon, and re-running 73-UAT.md gap-3 Skip Next scenario with a real Spotify app session -- not reproducible in the host-test harness, which has no LMS/Soloist process to observe end-to-end."

duration: 20min
completed: 2026-08-27
status: complete
---

# Phase 73 Plan 06: fake-libpulse pa_stream_flush Ring Flush Summary

**Implemented `pa_stream_flush` as a real ring-buffer flush in fake-libpulse.c (HTTP streaming mode), closing the transport-level portion of UAT gap 3 (Spotify→LMS skip: long audible delay + progress stuck at 0/1s) — pinned by a new host-test flush check.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-08-27 (this session)
- **Completed:** 2026-08-27
- **Tasks:** 2
- **Files modified:** 2 (`fake-libpulse.c`, rebuilt `libpulse.so.0`)

## Accomplishments
- Added `_ring_flush(ring_buffer_t *r)`: under the ring's existing lock, resets `tail = head` and `fill = 0`, then broadcasts the existing `space_avail` condvar so any `pa_stream_write` blocked on a full ring wakes immediately with fresh audio instead of waiting on a now-nonexistent backlog.
- Wired `_ring_flush` + an immediate `_stream_refresh_timing(s)` into `pa_stream_flush`, gated to HTTP mode only (`g_http_mode`) — the non-HTTP (Phase 71/72 synchronous-forward) path keeps its prior no-op behavior byte-for-byte since nothing is buffered there.
- Previously `pa_stream_flush` only invoked the success callback and left the ring untouched — every app-side skip/seek left up to `RING_CAPACITY` (~4.0s at 44.1kHz/2ch/S16) of stale prior-track PCM draining out to the player, and `_stream_refresh_timing`'s `read_index` (write_index minus ring fill) stayed inflated by that same stale fill, which is what made Soloist's cluster-reported position (the Spotify app's progress bar) sit near zero for the first seconds of the new track.
- Extended the `FAKE_LIBPULSE_TEST` host-test harness with a new flush check (reusing the already-connected `/stream` client from the existing conversion check): writes a second pattern and confirms `pa_stream_writable_size` shrinks, calls `pa_stream_flush` and confirms `writable_size` returns to full `RING_CAPACITY` and the success callback fired exactly once, then writes a third pattern and confirms only its bytes are ever served over `/stream` — the flushed second pattern never arrives.
- Host test now reports 6 `ok:` lines (5 before this plan: port-announce, conversion, WR-11, drop-oldest, writable_size — this plan adds the new flush check as the 3rd line).

## Task Commits

1. **Task 1: Implement pa_stream_flush as a real ring flush**
   - `6c8ed0f` feat(73-06): implement pa_stream_flush as a real ring flush (D-04)
2. **Task 2: Host-test coverage for flush semantics**
   - `739f099` test(73-06): host-test coverage for pa_stream_flush ring-flush semantics

## Files Created/Modified
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — `_ring_flush` helper, `pa_stream_flush` real-flush implementation (HTTP-mode-gated), new flush host-test check
- `Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0` — rebuilt shared object (Task 1 only; Task 2's test-harness additions live entirely inside `#ifdef FAKE_LIBPULSE_TEST`, never linked into the `.so`, so it is byte-identical after Task 2's rebuild)

## Decisions Made
- The flush test toggles `g_ring.client_connected` directly (same direct-struct-access technique the file's existing drop-oldest and writable_size tests already use) rather than opening a second connection, so it can accumulate an unread pattern in the ring for the pre-flush `writable_size` assertion while still reusing the single already-connected `/stream` client the plan specified, for the post-flush byte-content assertion.
- `_stream_refresh_timing(s)` is called synchronously inside `pa_stream_flush` (immediately after `_ring_flush`), not deferred to the next natural timing-info call, so `read_index` catches up to `write_index` at the same moment the flush completes — directly addressing the plan's diagnosis of the stuck-progress symptom.

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written. Both tasks' `<action>` steps were followed literally; the only implementation choice left open by the plan (exact test pattern values and the toggle-vs-reconnect technique for accumulating unread ring bytes) was resolved per the "Decisions Made" section above, staying within the plan's explicit instruction to reuse the already-connected client.

## Issues Encountered
None. Build was warning-clean with `-Wall -Wextra` on the first attempt; host test passed on first run and was re-run 5 additional times to confirm no flakiness in the client_connected-toggle technique (deterministic pass every time, since the toggle happens under the ring's own lock and the http server thread's 50ms poll tick only observes the ring state through that same lock).

## User Setup Required
None — no external service configuration required for this plan's automated verification.

**Live UAT re-verification is still required** (see coverage D4 above and the plan's `<verification>` note): the deployed `libpulse.so.0` on the dev LMS must be rebuilt from this source (`make -C Plugins/SpotOn/Bin/fake-libpulse all`) and redeployed per the local-deploy convention, then 73-UAT.md's gap-3 Skip Next scenario re-run against a live Spotify app session to confirm the ring-attributable delay and stuck-progress symptoms are gone (residual squeezelite-buffer delay, ~2-3s on the dev player, is expected and out of scope — documented pre-existing behavior, identical on the librespot Connect path).

## Next Phase Readiness
- All three of this phase's UAT gaps now have committed, unit-verified fixes: gap 1 (resume-at-0) and gap 2 (LMS seek not reaching Spotify) from 73-05, and gap 3's fake-libpulse ring-flush component from this plan.
- Remaining before the phase can be considered fully closed: a single live UAT session re-running 73-UAT.md Test 2 (bidirectional Connect loop) and the gap-3 Skip Next scenario end-to-end against a rebuilt/redeployed `libpulse.so.0` and the running Soloist daemon.
- Residual gap-3 delay from squeezelite's own output buffer draining old PCM (~2-3s on the dev player, more on Radio/Touch hardware) is pre-existing, documented, cross-path (librespot Connect has the same behavior), and explicitly out of scope for this gap-closure plan.

---
*Phase: 73-soloist-connect-mode*
*Completed: 2026-08-27*

## Self-Check: PASSED

All claimed files exist (`Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c`, `Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0`, this SUMMARY). Both claimed commits (`6c8ed0f`, `739f099`) verified present in `git log`.
