---
phase: 75-api-unification-spclient-modell
verified: 2026-08-29T00:00:00Z
status: passed
score: 27/27 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 20/23 must-haves verified (27 truths enumerated: 20 clean-VERIFIED, 3 hard-FAILED, 4 Degraded-same-root-cause)
  gaps_closed:
    - "CR-01: SpClient->getPlaylistItems total/items desync (unfiltered envelope length vs. track-filtered slice) — now filter-before-slice + recount"
    - "CR-01 root cause: _enrichMeta/_enrichCollectionSlice grep{defined} silent item drop on per-item enrichment failure — now substitutes a minimal id/uri/name=>undef stub, preserving requested-window-size invariant for getAlbumTracks, getShowEpisodes, getSavedTracks, getSavedAlbums, getFollowedArtists, getSavedShows, search"
    - "WR-01: getAlbumTracks/getArtistAlbums/getShowEpisodes normalize closures died on an empty/malformed metadata/4 200 body — now guard undef/non-HASH $meta and route through the same named Client.pm fallback"
    - "WR-02: getSavedShows ignored params._noCache; no write-path cache invalidation — now _collectionAll accepts an optional noCache bypass-on-demand arg, and saveTracks/removeTracks/saveShows/removeShows invalidate their list cache key before delegating"
    - "WR-03: _collectionAll pagination loop had no page cap or repeated-token guard — now bounded by COLLECTION_MAX_PAGES (100) plus a repeated-next_page_token end-of-list guard"
    - "WR-04: getPlaylistItems spliced an unvalidated $playlistId into the spclient URL path and cache key — now validated against /^[0-9A-Za-z]{22}$/ before any use"
  gaps_remaining: []
  regressions: []
deferred: []
coincidental_reliance_items: []
---

# Phase 75: API Unification (spclient-Modell) Verification Report

**Phase Goal:** Build spclient API layer (ProtobufLite, Login5, SpClient) and switch all browse/search/library call sites from Client.pm to the SpClient facade with D-06 capability routing and D-07 Client.pm fallback.
**Verified:** 2026-08-29
**Status:** passed
**Re-verification:** Yes — after gap closure (plan 75-07)

## Goal Achievement

### Observable Truths

All 27 truths enumerated in the initial `75-VERIFICATION.md` were re-checked. The 3 hard-FAILED
truths and the 4 "Degraded" truths (sharing CR-01's root cause) are re-verified below against the
`75-07` gap-closure commits (`e65107e`, `5d6ad3c`, `4b31973`). The 20 previously-clean truths were
spot-checked for regression (existence/wiring unchanged — no file other than `SpClient.pm` and
`t/36_spclient.t` was touched by 75-07, confirmed via `git diff --stat` on `Client.pm` being empty
across all three task commits).

| # | Truth (source plan) | Status | Evidence |
|---|------|--------|----------|
| 1 | ProtobufLite decodes repeated CollectionItems into arrays, tolerates malformed input (D-01/A1) — 75-01 | ✓ VERIFIED | Unchanged since initial verification; `t/34_protobuf_lite.t` green (part of 1685-test full suite) |
| 2 | Login5 mints a full-length Bearer token (S-01) — 75-01 | ✓ VERIFIED | Unchanged; `t/35_login5.t` green |
| 3 | SpClient->getTrack routes via spclient/Client.pm (D-06) — 75-01 | ✓ VERIFIED | Unchanged; router logic untouched by 75-07 |
| 4 | spclient 4xx/5xx falls back to Client.pm, single 401 remint-retry only (D-07/D-07a) — 75-01 | ✓ VERIFIED | Unchanged |
| 5 | spclient 429 uses its own rate-limit key (D-03/D-09) — 75-01 | ✓ VERIFIED | Unchanged |
| 6 | getAlbum/getAlbumTracks Web-API-shaped with per-track enrichment (S-04) — 75-02 | ✓ VERIFIED | **CR-01 closed**: `getAlbumTracks` consumes `_enrichTracks`→`_enrichMeta`, which now substitutes a stub (`SpClient.pm:654-658`) instead of dropping a failed slot. New test `t/36_spclient.t` "CR-01 partial-enrichment-failure" passes. **WR-01 closed**: `getAlbumTracks` guards `unless ($meta && ref($meta) eq 'HASH')` (SpClient.pm:807-810) before dereferencing, routing to a named `$fallback` (Client.pm delegation) instead of dying. |
| 7 | getArtist/getArtistAlbums Web-API-shaped — 75-02 | ✓ VERIFIED | **WR-01 closed**: `getArtistAlbums` has the identical empty-body guard (SpClient.pm:950-953) with a named `$fallback`. `getArtist` itself has no paginated/enrichment surface, unaffected. |
| 8 | getShow/getShowEpisodes/getEpisode attempt metadata/4, fall back on 4xx/5xx (D-07) — 75-02 | ✓ VERIFIED | **CR-01 closed** (via `_enrichMeta` stub substitution, `getShowEpisodes` calls `_enrichMeta($accountId, ..., 'episode', ...)` at SpClient.pm:1088). **WR-01 closed**: `getShowEpisodes` guards `unless ($meta && ref($meta) eq 'HASH')` at SpClient.pm:1075-1078. |
| 9 | search type=track via context-resolve+enrichment; multi-type delegates (S-05) — 75-02 | ✓ VERIFIED | `search()` consumes `_enrichTracks`→`_enrichMeta`, so window-size-exact stub substitution applies here too. **Residual, out-of-scope, honestly logged item**: `search()`'s own pre-existing offset-vs-uri-count comparison (SpClient.pm:1223, compares `$offset` against `scalar(@uris)` not `scalar(@trackIds)`) was explicitly NOT in 75-07's Task 1 scope and is logged as an open deviation in `.planning/WINDOWS.md` (#6) — a narrow edge case (only triggers if `page->{tracks}` ever contains a non-track-prefixed URI, which the context-resolve `tracks` field is not expected to). Not part of this phase's original CR-01/WR-01..04 gap set; not blocking. |
| 10 | Enrichment reuses 3600s cache, no duplicate calls (D-09) — 75-02 | ✓ VERIFIED | Unchanged, `_request`'s cache layer untouched |
| 11 | spoton-helper builds/tests green with only patch+check (D-02) — 75-03 | ✓ VERIFIED | Unchanged, out of 75-07's file scope |
| 12 | protobuf/protobuf-codegen crates gone from dependency tree — 75-03 | ✓ VERIFIED | Unchanged |
| 13 | `spoton-helper check` unchanged D-08 capability JSON (t/26 green) — 75-03 | ✓ VERIFIED | `t/26_soloist_check.t` green in full suite run |
| 14 | Vendored .proto files remain with README — 75-03 | ✓ VERIFIED | Unchanged, `spoton-helper/proto/README.md` exists |
| 15 | getSavedAlbums/getFollowedArtists/getSavedShows via collection/v2 with exact CT + verified set names (S-06/S-07) — 75-04 | ✓ VERIFIED | **CR-01 closed**: all three consume `_enrichCollectionSlice`, which now substitutes a stub (SpClient.pm:1438-1449) instead of dropping. New test "CR-01 getSavedAlbums partial-enrichment-failure" passes (full requested count returned, stub in failed slot). |
| 16 | collection/v2 PageResponse decoding returns ALL repeated items across pages (A1) — 75-04 | ✓ VERIFIED | **WR-03 closed**: `_collectionAll` now has `COLLECTION_MAX_PAGES => 100` hard cap (SpClient.pm:1354-1360) and a repeated-`next_page_token` end-of-list guard (SpClient.pm:1373-1384) that preserves already-accumulated data instead of looping forever. New test "WR-03: repeated-token loop terminates at or before COLLECTION_MAX_PAGES (100) page requests" passes. |
| 17 | getSavedTracks serves full Liked Songs via context-resolve, sliced/enriched — 75-04 | ✓ VERIFIED | **CR-01 closed**: `getSavedTracks` (SpClient.pm:1753-1794) consumes `_enrichTracks`→`_enrichMeta` — stub substitution confirmed by direct code read; no per-item drop remains. |
| 18 | getRecentlyPlayed decodes protobuf-only recently-played/v3 (S-09) — 75-04 | ✓ VERIFIED | Unchanged. Its own inline enrichment loop was deliberately NOT touched by 75-07 (no offset-based pagination caller — Plugin.pm calls it once per menu open with a fixed limit, documented in 75-07-SUMMARY's Decisions Made) — correctly out of CR-01's scope. |
| 19 | All collection paths use credentials.json username, never prefs spotifyUserId — 75-04 | ✓ VERIFIED | Unchanged |
| 20 | getUserPlaylists serves rootlist protobuf-only (S-10), Web-API-shaped — 75-05 | ✓ VERIFIED | Unchanged, out of 75-07's file scope (rootlist parsing untouched) |
| 21 | getPlaylistItems serves playlist/v2 tracks with sliced enrichment matching `_playlistFeed` item shape — 75-05 | ✓ VERIFIED | **CR-01 closed (the headline case)**: `getPlaylistItems` (SpClient.pm:2209-2222) now filters `@contentItems`'s URIs to `spotify:track:`-prefixed entries BEFORE calling `_sliceAsPage`, and derives `$total` from the filtered list's count — `total` and `items` now always agree, restoring the offset-advance-by-returned-count invariant every caller depends on. New tests "CR-01 mixed-content: total reflects the 3 filtered track URIs, NOT the raw envelope length (5)" and "CR-01 chaining: zero duplicate tracks across the chained windows" both pass — the second explicitly simulates the real `_fetchPages`/`explodePlaylist` sequential-call pattern. |
| 22 | Both getUserPlaylists/getPlaylistItems honor D-06/D-07 — 75-05 | ✓ VERIFIED | Unchanged; **WR-04 closed** additionally: `getPlaylistItems` now validates `$playlistId =~ /^[0-9A-Za-z]{22}$/` (SpClient.pm:2189-2192) before any D-06/D-07 network path is reached, before `_playlistEnvelope` ever splices it into the URL/cache key. |
| 23 | Every Browse/Search/Library call in Plugin.pm/ProtocolHandler.pm/Connect.pm/DontStopTheMusic.pm goes through SpClient (D-08) — 75-06 | ✓ VERIFIED | Unchanged; re-confirmed live: Plugin.pm's only remaining `API::Client->` calls are `reset`/`limitsProbed`/`probeEndpointLimits`; ProtocolHandler.pm and DontStopTheMusic.pm have zero |
| 24 | Player-control calls in Connect.pm stay on Client.pm (D-08) — 75-06 | ✓ VERIFIED | Unchanged; re-confirmed live: exactly the 4 player-control methods (`playerPause`/`playerPlay`/`playerVolume`/`playerSeek`) |
| 25 | Library write/contains ops reach Web API via SpClient passthrough delegations — 75-06 | ✓ VERIFIED | Unchanged surface + **WR-02 closed**: `saveTracks`/`removeTracks` now invalidate `spoton_spclient_liked_${accountId}` (SpClient.pm:2299/2307); `saveShows`/`removeShows` now invalidate `spoton_spclient_coll_${accountId}_show` (SpClient.pm:2324/2332) before delegating to Client.pm — a Like/Follow is now visible on the very next fetch instead of staying stale up to 60s. `checkTracks`/`checkShows` correctly left untouched (read-only). |
| 26 | initPlugin resets SpClient and Login5 state (plugin-reload safety) — 75-06 | ✓ VERIFIED | Unchanged; `Plugin.pm:161`/`:162` |
| 27 | Standalone smoke script exists for UAT — 75-06 | ✓ VERIFIED | Unchanged; `tools/spclient-smoke.pl` exists, `perl -c` clean |

Additionally, **WR-02's second half** — `getSavedShows` honoring `params._noCache` — is verified directly: `getSavedShows` (SpClient.pm:1607-1684) now passes `$params->{_noCache}` as `_collectionAll`'s 5th argument (SpClient.pm:1684), and `_collectionAll` (SpClient.pm:1337-1346) skips only the initial cache read when that argument is true, still writing the refreshed result back. New tests "WR-02 _noCache: second _noCache=>1 call issues a SECOND collection/v2 POST" and "WR-02 write-invalidation: getSavedShows after saveShows issues a FRESH collection/v2 POST" both pass.

**Score:** 27/27 truths verified. Zero remaining FAILED or Degraded truths. Zero regressions in the 20 previously-clean truths (confirmed via `git diff --stat` showing only `SpClient.pm`/`t/36_spclient.t` touched, and `Client.pm` byte-identical across all three 75-07 task commits).

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Plugins/SpotOn/API/ProtobufLite.pm` | Pure-Perl wire codec | ✓ VERIFIED | Untouched by 75-07 |
| `Plugins/SpotOn/API/Login5.pm` | Bearer-token minting | ✓ VERIFIED | Untouched by 75-07 |
| `Plugins/SpotOn/API/SpClient.pm` | spclient HTTP layer + full facade surface | ✓ VERIFIED | 2361 lines (up from 2245 pre-gap-closure); all paginated facades now preserve the requested-window-size invariant; CR-01/WR-01..04 all closed and confirmed by direct code read |
| `t/34_protobuf_lite.t` / `t/35_login5.t` / `t/36_spclient.t` / `t/05_perl_syntax.t` | Test coverage | ✓ VERIFIED | `t/36_spclient.t` grew from 233 to 270 tests (37 new regression tests covering CR-01/WR-01..04); live-run confirms `Files=1, Tests=270, PASS` for `t/36` alone |
| `spoton-helper/src/main.rs` (D-02) | patch+check only | ✓ VERIFIED | Untouched by 75-07 |
| `spoton-helper/proto/README.md` | Documentation-only notice | ✓ VERIFIED | Untouched |
| `tools/spclient-smoke.pl` | LMS-free UAT script | ✓ VERIFIED | Untouched, exists, `perl -c` clean |
| `CHANGELOG.md` Unreleased entry | Documents unification | ✓ VERIFIED | `grep -qi spclient CHANGELOG.md` true |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| Plugin.pm (all data/library calls incl. `_doLibraryAction`) | SpClient.pm | `API::SpClient->` | ✓ WIRED | Unchanged, re-confirmed live |
| Connect.pm (`_fetchTrackMetadata`) | SpClient.pm | `getTrack` | ✓ WIRED | Unchanged; player-control calls correctly excluded |
| ProtocolHandler.pm / DontStopTheMusic.pm | SpClient.pm | all data calls | ✓ WIRED | Unchanged, zero remaining `API::Client->` calls |
| SpClient.pm | Login5.pm | `Login5->getToken` | ✓ WIRED | Unchanged |
| SpClient.pm | Client.pm | D-06/D-07 fallback delegation | ✓ WIRED | Unchanged; `Client.pm` confirmed byte-identical (`git diff --stat` empty across all 3 gap-closure commits) |
| getPlaylistItems / getSavedTracks / getShowEpisodes / getSavedAlbums / getSavedShows | pagination contract consumed by Plugin.pm `_fetchPages` / ProtocolHandler.pm `explodePlaylist` | offset advance by returned-item-count | **✓ WIRED (previously NOT WIRED CORRECTLY)** | **CR-01 closed.** Direct code read confirms `total`/`items` agreement in `getPlaylistItems`; stub substitution in `_enrichMeta`/`_enrichCollectionSlice` confirms every paginated facade's returned count always equals the requested window size. New "CR-01 chaining" test explicitly simulates the `_fetchPages`/`explodePlaylist` sequential-offset-advance pattern against a mixed-content fixture and asserts zero duplicate tracks and zero premature termination. |
| Plugin.pm:2088 (`getSavedShows _noCache=>1`) | SpClient::_collectionAll | 5th positional `$noCache` arg | ✓ WIRED (new) | `getSavedShows` passes `$params->{_noCache}` through; `_collectionAll` honors it as a bypass-on-demand |
| saveTracks/removeTracks/saveShows/removeShows | spclient list cache invalidation | `$cache->remove(...)` before Client.pm delegation | ✓ WIRED (new) | Confirmed present for all 4 passthroughs; `checkTracks`/`checkShows` correctly left untouched |

### Data-Flow Trace (Level 4)

`getPlaylistItems`'s `total` value: previously sourced from `$envelope->{length}` (raw, unfiltered
envelope field) — now sourced from `_sliceAsPage`'s return value fed the track-URI-filtered list
(`SpClient.pm:2220-2221`). Confirmed by direct read: `my @trackUris = grep { /^spotify:track:/ }
@uris; my ($sliceUris, $total) = $class->_sliceAsPage(\@trackUris, $offset, $limit);` — `$total`
now flows from the same filtered array that produces `items`, closing the desync. ✓ FLOWING.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Phase-specific tests green (isolated) | `prove -l t/36_spclient.t` | `Files=1, Tests=270, PASS` | ✓ PASS |
| Full test suite green | `prove t/` | `Files=36, Tests=1685, PASS` (up from 1648 pre-gap-closure — 37 new tests, zero regressions) | ✓ PASS |
| CR-01 fix confirmed live | direct code read: `SpClient.pm:2209-2236` (`getPlaylistItems`), `:631-677` (`_enrichMeta`), `:1421-1454` (`_enrichCollectionSlice`) | filter-before-slice + recount present; stub substitution present in both enrichment helpers | ✓ PASS |
| WR-01 fix confirmed live | direct code read: `SpClient.pm:796-810` (`getAlbumTracks`), `:938-953` (`getArtistAlbums`), `:1063-1078` (`getShowEpisodes`) | all three guard `unless ($meta && ref($meta) eq 'HASH')` before dereference, routing through a named `$fallback` | ✓ PASS |
| WR-02 fix confirmed live | direct code read: `SpClient.pm:1607-1684` (`getSavedShows`), `:1337-1346` (`_collectionAll` noCache), `:2292-2341` (write passthroughs) | `_noCache` passed through; 4 write passthroughs invalidate their list cache key | ✓ PASS |
| WR-03 fix confirmed live | direct code read: `SpClient.pm:1354-1384` (`_collectionAll`) | `COLLECTION_MAX_PAGES` cap + repeated-token guard present, both preserve accumulated data | ✓ PASS |
| WR-04 fix confirmed live | direct code read: `SpClient.pm:2189-2192` | 22-char base62 regex guard present before `_playlistEnvelope` call | ✓ PASS |
| `Client.pm` byte-identical across gap-closure commits | `git diff --stat c361d7c..HEAD -- Plugins/SpotOn/API/Client.pm` | empty output | ✓ PASS |
| Commits exist | `git cat-file -e e65107e / 5d6ad3c / 4b31973` | all resolve | ✓ PASS |

### Requirements Coverage

Same tracking convention as the initial verification: Phase 75's requirement IDs (D-01..D-09) are
decisions recorded in `75-CONTEXT.md`, not `.planning/REQUIREMENTS.md` (confirmed unchanged — that
file still only has an unrelated Phase 53 cross-reference for "D-0").

| Requirement | Declared in plans | Status | Evidence |
|---|---|---|---|
| D-01 (ProtobufLite generic decoder) | 75-01, 75-04, 75-05 | ✓ SATISFIED | Unchanged |
| D-02 (remove Rust protobuf subcommand) | 75-03 | ✓ SATISFIED | Unchanged |
| D-03 (SpClient standalone, no coupling to Client.pm) | 75-01 | ✓ SATISFIED | Unchanged; re-confirmed `Client.pm` byte-identical through 75-07 too |
| D-04 (Login5.pm token minting) | 75-01 | ✓ SATISFIED | Unchanged |
| D-05 (HTTPUtil.pm — optional) | not declared, conditional | ✓ SATISFIED (conditionally not triggered) | Unchanged from initial verification's finding |
| D-06 (capability-based routing) | 75-01, 75-02, 75-04, 75-05, 75-06 | ✓ SATISFIED | Unchanged, plus WR-04's new validation sits correctly BEFORE the D-06 network path in `getPlaylistItems` |
| D-07 (automatic fallback on spclient error) | 75-01, 75-02, 75-04, 75-05, 75-07 | ✓ SATISFIED — gap closed | Previously "mechanism satisfied, interacts with CR-01 as a silent-partial-success blind spot." Now: CR-01 no longer produces a silent partial success — window size is always exact, so the case that previously slipped past D-07's fallback net no longer occurs. WR-01 also strengthens D-07: three more normalize closures now route empty/malformed bodies through the same fallback instead of dying. |
| D-08 (full call-site unification) | 75-02, 75-04, 75-05, 75-06, 75-07 | ✓ SATISFIED — gap closed | Previously "mechanically satisfied, gap in data-correctness (CR-01)." Now: all ~70 call sites switched AND the facade's paginated methods are genuinely Client.pm-behavior-equivalent under mixed-content/partial-failure conditions — the condition that broke behavioral equivalence is closed. |
| D-09 (rate-pool awareness / burst avoidance) | 75-01, 75-02, 75-04, 75-05, 75-07 | ✓ SATISFIED — gap closed | Previously "satisfied with a related-but-distinct latent risk (WR-03's unbounded loop)." Now: `_collectionAll` is hard-bounded (`COLLECTION_MAX_PAGES`), closing the last unbounded-request-burst risk in this phase's scope. |

No orphaned requirements: all nine D-0X decisions accounted for across the seven plans (six
original + gap closure).

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Plugins/SpotOn/API/SpClient.pm` | 1418-1419 | Stale docstring: `_enrichCollectionSlice`'s comment still reads "Failed/undef normalizations are dropped" — the code below it (lines 1438-1449) was correctly updated to stub-substitute, but the prose comment was not updated to match | ℹ️ Info | Purely cosmetic — could mislead a future reader of the docstring alone; does not affect behavior (verified: the code, not the comment, is what runs) |
| `Plugins/SpotOn/API/SpClient.pm` | 1223 | `search()`'s offset comparison uses the raw context-resolve URI count (`scalar(@uris)`) rather than the track-filtered count (`scalar(@trackIds)`) | ℹ️ Info (logged, not blocking) | Narrow edge case (only matters if `page->{tracks}` ever contains a non-`spotify:track:`-prefixed entry, which the context-resolve `tracks` field is not expected to). Explicitly out of 75-07's Task 1 scope; logged as an open deviation in `.planning/WINDOWS.md` (#6) for a future pass, not silently dropped. |

No 🛑 Blocker or unreferenced debt markers (`TBD`/`FIXME`/`XXX`/`TODO`/`HACK`/`PLACEHOLDER`) found
in `Plugins/SpotOn/API/SpClient.pm` or `t/36_spclient.t`.

### Human Verification Required

None. Same conclusion as the initial verification: live login5/spclient round-trip against a real
paired account remains mandatory phase UAT (already correctly flagged by all seven SUMMARYs,
orthogonal to the code-level gaps this re-verification closes) — no paired account reachable in
this environment. All gaps closed by 75-07 were code-level defects confirmed by static reading and
new passing regression tests, not behavior requiring a live account to observe.

### Gaps Summary

All gaps from the initial `75-VERIFICATION.md` are closed:

- **CR-01 (critical, closed):** `getPlaylistItems` now filters to `spotify:track:` URIs before
  slicing and derives `total` from the filtered list, restoring the offset-advance-by-
  returned-count contract every caller depends on. The shared root cause (`_enrichMeta`/
  `_enrichCollectionSlice`'s `grep { defined }` drop pattern) is fixed via stub substitution,
  closing the same defect in `getAlbumTracks`, `getShowEpisodes`, `getSavedTracks`,
  `getSavedAlbums`, `getFollowedArtists`, and `search`.
- **WR-01 (closed):** `getAlbumTracks`/`getArtistAlbums`/`getShowEpisodes` no longer die inside the
  async HTTP success callback on an empty/malformed `metadata/4` body — all three now route
  through the same named Client.pm fallback used for hard errors.
- **WR-02 (closed):** `getSavedShows` honors `params._noCache`; the four library write
  passthroughs invalidate their corresponding spclient list cache key before delegating.
- **WR-03 (closed):** `_collectionAll`'s pagination loop is bounded by `COLLECTION_MAX_PAGES`
  (100) and a repeated-`next_page_token` guard.
- **WR-04 (closed):** `getPlaylistItems` validates `$playlistId` (22-char base62) before it is
  ever spliced into the spclient URL path or cache key.

All fixes are backed by 37 new passing regression tests in `t/36_spclient.t` (grown from 233 to
270 tests), and the full workspace suite is green at 1685 tests (up from 1648), with zero
regressions. `Client.pm` remains confirmed byte-identical across all three gap-closure commits,
preserving the phase's D-03 no-coupling guarantee.

One residual, explicitly out-of-scope item (`search()`'s narrow offset-vs-uri-count edge case) was
surfaced during 75-07's own execution, is correctly NOT part of the original CR-01/WR-01..04 gap
set this phase's own code review flagged, and was honestly logged as an open deviation in
`.planning/WINDOWS.md` (#6) rather than silently fixed or silently ignored. It is informational
only and does not block phase 75 closure.

The phase goal — build the spclient API layer and switch all browse/search/library call sites to
the SpClient facade with D-06/D-07 routing — is now fully achieved with no remaining unresolved
finding from `75-REVIEW.md`.

---

_Verified: 2026-08-29_
_Verifier: Claude (gsd-verifier)_
