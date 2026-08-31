---
phase: "78"
slug: "browse-connect-reintegration-perl"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: "2026-08-31"
---

# Phase 78 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Test::More (Perl, bundled with LMS) |
| **Config file** | none — uses `prove` directly |
| **Quick run command** | `prove -l t/05_perl_syntax.t` |
| **Full suite command** | `prove -l t/ 2>&1` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `prove -l t/05_perl_syntax.t`
- **After every plan wave:** Run `prove -l t/ 2>&1`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 78-01-01 | 01 | 0 | — | — | N/A | unit | `prove -l t/05_perl_syntax.t` | ✅ | ⬜ pending |
| 78-01-02 | 01 | 1 | — | — | N/A | unit | `prove -l t/29_soloist_browse.t` | ✅ | ⬜ pending |
| 78-01-03 | 01 | 2 | — | — | N/A | unit | `prove -l t/31_soloist_ws.t t/32_soloist_events.t` | ✅ | ⬜ pending |
| 78-01-04 | 01 | 3 | — | — | N/A | integration | `prove -l t/37_connect_lifecycle.t` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Commit uncommitted Spike-2 changes (fake-libpulse.c, libpulse.so.0, _signalBoundary, t/37)
- [ ] Remove `SPOTON_BOUNDARY_SPIKE` env guard

*Spike code is currently uncommitted in the working tree.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Browse playback via bounded endpoint | — | Requires running Soloist daemon + LMS | Start Soloist, play album via LMS Browse, verify track-advance with EOF |
| Connect playback via bounded endpoint | — | Requires Spotify app + Soloist daemon | Transfer playback to Soloist via Spotify app, verify audio + track-advance |
| ~46ms boundary chunk drop acceptable | — | Requires human listening test | Play album, listen for audible gap at track transitions |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
