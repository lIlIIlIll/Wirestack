# M0-013 — Linux x86_64 DNS carrier-thread result

**Task:** COMPLETE  
**Linux decision:** FAIL  
**Global status:** INCOMPLETE

The controlled `LD_PRELOAD` shim intercepted every requested `getaddrinfo` call.
A 200 ms delay was injected only inside the test process; control and delayed
groups used the same Cangjie probe and host.

| Tasks | Control P95 | Delayed P95 | Delayed Max | Helper threads P50 | Decision |
|---:|---:|---:|---:|---:|---|
| 1 | 10.252 ms | 10.136 ms | 11.542 ms | 1 | PASS |
| 4 | 10.154 ms | 10.127 ms | 10.550 ms | 4 | PASS |
| 8 | 10.156 ms | 10.585 ms | 203.544 ms | 5 | PASS |
| 16 | 10.245 ms | 201.003 ms | 203.238 ms | 5 | FAIL |
| 32 | 10.171 ms | 201.117 ms | 204.341 ms | 5 | FAIL |
| 64 | 12.431 ms | 202.289 ms | 403.204 ms | 5 | FAIL |

At 16, 32 and 64 concurrent resolutions, heartbeat P95 exceeded the fail
threshold. The 64-task run reached a 403.204 ms maximum gap. The shim observed a
bounded set of native thread IDs rather than one independent asynchronous
resolver per task, so delayed calls ran in batches and stalled runnable Cangjie
work.

## Decision

```text
CARRIER_THREAD_STARVATION_OBSERVED
recommendation: runtime-native async resolver or a strictly bounded blocking resolver pool
conditional upstream candidate: UP-007
```

This is native Linux x86_64 evidence only. It does not authorize `UP-007` by
itself; M0-021 must produce the minimum upstream-interface RFC after all M0 gate
evidence is reviewed.

## Integrity

The committed `manifest.json` pins every compact evidence file and records the
full event-level report digest:

```text
full event report SHA-256:
4c4b22ba86ba8e803633a306a36ceb98906163acd23bc9ae29cd4b74f6666a0c

SDK archive SHA-256:
bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d
```

Implementation commit measured:

```text
a9af504f298ad3c6e26fe122eed8b540b0270ed6
```
