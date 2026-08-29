---
phase: 75-api-unification-spclient-modell
plan: 07
subsystem: api
tags: [spclient, pagination, spotify-web-api, perl, cache-invalidation]

requires:
  - phase: 75-api-unification-spclient-modell (plans 01-06)
    provides: "SpClient.pm facade layer, D-06/D-07 capability routing, collection/v2 + playlist/v2 + context-resolve plumbing"
provides:
  - "getPlaylistItems filter-before-slice + recount (CR-01 fix) -- total always agrees with the track-filtered window"
  - "_enrichMeta/_enrichCollectionSlice stub substitution -- every paginated facade preserves the requested-window-size invariant under enrichment failures"
  - "getAlbumTracks/getArtistAlbums/getShowEpisodes empty-body $meta guard (WR-01) -- no die inside async HTTP success callback"
  - "getPlaylistItems playlistId charset/length validation (WR-04) -- rejected before any URL/cache-key use"
  - "_collectionAll bounded pagination (WR-03) -- COLLECTION_MAX_PAGES cap + repeated-token guard"
  - "getSavedShows _noCache honoring + write-path cache invalidation (WR-02) -- library lists visible on next fetch after Like/Follow"
affects: [76-soloist-ux-polish, 77-soloist-uat-release]

actuals:
  tokens: 8300
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Stub-substitution enrichment: never drop a paginated slot on per-item failure, substitute a minimal {id,uri,name=>undef} stub instead, so scalar(@results) always equals the requested window size"
    - "Filter-before-slice: filter to the target content type BEFORE calling _sliceAsPage, so total/offset arithmetic reflects only what the caller actually consumes"
    - "Named-fallback reuse: hoist an inline _spFacade fallback closure to a named variable so it can also guard the normalize closure against an empty/malformed success body"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/API/SpClient.pm
    - t/36_spclient.t

key-decisions:
  - "getRecentlyPlayed's own inline enrichment loop (grep{defined} drop pattern) deliberately left untouched -- it has no offset-based pagination caller (Plugin.pm calls it once per menu open with a fixed limit, never accumulating across repeated calls), so it is out of CR-01's scope, not an oversight"
  - "search()'s pre-existing offset-guard scope issue (offset compared against raw context-resolve URI count, not the track-filtered count -- noted in 75-REVIEW.md CR-01's related off-by-scope observation) was NOT in this plan's Task 1 action list and was left unfixed as a residual pre-existing item, logged to WINDOWS.md (#6) rather than silently fixed or silently dropped"
  - "_collectionAll's $noCache is a bypass-on-demand (skips only the initial cache read, still writes the fresh result back), not a cache-disable -- matches Plugin.pm:2088's actual call shape and keeps the 60s cache useful for every other caller"
  - "Write-path cache invalidation peeks $_[0] as accountId without consuming @_, so Client.pm still receives the exact original argument list unchanged"

requirements-completed: [D-07, D-08, D-09]

coverage:
  - id: D1
    description: "CR-01 closed: getPlaylistItems filters to spotify:track: URIs before slicing and derives total from the filtered list, restoring the offset-advance-by-returned-count contract for _fetchPages/_albumFeed play-all/explodePlaylist"
    requirement: "D-08"
    verification:
      - kind: unit
        ref: "t/36_spclient.t#CR-01 mixed-content: total reflects the 3 filtered track URIs, NOT the raw envelope length (5)"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#CR-01 chaining: zero duplicate tracks across the chained windows"
        status: pass
    human_judgment: false
  - id: D2
    description: "_enrichMeta/_enrichCollectionSlice substitute a minimal stub for a failed per-item metadata fetch instead of dropping it, so every paginated facade returns exactly as many items as were sliced"
    requirement: "D-09"
    verification:
      - kind: unit
        ref: "t/36_spclient.t#CR-01 partial-enrichment-failure: items length stays 3 (stub substituted, not dropped)"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#CR-01 getSavedAlbums partial-enrichment-failure: full requested count returned (stub in failed slot, not dropped)"
        status: pass
    human_judgment: false
  - id: D3
    description: "getAlbumTracks/getArtistAlbums/getShowEpisodes never die on an empty/malformed metadata/4 response body; they fall back to Client.pm exactly like any other spclient-path error (WR-01)"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "t/36_spclient.t#WR-01 getAlbumTracks: empty-body \$meta delegates to Client.pm exactly once, no die"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#WR-01 getArtistAlbums: empty-body \$meta delegates to Client.pm exactly once, no die"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#WR-01 getShowEpisodes: empty-body \$meta delegates to Client.pm exactly once, no die"
        status: pass
    human_judgment: false
  - id: D4
    description: "getPlaylistItems rejects a malformed \$playlistId before it is ever spliced into the spclient URL path or cache key (WR-04)"
    requirement: "D-07"
    verification:
      - kind: unit
        ref: "t/36_spclient.t#WR-04: malformed playlistId (contains /) returns { error => invalid_id }"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#WR-04: too-short playlistId returns { error => invalid_id }"
        status: pass
    human_judgment: false
  - id: D5
    description: "getSavedShows honors params._noCache; saveTracks/removeTracks/saveShows/removeShows invalidate the corresponding spclient list cache (WR-02)"
    requirement: "D-09"
    verification:
      - kind: unit
        ref: "t/36_spclient.t#WR-02 _noCache: second _noCache=>1 call issues a SECOND collection/v2 POST"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#WR-02 write-invalidation: getSavedShows after saveShows issues a FRESH collection/v2 POST"
        status: pass
      - kind: unit
        ref: "t/36_spclient.t#WR-02 saveTracks: Liked Songs cache key removed after saveTracks"
        status: pass
    human_judgment: false
  - id: D6
    description: "_collectionAll's pagination loop is bounded (page cap) and detects a repeated next_page_token, so a malformed/adversarial spclient response cannot loop forever (WR-03)"
    requirement: "D-09"
    verification:
      - kind: unit
        ref: "t/36_spclient.t#WR-03: repeated-token loop terminates at or before COLLECTION_MAX_PAGES (100) page requests"
        status: pass
    human_judgment: false

