# Phase 78: Browse + Connect Reintegration (Perl) - Research

**Researched:** 2026-08-31
**Domain:** LMS ProtocolHandler/Connect-Refactoring auf den bounded Audio-Endpoint (Soloist-Backend, rein Perl)
**Confidence:** HIGH (alle Kernaussagen aus in dieser Session gelesenem Repo-Code; keine externen Abhängigkeiten)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### First-Track-Bootstrap
- **D-01:** Erster Track einer Session serviert unbounded (kein Boundary planted). Boundary erst beim nächsten `track_changed` Event. Kein Sonder-Bootstrap nötig. — **Reversibility:** reversible
- **D-02:** Session-Ende: Daemon 'stopped' `playback_changed` Event → `POST /boundary` → Stream bekommt sauberes EOF. LMS stoppt normal. — **Reversibility:** reversible

#### Browse vs Connect Modell
- **D-03:** Gleicher ProtocolHandler-Pfad für Browse und Connect. Beide nutzen `spoton://track:ID` URLs, ProtocolHandler zeigt auf bounded `/stream` Endpoint, getNextTrack holt Track-Metadata per API. Ein Audio-Vertrag für beide. — **Reversibility:** costly — Rückkehr zu zwei getrennten Pfaden erfordert Re-Implementierung der browseSession/Connect-Split-Logik
- **D-04:** Connect wird von `spoton://connect-<ts>` mit `isRepeatingStream=1` auf `spoton://track:ID` Einträge umgestellt. Connect.pm erzeugt bei 'start' einen spoton://track:ID Eintrag, bei `track_changed` einen neuen. `isRepeatingStream` entfällt für Soloist. — **Reversibility:** costly — Connect.pm's streamUrl-Swap und repeating-stream Mechanik müsste wiederhergestellt werden

#### Skip/Seek + Flush
- **D-05:** Skip = Flush + implizites EOF. `pa_stream_flush` → `g_flush_disconnect` schließt den Client (bereits implementiert). LMS sieht EOF, ruft `getNextTrack`. Boundary wird invalidiert (`g_boundary_at_pushed = -1`). Gleicher Flow wie natürliches Track-Ende. — **Reversibility:** reversible

#### Code-Removal-Strategie
- **D-06:** Inkrementell — erst Browse auf bounded umstellen + testen, dann alten Code entfernen. Zwei separate Commits. Wenn Browse auf bounded funktioniert, ist der alte Code beweisbar tot. — **Reversibility:** reversible
- **D-07:** Browse-spezifische Tests (t/29, t/32, t/37 browseSession-Tests) löschen und neue Tests für das bounded Modell schreiben (EOF bei Boundary, Track-Advance, Connect-Transfer). — **Reversibility:** reversible

### Claude's Discretion
- **Restart Gate Disposition:** Entscheidung ob die Phase-76 Restart Gate entfernt oder vereinfacht wird, basierend auf Code-Analyse ob Session-Restore-Autoplay im neuen Modell noch ein Problem ist
- **Connect.pm Browse-Pfade:** Code-Analyse ob `_soloistBrowseWs`, D-16 stale-claim, browseSession-Checks komplett entfernt oder zu unified Pfad refactored werden
- **Seek-Implementierung:** WS seek + Reconnect vs. `start=` Query-Parameter — basierend auf Aufwand und Kompatibilität

### Deferred Ideas (OUT OF SCOPE)
- **FFmpeg-Hook für encoded Audio (OGG/Vorbis)** — Zukunftsoption dokumentiert in playback-architecture-comparison.md §12. Nicht für v4.0.
- **Private Audio-Research** — ~/spoton-private/ Projekt, separate Session
- **soc flc convert-Regel** — Phase 76 D-05, DEFERRED. Braucht eigene Phase nach bounded Facade.
- **Gapless Playback** — owntone-Pattern (shared buffer + boundary markers ~2s vor EOF) als Zukunftsoption. Bounded Facade mit per-Track-EOF hat inhärent eine kleine Lücke beim Reconnect.
</user_constraints>

## Summary

Phase 78 stellt den Soloist-Playback-Pfad (Browse UND Connect) auf den in Phase 77/Spike 2 validierten bounded Audio-Endpoint um und entfernt ~530 LOC kompensatorischen Browse-Code (browseSession-State-Machine, D-15/D-16/D-17-Gates, Seeding, Grace-Timer). Die C-Seite (fake-libpulse: `POST /boundary`, bounded Serving, `g_flush_disconnect`) ist fertig und E2E-validiert; die Phase ist rein Perl — plus das Committen der noch **uncommitteten Spike-Änderungen** im Working Tree (fake-libpulse.c +385 Zeilen, SoloistWS.pm `_signalBoundary`, Connect.pm Metadata-Bleed-Guard, t/37-Erweiterung).

Die Recherche hat vier Design-Fallstricke identifiziert, die der Plan explizit lösen muss und die aus der reinen Task-Liste nicht ersichtlich sind: (1) Nach Entfernen des `_emitAllowed`-browseSession-Gates echoen LMS-initiierte Browse-Plays als `spottyconnect start/change` zurück nach Connect.pm, das dann per D-04 neue Playlist-Einträge erzeugen und die User-Playlist zerstören würde — es braucht einen Bestätigungs-/Echo-Check (Volumio `play_origin`-Analogon). (2) Der D-16-Claim-Release in `_onNewSong` feuert unter D-04 bei JEDEM Soloist-Connect-Track ("new song without Connect URL"), weil Connect-Tracks jetzt `spoton://track:ID` heißen — die gesamte Ownership-Logik (`$_activeConnectPlayer`, `_isLiveConnectStream`, alle `connect-`-URL-Guards) muss für Soloist auf ein neues Kriterium umgestellt werden. (3) Die Phase-27-Watchdogs in Plugin.pm (`^spoton://(?!connect-)`) matchen unter D-04 plötzlich auch Soloist-Connect-Songs und können Doppel-Skips auslösen. (4) LMS-Pause während Browse MUSS weiterhin als WS `pause` an den Daemon weitergeleitet werden (das Removal-Target "_onPause Browse-Pfade" braucht einen unified Ersatz), sonst killt `_http_write_all`s 2s-POLLOUT-Timeout die Verbindung, sobald der Socket-Puffer voll ist, und der Ring läuft per drop-oldest weiter.

