---
phase: 74-spoton-helper-binary
plan: 03
subsystem: infra
tags: [rust, protobuf, protobuf-codegen, cross-rs, cli, spoton-helper]

# Dependency graph
requires:
  - phase: 74-spoton-helper-binary (74-01)
    provides: spoton-helper crate skeleton (clap dispatch, protobuf_cmd stub)
provides:
  - "spoton-helper protobuf subcommand: stdin/stdout protobuf <-> JSON for collection/v2, recently-played, rootlist (D-02)"
  - "Vendored D-02 protobuf schemas + full rootlist transitive import closure under spoton-helper/proto/"
  - "Pure-Rust protobuf codegen wiring (build.rs, no protoc) proven cross-rs safe"
affects: [75-spclient-integration]

# Actuals (#2632)
actuals:
  tokens: 14000
  tasks: 2
  commits: 2

tech-stack:
  added: ["protobuf 3.7 (rust-protobuf)", "protobuf-codegen 3.7 (.pure() build-dep)"]
  patterns:
    - "mod protos { include!(concat!(env!(\"OUT_DIR\"), \"/protos/mod.rs\")); } to pull cargo_out_dir-generated code into a submodule"
    - "Hand-rolled struct->serde_json::Value mapping per message (no serde support in protobuf 3.7; avoids a second package-manager install requiring its own supply-chain checkpoint)"
    - "Pure dispatch fn process(schema, mode, input: &[u8]) -> Result<Output> kept I/O-free so it is directly unit-testable"
    - "Generic fn read_bounded<R: Read>(r: R) for stdin size-capping, dependency-injected via Cursor in tests instead of touching real stdin"

key-files:
  created:
    - spoton-helper/build.rs
    - spoton-helper/proto/collection2v2.proto
    - spoton-helper/proto/recently_played.proto
    - spoton-helper/proto/recently_played_backend.proto
    - spoton-helper/proto/rootlist_request.proto
    - spoton-helper/proto/playlist_folder_state.proto
    - spoton-helper/proto/playlist_permission.proto
    - spoton-helper/proto/playlist_playlist_state.proto
    - spoton-helper/proto/protobuf_delta.proto
    - spoton-helper/proto/playlist_user_state.proto
    - spoton-helper/proto/extension_kind.proto
    - spoton-helper/proto/metadata/extension.proto
    - spoton-helper/proto/metadata/image_group.proto
  modified:
    - spoton-helper/Cargo.toml
    - spoton-helper/Cargo.lock
    - spoton-helper/src/protobuf_cmd.rs

key-decisions:
  - "All 12 vendored .proto files are passed as build.rs .input()s, not just the 4 schema roots -- protobuf-codegen's .pure() path does not inline transitively-imported message types; it emits super::<module> references to sibling generated modules, so every file in the rootlist import closure needs its own generated .rs or the build fails to resolve those paths (verified empirically before committing)."
  - "No new crate dependency for JSON mapping (rejected protobuf-json-mapping, from the same rust-protobuf repo already approved in the Task 1 checkpoint) -- the protobuf 3.7 crate has zero serde support, and a fully-generic reflection-based mapper would have been a plausible fix, but adding any new package-manager dependency requires its own supply-chain checkpoint per deviation Rule 3's exclusion. Hand-wrote the (finite, fixed-schema) JSON conversion instead, staying exactly within the Cargo.toml diff the plan and Task 1 approval scoped."
  - "Opaque protobuf bytes fields (Extension.data) are hex-encoded rather than base64 -- avoids a base64 crate dependency for a field Phase 75 does not need to interpret; reuses the same hex-formatting idiom already used by check.rs's SHA256 output."

patterns-established:
  - "Pure-dispatch + I/O-boundary split for CLI subcommands: process(schema, mode, &[u8]) -> Result<Output> is fully unit-testable; run() is the thin stdin/stdout wrapper."

requirements-completed: [D-02]

