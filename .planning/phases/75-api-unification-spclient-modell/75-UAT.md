---
status: complete
phase: 75-api-unification-spclient-modell
source: [75-01-SUMMARY.md, 75-02-SUMMARY.md, 75-03-SUMMARY.md, 75-04-SUMMARY.md, 75-05-SUMMARY.md, 75-06-SUMMARY.md, 75-07-SUMMARY.md]
started: 2026-08-29T09:55:00Z
updated: 2026-08-29T16:45:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Login5 + SpClient Metadata Roundtrip (live)
expected: Run `tools/spclient-smoke.pl /var/lib/squeezeboxserver/cache/spoton/<accountId>/credentials.json` on the LMS dev machine. All 3 stages pass — login5 token minted, metadata/4/track returns valid JSON, rootlist decodes playlists.
result: pass
notes: "Initial test used Spotty credentials (CID mismatch → HashCash challenge). SpotOn's own credentials work. Rootlist initially returned count=0 due to Response field mapping bug (field 5 not field 1) — fixed in 0c7ff9f. Re-test: token=438 chars, metadata=OK, rootlist=93 playlists. Proto audit: all endpoints (collection/v2, context-resolve, recently-played) match expected structures."

### 2. Album/Artist/Search + Show/Episode Shapes (live)
expected: Browse an album (track list loads with correct names/durations), browse an artist (albums list loads), search for a track (results appear). Verify no visible regressions vs. pre-Phase-75 behavior.
result: pass
notes: "Artist albums initially showed empty items — spclient metadata/4/artist only embeds gid per album (no name/cover). Fixed in 6146a2b: getArtistAlbums now enriches via metadata/4/album. After fix: album names and covers load correctly."

### 3. Collection/v2 Library (live)
expected: Open "Saved Albums" — albums appear. Open "Liked Songs" — tracks load with play-all working. All via spclient path (check server log for `spclient` entries).
result: pass
notes: "Saved Albums initially showed empty items on page 10+ — collection/v2 set 'collection' mixes albums + liked tracks. Fixed in 4ba3cd3: URI-type filter before slicing. After fix: all pages show correct albums. Liked Songs work. Zero Client.pm fallbacks during testing."

### 4. Playlist Library + Playlist Tracks (live)
expected: Open "My Playlists" — playlist library appears. Open a playlist — tracks load.
result: pass
notes: "Covered by smoke test (93 playlists decoded). Rootlist parser fixed from field 1 to field 5 (0c7ff9f). Live-verified by user."

### 5. Connect Session Survival + D-09 Rate Watch (live)
expected: Start a Connect session from Spotify app to LMS. Play, skip 5+ tracks. Browse during playback. No audio interruption or audio-key throttle.
result: pass
notes: "User confirmed all browsing works during session. Zero D-07 fallbacks in logs after final fix deployment."

### 6. ProtobufLite wire-format encode/decode (automated)
expected: t/34_protobuf_lite.t passes with Rust-parity golden vectors
result: pass
source: automated
coverage_id: D1-D3

### 7. Login5 Bearer token minting + coalescing (automated)
expected: t/35_login5.t passes — S-01 varint regression, coalescing, error mapping
result: pass
source: automated
coverage_id: D1-D3

### 8. SpClient router/fallback/rate-isolation (automated)
expected: t/36_spclient.t covers D-06 routing, D-07 fallback, D-03 rate key, base62, normalization
result: pass
source: automated
coverage_id: D1-D6

### 9. Rust protobuf removal (automated)
expected: cargo build/test green, cargo tree has no protobuf, --help shows only patch/check
result: pass
source: automated
coverage_id: D1-D4

### 10. CR-01 pagination fix + WR-01..04 hardening (automated)
expected: t/36_spclient.t regression tests for mixed-content windows, partial-enrichment stubs, meta guard, playlistId validation, collection page cap
result: pass
source: automated
coverage_id: D1-D6

## Summary

total: 10
passed: 10
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps
