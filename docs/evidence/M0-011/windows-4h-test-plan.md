# M0-011 Windows four-hour supplemental test plan

This plan covers the native Windows x86_64 supplemental profile for
GATE-NET-06. The profile runs the mixed lifecycle workload for exactly four
hours on a GitHub `windows-2025` runner and records bounded process-resource
trends. It does not replace the PRD's 24-hour Linux release-candidate soak or
the remaining native-platform requirements.

## Semantics and control-flow path matrix

| Path ID | Conditions | Required behavior | Reachability |
|---|---|---|---|
| P001 | native Windows x86_64, Cangjie and Win32 probes available | environment is READY | reachable |
| P002 | non-Windows, wrong architecture, missing tool or stale SHA | return BLOCKED/FAIL; never PASS | reachable error |
| P003 | four-hour mixed lifecycle workload | exact duration and non-zero completed iterations | reachable |
| P004 | process resource sampler | RSS, private bytes, handles, threads and sockets are measured | reachable |
| P005 | end-to-end resource trend | first/last steady windows stay within explicit bounds | reachable |
| P006 | malformed, short, skipped or globally promoted report | strict validator rejects it | reachable error |
| P007 | atomic report publication | one complete JSON file and no temporary residue | reachable |

## Scenario matrix

| Scenario ID | Trigger | Expected result | Evidence |
|---|---|---|---|
| S001 | `--environment-only` on `windows-2025` | READY with runner/toolchain identity | environment JSON |
| S002 | `--run --duration-seconds 14400` | mixed `connect-close`, `echo-close`, `peer-reset` and `close-during-read` cycles complete; the Windows probe reports `gcEvery=256` | long report |
| S003 | process exits early, timeout or server error | FAIL; no partial result is promoted to PASS | process/workload fields |
| S004 | Win32/PowerShell/netstat query unavailable | BLOCKED/FAIL; metric is not reported as measured | sampler errors |
| S005 | RSS, private, handle, thread or socket growth | FAIL when the explicit trend bound is exceeded | trend object |
| S006 | stale SHA, wrong schema, `SKIPPED`, `NOT_RUN` or global PASS claim | FAIL with stable validator code | validation JSON |
| S007 | interrupted/competing report write | target remains old or complete; no temporary file remains | atomic-write test |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Test | Expected result | Type |
|---|---|---|---|---|---|
| T001 | S001 | P001,P002 | environment identity and missing-capability injection | truthful READY/BLOCKED | unit,fault-injection |
| T002 | S002,S003 | P003 | workload report validation, including the required Windows GC cadence | four-hour PASS only after exact bounded checks | unit |
| T003 | S004,S005 | P004,P005 | sampler coverage and trend mutations | measured metrics pass; missing/growth fails | unit,fault-injection |
| T004 | S006 | P006 | unknown schema, stale SHA, short duration, SKIPPED and global-claim mutations | stable FAIL codes | fault-injection |
| T005 | S007 | P007 | atomic JSON write | one complete file, no temp residue | unit,fault-injection |
| T006 | S002 | P003 | hosted Windows workflow | native four-hour report and raw artifacts | native-platform |

## Acceptance boundary

The report may claim `status=PASS` only for the Windows four-hour supplemental
profile. It must retain `global_gate_status=INCOMPLETE` and explicit non-claims.
The profile cannot close M0-011, M0-012, or the six-platform release matrix.

The four-hour run is the only long gate in this task. No one-hour SSE profile,
86,400-second Linux soak, mobile device gate, or non-Windows native gate is
run by this profile.
