# t/fixtures/uat/ — Konvention

Real archive excerpts used to prove `tools/uat/extract-run.pl`'s categories
both fail (BEFORE-state) and pass (AFTER-state) against genuine log
material, not a hand-written synthetic that could accidentally match its
own implementation's assumptions (memory
`trockenlauf-synthetisch-belegt-nur-die-formel`).

## `83.1-messung-c-connect-guard.log`

**Source:** `/home/uuu/SynologyDrive/dev/spoton-archive/83.1/server.log.2026-09-22.gz` (owned
by `uuu`, no sudo needed) — the orchestrator's 2026-09-23 sha256-verified
copy of the nightly-rotated `/var/log/squeezeboxserver/server.log.1.gz`
(original rotation time `00:05:43`, that name no longer exists in
`/var/log/squeezeboxserver/` — memory `serverlog-rotiert-um-mitternacht`).

**sha256 of the source archive (verified before excerpting):**
`f10a3f98abfc40a045b897eedcd75a2075c9335298906736e1fc66e801e363b6`

**Player:** `02:00:00:5a:11:01` (lavender-UAT). MACs are not secrets.

**Extraction:** byte-exact `awk` selection on the `[26-09-22 HH:MM:SS.mmmm]`
prefix (no re-encoding — server.log stores the em dash in
`Resume while not on Connect stream — ...` double-encoded as the six-byte
sequence `c3 a2 c2 80 c2 94`; the excerpt preserves those bytes literally).

**Two windows, both from Messung-C night 2026-09-22** (`83-MESSUNG-C.md`
lines 753-790):

1. **Healthy boundary** — `12:52:26.790`–`12:52:26.815` (153 lines).
   Contains one `Dropping Connect change event` drop, one
   `Dropping Connect seek event` drop, one
   `Resume while not on Connect stream` re-entry, the resulting
   `playlistXitemCommand`, and the `ProtocolHandler::getNextTrack (718)`
   dispatch line — the BEFORE-code advance mechanism (change dropped,
   rescued a fraction of a second later by `resume`).
2. **Failed boundary** — `12:25:19.000`–`12:25:32.000` (104 lines).
   Contains one `Dropping Connect change event` drop, two
   `Dropping Connect seek event` drops, and — 11.6s later — the
   `Prefetch watchdog: still on same track after 10s past end` line
   (Runde 1). No `resume`/`Resume while not on Connect stream` line and
   no `Track change:` line appear in this window: the boundary hung.

**Combined fixture:** 257 lines total (well under the 400-line cap), 0
`Track change:` lines (this is deliberately a BEFORE-code archive: the
connect-guard-passes-and-dispatches mechanism this plan adds categories for
did not exist yet on 2026-09-22), no `spak_`/`auth_data`/`Bearer ` literal
(verified via `command grep`).

**Why both windows in one file:** Task 1's archive subtest
(`extract-run-connect-advance-archive`) needs both signatures in a single
run to assert the BEFORE-state pattern (`Anzahl` >= 2 change-drops, >= 1
resume re-entry, 0 `Track change:`) over one `extract-run.pl` invocation,
matching the idiom of the existing `extract-run-watchdog`/
`extract-run-nextifmore` subtests in `t/46_uat_tools.t`.

## `84.1-05-extract-forced-skip-real.txt`, `84-03-extract-rapid-skip-final-build-clean.txt`, `84-14-extract-headers-only-clean.txt`

Whole `extract-run.pl` outputs (no secrets), used by the `rapid-skip.sh
selftest` cases for the B8 gate (84-17 repair). The first holds ONE real
`Control: watchdog forced skip on <mac>` server.log line (MUST-FAIL, 1 real
hit); the other two carry the phrase only in the extract's own
`--- server.log: ... ---` category header and the
`[MUSTER NICHT GEFUNDEN IM FENSTER]` marker (MUST-PASS; the old gate counted
those 2 hits and failed the saved final-build run). Sources:
`spoton-messdaten/84.1-05-series-260928-2100/lavender-UAT/extract-A3-postfix-260929.txt`,
`spoton-messdaten/84-03-rapid-skip-261001-1354/extract.txt`,
`spoton-messdaten/84-14-entry-260930-134800-empty/extract-l2-empty.txt`.
No archived server.log extract holds a real `PROBLEM_OPENING` line; that
MUST-FAIL case is synthetic in the real Control.pm log format.

