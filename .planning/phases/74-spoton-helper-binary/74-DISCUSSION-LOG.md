# Phase 74: spoton-helper Binary - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-08-28
**Phase:** 74-spoton-helper-binary
**Areas discussed:** Scope-Kalibrierung, Patch-Strategie, Build & Distribution, check-Modus Scope

**Pre-discussion:** Fable 5 Review der ROADMAP Phase 74-77 gegen Spike 008/009 + Phase 73 Outcomes. ROADMAP aktualisiert (daemon/audio als erledigt markiert, Spike-Ergebnisse eingearbeitet, Progress Table ergänzt).

---

## Scope-Kalibrierung

| Option | Description | Selected |
|--------|-------------|----------|
| Rust-Binary (Empfohlen) | Eigenständiges spoton-helper mit Cargo/cross-rs. Erweiterbar, gleiche CI-Pipeline wie librespot. | ✓ |
| Reines Shell/Python | Patch-Logik als Script. Einfacher, aber fragiler und nicht cross-compile-fähig. | |
| FLAC24 raus, nur Lifetime | Nur validierten Lifetime-Patch. FLAC24 später wenn mehr Daten da. | |

**User's choice:** Rust-Binary
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Einschließen (best effort) | Pattern-Scanner für die 5 sicheren Gates, Gate 4 auslassen. Server-seitige Quality-Zuweisung separat. | ✓ |
| Verschieben auf Phase 76 | Erst klären ob Spotify FLAC24 liefert. Kein Aufwand in toten Code. | |
| Du entscheidest | Researcher evaluiert Machbarkeit. | |

**User's choice:** FLAC24 einschließen, best effort
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Nur patch+check | Schlanker Scope, Phase 75 löst Protobuf in Perl. | |
| Protobuf vorbereiten | spoton-helper bekommt protobuf-Subcommand. Phase 75 kann wahlweise nutzen. | ✓ |
| Du entscheidest | Researcher evaluiert ob Perl-Protobuf realistisch ist. | |

**User's choice:** Protobuf-Subcommand vorbereiten
**Notes:** —

---

## Patch-Strategie

| Option | Description | Selected |
|--------|-------------|----------|
| Bei Installation (Empfohlen) | Einmalig nach Download, gepatchte Binary wird gespeichert. | ✓ |
| On-Demand (jedes Mal) | Original bleibt, temporäre Kopie bei jedem Start. | |
| Beides: Patch + Verify | Patcht bei Installation, verifiziert bei jedem Start. | |

**User's choice:** Bei Installation
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Fail-closed + Warnung | Pattern nicht gefunden → Soloist läuft ungepatcht. | |
| Heuristischer Scan | Breiterer Match, auch bei verschobenen Offsets. Riskanter. | |
| Version-Lock | Nur gepinnte Version (1.3.7.489). Bei anderer Version kein Patch-Versuch. | ✓ |

**User's choice:** Version-Lock
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Pro-Arch Pattern-Tabelle | Jede Architektur hat eigene Byte-Patterns als Konstanten. | |
| ELF-Parser + Disassembly | Binary parsen, Instruktionen dekodieren. Flexibler, komplexer. | |
| Du entscheidest | Researcher analysiert konkrete Patterns der 3 Architekturen. | ✓ |

**User's choice:** Du entscheidest
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Automatisch bei Installation | Immer angewendet, kein Toggle. | ✓ |
| Settings-Toggle | User kann wählen ob Lifetime gepatcht wird. | |
| CLI-Flag only | Nur für Power-User die manuell patchen. | |

**User's choice:** Automatisch bei Installation
**Notes:** —

---

## Build & Distribution

| Option | Description | Selected |
|--------|-------------|----------|
| Bin/<arch>/ (Empfohlen) | Neben librespot im Plugin-Zip. Gleiches Pattern. | ✓ |
| Separater Download | Nicht im Zip, bei Bedarf heruntergeladen. | |
| Cachedir (wie Soloist) | Unter cachedir/spoton/helper/<arch>/. | |

**User's choice:** Bin/<arch>/
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| In build-librespot.yml | Zusätzlicher Job im bestehenden Workflow. | |
| Eigener Workflow | build-spoton-helper.yml separat. | |
| Du entscheidest | Researcher analysiert bestehende Pipeline. | ✓ |

**User's choice:** Du entscheidest
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Automatisch (Empfohlen) | Soloist.pm ruft nach Download automatisch spoton-helper patch auf. | ✓ |
| Manuell / CLI only | User muss spoton-helper patch manuell aufrufen. | |
| Settings-Button | Button in Settings der Vorgang auslöst. | |

**User's choice:** Automatisch
**Notes:** —

---

## check-Modus Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Patch-Status | Prüft ob Patches angewendet wurden. JSON mit Details. | ✓ |
| Binary-Integrität | SHA256 gegen gespeicherten Hash. | ✓ |
| Arch + Version | Erkennt Architektur und Version. Capability-Manifest als JSON. | ✓ |
| Protobuf-Test | Smoke-Test für Protobuf-Decoder. | |

**User's choice:** Patch-Status + Binary-Integrität + Arch/Version (3 von 4)
**Notes:** —

| Option | Description | Selected |
|--------|-------------|----------|
| Eigenes Format (Empfohlen) | JSON mit spoton-helper-spezifischen Feldern. Nicht librespot-kompatibel. | ✓ |
| Librespot-kompatibel | Gleiches Basis-Schema wie librespot --check. | |
| Du entscheidest | Researcher schaut sich librespot --check Format an. | |

**User's choice:** Eigenes JSON-Format
**Notes:** —

---

## Claude's Discretion

- Multi-Arch Pattern-Scanner-Ansatz (Pro-Arch Pattern-Tabelle vs. ELF-Parser + Disassembly)
- CI-Workflow-Integration (eigener Workflow vs. Job in build-librespot.yml)
- Cargo-Projektstruktur (Workspace, Dependencies)

## Deferred Ideas

- login5 Token-Minting in Perl → Phase 75
- Cached-Datei Decryption als spoton-helper `decrypt` Subcommand → geparkt
- Per-Player Backend-Auswahl → Phase 76
- Quality-Dropdown → Phase 76
- Pairing-Flow-Ausbau → Phase 76
