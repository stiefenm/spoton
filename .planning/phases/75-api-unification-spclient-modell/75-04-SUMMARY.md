---
phase: 75-api-unification-spclient-modell
plan: 04
subsystem: api
tags: [protobuf, collection-v2, context-resolve, recently-played, spclient, perl, wire-format]

# Dependency graph
requires:
  - phase: 75-01
    provides: "ProtobufLite.pm's parse_fields (repeated-field-safe wire decoder) and SpClient.pm's _request/_doRequest pipeline, capability router (_hasLogin5Creds/_isFallbackError)"
  - phase: 75-02
    provides: "_spFacade/_enrichMeta/_enrichTracks shared request/normalize/fallback and lazy fan-out enrichment helpers extended by this plan's collection-slice enrichment"
provides:
  - "Plugins::SpotOn::API::SpClient -- SET_MAP, _collectionPage, _collectionAll, _sliceAsPage, _enrichCollectionSlice, getSavedAlbums, getFollowedArtists, getSavedShows, getSavedTracks, getRecentlyPlayed, all Web-API-shaped and D-06/D-07-wrapped"
  - "_doRequest extended with optional _body/_contentType support (POST bodies), the infrastructure collection/v2 needed"
affects: [75-05, 75-06]

# Actuals (#2632)
actuals:
  tokens: 13800
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "_enrichCollectionSlice($accountId,\\@slice,$metaType,$normalizeMethod,$wrapKey,$cb): order-preserving id-in/wrapped-object-out enrichment that re-pairs each result with its ORIGINAL added_at (distinct from _enrichMeta, which discards positional pairing when it filters undefs)"
    - "Single-item probe before N-item enrichment: getSavedShows fetches the FIRST slice item's metadata alone to detect a broadly-broken spike-unverified endpoint, routing the WHOLE call to Client.pm in one shot instead of risking N per-item Client.pm fallback roundtrips"
    - "Cursor emulation over a cached full list: getFollowedArtists resolves a Web-API-shaped after-cursor (last artist's id) to a position in the cached collection/v2 list rather than exposing spclient's plain-list reality to callers"
    - "Original-request-uri-keyed pairing: getRecentlyPlayed pairs each enriched track with its OWN request uri's lastPlayedTime rather than the enriched object's returned uri, which may differ (relinked/canonicalized track)"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/API/SpClient.pm
    - t/36_spclient.t

key-decisions:
  - "getSavedTracks has NO play-all-specific shortcut: _savedTracksFeed's play-all branch calls this SAME method repeatedly via _fetchAllPages with successive offset/limit windows, and every page must carry full track fields (name/artists/album/duration_ms) for _trackItem to render -- the already-complete cached URI list (context-resolve, 60s TTL) already makes every page a cheap slice+enrichment call with no Spotify-side re-pagination, so no shortcut was needed"
  - "getSavedShows probes the FIRST slice item's metadata/4/show fetch before enriching the rest -- a fallback-classified error there routes the WHOLE call to Client.pm in one shot, avoiding N per-item Client.pm fallback roundtrips if the spike-unverified endpoint is broadly broken for an account"
  - "getFollowedArtists emulates the Web-API cursor contract (after=last-artist-id) purely by resolving position in the cached collection/v2 'artist' list -- matches _fetchAllFollowedArtists's actual consumption (loop on cursors.after until empty) without exposing spclient's plain-list shape to callers"
  - "collection/v2 list-level cache (60s, per account+set) and the Liked-Songs URI-list cache (60s, per account) are both independent of the shared _request response cache (_noCache=1 on the underlying HTTP calls) -- this module owns list-level caching explicitly rather than relying on path-based caching, since the same collection/v2 URL serves different pages via different pagination_token bodies"
  - "getRecentlyPlayed pairs lastPlayedTime by the ORIGINAL recently-played context uri, not by the enriched track object's own uri -- a canonicalized/relinked track uri from metadata/4/track could otherwise silently break the pairing"

requirements-completed: [D-01, D-06, D-07, D-08, D-09]

