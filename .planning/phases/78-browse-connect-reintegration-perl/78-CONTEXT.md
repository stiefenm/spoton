# Phase 78: Browse + Connect Reintegration (Perl) - Context

**Gathered:** 2026-08-31
**Status:** Ready for planning

<domain>
## Phase Boundary

ProtocolHandler auf den bounded Audio-Endpoint (Phase 77, Spike 1+2 validiert)
umstellen. ~530 LOC kompensatorischen Browse-Code (browseSession, D-15/D-16/D-17,
Watchdogs, Seeding) entfernen. Connect auf spoton://track:ID URLs umstellen
(gleicher Pfad wie Browse). Betroffene Tests löschen und für das neue Modell
neu schreiben. Inkrementelle Strategie: erst umstellen + testen, dann alten
Code entfernen.

</domain>

<decisions>
## Implementation Decisions

### First-Track-Bootstrap
- **D-01:** Erster Track einer Session serviert unbounded (kein Boundary planted). Boundary erst beim nächsten `track_changed` Event. Kein Sonder-Bootstrap nötig. — **Reversibility:** reversible
- **D-02:** Session-Ende: Daemon 'stopped' `playback_changed` Event → `POST /boundary` → Stream bekommt sauberes EOF. LMS stoppt normal. — **Reversibility:** reversible

### Browse vs Connect Modell
- **D-03:** Gleicher ProtocolHandler-Pfad für Browse und Connect. Beide nutzen `spoton://track:ID` URLs, ProtocolHandler zeigt auf bounded `/stream` Endpoint, getNextTrack holt Track-Metadata per API. Ein Audio-Vertrag für beide. — **Reversibility:** costly — Rückkehr zu zwei getrennten Pfaden erfordert Re-Implementierung der browseSession/Connect-Split-Logik
- **D-04:** Connect wird von `spoton://connect-<ts>` mit `isRepeatingStream=1` auf `spoton://track:ID` Einträge umgestellt. Connect.pm erzeugt bei 'start' einen spoton://track:ID Eintrag, bei `track_changed` einen neuen. `isRepeatingStream` entfällt für Soloist. — **Reversibility:** costly — Connect.pm's streamUrl-Swap und repeating-stream Mechanik müsste wiederhergestellt werden

### Skip/Seek + Flush
- **D-05:** Skip = Flush + implizites EOF. `pa_stream_flush` → `g_flush_disconnect` schließt den Client (bereits implementiert). LMS sieht EOF, ruft `getNextTrack`. Boundary wird invalidiert (`g_boundary_at_pushed = -1`). Gleicher Flow wie natürliches Track-Ende. — **Reversibility:** reversible

### Code-Removal-Strategie
- **D-06:** Inkrementell — erst Browse auf bounded umstellen + testen, dann alten Code entfernen. Zwei separate Commits. Wenn Browse auf bounded funktioniert, ist der alte Code beweisbar tot. — **Reversibility:** reversible
- **D-07:** Browse-spezifische Tests (t/29, t/32, t/37 browseSession-Tests) löschen und neue Tests für das bounded Modell schreiben (EOF bei Boundary, Track-Advance, Connect-Transfer). — **Reversibility:** reversible

### Claude's Discretion
- **Restart Gate Disposition:** Entscheidung ob die Phase-76 Restart Gate entfernt oder vereinfacht wird, basierend auf Code-Analyse ob Session-Restore-Autoplay im neuen Modell noch ein Problem ist
- **Connect.pm Browse-Pfade:** Code-Analyse ob `_soloistBrowseWs`, D-16 stale-claim, browseSession-Checks komplett entfernt oder zu unified Pfad refactored werden
- **Seek-Implementierung:** WS seek + Reconnect vs. `start=` Query-Parameter — basierend auf Aufwand und Kompatibilität

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture Review + Spike Results
- `.planning/debug/browse-architecture-review.md` — Fable 5 Analyse: warum der unbounded Ansatz scheitert, Spike 1+2 Ergebnisse, empfohlene Architektur
- `.planning/research/playback-architecture-comparison.md` — 8-Projekt-Vergleich: Spotty, owntone, Mopidy, Volumio, Snapcast, librespot, go-librespot, Roon. Bounded Facade Empfehlung
- `.planning/quick/260831-boundary-spike-instrument/SUMMARY.md` — Spike 1: keine PA-Lifecycle an Track-Grenzen, Jitter ~30-40ms, WS event-bridged boundary stamping
- `.planning/quick/260831-bounded-endpoint-prototype/SUMMARY.md` — Spike 2: POST /boundary + bounded serving funktioniert, 16ms Overshoot, echtes EOF validiert

