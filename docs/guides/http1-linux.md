# Linux HTTP client and server

Wirestack's Linux facade uses typed endpoints. `HttpClient.builder().build()`
owns a bounded `SystemResolver` by default. A resolver passed through
`HttpClientBuilder.resolver` remains caller-owned. The facade never consults
proxy environment variables, PAC, or WPAD.

`SystemResolver` runs blocking system DNS calls on a fixed native worker pool.
Its default bounds are four workers and 64 queued requests. The result retains
all candidates up to `ResolveOptions.maxResults`, does not invent a TTL, and
maps native resolver failures to `ResolveErrorCode`.

## Cleartext client and server

```cj
import std.fs.File
import wirestack.http.*

let loopback = IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8080))
    .handler(MyHandler())
    .connectionLimit(256)
    .build()
let serving = spawn { server.serve() }

let host = HostName("service.internal")
let client = HttpClient.builder()
    .resolver(StaticResolver(ResolveResult([loopback], host, ResolverSource.Static)))
    .requestTimeout(5 * Duration.second)
    .build()
let response = client.get("http://service.internal:8080/ready")
try {
    let buffer = Array<Byte>(16 * 1024, repeat: 0)
    let _ = response.body.read(buffer) // Continue until EOF in real code.
} finally {
    response.close()
    client.close()
    let _ = server.shutdown(context: OperationContext(
        deadline: Some(Deadline.after(5 * Duration.second))))
    serving.get(5 * Duration.second)
}
```

`MyHandler` implements `HttpServerHandler` and returns `HttpServerResponse`.
Always consume or close the request body before returning when the connection
should remain reusable.

## Total and phase-specific deadlines

Existing `HttpClientBuilder.requestTimeout` callers need no migration. It remains a cap for the complete request, including retries, redirects, and response-body reads. Add `OperationTimeoutPolicy` through `OperationContext` when one phase needs a shorter limit. If both `requestTimeout` and `OperationContext.deadline` are set, the earlier absolute deadline wins.

Every configured stage limit must be positive and cannot extend the absolute deadline. An omitted stage limit adds no extra timer. Retries and redirects reuse the request deadline rather than starting a new total budget. For HTTP/1 `Expect: 100-continue`, one `responseHeaders` budget covers both the continue wait and the final response headers. Sending the request body does not restart that budget.

```cj
let loopback = IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
let host = HostName("service.internal")
let client = HttpClient.builder()
    .resolver(StaticResolver(ResolveResult([loopback], host, ResolverSource.Static)))
    .requestTimeout(60 * Duration.second)
    .build()
let context = OperationContext(
    deadline: Some(Deadline.after(45 * Duration.second)),
    timeoutPolicy: OperationTimeoutPolicy(
        requestAdmission: Some(Duration.second),
        connectionPool: Some(2 * Duration.second),
        dns: Some(3 * Duration.second),
        tcpConnect: Some(5 * Duration.second),
        responseHeaders: Some(8 * Duration.second),
        bodyReadIdle: Some(15 * Duration.second)
    )
)
let response = client.get(
    "http://service.internal:8080/ready", context: context
)
try {
    let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = response.body.read(buffer)
        if (count == 0) { break }
        // Pass buffer[0..count] to the application parser.
    }
} finally {
    response.close()
    client.close()
}
```

`bodyReadIdle` starts only when the application calls `ResponseBody.read`. It does not count time spent processing a chunk between calls. HTTP/2 keeps the idle wait on the target response stream. A sibling stream or connection PING does not count as body progress. Outbound HTTP/2 `WINDOW_UPDATE` writes retain the caller's total deadline and cancellation token; they do not use the inbound body idle limit.

## Long-lived response and WebSocket streams

Use `bodyReadIdle` for SSE response bodies and `streamReadIdle` for WebSocket or upgraded-stream reads. Pass the same `OperationContext` to the WebSocket handshake and each `receive` call when one total deadline should cover the complete session. A two-hour total deadline below leaves each active read a 45-second idle cap.

