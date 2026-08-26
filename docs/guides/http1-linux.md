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
