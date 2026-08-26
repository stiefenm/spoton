---
status: testing
phase: 73-soloist-connect-mode
source: [73-VERIFICATION.md]
started: 2026-08-26T20:15:00Z
updated: 2026-08-26T20:15:00Z
---

## Current Test

number: 1
name: Connect Transfer via App-Tap Pairing (D-07)
expected: |
  Device erscheint unter seinem LMS-Namen im Spotify Device Picker;
  Antippen transferiert Audio zu LMS via /stream — kein Web API PUT /me/player Call.
awaiting: user response

## Tests

### 1. Connect Transfer via App-Tap Pairing (D-07)
expected: Device erscheint unter LMS-Name im Spotify Device Picker; Antippen startet LMS-Playback via /stream ohne Web API Call
result: [pending]

### 2. Bidirektionale Kontroll-Loop + WS-Down-Fallback (D-06/D-15)
expected: LMS-side Pause/Skip/Seek/Volume werden in der Spotify App innerhalb ~1s gespiegelt; bei WS-Down greifen die Web API Fallbacks
result: [pending]

### 3. Build-Expiry Escalation (Pitfall 7)
expected: DaemonManager loggt Expiry-Meldung, setzt spoton_soloist_expired, Daemon wird vom Watchdog nie wieder gestartet
result: [pending]

### 4. Wave-0 Spike — Track-End/Autoplay/Queue-Echo (D-03)
expected: Bestätigt oder korrigiert die RESEARCH-Default-Annahmen für Browse Advance/Seeding (track_changed Timing, Autoplay-Verhalten, Queue-Echo-Shape)
result: [pending]

### 5. Live Browse + Sync-Group UAT
expected: Sequenzielle Wiedergabe ohne Skips; Pause/Unpause behält Position; Seek funktioniert; Mixed Playlist handover; Sync-Group mit zwei Playern; Sync-Suffix im Device Picker
result: [pending]

### 6. Settings Page Visual Render
expected: Soloist-Backend zeigt Per-Player Daemon/Paired/WS-State Tabelle + Build-Expiry-Zeile mit korrektem Styling; Librespot-Backend zeigt nichts davon
result: [pending]

## Summary

total: 6
passed: 0
issues: 0
pending: 6
skipped: 0
blocked: 0

## Gaps
