# M1-020 evidence: idempotent close and abort wakeup

## Status

- Task: **COMPLETE**
- Linux x86_64 glibc: **PASS**
- Other platforms: **NOT RUN**

This result closes only the Linux M1-020 task. It does not claim the global
six-platform M1 exit gate.

## Implementation decision

`StdNetTransport` owns one terminal decision under `lifecycleMutex`.
`takeNativeCloseLocked` lets only the winning `close` or `abort` call close the
native socket. Later terminal calls return without touching it.

Graceful close calls `TcpSocket.close` directly. Abort first installs the native
abortive `SO_LINGER` value through the public `TcpSocket.setSocketOption` API,
then closes the socket. The pinned SDK rounds `TcpSocket.linger =
Some(Duration.Zero)` up to one second, so that property cannot implement this
contract. The SDK behavior and source revision are recorded in
[`docs/references/cangjie-std-net-linger-2026-08-28.md`](../../references/cangjie-std-net-linger-2026-08-28.md).

The adapter has no finalizer and performs no finalizer-driven network cleanup.
It does not use a private socket handle or `CJ_MRT_Sock*` ABI.

## Acceptance evidence

| Criterion | Evidence | Result |
|---|---|---|
| Graceful close and abort remain distinct | `firstCloseOrAbortKeepsItsPeerVisibleTerminalResult` observes EOF after close-first and a `NetworkException` after abort-first | PASS |
| Close and abort are idempotent | The same test repeats mixed close/abort calls and retains the first peer-visible terminal result | PASS |
| Explicit abort wakes an active read | `explicitAbortWakesBlockedReadWithStableEvidence` gates on active read state, aborts, joins within one second, and receives stable local `Closed` evidence | PASS |
| Cancellation wakes an active read | `cancellationWakesBlockedReadAndIsNeverReportedAsEof` joins as `Cancelled` and closes the transport | PASS |
| Graceful close wakes an active read | `localCloseMapsBlockedReadWithStableEvidence` joins as local `Closed`, not peer EOF | PASS |
| Listener close wakes active accept | `StdNetTransportListenerTest.listenerCloseWakesActiveAcceptWithStructuredErrorAndIsIdempotent` joins as `Closed` | PASS |
| Read, write, connect, and accept waiters exit on native close | M0-006 Linux GATE-NET-01 ran 20 samples per waiter; every sample passed and P99 stayed below 4.1 ms | PASS |
| Native close is claimed once | `closed`/`aborted` and `nativeClosed` are selected under one mutex before the socket call; repeated mixed terminal calls preserve the first observable result | PASS |
| Finalizer performs no network cleanup | Static inspection finds no finalizer on `StdNetTransport` or `StdNetTransportListener` | PASS |

## Commands

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='StdNetTransportTest.explicitAbortWakesBlockedReadWithStableEvidence,StdNetTransportTest.firstCloseOrAbortKeepsItsPeerVisibleTerminalResult'
```

Result: 2 passed, 563 skipped, 0 failed. Exit status 0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='StdNetTransportTest.*'
```

Result: all 17 `StdNetTransportTest` cases passed, 548 unrelated cases were
skipped, and no case failed. Exit status 0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: 57 tool tests, 114 gate-tool tests, and 23 benchmark-tool tests passed.
The architecture guard, resolver native build, `cjpm check`, and `cjpm build`
passed. The non-performance suite finished with 545 passed, 20 skipped, and 0
failed. Exit status 0. Existing unused-function warnings remain unchanged.

The first run before the fix failed both cases. It showed that
`TcpSocket.linger = Some(Duration.Zero)` produced graceful EOF instead of an
abortive peer result. The public raw socket-option implementation fixed that
failure without an SDK or runtime change.

## Scope limits

- No runtime, std, or SDK source was modified.
- No SDK component was built.
- Windows, macOS, Android, iOS, and Harmony were not executed.
- M1-024 owns the later deterministic Transport race matrix, including the
  scripted write-plus-abort ordering.
