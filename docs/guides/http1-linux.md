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

Every configured stage limit must be positive and cannot extend the absolute deadline. An omitted stage limit adds no extra timer. Retries and redirects reuse the request deadline rather than starting a new total budget.

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

`bodyReadIdle` starts only when the application calls `ResponseBody.read`. It does not count time spent processing a chunk between calls. HTTP/2 keeps the idle wait on the target response stream. A sibling stream or connection PING does not count as body progress.

## Automatic retries

Automatic retries require a replayable request body and an attempt slot below `HttpRetryPolicy.maximumAttempts`. Idempotent methods are eligible by default; `HttpRetrySafety.ExplicitlySafe` opts an otherwise non-idempotent request in, while `HttpRetrySafety.Disabled` opts it out.

Before request submission, retries require a structured retryable DNS, address-selection, TCP/proxy-connect, TLS-handshake, or pool-acquisition failure. HTTP/1 write failures use commit evidence: `SafeBeforeWrite` requires zero committed request bytes; a submitted request can retry only with structured retryability and replay safety. HTTP/2 GOAWAY retries only streams explicitly identified as not processed. Generic HTTP response-phase failures do not prove that the request was unprocessed and are not retried.

All attempts reuse the original absolute request deadline and cancellation context.

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

Install a caller-owned bounded buffer when an operation needs diagnostic evidence:

```cj
import wirestack as api
import wirestack.http.*

let events = api.NetworkEventBuffer(capacity: 256)
let context = api.OperationContext(
    deadline: Some(api.Deadline.after(10 * Duration.second)),
    eventSink: Some<api.NetworkEventSink>(events),
    requestId: Some(42)
)
let response = client.get("https://example.test/data", context: context)
let retained = client.observationSnapshot(observations: Some<api.NetworkEventStatistics>(events))
response.close()
let completed = client.observationSnapshot(observations: Some<api.NetworkEventStatistics>(events))
let records = events.drain()
```

The default context has no sink, worker or global event service. The buffer
allocates fixed slots once, accepts concurrent producers, drops newest when
full, and releases retained references on FIFO drain. Capacity is 1–4096;
cumulative drops saturate rather than wrap.

### Correlation and completion

| Field or event | Meaning |
| --- | --- |
| `requestId` | One logical client send across retries/redirects. Supplied positive IDs are preserved; observed sends allocate an absent ID. |
| `attemptId` | One protocol execution, not a DNS candidate. Retries/redirects get distinct IDs. |
| `connectionId` | Process-local physical identity, allocated before creation and preserved through ALPN adoption, reuse and drain. |
| `streamId` | Actual H2 wire stream ID, scoped by connection. H1 invents no stream ID. |
| `connectionAttemptIndex` | One-based Happy Eyeballs candidate position. Skipped candidates are `NotExecuted` without fake starts. |
| `RequestCompleted` | Logical client send returned final headers or failed, once rather than per retry. It is not body consumption. Server request events surround handler dispatch. |
| `AttemptCompleted` | One execution returned headers or failed; a retry may follow. |
| `BodyCompleted` | The separately retained body owner terminated. Unread-body abandonment differs from successful EOF and logical request failure. |

Body and connection terminal emissions are exactly once. Complete H2
END_STREAM responses retain readable bytes after graceful connection EOF;
that EOF does not retrospectively fail a completed stream. No identifier
registry or per-identifier metric map exists. IDs are local correlations, not
automatic HTTP-header propagation between processes.

### Real stages and deadline causes

Admission, pool acquisition, DNS, indexed TCP attempts, proxy CONNECT, TLS,
request write, response headers and active body reads use their operative
contexts. Release, drain and close follow actual ownership transitions.
Reused connections report DNS/TLS `NotExecuted`, not zero-duration work.
Incoming server headers and response writes retain their existing operation
budget and direction-neutral phases; observation adds no timeout owner.

`occurredAt` uses the operation's monotonic clock; `stage` is the active stage.
For a proved expired effective budget, `timeoutReason` distinguishes
`TotalDeadline` from `StageLimit`; `timeoutStage` names the cap owner, which
can differ from the failing stage. Unexpired native timeouts and aggregate
failures without that proof leave the cause absent. Join the real stage event
with its request/attempt instead of inventing a cause from summary events.
`LocalBackpressureStarted/Completed` measure actual H2 send flow-window or
admitted-permit waits, not remote response delay.

### Read-only owner snapshots

`HttpClient.observationSnapshot()` combines its actual aggregate ledger,
current/retained route pools, TLS/direct/proxy DNS generations, optional
resolver owners and optional caller-supplied event statistics.
`HttpServer.observationSnapshot()` combines its ledger, current/retained TLS
generations and draining accepted connections. Each owner is sampled
independently; the composite is deliberately not a cross-owner atomic instant.

