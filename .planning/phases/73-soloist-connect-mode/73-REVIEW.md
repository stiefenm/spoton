---
phase: 73-soloist-connect-mode
reviewed: 2026-08-26T18:46:36Z
depth: standard
files_reviewed: 10
files_reviewed_list:
  - Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c
  - Plugins/SpotOn/Connect.pm
  - Plugins/SpotOn/Plugin.pm
  - Plugins/SpotOn/ProtocolHandler.pm
  - Plugins/SpotOn/Settings.pm
  - Plugins/SpotOn/Soloist.pm
  - Plugins/SpotOn/Unified/DaemonManager.pm
  - Plugins/SpotOn/Unified/SoloistDaemon.pm
  - Plugins/SpotOn/Unified/SoloistWS.pm
  - Plugins/SpotOn/Vendor/Protocol/WebSocket.pm
findings:
  critical: 2
  warning: 11
  info: 7
  total: 20
status: issues_found
---

# Phase 73: Code Review Report

**Reviewed:** 2026-08-26T18:46:36Z
**Depth:** standard
**Files Reviewed:** 10
**Status:** issues_found

## Summary

Reviewed all Phase 73 source changes (persistent Soloist daemon, WS event client, browse Model B, fake-libpulse HTTP mode, cleanup). Findings were verified against the **real LMS install on this machine** (`/usr/share/perl5/Slim/...`), not just the test stubs — which matters, because the single most severe finding (CR-01) is invisible to the phase's own test suite precisely because the isolated-require harness stubs `Slim::Utils::Accessor` with hash-based objects while the real one uses **blessed arrays**. As written, `SoloistWS->new` dies on every real LMS, rendering the entire phase's runtime behavior (Connect events, browse playback, WS control dispatch) inert.

All seven prior-review concerns were verified: five confirmed as real defects (WR-01, WR-02, WR-03, WR-04, WR-05), one confirmed as a broader stuck-state class (WR-06), and one confirmed as degraded-but-safe behavior (IN-05). One prior concern (spurious pause on browse advance) escalates to CR-02 after tracing the LMS notification flow against Connect.pm's own documented echo-suppression rationale.

The vendored `Protocol::WebSocket` tree was spot-verified byte-identical to the LMS 9.2 bundle (`Client.pm`, `Handshake/Client.pm` diff clean) — no findings there, but its `write()` semantics (silent frame drop pre-handshake) are load-bearing for WR-01.

## Structural Findings (fallow)

None provided — no structural pre-pass accompanied this review.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: SoloistWS->new dies on real LMS — hash deref on a blessed-array Accessor object

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:97`
**Issue:** `weaken($self->{daemon}) if $self->{daemon};` — `SoloistWS` inherits from `Slim::Utils::Accessor`, whose objects are **blessed ARRAY refs** (`sub new { return bless [], $class }`; storage is `$_[0]->[$n]` via `Class::XSAccessor::Array` or the pure-Perl fallback — verified against `/usr/share/perl5/Slim/Utils/Accessor.pm`). `$self->{daemon}` is a hash dereference of an array ref and dies with `Not a HASH reference` — already in the `if` condition, so `new()` **always** dies in production. The call site is `SoloistDaemon::_pollWsPort` (a timer callback); `Slim::Utils::Timers` evals callbacks and logs `Timer ... failed`, so LMS survives, but `_ws` is never set: no WS client, no Connect events, `getNextTrack` always errors with "Soloist daemon not ready", and every control command falls to the Web API path. **The entire Phase 73 feature set is dead on a real LMS.** The test suite passes only because `t/31_soloist_ws.t` (and siblings) stub `Slim::Utils::Accessor` as `bless {}` with hash-based accessors — the stub diverges from the production contract in exactly the dimension this line depends on.
**Fix:** Use the Accessor's native weak-reference type instead of a manual `weaken`:
```perl
# Remove 'daemon' from the rw list and declare it weak:
__PACKAGE__->mk_accessor( weak => qw(daemon) );
__PACKAGE__->mk_accessor( rw => qw( mac port connected ... ) );

