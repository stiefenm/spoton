# t/fixtures/soloist/ — Konvention

**Neue Konvention.** `t/` enthielt vor Phase 81 ausschließlich `NN_*.t`-Dateien; Fixtures
lagen ausnahmslos inline als JSON-String-Literale im Test (`t/32_soloist_events.t:262`) oder
als Perl-Datenstrukturen im Block (`t/20_pathfinder_parse.t:262-278`). Dateien auf Platte
sind ein bewusster Konventionsbruch: die A4-Mitschnitte aus `tools/soloist-ws-record.pl`
sind Rohdaten des echten Daemons und sollen die Test-Neufassung in Phase 82/83 überleben
(`81-CONTEXT.md` „Integration Points"), statt bei jeder Testüberarbeitung neu abgetippt zu
werden.

## Zwei Formen

1. **Einzelframe-Fixtures** (eine Datei je Frame-`type`, z. B. `auth_state.json`,
   `error.json`, `track_changed.json`): Inhalt ist **eine JSON-Zeile**, der unveränderte
   Rohtext eines WS-Frames — geht direkt als `$json_text` an `SoloistWS::_onMessage` bzw.
   an `run_fixtures()` in `t/32_soloist_events.t`.
2. **Spike-Mitschnitte** (`s01-*.jsonl`, `s03-*.jsonl`, `s04-*.jsonl`, `s07-*.jsonl`, …):
   eine zeitgeordnete Sequenz von Frames aus einem echten Spike-Lauf. Vor **jedem** Frame
   steht eine Kommentarzeile `#ts=<HH:MM:SS.mmm> epoch=<float>` (aus dem `ts`/`epoch`-Feld
   der `tools/soloist-ws-record.pl`-JSONL-Ausgabe extrahiert), gefolgt vom Rohtext des
   Frames als eigene Zeile. Kommentarzeilen beginnen mit `#` und werden von einem Loader
   übersprungen (`grep -v '^#'`).

## Herkunft, Version, Erzeugung

| Datei | Daemon-Version | Erzeugt | Erzeugungskommando |
|---|---|---|---|
| `auth_state.json` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-03 | `sudo perl tools/soloist-ws-record.pl --mac 02:00:00:5a:11:01 --expect-device lavender-UAT --seconds 6 --send get_auth_state --send get_state --send get_queue --out /tmp/spoton81/probe.jsonl` (erste `auth_state`-Zeile extrahiert) |
| `error.json` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-03 | `sudo perl tools/soloist-ws-record.pl --mac 02:00:00:5a:11:03 --send get_state --seconds 3` gegen den ungepairten `lavender-pa`-Daemon (Lesen einer Fehlermeldung — kein Playback, kein Schreibzugriff) |
| `s01-pure-daemon-play.jsonl` | soloist 1.3.7.489, Handstart (D-09) | 2026-09-03 | `runners/s01-pure-daemon.sh play 1 …` |
| `s01-pure-daemon-queue.jsonl` | soloist 1.3.7.489, Handstart (D-09) | 2026-09-03 | `runners/s01-pure-daemon.sh queue 1 …` |
| `position_sync.json` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-04 | `runners/s02-position.sh 1` (Lauf 1, unsolizitiertes Frame aus dem passiven Recorder waehrend des 30s-Einfrierfensters, `ws.jsonl`) |
| `playback_state.json` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-04 | `runners/s02-position.sh 1` (Lauf 1, `get_state`-Antwort T0, `tx-get_state-t0.jsonl`) |
| `command_result.json` | soloist 1.3.7.489, Handstart (D-09) | 2026-09-03 (S-01-Material, in 81-04/S-03 wiederverwendet) | `runners/s01-pure-daemon.sh play 3 …` (`tx-seek.jsonl`, `command=seek`) -- S-03s eigene Serie fing nie ein `command_result` ein (s. `81-SPIKES.md` Paragraph S-03: nicht im Broadcast-Set, A1-Befund) |
| `track_changed.json` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-04 | `runners/s03-seek-order.sh mismatch 30` (`ws.jsonl`, erstes `track_changed`-Frame der Serie) |
| `playback_changed.json` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-04 | `runners/s03-seek-order.sh mismatch 30` (`ws.jsonl`, erstes `playback_changed`-Frame der Serie) |
| `s03-seek-order.jsonl` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-04 | `runners/s03-seek-order.sh seek 30` (Lauf 12, `ws.jsonl` -- Laeufe 1-9 hatten wegen einer WS-Stille-Luecke keine RX-Frames, s. `81-SPIKES.md` Paragraph S-03) |
| `s03-mismatch-play.jsonl` | soloist 1.3.7.489 (build 1787637711, 20260825) | 2026-09-04 | `runners/s03-seek-order.sh mismatch 30` (Lauf 1-3, `ws.jsonl`) |
| `volume_changed.json` | soloist 1.3.7.489 (build 1787637711, 20260825), Handstart (D-09), `-i 70` | 2026-09-04 | `runners/s06-volume.sh 1 70 full` (Lauf 1, `set_volume:100`-Bestätigung, erstes `volume_changed`-Frame aus `ws.jsonl`) |
| `device_changed.json` | soloist 1.3.7.489 (build 1787637711, 20260825), CDP-Transfer `lavender-UAT` | 2026-09-04 | `runners/s04-connect-control.sh 02:00:00:5a:11:01 lavender-UAT seek 1` (Lauf 1, erstes `device_changed(is_active:true)`-Frame nach dem CDP-Transfer, `ws.jsonl`) — Lauf selbst durch einen Sicherheitsvorfall überschattet (s. `81-SPIKES.md` § S-04), diese eine Frame-Extraktion betrifft ausschließlich `lavender-UAT`s eigenen Recorder-Mitschnitt und ist davon unabhängig valide |
| `s04-connect-seek.jsonl` | soloist 1.3.7.489 (build 1787637711, 20260825), CDP-Transfer `lavender-UAT` | 2026-09-04 | `runners/s04-connect-control.sh 02:00:00:5a:11:01 lavender-UAT seek 1` (vollständiger `ws.jsonl`-Mitschnitt aus Lauf 1 — durch den in `81-SPIKES.md` § S-04 dokumentierten Sicherheitsvorfall konfundiert, technisch valide) |
| `s04-connect-skip.jsonl` | soloist 1.3.7.489 (build 1787637711, 20260825), CDP-Transfer `lavender-UAT`, getrennte Konten nach Sicherheitsvorfall | 2026-09-04 | `runners/s04-connect-control.sh 02:00:00:5a:11:01 lavender-UAT skip 1` (vollständiger `ws.jsonl`-Mitschnitt aus Skip-Lauf 1) |
| `s07-boundary.jsonl` | soloist 1.3.7.489 (build 1787637711, 20260825), CDP-Transfer `lavender-UAT` | 2026-09-04/05 | `runners/s07-boundary.sh 3 pertrack` (Lauf 3, vollständiger `ws.jsonl`-Mitschnitt — der einzige der drei Läufe mit einem echten `boundary_planted`/`boundary_reached`/`client-close: bounded EOF`-Zyklus, Grenze 2) |
| `83.1-station-no-skip-prev.json` | unbekannt (hung-state Mitschnitt) | 2026-09-21 (Archiv-Kopie 2026-09-23) | Zeile 3 (das `playback_state`-Frame) aus `/tmp/spoton83/hung-state/ws-passive.jsonl` (reboot-flüchtig), archiviert unter `/home/uuu/SynologyDrive/dev/spoton-archive/83.1/ws-passive.2026-09-21.jsonl` (sha256 `ee2b6f0ea675ebbf39d1d77930fbcafd2eaf77f2d0162347721962a7420ddee2`, außerhalb von git) — `83-MESSUNG-A.md` Abschnitt "UNIT 1: `available_actions` als Vorbedingung vor JEDEM Send"; ein echtes Stationswiedergabe-Frame (`context.uri` beginnt mit `spotify:station:`) dessen `available_actions` `skip_prev` NICHT enthält (nur `add_to_queue`, `pause`, `seek`, `seek_backward`, `seek_forward`, `skip_next`) — die D-B4-Vorbedingungsprüfung in `Control::requestSkip` (83.1-04 Task 2) refusiert `skip_prev` gegen genau dieses Frame. Das Archiv selbst bleibt außerhalb von git; nur dieses eine sekret-geprüfte Frame wurde hierher kopiert. |
| `f18n4-same1.frames` | soloist 1.3.8.105 | 2026-10-04 | UAT run `same-1` of the 84-19 F-18-N4 spike (daemon rx frames 10, 12, 15, 17-27 of the WS capture; `.frames` not `.jsonl` so t/47's real-archive glob does not take it) |
| `f18n4-bound1.frames` | soloist 1.3.8.105 | 2026-10-04 | UAT run `bound-1` of the same spike (daemon rx frames 19-22: natural advance to the stale different head; control case of the replay detector) |
| `84-2-b7-0748-leftover.frames` | not recorded in the run's meta.txt (live daemon on lavender-UAT, 2026-10-09) | 2026-10-09 | `spoton-messdaten/84-26-b7-run-261009-074810/ws.jsonl` lines 9, 11, 26, 28, 31 (inner `frame` text via python `json.loads`): B7 07:48 Africa echo, queue_changed q1 6d0c, the leftover 6d0c's track_changed and its two playback_state frames -- the 84.2-01 CAUSE-3 replay |
| `84-2-off1-context-end.frames` | not recorded in the run directory (84-19 autoplay spike, 2026-10-04) | 2026-10-04 | `spoton-messdaten/84-19-spike-autoplay-261004/off-1/ws.jsonl` lines 15-21 (inner `frame` text via python `json.loads`): resume at 194143 ms, then the Browse context end at 09:18:11.943 under Autoplay OFF -- the 84.2-02 D-15 MUST-fire case |
| `84-2-run7-context-end.frames` | not recorded (84-04 C5 Connect recording) | 2026-10-09 | `spoton-messdaten/84-04-c5/run7/ws-all.jsonl` lines 20-27: reconnect snapshot 239075, buffering 314298, context end 08:37:43.621 -- fires in browse, plants nothing in connect (84.2-02 D-15/D-16) |
| `84-2-b7-0748-midtitle-pause.frames` | not recorded in the run's meta.txt (live daemon on lavender-UAT) | 2026-10-09 | `spoton-messdaten/84-26-b7-run-261009-074810/ws.jsonl` lines 42-46: 552l paused at 24738 ms, no reset -- 84.2-02 D-15 negative |
| `84-2-b7-0748-seek.frames` | not recorded in the run's meta.txt (live daemon on lavender-UAT) | 2026-10-09 | same ws.jsonl lines 18-22: Africa seek to 275000 ms, playing 275001 -- 84.2-02 D-15 negative |
| `84-2-b7-0748-late-pick.frames` | not recorded in the run's meta.txt (live daemon on lavender-UAT) | 2026-10-09 | same ws.jsonl lines 23-29: Africa paused at 292333, then 6d0c starts at 0 -- 84.2-02 D-15 negative through the anchor's uri tag |
| `s85-get-queue-reply.jsonl` | soloist 1.3.8.105 build 1790942580 (20261002) | 2026-10-16 | `sudo -n perl tools/soloist-ws-record.pl --mac 02:00:00:5a:11:03 --send get_queue --seconds 5 --out <tmp>` auf `lavender-pa` (pausiert, Lauf 85-03 Task 4): echte `get_queue`-Antwort, Frame-Typ `queue_changed` mit `previous`=3 und `upcoming`=10 (Short-Form sendet `limit` 10); Zweck: Eingabe fuer den D-09-Mapper (85-07), RESEARCH A7. Kein Benutzername, keine Account-ID, kein Schluessel (Redaktions-Grep 0). |

Künftige Dateien tragen dieselben drei Angaben (Version, Datum, Kommando) als neue
Tabellenzeile hier.

## Bekannter Fehler in einem Mitschnitt (81-REVIEW.md CR-01)

`s01-pure-daemon-play.jsonl:42` enthält den Künstlernamen "Janelle Monáe" fehlerhaft als
`"Janelle MonÃ¡e"` gespeichert (Feld `creators[].entity.decorations.identity.name` im
`queue_changed`-Frame, `upcoming`-Eintrag für "Make Me Feel").

**Ursache:** `tools/soloist-ws-record.pl`s `jsonl_line()` doppelt-UTF-8-kodierte
Nicht-ASCII-Frametext vor dem 81-REVIEW.md-CR-01-Fix (behoben in der Commit-Historie dieser
Phase, siehe `git log --grep=CR-01`). Diese Datei wurde mit der defekten Tool-Version
mitgeschnitten (`runners/s01-pure-daemon.sh play 1 …`, 2026-09-03, soloist 1.3.7.489
Handstart/D-09 — siehe Tabellenzeile oben).

**Diese Datei wird absichtlich NICHT repariert oder neu erzeugt.** Sie ist ein
Mitschnitt-Artefakt eines echten Laufs und belegt Task 2/dieses Reviews Architekturentscheidungen;
ein still korrigierter Mitschnitt wäre kein Beleg mehr. Das betroffene Feld ist ein
Anzeigename (Metadaten-String für UI-Darstellung), keine Messgröße — die
Zeitstempel/Sequenz-/Frame-Typ-Daten, auf denen die S-01-Befunde beruhen, sind von diesem
Fehler nicht betroffen.

Neue Mitschnitte (mit dem gefixten Tool erzeugt) haben diesen Fehler nicht mehr.

## Redaktionsregel (T-81-06)

Keine Datei in diesem Verzeichnis darf den Soloist-App-Key (`spoton/soloist/spak.key`,
Präfix `sp` + `ak_`) oder Session-Payload-Felder (Feldname `auth` + `_data`) enthalten.
Vorbild: `t/13_status_page.t:612-615` („serialized status payload never leaks the fixture
credential value"). Jede Datei, die aus einem Live-Mitschnitt entsteht, läuft vor dem
Commit durch einen Redaktions-Grep auf die beiden oben genannten Muster — muss `0`
Treffer liefern (siehe `81-SPIKES.md` Verify-Gate, T-81-06).