Pools expose leased, idle, connecting, queued, active/reserved stream and
draining counts. The ledger exposes active/reserved requests, streams and
managed bytes, real bounded-admission rejections and cancellation measurements.
Latency starts when Wirestack observes cancellation and ends after the
measured request/stream/exchange leases are released. It does not measure
arbitrary callbacks that ran before Wirestack or unrelated connection writer
reservations. No completed cancellation means absent latency, not fake zero.

Stock `wirestack.http.SystemResolver`, `wirestack.net.DnsClient` and
`wirestack.net.Resolver` expose `ResolverResourceOwner`: active/queued queries,
running native/protocol work, cache entries and rejections. A cancelled caller
can finish while uncancellable native getaddrinfo still runs; that work remains
visible. A closed native owner retains its final sample with `isLive == false`
and the original timestamp, not current zero work. A custom resolver without
the capability increments `unavailableResolvers`; its counters are unknown.

### Optional asynchronous export

Import `wirestack.observability` only for asynchronous export. Implement
`NetworkEventExporter.export(events, context)` and explicitly construct
`BoundedNetworkEventSink` with `NetworkEventSinkConfig`. Producers never wait
for capacity. Queue capacity is 1–4096, batch size 1–capacity, and sampling
denominator 1–65536. Stable sampling selects request ID, then attempt ID, then
connection ID; uncorrelated events are retained. No label map grows with hosts,
requests or traces.

The adapter owns a fixed ring, at most one active batch, one export worker and
at most one lazy cancellation dispatcher. Full queues drop newest. Exporter
exceptions drop that batch without retry or retained error text. Sampling,
queue-full, closed, shutdown and exporter-fault counters are separate.
Exporter-retained batches are its additional memory ownership.

`flush(context)` waits for settled queue/in-flight work, not guaranteed delivery:
inspect export faults/drops. `close(context)` rejects new events, discards
pending events, requests canonical cancellation, and waits for worker/callbacks.
Both use the earlier caller absolute deadline and positive configured cap
(at most five seconds). Repeated/reentrant close starts no extra dispatcher.
Arbitrary exporter/cancellation code cannot be preempted: a blocked callback
makes close return false within its bound; the snapshot retains running work.

Synchronous event, pool and service-hook exceptions are isolated. Callbacks
run outside owner locks and may reenter snapshots or rotation. A slow
synchronous callback still delays its task; use the optional adapter instead
of exporter I/O in synchronous hooks.

### Privacy and diagnosis

Events have no URL, header, cookie, authorization, body, certificate, key or
session-secret field. Opaque trace IDs are caller supplied: do not put secrets
there or into custom exporters. Metric labels should be fixed kind/outcome/
phase/code enums, never request IDs, endpoints or traces. Public HTTP policy/
protocol failures use `HttpException.code`; HTTP 4xx/5xx are normal responses.
Observer exceptions never replace original typed I/O failures.

The [installed native example](../../examples/linux/m10_005/observability.cj)
locates bounded pool wait, controlled slow DNS, a silent peer's TLS handshake,
delayed response headers and actual H2 local send-flow backpressure. It checks
separate lifetimes, real reclamation, secret-marker inputs, bounded export,
native FD/task stability and measured disabled/buffer/async request samples
without a monitoring dependency. In the qualified SDK environment, run:

```sh
python3 tools/m10_005_native_observation.py --output docs/evidence/M10-005/installed/report.json
```

The runner verifies a fresh extracted installation outside the checkout. This
is source-candidate development acceptance, not release qualification.


## Rotate TLS and resolver configuration online

Use `HttpConfigurationRotation.Graceful` for ordinary certificate or resolver replacement. It stops new admissions to the affected old pools, closes idle connections and drains admitted exchanges under their original operation budgets. A started handshake keeps its captured TLS snapshot. HTTP/2 streams already admitted may finish, but later client requests use the replacement pool. The server sends GOAWAY to obsolete H2 connections and closes idle H1 keepalive reads without interrupting an admitted H1 exchange.

A validated H2 response that has received END_STREAM remains readable, including buffered DATA, after its graceful peer closes the connection. Those bytes remain budgeted until caller consumption or close. Matching Content-Length without END_STREAM is not completion: premature EOF still fails, and explicit security cancellation still aborts the old response.

Choose `HttpConfigurationRotation.SecurityReplacement` explicitly when an old trust policy or client identity must stop being used. Wirestack cannot infer which arbitrary policy is stricter. This mode cancels affected old-generation request tokens and aborts their connections, including generations draining from earlier graceful updates. New H2 requests cannot reuse the old authenticated connection. The server also cancels pending handshakes and active handler contexts; the listener stays bound. Cancellation cannot undo work the peer already executed.

