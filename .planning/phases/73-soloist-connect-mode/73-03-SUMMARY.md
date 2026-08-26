---
phase: 73-soloist-connect-mode
plan: 03
subsystem: infra
tags: [perl, websocket, lms-plugin, protocol-handler, streaming, daemon-lifecycle]

requires:
  - phase: 73-soloist-connect-mode (plan 01)
    provides: Unified::SoloistDaemon lifecycle class (ws.port + HTTP-port polling, fake-libpulse /stream), Unified::SoloistWS event client + spottyconnect translation, browseSession emit gate
  - phase: 73-soloist-connect-mode (plan 02)
    provides: SoloistWS full command surface (sendCommand/sendRepeatMode/sendShuffle, T-22-01 uri validation), Connect.pm backend-dispatched control routing (_sendControlCommand)
provides:
  - Browse playback moved off Phase-72 per-track `--single-track` spawning onto the persistent daemon (D-03, Modell B) — WS `play`/`add_to_queue` commands + the daemon's HTTP /stream endpoint, the SAME endpoint Connect already uses
  - SoloistWS browse session state machine — startBrowseTrack/endBrowseSession, seeded-match event-driven playlist advance, Pitfall-4 defensive autoplay/drift correction, queue seeding inside a 15s lead window, track-end handling
  - ProtocolHandler.pm soloist Browse rebuild — contentType/getFormatForURL/formatOverride answer 'soc' (retired 'sol' transcoder profile); canDirectStream/new() resolve the daemon HTTP /stream URL (direct + sync-group proxy); getNextTrack dispatches play over WS with a re-entry guard; canSeek/getSeekData/canDoAction lift the Phase-72 hard-seek-off
  - Connect.pm LMS→Soloist browse forwarding — _soloistBrowseWs() resolves an active browse session; _onPause/_onSeek forward pause/unpause/seek via WS (separate debounce timer from the Connect path)
  - t/29_soloist_browse.t rewritten for the daemon-model dispatch matrix (both backends, both sync states); t/31_soloist_ws.t extended with the full browse-engine unit matrix
affects: [73-04-soloist-cleanup, 75-soloist-uat-release]

actuals:
  tokens: 16800
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Event-driven playlist advance: an autonomous daemon's own transition event (track_changed matching a pre-seeded queue entry) drives a source-marked LMS playlist-index command, rather than LMS polling or timing the advance itself"
    - "Defensive containment for an opaque third-party autoplay feature: never trust that seeding alone suppresses it — an unconditionally-armed correction path (retarget or pause+end) is cheaper than proving autoplay can't happen"
    - "Wave-0 spike deferred gracefully: RESEARCH-documented default assumptions substitute for empirical findings when the live precondition (paired daemon + Spotify app) can't be met in the execution environment, with the real spike carried forward as a tracked UAT/ledger item rather than skipped silently"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Unified/SoloistWS.pm
    - Plugins/SpotOn/ProtocolHandler.pm
    - Plugins/SpotOn/Connect.pm
    - t/29_soloist_browse.t
    - t/31_soloist_ws.t
    - .planning/phases/73-soloist-connect-mode/73-SPIKE-NOTES.md