### Fake-libpulse (Spike 2 Implementierung — die Basis für Phase 78)
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — Ring-Buffer mit total_pushed/total_popped, POST /boundary, bounded serving, g_boundary_at_pushed. Die C-Seite ist FERTIG — Phase 78 ist rein Perl.
- `Plugins/SpotOn/Unified/SoloistWS.pm` — `_signalBoundary()` bereits implementiert (Spike 2), feuert auf `_onTrackChanged`

### ProtocolHandler + Connect (die zu ändernden Dateien)
- `Plugins/SpotOn/ProtocolHandler.pm` — `getNextTrack` (D-17 gate, Browse re-entry guard), `canDirectStream` (Connect/Browse URL-Handling), `isRepeatingStream`, `formatOverride` ('soc' Profil)
- `Plugins/SpotOn/Connect.pm` — `_connectEvent` (start/change/stop/seek), `_onPause` (Browse-Forwarding, D-16 stale-claim), `isSpotifyConnect`, repeating-stream lifecycle
- `Plugins/SpotOn/Plugin.pm` — `_onNewSongWatchdog`, `_prefetchWatchdog`, `_pauseGuardCheck`
- `Plugins/SpotOn/Unified/SoloistWS.pm` — browseSession, `_emitAllowed`, `_onBrowseTrackChanged`, `waitForBrowseReady`, `startBrowseTrack`, `_maybeSeedBrowseQueue`, `endBrowseSession`

### Spotty v4.4.9 (Referenz für Connect-Pattern)
- `.planning/research/playback-architecture-comparison.md` §1 — Spotty Connect: muted daemon, repeating-stream, Web API playerNext, SEEK_THRESHOLD=3s, _syncController, optimizePreBuffer

### Prior Phase Context
- `.planning/phases/76-connect-stabilization-flac24-integration/76-CONTEXT.md` — Phase 76 Decisions (D-04 S32LE, D-05 soc flc, D-06 Auto-Modus, D-12 8s Gap)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_signalBoundary()` in SoloistWS.pm — bereits implementiert (Spike 2), POST /boundary auf _onTrackChanged
- `g_flush_disconnect` Mechanismus — Skip/Seek-Handling bereits fertig (260827-of9)
- Connect.pm `_connectEvent` Framework — start/change/stop/seek Event-Handling bleibt, nur die Track-URL-Erzeugung ändert sich
- ProtocolHandler `canDirectStream` — zeigt bereits auf daemon HTTP-Port für Soloist, muss nur URL-Pfad anpassen

### Established Patterns
- librespot Backend nutzt `--single-track` mit echtem EOF → das ist der Vertrag den bounded Soloist jetzt auch erfüllt
- `formatOverride` gibt 'soc' für Connect-URLs → gleicher Profil-Name für Soloist bounded
- Source-Marking (`$request->source(__PACKAGE__)`) für Loop-Prevention bei Commands

### Integration Points
- ProtocolHandler::getNextTrack — Haupteinstiegspunkt, D-17 gate muss entfernt werden
- Connect.pm::_connectEvent('start') — muss spoton://track:ID statt spoton://connect-<ts> erzeugen
- Connect.pm::_connectEvent('change') — muss neuen Track-Eintrag erzeugen statt streamUrl swap
- SoloistWS.pm::_onTrackChanged — _signalBoundary bereits da, browseSession-Logik muss weg
- Plugin.pm::_prefetchWatchdog — Browse-spezifische Pfade entfernen

</code_context>

<specifics>
## Specific Ideas

- Spotty v4.4.9 Connect-Pattern als Referenz: SEEK_THRESHOLD=3s für Position-Sync, _syncController für Near-End-Resync, optimizePreBuffer für große Buffer
- Daemon 'stopped' Event → POST /boundary → EOF als sauberer Session-End-Mechanismus
- Inkrementelle Strategie: Wave 1 = bounded Browse funktioniert, Wave 2 = alter Code entfernt

</specifics>

<deferred>
## Deferred Ideas

- **FFmpeg-Hook für encoded Audio (OGG/Vorbis)** — Zukunftsoption dokumentiert in playback-architecture-comparison.md §12. Nicht für v4.0.
- **Private Audio-Research** — ~/spoton-private/ Projekt, separate Session
- **soc flc convert-Regel** — Phase 76 D-05, DEFERRED. Braucht eigene Phase nach bounded Facade.
- **Gapless Playback** — owntone-Pattern (shared buffer + boundary markers ~2s vor EOF) als Zukunftsoption. Bounded Facade mit per-Track-EOF hat inhärent eine kleine Lücke beim Reconnect.

</deferred>

---

*Phase: 78-Browse + Connect Reintegration (Perl)*
*Context gathered: 2026-08-31*
