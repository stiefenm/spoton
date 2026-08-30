# Debug: Soloist Browse Audio Stutter + FLAC24 Transcode Architecture

## Symptom

Soloist Browse-Playback (Album abspielen über SpotOn-Menü) stottert:
- Audio startet erst nach mehreren Sekunden
- Stutter wird progressiv schlimmer
- ~5 Sekunden Stille
- Danach kurz flüssiger, dann wiederholt sich das Muster
- Identisches Verhalten ob Direct-Stream PCM oder sox→FLAC Transcode

## Bewiesene Fakten (aus UAT-Session 2026-08-30)

1. **Stutter ist NICHT der Transcode:** Identisches Muster mit `soc pcm * *` (Direct-Stream, kein sox) und `soc flc * *` (sox Pipeline). sox ist nicht der Engpass.

2. **Stutter ist im Ring-Buffer/HTTP-Layer:** `canDirectStream` liefert den `/stream`-URL direkt an squeezelite (kein `new()`, kein Transcode), Stutter bleibt.

3. **Pre-Phase-76 Problem:** Soloist Browse-Playback wurde NIE live getestet. Phase 73 Windows 1-4 alle `PRESENT_BEHAVIOR_UNVERIFIED`. Der S32LE-Umbau (Phase 76-01) hat das Problem nicht eingeführt, nur erstmals exponiert.

4. **Connect-Playback funktioniert:** Der 8s-Reconnect-Gap (Window 5) wurde GEFIXT. Connect-Skips messen sub-second. Das Stutter betrifft nur Browse.

5. **Zweites Problem (FLAC24 Transcode):** Die `soc flc * *` convert-Regel kollidiert mit LMS Prefetch — LMS wählt `soc→flc` weil squeezelite `flc` vor `pcm` meldet → jeder Prefetch-Track öffnet eine neue `/stream`-Verbindung via `new()` → Daemon-Takeover. Braucht Architektur-Lösung.

## Root-Cause-Hypothesen

### A) Ring-Buffer Rate-Mismatch
- Ring: `RING_BYTES_PER_SEC = 44100 * 4 * 2 = 352800 B/s` (S32LE)
- HTTP-Thread pollt alle 50ms, Chunk-Größe 16384
- Pro Tick: 352800 * 0.05 = 17640 Bytes rein, 16384 Bytes raus → 1.2 KB/Tick Defizit?
- Ring-Kapazität: 20s (7 MB) — Defizit akkumuliert über Minuten bis Overflow → Drop-Oldest → Lücke

### B) HTTP Backpressure
- `_http_write_all()` hat 2s poll-Timeout pro Chunk
- Wenn squeezelite langsam liest (Player-Buffer voll), backpressure → Ring füllt sich
- Periodisches Entleeren wenn squeezelite-Buffer Platz hat → Burst → kurz flüssig → wieder voll

### C) Soloist Decoder Timing
- Soloist schreibt Float32 via `pa_stream_write()` in Bursts, nicht gleichmäßig
- Ring-Füllstand schwankt → HTTP-Thread hat mal Daten, mal nicht → Stutter

### D) squeezelite Buffer-Underrun
- squeezelite-pulseaudio → PulseAudio → ALSA → Hardware
- Wenn der HTTP-Stream ungleichmäßig liefert → squeezelite-Buffer leert → Underrun

## Dateien zum Lesen

- `Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c`
  - `_convert_and_push()` §484-530: S32LE Konversion
  - `_http_thread_fn()` §647-810: HTTP-Serving, Ring-Drain, Chunk-Größe
  - `_ring_push()` / `_ring_pop_timed()`: Ring-Buffer-Mechanik
  - Ring-Konstanten §316-324: RING_BYTES_PER_SEC, RING_CAPACITY
  - 76-07 Instrumentierung: t0-t4 Timestamps (SPOTON_FAKEPULSE_DEBUG)
- `Plugins/SpotOn/ProtocolHandler.pm`
  - `canDirectStream()` §213-275: Direct-Stream URL-Rückgabe
  - `new()` §532-639: Proxy-Substitution (der Fix der alle Soloist-Browse durch new() routed)
  - `getNextTrack()` §640-815: startBrowseTrack + Prefetch-Problem
- `Plugins/SpotOn/Unified/SoloistWS.pm`
  - `_onBrowseTrackChanged()` §662-737: Track-Advance, Seeding, Pitfall 4
  - `_maybeSeedBrowseQueue()` §885-913: Gapless-Seeding ~15s vor Track-Ende

## Debug-Ansatz

1. **Ring-Buffer-Instrumentierung:** SPOTON_FAKEPULSE_DEBUG aktivieren, Ring-Füllstand über Zeit loggen (fill/capacity pro Tick). Zeigt ob Overflow, Underrun, oder Burst-Pattern.
2. **HTTP-Timing:** Messen wie lange `_http_write_all()` pro Chunk braucht. Backpressure von squeezelite?
3. **squeezelite Debug-Log:** `-d output=debug` zeigt Buffer-Füllstand und Underruns.
4. **Vergleich Connect vs Browse:** Connect-Playback stottert NICHT — was macht Connect anders? (Gleicher /stream-Endpoint, gleicher Ring, gleicher HTTP-Thread.)

## Zweites Thema: FLAC24 Transcode Architektur

Die `soc flc * *` Regel ist deaktiviert. Lösungsansätze:
- **Option A:** Eigenen Content-Type für Soloist-FLAC (z.B. `sof`), formatOverride gibt `sof` statt `soc` zurück wenn resolved=flac → `canDirectStream` für `soc` bleibt unberührt
- **Option B:** In fake-libpulse Multi-Client-Support: alte Verbindung aktiv halten bis Track endet, neue Verbindung erst danach bedienen
- **Option C:** Prefetch-Deferral in getNextTrack (wurde versucht, aber Pitfall-4-Loop-Problem und browseCurrentUri-Timing machten es instabil — braucht saubereres State-Management)

## Aktueller Code-Stand

- Commit `1cf4272`: soc flc Regel deaktiviert, new() URL-Substitution-Fix aktiv
- `streamFormat=pcm` nutzt canDirectStream (Direct-Stream, kein Transcode)
- Stutter tritt auch im Direct-Stream-Pfad auf
- Alle Phase-76-Execution-Commits (Wave 1-4) + Code-Review-Fixes sind gemergt
