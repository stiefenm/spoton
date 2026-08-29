# Phase 76 — Konsolidierte Live-UAT-Checkliste (D-09 / D-11 / D-14)

**Ein Durchlauf, beide Backends.** Diese Checkliste ist das Master-Skript für die EINE manuelle
UAT-Session am Ende von Phase 76 (Entscheidung D-10/D-11): Dev-Setup mit LMS + squeezelite +
Spotify-App, kein automatisiertes Test-Rig (D-09). Sie konsolidiert:

- Phase 73 Windows 1-4 (73-VERIFICATION.md, 6 Human-Verification-Szenarien)
- Phase 75 SpClient-Smoke (tools/spclient-smoke.pl + In-LMS-Spot-Checks)
- GH #149/#150-Verifikation (Code-Fixes aus QT 260817-ana, released v3.5.1/v3.5.2)
- Jeden `<human-check>` aus den Plänen 76-01 bis 76-08
- Die librespot-Backend-Regressionsmatrix (D-14)

Die Reihenfolge minimiert Umgebungswechsel: erst Soloist-Backend komplett (Abschnitte 2-3),
dann LMS-freier SpClient-Smoke + Browse-Spot-Checks (Abschnitt 4), dann einmaliger
Backend-Wechsel auf librespot für die Regressionsmatrix (Abschnitt 5). Ergebnisse landen im
Ledger (Abschnitt 6). `/gsd-verify-work` kann diese Datei konversationell abarbeiten.

**Pro Item:** Setup → Aktion → Erwartet → Evidenz.

---

## 1. Environment-Vorbereitung

- [ ] **1.1 Deploy-Stand prüfen.** Der Dev-LMS lädt das Plugin per Symlink aus dem
  Main-Checkout (`/var/lib/squeezeboxserver/Plugins/SpotOn -> /home/sti/spoton/Plugins/SpotOn`).
  Sicherstellen, dass ALLE Phase-76-Merges (Wave 1-4) im Main-Checkout liegen und LMS danach
  neu gestartet wurde (`sudo systemctl restart lyrionmusicserver` — sanktioniert; 76-07 lief
  sonst gegen alten Code). Evidenz: `git log --oneline -5` im Main-Checkout + LMS-Startzeit im
  server.log nach dem letzten Merge.
