# Phase 76: Connect Stabilization + FLAC24 Integration - Research

**Researched:** 2026-08-29
**Domain:** LMS Perl plugin — Spotify Connect stabilization, PCM/FLAC24 audio transcoding pipeline, fake-libpulse (C) resolution upgrade, live UAT of Soloist backend
**Confidence:** HIGH (in-repo code + LMS core read this session; transcoding pipeline empirically tested with bundled tools)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Voller Scope — alle ~15 Items aus der ROADMAP bleiben in Phase 76. Keine Deferrals. (reversible)
- **D-02:** Planner bestimmt Reihenfolge — kein festes Cluster-Modell. Planner ordnet nach Abhängigkeiten. (reversible)
- **D-03:** ROADMAP-Bereinigung — Phase-76-Beschreibung aktualisieren: #149/#150 als gefixt markieren, verbleibende Items klar listen. (reversible)
- **D-04:** RESEARCH-AUFTRAG — fake-libpulse muss von S16LE auf höhere Auflösung umgebaut werden. Klären: (1) optimales Ausgabeformat (S32LE vs. S24LE vs. S24_32LE), (2) Ring-Buffer-Architektur-Impact, (3) bestes Transcoding-Tool für `soc flc * *`. Alles mit LMS-bundled Tools (sox, flac bundled; lame Systempaket; ffmpeg NICHT bundled). (reversible)
- **D-05:** Neue `soc flc * *` convert-Regel in custom-convert.conf. LMS-TranscodingHelper wählt automatisch für `flc`-fähige Player, andere fallen auf `soc pcm * *` zurück. Keine manuelle Player-Erkennung. (reversible)
- **D-06:** Auto-Modus bei Soloist: capability-basiert. Player meldet `flc` → FLAC24, sonst PCM. `resolvePassthroughForClient()` (DaemonManager.pm) braucht Soloist-Branch statt `return 0` Short-Circuit. (reversible)
- **D-07:** Format-Dropdown bei Soloist: Auto/PCM/FLAC/MP3 — OGG ausgeblendet (JS im Settings-Template). MP3 braucht `lame`. (reversible)
- **D-08:** ProtocolHandler.pm `samplesize(16)` (Zeile 642) muss auf korrekte Bit-Tiefe (abhängig von D-04). (reversible)
- **D-09:** Manuelles UAT gegen Dev-Setup (LMS + squeezelite + Spotify App). Kein automatisiertes Test-Rig in dieser Phase. (reversible)
- **D-10:** Planner bestimmt wann im Phase-Ablauf das UAT stattfindet. (reversible)
- **D-11:** UAT deckt Phase 73 (Windows 1-4) UND Phase 75 (SpClient Smoke-Test) UND librespot-Backend-Regression (D-14) zusammen ab. Ein Durchlauf, beide Backends. #149/#150 Verifikation enthalten. (reversible)
- **D-12:** 8s Reconnect-Gap: Debug + Fix-Versuch. Root cause untersuchen (Ring: write_index steigt, read_index friert 8s). (reversible)
- **D-13:** Soft-Blocker: ernsthafter Debug-Versuch. Wenn nicht lösbar: Known Issue mit Workaround dokumentieren, v4.0 kann damit leben. Nicht hart blockierend. (reversible)
- **D-14:** librespot-Backend Regressionstest vor Shipping — Browse, Connect, Format-Wechsel. UAT (D-11) muss BEIDE Backends abdecken. (reversible)

### Claude's Discretion

