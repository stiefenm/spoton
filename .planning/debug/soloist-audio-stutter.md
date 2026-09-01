---
status: diagnosed
trigger: "Zyklisches Audio-Stutter bei Soloist Browse Playback — vorbestehend, nicht Phase 78 spezifisch"
created: 2026-09-01T11:45:00Z
updated: 2026-09-01T12:00:00Z
---

## Current Focus

hypothesis: "CONFIRMED — fake-libpulse.c's HTTP-serving thread (_http_thread_fn) has a hard-coded throughput ceiling of 16384 bytes per ~50ms poll cycle (327,680 B/s), which is below the 352,800 B/s required for real-time S32LE 44.1kHz stereo playback. The 16384-byte chunk size was sized during Phase 73-01 (commit 0cf32f5) when the ring was S16LE (176,400 B/s required) -- 327,680 B/s was then ~1.86x headroom, safe. Phase 76-01 (commit 74327fa, 'upgrade fake-libpulse ring from S16LE to S32LE') doubled RING_BYTES_PER_SEC (44100*2*2 -> 44100*4*2) but never touched the HTTP thread's chunk[16384]/poll(...,50) constants, leaving the thread's maximum sustainable output at 327,680 B/s -- a permanent 7.12% underfeed of the audio consumer, present ever since that commit and independent of Soloist's own behavior, ring capacity, or the Phase 78 backpressure change."
test: "Live daemon log analysis (52540043d5c2-soloist.log, current session): once the ring saturates (fill caps at ~7,047,680 / 7,056,000 bytes, RING_CAPACITY), bytes_written growth rate measured across 40+ consecutive TIMING samples drops from ~352,800 B/s (Soloist's natural decode pace, matches real-time) to EXACTLY 655,360 bytes / 2.000s = 327,680 B/s, sustained for 80+ seconds without deviation -- an exact match to 16384 bytes / 0.050s. Cross-checked against source: _ring_pop_timed(chunk, maxlen=16384, ...) caps every pop at 16384 bytes regardless of available fill; the enclosing loop's top-level poll(fds, ..., 50) blocks up to 50ms per iteration in steady state (no new connections), so wall-clock loop cadence is pinned at ~50ms regardless of ring fill level."
expecting: "n/a — hypothesis already confirmed via direct, reproducible, git-history-corroborated evidence. No further test needed for root-cause diagnosis (goal: find_root_cause_only)."
next_action: "Return ROOT CAUSE FOUND to caller. Suggested fix (NOT implemented, out of scope for find_root_cause_only): rescale the HTTP thread's per-tick byte budget to match RING_BYTES_PER_SEC*0.05=17640 bytes (or reduce the poll timeout / drain in a loop until caught up), so drain rate >= 352,800 B/s."

## Symptoms

- expected: Saubere, durchgehende Audio-Wiedergabe über Soloist → fake-libpulse → HTTP → squeezelite
- actual: Millisekunden-Gaps (kurze Audio-Aussetzer), dann ~5s Stille, dann stutterfreie Wiedergabe bei schnellerem Tempo (klingt wie korrektes Tempo), nach 20-30s wiederholt sich der Zyklus
- errors: Keine expliziten Fehlermeldungen
- timeline: VORBESTEHEND — existierte bereits vor Phase 78 (bounded Endpoint). Tritt mit dem alten unbounded /stream Endpoint genauso auf. Nicht durch Phase 78 Änderungen verursacht.
- reproduction: Jeden Soloist Browse Track abspielen → Stutter-Pattern reproduzierbar

## Ausgeschlossene Hypothesen

1. Ring-Buffer Overflow (drop-oldest): Blocking _ring_push getestet → identisches Stutter-Verhalten → NICHT die Ursache
2. Sample-Rate Mismatch: squeezelite debug zeigt pcm_open: size=4 rate=44100 chan=2 bigendian=0 → korrekt
3. F32→S32 Konversion: C-Test besteht, User erkennt korrekten Song → Konversion funktioniert
4. Browse/Connect Event Interferenz: Stutter existierte schon VOR Phase 78, als Events noch kein Thema waren

