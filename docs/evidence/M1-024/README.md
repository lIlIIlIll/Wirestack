# M1-024 Linux deterministic Transport race evidence

## Status

- Task: `M1-024`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**
- Date: 2026-08-28, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

The focused cases and canonical repository gate pass.

## Dependencies

M1-013 through M1-023 have retained Linux evidence. The relevant contracts are
the bounded `MemoryTransport`, deterministic `ScriptedTransport` and
`VirtualWaiter`, exactly-once completion, serialized lifecycle, public
`StdNetTransport` fallback, stable errors and transport diagnostics.

## Semantics

One read and one write may run concurrently. Close, abort, cancellation and
successful completion must select one observable result for each operation.
Every terminal path must wake blocked work, remove its waiter and cancellation
registration, and preserve the first transport terminal state. Directional
shutdown either works independently or returns the stable `Unsupported`
fallback without changing the connection.

## Control-flow paths

| Path ID | Conditions | Observable result |
|---|---|---|
| P001 | Read consumes `Delay`; close runs after waiter admission | Close releases the waiter; the resumed read returns `Closed`; the waiter queue is empty |
| P002 | Write consumes `Delay`; abort runs after waiter admission | Abort releases the waiter and aborts the delegate; the resumed write returns `Closed`; the waiter queue is empty |
| P003 | Manual release wins before cancellation | The write succeeds once, one byte reaches the peer, and later cancellation cannot change the result |
| P004 | Cancellation wins before manual release | The write returns `Cancelled`, removes its waiter, and produces no peer data |
| P005 | Adapter supports directional shutdown | Write shutdown drains buffered data then produces peer EOF while the reverse direction remains usable |
| P006 | Adapter reports `supportsHalfClose=false` | Both shutdown directions return stable `Unsupported`; read and write remain usable |
| P007 | Close or abort is repeated or followed by another terminal call | The first terminal state remains visible and cleanup runs once |
| P008 | Terminal completion races registration or unregister | Every claimed cleanup runs once; removed cleanup runs zero times; the registry drains to zero |

## Input and state domains

| Domain | Partitions covered |
|---|---|
| Operation | blocked read; blocked write; successful write; cancelled write |
| Terminal action | graceful close; abort; cancellation; successful completion |
| Ordering | waiter admitted before close/abort; release before cancel; cancel before release; repeated terminal calls |
| Half-close capability | supported memory adapter; unsupported Linux `StdNetTransport` |
| Cleanup registration | claimed at terminal; unregistered first; registered after terminal; registration/unregister race |

## Scenario matrix

