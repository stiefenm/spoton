---
id: 260818-v1l
type: quick
status: planned
description: "Fix #155 follow-up: rate_limited_local short-circuit invisible + empty page"
issue: "#155"
created: "2026-08-18"
---

# Fix #155 Follow-up: rate_limited_local Visibility

## Problem

When `spoton_rate_limit` or `WP_RATE_LIMIT_KEY` cache flag is active, subsequent requests are short-circuited immediately with `rate_limited_local`. Two issues:

1. **Invisible logging**: All 3 short-circuit sites log at `$log->debug()` — invisible even with diagnosticMode
2. **Silent empty page**: OPML consumers receive `{ error => 'rate_limited_local' }` but `_authRequiredItem` doesn't recognize it, falling through to `PLUGIN_SPOTON_NO_RESULTS` — user sees "No results" with zero explanation

## Tasks

### T1: Upgrade short-circuit logging (Client.pm)

Change 3 `$log->debug(...)` calls to `main::INFOLOG && $log->info(...)` so they appear in server.log at normal log levels:

- Line 1365: `_request()` short-circuit (main API pipeline)
- Line 814: `pathfinderHome` short-circuit (Web-Player pool)
- Line 1155: `getWebPlayerPlaylistItems` short-circuit (Web-Player pool)

### T2: Add rate-limited i18n string (strings.txt)

Add `PLUGIN_SPOTON_RATE_LIMITED` with translations for all 11 languages. Message: "Temporarily rate limited — please try again shortly"

### T3: Surface rate_limited_local in OPML (Plugin.pm)

In `_authRequiredItem()`: before the `needsAuth` check, detect `rate_limited_local` or `rate_limited` in `$err->{error}` and return the new `PLUGIN_SPOTON_RATE_LIMITED` string. This gives the user a clear explanation instead of a confusing "No results".

## Files

- `Plugins/SpotOn/API/Client.pm` — T1 (3 log-level changes)
- `Plugins/SpotOn/strings.txt` — T2 (new string key)
- `Plugins/SpotOn/Plugin.pm` — T3 (`_authRequiredItem` enhancement)
