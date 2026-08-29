---
phase: 75-api-unification-spclient-modell
verified: 2026-08-29T09:39:00Z
status: gaps_found
score: 20/23 must-haves verified
behavior_unverified: 0
overrides_applied: 0
gaps:
  - truth: "SpClient->getPlaylistItems serves playlist tracks from playlist/v2 (JSON via Accept header) with sliced track enrichment, matching the _playlistFeed item shape (75-05)"
    status: failed
    reason: >
      Confirmed unresolved CRITICAL finding from the phase's own 75-REVIEW.md (CR-01), verified
      directly against the shipped code: getPlaylistItems (SpClient.pm:2113-2118) reports
      `total => $envelope->{length}` (ALL playlist entries, including non-track episodes/local
      files) while the returned `items` array is filtered to `spotify:track:` URIs only
      (line 2121) and additionally silently drops any track whose per-track metadata enrichment
      fails (`_enrichMeta`/`_enrichTracks`, SpClient.pm:648-650, `grep { defined } @results`).
      Every caller that consumes this facade (Plugin.pm `_fetchPages` at line 1912, `_albumFeed`
      play-all at line 3278, ProtocolHandler.pm `explodePlaylist` at lines 843/891) advances its
      next-page offset by the COUNT of items actually returned, not by the requested window size.
      When a window's real item count differs from the requested slice size (mixed-content
      playlists, or any per-item metadata fetch failure — the designed degraded-mode path under
      429s/timeouts) the caller's next request overlaps the previous window (duplicate tracks in
      exploded playlists / play-all queues) or, if an entire window is non-track/failed, returns
      `items => []` while `total` still claims more remain, causing `_fetchPages`'s T-25-01 guard
      and `explodePlaylist`'s truthiness check to terminate early (silent playlist truncation).
      This is not a theoretical edge case: mixed track/episode/local-file playlists and individual
      429/timeout enrichment failures are exactly the conditions the phase's own threat model
      (T-75-08, T-75-13) explicitly designed the code to tolerate — tolerating them by dropping
      items is what breaks the offset contract. No `t/36_spclient.t` regression test exercises a
      mixed-content or partial-enrichment-failure window, so the full test suite (1648/1648 green)
      does not catch this.
    artifacts:
      - path: "Plugins/SpotOn/API/SpClient.pm"
        issue: >
          getPlaylistItems (:2090-2131): total derived from unfiltered envelope length while
          items are filtered post-slice. getShowEpisodes (:1016-1052), getSavedTracks
          (~:1690-1711 via _enrichTracks), getSavedAlbums/getSavedShows (via
          _enrichCollectionSlice :1346-1369), and search's track-offset path (~:1188 vs :1194)
          share the identical `grep { defined }` truncation-without-recount pattern in
          _enrichMeta/_enrichCollectionSlice.
    missing:
      - "Filter to track-only URIs (or drop failed enrichments) BEFORE slicing, and derive `total` from the filtered/eligible list so window arithmetic and `total` stay consistent — per 75-REVIEW.md CR-01's proposed fix."
      - "OR: substitute a minimal id/uri-only stub for enrichment failures instead of dropping them, so page size always matches the requested window (also proposed in CR-01)."
      - "A t/36_spclient.t regression test with a mixed track/non-track URI window, and a partial-enrichment-failure window, asserting the returned item count matches the window and total/offset arithmetic never overlaps or skips."
      - "Resolution of the review's WR-02 (getSavedShows ignores _noCache, no write-path cache invalidation -- library lists stale up to 60s after Like/Follow), WR-03 (_collectionAll pagination loop has no page cap or repeated-token guard -- can loop forever on a malformed/adversarial next_page_token, contradicting the bounded-parse discipline applied everywhere else in this phase), and WR-04 (getPlaylistItems/_playlistEnvelope splice an unvalidated user-influenced $playlistId into the request URL and cache key, unlike every other facade's idToHex validation) -- all three remain open in 75-REVIEW.md with no follow-up commit.
deferred: []
coincidental_reliance_items: []
---

# Phase 75: API Unification (spclient-Modell) Verification Report

