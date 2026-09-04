# M0-025 Windows resource-growth test plan

This plan diagnoses the Windows x86_64 resource growth recorded by M0-011 run
`33705670217`. It first runs bounded mode-isolation probes, then applies only a
Wirestack-owned repair when the evidence identifies one, and finally reruns the
fixed M0-011 four-hour profile. The four-hour profile remains the acceptance
gate. Short diagnostics do not substitute for it.

## Semantics and control-flow paths

| Path ID | Condition | Required behavior | Reachability |
|---|---|---|---|
| P001 | Native Windows x86_64 with the pinned toolchain | Report environment identity and run diagnostics | reachable |
| P002 | Non-Windows, wrong architecture, or missing capability | Return BLOCKED with a stable code | fault injection |
| P003 | One isolated `connect-close`, `echo-close`, `peer-reset`, or `close-during-read` probe | Keep mode, explicit `16,384`-iteration budget, `600`-second timeout, command, and resource samples separate | reachable |
| P004 | Diagnostic process timeout or incomplete result | Record INCOMPLETE; never promote it to PASS | fault injection |
| P005 | Resource trend exceeds the existing M0-011 limit | Record FAIL with the metric and limit | fault injection |
| P006 | Growth is not controlled by Wirestack-owned code | Record an upstream-candidate decision without editing runtime/std | reachable |
| P007 | An in-scope source fix is identified | Add the narrow fix and rerun the native four-hour gate | reachable |
| P008 | Native four-hour rerun | Validate exact revision, duration, workload, measured resources, and no skipped result | reachable |
| P009 | Concurrent or interrupted report publication | Leave one complete JSON file and no temporary residue | fault injection |

## Scenario matrix

| Scenario ID | Trigger | Expected result | Evidence |
|---|---|---|---|
| S001 | `--environment-only` on Windows x86_64 | READY with runner and toolchain identity | environment report |
| S002 | Four mode-isolation diagnostics | Each mode has an independent bounded report | diagnostic-results.json |
| S003 | Missing tool, wrong host, or invalid revision | BLOCKED/FAIL with a stable code | diagnostic report |
| S004 | Diagnostic timeout, missing RESULT, or sampler error | INCOMPLETE/FAIL, never PASS | diagnostic report |
| S005 | Handle/private/RSS/thread/socket growth | Existing limits are applied without change | diagnostic report |
| S006 | Source inspection identifies Wirestack or upstream ownership | Repair decision names the owner and allowed next step | repair-decision.json |
| S007 | Fresh native M0-011 run | Four-hour report is accepted only when all current assertions pass | native-rerun.json |
| S008 | Atomic report write fault injection | Complete old or new report, no partial target | unit output |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Test | Expected result | Type |
|---|---|---|---|---|---|
| T001 | S001,S003 | P001,P002 | Environment and revision capability injection | truthful READY/BLOCKED | unit, fault-injection |
| T002 | S002 | P003 | Mode selection, explicit iteration budget, and bounded command construction | exactly four known modes, budget is not derived from timeout, no shell interpolation | unit |
| T003 | S004,S005 | P004,P005 | Diagnostic report parsing and trend mutation | incomplete/growth reports fail closed | unit, fault-injection |
| T004 | S006 | P006,P007 | Ownership decision and forbidden-path guard | runtime/std cannot be modified or claimed fixed | unit, architecture |
| T005 | S007 | P008 | Exact-revision four-hour result validation | only a complete PASS can close the rerun | integration |
| T006 | S008 | P009 | Atomic JSON publication | one complete report, no temporary residue | unit, fault-injection |
| T007 | S002,S007 | P003,P008 | GitHub `windows-2025` workflow | complete diagnostic artifact; native four-hour rerun only when explicitly dispatched | native-platform |

## Acceptance boundary

M0-025 is COMPLETE only when the diagnostic result, repair decision, and fresh
M0-011 native four-hour report are source-bound and PASS. A diagnostic-only
result, a timeout, or a report with `SKIPPED`, `NOT_RUN`, `INCOMPLETE`, or FAIL
status keeps the task BLOCKED. Existing M0-011 limits are immutable. Mode
diagnostics must use an explicit per-mode budget; the iteration count must not
be inferred from the wall-clock timeout.

The workflow does not run a 24-hour soak, one-hour SSE profile, mobile gate, or
non-Windows native gate.