## Offene Fragen

- 20-30s Cycle passt zur Ring-Buffer-Größe (~20s) — Zufall oder Zusammenhang?
- "Schnelleres Tempo = korrektes Tempo" — bedeutet das, dass die NORMALE Geschwindigkeit zu langsam ist?
- TIMING-Daten zeigen fill_input = 2 * fill — ist das ein Hinweis auf ein Byte-Counting-Problem?
- Welche Rolle spielt der 2s POLLOUT-Timeout in _http_write_all?

## Blueprint: Real PulseAudio Flow Control

User-Directive: Nicht die Architektur ändern (kein echter PA-Server), sondern das Verhalten von echtem libpulse/PA als Blueprint für fake-libpulse nutzen.

Zu studierende PA-Mechanismen:
1. **`pa_buffer_attr` (tlength, maxlength, prebuf, minreq)**: Server kontrolliert wie viel der Client buffern darf. `tlength` ist die TARGET buffer length — der Server bremst den Client wenn der Buffer über tlength liegt.
2. **`pa_stream_set_write_callback`**: Callback feuert NUR wenn der Server bereit für mehr Daten ist (minreq bytes frei). Soloist schreibt NUR im Callback — fake-libpulse muss das Callback-Timing an die Consumer-Rate koppeln.
3. **`writable_size`**: In echtem PA = "wie viel der Server noch akzeptiert", NICHT "freier Ring-Platz". Der Server reguliert basierend auf seiner eigenen Drain-Rate.
4. **Timing (`sink_usec`)**: Echtes PA liefert exakte Buffer-Füllstands-Information. Der Client nutzt das um seine Decode-Rate zu steuern.

Hypothese: fake-libpulse's write_callback feuert zu aggressiv (oder gar nicht korrekt), writable_size returned zu viel Platz, und der Client (Soloist) schreibt schneller als der HTTP-Consumer liest → Stutter.

## Evidence

- timestamp: 2026-09-01T11:53:00Z
  checked: Live daemon log /var/lib/squeezeboxserver/cache/spoton/52540043d5c2-soloist.log (current running session, player "claude", track spotify:track:3LIcZcZnXVQbBbgVmDALUQ "Heavy Soul", SPOTON_FAKEPULSE_DEBUG=1 / trace level 1), read via `sudo cat` (file owned by squeezeboxserver:nogroup) into a scratch copy, tailed the most recent ~2.5 minutes of TIMING lines for stream 0x7851f45af860
  found: corked=1 for the ENTIRE observed session (~2m29s) — Soloist never uncorks — yet bytes_written grows continuously the whole time (real audio IS flowing, matching the sibling "stuck-corked" sessions' finding that audio plays while the PA-facing progress/cork state stays frozen). fill climbs from the initial burst up to 7,047,680 bytes (RING_CAPACITY = 44100*4*2*20 = 7,056,000) by ~50s after connect, then stays pinned at ~7,047,680 (oscillating by one 16384-byte pop) for the rest of the session. Crucially, bytes_written growth rate CHANGES at the exact moment fill saturates: before saturation it tracks ~352,800 B/s (Soloist's natural real-time decode pace); after saturation it locks to EXACTLY 655,360 bytes per 2.000s = 327,680 B/s, measured across 40+ consecutive samples with zero deviation, for 80+ continuous seconds.
  implication: 327,680 B/s = 16384 bytes / 0.050s exactly — the HTTP-serving thread's hard per-tick byte cap. Once the ring is full and the Phase 78 backpressure blocks the producer, the producer's effective rate becomes bottlenecked by the CONSUMER's (HTTP thread's) rate, which is fixed at 327,680 B/s regardless of how much data is available — 7.12% below the 352,800 B/s required for real-time S32LE 44.1kHz stereo. This is a genuine, sustained, deterministic throughput deficit, not a transient/racy effect.

