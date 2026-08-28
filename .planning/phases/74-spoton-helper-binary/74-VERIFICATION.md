---
phase: 74-spoton-helper-binary
verified: 2026-08-28T00:00:00Z
status: passed
score: 15/15 must-haves verified
behavior_unverified: 0
overrides_applied: 0
---

# Phase 74: spoton-helper Binary Verification Report

**Phase Goal:** Eigenständiges Rust-Binary `spoton-helper` — `patch` (Lifetime-Timestamp + FLAC24-Enum), `check` (Binary-Validierung/Capability-Manifest), `protobuf` (protobuf⇄JSON Converter). CI-Build für x86_64, arm64, arm32 via cross-rs.
**Verified:** 2026-08-28
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

No `roadmap.get-phase` success-criteria block exists for Phase 74 (ROADMAP.md uses the checklist format for this phase, not the `### Phase N:` detail-section format the query tool expects — confirmed via `gsd_run query roadmap.get-phase 74` returning `malformed_roadmap`). Must-haves were therefore taken from the four PLAN.md frontmatter blocks (74-01 through 74-04), which together enumerate 15 observable truths across D-01 through D-09. This is a complete substitute for a roadmap success-criteria block since all 4 phase plans declare `must_haves`.

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `check --binary <file>` emits D-08 JSON (version, arch, soloist_version, patches.lifetime, patches.flac24_gates, sha256, patched) | ✓ VERIFIED | Live run: `spoton-helper check --binary <fixture>` → `{"arch":"x86_64-linux","patched":false,"patches":{"flac24_gates":[...6...],"lifetime":false},"sha256":"<64-hex>","soloist_version":"1.3.7.489","version":"0.1.0"}`; `cargo test --test fixture` (2/2 pass) |
| 2 | Crate builds with `cargo build`, `cargo test` green against synthetic fixtures only | ✓ VERIFIED | `cargo build` exit 0; `cargo test` 20/20 pass; no real Soloist binary referenced anywhere in test code (grep confirmed) |
| 3 | `patch`/`protobuf` dispatchable via clap, structured JSON error until filled | ✓ VERIFIED | Live run: `patch --version 9.9.9.999 ...` → `{"error":"version mismatch..."}` exit 1; `protobuf --schema bogus` → `{"error":"unknown schema..."}` exit 1 |
| 4 | `patch --version 1.3.7.489` applies Lifetime + 5/6 FLAC24 gates, skips crash gate | ✓ VERIFIED (engine only — see note) | `cargo test patch::tests::full_patch_applies_lifetime_and_five_gates` proves the engine mechanics against a TEST-ONLY table (`flac24_gates == [true,true,true,false,true,true]`). Real byte-patterns are intentionally absent from the public checkout (see Note below) |
| 5 | patch refuses unless version + exact pattern counts match; aborts with no write otherwise | ✓ VERIFIED | `cargo test patch::tests::wrong_version_aborts_with_no_write` + `count_mismatch_aborts_with_no_write`, both assert byte-identical target after abort |
| 6 | patch never mutates in place: stage → self-verify → atomic rename | ✓ VERIFIED | `src/patch/mod.rs` `run_core` steps 5 (self-verify), staging in same dir (`staging_path_for`), `std::fs::rename`; test asserts no leftover staging file |
| 7 | after successful patch, `check` reports patched:true, lifetime:true, 5 true gates | ✓ VERIFIED | `cargo test patch::tests::scan_status_reports_gate4_skip_after_patch` — `scan_status_for_sites` is the same function `check.rs` calls |
| 8 | `protobuf --mode decode` covers collection-v2/recently-played/rootlist from stdin | ✓ VERIFIED | `cargo test protobuf_cmd::tests::{collection_v2,recently_played,rootlist}_decode_roundtrip`, all 3 pass |
| 9 | `protobuf --mode encode` works for collection-v2 (PageRequest); response-only schemas return decode-only error | ✓ VERIFIED | `collection_v2_encode_roundtrip` pass; `recently_played_encode_is_decode_only` + `rootlist_encode_is_decode_only` pass |
| 10 | protobuf codegen uses pure-Rust `.pure()` — no protoc | ✓ VERIFIED | `build.rs` line 11: `.pure()`; `cargo build` succeeds with no `protoc` on PATH in this sandbox |
| 11 | malformed protobuf on stdin → JSON error, non-zero exit, never panic | ✓ VERIFIED | `malformed_protobuf_returns_error_not_panic`, `malformed_json_returns_error_not_panic`, `oversized_input_is_rejected` all pass; no `unsafe`, no `.unwrap()` on stdin-derived data (grep confirmed) |
| 12 | CI builds spoton-helper for 3 archs, folds into `Bin/<arch>/` in same workflow run as zip assembly | ✓ VERIFIED | `build-spoton-helper` job present, matrix maps armv7→armhf-linux; job listed in `release.needs`; zip-assembly step folds `release-artifacts/helper-*/` into `Bin/<arch>/` (YAML parsed + grepped) |
| 13 | Soloist.pm auto-patches once after download+activation: check-first, skip if already patched | ✓ VERIFIED | `_autoPatch` wired into `_onSoloistDownloadDone` after `_versionCheck` branch; `t/33_soloist_patch.t` Test 1-2 proves idempotent skip (only 1 invocation, `check`, when already patched) |
| 14 | auto-patch failure is non-fatal — Soloist still runs unpatched with a warning | ✓ VERIFIED | `_autoPatch` never dies (fail-open); `t/33` Test 6 (missing helper) + Test 7 (patch not completing) both assert no exception + warning logged |
| 15 | helper path constructed from `@ARCH_MAP` bindir + `Bin/<arch>/`, never findbin | ✓ VERIFIED | `_helperPath()` uses `_arch()->{bindir}` (same `@ARCH_MAP` used by `libPath()`) joined with `Plugin->_pluginDataFor('basedir')`; no `FindBin` reference anywhere in Soloist.pm |

