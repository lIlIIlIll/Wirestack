# M6-026 HTTP/2 concurrent response-body evidence

- Task: `M6-026`
- Status: **INCOMPLETE** pending downstream release-evidence refresh
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
| `scripts/check` | FAIL-CLOSED before Cangjie build: M7-019/M7-020 source digests and M7-021 release fingerprint are stale after the backlog and product-source changes |

The machine-readable profile report is
[`linux_x86_64/concurrent-bodies.json`](linux_x86_64/concurrent-bodies.json).
The task remains INCOMPLETE until the three downstream release artifacts are
refreshed in their own task scopes and the final repository check passes.

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

Result: exit 1 during the tool-test phase. All M6-026 gate tests passed. The
reported 8 failures and 3 errors were freshness failures from M7-019, M7-020
and M7-021; no product or M6-026 regression failed.

## Boundaries

No SDK, runtime, std or stdx repository was modified or built. No one-hour SSE
profile, 24-hour release soak, musl test or non-Linux platform gate ran. No
remote branch was pushed.
