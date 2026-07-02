// SpotOn librespot integration binary for Lyrion Music Server
//
// Phase 04.2 implementation: --token-login subcommand for credential provisioning
// Phase 04.3 implementation: --discover-once subcommand for ZeroConf credential acquisition
// Phase 29.1 implementation: --unified mode (Browse + Connect in one process)
// Phase 30: removed legacy --single-track, --connect, --browse modes
//
// Modes:
//   --check          : Print capability manifest (Phase 1 contract, unchanged)
//   --authenticate   : Acquire credentials via username/password, write credentials.json
//   --get-token      : Read cached credentials, return Web API token JSON to stdout
//   --token-login    : Acquire reusable credentials from OAuth access token, write credentials.json
//   --discover-once  : ZeroConf mDNS announcement, wait for Spotify App connection, write credentials.json
//   --unified        : Combined Browse+Connect daemon (one process, one port, optional Spirc)
//
// --check output format:
//   Line 1: "ok spoton v{VERSION}"
//   Line 2: JSON capability manifest
//
// --authenticate contract (for Settings.pm):
//   Command: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>
//   stdout: "authorized" on success
//   exit 0 on success, non-zero on failure
//
// --get-token contract (for TokenManager.pm):
//   Command: spoton -n 'SpotOn' --cache <dir> --get-token [--scope <scopes>]
//   stdout: {"accessToken":"<token>","expiresIn":<seconds>}
//   exit 0 on success, non-zero on failure
//
// --token-login contract (for TokenManager.pm):
//   Command: spoton -n 'SpotOn' --token-login --token <access_token> --cache <dir>
//   stdout: "credentials_saved" on success
//   exit 0 on success, non-zero on failure
//
// --discover-once contract (for Settings.pm / TokenManager.pm):
//   Command: spoton -n 'LMS-Server-Name' --cache <dir> --discover-once
//   stdout line 1: "credentials_saved"
//   stdout line 2: spotify_username
//   exit 0 on success, exit 1 on failure (including 15-min timeout)

mod connect;  // connect.rs: LMS + HttpStreamSink used by unified.rs
mod browse;   // browse.rs: BrowseHttpSink + serve_track_request used by unified.rs
mod unified;  // Phase 29: unified Browse+Connect daemon (one process, one port)

use std::env;
use std::process;

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::Session;

// Phase 04.3: ZeroConf Discovery imports
use librespot_discovery::{DeviceType, Discovery};
use futures_util::StreamExt;
use tokio::time::{timeout, Duration};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, PartialEq)]
enum Mode {
    Check,
    Authenticate,
    GetToken,
    TokenLogin,    // Phase 04.2: credential provisioning from OAuth access token
    DiscoverOnce,  // Phase 04.3: ZeroConf mDNS credential acquisition
    Unified,       // Phase 29: combined Browse+Connect daemon (one process, one port)
}

