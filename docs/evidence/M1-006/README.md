# M1-006 Linux trace-context evidence

## Status

- Task: `M1-006`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

M1-006 qualifies the trace context and structured event entry required by PRD
section 20 on Linux.

## Dependency

M1-001 is complete. Its evidence confirms that Transport Core is a physical
package with co-located tests and enforced dependency boundaries.

## Acceptance mapping

| Criterion | Evidence | Result |
|---|---|---|
| Trace identifiers are read-only and bounded | `NetworkTraceContext` exposes `traceId` and `spanId` as public `let` fields. `traceIdentifiersAreBoundedAndNonEmpty` accepts both identifiers at 128 characters and rejects an empty trace ID or either identifier above the limit. | PASS |
| Trace values propagate without mutation | `derivedContextRetainsCancellationAndTrace`, `derivationHelpersChangeOnlyTheirNamedField`, and `derivedContextsRetainEventSinkAndSinkFailuresAreIsolated` observe the caller-provided trace after context derivation and event delivery. | PASS |
| Events are disabled by default | `OperationContext.background()` stores no trace or event sink. `emitNetworkEvent` takes the `None` branch without calling user code. | PASS |
| The default path stays cheap | The M1-027 Linux profile measures the no-Deadline, no-cancellation, no-trace, no-event-sink fast path. Empty `readSome` P50 is 92.110 ns and the formal five-payload GATE-NET-05 comparison passes. The profile does not claim expression-level managed allocation counts. | PASS |
| Events do not carry sensitive protocol data | `NetworkEvent` has typed kind, outcome, trace, phase, error code, and connection ID fields. It has no header, URL, body, key, secret, certificate, or arbitrary-message field. | PASS |
| Sink failures cannot change I/O completion | `derivedContextsRetainEventSinkAndSinkFailuresAreIsolated` delivers one traced event and proves that an exception from a user sink does not escape. | PASS |

The implementation already met the task contract. This task adds the missing
span-ID boundary case and durable Linux evidence.

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='OperationContextTest.*' --no-color --no-progress
```

Result: all 6 `OperationContextTest` cases passed. Project totals were 6 passed,
561 skipped, 0 failed, and 0 errors. Exit status 0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository tool tests, 114 gate
tool tests, 23 benchmark tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. Non-performance Cangjie totals were 547 passed, 20 skipped, 0
failed, and 0 errors. The existing compiler warnings for `metrics`,
`waitUntilAcceptActive`, and `waitUntilWaiters` remain unrelated to M1-006.

## Scope limits

- No public declaration or production behavior changed.
- No runtime, std, or SDK source was modified.
- No SDK component was built.
- Runtime and std enhancements are optional future work, not Wirestack release
  dependencies.
- Non-Linux platforms were not executed.
