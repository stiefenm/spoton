---
phase: 76
slug: connect-stabilization-flac24-integration
status: validated
nyquist_compliant: true
wave_0_complete: true
created: 2026-08-29
validated: 2026-09-01
---

# Phase 76 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Perl `prove` with Test::More |
| **Test dir** | t/ |
| **Quick run command** | `perl -c Plugins/SpotOn/Plugin.pm` |
| **Full suite command** | `prove -l t/` |
| **Test count** | 41 files, 1842 tests |
| **Estimated runtime** | ~2s (automated) + ~30 min (manual UAT) |

---

## Sampling Rate

- **After every task commit:** Run `perl -c Plugins/SpotOn/Plugin.pm`
- **After every plan wave:** Run full UAT checklist
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds (syntax check); UAT on wave boundaries

---

## Per-Task Verification Map

| Req | Plan | Wave | Description | Test File | Command | Status |
|-----|------|------|-------------|-----------|---------|--------|
| D-04 | 76-01 | 1 | S32LE ring conversion | fake-libpulse `make test` | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| D-05 | 76-01 | 1 | soc flc convert rule (D-18 disabled) | t/03_convert_conf.t (tests 9-10) | `prove -l t/03_convert_conf.t` | ✅ green |
| D-06 | 76-04 | 2 | resolveSoloistFormat | t/28_soloist_dispatch.t | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| D-07 | 76-04+08 | 2,4 | format dropdown + smp rule | t/03, t/04, t/09, t/29 | `prove -l t/03_convert_conf.t t/04_settings.t t/09_settings_player.t t/29_soloist_browse.t` | ✅ green |
| D-08 | 76-01 | 1 | samplesize(32) hints | t/28, t/29 | `prove -l t/28_soloist_dispatch.t t/29_soloist_browse.t` | ✅ green |
| D-09 | 76-08 | 4 | Consolidated manual UAT | 76-UAT-CHECKLIST.md | manual | ✅ green (manual) |
| D-10 | 76-08 | 4 | UAT timing decision | (doc) | — | ✅ documented |
| D-11 | 76-08 | 4 | Both-backend UAT checklist | 76-UAT-CHECKLIST.md | manual | ✅ green (manual) |
| D-12 | 76-07 | 3 | 8s gap instrumentation | fake-libpulse `make test` | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| D-13 | 76-07 | 3 | Gap fix (FIXED) | fake-libpulse host test | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| D-14 | 76-04+08 | 2,4 | librespot regression | t/29 (D-14 pins) | `prove -l t/29_soloist_browse.t` | ✅ green |
| D-15 | 76-09 | 5 | track_changed confirmation | — | — | ⊘ SUPERSEDED (Phase 78-03 removed code + tests) |
| D-16 | 76-10 | 5 | Stale-claim guard | t/37_connect_lifecycle.t | `prove -l t/37_connect_lifecycle.t` | ✅ green |
| D-17 | 76-11 | 6 | Stream-handoff gate | — | — | ⊘ SUPERSEDED (Phase 78-03 removed code + tests) |
| D-03 | 76-08 | 4 | ROADMAP cleanup | t/33_soloist_patch.t | `prove -l t/33_soloist_patch.t` | ✅ green |
| GH-94 | 76-03 | 1 | Context menu parity | t/14_context_menu.t (CTX-14/15) | `prove -l t/14_context_menu.t` | ✅ green |
| GH-128 | 76-02 | 1 | relay-start position resync | unified.rs relay_resync_tests | `cargo test` | ✅ green |
| GH-131 | 76-02 | 1 | buffer-latency-ms | t/39_daemon_buffer_latency.t | `prove -l t/39_daemon_buffer_latency.t` | ✅ green |
| GH-135 | 76-06 | 2 | getQueue API | t/08_api_client.t | `prove -l t/08_api_client.t` | ✅ green |
| GH-149 | 76-08 | 4 | Idle-guard verification | UAT checklist | manual | ✅ green (manual) |
| GH-150 | 76-08 | 4 | Audio-key timeout | UAT checklist | manual | ✅ green (manual) |
| GH-151 | 76-05 | 2 | Power save/restore | t/41_gh151_gh158_lifecycle.t | `prove -l t/41_gh151_gh158_lifecycle.t` | ✅ green |
| GH-158 | 76-05 | 2 | Group pause-skip-play | t/41_gh151_gh158_lifecycle.t | `prove -l t/41_gh151_gh158_lifecycle.t` | ✅ green |
| GH-159 | 76-02 | 1 | 409 for inactive Spirc | unified.rs control_status_tests | `cargo test` | ✅ green |
| GH-161 | 76-03 | 1 | type playlist on flat-list | t/40_gh161_playlist_type.t | `prove -l t/40_gh161_playlist_type.t` | ✅ green |
| W6 | 76-03 | 1 | search() offset guard | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| WIN-5 | 76-07 | 3 | Skip-reconnect gap | fake-libpulse host test | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| Autoplay | 76-05 | 2 | Restart auto-play suppress | t/38_autoplay_gate.t | `prove -l t/38_autoplay_gate.t` | ✅ green |
| Up Next | 76-06 | 2 | OPML feed + i18n | t/14_context_menu.t (CTX-16/17/18) | `prove -l t/14_context_menu.t` | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky · ⊘ superseded*

---

## Wave 0 Requirements

*All requirements covered by automated tests or manual UAT checklist. No Wave 0 pre-requisites remain.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| FLAC24 end-to-end playback | D-04/D-05 | Requires real audio hardware + Soloist | Play track via Soloist, verify FLAC output on squeezelite |
| Connect deselect in pause | D-09 (#159) | Requires Spotify Desktop interaction | Deselect SpotOn while paused, verify no BUFFERING hang |
| Sync group playback | D-09 (#131) | Requires multi-player setup | Play to sync group with mixed player types |
| Idle-guard verification | GH-149 | Requires real-time daemon lifecycle | Verify daemon stays alive during idle periods |
| Audio-key timeout | GH-150 | Requires live Spotify auth | Verify audio-key timeout recovery |

---

## Superseded Requirements

| Req | Reason | Removed By |
|-----|--------|------------|
| D-15 | track_changed confirmation gate — browse-SM machinery removed | Phase 78-03 (commit f6bfc0d) |
| D-17 | stream-handoff gate — browseAdvancePending removed | Phase 78-03 (commit f6bfc0d) |

---

## Validation Audit 2026-09-01

| Metric | Count |
|--------|-------|
| Total requirements | 29 |
| Gaps found | 7 (5 PARTIAL, 1 MISSING, 1 already covered) |
| Resolved (tests added) | 6 |
| Already covered (D-05) | 1 |
| Superseded (D-15, D-17) | 2 |
| Escalated | 0 |

**New test files:** t/38_autoplay_gate.t, t/39_daemon_buffer_latency.t, t/40_gh161_playlist_type.t, t/41_gh151_gh158_lifecycle.t
**Extended:** t/14_context_menu.t (CTX-14 through CTX-18)
**Suite result:** 41 files, 1842 tests, all green.

---

## Validation Sign-Off

- [x] All tasks have automated verify or manual UAT coverage
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 60s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-09-01