`bodyReadIdle` observes HTTP response-body progress, not decoded SSE events. Comment or heartbeat bytes may satisfy body progress without representing a business event. The current API has no SSE event-level watchdog; event and comment semantics belong to an explicit future SSE codec/session policy.

```cj
let client = HttpClient.builder().build()
let streamContext = OperationContext(
    deadline: Some(Deadline.after(2 * 60 * 60 * Duration.second)),
    timeoutPolicy: OperationTimeoutPolicy(
        dns: Some(5 * Duration.second),
        tcpConnect: Some(5 * Duration.second),
        tlsHandshake: Some(10 * Duration.second),
        responseHeaders: Some(10 * Duration.second),
        bodyReadIdle: Some(45 * Duration.second)
    )
)
let events = client.get(
    "https://events.example.com/events", context: streamContext
)
try {
    let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = events.body.read(buffer)
        if (count == 0) { break }
        // Feed buffer[0..count] to the application SSE parser.
    }
} finally {
    events.close()
    client.close()
}
```

For WebSocket, use the stream idle field and reuse the context for `receive`:

```cj
let streamContext = OperationContext(
    deadline: Some(Deadline.after(2 * 60 * 60 * Duration.second)),
    timeoutPolicy: OperationTimeoutPolicy(
        dns: Some(5 * Duration.second),
        tcpConnect: Some(5 * Duration.second),
        tlsHandshake: Some(10 * Duration.second),
        responseHeaders: Some(10 * Duration.second),
        streamReadIdle: Some(45 * Duration.second)
    )
)
let client = HttpClient.builder().build()
try {
    match (client.connectWebSocket(
        HttpUrl.parse("https://events.example.com/socket"), context: streamContext
    )) {
        case WebSocketConnectResult.Connected(socket) =>
            try {
                let frame = socket.receive(context: streamContext)
                let _ = frame.opcode
            } finally {
                socket.close(1000u16, "done", context: streamContext)
            }
        case WebSocketConnectResult.Rejected(response) => response.close()
    }
} finally {
    client.close()
}
```

If an event source should run without a fixed lifetime, omit the total deadline intentionally and keep phase and active-read limits. The `requestTimeout` builder setting still supplies a total cap when configured.

## Aggregate resource budgets

Each `HttpClient` and `HttpServer` owns one resource ledger shared by its routes and protocol pools. Configure a client with `HttpClientBuilder.resourceLimits` or a server with `HttpServerBuilder.resourceLimits`; `HttpResourceLimits.clientDefault()` and `serverDefault()` select the defaults. `HttpClient.resourceSnapshot()` and `HttpServer.resourceSnapshot()` return a single-lock point-in-time sample with a monotonic `sampledAt`, active and reserved connection/stream counts, lifetime high-water counts, effective limits, and current non-empty origin/route owners. Connection and stream high-water counts include both active and not-yet-activated reservations. Owner rows expose active and reserved counts separately; they are snapshots, not stable identities or ordered output.

`maximumManagedBufferBytesPerRoute` and `maximumManagedBufferBytesPerOrigin` bound DATA bytes attributed to a route+origin and to all routes for an origin. `maximumOwners` bounds the number of live origin/route ledger rows. These are independent of connection, request, and stream ceilings.

```cj
let limits = HttpResourceLimits(
    maximumConnections: 64,
    maximumConnectionsPerRoute: 16,
    maximumConnectionsPerOrigin: 32,
    maximumManagedBufferBytesPerRoute: 16777216u64,
    maximumManagedBufferBytesPerOrigin: 33554432u64,
    maximumOwners: 4096
)
let client = HttpClient.builder()
    .resourceLimits(limits)
    .build()
let snapshot = client.resourceSnapshot()
```

The default limits are:

