---
phase: 76-connect-stabilization-flac24-integration
plan: 04
subsystem: audio-pipeline
tags: [format-resolver, soloist, flac24, mp3, lame, smp, canDirectStream, formatOverride, sync-group, transcoding]

# Dependency graph
requires:
  - phase: 76-connect-stabilization-flac24-integration
    provides: "76-01: S32LE ring, soc flc * * rule, samplesize(32) hints (FLAC24 tracer)"
  - phase: 73-soloist-connect-mode
    provides: persistent Soloist daemon HTTP /stream, soc-family dispatch in ProtocolHandler
provides:
  - "resolveSoloistFormat() in DaemonManager -- three-value (pcm|flac|mp3) D-06 resolver with ogg->auto mapping and sync-group flc downgrade aggregation"
  - "resolver-gated canDirectStream in both soloist stream paths (browse + unified connect): pcm keeps direct raw-S32 /stream, flac/mp3 force LMS-side transcoding"
  - "formatOverride 'smp' routing for explicit MP3 (both backends)"
  - "smp content type + single 'smp mp3 * *' [lame] $SAMPLESIZE$-driven forcing rule"
affects: [76-08 dropdown D-07, phase-76 UAT D-11, librespot regression D-14]

# Actuals (#2632) -- pairs with the plan's `estimate` to calibrate future estimates.
actuals:
  tokens: 7300
  tasks: 3
  commits: 4

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Three-value resolver as a SIBLING of the boolean resolver -- never widen an existing boolean contract with multiple consumers (D-14 / RESEARCH Pitfall 3)"
    - "Single-rule forcing content type (smp mirrors son): the only way to beat TranscodingHelper's player-format-preference order"
    - "Backend-dispatched if/else in canDirectStream keeps the librespot branch byte-for-byte unchanged while soloist gets resolver gating"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/Unified/DaemonManager.pm
    - Plugins/SpotOn/ProtocolHandler.pm
    - Plugins/SpotOn/custom-convert.conf
    - Plugins/SpotOn/custom-types.conf
    - t/28_soloist_dispatch.t
    - t/29_soloist_browse.t
    - t/03_convert_conf.t
    - t/04_types_conf.t

key-decisions:
  - "Sync-group aggregation checks flc capability of ALL members incl. the master (also for explicit 'flac') -- keeps the resolver consistent with LMS CapabilitiesHelper::supportedFormats, which performs the authoritative intersection anyway"
  - "No smp-pcm fallback rule: a missing lame binary yields a visible PROBLEM_CONVERT_FILE stream error (Song.pm:425-427) instead of silently playing a different format than the user explicitly chose"
  - "contentType() stays client-agnostic: verified Song.pm:375-378 unconditionally replaces it with formatOverride() on the transcode path -- formatOverride is the single authoritative per-player site"

patterns-established:
  - "Strip-then-assert tool-token pin extended to [lame] in t/03 (mirror of the 76-01 [sox] pin); conf comments must spell the tool as its bracketed token"

requirements-completed: [D-06, D-07]

coverage:
  - id: D1
    description: "resolveSoloistFormat: explicit pcm/flac/mp3 win without capability check, ogg maps to auto, auto is flc-capability-based, sync group downgrades to pcm when any member lacks flc, unsynced never consults slaves"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "prove -l t/28_soloist_dispatch.t (11 new resolver assertions, 40 total)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Both soloist stream paths (browse + unified connect) gate direct-vs-transcode on the resolver; explicit pcm keeps the direct raw-S32 /stream URL; librespot pref check byte-for-byte unchanged"
    requirement: "D-06"
    verification:
      - kind: unit
        ref: "prove -l t/29_soloist_browse.t (gating matrix browse/connect x pcm/flac/mp3 + librespot D-14 pins); git diff shows zero deletions in DaemonManager.pm (resolvePassthroughForClient untouched)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Explicit MP3 reaches the player as MP3 via the dedicated smp type (formatOverride routes 'smp' for both backends; single [lame] rule)"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "prove -l t/29 (formatOverride smp matrix) + t/03/t/04 (smp rule + type row pins); prove -l t/ fully green (1713 tests)"
        status: pass
      - kind: integration
        ref: "pipe check: raw S32LE and S16LE sine | lame --silent -r --little-endian --signed --bitwidth {32,16} -s 44.1 -q 2 - - -> rc=0, valid MPEG ADTS layer III"
        status: pass
    human_judgment: false
  - id: D4
    description: "Live format matrix: soloist auto->FLAC on squeezelite, pcm->direct raw stream (no transcoder process), mp3->lame in pipeline; librespot OGG/PCM behavior unchanged"
    requirement: "D-06"
    verification: []
    human_judgment: true
    rationale: "Requires the live dev setup (LMS + squeezelite + Spotify app) -- explicitly deferred to the consolidated Phase 76 UAT (D-11); recorded in .planning/WINDOWS.md entry #2"

