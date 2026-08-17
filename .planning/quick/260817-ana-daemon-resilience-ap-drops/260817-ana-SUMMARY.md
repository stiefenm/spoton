---
id: 260817-ana
description: "Fix #149 + #150: Daemon resilience on AP drops"
status: complete
created: 2026-08-17
completed: 2026-08-17
commit: 4ba5247
---

# Summary: Daemon Resilience on AP Drops (#149 + #150)

## Changes

### #149: Idle guard on health-check Signal 1
- `DaemonManager.pm:_onHealthResponse` — Signal 1 (`session_valid=false`) now defers restart while `idle_secs <= 30`
- Same discipline as Signal 2 (stale session), which already had an idle guard
- Transient AP drops no longer kill mid-playback sessions

### #150: Audio key timeout detection
- `Credentials.pm:classifyAudioKeyError` — new 'timeout' classification for "Audio key response timeout"
- `DaemonManager.pm:_streamAlivePoll` — 'timeout' cached with 300s TTL (transient)
- Previously invisible to all monitoring; now surfaced in Auth Health dashboard

### Tests
- `t/22_audio_key_classifier.t` — 3 new tests (exact match, embedded in noise, priority over timeout)
- All 11 tests pass, full syntax check green

## Files Changed

| File | Lines | Change |
|------|-------|--------|
| Plugins/SpotOn/Unified/DaemonManager.pm | +10/-1 | Idle guard + timeout cache |
| Plugins/SpotOn/API/Credentials.pm | +1 | Timeout pattern |
| t/22_audio_key_classifier.t | +12 | 3 new tests |
