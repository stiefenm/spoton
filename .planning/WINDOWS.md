---
schema_version: 1
open_count: 5
waived_count: 0
fixed_count: 0
total_count: 5
last_updated: 2026-08-29T20:56:58.192Z
---

# Broken Windows Ledger

> Cross-phase defect register. With `workflow.windows_enforce` enabled, `/gsd-ship` blocks while `open_count > 0`.
> Waive with `gsd-tools windows waive <id> "<reason>"` (reason required).
> Mark fixed with `gsd-tools windows fixed <id>`.

| id | phase | kind | file | line | description | status | reason | recorded_at | resolved_at |
|----|-------|------|------|------|-------------|--------|--------|-------------|-------------|
| 1 | 76 | unrun-verify | Plugins/SpotOn/custom-convert.conf |  | 76-01 human-check deferred to consolidated Phase 76 UAT (D-11): live FLAC24 chain -- play Soloist track to squeezelite with flc rule active, confirm FLAC 24-bit + clean audio | open |  | 2026-08-29T20:27:45.909Z |  |
| 2 | 76 | unrun-verify | Plugins/SpotOn/ProtocolHandler.pm |  | 76-04 live format matrix pending consolidated Phase 76 UAT (D-11): soloist auto->FLAC on squeezelite, pcm->direct raw stream (no transcoder), mp3->lame in pipeline; librespot OGG/PCM regression re-check (D-14) | open |  | 2026-08-29T20:40:32.922Z |  |
| 3 | 76 | unrun-verify | Plugins/SpotOn/Connect.pm |  | 76-05 Task 1: restart-autoplay live repro — pinned to Phase 76 UAT | open |  | 2026-08-29T20:56:57.248Z |  |
| 4 | 76 | unrun-verify | Plugins/SpotOn/Connect.pm |  | 76-05 Task 3: GH #158 group-player crash live repro — pinned to Phase 76 UAT | open |  | 2026-08-29T20:56:57.718Z |  |
| 5 | 76 | unrun-verify | Plugins/SpotOn/Connect.pm |  | 76-05 Task 2: GH #151 power-state restore live check — pinned to Phase 76 UAT | open |  | 2026-08-29T20:56:58.192Z |  |

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
    "file": "Plugins/SpotOn/ProtocolHandler.pm",
    "line": null,
    "description": "76-04 live format matrix pending consolidated Phase 76 UAT (D-11): soloist auto->FLAC on squeezelite, pcm->direct raw stream (no transcoder), mp3->lame in pipeline; librespot OGG/PCM regression re-check (D-14)",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:40:32.922Z",
    "resolved_at": null
  },
  {
    "id": 3,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/Connect.pm",
    "line": null,
    "description": "76-05 Task 1: restart-autoplay live repro — pinned to Phase 76 UAT",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:56:57.248Z",
    "resolved_at": null
  },
  {
    "id": 4,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/Connect.pm",
    "line": null,
    "description": "76-05 Task 3: GH #158 group-player crash live repro — pinned to Phase 76 UAT",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:56:57.718Z",
    "resolved_at": null
  },
  {
    "id": 5,
    "kind": "unrun-verify",
    "phase": "76",
    "file": "Plugins/SpotOn/Connect.pm",
    "line": null,
    "description": "76-05 Task 2: GH #151 power-state restore live check — pinned to Phase 76 UAT",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-29T20:56:58.192Z",
    "resolved_at": null
  }
]
````
