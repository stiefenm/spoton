---
phase: 75-api-unification-spclient-modell
plan: 06
subsystem: api
tags: [spclient, login5, d-08, perl, browse, uat]

# Dependency graph
requires:
  - phase: 75-02
    provides: "SpClient album/artist/show/search facades (getAlbum, getAlbumTracks, getArtist, getArtistAlbums, getShow, getShowEpisodes, getEpisode, search) this plan's caller switch consumes"
  - phase: 75-05
    provides: "SpClient playlist family (getUserPlaylists, getPlaylistItems) completing the full 16-method facade surface this plan switches callers onto"
provides:
  - "Plugins::SpotOn::API::SpClient -- 13 Web-API-only passthrough delegations (getLimit, getMe, getTopTracks, getPersonalMixes, saveTracks, removeTracks, checkTracks, saveShows, removeShows, checkShows, addToPlaylist, getWebPlayerPlaylistItems, pathfinderHome), completing SpClient as a full drop-in for every non-player Client.pm method"
  - "All ~70 Browse/Search/Library call sites in Plugin.pm/ProtocolHandler.pm/Connect.pm/DontStopTheMusic.pm switched to the SpClient facade (D-08); player control (playerPlay/Pause/Volume/Seek) and probe machinery (reset/probeEndpointLimits/limitsProbed) remain Client.pm-backed"
  - "tools/spclient-smoke.pl -- standalone LMS-free UAT script (login5 mint + metadata/4/track fetch + rootlist fetch)"
affects: []

# Actuals (#2632)
actuals:
  tokens: 17350
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Web-API-only passthrough delegation: a one-line runtime-require + forward-@_ sub on SpClient for every Client.pm method with no spclient equivalent (writes/contains ops, getTopTracks/getPersonalMixes/pathfinderHome/getWebPlayerPlaylistItems, getMe, getLimit) -- makes the facade a complete drop-in so the caller switch is a mechanical class-name rename, not a rewrite"
    - "Mechanical caller switch with an explicit exception list: sed-based `Plugins::SpotOn::API::Client->` -> `Plugins::SpotOn::API::SpClient->` across all four consumer files, then surgically reverting the 3 probe-machinery calls (reset/probeEndpointLimits/limitsProbed) and the 4 player-control calls (playerPlay/Pause/Volume/Seek) back to Client.pm -- proven correct via exact-string equality gates on the post-switch grep output, not just an absence check"
    - "Standalone dev-tool duplication over module reuse: tools/spclient-smoke.pl duplicates SpClient.pm's idToHex/hexToId math and Login5.pm's LoginRequest field layout instead of requiring those modules, because both have compile-time Slim::* dependencies incompatible with an LMS-free script (ProtobufLite.pm is the only production module reused, since it was deliberately kept dependency-free for this exact purpose)"
    - "curl -K config file for secret headers: the smoke script never passes the Authorization Bearer header via -H argv (visible in ps/proc), routing all headers through a 0600 temp curl config file instead -- extends the plan's stdin-only body-secret discipline (T-75-19) to the token as well"

key-files:
  created:
    - tools/spclient-smoke.pl
  modified:
    - Plugins/SpotOn/API/SpClient.pm
    - Plugins/SpotOn/Plugin.pm
    - Plugins/SpotOn/ProtocolHandler.pm
    - Plugins/SpotOn/Connect.pm
    - Plugins/SpotOn/DontStopTheMusic.pm
    - t/11_track_history.t
    - t/14_context_menu.t
    - t/15_streaming_mode.t
    - t/36_spclient.t
    - CHANGELOG.md

