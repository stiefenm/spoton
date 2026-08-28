# Phase 74: spoton-helper Binary - Context

**Gathered:** 2026-08-28
**Status:** Ready for planning

<domain>
## Phase Boundary

Eigenständiges Rust-Binary `spoton-helper` mit drei Subcommands: `patch` (Lifetime-Timestamp + FLAC24-Enum Pattern-Scanner), `check` (Binary-Validierung, Patch-Status, Integrität) und `protobuf` (Protobuf↔JSON Konversion für Phase 75). CI-Build für x86_64, arm64, arm32 via cross-rs. Binary wird im Plugin-Zip unter `Bin/<arch>/` mitgeliefert.

**Nicht mehr Teil von Phase 74 (erledigt in Phase 73):**
- ~~`daemon` (Soloist-Lifecycle)~~ → SoloistDaemon.pm + DaemonManager (Perl)
- ~~`audio` (fake-libpulse)~~ → fake-libpulse.c mit HTTP-Server (C, CI-cross-kompiliert)
- ~~`token` (HashCash/login5)~~ → login5 in Perl machbar (Spike 009, librespot CID challenge-frei)

Soloist ist Linux-only (x86_64, arm64, arm32). macOS/Windows bleiben bei librespot.

</domain>

<decisions>
## Implementation Decisions

### Scope & Architektur
- **D-01:** Eigenständiges Rust-Binary (`spoton-helper`) mit drei Subcommands: `patch`, `check`, `protobuf`. Cargo-Projekt mit cross-rs für 3 Architekturen. — **Reversibility:** costly — Umstellung auf Shell/Python erfordert Neuimplementierung der Byte-Pattern-Logik und Protobuf-Handling
- **D-02:** `protobuf`-Subcommand für Protobuf↔JSON Konversion. Phase 75 (SpClient.pm) kann wahlweise Perl-Decoder ODER spoton-helper als Backend nutzen. Deckt collection/v2, recently-played und rootlist ab. — **Reversibility:** reversible

### Patch-Strategie
- **D-03:** Patching bei Installation — einmalig nach Soloist-Download. Gepatchte Binary wird gespeichert, kein On-Demand-Patching bei jedem Start. Soloist.pm triggert `spoton-helper patch` automatisch nach erfolgreichem Download + Extraktion. — **Reversibility:** reversible
- **D-04:** Version-Lock — Patches nur für die gepinnte Soloist-Version (1.3.7.489). Bei anderer Version kein Patch-Versuch. Expliziter Support pro Version, neue Version erfordert SpotOn-Update mit aktualisierten Patterns. — **Reversibility:** one-way — Wechsel zu heuristischem Scan erfordert grundlegend anderen Ansatz und riskiert Binary-Korruption
- **D-05:** Lifetime-Patch immer automatisch, kein Settings-Toggle. ASCII-Timestamp in .rodata ersetzen, validiert im Spike (25696 Tage). — **Reversibility:** reversible
- **D-06:** FLAC24-Enum-Patch best effort — 5 von 6 Gates patchen, Gate 4 bewusst auslassen (Crash). Server-seitige Quality-Zuweisung ist ungeklärt (A/B-Test zeigte identische CDN-Größen), wird aber nicht blockierend behandelt — Patch vorbereiten, Effekt in Phase 77 UAT verifizieren. — **Reversibility:** reversible

### check-Modus
- **D-07:** `spoton-helper check` validiert drei Aspekte: (1) Patch-Status (Lifetime + FLAC24 Gates angewendet?), (2) Binary-Integrität (SHA256 gegen gespeicherten Hash), (3) Architektur + Version der Soloist-Binary. — **Reversibility:** reversible
- **D-08:** Eigenes JSON-Format (nicht librespot-kompatibel): `{version, arch, soloist_version, patches: {lifetime: bool, flac24_gates: [bool]}, sha256, patched: bool}`. Soloist.pm konsumiert dieses Format für Settings-Anzeige. — **Reversibility:** reversible

### Build & Distribution
- **D-09:** Binary im Plugin-Zip unter `Plugins/SpotOn/Bin/<arch>/spoton-helper`. Gleicher Ort wie librespot. Kein separater Download. — **Reversibility:** reversible

### Claude's Discretion
- Multi-Arch Pattern-Scanner-Ansatz (Pro-Arch Pattern-Tabelle vs. ELF-Parser + Disassembly) — Researcher analysiert die konkreten Byte-Patterns der 3 Architekturen und empfiehlt
- CI-Workflow-Integration (eigener Workflow vs. Job in build-librespot.yml) — Researcher analysiert bestehende Pipeline und wählt pragmatischsten Weg
- Cargo-Projektstruktur (Workspace vs. einzelnes Crate, Dependency-Auswahl für Protobuf-Handling)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike-Ergebnisse (Architektur-Basis)
- `.planning/spikes/008-soloist-token-discovery/RESULTS.md` — KDF gelöst, Block-Cipher identifiziert, `cached`-Datei = login5-StoredCredential. Lifetime-Patch validiert, FLAC24 5/6 Gates. GDB-Decryption-Tool als Referenz.
- `.planning/spikes/009-spclient-mercury-browse/RESULTS.md` — spclient Ein-Host-Modell, collection/v2 Protobuf-Schema, Set-Mapping, 11 Stolpersteine (S-01 bis S-11). Proto-Schema `collection2v2.proto` in librespot upstream.

