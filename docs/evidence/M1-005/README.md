# M1-005 Linux operation-context evidence

## Status

- Task: `M1-005`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

This task qualifies the `OperationContext` composition and derivation contract
from TR-CTX-001 through TR-CTX-005 for the Linux profile.

## Dependencies

- M1-003 proves monotonic absolute Deadline behavior and child-budget capping.
- M1-004 proves cancellation registration, removal, already-cancelled fast
  failure, and exactly-once callback races.

## Acceptance mapping

| Criterion | Evidence | Result |
|---|---|---|
| One immutable input carries the operation state | `OperationContext` exposes read-only optional Deadline, cancellation token, optional trace, and optional event sink fields. | PASS |
| Background work has explicit defaults | `backgroundHasNoDeadlineCancellationOrTrace` proves there is no Deadline, trace, event sink, cancellation request, or expired budget. | PASS |
| Relative child budgets cannot extend a parent | `shortenDeadline` delegates to the M1-003-qualified `Deadline.child`; `derivationHelpersChangeOnlyTheirNamedField` observes an earlier child expiry. | PASS |
| Absolute child budgets cannot extend a parent | `earlierDeadlineCannotBeExtended` retains the parent for a later candidate and accepts an earlier candidate. | PASS |
| Derivation changes only the requested field | `derivationHelpersChangeOnlyTheirNamedField` covers cancellation replacement, trace removal, event-sink removal, relative shortening, and absolute shortening while the other values remain observable. | PASS |
| Pre-cancelled work has no network side effect | `MemoryTransportTest.cancelledBeforeOperationHasNoDataSideEffect` rejects the write as `Cancelled`; the peer then observes EOF without receiving data. | PASS |
| Cancellation cleanup has one owner | `OperationContext` retains the M1-004-qualified token and does not create a second registration, timer, or waiter owner. Per-operation cleanup remains enforced by M1-008 and later operation tests. | PASS |

This task adds the missing derivation-helper contract test. The production
implementation already met the contract and did not change.

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='OperationContextTest.*,MemoryTransportTest.cancelledBeforeOperationHasNoDataSideEffect' \
  --no-color --no-progress
```

Result: 6 `OperationContextTest` cases and the pre-cancelled MemoryTransport
case passed. Project totals were 7 passed, 560 skipped, 0 failed, and 0 errors.
Exit status 0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository tool tests, 114 gate
tool tests, 23 benchmark tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. Non-performance Cangjie totals were 547 passed, 20 skipped, 0
failed, and 0 errors. The existing compiler warnings for `metrics`,
`waitUntilAcceptActive`, and `waitUntilWaiters` remain unrelated to M1-005.

## Scope limits

- No public declaration or production behavior changed.
- No runtime, std, or SDK source was modified.
- No SDK component was built.
- Runtime and std enhancements remain optional future work, not a Wirestack
  release dependency.
- Non-Linux platforms were not executed.
