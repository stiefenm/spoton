---
phase: 73-soloist-connect-mode
plan: 02
subsystem: infra
tags: [perl, websocket, lms-plugin, protocol-websocket, daemon-lifecycle]

requires:
  - phase: 73-soloist-connect-mode (plan 01)
    provides: Unified::SoloistDaemon lifecycle class, Unified::SoloistWS event client + spottyconnect translation, vendored Protocol::WebSocket
provides:
  - Backend-dispatched Connect control path — Connect.pm's LMS-side forwarders (_onPause/_onVolume/_onSeek/_onPlaylistJump) route through SoloistWS commands for soloist-backend players, with the existing Web API fallback (D-15) preserved
  - Full Soloist WS command surface — sendRepeatMode (Pitfall-6 corrected two-command matrix)/sendShuffle wrappers, T-22-01 uri validation choke point, lastCommand-context error logging
  - Reconnect resync — logged_in auth_state triggers get_state; playback_state snapshot reconciles track/volume/position against the prior session baseline with SEEK_THRESHOLD tolerance
  - Build-expiry hardening (Pitfall 7) — exit-code-10 permanently parks a SoloistDaemon (spoton_soloist_expired cache flag), startHelper's soloist branch refuses to resurrect it, Soloist::_versionCheck self-heals the flag on next successful activation
  - Expiry-days capture — soloist's "client expires in N days" stdout line parsed once per daemon start into spoton_soloist_expiry_days (host-global, for 73-04 Settings)
  - t/31 (extended) + t/32 (new) — full command-map/repeat-matrix/reconnect-resync unit coverage and the complete D-06 event->spottyconnect mapping table pinned by tests
affects: [73-03-soloist-browse, 73-04-soloist-cleanup]

