---
phase: 74-spoton-helper-binary
plan: 02
subsystem: infra
tags: [rust, binary-patching, elf, sha256, fail-closed, compliance]

requires:
  - "spoton-helper crate scaffold + check subcommand (74-01)"
  - "patch::scan_status / patch::run stub contracts (74-01)"
provides:
  - "patch::run — version-locked, fail-closed per-arch pattern-table patcher (stage + self-verify + atomic rename)"
  - "patch::scan_status — real post-patch state (lifetime, flac24_gates[6], patched)"
  - "patterns.rs PatchSite/SiteKind data model + sites_for(arch) with a clearly marked private-injection point"
  - "encoding.rs per-arch FLAC24 gate encoding scaffolding (x86_64/aarch64/armhf)"
  - "SHA256 integrity sidecar (<binary>.sha256) written at patch time"
  - "already_patched idempotency no-op for re-runs"
affects: [74-04]

actuals:
  tokens: 6855
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "Absence-as-control compliance boundary: public patterns.rs ships an empty per-arch table with a marked injection-point comment; release CI injects the real validated byte-patterns from a private source (never plaintext in the public repo)"
    - "Testable-core / thin-wrapper split: run_core(version, binary, table_for_arch) takes an injectable site-table resolver and returns the JSON Value instead of printing, so unit tests drive the full safety envelope with a TEST-ONLY pattern table while patch::run (unchanged signature) delegates to it with the real, possibly-empty patterns::sites_for"
    - "Skip encoded as data: PatchSite.skip is a bool flag on the site itself (Gate 4 crash gate), not a positional/magic index — auditable straight from the table"
    - "Fail-closed safety envelope: version gate -> exact-occurrence count assertion (before any write) -> build patched buffer -> self-verify via scan_status -> stage in same dir -> atomic rename; any failure aborts with zero writes"
    - "Idempotency via read-only pre-scan: run_core scans the target with scan_status_for_sites before the count assertion; an already-patched target short-circuits to status:\"already_patched\" instead of hitting a misleading count-mismatch error"

key-files:
  created:
    - spoton-helper/src/patch/patterns.rs
    - spoton-helper/src/patch/encoding.rs
  modified:
    - spoton-helper/src/patch/mod.rs

key-decisions:
  - "Task 1 (decision checkpoint, resolved before this session): empty public stub table + private build-time injection from stiefenm/spoton-private, not plaintext-in-public. Encoded directly in patterns.rs's module doc and the sites_for match arms (all arches return &[])."
  - "run_core's site-table resolver is a plain fn-pointer/closure parameter (impl Fn(&str) -> &'static [PatchSite]), not a trait object or feature flag — keeps the production call site (patch::run) a one-line delegation to patterns::sites_for while giving tests full access to the real engine logic with a synthetic table"
  - "The already-patched short-circuit lives in run_core itself (not a separate check() call from Soloist.pm) — a single scan_status_for_sites pass on the pre-read bytes, reusing the exact same status computation the self-verify step already needs"

patterns-established:
  - "PatchSite.kind: SiteKind (Lifetime | Flac24Gate(usize)) replaces name-string matching for mapping a site to its status-array slot — scan_status_for_sites is a pure function of (bytes, sites) usable by both check's read path and patch's self-verify path"

requirements-completed: [D-03, D-04, D-05, D-06, D-07]