key-decisions:
  - "Wave-0 spike filed DEFERRED (not skipped): no paired/authenticated Soloist daemon or Spotify app was reachable in this execution environment (existing host data-dirs have a .device_id but never completed pairing — no settings/Users/<user>-user/). Tasks 2-3 implement against the plan's own RESEARCH-default assumptions; the live spike is tracked as a mandatory UAT item (WINDOWS.md #3, #4)"
  - "Pitfall-4 corrective play() retargets to browseCurrentUri (the LMS-expected currently-playing track), not the next LMS entry -- only the seeded-match advance branch is ever allowed to move the LMS playlist pointer, keeping the state machine's one invariant (LMS index only moves on our own explicit advance) simple and auditable"
  - "endBrowseSession() skips sending `pause` for 'track_end' (Soloist already stopped on its own) and 'handover' (an incoming Connect session owns transport) -- every other end reason (e.g. 'queue_end') sends pause since nothing else is about to take over"
  - "Soloist Browse now serves through the SAME /stream endpoint Connect uses (not a per-track /track/{id} URL like the retired sol transcoder path or even the still-current librespot Browse path) -- there is one fake-libpulse HTTP server per daemon, not a per-track URL scheme"
  - "getSeekData/canDoAction('rew') soloist-browse checks are URL-based (song->track->url) and ws->browseSession-based respectively, not a single shared flag -- matches the plan's literal per-callsite wording rather than introducing a new cross-module session-state accessor"
  - "Connect.pm's own forwarding logic (_soloistBrowseWs/_onPause/_onSeek) is not exercised by an isolated test harness -- Connect.pm has never had one (73-02-SUMMARY.md D4 precedent: its load graph is disproportionate for a stub harness); covered by grep-based acceptance criteria and code review instead, consistent with the plan's own escape hatch"
  - "t/29 rewrite blesses its DaemonManager-helper test double into the literal 'Plugins::SpotOn::Unified::SoloistDaemon' package name (not a distinct Test:: namespace) per the plan's explicit 'Scalar::Util::blessed trickery' instruction, so any future isa() check against it behaves like production code would"

patterns-established:
  - "Re-entry guard via a single boolean flag on the long-lived WS client object (browseAdvancePending) rather than a request-id/token scheme -- sufficient because LMS's own playlist-index execute() is synchronous relative to the getNextTrack re-entry it triggers"

requirements-completed: [D-03]