### Phase 71-73 Kontext (Vorgänger)
- `.planning/phases/71-soloist-foundation/71-CONTEXT.md` — Soloist.pm Architektur, Version-Pin, Bin/<arch>/ Pattern, fake-libpulse CI-Build
- `.planning/phases/72-soloist-browse-playback/72-CONTEXT.md` — contentType son/sol, custom-convert.conf (inzwischen durch Phase 73 ersetzt)
- `.planning/phases/73-soloist-connect-mode/73-CONTEXT.md` — SoloistDaemon.pm, WS-API, HTTP-Audio, Vendor Protocol::WebSocket, Phase-72-Rückbau

### Bestehende Architektur
- `Plugins/SpotOn/Soloist.pm` — Binary-Discovery, Download, _versionCheck, SOLOIST_VERSION Pin, ensureBinary(). Integration-Punkt für auto-patch nach Download.
- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c` — 2329 LOC C, HTTP-Server (Ring, f32→S16LE), 3-Arch CI-Build. Referenz für Audio-Shim (erledigt, kein Rust-Port geplant).
- `.github/workflows/build-librespot.yml` — Bestehende Rust-CI-Pipeline (cross-rs, Tag-Trigger, Release-Job). Möglicher Integration-Punkt für spoton-helper Build.
- `.github/workflows/build-fake-libpulse.yml` — C-Build-Pipeline (glibc cross-gcc, 3 Architekturen). Referenz für alternative CI-Architektur.

### Protobuf-Schemas (für protobuf-Subcommand)
- librespot upstream `protocol/proto/collection2v2.proto` — PageRequest/PageResponse/CollectionItem/WriteRequest Schema

### Roadmap
- `.planning/ROADMAP.md` §Active — v4.0 Soloist Integration, Phase 74 Beschreibung (aktualisiert 2026-08-28)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Soloist.pm` ensureBinary(): Download + Extraktion + _versionCheck Pipeline. Integration-Punkt für auto-patch (D-03): nach erfolgreichem Download `spoton-helper patch` aufrufen.
- `Helper.pm` get()/helperCheck(): Binary-Finder Pattern mit `--check` JSON-Parsing. Referenz für spoton-helper check JSON-Konsumption in Soloist.pm.
- `.github/workflows/build-librespot.yml`: Cross-rs Pipeline mit matrix.include für 6 Targets. Adaptierbar für spoton-helper (3 Linux-Targets).

### Established Patterns
- Binary unter `Bin/<arch>/`: librespot + fake-libpulse.so.0 liegen dort bereits
- `--check` JSON-Manifest: librespot gibt Capabilities als JSON aus, Helper.pm parst es
- Version-Pin als Konstante: `SOLOIST_VERSION => '1.3.7.489'` in Soloist.pm

### Integration Points
- `Soloist.pm::ensureBinary()` → nach Download: `spoton-helper patch` aufrufen (async oder sync)
- `Soloist.pm::_versionCheck()` → `spoton-helper check` Ergebnis konsumieren für Patch-Status-Anzeige
- `Settings.pm` Soloist-Sektion → Patch-Status anzeigen (gepatcht/ungepatcht, welche Patches aktiv)
- Phase 75 `SpClient.pm` → `spoton-helper protobuf` als Protobuf↔JSON Backend aufrufen

</code_context>

<specifics>
## Specific Ideas

- Lifetime-Patch: ASCII-Timestamp in .rodata (10 Zeichen), Drop-in-Replace. Spike-validiert mit "25696 days" Ergebnis.
- FLAC24: 6 Enum-Downgrade-Gates (cmp 6/mov 5), 5 davon sicher patchbar. Gate 4 crasht → bewusst auslassen. Instruction Encoding unterscheidet sich zwischen x86_64 (cmp imm8), arm64 (cmp wN, #imm) und arm32 (cmp rN, #imm).
- Protobuf-Subcommand: stdin→stdout Pipe-Modus (Perl schickt Protobuf rein, bekommt JSON zurück). Deckt collection/v2 (PageRequest/PageResponse), recently-played (URI-Extraktion) und rootlist.
- Version-Lock: `spoton-helper patch --version 1.3.7.489` — Patch nur wenn Soloist-Binary diese Version meldet. Sonst Exit 1 mit JSON-Error.

</specifics>

<deferred>
## Deferred Ideas

- **login5 Token-Minting** — In Perl machbar (Spike 009: librespot CID, kein HashCash). Gehört zu Phase 75 (SpClient.pm), nicht Phase 74.
- **Cached-Datei Decryption** — KDF + Cipher gelöst (Spike 008), GDB-Tool existiert. Könnte in spoton-helper als `decrypt`-Subcommand landen, aber kein klarer Use Case ohne login5 Token-Minting im Helper. Geparkt.
- **Per-Player Backend-Auswahl** — Phase 76 (UX Polish)
- **Quality-Dropdown (OGG/FLAC/Lossless)** — Phase 76
- **Pairing-Flow-Ausbau** — Phase 76 (Basis aus 73-04 existiert)

</deferred>

---

*Phase: 74-spoton-helper Binary*
*Context gathered: 2026-08-28*
