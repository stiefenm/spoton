---
gsd_state_version: 1.0
milestone: v2.3
current_phase: 70
status: completed
stopped_at: Phase 70 complete — all phases complete
last_updated: "2026-08-22T18:10:36.066Z"
last_activity: 2026-08-22
last_activity_desc: Phase 70 complete
state_head: f73f42d0272e0084f8c6ceb76f2be26e087a07e4
progress:
  total_phases: 38
  completed_phases: 14
  total_plans: 72
  completed_plans: 68
milestone_name: Library Integration
---

# Project State: SpotOn

**Project:** SpotOn — LMS Spotify Plugin
**Initialized:** 2026-05-26
**Mode:** yolo

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-30)

**Core Value:** Reliable Spotify playback and Connect integration on LMS — Browse, stream, and control via Spotify app, without 429 bursts, zombie daemons, or audio glitches.

**Current Focus:** Phase 70 — JiveLite Pagination Fill (GH #157)

## Current Position

Phase: 70
Plan: Not started
Status: All phases complete
Last activity: 2026-08-22 — Phase 70 complete

## Progress Bar

```
v2.3 Library Integration: [░░░░░░░░░░░░░░░░░░░░] 0/5 phases (37-41)
Phase 37: [x] Context Menu LMS Items (CTX-01)
Phase 38: [ ] Importer Foundation (LIB-06, TOK-01, TOK-02, CFG-01)
Phase 39: [ ] Album + Artist Import (LIB-02, LIB-03, LIB-07, LIB-09)
Phase 40: [ ] Liked Songs + Incremental Sync (LIB-01, LIB-04, LIB-05, LIB-08)
Phase 41: [ ] Playlist Import (PL-01, PL-02, CFG-02)

Side phases (independent):
Phase 42: [x] OGG Vorbis Passthrough (OGG-01..03)
Phase 43: [x] Connect OGG Passthrough (OGG-04)
Phase 44: [x] Connect OGG Rate-Limiting (OGG-05)
Phase 46: [x] Code Review Bugfixes (30 findings)
Phase 48: [~] SUPERSEDED by v3.0 Auth Overhaul (2026-07-04)

v3.0 Auth Overhaul (Phases 49-53, shipped v3.0.0):
Phase 49-00: [x] Token Usage Audit + Backend Evaluation
Phase 49: [x] PKCE OAuth Flow (AUTH-01, AUTH-02)
Phase 50: [x] Perl TokenManager Rewrite (AUTH-03)
Phase 51: [x] Credential Derivation + Connect (AUTH-04, AUTH-05)
Phase 52: [x] sp_dc + Pathfinder Integration (Made for You)
Phase 53: [x] Keymaster Removal + Migration (AUTH-06, AUTH-07)

Post-v3.0 (shipped):
Phase 54: [x] Auth Health Dashboard
Phase 55: [x] Bundled Client ID UX
Phase 56: [x] Material Skin Compatibility (v3.2.0)
Phase 57: [x] Material Skin UX Polish
```

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
- [v3.0]: **librespot Audio Pipeline analysiert (2026-07-13):** Kein Branching — BEIDE Pfade (CDN storage-resolve + AudioKeyManager RequestKey 0x0c) werden IMMER für jeden Track aufgerufen. CDN liefert AES-128-CTR-verschlüsselte Bytes, Audio Key ist der Entschlüsselungsschlüssel. Kein client-seitiger Workaround möglich — AP entscheidet serverseitig ob Key rausgegeben wird. Newest-cohort-Fix erfordert komplett anderes Audio-Backend (v4.0/spoton-private).
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

### Blockers/Concerns

- Forum #143 (plasticator2): Audio distortion on Pi 4B + HiFiBerry Digi2 Pro SPDIF — log analysis pending
- ~~PR #104 (urknall): Release year metadata — review pending~~ MERGED, shipped in v2.3.8
- Forum #159 (Chezza): New Spotify account (Oct 2025) → NoStoredCredentials, urknall + CJS helping
- ~~Forum #160 (CJS): "Default Adjustment for Remote Streams" stacks with SpotOn ReplayGain~~ FIXED in v2.3.12: trackGain() implemented (GH #108)
- ~~Wait for urknall's response to auth architecture reply (#175)~~ RESOLVED: urknall #176 confirmed PKCE-first, provided edge cases and Keymaster audit guidance
- Auth architecture research completed — details in private notes (SynologyDrive), not in this repo.

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

## Session Continuity

**Resume file:** None

**Last session:** 2026-08-22T18:06:15.887Z
**Stopped at:** Phase 70 complete — all phases complete
**Completed this session (2026-08-19):**

- Forum triage (Page 19): 4 new posts, 3 replies drafted (#273 agriff79, #274 alnames, #275 CJS)
- woOrszt #155 confirmed v3.5.7 deferral works (emoji reaction)
- **Bug found + fixed:** Rate-limit flags (`spoton_rate_limit`, `spoton_wp_rate_limit`) survived Client-ID switch → `Client->reset()` now clears them (96a6dee)
- GH #156 updated with sanitized research findings (approach, SC, pitfalls, open questions)
- **Phase 68** (OGG Metadata Strip) created in ROADMAP + `.planning/phases/`

**Next action:**

1. Phase 62 (Browse Endpoints + Connect Queue) remains unplanned
2. #154 (librespot log integration) queued as future work
3. Monitor #149/#150 (Rouzax), alnames #274 response
4. v2.3 Library Integration (Phases 38–41) — core milestone work untouched

---
*State initialized: 2026-05-26*
*Last updated: 2026-08-22 — Phase 70 added (JiveLite Pagination Fill, GH #157)*