coverage:
  - id: D1
    description: "SpClient->getSavedAlbums serves Saved Albums via collection/v2 with the exact application/vnd.collection-v2.spotify.proto Content-Type/Accept and the verified 'collection' set name (S-06/S-07)"
    requirement: D-08
    verification:
      - kind: unit
        ref: "t/36_spclient.t (wire-level CT/body assertions, SET_MAP assertion)"
        status: pass
    human_judgment: false
  - id: D2
    description: "collection/v2 PageResponse decoding returns ALL repeated items across pagination pages (A1), cached as a URI list and served to callers as Web-API offset/limit pages"
    requirement: D-01
    verification:
      - kind: unit
        ref: "t/36_spclient.t (2-page pagination test proving 4 items surface; is_removed tombstone filter; D-09 list-cache-reuse test)"
        status: pass
    human_judgment: false
  - id: D3
    description: "SpClient->getFollowedArtists and getSavedShows serve their collection/v2 sets with caller-compatible cursor/offset semantics, including a single-item probe fallback for the spike-unverified show endpoint"
    requirement: D-08
    verification:
      - kind: unit
        ref: "t/36_spclient.t (cursor-walk test across 2 sequential calls; saved-shows shape test; probe-fallback test via set_error_for; D-06/D-07 router regressions)"
        status: pass
    human_judgment: false
  - id: D4
    description: "SpClient->getSavedTracks serves the FULL Liked Songs list via context-resolve (no Spotify-side paging), sliced/enriched per requested offset/limit, and SpClient->getRecentlyPlayed decodes the protobuf-only recently-played/v3 response into the item shape Plugin.pm's feed consumes"
    requirement: "D-06, D-07, D-09"
    verification:
      - kind: unit
        ref: "t/36_spclient.t (25-URI liked-songs slice/enrichment-count test; 3-context recently-played fixture proving track-only filtering + multi-byte varint decode; username-source A5 regression)"
        status: pass
    human_judgment: false
  - id: D5
    description: "All collection paths (collection/v2, context-resolve, recently-played) use the credentials.json username from verifyCredentials, never the prefs spotifyUserId"
    requirement: D-06
    verification:
      - kind: unit
        ref: "t/36_spclient.t (username-source A5 test: prefs spotifyUserId set to a distinct value, request URL asserted to contain only the credentials username)"
        status: pass
    human_judgment: false
  - id: D6
    description: "A real collection/v2 POST, context-resolve Liked Songs fetch, and recently-played protobuf decode against a live paired Spotify account works end-to-end"
    human_judgment: true
    rationale: "No paired Spotify account is reachable in this environment (Phase 73/75-01/75-02 precedent). All decodable-in-isolation behavior (wire encode/decode, pagination, tombstone filtering, cursor emulation, probe-fallback, username sourcing, slicing/enrichment) is covered by unit tests against synthetic fixtures; only the live network round-trip requires a human with a real account, tracked as mandatory phase UAT per this plan's own <verification> section (aided by the 75-06 smoke script)."

duration: ~35min
completed: 2026-08-29
status: complete
---

# Phase 75 Plan 04: SpClient Collection/v2 + Liked Songs + Recently Played Summary

**Five new Web-API-shaped SpClient facades (getSavedAlbums, getFollowedArtists, getSavedShows, getSavedTracks, getRecentlyPlayed) backed by a hand-rolled collection/v2 protobuf paginator and a protobuf-only recently-played decoder, all D-06/D-07-wrapped and username-sourced exclusively from credentials.json**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3
- **Files modified:** 2 (`Plugins/SpotOn/API/SpClient.pm`, `t/36_spclient.t`)

## Accomplishments

