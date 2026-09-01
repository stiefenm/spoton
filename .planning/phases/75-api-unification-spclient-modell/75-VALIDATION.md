---
phase: 75
slug: api-unification-spclient-modell
status: validated
nyquist_compliant: true
wave_0_complete: true
created: 2026-08-29
validated: 2026-09-01
---

# Phase 75 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Perl Test::More (LMS bundled) |
| **Test dir** | t/ |
| **Quick run command** | `prove -l t/34_protobuf_lite.t t/35_login5.t t/36_spclient.t` |
| **Full suite command** | `prove -l t/` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run quick suite (new module tests)
- **After every plan wave:** Run full suite
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Req | Plan | Wave | Description | Test File | Command | Status |
|-----|------|------|-------------|-----------|---------|--------|
| D-01 | 75-01,04,05 | 1,3,4 | ProtobufLite wire parser | t/34_protobuf_lite.t | `prove -l t/34_protobuf_lite.t` | ✅ green |
| D-02 | 75-03 | 2 | Remove protobuf from spoton-helper | t/26, t/33, cargo test | `prove -l t/26_soloist_check.t t/33_soloist_patch.t` | ✅ green |
| D-03 | 75-01 | 1 | spclient 429 rate-limit key | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| D-04 | 75-01 | 1 | Login5 token minting (S-01) | t/35_login5.t | `prove -l t/35_login5.t` | ✅ green |
| D-06 | 75-01,02,04,05,06 | 1-5 | Capability routing (login5-creds) | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| D-07 | 75-01,02,04,05,07 | 1-5 | Client.pm fallback on 4xx/5xx | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| D-07a | 75-01 | 1 | Single 401 remint-retry | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| D-08 | 75-02,04,05,06 | 2-5 | Full facade unification (~70 sites) | t/36, t/05, grep gates | `prove -l t/36_spclient.t t/05_perl_syntax.t` | ✅ green |
| D-09 | 75-01,02,04,05,07 | 1-5 | Burst avoidance (cache tiers) | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| S-01 | 75-01 | 1 | Varint regression | t/34, t/35 | `prove -l t/34_protobuf_lite.t t/35_login5.t` | ✅ green |
| S-04 | 75-02 | 2 | Track-name enrichment | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| S-05 | 75-02 | 2 | context-resolve track-only | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| S-06 | 75-04 | 3 | collection/v2 Content-Type | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| S-07 | 75-04 | 3 | Verified set names | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| S-09 | 75-04 | 3 | recently-played/v3 protobuf | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |
| S-10 | 75-05 | 4 | rootlist protobuf-only | t/36_spclient.t | `prove -l t/36_spclient.t` | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*All Wave 0 test files created during Phase 75-01 execution. No pre-existing gaps.*

- [x] `t/34_protobuf_lite.t` — ProtobufLite wire-parser tests
- [x] `t/35_login5.t` — Login5 token-minting tests
- [x] `t/36_spclient.t` — SpClient endpoint tests (309 assertions)

---

## Manual-Only Verifications

| Behavior | Why Manual | Test Instructions |
|----------|------------|-------------------|
| login5 token minting against live Spotify | Requires real stored credentials | Run on dev machine with configured SpotOn account |
| spclient Browse/Search end-to-end | Requires real Spotify session | Browse SpotOn menus after spclient migration |
| Rate-Pool interaction during playback | Requires active Connect playback | Browse while Connect is streaming, monitor for 429s |

---

## Validation Audit 2026-09-01

| Metric | Count |
|--------|-------|
| Total requirements | 16 (10 D-xx + 6 S-xx) |
| Gaps found | 0 |
| All covered | 16 |

**Suite result:** 309 core tests (t/34+t/35+t/36), all green. VERIFICATION.md 27/27 truths verified (after 75-07 gap closure).

---

## Validation Sign-Off

- [x] All tasks have automated verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-09-01
