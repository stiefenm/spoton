# Requirements: SpotOn v2.3

**Defined:** 2026-06-30
**Core Value:** Reliable Spotify playback and Connect integration on LMS — Browse, stream, and control via Spotify app, without 429 bursts, zombie daemons, or audio glitches.

## v2.3 Requirements

Requirements for Library Integration milestone. Each maps to roadmap phases.

### Library Import

- [ ] **LIB-01**: User's Liked Songs erscheinen in LMS My Music > Tracks und sind über globale Suche findbar
- [ ] **LIB-02**: User's Saved Albums erscheinen in LMS My Music > Albums mit Cover und Tracklisting
- [ ] **LIB-03**: User's Followed Artists erscheinen in LMS My Music > Artists
- [ ] **LIB-04**: Inkrementeller Sync — nur neue/geänderte Items werden importiert (added_at Early-Exit)
- [ ] **LIB-05**: Change Detection via needsUpdate() — leichtgewichtige Prüfung (3 API-Calls) ob Rescan nötig
- [ ] **LIB-06**: Scanner nutzt SimpleSyncHTTP mit 1 req/3s Throttle und 429-Handling (sleep + retry)
- [ ] **LIB-07**: Library-Icon Badge für Spotify-Items in LMS Library View
- [ ] **LIB-08**: Library Stats auf Status Page (Tracks/Albums/Artists importiert)
- [ ] **LIB-09**: Progress-Anzeige während Scan (Slim::Utils::Progress)
- [ ] **LIB-10**: Importierte Tracks haben separate title/artist/album DB-Felder, damit LMS standardTitle() das konfigurierte titleFormat (z.B. "TITLE BY ARTIST FROM ALBUM") korrekt zusammenbauen kann -- ermoeglicht current_title Kompatibilitaet mit Drittanbieter-Playern (WiiM Ultra etc.), siehe GH #96

### Playlist Import

- [ ] **PL-01**: Spotify-Playlists als LMS-Playlists importierbar (opt-in via Preference)
- [ ] **PL-02**: Playlist-Change-Detection via snapshot_id — nur geänderte Playlists werden reimportiert

### Token Routing

- [ ] **TOK-01**: Library-Import nutzt PKCE-Token (eigener Rate-Pool via SpotOn client_id), Fallback auf login5 (shared pool)
- [ ] **TOK-02**: Cross-Process Rate-Limit-Signal zwischen Scanner und Hauptprozess via Cache-Key

### Context Menu

- [x] **CTX-01**: Standard-LMS-Menüeinträge (Add to Favorites, etc.) erscheinen im SpotOn More-Menü neben den SpotOn-Einträgen

### Configuration

- [ ] **CFG-01**: Preference "Import Library" (global toggle, default: off)
- [ ] **CFG-02**: Preference "Import Playlists" (global toggle, default: off, nur aktiv wenn LIB enabled)

## Future Requirements

Deferred to future release. Tracked but not in current roadmap.

### Library Enhancements

- **LIB-F01**: Tag Cleanup — Strip "(Remastered)", "(Deluxe Edition)" from imported album/track names (opt-in)
- **LIB-F02**: Multi-Account Support — Import from multiple Spotify accounts into separate LMS library namespaces

### Auth Architecture (v2.4 — Golden Path: PKCE-Only)

> **Architectural Decision (2026-07-03):** PKCE replaces ZeroConf as the primary auth mechanism. Single auth flow handles both Web API tokens (own rate pool) and librespot Connect credentials. ZeroConf/mDNS discovery is no longer needed — librespot registers as Connect device via cloud/Spirc with stored credentials. Solves Keymaster deprecation (#91), Docker mDNS issues (#103), and rate pool fragmentation in one move. Deep Research Report: https://gist.github.com/stiefenm/1f8c1231462ec6c41e29832e758f338d

- [x] **AUTH-01**: User authenticates via one-click PKCE OAuth in LMS Settings ("Connect Spotify Account" button → browser redirect → authorize → callback)
- [x] **AUTH-02**: PKCE flow uses SpotOn's own client_id → access+refresh tokens under own Extended Quota rate pool
- [x] **AUTH-03**: PKCE access token is used once to obtain non-expiring librespot stored credentials (PR #1309 pattern: token → AP session → credential blob)
- [x] **AUTH-04**: librespot starts with stored credentials + `--disable-discovery` — Connect device appears via cloud/Spirc registration, no mDNS needed
- [x] **AUTH-05**: TokenManager.pm refreshes Web API tokens via standard OAuth refresh flow — no binary spawn (`--get-token`) needed for API calls
- [x] **AUTH-06**: ~~Login5 fallback~~ (dropped — Login5 gets immediate 429 on api.spotify.com, not viable as API token source. PKCE is the sole API auth path. See Phase 53 D-01/D-02)
- [x] **AUTH-07**: Keymaster code removed from TokenManager.pm after PKCE is stable (Plan 01 Rust removal, Plan 02 Client.pm/i18n cleanup, Plan 03 TokenManager.pm D-16 comment fix + migration detection/UX all complete — zero case-insensitive "keymaster" references remain, permanently guarded by test)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Full Catalog Search via Importer | Dev Mode limit=10 macht Search-basierte Anreicherung unwirtschaftlich |
| Background Polling kürzer als 1h | LMS OnlineLibrary pollt stündlich, kürzere Intervalle nicht vorgesehen |
| Extended Quota Neuantrag | Spotify requires 250k MAU + legally registered business (bestehende EQ grandfathered) |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CTX-01 | Phase 37 | Complete |
| LIB-06 | Phase 38 | Pending |
| TOK-01 | Phase 38 | Pending |
| TOK-02 | Phase 38 | Pending |
| CFG-01 | Phase 38 | Pending |
| LIB-02 | Phase 39 | Pending |
| LIB-03 | Phase 39 | Pending |
| LIB-07 | Phase 39 | Pending |
| LIB-09 | Phase 39 | Pending |
| LIB-10 | Phase 39 | Pending |
| LIB-01 | Phase 40 | Pending |
| LIB-04 | Phase 40 | Pending |
| LIB-05 | Phase 40 | Pending |
| LIB-08 | Phase 40 | Pending |
| PL-01 | Phase 41 | Pending |
| PL-02 | Phase 41 | Pending |
| CFG-02 | Phase 41 | Pending |

**Coverage:**

- v2.3 requirements: 17 total
- Mapped to phases: 17
- Unmapped: 0

---
*Requirements defined: 2026-06-30*
*Last updated: 2026-07-02 — LIB-10 added (current_title metadata compatibility for third-party players)*
