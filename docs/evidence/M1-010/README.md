# M1-010 Linux DuplexTransport contract evidence

- Task: `M1-010`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Paths and scenarios | Evidence |
|---|---|---|
| Read and partial-write contract | P001 bounded `readSome`/`writeSome` progress in both directions | `pairTransfersPartialDataInBothDirections`; full StdNet and TLS transport suites |
| Duplex concurrency | P002 one read and one write may overlap; P003 a second operation in either direction fails with `ConcurrentOperation` | `operationClaimsAllowDuplexButRejectSameDirectionConcurrency`; `StdNetTransportTest.concurrentReadsFailWithoutDisturbingTheActiveRead`; `TlsConnectionTest.oneReadAndOneWriteMayOverlapButSecondReadFailsImmediately` |
| Empty buffers and EOF | P004 empty read is `Data(0)` before and after peer FIN; P005 empty write returns zero and creates no peer data; only a non-empty peer read observes `EndOfStream` | `emptyBuffersReturnZeroWithoutProducingEofOrPeerData` |
| Directional shutdown | P006 write shutdown retains reads and drains buffered data before EOF; P007 read shutdown retains local writes and gives the peer `BrokenPipe` | `writeShutdownProducesPeerEofAfterBufferedData`, `readShutdownMakesPeerWritesFailAsBrokenPipe`, lifecycle half-close tests |
| Distinct terminal evidence | P008 pre-cancellation and expired deadline fail before data mutation; P009 local close wakes a read as `Closed`, never peer EOF | `cancelledBeforeOperationHasNoDataSideEffect`, `expiredDeadlineFailsBeforeAnyWrite`, `cancellationWakesABlockedRead`, `closeWakesABlockedLocalRead` |
| Close and abort | P010 graceful close and immediate abort publish one retained terminal state and release both directions once | `closeAndAbortAreIdempotentAndTerminal`; M1-009 terminal race and cleanup tests |

`TransportLifecycle.beginRead` and `beginWrite` validate direction state and
claim the operation under the same mutex. This prevents a state transition from
racing between validation and the same-direction concurrency claim. Read and
write claims remain independent. These claim methods are package-internal and
do not expand Wirestack's public API inventory.

`MemoryTransport` now uses the shared lifecycle instead of parallel local
closed, aborted, half-close and operation-active flags. Terminal pipe cleanup
runs through the M1-008 exactly-once cleanup registry after the lifecycle lock
is released.

## Commands and results

Focused tests:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter TransportLifecycleTest,MemoryTransportTest \
  --no-color --no-progress
```

Result: exit `0`; `TransportLifecycleTest` passed `10/10` and
`MemoryTransportTest` passed `11/11`. Project summary: `PASSED 21`,
`SKIPPED 455`, `FAILED 0`, `ERROR 0`.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit `0`. Python suites passed `50/50`, `84/84` and `8/8`;
architecture guard, `cjpm check`, `cjpm build` and all Cangjie tests passed.
The Cangjie summary was `PASSED 476`, `SKIPPED 0`, `FAILED 0`, `ERROR 0`.
The build retained one pre-existing unused-function warning for
`waitUntilWaiters` in `src/internal/http1/connection_pool.cj`.

The first sandboxed focused-test attempt exited `1` before executing tests
because the unittest runner could not create its local control socket
(`Operation not permitted`). The identical command passed in the authorized
environment; no product-code workaround was made.

## Compatibility classification

The declaration diff classifier reports the new lifecycle claim methods and
the removed MemoryTransport-local fields/helpers conservatively as
incompatible. The claim methods are `internal`, and every removed declaration
is `private`; the `DuplexTransport` signatures are unchanged. Therefore the
public API and source-compatibility surface is unchanged. The classifier's
private-declaration removals are a known declaration-parser overclassification;
the architecture, inventory, build and semantic gates above passed.

## Scope boundary

This is Linux task completion, not six-platform release completion. The public
internal interface signature is unchanged; its TR-STREAM-001 through 007
behavior is now documented and enforced by the shared lifecycle plus concrete
transport tests. `StdNetTransport` retains its adapter-specific native close
and wakeup fields; its observable contract is covered by the canonical gate,
while structural adapter consolidation remains transport-adapter work rather
than part of this core contract task.