coverage:
  - id: D1
    description: "protobuf --schema collection-v2 --mode decode reads a PageResponse from stdin and emits JSON (items/added_at/is_removed/context_uri, next_page_token, sync_token)"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::collection_v2_decode_roundtrip"
        status: pass
    human_judgment: false
  - id: D2
    description: "protobuf --schema collection-v2 --mode encode reads a JSON PageRequest from stdin and emits protobuf bytes that round-trip"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::collection_v2_encode_roundtrip"
        status: pass
    human_judgment: false
  - id: D3
    description: "protobuf --schema recently-played --mode decode reads a backend RecentlyPlayed message and emits JSON contexts (uri/lastPlayedTime)"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::recently_played_decode_roundtrip"
        status: pass
    human_judgment: false
  - id: D4
    description: "protobuf --schema rootlist --mode decode reads a Response and emits the full JSON Folder/Item/Playlist tree (row_id/uri included)"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::rootlist_decode_roundtrip"
        status: pass
    human_judgment: false
  - id: D5
    description: "encode on response-only schemas (recently-played, rootlist) returns a single-line JSON decode-only error, non-zero exit"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::recently_played_encode_is_decode_only"
        status: pass
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::rootlist_encode_is_decode_only"
        status: pass
    human_judgment: false
  - id: D6
    description: "malformed protobuf/JSON and oversized stdin never panic -- return Err, surfaced by main.rs as a JSON error + non-zero exit"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::malformed_protobuf_returns_error_not_panic"
        status: pass
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::malformed_json_returns_error_not_panic"
        status: pass
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::oversized_input_is_rejected"
        status: pass
      - kind: e2e
        ref: "manual CLI smoke: spoton-helper protobuf --schema collection-v2 --mode decode on truncated bytes -> {\"error\":...} exit 1"
        status: pass
    human_judgment: false
  - id: D7
    description: "unknown --schema value returns a JSON error listing all three supported schemas"
    requirement: D-02
    verification:
      - kind: unit
        ref: "spoton-helper/src/protobuf_cmd.rs#tests::unknown_schema_lists_supported_schemas"
        status: pass
    human_judgment: false
  - id: D8
    description: "cargo build regenerates protobuf types via pure-Rust codegen (no protoc) for all three schema roots and the full rootlist transitive closure"
    verification:
      - kind: integration
        ref: "cd spoton-helper && cargo build (exit 0, no protoc invocation)"
        status: pass
    human_judgment: false

duration: 25min
completed: 2026-08-28
status: complete
---

# Phase 74 Plan 03: protobuf Subcommand Summary

**`spoton-helper protobuf` now decodes/encodes all three D-02 schemas (collection/v2, recently-played, rootlist) via pure-Rust `protobuf 3.7` codegen with zero `protoc` dependency, giving Phase 75's SpClient.pm an optional native protobuf backend.**

## Performance

- **Duration:** ~25 min (Task 2 + Task 3; Task 1 supply-chain checkpoint was approved in a prior session)
- **Started:** 2026-08-28T16:15:00Z (approx.)
- **Completed:** 2026-08-28T16:42:09Z
- **Tasks:** 2 (Task 1 checkpoint already resolved on entry)
- **Files modified:** 16 (1 Cargo.toml + 1 Cargo.lock + 1 new build.rs + 12 new vendored .proto files + 1 protobuf_cmd.rs)

## Accomplishments

- Vendored all three D-02 protobuf schemas from librespot upstream `protocol/proto/` — `collection2v2.proto`, `recently_played.proto` + `recently_played_backend.proto`, and `rootlist_request.proto` plus its full 8-file transitive import closure — verified the closure is complete (no unresolved imports) by a clean `cargo build`.
- Wired `protobuf_codegen::Codegen::new().pure()` in `build.rs` for cross-rs-safe codegen (no `protoc` binary anywhere in the build).
- Implemented `protobuf_cmd::run(schema, mode)`: decode for all three schemas (collection-v2 `PageResponse`, recently-played backend `RecentlyPlayed`, rootlist `Response` with its full nested Folder/Item/Playlist/PlaylistMetadata/Capabilities tree), encode for collection-v2 `PageRequest` only.
- Hardened untrusted-stdin handling: 8 MiB read cap, no `unsafe`, no `.unwrap()` on stdin-derived data, all parse failures propagate as `Err` and surface via `main.rs`'s existing single-line-JSON-error + non-zero-exit path.
- 10 new tests (decode round-trip x3, encode round-trip, decode-only-error x2, malformed protobuf, malformed JSON, oversized stdin, unknown schema) — all pass, plus a manual CLI smoke test confirming the exit-code/JSON contract end-to-end.

## Task Commits

Each task was committed atomically:

1. **Task 2: Vendor all three schemas + pure-Rust codegen wiring** - `66493e6` (feat)
2. **Task 3: protobuf subcommand — collection/v2 + recently-played + rootlist decode/encode** - `2f6ec72` (feat)

_Task 1 (supply-chain checkpoint) had no commit — verification only, resolved before this execution resumed._

## Files Created/Modified

- `spoton-helper/Cargo.toml` - added `protobuf = "3.7"` dep + `protobuf-codegen = "3.7"` build-dep
- `spoton-helper/Cargo.lock` - dependency graph update (protobuf/protobuf-codegen/protobuf-parse/protobuf-support + transitive deps)
- `spoton-helper/build.rs` - `.pure()` codegen listing all 12 vendored `.proto` files as inputs
- `spoton-helper/proto/collection2v2.proto` - PageRequest/PageResponse/CollectionItem/WriteRequest schema
- `spoton-helper/proto/recently_played.proto` - client `Item` schema (vendored per D-02, not used in decode/encode)
- `spoton-helper/proto/recently_played_backend.proto` - backend `RecentlyPlayed`/`Context` schema (the decode target)
- `spoton-helper/proto/rootlist_request.proto` - `Playlist`/`Item`/`Folder`/`Response` schema
- `spoton-helper/proto/playlist_folder_state.proto`, `playlist_permission.proto`, `playlist_playlist_state.proto`, `protobuf_delta.proto`, `playlist_user_state.proto`, `extension_kind.proto`, `metadata/extension.proto`, `metadata/image_group.proto` - rootlist's full transitive import closure
- `spoton-helper/src/protobuf_cmd.rs` - full decode/encode implementation replacing the Wave 1 stub

