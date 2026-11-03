# M10-002 current-source acceptance follow-up

The retained acceptance below records the earlier #216 Q4 source and its
failures. Current blocker maintenance is recorded separately in
[`closure-regressions/proof.json`](stack-200-review/closure-regressions/proof.json).
The maintenance source commit is `e05a13910c752417c3782b1d833bb27c761b58fc`;
it is not yet a final integrated acceptance candidate.

## Scope and dependency state

M10-002 implements bounded resource ownership and HTTP/2 Q4 outbound DATA admission. For positive stream flow credit, the sender caps the DATA frame to current credit, waits for a suitably sized managed-buffer lease, rechecks credit, then acquires the flow-control permit. A blocked buffer wait holds no flow permit; if SETTINGS reduces credit after the lease is acquired, the lease is released before retry. Zero flow credit waits without retaining a managed buffer. Stream/controller termination cancels pending lease waiters. Classic CONNECT without `:scheme` uses the actual `http` or `https` transport scheme for resource ownership. No public API was added or changed.

The M10-002 task gate is `INVALID` (exit 2, `commands: []`) because its declared dependency M9-001 is BLOCKED. M9-001 is blocked by P1-015. The P1-012 validator fix is now in the local #216 ancestry, so the task check reaches M9-001 rather than the former plan-only prerequisite mismatch. Repository-wide `validate-tasks` is also `INVALID` (exit 2, no task IDs) at `M10-001 dependency is not COMPLETE: M9-001`.

Related task-status edges were refreshed without marking blocked tasks complete.
M12-002 and M10-003 / #175 remain BLOCKED. P1-012 task acceptance and a
source-bound seal may PASS independently of global readiness when its own
complete dependency closure passes. Its current qualification must still be
regenerated; the historical global-readiness failure is not a PASS seal input.

## Retained acceptance before blocker maintenance

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

## Deterministic admission maintenance

The pool now retains the outstanding waiter ID across off-lock connection
discard. Only a successful reuse or reservation grants and removes that turn;
exception cleanup has one scalar owner. The existing admission queue policy
and the buffer-lease-before-flow-permit ordering are unchanged.

A closed resource ledger now wins over cancellation or deadline for admission
that has not completed. Open-ledger context semantics remain unchanged.
The client regression waits for actual connector entry and aggregate queueing,
checks structured `Closed` coordinates, joins both workers and verifies zero
request, connection and waiter counts.

The new pool interleaving failed before the production repair with zero
retained waiters and same-key refill taking the slot first. The closed-ledger
regression also failed before repair, while the open-ledger cancellation
control passed. After repair, the pool, resource-budget and client-extension
classes passed 23, 15 and 5 cases respectively with no errors or failures.
Filter-excluded cases were not executed and are not qualification passes.
Typed source and normalized log digests are retained in the proof report.

These results prove the two specific defects. They do not identify which
interleaving caused each historical full-suite failure and do not replace
final integrated full-suite, installed-consumer, dependency or evidence gates.
M10-002 remains BLOCKED pending those gates. No coverage or mutation claim is
made.