## 84-04 fixtures (instrument repairs before the first acceptance)

All REAL, masked with l2-proof's `mask` (account-key prefixes and bearer tokens replaced; none were present), MACs kept.

- `84-04-server-remote-stream-stopped.log` -- the three archived server.log lines 8911 / 105966 / 108837 of
  `spoton-messdaten/84-04-archive/server-261001-full-1601.log` (sha256 prefix `47ba8af92c672ea2`) with two
  preceding context lines each: LMS' `Stopping remote stream upon full buffer when paused` (StreamingController
  437). Used by the t/46 subtest `extract-run-remote-stream-stopped` (new extract-run.pl category; MUST-FAIL half
  on a throwaway copy without the entry).
- `84-01-daemon-window-hold-uat.txt`, `84-01-l1-status-hold-uat.txt` -- copies of the UAT hold-build Connect run
  `84-01-attrib-261001-134104-empty/lavender-UAT/{daemon-window.txt,L1-status.txt}`: one natural close
  (`bounded EOF at track boundary`) covered by the status series, the takeover at the session start uncovered.
  Input of `runners/_x4_prefetch_derive.py selftest` case 1 (`no`).
- `84-04-daemon-window-rapid-skip-browse.txt` -- the daemon window of the Browse rapid-skip storm 2026-10-01
  13:54:30-13:55:05 on lavender-UAT (`DAEMON_TAIL_N=0 cluster2-series.sh attrib daemon-window 02:00:00:5a:11:01
  <epoch> <epoch> <file>`, epoch-filtered by the window day): one write-error close at 13:54:36.250 and seven
  takeover closes 13:54:48.156 .. 13:54:57.242, each followed by an attach in the same millisecond.
- `84-04-status-series-rapid-skip-post-storm.txt` -- copy of `spoton-messdaten/84-03-rapid-skip-261001-1354/status-series.txt`
  (`epoch mode time url`, 1 Hz, starts 13:54:58 -- AFTER the storm, so the real pair reads `no_overlap`). With a
  SYNTHETIC continuous series the same window reads `yes` (7 covered takeovers), with a synthetic skip series `no`.
- `84-01-extract-hold-build-uat.txt`, `84-01-ws-hold-build-uat.jsonl` -- the extract-run.pl output of the same UAT
  hold run (`Track change ... via=live`, `Connect: hold opened` / `closed by newsong`, 0 `Connect change verworfen`)
  and its recorder frames from the connect to 10 s after the track_changed. Input of
  `e-advance-mechanism.sh selftest` cases 4 (`change_direct`) and 5 (the Track change category emptied: never PASS).
- `84-04-c1-row-output-entry-pass.txt` -- the REAL output of the first live acceptance C1 row (2026-10-01 19:10,
  `l2-proof.sh run empty --prior same`, run dir `spoton-messdaten/84-14-entry-261001-191053-empty`): ENTRY_GATE=PASS,
  L2_GATE=PASS, SETUP=OK next to the transfer runner's literal `GATE_TRANSFER_IN=UNBESTIMMT` and its mirror
  `GATE_TRANSFER_IN_RUNNER=UNBESTIMMT`. `acceptance-x86.sh selftest` `derive_real_c1_row_runner_mirror_superseded`
  (PASS; the old exact-key supersession read UNBESTIMMT) and the doctored ENTRY_GATE=FAIL copy (FAIL).
