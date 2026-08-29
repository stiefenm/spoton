---
phase: 76
slug: connect-stabilization-flac24-integration
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-08-29
---

# Phase 76 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Manual UAT (LMS + squeezelite + Spotify Desktop) |
| **Config file** | none — manual verification per D-09 |
| **Quick run command** | `perl -c Plugins/SpotOn/Plugin.pm` |
| **Full suite command** | Manual UAT checklist (D-09/D-11) |
| **Estimated runtime** | ~30 minutes per UAT pass |

---

## Sampling Rate

- **After every task commit:** Run `perl -c Plugins/SpotOn/Plugin.pm`
- **After every plan wave:** Run full UAT checklist
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds (syntax check); UAT on wave boundaries

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | D-04 | — | N/A | manual | UAT: FLAC24 output verification | N/A | ⬜ pending |
| TBD | TBD | TBD | D-12 | — | N/A | manual | UAT: 8s gap measurement | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*Existing infrastructure covers all phase requirements. Manual UAT per D-09.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| FLAC24 end-to-end playback | D-04/D-05 | Requires real audio hardware + Soloist | Play track via Soloist, verify FLAC output on squeezelite |
| Connect deselect in pause | D-09 (#159) | Requires Spotify Desktop interaction | Deselect SpotOn while paused, verify no BUFFERING hang |
| Sync group playback | D-09 (#131) | Requires multi-player setup | Play to sync group with mixed player types |
| 8s reconnect gap | D-12 | Requires real-time audio measurement | Skip track, measure gap between streams |
| librespot regression | D-14 | Requires both backends active | Browse + Connect + Format on librespot backend |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
