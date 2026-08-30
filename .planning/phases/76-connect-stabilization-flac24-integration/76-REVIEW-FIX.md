---
phase: 76-connect-stabilization-flac24-integration
fixed_at: 2026-08-30T15:15:00Z
review_path: .planning/phases/76-connect-stabilization-flac24-integration/76-REVIEW.md
iteration: 1
findings_in_scope: 6
fixed: 6
skipped: 0
status: all_fixed
---

# Phase 76: Code Review Fix Report

**Fixed at:** 2026-08-30
**Source review:** 76-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 6 (1 Critical, 5 Warning; Info findings excluded per fix_scope)
- Fixed: 6
- Skipped: 0

**Verification environment:** All gates ran inside the isolated review-fix worktree
(`.claude/worktrees/rf-76-*`, branch `gsd-reviewfix/76-727107`, fast-forwarded into
`soloist` on cleanup). Per-fix: full `prove -l t/` (37 files, 1744 tests, PASS after
every fix). For WR-01 additionally `make -C Plugins/SpotOn/Bin/fake-libpulse test`
(all host-test assertions PASS with the updated `audio/x-pcm` expectation). `perl -c`
is not runnable standalone (Slim::* modules unavailable outside LMS — pre-existing);
syntax coverage comes from `t/05_perl_syntax.t` inside the suite.

## Fixed Issues

### CR-01: Stale `samplesize(32)` on shared RemoteTrack objects breaks librespot playback after a backend switch

**Files modified:** `Plugins/SpotOn/ProtocolHandler.pm`
**Commit:** 1ddc0db
**Applied fix:** Both librespot `getNextTrack` paths now EXPLICITLY reset the hint
instead of relying on "never set": the Connect branch gained an `else` to the
`_useSoloist()` check that sets `samplesize(16)`, and the browse-URL path gained an
`elsif` for `spoton://track|episode:` URLs under librespot that does the same.
Comments updated to explain the RemoteTrack in-memory cache (`%Cache`) surviving a
backend switch within one LMS uptime.

### WR-01: `application/octet-stream` Content-Type makes LMS classify the soloist direct stream as MP3

**Files modified:** `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c`
**Commit:** 812e203
**Applied fix:** `HTTP_RESPONSE_HEADER` Content-Type changed to `audio/x-pcm`
(verified against stock LMS `types.conf:45` — maps to `pcm`). The misleading
"no Perl consumer parses this header" comment replaced with the actual
direct-stream `parseDirectHeaders`/`mimeToType` behavior. Host-test
`_test_read_header` expectation updated to `audio/x-pcm`; full C host-test suite PASS.

### WR-02: Explicit `streamFormat=pcm` is silently overridden to FLAC on every flc-capable player

**Files modified:** `Plugins/SpotOn/Unified/DaemonManager.pm`, `Plugins/SpotOn/ProtocolHandler.pm`, `Plugins/SpotOn/strings.txt`
**Commit:** 94ecb5a
**Applied fix:** Documentation option (the YAGNI stance is an accepted 76-04 design
decision, so no pcm-forcing content type was added). The "Accepted corner (76-04)"
comment in `resolveSoloistFormat` now states the real scope (Song::open picks the
transcoder BEFORE canDirectStream; soc-flc outranks soc-pcm on every flc-first
player, synced or not, both backends). Both canDirectStream gate comments in
ProtocolHandler.pm gained matching WR-02 scope notes. User-visible documentation
added to `PLUGIN_SPOTON_STREAM_FORMAT_DESC` in all 11 languages (CS/DA/DE/EN/ES/
FR/IT/NL/NO/PL/SV, real translations): explicit PCM on FLAC-capable players is
delivered as lossless FLAC.

### WR-03: `_typeString` displays "PCM" under soloist while FLAC/MP3 is streamed

**Files modified:** `Plugins/SpotOn/Plugin.pm`
**Commit:** 0208054
**Applied fix:** `_typeString` now dispatches by backend: under soloist, `auto`/`ogg`
resolve via `resolveSoloistFormat` (with eval guard + pcm fallback, mirroring the
existing librespot branch); the librespot `resolvePassthroughForClient` branch is
unchanged as `elsif`. Display labels in `spoton_meta_*` cache entries now match the
actual stream format.

### WR-04: `resolveSoloistFormat` drops the `connectOggOverride` fallback chain

**Files modified:** `Plugins/SpotOn/Unified/DaemonManager.pm`
**Commit:** 046bd39
**Applied fix:** `$resolveOne` now reads
`streamFormat || connectOggOverride || 'auto'` — identical to every other pref
reader. A legacy `connectOggOverride='pcm'` now resolves the same in the soloist
resolver as on the settings page. `'ogg'` safely falls through to auto.

### WR-05: Soloist OGG→Auto display remap destroys stored OGG choice on save

**Files modified:** `Plugins/SpotOn/Settings/Player.pm`
**Commit:** 4c9c29c
**Applied fix:** Save handler now guards exactly the echo case: when
backend=soloist, stored value (full fallback chain) is `'ogg'`, and the posted
value is `'auto'`, the write is skipped — any other user selection (pcm/flac/mp3,
or any value under librespot) persists normally. The render-block comment now
references the guard so the preservation contract is documented end-to-end.

## Skipped Issues

None.

---

_Fixed: 2026-08-30_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
