# M6-018 Linux acceptance evidence

Date: 2026-08-25

## Scope and environment

- Target: native Arch Linux x86_64.
- Cangjie compiler: `1.1.0-alpha.20260817040003`.
- cjpm: `1.1.3`.
- Task: integrate ALPN selection, HTTP/1.1 and HTTP/2 pools, and live
  multiplexed-stream capacity.

## Acceptance decision

| Acceptance criterion | Result | Evidence |
| --- | --- | --- |
| Prefer h2 and fall back to HTTP/1.1 | PASS | The automatic client offers `h2,http/1.1`; the native AWS-LC test proves HTTP/1.1 fallback, and the automatic-pipeline tests prove both negotiated routes execute and reuse the correct pool. |
| Allocate by connection stream capacity | PASS | Ten concurrent requests are mapped to one HTTP/2 connection, responses complete out of order, peer `MAX_CONCURRENT_STREAMS` is applied, and flow permits are consumed only when the single writer claims DATA. |
| Do not admit new requests on GOAWAY/draining connections | PASS | An accepted stream completes after peer GOAWAY, subsequent admission is rejected, RST fails only its stream, and pool tests exclude draining connections while releasing completed leases exactly once. |

## Implementation evidence

- `src/internal/http2/client_connection.cj` owns one reader, one writer,
  per-stream exchanges, response-body lifecycle, HPACK serialization, request
  DATA flow permits, RST isolation, and GOAWAY draining.
- `src/internal/http2/write_scheduler.cj` atomically queues header batches and
  couples DATA tickets to flow permits.
- `src/internal/http1/http2_connection_pool.cj` adapts executable HTTP/2
  connections to capacity-aware leases.
- `src/internal/http1/tls_client_pipeline.cj` routes a complete security pool
  key to bounded HTTP/2 or HTTP/1.1 pools and adopts the first ALPN-negotiated
  connection without reconnecting.
- `src/http/client.cj` and `src/http/tls.cj` use automatic h2-first ALPN for
  direct HTTPS. Existing HTTPS proxy behavior remains HTTP/1.1 and is outside
  this task's acceptance criteria.

## Commands and exact results

All commands ran from the repository root through the configured Cangjie
environment.

1. `cjpm test --no-run`
   - Exit 0; test-profile compilation finished; no warnings after final cleanup.
2. `cjpm test --skip-build --filter HttpAutomaticHttpsClientTest --no-progress --no-color`
   - Exit 0; 2 passed, 423 skipped, 0 errors, 0 failed.
   - Proves ten h2 requests use one negotiated connection and HTTP/1.1 fallback
     reuses the adopted connection.
3. `cjpm test --skip-build --filter Http1TlsServerTest --no-progress --no-color`
   - Exit 0; 3 passed, 422 skipped, 0 errors, 0 failed.
   - Includes native AWS-LC `h2,http/1.1` offer and explicit HTTP/1.1 fallback.
4. `cjpm test --skip-build --filter Http2ClientConnectionTest --no-progress --no-color`
   - Exit 0; 5 passed, 420 skipped, 0 errors, 0 failed.
   - Covers ten concurrent streams with out-of-order responses, request-body
     DATA, wire END_STREAM ownership, RST isolation, and GOAWAY draining.
5. `cjpm test --skip-build --filter Http2GoAwayManagerTest --no-progress --no-color`
   - Exit 0; 5 passed, 420 skipped, 0 errors, 0 failed.
6. `cjpm test --skip-build --no-progress --no-color --parallel 1 --report-path /tmp/wirestack-m6-018-serial-report --report-format xml`
   - Exit 0; the complete 425-test repository suite passed with no failed or
     errored test process. The XML files emitted by this cjpm version are
     package-worker partial artifacts, so they are not retained as a complete
     aggregate report.
7. `scripts/check`
   - Exit 0.
   - Python repository tests: 50 passed.
   - Python gate-runner tests: 63 passed.
   - Python benchmark-tool tests: 4 passed.
   - Architecture guard: PASS.
   - `cjpm check`, `cjpm build`, and `cjpm test`: success.

## Remaining scope

M6-018 is complete on Linux. HTTP/2 conformance/race/fuzz closure is M6-019;
1/10/100-stream benchmark evidence and documentation are M6-020. Neither is
claimed by this evidence.
