//! Wave 0 synthetic-fixture harness for `check` subcommand tests.
//!
//! Fixtures are crafted byte sequences, never a real distributed Soloist
//! binary (RESEARCH.md "Validation Architecture": tests must run against a
//! synthetic fixture). Wave 2 patch tests extend `write_fixture` by
//! injecting marker byte sequences into the same fixture body.

use std::path::{Path, PathBuf};
use std::process::Command;

/// ELF e_ident bytes up to (but not including) `e_type`/`e_machine`:
/// magic 0x7fELF, EI_CLASS=2 (64-bit), EI_DATA=1 (little-endian),
/// EI_VERSION=1, EI_OSABI=0, EI_ABIVERSION=0, 7 bytes padding.
const E_IDENT: [u8; 16] = [0x7f, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];

/// Write a crafted fixture file: a valid ELF header with `e_machine` set to
/// `arch_machine`, followed by an ASCII `soloist <version> build 000`
/// marker when `version` is `Some`, plus arbitrary padding so SHA256 is
/// well-defined. Returns the fixture's path.
fn write_fixture(dir: &Path, arch_machine: u16, version: Option<&str>) -> PathBuf {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(&E_IDENT);
    // e_type = ET_EXEC (2), little-endian.
    bytes.extend_from_slice(&2u16.to_le_bytes());
    // e_machine at offset 0x12.
    bytes.extend_from_slice(&arch_machine.to_le_bytes());

    if let Some(v) = version {
        bytes.extend_from_slice(b"soloist ");
        bytes.extend_from_slice(v.as_bytes());
        bytes.extend_from_slice(b" build 000");
    }

    // Arbitrary padding so the fixture has a well-defined, non-trivial
    // SHA256 regardless of the header/marker length above.
    bytes.extend_from_slice(&[0xAA; 32]);

    let path = dir.join("fixture.bin");
    std::fs::write(&path, &bytes).expect("write fixture");
    path
}

/// Run the compiled `spoton-helper check` binary against `binary` and parse
/// stdout as JSON.
fn run_check(binary: &Path) -> serde_json::Value {
    let output = Command::new(env!("CARGO_BIN_EXE_spoton-helper"))
        .arg("check")
        .arg("--binary")
        .arg(binary)
        .output()
        .expect("run spoton-helper check");

    assert!(
        output.status.success(),
        "check exited non-zero: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    serde_json::from_slice(&output.stdout).expect("check stdout is valid JSON")
}

#[test]
fn check_json_schema() {
    let dir = tempdir();
    let fixture = write_fixture(dir.path(), 0xB7, Some("1.3.7.489"));

    let value = run_check(&fixture);

    assert_eq!(value["arch"], "aarch64-linux");
    assert_eq!(value["soloist_version"], "1.3.7.489");
    assert_eq!(value["patched"], false);
    assert!(
        value["patches"]["flac24_gates"]
            .as_array()
            .expect("flac24_gates is an array")
            .len()
            == 6,
        "flac24_gates must have exactly 6 elements, got {:?}",
        value["patches"]["flac24_gates"]
    );
    let sha256 = value["sha256"].as_str().expect("sha256 is a string");
    assert_eq!(sha256.len(), 64, "sha256 must be a 64-char hex string");
    assert!(
        sha256.chars().all(|c| c.is_ascii_hexdigit()),
        "sha256 must be hex: {sha256}"
    );
}

#[test]
fn check_rejects_non_elf() {
    let dir = tempdir();
    let path = dir.path().join("not_elf.bin");
    std::fs::write(&path, b"this is definitely not an ELF file, just text padding")
        .expect("write non-ELF fixture");

    let value = run_check(&path);

    assert!(value["arch"].is_null(), "arch must be null for non-ELF input, fails closed");
}

/// Minimal tempdir helper (no external crate dependency): create a
/// uniquely-named directory under the OS temp dir and clean it up on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn tempdir() -> TempDir {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    let dir = std::env::temp_dir().join(format!("spoton-helper-fixture-{pid}-{n}"));
    std::fs::create_dir_all(&dir).expect("create tempdir");
    TempDir(dir)
}
