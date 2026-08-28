# Phase 75: API Unification (spclient-Modell) - Context

**Gathered:** 2026-08-28
**Status:** Ready for planning

<domain>
## Phase Boundary

SpClient.pm als neue API-Schicht für spclient.spotify.com, die alle Browse/Search/Library-Calls von api.spotify.com/v1 (Client.pm) ablöst. Login5 Token-Minting in Perl (librespot CID `65b708...`, challenge-frei). Capability-basiertes Routing: stored credentials vorhanden → spclient, sonst automatischer Fallback auf Client.pm. Client.pm bleibt ausschließlich für Player-Control (me/player/*).

Endpunkte: Metadata (JSON via Accept Header), Collection/v2 (Protobuf), Context-Resolve (JSON, inkl. Liked Songs ohne Paging), Recently-Played (Protobuf), Playlists + Rootlist (JSON/Protobuf). Protobuf-Decoding in Perl (ProtobufLite.pm, generischer Wire-Parser). Kein HashSource/api-partner/Pathfinder nötig — Ein-Host-Modell (Spike 009 verifiziert).

</domain>

<decisions>
## Implementation Decisions

### Protobuf-Strategie
- **D-01:** Perl Mini-Decoder (ProtobufLite.pm, ~80 LOC generischer Wire-Parser) als einziger Protobuf-Pfad. Kein External-Prozess-Spawn. Überspringt unbekannte Felder automatisch (zukunftssicher bei Schema-Erweiterungen). Deckt collection/v2 (PageRequest Encoding + PageResponse Decoding), recently-played (URI-Extraktion) und rootlist ab. — **Reversibility:** reversible
- **D-02:** protobuf-Subcommand aus spoton-helper zurückbauen. Entfernt ~505 LOC Rust + 10 .proto-Dateien + protobuf/protobuf-codegen Crates. Beschleunigt Cross-Builds, verkleinert Rust-Wartungsfläche. Helper behält nur `patch` + `check`. Die vendored .proto-Dateien bleiben als Schema-Dokumentation im Repo. — **Reversibility:** costly — Wiederaufbau erfordert Codegen-Pipeline + Crate-Dependencies neu einrichten

### Client-Architektur
- **D-03:** SpClient.pm als komplett eigenständiges Modul neben Client.pm. Eigene `_request()`, eigener Inflight-Counter, eigener Rate-Key (`spoton_spclient_rate_limit`). Keine Abhängigkeit SpClient ↔ Client in beide Richtungen. Client.pm bleibt unverändert (70KB battle-tested, H1/CR-01/GH#155-Fixes). Entspricht LMS-Idiomatik (Qobuz, TIDAL, Spotty splitten nach Host-Domäne). — **Reversibility:** reversible
- **D-04:** Login5.pm als eigenes Token-Minting-Modul. Konsumiert stored credentials aus Credentials.pm, mintet login5 Bearer Token (librespot CID, ~1h TTL). Eigener Cache-Key (`spoton_login5_token_${accountId}`). TokenManager.pm bleibt PKCE-only, unverändert. — **Reversibility:** reversible
- **D-05:** HTTPUtil.pm optional — nur einführen wenn beim Schreiben von SpClient.pm tatsächlich 1:1 kopierte Funktionen aus Client.pm entstehen (Retry-After-Parse, CB-Guard, Timer-Retry). Client.pm-Umstellung darauf ist nicht Voraussetzung für Phase 75. — **Reversibility:** reversible

### Token-Routing
- **D-06:** Capability-basiertes Routing, nicht backend-basiert. Entscheidungskriterium: "Hat der Account login5-fähige stored credentials (ZeroConf/Keymaster/Soloist-Provenance)?" → spclient-Pfad. "Nur PKCE?" → Client.pm-Fallback. ZeroConf-gepairte librespot-Nutzer profitieren automatisch. PKCE-only-Kohorte (needsPlaybackAuth) merkt keinen Unterschied. — **Reversibility:** reversible
- **D-07:** Automatischer Fallback auf Client.pm bei spclient-Fehlern (nicht nur bei fehlenden Credentials). spclient ist inoffizielles API — Aug-10-Blockade (GH #147) beweist, dass Spotify ohne Vorwarnung ändert. Fehler-Klassifikation im Router: HTTP 4xx/5xx → Fallback, kein Retry auf spclient. — **Reversibility:** reversible

### Umstellungs-Scope
- **D-08:** Volle Unification — alle Browse/Search/Library-Calls (~60 Call-Sites in Plugin.pm, ProtocolHandler.pm, Connect.pm, DontStopTheMusic.pm) auf spclient umstellen. Client.pm bleibt ausschließlich für Player-Control (me/player/play, pause, volume, seek, transfer, devices, queue). Response-Shape-Normalisierung nötig (spclient-JSON ≠ Web-API-JSON). — **Reversibility:** costly — Rückbau auf Client.pm erfordert Shape-Denormalisierung an ~60 Call-Sites
- **D-09:** Rate-Pool-Awareness: login5-Token (librespot CID) teilt Rate-Pool mit dem laufenden Daemon. SpClient.pm Throttle muss konservativer sein als Client.pm's PKCE-Pool. Bekanntes Risiko: Browse-Bursts während Playback können Audio-Key-Throttle triggern (Rapid-Skip KE). — **Reversibility:** reversible

### Claude's Discretion
- Login5.pm ↔ TokenManager.pm Integration — ob Login5 völlig getrennt bleibt oder TokenManager eine getSpClientToken()-Convenience bekommt
- Response-Shape-Normalisierung — ob spclient-Responses in Web-API-kompatible Shapes konvertiert werden (Caller bleiben unverändert) oder ob Caller an neue Shapes angepasst werden
- SpClient.pm Endpunkt-Methoden-Design (Signatur, Caching-TTLs, Error-Handling-Pattern)
- base62↔hex ID-Konversion — Utility-Funktion in SpClient.pm oder eigenes Modul
- collection/v2 Pagination-Strategie (alle Seiten auf einmal vs. lazy on-demand)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike-Ergebnisse (Architektur-Basis)
- `.planning/spikes/009-spclient-mercury-browse/RESULTS.md` — Ein-Host-Modell verifiziert, vollständiger Endpunkt-Katalog, 11 Stolpersteine (S-01 bis S-11), Token-Flow, Set-Mapping, Auth-Modell. **KRITISCH — muss komplett gelesen werden.**

### Spike Findings (Auth Golden Path)
- `.claude/skills/spike-findings-spoton/SKILL.md` — PKCE + Credential-Bridge Patterns, Connect ohne mDNS
- `.claude/skills/spike-findings-spoton/references/credential-bridge.md` — Credential derivation (relevant für Login5.pm Credential-Input)

### Phase 71-74 Kontext (Vorgänger)
- `.planning/phases/74-spoton-helper-binary/74-CONTEXT.md` — spoton-helper Architektur, protobuf-Subcommand (D-02: wird zurückgebaut)
- `.planning/phases/73-soloist-connect-mode/73-CONTEXT.md` — SoloistDaemon.pm, WS-API, DaemonManager-Erweiterung
- `.planning/phases/72-soloist-browse-playback/72-CONTEXT.md` — contentType son/sol, Backend-Routing

### Bestehende API-Architektur
- `Plugins/SpotOn/API/Client.pm` — Zentraler Web-API-Client (70KB). _request()/_doRequest() Zeilen 1358-1642. Pathfinder-Routing-Präzedenzfall (WebPlayer->getToken, Zeile 822). Player-Control Methoden (Zeilen 1304-1357). **Bleibt unverändert.**
- `Plugins/SpotOn/API/TokenManager.pm` — PKCE Token-Management. **Bleibt unverändert.**
- `Plugins/SpotOn/API/Credentials.pm` — Credential Storage, Provenance-Tracking, needsPlaybackAuth-Flag (Zeile 30-35), Login5-Provenance-Blockade (Zeile 101-105, GH #147)
- `Plugins/SpotOn/API/WebPlayer.pm` — sp_dc → WebPlayer Token (Routing-Vorbild für Login5.pm)

### Protobuf-Schemas
- librespot upstream `protocol/proto/collection2v2.proto` — PageRequest/PageResponse/CollectionItem Schema

### Roadmap
- `.planning/ROADMAP.md` §Active — v4.0 Soloist Integration, Phase 75 Beschreibung

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Client.pm` Pathfinder-Routing (Zeile 822): Per-Call Token-Provider-Wechsel (`WebPlayer->getToken` statt `TokenManager->getToken`). Architektur-Vorlage für SpClient.pm Login5-Integration.
- `Client.pm` 429-Retry-Pattern: Retry-After-Parse, Clamp 1-300s, Timer-Retry. Kann als Vorlage für SpClient.pm dienen (oder in HTTPUtil.pm extrahiert).
- `Credentials.pm` stored-credential-Zugriff: `getStoredCredentials($accountId)` liefert credentials.json-Inhalt. Input für Login5.pm.
- `DaemonManager.pm` Backend-Dispatch: `$isLibrespot`/`$isSoloist` Pattern. Referenz für capability-basiertes Routing.

### Established Patterns
- Per-Call Token-Routing: Bereits implementiert (Pathfinder → WebPlayer, Browse → TokenManager)
- Rate-Key-Isolation: `spoton_rate_limit` vs. `spoton_wp_rate_limit` — SpClient bekommt `spoton_spclient_rate_limit`
- Account-scoped Cache-Keys: `spoton_token_${accountId}` Pattern
- SimpleAsyncHTTP non-blocking: Alle API-Calls async über LMS Event-Loop

### Integration Points
- `Plugin.pm` Browse/Search/Library-Calls (~45 Sites) → umstellen auf SpClient.pm (mit Routing-Facade)
- `ProtocolHandler.pm` Track/Album/Playlist-Resolution (~9 Sites) → umstellen auf SpClient.pm
- `Connect.pm` getTrack → umstellen auf SpClient.pm
- `DontStopTheMusic.pm` search/getTopTracks → umstellen auf SpClient.pm
- `Settings.pm` Limit-Probing → entfällt für spclient (keine Dev-Mode-Limits)

</code_context>

<specifics>
## Specific Ideas

- Capability-Routing als Facade: Gleiche Methoden-Signatur wie Client.pm, intern Dispatch nach Credential-Verfügbarkeit. Caller müssen idealerweise nur den Import ändern, nicht die Aufruf-Logik.
- login5 Token-Minting: Spike-validierter Parser aus `scratchpad/spclient-test.py` → `parse_protobuf_simple()` als Perl-Referenz. Varint-Parser S-01 beachten (Multi-Byte-Varints, sonst Token truncated auf 31 chars).
- Set-Mapping (verifiziert): `collection`=Saved Albums, `artist`=Followed Artists, `show`=Saved Shows, `ylpin`=Pinned Playlists, `listenlater`=Saved Episodes. Liked Songs via context-resolve `spotify:user:{id}:collection`.
- ProtobufLite.pm Testvektoren: Phase 74 Rust-Testfixtures direkt als Perl-Testvektoren wiederverwenden.
- spclient liefert in Dev Mode entfernte Felder: `popularity` (Track/Album/Artist), `label` (Album) — UI kann diese wieder anzeigen.
- Search über context-resolve: 20 Results statt 10 (Dev Mode). Aber nur Track-URIs, kein Multi-Type-Search → Web API Fallback für Album/Artist/Playlist-Search.

</specifics>

<deferred>
## Deferred Ideas

- **Probe-Logik entfernen** — Client.pm's `probeEndpointLimits()` wird nach vollständiger spclient-Migration überflüssig. Cleanup in Phase 76 oder 77.
- **WebPlayer.pm / Pathfinder entfernen** — sp_dc/Pathfinder-Pfad wird nach spclient-Migration nicht mehr benötigt. Cleanup nach UAT-Bestätigung.
- **collection/v2/write** — Like/Unlike/Follow via spclient (noch nicht getestet im Spike). Eigene Phase.
- **searchview-Endpunkt** — Multi-Type-Search über spclient (aktuell 400). Wenn Spotify das öffnet, eigene Phase.

</deferred>

---

*Phase: 75-API Unification (spclient-Modell)*
*Context gathered: 2026-08-28*
