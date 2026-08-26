---
phase: 73-soloist-connect-mode
plan: 04
subsystem: infra
tags: [perl, lms-plugin, i18n, daemon-lifecycle, settings-ui, sync-groups]

requires:
  - phase: 73-soloist-connect-mode (plan 01)
    provides: Unified::SoloistDaemon lifecycle class, per-player data/cache dirs, vendored Protocol::WebSocket (D-08)
  - phase: 73-soloist-connect-mode (plan 02)
    provides: spoton_soloist_expiry_days / spoton_soloist_expired cache flags, build-expiry escalation
  - phase: 73-soloist-connect-mode (plan 03)
    provides: Soloist Browse on the persistent daemon (Modell B), spoton_soloist_ws_<mac> per-mac WS status cache (laid down specifically for this plan's Settings display)
provides:
  - Phase-72 per-track path fully retired — no sol convert rule, no sol content-type row, no per-track launcher generator, no sox dependency; Plugin.pm boot wiring simplified to ensureBinary()-only
  - Plugins::SpotOn::Soloist::isPairedForClient($mac) — per-player pairing heuristic replacing the retired shared dataDir()/isPaired() pair
  - Sync-group pinning for the soloist backend (Pattern 7), proven against the real DaemonManager module — no production code changes needed, mechanism already generic
  - Settings per-player daemon/pairing status table (soloistPlayers) + build-expiry warning display (soloistExpiryDays/soloistExpiryWarn/soloistExpired/soloistExpiryText), sourced from DaemonManager->helperForClient + Soloist::isPairedForClient + the 73-02/73-03 cache keys
  - App-tap pairing instructions (11 languages) replacing the SSH --pair howto; 4 new i18n keys for daemon/expiry status
  - CHANGELOG.md Unreleased entry for the Soloist Connect Mode phase
affects: [75-soloist-uat-release]

actuals:
  tokens: 18300
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Per-player status derived at Settings render time from three independent sources (DaemonManager registry, per-player data-dir presence heuristic, per-mac WS status cache) rather than a single daemon-owned status object -- each source degrades independently (no daemon tracked / no data dir yet / cache entry expired) without the whole row erroring"
    - "Sync-group daemon delegation is backend-agnostic by construction (initHelpers()/deviceNameForClient()/the sync-change handler operate on %helperInstances values generically) -- a new daemon subclass gets the mechanism for free, provable via isa()-blessed test doubles rather than needing new production code"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/custom-convert.conf
    - Plugins/SpotOn/custom-types.conf
    - Plugins/SpotOn/Soloist.pm
    - Plugins/SpotOn/Plugin.pm
    - Plugins/SpotOn/Settings.pm
    - Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html
    - Plugins/SpotOn/strings.txt
    - CHANGELOG.md
    - t/03_convert_conf.t
    - t/04_types_conf.t
    - t/26_soloist_check.t
    - t/28_soloist_dispatch.t
    - t/30_soloist_launcher.t (renamed to t/30_soloist_daemon.t)

key-decisions:
  - "Settings.pm's isPaired()/launcherPath() calls (broken the instant Task 1 deleted their targets) were fixed inline during Task 1 itself, not deferred to Task 3 -- required to keep `prove -l t/` green per Task 1's own acceptance gate (Rule 3: blocking issue caused directly by this task's own changes). Task 3 then replaced the placeholder comment with the full soloistPlayers implementation, so no work was duplicated."
  - "Task 2 found NO gap in the librespot sync machinery (initHelpers()'s slave-delegates-to-master branch, deviceNameForClient()'s suffix/cap, the sync-change handler's name-comparison restart) when applied to SoloistDaemon -- all three operate generically on %helperInstances values via isa()/accessor calls with no backend-specific branching, so Pattern 7's '1:1 transfer' premise is proven rather than patched. No DaemonManager.pm/SoloistDaemon.pm changes were needed."
  - "isPairedForClient($mac) reuses the exact same non-dot-entry heuristic the retired shared isPaired() used (Soloist's own on-disk pairing artifact format is still unverified per RESEARCH A3), now applied to dataDirForClient($mac) instead of the single shared dataDir()"
  - "WS auth state ('logged_in') is not a separate new i18n string -- folded into the daemon-status color (green only when daemonAlive AND logged_in, orange when daemon alive but not yet authenticated, red when daemon not alive) rather than inventing a key beyond the plan's literal 4-key list"
  - "soloistExpiryText is a Settings.pm-computed helper param (sprintf(string('PLUGIN_SPOTON_SOLOIST_EXPIRY_DAYS'), $days), mirroring Plugin.pm's existing sprintf(cstring(...), $n) convention) rather than pushing %s-substitution into the TT template, which has no established parametrized-string filter in this codebase"
  - "The actual 11-language set in this codebase is CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV (Polish, not Finnish) -- verified against strings.txt's existing language-line distribution before writing any translations, overriding the FI assumption in the task brief"

patterns-established: []

requirements-completed: [D-01, D-02, D-03]

coverage:
  - id: D1
    description: "Phase-72 per-track path retired end to end: sol convert rule, sol content-type row, launcher generator (ensureLauncher/_launcherScript/launcherPath/dataDir/isPaired), addFindBinPaths registration, and Plugin.pm's ensureLauncher boot branch all removed; isPairedForClient($mac) added as the per-player replacement heuristic; Settings.pm's now-broken isPaired()/launcherPath() calls fixed inline"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "t/03_convert_conf.t, t/04_types_conf.t, t/30_soloist_daemon.t, t/26_soloist_check.t, t/27_soloist_key.t"
        status: pass
      - kind: other
        ref: "grep -v '^\\s*#' custom-convert.conf | grep -c spoton-soloist == 0; grep -c sox == 0; grep -v '^#' custom-types.conf | grep -c '^sol\\b' == 0; grep -c 'sub ensureLauncher|sub _launcherScript|sub launcherPath' Soloist.pm == 0; grep -c 'sub isPairedForClient' Soloist.pm == 1"
        status: pass
    human_judgment: false
  - id: D2
    description: "Sync-group pinning for the soloist backend (Pattern 7): a synced slave-with-master pair delegates the daemon to the master's MAC and stops the slave's own previously-tracked daemon; deviceNameForClient()'s sync-group suffix stays within the 60-char cap and is exactly what the soloist start path (_spawnArgs) consumes; the sync-change handler's name-comparison restart (stopForSync when idle) applies to a SoloistDaemon instance identically to a librespot Daemon. No gap found -- no production code changed."
    requirement: "D-01, D-02"
    verification:
      - kind: unit
        ref: "t/28_soloist_dispatch.t (29 assertions total, 13 new for this task, run against the REAL DaemonManager module -- not a stub of it)"
        status: pass
      - kind: unit
        ref: "t/29_soloist_browse.t (unaffected regression check)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Settings shows live per-player Soloist state (daemon running/stopped, paired/not-paired, WS auth state via status color) and a build-expiry countdown with warning/error styling, sourced from DaemonManager->helperForClient + Soloist::isPairedForClient + the 73-02/73-03 cache keys (spoton_soloist_ws_<mac>, spoton_soloist_expiry_days, spoton_soloist_expired); all soloist-specific computation gated behind backend=soloist so librespot installs see zero param/render change"
    requirement: "D-01, D-02"
    verification:
      - kind: unit
        ref: "t/09_settings.t (backend=soloist and backend=librespot handler() paths both exercised, full suite green)"
        status: pass
      - kind: other
        ref: "grep -c soloistPlayers Settings.pm >= 1; grep -c soloistLauncherPath Settings.pm == 0 (plan's own acceptance criteria)"
        status: pass
    human_judgment: true
    rationale: "The Settings page's actual visual rendering (per-player table layout, color-coded status dots, expiry warning styling) was not screenshotted against a live LMS instance in this execution environment -- t/09_settings.t verifies the Perl template-param computation (handler() populates soloistPlayers/soloistExpiry* correctly for both backend states) but not the rendered HTML's visual appearance. Parked as UAT alongside the phase's other live-environment checks (WINDOWS.md)."
  - id: D4
    description: "i18n: PLUGIN_SPOTON_SOLOIST_PAIR_HOWTO rewritten for the app-tap flow (no SSH, no command line); PLUGIN_SPOTON_SOLOIST_NOT_PAIRED updated to the new per-player consequence wording; 4 new keys (DAEMON_RUNNING/DAEMON_STOPPED/EXPIRY_DAYS/EXPIRED) added -- all with real translations across the actual 11-language set (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV), never EN fallback"
    requirement: null
    verification:
      - kind: unit
        ref: "t/02_strings.t (11-language completeness enforced for every new/changed key)"
        status: pass
      - kind: other
        ref: "each new key block manually verified at 11 language lines via awk; grep -c PLUGIN_SPOTON_SOLOIST_EXPIRED strings.txt == 1; grep -c NEEDS_LMS91 strings.txt == 0 (no version-gate string, D-08)"
        status: pass
    human_judgment: false
  - id: D5
    description: "CHANGELOG.md Unreleased entry documenting the persistent daemon, app-tap pairing, restored seek, and expiry warning, without inventing a version number (per user preference: version numbers are always agreed with the user, never self-assigned)"
    requirement: null
    verification:
      - kind: other
        ref: "grep -n Soloist CHANGELOG.md (entry present under the existing empty ## [Unreleased] header, no new version heading added)"
        status: pass
    human_judgment: false

duration: ~40min
completed: 2026-08-26
status: complete
---

# Phase 73 Plan 04: Soloist Connect Mode Cleanup — Launcher Retirement, Sync Pinning, Settings i18n Summary

**Retired the Phase-72 per-track launcher/sol-rule/sox path entirely, proved the librespot sync-group mechanism already works unmodified for the persistent Soloist daemon (no code changes needed), and gave Settings a live per-player daemon/pairing/build-expiry status display with a fully-translated app-tap pairing howto across all 11 languages.**

## Performance

- **Duration:** ~40 min
- **Tasks:** 3
- **Files modified:** 13 (12 modified, 1 renamed+rewritten: t/30_soloist_launcher.t → t/30_soloist_daemon.t)

## Accomplishments

- **Phase-72 per-track path is completely gone.** `custom-convert.conf`'s `sol pcm * *` rule (the last remaining external-converter dependency, `sox`) and `custom-types.conf`'s `sol` content-type row are deleted byte-precisely (soc/son blocks stay byte-identical to their pre-Phase-72 content). `Soloist.pm` lost the entire launcher generator (`ensureLauncher`/`_launcherScript`/`launcherPath`/the shared `dataDir()`/`isPaired()` pair) and its `Slim::Utils::Misc::addFindBinPaths()` registration — `findbin` is once again completely unused, matching the module's original cachedir-based-discovery-only design. `Plugin.pm`'s boot wiring collapsed to a single `ensureBinary()` call for `backend=soloist`, no `ensureLauncher()` else-branch. A new `isPairedForClient($mac)` reuses the exact same non-dot-entry-in-data-dir heuristic per player instead of the single shared dir. Old data written by a Phase-72 pairing session under the shared `data/` dir is left untouched on disk — orphaned but harmless, since no code path reads it anymore.
- **Sync-group behavior for the soloist backend is now pinned by tests against the REAL `DaemonManager` module** (not a stub of it) — and the finding is that **no production code needed to change**. `initHelpers()`'s slave-delegates-to-master branch, `deviceNameForClient()`'s sync-suffix/60-char cap, and the sync-change handler's name-comparison `stopForSync()` restart all operate generically on `%helperInstances` values via `isa()`/accessor calls with zero backend-specific branching — Pattern 7's "transfers 1:1" premise from the RESEARCH doc is proven, not patched. 13 new assertions in `t/28_soloist_dispatch.t` cover: a synced slave+master pair delegating the daemon to the master's MAC while stopping the slave's own previously-tracked daemon; `deviceNameForClient()`'s suffix consumed exactly by the soloist start path (`_spawnArgs`); and the sync-change handler applying `stopForSync()` to an idle `SoloistDaemon` whose name no longer matches.
- **Settings now shows live per-player Soloist state.** A new `soloistPlayers` array (one row per connected client, computed only when `backend=soloist`) reports `name`/`mac`/`paired` (via `isPairedForClient`)/`daemonAlive` (via `DaemonManager->helperForClient` + `isa` check)/`loggedIn`/`isActive` (from the `spoton_soloist_ws_<mac>` cache snapshot the 73-02/73-03 plans already wrote in preparation for this display). A build-expiry section reads `spoton_soloist_expiry_days`/`spoton_soloist_expired` and renders a countdown (warning styling at ≤14 days, hard error once expired) — no LMS-version gate string, since the vendored `Protocol::WebSocket` (D-08) means Soloist Connect works on any LMS 8.0+ install.
- **The pairing howto is rewritten for the app-tap flow** across all 11 languages actually used in this codebase (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV — verified against the file's real language distribution, not assumed): enable the Soloist backend, wait for the daemon, select the player once in the Spotify app's device picker. No SSH, no command line. The not-paired consequence text was updated to match (playback fails until the device is selected once in the app). Two brand-new status keys (`DAEMON_RUNNING`/`DAEMON_STOPPED`) and two expiry keys (`EXPIRY_DAYS` taking a `%s` day count, `EXPIRED`) round out the i18n additions — all genuinely translated, never EN fallback.
- **CHANGELOG.md** gained an `## [Unreleased]` entry (no invented version number, per standing project convention) covering the persistent daemon, app-tap pairing, restored seek, and the expiry warning, plus a Removed note for the retired sox/launcher path.

## Task Commits

1. **Task 1: Retire the Phase-72 per-track path — launcher, sol rules, sol type, tests** - `76805c2` (feat)
2. **Task 2: Sync-group pinning — tests + gap fixes** - `191bcec` (test)
3. **Task 3: Settings daemon status + pairing howto rewrite + i18n (11 languages) + CHANGELOG** - `3ccf6db` (feat)

## Files Created/Modified

- `Plugins/SpotOn/custom-convert.conf` - deleted the `sol pcm * *` rule; soc/son byte-identical
- `Plugins/SpotOn/custom-types.conf` - deleted the `sol` content-type row
- `Plugins/SpotOn/Soloist.pm` - removed the entire Phase-72 launcher block; added `isPairedForClient($mac)`; updated module header comment
- `Plugins/SpotOn/Plugin.pm` - simplified boot wiring to `ensureBinary()`-only for `backend=soloist`
- `Plugins/SpotOn/Settings.pm` - dropped broken `isPaired()`/`launcherPath()` params (Task 1 fix); added `soloistPlayers`/`soloistExpiryDays`/`soloistExpiryWarn`/`soloistExpired`/`soloistExpiryText` (Task 3)
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html` - per-player status table + expiry line replacing the retired shared pairing-status block
- `Plugins/SpotOn/strings.txt` - rewrote PAIR_HOWTO/NOT_PAIRED, added 4 new keys, all 11 languages
- `CHANGELOG.md` - Unreleased entry
- `t/03_convert_conf.t`, `t/04_types_conf.t` - inverted sol-rule/sol-row assertions to their absence
- `t/26_soloist_check.t` - dropped the retired `addFindBinPaths` stub/assertion, asserted its absence instead
- `t/28_soloist_dispatch.t` - 13 new sync-group delegation/naming/restart assertions against the real `DaemonManager`
- `t/30_soloist_launcher.t` → `t/30_soloist_daemon.t` (renamed+rewritten) - per-player dir shapes, `isPairedForClient`, `readKey`, `SoloistDaemon::_spawnArgs`, retired-symbol absence

## Decisions Made

See `key-decisions` in frontmatter for the full list. Highlights: the Settings.pm breakage caused by Task 1's own deletions was fixed inline in Task 1 (Rule 3), not deferred, to keep the suite green at every commit boundary; Task 2 found the sync mechanism already fully generic and made zero production-code changes; WS auth state is shown via status color rather than a fifth new i18n key; and the actual 11-language set was verified against the file itself (PL, not FI) before writing any translations.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Settings.pm's isPaired()/launcherPath() calls broken by Task 1's own deletions**
- **Found during:** Task 1
- **Issue:** Settings.pm's `handler()` unconditionally called `Plugins::SpotOn::Soloist::isPaired()` and `::launcherPath()` on every invocation (regardless of backend) to populate `soloistPaired`/`soloistLauncherPath` template params. Task 1 deletes both subs from Soloist.pm, which would make every `handler()` call (exercised extensively by t/09_settings.t) die with "Undefined subroutine" — breaking Task 1's own "prove -l t/ fully green" acceptance gate.
- **Fix:** Removed the two broken param assignments in Settings.pm, replaced with a comment pointing to Task 3's full replacement.
- **Files modified:** Plugins/SpotOn/Settings.pm
- **Verification:** `prove -l t/09_settings.t` and `prove -l t/` both green after the fix.
- **Committed in:** `76805c2` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (Rule 3 — blocking issue directly caused by this plan's own Task 1 changes)
**Impact on plan:** Necessary to keep every task's own acceptance gate (`prove -l t/` fully green) satisfied at each commit boundary. No scope creep — Task 3 still delivered its own full `soloistPlayers` implementation on schedule; this was a minimal placeholder removal, not a preview of Task 3's work.

## Issues Encountered

None — `prove -l t/` was fully green after each task's changes (32 files, 1305→1315 tests across the plan as new assertions were added in Tasks 2/3; no regressions in any pre-existing test file, including t/29/t/31/t/32 as required by Task 1's acceptance criteria).

## User Setup Required

None — no external service configuration required.

## Known Stubs

None — no hardcoded empty values or placeholder UI reach the user. `soloistPlayers` defaults to an empty arrayref when `backend != 'soloist'` (correct: the template's own `#soloist-fields` div is `display:none` in that state, matching pre-existing behavior) or when no players are connected (an empty table renders correctly, no stub content shown).

## TROUBLESHOOTING notes (per plan's `<output>` instruction, for the next docs review)

- **Orphaned Phase-72 shared data dir:** `cachedir/spoton/soloist/data/` (the retired shared `dataDir()`) is left untouched on disk by this plan. If a user previously ran the Phase-72 SSH `--pair` flow, that directory may still contain a paired session — it is now completely inert (no code path reads it), but it is not cleaned up automatically. A future release could offer a one-time migration hint or manual cleanup note if this proves confusing in the field.
- **Stale per-track launcher script:** the generated `cachedir/spoton/soloist/spoton-soloist` wrapper script (if one exists from a prior Phase-72 install) is not deleted by this plan either. It is inert without the `sol` convert-conf rule and content-type row (nothing invokes it), but it remains on disk until a manual cache-clear or reinstall.
- **Vendored `Protocol::WebSocket` (D-08):** Soloist Connect works on LMS 8.0+ via the plugin's own vendored copy (`Plugins/SpotOn/Vendor/Protocol/WebSocket/`), preferring an LMS-bundled copy (9.1+) when present. No version-specific troubleshooting note is needed for the Settings page — there is no `soloist_missing_wslib` prereq state a user can hit.

## Next Phase Readiness

- **D-01/D-02/D-03 are now complete end to end** for Phase 73: the persistent daemon is the sole soloist execution path, sync groups are pinned by tests, and the daemon/pairing/expiry state is visible in Settings across 11 languages.
- **Live UAT still pending** (carried forward from 73-01/73-02/73-03, tracked in `.planning/WINDOWS.md` #1-#4): the actual Settings page render (per-player table, color-coded status, expiry warning styling) has not been screenshotted against a live LMS + paired daemon in this execution environment — t/09_settings.t verifies the Perl-side param computation only. Phase 75 (Soloist UAT + Release) is the natural place to close this out alongside the other parked live-environment scenarios.
- No blockers identified for Phase 74 (Soloist Polish) or Phase 75 (Soloist UAT + Release).

---
*Phase: 73-soloist-connect-mode*
*Completed: 2026-08-26*

## Self-Check: PASSED
