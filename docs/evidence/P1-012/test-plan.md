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
| P006 | Declared dependency IDs exist in backlog/status and the complete manifest graph is acyclic | Contract validation accepts the structural graph |
| P007 | A dependency is absent or manifests form a cycle | Contract validation fails closed |
| P017 | A requested task has a complete transitive dependency closure while unrelated tasks may remain blocked | The selected task is not rejected by unrelated dependency state |
| P018 | Repository-wide validation or check runs while any declared dependency is incomplete | Global mode returns INVALID before selecting or executing acceptance commands |
| P019 | An explicit task ID accompanies a repository-wide fast/full check | Repository-wide dependency strictness is unchanged and the supplied ID is still validated |
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
| S013 | Requested task has a COMPLETE transitive dependency closure; unrelated task has a BLOCKED dependency | P006,P017 | Only the requested task's dependency closure determines dependency readiness | Assert selected task passes; selecting the blocked task fails with DEPENDENCY_INCOMPLETE | boundary,regression | P0 |
| S014 | An unrelated manifest has a BLOCKED dependency; invoke global and selected-task modes | P006,P017,P018 | Global validation/check/all-task evidence reject before command execution; selected-task readiness depends only on its transitive closure | Assert global modes report DEPENDENCY_INCOMPLETE with no command results; selected task passes only with a complete closure | global-readiness,regression | P0 |
| S015 | Invoke the real task-check CLI with `check task TEST-001 --json --output receipt` for a selected task while an unrelated task has a BLOCKED dependency | P006,P016,P017 | The selected command executes and the receipt records PASS without running the unrelated task | Assert CLI exit, receipt status, selected command output, and absent unrelated-command marker | integration,regression | P0 |
| S016 | The selected task's dependency exists only in the backlog and status with COMPLETE, or a transitive plan-only leaf is BLOCKED; a dependency-only ID appears in planning rows without a manifest | P006,P017 | A COMPLETE plan-only leaf satisfies the selected closure; a BLOCKED plan-only leaf rejects the selected task | Assert selected acceptance and DEPENDENCY_INCOMPLETE detail naming the leaf | boundary,regression | P0 |
| S017 | The selected task's own evidence is current (source-bound PASS evidence for the selected task) while an unrelated task has a BLOCKED dependency | P012,P017,P018 | Selected-task freshness passes while repository-wide freshness rejects before selecting tasks | Assert PASS for the selected task and FAIL with zero task results globally | regression,security | P0 |
| S018 | Fast/full check invoked with an unknown ID, and with a known ID whose repository graph is invalid | P018,P019 | An unknown ID is rejected as TASK_MISSING; a known ID leaves the global dependency verdict unchanged | Assert TASK_MISSING detail names the ID, and assert the known-ID run reports the same global DEPENDENCY_INCOMPLETE with zero commands | boundary,regression | P0 |
| S007 | Explicit long selection for a task with or without long commands | P010 | Only declared long commands run; no-long task returns stable SKIPPED | Assert command inventory and exit code | boundary | P1 |
| S008 | PASS/nonzero/timeout command through shared command runner | P008,P015,P016 | Result, duration, bounded excerpts and full log paths are retained | Assert stable exit mapping and truncation flags | normal,error | P0 |
| S009 | Existing report with injected failure before replace, followed by success | P011 | Existing report survives failure; success atomically replaces it | Assert old bytes remain then complete JSON appears | fault-injection | P0 |
| S010 | A valid source-bound evidence index and unchanged candidate files | P012 | Selected-task freshness check passes | Assert report/source digests, task/platform/toolchain, and PASS acceptance match | normal | P0 |
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
| T009 | S003,S006,S014 | P004,P006,P008,P018 | Public scripts against P1-012 with M10-004 → M10-003 incomplete | Task check passes; global validation, fast/full, and all-task evidence fail before execution | Assert task PASS and global DEPENDENCY_INCOMPLETE with no selected commands; current evidence remains BLOCKED | integration,regression |
| T010 | S001,S006,S008,S014 | P001,P008,P009,P015,P018 | `scripts/check-fast` and `scripts/check-full` with ready and incomplete dependency graphs | Ready graph excludes long commands; incomplete graph fails before selection; full delegates only after readiness passes | Assert no soak/profile command and zero command results on dependency failure | integration |
| T011 | S013 | P006,P017 | Temporary manifests with unrelated and transitive incomplete dependencies | Selected task passes only when its full dependency closure is COMPLETE | Assert unrelated BLOCKED dependency does not reject selected task; transitive BLOCKED dependency is rejected | unit,regression |
| T012 | S014 | P006,P017,P018 | Temporary manifests with a blocked unrelated dependency | `validate-tasks`, fast/full, and all-task evidence reject; selected-task checks retain closure scope | Assert global invalidity and zero commands, plus selected-closure behavior | unit,integration,regression |
| T013 | S015 | P006,P016,P017 | Temporary manifests with a COMPLETE selected closure and unrelated BLOCKED closure | Actual CLI writes a PASS receipt and executes only selected commands | Assert exit 0, command log content, and no unrelated marker | integration,regression |
| T014 | S016 | P006,P017 | Temporary manifests whose selected closure ends in a plan-only dependency ID | COMPLETE plan-only leaf accepted; BLOCKED plan-only leaf rejected | Assert selected validation passes and DEPENDENCY_INCOMPLETE names the leaf | unit,regression |
| T016 | S018 | P018,P019 | Fast/full selection with an unknown task ID and with a known ID over a blocked unrelated graph | Unknown ID fails before execution; known ID keeps repository-wide rejection | Assert real CLI exit 2, receipt mode/task_id/issues, and no command results | unit,integration,regression |
| T015 | S017 | P012,P017,P018 | Current source-bound evidence for the selected task and an unrelated blocked task | Selected freshness passes while global freshness rejects | Assert PASS status for one task and FAIL with empty task results globally | unit,regression |

## Evidence boundary

The checked-in task report covers only P1-012's selected task commands on the
native Linux glibc host. Global readiness is recorded separately; the active
evidence index is BLOCKED and is not a PASS seal. A digest change or source
drift invalidates any future PASS seal.
The one-hour SSE profile, 24-hour soak, and all other explicitly long gates are
outside this task and must remain unexecuted.

## Coverage gaps

The tests inject subprocess, filesystem, manifest and probe failures without
changing the host SDK or operating system. Native non-Linux behavior, hostile
filesystem races outside the repository owner, and actual long-duration gate
execution remain unverified by P1-012.
