# GATE-NET-02 — Linux x86_64 supplied-SDK result

**Task:** COMPLETE  
**Linux gate:** INCOMPLETE  
**Global gate:** INCOMPLETE

## Functional results

| Scenario | Samples | Result |
|---|---:|---:|
| concurrent reader + writer, exact 256 KiB each direction | 20 | PASS |
| close/read/write deterministic races | 100 | PASS |
| same-direction reads | 20 | OBSERVED |
| same-direction writes | 20 | OBSERVED |
| public `TcpSocket.abort()` compile probe | 1 | BLOCKED |

### Close-race wakeup

| Waiter | P50 | P95 | P99 | Maximum |
|---|---:|---:|---:|---:|
| reader | 0.068 ms | 0.117 ms | 0.342 ms | 3.666 ms |
| writer | 0.088 ms | 0.156 ms | 0.362 ms | 3.646 ms |

All 100 race processes exited without timeout or deadlock, and both waiters reached terminal states after close.

## Same-direction observations

Two simultaneous reads consistently allowed one 4096-byte read with exact payload and rejected the other through a caught generic exception:

- reader 1 success / reader 2 rejected: 8
- reader 2 success / reader 1 rejected: 12

Two simultaneous 64 KiB writes produced only byte-exact outcomes:

- both writes succeeded, 131072 bytes received: 5
- writer 1 succeeded and writer 2 was rejected: 6
- writer 2 succeeded and writer 1 was rejected: 9

These observations are not adopted as the Wirestack same-direction concurrency contract. Wirestack still intends to reject concurrent operations in the same direction deterministically.

## Abort capability

The public capability probe exited with compiler status 1. Diagnostic SHA-256:

```text
9a8262c952db6b5b1c7be30811ba76710cdfaedda315a2bddcd37bf5db77a153
```

Because public `TcpSocket.abort()` is unavailable, the Linux gate is retained as **INCOMPLETE**, even though full duplex and close races pass.