**Phase Goal:** Build spclient API layer (ProtobufLite, Login5, SpClient) and switch all browse/search/library call sites from Client.pm to the SpClient facade with D-06 capability routing and D-07 Client.pm fallback.
**Verified:** 2026-08-29T09:39:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

Must-haves merged from all six plans' frontmatter (no roadmap Success Criteria block exists for
Phase 75 in ROADMAP.md — this project's v4.0 milestone records phase requirements as D-01..D-09
decisions in `75-CONTEXT.md` rather than a `### Phase 75:` detail section, confirmed via
`gsd-tools query roadmap.get-phase 75` returning `malformed_roadmap`).

| # | Truth (source plan) | Status | Evidence |
|---|------|--------|----------|
| 1 | ProtobufLite decodes repeated CollectionItems into arrays, tolerates malformed input (D-01/A1) — 75-01 | ✓ VERIFIED | `t/34_protobuf_lite.t` green (17 tests); source: `parse_fields` uses `push` into arrayrefs (SpClient.pm/ProtobufLite.pm reviewed, confirmed by 75-REVIEW.md) |
| 2 | Login5 mints a full-length Bearer token from a 700+ byte LoginOk response (S-01) — 75-01 | ✓ VERIFIED | `t/35_login5.t` green (22 tests), asserts 438-char token survives multi-byte varint length |
| 3 | SpClient->getTrack routes via spclient for creds accounts, delegates to Client.pm otherwise (D-06) — 75-01 | ✓ VERIFIED | `t/36_spclient.t` green; router logic present and grep-confirmed |
| 4 | spclient 4xx/5xx falls back to Client.pm, single 401 remint-retry only (D-07/D-07a) — 75-01 | ✓ VERIFIED | `_isFallbackError`/`_retried401` present, tested in t/36 |
| 5 | spclient 429 uses its own rate-limit key, never `spoton_rate_limit` (D-03/D-09) — 75-01 | ✓ VERIFIED | `grep -c "spoton_spclient_rate_limit"` >=1, `grep 'spoton_rate_limit'` (excluding own key) = 0, confirmed live |
| 6 | getAlbum/getAlbumTracks Web-API-shaped with per-track enrichment (S-04) — 75-02 | ⚠️ Degraded (see gap) | Present, wired, tests pass — but `getAlbumTracks`'s enrichment path shares the `_enrichMeta` count-drop defect (CR-01-adjacent); not itself the CR-01 headline case but same root cause |
| 7 | getArtist/getArtistAlbums Web-API-shaped — 75-02 | ✓ VERIFIED | `t/36_spclient.t` green, normalizer fields confirmed by code read |
| 8 | getShow/getShowEpisodes/getEpisode attempt metadata/4, fall back on 4xx/5xx (D-07) — 75-02 | ⚠️ Degraded (see gap) | Router/fallback present and tested; `getShowEpisodes`'s slice/enrichment shares the same total-vs-returned-count desync as CR-01 |
| 9 | search type=track via context-resolve+enrichment; multi-type delegates (S-05) — 75-02 | ✓ VERIFIED | 4 routing tests pass in t/36; delegation confirmed |
| 10 | Enrichment reuses 3600s cache, no duplicate calls (D-09) — 75-02 | ✓ VERIFIED | Cache-reuse test in t/36 passes |
| 11 | spoton-helper builds/tests green with only patch+check (D-02) — 75-03 | ✓ VERIFIED | `cargo build && cargo test` green, `cargo run -- --help` lists exactly patch/check (live-verified) |
| 12 | protobuf/protobuf-codegen crates gone from dependency tree — 75-03 | ✓ VERIFIED | `cargo tree | grep protobuf` empty (live-verified) |
| 13 | `spoton-helper check` unchanged D-08 capability JSON (t/26 green) — 75-03 | ✓ VERIFIED | `prove -l t/26_soloist_check.t` part of full green suite |
| 14 | Vendored .proto files remain with README — 75-03 | ✓ VERIFIED | `spoton-helper/proto/README.md` exists (38 lines), 12 .proto files present |
| 15 | getSavedAlbums/getFollowedArtists/getSavedShows via collection/v2 with exact CT + verified set names (S-06/S-07) — 75-04 | ⚠️ Degraded (see gap) | Wire-level CT/body tests pass; `getSavedAlbums`/`getSavedShows` enrichment via `_enrichCollectionSlice` shares the CR-01 count-drop pattern |
| 16 | collection/v2 PageResponse decoding returns ALL repeated items across pages (A1) — 75-04 | ✓ VERIFIED (with WR-03 caveat) | 2-page fixture proves 4 items surface; however `_collectionAll`'s pagination loop (SpClient.pm:1287-1321) has no page cap or repeated-token guard (WR-03, unresolved) — a malformed/adversarial `next_page_token` loops forever, contradicting this phase's own bounded-parse discipline (varint cap, ROOTLIST_MAX_DEPTH) |
| 17 | getSavedTracks serves full Liked Songs via context-resolve, sliced/enriched — 75-04 | ✗ FAILED | Same `_enrichTracks`→`_enrichMeta` drop pattern as CR-01; a 429/timeout on any per-track fetch inside the slice silently shrinks the returned page below the requested window with no compensating recount |
| 18 | getRecentlyPlayed decodes protobuf-only recently-played/v3 (S-09) — 75-04 | ✓ VERIFIED | 3-context fixture (2 track + 1 playlist) test passes, multi-byte varint decode confirmed |
| 19 | All collection paths use credentials.json username, never prefs spotifyUserId — 75-04 | ✓ VERIFIED | A5 regression test passes in t/36 |
| 20 | getUserPlaylists serves rootlist protobuf-only (S-10), Web-API-shaped — 75-05 | ✓ VERIFIED | Nested-folder fixture (3 playlists across 1 nesting level) surfaces correctly; depth guard (ROOTLIST_MAX_DEPTH=10) present |
| 21 | getPlaylistItems serves playlist/v2 tracks with sliced enrichment matching `_playlistFeed` item shape — 75-05 | ✗ FAILED | **CR-01 (critical, unresolved in 75-REVIEW.md)** — confirmed live against SpClient.pm:2113-2131: `total` from unfiltered envelope length, `items` filtered to track-only + enrichment-failure-tolerant, no recount. Breaks the offset-advancement invariant every caller (Plugin.pm `_fetchPages`/`_albumFeed` play-all, ProtocolHandler.pm `explodePlaylist`) depends on -- causes duplicate tracks or silent playlist truncation under realistic conditions (mixed-content playlists, individual metadata-fetch failures) |
| 22 | Both getUserPlaylists/getPlaylistItems honor D-06/D-07 — 75-05 | ✓ VERIFIED | Router regression tests pass for both |
| 23 | Every Browse/Search/Library call in Plugin.pm/ProtocolHandler.pm/Connect.pm/DontStopTheMusic.pm goes through SpClient, incl. `_doLibraryAction` dynamic dispatch (D-08) — 75-06 | ✓ VERIFIED | Live-verified: exact-string equality gates re-run — Plugin.pm's only remaining `API::Client->` calls are `limitsProbed`/`probeEndpointLimits`/`reset`; ProtocolHandler.pm and DontStopTheMusic.pm have zero; `API::SpClient->$apiMethod` present at Plugin.pm:932, legacy form absent |
| 24 | Player-control calls in Connect.pm stay on Client.pm (D-08) — 75-06 | ✓ VERIFIED | Live-verified: Connect.pm's only remaining `API::Client->` calls are exactly the 4 player-control methods |
| 25 | Library write/contains ops reach Web API via SpClient passthrough delegations — 75-06 | ✓ VERIFIED | All 13 passthrough subs confirmed present by grep (`getLimit`, `getMe`, `getTopTracks`, `getPersonalMixes`, `saveTracks`, `removeTracks`, `checkTracks`, `saveShows`, `removeShows`, `checkShows`, `addToPlaylist`, `getWebPlayerPlaylistItems`, `pathfinderHome`) |
| 26 | initPlugin resets SpClient and Login5 state (plugin-reload safety) — 75-06 | ✓ VERIFIED | Live-verified: `Plugin.pm:161` `SpClient->reset()`, `:162` `Login5->reset()`, alongside `:158` `Client->reset()` |
| 27 | Standalone smoke script exists for UAT — 75-06 | ✓ VERIFIED | `tools/spclient-smoke.pl` exists (299 lines), `perl -c` clean, no LMS deps (per SUMMARY + spot-check) |

**Score:** 20/27 truths cleanly verified; 3 explicitly FAILED (getSavedTracks, getPlaylistItems, and the systemic pagination-count-desync root cause); 4 flagged "Degraded" (share the same root-cause defect but are lower-severity / less-triggered instances of it). Rolling these into distinct-blocking-truths per the phase's D-08 unification concern: **3 hard FAILED, 24 VERIFIED** for the frontmatter `gaps` count purposes (the 4 "Degraded" truths are folded into the single grouped gap entry below since they share one root cause and one fix).

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Plugins/SpotOn/API/ProtobufLite.pm` | Pure-Perl wire codec | ✓ VERIFIED | 153 lines, `grep -c "Slim::"` = 0 (standalone-loadable, confirmed) |
| `Plugins/SpotOn/API/Login5.pm` | Bearer-token minting | ✓ VERIFIED | 242 lines, CID constant present, cache TTL from `expires_in` |
| `Plugins/SpotOn/API/SpClient.pm` | spclient HTTP layer + full facade surface | ✓ VERIFIED (existence/wiring), ⚠️ correctness gap in paged facades | 2245 lines; all 16 browse-data methods + 13 passthroughs present (grep-confirmed); pagination-count defect documented above |
| `t/34_protobuf_lite.t` / `t/35_login5.t` / `t/36_spclient.t` / `t/05_perl_syntax.t` | Test coverage | ✓ VERIFIED | All green, live-run: `Files=4, Tests=290, PASS` |
| `spoton-helper/src/main.rs` (D-02) | patch+check only | ✓ VERIFIED | `cargo run -- --help` confirms exactly `patch`/`check` |
| `spoton-helper/proto/README.md` | Documentation-only notice | ✓ VERIFIED | 38 lines, exists |
| `tools/spclient-smoke.pl` | LMS-free UAT script | ✓ VERIFIED | 299 lines, `perl -c` clean |
| `CHANGELOG.md` Unreleased entry | Documents unification | ✓ VERIFIED | `grep -qi spclient CHANGELOG.md` true |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| Plugin.pm (all data/library calls incl. `_doLibraryAction`) | SpClient.pm | `API::SpClient->` | ✓ WIRED | Live-verified equality gate |
| Connect.pm (`_fetchTrackMetadata`) | SpClient.pm | `getTrack` | ✓ WIRED | Live-verified; player-control calls correctly excluded |
| ProtocolHandler.pm / DontStopTheMusic.pm | SpClient.pm | all data calls | ✓ WIRED | Zero remaining `API::Client->` calls, live-verified |
| SpClient.pm | Login5.pm | `Login5->getToken` | ✓ WIRED | Runtime-require confirmed, no compile-time `use` |
| SpClient.pm | Client.pm | D-06/D-07 fallback delegation | ✓ WIRED | Runtime-require only; `git diff --stat` on Client.pm empty (confirmed live) |
| getPlaylistItems / getSavedTracks / getShowEpisodes / getSavedAlbums / getSavedShows | pagination contract consumed by Plugin.pm `_fetchPages` / ProtocolHandler.pm `explodePlaylist` | offset advance by returned-item-count | ✗ NOT WIRED CORRECTLY | Confirmed broken (CR-01) — see gap |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full test suite green | `prove t/` | `Files=36, Tests=1648, PASS` | ✓ PASS |
| Phase-specific tests green | `prove -l t/34 t/35 t/36 t/05` | `Files=4, Tests=290, PASS` | ✓ PASS |
| spoton-helper crate green, no protobuf dep | `cargo build && cargo test && cargo tree \| grep protobuf` | tests pass, grep empty | ✓ PASS |
| CR-01 pagination defect | direct code read at cited line numbers | confirmed present exactly as 75-REVIEW.md describes | ✗ FAIL (confirms unresolved gap, not a false alarm) |
| WR-03 unbounded collection pagination loop | direct code read `_collectionAll` (SpClient.pm:1287-1321) | no page cap, no repeated-token guard | ✗ FAIL (confirms unresolved gap) |

### Requirements Coverage

Phase 75's requirement IDs (D-01..D-09) are decisions recorded in `75-CONTEXT.md`, not
`.planning/REQUIREMENTS.md` (that file only covers the older v2.3 milestone; this project's v4.0
Soloist milestone tracks phase-level decisions in each phase's own CONTEXT.md — confirmed by
grepping REQUIREMENTS.md for "D-0" and finding only an unrelated Phase 53 cross-reference).

| Requirement | Declared in plans | Status | Evidence |
|---|---|---|---|
| D-01 (ProtobufLite generic decoder) | 75-01, 75-04, 75-05 | ✓ SATISFIED | t/34 green; repeated-field + malformed-input tests pass; recursion depth guard for rootlist present |
| D-02 (remove Rust protobuf subcommand) | 75-03 | ✓ SATISFIED | cargo tree clean, main.rs reduced, README added |
| D-03 (SpClient standalone, no coupling to Client.pm) | 75-01 | ✓ SATISFIED | `git diff --stat` empty for Client.pm/Credentials.pm/TokenManager.pm across the whole phase (live-verified) |
| D-04 (Login5.pm token minting) | 75-01 | ✓ SATISFIED | t/35 green, S-01 regression covered |
| D-05 (HTTPUtil.pm — optional) | not declared in any plan's `requirements:` field | ✓ SATISFIED (conditionally not triggered) | D-05's own text says "only introduce if literal 1:1 duplication occurs"; no HTTPUtil.pm was created and none of the 6 SUMMARYs claim one was needed — consistent with the decision's own default. Not an orphaned requirement: it is a conditional decision, not a mandatory deliverable, and phase task explicitly lists D-05 as a requirement ID to check — noting it here as satisfied-by-default rather than skipped. |
| D-06 (capability-based routing) | 75-01, 75-02, 75-04, 75-05, 75-06 | ✓ SATISFIED | Router logic present and tested on every facade |
| D-07 (automatic fallback on spclient error) | 75-01, 75-02, 75-04, 75-05 | ✓ SATISFIED (mechanism); ⚠️ interacts with CR-01 | Fallback triggers correctly on transport/HTTP errors; the CR-01 defect is a silent partial-success case that does NOT trigger fallback (by design — D-07 only fires on hard errors, not on "fewer items than expected"), which is exactly why it isn't caught by the D-07 safety net |
| D-08 (full call-site unification) | 75-02, 75-04, 75-05, 75-06 | ⚠️ SATISFIED mechanically, gap in data-correctness | All ~70 call sites switched (live-verified equality gates); however the facade's paginated methods are not truly Client.pm-behavior-equivalent under mixed-content/partial-failure conditions (CR-01) |
| D-09 (rate-pool awareness / burst avoidance) | 75-01, 75-02, 75-04, 75-05 | ✓ SATISFIED | Own rate key, cap-2 concurrency, cache reuse all tested; WR-03's unbounded loop is a related-but-distinct latent risk (not a rate-pool violation per se, but could produce an unbounded burst of collection/v2 requests) |

No orphaned requirements: all nine D-0X decisions are accounted for across the six plans.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Plugins/SpotOn/API/SpClient.pm` | 2113-2131 | Pagination total/returned-count desync (CR-01) | 🛑 Blocker | Duplicate tracks or silent playlist truncation in production playback/browse paths |
| `Plugins/SpotOn/API/SpClient.pm` | 630-651, 1346-1369 | `grep { defined }` silently drops items without recount (shared root cause of CR-01) | 🛑 Blocker (same issue) | Affects getAlbumTracks, getShowEpisodes, getSavedTracks, getSavedAlbums, getSavedShows, search |
| `Plugins/SpotOn/API/SpClient.pm` | 1287-1321 | Unbounded pagination loop, no page cap / repeated-token guard (WR-03) | ⚠️ Warning | Contradicts the phase's own bounded-parse discipline; DoS-adjacent if spclient misbehaves |
| `Plugins/SpotOn/API/SpClient.pm` | 1526-1553, 1287-1294, 1619-1623 | `_noCache` param silently ignored, no write-path cache invalidation (WR-02) | ⚠️ Warning | Library lists stale up to 60s after Like/Follow — behavior regression vs. Client.pm |
| `Plugins/SpotOn/API/SpClient.pm` | 2050, 2056 | Unvalidated `$playlistId` spliced into URL/cache key (WR-04) | ⚠️ Warning | Potential path-injection / cache-key pollution from user-influenced input |
| `Plugins/SpotOn/API/SpClient.pm` | 788, 925, 1041 | Unguarded `$meta` deref on empty-body success response (WR-01) | ⚠️ Warning | Dies inside async HTTP callback with no D-07 fallback triggered — request hangs |

