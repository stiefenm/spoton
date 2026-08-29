---
schema_version: 1
open_count: 4
waived_count: 0
fixed_count: 0
total_count: 4
last_updated: 2026-08-29T20:52:21.177Z
---

# Broken Windows Ledger

> Cross-phase defect register. With `workflow.windows_enforce` enabled, `/gsd-ship` blocks while `open_count > 0`.
> Waive with `gsd-tools windows waive <id> "<reason>"` (reason required).
> Mark fixed with `gsd-tools windows fixed <id>`.

| id | phase | kind | file | line | description | status | reason | recorded_at | resolved_at |
|----|-------|------|------|------|-------------|--------|--------|-------------|-------------|
| 1 | 76 | unrun-verify | Plugins/SpotOn/custom-convert.conf |  | 76-01 human-check deferred to consolidated Phase 76 UAT (D-11): live FLAC24 chain -- play Soloist track to squeezelite with flc rule active, confirm FLAC 24-bit + clean audio | open |  | 2026-08-29T20:27:45.909Z |  |
| 2 | 76 | unrun-verify | Plugins/SpotOn/Connect.pm |  | 76-05 Task 1: after-fix live restart repro (pause session, restart LMS, then fresh transfer) not runnable from isolated worktree — pinned to consolidated Phase 76 UAT (76-08) | open |  | 2026-08-29T20:52:20.253Z |  |
| 3 | 76 | unrun-verify | Plugins/SpotOn/Connect.pm |  | 76-05 Task 3: GH #158 sync-group pause-skip-play live repro (before/after 76-02 baseline) not runnable from isolated worktree — pinned to consolidated Phase 76 UAT (76-08) | open |  | 2026-08-29T20:52:20.701Z |  |
| 4 | 76 | unrun-verify | Plugins/SpotOn/Connect.pm |  | 76-05 Task 2: GH #151 power off/on live check (off->connect->end->off again; on stays on) — pinned to consolidated Phase 76 UAT (76-08) | open |  | 2026-08-29T20:52:21.177Z |  |

````json
[
  {
    "id": 1,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/custom-convert.conf",
    "line": null,
    "description": "76-01 human-check deferred to consolidated Phase 76 UAT (D-11): live FLAC24 chain -- play Soloist track to squeezelite with flc rule active, confirm FLAC 24-bit + clean audio",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:27:45.909Z",
    "resolved_at": null
  },
  {
    "id": 2,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/Connect.pm",
    "line": null,
    "description": "76-05 Task 1: after-fix live restart repro (pause session, restart LMS, then fresh transfer) not runnable from isolated worktree — pinned to consolidated Phase 76 UAT (76-08)",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:52:20.253Z",
    "resolved_at": null
  },
  {
    "id": 3,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/Connect.pm",
    "line": null,
    "description": "76-05 Task 3: GH #158 sync-group pause-skip-play live repro (before/after 76-02 baseline) not runnable from isolated worktree — pinned to consolidated Phase 76 UAT (76-08)",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:52:20.701Z",
    "resolved_at": null
  },
  {
    "id": 4,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/Connect.pm",
    "line": null,
    "description": "76-05 Task 2: GH #151 power off/on live check (off->connect->end->off again; on stays on) — pinned to consolidated Phase 76 UAT (76-08)",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:52:21.177Z",
    "resolved_at": null
  }
]
````