duration: 35min
completed: 2026-08-29
status: complete
---

# Phase 75 Plan 07: Gap Closure Summary

**Closed all 5 verified gaps from 75-VERIFICATION.md against the shipped SpClient.pm: CR-01's critical pagination offset desync (filter-before-slice + recount, stub-substituting enrichment) and warnings WR-01/WR-02/WR-03/WR-04 (empty-body normalize guards, playlistId validation, bounded collection pagination, _noCache + write-path cache invalidation).**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-08-29T15:xx:xxZ
- **Completed:** 2026-08-29T15:06:29Z
- **Tasks:** 3
- **Files modified:** 2

## Accomplishments

- **CR-01 (critical, closed):** `getPlaylistItems` now filters `contents.items` to `spotify:track:` URIs BEFORE slicing, and derives `total` from that filtered list via `_sliceAsPage` instead of the raw envelope length (which counted non-track episodes/local files too). This restores the offset-advance-by-returned-count invariant `_fetchPages`, `_albumFeed` play-all, and `explodePlaylist` all depend on.
- `_enrichMeta` and `_enrichCollectionSlice` no longer drop a slot via `grep { defined }` on a failed `idToHex`/metadata-fetch — they substitute a minimal `{ id, uri, name => undef }` stub instead, so every paginated facade built on these helpers (`getAlbumTracks`, `getShowEpisodes`, `getSavedTracks`, `getSavedAlbums`, `getFollowedArtists`, `getSavedShows`, `search`) always returns exactly as many items as were sliced, even under 429/timeout enrichment failures.
- **WR-01 (closed):** `getAlbumTracks`/`getArtistAlbums`/`getShowEpisodes` now guard `unless ($meta && ref($meta) eq 'HASH')` as the first line of their normalize closures, reusing a named `$fallback` variable to route an empty/malformed spclient success body through the identical Client.pm delegation every other spclient error already uses — no more dying inside the async HTTP success callback with `$cb` never invoked.
- **WR-04 (closed):** `getPlaylistItems` validates `$playlistId` against `/^[0-9A-Za-z]{22}$/` immediately after the D-06 creds check, before `_playlistEnvelope` ever splices it into the URL path or cache key.
- **WR-03 (closed):** `_collectionAll`'s pagination loop is now bounded by a hard `COLLECTION_MAX_PAGES` (100) cap AND a repeated-`next_page_token` guard — a malformed/adversarial spclient response can no longer loop forever, and the repeated-token case still delivers accumulated data via the normal success path (not an error).
- **WR-02 (closed):** `_collectionAll` accepts an optional `$noCache` bypass-on-demand argument (skips only the initial cache read, still refreshes the cache afterward); `getSavedShows` passes `$params->{_noCache}` through. The four library write passthroughs (`saveTracks`/`removeTracks`/`saveShows`/`removeShows`) now invalidate their corresponding spclient list cache key before delegating to Client.pm, so a Like/Follow is visible on the very next fetch.

## Task Commits

Each task was committed atomically:

1. **Task 1: CR-01 — filter-before-slice + recount, stub-substituting enrichment** - `e65107e` (fix)
2. **Task 2: WR-01 guard undef $meta, WR-04 validate playlistId** - `5d6ad3c` (fix)
3. **Task 3: WR-02 honor _noCache + write-path invalidation, WR-03 bound _collectionAll** - `4b31973` (fix)

