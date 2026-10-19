# Native end-to-end development baselines

M12-001 measures the complete public stack on native Linux x86_64 glibc.
It does not qualify a release, compare Internet performance, or claim superiority
over std/stdx. The earlier [H1](http1-benchmark.md) and
[H2 protocol-core](http2-benchmark.md) reports retain their original boundaries.

## Reproduce

Use the SDK 1.1.3 environment recorded in the accepted report. `cjc`, `cjpm`,
`openssl`, `readelf`, `findmnt` and `lscpu` must be available. `cjprof` is optional;
its failed execution is retained as unavailable evidence, never a successful
profile. OpenSSL generates disposable test certificates only; the workloads
link the build-selected static AWS-LC5.5.0 provider.

```sh
mkdir -p "$HOME/.cache/agent-tmp"
work=$(mktemp -d "$HOME/.cache/agent-tmp/wirestack-m12-001.XXXXXX")
chmod 700 "$work"
export TMPDIR="$work" TMP="$work" TEMP="$work"
python3 tools/benchmarks/m12_001_end_to_end.py capture \
  --scratch "$work/native" --repeats 14 --warmups 2 \
  --output "$work/evidence"
python3 tools/benchmarks/m12_001_end_to_end.py verify \
  --report "$work/evidence/report.json"
```

The runner rejects tmpfs and less than 2 GiB free scratch space. Use a new
scratch/output pair and retain the evidence before removing extracted packages
and private keys. It rebuilds the exact M11-004 development-accepted archive,
checks every production source and archive digest against the SDK 1.1.3 installed
acceptance report, and compiles three installed consumers with `-O2 -g`.
A source or archive mismatch stops capture; it does not silently select another
baseline. A different accepted artifact needs an explicit task-scoped update
of that binding. The capture also records every benchmark source declared by
`tools/tasks/M12-001.json`: the four native probes, this runner, its tests, the
task contract and the three benchmark documents. `verify` rechecks that complete
inventory, so a changed runner, test, task contract or document cannot reuse an
older capture. The prior P1-015 archive could not be reconstructed exactly;
it is not substituted or presented as a measured before-version.

## Work and accounting

Thirty-three scenarios execute sequentially, with two complete process warmup
rounds and 14 measured rounds in alternating forward/reverse order. Each process
also performs its documented native operation warmups. Every measured operation,
including expected cancellation, timeout and rejection, has a positive raw
latency. Successes, unexpected failures and expected rejections are separate.
Successful byte throughput never counts failed operations.

| Layer | Native cases | Timing and configuration boundary |
| --- | --- | --- |
| TCP/UDP |8MiB bidirectional bulk,7-byte partial spans, admitted-read cancellation,1,024 1,200-byte packet round trips | Public read/write invocation counts, not syscalls; TCP caller-owned bulk arrays total24MiB. Counters include native operation warmup. TCP/UDP elapsed work includes final closure. |
| TLS |32 full/resumed TLS1.2 handshakes,256 small exchanges,8 bulk exchanges,16 stalled-handshake timeouts,32 graceful closes | Full/resumed status asserted on both peers. Operation latency selects handshake, application exchange or close; total duration includes connection/handshake/application/close work. |
| H1 |200 reused/fresh short requests,8MiB body with4/32KiB caller buffers,10-way concurrency,200 early body closes | Native plaintext TCP, explicitly not HTTPS. Exact checksums; cleanup measured separately from work. |
| H2 |1/10/100 concurrently retained streams, real receive-window stall, sibling progress, cancellation and recovery | Native authenticated TLS/ALPN and one actual connection. Slow-reader aggregate capacity2 supplies131,070 receive-reservation bytes; per-route/per-origin capacity stays1. Total16MiB/control64KiB remains bounded. |
| SSE/WebSocket |H1/H2, slow reader, cancellation/disconnect, fragmented messages and control frames | Native authenticated TLS for both protocols. H1 uses an explicit public TLS connector; URL framing alone is not the security claim. Steady intervals exceed250ms; first delivery includes opening/handshake. |
| Overload |Client waiter admission/rejection, server503, successful recovery | One waiter, real typed PoolExhausted and separate503 outcomes; all rejection latencies retained. Queue delay is not mutex contention. |

