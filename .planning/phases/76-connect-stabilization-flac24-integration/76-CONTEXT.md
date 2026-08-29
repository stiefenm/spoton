# Phase 76: Connect Stabilization + FLAC24 Integration - Context

**Gathered:** 2026-08-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Alle Bugs und fehlenden Integrationen fixen, die ein nutzbares v4.0 blockieren. Vier Cluster: (1) Connect-Mode-Bugs (#159, #158, #131, #128, #151, Auto-Play nach Restart, Window 5 8s-Gap), (2) FLAC24-Audio-Pipeline (fake-libpulse Upgrade, convert-Regel, Format-Dropdown), (3) Phase-73/75 Live-Verifikation (Windows 1-4, SpClient Smoke-Test), (4) Browse/Playback-Control (#161, #94, #135, Window 6 search()-Offset). ROADMAP-Bereinigung (gefixt Issues markieren) ist Teil der Phase.

#149 (Idle-Guard) und #150 (Audio-Key-Timeout) sind bereits per Quick Task 260817-ana gefixt (Code), Verifikation steht noch aus — wird als Teil der Live-Verifikation abgedeckt.

</domain>

<decisions>
## Implementation Decisions

### Scope & Organisation
- **D-01:** Voller Scope — alle ~15 Items aus der ROADMAP bleiben in Phase 76. Keine Deferrals. — **Reversibility:** reversible
- **D-02:** [informational] Planner bestimmt Reihenfolge — kein festes Cluster-Modell (Connect-Bugs vs. FLAC24 vs. Verifikation vs. Browse). Planner ordnet nach Abhängigkeiten. — **Reversibility:** reversible
- **D-03:** ROADMAP-Bereinigung — Phase-76-Beschreibung aktualisieren: #149/#150 als gefixt markieren, verbleibende Items klar listen. — **Reversibility:** reversible

### FLAC24 Audio-Pipeline
- **D-04:** RESEARCH-AUFTRAG — fake-libpulse muss von S16LE auf höhere Auflösung umgebaut werden. Aktuell konvertiert `_convert_and_push()` (fake-libpulse.c Zeile 484-525) FLOAT32LE→S16LE und S32LE→S16LE — das vernichtet 8 Bit Dynamikumfang (48 dB). Researcher klärt: (1) optimales Ausgabeformat (S32LE vs. S24LE vs. S24_32LE), (2) Ring-Buffer-Architektur-Impact, (3) bestes Transcoding-Tool für `soc flc * *` convert-Regel (sox+flac vs. ffmpeg vs. anderes). Alles muss mit LMS-bundled Tools funktionieren (sox, flac sind bundled; lame ist Systempaket; ffmpeg ist NICHT bundled). — **Reversibility:** reversible
- **D-05:** Neue `soc flc * *` convert-Regel in custom-convert.conf. LMS-TranscodingHelper iteriert Player-Formats in Präferenz-Reihenfolge (TranscodingHelper.pm Zeile 371-386) und sucht passende Regeln. Player die `flc` in `$c->formats()` melden (z.B. squeezelite), bekommen automatisch FLAC. Andere fallen auf `soc pcm * *` zurück. Keine manuelle Player-Erkennung nötig — LMS macht das automatisch. — **Reversibility:** reversible
- **D-06:** Auto-Modus bei Soloist-Backend: capability-basiert. Player meldet `flc` → FLAC24, sonst PCM. Gleiche Idiomatik wie librespot-Auto (Player meldet `ogg` → OGG, sonst PCM). `resolvePassthroughForClient()` (DaemonManager.pm Zeile 105-155) braucht Soloist-Branch statt dem aktuellen `return 0` Short-Circuit. — **Reversibility:** reversible
- **D-07:** Format-Dropdown bei Soloist: Auto/PCM/FLAC/MP3 — OGG wird ausgeblendet (JS im Settings-Template). OGG ist librespot-exklusiv (Passthrough = roher Ogg/Vorbis-Stream). PCM, FLAC, MP3 sind Post-Decode-Transcoding und funktionieren backend-unabhängig. MP3 braucht `lame` (Systempaket, nicht LMS-bundled — gleich wie bei librespot). — **Reversibility:** reversible
- **D-08:** ProtocolHandler.pm Zeile 642 `samplesize(16)` muss auf die korrekte Bit-Tiefe aktualisiert werden (abhängig von D-04 Ergebnis), damit LMS `$SAMPLESIZE$` korrekt in convert-Regeln substituiert. — **Reversibility:** reversible

### Live-Verifikation
- **D-09:** Manuelles UAT gegen das Dev-Setup (LMS + squeezelite + Spotify App). Kein automatisiertes Test-Rig in dieser Phase. — **Reversibility:** reversible
- **D-10:** Planner bestimmt wann im Phase-Ablauf das UAT stattfindet (vor oder nach Code-Änderungen). — **Reversibility:** reversible
- **D-11:** UAT deckt Phase 73 (Windows 1-4) UND Phase 75 (SpClient Smoke-Test: Browse/Search/Library über spclient) UND librespot-Backend-Regression (D-14) zusammen ab. Ein Durchlauf, beide Backends. #149/#150 Verifikation ebenfalls enthalten. — **Reversibility:** reversible

### 8s Reconnect-Gap
- **D-12:** Debug + Fix-Versuch. Root cause untersuchen: ~8s zwischen "alter HTTP-Stream geschlossen" und "neuer HTTP-Stream verbunden" (fake-libpulse Ring: write_index steigt, read_index friert 8s). Hypothese: LMS-seitige Stream-Aufbau-Latenz für `spoton://connect-<ts>`. — **Reversibility:** reversible
- **D-13:** Soft-Blocker: ernsthafter Debug-Versuch. Wenn Root cause nach angemessenem Aufwand nicht lösbar: Known Issue mit Workaround dokumentieren, v4.0 kann damit leben. Nicht hart blockierend. — **Reversibility:** reversible

### librespot Regressions-Schutz
- **D-14:** Phase 76 ändert shared Code (fake-libpulse, DaemonManager, ProtocolHandler, custom-convert.conf, Settings). Vor dem Shipping muss ein librespot-Backend Regressionstest laufen — Browse, Connect, Format-Wechsel. Aktuell gibt es keinen solchen Test. UAT (D-11) muss BEIDE Backends abdecken, nicht nur Soloist. — **Reversibility:** reversible

### Claude's Discretion
- Transcoding-Pipeline Details (convert-Regel Syntax, sox/flac Flags, $SAMPLESIZE$ Nutzung)
- Bug-Fix-Strategien für die einzelnen Connect-Issues (#159, #158, #131, #128, #151)
- UAT-Checkliste und Reihenfolge der Testszenarien
- Debug-Ansatz für 8s Gap (Log-Analyse, Instrumentierung, LMS-Profiling)
- Browse/UX-Fixes (#161, #94, #135, Window 6) — Implementierungsdetails

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Soloist Audio-Pipeline
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — `_convert_and_push()` (Zeile 484-525): aktuelle S16LE-Konversion die auf höhere Auflösung umgebaut werden muss. Ring-Buffer-Architektur (`_ring_push`, `_http_thread_fn`).
- `Plugins/SpotOn/custom-convert.conf` — Aktuelle 2 Regeln: `soc pcm * *` und `son ogg * *`. Neue `soc flc * *` Regel muss hinzugefügt werden.
- `Plugins/SpotOn/ProtocolHandler.pm` §631-650 — Soloist `samplesize(16)` Hint und D-04/Pitfall-2 Kommentar. Muss aktualisiert werden.
- `/etc/squeezeboxserver/convert.conf` — LMS Standard-convert-Regeln. Referenz für `$SAMPLESIZE$`, `[sox]`, `[flac]`, `[lame]` Syntax.
- `/usr/share/perl5/Slim/Player/TranscodingHelper.pm` §350-410 — Format-Matching-Logik: wie LMS Player-Capabilities gegen convert-Regeln matched.

### Connect-Architektur (Bug-Kontext)
- `Plugins/SpotOn/Unified/DaemonManager.pm` — `resolvePassthroughForClient()` (Zeile 101-155): Format-Resolution, Soloist-Short-Circuit (Zeile 113). Daemon-Lifecycle, Crash-Backoff, Health-Monitoring.
- `Plugins/SpotOn/Unified/SoloistWS.pm` — WebSocket Event-API, `skipInitiated` Flag (Quick Task 12), `sessionPaused` Tracking.
- `Plugins/SpotOn/Unified/SoloistDaemon.pm` — Per-Player Soloist-Daemon-Lifecycle.
- `Plugins/SpotOn/Unified/Connect.pm` — Connect-Event-Handling, `_sendControlCommand`, Browse-Forwarding.
- `Plugins/SpotOn/API/SpClient.pm` — spclient API-Client (Phase 75). Browse/Search/Library über spclient.

### 8s Gap Analyse
- `.planning/quick/260827-of9-soloist-skip-stream-reconnect-fake-libpu/260827-of9-SUMMARY.md` — Quick Task 12 Ergebnis: skipInitiated + flush-disconnect gefixt, 8s Gap Root cause unbekannt. Ring-Buffer-Daten (write_index vs. read_index Freeze).

### Phase-73 Verifikation
- `.planning/phases/73-soloist-connect-mode/73-VERIFICATION.md` — 9 PRESENT_BEHAVIOR_UNVERIFIED Truths, 4 WINDOWS. Details pro Window und warum menschliche Verifikation nötig.
- `.planning/phases/73-soloist-connect-mode/73-03-SUMMARY.md` — Wave-0 Spike DEFERRED, Browse Sequential Playback gegen RESEARCH-Defaults gebaut.

### Settings UI
- `Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/player.html` §43-48 — Format-Dropdown (aktuell 5 Optionen). OGG muss bei Soloist ausgeblendet werden.

### Prior Phase Kontext
- `.planning/phases/75-api-unification-spclient-modell/75-CONTEXT.md` — SpClient.pm Architektur, Capability-Routing, Deferred: Probe-Logik/WebPlayer entfernen
- `.planning/phases/74-spoton-helper-binary/74-CONTEXT.md` — spoton-helper patch/check, FLAC24 5/6 Gates, Version-Lock
- `.planning/phases/73-soloist-connect-mode/73-CONTEXT.md` — SoloistDaemon, WS-API, Vendored Protocol::WebSocket

### Roadmap
- `.planning/ROADMAP.md` §Active — v4.0 Soloist Integration, Phase 76+77 Beschreibung

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `resolvePassthroughForClient()` (DaemonManager.pm Zeile 105-155): Capability-basierte Format-Resolution mit Sync-Group-Aggregation. Muss für Soloist erweitert werden (aktuell `return 0` Short-Circuit auf Zeile 113).
- `_convert_and_push()` (fake-libpulse.c Zeile 484-525): Bereits FLOAT32LE, S32LE und S16LE Pfade implementiert. Nur die Ziel-Konversion muss geändert werden.
- `$c->formats()` (LMS SqueezePlay.pm): Player melden unterstützte Formate (`ogg`, `flc`, `pcm`, `mp3`). squeezelite Default: `[ogg, flc, aif, pcm, mp3]`.
- TranscodingHelper Profil-Matching (Zeile 371-386): Iteriert Player-Formats, sucht convert-Regel `{input}-{output}-*-*`. Neue `soc flc * *` Regel wird automatisch für FLAC-fähige Player gewählt.

### Established Patterns
- Per-Player streamFormat Pref: `auto`/`ogg`/`pcm`/`flac`/`mp3` — schon implementiert, nur Soloist-Semantik fehlt
- Convert-Regel Syntax: `[tool]` = LMS sucht Binary, überspringt Regel wenn nicht vorhanden. `$SAMPLESIZE$` = Source Bit-Tiefe.
- Sync-Group Format-Aggregation: PCM-Fallback wenn IRGENDEIN Member kein OGG kann (Zeile 140-153). Gleiches Muster für FLAC nötig.
- Settings JS-Toggle: Backend-abhängige UI-Elemente werden bereits via `querySelectorAll` getoggelt (#librespot-fields, Phase 72 D-07)

### Integration Points
- `custom-convert.conf`: neue `soc flc * *` Regel
- `fake-libpulse.c`: `_convert_and_push()` Ausgabeformat ändern
- `ProtocolHandler.pm`: `samplesize()` Hint korrigieren
- `DaemonManager.pm`: `resolvePassthroughForClient()` Soloist-Branch
- `player.html`: OGG ausblenden bei backend=soloist
- `strings.txt`: ggf. Format-Label-Anpassung für Soloist

</code_context>

<specifics>
## Specific Ideas

- FLAC24-Qualitätskette: Spotify CDN (24-bit) → Soloist Decoder (float32, ~24 Bit Mantisse) → fake-libpulse (MUSS ≥24 Bit ausgeben) → sox/flac Pipeline → Player. Kein Qualitätsverlust wenn fake-libpulse ≥24 Bit liefert.
- LMS-bundled Tools: sox, flac, faad, mac, wvunpack. lame ist Systempaket (nicht bundled, aber in Standard-convert.conf referenziert). ffmpeg ist NICHT bundled und NICHT in Standard-convert.conf.
- Auto bei Soloist = `flc ∈ $c->formats()` → FLAC24, sonst PCM. Bei librespot = `ogg ∈ $c->formats()` → OGG, sonst PCM. Gleiche Idiomatik, anderes Format.
- 8s Gap Debug-Ansatz: Ring-Buffer-Instrumentierung zeigt exakt wo die Latenz entsteht (fake-libpulse `read_index` Freeze). Nächster Schritt: LMS-seitige Zeitmessung zwischen `playlist play spoton://connect-*` Command und erstem HTTP GET an fake-libpulse `/stream`.

</specifics>

<deferred>
## Deferred Ideas

- **Quality-Dropdown (OGG/FLAC/Lossless Tier-Auswahl)** — Phase 77 (UX Polish). Phase 76 baut die Pipeline, Phase 77 die Quality-Tiers.
- **Per-Player Backend-Auswahl (librespot vs. soloist per Player)** — Phase 77
- **Soloist-spezifische Diagnostics im Status-Dashboard** — Phase 77
- **Automatisiertes Audio-Level-Test-Rig** — Geparkt. Manuelles UAT für Phase 76, Rig ggf. in späterer Phase.
- **Probe-Logik entfernen** (Client.pm `probeEndpointLimits()`) — Phase 75 Deferred, ggf. Phase 76 Cleanup oder Phase 77
- **WebPlayer.pm / Pathfinder entfernen** — Phase 75 Deferred, nach UAT-Bestätigung

</deferred>

---

*Phase: 76-Connect Stabilization + FLAC24 Integration*
*Context gathered: 2026-08-29*
