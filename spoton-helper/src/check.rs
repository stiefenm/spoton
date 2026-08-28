//! `check` subcommand — D-08 JSON manifest emitter.
//!
//! Reads the whole binary once (Soloist binaries are single-digit MB; see
//! RESEARCH.md threat T-74-01), computes its SHA256, detects architecture
//! and an embedded Soloist version marker, and reports patch status via
//! `crate::patch::scan_status` -- Wave 2 fills patch scanning without this
//! file changing (RESEARCH.md key_links).

use anyhow::{bail, Context, Result};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::Path;

use crate::arch;
use crate::patch;

/// Marker prefix used to locate an embedded Soloist version string, e.g.
/// `soloist 1.3.7.489`.
const VERSION_MARKER: &[u8] = b"soloist ";

pub fn run(binary: &Path, expect_sha: Option<String>) -> Result<()> {
    let bytes = std::fs::read(binary)
        .with_context(|| format!("failed to read binary at {}", binary.display()))?;

    let sha256 = compute_sha256(&bytes);
    let detected_arch = arch::read_arch(&bytes);
    let soloist_version = find_soloist_version(&bytes);
    let status = patch::scan_status(&bytes);

    let mut obj = json!({
        "version": env!("CARGO_PKG_VERSION"),
        "arch": detected_arch,
        "soloist_version": soloist_version,
        "patches": {
            "lifetime": status.lifetime,
            "flac24_gates": status.flac24_gates,
        },
        "sha256": sha256,
        "patched": status.patched,
    });

    if let Some(expected) = expect_sha {
        let matches = expected.eq_ignore_ascii_case(&sha256);

        // WR-06: a SHA mismatch is the one condition an integrity check
        // most needs to surface via exit status. Returning an error here
        // (rather than printing "sha_matches": false and exiting 0) routes
        // through main.rs's existing error path -- a single JSON "error"
        // line and a non-zero exit -- so a caller that only checks exit
        // status (the natural shell idiom, and how Soloist.pm's
        // _runHelperJson slurps + parses exactly one JSON object) still
        // notices, instead of needing to parse and check `sha_matches`.
        if !matches {
            bail!("sha256 mismatch: expected {expected}, computed {sha256}");
        }

        obj["sha_matches"] = json!(matches);
    }

    println!("{obj}");
    Ok(())
}

fn compute_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// Scan `bytes` for `soloist <dotted-version>` and return the dotted
/// version string, or `None` if no such marker is present.
///
/// WR-01: a multi-MB binary can plausibly contain the marker bytes more
/// than once (help/usage text, user-agent strings, symbol names) before
/// the real version banner. Stopping at the first occurrence risks
/// rejecting a valid version when an earlier false-positive marker isn't
/// followed by a dotted number, so every marker position is tried in
/// order until one yields a dotted-numeric version.
fn find_soloist_version(bytes: &[u8]) -> Option<String> {
    let marker_len = VERSION_MARKER.len();
    let mut start = 0;

    while start + marker_len <= bytes.len() {
        let rel = bytes[start..]
            .windows(marker_len)
            .position(|window| window == VERSION_MARKER)?;
        let after = start + rel + marker_len;

        let version_bytes: Vec<u8> = bytes[after..]
            .iter()
            .copied()
            .take_while(|&b| b.is_ascii_digit() || b == b'.')
            .collect();

        if !version_bytes.is_empty() && version_bytes.contains(&b'.') {
            return String::from_utf8(version_bytes).ok();
        }

        start = after; // keep scanning past this false match
    }

    None
}
