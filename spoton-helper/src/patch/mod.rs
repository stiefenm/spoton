//! Patch engine: version-locked, fail-closed per-arch pattern-table
//! patcher (RESEARCH.md Pattern 1).
//!
//! `run` applies the Lifetime timestamp patch (D-05) and the FLAC24
//! enum-downgrade gates (D-06, 5 of 6 -- Gate 4 is deliberately skipped)
//! behind a mandatory safety envelope: version gate -> exact-occurrence
//! assertion -> stage+self-verify -> atomic rename. `scan_status` is the
//! read-only counterpart `check.rs` depends on (RESEARCH.md key_links) --
//! its signature must not change without updating `check.rs`.
//!
//! The concrete per-arch byte patterns live in `patterns::sites_for` and
//! are, in a public checkout, an empty table per arch (see that module's
//! doc comment) -- `patch` then reports `status: "unsupported"` and is a
//! clean no-op.

pub mod encoding;
pub mod patterns;

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

use crate::arch;
use patterns::{PatchSite, SiteKind};

/// Marker prefix used to locate an embedded Soloist version string, e.g.
/// `soloist 1.3.7.489`. Mirrors `check.rs::VERSION_MARKER` -- kept as a
/// private duplicate since the two modules must not share mutable state
/// and `check.rs` is out of scope for this plan.
const VERSION_MARKER: &[u8] = b"soloist ";

/// Patch status as reported by both `check` (read-only scan) and `patch`
/// (post-write verification).
pub struct PatchStatus {
    pub lifetime: bool,
    pub flac24_gates: [bool; 6],
    pub patched: bool,
}

/// Scan `bytes` for the current patch state without mutating anything.
pub fn scan_status(bytes: &[u8]) -> PatchStatus {
    match arch::read_arch(bytes) {
        Some(arch) => scan_status_for_sites(bytes, patterns::sites_for(arch)),
        None => PatchStatus {
            lifetime: false,
            flac24_gates: [false; 6],
            patched: false,
        },
    }
}

/// Core of `scan_status`, parameterized over an explicit site table so unit
/// tests can drive it with a TEST-ONLY table (see `tests` module below).
fn scan_status_for_sites(bytes: &[u8], sites: &[PatchSite]) -> PatchStatus {
    let mut lifetime = false;
    let mut flac24_gates = [false; 6];

    for site in sites {
        // A site is "applied" when its replacement bytes are present. Skip
        // sites (Gate 4) are never written by `run`, so this same rule
        // naturally keeps them reporting false -- no special case needed.
        let present = count_occurrences(bytes, site.replace) > 0;
        match site.kind {
            SiteKind::Lifetime => lifetime = present,
            SiteKind::Flac24Gate(i) if i < flac24_gates.len() => flac24_gates[i] = present,
            SiteKind::Flac24Gate(_) => {}
        }
    }

    let non_skip_gates_applied = sites
        .iter()
        .filter_map(|s| match s.kind {
            SiteKind::Flac24Gate(i) if !s.skip && i < flac24_gates.len() => Some(i),
            _ => None,
        })
        .all(|i| flac24_gates[i]);

    let patched = !sites.is_empty() && lifetime && non_skip_gates_applied;

    PatchStatus {
        lifetime,
        flac24_gates,
        patched,
    }
}

/// Apply the lifetime + FLAC24 patches to `binary` for the pinned Soloist
/// `version`. See module doc for the safety envelope.
pub fn run(version: &str, binary: &Path) -> Result<()> {
    let value = run_core(version, binary, patterns::sites_for)?;
    println!("{value}");
    Ok(())
}

