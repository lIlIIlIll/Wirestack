# M6-026 HTTP/2 concurrent response-body evidence

- Task: `M6-026`
- Status: **COMPLETE**
- Platform: native Linux x86_64 glibc
- Date: 2026-08-28, UTC+8
- Compiler: Cangjie 1.1.0-alpha.20260817040003, cjnative
- Package manager: cjpm 1.1.3

## Failure and root cause

M7-022 first retained two public HTTP/2 response-body callers failing together
with `HttpErrorCode.ProtocolViolation`. The M6-026 real-TLS reproducer failed
before the product change at batches 616 and 472. A temporary, bounded reader
terminal diagnostic retained the first server-side failure:

```text
HTTP/2 peer stream ids must increase monotonically
```

Pool admission allocated increasing odd client stream IDs, but request
execution occurred in separate tasks. Consequently, stream 3 could enqueue its
initial HEADERS before stream 1. The server correctly treated the later stream
1 HEADERS as a connection-scoped protocol error. The client socket error was a
secondary consequence of the server closing that connection. Diagnostic
printing was removed before the final product change.

The fix orders only the enqueue of each newly admitted stream's initial HEADERS.
Request bodies, response bodies and subsequent frames remain multiplexed. An
unpublished lower stream that is cancelled advances the bounded ordering state
locally and does not emit RST_STREAM for an idle peer stream. The existing
OperationContext and five-second request Deadline remain the only timeout
owners.

## Current acceptance results

| Gate | Result |
| --- | --- |
| Ordered-initial-HEADERS and unpublished-cancellation regressions | PASS; `Http2ClientConnectionTest` 7/7 |
| Public real-TLS concurrent-body profile | PASS; 1,000 batches, 2,000 responses, 4,000 bytes, zero failure/timeout/residual handler |
| Gate fault-injection tests | PASS; 7/7, including short count, failure count, SKIPPED target, duplicate/missing marker and atomic replace failure |
| `src/http` non-Performance package | PASS; 67 passed, 3 skipped, 0 failed |
| Architecture guard | PASS |
| `scripts/check` | PASS; 132 repository-tool tests, 131 gate-tool tests, 23 benchmark-tool tests, architecture guard, `cjpm check`, build and 561/561 non-Performance Cangjie tests |

The machine-readable profile report is
[`linux_x86_64/concurrent-bodies.json`](linux_x86_64/concurrent-bodies.json).
M7-019 and M7-020 were refreshed in their own audit branches. M7-021 rebuilt
the release artifact and passed reproducibility, clean installation, public
HTTP/2 smoke and dependency scanning. M7-025 then rebound the SBOM, provider
manifest and build fingerprint to that artifact before the final repository
check ran.

## Commands

```text
scripts/check-m6-026-http2-concurrent-bodies --json
```

Result: exit 0. The report records exactly 1,000 batches, 2,000 responses,
4,000 bytes, zero failures, zero timeouts and zero active handlers.

```text
cangjie_env cjpm test src/http -j 1 --parallel 1 \
  --exclude-tags=Performance --show-all-output --no-progress --no-color
```

Result: exit 0; 67 passed, 3 skipped and 0 failed.

```text
scripts/architecture-guard
```

Result: exit 0; `architecture guard: PASS`.

```text
cangjie_env scripts/check
```

Result: final exit 0. Repository-tool tests passed 132/132, gate-tool tests
131/131, benchmark-tool tests 23/23, architecture guard, `cjpm check` and
`cjpm build` passed, and the non-Performance Cangjie suite passed 561 tests
with 23 explicitly skipped and zero failures. An earlier run failed closed on
stale M7-019, M7-020 and M7-021 evidence; those downstream artifacts were
refreshed rather than weakening the freshness checks.

## Boundaries

No SDK, runtime, std or stdx repository was modified or built. No one-hour SSE
profile, 24-hour release soak, musl test or non-Linux platform gate ran. No
remote branch was pushed.