coverage:
  - id: D1
    description: "patch on a fixture reporting the locked version, with all TEST-ONLY patterns present at expected counts, applies lifetime + 5/6 FLAC24 gates, leaves Gate 4 untouched, atomic-renames over the original"
    requirement: "D-05, D-06"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#tests::full_patch_applies_lifetime_and_five_gates"
        status: pass
    human_judgment: false
  - id: D2
    description: "patch on a fixture whose embedded version != 1.3.7.489 aborts with an error and leaves the target byte-identical"
    requirement: "D-04"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#tests::wrong_version_aborts_with_no_write"
        status: pass
    human_judgment: false
  - id: D3
    description: "patch aborts with no write when a pattern's occurrence count != expected, before any write"
    requirement: "D-04"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#tests::count_mismatch_aborts_with_no_write"
        status: pass
    human_judgment: false
  - id: D4
    description: "the empty public pattern table makes patch a clean no-op reporting status:unsupported, exit 0, no write"
    requirement: "D-06 (compliance)"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#tests::empty_public_table_is_unsupported_no_op"
        status: pass
    human_judgment: false
  - id: D5
    description: "after a successful patch, scan_status reports lifetime:true and flac24_gates == [true,true,true,false,true,true] (Gate 4 index skipped)"
    requirement: "D-06, D-07"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#tests::scan_status_reports_gate4_skip_after_patch"
        status: pass
    human_judgment: false
  - id: D6
    description: "a successful patch writes a <binary>.sha256 sidecar (64-char hex) matching the patched binary's own SHA256"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#idempotent::rerun_on_already_patched_binary"
        status: pass
    human_judgment: false
  - id: D7
    description: "re-running patch against an already-patched binary is a clean no-op reporting status:already_patched, exit 0, no write"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "spoton-helper/src/patch/mod.rs#idempotent::rerun_on_already_patched_binary"
        status: pass
    human_judgment: false
  - id: D8
    description: "public checkout patterns.rs contains no concrete byte-pattern literals — empty per-arch slices + injection-point comment only"
    requirement: "D-06 (T-74-06 compliance)"
    verification:
      - kind: other
        ref: "manual review: spoton-helper/src/patch/patterns.rs sites_for match arms all return &[]; grep for byte-literal arrays finds only TEST-ONLY markers in mod.rs's #[cfg(test)] module"
        status: pass
    human_judgment: false

duration: 8min
completed: 2026-08-28
status: complete
---

# Phase 74 Plan 02: Patch Engine + Safety Envelope + Compliance-Boundary Pattern Table Summary

**Version-locked, fail-closed per-arch binary patcher: stage+self-verify+atomic-rename safety envelope wraps an empty public pattern-table stub with a marked private-injection point, so the compliance-sensitive Lifetime/FLAC24 byte patterns never enter the public repo as plaintext while the engine, idempotency, and integrity sidecar are fully implemented and unit-tested against a synthetic table.**

## Performance

- **Duration:** ~8 min (Tasks 2-3; Task 1 decision checkpoint was resolved in a prior session)
- **Tasks:** 2 (Task 1 was a decision checkpoint with no code, resolved before this session)
- **Files modified:** 3

## Accomplishments
- `patch/patterns.rs`: `PatchSite { name, kind, search, replace, expect_count, skip }` data model with `SiteKind::{Lifetime, Flac24Gate(usize)}`; `sites_for(arch)` returns an empty slice for every known arch in the public checkout, with a clearly marked `PRIVATE-INJECTION POINT` comment for release CI to replace
- `patch/encoding.rs`: `GateEncoding` enum + `encoding_for(arch)` documenting the per-arch FLAC24 compare-instruction shape (x86_64 `cmp imm8` / aarch64 `cmp wN,#imm` / armhf `cmp rN,#imm`) without any concrete opcodes or immediates; used by the engine as a defensive arch cross-check
- `patch/mod.rs` rewritten from the Plan 01 stub into the real engine:
  - `run(version, binary)` keeps its exact Plan-01 signature (contract with `main.rs`) and delegates to a testable `run_core(version, binary, table_for_arch)` that returns a `serde_json::Value`
  - Safety envelope: version gate → arch/encoding resolution → **idempotency short-circuit** (already-patched → `already_patched`, added in Task 3) → exact-occurrence count assertion (before any write) → build patched buffer → self-verify via `scan_status_for_sites` → stage in the same directory → atomic `rename()`
  - `scan_status(bytes)` (unchanged signature, `check.rs` contract) rewritten to resolve arch, load `sites_for(arch)`, and report real presence-of-`replace`-bytes state per site — reports all-false for the empty public table, matching Plan 01 behavior
  - SHA256 integrity sidecar (`<binary>.sha256`, single hex line) written immediately after a successful rename (D-07 integrity baseline for `check --expect-sha` / Soloist.pm)
