---
phase: 71
slug: soloist-foundation
status: validated
nyquist_compliant: true
wave_0_complete: true
created: 2026-08-24
validated: 2026-09-01
---

# Phase 71 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Perl Test::More (LMS standard) |
| **Test dir** | t/ |
| **Quick run command** | `prove -l t/26_soloist_check.t t/27_soloist_key.t t/28_soloist_dispatch.t` |
| **Full suite command** | `prove -l t/` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `prove -l t/`
- **After every plan wave:** Run full suite
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Req | Plan | Wave | Description | Test File | Command | Status |
|-----|------|------|-------------|-----------|---------|--------|
| D-01 | 71-01 | 0 | Feature-branch `soloist` | git (precondition) | — | ✅ structural |
| D-02 | 71-01 | 0 | Separate Soloist.pm module | t/05, t/26 | `prove -l t/05_perl_syntax.t t/26_soloist_check.t` | ✅ green |
| D-03 | 71-01 | 0 | Auto-download binary | t/26 (tests 1-4,7-8) | `prove -l t/26_soloist_check.t` | ✅ green |
| D-04 | 71-01 | 0 | Cache-dir storage layout | t/26 (tests 7-8) | `prove -l t/26_soloist_check.t` | ✅ green |
| D-05 | 71-01 | 0 | Version-pin, fail-closed | t/26 (tests 6,9) | `prove -l t/26_soloist_check.t` | ✅ green |
| D-06 | 71-01+04 | 0+1 | libPath() + fake-libpulse | t/26, `make test` | `prove -l t/26_soloist_check.t` | ✅ green |
| D-07 | 71-02 | 0 | Backend dispatch | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| D-08 | 71-03 | 0 | Settings UI JS toggle | t/42_soloist_settings_js_toggle.t | `prove -l t/42_soloist_settings_js_toggle.t` | ✅ green |
| D-09 | 71-02+03 | 0 | Prereq gate (no crash) | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| D-10 | 71-01 | 0 | spak.key mode 0600 | t/27 (tests 2,5) | `prove -l t/27_soloist_key.t` | ✅ green |
| D-11 | 71-01+03 | 0 | Key format + storeKey | t/27 (tests 1-10) | `prove -l t/27_soloist_key.t` | ✅ green |
| SOLO-BIN | 71-01 | 0 | Soloist binary module | t/26 | `prove -l t/26_soloist_check.t` | ✅ green |
| SOLO-DISPATCH | 71-02 | 0 | DaemonManager dispatch | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| SOLO-BYOK | 71-03 | 0 | Settings BYOK UX | t/09 (SOLO-BYOK block) | `prove -l t/09_settings.t` | ✅ green |
| SOLO-LIBPULSE | 71-04 | 1 | fake-libpulse C library | `make test`, CI | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ green |
| T-71-02 | 71-01 | 0 | Key never logged | t/27 (tests 6-7) | `prove -l t/27_soloist_key.t` | ✅ green |
| T-71-07 | 71-02 | 0 | No crash-loop | t/28 | `prove -l t/28_soloist_dispatch.t` | ✅ green |
| T-71-10 | 71-04 | 1 | LD_LIBRARY_PATH from Bin/ | t/26 | `prove -l t/26_soloist_check.t` | ✅ green |
| i18n | 71-03 | 0 | All 11 languages | t/02 | `prove -l t/02_strings.t` | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*All requirements covered by existing test infrastructure + 2 new tests from validation audit.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Soloist binary download works | D-03 | Requires network + Spotify auth | Download binary, verify checksum, run --version |
| LD_LIBRARY_PATH at runtime | D-06 | Runtime process environment | Start daemon, verify env var in /proc/PID/environ |

---

## Validation Audit 2026-09-01

| Metric | Count |
|--------|-------|
| Total requirements | 19 |
| Gaps found | 2 (D-08 PARTIAL, SOLO-BYOK PARTIAL) |
| Resolved | 2 |
| Escalated | 0 |

**New test files:** t/42_soloist_settings_js_toggle.t
**Extended:** t/09_settings.t (SOLO-BYOK block: backend whitelist, key validation, storeKey wiring)

---

## Validation Sign-Off

- [x] All tasks have automated verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-09-01
