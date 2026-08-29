---
phase: 75-api-unification-spclient-modell
reviewed: 2026-08-29T09:33:08Z
depth: standard
files_reviewed: 20
files_reviewed_list:
  - Plugins/SpotOn/API/ProtobufLite.pm
  - Plugins/SpotOn/API/Login5.pm
  - Plugins/SpotOn/API/SpClient.pm
  - Plugins/SpotOn/Plugin.pm
  - Plugins/SpotOn/ProtocolHandler.pm
  - Plugins/SpotOn/Connect.pm
  - Plugins/SpotOn/DontStopTheMusic.pm
  - t/34_protobuf_lite.t
  - t/35_login5.t
  - t/36_spclient.t
  - t/05_perl_syntax.t
  - t/11_track_history.t
  - t/14_context_menu.t
  - t/15_streaming_mode.t
  - tools/spclient-smoke.pl
  - spoton-helper/src/main.rs
  - spoton-helper/Cargo.toml
  - spoton-helper/Cargo.lock
  - spoton-helper/proto/README.md
  - CHANGELOG.md
findings:
  critical: 1
  warning: 4
  info: 9
  total: 14
status: issues_found
---

# Phase 75: Code Review Report

**Reviewed:** 2026-08-29T09:33:08Z
**Depth:** standard
**Files Reviewed:** 20
**Status:** issues_found

## Summary

Reviewed the full Phase 75 spclient-unification surface: the three new API modules (ProtobufLite, Login5, SpClient), the four caller-switch consumers (Plugin, ProtocolHandler, Connect, DontStopTheMusic), the new/modified test files, the standalone smoke tool, and the trimmed Rust helper.

**Focus areas verified clean:**

- **Rate isolation (D-03/D-09):** SpClient uses its own `spoton_spclient_rate_limit` key and its own `$inflightCount` (cap 2). Never touches `spoton_rate_limit`. Covered by an explicit test (`t/36_spclient.t` block (e), lines 671-687).
- **No compile-time coupling (D-03):** SpClient.pm contains zero `use Plugins::SpotOn::API::Client` — Client.pm is runtime-`require`'d only inside fallback branches. Verified by grep.
- **D-07/D-07a fallback:** `_isFallbackError` classifies all 4xx/5xx plus local pre-flight reasons; exactly one 401 remint retry via `_retried401`, then fallback. Covered by test (`t/36` block (g), 2 HTTP attempts + 1 Client.pm fallback asserted).
- **Account isolation (CR-01 pattern):** All response/list/token cache keys include `$accountId` (`spoton_spclient_resp_`, `_coll_`, `_liked_`, `_rootlist_`, `_plenv_`, `spoton_login5_token_`). One dead-code exception noted as IN-02.
- **Protobuf safety (V5/T-75-02):** varint bounded at 10 bytes, all length-delimited reads bounds-checked, unknown wire types abort with `undef`, rootlist recursion capped at depth 10. Malformed-input tests present and passing.
- **Secret hygiene (T-75-01/T-75-19):** No token/username value is ever logged (masked via `_mask`); smoke tool passes the Bearer token via a 0600 curl `-K` config file and the request body via stdin — nothing secret in argv.
- **SimpleAsyncHTTP error signature:** the 3-arg `($http, $error, $response)` error callback and `$response->header('Retry-After')` usage match the LMS source (`ecb->($self, $error, $http->response)`) — verified against the installed `Slim/Networking/SimpleAsyncHTTP.pm`.
- **Windows compatibility:** pure-Perl modules, no `fork`/unix-only constructs; smoke tool uses list-form `IPC::Open3` + curl (present on Win10+), `chmod` is a no-op there.
- **Call-site switch completeness:** all browse/search/library reads in the four consumers now route through SpClient; remaining direct `API::Client` calls are player-control (`playerPause/Play/Volume/Seek`) and probe machinery — intentionally out of scope per plan 75-06.
- **Tests:** `t/34` (17), `t/35` (22), `t/36` (233) and the four modified suites all pass locally.

**Key concern:** the facades change an implicit pagination contract the callers depend on — SpClient pages can return fewer items than the consumed offset window, while every caller advances its offset by the *returned* item count. See CR-01.

## Critical Issues

### CR-01: Pagination offset desync — paged facades drop items from the window while callers advance offset by returned count (duplicates/truncation)