- [ ] **1.2 Binaries.**
  - `libpulse.so.0`: in-tree neu gebaut (76-01 S32LE + 76-07 Instrumentierung, x86_64-Dev-Build) —
    wird über den Checkout-Symlink geladen; kein separater Deploy nötig.
  - `librespot-spoton`: die Rust-Änderungen aus 76-02 (#159-409-Contract, #128-Resync) und
    76-05 (`stop inactive`-Marker) sind NICHT im released Binary — vor Abschnitt 5 lokal
    `cargo build --release` und das Binary in den LMS-Bin-Pfad deployen (CI baut erst beim
    nächsten Tag). Evidenz: Build-Timestamp des deployten Binaries.
  - `lame` vorhanden (`/usr/bin/lame`, Systempaket) — nötig für die MP3-Items.
- [ ] **1.3 Soloist-Pairing.** backend=soloist aktiv, spak-Key hinterlegt, Test-Player in der
  Spotify-App gepairt (App-Tap). Daemon-Status in den Settings grün.
- [ ] **1.4 Diagnostics an.** `diagnosticMode` in den SpotOn-Settings aktivieren und
  `SPOTON_FAKEPULSE_DEBUG` setzen (aktiviert die t0-t4-Reconnect-Instrumentierung aus 76-07).
  `tail -F /var/log/squeezeboxserver/server.log` + Daemon-Log des Test-Players offen halten.
- [ ] **1.5 squeezelite mit Debug-Logs.** Test-Instanz mit `-d output=debug` (oder `-d all=debug`)
  starten, damit Format/Bit-Tiefe im Log nachweisbar sind. Für Sync-Group-Items eine ZWEITE
  squeezelite-Instanz bereithalten.
- [ ] **1.6 Spotify Desktop mit CDP starten (RESEARCH Pitfall 7).** Alte Instanz zuerst hart
  beenden (`kill -9`, nicht `pkill -f`), dann:
  `spotify --remote-debugging-port=9222 --remote-allow-origins='*'`
  ⚠️ **Security (T-76-18): `--remote-allow-origins=*` ist NUR für diese Test-Session zulässig.**
  Teardown-Schritt 6.4 (CDP-Instanz beenden, normal neu starten) ist Pflichtteil dieser UAT.

---

## 2. Soloist-Backend — Phase 73 Windows 1-4 (aus 73-VERIFICATION.md)

- [ ] **2.1 Connect-Transfer via Device-Picker (D-07/Phase 73).**
  Setup: Player verbunden, backend=soloist, genau ein Soloist-Prozess läuft.
  Aktion: Player in der Spotify-App im Device-Picker antippen.
  Erwartet: Gerät erscheint unter seinem LMS-Namen; der Tap transferiert — LMS startet
  `spoton://connect-`-Playback mit hörbarem `/stream`-Audio, OHNE LMS-seitigen Web-API-Call.
  Evidenz: server.log (kein `PUT /me/player`), `device_changed`/`track_changed` im Daemon-Log.
- [ ] **2.2 Bidirektionale Control-Loop + WS-down-Fallback (D-06/D-15, WINDOWS-Phase-73 #1).**
  Setup: Aktive Soloist-Connect-Session.
  Aktion: pause/skip/seek/volume aus LMS (Material Skin oder CLI) auslösen und Spotify-App
  beobachten; dann WS-Verbindung killen/blockieren und dieselben Aktionen wiederholen.
  Erwartet: Aktionen spiegeln sich in der App innerhalb ~1s; bei totem WS erreichen sie
  Spotify über den Web-API-Fallback (nicht stillschweigend verworfen).
  Evidenz: server.log Fallback-Zeile ("trying Web API fallback (D-15)").
- [ ] **2.3 Build-Expiry rc=10-Parking (Pitfall 7 Phase 73, WINDOWS-Phase-73 #2) — best effort.**
  Nur wenn erzwingbar (z.B. abgelaufenes Build vorhanden): Soloist-Prozess mit Exit-Code 10
  enden lassen.
  Erwartet: DaemonManager loggt die Build-Expiry-Meldung, setzt `spoton_soloist_expired`,
  der 60s-Watchdog restartet NIE. Nicht erzwingbar → als SKIPPED mit Begründung ins Ledger.
- [ ] **2.4 Wave-0-Spike-Beobachtungen (D-03, WINDOWS-Phase-73 #3).**
  Setup: Browse-Playback (Abschnitt 2.5) mit Daemon-Log/`soloist ctl trace` beobachten.
  Aktion: An jeder Track-Grenze die reale Event-Sequenz mitschneiden: Track-Ende-Verhalten,
  Autoplay-Unterdrückung durch Seeding, `queue_changed`-Echo-Form, Takeover-Gap (Ziel <1s).
  Erwartet: Bestätigt (oder korrigiert) die RESEARCH-Default-Annahmen der Advance/Seeding-Logik.
  Evidenz: Event-Log-Auszug pro Track-Grenze.
- [ ] **2.5 Live Browse + Sync-Group (D-03/Pattern 7, WINDOWS-Phase-73 #4).**
  Aktion (Sequenz): (a) 3 Album-Tracks in Browse queuen und durchspielen — keine Skips, kein
  früher Wechsel; (b) 10s pausieren, unpausieren — Resume an der Pause-Position, nicht
  vorgerückt; (c) Material-Skin-Seek-Bar nutzen — Seek ohne Stream-Restart; (d) gemischte
  Spotify→Radio/Lokal-Playlist — sauberer Handover an der Grenze; (e) zwei Player syncen —
  beide spielen Audio über den Daemon-Proxy, Device-Picker zeigt den Sync-Suffix-Namen.
  Evidenz: server.log + hörbare Kontrolle pro Teilschritt.
- [ ] **2.6 Settings-Render + D-07-Dropdown (76-08 Task 1 human-check).**
  Aktion: Player-Settings-Seite mit backend=soloist öffnen — Stream-Format-Dropdown zeigt
  Auto/PCM/FLAC/MP3 (KEIN OGG); zusätzlich Basic-Settings: Soloist-Status-Tabelle +
  Expiry-Zeile sichtbar. Danach backend=librespot, Seite neu laden — alle fünf Optionen
  rendern und eine zuvor gespeicherte OGG-Wahl ist wieder selektiert; Soloist-Statusblock weg.
  Erwartet: exakt wie beschrieben (gespeicherte OGG-Pref wird bei Soloist nur ANGEZEIGT als
  Auto, nie umgeschrieben).
  Evidenz: 2 Screenshots (soloist/librespot).

---

## 3. Soloist-Backend — Phase-76-Fixes

- [ ] **3.1 FLAC24-Kette (76-01 human-check; WINDOWS-Ledger #1).**
  Setup: backend=soloist, streamFormat=auto, squeezelite (meldet `flc`).
  Aktion: Soloist-Track (Browse) auf squeezelite abspielen.
  Erwartet: LMS songinfo / squeezelite-Debug-Log zeigt FLAC mit 24 bit; Audio sauber —
  KEIN weißes Rauschen, KEINE falsche Geschwindigkeit (RESEARCH-Pitfall-2-Warnzeichen).
  Evidenz: songinfo-Ausgabe + squeezelite-Logzeile mit Format/Bit-Tiefe.
- [ ] **3.2 Format-Matrix Soloist (76-04 human-check; WINDOWS-Ledger #2, Soloist-Hälfte).**
  Aktion: nacheinander streamFormat=pcm, dann mp3 setzen und je einen Track spielen.
  Erwartet: pcm → direkter Raw-S32-Stream, KEIN Transcoder-Prozess (per `ps` prüfen);
  mp3 → `lame` sichtbar in der Transcoder-Pipeline.
  Zusatz (76-07-Residual, WINDOWS-Ledger #6 Teil 2): squeezelite einmal mit `-e flac`
  (flc-Capability ausgeschlossen) starten → auto fällt auf den `soc pcm`-Direct-Path zurück;
  einen Spotify-App-Skip in dieser Konfiguration testen (Direct-Stream-Reconnect-Verhalten).
  Evidenz: `ps`-Ausgabe, server.log formatOverride/canDirectStream-DIAG-Zeilen.
- [ ] **3.3 Skip-Reconnect Ohr-Check (76-07 human-check; WINDOWS-Ledger #6 Teil 1).**
  Setup: Aktive Soloist-Connect-Session, streamFormat=auto.
  Aktion: In der Spotify-App mehrfach Skip Next.
  Erwartet: hörbares Audio des neuen Tracks innerhalb ~3s (gemessen in 76-07: sub-second).
  Evidenz: t0-t4-Trace-Zeilen im Daemon-Log (1.4 aktiviert) + Ohr.
- [ ] **3.4 Restart-Autoplay-Suppression (76-05 Task 1 human-check; WINDOWS-Ledger #3).**
  Aktion: (a) Connect-Session pausieren, LMS restarten — es startet KEIN Audio von selbst;
  Session bleibt in der App sichtbar. (b) Danach das Gerät in der App antippen/Play —
  Playback startet normal in üblicher Transfer-Zeit.
  Evidenz: server.log Suppression-Info-Zeile nach Restart; kein `playlist play spoton://connect-`
  ohne User-Aktion.
- [ ] **3.5 Power-Restore GH #151 (76-05 Task 2 human-check; WINDOWS-Ledger #5).**
  Aktion: (a) Player ausschalten (Power OFF), Connect-Session aus der App starten — Player
  geht an und spielt; Session beenden (Transfer weg oder Disconnect) — Player schaltet wieder
  AUS. (b) Wiederholen mit einem Player, der schon AN war — er bleibt AN.
  Evidenz: Power-Status vorher/nachher, server.log `'inactive'`-Stop + Restore-Dispatch.
  📋 **Entscheidung fürs Ledger (6.3):** Community-Wunsch nach Opt-in-Pref (Automationen
  hängen am Power-State) — mit User klären, ggf. Phase-77-Settings-Item.
- [ ] **3.6 Up Next GH #135 (76-06 human-check).**
  Aktion: Während einer aktiven Connect-Session 2 Tracks in der Spotify-App zur Queue
  hinzufügen, dann SpotOn → "Up Next" in Material Skin öffnen.
  Erwartet: Now-Playing-Track + beide gequeuten Tracks in Reihenfolge; ohne Session zeigt der
  Menüpunkt die Empty-State-Meldung; server.log zeigt GENAU EINEN `me/player/queue`-Request
  pro Menü-Öffnung (kein Polling).
  Evidenz: Screenshot + server.log-Zählung.
  📋 **Entscheidung fürs Ledger (6.3):** Option A (Web-API on-demand) vs. Issue-Autor-Präferenz
  Option B (Spirc-Events, Phase 77+) — Absegnung durch User.

---

## 4. SpClient-Smoke (Phase 75) + Browse-Spot-Checks

- [ ] **4.1 LMS-freier Smoke-Lauf.**
  Aktion: `perl tools/spclient-smoke.pl /pfad/zu/credentials.json [trackId]`
  Erwartet: alle Stages grün — `creds` (Datei-Parse) → `mint` (login5-Token, nur Länge/Expiry
  geloggt) → `apresolve` (Host) → `metadata` (Track-Name + Artists) → `rootlist`
  (Playlist-Count) → Abschluss `OK: login5 + spclient round-trip succeeded end to end.`
  Evidenz: vollständige Script-Ausgabe.
- [ ] **4.2 In-LMS-Spot-Checks über den spclient-Pfad (ein Item pro Familie).**
  Aktion + Erwartet (jeweils Ergebnisliste plausibel, keine Fallback-Fehler im server.log):
  - Track-Metadata: beliebigen Album-Track in Browse öffnen (Titel/Artist/Cover korrekt)
  - Search: Track-Suche (bis zu 20 Treffer — spclient, nicht Web-API-Cap 10)
  - Liked Songs: Liste lädt ohne Web-API-Paging
  - Playlists: eigene Playlist-Liste (Rootlist) + eine Playlist öffnen
  - Recently Played: Liste lädt (Protobuf-Pfad)
  Evidenz: server.log-Routing-Zeilen (SpClient, keine unerwarteten Client.pm-Delegationen).
- [ ] **4.3 Browse-UX GH #161 (76-03 human-check — backend-unabhängig, hier einmal testen).**
  Aktion: In Material Skin über Recently Played / Top Tracks / Liked Songs hovern.
  Erwartet: Play-All- und Add-to-Queue-Aktionen erscheinen; Made For You navigiert weiterhin
  als einfacher Link (keine Hover-Play-Aktionen).
  Evidenz: Screenshot.
- [ ] **4.4 Kontextmenü-Parität GH #94 (76-03 human-check).**
  Aktion: Beliebigen Album-Track über das SpotOn-OPML-Menü browsen, "More" drücken; dasselbe
  für eine Podcast-Episode.
  Erwartet: Item-Set identisch mit dem TrackInfo-Menü aus Now Playing für denselben Track
  (LMS-Standard-Items + Artist View + Album View + Like + Add to Playlist; Episode: Show View
  + Follow + Add to Playlist + Standard-Items).
  Evidenz: 2 Screenshots (Browse-More vs. Now-Playing-More).

---

## 5. librespot-Backend — Regressionsmatrix (D-14)

> Backend global auf librespot umstellen, Daemons neu starten (deployte librespot-spoton
> mit den 76-02/76-05-Rust-Änderungen — siehe 1.2).

- [ ] **5.1 Browse-Playback.** Einen Track + ein Album über Browse abspielen — startet,
  spielt sauber, Metadata korrekt. Evidenz: hörbar + server.log.
- [ ] **5.2 Connect-Transfer + Control-Loop.** Transfer via Device-Picker, dann
  pause/skip/seek/volume aus LMS und aus der App — beide Richtungen spiegeln sich ≤ ~1s.
- [ ] **5.3 Format-Wechsel auto/ogg/pcm/flac/mp3 (76-04 human-check, librespot-Hälfte;
  WINDOWS-Ledger #2).**
  Aktion: streamFormat der Reihe nach durchschalten, je einen Track spielen.
  Erwartet: auto → OGG-Passthrough wenn Player OGG kann, sonst PCM (UNVERÄNDERT);
  ogg/pcm unverändert; **NEU:** explizites flac transkodiert jetzt WIRKLICH über die
  `soc flc`-Regel (16-bit bei librespot) statt still auf PCM zu fallen; mp3 → `smp`/[lame].
  Auf Pitfall-2-Warnzeichen achten: weißes Rauschen, doppelte/halbe Geschwindigkeit.
  Evidenz: songinfo/squeezelite-Log pro Format.
- [ ] **5.4 GH #149 Idle-Guard + GH #150 Audio-Key-Timeout (QT 260817-ana, Live-Verifikation).**
  Setup: Aktive librespot-Connect-Playback-Session.
  Aktion: AP-Drop-Szenario provozieren (kurze Netzwerk-Unterbrechung Richtung Spotify-APs
  oder opportunistisch einen natürlichen AP-Reconnect abwarten).
  Erwartet: KEIN Daemon-Restart mitten im Playback (Idle-Guard defer-Zeile im server.log,
  #149); Playback überlebt den AP-Reconnect — Audio-Key-Retry statt "continuing without
  decryption"/Session-Drop (#150).
  Evidenz: server.log Idle-Guard-Defer + Daemon-Log Key-Retry.
- [ ] **5.5 GH #159 Eject-Szenario (76-02 human-check).**
  Aktion: Connect-Playback starten, pausieren, Gerät in der Spotify-App DESELEKTIEREN, dann
  Play aus Material Skin drücken.
  Erwartet: LMS stoppt/ejected innerhalb ~5s statt in BUFFERING zu hängen; server.log zeigt
  den `control_cmd_rejected`-Marker; Gerät wieder selektieren → normale Kontrolle zurück.
  Evidenz: server.log-Auszug.
- [ ] **5.6 GH #131 Sync-Group-Stutter (76-02 human-check).**
  Aktion: Connect-Playback auf der Dev-Sync-Group (zwei squeezelite-Instanzen), 3+ Minuten
  durchlaufen lassen.
  Erwartet: kontinuierliches Playback OHNE den 1s-Play/10-20s-Pause-Stutter-Zyklus.
  Evidenz: server.log (keine Rebuffer-Zyklen), Ohr.
- [ ] **5.7 GH #128 Handoff-Position (76-02 human-check).**
  Aktion: Track in der Spotify-App starten, MITTEN im Song auf den SpotOn-Player transferieren.
  Erwartet: nach Buffer-Fill divergieren App-Playhead und LMS-UI um ≤ ~2s; Daemon-Log zeigt
  die "resyncing LMS position"-Zeile beim Relay-Start.
  Evidenz: Daemon-Log + Sichtvergleich beider Progress-Bars.
- [ ] **5.8 GH #158 Gruppen pause→skip→play (76-05 Task 3 human-check; WINDOWS-Ledger #4).**
  Aktion: Auf der Dev-Sync-Group Connect-Playback starten, in der App pausieren, skippen,
  dann Play drücken.
  Erwartet: Musik läuft auf dem neuen Track innerhalb weniger Sekunden an; KEINE wiederholten
  `playlist play spoton://connect-`-Dispatches / Song-Restarts im server.log.
  Evidenz: server.log-Auszug.

---

## 6. Ergebnis-Ledger

### 6.1 WINDOWS.md-Einträge (nach bestandenem Item im MAIN-CHECKOUT schließen)

Befehl je Eintrag: `node ~/.claude/gsd-core/bin/gsd-tools.cjs windows fixed <id>`

| WINDOWS-id | Inhalt | UAT-Item | Ergebnis | Geschlossen |
|-----------|--------|----------|----------|-------------|
| 1 | 76-01 Live-FLAC24-Kette (24-bit + sauberes Audio) | 3.1 | ☐ pass / ☐ fail | ☐ |
| 2 | 76-04 Live-Format-Matrix (Soloist auto/pcm/mp3 + librespot D-14) | 3.2 + 5.3 | ☐ pass / ☐ fail | ☐ |
| 3 | 76-05 Restart-Autoplay-Live-Repro | 3.4 | ☐ pass / ☐ fail | ☐ |
| 4 | 76-05 GH #158 Gruppen-Crash-Live-Repro | 5.8 | ☐ pass / ☐ fail | ☐ |
| 5 | 76-05 GH #151 Power-Restore-Live-Check | 3.5 | ☐ pass / ☐ fail | ☐ |
| 6 | 76-07 Skip-Ohr-Check + PCM-only-Direct-Pfad | 3.3 + 3.2-Zusatz | ☐ pass / ☐ fail | ☐ |

### 6.2 Nicht-Ledger-Items

| Item | UAT-Item | Ergebnis |
|------|----------|----------|
| Phase 73 Window 1 (Control-Loop + WS-Fallback) | 2.2 | ☐ pass / ☐ fail |
| Phase 73 Window 2 (Build-Expiry rc=10) | 2.3 | ☐ pass / ☐ fail / ☐ skipped |
| Phase 73 Window 3 (Wave-0-Spike-Annahmen) | 2.4 | ☐ pass / ☐ fail |
| Phase 73 Window 4 (Browse + Sync-Group) | 2.5 | ☐ pass / ☐ fail |
| Phase 73 Transfer + Settings-Render | 2.1 + 2.6 | ☐ pass / ☐ fail |
| D-07 Dropdown (76-08) | 2.6 | ☐ pass / ☐ fail |
| SpClient-Smoke + Spot-Checks | 4.1 + 4.2 | ☐ pass / ☐ fail |
| GH #161 / GH #94 Browse-UX | 4.3 + 4.4 | ☐ pass / ☐ fail |
| GH #149 / GH #150 (QT 260817-ana) | 5.4 | ☐ pass / ☐ fail |
| GH #159 / #131 / #128 (76-02) | 5.5-5.7 | ☐ pass / ☐ fail |
| GH #135 Up Next | 3.6 | ☐ pass / ☐ fail |
| librespot-Regression gesamt (D-14) | 5.1-5.8 | ☐ pass / ☐ fail |

### 6.3 Entscheidungen zur Bestätigung durch den User (während/nach der UAT)

- [ ] **FLAC24-Enum-Deferral:** Der spoton-helper-Patch-Effekt ist mangels CI-Secrets
  (`SPOTON_PRIVATE_PATTERNS_TOKEN`/`REPO`) unverifizierbar und wurde aus den
  Phase-76-Erfolgskriterien auf Phase 77 verschoben — Ausnahme zur D-01-Regel
  ("keine Deferrals"), explizit bestätigen lassen (RESEARCH Open Question 4).
- [ ] **GH #135 Option A:** on-demand Web-API-Queue statt Spirc-Events (Option B, Phase 77+) —
  Issue-Autor präferierte B; Wahl absegnen lassen.
- [ ] **GH #151 Opt-in-Frage:** Always-on Power-Restore vs. Opt-in-Pref (Community-Einwand:
  Automationen am Power-State) — entscheiden, ggf. Phase-77-Settings-Item.

### 6.4 Teardown (Pflicht, T-76-18)

- [ ] CDP-fähige Spotify-Instanz beenden (`kill -9`) und Spotify OHNE
  `--remote-debugging-port`/`--remote-allow-origins` normal neu starten.
- [ ] `diagnosticMode`/`SPOTON_FAKEPULSE_DEBUG` zurücksetzen, falls nicht dauerhaft gewünscht.

---

*Erstellt: 2026-08-29 (Plan 76-08 Task 3). Quellen: 73-VERIFICATION.md, WINDOWS.md,
76-01..76-07-SUMMARYs, 76-RESEARCH.md (Validation Architecture, Pitfall 2/6/7).*
