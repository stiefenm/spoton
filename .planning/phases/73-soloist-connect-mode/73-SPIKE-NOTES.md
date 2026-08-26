# Phase 73 Plan 03 — Task 1: Wave-0 Empirical Spike (Track-End / Autoplay / Queue-Echo / Takeover-Gap)

**Status: DEFERRED**

## Why deferred

The plan's `<precondition>` requires either (a) a paired per-player soloist daemon on
this dev host (73-01 E2E marked this parked — see 73-01-SUMMARY.md "Next Phase
Readiness"), or (b) the ability to pair now via a Spotify-app device tap.

Neither is available in this execution environment:

- No Spotify app / mobile device is reachable from this session (no LAN, no browser
  with an active Spotify session available to the harness).
- The only Soloist data-dirs found on this host (`/tmp/.../soloist-spike/data*`, left
  over from the Phase-71 spike session) contain a `.device_id` but **no**
  `settings/Users/<user>-user/` directory — i.e. none of them have ever completed a
  successful pairing/login. Starting the daemon against any of them would produce an
  unauthenticated `auth_state{logged_in:false}` session, in which `play`/`add_to_queue`
  commands are rejected with `{"type":"error","message":"command requires
  authentication"}` (per the live-verified error path in 73-RESEARCH.md) — there is no
  way to observe real track-end/autoplay/queue-echo behavior without a logged-in
  session that can actually start audio.
- Verified: `soloist` binary itself is present (`/tmp/soloist_extract/soloist`,
  matching the Phase-71 pin), so the WS transport itself is not the blocker — only the
  authenticated-playback precondition is unmet.

Per the plan's own instruction for this case: this file is filed as DEFERRED, Tasks 2
and 3 are implemented against the RESEARCH-default assumptions below (not skipped),
and the live spike is carried forward as a **mandatory UAT item** before Phase 73 ships
(recorded in the Plan 03 SUMMARY and `.planning/WINDOWS.md`).

## RESEARCH-default assumptions applied to Task 2/3 implementation

These are the literal defaults the plan specifies for the DEFERRED path (73-03-PLAN.md
Task 1 `<action>`, closing paragraph), applied as-is:

1. **Q1 — end-of-track signal:** `playback_changed{status:"stopped"}` is treated as the
   "no more queued track" stop signal while a browse session is active and no seed was
   sent for the current track. SoloistWS's browse-advance logic (Task 2) reacts to this
   event by ending the browse session and letting LMS advance its own playlist —
   deliberately NOT waiting on (or trusting) any Soloist-side autoplay to keep going.
2. **Q1/Pitfall 4 — autoplay containment:** queue-seeding via `add_to_queue` is assumed
   to suppress unwanted autoplay in the common case, but the defensive correction path
   (an unexpected `track_changed` URI triggers either a corrective `play {expected}` or
   a `pause` + end-of-session at LMS queue end) stays **permanently armed** regardless —
   this is the literal instruction from the plan ("do NOT silently skip the defensive
   correction logic, it is what makes the defaults safe"). It is not conditional on
   whether autoplay actually manifests; it is cheap insurance implemented unconditionally.
3. **Q2 — context URIs:** not probed. `startBrowseTrack` only ever sends bare
   `spotify:track:ID` / `spotify:episode:ID` URIs (never album/playlist context URIs) —
   Modell B's queue-seeding design (RESEARCH Pattern 6) already avoids needing
   context-based continuation, so this open question does not gate the implementation.
4. **Q4 — queue-echo handling:** any `queue_changed` event arriving while a browse
   session is active is treated as an echo of our own `add_to_queue` call and ignored
   (no dedicated handling beyond the existing debug-log passthrough in
   `SoloistWS::_onMessage`'s default branch). No confirmation/ack logic is built on top
   of it.
5. **Takeover gap:** not measured. Assumed small (<500ms) per the RESEARCH default,
   consistent with the existing librespot `/stream` reconnect-takeover mechanism this
   design mirrors (same `fake-libpulse` ring-buffer + connection-takeover code from
   73-01, unchanged by this plan). Flagged below as a mandatory UAT measurement.
6. **A3 — volume attenuation:** not probed (requires audible playback). Per RESEARCH
   Pattern 3/Assumption A3, LMS-side volume stays untouched in browse mode (no browser
   branch added to `_onVolume`/`_onPlaylistJump` for soloist-browse in Task 3) — if the
   UAT pass below finds double-attenuation, that becomes Phase-74 scope (per the plan's
   own instruction: "note it in the SUMMARY for Phase-74 handling").

## Mandatory UAT before Phase 73 ships (parked here, tracked in WINDOWS.md and the
Plan 03 SUMMARY)

Run with a real dev LMS + paired Soloist daemon + Spotify Premium account:

1. Queue 3 album tracks in Browse (`backend=soloist`), play — confirm tracks advance in
   order (no skips, no early switches), and subjectively judge the transition gap.
2. Let a single queued track play to its natural end with `soloist ctl trace` attached
   — record the literal event sequence at track-end (does `playback_changed{stopped}`
   actually fire as assumed, or something else — autoplay, no event at all)?
3. Confirm `queue_changed` after our own `add_to_queue` — does it echo back, with what
   shape (`previous`/`upcoming`)?
4. Measure the takeover gap: attach a second `/stream` client mid-playback and time the
   header-to-first-byte interval, to validate/replace the <500ms assumption.
5. Pause 10s → unpause resumes at the paused position (not ahead of it).
6. Seek via the Material Skin seek bar — confirm no LMS-side stream restart.
7. Mixed playlist (Spotify track → radio/local) hands over cleanly at the boundary.
8. Sync two players — both play soloist Browse audio via the proxy path.
9. Set app volume to 50% during playback — hexdump/audible check whether `/stream` PCM
   amplitude drops (decides whether volume_changed must stay display-only, per A3).

## Decisions

Mapping findings (or, in the DEFERRED case, the applied defaults) to Task 2 parameters:

| # | Parameter | Value applied in Task 2/3 |
|---|-----------|----------------------------|
| a | End-of-track stop signal | `playback_changed{status:"stopped"}` (RESEARCH default) |
| b | Autoplay suppression | Seeding is the primary suppression; the defensive `track_changed`-mismatch correction (corrective `play` or `pause`+end-session) stays unconditionally armed, never gated on whether autoplay is confirmed to occur |
| c | Measured takeover gap | Not measured — assumed <500ms (RESEARCH default); real measurement is a mandatory UAT item (see above) |
| d | Queue-echo handling rule | `queue_changed` while `browseSession` is treated as an echo of our own `add_to_queue` and ignored (no ack-tracking logic) |

This file will be updated with real findings once a live paired daemon + Spotify
Premium session is available (see WINDOWS.md entry for this phase).
