# Use the repository control plane

Status: **BLOCKED**

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

- task ID and declared dependencies (COMPLETE for a task-specific check);
- allowed repository paths and supported platforms;
- acceptance command arguments, timeout, gate and long-running marker;
- required evidence paths;
- task timeout and task-level long-running marker;
- source paths whose SHA-256 values bind retained evidence to the code.

Dependency IDs must exist in the backlog and status, and all manifests must
form an acyclic graph. `validate-tasks`, `check-fast`, `check-full`, and
`verify-evidence --all` are repository-wide gates: any incomplete declared
dependency makes them fail before acceptance commands or evidence are
processed. An optional task ID does not narrow a global fast/full check.

A task-specific `check-task`, `check-long`, or `verify-evidence TASK` checks
only that task's transitive dependency closure; unrelated blocked tasks do not
invalidate the selected task. Structural manifest validation remains global.

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

The current `scripts/check-task P1-012 --json` passes: the plan has 18 paths,
17 scenarios, and 15 tests; all 44 repository-tooling tests pass. The exact
task report and plan validation are retained in
[`task-check.json`](task-check.json) and
[`test-plan-validation.json`](test-plan-validation.json).

Repository-wide readiness is BLOCKED because M10-004 depends on incomplete
M10-003. A separate draft change (PR #230) records M10-004 as BLOCKED instead
of COMPLETE and claims no acceptance; that correction resolves the misleading
status record but does not complete M10-003. `validate-tasks` and global fast/full checks return INVALID (exit 2)
before selecting or executing commands; `verify-evidence --all` returns FAIL
(exit 1) on the same dependency. The reports are linked from
[`global-readiness.json`](global-readiness.json). P1-012 remains BLOCKED; no
current PASS evidence seal is claimed. The active
[`evidence.json`](evidence.json) records BLOCKED, and
[`evidence-unqualified-2026-10-19.json`](evidence-unqualified-2026-10-19.json)
records provenance for the former PASS index, bound to unpublished revision
`8beeed24620452e0b8101c0375e1494b73e0de6e`. The original index remains in
earlier PR history and is not current evidence.

A selected `verify-evidence P1-012` also returns FAIL with
`ACCEPTANCE_NOT_PASS`; the BLOCKED marker cannot be treated as a current seal.

The M12-003 reproduction in
[`dependency-scope-reproduction.json`](dependency-scope-reproduction.json) and
[`m12-003-after.json`](m12-003-after.json) is historical: at that revision 47
fault-contract tests passed with one environment-gated skip, while its
source-bound evidence verifier failed on drift in
`tools/gates/m12_003_resources.py`. On the current tree the selected M12-003
closure reaches BLOCKED P1-012 through P1-013, so
[`m12-003-current.json`](m12-003-current.json) returns INVALID with
`P1-013 dependency is not COMPLETE: P1-012`; M12-003 remains BLOCKED. The
deliberately blocked M10-004 selection in
[`blocked-dependency-smoke.json`](blocked-dependency-smoke.json) rejects its own
incomplete M10-003 dependency.

[`full-check.json`](full-check.json) is the unchanged historical 2026-09-01 PASS receipt.
[`full-check-pre-strict-global-readiness.json`](full-check-pre-strict-global-readiness.json)
summarizes an earlier pre-fix run (584 tests, 25 failures, 16 errors, 4 skips);
the original report remains in earlier PR history, not current qualification.
The current full check is
[`full-check-current.json`](full-check-current.json): it returns INVALID before
delegating to `scripts/check`. No current repository-wide full PASS is claimed.

P1-012 did not run the one-hour SSE profile, the 24-hour soak, or another long
profile. It did not modify runtime, std, stdx, or an SDK, and did not build an
SDK.
