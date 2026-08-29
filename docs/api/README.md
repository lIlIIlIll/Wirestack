# Public API orientation

Wirestack exposes `wirestack.http` and `wirestack.tls`. Everything under
`wirestack.internal.*` is implementation detail and must not be imported by
consumers.

## `wirestack.http`

Use `HttpClient` and `HttpServer` for HTTP/1.1 and HTTP/2. The facade owns
routing, DNS, Happy Eyeballs, optional CONNECT, TLS, ALPN, pooling and body
lifecycle under one `OperationContext`.

Important types include `HttpClient`, `HttpServer`, `HttpRequest`,
`HttpResponse`, `HttpClientTlsConfig`, `HttpServerTlsConfig`, `HttpBodyStream`,
`RequestBody`, `ResponseBody`, and the request/connection/stream cancellation
handles. Consume or close every response body before its connection can return
to the pool.

See [the Linux HTTP guide](../guides/http1-linux.md).

## `wirestack.tls`

Use `TlsClientContext` or `TlsServerContext` when TLS wraps a caller-owned
`DuplexTransport`. Contexts are immutable after build and never expose AWS-LC
handles. Trust, reference identity, local identity, external signing and
transport ownership are separate typed contracts.

`TlsRuntime.info()` returns read-only provider/build diagnostics. It reports the
build-time selection; it does not choose or replace a provider.

## Stability and ownership

The [M7-032 Linux pre-1.0 inventory](baselines/wirestack-linux-pre1-m7-032.json)
records the current public contract. The earlier
[M7-026 snapshot](baselines/wirestack-linux-v0.json) remains historical
evidence and is not a compatibility target. Before 1.0, Wirestack does not
preserve source, API, ABI, or semantic compatibility with experimental APIs.

- wrapping a transport transfers its use to the TLS connection;
- `close` and `abort` are idempotent;
- one read and one write may overlap, but same-direction overlap fails;
- child work may shorten a deadline, never extend it;
- custom roots do not disable reference-identity verification;
- HTTP 4xx/5xx is a response, not a transport exception.

The complete public-only runnable consumer is under
[`examples/linux/m7_027`](../../examples/linux/m7_027/). Source declarations
remain the exact signature reference.

Validate the current inventory with:

```sh
scripts/check-m7-032-public-api --json
```

The gate verifies public ownership and rejects aliases to internal packages.
