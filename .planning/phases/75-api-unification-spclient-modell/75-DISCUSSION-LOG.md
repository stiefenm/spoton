# Phase 75: API Unification (spclient-Modell) - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-08-28
**Phase:** 75-API Unification (spclient-Modell)
**Areas discussed:** Protobuf-Decoder-Strategie, Client-Architektur, Token-Routing & login5, Umstellungs-Scope

---

## Protobuf-Decoder-Strategie

**Fable-5 Beratung hinzugezogen** — User wollte fundierte Analyse zu Pi-Performance, Architektur-Sauberkeit und Rückbau-Kosten.

| Option | Description | Selected |
|--------|-------------|----------|
| spoton-helper protobuf (One-Shot CLI) | Pro API-Call ein fork+exec, schema-validiert (Rust Codegen), bereits in Phase 74 gebaut | |
| Perl Mini-Decoder (~80 LOC) | Generischer Wire-Parser in Perl, kein Prozess-Spawn, ~3-5ms/Page auf Pi 2/3 | ✓ |
| spoton-helper als Daemon | Persistent, kein Spawn-Overhead, hypothetische Basis für Soloist-Management | |
| Hybrid: Regex + Helper | Regex für simple Fälle, Helper für komplexe | |

**User's choice:** Perl Mini-Decoder + protobuf-Subcommand aus spoton-helper zurückbauen (Option A + D)
**Notes:** User fragte zunächst warum der Helper nicht als Daemon läuft. Fable-5 Analyse zeigte: Hauptproblem ist nicht Pi-Performance, sondern Event-Loop-Blocking + Windows-Inkompatibilität (select() auf Pipes). Daemon-Option abgelehnt wegen "keine Zombie-Daemons" Kernversprechen und fehlender Abnehmer. Payloads sind winzig (~5KB), Schemas seit Jahren stabil.

---

## Client-Architektur

**Fable-5 Beratung hinzugezogen** — User wollte fundierte Analyse des _request()-Codes.

| Option | Description | Selected |
|--------|-------------|----------|
| Eigenständiges SpClient.pm | Eigene _request(), eigenes Rate-Limiting, kein Shared Code mit Client.pm | ✓ |
| Shared Base-Klasse | Gemeinsame Basis-Infrastruktur extrahiert aus Client.pm | |
| Client.pm erweitern | Multi-Host-Client, alles in einem 70KB+ Modul | |

**User's choice:** Eigenständiges SpClient.pm (Option A)
**Notes:** Fable-5 analysierte _doRequest() (Z. 1358-1642, ~285 LOC) und fand: Host-neutraler Anteil nur ~60-80 LOC. Rest ist api.spotify.com-spezifisch (Probe, Dev-Mode-Limits, _cacheTTL). Client.pm hat dokumentierte Fix-Historie (H1, CR-01, GH#155) — Refactoring-Risiko überwiegt DRY-Gewinn. LMS-Idiomatik bestätigt: Qobuz/TIDAL/Spotty splitten nach Host-Domäne.

---

## Token-Routing & login5

| Option | Description | Selected |
|--------|-------------|----------|
| Komplett getrennt | Login5.pm als reiner Token-Minter, TokenManager weiß nichts von login5 | |
| TokenManager als Router | TokenManager bekommt getSpClientToken() | |
| Du entscheidest | Claude's Discretion | ✓ (Integration) |

**User's choice:** Claude's Discretion für Login5↔TokenManager Integration
**Notes:** User stellte klar, dass die Credential-Quelle bereits designed ist: Soloist-Pairing (analog ZeroConf) liefert stored credentials → login5 → Bearer Token. Keine offene Frage.

---

## Umstellungs-Scope

**Fable-5 Beratung hinzugezogen** — User wollte fundierte Analyse inkl. Impact auf librespot-Backend.

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal: Nur Layer bauen | SpClient.pm bauen, keine Caller umstellen | |
| Mittel: High-Value-Calls | Layer + Search/Metadata/Liked Songs umstellen, Rest bleibt | |
| Maximal: Volle Unification | Alle ~60 Browse/Library-Calls umstellen, Client.pm nur Player-Control | ✓ |

**User's choice:** Volle Unification (Maximal)
**Notes:** Fable-5 empfahl mittleren Scope wegen Regressionsfläche und PKCE-only-Kohorte. User entschied sich bewusst für Maximal. Wichtiger Befund aus der Analyse: stored credentials sind NICHT universell vorhanden (Login5-Provenance-Blockade GH #147). Routing muss capability-basiert sein (stored creds vorhanden → spclient, sonst → Client.pm Fallback). User verstand das Routing-Diagramm und entschied trotzdem für volle Umstellung.

---

## Claude's Discretion

- Login5.pm ↔ TokenManager.pm Integration (getrennt vs. Convenience-Methode)
- Response-Shape-Normalisierung (spclient → Web-API-kompatibel vs. Caller anpassen)
- SpClient.pm Endpunkt-Methoden-Design (Signaturen, Caching-TTLs)
- base62↔hex ID-Konversion (Utility-Placement)
- collection/v2 Pagination-Strategie
- HTTPUtil.pm: nur einführen wenn tatsächlich 1:1 Code-Duplikation entsteht

## Deferred Ideas

- Probe-Logik aus Client.pm entfernen (nach vollständiger Migration)
- WebPlayer.pm / Pathfinder entfernen (nach UAT-Bestätigung)
- collection/v2/write (Like/Unlike/Follow via spclient) — eigene Phase
- searchview-Endpunkt (Multi-Type-Search über spclient) — eigene Phase
