---
phase: 77
reviewers: [fable]
reviewed_at: 2026-09-01T19:32:35Z
plans_reviewed: [77-01-PLAN.md, 77-02-PLAN.md, 77-03-PLAN.md, 77-04-PLAN.md, 77-05-PLAN.md, 77-06-PLAN.md]
models:
  fable: "claude-fable-5"
model_sources:
  fable: "orchestrator-specified"
review_mode: in-session-subagent
cross_ai: false
---

# Plan Review — Phase 77

> **Not a cross-AI review.** No external reviewer CLI is installed on this host
> (gemini, codex, opencode, qwen, cursor-agent, agy, kimi, coderabbit all absent;
> no local model server reachable). The only external CLI present is `claude`,
> which `/gsd-review` excludes for independence when running inside Claude Code.
> This review was produced instead by a fresh Fable subagent with full repo access
> and an adversarial brief. It is an independent *context* — no memory of the
> planning session — but not an independent *model family*, so it shares Claude's
> blind spots. Weight it accordingly: its `file:line` findings are verifiable
> evidence; its clean bills are weaker assurance than a true cross-AI pass.
>
> The reviewer verified claims against source and ran `make -C Plugins/SpotOn/Bin/fake-libpulse test`
> (9 `ok:` baseline confirmed) and `prove -l t/31_soloist_ws.t` (143 tests confirmed).

## Fable Review


Reviewer: independent, no stake in the plans. Every claim below was checked against the working tree at `/home/sti/spoton` (branch `soloist`), including a live run of the C host-test suite.

## 1. Summary

The six plans are unusually well-grounded: nearly every line anchor, test count, and behavioral claim I checked against the actual source is correct (baseline of 9 `ok:` host tests confirmed by running `make test`; t/31 at 143 tests confirmed by running `prove`; the CR-S1 duplication really lives in SoloistWS.pm, not Connect.pm as CONTEXT/ROADMAP wrongly state — the plans caught and corrected their own upstream inputs). The headline design (arm-counter + conditional flush + drain-loop write gate, with the WS command dispatched from inside the arm-POST completion callback) is sound against the specific race it targets: because the arm handler runs on the same HTTP thread as the drain gate, and the Perl side sequences the WS seek strictly after the arm response, there is no check-then-act window between the gate test and the write for a *deliberate* flush. The real weakness is the arm counter's *lifecycle*, not its atomicity: nothing ever resets a leaked arm. If an armed flush never arrives — daemon ignores the seek, `sendCommand` fails after a successful arm, or (most concretely) the mismatch-arm fires against a *stopped* daemon whose stale `lastTrackId` makes it look mid-track — the drain gate wedges shut, all audio is withheld, and even the session-end boundary EOF (D-11) can never be reached, because boundary close requires pops the gate forbids. The plans assert D-11 survives as a "truth" but provide no mechanism or test for the leak case. That gap is fixable with a small addition (reset the counter on `POST /boundary` and/or a TTL) and one host test; everything else is solid.

## 2. Strengths

- **Root cause correctly traced and mechanism matches it.** `pa_stream_flush()` really does set `g_flush_disconnect = 1` unconditionally (`Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:2007`), consumed at loop top (`fake-libpulse.c:756-775`), and it is the daemon's only entry point for both seek and skip — the out-of-band arm signal is the only viable discriminator, exactly as RESEARCH's Anti-Pattern section argues (`77-RESEARCH.md:251`).
- **The arm/gate concurrency design is actually race-free for the deliberate-flush path.** Arm increments happen on the HTTP thread itself (the `/seek-arm` control branch mirrors `POST /boundary` at `fake-libpulse.c:834-857`, processed *before* the drain in the same loop iteration), the WS command is only sent from the arm-POST completion callback (`77-04-PLAN.md:33,95`), and the decrement in `pa_stream_flush()` is ordered after `_ring_flush` (`77-01-PLAN.md:126`). I traced the interleavings: the drain gate can never read `armed==0` while pre-seek bytes from an armed flush are still servable. `atomic_int` is sufficient here — the prompt's suspected TOCTOU window between gate test and write does not exist for armed flushes.
- **Test-count claims verified against reality.** `make -C Plugins/SpotOn/Bin/fake-libpulse test` prints exactly 9 `ok:` lines today (run during this review); the 9→10→11→12→14 ladder in the plans' verify commands is internally consistent, and 77-RESEARCH.md:421 even corrects a stale `grep -qx 6` from a prior phase.
- **Plans corrected erroneous upstream context instead of propagating it.** CONTEXT (`77-CONTEXT.md:16`, canonical_refs) and ROADMAP (`ROADMAP.md:533`) both place CR-S1 in Connect.pm:800-882; the duplicated drift math actually lives in `SoloistWS.pm:800-811` and `:869-878` (verified), with the exact `sessionActive` guard divergence Plan 77-02 pins by test (`77-02-PLAN.md:38,84`).
- **CR-S3 divergences accurately catalogued and pinned tests-first.** `_pollWsPort` has the mtime-vs-`_spawnTime` stale-file guard and `stop()` on exhaustion (`SoloistDaemon.pm:302-306,323-327`); `_pollHttpPort` has neither, falls through with the WR-07 comment (`SoloistDaemon.pm:378-390,398-402`). Plan 77-02 extracts only the shared scaffold and writes the first-ever poll coverage before refactoring (`77-02-PLAN.md:113-115`) — t/30 indeed covers only `_spawnArgs` today (`t/30_soloist_daemon.t:308-327`).
- **D-12 regression protection is real.** The existing `ok: reconnect after flush-disconnect attaches and drains immediately` test (`fake-libpulse.c:2763`) is explicitly kept as the unarmed-flush pin (`77-01-PLAN.md:140`), and 77-05's Test B third-flush assertion proves counter exhaustion restores disconnect semantics (`77-05-PLAN.md:101,113`).
- **Byte-content assertions mandated, not lifecycle-only.** Pitfall 3 (`77-RESEARCH.md:279-283`) is honored in both 77-01 Task 2 (memcmp requirement, `77-01-PLAN.md:141`) and 77-05 Test A (`77-05-PLAN.md:112`) — the exact class of false-green test a lazy plan would have written.
- **CLAUDE.md compliance clean.** `_armSeekFlush` mandates `Slim::Networking::SimpleAsyncHTTP` (never LWP) with a loopback URL built only from `$helper->_streamPort` (`77-04-PLAN.md:95`); zero new packages anywhere; Perl constructs are 5.10-safe (dynamic method dispatch, closures).
- **Degrade-open on arm failure.** Test 5 (`77-04-PLAN.md:91`) pins that an arm-POST error still dispatches the WS command — a dead control endpoint degrades to the pre-77 disconnect behavior instead of wedging `getNextTrack`.
- **Wave-1 `files_modified` sets are genuinely disjoint.** 77-01: fake-libpulse.c + .so; 77-02: SoloistWS.pm/SoloistDaemon.pm + t/30/t/31; 77-03: SpClient.pm + t/36. No overlap, verified against what the tasks actually touch.
- **Deferring 78-UAT tests 11/15 is defensible.** The Wave-3 checkpoint items 1-5 (`77-06-PLAN.md:71-77`) are Browse-only (seek, double-seek, rapid-skip, daemon crash, EOF advance); the broken Connect transfer (resume `_p2` carrying `0.000` as trackId, a SoloistWS/Connect parameter bug per `78-UAT.md` gaps) cannot contaminate any of them. The deferral is recorded visibly in three places (77-04 objective, 77-06 objective, SUMMARY requirements).
- **CI claims verified.** `build-fake-libpulse.yml` has `workflow_dispatch` at line 20, a 3-job `bin_dir` matrix, a "Verify binary" step at line 80, and native-only host tests at line 69 — exactly as 77-06 Task 3 describes; the `-std=gnu11`-not-`-std=c11` remedy is technically correct (c11 would drop POSIX extensions pthread.h needs).
- **Repo convention for committing the .so verified.** Commit `6cf03a8` does include both `fake-libpulse.c` and `libpulse.so.0`, as 77-01 claims.
- **No test today asserts the removed Connect.pm forwarding.** `grep -rn '_bufferedBrowseSeek\|_onSeek' t/` returns nothing — 77-04 Task 2's "zero test edits expected" claim holds; and 77-06 Task 2's caution to preserve `_soloistBrowseWs` (still called from `_onPause`, `Connect.pm:655`) and `SEEK_DEBOUNCE` (used by `_bufferedSeek`, `Connect.pm:852`) is accurate.

## 3. Concerns

- **HIGH — A leaked arm has no recovery path and wedges the entire bounded contract, including D-11 session-end EOF.** The counter is incremented by `POST /seek-arm`, decremented only by `pa_stream_flush()`, and reset only in `_fake_libpulse_init` (daemon restart) (`77-01-PLAN.md:124-128`). If an arm lands but its flush never arrives — the daemon ignores the seek, the WS drops between arm and command (Plan 77-04's callback calls `$ws->sendCommand('seek', ...)` with no failure handling; `sendCommand` returns 0 when not connected, `SoloistWS.pm:354-359`), or the mismatch-arm fires against a daemon that doesn't flush (see next finding) — then `g_seek_flush_armed > 0` forever: the drain-loop write gate withholds all audio, and because boundary EOF is only reached by *popping* to the watermark (`fake-libpulse.c:955-1006`), a subsequent `stopped` → `POST /boundary` can never close the client. Plan 77-01's must_have literally asserts "the arm counter must be 0 at session end and must never suppress the boundary close" (`77-01-PLAN.md:25`) and 77-05's D-11 truth repeats it (`77-05-PLAN.md:25`), but **no task implements a mechanism and no host test covers arm-without-flush → boundary**. 77-05's three tests all pair arms with flushes. The saturation cap (8) bounds winding, not leaking. Concrete failure: playback goes permanently silent mid-session with the HTTP client held open until the daemon is killed — strictly worse than the seek-skip bug being fixed.
- **MEDIUM — The D-05 mismatch-arm condition `$daemonCurrent ne ''` conflates "daemon mid-track" with "daemon stopped, stale lastTrackId", providing a mainstream trigger for the HIGH leak.** `SoloistWS.pm` never clears `lastTrackId` on `stopped` (`_onPlaybackChanged` at :731/:758 signals the boundary and sets `sessionPaused` but leaves `lastTrackId` intact; updates at :642/:847 are set-only). So the ordinary flow "album finishes → session stops → user plays a different album" hits the play branch with `daemonCurrent ne ''` → arms (`77-04-PLAN.md:99`) — but whether Soloist calls `pa_stream_flush()` when starting playback from a stopped state (nothing buffered) is precisely the unverified A2 territory (`77-RESEARCH.md:376`). If it doesn't flush, the arm leaks per the HIGH finding. Worse, the 77-06 UAT script (`77-06-PLAN.md:72-76`) never tests "session end → play new track" — items 3/5 cover mid-track skips and natural advance only — so the phase gate would not catch it either.
- **MEDIUM — Seek edge cases in the resume branch: seek-while-paused and seek-to-zero.** The dispatch condition uses truthiness of `$song->seekdata->{timeOffset}` (`77-04-PLAN.md:98`): (a) a seek to position 0 (timeOffset 0, falsy) silently degrades to an un-armed `play` resume with no WS seek — the daemon keeps playing at the old position while LMS's UI shows 0:00 (the same falsy-0 idiom already exists in `ProtocolHandler.pm:199,209`, but this plan extends its blast radius to the WS command path); (b) when the seek dispatch replaces the existing `sendCommand('play')` for a *paused* daemon, the plan sends only `seek` — if Soloist's seek does not implicitly resume, playback stays paused with LMS expecting a stream. Neither case appears in the six behavior rows or the UAT script.
- **MEDIUM — CR-S2's numbers are wrong and the item is mild scope creep.** There are **16** guard call sites, not 17: `grep -n '_hasLogin5Creds' SpClient.pm` yields 18 hits = 1 comment (line 209) + 1 definition (line 212) + 16 `unless` guards (476, 699, 779, 844, 925, 992, 1051, 1103, 1180, 1485, 1540, 1622, 1769, 1821, 2106, 2190), of which line 1180 is a non-uniform compound guard (`unless ($type eq 'track' && ...)`) the wrapper cannot absorb cleanly. Plan 77-03's acceptance criterion "`grep -c '_delegateToClient'` returns 18 (1 definition + 17 call sites)" (`77-03-PLAN.md:100`) is unattainable; the executor will chase a phantom site before falling back to the documented-exceptions escape hatch. Separately: CONTEXT rated CR-S2 "evaluate wrapper, low priority" (`77-CONTEXT.md:16`) and the plan resolved it as "implement" — the plan does document its evaluation and the argument-transposition risk (`77-03-PLAN.md:34,93`), and t/36's stub recorders pin delegation, so this is defensible; but a 16-site mechanical edit is the least valuable and most tedious work in a phase whose gate is a C-layer seek fix. Dropping it would cost nothing the phase goal needs.
- **LOW — T-77-03 understates the `/seek-arm` DoS impact.** The register describes the residual as "up to 8 suppressed flushes" (`77-01-PLAN.md:164`), but an armed counter also *mutes all audio* via the drain gate until flushes arrive — a LAN peer can silence playback indefinitely by re-arming (the cap saturates, it does not decay). Materially the same accepted posture as `POST /boundary` (which can already kill streams), so acceptance is fine, but the register should describe the real impact — and a TTL/boundary-reset (see Suggestions) shrinks it for free.
- **LOW — Pre-existing dead logic in the takeover block that 77-05's Test A will collide with.** In `_http_thread_fn`, `int was_supersede = (client_fd >= 0);` is computed *after* the branch that already closed and reset `client_fd` to -1 (`fake-libpulse.c:866-895`), so `was_supersede` is always 0 and a pending `g_flush_disconnect` is unconditionally cleared on every promotion — the code's comment describes intent the code does not implement. Behaviorally it happens to be safe today, but 77-05 Task 2's armed-window takeover test exercises exactly this region; the executor should be told the flag is dead so a "fix" or a test built on the comment's claimed semantics doesn't misfire.
- **LOW — Wave-2 parallel plans share full-suite verification gates while one edits test files.** Plans 77-04 and 77-05 run in the same wave; 77-04 modifies `t/29` while 77-05's verification includes `prove -l t/*.t` (`77-05-PLAN.md:139`). If the executor runs plan-level verification concurrently rather than at the wave merge, the full-suite run can race a half-edited t/29. Harness detail, not a design flaw.

## 4. Suggestions

1. **Give the arm counter a lifecycle, not just a cap (addresses the HIGH).** Cheapest robust option: reset `g_seek_flush_armed = 0` inside the `POST /boundary` handler — a boundary is the authoritative "track/session transition" signal from Perl, and any arm still pending at that moment is by definition stale (its flush would have preceded the track change). Optionally also clear it in the `g_flush_disconnect` consumption block. Add one host test: arm once, never flush, push past a planted boundary → client still closes at the watermark (this is the test the D-11 must_haves in 77-01/77-05 claim but never get). A 2-5s wall-clock TTL on arms is an acceptable alternative but the boundary-reset is simpler and thread-confined (both run on the HTTP thread).
2. **Narrow the D-05 arming condition in 77-04.** Arm the play branch only when the daemon is plausibly mid-track — e.g. `$daemonCurrent ne '' && !$ws->sessionPaused` (or clear `lastTrackId` on `stopped` in SoloistWS.pm, which also fixes the stale-id ambiguity for other consumers). Also move `$successCb` handling so a `sendCommand` failure after a successful arm is at least logged as an arm-leak event; with suggestion 1 in place the leak self-heals at the next boundary.
3. **Fix the falsy-0 seek and decide paused-seek semantics.** Use `defined $song->seekdata->{timeOffset}` (LMS sets it only on genuine seeks) and, for the paused case, send `seek` followed by the existing `play` resume (Soloist treats play-without-uri as resume/no-op per the code comment at `ProtocolHandler.pm:794-797`, so appending it is safe in the playing case too).
4. **Correct CR-S2's counts (16 sites, 15 uniform) in 77-03's acceptance criteria** — or drop CR-S2 from the phase entirely; nothing downstream consumes it.
5. **Add one UAT item to 77-06 Task 1:** "let an album play to session end (daemon `stopped`), then start a different album from Browse — audio must start within ~2s." This is the cheapest live probe of both the stale-`lastTrackId` arming path and Soloist's flush-on-play-from-stopped behavior (A2's least-tested corner).
6. **Tell 77-05's executor that `was_supersede` is dead code** so Test A is written against actual behavior (flush-disconnect always cleared on promotion), and consider fixing the computation while in the region — it is a two-line move.

