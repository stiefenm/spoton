---
status: partial
phase: 78-browse-connect-reintegration-perl
source: [78-01-SUMMARY.md, 78-02-SUMMARY.md, 78-03-SUMMARY.md, 78-04-SUMMARY.md]
started: 2026-09-01T07:50:00Z
updated: 2026-09-01T13:40:00Z
---

## Current Test

[testing paused — 4 items outstanding]

## Tests

### 1. Test Suite Green
expected: prove -l t/ passes
result: pass

### 2. browseSession Remnants entfernt
expected: Keine browseSession/browseCurrentUri etc. in Perl-Code (Kommentare OK)
result: pass

### 3. SPOTON_BOUNDARY_SPIKE entfernt
expected: Kein SPOTON_BOUNDARY_SPIKE in SoloistDaemon.pm
result: pass

### 4. Bounded URL in ProtocolHandler
expected: /stream/track?uri= in ProtocolHandler.pm
result: pass

### 5. Echo Guard in Connect.pm
expected: _currentSpotonTrackUrl >= 4 Treffer
result: pass

### 6. _isSoloistOwnedSong Ownership
expected: >= 6 Treffer in Connect.pm
result: pass

### 7. Watchdog isSpotifyConnect Guards
expected: >= 6 Treffer in Plugin.pm
result: pass

### 8. D-02 Boundary auf 'stopped'
expected: $self->_signalBoundary >= 2 in SoloistWS.pm
result: pass

### 9. Browse Playback via Bounded Endpoint
expected: Album abspielen, Track-Advance bei EOF
result: pass
reported: "Audio startete sofort, alle Tracks in Playlist, Track-Advance funktioniert"

### 10. Browse Seek
expected: Seek in LMS → Audio an neuer Position
result: issue
reported: "Seek hat kurz geklungen als ob es funktioniert, dann zum Skippen geführt"
severity: major

### 11. Connect Transfer von Spotify App
expected: Transfer auf Soloist → Connect übernimmt
result: issue
reported: "Audio stoppt, LMS zeigt Loading... — Browse Gate cleared korrekt, aber Resume-Handler bekommt Position als TrackId (0.000)"
severity: major

### 12. Connect Track-Advance
expected: Track-Ende → nächster Track automatisch
result: blocked
blocked_by: prior-phase
reason: Connect-Transfer (Test 11) funktioniert nicht korrekt, Track-Advance kann nicht getestet werden

### 13. Connect Skip
expected: Skip in Spotify App → Track wechselt
result: blocked
blocked_by: prior-phase
reason: Connect-Transfer (Test 11) funktioniert nicht korrekt

### 14. Connect Pause/Resume
expected: Pause/Play in Spotify App → LMS stoppt/startet
result: blocked
blocked_by: prior-phase
reason: Connect-Transfer (Test 11) funktioniert nicht korrekt

### 15. Browse→Connect Koexistenz
expected: Browse → Connect-Transfer → sauberer Übergang
result: issue
reported: "Browse Gate cleared korrekt (soloistBrowseActive), aber Resume-Event hat malformed trackId (Position statt ID)"
severity: major

### 16. ~46ms Boundary Gap Hörtest
expected: Kein hörbarer Aussetzer an Track-Grenzen
result: skipped
reason: Track-Advance bei Browse funktioniert, aber kein gezielter Grenz-Hörtest durchgeführt

## Summary

total: 16
passed: 9
issues: 3
pending: 0
skipped: 1
blocked: 3

## Gaps

- truth: "Browse seek jumps to correct position and continues playing"
  status: failed
  reason: "User reported: Seek hat kurz geklungen, dann zum nächsten Track geskippt"
  severity: major
  test: 10
  root_cause: "WS seek → pa_stream_flush → flush-disconnect closes HTTP client → squeezelite sees EOF → LMS advances. Bounded model seek needs flush-disconnect suppression during seek."
  artifacts:
    - path: "Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c"
      issue: "flush-disconnect fires on seek-initiated flush"
  missing:
    - "Seek-aware flush that doesn't close the HTTP client"
  debug_session: ""

- truth: "Connect transfer from Spotify app takes over playback"
  status: failed
  reason: "User reported: Audio stoppt, Loading... — resume event carries position (0.000) as trackId"
  severity: major
  test: 11
  root_cause: "SoloistWS resume emit uses lastTrackId which may be stale, and the Connect resume handler's _p2 parameter receives position instead of trackId for device-activation resumes"
  artifacts:
    - path: "Plugins/SpotOn/Unified/SoloistWS.pm"
      issue: "Resume emit parameter order on device re-activation"
    - path: "Plugins/SpotOn/Connect.pm"
      issue: "Resume handler trusts _p2 as trackId unconditionally"
  missing:
    - "Fix resume emit to pass correct trackId on device activation"
    - "Or: resume handler extracts trackId from device_changed payload instead of _p2"
  debug_session: ".planning/debug/browse-connect-gating.md"

- truth: "Browse→Connect coexistence: clean transition preserving both modes"
  status: failed
  reason: "Browse gate clearing works (soloistBrowseActive), but downstream resume processing fails (same root cause as test 11)"
  severity: major
  test: 15
  root_cause: "Same as test 11 — resume parameter parsing"
  artifacts: []
  missing: []
  debug_session: ".planning/debug/browse-connect-gating.md"
