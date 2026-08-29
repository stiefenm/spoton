---
gsd_state_version: 1.0
milestone: v4.0
milestone_name: Soloist Integration
current_phase: 75
current_phase_name: API Unification (spclient-Modell)
status: executing
stopped_at: Completed 75-04-PLAN.md
last_updated: "2026-08-29T08:49:27.537Z"
last_activity: 2026-08-29
last_activity_desc: Phase 75 execution started
state_head: 74b1b2f17417aefbe979d2fa8b2b077b701182c5
progress:
  total_phases: 14
  completed_phases: 3
  total_plans: 23
  completed_plans: 21
  percent: 21
---

# Project State: SpotOn

**Project:** SpotOn — LMS Spotify Plugin
**Initialized:** 2026-05-26
**Mode:** yolo

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-30)

**Core Value:** Reliable Spotify playback and Connect integration on LMS — Browse, stream, and control via Spotify app, without 429 bursts, zombie daemons, or audio glitches.

**Current Focus:** Phase 75 — API Unification (spclient-Modell)

## Current Position

Phase: 75 (API Unification (spclient-Modell)) — EXECUTING
Plan: 5 of 6
Status: Ready to execute
Last activity: 2026-08-29 — Phase 75 execution started

## Progress Bar

```
v4.0 Soloist Integration: [██████████░░░░░░░░░░░░░░░░░░] 3/7 phases (71-77)
Phase 71: [x] Soloist Foundation (BYOK, Fake-libpulse, Helper Backend-Switch)
Phase 72: [x] Soloist Browse Playback (--single-track, Audio Pipeline)
Phase 73: [x] Soloist Connect Mode (WebSocket API, Transfer-Playback)
Phase 74: [ ] spoton-helper Binary (Rust: token+daemon+patch+audio)
Phase 75: [ ] API Unification (Drei-Host-Modell, SpClient.pm, HashSource)
Phase 76: [ ] Soloist UX Polish (Quality, Per-Player, Pairing, Diagnostics)
Phase 77: [ ] Soloist UAT + Release (Final Proof: kein librespot nötig)
```

<details>
<summary>Prior milestones</summary>

- v2.3: Phase 37 shipped (CTX-01), Phases 38-41 deferred to v5.0
- v3.0: Phases 49-53 shipped (Auth Overhaul)
- v3.x: Phases 54-70 shipped (Point releases through v3.5.8)

</details>

## Performance Metrics

**Historical velocity (reference):**

- v2.0: 9 phases, 16 plans in 9 days (~1.8 plans/day)
- v2.1: 2 phases, 2 plans in 1 day
- v1.5: 4 phases, 6 plans in 2 days (~3 plans/day)
- v1.0: 15 phases, 50 plans in 9 days (~5-6 plans/day)

**Per-Plan Metrics:**

| Plan | Duration | Tasks | Files |
|------|----------|-------|-------|
| Phase 53 P01 | 10min | 2 tasks | 2 files |
| Phase 53 P02 | 8min | 2 tasks | 4 files |
| Phase 53 P03 | 14min | 3 tasks | 6 files |
| Phase 54 P01 | 12min | 2 tasks | 3 files |
| Phase 54 P03 | 15min | 2 tasks | 1 files |
| Phase 54 P02 | 15min | 2 tasks | 4 files |
| Phase 54 P04 | 3min | 2 tasks | 1 files |
| Phase 54 P05 | ~2h | 3 tasks | 8 files |
| Phase 55 P02 | 45min | 2 tasks | 5 files |
| Phase 56 P01 | 20min | 2 tasks | 6 files |
| Phase 57 P01 | ~15min | 2 tasks | 4 files |
| Phase 60 P01 | 4min | 3 tasks | 2 files |
| Phase 61 P01 | 5min | 3 tasks | 4 files |
| Phase 61 P02 | 3min | 2 tasks | 5 files |
| Phase 63 P01 | 2min | 3 tasks | 2 files |
| Phase 63 P02 | 4min | 6 tasks | 4 files |
| Phase 64 P01 | 16min | 2 tasks | 3 files |
| Phase 65 P01 | 13m | 3 tasks | 6 files |
| Phase 65 P02 | 14m | 3 tasks | 7 files |
| Phase 65 P03 | 10m | 3 tasks | 9 files |
| Phase 65 P04 | 12m | 3 tasks | 8 files |
| Phase 65 P05 | 5min | 2 tasks | 1 files |
| Phase 70 P01 | ~25min | 2 tasks | 2 files |
| Phase 70 P04 | 5min | 2 tasks | 3 files |
| Phase 70 P02 | ~20min | 2 tasks | 1 files |
| Phase 70 P03 | ~15min | 3 tasks | 2 files |
| Phase 70 P05 | 4m | 1 tasks | 1 files |
| Phase 72 P01 | ~13min | 3 tasks | 11 files |
| Phase 72 P02 | ~15min | 2 tasks | 4 files |
| Phase 72 P03 | ~10min | 2 tasks | 2 files |
| Phase 73 P01 | ~35min | 3 tasks | 24 files |
| Phase 73 P02 | ~10min | 3 tasks | 7 files |
| Phase 73 P03 | ~35min | 3 tasks | 6 files |
| Phase 73 P04 | ~40min | 3 tasks | 13 files |
| Phase 73 P05 | 35min | 2 tasks | 3 files |
| Phase 73 P06 | 20min | 2 tasks | 2 files |
| Phase 74 P01 | 20min | 3 tasks | 11 files |
| Phase 74 P02 | 8min | 2 tasks | 3 files |
| Phase 74 P03 | 25min | 2 tasks | 16 files |
| Phase 74 P04 | 20min | 3 tasks | 7 files |
| Phase 75 P01 | 20min | 3 tasks | 7 files |
| Phase 75 P02 | ~30min | 3 tasks | 2 files |
| Phase 75 P03 | 10min | 2 tasks | 6 files |
| Phase 75 P04 | ~35min | 3 tasks | 2 files |