**File:** `Plugins/SpotOn/API/SpClient.pm:2113-2133` (getPlaylistItems), `:1038-1052` (getShowEpisodes), `:1554-1602` (getSavedShows), `:1697-1711` (getSavedTracks), `:649` (`_enrichMeta` drops failed items), plus callers `Plugins/SpotOn/Plugin.pm:1912` (`_fetchPages`: `$requestOffset = $startOffset + scalar(@accumulated)`), `Plugins/SpotOn/Plugin.pm:3278` (`_albumFeed` play-all: `$fetchPage->(scalar(@accumulated))`), `Plugins/SpotOn/ProtocolHandler.pm:843` and `:891` (explodePlaylist: `$fetchPage->($offset + scalar(@{ $data->{items} }))`).

**Issue:** With Client.pm, a page request for `offset/limit` always returned exactly the window's raw items, so advancing the next offset by the returned item count was sound. SpClient's paged facades break that invariant in two ways:

1. `getPlaylistItems` filters the sliced window down to `spotify:track:` URIs only (`@trackIds = map { /^spotify:track:(.+)$/ ? $1 : () } @$sliceUris`, line 2121) — playlist entries that are episodes or local files are silently consumed from the window but not returned. Meanwhile `total` is taken from the envelope's `length` field (line 2117-2118), which counts *all* entries.
2. Every enrichment path (`_enrichMeta` line 649, `_enrichCollectionSlice` line 1367, `getRecentlyPlayed` line 1811) drops failed/undef normalizations via `grep { defined }` — expected under 429s/timeouts on individual `metadata/4` fetches by design.

Consequence at the callers: when a page returns N < consumed-window items, the next request offset is `previous_offset + N`, so the next window overlaps the previous one → **duplicate tracks** in exploded playlists, play-all queues, and browse fills. Conversely, if a whole window's items are dropped (e.g. a run of 100 non-track playlist entries), the page returns `items => []`, and both `_fetchPages` (T-25-01 guard, Plugin.pm:1938) and explodePlaylist (`@{ $data->{items} }` false, ProtocolHandler.pm:842) terminate early → **the rest of the playlist is silently lost**. A related off-by-scope exists in `search` (SpClient.pm:1188 vs 1194): the offset guard counts all URIs but the slice indexes track-only IDs, shifting page boundaries when context-resolve returns non-track URIs.

This is incorrect behavior in the core playback/browse path under realistic conditions (mixed-content playlists are common; enrichment failures are the designed-for degraded mode), not a theoretical edge case.

**Fix:**
```perl
# getPlaylistItems: filter to track URIs BEFORE slicing, and derive total
# from the filtered list so window arithmetic and `total` agree:
my @trackUris = grep { /^spotify:track:/ } @uris;
my $total = scalar @trackUris;                 # not $envelope->{length}
my ($sliceUris) = $class->_sliceAsPage(\@trackUris, $offset, $limit);

# Enrichment failures: substitute a minimal stub derived from the source
# URI instead of dropping, so page size stays window-exact:
$finish->($err ? { id => $id, uri => "spotify:track:$id", name => undef }
               : $class->$normalizeMethod($result));
```
Apply the same filter-before-slice discipline to `getSavedTracks`/`getShowEpisodes`/`getSavedShows`, or alternatively change the callers to advance the offset by the *requested* window size when `total` has not been reached. Add a `t/36` regression: page of mixed track/episode URIs must not produce overlapping windows.

## Warnings

### WR-01: Unguarded `$meta` dereference in three `_spFacade` normalize closures — dies inside an async HTTP callback on an empty 200 body

**File:** `Plugins/SpotOn/API/SpClient.pm:788` (getAlbumTracks), `:925` (getArtistAlbums), `:1041` (getShowEpisodes)
**Issue:** `_doRequest`'s success handler leaves `$result` as `undef` when the response body is empty/whitespace (`$content =~ /\S/` false, line 350) and delivers it with **no error**. `_spFacade` then calls `$normalize->(undef, $cb)`. `_normalizeAlbum`/`_normalizeArtist`/`_normalizeShow` guard against undef, but these three closures dereference immediately: `@{ $meta->{disc} || [] }` (line 788), `$meta->{$groupKey}` (line 925), `@{ $meta->{episode} || [] }` (line 1041) — "Can't use an undefined value as a HASH reference" thrown from inside the SimpleAsyncHTTP success callback, after the H1 eval guard has already exited. The `$cb` is never invoked, so the browse request hangs with no D-07 fallback.
**Fix:**
```perl
sub {
    my ($meta, $fcb) = @_;
    unless ($meta && ref($meta) eq 'HASH') {
        $fcb->(undef, { error => 'parse_error' });   # fallback-classified
        return;
    }
    ...
```
(or normalize `$meta //= {}` at the top of each closure).

### WR-02: `_noCache` contract silently dropped and no write-path invalidation — library lists stale for up to 60s after Like/Follow

