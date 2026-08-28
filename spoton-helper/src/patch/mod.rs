//! Patch engine (STUB for Wave 1 / Plan 01).
//!
//! Wave 2 (Plan 02) replaces the bodies of `scan_status` and `run` with the
//! real per-arch pattern-table patcher (version gate + exact-occurrence
//! assertion + staged self-verify + atomic rename, per RESEARCH.md Pattern
//! 1). The signatures below are the contract `check.rs` and `main.rs`
//! depend on and must not change without updating both call sites.

use std::path::Path;

/// Patch status as reported by both `check` (read-only scan) and `patch`
/// (post-write verification).
pub struct PatchStatus {
    pub lifetime: bool,
    pub flac24_gates: [bool; 6],
    pub patched: bool,
}

/// Scan `bytes` for the current patch state without mutating anything.
/// STUB: always reports the all-false "unpatched" defaults until Wave 2
/// fills in the real per-arch pattern table.
pub fn scan_status(_bytes: &[u8]) -> PatchStatus {
    PatchStatus {
        lifetime: false,
        flac24_gates: [false; 6],
        patched: false,
    }
}

/// Apply the lifetime + FLAC24 patches to `binary` for the pinned Soloist
/// `version`. STUB: unconditionally refuses until Wave 2 implements the
/// real patch engine.
pub fn run(_version: &str, _binary: &Path) -> anyhow::Result<()> {
    anyhow::bail!("patch: unimplemented in this build")
}
