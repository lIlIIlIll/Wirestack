# M0-010 evidence: GATE-NET-05 large-buffer and copy characteristics

## Status

- Task evidence: **COMPLETE**
- Linux x86_64 GATE-NET-05: **FAIL**
- Native Windows copy profile: **BLOCKED**
- Global GATE-NET-05: **INCOMPLETE**

The schema-v2 gate compares raw `std.net.TcpSocket` with the current
`StdNetTransport` against the same bounded loopback sender. Both receive legs
run from the same `-O2` unittest binary, with the same process shape and a
reusable 64 KiB destination. Eleven measured rounds alternate execution order
after one warmup. Every byte, payload pattern and read size is verified for
1 KiB, 16 KiB, 64 KiB, 1 MiB and 100 MiB payloads.

The Wirestack whole-array fast path removes adapter staging copies for every
profile payload. The fair-process comparison still fails at 1 KiB, 16 KiB and
64 KiB. The 1 MiB and 100 MiB cases pass both PRD thresholds. This shape shows
a fixed per-call cost rather than a body-size or staging-copy cost: the ratio
improves as more bytes amortize `readSome` cancellation, Deadline, lifecycle
and exactly-once bookkeeping.

## Comparison

| Payload | Raw P50 MiB/s | Adapter P50 MiB/s | Throughput ratio | P95 latency ratio | Decision |
|---|---:|---:|---:|---:|---|
| 1 KiB | 37.229 | 6.639 | 0.178 | 1.729 | FAIL |
| 16 KiB | 213.058 | 61.175 | 0.287 | 0.233 | FAIL |
| 64 KiB | 342.838 | 294.006 | 0.858 | 13.629 | FAIL |
| 1 MiB | 351.430 | 406.107 | 1.156 | 0.359 | PASS |
| 100 MiB | 366.174 | 404.734 | 1.105 | 0.761 | PASS |

The report retains each raw sample, paired execution order, P50/P95/P99,
read sizes, read counts, RSS and thread samples. It also retains one separate
`heaptrack` plus `strace` operation for each implementation and payload.

## Copy and allocation evidence

All ten instrumented operations pass. `strace` confirms that successful
`recvfrom` results sum to the exact payload for both implementations.
`StdNetTransport.stagingCopiedBytes` independently reports zero read-side and
zero write-side staging copies. The profile supplies a full 64 KiB destination,
so the adapter passes that array directly to `std.net`; subranges retain the
bounded staging fallback and separate copy accounting.

| Payload | Raw process allocations | Adapter process allocations | Adapter staging copy |
|---|---:|---:|---:|
| 1 KiB | 36,682 | 36,692 | 0 B |
| 16 KiB | 36,682 | 36,692 | 0 B |
| 64 KiB | 36,684 | 36,694 | 0 B |
| 1 MiB | 36,684 | 36,694 | 0 B |
| 100 MiB | 36,680 | 36,694 | 0 B |

The allocation values cover the complete native process operation, including
startup and the common unittest runner. Raw and adapter process allocation
counts now differ by only 10 to 14 events. They are not presented as
steady-state Cangjie allocation counts. Performance samples run without
instrumentation.

## Root cause and upstream disposition

The current public `std.net` receive API accepts a whole `Array<Byte>`. Wirestack
can avoid its own staging copy when a bounded operation spans the complete
array; offset or shortened views still require staging because exposing bytes
outside the requested span would violate the Transport contract. This fast
path materially improves the profile without changing runtime or `stdx`.

The formal Linux gate remains failed, so the original `UP-004` failure evidence
is not withdrawn. The retained run does not show that staging copy is still the
cause. Every measured adapter operation reports zero staging copies, and the
large payloads pass. The remaining gap is per-operation Transport bookkeeping
on short reads. Starting UP-004 still requires evidence that an upstream span
API would address that gap, plus an approved interface and regression plan.

## Commands and retained report

Formal command:

```text
timeout 900s env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack bash scripts/gate-net05-large-buffer-profile --warmup 1 --repetitions 11 --output /tmp/wirestack-m0-010-fair-shape-formal11.json --artifact-dir /tmp/wirestack-m0-010-fair-shape-formal11-artifacts --repository-revision working-tree-m0-010-fair-shape
```

Result: exit 1 because the measured Linux gate is `FAIL`. The runner completed
all cases and wrote [`result.json`](linux_x86_64/result.json), SHA-256
`0e82bbb8fbefdfae7a985da14e75a392233ff025df8f4d7b8a2db27bad52f689`.

Focused tests:

```text
python3 -m unittest tools.gates.tests.test_net05_large_buffer_profile tools.gates.tests.test_m0_005_raw_tcp_baseline -v
```

Result: exit 0, 21 tests passed across NET-05 and the shared raw-baseline suite.

Canonical repository gate:

```text
timeout 600s /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python suites passed 50, 99 and 11 tests; the architecture
guard, `cjpm check` and `cjpm build` passed. The Cangjie suite reported 518
total, 512 passed, 6 Performance-tagged skips, zero errors and zero failures.
The two pre-existing unused-function warnings remain unchanged.

## Boundary

M0-010 evidence collection is complete, but the Linux gate failed. Windows
still owns the native fixed-4-KiB decision. This report does not claim global
GATE-NET-05, M1-025, an approved `UP-004` interface, or a Linux release pass.
