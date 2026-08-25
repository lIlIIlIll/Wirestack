# M6-020 Linux acceptance evidence

Date: 2026-08-25

## Scope and environment

- Target: native Arch Linux x86_64, kernel `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003`.
- cjpm: `1.1.3`.
- Workload: bounded in-memory HTTP/2 protocol-core benchmark; 2 warmup and 20
  measured rounds per pass, in forward and reverse concurrency order.
- Durable raw samples: [`http2-benchmark.json`](http2-benchmark.json).

## Acceptance decision

Overall decision: **PASS**.

| Streams | Measured requests | req/s | P50 | P95 | P99 | Connections | Peak RSS | Peak FDs | Queue high-water | Flow stalls |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 40 | 1070.397 | 0.933 ms | 1.347 ms | 1.672 ms | 1 | 1,328,332 KiB | 96 | 3 writes / 43 B | 0 |
| 10 | 400 | 1811.197 | 5.192 ms | 7.940 ms | 8.826 ms | 1 | 1,170,092 KiB | 96 | 8 writes / 144 B | 0 |
| 100 | 4000 | 1593.354 | 53.771 ms | 97.043 ms | 104.197 ms | 1 | 1,103,276 KiB | 96 | 35 writes / 604 B | 0 |

All scenarios finished with zero outstanding flow permits. Queue high-water
values remained below the configured 256-write and 1-MiB bounds.

The controlled HTTP/1 comparison used 100 independent connection owners for
100 simultaneous requests. HTTP/2 used one connection owner for 100 streams:
ratio `0.01`, a 99% reduction, against the required maximum ratio `0.25`.
Each pool connection owner maps one-to-one to an adopted transport/TLS
connection. The workload uses `MemoryTransport`; it proves bounded protocol
scheduling and connection ownership, not TCP syscall, TLS cryptography, or
Internet performance. M6-018 separately records native Linux AWS-LC ALPN and
automatic pool routing evidence.

## Implementation and defect evidence

- `Http2ClientMetrics` exposes current/high-water writer queue state,
  outstanding flow permits, flow-control stalls, and listener counts.
- The benchmark first exposed a full-capacity failure at 100 streams. The
  reader registry had capacity for 100 stream listeners but its connection-level
  stream registry also owns one listener. Its explicit bound is now
  `maxConcurrentStreams + 1`; a boundary test proves two listeners are accepted
  for a one-stream reader and a third is rejected.
- The Python runner preserves raw latency samples, fingerprints the harness and
  runner, samples `/proc`, executes reversed order, and emits stdout plus stderr
  tails on subprocess failure.

Accepted source fingerprints:

- runner: `98dc3cf9c001271505655da6c56ea9204b453aa6cc72b9ac4c4015ada065d990`
- harness: `f38ec74f2a7e7b164aa07b239eb362fbf0a9ae6848808376dcffb025f9427370`

## Commands and exact results

1. `cjpm test --no-run`
   - Exit 0; test-profile compilation finished.
2. `cjpm test src/internal/http2 -j 1 --parallel 1 --filter Http2ConnectionReaderTest --show-all-output --no-progress --no-color`
   - Exit 0; 7 passed, 138 skipped, 0 errors, 0 failed.
3. `cjpm test src/internal/http1 -j 1 --parallel 1 --filter Http2Streams100BenchmarkTest --show-all-output --no-progress --no-color`
   - Exit 0; 1 passed, 107 skipped, 0 errors, 0 failed; 2,000 measured requests completed on one connection.
4. `cjpm test src/internal/http1 -j 1 --parallel 1 --filter Http1HundredConnectionBaselineTest --show-all-output --no-progress --no-color`
   - Exit 0; 1 passed, 107 skipped, 0 errors, 0 failed; 100 requests used 100 connection owners.
5. `python3 tools/benchmarks/http2_benchmark.py --output docs/evidence/M6-020/http2-benchmark.json`
   - Exit 0; overall `PASS`; forward and reverse passes completed.
6. `scripts/check`
   - Exit 0.
   - Python repository tests: 50 passed.
   - Python gate and gate-runner tests: 67 passed.
   - Python benchmark-tool tests: 8 passed.
   - Architecture guard: PASS.
   - `cjpm check`, `cjpm build`, and the complete 436-test suite succeeded;
     436 passed, 0 skipped, 0 errors, 0 failed.
   - The build retained one existing unused-function warning for
     `waitUntilWaiters` in the HTTP/1 connection pool; it is outside M6-020.

## Remaining scope

This result is a fixed-host protocol-core baseline. It does not claim native
TCP/TLS latency or throughput. Cross-host, network-shaped, TLS-handshake, soak,
and continuous performance-regression infrastructure remain release-hardening
scope rather than M6-020 acceptance.
