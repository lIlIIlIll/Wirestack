# M0-013 evidence — std.net DNS carrier-thread behavior

## Status

- Task: **COMPLETE**
- Native Linux x86_64 decision: **FAIL**
- Classification: `CARRIER_THREAD_STARVATION_OBSERVED`
- Global cross-platform status: **INCOMPLETE**
- Conditional upstream candidate: `UP-007`

The task is complete because the controlled resolver-delay experiment was
implemented, compiled with the supplied Cangjie SDK, executed across the full
1/4/8/16/32/64 concurrency matrix, and retained with bounded evidence. A failed
gate is valid M0 evidence; it is not relabeled as a harness failure or PASS.

## Method

- A test-only `LD_PRELOAD` shim intercepts `getaddrinfo` inside the Cangjie probe
  process and records entry/exit monotonic timestamps, sequence, PID, TID,
  result and hostname.
- The shim injects either 0 ms control delay or 200 ms synthetic resolver delay.
- Cangjie resolution tasks construct `std.net.TcpSocket("localhost", 1u16)` while
  an independent Cangjie heartbeat task records `MonoTime` progress every 5 ms.
- Every intended resolution must have one paired shim entry/exit record; missing,
  duplicate or malformed calls fail the harness.
- Every process has a hard timeout, bounded output capture and process-group
  cleanup.
- Final host-sensitive execution was serialized by the shared Linux gate lock.

## Durable evidence

- [`linux_x86_64/summary.md`](linux_x86_64/summary.md)
- [`linux_x86_64/result-summary.json`](linux_x86_64/result-summary.json)
- [`linux_x86_64/samples-00.jsonl`](linux_x86_64/samples-00.jsonl)
- [`linux_x86_64/samples-01.jsonl`](linux_x86_64/samples-01.jsonl)
- [`linux_x86_64/samples-02.jsonl`](linux_x86_64/samples-02.jsonl)
- [`linux_x86_64/samples-03.jsonl`](linux_x86_64/samples-03.jsonl)
- [`linux_x86_64/manifest.json`](linux_x86_64/manifest.json)
- [`linux_x86_64/run.log`](linux_x86_64/run.log)
- [`linux_x86_64/sdk.sha256`](linux_x86_64/sdk.sha256)

The JSONL files retain all 36 measured sample-level process, heartbeat,
resolution, helper-thread and shim-log digest records. The manifest pins every
committed evidence file and the SHA-256 of the larger event-level report produced
by the harness.

## Decision boundary

This evidence shows that delayed hostname resolution can occupy the current
Linux carrier-thread set and stall unrelated runnable Cangjie tasks. It supports
a future requirement for a runtime-native asynchronous resolver or a strictly
bounded blocking resolver pool.

Wirestack selected and completed the bounded-pool path in M2-003. The runtime
resolver option therefore remains a future upstream enhancement, not a
dependency of the current implementation or Linux release.

It does **not** directly authorize an upstream runtime change. M0-021 must review
all M0 gate failures and produce the minimal upstream-interface RFC before
`UP-007` can start. No production Resolver, Transport, TLS or HTTP code is added
by this task.
