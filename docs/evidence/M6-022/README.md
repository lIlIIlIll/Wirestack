# M6-022 Linux acceptance evidence

Date: 2026-08-26

## Scope and environment

- Target: native Arch Linux x86_64, kernel `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003` (`cjnative`).
- cjpm: `1.1.3`.
- Task: public request, connection and HTTP/2 stream cancellation handles.

## Acceptance decision

| Acceptance criterion | Result | Evidence |
| --- | --- | --- |
| Typed, idempotent public handles | PASS | `HttpRequestCancellationHandle`, `HttpConnectionCancellationHandle` and `HttpStreamCancellationHandle` expose exact scopes. Sequential and 64-caller concurrent tests prove exactly one successful `cancel()` claim. |
| Request cancellation spans the full operation | PASS | `getControlled`/`sendControlled` link a request handle into the same immutable `OperationContext` before route and DNS work and retain it through response-body EOF or close. A pre-cancelled request performs no network call; a body-stage cancellation returns structured `Cancelled`. |
| HTTP/1.1 connection cancellation | PASS | A real cleartext loopback request reads part of a 256-KiB body, cancels its connection handle, wakes with structured `Cancelled`, discards the exclusive connection and then succeeds through a fresh connection. |
| HTTP/2 stream isolation | PASS | A real native TCP/TLS h2 request cancels one streaming body, emits local stream cancellation, and retains both a sibling response and subsequent requests on the same connection. |
| HTTP/2 connection fan-out | PASS | A real h2 connection handle cancels two active response streams on the selected connection; both waiters receive structured `Cancelled` and all exchange registrations and flow ownership are released. |
| Server facade control surface | PASS | Public handlers receive request and connection handles for H1/H2 and an optional stream handle only for H2. H1 request scope binds to its exclusive connection; H2 request/stream scope binds to one `RST_STREAM`. |
| Exactly-once terminal cleanup | PASS | Response EOF/close/error and cancellation converge on idempotent observers. H1 cancellation registrations are unregistered on every terminal path; H2 stream/connection/reset/GOAWAY/reader registrations, body channel, flow ownership and dispatcher membership are released by one terminal claim. Existing GOAWAY and close races remain green in the full suite. |
| Existing public client API retained | PASS | Existing `HttpClient.get` and `HttpClient.send` declarations remain unchanged. Controlled cancellation is additive through separately named `getControlled` and `sendControlled` methods and new public types. |

## Implementation evidence

- `src/http/cancellation.cj` defines the public typed handles, links them to the
  canonical operation context, and retains registrations through body lifetime.
- `src/http/client.cj` adds additive controlled-request entry points while
  preserving the existing `get` and `send` declarations.
- `src/http/server.cj` exposes scoped handles to handlers and binds them to the
  selected H1 connection or H2 stream/connection owner.
- `src/internal/http1/client_connection.cj` and `response_reader.cj` wake and
  classify connection/body cancellation without returning buffered bytes after
  cancellation.
- `src/internal/http2/client_connection.cj` isolates stream cancellation and
  fans connection cancellation out to every active exchange with prompt cleanup.
- `src/http/facade_test.cj` exercises all public scopes over real Linux loopback
  H1 and native AWS-LC/TLS H2 connections.

## Commands and exact results

All commands ran from the repository root through the configured Cangjie
environment.

1. `cjpm test src/http --filter HttpFacadeTest --no-color`
   - Exit 0; 12 passed, 45 skipped, 0 errors, 0 failed.
   - The three new public cancellation cases complete in 5 ms, 18 ms and
     263 ms respectively in the retained final focused run.
2. `cjpm test src/internal/http1 --filter Http1ClientConnectionTest,Http1ResponseReaderTest,Http2ConnectionPoolTest --no-color`
   - Exit 0; 22 passed, 87 skipped, 0 errors, 0 failed.
3. `cjpm test src/internal/http2 --filter Http2ClientConnectionTest --no-color`
   - Exit 0; 5 passed, 140 skipped, 0 errors, 0 failed.
4. `scripts/check`
   - Exit 0.
   - Python architecture/tool tests: 50 passed.
   - Python gate-runner tests: 80 passed.
   - Python benchmark-tool tests: 8 passed.
   - Architecture guard: PASS.
   - `cjpm check`: success.
   - `cjpm build`: success, with one pre-existing unused-function warning for
     `waitUntilWaiters` in `src/internal/http1/connection_pool.cj`.
   - `cjpm test`: 444 passed, 0 skipped, 0 errors, 0 failed.

## 2026-08-27 stability follow-up

A repeated run exposed a race in the public HTTP/2 cancellation acceptance
test before cancellation was requested. The test consumed 4 KiB from a
256-KiB response and then waited for a sibling body. When the first response
won the scheduling race and exhausted the 65,535-byte connection window, the
4-KiB consumption remained below the coalesced WINDOW_UPDATE threshold and the
sibling read reached the shared five-second deadline.

The acceptance order now opens the sibling response, cancels the first stream,
verifies the first body receives structured `Cancelled`, and only then reads
the sibling body. This directly verifies the M6-022 contract: stream
cancellation returns connection credit and does not terminate an already-open
sibling. It does not weaken the deadline or change production flow-control
policy.

1. Pre-fix repeated focused run
   - Command: 100 sequential `cjpm test --skip-build` invocations filtered to
     `HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes`.
   - Result: exit 1 after a focused invocation reported
     `NetworkException: HTTP/2 operation deadline exceeded` at
     `facade_test.cj:164` while reading the sibling before cancellation.
2. Post-fix focused rebuild
   - Exit 0; 1 passed, 547 skipped, 0 errors, 0 failed.
3. Post-fix repeated focused run
   - The same 100 sequential filtered `--skip-build` invocations passed
     100/100.
4. Post-fix `scripts/check`
   - Exit 0.
   - Python architecture/tool tests: 57 passed.
   - Python gate-runner tests: 110 passed.
   - Python benchmark-tool tests: 11 passed.
   - Architecture guard: PASS.
   - `cjpm check` and `cjpm build`: success.
   - `cjpm test`: 548 total; 532 passed, 16 skipped, 0 errors, 0 failed.

## Remaining scope

M6-022 remains complete on native glibc Linux. M6-023 is tracked and evidenced
separately; this follow-up makes no new platform claim.
