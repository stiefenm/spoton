#!/usr/bin/env python3
"""Restrict a closed phase's VERIFICATION.md covered_files to its .planning artifacts.

Why: GSD recomputes covered_digest over the CURRENT content of every file in
covered_files. When a report lists source files, any later phase that touches
them flips the closed (and shipped) phase to `stale`, and /gsd-progress then
routes back to it. Run this once a phase is closed (after phase.complete),
e.g. for phase 91:

    python3 -I tools/restrict-covered-files.py .planning/phases/91-*

What it does per phase directory:
  - refuses unless the report reads `status: passed`
  - keeps only `.planning/` entries in covered_files (GSD unions the phase's
    own PLAN/SUMMARY files in anyway)
  - recomputes covered_digest with `gsd-tools query verification.fingerprint`
  - writes one YAML comment line above covered_files (replacing an earlier one)
status, score and the report body stay untouched; the verifier is not re-run.
Check afterwards: `gsd-tools query verification.status <phase-dir>` -> passed.
First used 2026-11-24 on phases 88, 89, 90 and 90.1 (commit c9c4e079).
"""
import datetime
import glob
import json
import os
import subprocess
import sys

NOTE_PREFIX = "# covered_files restricted to this phase's .planning artifacts"
GSD_TOOLS = os.environ.get(
    "GSD_TOOLS", os.path.expanduser("~/.claude/gsd-core/bin/gsd-tools.cjs"))


def restrict(phase_dir):
    reports = glob.glob(os.path.join(phase_dir, "*-VERIFICATION.md"))
    if len(reports) != 1:
        sys.exit(f"{phase_dir}: expected exactly one *-VERIFICATION.md, found {len(reports)}")
    path = reports[0]
    lines = open(path, encoding="utf-8").read().split("\n")
    if lines[0] != "---":
        sys.exit(f"{path}: no frontmatter")
    end = lines.index("---", 1)
    front = lines[1:end]
    if "status: passed" not in front:
        sys.exit(f"{path}: status is not 'passed' - refusing (re-run the verifier instead)")
    i = lines.index("covered_files:", 1)
    j = i + 1
    while lines[j].startswith("  - "):
        j += 1
    if not lines[j].startswith("covered_digest:"):
        sys.exit(f"{path}: covered_digest does not follow covered_files (line {j + 1})")
    entries = [l[4:].strip().strip('"') for l in lines[i + 1:j]]
    quoted = lines[i + 1].startswith('  - "')
    keep = [e for e in entries if e.startswith(".planning/")]
    dropped = len(entries) - len(keep)
    if not keep:
        sys.exit(f"{path}: no .planning entries to keep")
    out = json.loads(subprocess.check_output(
        ["node", GSD_TOOLS, "query", "verification.fingerprint", phase_dir] + keep,
        stderr=subprocess.DEVNULL))
    files, digest = out["covered_files"], out["covered_digest"]
    if not all(f.startswith(".planning/") for f in files):
        sys.exit(f"{path}: fingerprint returned non-.planning paths, aborting")
    q = (lambda s: f'"{s}"') if quoted else (lambda s: s)
    has_note = lines[i - 1].startswith(NOTE_PREFIX)
    start = i - 1 if has_note else i
    note = lines[i - 1] if has_note and dropped == 0 else (f"{NOTE_PREFIX} on {datetime.date.today().isoformat()} "
            f"({dropped} source paths dropped): the phase is closed and shipped, later phases "
            f"legitimately change the same source files. status/score unchanged, verifier not re-run.")
    lines[start:j + 1] = ([note, "covered_files:"] + [f"  - {q(f)}" for f in files]
                          + [f'covered_digest: "{digest}"'])
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    print(f"{os.path.basename(path)}: {len(entries)} -> {len(files)} entries, "
          f"dropped {dropped} source paths, digest {digest[:28]}...")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for d in sys.argv[1:]:
        restrict(d.rstrip("/"))
