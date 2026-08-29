# Roadmap: SpotOn

**Project:** SpotOn — LMS Spotify Plugin
**Created:** 2026-05-26
**Granularity:** standard

## Milestones

- ✅ **v1.0 Foundation** — Phases 1-6 (shipped 2026-06-03)
- ✅ **v1.1 Hardening & Reach** — Phases 7-12 (shipped 2026-06-06)
- ✅ **v1.3 Polish & Publish** — Phases 13-16.1 (shipped 2026-06-13)
- ✅ **v1.5 Podcasts** — Phases 18-21 (shipped 2026-06-15)
- ✅ **v2.0 Browse Daemon Migration** — Phases 28-30 (shipped 2026-06-23)
- ✅ **v2.1 Context Menu** — Phases 31, 37 (shipped 2026-06-26)
- ✅ **v2.2 Session Health** — Phase 36 (shipped 2026-06-30)
- ✅ **v3.0 Auth Overhaul** — Phases 49-53 (shipped 2026-07-17)
- ⏸️ **v2.3 Library Integration** — Phase 37 shipped (CTX-01), Phases 38-41 deferred to v5.0
- 🔄 **v4.0 Soloist Integration** — Phases 71-77 (active)
- 📋 **v5.0 Library Integration** — Phases TBD (future, v2.3 Requirements carried forward)

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
  **Note**: Closed — manual posting via reply files works well enough, vBulletin automation not worth the effort.

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

<details>
<summary>✅ v2.0 Browse Daemon Migration (Phases 28-30) — SHIPPED 2026-06-23</summary>

- [x] **Phase 28: Persistent Browse Daemon** — completed 2026-06-22
- [x] **Phase 29: Unified Browse+Connect Daemon** — completed 2026-06-22
- [x] **Phase 30: Legacy Pipe Cleanup** — closed 2026-07-24

</details>

<details>
<summary>✅ v3.0 Auth Overhaul (Phases 49-53) — SHIPPED 2026-07-17</summary>

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

</details>

### v3.x Point Releases (Phases 54-70)

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

- [x] **Phase 58: Connect Position Sync Fix** (completed 2026-08-18)
  **Goal**: Fix mid-song Connect resume position (Rust: needs_position_sync cleared too early in TrackChanged Some→Some) and relocate the change-handler notification to _fetchTrackMetadata failure paths (Perl: avoid pushing position=0 before real position is known). Fixes regression from #126 fix.
  Depends on: Phase 57 (completed), #126 fix (commit 5d91cd8)
  **Plans:** 2/2 plans complete
  Plans:

  - [x] 58-01-PLAN.md — Perl hotfix: relocate change-handler newmetadata notify to _fetchTrackMetadata failure paths (Wave 1)
  - [x] 58-02-PLAN.md — Rust root-cause fix: preserve needs_position_sync across TrackChanged Some→Some, consume in Playing Some→Some (Wave 1, triggers CI binary rebuild)
  See: `.planning/phases/58-connect-position-sync-fix/`

### Phase 59: Connect & Search Fixes

