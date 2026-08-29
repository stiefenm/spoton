---
phase: 75-api-unification-spclient-modell
plan: 02
subsystem: api
tags: [spclient, metadata, search, context-resolve, perl, browse]

# Dependency graph
requires:
  - phase: 75-01
    provides: "SpClient.pm's _request/_doRequest pipeline, capability router (_hasLogin5Creds/_isFallbackError), base62<->hex id conversion, and the getTrack tracer + _normalizeTrack pattern this plan extends horizontally"
provides:
  - "Plugins::SpotOn::API::SpClient -- getAlbum, getAlbumTracks, getArtist, getArtistAlbums, getShow, getShowEpisodes, getEpisode, and a search router, all Web-API-shaped and D-06/D-07-wrapped"
  - "_spFacade/_enrichMeta/_enrichTracks -- shared request/normalize/fallback and lazy fan-out enrichment helpers reused by every metadata/4 facade in this plan and available to 75-04/75-05 (collection/playlist plans)"
affects: [75-03, 75-04, 75-05, 75-06]

# Actuals (#2632)
actuals:
  tokens: 11500
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "_spFacade($path, $params, $normalize, $fallback, $cb): shared D-07 request/normalize/fallback pattern -- normalize receives (rawResult, $cb) so it can be sync (getAlbum/getArtist/getShow/getEpisode) or async (getAlbumTracks/getShowEpisodes' enrichment pass) without changing the facade shape"
    - "_enrichMeta generic fan-out enrichment (id-list -> per-id metadata/4/$type/{hex} -> normalized objects, order-preserved, individual-failure-tolerant) with _enrichTracks as its track-specific, plan-external-facing wrapper"
    - "Lazy slice-then-enrich: getAlbumTracks/getShowEpisodes/search all flatten a full id/URI list first, then enrich ONLY the requested offset/limit slice -- never the whole collection (D-09 burst avoidance)"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/API/SpClient.pm
    - t/36_spclient.t

key-decisions:
  - "getAlbum's tracks.items is intentionally always empty (S-04: metadata/4/album's disc[].track[] carries gids only, no names) -- getAlbumTracks owns all per-track enrichment; this is a normalization-shape decision, not a stub (75-06 caller-switch will use getAlbumTracks for anything beyond the album's own metadata)"
  - "search() routing threshold for context-resolve is a hardcoded 20 (its verified hard ceiling, S-05) checked BEFORE issuing any HTTP request when offset>=20, avoiding a wasted spclient call for a request that can structurally never succeed via context-resolve -- a second check re-validates against the ACTUAL returned URI count (which may be <20 for a low-result query) after the fetch"
  - "getShow/getShowEpisodes/getEpisode implement metadata/4/show and metadata/4/episode as a best-effort mirror of the album/track pattern (show~album, episode~track, getShowEpisodes~getAlbumTracks) because Spike 009 verified track/album/artist/context-resolve/collection/recently-played/playlists but explicitly did NOT exercise show/episode metadata shapes -- D-07's any-4xx/5xx-falls-back-to-Client.pm safety net is the accepted mitigation for this residual shape-uncertainty, with live verification deferred to mandatory phase UAT (documented in the plan's own <verification> section, not new to this plan)"
  - "getArtistAlbums normalizes embedded album_group/single_group/compilation_group entries to a minimal stub {id,uri,name,images} with ZERO additional per-album metadata calls -- confirmed against Plugin.pm's _albumItem/_artistAlbumsFeed consumers, which only render name+id and treat images/release_date as optional-safe"
  - "_spFacade's normalize callback receives (rawResult, $cb) rather than returning a value, so the exact same helper serves both synchronous normalizers (getAlbum/getArtist/getShow/getEpisode) and asynchronous ones that must fan out further requests before calling back (getAlbumTracks/getShowEpisodes)"

requirements-completed: [D-06, D-07, D-08, D-09]

