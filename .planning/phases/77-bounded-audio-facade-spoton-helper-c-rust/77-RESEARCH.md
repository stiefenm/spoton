# Phase 77: Bounded Audio Facade (spoton-helper, C/Rust) - Research

**Researched:** 2026-09-01
**Domain:** C shared-library audio proxy (fake-libpulse.so.0), Perl LMS plugin glue (SoloistWS/Connect/ProtocolHandler), CI cross-compile
**Confidence:** HIGH (grounded in this session's direct reads of the actual repo files and current `make test` run — not generic C/Perl advice)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Pre-Cleanup (Wave 0)**
- **D-01:** All 5 code review items (CR-1 + CR-S1..S4) go into Phase 77 Wave 0. Clean foundation before hardening.
  - CR-1: `g_ring_underrun_fired` atomic fix in fake-libpulse.c (C11 `atomic_int`) — Reversibility: reversible
  - CR-S1: Extract `_detectSeek()` helper from Connect.pm:800-882 — Reversibility: reversible
  - CR-S2: `_hasLogin5Creds` 17× guard pattern (SpClient.pm) — evaluate wrapper, low priority — Reversibility: reversible
  - CR-S3: `_pollWsPort`/`_pollHttpPort` duplication merge (SoloistDaemon.pm) — careful, different error handling — Reversibility: reversible
  - CR-S4: Inline slice → `_sliceAsPage` (SpClient.pm) — Reversibility: reversible

**Seek Parameter (start=N)**
- **D-02:** Seek via WS command + ring flush. ProtocolHandler passes `start=N` → SoloistWS sends seek-command to daemon → daemon flushes ring → HTTP waits for post-flush data → serves from new position. No pre-seek audio in response. — Reversibility: costly — seek contract is consumed by ProtocolHandler and Phase 78 bounded endpoint integration
- **D-03:** C-side waits for flush completion. fake-libpulse recognizes `pa_stream_flush` callback, invalidates old boundary, blocks HTTP-thread read-loop until post-flush data arrives. Simplest model, no Perl-side coordination needed. — Reversibility: reversible

**Rapid-Skip + Edge Cases**
- **D-04:** Last-wins + flush for rapid track changes. Each new `POST /boundary` overwrites previous marker. Stale client reading old track gets `g_flush_disconnect` → socket close → LMS sees EOF. — Reversibility: reversible
- **D-05:** URI-Mismatch: Daemon play-command + flush. ProtocolHandler detects mismatch, sends play-command via WS, daemon flushes ring + starts new track. HTTP waits for post-flush data. Same mechanism as seek (D-02/D-03). — Reversibility: costly — mismatch-handling contract shared with Phase 78
- **D-06:** Stale-client cleanup via existing `g_flush_disconnect` pattern. HTTP-thread checks flag in read-loop, closes socket on set. Already implemented in spike. — Reversibility: reversible

**Production Hardening**
- **D-07:** Host-tests + Live-UAT. C host-tests for all new edge cases (seek+flush, rapid-skip, mismatch, stale-client). Then live UAT with real audio. No fuzzing/stress-test in this phase. — Reversibility: reversible
- **D-08:** EOF + LMS retry on daemon crash. HTTP-thread detects daemon death (no ring-writer), closes socket cleanly (EOF). LMS sees playback stop, ProtocolHandler can retry/reconnect. No special recovery code. — Reversibility: reversible
- **D-09:** CI binary rebuild at Phase 77 end. Trigger CI for all 3 architectures (x86_64, aarch64, armv7). Binary rebuild is prerequisite for Phase 78 live testing. — Reversibility: reversible

**Carrying Forward (locked from prior phases)**
- **D-10 (from 78/D-01):** First track serves unbounded — no boundary before first `track_changed`.
- **D-11 (from 78/D-02):** Session-end: daemon `stopped` → `POST /boundary` → clean EOF.
- **D-12 (from 78/D-05):** Skip = Flush + implicit EOF. `pa_stream_flush` → `g_flush_disconnect` closes client.
- **D-13 (from 76/D-04):** Ring-buffer is S32LE (32-bit depth). Write rate ~327,680 bytes/sec.

### Claude's Discretion

Not explicitly enumerated as a separate section in 77-CONTEXT.md — all in-scope decisions are locked above. The **specific C-level mechanism for distinguishing a seek-flush from a skip/mismatch-flush inside `pa_stream_flush()`** (i.e., what exact signal/flag/endpoint arms the "don't disconnect" behavior) is left to the planner/implementer; D-02/D-03 specify the *contract*, not the wire mechanism. This research proposes one concrete, code-grounded mechanism below (see Architecture Patterns → Pattern 1).

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope (per 77-CONTEXT.md `<deferred>`).

</user_constraints>

<phase_requirements>
## Phase Requirements

No REQUIREMENTS.md IDs are mapped to Phase 77 in `.planning/REQUIREMENTS.md`'s Traceability table (that table covers only the v2.3 Library Integration milestone; this is v4.0 Soloist Integration work tracked entirely through ROADMAP.md + CONTEXT.md decisions D-01..D-13 above). The planner should treat D-01 through D-13 as the requirement set for this phase — each PLAN.md task should trace back to one of these decision IDs.

</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Language boundary:** Perl (>= 5.10, LMS floor) for all `Slim::Plugin::*` glue; C for `fake-libpulse.c` (compiled with plain `gcc`/cross-`gcc`, no build system beyond the existing `Makefile`); Rust only inside `librespot-spoton` (this phase's file scope does not touch Rust source — see Environment Availability's `cargo`/`rustc` note).
- **No external CPAN dependencies:** All Perl changes in this phase (SoloistWS.pm, Connect.pm, ProtocolHandler.pm, SoloistDaemon.pm, SpClient.pm) must use only LMS-bundled modules (`JSON::XS`, `Digest`, etc. — see CLAUDE.md's Bundled CPAN Modules table). No new `cpanm`/`cpan` installs.
- **No new external packages of any kind** — confirmed in Package Legitimacy Audit above (N/A, zero new packages this phase).
- **Async HTTP idiom:** `Slim::Networking::SimpleAsyncHTTP` is the LMS idiom for any new Perl-side HTTP calls (e.g., if the seek-arm control POST to fake-libpulse's HTTP port is issued from Perl) — not `LWP::UserAgent` (blocks; LMS is single-threaded) and not a new dependency.
- **GSD Workflow Enforcement:** file-changing work must go through `/gsd-execute-phase` (or another GSD entry point) — this research output feeds `/gsd-plan-phase`, which is itself part of that required flow. No direct repo edits outside GSD are authorized by this research document.
- **Branding/compliance:** not implicated by this phase's scope (no Spotify Design Guidelines surface touched — this is transport-layer audio serving, not UI/branding).
- **Connect/Browse architecture already established:** LMS version floor 8.0 (full features 8.5.1+), librespot-derived Soloist binary as the only playback engine for this feature — Phase 77 works entirely within this existing architecture, introducing no new engine or protocol.

## Summary

Phase 77 hardens an already-working prototype (Spikes 1+2, committed in `6cf03a8`/`e62557b`) rather than building greenfield. The C side (`fake-libpulse.c`, 3015 lines) already implements: a lock-based S32LE ring buffer with monotonic `total_pushed`/`total_popped` counters, a single-threaded `select()`-free `poll()`-based HTTP server, a `POST /boundary` control request that plants a "close-at-this-offset" marker consumed by the same thread's drain loop, and a `g_flush_disconnect` flag that force-closes the currently attached client whenever `pa_stream_flush()` is called by the Soloist binary (skip/seek/mismatch all funnel through this one PulseAudio API call).

This session traced the exact root cause of the Phase 78 UAT seek failure (test 10, `78-UAT.md`) directly in the code: `pa_stream_flush()` (fake-libpulse.c:1976-2013) sets `g_flush_disconnect = 1` **unconditionally**, with no way to distinguish "this flush is a deliberate skip" (where disconnect-and-let-LMS-reconnect is correct, D-12) from "this flush is a seek within the same track" (where the client should stay attached and just wait for post-flush data, D-02/D-03). Because `pa_stream_flush()` is the daemon's only synchronous entry point into fake-libpulse.c for this class of event, and it is called identically by the closed-source Soloist binary for both cases, the distinction **cannot** be made from inside `pa_stream_flush()` alone — it requires an out-of-band signal from Perl, arriving before the flush, over the same HTTP control channel `POST /boundary` already uses. Connect.pm's existing `_onSeek`/`_bufferedBrowseSeek` path (Connect.pm:812-871) drives the WS seek command asynchronously off LMS's `time` event with a 0.3s debounce (`SEEK_DEBOUNCE`), racing independently against LMS's own stream-restart (`canSeek`/`getSeekData` returning `{timeOffset=>N}`, ProtocolHandler.pm:1061-1105) — this is the documented, already-anticipated race (ProtocolHandler.pm:824-830 comment cites "RESEARCH Pitfall 5"). Phase 77 D-02 explicitly redirects seek dispatch to ProtocolHandler (the same module that already resolves `$song->seekdata->{timeOffset}` and rebuilds the direct-stream URL), making the arm-then-command ordering deterministic instead of racy.

**Primary recommendation:** Add a new lightweight HTTP control request (sibling to `POST /boundary`, same trust boundary, same thread) that arms a one-shot "next flush is a seek, not a skip" flag in fake-libpulse.c *before* SoloistWS.pm sends the WS `seek` command to the daemon. `pa_stream_flush()` consumes that flag: when armed, it flushes the ring and invalidates the boundary marker exactly as today, but does **not** set `g_flush_disconnect` — instead it should also gate the drain loop so no ring bytes are written to whatever client is attached until a flush actually lands (preventing the already-documented "brief burst of pre-seek audio" symptom). Move the seek dispatch itself out of Connect.pm's debounced, LMS-`time`-event-driven path into ProtocolHandler.pm's `getNextTrack` (the `$daemonCurrent eq $id` / resume branch, ProtocolHandler.pm:786-796), which is the single call site LMS's own seek-restart connection request already flows through — this removes the independent-timing race entirely rather than narrowing the window.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Ring buffer, S32LE conversion, HTTP `/stream` serving | C shared lib (fake-libpulse.so.0, in-process with daemon) | — | Only component with access to raw PCM from `pa_stream_write()`; owns the byte-accurate boundary/EOF contract |
| Track-boundary marking, flush-vs-seek distinction | C shared lib | Perl (SoloistWS.pm as trigger) | The marker/flag lives in ring-adjacent global state only the C server thread can consume without a lock-ordering hazard; Perl only ever *arms* it via HTTP control POST |
| Seek/skip/URI-mismatch decision (which one is this?) | Perl (ProtocolHandler.pm + SoloistWS.pm) | — | Only LMS-side code knows *why* a new connection request arrived (seek-restart URL vs. genuine new track vs. Connect-driven play) |
| Browse-vs-Connect event discrimination | Perl (SoloistWS.pm `_emit`, `soloistBrowseActive`) | — | Already fixed in the 2026-09-01 `browse-connect-gating.md` session; orthogonal to Phase 77's C-side scope but touches the same files (SoloistWS.pm, ProtocolHandler.pm) — plans must diff carefully against this recent change |
| Daemon lifecycle (spawn, port announce, crash recovery) | Perl (SoloistDaemon.pm) | C shared lib (process-death implies socket-death, since it's in-process) | `Proc::Background`-style spawn/poll is Perl; D-08's "EOF on daemon crash" is a property of the OS closing the listening process's sockets, not new C code |
| CI binary rebuild (3 architectures) | GitHub Actions (`build-fake-libpulse.yml`, `build-librespot.yml`) | — | Cross-compile toolchain concerns (glibc vs musl) are infrastructure, not application logic |

## Standard Stack

This phase introduces **no new external dependencies** — it is a hardening pass over an existing C file (compiled with plain `gcc`/cross-gcc, `-lpthread -lm`) and existing Perl modules (LMS-bundled CPAN only, per CLAUDE.md). C11 atomics (`stdatomic.h`, `atomic_int`) required for CR-1 are part of the C standard library, not a separate dependency, and available without extra `-std=` flags on the GCC versions this project's CI already uses (verified: `gcc` on `ubuntu-latest` and the `gcc-aarch64-linux-gnu`/`gcc-arm-linux-gnueabihf` cross packages default to a GNU C standard ≥ gnu11, all of which ship `<stdatomic.h>`) [ASSUMED — not verified against the exact CI runner's GCC version this session; recommend a `checkpoint:human-verify` or a CI dry-run before merging the atomic-fix task].

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| C11 `<stdatomic.h>` | C11 (part of glibc toolchain) | `atomic_int` for `g_ring_underrun_fired` (CR-1) | Standard, zero-dependency fix for the documented cross-thread race; matches the existing `volatile` idiom already used for `g_flush_disconnect`/`g_boundary_at_pushed` in this file, just with correct atomicity guarantees on ARM's weaker memory model |
| POSIX `pthread` | glibc-bundled | Ring buffer mutex/condvar, HTTP server thread | Already in use throughout fake-libpulse.c; no change |

### Supporting

None — no new packages.

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `atomic_int` for `g_ring_underrun_fired` | Keep `int` + add `volatile` only (matching `g_flush_disconnect`'s existing style) | `volatile` prevents compiler caching but gives no atomicity/ordering guarantee across CPUs — exactly the CR-1 finding's concern on ARM's weak memory model. CONTEXT.md D-01 explicitly specifies C11 `atomic_int`, not `volatile`; do not substitute. |
| New HTTP control endpoint for seek-arm | Encode seek-intent as a query param on the existing `POST /boundary` request | Conflates two independent single-purpose signals (boundary-plant vs. seek-arm) in one endpoint; the existing `POST /boundary` handler (fake-libpulse.c:836-856) already has a `continue`-early-return shape that a second, distinct request type can mirror without touching it. A separate endpoint (e.g. `POST /seek-arm`) keeps each control message's parsing and effect independently testable. |

**Installation:** N/A — no new packages; `make -C Plugins/SpotOn/Bin/fake-libpulse` (unchanged invocation) picks up C source changes automatically.

## Package Legitimacy Audit

Not applicable — this phase adds zero external packages (no new `npm`/`pip`/`cargo`/CPAN dependencies). All work is in-repo C and Perl source changes plus a CI workflow dispatch. No `package-legitimacy check` run was needed.

## Architecture Patterns

### System Architecture Diagram

```
                         ┌─────────────────────────────────────────────┐
                         │        Soloist daemon process (Rust,        │
                         │        closed-source binary)                │
                         │                                              │
  LMS ProtocolHandler.pm │  dlopen("libpulse.so.0") ──► fake-libpulse.c │
  ── new HTTP GET ──────►│  (in-process, same PID)                     │
  (/stream/track?uri=..  │                                              │
   &start=N)             │  pa_stream_write(pcm) ─┐                    │
                         │                          │                   │
  SoloistWS.pm ──WS cmd─►│  {"command":"seek",      ▼                   │
  {play|seek|...}         │   position_ms:N}   ┌─────────────┐         │
                         │        │              │ ring_buffer │         │
                         │        ▼              │ (S32LE,     │         │
                         │  internal Soloist      │  20s cap)   │         │
                         │  seek/skip logic  ─────►│             │         │
                         │        │              └──────┬──────┘         │
                         │        │ pa_stream_flush()    │pop(50ms tick) │
                         │        ▼                      ▼               │
                         │  [FIX TARGET]           HTTP server thread    │
                         │  g_flush_disconnect     (poll()-based,        │
                         │  set UNCONDITIONALLY    single client_fd)     │
                         │  today; must become     │                     │
                         │  conditional on         │ writes PCM bytes    │
                         │  seek-armed flag         ▼                     │
                         └─────────────────── GET /stream client fd ─────┘
                                                       │
                                                       ▼
                                              squeezelite (LMS player)
                                              expects: continuous bytes,
                                              real socket-close = EOF
                                              (skip advances playlist)

  Control channel (same HTTP port, same thread, request-line dispatch
  BEFORE the GET /stream takeover logic):
    SoloistWS.pm --POST /boundary----------► plants g_boundary_at_pushed
                                              (existing, Spike 2)
    SoloistWS.pm --POST /seek-arm (NEW)-----► arms "next flush = seek,
                                              suppress disconnect" flag
                                              (this phase's proposed fix)
```

### Recommended Project Structure

No new files/directories — all changes are in-place edits to existing files:

```
Plugins/SpotOn/Bin/fake-libpulse/
├── fake-libpulse.c      # ring buffer, HTTP server, boundary+seek-arm logic, CR-1 atomic fix
├── Makefile              # unchanged — `make test` picks up new host-test cases automatically
Plugins/SpotOn/Unified/
├── SoloistWS.pm          # CR-S1 target (_detectSeek extraction), seek-arm dispatch (D-02)
├── SoloistDaemon.pm      # CR-S3 target (_pollWsPort/_pollHttpPort partial merge)
Plugins/SpotOn/
├── Connect.pm            # CR-S1 target, remove/relocate _onSeek's browse-seek branch per D-02
├── ProtocolHandler.pm    # D-02 seek dispatch relocation (getNextTrack resume branch)
Plugins/SpotOn/API/
├── SpClient.pm           # CR-S2 (_hasLogin5Creds wrapper, low priority), CR-S4 (_sliceAsPage in getAlbumTracks/getShowEpisodes)
.github/workflows/
├── build-fake-libpulse.yml  # D-09 CI trigger target (workflow_dispatch, 3-arch matrix)
```

### Pattern 1: Seek-Armed Flush (proposed fix for D-02/D-03, NOT yet implemented)

**What:** A one-shot flag, set via a new HTTP control POST on the same port/thread `POST /boundary` already uses, that changes `pa_stream_flush()`'s side effect from "force-disconnect the client" to "flush silently and let the drain loop naturally wait for fresh data."

**When to use:** Whenever the Perl side is about to send a WS `seek` command that it knows will trigger the daemon to call `pa_stream_flush()` for a **same-track** repositioning (not a track change/skip, which must still disconnect per D-12).

**Grounding — the exact code this changes:**

```c
// Source: Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:1976-2013 (current, unconditional)
pa_operation *pa_stream_flush(pa_stream *s, pa_stream_success_cb_t cb, void *userdata) {
    ...
    if (s && g_http_mode) {
        _ring_flush(&g_ring);
        _stream_refresh_timing(s, "flush");
        g_boundary_at_pushed = -1;
        /* 260827-of9: Soloist calls pa_stream_flush() on an app-side skip
         * (confirmed via trace) -- signal the HTTP thread to drop the
         * currently connected client so LMS reconnects fresh ... */
        g_flush_disconnect = 1;   // <-- fires for SEEK too today; this is the bug
    }
    ...
}
```

```c
// Source: Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:738-773 (consumption site, current)
if (g_flush_disconnect && client_fd >= 0) {
    close(client_fd);
    client_fd = -1;
    ...
    g_boundary_at_pushed = -1;
    ...
}
```

**Recommended shape of the fix** (not yet in the codebase — this is this session's proposed design, to be detailed by the planner):

1. New global, e.g. `static volatile int g_seek_flush_armed = 0;` (or `atomic_int`, matching the CR-1 fix style — recommend `atomic_int` for consistency given CR-1 establishes that pattern in the same Wave).
2. New control request handled in the same `if (pending.fd >= 0 && _pending_head_complete(&pending) && ...)` block that already special-cases `POST /boundary` (fake-libpulse.c:829-856) — add a sibling branch for e.g. `POST /seek-arm` that sets `g_seek_flush_armed = 1` and responds/closes exactly like the boundary handler does, `continue`-ing before the GET /stream takeover logic.
3. `pa_stream_flush()` becomes conditional:
   ```c
   if (s && g_http_mode) {
       _ring_flush(&g_ring);
       _stream_refresh_timing(s, "flush");
       g_boundary_at_pushed = -1;
       if (g_seek_flush_armed) {
           g_seek_flush_armed = 0;
           /* seek: ring is now empty/fresh; do NOT disconnect -- the
              existing 50ms drain-loop poll already retries an empty
              ring, so the attached client (old or freshly-taken-over)
              simply waits until post-seek pa_stream_write() calls
              refill it. */
       } else {
           g_flush_disconnect = 1;   /* skip/mismatch: unchanged (D-12) */
       }
   }
   ```
4. **"No pre-seek audio in response" (D-02) needs one more guard**, because the arm and the flush are not atomic with the ring's own state: if a *new* client attaches (via the existing takeover logic) *after* the arm but *before* the flush actually happens, it could still be handed whatever stale bytes are already sitting in the ring at that moment. Recommend also checking `g_seek_flush_armed` in the drain loop's write path (fake-libpulse.c:914-1050) and skipping writes (but not the poll) while armed — i.e. treat "armed but not yet flushed" as "ring is not yet trustworthy," symmetric to how `g_boundary_at_pushed` already gates writes near a boundary.
5. **Ordering guarantee**: because both the arm-POST and the WS `seek` command are dispatched from the *same* Perl call site back-to-back (recommended: ProtocolHandler.pm's `getNextTrack` resume branch, synchronous, arm-then-send), the arm is guaranteed to reach the C layer before the daemon's internal seek logic gets around to calling `pa_stream_flush()` — removing the previous 0.3s-debounce-driven race entirely. This matches D-03's "no Perl-side coordination needed" (Perl fires-and-forgets both calls; no ack-wait needed).

**Why the current architecture actually causes the two failure signatures seen in `78-UAT.md` test 10:** LMS's own seek-restart (`canSeek`/`getSeekData` returning `{timeOffset=>N}`, unconditionally for Browse — ProtocolHandler.pm:1079-1105) opens a **second, genuinely new** HTTP connection with `&start=N` in the URL (the C server does not parse this query string at all — "the C side answers any GET on the port," ProtocolHandler.pm:279 comment). The existing takeover logic (fake-libpulse.c:858-905) already correctly closes the old `client_fd` and promotes the new one when this second connection's request head completes — that part is *not* the bug. The bug is that the (previously async, 0.3s-debounced) WS-seek-triggered `pa_stream_flush()` call can land **either before or after** that takeover, and in *either* order it forces `g_flush_disconnect=1` against whatever `client_fd` happens to be attached at that moment — including the brand-new, just-taken-over connection that LMS/squeezelite has no reason to expect will die again. squeezelite sees an unprompted second close on a connection it just opened and, per the observed symptom ("Seek hat kurz geklungen als ob es funktioniert, dann zum Skippen geführt"), interprets it as track-end rather than a reconnect-worthy hiccup.

### Pattern 2: Existing Boundary-Marker Protocol (unchanged, for context)

**What:** `POST /boundary` plants `g_boundary_at_pushed = g_ring.total_pushed` (a write-cursor watermark); the drain loop caps how many bytes of the *current* popped chunk get written to the client once `total_popped` crosses that watermark, then closes the client for a clean per-track EOF.

**Already implemented and host-tested** (fake-libpulse.c:829-856 plant, :940-1006 consume). Do not restructure this for D-02/D-03 — Pattern 1 above is a **new, parallel** mechanism, not a modification of the boundary protocol. D-04 (rapid-skip, last-wins) is already satisfied by this pattern's existing "overwrite `g_boundary_at_pushed` on every new POST" behavior — no C code change needed for D-04, only new host tests exercising back-to-back `POST /boundary` calls with no intervening drain.

**Known accepted limitation** (already documented in the file, fake-libpulse.c:940-955): a boundary that lands mid-chunk can leak up to ~46ms (16383 bytes at S32LE 44.1kHz stereo) of next-track audio into the closed connection's final write before the trim applies, because `_ring_pop_timed()` has already fully removed the chunk from the ring before the boundary check runs. This is the source of the "16ms overshoot" figure in Spike 2's own result and is *not* a regression to fix in Phase 77 — D-07 explicitly scopes new host-tests to seek+flush/rapid-skip/mismatch/stale-client, not to shrinking this pre-existing, accepted overshoot window.

### Anti-Patterns to Avoid

- **Do not try to make `pa_stream_flush()` self-distinguish seek vs. skip from its own arguments.** The function signature (`pa_stream *s, pa_stream_success_cb_t cb, void *userdata`) carries no intent information, and the caller (Soloist's Rust binary) is closed-source and calls it identically for both cases — confirmed by the existing comment at fake-libpulse.c:550-561 ("Soloist calls `pa_stream_flush()` when it discards buffered audio on an app-side skip/seek" — both named in one sentence, same call). Any fix that tries to infer seek-vs-skip from ring state, timing, or `pa_stream` fields will re-introduce exactly the kind of race this phase exists to remove. The distinction must come from Perl, out-of-band, before the flush.
- **Do not move the seek-arm/seek-dispatch logic into Connect.pm's existing `_onSeek` debounced path.** That is the architecture the current bug lives in — the LMS `time` event and LMS's own internal stream-restart timing are two independently-scheduled things; D-02's "ProtocolHandler passes start=N" phrasing is a deliberate architectural relocation to a single, deterministic call site (the same one LMS's stream-restart connection request already flows through), not a compatible detail to keep alongside the C-side fix.
- **Do not conflate this phase's Browse-seek fix with the separately-resolved Browse/Connect event-discrimination bug** (`soloistBrowseActive`, resolved 2026-09-01 per `.planning/debug/browse-connect-gating.md`, awaiting live human verification). Both touch SoloistWS.pm/ProtocolHandler.pm in similar regions; a plan diffing against a pre-fix baseline could accidentally revert that resolution. Verify `soloistBrowseActive` is present in SoloistWS.pm/ProtocolHandler.pm before starting Phase 77 edits.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cross-thread flag synchronization | A custom mutex-protected flag for `g_ring_underrun_fired` | C11 `atomic_int` (`stdatomic.h`) | CONTEXT.md D-01 already specifies this; a mutex here would add lock-contention risk in a hot 50ms-tick drain loop for a single-bit flag — atomics are the standard, zero-contention primitive for this exact shape |
| Perl pagination slicing | A third hand-rolled offset/limit slice in a new call site | `SpClient->_sliceAsPage($list, $offset, $limit)` (already exists, SpClient.pm:1404-1417) | CR-S4 exists precisely because two call sites (getAlbumTracks, getShowEpisodes) already duplicate this exact 4-line block instead of calling the helper that other call sites (getAlbum, getShow, getPlaylistItems, search) already use |
| Seek-detection drift computation | A third copy of the `$elapsedMs`/`$expectedMs`/`$deltaSec`/`SEEK_THRESHOLD` block | `_detectSeek($old, $new)` helper (CR-S1, to be extracted) | `_onPositionSync` (SoloistWS.pm:784-815) and `_onPlaybackState` (SoloistWS.pm:831-882) already implement byte-for-byte identical drift math; a Phase 77 seek-arm addition must not become a third inline copy |

**Key insight:** every "Don't Hand-Roll" item in this phase is really the same lesson: this codebase already has the reusable primitive (`_sliceAsPage`, the boundary-marker watermark pattern, `SEEK_THRESHOLD`-based drift detection) — the CR items exist because some call sites were written before or alongside the shared helper and never converged. Phase 77's own new seek-arm mechanism (Pattern 1) should be built to look and feel like the existing `POST /boundary` mechanism (same thread, same request-parsing shape, same watermark idiom) rather than introducing a structurally different control-channel pattern.

## Common Pitfalls

### Pitfall 1: Fixing the seek race by *narrowing* the window instead of removing it
**What goes wrong:** A tempting quick-fix is to shorten `SEEK_DEBOUNCE` (Connect.pm:48, currently 0.3s) or add a small `sleep`/retry on the C side, hoping the race resolves in practice.
**Why it happens:** The symptom ("kurz geklungen als ob es funktioniert, dann zum Skippen") looks timing-sensitive, so timing tweaks look like plausible fixes.
**How to avoid:** The bug is architectural (two independently-scheduled paths — LMS's own stream-restart and Connect.pm's debounced WS dispatch — both able to reach the C layer in either order), not a tuning problem. D-02's relocation to ProtocolHandler.pm's synchronous call site removes the independent scheduling entirely; a debounce-tuning fix would still fail intermittently under load (documented already as "RESEARCH Pitfall 5" in ProtocolHandler.pm:828).
**Warning signs:** A host test that passes reliably but a live UAT re-check that still occasionally skips — that gap is exactly what a timing-only fix produces.

### Pitfall 2: Reverting the 2026-09-01 `soloistBrowseActive` fix by accident
**What goes wrong:** SoloistWS.pm and ProtocolHandler.pm were both modified in the *same session* this research was written to fix a *different* bug (Browse/Connect event hijacking, `.planning/debug/browse-connect-gating.md`). Phase 77's D-02 also touches ProtocolHandler.pm's `getNextTrack` and SoloistWS.pm's `_emit`/command dispatch. A plan branched from an older checkpoint, or a careless refactor, could silently drop the `soloistBrowseActive` gate.
**Why it happens:** Both fixes live in the same handful of functions (`getNextTrack`'s resume/play branches, `_emit`, `sendCommand`).
**How to avoid:** Before Wave 0, confirm `soloistBrowseActive` (grep for the exact string) is present in both files and that `t/29_soloist_browse.t` + `t/32_soloist_events.t` are green (confirmed this session: 71 + tests pass together with t/05; t/31 143 tests pass). Any Phase 77 plan task touching these functions should re-run these suites, not just the new fake-libpulse host tests.
**Warning signs:** `t/29`/`t/32` regressions after a Phase 77 edit that "only touched seek."

### Pitfall 3: Treating `g_flush_disconnect` suppression as sufficient without gating the drain-loop write path
**What goes wrong:** Just skipping the `g_flush_disconnect = 1` line for a seek-armed flush stops the disconnect, but if a client attaches (via ordinary takeover) *between* the arm and the actual flush, it can still be served stale (pre-seek) ring bytes for one or more 50ms ticks before the flush empties the ring — violating D-02's explicit "No pre-seek audio in response."
**Why it happens:** The arm and the flush are not atomic; the existing takeover logic (fake-libpulse.c:858-905) runs independently of the seek-arm state.
**How to avoid:** Gate the drain-loop's write path (not just the disconnect) on the armed flag, per Pattern 1 step 4 above — while armed-but-not-yet-flushed, do not write popped bytes to the client (whether the pre-existing or freshly-taken-over one).
**Warning signs:** A host test for "seek: no stale audio crosses the socket" that only checks disconnection, not byte content, would pass even with this gap present — the test itself must assert on served *content*, not just on connection lifecycle (matches the existing `POST /boundary` host test's "0 bytes leaked" assertion style, fake-libpulse.c ~line 2899).

### Pitfall 4: Merging `_pollWsPort`/`_pollHttpPort` too aggressively (CR-S3)
**What goes wrong:** The two functions look identical at a glance (attempts counter, `procAlive` check, re-schedule-if-alive-and-under-max-attempts loop) but diverge in exactly the ways CONTEXT.md already flags: `_pollWsPort` checks the port file's `mtime` against `_spawnTime` (stale-file guard) and calls `$self->stop()` on failure; `_pollHttpPort` has no mtime check, never calls `stop()` on failure (falls through to "will poll on demand" via `ensureHttpPort`), and unlinks its own tmpfile on success. A naive merge that unifies the failure branch would make a missing HTTP port stop the whole daemon — a real regression (WR-07 in the existing code explicitly protects against premature tmpfile unlink for exactly this idle-daemon case).
**Why it happens:** Structural similarity invites over-eager DRY.
**How to avoid:** Per CONTEXT.md's own "evaluate carefully" framing, extract only the truly identical scaffold (attempts-counter increment + `procAlive` check + re-schedule-if-under-max-attempts) into a shared private helper; keep the divergent success/failure bodies as distinct callback closures passed into that helper. Verify with `t/` daemon-lifecycle tests (whichever cover SoloistDaemon.pm) before and after.
**Warning signs:** A host-idle-daemon integration scenario where the daemon gets killed just because its HTTP port announcement was slow.

### Pitfall 5: Assuming `atomic_int` needs a different Makefile flag
**What goes wrong:** Adding `#include <stdatomic.h>` and expecting a build failure without an explicit `-std=c11` (or later) flag.
**Why it happens:** Some older cross-compile guides suggest C11 features need explicit `-std=` opt-in.
**How to avoid:** GCC's default GNU dialect (gnu11/gnu17 depending on version) already includes C11 atomics without extra flags; the Makefile's current `CFLAGS ?= -O2 -Wall -Wextra` (no `-std=` override) should compile `atomic_int` cleanly on all three CI cross-toolchains. Verify with a local `make -C Plugins/SpotOn/Bin/fake-libpulse test` build after the CR-1 change — if it fails to compile, add `-std=gnu11` (not `-std=c11`, to avoid losing POSIX extensions `pthread.h` needs) as a targeted CFLAGS addition, not a project-wide default. [ASSUMED — GCC version on the actual CI runner not verified this session; treat as a checkpoint if the local build environment lacks a C compiler to test against.]

## Code Examples

### Existing boundary-plant pattern (model for the new seek-arm endpoint)
```c
// Source: Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:829-856
if (pending.fd >= 0 && _pending_head_complete(&pending)
    && strstr(pending.buf, "POST") != NULL && strstr(pending.buf, "/boundary") != NULL)
{
    pthread_mutex_lock(&g_ring.lock);
    g_boundary_at_pushed = g_ring.total_pushed;
    size_t ring_fill_now = g_ring.fill;
    pthread_mutex_unlock(&g_ring.lock);

    static const char boundary_resp[] =
        "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    _http_write_all(pending.fd, (const unsigned char *)boundary_resp,
                     sizeof(boundary_resp) - 1);
    close(pending.fd);
    pending.fd = -1;
    pending.len = 0;

    BOUNDARY("boundary_planted: total_pushed=%lld ring_fill=%zu",
             (long long)g_boundary_at_pushed, ring_fill_now);

    continue; /* back to the top of the for(;;) -- skip GET /stream takeover */
}
```
A `POST /seek-arm` branch should be inserted immediately adjacent to this block, following the identical shape (parse request line, act, respond `200 OK Connection: close`, `continue`).

### Existing Perl WS seek dispatch (current location — D-02 relocates this)
```perl
# Source: Plugins/SpotOn/Connect.pm:855-871 (_bufferedBrowseSeek, current implementation)
sub _bufferedBrowseSeek {
    my ($client, $positionMs) = @_;

    my $browseWs = _soloistBrowseWs($client);
    return unless $browseWs;

    main::INFOLOG && $log->is_info && $log->info(
        "Soloist browse: forwarding seek to daemon via WS seek: ${positionMs}ms"
    );
    $log->warn("[DIAG] browse_seek_to_daemon: mac=" . $client->id . " position_ms=$positionMs debounced=" . SEEK_DEBOUNCE . "s") if $prefs->get('diagnosticMode');

    $browseWs->sendCommand('seek', position_ms => $positionMs);
}
```

### Existing synchronous call site D-02 should move dispatch into
```perl
# Source: Plugins/SpotOn/ProtocolHandler.pm:782-796 (getNextTrack, soloist-browse branch)
my $daemonCurrent = $ws->can('lastTrackId') ? ($ws->lastTrackId // '') : '';

# Daemon already on this track: skip play (would restart audio).
# Covers both EOF-advance (Browse) and Connect (daemon sequencing).
if ($daemonCurrent eq $id) {
    main::INFOLOG && $log->is_info && $log->info(
        "getNextTrack: soloist browse -- resume (lastTrackId match,"
        . " id=$id, mac=" . ($client ? $client->id : '?') . ")"
    );
    $ws->soloistBrowseActive(1) if $ws->can('soloistBrowseActive');
    # Resume (play without URI): safe if daemon is already playing
    # (no-op), resumes if paused, and arms pendingPlayConfirm to
    # suppress the transitional _onPause from LMS's stream swap.
    $ws->sendCommand('play');
}
```
This is exactly where LMS's seek-restart connection request re-enters (same track ID, new `&start=N`). D-02's seek dispatch belongs in this branch, gated on whether `$song->seekdata->{timeOffset}` (or the parsed `start=` value) differs from the daemon's last known position — send `POST /seek-arm` to the daemon's own HTTP port, then `$ws->sendCommand('seek', position_ms => ...)`, before falling through to the existing `sendCommand('play')`/resume call (or replacing it for the seek case — exact task-level design left to the planner).

## State of the Art

No external ecosystem shifted since Phase 78 — this is a from-scratch, project-internal audio proxy with no upstream framework to track. The only "state of the art" question is internal: the codebase's own boundary-marker pattern (Spike 2, Phase 77) is the newest, most-refined mechanism in this file, and the seek-arm mechanism proposed above is explicitly modeled on it rather than inventing a new idiom.

**Superseded within this project:**
- The Phase 78-02 debounced `_onSeek`/`_bufferedBrowseSeek` browse-seek path (Connect.pm:812-871) is superseded by D-02's ProtocolHandler-based synchronous dispatch — but only once the new mechanism is implemented and verified; do not delete the old path until the new one is live-UAT-confirmed (D-07: host-tests then live UAT, no fuzzing).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | GCC on all 3 CI cross-toolchains (native `gcc`, `gcc-aarch64-linux-gnu`, `gcc-arm-linux-gnueabihf`) supports `<stdatomic.h>`/`atomic_int` without an explicit `-std=` flag | Standard Stack, Pitfall 5 | CR-1's atomic fix fails to cross-compile on one or more of the 3 architectures in `build-fake-libpulse.yml`, blocking D-09's CI rebuild until a targeted `-std=gnu11` CFLAGS addition is made |
| A2 | The proposed `POST /seek-arm` control endpoint mechanism (Pattern 1) is a workable design that satisfies D-02/D-03's contract | Architecture Patterns → Pattern 1 | This is this session's own proposed solution, not something already in the codebase or verified against the closed-source Soloist binary's actual internal seek/flush call sequencing. If Soloist's internal seek path does something unexpected (e.g., calls `pa_stream_flush()` more than once per seek, or calls it from a different code path than skip), the single-arm/single-consume design may need to become re-armable or counted rather than one-shot. Should be validated with the first new host test written for this pattern before broader implementation. |
| A3 | Moving seek dispatch to ProtocolHandler.pm's `getNextTrack` resume branch (line ~786-796) is sufficient to eliminate the race, without needing to also modify `canDirectStreamSong`/`getSeekData` | Summary, Pattern 1 | If LMS's actual seek-restart timing calls `getNextTrack` *after* the new HTTP connection is already opened (rather than before, as the direct-stream URL flow implies), the arm-then-connect ordering guarantee could still be violated. Not verified against live LMS internals this session — this is inferred from the existing code comments' description of the direct-stream flow, not from tracing LMS core's `_JumpToTime`/`Song.pm` source. |
| A4 | D-08 ("EOF + LMS retry on daemon crash... No special recovery code") requires zero new C code because fake-libpulse.so.0 is dlopen()'d in-process with the Soloist daemon, so process death already closes all its sockets via the OS | Architectural Responsibility Map, Pitfall n/a | Verified via the file's own header comment (fake-libpulse.c:1-30-ish) confirming in-process dlopen — HIGH confidence this reasoning is correct, but the actual "LMS retries" half of D-08 (squeezelite/LMS behavior on an unexpected socket close outside of a boundary/skip) has not been independently confirmed against LMS core behavior this session. |

**If this table is empty:** N/A — see above; 4 assumptions logged, all flagged for planner/CONTEXT confirmation or first-host-test validation rather than blind implementation.

## Open Questions

1. **Does the closed-source Soloist binary call `pa_stream_flush()` exactly once per seek, or could it call it multiple times (e.g., once to discard, once more if the seek target itself changes mid-flight)?**
   - What we know: The existing doc comment (fake-libpulse.c:550-561) describes flush as reacting to "an app-side skip/seek" in the singular, and Spike 1/2's host tests only ever exercise a single flush per scenario.
   - What's unclear: Whether a rapid double-seek (user drags the seek bar twice quickly) could produce two `pa_stream_flush()` calls before the first one's armed-flag is consumed, potentially leaving the second flush unarmed (falling back to disconnect behavior) or double-consuming a stale arm.
   - Recommendation: D-07's new host-test set should explicitly include a "double-seek" case (two `POST /seek-arm` + two `pa_stream_flush()` calls in quick succession) to characterize this before live UAT.

2. **Should `getSeekData` (ProtocolHandler.pm:1079-1105) be changed at all, or does the fix work entirely underneath the existing `{timeOffset=>N}` contract?**
   - What we know: `getSeekData` already returns `{timeOffset=>$newtime}` unconditionally for Browse (not Connect), and its own comment already documents "LMS-native seek-restart" as the intended Phase 78 design. Pattern 1's fix works underneath this without changing `getSeekData`'s return value.
   - What's unclear: Whether leaving LMS's own stream-restart (a second, genuinely new TCP connection) in place is actually necessary once the C-side fix prevents any disconnect-triggered skip — or whether it would be *simpler* (per D-03's "simplest model" framing) to have `getSeekData` return `undef` for Browse too (matching the existing Connect-mode branch immediately above it), suppressing LMS's own restart entirely and relying purely on the same already-open connection continuing past the flush.
   - Recommendation: Planner should weigh both options against D-07 (host-tests first). The `undef`-return option is architecturally simpler (one connection, ever) but is a `canSeek`/`getSeekData`-contract behavior change (D-02 marked "Reversibility: costly — seek contract is consumed by ProtocolHandler and Phase 78 bounded endpoint integration") and should probably be a `checkpoint:human-verify` decision point in the plan rather than an assumed default.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `gcc` (native) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✓ | present in this sandbox (used this session) | — |
| `gcc-aarch64-linux-gnu` / `gcc-arm-linux-gnueabihf` cross toolchains | D-09 CI cross-compile (3-arch matrix) | Not checked in this sandbox — CI-only concern | — | `build-fake-libpulse.yml` already installs these via `apt-get` on `ubuntu-latest`; not needed locally for host-test-driven development |
| `prove` (Perl `Test::Harness`) | `t/*.t` regression suite | ✓ | ran this session (t/05, t/29, t/31 all green) | — |
| `cargo`/`rustc` | `librespot-spoton && cargo test` (prior-phase verify command) | ✗ — not found in this sandbox (`which cargo rustc` returned nothing) | — | This phase's own scope (fake-libpulse.c, Perl glue) does not touch `librespot-spoton`'s Rust source, so `cargo test` is likely inherited from a stale prior-phase verify command list rather than actually exercised by Phase 77's plans — confirm with the planner whether any Phase 77 task touches `librespot-spoton/` at all before including this command in the phase's verification loop |
| `gh` CLI (or manual GitHub UI) | D-09 — trigger `build-fake-libpulse.yml` workflow_dispatch | Not checked this session | — | `gh workflow run build-fake-libpulse.yml` if `gh` is authenticated; otherwise manual dispatch via GitHub Actions UI is the fallback (the workflow is `workflow_dispatch`-only, confirmed via `.github/workflows/build-fake-libpulse.yml:20`) |

**Missing dependencies with no fallback:** None — every item above has a fallback or is confirmed present.

**Missing dependencies with fallback:** `cargo`/`rustc` (not needed for this phase's actual file scope, per the note above — flag to planner rather than assume it's required); `gh` CLI (manual dispatch fallback exists).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework (C) | Custom single-file host-test harness compiled with `-DFAKE_LIBPULSE_TEST`, driven from `int main(void)` in fake-libpulse.c (lines ~2416 onward), printing `ok: <description>`/`not ok: <description>` lines |
| Framework (Perl) | `Test::More` via `prove -l t/*.t` (standard LMS-plugin convention, `t/` directory) |
| Config file (C) | none — `Makefile`'s `test` target compiles+runs directly |
| Config file (Perl) | none discovered beyond `t/` directory convention |
| Quick run command (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` |
| Quick run command (Perl, targeted) | `prove -l t/29_soloist_browse.t t/31_soloist_ws.t t/32_soloist_events.t t/37_connect_lifecycle.t t/05_perl_syntax.t` |
| Full suite command (Perl) | `prove -l t/*.t` (full project: 37 files, ~1873 tests per STATE.md's most recent full-suite run) |

**Correction to prior-phase verify command list:** the additional-context-supplied command `make -C Plugins/SpotOn/Bin/fake-libpulse test 2>&1 | grep -c '^ok:' | grep -qx 6` is **stale** — this session's actual run of `make test` produces **9** `ok:` lines (verified directly: HTTP port announced; f32→s32 conversion; `pa_stream_flush` discards buffered audio; idle pending connection WR-11; reconnect after flush-disconnect; `POST /boundary` closes with exact-EOF; fresh client after boundary EOF; drop-oldest with no client; `writable_size` shrinks). The `6` figure predates Spike 2's 3 additional boundary-related tests. Phase 77's Wave 0/verification should use `grep -qx 9` as the **pre-Phase-77 baseline**, then update that count again after each new D-07 host test is added (seek+flush, rapid-skip, mismatch, stale-client — expect the final count to be 9 + however many new `ok:` lines D-07's tasks add, likely 13-17).

### Phase Requirements → Test Map
| Decision ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CR-1 | `g_ring_underrun_fired` no longer races under concurrent set/reset from two threads | unit (C host test) | new case in `fake-libpulse-test` binary — assert underflow_cb still fires correctly under a tight push/pop interleaving loop | ❌ Wave 0 (new test needed) |
| D-02/D-03 | Seek does not disconnect the client; no pre-seek audio crosses the socket | unit (C host test) | new case: arm seek, call `pa_stream_flush`, assert `client_fd` stays open and served bytes exclude anything pushed before the flush | ❌ Wave 0/main-wave (new test needed) |
| D-04 | Rapid-skip: last `POST /boundary` wins, stale client gets disconnected via `g_flush_disconnect` | unit (C host test) | new case: two `POST /boundary` calls before either is reached, assert only the second (later) watermark applies | ❌ (new test needed — extends existing boundary test) |
| D-05 | URI-mismatch: same mechanism as seek/D-02, verified via daemon play-command path | unit (C host test) + Perl (t/29 extension) | new C case (mirrors D-02's) + `prove -l t/29_soloist_browse.t` extended with a mismatch scenario | ❌ (new tests needed both sides) |
| D-06 | Stale-client cleanup via existing `g_flush_disconnect` | unit (C host test) | Already covered — "reconnect after flush-disconnect attaches and drains immediately" (existing test, fake-libpulse.c ~line 2763) | ✅ existing |
| D-08 | Daemon crash → clean EOF, no special code | manual/live UAT only (cannot host-test a real process death cleanly without a process-kill harness) | N/A — recommend a documented manual test step (kill the daemon process mid-stream, confirm squeezelite sees clean EOF and LMS's normal reconnect/retry logic takes over) rather than an automated host test | ❌ manual-only, by design |
| CR-S1 | `_detectSeek()` extraction preserves identical drift-detection behavior in both `_onPositionSync` and `_onPlaybackState` | unit (Perl) | extend `t/31_soloist_ws.t` (currently 143 tests, all pass) with before/after-refactor equivalence assertions | ❌ (extend existing file) |
| CR-S2 | `_hasLogin5Creds` guard wrapper (if built) preserves all 17 call sites' delegate-to-Client.pm behavior | unit (Perl) | grep-gate style check (like `t/37`'s existing pattern) confirming call-site count and delegate behavior unchanged | ❌ (new grep-gate row, low priority per D-01) |
| CR-S3 | `_pollWsPort`/`_pollHttpPort` shared-scaffold extraction preserves distinct failure semantics (Pitfall 4) | unit (Perl) | daemon-lifecycle test file (identify exact `t/` file covering SoloistDaemon.pm — not confirmed by filename in this session, planner should locate before Wave 0) | ❓ (locate existing coverage first) |
| CR-S4 | `getAlbumTracks`/`getShowEpisodes` switched to `_sliceAsPage`, behavior identical | unit (Perl) | existing SpClient.pm test coverage (file not identified by name this session — grep `t/` for `getAlbumTracks`/`_sliceAsPage` before Wave 0) | ❓ (locate existing coverage first) |
| D-09 | CI rebuild succeeds on all 3 architectures, binaries pass the glibc/musl NEEDED-entry verification | integration (CI) | `gh workflow run build-fake-libpulse.yml` then inspect the 3 matrix jobs' "Verify binary" step output | ✅ CI job exists (`.github/workflows/build-fake-libpulse.yml`), just needs dispatching at phase end |

### Sampling Rate
- **Per task commit:** `make -C Plugins/SpotOn/Bin/fake-libpulse test` (fast, <1s, run after every fake-libpulse.c edit) + targeted `prove -l t/29_soloist_browse.t t/31_soloist_ws.t t/32_soloist_events.t` after every Perl edit in this phase's scope
- **Per wave merge:** `prove -l t/*.t` (full 37-file suite) — this phase's edits span both the C ring/flush logic and 4+ Perl modules, so cross-module regressions (especially the `soloistBrowseActive` gate, Pitfall 2) are the main risk the full suite catches that targeted runs would miss
- **Phase gate:** Full Perl suite green + full C host-test suite green (updated count, not the stale `6`) + `checkpoint:human-verify` live UAT re-run of `78-UAT.md` test 10 (Browse seek) specifically, since that is the exact failure this phase's headline fix (D-02/D-03) targets. D-07 explicitly excludes fuzzing/stress-testing from this phase's scope — the phase gate should not require it.

### Wave 0 Gaps
- [ ] New C host-test case for CR-1 (concurrent set/reset race on `g_ring_underrun_fired`) — genuinely hard to make deterministic in a single-process host test; consider a targeted `pthread`-based stress loop (spawn a thread that hammers `_ring_push`/`_ring_flush` while the main thread polls the underrun path) rather than a timing-hopeful single-shot assertion
- [ ] Locate existing `t/` coverage (if any) for SoloistDaemon.pm's `_pollWsPort`/`_pollHttpPort` and SpClient.pm's `getAlbumTracks`/`getShowEpisodes` before starting CR-S3/CR-S4 — this session did not locate test files by name for either, and the planner should not assume no coverage exists without checking
- [ ] Decide (per Open Question 2) whether `getSeekData`'s Browse branch changes as part of D-02, since that decision changes whether the seek-arm C-side fix needs to also handle a "second connection takes over mid-armed-window" case (Pattern 1 step 4) or whether it simplifies to "same connection, never torn down"

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | The fake-libpulse HTTP server (both `/stream` and control endpoints) has no auth today and this phase does not add any — same accepted posture as the existing `POST /boundary` endpoint |
| V3 Session Management | no | No session concept at this layer |
| V4 Access Control | partial | The server is deliberately bound `INADDR_ANY` (wildcard), not loopback-only — already documented as an accepted, deliberate choice ("Wildcard bind is deliberate: LMS players stream `/stream` directly from the LAN — identical exposure to the existing librespot `/stream`," fake-libpulse.c ~line 1057-1065, citing "RESEARCH Security V4"). The new `POST /seek-arm` control endpoint inherits this exact same LAN-exposed trust boundary — it is a control-plane request with no destructive capability beyond what `POST /boundary` already exposes (flushing/re-arming ring state, not reading/writing arbitrary files or executing commands), so it does not raise the phase's risk profile beyond the existing accepted posture. The WS control port (SoloistWS.pm), by contrast, is already 127.0.0.1-only per the existing code_context note in CONTEXT.md — unaffected by this phase. |
| V5 Input Validation | yes | `sendCommand`'s existing URI-shape validation (`^spotify:(?:track|episode):[A-Za-z0-9]+$`, SoloistWS.pm:333-336) and numeric-param coercion (`int()` on `position_ms`/`volume`, SoloistWS.pm:348-350) already cover the WS seek command this phase extends the dispatch site of — no new validation surface introduced by relocating the *call site*, but if the new `POST /seek-arm` control request accepts any body/params (as opposed to being a bare trigger like `POST /boundary`), it must receive equivalent validation before being trusted to arm C-side state. Recommend keeping it parameterless (a bare trigger, matching `POST /boundary`'s shape) to avoid introducing new parsed input on the C side, where buffer/parsing bugs are more costly than in Perl. |
| V6 Cryptography | no | Not applicable to this phase's scope |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| A LAN-adjacent host spamming `POST /seek-arm` to force spurious ring flushes / denial-of-service against legitimate playback | Denial of Service | Same accepted-risk posture as `POST /boundary` today (no rate-limiting exists for that endpoint either) — out of scope for this phase per D-07 ("No fuzzing/stress-test in this phase"); flag as a known residual risk in the plan rather than building new rate-limiting |
| A malformed/oversized HTTP request line to the new control endpoint causing a parser bug in the shared `pending.buf`/`_pending_head_complete` path | Denial of Service / potential memory-safety issue | Reuse the exact same bounded-buffer parsing (`pending.buf`, fixed-size, already used for `/boundary` and `/stream`) rather than writing new parsing code for `/seek-arm` — do not introduce a new buffer or a new length-unbounded read path |

## Sources

### Primary (HIGH confidence — direct reads of this repo's actual files, this session)
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` (full structural read: lines 1-50, 330-600, 738-1070, 1960-2040, plus `int main(void)` host-test list ~2416+) — ring buffer, HTTP server, boundary marker, `pa_stream_flush`, `g_flush_disconnect`, `g_ring_underrun_fired`
- `Plugins/SpotOn/Bin/fake-libpulse/Makefile` (full read) — build/test targets
- `Plugins/SpotOn/ProtocolHandler.pm` (lines 185-330, 720-820, 1040-1260) — `canDirectStream`, `canDirectStreamSong`, `canSeek`, `getSeekData`, `canDoAction`, `getNextTrack` soloist-browse branch
- `Plugins/SpotOn/Connect.pm` (lines 240-300, 760-910) — `_currentSpotonTrackUrl`, `_soloistBrowseWs`, `_onSeek`, `_bufferedBrowseSeek`, `_bufferedSeek`
- `Plugins/SpotOn/Unified/SoloistWS.pm` (lines 320-370, 700-895) — `sendCommand`, `_onPlaybackChanged`, `_onPositionSync` (CR-S1 target 1), `_onPlaybackState` (CR-S1 target 2)
- `Plugins/SpotOn/Unified/SoloistDaemon.pm` (lines 270-420) — `_pollWsPort`/`_pollHttpPort` (CR-S3 target)
- `Plugins/SpotOn/API/SpClient.pm` (lines 205-235, 799-833, 1060-1100, 1170-1230, 1400-1420) — `_hasLogin5Creds` (CR-S2), `_sliceAsPage` and its two un-migrated inline duplicates in `getAlbumTracks`/`getShowEpisodes` (CR-S4)
- `.github/workflows/build-fake-libpulse.yml` (full read) — CI 3-architecture matrix, `workflow_dispatch` trigger, glibc/musl NEEDED-entry verification
- `.planning/phases/78-browse-connect-reintegration-perl/78-UAT.md` (full read) — test 10 (Browse seek, root cause), test 11/15 (Connect transfer, out of this phase's scope)
- `.planning/debug/browse-connect-gating.md` (full read) — resolved `soloistBrowseActive` fix, orthogonal to but file-adjacent to this phase's scope
- `.planning/phases/77-bounded-audio-facade-spoton-helper-c-rust/77-CONTEXT.md` (full read) — locked decisions D-01..D-13
- Live command runs this session: `make -C Plugins/SpotOn/Bin/fake-libpulse test` (9/9 `ok:`), `prove -l t/05_perl_syntax.t` (18/18), `prove -l t/29_soloist_browse.t t/05_perl_syntax.t` (71/71), `prove -l t/31_soloist_ws.t` (143/143), `git log --oneline -5 -- Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c`

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md`, `.planning/STATE.md` — project-level context, milestone framing (no direct technical claims sourced from these beyond confirming no REQ-IDs map to this phase)

### Tertiary (LOW confidence / ASSUMED — flagged individually in Assumptions Log)
- A1 (GCC C11 support on CI cross-toolchains without `-std=` flag)
- A2 (the proposed `POST /seek-arm` mechanism's overall soundness against the closed-source Soloist binary's actual internal seek sequencing)
- A3 (ProtocolHandler.pm's `getNextTrack` call ordering relative to LMS's internal connection-open timing)
- A4 (LMS/squeezelite's actual retry behavior on an unexpected daemon-crash socket close)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies; C11 atomics claim is the only externally-sourced (not project-internal) fact, flagged ASSUMED (A1)
- Architecture (seek-flush race root cause): HIGH — traced directly through the actual C and Perl source this session, cross-referenced against the exact UAT failure description and the code's own pre-existing "RESEARCH Pitfall 5" comment predicting this race
- Architecture (proposed fix, Pattern 1): MEDIUM — sound design grounded in the existing `POST /boundary` precedent in the same file, but not yet implemented or tested against the real (closed-source) daemon's seek behavior — flagged A2
- Pitfalls: HIGH — CR-S3's divergence and CR-S4's exact duplicate line ranges were read directly, not inferred
- Validation architecture: HIGH for what's directly testable (C host tests, Perl `prove`), MEDIUM for D-08 (manual-only by nature) and the two "locate existing coverage" gaps (CR-S3/CR-S4 Perl test files not identified by name this session)

**Research date:** 2026-09-01
**Valid until:** Effectively pinned to this specific codebase state (commit `1d0106a`/working tree at research time) rather than a calendar window — re-verify the exact `make test` count and the `soloistBrowseActive` presence check if significant time passes or other phases land first, since both are precise, easily-drifted facts this research depends on.