coverage:
  - id: D1
    description: "Wave-0 empirical spike protocol for RESEARCH Open Questions 1/2/4 + takeover-gap measurement -- filed DEFERRED with RESEARCH-default assumptions applied to Task 2/3 (no live paired daemon/Spotify app reachable in this environment)"
    requirement: "D-03"
    verification:
      - kind: other
        ref: ".planning/phases/73-soloist-connect-mode/73-SPIKE-NOTES.md (DEFERRED status + Decisions section required by the plan's own <verify> block)"
        status: pass
    human_judgment: true
    rationale: "The spike itself IS the human/live-environment verification step -- it requires a live LMS instance, a paired Soloist daemon, and a Spotify Premium account/app, none available in this execution environment. Parked as a mandatory UAT item (WINDOWS.md #3)."
  - id: D2
    description: "SoloistWS browse session engine: startBrowseTrack/endBrowseSession, seeded-match track_changed advances the real LMS playlist (source-marked, browseAdvancePending re-entry guard), unexpected track_changed corrects (retarget) or ends the session (Pitfall 4), position_sync seeds the next LMS Spotify entry inside a 15s lead window (non-Spotify/end-of-playlist skips seeding), a stop with no seed ends the session and advances LMS normally, device_changed(is_active:false) mid-browse hands off to Connect"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/31_soloist_ws.t (16 new assertions across startBrowseTrack, seeded-match advance, both Pitfall-4 branches, device handover, track-end handling with/without a next entry, queue seeding inside/outside the lead window, non-Spotify next-entry skip, already-seeded no-op)"
        status: pass
    human_judgment: false
  - id: D3
    description: "ProtocolHandler.pm soloist Browse rebuild: contentType/getFormatForURL/formatOverride answer 'soc' (retired 'sol'); canDirectStream/new() resolve the daemon HTTP /stream URL directly and via sync-group proxy; getNextTrack dispatches the WS play command with the browseAdvancePending re-entry guard; canSeek/getSeekData/canTranscodeSeek/canDoAction lift the Phase-72 hard seek-off via the WS `seek` command (GH #129 pattern reapplied to browse)"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/29_soloist_browse.t (rewritten -- 23 assertions across both backends, both sync states, no-daemon fallback)"
        status: pass
      - kind: other
        ref: "plan's own grep-based acceptance criteria (startBrowseTrack|endBrowseSession count, add_to_queue/PLUGIN_SPOTON_SOLOIST_BROWSE source marker presence, retired 'sol' return-statement absence, canSeek soloist-gate removal) — all satisfied"
        status: pass
    human_judgment: false
  - id: D4
    description: "Connect.pm LMS→Soloist browse forwarding: _soloistBrowseWs() resolves an active browse session; _onPause forwards pause/unpause via WS before the Connect isSpotifyConnect guard; _onSeek forwards seek+position_ms on its own debounce timer (_bufferedBrowseSeek, distinct from the Connect path's _bufferedSeek); both skip PLUGIN_SPOTON_SOLOIST_BROWSE-sourced echo requests; _onVolume/_onPlaylistJump get no browse branch (volume stays LMS-local per the DEFERRED spike's A3 default; playlist jumps re-enter getNextTrack natively)"
    requirement: "D-03"
    verification:
      - kind: other
        ref: "grep-based acceptance check (_soloistBrowseWs count >= 3, satisfied at 5) against Plugins/SpotOn/Connect.pm; t/05_perl_syntax.t isolated-require confirms the modified module still loads"
        status: pass
    human_judgment: true
    rationale: "No unit harness invokes Connect.pm's private _onPause/_onSeek with a live/fake browse-session WS -- Connect.pm has never had an isolated test harness (73-02-SUMMARY.md D4 precedent: its load graph of Digest::MD5/File::Path/JSON::XS::VersionOneAndTwo/Slim::Networking::SimpleAsyncHTTP/Slim::Control::Request is disproportionate for a stub harness, and the plan's own Task 3 action explicitly permits parking this coverage). Verified by code review and the plan's grep-based acceptance criteria; true end-to-end behavior (LMS pause/seek -> WS command -> Soloist reaction) requires a live LMS + paired daemon + Spotify app; parked as UAT (WINDOWS.md #3, #4)."
  - id: D5
    description: "Live UAT scenarios (Task 3 human-check): sequential Browse playback advances without skips/early switches, pause 10s then unpause resumes at the paused position, seek bar works without an LMS-side stream restart, a mixed Spotify->radio/local playlist hands over cleanly at the boundary, sync-group proxy plays soloist Browse audio identically to librespot, and the actual track-transition (takeover) gap is measured"
    requirement: "D-03"
    verification: []
    human_judgment: true
    rationale: "Requires a live LMS instance, a paired Soloist daemon, and a Spotify Premium account/app on the same LAN -- none available in this execution environment. Parked as UAT per the plan's own <verification> section and Task 3's <human-check> block (WINDOWS.md #4)."

duration: ~35min
completed: 2026-08-26
status: complete
---

# Phase 73 Plan 03: Soloist Browse on the Persistent Daemon (Modell B) Summary

**Browse playback moved off Phase-72 per-track `--single-track` spawning onto the persistent Soloist daemon: WS `play`/`add_to_queue` commands drive playback, the daemon's HTTP `/stream` endpoint (shared with Connect) carries the audio, and `track_changed` events advance the real LMS playlist — the data-dir lock failure mode is structurally gone.**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3
- **Files modified:** 6 (1 created — spike notes; 5 modified — SoloistWS.pm, ProtocolHandler.pm, Connect.pm, t/29, t/31)

## Accomplishments

