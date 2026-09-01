---
phase: 73
slug: soloist-connect-mode
status: validated
nyquist_compliant: true
wave_0_complete: true
created: 2026-08-26
validated: 2026-09-01
---

# Phase 73 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Note: Phase 73 is PARTIALLY SUPERSEDED — browse SM removed by Phase 78-03. WS base + Connect paths remain.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Perl Test::More + C host tests (fake-libpulse) |
| **Test dir** | t/ |
| **Quick run command** | `prove -l t/28_soloist_dispatch.t t/30_soloist_daemon.t t/31_soloist_ws.t t/32_soloist_events.t` |
| **Full suite command** | `prove -l t/` |
| **Estimated runtime** | ~5 seconds |

---

## Per-Task Verification Map

| Req | Plan | Description | Test File | Command | Status |
|-----|------|-------------|-----------|---------|--------|
| D-01 | 73-01,04 | One daemon per player | t/28, t/30 | `prove -l t/28_soloist_dispatch.t t/30_soloist_daemon.t` | ✅ green |
| D-02 | 73-01,04 | Daemon start on player-connect | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| D-03 (browse) | 73-03,04 | Browse over daemon | — | — | ⊘ SUPERSEDED (Phase 78-03) |
| D-03 (retire) | 73-04 | Per-track path removed | t/03, t/04 | `prove -l t/03_convert_conf.t t/04_types_conf.t` | ✅ green |
| D-04 | 73-01,06 | fake-libpulse HTTP + ring | `make test` | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| D-05 | 73-01,02,05 | WS client + reconnect | t/31 | `prove -l t/31_soloist_ws.t` | ✅ green |
| D-06 | 73-02,05 | Event→spottyconnect mapping | t/32 | `prove -l t/32_soloist_events.t` | ✅ green |
| D-07 | 73-01 | Native Connect registration | manual UAT | manual | ✅ green (manual) |
| D-08 | 73-01 | Vendored Protocol::WebSocket | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| Sync groups | 73-04 | Slave delegation, sync suffix | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| Settings | 73-04 | Strings + template + status | t/02, t/09 | `prove -l t/02_strings.t t/09_settings.t` | ✅ green |
| Expiry escalation | 73-02 | exit-code-10 block re-spawn | t/33_soloist_expiry.t | `prove -l t/33_soloist_expiry.t` | ✅ green |
| sessionPaused | 73-05 | Three-signal convergence | t/31 (convergence block) | `prove -l t/31_soloist_ws.t` | ✅ green |
| Ring flush | 73-06 | pa_stream_flush | `make test` | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| Browse session | 73-03 | startBrowseTrack, seeding | — | — | ⊘ SUPERSEDED (Phase 78-03) |
| Spike findings | 73-03 | Track-end/autoplay empirical | — | — | ⊘ SUPERSEDED (Phase 78-03) |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky · ⊘ superseded*

---

## Superseded Requirements

| Req | Reason | Removed By |
|-----|--------|------------|
| D-03 (browse) | Browse SM removed — replaced by bounded endpoint | Phase 78-03 |
| Browse session engine | browseSession, _onBrowseTrackChanged, seeding | Phase 78-03 |
| Spike findings | Drove browse SM logic that was removed | Phase 78-03 |

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Native Connect registration | D-07 | Requires Spotify app + real audio | Transfer playback to SpotOn in Spotify app, verify audio plays |
| Transfer E2E (app→Soloist→LMS) | D-07 | Live system | Play in Spotify, transfer to SpotOn, verify squeezelite output |

---

## Validation Audit 2026-09-01

| Metric | Count |
|--------|-------|
| Total requirements | 16 (13 active + 3 superseded) |
| Gaps found | 2 (expiry escalation PARTIAL, sessionPaused PARTIAL) |
| Resolved | 2 |
| Superseded | 3 |
| Escalated | 0 |

**New test files:** t/33_soloist_expiry.t (exit-code-10 behavioral mock)
**Extended:** t/31_soloist_ws.t (sessionPaused three-signal convergence block)

**Auditor note on sessionPaused:** The three signals are all WS-originated (playback_changed status, playback_state snapshot, position_sync speed), not WS + spottyconnect + LMS power as originally described. Test built against actual implementation contract.

---

## Validation Sign-Off

- [x] All tasks have automated verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-09-01
