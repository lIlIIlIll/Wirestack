# P1-012 AI-friendly repository infrastructure test plan

## Scope and acceptance boundary

This plan covers repository diagnostics, machine-readable task contracts,
layered validation entry points, and fail-closed evidence freshness checks. It
does not run or qualify any long-duration profile, build the Cangjie SDK, or
change product networking behavior.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Repository platform, required tools, Cangjie/CJPM and required capabilities are available | Doctor reports READY |
| P002 | A required capability is absent | Doctor reports BLOCKED and exits nonzero |
| P003 | Only an optional capability or clean-worktree condition is absent | Doctor reports DEGRADED without claiming PASS |
| P004 | Task manifest uses schema v1, safe repository-relative paths and complete typed fields | Contract is accepted |
| P005 | Manifest has an unknown schema/field, missing task, escaping path or invalid timeout | Contract fails closed |
| P006 | Declared dependencies are present in backlog/status and acyclic | Dependency graph is accepted |
| P007 | A dependency is absent or manifests form a cycle | Contract validation fails closed |
| P008 | Fast/task/full validation selects only non-long commands | Selected commands execute with bounded capture and stable status/exit |
| P009 | A long command is reachable from fast/full or a task command has inconsistent long metadata | Validation rejects the contract before execution |
| P010 | Long validation explicitly selects a task's long commands | Only long commands execute; no implicit fallback |
| P011 | A report is written | Temporary file is flushed and atomically replaced; no partial target is exposed |
| P012 | Evidence index fields, task/platform/toolchain, report digests and source digests match | Freshness reports PASS |
| P013 | Evidence/report is missing, malformed, path-escaping, digest-stale or source-drifted | Freshness reports FAIL or STALE and exits nonzero |
| P014 | Evidence or acceptance reports SKIPPED/BLOCKED as successful | Freshness rejects the false PASS |
| P015 | Human output is selected | Output is bounded and names terminal status plus failed checks |
| P016 | `--json` or `--output` is selected | One schema-stable machine report is emitted or atomically stored |

## Input domains and state

- Task IDs: valid `P1-012`, syntactically invalid, well-formed but absent, and
  dependency-only IDs.
- Paths: valid repository-relative files, missing paths, directories, absolute
  paths, `..` escapes, and symlink escapes.
- Schemas: current version, unknown version, unknown field, wrong type, missing
  required field, duplicate command ID, and cyclic dependency graph.
- Commands: PASS, nonzero FAIL, timeout, missing tool, SKIPPED, fast/full
  command, and explicitly long command.
- Evidence: current digest, malformed digest, changed report, changed source,
  missing report, wrong source task/platform/toolchain, and non-PASS acceptance.
- Report state: absent target, existing target, injected pre-replace failure,
  and successful atomic replacement.

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|
| S001 | Supported Linux host with Cangjie/CJPM and required tools | P001,P015,P016 | Doctor reports READY when clean, or DEGRADED only for explicitly named optional/worktree findings | Assert typed checks, bounded detail and stable status/exit mapping | normal,platform | P0 |
| S002 | Required tool absent and optional capability absent | P002,P003 | Required absence is BLOCKED; optional absence is DEGRADED | Assert no missing capability is represented as PASS | error | P0 |
| S003 | Valid P1-012 schema-v1 manifest aligned with backlog/status | P004,P006 | Contract validation passes | Assert ID, dependency, path, platform, evidence, timeout and long attributes | normal | P0 |
| S004 | Unknown schema/field, missing task, path escape or invalid timeout | P005 | Validation fails before command execution | Assert stable INVALID result and exact structured issue code | boundary,error | P0 |
| S005 | Missing dependency and two manifests with a dependency cycle | P007 | Validation fails closed | Assert missing ID or cycle members are reported | error,regression | P0 |
| S006 | Fast, task and full selection over mixed command metadata | P008,P009 | Fast/full never select long commands and malformed long placement is rejected | Assert selected command IDs and zero long executions | safety,regression | P0 |
| S007 | Explicit long selection for a task with or without long commands | P010 | Only declared long commands run; no-long task returns stable SKIPPED | Assert command inventory and exit code | boundary | P1 |
| S008 | PASS/nonzero/timeout command through shared command runner | P008,P015,P016 | Result, duration, bounded excerpts and full log paths are retained | Assert stable exit mapping and truncation flags | normal,error | P0 |
| S009 | Existing report with injected failure before replace, followed by success | P011 | Existing report survives failure; success atomically replaces it | Assert old bytes remain then complete JSON appears | fault-injection | P0 |
| S010 | Current P1-012 evidence index and unchanged files | P012 | Single-task and `--all` freshness checks PASS | Assert report SHA, source SHA, task/platform/toolchain and acceptance PASS | normal | P0 |
| S011 | Escaping/missing report, stale report digest or changed source | P013 | Check returns FAIL for contract faults or STALE for drift | Assert no old PASS is reused and affected path is named | boundary,regression | P0 |
| S012 | Evidence index or acceptance report says SKIPPED while summary says PASS | P014 | Check fails closed | Assert SKIPPED cannot satisfy PASS | security,regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002 | P001,P002,P003,P015,P016 | Injected doctor probes | READY/BLOCKED/DEGRADED are truthful | Assert severity aggregation, stable exit and JSON fields | unit,fault-injection |
| T002 | S003,S004 | P004,P005 | Valid manifest plus unknown schema/field, path escape and bad timeout | Valid passes; invalid cases fail closed | Assert structured validation issue codes | unit,boundary |
| T003 | S004,S005 | P005,P006,P007 | Missing task/dependency and cyclic temporary manifests | INVALID | Assert missing IDs and cycle chain | unit,fault-injection |
| T004 | S006,S007 | P008,P009,P010 | Mixed fast/full/long commands | Long never enters fast/full; explicit long is isolated | Assert selected command IDs and SKIPPED no-long result | unit,safety |
| T005 | S008 | P008,P015,P016 | PASS, nonzero and oversized-output subprocesses | Stable result and bounded report | Assert exit/status map, truncation and retained log | unit,boundary |
| T006 | S009 | P011 | Injected atomic-write failure | No partial report replacement | Assert byte-for-byte preservation and later valid JSON | unit,fault-injection |
| T007 | S010,S011 | P012,P013 | Current evidence, stale digest, missing/escaping report and source drift | PASS then STALE/FAIL | Assert drift category and nonzero exit | unit,regression |
| T008 | S012 | P014 | SKIPPED acceptance disguised by PASS summary | FAIL | Assert successful acceptance requires every report PASS | unit,security |
| T009 | S003,S006,S010 | P004,P006,P008,P012 | Public scripts against repository P1-012 | Task check and freshness check PASS | Assert machine reports and stable zero exits | integration |
| T010 | S001,S006,S008 | P001,P008,P009,P015 | `scripts/check-fast` and `scripts/check-full` | Both exclude long profiles; full delegates to existing `scripts/check` | Assert command inventory and no soak/profile command | integration |

## Evidence boundary

The checked-in task report will describe only commands run for P1-012 on the
native Linux glibc host. A digest change or source drift invalidates that PASS.
The one-hour SSE profile, 24-hour soak, and all other explicitly long gates are
outside this task and must remain unexecuted.

## Coverage gaps

The tests inject subprocess, filesystem, manifest and probe failures without
changing the host SDK or operating system. Native non-Linux behavior, hostile
filesystem races outside the repository owner, and actual long-duration gate
execution remain unverified by P1-012.