TLS material is fully validated before publication, including native engine installation of certificates, trust roots and keys. Validation, capacity or closed-state failure leaves the previous generation active. Generation publication and client route selection share one mutex. Server handshake dispatch captures the current generation under its dispatcher mutex. The update returns after applying the selected retirement action to its captured obsolete connections; operations concurrent with the update may already have been admitted to their old snapshot.

`HttpClient.rotateTls` changes direct HTTPS and HTTPS-through-proxy TLS. `rotateResolver` changes only direct DNS and direct pools. `rotateProxyResolver` changes only proxy-endpoint DNS and proxy pools, retaining NO_PROXY and authorization policy; a client without a configured proxy rejects that update. Each method returns the new independent `UInt64` generation. Client counters start at one. A TLS server starts at one and reports its last published value through `tlsGeneration()`; a cleartext server reports zero and rejects TLS rotation.

```cj
let replacement = HttpClientTlsConfig(
    [File.readFrom("/etc/wirestack/replacement-ca.der")]
)
try {
    let generation = client.rotateTls(
        replacement, policy: HttpConfigurationRotation.SecurityReplacement
    )
    let snapshot = client.configurationSnapshot()
    // snapshot.tlsGeneration equals generation unless another caller updates TLS.
    // No certificates, key bytes or arbitrary hostnames enter this snapshot.
} finally { replacement.close() }

let serverReplacement = HttpServerTlsConfig(
    [File.readFrom("/etc/wirestack/replacement-leaf.der")],
    File.readFrom("/etc/wirestack/replacement-key.pk8")
)
try { let _ = server.rotateTls(serverReplacement) }
finally { serverReplacement.close() }
```

The built client/server retains provider and key ownership independently of the caller's TLS config. DNS rotation shares the retained immutable TLS context instead of reopening a config the caller may have closed. Existing TLS session/contextVersion partitioning remains unchanged. A replacement never borrows a session from its obsolete trust context.

For hosts, nameserver, search, ndots or DNS cache-policy changes, construct a fresh `wirestack.net.Resolver` with the replacement `DnsResolverConfig`, then publish it with `rotateResolver` or `rotateProxyResolver`. Each resolver snapshots hosts at construction and owns separate positive and negative caches. Exact hosts lookup precedes DNS search expansion. An old in-flight DNS result can complete the old admitted operation and populate only its old resolver's cache. Security replacement cancels the old operation instead. No result/cache entries transfer between snapshots.

A resolver supplied by the caller remains caller-owned. Keep its old instance alive until the old admitted work completes, then close it. Wirestack does not poll configuration files. `DnsResolverConfig.fromSystem` retains its documented tolerant parsing behavior; callers requiring strict file validation must validate before constructing and publishing their replacement. An ordinary cache TTL expiration only affects that cache entry. It does not rotate generations or disconnect established connections.

`configurationSnapshot()` reports `tlsGeneration`, `directDnsGeneration`, `proxyDnsGeneration`, `retainedGenerations` and `retainedTlsContexts`. At most 64 client route owners and 64 distinct TLS context owners are retained. A server retains at most 64 referenced TLS generations. Old contexts release only after their real request/body/connection lifetimes finish; updates reject capacity exhaustion rather than growing an unbounded queue or spawning watchers.

A successfully transferred HTTP/1 Upgrade or CONNECT session is caller-owned, not a pooled request. Graceful/security rotation and client close do not revoke it. It retains its old generation until the caller closes or aborts the session. Close such sessions explicitly when your application's security policy requires revocation. HTTP/2 CONNECT remains a stream on a shared pooled connection and is aborted by security replacement of that connection.

The Linux example `examples/linux/m10_004/configuration_rotation.cj` demonstrates graceful admitted-request completion, server security cancellation, new mTLS authentication, removed-trust rejection, direct DNS admission and zero terminal connection/generation owners. The installed acceptance runner extracts a fresh current package outside the checkout and builds the example against only that installation:

```sh
python3 tools/m10_004_native_rotation.py
```

Expected final marker: `M10_004_INSTALLED_ROTATION_PASS` in `docs/evidence/M10-004/installed/consumer-run.stdout.log`. This is Linux development acceptance, not release qualification.


## Bounded server-sent events

Use the opt-in `wirestack.sse` package for bounded incremental decoding,
server body publication and explicit GET reconnect sessions. Ordinary HTTP
retry policy does not opt a stream into reconnection. POST `oneShot` never
replays, even with an explicitly-safe replayable request. The
[SSE guide](sse-linux.md) covers cursor versus acknowledgement, shared deadline
and DATA-buffer admission, local flush semantics and H1/H2 body ownership.
`examples/linux/m11_001/sse.cj` is the extracted-install consumer.
