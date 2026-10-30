[![Perl Tests](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml/badge.svg)](https://github.com/stiefenm/spoton/actions/workflows/perl-tests.yml)

# SpotOn

A Spotify plugin for Lyrion Music Server (LMS).

## Background

SpotOn builds on the foundation that [Michael Herger](https://github.com/michaelherger) laid with his [Spotty plugin](https://github.com/michaelherger/Spotty-Plugin), the original Spotify integration for LMS that served the community for years. Without Herger's pioneering work on Spotty and the broader LMS plugin ecosystem, SpotOn would not exist. Thank you, Michael.

SpotOn is not a fork or a competitor. It is a from-scratch rewrite. Browse, Search and Library run over Spotify's own client endpoints with the login of your paired account, so no Spotify Developer App and no Web API quota are involved. Where Spotty had to work around years of accumulated API changes, SpotOn could start fresh.

SpotOn plays audio through one of two backends, chosen in SpotOn Settings:

- **librespot** (the default): the open-source Spotify client, shipped with SpotOn for every supported platform.
- **Soloist**: Spotify's official client. It runs on Linux only. SpotOn downloads it from Spotify on your LMS host and never ships it (see [Terms](#terms)).

| | librespot (default) | Soloist |
|--|--------|--------|
| **Platforms** | Linux, Windows, macOS | Linux only (x86_64, aarch64, armhf), glibc 2.38 or newer |
| **Spotify quality** | Ogg Vorbis at 96/160/320 kbps | Spotify's own quality setting with the same names as in the Spotify app, up to Lossless (needs a Premium plan with lossless enabled) |
| **Stream formats to the player** | OGG passthrough, FLAC, PCM, MP3 | FLAC 16, PCM, MP3 (Auto picks FLAC 16 on FLAC-capable players) |
| **Setup** | Pair your Spotify account once | Pair your account once, enter your spak key, then pair each player once by tapping it in the Spotify app |
| **Updates** | Ships with SpotOn | Soloist builds expire after 90 days; SpotOn renews them automatically, or you place your own build in the `manual/` folder |
| **"Up Next" queue in the SpotOn menu** | Not available | Available |

| | SpotOn | Spotty |
|--|--------|--------|
| **Podcasts** | Browse, search, play, follow/unfollow shows, explicit markers, 11 languages | Browse and play shows/episodes |
| **Like / Unlike** | One-click toggle from any track menu | Not available |
| **Audio formats** | OGG, FLAC, PCM, MP3, configurable per player (see the backend table above) | PCM, FLAC, MP3, global setting |
| **Spotify Connect** | Bidirectional sync (play, pause, seek, volume, skip) | Currently disabled |
| **Made For You** | Daily Mixes, Discover Weekly, Daylist, Release Radar | Either Liked Songs or Made For You content (not both) |

## Features

- **Browse** - Search tracks, albums, artists, and playlists with search history (last 50 queries); full artist discography with albums, singles, compilations
- **Podcasts** - Browse saved shows, search for shows and episodes, play episodes, follow/unfollow shows. Episode info view links back to the parent show with lazy-loaded metadata. Explicit episodes are marked. Duration and dates are localized in 11 languages.
- **Library** - Liked Songs, Albums, Artists, Playlists, Recently Played, Top Tracks
- **Like / Unlike** - Save or remove tracks from your Liked Songs directly from any track context menu. In Material Skin, open the track's "..." menu, then "More", then "Like / Unlike". The plugin checks Spotify for the current state and shows either "Like" (to save) or "Unlike" (to remove). In Classic Skin, the same flow is available via the Track Info panel. After the action, a popup confirms "Liked!" or "Removed" and the menu navigates back automatically.
- **Streaming** - Per-player Stream Format. With librespot: OGG passthrough, FLAC, PCM or MP3, 96/160/320 kbps and volume normalization. With Soloist: FLAC 16, PCM or MP3, with Spotify's quality setting up to Lossless.
- **Spotify Connect** - Full bidirectional control: appear as a Connect device, control from any Spotify client, state syncs both ways
- **Made For You** - Daily Mixes, Discover Weekly, Daylist, Release Radar with locale-aware sorting
- **Don't Stop The Music** - Automatic queue extension with multi-artist search, diversity pool from your top tracks, and anti-bubble deduplication
- **Material Skin Integration** - Menu icons for all navigation entries, fallback artwork for grid/cover-view compatibility, and optional home-screen rows (Recently Played, Top Tracks, Made For You, Main Menu, Playlists)
- **Multi-Account** - Pair more than one Spotify account and switch between them
- **Soloist renewal** - Soloist builds expire 90 days after release. SpotOn renews them automatically 14 days before expiry, switches a player to the new build only while it is idle, and rolls back if the new build fails to start. You can also place your own build in `<cachedir>/spoton/soloist/manual/`.

## Requirements

- LMS 8.0+ (LMS 9.x recommended)
- Spotify Premium account
- **Two-step setup, guided in SpotOn Settings:** (1) pair your Spotify account once: press **Konto koppeln** (*Pair account*) and pick the `SpotOn Authorization` device in your Spotify app while a track is playing, like connecting to a speaker; (2) with the Soloist backend only, pair each player once as well by tapping it in the Spotify app's device picker. No browser login and no Spotify Developer App are needed. If the Spotify app cannot see the pairing device (Docker, VLANs), drop a `credentials.json` into the `__DISCOVER__` folder instead, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **For Soloist only:** a Linux host with glibc 2.38 or newer (for example Debian 13 or Raspberry Pi OS Trixie), and your own spak key. The spak key is Spotify's access key for Soloist; you get it with your Spotify Premium account as described in [Spotify's Soloist documentation](https://developer.spotify.com/documentation/soloist/concepts/authentication). SpotOn stores it locally and never transmits it.

### Platforms

| Platform | Backends | Tested for this release |
|----------|----------|-------------------------|
| x86_64 Linux | librespot, Soloist | Yes: fresh install and upgrade from 3.5.8 on Debian 13 with LMS 9.1.1 |
| aarch64 Linux (Raspberry Pi 4/5, 64-bit OS) | librespot, Soloist | Yes: Soloist on a Raspberry Pi with Debian 13 (Trixie) and LMS 9.1.1 |
| armhf Linux (Raspberry Pi 2/3, 32-bit OS) | librespot, Soloist | Not tested |
| i386 Linux, other arm Linux | librespot | Not tested |
| x86_64 Windows | librespot only | Yes: Browse playback on Windows 11 with LMS 9.1.1; Spotify Connect on Windows not tested |
| macOS (Universal Binary: Intel + Apple Silicon) | librespot only | No: CI compile only, not tested |

Windows and macOS run librespot only; Soloist exists for Linux only. On an older Linux (glibc below 2.38) SpotOn Settings shows no Soloist hint; if Soloist is selected there anyway, it cannot start and the SpotOn status page says why, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Use librespot on such a system. On macOS, if you download the binary manually (not via the LMS plugin manager), you may need to run `xattr -d com.apple.quarantine /path/to/spoton` in Terminal before first use.

## Installation

1. Open **LMS Settings > Plugins > Additional Repositories**
2. Add the repository URL:
   ```
   https://raw.githubusercontent.com/stiefenm/spoton/main/repo.xml
   ```
3. Click **Apply**, then find **SpotOn** in the plugin list and install it
4. Restart LMS when prompted

SpotOn starts with librespot. Pair your account in SpotOn Settings (step 1 above).

**Using Soloist:** on a Linux system that can run Soloist, SpotOn Settings shows a hint "Soloist is available on this system. To use it, get your spak key from Spotify:" with a link and a key field. Enter your spak key there and save; the page then offers the switch to Soloist. After the switch SpotOn downloads Soloist from Spotify, starts it, and asks you to pair each player once by tapping it in the Spotify app's device picker.

**Upgrading from 3.5.x:** your settings and accounts are taken over. A custom client ID from 3.5.x is removed because SpotOn no longer uses the Web API. An account whose stored login cannot be used any more is marked "Please pair this account once"; one pairing with the same Spotify account fixes it, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and solutions, including Soloist (glibc, spak key, player pairing, renewal), Docker setup, Connect audio problems, and how to collect diagnostic data.

## Known limitations

- **Sync groups:** with the Soloist backend, one very brief stutter within the first second after a group starts can occur (LMS re-aligns the members). Details and a tip for squeezelite on PulseAudio/PipeWire are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **Docker:** Soloist needs glibc 2.38 or newer. The official Lyrion Docker image is based on Debian 12 (glibc 2.36), so Soloist can't run there and SpotOn uses librespot; an image based on Debian 13 works. See [#183](https://github.com/stiefenm/spoton/issues/183).

## Terms

SpotOn's Soloist backend uses Spotify's Soloist client as delivered by Spotify. In line with the Spotify Developer Terms (section V.11), Soloist must not be modified, decompiled, disassembled or reverse engineered, and its archives or binaries must not be redistributed. SpotOn downloads Soloist from Spotify's own download page (https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates) on your LMS host and never ships it. Spotify is a third-party beneficiary of these terms.

## License

MIT - see [LICENSE](LICENSE)