- 8 `#[cfg(test)]` unit tests against a TEST-ONLY synthetic pattern table (unrelated markers, Gate index 3 carrying `skip: true` to mirror the real D-06 exclusion): full success, version mismatch, count mismatch, empty-public-table no-op, post-patch gate-4-skip scan, and idempotent re-run + sidecar-hash-matches-binary — all green, plus 2 `encoding.rs` arch-dispatch tests and the 2 pre-existing `check` integration tests, 12 total

## Task Commits

Each task was committed atomically:

1. **Task 1: DECISION — where the validated byte-patterns live** — no commit (decision-only checkpoint), resolved before this session: option (b), empty public stub + private build-time injection from `stiefenm/spoton-private`
2. **Task 2: Patch engine + safety envelope + per-arch pattern table** - `fd62be9` (feat)
3. **Task 3: Expected-SHA baseline + patch/check idempotency wiring** - `814efed` (feat)

## Files Created/Modified
- `spoton-helper/src/patch/patterns.rs` - `PatchSite`/`SiteKind` model, `sites_for(arch)` empty-table + injection point
- `spoton-helper/src/patch/encoding.rs` - `GateEncoding`/`encoding_for(arch)` per-arch scaffolding
- `spoton-helper/src/patch/mod.rs` - real `run`/`scan_status`, `run_core` testable core, staging/sidecar path helpers, `sha256_hex`, `find_soloist_version`, idempotency short-circuit, and the `tests`/`test_support`/`idempotent` `#[cfg(test)]` modules

## Decisions Made
- Test module split: shared fixture helpers and the TEST-ONLY pattern table live in a private `test_support` module; the idempotency test lives in its own sibling `idempotent` module (not nested under `tests`) so the fully-qualified test path is `patch::idempotent::rerun_on_already_patched_binary` — this makes the plan's verify command `cargo test patch::idempotent` select exactly that one test via substring match, rather than matching zero tests under `patch::tests::idempotent_...`.
- `run_core` returns `serde_json::Value` rather than printing directly, so unit tests assert on JSON fields without spawning a subprocess or capturing stdout; the public `run(&str, &Path) -> Result<()>` wrapper (unchanged signature) is the only thing that calls `println!`.
- Kept `patch::run`/`patch::scan_status` signatures byte-for-byte identical to the Plan 01 stub contract — `main.rs` and `check.rs` required zero changes.

## Deviations from Plan

None — plan executed exactly as written, including the Task 1 decision already resolved by the user before this session (option b).

## Known Stubs

- **`spoton-helper/src/patch/patterns.rs` `sites_for()`** — all three arch arms return an empty `&[]`. This is the *intended* Task 1 (option b) outcome, not an oversight: the concrete Lifetime + FLAC24 byte patterns are compliance-sensitive reverse-engineering output that must never be committed to the public repo as plaintext. The public checkout's `patch` subcommand is therefore a safe, fully-tested no-op (`status: "unsupported"`) until release CI injects the real per-arch tables from the private source (`stiefenm/spoton-private`) — that injection wiring is explicitly Plan 04's scope (74-04-PLAN.md, CI integration), not a gap in this plan.

## Issues Encountered
None.

## User Setup Required
None in this plan. Plan 04 will require the private-repo CI access (deploy key / self-hosted runner) that the Task 1 decision anticipated.

## Next Phase Readiness
- Plan 03 (protobuf subcommand) is independent of this plan's files and can proceed in parallel.
- Plan 04 (CI integration + Soloist.pm auto-patch wiring) can now: (a) inject the real per-arch `PatchSite` tables at `patterns.rs`'s marked injection point during the release build, (b) call `spoton-helper patch --version 1.3.7.489 --binary <soloist>` from `Soloist.pm::_autoPatch` and parse the `status` field (`patched` / `already_patched` / `unsupported`), and (c) read the `<binary>.sha256` sidecar as the `check --expect-sha` baseline.
- The FLAC24 audible effect remains explicitly unverified by design (D-06) — Phase 77 UAT is where that gets checked, not this plan.

---
*Phase: 74-spoton-helper-binary*
*Completed: 2026-08-28*

## Self-Check: PASSED

All 3 created/modified files found on disk (patterns.rs, encoding.rs, mod.rs); both task commits (fd62be9, 814efed) found in git log.
