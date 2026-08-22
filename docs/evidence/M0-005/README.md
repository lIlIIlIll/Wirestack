# M0-005 evidence — existing std.net raw TCP baseline

## Result

The benchmark harness and supplied-SDK Linux x86_64 baseline are complete. This is a pre-Wirestack reference measurement and is not a GATE-NET-05 pass.

## Method

A Cangjie client using the supplied SDK's actual `std.net.TcpSocket` API connects to a bounded Python loopback echo server. The harness verifies every received payload byte, echoes the same bytes, checks exact sent/echoed totals, bounds subprocess/server lifetimes, retains raw samples, and reports P50/P95/P99 values.

Cases cover connect-only plus 1 KiB, 16 KiB, 64 KiB, 1 MiB, and 100 MiB totals. Transfers larger than 64 KiB are streamed as repeated 64 KiB writes to avoid making the benchmark's memory footprint proportional to body size.

## Commands

```text
python3 -m unittest discover -s tools/benchmarks/tests -p 'test_raw_tcp_stdnet.py' -v
python3 tools/architecture_guard.py --root . --format text
cjpm check
cjpm build
python3 tools/benchmarks/raw_tcp_stdnet.py \
  --repo-root . \
  --artifact-dir build/benchmarks/raw-tcp-full \
  --output build/benchmarks/raw-tcp-full.json \
  --warmup 1 --repetitions 3 --timeout-seconds 240
```

## Non-claims

The current harness does not measure allocation counts or copied bytes, and this single Linux host cannot establish the Windows copy requirement or cross-platform performance thresholds. Those measurements remain required by the platform gate work.
