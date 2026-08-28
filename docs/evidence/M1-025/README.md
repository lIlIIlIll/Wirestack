# M1-025 Linux Transport qualification evidence

## Status

- Task: `M1-025`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**
- Date: 2026-08-28, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

The Linux Transport profile passes throughput, P95 latency, cancellation P99,
resource cleanup and soak requirements. The qualification uses the current
public SDK. It does not build or modify runtime, `std` or the SDK.

The machine-readable report is
[`linux_x86_64/report.data`](linux_x86_64/report.data).

## Dependency and evidence boundary

M1-024 supplies deterministic terminal-race coverage. M1-027 supplies the
formal raw `std.net` versus `StdNetTransport` comparison. M0-011 supplies the
retained Linux leak and 24-hour soak results. M1-025 adds the missing measured
P99 for cancellation of admitted blocked reads and writes.

The qualification tool verifies the retained report fields and the SHA-256 of
the 24-hour soak before reusing them. It does not treat a status-table entry as
acceptance evidence.

## Raw TCP comparison

The retained NET-05 report uses one `-O2` unittest binary, one warmup and 11
alternating measured rounds for both implementations.

| Payload | Throughput ratio | Required | P95 latency ratio | Maximum | Result |
|---|---:|---:|---:|---:|---|
| 1 KiB | 1.365428 | 0.95 | 0.943396 | 1.10 | PASS |
| 16 KiB | 1.198192 | 0.95 | 0.990445 | 1.10 | PASS |
| 64 KiB | 0.988339 | 0.95 | 0.333576 | 1.10 | PASS |
| 1 MiB | 1.042970 | 0.95 | 0.967290 | 1.10 | PASS |
| 100 MiB | 1.114788 | 0.95 | 0.961544 | 1.10 | PASS |

All instrumented adapter operations retain zero staging copies. The source
report SHA-256 is
`2bab904ceeaad6c1aec87bdc8b3c04db85c8da16154cc90c2c382fc66cda70b8`.

## Cancellation latency

The native loopback profile discards two warmups and retains 100 samples per
scenario. It starts timing only after the adapter reports the operation active.
For writes, the profile also requires 100 ms of unchanged progress before the
second 100 ms observation and cancellation. Every sample returns the typed
`Cancelled` result and closes the transport.

| Scenario | Samples | P50 | P95 | P99 | Maximum | Limit | Result |
|---|---:|---:|---:|---:|---:|---:|---|
| blocked read | 100 | 1.115 ms | 4.431 ms | 9.098 ms | 10.160 ms | 50 ms | PASS |
| blocked write | 100 | 1.115 ms | 2.803 ms | 4.118 ms | 6.533 ms | 50 ms | PASS |

The report retains every sample and the complete unittest process output.
Percentiles use nearest rank.

## Leak and soak decision

The qualification tool revalidates these retained NET-06 facts:

- connect/close, peer reset, close during blocked read, failed TLS handshake,
  production cancellation and production TLS cleanup each completed at least
  100,000 iterations with `PASS`;
- the mixed idle/active soak ran for 86,400 seconds and 187,051,774 iterations;
- the retained soak SHA-256 is
  `0cf4528c203131d4c6926ce27f9dbbbf3f11ff10f21848169d5ecc2a4248b93d`;
- all eight resource classes are measured: RSS, native file descriptors,
  sockets, timers, waiters, native buffers, GC roots and background tasks;
- 100,000 production cancellations completed with 200,000 joined tasks,
  zero active reads and zero background tasks;
- cancellation heavy-GC heap growth is -131,072 bytes; socket median growth is
  0, timerfd median growth is 0 and process median growth is 0.

The 24-hour run was not repeated. Reusing its digest-verified raw report avoids
another day-long run without weakening the acceptance rule.

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| compare current `std.net` and `StdNetTransport` | same-binary five-payload NET-05 report | PASS |
| throughput at least 95% | every payload ratio is at least 0.988339 | PASS |
| P95 latency degradation at most 10% | every payload ratio is at most 0.990445 | PASS |
| cancellation P99 at most 50 ms | blocked read 9.098 ms; blocked write 4.118 ms | PASS |
| no handle or waiter monotonic growth | 100,000 cancellation cleanup plus eight measured resource classes | PASS |
| required leak and soak workloads | six 100,000-iteration workloads plus 86,400-second soak | PASS |

## Commands and results

Qualification runner tests:

```text
python3 -m unittest tools.gates.tests.test_m1_025_transport_qualification -v
```

Result: exit `0`; 4/4 tests passed. The tests cover nearest-rank percentiles,
strict marker parsing, threshold failure and the required NET-05 matrix.

Short native profile:

```text
WIRESTACK_M125_WARMUP=1 WIRESTACK_M125_REPETITIONS=2 \
  /home/elliot/.codex/scripts/codex_cangjie_env \
  cjpm test src/internal/transport_stdnet -j 1 --parallel 1 \
  '--filter=M125TransportCancellationProfileTest.*' \
  --show-all-output --no-progress --no-color
```

Result: exit `0`; both selected cases passed.

Formal Linux qualification:

```text
scripts/qualify-m1-025-transport \
  --output docs/evidence/M1-025/linux_x86_64/report.data \
  --repository-revision workspace-m1-025-linux-qualification \
  --warmup 2 --repetitions 100
```

Result: exit `0`; report decision `PASS`.

Canonical repository gate:

```text
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit `0`. The Python suites passed 57/57, 118/118 and 23/23 tests;
the architecture guard, `cjpm check` and `cjpm build` passed; the Cangjie suite
reported 574 total, 552 passed, 22 Performance-tagged cases skipped, and zero
failures or errors. Compilation reported four unused internal diagnostic
function warnings, including the new test-only write-admission diagnostic; no
warning changed the gate result.

## Scope boundary

This closes M1-025 for the Linux glibc profile. It does not close global
six-platform M1-026, claim musl support or replace the original failed M0-010
report. M1-027 is the later passing Linux comparison and retains the original
failure as regression history. Future runtime or `std.net` enhancements remain
optional and are not a Wirestack release dependency.
