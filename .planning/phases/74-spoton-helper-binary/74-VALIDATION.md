---
phase: 74
slug: spoton-helper-binary
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-08-28
---

# Phase 74 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | `cargo test` (built-in) — unit tests in `spoton-helper/src/**` |
| **Framework (Perl)** | LMS `prove -l t/` (existing SpotOn test harness) |
| **Config file** | `spoton-helper/Cargo.toml`; Perl: `t/` dir (existing) |
| **Quick run command** | `cargo test` (in `spoton-helper/`) |
| **Full suite command** | `cargo test --release` + `prove -l t/` |
| **Estimated runtime** | ~5 seconds (Rust) + ~10 seconds (Perl) |

---

## Sampling Rate

- **After every task commit:** Run `cargo test` (in `spoton-helper/`)
- **After every plan wave:** Run `cargo test --release` + `prove -l t/`
- **Before `/gsd-verify-work`:** Full suite + cross-build smoke (`cross build --release --target aarch64-unknown-linux-musl`)
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 74-01-01 | 01 | 1 | D-01 | unit | `cargo test` (crate compiles + clap dispatch) | ❌ W0 | ⬜ pending |
| 74-01-02 | 01 | 1 | D-07/D-08 | unit | `cargo test check::` | ❌ W0 | ⬜ pending |
| 74-01-03 | 01 | 1 | D-01 | integration | `cargo test --test fixture` | ❌ W0 | ⬜ pending |
| 74-02-01 | 02 | 2 | D-04/D-05 | unit | `cargo test patch::lifetime_applies_on_locked_version` | ❌ W0 | ⬜ pending |
| 74-02-02 | 02 | 2 | D-04 | unit | `cargo test patch::rejects_wrong_version` | ❌ W0 | ⬜ pending |
| 74-02-03 | 02 | 2 | D-06 | unit | `cargo test patch::flac24_skips_gate4` | ❌ W0 | ⬜ pending |
| 74-02-04 | 02 | 2 | Safety | unit | `cargo test patch::aborts_on_count_mismatch` | ❌ W0 | ⬜ pending |
| 74-03-01 | 03 | 2 | D-02 | unit | `cargo test protobuf::collection_v2_roundtrip` | ❌ W0 | ⬜ pending |
| 74-03-02 | 03 | 2 | D-02 | unit | `cargo test protobuf::recently_played_decode` | ❌ W0 | ⬜ pending |
| 74-03-03 | 03 | 2 | D-02 | unit | `cargo test protobuf::rootlist_decode` | ❌ W0 | ⬜ pending |
| 74-04-01 | 04 | 3 | D-03 | unit (Perl) | `prove -l t/33_soloist_patch.t` | ❌ W0 | ⬜ pending |
| 74-04-02 | 04 | 3 | D-09 | CI | `yaml.safe_load` CI structure check | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `spoton-helper/src/` — crate scaffold with `#[cfg(test)]` modules
- [ ] `spoton-helper/tests/fixture.rs` — synthetic fixture binary generator (crafted file with expected patterns, NOT the real Soloist binary)
- [ ] `t/33_soloist_patch.t` — Perl test for `Soloist.pm::_autoPatch` idempotency (mock helper returning `{patched:true}`)

*Tests run against synthetic fixtures — no proprietary binary or private patterns needed in CI.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cross-build smoke for 3 arches | D-01 | Needs cross-rs Docker | `cross build --release --target {triple}` for each of x86_64/aarch64/armv7 musl targets |
| Real Soloist binary patch verification | D-05/D-06 | Proprietary binary | Download Soloist 1.3.7.489, run `spoton-helper patch`, verify `--version` output + `check` JSON |
| FLAC24 server-side effect | D-06 | Spotify server behavior | Play track, compare CDN file sizes with/without FLAC24 enum patch (deferred to Phase 77 UAT) |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
