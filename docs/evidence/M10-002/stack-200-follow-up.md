# M10-002 current-source acceptance follow-up

This report records the current #216 Q4 source and its acceptance blockers. The P1-012 dependency-scope correction from PR #220 is integrated into the local #216 ancestry; #220 remains a separate draft PR and no merge is claimed. The tested production-source revision is `e7c4bba5faf568317edd580e26eef118cc59057d`; later changes in this follow-up update evidence and task-status records only.

## Scope and dependency state

M10-002 implements bounded resource ownership and HTTP/2 Q4 outbound DATA admission. For positive stream flow credit, the sender caps the DATA frame to current credit, waits for a suitably sized managed-buffer lease, rechecks credit, then acquires the flow-control permit. A blocked buffer wait holds no flow permit; if SETTINGS reduces credit after the lease is acquired, the lease is released before retry. Zero flow credit waits without retaining a managed buffer. Stream/controller termination cancels pending lease waiters. Classic CONNECT without `:scheme` uses the actual `http` or `https` transport scheme for resource ownership. No public API was added or changed.

The M10-002 task gate is `INVALID` (exit 2, `commands: []`) because its declared dependency M9-001 is BLOCKED. M9-001 is blocked by P1-015. The P1-012 validator fix is now in the local #216 ancestry, so the task check reaches M9-001 rather than the former plan-only prerequisite mismatch. Repository-wide `validate-tasks` is also `INVALID` (exit 2, no task IDs) at `M10-001 dependency is not COMPLETE: M9-001`.

Related task-status edges were refreshed without marking blocked tasks complete. The evolution-task status graph now has the expected issue links and BLOCKED classifications; `python3 -m unittest tools.tests.test_m7_linux_task_graph -v` passes all 6 tests. M12-002 remains BLOCKED because M9-001 is incomplete. P1-012 remains BLOCKED because current global readiness is not established. M10-003 / #175 remains BLOCKED and unchanged.

## Current-source acceptance

Detailed machine-readable results: [`current-source-acceptance.json`](stack-200-review/current-source-acceptance.json). The updated scenario matrix and verification summary are [`scenario-matrix.json`](stack-200-review/scenario-matrix.json) and [`verification.json`](stack-200-review/verification.json).

| Gate | Current result |
|---|---|
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS. |
| `python3 tools/check_network_capabilities.py --check` | Exit 0; 86 contract rows pass. Native capability evidence is NOT_RUN; no platform qualification claim. |
| `cjpm check` / `cjpm build` | Both exit 0; PASS with the pinned AWS-LC 5.5.0 source. |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` | FAIL in two runs. Run 1: 1,085 passed, 28 skipped, 1 error, 0 failures (1,114 total); HTTP/2 connection-pool waiter refill timed out. Run 2: 1,085 passed, 28 skipped, 0 errors, 1 failure; stalled connector admission expected `secondRejected == true`. Each exact failing test passed in isolated replay; isolated passes do not replace the full-suite gate. |
| HTTP/2 resource profiles | RLIMIT_NOFILE=64, RLIMIT_DATA=1 GiB, RLIMIT_AS=4 GiB, and CPU affinity 0 each pass 219/219. |
| Strict generated documentation | Exit 0; cjdoc 0.7.2; 1,873/1,873 symbols and 950/950 parameters. Generated docs digest: `5cc77ecbb5432b68e71062e41a8744341f859ca19d43fb2179ff020044b3a099`. |
| `scripts/check` | FAIL, exit 1: 584 tests, 24 failures, 16 errors, 4 skipped. Families: M0-016 stale AWS-LC advisory disposition (19 failures, 6 errors); M3-031 desktop-provider fixture/validation-order issues (4 failures, 2 errors); M7-030 missing frozen release artifact (8 errors); M12-002 stale platform-support source digest (1 failure). The M7 task-graph tests pass after status-edge correction. |
| `scripts/check-task M10-002 --json` | INVALID, exit 2, no commands; direct dependency M9-001 is not COMPLETE. |
| Repository `validate-tasks` | INVALID, exit 2, no task IDs; M10-001 dependency M9-001 is not COMPLETE. |

The current task gate cannot complete, and the full native suite and repository-wide check fail. M10-002 remains **BLOCKED** despite the successful architecture, build/check, strict-doc, and constrained-resource gates. The exact current commands, statuses, failure names, and dependency details are in the machine-readable report above.

## Evidence boundaries and PR state

Prior independent reviews reported no findings on earlier PR heads; they are historical and are not a review of the refreshed #216 head. Previous published CI results likewise do not replace this local current-source acceptance.

Keep PR #216 **OPEN and DRAFT**; do not mark it ready or merge it. Keep issue #174 open. Leave #175 open and unchanged; M10-003 has not started. Refresh the #216 description with the current report links and blockers. Reassess readiness only after M9-001 and all required acceptance gates are complete on the exact candidate.
