# Changelog

All notable changes to SpotOn will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [3.5.7] - 2026-08-18

### Fixed
- **Concurrent Browse requests during a 429 window no longer show empty pages** — when one request triggers a 429, other Browse (GET) requests arriving during the Retry-After window are now deferred and retried automatically after the window closes (with jitter to prevent bursts), instead of returning an instant "No results" page with no log trace. Write requests (play/pause/seek/volume) keep fail-fast behavior. ([#155](https://github.com/stiefenm/spoton/issues/155))
- **Rate-limit short-circuits now visible in server.log** — upgraded from debug to info level across all three API pipelines, making the "invisible empty page" pattern diagnosable at normal log verbosity.
- **"Temporarily rate limited" message instead of "No results"** — when a request is rate-limited and cannot be deferred, the OPML menu now shows a localized explanation (11 languages) instead of the confusing generic "No results".

## [3.5.6] - 2026-08-18

### Fixed
- **Transparent auto-retry on 429 rate limits** — when Spotify returns a 429 with a short Retry-After (≤30s), SpotOn now waits and retries once automatically instead of showing an instant "no result" page. Covers all three API pipelines (Browse, Pathfinder Home, Web Player Playlists). A second consecutive 429 still fails fast as before. ([#155](https://github.com/stiefenm/spoton/issues/155))

## [3.5.5] - 2026-08-18

### Changed
- **Settings UX polish** — Client ID section is now the first item in Account Settings. Removed redundant nested details section (single wizard remains). Removed devmode quota warning and redundant Redirect URI hint from the auth section. "Default mode" relabeled to "bundled ID" in the remove link.
- **Re-authorization banner** — after changing the Client ID, a prominent orange banner appears at the top of Settings linking to the Connect Account section, matching the playback auth banner style.

## [3.5.4] - 2026-08-18

### Fixed
- **Client ID section moved to top of Account Settings** — the shared-quota warning and custom ID input are now the first item users see, instead of being buried below Pathfinder Hash.

## [3.5.3] - 2026-08-18

### Fixed
- **`/login` handler no longer returns 404** — the handler registration used a regex object as a hash key, which stringified to `(?^:^login$)` instead of matching `login`. Now uses a plain string key. ([D-01](https://github.com/stiefenm/spoton/issues/147))
- **Local rate-limit short-circuits now distinguishable from real 429s** — a single Spotify 429 no longer cascades into phantom 429s on unrelated endpoints. Local cache-based short-circuits are tagged as `rate_limited_local` with debug logging, making the Status page's 429 count accurate. ([#152](https://github.com/stiefenm/spoton/issues/152))
- **Classic Skin Settings page reloads after OAuth** — the PKCE success popup now redirects the opener tab back to Settings, so the connected account state is immediately visible without a manual page reload.

### Changed
- **Bundled Client ID skips startup limit probe** — SpotOn no longer sends 8 API requests to detect endpoint limits on every LMS restart when using the bundled Client ID. The limits are known constants for the shared ncspot Extended Quota app. Saves API quota across 138+ installations. The `force` re-probe option remains available.
- **Settings UX clearly communicates shared vs. private API quota** — bundled mode shows an amber shared-quota warning recommending a personal Client ID; custom mode shows a green private-quota confirmation. The Client ID input is now directly visible (not inside a collapsed section), and a re-authorization hint appears when accounts are already connected.
- **Client ID description reframed** — bundled mode is presented as "works out of the box but shared", custom mode as "recommended for the best experience" (previously: bundled as default, custom as "advanced").
- **i18n: 4 new + 3 reworded string keys** across all 11 languages (CS, DA, DE, EN, ES, FR, IT, NL, NO, PL, SV) with genuine translations.

### Added
- **TROUBLESHOOTING.md: rate-limit section** — explains the shared-bucket cause of frequent 429s and recommends creating a personal Spotify Developer App.

## [3.5.2] - 2026-08-17

### Fixed
- **Audio key timeout no longer drops the session** — librespot now retries audio key requests up to 2 times on timeout after AP reconnects, and fails the track cleanly instead of feeding encrypted bytes to the decoder. Previously, a single 1500ms timeout after an access-point reconnect would cause "continuing without decryption" → decoder failure → session drop. Binary rebuilt with patched librespot (`spoton v3.0.2`). ([#150](https://github.com/stiefenm/spoton/issues/150), upstream [librespot#1742](https://github.com/librespot-org/librespot/pull/1742))

## [3.5.1] - 2026-08-17

### Fixed
- **Health check no longer restarts daemon mid-playback on AP drops** — Signal 1 (`session_valid=false`) now defers daemon restart while actively playing (`idle_secs ≤ 30`). Transient Spotify access-point reconnects no longer kill active Connect sessions. ([#149](https://github.com/stiefenm/spoton/issues/149))
- **Audio key response timeout now detected by Auth Health** — `classifyAudioKeyError` recognizes client-side key timeouts after AP reconnects and surfaces them in the Status page. Previously these failures were invisible to all monitoring. ([#150](https://github.com/stiefenm/spoton/issues/150))

## [3.5.0] - 2026-08-16

### Added
- **Authorize Playback (ZeroConf pairing)** — a new "Authorize Playback" section in Settings lets you pair SpotOn with the Spotify app via mDNS discovery. Start pairing, then select the shown device in your Spotify app. This replaces the previous auto-derivation approach and is required once per account for playback and Spotify Connect. ([#147](https://github.com/stiefenm/spoton/issues/147))
- **Browser fallback for playback authorization** — for networks where the Spotify app can't discover SpotOn via mDNS (Docker, VLANs), a browser-based authorization flow is available as a nested option inside the Authorize Playback section.
- **Auth Health dashboard** — the Status page now shows "Web API Token" and "Playback Credentials" as separate rows with credential source (Spotify app pairing / browser authorization) and clear remediation guidance when either is missing.
- **Provenance migration** — existing accounts from pre-3.5 are automatically tagged with their credential source on first startup; no re-authorization needed.
- **`--get-token` mode restored in librespot binary** — the capability manifest now includes `get_token: true` for integrations that need Web API tokens from librespot.
- **OPML playback-auth hint** — when playback credentials are missing, the browse menu shows a non-blocking hint directing the user to SpotOn Settings instead of failing silently.

### Changed
- **Settings page reorganized into three sections** — Account (authorization, pairing, sp_dc, Pathfinder, Custom App), Global Settings, Diagnostics. The Custom Developer App control is always visible as a collapsed details element (no longer hidden behind a preference). ([#147](https://github.com/stiefenm/spoton/issues/147))
- **Two-step authorization model** — step 1 connects your Spotify account (Web API), step 2 authorizes playback via pairing. All UI text across 11 languages reflects this model. ([#147](https://github.com/stiefenm/spoton/issues/147))
- **Default PKCE identity switched to ncspot Extended Quota Client ID** — the previous default shared a global rate-limit bucket with all librespot and Spotify Desktop users, causing 429 errors. The new default has its own dedicated bucket. ([#147](https://github.com/stiefenm/spoton/issues/147))
- **Onboarding guide updated** — four steps: Connect Account, Authorize Playback, optional sp_dc cookie, optional Pathfinder hash. The Developer App step was removed (not needed for default mode).

### Fixed
- **429 rate limiting on /me and Web API calls** — eliminated by switching from the shared Keymaster Client ID to the ncspot Extended Quota ID with its own rate-limit bucket. ([#147](https://github.com/stiefenm/spoton/issues/147))
- **Credential crash-loop auto-derivation removed** — daemon credential crashes now escalate to a playback-auth flag with exponential backoff instead of silently re-deriving credentials in a loop. ([#147](https://github.com/stiefenm/spoton/issues/147))
- **Limit probe no longer competes with user requests after 429** — the endpoint limit detection now checks for active rate-limit state before firing and retries after 30s, preventing probe calls from extending a 429 window.
- **Pairing status poll no longer runs forever on server reset** — the polling JS now handles the `idle` state as a terminal condition, resetting the UI instead of polling indefinitely.
- **Browser fallback 30-minute cooldown cleared on fresh authorization** — a new OAuth round-trip now resets the derive rate limiter so users aren't stuck waiting after transient failures.
- **`/login` raw handler anchored** — the LMS raw function handler now uses an anchored regex (`qr{^login$}`) preventing it from hijacking unrelated URLs containing "login" in their path.
- **Pairing cleanup on plugin shutdown** — `cancelPairing()` is now called during `shutdownPlugin` to stop the mDNS helper and polling timer.

## [3.4.0] - 2026-08-08

### Added
- **Recent search history (last 50 entries, newest-first)** — the dedicated search page now shows a "New Search" input followed by previous queries, each with a context menu to delete a single entry or clear all history. History is stored, deduplicated, and capped at 50 entries. Contributed by @urknall in [PR #145](https://github.com/stiefenm/spoton/pull/145).

### Fixed
- **PCM double attenuation in Connect fallback mode** — the binary now uses a PassthroughMixer that tracks the Spotify volume slider and keeps VolumeChanged events flowing but never attenuates decoded samples; LMS/squeezelite is the single volume attenuator in every mode (previously ~-6 dB extra at LMS volume 50 in PCM mode). Credit the analysis by @urknall in [#143](https://github.com/stiefenm/spoton/issues/143). ([#144](https://github.com/stiefenm/spoton/issues/144))
- **Fixed-output players (Digital Volume Control off) and sync groups with a fixed-output master are now genuinely bit-perfect in PCM mode** — the broken `VolumeCtrl::Fixed` semantics of the previous volume path no longer apply. ([#144](https://github.com/stiefenm/spoton/issues/144))
- **Classic Skin split the SpotOn main menu into separate sections** — the top-level Search entry used `type => 'search'`, which Classic Skin interprets as a section break. It now uses `type => 'link'` and navigates to the dedicated search page, matching Spotty's two-step UX pattern. ([PR #145](https://github.com/stiefenm/spoton/pull/145))

### Changed
- **librespot dev-branch pin refreshed to `9c7d7561`** — descendant of the CDN-fallback fix ([librespot#1722](https://github.com/librespot-org/librespot/pull/1722)), which remains included.

## [3.3.5] - 2026-08-04

### Fixed
- **Spotify app volume slider showed arbitrary default for fixed-volume players** — the `fixed` branch now seeds `--initial-volume 100` so the slider starts at 100% instead of librespot's internal default. Note: the flag is 0–100 scale (u8), scaled to 0–65535 internally by the daemon. ([#137](https://github.com/stiefenm/spoton/issues/137))
- **Account switch toast in Material Skin showed raw HTML** — the confirmation item no longer carries `type => 'text'`, which triggered Material Skin's client-side div-wrapping. Matches the Like/Unlike confirmation shape that already toasts correctly. ([#136](https://github.com/stiefenm/spoton/issues/136))
- **Auth Health Dashboard showed "Audio Key: Denied" after daemon crash-loop recovery** — the `denied` cache state (TTL `never`) was never cleared. Now clears the stale denial when no error signature is present and the player is actively streaming, proving audio keys are being granted. ([#141](https://github.com/stiefenm/spoton/issues/141))

## [3.3.4] - 2026-08-03

### Fixed
- **Account switcher stranded Material Skin and Classic users on the confirmation page** — switcher items no longer carry `type => 'link'`, so Material Skin's inline action handling executes the switch and shows the confirmation as a toast instead of navigating into a new page; JiveLite keeps navigating back via `nextWindow => 'parent'`. Classic shows the confirmation page (ecosystem standard, same as Spotty). Follow-up to the v3.3.3 fix. ([#136](https://github.com/stiefenm/spoton/issues/136))
- **Sync group membership changes no longer restart the Connect daemon / drop the Spotify Connect session** — the device name now uses a static localized suffix (e.g. "Kitchen (Group)") instead of the composed syncname ("Kitchen & Living Room & Bedroom"), so adding or removing members to an already-synced group no longer triggers a daemon restart. Solo-to-group and group-to-solo transitions still restart (idle-guarded to protect active streams). Device appears as "PlayerName (Group)" in the Spotify app while synced. ([#143](https://github.com/stiefenm/spoton/issues/143))

## [3.3.3] - 2026-08-02

### Fixed
- **Material Skin HomeExtra rows returned page 1 for every page** — the memoization cache key now includes pagination args (index/quantity) so subsequent pages within the 60s TTL return their own items instead of re-serving page 1. ([#133](https://github.com/stiefenm/spoton/issues/133))
- **Menu shows the previous account name after switching** — the account switcher now returns to a re-fetched main menu via `nextWindow => 'parent'` so the active account name updates immediately. ([#136](https://github.com/stiefenm/spoton/issues/136))
- **Connect always used digital volume attenuation** — players with Digital Volume Control disabled in LMS player settings now start librespot with `--volume-ctrl fixed` for external amps (full-scale output, Spotify-app slider does not attenuate). Players with digital volume enabled keep the existing linear behavior. ([#137](https://github.com/stiefenm/spoton/issues/137))
- **Status page account order shuffled between auto-refreshes** — `getAccountIds()` now returns sorted keys and `renderAuthHealth` sorts `Object.keys()` at render time, pinning display order regardless of Perl hash randomization. ([#138](https://github.com/stiefenm/spoton/issues/138))
- **Material Skin home rows did not refresh after account switch, authentication, or removal** — a new `refresh()` helper clears the HomeExtra memoization cache and signals Material Skin, wired at four state-change points. ([#139](https://github.com/stiefenm/spoton/issues/139))

## [3.3.2] - 2026-07-27

### Added
- **Material Skin: Main Menu and Playlists as HomeExtra scrolled rows** — SpotOn's top-level navigation (Home, Search, Library, Podcasts) and the user's playlists are now available as optional scrolled rows on the Material Skin home screen, matching Spotty's feature set. Enable them in Material Skin's home screen settings. ([#132](https://github.com/stiefenm/spoton/issues/132))

## [3.3.1] - 2026-07-25

### Fixed
- **Search overview counts now match drill-in totals** — the search overview and drill-in page now use the same single-type API calls. Previously, the combined multi-type search returned different per-type totals, so the overview label disagreed with the drill-in's actual pagination total. ([#130](https://github.com/stiefenm/spoton/issues/130))
- **Podcast search (Shows/Episodes) now paginates past the first 10 results** — drill-in maps the LMS page index to the API offset and reports `offset`/`total` back to the menu framework, including nameless-entry ignore placeholders and a 50-offset cap matching Dev Mode limits. ([#130](https://github.com/stiefenm/spoton/issues/130))
- **Search items named "0" were hidden** — the nameless-entry predicate treated the literal name `"0"` as falsy. Now uses `defined` check. ([#130](https://github.com/stiefenm/spoton/issues/130))
- **Search icon missing in Classic Skin** — the main menu search entry used an incorrect image path.
- **Artist feed missing grid/cover toggle in Material Skin** — Albums, Singles, Compilations, and Appears On category items now have image keys, enabling Material Skin's view toggle. ([#124](https://github.com/stiefenm/spoton/issues/124))
- **Podcast feed missing grid/cover toggle** — My Podcasts, Shows, and Episodes category items now have image keys.

## [3.3.0] - 2026-07-24
### Added
- **Seek from JiveLite/LMS UIs now works during Spotify Connect playback** — the seek slider was disabled for Connect streams (`canSeek` returned 0). Seeking now forwards the target position to the Connect binary via `/control/seek` without restarting the LMS stream. Relative seeks (`+N`/`-N`) and seek-to-0 are supported. ([#129](https://github.com/stiefenm/spoton/issues/129))

### Fixed
- **Search category results were capped at the first API page** — drilling into Tracks/Albums/Artists/Playlists from search showed the same first 10 results on every page. `_searchTypeFeed` now maps the LMS page index to the API offset and reports `offset`/`total` back to the menu framework, enabling real pagination. ([#130](https://github.com/stiefenm/spoton/issues/130))
- **Search pagination breaks when API returns nameless entries** — nameless items are now mapped to XMLBrowser `ignore` placeholders instead of being filtered out, keeping offset/total aligned across page boundaries. ([#130](https://github.com/stiefenm/spoton/issues/130))
- **Search total exceeds Spotify's 1000-offset limit** — the advertised total is now capped at 1000 to prevent paging into guaranteed API errors. ([#130](https://github.com/stiefenm/spoton/issues/130))

## [3.2.3] - 2026-07-23
### Fixed
- **Connect progress bar divergence on mid-song resume** — the change handler no longer pushes a premature `newmetadata` notification at track-change time, which was sending a definitive position=0 to LMS clients before the real position arrived. The notification is now deferred to `_fetchTrackMetadata`'s failure paths (stale-API discard, 429 backoff, parse error), preserving the rapid-skip progress reset from the #126 fix without the eager wrong push. ([#126](https://github.com/stiefenm/spoton/issues/126))
- **Mid-song Connect resume position stays at 0** — the `needs_position_sync` flag in the librespot Connect handler now survives an intervening `TrackChanged Some→Some` event. Previously, a second TrackChanged before the first Playing event unconditionally cleared the flag, so the seek notification with the real position never fired. Both Playing handler branches now consume the flag via atomic swap. (librespot-spoton 3.0.1, [#126](https://github.com/stiefenm/spoton/issues/126))

## [3.2.2] - 2026-07-23
### Fixed
- **Connect seek/skip doesn't update progress bar on JiveLite/SqueezePlay** — the seek and track-change handlers in Connect mode now trigger a status push so subscribed displays resync immediately. Previously, LMS silently dropped the notification because no nested command was executed. ([#126](https://github.com/stiefenm/spoton/issues/126))
- **UTF-8 double-encoding on Status and Settings pages** — player names and other non-ASCII text (e.g. "Küche") now render correctly instead of mojibake ("KÃ¼che"). The `_jsonResponse` helper was wrapping `to_json()` output in a redundant `encode('UTF-8', ...)`. ([#125](https://github.com/stiefenm/spoton/issues/125))

### Added
- **Home feed icons for Material Skin grid/cover toggle** — Recently Played, Made For You, and Top Tracks entries now carry menu icons, enabling the grid/cover-view toggle on the Home feed. ([#124](https://github.com/stiefenm/spoton/issues/124))
- **Search result category icons** — Top Result, Tracks, Albums, Artists, and Playlists categories in search results now have distinct icons.
- **Made For You as Material Skin scrolled row** — available in MS Settings → Home Screen alongside Recently Played and Top Tracks. Degrades cleanly when sp_dc is not configured. ([#125](https://github.com/stiefenm/spoton/issues/125))

## [3.2.1] - 2026-07-23
### Fixed
- **Autoplay silently overrides Don't Stop The Music** — the Autoplay toggle in SpotOn Player Settings now controls Spotify Connect autoplay only and no longer writes to the DSTM provider setting. SpotOn no longer auto-claims DSTM for all players, and saving SpotOn settings no longer overwrites your chosen DSTM provider (LastMix, MusicIP, Random Mix, etc.). To use SpotOn recommendations for Browse queues, select "SpotOn Recommendations" in LMS Player Settings > Don't Stop The Music. ([#117](https://github.com/stiefenm/spoton/issues/117))

### Added
- **DSTM status display** — SpotOn Player Settings now shows the current Don't Stop The Music provider status as read-only info, with a hint pointing to LMS Player Settings for configuration.

## [3.2.0] - 2026-07-22
### Fixed
- **Material Skin grid-view toggle broken by artwork-less items** — playlists, albums, or tracks without Spotify artwork now show LMS-core fallback images instead of empty strings, so Material Skin's grid/cover-view toggle stays available for the entire list. Applied to all 8 item builders. ([#124](https://github.com/stiefenm/spoton/issues/124))

### Added
- **Material Skin home-screen integration** — new HomeExtras module registers "Recently Played" and "Top Tracks" as scrolled rows on the Material Skin home screen. Loads silently as a no-op when Material Skin is not installed. ([#125](https://github.com/stiefenm/spoton/issues/125))
- **Menu icons for all skins** — top-level entries (Home, Search, Library, Podcasts, Account Switcher) and library submenu entries (Liked Songs, Albums, Artists, Playlists) now have distinct icons, improving navigation in Material Skin and all other LMS skins.
- **HomeExtras robustness** — scrolled-row feeds filter out error/auth textarea items (preventing junk cards) and memoize results for 60s per player (preventing uncached API calls on every home-screen refresh).

## [3.1.3] - 2026-07-21
### Fixed
- **DSTM silent failures** — five bugs in Don't Stop The Music that caused silent fallback to local music: multi-artist query strings that Spotify couldn't match, unclamped random offset producing empty results, `getLimit('search')` returning 0 for blocked endpoints, and dead code (`_searchForSeeds`) that wasted API calls and could trigger rate-limit self-sabotage.
- **DSTM single-artist feedback loop** — only the first seed artist was used, producing tracks from one artist that then reinforced itself in successive cycles. Now collects up to 3 unique artists from a deep seed window (last 20 playlist tracks), shuffles per cycle, and excludes previously DSTM-generated tracks via tagging.
- **DSTM self-queueing** — search results could include tracks already in the playlist. Now builds an exclusion set from the current playlist and filters results against it.
- **Artist name mangling** — "Tyler, The Creator" was incorrectly split into "Tyler". Now preserves comma-containing artist names where the post-comma text starts lowercase.
- **Lazy re-probe hardening** — blocked endpoints stayed permanently blocked after re-probe (cleared now), auth failures mid-probe disabled future re-probes (restored now), and any HTTP 400 triggered probe storms (now gated on limit-related error messages only).

### Added
- **DSTM diversity pool** — injects up to 3 tracks from the user's Spotify top tracks (medium-term, cached 30 min) into each DSTM mix for taste-relevant variety beyond the seed artists.
- **DSTM recent-URI deduplication** — per-client rolling list of the last 30 DSTM-queued URIs (24h TTL) prevents the same tracks from reappearing across successive cycles.
- **Lazy API limit re-probe** — when a limit-related HTTP 400 occurs and the last probe was more than 6 hours ago, SpotOn automatically re-probes endpoint limits without requiring an LMS restart. ([#123](https://github.com/stiefenm/spoton/issues/123))

## [3.1.2] - 2026-07-20
### Fixed
- **Artist Albums pagination broken in Material Skin** — `_artistAlbumsFeed` fetched only one API page but reported the full `total` to LMS, causing Material Skin to show "scroll for more" indefinitely. Added the same play-all/`_fetchAllPages` pattern that `_playlistFeed` already had. Also applied to `_savedAlbumsFeed`, `_userPlaylistsFeed`, and `_savedShowsFeed` which had the same structural vulnerability for large collections. ([#121](https://github.com/stiefenm/spoton/issues/121))
- **Stale API limits after Client ID switch** — the binary-search limit detection was not re-triggered when switching between custom and bundled Client IDs. The Status page continued to show limits from the previous Client ID, and the higher caps of the bundled ID were not utilized. Now calls `Client->reset()` on Client ID change so the probe re-runs after re-authentication. ([#122](https://github.com/stiefenm/spoton/issues/122))

## [3.1.1] - 2026-07-18
### Fixed
- **Playlists empty for Development Mode Client IDs** — Spotify's Feb 2026 API changes serve a different response schema for Dev Mode apps (`item` key instead of `track`/`album`/`show`). SpotOn assumed the legacy schema everywhere, causing empty playlists, saved tracks, saved albums, and saved shows. Added `_normalizeLibraryItem` helper at all 8 consumer sites to handle both schemas transparently. ([#119](https://github.com/stiefenm/spoton/issues/119))

## [3.1.0] - 2026-07-18
### Added
- **Bundled Client ID (fallback)** — SpotOn ships a shared community Client ID with Extended Quota access. Users whose own Developer App has API restrictions (HTTP 400/403) can remove their Client ID from Settings to use the fallback. The ID is borrowed from the ncspot open-source project without explicit permission — users are encouraged to use their own Client ID when possible.
- **Granular API Limit Detection** — probes 5 endpoint classes individually on startup (search, library, artist albums, album tracks, playlist items) instead of 2. Each class gets its own binary-search limit detection. A 403 on one endpoint no longer aborts detection for the others. Detected limits and blocked endpoints are shown on the Status page.
- **PKCE token invalidation on Client ID change** — switching between bundled and custom Client ID (or changing to a different custom ID) automatically deletes stored tokens and prompts re-authentication.
- **TokenManager revocation detection** — distinguishes `invalid_client` (revoked Client ID) from `invalid_grant` (user revocation) with targeted messages in Settings and OPML.

### Changed
- **Settings UX** — bundled mode uses a loopback redirect URI with copy-paste auth flow (no Spotify Developer App required). Custom mode continues to use the GitHub Pages relay. The copy-paste field is visible from page load in bundled mode.
- **API limit clamping** — `getArtistAlbums` and `getAlbumTracks` now internally clamp the `limit` parameter to the detected value (defense-in-depth), matching the existing `search()` behavior.

### Fixed
- **Artist albums HTTP 400** — `_artistAlbumsFeed` used the `library` limit class (50) for the `artists/{id}/albums` endpoint, which Spotify caps differently for Dev Mode apps. Now uses a dedicated `artist_albums` limit class. ([#118](https://github.com/stiefenm/spoton/issues/118))

## [3.0.3] - 2026-07-17
### Added
- **API Limit Auto-Detection** — on startup, probes Spotify's enforced `limit` parameter maximum per endpoint class (Search, Library, Playlist Items) using binary search. Uses detected limits dynamically instead of hardcoded values. Displayed on the Status page under "API Limits". Apps with higher quotas automatically get better pagination; restricted apps stay within their enforced bounds.

## [3.0.2] - 2026-07-17
### Fixed
- **Search returns HTTP 400 for some Client IDs** — search calls sent `limit=50`, but the Feb 2026 Dev Mode changes cap `/v1/search` at `limit=10`. Spotify enforces this per-app; now hard-clamped to 10 across all search call sites. ([#118](https://github.com/stiefenm/spoton/issues/118))
- **DSTM causes API throttling under PKCE** — Don't Stop The Music fired up to 12 API calls in a ~100ms burst, risking 429 rate limiting that could disrupt playback. Removed dead `/recommendations` endpoint (removed by Spotify Nov 2024), staggered seed searches with 200ms delays, reduced seed count from 5 to 3. Worst case now 7 calls over ~1.4s.
- **HTTP 400 errors show no detail on Status page** — 400 responses now include Spotify's error message (e.g. "HTTP 400 for search: Invalid limit") instead of just the status code.

## [3.0.1] - 2026-07-17
### Fixed
- **Windows: Clear Logs blocked by open stderr handle** — v3.0 made stderr capture always-on, which held a file lock on Windows preventing log deletion. Handle is now closed immediately on Windows (read-by-path still works).
- **PKCE success page opens without LMS navigation** — after auth, the popup tab now closes automatically instead of redirecting to a frameless Settings page.
- **Status page card order** — Auth Health card moved to the top, followed by API & Tokens, Player, Errors, System Info.
- **Popup-blocker awareness** — added a note near the PKCE auth button that browsers must allow pop-ups.

## [3.0.0] - 2026-07-17
### Changed
- **Authentication**: PKCE OAuth replaces ZeroConf/Keymaster as the primary auth mechanism
- **Token management**: PKCE-native TokenManager with refresh token rotation
- **Connect**: Stored credentials derived from PKCE tokens (no ZeroConf needed for Connect)
- **Auth Health Dashboard**: Per-account status indicators, shown on the Status page

### Added
- **PKCE OAuth flow** via GitHub Pages static relay (one-click browser auth)
- **sp_dc cookie support** for Made For You playlists (Pathfinder integration)
- **Credential derivation**: automatic conversion of PKCE tokens to Connect credentials
- **Migration detection and guided re-auth flow** for existing v2.x accounts
- **Auth Health Dashboard** showing PKCE, sp_dc, Connect, migration, and audio-key status
- **Client-ID PKCE setup wizard** in Settings

### Removed
- **Keymaster token service** (`hm://keymaster/token/authenticated`) — all code paths removed
- **ZeroConf as auth mechanism** (retained only for guest LAN Connect discovery)
- **`--get-token` binary mode** (replaced by PKCE refresh in pure Perl)
- **Dual-token flavor system** in Client.pm (single PKCE token per account)

### Fixed
- **Playlist play-all from folder-level "Play now"**: CLI/Material Skin-driven play-all commands leave `quantity` undefined (unlike the Classic/Web UI, which sends `quantity>=500`). The play-all trigger now fires on `quantity` being undefined OR `>=500`, applied uniformly across Liked Songs, Shows, Albums, and Playlists.

## [2.3.18] - 2026-07-09
### Fixed
- **Connect silent failure with LMS password protection (GH #116)**: when LMS password protection is enabled, the Connect daemon's JSON-RPC notify to LMS was silently rejected with HTTP 401. SpotOn sent the stored SHA1 password hash via Basic Auth, but LMS re-hashed it (double hash), causing a mismatch on every request. Added the `X-Scanner` header that LMS accepts for backend processes authenticating with the stored hash directly — matching Spotty's original implementation. Connect now works with password protection enabled.

## [2.3.17] - 2026-07-09
### Fixed
- **Keymaster 403 shows as confusing JSON parse error (GH #99)**: when librespot exits with code 0 but Keymaster returns HTTP 403, the output contains only stderr log lines. The JSON parser misinterpreted the timestamp `[` as a JSON array start, producing `JSON parse error on --get-token` instead of the actual cause. The parse-failure path now runs the same Keymaster diagnostics (HTTP status code, error payload) as the exit-nonzero path, showing `keymaster_status: HTTP 403` and `no valid token in --get-token output` instead.

## [2.3.16] - 2026-07-09
### Fixed
- **Daemon crash-loop on multi-player systems (GH #113)**: daemon starts are now staggered with a 3-second delay between players, preventing simultaneous mDNS port contention. With 6 players, daemons start over ~15 seconds instead of all at once. Delay scales down automatically for 20+ players to fit within the watchdog window.
- **Port-capture timeout too short**: increased the async port-announcement timeout from 5 seconds to 10 seconds, reducing false-positive timeout aborts on slower systems.
- **Stagger timers survive plugin shutdown**: pending stagger timers are now properly cancelled during plugin shutdown, preventing orphaned daemon processes.

### Changed
- **Diagnostic report: Token & API Status section**: the downloadable diagnostic report now includes account display name, API request/429 counters, rate-limit status, and recent token error history — making Keymaster 403 issues immediately visible without requiring server.log analysis.
- **Diagnostic report: removed dead browse-errors.log section**: the "Browse Errors" section referenced a log file that was never written. Removed from the diagnostic bundle, log size calculation, and clear-logs handler.

## [2.3.15] - 2026-07-06
### Fixed
- **Browse playback error when daemon not running**: `ProtocolHandler::new()` now returns `undef` when the unified daemon is not running for a Browse URL, matching the existing Connect URL behavior. Previously, the raw `spoton://track:...` URL fell through to LMS's generic HTTP handler, causing a confusing `Couldn't resolve IP address for: track` DNS error instead of a clean stream-open failure. Reported by @jmhunter in GH #112.

## [2.3.14] - 2026-07-06
### Fixed
- **Connect OGG no audio on first track**: the `/stream` handler hardcoded a 3-page OGG header count, but Vorbis Comment and Setup headers can share a single page (2 pages total). When only 2 arrived, the 3-second timeout fired, headers were skipped, and squeezelite received an undecodable stream — progress bar looping at 0–1s with no audio. Replaced the fixed count with an `AtomicBool` completion signal from the sink, snapshotted headers inside the wait loop to eliminate a TOCTOU race, and added a `>= 2` fallback at timeout for the audio-key throttle scenario. Reported by @urknall on Raspberry Pi.

## [2.3.13] - 2026-07-06
### Fixed
- **Connect OGG stale header replay on rapid skip**: the `/stream` handler now verifies that buffered OGG headers match the current track's serial before replaying them. Previously, a rapid skip could cause LMS to receive headers from the previous track before the sink had processed the new serial, corrupting the Vorbis decoder setup. Shared `ogg_header_serial` atomic between sink and handler, with serial validation in the header-wait loop and replay skip on mismatch. Reported by @urknall via Telegram.

## [2.3.12] - 2026-07-05
### Fixed
- **ReplayGain double adjustment (GH #108)**: when SpotOn normalization is enabled, LMS no longer additionally applies its "Default Adjustment for Remote Streams." New `trackGain()` method in ProtocolHandler suppresses the LMS-side adjustment when librespot already handles gain. Reported by @CornelisJ.
- **Connect OGG gapless timeline drift**: replaced per-track rate-limiter reset with a continuous cumulative OGG timeline across serial boundaries. Eliminates the buffer-latency gap between gapless tracks and prevents progressive timing drift in long playlists. Improvements from PR #107 by @urknall.
- **Connect OGG rapid-skip header corruption**: OGG header pages are now buffered individually (per-page) instead of as whole decoder chunks. Fixes reconnecting clients receiving invalid stream setup data when a chunk spans a track boundary during rapid skipping.
- **Connect OGG granule offset**: first audio page frames are now fully counted in the continuous timeline (granule_offset = 0 at serial change), preventing ~93ms per-track accumulation over long gapless sessions.
- **Connect OGG header continuation pages**: header detection now accepts granule ≤ 0 (not just == 0), correctly handling Vorbis setup headers that span OGG page boundaries.

### Changed
- **Connect OGG zero-copy**: `Bytes::from()` for chunk ownership and `chunk.slice()` for header page references eliminate unnecessary memory copies on the audio hot path.
- **Connect PCM gapless simplified**: removed explicit rate-limiter reset on PCM track transitions — gapless PCM audio is continuous, so `frames_consumed` and `began_at` naturally carry across track boundaries.

## [2.3.11] - 2026-07-05
### Fixed
- **Windows: Browse/Library broken since v2.3.2**: `Proc::Background` stdout redirect silently fails on Windows services — the async token fetch (introduced in v2.3.2) never got the `ISWINDOWS` guard that `Daemon.pm` already had. Token JSON went nowhere, causing `--get-token` to always fail. Now uses `SPOTON_TOKEN_FILE` env var on Windows, matching the proven `SPOTON_PORT_FILE` pattern. Forum #183 by @foxesden.

## [2.3.10] - 2026-07-05
### Fixed
- **Connect track transition rate limiting**: reset the Connect stream rate limiter on track changes without re-applying the 2s buffer latency as a pause. Prevents audio gaps on gapless transitions. PR #106 by @urknall, with additional fixes for buffer_latency_ns permanence and start()/dispatcher race guard.
- **Connect OGG header race on skip**: the `/stream` relay now waits up to 3s for OGG header pages before starting delivery, fixing intermittent `vorbis_decode error: -132` when LMS reconnected before the new track's headers were buffered.
- **Forum monitor CI**: fixed non-fast-forward push failure when concurrent runs landed between checkout and push.

## [2.3.9] - 2026-07-04
### Fixed
- **Daemon restart on normalization toggle**: changing the "Volume Normalization" checkbox in Server Settings now immediately restarts the librespot daemon. Previously, `formatOverride()` would return the new format (OGG passthrough) while the daemon still output PCM, causing silence until LMS restart or the 60s watchdog caught up.

## [2.3.8] - 2026-07-04
### Added
- **Release year metadata**: album release year is now propagated through all track metadata paths (browse items, connect updates, album tracks, deferred cache flushes, async refetch) and displayed in LMS track info via the native `infoYear` provider. PR #104 by @urknall.

### Fixed
- **Volume normalization was a no-op**: the "Volume Normalization" checkbox in SpotOn settings had no effect — the `--enable-volume-normalisation` flag was passed to the daemon but never parsed. Now wired through to both Browse and Connect PlayerConfig. Users switching from Spotty with normalization enabled may have experienced louder (potentially clipping) output. Note: normalization has no effect in OGG Passthrough mode (librespot only normalizes decoded PCM).
- **Auto format + normalization**: when streaming format is set to "Auto" and normalization is enabled, SpotOn now selects PCM instead of OGG Passthrough — otherwise normalization would silently do nothing.
- **Release year "0000" guard**: Spotify's placeholder date `"0000"` for tracks with unknown release dates is now filtered out instead of displaying year 0000.

## [2.3.7] - 2026-07-03
### Added
- **Runtime metadata propagation**: `setCurrentTitle` is now called on both the logical (`spoton://`) and stream (HTTP) URL so renderers that key display metadata off the stream URL (e.g. UPnPBridge/WiiM) get correct titles. `_applyRuntimeMetadata` propagates duration and title to the playing song with a recursion guard, gated to the actively playing song only. Based on PR #100 by @urknall.
- **OPML item enrichment**: track, episode, and album item builders now include explicit `title`, `artist`, `album`, and `favorites_title` fields for richer metadata on third-party controllers and correct favorites naming.
- **Songinfo duration**: track duration is now propagated to the `RemoteTrack` object so LMS songinfo (Titelinformationen / More menu) displays track length.

### Fixed
- **Favorites naming**: saving a track to favorites from the songinfo page now shows "Title — Artist" instead of the raw `spoton://` URL.
- **streamFormat labels**: removed confusing "(DirectStream)" suffix from OGG Passthrough and PCM option labels; replaced "DirectStream-capable" with "when supported" in descriptions. Suggested by @urknall.
- **streamFormat description**: removed outdated "Connect always uses PCM DirectStream" reference; now points to Connect OGG Override.
- **Streaming Mode description**: added "changes take effect on next track" hint to all 11 locales.

## [2.3.5] - 2026-07-03
### Added
- **Streaming Mode preference**: per-player Direct/Proxy toggle with a global server-wide default. Proxy mode forces LMS to relay the stream, preserving metadata for third-party players like WiiM via UPnPBridge. Configurable in Server Settings (global default) and Player Settings (per-player override). Addresses #96.
- **URL canonicalization**: `getMetadataFor()` and `getIcon()` now map daemon HTTP URLs (`http://host:PORT/track/ID`) to `spoton://track:ID` cache keys, eliminating metadata cache misses when LMS calls `parseDirectHeaders()` with the direct-stream URL.

## [2.3.4] - 2026-07-03
### Fixed
- **Token parse error on Keymaster 403**: when librespot exits 0 but outputs only stderr log noise (e.g. `[timestamp ERR ...]` from a Keymaster 403), the `[` was misinterpreted as a JSON array start, producing a confusing parse error. Now runs Keymaster diagnostics (HTTP status, error payload) and logs a clear message. Fixes #99.

## [2.3.3] - 2026-07-02
### Fixed
- **Third-party player metadata**: exploded track items now include separate `title`, `artist`, and `album` fields that LMS maps onto the RemoteTrack object. This allows `standardTitle()` to compose the client's configured `titleFormat` (e.g. "Title by Artist from Album") instead of showing only the combined "Title - Artist" string. Fixes metadata display on WiiM Ultra and similar players that rely on `current_title`. Fixes #96.
- **Time::HiRes import**: added missing `use Time::HiRes` in ProtocolHandler.pm and guarded `currentPlaylistUpdateTime()` calls with `->can()` in both Connect.pm and ProtocolHandler.pm to prevent runtime errors on clients that don't implement the method. Based on PR #98 by @urknall.

## [2.3.2] - 2026-07-02
### Fixed
- **API deadlock prevention**: `uri_escape_utf8` for non-ASCII search queries (Björk, CJK) — previously could leak `$inflightCount` and deadlock all API requests. Cache lookup now runs before token fetch to avoid unnecessary token refreshes.
- **Token fetch timeout**: async token fetch with 15s watchdog replaces blocking backtick call that could hang the LMS event loop. Added in-flight coalescing to prevent token refresh stampede on cache expiry.
- **Credentials cleanup**: `removeAccount` now deletes the credentials directory from disk.
- **Web UI crash**: `_getAccountId` no longer crashes with undef `$client` when browsing SpotOn from the web UI without an attached player.
- **Album pagination loop**: album explode now uses the raw API offset instead of filtered count, preventing an infinite loop when tracks are skipped (e.g., unavailable tracks).
- **Connect metadata bleed**: `change`/`seek`/`volume` events now have Connect guards — metadata from Connect playback no longer overwrites Browse metadata. `newTrack` flag leak fixed with 10s expiry timer.
- **Pause after Spotify disconnect**: `ready` handler no longer force-resumes playback after a Spotify app disconnect — player stays paused if it was paused.
- **Crash-loop cooldown**: watchdog no longer resets the 30-minute cooldown every 60s. Health-restart rate-limit is now tied to the player MAC, not the daemon object.
- **Credentials in process list**: LMS auth credentials are passed via environment variable instead of command-line argument, no longer visible in `ps aux`.
- **Daemon subscriptions**: event subscriptions are now properly unsubscribed on shutdown.
- **Async port wait**: daemon port detection no longer blocks the LMS event loop for up to 5s.
- **Rapid-skip session teardown**: superseded Browse requests now return HTTP 409 instead of counting as failures that could tear down the Spotify session. `browse_cancel` properly aborts the stream.
- **Stream relay generation**: reconnecting `/stream` clients get their own relay channel instead of sharing one — prevents audio corruption.
- **Connect/Browse timeouts**: LMS notify calls in Rust have a 10s timeout instead of the 2min OS default. Graceful shutdown no longer hangs on active `/stream` clients.
- **Reconnect backoff**: failed Browse reconnects use exponential backoff instead of infinite immediate retry.
- **DSTM multi-account**: Don't Stop The Music now uses the per-client account instead of only the global account.
- **Discovery PID tracking**: `bsd_glob` replaces glob for Windows compatibility. Discovery process PID is tracked for clean shutdown.
- **Cache version constant**: unified across all modules to prevent silent cache schema divergence.
- **pgrep safety**: helper process detection uses `quotemeta` to prevent regex injection from binary paths.

## [2.3.1] - 2026-07-02
### Fixed
- **Bitrate preference**: `--bitrate` flag is now wired to the librespot daemon, honoring the per-player bitrate preference (96/160/320 kbps). NowPlaying metadata shows the actual stream bitrate instead of always displaying "320k". Fixes #97.
- **Metadata polling for third-party players**: `currentPlaylistUpdateTime()` is now called before `newmetadata` notifications in both Connect and Browse async metadata paths, ensuring polling clients (WiiM Ultra, web UI) detect metadata updates via `playlist_timestamp`. Follows the Podcast/RemoteLibrary plugin pattern.
- **Exploded track item title format**: replaced em dash (U+2014) with standard dash in track `name` field for consistent `current_title` formatting across players.
- **`--check` capability manifest**: `lms-auth` is now correctly reported as `true`.

## [2.3.0] - 2026-07-02
### Added
- **OGG Vorbis Passthrough (Connect)**: Spotify Connect streams can now deliver raw OGG/Vorbis to players that support it, skipping CPU-intensive PCM decoding. Auto-detected via player format announcement; configurable per-player (`streamFormat` pref: auto/ogg/pcm).
- **OGG Vorbis Passthrough (Browse)**: single-track Browse playback also supports OGG passthrough with the same auto-detection logic.
- **Shared passthrough resolver**: `resolvePassthroughForClient()` in DaemonManager provides a single source of truth for OGG passthrough decisions across Browse, Connect, and NowPlaying display.
- **Context Menu cleanup**: removed `trackInfoURL` override from ProtocolHandler — LMS now shows its native Song Info items instead of the broken Spotify web link. Fixes #55.
- **Favorites artwork**: added `getIcon()` to ProtocolHandler so LMS Favorites show album artwork instead of the generic SpotOn plugin icon.

### Fixed
- **Connect OGG rate-limiting**: granule_position-based wall-clock pacing ensures OGG data flows at real-time speed, preventing Spirc/audio desync where the Spotify app skipped ahead while LMS was still buffering.
- **Gapless track transitions (OGG)**: OGG serial number change detection resets the rate-limiter on gapless transitions — librespot does not call stop()/start() between gapless tracks, so the serial number is the only reliable track boundary signal.
- **Connect Pause/Resume**: resume handler now uses `track->url` (the original `spoton://connect-*` URL) instead of `streamUrl` (which becomes the HTTP proxy URL after `canDirectStream`). Previously, resume always restarted the stream from 0:00.
- **Resume position offset**: captures the first audio page's granule_position as a baseline offset so the rate-limiting formula starts from 0 relative to `began_at` after pause/resume, instead of sleeping for the entire track prefix.
- **Negative granule guard**: `.max(0)` before i64-to-u128 cast prevents a negative relative_granule (from a missed serial change in a multi-page chunk) from wrapping to ~2^64 and hanging the audio thread for ~420 years.
- **OGG header replay on Connect reconnect**: buffered OGG BOS + Vorbis setup headers are replayed when squeezelite reconnects to the `/stream` endpoint, ensuring the decoder always receives valid stream initialization.
- **Keymaster 403 diagnostics**: error payload is now parsed and logged with client-id context; no-op fallback eliminated.
- **explodePlaylist format**: returns OPML items hash instead of bare URL array, fixing playlist population in some LMS skins.
- **Song Info web link**: shows Spotify web link instead of raw `spoton://` URL.

### Changed
- **NowPlaying format display**: shows actual stream format (PCM vs OGG) based on passthrough state instead of always showing OGG.
- **Context menu prefix**: SpotOn context menu items now prefixed with "SpotOn:" for clarity.

## [2.2.0] - 2026-06-30
### Added
- **Session Health Monitoring**: the unified daemon's `/health` endpoint now returns JSON with `session_valid`, `session_age_secs`, and `idle_secs` fields. The Perl side polls each daemon every 60 seconds and proactively restarts daemons with stale Spotify sessions (invalid session or >4h idle) before users experience cold-start playback failure.
- **Status Page: Session Health**: the diagnostic status page now shows per-daemon session validity, session age, and idle time with live-updating green/red indicators.

### Fixed
- **me/* endpoint fallback**: API requests to `me/*` endpoints (library, playlists, player state) now fall back to the bundled token when Keymaster returns 403 for a custom Client ID. Previously, only Browse/Search had this fallback — library and player endpoints failed silently. (#91)
- **Status page crash resilience**: all five data collectors in `_statusDataHandler` are now wrapped in `eval` guards — a failing collector returns an empty default instead of crashing the entire status page.
- **Browse fail counter race**: the consecutive-failure counter is no longer incorrectly reset when `serve_track_request` returns a slow 404 after the 500ms early-status timeout.
- **Health restart crash-loop**: health-triggered daemon restarts are now rate-limited to once per 5 minutes, preventing indefinite restart cycles when a session is permanently dead.
- **Health check error logging**: JSON parse errors from the `/health` endpoint are now logged with the raw response body instead of being silently discarded.
- **Status page XHR pileup**: added 4-second request timeout and switched from `setInterval` to `setTimeout`-chained polling to prevent request accumulation when LMS is slow.
- **Stale health data display**: the status page now shows "invalid" when the health endpoint is unreachable, instead of displaying the last successful (potentially outdated) snapshot.

### Changed
- **Watchdog log cleanup**: three `initHelpers` log lines that fired every 5 seconds (>800/day) downgraded from INFO to DEBUG.

## [2.1.8] - 2026-06-29
### Fixed
- **Custom Client ID fallback**: when a custom Spotify Developer App Client ID fails token retrieval (Keymaster 403/404), SpotOn now automatically falls back to the bundled token for Browse/Search/Library requests. Previously, a failing custom Client ID caused "No results" with no recovery. Fixes #86, #91.

### Changed
- **Custom Client ID documentation**: Settings page, Setup Guide, README, and Troubleshooting now clarify that custom Client IDs only work with older (pre-2025) Spotify Developer Apps. Newly created apps are rejected by Spotify's Keymaster server — this is a Spotify-side restriction, not a SpotOn bug.

## [2.1.7] - 2026-06-29
### Fixed
- **Pause guard**: pause commands that were silently swallowed during HTTP stream setup or track transitions are now detected and re-applied automatically. Uses a per-client timer chain that monitors play mode for up to 5 seconds after a pause, re-issuing the pause if the stream setup overrides it. Explicit user resume clears the guard immediately.

### Changed
- **Custom Client ID docs**: README now notes that Developer App owners must have Spotify Premium (required since Feb 2026). Added troubleshooting entry for empty search results with custom client IDs.
- **CDN 404 troubleshooting**: added entry for track skip / 404 errors with upgrade and `/etc/hosts` workaround guidance.

## [2.1.6] - 2026-06-29
### Changed
- **librespot upgraded to dev branch** (post-v0.8.0): includes CDN fallback fix (#1722), 32-bit overflow fix (#1678), multi-address connection fix (#1651), credential file permissions (#1650), and volume-ctrl fixed fix (#1642). Combined with SpotOn's existing 404 retry layer (3 attempts, 2s delay), this provides significantly improved playback reliability against Spotify CDN issues.

### Added
- **Diagnostic logging for pause events**: tracks `newsong` race conditions and pause mode state for intermittent pause-not-working investigation

## [2.1.5] - 2026-06-28
### Fixed
- **Connect credential isolation**: Connect sessions from a different Spotify user no longer overwrite the Browse account's `credentials.json`. Reconnect sessions now use a credential-free cache, preserving audio key caching while preventing credential writes. Fixes regression from Phase 14 where `Spirc::new()` always called `store_credentials=true`.

## [2.1.4] - 2026-06-28
### Fixed
- **Multi-account switch**: Settings page account switch now clears per-player overrides so all players fall back to the new global account. Previously, players that had been switched via the OPML menu silently ignored the Settings switch. (#75)
- **Account removal cleanup**: removing an account now clears per-player preferences pointing to the deleted account
- **OPML switch breadcrumb**: removed nested "SpotOn" link from account switch confirmation to prevent breadcrumb stacking in Default skin

## [2.1.3] - 2026-06-28
### Fixed
- **Browse 404 retry crash**: `_retryStream` called non-existent `shuffleIndex` — replaced with correct `streamingSongIndex` API. Affected users who hit a transient 404 from the browse daemon (e.g. audio-key throttle, CDN issues). (#60)
- **Docker/s6 daemon startup**: `Proc::Background` stdout redirect fails in Docker containers with s6 process supervisor — the daemon's port announcement was never captured. Now uses `SPOTON_PORT_FILE` env var on all platforms so the daemon writes its port directly to the tempfile. (#60)
- **Manual credential transfer docs**: instructions in TROUBLESHOOTING.md were broken — placing `credentials.json` in a hash directory never registered the account in preferences. Replaced with the `__DISCOVER__/` flow (place file, visit Settings page). Added Docker/Kubernetes notes. (#52)

## [2.1.2] - 2026-06-26
### Fixed
- **Play-All performance**: large playlists and Liked Songs (1000+ tracks) no longer cause song skips or extreme slowdown. Metadata cache writes are now deferred to background batches of 50 per event-loop tick, preventing SQLite I/O from blocking audio streaming. Reduces API token usage from 200+ to <30 for 1633 Liked Songs. (#51)

## [2.1.1] - 2026-06-26
### Added
- **Add to Playlist**: track and episode context menus now include "Add to Playlist" — shows a paginated picker of the user's Spotify playlists, selecting one adds the item via Spotify API with confirmation popup

### Fixed
- **Playlist pagination**: playlist picker reads pagination offset from correct LMS parameter source

## [2.1.0] - 2026-06-26
### Added
- **More Context Menu**: track info menu now shows Artist View, Album View, and Like/Unlike for tracks; View Show and Follow/Unfollow for episodes. Navigation items link directly into SpotOn Browse. Resolves #29, #33.

### Fixed
- **Cache-key normalization**: trackInfoMenu now normalizes `spoton:` to `spoton://` before cache lookup, preventing silent Artist/Album View disappearance when LMS passes non-double-slash URL form
- **Episode menu guard**: Follow/Unfollow item for episodes is now guarded behind showId availability check, preventing invalid API calls on cache miss
- **Like item consistency**: Like/Unlike item attributes (`type`, `favorites`) aligned between trackInfoMenu and trackInfoURL entry points

### Changed
- **Shared ID extraction**: artist/album ID extraction consolidated into `_extractTrackIds()` helper, replacing 4 inline copies across Plugin.pm, ProtocolHandler.pm, and Connect.pm

## [2.0.9] - 2026-06-25
### Added
- **Status Page**: standalone diagnostic dashboard at `/plugins/SpotOn/status.html` — dark-themed 4-card grid with Player Daemon Health, API & Tokens, Recent Errors, and System Info. Auto-polls every 5 seconds, pauses when browser tab is hidden. Link in Settings Diagnostics section.
- **API telemetry**: request counter, 429 counter, and rate-limit status tracked in Client.pm with `statusSnapshot()` method for Status Page
- **Error ring-buffer**: last 30 errors stored in Status.pm, displayed newest-first in Status Page

### Fixed
- **Browse 404 retry**: transient audio-key throttles from Spotify no longer cause immediate track skip — retries up to 3 times with 2-second delay before skipping. Prevents playlist playback from stopping when consecutive tracks hit temporary 404s.
- **Search routing**: search requests now route through bundled token with limit raised to 50 results per type

## [2.0.8] - 2026-06-25
### Added
- **Troubleshooting guide**: setup page links to TROUBLESHOOTING.md for Docker/VLAN/mDNS issues with manual credential transfer instructions (11 languages)

### Fixed
- **Windows: static VCRUNTIME**: Visual C++ Runtime is now statically linked — no separate redistributable install needed
- **Windows: log file fallback**: daemon falls back to stderr logging if SPOTON_LOG_FILE can't be opened (prevents crash-loop on permissions errors)
- **Windows: shell escaping**: escape `%` characters in cmd.exe commands to prevent environment variable injection
- **Windows: orphan cleanup**: use `tasklist` instead of PowerShell (avoids enterprise execution policy restrictions)

## [2.0.7] - 2026-06-25
### Fixed
- **Windows daemon startup**: Proc::Background stdout/stderr redirect fails on Windows services (no valid STDOUT/STDERR file descriptors). Port capture now uses `SPOTON_PORT_FILE` env var — daemon writes port directly to a file. Daemon logging uses `SPOTON_LOG_FILE` env var — logs written to file instead of stderr. Both mechanisms bypass Proc::Background handle redirect entirely. (#40)
- **Windows orphan cleanup**: replaced deprecated `wmic` with PowerShell `Get-Process` + PID-based filtering

## [2.0.6] - 2026-06-25
### Fixed
- **Windows daemon startup**: replaced pipe+IO::Select with cross-platform tempfile polling for port capture — IO::Select fails on pipe filehandles on Windows where select() only works on sockets (#40)
- **Windows orphan cleanup**: replaced deprecated `wmic` (removed from Windows 11) and blanket `taskkill /IM` with PowerShell `Get-Process` + PID-based filtering that protects active daemons
- **Tempfile robustness**: eval-wrapped tempfile creation, stale tempfile cleanup on daemon start, partial-write guard with EOL anchor

## [2.0.5] - 2026-06-24
### Fixed
- **Windows binary compatibility**: switched from MinGW cross-compilation to native MSVC build on GitHub Actions — the MinGW-built binary failed to run on Windows 11 with "incompatible with 64-bit Windows" error (#40)

## [2.0.4] - 2026-06-24
### Fixed
- **Diagnostic bundle download truncated**: Content-Length header and actual body size could mismatch on non-ASCII log content — now encodes to UTF-8 before measuring and sending
- **Diagnostic bundle expanded**: now includes unified daemon logs (`*-unified.log`), browse error log, and SpotOn-related entries from LMS server.log (last 200 lines)
- **Log size calculation**: Settings page now shows total size of all SpotOn logs (connect + unified + browse errors), not just connect logs
- **Clear logs**: now also deletes unified daemon logs alongside connect and browse error logs

## [2.0.3] - 2026-06-24
### Fixed
- **Browse session auto-reconnect**: when the Spotify TCP connection drops overnight, Browse mode now detects consecutive track failures and automatically reconnects the session — previously all tracks failed with 404 until LMS restart
- **Event dispatcher after Spirc reconnect**: Connect notifications (start/stop/volume/seek) no longer silently stop working after a ZeroConf credential rotation — the event dispatcher is now respawned with a fresh player event channel
- **CSRF protection on settings endpoints**: clearLogs, discovery/start, and discovery/stop now validate X-Requested-With header when LMS authentication is enabled
- **Windows token refresh**: shell commands for `--get-token` now use double-quotes on Windows instead of Unix single-quotes, fixing "filename, directory name, or volume label syntax is incorrect" errors (#40)
- **Diagnostic bundle expanded**: now includes unified daemon logs (`*-unified.log`) and SpotOn-related entries from LMS server.log — log size calculation and clear-logs updated accordingly
- **Cache version alignment**: ProtocolHandler, Connect, and DontStopTheMusic modules now use the same cache namespace version as Plugin.pm
- **12 code review findings**: use warnings in 3 modules, Retry-After minimum backoff, UTF-8 Content-Length, helperCheck explicit return, library action allowlist, HTTP body limit on /control/*, CRLF sanitization, TCP graceful shutdown, translated URL cap, fetchAllPages circular reference cleanup, reconnect timeout 503, source-before-execute for Connect loop prevention

## [2.0.2] - 2026-06-24
### Fixed
- **Browse session auto-reconnect**: when the Spotify TCP connection drops overnight, Browse mode now detects consecutive track failures and automatically reconnects the session — previously all tracks failed with 404 until LMS restart

## [2.0.1] - 2026-06-23
### Fixed
- **Play All performance**: Material Skin Play All on large lists (1600+ liked songs) no longer triggers individual API calls per track — results are served from an in-memory cache populated by the initial batch fetch (15s instead of 10+ minutes)
- **formatOverride dead fallback**: removed `son` fallback that referenced deleted transcoding pipelines — always returns `soc` now, preventing silent playback failure when the daemon is temporarily down
- **Browse sync-proxy missing alive check**: added `$helper->alive` guard to prevent routing to a crashed daemon's stale port
- **Connect toggle not detected**: toggling Spotify Connect on/off in player settings now correctly restarts the daemon with the updated `--enable-connect` flag
- **DSTM auto-config respects user choice**: auto-configuration of Don't Stop The Music provider only applies to players that never saved their SpotOn settings, avoiding silent overwrite of the user's deliberate choice
- **Play-all cache eviction**: `_playAllItemCache` entries older than 120s are now proactively evicted to prevent unbounded memory growth on long-running LMS instances

## [2.0.0] - 2026-06-23
### Added
- **Unified Browse + Connect daemon**: Browse and Spotify Connect now run in a single persistent process per player instead of separate daemons — eliminates per-track process spawning, halves memory footprint
- **HTTP track serving**: Browse mode streams tracks via HTTP from the persistent daemon instead of the old pipe-based `--single-track` pipeline — no process startup delay, no broken-pipe edge cases
- **Podcast episode route**: `/episode/{id}` endpoint in the unified daemon for podcast streaming alongside `/track/{id}`
- **Rapid-skip debounce**: `browse_abort_gen` counter detects superseded track requests and cancels them before hitting Spotify's audio-key API
- **Daemon lifecycle: account removal**: removing a Spotify account now immediately stops all daemons and restarts them with fresh credentials on ZeroConf re-authentication (~2s instead of up to 60s)
- **Daemon lifecycle: scheduleInit()**: public method for external callers (TokenManager, Settings) to trigger daemon restart without function-reference issues
- **DSTM auto-configuration**: Don't Stop The Music provider is now automatically set for all players with autoplay enabled — no more silent DSTM failures on players that never opened SpotOn settings

### Fixed
- **Sync group: stale daemon name after unsync** — name-mismatch check in `startHelper()` detects when a daemon's Spirc name doesn't match the current sync state and restarts it (fixes [#25](https://github.com/stiefenm/spoton/issues/25))
- **Sync group: no Connect audio on re-sync** — merged LMS event dispatcher and mode-watcher into a single async task, eliminating the race condition that dropped the `start` notification to LMS (fixes [#25](https://github.com/stiefenm/spoton/issues/25))
- **Early track skip in Browse mode** — tracks no longer cut short before finishing; the old pipe-based architecture could lose buffered data on process exit, especially with FLAC transcoding (fixes [#28](https://github.com/stiefenm/spoton/issues/28))
- **Browse/Connect mode transitions** — Spirc shutdown on Browse takeover, ready-event suppression during Browse, Connect metadata bleed prevention
- **Settings/Player.pm** — fixed stale `Connect::DaemonManager` reference (module removed in v2.0), now uses `Unified::DaemonManager->scheduleInit()`

### Changed
- **Autoplay tooltip** updated to explain it controls both Connect autoplay and Browse DSTM together
- `custom-convert.conf` simplified to single `soc pcm * *` entry (all legacy `son-*` pipelines removed)
- Binary version bumped to 2.0.0
- All `--single-track` mode code removed from Rust binary
- Legacy Browse::DM, Browse::Daemon, Connect::DM, Connect::Daemon Perl modules removed

### Removed
- `browseMode` / `daemonMode` toggle preferences (unified is the only mode)
- `son-*` transcoding pipelines from `custom-convert.conf`
- `--single-track` and `--browse-daemon` CLI modes from the Rust binary

## [1.9.1] - 2026-06-22
### Fixed
- Prefetch hang watchdog redesigned: URL-based "same song after 10s?" check replaces fragile elapsed-arithmetic approach — more robust, seek-safe, max 13s worst-case hang

## [1.9.0] - 2026-06-22
### Added
- **Browse Error Recovery**: Unavailable tracks (region-locked, removed, CDN error) are now detected via `PlayerEvent::Unavailable` — binary exits with code 1 within seconds instead of hanging forever
- **Browse Error Diagnostics**: Single-track stderr captured to `browse-errors.log` when diagnosticMode is on; included in diagnostic bundle under "Browse Errors" section; Clear Logs removes it
- **Prefetch Hang Watchdog**: Detects when player stalls at end of track because the next track's pipeline failed (unavailable, audio key error) and forces skip automatically

### Changed
- Single-track safety-net timeout reduced from 30s to 5s (Unavailable events fire within 1-2s)
- Binary version bumped to 1.3.0 (new PlayerEvent channel loop replaces `await_end_of_track`)

### Fixed
- diagnosticMode rapid-toggle race condition: `killTimers` before `setTimer` prevents duplicate Connect daemon instances
- STDERRLOG injection unified from two-pass substitution to single regex (eliminates implicit ordering dependency)
- 500KB log tail-read pattern extracted to `_readLogTail` helper (was duplicated in diagnostic bundle)
- clearLogs message no longer reports misleading "deleted N of M" count

### Known Limitations
- Rapid skipping through many tracks can trigger Spotify audio-key throttling (`error audio key 0 2`) causing temporary skip of available tracks — this is a Spotify-side session-burst rate limit, identical to Spotty behavior. A persistent Browse daemon (Backlog #8) would eliminate this.
- Prefetch of unavailable tracks causes ~10-30s of audio stalling at the end of the preceding song before the watchdog forces a skip — LMS buffer management limitation, also addressed by Backlog #8.

## [1.7.8] - 2026-06-21
### Fixed
- `getMetadataFor` no longer logs Error-level backtrace when LMS passes `Slim::Schema::RemoteTrack` instead of URL string — downgraded to debug (fixes [#14](https://github.com/stiefenm/spoton/issues/14))

### Changed
- Connect daemon `RUST_LOG` now tied to diagnosticMode setting — `spoton=info,librespot=warn` when off (default), `spoton=debug,librespot=info` when on
- Connect daemon stderr routed to `/dev/null` when diagnosticMode is off — no more `*-connect.log` files in normal operation
- Toggling diagnosticMode restarts all Connect daemons so log settings take effect immediately
- Connect log total size shown next to "Clear Logs" button in settings

## [1.7.7] - 2026-06-20
### Added
- Play-all on playlists, liked songs, albums, and podcast shows now fetches ALL tracks/episodes via full API pagination (fixes [#16](https://github.com/stiefenhofer/spoton/issues/16))
- Reusable `_fetchAllPages` async paginator helper for all feed functions
- Recursive pagination in ProtocolHandler show-explode path (matching existing album/playlist patterns)

### Fixed
- Play-all detection threshold raised to `qty >= 500` to avoid triggering full pagination during normal browsing on non-Material-Skin clients
- Circular reference memory leak in recursive `$fetchPage` closures (broken with `undef` at exit points)
- Missing null-track guard in `_savedTracksFeed` play-all branch (consistent with `_playlistFeed`)

## [1.7.6] - 2026-06-19
### Fixed
- Material Skin now shows "OGG, SpotOn Connect" instead of just "OGG" (parenthesized part was stripped)
- `glob()` replaced with `bsd_glob()` to handle spaces in LMS cache directory paths

### Changed
- Deduplicated `_largestImage` across Plugin, ProtocolHandler, and Connect modules
- Extracted `_jsonResponse` helper in Settings (eliminates 5x JSON response boilerplate)
- Extracted `_extractShowIds` in API Client (eliminates 3x URI-to-ID regex)
- Merged `_doShowLibraryAction` into `_doLibraryAction` with options parameter
- Forum monitor draft generation now retries 3x with backoff on transient API errors

## [1.7.5] - 2026-06-19
### Fixed
- Stale credentials from failed auto-setup permanently blocked ZeroConf re-authentication
- Duplicate variable declarations in `startDiscovery` caused Perl warnings on every call
- Off-by-one in podcast show feed when Follow button was present on first page
- Developer App ID setup guide now correctly marked as "optional, recommended" (was "optional, advanced")

## [1.7.4] - 2026-06-18
### Fixed
- ZeroConf discovery auth race condition: credentials were deleted before account creation because `location.reload()` replayed the POST form data, re-triggering `startDiscovery()`
- Discovery start/stop buttons no longer trigger spurious "changes saved" banner (moved from form POST to AJAX endpoints)
- IPv6 discovery fallback: systems with `ipv6.disable=1` can now use ZeroConf discovery (dual-stack bind falls back to IPv4)

### Changed
- Setup guide rewritten: account connection is now step 1, Developer App moved to optional section at the bottom
- Setup guide now explains that Spotify app won't show a success animation (expected behavior)
- Connect-hint image removed from setup guide (replaced by detailed text instructions)
- Binary updated to v1.2.0 with vendored librespot-discovery patch

## [1.7.3] - 2026-06-18
### Changed
- Connect daemon log is now truncated on each daemon start instead of appending indefinitely
- Diagnostic report download is now a proper button (was a styled link)

### Added
- "Clear Daemon Logs" button in Settings (always visible, deletes all `*-connect.log` files)

## [1.7.2] - 2026-06-18
### Changed
- `getMetadataFor` ref guard now logs a backtrace (`logBacktrace`) to trace the caller when LMS passes an object instead of a URL string

### Added
- Troubleshooting entry: ZeroConf auth shows "Connecting" forever in Spotify app (expected behavior, credentials are received successfully)

## [1.7.1] - 2026-06-17
### Fixed
- Streaming crash on Squeezebox hardware: `parseDirectHeaders` called non-existent SUPER method on `RemoteStream` — now delegates to `Slim::Player::Protocols::HTTP` explicitly
- Perl warning `md5_hex called with reference argument` when LMS passes object instead of URL string to `getMetadataFor`
- Zombie daemons after plugin disable/uninstall: added `shutdownPlugin()` to stop all Connect daemons and cancel timers on plugin shutdown

## [1.7.0] - 2026-06-17
### Fixed
- Seek bar showed 0:00 duration — seeking was impossible (duration propagation via `$song->duration()`)
- LMS Favorites unplayable — items used `spotify:` URIs instead of `spoton://` URLs
- Queue showed "Loading..." for all tracks after playing album/playlist from Favorites

### Added
- `explodePlaylist`: resolves album, playlist, and show containers from Favorites into playable tracks
- Metadata pre-caching during container resolution — queue shows titles and artwork immediately
- Episode support in async metadata refetch (`_asyncRefetch`)
- `parseDirectHeaders` for Connect DirectStream duration propagation

## [1.6.3] - 2026-06-16
### Fixed
- Follow/Unfollow button restored in show feed with correct offset correction

## [1.6.2] - 2026-06-16
### Fixed
- Episode click opened wrong item when Follow button was present (index shift)

## [1.6.1] - 2026-06-16
### Fixed
- Search results opened wrong item — Material Skin re-request offset bug
- Show save/remove uses correct `me/shows` endpoints instead of unified `me/library`

## [1.6.0] - 2026-06-15
### Added
- Podcast support: browse saved shows, search podcasts, play episodes
- Show details with episode list, explicit content markers
- Follow/Unfollow shows via library actions
- Episode info view with lazy-load show navigation
- Play/Queue/Favorites buttons on track and episode items (songinfo)
- 27 new i18n string keys across 11 languages for podcast UI
- TROUBLESHOOTING.md and enhanced GitHub issue templates

### Changed
- Date and duration formatting refactored to `cstring()` for full i18n support

## [1.5.1] - 2026-06-15
### Fixed
- Docker: daemon uses actual LMS server address instead of hardcoded `127.0.0.1`
- Docker: mDNS discovery routes through LMS host with loopback fallback guard
- Connect reconnect: reset `current_track` on Stopped event to prevent silent playback
- Player Settings now distinguishable from Server Settings in sidebar

### Added
- Credential pre-check before Connect daemon start (prevents crash-loop)
- Built-in diagnostic system: enable in Settings, download diagnostic bundle
- DIAG logging across all modules (Client, TokenManager, Connect, Daemon, ProtocolHandler)
- Clickable link from Server Settings to active player's SpotOn settings
- Settings split into separate server and player settings classes

## [1.5.0] - 2026-06-14
### Added
- Podcast API foundation: `getShow`, `getShowEpisodes`, `getSavedShows`, `search(type=show,episode)`
- Podcast browse: saved shows list, show detail with episodes, podcast search
- `user-read-playback-position` scope for episode resume points
- Setup guide hint in 11 languages

### Fixed
- Dark theme: replaced hardcoded light-theme colors with `rgba`/opacity
- Publisher display: embedded in show name for Default skin compatibility

## [1.4.3] - 2026-06-13
### Fixed
- Deduplicated discovery UI entries
- String test coverage aligned with actual keys

## [1.4.2] - 2026-06-13
### Fixed
- Account switcher UX with add-account discovery feedback
- CI conditional Rust build (skip rebuild when only Perl changes)

## [1.4.1] - 2026-06-12
### Fixed
- Like/Unlike Material Skin compatibility and state display
- Release binary naming collision (platform suffix added)

### Added
- Auto-build plugin ZIP in CI release job

## [1.4.0] - 2026-06-11
### Added
- macOS Universal Binary (Intel + Apple Silicon) via CI `lipo` + ad-hoc codesign
- `Helper.pm` auto-detects macOS and selects `Bin/darwin/spoton`
- Gatekeeper hint on Settings page for macOS users (11 languages)
- macOS build jobs in CI pipeline

## [1.3.0] - 2026-06-10
### Added
- Like/Unlike button for tracks and albums
- Connect credential isolation (per-player cache directories)
- Connect volume sync between Spotify and LMS

## [1.1.0] - 2026-06-06
### Added
- Multi-arch binary distribution (6 Linux targets + Windows)
- Stream metadata in Songinfo (mode, format, bitrate)
- Connect-DSTM (Don't Stop The Music) with Spirc-native autoplay
- Track history with artwork and async re-fetch
- `spoton://` URI scheme for Spotty coexistence
- 11-language i18n, Setup Guide, Credits
- Production deployment with monitoring

## [1.0.0] - 2026-06-03
### Added
- Initial release: Browse, Search, Library via OPML menus
- Single-track streaming with 5 format modes (Auto/OGG/PCM/FLAC/MP3)
- Spotify Connect with bidirectional controls and sync groups
- ZeroConf + Dual-Token Auth (one-click setup via Spotify app)
- Per-player settings (bitrate, format, Connect toggle, Autoplay toggle)
- mDNS discovery for Spotify Connect visibility

[Unreleased]: https://github.com/stiefenm/spoton/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/stiefenm/spoton/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/stiefenm/spoton/compare/v1.9.1...v2.0.0
[1.9.1]: https://github.com/stiefenm/spoton/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/stiefenm/spoton/compare/v1.7.8...v1.9.0
[1.6.3]: https://github.com/stiefenm/spoton/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/stiefenm/spoton/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/stiefenm/spoton/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/stiefenm/spoton/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/stiefenm/spoton/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/stiefenm/spoton/compare/v1.4.3...v1.5.0
[1.4.3]: https://github.com/stiefenm/spoton/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/stiefenm/spoton/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/stiefenm/spoton/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/stiefenm/spoton/compare/v1.3.4...v1.4.0
[1.3.0]: https://github.com/stiefenm/spoton/compare/v1.1...v1.3.0
[1.1.0]: https://github.com/stiefenm/spoton/compare/v1.0.0...v1.1
[1.0.0]: https://github.com/stiefenm/spoton/releases/tag/v1.0.0
