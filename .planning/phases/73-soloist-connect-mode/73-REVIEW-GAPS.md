---
phase: 73-soloist-connect-mode
reviewed: 2026-08-27T09:14:06Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - Plugins/SpotOn/Unified/SoloistWS.pm
  - Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c
findings:
  critical: 0
  warning: 3
  info: 2
  total: 5
status: issues_found
---

# Phase 73: Code Review Report — Gap Closure Plans 73-05 / 73-06

**Reviewed:** 2026-08-27T09:14:06Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

Reviewed the two gap-closure changes: the SoloistWS.pm wire-format fixes plus
`sessionPaused` resume gating (73-05, commits `fab6bba..8adbd1e`) and the
fake-libpulse `pa_stream_flush` ring flush (73-06, commits `6c8ed0f`,
`739f099`). Review included tracing the WS event handlers against Connect.pm's
`spottyconnect` consumers, thread-safety analysis of the ring flush against
`_ring_push`/`_ring_pop_timed`/the HTTP server drain loop, and an empirical
host-test campaign (100+ runs, including CPU-starvation stress and a
delay-injection experiment on a scratchpad copy).

**What checks out cleanly:**

- **UTF-8 bridge (D-05):** Correct. `utf8::encode($json_text) if
  utf8::is_utf8($json_text)` sits before the `eval { from_json }`, operates on
  a local copy (no caller aliasing), and the `is_utf8` guard handles both the
  vendored `Frame::next` character-string path and any plain-octet path
  (no double-encode risk). LMS's `JSON::XS::VersionOneAndTwo` maps `from_json`
  to octet-expecting `decode_json`, so the bridge direction is right. The test
  stub's `JSON::PP->new->utf8(1)->decode` faithfully mirrors the octet
  contract, so the regression test is non-vacuous.
- **Numeric coercion coverage (D-06):** Complete. The only numeric params that
  cross `sendCommand` are `position_ms` (Connect-seek at Connect.pm:271 and
  `_bufferedBrowseSeek` at Connect.pm:668) and `volume` (Connect.pm:274); both
  are covered by the choke-point loop. The `enabled` scalar-ref booleans are
  correctly excluded. Coercion before the connected-check is harmless.
- **`_ring_flush` production semantics:** Sound. Lock discipline matches
  `_ring_push`/`_ring_pop_timed` (broadcast under the lock, no missed-wakeup
  window); a producer blocked in `cond_wait(space_avail)` re-checks
  `fill == capacity` after wake, so it resumes cleanly. Frame alignment is
  preserved across a flush: `RING_CAPACITY` (705600) is a multiple of the
  4-byte S16LE stereo frame, all pushes/pops are frame-multiples, so the
  discarded byte count can never shift channel/sample alignment on the
  continuous HTTP stream. The synchronous `_stream_refresh_timing(s)` after
  the flush correctly snaps `read_index` to `write_index`. The `g_http_mode`
  gate preserves the Phase 71/72 no-op path. Residual staleness is bounded to
  one in-flight consumer chunk (≤16 KB ≈ 93 ms) — inherent and acceptable.
- No security regressions: `uri` validation is untouched, the coercion only
  narrows what can reach the wire, no new input surfaces.

**What does not check out:** three warnings below — two state-machine gaps in
the `sessionPaused` logic, and one experimentally-proven defect in the flush
host-test's "detach" mechanism (the test currently passes by winning a timing
race, not by the mechanism its comment claims).

## Warnings