## Deferred Items

Items carried forward from previous milestones:

| Category | Item | Status |
|----------|------|--------|
| debug | connect-reconnect-no-audio | awaiting_human_verify |
| uat | Phase 16 macOS Binary (3 scenarios) | deferred (no macOS test env) |
| Phase 49 P01 | 18min | 2 tasks | 3 files |
| Phase 49 P02 | 18min | 2 tasks | 5 files |
| Phase 50 P01 | 25min | 2 tasks | 3 files |
| Phase 50 P02 | 12min | 2 tasks | 5 files |
| Phase 50 P03 | 20min | 2 tasks | 6 files |
| Phase 51 P01 | 8min | 2 tasks | 3 files |
| Phase 51 P02 | 9min | 3 tasks | 3 files |
| Phase 51 P03 | 13min | 2 tasks | 4 files |
| Phase 52 P01 | 4min | 3 tasks | 5 files |
| Phase 52 P02 | 12min | 2 tasks | 3 files |
| Phase 52 P03 | 4min | 3 tasks | 6 files |
| Phase 52 P04 | 3min | 2 tasks | 2 files |
| Phase 52 P05 | 3min | 2 tasks | 3 files |
| Phase 52 P06 | 12min | 2 tasks | 7 files |

## Accumulated Context

### Decisions

