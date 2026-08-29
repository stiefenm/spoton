---
phase: 76-connect-stabilization-flac24-integration
plan: 06
subsystem: browse-ui
tags: [connect, queue, opml, web-api, i18n, gh-135]
requires:
  - "76-03: Web API player-control family on Client.pm (D-08 split)"
provides:
  - "Client.pm getQueue() — GET /me/player/queue via central _request pipeline, uncached"
  - "Plugin.pm _upNextFeed + 'Up Next' Home menu entry (GH #135)"
  - "strings.txt PLUGIN_SPOTON_UP_NEXT / PLUGIN_SPOTON_UP_NEXT_EMPTY in 11 languages"
affects:
  - "Phase 77+: Option B (Spirc event-driven refresh) can layer on this feed"
tech-stack:
  added: []
  patterns:
    - "On-demand-only player-state fetch (no polling) through the shared throttle"
    - "LMS core string reuse (NOW_PLAYING) for section prefixing"
key-files:
  created: []
  modified:
    - Plugins/SpotOn/API/Client.pm
    - Plugins/SpotOn/Plugin.pm
    - Plugins/SpotOn/strings.txt
    - t/08_api_client.t
decisions:
  - "GH #135 shipped as Option A (Web API, on-demand per menu open) — sidesteps the rate-pool objection to polling; Option B (Spirc events) stays layerable in Phase 77+"
  - "Up Next menu item is type 'link', NOT 'playlist' — Play All on a live Connect queue would double-play (GH #161 convention deliberately not applied)"
  - "Now-playing head row prefixed with LMS core NOW_PLAYING string — no third custom i18n key needed"
metrics:
  duration: "~5 min"
  completed: "2026-08-29"
actuals:
  tokens: 2700
  tasks: 2
  commits: 3
status: complete
---

# Phase 76 Plan 06: Up Next (#135) Summary

**One-liner:** On-demand Spotify Connect queue ("Up Next") in the SpotOn Home menu via GET /me/player/queue through the central throttle — one request per menu open, zero polling, 11-language i18n.

## What Was Built

### Task 1: Client.pm getQueue() (TDD)

- **RED** (`be542d5`): three new test blocks in `t/08_api_client.t` — UN-01 (GET /me/player/queue, `{currently_playing, queue}` payload passthrough), UN-02 (no cache read/write; second identical call re-dispatches HTTP), UN-03 (HTTP error → error hash to callback, never a die). Confirmed failing (5 failures).
- **GREEN** (`9d3b907`): `getQueue($class, $accountId, $cb)` added to the Player Control section of `Plugins/SpotOn/API/Client.pm`, modeled 1:1 on the sibling player-state methods: routed through `_request` (central throttle, GH #155 429 auto-retry, token handling), `_noCache => 1` (player state TTL 0 per CLAUDE.md; `_cacheTTL` already returns 0 for `me/player/*`). No refactor commit needed.
- Scope check: `user-read-currently-playing` is already among the requested PKCE scopes (PKCE.pm line 74) — no re-auth required.

### Task 2: Up Next OPML feed + menu + i18n (`06ffa46`)

- `_upNextFeed` in `Plugins/SpotOn/Plugin.pm`: calls `Client->getQueue` on invocation — the ONLY trigger (rate-pool rationale documented in a comment referencing GH #135 and CLAUDE.md P-01). Renders the `currently_playing` track first (via `_trackItem`, name-prefixed with the LMS core `NOW_PLAYING` string), then each `queue` entry via `_trackItem`. Single page, no pagination.
- Empty/idle session (or malformed payload, T-76-14): single `textarea` item with `PLUGIN_SPOTON_UP_NEXT_EMPTY`. Rate-limit errors reuse `_authRequiredItem` (GH #155 clear message).
- Menu entry in `_homeFeed` directly after Recently Played: `type => 'link'`, reuses the existing `playlist.png` icon (no new art).
- `strings.txt`: `PLUGIN_SPOTON_UP_NEXT` and `PLUGIN_SPOTON_UP_NEXT_EMPTY` with real translations in all 11 languages (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV), no EN fallback.

## Verification

- `prove -l t/08_api_client.t` → PASS (88 tests, 12 new)
- `prove -l t/02_strings.t t/05_perl_syntax.t` → PASS (t/02 enforces exactly 11 language lines per key)
- `prove -l t/` → PASS (36 files, 1695 tests)
- Acceptance greps: `me/player/queue` ×2 in Client.pm; `_upNextFeed` ×3 in Plugin.pm (sub + comment + wiring); `PLUGIN_SPOTON_UP_NEXT*` keys ×2 in strings.txt
- Source assertion: no `Slim::Utils::Timers` usage and no Request subscription anywhere in the queue feed — the fetch happens only inside `_upNextFeed`
- **Deferred to consolidated Phase 76 UAT** (per plan `<human-check>`): live queue rendering in Material Skin, empty-state with no session, exactly one `me/player/queue` request per menu open in server.log

## TDD Gate Compliance

- RED gate: `be542d5` `test(76-06)` — failing tests committed first
- GREEN gate: `9d3b907` `feat(76-06)` — implementation after RED
- REFACTOR: not needed (implementation matched the sibling-method template exactly)

## Deviations from Plan

None - plan executed exactly as written. Two discretionary micro-choices within the plan's stated latitude: LMS core `NOW_PLAYING` string reused for the "now playing" prefix (plan allowed "name-prefixed or sectioned"), and `playlist.png` chosen as the reused icon asset.

## Threat Model Outcome

- **T-76-13 (DoS, shared rate pool):** mitigated — fetch is strictly user-initiated (menu open), routed through the central throttle with 429 retry; zero polling paths, source-asserted.
- **T-76-14 (Tampering, payload rendering):** mitigated — every payload level is type-checked (`ref` guards on data/currently_playing/queue/entries); rendering goes through the established `_trackItem` pipeline; malformed payload degrades to the empty-state row, no die.
- No new threat surface beyond the plan's `<threat_model>`.

## Known Stubs

None — the feed is fully wired to live data.

## Commits

| Commit | Type | Description |
| ------ | ---- | ----------- |
| `be542d5` | test | Failing getQueue tests (RED) |
| `9d3b907` | feat | Client.pm getQueue via central pipeline (GREEN) |
| `06ffa46` | feat | Up Next feed + Home menu entry + 11-language i18n |

## Self-Check: PASSED

- All 4 modified files present on disk
- All 3 task commits present in git log
- Full test suite green (36 files, 1695 tests)