All six items above are documented, unresolved findings from the phase's own `75-REVIEW.md`
(committed as `10285f9`, dated after all six plan SUMMARYs). No commit after `10285f9` addresses
any of them — this verifier independently re-confirmed the critical (CR-01) and the two most
severe warnings (WR-02, WR-03) by reading the cited line ranges directly.

### Human Verification Required

None triggered by this verification's own analysis beyond what the phase's plans already
correctly flagged as mandatory live UAT (login5/spclient round-trip against a real paired
account — no paired account reachable in this environment, consistent across all six SUMMARYs).
That UAT need is orthogonal to the gaps below, which are code-level defects confirmed by static
reading, not behavior needing a live account to observe.

### Gaps Summary

The phase's mechanical objective — build the three new API modules and switch ~70 call sites from
Client.pm to the SpClient facade with D-06/D-07 routing — is genuinely done, and the SUMMARY
claims about file existence, test counts, and grep-gate equality checks were independently
re-verified and hold up. `Client.pm`/`Credentials.pm`/`TokenManager.pm` are confirmed
byte-identical, D-02's Rust removal is confirmed clean, and the full 1648-test suite is
confirmed green.

However, the phase's own code-review step (executed and committed as part of this same phase,
`75-REVIEW.md`) found a **critical, unfixed defect (CR-01)**: SpClient's paginated facades
(most severely `getPlaylistItems`, but the same root cause — `grep { defined }` dropping items
without recounting `total`/the window — also reaches `getAlbumTracks`, `getShowEpisodes`,
`getSavedTracks`, `getSavedAlbums`, `getSavedShows`, and `search`) do not preserve the
offset-window invariant that every caller (`Plugin.pm _fetchPages`/`_albumFeed` play-all,
`ProtocolHandler.pm explodePlaylist`) depends on. Under realistic, designed-for conditions
(mixed-content playlists; individual `metadata/4` fetch failures under load/429s — exactly the
degraded mode D-07/D-09's threat model calls for) this produces **duplicate tracks or silently
truncated playlists** in the live playback/browse path. No test in `t/36_spclient.t` exercises
this condition, so the green test suite does not surface it — the code review did, and it was
never followed up.

Three further unresolved warnings (WR-02 stale library lists after write, WR-03 unbounded
collection pagination loop, WR-04 unvalidated playlist ID in URL/cache key) compound the risk
picture but are not independently blocking beyond CR-01.

Since `must_haves.truths` in 75-02 ("Every facade method preserves the cb->($result) contract
so 75-06 call-site switching needs no caller changes") and 75-05 ("matching the _playlistFeed
item shape") both implicitly assert Client.pm-behavioral-equivalence, and CR-01 demonstrates
that equivalence does not hold under conditions the phase's own threat model designed for,
this is scored as a genuine gap, not a deferred/future-phase concern — it lives entirely within
Phase 75's own delivered code and its own code-review found it.

**This looks like an oversight, not an intentional deviation** — no VERIFICATION.md override is
suggested; the fix (filter-before-slice + recount, per 75-REVIEW.md's own proposed patch) is
small, scoped, and the review already wrote it. Recommend routing this to a phase 75 closure
plan (`/gsd-plan-phase --gaps`) rather than deferring to Phase 76/77.

---

_Verified: 2026-08-29T09:39:00Z_
_Verifier: Claude (gsd-verifier)_