# In new():
$self->daemon($args{daemon});   # weak accessor weakens on store
# delete line 97 entirely
```
Also fix the test stub's `Slim::Utils::Accessor` to be array-based (`bless []`, slot indices, plus a `weak` type) so this class of divergence can't recur silently.

### CR-02: Seeded browse advance pauses Soloist via un-suppressed internal LMS stop event

**File:** `Plugins/SpotOn/Connect.pm:437-456` (browse branch of `_onPause`), interacting with `Plugins/SpotOn/Unified/SoloistWS.pm:496-503` and `Plugins/SpotOn/ProtocolHandler.pm:645-649`
**Issue:** On a seeded-match advance, `_onBrowseTrackChanged` executes a source-marked `['playlist','index','+1']`. LMS internally stops the previous stream during a playlist jump, generating a `['playlist','stop']` **notification without a source** — Connect.pm's own comments document exactly this phenomenon twice ("LMS fires internal pause/stop events during playlist jump", "LMS internally stops the previous item which generates a stop event") and defends the Connect path with a 1s echo window plus a 3s `connectStartTime` grace period. The new browse branch has **only** the source-marker check (`PLUGIN_SPOTON_SOLOIST_BROWSE`), which the internal stop does not carry. Sequence on every gapless advance: browse session still active → `_soloistBrowseWs` resolves → internal stop forwarded as WS `pause` → Soloist pauses the track it just transitioned into → `getNextTrack` re-entry sees `browseAdvancePending` and (correctly) skips re-issuing `play` → nothing ever unpauses → silence after every seeded advance. The Model-B advance mechanism defeats itself.
**Fix:** Give the browse branch the same grace discipline the Connect path has — record a timestamp when the advance request is executed and suppress pause/stop forwarding within a short window:
```perl
# SoloistWS::_onBrowseTrackChanged, before $req->execute():
$self->browseAdvanceTs(Time::HiRes::time());

# Connect.pm browse branch, before forwarding a non-unpause event:
my $advTs = $browseWs->can('browseAdvanceTs') ? ($browseWs->browseAdvanceTs || 0) : 0;
return if !$isUnpause && (Time::HiRes::time() - $advTs) < 3;
```
Apply the same suppression to the `startBrowseTrack` path (a fresh browse play also triggers an internal stop of the previous item; today that pause is immediately overridden by the subsequent `play`, but it is a race, not a guarantee).

## Warnings

### WR-01: connected(1) set before the WS handshake completes — commands silently lost, fallback skipped

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:159` (and `sendCommand`, lines 236-259)
**Issue:** `connect()` marks `connected(1)` immediately after the TCP connect, but the handshake completes only after the response round-trips through the select loop. The vendored `Protocol::WebSocket::Client::write()` (verified in `Vendor/Protocol/WebSocket/Client.pm:128-143`) **silently drops the frame with only a `warn`** when `is_ready` is false. So any `sendCommand` issued in the connect window is discarded while returning 1 — `Connect.pm::_sendControlCommand` then treats the command as delivered and skips the D-15 Web API fallback. A hung daemon that never answers the handshake leaves `connected` true forever (no handshake timeout), permanently in this frame-dropping state until the socket closes.
**Fix:** Track handshake completion separately: set `connected(1)` inside the client's `connect` callback (which fires when the handshake is done, alongside the existing `get_auth_state` send), keep a `_sockOpen` flag for socket lifecycle, and add a handshake timeout (e.g. 5s timer → `_onClosed`). Guard `_onClosed`'s re-entry check on the socket flag, not `connected`.

