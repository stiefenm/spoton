# Phase 74: spoton-helper Binary - Research

**Researched:** 2026-08-28
**Domain:** Rust CLI utility (binary patcher + protobuf converter), cross-rs multi-arch CI, Perl↔binary integration
**Confidence:** HIGH (engineering approach), MEDIUM (FLAC24 server-side effect — unresolved by design, D-06)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Scope & Architektur**
- **D-01:** Eigenständiges Rust-Binary (`spoton-helper`) mit drei Subcommands: `patch`, `check`, `protobuf`. Cargo-Projekt mit cross-rs für 3 Architekturen. — *Reversibility: costly.*
- **D-02:** `protobuf`-Subcommand für Protobuf↔JSON Konversion. Phase 75 (SpClient.pm) kann wahlweise Perl-Decoder ODER spoton-helper als Backend nutzen. Deckt collection/v2, recently-played und rootlist ab. — *Reversibility: reversible.*

**Patch-Strategie**
- **D-03:** Patching bei Installation — einmalig nach Soloist-Download. Gepatchte Binary wird gespeichert, kein On-Demand-Patching bei jedem Start. Soloist.pm triggert `spoton-helper patch` automatisch nach erfolgreichem Download + Extraktion. — *Reversibility: reversible.*
- **D-04:** Version-Lock — Patches nur für die gepinnte Soloist-Version (1.3.7.489). Bei anderer Version kein Patch-Versuch. Expliziter Support pro Version. — *Reversibility: one-way.*
- **D-05:** Lifetime-Patch immer automatisch, kein Settings-Toggle. ASCII-Timestamp in .rodata ersetzen, validiert im Spike (25696 Tage). — *Reversibility: reversible.*
- **D-06:** FLAC24-Enum-Patch best effort — 5 von 6 Gates patchen, Gate 4 bewusst auslassen (Crash). Server-seitige Quality-Zuweisung ist ungeklärt (A/B-Test zeigte identische CDN-Größen), wird aber nicht blockierend behandelt — Patch vorbereiten, Effekt in Phase 77 UAT verifizieren. — *Reversibility: reversible.*

**check-Modus**
- **D-07:** `spoton-helper check` validiert drei Aspekte: (1) Patch-Status (Lifetime + FLAC24 Gates angewendet?), (2) Binary-Integrität (SHA256 gegen gespeicherten Hash), (3) Architektur + Version der Soloist-Binary. — *Reversibility: reversible.*
- **D-08:** Eigenes JSON-Format (nicht librespot-kompatibel): `{version, arch, soloist_version, patches: {lifetime: bool, flac24_gates: [bool]}, sha256, patched: bool}`. Soloist.pm konsumiert dieses Format für Settings-Anzeige. — *Reversibility: reversible.*

**Build & Distribution**
- **D-09:** Binary im Plugin-Zip unter `Plugins/SpotOn/Bin/<arch>/spoton-helper`. Gleicher Ort wie librespot. Kein separater Download. — *Reversibility: reversible.*

### Claude's Discretion
- Multi-Arch Pattern-Scanner-Ansatz (Pro-Arch Pattern-Tabelle vs. ELF-Parser + Disassembly) — Researcher analysiert die konkreten Byte-Patterns der 3 Architekturen und empfiehlt.
- CI-Workflow-Integration (eigener Workflow vs. Job in build-librespot.yml) — Researcher analysiert bestehende Pipeline und wählt pragmatischsten Weg.
- Cargo-Projektstruktur (Workspace vs. einzelnes Crate, Dependency-Auswahl für Protobuf-Handling).

### Deferred Ideas (OUT OF SCOPE)
- **login5 Token-Minting** — In Perl machbar (Spike 009: librespot CID, kein HashCash). Gehört zu Phase 75 (SpClient.pm), nicht Phase 74.
- **Cached-Datei Decryption** — KDF + Cipher gelöst (Spike 008), GDB-Tool existiert. Könnte als `decrypt`-Subcommand landen, aber kein klarer Use Case ohne login5 Token-Minting im Helper. Geparkt.
- **Per-Player Backend-Auswahl** — Phase 76 (UX Polish).
- **Quality-Dropdown (OGG/FLAC/Lossless)** — Phase 76.
- **Pairing-Flow-Ausbau** — Phase 76 (Basis aus 73-04 existiert).
</user_constraints>

## Summary

Phase 74 builds `spoton-helper`, a single-purpose standalone Rust binary with three subcommands (`patch`, `check`, `protobuf`) shipped inside the plugin zip under `Bin/<arch>/` for three Linux targets. Unlike `librespot-spoton`, this helper does **no networking, no async, no TLS** — it reads/writes local files and transcodes protobuf on stdin/stdout. That makes its cross-compile the simplest binary in the project: pure static musl, no C toolchain, no `protoc`, no `ring`/`aws-lc-rs`.

The two hard research questions both resolve toward the *simpler, version-locked* option. Because D-04 pins the patch surface to exactly Soloist 1.3.7.489, the byte offsets and instruction encodings are **fixed constants** — there is no need for an ELF disassembler to *find* instructions at runtime. A **per-arch static pattern table** (search-with-context + exact-occurrence-count assertion + SHA256 gate) is safer and lighter than parsing/disassembling, and it fails closed the moment the binary deviates. For CI, the helper must be a **job inside `build-librespot.yml`**, not a separate workflow — this is the exact constraint that already forced `fake-libpulse` into that workflow (CR-02): `actions/download-artifact@v4` in the `release` job only sees artifacts from its own run, and D-09 requires the helper to land in the same plugin zip.

