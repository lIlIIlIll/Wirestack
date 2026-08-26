# Wirestack Gates

Gate reports are durable evidence. A gate is not considered passed because code
compiled or a single happy-path test ran.

## M0 std.net adoption gates

- `GATE-NET-01`: close/cancel wakes blocked read/write/connect/accept.
- `GATE-NET-02`: one-reader/one-writer duplex and close/abort races.
- `GATE-NET-03`: absolute Deadline is not reset by internal loops.
- `GATE-NET-04`: peer EOF, RST, local close/abort and cancellation evidence.
- `GATE-NET-05`: large I/O, copies, allocation and Windows 4 KiB behavior.
- `GATE-NET-06`: repeated cleanup and long-running leak/soak behavior.
- `GATE-NET-07`: Android/iOS/Harmony network and application lifecycle changes.

Each report must record:

- task ID and gate ID;
- platform/device/VM and OS version;
- Cangjie SDK/runtime version and relevant upstream commit;
- exact command/configuration;
- raw output location;
- iteration count and percentile method where applicable;
- resource counters;
- PASS/FAIL/NOT RUN;
- blocker and proposed upstream action when failed.

A failed gate may unlock an `UP-*` tracking task. It must never be bypassed by
polling, private runtime handles, exception-message parsing, or TLS-layer guesses.

### Linux raw TCP baseline

Capture every required M0-005 loopback payload with one warmup and five measured
samples:

```bash
bash scripts/gate-m0-005-raw-tcp-baseline \
  --warmup 1 \
  --repetitions 5 \
  --repository-revision <tested-commit>
```

The report measures exact bytes, application-visible read sizes, transfer
latency, throughput, peak RSS and process thread count for 0 B, 1 KiB, 16 KiB,
64 KiB, 1 MiB and 100 MiB. It remains `BLOCKED` until a native LAN run and
supported allocations/op and raw copied-bytes/op counters are also present.
Do not infer those counters from heap-size deltas.

### Linux GATE-NET-06 formal profile

The Linux profile uses two fail-closed reports. First run the pinned AWS-LC
failed-handshake cleanup workload:

```bash
bash scripts/gate-net06-tls-failure-cleanup \
  --cycles 100000 \
  --output build/gates/net06-tls-failure-cleanup.json
```

Then run the transport counts and 24-hour mixed soak, importing that exact
report:

```bash
bash scripts/gate-net06-leak-soak \
  --full-linux \
  --soak-seconds 86400 \
  --sample-interval-seconds 60 \
  --timeout-seconds 1800 \
  --tls-cleanup-report build/gates/net06-tls-failure-cleanup.json
```

Short or missing runs remain `INCOMPLETE`. The formal Linux result requires all
three 100,000-iteration transport scenarios, exactly 100,000 failed TLS
handshake cleanups, a full 86,400-second soak, PASS RSS/FD steady-state trends,
and no dynamic system TLS dependency.

## Release gates

Release-gate ownership and blockers are summarized in
[`../planning/implementation-backlog.md`](../planning/implementation-backlog.md).
