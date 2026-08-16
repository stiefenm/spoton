# Roadmap: SpotOn

**Project:** SpotOn — LMS Spotify Plugin
**Created:** 2026-05-26
**Granularity:** standard

## Milestones

- ✅ **v1.0 Foundation** — Phases 1-6 (shipped 2026-06-03)
- ✅ **v1.1 Hardening & Reach** — Phases 7-12 (shipped 2026-06-06)
- ✅ **v1.3 Polish & Publish** — Phases 13-16.1 (shipped 2026-06-13)
- ✅ **v1.5 Podcasts** — Phases 18-21 (shipped 2026-06-15)
- 🔄 **v2.0 Browse Daemon Migration** — Phases 28-30 (active)

## Phases

<details>
<summary>✅ v1.0 Foundation (Phases 1-6) — SHIPPED 2026-06-03</summary>

- [x] **Phase 1: Plugin Skeleton + Binary Foundation** — completed 2026-05-26
- [x] **Phase 2: Auth + API Foundation** (6/6 plans) — completed 2026-05-27
- [x] **Phase 02.1: OAuth-PKCE Browser Auth** (4/4 plans) — completed 2026-05-27
- [x] **Phase 3: Browse + Navigation** (3/3 plans) — completed 2026-05-28
- [x] **Phase 4: Single-Track Streaming** (2/2 plans) — completed 2026-05-28
- [x] **Phase 04.1: Streaming Bug Fixes + Passthrough Binary** (2/2 plans) — completed 2026-05-28
- [x] **Phase 04.2: Credentials + Made For You Fix** (2/2 plans) — completed 2026-05-29
- [x] **Phase 04.3: ZeroConf + Keymaster Auth** (4/4 plans) — completed 2026-05-29
- [x] **Phase 04.4: Dual-Token API Routing** (2/2 plans) — completed 2026-05-29
- [x] **Phase 5: Spotify Connect** (5/5 plans) — completed 2026-06-01
- [x] **Phase 05.1: Connect Audio Streaming Bugfix** (3/3 plans) — completed 2026-06-01
- [x] **Phase 05.2: Connect Controls & Resume** (2/2 plans) — completed 2026-06-01
- [x] **Phase 05.3: Sync Groups + Connect Robustness** (3/3 plans) — completed 2026-06-02
- [x] **Phase 05.4: mDNS Connect Discovery Fix** (3/3 plans) — completed 2026-06-02
- [x] **Phase 6: Polish + DSTM + Settings** (5/5 plans) — completed 2026-06-03

</details>

<details>
<summary>✅ v1.1 Hardening & Reach (Phases 7-12) — SHIPPED 2026-06-06</summary>

- [x] **Phase 7: DE→EN Code Cleanup** (1/1 plan) — completed 2026-06-03
- [x] **Phase 8: Multi-Arch Binary Distribution** (2/2 plans) — completed 2026-06-03
- [x] **Phase 9: Stream Metadata** (1/1 plan) — completed 2026-06-04
- [x] **Phase 9.5: Prod Deployment & Monitoring** (2/2 plans) — completed 2026-06-04
- [x] **Phase 10: Connect-DSTM** (3/3 plans) — completed 2026-06-04
- [x] **Phase 11: Track History Metadata** (2/2 plans) — completed 2026-06-05
- [x] **Phase 12: Protocol Handler Rename** (2/2 plans) — completed 2026-06-05

</details>

<details>
<summary>✅ v1.3 Polish & Publish (Phases 13-16.1) — SHIPPED 2026-06-13</summary>

- [x] **Phase 13: Repo Maintenance** (2/2 plans) — completed 2026-06-07
- [x] **Phase 14: Connect Fixes** (2/2 plans) — completed 2026-06-07
- [x] **Phase 15: Like Button** (2/2 plans) — completed 2026-06-11
- [x] **Phase 16: macOS Universal Binary** (2/2 plans) — completed 2026-06-11
- [x] **Phase 16.1: CI Conditional Build** (1/1 plan) — completed 2026-06-12

</details>

- ✅ **v1.5 Podcasts** — Phases 18-21 (shipped 2026-06-15) → [archive](milestones/v1.5-ROADMAP.md)

## Active