actuals:
  tokens: 13300
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Single dispatch point (Connect.pm's _sendControlCommand) resolving the player's helper class before choosing HTTP vs WS control transport, falling through to the same Web API fallback either way"
    - "1-deep lastCommand tracking on a WS client for actionable error-context logging without a full request queue"
    - "Exit-code classification of a dead Proc::Background handle (via ->wait, already-reaped by the preceding ->alive check) to distinguish a permanent failure mode from a transient crash"
    - "Self-healing escalation flags: the same code path that validates/activates a resource (Soloist::_versionCheck) clears the flag that a different subsystem (DaemonManager) set on failure"

key-files:
  created:
    - t/32_soloist_events.t
  modified:
    - Plugins/SpotOn/Connect.pm
    - Plugins/SpotOn/Unified/SoloistWS.pm
    - Plugins/SpotOn/Unified/DaemonManager.pm
    - Plugins/SpotOn/Unified/SoloistDaemon.pm
    - Plugins/SpotOn/Soloist.pm
    - t/31_soloist_ws.t

key-decisions:
  - "Connect.pm's _sendControlCommand resolves the helper via DaemonManager->helperForClient and isa-checks for SoloistDaemon as the FIRST thing it does, before any librespot HTTP-port logic -- the librespot path below is byte-identical to before this plan"
  - "Endpoint->command translation table lives inline in _sendControlCommand (not in SoloistWS) since it's a Connect.pm-specific wire-protocol concern (the /control/* vocabulary is librespot's, not Soloist's)"
  - "sendRepeatMode follows the RESEARCH Pitfall-6 FOOTNOTE, not the official docs' self-contradictory table: off=(false,false), context=(true,false), track=(false,true); any unrecognized mode is treated as 'off' (fail-safe)"
  - "Booleans in WS command params are encoded as \\1/\\0 scalar refs (JSON::XS/JSON::PP native boolean idiom), not JSON::XS::true() -- keeps the isolated-require test harness (which stubs JSON::XS::VersionOneAndTwo, not real JSON::XS) able to decode them without an extra stub"
  - "URI validation (T-22-01/T-73-07) lives inside sendCommand() itself as a single choke point for any command carrying a uri param, not duplicated per call site"
  - "playback_state reconciliation only emits corrections when sessionActive is already true -- a cold snapshot (no active session yet) seeds lastTrackId/lastPositionMs/lastVolume silently, since there is nothing yet to have drifted from"
  - "Exit-code-10 detection uses Proc::Background's ->wait + >>8 (per RESEARCH literal guidance) rather than the module's newer exit_code() accessor -- functionally equivalent here since the preceding ->alive call already triggered a non-blocking reap, but kept as a documented, eval-guarded best-effort read"
  - "Soloist::_versionCheck's success branch is the single self-heal site for spoton_soloist_expired -- a re-downloaded/replaced copy of the pinned version un-parks the daemon with no manual cache-flush step"
  - "spoton_soloist_expiry_days is host-global (not per-player) -- the pinned soloist binary is shared across all players on a host, so last-writer-wins is an acceptable simplification for a Settings display"

patterns-established:
  - "Wave-0-style isolated-require test harness (write_stub + unshift @INC) copied per test file rather than factored into a shared helper module, matching the existing t/28/t/31 convention"

requirements-completed: [D-05, D-06]

coverage:
  - id: D1
    description: "SoloistWS full command-map serialization (pause/play/skip_next/skip_prev/seek/set_volume/add_to_queue/get_state/get_queue/activate/deactivate) and the sendRepeatMode/sendShuffle two-command matrix (Pitfall-6 footnote)"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t"
        status: pass
      - kind: unit
        ref: "t/32_soloist_events.t"
        status: pass
    human_judgment: false
  - id: D2
    description: "Reconnect resync: logged_in auth_state triggers get_state; playback_state snapshot reconciles track/volume (mismatch emits change/volume) and position (SEEK_THRESHOLD-gated seek) against the prior WS session baseline; a cold snapshot with no active session emits no correction"
    requirement: "D-05"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t"
        status: pass
    human_judgment: false
  - id: D3
    description: "Complete D-06 event->spottyconnect mapping table: track_changed start/change, playback_changed stop-collapse (paused+stopped) + resume-with-position, volume_changed boundary passthrough, position_sync tolerance, device_changed start/stop, auth_state/context_changed/options_changed/queue_changed no-emission, unknown-type no-die, Connect-toggle-off and malformed-JSON-burst gating"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "t/32_soloist_events.t"
        status: pass
    human_judgment: false
  - id: D4
    description: "Connect.pm backend dispatch: _sendControlCommand routes soloist-backend players' pause/play/next/prev/seek/volume through SoloistWS commands, falling back to the existing Web API path (D-15) when the WS is down or a command fails; librespot HTTP path unchanged"
    requirement: "D-06"
    verification:
      - kind: other
        ref: "grep-based acceptance checks (SoloistDaemon isa reference, _sendControlFallback reuse) against Plugins/SpotOn/Connect.pm; t/05_perl_syntax.t isolated-require confirms the modified module still loads"
        status: pass
    human_judgment: true
    rationale: "No unit harness invokes Connect.pm's private _sendControlCommand with a live/fake SoloistDaemon helper end-to-end (would require simulating a connected WS + a real player client) -- verified by code review, the plan's own grep-based acceptance criteria, and the underlying SoloistWS command tests. True end-to-end behavior (LMS action -> WS command -> Spotify app reaction, and the WS-down fallback firing) requires a live LMS + paired Soloist daemon + Spotify app; parked as UAT (WINDOWS.md #1)."
  - id: D5
    description: "Build-expiry escalation (Pitfall 7): a SoloistDaemon exiting with code 10 is classified and permanently parked (spoton_soloist_expired, 'never' TTL) instead of entering the generic CRASH_BACKOFF restart loop; startHelper's soloist branch folds the flag into its prereq-state skip log so the 60s watchdog cannot resurrect it; Soloist::_versionCheck's success path self-heals the flag"
    requirement: null
    verification:
      - kind: unit
        ref: "t/28_soloist_dispatch.t (regression -- no behavioral change to the startHelper paths it covers)"
        status: pass
      - kind: other
        ref: "grep + inline perl -e string-presence check (per the plan's own <verify> block) against Plugins/SpotOn/Unified/DaemonManager.pm and Plugins/SpotOn/Soloist.pm"
        status: pass
    human_judgment: true
    rationale: "No fixture simulates a real dead Proc::Background process reporting exit code 10 -- the escalation path itself is not exercised end-to-end by any test, only its static presence in the code is grep-verified per the plan's own verification design. A live soloist build that has actually expired (or a wrapper script forcing rc=10) is needed to observe the real park-and-log behavior; parked as UAT (WINDOWS.md #2)."
  - id: D6
    description: "Expiry-days capture: soloist's 'client expires in N days' stdout line is parsed once per daemon start (bounded 8 KiB head read of the per-player log, after ws.port confirms the daemon is up) into a host-global spoton_soloist_expiry_days cache key for 73-04's Settings display"
    requirement: null
    verification:
      - kind: other
        ref: "grep-based acceptance check (per the plan's own <verify> block) against Plugins/SpotOn/Unified/SoloistDaemon.pm"
        status: pass
    human_judgment: true
    rationale: "No fixture provides a real per-player log file containing the 'client expires in N days' line from a live soloist process -- the regex match itself is straightforward and unit-testable in principle, but the plan's own verify block only requires a grep/string-presence check, and this plan didn't add a dedicated unit test file for SoloistDaemon.pm's log-parsing path. Confirmed correct against the RESEARCH doc's live-verified stdout line format."

duration: ~13min
completed: 2026-08-26
status: complete
---

# Phase 73 Plan 02: Soloist Connect Command Dispatch + Lifecycle Hardening Summary

**LMS-side Connect controls (pause/play/skip/seek/volume/repeat/shuffle) now route to Soloist over WebSocket with Web-API fallback; reconnects resync track/volume/position from a playback_state snapshot; an expired 90-day soloist build parks the daemon permanently instead of crash-looping forever.**

## Performance

- **Duration:** ~13 min
- **Tasks:** 3
- **Files modified:** 7 (5 modified, 1 new test file, 1 test file extended)

## Accomplishments

- Closed the D-06 loop in the LMS->Soloist direction: `Connect.pm`'s `_sendControlCommand` now resolves the player's registered helper and, for a `SoloistDaemon`, translates the librespot `/control/*` endpoint into the Soloist WS command vocabulary (`pause`, `play`, `skip_next`, `skip_prev`, `seek`+`position_ms`, `set_volume`+`volume`) and sends it over the daemon's WS connection -- falling through to the existing Spotify Web API fallback (D-15) whenever the WS is disconnected or `sendCommand` fails. The librespot HTTP control path is untouched.
- `SoloistWS` gained the full command surface: `sendRepeatMode($mode)` implements the RESEARCH Pitfall-6 **footnote** matrix (the official docs table self-contradicts) as two sequential commands (`set_repeat_context`/`set_repeat_track`), `sendShuffle($bool)` wraps `set_shuffle`, and any command carrying a `uri` param is validated against `^spotify:(?:track|episode):[A-Za-z0-9]+$` before it reaches the wire (T-22-01/T-73-07). A 1-deep `lastCommand` field gives `error` replies actionable context without a full request queue (T-73-09), and `command_result` gets its own debug-log branch.
- Reconnect resync (D-05): a `logged_in:true` `auth_state` (which arrives both unsolicited on connect and as the reply to the daemon's own `get_auth_state`) now triggers `get_state`; the `playback_state` handler reconciles track (emits `change` on mismatch), volume (emits `volume` on mismatch), and position (emits `seek` only beyond the shared `SEEK_THRESHOLD` tolerance, extrapolated from the last known position + wallclock elapsed) against whatever the WS client still believed before the drop -- closing the drift window opened while the connection was down. A cold snapshot with no prior session baseline never emits a spurious correction.
- Build-expiry hardening (Pitfall 7): `_streamAlivePoll`'s crash branch now classifies a dead `SoloistDaemon`'s exit code; code 10 (the documented 90-day build-expiry signal) escalates to a new `_handleSoloistBuildExpiry` -- a `'never'`-TTL `spoton_soloist_expired` cache flag plus `stopHelper`, mirroring `_handleCredentialCrash`'s stay-down discipline instead of restarting a permanently-dead binary every 5s-300s forever. `startHelper`'s soloist branch folds the flag into its existing prereq-state skip log as a synthetic `'soloist_build_expired'` state, so the 60s watchdog can never resurrect it. `Soloist::_versionCheck`'s success path self-heals the flag on the next successful activation (e.g. a replaced binary).
- `SoloistDaemon` now parses soloist's own `client expires in N days` stdout line (bounded 8 KiB head-read of the per-player log, once per daemon start after `ws.port` confirms the daemon is up and its startup banner has flushed) into a host-global `spoton_soloist_expiry_days` cache key for 73-04's Settings countdown display.
- Backoff-interplay audit (small, code comments): confirmed and documented that `SoloistWS::disconnect` already kills its own reconnect timer (no separate `killTimers` needed in `SoloistDaemon::stop`), that `startHelper` is the sole spawn entry point so `initHelpers`'s `STAGGER_DELAY` staggering covers soloist daemons unchanged (Pitfall 9), and that `helperPids` already iterates `%helperInstances` generically so orphan cleanup never targets a live soloist daemon.
- `t/31_soloist_ws.t` extended with the full command-map serialization table, the repeat-mode matrix, reconnect-resync (`get_state` trigger + tolerance-gated `seek`), track/volume snapshot reconciliation, and invalid-URI refusal. New `t/32_soloist_events.t` pins the complete D-06 event->spottyconnect mapping table (stop-collapse, resume-with-position, boundary volumes, position tolerance, device transfer start/stop, no-emission event types, unknown-type safety, Connect-toggle and malformed-JSON gating) -- the contract 73-03's browse logic builds against.

## Task Commits

Each task was committed atomically:

1. **Task 1: Backend dispatch for control commands + reconnect resync + repeat/shuffle helpers** - `686d9c4` (feat)
2. **Task 2: Lifecycle hardening — build-expiry escalation, expiry-days parsing, backoff interplay** - `a3368ea` (feat)
3. **Task 3: t/32 event-mapping table coverage** - `e79fc05` (test)

## Files Created/Modified

- `Plugins/SpotOn/Connect.pm` - `_sendControlCommand` backend dispatch: soloist helper isa-check, endpoint->WS-command translation, Web API fallback reuse
- `Plugins/SpotOn/Unified/SoloistWS.pm` - `sendRepeatMode`/`sendShuffle`, uri validation in `sendCommand`, `lastCommand`/`lastVolume` accessors, `command_result` handling, reconnect `get_state` trigger, `playback_state` reconciliation
- `Plugins/SpotOn/Unified/DaemonManager.pm` - exit-code classification in `_streamAlivePoll`, `_handleSoloistBuildExpiry`, `startHelper`'s soloist-branch expiry gate, stagger/orphan-cleanup documentation comments
- `Plugins/SpotOn/Unified/SoloistDaemon.pm` - `_parseExpiryDays`, `stop()` reconnect-timer documentation comment
- `Plugins/SpotOn/Soloist.pm` - `_versionCheck`'s success path clears `spoton_soloist_expired` (self-heal)
- `t/31_soloist_ws.t` - extended with command-map, repeat-matrix, reconnect-resync, and reconciliation test cases
- `t/32_soloist_events.t` (new) - full D-06 event->spottyconnect mapping table + repeat matrix + gating rows

## Decisions Made

See `key-decisions` in frontmatter for the full list. Highlights: the endpoint->command translation table lives in `Connect.pm` (a librespot-wire-protocol concern) rather than `SoloistWS`; booleans in WS command payloads use the `\1`/`\0` scalar-ref JSON idiom (not `JSON::XS::true()`) so the isolated-require test harness can decode them without an extra stub; exit-code-10 detection uses `Proc::Background`'s `->wait` + `>>8` per the RESEARCH doc's literal guidance (functionally safe here since the preceding `->alive` call already triggered a non-blocking reap).

## Deviations from Plan

None — plan executed as written. All three tasks' acceptance criteria (grep-based checks, `prove` invocations) pass exactly as specified in 73-02-PLAN.md.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **Live E2E verification is parked as UAT** (matching 73-01's own precedent, and this plan's own `<verification>` section): the bidirectional control loop (LMS action -> WS command -> Spotify app reaction), the WS-down Web API fallback actually firing, and a real build-expiry (rc=10) park all require a live LMS instance, a paired Soloist daemon, and a Spotify app on the same LAN -- none available in this execution environment. Recorded in `.planning/WINDOWS.md` (entries #1, #2) so they stay visible at ship time.
- 73-03 (Browse via the persistent daemon, Model B) can build directly on the command surface and event mapping delivered here (`sendCommand`/`sendRepeatMode`/`sendShuffle`, the full `_onMessage` dispatch table) -- no blockers identified.
- 73-04 (Settings/cleanup) can consume `spoton_soloist_expired` and `spoton_soloist_expiry_days` directly for the build-lifetime display.

---
*Phase: 73-soloist-connect-mode*
*Completed: 2026-08-26*

## Self-Check: PASSED

All modified/created files verified present on disk; all task commit hashes (`686d9c4`, `a3368ea`, `e79fc05`) verified present in git log.
