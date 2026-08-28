---
phase: 74-spoton-helper-binary
plan: 04
subsystem: infra
tags: [github-actions, cross-rs, perl, lms-plugin, ci-cd, soloist]

# Dependency graph
requires:
  - phase: 74-spoton-helper-binary (plan 02)
    provides: patch engine, empty public patterns.rs stub table with PRIVATE-INJECTION POINT
  - phase: 74-spoton-helper-binary (plan 03)
    provides: protobuf subcommand, Cross.toml 3-target musl config
provides:
  - build-spoton-helper CI job (3 musl targets) folded into the release plugin zip under Bin/<arch>/
  - Soloist.pm auto-patch orchestration (_helperPath/_runHelperJson/_autoPatch) wired after download activation
  - t/33_soloist_patch.t idempotency + fail-open Perl coverage
  - CHANGELOG entry documenting the new binary and auto-patch behavior
affects: [phase-75-spclient, phase-77-uat]

# Actuals (#2632)
actuals:
  tokens: 6762
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CI same-workflow artifact constraint (CR-02): build-spoton-helper lives inside build-librespot.yml, not a standalone workflow, so the release job's download-artifact@v4 can see it"
    - "Collision-safe artifact naming: helper-<bin_dir> (not spoton-helper-<bin_dir>) to avoid the librespot spoton-* glob loops"
    - "Compliance-boundary private-pattern injection: guarded CI step, no-op when secrets absent, keeps public repo patterns.rs empty"
    - "Perl auto-patch orchestration: check-then-patch idempotency probe, fail-open on any incompleteness, array-form open('-|', ...) only"

key-files:
  created:
    - t/33_soloist_patch.t
  modified:
    - .github/workflows/build-librespot.yml
    - Plugins/SpotOn/Soloist.pm
    - t/26_soloist_check.t
    - t/27_soloist_key.t
    - t/30_soloist_daemon.t
    - CHANGELOG.md

key-decisions:
  - "Helper artifacts use the `helper-<arch>` prefix, never `spoton-helper-<arch>`, so the existing `release-artifacts/spoton-*/` librespot fold-in loop never matches them"
  - "build-spoton-helper runs unconditionally on tag/workflow_dispatch, with no detect-changes gate -- the helper compiles in seconds and must never ship stale"
  - "Private pattern injection is a guarded, secrets-driven CI step (SPOTON_PRIVATE_PATTERNS_REPO/_TOKEN); those secrets do not currently exist in this repo, so the step is presently always a no-op and the shipped binary keeps the public empty patterns.rs table"
  - "_autoPatch is fail-open: any failure (missing helper, invocation error, patch not completing) logs a warning and lets Soloist run unpatched -- core playback is never blocked by patch failure"

requirements-completed: [D-03, D-09]

coverage:
  - id: D1
    description: "CI builds spoton-helper for x86_64/aarch64/armhf-linux and folds it into the release plugin zip under Bin/<arch>/ (D-09)"
    requirement: "D-09"
    verification:
      - kind: other
        ref: "python3 yaml-parse assertion + grep for release-artifacts/helper-* and absence of release-artifacts/spoton-helper- in .github/workflows/build-librespot.yml"
        status: pass
    human_judgment: true
    rationale: "The workflow YAML is structurally verified (job exists, needs list, artifact-name collision avoidance) but a live tag-push CI run was not executed as part of this plan -- an actual GitHub Actions run should be observed at the next release to confirm the fold-in behaves as designed."
  - id: D2
    description: "Soloist.pm auto-patches once after a successful download+activation, idempotent (check-first) and fail-open (D-03)"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/33_soloist_patch.t (14 assertions: idempotent skip, patch-on-unpatched with array-form argv, missing-helper fail-open, patch-failure warning-without-dying, source assertions for wiring + array-form exec)"
        status: pass
    human_judgment: false

# Metrics
duration: ~20min
completed: 2026-08-28
status: complete
---

# Phase 74 Plan 04: CI Ship + Auto-Patch Wiring Summary

**build-spoton-helper CI job cross-builds the 3-arch helper into the release plugin zip (D-09), and Soloist.pm now runs it exactly once, idempotently and fail-open, right after a fresh Soloist download activates (D-03).**

## Performance

- **Duration:** ~20 min
- **Completed:** 2026-08-28T16:50:22Z
- **Tasks:** 3
- **Files modified:** 7 (1 created, 6 modified)

## Accomplishments
- Added a `build-spoton-helper` matrix job to `build-librespot.yml` (modeled on `build-fake-libpulse`) that cross-builds all three musl targets, runs unconditionally on tag/workflow_dispatch (no `detect-changes` gate), and uploads collision-safe `helper-<bin_dir>` artifacts.
- Wired `build-spoton-helper` into the `release` job's `needs:` and added a fold-in loop in the "Assemble plugin zip" step that copies each `helper-*` artifact into `Plugins/SpotOn/Bin/<arch>/spoton-helper`, mirroring the existing `fake-libpulse-*` fold-in.
- Added a guarded, secrets-driven private-pattern-injection step (compliance boundary from Plan 02) — a no-op today since the referenced secrets do not exist in this repo, so the shipped binary keeps the public empty `patterns.rs` table and `patch` safely reports `status: "unsupported"`.
- Added `_helperPath()`, `_runHelperJson()`, and `_autoPatch()` to `Soloist.pm`, wired `_autoPatch($canonical)` into `_onSoloistDownloadDone()` immediately after the successful `_versionCheck` activation branch.
- Added `t/33_soloist_patch.t` (14 assertions) covering the idempotent skip, the patch-on-unpatched path with array-form argv verification, missing-helper fail-open, and patch-failure-without-dying.
- Added a CHANGELOG entry under `[Unreleased]` documenting the new `spoton-helper` binary, its three subcommands, the 3-arch CI build, and automatic one-time patching.