key-decisions:
  - "getLimit passthrough reads through to Client.pm's %_detectedLimits/%_blockedEndpoints probe cache rather than duplicating it on SpClient -- probe-machinery cleanup is explicitly deferred to Phase 76/77, so ALL getLimit call sites (not just the 3 reset/probeEndpointLimits/limitsProbed calls) switch to SpClient, with SpClient transparently forwarding to the same underlying Client.pm state"
  - "Connect.pm's D-08 boundary is call-level, not file-level: only the two _fetchTrackMetadata getTrack references (one call, one comment) switch to SpClient; the four playerPlay/Pause/Volume/Seek calls in _sendControlFallback stay on Client.pm exactly as D-08 defines Client.pm as the player-control home"
  - "t/11/t/14/t/15's API::Client stubs were fully renamed to API::SpClient (package, write_stub call, require, all package-variable/sub references) rather than adding a parallel SpClient stub alongside -- the plan's own instruction ('the stub replaces it entirely') and confirmation that no other Client.pm functionality is exercised in those three files"
  - "Smoke script routes the Bearer token through a curl -K config file (not -H argv) in addition to the plan-mandated stdin body passthrough -- closes an argv/ps exposure gap the plan's T-75-19 mitigation text didn't explicitly call out for the token, verified live against httpbin.org that curl's config-file header syntax behaves identically to -H"

requirements-completed: [D-06, D-08]

coverage:
  - id: D1
    description: "Every Browse/Search/Library call site in Plugin.pm, ProtocolHandler.pm, Connect.pm, and DontStopTheMusic.pm dispatches through Plugins::SpotOn::API::SpClient, including the _doLibraryAction dynamic method dispatch ($apiMethod)"
    requirement: D-08
    verification:
      - kind: other
        ref: "grep equality gate: Plugin.pm's remaining API::Client-> calls are exactly {limitsProbed, probeEndpointLimits, reset}; ProtocolHandler.pm/DontStopTheMusic.pm have zero API::Client-> calls; fixed-string grep confirms API::SpClient->$apiMethod present and API::Client->$apiMethod absent in Plugin.pm"
        status: pass
    human_judgment: false
  - id: D2
    description: "Connect.pm's player-control calls (playerPlay/playerPause/playerVolume/playerSeek) remain on Client.pm; only the _fetchTrackMetadata getTrack call switched to SpClient"
    requirement: D-08
    verification:
      - kind: other
        ref: "grep equality gate: Connect.pm's remaining API::Client-> calls are exactly {playerPause, playerPlay, playerSeek, playerVolume}"
        status: pass
    human_judgment: false
  - id: D3
    description: "SpClient exposes 13 Web-API-only passthrough delegations (getLimit, getMe, getTopTracks, getPersonalMixes, saveTracks, removeTracks, checkTracks, saveShows, removeShows, checkShows, addToPlaylist, getWebPlayerPlaylistItems, pathfinderHome), each forwarding the exact argument list to Client.pm, including via dynamic method-name dispatch"
    requirement: D-08
    verification:
      - kind: unit
        ref: "t/36_spclient.t (delegation matrix: 13 methods, each asserted to call Client.pm exactly once with identical arguments; dynamic dispatch test mirrors Plugin.pm's _doLibraryAction $SP->$m(...) pattern)"
        status: pass
    human_judgment: false
  - id: D4
    description: "Plugin.pm's initPlugin resets SpClient and Login5 state alongside the existing Client.pm reset (plugin-reload safety)"
    requirement: D-08
    verification:
      - kind: other
        ref: "source assertion: Plugin.pm initPlugin calls Plugins::SpotOn::API::Client->reset(), Plugins::SpotOn::API::SpClient->reset(), and Plugins::SpotOn::API::Login5->reset() consecutively"
        status: pass
    human_judgment: false
  - id: D5
    description: "tools/spclient-smoke.pl exists, compiles standalone (no LMS modules required), never prints the Bearer token or auth_data (length/expiry only), and exits non-zero with a stage-labelled message on any failure"
    verification:
      - kind: unit
        ref: "perl -c tools/spclient-smoke.pl (clean); manual runs against a synthetic credentials.json exercising the args/creds/mint failure stages, each producing the expected FAIL [stage]: message and non-zero exit"
        status: pass
    human_judgment: false
  - id: D6
    description: "A real login5 mint + spclient metadata/4/track fetch + rootlist fetch against a live paired Spotify account succeeds end-to-end via tools/spclient-smoke.pl, and a Connect session survives a full Browse session with no audio-key throttle regression (D-09 Rapid-Skip watch)"
    human_judgment: true
    rationale: "No paired Spotify account is reachable in this environment (Phase 73/75-01..75-05 precedent). The script's control-flow (arg parsing, credentials.json validation, protobuf encode/decode, curl invocation, stage-labelled failure/exit) is verified against a synthetic credentials.json exercising every pre-network failure stage, and a real login5 network round-trip WAS exercised live (login5.spotify.com correctly rejected the synthetic auth_data with a HashCash-challenge response, proving the protobuf wire format and curl plumbing work against the real endpoint) -- but a full success path (valid stored credentials, real metadata/rootlist data, and the Connect-session audio-key regression watch) requires a human with a real paired account, tracked as mandatory phase UAT per this plan's own <verification> section."

