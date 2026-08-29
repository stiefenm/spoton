---
phase: 75-api-unification-spclient-modell
plan: 01
subsystem: api
tags: [protobuf, login5, spclient, perl, wire-format, bearer-token, math-bigint]

# Dependency graph
requires:
  - phase: 74-spoton-helper-binary
    provides: spoton-helper Rust binary with a still-present protobuf subcommand used once here to capture Rust-parity golden test vectors before D-02 deletes it
provides:
  - "Plugins::SpotOn::API::ProtobufLite -- pure-Perl protobuf wire-format encoder/decoder (encode_varint, encode_field, parse_fields, field_first), zero LMS dependencies, repeated-field-safe"
  - "Plugins::SpotOn::API::Login5 -- login5 Bearer-token minting from stored credentials via the librespot Client ID (challenge-free), cache-first with in-flight coalescing"
  - "Plugins::SpotOn::API::SpClient -- standalone spclient.spotify.com HTTP layer with capability-based router facade, base62<->hex ID conversion, and a getTrack tracer that normalizes spclient metadata into the existing Web-API track shape"
affects: [75-02, 75-03, 75-04, 75-05, 75-06]

# Actuals (#2632)
actuals:
  tokens: 17750
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Standalone-module cloning: SpClient.pm duplicates Client.pm's _request/_doRequest pipeline shape (rate-gate, concurrency cap, double-callback guard) with its own state instead of extending Client.pm, per D-03 isolation"
    - "Capability-based router facade: same method signature and callback shape used by the module it replaces (Client.pm), internal dispatch on credential availability + error classification (D-06/D-07)"
    - "Rust-to-Perl test-vector portability: capture golden wire bytes from the still-compiling Rust helper via CLI before the source is deleted, embed as a hex constant in the Perl test"

key-files:
  created:
    - Plugins/SpotOn/API/ProtobufLite.pm
    - Plugins/SpotOn/API/Login5.pm
    - Plugins/SpotOn/API/SpClient.pm
    - t/34_protobuf_lite.t
    - t/35_login5.t
    - t/36_spclient.t
  modified:
    - t/05_perl_syntax.t

key-decisions:
  - "parse_fields collects every field occurrence into an arrayref (push, never overwrite) -- corrects the RESEARCH.md sample's last-item-wins bug (A1) so collection/v2 repeated CollectionItems decode completely"
  - "Device id for login5 is a stable per-account Digest::MD5 hexdigest of \"spoton-login5-${accountId}\" -- deterministic, no MAC address dependency (RESEARCH Open Question 2)"
  - "login5 cache TTL is always derived from the response's own expires_in field (max(60, expires_in-60)), never a hardcoded 3600 guess (A2)"
  - "SpClient.pm runtime-require's Login5/Credentials/Client (never a compile-time `use`) -- mirrors Client.pm's own runtime-require of TokenManager and keeps D-03's no-compile-time-coupling guarantee literally true for all three collaborators, not just Client.pm"
  - "D-07a: a single 401 triggers exactly one remint-retry with a freshly minted token before falling back to Client.pm; a second 401 falls back immediately -- refreshing an expired Bearer token is standard token lifecycle, not a spclient API failure"
  - "_normalizeTrack degrades every field to undef/[] on absence rather than dying -- untrusted network JSON, Pitfall 6 discipline"

requirements-completed: [D-01, D-03, D-04, D-06, D-07, D-09]

coverage:
  - id: D1
    description: "ProtobufLite.pm decodes repeated fields into arrays (not last-item-wins) and never dies/loops on malformed input"
    requirement: D-01
    verification:
      - kind: unit
        ref: "t/34_protobuf_lite.t"
        status: pass
    human_judgment: false
  - id: D2
    description: "Login5.pm mints a full-length Bearer token from stored credentials, correctly parsing the S-01 multi-byte-varint-length response"
    requirement: D-04
    verification:
      - kind: unit
        ref: "t/35_login5.t"
        status: pass
    human_judgment: false
  - id: D3
    description: "SpClient.pm getTrack routes via login5 for creds-capable accounts and delegates transparently to Client.pm for PKCE-only accounts or any spclient-path failure, with rate-key isolation and shape normalization"
    requirement: "D-03, D-06, D-07, D-09"
    verification:
      - kind: unit
        ref: "t/36_spclient.t"
        status: pass
    human_judgment: false
  - id: D4
    description: "A real login5 mint + spclient metadata round-trip against a live paired Spotify account works end-to-end"
    human_judgment: true
    rationale: "No paired Spotify account is reachable in this environment (Phase 73 precedent) -- the plan's own <verification> section marks this mandatory UAT via /gsd-verify-work, aided by the smoke script from plan 75-06. All decodable-in-isolation behavior (varint parsing, wire encoding, router dispatch, fallback classification, rate-key isolation, shape mapping) is covered by unit tests against synthetic fixtures; only the live network round-trip requires a human with a real account."

