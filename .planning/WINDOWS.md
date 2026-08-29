---
schema_version: 1
open_count: 2
waived_count: 0
fixed_count: 0
total_count: 2
last_updated: 2026-08-29T20:40:32.922Z
---

# Broken Windows Ledger

> Cross-phase defect register. With `workflow.windows_enforce` enabled, `/gsd-ship` blocks while `open_count > 0`.
> Waive with `gsd-tools windows waive <id> "<reason>"` (reason required).
> Mark fixed with `gsd-tools windows fixed <id>`.

| id | phase | kind | file | line | description | status | reason | recorded_at | resolved_at |
|----|-------|------|------|------|-------------|--------|--------|-------------|-------------|
| 1 | 76 | unrun-verify | Plugins/SpotOn/custom-convert.conf |  | 76-01 human-check deferred to consolidated Phase 76 UAT (D-11): live FLAC24 chain -- play Soloist track to squeezelite with flc rule active, confirm FLAC 24-bit + clean audio | open |  | 2026-08-29T20:27:45.909Z |  |
| 2 | 76 | unrun-verify | Plugins/SpotOn/ProtocolHandler.pm |  | 76-04 live format matrix pending consolidated Phase 76 UAT (D-11): soloist auto->FLAC on squeezelite, pcm->direct raw stream (no transcoder), mp3->lame in pipeline; librespot OGG/PCM regression re-check (D-14) | open |  | 2026-08-29T20:40:32.922Z |  |

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
  }
]
````