# Metrics
duration: 10min
completed: 2026-08-29
status: complete
---

# Phase 76 Plan 04: FLAC24 Expansion — Format Resolver + MP3 Path Summary

**Three-value `resolveSoloistFormat()` (pcm|flac|mp3, ogg→auto, sync-group flc downgrade) sitting NEXT TO the untouched boolean passthrough resolver, wired into both soloist canDirectStream paths and formatOverride, plus a dedicated single-rule `smp` [lame] content type so explicit MP3 actually forces MP3**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-08-29T20:30:52Z
- **Completed:** 2026-08-29T20:40:38Z
- **Tasks:** 3
- **Files modified:** 8

## Accomplishments

- `resolveSoloistFormat($class, $client)` in DaemonManager.pm (D-06): explicit pcm/flac/mp3 win with no capability check (transcoding is LMS-side); 'ogg' maps to auto (librespot-exclusive, D-07); auto resolves 'flac' when the player announces `flc`, else 'pcm'; sync groups resolve from the MASTER's pref and downgrade to 'pcm' when ANY member lacks flc (mirror of the OGG aggregation). Implemented TDD: RED commit (11 failing matrix cases) before GREEN.
- `resolvePassthroughForClient()` and its two librespot consumers are **byte-for-byte unchanged** — the full-plan diff of DaemonManager.pm contains zero deletion lines (D-14 regression guard held).
- canDirectStream soloist browse block: resolver gate after the streamingMode-proxy gate — only resolved 'pcm' returns the direct raw-S32 /stream URL; 'flac'/'mp3' return 0 with a `resolved_format_*` DIAG log so LMS opens the stream itself and runs the soc/smp transcode rule.
- canDirectStream unified connect block: backend-dispatched — soloist uses the resolver (explicit pcm now correctly KEEPS the direct path), while the librespot pref check moved verbatim into the else branch (unchanged behavior, pinned by new t/29 D-14 assertions).
- formatOverride: the whole soloist family (browse + connect) resolves via the resolver — 'mp3' → 'smp', everything else 'soc' (auto FLAC selection stays with TranscodingHelper per D-05); librespot explicit `streamFormat=mp3` also routes to 'smp'; son/soc/passthrough paths otherwise unchanged. contentType() verified as NOT the transcode-profile site (Song.pm:375-378 replaces it with formatOverride) and documented in a comment.
- `smp` registered in custom-types.conf (`smp / audio/mpeg / audio`) and one rule `smp mp3 * *` in custom-convert.conf: `[lame] --silent -r --little-endian --signed --bitwidth $SAMPLESIZE$ -s 44.1 -q 2 $BITRATE$ - -` with `# IFB:{BITRATE=--abr %B}` capability line — $SAMPLESIZE$ serves soloist S32 (hinted 32) and librespot S16 (default 16) through the same rule text.
- Test coverage: t/28 +11 resolver assertions (40 total), t/29 +11 gating/formatOverride assertions (54 total incl. syntax), t/03 SKIP 10→13 ([lame] token pin, ≥2 $SAMPLESIZE$ rules, strip-then-assert no bare lame), t/04 SKIP 4→7 (smp row pins). Full suite: **36 files, 1713 tests, PASS**.

