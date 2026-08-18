# Troubleshooting

Common issues and how to resolve them. Always update to the [latest release](https://github.com/stiefenm/spoton/releases/latest) before troubleshooting — many issues are fixed in newer versions.

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

### PKCE authorization fails or never completes

**Symptoms:** Clicking "Connect to Spotify" in SpotOn Settings opens a popup that closes without finishing, or the Settings page never picks up the new account after you approve access on Spotify's authorization page.

**Common causes and fixes:**
- **Popup blocked** — browsers block `window.open()` popups unless they're triggered directly by a click. Allow pop-ups for your LMS host and try again (SpotOn shows a reminder about this next to the auth button).
- **No Client ID configured** — SpotOn ships a bundled Client ID that works out of the box. If you prefer your own, enter it in SpotOn Settings before starting the auth flow; the setup wizard walks you through creating one at [developer.spotify.com](https://developer.spotify.com/dashboard).
- **Redirect doesn't reach LMS** — SpotOn bounces the browser back to your LMS server via a GitHub Pages relay (`https://stiefenm.github.io/spoton/auth/`). If your phone/browser can't reach your LMS host directly (different network, VPN, restrictive firewall), the relay page falls back to a "copy this URL" box — paste it into the manual auth field on the SpotOn Settings page to complete the flow.
- **Redirect URI mismatch** — the Client ID's app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) must have `https://stiefenm.github.io/spoton/auth/` registered as an allowed Redirect URI, exactly as shown by the setup wizard.

### Re-authentication needed / token refresh fails

**Symptoms:** The Auth Health Dashboard (Status page) shows a warning for an account, Browse/Search return errors, or Connect stops working, with a token or credential error in the daemon log.

**Cause:** SpotOn refreshes your PKCE access token automatically in the background using the stored refresh token. If that refresh token becomes invalid (access revoked in your Spotify account, a corrupted token file, or an old v2.x account that never migrated), SpotOn can no longer refresh it and flags the account for re-authentication.

**Solution:**
1. Open **SpotOn Settings** and check the Auth Health Dashboard (also shown on the Status page) for the affected account — it shows Web API Token and Playback Credentials status separately
2. If the **Web API Token** shows "needs re-authentication," complete the PKCE flow again via "Connect Spotify Account"
3. If **Playback Credentials** are missing, run "Authorize Playback" — select SpotOn in the Spotify app to pair
4. If the account still fails after both steps, clear its cache and start fresh:

```bash
# 1. Stop LMS

# 2. Remove the account's cache directory (find the account ID hash in
#    SpotOn Settings, or remove all account directories to reset everything):
#    Linux (typical path — adjust for your setup):
rm -rf /var/lib/squeezeboxserver/cache/spoton/<accountId>/

#    Docker (typical path):
rm -rf /config/cache/spoton/<accountId>/

# 3. Start LMS, then re-add the account via SpotOn Settings
```

4. If the issue persists, collect a diagnostic bundle and open an issue.

### Browse/Search return HTTP 400 or empty results

**Symptoms:** Search returns no results, playlists show "No results", or the Status page shows `HTTP 400 for search` / `HTTP 400 for artists/.../albums`. The Auth Health Dashboard shows "Valid" for PKCE.

**Likely cause:** Your Spotify Developer App enforces stricter API limits than expected. Spotify's Development Mode caps vary per app — some accept `limit=50`, others reject anything above `limit=10` with HTTP 400.

**Solutions:**
1. **Update to v3.1.0 or later** — SpotOn now auto-detects your app's enforced limits across 5 endpoint classes on startup and adapts all API calls accordingly. Check the Status page under "API Limits" to see the detected values. If your app has severe restrictions, you can also remove your Client ID from Settings to use the bundled fallback (see below).
2. **Check User Management** — in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), open your app's **Settings → User Management** and make sure your own Spotify account is on the allowlist. Development Mode apps may restrict API access to listed users only. After adding yourself, re-authenticate in SpotOn Settings.
3. **Check Redirect URI** — ensure `https://stiefenm.github.io/spoton/auth/` is listed as a Redirect URI in your app settings (the setup wizard shows this).

If the Status page shows `API Limits: Search 10 | Library 10 | Playlists 20` (or similarly low values), your app has restricted limits — SpotOn will still work, just with smaller page sizes.

### Frequent rate limiting (HTTP 429)

**Symptoms:** OPML menus show "Spotify requests throttled -- please wait", the Status page shows a nonzero 429 count, or playback/browsing is intermittently interrupted.

**Cause:** By default SpotOn uses a bundled Client ID (`d420a117...`) borrowed from the open-source ncspot project. This ID is shared across all SpotOn installations and all ncspot users worldwide. Under peak usage across that shared population, the aggregate API quota can be exhausted, triggering Spotify's 429 rate limiter — even if your own individual usage is light. A/B testing (same account, same library, identical request pattern) confirmed the bundled ID produces 429s under load where a private Client ID does not.

**Solutions:**

1. **Recommended: Create your own Spotify Developer App.** Go to the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), create an app, and enter its Client ID in SpotOn Settings. Your own app has a private rate-limit bucket that is not shared with anyone else. The setup wizard in SpotOn Settings walks through the required steps (Redirect URI, Client ID entry).
2. **If 429s are intermittent and brief**, SpotOn automatically backs off and retries — waiting a few seconds usually resolves it without any action needed.