- `84-04-row-output-R1-health-pass.txt`, `84-04-row-output-R2-result-fail.txt`, `84-04-row-output-R4-result-fail.txt`,
  `84-04-row-output-R6-result-pass.txt` -- the REAL row outputs of the first live all-uat (2026-10-01 20:23-20:31):
  cluster3 (R1/R2), gap-15 (R4) and gap-18 (R6) end with `RESULT: PASS|FAIL <reasons>` and no GATE_ line, and cluster3's
  dryrun echoes its MUST-FAIL half as `PA_GATE_DIFF_RAW=FAIL`. The old derive read R1 FAIL (the raw echo), R4/R6
  UNBESTIMMT (no verdict line); `acceptance-x86.sh selftest` pins R1 PASS, R2 FAIL (`T_DETECT_DELTA=17 out of range`),
  R4 FAIL (`exit10_lines=0 renewal_not_immediate`), R6 PASS, plus doctored copies.
- `84-04-status-errors-claim-conflict-real.json` -- the `errors` array of the REAL `plugins/SpotOn/status/data` snapshot
  `spoton-messdaten/84-03-acceptance-x86-261001-1706/inline-c11-status-data.json` (one `claim-conflict` warning, `ts`
  1790867249 = 2026-10-01 17:07:29, created by the H2 app-skip run). B8's 19:59 storm (`RUN_T0` 1790877574.787) saw
  it and read `errors_entry_for_mac n=1`. Input of `rapid-skip.sh selftest` (`errors_entry_before_storm_ignored` 0,
  `errors_entry_inside_run_window_counted` 1) via a `file://` `STATUS_DATA_URL`; run by the t/46 subtest `84-19 runner selftests`.
- `84-19-soloist-renew-status-both-daemons.json` -- the REAL `plugins/SpotOn/settings/soloistRenewStatus` JSON read from the
  running LMS on 2026-10-03 (lavender-UAT pid 172132 and lavender-pa pid 106397 both `alive: 1`). Input of
  `gap-15-exit10-live.sh selftest` (`quiet_both_listed_stable_30s` QUIET, `arm_recheck_*`); its MUST-FAIL counterpart is the
  REAL `status-before.json` of the first live R4 run (`spoton-messdaten/84-03-gap15-261001-2025`, UAT only -- the pa daemon came up
  after the arm), which the t/46 subtest `84-19 runner selftests` reads from the measurement archive when present.
- `84-04-volume-ws-idle-player-real.jsonl` -- the REAL recorder file `spoton-messdaten/84-03-volume-261001-1958/ws.jsonl` of the first
  live B5 run (3 frames: handshake, auth_state, one `playback_state` `paused` carrying a volume; the player was idle, `CONTROL_MODE=idle`,
  `T_CMD_A=1790877529.940255713`, `T_CMD_B=1790877535.019100356`). Input of `volume.sh selftest`: with the precondition (a playing title)
  met the gate still reads FAIL (MUST-FAIL), with it missing it reads UNBESTIMMT, never FAIL.
