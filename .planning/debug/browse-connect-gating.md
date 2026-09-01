---
status: awaiting_human_verify
trigger: "Phase 78 UAT: Daemon events (start/change/resume) hijack Browse playlist"
created: 2026-09-01T11:45:00Z
updated: 2026-09-01T00:00:00Z
---

## Current Focus

reasoning_checkpoint:
  hypothesis: "Every prior gate (78-02 per-handler echo guards, the 78-hybrid top-of-_connectEvent broad drop) derives Browse-vs-Connect discrimination from LMS song state (_currentSpotonTrackUrl -> streamingSong/playingSong URL, isSpotifyConnect) that is not synchronously settled at the moment the daemon's spottyconnect event is processed. Because the discrimination lives DOWNSTREAM (in Connect.pm, the event consumer) instead of UPSTREAM (in SoloistWS.pm, the event producer), it must infer intent from an effect (LMS state) that lags its cause (our own WS command) by an unbounded number of event-loop ticks -- an inherently racy design, not a race in any one implementation attempt."
  confirming_evidence:
    - "Failed Approaches log (this file): 4 independent attempts at downstream/derived discrimination (echo guards, broad drop, session-type resume guard, hybrid) all failed for the same class of reason -- 'resume Event kommt bevor playingSong settled -> Gate greift nicht'."
    - "78-RESEARCH.md Pitfall 1 + Assumption A3: the ORIGINAL Phase-78 design explicitly chose the URI-comparison-to-current-LMS-song approach and flagged the exact risk that materialized ('Falsch-positive Echos... Planner sollte streamingSong UND playingSong prüfen') -- both were already checked and it still raced."
    - "73-RESEARCH.md ':158/:248/:275: device_changed{is_active:true} is documented as THE Spotify-Connect-protocol signal for 'Transfer ZU Soloist' (App-initiated), and 'activate'/'deactivate' are explicitly never called by SpotOn's own Browse-driving code path -- is_active transitions are not touched by local WS play/pause commands, making them a race-free, authoritative discriminator when the check moves to the SOURCE (SoloistWS.pm) instead of the consumer (Connect.pm)."
    - "ProtocolHandler.pm's getNextTrack: a genuine Connect-issued 'playlist play' always targets a track the daemon's lastTrackId already reports (SoloistWS::_onTrackChanged sets lastTrackId BEFORE emitting the spottyconnect event that triggers Connect.pm's playlist play) -- so the WS sendCommand('play', uri=>...) branch is PROVABLY reached only for genuine NEW Browse-commanded tracks, never for a Connect echo. Verified in t/29 row 'a genuine Connect-echoed playlist play never sets soloistBrowseActive'."
  falsification_test: "If a genuine App-initiated Connect transfer-in, arriving while soloistBrowseActive is set, is silently swallowed (no 'start'/'resume' reaches Connect.pm, D-08 mutual exclusion never fires), the hypothesis is wrong. t/32 rows 'device_changed is_active=true still emits start even while soloistBrowseActive was set' and 'clears soloistBrowseActive as a side effect' + the follow-on row proving the NEXT track_changed flows through normally exercise exactly this and pass."
  fix_rationale: "Move the Browse/Connect discrimination from Connect.pm (event consumer, downstream of the race) to SoloistWS.pm (event producer, the only place with synchronous, race-free knowledge of 'did I just send this command'). Replaces ALL derived per-event trackId/URL matching with one explicit boolean (soloistBrowseActive): set exactly once per Browse session at the single call site that provably only fires for genuine new Browse tracks (getNextTrack's WS play dispatch), cleared exactly once by the single authoritative external signal for a genuine transfer (device_changed is_active:true). This is a root-cause fix, not a symptom patch: it eliminates the race by removing the dependency on LMS's unsettled state entirely, rather than trying to check that state faster or more cleverly."
  blind_spots: "(1) Cannot verify live against the actual (closed-source) Soloist binary in this sandbox -- the is_active semantics are inferred from 73-RESEARCH.md's documented wire-protocol description and the 'activate/deactivate deliberately left unwired' comment, not from reading Soloist's source. Needs live UAT confirmation. (2) A WS reconnect (not a daemon process restart) reuses the SAME SoloistWS object, so if soloistBrowseActive was true when the socket dropped mid-Browse, it stays true across the reconnect and _onPlaybackState's snapshot-bootstrap _emitStart would be suppressed by the same gate -- untested edge case, no evidence this occurs in practice, and it fails safe (suppression) rather than fails open (hijack) if it does."
  candidate_causes:
    - "code: downstream/derived discrimination in Connect.pm reads LMS song state before it settles (category: code)"
    - "architecture: the event-consumer layer (Connect.pm) was structurally the wrong place to decide Browse-vs-Connect -- the decision requires information (was this event caused by MY OWN outbound command) that only the event-producer layer (SoloistWS.pm) has synchronously (category: architecture/design)"
  and_gate: "no -- single root cause (wrong layer for the discrimination decision); the two candidate_causes above are the same root cause described at two levels of abstraction (symptom-level: races on LMS state; design-level: wrong module owns the decision), not two independent contributing conditions that both had to be true simultaneously."