| Limit | Client | Server |
| --- | ---: | ---: |
| Connections, instance | 128 | 1024 |
| Connections, one route + origin | 16 | 1024 |
| Connections, one origin across routes | 32 | 1024 |
| Requests, instance | 4096 | 4096 |
| Requests, one route + origin | 1024 | 1024 |
| Requests, one origin across routes | 2048 | 2048 |
| HTTP/2 streams, instance | 4096 | 4096 |
| HTTP/2 streams, one route + origin | 1024 | 1024 |
| HTTP/2 streams, one origin across routes | 2048 | 2048 |
| Managed HTTP/2 buffers, instance | 128 MiB | 128 MiB |
| DATA buffers, one route + origin | 32 MiB | 16 MiB |
| DATA buffers, one origin across routes | 64 MiB | 32 MiB |
| Control and cleanup buffer reserve | 1 MiB | 1 MiB |
| Aggregate admission waiters | 256 | 256 |
| Current origin/route owner rows | 8192 | 8192 |

The server's legacy `connectionLimit` can lower its effective connection ceiling. A route count is scoped to the exact route-and-origin owner pair; origin counts aggregate those owners. The per-route and per-origin DATA-byte limits include received body DATA and serialized writer DATA, but not control frames. Defaults may be replaced with positive limits subject to cross-field constraints. Hard validation bounds are 65,536 connections, 1,000,000 requests, 1,000,000 streams, 65,536 waiters, and 65,536 owner rows; managed buffers are capped at 1 GiB. The control reserve must contain at least 17 bytes per configured connection for cleanup traffic. The managed-buffer limit must also leave more than 65,535 bytes per configured connection after its control reserve, so a configuration can be rejected even when each individual field is below its hard bound.

Client admission waits use the request's original `OperationContext`, including its absolute deadline and cancellation token. Cancelling or timing out removes that waiter; admitting beyond `maximumWaiters` fails with `NetworkException` in `PoolAcquire` and `ResourceExhausted`. The ledger wakes eligible bounded waiters as leases are released. A full owner-row table does not allocate another owner. Existing connection-pool and HTTP/2 writer queue limits remain separate; `admissionWaiters` reports only waiters on the shared resource ledger. Server request/stream admission is nonblocking: HTTP/1.1 request exhaustion returns 503 and closes that connection; HTTP/2 request or stream exhaustion is refused with `REFUSED_STREAM`.

`maximumManagedBufferBytes` shares one cap across received HTTP/2 DATA retained in body segments and serialized writer frames that are queued or active. The control reserve is unavailable to DATA and is split between ordinary control traffic and protected cleanup capacity. Received DATA is charged before the parser allocates its payload array; if its owner or aggregate budget is full, the reader discards the payload without retaining that array and refuses the stream instead of waiting. Writer-side backpressure waits under the original operation context. Body consumption, body close/reset, write completion, cancellation, and terminal failure release the corresponding byte reservation.

`managedBufferBytes` and its high-water value report logical accounted bytes: received DATA payload bytes (including padding) plus complete serialized outbound frame bytes. They are not process-memory or RSS measurements and exclude application/source buffers, native TLS and runtime memory, OS socket buffers, frame-header/parser scratch, and transient serialization allocations.

## Typed cancellation handles

Create a handle before starting a request when another task must stop work
without owning the response object:

```cj
let requestCancellation = HttpRequestCancellationHandle()
let streamCancellation = HttpStreamCancellationHandle()
let response = client.getControlled(
    "https://service.internal/events",
    HttpCancellationHandles(
        request: Some(requestCancellation),
        stream: Some(streamCancellation)
    )
)

// Either call is idempotent; exactly one caller observes true.
let _ = streamCancellation.cancel()
response.close()
```

`HttpRequestCancellationHandle` covers the complete request path from routing
and DNS through response-body EOF. `HttpStreamCancellationHandle` sends one
HTTP/2 `RST_STREAM` and leaves sibling streams usable. HTTP/1.1 has no
independent stream scope, so cancelling its current stream/request terminates
the exclusive connection. `HttpConnectionCancellationHandle` aborts the
selected H1 connection or every stream on the selected H2 connection.

Server handlers receive the same typed control surface on
`HttpServerRequest`: `requestCancellation`, `connectionCancellation`, and an
optional `streamCancellation` that is present only for HTTP/2. Handler contexts
observe cancellation through the same immutable `OperationContext`; no second
timeout owner is created.