- Transcoding-Pipeline Details (convert-Regel Syntax, sox/flac Flags, $SAMPLESIZE$ Nutzung)
- Bug-Fix-Strategien für die einzelnen Connect-Issues (#159, #158, #131, #128, #151)
- UAT-Checkliste und Reihenfolge der Testszenarien
- Debug-Ansatz für 8s Gap (Log-Analyse, Instrumentierung, LMS-Profiling)
- Browse/UX-Fixes (#161, #94, #135, Window 6) — Implementierungsdetails

### Deferred Ideas (OUT OF SCOPE)

- Quality-Dropdown (OGG/FLAC/Lossless Tier-Auswahl) → Phase 77
- Per-Player Backend-Auswahl (librespot vs. soloist per Player) → Phase 77
- Soloist-spezifische Diagnostics im Status-Dashboard → Phase 77
- Automatisiertes Audio-Level-Test-Rig → geparkt
- Probe-Logik entfernen (Client.pm `probeEndpointLimits()`) → ggf. Phase 76 Cleanup oder Phase 77
- WebPlayer.pm / Pathfinder entfernen → nach UAT-Bestätigung
</user_constraints>

<phase_requirements>
## Phase Requirements

REQUIREMENTS.md ist auf das v2.3-Milestone begrenzt und mappt **keine** REQ-IDs auf Phase 76 (bestätigt via `init.phase-op` + grep). Phase 76 nutzt — wie Phase 73/74/75 — die CONTEXT-Decisions (D-01…D-14) plus die GitHub-Issues als Anforderungsbasis. Der Verifier soll dieselbe Traceability-Basis verwenden (CONTEXT-Decisions + Issue-Nummern), nicht REQUIREMENTS.md.

| Item | Quelle | Research-Support |
|------|--------|------------------|
| #159 BUFFERING-Deadlock nach Connect-Deselect | GH Issue (OPEN, bug) | Root cause in `librespot-spoton/src/unified.rs` /control handler — siehe Pitfall & Bug-Cluster |
| #158 Group-Player Crash (pause→skip→play) | GH Issue (OPEN, bug) | Connect.pm sync-group + skipInitiated interaction |
| #150 Audio-Key-Timeout | GH Issue (OPEN, bug) | **Code gefixt** in QT 260817-ana — nur Live-Verifikation offen |
| #149 Idle-Guard Health-Check | GH Issue (OPEN, bug) | **Code gefixt** in QT 260817-ana — nur Live-Verifikation offen |
| #131 Sync-Group-Stutter (mixed player types) | GH Issue (OPEN, bug) | `--buffer-latency-ms` CLI-Flag existiert in `main.rs:196`; DaemonManager muss höheren Wert für synced masters setzen |
| #128 Progress-Bar-Lag beim Connect-Handoff | GH Issue (OPEN, bug) | `/stream` relay-ready gap; position-notify feuert vor relay-start |
| #151 Player-Power-State Restore | GH Issue (OPEN, enhancement) | ShairTunes-Muster; power save/restore an Connect start/end |
| Window 5: ~8s Reconnect-Gap | WINDOWS.md #5 | Ring read_index Freeze; siehe Pitfall 1 |
| Auto-Play nach LMS-Restart | ROADMAP | Connect autoplay-on-restart ohne User-Aktion |
| Windows 1-4 Live-Verifikation | WINDOWS.md #1-4 / 73-VERIFICATION.md | Ganze UAT-Sektion unten |
| FLAC24/Audio-Pipeline | D-04..D-08 | Standard Stack + Architecture Patterns unten |
| #161 Play All/Queue flache Tracklisten | GH Issue (OPEN, enhancement) | `type => 'playlist'` für Recently Played + Liked Songs in Plugin.pm |
| #94 Browse-Kontextmenü-Parität | GH Issue (OPEN, enhancement) | TrackInfo-Framework vs. OPML itemActions |
| #135 Connect-Queue ("Up Next") | GH Issue (OPEN, enhancement) | Option A (Web API poll) vs. Option B (Spirc events) |
| Window 6: search() Offset-Guard | WINDOWS.md #6 | SpClient.pm search() offset vs. track-filtered count |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

Bindend für alle Phase-76-Pläne (gleiche Autorität wie Locked Decisions):

- **Perl >= 5.10**, LMS Plugin API only, **keine externen CPAN-Deps** — nur LMS-bundled Module (JSON::XS, URI, Digest, MIME::Base64, etc.)
- **Windows-Kompatibilität PFLICHT** (LMS läuft auch auf Windows): kein `cfg(unix)` in Perl, `File::Spec` für Pfade, `Proc::Background` statt `fork`, `main::ISWINDOWS`-Guards. Soloist selbst ist Linux-only — jeder Soloist-Pfad muss auf Windows sauber no-oppen, nicht sterben.
- **SimpleAsyncHTTP** für alle HTTP-Calls im Plugin-Kontext (nie LWP blocking)
- **Zentrale Throttle** — alle Web-API-Requests durch `API/Client.pm` (relevant für #135 Option A, das den shared rate pool belastet)
- **Player/playback state: nie cachen (TTL 0)**
- **i18n:** neue Strings in **allen 11 Sprachen** (CS/DA/DE/EN/ES/FR/IT/NL/NO/PL/SV — PL nicht FI) echt übersetzen, nie EN-Fallback
- **Code comments + forum replies: English**; user-facing German
- **Kein Auto-Release, keine eigenmächtige Versionsnummer** — mit User abstimmen
- **Branching:** `git.branching_strategy: none` → nur `soloist`/`main`, keine Phase-Branches

## Summary

Phase 76 ist ein **Stabilisierungs- + Integrations-Sprint**, kein Greenfield. Vier Cluster: (1) Connect-Bug-Fixes an bestehendem Perl/Rust-Code, (2) FLAC24-Audio-Pipeline (die eigentliche Neu-Entwicklung), (3) Live-UAT der bisher nur statisch verifizierten Phasen 73/75, (4) Browse/UX-Fixes. Der überwältigende Teil des Wissens liegt **im Repo** — die richtige Recherche ist Code-Reading, nicht Web-Suche.

**Das architektonische Herzstück ist die FLAC24-Pipeline.** Die aktuelle Kette endet in `fake-libpulse.c::_convert_and_push()`, die jedes Sample-Format destruktiv auf **S16LE** herunterrechnet (FLOAT32→s16 via `*32767`, S32→s16 via `>>16`) — das vernichtet 8 Bit (48 dB) Dynamik. Der Ring-Buffer, die HTTP-Header (`audio/L16`), die Timing-Mathematik und `RING_BYTES_PER_SEC` sind **alle auf 2 Bytes/Sample hartverdrahtet**. Der Umbau auf 24-bit ist deshalb keine Ein-Zeilen-Änderung, sondern berührt fünf zusammenhängende Stellen in der C-Datei plus vier Perl/Conf-Integration-Punkte.

**Empirisch getestet und bestätigt (diese Session, mit den LMS-bundled Binaries):** Die Transcoding-Kette `S32LE raw → [sox] → FLAC -b 24` funktioniert mit `sox 14.4.3` + `flac 1.3.4` fehlerfrei, auch über eine non-seekable Pipe (24-bit precision im Output verifiziert). Das umgeht das in Phase 72/73 dokumentierte Problem, dass `flac --bps=32` von der bundled flac-Version abgelehnt wird — **sox** (nicht das flac-Binary direkt) macht die Raw→FLAC-Konversion. MP3 via `lame -r --bitwidth 32` funktioniert ebenfalls.

**Primary recommendation:** fake-libpulse auf **S32LE** umbauen (nicht S24LE/S24_3LE — 4-Byte-Container ist der natürliche Landepunkt für Soloists float32-Output und trivial für sox), `ProtocolHandler` `samplesize(32)` melden, `soc flc * *`-Regel via **sox** (`-b 32` raw in, `-t flac -C 0 -b 24` out), `resolvePassthroughForClient()` einen Soloist-Branch geben (`flc ∈ formats` → FLAC), OGG im Dropdown per JS ausblenden. Bug-Fixes und Live-UAT laufen parallel dazu.

**⚠️ Kritischer Blocker-Befund (siehe Pitfall 6):** Der spoton-helper `patch` (FLAC24-Enum + Lifetime) ist in öffentlichen Builds ein **No-Op** — die private Pattern-Tabelle wird via CI-Secrets injiziert, und `gh secret list` zeigt, dass `SPOTON_PRIVATE_PATTERNS_TOKEN`/`SPOTON_PRIVATE_PATTERNS_REPO` **nicht konfiguriert** sind. „patch verdrahten" (ROADMAP-Item 3) heißt praktisch: den Aufruf-Pfad fertigstellen und fail-open lassen — der *tatsächliche* FLAC24-Enum-Effekt bleibt unverifizierbar bis Secrets/Private-Repo existieren. Die fake-libpulse-Resolution-Kette liefert aber unabhängig davon 24-bit-Container-Qualität aus Soloists float32-Output.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Audio-Sample-Auflösung (float32→S32LE) | fake-libpulse (C) | — | Soloist schreibt via `pa_stream_write` in den Shim; hier entscheidet sich die Bit-Tiefe. Nirgends sonst. |
| PCM→FLAC/MP3 Transcoding | LMS TranscodingHelper (sox/flac/lame) | custom-convert.conf | LMS wählt die convert-Regel capability-basiert; SpotOn liefert nur die Regeln + Format-Hints. |
| Format-Auswahl (auto/pcm/flac/mp3) | DaemonManager.pm (`resolvePassthroughForClient`) | ProtocolHandler.pm | Single source of truth für Format-Resolution; ProtocolHandler konsumiert für canDirectStream/formatOverride. |
| Player-Capability-Matching | LMS core (`CapabilitiesHelper::supportedFormats`) | — | LMS iteriert Player-`formats()`, matched gegen convert-Regeln. SpotOn muss nichts erkennen. |
| Connect-Command-Direction (LMS→Spotify) | Connect.pm (`_sendControlCommand`) | SoloistWS / Client.pm (Web API fallback) | Backend-dispatch bereits verdrahtet (Phase 73); Bugs #158/#159 liegen unter dieser Ebene (Rust /control handler + Spirc-State). |
| Connect-Session-Lifecycle (power, autoplay) | Connect.pm (spottyconnect handler) | Slim::Control::Request | Session start/end events sind der Ort für Power-Restore (#151) und Autoplay-Suppression. |
| Daemon-Health / Restart-Gating | DaemonManager.pm (`_onHealthResponse`) | — | #149-Fix sitzt hier (idle-guard); #150 in Credentials.pm classifier. |
| Sync-Group Buffer-Tuning (#131) | DaemonManager.pm (spawn args) | librespot-spoton main.rs (`--buffer-latency-ms`) | CLI-Flag existiert; DaemonManager muss ihn für synced masters erhöhen. |
| Browse Menü-Semantik (#161/#94) | Plugin.pm (`_trackItem`, feed `type`) | LMS XMLBrowser / Menu::TrackInfo | Reine OPML-Attribut-/Provider-Fragen, LMS-idiomatisch. |
| Connect-Queue (#135) | Connect.pm (neu) | Client.pm (Web API) / librespot fork (Spirc events) | Zwei Optionen mit stark unterschiedlichem Lift — siehe Open Questions. |

## Standard Stack

Kein neues Package. Die gesamte Pipeline nutzt ausschließlich LMS-bundled Binaries und -Module.

### Core (Transcoding-Tools)
| Tool | Version (verifiziert) | Purpose | Why Standard |
|------|-----------------------|---------|--------------|
| `sox` (LMS-bundled) | **v14.4.3** `[VERIFIED: /usr/share/squeezeboxserver/Bin/x86_64-linux/sox --version]` | Raw-S32LE→FLAC / →MP3-wav Konversion | LMS liefert sox unter `Bin/<arch>/`; `[sox]` in convert-Regel findet es automatisch. Verarbeitet `s32` raw + `flac` output nativ. |
| `flac` (LMS-bundled) | **1.3.4** `[VERIFIED: bundled flac --version]` | FLAC-Encoder (via sox) / FLAC-Decoder in Standard-Regeln | Bundled. **ABER:** `flac --bps=32` wird abgelehnt (72-RESEARCH Pitfall 2) → Raw→FLAC über **sox** machen, nicht über `flac` direkt. |
| `lame` (Systempaket) | 3.100 `[VERIFIED: lame --version]` | MP3-Encoder | Nicht LMS-bundled, aber in Standard-`convert.conf` referenziert (gleiche Situation wie librespot-MP3). `[lame]`-Token überspringt Regel wenn absent. |

> Hinweis: Die **System**-sox ist v14.4.2, die **bundled** sox v14.4.3. Die convert-Regel nutzt `[sox]` → LMS wählt die bundled Variante. Beide unterstützen `s32`+`flac`; das Empirie-Testergebnis unten wurde mit der bundled sox 14.4.3 erzeugt.

### Supporting (LMS Plugin API — bereits im Einsatz)
| Modul | Purpose | When to Use |
|-------|---------|-------------|
| `Slim::Player::TranscodingHelper` | Wählt convert-Profil per Player-Capability (`{input}-{output}-{player}-{clientid}`) | Verstehen wie `soc flc * *` gegen Player gematcht wird — nicht ändern, nur Regel liefern |
| `Slim::Player::CapabilitiesHelper::supportedFormats` | Sync-Group Format-**Intersection** | FLAC-Sync-Group-Fallback: nur Formate die ALLE Members können |
| `Slim::Control::Request` | power read/execute, playlist play, event dispatch | #151 Power-Restore, Connect autoplay, #135 |
| `Slim::Menu::TrackInfo->registerInfoProvider` | Vollständiges Kontextmenü | #94 Browse-Parität |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| **sox** für Raw→FLAC | `flac` Binary direkt | `flac --force-raw-format --bps=32` von bundled flac 1.3.4 abgelehnt (72-RESEARCH Pitfall 2); sox umgeht das komplett `[VERIFIED: empirical test this session]` |
| **S32LE** Ausgabeformat | S24_3LE (packed 3-byte) | S24_3 spart 25% Bandbreite, aber PA-Enum `PA_SAMPLE_S24_32LE`/`S24LE` erfordert Byte-Packing-Logik im Shim; float32→s32 ist ein einzeiliger Cast. Bandbreite lokal (localhost) unkritisch. |
| **S32LE** | float32 durchreichen (`f32`) | LMS `strm` PCM-Pfad kennt kein f32; sox könnte, aber Player erwarten integer PCM. S32 ist der idiomatische High-Res-PCM-Weg in LMS (`pcm_sample_sizes` kennt 8/16/24/32). |
| #135 **Spirc events** (Option B) | Web API poll (Option A) | Option A ist rein Perl-seitig + sofort machbar, belastet aber den shared 30s-Rate-Pool und ist nur poll (Lag). Option B ist event-driven, braucht aber 2 librespot-PR-Cherry-Picks (#1676/#1677) + Rust→Perl-Channel-Erweiterung. Siehe Open Question. |

**Installation:** Keine. `npm/pip/cargo`-Install entfällt — reine LMS-bundled Tools. **Package Legitimacy Audit daher N/A** (kein externes Package installiert; sox/flac/lame kommen mit LMS bzw. dem OS).

## Architecture Patterns

### System Architecture Diagram — FLAC24 Audio-Pipeline (Ziel-Zustand)

```
Spotify CDN (encrypted, ≤24-bit source)
        │
        ▼
  Soloist Decoder ──── float32 samples ────► pa_stream_write()
   (in-process)                                     │
                                                     ▼
                          fake-libpulse.so  _convert_and_push(fmt, data, n)
                                                     │
                    ┌────────────────────────────────┤  ◄── CHANGE: float32 → S32LE
                    │  Ring Buffer (g_ring)           │      (statt → S16LE)
                    │  RING_BYTES_PER_SEC=44100*4*2   │  ◄── CHANGE: war *2*2
                    └────────────────────────────────┤
                                                     ▼
                          HTTP /stream server (Content-Type header)  ◄── CHANGE: audio/L16 → raw/L24-aware
                                                     │
                              GET http://host:port/stream
                                                     ▼
                        ┌──── LMS ProtocolHandler.pm ────┐
                        │  formatOverride() → 'soc'       │  samplesize(32) hint  ◄── D-08
                        │  canDirectStream / new() proxy  │
                        └──────────────┬──────────────────┘
                                       ▼
                     LMS TranscodingHelper — matcht Player-formats()
                    ┌──────────────────┴───────────────────┐
                    ▼                                       ▼
       Player meldet 'flc'                     Player meldet NUR 'pcm'
       (z.B. squeezelite)                      (kein flc)
            │                                        │
   soc flc * *  (NEU)                         soc pcm * *  (bestehend, passthrough '-')
   [sox] raw s32 → flac -b24                  raw S32LE PCM direct
            │                                        │
            ▼                                        ▼
      FLAC24 an Player                        S32LE PCM an Player
```

Format-Resolution-Entscheidung (D-06), analog zur bestehenden librespot-OGG-Idiomatik:

```
resolvePassthroughForClient($client)  [DaemonManager.pm]
   backend == 'soloist' ?
       ├─ streamFormat == 'flac'         → FLAC   (explizit)
       ├─ streamFormat == 'pcm'          → PCM    (explizit)
       ├─ streamFormat == 'mp3'          → MP3    (explizit)
       └─ streamFormat == 'auto'/undef   → flc ∈ $c->formats() ? FLAC : PCM
   backend == 'librespot' ? (bestehend)
       └─ auto → ogg ∈ formats() && passthrough-capable ? OGG : PCM
```

> **Wichtig:** `resolvePassthroughForClient()` gibt heute nur 0/1 (OGG-passthrough ja/nein) zurück und **short-circuited bei soloist auf 0** (`DaemonManager.pm:113` `[VERIFIED: Plugins/SpotOn/Unified/DaemonManager.pm:113]`). Der Soloist-Branch braucht eine **mehr-Wert-Semantik** (pcm/flac/mp3), nicht nur boolean. Der Planner muss klären, ob das über einen zweiten Resolver läuft oder ob der bestehende Boolean-Contract erweitert wird — die librespot-Aufrufer (`--passthrough` flag, `formatOverride`) erwarten weiter 0/1. Sauberster Weg: ein neuer `resolveSoloistFormat()` neben dem bestehenden, ProtocolHandler/canDirectStream verzweigt per backend.

### Recommended change map (files → responsibility)

```
Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c   # S32LE ring + HTTP header + timing math (D-04)
Plugins/SpotOn/custom-convert.conf                 # + soc flc * *  (+ optional soc mp3 * *) (D-05)
Plugins/SpotOn/ProtocolHandler.pm §631-645         # samplesize(32) statt (16) (D-08)
Plugins/SpotOn/Unified/DaemonManager.pm §105-155   # Soloist-Format-Branch (D-06)
Plugins/SpotOn/HTML/EN/.../settings/player.html §42-50  # OGG-Option per JS ausblenden bei backend=soloist (D-07)
Plugins/SpotOn/Soloist.pm _autoPatch (§446)        # patch schon verdrahtet — Daemon-Start nutzt gepatchtes Binary
Plugins/SpotOn/Plugin.pm strings/i18n              # ggf. Format-Label-Anpassung, 11 Sprachen
```

### Pattern 1: `soc flc * *` convert-Regel (sox-basiert)

**What:** Raw S32LE PCM vom fake-libpulse `/stream` → FLAC 24-bit an FLAC-fähige Player.
**When to use:** Player meldet `flc` in `formats()` (LMS wählt automatisch, D-05).
**Example (empirisch getestet, funktioniert mit bundled sox 14.4.3):**
```conf
# custom-convert.conf — Reihenfolge egal, LMS merged nach {in}-{out}-{player}-{id}
soc flc * *
	# IFT:{START=--skip=%t}U:{END=--until=%v}
	[sox] -q -t raw --encoding signed-integer --bits 32 --endian little -r 44100 -c 2 - -t flac -C 0 -b 24 -
```
> `-C 0` = compression level 0 (schnellste Encodierung, für Echtzeit-Stream wichtig — Standard-`convert.conf` nutzt `-C 0` in allen live-flac-Regeln). `-b 24` cast von 32→24 (die unteren 8 Bit sind float-Rundungsrauschen, praktisch verlustfrei). `$SAMPLESIZE$` ließe sich statt hartem `32`/`24` nutzen, wenn ProtocolHandler `samplesize(32)` meldet — aber der Input ist immer 32 und der FLAC-Ziel-Wert 24, deshalb sind Literale hier robuster.

`[VERIFIED: empirical test this session — 1s S32LE sine → sox → flac -b24 over non-seekable pipe, output "Precision: 24-bit / Sample Encoding: 24-bit FLAC", flac -t decode ok]`

### Pattern 2: `soc mp3 * *` (optional, für D-07 MP3-Option)
```conf
soc mp3 * *
	# IFB:{BITRATE=--abr %B}
	[lame] --silent -r --little-endian --signed --bitwidth 32 -s 44.1 -q 2 $BITRATE$ - -
```
`[VERIFIED: empirical test — lame -r --bitwidth 32 raw S32LE → mp3, rc=0]`. `[lame]`-Token überspringt die Regel sauber wenn lame fehlt → Player fällt auf `soc pcm` zurück (gleiche Idiomatik wie librespot).

### Pattern 3: Sync-Group Format-Aggregation (FLAC)
LMS `CapabilitiesHelper::supportedFormats` liefert nur Formate die **alle** Sync-Members können (`$formatcounter{$format} == @playergroup`) `[VERIFIED: /usr/share/perl5/Slim/Player/CapabilitiesHelper.pm:38-58]`. Wenn ein Member kein `flc` kann, wählt LMS automatisch `soc pcm`. Das bestehende manuelle Sync-Aggregations-Muster in `resolvePassthroughForClient` (Zeile 140-153, PCM-Fallback wenn ANY member kein OGG) muss für FLAC gespiegelt werden — **aber** LMS macht die eigentliche Regel-Auswahl schon selbst; die Perl-Aggregation dient nur der korrekten `formatOverride`/`--passthrough`-Anzeige.

### Pattern 4: Connect autoplay-on-restart Suppression
Der `start`-handler in `Connect.pm` (§1018) issued unbedingt `playlist play spoton://connect-<ts>` `[VERIFIED: Plugins/SpotOn/Connect.pm:1018-1056]`. Nach einem LMS-Restart kann ein persistierter Connect-State ein ungewolltes Autoplay auslösen. Fix-Ansatz: den `start`-handler gaten, wenn kein *frischer* User-/App-Trigger vorliegt (z.B. `connectStartTime`-Prüfung oder ein „session was restored, not initiated"-Flag).

### Anti-Patterns to Avoid
- **Ring weiter S16LE lassen und erst in der convert-Regel upsampeln:** sinnlos — die 8 Bit sind bei `>>16` bereits weg. Die Auflösung MUSS im Shim erhalten bleiben.
- **`flac --bps=32` direkt aufrufen:** von bundled flac 1.3.4 abgelehnt (dokumentiert 72-RESEARCH Pitfall 2, Phase-73 CR-02). Immer sox davor.
- **Manuelle Player-Typ-Erkennung für FLAC vs. PCM:** verboten per D-05. LMS matcht `formats()` selbst.
- **Web-API-Queue-Poll (#135 Option A) in kurzen Intervallen:** belastet den zentralen 30s-Rate-Pool (CLAUDE.md P-01/NFL-03). Falls überhaupt Option A, dann nur on-demand/langsam.
- **fake-libpulse-Änderung ohne C-Host-Test:** `make -C Plugins/SpotOn/Bin/fake-libpulse test` (6 Assertions inkl. Conversion+Clamping) muss grün bleiben und um S32-Assertions erweitert werden.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| S32→FLAC/MP3 Encoding | Eigener Encoder in C/Perl | `[sox]`/`[lame]` convert-Regel | LMS-Transcoding-Framework macht Streaming, Seek (`--skip`/`--until`), Rate-Limit, Prozess-Management |
| Player-FLAC-Capability-Check | Eigene Player-DB / User-Agent-Parsing | `$c->formats()` + LMS `supportedFormats` | LMS kennt jede Player-Capability schon; manuell = Fehlerquelle |
| Sync-Group Format-Intersection | Eigene Member-Iteration | `CapabilitiesHelper::supportedFormats` | LMS liefert die Intersection fertig |
| Power-State Save/Restore (#151) | Eigenes State-File | `Slim::Control::Request::executeRequest($client,['power'])` read + Connect-lifecycle-hook | LMS hält Power-State; ShairTunes-Muster ist etabliert |
| Kontextmenü-Parität (#94) | itemActions in `_trackItem` von Hand erweitern | `Slim::Menu::TrackInfo->registerInfoProvider` | Ein registrierter Provider erscheint in BEIDEN Menüs; itemActions dupliziert nur |
| MP3/FLAC Bit-Tiefe an Player melden | Eigene `strm`-Frame-Manipulation | `$track->samplesize()` → LMS `pcm_sample_sizes` | LMS mappt 8/16/24/32 → strm-Byte automatisch (`Squeezebox.pm:1129`) |

**Key insight:** Fast alles außer der fake-libpulse-Resolution-Änderung ist reine **Konfiguration + Format-Hints**. Die einzige echte Neu-Implementierung ist der C-seitige S32LE-Umbau; der Rest ist „LMS die richtigen Signale geben und LMS entscheiden lassen".

## Runtime State Inventory

> Phase 76 ist überwiegend Bug-Fix + neues Feature, kein Rename. Es gibt aber persistente/Runtime-State-Aspekte, die den FLAC24-Umbau und die Live-Verifikation betreffen:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Per-Player prefs `streamFormat` (auto/ogg/pcm/flac/mp3) — bereits implementiert, nur Soloist-Semantik fehlt. `spak.key` in `cache/spoton/soloist/`. | Code edit (Resolver), kein Daten-Migration |
| Live service config | Cache-Keys `spoton_soloist_expiry_days`, `spoton_soloist_expired` (TTL 'never') aus Phase 73. **fake-libpulse Binary** `libpulse.so.0` unter `Bin/<arch>/` — muss nach S32-Umbau **neu gebaut** werden (CI `build-fake-libpulse.yml`). | Rebuild C-Binary via CI + lokal für Test |
| OS-registered state | Keine (Soloist-Daemon ist Proc::Background, kein systemd/Task Scheduler). | None — verifiziert: SoloistDaemon nutzt tempfile + Proc::Background |
| Secrets/env vars | **CI-Secrets `SPOTON_PRIVATE_PATTERNS_TOKEN`/`SPOTON_PRIVATE_PATTERNS_REPO` NICHT gesetzt** (`gh secret list`) → spoton-helper patch = no-op in Released Builds. `LD_LIBRARY_PATH` env für Soloist-Launcher (Phase 72). | Blocker dokumentieren (siehe Pitfall 6); Secrets sind out-of-band Setup |
| Build artifacts | `spoton-helper` Binary **NICHT im Working Tree** (`Plugins/SpotOn/Bin/*/spoton-helper` fehlt) — kommt aus CI-Release. Lokales `cache/spoton/soloist/spoton-soloist` (gepinnt 1.3.7.489) existiert, ungepatcht. | Für Live-UAT ggf. spoton-helper lokal bauen; Patch-Effekt separat prüfen |

**Kanonische Frage beantwortet:** Nach dem S32-Umbau der C-Datei ist das **kompilierte `libpulse.so.0`** der Runtime-State, der nicht automatisch aus dem Source-Rename folgt — es muss neu gebaut und deployed werden, sonst läuft der alte S16-Shim weiter.

## Common Pitfalls

### Pitfall 1: 8s Reconnect-Gap — Ring wird nicht entleert nach flush-disconnect (WINDOWS #5, D-12)
**What goes wrong:** Nach App-Skip switcht LMS-Metadata in ~1.16s, aber der Ring-`read_index` friert **8.000s** ein (`write_index` steigt weiter), Audio bleibt stumm, Spotify-Progress-Bar friert.
**Why it happens (Hypothese, NICHT bestätigt):** Zwischen `flush-disconnect` (alter HTTP-Client geschlossen) und dem Zeitpunkt, an dem LMS einen **neuen** GET auf `/stream` für die `spoton://connect-<ts>`-URL öffnet, vergeht LMS-seitige Stream-Aufbau-Latenz. Der Ring füllt sich weiter (Soloist schreibt), aber niemand liest.
**How to avoid / Debug-Ansatz (D-12):** Instrumentiere die Zeit zwischen `playlist play spoton://connect-*` (Connect.pm) und erstem HTTP-GET am fake-libpulse-`/stream`. Prüfe: (a) verzögert LMS den neuen Stream-Request (Buffer-Drain der alten Song-Instanz)? (b) hilft es, den Ring beim flush-disconnect **zu leeren** (`_ring_flush` im disconnect-Pfad, nicht nur bei `pa_stream_flush`)? Aktuell wird beim flush-disconnect nur der Client geschlossen, der Ring aber NICHT geleert (`fake-libpulse.c:468 _ring_flush` existiert, wird aber im disconnect-Pfad evtl. nicht gerufen). Wenn der Ring beim disconnect voll bleibt, serviert der neue Client zuerst 8s **alte** Samples bevor er zu Live-Audio aufschließt — das erklärt den Freeze exakt.
**Warning signs:** `read_index` konstant, `write_index` steigt, im Daemon-Log `flush-disconnect: closed active HTTP client` gefolgt von langer Stille bis „new client attached".
**Soft-Blocker (D-13):** Wenn nach ernsthaftem Versuch nicht lösbar → Known Issue + Workaround dokumentieren, v4.0 kann leben.

### Pitfall 2: fake-libpulse S16→S32 berührt FÜNF gekoppelte Stellen, nicht nur `_convert_and_push`
**What goes wrong:** Man ändert nur die Konversion und der Rest bleibt auf 2 Bytes/Sample → Timing/Position kaputt, halbe Geschwindigkeit oder Rauschen.
**Why it happens:** S16LE ist hart verdrahtet an: (1) `_convert_and_push` (§484) `[VERIFIED: fake-libpulse.c:484-526]`, (2) HTTP-Header `Content-Type: audio/L16;rate=44100;channels=2` (§597) `[VERIFIED: fake-libpulse.c:597-599]`, (3) `RING_BYTES_PER_SEC (44100*2*2)` (§1100) `[VERIFIED: fake-libpulse.c:1099-1100]`, (4) Timing-Math `input_bps`/`fill_input` (§1129-1136) `[VERIFIED: fake-libpulse.c:1124-1136]`, (5) `_stream_refresh_timing`-Kommentar „Output side (ring) is always S16LE".
**How to avoid:** Alle fünf konsistent auf S32LE (4 Bytes/Sample) ziehen. `_convert_and_push` FLOAT32→S32: `(int32_t)lrintf(clamp(f,-1,1) * 2147483647.0f)`. `RING_BYTES_PER_SEC` → `44100*4*2`. Nach dem Umbau ist Ring-Format == Input-Format (float32→s32 sind beide 4-byte), also `fill_input = fill` (kein `*input_bps/2` mehr). C-Host-Test um S32-Assertions erweitern.
**Warning signs:** Doppelte/halbe Wiedergabegeschwindigkeit, Progress-Bar läuft doppelt so schnell/langsam, weißes Rauschen.

### Pitfall 3: `resolvePassthroughForClient` ist Boolean, FLAC braucht drei Werte
**What goes wrong:** Man versucht FLAC in den bestehenden 0/1-Return zu quetschen und bricht den librespot-`--passthrough`-Pfad.
**Why it happens:** Der Contract ist heute „1 = OGG-passthrough, 0 = PCM" und wird von `Daemon.pm` (`--passthrough` flag) UND `formatOverride` konsumiert `[VERIFIED: DaemonManager.pm:102-104]`.
**How to avoid:** Separater `resolveSoloistFormat()` (returns 'pcm'/'flac'/'mp3'), ProtocolHandler verzweigt per `backend`. Der bestehende Boolean bleibt für librespot unverändert. `RING_CAPACITY` verdoppelt sich in Bytes bei gleicher Sekunden-Kapazität — Speicher (aktuell 352800*10 = 3.5MB → 7MB) unkritisch.

### Pitfall 4: #158 Group-Player-Crash interagiert mit dem skipInitiated-Fix (QT 260827-of9)
**What goes wrong:** Auf Sync-Groups: pause→skip→play führt zu „song starts over and over" (Endlos-Reload).
**Why it happens (zu untersuchen):** Der Skip-Fix (QT 12) issued `playlist play spoton://connect-<ts>` bei skipInitiated. Auf Sync-Groups läuft Connect über die `new()`-Proxy (nicht direct stream), und das flush-disconnect + playlist-play-Muster kann mit der Sync-Group-Rebuffer-Logik (`_Rebuffer` pausiert die ganze Gruppe) kollidieren.
**How to avoid:** #158 und #131 zusammen betrachten — beide sind Sync-Group + Connect. #131 hat konkreten Fix (`--buffer-latency-ms` erhöhen für synced masters, Flag existiert `[VERIFIED: librespot-spoton/src/main.rs:196]`). #158 braucht eigene Reproduktion mit dem beigefügten Diag-Log.

### Pitfall 5: #159 — `/control/*` gibt success zurück obwohl Spirc inaktiv
**What goes wrong:** Nach Connect-Deselect im Pause-Zustand: LMS glaubt `play` war erfolgreich (`NO_CONTENT`), geht in `BUFFERING-STREAMING` und hängt dort permanent.
**Why it happens:** Der Rust `/control`-Handler mappt `(false, "play")` (= Spirc lehnte ab weil „Not Active") trotzdem auf `StatusCode::NO_CONTENT` `[VERIFIED: librespot-spoton/src/unified.rs:1217-1226]`. LMS unterscheidet nicht zwischen „ausgeführt" und „ignoriert weil nicht aktiv".
**How to avoid:** Der `(false, play|pause|next|prev)`-Arm muss einen distinkten Status (z.B. `409 Conflict`) zurückgeben, damit Connect.pm/LMS den Stream stoppen/ejecten statt zu buffern. **Rust-Änderung** → librespot-spoton neu bauen. Vorsicht: darf normale (aktive) Commands nicht brechen.

### Pitfall 6: spoton-helper `patch` ist No-Op ohne private Pattern-Tabelle — FLAC24-Enum-Effekt unverifizierbar
**What goes wrong:** ROADMAP-Item „spoton-helper patch tatsächlich verdrahten" suggeriert, dass FLAC24-Patching nach dem Verdrahten funktioniert — aber die Pattern-Tabelle ist in öffentlichen Builds **leer**.
**Why it happens:** `patterns.rs` ist ein bewusst leerer Stub (`sites_for` gibt für jede Arch eine leere Tabelle → `patch` meldet `status: "unsupported"`, no-op) `[VERIFIED: spoton-helper/src/patch/patterns.rs:1-40]`. Die echten Byte-Patterns werden zur CI-Build-Zeit aus einem privaten Repo injiziert (`build-librespot.yml:353-364`) `[VERIFIED: .github/workflows/build-librespot.yml:353-364]`. `gh secret list` zeigt: **weder `SPOTON_PRIVATE_PATTERNS_TOKEN` noch `SPOTON_PRIVATE_PATTERNS_REPO` existieren** `[VERIFIED: gh secret list this session — only ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN]`. Zusätzlich ist im Working Tree **gar kein** `spoton-helper`-Binary vorhanden `[VERIFIED: ls Plugins/SpotOn/Bin/*/spoton-helper — empty]`.
**How to avoid / Scope-Klärung:** „patch verdrahten" in Phase 76 bedeutet realistisch: den Aufruf-Pfad (`Soloist.pm::_autoPatch` → Daemon-Start nutzt gepatchtes Binary) vervollständigen und **fail-open** halten (bereits so gebaut, §459-461). Der *tatsächliche* FLAC24-Enum-Downgrade-Effekt (holt Soloist 24-bit vom CDN?) bleibt **unverifizierbar**, bis (a) das private Pattern-Repo + CI-Secrets eingerichtet sind ODER (b) lokal mit privaten Patterns gebaut wird. **Das ist kein Phase-76-Blocker für die Pipeline** — die fake-libpulse-S32-Kette liefert 24-bit-Container aus Soloists float32-Output unabhängig vom Enum-Patch (die Lifetime-Patch-Abhängigkeit ist separat, betrifft Build-Ablauf nicht Audio). Aligned mit Phase-74 D-06 „best effort, Effekt in Phase 77 UAT verifizieren".
**Warning signs:** `spoton-helper check` meldet `patched: false` / `status: unsupported`; Soloist läuft „unpatched" (Warning im Log), Audio funktioniert trotzdem.

### Pitfall 7: Live-UAT braucht `--remote-allow-origins=*` für Spotify-Desktop-CDP
**What goes wrong:** CDP-getriebenes UAT (spotify-control skill) schlägt mit `403 Forbidden` beim WebSocket-Handshake fehl.
**Why it happens:** Spotify Desktop lehnt CDP-WS ohne `--remote-allow-origins=*` ab; ein vorher ohne Flag gestarteter Prozess muss `kill -9` (nicht `pkill -f`) `[VERIFIED: 260827-of9-SUMMARY.md Deviations]`.
**How to avoid:** Spotify mit `--remote-debugging-port=... --remote-allow-origins=*` starten. Der `spotify-control` skill referenziert `tools/spotify-cdp.js`, das evtl. fehlt → Python `websocket-client`-Fallback für `Runtime.evaluate`.

## Code Examples

### fake-libpulse: FLOAT32 → S32LE Konversion (Ziel, ersetzt §492-509)
```c
// Source: fake-libpulse.c current _convert_and_push (S16 version), scaled to 32-bit
if (fmt == PA_SAMPLE_FLOAT32LE) {
    size_t nsamples = nbytes / sizeof(float);
    const float *src = (const float *)data;
    int32_t stackbuf[1024];
    size_t i = 0;
    while (i < nsamples) {
        size_t batch = nsamples - i; if (batch > 1024) batch = 1024;
        for (size_t j = 0; j < batch; j++) {
            float f = src[i + j];
            if (f > 1.0f) f = 1.0f; if (f < -1.0f) f = -1.0f;
            stackbuf[j] = (int32_t)lrintf(f * 2147483647.0f);   // was 32767.0f → int16
        }
        _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int32_t));
        i += batch;
    }
    return;
}
// PA_SAMPLE_S32LE: now the native ring format → memcpy passthrough (was >>16 to s16)
if (fmt == PA_SAMPLE_S32LE) {
    _ring_push(&g_ring, (const unsigned char *)data, nbytes);
    return;
}
```
> Werte `2147483647` (INT32_MAX), `sizeof(int32_t)`, `RING_BYTES_PER_SEC = 44100*4*2` sind die neuen Konstanten. Die S16LE-Passthrough-Sonderbehandlung (§485) entfällt bzw. wird zur S32-Passthrough.

### soc flc convert-Regel (getestet)
```conf
soc flc * *
	# IFT:{START=--skip=%t}U:{END=--until=%v}
	[sox] -q -t raw --encoding signed-integer --bits 32 --endian little -r 44100 -c 2 - -t flac -C 0 -b 24 -
```

### ProtocolHandler samplesize-Hint (§642)
```perl
# D-08: fake-libpulse now emits S32LE (24-bit content in 32-bit container)
$track->samplesize(32)    if $track->can('samplesize');   # was 16
$track->samplerate(44100) if $track->can('samplerate');
$track->channels(2)       if $track->can('channels');
```
> LMS `pcm_sample_sizes` mappt `32 => '3'` im strm-Frame `[VERIFIED: Squeezebox.pm:1129-1133]`. Für den FLAC-Pfad liest LMS die Bit-Tiefe aus dem FLAC-Header (`flc` → `pcmsamplesize='?'` `[VERIFIED: Squeezebox.pm:635-641]`), der Hint zählt v.a. für den direkten PCM-Pfad und `$SAMPLESIZE$`-Substitution.

### #161 flat-track-list als playlist markieren (Plugin.pm)
```perl
# Recently Played & Liked Songs führen direkt zu flacher Trackliste → type 'playlist'
name  => cstring($client, 'PLUGIN_SPOTON_LIKED_SONGS'),
url   => \&_savedTracksFeed,
type  => 'playlist',   # war 'link' → aktiviert Play All / Add to Queue in Material Skin
```
> Made For You bleibt `'link'` (führt zu Playlist-Liste, nicht direkt zu Tracks) `[CITED: GH #161 issue body]`.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Soloist Browse per-track `sol`-Transcoder | Persistent daemon `/stream` (Modell B, `soc`-Familie) | Phase 73 | S32-Umbau betrifft EINEN Stream-Pfad, nicht per-track |
| `flac --bps=32` direkt | `sox` raw→flac Konversion | Phase 76 (dieser Research) | Umgeht bundled-flac-1.3.4-Ablehnung |
| fake-libpulse S16LE-only | S32LE High-Res | Phase 76 (D-04) | 24-bit-Container-Qualität möglich |
| #149 unconditional restart | idle-guard (idle_secs≤30 defer) | QT 260817-ana | Nur noch Live-Verifikation offen |

**Deprecated/outdated:**
- Phase 72 `sol`/`son`-per-track-Regeln: entfernt (Phase 73). `custom-types.conf` hat nur noch `son`+`soc` `[VERIFIED: custom-types.conf]`.
- `custom-convert.conf` aktuell nur `soc pcm * *` + `son ogg * *` `[VERIFIED: custom-convert.conf]` — `soc flc` ist neu.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | S32LE ist gegenüber S24_3LE/S24_32LE das beste Ausgabeformat | Standard Stack / D-04 | Niedrig — reversibel; S32 ist LMS-idiomatisch, Bandbreite localhost unkritisch |
| A2 | Der 8s-Gap wird durch nicht-geleerten Ring beim flush-disconnect verursacht | Pitfall 1 | Mittel — Hypothese, nicht bestätigt; D-12/D-13 erlauben explizit Soft-Blocker wenn nicht lösbar |
| A3 | `flac -b 24` von 32-bit-sox-Input ist praktisch verlustfrei (untere 8 Bit = float-Rauschen) | Pattern 1 | Niedrig — Soloist-Quelle hat ≤24-bit echte Präzision |
| A4 | Soloist emittiert float32 (nicht nativ S32) | fake-libpulse-Umbau | Niedrig — Phase-72-UAT bestätigte float32; _convert_and_push hat beide Pfade |
| A5 | #135 Option B (Spirc events) ist der langfristig richtige Weg trotz größerem Lift | Open Questions | Niedrig — User (Issue-Autor) präferiert selbst B; Entscheidung offen |
| A6 | Lifetime-Patch-No-Op blockiert den Daemon-Start nicht (fail-open) | Pitfall 6 | Niedrig — `_autoPatch` ist unconditional fail-open `[VERIFIED: Soloist.pm:459-461]` |
| A7 | #158 hängt mit dem skipInitiated/Sync-Group-Proxy-Pfad zusammen | Pitfall 4 | Mittel — braucht Reproduktion mit dem beigefügten Diag-Log |

## Open Questions

1. **#135 Connect-Queue: Option A (Web API poll) vs. Option B (Spirc events)? (RESOLVED — Plan 76-06)**
   - Was wir wissen: Option A funktioniert heute mit bundled Client ID (`GET /me/player/queue`), rein Perl. Option B braucht librespot-PR #1676+#1677 Cherry-Picks + Rust→Perl-Channel-Erweiterung.
   - **Auflösung (Planner):** Plan 76-06 shippt Option A in rate-sicherer Form — ON-DEMAND only, ein Request pro Menü-Öffnung, nie gepollt. Das umgeht den Rate-Pool-Einwand des Issue-Autors (der zielt auf wiederkehrende Calls) und funktioniert für BEIDE Backends. Option B bleibt als kompatibles Phase-77+-Layering erhalten (event-getriebener Refresh desselben Feeds) und wird durch 76-06 nicht verbaut.
   - **Offener Rest:** Die Option-A-Wahl wird beim Phase-76-UAT dem User zur Absegnung vorgelegt (Issue-Autor-Präferenz war Option B — siehe A5).

2. **`resolvePassthroughForClient` erweitern oder neuer Resolver? (RESOLVED — Plan 76-04)**
   - Was wir wissen: Boolean-Contract von 2 Aufrufern konsumiert (librespot).
   - Empfehlung: Neuer `resolveSoloistFormat()`, ProtocolHandler verzweigt per backend. Planner bestätigt.

3. **8s-Gap Root Cause (D-12) — Ring-leeren löst es oder ist es LMS-Stream-Latenz? (RESOLVED — Plan 76-07)**
   - Was wir wissen: Ring `_ring_flush` existiert, wird beim `pa_stream_flush` gerufen; Frage ob der disconnect-Pfad ihn auch braucht.
   - **Auflösung (Planner):** Genau der empfohlene Instrument-first-Ansatz ist Plan 76-07: Task 1 misst alle fünf Hops (t0 pa_stream_flush → t4 first ring drain, 3 Läufe), Task 2 fixt den identifizierten Hop oder dokumentiert per D-13-Soft-Blocker ein Known Issue (TROUBLESHOOTING + WINDOWS.md-#5-Annotation). Die Root-Cause-Frage wird also nicht vorab entschieden, sondern datengetrieben im Plan aufgelöst.

4. **spoton-helper Live-Patch für UAT verfügbar? (RESOLVED — Plan 76-08)**
   - Was wir wissen: Kein Binary im Tree, keine CI-Secrets, keine lokalen Patterns gefunden.
   - **Auflösung (Planner):** Empfehlung übernommen — Plan 76-08 Task 2 dokumentiert den verifizierten Status im ROADMAP-Eintrag (Wiring seit 74-04 komplett, fail-open, t/33-gedeckt; öffentliche Builds mit leerer Pattern-Tabelle, Secrets `SPOTON_PRIVATE_PATTERNS_TOKEN`/`REPO` fehlen). Der FLAC24-Enum-Effekt ist explizit AUS den Phase-76-Erfolgskriterien genommen und auf Phase-77-UAT verschoben; Pipeline-Qualität wird an der fake-libpulse-S32-Kette gemessen. Diese Deferral-Ausnahme zu D-01 („Keine Deferrals") ist umgebungsbedingt (fehlende CI-Secrets) und wird beim UAT-/Verify-Review dem User explizit zur Bestätigung vorgelegt.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| LMS (lyrionmusicserver) | Live-UAT (D-09/D-11) | ✓ | active (systemd) | — |
| squeezelite | FLAC-fähiger Test-Player, UAT | ✓ | v1.9.9-1449 | — |
| sox (bundled) | soc flc/mp3 Regel | ✓ | 14.4.3 (bundled) / 14.4.2 (system) | — |
| flac (bundled) | FLAC encode/decode | ✓ | 1.3.4 | — |
| lame (system) | soc mp3 Regel (D-07) | ✓ | 3.100 | Regel überspringt sich, PCM-Fallback |
| Spotify Desktop | Connect-UAT (CDP) | ✓ | `/usr/bin/spotify` | — |
| gdb | fake-libpulse Debug (8s-Gap) | ✓ | vorhanden | — |
| gcc/make | fake-libpulse Rebuild | (via CI `build-fake-libpulse.yml`) | — | Lokal bauen |
| spoton-helper Binary | FLAC24/Lifetime patch | ✗ | — | Fail-open (Daemon läuft ungepatcht); nicht Audio-blockierend |
| CI-Secrets (private patterns) | Echter FLAC24-Enum-Patch | ✗ | — | Kein Fallback — Enum-Effekt unverifizierbar (Phase 77) |
| squeezelite debug logs | Audio-Level-Verifikation (spoton-uat skill) | ✓ (skill vorhanden) | — | Manuelles Hören |

**Missing dependencies with no fallback:**
- CI-Secrets für private FLAC24-Patterns → FLAC24-Enum-Patch-Effekt bleibt unverifizierbar. **Nicht Pipeline-blockierend** (fake-libpulse-S32-Kette liefert 24-bit-Container unabhängig).

**Missing dependencies with fallback:**
- spoton-helper Binary fehlt im Tree → fail-open, Daemon läuft ungepatcht weiter; für Live-Patch-Test lokal bauen.

## Validation Architecture

> nyquist_validation ist enabled (config.json `workflow.nyquist_validation: true`).

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Perl `Test::More` via `prove` (36 Test-Dateien, live gezählt bei Planning-Verify; Testanzahl wächst mit den Phase-76-Plänen) + C-Host-Test (`make test`, 6 Assertions) |
| Config file | keine — `prove -l t/` Konvention |
| Quick run command | `prove -l t/32_soloist_events.t t/31_soloist_ws.t` (relevante Soloist-Tests) |
| Full suite command | `prove -l t/` + `make -C Plugins/SpotOn/Bin/fake-libpulse test` |
| Phase-Gate | Beide grün vor `/gsd-verify-work`, PLUS Live-UAT (D-11, human) |

### Phase Requirements → Test Map
| Item | Behavior | Test Type | Automated Command | File Exists? |
|------|----------|-----------|-------------------|-------------|
| D-04 fake-libpulse S32 | float32→S32LE Konversion + Clamping | unit (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | ✅ (erweitern um S32-Assertion) |
| D-05 soc flc Regel | Regel parst, sox-Pipeline lauffähig | unit + manual | `prove -l t/03_*.t t/04_*.t` (conf-syntax) + manueller sox-Test | ✅ conf-tests / ❌ Pipeline-Test Wave 0 |
| D-06 Format-Resolver | flc∈formats → flac, sonst pcm | unit | `prove -l t/28_soloist_dispatch.t` (erweitern) | ❌ Wave 0 (neuer Resolver) |
| D-08 samplesize hint | samplesize(32) gesetzt | unit | `prove -l t/29_soloist_browse.t` | ✅ (keine bestehende samplesize-Assertion — neue Assertions ergänzen, nichts anzupassen) |
| #149/#150 | idle-guard / key-timeout classifier | unit (schon grün) | `prove -l t/22_audio_key_classifier.t` | ✅ |
| #159 /control status | (false,play) → distinkter Status | unit (Rust) | `cargo test` in librespot-spoton | ❌ Wave 0 |
| #161 flat-list type | Recently/Liked → type playlist | unit | `prove -l t/` (Plugin.pm feed test) | ⚠️ prüfen ob feed-test existiert |
| Windows 1-4, SpClient smoke | Live E2E | **manual-only** | spoton-uat skill / CDP | N/A (human, D-09) |

### Sampling Rate
- **Per task commit:** relevante `t/`-Datei + (bei C-Änderung) `make test`
- **Per wave merge:** `prove -l t/` full + `make test`
- **Phase gate:** Full suite grün + Live-UAT-Durchlauf (beide Backends, D-11/D-14)

### Wave 0 Gaps
- [ ] C-Host-Test um S32LE-Konversions-Assertion erweitern (`fake-libpulse` test harness)
- [ ] Unit-Test für neuen `resolveSoloistFormat()` (D-06) — flc/pcm/mp3 + sync-group intersection
- [ ] Rust-Test für #159 `/control`-Status-Mapping (falls Rust-Fix)
- [ ] conf-syntax-Test deckt `soc flc`/`soc mp3` Regeln ab (`t/03`/`t/04`)
- [ ] i18n-Test bleibt grün wenn Format-Labels geändert (11 Sprachen, `t/02_strings.t`)

## Security Domain

> `security_enforcement` nicht explizit `false` → Sektion enthalten. Phase 76 hat geringe neue Angriffsfläche (lokales Plugin, kein neuer Netzwerk-Endpunkt).

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | convert-Regel-Werte sind LMS-kontrolliert (`$SAMPLESIZE$` etc.), keine User-Eingabe; `/stream`-URL aus `serverAddr()`+Daemon-Port (kein User-Input, T-05-16) `[VERIFIED: ProtocolHandler.pm:184-186]` |
| V6 Cryptography | no | keine neue Krypto; Audio-Keys serverseitig (unverändert) |
| V2 Auth / V3 Session | no | keine Auth-Änderung in Phase 76 |
| V12 File/Resource | yes | `_runHelperJson` nutzt array-form `open('-|', ...)`, nie shell-string (spak-key-Disziplin) `[VERIFIED: Soloist.pm:417-422]` |

### Known Threat Patterns for LMS-Perl/C-Shim
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Command injection in convert-Regel | Tampering | Nur bekannte `[tool]`-Tokens + LMS-substituierte Platzhalter; keine String-Interpolation von User-Daten |
| Buffer overflow in S32-Ring | Tampering/DoS | `_ring_push`/`_ring_pop_timed` bounds-checken via `capacity`/`fill`; nach S32-Umbau `RING_CAPACITY`-Bytes-Semantik prüfen (Byte- nicht Sample-Zählung) |
| spak-key Leak | Info Disclosure | Nie loggen, nie in argv (bestehende Disziplin, T-74-09) |
| CDP `--remote-allow-origins=*` beim UAT | Elevation | Nur temporär für Test-Instanz; nicht in Produktion |

## Sources

### Primary (HIGH confidence — in-repo / LMS core, read this session)
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` §380-599, §1095-1164 — Ring/Konversion/HTTP/Timing
- `Plugins/SpotOn/Unified/DaemonManager.pm` §90-169 — resolvePassthroughForClient
- `Plugins/SpotOn/ProtocolHandler.pm` §74-309, §600-680 — canDirectStream/formatOverride/samplesize
- `Plugins/SpotOn/Connect.pm` §1008-1057 — start handler / playlist play
- `Plugins/SpotOn/Soloist.pm` §385-465 — _autoPatch fail-open
- `Plugins/SpotOn/custom-convert.conf`, `custom-types.conf` — aktuelle Regeln
- `spoton-helper/src/patch/patterns.rs` §1-40 — empty stub table
- `librespot-spoton/src/unified.rs` §1215-1235 — /control status mapping (#159)
- `librespot-spoton/src/main.rs` §106,196 — --buffer-latency-ms (#131)
- `/usr/share/perl5/Slim/Player/TranscodingHelper.pm` §340-386 — Profil-Matching
- `/usr/share/perl5/Slim/Player/CapabilitiesHelper.pm` §38-58 — supportedFormats intersection
- `/usr/share/perl5/Slim/Player/Squeezebox.pm` §595-642, §1125-1138 — pcm_sample_sizes / flc handling
- `/usr/share/perl5/Slim/Player/Song.pm` §390-449 — getConvertCommand2 flow
- `/etc/squeezeboxserver/convert.conf` — Standard flac/sox/lame-Regel-Syntax
- `.github/workflows/build-librespot.yml` §353-364 — private patterns injection
- `.planning/WINDOWS.md`, `73-VERIFICATION.md`, `260827-of9-SUMMARY.md`, `260817-ana-SUMMARY.md`
- **Empirische Tests (diese Session):** bundled sox 14.4.3 + flac 1.3.4: S32LE raw→FLAC -b24 (auch pipe), lame -r --bitwidth 32→mp3 — alle rc=0, 24-bit verifiziert
- `gh issue view` #159/#158/#151/#150/#149/#135/#131/#128/#94/#161 — Issue-Bodies + Root-Cause-Analysen

### Secondary (MEDIUM confidence)
- Tool-Versionen via `--version` (bundled + system) — verifiziert, aber nicht gegen offizielle Docs quergeprüft
- `gh secret list` — Momentaufnahme; Secrets könnten out-of-band nachträglich gesetzt werden

### Tertiary (LOW confidence)
- 8s-Gap-Root-Cause-Hypothese (A2) — nicht bestätigt, Debug-Auftrag (D-12)

## Metadata

**Confidence breakdown:**
- FLAC24 Pipeline (Stack + Regeln): HIGH — empirisch mit bundled Tools getestet, in-repo Code-Pfade verifiziert
- fake-libpulse S32-Umbau: HIGH — alle 5 gekoppelten Stellen im Code lokalisiert und zitiert
- Connect-Bugs (#159/#158/#131/#128/#151): HIGH für Root-Cause-Lokalisierung (Code + Issue-Logs), MEDIUM für Fix-Wirkung (nicht live reproduziert)
- 8s-Gap: LOW — Hypothese, expliziter Debug-Auftrag
- spoton-helper patch: HIGH für den Blocker-Befund (Secrets fehlen), das ist ein verifizierter Zustand
- Browse/UX (#161/#94/#135): HIGH für #161 (klarer Fix), MEDIUM für #94/#135 (Design-Entscheidung offen)

**Research date:** 2026-08-29
**Valid until:** ~2026-09-28 (30 Tage — stabiles LMS/Tool-Ökosystem; Ausnahme: CI-Secret-Status kann sich ändern)
