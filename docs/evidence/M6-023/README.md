# M6-023 Linux acceptance evidence

Date: 2026-08-27

## Scope and environment

- Target: native Arch Linux x86_64, kernel `7.1.9-arch1-2`, glibc 2.44.
- Cangjie compiler: `1.1.0-alpha.20260817040003` (`cjnative`).
- cjpm: `1.1.3`.
- Implementation revision: `bc5e32af70bac16aa978c3c1ab34eb2e83ca2430`.
- Raw report: [`linux_x86_64/sse-streaming-profile.json`](linux_x86_64/sse-streaming-profile.json).

## Acceptance decision

| Acceptance criterion | H1 result | H2 result |
| --- | --- | --- |
| Real `text/event-stream` duration | PASS: 3,600.017 s | PASS: 3,600.021 s |
| Numbered events consumed | PASS: 95,935,756 | PASS: 90,877,593 |
| Sequence errors | PASS: 0 | PASS: 0 |
| Bounded stream lead | PASS: 152,522 events | PASS: 4,219 events |
| Application pending bytes at cancellation | PASS: 0 | PASS: 0 |
| Heavy-GC heap trend after warmup | PASS: -9,140,224 bytes | PASS: -6,719,488 bytes |
| Process-tree RSS trend after warmup | PASS: -30,864 KiB | PASS: -32,356 KiB |
| FD, socket, and thread growth | PASS: 0, 0, 0 | PASS: 0, 0, 0 |
| Slow-consumer backpressure | PASS | PASS |
| Public cancellation latency | PASS: 3.417 ms | PASS: 3.458 ms |
| H2 sibling before and after stream cancellation | Not applicable | PASS |

The M6-023 Linux result is PASS. Both profiles ran in parallel. Each profile
exceeded the one-hour and one-million-event requirements. The raw report retains
12 heavy-GC heap samples and 356 process-tree resource samples per protocol.

## Implementation evidence

- `src/internal/http1/chunked.cj`, `response_reader.cj`, and `server_writer.cj`
  keep request and declared-response bounds while allowing unknown-length
  responses to exceed the configured lifetime body limit.
- `src/internal/http2/client_mapping.cj` and `server_mapping.cj` apply the same
  rule to unknown-length H2 responses. Declared `Content-Length` remains exact.
- `src/internal/http2/flow_control.cj` coalesces small receive-credit updates.
  Body discard and stream cleanup flush retained connection credit.
- `src/internal/http2/write_scheduler.cj` admits control batches through the
  bounded queue with cancellation and deadline checks.
- `src/http/sse_profile_test.cj` runs real public H1 and native AWS-LC/TLS H2
  clients and servers. The test parses sequence numbers without storing the
  full stream, exercises slow-consumer backpressure, cancels through public
  handles, and verifies H2 sibling isolation.
- `tools/gates/sse_streaming_profile.py` launches both protocols in parallel,
  samples the process trees, checks heavy-GC heap trends, and writes the raw
  fail-closed report.

## Commands and exact results

All Cangjie commands ran through the configured repository environment.

1. Focused H1/H2 SSE and H2 flow-control regression command
   - Exit 0; 38 passed, 169 skipped, 0 errors, 0 failed.
2. `python3 -m unittest tools.gates.tests.test_sse_streaming_profile`
   - Exit 0; 4 passed.
3. `scripts/check`
   - Exit 0.
   - Python architecture and tool tests: 50 passed.
   - Python gate tests: 84 passed.
   - Python benchmark tests: 8 passed.
   - Architecture guard: PASS.
   - `cjpm check`: success.
   - `cjpm build`: success, with one pre-existing unused-function warning for
     `waitUntilWaiters` in `src/internal/http1/connection_pool.cj`.
   - `cjpm test`: 452 passed, 0 skipped, 0 errors, 0 failed.
4. `scripts/sse-streaming-profile --duration-seconds 3600 --minimum-events 1000000 --slow-seconds 60 --slow-delay-ms 20 --heap-sample-seconds 300 --resource-sample-seconds 10 --timeout-seconds 3900 --output docs/evidence/M6-023/linux_x86_64/sse-streaming-profile.json --repository-revision bc5e32af70bac16aa978c3c1ab34eb2e83ca2430`
   - Exit 0; overall PASS.
   - H1: 95,935,756 events in 3,600.017 s; cancellation 3.417 ms.
   - H2: 90,877,593 events in 3,600.021 s; cancellation 3.458 ms.

## Remaining scope

M6-023 is complete on Linux. This evidence does not claim results for Windows,
macOS, Android, iOS, or HarmonyOS.
