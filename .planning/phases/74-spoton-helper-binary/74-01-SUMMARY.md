---
phase: 74-spoton-helper-binary
plan: 01
subsystem: infra
tags: [rust, clap, cargo, cross-rs, elf, sha256, cli]

requires: []
provides:
  - "spoton-helper Rust crate scaffold with clap-derive CLI (patch/check/protobuf subcommands)"
  - "check subcommand emitting the D-08 JSON manifest (version, arch, soloist_version, patches, sha256, patched)"
  - "arch::read_arch — dependency-free ELF e_machine detection mapped to Soloist.pm @ARCH_MAP bindir vocabulary"
  - "patch::scan_status / patch::run and protobuf_cmd::run stub contracts for Wave 2"
  - "Synthetic ELF fixture generator (tests/fixture.rs) reusable by Wave 2 patch tests"
  - "Cross.toml + rust-toolchain.toml for 3-arch musl cross builds (x86_64/aarch64/armv7)"
affects: [74-02, 74-03, 74-04]

actuals:
  tokens: 6417
  tasks: 3
  commits: 3

tech-stack:
  added: [clap 4 (derive), serde_json 1, sha2 0.10, anyhow 1, thiserror 2]
  patterns:
    - "Stub-first contract: patch::scan_status/run and protobuf_cmd::run return fixed defaults/errors so check.rs and main.rs never change when Wave 2 fills the bodies"
    - "Fail-closed detection: arch/version detection returns null/None on any malformed input rather than guessing"
    - "Dependency-free binary parsing: hand-rolled ELF e_machine read instead of pulling in object/goblin for one field"
    - "Uniform JSON error contract: any subcommand error prints {\"error\": \"<msg>\"} to stdout and exits non-zero, so Soloist.pm can always parse stdout as JSON"

key-files:
  created:
    - spoton-helper/Cargo.toml
    - spoton-helper/Cargo.lock
    - spoton-helper/Cross.toml
    - spoton-helper/rust-toolchain.toml
    - spoton-helper/.gitignore
    - spoton-helper/src/main.rs
    - spoton-helper/src/check.rs
    - spoton-helper/src/arch.rs
    - spoton-helper/src/patch/mod.rs
    - spoton-helper/src/protobuf_cmd.rs
    - spoton-helper/tests/fixture.rs
  modified: []

key-decisions:
  - "No external tempdir crate for tests/fixture.rs — a ~15-line Drop-based TempDir keeps the dependency set at exactly clap/serde_json/sha2/anyhow/thiserror, matching the threat model's zero-network posture"
  - "Cross.toml scoped to exactly the 3 targets named in the plan (x86_64/aarch64/armv7 musl), not the 6-target librespot-spoton superset (i386, arm-linux, windows) — spoton-helper only needs the arches Soloist itself ships for"

patterns-established:
  - "Wave-0 fixture harness (write_fixture in tests/fixture.rs) is the reusable synthetic-binary generator Wave 2 patch tests extend by injecting marker byte sequences into the same fixture body — never a real distributed Soloist binary"

requirements-completed: [D-01, D-07, D-08]

coverage:
  - id: D1
    description: "check subcommand emits D-08 JSON (version, arch, soloist_version, patches.lifetime, patches.flac24_gates, sha256, patched)"
    requirement: "D-08"
    verification:
      - kind: unit
        ref: "spoton-helper/tests/fixture.rs#check_json_schema"
        status: pass
    human_judgment: false
  - id: D2
    description: "arch detection fails closed (null) on non-ELF input rather than guessing"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "spoton-helper/tests/fixture.rs#check_rejects_non_elf"
        status: pass
    human_judgment: false
  - id: D3
    description: "patch and protobuf subcommands are dispatchable via clap and return a structured JSON error until Wave 2"
    requirement: "D-01"
    verification:
      - kind: manual_procedural
        ref: "cd spoton-helper && ./target/debug/spoton-helper patch --version 1.3.7.489 --binary /tmp/fx74 (exits non-zero, prints {\"error\":...})"
        status: pass
    human_judgment: false
  - id: D4
    description: "Cross.toml + rust-toolchain.toml declare the 3 musl targets for cross-arch builds"
    verification:
      - kind: other
        ref: "grep -c 'target\\.' Cross.toml == 3; rust-toolchain.toml targets list"
        status: pass
    human_judgment: false

duration: 20min
completed: 2026-08-28
status: complete
---

# Phase 74 Plan 01: spoton-helper Scaffold + Check Subcommand Summary

