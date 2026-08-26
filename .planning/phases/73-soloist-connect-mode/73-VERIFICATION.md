---
phase: 73-soloist-connect-mode
verified: 2026-08-26T19:40:00Z
status: human_needed
score: 18/27 must-haves verified
behavior_unverified: 9
overrides_applied: 0
behavior_unverified_items:
  - truth: "The player appears in the Spotify app's device picker under its LMS name; selecting it (transfer) starts LMS playback of the Connect stream — no LMS-side Web API call is involved (D-07)"
    test: "With a real LMS + paired Soloist daemon + Spotify Premium app on the same LAN: connect a player with backend=soloist, confirm one soloist process starts, tap the device in the Spotify app's device picker"
    expected: "device_changed/track_changed events arrive over WS and LMS starts spoton://connect- playback with audible /stream output — no Web API PUT /me/player call is made"
    why_human: "Requires a live LMS instance, a paired/authenticated Soloist daemon, and the Spotify mobile/desktop app on the same LAN; no such environment exists in this execution session. 73-01-SUMMARY marks this human_judgment=true."
  - truth: "During a soloist Connect session, LMS-side pause/unpause/next/prev/seek/volume actions reach Soloist as WS commands and Spotify state follows (D-06 command direction)"
    test: "Trigger pause/skip/seek/volume from LMS (web UI or CLI) while backend=soloist and a Connect session is active in the Spotify app"
    expected: "Each action is mirrored in the Spotify app's transport UI within ~1s"
    why_human: "No unit harness invokes Connect.pm's private _sendControlCommand with a live/fake connected SoloistDaemon WS end-to-end (73-02-SUMMARY D4 rationale) — grep/code-review only. Tracked as WINDOWS.md #1 (open)."
  - truth: "When the WS connection is unreachable, LMS control actions fall back to the Spotify Web API (D-15 parity with librespot)"
    test: "Kill/block the soloist WS mid-session, then issue an LMS control action"
    expected: "The action reaches Spotify via the existing Web API fallback path, not silently dropped"
    why_human: "Same dispatch code path as above is not exercised end-to-end by any test; fallback firing has never been observed live. Tracked as WINDOWS.md #1 (open)."
  - truth: "An expired soloist build (exit code 10) stops the daemon permanently with a clear log message instead of crash-looping every 5-300s (Pitfall 7)"
    test: "Force (or wait for) a soloist process to exit with code 10"
    expected: "DaemonManager logs the build-expiry message, sets spoton_soloist_expired, and startHelper refuses to resurrect the daemon on subsequent watchdog passes"
    why_human: "No fixture simulates a real dead Proc::Background process reporting exit code 10 (73-02-SUMMARY D5 rationale) — classification logic is grep/static-verified only. Tracked as WINDOWS.md #2 (open)."
  - truth: "The remaining build lifetime parsed from soloist's own log line is cached per host for the Settings display (73-04 consumes it)"
    test: "Start a soloist daemon and inspect the spoton_soloist_expiry_days cache key"
    expected: "The days-remaining value matches the 'client expires in N days' line in the daemon's own log"
    why_human: "No fixture provides a real per-player log file containing that line (73-02-SUMMARY D6 rationale) — regex presence is grep-verified only, never exercised against real soloist stdout."
  - truth: "Sequential Browse playback advances the LMS playlist in lockstep with Soloist's track_changed events; no track is skipped and none changes early — the Phase-72 data-dir-lock failure mode is structurally gone (D-03)"
    test: "Queue 3 album tracks in Browse with backend=soloist, play through all three, and attach `soloist ctl trace` to observe the real event sequence at each track boundary"
    expected: "Tracks advance in order with no skips or early switches; the actual end-of-track/autoplay event sequence matches (or corrects) the RESEARCH-default assumptions the advance logic was built against"
    why_human: "The mandatory Wave-0 spike (73-SPIKE-NOTES.md) was filed DEFERRED — no paired/authenticated Soloist daemon or Spotify app was reachable in this execution environment. The advance/seeding logic is unit-tested only against fixture events matching the RESEARCH defaults, not real Soloist output. Tracked as WINDOWS.md #3 (open)."
  - truth: "The next Spotify track in the LMS playlist is seeded into Soloist's queue before the current track ends, so the audio transition happens inside Soloist (gapless-capable path, Modell B)"
    test: "Same Browse session as above; measure the audible/byte gap at the track-boundary takeover"
    expected: "The transition is subjectively gapless or near-gapless; the measured takeover gap is <1s (RESEARCH default assumed <500ms, unconfirmed)"
    why_human: "Takeover gap was never measured (73-SPIKE-NOTES.md Q5) — the plan's own default assumption substitutes for a live measurement. Tracked as WINDOWS.md #3/#4 (open)."
  - truth: "LMS pause/stop during soloist Browse playback freezes Soloist (WS pause) so unpause resumes at the paused position, not ahead of it"
    test: "Pause a soloist Browse track for ~10s via LMS, then unpause"
    expected: "Playback resumes at the paused position, not advanced by the pause duration"
    why_human: "Connect.pm's _onPause/_onSeek browse-forwarding branches have no isolated test harness (73-03-SUMMARY D4 rationale — Connect.pm has never had one); verified by grep/code-review only. Tracked as WINDOWS.md #4 (open)."
  - truth: "Settings shows the live Soloist state: per-player daemon running + paired status, WS auth state, and a build-expiry countdown with a warning"
    test: "Open Settings with backend=soloist (one or more players connected) and with backend=librespot"
    expected: "The soloist backend shows the per-player status table (daemon dot, paired yes/no, logged-in state) and the expiry line with correct warning/error styling; the librespot backend renders none of it"
    why_human: "t/09_settings.t verifies only the Perl-side param computation (soloistPlayers/soloistExpiry*); the actual rendered HTML has not been screenshotted against a live LMS instance in this execution environment (73-04-SUMMARY D3 rationale, and the plan's own Task 3 human-check)."