| Scenario ID | Pre-state and trigger | Path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|
| S001 | Scripted read is queued, then close | P001 | Read wakes with `Closed` | Assert exact code, zero pending waiters and terminal transport | race, regression | P0 |
| S002 | Scripted write is queued, then abort | P002 | Write wakes with `Closed` | Assert exact code, zero pending waiters and terminal transport | race, regression | P0 |
| S003 | Release completes a write before cancel | P003 | Success remains final | Assert exact count and byte plus zero pending waiters | race | P0 |
| S004 | Cancel precedes release | P004 | Cancellation remains final | Assert exact code, zero pending waiters and no peer byte | race | P0 |
| S005 | Memory transport shuts down writing | P005 | Peer reads buffered data then EOF; reverse direction stays open | Assert exact bytes and EOF | lifecycle | P0 |
| S006 | Linux adapter rejects half-close | P006 | Stable fallback does not mutate either direction | Assert capability, error coordinates and bidirectional transfer | platform | P0 |
| S007 | Close and abort repeat in both orders | P007 | First terminal result wins | Assert idempotence and EOF versus reset evidence | lifecycle | P0 |
| S008 | Completion and lifecycle cleanup race | P008 | Cleanup is exactly once and bounded | Assert winner count, cleanup count and empty registry | property, race | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Test | Assertions | Type |
|---|---|---|---|---|---|
| T001 | S001 | P001 | `M124TransportRaceTest.readCloseReleasesBlockedOperationAndDrainsWaiter` | Assert `Closed`, zero waiters and terminal state | new deterministic |
| T002 | S002 | P002 | `M124TransportRaceTest.writeAbortReleasesBlockedOperationAndDrainsWaiter` | Assert `Closed`, zero waiters and terminal state | new deterministic |
| T003 | S003,S004 | P003,P004 | `M124TransportRaceTest.successAndCancelOrderingsCompleteOnceWithoutDataLeak` | Assert exact success byte, exact cancellation, no cancelled byte and both queues empty | new deterministic |
| T004 | S005 | P005 | `MemoryTransportTest.writeShutdownProducesPeerEofAfterBufferedData` | Assert exact data then EOF | existing regression |
| T005 | S005 | P005 | `MemoryTransportTest.readShutdownMakesPeerWritesFailAsBrokenPipe` | Assert reverse directional failure is `BrokenPipe` | existing regression |
| T006 | S006 | P006 | `StdNetTransportTest.unsupportedHalfClosePreservesBothDirections` | Assert stable `Unsupported` coordinates and bidirectional transfer | native Linux |
| T007 | S007 | P007 | `MemoryTransportTest.closeAndAbortAreIdempotentAndTerminal` | Assert repeated calls retain terminal state | existing regression |
| T008 | S007,S008 | P007,P008 | `TransportLifecycleTest.racingTerminalTransitionsRetainOneWinnerAndOneCleanup` | Assert one winner and one cleanup for 100 rounds | property, race |
| T009 | S008 | P008 | `OperationCompletionTest.registrationRacingCompletionIsAlwaysCleanedOnce`; `unregisterRacingCompletionRunsCleanupAtMostOnce` | Assert exact or at-most-once cleanup and empty registry for 100 rounds | property, race |

## Gap review

Every M1-024 acceptance item maps to a reachable path, scenario and semantic
assertion. No line, branch, mutation or fuzz coverage claim is made because
this task does not produce those artifacts. Other platforms remain
evidence-insufficient and are not part of the Linux profile decision.

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| read plus close | T001 | PASS |
| write plus abort | T002 | PASS |
| success plus cancel | T003 covers both explicit orderings | PASS |
| supported half-close | T004,T005 | PASS |
| `Unsupported` fallback | T006 on native Linux loopback | PASS |
| repeated close and abort | T007,T008 | PASS |
| registration cleanup | T008,T009 | PASS |
| canonical repository gate | Architecture guard, check, build and all repository tests pass | PASS |

## Commands and results

New deterministic cases:

```text
/home/elliot/.codex/scripts/codex_cangjie_env \
  cjpm test --filter='M124TransportRaceTest.*' --no-color --no-progress
```

Result: exit `0`. All three selected cases passed. Project summary: `TOTAL 572`,
`PASSED 3`, `SKIPPED 569`, `FAILED 0`, `ERROR 0`.

Native Linux fallback:

```text
/home/elliot/.codex/scripts/codex_cangjie_env \
  cjpm test --filter='StdNetTransportTest.unsupportedHalfClosePreservesBothDirections' \
  --no-color --no-progress
```

Result: exit `0`. The selected Linux loopback case passed. Project summary:
`TOTAL 572`, `PASSED 1`, `SKIPPED 571`, `FAILED 0`, `ERROR 0`.

Canonical repository gate:

```text
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit `0`. Python suites passed `57/57`, `114/114` and `23/23`;
architecture guard, `cjpm check` and `cjpm build` passed. Cangjie project
summary: `TOTAL 572`, `PASSED 552`, `SKIPPED 20`, `FAILED 0`, `ERROR 0`.
The build retained three pre-existing unused-function warnings for `metrics`,
`waitUntilAcceptActive` and `waitUntilWaiters`.

## Scope boundary

This task closes the deterministic Transport race matrix for Linux glibc. It
does not claim other-platform execution, leak or soak qualification, or the
M1-025 performance milestone. `T-RACE-001` remains OPEN in the global threat
register because its cross-platform and final ABI verification tasks are not
complete. Wirestack uses only the public SDK for this result. Any future
runtime or `std.net` enhancement remains optional and is not a dependency of
this task or the Wirestack release.