- `84-20-c5-newso-status-series-lms-time-transient.txt` -- the REAL C5 `status-series.txt` of the first 84-20 run on the new
  `.so` (`spoton-messdaten/84-04-c5/run2`, 2026-10-05 10:43-10:48; `epoch mode time url`, 52 samples). At the natural title change the
  FIRST LMS `time` sample of the new url reads `199.95` (the previous title's end time), the next ones 5.36, 10.51 ... rise normally.
  The old `_stall_verdict` took 199.95 as its baseline and read STALL after 61.7 s (false `strom_tot`). Input of
  `e-advance-mechanism.sh selftest` (baseline rule `BASELINE_GRACE_S = 2.0`): MUST read OK; two doctored copies (time frozen after
  the transient / frozen at the transient value, extended by 8 samples) MUST read STALL.
- `84-04-c5-head-status-series.txt` -- the REAL C5 `status-series.txt` of the 84-04 HEAD run (`spoton-messdaten/84-04-c5/run1`,
  2026-10-01, 416 samples, 9 healthy title changes, first samples 0.57-3.79 s). MUST read OK under the new rule; a copy frozen
  after its first boundary MUST STALL.

## `84.3-c5-run13-server-race.log`

**Source:** `/home/uuu/SynologyDrive/dev/spoton-archive/84.3/server.log.2026-10-13.gz` -- copied 2026-10-15T07:08:13Z by plan 84.3-01 from
`/var/log/squeezeboxserver/server.log.1.gz` (that name no longer holds this generation after the next rotation; memory
`serverlog-rotiert-um-mitternacht`), recorded in `PROVENANCE.txt` of the archive.
First line `[26-10-13 00:21:30.0329]`. sha256 (verified before cutting):
`6ecd74d2b8ef0280508ac209a73b8ba550832a8a6787fa883109bdcff661ed9e`.

**Player:** `02:00:00:5a:11:01` (lavender-UAT). **Extraction (byte-exact):**
`zcat server.log.2026-10-13.gz | sed -n '35073,35110p'` (38 lines, 01:14:41.0023-01:14:41.7304).

**Proves:** the C5 run13 race -- `OutputUnderrun in PLAYING-STREAMING -> _Rebuffer`, `Pause in BUFFERING-STREAMING -> _NoOp` (LMS discarded
the pause while rebuffering) and three real `Buffering... 3896 / 81920` lines. The t/46 subtest `extract-run-84.3-settle` inserts two fabricated
lines (one settle warn, one check info, built from the Connect.pm format strings) into a COPY of this file and says `doctored` in its assertion
names; the file itself is unchanged.

## `84.3-c5-run8-server-pause-won.log`

**Source:** `/home/uuu/SynologyDrive/dev/spoton-archive/84.3/server.log.2026-10-09.gz` -- copied 2026-10-15T07:08:13Z by plan 84.3-01 from
`/var/log/squeezeboxserver/server.log.3.gz`, recorded in `PROVENANCE.txt`. First line `[26-10-09 07:08:06.6069]`. sha256 (verified before cutting):
`3f2195fc77d16de2b2874cbe8baffbac302c1ceace4fe650bcf03461a2b2356c`.

**Player:** `02:00:00:5a:11:01`. **Extraction (byte-exact):** `zcat server.log.2026-10-09.gz | sed -n '93720,93760p'` (41 lines,
21:09:27.9895-...).

**Proves:** the C5 run8 pause-won case -- `Pause in PLAYING-STREAMING -> _Pause` (the pause took effect), then
`OutputUnderrun in PAUSED-STREAMING -> _NoOp`; zero `Buffering...` lines. Used unchanged (`real` in the t/46 assertion names).

## `84.3-c5-run13-extract-recut.txt`, `84.3-c5-run8-extract-recut.txt`

Whole `extract-run.pl` outputs of the C5 runs 13 (race) and 8 (pause won), re-cut through the 84.3-03 extractor (four new @SRV_CATS entries:
context-end settle, context-end check, LMS pause/underrun state rows, LMS buffering progress). Input of the per-run digest selftest of plan 84.3-05
(server.log sections only; the daemon log was an EMPTY scratch file, so no daemon content is in git). Sources: the archived, sha256-verified
`server.log.2026-10-13.gz` (first line `[26-10-13 00:21:30.0329]`, sha256 `6ecd74d2b8ef0280508ac209a73b8ba550832a8a6787fa883109bdcff661ed9e`) and
`server.log.2026-10-09.gz` (first line `[26-10-09 07:08:06.6069]`, sha256 `3f2195fc77d16de2b2874cbe8baffbac302c1ceace4fe650bcf03461a2b2356c`) under
`/home/uuu/SynologyDrive/dev/spoton-archive/84.3/`, `zcat`-ed to a scratch file; recorders `spoton-messdaten/84-04-c5/run13/ws-all.jsonl` and
`.../run8/ws-all.jsonl`. The `Quelle ...` header lines name the scratch paths of the cutting session.

- run13: `perl tools/uat/extract-run.pl 02:00:00:5a:11:01 01:13:13.65962800 01:15:52.990948406 --server-log <zcat of server.log.2026-10-13.gz> --daemon-log <empty file> --recorder .../run13/ws-all.jsonl --date 2026-10-13 > 84.3-c5-run13-extract-recut.txt`.
  State rows: `OutputUnderrun in PLAYING-STREAMING -> _Rebuffer`, `Pause in BUFFERING-STREAMING -> _NoOp`; buffering section: 104 lines, 103 `/ 81920`; no settle
  line (none existed then).
- run8: same with `21:08:01.611665700 21:09:39.754740787`, the zcat of `server.log.2026-10-09.gz`, `.../run8/ws-all.jsonl`, `--date 2026-10-09`, into
  `84.3-c5-run8-extract-recut.txt`. State rows: `Pause in PLAYING-STREAMING -> _Pause`, `OutputUnderrun in PAUSED-STREAMING -> _NoOp`; buffering section: the one
  `Buffering... 0 / 20480` line.

## `84.3-c5-run13-status-series.txt`, `84.3-c5-run13-ws-all.jsonl`, `84.3-c5-run13-extract.txt`

Byte copies of `/home/uuu/SynologyDrive/dev/spoton-messdaten/84-04-c5/run13/{status-series.txt,ws-all.jsonl,extract.txt}` -- the C5 run13 (Autoplay OFF, 2026-10-13
01:13:23, `VERIFY_TS_EPOCH=1791846803.065962682`, lavender-UAT): 25 rising `play` rows to 200.872 s on `spoton://track:5oiTnaEHK3OFDZIL8AIYwu` (duration 201.000 /
201.142 s), then 14 `play 0` rows (the race: LMS discarded the pause while rebuffering, no settle guard existed yet), `STALL_ABORT=ja`. The extract predates the
84.3 categories (no settle section). Used by `e-advance-mechanism.sh selftest`, block `84.3` (plan 84.3-04): as-is (`asis`) it must stay `FAIL_unbestimmt`; the
doctored derivatives (`doctored` in the case name; built in `$OUT_BASE/selftest-84-3`, never committed) turn the `play 0` rows into `stop 0` rows and append one
fabricated settle category section. The selftest asserts each file with `cmp -s` against the archive when the archive is present. PII/secret ERE count 0 per file.

## `84.3-c5-run18-status-series.txt`, `84.3-c5-run18-ws-all.jsonl`, `84.3-c5-run18-extract.txt`

Byte copies of `/home/uuu/SynologyDrive/dev/spoton-messdaten/84-04-c5/run18/{status-series.txt,ws-all.jsonl,extract.txt}` -- the C5 ON-round run18 (Autoplay ON,
2026-10-15 22:00, `VERIFY_TS_EPOCH=1792094404.032420411`, lavender-UAT): 10 `track_changed` frames after VERIFY_TS, of which the FIRST (22:00:12.092, 8.1 s after
VERIFY_TS) is the session-start frame of the app Play (it announces `spotify:track:5oiTnaEHK3OFDZIL8AIYwu`, the title the recorder already holds from the
`playback_state` at 21:59:52) and 9 are real advances; the extract holds 9 `Track change (Connect` lines, 0 guard drops, 0 `context-end` lines. The live gate read
`N_BOUNDARIES=10 / N_TRACK_CHANGE=9 -> MECHANISM=mixed` (boundary miscount, 84.3 deviation fix); the repaired gate reads `N_BOUNDARIES=9 -> change_direct`. Used by
`e-advance-mechanism.sh selftest`, block `84.3-gate` (cases `run18_real_on_session_start_after_verify_ts` MUST-PASS, `run18_doctored_extra_advance` and
`run18_doctored_start_frame_other_title` MUST-FAIL; the doctored derivatives are built in `$OUT_BASE/selftest-84-3`, never committed). The selftest asserts each file
with `cmp -s` against the archive when the archive is present. PII/secret ERE count 0 per file.

## `84.3-c5-hit1-status-series.txt`, `84.3-c5-hit1-ws-all.jsonl`, `84.3-c5-hit1-extract.txt`

Byte copies of `/home/uuu/SynologyDrive/dev/spoton-messdaten/84-04-c5/run14/{status-series.txt,ws-all.jsonl,extract.txt}` -- the FIRST real guard hit of the 84.3 OFF round
(run14, Autoplay OFF, 2026-10-15 21:23, `VERIFY_TS_EPOCH=1792092209.750674373`, lavender-UAT, tree `6185a9e82a537a8b07be07f85aa2e60ef81126d3`): the pause at the context end
met a rebuffering LMS, the guard settled it (`context-end settle ... via=immediate`, delay 0.001 s, server.log 21:26:51), the status series ends in a 3-sample `stop 0`
plateau after 40 rising `play` rows (last 198.250 s of 201.000 s). Ledger row: `84.3-c5-261015-2117/ledger.tsv` n=1, `hit=yes`. The extract carries the 84.3 categories
(`context-end settle`, `context-end check`). Used by `e-advance-mechanism.sh selftest`, block `84.3` (plan 84.3-08): case `real_hit1_off` is the REAL MUST-PASS input
(`MECHANISM=context_end_settled_stop`, `GATE_ADVANCE=PASS`, `N_SETTLE=1`, `END_REACHED_STOP=yes`), case `real_hit1_on` (same files under Autoplay ON) the MUST-FAIL twin
(`GATE_ADVANCE=FAIL_unbestimmt`). Nothing is doctored; the selftest asserts each file with `cmp -s` against the archive when the archive is present. PII/secret ERE count 0
per file. Limit: this is one race shape (via=immediate); the 1.5 s grace branch has no real material.

## `85-03-server-webapi-prephase.log`

Real `server.log` window of the D-25 runtime MUST-FAIL run (plan 85-03, Task 1): 2026-10-16, rig lavender-pa (`02:00:00:5a:11:03`), plugin tree `39905172` (pre-phase,
every Web-API caller still live), LMS restarted 19:09:51 (the log therefore starts at the restart), `tools/uat/menu-walk.pl --arm-webapi-log --depth 3 --search "Miles Davis"`
armed at 19:10:22.779 and ended 19:11:34 (157 menus, 0 unanswered). Window under test: T0 19:10:23 / T1 19:11:35. Cut: the timestamped `server.log` lines from the first walk
request (19:10:22.9084) to the last (19:11:34.1890), 6140 lines. Purpose: the real MUST-FAIL input of the D-25 runtime verdict (`tools/uat/webapi-gate.pl`): `extract-run.pl
02:00:00:5a:11:01 19:10:23 19:11:35 --server-log <this file> --date 2026-10-16` yields 138 lines in the `Web API request (api.spotify.com` category (82 `/v1/search`, 4
`/v1/me/playlists`, 2 `/v1/me/shows`, 2 `/v1/me/player/queue`, the rest `Connecting to`/status lines) and the gate answers `WEBAPI_GATE=FAIL ... reason=webapi_requests`
(subtest `webapi-gate-85-03-real` in `t/soloist/46_uat_tools.t`). Nothing is added or doctored. Two redactions, both from the cut itself: the unprefixed continuation lines
(request/response headers, which at `network.asynchttp=DEBUG` carry the full `Authorization: Bearer` token, the `Cookie:` line and a Perl dump of response headers) are dropped,
and the Spotify user id (the account username) in the six `playlist/v2/user/<id>/rootlist` request lines is masked as `xxxx****`. The account directory name does not occur.
`command grep -c` of the clear username, the clear account dir name, `@` and `Bearer <token>` is 0. The unredacted window stays on the rig (server.log of the restart at
19:09:51) and is not archived; the walk and the extract of the run are in `/home/uuu/SynologyDrive/dev/spoton-messdaten/85-03-prephase-261016-1909/`.
Limit: the walk skips nodes of `type=playlist` (Home -> Recently Played `0.0` and Top Tracks `0.3`, `isaudio=1`), so `me/top/tracks` and `me/player/recently-played` are not
in this window; Up Next (`/v1/me/player/queue`), Search -> Neue Suche (`/v1/search`) and the Library nodes (`/v1/me/playlists`, `/v1/me/shows`) are.

## `r2-connect-seek.log`

The real recorder frames of the 79-47 Task 4 R2 re-run attempt 3 (`R2_3`, 2026-10-26 18:00:36 .. 18:01:18, lavender-UAT, a Connect session, an app seek via the CDP tool at 18:01:10.5):
`/home/uuu/SynologyDrive/dev/spoton-messdaten/79-47-shim/task4/run-261026-175021/R2_3.ws.jsonl` (15 lines), redacted in the form of the `d34-*.log` fixtures: one meta line
(`R2 CASE R2_3 (79-47 Task 4, redacted: rx frames only, decorations removed)`, so `d34_case($file, 'R2_3')` in `t/soloist/44_soloist_control.t` finds the case), rx frames only, and
`item.decorations` / `context.decorations` (names, cover URLs, creators, durations) removed. The file lines are the lines of the source file (the meta line takes the place of the
HANDSHAKE line): 3 `playback_state paused`, 4-6 the app play at 18:00:53.561 (position 100094), 7-9 the app seek's first frames at 18:01:11.516 (`playback_changed buffering`, then
`playback_state buffering` on the SAME title `spotify:track:2374M0fQpWi3dLnB54qaLX` at the SAME position 100094, no `track_changed`), 10-12 the playing frames at 18:01:11.616, 13-15 the
defect's own `paused` trio at 18:01:18.011 (LMS stopped 6.5 s after the daemon's flush closed its stream). Used by `D-34 R2-S1:` in `t/soloist/44_soloist_control.t` (lines 3-12 only:
the paused trio is excluded) to pin that Control posts exactly one `POST /seek-keep` at the line-8 frame. Limit: the position is 100094 before AND after the seek (no `position_sync`
in between), so Control's frozen-position guard returns before `_detectSeek` and the live `seek_from_binary` of 18:01:11.5169 cannot be reproduced from these frames; the test asserts
only the keep. Nothing is added or doctored. PII/secret ERE (`@`, `Bearer`, `https?://`, `scdn`, `cover`) count 0; the one `device_name` is the rig player's name `lavender-UAT`.