- timestamp: 2026-09-01T11:56:00Z
  checked: fake-libpulse.c source — `_http_thread_fn` (lines ~744-1040), `_ring_pop_timed` (lines 515-552), `#define RING_BYTES_PER_SEC` (line 316), `chunk[16384]` (line 921), `poll(fds, ..., 50)` (line 791)
  found: `_ring_pop_timed(&g_ring, chunk, sizeof(chunk)=16384, 50)` caps every single pop at 16384 bytes regardless of how much `fill` is available (`chunk = maxlen < r->fill ? maxlen : r->fill`) — it never loops to drain more within one call. The enclosing `for(;;)` loop's ONLY blocking wait when a client is steadily attached and no new connections arrive is the top-of-loop `poll(fds, pending_idx>=0?2:1, 50)` against the LISTEN socket, which blocks the full 50ms in steady state (no data arrives on a listen socket). So each loop iteration takes ~50ms wall-clock and delivers at most 16384 bytes — a hard-coded ceiling of 327,680 B/s baked into the thread's structure, independent of ring fill level, Soloist's write rate, or the Phase 78 change (blocking vs. drop-oldest at the ring only changes what happens to EXCESS bytes when full — it cannot make the HTTP thread drain faster).
  implication: Confirms the ceiling is structural (in the loop's own cadence + fixed chunk size), not an artifact of the specific log sample. RING_BYTES_PER_SEC (352,800, S32LE) has no relationship enforced anywhere to the HTTP thread's 16384/50 constants — nothing in the code derives one from the other.

- timestamp: 2026-09-01T11:58:00Z
  checked: `git log -L 921,922:...fake-libpulse.c` (blame for the `chunk[16384]` line) and `git show 74327fa` (commit "feat(76-01): upgrade fake-libpulse ring from S16LE to S32LE (D-04)", 2026-08-29)
  found: `chunk[16384]` was introduced in `0cf32f5 feat(73-01): fake-libpulse HTTP streaming mode (D-04)`, when the ring was S16LE (`RING_BYTES_PER_SEC = 44100*2*2 = 176,400 B/s`) — at that rate, 327,680 B/s was ~1.86x headroom, safely fast enough, never a bottleneck. Commit `74327fa` (Phase 76-01) changed `RING_BYTES_PER_SEC` from `44100*2*2` to `44100*4*2` (176,400 -> 352,800 B/s) as part of upgrading the ring's native format to S32LE, and updated `RING_CAPACITY`, `_convert_and_push`, and the timing/`fill_input` math accordingly (per its own commit message) — but its diff touches NEITHER `chunk[16384]` nor the `poll(..., 50)` timeout anywhere; grep of that commit's full diff for "16384" and "chunk[" returns zero hits in `_http_thread_fn`.
  implication: Decisive, git-history-corroborated confirmation. The 16384/50ms constants were correctly sized for the ORIGINAL S16LE-era rate and were never rescaled when 74327fa doubled the required real-time byte rate to S32LE. This exactly matches the reported timeline ("existiert seit den ersten Soloist-Audio-Tests", i.e. since Soloist's ring first needed the higher S32LE rate) and explains why the deficit is small enough (7.12%) to not be instantly, catastrophically obvious, yet large enough to guarantee eventual downstream buffer underrun given any sustained playback duration.

- timestamp: 2026-09-01T12:00:00Z
  checked: Re-examined the "Ring-Buffer drop-oldest (blocking getestet, kein Effekt)" already-eliminated hypothesis (Ausgeschlossene Hypothesen #1) in light of the throughput-ceiling finding; confirmed via `git diff HEAD -- fake-libpulse.c` that the Phase 78 blocking-on-full fix (`_ring_push` waits on `space_avail` instead of dropping oldest bytes when `r->fill == r->capacity && r->client_connected`) is currently applied in the working tree (uncommitted)
  found: Whether the ring's full-buffer policy is "drop-oldest" (old) or "block producer" (Phase 78, current), the HTTP thread's own drain rate is IDENTICAL either way (327,680 B/s, fixed by chunk/poll constants, not by ring policy) — so downstream (squeezelite) is underfed by the same 7.12% under BOTH policies. This fully explains, with a specific mechanism rather than just an empirical "no effect" observation, why testing the blocking fix produced "identisches Stutter-Verhalten": the ring-full policy was never the bottleneck; the HTTP thread's fixed per-tick byte budget is.
  implication: Strengthens confidence in the throughput-ceiling hypothesis — it is the ONE mechanism that (a) is unaffected by the ring-policy change already tested and eliminated, (b) is unaffected by Phase 78's bounded-endpoint feature (separate code path, boundary POST handling, confirmed via source read), (c) predates Phase 78 entirely (introduced at 74327fa, before Phase 77/78 existed), and (d) is fully reproducible/measurable in a live capture.

## Eliminated

- hypothesis: "fill_input = 2 * fill in some TIMING lines indicates a byte-counting bug in _stream_refresh_timing's read_index/fill_input scaling math"
  evidence: "Live daemon log (current session, S32LE format, input_bps=4 branch) shows fill_input == fill in every single TIMING line without exception (e.g. `fill=7047680 fill_input=7047680`), consistent with the current formula `fill_input = fill * input_bps / 4` correctly reducing to identity for S32LE/FLOAT32LE input. No 2x relationship was observed in this session's fresh capture. (The '2 * fill' observation likely refers to the OLDER `fill_input = fill * input_bps / 2` formula documented as already-superseded in the sibling debug session .planning/debug/fakepulse-timing-buffer.md, line 19 — that formula predates the Phase 76-01 S32LE upgrade and is not the currently-running code.)"
  timestamp: 2026-09-01T11:55:00Z

## Resolution

- root_cause: "fake-libpulse.c's HTTP-serving thread (_http_thread_fn) drains the ring at a hard-coded, structural ceiling of 16384 bytes per ~50ms poll cycle = 327,680 B/s (the loop's only steady-state wait is the top-level `poll(fds, ..., 50)` against the listen socket, and `_ring_pop_timed` never pops more than `chunk[16384]` bytes per call regardless of available fill). This constant was correctly sized for the S16LE-era ring (176,400 B/s required, introduced in commit 0cf32f5 / Phase 73-01) but was never rescaled when commit 74327fa (Phase 76-01, 'upgrade fake-libpulse ring from S16LE to S32LE') doubled the required real-time rate to 352,800 B/s (RING_BYTES_PER_SEC: 44100*2*2 -> 44100*4*2). The result is a permanent, deterministic 7.12% underfeed of the audio consumer (squeezelite via /stream), present continuously since that commit, regardless of Soloist's own write behavior, ring capacity, or the Phase 78 ring-full policy (block vs. drop-oldest) — sustained starvation of a finite downstream buffer eventually and repeatedly underruns, producing the reported millisecond-gaps -> ~5s-silence -> catch-up cyclic stutter pattern. Directly measured live: post-saturation bytes delivered grow at EXACTLY 655,360 bytes/2.000s = 327,680 B/s for 80+ continuous seconds, an exact match to 16384/0.050."
- fix: "NOT APPLIED (goal: find_root_cause_only — diagnosis only, per session mode). Suggested fix direction: rescale the HTTP thread's per-tick byte budget to match real-time S32LE throughput (RING_BYTES_PER_SEC * 0.05 = 17,640 bytes per 50ms tick, replacing the stale 16384), and/or restructure the drain step to loop within the tick until it has delivered enough bytes to keep pace, rather than a single fixed-size pop per ~50ms poll cycle. Any fix must be re-verified against a live, sustained (multi-minute) playback capture — a short test could look fine while still carrying the 7% deficit, since the deficit only manifests as an underrun once a downstream buffer (squeezelite streambuf/outputbuf) has had enough elapsed time to drain from the shortfall."
- verification: "N/A — root-cause diagnosis only, no fix implemented or verified this session."
- files_changed: []

## Specialist Review

- reviewer: engineering:debug (general specialist dispatch)
- verdict: SUGGEST_CHANGE — diagnosis confirmed correct via independent source read; fix direction on target but must NOT be applied as the bare "rescale to 17,640 B/tick" variant.
- confirmed mechanism details: poll(fds, ..., 50) at line 791 blocks the full 50ms in steady state; _ring_pop_timed (lines 533-535) caps at maxlen, and its 50ms timedwait only applies when the ring is EMPTY — during saturation the pop returns instantly, so cadence is set solely by the top-of-loop poll. Additionally, with the Phase 78 blocking _ring_push (line 475), the PRODUCER is also throttled to the consumer's 327,680 B/s — the whole pipeline runs at ~92.9% of real time.
- specific improvements before applying a fix:
  1. Do NOT size the per-tick budget to exactly 1.00x real time (17,640 B). poll() is a minimum sleep (kernel oversleeps 1-2ms), and ticks are occasionally consumed by pending-connection reads, flush handling, and boundary trims (lines 942-951). Zero headroom means every lost microsecond is a permanent unrepayable deficit — failure recurs on a slower timescale. Original design had 1.86x headroom; preserve multi-x headroom.
  2. Prefer a BOUNDED inner drain loop: pop-and-write up to N chunks per tick (N=4 with the existing 16384 chunk gives ~3.7x real-time headroom), stopping early when the ring is empty, a write fails, or the boundary closes the client. Must be bounded — _http_write_all (line 692) blocks-with-poll on POLLOUT, and with Phase 78 backpressure the ring is essentially never empty during playback; an unbounded "drain until empty" loop would starve the top-of-loop poll() (g_flush_disconnect / skip responsiveness at line 760, WR-11 takeover, new-connection accepts).
  3. Inner-loop exit conditions need explicit breaks: on write_failed and at_boundary (lines 974-999) client_fd becomes -1 — break immediately, do not pop again for a closed client. The at_boundary trim math (lines 956-967) works per-pop and survives an inner loop as long as each iteration re-reads total_popped (it already does).
  4. Keep chunks frame-aligned: S32LE stereo frames are 8 bytes; if any new constant is derived from RING_BYTES_PER_SEC, assert/round to a multiple of 8.
  5. underflow_cb interaction is fine: g_ring_underrun_fired edge-triggering (lines 1014-1039) still behaves correctly with an inner drain loop.
  6. Verification: multi-minute live capture; assert bytes_written growth >= 352,800 B/s sustained AND that the ring never sits pinned at capacity.
- portability: shim is Linux-only (pthreads/poll); Windows-compat rule for Perl parts does not constrain this fix. The gettimeofday-based _ring_pop_timed deadline is wall-clock-sensitive — pre-existing unrelated wart, not a blocker.

## Prior Session Cross-Reference

This bug is DISTINCT from (but likely compounds with) the "stuck-corked" mechanism documented in the sibling sessions `.planning/debug/soloist-browse-stutter.md` and `.planning/debug/fakepulse-timing-buffer.md` (Soloist's own internal worker-thread lifecycle gates its uncork/position-reporting, unrelated to fake-libpulse's PA-API surface). Both mechanisms can coexist: Soloist may sit corked (frozen position report) while still writing real audio, AND that real audio is simultaneously being underfed to the HTTP client at 92.88% of real-time rate. The throughput-ceiling bug documented in THIS session is fully evidenced, root-caused to a specific commit/line, and — unlike the "stuck-corked" mechanism — is entirely within fake-libpulse.c's control and does not require reverse-engineering Soloist's closed-source internals to fix.
