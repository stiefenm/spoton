# Phase 73: Soloist Connect Mode — Validation Map

**Generated:** 2026-08-26
**Source:** 73-RESEARCH.md §Validation Architecture + Plan-Set 73-01 … 73-04
**Note:** Phase 73 hat keine formalen REQ-IDs in REQUIREMENTS.md — das Mapping läuft über die CONTEXT-Entscheidungen D-01 … D-08.

## Test Framework

| Property | Value |
|----------|-------|
| Framework | Perl Test::More via `prove` (CI: Perl 5.36/5.38 Matrix, `.github/workflows/perl-tests.yml`) |
| Config file | keine (Konvention: `t/NN_name.t`) |
| Quick run command | `prove -l t/31_soloist_ws.t` |
| Full suite command | `prove -l t/` |
| C harness | `make -C Plugins/SpotOn/Bin/fake-libpulse test` (Host-Build, CI nur x86_64-Leg) |

## Phase Requirements → Test Map

| Req | Behavior | Test Type | Automated Command | Test File | Created/Extended by |
|-----|----------|-----------|-------------------|-----------|---------------------|
| D-01 | Ein Daemon pro Player: `_spawnArgs` (per-player `-D`/`-C`, `-w 127.0.0.1:0`), `dataDirForClient`/`cacheDirForClient`-Pfadformen, `%helperInstances`-Registrierung | unit | `prove -l t/28_soloist_dispatch.t` | t/28_soloist_dispatch.t | 73-01 Task 2 (erweitert); Sync-Delegation 73-04 Task 2 |
| D-01 | Per-Player-Dir-/Key-/Paired-Kontrakt nach Launcher-Retirement (`isPairedForClient`, `readKey`, retired Symbols weg) | unit | `prove -l t/30_soloist_daemon.t` | t/30_soloist_daemon.t (git mv aus t/30_soloist_launcher.t) | 73-04 Task 1 |
| D-02 | Daemon-Start bei Player-Connect: `_backendPrereqState('soloist')`-Zustände, startHelper-Dispatch, `resolvePassthroughForClient`-Short-Circuit, Expiry-Gate `soloist_build_expired` | unit | `prove -l t/28_soloist_dispatch.t` | t/28_soloist_dispatch.t | 73-01 Task 2; Expiry-Gate 73-02 Task 2 |
| D-03 | Browse über den Daemon: canDirectStream→HTTP-URL, canSeek=1, `soc`-Content-Type, new()-Proxy, Modell-B-Advance | unit | `prove -l t/29_soloist_browse.t` | t/29_soloist_browse.t | 73-03 (umgeschrieben) |
| D-03 | Per-Track-Pfad vollständig entfernt: keine sol-Rules/sol-Row/Launcher-Reste (inverse Assertions, kommentar-gefiltert) | unit | `prove -l t/03_convert_conf.t t/04_types_conf.t` | t/03_convert_conf.t, t/04_types_conf.t | 73-04 Task 1 |
| D-04 | fake-libpulse HTTP-Mode: f32→S16LE-Konvertierung (inkl. Clamping), Ringpuffer drop-oldest, `writable_size`-Pacing, Header/Port-Announce | unit/smoke (C) | `make -C Plugins/SpotOn/Bin/fake-libpulse test` | fake-libpulse.c (`FAKE_LIBPULSE_TEST` main) | 73-01 Task 1 |
| D-05 | WS-Client: Message-Parsing (auth_state, error, command_result, alle Event-Typen), Command-Serialisierung, Reconnect + get_state-Resync, Repeat-Matrix, ws-down-Fallback-Kontrakt | unit | `prove -l t/31_soloist_ws.t` | t/31_soloist_ws.t | 73-01 Task 3 (Scaffold); 73-02 Task 1 (voll) |
| D-06 | Event→spottyconnect-Übersetzungstabelle: start/change/stop/volume/seek/resume, Paused+Stopped→stop-Kollaps, position_sync-Toleranz, Gating (Connect-Toggle, browseSession), Repeat-Zwei-Command-Matrix | unit | `prove -l t/32_soloist_events.t` | t/32_soloist_events.t | 73-02 Task 3 |
| D-07 | Native Connect-Registrierung + Transfer-Playback E2E (App→Soloist→LMS-Audio, Pairing per App-Tap) | manual-only (UAT) | — (`spoton-uat`-Skill) | human-check 73-01 Task 3 + Phase-UAT | Begründung: braucht echte Spotify-App + Netzwerk; nicht automatisierbar |
| D-08 | Vendored Protocol::WebSocket 0.26: `ensureWsLib()` lädt Vendor-Fallback bei fehlendem Bundle, Bundle hat Vorrang; Vendor-Tree im Zip vorhanden | unit + structural | `prove -l t/28_soloist_dispatch.t` und `test -f Plugins/SpotOn/Vendor/Protocol/WebSocket/Client.pm` | t/28_soloist_dispatch.t | 73-01 Task 2 |