## `runaway-album-start.log`

Real recorder frames of five start shapes, the evidence of plan 79-51 (album-start runaway, .planning/debug/album-start-connect-runaway.md), redacted in the form of the `d34-*.log`
fixtures (one meta line `R51 CASE <NAME> (<source> lines <a>-<b>, ...)` per case, so `d34_case($file, '<NAME>')` in `t/soloist/44_soloist_control.t` finds it; rx frames only;
`decorations` objects removed at every depth). Sources below `/home/uuu/SynologyDrive/dev/spoton-messdaten/`; the cut is the source line range:
- `RUNAWAY` = `79-49-d34/run-261027-094204/connect_skip-single.ws.jsonl` lines 3-44 (E1): paused Redbone T1 at 95802 ms, then at 09:42:24.913 `playing`, `context_changed` album, an item-less
  `playback_state` and `position_sync` in one millisecond, the album's first title 136 ms later, then the Spotify app's own four skips, each followed by SpotOn-caused `paused` triplets.
- `PASS1` = `79-49-d34/run-261027-092233/connect_skip-single.ws.jsonl` lines 3-16 (E2, E10): the same frame form at position 0; line 13 is a speed-0 `position_sync`, line 14 a second `playing`.
- `RESUME` = `79-49-d34/run-261027-092326/connect_lmsseek-single.ws.jsonl` lines 3-6 (E3): a plain Connect resume, the deciding `playback_state` in the same millisecond.
- `TRANSFER` = `79-50-r2/run-261026-230636/R2.ws.jsonl` lines 3-14 (E8): transfer-in, `device_changed`, `playing`, item-less `playback_state`, same-uri `track_changed` 76 ms later, no `context_changed`.
- `TRACKFIRST` = `84-17-hold-261001-110502-L1-empty/lavender-UAT/ws.jsonl` lines 3-9 (E9): `track_changed` before `playing`; its `playback_state` frames carry `is_active` false.
Used by `79-51 D1-R1..R9:` in `t/soloist/44_soloist_control.t`. Nothing is added or doctored (a test that doctors a frame says so and works on its own copy). The fixture has 84 lines (5 meta, 79 frames).
PII/secret ERE of the `r2-connect-seek.log` section above: count 0 on the fixture; the one `device_name` is the rig player's name `lavender-UAT`.

