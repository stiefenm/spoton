//! Per-arch patch-site table.
//!
//! PUBLIC CHECKOUT: this table is intentionally EMPTY. The concrete
//! Lifetime-timestamp and FLAC24-gate byte patterns are reverse-engineering
//! output validated against a private Soloist build (phase 74 COMPLIANCE
//! NOTE / RESEARCH.md Open Question 1) and are never committed to this
//! public repository as plaintext.
//!
//! Release builds inject the real per-arch tables at build time from the
//! private validated source, replacing the match arms in `sites_for` below.
//! In a plain public checkout every arch's table is empty, so `patch`
//! reports `status: "unsupported"` and performs a clean no-op --
//! RESEARCH.md Pattern 1 safety envelope, D-06/T-74-06 compliance.

/// Which logical patch this site belongs to. Recorded as data (not a
/// positional/magic index) so the D-06 Gate 4 skip is auditable straight
/// from the table (RESEARCH.md Pattern 1, point 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SiteKind {
    /// D-05: the single ASCII-timestamp site in `.rodata`.
    Lifetime,
    /// D-06: one of the six FLAC24 enum-downgrade gates, indexed 0..6.
    Flac24Gate(usize),
}

/// A single patch site: a byte-exact search pattern, its replacement, and
/// the exact number of times `search` must occur in the target binary
/// before any write is permitted (T-74-03 / T-74-04 fail-closed
/// discipline).
pub struct PatchSite {
    pub name: &'static str,
    pub kind: SiteKind,
    pub search: &'static [u8],
    pub replace: &'static [u8],
    pub expect_count: usize,
    /// D-06: Gate 4 (the FLAC24 crash gate) is asserted present but never
    /// replaced -- `skip` is data, not a magic index.
    pub skip: bool,
}

/// Select the patch-site table for `arch` (the bindir vocabulary produced
/// by `arch::read_arch`: `"x86_64-linux"` / `"aarch64-linux"` /
/// `"armhf-linux"`).
///
/// PRIVATE-INJECTION POINT.
/// Release CI replaces the empty slices below with the validated per-arch
/// Lifetime + FLAC24 gate tables from the private source. Do not add
/// concrete byte-pattern literals to this file in the public repo.
pub fn sites_for(arch: &str) -> &'static [PatchSite] {
    match arch {
        "x86_64-linux" => &[],
        "aarch64-linux" => &[],
        "armhf-linux" => &[],
        _ => &[],
    }
}
