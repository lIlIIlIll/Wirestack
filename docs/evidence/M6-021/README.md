# M6-021 Linux acceptance evidence

Date: 2026-08-26

## Scope and environment

- Target: native Arch Linux x86_64, kernel `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003` (`cjnative`).
- cjpm: `1.1.3`.
- Task: public HTTP/2 server facade, TLS ALPN dispatch, and Linux end-to-end
  acceptance.

## Acceptance decision

| Acceptance criterion | Result | Evidence |
| --- | --- | --- |
| One public server dispatches only by negotiated ALPN | PASS | A real TCP/TLS loopback test reaches the same `HttpServer` first with the automatic h2 client and then with an HTTP/1.1-only client. The handler observes only public `HttpVersion.Http2` and `HttpVersion.Http11`. |
| H2 request/body/trailer/response mapping | PASS | The public client sends a POST body plus trailer and receives status, body and response trailer through the public handler facade. |
| Bounded concurrent streams | PASS | With `http2StreamLimit(1)`, two overlapping public requests complete through two bounded negotiated connections; both connections drain without abort. Existing registry tests reject over-limit streams within one connection. |
| GOAWAY graceful shutdown | PASS | Shutdown begins while negotiated H2 connections remain pooled, emits GOAWAY, stops new stream admission, drains accepted streams and returns `aborted=0`, `activeAtReturn=0`. |
| Structured errors | PASS | A server-handler failure resets only its H2 stream and the public client receives `HttpErrorCode.StreamReset`; the containing connection remains usable until graceful shutdown. |
| No shared protocol fails stably | PASS | A native AWS-LC client offering only `wirestack.invalid` and the server offering `h2,http/1.1` both reject the handshake; the server retains `TlsEngineErrorCode.NoSharedAlpn`. |
| No internal H2/TLS public types | PASS | The public facade exposes `HttpServer`, `HttpServerRequest`, `HttpServerResponse`, `HttpVersion` and the scalar `http2StreamLimit`; the architecture guard passes. |

## Implementation evidence

- `src/internal/http2/server_connection.cj` composes one reader, one bounded
  writer, stream registry, flow control, reset handling, HPACK mapping and
  GOAWAY drain for each accepted h2 transport.
- `src/internal/http1/tls_server.cj` returns a protocol-neutral negotiated
  transport and fails closed without supported ALPN evidence.
- `src/internal/http1/server.cj` retains the bounded listener lifecycle while
  delegating each accepted transport to a protocol-neutral connection owner.
- `src/http/server.cj` adapts H1 and H2 requests to the same public handler and
  tracks live H2 connections for server shutdown.
- `src/http/error.cj` maps H2 stream and connection protocol failures to
  stable public error codes.

## Commands and exact results

All commands ran from the repository root through the configured Cangjie
environment.

1. `cjpm test src/http -j 1 --parallel 1 --filter HttpFacadeTest --show-all-output --no-progress --no-color`
   - Exit 0; 9 passed, 45 skipped, 0 errors, 0 failed.
   - Includes real native TLS H2/H1 dispatch, body/trailer mapping, structured
     reset, stream-capacity routing and graceful shutdown.
2. `cjpm test src/internal/http1 -j 1 --parallel 1 --filter Http1TlsServerTest --show-all-output --no-progress --no-color`
   - Exit 0; 4 passed, 105 skipped, 0 errors, 0 failed.
   - Includes no-shared-ALPN failure and h2-first client/H1 fallback.
3. `cjpm test src/internal/http2 -j 1 --parallel 1 --filter Http2ServerMappingTest --show-all-output --no-progress --no-color`
   - Exit 0; 9 passed, 136 skipped, 0 errors, 0 failed.
   - Covers strict request mapping, bounded body flow accounting, response
     streaming/trailers and exactly-once handler ownership.
4. `scripts/check`
   - Exit 0 after the final GOAWAY admission-race fix.
   - Python architecture/tool tests: 50 passed.
   - Python gate-runner tests: 80 passed.
   - Python benchmark-tool tests: 8 passed.
   - Architecture guard: PASS.
   - `cjpm check`: success.
   - `cjpm build`: success, with one pre-existing unused-function warning for
     `waitUntilWaiters` in `src/internal/http1/connection_pool.cj`.
   - `cjpm test`: 441 passed, 0 skipped, 0 errors, 0 failed.

## Remaining scope

M6-021 is complete on Linux. Typed public request, connection and stream
cancellation handles remain M6-022. The one-hour/one-million-event H1/H2 SSE
steady-state profile remains M6-023 and is blocked on M6-022.

## 2026-08-27 stream-capacity race revalidation

The canonical full suite later exposed an intermittent deadline error in
`tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests`. Running the
already-built test directly reproduced 5 failures in 20 rounds. Two independent
ordering defects were closed:

- `Http2ConnectionPool.acquire` now admits the creator's first stream before
  publishing a new connection. A concurrent request can no longer claim the
  apparently empty connection during that publication window and then have its
  lease invalidated when the creator's admission loses the capacity race.
- The end-to-end handler now separates monotonic arrival count from current
  active count. A waiter can no longer miss the transient active count of two
  when its sibling returns first.

The deterministic pool regression holds first admission at a gate and proves
that the connection remains reserved but unpublished until the stream claim
succeeds. The same real TLS loopback test then passed 20 of 20 direct rounds;
the complete non-performance Cangjie suite passed 511 tests with 4 tagged tests
skipped and no failures or errors. Raw summary data is retained in
[`linux-x86_64/stream-limit-race.data`](linux-x86_64/stream-limit-race.data).