human_verification:
  - test: "Live LMS + paired Soloist daemon + Spotify Premium app: connect a player (backend=soloist), tap the device in the Spotify app's device picker."
    expected: "Device appears under its LMS name; tapping it transfers audio to LMS via /stream with no LMS-side Web API call."
    why_human: "External Spotify app + LAN + Premium account interaction; not reproducible in this sandbox (D-07, 73-01-SUMMARY)."
  - test: "During an active soloist Connect session, trigger LMS-side pause/skip/seek/volume and observe the Spotify app; then kill the WS mid-session and repeat."
    expected: "Actions mirror in the Spotify app within ~1s; with WS down, actions still reach Spotify via the Web API fallback."
    why_human: "No test exercises Connect.pm's _sendControlCommand -> WS -> real Spotify app loop, or the WS-down fallback firing (WINDOWS.md #1)."
  - test: "Force or await a real soloist process exit with code 10 (build expiry)."
    expected: "DaemonManager logs an actionable expiry message, sets spoton_soloist_expired, and the daemon is never restarted by the 60s watchdog."
    why_human: "No fixture simulates a real dead process with that exit code (WINDOWS.md #2)."
  - test: "Run the Wave-0 spike protocol (73-SPIKE-NOTES.md) against a real paired daemon: track-end behavior, autoplay, queue_changed echo shape, and the takeover-gap measurement."
    expected: "Confirms or corrects the RESEARCH-default assumptions the browse advance/seeding logic (SoloistWS.pm) was built against."
    why_human: "DEFERRED — no live paired daemon/Spotify app reachable in this session (WINDOWS.md #3)."
  - test: "Live Browse UAT: queue 3 album tracks and play through, pause 10s and unpause, use the seek bar, run a mixed Spotify->radio playlist, and sync two players."
    expected: "No skipped/early-switched tracks; unpause resumes at the paused position; seek works without a stream restart; the mixed playlist hands over cleanly; both synced players play audio via the daemon proxy; the device name in the Spotify app picker carries the sync suffix."
    why_human: "Requires a live LMS + paired daemon + Spotify app + a second physical/software player (WINDOWS.md #4; 73-03 Task 3 and 73-04 Task 2 human-check blocks)."
  - test: "Open Settings with backend=soloist (players connected) and with backend=librespot."
    expected: "soloist backend renders the per-player daemon/paired/WS-state table and the build-expiry line with correct styling; librespot backend shows none of it."
    why_human: "Only the Perl-side param computation is unit-tested (t/09_settings.t); the rendered page has not been visually verified (73-04 Task 3 human-check)."
---

# Phase 73: Soloist Connect Mode Verification Report

**Phase Goal:** Soloist Connect Mode — WebSocket API, Transfer-Playback, Browse on persistent daemon
**Verified:** 2026-08-26T19:40:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

Phase 73 has no formal REQ-IDs in `.planning/REQUIREMENTS.md` — that file is scoped to the v2.3 milestone. Per the phase's own `73-VALIDATION.md`, the phase's requirement set is the CONTEXT decisions D-01 … D-08, and this is the traceability basis used below (confirmed: no `Phase 73` references exist in REQUIREMENTS.md, so there is nothing orphaned there).

All four plans' commits are present in git log (`0cf32f5`, `534bb51`, `6ce6f1d`, `e31bcf4`, `686d9c4`, `a3368ea`, `e79fc05`, `126b12a`, `99d99f8`, `2c016f2`, `76805c2`, `191bcec`, `3ccf6db`). `prove -l t/` is fully green (32 files, 1315 tests) and `make -C Plugins/SpotOn/Bin/fake-libpulse test` passes (4/4 C host-test assertions). No debt markers (TBD/FIXME/XXX/TODO/HACK/PLACEHOLDER) found in any file this phase touched.

The code-level implementation (data structures, dispatch tables, state machines, i18n, conf cleanup) is thorough, well-tested at the unit/logic level, and honestly self-documented: the executing agent itself flagged 9 behaviors as unverifiable in this sandboxed environment (no live LMS, no paired/authenticated Soloist daemon, no Spotify Premium app on a LAN) and recorded 4 of them in `.planning/WINDOWS.md` as an open cross-phase ledger (`open_count: 4`). This verifier confirms that self-assessment is accurate and complete, adds two items the ledger did not separately capture (D-07 transfer/pairing visibility, and the Settings visual render), and classifies every truth accordingly.

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | One persistent soloist process per player, own data-dir under players/<mac>/ (D-01, D-02) | ✓ VERIFIED | `Unified::SoloistDaemon.pm` per-player `_spawnArgs`/dirs; `t/28_soloist_dispatch.t`, `t/30_soloist_daemon.t` pass |
| 2 | Device picker shows player; tap transfers; LMS plays Connect stream, no Web API call (D-07) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | Code present (DaemonManager startHelper soloist branch, SoloistWS auth_state/device_changed handling); no live Spotify app available (73-01-SUMMARY human_judgment=true) |
| 3 | WS events drive player state via spottyconnect vocabulary (transfer-in/away, volume, seek) (D-05, D-06) | ✓ VERIFIED | `t/31_soloist_ws.t` + `t/32_soloist_events.t` — full event→spottyconnect mapping table, incl. stop-collapse, tolerance gating |
| 4 | GET /stream delivers S16LE/44100/stereo PCM converted in C, no sox (D-04) | ✓ VERIFIED | `make -C Plugins/SpotOn/Bin/fake-libpulse test` — 4/4 pass (conversion+clamping, drop-oldest, writable_size) |
| 5 | WS protocol error/connection loss never terminates LMS (Pitfall 1) | ✓ VERIFIED | `t/31_soloist_ws.t` malformed-JSON/error-event tests — no die, reconnect logic present |
| 6 | backend=librespot unaffected (no regression) | ✓ VERIFIED | isa-gated `_streamAlivePoll`; full `prove -l t/` green incl. all pre-existing librespot tests |
| 7 | Protocol::WebSocket 0.26 vendored, fallback loads when bundle absent (D-08) | ✓ VERIFIED | `Plugins/SpotOn/Vendor/Protocol/WebSocket/` (14 files) present; `ensureWsLib()` push-not-unshift logic reviewed; `t/28` tests both precedence paths |
| 8 | LMS pause/unpause/next/prev/seek/volume reach Soloist as WS commands, Spotify state follows (D-06 command direction) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `Connect.pm::_sendControlCommand` dispatch reviewed and logically sound; no test invokes it end-to-end (WINDOWS.md #1) |
| 9 | WS unreachable → Web API fallback (D-15 parity) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | Same dispatch path; fallback call present, never exercised live (WINDOWS.md #1) |
| 10 | WS reconnect resyncs position/track/volume from playback_state snapshot | ✓ VERIFIED | `t/31_soloist_ws.t` reconnect/get_state + tolerance-gated reconciliation tests |
| 11 | Repeat mode two-command matrix correct (Pitfall 6 footnote) | ✓ VERIFIED | `t/31_soloist_ws.t` repeat-matrix assertions; `grep` confirms `set_repeat_context`/`set_repeat_track` |
| 12 | Expired build (exit code 10) permanently parks daemon (Pitfall 7) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | Classification code present (`grep -c spoton_soloist_expired` = 3 in DaemonManager.pm); no real dead-process fixture (WINDOWS.md #2) |
| 13 | Build lifetime parsed from log, cached for Settings | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | Regex/cache-write code present (`grep` confirms); never run against real soloist stdout |
| 14 | spoton://track:ID routes through daemon (WS play + /stream); per-track spawner retired (D-03) | ✓ VERIFIED | `t/29_soloist_browse.t` (23 assertions); `grep -c "return 'sol'"` == 0 in ProtocolHandler.pm |
| 15 | Sequential Browse playback advances in lockstep with track_changed; no skip/early switch | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | State machine unit-tested (`t/31`, 16 assertions) against RESEARCH-default fixture events; Wave-0 spike DEFERRED, never run against real Soloist (WINDOWS.md #3) |
| 16 | Next Spotify track seeded before current ends (gapless-capable) | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | Seeding logic unit-tested; takeover gap never measured (73-SPIKE-NOTES.md Q5, WINDOWS.md #3/#4) |
| 17 | Unrequested track_changed corrected (Pitfall 4, autoplay containment) | ✓ VERIFIED | `t/31_soloist_ws.t` — both correction branches (retarget / pause+end) tested at state-machine level |
| 18 | Seek works via WS seek, no LMS-side stream restart | ✓ VERIFIED | `t/29_soloist_browse.t` canSeek/getSeekData assertions; GH #129 pattern reapplied and code-reviewed |
| 19 | LMS pause/stop during browse freezes Soloist; unpause resumes at position | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `Connect.pm` `_onPause`/`_onSeek` browse branches reviewed; no isolated test harness for Connect.pm (73-03-SUMMARY D4; WINDOWS.md #4) |
| 20 | Sync groups play via new() proxy exactly like librespot (Pattern 7) | ✓ VERIFIED | `t/28_soloist_dispatch.t` (13 new assertions against the REAL DaemonManager module, not a stub) + `t/29` proxy cases |
| 21 | Mixed playlist hands back to LMS cleanly at boundary | ✓ VERIFIED | `t/31_soloist_ws.t` non-Spotify next-entry skip-seed logic tested |
| 22 | Phase-72 per-track machinery fully retired (no sol rules/type/launcher/sox) | ✓ VERIFIED | `grep` zero-counts on all four artifacts; `t/03`, `t/04`, `t/30` pass |
| 23 | Settings shows live daemon/paired/WS-auth/expiry state | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | `soloistPlayers`/`soloistExpiry*` params computed and unit-tested (`t/09_settings.t`); rendered HTML never screenshotted (73-04-SUMMARY D3) |
| 24 | Pairing instructions describe app-tap flow, no SSH | ✓ VERIFIED | `strings.txt` PAIR_HOWTO/NOT_PAIRED content reviewed — app-tap wording, no SSH/CLI references |
| 25 | Sync groups test-pinned (Pattern 7) | ✓ VERIFIED | `t/28_soloist_dispatch.t` 13 new assertions vs. real module; no production code change needed (mechanism already generic) |
| 26 | All new UI strings in 11 languages, real translations | ✓ VERIFIED | `t/02_strings.t` passes; spot-checked `PLUGIN_SPOTON_SOLOIST_EXPIRED` block — 11 distinct real-language lines |
| 27 | librespot installs zero regression | ✓ VERIFIED | isa-gating throughout; full `prove -l t/` green, no pre-existing librespot test broken |

**Score:** 18/27 truths verified (9 present, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` | HTTP streaming mode, ring buffer, f32→S16LE conversion | ✓ VERIFIED | `make test` — 4/4 pass |
| `Plugins/SpotOn/Unified/SoloistDaemon.pm` | Per-player lifecycle class | ✓ VERIFIED | 498 lines; spawn/poll/expiry-parse logic present, exercised by t/28/t/30 |
| `Plugins/SpotOn/Unified/SoloistWS.pm` | Event client + command surface + browse engine | ✓ VERIFIED | 828 lines; exercised by t/31 (172 assertions incl. 16 browse-engine) + t/32 |
| `Plugins/SpotOn/Vendor/Protocol/WebSocket/*` | Vendored 0.26, 14 files | ✓ VERIFIED | `find` confirms 14 files present |
| `Plugins/SpotOn/Connect.pm` | Backend-dispatched control + browse forwarding | ✓ VERIFIED (wired) / ⚠️ behavior unverified | `_sendControlCommand`/`_soloistBrowseWs` present and wired; end-to-end behavior untested (see truths 8/9/19) |
| `Plugins/SpotOn/ProtocolHandler.pm` | Soloist Browse rebuilt on daemon | ✓ VERIFIED | canDirectStream/new()/getNextTrack/canSeek all updated; `t/29` 23 assertions |
| `Plugins/SpotOn/Soloist.pm` | Launcher retired, isPairedForClient added | ✓ VERIFIED | `grep` confirms retired subs gone, `isPairedForClient` present once |
| `Plugins/SpotOn/custom-convert.conf` / `custom-types.conf` | sol rule/type removed | ✓ VERIFIED | `grep` zero-counts; soc/son untouched |
| `Plugins/SpotOn/Settings.pm` + `basic.html` | Per-player status + expiry display | ✓ VERIFIED (wired) / ⚠️ render unverified | `soloistPlayers` param present, `t/09_settings.t` passes; visual render not screenshotted |
| `Plugins/SpotOn/strings.txt` | New/updated keys, 11 languages | ✓ VERIFIED | `t/02_strings.t` passes; spot-checked full 11-language block |
| `t/28`…`t/32` (test files) | Full unit coverage | ✓ VERIFIED | All pass; 1315 total tests in suite |
| `.planning/phases/73-soloist-connect-mode/73-SPIKE-NOTES.md` | Empirical protocol findings | ⚠️ DEFERRED (documented) | Filed with explicit DEFERRED status + RESEARCH-default assumptions, per plan's own escape hatch |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `Connect.pm::_sendControlCommand` | `SoloistWS::sendCommand` | `helperForClient` isa-check → `$ws->sendCommand(...)` | ✓ WIRED | Code reviewed line-by-line; single dispatch point confirmed, librespot HTTP path untouched below it |
| `DaemonManager::startHelper` | `SoloistDaemon->new` | soloist branch (`_useSoloist`) | ✓ WIRED | `grep` confirms `SoloistDaemon->new($clientId)` call site (line 804) |
| `ProtocolHandler::canDirectStream` | `DaemonManager::helperForClient` → `_streamPort` | soloist-track branch | ✓ WIRED | Code reviewed; returns HTTP URL when alive+port, 0 when synced (proxy) or absent |
| `ProtocolHandler::getNextTrack` | `SoloistWS::startBrowseTrack` | `browseAdvancePending` re-entry guard | ✓ WIRED | `grep` confirms both call sites (lines 645, 655) |
| `SoloistWS` event handlers | Connect.pm's existing spottyconnect consumers | translation table (start/change/stop/volume/seek) | ✓ WIRED | `t/32_soloist_events.t` exercises the full mapping directly |
| Settings cache keys (`spoton_soloist_ws_<mac>`, `..._expiry_days`, `..._expired`) | `Settings.pm::handler` template params | direct cache reads | ✓ WIRED | `grep -c soloistPlayers Settings.pm` == 2; params computed from the same keys 73-02/73-03 write |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|---------------------|--------|
| `Settings.pm` `soloistPlayers` | per-player `{name, mac, paired, daemonAlive, wsState}` | `DaemonManager->helperForClient` + `Soloist::isPairedForClient` + `spoton_soloist_ws_<mac>` cache | Yes (real DaemonManager registry + cache reads, not hardcoded) | ✓ FLOWING |
| `ProtocolHandler.pm` `canDirectStream` URL | `http://<host>:<port>/stream` | `Slim::Utils::Network::serverAddr()` + `$helper->_streamPort` | Yes (both LMS/daemon-derived) | ✓ FLOWING |
| `SoloistWS` `sendCommand` payload | command params (position_ms, volume, uri) | caller-supplied, uri-validated | Yes | ✓ FLOWING |

### Requirements Coverage

Phase 73 uses CONTEXT decisions D-01…D-08 as its requirement set (no formal REQ-IDs in REQUIREMENTS.md for this milestone — confirmed via `73-VALIDATION.md` and a direct grep of REQUIREMENTS.md showing zero "Phase 73" references, so nothing is orphaned).

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| D-01 | 73-01, 73-04 | One daemon per player | ✓ SATISFIED | Truths 1, 20, 25 |
| D-02 | 73-01, 73-04 | Daemon starts on player-connect | ✓ SATISFIED | Truth 1; startHelper wiring |
| D-03 | 73-03, 73-04 | Daemon handles Browse + Connect; per-track path retired | ✓ SATISFIED (code) / partially UAT-pending (live) | Truths 14, 22; live Browse behavior per truths 15/16/19 pending |
| D-04 | 73-01 | Audio transport (HTTP server, C conversion) | ✓ SATISFIED | Truth 4, C host test |
| D-05 | 73-01, 73-02 | WS client implementation | ✓ SATISFIED | Truths 3, 10 |
| D-06 | 73-01, 73-02 | Event set → LMS player state, command direction | ✓ SATISFIED (code) / ? NEEDS HUMAN (live loop) | Truths 3, 8, 9 |
| D-07 | 73-01, 73-04 | Connect registration + transfer mechanism (app-tap) | ? NEEDS HUMAN | Truth 2, 24 |
| D-08 | 73-01 | Vendored Protocol::WebSocket 0.26 | ✓ SATISFIED | Truth 7 |

No orphaned requirements found — REQUIREMENTS.md does not map any IDs to Phase 73.

### Anti-Patterns Found

None. Scanned all modified core modules (`fake-libpulse.c`, `SoloistDaemon.pm`, `SoloistWS.pm`, `DaemonManager.pm`, `Soloist.pm`, `Connect.pm`, `ProtocolHandler.pm`, `Plugin.pm`, `Settings.pm`) for `TBD|FIXME|XXX|TODO|HACK|PLACEHOLDER` and placeholder-language patterns — zero hits (the only "XXXX" matches are `File::Temp` filename templates, not debt markers).

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| fake-libpulse HTTP conversion/ring-buffer | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | 4/4 checks pass (port announce, f32→s16 conversion+clamping, drop-oldest, writable_size shrink) | ✓ PASS |
| Full Perl test suite | `prove -l t/` | 32 files, 1315 tests, all pass | ✓ PASS |
| WS command dispatch wiring | code review of `Connect.pm::_sendControlCommand` | Single dispatch point confirmed, librespot path untouched | ✓ PASS (structural) |
| Live WS↔Spotify-app control loop | — | not runnable (no live daemon/app) | ? SKIP → human verification |

### Probe Execution

Not applicable — no `scripts/*/tests/probe-*.sh` declared or found for this phase.

### Gaps Summary

No structural gaps. Every artifact this phase's plans specify exists, is substantive, and is wired into the correct call path; every grep-based acceptance criterion from all four plans passes; the full Perl suite (1315 tests) and the C host-test harness are green; no debt markers were introduced.

The phase's own execution was transparent about what remains genuinely unverifiable inside this sandboxed environment: 9 of the 27 must-have truths describe runtime behavior against a real Soloist daemon, a real Spotify Premium account/app, or a real process crash — none of which are reproducible here. Four of these are already tracked in `.planning/WINDOWS.md` (open_count: 4) with clear reasons; this verification adds two more (D-07 transfer/pairing visibility, and the Settings page's visual render) that were flagged in SUMMARY rationale or PLAN human-check blocks but not separately logged to the ledger.

None of this is disqualifying for the phase goal on its own — the WebSocket API, transfer-playback dispatch, and daemon-based Browse are all implemented and unit-tested at the logic level. But "WebSocket API, Transfer-Playback, Browse on persistent daemon" as a goal statement inherently makes claims about live Spotify-Connect behavior that only a real device/app pairing can confirm. Recommend running the mandatory live UAT pass (Wave-0 spike + 73-03/73-04 human-check scenarios + the two additional items below) before shipping v4.0, consistent with the phase's own "Next Phase Readiness" notes across all four SUMMARYs.

## Human Verification Required

### 1. Connect Transfer via App-Tap Pairing (D-07)

**Test:** With a live LMS instance, a paired Soloist daemon, and the Spotify app on the same LAN: connect a player with `backend=soloist`, confirm exactly one soloist process starts, then tap the player in the Spotify app's device picker.
**Expected:** The device appears under its LMS name; tapping it transfers playback — LMS starts `spoton://connect-` playback with audible `/stream` output — with no LMS-side Web API call involved.
**Why human:** Requires a real Spotify Premium account, the Spotify app, and LAN/mDNS reachability; not reproducible in this execution environment (73-01-SUMMARY, human_judgment=true).

### 2. Bidirectional Control Loop + WS-Down Fallback (D-06/D-15)

**Test:** During an active soloist Connect session, trigger pause/skip/seek/volume from LMS and watch the Spotify app; then kill/block the WS connection and repeat the same actions.
**Expected:** Actions mirror in the Spotify app within ~1s; with the WS down, the same actions still reach Spotify via the existing Web API fallback.
**Why human:** No test invokes `Connect.pm::_sendControlCommand` end-to-end against a live/fake connected WS (WINDOWS.md #1, open).

### 3. Build-Expiry Escalation (Pitfall 7)

**Test:** Force or await a real soloist process to exit with code 10.
**Expected:** DaemonManager logs an actionable build-expiry message, sets `spoton_soloist_expired`, and the 60s watchdog never restarts the daemon afterward.
**Why human:** No fixture simulates a real dead `Proc::Background` process with that exit code (WINDOWS.md #2, open).

### 4. Wave-0 Spike — Track-End / Autoplay / Queue-Echo / Takeover-Gap (D-03)

**Test:** Run the spike protocol documented in `73-SPIKE-NOTES.md` against a real paired/authenticated Soloist daemon: observe the literal event sequence at track end, whether seeding suppresses autoplay, the `queue_changed` echo shape, and measure the takeover gap.
**Expected:** Confirms (or corrects) the RESEARCH-default assumptions the browse advance/seeding logic in `SoloistWS.pm` was built against.
**Why human:** DEFERRED — no paired daemon or Spotify app was reachable in this execution environment (WINDOWS.md #3, open).

### 5. Live Browse + Sync-Group UAT (D-03, Pattern 7)

**Test:** Queue 3 album tracks in Browse (`backend=soloist`) and play through; pause 10s then unpause; use the Material Skin seek bar; run a mixed Spotify→radio/local playlist; sync two players and confirm one soloist process with the sync-suffixed device name in the Spotify app's picker.
**Expected:** No skipped/early-switched tracks; unpause resumes at the paused position; seek works without a stream restart; the mixed playlist hands over cleanly; both synced players output audio via the daemon proxy; the picker shows the sync-suffixed name.
**Why human:** Requires a live LMS + paired daemon + Spotify app + a second player (WINDOWS.md #4, open; 73-03 Task 3 and 73-04 Task 2 human-check blocks).

### 6. Settings Page Visual Render

**Test:** Open Settings with `backend=soloist` (one or more players connected) and again with `backend=librespot`.
**Expected:** The soloist backend shows the per-player daemon/paired/WS-auth status table and the build-expiry line with correct warning/error styling; the librespot backend renders none of it.
**Why human:** Only the Perl-side parameter computation is unit-tested (`t/09_settings.t`); the actual rendered HTML has never been screenshotted against a live LMS instance (73-04-SUMMARY D3 rationale; 73-04 Task 3 human-check).

---

_Verified: 2026-08-26T19:40:00Z_
_Verifier: Claude (gsd-verifier)_