**Note:** Recent versions of SpotOn skip the startup API-limit probe when using the bundled Client ID (the limits are known constants), saving 8 requests from the shared quota on every LMS restart.

### "Made For You" playlists missing or empty

**Symptoms:** The "Made For You" section under SpotOn > Home is empty or doesn't appear. Daily Mixes, Discover Weekly, and other algorithmic playlists are not shown.

**Context:** Spotify blocks access to algorithmic playlists (`37i9...` IDs) for Development Mode apps. SpotOn uses a separate "Pathfinder" pathway with your browser's `sp_dc` cookie to access these playlists. This is best-effort — it depends on two values that Spotify rotates periodically.

**Setup:**

1. **sp_dc cookie** — Open [open.spotify.com](https://open.spotify.com) in your browser and log in. Open Developer Tools (F12) → Application → Cookies → `open.spotify.com` → find `sp_dc`. Copy the full value and paste it into SpotOn Settings under "Made For You Setup."

2. **Pathfinder Query Hash** — This is the hardest part. The hash identifies a specific Spotify web player GraphQL query. To capture it:
   - Open Developer Tools (F12) → Network tab
   - Filter for `pathfinder`
   - **Log out** of open.spotify.com, then **log back in** — the `home` query fires during the login redirect and is easy to miss during normal browsing
   - Find the request whose Payload contains `operationName: "home"`
   - In the Payload, copy `extensions.persistedQuery.sha256Hash`
   - Paste it into SpotOn Settings under "Pathfinder Query Hash"

**If you can't find the `home` query:** Spotify occasionally renames the operation (e.g. `homeSection`). If you see a different name, try its hash — but it may not return the right data format. This is a known fragility of the Pathfinder approach.

**Note:** The hash and sp_dc cookie can expire or rotate when Spotify updates their web player. If Made For You stops working after it previously worked, repeat the capture process.

### Tracks skip or fail with "404" in logs (CDN errors)

**Symptoms:** Tracks skip to the next song after a few seconds, or playback fails entirely. The LMS log shows `Browse daemon 404` or `attempts exhausted, skipping to next track`.

**Cause:** Spotify occasionally returns bad CDN endpoints that respond with HTTP 404. This is a server-side issue on Spotify's end.

**Solutions:**
- **Update to v2.1.6 or later** — includes an upgraded librespot with CDN fallback (automatically tries the next CDN URL on 404) plus SpotOn's own 404 retry layer (3 attempts with 2s delay)
- If errors persist after updating, you can block specific bad CDN hosts via `/etc/hosts` — see the [forum thread](https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton) for known problematic hosts

## mDNS / ZeroConf and Playback Authorization

SpotOn uses mDNS (ZeroConf) for two purposes:

1. **Authorize Playback (setup step 2)** — after connecting your Spotify account via browser login, you need to authorize playback by selecting SpotOn's pairing device in the Spotify app. This uses mDNS so the Spotify app can discover the pairing device on your local network. This is a one-time step per account.

2. **Guest Spotify Connect discovery** — lets someone else on your LAN see your LMS player in their Spotify app's device list and hand off playback to it, without needing a SpotOn account of their own.

### If the Spotify app can't find the pairing device

This happens when mDNS doesn't work between your phone/computer and the LMS host:
- **Docker** — use `--network host`, or use the **browser fallback** (nested inside the Authorize Playback section in SpotOn Settings)
- **Different VLANs/subnets** — use the browser fallback
- **Firewall** blocks mDNS (UDP port 5353) — open it, or use the browser fallback

The browser fallback authorizes playback without mDNS by opening a browser window on the LMS host. It works in any network topology.

**Note:** Step 1 (Connect Spotify Account) never needs mDNS — it runs entirely through the browser, regardless of network setup.

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