/// Testable core of `run`: takes an injectable site-table resolver so unit
/// tests can drive the full engine (version gate, count assertion,
/// staging, self-verify, atomic rename) against a TEST-ONLY pattern table
/// without touching the real (empty, in public checkouts) one -- and
/// returns the JSON value instead of printing it, so tests can assert on
/// it directly.
fn run_core(
    version: &str,
    binary: &Path,
    table_for_arch: impl Fn(&str) -> &'static [PatchSite],
) -> Result<Value> {
    let bytes = std::fs::read(binary)
        .with_context(|| format!("failed to read binary at {}", binary.display()))?;

    // 1. Version gate -- refuse before touching anything else.
    let embedded_version = find_soloist_version(&bytes);
    if embedded_version.as_deref() != Some(version) {
        bail!(
            "version mismatch: target reports {:?}, expected {version:?} -- refusing to patch",
            embedded_version
        );
    }

    // 2. Resolve arch + pattern table. Encoding lookup is a defensive
    // cross-check that the arch is one the engine knows how to reason
    // about at all (encoding.rs scaffolding), independent of whether the
    // (possibly private-injected) pattern table has entries for it.
    let Some(detected_arch) = arch::read_arch(&bytes) else {
        bail!(
            "unable to determine architecture of {} -- refusing to patch",
            binary.display()
        );
    };
    if encoding::encoding_for(detected_arch).is_none() {
        bail!("unsupported architecture {detected_arch:?} -- refusing to patch");
    }
    let sites = table_for_arch(detected_arch);

    if sites.is_empty() {
        return Ok(json!({ "status": "unsupported", "arch": detected_arch }));
    }

    // 3. Exact-occurrence assertion -- every site, before any write.
    for site in sites {
        let count = count_occurrences(&bytes, site.search);
        if count != site.expect_count {
            bail!(
                "pattern count mismatch for site {name:?}: expected {expected} occurrence(s), found {count} -- refusing to patch, no bytes written",
                name = site.name,
                expected = site.expect_count,
            );
        }
    }

    // 4. Apply -- replace every non-skip site; skip sites are asserted
    // present above but never rewritten (D-06 auditable exclusion).
    let mut patched_bytes = bytes.clone();
    for site in sites {
        if site.skip {
            continue;
        }
        replace_all(&mut patched_bytes, site.search, site.replace);
    }

    // 5. Self-verify the staged bytes before they ever touch disk.
    let staged_status = scan_status_for_sites(&patched_bytes, sites);
    if !staged_status.patched {
        bail!("post-patch self-verification failed: staged bytes do not report a patched state");
    }

    // Stage in the same directory as the target, then atomically rename
    // over it -- never mutate the target in place (T-74-04).
    let staging_path = staging_path_for(binary)?;
    std::fs::write(&staging_path, &patched_bytes).with_context(|| {
        format!(
            "failed to write staging file {}",
            staging_path.display()
        )
    })?;

    if let Err(err) = std::fs::rename(&staging_path, binary) {
        let _ = std::fs::remove_file(&staging_path);
        return Err(err).with_context(|| {
            format!(
                "failed to atomically rename staged patch over {}",
                binary.display()
            )
        });
    }

    Ok(json!({
        "status": "patched",
        "lifetime": staged_status.lifetime,
        "flac24_gates": staged_status.flac24_gates,
        "patched": staged_status.patched,
    }))
}

/// Count non-overlapping-window occurrences of `needle` in `bytes`. An
/// empty needle never "occurs" -- avoids a degenerate always-true count.
fn count_occurrences(bytes: &[u8], needle: &[u8]) -> usize {
    if needle.is_empty() || bytes.len() < needle.len() {
        return 0;
    }
    bytes.windows(needle.len()).filter(|w| *w == needle).count()
}

/// Replace every occurrence of `search` with `replace` in `bytes`,
/// rebuilding the buffer. `search` and `replace` need not be the same
/// length.
fn replace_all(bytes: &mut Vec<u8>, search: &[u8], replace: &[u8]) {
    if search.is_empty() {
        return;
    }
    let mut result = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i..].starts_with(search) {
            result.extend_from_slice(replace);
            i += search.len();
        } else {
            result.push(bytes[i]);
            i += 1;
        }
    }
    *bytes = result;
}

/// Build a staging file path in the same directory as `binary` (T-74-05:
/// stage where the caller already trusts the directory, never in a shared
/// tmp location).
fn staging_path_for(binary: &Path) -> Result<PathBuf> {
    let file_name = binary
        .file_name()
        .context("binary path has no file name")?
        .to_string_lossy()
        .into_owned();
    let parent = binary.parent().unwrap_or_else(|| Path::new("."));
    Ok(parent.join(format!(
        ".{file_name}.spoton-helper-staging-{}",
        std::process::id()
    )))
}

