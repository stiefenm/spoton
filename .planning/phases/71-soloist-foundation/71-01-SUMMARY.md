---
phase: 71-soloist-foundation
plan: 01
subsystem: infra
tags: [perl, lms-plugin, spotify, soloist, byok, atomic-write, simpleasynchttp]

# Dependency graph
requires: []
provides:
  - "Plugins::SpotOn::Soloist module (get/ensureBinary/download/_versionCheck/storeKey/hasKey/keyPath/clearKey/libPath)"
  - "SOLOIST_VERSION => '1.3.7.489' pinned constant (D-05, checkpoint-resolved)"
  - "cachedir/spoton/soloist/<bindir>/soloist and cachedir/spoton/soloist/spak.key runtime layout"
affects: [71-02-daemonmanager-backend-dispatch, 71-03-settings-backend-ux, phase-72-soloist-browse-playback]

# Actuals (#2632)
actuals:
  tokens: 9370
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Cachedir-based binary discovery (get() constructs the expected path directly, no findbin()/addFindBinPaths())"
    - "Array-form open('-|', $binary, $flag) and system('tar', ...) -- never shell strings/backticks"
    - "Staging-tempfile + rename + chmod(0600) atomic secret-file write (mirrors Credentials.pm)"
    - "Fail-closed post-download version verification (mismatch => not activated)"

key-files:
  created:
    - Plugins/SpotOn/Soloist.pm
    - t/26_soloist_check.t
    - t/27_soloist_key.t
  modified:
    - t/05_perl_syntax.t

key-decisions:
  - "D-05 checkpoint resolved by the user: SOLOIST_VERSION pinned to 1.3.7.489, validated against a real x86_64 download (flat archive, --version works without --api-key)"
  - "Split the single-file module into 3 atomic commits matching the plan's task boundaries (skeleton/arch-map -> download pipeline -> key storage) even though it was authored as one coherent pass"
  - "downloadBinary() carries its own D-04 no-overwrite guard (not just ensureBinary()'s), so any direct caller is structurally protected against clobbering a cached binary"

patterns-established:
  - "Soloist.pm as a structural twin of Helper.pm with divergent discovery strategy (cachedir vs findbin) -- documented inline for future backend modules"

requirements-completed: [SOLO-BIN]

coverage:
  - id: D1
    description: "Soloist.pm arch-map resolves osArch to Spotify download-vocab and SpotOn bindir-vocab correctly for aarch64/arm/x86_64"
    requirement: "SOLO-BIN"
    verification:
      - kind: unit
        ref: "t/26_soloist_check.t#Test 1-3 (arch-map)"
        status: pass
    human_judgment: false
  - id: D2
    description: "get() resolves a cached, version-matched binary and returns undef without crashing when absent or on version mismatch (D-05 fail-closed)"
    requirement: "SOLO-BIN"
    verification:
      - kind: unit
        ref: "t/26_soloist_check.t#Test 7-9 (get() undef / cached / version-mismatch)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Download-and-cache pipeline: SimpleAsyncHTTP saveAs -> array-form tar extraction -> version check -> fail-closed activation; D-04 no-overwrite guard on both entry points"
    requirement: "SOLO-BIN"
    verification:
      - kind: unit
        ref: "t/26_soloist_check.t#Test 10-14 (no-redownload, full pipeline, error path, activation coupling)"
        status: pass
    human_judgment: false
  - id: D4
    description: "storeKey()/hasKey()/clearKey() write spak.key atomically with mode 0600, never log the raw key (T-71-02)"
    requirement: "SOLO-BIN"
    verification:
      - kind: unit
        ref: "t/27_soloist_key.t#Test 2,6,7,8 (mode 0600, no-log runtime+static assertions, atomic staging/rename)"
        status: pass
    human_judgment: false

duration: ~55min
completed: 2026-08-25
status: complete
---

# Phase 71 Plan 01: Soloist Foundation Tracer Summary

**Cachedir-based Soloist.pm backend module — arch-detection, unversioned-URL download-and-cache with fail-closed version pinning (1.3.7.489), and atomic mode-0600 spak-key storage, all structurally mirroring Helper.pm/Credentials.pm's existing patterns**

## Performance

- **Duration:** ~55 min (including a blocking `checkpoint:decision` pause for the D-05 version pin, resolved by the user)
- **Started:** 2026-08-24 (worktree setup + plan analysis)
- **Completed:** 2026-08-25T00:00:00Z (approx, post-checkpoint continuation)
- **Tasks:** 3/3
- **Files modified:** 4 (1 created module, 2 created test files, 1 registration edit)

