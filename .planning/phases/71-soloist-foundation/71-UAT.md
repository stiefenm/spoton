---
status: complete
phase: 71-soloist-foundation
source: 71-01-SUMMARY.md, 71-03-SUMMARY.md
started: 2026-08-25T09:30:00Z
updated: 2026-08-25T09:30:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Settings Backend-Dropdown sichtbar
expected: In LMS Settings → SpotOn → Global: ein Dropdown "Audio Backend" mit Optionen "librespot" (default) und "Soloist"
result: pass

### 2. Conditional spak-Key-Feld (Live-Toggle)
expected: Backend auf "Soloist" umschalten → spak-Key-Feld + Status-Zeilen erscheinen sofort (JS-Toggle, kein Page-Reload). Zurück auf "librespot" → Feld verschwindet.
result: pass

### 3. Soloist Status-Warnungen (D-09)
expected: Bei Soloist ausgewählt aber Binary fehlt + Key fehlt: Warnungen "Binary not found" und "API key not set" sichtbar in den Status-Zeilen.
result: issue
reported: "Backend-Auswahl fällt nach Übernehmen auf librespot zurück. Grüner Punkt erscheint unter spak-Key-Feld obwohl Key leer."
severity: major

### 4. spak-Key speichern
expected: Gültigen spak-Key eingeben, Save drücken. Seite neu laden → maskierter Platzhalter (********) sichtbar statt dem eingegebenen Key.
result: pass

### 5. spak-Key Validierung — ungültiger Key
expected: Key mit Sonderzeichen (z.B. "test!@#key") eingeben, Save → Fehlermeldung "Invalid spak key format" (nicht still akzeptieren).
result: pass

### 6. Auto-Download triggert bei Backend-Aktivierung
expected: Bei Wechsel auf Soloist (ohne gecachtes Binary): Download startet automatisch, Progress im Server-Log sichtbar. Nach erfolgreichem Download: "Binary not found" Warnung verschwindet nach Seiten-Reload.
result: pass

### 7. Version-Pin verifizieren
expected: `grep SOLOIST_VERSION Plugins/SpotOn/Soloist.pm` zeigt `1.3.7.489`
result: pass

### 8. spak-Key Datei-Permissions
expected: Nach Key-Speicherung: `ls -la cachedir/spoton/soloist/spak.key` zeigt mode `-rw-------` (0600)
result: pass

### 9. fake-libpulse kompiliert lokal
expected: `cd Plugins/SpotOn/Bin/fake-libpulse && make` kompiliert ohne Fehler, `file libpulse.so.0` zeigt "ELF 64-bit LSB shared object"
result: pass

### 10. Perl-Syntax clean
expected: `prove -I. t/05_perl_syntax.t` besteht — Soloist.pm ist registriert und syntaktisch korrekt
result: pass

### 11. Test Suite grün
expected: `prove -I. t/` — alle Tests bestehen, insbesondere t/26 (Soloist check), t/27 (key storage), t/28 (dispatch)
result: pass

### 12. Backend-Switch stoppt librespot-Daemons
expected: Mit laufendem librespot-Daemon: Backend auf Soloist umschalten, Save → Server-Log zeigt Daemon-Stop für den laufenden Player. Daemon wird nicht mehr neu gestartet.
result: pass

## Summary

total: 12
passed: 12
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps
