---
phase: quick
plan: 260831-wdg
type: execute
wave: 1
depends_on: []
files_modified:
  - Plugins/SpotOn/Plugin.pm
autonomous: true
requirements: []

estimate:
  tokens: 35000
  raw_tokens: 23000
  tasks: 2
  confidence: low

must_haves:
  truths:
    - Browse playback after an LMS restart (squeezelite kept running) survives past 40s without a forced skip
    - _prefetchWatchdog never arms the hang check from an elapsed value that is more than 30s past track duration
    - _prefetchWatchdog never reads the play point while the player is still buffering (playing state != PLAYING)
    - Genuine near-end hang detection (Phase 27 purpose) still works — watchdog arms within seconds of a real elapsed crossing duration-3
  artifacts:
    - Plugin.pm _prefetchWatchdog with isPlaying(1) guard and elapsed sanity bound
  key_links:
    - _prefetchWatchdog re-polls (2s) instead of arming _prefetchHangCheck when play-point data is untrustworthy
---

<objective>
Fix the forced-skip loop that breaks Soloist Browse playback after an LMS
restart with a still-running squeezelite.

Root cause (live log 2026-08-31 10:12-10:14, /var/log/squeezeboxserver/server.log):
`_prefetchWatchdog` (Plugin.pm ~4032) computes
`elapsed = $client->songElapsedSeconds() + $song->startOffset`.
`songElapsedSeconds` (LMS Squeezebox2.pm:434) is built from squeezelite's STMt
play-point plus a jiffies-timestamp extrapolation. After an LMS restart while
squeezelite keeps running, that play-point refers to the PREVIOUS (pre-restart)
stream until the new track actually starts (STMs) — and the jiffies mapping can
be so broken the extrapolation returns epoch-scale garbage. Live values against
a fresh Browse track still BUFFERING:

- 10:13:03.94  elapsed=4727.566s      duration=112s      (stale pre-restart play point)
- 10:13:34.03  elapsed=1787006093.35s duration=293.802s  (epoch-scale jiffies garbage)

Both readings pass the `elapsed >= duration - 3` near-end test, arm
`_prefetchHangCheck`, and 10s later force `playlist jump +1` on a track that is
playing fine — every track dies at exactly newsong+20s, a deterministic skip
loop. The `BUFFERING-STREAMOUT` / `ReadyToStream` `_Invalid` state error is a
secondary LMS-core symptom of the restart (restored PAUSED controller state
colliding with the stale squeezelite stream, iteration 1 only); LMS recovers
from it on its own. The audio pipeline (Soloist + fake-libpulse) is healthy —
the fix is purely in the watchdog's trust of player-reported elapsed time.

NOT the cause (verified in the same log, do not touch): Soloist position leak
into LMS — `_emitAllowed`'s browseSession guard suppressed the restored
session's seek/resume emissions, and Connect.pm's D-16 stale-claim release
fired correctly at 10:12:18.72. The D-17 gate worked as designed (resolved
'ready' after ~9.7s).

Fix: two defensive guards in `_prefetchWatchdog` so it only acts on play-point
data that can be trusted, re-polling on its normal 2s cadence otherwise.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@Plugins/SpotOn/Plugin.pm

Read only the watchdog section (~lines 3916-4082): `_onNewSongWatchdog`,
`_prefetchWatchdog`, `_prefetchHangCheck`.

Key facts for the executor:
- `Slim::Player::Source::playmode($client) eq 'play'` (existing guard, line
  ~4039) is TRUE while the player is still BUFFERING — it is the requested
  mode, not the actual playing state.
- `$client->isPlaying(1)` (Slim::Player::Client:1351 →
  StreamingController::isPlaying with $really=1) is TRUE only when
  playingState == PLAYING — false during BUFFERING and WAITING_TO_SYNC. This
  is the precise "the play point now refers to THIS track" signal: squeezelite
  resets its elapsed counter when the new track starts (STMs → PLAYING).
- The watchdog polls every 2s while playing, so a GENUINE near-end hang is
  caught within ~2-3s of elapsed crossing duration-3; a legit reading can
  never be 30s past duration at poll time. The sanity bound therefore costs
  nothing in real hang detection.
- The 2s re-poll timer is the same one the existing "not near end" branch
  sets (lines ~4060-4064); `_onNewSongWatchdog` kills all these timers on
  every newsong, so re-polling cannot leak across tracks.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Guard _prefetchWatchdog against untrusted play-point data</name>
  <files>Plugins/SpotOn/Plugin.pm</files>
  <action>
    In `_prefetchWatchdog`, immediately after the existing
    `return unless Slim::Player::Source::playmode($client) eq 'play';` guard,
    add guard 1 — do not read the play point while buffering:

    - `unless ($client->isPlaying(1)) { ... }`: inside, set the normal 2s
      re-poll timer (`Slim::Utils::Timers::setTimer($client,
      Time::HiRes::time() + 2, \&_prefetchWatchdog)`) and return.
    - Comment (English, per project convention) explaining WHY: playmode
      'play' includes BUFFERING; after an LMS restart with squeezelite still
      connected, STMt play-point data refers to the previous stream (or is
      jiffies-extrapolation garbage) until the new track reaches PLAYING —
      reading it here caused false near-end classification (live values
      4727.566s and 1787006093s against 112s/293s tracks, 2026-08-31 UAT).

    After the existing elapsed computation
    (`my $elapsed = $rawElapsed + $startOffset;`), before the
    `if ($elapsed >= $duration - 3)` near-end test, add guard 2 — sanity
    bound on the computed value:

    - `if ($elapsed > $duration + 30) { ... }`: inside, log an UNCONDITIONAL
      `$log->warn(...)` (not gated on diagnosticMode — this is a rare,
      field-triage-valuable event) naming the bogus value, the duration, and
      that the play point is being ignored, e.g.
      "Prefetch watchdog: implausible elapsed ${elapsed}s for
      ${duration}s track — ignoring stale play point"; then set the same 2s
      re-poll timer and return.
    - Comment explaining the bound: the 2s poll cadence means a real hang is
      caught within ~2-3s of crossing duration-3, so a value more than 30s
      past duration cannot come from real playback of this track.

    Do NOT change `_onNewSongWatchdog`, `_prefetchHangCheck`, the near-end
    arming logic, or the 10s hang-check delay. Keep both guards local to
    `_prefetchWatchdog`.
  </action>
  <verify>
    <automated>cd /home/sti/spoton && perl -Ilib t/05_perl_syntax.t 2>&1 | tail -3</automated>
    <automated>cd /home/sti/spoton && prove -l t/ 2>&1 | tail -4</automated>
  </verify>
  <done>
    _prefetchWatchdog re-polls (2s) instead of arming the hang check when the
    player is not actually PLAYING or when elapsed exceeds duration + 30.
    Near-end arming path is otherwise unchanged. Full test suite passes.
  </done>
