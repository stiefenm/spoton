---
phase: 76-connect-stabilization-flac24-integration
plan: 08
subsystem: settings-docs-uat
tags: [settings, template-toolkit, i18n, roadmap, changelog, uat-checklist, d-07, d-03, d-11]

# Dependency graph
requires:
  - phase: 76-connect-stabilization-flac24-integration
    provides: "76-04: resolveSoloistFormat ogg->auto mapping (the runtime behavior the D-07 display normalization mirrors)"
  - phase: 76-connect-stabilization-flac24-integration
    provides: "76-07: Window-5 FIXED verdict + WINDOWS ledger entry 6 (consumed by ROADMAP cleanup + checklist)"
  - phase: 73-soloist-connect-mode
    provides: "73-VERIFICATION.md human-verification scenarios (Windows 1-4 source material)"
provides:
  - "Backend-conditional Stream Format dropdown: OGG hidden under Soloist via server-rendered TT conditional (D-07)"
  - "Soloist+ogg display normalization in Settings/Player.pm (display-only, stored pref never rewritten)"
  - "Backend-aware PLUGIN_SPOTON_STREAM_FORMAT_DESC in 11 languages"
  - "ROADMAP Phase 76 entry reflecting post-code reality: #149/#150 code-fixed (QT 260817-ana), Window 5 FIXED, spoton-helper patch status truth (SPOTON_PRIVATE_PATTERNS secrets missing)"
  - "CHANGELOG [Unreleased] Added+Fixed entries for all user-visible Phase 76 changes"
  - "76-UAT-CHECKLIST.md — the D-11 consolidated one-pass live-UAT master script, both backends"
affects: [phase-76 UAT session, /gsd-verify-work, phase-77 release prep]

# Actuals (#2632) — pairs with the plan's `estimate` to calibrate future estimates.
actuals:
  tokens: 8500
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Server-rendered TT conditional for backend-dependent settings options on pages without a live backend toggle (vs. the basic.html JS-toggle pattern)"
    - "Display-only pref normalization in the settings handler (template param rewritten, stored pref untouched) to preserve cross-backend user choices"

key-files:
  created:
    - .planning/phases/76-connect-stabilization-flac24-integration/76-UAT-CHECKLIST.md
  modified:
    - Plugins/SpotOn/Settings/Player.pm
    - Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html
    - Plugins/SpotOn/strings.txt
    - .planning/ROADMAP.md
    - CHANGELOG.md

key-decisions:
  - "STREAM_FORMAT_DESC was rewritten (all 11 languages): the old text named OGG as the universal Auto choice, claimed browse-only scope (stale since 76-04 made streamFormat govern Connect too), and pointed at a Connect OGG Override control no longer present on the page — it failed the plan's backend-neutral test"
  - "ROADMAP plan-list checkboxes left untouched ([ ]): plan-progress marking is the orchestrator's write (roadmap update-plan-progress); this plan edited only descriptive truth within the Phase 76 entry"
  - "Checklist ledger mirrors WINDOWS.md entries 1-6 (not 1-5 as the plan text said): entry 6 was appended by 76-07 after plan authoring; the ledger section reflects the actual on-disk ledger"
  - "GH #161/#94 browse-UX human-checks placed in the SpClient/Browse section (4.3/4.4) as backend-independent items tested once, keeping the environment-switch count minimal"

patterns-established:
  - "76-UAT-CHECKLIST.md naming convention: consolidated human-UAT script kept distinct from the verifier-generated 76-UAT.md"

requirements-completed: [D-03, D-07, D-09, D-10, D-11, D-14]