### WR-02: reconnectDelay never reset after a successful reconnect

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:200-217`
**Issue:** `_scheduleReconnect` doubles `reconnectDelay` on every attempt; nothing ever resets it to `RECONNECT_DELAY_MIN` after a connection succeeds. After one flaky period drives it to 30s, every future single-drop reconnect (including routine daemon restarts while the object survives) waits up to 30s — a 30s Connect/browse outage where 1s would do.
**Fix:** `$self->reconnectDelay(RECONNECT_DELAY_MIN);` in the handshake-complete (`connect`) callback (same place WR-01 moves `connected(1)` to).

### WR-03: startBrowseTrack return value ignored; failed send leaves a phantom browse session

**File:** `Plugins/SpotOn/ProtocolHandler.pm:655` and `Plugins/SpotOn/Unified/SoloistWS.pm:688-703`
**Issue:** `startBrowseTrack` sets `browseSession(1)`/`browseCurrentUri` **before** calling `sendCommand`, and `getNextTrack` ignores its return value, calling `$successCb->()` unconditionally. If the send fails (pre-handshake drop per WR-01, syswrite failure, race with `_onClosed`), LMS proceeds to open `/stream` and plays silence, while `browseSession=1` suppresses all Connect event translation (`_emitAllowed`) — a stuck state that persists until some other path ends the session.
**Fix:** In `startBrowseTrack`, roll back state when the send fails (`$self->browseSession(0) ... return 0;`); in `getNextTrack`, check the return and call `$errorCb->('PROBLEM_OPENING', ...)` instead of `$successCb->()` on failure.

### WR-04: browseAdvancePending consumed without URI comparison — user skip racing a seeded advance swallows the play command

**File:** `Plugins/SpotOn/ProtocolHandler.pm:645-649`
**Issue:** The re-entry guard clears `browseAdvancePending` and skips `play` for **whatever** track `getNextTrack` was invoked with. If a user skip (or any other playlist navigation) lands between `_onBrowseTrackChanged` setting the flag and the seeded-advance's own `getNextTrack` re-entry, the flag is consumed for the *wrong* track: no `play` is issued for the user's chosen track, Soloist keeps playing the seeded one, and the Pitfall-4 correction machinery then fights the divergence. The flag also leaks (stays 1) when the `unless ($ws && $ws->connected)` error path is taken with the flag set, corrupting the next getNextTrack.
**Fix:** Only honor the guard when the requested URI matches the state machine's expectation, and clear it on every entry:
```perl
my $pending = $ws->browseAdvancePending;
$ws->browseAdvancePending(0);
if ($pending && ($ws->browseCurrentUri // '') eq "spotify:$type:$id") {
    # skip play -- Soloist already playing this exact track
} else {
    $ws->startBrowseTrack("spotify:$type:$id", $client) or return $errorCb->(...);
}
```

### WR-05: streamingMode=proxy per-player pref bypassed for soloist Browse

**File:** `Plugins/SpotOn/ProtocolHandler.pm:181-200` (soloist branch of `canDirectStream`)
**Issue:** The soloist browse branch returns the direct `/stream` URL **before** the COMPAT-02 streamingMode gate, whose own comment states it "forces LMS-relayed streaming for BOTH Browse and Connect (D-02)". A player configured with `streamingMode=proxy` (the GH #96 WiiM metadata workaround) direct-streams anyway under the soloist backend — a silent regression of a shipped per-player preference.
**Fix:** Evaluate the streamingMode resolution (per-player → global) inside the soloist branch before returning `$ds_url`, returning 0 for proxy mode (and add the corresponding proxy substitution in `new()`, which the synced-path b3 block already provides — extend its condition to `isSynced() || proxyMode`).

### WR-06: No LMS-side termination hook for a browse session — stuck browseSession blocks Connect translation

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:714-729` (endBrowseSession call graph), `Plugins/SpotOn/Connect.pm:437-456`
**Issue:** `endBrowseSession` is only ever invoked from daemon-side events (track_end stop, device_changed is_active:false, Pitfall-4 queue_end). No LMS-side action ends the session: user stop, playlist clear, power-off, or starting non-Spotify playback leaves `browseSession=1` (the `_onPause` browse branch forwards `pause` but never ends the session). Consequences: (a) `_emitAllowed` suppresses all Connect translation indefinitely — notably, a subsequent app-driven transfer-in arrives as `device_changed`/`track_changed` with `browseSession` still set and is mis-routed into the browse state machine (`_onBrowseTrackChanged` "corrects" the Connect track or force-ends with `queue_end`+pause) instead of starting a Connect session; (b) when Soloist later reaches its track end while the user is already playing something else, the `'stopped'`-no-seed branch fires a `['playlist','index','+1']` into the user's **current** (non-browse) playlist — an unrequested skip. `DaemonManager->stopHelper` mid-browse likewise drops the WS object without deactivating anything on the daemon.
**Fix:** End the session from the LMS side: in `_onPause`'s browse branch, call `$browseWs->endBrowseSession('lms_stop')` for stop (non-pause) commands; additionally end the session in `_onNewSong`/`getNextTrack` when the new song URL is not a `spoton://track|episode:` URL; and guard the `'stopped'`-no-seed advance by verifying the client's currently playing URL is still the browse track before executing `playlist index +1`.

### WR-07: Multi-daemon race — `_pollHttpPort` glob-unlinks other daemons' live HTTP port files

**File:** `Plugins/SpotOn/Unified/SoloistDaemon.pm:360-362`
**Issue:** On every poll completion (success *and* failure), `_pollHttpPort` unlinks **all** `spoton-soloist-http-*` files in the shared spoton cache dir. fake-libpulse writes its port exactly once, at dlopen (`_http_start_server`, constructor). With multiple players' daemons starting concurrently (stagger only spaces the spawns; LMS main-loop congestion can delay any daemon's Perl-side poll arbitrarily), daemon A's cleanup can delete daemon B's port file after B's constructor wrote it but before B's poll read it — B then times out after 10s and `stop()`s a perfectly healthy daemon, feeding the crash-backoff loop.
**Fix:** Unlink only the daemon's own `$tmpfile` here; move the global stale-file sweep to a single boot-time location (e.g. `DaemonManager::init` or `_cleanupOrphanedLogs`), where no daemon can be mid-announcement.