- **Wave-0 spike filed DEFERRED with RESEARCH defaults applied** (73-SPIKE-NOTES.md): no paired/authenticated Soloist daemon or reachable Spotify app existed in this execution environment (the only host data-dirs found have a `.device_id` but never completed pairing). Per the plan's own precondition, Tasks 2-3 implement the browse engine against the plan's literal RESEARCH-default assumptions (end-of-track = `playback_changed{stopped}`, defensive correction stays permanently armed regardless of whether autoplay is confirmed, queue_changed treated as an echo) rather than skipping the defensive logic — the live spike protocol is now a tracked mandatory UAT item.
- **SoloistWS gained the full browse session state machine** (Modell B, RESEARCH Pattern 6): `startBrowseTrack`/`endBrowseSession`, event-driven advance (`track_changed` matching a pre-seeded `add_to_queue` uri triggers a source-marked `['playlist','index','+1']`, never a stream restart), Pitfall-4 defensive containment (an unrequested `track_changed` retargets Soloist back onto the LMS-expected track, or pauses + ends the session at LMS queue end — the LMS playlist pointer only ever moves on our own explicit advance), queue seeding 15s before track end (skipped for non-Spotify next entries), and a clean device-handover to Connect when the Spotify app steals the player mid-browse.
- **ProtocolHandler.pm's soloist Browse paths rebuilt on the daemon**: `contentType`/`getFormatForURL`/`formatOverride` now answer `'soc'` (the retired `'sol'` transcoder profile is fully gone from code — conf cleanup follows in 73-04); `canDirectStream`/`new()` resolve the SAME `/stream` HTTP endpoint Connect already uses (direct for unsynced players, sync-group proxy substitution for synced ones); `getNextTrack` dispatches the actual WS `play` command with a `browseAdvancePending` re-entry guard so a seeded-transition re-entry doesn't restart audio Soloist is already playing; `canSeek`/`getSeekData`/`canDoAction('rew')` lift the Phase-72 hard seek-off — seek now works via the daemon's WS `seek` command using the same GH #129 stream-restart-suppression pattern the Connect path already uses.
- **Connect.pm forwards LMS-originated pause/unpause/seek to the daemon during a browse session**: `_soloistBrowseWs($client)` resolves an active browse-managed WS session (a browse session is NOT a Connect session, so the existing `isSpotifyConnect()` guard would otherwise silently drop these events); `_onPause`/`_onSeek` gained browse branches ahead of their Connect guards, with echo hygiene against the browse's own source marker and a dedicated debounce timer (`_bufferedBrowseSeek`) so the Connect and browse seek debounces can never collide.
- **t/29_soloist_browse.t rewritten** for the daemon-model dispatch matrix across both backends and both sync states (new `DaemonManager`/`SoloistDaemon`/`SoloistWS` test doubles); **t/31_soloist_ws.t extended** with 16 new assertions covering the entire new browse state machine. `prove -l t/` is fully green (32 files, 1321 tests).

## Task Commits

1. **Task 1: Wave-0 empirical spike — DEFERRED, RESEARCH defaults applied** - `126b12a` (docs)
2. **Task 2: Browse session engine — play dispatch, queue seeding, event-driven advance, defensive correction** - `99d99f8` (feat)
3. **Task 3: LMS→Soloist browse forwarding (pause/seek) + t/29 rewrite** - `2c016f2` (feat)

## Files Created/Modified

- `.planning/phases/73-soloist-connect-mode/73-SPIKE-NOTES.md` (new) - DEFERRED spike protocol, RESEARCH-default assumptions, mandatory UAT checklist
- `Plugins/SpotOn/Unified/SoloistWS.pm` - browse session state machine (startBrowseTrack/endBrowseSession/advance/correction/seeding), 3 new accessors, 6 new private subs
- `Plugins/SpotOn/ProtocolHandler.pm` - contentType/getFormatForURL/formatOverride 'soc' answer; canDirectStream/new() daemon /stream resolution; getNextTrack WS play dispatch; canSeek/getSeekData/canDoAction seek support
- `Plugins/SpotOn/Connect.pm` - `_soloistBrowseWs`/`_seekPositionFromRequest` helpers; `_onPause`/`_onSeek` browse forwarding branches; `_bufferedBrowseSeek`
- `t/29_soloist_browse.t` - rewritten for the daemon-model dispatch matrix (both backends, both sync states, no-daemon fallback)
- `t/31_soloist_ws.t` - extended with the full browse-engine unit test matrix

## Decisions Made