**Standalone `spoton-helper` Rust crate: clap CLI with a fully working `check` subcommand emitting D-08 JSON via hand-rolled ELF parsing and SHA256, stubbed `patch`/`protobuf` subcommands, a synthetic-fixture test harness, and 3-arch musl cross-build config — zero network/protobuf dependencies.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-08-28T15:18:09Z (Task 1, tracer)
- **Completed:** 2026-08-28T15:45:16Z
- **Tasks:** 3
- **Files modified:** 11

## Accomplishments
- `spoton-helper` crate scaffolded with clap-derive dispatch across `patch`/`check`/`protobuf` subcommands, all reachable and erroring uniformly as JSON when unimplemented
- `check` subcommand fully implements the D-08 JSON contract: SHA256 (sha2), ELF arch detection (dependency-free e_machine read), embedded Soloist version marker scan, and patch status delegated to `crate::patch::scan_status`
- `patch::scan_status`/`patch::run` and `protobuf_cmd::run` stubbed with the exact signatures Wave 2 will fill, so `check.rs`/`main.rs` never need to change
- Synthetic ELF fixture generator (`tests/fixture.rs`) proves the full JSON schema against a crafted fixture (never a real Soloist binary) — 2 passing tests covering both the happy path and fail-closed non-ELF rejection
- Cross.toml (3 musl targets) + rust-toolchain.toml + `.gitignore` complete the cross-compile-ready toolchain config

## Task Commits

Each task was committed atomically:

1. **Task 1: Scaffold crate + clap dispatch + check subcommand end-to-end** - `f53544f` (feat) — completed in prior session, tracer checkpoint approved by user
2. **Task 2: Synthetic fixture generator + Wave 0 check unit test** - `32b2649` (test)
3. **Task 3: Cross-compile + toolchain config + gitignore** - `04f01c4` (chore)

**Plan metadata:** (this commit) `docs(74-01): complete spoton-helper scaffold plan`

## Files Created/Modified
- `spoton-helper/Cargo.toml` - crate manifest (clap/serde_json/sha2/anyhow/thiserror only, `overflow-checks = true` release profile)
- `spoton-helper/Cargo.lock` - locked dependency graph
- `spoton-helper/src/main.rs` - clap derive parser + subcommand dispatch + uniform JSON error contract
- `spoton-helper/src/check.rs` - D-08 JSON emitter (`check::run`)
- `spoton-helper/src/arch.rs` - `read_arch(&[u8]) -> Option<&'static str>`, dependency-free ELF e_machine read
- `spoton-helper/src/patch/mod.rs` - `PatchStatus` struct + `scan_status`/`run` stubs (Wave 2 contract)
- `spoton-helper/src/protobuf_cmd.rs` - `run` stub (Wave 2 contract)
- `spoton-helper/tests/fixture.rs` - `write_fixture` synthetic-binary generator + `check_json_schema`/`check_rejects_non_elf` tests
- `spoton-helper/Cross.toml` - 3 musl target sections (x86_64/aarch64/armv7) with bindir-mapping header comment
- `spoton-helper/rust-toolchain.toml` - pins `stable` channel + the 3 musl targets
- `spoton-helper/.gitignore` - excludes `/target`

## Decisions Made
- Skipped an external tempdir crate dependency in `tests/fixture.rs`; a minimal `Drop`-based `TempDir` helper (PID + atomic counter naming, `remove_dir_all` on drop) keeps the crate's total dependency surface at exactly the five named in Cargo.toml, consistent with the threat model's "no network/async" posture (T-74-SC).
- Cross.toml deliberately scoped to the 3 targets the plan named (x86_64/aarch64/armv7 musl) rather than mirroring `librespot-spoton/Cross.toml`'s 6-target superset (i386-linux, arm-linux, Windows) — spoton-helper ships only for the architectures Soloist itself is distributed for.

## Deviations from Plan

None — plan executed exactly as written. Task 1 was previously completed and approved via the tracer feedback gate; Tasks 2 and 3 followed the plan's action blocks directly with no auto-fixes needed.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Wave 2 (Plan 02, patch engine) can now implement `patch::scan_status`/`patch::run` bodies without touching `check.rs` or `main.rs` — the stub signatures are the proven contract.
- Wave 2 patch tests can extend `tests/fixture.rs::write_fixture` by injecting marker byte sequences into the same fixture body rather than building a new harness.
- Plan 03 (protobuf converter) has its `protobuf_cmd::run` stub and JSON error contract ready to replace.
- Cross-compile config (Cross.toml + rust-toolchain.toml) is ready for CI wiring once the patch/protobuf subcommands are real; no `cross build` was run in this plan (not required by verification — build/test used the native `cargo build`/`cargo test` toolchain).

---
*Phase: 74-spoton-helper-binary*
*Completed: 2026-08-28*

## Self-Check: PASSED

All 10 created files found on disk; all 3 task commits (f53544f, 32b2649, 04f01c4) found in git log.
