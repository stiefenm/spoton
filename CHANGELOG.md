# Changelog

All notable changes to SpotOn will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
