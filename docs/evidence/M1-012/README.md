# M1-012 Linux acceptance evidence

## Scope

M1-012 freezes the `TransportListener` contract and validates its Linux
`StdNetTransportListener` implementation against TR-LISTEN-001. This evidence
does not claim non-Linux platform completion.

The listener accepts only resolved `SocketEndpoint` values. Its configured
backlog is bounded to 1 through 65535. One `OperationContext` supplies the
absolute monotonic deadline and cancellation token for each accept.

## Control-flow paths

| Path | Condition | Result |
|---|---|---|
| P001 | backlog is outside 1 through 65535 | fail before creating a listener |
| P002 | context is already cancelled or expired | structured fast-fail with no listener close |
| P003 | peer connects before a terminal signal | return an owned `DuplexTransport` |
| P004 | absolute accept deadline expires | structured `Accept/ServerAccept/TimedOut`; listener remains usable |
| P005 | cancellation wins an active accept | close wakes the public `std.net` accept and report `Accept/ServerAccept/Cancelled` |
| P006 | listener close wins an active accept | report `Accept/ServerAccept/Closed` |
| P007 | cancellation and socket timeout race | the exactly-once gate preserves the cancellation winner |
| P008 | close is repeated | native close runs at most once; repeated calls are no-ops |

## Scenario and test matrix

| Scenario | Paths | Test | Assertions |
|---|---|---|---|
| S001 backlog boundary | P001 | T001 `listenerRejectsOutOfRangeBacklogBeforeBinding` | 0, -1 and 65536 throw `IllegalArgumentException` |
| S002 pre-terminal context | P002 | T002 `listenerPreCancelledAndExpiredAcceptsFailFast` | exact category, phase and code; listener remains open |
| S003 deadline and reuse | P004,P003 | T003 `listenerDeadlineBoundsBlockedAcceptAndListenerRemainsUsable` | timeout is structured, then a real loopback accept succeeds |
| S004 active cancellation | P005,P007 | T004 `listenerCancellationWakesActiveAcceptWithStructuredError` | deterministic active-accept gate, structured cancellation, listener terminal |
| S005 explicit close | P006,P008 | T005 `listenerCloseWakesActiveAcceptWithStructuredErrorAndIsIdempotent` | deterministic wakeup, structured close, second close succeeds |

The adapter exposes `waitUntilAcceptActive` only with package visibility. It is
a deterministic race-gate hook, not part of the public Wirestack API.

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| `TransportListener` contract exists without `std.net` types | `src/internal/transport/transport.cj`; architecture guard | PASS |
| accept supports cancellation | T002 and T004 | PASS |
| accept uses an absolute Deadline | T002 and T003 | PASS |
| listener close wakes active accept | T005 | PASS |
| backlog is explicit and bounded | 1 through 65535 validation; T001 | PASS |
| accept failures are structured | T002 through T005 assert category, phase and code | PASS |
| terminal result completes once | `OperationGate`; P007 fix preserves a cancellation winner over timeout | PASS |

## Commands and results

Focused Linux listener tests were selected with:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=StdNetTransportListenerTest.*,HttpFacadeTest.tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests' --no-color --no-progress
```

Result: all five `StdNetTransportListenerTest` cases passed. The additionally
selected HTTP/2 concurrency case timed out, so the combined command exited 1.
That scheduling-sensitive failure was used to remove an earlier mutex-based
diagnostic hook that delayed the HTTP/2 second-connection path. The retained
listener activity counter is atomic and does not share the listener close
mutex. The authoritative final result is the canonical gate below, where the
same HTTP/2 case and all listener cases passed.

An initial sandbox run failed before test execution because unittest could not
create its control socket. Test execution therefore used the authorized Linux
environment.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python suites passed 50/50, 84/84 and 8/8. The architecture
guard, `cjpm check` and `cjpm build` passed. The Cangjie suite passed 484/484
with 0 skipped, 0 failed and 0 errors. The build reports the package-visible
`waitUntilAcceptActive` diagnostic hook as unused outside tests and retains one
pre-existing `waitUntilWaiters` warning in the HTTP/1 connection pool.

## Compatibility

The declaration classifier reports the production and new test files
compatible. New state and helper declarations are private or package-visible;
public signatures and inventory do not change. Runtime semantics intentionally
change only when cancellation wins the timeout race: the accept now returns
`Cancelled` instead of incorrectly returning `TimedOut`.

## Remaining boundary

Active accept cancellation closes the listener because the pinned public
`std.net` API exposes close as the only proven wakeup operation. This is a
documented Linux adapter constraint, not peer EOF. Global six-platform M1
completion remains open.