## Task Commits

Each task was committed atomically (Task 1 as TDD RED+GREEN pair):

1. **Task 1 RED: failing resolveSoloistFormat matrix in t/28** - `1d90f62` (test)
2. **Task 1 GREEN: resolveSoloistFormat in DaemonManager (D-06)** - `ccd91da` (feat)
3. **Task 2: resolver-gated canDirectStream + formatOverride smp routing** - `36fc4b5` (feat)
4. **Task 3: smp content type + [lame] MP3 forcing rule (D-07)** - `2ce2bf8` (feat)

## Files Created/Modified

- `Plugins/SpotOn/Unified/DaemonManager.pm` - new `resolveSoloistFormat()` (66 added lines, zero deletions — boolean contract untouched)
- `Plugins/SpotOn/ProtocolHandler.pm` - resolver gates in soloist browse + unified connect canDirectStream blocks; formatOverride smp routing for both backends; contentType() consistency comment
- `Plugins/SpotOn/custom-convert.conf` - `smp mp3 * *` rule ([lame], $SAMPLESIZE$-driven, no-pcm-fallback rationale comment)
- `Plugins/SpotOn/custom-types.conf` - `smp` audio/mpeg row
- `t/28_soloist_dispatch.t` - 11 resolver matrix cases; Test::SyncClient per-instance formats(); data-driven Sync::slaves() stub
- `t/29_soloist_browse.t` - controllable resolver/passthrough stubs; gating + formatOverride assertions; librespot D-14 pins
- `t/03_convert_conf.t` - smp rule pins, [lame] strip-then-assert
- `t/04_types_conf.t` - smp type-row pins

## Lame-Absent Failure Mode (Task 3 acceptance)

Verified via LMS's checkBin path analysis (TranscodingHelper.pm read this session):

1. `checkBin()` (TranscodingHelper.pm:263-302) resolves each `[tool]` token via `Slim::Utils::Misc::findbin`; a missing binary logs `couldn't find binary for: lame` and returns undef.
2. `getConvertCommand2` then skips the `smp-mp3-*-*` profile (`next PROFILE if !$command`, line 397). Since smp has NO other rule by design, no profile remains.
3. `Slim::Player::Song::open()` receives no transcoder and returns `(undef, 'PROBLEM_CONVERT_FILE', $url)` (Song.pm:425-427) — LMS surfaces a visible stream error in the UI.

Outcome: LMS handles the missing binary cleanly (explicit error, no silent wrong-format audio), so the plan's conditional `smp pcm * *` passthrough fallback was **not** needed. The rationale is documented in the conf comment. Positive path empirically verified: the exact rule command encodes raw S32LE and S16LE sine input over a non-seekable pipe with system lame 3.100 (rc=0, valid MPEG ADTS layer III at both bit widths). Dev-box note: lame exists at `/usr/bin/lame`; the LMS Bin dir ships only faad/flac/mac/sox/wvunpack — confirming lame's system-package status.

## Decisions Made

- **Sync aggregation checks flc on ALL members including the master, also for explicit 'flac':** LMS `CapabilitiesHelper::supportedFormats` performs the authoritative intersection for rule matching anyway (RESEARCH Pattern 3); checking every member keeps the resolver's answer consistent with what LMS will actually pick. Slave PREFS are deliberately ignored (master's pref governs — the group streams as one daemon keyed by the master's MAC), only slave CAPABILITIES matter.
- **No `smp pcm` fallback rule** (see failure-mode section above) — fail-loud beats fail-wrong for an explicit user choice.
- **contentType() left client-agnostic:** Song.pm:375-378 proves formatOverride is the single authoritative per-player site on the transcode path; a comment documents this so the asymmetry doesn't look like a bug later.
- **Accepted corner documented in code:** explicit 'pcm' on a SYNCED flc-capable group proxies through LMS and may still match soc-flc via TranscodingHelper's capability-order selection — audio stays bit-correct lossless; no dedicated pcm-forcing type (YAGNI until a user reports it).

