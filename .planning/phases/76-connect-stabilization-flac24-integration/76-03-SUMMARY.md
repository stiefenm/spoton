---
phase: 76-connect-stabilization-flac24-integration
plan: 03
subsystem: browse-ux
tags: [opml, material-skin, trackinfo, spclient, search, context-menu]
requires:
  - phase 75 SpClient search router (context-resolve, S-05 delegation)
  - phase 37 spotonTrackInfo registerInfoProvider (trackInfoMenu)
provides:
  - "GH #161: playlist type on Recently Played / Top Tracks / Liked Songs (Play All / Add to Queue hover actions in Material Skin)"
  - "Window 6 fix: SpClient search() offset guard compares against the track-filtered count"
  - "GH #94: browse More menu routed through Slim::Menu::TrackInfo (spotoninfo items CLI dispatch)"
affects:
  - Browse menu UX (home feed, library feed, album tracks, episodes)
  - Search pagination fallback behavior (SpClient -> Client.pm delegation)
tech-stack:
  added: []
  patterns:
    - "Top-level CLI verb + XMLBrowser::cliQuery feed serving (in-core analog: Slim::Plugin::OnlineLibrary::BrowseArtist)"
    - "On-demand RemoteTrack creation via Slim::Schema->updateOrCreate for never-played browse urls"
    - "filter-before-guard (same shape as 75-07 CR-01 getPlaylistItems fix)"
key-files:
  created: []
  modified:
    - Plugins/SpotOn/Plugin.pm
    - Plugins/SpotOn/API/SpClient.pm
    - t/36_spclient.t
decisions:
  - "GH #94 preferred branch taken (TrackInfo-routed info itemAction) — the LMS 8.x RemoteTrack gap (RemoteTrack->fetch is cache-only) is bridged inside the new spotoninfo CLI handler via Slim::Schema->updateOrCreate, so no provider/itemActions duplication was needed"
  - "@contextItems kept as the items drill-down for the Default web skin — itemActions.info only affects jive/Material clients, so no browse-only action is lost"
  - "Worktree base was stale (8c06025, Phase 70) — fast-forwarded to soloist tip d56a4b8 before execution (non-destructive ff-only merge)"
metrics:
  duration: "11m"
  completed: "2026-08-29"
status: complete
actuals:
  tokens: 2939
  tasks: 3
  commits: 4
---

# Phase 76 Plan 03: Browse/UX Fixes Summary