**File:** `Plugins/SpotOn/API/SpClient.pm:1526-1553` (getSavedShows ignores `$params->{_noCache}`), `:1287-1294` (`_collectionAll` always serves its 60s cache), `:1619-1623` (`_likedSongsUris` same); caller `Plugins/SpotOn/Plugin.pm:2088` explicitly passes `_noCache => 1`; `Plugins/SpotOn/API/Client.pm:541` honored it.
**Issue:** `_savedShowsFeed` deliberately requests fresh data (`{ %$params, _noCache => 1 }`) because Plugin.pm manages its own list caching. SpClient's `getSavedShows` never looks at `_noCache` — `_collectionAll` serves the `spoton_spclient_coll_${accountId}_show` cache unconditionally. Additionally, the write passthroughs (`saveTracks`/`removeTracks`/`saveShows`/`removeShows`, lines 2191-2225) delegate to Client.pm without invalidating `spoton_spclient_coll_*` / `spoton_spclient_liked_*`. Net effect: a user follows/unfollows a show or likes/unlikes a track and the Saved Shows / Liked Songs list does not reflect it for up to 60s — a behavior regression versus the Client.pm path the caller was written against.
**Fix:** Honor `_noCache` in `getSavedShows`/`getSavedTracks` (bypass and refresh the list cache), and/or have the write passthroughs remove the affected list cache keys on success:
```perl
sub saveShows {
    my $class = shift;
    my ($accountId) = @_;
    $cache->remove("spoton_spclient_coll_${accountId}_" . SET_MAP->{shows});
    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client->saveShows(@_);
}
```

### WR-03: `_collectionAll` pagination loop is unbounded — a repeated non-empty `next_page_token` loops forever

**File:** `Plugins/SpotOn/API/SpClient.pm:1296-1321`
**Issue:** The recursive `$fetchPage` continues as long as the server returns a non-empty `next_page_token` (line 1311-1312). There is no page cap and no repeated-token detection. A buggy or adversarial spclient response that echoes the same token indefinitely produces an infinite HTTP request loop (throttled to cap-2 but never terminating, and never calling `$cb`). This contradicts the bounded-parse discipline applied everywhere else in this phase (varint cap, `ROOTLIST_MAX_DEPTH`, T-75-16/V5).
**Fix:**
```perl
use constant COLLECTION_MAX_PAGES => 100;   # 100 * 200 = 20k items
...
my $pages = 0;
$fetchPage = sub {
    my ($pageToken) = @_;
    if (++$pages > COLLECTION_MAX_PAGES) {
        undef $fetchPage;
        $cb->(undef, { error => 'parse_error' });   # fallback-classified
        return;
    }
    ...
```
(also abort if `$nextPageToken` equals the token just used).

### WR-04: `$playlistId` interpolated into the spclient URL path and cache key without validation

**File:** `Plugins/SpotOn/API/SpClient.pm:2056` (`playlist/v2/playlist/$playlistId`), `:2050` (cache key)
**Issue:** Every other facade validates its ID via `idToHex` (strict 22-char base62) before building a URL. `getPlaylistItems`/`_playlistEnvelope` splice the raw `$playlistId` into the request path. IDs normally originate from Spotify responses, but playlist IDs also arrive via user-editable sources (LMS favorites URLs, CLI `playlist play` args routed through `explodePlaylist` passthroughs and OPML params). A value containing `/`, `?`, or `..` redirects the authenticated Bearer request to an arbitrary spclient path and pollutes the account cache-key namespace. `explodePlaylist`'s own regex (`[A-Za-z0-9]+`) covers one entry point but not `_playlistFeed`'s passthrough path.
**Fix:**
```perl
unless (defined $playlistId && $playlistId =~ /^[0-9A-Za-z]{22}$/) {
    $cb->(undef, { error => 'invalid_id' });
    return;
}
```
at the top of `getPlaylistItems` (before the D-06 creds check delegates, so Client.pm still sees legacy-format IDs if any exist — if legacy non-22-char playlist IDs must be supported, delegate them to Client.pm instead of erroring).

## Info

### IN-01: `encode_field` length uses character semantics — non-ASCII strings would produce malformed protobuf

**File:** `Plugins/SpotOn/API/ProtobufLite.pm:56`, consumers `Login5.pm:132`, `SpClient.pm:1232`
**Issue:** `encode_varint(length $data)` counts characters, not bytes. `$username` comes from `from_json`-decoded JSON (Unicode strings); a non-ASCII username would yield a wrong length prefix and potentially a "Wide character" die at HTTP dispatch. Spotify canonical usernames are ASCII in practice, so this is latent.
**Fix:** `use Encode (); $data = Encode::encode_utf8($data) if utf8::is_utf8($data);` inside `encode_field` for wire type 2, or document the bytes-only contract and encode at the callers.