coverage:
  - id: D1
    description: "SpClient->getAlbum/getAlbumTracks return Web-API-shaped album/track-list responses from spclient metadata/4, with track names resolved via per-track metadata enrichment (S-04) through the capped/cached pipeline"
    requirement: D-06
    verification:
      - kind: unit
        ref: "t/36_spclient.t (getAlbum normalization + label/popularity/date mapping; getAlbumTracks lazy-slice + enrichment-count + D-09 cache-reuse tests)"
        status: pass
    human_judgment: false
  - id: D2
    description: "SpClient->getArtist/getArtistAlbums return Web-API-shaped artist and album-list responses from metadata/4/artist"
    requirement: D-06
    verification:
      - kind: unit
        ref: "t/36_spclient.t (getArtist normalization test; getArtistAlbums group-flattening + zero-extra-calls test)"
        status: pass
    human_judgment: false
  - id: D3
    description: "SpClient->getShow/getShowEpisodes/getEpisode attempt metadata/4 and transparently fall back to Client.pm on any 4xx/5xx (D-07 covers the spike-unverified show/episode endpoints)"
    requirement: D-07
    verification:
      - kind: unit
        ref: "t/36_spclient.t (getShow normalization test; forced-404-on-getShow D-07 safety-net test; getShowEpisodes slice+enrichment test; getEpisode single-fetch test)"
        status: pass
    human_judgment: false
  - id: D4
    description: "SpClient->search with type 'track' serves up to 20 results via context-resolve + lazy enrichment; any multi-type search or deep offset delegates to Client.pm (S-05)"
    requirement: D-08
    verification:
      - kind: unit
        ref: "t/36_spclient.t (4 search routing tests: track offset0 context-resolve path, type=album delegation, track offset20 delegation, context-resolve-500 delegation)"
        status: pass
    human_judgment: false
  - id: D5
    description: "Track/episode metadata enrichment reuses the shared 3600s per-item response cache so repeated album/show/search views trigger no duplicate metadata calls (D-09 burst avoidance)"
    requirement: D-09
    verification:
      - kind: unit
        ref: "t/36_spclient.t (D-09 cache-reuse test: two identical getAlbumTracks calls issue zero additional HTTP requests)"
        status: pass
    human_judgment: false
  - id: D6
    description: "Live verification of the spike-unverified show/episode metadata/4 shapes and a full album/artist/search round-trip against a real paired Spotify account"
    human_judgment: true
    rationale: "No paired Spotify account is reachable in this environment (Phase 73/75-01 precedent). All decodable-in-isolation behavior (normalization mapping, D-06/D-07 routing, lazy slicing, cache reuse, search routing thresholds) is covered by unit tests against synthetic fixtures; only the live network round-trip -- and specifically confirming the guessed show/episode JSON shapes -- requires a human with a real account, tracked as mandatory phase UAT per this plan's own <verification> section."

# Metrics
duration: ~30min
completed: 2026-08-29
status: complete
---

# Phase 75 Plan 02: SpClient Album/Artist/Show/Search Facades Summary

**Seven new Web-API-shaped spclient facade methods (album/artist/show/episode/search) plus shared `_spFacade`/`_enrichMeta` request-normalize-fallback and lazy fan-out enrichment helpers, extending the Phase 75-01 getTrack tracer horizontally across the JSON metadata family**

## Performance

- **Duration:** ~30 min
- **Tasks:** 3
- **Files modified:** 2 (`Plugins/SpotOn/API/SpClient.pm`, `t/36_spclient.t`)

## Accomplishments

