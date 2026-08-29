---
phase: 75-api-unification-spclient-modell
plan: 05
subsystem: api
tags: [protobuf, rootlist, playlist-v2, spclient, perl, wire-format]

# Dependency graph
requires:
  - phase: 75-01
    provides: "ProtobufLite.pm's parse_fields (repeated-field-safe wire decoder) and SpClient.pm's _request/_doRequest pipeline, capability router (_hasLogin5Creds/_isFallbackError)"
  - phase: 75-04
    provides: "_sliceAsPage/_enrichTracks (reused directly for playlist/v2 track enrichment) and the collection/v2-era caching conventions this plan mirrors for rootlist/envelope caching"
provides:
  - "Plugins::SpotOn::API::SpClient -- getUserPlaylists (protobuf-only rootlist, S-10, recursive Folder/Item/Playlist flattening), getPlaylistItems (playlist/v2 JSON envelope + sliced enrichment), _rootlistPlaylists, _parseRootlist, _flattenRootlistFolder, _normalizePlaylistMeta, _playlistEnvelope, all D-06/D-07-wrapped"
affects: [75-06]

# Actuals (#2632)
actuals:
  tokens: 7575
  tasks: 2
  commits: 2

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Depth-bounded recursive protobuf flattening: _flattenRootlistFolder walks the rootlist's nested Folder->Item->{Playlist|Folder} tree with an explicit ROOTLIST_MAX_DEPTH guard (T-75-16/V5) -- the first pattern in this phase where ProtobufLite.pm's generic parse_fields is invoked recursively on nested embedded messages rather than a single flat layer"
    - "URI-derivation fallback chain: _normalizePlaylistMeta prefers PlaylistMetadata.link (a full spotify:playlist: URI) over Playlist.row_id, but treats row_id as either an already-full URI OR a bare base62 id to derive one from -- handles rootlist response variance (decorated vs undecorated) without dying on either shape"
    - "Full-envelope-then-slice, mirroring the 75-04 collection/v2 caching convention: _playlistEnvelope fetches and caches the WHOLE playlist/v2 response once (300s, playlist-tier TTL), and getPlaylistItems slices+enriches only the requested offset/limit window from the cached envelope on every subsequent call within the TTL"

key-files:
  created: []
  modified:
    - Plugins/SpotOn/API/SpClient.pm
    - t/36_spclient.t

key-decisions:
  - "PlaylistMetadata.link takes precedence over row_id for URI derivation, with row_id as a dual-purpose fallback (used as-is if it's already a spotify:playlist: URI, otherwise treated as a bare id to prepend the prefix to) -- the rootlist proto documents row_id as \"string\" with no further guarantee about its exact format across decorate-param variants, so both branches degrade safely rather than assuming one shape"
  - "ROOTLIST_MAX_DEPTH=10 bounds _flattenRootlistFolder's recursion (T-75-16/V5) -- proven with a synthetic 20-level-deep folder fixture that returns cleanly (buried playlist silently dropped past the cap) rather than crashing or exhausting the call stack"
  - "getPlaylistItems preserves Client.pm's exact 5-arg signature (accountId, playlistId, params, cb) with no distinct opts variant -- ProtocolHandler.pm's explodePlaylist call site (read_first) confirmed Client.pm itself takes this same shape, so no signature translation was needed"
  - "_playlistEnvelope caches the FULL playlist/v2 response (not per-page) at 300s TTL, matching the established 75-04 pattern (_collectionAll/_likedSongsUris) of fetching complete spclient state once and slicing/enriching only what's requested -- avoids repeated playlist/v2 GETs across sequential OPML page-forward navigation within the TTL window"

requirements-completed: [D-01, D-06, D-07, D-08, D-09]

