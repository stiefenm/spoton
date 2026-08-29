---
status: testing
phase: 75-api-unification-spclient-modell
source: [75-01-SUMMARY.md, 75-02-SUMMARY.md, 75-03-SUMMARY.md, 75-04-SUMMARY.md, 75-05-SUMMARY.md, 75-06-SUMMARY.md, 75-07-SUMMARY.md]
started: 2026-08-29T09:55:00Z
updated: 2026-08-29T09:55:00Z
---

## Current Test

number: 1
name: Login5 + SpClient Metadata Roundtrip (live)
expected: |
  `tools/spclient-smoke.pl --credentials ~/.spoton/credentials.json` completes
  Stage 1 (login5 Bearer token), Stage 2 (spclient metadata/4/track), and
  Stage 3 (rootlist) successfully. Token is >400 chars, track JSON contains
  name/artists/album fields, rootlist returns at least one playlist.
awaiting: user response

## Tests

### 1. Login5 + SpClient Metadata Roundtrip (live)
expected: Run `tools/spclient-smoke.pl --credentials ~/.spoton/credentials.json` on the LMS dev machine. All 3 stages pass — login5 token minted, metadata/4/track returns valid JSON, rootlist decodes playlists.
result: [pending]

### 2. Album/Artist/Search + Show/Episode Shapes (live)
expected: Browse an album (track list loads with correct names/durations), browse an artist (albums list loads), search for a track (results appear). If you have podcast content: browse a show (episodes load). Verify no visible regressions vs. pre-Phase-75 behavior — same menus, same data.
result: [pending]

### 3. Collection/v2 Library (live)
expected: Open "Saved Albums" — albums appear. Open "Liked Songs" — tracks load with play-all working. Check "Recently Played" — recent tracks appear. All via spclient path (check server log for `spclient` entries).
result: [pending]

### 4. Playlist Library + Playlist Tracks (live)
expected: Open "My Playlists" — your playlist library appears (including folders if you have them). Open a playlist — tracks load. Play-all on a playlist works without duplicates or truncation. Mixed playlists (tracks + episodes) should show tracks only, no gaps.
result: [pending]

### 5. Connect Session Survival + D-09 Rate Watch (live)
expected: Start a Connect session from Spotify app to LMS. Play, skip 5+ tracks. Browse during playback (search, playlists). No audio interruption, no audio-key throttle (10-20s delay would indicate D-09 regression). Playback resumes after browse activity.
result: [pending]

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
passed: 5
issues: 0
pending: 5
skipped: 0
blocked: 0

## Gaps