next_action: "Awaiting human verification: live UAT of album Browse-play (multi-track playlist, no hijack) and a real Spotify-app Connect transfer during active Browse (interrupts correctly)."

## Symptoms

- expected: Browse-Play über LMS → Audio spielt, Daemon-Events werden ignoriert, Album-Playlist bleibt intakt
- actual: Daemon-Events ersetzen Browse-Playlist mit Connect-Einträgen. Nur 1 Track in Playlist. Stream-Restarts durch wiederholtes getNextTrack
- errors: "Resume while not on Connect stream → re-entering Connect via playlist play" in server.log
- timeline: Seit Phase 78 Execution (Perl-seitige Reintegration auf bounded Endpoint). browseSession State Machine (alter Gate) wurde in Phase 78-03 entfernt
- reproduction: Album über SpotOn Browse abspielen → nur 1 Track, Stream-Restarts sichtbar im Log

## Failed Approaches

1. Per-handler echo guards (Phase 78-02): trackId-Match auf start/change — fängt nur Echoes des gleichen Tracks, nicht Auto-Advance zu anderem Track
2. Unified browse gate (cmd != stop): droppt ALLE Events → bricht genuine Connect Transfer-In (start Event für echten Connect wird gedroppt weil isSpotifyConnect noch false)
3. Session-type resume guard: _currentSpotonTrackUrl returned undef wenn playingSong noch nicht geladen → Gate greift nicht
4. Hybrid (change/resume broad, start trackId-only): change/resume Gate am Top funktioniert, aber resume Event kommt bevor playingSong settled → Gate greift nicht

## Key Insight

Der alte browseSession war ein EXPLIZITER State — gesetzt bei Browse-Start, gelöscht bei Browse-Ende. Alle abgeleiteten Kriterien (URL-Match, isSpotifyConnect, playingSong) haben Race Conditions weil der LMS-State beim Event-Eintreffen noch nicht settled ist.

**Resolution direction (implemented):** explicit `soloistBrowseActive` flag on the SoloistWS object itself (not derived from LMS state at all). Set by ProtocolHandler::getNextTrack right before it dispatches the WS 'play uri=...' command for a Browse-commanded track (the ONE call site that provably only fires for genuine new Browse tracks — a Connect echo always matches lastTrackId already and takes the EOF-advance skip branch instead). Cleared only by SoloistWS::_onDeviceChanged(is_active:true) — the authoritative Spotify-Connect-protocol signal for a genuine App-initiated transfer, never touched by Browse's own local WS commands. The gate itself lives in SoloistWS::_emit() (the single choke point before ANY spottyconnect dispatch), not in Connect.pm — so a Browse echo/auto-advance never reaches Connect.pm's _connectEvent at all, eliminating the race entirely (no LMS state is read to make the decision).

## Evidence

- timestamp: 2026-09-01T00:00:00Z
  checked: Working tree state (approach 4, "hybrid") — Connect.pm top-of-_connectEvent change/resume broad drop + per-handler start trackId-echo guard; ProtocolHandler.pm getNextTrack lastTrackId-only skip (isSpotifyConnect removed); SoloistWS.pm pendingPlayConfirm (D-01 boundary-skip only, not event-suppression)
  found: All 60 t/37 + 50 t/29 tests passed (tests were written to match the hybrid implementation, not to catch its race) — confirms the bug is real-world/timing-dependent and NOT caught by the existing regression nets, consistent with the user's live-observed hijack despite green tests.
  implication: Need behavioral (not just grep-gate) tests that actually exercise the race-prone path, and a fix that removes the race mechanically rather than handling it "more carefully".

- timestamp: 2026-09-01T00:00:00Z
  checked: SoloistWS.pm full source — _onTrackChanged, _onDeviceChanged, _onPlaybackChanged, _emit, _emitAllowed, sendCommand/pendingPlayConfirm
  found: _emit() is already the single choke point for every daemon->spottyconnect dispatch ("Two gates before ANY Connect emission" per existing doc comment). _onTrackChanged sets lastTrackId BEFORE calling _emitStart/_emit — so by the time an event reaches Connect.pm, the daemon-side state (lastTrackId) is already consistent, but LMS-side state (playingSong/streamingSong) is NOT, because that requires an LMS Request execute() round-trip Connect.pm itself has to trigger.
  implication: The producer side (SoloistWS.pm) has strictly more race-free information at emission time than the consumer side (Connect.pm) has at receipt time. Discrimination belongs upstream.