#[tokio::main]
async fn main() {
    // SPOTON_LOG_FILE: Windows services can't redirect stderr via Proc::Background.
    // When set, write logs to this file instead of stderr.
    if let Ok(log_path) = std::env::var("SPOTON_LOG_FILE") {
        use std::fs::OpenOptions;
        match OpenOptions::new().create(true).append(true).open(&log_path) {
            Ok(file) => {
                env_logger::Builder::from_default_env()
                    .target(env_logger::Target::Pipe(Box::new(file)))
                    .init();
            }
            Err(e) => {
                env_logger::init();
                log::warn!("Cannot open SPOTON_LOG_FILE '{}': {} — falling back to stderr", log_path, e);
            }
        }
    } else {
        env_logger::init();
    }
    let args: Vec<String> = env::args().collect();

    let mut mode = Mode::Check;
    let mut device_name = String::new();
    let mut username = String::new();
    let mut password = String::new();
    let mut token_str = String::new();
    let mut cache_dir = String::new();
    let mut scope = String::new();
    let mut client_id = String::new();

    // Connect / unified mode variables
    let mut player_mac = String::new();
    let mut lms_host = String::new();
    let mut lms_auth = String::new();
    let mut disable_discovery = false;
    let mut buffer_latency_ms: u64 = 2000;
    let mut autoplay: Option<bool> = None;
    let mut initial_volume_lms: Option<u8> = None;
    let mut volume_ctrl_str = String::from("log");

    // Phase 29: unified mode variable
    let mut enable_connect = false;

    // Phase 42: OGG/Vorbis passthrough mode
    let mut passthrough = false;

    // Issue #97: Spotify bitrate preference (96, 160, 320 kbps)
    let mut bitrate: u32 = 320;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--check" => {
                mode = Mode::Check;
            }
            "--authenticate" => {
                mode = Mode::Authenticate;
            }
            "--get-token" => {
                mode = Mode::GetToken;
            }
            "--token-login" => {
                mode = Mode::TokenLogin;
            }
            "--discover-once" => {
                mode = Mode::DiscoverOnce;
            }
            "--unified" => {
                mode = Mode::Unified;
            }
            "--enable-connect" => {
                enable_connect = true;
            }
            "--passthrough" => {
                passthrough = true;
            }
            "--bitrate" | "-b" => {
                if i + 1 < args.len() {
                    bitrate = match args[i + 1].as_str() {
                        "96" => 96,
                        "160" => 160,
                        "320" => 320,
                        _ => {
                            eprintln!("Invalid bitrate '{}', using 320", args[i + 1]);
                            320
                        }
                    };
                    i += 1;
                }
            }
            "--token" => {
                if i + 1 < args.len() {
                    token_str = args[i + 1].clone();
                    i += 1;
                }
            }
            "--disable-discovery" => {
                disable_discovery = true;
            }
            "--player-mac" => {
                if i + 1 < args.len() {
                    player_mac = args[i + 1].clone();
                    i += 1;
                }
            }
            "--lms" => {
                if i + 1 < args.len() {
                    lms_host = args[i + 1].clone();
                    i += 1;
                }
            }
            "--lms-auth" => {
                if i + 1 < args.len() {
                    lms_auth = args[i + 1].clone();
                    i += 1;
                }
            }
            "--buffer-latency-ms" => {
                if i + 1 < args.len() {
                    buffer_latency_ms = args[i + 1].parse().unwrap_or(2000);
                    i += 1;
                }
            }
            "--autoplay" => {
                if i + 1 < args.len() {
                    autoplay = match args[i + 1].as_str() {
                        "on"  => Some(true),
                        "off" => Some(false),
                        _     => None,
                    };
                    i += 1;
                }
            }
            "--initial-volume" => {
                if i + 1 < args.len() {
                    initial_volume_lms = args[i + 1].parse::<u8>().ok().map(|v| v.min(100));
                    i += 1;
                }
            }
            "--volume-ctrl" => {
                if i + 1 < args.len() {
                    volume_ctrl_str = args[i + 1].clone();
                    i += 1;
                }
            }
            "-n" | "--name" => {
                if i + 1 < args.len() {
                    device_name = args[i + 1].clone();
                    i += 1;
                }
            }
            "--username" | "-u" => {
                if i + 1 < args.len() {
                    username = args[i + 1].clone();
                    i += 1;
                }
            }
            "--password" | "-p" => {
                if i + 1 < args.len() {
                    password = args[i + 1].clone();
                    i += 1;
                }
            }
            "--cache" | "-c" => {
                if i + 1 < args.len() {
                    cache_dir = args[i + 1].clone();
                    i += 1;
                }
            }
            "--scope" => {
                if i + 1 < args.len() {
                    scope = args[i + 1].clone();
                    i += 1;
                }
            }
            "--client-id" => {
                if i + 1 < args.len() {
                    client_id = args[i + 1].clone();
                    i += 1;
                }
            }
            _ => {
                // Ignore unknown flags for forward compatibility
            }
        }
        i += 1;
    }

    // H10: LMS credentials via environment take precedence over the --lms-auth
    // flag. argv is world-readable via /proc/<pid>/cmdline; the env var is set
    // by Daemon.pm just for the spawn and deleted immediately after. The flag
    // is retained for manual testing / backward compatibility. Never log the value.
    if let Ok(env_auth) = std::env::var("SPOTON_LMS_AUTH") {
        if !env_auth.is_empty() {
            lms_auth = env_auth;
        }
    }

    // Convert LMS volume scale (0-100) to librespot u16 scale (0-65535)
    let initial_volume_u16: Option<u16> = initial_volume_lms.map(|v| (v as u32 * 65535 / 100) as u16);

    match mode {
        Mode::Check => {
            // Phase 1 --check contract — Regex in Helper.pm: /^ok spoton v([\d\.]+)/i
            println!("ok spoton v{}", VERSION);
            // Report passthrough capability based on compiled features
            let has_passthrough = cfg!(feature = "passthrough-decoder");
            let json = serde_json::json!({
                "version": VERSION,
                "autoplay": true,
                "browse": true,           // Phase 28: persistent Browse daemon capability
                "discover-once": true,
                "lms-auth": true,
                "ogg-direct": has_passthrough,
                "passthrough": has_passthrough,
                "token-login": true,
                "unified": true,          // Phase 29: unified Browse+Connect daemon capability
            });
            println!("{}", json);
            process::exit(0);
        }

        Mode::Authenticate => {
            if username.is_empty() {
                eprintln!("Error: --username is required for --authenticate");
                eprintln!("Usage: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>");
                process::exit(1);
            }
            if password.is_empty() {
                eprintln!("Error: --password is required for --authenticate");
                eprintln!("Usage: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>");
                process::exit(1);
            }
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --authenticate");
                eprintln!("Usage: spoton -n 'SpotOn' --username <u> --password <p> --authenticate --cache <dir>");
                process::exit(1);
            }

            match run_authenticate(&username, &password, &cache_dir).await {
                Ok(_) => {
                    println!("authorized");
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Authentication failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::GetToken => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --get-token");
                eprintln!("Usage: spoton -n 'SpotOn' --cache <dir> --get-token [--scope <scopes>]");
                process::exit(1);
            }

            match run_get_token(&cache_dir, &scope, &client_id).await {
                Ok(_) => {
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Token retrieval failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::TokenLogin => {
            if token_str.is_empty() {
                eprintln!("Error: --token is required for --token-login");
                eprintln!("Usage: spoton -n 'SpotOn' --token-login --token <access_token> --cache <dir>");
                process::exit(1);
            }
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --token-login");
                eprintln!("Usage: spoton -n 'SpotOn' --token-login --token <access_token> --cache <dir>");
                process::exit(1);
            }

            match run_token_login(&token_str, &cache_dir).await {
                Ok(_) => {
                    println!("credentials_saved");
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Token login failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::DiscoverOnce => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --discover-once");
                eprintln!("Usage: spoton -n 'LMS-Server' --cache <dir> --discover-once");
                process::exit(1);
            }

            match run_discover_once(&device_name, &cache_dir).await {
                Ok(username) => {
                    println!("credentials_saved");
                    println!("{}", username);
                    process::exit(0);
                }
                Err(e) => {
                    eprintln!("Discovery failed: {}", e);
                    process::exit(1);
                }
            }
        }

        Mode::Unified => {
            if cache_dir.is_empty() {
                eprintln!("Error: --cache is required for --unified");
                eprintln!("Usage: spoton -c <dir> --unified --player-mac <mac>");
                eprintln!("       spoton -n 'DeviceName' -c <dir> --unified --player-mac <mac> --enable-connect --lms <host:port>");
                process::exit(1);
            }

            match unified::run_unified(
                &cache_dir,
                &device_name,
                if player_mac.is_empty() { None } else { Some(&player_mac) },
                if lms_host.is_empty() { None } else { Some(&lms_host) },
                if lms_auth.is_empty() { None } else { Some(&lms_auth) },
                enable_connect,
                disable_discovery,
                buffer_latency_ms,
                autoplay,
                initial_volume_u16,
                &volume_ctrl_str,
                passthrough,
                bitrate,
            )
            .await
            {
                Ok(_) => process::exit(0),
                Err(e) => {
                    eprintln!("Unified mode error: {}", e);
                    process::exit(1);
                }
            }
        }
    }
}

/// Authenticate with Spotify via login5 username/password.
/// On success, writes credentials.json to cache_dir and returns Ok(()).
async fn run_authenticate(
    username: &str,
    password: &str,
    cache_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let credentials = Credentials::with_password(username, password);

    // Cache object: credentials_path = cache_dir, no volume/audio paths
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));

    // connect() with store_credentials=true saves credentials.json to cache_dir
    session.connect(credentials, true).await?;

    Ok(())
}