## 5. Risk Assessment

**MEDIUM.** The phase goal — a bounded per-track HTTP response where socket close is a real EOF at the track boundary, with seek no longer masquerading as EOF — is achievable with these plans as written: the root cause is correctly identified, the arm/gate mechanism is race-free for the orchestrated path, the ordering guarantee is enforced by callback rather than timing, the regression pins (D-12 unarmed flush, boundary EOF, soloistBrowseActive gate) are real tests I verified exist, and the factual accuracy of the plans against the source is exceptional. What keeps this at MEDIUM rather than LOW is a single structural gap with a mainstream trigger: the arm counter can leak (stopped-daemon mismatch arm, WS failure after arm, unknown Soloist flush cardinality — the exact A2 uncertainty RESEARCH itself flags) and nothing resets it, converting the old "seek skips a track" bug into a worse "playback silently wedges until daemon restart" failure mode that neither the 14 host tests nor the UAT script as specced would catch. Suggestion 1 (boundary-reset + one host test) plus suggestion 5 (one UAT line) closes that gap at trivial cost; with those amendments I would rate the phase LOW risk.

---

## Consensus Summary

Single reviewer — no cross-reviewer consensus is available. Findings below are one
independent, source-grounded opinion, not agreement between models.

**Verdict: MEDIUM risk** — 1 HIGH, 3 MEDIUM, 3 LOW. The reviewer states the phase
goal is achievable as planned and rates the plans' factual accuracy against source
as exceptional; the MEDIUM rating rests on a single structural gap, and the reviewer
would rate the phase LOW with two cheap amendments (Suggestions 1 and 5).

