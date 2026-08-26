# M1-013 Linux MemoryTransport evidence

- Task: `M1-013`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

M1-013 completes the bounded in-memory transport model used by TLS and HTTP
tests. The existing paired byte stream retains partial I/O, half-close, EOF,
backpressure, cancellation and Deadline behavior. This task adds a bounded
in-memory listener and a FIFO scheduler that advances connection delivery only
when a test calls `runNext` or `runUntilIdle`.

Fault scripting, injected RST/error phases and virtual waiters remain M1-014.

## Control-flow paths

| Path | Condition | Observable result |
|---|---|---|
| P001 | pair capacity or maximum chunk is invalid | fail before allocating pipes |
| P002 | read or write has available capacity | transfer at most the configured chunk |
| P003 | write reaches pipe capacity | wait until the peer reads, cancels, expires or terminates |
| P004 | writer half-closes after buffered data | peer drains data and then observes EOF |
| P005 | reader half-closes | peer write fails as `BrokenPipe` |
| P006 | close or abort wins | both blocked directions wake with a non-EOF terminal result |
| P007 | listener owns fewer connections than backlog | create a pair and reserve one bounded queue entry |
| P008 | immediate connection delivery | accept returns server endpoints in FIFO order |
| P009 | scheduled connection delivery | accept cannot observe the endpoint before scheduler advance |
| P010 | listener backlog or scheduler queue is full | fail as structured `ResourceExhausted` and release the reservation |
| P011 | accept is cancelled or its absolute Deadline expires | return structured `Accept/ServerAccept` evidence without closing the listener |
| P012 | listener closes with active accept or owned connections | wake accept, unregister scheduled work, abort unaccepted server endpoints and make repeated close a no-op |

## Scenario and test matrix

| Scenario | Paths | Tests | Required assertions |
|---|---|---|---|
| S001 paired partial duplex | P001,P002 | `pairTransfersPartialDataInBothDirections` | both directions preserve bytes and maximum chunk |
| S002 empty and EOF | P002,P004 | `emptyBuffersReturnZeroWithoutProducingEofOrPeerData`, `writeShutdownProducesPeerEofAfterBufferedData` | empty read is `Data(0)`; only drained peer FIN is EOF |
| S003 half-close | P004,P005 | `writeShutdownProducesPeerEofAfterBufferedData`, `readShutdownMakesPeerWritesFailAsBrokenPipe` | read and write directions remain independent |
| S004 cancellation, Deadline and terminal wake | P003,P006 | existing blocked read/write, cancellation, Deadline, close and abort cases | exact terminal code and no data mutation before failure |
| S005 bounded backpressure | P002,P003 | `boundedBackpressureResumesAfterPeerReads` | writer resumes and exact byte sequence arrives |
| S006 listener bounds and FIFO | P007,P008,P010 | `rejectsInvalidListenerAndSchedulerBounds`, `listenerDeliversConnectionsInFifoOrderAndBoundsBacklog` | invalid limits fail; backlog stays bounded; accepted byte markers remain ordered |
| S007 manual scheduling | P007,P009,P010 | `schedulerDefersDeliveryAndReleasesFailedReservations`, `schedulerRunsMultipleConnectionsInStableFifoOrder` | no early accept, FIFO advance, bounded queue and failed reservation cleanup |
| S008 accept terminal context | P011 | `cancellationWakesAcceptWithoutClosingListener`, `deadlineBoundsBlockedAcceptWithoutClosingListener` | exact category, phase and code; listener remains reusable |
| S009 listener close | P012 | `closeWakesAcceptAndAbortsOwnedConnectionsIdempotently` | active accept wakes as `Closed`; clients observe reset; scheduler slot is released immediately |

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| paired endpoints | `MemoryTransport.pair`; S001 | PASS |
| partial I/O | configured `maxChunk`; S001 | PASS |
| half-close and EOF | S002 and S003 | PASS |
| bounded backpressure | fixed pipe capacity; S005 | PASS |
| virtual scheduling | bounded manual FIFO scheduler; S007 | PASS |
| deterministic TLS/HTTP use | canonical TLS, HTTP/1 and HTTP/2 suites use `MemoryTransport` and pass | PASS |
| listener lifecycle and bounded ownership | S006, S008 and S009 | PASS |

Every pipe, listener backlog and scheduler queue has an explicit bound. Closing
the listener unregisters queued scheduler deliveries instead of leaving stale
work to consume scheduler capacity.

## Commands and results

Baseline before the M1-013 additions:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=MemoryTransportTest.*' --no-color --no-progress
```

Result: exit 0 in the authorized Linux environment. Existing
`MemoryTransportTest` cases passed 11/11. The project summary was 484 total,
11 passed, 473 skipped, 0 failed and 0 errors. The first sandbox attempt exited
1 before test execution because unittest could not create its local control
socket.

Final focused command:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=MemoryTransportTest.*,MemoryTransportListenerTest.*' --no-color --no-progress
```

Result: exit 0. The two selected classes passed 18/18. The project summary was
491 total, 18 passed, 473 skipped, 0 failed and 0 errors.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python suites passed 50/50, 84/84 and 8/8. The architecture
guard, `cjpm check` and `cjpm build` passed. The Cangjie suite passed 491/491
with 0 skipped, 0 failed and 0 errors. The build retains the existing unused
test-hook warnings for `waitUntilAcceptActive` and `waitUntilWaiters`.

## Compatibility

The declaration diff tool returned `compatible` but did not enumerate the two
new untracked files, so that result is not used as the sole decision. The
normative class rule 5.1.3.5.1 classifies a new compatibility-sensitive public
class as a compatible additive change. Existing source, binary symbols and
runtime behavior are unchanged. The internal-package inventory intentionally
adds `MemoryTransportListener` and `MemoryTransportScheduler`. Applications
that use those new declarations require the new library version, which is the
normal forward-use boundary for an additive API.

## Remaining boundary

This is Linux M1-013 completion, not global M1 or six-platform completion.
M1-014 still owns scripted delays, short I/O sequences, injected RST/EOF/error
phases, cancel races and virtual waiters.