See `key-decisions` in frontmatter for the full list. Highlights: Pitfall-4 corrective `play()` retargets to `browseCurrentUri` (never the next LMS entry) so the LMS playlist pointer only ever moves on the state machine's own explicit advance; `endBrowseSession()` skips `pause` only for `'track_end'`/`'handover'` reasons; soloist Browse now shares Connect's single `/stream` endpoint rather than a per-track URL scheme; Connect.pm's forwarding logic is verified by grep/code-review rather than an isolated harness (matching 73-02's own precedent for that module).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - missing test coverage] Extended t/31_soloist_ws.t for Task 2's browse engine**
- **Found during:** Task 2
- **Issue:** Task 2 carries `tdd="true"` and a `<behavior>` contract for the SoloistWS browse state machine, but the plan's own `<files>` list for Task 2 names only the two implementation files (no test file), and its `<verify>` block only re-runs the pre-existing t/31/t/32. Leaving the new state machine (startBrowseTrack, seeded-match advance, both Pitfall-4 branches, device handover, track-end handling, queue seeding) without dedicated unit coverage would have been a correctness gap for a plan explicitly marked tdd.
- **Fix:** Added 16 new test cases to t/31_soloist_ws.t (the natural home — it already tests SoloistWS.pm and the pre-existing browseSession emit gate) covering every branch of the new engine, plus 4 new stubs (`Slim::Player::Source`, `Slim::Player::Playlist`, `Slim::Control::Request`, extended `Slim::Player::Client::Recorder`).
- **Files modified:** t/31_soloist_ws.t
- **Verification:** `prove -l t/31_soloist_ws.t` — 156 tests, all pass.
- **Committed in:** `99d99f8` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (missing test coverage, Rule 2)
**Impact on plan:** Strengthens the tdd="true" contract for Task 2 without changing any implementation behavior. No scope creep — the browse engine itself was implemented exactly per the plan's `<action>` text.

## Issues Encountered

None — `prove -l t/` was fully green after each task's changes (t/29 was expectedly red between Task 2 and Task 3, exactly as anticipated by the plan's own task sequencing: Task 2 retires the `'sol'` assumptions t/29 previously pinned, and Task 3's own job is rewriting it).

## User Setup Required

None — no external service configuration required. (The live-daemon UAT scenarios below require a running LMS + paired Soloist daemon + Spotify Premium app, which is a manual verification step, not a setup/configuration task.)

## Known Stubs

None — no hardcoded empty values or placeholder UI reach the user. The DEFERRED Wave-0 spike substitutes documented RESEARCH-default assumptions for empirical findings in the browse engine's logic (not a UI stub); see `73-SPIKE-NOTES.md` and the coverage/rationale entries above.

## Next Phase Readiness

- **Mandatory live UAT before shipping Phase 73** (tracked in `.planning/WINDOWS.md` #3 and #4, alongside the pre-existing #1/#2 from 73-01/73-02): run the Wave-0 spike protocol (73-SPIKE-NOTES.md) against a real paired daemon to confirm/correct the RESEARCH-default assumptions this plan's advance/correction logic was built against, then run the Task-3 human-check scenarios (sequential Browse playback, pause/unpause position, seek bar, mixed-playlist handover, sync-group proxy, and the measured takeover gap).
- **73-04 (Settings/cleanup)** can now safely remove the retired `sol`-family convert-conf rules and the `spoton-soloist` `--single-track` launcher wrapper — no code path selects them anymore (grep-verified: zero non-comment `return 'sol'` in ProtocolHandler.pm).
- If the live spike finds the takeover gap disruptive (>1s) or reveals different end-of-track/autoplay behavior than the DEFERRED defaults assumed, the advance/seeding parameters in SoloistWS.pm (`BROWSE_SEED_LEAD_SECONDS`, the stop-signal branch in `_onPlaybackChanged`) are the values to revisit — the defensive correction path stays regardless, since it was built to be safe under exactly this uncertainty.

---
*Phase: 73-soloist-connect-mode*
*Completed: 2026-08-26*

## Self-Check: PASSED

All created/modified files verified present on disk; all task commit hashes (`126b12a`, `99d99f8`, `2c016f2`) verified present in git log.
