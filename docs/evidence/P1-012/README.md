# Use the repository control plane

Status: **COMPLETE**

P1-012 adds bounded diagnostics and validation commands for maintainers, CI,
and coding agents. The commands use one task contract and one result model, so
missing capabilities, skipped work, and stale evidence remain visible.

## Prerequisites

- Linux x86_64 with glibc for the first manifest.
- Cangjie Compiler 1.1.0-alpha.20260829040003 and CJPM 1.1.3 for the current
  repository profile.
- Python 3 and Git. GitButler is recommended for this workspace.

The doctor reports a different platform or missing required tool as BLOCKED.
Optional tooling and uncommitted changes produce DEGRADED.

## Diagnose the repository

Run the human-readable doctor before starting a task:

```shell
scripts/repo-doctor
```

Use JSON when another tool consumes the result:

```shell
scripts/repo-doctor --json
```

The output ends in READY, DEGRADED, or BLOCKED. Each check retains its own
status and a bounded detail field. In a GitButler workspace, the doctor reads
`but status --json` so applied commits are not mistaken for uncommitted files.

## Run the appropriate validation layer

Use the smallest layer that matches the change:

```shell
scripts/check-fast --json
scripts/check-task P1-012 --json
scripts/check-full --json
scripts/check-long P1-012 --json
```

`check-fast` selects manifest commands marked `fast`. `check-task` selects the
named task's non-long acceptance commands. `check-full` delegates to the
existing `scripts/check`. `check-long` is the only entry point that selects
commands marked `long`; P1-012 has none, so it returns SKIPPED with exit 4.

Add `--output PATH` to any command to write its complete machine report by
atomic replacement. Command stdout and stderr are retained under
`build/repository-tooling/`. The report includes bounded excerpts and
truncation flags.

## Verify evidence freshness

Verify one task or every task manifest:

```shell
scripts/verify-evidence P1-012 --json
scripts/verify-evidence --all --json
```

The verifier checks the evidence task, platform, Cangjie/CJPM identity,
acceptance status, report paths and SHA-256 values, and every source digest
listed by the task manifest. A changed report or source returns STALE. Invalid
fields, escaping paths, missing files, and a report whose status is SKIPPED,
BLOCKED, or FAIL return FAIL.

## Task contract reference

Task manifests live at `tools/tasks/<TASK-ID>.json` and use
`tools/tasks/schema-v1.json`. Schema v1 requires:

- task ID and completed dependencies;
- allowed repository paths and supported platforms;
- acceptance command arguments, timeout, gate and long-running marker;
- required evidence paths;
- task timeout and task-level long-running marker;
- source paths whose SHA-256 values bind retained evidence to the code.

Unknown fields and schema versions fail closed. Dependencies must exist in the
backlog and status, have COMPLETE status, and form an acyclic graph.

## Stable exit codes

| Exit | Status | Meaning |
|---:|---|---|
| 0 | PASS or READY | The selected checks passed. |
| 1 | FAIL | A command, report, or evidence contract failed. |
| 2 | INVALID | Arguments or task contracts are invalid. |
| 3 | BLOCKED | A required capability is unavailable. |
| 4 | SKIPPED | The explicit selection contains no runnable command. |
| 5 | STALE | A retained report or source digest changed. |
| 6 | DEGRADED | Optional capability or workspace cleanliness is unavailable. |

## Evidence boundary

The machine reports in this directory record native Linux glibc execution.
The current-toolchain requalification ran `scripts/check-task P1-012` and
`scripts/check-full`; both returned PASS. The task gate validated the 16-path,
12-scenario, 10-test plan and all 17 repository-tooling unit tests. The full
gate delegated to `scripts/check` and returned exit 0.

P1-012 did not run the one-hour SSE profile, the 24-hour soak, or another long
profile. It did not modify runtime, std, stdx, or an SDK, and did not build an
SDK.