**Primary recommendation:** Single standalone crate `spoton-helper/` (parallel to `librespot-spoton/`), deps `clap` + `serde_json` + `sha2` + `protobuf 3.7`/`protobuf-codegen 3.7` (`.pure()` codegen, no `protoc`); per-arch pattern-table patcher with staging+verify+atomic-rename; `build-spoton-helper` matrix job added to `build-librespot.yml` + folded into the `release` zip step; auto-patch hooked into `Soloist.pm::_onSoloistDownloadDone` after the post-download `_versionCheck` succeeds, guarded by a `check`-first idempotency probe.

> **Compliance / provenance note (read before planning the patch tasks):** The *concrete validated byte-patterns* for the Lifetime and FLAC24 gates are the reverse-engineering output validated in the Soloist spike. They are **not reproduced in this public planning document** and must not be committed into the public source repo as plaintext research — see **Open Question 1** for the recommended compliance-boundary handling (mirrors the project's existing private-crate-swap precedent). This document specifies the *engine, scaffolding, and safety envelope*; the pattern constants are injected at implementation/build time from the private validated source.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Binary byte-patching (Lifetime, FLAC24) | spoton-helper (Rust) | — | Byte-precise mutation + SHA256 + fail-closed count assertions belong in a compiled tool, not shell/Perl |
| Patch/integrity validation (`check`) | spoton-helper (Rust) | Soloist.pm (consumes JSON) | Arch/version/hash detection is a binary concern; Perl only reads the JSON verdict |
| Protobuf↔JSON conversion | spoton-helper (Rust) | Phase 75 SpClient.pm (optional caller) | Real protobuf schema handling; Perl caller is optional per D-02 |
| When to patch (once, post-download) | Soloist.pm (Perl) | spoton-helper (executes) | Lifecycle/orchestration is Perl's job; the helper is a stateless tool it invokes |
| Locating the helper binary | Soloist.pm (Perl) | — | Plugin `Bin/<arch>/` path construction, same pattern as `fake-libpulse` `libPath()` |
| CI build + zip assembly | GitHub Actions | — | Multi-arch cross build + artifact folding into plugin zip |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `clap` (derive) | 4.x | CLI: 3 subcommands, typed args | The de-facto Rust CLI framework; derive API gives typed subcommands + `--help` for free `[CITED: docs.rs/clap]` |
| `serde_json` | 1.x | `check` JSON output (D-08) + protobuf→JSON | Standard JSON in Rust; already used by `librespot-spoton` `[VERIFIED: crates.io, verdict OK]` |
| `sha2` | 0.10.x | SHA256 binary integrity (D-07) | RustCrypto standard; no C deps `[VERIFIED: crates.io, verdict OK]` |
| `protobuf` (rust-protobuf) | 3.7 | collection/v2, recently-played, rootlist decode/encode | Proven in-house with `.pure()` codegen — no `protoc` binary needed, ideal for cross-rs `[VERIFIED: crates.io, exists, 2.18M downloads/wk]` |
| `protobuf-codegen` | 3.7 | build.rs `.pure()` codegen | Generates Rust from `.proto` with zero external toolchain `[VERIFIED: crates.io, exists, 634K downloads/wk]` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `anyhow` | 1.x | Ergonomic error propagation in `main`/subcommands | Application-level errors, `?` everywhere `[VERIFIED: crates.io, verdict OK]` |
| `thiserror` | 2.x | Typed patch/validation errors | If you want distinct error variants for count-mismatch vs version-mismatch vs io `[VERIFIED: crates.io, verdict OK]` |

**No networking / async / TLS deps.** `spoton-helper` never opens a socket. Do **not** pull in `tokio`, `reqwest`, `rustls`, `hyper`, `ring`, or `aws-lc-rs` — they exist in `librespot-spoton` for streaming, and have zero role here. Their absence is what makes the helper's cross build trivial.

### Protobuf crate choice — `protobuf 3.7`, NOT `prost`
Both `prost` (+`protox` for pure-Rust compile) and `protobuf`/`protobuf-codegen` (rust-protobuf) can compile `.proto` without a system `protoc`. **Recommend `protobuf 3.7`** because:
- The `.pure()` codegen path (`protobuf_codegen::Codegen::new().pure()`) is already **proven in-house** against real Spotify protobuf (byte-identical round-trip), so the cross-compile risk is retired.
- It matches the ecosystem the project already reverse-engineered `collection2v2.proto`-adjacent schemas in — consistency of tooling for Phase 75.
- No `build.rs` dependency on a `protoc` binary being present in the cross-rs Docker image (the alternative — `prost-build` v0.11+ — *requires* `protoc` unless you add `protox`, i.e. one more moving part).

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `protobuf 3.7` (rust-protobuf) | `prost` + `protox` | `prost` generates more idiomatic types, but needs `protox` glue to avoid `protoc`; no in-house proof; extra risk for no benefit at this scale |
| Per-arch pattern table | `object`/`goblin` ELF parse + `capstone`/`iced-x86`/`yaxpeax` disassembly | Disassembler is only worth it for *version-portable* patching, which D-04 explicitly rejects (one-way). Heavy deps, larger binary, more cross-compile surface |
| Single crate | Cargo workspace | Workspace only pays off with multiple internal crates; three subcommands are one binary. Keep it a single crate |
| `sha2` crate | shell out to `sha256sum` | Not portable (Windows path, though helper is Linux-only), and the helper should be self-contained |

**Installation (Cargo.toml sketch):**
```toml
[package]
name = "spoton-helper"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "spoton-helper"
path = "src/main.rs"

[dependencies]
clap        = { version = "4", features = ["derive"] }
serde_json  = "1"
sha2        = "0.10"
protobuf    = "3.7"
anyhow      = "1"
thiserror   = "2"

[build-dependencies]
protobuf-codegen = "3.7"

# Defensive: a wrapping bug in offset math must abort, never corrupt a binary.
[profile.release]
overflow-checks = true
```

**Version verification performed this session:**
- `clap`, `serde_json`, `sha2`, `anyhow`, `thiserror` → `package-legitimacy check --ecosystem crates` returned **OK**.
- `protobuf`, `protobuf-codegen` → returned **SUS (reason: no-repository)** but both exist on crates.io with 2.18M / 634K weekly downloads and ~10-year history — the flag is a crates.io metadata omission (no `repository` field), not an authenticity signal. See Package Legitimacy Audit.

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| clap | crates | ~11 yrs | 17.2M/wk | github.com/clap-rs/clap `[ASSUMED]` | OK | Approved |
| serde_json | crates | ~10 yrs | (very high) | github.com/serde-rs/json `[ASSUMED]` | OK | Approved |
| sha2 | crates | mature | high | github.com/RustCrypto/hashes `[ASSUMED]` | OK | Approved |
| anyhow | crates | mature | high | github.com/dtolnay/anyhow `[ASSUMED]` | OK | Approved |
| thiserror | crates | mature | high | github.com/dtolnay/thiserror `[ASSUMED]` | OK | Approved |
| protobuf | crates | ~11 yrs (since 2014) | 2.18M/wk | github.com/stepancheg/rust-protobuf `[ASSUMED]` | SUS (no-repository) | **Keep** — download volume + age refute the flag; verify repo link before pinning |
| protobuf-codegen | crates | since 2018 | 634K/wk | github.com/stepancheg/rust-protobuf `[ASSUMED]` | SUS (no-repository) | **Keep** — same project as `protobuf`; build-dep only |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** `protobuf`, `protobuf-codegen` — flagged solely for a missing `repository` field in crates.io metadata. Mitigating evidence: millions of weekly downloads, decade of history, and prior in-house production use with byte-verified output. The planner should include a `checkpoint:human-verify` confirming the canonical repo (`github.com/stepancheg/rust-protobuf`) before the first `cargo build`, but these are not hallucination/slopsquat candidates.

## Architecture Patterns

### System Architecture Diagram

```
                          ┌─────────────────────────────────────────────┐
   LMS install / Settings │  Soloist.pm  (Perl, lifecycle orchestration) │
   save with backend=sol  │                                              │
        │                 │  ensureBinary() → download → extract         │
        ▼                 │      → _versionCheck() == 1.3.7.489 ✓        │
  soloist_release_*.tar.gz│              │                               │
        │                 │              ▼  (D-03: patch once)           │
        └────────────────▶│   1. spoton-helper check  ──► already patched?│──yes──▶ skip
                          │              │ no                            │
                          │              ▼                               │
                          │   2. spoton-helper patch --version 1.3.7.489 │
                          │        --binary <soloist>                    │
                          └──────────────┬───────────────────────────────┘
                                         │  invokes (array-form exec)
                                         ▼
        ┌────────────────────────────────────────────────────────────────┐
        │  spoton-helper  (Rust, static musl, no network)                 │
        │                                                                 │
        │  ┌──────────┐   ┌──────────┐   ┌───────────────────────────┐   │
        │  │  patch   │   │  check   │   │  protobuf (stdin→stdout)   │   │
        │  └────┬─────┘   └────┬─────┘   └────────────┬──────────────┘   │
        │       │              │                      │                  │
        │  read soloist   read ELF e_machine     read proto bytes        │
        │  bytes          + scan patch markers   (collection/v2, ...)    │
        │       │              │                      │                  │
        │  per-arch PATTERN    emit D-08 JSON     protobuf 3.7 decode    │
        │  TABLE: search+ctx   {version,arch,          │                 │
        │  → assert count      soloist_version,    serde_json encode     │
        │  → replace 5/6 gates patches{...},           │                 │
        │  + lifetime ASCII    sha256, patched}    JSON on stdout        │
        │       │                                                        │
        │  write staging → self-check → atomic rename over original      │
        └────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
                         patched Soloist binary at Bin cache path
                    (Phase 75 SpClient.pm may pipe protobuf ⇄ JSON here)
```

*File-to-implementation mapping lives in Component Responsibilities below, not in the diagram.*

### Recommended Project Structure
```
spoton-helper/                 # NEW top-level dir, parallel to librespot-spoton/
├── Cargo.toml                 # single crate, deps above
├── Cross.toml                 # 3 musl targets (mirror librespot-spoton/Cross.toml, minus win/extra)
├── rust-toolchain.toml        # pin channel + 3 musl targets (reproducibility)
├── build.rs                   # protobuf_codegen .pure() codegen from proto/
├── proto/
│   ├── collection2v2.proto    # vendored from librespot upstream
│   ├── recently_played.proto  # (identify schema — see Open Question 2)
│   └── rootlist.proto         # (identify schema — see Open Question 2)
└── src/
    ├── main.rs                # clap parser, subcommand dispatch
    ├── patch/
    │   ├── mod.rs             # patch engine: scan → assert count → stage → verify → rename
    │   ├── patterns.rs        # PER-ARCH pattern table (SEE Open Question 1 re: provenance)
    │   └── arch.rs            # ELF e_machine read (no full parser)
    ├── check.rs               # D-08 JSON emitter
    └── protobuf_cmd.rs        # stdin/stdout protobuf ⇄ JSON
```

### Pattern 1: Version-Locked Per-Arch Pattern Table (RECOMMENDED for D-04)
**What:** Each architecture has a static table of patch sites. A site = `{ name, search: &[u8] (instruction + unique surrounding context), replace: &[u8], expect_count: usize }`. The engine scans the whole file, asserts each `search` occurs **exactly** `expect_count` times (fail-closed on 0 or >expected), then replaces.
**When to use:** When the target is a single pinned build (D-04) — offsets and encodings are constants, so no disassembler is needed to *locate* anything.
**Why this beats ELF+disassembly here:**
- The Lifetime patch is an **ASCII timestamp string in `.rodata`** — a plain unique-substring search over the file bytes finds it; no section walking required (D-05, spike-validated "25696 days").
- The FLAC24 gates are `cmp`/`mov` **immediate** instructions whose encoding differs per arch (x86_64 `cmp imm8`; arm64 `cmp wN, #imm`; arm32 `cmp rN, #imm`) — but for a fixed build each is a fixed byte sequence. A per-arch table captures exactly this without decoding.
- Fail-closed safety comes free: if Spotify ships a different build, the exact byte context won't match `expect_count`, and `patch` aborts (which is what D-04 wants).

**Safety envelope (MANDATORY — every patch task must implement all four):**
1. **Version gate:** refuse to patch unless the Soloist `--version` (or an embedded version marker) equals `1.3.7.489`. Exit non-zero with JSON error otherwise.
2. **Exact-occurrence assertion:** each pattern must match its expected count *before any write*. A count mismatch aborts the whole patch (no partial writes).
3. **Staging + self-verify + atomic rename:** write the patched bytes to a temp file in the same dir, run the internal `check` logic against the staged file, and only `rename()` over the original if it validates. Mirror `Soloist.pm::storeKey`'s staging discipline.
4. **Gate 4 exclusion (D-06):** the FLAC24 table contains 6 gates; the engine patches 5 and deliberately skips the crash gate. Encode this as data (a `skip: true` flag on the gate), not a magic index, so it is auditable.

### Pattern 2: ELF e_machine Read Without a Full Parser (for `check` arch detection)
**What:** To report `arch` in the D-08 JSON, read two bytes at file offset `0x12` (ELF header `e_machine`, little-endian): `0x3E` = x86-64, `0xB7` = AArch64, `0x28` = ARM. Also validate the 4-byte magic `\x7fELF` at offset 0.
**When to use:** `check` needs arch without pulling in `object`/`goblin`.
**Why:** A 20-line read beats a full ELF-parsing dependency for a single field. `[CITED: ELF spec — e_machine at header offset 0x12]`

### Pattern 3: Protobuf stdin→stdout Pipe (D-02)
**What:** `spoton-helper protobuf --schema <collection-v2|recently-played|rootlist> --mode <decode|encode>`. `decode`: read raw protobuf bytes from stdin, emit JSON on stdout. `encode` (for `PageRequest`/`WriteRequest`): read JSON from stdin, emit protobuf bytes on stdout.
**When to use:** Phase 75 `SpClient.pm` may pipe bytes here instead of parsing protobuf in Perl (D-02 makes this optional, not required).
**Why:** A clean process boundary — Perl stays protobuf-agnostic; the helper owns the schema. Matches spike 009 S-06/S-09/S-10 (collection/v2 + recently-played + rootlist are protobuf-only).

### Anti-Patterns to Avoid
- **Patching in place without staging:** a crash mid-write corrupts the only copy of a binary that costs a multi-MB re-download (Soloist won't re-download once a file exists — D-04 structural guard in `downloadBinary`). Always stage+verify+rename.
- **Heuristic/fuzzy offset scanning:** explicitly rejected by the discussion (Version-Lock chosen over Heuristic Scan). Broad matching risks patching the wrong bytes. Use exact context + count assertion.
- **Shell-string invocation from Perl:** `Soloist.pm` already uses array-form `open('-|', ...)` and `system('tar', ...)`. The patch call must be array-form too — never an interpolated shell string (project Anti-Pattern; the raw spak-key discipline).
- **Pulling network crates into the helper:** no `tokio`/`reqwest`/`rustls`. The helper is offline.
- **Separate CI workflow for the release build:** `download-artifact@v4` can't cross workflow runs — see CI section.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Protobuf decode for collection/v2 | Custom varint reader in Rust | `protobuf 3.7` + `.pure()` codegen | Real schema (nested/repeated/tombstones); regex-URI hacks miss `added_at`/`is_removed` (spike S-08) |
| CLI arg parsing | Manual `std::env::args` matching | `clap` derive | Typed subcommands, `--help`, arg validation for free |
| SHA256 | Byte-loop implementation | `sha2` | Correctness + speed, RustCrypto standard |
| ELF full parse for one field | `object`/`goblin` dep | 2-byte `e_machine` read | Only need arch, not the section table |
| `protoc` toolchain in CI | Install `protoc` in cross Docker image | `protobuf-codegen` `.pure()` | Pure-Rust codegen — nothing to install, cross-compiles cleanly |

**Key insight:** The helper's whole reason to exist is *byte-precise, fail-closed* mutation of a third-party binary and *schema-correct* protobuf handling. Both are exactly the places where hand-rolled shortcuts (fuzzy scans, regex protobuf) silently produce a corrupt binary or wrong metadata — the two most expensive failure modes here.

## Common Pitfalls

### Pitfall 1: `protoc` assumed present in the cross build
**What goes wrong:** `prost-build` (or `protobuf-codegen` without `.pure()`) shells out to a `protoc` binary that isn't in the cross-rs Docker image → build fails only on CI, not locally.
**Why it happens:** Default protobuf codegen paths expect a system `protoc`.
**How to avoid:** Use `protobuf_codegen::Codegen::new().pure()` (pure-Rust compiler). Verified in-house to need no `protoc` on PATH. `[VERIFIED: docs.rs/protobuf-codegen .pure() API]`
**Warning signs:** `protoc: command not found` or `failed to invoke protoc` in the cross-build job only.

### Pitfall 2: Separate CI workflow → helper never reaches the plugin zip
**What goes wrong:** A standalone `build-spoton-helper.yml` builds the binary, but the `release` job in `build-librespot.yml` assembles the zip and can't see another workflow's artifacts.
**Why it happens:** `actions/download-artifact@v4` only sees artifacts from its **own** workflow run — the exact reason `fake-libpulse` was folded into `build-librespot.yml` (CR-02 comment, lines 239-246).
**How to avoid:** Add a `build-spoton-helper` job **inside** `build-librespot.yml`, add it to the `release` job's `needs:`, and fold its artifacts into the zip step. Keep an optional `build-spoton-helper.yml` for `workflow_dispatch` debug builds only (mirror `build-fake-libpulse.yml`).
**Warning signs:** Release zip missing `Bin/<arch>/spoton-helper`; Soloist.pm can't find the helper at runtime.

### Pitfall 3: `detect-changes` skips the helper build
**What goes wrong:** `build-librespot.yml`'s `detect-changes` job only diffs `librespot-spoton/`. If only `spoton-helper/` changed since the last tag, `rust_changed=false`, the `build` job is skipped, `reuse-binaries` runs — and the helper is never rebuilt (stale or missing).
**Why it happens:** The change-detection path is hard-coded to `librespot-spoton/`.
**How to avoid:** Either (a) always build the helper on tag (it compiles in seconds — cheapest, recommended), or (b) add `spoton-helper/` to the `detect-changes` diff and a `reuse-binaries` fallback that re-downloads `spoton-helper-*` from the previous release. Recommend (a).
**Warning signs:** A release whose helper is an older version than the source.

### Pitfall 4: Bindir vocabulary mismatch (arch naming)
**What goes wrong:** Three different vocabularies for the same arch: Rust triple (`aarch64-unknown-linux-musl`), Spotify download (`arm64`), SpotOn bindir (`aarch64-linux`). Cross-wiring them puts a binary in the wrong `Bin/<arch>/`.
**Why it happens:** `Soloist.pm`'s `@ARCH_MAP` maps osArch→`{download, bindir}`; the CI matrix maps triple→`bin_dir`. They must agree.
**How to avoid:** Reuse the exact `bin_dir` names the existing `build` matrix uses: `x86_64-linux`, `aarch64-linux`, `armhf-linux` (verified in `build-librespot.yml` lines 59-67 and `Soloist.pm` `@ARCH_MAP` lines 61-65). The helper's target triples: `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`, `armv7-unknown-linux-musleabihf`.
**Warning signs:** Helper present for x86_64 but "not found" on a Pi.

### Pitfall 5: Patching a non-1.3.7.489 build (D-04 violation)
**What goes wrong:** Spotify's download endpoint is **unversioned** (`Soloist.pm` comment lines 24-26, 44) — a future silent bump ships a different binary, and a naive patcher writes wrong bytes.
**Why it happens:** No version in the URL; the only signal is the binary's own `--version` / embedded marker.
**How to avoid:** `patch` must gate on version *before* scanning, and the exact-count assertion is a second line of defense (different build → context won't match → abort). `Soloist.pm::_versionCheck` already refuses to activate a non-matching version; the patch runs only after that gate.
**Warning signs:** `check` reports `patched:false` after a patch run, or Soloist crashes on launch.

### Pitfall 6: FLAC24 effect assumed, not proven (D-06)
**What goes wrong:** Planning tasks treat FLAC24 as a delivered feature; UAT then finds identical CDN sizes (A/B test already showed ~4.5 MB OGG both ways — ROADMAP line 470).
**Why it happens:** The enum patch is client-side; server-side quality assignment is unverified, and Soloist must also announce `supported_audio_quality=HIFI_24` in DeviceCapabilities.
**How to avoid:** Scope FLAC24 as "patch prepared + `check` reports gate status," with the *audible effect* explicitly deferred to Phase 77 UAT (D-06). Do not gate phase completion on hearing 24-bit audio.
**Warning signs:** A plan task with an acceptance criterion like "24-bit audio plays" — that belongs in Phase 77.

## Runtime State Inventory

> This phase adds a new binary and a patch step; it renames nothing. The relevant "runtime state" is the on-disk Soloist binary and its patch/integrity records.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Patched Soloist binary at `cachedir/spoton/soloist/<bindir>/soloist` (per `Soloist.pm::_cacheDir`); optional stored SHA256 baseline for `check` integrity comparison | New: write/patch the binary in place (staged); decide where the "expected sha256" baseline lives (cache entry vs sidecar file) |
| Live service config | None — the helper is invoked synchronously, holds no daemon/service state | None — verified: no port, no persistent process |
| OS-registered state | None — no systemd/task-scheduler/pm2 registration for the helper | None — verified: helper is a one-shot CLI |
| Secrets/env vars | None — helper touches no spak-key, no credentials (contrast Soloist.pm `readKey`) | None — keep it credential-free by design |
| Build artifacts | New `spoton-helper/target/` (git-ignore it); shipped `Bin/<arch>/spoton-helper` in the plugin zip | Add `spoton-helper/target/` to `.gitignore`; CI produces the shipped binary |

**Nothing found in categories "Live service config", "OS-registered state", "Secrets/env vars":** confirmed — `spoton-helper` is a stateless, offline, credential-free one-shot invoked by `Soloist.pm`.

## Code Examples

### build.rs — pure-Rust protobuf codegen (no protoc)
```rust
// Pattern proven in-house (byte-identical round-trip vs real Spotify protobuf).
// .pure() needs NO protoc binary on PATH — critical for cross-rs Docker builds.
fn main() {
    protobuf_codegen::Codegen::new()
        .pure()
        .includes(["proto"])
        .input("proto/collection2v2.proto")
        // add recently_played.proto / rootlist.proto once schemas are pinned
        .cargo_out_dir("protos")
        .run_from_script();
}
```

### clap subcommand skeleton
```rust
// Source: docs.rs/clap _derive tutorial
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "spoton-helper")]
struct Cli { #[command(subcommand)] cmd: Cmd }

#[derive(Subcommand)]
enum Cmd {
    Patch { #[arg(long)] version: String, #[arg(long)] binary: std::path::PathBuf },
    Check { #[arg(long)] binary: std::path::PathBuf, #[arg(long)] expect_sha: Option<String> },
    Protobuf { #[arg(long)] schema: String, #[arg(long, default_value = "decode")] mode: String },
}
```

### Perl integration — where the patch call goes (Soloist.pm)
```perl
# In _onSoloistDownloadDone(), AFTER the existing post-download activation:
#   if (_versionCheck($canonical)) { $binary = $canonical; ... }
# add (D-03, patch-once, idempotent):

if ($binary) {                      # only patch an activated, version-matched binary
    _autoPatch($canonical);         # array-form exec; never a shell string
}

# sketch — real impl belongs in a plan task:
sub _autoPatch {
    my ($soloistPath) = @_;
    my $helper = _helperPath() or return;   # basedir/Bin/<bindir>/spoton-helper (like fake-libpulse libPath)

    # 1. Idempotency probe (D-03): skip if already patched.
    my $status = _runHelperJson($helper, 'check', '--binary', $soloistPath);
    return if $status && $status->{patched};

    # 2. Patch (version-gated inside the helper too).
    my $result = _runHelperJson($helper, 'patch',
        '--version', SOLOIST_VERSION, '--binary', $soloistPath);

    if (!$result || !$result->{patched}) {
        # Non-fatal: Soloist still runs unpatched (fail-open for core playback).
        $log->warn("Soloist: auto-patch did not complete -- running unpatched");
    }
}
# _runHelperJson: open('-|', $helper, @args) + from_json, mirroring _versionCheck's
# array-form open and Helper.pm's --check JSON parsing.
```
*Note:* `_helperPath()` is new — it constructs `basedir/Bin/<bindir>/spoton-helper` exactly like `Soloist.pm::libPath()` builds the `fake-libpulse` dir (lines 117-128), reusing the `@ARCH_MAP` `bindir` value.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `prost-build` bundles/builds `protoc` | `protoc` required unless `skip_protoc`/`protox` | prost-build v0.11 | Reinforces choosing `protobuf 3.7` `.pure()` for painless cross builds `[CITED: prost-build changelog]` |
| Separate `build-fake-libpulse.yml` on tag | Folded into `build-librespot.yml` (CR-02) | Phase 71/73 | Establishes the precedent the helper must follow to reach the plugin zip |

**Deprecated/outdated:**
- Bundled-`protoc` codegen paths: avoid; use pure-Rust codegen.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Canonical repo for `protobuf`/`protobuf-codegen` is `github.com/stepancheg/rust-protobuf` | Package Legitimacy | Low — download volume confirms legitimacy regardless; verify link at pin time |
| A2 | FLAC24 gate byte-encodings differ by arch (x86_64 `cmp imm8`, arm64 `cmp wN,#imm`, arm32 `cmp rN,#imm`) and 5/6 are safely patchable, gate 4 crashes | Architecture Patterns / Pitfall 6 | Medium — sourced from spike RE (private, validated); wrong encoding → count-assert aborts (fail-closed), no corruption |
| A3 | Lifetime patch is a single unique ASCII timestamp string in `.rodata` findable by substring search | Pattern 1 | Low — spike-validated ("25696 days"); if not unique, count-assert catches it |
| A4 | `recently-played` and `rootlist` protobuf schemas can be sourced/derived for the `protobuf` subcommand | Open Questions | Medium — collection2v2.proto exists upstream; the other two need identification (spike S-09/S-10 left schema "TODO") |
| A5 | ELF `e_machine` values 0x3E/0xB7/0x28 identify the three targets | Pattern 2 | Low — stable ELF spec constants |
| A6 | Helper needs no network/credentials/daemon state | Runtime State Inventory | Low — follows directly from the three subcommands' scope |

**Concrete per-arch byte patterns are intentionally NOT in this document** (see Open Question 1) — they are validated RE output held privately, not `[ASSUMED]` guesses. A2/A3 record the *shape* of that knowledge, not the bytes.

## Open Questions

1. **Where do the validated byte-patterns live, and does the public repo ship them as source?**
   - What we know: D-09 ships the compiled helper (patterns baked in) in the public plugin zip, so the patterns are *distributed* in binary form regardless. The project already has a **compliance-boundary precedent**: a private-crate-swap where the sensitive algorithm lives in a private crate and the public checkout links a stub that reports "unsupported" (absence-as-control). Project memory also mandates that private RE (`~/spoton-private`) is never referenced from the public repo.
   - What's unclear: whether the pattern *constants* should (a) live in the public `spoton-helper/src/patch/patterns.rs` as plaintext, or (b) be injected at build from a private source (module/crate/submodule/CI secret), leaving a public no-op stub whose absence makes `patch` a safe no-op.
   - Recommendation: **Option (b)** — mirror the existing compliance-boundary pattern. Public repo contains the *engine + stub patterns* (empty table → `patch` reports `unsupported`, exits cleanly). The release build (which has private access — e.g. self-hosted runner or private submodule with deploy key) injects the real table. This keeps the public source clean and consistent with established project practice. **This is a policy decision for the user — surface it in `/gsd-discuss-phase` or as a plan checkpoint; do not let the planner assume plaintext-in-public.** The CI implication (release build must run where private patterns are reachable) is the main cost and must be designed if (b) is chosen.

2. **Exact protobuf schemas for `recently-played` and `rootlist`.**
   - What we know: `collection2v2.proto` exists in librespot upstream (verified reference in CONTEXT + spike 009). `recently-played` and `rootlist` are protobuf-only (spike S-09/S-10) with the schema marked "TODO: identify."
   - What's unclear: the precise `.proto` for those two endpoints.
   - Recommendation: scope the `protobuf` subcommand to **collection/v2 first** (schema in hand, highest Phase 75 value), and treat recently-played/rootlist as a follow-up within the subcommand once schemas are pinned (URI-regex extraction is the documented interim fallback, spike S-09). Don't block the phase on all three.

3. **Where does the `check` integrity baseline SHA256 come from?**
   - What we know: D-07 wants SHA256 "against a stored hash." The patched binary's hash is deterministic only if the patch is deterministic (it is — fixed patterns).
   - What's unclear: is the baseline (i) the expected post-patch hash computed/stored at patch time, or (ii) a hard-coded known-good hash per arch?
   - Recommendation: store the post-patch SHA256 at patch time (e.g. a `spoton` cache entry or sidecar), and have `check --expect-sha` compare against it. A hard-coded per-arch hash also works but couples `check` to the exact patch set (brittle if Gate policy changes). Prefer the stored-at-patch-time baseline.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `cargo` / Rust toolchain | Building `spoton-helper` locally | ✓ | `~/.cargo/bin/cargo` present | — |
| `cross` (cross-rs) | CI multi-arch build | ✓ (CI installs it) | via `cargo install cross` (existing `build` job) | Native musl build for host arch only |
| `protoc` binary | protobuf codegen | ✗ (not needed) | — | `.pure()` codegen — no protoc required |
| C cross-toolchain | (not needed) | ✗ (not needed) | — | Helper is pure Rust static musl; no C deps |
| `qemu-aarch64` | Optional local arm test | unknown | — | Test on real Pi / defer to Phase 77 platform UAT |

**Missing dependencies with no fallback:** none — the helper's toolchain is a strict subset of what `librespot-spoton` already builds with.
**Missing dependencies with fallback:** `protoc` (avoided via `.pure()`), C cross-toolchain (not used).

## Validation Architecture

> `workflow.nyquist_validation` is `true` in `.planning/config.json` — this section applies.

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Rust) | `cargo test` (built-in) — unit tests in `spoton-helper/src/**` |
| Framework (Perl) | LMS `prove -l t/` (existing SpotOn test harness, e.g. `t/05_perl_syntax.t`) |
| Config file | `spoton-helper/Cargo.toml`; Perl: `t/` dir (existing) |
| Quick run command | `cargo test` (in `spoton-helper/`) |
| Full suite command | `cargo test --release` + `prove -l t/` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| D-04/D-05 | patch on correct version applies lifetime | unit | `cargo test patch::lifetime_applies_on_locked_version` | ❌ Wave 0 |
| D-04 | patch refuses wrong version (fail-closed) | unit | `cargo test patch::rejects_wrong_version` | ❌ Wave 0 |
| D-06 | 5/6 FLAC gates patched, gate 4 skipped | unit | `cargo test patch::flac24_skips_gate4` | ❌ Wave 0 |
| Safety | count-mismatch aborts with no write | unit | `cargo test patch::aborts_on_count_mismatch` | ❌ Wave 0 |
| D-07/D-08 | check emits correct JSON shape | unit | `cargo test check::json_schema` | ❌ Wave 0 |
| D-02 | protobuf decode collection/v2 round-trips | unit | `cargo test protobuf::collection_v2_roundtrip` | ❌ Wave 0 |
| D-03 | Soloist.pm invokes patch once (idempotent) | unit (Perl) | `prove -l t/` (new test for `_autoPatch` skip-when-patched) | ❌ Wave 0 |

*Tests must run against a **synthetic fixture** binary (a crafted file containing the expected patterns), NOT a distributed Soloist binary — keeps the test suite runnable in CI without shipping the proprietary binary or the real patterns.*

### Sampling Rate
- **Per task commit:** `cargo test` (spoton-helper) — seconds.
- **Per wave merge:** `cargo test --release` + `prove -l t/`.
- **Phase gate:** full suite green + a cross-build smoke (`cross build --release --target aarch64-unknown-linux-musl`) before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `spoton-helper/tests/` (or inline `#[cfg(test)]`) — patch/check/protobuf unit tests
- [ ] Synthetic fixture generator — a helper that emits a fake "binary" containing the search patterns (so tests don't need the real Soloist binary or the private patterns)
- [ ] Perl `t/` test for `Soloist.pm::_autoPatch` idempotency (mock helper returning `{patched:true}`)
- [ ] Toolchain: `spoton-helper` crate + `cargo test` wired (none exists yet)

## Security Domain

> `security_enforcement` not explicitly `false` in config → treated as enabled.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | yes | Helper is offline, credential-free, stateless — minimal attack surface by design |
| V5 Input Validation | yes | `protobuf` subcommand parses **untrusted bytes from stdin** — use `protobuf 3.7` decode (bounded), never `unsafe`/manual pointer math; reject oversized input |
| V6 Cryptography | yes (integrity only) | SHA256 via `sha2` for integrity — not a security boundary, just tamper/corruption detection |
| V12 File Handling | yes | `patch` mutates a binary: validate paths, write to same-dir staging, atomic rename, no symlink following on the target |
| V2/V3/V4 (auth/session/access) | no | Helper handles no auth, no sessions, no user data |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed protobuf on stdin (DoS/panic) | Denial of Service | Bounded decode via `protobuf` crate; cap stdin size; return JSON error, don't panic |
| Patching an unexpected/tampered binary | Tampering | Version gate + exact-count assertion + staged self-verify before rename (fail-closed) |
| Partial write corrupts binary | Tampering / DoS | Staging + atomic `rename()`; never in-place mutation |
| Path injection via crafted binary path arg | Tampering | Caller (Soloist.pm) constructs the path from `@ARCH_MAP`/cachedir, never user input; helper still validates the path is a regular file |
| Distributing circumvention patterns in source | (compliance, not STRIDE) | Compliance-boundary crate-swap (Open Question 1) — keep validated patterns out of public source |

## Sources

### Primary (HIGH confidence)
- `Plugins/SpotOn/Soloist.pm` (read this session) — `_onSoloistDownloadDone` integration point, `@ARCH_MAP` bindir vocab, `_versionCheck`, staging discipline (`storeKey`), `libPath` pattern
- `.github/workflows/build-librespot.yml` (read this session) — CR-02 same-workflow-artifact constraint, `build` matrix, `detect-changes`, `reuse-binaries`, `release` zip assembly
- `.github/workflows/build-fake-libpulse.yml` (read this session) — standalone-workflow-for-debug-only precedent
- `Plugins/SpotOn/Helper.pm` (read this session) — `--check` JSON parsing pattern for binary capability manifests
- `librespot-spoton/Cargo.toml` + `Cross.toml` (read this session) — existing musl target set, arch→bindir mapping, cross-rs usage
- `.planning/spikes/008-...RESULTS.md` + `HANDOVER.md` (read this session) — lifetime patch validity, FLAC24 5/6 gates
- `.planning/spikes/009-...RESULTS.md` (read this session) — collection2v2.proto schema, S-06/S-09/S-10 protobuf-only endpoints
- In-house Rust workspace protobuf setup (reviewed this session, private) — `protobuf 3.7` + `protobuf-codegen 3.7` `.pure()` codegen proven with byte-identical round-trip; `overflow-checks=true` release profile; compliance-boundary crate-swap precedent

### Secondary (MEDIUM confidence)
- crates.io via `package-legitimacy check` — clap/serde_json/sha2/anyhow/thiserror OK; protobuf/protobuf-codegen exist (2.18M/634K weekly downloads)
- docs.rs/protobuf-codegen `.pure()` API; docs.rs/clap derive tutorial
- prost-build v0.11 changelog (protoc requirement) — reinforces protobuf-codegen choice

### Tertiary (LOW confidence)
- Canonical repo URLs for the `[ASSUMED]`-tagged crates (training knowledge; verify at pin time)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all crates verified/legit, protobuf approach proven in-house
- Architecture (pattern-table vs disassembly, CI-in-workflow, single crate): HIGH — grounded in D-04 lock + read CI + read Soloist.pm
- Patch byte-patterns themselves: MEDIUM — validated in spike RE (held privately), not re-derived this session; fail-closed envelope contains the risk
- FLAC24 server-side effect: LOW by design (D-06) — deferred to Phase 77 UAT

**Research date:** 2026-08-28
**Valid until:** 2026-09-27 (30 days — stable, except crate minor versions; re-verify `protobuf`/`clap` versions at pin time)
</content>
</invoke>
