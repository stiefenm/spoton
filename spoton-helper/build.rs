//! Pure-Rust protobuf codegen for the `protobuf` subcommand (D-02).
//!
//! Uses `.pure()` -- no system `protoc` binary is required on PATH, which is
//! mandatory for the cross-rs Docker build (RESEARCH.md Pitfall 1). The
//! three schema roots below pull in their full transitive import closure
//! automatically via the `proto/` include root; imported files must NOT be
//! listed as separate `.input()`s.

fn main() {
    protobuf_codegen::Codegen::new()
        .pure()
        .includes(["proto"])
        .input("proto/collection2v2.proto")
        .input("proto/recently_played.proto")
        .input("proto/recently_played_backend.proto")
        .input("proto/rootlist_request.proto")
        // The rootlist schema's generated code references sibling `super::*`
        // modules for every imported message type (protobuf-codegen does
        // not inline transitive imports) -- each file in the import closure
        // must be its own `.input()` so its module is emitted alongside
        // rootlist_request's.
        .input("proto/playlist_folder_state.proto")
        .input("proto/playlist_permission.proto")
        .input("proto/playlist_playlist_state.proto")
        .input("proto/protobuf_delta.proto")
        .input("proto/playlist_user_state.proto")
        .input("proto/extension_kind.proto")
        .input("proto/metadata/extension.proto")
        .input("proto/metadata/image_group.proto")
        .cargo_out_dir("protos")
        .run_from_script();
}
