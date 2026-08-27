---
status: partial
phase: 73-soloist-connect-mode
source: [73-VERIFICATION.md]
started: 2026-08-26T20:15:00Z
updated: 2026-08-27T08:50:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Connect Transfer via App-Tap Pairing (D-07)
expected: Device erscheint unter LMS-Name im Spotify Device Picker; Antippen startet LMS-Playback via /stream ohne Web API Call
result: pass

### 2. Bidirektionale Kontroll-Loop + WS-Down-Fallback (D-06/D-15)
expected: LMS-side Pause/Skip/Seek/Volume werden in der Spotify App innerhalb ~1s gespiegelt; bei WS-Down greifen die Web API Fallbacks
result: issue
reported: "LMS→Spotify: Pause/Resume/Volume/Skip OK. Seek nicht. Spotify→LMS: Pause OK, Resume mit +5s Delay und startet bei Position 0 statt Pausenposition. Skip Next lange Verzögerung, Spotify Progress bleibt bei 0/1s hängen."
severity: major

### 3. Build-Expiry Escalation (Pitfall 7)
expected: DaemonManager loggt Expiry-Meldung, setzt spoton_soloist_expired, Daemon wird vom Watchdog nie wieder gestartet
result: blocked
blocked_by: prior-phase
reason: Phase 74 Lifetime-Patch kann Datum auf Vergangenheit setzen → Exit-Code 10 testbar. Perl-Logik unit-getestet, E2E in Phase 74 UAT.

### 4. Wave-0 Spike — Track-End/Autoplay/Queue-Echo (D-03)
expected: Bestätigt oder korrigiert die RESEARCH-Default-Annahmen für Browse Advance/Seeding (track_changed Timing, Autoplay-Verhalten, Queue-Echo-Shape)
result: blocked
blocked_by: prior-phase
reason: Browse auf persistentem Daemon hängt von den Test-2-Fixes ab (Stream-Lifecycle, Position-Sync). Nach Gap-Closure testbar.

### 5. Live Browse + Sync-Group UAT
expected: Sequenzielle Wiedergabe ohne Skips; Pause/Unpause behält Position; Seek funktioniert; Mixed Playlist handover; Sync-Group mit zwei Playern; Sync-Suffix im Device Picker
result: blocked
blocked_by: prior-phase
reason: Browse + Sync-Group hängt von Test-2-Fixes ab. Nach Gap-Closure testbar.

### 6. Settings Page Visual Render
expected: Soloist-Backend zeigt Per-Player Daemon/Paired/WS-State Tabelle + Build-Expiry-Zeile mit korrektem Styling; Librespot-Backend zeigt nichts davon
result: pass

## Summary

total: 6
passed: 2
issues: 1
pending: 0
skipped: 0
blocked: 3

## Gaps

- truth: "Spotify App Resume behält Pausenposition"
  status: failed
  reason: "User reported: Resume von Spotify→LMS startet immer bei Position 0, nicht bei Pausenposition. isDeadHistory=1 erzwingt Stream-Neustart."
  severity: major
  test: 2
  root_cause: "Connect.pm behandelt resume als Stream-Restart (isDeadHistory=1) statt Position-Update. Soloist meldet position=0.000 bei resume Events."
  artifacts:
    - path: "Plugins/SpotOn/Connect.pm"
      issue: "resume handler restartet Stream statt Position zu tracken"
    - path: "Plugins/SpotOn/Unified/SoloistWS.pm"
      issue: "position_sync Events liefern position=0"
  missing:
    - "Connect-mode resume: nur Metadaten/Position aktualisieren, nicht Stream neu aufbauen"
    - "Position aus playback_state WS Event extrahieren"
  debug_session: ""

- truth: "LMS Seek wird an Spotify/Soloist weitergeleitet"
  status: failed
  reason: "User reported: Seek über LMS funktioniert nicht — kein control_cmd_sent für seek im Log"
  severity: major
  test: 2
  root_cause: "Seek-Forwarding für Soloist-Backend nicht implementiert oder nicht ausgelöst"
  artifacts:
    - path: "Plugins/SpotOn/Connect.pm"
      issue: "_sendControlCommand für seek bei backend=soloist"
  missing:
    - "Seek WS command an Soloist senden bei LMS-side seek"
  debug_session: ""

- truth: "Spotify→LMS Skip Next ohne lange Verzögerung"
  status: failed
  reason: "User reported: Skip Next von Spotify App → lange Verzögerung, Spotify Progress bleibt bei 0/1s. LMS hat korrekten Progress + Metadaten."
  severity: major
  test: 2
  root_cause: "Vermutlich Echo-Problem: LMS reagiert auf track_changed und sendet Kommandos zurück die Soloist stören"
  artifacts:
    - path: "Plugins/SpotOn/Connect.pm"
      issue: "track_changed Handler bei Soloist-Connect darf keine Kommandos zurücksenden"
  missing:
    - "Bei Soloist Connect: track_changed nur für Metadaten-Update nutzen, keine Playback-Kommandos"
  debug_session: ""