### Principal concern (HIGH)

The `g_seek_flush_armed` counter has **no recovery path**. It is incremented by
`POST /seek-arm`, decremented only by `pa_stream_flush()`, and reset only on daemon
restart. If an arm lands but its flush never arrives — daemon ignores the seek, the
WS drops between arm and command, or a play-from-stopped does not flush — the counter
stays above zero forever, the drain-loop write gate withholds all audio, and boundary
EOF can never fire because EOF is reached by popping to the watermark. That converts
today's "seek skips a track" bug into "playback silently wedges until the daemon is
killed" — strictly worse than the bug being fixed. Plans 77-01 and 77-05 *assert* the
counter is 0 at session end as a `must_haves` truth, but no task implements a mechanism
and no host test covers arm-without-flush → boundary. Proposed fix is cheap: reset the
counter in the `POST /boundary` handler (both run on the HTTP thread) plus one host test.

### Second-order concern (MEDIUM, feeds the HIGH)

`SoloistWS.pm` never clears `lastTrackId` on `stopped`, so the ordinary "album ends →
play a different album" flow satisfies the D-05 mismatch-arm condition and arms a flush
that may never come — and the Wave-3 UAT script does not exercise that path, so the
phase gate would not catch it either.

### Factual corrections the reviewer found

- CR-S2 has **16** guard call sites, not 17 (one of them a non-uniform compound guard the
  wrapper cannot absorb). Plan 77-03's acceptance criterion expecting a `grep -c` of 18
  is therefore unattainable as written.
- `int was_supersede = (client_fd >= 0);` in `_http_thread_fn` is dead — it is computed
  after the branch that already reset `client_fd` to -1, so it is always 0 and the code's
  comment describes intent the code does not implement. Plan 77-05 Task 2 tests exactly
  this region.

### Claims the reviewer checked and cleared

- No check-then-act window between the drain-gate test and its write — arming runs on the
  same HTTP thread and callback ordering sequences the flush after it, so `atomic_int` suffices.
- The 9→10→11→12→14 host-test ladder is correct against the current harness.
- Wave 1's three plans have genuinely disjoint file sets.
- Deferring 78-UAT tests 11/15 to Phase 78 is defensible — the Wave-3 UAT items are Browse-only.
- The plans correctly overrode CONTEXT/ROADMAP's wrong claim that CR-S1 lives in `Connect.pm`.

### Divergent Views

None recorded — single reviewer.
