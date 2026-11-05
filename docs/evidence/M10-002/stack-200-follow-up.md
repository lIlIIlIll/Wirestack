# M10-002 current-source acceptance follow-up

Current integrated code source is
`1631837216989f7eac6986b24b0b9a2c61d0bd20`. All ten actual selected task
commands pass after real P1-015 and M9-001 qualification. The complete canonical
command also passed at these unchanged production, build, test and manifest
bytes. Overall M10-002 remains BLOCKED: the original strict default-runtime
FD/task-restoration failure is still open. Complete actual outputs and source
identities are in
[`current-source-acceptance.json`](stack-200-review/current-source-acceptance.json).

Earlier #216 failures and reviews remain historical. Their exact reports are
preserved under the `historical-*-e7c4bba5.json` files. The deterministic
maintenance proof remains
[`closure-regressions/proof.json`](stack-200-review/closure-regressions/proof.json).

## Scope and dependency state

M10-002 implements bounded resource ownership and HTTP/2 Q4 outbound DATA admission. For positive stream flow credit, the sender caps the DATA frame to current credit, waits for a suitably sized managed-buffer lease, rechecks credit, then acquires the flow-control permit. A blocked buffer wait holds no flow permit; if SETTINGS reduces credit after the lease is acquired, the lease is released before retry. Zero flow credit waits without retaining a managed buffer. Stream/controller termination cancels pending lease waiters. Classic CONNECT without `:scheme` uses the actual `http` or `https` transport scheme for resource ownership. No public API was added or changed.

The actual current selected task exits 0/PASS, with all ten commands executed
and no timeout. P1-015 completed its original four-gate capture, byte verification
and three-command selected task. M9-001 then completed all six selected task
commands and the independent eighteen-scenario long gate. Direct native smoke
was not substituted for either task.

Owner publication has recovered from GitHub incident `smtdswd1h2w4`.
Shared completion metadata is requalified at the final frozen source with real
exact-revision Linux/Windows receipts and strict predecessor seals, never by
editing an older receipt revision. Repository-wide readiness and historical
M7 release qualification are not promoted.

## Actual selected and canonical evidence

The actual selected full native run passed 1,090 cases with 28 explicit skips
and no error or failure. All five changed-path cases and fifteen retained Q4
cases appear as PASSED in its complete output. Each exact HTTP/2 profile passed
219 cases: FD limit 64, data limit 1 GiB, address-space limit 4 GiB, and affinity
CPU 0. No CPU substitution, processor override or extra heap override was used.

The actual documentation command used its explicit 1 GiB heap and passed all
40 commands in 292.950 seconds, within its original 1,800-second deadline,
with complete symbol and parameter coverage. The earlier full canonical
invocation at the same frozen code passed in 487.303 seconds within its original
7,200-second deadline; no production, build, test or manifest input changed.
All twenty actual selected stdout/stderr projections are under
`stack-200-review/current-selected/`. The earlier twenty-two full diagnostic
outputs remain under `stack-200-review/current-local-diagnostics/`; neither set
is an excerpt-only substitute.

The installed default-runtime consumer's original strict result remains FAIL:
FDs 10 to 10, tasks 14 to 15. Twelve behavioral checks and child exit 0 did not
satisfy resource restoration. A passing default replay and a processor-count
control remain diagnostics, not closure or a substitute acceptance profile.

## Historical acceptance before blocker maintenance

Exact earlier results are in [`historical-current-source-acceptance-e7c4bba5.json`](stack-200-review/historical-current-source-acceptance-e7c4bba5.json), with the matching [`historical matrix`](stack-200-review/historical-scenario-matrix-e7c4bba5.json) and [`historical verification`](stack-200-review/historical-verification-e7c4bba5.json). These files are not current qualification inputs.

| Gate | Historical result |
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

At that earlier source, the full native suite and repository command failed
and the task dependency check was invalid. Those failures remain failures;
the current local successes above do not turn old reports into acceptance.

## Evidence boundaries and PR state

Prior independent reviews reported no findings on earlier PR heads; they are historical and are not a review of the refreshed #216 head. Previous published CI results likewise do not replace this local current-source acceptance.

Keep PR #216 **OPEN and DRAFT**; do not mark it ready or merge it. Keep issue #174 open. Leave #175 open and unchanged; M10-003 has not started. The remaining promotion blocker is the original default-runtime strict resource-restoration failure, not prerequisite readiness or the recovered GitHub incident. Passing replays, processor controls and metadata refresh do not close it.

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