- `_collectionPage`/`_collectionAll`: hand-encoded collection/v2 `PageRequest` (username/set/pagination_token/limit) POSTed with the exact `application/vnd.collection-v2.spotify.proto` Content-Type AND Accept (S-06 -- any other value 400s), decoded via ProtobufLite's repeated-field-safe `parse_fields` (A1 -- proven with a 2-page fixture surfacing all 4 items across pages, not just the last), `is_removed` tombstones filtered at decode time, full list cached 60s per account+set.
- `getSavedAlbums`: serves the collection/v2 `collection` set (S-07's confusingly-named Saved Albums set) sliced per offset/limit and enriched via the new `_enrichCollectionSlice` helper, which re-pairs each successful metadata fetch with its original `added_at` -- an order-preserving pairing `_enrichMeta` can't provide once it filters undefs.
- `getFollowedArtists`: emulates the Web-API's cursor contract (`after` = last artist's id) purely by resolving a position in the cached `artist` collection/v2 list -- proven with a full cursor walk across 2 sequential calls (2-of-3 then the remaining 1, with a correctly terminating `cursors.after`), while both calls share one cached collection/v2 fetch.
- `getSavedShows`: probes the FIRST slice item's `metadata/4/show` fetch before enriching the rest of the slice; a fallback-classified probe error routes the WHOLE call to Client.pm in a single shot instead of N per-item Client.pm fallback roundtrips (metadata/4/show is spike-unverified, per 75-02's precedent) -- proven with a dedicated single-probe-attempt test using a new `set_error_for` per-URL error-injection stub helper.
- `getSavedTracks`: serves the ENTIRE Liked Songs list via `context-resolve/v1/spotify:user:{username}:collection` (S-04's headline win -- no Spotify-side 50-item paging), cached 60s, then sliced/enriched per the requested offset/limit -- proven with a 25-URI fixture where offset=10/limit=10 issues exactly 10 enrichment calls while `total` still reports the full 25.
- `getRecentlyPlayed`: decodes the protobuf-only `recently-played/v3` response (S-09 -- `Accept: application/json` has no effect) via ProtobufLite, filtering to `spotify:track:` contexts only and correctly decoding `lastPlayedTime` through a multi-byte varint (epoch-ms values need 6+ bytes) -- proven with a 3-context fixture (2 tracks + 1 playlist) where exactly the 2 track items survive with their original request uri's timestamp intact.
- Every new username-consuming path (collection/v2, context-resolve, recently-played) sources the Spotify canonical username exclusively from `Credentials->verifyCredentials`, never prefs `spotifyUserId` -- proven with an explicit A5 regression test setting a distinct, deliberately wrong prefs value and asserting the request URL never contains it.
- `_doRequest` gained optional `_body`/`_contentType` params (POST support) -- the one piece of shared-pipeline infrastructure this plan needed beyond 75-01's GET-only tracer, backward-compatible with every existing GET-only facade.
- Full test suite: 36 files, 1584 tests, all green. `t/36_spclient.t` alone: 169 tests (58 new for this plan on top of 75-02's 111-test baseline).
- `Client.pm`/`Credentials.pm`/`TokenManager.pm` remain byte-identical (`git diff --stat` empty for all three) -- D-03 isolation holds after all three task commits.

## Task Commits

Each task was committed atomically:

1. **Task 1: collection/v2 plumbing + getSavedAlbums (S-06/S-07, A1)** - `2f2f606` (feat)
2. **Task 2: getFollowedArtists + getSavedShows on collection sets** - `40dcf3b` (feat)
3. **Task 3: getSavedTracks (Liked Songs, no paging) + getRecentlyPlayed (protobuf, S-09)** - `74b1b2f` (feat)

## Files Created/Modified

- `Plugins/SpotOn/API/SpClient.pm` - Added `COLLECTION_V2_CONTENT_TYPE`/`COLLECTION_PAGE_LIMIT`/`COLLECTION_LIST_TTL`/`LIKED_SONGS_LIST_TTL`/`RECENTLY_PLAYED_ACCEPT`/`SET_MAP` constants, `_username`, `_collectionPage`, `_collectionAll`, `_sliceAsPage`, `_enrichCollectionSlice`, `getSavedAlbums`, `getFollowedArtists`, `getSavedShows`, `_likedSongsUris`, `getSavedTracks`, `getRecentlyPlayed`; extended `_doRequest` with `_body`/`_contentType` POST support
- `t/36_spclient.t` - Extended the `SimpleAsyncHTTP` stub with `set_error_for` (per-URL forced error regardless of `auto_mode`) and sequential/coderef response support in `set_response_for` (needed for 2-page pagination fixtures keyed on the request body's `pagination_token`); extended the `Client` stub with call-recording for `getSavedAlbums`/`getFollowedArtists`/`getSavedShows`/`getSavedTracks`/`getRecentlyPlayed`; added collection/v2, liked-songs, and recently-played protobuf fixtures plus 58 new tests across the three tasks

## Decisions Made

- `getSavedTracks` carries NO play-all-specific shortcut -- `_savedTracksFeed`'s play-all branch reuses this SAME method via `_fetchAllPages`, and every page needs full track fields for `_trackItem` to render; the cached complete URI list already makes every page cheap regardless of mode, so no special-casing was needed (recorded per the plan's explicit instruction to decide from caller field usage).
- `getSavedShows`'s single-item probe (rather than per-item Client.pm fallback) avoids N wasted fallback roundtrips if `metadata/4/show` (spike-unverified) is broadly broken for an account -- one probe determines the whole call's fate.
- `getFollowedArtists`'s cursor emulation resolves position purely via URI lookup in the cached list rather than any Spotify-side cursor token, matching exactly what `_fetchAllFollowedArtists` consumes (loop on `cursors.after` until empty/absent).
- `_enrichCollectionSlice` is a distinct helper from 75-02's `_enrichMeta` specifically because it must re-pair each result with its ORIGINAL `added_at` -- `_enrichMeta`'s filter-undefs-then-return-array shape would lose that positional association once any item failed.
- `getRecentlyPlayed` keys the `lastPlayed` pairing by the request's own URI, not the enriched track object's returned URI, protecting against a canonicalized/relinked track URI silently breaking the pairing.

## Deviations from Plan

None - plan executed exactly as written. All five `must_haves.truths` hold, demonstrated by named tests in `t/36_spclient.t`. `Client.pm` verified byte-identical after every task commit.

## Issues Encountered

- Initial `getRecentlyPlayed` implementation reused the 75-02 `_enrichTracks` helper and keyed `lastPlayed` lookups by the ENRICHED track's returned `uri` -- this failed against the test fixture (mock metadata always returns the same fixed `gid` regardless of requested id, so the enriched uri never matches the original request uri). Fixed before committing by writing a dedicated order-preserving enrichment loop that pairs by the original request uri instead (see Decisions Made) -- not a plan deviation, a normal implementation correction caught by the test suite.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Five new facade methods are ready for 75-06's mechanical caller-switch (Plugin.pm/ProtocolHandler.pm/Connect.pm/DontStopTheMusic.pm import swap from Client.pm to SpClient.pm).
- `_collectionAll`/`_sliceAsPage`/`_enrichCollectionSlice` are reusable by 75-05 for the remaining collection/v2 sets it may need (pinned_playlists/saved_episodes, already documented in `SET_MAP`).
- `_doRequest`'s new `_body`/`_contentType` POST support is available for 75-05's playlist/v2 and rootlist endpoints if they need POST semantics.
- Live verification of collection/v2, context-resolve Liked Songs, and recently-played protobuf decoding against a real paired Spotify account remains **mandatory UAT** (no paired account reachable in this environment, Phase 73/75-01/75-02 precedent) -- tracked for `/gsd-verify-work`, aided by the 75-06 smoke script.
- No blockers.

## Self-Check: PASSED

- Both modified files verified present on disk with the expected final content
- All 3 task commit hashes (`2f2f606`, `40dcf3b`, `74b1b2f`) verified in `git log`
- All 5 `must_haves.truths` re-verified: `prove -l t/36_spclient.t` green (169 tests); full `prove t/` (36 files, 1584 tests) green
- `git diff --stat Plugins/SpotOn/API/Client.pm Plugins/SpotOn/API/Credentials.pm Plugins/SpotOn/API/TokenManager.pm` confirmed empty (byte-identical, D-03 isolation holds)

---
*Phase: 75-api-unification-spclient-modell*
*Completed: 2026-08-29*
