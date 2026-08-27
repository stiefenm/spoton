---
phase: 73-soloist-connect-mode
plan: 05
subsystem: connect
tags: [perl, websocket, json-xs, protocol-websocket, soloist]

# Dependency graph
requires:
  - phase: 73-soloist-connect-mode (73-01/73-02)
    provides: SoloistWS.pm WS client, D-06 event->spottyconnect translation table
provides:
  - "_onMessage octet bridge: UTF8-flagged character-string frames (as Protocol::WebSocket::Frame::next returns) are re-encoded to octets before from_json, fixing the malformed-JSON drop on every playback_state frame with non-ASCII metadata"
  - "sendCommand numeric coercion: position_ms/volume are re-cast via int() before to_json, so a previously-stringified scalar can never reach the wire as a quoted JSON string"
  - "sessionPaused state: gates 'resume' emission to real Paused->Playing transitions, recognizes 'buffering' as a no-op, and freezes wallclock position extrapolation while paused"
affects: [73-06, phase-74-per-player-backend]

actuals:
  tokens: 5380
  tasks: 2
  commits: 4

tech-stack:
  added: []
  patterns:
    - "JSON::XS decode_json expects octets, never characters -- any Perl string that may carry the utf8 flag (Encode::decode output) must be bridged with utf8::encode/utf8::is_utf8 immediately before from_json"
    - "Numeric params crossing into a JSON encoder must be re-cast with int()/0+ at the single choke point (sendCommand), never trusted from caller context, to avoid JSON::XS's dualvar string-quoting quirk"
    - "sessionPaused as the single source of truth for 'is the daemon currently paused' -- set from three independent signals (playback_changed status, playback_state snapshot status, position_sync speed) and read by both the resume-gate and the position-extrapolation frozen-elapsed rule"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Unified/SoloistWS.pm
    - t/31_soloist_ws.t
    - t/32_soloist_events.t

key-decisions:
  - "Reproduced the JSON::XS dualvar string-quoting bug for the test harness using a pure-PV scalar (sprintf('%d', ...), no IOK) rather than the plan's literal int()+interpolation repro -- Devel::Peek confirmed that under this environment's JSON::PP, an IOK+POK dualvar (int() then interpolated) already serializes as a bare number, so the plan's literal repro would not have produced a genuine RED failure in the JSON::PP-based test harness (JSON::XS's specific POK-over-IOK quoting quirk isn't reproducible via pure-Perl JSON::PP). The pure-string reproduction demonstrates the identical wire-format defect (a stringified numeric param reaching to_json unquoted-vs-quoted) and gives a real RED->GREEN gate."
  - "sendCommand's int() coercion is a single choke point covering both Connect.pm's Connect-seek path and _bufferedBrowseSeek's browse-seek path, per plan -- no changes to Connect.pm were needed or made."

requirements-completed: [D-05, D-06]

coverage:
  - id: D1
    description: "_onMessage bridges UTF8-flagged character-string frames (non-ASCII playback_state metadata) to octets before from_json, so they no longer fail decode and drop"
    requirement: "D-05"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t#_onMessage on a UTF8-flagged character string does not die / updates lastPositionMs from position.position_ms"
        status: pass
      - kind: unit
        ref: "t/31_soloist_ws.t#_onMessage on plain-octet input still updates lastPositionMs (no regression)"
        status: pass
    human_judgment: false
  - id: D2
    description: "sendCommand coerces position_ms/volume to fresh numeric IVs before to_json, so a previously-stringified value never reaches the wire quoted"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t#sendCommand('seek') does not quote a previously-stringified position_ms / serializes position_ms as a bare number"
        status: pass
      - kind: unit
        ref: "t/31_soloist_ws.t#sendCommand('set_volume') does not quote a previously-stringified volume / serializes volume as a bare number"
        status: pass
    human_judgment: false
  - id: D3
    description: "'resume' is emitted only for a real Paused->Playing transition (sessionPaused-gated), carrying the pause-position baseline, and triggers a get_state reconciliation"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t#playback_changed(playing) after a real pause emits resume at the pause-position baseline / resume sends a get_state command"
        status: pass
      - kind: unit
        ref: "t/32_soloist_events.t#playback_changed status=playing after a real pause emits 'resume' / playback_changed status=playing with no preceding pause emits no resume"
        status: pass
    human_judgment: false
  - id: D4
    description: "'buffering' playback_changed status is a recognized no-op; wallclock position extrapolation freezes while paused (position_sync and playback_state)"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "t/32_soloist_events.t#playback_changed status=buffering emits nothing (recognized no-op)"
        status: pass
      - kind: unit
        ref: "t/31_soloist_ws.t#playback_state snapshot at the pause position after >SEEK_THRESHOLD elapsed emits no seek (frozen baseline while paused)"
        status: pass
      - kind: unit
        ref: "t/31_soloist_ws.t#position_sync with speed=0 and a position far from baseline emits seek (app-side seek while paused)"
        status: pass
    human_judgment: false
  - id: D5
    description: "Live re-verification against the running Soloist daemon: LMS-side seek reaches Spotify, Spotify-app resume continues at the pause position, zero malformed-JSON drops during a real pause/resume/seek/skip cycle"
    verification: []
    human_judgment: true
    rationale: "Requires a live LMS + Soloist daemon + Spotify app UAT session (73-UAT.md Test 2 re-run) -- not reproducible in the isolated Perl unit-test harness used for this plan's regression tests."