/// Acquire reusable credentials from a Spotify OAuth access token.
///
/// Calls Credentials::with_access_token() (auth_type = AUTHENTICATION_SPOTIFY_TOKEN,
/// verified in librespot-core-0.8.0/src/authentication.rs:61-67), then connects with
/// store_credentials=true. librespot-core performs the token->reusable_credentials
/// exchange internally (session.rs:184-201, session.rs:249-258) and writes
/// credentials.json to cache_dir.
///
/// No manual reconnect needed — librespot handles the double-connect internally
/// (RESEARCH.md Pitfall 1).
async fn run_token_login(
    access_token: &str,
    cache_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Credentials::with_access_token() sets auth_type = AUTHENTICATION_SPOTIFY_TOKEN
    let credentials = Credentials::with_access_token(access_token);

    // Cache object: credentials_path = cache_dir, no volume/audio paths
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));

    // store_credentials=true: librespot-core connects, receives reusable_auth_credentials
    // from Spotify AP, and writes credentials.json to cache_dir automatically
    session.connect(credentials, true).await?;

    Ok(())
}

/// Read cached credentials from cache_dir, connect to Spotify, and
/// retrieve a Web API access token. Prints JSON to stdout:
///   {"accessToken":"<token>","expiresIn":<seconds>}
async fn run_get_token(
    cache_dir: &str,
    scope: &str,
    client_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Load cached credentials from credentials.json in cache_dir
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;

    let credentials = match cache.credentials() {
        Some(c) => c,
        None => {
            return Err(format!(
                "No cached credentials found in '{}'. Run --authenticate first.",
                cache_dir
            )
            .into());
        }
    };

    let session_config = SessionConfig::default();
    let session = Session::new(session_config, None);

    // Connect using cached credentials (store_credentials=false — already stored)
    session.connect(credentials, false).await?;

    // Determine scopes to request
    let scopes_str = if scope.is_empty() {
        // Default scopes required by SpotOn plugin
        "user-read-private,user-read-email,user-library-read,user-library-modify,\
         user-read-playback-state,user-modify-playback-state,user-read-currently-playing,\
         user-read-recently-played,user-top-read,user-read-playback-position,\
         playlist-read-private,playlist-read-collaborative,\
         playlist-modify-public,playlist-modify-private,\
         user-follow-read,user-follow-modify"
            .to_string()
    } else {
        scope.to_string()
    };

    // Get token via Keymaster/Mercury protocol
    let token = if client_id.is_empty() {
        session.token_provider().get_token(&scopes_str).await?
    } else {
        session.token_provider().get_token_with_client_id(&scopes_str, client_id).await?
    };

    // expires_in is a Duration — convert to whole seconds for the JSON contract
    let expires_in_secs = token.expires_in.as_secs();

    // Print JSON to stdout as required by TokenManager.pm
    // Contract: {"accessToken":"<token>","expiresIn":<seconds>}
    let json = serde_json::json!({
        "accessToken": token.access_token,
        "expiresIn": expires_in_secs,
    });
    println!("{}", json);

    Ok(())
}

