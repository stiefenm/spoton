# t/fixtures/seek-live-fix/ — echte Seek-Läufe für den Runner-Selbsttest

Eingaben für `seek-restart-built.sh selftest` (Phase 83.1, Runner
`.planning/phases/83.1-soloist-control-connect-umbau-und-policy/runners/`).
Kein `prove`-Test liest diese Dateien.

**Herkunft:** stille Live-Serie auf `lavender-UAT` (`02:00:00:5a:11:01`,
streamingMode=proxy, streamFormat=pcm) vom 2026-09-24, 08:56–09:12 Ortszeit,
NACH Fix `0cb0837` (Debug-Sitzung `connect-seek-stoppt-wiedergabe`), gefahren
mit der damaligen Runner-Kopie (`scratchpad/runner-fix.sh`, Stand `2c572f2`,
MAC/NAME/OUT_BASE auf lavender-UAT umgestellt). Kein Hörbefund, kein Nutzerzitat.
`uat-dry` (für `arm-keine/extract.txt`) ist der stille Trockenlauf derselben
Sitzung um 07:04, VOR dem Fix.

## Dateien je Lauf

| Datei | Inhalt | verändert? |
|---|---|---|
| `ws.jsonl[.gz]` | Recorder-Mitschnitt `tools/soloist-ws-record.pl`, 60 s ab T_SEND−3 s | nein (nur gzip -9n, wenn > 50 KB) |
| `status-series.txt` | LMS-`status`-Abfragen alle ~0,57 s, 20 s ab T_SEND (`EPOCH MODE TIME`) | nein |
| `extract.txt[.gz]` | `tools/uat/extract-run.pl`-Ausgabe des Laufs (server.log-Zeilen des Fensters wörtlich) | nein (run4: gzip) |
| `run-meta.txt` | `meta.txt` des ALTEN Runners — nur `T_SEND_EPOCH`/`SEEK_TARGET_S` werden gelesen; die alten Urteile darin sind historisch (run4/run5 „FAIL_POSITION" war der Erstframe-Fehlgriff) | nein |
| `daemon-window.log` | Daemon-Log-Ausschnitt des Laufs, siehe unten | **gefiltert** |

`daemon-window.log` wurde aus `/var/lib/squeezeboxserver/cache/spoton/0200005a1101-soloist.log`
geschnitten: Zeilen ab `dlog-lines-before-run<N>.txt`+1 (Zeilenzähler vor dem
Lauf) bis vor die erste fakepulse-Zeile mit Ortszeit > Fensterende
(`T1+5 s` aus der `Fenster:`-Zeile des extract.txt), dann durch den
damaligen Filter `_daemon_fp_filter` des Runners: nur zeitgestempelte
`[fakepulse …]`-Zeilen, ohne `underflow: ring empty`. Der Filter entfernt
keine Zeile, die die Arm-Prüfung liest; für alle sieben Ausschnitte wurde
geprüft, dass Filter(Vollausschnitt) byteidentisch zum Fixture ist.

**Diese sieben Fälle (`run2` … `run11`, `arm-keine`) enthalten deshalb KEINE
soloist-Zeile** — auch nicht die `Seeking to position: … ms`-Zeile, die der
heutige Filter zusätzlich durchlässt — und keine Herkunftsdatei
`daemon-window.quelle`. Der Daemon-Log-Ersatzweg von Bedingung (i) hat dort
nichts zu lesen (`SEEKING_LOG=fehlt`); ihre Urteile sind unverändert. Im echten
Lauf run2 stand die Zeile im Log (06:57:54.865 UTC) — neu geschnitten läse er
`FAIL_LMS_START` statt `FAIL_POSITION`, bliebe also rot.

## Fälle `fixa-A`, `fixa-B`, `fixa-D` (Daemon-Log-Ersatzweg von Bedingung (i))

**Herkunft:** stille Live-Serie „fix-a" auf `lavender-UAT` vom 2026-09-24,
10:11–10:15 Ortszeit, NACH Fix `6b8bbae` (startOffset aus seekdata), gefahren
mit dem Runner-Stand `daaabf6` (`SEEK_OUT_BASE=scratchpad/fix-a/live`,
`fixa-A` = run1, `fixa-B` = run2, `fixa-D` = run4; Buchstaben wie in der
Debug-Sitzung `connect-seek-zeit-ab-null`). Kein Hörbefund, kein Nutzerzitat.

- `ws.jsonl`, `status-series.txt`, `extract.txt` wörtlich; `run-meta.txt` = die
  `meta.txt` des Laufs wörtlich (alter Runner: B und D dort `FAIL_POSITION`).
- `daemon-window.log` NEU geschnitten aus demselben Roh-Log, exakt der
  Zeilenbereich `DAEMON_LOG_ZEILEN` der run-meta.txt (A `918152..922803`,
  B `925671..930320`, D `935897..940550`), durch den HEUTIGEN
  `_daemon_fp_filter`: fakepulse-Zeilen wie bisher plus genau die soloist-Form
  `HH:MM:SS.mmm <L> [f:<n> …] Seeking to position: <ms> ms` (UTC, ohne Datum,
  mit ANSI-Farbcode am Zeilenende). Geprüft: der ALTE Filter auf den neuen
  Schnitt angewandt ist byteidentisch zur `daemon-window.log` des Laufordners;
  der einzige Unterschied je Fall ist diese eine Zeile
  (A `08:11:04.963 … 150000 ms`, B `08:12:42.241 … 150000 ms`,
  D `08:14:58.163 … 120000 ms`).
- `daemon-window.quelle` **nachgebildet** (der Runner `daaabf6` schrieb noch
  keine): `DAEMON_LOG_DATEI=` der Roh-Log-Pfad, `DAEMON_LOG_ZEILEN=` der
  Bereich oben — genau das, was `_daemon_slice` heute schreibt.

| Verzeichnis | Ziel | Was er belegt |
|---|---|---|
| `fixa-B` | 150 s | GREEN (i) per Log: Ziel = eingefrorene Daemon-Position, 0 Frames (Dedup des Binaries), `Seeking to position: 150000 ms` +60 ms nach T_SEND → `POSITION_QUELLE=daemonlog_seeking`; LMS-Uhr richtig (151,13) |
| `fixa-D` | 120 s | dasselbe bei 120 s (+84 ms) |
| `fixa-A` | 150 s | GREEN per Frame: Frame 150000 (+70 ms) UND Log-Zeile → `POSITION_QUELLE=frame` (der Frame hat Vorrang) |

**Abgeleitete Fälle** (nicht als Dateien abgelegt; der Selbsttest erzeugt sie
zur Laufzeit per `_fx_derive` aus dem gestagten echten Fall, ändert oder
entfernt GENAU EINE Zeile einer Datei und prüft per `diff`/`cmp`, dass alles
andere byteidentisch bleibt): `b-falsche-position` (Seeking 150000 → 0 ms),
`b-grenze-3000`/`b-grenze-3001` (→ 153000/153001 ms), `b-ohne-seeking` (Zeile
entfernt), `b-vor-tsend` (Stempel → 08:12:41.241), `b-nach-fenster`
(→ 08:12:47.241), `b-fremder-player` (Herkunft → Log von lavender-pa
`0200005a1103-soloist.log`; dessen echtes Log enthält keine einzige
Seeking-Zeile, ein echter Fremd-Player-Fall existiert nicht),
`a-frame-widerspricht` (fixa-A, Seek-Frame 150000 → 0 ms). Dazu zwei
synthetische Formelproben über UTC-Mitternacht (`mitternacht-drin`/`-davor`,
echte Zeilenform, Stempel ersetzt) — kein echter Lauf kreuzte Mitternacht.

## Fälle

| Verzeichnis | Ziel | Was er belegt |
|---|---|---|
| `run2` | 150 s | RED (i) und (v): Daemon stand vor dem Seek schon auf `buffering`/150000, 0 Frames nach T_SEND, LMS zählt 0 → 19,5 |
| `run4` | 150 s | GREEN (i): erster Frame nach T_SEND ist ein Vor-Seek-Frame (35126 ms, +62 ms), der Seek-Frame 150104 kommt +72 ms; Arm per `via=pending` |
| `run5` | 120 s | GREEN (i): erster Frame 53004 ms (+18 ms), Seek-Frame 120000 (+70 ms) |
| `run6` | 150 s | GREEN, konform; Arm vom Backlog-Durchgang verbraucht |
| `run8` | 150 s | GREEN, konform; `seek_arm: armed=1` vor dem Flush |
| `run11` | 100 s | RED (v): Browse-Modus, Frame genau auf dem Ziel (+63 ms), LMS-Uhr trotzdem ab 0 (SF-5) |
| `arm-keine/` | — | RED (iv): wird mit run6 kombiniert (nur diese zwei Dateien getauscht). `extract.txt` = uat-dry 07:04 (server.log ohne Arm-Zeile, weil DEBUG damals aus war; enthält die Leertexte `[MUSTER NICHT GEFUNDEN …] … /seek-arm sent` und `[ABGELEITET] Delta(seek_arm: armed= …) … nicht gefunden`, die der alte Runner als Beleg nahm). `daemon-window.log` = echtes Fenster 09:00:05.707–09:01:38 zwischen run3 und run4 ohne LMS-Seek (enthält `boundary_planted … seek_arm_reset` — kein Arm) |