### WR-08: `$msg->{item}{uri}` dies on non-hash `item` — violates the module's own never-die contract

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:441` and `749`
**Issue:** `_onTrackChanged` (`$msg->{item} && $msg->{item}{uri}`) and `_onPlaybackState` (`$item && $item->{uri}`) dereference `item` as a hash without a `ref` check. A scalar/array `item` (payload shapes are explicitly unconfirmed — A4 in the phase's own summary) dies with `Not a HASH reference` inside the Select read callback. LMS's EV dispatch evals the callback (verified in `Slim/Networking/IO/Select.pm:119`), so the server survives, but processing of all remaining frames in that read burst is aborted, and the header comment's promise ("never die on malformed input, this runs inside the single LMS process", V5/T-73-03) is broken for exactly the field-shape drift the code claims to defend against.
**Fix:** `my $uri = (ref($msg->{item}) eq 'HASH') ? $msg->{item}{uri} : undef;` in both handlers (same for the `position` hash already handled correctly in `_onPlaybackState` — mirror that pattern).

### WR-09: Orphaned soloist processes never cleaned up — resurrects the data-dir-lock failure mode

**File:** `Plugins/SpotOn/Plugin.pm:411+` (`_killOrphanedProcesses`), `Plugins/SpotOn/Unified/SoloistDaemon.pm:228-232`
**Issue:** Orphan cleanup only targets the librespot helper binary name (`Plugins::SpotOn::Helper->get()`); the `soloist` binary is never swept. `die_upon_destroy => 1` does not survive a SIGKILLed/OOM-killed/crashed LMS. A leftover soloist process keeps its per-player data-dir lock, WS port, and HTTP port; after LMS restarts, the fresh spawn for the same player collides with the survivor (the exact "zombie daemon"/data-dir-lock class of failure this project — and Phase 73's Model B specifically — set out to eliminate). The pre-spawn stale-file unlink removes `ws.port`/`soloist.pid` files but cannot release the live process's lock.
**Fix:** Extend `_killOrphanedProcesses` to also sweep processes whose executable matches `Plugins::SpotOn::Soloist->get()` (excluding `DaemonManager->helperPids`, which already includes live SoloistDaemon pids), on both the Unix and Windows branches (Windows is a no-op today since soloist is Linux-only, but keep the guard structural).

### WR-10: Expiry-days value stale — append-mode head-read parses the oldest run; countdown never decreases

**File:** `Plugins/SpotOn/Unified/SoloistDaemon.pm:472-496`, `Plugins/SpotOn/Settings.pm` (expiry display)
**Issue:** `_parseExpiryDays` reads the **first** 8 KiB of the capture file from offset 0. In `diagnosticMode` the log is opened `'>>'` (append), so the head belongs to the oldest run — the parsed `days` is frozen at whatever the first-ever run reported. Independently, the `'never'`-TTL cache entry stores `checked_at` but Settings displays `days` as-is: a daemon that runs uninterrupted for weeks shows an unchanged countdown, undermining the ≤14-day warning threshold (`soloistExpiryWarn`) the display exists for.
**Fix:** Read from `_stderrStartOffset` (this run's start) instead of offset 0; in `Settings.pm`, display `max(0, $days - int((time() - $checked_at) / 86400))` and derive the warn flag from the adjusted value.

### WR-11: fake-libpulse: idle LAN connection stalls the single streaming thread for up to 2s per connect

**File:** `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:474-517, 562-618`
**Issue:** The server thread handles accept and streaming in one loop. On accept it first performs the takeover (closing the current player's connection), then calls `_http_discard_request`, which blocks up to `HTTP_REQUEST_TIMEOUT_MS` (2s) waiting for request bytes. Any LAN host connecting and sending nothing (portscanner, health checker, misbehaving client) both **disconnects the active player** and **freezes the ring drain for 2s** — repeated connects yield continuous audio interruption. The INADDR_ANY bind and takeover-wins semantics are documented librespot-parity decisions, but the 2s blocking header read in the drain thread is new to this implementation.
**Fix:** Don't take over until the request head has actually arrived: accept into a "pending" fd, poll it alongside the listen/streaming work (add it to the pollfd set with its own deadline), and only close the current client and switch once a complete request head (or at minimum a first line) is read. That preserves takeover semantics while removing both the drain stall and the trivially-triggered disconnect.

## Info

### IN-01: Dead Windows branch in SoloistDaemon::start

**File:** `Plugins/SpotOn/Unified/SoloistDaemon.pm:198-201`
**Issue:** `if (main::ISWINDOWS && $stderr_fh)` is unreachable — `start()` returns at line 106 on Windows.
**Fix:** Delete the block.

### IN-02: Poll-guard comments claim state that stop() never clears

**File:** `Plugins/SpotOn/Unified/SoloistDaemon.pm:270, 335, 392-416`
**Issue:** `_pollWsPort`'s guard comment says "stop() cleared state" but `stop()` never undefs `_proc`; only the killed timers prevent the poll from running. Works today, but the guard documents a contract that doesn't exist — a future caller of `_pollWsPort` after `stop()` would not be stopped by it.
**Fix:** Either clear `_proc` in `stop()` (after `->die`) or correct the comments to reference the killed timers.

### IN-03: Redundant condition in ProtocolHandler::new b3 block

**File:** `Plugins/SpotOn/ProtocolHandler.pm:505`
**Issue:** `$url !~ m{spoton://connect-}` is dead — the preceding anchored `^spoton://(?:track|episode):[A-Za-z0-9]+$` match already excludes connect URLs.
**Fix:** Drop the second condition.

### IN-04: Possible undef assignment to $ENV{LD_LIBRARY_PATH}

**File:** `Plugins/SpotOn/Unified/SoloistDaemon.pm:216-218`
**Issue:** When `libPath()` returns undef and no prior `LD_LIBRARY_PATH` exists, the ternary assigns `undef` to `$ENV{LD_LIBRARY_PATH}` — an uninitialized-value warning and a spurious empty env var in the child (restored correctly afterward).
**Fix:** Skip the assignment entirely when `$libPath` is undef.

### IN-05: Queue seeding silently disabled for tracks without duration (prior-review item — confirmed degraded, not broken)

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:626-631`
**Issue:** `_maybeSeedBrowseQueue` returns when `$song->duration` is 0/undefined, so gapless seeding never happens for tracks with missing duration metadata. The `'stopped'`-no-seed fallback advances correctly, so the impact is an audible gap, not a stall. Worth a one-time debug log so a systematic metadata gap (e.g. episodes) is diagnosable in the field.
**Fix:** Add a debug log on the zero-duration early return.

### IN-06: _ring_init does not check malloc failure

**File:** `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:316-324`
**Issue:** `r->buf = malloc(RING_CAPACITY)` unchecked; a NULL buffer leads to memcpy-to-NULL in `_ring_push`. Unlikely (~700 KiB), but the guard is one line.
**Fix:** On malloc failure, leave `g_http_mode = 0` (constructor checks `_ring_init` return) so the library degrades to the non-HTTP path instead of crashing Soloist.

### IN-07: _onPlaybackState pollutes Connect baseline during a browse session

**File:** `Plugins/SpotOn/Unified/SoloistWS.pm:745-789`
**Issue:** Unlike `_onTrackChanged`/`_onPlaybackChanged`, `_onPlaybackState` has no `browseSession` gate: a `get_state` snapshot arriving during a browse session (e.g. after a WS reconnect mid-browse) updates `lastTrackId`/`lastVolume`/`lastPositionMs` and can set `sessionActive(1)` from browse playback. Emissions are gated by `_emitAllowed`, but the polluted baseline produces a spurious `change`/`seek`/`volume` correction the moment the browse session ends and a real Connect snapshot is reconciled.
**Fix:** Early-return (after `_maybeSeedBrowseQueue`-style bookkeeping if desired) when `$self->browseSession`, matching the other two handlers.

---

## Prior-Review Concern Disposition

| Prior concern | Disposition |
|---|---|
| Browse session stuck states (daemon stop + WS write failure) | Confirmed — WR-03 (phantom session on failed send), WR-06 (no LMS-side termination hook) |
| streamingMode=proxy bypass in canDirectStream | Confirmed — WR-05 |
| reconnectDelay never reset after successful reconnect | Confirmed — WR-02 |
| getNextTrack ignoring startBrowseTrack return value | Confirmed — WR-03 |
| connected(1) set before WS handshake completes | Confirmed — WR-01 (aggravated: vendored client silently drops pre-handshake frames while sendCommand reports success, defeating the Web-API fallback) |
| _maybeSeedBrowseQueue failing on 0 duration | Confirmed as degraded-mode only — IN-05 |
| browseAdvancePending race with user skip | Confirmed — WR-04 (no URI comparison; flag also leaks on the error path); escalated sibling: CR-02 (advance's internal stop event pauses Soloist) |

---

_Reviewed: 2026-08-26T18:46:36Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