/// Scan `bytes` for `soloist <dotted-version>` and return the dotted
/// version string, or `None` if no such marker is present. Mirrors
/// `check.rs::find_soloist_version`.
fn find_soloist_version(bytes: &[u8]) -> Option<String> {
    let marker_len = VERSION_MARKER.len();
    if bytes.len() < marker_len {
        return None;
    }
    let pos = bytes
        .windows(marker_len)
        .position(|window| window == VERSION_MARKER)?;

    let rest = &bytes[pos + marker_len..];
    let version_bytes: Vec<u8> = rest
        .iter()
        .copied()
        .take_while(|&b| b.is_ascii_digit() || b == b'.')
        .collect();

    if version_bytes.is_empty() || !version_bytes.contains(&b'.') {
        return None;
    }

    String::from_utf8(version_bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    // TEST-ONLY pattern table: synthetic search/replace markers, wholly
    // unrelated to the real (privately-injected) Lifetime/FLAC24 patterns.
    // Gate index 3 carries `skip: true`, mirroring the real D-06 Gate 4
    // exclusion (encoded as data, not a magic index).
    static TEST_SITES: &[PatchSite] = &[
        PatchSite {
            name: "lifetime",
            kind: SiteKind::Lifetime,
            search: b"OLDTIME_MARKER_0123456789",
            replace: b"NEWTIME_MARKER_9876543210",
            expect_count: 1,
            skip: false,
        },
        PatchSite {
            name: "gate_0",
            kind: SiteKind::Flac24Gate(0),
            search: b"GATE0_SEARCH_MARKER_AA",
            replace: b"GATE0_REPLACE_MARKER_11",
            expect_count: 1,
            skip: false,
        },
        PatchSite {
            name: "gate_1",
            kind: SiteKind::Flac24Gate(1),
            search: b"GATE1_SEARCH_MARKER_BB",
            replace: b"GATE1_REPLACE_MARKER_22",
            expect_count: 1,
            skip: false,
        },
        PatchSite {
            name: "gate_2",
            kind: SiteKind::Flac24Gate(2),
            search: b"GATE2_SEARCH_MARKER_CC",
            replace: b"GATE2_REPLACE_MARKER_33",
            expect_count: 1,
            skip: false,
        },
        PatchSite {
            name: "gate_3_crash",
            kind: SiteKind::Flac24Gate(3),
            search: b"GATE3_SEARCH_MARKER_DD",
            replace: b"GATE3_REPLACE_MARKER_44",
            expect_count: 1,
            skip: true,
        },
        PatchSite {
            name: "gate_4",
            kind: SiteKind::Flac24Gate(4),
            search: b"GATE4_SEARCH_MARKER_EE",
            replace: b"GATE4_REPLACE_MARKER_55",
            expect_count: 1,
            skip: false,
        },
        PatchSite {
            name: "gate_5",
            kind: SiteKind::Flac24Gate(5),
            search: b"GATE5_SEARCH_MARKER_FF",
            replace: b"GATE5_REPLACE_MARKER_66",
            expect_count: 1,
            skip: false,
        },
    ];

    fn test_sites_for(_arch: &str) -> &'static [PatchSite] {
        TEST_SITES
    }

    const LOCKED_VERSION: &str = "1.3.7.489";

    /// Build a synthetic ELF fixture (aarch64, like tests/fixture.rs) with
    /// an embedded Soloist version marker and, optionally, one occurrence
    /// of every TEST_SITES search pattern.
    fn write_fixture(dir: &Path, version: Option<&str>, include_sites: bool) -> PathBuf {
        let mut bytes = Vec::new();
        // e_ident: magic + 64-bit + little-endian + version 1 + padding.
        bytes.extend_from_slice(&[0x7f, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        // e_type = ET_EXEC.
        bytes.extend_from_slice(&2u16.to_le_bytes());
        // e_machine = EM_AARCH64 (0xB7), at offset 0x12.
        bytes.extend_from_slice(&0xB7u16.to_le_bytes());

        if let Some(v) = version {
            bytes.extend_from_slice(b"soloist ");
            bytes.extend_from_slice(v.as_bytes());
            bytes.extend_from_slice(b" build 000");
        }

        if include_sites {
            for site in TEST_SITES {
                bytes.extend_from_slice(b"\x00\x00");
                bytes.extend_from_slice(site.search);
                bytes.extend_from_slice(b"\x00\x00");
            }
        }

        bytes.extend_from_slice(&[0xAA; 16]);

        let path = dir.join("soloist-fixture.bin");
        std::fs::write(&path, &bytes).expect("write fixture");
        path
    }

    fn tempdir() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let pid = std::process::id();
        let dir = std::env::temp_dir().join(format!("spoton-helper-patch-test-{pid}-{n}"));
        std::fs::create_dir_all(&dir).expect("create tempdir");
        dir
    }

    #[test]
    fn full_patch_applies_lifetime_and_five_gates() {
        let dir = tempdir();
        let fixture = write_fixture(&dir, Some(LOCKED_VERSION), true);
        let original_bytes = std::fs::read(&fixture).unwrap();

        let value = run_core(LOCKED_VERSION, &fixture, test_sites_for).expect("patch succeeds");
        assert_eq!(value["status"], "patched");
        assert_eq!(value["patched"], true);
        assert_eq!(value["lifetime"], true);

        let patched_bytes = std::fs::read(&fixture).unwrap();
        assert_ne!(patched_bytes, original_bytes, "target must have been rewritten");

        let status = scan_status_for_sites(&patched_bytes, TEST_SITES);
        assert_eq!(
            status.flac24_gates,
            [true, true, true, false, true, true],
            "gate index 3 (the crash gate) must remain unpatched"
        );
        assert!(status.patched);

        // No leftover staging file.
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("staging"))
            .collect();
        assert!(leftovers.is_empty(), "staging file must not survive a successful patch");
    }

    #[test]
    fn wrong_version_aborts_with_no_write() {
        let dir = tempdir();
        let fixture = write_fixture(&dir, Some("1.2.3.999"), true);
        let original_bytes = std::fs::read(&fixture).unwrap();

        let result = run_core(LOCKED_VERSION, &fixture, test_sites_for);
        assert!(result.is_err(), "wrong version must abort");

        let after_bytes = std::fs::read(&fixture).unwrap();
        assert_eq!(after_bytes, original_bytes, "target must be byte-identical after abort");
    }

    #[test]
    fn count_mismatch_aborts_with_no_write() {
        let dir = tempdir();
        // include_sites=false -> every search pattern occurs 0 times,
        // which != expect_count (1) for every site.
        let fixture = write_fixture(&dir, Some(LOCKED_VERSION), false);
        let original_bytes = std::fs::read(&fixture).unwrap();

        let result = run_core(LOCKED_VERSION, &fixture, test_sites_for);
        assert!(result.is_err(), "count mismatch must abort");

        let after_bytes = std::fs::read(&fixture).unwrap();
        assert_eq!(after_bytes, original_bytes, "target must be byte-identical after abort");
    }

    #[test]
    fn empty_public_table_is_unsupported_no_op() {
        let dir = tempdir();
        let fixture = write_fixture(&dir, Some(LOCKED_VERSION), true);
        let original_bytes = std::fs::read(&fixture).unwrap();

        // The real, production `patterns::sites_for` -- empty per arch in
        // this public checkout.
        let value = run_core(LOCKED_VERSION, &fixture, patterns::sites_for)
            .expect("empty table is a clean no-op, not an error");
        assert_eq!(value["status"], "unsupported");

        let after_bytes = std::fs::read(&fixture).unwrap();
        assert_eq!(after_bytes, original_bytes, "unsupported no-op must not write");
    }

    #[test]
    fn scan_status_reports_gate4_skip_after_patch() {
        let dir = tempdir();
        let fixture = write_fixture(&dir, Some(LOCKED_VERSION), true);

        run_core(LOCKED_VERSION, &fixture, test_sites_for).expect("patch succeeds");

        let patched_bytes = std::fs::read(&fixture).unwrap();
        let status = scan_status_for_sites(&patched_bytes, TEST_SITES);
        assert!(status.lifetime);
        assert_eq!(status.flac24_gates, [true, true, true, false, true, true]);
        assert!(status.patched);
    }
}
