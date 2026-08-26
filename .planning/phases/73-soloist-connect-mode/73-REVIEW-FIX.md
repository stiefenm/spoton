---
phase: 73-soloist-connect-mode
fixed_at: 2026-08-26T19:18:07Z
review_path: .planning/phases/73-soloist-connect-mode/73-REVIEW.md
iteration: 1
findings_in_scope: 13
fixed: 13
skipped: 0
status: all_fixed
---

# Phase 73: Code Review Fix Report

**Fixed at:** 2026-08-26T19:18:07Z
**Source review:** .planning/phases/73-soloist-connect-mode/73-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 13 (2 Critical + 11 Warning; Info findings out of scope per default `critical_warning` fix scope)
- Fixed: 13
- Skipped: 0

**Isolation:** all fixes applied and verified inside an isolated git worktree
(`.claude/worktrees/rf-73-<pid>-<epoch>`, branch `gsd-reviewfix/73-<pid>`),
fast-forwarded onto `soloist` after the last commit. Verification (`prove -l
t/` and `make test` for the C component) ran inside that same worktree.

**Verification method:** `prove -l t/` (full Perl suite, 32 files / 1314
tests) after every commit, plus `make test` (native C harness,
`Plugins/SpotOn/Bin/fake-libpulse/`) for the one finding touching C code
(WR-11). No syntax-only fallback was needed — the isolated-require Perl test
harness and the native C test harness both exercise real behavior, not just
parse-checking.

## Fixed Issues

### CR-01: SoloistWS->new dies on real LMS — hash deref on a blessed-array Accessor object

**Files modified:** `Plugins/SpotOn/Unified/SoloistWS.pm`, `t/28_soloist_dispatch.t`, `t/30_soloist_daemon.t`, `t/31_soloist_ws.t`, `t/32_soloist_events.t`
**Commit:** `736dae4`
**Applied fix:** Switched the `daemon` field to the Accessor's native `weak` type (weakens on store) instead of a manual `weaken($self->{daemon})` — a hash dereference on a blessed ARRAY ref that died on every real LMS. Fixed the isolated-require test stub for `Slim::Utils::Accessor` in all four affected test files to be array-based (matching the real LMS contract) so this exact class of divergence can no longer hide behind the test harness. One test double (`t/28_soloist_dispatch.t`) that blessed a hash for a `SoloistDaemon` stand-in was updated to bless an array and move its test-only "alive" flag into an external hash keyed by mac.
**Status:** fixed

### CR-02: Seeded browse advance pauses Soloist via un-suppressed internal LMS stop event

**Files modified:** `Plugins/SpotOn/Unified/SoloistWS.pm`, `Plugins/SpotOn/Connect.pm`
**Commit:** `cff3630`
**Applied fix:** Added a `browseAdvanceTs` timestamp, set immediately before the source-marked `['playlist','index','+1']` advance request (and on a fresh `startBrowseTrack`, which triggers the same internal stop of the previous item). `Connect.pm`'s `_onPause` browse branch now suppresses forwarding a non-unpause event to the daemon within a 3s grace window (`BROWSE_ADVANCE_GRACE`) after that timestamp, mirroring the existing Connect-path `connectStartTime` grace period.
**Status:** fixed: requires human verification (timing/logic fix with no dedicated functional test coverage for `Connect.pm`'s event handlers — verified only via full-suite pass + syntax check; recommend confirming with real seeded-advance UAT)

### WR-01/WR-02: connected(1) set before WS handshake completes; reconnectDelay never reset

**Files modified:** `Plugins/SpotOn/Unified/SoloistWS.pm`
**Commit:** `f114f4d`
**Applied fix:** Moved `connected(1)` into the WS client's `connect` callback (fires only once the handshake completes), added an independent `_sockOpen` flag for socket lifecycle so `_onClosed`'s re-entry guard no longer depends on handshake completion, and added a 5s handshake timeout (`HANDSHAKE_TIMEOUT`) that forces cleanup if the daemon never completes the handshake. `reconnectDelay` is reset to `RECONNECT_DELAY_MIN` in the same handshake-complete callback.
**Status:** fixed: requires human verification (protocol-timing fix; existing tests set `connected(1)` directly and don't exercise `connect()`'s handshake sequencing itself)

### WR-03/WR-04: startBrowseTrack return value ignored; browseAdvancePending consumed without URI comparison

**Files modified:** `Plugins/SpotOn/Unified/SoloistWS.pm`, `Plugins/SpotOn/ProtocolHandler.pm`, `t/31_soloist_ws.t`
**Commit:** `4361346`
**Applied fix:** `startBrowseTrack` now rolls back all browse state (`browseSession`, `browseCurrentUri`, `browseAdvanceTs`) when `sendCommand` fails, and `getNextTrack` checks the return value, calling `errorCb('PROBLEM_OPENING', ...)` on failure instead of unconditionally proceeding. The `browseAdvancePending` re-entry guard is now cleared unconditionally on every `getNextTrack` entry and only honored when `browseCurrentUri` matches the exact URI being requested, preventing a user-skip race from swallowing the wrong track's `play` command. Updated one existing test that relied on the old unconditional `browseSession=1` behavior.
**Status:** fixed

### WR-05: streamingMode=proxy per-player pref bypassed for soloist Browse

**Files modified:** `Plugins/SpotOn/ProtocolHandler.pm`
**Commit:** `f230e57`
**Applied fix:** Extracted the streamingMode resolution (per-player → global default, GH #96) into a shared `_streamingModeIsProxy($client)` helper. `canDirectStream`'s soloist branch now checks it before returning a direct URL (returning 0 for proxy mode, same as the existing COMPAT-02 gate), and `new()`'s b3 sync-group proxy substitution condition now also covers an unsynced player in proxy mode.
**Status:** fixed

### WR-06: No LMS-side termination hook for a browse session

**Files modified:** `Plugins/SpotOn/Connect.pm`, `Plugins/SpotOn/Unified/SoloistWS.pm`, `t/31_soloist_ws.t`
**Commit:** `b6d6650`
**Applied fix:** Three LMS-side hooks added: (1) `Connect.pm`'s `_onPause` browse branch now distinguishes a genuine LMS stop from a pause (after the CR-02 grace check) and calls `endBrowseSession('lms_stop')` for the former; (2) `_onNewSong` ends the session when a new song starts that is not a `spoton://track|episode:` URL while a browse session is still active; (3) the `'stopped'`-no-seed advance in `SoloistWS::_onPlaybackChanged` now verifies (via new `_clientCurrentSpotifyUri` helper) that LMS is still actually on the expected browse track before firing the advance, preventing an unrequested skip into the user's unrelated current playlist. Added a regression test for the stale-track case.
**Status:** fixed: requires human verification (the `Connect.pm` portion — `_onPause`/`_onNewSong` hooks — has no dedicated functional test harness, verified only via full-suite pass + syntax check; the `SoloistWS.pm` portion has direct test coverage)

### WR-07: Multi-daemon race — _pollHttpPort glob-unlinks other daemons' live HTTP port files

**Files modified:** `Plugins/SpotOn/Unified/SoloistDaemon.pm`, `Plugins/SpotOn/Unified/DaemonManager.pm`
**Commit:** `9c2121f`
**Applied fix:** `_pollHttpPort` now unlinks only its own tmpfile. The global stale-file sweep moved to a new `DaemonManager::_cleanupStaleHttpPortFiles`, scheduled once at the same boot-time delay as the existing `_cleanupOrphanedLogs` (`ORPHAN_LOG_CLEANUP_DELAY`), bounded further by only removing files older than 60s (well past the ~10s poll timeout).
**Status:** fixed

### WR-08: $msg->{item}{uri} dies on non-hash item

**Files modified:** `Plugins/SpotOn/Unified/SoloistWS.pm`
**Commit:** `62d9329`
**Applied fix:** Both `_onTrackChanged` and `_onPlaybackState` now guard the `item` field with `ref($msg->{item}) eq 'HASH'` before dereferencing, mirroring the ref-checked pattern `_onPlaybackState` already used correctly for its `position` field.
**Status:** fixed

### WR-09: Orphaned soloist processes never cleaned up

**Files modified:** `Plugins/SpotOn/Plugin.pm`
**Commit:** `07a4e6f`
**Applied fix:** Extracted the existing librespot-helper orphan-kill logic (Unix `pgrep`/Windows `tasklist`) into a shared `_killOrphansForBinary()` helper and added a second sweep for `Plugins::SpotOn::Soloist->get()`'s binary, reusing the same `%unifiedPids` exclusion set (which already protects live `SoloistDaemon` PIDs).
**Status:** fixed

### WR-10: Expiry-days value stale — append-mode head-read parses the oldest run; countdown never decreases

**Files modified:** `Plugins/SpotOn/Unified/SoloistDaemon.pm`, `Plugins/SpotOn/Settings.pm`
**Commit:** `1a3c6d4`
**Applied fix:** `_parseExpiryDays` now seeks to `_stderrStartOffset` (this run's own start) before reading, instead of offset 0 (which parsed whatever the first-ever run's append-mode log wrote). `Settings.pm` now displays `max(0, days - elapsed_days_since_checked_at)` instead of the raw cached value, and derives the warn flag from the adjusted value.
**Status:** fixed

### WR-11: fake-libpulse — idle LAN connection stalls the single streaming thread for up to 2s per connect

**Files modified:** `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c`
**Commit:** `52341e6`
**Applied fix:** Replaced the accept-then-block model (`_http_discard_request`, a blocking-with-poll call invoked AFTER the active client was already disconnected) with a non-blocking PENDING connection slot: a newly accepted fd is read incrementally on every server-thread tick and only takes over the active client once its request head has actually arrived (or it errors/times out) — the active client's ring-drain loop runs unconditionally every tick regardless of pending state. **Caught while writing the regression test:** the pending buffer wasn't cleared between reuses, so a stale `\r\n\r\n` tail from a previous connection's completed header made the head-complete check return true immediately for a brand-new, silent connection — defeating the fix entirely. Fixed by clearing the buffer on every new `accept()`. Added a `make test` regression case (native C harness) confirming an idle pending connection no longer disconnects or stalls the active client; verified stable across 8 consecutive runs after the buffer-clear fix (was reproducibly failing before it).
**Status:** fixed (native `make test` harness directly exercises the race this finding describes, including a real accept()-vs-active-client concurrency scenario — this is the fixer's highest-confidence fix)

## Skipped Issues

None — all 13 in-scope findings (2 Critical + 11 Warning) were fixed.

## Notes on Scope

Per the fix instructions, Info-level findings (IN-01 through IN-07) were
intentionally left unaddressed — they are cosmetic/documentation-only per
the review (dead code, stale comments, a redundant regex condition, an
uninitialized-value warning, degraded-not-broken behavior, and a defensive
malloc check) and out of the default `critical_warning` fix scope.

## Items Recommended for Human Verification

Three fixes are logic/timing corrections in code paths with no dedicated
functional test harness (`Plugins/SpotOn/Connect.pm`'s event subscribers —
CR-02, WR-06 — and `SoloistWS.pm`'s WS handshake sequencing — WR-01/WR-02).
All were verified via the full Perl test suite (no regressions) and
`t/05_perl_syntax.t` (syntax-clean), but their exact runtime behavior
(seeded-advance grace suppression, LMS-stop session termination, handshake
timing/backoff reset) should be confirmed with real Soloist Connect/Browse
UAT before considering the phase fully closed out. WR-11's fix, by
contrast, has direct native-harness regression coverage and is
high-confidence.

---

_Fixed: 2026-08-26T19:18:07Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