**Primary recommendation:** Drei Wellen gemäß D-06: (W1) Spike-Baseline committen + Browse auf bounded umstellen (`/stream/track?uri=X&start=Y`-URL, `_signalBoundary` zusätzlich auf `playback_changed 'stopped'` per D-02, getNextTrack ohne Gate) + neue Tests; (W2) tote browseSession-Maschinerie entfernen (Inventar unten, zeilengenau); (W3) Connect auf `spoton://track:ID` umstellen (D-04, backend-dispatched — librespot behält `spoton://connect-` + `isRepeatingStream` unverändert) mit neuem Soloist-Ownership-Kriterium.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Track-Sequenzierung Browse | LMS (Playlist + EOF-Advance) | Daemon (spielt genau 1 Track, 'stopped' am Ende) | Pattern A: ein Sequencer; EOF am Boundary-Marker = Advance-Signal [VERIFIED: .planning/research/playback-architecture-comparison.md §9-10] |
| Track-Sequenzierung Connect | Daemon (Spirc/App-Queue) | LMS folgt via `track_changed` → neuer Playlist-Eintrag (D-04) | Spotty-Overlay-Pattern; Audio-Vertrag identisch zu Browse |
| Audio-Transport | fake-libpulse HTTP (C, FERTIG) | ProtocolHandler liefert nur die URL | Bounded Serving, Boundary-Close, Flush-Disconnect sind implementiert [VERIFIED: fake-libpulse.c:738-1028] |
| Boundary-Signalisierung | SoloistWS.pm (Perl) | fake-libpulse (`POST /boundary`) | `_signalBoundary` auf `track_changed` existiert; D-02 verlangt zusätzlich 'stopped' [VERIFIED: SoloistWS.pm:679, 735-758] |
| Elapsed/Duration | LMS Byte-Counting + Metadata-Cache | Daemon `position_sync` nur noch für Seek-Erkennung/Connect-Anzeige | Bounded PCM mit fester Rate macht Byte-Counting exakt |
| Pause/Seek/Volume-Forwarding | Connect.pm Event-Subscriber | SoloistWS `sendCommand` | Bestehendes `_sendControlCommand`-Framework bleibt [VERIFIED: Connect.pm:296-450] |
| Metadata | ProtocolHandler `getMetadataFor` + `spoton_meta_`-Cache | `_asyncRefetch` bei Cache-Miss | Für `spoton://track:ID` funktioniert der Browse-Metadata-Pfad bereits für beide Modi [VERIFIED: ProtocolHandler.pm:1197-1320] |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Perl | 5.38.2 (Dev-Box), Floor 5.10 | Plugin-Sprache | LMS-Vorgabe [VERIFIED: `perl -v` dieser Session] |
| LMS Plugin API | 8.0+ / 9.1.1 | `Slim::Utils::Timers`, `Slim::Control::Request`, `Slim::Player::*` | Bestehender Code, keine neuen Module |
| Test::More + prove | TAP::Harness 3.44 | Testsuite | CI läuft `prove t/` [VERIFIED: .github/workflows/perl-tests.yml:33 — `run: prove t/`] |
| fake-libpulse.so | Working-Tree-Stand (Spike 2) | Bounded HTTP-Serving | C-Seite fertig, wird NICHT geändert (bis auf dokumentierte Ausnahme, s. Pitfall 8) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| spoton-uat Skill | lokal | Autonomes E2E-UAT (Connect + Browse, echte Audio-Verifikation via squeezelite-Logs) | Nach Wave 1 und Wave 3 |
| systemd `lyrionmusicserver` | aktiv | Dev-LMS für Live-Tests | Deploy + Restart per bestehender sudoers-Regeln |

**Keine neuen externen Abhängigkeiten.** Keine Installation nötig.

## Package Legitimacy Audit

Diese Phase installiert **keine** externen Packages. Alle verwendeten Module sind LMS-bundled oder bereits im Repo.

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram — Ziel-Zustand (Soloist bounded)

```
BROWSE (LMS sequenziert):
  User: playlist play spoton://track:A,B,C
    │
    ▼
  getNextTrack(A)  ── WS 'play' spotify:track:A ──► Soloist Daemon
    │  (kein Gate, kein waitForBrowseReady;            │ decodiert
    │   Metadata/Duration aus spoton_meta_ Cache)      ▼
    │                                        fake-libpulse Ring (S32LE, 20s)
    ▼                                                  │
  canDirectStream → http://host:PORT/stream/track?uri=A&start=0
    │  (Query-Params rein Perl-seitig: URL-Eindeutigkeit; C ignoriert Pfad)
    ▼
  squeezelite GET ──────────────────────────► HTTP-Thread serviert Ring
                                                       │
  Track-Ende: Daemon 'stopped' ──► SoloistWS: _signalBoundary (D-02, NEU)
                                                       │
                                    serve bis Marker → socket close = EOF
    ◄──────────────────────────────────────────────────┘
  LMS: EOF → Playlist-Advance → getNextTrack(B) → WS 'play' B → neuer GET

CONNECT (Daemon sequenziert, LMS folgt):
  Spotify App: play ──► Daemon 'track_changed' A
    │                        │
    │                        ├─► _signalBoundary (Marker, außer erster Track D-01)
    │                        └─► _emit('start'/'change') → Connect.pm
    ▼
  Connect.pm: playlist play/add spoton://track:A (D-04, source-marked)
    │   ECHO-CHECK nötig: wenn LMS-Song bereits == announced URI → no-op
    ▼
  getNextTrack(A): erkennt Connect-Ownership → KEIN WS 'play' (Daemon spielt schon)
    ▼
  gleicher bounded GET wie Browse; App-Skip = Flush → EOF (D-05) → Advance
```

### Verifizierter C-Vertrag (fake-libpulse, Working Tree — die Basis dieser Phase)

Alle folgenden Punkte in dieser Session aus dem Quelltext gelesen:

