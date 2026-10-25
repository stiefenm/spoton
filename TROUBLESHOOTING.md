# Troubleshooting

Common issues and how to resolve them. Always update to the [latest release](https://github.com/stiefenm/spoton/releases/latest) before troubleshooting — many issues are fixed in newer versions.

## Soloist build expired or renewal failed

Soloist builds from Spotify's CDN expire 90 days after release, so SpotOn keeps track of the remaining lifetime and renews automatically. SpotOn Settings (backend = Soloist) always shows the current state:

- **Expiring soon (14 days or less):** an informational line names the version and days remaining; a renewal starts automatically and retries once a day until it succeeds. A build that exits with error code 10 (already expired) triggers an immediate renewal instead of waiting for the next daily check.
- **Renewing:** the settings page shows the in-progress phase (downloading, extracting, testing, switching in).
- **Renewal failed:** the reason is shown, and SpotOn retries the next day. The switch to a freshly renewed build only happens while the player is idle — never during playback — so it may take a little longer to reach a player that never stops.
- **Rolled back:** if a newly switched-in build fails to start, or crashes three times within 30 minutes of the switch, SpotOn automatically restores the previous (still valid) build and shows the versions and the reason. **Blind spot:** a build that runs but produces silent/broken audio is not detected by this check — always confirm playback after a renewal.
- **Placed binary active/ignored:** see below.

You can also click **Renew Soloist now** at any time to trigger the same pipeline manually (useful right after Spotify publishes a new build, or to verify the renewal path works at all).

### Placing your own Soloist build

If automatic renewal from Spotify's CDN fails, or you prefer to fetch the build yourself, download the archive from the link on the settings page and place either the `.tar.gz` archive or the extracted `soloist` binary into the folder named there: `<cachedir>/spoton/soloist/manual/`. SpotOn checks the folder about once a minute, runs the same version check and a short test start the automatic path uses, and switches to it (again only while the player is idle).

While a valid placed build is present, automatic renewal from the CDN pauses entirely — the settings page states this and shows the placed build's own version and remaining lifetime. Placing an invalid file (wrong version, fails its test start), or letting the placed build itself expire, makes SpotOn ignore it and resume the automatic CDN renewal on its own; the reason is always shown. To go back to automatic renewal at any time, simply empty the manual folder.

Soloist is Spotify's software: don't modify, decompile, or reverse engineer it, and don't redistribute the archive or binary (Spotify Developer Terms V.11) — the link on the settings page always points to Spotify's own download page.

## Soloist does not start: glibc too old

**Symptoms:** with the Soloist backend selected, Soloist does not start, and the SpotOn status page (and the diagnostic report) shows:

> Soloist cannot run on this system: glibc 2.36 found, Soloist needs glibc 2.38 or newer (Raspberry Pi OS Trixie / Debian 13 or newer). Update the system or select the librespot backend.

The version after "glibc" is the one found on your system. On such a system SpotOn Settings also shows no "Soloist is available on this system" hint.

**Fix:** update the operating system to a release with glibc 2.38 or newer (for example Debian 13 or Raspberry Pi OS Trixie), or select **librespot** in SpotOn Settings. librespot has no glibc floor of this kind. Docker images based on Debian 12 (bookworm, glibc 2.36) are too old for Soloist.

Soloist runs on Linux only. On Windows and macOS SpotOn always uses librespot, whatever is selected.

## Key refused: spak key not saved, or Spotify refuses audio keys

**The spak key was not saved.** SpotOn checks the key before it stores it. If it contains characters a spak key cannot have, or is too short, the settings page says:

> The spak-key contains invalid characters or is too short - it was not saved.

Copy the key again from Spotify (without spaces or line breaks) and save once more. As long as no key is stored, the Soloist fields say "No spak-key configured - Soloist cannot start without one.". Get the key with your Spotify Premium account as described in [Spotify's Soloist documentation](https://developer.spotify.com/documentation/soloist/concepts/authentication).

**Spotify refuses audio keys (librespot).** For some accounts Spotify refuses the audio keys librespot asks for. Playback then cannot work with librespot for that account, and the SpotOn status page shows:

> Spotify refuses audio keys for account abcd**** with the librespot backend (AesKeyError 0x0001) - playback cannot work for this account. Select the Soloist backend in the SpotOn settings.

The way out is the Soloist backend (Linux with glibc 2.38 or newer, own spak key). Rapid skipping can also cause a short throttling warning ("Spotify is throttling audio keys ..."); that one recovers within a few minutes by itself.

## Soloist: pairing a player (tap in the Spotify app)

With the Soloist backend, each player is paired once, in addition to the account pairing (step 1). SpotOn Settings says:

> Enable the Soloist backend and wait for the daemon to start, then select this player once in your Spotify app's device picker. Pairing is per player and fully automatic - no command line needed; credentials are stored locally.

1. Switch the backend to **Soloist** and save. SpotOn downloads Soloist from Spotify and starts one daemon per player.
2. In the Spotify app on a phone or computer **in the same network**, open the devices menu and tap the player once.
3. The player's line in SpotOn Settings then reads "Paired with Spotify".

In a sync group only the group's master runs a Soloist daemon; pair and select the master. If the player is not listed in the Spotify app, see [mDNS / ZeroConf and Pairing](#mdns--zeroconf-and-pairing).

## Collecting Diagnostic Data

SpotOn has a built-in diagnostic system that collects system info, daemon logs, and LMS server log entries into a single downloadable file.

1. Go to **SpotOn Settings** (Server Settings > SpotOn)
2. Scroll to **Diagnostics** and enable the checkbox
3. Click **Save**
4. Reproduce the issue
5. Return to SpotOn Settings and click **Download Diagnostic Report**
6. Attach the `.txt` file to your GitHub issue

The bundle includes: LMS version, OS, Perl version, SpotOn version, player list, active settings, Connect and unified daemon logs, browse error log, and SpotOn-related entries from the LMS server log.

## Known Issues

### Daemon doesn't start (Docker)

**Symptoms:** Log shows `SpotOn daemon did not announce HTTP stream port (timeout) - aborting` repeatedly, followed by `crashed 3 times within less than 5 minutes - disabling discovery for 30 min`.

**Cause:** Docker networking can prevent the daemon from reaching LMS or announcing itself via mDNS.

**Solutions:**
- Make sure you are running the latest SpotOn version
- Use `--network host` in your Docker run command, or ensure the container can reach the LMS host IP
- Verify the SpotOn binary runs: exec into the container and run `/path/to/spoton --check` — you should see `ok spoton vX.Y.Z`

If the issue persists, collect a diagnostic bundle and include your Docker setup (docker-compose.yml or run command) in the issue.

### OGG playback issues on some players

**Symptoms:** Tracks skip early, stutter, or fail to play when streaming format is set to "OGG" or "Auto".

**Cause:** Spotify's OGG Vorbis stream contains non-standard metadata headers that some players handle poorly. Hardware players (Squeezebox Radio, Touch) cannot decode OGG natively — LMS must transcode on the fly, which can add latency and cause buffer issues.

**Solutions:**
- Go to **SpotOn Player Settings** and change **Streaming Format** to **"PCM"** or **"FLAC"** — these are universally compatible
- If you experience slow track changes on hardware players (10-20s delay), this is typically caused by the player's audio buffer draining. PCM/FLAC reduces this significantly
- Collect a diagnostic bundle during the issue and open a ticket

### Sync groups: one short stutter at the start, or constant stutter on a desktop squeezelite

**Symptoms:** In a sync group, one very brief stutter within the first second after the group starts.

**Cause (known limitation):** LMS re-aligns the group members shortly after a start; with the Soloist backend this can cause a single short hiccup on one member. In our last measurement, skips and title changes inside the group were clean.

**If a squeezelite on PulseAudio/PipeWire stutters in groups:** such a player gets PipeWire's 2 s default buffer, which makes LMS skip it by about 2 s after each start. Use the ALSA build of squeezelite (for example on HiFiBerry hardware), or set `PULSE_LATENCY_MSEC=100` in the player's service environment.

### Spotify-Konto koppeln (pair a Spotify account)

**Symptoms:** SpotOn Settings shows no account, an account is marked "Bitte Konto einmal koppeln" / "Please pair this account once", or the Spotify app never lists the pairing device.

**How pairing works:** open **SpotOn Settings**, step **1. Spotify-Konto koppeln (einmal pro Konto)**, and press **Konto koppeln** (*Pair account*). SpotOn announces a device named `SpotOn Authorization (<your library name>)` on your network for about **5 minutes**; the button shows a countdown and a waiting text. In the Spotify app on a phone or computer **in the same network**:

1. **Play any track first** — the Spotify app only lists devices while something is playing.
2. Open the devices menu and pick `SpotOn Authorization (...)`.
3. Keep the settings page open. When SpotOn has received the login, the page reloads itself and step 1 shows a check mark.

One pairing creates the account **and** its playback credentials; there is no separate browser login and no Developer App. The account is whichever Spotify account the app is logged in with: a different user adds a second account, the same user refreshes the existing one. With the **Soloist** backend, step **2. Player koppeln (nur Soloist, einmal pro Player)** additionally pairs each player once, because Soloist exports no credentials — the page shows one line why there are two steps.

**Common causes and fixes:**
- **The device is not listed** — the phone is not in the same network or VLAN as the LMS host, the router/firewall blocks mDNS (UDP port 5353), or LMS runs in a Docker bridge network. Use `--network host`, or skip mDNS entirely with the `__DISCOVER__` folder (next section).
- **"Pairing failed" or the window ran out** — nobody picked the device within 5 minutes. Press **Konto koppeln** again. A second press right after a successful pairing is answered with "the account was just paired"; reload the page.
- **The wrong account appeared** — pairing takes the account the Spotify app is currently logged in with. Remove it with **Remove** in the account list and pair again after switching accounts in the app.

**LAN guests:** while the pairing window is open, anybody on your network can choose the device in their own Spotify app and add *their* account to your SpotOn. Press **Cancel** as soon as you are done, and remove accounts you do not recognise in the account list.

**Accounts from an older SpotOn:** SpotOn migrates existing accounts once when LMS starts. An account whose stored login is unusable is kept and marked "Bitte Konto einmal koppeln"; one pairing with the same Spotify account fixes it and keeps the account's settings.

**If an account still fails after pairing again**, clear its cache and start fresh:

```bash
# 1. Stop LMS

# 2. Remove the account's cache directory (find the account ID hash in
#    SpotOn Settings, or remove all account directories to reset everything):
#    Linux (typical path — adjust for your setup):
rm -rf /var/lib/squeezeboxserver/cache/spoton/<accountId>/

#    Docker (typical path):
rm -rf /config/cache/spoton/<accountId>/

# 3. Start LMS, then pair the account again in SpotOn Settings
```

If the issue persists, collect a diagnostic bundle and open an issue.

### After the update from 3.5.x: pair an account again

SpotOn 4.0 no longer uses the Spotify Web API, its browser login or a Developer App. When LMS starts after the update, SpotOn migrates each account once:

- **An account that already had playback credentials** (paired in the Spotify app, or authorized in 3.5.x) is taken over silently with all its settings. Nothing to do.
- **An account that only had the browser login** cannot be used any more. It stays in the list and is marked "Please pair this account once" (German: "Bitte Konto einmal koppeln"); the SpotOn menu shows the same item.
- **A custom client ID** entered in 3.5.x is removed without a notice, because nothing uses it any more. Its old login tokens are deleted as well.

To fix a marked account: open **SpotOn Settings**, step **1**, press **Konto koppeln** (*Pair account*) and pick `SpotOn Authorization (...)` in the Spotify app while a track is playing, with the **same** Spotify account. The account keeps its settings, and the mark disappears after the page reloads. If the Spotify app cannot see the device, use the `__DISCOVER__` folder (next section).

The backend stays librespot after the update. On a Linux system that can run Soloist, SpotOn Settings additionally shows the "Soloist is available on this system" hint; you can ignore it.

### Konto ohne mDNS koppeln (Docker/VLAN): der __DISCOVER__-Ordner

Use this when the Spotify app cannot see the pairing device (Docker bridge network, separate VLANs, firewalled mDNS, pCP). You produce the login file on **any machine in the phone's network** and hand it to LMS.

**Step 1:** Download the SpotOn binary for that machine's platform from the [latest release](https://github.com/stiefenm/spoton/releases/latest).

**Step 2:** Run the pairing helper there:

```bash
spoton -n "SpotOn Setup" --cache /tmp/spoton-auth --discover-once
```

**Step 3:** In the Spotify app (same network as that machine), **play a track**, open the devices menu and pick **SpotOn Setup**. The helper writes `/tmp/spoton-auth/credentials.json` and exits.

**Step 4:** Copy that file to `<cachedir>/spoton/__DISCOVER__/credentials.json` on the LMS host **while LMS runs**:

```bash
# Linux (typical path — adjust if your cache directory differs)
sudo -u squeezeboxserver mkdir -p /var/lib/squeezeboxserver/cache/spoton/__DISCOVER__
sudo cp /tmp/spoton-auth/credentials.json /var/lib/squeezeboxserver/cache/spoton/__DISCOVER__/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/cache/spoton/__DISCOVER__/
```

On Windows the cache directory is typically `C:\ProgramData\Lyrion\Cache\spoton\`.

**Step 5:** Open **SpotOn Settings**. The page load takes the file: SpotOn checks it, creates the account, installs its credentials and removes the file and the folder. The account appears in the list and a line "Konto aus dem Ordner __DISCOVER__ übernommen" confirms it. A file that is dropped while LMS is stopped is imported at the next LMS start.

A file SpotOn cannot use (not valid JSON, not a SpotOn `credentials.json`, larger than 64 KB, or a symbolic link) is **left in place** and the settings page says so; the LMS log carries a `Credentials:` warning with the reason. Fix or replace the file and reload the page.

**Docker / Kubernetes notes:**
- The cache directory (and with it `__DISCOVER__`) must be a **writable volume** — never a ConfigMap, a secret mount or any other read-only mount. SpotOn moves the file out of the folder during the import.
- Do not place `credentials.json` directly in a hash-named account directory (e.g. `e20xxxxx/`). SpotOn only learns about accounts through the import or a pairing; a file placed by hand is not registered.
- If you created hash directories by hand earlier, or deleted an account in the list, remove the **stale 8-hex account directories** under `<cachedir>/spoton/` before importing.
- Pairing started from inside a container may announce an address the phone cannot reach (the helper then runs without knowing the LMS address). That is exactly the case this folder is for.

### SpotOn no longer uses the Web API

Older SpotOn versions needed a Spotify Developer App and a browser login, and showed symptoms such as "Browse/Search return HTTP 400 or empty results" or frequent rate limiting (HTTP 429) tied to that app's quota. SpotOn no longer does: browse and search run over Spotify's own client endpoints (spclient and Pathfinder) with the **account's own login** from the pairing above, rate limits (429) are absorbed by SpotOn's own request limits and retries, and **no Developer App is needed or used**. There is nothing to configure for it. If Browse or Search return errors, check that the account in SpotOn Settings shows a check mark at step 1 (pair it again if not), then collect a diagnostic bundle.

### "Made For You" playlists missing or empty

**Symptoms:** The "Made For You" section under SpotOn > Home is empty, shows only a single line of text, or shows fewer mixes than the Spotify app. Daily Mixes, Discover Weekly, and other algorithmic playlists are not all shown.

**Context:** Made for You needs **no setup**: there is nothing to copy from your browser and nothing to enter in SpotOn Settings. SpotOn reads the list from Spotify's own home page with the account's pairing login (step 1 in SpotOn Settings). It is best-effort — Spotify can change that page without notice, and SpotOn then says so in the menu instead of showing an empty list silently.

**What the visible lines mean:**

- **"Spotify home is unreachable right now: showing your saved mixes only. Details on the SpotOn status page."** (`MFY_FALLBACK`) — a degraded state. Spotify's home page did not answer as expected, so SpotOn lists only the mixes it finds in your own library (the saved `Daily Mix`, `Discover Weekly`, ... playlists). Nothing is broken on your side; the full list returns by itself once the home page answers again.
- **"Made for You is unreachable right now. Details on the SpotOn status page."** (`MFY_HASH_BROKEN`) — neither the home page nor your library yielded a mix. Check that the account shows a check mark at step 1 in SpotOn Settings (pair it again if not), then open the SpotOn status page: its Made for You card shows whether the home page answered, which operation is missing, and whether the saved-mixes list is active.

**If it stays that way:** wait a few minutes and open the section again; if it persists for a day, collect a diagnostic bundle and report it. A mix you never saved or followed cannot appear in the degraded list, so follow it once in the Spotify app.

### Tracks skip or fail with "404" in logs (CDN errors)

**Symptoms:** Tracks skip to the next song after a few seconds, or playback fails entirely. The LMS log shows `Browse daemon 404` or `attempts exhausted, skipping to next track`.

**Cause:** Spotify occasionally returns bad CDN endpoints that respond with HTTP 404. This is a server-side issue on Spotify's end.

**Solutions:**
- **Update to v2.1.6 or later** — includes an upgraded librespot with CDN fallback (automatically tries the next CDN URL on 404) plus SpotOn's own 404 retry layer (3 attempts with 2s delay)
- If errors persist after updating, you can block specific bad CDN hosts via `/etc/hosts` — see the [forum thread](https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton) for known problematic hosts

## mDNS / ZeroConf and Pairing

SpotOn uses mDNS (ZeroConf) for two purposes:

1. **Pairing an account (setup step 1)** — you press **Konto koppeln** in SpotOn Settings and pick SpotOn's pairing device in the Spotify app. This uses mDNS so the Spotify app can discover the pairing device on your local network. It is a one-time step per account; see "Spotify-Konto koppeln" above.

2. **Guest Spotify Connect discovery** — lets someone else on your LAN see your LMS player in their Spotify app's device list and hand off playback to it, without needing a SpotOn account of their own.

### If the Spotify app can't find the pairing device

This happens when mDNS doesn't work between your phone/computer and the LMS host:
- **Docker** — use `--network host`, or use the `__DISCOVER__` folder (see above)
- **Different VLANs/subnets** — use the `__DISCOVER__` folder
- **Firewall** blocks mDNS (UDP port 5353) — open it, or use the `__DISCOVER__` folder

The `__DISCOVER__` folder adds an account without mDNS on the LMS host: you create the login file on any machine in the phone's network and copy it over. It works in any network topology.

## Windows: Daemon Timeout or "Binary not found"

Make sure you are running the latest SpotOn version. Earlier versions had Windows-specific issues with daemon startup.

Update via: LMS Settings → Plugins → Check for Updates → Restart LMS.

### Windows Defender Firewall

You may need to add the SpotOn binary to the Windows Defender Firewall allowed apps list. The binary is located at:

```
C:\ProgramData\Lyrion\Cache\InstalledPlugins\Plugins\SpotOn\Bin\x86_64-win64\spoton.exe
```

Go to: Windows Security → Firewall & network protection → Allow an app through firewall → Add the path above.

If the issue persists after updating, collect a diagnostic bundle and open a [GitHub issue](https://github.com/stiefenm/spoton/issues).
