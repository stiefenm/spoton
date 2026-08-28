---
phase: 74-spoton-helper-binary
fixed_at: 2026-08-28T17:15:53Z
review_path: .planning/phases/74-spoton-helper-binary/74-REVIEW.md
iteration: 1
findings_in_scope: 6
fixed: 6
skipped: 0
status: all_fixed
---

# Phase 74: Code Review Fix Report

**Fixed at:** 2026-08-28T17:15:53Z
**Source review:** .planning/phases/74-spoton-helper-binary/74-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 6 (all Warning-severity; `fix_scope: critical_warning` — the 4 Info findings were out of scope and left untouched)
- Fixed: 6
- Skipped: 0

**Verification:** `cargo test` (spoton-helper crate, 20 tests) and `prove -l t/` (full Perl suite, 33 files / 1367 tests) both pass clean after all six commits, run cumulatively at the end as well as incrementally after each fix. WR-05 and WR-06 additionally got a targeted manual check beyond the automated suites (see their entries below) since neither has dedicated adversarial-scenario test coverage in this public checkout.

## Fixed Issues

### WR-01: Version detection picks the *first* `soloist ` marker — fragile, can silently disable patching

**Files modified:** `spoton-helper/src/check.rs`, `spoton-helper/src/patch/mod.rs`
**Commit:** `112d9ba`
**Applied fix:** `find_soloist_version` (duplicated in both modules per existing doc comments) now iterates every marker position in the binary, in order, and returns the first one followed by a dotted-numeric version — instead of giving up after the first marker fails the dotted-number check. Applied identically to both copies to keep `check` and `patch` in agreement.
**Verification status:** fixed: requires human verification — the change is a scanning-algorithm fix; the existing test suite (fixture with a single marker, idempotency test) still passes, but there is no adversarial fixture with multiple `soloist ` occurrences before the real version banner to directly exercise the fixed branch. Recommend a follow-up unit test with such a fixture if this is revisited.

### WR-02: `scan_status` infers "patched" solely from presence of replacement bytes — false-positive `already_patched` risk

**Files modified:** `spoton-helper/src/patch/mod.rs`
**Commit:** `8386d1a`
**Applied fix:** `scan_status_for_sites` now requires the site's `search` bytes to be **absent** in addition to `replace` being present before reporting it as applied (Fix option (a) from REVIEW.md). A real unpatched binary always still carries `search` until the engine rewrites it, so this removes the ambiguity a coincidental `replace`-pattern match could previously cause.
**Verification status:** fixed: requires human verification — logic-condition change in the patch-state detector; existing tests (full patch, idempotent re-run, gate-4-skip reporting) all still pass, but the private per-arch pattern table is empty in this public checkout, so the specific "coincidental short `replace` pattern" scenario the finding describes cannot be constructed/tested here.

### WR-03: Occurrence-count assertion (overlapping) vs. `replace_all` (non-overlapping) mismatch, and no per-site re-validation after prior replacements

**Files modified:** `spoton-helper/src/patch/mod.rs`
**Commit:** `93a8610`
**Applied fix:** Two changes: (1) `count_occurrences` now counts non-overlapping matches (advancing by `needle.len()` on each hit), matching `replace_all`'s strategy — previously it counted overlapping `.windows()` matches despite its own doc comment claiming otherwise. (2) Added a post-apply re-validation pass: after building `patched_bytes`, every non-skip site's `search` must now occur zero times and its `replace` exactly `expect_count` times, or the write is refused — catching a mis-applied intermediate the prior "looks patched overall" self-verify could miss.
**Verification status:** fixed: requires human verification — this is exactly the "incorrect condition / off-by-one" class of logic bug called out in the fixer's verification-strategy guidance. `cargo test` passes (18 unit + 2 fixture tests, including the full-patch and count-mismatch-abort cases), confirming no regression, but no test constructs a self-overlapping or cross-site-interfering pattern to directly exercise the new re-validation branch.

### WR-04: `_versionCompare` only iterates the *expected* version's components — a longer parsed version with an equal prefix compares equal

**Files modified:** `Plugins/SpotOn/Soloist.pm`
**Commit:** `0ee48a3`
**Applied fix:** The comparison loop now runs `0 .. max($#a, $#b)` instead of `0 .. $#b`, so trailing components on either side (parsed or expected) are significant — exactly the fix suggested in REVIEW.md. `prove -l t/26_soloist_check.t` (27 tests, includes version-check paths) passes.
**Verification status:** fixed: requires human verification — a clear loop-bound logic bug per the finding; fix matches the reviewer's suggested patch exactly and the existing test suite passes, but there is no dedicated test asserting the specific "reported version is a strict superset of the expected pin" scenario the finding describes.

### WR-05: Tar extraction of the downloaded archive is unhardened (path-traversal / ownership)

**Files modified:** `Plugins/SpotOn/Soloist.pm`
**Commit:** `878a8e7`
**Applied fix:** Added `--no-same-owner --no-same-permissions` to the `tar xzf` invocation (array-form `system()`, unchanged), and a new `_pathIsWithin` helper that, together with `Cwd::realpath`, verifies the extracted binary resolves inside `$destDir` before `chmod`/activation — rejecting a symlink or `..`-relative archive member that would otherwise escape the trusted cache directory.
**Verification status:** fixed — `prove -l t/26_soloist_check.t` Test 12 exercises the real end-to-end download pipeline (`tar czf` fixture → `_onSoloistDownloadDone` → extraction → activation) through the modified code path with a real `tar` binary and passed unchanged; ran the full `prove -l t/` suite (1367 tests) as an additional regression check. No adversarial malicious-archive fixture was added (out of scope for this fix-scope pass), so the escape-detection branch itself is exercised only by code inspection, not a dedicated negative test.

### WR-06: `check` subcommand's `--expect-sha` mismatch does not fail the process

**Files modified:** `spoton-helper/src/check.rs`
**Commit:** `1d85d99`
**Applied fix:** A `--expect-sha` mismatch now returns `Err` (via `bail!`) instead of printing `"sha_matches": false` and returning `Ok(())`. This routes through `main.rs`'s existing error handling (single-line JSON `{"error": ...}`, exit code 1), preserving the "callers parse stdout as JSON unconditionally" single-object-per-invocation contract the codebase already relies on.
**Verification status:** fixed — manually smoke-tested both branches against the built binary: a mismatched `--expect-sha` now exits 1 with `{"error":"sha256 mismatch: ..."}`, and a matching `--expect-sha` still exits 0 with the full manifest including `"sha_matches":true`. `cargo test` (no existing test exercised `--expect-sha`) confirms no regression elsewhere.

## Skipped Issues

None — all 6 in-scope findings (WR-01 through WR-06) were fixed. The 4 Info findings (IN-01 through IN-04) were out of scope for `fix_scope: critical_warning` and were left untouched.

---

_Fixed: 2026-08-28T17:15:53Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