**Plan metadata:** (this commit — docs: complete plan)

## Files Created/Modified

- `Plugins/SpotOn/API/SpClient.pm` — filter-before-slice + recount in `getPlaylistItems`; stub-substituting `_enrichMeta`/`_enrichCollectionSlice`; guarded normalize closures in `getAlbumTracks`/`getArtistAlbums`/`getShowEpisodes`; `_noCache`-honoring + page-capped `_collectionAll`; write-path cache invalidation in `saveTracks`/`removeTracks`/`saveShows`/`removeShows`; validated `playlistId` in `getPlaylistItems`
- `t/36_spclient.t` — 37 new regression tests covering all six must-have truths (mixed-content windows, chained-page dedup, partial-enrichment-failure stubs for both track and album paths, empty-body 200 guards for all three WR-01 facades, malformed/too-short playlistId rejection, repeated-token pagination guard, `_noCache` bypass-without-disable, and write-invalidation for both Saved Shows and Liked Songs)

## Decisions Made

- `getRecentlyPlayed`'s own inline enrichment loop is a deliberate scope boundary, not touched — it has no offset-based pagination caller (Plugin.pm calls it once per menu open with a fixed `limit`), so CR-01's offset-desync risk doesn't apply to it.
- `search()`'s pre-existing offset-guard scope issue (noted in 75-REVIEW.md's CR-01 write-up as "a related off-by-scope") was explicitly NOT in this plan's Task 1 action list. Rather than silently scope-creep into fixing it or silently ignore it, it's logged to `.planning/WINDOWS.md` (entry #6, kind `deviation`) as a residual pre-existing item for a future pass.
- `_collectionAll`'s `$noCache` is implemented as a bypass-ON-DEMAND (skip the read, still write the refreshed result), never a cache-disable — this matches Plugin.pm:2088's actual call shape and keeps the 60s cache useful for every other caller of the same account+set.
- Write-path cache invalidation peeks `$_[0]` as the account id without consuming `@_`, so Client.pm still receives the exact original argument list unchanged (no signature drift for the 13 existing passthrough delegations).

## Deviations from Plan

None — plan executed exactly as written. The only notable scope decision (search()'s residual offset-guard issue, out of Task 1's explicit action list) is documented above under Decisions Made and recorded in WINDOWS.md rather than silently addressed or silently dropped.

## Issues Encountered

- The first draft of the sequential-call-chaining regression test (Task 1) initially failed because `to_json_fixture()` always returns the same fixed `gid` regardless of which hex was requested, making every enriched track in the mixed-content fixture look identical and hiding a real duplicate-tracks regression. Fixed by adding a `track_fixture_for_id($id)` helper that derives a distinguishable `gid` per requested id, and registering per-hex response rules for the 3 track ids in the mixed envelope.
- A Perl operator-precedence bug was caught before running tests: `my @x = (LIST1), (LIST2);` does NOT flatten both lists into `@x` (comma has lower precedence than `=`, so only `LIST1` is assigned and `LIST2` is evaluated in void context). Fixed by wrapping both lists in a single outer paren group.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- All 6 must-have truths (CR-01 pagination-window invariant, WR-01 empty-body guards, WR-02 `_noCache`/write-invalidation, WR-03 bounded pagination, WR-04 playlistId validation) are demonstrated by 37 new passing automated tests.
- Full `prove t/` green: 1685 tests (up from 1648 pre-gap-closure), zero regressions.
- `Client.pm` confirmed byte-identical (`git diff --stat` empty across all 3 task commits) — this plan touched only `SpClient.pm` and its test file, as scoped.
- Re-running `/gsd-verify-phase 75` should now score all previously-FAILED truths (`getSavedTracks`, `getPlaylistItems`, and the four "Degraded" truths sharing the same root cause) as VERIFIED — no remaining unresolved finding from 75-REVIEW.md.
- One residual item (search()'s offset-guard scope issue) is tracked in WINDOWS.md #6 for a future pass, not blocking phase 75 closure per 75-REVIEW.md's own scoping of CR-01's fix to the task list actually specified.

---
*Phase: 75-api-unification-spclient-modell*
*Completed: 2026-08-29*

## Self-Check: PASSED

- FOUND: `Plugins/SpotOn/API/SpClient.pm`
- FOUND: `t/36_spclient.t`
- FOUND commit: `e65107e` (Task 1: CR-01)
- FOUND commit: `5d6ad3c` (Task 2: WR-01/WR-04)
- FOUND commit: `4b31973` (Task 3: WR-02/WR-03)
- `prove t/` — Files=36, Tests=1685, PASS (up from 1648 pre-gap-closure)
- `git diff --stat` on `Plugins/SpotOn/API/Client.pm` across all 3 task commits — empty (byte-identical, confirmed)