**Zusatzabdeckung (kein eigenes D, aber phase-kritisch):**

| Behavior | Test | Plan |
|----------|------|------|
| Sync-Groups: Slave-Delegation, Sync-Suffix-Name, stopForSync bei Namens-Mismatch | t/28 (Sync-Cases) + t/29 (Fan-out, bestehend) | 73-04 Task 2 |
| Settings-Rendering (Strings-Vollständigkeit 11 Sprachen, Template-Params) | t/02_strings.t, t/09_settings.t | 73-04 Task 3 |
| Exit-Code-10-Eskalation strukturell (`spoton_soloist_expired`, startHelper-Gate) | Perl-Struktur-Check in 73-02 Task 2 `<verify>` | 73-02 Task 2 |
| Track-Ende/Autoplay/Queue-Echo-Empirie (RESEARCH Open Questions 1/2/4) | 73-SPIKE-NOTES.md (empirisches Protokoll, kein .t) | 73-03 Task 1 (Wave-0-Spike, PFLICHT vor Modell-B-Freeze) |

## Sampling Rate

- **Per task commit:** betroffene `t/2x`/`t/3x`-Dateien einzeln (z. B. `prove -l t/31_soloist_ws.t`); C-Änderungen zusätzlich `make -C Plugins/SpotOn/Bin/fake-libpulse test`
- **Per wave merge:** `prove -l t/`
- **Phase gate:** `prove -l t/` grün + `make test` grün + 73-SPIKE-NOTES.md vorhanden (oder explizit DEFERRED mit UAT-Flag) vor `/gsd-verify-work`; D-07-UAT via `spoton-uat`-Skill inkl. librespot-No-Regression-Switch-Back

## Wave 0 Gaps → Plan Coverage

| RESEARCH Wave-0 Gap | Geschlossen durch |
|---------------------|-------------------|
| t/31_soloist_ws.t (WS-Frame/JSON-Parsing, Reconnect-State, D-05) | 73-01 Task 3 (Scaffold) + 73-02 Task 1 (voll); @INC-Hinweis Pitfall 8 entschärft durch D-08-Vendoring (Tests können den Vendor-Tree laden) |
| t/32_soloist_events.t (Event-Mapping-Tabelle, D-06) | 73-02 Task 3 |
| fake-libpulse Host-Build-Test (Konvertierung/Ringpuffer, D-04) | 73-01 Task 1 (`make test` + CI-Step) |
| Empirischer Spike `soloist ctl trace` (Open Questions 1/2/4) | 73-03 Task 1 (verpflichtend vor Modell-B-Advance-Logik; DEFERRED-Pfad dokumentiert) |

## Manual-Only Justifications

| Item | Warum nicht automatisierbar |
|------|-----------------------------|
| D-07 Transfer-E2E | Benötigt echte Spotify-App, eingeloggten Account, LAN/mDNS und hörbares Audio — kein CI-Surrogat; abgedeckt als human-check (73-01 Task 3) + `spoton-uat` |
| Sync-Gruppen live (2 Player, ein Daemon, Suffix im Device-Picker) | Benötigt zwei reale Player + Spotify-App-Picker; human-check 73-04 Task 2 |
| Settings-Render-Matrix | Visuelle Prüfung der TT-Templates; human-check 73-04 Task 3 |
