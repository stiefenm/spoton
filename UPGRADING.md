# Upgrading from SpotOn 3.5.x to 4.0

This page is for you if you used SpotOn 3.5.x and got SpotOn 4.0 through the LMS plugin manager. It tells you what is different, what to do right after the update, and what to do if something does not work. You do not need to have followed the forum or the beta versions.

After the update an account can be marked "Please pair this account once". Pairing it once in the Spotify app is all it needs. If no account is marked, there is nothing to do.

## What changes in 4.0

- **No browser login, no Developer App, no client ID.** SpotOn 4.0 no longer uses the Spotify Web API. The browser login is gone, you do not need a Spotify Developer App any more, and the client ID field is no longer in SpotOn Settings.
- **You pair an account in the Spotify app instead.** You press a button in SpotOn Settings and pick the device `SpotOn Authorization (...)` in your Spotify app, like connecting to a speaker. This is done once per account.
- **Your settings and accounts are taken over.** When LMS starts after the update, SpotOn checks each account once:
  - An account that already had playback credentials is taken over with all its settings. Nothing to do.
  - An account that only had the browser login cannot be used any more. It stays in the list and is marked "Please pair this account once". The SpotOn menu shows the same item.
  - A custom client ID from 3.5.x is removed without a notice, because nothing uses it any more.
- **The backend stays librespot** after the update.
- **Soloist is optional.** Soloist is a second backend that you can switch to if you want. It runs on Linux only, needs glibc 2.38 or newer (for example Debian 13 or Raspberry Pi OS Trixie) and your own Spotify Soloist API key. Windows and macOS run librespot only. The official Lyrion Docker image is based on Debian 12, so Soloist cannot run there. On a Linux system that can run Soloist, SpotOn Settings shows the hint "Soloist is available on this system"; you can ignore it.

## Right after the update

1. Restart LMS if the plugin manager asks for it.
2. Open **SpotOn Settings** (Server Settings > SpotOn).
3. Look at step **1. Pair Spotify account (once per account)**. If no account is marked "Please pair this account once", you are done.
4. For a marked account, press **Pair account**. SpotOn now announces a device named `SpotOn Authorization (...)` on your network for about 5 minutes.
5. Take a phone or computer that is in the same network as LMS and open the Spotify app there. Use the same Spotify account as the marked one.
6. Start any track. The Spotify app only lists devices while something is playing.
7. Open the devices menu in the Spotify app and pick `SpotOn Authorization (...)`.
8. Keep the settings page open. When SpotOn has received the login, the page reloads itself. The mark is gone and the account keeps its settings.
9. Repeat steps 4 to 8 for every other marked account.

If the 5 minutes ran out before you picked the device, press **Pair account** again.

**Players:** with librespot you do not have to do anything per player. Only if you switch to Soloist is each player paired once as well, in step **2. Pair player (Soloist only, once per player)**, by tapping the player in the Spotify app's devices menu.

More detail:

- [After the update from 3.5.x: pair an account again](TROUBLESHOOTING.md#after-the-update-from-35x-pair-an-account-again)
- [Pair a Spotify account](TROUBLESHOOTING.md#spotify-konto-koppeln-pair-a-spotify-account)
- [Soloist: pairing a player](TROUBLESHOOTING.md#soloist-pairing-a-player-tap-in-the-spotify-app)

## If the pairing device does not appear

If `SpotOn Authorization (...)` is not in the devices menu of your Spotify app, check these points in this order:

1. **Is a track playing?** The Spotify app only lists devices while something is playing. Start a track first, then open the devices menu.
2. **Same network?** The phone or computer and the LMS host must be in the same network. The Spotify app finds the device through mDNS (UDP port 5353). A separate VLAN, or a router or firewall that blocks mDNS, hides the device.
3. **iPhone or iPad?** The Spotify app needs the iOS permission "Local Network". Open the iOS Settings, go to Privacy & Security > Local Network and switch Spotify on. Then open the devices menu again.
4. **LMS in Docker?** In a Docker bridge network the Spotify app cannot see the device. Run the container with `--network host`, or use the `__DISCOVER__` folder.

**The `__DISCOVER__` folder** adds an account without mDNS on the LMS host. You create the login file `credentials.json` on any machine in the phone's network and hand it to LMS. It works in any network layout, so it is the way to go for Docker bridge networks and separate VLANs. The steps are in [Pairing an account without mDNS: the \_\_DISCOVER\_\_ folder](TROUBLESHOOTING.md#konto-ohne-mdns-koppeln-dockervlan-der-__discover__-ordner).

See also [If the Spotify app can't find the pairing device](TROUBLESHOOTING.md#if-the-spotify-app-cant-find-the-pairing-device).

## Getting help

- **In SpotOn Settings:** the section **Help & feedback** links to the troubleshooting guide, the problem reports, the release status and the forum thread.
- **Diagnostic report:** go to SpotOn Settings > **Diagnostics** and click **Download Diagnostic Report**. You get one text file. Personal data in it is replaced by placeholders, but read through it before you share it. Attach it when you ask for help. See [Collecting Diagnostic Data](TROUBLESHOOTING.md#collecting-diagnostic-data).
- **GitHub issue:** [open an issue](https://github.com/stiefenm/spoton/issues/new/choose) and attach the diagnostic report.
- **Forum:** the [SpotOn thread in the Lyrion forum](https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton-%E2%80%94-spotify-plugin-for-lms-alternative-to-spotty).
- **All known problems and fixes:** [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Going back to 3.5.8

Read this before you decide to go back. SpotOn 4.0 has no built-in way back, and nothing restores what the update removed.

On its first start, SpotOn 4.0 deleted these things for good:

- the browser-login tokens of every account
- a custom client ID, if you had entered one
- the stored sp_dc cookie value, if an account had one
- a Pathfinder hash, if you had entered one by hand

These things are kept:

- the account list with its settings
- the playback login of each account that has one

What this means for 3.5.8:

- 3.5.8 needs its browser login again for every account.
- If you used a custom client ID, you have to enter it again. Without one, 3.5.8 uses its built-in client ID.

The LMS plugin manager installs the release that the SpotOn repository lists. Going back therefore means installing the 3.5.8 release file by hand: [SpotOn-v3.5.8.zip](https://github.com/stiefenm/spoton/releases/download/v3.5.8/SpotOn-v3.5.8.zip).

Going back to 3.5.8 was not part of the release tests for 4.0. The release was tested as a fresh install and as an upgrade from 3.5.8, not in the other direction. If 4.0 does not work for you, please ask for help first, see "Getting help" above.
