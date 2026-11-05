# SqueezePlay - project-local build for Radio-like rig tests

## What it is

SqueezePlay is the Lua/C player software of the Logitech Squeezebox Radio
("baby"), Touch and Controller. The Radio runs the same core (`squeezeplay/`)
plus a small `squeezeplay_baby` layer; the desktop build (`squeezeplay_desktop`)
runs the identical core on Linux. We build Ralph Irving's maintained fork so the
rig can use the Radio's own stream/decode code instead of squeezelite.

This is only the build tool. Nothing is installed outside this directory.
Sources, prefix and binaries live in `build/` (git-ignored, verified with
`git check-ignore`). No sources or binaries are committed.

## Build

    tools/uat/squeezeplay/build.sh

Prints `SQUEEZEPLAY_BUILD=PASS <binary>` or `SQUEEZEPLAY_BUILD=FAIL <reason>`.
Idempotent (reuses the clone and make state). Log: `build/build.log`.
Result: `build/prefix/bin/jive` (+ `jive_alsa`, the ALSA output helper process).
Never starts the binary.

- Repo: https://github.com/ralph-irving/squeezeplay
- Pinned commit: `758bc110e16de4a61905e19d012a0ad25d97859b` (2026-09-25,
  merge of PR #59). Bump `PIN_SHA` in `build.sh` deliberately.

### Dependencies

Almost everything is bundled in the source tree and built into `build/prefix`
(SDL 1.2.15, SDL_image/ttf/gfx, freetype, libpng 1.2, jpeg, zlib, expat, Lua
5.1.5 and its modules, tolua++, libogg, FLAC, libmad, Tremor, fdk-aac).
From the system only these are needed (all already present on this machine):
gcc, make, patch, flex, bison, python3, git, pkg-config, X11 and ALSA headers
(`libx11-dev`, `libxext-dev`, `libasound2-dev`).

Adjustments the script makes inside the ignored clone (nothing upstream is
edited in git):
- gcc 15 defaults to C23, the code is 2007-2012 C: the private makefile
  (`src/Makefile.spoton`, derived from `Makefile.linux` by sed) uses
  `-std=gnu99 -fcommon` and demotes the new hard errors to warnings.
- `libreadline-dev` is not needed: Lua is built with `LUA_USE_POSIX
  LUA_USE_DLOPEN` instead of `LUA_USE_LINUX` (readline only serves the
  stand-alone `lua` interpreter).
- `scons` is not needed: tolua++ (normally an SCons build) is compiled by hand
  from the same sources.
- `automake/autoconf/libtool` are not needed: the shipped `configure` scripts are used.

## Running it later on the rig (not done yet, not part of this tool)

Rules for the rig, same as for lavender-UAT:
- Output only to the snd-aloop loopback (inaudible), never the default sink or
  PipeWire/Pulse. `rig-up.sh`
  (`.planning/phases/81-soloist-steuerungs-spikes/runners/rig-up.sh`) loads
  snd-aloop and keeps PipeWire off the card; lavender-UAT uses `hw:Loopback,0,0`.
  Use a different substream (e.g. `hw:Loopback,0,1`) or confirm that one is free.
- Point the ALSA helper at it with the environment, not at "default":
  `USEALSADEVICE=hw:Loopback,0,1` (read in `decode_alsa.c:239`). Also set
  `USEALSACAPTURE`/`USEALSAEFFECTS=null` as in `squeezeplay.sh` to avoid opening
  other devices.
- Isolated home so nothing lands in `~/.squeezeplay`:
  `HOME=<build>/home`. Set `LD_LIBRARY_PATH=<build>/prefix/lib` (rpath is also baked in).
- Fixed fake MAC: the desktop applet reads `settings.mac` of the DesktopJive
  applet (`squeezeplay_desktop/share/applets/DesktopJive/DesktopJiveMeta.lua:66-93`)
  and stores it. Set it once in `$HOME/.squeezeplay/userpath/settings/DesktopJive.lua`
  as `settings = { mac = "02:00:00:5a:11:02" }` (locally administered, not the
  02:00:00:5a:11:01 of lavender-UAT; a "00:04:20" prefix is discarded at line 66).
  NOT yet tested at runtime - verify the file format at first start.
- Server address: SqueezePlay discovers LMS by UDP broadcast (SlimDiscovery
  applet) and via the setup wizard. Pin the server explicitly and keep it away
  from the measured LMS until a run is intended. Not yet tested.
- Headless smoke: `SDL_VIDEODRIVER=dummy` (SDL 1.2 has a dummy video driver);
  SDL audio is not used for playback, the output goes through `jive_alsa`.

## Known limits versus a real Radio

Findings from the pinned source (paths relative to `build/src/squeezeplay/src/`):

| Item | Value | Where |
|---|---|---|
| Stream buffer (compressed, input side) | 3 MiB static, one constant, no per-platform override | `squeezeplay/src/audio/streambuf.c:34` (`STREAMBUF_SIZE`), used at 86, 142, 989 |
| Decode FIFO (decoded PCM, output side) | 10 s of 44.1 kHz stereo = `10*2*44100*sizeof(sample_t)` (sample_t is 32 bit, so about 3.4 MiB); 2.29 s at 192 kHz | `squeezeplay/src/audio/decode/decode_priv.h:222` (`DECODE_FIFO_SIZE`), comment 210-221 |
| Effects FIFO | 1 s mono | `decode_priv.h:225` |
| Decoder start thresholds | FLAC 25000 bytes, others 512 bytes | `squeezeplay/src/audio/decode/decode.h:42-43`, `decode.c:349` |
| ALSA ring, code default | buffer 30000 us, 3 periods | `squeezeplay/src/audio/decode/decode_alsa.c:25-26` |
| ALSA ring, Radio ("baby") | buffer 20000 us, 2 periods | `squeezeplay_baby/share/applets/SqueezeboxBaby/SqueezeboxBabyMeta.lua:37-38` |
| ALSA ring, desktop | no desktop override: code default 30000 us / 3 periods, or `USEALSABUFFERTIME`/`USEALSAPERIODCOUNT` | `decode_alsa.c:244-245,305-311`; `squeezeplay_desktop/squeezeplay.sh` |

Answer to "is the desktop buffer the same as the Radio's": the stream buffer and
the decode FIFO are compile-time constants in shared `squeezeplay/src/audio/`
code and the platform directories (`squeezeplay_baby`, `squeezeplay_desktop`)
contain no override, so the desktop build has the same 3 MiB / 10 s as this
source tree's Radio build. Only the ALSA output ring differs (Radio 20 ms / 2
periods vs desktop 30 ms / 3 periods); set `USEALSABUFFERTIME=20000` and
`USEALSAPERIODCOUNT=2` to match it. Caveat: this is the 2026 fork. The firmware
actually on a tester's Radio (Logitech's last release, 7.7.x) may have been
built from older source with different constants; that cannot be checked from
this tree. The real Radio also has a slow ARM CPU (decode/TLS timing) and
different memory pressure, which the desktop build does not reproduce.

Other differences: the HELO model/device id (desktop identifies as
"squeezeplay", device id 12; Radio as "baby", `Player.lua:106` and
`SqueezeboxBabyMeta.lua:62`), which LMS uses for capabilities, so server-side
behaviour (transcoding choice, buffer thresholds sent in `strm`) can differ;
and the LMS-chosen `strm` buffer/output thresholds apply on both. No Radio
hardware, no WiFi, no firmware-specific codecs (closed `squeezeplay_private`
WMA/AAC not built).

## Status

Build verified: `jive` and `jive_alsa` link with no unresolved libraries
(`ldd`). Not started, not connected to any server, no audio device opened.