/// ZeroConf Discovery: announce via mDNS, wait for first Spotify App connection,
/// write credentials.json, return spotify_username.
///
/// Contract for Perl layer (stdout):
///   Line 1: "credentials_saved"
///   Line 2: spotify_username
///   exit 0 on success, exit 1 on failure (including 15-min timeout)
///
/// Timeout: 15 minutes (900 seconds), matching Spotty pattern.
async fn run_discover_once(
    device_name: &str,
    cache_dir: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    // Stable device_id from cache_dir via FNV-1a (not DefaultHasher which
    // is version-specific and would cause duplicate Spotify devices on rebuild).
    let device_id = {
        let mut h: u64 = 14695981039346656037;
        for b in cache_dir.as_bytes() { h ^= *b as u64; h = h.wrapping_mul(1099511628211); }
        format!("{:016x}", h)
    };

    // KEYMASTER_CLIENT_ID — standard librespot client ID
    // Source: librespot-core-0.8.0/src/config.rs line 6
    const KEYMASTER_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";

    // Build Discovery: starts mDNS announcement and HTTP server for Spotify Connect
    // builder() requires T: Into<String> + 'static; use owned Strings
    let device_name_owned = device_name.to_string();
    let mut discovery = Discovery::builder(device_id, KEYMASTER_CLIENT_ID.to_string())
        .name(device_name_owned)
        .device_type(DeviceType::Speaker)
        .launch()?;

    // Wait for first connection with 15-minute timeout (RESEARCH.md Pitfall 7)
    let credentials = timeout(
        Duration::from_secs(900),
        discovery.next(),
    )
    .await
    .map_err(|_| "Discovery timeout after 15 minutes — no Spotify App connected")?
    .ok_or("Discovery stream ended without credentials")?;

    // Write credentials.json via session.connect(creds, store_credentials=true)
    // Source: run_authenticate() pattern
    let cache = Cache::new(Some(cache_dir), None::<&str>, None::<&str>, None)?;
    let session_config = SessionConfig::default();
    let session = Session::new(session_config, Some(cache));
    session.connect(credentials, true).await?;

    // Read username from credentials.json (safer than session.username() — RESEARCH Open Q1)
    // credentials.json format: {"username":"...","auth_type":1,"auth_data":"..."}
    let creds_path = std::path::Path::new(cache_dir).join("credentials.json");
    let creds_json = std::fs::read_to_string(&creds_path)?;
    let creds_data: serde_json::Value = serde_json::from_str(&creds_json)?;
    let username = creds_data["username"]
        .as_str()
        .ok_or("username field missing in credentials.json")?
        .to_string();

    Ok(username)
}

