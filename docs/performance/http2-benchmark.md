# HTTP/2 stream benchmark

The Linux benchmark measures small GET requests at 1, 10, and 100 concurrent
HTTP/2 streams. Each scenario uses two warmup rounds followed by 20 measured
rounds and is executed in both forward (`1,10,100`) and reverse (`100,10,1`)
order. The report retains every request latency and calculates nearest-rank
P50, P95, and P99 values from the combined forward and reverse samples.

Run it from the pinned Cangjie environment:

```sh
python3 tools/benchmarks/http2_benchmark.py \
  --output /tmp/wirestack-http2-benchmark.json
```

The runner samples aggregate RSS and open file descriptors for `cjpm`, the
test process, and all descendants from Linux `/proc`. RSS therefore includes
the test toolchain and is useful as a reproducible process-tree high-water
measurement, not as an allocation profile of the HTTP/2 core alone.

The harness also records the HTTP/2 writer queue high-water count and bytes,
the number of flow-control blocking episodes, and outstanding flow permits.
The run fails if the configured 256-write or 1-MiB queue bound is exceeded, if
a flow permit remains after completion, or if throughput or latency evidence
is invalid.

## Connection comparison

The 100-stream case executes all requests through one `Http2ClientConnection`.
The controlled HTTP/1 comparison executes 100 simultaneous requests through
100 independently owned `Http1ClientConnection` instances. Wirestack's pool
maps each of these protocol connection objects one-to-one to an adopted
transport/TLS connection, so the comparison measures the connection ownership
reduction required by the product architecture: 1 versus 100 (99%). A pass
requires the HTTP/2-to-HTTP/1 ratio to be no greater than 0.25.

Both peers use bounded `MemoryTransport` so the latency and throughput figures
isolate protocol-core scheduling rather than loopback TCP, TLS cryptography,
or certificate verification. They must not be presented as Internet, socket,
or TLS-handshake performance. Native Linux AWS-LC ALPN and pool-routing proof
is recorded separately by M6-018.

The accepted raw report is
[`docs/evidence/M6-020/http2-benchmark.json`](../evidence/M6-020/http2-benchmark.json).