## Accomplishments
- `Plugins::SpotOn::Soloist` module implementing the full Phase 71 Plan 01 API surface: `init`, `get`, `ensureBinary`/`downloadBinary`, `_onSoloistDownloadDone`/`_onSoloistDownloadError`, `_versionCheck`, `_versionCompare`, `_arch`, `_downloadUrl`, `_cacheDir`, `keyPath`, `storeKey`, `hasKey`, `clearKey`, `libPath`
- Arch-detection regex-dispatch reconciling Spotify's download vocabulary (`arm64`/`arm32`/`x86_64`) against SpotOn's `Bin/<arch>/` vocabulary (`aarch64-linux`/`armhf-linux`/`x86_64-linux`) — RESEARCH.md Pitfall 4
- Download-and-cache pipeline via `SimpleAsyncHTTP` `saveAs` + array-form `tar xzf` extraction + fail-closed post-download version check, with a structural D-04 no-overwrite guard present at both `ensureBinary()` and `downloadBinary()` entry points
- Atomic `spak.key` write (staging tempfile → unlink-if-exists → rename → `chmod(0600)`), verified with `(stat)[2] & 0777 == 0600`, and a never-logs-the-key discipline verified both at runtime (log capture) and statically (source grep)
- 63 new/extended test assertions across `t/05_perl_syntax.t` (+1), `t/26_soloist_check.t` (41), `t/27_soloist_key.t` (22) — full project suite (`t/*.t`, 1031 tests) green with zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Soloist.pm Skeleton — Arch-Map, get(), Version-Check, libPath** - `11bd93b` (feat)
2. **Task 2: Download-and-cache — SimpleAsyncHTTP saveAs, tar-Extract, Post-Download-Validierung** - `1d56eac` (feat)
3. **Task 3: spak-Key Storage — storeKey/hasKey/keyPath, atomarer 0600-Write** - `dc5bedf` (feat)

**Setup (not a plan task):** `3db47e4` — cherry-picked the phase-planning docs commit (`71-0{1,2,3,4}-PLAN.md`, `ROADMAP.md`) from `main`/`soloist` into this worktree, whose branch predated that commit landing.

_Note: no separate "plan metadata" commit — this is a parallel worktree executor; STATE.md/ROADMAP.md are owned by the orchestrator per the wave protocol._

## Files Created/Modified
- `Plugins/SpotOn/Soloist.pm` - New module: cachedir-based binary lifecycle (arch-map, download, version-pin, spak-key)
- `t/05_perl_syntax.t` - Registered `Soloist.pm` in `@pm_files`
- `t/26_soloist_check.t` - Arch-map, URL construction, anti-pattern greps, get()/version-check behavior, download pipeline, D-04 no-overwrite, error path
- `t/27_soloist_key.t` - spak.key atomic write, mode 0600, no-log discipline, clearKey idempotency

## Decisions Made
- **D-05 (checkpoint, one-way):** `SOLOIST_VERSION => '1.3.7.489'`, resolved by the user with empirical data from a real x86_64 download: flat archive structure (no nested dir), `--version` works without `--api-key`, exact output format `soloist 1.3.7.489 build 1787637711 (20260825) (gb24005ef46) (linux/x86_64)`. `VERSION_FLAG => '--version'` confirmed as the correct flag spelling (resolves RESEARCH.md Assumptions A1/A5 and Open Question 3 for this specific flag).
- **Version-check semantics:** used `_versionCompare(...) == 0` (exact match across `SOLOIST_VERSION`'s 4 segments) rather than a `>=` minimum-version gate — the plan's D-05 language explicitly says a *deviating* version must not activate, not merely an older one.
- **Task-commit sequencing:** the module was authored as one coherent pass (all three tasks' logic together) for design coherence, then deliberately re-split into 3 sequential edits/commits matching the plan's task boundaries, so the git history reflects the intended incremental build-up rather than one monolithic commit.

## Deviations from Plan

None — plan executed exactly as written, using the checkpoint-resolved D-05 value. `_findExtractedBinary()`'s recursive nested-directory fallback (A3) was implemented as specified even though the empirical archive turned out to be flat, per the plan's explicit defensive-fallback instruction.

## Issues Encountered
- **Stale worktree base:** this worktree's branch (`worktree-agent-a27730e01566cae41`) was created from a commit (`8c06025`) that predates the phase-71 planning docs commit (`b13de4a`, "docs(71): create Soloist Foundation phase plan") landing on `main`/`soloist`. Resolved by cherry-picking that docs-only commit (clean apply, merge-base matched HEAD exactly) before any implementation work — see commit `3db47e4`.
- **Checkpoint blocked initial execution:** the plan's first task is a `checkpoint:decision` (D-05, `gate="blocking"`) requiring a human-validated version string from a real binary download. `auto_advance`/`_auto_chain_active` are both `false` in `.planning/config.json`, so this correctly halted execution rather than auto-selecting — the coordinator relayed the resolved value (`1.3.7.489`) with full empirical findings, and execution continued from there.

## User Setup Required
None — no external service configuration required by this plan. (The `user_setup: soloist-binary` item noted in the plan's frontmatter was satisfied by the coordinator's real-binary validation that resolved the D-05 checkpoint.)

## Next Phase Readiness
- `Soloist.pm`'s public API (`get`, `ensureBinary`, `hasKey`, `storeKey`, `libPath`) is ready for Plan 02 (`DaemonManager` backend dispatch) and Plan 03 (`Settings.pm` backend UX + spak-key form handling) to consume directly, per the `key_links` in this plan's frontmatter.
- `libPath()` (`Bin/<bindir>/` for `LD_LIBRARY_PATH`) is wired and tested for arch resolution, ready for Phase 72's Fake-libpulse.so consumption.
- No blockers. Full project test suite green (1031/1031).

---
*Phase: 71-soloist-foundation*
*Completed: 2026-08-25*

## Self-Check: PASSED

- FOUND: Plugins/SpotOn/Soloist.pm
- FOUND: t/26_soloist_check.t
- FOUND: t/27_soloist_key.t
- FOUND: .planning/phases/71-soloist-foundation/71-01-SUMMARY.md
- FOUND commit: 11bd93b (Task 1)
- FOUND commit: 1d56eac (Task 2)
- FOUND commit: dc5bedf (Task 3)
- FOUND commit: 3db47e4 (setup cherry-pick)