# Metrics
duration: ~15min
completed: 2026-08-29
status: complete
---

# Phase 75 Plan 06: SpClient Caller Switch + UAT Smoke Script Summary

**All ~70 Browse/Search/Library call sites in Plugin.pm/ProtocolHandler.pm/Connect.pm/DontStopTheMusic.pm now dispatch through the SpClient facade (D-08), with 13 new Web-API-only passthrough delegations completing SpClient as a full Client.pm drop-in, plus a standalone LMS-free UAT smoke script**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-08-29T09:05:17Z
- **Completed:** 2026-08-29T09:19:47Z
- **Tasks:** 3
- **Files modified:** 10 (1 created, 9 modified)

## Accomplishments

- `SpClient.pm` gained 13 one-line passthrough delegations (`getLimit`, `getMe`, `getTopTracks`, `getPersonalMixes`, `saveTracks`, `removeTracks`, `checkTracks`, `saveShows`, `removeShows`, `checkShows`, `addToPlaylist`, `getWebPlayerPlaylistItems`, `pathfinderHome`) for every Web-API-only operation with no spclient equivalent -- library writes/contains stay on the Web API (collection/v2 write is deferred), the remaining four have no verified spclient equivalent, and `getLimit` reads through to Client.pm's existing probe-detected limits. This makes SpClient a complete drop-in for every non-player Client.pm method, proven by a 13-method delegation matrix test plus a dynamic method-name dispatch test mirroring Plugin.pm's `_doLibraryAction` pattern.
- Every data/limit/library call site in `Plugin.pm` switched to `Plugins::SpotOn::API::SpClient`, including the `_doLibraryAction` dynamic dispatch target (`$apiMethod`) -- proven by an exact-string equality gate showing the ONLY remaining `API::Client->` calls are the three probe-machinery methods (`reset`, `probeEndpointLimits`, `limitsProbed`), which D-08 keeps on Client.pm as deferred Phase 76/77 cleanup.
- `ProtocolHandler.pm` (9 call sites: `getAlbum`, `getAlbumTracks`, `getPlaylistItems`, `getShowEpisodes`, `getEpisode`, `getTrack`, plus 3 `getLimit` calls) and `DontStopTheMusic.pm` (5 call sites: `search` x2, `getTopTracks`, `getLimit` x2) switched entirely to SpClient -- zero remaining `API::Client->` references in either file.
- `Connect.pm`'s D-08 boundary is enforced at call level: only the `_fetchTrackMetadata` `getTrack` call switched to SpClient; the four `playerPlay`/`playerPause`/`playerVolume`/`playerSeek` calls in `_sendControlFallback` remain Client.pm-backed exactly as D-08 designates Client.pm the player-control home -- proven by the same equality-gate technique (remaining calls are EXACTLY the four player-control methods, nothing more, nothing less).
- `Plugin.pm`'s `initPlugin` now resets `SpClient` and `Login5` state alongside the existing `Client.pm` reset, closing a plugin-reload staleness gap for the two new modules.
- `t/11_track_history.t`, `t/14_context_menu.t`, and `t/15_streaming_mode.t` had their `Plugins::SpotOn::API::Client` stubs (serving `getTrack` / `pathfinderHome` + `getWebPlayerPlaylistItems`) fully renamed to `Plugins::SpotOn::API::SpClient` to match the switched consumers -- all pre-existing assertions in those files still pass unchanged, just against the renamed package.
- `tools/spclient-smoke.pl`: a new standalone, LMS-free dev/UAT script that mints a login5 Bearer token from a librespot-format `credentials.json` (mirroring `Login5.pm`'s protobuf field layout, reusing `ProtobufLite.pm` directly), then fetches one track's metadata via `metadata/4/track/{hex}` and the account's rootlist via `playlist/v2/user/{username}/rootlist`, proving the whole login5+spclient chain end to end without a running LMS instance. Compiles clean (`perl -c`) with zero LMS module dependencies; the Bearer token and decoded `auth_data` are never printed (length/expiry only); both the login5 request body and every Authorization header route through stdin / a 0600 `curl -K` config file (never `-H` argv) via `IPC::Open3` list-form exec, so no secret ever appears in `ps`/`/proc/<pid>/cmdline`. A live run against this environment (with synthetic credentials) confirmed the script correctly reaches `login5.spotify.com`, encodes/decodes the protobuf wire format, and reports a clean stage-labelled failure (`FAIL [mint]: ... HashCash challenge ...`) with a non-zero exit -- the full happy path requires a real paired account (mandatory UAT).
- `CHANGELOG.md` Unreleased section documents the spclient unification (up-to-20-result search, restored `popularity`/`label` metadata, unpaged Liked Songs, Web-API fallback) and corrects the Phase 74 `spoton-helper` entry now that its `protobuf` subcommand is removed (superseded by `ProtobufLite.pm`, Plan 03) -- no version bump, `repo.xml`/`install.xml` untouched (release procedure stays user-approved).
- `Client.pm`/`Settings.pm`/`Status.pm`/`API/TokenManager.pm` verified byte-identical (`git diff --stat` empty) after every task commit -- D-03 isolation and the out-of-scope file list both hold.
- Full test suite: 36 files, 1648 tests, all green (`t/36_spclient.t` alone: 233 tests, up from 75-05's 202-test baseline).

## Task Commits

Each task was committed atomically:

1. **Task 1: Passthrough delegations on SpClient (Web-API-only operations)** - `3d6fb70` (feat)
2. **Task 2: Switch the browse consumers to the facade (D-08)** - `915f49c` (feat)
3. **Task 3: UAT smoke script + CHANGELOG** - `eca3b4c` (feat)

## Files Created/Modified

- `Plugins/SpotOn/API/SpClient.pm` - Added 13 passthrough delegation subs (getLimit, getMe, getTopTracks, getPersonalMixes, saveTracks, removeTracks, checkTracks, saveShows, removeShows, checkShows, addToPlaylist, getWebPlayerPlaylistItems, pathfinderHome) with a header comment documenting the per-method rationale
- `Plugins/SpotOn/Plugin.pm` - All data/limit/library call sites switched to SpClient (including `_doLibraryAction`'s dynamic dispatch); `initPlugin` now also resets SpClient and Login5
- `Plugins/SpotOn/ProtocolHandler.pm` - All 9 Browse/Library call sites (album/album-tracks/playlist-items/show-episodes/episode/track + 3 getLimit calls) switched to SpClient
- `Plugins/SpotOn/Connect.pm` - Only the `_fetchTrackMetadata` getTrack call switched; player-control calls untouched
- `Plugins/SpotOn/DontStopTheMusic.pm` - All 5 call sites (search x2, getTopTracks, getLimit x2) switched to SpClient
- `t/11_track_history.t`, `t/14_context_menu.t`, `t/15_streaming_mode.t` - API::Client stubs renamed to API::SpClient to match switched consumers
- `t/36_spclient.t` - Extended Client stub with call-recording for all 13 new passthrough methods; added a 13-method delegation matrix test plus a dynamic method-name dispatch test (31 new tests total)
- `tools/spclient-smoke.pl` (new) - Standalone LMS-free login5 + spclient UAT script
- `CHANGELOG.md` - Unreleased entry for the spclient unification; corrected the Phase 74 spoton-helper entry (protobuf subcommand removed)

## Decisions Made

- `getLimit` reads through to Client.pm's existing probe-detected limits rather than duplicating that state on SpClient -- ALL `getLimit` call sites (not just the 3 kept-on-Client methods) switch to SpClient, which transparently delegates.
- Connect.pm's D-08 split is enforced at call level, not file level -- only `_fetchTrackMetadata`'s single `getTrack` call switches; the four player-control calls in `_sendControlFallback` stay on Client.pm.
- t/11/t/14/t/15's Client stubs were fully renamed to SpClient stubs (not duplicated alongside a retained Client stub) since no other Client.pm functionality is exercised in those three files.
- The smoke script routes the Bearer token through a `curl -K` config file (not `-H` argv) in addition to the plan's mandated stdin body passthrough, closing an argv/ps exposure gap for the token that the plan's T-75-19 text only explicitly named for the body.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Bearer token routed through a curl config file instead of `-H` argv**
- **Found during:** Task 3 (UAT smoke script)
- **Issue:** The plan's T-75-19 mitigation explicitly calls out passing the login5 body via stdin so `auth_data` never appears in argv/`ps`, but doesn't address the Bearer token used in the two authenticated GET requests (metadata/rootlist) -- passing it via `-H "Authorization: Bearer $token"` would put the live token into the process's argv, visible via `ps aux`/`/proc/<pid>/cmdline` for the (brief) lifetime of the curl subprocess.
- **Fix:** All curl headers (not just the POST body) route through a 0600 temporary `curl -K` config file (`header = "..."` lines) instead of `-H` flags, verified live against httpbin.org to behave identically to `-H`. The config file is deleted immediately after each curl invocation.
- **Files modified:** tools/spclient-smoke.pl
- **Verification:** Live smoke-test run against a synthetic credentials.json confirms identical stage-labelled behavior with the config-file approach; manual curl comparison against httpbin.org/headers confirmed header delivery is unchanged.
- **Committed in:** eca3b4c (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical -- security hardening beyond the plan's literal text, in the same spirit as the plan's own T-75-19 discipline)
**Impact on plan:** Strictly additive security hardening; no scope creep, no behavior change to the script's actual UAT function.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- D-08 (full spclient unification) is now complete: every Browse/Search/Library call site in the four consumer files dispatches through SpClient, with automatic fallback to Client.pm for PKCE-only accounts and any spclient-side failure. Player control and probe machinery remain correctly isolated on Client.pm.
- `tools/spclient-smoke.pl` is ready for the mandatory live UAT pass (`/gsd-verify-work` on the dev machine with a paired account): mint a token, fetch a track, fetch the rootlist, then manually browse Liked Songs/Saved Albums/search/a playlist in LMS while a Connect session plays, watching for the D-09 Rapid-Skip regression ("error audio key 0 2" in daemon stderr).
- Probe machinery (`reset`/`probeEndpointLimits`/`limitsProbed` on Client.pm) and the `getLimit` probe-cache itself remain intentionally deferred cleanup for Phase 76/77, as scoped by this plan.
- Live verification of the spike-unverified `metadata/4/show`/`metadata/4/episode` shapes (75-02) and the rootlist decorate-response field layout (75-05) remain open mandatory-UAT items, now directly exercisable via this plan's smoke script plus a manual Browse/Connect session.
- No blockers.

## Self-Check: PASSED

- All modified/created files verified present on disk with the expected final content
- All 3 task commit hashes (`3d6fb70`, `915f49c`, `eca3b4c`) verified in `git log`
- All 5 `must_haves.truths` re-verified: `prove -l t/36_spclient.t` green (233 tests); full `prove t/` (36 files, 1648 tests) green; the plan's exact equality-gate verify command (Task 2) re-run and passing; `perl -c tools/spclient-smoke.pl` clean; `grep -qi spclient CHANGELOG.md` true
- `git diff --stat` confirmed empty for `Client.pm`, `Settings.pm`, `Status.pm`, `API/TokenManager.pm` (out-of-scope files untouched)
- `DontStopTheMusic.pm` (not covered by t/05_perl_syntax.t's stub list) manually verified to `require` cleanly under a minimal ad-hoc stub set after the caller switch

---
*Phase: 75-api-unification-spclient-modell*
*Completed: 2026-08-29*