- `getAlbum`/`getAlbumTracks`: album metadata comes Web-API-shaped from spclient with order-preserving, cache-aware track-name enrichment (S-04 -- `metadata/4/album`'s `disc[].track[]` carries gids only, no names). `getAlbumTracks` enriches ONLY the requested offset/limit slice, proven by a test that asserts exactly limit-many `metadata/4/track` requests against a 3-track album fixture, not all three.
- `getArtist`/`getArtistAlbums`: artist metadata normalized with `popularity` and `portrait_group` images (Dev-Mode value-add); `getArtistAlbums` flattens `album_group`/`single_group`/`compilation_group` into a single Web-API album-stub list with ZERO additional per-album metadata calls, confirmed against Plugin.pm's actual `_albumItem` consumer fields.
- `getShow`/`getShowEpisodes`/`getEpisode`: implemented as a best-effort mirror of the verified album/track pattern (Spike 009 never exercised these two spclient paths). Any 4xx/5xx degrades invisibly to Client.pm (D-07) -- proven with an explicit forced-404 test on `getShow`, not just a generic 500.
- `search()`: a `type=track` search on a login5-capable account routes through `context-resolve/v1` (20 URIs, double the Dev-Mode Web-API cap) with lazy enrichment nested under a Web-API-compatible `tracks.items` shape. Any other type, a PKCE-only account, an offset at/beyond the 20-result ceiling, or any context-resolve error all delegate to Client.pm unchanged -- DSTM's and JiveLite's existing paging loops keep working past the first 20 results without any caller change.
- `_spFacade`/`_enrichMeta` factor the repeated D-06/D-07/normalize boilerplate that would otherwise be duplicated across all seven new methods; `_enrichTracks` (the track-specific wrapper) is explicitly the reusable artifact for the collection/playlist plans (75-04/75-05).
- `Client.pm` remains byte-identical (`git diff --stat` empty) -- every addition is additive and isolated (D-03), confirmed after all three task commits.
- Full test suite: 36 files, 1526 tests, all green. `t/36_spclient.t` alone: 111 tests (30 new for this plan on top of 75-01's baseline).

## Task Commits

Each task was committed atomically:

1. **Task 1: Album + artist endpoints with track-name enrichment (S-04)** - `61b4e86` (feat)
2. **Task 2: Show + episode endpoints with D-07 safety net** - `24e911a` (feat)
3. **Task 3: Search router — context-resolve for track search, Client.pm for multi-type (S-05)** - `a3556b2` (feat)

## Files Created/Modified

- `Plugins/SpotOn/API/SpClient.pm` - Added `_imagesFromGroup`, `_formatDate`, `_spFacade`, `_enrichMeta`, `_enrichTracks`, `getAlbum`, `_normalizeAlbum`, `getAlbumTracks`, `getArtist`, `_normalizeArtist`, `_normalizeAlbumStub`, `getArtistAlbums`, `getShow`, `_normalizeShow`, `getShowEpisodes`, `getEpisode`, `_normalizeEpisode`, `search`
- `t/36_spclient.t` - Extended `Slim::Networking::SimpleAsyncHTTP` stub with per-URL-pattern response routing (`set_response_for`) and an `error_404` mode; extended `Plugins::SpotOn::API::Client` stub with call-recording for all 8 new delegated methods; added album/artist/show/episode/context-resolve fixtures and 30 new tests across the three tasks

## Decisions Made

- `getAlbum`'s `tracks.items` is intentionally always empty (S-04) -- `getAlbumTracks` owns all per-track enrichment; a normalization-shape decision, not a stub.
- `search()`'s context-resolve routing checks the hardcoded 20-result ceiling BEFORE issuing any HTTP request when `offset>=20` (avoids a wasted call for a request that can structurally never succeed), then re-checks against the ACTUAL returned URI count after the fetch (handles low-result queries with fewer than 20 real matches).
- `getShow`/`getShowEpisodes`/`getEpisode` implement the spike-unverified `metadata/4/show`/`metadata/4/episode` paths as a best-effort mirror of the verified album/track pattern, per the plan's explicit instruction not to preemptively hardcode them as unsupported -- D-07's any-4xx/5xx-falls-back safety net is the accepted mitigation, live verification deferred to mandatory phase UAT (already tracked, not new scope).
- `getArtistAlbums` embeds zero extra per-album metadata calls -- confirmed by reading Plugin.pm's `_albumItem`/`_artistAlbumsFeed` consumers first, which only need `id`+`name` with `images`/`release_date` already optional-safe.
- `_spFacade`'s normalize callback takes `($rawResult, $cb)` instead of returning a value, letting the same helper serve synchronous normalizers (getAlbum/getArtist/getShow/getEpisode) and asynchronous ones that must fan out further enrichment requests before calling back (getAlbumTracks/getShowEpisodes) without a second helper shape.

## Deviations from Plan

None - plan executed exactly as written. All five `must_haves.truths` hold, demonstrated by named tests in `t/36_spclient.t`. `Client.pm` verified byte-identical after every task commit.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `_enrichTracks`/`_enrichMeta` are ready for direct reuse by 75-04 (collection/v2) and 75-05 (recently-played/playlists/rootlist) without re-deriving the lazy fan-out pattern.
- `_spFacade` is available for any future metadata/4 facade needing the same D-06/D-07/normalize wiring.
- Live verification of the spike-unverified `metadata/4/show`/`metadata/4/episode` JSON shapes, and a full album/artist/search round-trip against a real paired Spotify account, remains **mandatory UAT** (no paired account reachable in this environment, Phase 73/75-01 precedent) -- tracked for `/gsd-verify-work`.
- No blockers.

## Self-Check: PASSED

- Both modified files verified present on disk with the expected final content (`diff` against the pre-commit staged snapshot: empty)
- All 3 task commit hashes (`61b4e86`, `24e911a`, `a3556b2`) verified in `git log`
- All 5 `must_haves.truths` re-verified: `prove -l t/36_spclient.t` green (111 tests); full `prove t/` (36 files, 1526 tests) green
- `git diff --stat Plugins/SpotOn/API/Client.pm` confirmed empty (byte-identical, D-03 isolation holds)

---
*Phase: 75-api-unification-spclient-modell*
*Completed: 2026-08-29*
