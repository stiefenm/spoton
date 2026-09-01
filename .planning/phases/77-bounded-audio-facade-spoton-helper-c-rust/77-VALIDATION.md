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
| 77-01/T1 | 77-01 | 1 | CR-1 | — | `g_ring_underrun_fired` is `atomic_int`; underflow_cb survives concurrent push/flush hammering | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test 2>&1 \| grep -c '^ok:' \| grep -qx 10` | ❌ new case (`ok: underrun_fired atomic under concurrent push/flush hammering`) | ⬜ pending |
| 77-01/T2 | 77-01 | 1 | D-02/D-03 | T-77-02/T-77-03 | Armed flush keeps client attached; no pre-seek bytes cross the socket (byte-content memcmp) | unit (C, tracer) | `make -C Plugins/SpotOn/Bin/fake-libpulse test 2>&1 \| grep -c '^ok:' \| grep -qx 11` | ❌ new case (`ok: seek-armed flush keeps client attached and serves only post-flush bytes`) | ⬜ pending |
| 77-02/T1 | 77-02 | 1 | CR-S1 | — | `_detectSeek()` extraction preserves drift detection; sessionActive guard divergence stays at call sites | unit (Perl) | `prove -l t/31_soloist_ws.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` (>= 147 tests) | ❌ extend t/31 (+4 rows) | ⬜ pending |
| 77-02/T2 | 77-02 | 1 | CR-S3 | T-77-04/T-77-05 | Poll-scaffold extraction preserves distinct failure semantics (WS stop() vs HTTP no-stop) | unit (Perl) | `prove -l t/30_soloist_daemon.t t/05_perl_syntax.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ❌ NEW coverage in t/30 (genuine gap — PATTERNS confirmed only `_spawnArgs` covered) | ⬜ pending |
| 77-03/T1 | 77-03 | 1 | CR-S4 | — | `getAlbumTracks`/`getShowEpisodes` on `_sliceAsPage`, pre-enrichment slicing order intact | unit (Perl) | `prove -l t/36_spclient.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ✅ t/36:867-900+ (getAlbumTracks) + t/36:1034+ (getShowEpisodes) — preserve unmodified | ⬜ pending |
| 77-03/T2 | 77-03 | 1 | CR-S2 | T-77-06 | `_delegateToClient` wrapper preserves all 17 sites' delegate behavior; early return stays in caller | unit (Perl) | `prove -l t/36_spclient.t t/05_perl_syntax.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ✅ t/36 Client.pm stub recorders | ⬜ pending |
| 77-04/T1 | 77-04 | 2 | D-02/D-05/D-10 | T-77-08..T-77-10 | Arm-then-command dispatch (callback-ordered) in both getNextTrack branches; idle daemon un-armed | unit (Perl) | `prove -l t/29_soloist_browse.t t/05_perl_syntax.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ❌ extend t/29 (+6 rows incl. SimpleAsyncHTTP stub) | ⬜ pending |
| 77-04/T2 | 77-04 | 2 | D-02 | — | `_onSeek` browse forwarding disconnected (no second un-armed WS seek possible) | unit (Perl) | `prove -l t/29_soloist_browse.t t/32_soloist_events.t t/37_connect_lifecycle.t t/05_perl_syntax.t 2>&1 \| tail -1 \| grep -q 'Result: PASS'` | ✅ existing suites (no test asserts the removed path) | ⬜ pending |
| 77-05/T1 | 77-05 | 2 | D-04 | T-77-12 | Rapid-skip: last `POST /boundary` watermark wins (byte-count assertion) | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test 2>&1 \| grep -c '^ok:' \| grep -qx 12` | ❌ new case (`ok: rapid-skip last boundary wins`) | ⬜ pending |
| 77-05/T2 | 77-05 | 2 | D-05 + OQ1 | T-77-11 | Takeover mid-armed-window serves zero pre-flush bytes; double-arm/double-flush survives; third un-armed flush disconnects (D-12 restored) | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test 2>&1 \| grep -c '^ok:' \| grep -qx 14` | ❌ 2 new cases | ⬜ pending |
| — | (existing) | — | D-06 | — | Stale-client cleanup via `g_flush_disconnect` | unit (C) | covered by pre-existing case `ok: reconnect after flush-disconnect attaches and drains immediately`, re-asserted in 77-01/T2 + 77-05/T2 acceptance | ✅ existing | ⬜ pending |
| 77-06/T1 | 77-06 | 3 | D-07 + D-08 | — | Live UAT: 78-UAT test 10 pass, repeated seek, rapid-skip, daemon-crash clean EOF | manual (checkpoint:human-verify) | manual — see 77-06 Task 1 items 1-5 | ❌ manual-only by design | ⬜ pending |
| 77-06/T3 | 77-06 | 3 | D-09 | T-77-13 | CI rebuild green on all 3 architectures incl. per-job binary verification | integration (CI) | `gh run list --workflow=build-fake-libpulse.yml --limit 1 --json conclusion --jq '.[0].conclusion' \| grep -qx success` | ✅ workflow exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] New C host-test case for CR-1 — a `pthread`-based stress loop hammering `_ring_push`/`_ring_flush` while the main thread polls the underrun path, rather than a timing-hopeful single-shot assertion → **planned as 77-01/T1**
- [x] Locate existing `t/` coverage for `SoloistDaemon.pm`'s `_pollWsPort`/`_pollHttpPort` and `SpClient.pm`'s `getAlbumTracks`/`getShowEpisodes` — RESOLVED by PATTERNS: t/30 covers only `_spawnArgs` (genuine gap → 77-02/T2 adds first-ever poll coverage); t/36 covers getAlbumTracks (:867-900+) AND getShowEpisodes (:1034+) — preserve, don't rewrite
- [x] Resolve RESEARCH Open Question 2 — RESOLVED at planning: `getSeekData`'s Browse branch stays `{timeOffset=>N}` (D-02's locked "ProtocolHandler passes start=N" requires the LMS-native restart), therefore the C side MUST handle takeover-mid-armed-window → drain-loop write gate is mandatory in 77-01/T2, tested in 77-05/T2
- [x] Update the `ok:` count assertion from the stale `6` to the current `9` — RESOLVED: all plan verify commands use the 9 baseline + added cases (10 → 11 → 12 → 14); Open Question 1 (double-flush) resolved by design as a saturating arm COUNTER (77-01/T2), characterized by test in 77-05/T2

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