### WR-01: sessionPaused can be cleared without ever emitting 'resume' — LMS player left silently paused

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:755-757` and `Plugins/SpotOn/Unified/SoloistWS.pm:972-980`
**Issue:** Three independent signals write `sessionPaused`, but only one of
them (`_onPlaybackChanged` status `'playing'`, line 699) emits `'resume'` on
the 1→0 transition. The other two clear the flag silently:

- `_onPositionSync` line 756: `$self->sessionPaused($msg->{speed} ? 0 : 1)`
- `_onPlaybackState` lines 977-979: `$self->sessionPaused(0)` on snapshot
  status `'playing'`

If either frame is processed after the daemon actually resumed but before the
`playback_changed('playing')` frame (a `position_sync` ticker firing between
the daemon's internal state change and its event emission; or a `get_state`
reply arriving first), the later `'playing'` frame finds the gate already
closed and **no resume is ever emitted — the LMS player stays paused/stopped
while Spotify plays**. Pre-73-05, the unconditional resume-on-playing masked
this ordering sensitivity.

The most concrete trigger is the reconnect path: pause happens, WS drops, user
resumes in the app, WS reconnects → `auth_state` → `get_state` → snapshot
reports `status:'playing'` → `sessionPaused` cleared at line 978 with no
emission, and no `playback_changed('playing')` frame will ever arrive (it was
sent while disconnected). This hardens a previously-soft gap into a structural
one, and matches the known-error family "Connect Reconnect → no audio".
**Fix:** Centralize the transition so any genuine 1→0 while `sessionActive`
routes through the resume emission, e.g.:

```perl
sub _setSessionPaused {
    my ($self, $paused) = @_;
    if (!$paused && $self->sessionPaused && $self->sessionActive) {
        my $posSec = defined $self->lastPositionMs
            ? sprintf('%.3f', $self->lastPositionMs / 1000) : '0.000';
        $self->_emit('resume', $self->lastTrackId, $posSec);
        $self->lastPositionTs(Time::HiRes::time());
    }
    $self->sessionPaused($paused ? 1 : 0);
}
```

and call it from all three signal sites (keeping the `get_state`
reconciliation send in the `_onPlaybackChanged` branch, or moving it into the
helper). At minimum, `_onPlaybackState`'s `'playing'` branch must emit resume
when it observes `sessionPaused` set.

### WR-02: Stale pause-position resume after an app-side skip while paused; sessionPaused survives track/session boundaries

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:692-716` (with `_onTrackChanged` at 543-574)
**Issue:** `lastPositionMs` and `sessionPaused` are never reset on
`track_changed`. Sequence: pause (sessionPaused=1, lastPositionMs=e.g.
145000) → user skips to the next track in the Spotify app →
`track_changed` emits `'change'` (new track) → `'buffering'` (no-op) →
`'playing'` finds `sessionPaused` still 1 and emits
`'resume'` with the **previous track's pause position** (`145.000`).
Connect.pm's resume handler (Connect.pm:962-971) applies that stale position
to `startOffset`, so the new track shows a wildly wrong elapsed time until the
`get_state` snapshot round-trip triggers the tolerance-gated corrective
`'seek'`. The same stale-flag mechanics apply after `endBrowseSession`
handover and across daemon session teardown (`disconnect()` resets neither
`sessionPaused` nor the position baseline), so the first `'playing'` of a
fresh session can fire a spurious resume at an ancient position.
**Fix:** In `_onTrackChanged`'s Connect branch (after the browse-session
early-return, before/around line 566), end the pause epoch:

```perl
$self->sessionPaused(0);
$self->lastPositionMs(0);
$self->lastPositionTs(Time::HiRes::time());
```

The code's own comment already states "the track_changed start/change flow
owns the track-start transition" — this makes the state agree with it.
(If WR-01's helper is adopted, clear via plain `sessionPaused(0)` here — a
track change must not itself emit resume.)

### WR-03: Flush host-test "detach" is illusory — test passes by timing luck, not by its claimed mechanism (experimentally proven)