- [x] **Phase 22: Seek + Favorites Bugfixes** — completed 2026-06-17
  **Goal**: Fix seeking (duration 0:00 in seek bar) and LMS favorites (spotify: scheme statt spoton://)
  **Plans:** 1 plan

  Plans:

  - [x] 22-01-PLAN.md — Fix seek bar duration + favorites URL scheme + explodePlaylist

- [x] **Phase 23: Forum Monitor + Draft Generation** — completed 2026-07-03
  **Goal**: GitHub Action (cron) die den Lyrion-Forum-Thread pollt, neue Posts erkennt, via Claude API Draft-Replies generiert und als GitHub Issues zur Review erstellt.
  **Note**: Implemented as self-hosted runner with Playwright scraper + Claude API drafter. Scripts live on runner at /home/sti/.spoton-forum-monitor/scripts/.

- [x] **Phase 24: Forum Auto-Post** — closed 2026-07-24
  **Goal**: Label-getriggerter GitHub Action Workflow der approved Draft-Replies automatisch im vBulletin-Forum postet.
  **Note**: Closed — manual posting via SynologyDrive reply files works well enough, vBulletin automation not worth the effort.

- [x] **Phase 25: Play-All Full Pagination** — completed 2026-06-18
  **Goal**: Play-All auf Playlists, Liked Songs, Alben und Shows spielt alle Tracks ab — nicht nur die erste API-Seite (max 50/100). Reusable Paginator-Helper für alle Feed-Funktionen.
  **Plans:** 1/1 plans complete

  Plans:

  - [x] 25-01-PLAN.md — Reusable _fetchAllPages helper + integration in all four feeds + ProtocolHandler show-explode fix

- [x] **Phase 26: Browse Error Recovery + Diagnostics** — completed 2026-06-21
  **Goal**: Unavailable Tracks in Browse Mode erkennen und automatisch skippen statt endlos hängen. Diagnostic Bundle um Browse-Mode stderr erweitern.
  **Plans:** 2/2 plans complete

  Plans:

  - [x] 26-01-PLAN.md — Unavailable track detection + auto-skip
  - [x] 26-02-PLAN.md — Browse stderr capture for diagnostics

- [x] **Phase 27: Browse Pipeline Failure Recovery** — completed 2026-06-22
  **Goal**: Prefetch-Hang bei unavailable Tracks verhindern (LMS wartet auf PCM-Daten die nie kommen) und Rapid-Retry-Loop stoppen.
  **Plans:** 1/1 plans complete

  Plans:

  - [x] 27-01-PLAN.md — Prefetch watchdog + skip cache

### v2.0 Browse Daemon Migration

- [x] **Phase 28: Persistent Browse Daemon** — completed 2026-06-22
  **Goal**: Per-track `--single-track` spawning durch persistenten Browse-Daemon mit HTTP-Track-Serving ersetzen. Löst Prefetch-Hang, Audio-Key-Throttling und Log-Flood an der Wurzel.
  **Plans:** 3/3 plans complete
  Canonical refs: `.planning/notes/browse-daemon-architecture-decision.md`

  Plans:

  - [x] 28-01-PLAN.md — Browse daemon Rust implementation (HTTP server + track endpoint)
  - [x] 28-02-PLAN.md — Browse daemon lifecycle modules (DaemonManager + Daemon Perl)
  - [x] 28-03-PLAN.md — Browse-HTTP pipeline integration (ProtocolHandler + Plugin wiring)

- [x] **Phase 29: Unified Browse+Connect Daemon** (completed 2026-06-22)
  **Goal**: Browse- und Connect-Daemon in einen Prozess pro Player zusammenführen — ein librespot-Prozess mit Spirc (Connect) + HTTP Track-Endpoint (Browse) gleichzeitig. Eliminiert doppelten RAM-Overhead und Session-Koordination.
  **Plans:** 3 plans
  Canonical refs: `.planning/notes/browse-daemon-architecture-decision.md`, `.planning/seeds/evaluate-phase2-unified-daemon.md`

  Plans:

  - [x] 29-01-PLAN.md — Unified Rust daemon (unified.rs + main.rs CLI dispatch)
  - [x] 29-02-PLAN.md — Unified Perl DaemonManager + Daemon lifecycle modules
  - [x] 29-03-PLAN.md — Integration (ProtocolHandler + Plugin.pm + daemonMode pref)

- [x] **Phase 30: Legacy Pipe Cleanup** — closed 2026-07-24
  **Goal**: Remove `--single-track` mode and `son-*` transcoding pipelines. Remove `browseMode`/`daemonMode` toggle prefs. Delete Browse::DM, Browse::Daemon, Connect::DM, Connect::Daemon modules. Add rapid-skip debounce to unified.rs.
  **Plans:** 1/2 plans complete (30-02 rapid-skip debounce dropped — not needed in practice)

  Plans:

  - [x] 30-01-PLAN.md — Delete legacy Perl modules + simplify Plugin.pm/ProtocolHandler.pm/Connect.pm + remove son-* from custom-convert.conf + remove dead Rust modes
  - [ ] ~~30-02-PLAN.md~~ — dropped

### v3.0 Auth Overhaul

### Phase 49: PKCE OAuth Flow

- [x] **Phase 49: PKCE OAuth Flow** (completed 2026-07-14)
  **Goal**: Implement PKCE OAuth authorization flow — GitHub Pages static relay, LMS Settings handler for code_verifier, token exchange, refresh token storage. AUTH-01, AUTH-02.
  **Plans:** 2/2 plans complete
  Depends on: Keymaster audit (.planning/notes/keymaster-audit.md), spike findings (spike-findings-spoton skill), urknall edge cases (#176)

  Plans:

  - [x] 49-01-PLAN.md — PKCE core module (crypto, token exchange, persistence) + GitHub Pages relay page
  - [x] 49-02-PLAN.md — Settings integration (PKCE handlers, auth UI, copy-paste fallback, i18n strings)

### Phase 50: Perl TokenManager Rewrite

- [x] **Phase 50: Perl TokenManager Rewrite** (completed 2026-07-14)
  **Goal**: Replace Keymaster-based TokenManager with PKCE token management — refresh flow, expiry handling, per-player token isolation. AUTH-05.
  **Plans:** 3/3 plans complete
  Depends on: Phase 49

  Plans:

  - [x] 50-01-PLAN.md — TokenManager.pm PKCE rewrite + PKCE.pm error extension + test rewrite (review: M-1/M-4/M-5/M-6/L-1/L-4/L-6)
  - [x] 50-02-PLAN.md — Client.pm flavor removal + Status.pm/status.html fix + test updates (review: H-1/H-2/L-2/L-5)
  - [x] 50-03-PLAN.md — Integration wiring: Plugin.pm + Settings.pm + basic.html + i18n (review: M-2/M-3/M-7)

### Phase 51: Credential Derivation + Connect

- [x] **Phase 51: Credential Derivation + Connect** (completed 2026-07-14)
  **Goal**: Convert PKCE access tokens to stored credentials for librespot Connect sessions. Ensure Connect registration and audio playback work with PKCE-derived credentials. AUTH-03, AUTH-04.
  **Plans:** 3/3 plans complete
  Depends on: Phase 50

  Plans:

  - [x] 51-01-PLAN.md — Credentials.pm shared derivation module (D-01) + t/16_credentials.t (rate limiting D-05, mismatch detection D-08, error classification D-03)
  - [x] 51-02-PLAN.md — Daemon lifecycle wiring: always-on stderr capture, lazy derivation safety-net, crash auto-re-derive (D-03/D-04), D-09 verification
  - [x] 51-03-PLAN.md — Settings eager derivation (D-02/D-06) + i18n warning string + test updates

### Phase 52: sp_dc + Pathfinder Integration

- [x] **Phase 52: sp_dc + Pathfinder Integration** (gap closure) (completed 2026-07-15)
  **Goal**: Best-effort sp_dc cookie extraction + Pathfinder API for Made for You content. TOTP rotation, graceful degradation, re-scrape on failure.
  **Plans:** 6/6 plans complete
  Depends on: Phase 50

  Plans:

  - [x] 52-01-PLAN.md — WebPlayer.pm token lifecycle (SecretSource, TOTP, mint, client-token, state enum) + Wave 0 tests (D-01/D-02/D-05/D-06/D-09/D-10)
  - [x] 52-02-PLAN.md — Client.pm Pathfinder discovery + Web-Player 37i9 track fetch + separate rate pool (D-07)
  - [x] 52-03-PLAN.md — Settings sp_dc section + Status channel + i18n strings + template (D-04/D-08/D-09)
  - [x] 52-04-PLAN.md — Plugin.pm OPML Made for You feed gating + Pathfinder wiring (D-03/D-04/D-05/D-07)
  - [x] 52-05-PLAN.md — Gap closure: Fix STATE_EXPIRED over-attribution in WebPlayer mint errors (CR-02) + regression tests (WR-04)
  - [x] 52-06-PLAN.md — Gap closure: Pathfinder hash admin path via Settings (CR-01) + sp_dc clear (WR-03) + dead cache write removal (WR-02)

### Phase 53: Keymaster Removal + Migration

- [x] **Phase 53: Keymaster Removal + Migration** (completed 2026-07-16)
  **Goal**: Remove all hm://keymaster/token/authenticated code paths. Migration UX for existing ZeroConf users to PKCE. UAT gate: no Keymaster service calls in normal logs. AUTH-06, AUTH-07.
  **Plans:** 3/3 plans complete
  Depends on: Phase 49, Phase 50, Phase 51

  Plans:

  - [x] 53-01-PLAN.md — Rust binary: remove --get-token/Mode::GetToken/run_get_token(), rename KEYMASTER_CLIENT_ID
  - [x] 53-02-PLAN.md — Perl naming cleanup (Client.pm), i18n string rewrite (22+), AUTH-06 disposition
  - [x] 53-03-PLAN.md — Migration detection + OPML/Settings/feed UX wiring + Client-ID setup wizard

### Phase 54: Auth Health Dashboard

- [x] **Phase 54: Auth Health Dashboard + v3.0 Release Prep** — completed 2026-07-16
  **Goal**: Auth Health Dashboard on Status page (5 indicators per account, passive reads only; relocated from Settings during Plan 05 verification), Playlist Play-All bug fix, v2-legacy fallback branch, v3.0.0 merge to main, PKCE Migration E2E verification.
  **Plans:** 5/5 plans complete
  Depends on: Phase 52, Phase 53

  Plans:

  - [x] 54-01-PLAN.md — Audio-key classifier + dashboard backend state (last-API-call timestamp, unconditional stderr scan)
  - [x] 54-02-PLAN.md — Auth Health Dashboard UI (Settings.pm aggregation + basic.html template + i18n)
  - [x] 54-03-PLAN.md — Playlist play-all investigation (debug logging + fix decision checkpoint)
  - [x] 54-04-PLAN.md — Playlist play-all fix (implement chosen approach + cleanup)
  - [x] 54-05-PLAN.md — v2-legacy branch + v3.0 merge + version bump + PKCE E2E verification

### Phase 55: Bundled Client ID + Granular Probing

- [x] **Phase 55: Bundled Client ID + Granular Endpoint Probing** — closed 2026-07-24
  **Goal**: Enable ncspot's Extended Quota Client ID as bundled default (solves #119 playlist 403 + all Dev Mode restrictions). Add granular per-endpoint limit probing with per-class abort isolation (solves #118 artist/albums 400). Loopback redirect URI with copy-paste fallback, Settings UX for bundled vs custom ID mode, TokenManager revocation handling.
  **Note**: Deliberately parked — spike validated, plans ready, but own user Client-ID remains mandatory. See memory: project_bundled_id_parked.md
  Depends on: Phase 49, Phase 50
  See: `.planning/spikes/ncspot-bundled-id-spike.md`, `.planning/phases/55-bundled-client-id/`

### Phase 56: Material Skin Compatibility

- [x] **Phase 56: Material Skin Compatibility** (completed 2026-07-22)
  **Goal**: Fix Grid/Cover-View toggle for Playlists (#124), add Home Extras for MS home screen scrolled rows (#125), add icons to all menus. Fallback images in item builders, HomeExtras.pm module, top-level + submenu icons.
  **Plans:** 1/1 plans complete
  Depends on: None (independent)
  See: `.planning/phases/56-material-skin-compat/`

  Plans:

  - [x] 56-01-PLAN.md — Fallback images in item builders + menu icons + HomeExtras module

### Phase 57: Material Skin UX Polish

- [x] **Phase 57: Material Skin UX Polish** (completed 2026-07-23)
  **Goal**: Home feed icons for grid/cover toggle (#124), UTF-8 double-encoding fix (#125), Made For You as scrolled row (#125), upstream MS encoding issue filed. Follow-up to Phase 56.
  **Plans:** 3/3 plans complete
  Depends on: Phase 56 (completed)
  See: `.planning/phases/57-material-skin-ux-polish/`

  Plans:

  - [x] 57-01-PLAN.md — Home feed icons: 3 PNG assets + image keys on all 4 _homeFeed items
  - [x] 57-02-PLAN.md — UTF-8 double-encoding fix (Status/Settings _jsonResponse) + Made For You scrolled row
  - [x] 57-03-PLAN.md — Upstream MS encoding issue (CDrummond/lms-material#1243)

### Phase 58: Connect Position Sync Fix

- [ ] **Phase 58: Connect Position Sync Fix**
  **Goal**: Fix mid-song Connect resume position (Rust: needs_position_sync cleared too early in TrackChanged Some→Some) and relocate the change-handler notification to _fetchTrackMetadata failure paths (Perl: avoid pushing position=0 before real position is known). Fixes regression from #126 fix.
  Depends on: Phase 57 (completed), #126 fix (commit 5d91cd8)
  **Plans:** 2 plans
  Plans:

  - [ ] 58-01-PLAN.md — Perl hotfix: relocate change-handler newmetadata notify to _fetchTrackMetadata failure paths (Wave 1)
  - [ ] 58-02-PLAN.md — Rust root-cause fix: preserve needs_position_sync across TrackChanged Some→Some, consume in Playing Some→Some (Wave 1, triggers CI binary rebuild)
  See: `.planning/phases/58-connect-position-sync-fix/`

### Phase 59: Connect & Search Fixes

- [ ] **Phase 59: Connect & Search Fixes (GH #129 + #130)**
  **Goal**: Two v3.2.3 bugfixes reported by woorszt. #129: enable seek from JiveLite/LMS UIs during Spotify Connect playback — remove the `canSeek` Connect guard, but suppress the LMS-side stream restart (`getSeekData` returns undef when Connect active) and read the seek target from the request's `_newvalue` instead of stale `songTime`. #130: `_searchTypeFeed` pagination — map LMS `index` to API offset and return `offset`/`total` (same pattern as `_artistAlbumsFeed`, #121).
  Depends on: none (independent of Phase 58)
  **Plans:** 1/2 plans executed
  Plans:

  - [x] 59-01-PLAN.md — Connect seek (ProtocolHandler.pm + Connect.pm) + search pagination (Plugin.pm) + CHANGELOG (Wave 1)
  - [ ] 59-02-PLAN.md — Review finding fixes: R-1 canDoAction 'rew' guard, R-2 pause-seek-unpause documented + UAT, R-4 ignore-placeholders, R-5 error offset/total + 1000-cap; R-3 accepted as known limitation, no code fix (Wave 2)
  See: `.planning/phases/59-connect-search-fixes/`

### Phase 60: Search Single-Type & Podcast Pagination

- [ ] **Phase 60: Search Single-Type & Podcast Pagination (GH #130)**
  **Goal**: Fix search total-count discrepancy and podcast search pagination. (1) Switch `_searchFeed` and `_podcastSearchFeed` from combined multi-type API calls to parallel single-type calls so overview totals match drill-in totals (woorszt #130 observation). (2) Add full pagination to `_podcastSearchTypeFeed` (currently hardcoded offset=0, no total). (3) Backport R-4 (nameless ignore placeholders) and R-5 (1000 offset cap) to podcast search. (4) Fix duplicate `$offset` declaration in `_searchTypeFeed`.
  Depends on: Phase 59 (search pagination foundation)
  **Plans:** 1/1 plans executed
  Plans:

  - [x] 60-01-PLAN.md — _multiTypeSearch aggregator (single-type overview totals) + podcast search pagination with R-4/R-5 backport + duplicate $offset fix + CHANGELOG (Wave 1)
  See: `.planning/phases/60-search-single-type-podcast-pagination/`

## Progress Table

| Phase | Milestone | Plans | Status | Completed |
|-------|-----------|-------|--------|-----------|
| 1-6 (15 phases) | v1.0 | 50/50 | Complete | 2026-06-03 |
| 7-12 (7 phases) | v1.1 | 13/13 | Complete | 2026-06-06 |
| 13-16.1 (5 phases) | v1.3 | 9/9 | Complete | 2026-06-13 |
| 18. Podcast API Foundation | v1.5 | 1/1 | Complete | 2026-06-14 |
| 19. Podcast Browse | v1.5 | 2/2 | Complete | 2026-06-14 |
| 20. Podcast Library Actions | v1.5 | 1/1 | Complete | 2026-06-15 |
| 21. Podcast UX Polish + i18n | v1.5 | 2/2 | Complete | 2026-06-15 |
| 22. Seek + Favorites Bugfixes | — | 1/1 | Complete | 2026-06-17 |
| 25. Play-All Full Pagination | — | 1/1 | Complete | 2026-06-18 |
| 26. Browse Error Recovery | — | 2/2 | Complete | 2026-06-21 |
| 27. Pipeline Failure Recovery | — | 1/1 | Complete | 2026-06-22 |
| 28. Persistent Browse Daemon | v2.0 | 3/3 | Complete | 2026-06-22 |
| 29. Unified Daemon | v2.0 | 3/3 | Complete   | 2026-06-22 |
| 23. Forum Monitor | — | — | Complete | 2026-07-03 |
| 24. Forum Auto-Post | — | — | Closed | 2026-07-24 |
| 30. Legacy Pipe Cleanup | v2.0 | 1/2 | Closed | 2026-07-24 |
| 54. Auth Health Dashboard | v3.0 | 5/5 | Complete | 2026-07-16 |
| 55. Bundled Client ID | — | — | Parked | 2026-07-24 |

## Backlog

Items discovered during development — not assigned to a milestone.

1. **Eigene SpotOn Client-ID bei Spotify registrieren** — Blocked: Spotify requires 250k MAU + legally registered business. Extended Quota documentation deferred to future milestone.
2. **~~Online-Musiksammlung (Importer.pm / OnlineLibraryBase)~~** — Evaluiert und bewusst abgelehnt. API-Quota im Dev Mode macht Library-Scan extrem teuer; Browse > Library deckt den Use Case on-demand ab.
3. ~~**LMS Community Repo Submission**~~ — Erledigt: Plugin im Community Repo veröffentlicht.
4. ~~**ZeroConf Auth UX: "Connected" an Spotify App melden**~~ — Verworfen: Setup Guide erklärt das Verhalten, kein technischer Fix möglich ohne Playback-Session.
5. ~~**Diagnostics: "Clear Logs" Button in Settings**~~ — Implementiert in v1.7.4 (truncate on daemon restart + Clear Logs button).
6. **Spotty Favorites Migration** — Settings-Button der `spotify://` Einträge in LMS Favorites und Playlists als `spoton://` Duplikate anlegt. Originale bleiben erhalten, User kann Spotty danach deinstallieren. URI-Schema nach Prefix ist identisch (`track:ID`, `album:ID`, etc.). Idee von Paul Webster (Forum #32, 2026-06-19).

### Phase 61: Community Bugfixes (HomeExtra, Status Page, Connect Volume)

**Goal:** Fix 5 community-reported bugs: #133 HomeExtra pagination cache, #139 HomeExtra refresh signal, #138 Status Page account order, #136 account name menu refresh, #137 Connect volume-ctrl per player
**Requirements**: GH #133, #136, #137, #138, #139
**Depends on:** None (independent bugfixes)
**Plans:** 2/2 plans executed

Plans:

- [x] 61-01-PLAN.md — HomeExtra staleness + account switch: pagination-aware memoization key (#133), refresh() signal helper wired at account/auth state changes (#139), switcher returns to re-fetched main menu (#136)
- [x] 61-02-PLAN.md — Status page deterministic account order (#138), --volume-ctrl fixed for players without digital volume (#137), CHANGELOG

### Phase 62: Browse Endpoints + Connect Queue

**Goal:** Add New Releases, Genres & Moods, Featured Playlists via Extended Quota bundled Client ID (#134). Reflect Spotify Connect queue ("Up Next") in LMS/Material Skin (#135).
**Requirements**: GH #134, #135
**Depends on:** None (independent features)
**Plans:** 0 plans

Plans:

- [ ] TBD (run /gsd-plan-phase 62 to break down)

### Phase 63: Account Switcher UX + Sync Group Stability

**Goal:** Fix account switcher confirmation page behavior across all LMS client types (#136). Prevent unnecessary Connect daemon restarts when sync group membership changes (#143).
**Requirements**: GH #136, #143
**Depends on:** None (independent UX/stability fixes)
**Plans:** 2/2 plans executed

Plans:

- [x] 63-01-PLAN.md
- [x] 63-02-PLAN.md

- [ ] TBD (run /gsd-plan-phase 63 to break down)

### Phase 64: PassthroughMixer + Upstream Merge

**Goal:** Implement a PassthroughMixer in unified.rs that tracks volume and emits VolumeChanged events but always returns attenuation_factor 1.0, eliminating PCM double attenuation and fixing volume-ctrl Fixed semantics (#144). Merge upstream librespot changes (CDN fallback #1722) into the binary and rebuild via CI.
**Requirements**: GH #144
**Depends on:** None (independent Rust + binary rebuild)
**Plans:** 2/2 plans complete

Plans:

- [x] 64-01-PLAN.md — Rust: PassthroughMixer in unified.rs + --check capability + librespot dev pin refresh (#1722 verified included)
- [x] 64-02-PLAN.md — Perl: capability-gated Daemon.pm volume arg simplification + CHANGELOG + live volume verification on dev LMS

### Phase 65: ZeroConf Credential Provenance Fix (Login5 Outage)

**Goal:** Restore playback after Spotify's Login5 StoredCredential blockade (Aug 10, 2026) by switching credential provisioning from PKCE-derived `--token-login` to ZeroConf-paired `--discover-once`. Stop the daemon crash-loop caused by unrecognized INVALID_CREDENTIALS errors. Provide browser-based fallback for environments where mDNS is unavailable (Docker, VLANs).
**Requirements**: GH #147
**Depends on:** None (hotfix, independent of v2.3 Library Integration)
**Plans:** 5/5 plans executed (65-06..65-08 cancelled — STOP gate)

Plans:

- [x] 65-01-PLAN.md — Crash-loop fix: extend isCredentialError, playback-auth flag, restart backoff, defuse all PKCE auto-derive paths
- [x] 65-02-PLAN.md — ZeroConf pairing: --discover-once engine, Authorize Playback Settings UI with 2s polling, strings (11 languages)
- [x] 65-03-PLAN.md — Browser fallback (Keymaster PKCE + --token-login), upgrade migration, OPML hint, strings (11 languages)
- [x] 65-04-PLAN.md — Keymaster PKCE unification: one auth step yields Web API tokens + auto-derived playback credentials; loopback-to-LMS redirect; Custom App collapsed to advanced; strings (11 languages)
- [x] 65-05-PLAN.md — ZeroConf-only auth, gate: restore --get-token (revert d7fd566) + live hypothesis test (Keymaster Mercury token from ZeroConf creds vs api.spotify.com) — STOP gate for 06-08
- [~] 65-06-PLAN.md — CANCELLED (65-05 STOP gate: Mercury Keymaster 403 disproves the PKCE-elimination hypothesis)
- [~] 65-07-PLAN.md — CANCELLED (65-05 STOP gate) — Settings reorg scope superseded by Phase 66
- [~] 65-08-PLAN.md — CANCELLED (65-05 STOP gate)

### Phase 66: Two-Step Auth Revert + Settings Reorganization

**Goal:** Eliminate the severe 429 rate limiting introduced by 65-04's Keymaster PKCE default (shared global rate-limit bucket) by reverting to the ncspot Extended Quota Client ID for Web API tokens, making ZeroConf pairing the required playback-credential step again (two-step auth), reverting the 65-05-session /me workarounds at the source, reorganizing the Settings page into clear Onboarding/Account/Global/Diagnostics sections, and updating the Auth Health dashboard to show Web API token and playback credential status separately.
**Requirements**: GH #147
**Depends on:** Phase 65 (plans 65-01..65-05)
**Plans:** 3/3 plans complete

Plans:

- [x] 66-01-PLAN.md — Auth revert: ncspot Extended Quota ID as PKCE default, zero derivation from account tokens, 65-05 workaround revert, TokenManager fallback, test gates
- [x] 66-02-PLAN.md — Settings UI reorganization (4-step onboarding, Account/Global/Diagnostics sections, always-visible pairing, collapsed Custom App) + Auth Health playback indicators
- [x] 66-03-PLAN.md — Strings: two-step auth messaging, new section/guide/source keys, obsolete key removal (11 languages)

---
*Roadmap created: 2026-05-26*
*Last updated: 2026-08-15 — Phase 66 added (429 revert + Settings reorg); 65-06..08 cancelled per 65-05 STOP gate*