coverage:
  - id: D1
    description: "OGG option renders only when backend != soloist; stored ogg pref displays as Auto under soloist without a pref write; desc string backend-aware in 11 languages"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "prove -l t/09_settings.t t/05_perl_syntax.t t/02_strings.t (437 tests) + full suite prove -l t/ (37 files, 1744 tests, PASS)"
        status: pass
      - kind: static
        ref: "grep: backend x2 in player.html (TT conditional); only set('streamFormat') site is the saveSettings branch — zero set() calls in the normalization block"
        status: pass
    human_judgment: false
  - id: D2
    description: "ROADMAP Phase 76 entry truthful: #149/#150 code-fixed attribution (260817-ana), missing-secrets patch status, Window 5 FIXED, delivered plan set; rest of ROADMAP untouched"
    requirement: "D-03"
    verification:
      - kind: unit
        ref: "prove -l t/33_soloist_patch.t (14 tests, PASS — wiring claim verified) + Soloist.pm _autoPatch read (fail-open, download-activation path)"
        status: pass
      - kind: static
        ref: "grep 260817-ana ==1, grep SPOTON_PRIVATE_PATTERNS ==1 in ROADMAP.md; git diff --stat shows only the Phase 76 entry lines changed (2 lines modified)"
        status: pass
    human_judgment: false
  - id: D3
    description: "CHANGELOG [Unreleased] carries all Phase 76 user-visible changes, no version number"
    requirement: "D-03"
    verification:
      - kind: static
        ref: "grep hits for FLAC/159/131/151/135/161 all >=1; no new version heading added"
        status: pass
    human_judgment: false
  - id: D4
    description: "Consolidated UAT checklist exists with all 6 sections, covers Windows 1-4 + SpClient smoke + D-14 regression + every plan human-check + #149/#150"
    requirement: "D-11"
    verification:
      - kind: static
        ref: "test -s + grep -c '## ' >= 6; grep 149|150 ==5 lines; grep spclient-smoke ==2; human-check mapping table below"
        status: pass
    human_judgment: false
  - id: D5
    description: "The checklist is executed as THE Phase 76 UAT session (one pass, both backends), results recorded in the ledger and fed into /gsd-verify-work"
    requirement: "D-09"
    verification: []
    human_judgment: true
    rationale: "The UAT run itself is the phase's terminal human activity — this plan produces the script, the user executes it (D-09 manual, no automated rig)"

# Metrics
duration: 12min
completed: 2026-08-29
status: complete
---

# Phase 76 Plan 08: Settings, Docs, UAT Checklist Summary

**D-07 dropdown closes the backend split (OGG hidden under Soloist via server-rendered TT conditional, stored ogg displayed as Auto without pref rewrite, desc string backend-aware in 11 languages), ROADMAP Phase 76 entry rewritten to post-code truth incl. the honest spoton-helper patch no-op status, CHANGELOG carries all Phase 76 entries, and 76-UAT-CHECKLIST.md scripts the single D-11 live-UAT pass covering both backends end to end.**

## Performance

- **Duration:** ~12 min
- **Started:** 2026-08-29T21:27:02Z
- **Completed:** 2026-08-29T21:39:00Z
- **Tasks:** 3
- **Files modified:** 6 (1 created)

## Accomplishments