- [x] **Phase 59: Connect & Search Fixes (GH #129 + #130)** (completed 2026-08-18)
  **Goal**: Two v3.2.3 bugfixes reported by woorszt. #129: enable seek from JiveLite/LMS UIs during Spotify Connect playback — remove the `canSeek` Connect guard, but suppress the LMS-side stream restart (`getSeekData` returns undef when Connect active) and read the seek target from the request's `_newvalue` instead of stale `songTime`. #130: `_searchTypeFeed` pagination — map LMS `index` to API offset and return `offset`/`total` (same pattern as `_artistAlbumsFeed`, #121).
  Depends on: none (independent of Phase 58)
  **Plans:** 2/2 plans complete
  Plans:

  - [x] 59-01-PLAN.md — Connect seek (ProtocolHandler.pm + Connect.pm) + search pagination (Plugin.pm) + CHANGELOG (Wave 1)
  - [x] 59-02-PLAN.md — Review finding fixes: R-1 canDoAction 'rew' guard, R-2 pause-seek-unpause documented + UAT, R-4 ignore-placeholders, R-5 error offset/total + 1000-cap; R-3 accepted as known limitation, no code fix (Wave 2)
  See: `.planning/phases/59-connect-search-fixes/`

### Phase 60: Search Single-Type & Podcast Pagination

- [x] **Phase 60: Search Single-Type & Podcast Pagination (GH #130)** (completed 2026-08-18)
  **Goal**: Fix search total-count discrepancy and podcast search pagination. (1) Switch `_searchFeed` and `_podcastSearchFeed` from combined multi-type API calls to parallel single-type calls so overview totals match drill-in totals (woorszt #130 observation). (2) Add full pagination to `_podcastSearchTypeFeed` (currently hardcoded offset=0, no total). (3) Backport R-4 (nameless ignore placeholders) and R-5 (1000 offset cap) to podcast search. (4) Fix duplicate `$offset` declaration in `_searchTypeFeed`.
  Depends on: Phase 59 (search pagination foundation)
  **Plans:** 1/1 plans complete
  Plans:

  - [x] 60-01-PLAN.md — _multiTypeSearch aggregator (single-type overview totals) + podcast search pagination with R-4/R-5 backport + duplicate $offset fix + CHANGELOG (Wave 1)
  See: `.planning/phases/60-search-single-type-podcast-pagination/`

## Progress Table

| Phase | Milestone | Plans | Status | Completed |
|-------|-----------|-------|--------|-----------|
| 1-6 (15 phases) | v1.0 | 50/50 | Complete | 2026-06-03 |
| 7-12 (7 phases) | v1.1 | 13/13 | Complete | 2026-06-06 |
| 13-16.1 (5 phases) | v1.3 | 9/9 | Complete | 2026-06-13 |
| 18-21 (4 phases) | v1.5 | 6/6 | Complete | 2026-06-15 |
| 22-27 (6 phases) | — | 6/6 | Complete | 2026-06-22 |
| 28-30 (3 phases) | v2.0 | 7/7 | Complete | 2026-06-23 |
| 37. Context Menu LMS Items | v2.3 | 2/2 | Complete | 2026-07-02 |
| 42-44. OGG Passthrough | — | 3/3 | Complete | — |
| 46. Code Review Bugfixes | — | —/— | Complete | — |
| 49-53 (5 phases) | v3.0 | 19/19 | Complete | 2026-07-17 |
| 54. Auth Health Dashboard | v3.x | 5/5 | Complete | 2026-07-16 |
| 55. Bundled Client ID | — | — | Parked | 2026-07-24 |
| 56-57. Material Skin | v3.x | 5/5 | Complete | 2026-07-23 |
| 58-60. Connect/Search Fixes | v3.x | 5/5 | Complete | 2026-08-18 |
| 61. Community Bugfixes | v3.x | 2/2 | Complete | — |
| 63. Account Switcher + Sync | v3.x | 2/2 | Complete | — |
| 64. PassthroughMixer | v3.x | 2/2 | Complete | — |
| 65-67. ZeroConf + Auth Revert | v3.x | 13/16 | Complete | — |
| 70. JiveLite Pagination | v3.x | 5/5 | Complete | 2026-08-22 |
| 71. Soloist Foundation | v4.0 | 4/4 | Complete | 2026-08-26 |
| 72. Soloist Browse Playback | v4.0 | 3/3 | Complete | 2026-08-26 |
| 73. Soloist Connect Mode | v4.0 | 6/6 | Complete | 2026-08-27 |
| 74. spoton-helper Binary | v4.0 | 0/? | In Progress|  |
| 75. API Unification | v4.0 | 0/? | In Progress|  |
| 76. Soloist UX Polish | v4.0 | 0/? | Not started | — |
| 77. Soloist UAT + Release | v4.0 | 0/? | Not started | — |
| 38-41 (4 phases) | v2.3→v5.0 | 0/? | Deferred | — |
| 62. Browse + Connect Queue | — | 0/? | Backlog | — |

### Phase 61: Community Bugfixes (HomeExtra, Status Page, Connect Volume)

**Goal:** Fix 5 community-reported bugs: #133 HomeExtra pagination cache, #139 HomeExtra refresh signal, #138 Status Page account order, #136 account name menu refresh, #137 Connect volume-ctrl per player
**Requirements**: GH #133, #136, #137, #138, #139
**Depends on:** None (independent bugfixes)
**Plans:** 2/2 plans executed

Plans:

- [x] 61-01-PLAN.md — HomeExtra staleness + account switch: pagination-aware memoization key (#133), refresh() signal helper wired at account/auth state changes (#139), switcher returns to re-fetched main menu (#136)
- [x] 61-02-PLAN.md — Status page deterministic account order (#138), --volume-ctrl fixed for players without digital volume (#137), CHANGELOG

### ~~Phase 62: Browse Endpoints + Connect Queue~~ DEFERRED

**Deferred to Backlog** (2026-08-24): New Releases (#134) + Connect Queue (#135) are independent features, not blocking v4.0 Soloist. Moved to Backlog.

### Phase 63: Account Switcher UX + Sync Group Stability

**Goal:** Fix account switcher confirmation page behavior across all LMS client types (#136). Prevent unnecessary Connect daemon restarts when sync group membership changes (#143).
**Requirements**: GH #136, #143
**Depends on:** None (independent UX/stability fixes)
**Plans:** 2/2 plans complete

Plans:

- [x] 63-01-PLAN.md
- [x] 63-02-PLAN.md

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
**Plans:** 5/8 plans complete

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

### Phase 67: Bundled ID & Auth Redirect UX

**Goal:** Fix /login redirect handler bug (qr{} regex-as-hash-key → 404), overhaul bundled ID UX to communicate shared-bucket degradation, recommend custom Client ID as primary path
**Requirements**: GH #147 (rate-limit root cause), D-01..D-05
**Depends on:** Phase 66
**Plans:** 2/2 plans complete

Plans:

- [x] 67-02-PLAN.md

- [x] 67-01-PLAN.md — /login fix, probe skip for bundled ID, Settings UX reframing, i18n (11 langs), TROUBLESHOOTING.md, forum reply

### ~~Phase 68: OGG Metadata Strip (Passthrough)~~ DROPPED

**Dropped:** 2026-08-21 — librespot's PassthroughDecoder re-serializes the OGG container from scratch (only standard headers 0x01/0x03/0x05 + audio data). Spotify's proprietary 0x81 page is never present in the output. Verified via source analysis, confirmed by urknall (#156). No strip logic needed.

### Phase 70: JiveLite Pagination Fill (GH #157)

**Goal:** Fix JiveLite empty rows by implementing bounded multi-page fill in all 11 affected feed functions. Generalize _fetchAllPages to _fetchPages with startOffset/maxItems, swap else-branch single API calls for multi-page fills, clamp total on partial errors. Covers saved tracks/albums/shows, playlists, artist albums, album tracks, search, podcast search, and add-to-playlist.
**Depends on:** None (independent side phase)
**Plans:** 5/5 plans complete

Requirements:

- JVL-01: _fetchPages helper with startOffset + maxItems params (generalization of _fetchAllPages)
- JVL-02: 8 tripartite feeds else-branch converted to _fetchPages fill
- JVL-03: _searchTypeFeed + _podcastSearchTypeFeed converted with extractTotal for nested keys
- JVL-04: SpotOnAddToPlaylist converted
- JVL-05: _albumFeed embedded-seed + continuation fill
- JVL-06: Total-clamping safety on partial fill (mid-fill error → total = offset + count)
- JVL-07: pageLimit=0 guard (blocked endpoints)
- JVL-08: Existing play-all + Material Skin + Classic Skin behavior preserved
- JVL-09: Icon contrast fix from reverted Phase 69 (GH #124) — recently.png + madeforyou.png grey-gradient regeneration

Plans:

- [x] 70-05-PLAN.md

**Wave 1**

- [x] 70-01-PLAN.md — _fetchPages generalized paginator + _fetchAllPages wrapper + _savedTracksFeed tracer conversion + t/25 unit test (Wave 1)
- [x] 70-04-PLAN.md — Icon contrast fix: cherry-pick 30f8b7b + CHANGELOG (Wave 1, parallel)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 70-02-PLAN.md — Convert 6 tripartite feeds: savedAlbums, savedShows, userPlaylists, showFeed, artistAlbums, playlistFeed (Wave 2)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 70-03-PLAN.md — Convert search + podcast search (extractTotal), SpotOnAddToPlaylist, _albumFeed seed+continuation + CHANGELOG (Wave 3)

## Backlog

Items discovered during development — not assigned to a milestone.

1. **Eigene SpotOn Client-ID bei Spotify registrieren** — Blocked: Spotify requires 250k MAU + legally registered business.
2. **Spotty Favorites Migration** — Settings-Button der `spotify://` Einträge in LMS Favorites als `spoton://` Duplikate anlegt.
3. **Browse Endpoints + Connect Queue** — New Releases/Genres/Featured via Extended Quota (#134), Connect Queue in LMS (#135). Deferred from Phase 62.
4. **Browse context parity** — Browse menu fewer items than TrackInfo (#94).
5. **Connect stutter sync groups** — Mixed player types (#131).
6. **Progress bar lag Connect handoff** — Buffer fill delay (#128).
7. **Restore player power state** — When Connect session ends (#151).
8. **librespot log integration** — Feed daemon log into server.log (#154).
9. **Recommendations diversification** — Too account-centric (#127).
10. ~~**Online-Musiksammlung**~~ — Deferred to v5.0 Library Integration.
11. ~~**LMS Community Repo Submission**~~ — Erledigt.
12. ~~**ZeroConf Auth UX**~~ — Verworfen.
13. ~~**Clear Logs Button**~~ — Implementiert in v1.7.4.

## Active — v4.0 Soloist Integration

**Goal:** Spotify Soloist als alternatives Audio-Backend neben librespot — offizieller Spotify Connect Client mit BYOK (Bring Your Own Key), Fake-libpulse Audio-Interface und optionalem Lifetime-Patch.

**Context:** Spotify launched Soloist am 2026-08-13 als offizielles Developer-Produkt. spak-Key ist Self-Service im Developer Dashboard (Premium required). Drei Linux-Architekturen: x86_64, arm64, arm32 — deckt Pi und Desktop ab.

**Approach:** BYOK + Fake-libpulse. User generiert eigenen spak-Key, Projekt liefert Integration + eine schlanke Fake-libpulse.so.0 die Audio direkt per FD abgreift statt PulseAudio zu benötigen.

**Spike Results (2026-08-24):**

| Spike | Ergebnis | Details |
|-------|----------|---------|
| **Lifetime Patch** | VALIDIERT | ASCII-Timestamp in .rodata, 10-Zeichen Drop-in-Replace. Binary zeigt "25696 days". Spotify akzeptiert gepatchten Client. |
| **Audio Interface** | VALIDIERT | Fake-libpulse.so.0 (~250 LOC C) implementiert 47 PA-Funktionen inkl. `pa_threaded_mainloop_*`. Soloist gibt S32LE/44100Hz/Stereo PCM via `pa_stream_write` aus. Kein PulseAudio-Server nötig, kein Capture-Overhead. `LD_LIBRARY_PATH` statt Binary-Patch. |
| **BYOK** | VALIDIERT | spak-Key per Developer Dashboard, Pairing via Spotify App, Credentials persistent. `--single-track` nutzt gespeicherte Session. |
| **Audio Pipeline** | VALIDIERT | PCM → FLAC (68% Ratio, 93x Realtime), PCM → OGG (10% Ratio). Gleiche Pipeline wie librespot via custom-convert.conf. |
| **24-Bit FLAC Patch** | TEILWEISE | 6 Enum-Downgrade-Gates gefunden (cmp 6/mov 5), 5 davon sicher patchbar (Gate 4 crasht). Aber: Patch allein reicht nicht — Soloist muss `supported_audio_quality=HIFI_24` in DeviceCapabilities announcen UND Spotify muss die Quality-Stufe serverseitig zuweisen. A/B-Test zeigt identische CDN-Dateigrößen (~4.5 MB OGG). Needs deeper analysis in Phase 74. |

**Key Decisions:**

- Soloist ist Community-Alternative neben librespot im öffentlichen Repo
- Kein Key im Repo, keine Key-Verteilung — reines BYOK (Spotify's eigenes Modell)
- Fake-libpulse statt PulseAudio-Capture — kein Systemprozess-Overhead, kein Binary-Patch für Audio
- Lifetime-Patch ist ein optionaler Komfort (ASCII-Replace), kein harter Blocker
- Drei Plattformen: x86_64, arm64, arm32 (kein macOS/Windows — dort bleibt librespot)

**Architecture (Spike 008+009, 2026-08-28):**

Ein-Host-Modell — spclient.spotify.com deckt ALLE Browse/Library-Features:

- **spclient.spotify.com**: Metadata (JSON), Search, Liked Songs, Saved Albums, Followed Artists, Recently Played, Playlists
- **Auth**: ZeroConf-Credentials → login5 (librespot CID, kein HashCash, kein client-token) → Bearer Token
- **api-partner.spotify.com**: NICHT nötig (CID-geblockt für librespot, aber alle Features auf spclient verfügbar)
- **spoton-helper** (Rust): Daemon-Management, Audio-Shim, Binary-Patching (kein HashCash-Solver nötig)
- **Kein PKCE, kein sp_dc, kein Browser** für Soloist-Backend.
- **Kritischer Stolperstein**: collection/v2/paging braucht Content-Type `application/vnd.collection-v2.spotify.proto`
- **Final Proof**: Soloist-Backend läuft komplett ohne librespot-Binary.

**Phases:**

- [x] **Phase 71: Soloist Foundation** — Soloist.pm Backend-Modul (Download/Version-Check/Lifecycle), Fake-libpulse.so Build-Pipeline (3 Architekturen), Helper.pm Backend-Auswahl (librespot vs soloist), BYOK Key-Management (Settings UI, mode 0600 Datei) (completed 2026-08-26)
  - **Plans:** 4 plans (Wave 1: 71-01, 71-04 parallel · Wave 2: 71-02, 71-03 parallel)
  - [x] 71-01-PLAN.md — Soloist.pm Backend-Modul (Tracer): Arch-Map, Auto-Download, Version-Check, spak.key mode 0600
  - [x] 71-02-PLAN.md — DaemonManager Backend-Dispatch + D-09 Voraussetzungs-Gate
  - [x] 71-03-PLAN.md — Settings UI: Backend-Dropdown, conditional spak-Key-Feld, Format-Validierung, i18n
  - [x] 71-04-PLAN.md — Fake-libpulse CI Build-Pipeline (glibc cross-gcc, 3 Architekturen)
- [x] **Phase 72: Soloist Browse Playback** — ProtocolHandler Runtime-Backend-Dispatch (sol/son), `--single-track` Integration via generiertem Launcher-Wrapper, Audio-Pipeline (S32LE → FLAC32/PCM via custom-convert.conf), FD-basiertes Streaming an LMS StreamServer (completed 2026-08-26)
  - **Plans:** 3 plans (Wave 1: 72-01 · Wave 2: 72-02 · Gap Closure: 72-03)
  - [x] 72-01-PLAN.md — Tracer: sol-Transcoder-Pfad end-to-end (Launcher-Wrapper, sol-Convert-Rules, ProtocolHandler-Dispatch, D-06 Retry, Tests)
  - [x] 72-02-PLAN.md — Settings D-07 Reorg: Backend als Top-Level-Sektion, conditional librespot/soloist-Felder, Pairing-Status, i18n (11 Sprachen)
  - [x] 72-03-PLAN.md — Gap Closure: CR-01 spoton://→spotify: URI-Translation im Launcher + argv-Capture-Regressionstest, WR-01 -k-argv Trade-off dokumentiert + test-pinned
- [x] **Phase 73: Soloist Connect Mode** — WebSocket API Integration (Events → LMS Player State), Connect Transfer-Playback, Daemon-Lifecycle pro Player, Sync-Group Support. **Prerequisite:** persistenter Daemon löst auch das Browse-Session-Lock-Problem (data-dir Lock blockiert Gapless/Crossfade bei Per-Track-Spawning — Tracks werden übersprungen oder zu früh gewechselt)
  - **Plans:** 6 plans (Wave 1: 73-01 Tracer · Wave 2: 73-02 · Wave 3: 73-03 · Wave 4: 73-04 · Gap Closure Wave 1: 73-05 ∥ 73-06)
  - [x] 73-01-PLAN.md — Tracer: fake-libpulse HTTP-Server (Ring, f32→S16LE) + SoloistDaemon.pm + SoloistWS.pm + DaemonManager-Lifecycle + Connect-Transfer end-to-end (D-01/D-02/D-04/D-05/D-07)
  - [x] 73-02-PLAN.md — Command-Richtung LMS→Soloist (Connect.pm WS-Dispatch), Reconnect-Resync, Repeat-Matrix, Build-Expiry-Härtung (rc=10), Tests t/31 + t/32 (D-05/D-06)
  - [x] 73-03-PLAN.md — Browse über den persistenten Daemon (Modell B): Wave-0-Spike (Track-Ende/Autoplay/Queue-Echo), play/add_to_queue-Seeding, Event-getriebener Playlist-Advance, Seek via WS, t/29-Rewrite (D-03)
  - [x] 73-04-PLAN.md — Phase-72-Rückbau (Launcher/sol-Rules/sox), Sync-Group-Tests, Settings-Daemon-Status + Pairing-Howto (App-Tap) + i18n 11 Sprachen, CHANGELOG (D-01/D-02/D-03)
  - [x] 73-05-PLAN.md — Gap Closure: SoloistWS Wire-Format-Fixes (UTF-8 Character-Frames, numerisches position_ms) + Pause-aware Position-Baseline + Resume-Gating (UAT Gaps 1+2, D-05/D-06)
  - [x] 73-06-PLAN.md — Gap Closure: fake-libpulse pa_stream_flush als echter Ring-Flush + Host-Test (UAT Gap 3, D-04)
- [x] **Phase 74: spoton-helper Binary** — Eigenständiges Rust-Binary, fokussiert auf die von Phase 73 NICHT abgedeckten Aufgaben: `patch` (Lifetime-Timestamp + FLAC24-Enum als Pattern-Scanner) und `check` (Binary-Validierung/Capability-Manifest). CI-Build für x86_64, arm64, arm32 via cross-rs. Kein HashCash-Solver nötig (login5 mit librespot-CID ist challenge-frei). Kein `token`-Modus nötig — login5-Minting läuft in Perl (siehe Phase 75). (completed 2026-08-28)
  **Bereits erledigt in Phase 73 (NICHT mehr Teil von 74):**

  - ~~`daemon` (Soloist-Lifecycle, ersetzt Shell-Launcher)~~ → umgesetzt als Perl-Modul `Unified/SoloistDaemon.pm` + `DaemonManager` (per-Player-Lifecycle, WS-Control + HTTP-Audio Ports, Crash-Backoff). Der Shell-Launcher-Wrapper aus Phase 72 wurde in 73-04 bereits entfernt.
  - ~~`audio` (fake-libpulse Rust-Port oder .so Companion)~~ → läuft als C-`libpulse.so.0` mit In-Process-HTTP-Server (f32→S16LE Ring, `GET /stream`), CI-cross-kompiliert für 3 Architekturen (Phase 71 Build-Pipeline, Phase 73 HTTP-Modus). Ein Rust-Port ist optional und aktuell nicht geplant.
  **Note:** Patches als Pattern-Scanner, nicht statische Offsets — Instruction Encoding unterscheidet sich zwischen Architekturen. FLAC24 nur TEILWEISE validiert (Spike: 5/6 Enum-Gates patchbar, Gate 4 crasht; zusätzlich Server-seitige Quality-Zuweisung ungeklärt — A/B-Test zeigte identische CDN-Größen; siehe v4.0 Spike Results "24-Bit FLAC Patch").
  **Spike Basis:** Spike 008 (KDF/Credential-Analyse — `cached`-Datei entschlüsselbar, Format ist login5-StoredCredential, kein Klartext-Token) + Spike 009 (spclient Token-Flow + collection/v2 Schema verifiziert)
  **Plans:** 4 plans (Wave 1: 74-01 Tracer · Wave 2: 74-02 ∥ 74-03 · Wave 3: 74-04)

  Plans:

  - [x] 74-01-PLAN.md — Tracer: crate scaffold + clap dispatch + `check` D-08 JSON manifest end-to-end + synthetic fixture harness + 3-arch cross config (D-01/D-07/D-08)
  - [x] 74-02-PLAN.md — Patch engine: version-locked per-arch pattern table, fail-closed safety envelope (count-assert + stage/verify/atomic-rename), Lifetime + FLAC24 5/6 gates, compliance-boundary decision + `.sha256` baseline (D-03/D-04/D-05/D-06/D-07)
  - [x] 74-03-PLAN.md — `protobuf` subcommand: collection/v2 stdin↔stdout decode/encode via pure-Rust codegen (no protoc), package-legitimacy gate, untrusted-input hardening (D-02)
  - [x] 74-04-PLAN.md — CI `build-spoton-helper` job (3 musl targets, zip fold-in) + Soloist.pm auto-patch wiring (idempotent, fail-open) + t/33 test + CHANGELOG (D-03/D-09)

- [ ] **Phase 75: API Unification (spclient-Modell)** — SpClient.pm als neue API-Schicht für spclient.spotify.com. Metadata (JSON via Accept Header), Collection/v2 (Protobuf, CT `application/vnd.collection-v2.spotify.proto`), Context-Resolve (JSON, inkl. Liked Songs ohne Paging), Recently-Played (Protobuf), Playlists + Rootlist (JSON/Protobuf). login5 Token-Minting in Perl (librespot CID `65b708...`, kein HashCash, kein client-token — Varint-Parser S-01 beachten). Token-Routing: login5 bevorzugt, PKCE als Fallback. Minimaler Protobuf-Decoder in Perl für collection/v2 + recently-played + rootlist (Optionen: Regex-URI-Extraktion, Mini-Decoder ~50 LOC, oder spoton-helper als Protobuf→JSON-Konverter). Kein HashSource/api-partner/Pathfinder nötig — sp_dc/WebPlayer bleibt optionales Legacy.
  **Set-Mapping (verifiziert, Spike 009):** `collection`=Saved Albums, `artist`=Followed Artists, `show`=Saved Shows, `ylpin`=Pinned Playlists, `listenlater`=Saved Episodes. Liked Songs via context-resolve `spotify:user:{id}:collection`. Multi-Type-Search bleibt Web-API-Fallback (context-resolve liefert nur Track-URIs).
  **Depends on:** Keine harte Abhängigkeit (login5 Token-Minting in Perl machbar). Optional beschleunigt durch Phase 74 (spoton-helper als Protobuf-Konverter), aber nicht erforderlich.
  **Stolpersteine:** Siehe Spike 009 RESULTS.md S-01 bis S-11 (u.a. base62→hex ID-Konversion S-02, Accept-Header zwingend S-03, collection Content-Type S-06, Set-Namen S-07, Protobuf-only bei recently-played/rootlist S-09/S-10)
  **Plans:** 6 plans (Wave 1: 75-01 Tracer · Wave 2: 75-02 ∥ 75-03 · Wave 3: 75-04 · Wave 4: 75-05 · Wave 5: 75-06)

  Plans:

  - [x] 75-01-PLAN.md — Tracer: ProtobufLite + Login5 + SpClient-Skelett, getTrack end-to-end über Router/Fallback (D-01/D-03/D-04/D-06/D-07/D-09)
  - [ ] 75-02-PLAN.md — Metadata-Familie: Album/Artist/Show/Episode + Search-Router (context-resolve Track-Search, Web-API-Fallback für Multi-Type, S-04/S-05)
  - [ ] 75-03-PLAN.md — D-02 Rückbau: protobuf-Subcommand, build.rs-Codegen + 2 Crates aus spoton-helper entfernt; .proto-Dateien bleiben als Schema-Doku
  - [ ] 75-04-PLAN.md — Collection-Familie: collection/v2 Sets (S-06/S-07), Liked Songs via context-resolve (kein Paging), Recently Played (Protobuf S-09)
  - [ ] 75-05-PLAN.md — Playlist-Familie: Rootlist (Protobuf S-10, Folder-Flattening) + playlist/v2 Items mit Slice-Enrichment
  - [ ] 75-06-PLAN.md — Unification: ~70 Call-Sites auf SpClient-Facade, Passthrough-Delegationen, UAT-Smoke-Script, CHANGELOG (D-08)

- [ ] **Phase 76: Soloist UX Polish** — Quality-Dropdown (OGG/FLAC/Lossless), Per-Player Backend-Auswahl (librespot vs soloist per Player-Pref), Pairing-Flow-Ausbau in Settings (Basis-Howto/App-Tap-Status bereits in 73-04 vorhanden — hier QR-Code oder erweiterte In-App-Anleitung), Diagnostics (Soloist-spezifische Health-Checks im Status-Dashboard), Lifetime-Patcher-UI.
  **Depends on:** Phase 74 (spoton-helper `patch`-Modus für Lifetime/FLAC24)

- [ ] **Phase 77: Soloist UAT + Release** — E2E-Tests (Browse, Connect, Sync Groups, Format-Switching), Plattform-Tests (x86_64, arm64, arm32), TROUBLESHOOTING, CHANGELOG, v4.0.0 Release
  **Final Proof:** Soloist-Backend funktioniert komplett ohne librespot-Binary — nur spoton-helper (`patch`/`check`) + `fake-libpulse.so` + Soloist + Perl (SoloistDaemon + SpClient). Kein librespot-Prozess, keine librespot-Credentials-Abhängigkeit. Browse/Library über spclient (Ein-Host-Modell), sp_dc/PKCE für den Soloist-Pfad nicht nötig.
  **Depends on:** Phase 74, 75, 76

**Risks:**

- Spotify kann Soloist-API-Terms ändern oder Keys revoken
- Build-Expiry-Mechanismus kann serverseitig verschärft werden
- Soloist ist Linux-only (kein macOS/Windows)
- spak-Key ist account-gebunden — User-Tracking möglich
- Dynamisches Linking gegen glibc — ältere Distros könnten Probleme haben

**References:**

- Spotify Docs: developer.spotify.com/documentation/soloist
- Downloads: developer.spotify.com/documentation/soloist/reference/downloads-and-updates
- GitHub: github.com/spotify/soloist
- Soloist Auth: developer.spotify.com/documentation/soloist/concepts/authentication
- WebSocket API: developer.spotify.com/documentation/soloist/reference/websocket-api

## Future — v5.0 Library Integration

**Goal:** Spotify-Bibliothek in LMS Native Library integrieren (OnlineLibraryBase/Importer.pm). Carried forward from v2.3.

**Requirements:** LIB-01..10, PL-01..02, TOK-01..02, CFG-01..02 (see `.planning/REQUIREMENTS.md`)

**Phases:** TBD — to be broken down when milestone becomes active.

**Key Decisions (from v2.3 research):**

- Importer follows OnlineLibraryBase pattern (Spotty, Qobuz, TIDAL, Deezer)
- me/tracks returns full objects — no individual entity fetches needed
- Incremental sync via added_at early-exit
- Scanner uses SimpleSyncHTTP (blocking OK in scanner process)

---
*Roadmap created: 2026-05-26*
*Last updated: 2026-08-24 — v2.3 deferred, v4.0 Soloist active, v5.0 Library future*