</task>

<task type="auto">
  <name>Task 2: Live verification — LMS restart + Browse play survives</name>
  <files></files>
  <precondition>Dev-box LMS serves Plugins/ from this repo (systemd unit lyrionmusicserver, player 52:54:00:43:d5:c2 connected) and a Spotify Premium session is authenticated in SpotOn.</precondition>
  <action>
    Reproduce the exact failure scenario from the 2026-08-31 10:12 UAT log:

    1. `sudo systemctl restart lyrionmusicserver` (NOPASSWD per dev-box
       sudoers), wait ~15s for init + Soloist daemon spawn (grep server.log
       for "ws.port announced").
    2. Start a Browse play via jsonrpc:
       `curl -s -X POST http://localhost:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["52:54:00:43:d5:c2",["playlist","play","spoton://track:5aoe582nRsthk1hpeqn36G"]]}'`
       and let it reach audio (D-17 gate resolves 'ready' after ~10s).
    3. While it is playing (~30s in), restart LMS again — this recreates the
       stale-squeezelite-play-point condition (squeezelite keeps running
       across the restart).
    4. After LMS is back, Browse-play the same track again and observe for
       60s.
    5. Assert from `/var/log/squeezeboxserver/server.log` (window since step
       4): NO "near end (elapsed=" line with elapsed > duration+30; NO
       "Prefetch watchdog: still on same track after 10s past end — forcing
       skip"; the new "implausible elapsed" warn MAY appear (that is the
       guard working).
    6. Assert via jsonrpc status that the SAME track is still playing >40s
       after newsong with a sane, monotonically advancing time value.
    7. Regression check (watchdog still functional): let a short track play
       to its natural end and confirm normal advance to the next playlist
       entry (no stuck player, no double skip).

    If step 5/6 still shows a stream break WITHOUT any forced skip, document
    it in the SUMMARY as a separate residual issue (candidate: LMS-core
    restored-PAUSED state + `_Resume`-notification unpause forward to the
    daemon at buffer-ready, seen once at 10:13:03.73) — do NOT widen this fix
    to chase it.
  </action>
  <verify>
    <automated>curl -s -X POST http://localhost:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["52:54:00:43:d5:c2",["status","-1","1","tags:adlN"]]}' | python3 -c "import sys,json;r=json.load(sys.stdin)['result'];import sys as s;print(f'mode={r[\"mode\"]} time={r.get(\"time\",0):.1f}s track={r.get(\"playlist_loop\",[{}])[0].get(\"title\",\"?\")}')"</automated>
    <automated>awk -v d="$(date +'%y-%m-%d')" 'index($0,"[" d)' /var/log/squeezeboxserver/server.log | grep -c "forcing skip" | grep -qx 0 && echo NO_FORCED_SKIP_TODAY_AFTER_FIX</automated>
  </verify>
  <done>
    Post-restart Browse playback survives >40s on the same track, time
    advances sanely, no forced skip fires, and natural track-end advance
    still works.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries
No new trust boundaries. Change consumes player-reported telemetry (STMt play
point) that was already being read; the fix REDUCES trust in that input.

## STRIDE Threat Register
| Threat ID | Category | Component | Severity | Disposition | Mitigation Plan |
|-----------|----------|-----------|----------|-------------|-----------------|
| T-quick-01 | DoS | _prefetchWatchdog 2s re-poll | low | mitigate | Timers killed on every newsong by _onNewSongWatchdog; poll cadence identical to existing not-near-end branch |
| T-quick-02 | Tampering | Player-reported elapsed (STMt) | low | mitigate | This fix: implausible values (> duration+30) are discarded instead of driving playlist jumps |
</threat_model>

<verification>
- prove -l t/ passes (t/05 perl -c covers Plugin.pm compile)
- Live: post-LMS-restart Browse play survives >40s, no "forcing skip" in log
- Live: natural track-end advance still works (watchdog not neutered)
</verification>

<success_criteria>
- The 2026-08-31 10:12 UAT scenario (LMS restart mid-session → Browse play)
  no longer produces a forced skip at newsong+20s
- Watchdog hang detection near real track end is preserved
- One file changed (Plugins/SpotOn/Plugin.pm), no behavior change on the
  normal (non-restart) playback path
</success_criteria>

<output>
Create `.planning/quick/260831-wdg-prefetch-watchdog-bogus-elapsed-guard/260831-wdg-SUMMARY.md` when done
</output>