coverage:
  - id: D1
    description: "SpClient->getUserPlaylists serves the user's playlist library from the protobuf-only rootlist endpoint (S-10), flattening nested Folder/Item/Playlist trees into a Web-API-shaped playlist list for the Plugin.pm playlists feed"
    requirement: D-08
    verification:
      - kind: unit
        ref: "t/36_spclient.t (nested-folder fixture: 2 top-level + 1 folder-nested playlist, all 3 surface flattened in tree order with correct uri/name/owner)"
        status: pass
    human_judgment: false
  - id: D2
    description: "_flattenRootlistFolder's recursion is bounded (ROOTLIST_MAX_DEPTH=10, T-75-16/V5) -- a pathological/adversarial deeply-nested rootlist payload cannot exhaust the call stack or hang"
    requirement: D-01
    verification:
      - kind: unit
        ref: "t/36_spclient.t (20-level-deep synthetic folder fixture returns cleanly; source assertions confirm the depth-guard constant and bail-out check exist)"
        status: pass
    human_judgment: false
  - id: D3
    description: "SpClient->getPlaylistItems serves playlist tracks from playlist/v2 (JSON via Accept header) with sliced track enrichment, matching the _playlistFeed/ProtocolHandler item shape ({items:[{track=>...}], total, offset, limit, next})"
    requirement: D-08
    verification:
      - kind: unit
        ref: "t/36_spclient.t (5-track envelope, offset=0/limit=3 -> exactly 3 enrichment calls, total=5; envelope-cache test: one playlist/v2 GET shared across two calls at different offsets)"
        status: pass
    human_judgment: false
  - id: D4
    description: "Both getUserPlaylists and getPlaylistItems honor D-06 capability routing (no login5-capable creds -> Client.pm) and D-07 fallback (any spclient request or protobuf-parse failure -> Client.pm), matching every other SpClient facade in this phase"
    requirement: "D-06, D-07"
    verification:
      - kind: unit
        ref: "t/36_spclient.t (getUserPlaylists: creds-absent + rootlist-500 + malformed-bytes delegation tests; getPlaylistItems: creds-absent + playlist/v2-500 delegation tests -- all assert exactly one Client.pm delegation call)"
        status: pass
    human_judgment: false
  - id: D5
    description: "Every browse-data method plan 75-06 needs now exists on SpClient.pm: getTrack, getAlbum, getAlbumTracks, getArtist, getArtistAlbums, getShow, getShowEpisodes, getEpisode, search, getSavedTracks, getSavedAlbums, getFollowedArtists, getSavedShows, getRecentlyPlayed, getUserPlaylists, getPlaylistItems"
    verification:
      - kind: unit
        ref: "grep confirms all 16 sub definitions present in Plugins/SpotOn/API/SpClient.pm"
        status: pass
    human_judgment: false
  - id: D6
    description: "A real rootlist decorate-params fetch and playlist/v2 envelope fetch against a live paired Spotify account works end-to-end, including the actual decorated PlaylistMetadata field layout in production (S-10 field-number choices are proto-verified but not live-verified)"
    human_judgment: true
    rationale: "No paired Spotify account is reachable in this environment (Phase 73/75-01..75-04 precedent). All decodable-in-isolation behavior (nested protobuf flattening, depth guard, URI-derivation fallback chain, envelope slicing/enrichment, caching, D-06/D-07 routing) is covered by unit tests against synthetic fixtures encoded with the SAME ProtobufLite.pm the production code uses; only the live network round-trip and the real decorate-response field layout require a human with a real account, tracked as mandatory phase UAT per this plan's own <verification> section (aided by the 75-06 smoke script, which already covers a rootlist fetch)."

duration: ~12min
completed: 2026-08-29
status: complete
---

# Phase 75 Plan 05: SpClient Playlist Family (Rootlist + Playlist/v2) Summary

**getUserPlaylists decodes the protobuf-only rootlist's nested Folder/Item/Playlist tree with a bounded-depth flattener; getPlaylistItems serves playlist/v2's JSON envelope with cached full-fetch + sliced enrichment -- completing every SpClient facade plan 75-06 needs**

## Performance

- **Duration:** ~12 min
- **Tasks:** 2
- **Files modified:** 2 (`Plugins/SpotOn/API/SpClient.pm`, `t/36_spclient.t`)

## Accomplishments