## TLS HTTP/2 and HTTP/1.1 server

Certificate chains are leaf-first DER arrays; private keys are exact,
unencrypted DER PKCS#8 objects.

```cj
let tls = HttpServerTlsConfig(
    [File.readFrom("/etc/wirestack/server-leaf.der")],
    File.readFrom("/etc/wirestack/server-key.pk8")
)
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8443))
    .handler(MyHandler())
    .tls(tls)
    .http2StreamLimit(100u32)
    .build()
tls.close() // The built server owns validated provider/key state.
```

The same server offers `h2,http/1.1` and dispatches only from the protocol
retained in the completed TLS handshake. The public request reports
`HttpVersion.Http2` or `HttpVersion.Http11`; no internal HTTP/2 or TLS type
enters the handler API. `http2StreamLimit` is the advertised and enforced
per-connection concurrent-stream bound. A client with no shared protocol, or
one that completes without negotiated ALPN evidence, fails the handshake.

## HTTPS through an explicit CONNECT proxy

```cj
let proxyHost = HostName("proxy.internal")
let proxyResolver = StaticResolver(ResolveResult(
    [proxyAddress], proxyHost, ResolverSource.Static))
let proxy = HttpProxyConfig(
    HttpProxyEndpoint.hostname("proxy.internal", 3128),
    proxyResolver,
    authorizationProvider: Some(MyProxyAuthorizationProvider())
)
let client = HttpClient.builder()
    .resolver(originResolver)
    .proxy(proxy)
    .requestTimeout(10 * Duration.second)
    .build()
let response = client.get("https://service.internal/private")
```

The authorization hook runs only for the proxy request. Caller-supplied
`Proxy-Authorization` is removed, credentials are sent on CONNECT only, origin
DNS remains independent, and TLS SNI/reference identity remains the origin.

## Mutual TLS

The same custom root and client identity configuration works for direct HTTPS
and HTTPS-over-CONNECT:

```cj
let serverTls = HttpServerTlsConfig(
    [serverLeafDer], serverPrivateKeyPkcs8Der,
    clientAuthentication: HttpServerClientAuthentication.Required,
    clientTrustRootsDer: [clientCaDer]
)
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8443))
    .handler(MyHandler())
    .tls(serverTls)
    .build()

let clientTls = HttpClientTlsConfig(
    [serverCaDer],
    clientCertificateChainDer: [clientLeafDer],
    clientPrivateKeyPkcs8Der: clientPrivateKeyPkcs8Der
)
let client = HttpClient.builder()
    .resolver(originResolver)
    .tls(clientTls)
    .build()

serverTls.close()
clientTls.close()
```

All DER inputs are bounded and validated before network use. Closing a config
zeroes its retained key copy; the built client/server owns a separate validated
key reference until it is closed.

## Structured events and stable errors

Install an event sink on the immutable operation context when a request needs
diagnostic evidence:

```cj
class MySink <: NetworkEventSink {
    public func emit(event: NetworkEvent): Unit {
        // Enqueue quickly; emit may run concurrently for connection attempts.
        metrics.record(event.kind, event.outcome)
    }
}

let context = OperationContext(
    trace: Some(NetworkTraceContext("request-42", spanId: "fetch")),
    eventSink: Some(MySink())
)
let response = client.get("https://service.internal/data", context: context)
```

The sink is disabled by default. Sink exceptions are isolated from network I/O.
Events contain only typed lifecycle outcome, phase, stable network error code,
opaque trace identifiers and an optional connection ID. Their type has no field
for URLs, headers, cookies, authorization values, bodies, certificates, keys or
session secrets.

Public HTTP protocol/policy failures use `HttpException.code`, including
`InvalidUrl`, `InvalidRequest`, `InvalidResponse`, `HeaderLimitExceeded`,
`BodyLimitExceeded`, `InvalidFraming`, `ProxyFailure`, `PoolExhausted`,
`RedirectLimit` and `BodyNotReplayable`. HTTP 4xx/5xx remain normal responses.
