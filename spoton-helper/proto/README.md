# Vendored Spotify .proto schemas — documentation only

**Status: DOCUMENTATION ONLY.** As of Phase 75 (D-02), no Rust code in
`spoton-helper` consumes these files. The `protobuf` subcommand, its
`build.rs` codegen step, and the `protobuf`/`protobuf-codegen` crates were
removed from this crate — see the Phase 75 plan
(`.planning/phases/75-api-unification-spclient-modell/75-03-PLAN.md`) and the
Phase 75 decision log (D-01/D-02 in `75-CONTEXT.md`).

The runtime protobuf decoder is now the pure-Perl generic wire parser
`Plugins::SpotOn::API::ProtobufLite` (D-01), with Rust-parity golden wire
vectors captured before this deletion and preserved in
`t/34_protobuf_lite.t`. That module decodes fields generically by wire type
(varint, length-delimited, fixed32/fixed64) without needing generated
message structs, so it does not require these `.proto` files to run — they
remain here purely as human-readable schema documentation for field-number
lookups when adding support for new endpoints.

## What these files are for

When a Perl caller needs to know which field number in a spclient response
maps to which semantic field (e.g. "which field is the paging cursor in a
collection/v2 response?"), these vendored schemas are the reference. Notably:

- `collection2v2.proto` — schema for the collection/v2 paging response used
  by liked-songs/liked-albums sync; field numbers here map directly to the
  keys `ProtobufLite::parse_fields` returns.
- The remaining files (`recently_played*.proto`, `rootlist_request.proto`,
  `playlist_*.proto`, `protobuf_delta.proto`, `extension_kind.proto`,
  `metadata/*.proto`) document the wire shapes for their respective spclient
  endpoints, retained for the same field-number-lookup purpose.

## Source

Extracted from Spotify client 1.2.52.442 (Windows) and cross-referenced
against the librespot project's own vendored proto definitions
(https://github.com/librespot-org/librespot). No code generation, compiler
invocation, or build-time processing is applied to these files anymore.
