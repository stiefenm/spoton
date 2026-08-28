//! Protobuf <-> JSON conversion (STUB for Wave 1 / Plan 01).
//!
//! Wave 2 (Plan 03) replaces this with real `protobuf` 3.7 `.pure()`-codegen
//! decode/encode for collection/v2, recently-played, and rootlist schemas
//! (D-02). This stub keeps `protobuf` dispatchable from `main.rs` and
//! returns a structured "unimplemented" JSON error via the shared
//! `main.rs` error-printing path.

pub fn run(_schema: &str, _mode: &str) -> anyhow::Result<()> {
    anyhow::bail!("protobuf: unimplemented in this build")
}
