# Phase 77: Bounded Audio Facade (spoton-helper, C/Rust) - Context

**Gathered:** 2026-09-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Harden the Spike 1+2 prototype into production-quality bounded audio serving. fake-libpulse.c delivers per-track HTTP responses with real EOF at track boundaries. LMS gets the same contract as librespot `--single-track`. Includes pre-cleanup from code review findings and CI binary rebuild.

**Spikes 1+2 are ALREADY DONE.** The C-side bounded endpoint prototype is implemented and validated (16ms overshoot, 9/9 host tests). This phase hardens edge cases (seek, rapid-skip, URI-mismatch, stale-client), fixes the ARM data race, applies Perl simplifications, and rebuilds binaries via CI.

</domain>

<decisions>
## Implementation Decisions

### Pre-Cleanup (Wave 0)
- **D-01:** All 5 code review items (CR-1 + CR-S1..S4) go into Phase 77 Wave 0. Clean foundation before hardening.
  - CR-1: `g_ring_underrun_fired` atomic fix in fake-libpulse.c (C11 `atomic_int`) — **Reversibility:** reversible
  - CR-S1: Extract `_detectSeek()` helper from Connect.pm:800-882 — **Reversibility:** reversible
  - CR-S2: `_hasLogin5Creds` 17× guard pattern (SpClient.pm) — evaluate wrapper, low priority — **Reversibility:** reversible
  - CR-S3: `_pollWsPort`/`_pollHttpPort` duplication merge (SoloistDaemon.pm) — careful, different error handling — **Reversibility:** reversible
  - CR-S4: Inline slice → `_sliceAsPage` (SpClient.pm) — **Reversibility:** reversible

### Seek Parameter (start=N)
- **D-02:** Seek via WS command + ring flush. ProtocolHandler passes `start=N` → SoloistWS sends seek-command to daemon → daemon flushes ring → HTTP waits for post-flush data → serves from new position. No pre-seek audio in response. — **Reversibility:** costly — seek contract is consumed by ProtocolHandler and Phase 78 bounded endpoint integration
- **D-03:** C-side waits for flush completion. fake-libpulse recognizes `pa_stream_flush` callback, invalidates old boundary, blocks HTTP-thread read-loop until post-flush data arrives. Simplest model, no Perl-side coordination needed. — **Reversibility:** reversible

### Rapid-Skip + Edge Cases
- **D-04:** Last-wins + flush for rapid track changes. Each new `POST /boundary` overwrites previous marker. Stale client reading old track gets `g_flush_disconnect` → socket close → LMS sees EOF. — **Reversibility:** reversible
- **D-05:** URI-Mismatch: Daemon play-command + flush. ProtocolHandler detects mismatch, sends play-command via WS, daemon flushes ring + starts new track. HTTP waits for post-flush data. Same mechanism as seek (D-02/D-03). — **Reversibility:** costly — mismatch-handling contract shared with Phase 78
- **D-06:** Stale-client cleanup via existing `g_flush_disconnect` pattern. HTTP-thread checks flag in read-loop, closes socket on set. Already implemented in spike. — **Reversibility:** reversible

### Production Hardening
- **D-07:** Host-tests + Live-UAT. C host-tests for all new edge cases (seek+flush, rapid-skip, mismatch, stale-client). Then live UAT with real audio. No fuzzing/stress-test in this phase. — **Reversibility:** reversible
- **D-08:** EOF + LMS retry on daemon crash. HTTP-thread detects daemon death (no ring-writer), closes socket cleanly (EOF). LMS sees playback stop, ProtocolHandler can retry/reconnect. No special recovery code. — **Reversibility:** reversible
- **D-09:** CI binary rebuild at Phase 77 end. Trigger CI for all 3 architectures (x86_64, aarch64, armv7). Binary rebuild is prerequisite for Phase 78 live testing. — **Reversibility:** reversible

### Carrying Forward (locked from prior phases)
- **D-10 (from 78/D-01):** First track serves unbounded — no boundary before first `track_changed`.
- **D-11 (from 78/D-02):** Session-end: daemon `stopped` → `POST /boundary` → clean EOF.
- **D-12 (from 78/D-05):** Skip = Flush + implicit EOF. `pa_stream_flush` → `g_flush_disconnect` closes client.
- **D-13 (from 76/D-04):** Ring-buffer is S32LE (32-bit depth). Write rate ~327,680 bytes/sec.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Audio Architecture
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — Ring buffer, boundary markers, HTTP server, bounded serving (3015 lines, prototype implemented)
- `Plugins/SpotOn/Bin/fake-libpulse/Makefile` — Build + host test targets (`make test`)
- `.planning/phases/78-browse-connect-reintegration-perl/78-CONTEXT.md` — Phase 78 decisions D-01/D-02/D-05 that constrain Phase 77 contracts

### Daemon Lifecycle
- `Plugins/SpotOn/Unified/SoloistDaemon.pm` — Daemon spawn, port polling, ensureHttpPort (CR-S3 target)
- `Plugins/SpotOn/Unified/SoloistWS.pm` — `_signalBoundary()`, `_onTrackChanged`, WS message handling

### Perl Simplification Targets
- `Plugins/SpotOn/Connect.pm:800-882` — Seek detection copy-paste (CR-S1)
- `Plugins/SpotOn/API/SpClient.pm` — `_hasLogin5Creds` 17× (CR-S2), inline slice (CR-S4)

### Prior Spike Results
- `.claude/skills/spike-findings-spoton/SKILL.md` — Auth spike findings (not directly relevant but context)
- `.planning/ROADMAP.md` §Phase 77 — Spike 1+2 results embedded in phase description

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **fake-libpulse.c boundary prototype** (Spike 2): `g_boundary_at_pushed`, `POST /boundary` handler, bounded serve loop, `g_flush_disconnect`. Production-ready structure, needs edge-case hardening.
- **`_signalBoundary()` in SoloistWS.pm**: Already fires `POST /boundary` on `_onTrackChanged`. Wiring exists.
- **Host test harness** (`make test`): 9/9 tests, C-level ring+boundary tests. Extend for new edge cases.
- **`_sliceAsPage` in SpClient.pm**: Existing pagination helper for CR-S4 cleanup.

### Established Patterns
- **Ring buffer**: lock-based (`g_ring.lock`), condition variable (`g_ring.space_avail`), `total_pushed`/`total_popped` counters. All boundary logic uses these counters.
- **HTTP-thread**: Single-threaded HTTP server in fake-libpulse, `select()`-based. One client at a time.
- **Flush pattern**: `pa_stream_flush` → `ring_flush()` → `g_flush_disconnect = 1` → HTTP-thread closes client.

### Integration Points
- **ProtocolHandler.pm** `canDirectStream`: Returns `http://host:PORT/stream/track?uri=X&start=Y` for Soloist. Phase 78 consumes this URL.
- **custom-convert.conf** `soc` profile: Transcoding rules for Soloist output. S32LE PCM from bounded endpoint.
- **CI workflow**: `.github/workflows/build-*.yml` builds fake-libpulse.so + spoton-helper for 3 architectures.

</code_context>

<specifics>
## Specific Ideas

- Seek and URI-mismatch share the same mechanism (WS command + flush + wait for post-flush data) — implement once, use twice.
- C-side flush-wait is preferred over Perl-side coordination to minimize roundtrips.
- `g_flush_disconnect` is the universal stale-client cleanup — no timeout-based approach needed.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 77-Bounded Audio Facade (spoton-helper, C/Rust)*
*Context gathered: 2026-09-01*
