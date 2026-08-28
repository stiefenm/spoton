//! spoton-helper — Soloist binary patcher, integrity checker, and protobuf
//! converter for the SpotOn LMS plugin.
//!
//! This binary opens no socket, holds no credentials, and touches only the
//! files given to it on the command line. See Cargo.toml for the deliberately
//! minimal dependency set.

mod arch;
mod check;
mod patch;
mod protobuf_cmd;

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
    /// Convert protobuf <-> JSON over stdin/stdout.
    Protobuf {
        #[arg(long)]
        schema: String,
        #[arg(long, default_value = "decode")]
        mode: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let result = match cli.cmd {
        Cmd::Check { binary, expect_sha } => check::run(&binary, expect_sha),
        Cmd::Patch { version, binary } => patch::run(&version, &binary),
        Cmd::Protobuf { schema, mode } => protobuf_cmd::run(&schema, &mode),
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
