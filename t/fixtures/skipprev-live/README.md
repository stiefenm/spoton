# t/fixtures/skipprev-live/ — echter skip_prev-Lauf für den Runner-Selbsttest

Eingaben für `seek-restart-built.sh selftest`, Teil 3 (`_selftest_skipprev`),
Runner `.planning/phases/83.1-soloist-control-connect-umbau-und-policy/runners/`.
Kein `prove`-Test liest diese Dateien.

## `run1` — der Hörlauf vom 2026-09-24, 11:39 (lavender-pa)

**Herkunft:** `skipprev-run1` des Hörprotokolls 83.1-05 (Plan 05 Task 4, D-B3),
Spieler `lavender-pa` (`02:00:00:5a:11:03`, streamFormat auto → flac,
Proxy-Pfad), Connect, Titel „On & On" (`0tNuJpBgtE65diL6Q8Q7fI`) bei ~1:33,
LMS-Neustart 11:35:03. Der Nutzer drückte in LMS einmal „voriger Titel".
Gefahren mit dem alten Runner-Stand (vor der Debug-Sitzung
`connect-skip-prev-ton-bleibt`). Die Hörbefunde selbst stehen wörtlich nur in
`83.1-05-HOERPROTOKOLL.md` und in der Debug-Sitzung — hier steht keiner.

| Datei | Inhalt | verändert? |
|---|---|---|
| `status-series.txt` | LMS-`status`-Abfragen des alten Runners (`EPOCH MODE TIME`) | nein |
| `run-meta.txt` | `meta.txt` des alten Runners — gelesen wird nur `T_PRESS_EPOCH`; sein Urteil `GATE_SKIPPREV_POST=FAIL_KEINE_DATEN` ist historisch | nein |
| `ws.jsonl.gz` | Recorder-Mitschnitt `tools/soloist-ws-record.pl` | nein (nur `gzip -9n`; entpackt byteidentisch geprüft) |
| `daemon-window.log` | Daemon-Log-Ausschnitt, siehe unten | **gefiltert** |
| `daemon-window.quelle` | Herkunft: Datei und Zeilenbereich | neu |

`daemon-window.log` wurde aus `/var/lib/squeezeboxserver/cache/spoton/0200005a1103-soloist.log`
geschnitten, Rohzeilen `424027..427021`. Der alte skipprev-Modus zählte vor
dem Lauf keine Zeilen; der Bereich ist deshalb über die fakepulse-Ortszeit
gewählt: erste fakepulse-Zeile ≥ 11:39:36.000 (Beginn der PRE-Abfrage
11:39:36.9) bis vor die erste Zeile nach dem Fensterende 11:41:07.301 des
extract.txt dieses Laufs (das Log war nach 09:40:51 UTC still). Danach
durch den `_daemon_fp_filter` des Runners: nur zeitgestempelte
`[fakepulse …]`-Zeilen ohne `underflow: ring empty`, plus die soloist-Zeile
`Seeking to position: … ms`. 0 Treffer für `spak_`/`auth_data`/`Bearer`.

## Warum run1 ROT sein MUSS — und woraus

Die Statusreihe wurde **nicht** verlängert: nach dem Tastendruck gibt es keine
echte LMS-Abfrage (der alte Runner brach die Abfrage an der Zeile ab, die den
Sprung zeigte — genau der Fehler, den Schritt 1 behebt). Deshalb:

- `BED_POST_DATEN=FAIL_FENSTER_UNVOLLSTAENDIG` — strukturell, kein Produktsignal.
- `BED_POST_NEUSTART=PASS` — die LMS-Uhr sprang wirklich auf 0,58 s (die
  „Leiste springt"-Hälfte des Symptoms).
- `BED_KEIN_STOP=FAIL_DAEMON_PAUSE` — **echter** Frame: der Daemon meldet
  `paused` 21,54 s nach dem Tastendruck (ws.jsonl, 11:40:20.014).
- `BED_NEUER_STROM=FAIL_KEIN_ATTACH` — **echte** Zeilen:
  `[fakepulse 11:39:58.009] flush-disconnect: closed active HTTP client`
  ohne Arm, danach kein `client-attach` — der Strom zu LMS wurde geschlossen
  und nie neu geöffnet.

Die beiden letzten sind die Produktbelege; sie brauchen keine LMS-Zeile nach
dem Tastendruck.