**Score:** 15/15 truths verified (0 present-but-behavior-unverified)

**Note on Truth #4 (D-05/D-06 real patch content):** Per the Plan 02 Task 1 blocking-human decision (resolved: option b), the concrete Lifetime-timestamp and FLAC24-gate byte patterns are compliance-sensitive reverse-engineering output that must never be committed to the public repo as plaintext. `spoton-helper/src/patch/patterns.rs::sites_for()` ships with an **empty table for every architecture** in this checkout, with a marked `PRIVATE-INJECTION POINT`. A guarded CI step (`build-librespot.yml` lines 353-372) would inject the real tables from a private source at release-build time, but is keyed on `secrets.SPOTON_PRIVATE_PATTERNS_REPO`/`_TOKEN`, which **do not currently exist in this repository** (confirmed by both Plan 04's SUMMARY and by this being an intentional, documented, previously-approved compliance boundary — not an oversight). **Practical consequence:** every binary CI currently ships reports `patch` as `{"status":"unsupported"}` — a safe no-op — until a private pattern source is provisioned. The safety envelope, data model, idempotency, and JSON contract around the (currently empty) pattern table are fully implemented and tested; only the concrete byte values are pending a separate, out-of-band provisioning step the user already approved deferring. This is consistent with ROADMAP.md's own Phase-74 note ("FLAC24 nur TEILWEISE validiert... Effekt in Phase 77 UAT verifizieren") and is not treated as a gap.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `spoton-helper/Cargo.toml` | clap/serde_json/sha2/anyhow/thiserror + protobuf/protobuf-codegen, no tokio/reqwest/rustls/ring/aws-lc-rs | ✓ VERIFIED | Read directly; `overflow-checks = true` present |
| `spoton-helper/src/main.rs` | clap dispatch to check/patch/protobuf | ✓ VERIFIED | Read + live-invoked all 3 subcommands |
| `spoton-helper/src/check.rs` | D-08 JSON emitter | ✓ VERIFIED | Read; matches JSON contract exactly |
| `spoton-helper/src/arch.rs` | ELF e_machine detection | ✓ VERIFIED | Read; 0x3E/0xB7/0x28 → x86_64-linux/aarch64-linux/armhf-linux, matches Soloist.pm `@ARCH_MAP` |
| `spoton-helper/src/patch/mod.rs` | real patch engine + scan_status | ✓ VERIFIED | Read in full; safety envelope matches plan exactly |
| `spoton-helper/src/patch/patterns.rs` | empty public table + injection point | ✓ VERIFIED | Read; no byte literals, injection point documented |
| `spoton-helper/src/patch/encoding.rs` | per-arch gate encoding scaffolding | ✓ VERIFIED | Read; no concrete opcodes |
| `spoton-helper/src/protobuf_cmd.rs` | stdin/stdout protobuf⇄JSON, 3 schemas | ✓ VERIFIED | Read in full; no `unsafe`, no `.unwrap()` on stdin data |
| `spoton-helper/proto/*.proto` (12 files) | vendored D-02 schemas + rootlist closure | ✓ VERIFIED | `find`/`wc -l` confirms all 12 present incl. `metadata/` subdir |
| `spoton-helper/build.rs` | `.pure()` codegen | ✓ VERIFIED | Read; all 12 files as `.input()`s |
| `spoton-helper/Cross.toml` + `rust-toolchain.toml` | 3 musl targets | ✓ VERIFIED | Read; exactly 3 target sections |
| `.github/workflows/build-librespot.yml` | build-spoton-helper job + zip fold-in | ✓ VERIFIED | YAML-parsed + grepped, job present, wired into release needs |
| `Plugins/SpotOn/Soloist.pm` | `_helperPath`/`_runHelperJson`/`_autoPatch` | ✓ VERIFIED | Read in full; wired after `_versionCheck` activation branch |
| `t/33_soloist_patch.t` | auto-patch idempotency + fail-open tests | ✓ VERIFIED | Read in full; `prove -l t/33_soloist_patch.t` → 14/14 pass |
| `CHANGELOG.md` | Phase 74 entry | ✓ VERIFIED | grep confirms entry describing all 3 subcommands, 3-arch CI, auto-patch |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `check.rs` | `patch::scan_status` | direct call | ✓ WIRED | `check.rs:28` calls `patch::scan_status(&bytes)` |
| `patch::run` | `patterns::sites_for` | fn pointer passed to `run_core` | ✓ WIRED | `mod.rs:92` `run_core(version, binary, patterns::sites_for)` |
| CI `build-spoton-helper` | release job | `needs:` + `helper-*` artifact glob | ✓ WIRED | grep + YAML parse confirms both |
| `Soloist.pm::_onSoloistDownloadDone` | `_autoPatch` | direct call after activation | ✓ WIRED | Line 315, inside the successful `_versionCheck` branch |
| `Soloist.pm::_autoPatch` | `spoton-helper` binary | `_runHelperJson` → array-form `open('-|', ...)` | ✓ WIRED | Confirmed no shell interpolation (`t/33` Test 9 + direct grep: no backtick usage) |
| `patch::run` | `<binary>.sha256` sidecar | `std::fs::write` after rename | ✓ WIRED | `mod.rs:200-207`; test `idempotent::rerun_on_already_patched_binary` confirms sidecar hash == patched-binary SHA256 |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `check` emits D-08 JSON for a synthetic ELF fixture | `spoton-helper check --binary <fx>` | Valid JSON, all 6 keys present, sha256 64-hex | ✓ PASS |
| `patch` reports `unsupported` for the empty public table | `spoton-helper patch --version 1.3.7.489 --binary <fx>` | `{"arch":"x86_64-linux","status":"unsupported"}` exit 0 | ✓ PASS |
| `patch` aborts on version mismatch | `spoton-helper patch --version 9.9.9.999 --binary <fx>` | `{"error":"version mismatch..."}` exit 1 | ✓ PASS |
| `protobuf` rejects unknown schema | `echo -n \| spoton-helper protobuf --schema bogus --mode decode` | `{"error":"unknown schema 'bogus'..."}` exit 1 | ✓ PASS |
| Full Rust test suite (single run) | `cd spoton-helper && cargo test` | 20/20 pass (18 unit + 2 integration) | ✓ PASS |
| Full Perl test suite (single run) | `prove -l t/` | 33 files, 1370 assertions, all pass | ✓ PASS |
| CI workflow YAML validity | `python3 -c "yaml.safe_load(...)"` | parses; all expected jobs present | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| D-01 | 74-01 | Standalone Rust binary, 3 subcommands, cross-rs 3 archs | ✓ SATISFIED | Cargo.toml, main.rs, Cross.toml all confirmed |
| D-02 | 74-03 | protobuf⇄JSON for collection/v2, recently-played, rootlist | ✓ SATISFIED | 10 passing protobuf tests, live decode/encode confirmed |
| D-03 | 74-04 | Patch at install, once, auto-triggered, idempotent | ✓ SATISFIED | `_autoPatch` wiring + t/33 idempotency tests |
| D-04 | 74-02 | Version-lock, fail-closed on mismatch/count-mismatch | ✓ SATISFIED | `run_core` version gate + count assertion, tests pass |
| D-05 | 74-02 | Lifetime-patch always automatic, no toggle | ✓ SATISFIED (engine); byte pattern deferred | Engine applies whenever a non-empty table + count match exist; no settings toggle exists in Soloist.pm |
| D-06 | 74-02 | FLAC24 5/6 gates, Gate 4 skip encoded as data | ✓ SATISFIED (engine); byte pattern + audible effect deferred to Phase 77 per ROADMAP | `SiteKind::Flac24Gate` + `skip: bool` data model, test proves 5/6 gate behavior |
| D-07 | 74-01/02 | check validates patch-status/integrity/arch/version | ✓ SATISFIED | check.rs emits all fields; sha256 sidecar written at patch time |
| D-08 | 74-01 | Exact JSON contract | ✓ SATISFIED | Live-verified field-for-field |
| D-09 | 74-04 | Binary ships in plugin zip under Bin/<arch>/ | ✓ SATISFIED | CI job + zip fold-in confirmed |

