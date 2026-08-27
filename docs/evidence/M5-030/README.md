# M5-030 Linux acceptance evidence

Date: 2026-08-27

## Scope and environment

- Target: native Arch Linux x86_64, kernel `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003` (`cjnative`).
- Cangjie target: `x86_64-unknown-linux-gnu`.
- cjpm: `1.1.3`.
- Optimization: `-O2` for Wirestack and the stdx benchmark driver.
- Raw report: [`linux_x86_64/http1-benchmark.data`](linux_x86_64/http1-benchmark.data).

## Acceptance decision

| Acceptance criterion | Result |
| --- | --- |
| Keep-alive small-request throughput is at least 90% of current stdx | PASS: Wirestack 10,073.727 req/s, stdx 4,829.858 req/s, ratio 2.0857 |
| Streamed large-body memory does not grow linearly with body size | PASS: 16 MiB peak RSS 24,996 KiB; 64 MiB peak RSS 24,048 KiB; growth -948 KiB and ratio 0.962 |
| Client and server example | PASS: [`http1-linux.md`](../../guides/http1-linux.md#cleartext-client-and-server) |
| CONNECT example | PASS: [`http1-linux.md`](../../guides/http1-linux.md#https-through-an-explicit-connect-proxy) |
| mTLS example | PASS: [`http1-linux.md`](../../guides/http1-linux.md#mutual-tls) |

The M5-030 native Linux result is PASS.

## Baseline and method

The comparison uses Cangjie/cangjie_stdx release `v1.1.3.1`, commit
`8fa4b04b4cb1753e8f3581e4935cf72ad145fedc`. The pinned reference records the
release asset ID and SHA-256 values for the archive, Cangjie object, and shared
library. The runner verifies every hash before use.

Each implementation handles 200 warm-up requests and 2,000 measured empty
responses over one loopback keep-alive connection. Seven rounds run in
alternating order. The report compares median durations. The streaming cases
consume 16 MiB and 64 MiB without retaining the full body and sample aggregate
RSS and file descriptors for the process tree.

## Commands and exact results

1. `python3 -m py_compile tools/benchmarks/http1_benchmark.py`
   - Exit 0.
2. `python3 -m unittest tools/benchmarks/tests/test_http1_benchmark.py -v`
   - Exit 0; 7 tests passed.
3. `python3 -m json.tool docs/references/stdx-http1-baseline-linux.data`
   - Exit 0.
4. `env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack python3 tools/benchmarks/http1_benchmark.py --stdx-archive /tmp/cangjie-stdx-linux-x64-1.1.3.1.zip --stdx-root /tmp/wirestack-stdx-1.1.3.1.sAN2Jp --output docs/evidence/M5-030/linux_x86_64/http1-benchmark.json`
   - Exit 0; overall PASS.
   - The raw JSON uses a `.data` suffix because local global ignore rules cover
     `.json` and `.txt`; no cross-task `.gitignore` edit is required.
   - Keep-alive: Wirestack 10,073.727 req/s; stdx 4,829.858 req/s; ratio 2.0857.
   - Streaming memory: -948 KiB growth; ratio 0.962; PASS.
5. `scripts/check`
   - Exit 0.
   - Python architecture and repository tests: 50 passed.
   - Python gate tests: 89 passed.
   - Python benchmark tests: 11 passed.
   - Architecture guard: PASS.
   - `cjpm check` and `cjpm build`: success. The build retains two existing
     unused-function warnings.
   - `cjpm test --exclude-tags=Performance`: 509 passed, 4 skipped, 0 errors,
     0 failed. The skipped cases are the four benchmark classes that the formal
     runner executes separately from the ordinary test gate.

## Remaining scope

M5-030 is complete on native Linux x86_64 glibc. This evidence does not claim
results for Linux musl, Windows, macOS, Android, iOS, or HarmonyOS.