- `_rootlistPlaylists`/`_parseRootlist`/`_flattenRootlistFolder`: decode the protobuf-only rootlist endpoint (S-10 -- `Accept: application/json` has no effect) by recursively walking the `Response -> root Folder -> repeated Item -> {Playlist | Folder}` tree (field numbers from `proto/rootlist_request.proto` and its imports), flattening arbitrarily nested folders into a single ordered playlist list -- proven with a fixture containing 2 top-level playlists plus 1 folder nesting a 3rd, all 3 surfacing correctly in tree order.
- `_normalizePlaylistMeta`: decodes a `Playlist` message's `playlist_metadata` submessage (`link`/`name`/`owner`) into the Web-API playlist shape, with a URI-derivation fallback chain (prefer `PlaylistMetadata.link`, else treat `row_id` as either an already-full URI or a bare id to derive one from) -- proven with dedicated unit tests for both branches plus a malformed-bytes-returns-undef case.
- `ROOTLIST_MAX_DEPTH=10` bounds the folder-flattening recursion (T-75-16/V5) -- proven with a synthetic 20-level-deep nested-folder fixture that returns cleanly (the buried playlist silently dropped past the cap) instead of crashing or exhausting the call stack, plus source-level assertions confirming the guard exists.
- `getUserPlaylists`: D-06 (no login5-capable creds) and D-07 (any rootlist request or protobuf-parse failure, including malformed bytes) both delegate transparently to `Client.pm->getUserPlaylists` -- proven with dedicated router-regression tests, mirroring every other facade in this phase.
- `_playlistEnvelope`: fetches and caches (300s, CLAUDE.md's playlist-tracks tier) the FULL `playlist/v2/playlist/{id}` JSON response (the one playlist-family endpoint that honors `Accept: application/json`, unlike rootlist) -- proven with a cache-reuse test where two sequential `getPlaylistItems` calls at different offsets share exactly one HTTP GET.
- `getPlaylistItems`: preserves `Client.pm`'s exact 5-arg signature (verified against `ProtocolHandler.pm`'s `explodePlaylist` call site), slices the envelope's `contents.items[]` track URIs by offset/limit, enriches ONLY the requested slice via `_enrichTracks` (lazy, D-09, rides the shared 3600s track cache) -- proven with a 5-track envelope where `offset=0/limit=3` issues exactly 3 enrichment calls while `total` still reports the full 5. Result shape is identical to `getSavedTracks`'s (`{items:[{track=>...}], total, offset, limit, next}`), a superset of what both `_playlistFeed`/`_trackItem` and `ProtocolHandler`'s playlist-resolution path consume.
- All 16 browse-data methods plan 75-06 needs (`getTrack`, `getAlbum`, `getAlbumTracks`, `getArtist`, `getArtistAlbums`, `getShow`, `getShowEpisodes`, `getEpisode`, `search`, `getSavedTracks`, `getSavedAlbums`, `getFollowedArtists`, `getSavedShows`, `getRecentlyPlayed`, `getUserPlaylists`, `getPlaylistItems`) now exist on `SpClient.pm`, verified by direct grep against the module.
- Full test suite: 36 files, 1617 tests, all green (`t/36_spclient.t` alone: 202 tests, up from 75-04's 169-test baseline). `Client.pm`/`Credentials.pm`/`TokenManager.pm`/`Plugin.pm`/`ProtocolHandler.pm` remain byte-identical (`git diff --stat` empty for all five) -- D-03 isolation and Client-identical-caller-contract both hold after each task commit.

## Task Commits

Each task was committed atomically:

1. **Task 1: getUserPlaylists via rootlist (protobuf-only, S-10)** - `eb1ed9d` (feat)
2. **Task 2: getPlaylistItems via playlist/v2 (JSON) with sliced enrichment** - `f7aca28` (feat)

## Files Created/Modified

- `Plugins/SpotOn/API/SpClient.pm` - Added `ROOTLIST_DECORATE`/`ROOTLIST_LIST_TTL`/`ROOTLIST_MAX_DEPTH`/`PLAYLIST_ENVELOPE_TTL` constants, `_rootlistPlaylists`, `_parseRootlist`, `_flattenRootlistFolder`, `_normalizePlaylistMeta`, `getUserPlaylists`, `_playlistEnvelope`, `getPlaylistItems`
- `t/36_spclient.t` - Extended the `Client` stub with call-recording for `getUserPlaylists`/`getPlaylistItems`; added rootlist protobuf fixture encoders (`encode_user`, `encode_playlist_metadata`, `encode_rootlist_playlist`, `encode_rootlist_item`, `encode_rootlist_folder`, `encode_rootlist_response`) and a `playlist_envelope_fixture` JSON encoder; 41 new tests across the two tasks (nested-folder flattening, malformed-bytes fallback, depth-guard runtime + source assertions, `_normalizePlaylistMeta` unit tests, D-06/D-07 router regressions for both methods, envelope-cache reuse, sliced-enrichment count)

## Decisions Made

- `PlaylistMetadata.link` takes precedence over `row_id` for URI derivation, with `row_id` as a dual-purpose fallback (used as-is if already a `spotify:playlist:` URI, otherwise treated as a bare id) -- the proto documents `row_id` as a plain `string` with no format guarantee across decorate-param variants, so both branches degrade safely.
- `ROOTLIST_MAX_DEPTH=10` bounds `_flattenRootlistFolder`'s recursion (T-75-16/V5), proven against a synthetic 20-level-deep fixture.
- `getPlaylistItems` keeps `Client.pm`'s exact 5-arg signature with no distinct opts variant -- `ProtocolHandler.pm`'s `explodePlaylist` call site confirmed `Client.pm` itself takes this same shape, so no translation layer was needed.
- `_playlistEnvelope` caches the FULL playlist/v2 response (not per-page) at 300s, matching 75-04's established full-fetch-then-slice convention (`_collectionAll`/`_likedSongsUris`) rather than introducing a new caching shape for this one endpoint family.

## Deviations from Plan

None - plan executed exactly as written. All three `must_haves.truths` hold, demonstrated by named tests in `t/36_spclient.t`. `Client.pm` verified byte-identical after every task commit. The plan's own open decision point ("if the decorate response omits names in practice, fall back per-playlist to `_normalizePlaylistMeta` over GET `/playlist/v2/playlist/{id}`...") resolved in favor of decoding names directly from the rootlist's `playlist_metadata` submessage per the proto schema, since `proto/rootlist_request.proto`'s `PlaylistMetadata.name` (field 2) is present whenever `decorate=attributes` is requested (which `ROOTLIST_DECORATE` always includes) -- no per-playlist fallback fetch was needed; live UAT will confirm this proto-schema assumption holds against a real decorated response.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All 16 browse-data facade methods now exist on `SpClient.pm` with consistent D-06/D-07 wrapping -- plan 75-06 can proceed with its mechanical caller-switch (`Plugin.pm`/`ProtocolHandler.pm`/`Connect.pm`/`DontStopTheMusic.pm` import swap from `Client.pm` to `SpClient.pm`) with no remaining gaps.
- Live verification of rootlist decorate-params behavior (does the real decorated response populate `playlist_metadata.name`/`owner` as the proto schema implies?) and the playlist/v2 JSON envelope's exact field layout remain **mandatory UAT** (no paired account reachable in this environment, Phase 73/75-01..75-04 precedent) -- tracked for `/gsd-verify-work`, aided by the 75-06 smoke script (already covers a rootlist fetch per its own SUMMARY).
- No blockers.

## Self-Check: PASSED

- Both modified files verified present on disk with the expected final content
- Both task commit hashes (`eb1ed9d`, `f7aca28`) verified in `git log`
- All 3 `must_haves.truths` re-verified: `prove -l t/36_spclient.t` green (202 tests); full `prove t/` (36 files, 1617 tests) green
- All 16 required browse-data methods confirmed present via `grep '^sub ' Plugins/SpotOn/API/SpClient.pm`
- `git diff --stat Plugins/SpotOn/API/Client.pm Plugins/SpotOn/API/Credentials.pm Plugins/SpotOn/API/TokenManager.pm Plugins/SpotOn/Plugin.pm Plugins/SpotOn/ProtocolHandler.pm` confirmed empty (byte-identical, D-03 isolation and caller-contract both hold)

---
*Phase: 75-api-unification-spclient-modell*
*Completed: 2026-08-29*