duration: 35min
completed: 2026-08-27
status: complete
---

# Phase 73 Plan 05: Soloist WS Wire-Format + Resume-Gating Gap Closure Summary

**Fixed two live-verified SoloistWS.pm wire-format defects (UTF8-flagged JSON frames silently dropped, numeric position_ms/volume silently quoted) and gated 'resume' emission to real Paused->Playing transitions with a frozen position baseline while paused — closing UAT gaps 1 (resume-at-0) and 2 (LMS seek never reaching Spotify).**

## Performance

- **Duration:** 35 min
- **Started:** 2026-08-27T08:20:00Z (approx, per plan's diagnosis session)
- **Completed:** 2026-08-27T08:56:31Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- `_onMessage` re-encodes UTF8-flagged character strings (as the vendored `Protocol::WebSocket::Frame::next` returns) back to octets via `utf8::encode`/`utf8::is_utf8` before `from_json` — every `playback_state` frame carrying non-ASCII track/artist metadata now decodes instead of being silently dropped as malformed JSON.
- `sendCommand` re-casts `position_ms`/`volume` via `int()` before `to_json`, closing the JSON encoder dualvar-quoting risk that made the daemon reject LMS-originated seeks with "invalid JSON or missing required fields".
- New `sessionPaused` state, set from three independent signals (`playback_changed` status, `playback_state` snapshot status, `position_sync` speed:0), gates `resume` emission to real Paused→Playing transitions (previously fired on every `playing` status, including the buffering→playing sequence after every track change) and freezes the wallclock position-extrapolation baseline while paused.
- `'buffering'` is now a recognized no-op in `_onPlaybackChanged` instead of logging as an unrecognized status.
- On resume: the wallclock anchor (`lastPositionTs`) restarts and a `get_state` command is sent for post-resume drift reconciliation through the existing tolerance-gated seek path.

## Task Commits

Each task followed RED (failing test) → GREEN (fix) TDD:

1. **Task 1: Wire-format fixes — inbound character-string JSON, outbound numeric params**
   - `fab6bba` test(73-05): add failing tests for wire-format fixes (D-05/D-06)
   - `4d6ad38` fix(73-05): SoloistWS wire-format — octet bridge + numeric coercion (D-05/D-06)
2. **Task 2: Pause-aware position baseline + resume emission gating**
   - `98b0cf9` test(73-05): add failing tests for pause-aware resume gating (D-06)
   - `8adbd1e` feat(73-05): pause-aware position baseline + resume gating (D-06)

_TDD tasks each produced exactly a test → feat/fix commit pair (no refactor step needed)._

## Files Created/Modified
- `Plugins/SpotOn/Unified/SoloistWS.pm` — `_onMessage` octet bridge, `sendCommand` numeric coercion, `sessionPaused` accessor + resume-gating + frozen-extrapolation logic in `_onPlaybackChanged`/`_onPositionSync`/`_onPlaybackState`
- `t/31_soloist_ws.t` — octet-mode `from_json` stub, 8 new regression tests (character-string decode, plain-octet regression, numeric seek/volume serialization, pause/resume sequence with get_state, frozen extrapolation, app-side seek while paused)
- `t/32_soloist_events.t` — octet-mode `from_json` stub, 3 new/updated tests (buffering no-op, resume-gating positive/negative, updated existing resume test to seed `sessionPaused`)

## Decisions Made
- The plan's literal test-repro suggestion for the numeric-quoting bug (`my $n = int(145791.4); my $x = "p=$n";`) was adapted: `Devel::Peek` confirmed this environment's `JSON::PP` already serializes that IOK+POK dualvar as a bare number (unlike production's `JSON::XS`, which is documented to prefer a cached PV over IOK). Using a pure-string reproduction (`sprintf('%d', ...)`, no IOK flag at all) gave a test that genuinely fails before the `int()` fix and passes after, under the JSON::PP-based test harness — same wire-format contract, reproducible RED/GREEN gate.
- No changes to `Connect.pm` — confirmed by the plan's diagnosis and by the resulting fix: both bugs were entirely internal to `SoloistWS.pm`'s wire encode/decode paths.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Test correctness] Adapted the numeric-quoting test reproduction to actually fail under JSON::PP**
- **Found during:** Task 1 (writing the RED tests)
- **Issue:** The plan's suggested reproduction (`int()` then string-interpolate) produces a dualvar that retains the `IOK` flag; this environment's `JSON::PP` (used by the test stub, since there is no `JSON::XS` in this dev environment) treats `IOK`-flagged scalars as numbers regardless of any cached `PV`, so the literal repro would pass even without the fix — violating the TDD fail-fast rule ("a test passes unexpectedly during RED must be investigated").
- **Fix:** Used a pure-string reproduction (`sprintf('%d', 145791.4)`, verified via `Devel::Peek` to carry only the `POK` flag, no `IOK`) which `JSON::PP` does quote as a JSON string before the fix and does not after `sendCommand`'s `int()` coercion — a faithful, environment-appropriate regression test for the same wire-format contract.
- **Files modified:** `t/31_soloist_ws.t`
- **Verification:** Confirmed RED (quoted output, test fails) before the fix, GREEN (unquoted output, test passes) after.
- **Committed in:** `fab6bba` (RED), `4d6ad38` (GREEN)

**2. [Rule 1 - Test update for behavior change] Updated the pre-existing "playback_changed playing emits resume" test in t/32**
- **Found during:** Task 2
- **Issue:** The existing t/32 test asserted `resume` fires on every `playing` status without a preceding pause — this is exactly the spurious-resume behavior Task 2 removes.
- **Fix:** Seeded `sessionPaused => 1` in that test case (a real prior pause) so it continues to pin the correct, narrower contract (resume-after-real-pause), and added a new adjacent test asserting the negative case (playing with no preceding pause emits nothing).
- **Files modified:** `t/32_soloist_events.t`
- **Verification:** Both the updated and new test pass after the Task 2 fix.
- **Committed in:** `98b0cf9` (RED), `8adbd1e` (GREEN)

---

**Total deviations:** 2 auto-fixed (both Rule 1 — test-construction corrections needed to keep the TDD RED/GREEN gate genuine in this dev environment). No scope creep; no production-code deviations from the plan's action items.

## Issues Encountered
- This dev environment has no `JSON::XS` installed (`prove` relies on the `JSON::XS::VersionOneAndTwo` stub delegating to `JSON::PP`), and `JSON::PP` does not reproduce JSON::XS's specific dualvar-quoting quirk for `int()`-then-stringified scalars. Investigated with `Devel::Peek` and worked around by using a pure-PV-flag string reproduction instead — see Deviation 1. The `sendCommand` fix itself (`int()` coercion) is unaffected and correct regardless of which JSON backend the live daemon connection uses.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Both UAT gaps (resume-at-0, LMS seek not reaching Spotify) are fixed at the unit level with regression coverage; `prove -l t/` is fully green (32 files, 1338 tests).
- **Still outstanding (per plan's `<verification>` section, D5 in the coverage table above):** a live re-run of 73-UAT.md Test 2 (bidirectional Connect loop) against the actual running Soloist daemon is required to confirm the fix end-to-end (LMS seek mirrors in the Spotify app within ~1s with no daemon error reply; app-side pause→resume continues at the pause position; zero malformed-JSON warnings during a full pause/resume/seek/skip cycle). This is a human/live-environment verification step, not automatable in this unit-test harness.
- 73-06 (fake-libpulse flush gap closure) is the remaining plan in this phase's gap-closure set.

---
*Phase: 73-soloist-connect-mode*
*Completed: 2026-08-27*

## Self-Check: PASSED

All claimed files exist (`Plugins/SpotOn/Unified/SoloistWS.pm`, `t/31_soloist_ws.t`, `t/32_soloist_events.t`, this SUMMARY). All 4 claimed commits (`fab6bba`, `4d6ad38`, `98b0cf9`, `8adbd1e`) verified present in `git log`.