## `album-start-deadline.log`

Real recorder frames of eight start shapes, the evidence of plan 79-52 (album-start deadline stop, .planning/debug/album-start-deadline-stop.md), redacted in the form of the `d34-*.log`
fixtures (one meta line `R52 CASE <NAME> (<source> lines <a>-<b>, ...)` per case, so `d34_case($file, '<NAME>')` in `t/soloist/44_soloist_control.t` finds it; rx frames only; `decorations`
objects removed at every depth). Sources below `spoton-messdaten/` (the archive next to the repository); line 1 of every source is the HANDSHAKE meta line and line 2 the `auth_state`
frame, the cut starts at line 3 (the session seed comes from the test, the `auth_state` frame is not fed):
- `V3_SAME` = `79-45-d34/run-261028-123930/album_start-single.ws.jsonl` lines 3-18: the app's `play-uri` of a bare track on a session that already sits (paused) on that title. The daemon's
  first load reaches `buffering` (12:39:52.418), then the second `prepare play` lands while it is still corked: only `context_changed` (album) and `queue_changed` (12:39:52.723), then
  `playback_state playing` of the SAME title at position 1 ms (12:39:53.030). Variant V3 (lines 19-21, the `paused` triplet SpotOn itself caused after the shim closed LMS's stream, are excluded).
- `V3_CHANGE` = `debug-album-start-deadline-stop/run-261028-130219/album_start-single.ws.jsonl` lines 3-18: the same sequence on a session paused on ANOTHER title (Rosanna), so the first
  `track_changed` is a title change with its pending 84-17 change (the shim's `departed` reply at 13:02:40.956 clears it before the album `context_changed` at 13:02:41.223).
- `V1` = `debug-album-start-deadline-stop/run-261028-130103/album_start-single.ws.jsonl` lines 3-42; `V1B` = `79-45-d34-attempt5/run-261028-112204/album_start-single.ws.jsonl` lines 3-44: the first load
  reached `playing` before the second command; a flush, `buffering`, `playing`: the keep at the `buffering` frame.
- `V2` = `79-45-d34/run-261028-123720/album_start-single.ws.jsonl` lines 3-44: the second command 197 ms after `buffering`; a transient `playing` with an empty item, `track_changed`, `buffering`, `playing`.
- `V0` = `debug-album-start-deadline-stop/run-261028-125939/album_start-single.ws.jsonl` lines 3-44: no album context at all (one flush).
- `SKIP` = `79-45-d34/run-261028-123157/connect_skip-single.ws.jsonl` lines 3-30: an app skip (`track_changed` first; its /boundary decides, no keep).
- `CSEEK` = `79-45-d34/run-261028-123100/connect_seek-single.ws.jsonl` lines 3-13: an app seek on the unchanged title (one keep at its `buffering` frame).
Used by `79-52 G1-` in `t/soloist/44_soloist_control.t`: the two V3 cases must post their keep at the `playing` frame after the album `context_changed` (HEAD before 79-52: 1 and 0 keeps in all,
the fix: 2 and 1), the six negatives must post exactly the keeps and drains the code posted before (V1 2/2, V1B 2/2, V2 2/2, V0 3/1, SKIP 0/2, CSEEK 1/0). Nothing is added or doctored
(a test that doctors a frame says so and works on its own copy). The fixture has 245 lines (8 meta, 237 frames).
PII/secret ERE of the `r2-connect-seek.log` section above: count 0 on the fixture; no home path occurs in the fixture or here.