## Decisions Made

- **build.rs lists all 12 vendored files as `.input()`s, not just the 4 schema roots.** The plan's literal sketch said imported files "do NOT need to be `input()`s," but empirical testing showed protobuf-codegen's `.pure()` path generates `super::<module>` references for every imported message type rather than inlining them — so each file in the rootlist closure needs its own generated `.rs` alongside `rootlist_request`'s or the build fails with unresolved module paths. Verified before committing: listing only the 4 roots produced a `mod.rs` missing 8 of the modules that `rootlist_request.rs`'s generated code actually references.
- **No new crate for JSON mapping.** The `protobuf` 3.7 crate has no serde support. `protobuf-json-mapping` (same repo, same version, would have been the natural companion crate and drastically simplified the ~15-message rootlist tree) was considered and rejected — adding it is a new package-manager install, and per the deviation-rules package-install exclusion, any new dependency needs its own supply-chain checkpoint rather than being silently added mid-task. Hand-wrote the JSON conversion against the already-approved `protobuf`/`protobuf-codegen` pair instead. This is more code (~300 lines of per-message mapping) but stays exactly within the Cargo.toml diff Task 1 verified.
- **Extension.data (opaque bytes) is hex-encoded, not base64.** Avoids a third dependency for a field Phase 75 has no current need to interpret; reuses the hex-formatting idiom already established in `check.rs`'s SHA256 output.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] build.rs must list the full transitive closure as inputs, not just the 4 schema roots**
- **Found during:** Task 2 (codegen wiring) — first `cargo build` with only the 4 roots produced a `mod.rs` with 4 modules, but `rootlist_request.rs`'s generated code referenced `super::playlist_playlist_state`, `super::playlist_permission`, `super::protobuf_delta`, `super::playlist_folder_state` (and transitively `super::extension`, `super::image_group`, `super::extension_kind`, `super::playlist_user_state`) which did not exist as sibling modules.
- **Issue:** The plan's build.rs sketch assumed imported files are resolved purely via the `includes` path and don't need to be separate `.input()`s. Verified this is incorrect for `.pure()` codegen's cross-file message references — each imported file needs its own generated module.
- **Fix:** Added all 8 closure files as additional `.input()`s in build.rs.
- **Files modified:** spoton-helper/build.rs
- **Verification:** `cargo build` succeeds; `mod.rs` lists all 12 modules; `rootlist_request.rs`'s `super::*` references all resolve.
- **Committed in:** 66493e6 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Necessary correction to make the plan's build.rs sketch actually compile; no scope creep — same 12 files were always going to be vendored per the plan's `<files>` list, this only changes which ones are passed to `.input()`.

## Issues Encountered

- rust-protobuf 3.7's `.pure()` codegen path emits `super::<sibling_module>::TypeName` references for every cross-file message type rather than inlining or re-exporting them — this is undocumented in the crate's top-level docs (which show only single-file examples) and had to be discovered empirically via a scratch `cargo run --example` probe before committing the real build.rs. Documented as a code comment in build.rs for future maintainers.
- `protobuf` 3.7 has zero serde/JSON support built in (confirmed via crate source inspection, no `serde` feature exists). The natural companion crate `protobuf-json-mapping` (same publisher/repo/version) was available and would have generalized the whole rootlist tree via reflection, but was rejected per the package-install supply-chain policy — see Decisions Made above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `spoton-helper protobuf --schema <collection-v2|recently-played|rootlist> --mode <decode|encode>` is fully implemented and tested — Phase 75's `SpClient.pm` can now optionally shell out to this instead of hand-rolling a Perl protobuf decoder (D-02 satisfied in full).
- All three subcommands (`patch`, `check`, `protobuf`) of `spoton-helper` are now implemented; Phase 74's Cargo-project scope (D-01) is complete pending CI/cross-build wiring (tracked separately per the phase's remaining plans/waves, if any).
- No blockers for Phase 75. The rootlist JSON shape is a direct field-for-field mirror of the vendored `.proto` schemas (see `protobuf_cmd.rs` per-message `*_to_json` functions) — Phase 75 should treat that mapping as the contract when consuming rootlist output.

---
*Phase: 74-spoton-helper-binary*
*Completed: 2026-08-28*