**One-liner:** Playlist-type hover actions on flat track lists (GH #161), track-filtered search() offset guard with TDD regression pin (Window 6), and a TrackInfo-framework-routed browse More menu via a new `spotoninfo items` CLI dispatch (GH #94).

## Tasks Completed

| Task | Name | Commits | Files |
|------|------|---------|-------|
| 1 | Window 6 — search() offset guard against filtered count (TDD) | 2a352e6 (RED), f92000d (GREEN) | SpClient.pm, t/36_spclient.t, .planning/WINDOWS.md |
| 2 | GH #161 — playlist type on flat-track-list entries | 209e131 | Plugin.pm |
| 3 | GH #94 — browse context menu parity with TrackInfo | ab57cc4 | Plugin.pm |

## What Was Built

### Task 1: Window 6 (WINDOWS.md #6)
`SpClient.pm search()` filtered `@uris` to `spotify:track:` AFTER the count-based delegation guard, so the guard compared `$offset` against the raw URI count while the slice operated on the filtered list — a mixed context-resolve window (e.g. 5 URIs, 3 tracks) with offset 3 returned an empty slice instead of delegating to Client.pm. The filter now runs BEFORE the guard and the guard compares against `scalar(@trackIds)` (filter-before-slice shape of 75-07 CR-01). Two regression tests in t/36_spclient.t pin both directions:
- offset >= filtered count but < raw count → exactly one Client.pm delegation, zero enrichment requests
- offset within the filtered window → served from context-resolve (no over-delegation), `total` = filtered count

TDD gates: RED commit 2a352e6 (test 118 failed: got 0 delegations, expected 1), GREEN commit f92000d (270/270 pass).

### Task 2: GH #161 (Material Skin hover actions)
`type => 'link'` changed to `type => 'playlist'` on exactly the entries whose feed renders a flat track list directly (each has a single push site; verified by grep over all feed references):
- Recently Played (`_recentlyPlayedFeed`) — Plugin.pm:1425 (home feed)
- Top Tracks (`_topTracksFeed`) — Plugin.pm:1461 (home feed)
- Liked Songs (`_savedTracksFeed`) — Plugin.pm:1630 (library feed)

Made For You keeps `type => 'link'` at both push sites (expired branch Plugin.pm:1446, valid branch Plugin.pm:1453) — it renders a playlist list, not tracks. All three target feeds verified flat before the change (`_trackItem` maps, `_savedTracksFeed` carries server-side Play All detection).

### Task 3: GH #94 (context menu parity)
Preferred branch implemented — one menu source feeds both navigation paths:
- New CLI dispatch `['spotoninfo', 'items', '_index', '_quantity']` (initPlugin) with handler `_trackInfoItemsCLI`, which builds the feed via `Slim::Menu::TrackInfo->menu($client, $url, $track, $tags)` and serves it through `Slim::Control::XMLBrowser::cliQuery('spotoninfo', $feed, $request)` — the in-core `Slim::Plugin::OnlineLibrary::BrowseArtist` pattern.
- **LMS 8.x gap bridged (evidence):** `Slim::Menu::TrackInfo::menu()` requires a track object (`TrackInfo.pm:255-263` errors out otherwise) and `Slim::Schema::RemoteTrack->fetch()` is cache-only (`RemoteTrack.pm:426-437` — no create path), so a browse item that was never PLAYED has no RemoteTrack and the stock `['trackinfo','items'] url:` dispatch fails with `setStatusBadParams`. The handler therefore creates the RemoteTrack on demand via `Slim::Schema->updateOrCreate` (remote short-circuit `Schema.pm:1948-1958`) with title/artist/album/secs from the spoton_meta cache. This is NOT the duplication anti-pattern — the menu itself still comes exclusively from the TrackInfo framework.
- `itemActions => { info => { command => ['spotoninfo','items'], fixedParams => { url => $spoton_url } } }` added to `_trackItem`, `_albumTrackItem`, and `_episodeItem` (episode parity per the issue). XMLBrowser maps `info` to the jive `more` action (`XMLBrowser.pm:1291-1293`); play/add defaults stay intact (no `allAvailableActionsDefined`).

**More-menu item sets (parity proof):**

| Menu | Before | After |
|------|--------|-------|
| Now Playing TrackInfo (track) | LMS standard (favorites, More Info w/ GH-93 url, jive play controls) + Artist View + Album View + Like + Add to Playlist | unchanged |
| Browse More (track) | ARTIST/ALBUM/YEAR text + Artist View + Album View + Like (no Add to Playlist, no LMS standard items) | identical to TrackInfo menu (same `TrackInfo->menu()` feed) |
| Browse More (episode) | Show text items + Show View + Follow + duration text (no Add to Playlist, no LMS standard items) | identical to TrackInfo menu (Show View + Follow + Add to Playlist + LMS standard items) |

No browse-only action lost: every `@contextItems` entry is covered by the TrackInfo feed (Artist/Album/Year via standard remote-meta items + spotonTrackInfo provider), and `@contextItems` itself remains as the `items` drill-down for the Default web skin.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Stale worktree base — fast-forwarded to soloist tip**
- **Found during:** Execution start (load_plan)
- **Issue:** The worktree branch was created from `8c06025` (Phase 70 / v3.5.8) — `SpClient.pm`, `t/36_spclient.t` and all Phase 71-75 code the plan modifies did not exist at that base.
- **Fix:** `git merge --ff-only soloist` (8c06025 is an ancestor of `d56a4b8`; non-destructive fast-forward, no history rewrite). All plan targets present afterwards.
- **Files modified:** none (branch pointer only)
- **Commit:** n/a (ff)

**2. [Rule 3 - Blocking] WINDOWS.md ledger not reachable in the worktree**
- **Found during:** Task 1 (mark entry #6 fixed)
- **Issue:** `.planning/WINDOWS.md` lives only in the main checkout (`.planning/` is gitignored, the ledger was never committed); the sandbox blocks writes outside the worktree, and `gsd-tools windows fixed 6` resolves the planning dir from cwd.
- **Fix:** Copied the ledger into the worktree, ran `gsd-tools windows fixed 6` there (entry #6 → fixed, open_count 6→5). **Orchestrator action required:** the worktree copy cannot propagate via git merge — run `node ~/.claude/gsd-core/bin/gsd-tools.cjs windows fixed 6` in the main checkout (or copy `.planning/WINDOWS.md` from the worktree) before cleanup.
- **Files modified:** `.planning/WINDOWS.md` (worktree copy, uncommitted — gitignored)
- **Commit:** n/a (gitignored; not force-added per SDK policy)

## Verification

- `prove -l t/` fully green: 36 files, 1682 tests (incl. 2 new W6 tests in t/36, t/14 context menu unbroken)
- TDD gates verified in git log: `test(...)` 2a352e6 before `feat/fix(...)` f92000d
- WINDOWS.md #6 status `fixed` (worktree ledger copy; `grep -A8 '"id": 6' | grep -c fixed` = 1)
- Live checks deferred to consolidated Phase 76 UAT (plan `<human-check>` items): Material Skin hover actions on the three entries; More-menu parity for an album track and a podcast episode

## Known Stubs

None — no hardcoded empty values, placeholders, or unwired components introduced.

## Threat Flags

None — no new network endpoints, auth paths, or schema changes beyond the plan's threat model. T-76-07 mitigated (guard derives from the filtered list actually sliced, regression-pinned); T-76-08 accepted per plan (the new `spotoninfo` dispatch validates the url shape `^spoton://(?:track|episode):[A-Za-z0-9]+$` before it reaches Schema/TrackInfo).

## TDD Gate Compliance

Task 1 (`tdd="true"`): RED commit 2a352e6 (failing test confirmed: 1 failure of 270), GREEN commit f92000d (all pass). No refactor commit needed.

## Self-Check: PASSED

- t/36_spclient.t contains `context_resolve_mixed_fixture` + both W6 tests: FOUND
- SpClient.pm guard uses `scalar(@trackIds)`: FOUND
- Plugin.pm playlist types at 1425/1461/1630, Made For You link at 1446/1453: FOUND
- Commits 2a352e6, f92000d, 209e131, ab57cc4 in git log: FOUND
