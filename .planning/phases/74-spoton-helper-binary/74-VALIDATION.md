---
phase: 74
slug: spoton-helper-binary
status: validated
nyquist_compliant: true
wave_0_complete: true
created: 2026-08-28
validated: 2026-08-28
---

# Phase 74 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | `cargo test` (built-in) — 20 tests in `spoton-helper/src/**` + `tests/` |
| **Framework (Perl)** | LMS `prove -l t/` (existing SpotOn test harness) — 1370 tests |
| **Config file** | `spoton-helper/Cargo.toml`; Perl: `t/` dir (existing) |
| **Quick run command** | `cargo test` (in `spoton-helper/`) |
| **Full suite command** | `cargo test --release` + `prove -l t/` |
| **Estimated runtime** | ~5 seconds (Rust) + ~6 seconds (Perl) |

---

## Sampling Rate

- **After every task commit:** Run `cargo test` (in `spoton-helper/`)
- **After every plan wave:** Run `cargo test --release` + `prove -l t/`
- **Before `/gsd-verify-work`:** Full suite + cross-build smoke (`cross build --release --target aarch64-unknown-linux-musl`)
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Test Name | Status |
|---------|------|------|-------------|-----------|-------------------|-----------|--------|
| 74-01-01 | 01 | 1 | D-01 | unit | `cargo test` | `check_json_schema` + `check_rejects_non_elf` | ✅ green |
| 74-01-02 | 01 | 1 | D-07/D-08 | integration | `cargo test --test fixture` | `check_json_schema` | ✅ green |
| 74-01-03 | 01 | 1 | D-01 | integration | `cargo test --test fixture` | `check_rejects_non_elf` | ✅ green |
| 74-02-01 | 02 | 2 | D-04/D-05 | unit | `cargo test patch::` | `full_patch_applies_lifetime_and_five_gates` | ✅ green |
| 74-02-02 | 02 | 2 | D-04 | unit | `cargo test patch::` | `wrong_version_aborts_with_no_write` | ✅ green |
| 74-02-03 | 02 | 2 | D-06 | unit | `cargo test patch::` | `scan_status_reports_gate4_skip_after_patch` | ✅ green |
| 74-02-04 | 02 | 2 | Safety | unit | `cargo test patch::` | `count_mismatch_aborts_with_no_write` | ✅ green |
| 74-03-01 | 03 | 2 | D-02 | unit | `cargo test protobuf_cmd::` | `collection_v2_decode_roundtrip` | ✅ green |
| 74-03-02 | 03 | 2 | D-02 | unit | `cargo test protobuf_cmd::` | `recently_played_decode_roundtrip` | ✅ green |
| 74-03-03 | 03 | 2 | D-02 | unit | `cargo test protobuf_cmd::` | `rootlist_decode_roundtrip` | ✅ green |
| 74-04-01 | 04 | 3 | D-03 | unit (Perl) | `prove -l t/33_soloist_patch.t` | 14 assertions | ✅ green |
| 74-04-02 | 04 | 3 | D-09 | CI | `gh workflow run` | CI run 33195421926 | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Additional Test Coverage (beyond map)

| Test Name | Scope | Requirement |
|-----------|-------|-------------|
| `patch::encoding::tests::known_arches_have_an_encoding` | unit | Safety |
| `patch::encoding::tests::unknown_arch_fails_closed` | unit | Safety |
| `patch::idempotent::rerun_on_already_patched_binary` | unit | D-03 |
| `patch::tests::empty_public_table_is_unsupported_no_op` | unit | D-06 compliance |
| `protobuf_cmd::tests::collection_v2_encode_roundtrip` | unit | D-02 |
| `protobuf_cmd::tests::recently_played_encode_is_decode_only` | unit | D-02 |
| `protobuf_cmd::tests::rootlist_encode_is_decode_only` | unit | D-02 |
| `protobuf_cmd::tests::malformed_protobuf_returns_error_not_panic` | unit | Safety |
| `protobuf_cmd::tests::malformed_json_returns_error_not_panic` | unit | Safety |
| `protobuf_cmd::tests::oversized_input_is_rejected` | unit | Safety |
| `protobuf_cmd::tests::unknown_schema_lists_supported_schemas` | unit | D-02 |

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real Soloist binary patch verification | D-05/D-06 | Proprietary binary | Download Soloist 1.3.7.489, run `spoton-helper patch`, verify `check` JSON |
| FLAC24 server-side effect | D-06 | Spotify server behavior | Play track, compare CDN file sizes with/without FLAC24 enum patch (deferred to Phase 77 UAT) |

---

## Validation Sign-Off

- [x] All tasks have automated verify
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 15s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-08-28

---

## Validation Audit 2026-08-28

| Metric | Count |
|--------|-------|
| Tasks audited | 12 |
| Gaps found | 0 |
| Resolved | 0 |
| Escalated | 0 |
| Total tests (Rust) | 20 |
| Total tests (Perl) | 1370 |
| CI verified | ✓ (run 33195421926) |
