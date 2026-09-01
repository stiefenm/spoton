---
phase: "77"
slug: "bounded-audio-facade-spoton-helper-c-rust"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: "2026-09-01"
---

# Phase 77 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Seeded from `77-RESEARCH.md` § Validation Architecture. The planner fills the
> Per-Task Verification Map once PLAN.md task IDs exist.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (C)** | Custom single-file host-test harness compiled with `-DFAKE_LIBPULSE_TEST`, driven from `int main(void)` in `fake-libpulse.c`; prints `ok: <desc>` / `not ok: <desc>` |
| **Framework (Perl)** | `Test::More` via `prove -l t/*.t` (LMS plugin convention) |
| **Config file** | none — `Makefile`'s `test` target compiles + runs directly; Perl uses the `t/` directory convention |
| **Quick run command (C)** | `make -C Plugins/SpotOn/Bin/fake-libpulse test` |
| **Quick run command (Perl)** | `prove -l t/29_soloist_browse.t t/31_soloist_ws.t t/32_soloist_events.t t/37_connect_lifecycle.t t/05_perl_syntax.t` |
| **Full suite command** | `prove -l t/*.t` |
| **Estimated runtime** | C host tests < 1s; targeted Perl ~seconds; full Perl suite ~1873 tests |

**Baseline correction (from RESEARCH):** the prior-phase verify command
`make -C Plugins/SpotOn/Bin/fake-libpulse test 2>&1 | grep -c '^ok:' | grep -qx 6`
is **stale** — the current tree produces **9** `ok:` lines. Use `grep -qx 9` as the
pre-Phase-77 baseline and raise the expected count as each new D-07 host test lands
(expected final: 13–17).

---

## Sampling Rate

- **After every task commit:** `make -C Plugins/SpotOn/Bin/fake-libpulse test` after every `fake-libpulse.c` edit; targeted `prove -l t/29_soloist_browse.t t/31_soloist_ws.t t/32_soloist_events.t` after every Perl edit in this phase's scope
- **After every plan wave:** `prove -l t/*.t` — this phase's edits span the C ring/flush logic and 4+ Perl modules, so cross-module regressions (notably the `soloistBrowseActive` gate) are the main risk targeted runs miss
- **Before `/gsd-verify-work`:** full Perl suite green + full C host-test suite green at the updated `ok:` count
- **Max feedback latency:** < 60 seconds for the per-task loop

---

## Per-Task Verification Map

> Seeded from RESEARCH's Decision → Test map. Task IDs are filled by the planner
> once PLAN.md files exist; rows below are keyed by decision ID until then.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | 0 | CR-1 | — | `g_ring_underrun_fired` no longer races under concurrent set/reset from two threads | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ❌ W0 (new case) | ⬜ pending |
| TBD | TBD | — | D-02/D-03 | — | Seek does not disconnect the client; no pre-seek audio crosses the socket | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ❌ (new case) | ⬜ pending |
| TBD | TBD | — | D-04 | — | Rapid-skip: last `POST /boundary` wins; stale client disconnected via `g_flush_disconnect` | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ❌ (extends existing boundary case) | ⬜ pending |
| TBD | TBD | — | D-05 | — | URI-mismatch uses the same mechanism as seek, verified via the daemon play-command path | unit (C) + unit (Perl) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` and `prove -l t/29_soloist_browse.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ❌ (new both sides) | ⬜ pending |
| TBD | TBD | — | D-06 | — | Stale-client cleanup via existing `g_flush_disconnect` | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ existing | ⬜ pending |
| TBD | TBD | 0 | CR-S1 | — | `_detectSeek()` extraction preserves drift detection in both `_onPositionSync` and `_onPlaybackState` | unit (Perl) | `prove -l t/31_soloist_ws.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ❌ (extend existing) | ⬜ pending |
| TBD | TBD | 0 | CR-S2 | — | `_hasLogin5Creds` wrapper preserves all 17 call sites' delegate behavior | unit (Perl, grep-gate) | `prove -l t/05_perl_syntax.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ❌ (new grep-gate) | ⬜ pending |
| TBD | TBD | 0 | CR-S3 | — | `_pollWsPort`/`_pollHttpPort` shared scaffold preserves distinct failure semantics | unit (Perl) | TBD — planner locates the SoloistDaemon.pm test file first | ❓ locate first | ⬜ pending |
| TBD | TBD | 0 | CR-S4 | — | `getAlbumTracks`/`getShowEpisodes` switched to `_sliceAsPage`, behavior identical | unit (Perl) | TBD — planner locates the SpClient.pm slice coverage first | ❓ locate first | ⬜ pending |
| TBD | TBD | last | D-09 | — | CI rebuild succeeds on all 3 architectures; binaries pass the glibc/musl NEEDED verification | integration (CI) | `gh workflow run build-fake-libpulse.yml` + inspect the 3 matrix "Verify binary" steps | ✅ workflow exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] New C host-test case for CR-1 — a `pthread`-based stress loop hammering `_ring_push`/`_ring_flush` while the main thread polls the underrun path, rather than a timing-hopeful single-shot assertion
- [ ] Locate existing `t/` coverage for `SoloistDaemon.pm`'s `_pollWsPort`/`_pollHttpPort` and `SpClient.pm`'s `getAlbumTracks`/`getShowEpisodes` before starting CR-S3/CR-S4 — RESEARCH did not identify these files by name; do not assume coverage is absent
- [ ] Resolve RESEARCH Open Question 2 — whether `getSeekData`'s Browse branch changes as part of D-02, since that decides whether the seek-arm C-side fix must also handle "a second connection takes over mid-armed-window"
- [ ] Update the `ok:` count assertion from the stale `6` to the current `9` before adding new cases

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Daemon crash → clean EOF, LMS retry takes over | D-08 | Cannot host-test a real process death cleanly without a process-kill harness | Kill the daemon process mid-stream; confirm squeezelite sees a clean EOF and LMS's normal reconnect/retry logic takes over |
| Browse seek jumps to the correct position and keeps playing | D-02/D-03 | Real audio + real Soloist binary; this is the exact `78-UAT.md` test 10 failure this phase targets | Re-run `78-UAT.md` test 10 against the rebuilt binary; seek mid-track, confirm audio continues and the HTTP client is not closed |
| Rapid-skip and URI-mismatch behavior under a real player | D-04/D-05 | Timing against the closed-source Soloist binary and LMS's own stream restart | Skip rapidly across 3+ tracks; confirm last-wins with no stall and no stale audio |
| Boundary jitter within tolerance on real hardware | phase goal | Audio boundary jitter is only observable end-to-end | Play an album with natural gapless transitions; confirm no audible gap/overlap at track boundaries |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