### IN-02: Dead fallback cache key in `_doRequest` omits accountId

**File:** `Plugins/SpotOn/API/SpClient.pm:362`
**Issue:** `my $cacheKey = $params->{_cacheKey} || "spoton_spclient_resp_$cleanPath";` — the fallback is unreachable today (`_request` always sets `_cacheKey` when caching is on), but if ever reached it would drop the account scoping that CR-01-pattern discipline requires.
**Fix:** Remove the fallback (`my $cacheKey = $params->{_cacheKey} or return` style) or include `$accountId` in it.

### IN-03: Login5's token cache key duplicated as a magic string in SpClient

**File:** `Plugins/SpotOn/API/SpClient.pm:396` vs `Plugins/SpotOn/API/Login5.pm:77/233`
**Issue:** The 401 handler removes `"spoton_login5_token_${accountId}"` by re-deriving Login5's private key format. A future rename in Login5 silently breaks the D-07a remint (retry would reuse the stale cached token, always hitting the second 401 and falling back).
**Fix:** Expose `Plugins::SpotOn::API::Login5->invalidate($accountId)` and call that instead.

### IN-04: Plugin.pm comment claims `Login5->reset()` clears the token cache — it only clears the in-flight queue

**File:** `Plugins/SpotOn/Plugin.pm:159-162`, `Plugins/SpotOn/API/Login5.pm:64-68`
**Issue:** The initPlugin comment says "reset ... Login5's token cache alongside Client.pm's reset"; `Login5::reset` only empties `%_mintInflight`. Cached tokens survive plugin reload (harmless — account-keyed and TTL'd — but the comment misleads future maintainers).
**Fix:** Correct the comment, or make `reset` also drop cached tokens if reload-freshness is actually desired.

### IN-05: apresolve host used unvalidated in URL construction

**File:** `Plugins/SpotOn/API/SpClient.pm:186-192`
**Issue:** The JSON `spclient[0]` value goes straight into `https://$host/$cleanPath` and is cached 1h. It arrives over TLS from Spotify, so risk is low, but a malformed value (containing `/`, `?`, `@`) would silently redirect all spclient traffic.
**Fix:** Accept only `^[A-Za-z0-9.-]+(?::\d+)?$`, else use `SPCLIENT_FALLBACK_HOST`.

### IN-06: Inconsistent facade pagination contract — `next` present in some responses, absent in others

**File:** `Plugins/SpotOn/API/SpClient.pm:1429/1708/2131` (present) vs `:1557/1586` (getSavedShows) and `:2030` (getUserPlaylists) (absent)
**Issue:** Current consumers use `total`, so nothing breaks, but the drop-in-replacement claim is weaker than stated; a future caller keying on `next` would behave differently per method.
**Fix:** Emit `next => (($offset + $limit) < $total) ? 1 : undef` uniformly.

### IN-07: Connect.pm reaches into SoloistDaemon's private `_ws` accessor

**File:** `Plugins/SpotOn/Connect.pm:38-48`
**Issue:** `_soloistConnectWs` returns `$helper->_ws` — an underscore-private method of another class. Works, but couples Connect.pm to SoloistDaemon internals.
**Fix:** Add a public `ws()` accessor (or `connectWs()`) on SoloistDaemon and call that.

### IN-08: DSTM field-filter queries (`artist:"X"`) now route through context-resolve, which is spike-unverified for filter syntax

**File:** `Plugins/SpotOn/DontStopTheMusic.pm:162-176`, `Plugins/SpotOn/API/SpClient.pm:1163`
**Issue:** Spike 009 verified plain-text context-resolve searches; whether `spotify:search:artist%3A%22name%22` honors the field filter is unverified. The failure modes are benign-ish: an empty result set falls back to Client.pm (offset 0 >= 0 uris), but a non-empty *unfiltered* result would silently degrade DSTM seed quality with no fallback signal.
**Fix:** Verify during live UAT (add an `artist:"..."` query to `tools/spclient-smoke.pl`); if unsupported, have `search()` delegate filtered queries (`$query =~ /\w+:/`) to Client.pm.

### IN-09: login5 Bearer token persisted in the shared on-disk spoton cache

**File:** `Plugins/SpotOn/API/Login5.pm:233-234`
**Issue:** The minted token is stored plaintext in `Slim::Utils::Cache` (spoton.db) with a server-derived TTL. This matches the established WebPlayer/TokenManager pattern and the token is short-lived, so this is a consistency note, not a new exposure — recorded so the decision is explicit.
**Fix:** None required; consider an in-memory-only token cache if the pattern is ever revisited project-wide.

---

_Reviewed: 2026-08-29T09:33:08Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