## Deviations from Plan

**1. [Note] Task 3's resolveSoloistFormat corner-case comment landed in Task 1's commit**
- **Context:** Task 3 action item 3 asks for the explicit-pcm-on-synced-group comment "near resolveSoloistFormat", but Task 3's file list doesn't include DaemonManager.pm
- **Resolution:** The comment was written as part of the resolver's header doc in Task 1 (commit `ccd91da`) — semantically it belongs to the resolver contract; Task 3's commit stays scoped to its listed files
- **Impact:** None — plan content fully delivered, cleaner commit boundaries

**2. [Rule 1 - Bug] Conf comment tripped the new strip-then-assert lame pin**
- **Found during:** Task 3 (first t/03 run)
- **Issue:** The new conf comment used "lame" as a bare word, which the new strip-then-assert check (correctly) rejects
- **Fix:** Reworded the comment to spell the tool as its bracketed `[lame]` token throughout (same discipline 76-01 established for `[sox]`)
- **Files modified:** Plugins/SpotOn/custom-convert.conf
- **Commit:** `2ce2bf8` (fixed before the task commit)

**3. [Note] SUMMARY committed despite the stale `.planning/` gitignore entry**
- **Context:** `.gitignore:24` lists `.planning/`, so the SDK commit verb returned `skipped_gitignored`. However the repo's demonstrated convention is the opposite: the entire `.planning/` tree (all PLANs, SUMMARYs, WINDOWS.md, STATE.md — including 76-01's SUMMARY from this same phase, commit `d6f8f24`) is tracked and continuously committed, and the orchestrator contract requires the SUMMARY committed before return (worktree contents are otherwise discarded at merge)
- **Resolution:** Followed the established project convention and sibling-agent precedent: SUMMARY force-added (single file), WINDOWS.md staged normally (already tracked)
- **Impact:** None — matches every prior phase's history

Otherwise: plan executed exactly as written.

## Issues Encountered

None beyond the deviations above.

## Known Stubs

None — all code paths are real implementations; no placeholders, no empty data sources.

## Threat Flags

None — no new security surface beyond the plan's threat model. T-76-09 (smp lame rule): the command contains only the `[lame]` token and LMS-substituted `$SAMPLESIZE$`/`$BITRATE$` placeholders, no user string interpolation. T-76-10 (resolver in the stream-open path): pure pref + formats() reads, no I/O, no network — unit-tested for all branches.

## User Setup Required

None for the code path. Note for UAT: explicit MP3 requires the system `lame` package on the LMS host (present on the dev box at `/usr/bin/lame`); without it LMS shows a stream error for streamFormat=mp3 by design.

## Next Phase Readiness

- Every D-07 dropdown value now maps to a distinct on-wire behavior under backend=soloist: auto→capability-based FLAC24/PCM, pcm→direct raw S32, flac→soc-flc transcode, mp3→smp-lame transcode; 76-08 (dropdown OGG hiding, D-07 UI) can build directly on this
- Live format matrix (auto/pcm/flac/mp3 on both backends) pending in the consolidated Phase 76 UAT (D-11) — WINDOWS.md entry #2
- librespot resolution provably unchanged: boolean contract byte-for-byte identical, D-14 regression pins added to t/29

## Self-Check: PASSED

- All 8 modified files exist on disk
- All 4 task commits exist: `1d90f62`, `ccd91da`, `36fc4b5`, `2ce2bf8`
- `git diff fe0ff59..HEAD -- DaemonManager.pm` → zero deletion lines (D-14)
- `prove -l t/` → Result: PASS (36 files, 1713 tests)

## TDD Gate Compliance

Task 1 (`tdd="true"`): RED commit `1d90f62` (test, failing matrix verified via prove FAIL) precedes GREEN commit `ccd91da` (feat, suite PASS). No refactor commit needed.

---
*Phase: 76-connect-stabilization-flac24-integration*
*Completed: 2026-08-29*