## Task Commits

Each task was committed atomically:

1. **Task 1: CI — build-spoton-helper job + plugin-zip fold-in** - `b8fbd2f` (feat)
2. **Task 2: Soloist.pm auto-patch wiring + idempotency test** - `f60e9e4` (feat)
3. **Task 3: CHANGELOG entry** - `171e329` (docs)

_Note: Task 2's commit also includes the JSON stub fix to t/26/t/27/t/30 described under Deviations below._

## Files Created/Modified
- `.github/workflows/build-librespot.yml` - New `build-spoton-helper` matrix job (3 musl targets, guarded pattern-injection step, `helper-<arch>` artifact naming); `release` job `needs:` + zip fold-in loop
- `Plugins/SpotOn/Soloist.pm` - `_helperPath()`, `_runHelperJson()`, `_autoPatch()`; call wired into `_onSoloistDownloadDone()`; added `use JSON::XS::VersionOneAndTwo;`
- `t/33_soloist_patch.t` - New Perl test: idempotency + fail-open coverage for auto-patch (14 assertions)
- `t/26_soloist_check.t`, `t/27_soloist_key.t`, `t/30_soloist_daemon.t` - Added the `JSON::XS::VersionOneAndTwo` stub (delegates to `JSON::PP`) so `require Plugins::SpotOn::Soloist` still loads under the sandbox test harness after Soloist.pm gained a new `use` dependency
- `CHANGELOG.md` - `[Unreleased]` entry for the spoton-helper binary

## Decisions Made
- Helper artifacts use the `helper-<arch>` prefix (never `spoton-helper-<arch>`) — the existing `release-artifacts/spoton-*/` librespot fold-in loop would otherwise mis-match and mis-copy them.
- `build-spoton-helper` has no `detect-changes` gate and always runs on tag/workflow_dispatch — the helper compiles in seconds, so unconditional building is cheaper than change-detection plumbing and structurally prevents a stale-helper release (RESEARCH.md Pitfall 3).
- Private pattern injection is implemented as a guarded CI step keyed on `secrets.SPOTON_PRIVATE_PATTERNS_REPO`/`SPOTON_PRIVATE_PATTERNS_TOKEN`. Neither secret currently exists in this repository, so in practice the step is presently always skipped and every CI-built binary ships the public no-op patch table — this is intentional per the Plan 02 compliance-boundary decision and requires no further action until/unless a private pattern source is provisioned.
- `_autoPatch()` is unconditionally fail-open: a missing helper, a failed invocation, or a patch call that doesn't report `patched: true` all resolve to a warning log and Soloist continuing to run unpatched. No error path in this function can block or delay playback.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added `JSON::XS::VersionOneAndTwo` stub to 3 pre-existing test files broken by Soloist.pm's new `use` dependency**
- **Found during:** Task 2 (Soloist.pm auto-patch wiring)
- **Issue:** Soloist.pm now `use`s `JSON::XS::VersionOneAndTwo` (needed by `_runHelperJson()`'s `from_json`). Running the full test suite after this change revealed `t/26_soloist_check.t`, `t/27_soloist_key.t`, and `t/30_soloist_daemon.t` all `require Plugins::SpotOn::Soloist` in an isolated sandbox that did not stub this module, so all three started failing to load with `Can't locate JSON/XS/VersionOneAndTwo.pm`.
- **Fix:** Added the same `JSON::PP`-backed stub already used by numerous other test files (t/07, t/09, t/33, etc.) to each of the three affected files.
- **Files modified:** `t/26_soloist_check.t`, `t/27_soloist_key.t`, `t/30_soloist_daemon.t`
- **Verification:** `prove -l t/` — all 33 test files, 1370 assertions, pass.
- **Committed in:** `f60e9e4` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug/regression from this plan's own change)
**Impact on plan:** Necessary to keep the pre-existing test suite green; no scope creep beyond adding a module stub already established as the project's pattern for this exact situation.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required. (The private-pattern-injection secrets are optional infrastructure for a future release-signing step, not a blocker for this plan or for shipping the public no-op binary.)

## Known Stubs
- **`spoton-helper/src/patch/patterns.rs`** — intentionally empty per-arch tables in the public checkout (Plan 02 decision, unchanged by this plan). `patch` reports `status: "unsupported"` and Soloist runs with lifetime/FLAC24 patches unapplied until a private pattern source is provisioned in CI via the `SPOTON_PRIVATE_PATTERNS_REPO`/`SPOTON_PRIVATE_PATTERNS_TOKEN` secrets added in this plan's Task 1. This is the documented, deliberate compliance boundary — not a defect to fix in a later phase.

## Next Phase Readiness
- Phase 74 is functionally complete: the helper builds, ships in the plugin zip, and auto-patches on Soloist install.
- Phase 75 (SpClient.pm) can optionally use `spoton-helper protobuf` as a protobuf⇄JSON backend per D-02.
- Phase 77 UAT should verify the actual audible/CDN effect of the FLAC24 patch once a private pattern source is provisioned (D-06, deliberately deferred — not blocking this phase).
- No blockers.

---
*Phase: 74-spoton-helper-binary*
*Completed: 2026-08-28*

## Self-Check: PASSED
- FOUND: .planning/phases/74-spoton-helper-binary/74-04-SUMMARY.md
- FOUND: commit b8fbd2f (Task 1)
- FOUND: commit f60e9e4 (Task 2)
- FOUND: commit 171e329 (Task 3)
- FOUND: build-spoton-helper job in .github/workflows/build-librespot.yml
- FOUND: t/33_soloist_patch.t
