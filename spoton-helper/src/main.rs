//! spoton-helper — Soloist binary patcher and integrity checker for the
//! SpotOn LMS plugin.
//!
//! This binary opens no socket, holds no credentials, and touches only the
//! files given to it on the command line. See Cargo.toml for the deliberately
//! minimal dependency set.
//!
//! Protobuf decoding lives entirely in Perl now (Plugins::SpotOn::API::ProtobufLite,
//! Phase 75 D-01/D-02) — this crate no longer carries a protobuf subcommand,
//! codegen build script, or the protobuf/protobuf-codegen crates. The
//! vendored .proto files under proto/ remain as schema documentation only.

mod arch;
mod check;
mod patch;

use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "spoton-helper", about = "SpotOn Soloist binary helper")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Patch a pinned-version Soloist binary in place (lifetime + FLAC24 gates).
    Patch {
        #[arg(long)]
        version: String,
        #[arg(long)]
        binary: PathBuf,
    },
    /// Report D-08 JSON: version, arch, soloist_version, patches, sha256, patched.
    Check {
        #[arg(long)]
        binary: PathBuf,
        #[arg(long)]
        expect_sha: Option<String>,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let result = match cli.cmd {
        Cmd::Check { binary, expect_sha } => check::run(&binary, expect_sha),
        Cmd::Patch { version, binary } => patch::run(&version, &binary),
    };

    if let Err(err) = result {
        // On any subcommand error, print a single-line JSON error object to
        // stdout and exit non-zero -- callers (Soloist.pm) parse stdout as
        // JSON unconditionally.
        let obj = serde_json::json!({ "error": err.to_string() });
        println!("{obj}");
        return ExitCode::FAILURE;
    }

    ExitCode::SUCCESS
}