- [v2.3]: Importer follows OnlineLibraryBase pattern (Spotty, Qobuz, TIDAL, Deezer)
- [v2.3]: me/tracks returns full objects — no individual entity fetches needed
- [v2.3]: Incremental sync via added_at early-exit (Spotty doesn't have this)
- [v2.3]: Scanner uses SimpleSyncHTTP (blocking OK in scanner process)
- [v2.3]: Token routing: Own ID via Keymaster, fallback to bundled on 403
- [v2.3]: PKCE-only is the Golden Path — replaces ZeroConf/Keymaster as single auth mechanism
- [v2.3]: ~~Phase 48 is a bridge (login5 fallback), not the target architecture~~ SUPERSEDED → v3.0
- [v2.3]: Keymaster is dying — 403s widespread since Aug 2025
- [v2.3]: login5 rejects Developer App IDs — Dual-Token architecture is dead
- [v3.0]: Auth Overhaul — PKCE + sp_dc/Pathfinder. 7 spikes validated 2026-07-04. Phase 48 archived.
- [v3.0]: PKCE-first confirmed as correct direction (urknall agrees given Extended Quota Client ID)
- [v3.0]: ZeroConf stays as feature (mDNS guest-discovery), no longer an auth mechanism
- [v3.0]: Discovery ON by default — --disable-discovery is per-player option, not default
- [v3.0]: Callback URI via GitHub Pages static relay (stiefenm.github.io/spoton/auth/), state parameter with LMS callback URL + nonce
- [v3.0]: Login5 fallback declined (Login5 gets immediate 429 on api.spotify.com)
- [v3.0]: Desktop Client ID OAuth declined (ToS risk, unnecessary with Extended Quota)
- [v3.0]: go-librespot = token/control reference only, NOT audio backend replacement (Rust librespot stays for OGG passthrough, Connect sinks, rate-limiting — go-librespot lacks these)
- [v3.0]: Keymaster audit must distinguish 4 buckets: (1) Real Keymaster Service (hm://keymaster/token/authenticated), (2) Old Keymaster Client-ID used as platform identity hint, (3) Login5 path, (4) PKCE path
- [v3.0]: UAT gate is specifically "hm://keymaster/token/authenticated must NOT appear in normal logs" — not "string Keymaster appears anywhere" (client-ID-as-identity references are fine to keep)
- [v3.0]: Login5 already used by Rust librespot internally for spclient HTTP (not just session bootstrap) — supports our architecture where librespot handles its own session auth
- [v3.0]: OAuth-token-authenticated sessions cannot use Keymaster service (confirms credential derivation approach is correct — PKCE tokens must be converted to stored credentials for Connect)
- [v3.0]: 7 PKCE implementation edge cases (urknall #176): (A) code_verifier must never appear on GitHub Pages — stays in LMS Settings handler only, (B) static relay uses window.location navigation not fetch — CORS-safe, (C) callback redirect target restricted to RFC1918/loopback/.local addresses, (D) copy-paste fallback when redirect fails, (E) v2/PKCE account mismatch detection needed (existing ZeroConf creds from different account than PKCE login), (F) guest ZeroConf must not overwrite primary PKCE-derived credentials, (G) refresh-token expiry (6 months inactivity) needs first-class UX with re-auth prompt
- [v3.0]: sp_dc/Pathfinder as "best effort" — TOTP rotation, graceful degradation, re-scrape on failure
- [v3.0]: urknall's 11 success criteria as UAT gates (central: no hm://keymaster/token/authenticated in normal logs)
- [v3.0]: Audit phase (49-00) before implementation — classify every Keymaster reference into the 4 buckets
- [v3.0]: ~~AUDIO KEY DEAD END (2026-07-13)~~ **RETRACTED (2026-07-13):** woorszt (#115) confirms PKCE restores full audio playback on his Keymaster-403-affected account. Dead end was specific to newest-cohort test accounts only. Three-tier model: (1) unaffected = spclient path, (2) mid-cohort (Keymaster 403, audio keys work via PKCE) = v3.0 fixes everything, (3) newest-cohort (Keymaster 403 + audio key denied) = needs future audio backend research. Mid-cohort is the relevant target population.
- [v3.0]: Phase 49-00 Audit slim — Grep+Klassifikation der 4 Keymaster-Buckets, kein Research. Direkt danach Phase 49 PKCE.
- [v3.0]: Audio key denial (newest cohort) tracked in #91, kein eigenes Issue — Population noch unklar
- [v3.0]: **librespot Audio Pipeline analysiert (2026-07-13):** Kein Branching — BEIDE Pfade (CDN storage-resolve + AudioKeyManager RequestKey 0x0c) werden IMMER für jeden Track aufgerufen. CDN liefert AES-128-CTR-verschlüsselte Bytes, Audio Key ist der Entschlüsselungsschlüssel. Kein client-seitiger Workaround möglich — AP entscheidet serverseitig ob Key rausgegeben wird. Newest-cohort-Fix erfordert komplett anderes Audio-Backend.
- [Phase 49]: Added PKCE.pm to t/05_perl_syntax.t syntax-check list to keep CI coverage consistent with sibling API modules (TokenManager.pm, Client.pm)
- [Phase 49]: Reused TokenManager::_storeAccountPrefs for PKCE account creation instead of duplicating prefs-writing logic in Settings.pm
- [Phase 49]: Fallback userId on /me lookup failure derived from access_token hash, not a fixed literal, to avoid account-collision across concurrent failed lookups
- [Phase 49]: PKCE OAuth result page HTML-escapes all interpolated values (attacker-controlled error query param reflected into HTML)
- [Phase 50]: [Phase 50-01]: getToken loses the $flavor parameter entirely (D-04) -- single PKCE token per account
- [Phase 50]: [Phase 50-01]: needsReauth cache flag uses explicit 'never' TTL (M-1) -- DbCache defaults to 1h, would otherwise silently expire
- [Phase 50]: [Phase 50-01]: refreshAllTokens calls _refreshToken directly, not getToken (M-5) -- forces real refresh, keeps refresh_token alive against Spotify 6-month expiry
- [Phase 50]: [Phase 50-02]: D-04 completion -- Client.pm flavor system deleted entirely (single PKCE token per account, single spoton_rate_limit cache key, 2-arg getToken call site)
- [Phase 50]: [Phase 50-02]: M-7 (Settings.pm still reads old rateLimitedOwn/rateLimitedBundled keys) intentionally deferred to Plan 03, not fixed here
- [Phase 50]: [Phase 50-03]: D-08 completion -- OPML (Channel 1) + Settings (Channel 2) re-auth warnings wired via anyAccountNeedsReauth(); all ZeroConf discovery-as-auth code removed from Plugin.pm/Settings.pm/basic.html (D-01), including _autoSetupAccount + __DISCOVER__ fallback (M-3); Add Another Account repointed to spotonPkceStart() XHR (M-2)
- [Phase 51]: [51-01] D-05 rate-limit counter only counts real derivation-attempt failures (spawn_failed/derivation_failed), not pre-flight gate skips (no_token/no_binary/binary_too_old)
- [Phase 51]: [51-01] accountMismatch reads credentials.json via a raw parse independent of verifyCredentials's auth_type==1 validation
- [Phase 51]: [51-02] diagnosticMode OFF now truncates the same per-daemon stderr file on every start instead of routing to devnull -- simplest fix for Pitfall 1 (stderr must be readable for D-03 crash classification in the default configuration)
- [Phase 51]: [51-02] D-08 mismatch repair and D-01 lazy safety-net both gated on non-empty activeAccountId (Pitfall 4) -- legacy flat-dir credential setups untouched, D-10 cleanup deferred to Phase 53
- [Phase 51]: [51-02] _handleCredentialCrash only escalates markNeedsReauth for 'derivation_failed' -- 'no_token' is already flagged internally by TokenManager, avoiding a duplicate 4-channel warning
- [Phase 51]: [51-03] D-06 daemon start is unconditional on derivation success, deliberately bypassing _storeAccountPrefs's first-account-only $needsDaemonStart conditional -- closes Pitfall 6 for Add Another Account / re-auth flows
- [Phase 51]: [51-03] Failure branch never reflects the raw derivation $reason into the user-facing page (T-51-10) -- only the fixed PLUGIN_SPOTON_CONNECT_DERIVE_FAILED string is rendered, masked accountId in logs
- [Phase 51]: [51-03] Success messaging deferred until after derivation completes -- one unified D-02 signal, resolving RESEARCH Open Question 2
- [Phase 52]: [52-01] state()/statusSnapshot() default to 'valid' when sp_dc is present and no negative state is cached -- mirrors TokenManager::needsReauth's innocent-until-proven-guilty default
- [Phase 52]: [52-01] SecretSource validation is fail-closed on the WHOLE xyloflake payload -- any single anomaly anywhere rejects everything, never a partial fallback to a lower valid version
- [Phase 52]: [52-02] pathfinderHome() and getWebPlayerPlaylistItems() bypass the shared _request/_doFlavouredRequest pipeline entirely -- dedicated SimpleAsyncHTTP calls keep the WebPlayer->getToken-not-TokenManager source assertion literally true and avoid touching the 40+ existing PKCE call sites
- [Phase 52]: [52-02] PATHFINDER_HOME_HASH_DEFAULT ships as an explicit UNVERIFIED PLACEHOLDER, not a fabricated-looking SHA256 -- degrades cleanly (Pitfall 4) until a real hash is captured during manual UAT
- [Phase 52]: [52-03] sp_dc unchanged-resubmit check compares the raw trimmed submitted value against the masked preview BEFORE charset sanitization strips the placeholder's asterisks -- sanitizing first would make every resubmit look changed and overwrite the stored cookie
- [Phase 52]: [52-03] sp_dc save reuses the standard saveSettings form POST (like pref_clientId), not a dedicated AJAX endpoint -- no new _csrfCheck surface needed
- [Phase 52]: [52-04] _playlistItem/_playlistFeed gained an opts/passthrough webPlayer flag rather than a duplicate _madeForYouPlaylistFeed sibling -- single-sources the play-all/pagination/cache/_trackItem pipeline for both PKCE and Web-Player playlist access (Pitfall 3)
- [Phase 52]: [52-04] Made For You playlist items are labelled by raw Spotify ID, not a human-readable name -- pathfinderHome (Plan 02) only extracts/validates IDs, no name/image metadata; documented as a Known Stub, out of this plan's Plugin.pm-only file scope
- [Phase 52]: [Phase 52] [52-05] Left previously cached state untouched on transient mint failure rather than introducing a 5th state enum value -- simplest CR-02 fix, no downstream consumer needs new handling
- [Phase 52]: [52-06] Hash resolution is prefs-first; WP_GQL_HASH_CACHE_KEY left unused (reserved for future auto-scrape, not this plan's scope)
- [Phase 52]: [52-06] sp_dc clear guarded by hasSpDc() check to avoid pointless storeSpDc('', '') calls on accounts that never had a cookie
- [Phase ?]: [Phase 53]: [53-01] D-07/D-08 confirmed as planned — Mode::GetToken/run_get_token clean-cut removal, KEYMASTER_CLIENT_ID cosmetic rename to DISCOVERY_CLIENT_ID in both main.rs and unified.rs, no deviations
- [Phase ?]: [Phase 53]: [53-02] _doRequest kept (not _executeRequest) -- matches existing _request naming pair already in Client.pm
- [Phase ?]: [Phase 53]: [53-02] New i18n keys placed adjacent to nearest thematic sibling block in strings.txt rather than a single new trailing block -- easier future discoverability
- [Phase ?]: [Phase 53]: [53-02] AUTH-06 (Login5 fallback) marked dropped in REQUIREMENTS.md -- Login5 gets immediate 429 on api.spotify.com, PKCE is sole API auth path; AUTH-07 left open pending Plan 03
- [Phase ?]: [Phase 53]: [53-03] accountNeedsMigration composes Credentials::credentialsPathFor + PKCE::loadTokens per D-05's literal formula, not the stricter verifyCredentials check
- [Phase ?]: [Phase 53]: [53-03] OPML migration hint checks only the active account; Settings banner checks anyAccountNeedsMigration (all accounts) -- deliberate asymmetry, migration hint takes precedence over the reactive reauth hint
- [Phase ?]: [Phase 53]: [53-03] Propagated $err through 2 internal pagination helpers (_fetchAllFollowedArtists, _fetchAllPages) with no inline NO_RESULTS construction of their own, so their 4 outer done-consumers call _authRequiredItem instead
- [Phase ?]: [Phase 54]: [54-01] classifyAudioKeyError placed directly after isCredentialError, denial signature checked before throttle signature so denial wins when both present
- [Phase ?]: [Phase 54]: [54-01] DaemonManager audio-key cache write only on state change (write-guard) and never on undef classification -- preserves a denied state that scrolled out of the bounded stderr tail
- [Phase ?]: [Phase 54]: [54-01] last-API-call timestamp written only in getToken's cache-hit branch (single write site), deliberately excluding _refreshToken's success path to avoid conflating token-refresh-cycle-alive with actual API usage
- [Phase ?]: [Phase 54]: [54-03] Playlist Play-All root cause confirmed via runtime DIAG logging — LMS core leaves quantity=undef for CLI-driven play commands (Material Skin), heuristic >=500 unreachable on that path; user chose Option D (broaden heuristic to !defined(quantity) || quantity>=500) for Plan 04 to implement
- [Phase ?]: [Phase 54]: [54-02] _collectAuthHealth is self-contained (requires own collaborators) so it can be unit-tested directly without a full handler() invocation
- [Phase ?]: [Phase 54]: [54-02] Connect indicator prefers the first alive daemon helper matching an account, falling back to the first helper found at all if none are alive
- [Phase ?]: [Phase 54]: [54-02] lastApiCall rendered as relative time entirely client-side (data-epoch attribute + inline JS) rather than server-formatted, avoiding a new date-formatting dependency in the TT template
- [Phase ?]: [Phase 54]: [54-04] Option D implemented exactly as specified: isPlayAll = !defined(quantity) || quantity>=500, applied uniformly across all 4 feed functions (_savedTracksFeed, _showFeed, _albumFeed, _playlistFeed); index/quantity defaults switched from || to // (defined-or)
- [Phase ?]: [Phase 54][54-05] v2-legacy branched from main HEAD, not the v2.3.18 tag -- tag's repo.xml had stale SHA/URL pointing at v2.3.17 asset
- [Phase ?]: [Phase 54][54-05] repo.xml version bumped to 3.0.0 with URL/SHA intentionally still pointing at v2.3.18 -- safe only because main stays unpushed until explicit release approval
- [Phase ?]: [Phase 54][54-05] User decided post-checkpoint to relocate the Auth Health Dashboard from Settings page to Status page (3 follow-up commits: 16f5cde, c6eea81, 2b1ff22)
- [Phase ?]: [Phase 54][54-05] CHANGELOG.md [3.0.0] Changed entry corrected from 'Settings page' to 'Status page' to match dashboard relocation (Rule 1 auto-fix)
- [Phase ?]: [Phase 55][55-03] Seed IDs for artist_albums/album_tracks/playlist_items probes fetched via dedicated real API calls (search limit=1, me/playlists limit=1), not reused from binary-search intermediate responses -- final converged binary-search value has no guaranteed fresh response body
- [Phase ?]: [Phase 55][55-03] Probe error classification: 400=retry (binary search continues), 403=blocked (limit=0, class isolated), 401=auth_abort (stops entire chain), everything else=skip (keep default, continue) -- only 401 aborts the full probe chain
- [Phase ?]: D-01..D-06: bundled Client-ID Settings UX wired per 55-CONTEXT.md, no deviations from documented design
- [Phase ?]: [Phase 56][56-01] Metadata cache writes in _trackItem/_albumTrackItem/_episodeItem keep raw (possibly empty) $image -- only the OPML display hash gets the fallback, so cached NowPlaying/history artwork reflects what Spotify actually returned
- [Phase ?]: [Phase 56][56-01] Made For You skipped as a HomeExtra candidate -- its feed renders a textarea hint when sp_dc is missing, which would show as a junk row in a Material Skin scrolled list
- [Phase ?]: [Phase 56][56-01] HomeExtraBase.initPlugin passes the feed coderef directly (no OPML.pm-style menu-param wrapper) since SpotOn's _recentlyPlayedFeed/_topTracksFeed already match the ($client, $callback, $args) signature Plugins::MaterialSkin::HomeExtraBase expects
- [Phase ?]: [Phase 57][57-01] Both Made For You _homeFeed push sites (expired + normal branch) get the same madeforyou.png image key -- missing either would silently break the grid/cover toggle depending on sp_dc state
- [Phase ?]: [Phase 57][57-01] toptracks.png copied unmodified from Spotty; recently.png + madeforyou.png generated fresh via throwaway PIL script (4x oversample + LANCZOS downscale, LA mode) since Spotty has no equivalent icons
- [Phase ?]: Single-type failure fails the whole overview (consistent with previous combined-call behavior)
- [Phase ?]: Daemon lifecycle intentionally NOT signaled by HomeExtras refresh() -- rows carry no daemon-derived content, clearing memoization on restarts would trigger redundant API refetch bursts
- [Phase ?]: Sort at both ends (Perl getAccountIds + JS renderAuthHealth) for deterministic Status page account order (GH #138)
- [Phase ?]: undefined digitalVolumeControl treated as enabled (LMS ClientV5 default=1) -- no behavior change for players that never stored the pref (GH #137)
- [Phase ?]: Material Skin text-click coercion requires no type key on OPML items — omitting type matches Spotty/Qobuz pattern
- [Phase ?]: Static localized group suffix replaces composed syncname for daemon stability (GH #143)
- [Phase ?]: [Phase 64][64-01] PassthroughMixer relies on librespot's Mixer trait default (NoOpVolume) rather than overriding get_soft_volume() -- the omission IS the GH #144 fix
- [Phase ?]: [Phase 64][64-01] --volume-ctrl CLI flag kept as an accepted no-op in main.rs for backward compatibility with pre-PassthroughMixer Daemon.pm during mixed-version installs
- [Phase ?]: GH #147: playback-auth flag is a separate cache key (spoton_needs_playback_auth_), never TokenManager needsReauth — keeps Web API working while playback is broken
- [Phase ?]: GH #147 D-04: all automatic PKCE credential derivation removed; deriveCredentials retained callerless for plan 65-03 Keymaster fallback
- [Phase ?]: Pairing test file is t/24_player_auth.t (t/22 number already taken by audio_key_classifier)
- [Phase ?]: _installPairedCredentials fails closed (account_mismatch) when the account has no spotifyUserId (D-01)
- [Phase ?]: playbackAuthState 'required' also covers fresh PKCE auth without credentials.json, not only the crash-escalation flag
- [Phase ?]: Symmetric cross-flow nonce guard: regular PKCE handlers reject playerauth-purposed nonces so a Keymaster token pair can never clobber pkce_tokens.json (T-65-13)
- [Phase ?]: t/09 derivation ban refined to negative lookahead (?!FromToken) — bans automatic derivation, permits the user-initiated Keymaster path
- [Phase ?]: Keymaster-PKCE is the primary auth path (amends D-02): one authorization yields Web API tokens AND auto-derived playback credentials; ZeroConf pairing and browser fallback remain as fallbacks
- [Phase ?]: Auto-derivation is provenance-gated: fires only for Keymaster-minted tokens at user-initiated auth completion; custom-ID tokens never derive (D-04 preserved)
- [Phase ?]: HYPOTHESIS FAILED: Mercury Keymaster 403 'Invalid client' even with ZeroConf-paired credentials — Keymaster service is server-side restricted for this account/cohort, independent of credential provenance. Plans 65-06..65-08 must not execute.
- [Phase 70]: [Phase 70][70-01] _fetchAllPages kept as public sub name, reduced to a one-line delegating wrapper around _fetchPages -- all 7 existing play-all call sites need zero changes
- [Phase 70]: [Phase 70][70-01] apiFn closure hoisted above the if/elsif/else in _savedTracksFeed so play-all and bounded-fill branches share one getSavedTracks wrapper instead of duplicating it
- [Phase 70]: [Phase 70][70-01] Deferred metadata cache flush (FIX-01 protocol) applied to the bounded-fill else-branch too, matching the play-all branch, since a 210-item fill has the same synchronous-SQLite-write risk
- [Phase 70]: [Phase 70][70-04] Cherry-picked (-n) icon assets from reverted phase-69-attempt-1 commit 30f8b7b rather than regenerating -- already PIL-contract-verified on that branch; CHANGELOG wording reused verbatim from 964f18c, #131 sync-group line deliberately excluded (reverted scope)
- [Phase 70]: [Phase 70][70-02] _playlistFeed else-branch pageLimit switched to Client->getLimit('playlist_items') (probe-aware, defaults 100) -- play-all branch keeps its existing literal 100 pageLimit unchanged
- [Phase 70]: [Phase 70][70-02] _playlistFeed else-branch gained the same FIX-01 deferred metadata cache flush the play-all branch already had -- 210-item bounded fill has same synchronous-SQLite-write risk
- [Phase 70]: [Phase 70][70-02] _showFeed's advertised total computed from helper's safeTotal (API coordinates) plus Follow-item offset, not a raw API total -- preserves JVL-06 clamping and pre-existing Follow-button total+1 semantics simultaneously
- [Phase 70]: [Phase 70][70-03] _multiTypeSearch (overview aggregator) left untouched -- confirmed via git diff, no hunk touches it during search feed conversion
- [Phase 70]: [Phase 70][70-03] _albumFeed offset==0 branch only converts to _fetchPages when quantity exceeds embedded getAlbum seed tracks AND album has more -- preserves zero-extra-API-call short-circuit for typical browse loads
- [Phase 70]: [Phase 70][70-03] SpotOnAddToPlaylist error path kept as NO_RESULTS textarea (not _authRequiredItem) -- matches its pre-existing distinct error convention
- [Phase 72]: [Phase 72][72-01] Launcher wrapper (not findbin token/symlink) generated at cachedir/spoton/soloist/spoton-soloist -- only mechanism that can set LD_LIBRARY_PATH, keep the spak-key off argv, and resolve a cachedir-resident binary from a static convert-rule token
- [Phase 72]: [Phase 72][72-01] D-06 retry/skip implemented at the wrapper (shell) level, not via LMS's BROWSE_404_RETRY logic -- that logic is HTTP-status-driven and has no equivalent on the pipe-based transcoder path
- [Phase 72]: [Phase 72][72-01] FLAC target declared --bps=32 (not 24) -- Soloist emits S32LE and flac cannot down-convert; true 24-bit deferred to Phase 74 HiFi enum patch
- [Phase 72]: [Phase 72][72-02] Two duplicate-id #librespot-fields divs (Account Player Auth block + Global Binary/Bitrate/Streaming/Normalization block) toggled together via querySelectorAll, not one contiguous div -- the two D-07 librespot-only groups are not DOM-adjacent once Backend is promoted above Account
- [Phase 72]: [Phase 72][72-02] helperMissing (librespot binary-missing warning) suppressed when backend=soloist -- D-07 hides librespot-specific state under Soloist
- [Phase 72]: [Phase 72][72-02] Pairing-status block (paired/not-paired + exact --pair command) nested inside the existing spak-key WRAPPER rather than a new titled WRAPPER -- no dedicated pairing-block title string in the plan's new-strings list
- [Phase 72]: [Phase 72][72-03] WR-01 resolved via the verification gap's sanctioned documented-trade-off branch (not a code fix) -- soloist 1.3.7.489's --help and binary strings confirm -k/--api-key is the only key mechanism, no env/stdin alternative exists
- [Phase 72]: [Phase 72][72-03] Translation loop uses argc/argi/a variable names to avoid colliding with the D-06 retry loop's n/rc/start/now/elapsed in the same launcher heredoc
- [Phase 73]: [Phase 73][73-01] Vendored Protocol::WebSocket 0.26 verbatim from the real LMS 9.2 install tree (unifying its CPAN/+lib/ split layout) into Plugins/SpotOn/Vendor/ -- ensureWsLib() prefers an LMS-bundled copy (push, not unshift) so Soloist Connect works on LMS 8.0+ with no version gate (D-08)
- [Phase 73]: [Phase 73][73-01] SoloistDaemon is a separate lifecycle class parallel to Daemon.pm rather than an extension of it -- structural differences (two ports, no credentials.json gate, per-player dirs, LD_LIBRARY_PATH env) outweigh code reuse; _streamAlivePoll's librespot-only blocks are isa-gated instead of duplicating the poll loop
- [Phase 73]: [Phase 73][73-01] resolvePassthroughForClient short-circuits to 0 for backend=soloist as the first statement -- Phase 73 is S16LE-PCM-only end to end via fake-libpulse HTTP mode, sox/OGG formats land in Phase 74
- [Phase 73]: [Phase 73][73-02] _sendControlCommand resolves the backend via DaemonManager->helperForClient + isa('...::SoloistDaemon') rather than a prefs read -- the object owning the WS connection is the single source of truth for which transport is live
- [Phase 73]: [Phase 73][73-02] Exit-code-10 (Pitfall 7 build expiry) permanently parks the soloist daemon via a 'never'-TTL cache flag instead of feeding CRASH_BACKOFF; Soloist::_versionCheck's success path self-heals the flag
- [Phase 73]: [Phase 73][73-03] Wave-0 spike filed DEFERRED — no paired daemon/Spotify app reachable in this environment; browse advance/correction implemented against RESEARCH-default assumptions, live spike tracked as mandatory UAT (WINDOWS.md)
- [Phase 73]: [Phase 73][73-03] Pitfall-4 corrective play() retargets to browseCurrentUri (never the next LMS entry) — only the seeded-match advance branch is ever allowed to move the LMS playlist pointer
- [Phase 73]: [Phase 73][73-03] Soloist Browse now serves through the SAME daemon /stream endpoint Connect uses (not a per-track URL) — D-03 Modell B
- [Phase 73]: [Phase 73][73-04] Settings.pm's isPaired()/launcherPath() calls fixed inline during Task 1 (Rule 3) to keep prove -l t/ green, not deferred to Task 3 which replaces them fully
- [Phase 73]: [Phase 73][73-04] Sync-group pinning found no gap in DaemonManager.pm/SoloistDaemon.pm -- Pattern 7's librespot-to-soloist 1:1 transfer confirmed via tests against the real module, zero production code changed
- [Phase 73]: [Phase 73][73-04] WS auth state shown via daemon-status color coding, not a 5th new i18n key; actual 11-language set verified as CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV (PL not FI) against strings.txt before translating
- [Phase 73]: SoloistWS.pm D-05/D-06 gap closure: utf8::encode bridge for octet-mode from_json, int() coercion for numeric sendCommand params, sessionPaused-gated resume emission with frozen extrapolation while paused
- [Phase 74]: spoton-helper Cross.toml scoped to exactly the 3 target arches (x86_64/aarch64/armv7 musl) the plan named, not the 6-target librespot-spoton superset
- [Phase 74]: tests/fixture.rs uses a minimal hand-rolled Drop-based TempDir instead of an external tempdir crate, keeping spoton-helper's dependency surface at exactly clap/serde_json/sha2/anyhow/thiserror
- [Phase 74]: Patch patterns: empty public stub table + private build-time injection from stiefenm/spoton-private (Task 1, option b) — no plaintext byte-patterns in public source
- [Phase 74]: run_core testable-core / thin-wrapper split lets unit tests drive the full safety envelope with a TEST-ONLY pattern table while patch::run keeps its Plan-01 signature
- [Phase 74]: protobuf_cmd.rs: no new crate for JSON mapping — hand-rolled struct->serde_json::Value conversion instead of adding protobuf-json-mapping, to avoid a second package-manager install requiring its own supply-chain checkpoint
- [Phase 74]: build.rs lists all 12 vendored proto files as .input()s, not just the 4 schema roots — protobuf-codegen .pure() emits super::<module> refs for imported types rather than inlining them
- [Phase 74]: Helper CI artifacts use helper-<arch> prefix (never spoton-helper-<arch>) to avoid colliding with librespot's spoton-* fold-in glob
- [Phase 74]: build-spoton-helper runs unconditionally on tag/workflow_dispatch, no detect-changes gate (compiles in seconds, must never be stale)
- [Phase 74]: Private pattern injection is a guarded CI step keyed on repo secrets that do not yet exist -- shipped binary presently always keeps the public empty patterns.rs table
- [Phase 74]: _autoPatch in Soloist.pm is unconditionally fail-open: any incomplete/failed patch logs a warning and Soloist continues unpatched, never blocking playback
- [Phase 75]: [Phase 75][75-01] parse_fields collects every field occurrence into an arrayref (never overwrite) -- fixes RESEARCH.md's last-item-wins sample so collection/v2 repeated items decode completely
- [Phase 75]: [Phase 75][75-01] SpClient.pm runtime-require's Login5/Credentials/Client (never compile-time use) -- extends D-03's no-compile-time-coupling guarantee to all three collaborators, not just Client.pm
- [Phase 75]: [Phase 75][75-01] D-07a single 401 remint-retry implemented exactly as user-approved: one retry with a fresh token, second 401 falls back to Client.pm immediately
- [Phase 75]: [Phase 75][75-02] _spFacade's normalize callback receives (rawResult, $cb) rather than returning a value -- lets the same D-06/D-07 helper serve sync normalizers (getAlbum/getArtist/getShow/getEpisode) and async ones that fan out enrichment (getAlbumTracks/getShowEpisodes)
- [Phase 75]: [Phase 75][75-02] getAlbum's tracks.items always empty (S-04) -- getAlbumTracks owns all per-track enrichment via metadata/4/track
- [Phase 75]: [Phase 75][75-02] search() context-resolve routing checks the hardcoded 20-result ceiling before any HTTP call, then re-checks against the actual returned URI count -- avoids wasted calls for offsets that can never be satisfied
- [Phase 75]: [Phase 75][75-02] getShow/getShowEpisodes/getEpisode mirror the verified album/track pattern for the spike-unverified metadata/4/show and metadata/4/episode paths -- D-07's 4xx/5xx fallback is the accepted mitigation, live verification deferred to mandatory phase UAT
- [Phase 75]: [Phase 75][75-03] No CI workflow change needed -- build-spoton-helper job has no protobuf-specific step; cross build naturally builds fewer crates now that protobuf/protobuf-codegen are removed (D-02)
- [Phase 75]: [Phase 75][75-03] proto/README.md documents collection2v2.proto as the field-number reference for collection/v2 paging (ProtobufLite.pm's parse_fields consumers); other 11 files documented as the same kind of reference for their endpoints, all retained as documentation-only per D-02
- [Phase 75]: [Phase 75][75-04] getSavedTracks has NO play-all-specific shortcut -- play-all reuses the same method via _fetchAllPages, and the cached complete URI list already makes every page cheap regardless of mode
- [Phase 75]: [Phase 75][75-04] getSavedShows probes the FIRST slice item's metadata/4/show fetch before enriching the rest -- a fallback-classified probe error routes the WHOLE call to Client.pm in one shot, avoiding N per-item fallback roundtrips
- [Phase 75]: [Phase 75][75-04] getFollowedArtists emulates the Web-API cursor contract (after=last-artist-id) by resolving position in the cached collection/v2 list, matching exactly what _fetchAllFollowedArtists consumes
- [Phase 75]: [Phase 75][75-04] _enrichCollectionSlice is distinct from 75-02's _enrichMeta because it must re-pair each result with its original added_at, which _enrichMeta's filter-undefs shape would lose
- [Phase 75]: [Phase 75][75-04] getRecentlyPlayed pairs lastPlayedTime by the ORIGINAL request uri, not the enriched track's returned uri, to guard against relinked/canonicalized track uris

### Blockers/Concerns

- Forum #143 (plasticator2): Audio distortion on Pi 4B + HiFiBerry Digi2 Pro SPDIF — log analysis pending
- ~~PR #104 (urknall): Release year metadata — review pending~~ MERGED, shipped in v2.3.8
- Forum #159 (Chezza): New Spotify account (Oct 2025) → NoStoredCredentials, urknall + CJS helping
- ~~Forum #160 (CJS): "Default Adjustment for Remote Streams" stacks with SpotOn ReplayGain~~ FIXED in v2.3.12: trackGain() implemented (GH #108)
- ~~Wait for urknall's response to auth architecture reply (#175)~~ RESOLVED: urknall #176 confirmed PKCE-first, provided edge cases and Keymaster audit guidance
- Auth architecture research completed — details not in this repo.
- Soloist skip: ~8s audio-reconnect gap after flush-disconnect (root cause unknown) -- see WINDOWS.md entry #5, .planning/quick/260827-of9-.../260827-of9-SUMMARY.md. Follow-up requested by user: build automated audio-level test rig for Connect edge cases instead of manual CDP+listening.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260709-bsx | Diagnostik + Daemon-Stabilität Verbesserungen | 2026-07-09 | e714019 | [260709-bsx](./quick/260709-bsx-diagnostik-daemon-stabilitaet-verbesseru/) |
| 260713-bg4 | Keymaster 403 account check script for affected users | 2026-07-13 | 9aef195 | [260713-bg4](./quick/260713-bg4-keymaster-403-account-check-script-for-a/) |
| 3 | Keymaster Token Usage Audit (4-bucket classification) | 2026-07-13 | e50fc26 | — |
| 260718-rpy | Dev Mode playlist/library item schema fix (#119) | 2026-07-18 | 26e8c1a | [260718-rpy](./quick/260718-rpy-dev-mode-playlist-schema-fix/) |
| 260723-awc | Fix #117: Decouple Connect Autoplay from DSTM provider | 2026-07-23 | a3c18dd | [260723-awc](./quick/260723-awc-fix-117-decouple-connect-autoplay-from-d/) |
| 260723-fkg | Fix #126: Connect seek/change progress bar resync | 2026-07-23 | 5d91cd8 | [260723-fkg](./quick/260723-fkg-fix-126-connect-seek-change-progress-bar/) |
| 260727-a1w | HomeExtra rows Main Menu + Playlists for Material Skin (#132) | 2026-07-27 | 93630bb | [260727-a1w](./quick/260727-a1w-add-homeextra-scrolled-rows-for-material/) |
| 260817-ana | Fix #149 + #150: Daemon resilience on AP drops (idle guard + key timeout) | 2026-08-17 | 4ba5247 | [260817-ana](./quick/260817-ana-daemon-resilience-ap-drops/) |
| 260818-qaw | Fix #155: Auto-retry on 429 in Client.pm | 2026-08-18 | a3a972a | [260818-qaw](./quick/260818-qaw-fix-155-auto-retry-on-429-in-client-pm/) |
| 260818-v1l | Fix #155 follow-up: 429 deferral + rate-limited UX + logging | 2026-08-18 | 60a5ffb | [260818-v1l](./quick/260818-v1l-fix-155-rate-limited-local-visibility/) |
| 260827-jqa | Fix position drift on Connect device transfer-away/back (deactivating guard + re-sync seek) | 2026-08-27 | f0c9bf7 | [260827-jqa](./quick/260827-jqa-fix-position-drift-on-connect-device-tra/) |
| 12 | Fix Soloist Connect skip ~30s delay (skipInitiated + playlist-play-on-skip + flush-disconnect); live-verified: LMS metadata switches in ~1.16s, but audio-level ~8s reconnect gap found and deferred | 2026-08-27 | 6c40526 | — |

## Session Continuity

**Resume file:** None

**Last session:** 2026-08-29T08:49:13.247Z
**Stopped at:** Completed 75-04-PLAN.md

**Completed this session (2026-08-24):**

- ROADMAP Milestones aufgeräumt: v2.0, v2.1, v2.2, v3.0 als shipped markiert
- Sensitive Referenzen aus .planning/ entfernt (eSDK, private Kontakte, SynologyDrive)
- v4.0 Soloist Integration Milestone eingetragen
- **Soloist Spike — alle Hypothesen validiert:**
  - Lifetime Patch: ASCII-Timestamp in .rodata, Drop-in-Replace, "25696 days"
  - Audio Interface: Fake-libpulse.so.0 (47 PA-Funktionen, 250 LOC C) → S32LE/44100/Stereo direkt via pa_stream_write, kein PulseAudio-Server nötig
  - BYOK: spak-Key Self-Service im Dev Dashboard, Pairing + Single-Track + Connect funktionieren
  - Audio Pipeline: PCM → FLAC (68%) und OGG (10%) via ffmpeg, gleiche Pipeline wie librespot
- spak-Key ist offiziell Self-Service seit Soloist Launch (2026-08-13)
- Drei Plattformen verfügbar: x86_64, arm64, arm32

**Next action:**

1. v2.3 Library Integration (Phases 38–41) — core milestone work untouched
2. v4.0 Soloist (Phases 71-75) — Spike complete, ready for Phase 71 wenn priorisiert
3. Phase 62 (Browse Endpoints + Connect Queue) remains unplanned
4. Monitor PR #1748 upstream, #149/#150 (Rouzax)

---
*State initialized: 2026-05-26*
*Last updated: 2026-08-24 — Soloist Spike validated, v4.0 milestone concretized*