duration: 20min
completed: 2026-08-29
status: complete
---

# Phase 75 Plan 01: ProtobufLite + Login5 + SpClient Tracer Summary

**Pure-Perl protobuf wire parser, login5 Bearer-token minting, and a working end-to-end getTrack tracer through a new spclient.spotify.com API layer with transparent Client.pm fallback**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-08-29T09:50:00Z (approx.)
- **Completed:** 2026-08-29T10:01:29+02:00
- **Tasks:** 3
- **Files modified:** 7 (6 created, 1 modified)

## Accomplishments

- `ProtobufLite.pm`: generic protobuf wire-format decoder/encoder (varint + length-delimited + fixed-width types), zero LMS dependencies, bounded parse loops that never die or loop on malformed input, repeated-field-safe (`parse_fields` returns arrayrefs for every field, fixing the RESEARCH.md sample's overwrite bug). Golden `PageRequest` encode vector captured from the still-live Rust helper (`cargo run -- protobuf --schema collection-v2 --mode encode`) before D-02 deletes that code, confirming byte-for-byte Rust parity.
- `Login5.pm`: mints login5 Bearer tokens from stored credentials using the librespot Client ID (challenge-free per Spike 009), following the WebPlayer.pm cache-first + in-flight-coalescing lifecycle. Fixes the S-01 truncated-token class of bug by correctly parsing the outer LoginOk's multi-byte varint length; a synthetic 700+ byte response with a 438-char token round-trips intact in the test suite. Cache TTL always derives from the response's real `expires_in` field.
- `SpClient.pm`: a fully standalone spclient.spotify.com HTTP layer (own inflight counter, own `spoton_spclient_rate_limit` key, `MAX_CONCURRENT_REQUESTS=2`) that clones Client.pm's battle-tested `_request`/`_doRequest` pipeline shape without a compile-time dependency on Client.pm. Implements base62<->hex ID conversion via `Math::BigInt` (128-bit safe), a capability router (`getTrack`) that dispatches to spclient for login5-capable accounts and falls back to Client.pm for PKCE-only accounts or any spclient error (with exactly one 401 remint-retry, D-07a), and `_normalizeTrack` mapping spclient's metadata/4 JSON into the existing Web-API track shape so callers are unaffected.
- All four new/updated test files (`t/34`, `t/35`, `t/36`, `t/05`) pass under `prove -l`; the full `prove t/` suite (36 files, 1467 tests) is green with zero regressions; `cargo test` in `spoton-helper` is unaffected (18+2 tests pass).
- `Client.pm`, `TokenManager.pm`, and `Credentials.pm` are byte-identical (`git diff --stat` confirms zero changes for all three) — the phase's isolation decisions (D-03/D-04) hold in practice, not just on paper.

## Task Commits

Each task was committed atomically:

1. **Task 1: ProtobufLite.pm -- generic wire parser/encoder with repeated-field support (D-01)** - `df6e076` (feat)
2. **Task 2: Login5.pm -- Bearer token minting from stored credentials (D-04)** - `e0bc9e7` (feat)
3. **Task 3: SpClient.pm skeleton + getTrack end-to-end through router, login5 and metadata/4 (D-03/D-06/D-07/D-09)** - `6469651` (feat, tracer)

_Note: no TDD RED/GREEN split -- Task 1 carries `tdd="true"` but was implemented as a single commit covering both the module and its test file together per the plan's action description; behavior and test were designed jointly against the Rust-parity golden vector rather than as a separate failing-test-first commit._

## Files Created/Modified

- `Plugins/SpotOn/API/ProtobufLite.pm` - Pure-Perl protobuf wire-format encoder/decoder (D-01)
- `Plugins/SpotOn/API/Login5.pm` - login5 Bearer-token minting from stored credentials (D-04)
- `Plugins/SpotOn/API/SpClient.pm` - spclient HTTP pipeline + capability router + getTrack facade (D-03/D-06/D-07/D-09)
- `t/34_protobuf_lite.t` - ProtobufLite unit tests incl. Rust-parity golden vector, repeated items, malformed input
- `t/35_login5.t` - Login5 unit tests incl. S-01 regression, error mapping, coalescing, request-body wire assertions
- `t/36_spclient.t` - SpClient unit tests incl. id conversion, D-06 routing, D-07 fallback, D-03 rate isolation, D-07a retry
- `t/05_perl_syntax.t` - Added ProtobufLite.pm/Login5.pm/SpClient.pm to the syntax-check module list (Phase 49 precedent)

## Decisions Made

- `parse_fields` collects every field occurrence into an arrayref instead of overwriting on repeat, correcting the RESEARCH.md reference sample (A1) so collection/v2's `repeated CollectionItem items` decodes completely in later plans.
- Login5's device id is a stable per-account `Digest::MD5` hexdigest of `"spoton-login5-${accountId}"` -- deterministic, no MAC address needed (resolves RESEARCH Open Question 2).
- login5 cache TTL is always computed from the response's real `expires_in` field, never a hardcoded 3600 guess (A2).
- SpClient.pm runtime-require's all three of its Perl collaborators (Login5, Credentials, Client) rather than `use`-ing any of them at compile time -- mirrors Client.pm's own runtime-require of TokenManager and makes D-03's "no compile-time coupling" guarantee literally true beyond just the specific Client.pm grep check.
- D-07a implemented exactly as the plan's user-approved refinement: one 401 remint-retry with a fresh token, then fallback on a second 401 -- token expiry is normal lifecycle, not a spclient outage signal.
- `_normalizeTrack` degrades every missing field to `undef`/`[]` rather than dying, since spclient's metadata/4 response is untrusted network JSON (Pitfall 6 discipline).

## Deviations from Plan

None - plan executed exactly as written. All five `must_haves.truths` hold, demonstrated by the named tests (`t/34` for repeated-item decode + malformed tolerance, `t/35` for the S-01 regression, `t/36` for the getTrack routing/fallback/rate-isolation behaviors).

## Issues Encountered

- Two of my own test-authoring mistakes were caught and fixed before committing (not plan deviations, just normal test-writing iteration): a stub-loading-order bug in `t/36_spclient.t` (Login5/Client/Credentials stubs are only `require`'d lazily by SpClient.pm's runtime-require calls, so `reset_all()`'s helper subs weren't defined until forced with explicit `require_ok` calls up front), and a 31-vs-32-char hex fixture typo in the normalization test's synthetic `gid` values.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The tracer proves the whole spclient stack end-to-end (stored creds -> login5 Bearer token -> spclient metadata/4 -> Web-API-shaped result) with verified fallback and rate-key isolation. Plans 75-02 (context-resolve/search), 75-03 (D-02 Rust protobuf removal), 75-04 (collection/v2), and 75-05 (recently-played/playlists/rootlist) can now build on this skeleton directly.
- `_cacheTTL` already carries the context-resolve (300s) TTL entry for 75-02 to reuse without re-deriving the table.
- Live login5 + metadata round-trip against a real paired account remains **mandatory UAT** (no paired account reachable in this environment, Phase 73 precedent) -- tracked for `/gsd-verify-work`, to be aided by the smoke script planned for 75-06.
- No blockers.

## Self-Check: PASSED

- All 6 created files + 1 modified file verified present on disk (`[ -f ]`)
- All 3 task commit hashes (`df6e076`, `e0bc9e7`, `6469651`) verified in `git log`
- All 5 `must_haves.truths` re-verified: `prove -l t/34_protobuf_lite.t t/35_login5.t t/36_spclient.t t/05_perl_syntax.t` green; full `prove t/` (36 files, 1467 tests) green; `cargo test` in spoton-helper green (18+2 tests)
- `git diff --stat` confirmed empty for `Client.pm`, `TokenManager.pm`, `Credentials.pm`

---
*Phase: 75-api-unification-spclient-modell*
*Completed: 2026-08-29*