HTTP measurement rounds use one coordinator-owned release gate. Each round
starts closed. Concurrent rounds first retain all response owners and check
their live count; the coordinator then opens the gate for every round before
joining futures, including serial rounds. The [M12-004 repair evidence](../evidence/M12-004/http-round-release/summary.json)
binds the changed consumer source and its STS-only native correctness run.
Historical M12-001 measurements and the failed M12-004 performance captures
retain their original source and artifact bindings. New performance comparisons
must build both legs from the same current consumer source.

Normal, slow, overload, failure and cleanup regimes are reported separately.
Long-stream producers offer one bounded message at a time, paced 2 ms; slow
consumers pause 1 ms after offer. Their latency includes that pause. This proves
application-level bounded backpressure, not socket-buffer saturation. H2 uses
actual protocol-window exhaustion, not that pacing proxy.

`duration_ns` excludes JSON serialization. H1/H2 final close and long-stream
final resource reclamation are separately timed; cancellation/disconnect
latencies retain their terminal operation boundary. The TCP/TLS total duration
includes their close work. Do not compare these different latency definitions
as interchangeable request percentiles.

## Attribution and unavailable costs

The native observer workload correlates M10 request/attempt/connection IDs and
monotonic stage events. RequestStarted-to-BodyCompleted is the E2E span; overlapping
stage durations are not summed into a fabricated total. The enabled/disabled
pair includes the benchmark's bounded event drain/correlation overhead, so it
does not isolate event-emission cost alone. H2 snapshots, flow-stall events and
terminal ledgers accompany real 1/10/100-stream work.

Every 20 ms, `/proc` records whole-process RSS, threads and file descriptors,
including Cangjie runtime and both peers, but excluding the compiler. Public
managed-buffer snapshots are a different ownership boundary. Post-work managed
heap size and total GC count are not per-I/O allocation counts or peak heap.
Raw CPU samples describe CPU residency, not elapsed stage duration.

Per-I/O allocation events, context/cancel allocation events, TLS/body copied
bytes, H2 writer/pool mutex wait and UDP per-packet allocation events remain
explicit `null` with reasons. Public API call counts cannot replace them.
No vectored/borrowed-buffer API is introduced; P1-001 stays deferred without
measured copying evidence and a supported native SPI.

The held-frame admission failure is retained separately: consuming 4 KiB
returns protocol credit but can retain a whole frame allocation. Capacity 1's
65,535-byte reserve rejected a tiny sibling. The corrected capacity 2 workload
still proves one physical connection; it is a configuration correction, not
an identical-work optimization or a production fix.

## Candidate decisions and CI

The 4 KiB/32 KiB caller-buffer candidate preserves 8 MiB bytes/checksum, response
contract, provider, parser limits and operation count. Acceptance requires at
least 7 independent paired rounds, a two-sided sign-test `p <= 0.05`, median
speedup at least 5%, P95/P99 regression no more than 10%, robust noise no more
than 20%, and fewer actual body-read invocations. Even a supported caller
configuration does not prove reduced internal allocation/copying or justify
changing the default production buffer.

```sh
python3 tools/benchmarks/m12_001_end_to_end.py compare \
  --baseline "$work/evidence/report.json" --candidate "$work/evidence/report.json" \
  --baseline-rounds 0:7 --candidate-rounds 7:14 --output "$work/comparison.json"
```

This compares disjoint seven-round cohorts, not the same executions against
themselves. It is a same-artifact repeatability check, not an optimization gain.
For independent capture reports, select distinct report paths and omit the
round selectors to use all measured rounds. Overlapping self-comparisons are
INCONCLUSIVE, never a performance pass.

Comparisons verify raw stdout digests, unique independent executions, complete
33-case coverage, recomputed summaries and frozen references. SDK/runtime,
CPU model/topology, OS, optimization, network, workload and probe sources must
match. Thresholds are `max(5%, 6 × robust relative MAD)` from the baseline.
A threshold above10% is **NOISY**, not a relaxed passing gate. Insufficient
rounds or mismatched conditions are **INCONCLUSIVE**; reliable throughput or
tail regressions are **FAIL**. Exit codes: PASS0, FAIL1, NOISY2,
INCONCLUSIVE3. Retained evidence verification is not a new performance run.

See [M12-001 evidence](../evidence/M12-001/README.md) for actual measured
results, accepted/rejected candidates, classifier outcomes and limitations.