**File:** `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:1594-1600` (test block), drain gate at `fake-libpulse.c:668`
**Issue:** The flush test sets `g_ring.client_connected = 0` and its comment
claims this "detach[es] the ring from the drain loop (same
direct-struct-access technique as the drop-oldest / writable_size tests)".
It does not: the server thread's drain gate is `if (client_fd >= 0)` — its
**local** fd, never `client_connected`. The flag only switches `_ring_push`
between block and drop-oldest mode. The later drop-oldest/writable_size tests
are safe only because they run after `close(client)` **and** an explicit
bounded wait for the server to observe the close (`client_fd == -1`, lines
1738-1753 — whose comment explicitly warns a fixed assumption is unreliable).
The flush test skips both steps, so the server keeps popping every ≤100 ms
cycle while the test's second pattern sits in the ring.

Proven on this machine: inserting a 120 ms delay between the
`pa_stream_write(flushed_pattern)` and the `pa_stream_flush` call (scratchpad
copy) makes the server drain the "detached" ring and both assertions fail:

```
FAIL: writable_size did not shrink before flush (before=705600 after=705600)
FAIL: post-flush bytes do not match the fresh pattern (flushed bytes leaked?): got 8192 -8192 24575 -24575
```

(8192/-8192/24575/-24575 is exactly the ±0.25/±0.75 "flushed" pattern.) The
unmodified test survives only because the main thread reaches the flush within
the server's 50 ms poll window — a scheduler preemption in that gap fails the
run. The 73-06 SUMMARY's determinism rationale ("the http server thread's
50ms poll tick only observes the ring state through that same lock") is
factually incorrect. No production impact: outside the test harness,
`client_connected` and the server's `client_fd` only ever change together on
the server thread itself.
**Fix (either):**
(a) Make the drain honor the flag it documents — change line 668 to check the
shared state, which also makes the test's technique genuinely work:

```c
int drain_ok;
pthread_mutex_lock(&g_ring.lock);
drain_ok = g_ring.client_connected;
pthread_mutex_unlock(&g_ring.lock);
if (client_fd >= 0 && drain_ok) { ... }
```

(b) Or keep production untouched and restructure the test like the WR-11
block: `close(client)`, run the observed-detach wait loop (nudge writes until
`client_connected` goes 0), do the write/flush/writable_size assertions
against the truly-detached ring, then open a **fresh** `/stream` connection
for the post-flush byte-content assertion. Either way, correct the comment.

## Info

### IN-01: Pre-existing WR-11 host-test flake undermines the gap plans' verification gate

**File:** `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:1704-1719`
**Issue:** Not introduced by 73-06, but both gap plans rely on `make test` as
their automated gate: the WR-11 check ("active client did not receive new PCM
data") failed 2/30 runs at the pre-73-06 parent and 6/30 at HEAD on this dev
machine unloaded, and 40/40 under CPU starvation (4 busy hogs + single-CPU
pinning) — its 500 ms wall-clock budget is scheduler-sensitive.
**Fix:** Widen the read timeout/budget (e.g., 500 → 2000 ms; the assertion's
point is "no HTTP_REQUEST_TIMEOUT_MS-scale stall", which a 2 s bound still
catches versus the 5 s pathology) or retry once before declaring failure.

### IN-02: int() coercion turns a non-numeric position_ms into a silent seek-to-0

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:334-336`
**Issue:** `int()` on a non-numeric scalar warns "Argument isn't numeric" into
the LMS log and yields 0 — a malformed `position_ms` becomes a seek to 0:00
instead of a refused command. Current callers only pass values from LMS's own
control bodies, so exposure is low.
**Fix:** Mirror the adjacent `uri` validation's refuse-don't-forward stance:

```perl
require Scalar::Util;
for my $numericParam (qw(position_ms volume)) {
    next unless defined $params{$numericParam};
    unless (Scalar::Util::looks_like_number($params{$numericParam})) {
        $log->warn("SoloistWS: refusing '$command' with non-numeric $numericParam");
        return 0;
    }
    $params{$numericParam} = int($params{$numericParam});
}
```

---

_Reviewed: 2026-08-27T09:14:06Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