No orphaned requirements found (all D-01..D-09 referenced by at least one plan's `requirements:` frontmatter).

### Anti-Patterns Found

None. Grepped all phase-touched files (`spoton-helper/src/**/*.rs`, `.github/workflows/build-librespot.yml`, `Plugins/SpotOn/Soloist.pm`, `t/33_soloist_patch.t`) for TODO/FIXME/HACK/XXX/TBD/placeholder/"not yet implemented"/empty-return stubs. The only `XXXX` hits are `File::Temp` filename templates (`'soloist-XXXX'`, `'spak-XXXX'`), not debt markers. The empty `patterns.rs` table is a deliberately documented, user-approved compliance boundary (see Truth #4 note), not an unmarked stub — it has an explicit doc comment, is covered by a dedicated passing test (`empty_public_table_is_unsupported_no_op`), and is called out explicitly in both SUMMARY.md files as a "Known Stub" with its rationale.

### Human Verification Required

None. All 15 must-haves resolved to VERIFIED via direct code reading, live CLI execution, and a single run each of the Rust (`cargo test`) and Perl (`prove -l t/`) test suites. No visual, real-time, or external-service-dependent behavior in this phase.

### Gaps Summary

No gaps. All must-haves from all 4 plans (74-01 through 74-04) are backed by codebase evidence: builds succeed, all 20 Rust tests and all 1370 Perl assertions pass in a single full-suite run, the CI workflow YAML is structurally correct and matches the documented artifact-naming/fold-in scheme, and Soloist.pm's auto-patch wiring is both source-verified and behaviorally tested (idempotent skip, fail-open on missing helper, fail-open on incomplete patch, array-form exec).

One informational note carried forward (not a gap, not blocking): the real Lifetime/FLAC24 byte-patterns are intentionally absent from the public checkout per an explicit, previously-approved compliance decision (Plan 02 Task 1). The CI injection mechanism for them exists but its secrets are not yet provisioned, so every binary built from this repository today reports `patch` as a safe `unsupported` no-op. This is consistent with the ROADMAP's own note that the FLAC24 patch's real-world effect is deferred to Phase 77 UAT, and does not block Phase 74's goal (building the helper binary, its safety envelope, and its CI/Perl integration).

---

*Verified: 2026-08-28*
*Verifier: Claude (gsd-verifier)*