1. **Jeder GET auf dem Stream-Port wird zum Streaming-Client — Pfad/Query egal.** [VERIFIED: fake-libpulse.c:326-328] Verbatim: `/* Bounded read of the HTTP request head (GET line + headers); any GET * is answered -- path checking beyond the fixed /stream endpoint is * unnecessary on this single-purpose port. */` → Die URL `http://host:PORT/stream/track?uri=X&start=Y` funktioniert **ohne C-Änderung**; `uri`/`start` sind Perl-seitige Dekoration (URL-Eindeutigkeit pro Track/Seek gegenüber LMS' RemoteTrack-Cache und Prefetch).
2. **`POST /boundary`** pflanzt den Marker bei `g_ring.total_pushed`, antwortet 200, berührt den aktiven Client nicht. [VERIFIED: fake-libpulse.c:829-856]
3. **Genau EIN Marker-Slot.** [VERIFIED: fake-libpulse.c:393-401] Verbatim: `/* -1 = no boundary planted (serve indefinitely, existing behavior). */ static volatile int64_t g_boundary_at_pushed = -1;` — ein zweiter POST überschreibt den ersten. Für den Ziel-Flow reicht das (LMS reconnected innerhalb der 20s-Ring-Lookahead), bei Rapid-Skips invalidiert der Flush ohnehin (Punkt 5).
4. **Serve-Loop schließt am Marker** (partial-chunk-genau), setzt Marker auf -1 zurück. [VERIFIED: fake-libpulse.c:935-982]
5. **Skip/Seek-Flush:** `pa_stream_flush` → `g_flush_disconnect` → aktiver Client wird geschlossen (= EOF für LMS), Marker invalidiert (`g_boundary_at_pushed = -1`). [VERIFIED: fake-libpulse.c:754-772] — deckt D-05 ab.
6. **WR-11-Takeover bleibt:** ein neuer vollständiger GET-Head schließt den aktiven Client. [VERIFIED: fake-libpulse.c:858-894] Im bounded Modell unkritisch: LMS öffnet die nächste Verbindung erst nach EOF (Client-Slot ist dann frei); LMS-natives Prefetch nach EOF ist sogar der gewollte Gapless-Näherungsmechanismus.
7. **HTTP-Antwort:** `HTTP/1.0 200 OK`, `Content-Type: audio/x-pcm`, kein Content-Length, `Connection: close`. [VERIFIED: fake-libpulse.c:724-728]
8. **Bekannte, dokumentierte C-Limitierung:** bis zu 16383 Bytes (~46 ms S32LE-Audio) NACH dem Marker im selben Pop-Chunk werden **verworfen**, nicht in die nächste Verbindung übertragen. [VERIFIED: fake-libpulse.c:925-934] Verbatim: `* Known prototype limitation: _ring_pop_timed() already * removed the full 'n' bytes from the ring before this * check runs, so any bytes beyond the boundary within this * SAME chunk (up to sizeof(chunk)-1 = 16383 bytes, ~46ms of * S32LE 44100Hz stereo audio) are dropped rather than * carried over to the next connection. ... a production version would need a * small carry-over buffer instead of a hard pop-then-trim.` — **Widerspricht der CONTEXT-Aussage "Die C-Seite ist FERTIG" in einem Detail.** Empfehlung: als akzeptierte Limitation (~46 ms Clip am Track-ANFANG des Folgetracks) dokumentieren und in UAT hörprüfen; die Carry-over-Buffer-Korrektur ist eine kleine, isolierte C-Änderung, falls hörbar (siehe Open Question 3).
9. **Underflow-Signal an Soloist** (Ring leer → `underflow_cb`) bleibt unangetastet — das ist der Fix für Soloists Writer-Thread-Stall. [VERIFIED: fake-libpulse.c:985-1023]
10. **`_http_write_all` bricht nach 2 s POLLOUT-Timeout ab und schließt den Client.** [VERIFIED: fake-libpulse.c:686-709] → Konsequenz für Pause-Handling, siehe Pitfall 4.

### Bestehende Perl-Regexe, die die neue URL-Form gratis abdecken

Die URL-Form `http://host:PORT/stream/track?uri=X&start=Y` matcht die vorhandenen Muster, sodass Range-Unterdrückung, Enhanced-HTTP-Off und pcm-Typisierung ohne Änderung greifen:

- `getFormatForURL`: `return 'pcm' if $url && $url =~ m{:\d+/stream\b};` [VERIFIED: ProtocolHandler.pm:134] — `:PORT/stream/track` matcht `\b` nach `stream`.
- `requestString` / `canEnhanceHTTP`: `m{:\d+/(?:stream\b|(?:track|episode)/)}` [VERIFIED: ProtocolHandler.pm:391, 512] — matcht ebenfalls über `stream\b`.
- **Achtung:** `canDirectStreamSong` hängt `?start_position=` nur bei `m{/(?:track|episode)/}` an [VERIFIED: ProtocolHandler.pm:199] — `/stream/track?` matcht dieses Muster NICHT (kein `/` nach `track`). Der Soloist-Seek-Offset muss also im Soloist-Branch von `canDirectStream` selbst als `&start=Y` angehängt werden (plus `$song->startOffset($offset)`), oder das Muster wird erweitert.

### Pattern 1: Bounded Browse getNextTrack (Ersatz für D-17-Gate + Re-entry-Guard)

**What:** getNextTrack für `spoton://track:ID` unter Soloist: Samplesize-Hints setzen (bleibt), Duration aus Cache (bleibt), WS `play` senden — aber NUR wenn der Daemon nicht ohnehin schon auf diesem Track ist (Connect-Fall / Daemon-Advance). Danach sofort `successCb->()` — kein `waitForBrowseReady`.
**When to use:** Ersatz für ProtocolHandler.pm:745-843.
**Example (Skizze, Identifikatoren aus dem realen Code):**
```perl
# ProtocolHandler::getNextTrack, Soloist-Branch (ersetzt Z.745-843)
my $ws = ($helper && $helper->can('_ws')) ? $helper->_ws : undef;
unless ($ws && $ws->connected) {
    $errorCb->('PROBLEM_OPENING', 'Soloist daemon not ready');
    return;
}
# Connect-Ownership ODER Daemon spielt den Track bereits (lastTrackId):
# kein play — der Daemon sequenziert (D-03/D-04).
my $daemonCurrent = $ws->lastTrackId // '';
if (Plugins::SpotOn::Connect->isSpotifyConnect($client) || $daemonCurrent eq $id) {
    # no-op: bounded GET serviert die laufende Session
}
else {
    $ws->sendCommand('play', uri => "spotify:$type:$id")
        or do { $errorCb->('PROBLEM_OPENING', 'Soloist daemon send failed'); return; };
}
$successCb->();
```
*Hinweis:* `lastTrackId` wird heute im Browse-Modus NICHT gepflegt (browse-Route return vor `lastTrackId($newId)` [VERIFIED: SoloistWS.pm:688-697]); nach Entfernen der Browse-Route pflegt `_onTrackChanged` es für alle Events — genau das braucht der Vergleich oben.

### Pattern 2: D-02 — Boundary auf 'stopped'

**What:** `_signalBoundary` feuert heute nur in `_onTrackChanged` [VERIFIED: SoloistWS.pm:679]. D-02 verlangt es zusätzlich bei `playback_changed` Status `'stopped'` (natürliches Track-/Session-Ende ohne Folge-Track), sonst bleibt die Verbindung nach dem letzten Track offen und LMS' `_RetryOrNext` (~10 s) reißt den alten Fehlermodus wieder auf.
**Wichtig:** `'paused'` darf KEINEN Boundary pflanzen (Pause ≠ Track-Ende). Der Daemon kollabiert Paused+Stopped in der Emission [VERIFIED: SoloistWS.pm:984-988 — `# librespot collapses Paused+Stopped identically`], aber der rohe `$msg->{status}` unterscheidet 'paused' und 'stopped' — der Boundary-Trigger muss am rohen Status hängen, nicht an der `_emit('stop')`-Übersetzung.

### Pattern 3: Connect D-04 — backend-dispatchte Playlist-Einträge

**What:** Die vier `playlist play spoton://connect-<ts>`-Dispatch-Stellen in Connect.pm werden für Soloist auf `spoton://track:$trackId` umgestellt; librespot-Pfad bleibt byte-identisch (Repeating-Stream ist dort weiterhin korrekt).
**Die vier Stellen:** [VERIFIED: Connect.pm:1097-1103 (resume-Re-Entry), 1274-1280 ('start'), 1374-1389 ('change' skipInitiated-Reconnect), 1516-1523 ('ready')]
**'change' unter Soloist neu:** statt streamUrl-Swap/Metadata-only → neuen `spoton://track:$newTrackId`-Eintrag anlegen (playlist add + source-marked advance, oder `playlist play` — Planner-Detail). Der `skipInitiated`-Sonderpfad (260827-of9) entfällt für Soloist: D-05 macht den Flush-Disconnect selbst zum EOF, LMS reconnected ohnehin.
**`isRepeatingStream`** bleibt unverändert (`return $url =~ m{spoton://connect-} ? 1 : 0;` [VERIFIED: ProtocolHandler.pm:1089-1094]) — Soloist-Track-URLs liefern automatisch 0.

### Anti-Patterns to Avoid
- **Neue Zustands-Flags als Ersatz für alte:** Das Architektur-Review setzt als Messlatte ≤ ~2 verbleibende Sonderfälle [VERIFIED: .planning/debug/browse-architecture-review.md §4 Spike-Schritt 4]. Jedes neue Flag à la `browseAdvancePending` ist ein Modell-Leck.
- **`waitForBrowseReady`-Nachbauten:** Startlatenz des Daemons erscheint im bounded Modell als Buffering (Verbindung offen, Ring liefert später) statt als Retry-Stutter — kein Gate nötig.
- **`['time', N]` für Connect-Positionskorrekturen im Stream-Modus** — weiterhin verboten (CON-13, startOffset-Pattern) solange die betreffende Verbindung nicht neu aufgebaut werden soll.
- **Unbedachtes Löschen "Browse-verdächtiger" Shared-Code-Stellen:** `_onNewSongWatchdog`/`_prefetchWatchdog`/`_pauseGuardCheck` sind Phase-27-Code für den **librespot**-Browse-Daemon (Kommentar `# Prefetch Hang Watchdog (Phase 27)` [VERIFIED: Plugin.pm:3916-3918]) und enthalten **null** Soloist-spezifische Zweige (Grep in dieser Session). Entfernt werden darf dort nichts ersatzlos — siehe Pitfall 3 für die tatsächlich nötige Änderung.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Track-Advance Browse | Seeding/Advance-Choreografie (wie D-15/16/17) | LMS EOF-Advance (bounded socket close) | Der ganze Sinn der Phase; EOF ist das native LMS-Signal |
| Startlatenz-Handling | Readiness-Gates/Timer | Offene HTTP-Verbindung, die erst liefert wenn der Ring Daten hat | LMS zeigt Buffering; kein Retry-Loop, weil kein vorzeitiges Stream-Ende |
| Pause/Seek/Volume-Routing | Neue Dispatcher | `_sendControlCommand` + Endpoint→WS-Mapping [VERIFIED: Connect.pm:296-348] | Fertig inkl. Web-API-Fallback (D-15) und 409-Handling |
| Metadata für Connect-Tracks | Eigener Connect-Metadata-Pfad für track-URLs | `spoton_meta_`-Cache + `_asyncRefetch` [VERIFIED: ProtocolHandler.pm:1268-1320, 1442-1556] | Browse-Cache-Pfad deckt `spoton://track:ID` bereits ab; `_fetchTrackMetadata` kann für Soloist zum Cache-Befüller degradieren |
| Loop-Prevention | Neue Echo-Flags | `$request->source(__PACKAGE__)` / Source-Marking | Etabliertes Muster in allen Subscribern |

**Key insight:** Alles, was diese Phase NEU braucht, existiert bereits als Mechanismus im Repo — die Arbeit ist Umverdrahtung + Löschung, nicht Neubau. Das größte Risiko ist nicht fehlender Code, sondern übersehene Konsumenten der alten `connect-`-URL-Semantik.

## Runtime State Inventory

> Refactor-Phase — alle 5 Kategorien geprüft:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | `spoton_meta_`-Cache-Einträge: alte `spoton://connect-<ts>`-History-Keys (mit `spotifyUri`) bleiben gültig — getNextTrack-Translation + getMetadataFor-History-Pfad bleiben für librespot und Alt-History bestehen [VERIFIED: ProtocolHandler.pm:644-672, 1231-1249]. Neue Soloist-Connect-Tracks cachen direkt unter `spoton://track:ID` (Browse-Key). | Keine Migration. Code-Verhalten: `_fetchTrackMetadata`/`_asyncRefetch` schreiben für Soloist unter Track-URL-Key (tut `_asyncRefetch` via Pitfall-3-Regel bereits [VERIFIED: ProtocolHandler.pm:1527-1532]). |
| Live service config | Keine — Daemon-Ports sind ephemer (Port-File), keine externe Service-Config betroffen. | none |
| OS-registered state | Keine — systemd-Unit `lyrionmusicserver` unverändert. | none |
| Secrets/env vars | `SPOTON_BOUNDARY_SPIKE=1` in SoloistDaemon.pm ist als temporär markiert (uncommitted diff: `# Phase 77 Spike 1: boundary observability (temporary, remove after spike)` [VERIFIED: git diff SoloistDaemon.pm dieser Session]). | In Wave 1/0 entfernen oder bewusst als Diagnostic behalten (Empfehlung: entfernen, BOUNDARY-Traces bleiben per Env aktivierbar). |
| Build artifacts | `Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0` ist im Repo UND uncommitted geändert (59240→63704 Bytes, Spike-2-Build). Dev-LMS unter `/var/lib/squeezeboxserver/...` hat ggf. eine ältere .so deployed. | Wave 0: Spike-Stand committen; vor Live-Test .so auf Dev-LMS deployen + LMS-Restart (bestehende sudoers-Deploy-Regeln, Rücksprache-Regel für Pi beachten). |

**Nothing found in category:** Live service config, OS-registered state — verifiziert per Repo-Grep und systemd-Kenntnis; keine externen Registrierungen referenzieren Browse-/Connect-URL-Formen.

## Removal Inventory (zeilengenau, Working-Tree-Stand dieser Session)

Vollständiges Grep-verifiziertes Inventar der browseSession-Maschinerie. Dateien mit Treffern: `Connect.pm`, `ProtocolHandler.pm`, `SoloistWS.pm`, `t/29_soloist_browse.t`, `t/31_soloist_ws.t` [VERIFIED: grep -l dieser Session — t/32 und Plugin.pm enthalten KEINE browseSession-Referenzen].

### SoloistWS.pm (~470 LOC Removal)
| Was | Zeilen | Anmerkung |
|-----|--------|-----------|
| Accessors `browseSession browseCurrentUri browseSeededUri browseAdvancePending browseAdvanceTs browseReadyCb browseTrackConfirmed` | 99-105 (in mk_accessor-Liste 84-110) + Init 222-223 | |
| Konstanten `BROWSE_SEED_LEAD_SECONDS` (=15), `BROWSE_READY_TIMEOUT` (=30), `BROWSE_READY_CONFIRM` (=1) | 51-82 | |
| `_onClosed`: `$self->_resolveBrowseReady('timeout')` | 346-350 | |
| `_onDeviceChanged`: browse-Handover-Block | 636-644 | |
| `_onTrackChanged`: browse-Routing `return $self->_onBrowseTrackChanged($uri) if browseSession` | 686-690 | Danach pflegt `lastTrackId` auch Browse-Fälle → Basis für Pattern 1 |
| `_onBrowseTrackChanged` komplett | 760-869 | |
| `_onPlaybackChanged`: browse-Block (Stage-B-Timer + stopped-no-seed-Advance) | 891-957 | Ersatz: D-02-Boundary auf rohes `'stopped'` (Pattern 2) |
| `_onPositionSync`: `_maybeSeedBrowseQueue`-Aufruf + Stage-B-Resolve | 1016-1028 | |
| `_maybeSeedBrowseQueue` | 1057-1096 | |
| `_hasNextPlaylistEntry`, `_nextBrowseSpotifyUri`, `_clientCurrentSpotifyUri` | 1098-1147 | Nur von Browse-Pfaden benutzt (Grep) |
| `startBrowseTrack`, `%_BROWSE_END_SKIP_PAUSE`, `endBrowseSession` | 1149-1233 | |
| `waitForBrowseReady`, `_resolveBrowseReady`, `_clearBrowseReadyTimers`, `_browseReadyTimeoutTimer`, `_browseReadyConfirmTimer` | 1235-1326 | |
| `_emitAllowed`: browseSession-Gate `return 0 if $self->browseSession;` | 1432-1435 | Pref-Check (enableSpotifyConnect) BLEIBT |

**BLEIBT:** `_signalBoundary` (735-758), `skipInitiated`/`sessionPaused`/`deactivating`-Logik, Reconnect/Handshake, `sendCommand`-URI-Validierung, `_onPlaybackState`-Reconciliation.

### ProtocolHandler.pm
| Was | Zeilen | Aktion |
|-----|--------|--------|
| getNextTrack Soloist-Browse-Block: WS-Check, `browseAdvancePending`-Re-entry-Guard (WR-04), `startBrowseTrack`, D-17 `waitForBrowseReady`-Gate | 745-843 | Ersetzen durch Pattern 1 |
| `canDirectStream` Soloist-Browse: URL `"/stream"` | 225-275 (URL-Bau 265-268) | URL → `"/stream/track?uri=spotify:$type:$id&start=$offset"`; Rest (Proxy-Gate WR-05, resolveSoloistFormat-Gate D-06, synced-Gate) bleibt |
| `new()` b3-Soloist-Proxy: URL `"/stream"` | 592-610 (URL 599-601) | Gleiche URL-Umstellung (Sync-Group/Proxy/Transcode-Pfad) |
| `_hasActiveSoloistBrowseSession` + Verwendung in `canDoAction('rew')` | 1158-1188 | Entfernen; 'rew'-Suppression je nach Seek-Entscheidung (bei LMS-nativem Seek-Restart ist die Suppression für Soloist-Browse falsch) |
| `getSeekData` Soloist-Browse-`undef`-Branch | 1136-1146 | Je nach Seek-Entscheidung (Empfehlung: entfernen → `{ timeOffset => $newtime }`, s. Pitfall 5) |
| `canSeek`/`canTranscodeSeek`-Kommentare | 1096-1115 | Kommentar-Update (Verhalten bleibt: canTranscodeSeek=0) |
| `_translatedConnectUrls` + Dead-History-Translation | 66-67, 644-672, 315-322 | **BEHALTEN** — backend-agnostisch; nötig für librespot und Alt-History-Einträge. Kein Soloist-spezifischer Zweig vorhanden (Grep) |

### Connect.pm
| Was | Zeilen | Aktion |
|-----|--------|--------|
| `BROWSE_ADVANCE_GRACE` | 44-47 | Entfernen |
| `_soloistBrowseWs` | 187-207 | Entfernen (oder zu `_soloistConnectWs`-Nutzung vereinheitlichen) |
| `_onNewSong` WR-06 browse-end Hook | 486-493 | Entfernen |
| `_onNewSong` D-16 Stale-Claim-Release | 527-558 | **Umbauen, nicht nur löschen** — feuert unter D-04 bei jedem Soloist-Connect-Track (Pitfall 2) |
| `_onPause` browse-Forwarding-Block | 575-632 | Entfernen — ABER unified Pause-Forwarding als Ersatz nötig (Pitfall 4) |
| `_onPause` D-16 Stale-Claim-Guard | 636-663 | Entfernen (Removal-Liste) — Ownership-Neudefinition ersetzt ihn |
| `_onSeek` browse-Forwarding + `_bufferedBrowseSeek` | 774-789, 804-820 | Je nach Seek-Entscheidung entfernen/vereinheitlichen |
| `_connectEvent` 'start'/'resume'/'change'/'ready' playlist-play-Sites | 1097-1103, 1274-1280, 1374-1389, 1516-1523 | D-04 backend-Dispatch (Pattern 3) |
| `_isLiveConnectStream` / `_isDeadHistoryUrl` / alle `m{spoton://connect-}`-Guards | 108-139 u. v. a. | Für librespot BEHALTEN; für Soloist braucht jede Stelle das neue Ownership-Kriterium |
| Restart Gate `RESTART_START_GRACE` | 30-42, 1201-1225 | **Discretion — Empfehlung: BEHALTEN** (s. u.) |

### Plugin.pm
Kein browseSession-Code vorhanden. `_onNewSongWatchdog`/`_onModeChange`/`_onPauseCommand`/`_pauseGuardCheck`/`_prefetchWatchdog`/`_prefetchHangCheck` (3916-4099, Subscriptions 254-256) sind Phase-27-librespot-Code ohne Soloist-Zweige. **Nötige Änderung ist keine Löschung, sondern ein Guard** (Pitfall 3).

### Tests
| Test | Betroffen | Aktion |
|------|-----------|--------|
| `t/29_soloist_browse.t` (518 Z.) | WS-Stub mit `browseSession/browseAdvancePending/startBrowseTrack` [VERIFIED: t/29:286-297]; getNextTrack-Dispatch-Tests | Umschreiben auf bounded Modell: getNextTrack ohne Gate, `canDirectStream`-URL-Form `/stream/track?uri=`, Connect-Ownership-No-Play-Fall |
| `t/31_soloist_ws.t` | Emit-Gate-Test (421-434), D-17-Recorder (78), Browse-SM-Tests (800ff) | Browse-Blöcke löschen; neuer Test: `_signalBoundary` auf `track_changed` UND rohem `'stopped'` (D-02), nicht auf `'paused'` |
| `t/32_soloist_events.t` | **Keine** Browse-Referenzen (Grep) — pinnt Event→spottyconnect-Mapping | Bleibt fast unverändert; ggf. neuer Fall: Emission auch ohne (ehemaliges) browseSession-Gate |
| `t/37_connect_lifecycle.t` (201 Z. + 37 uncommitted) | D-16-Tests (123-161) | D-16-Blöcke löschen; neue Tests: D-04-URL-Erzeugung backend-dispatched, neues Ownership-Kriterium; Metadata-Bleed-Block (uncommitted) BLEIBT |
| `t/03_convert_conf.t` | Falls custom-convert.conf angefasst wird | Prüfen — Task 2 ist voraussichtlich No-op (s. u.) |

### custom-convert.conf (Task 2 — voraussichtlich No-op)
`soc pcm * *` Passthrough existiert [VERIFIED: custom-convert.conf:1-3 — verbatim: `soc pcm * *` / `\t# I` / `\t-`]; `getFormatForURL` mappt die bounded URL auf 'pcm' (s. o.). Die auskommentierte `soc flc`-Regel bleibt DEFERRED (eigene Phase, CONTEXT). Einzige mögliche Änderung: den DEFERRED-Kommentar (Z. 21-22 „needs prefetch architecture fix") aktualisieren — der Prefetch-Blocker ist mit bounded Serving strukturell gelöst, Aktivierung aber out of scope.

## Common Pitfalls

### Pitfall 1: Browse-Play-Echo zerstört die User-Playlist (KRITISCH)
**What goes wrong:** Ohne `_emitAllowed`-browseSession-Gate übersetzt `_onTrackChanged` JEDES Daemon-Event in `spottyconnect start/change`. Ein LMS-initiierter Browse-Play (getNextTrack → WS `play` A) erzeugt ein `track_changed` A → `_emit('start', A)` → Connect.pm 'start'-Handler → per D-04 `playlist play spoton://track:A` → die gerade geladene User-Playlist (A,B,C) wird durch einen Ein-Track-Eintrag ersetzt, `$_activeConnectPlayer` wird gesetzt, Browse mutiert ungewollt zu Connect.
**Why it happens:** Das Gate war die (falsche) Lösung genau dieses Echos; sein Ersatz fehlt in der Task-Liste.
**How to avoid:** Bestätigungs-Check in Connect.pm 'start'/'change' (bzw. schon in `_onTrackChanged`): Wenn die announced URI bereits der aktuellen/streamenden LMS-Song-URL `spoton://track:<id>` entspricht → no-op (höchstens Metadata-Refresh), KEIN playlist play, KEIN Claim. Nur eine URI, die LMS nicht erwartet (App-initiiert), triggert den Connect-Eintrag. Das ist Volumios `play_origin`-Diskriminierung in LMS-Begriffen [VERIFIED: .planning/research/playback-architecture-comparison.md §5.1].
**Warning signs:** Nach Browse-Play schrumpft die Playlist auf 1 Eintrag; `isSpotifyConnect` true während Browse.

### Pitfall 2: D-16-Claim-Release feuert bei jedem Soloist-Connect-Track (KRITISCH)
**What goes wrong:** `_onNewSong` released den Connect-Claim, wenn der neue Song KEINE `connect-`-URL hat [VERIFIED: Connect.pm:537-544 — verbatim: `if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) { unless ($url =~ m{spoton://connect-}) { ... $_activeConnectPlayer = undef;`]. Unter D-04 hat JEDER Soloist-Connect-Track eine `spoton://track:ID`-URL → Claim wird beim ersten newsong released → `isSpotifyConnect` false → H6-Guards droppen alle weiteren change/seek/volume-Events, `_onPause`/`_onSeek`/`_onPlaylistJump` forwarden nichts mehr, `_restorePowerAfterConnect`-Logik bricht.
**How to avoid:** Ownership-Kriterium für Soloist neu definieren. Empfehlung: Claim wird gesetzt durch `_connectEvent('start')` (wie heute) und released durch (a) `stop 'inactive'` (Session-Ende, existiert: GH #151-Pfad [VERIFIED: Connect.pm:1423-1445]), (b) einen newsong, dessen URL NICHT von Connect.pm selbst source-marked erzeugt wurde bzw. nicht der zuletzt vom Daemon announced Track ist (User startet eigenes Playback). Alle `m{spoton://connect-}`-Live-Checks (`_isLiveConnectStream` etc.) brauchen für Soloist ein Äquivalent (z. B. „aktueller Song == zuletzt announced Daemon-Track").
**Warning signs:** Connect-Events nach Track 1 wirkungslos; Pause in der App pausiert LMS nicht mehr.

### Pitfall 3: Phase-27-Watchdogs matchen jetzt Soloist-Connect
**What goes wrong:** Alle fünf Watchdog-Gates nutzen `^spoton://(?!connect-)` [VERIFIED: Plugin.pm:3942, 3952, 3973, 4011, 4038]. Unter D-04 matcht das Soloist-Connect-Songs: `_prefetchWatchdog` armt auf Connect-Tracks und kann `playlist jump +1` forcen → `_onPlaylistJump` forwarded `skip_next` an den Daemon → Doppel-Skip; `_pauseGuardCheck` re-applied Pausen gegen Connects eigene Grace-Logik.
**Why it happens:** Der Negative-Lookahead war das implizite „nicht Connect"-Kriterium; das URL-Schema trug die Semantik.
**How to avoid:** In den Watchdog-Gates zusätzlich `return if Plugins::SpotOn::Connect->isSpotifyConnect($client);` (bzw. das neue Ownership-Kriterium). Die Watchdogs selbst BLEIBEN — sie schützen librespot-Browse und sind unter bounded Soloist-Browse harmlos-redundant (ehrliches Elapsed + echtes EOF). Das ROADMAP-Removal-Item „_prefetchWatchdog Browse-Pfade" ist damit korrekt als „Connect-Ausschluss reparieren", nicht als „Watchdog löschen" zu lesen.
**Warning signs:** Log `Prefetch watchdog: ... forcing skip` während Connect-Session; übersprungene Tracks in der App.

### Pitfall 4: LMS-Pause ohne Daemon-Pause killt die Verbindung (Browse)
**What goes wrong:** Das Removal-Target „browseSession-aware Pfade in _onPause" entfernt das einzige LMS→Daemon-Pause-Forwarding für Soloist-Browse. Ohne WS `pause` decodiert Soloist weiter; squeezelite liest nicht mehr; sobald der Socket-Puffer voll ist, bricht `_http_write_all` nach 2 s POLLOUT-Timeout ab und schließt den Client [VERIFIED: fake-libpulse.c:686-709] → beim Unpause reconnected LMS und bekommt per drop-oldest verschobene Ring-Daten → Positionssprung/Audio-Verlust.
**How to avoid:** Unified Pause/Unpause-Forwarding behalten: für Soloist-Backend + `spoton://track:`-Song (Browse wie Connect — dank D-03 identisch) LMS-Pause → WS `pause`, Unpause → WS `play` (ohne uri = resume [VERIFIED: Connect.pm:306 — `'/control/play' => 'play', # no uri: resume semantics`]). Das Connect-`_onPause`-Framework kann das übernehmen, sobald das Ownership-Kriterium (Pitfall 2) auch Browse-Soloist-Songs erfasst — oder ein schlanker backend-Check ersetzt `_soloistBrowseWs`.
**Warning signs:** Nach >2 s Pause + Unpause: Positionssprung, `client-close: write error/disconnect` im Daemon-Log.

### Pitfall 5: Seek — WS-only-Seek ist mit bounded Serving inkompatibel
**What goes wrong:** Heute unterdrückt `getSeekData` den LMS-Stream-Restart (GH-#129-Pattern) und forwarded per WS. Ein Daemon-Seek löst aber `pa_stream_flush` → `g_flush_disconnect` aus → die offene Verbindung wird geschlossen = **EOF mitten im Track** → LMS advanced fälschlich zum nächsten Playlist-Eintrag.
**How to avoid (Discretion-Empfehlung):** LMS-nativen Seek-Restart zulassen: `getSeekData` liefert für Soloist-Track-URLs `{ timeOffset => $newtime }`; `canDirectStream` hängt `&start=$offset` an (URL-Eindeutigkeit, `$song->startOffset` setzen — Elapsed stimmt); parallel forwarded `_onSeek` den Seek als WS `seek` (Daemon flusht + repositioniert). Der Flush-Disconnect trifft dann eine Verbindung, die LMS ohnehin gerade neu aufbaut. **Race dokumentieren:** Kommt der neue GET vor dem Daemon-Flush an, serviert er kurz Prä-Seek-Ringdaten; der Flush-Disconnect schließt ihn danach → LMS-Retry verbindet neu. In UAT prüfen; falls störend, WS-seek synchron VOR successCb im Seek-Pfad senden. `canDoAction('rew')`-Suppression für Soloist-Browse entfernen (Restart ist jetzt gewollt), für Connect beibehalten je nach Ownership-Modell.
**Warning signs:** Seek springt zum nächsten Track; Seek spielt kurz die alte Position.

### Pitfall 6: EOF-Timing — track_changed kommt ~20 s vor hörbarem Ende
**What goes wrong:** Der Daemon decodiert voraus; `track_changed` (= Boundary + Connect-Eintrag) feuert beim Decode-Start des Folgetracks, bis zu ~20 s (Ring-Kapazität [VERIFIED: fake-libpulse.c:324 — `#define RING_CAPACITY (RING_BYTES_PER_SEC * 20)`]) vor dem hörbaren Trackende. LMS erhält das EOF, sobald der Client die Rest-Bytes gelesen hat, und prefetcht dann den nächsten Eintrag — das ist der normale streamingSong/playingSong-Vorlauf und gewollt. ABER: Metadata-/Now-Playing-Updates, die an `track_changed` statt an LMS' `newsong` hängen, laufen der Anzeige um Sekunden voraus.
**How to avoid:** Connect-Metadata (Titel/Cover) über den `spoton_meta_`-Cache + LMS' eigenes newsong-Timing laufen lassen (getMetadataFor pro Song-Objekt), nicht als sofortiges `setCurrentTitle` auf den SPIELENDEN Song. Bekanntes Muster: go-librespot-Decode-Ahead [VERIFIED: playback-architecture-comparison.md §5.2 Timing caveat].
**Warning signs:** Titel wechselt ~15-20 s vor dem hörbaren Trackwechsel.

### Pitfall 7: Restart Gate (Discretion) — behalten
**Analyse:** Das Phase-76-Gate unterdrückt `playlist play` für ein 'start', das < `RESTART_START_GRACE` (5 s) nach Daemon-Spawn bei idle Player eintrifft (Re-Announcement einer dormanten Spirc-Session) [VERIFIED: Connect.pm:30-42, 1201-1225]. Das Problem ist orthogonal zum URL-Schema: auch unter D-04 würde ein Daemon-Respawn nach LMS-Restart sonst selbststartendes Audio erzeugen (jetzt via `playlist play spoton://track:ID`). **Empfehlung: Gate unverändert behalten**, nur die playReq-URL im nicht-unterdrückten Pfad wird per D-04 umgestellt. Spike 2 nennt „restart gate suppression" unter den prä-existierenden Connect-Symptomen [VERIFIED: 260831-bounded-endpoint-prototype/SUMMARY.md „Connect Playback Note"] — in Wave-3-UAT gezielt verifizieren (Transfer < 5 s nach Daemon-Start).

### Pitfall 8: Uncommittete Spike-Basis
**What goes wrong:** Der gesamte Phase-77-Stand (fake-libpulse.c +385, libpulse.so.0, `_signalBoundary`, Connect-Metadata-Guard, t/37-Erweiterung, ROADMAP) liegt **uncommitted** im Working Tree [VERIFIED: `git diff --stat` dieser Session]. Ein Plan, der auf sauberem HEAD aufsetzt, bricht.
**How to avoid:** Wave 0/erster Task: Spike-Baseline committen (inkl. `SPOTON_BOUNDARY_SPIKE`-Env-Entfernung aus SoloistDaemon.pm), untracked Reste (`-`, `SHA256SUMS`, `graphify-out/`) klären/entsorgen. Erst dann Feature-Arbeit.

### Pitfall 9: `sendCommand('play')` ohne uri vs. mit uri
**What goes wrong:** `sendCommand` validiert `uri`-Parameter strikt (`^spotify:(?:track|episode):[A-Za-z0-9]+$` [VERIFIED: SoloistWS.pm:397]); `play` OHNE uri ist resume. Verwechslung führt zu Refuse-Logs oder ungewolltem Restart des aktuellen Tracks.
**How to avoid:** Pattern 1 nutzt `play` mit uri nur bei Track-Mismatch; Pause/Unpause-Forwarding nutzt `play` ohne uri.

## Code Examples

Siehe Pattern 1-3 oben (aus realem Repo-Code abgeleitet). Zusätzlich der Boundary-Trigger (Pattern 2) als konkrete Skizze:

```perl
# SoloistWS::_onPlaybackChanged — nach dem deactivating-Guard, VOR der
# Connect-Übersetzung (ersetzt den gelöschten browse-Block Z.891-957):
# D-02: natürliches Track-/Session-Ende ⇒ Boundary ⇒ bounded EOF für LMS.
# NUR 'stopped' — 'paused' ist kein Track-Ende (Pitfall: Pause ≠ EOF).
$self->_signalBoundary if $status eq 'stopped';
```

## State of the Art

| Old Approach (Phase 72/73/76) | Current Approach (Phase 78) | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Unbounded `/stream` + browseSession-SM + D-15/16/17-Gates | Bounded `/stream/track?uri&start` + EOF-Advance | Phase 77 Spikes GO (2026-08-31) | ~530 LOC Removal, ein Audio-Vertrag |
| Connect: `spoton://connect-<ts>` + isRepeatingStream (Soloist) | `spoton://track:ID`-Einträge pro Track (D-04) | Diese Phase | librespot-Connect UNVERÄNDERT |
| Elapsed: umkämpft (Byte-Count vs. position_sync) | Byte-Count autoritativ; position_sync nur Seek-Detection | Diese Phase | Watchdog-/Jiffies-Probleme strukturell entschärft |

**Deprecated/outdated (nach dieser Phase):** `waitForBrowseReady`/D-17, `browseAdvancePending`-Re-entry, Seeding (`_maybeSeedBrowseQueue`), `BROWSE_ADVANCE_GRACE`, D-16-Stale-Claim in der bisherigen Form.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | LMS öffnet nach bounded EOF die nächste Playlist-URL zeitnah (Prefetch nach EOF), sodass die Lücke am Trackwechsel klein bleibt (Reconnect-Latenz; vgl. Phase-76 „8s Reconnect-Gap" D-12) | Architecture Patterns / Pitfall 6 | Hörbare Lücke pro Trackwechsel; UAT-Messung nötig — Deferred „Gapless" deckt die Langfrist-Lösung |
| A2 | Ein WS `play uri=X` während einer aktiven Soloist-Session flusht den Ring (wie App-Skip), sodass Browse-Skip saubere neue Audio-Daten liefert | Pattern 1 / D-05 | Skip serviert kurz Alt-Audio; Gegenmittel wäre explizites Flush-Signal — in Wave-1-UAT verifizieren |
| A3 | `track_changed`-Echo-Erkennung per URI-Vergleich (announced == aktueller LMS-Song) reicht als Browse/Connect-Diskriminator; kein `play_origin`-Feld im Soloist-WS-Vokabular nötig | Pitfall 1 | Falsch-positive Echos bei Track-Doppelungen in Playlist; Planner sollte streamingSong UND playingSong prüfen |
| A4 | Die ~46 ms Chunk-Drop-Limitierung am Boundary ist unhörbar (Track-Anfang, leiser Bereich) | C-Vertrag Punkt 8 | Hörbarer Clip am Trackanfang → kleine C-Korrektur (Carry-over) als Follow-up nötig |
| A5 | `spoton-uat`-Skill deckt die neuen Szenarien (EOF-Advance, Connect-Transfer auf track-URLs) nach Anpassung ab | Validation | UAT-Aufwand steigt; manuelles Dev-Box-UAT als Fallback (Phase-76 D-09-Muster) |

## Open Questions (RESOLVED)

Alle vier Fragen sind in den Plänen 78-01..78-04 dispositioniert:

1. **Soloist-Ownership-Kriterium (ersetzt `connect-`-URL-Checks)** — RESOLVED (Plan 78-04, Task 2)
   - What we know: Claim via `$_activeConnectPlayer`; alle Live-Checks hängen an `m{spoton://connect-}`; unter D-04 kollidiert das (Pitfall 2).
   - What's unclear: exaktes Release-Kriterium bei „User startet eigenes Playback" ohne URL-Unterscheidbarkeit (Browse-Track vs. Connect-Track sehen identisch aus).
   - Recommendation: Source-Marking der Connect-eigenen playlist-Requests + Vergleich gegen `ws->lastTrackId`; Release bei un-marked newsong mit URI ≠ lastTrackId sowie bei `stop 'inactive'`. Planner entscheidet die Details (liegt in Discretion „Connect.pm Browse-Pfade").
   - **Disposition:** `_isSoloistOwnedSong($client)` = aktueller Song-URL == `spoton://track:` . `$ws->lastTrackId`; D-16-Release nur bei newsong das weder connect-URL noch Soloist-owned ist; `stop 'inactive'` bleibt der autoritative Session-End-Release. Akzeptierte Kante (inline dokumentiert): manuelles Browse-Play exakt des announced Tracks released erst beim nächsten abweichenden Track.
2. **Wer erzeugt den Connect-Folgeeintrag: `playlist add`+advance oder `playlist play`?** — RESOLVED (Plan 78-04, Task 1)
   - What we know: `playlist play` ersetzt die Playlist (heutiges Verhalten, 1 Eintrag); D-04 sagt „erzeugt … einen neuen [Eintrag]".
   - What's unclear: ob eine wachsende Connect-History-Playlist (add) gewünscht ist oder Ein-Eintrag-Ersetzung (play) reicht.
   - Recommendation: `playlist play` (Ein-Eintrag, minimale Abweichung vom heutigen UX); History kommt weiter über den Meta-Cache.
   - **Disposition:** Recommendation übernommen — `playlist play` Ein-Eintrag-Ersetzung an allen vier Dispatch-Sites, source-marked; History weiter über den `spoton_meta_`-Cache.
3. **~46 ms Boundary-Chunk-Drop akzeptieren oder C-Fix?** — RESOLVED (akzeptiert; UAT-Beobachtung)
   - What we know: dokumentierte Prototyp-Limitierung [VERIFIED: fake-libpulse.c:925-934]; CONTEXT deklariert C als fertig.
   - Recommendation: In Wave-1-UAT hörprüfen; wenn hörbar → kleiner, isolierter C-Task (Carry-over-Buffer) als Plan-Ergänzung mit User-Rücksprache (Scope-Abweichung von „rein Perl").
   - **Disposition:** Kein Plan-Task; Drop akzeptiert. Hörprüfung läuft über die Live-UAT nach Wave 2 (Plan 78-02 Verification) bzw. die Phase-End-UAT (Plan 78-04 human-check). Ein C-Fix würde als separate Plan-Ergänzung nur nach User-Rücksprache aufgesetzt.
4. **Verhält sich der erste GET einer Session korrekt, wenn der Ring noch leer ist (Soloist-Warmup)?** — RESOLVED (akzeptiert; Design trägt den Fall)
   - What we know: Serve-Loop poppt mit 50 ms-Timeout und schreibt nichts, solange leer — Verbindung bleibt offen [VERIFIED: fake-libpulse.c:903-905]; LMS `_RetryOrNext` reconnected nach ~10 s stalled Stream; Warmup gesund <1 s, Worst Case >200 s.
   - What's unclear: ob der 10s-Retry beim Cold-Start noch zuschlägt (Reconnect ist im bounded Modell aber harmlos: Takeover, weiter warten).
   - Recommendation: Akzeptieren (Retry rejoint verlustfrei — kein Positions-Reset mehr relevant, da noch nichts spielte); im UAT den Cold-Start-Pfad beobachten.
   - **Disposition:** Recommendation übernommen — Plan 78-01 Task 2 baut das gate-freie getNextTrack mit synchronem successCb genau darauf: Startup-Latenz erscheint als LMS-Buffering auf der offenen bounded Connection; ein etwaiger 10s-Retry rejoint verlustfrei. Cold-Start-Pfad wird in der UAT beobachtet (Plan 78-02/78-04 Verification).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| perl | Tests/Runtime | ✓ | 5.38.2 | — |
| prove (TAP::Harness) | Testsuite | ✓ | 3.44 | — |
| LMS (`lyrionmusicserver`) | Live-Verifikation | ✓ (systemd active) | — | — |
| squeezelite | UAT-Player | ✓ | /usr/bin/squeezelite | — |
| fake-libpulse Build-Toolchain (make/gcc) | nur falls C-Fix (OQ 3) | nicht geprüft | — | CI-Workflow `build-fake-libpulse.yml` |

**Missing dependencies with no fallback:** keine.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Test::More (Perl core) + TAP::Harness 3.44 |
| Config file | keins (Konvention: `t/*.t`, stub-basierte Isolation per `write_stub`) |
| Quick run command | `prove t/29_soloist_browse.t t/31_soloist_ws.t t/32_soloist_events.t t/37_connect_lifecycle.t t/05_perl_syntax.t` |
| Full suite command | `prove t/` |

### Phase Requirements → Test Map
(Phase hat keine REQUIREMENTS-IDs; Mapping gegen die Phasen-Tasks)

| Req | Behavior | Test Type | Automated Command | File Exists? |
|-----|----------|-----------|-------------------|-------------|
| Task 1 | canDirectStream liefert `/stream/track?uri=…` (bounded), kein Gate in getNextTrack | unit (source/dispatch) | `prove t/29_soloist_browse.t` | ✅ (umschreiben, D-07) |
| Task 2 | soc-Profil deckt bounded URL (getFormatForURL→pcm) | unit | `prove t/03_convert_conf.t t/29_soloist_browse.t` | ✅ |
| Task 3 | browseSession-Maschinerie entfernt; `_signalBoundary` auf track_changed + 'stopped' | unit | `prove t/31_soloist_ws.t` | ✅ (Browse-Blöcke ersetzen) |
| Task 4 | Connect D-04: track-URL-Einträge backend-dispatched; Ownership-Lifecycle | unit (source-analysis wie t/37-Stil) | `prove t/37_connect_lifecycle.t` | ✅ (D-16-Blöcke ersetzen) |
| E2E | EOF-Advance, Seek, Connect-Transfer mit echtem Audio | manual/agent UAT | `Skill("spoton-uat")` bzw. Dev-Box-UAT | manual-only (LMS+Daemon+Spotify nötig — begründet) |

### Sampling Rate
- **Per task commit:** betroffene t/-Dateien einzeln (`prove t/<geänderte>.t`)
- **Per wave merge:** `prove t/`
- **Phase gate:** `prove t/` grün + spoton-uat Browse/Connect-Durchlauf vor `/gsd-verify-work`; librespot-Regression (Phase-76-D-14-Muster: beide Backends) verpflichtend, da shared Code (ProtocolHandler, Connect.pm, Plugin.pm) angefasst wird

### Wave 0 Gaps
- [ ] Spike-Baseline committen (uncommitted fake-libpulse.c/.so, SoloistWS, Connect.pm, t/37, ROADMAP) — Voraussetzung für saubere Diffs
- [ ] `SPOTON_BOUNDARY_SPIKE`-Env aus SoloistDaemon.pm entfernen (als temporär markiert)
- [ ] t/29-Stub-Harness: WS-Stub um `lastTrackId` erweitern, browse-Accessors entfernen (Basis für neue Dispatch-Tests)

## Security Domain

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2/V3 Auth/Session | no (keine Auth-Änderung) | — |
| V4 Access Control | yes | Stream-Port bleibt LAN-exponiert wie bisher (deliberate wildcard bind [VERIFIED: fake-libpulse.c:1030-1038]); `POST /boundary` ist auf demselben Port erreichbar — ein LAN-Client könnte Boundaries pflanzen (DoS: vorzeitiges EOF). Bestehende Exposition, keine Verschärfung durch diese Phase; als Known Limitation notieren |
| V5 Input Validation | yes | URI-Regex-Gate in `sendCommand` beibehalten [VERIFIED: SoloistWS.pm:397]; `uri`-Query-Param der bounded URL wird C-seitig ignoriert (kein Parse) — keine neue Injection-Fläche |
| V6 Cryptography | no | — |

### Known Threat Patterns
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed WS-Frames vom Daemon | DoS | eval-guarded `from_json`, kein die (bestehend, beibehalten) |
| LAN-Client POSTet /boundary | DoS (Track-Abbruch) | Bestehende Exposition; Ring-Reconnect heilt; optional künftig Token/Loopback-Check (out of scope, C-seitig) |
| Echo-Loops LMS↔Daemon | Tampering/DoS | Source-Marking (`source(__PACKAGE__)`), URI-Bestätigungs-Check (Pitfall 1) |

## Project Constraints (from CLAUDE.md)

- **Perl >= 5.10, keine externen CPAN-Deps** — alle Änderungen nur mit LMS-bundled Modulen (erfüllt: keine neuen Module).
- **Windows-Lauffähigkeit:** Soloist ist Linux-only (ROADMAP-Risiko), aber ProtocolHandler/Connect/Plugin sind shared mit librespot, das auf Windows läuft — kein Verhalten des librespot-Pfads ändern; keine unix-only Perl-Konstrukte (Memory: `File::Spec`, `main::ISWINDOWS`).
- **GSD-Workflow:** Ausführung über `/gsd-execute-phase`; keine Direkt-Edits.
- **Lokal testen, dann Release** (Memory): Dev-Box-LMS-Verifikation vor jedem Release; Pi-Deploy nur nach Rücksprache.
- **Kein Auto-Release / Versionsnummern nur mit User** (Memory) — Phase 79 ist der Release, Phase 78 endet vor Version-Bump.
- **CHANGELOG bei Release VOR Tag-Push** — für Phase 78 nur vorbereitende Einträge, kein Release.

## Sources

### Primary (HIGH confidence — in dieser Session gelesen)
- `Plugins/SpotOn/ProtocolHandler.pm` (vollständig) — getNextTrack/canDirectStream/getSeekData/Format-Routing
- `Plugins/SpotOn/Unified/SoloistWS.pm` (vollständig) — browseSession-SM, `_signalBoundary`, Event-Übersetzung
- `Plugins/SpotOn/Connect.pm` (vollständig) — `_connectEvent`, `_onPause`/`_onSeek`, D-16, Restart Gate
- `Plugins/SpotOn/Plugin.pm:3900-4100` — Watchdogs (Phase 27)
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:320-1044` — Boundary-Marker, Serve-Loop, Flush-Disconnect, HTTP-Header
- `Plugins/SpotOn/custom-convert.conf` (vollständig)
- `t/29_soloist_browse.t`, `t/31_soloist_ws.t` (Grep+Ausschnitte), `t/32_soloist_events.t` (Struktur), `t/37_connect_lifecycle.t` (Diff)
- `.planning/debug/browse-architecture-review.md`, `.planning/research/playback-architecture-comparison.md`, beide Spike-SUMMARYs, `76-CONTEXT.md`, ROADMAP Phase-77/78-Abschnitte
- `git diff --stat` / Datei-Diffs — uncommitteter Spike-Stand
- Umgebung: `perl -v`, `prove --version`, `systemctl is-active lyrionmusicserver`, `command -v squeezelite`

### Secondary (MEDIUM)
- Knowledge Graph (.planning/graphs/graph.json): Build vom 2026-08-24 — **stale** (vor Spikes), Boundary-Queries leer; nicht verwendet.

### Tertiary (LOW)
- keine (keine Web-Recherche nötig — Phase ist vollständig repo-intern).

## Metadata

**Confidence breakdown:**
- Removal-Inventar: HIGH — jede Zeile aus dem Working-Tree-Quelltext dieser Session
- C-Vertrag: HIGH — Quelltext + Spike-2-E2E-Validierung
- Design-Pitfalls 1-4: HIGH — direkt aus Code-Kollisionen ableitbar (Regex/Claim/Timeout verifiziert)
- Timing-Annahmen (A1, A2, OQ 4): MEDIUM — plausibel aus Code, aber nur im Live-UAT final belegbar

**Research date:** 2026-08-31
**Valid until:** Working-Tree-gebunden — bei jedem Commit auf `soloist` Branch Zeilenreferenzen erneut prüfen (Inventar nennt deshalb immer Funktion + Zeile)
