---
id: 260817-ana
description: "Fix #149 + #150: Daemon resilience on AP drops"
status: in-progress
created: 2026-08-17
---

# Quick Task: Daemon Resilience on AP Drops (#149 + #150)

## Objective

Two fixes for daemon stability during routine Spotify access-point reconnects:

1. **#149**: Health check Signal 1 (`session_valid=false`) restarts daemon mid-playback — add idle guard (same as Signal 2)
2. **#150**: Audio key response timeout is invisible to monitoring — extend classifier + cache handling

## Tasks

### T1: Idle guard on Signal 1 (DaemonManager.pm)

**File:** `Plugins/SpotOn/Unified/DaemonManager.pm:796`

Change:
```perl
if (!$json->{session_valid}) {
```
To:
```perl
if (!$json->{session_valid} && ($json->{idle_secs} // 0) > 30) {
```

### T2: Audio key timeout classification (Credentials.pm)

**File:** `Plugins/SpotOn/API/Credentials.pm:432-438`

Add pattern between 'throttled' and final `return undef`:
```perl
return 'timeout'   if $stderrText =~ /Audio key response timeout/;
```

Priority order: denied > throttled > timeout (denied is permanent, throttled is protocol-level, timeout is client-side transient).

### T3: Cache handling for 'timeout' state (DaemonManager.pm)

**File:** `Plugins/SpotOn/Unified/DaemonManager.pm:461-465`

Add `elsif` for timeout after the throttled block:
```perl
elsif ($state eq 'timeout') {
    $cache->set($cacheKey, 'timeout', 300);
}
```

300s TTL — shorter than throttled (600s) since timeout is transient and self-clears on next successful key exchange.

### T4: Tests (t/22_audio_key_classifier.t)

Add 3 tests:
- Exact "Audio key response timeout" → 'timeout'
- Embedded in stderr noise → 'timeout'
- All three signatures present → 'denied' wins (existing priority)

## Files Changed

| File | Change |
|------|--------|
| Plugins/SpotOn/Unified/DaemonManager.pm | T1 (idle guard) + T3 (timeout cache) |
| Plugins/SpotOn/API/Credentials.pm | T2 (timeout pattern) |
| t/22_audio_key_classifier.t | T4 (3 new tests) |
