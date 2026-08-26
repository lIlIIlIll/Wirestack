# M1-014 Linux scripted transport evidence

- Task: `M1-014`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

M1-014 adds a bounded deterministic fault-injection wrapper for the Transport
SPI. Read and write scripts independently model manual delay, short progress,
EOF, terminal reset and structured failures with an explicit operation phase.
`VirtualWaiter` queues blocked operations in FIFO order and advances only when
a test calls `releaseNext` or `releaseAll`.

This task supplies reusable deterministic primitives. M1-024 still owns the
complete adapter-level transport race matrix.

## Example

```cangjie
let (raw, peer) = MemoryTransport.pair()
let waiter = VirtualWaiter()
let transport = ScriptedTransport(
    raw,
    readScript: [
        ScriptedTransportStep.Delay(waiter),
        ScriptedTransportStep.Short(3),
        ScriptedTransportStep.EndOfStream
    ]
)

// A spawned read remains queued until the test calls waiter.releaseNext().
```

## Control-flow paths

| Path | Condition | Observable result |
|---|---|---|
| P001 | waiter or script bound is invalid | construction fails before retaining work |
| P002 | empty read or write | returns zero data/progress without consuming a script step |
| P003 | script is empty | operation delegates unchanged |
| P004 | `Delay` is next | operation enters the bounded FIFO waiter until manual release, cancellation, Deadline or terminal wake |
| P005 | `Short(n)` is next | one delegated operation is limited to `min(n, span length)` |
| P006 | read `EndOfStream` is next | returns explicit peer EOF without reading the delegate |
| P007 | `Reset(phase)` is next | aborts the delegate, terminates the wrapper and raises `ConnectionReset` with the injected phase |
| P008 | `Failure(category, phase, code, retryability)` is next | raises the exact structured coordinates without terminating later scripted work |
| P009 | cancellation and manual release race | cancellation remains terminal and the waiter registration is removed |

## Scenario and test matrix

| Scenario | Paths | Test | Required assertions |
|---|---|---|---|
| S001 bounded construction | P001 | `rejectsUnboundedOrInvalidScripts` | non-positive bounds, zero short count, write EOF and oversize scripts fail |
| S002 ordered short I/O | P003,P005 | `shortReadAndWriteStepsAreConsumedInOrder` | exact partial counts, bytes and remaining step counts |
| S003 empty I/O and EOF | P002,P006 | `emptyIoDoesNotConsumeScriptAndEofIsExplicit` | empty spans preserve scripts; only the EOF step reports EOF |
| S004 injected RST | P007 | `resetTerminatesTransportAtInjectedPhase` | exact phase/code, terminal wrapper and reset peer |
| S005 injected structured error | P008 | `failurePreservesCoordinatesWithoutTerminatingTransport` | exact category/phase/code and subsequent delegate progress |
| S006 FIFO virtual delay | P004 | `virtualWaiterReleasesBlockedOperationsInFifoOrder` | first registered operation completes first; queue drains to zero |
| S007 cancel race | P004,P009 | `cancellationWinsAReleaseRaceAndCleansWaiter` | cancellation wins a concurrent release and removes the waiter |

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| scriptable delay | `Delay(VirtualWaiter)`; S006 | PASS |
| scriptable short reads and writes | `Short`; S002 | PASS |
| scriptable RST and EOF | `Reset` and `EndOfStream`; S003,S004 | PASS |
| cancellation race | cancellation callback wakes the waiter; S007 | PASS |
| explicit error phase | `Reset` and `Failure` carry `NetworkPhase`; S004,S005 | PASS |
| reproducible bounded script | independent FIFO queues with explicit limits and remaining-step counters | PASS |

## Commands and results

Focused build:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm build
```

Result: exit 0. The existing unused test-hook warnings remain unchanged.

Focused tests:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=ScriptedTransportTest.*' --no-color --no-progress
```

Result: exit 0; all seven selected scripted transport cases passed.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0 in 30.3 seconds. Python suites passed 50/50, 84/84 and
8/8. The architecture guard, `cjpm check`, `cjpm build` and the complete
Cangjie test command passed. The build retains the existing unused test-hook
warnings for `waitUntilAcceptActive` and `waitUntilWaiters`.

## Compatibility

The declaration diff tool returned `compatible` but did not enumerate the new
untracked files. A separate rule query classifies new public declarations in an
internal package as compatible additive symbols. No existing declaration or
behavior is modified; consumers of the new test utility require the new
library version as expected.

## Remaining boundary

This is Linux M1-014 completion evidence only. It does not complete global M1,
the six-platform matrix, or M1-024 deterministic adapter races.