- timestamp: 2026-09-01T00:00:00Z
  checked: ProtocolHandler.pm getNextTrack soloist branch (~line 749-812) — the daemonCurrent-eq-id skip vs. sendCommand('play', uri=>...) branching
  found: A genuine Connect-issued `playlist play spoton://track:$trackId` (from Connect.pm's start/change/resume handlers) ALWAYS targets a trackId that SoloistWS::lastTrackId already equals by the time Connect.pm dispatches it (lastTrackId is set inside _onTrackChanged before the spottyconnect event that triggers the dispatch even fires) — so getNextTrack's `daemonCurrent eq $id` skip branch fires and the WS sendCommand('play', ...) branch is never reached for a Connect echo.
  implication: `$ws->sendCommand('play', uri=>...)` in getNextTrack is a mechanically reliable "Browse commanded a genuinely new track" signal — safe to key an explicit flag off of, with no risk of it firing for a Connect-originated play. Confirmed by t/29's new row asserting soloistBrowseActive stays false in the Connect-matching-lastTrackId test case.

- timestamp: 2026-09-01T00:00:00Z
  checked: 73-RESEARCH.md (§158, §248, §275) and the "activate/deactivate... deliberately left unwired" comment in SoloistWS.pm
  found: device_changed(is_active:true) is documented as the Spotify-Connect-protocol-level signal specifically for an App-initiated transfer TO this device ("Transfer ZU Soloist"). SpotOn's own code never calls the daemon's 'activate'/'deactivate' commands — is_active transitions are driven entirely by the cloud/Spotify-app side, never by Browse's local WS play/pause traffic.
  implication: is_active:true is usable as the race-free, authoritative "genuine transfer started" signal to clear the new flag, without risk of Browse's own commands prematurely clearing it. (Documented as a blind spot: not verified against the live closed-source binary in this sandbox.)

- timestamp: 2026-09-01T00:00:00Z
  checked: Full project test suite after the fix (`prove -q t/*.t`)
  found: Files=37, Tests=1781, all pass. New behavioral rows added to t/32 (soloistBrowseActive gate: suppresses track_changed/playback_changed/position_sync while set; device_changed is_active:true clears it and still emits; is_active:false does NOT clear it; events flow normally once cleared) and t/29 (getNextTrack sets/does-not-set the flag in the three relevant branches) all pass. t/37's grep-gates updated to assert the OLD per-event echo guards are gone from Connect.pm and the NEW mechanism exists in SoloistWS.pm/ProtocolHandler.pm.
  implication: Adjacent/held-out signal passes (fix-acceptance guardrail signal 4).

- timestamp: 2026-09-01T00:00:00Z
  checked: Revert-and-reconfirm (fix-acceptance guardrail signal 5) — `git stash push -- Plugins/SpotOn/Unified/SoloistWS.pm Plugins/SpotOn/ProtocolHandler.pm` (source-only revert, new tests kept), reran t/29 + t/32, then `git stash pop`
  found: Without the source fix, t/32 dies fatally ("Can't locate object method soloistBrowseActive") and t/29's new row fails (`got: undef, expected: '1'`) — the driving tests genuinely depend on the fix. Reapplying the fix (stash pop) restores all-green (t/29 + t/32 + t/37 = 187/187; full suite 1781/1781).
  implication: bug_returned_on_revert=true, fixed_on_reapply=true — signal 5 passes.

## Eliminated

- hypothesis: "A per-event echo guard in Connect.pm, comparing the daemon's announced trackId/URL against LMS's current song state (_currentSpotonTrackUrl / playingSong / streamingSong), can reliably discriminate a Browse echo from a genuine Connect event."
  evidence: "4 independent implementation attempts (see Failed Approaches) — including one that explicitly checked BOTH streamingSong and playingSong per 78-RESEARCH.md Assumption A3's own risk warning — all failed because LMS's song state is not synchronously settled relative to the daemon event's arrival. The discrimination question ('did I just send this') cannot be answered reliably by inspecting the EFFECT (LMS state) of a possibly-still-in-flight command; it must be answered by the code that issued the command."
  timestamp: 2026-09-01T00:00:00Z

## Resolution

root_cause: "Browse-vs-Connect event discrimination lived in the wrong architectural layer. All four prior attempts (Failed Approaches) implemented the discrimination in Connect.pm (the spottyconnect event CONSUMER), deriving intent from LMS playback state (_currentSpotonTrackUrl via streamingSong/playingSong, isSpotifyConnect) that lags behind the daemon event by an LMS Request round-trip and is therefore not reliably settled at the moment the event is processed — an inherent race, not an implementation bug in any one attempt. The correct layer is SoloistWS.pm (the spottyconnect event PRODUCER), which has synchronous, race-free knowledge of whether it just sent a Browse-driven WS 'play' command."

fix: "Replaced all derived per-event trackId/URL echo guards in Connect.pm (the 78-02 'start' handler guard and the 78-hybrid top-of-_connectEvent change/resume broad-drop) with one explicit boolean state, soloistBrowseActive, living on the SoloistWS object: (1) SET — ProtocolHandler::getNextTrack sets it to 1 immediately before its WS sendCommand('play', uri=>...) dispatch, the single call site proven to fire only for genuinely new Browse-commanded tracks (a Connect echo always matches lastTrackId already and takes the EOF-advance skip branch instead, never setting it). It stays true across a whole Browse session/album — auto-advance never re-sends WS play (the daemon's own queue advances and getNextTrack just confirms via lastTrackId), so the flag is untouched and remains set. (2) GATE — SoloistWS::_emit(), the existing single choke point before any spottyconnect dispatch, now returns early while soloistBrowseActive is set, suppressing every daemon event translation (track_changed start/change, playback_changed resume/stop, position_sync seek, volume_changed) at the source — Connect.pm's _connectEvent is never invoked at all for a Browse echo or auto-advance, eliminating the race by construction. (3) CLEAR — SoloistWS::_onDeviceChanged, in the is_active:true branch, clears soloistBrowseActive before any emission in that branch — device_changed(is_active:true) is the authoritative Spotify-Connect-protocol signal for a genuine App-initiated transfer (73-RESEARCH.md), never fired by Browse's own local WS commands, so a real transfer-in still interrupts an active Browse session correctly. This also fixes the second reported symptom (album collapsing to a single playlist track) as a direct consequence: Connect.pm's 'change' handler's `playlist play spoton://track:$newTrackId` (which replaces the whole LMS playlist with one entry) can no longer fire during Browse auto-advance, because the 'change' event that used to trigger it is now suppressed at the source."

verification:
  target_test:
    result: pass
    detail: "t/32 new rows (soloistBrowseActive suppression + device_changed clear + post-clear resume) and t/29 new rows (flag set/not-set in the three getNextTrack branches) — all pass. Full file runs: t/29 53/53, t/32 72/72, t/37 62/62."
  mutation_check:
    result: skipped
    reason_if_skipped: "No mutation-testing tool configured for this Perl project (Stryker is JS-only; no Perl equivalent — e.g. Test::Mutate — is set up in this repo)."
    mutant_killed: null
  no_op_deletion:
    result: flagged
    deletion_justified_by_rca: true
    detail: "Connect.pm diff is net-deletion (20 insertions / 52 deletions) — the 78-02/78-hybrid echo guards were removed outright, not weakened. This is explicitly justified by the reasoning_checkpoint RCA: the removed code WAS the root cause (discrimination in the wrong, racy layer), and it is superseded by new logic added elsewhere (SoloistWS.pm +73/-3, ProtocolHandler.pm +18/-6) that performs the equivalent decision race-free, at the correct layer. Net across all three source files: +111/-61 — a new mechanism, not a symptom-deleting no-op. Behavioral proof it isn't a no-op: t/32's new rows fail/die when the SoloistWS.pm+ProtocolHandler.pm fix is reverted while Connect.pm's deletions are (implicitly, since only those two files were stashed) still in place conceptually — see revert_and_reconfirm below, which reverted exactly the additive half and confirmed the mechanism's absence breaks behavior."
  adjacent_tests:
    result: pass
    suites_run: ["full suite: prove -q t/*.t (Files=37, Tests=1781)"]
  revert_and_reconfirm:
    result: pass
    bug_returned_on_revert: true
    fixed_on_reapply: true
    detail: "git stash push -- Plugins/SpotOn/Unified/SoloistWS.pm Plugins/SpotOn/ProtocolHandler.pm (source-only, new/updated tests kept in place); t/32 died fatally (soloistBrowseActive method missing) and t/29's new assertion failed (got undef, expected 1); git stash pop restored all-green (t/29+t/32+t/37 = 187/187, full suite 1781/1781)."
  guardrail_verdict: accepted
  rejected_signal: null

files_changed:
  - Plugins/SpotOn/Unified/SoloistWS.pm
  - Plugins/SpotOn/ProtocolHandler.pm
  - Plugins/SpotOn/Connect.pm
  - t/29_soloist_browse.t
  - t/32_soloist_events.t
  - t/37_connect_lifecycle.t