- **Task 1 (D-07):** `Settings/Player.pm` passes `backend` to the template and normalizes a stored `ogg` streamFormat to `auto` for display when backend=soloist — display-only, the stored pref is never rewritten, so switching back to librespot re-selects the user's OGG choice. `player.html` wraps the OGG option in `[% IF backend != 'soloist' %]`. `PLUGIN_SPOTON_STREAM_FORMAT_DESC` rewritten backend-aware in all 11 languages (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV, real translations) — the old text named OGG as the universal Auto choice and referenced a removed control.
- **Task 2 (D-03):** ROADMAP Phase 76 entry rewritten scoped-only: #149/#150 marked code-fixed in QT 260817-ana (released v3.5.1/v3.5.2, live verification in the Phase 76 UAT), Window 5 marked FIXED citing 76-07's five measured sub-second runs, delivered 8-plan set restated per wave (76-08 corrected to Wave 4), and the spoton-helper patch status documented truthfully: wiring complete since 74-04 (`_autoPatch` fail-open, t/33-covered, re-verified this session), public builds carry an EMPTY pattern table because CI secrets `SPOTON_PRIVATE_PATTERNS_TOKEN`/`SPOTON_PRIVATE_PATTERNS_REPO` are unset — FLAC24-enum effect excluded from Phase 76 success criteria, deferred to Phase 77 UAT. CHANGELOG [Unreleased] gains 6 Added + 8 Fixed entries (English, one line per item, issue-referenced, no version number).
- **Task 3 (D-09/D-11/D-14):** `76-UAT-CHECKLIST.md` created — ordered one-pass script with per-item setup/action/expected/evidence: (1) environment prep incl. local librespot-spoton cargo-build requirement, CDP flags with mandatory teardown (T-76-18), diagnosticMode + SPOTON_FAKEPULSE_DEBUG; (2) Soloist Phase 73 Windows 1-4 (all 6 human-verification scenarios from 73-VERIFICATION.md incl. the Settings render + D-07 dropdown check); (3) Soloist Phase 76 items (FLAC24 chain, format matrix incl. the `-e flac` PCM-only direct path, skip ear check, restart-autoplay, #151, #135); (4) SpClient smoke (all five spclient-smoke.pl stages + per-family in-LMS spot checks + #161/#94 browse UX); (5) librespot regression matrix (Browse, Connect loop, five-format switching with Pitfall-2 warning signs, #149/#150 AP-drop, #159 eject, #131, #128, #158); (6) result ledger mirroring WINDOWS.md entries 1-6 with `gsd-tools windows fixed <id>` close commands, three user-confirmation decisions, and the CDP teardown.

## Human-Check Mapping (plan → checklist item)

| Source plan human-check | Checklist item |
|------------------------|----------------|
| 76-01: live FLAC24 chain (24-bit, clean audio) | 3.1 |
| 76-02: #159 deselect-while-paused eject | 5.5 |
| 76-02: #131 sync-group 3+min stutter-free | 5.6 |
| 76-02: #128 mid-song handoff divergence ≤2s | 5.7 |
| 76-03: Material Skin hover actions (#161) | 4.3 |
| 76-03: More-menu parity track + episode (#94) | 4.4 |
| 76-04: soloist auto→FLAC / pcm→direct / mp3→lame | 3.1 + 3.2 |
| 76-04: librespot OGG/PCM re-check (D-14) | 5.3 |
| 76-05 T1: restart-autoplay suppression + manual resume | 3.4 |
| 76-05 T2: #151 power off→on→off / stays-on | 3.5 |
| 76-05 T3: #158 group pause→skip→play | 5.8 |
| 76-06: Up Next queue render / empty state / one request | 3.6 |
| 76-07: skip ear check ~3s | 3.3 |
| 76-07 residual: PCM-only-player direct-stream skip path | 3.2 (Zusatz) |
| 76-08 T1: dropdown soloist(4)/librespot(5) + OGG re-select | 2.6 |

Additionally covered per D-11: 73-VERIFICATION scenarios 1-6 → items 2.1-2.6; SpClient smoke → 4.1-4.2; #149/#150 → 5.4.

## Task Commits

Each task was committed atomically:

1. **Task 1: D-07 backend-conditional Stream Format dropdown** - `ef8edc0` (feat)
2. **Task 2: D-03 ROADMAP truth pass + CHANGELOG entries** - `e508e09` (docs)
3. **Task 3: consolidated live-UAT checklist** - `2b2d0ea` (docs)

## Files Created/Modified

- `Plugins/SpotOn/Settings/Player.pm` - backend template param + soloist/ogg display normalization (no pref write)
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html` - TT-conditional OGG option
- `Plugins/SpotOn/strings.txt` - backend-aware STREAM_FORMAT_DESC, 11 languages
- `.planning/ROADMAP.md` - Phase 76 entry only (description + wave line)
- `CHANGELOG.md` - [Unreleased] Added (6) + Fixed (8) Phase 76 entries
- `.planning/phases/76-connect-stabilization-flac24-integration/76-UAT-CHECKLIST.md` - new D-11 master script

## Decisions Made

- **Desc string rewritten instead of left alone:** the plan preferred "touch nothing if backend-neutral", but the existing text failed that test on three counts — it presented Auto→OGG as universal (false under Soloist), claimed "Browse mode only" (stale since streamFormat governs Connect on both backends), and referenced the removed "Connect OGG Override below" control. Rewritten once, translated genuinely in all 11 languages.
- **ROADMAP checkbox/progress markers untouched:** the orchestrator owns plan-progress writes; this plan changed only the descriptive entry text and the wave listing (76-08 moved from the incorrect "Wave 3" to Wave 4 per its frontmatter).
- **Ledger section covers WINDOWS ids 1-6:** the plan's "entries 1-5" predates 76-07 appending entry 6; the checklist mirrors the actual ledger.

## Deviations from Plan

**1. [Note] CHANGELOG intermediate edit restructured**
- **Context:** The first CHANGELOG edit accidentally left the pre-existing Phase 74/75 Added entries under the new Fixed heading
- **Resolution:** Corrected in the same task before commit — Fixed section moved after the full Added block; final structure verified by read-back
- **Impact:** None (fixed pre-commit)

**2. [Note] Planning artifacts staged despite stale `.planning/` gitignore entry**
- **Context:** `.gitignore:24` lists `.planning/`, but the repo's demonstrated convention is the opposite — the entire `.planning/` tree (ROADMAP.md, WINDOWS.md, every prior PLAN/SUMMARY incl. this phase's) is tracked and continuously committed, and the orchestrator contract requires the checklist + SUMMARY committed before return
- **Resolution:** Tracked files (ROADMAP.md) staged with `git add -u`; the two new files (76-UAT-CHECKLIST.md, this SUMMARY) force-added individually, matching the 76-04 sibling precedent
- **Impact:** None — matches every prior phase's history

Otherwise: plan executed exactly as written.

## Issues Encountered

None beyond the deviations above.

## Known Stubs

None — the dropdown conditional, normalization, and all documentation are complete; the checklist's open checkboxes are its purpose (the UAT session fills them). All outstanding live verifications were already recorded as WINDOWS.md entries 1-6 by prior plans; this plan added the closing commands to the checklist rather than new ledger entries.

## Threat Flags

None — no new network/auth/file surface. T-76-17 (streamFormat save path) accepted per plan: the whitelist regex in Player.pm is untouched, this plan changed display only. T-76-18 mitigated as registered: checklist item 1.6 marks `--remote-allow-origins=*` as test-session-only and teardown 6.4 is a mandatory step.

## User Setup Required

None for this plan's artifacts. Note for the UAT session itself (checklist 1.2): the librespot-spoton daemon binary must be locally cargo-built and deployed before Section 5 — the 76-02/76-05 Rust changes are not in any released binary until the next tag.

## Next Phase Readiness

- Phase 76 code work is complete across all 8 plans; the single remaining phase activity is executing `76-UAT-CHECKLIST.md` (one pass, both backends) and closing WINDOWS.md entries 1-6 from the ledger section.
- Three decisions are queued for user confirmation during/after the UAT (checklist 6.3): the FLAC24-enum deferral to Phase 77 (D-01 exception), the #135 Option-A choice, and the #151 opt-in question.
- CHANGELOG is release-ready except version numbering (user-approved only, per project rules).

## Self-Check: PASSED

- `Plugins/SpotOn/Settings/Player.pm` — FOUND
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html` — FOUND
- `Plugins/SpotOn/strings.txt` — FOUND
- `.planning/ROADMAP.md` — FOUND
- `CHANGELOG.md` — FOUND
- `.planning/phases/76-connect-stabilization-flac24-integration/76-UAT-CHECKLIST.md` — FOUND
- Commit `ef8edc0` — FOUND
- Commit `e508e09` — FOUND
- Commit `2b2d0ea` — FOUND
- `prove -l t/` — 37 files, 1744 tests, Result: PASS
- Acceptance greps: player.html backend x2; ROADMAP 260817-ana x1 + SPOTON_PRIVATE_PATTERNS x1; CHANGELOG FLAC/159/131/151/135/161 all >=1; checklist >=6 sections, 149|150 x5, spclient-smoke x2

---
*Phase: 76-connect-stabilization-flac24-integration*
*Completed: 2026-08-29*
