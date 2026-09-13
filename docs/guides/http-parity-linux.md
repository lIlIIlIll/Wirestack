# Use HTTP parity features on Linux

Wirestack adds bounded cookies, multipart bodies, file transfer, protocol upgrades, WebSockets, HTTP/2 push, and HTTP extension hooks to its existing client and server. This page describes the public contracts and shows how to qualify them from an installed release archive.

For basic client, server, TLS, proxy, cancellation, and error usage, read [Linux HTTP client and server](http1-linux.md).

## Requirements

- Linux x86_64 with the GNU environment
- Cangjie STS 1.1.3
- Python 3 for the installed-consumer qualification command
- A Wirestack source candidate with its native resolver, TLS provider, and HTTP file library available to the release build

`FileHandler`, `FileHandlerMode`, `FileHandlerException`, and `FileHandlerErrorCode` exist only when `os == "Linux"`, `arch == "x86_64"`, and `env == "gnu"`.

## Use a bounded cookie jar

Create one `CookieJar` and pass it to `HttpClientBuilder.cookieJar`. The client reads every `Set-Cookie` response field and applies matching cookies to later requests, retries, and redirects. A `Cookie` header supplied in the request takes precedence over the jar.

```cj
let jar = CookieJar(
    maximumCookies: 256,
    maximumHeaderBytes: 8192,
    rejectPublicSuffixes: ["com", "co.uk"]
)
let client = HttpClient.builder()
    .cookieJar(jar)
    .build()
```

The jar applies host-only and Domain scope, the default directory path, path boundaries, expiry, `Max-Age` precedence, and the `Secure` transport rule. `headerFor(url)` returns a `String`. An empty string means that no stored cookie matches. Cookies are ordered by longest path and then by oldest identity, and serialization stops before `maximumHeaderBytes` is exceeded.

`rejectPublicSuffixes` is an exact normalized-domain blacklist. Wirestack does not bundle or update a public suffix list. Capacity is also exact: a new identity evicts the oldest retained identity when `maximumCookies` is full. Replacing an existing name, effective domain, and path keeps that identity's original order.

Use these methods when you need explicit control:

```cj
let accepted = jar.acceptSetCookie(
    "session=abc; Path=/account; Secure; HttpOnly",
    HttpUrl.parse("https://example.test/account/login")
)
let header: String = jar.headerFor(HttpUrl.parse("https://example.test/account/profile"))
let cookies: Array<Cookie> = jar.cookiesFor(HttpUrl.parse("https://example.test/account/profile"))
let removed = jar.remove("session", HttpUrl.parse("https://example.test/"), path: "/account")
let removedFromDomain = jar.removeCookies("example.test")
jar.clear()
```

`HttpOnly` remains metadata because Wirestack has no browser script API. The jar does not implement browser SameSite policy or other browser cookie policy.

## Stream multipart bodies within fixed limits

Use `MultipartWriter` for outbound `multipart/form-data`. Each part owns a `RequestBody`, so a writer made only from replayable parts produces a replayable body. A one-shot part makes the complete multipart body one-shot.

```cj
let writer = MultipartWriter(
    "wirestack-boundary",
    maximumParts: 4,
    maximumPartBytes: 64 * 1024 * 1024
).add(MultipartPart(
    "file",
    [0u8, 255u8, 13u8, 10u8],
    filename: Some("sample.bin"),
    contentType: "application/octet-stream"
))
let body = writer.body(maximumBytes: 128 * 1024 * 1024)
let headers = HttpHeaders(entries: [
    HttpHeader("Content-Type", writer.contentType()),
    HttpHeader("Content-Length", "${body.contentLength.getOrThrow()}")
])
```

`contentType()` quotes the boundary, including boundaries that contain permitted separator characters:

```text
multipart/form-data; boundary="wirestack-boundary"
```

`HttpHeaders` is immutable. Construct it with `HttpHeaders(entries: ...)` or build it with `HttpHeaders.builder().add(...).build()`.

Use `MultipartReader.fromRequest` in a server handler. Pass the handler's `context` so cancellation and the absolute deadline control multipart reads.

```cj
let reader = MultipartReader.fromRequest(
    request,
    limits: MultipartLimits(
        maximumParts: 8,
        maximumHeaderBytes: 16 * 1024,
        maximumHeaderCount: 16,
        maximumPartBytes: 8 * 1024 * 1024,
        maximumBodyBytes: 16 * 1024 * 1024,
        readBufferBytes: 16 * 1024
    ),
    context: context
)
```

Only one `MultipartReadPart` may be active. Read its body to EOF or close the part before calling `next()`. Closing a part discards only that part and permits the next part. A malformed body or a configured limit failure closes the reader's owned source and raises `MultipartException` with a stable `MultipartErrorCode`.

## Serve bounded files

`FileHandler.download` serves one fixed relative path from a trusted local root. It rejects traversal, backslashes, symlinks, nonregular files, and files larger than `maximumBytes`.

```cj
let handler = FileHandler.download(
    "/srv/wirestack/files",
    "releases/current.bin",
    maximumBytes: 1024 * 1024 * 1024,
    bufferSize: 64 * 1024
)
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8080))
    .handler(handler)
    .build()
```

`FileHandler.upload` accepts one multipart part that has a filename. The validator can reject the filename before publication.

```cj
let handler = FileHandler.upload(
    "/srv/wirestack/uploads",
    maximumBytes: 64 * 1024 * 1024,
    bufferSize: 64 * 1024,
    validator: { name => name.endsWith(".bin") },
    maximumParts: 4,
    maximumHeaderBytes: 16 * 1024
)
```

Uploads stay private with mode `0600` until an atomic no-replace publication succeeds. An existing destination returns `409 Conflict` and remains unchanged. Invalid multipart or paths return `400 Bad Request`. Limit failures return `413 Payload Too Large`. Cancellation and deadline failures propagate as `FileHandlerException` instead of becoming an HTTP response.

`FileHandler` checks cancellation between bounded synchronous filesystem calls. It does not interrupt a blocking filesystem syscall that has already entered the kernel.

## Transfer an HTTP/1.1 Upgrade

Build a bodyless request with an Upgrade protocol offer and `Connection: Upgrade`, then call `HttpClient.upgrade` with the offered protocol to use for extended CONNECT if HTTPS negotiates HTTP/2. Omit `protocol` only for an ordinary CONNECT request. A successful HTTP/1.1 response must be `101 Switching Protocols` with `Connection: Upgrade` and one selected protocol from the offer.

```cj
let headers = HttpHeaders.builder()
    .add("Connection", "Upgrade")
    .add("Upgrade", "example-protocol")
    .build()
let request = HttpRequest(
    HttpMethod("GET"),
    HttpUrl.parse("http://example.test/session"),
    headers: headers
)
let result = client.upgrade(request, protocol: Some("example-protocol"))
```

`HttpUpgradeResult.Connected` transfers one exclusive `HttpUpgradedConnection` to the caller. Its `transport` includes any bytes read after the response head. Close the upgraded connection when the protocol session ends. The HTTP connection pool cannot reuse that transport.

`HttpUpgradeResult.Rejected` transfers the complete `HttpResponse`, including its body, to the caller. Close the response after consuming it. A malformed or mismatched `101` fails closed and transfers no transport.

A server establishes a generic upgrade by returning `HttpServerResponse` with a matching response head and a `duplexHandler`. The server calls `HttpDuplexHandler.serve(transport, context)` after it commits the response. The server closes that transport when `serve` returns.

## Connect an uncompressed WebSocket

Pass an absolute `HttpUrl` to `connectWebSocket`. The accepted schemes are `http` and `https`. The API does not parse `ws` or `wss` URLs.

```cj
let result = client.connectWebSocket(
    HttpUrl.parse("https://example.test/socket"),
    protocols: ["events"],
    headers: HttpHeaders(entries: [HttpHeader("Authorization", "Bearer token")]),
    webSocketLimits: WebSocketLimits(
        maximumFrameBytes: 1024 * 1024,
        maximumMessageBytes: 16 * 1024 * 1024,
        ioBufferBytes: 16 * 1024,
        closeTimeout: 5 * Duration.second
    ),
    context: context
)
```

The client uses an HTTP/1.1 Upgrade when the connection uses HTTP/1.1. A negotiated HTTP/2 connection uses extended CONNECT. Wirestack owns `Connection`, `Upgrade`, `Host`, `Content-Length`, `Transfer-Encoding`, and all `Sec-WebSocket-*` request fields, so additional headers cannot set them.

Match the result before using the session:

```cj
let connection = match (result) {
    case WebSocketConnectResult.Connected(value) => value
    case WebSocketConnectResult.Rejected(response) =>
        let status = response.status
        response.close()
        throw Exception("WebSocket handshake rejected with ${status}")
}
```

On the server, validate the incoming handshake and transfer the session with `HttpServerResponse.webSocket(request, handler, subProtocol: ..., limits: ...)`. `WebSocketHandler.serve` receives the request's `OperationContext`.

`WebSocketConnection` permits one reader and one writer at a time. `send` and `receive` keep the caller's absolute deadline and cancellation. A pre-cancelled operation performs no I/O and leaves an untouched session usable. A failure after frame I/O starts fails the session closed. Ping receives trigger a bounded automatic Pong, and `close(code, reason, context: ...)` uses the shorter of the caller deadline and `WebSocketLimits.closeTimeout`.

Wirestack enforces client-to-server masking, server-to-client non-masking, canonical lengths, control-frame bounds, continuation order, message size, UTF-8 text, and close payload rules. `WebSocketFrame.payload` returns a defensive copy. WebSocket compression and all other extensions are excluded.

## Opt in to bounded HTTP/2 push

HTTP/2 push is disabled unless the client receives an `Http2PushConfig`.

```cj
let client = HttpClient.builder()
    .http2Push(Http2PushConfig(
        SameOriginHttp2PushPolicy(),
        maximumConcurrentPushes: 8,
        maximumPendingPushes: 8,
        maximumPushesPerRequest: 8
    ))
    .build()
```

Wirestack validates a promised request before it calls the application policy. A promise must be a same-origin, bodyless `GET` with valid HTTP/2 request fields. `SameOriginHttp2PushPolicy` compares the canonical scheme, host, and effective port. `DenyHttp2PushPolicy` rejects every offer.

When a response has a push source, call `receive` with a bounded context. Drain the parent body first or consume both bodies concurrently so that flow control can advance:

```cj
if (let Some(source) <- response.pushes) {
    while (let Some(pushed) <- source.receive(context: context)) {
        try {
            consume(pushed.response.body)
        } finally {
            pushed.close()
        }
    }
}
```

A push source permits one active receiver. It returns `None` after the parent receives `END_STREAM` and queued offers have been handled. Already queued pushes remain available even if their bodies finish later. Each `HttpPushedResponse` uniquely owns its response. Closing a parent `HttpResponse` closes its push source and resets unclaimed pushes.

A server handler calls `HttpServerRequest.push(request, response)`. The method uses the parent request's stored context. It has no context argument. The promised URL must use `request.authority` when it needs the original host and explicit port:

```cj
request.push(
    HttpRequest.get("https://${request.authority}/asset"),
    HttpServerResponse(HttpResponse(
        200,
        "OK",
        ResponseBody(RequestBody.string("asset").open())
    ))
)
```

Server admission has concurrent, pending, and per-request bounds. `HttpServerBuilder` does not expose separate setters for these server-side push bounds. `push` waits for admission and submits the promise within the parent request's deadline and cancellation. An admitted body runs in a separate bounded worker, so a flow-controlled push does not delay the parent response. Later write failures reset that push.

The server retains the parent request's cancellation links until the push worker finishes cleanup. A reset requests cancellation but does not run user body cleanup on the connection reader or free a still-blocked worker's slot. A failed admission closes the supplied response. Push is unavailable for HTTP/1.1 requests and after the HTTP/2 connection starts draining.

## Install connector, pool, and service hooks

`HttpConnector` is the provider-neutral `TransportFactory` contract. `HttpClientBuilder.connector` replaces connection creation but retains resolver, route, deadline, and pool policy. The client owns each returned transport. It does not own the supplied connector.

`HttpConnectionPoolHook` receives actual acquire and release events outside pool locks. Hook exceptions cannot alter request I/O or connection ownership. Keep callbacks non-blocking. Events use the secret-safe `NetworkEvent` contract and do not expose URLs, headers, cookies, bodies, credentials, certificates, keys, or session secrets.

`HttpServerBuilder.serviceHook` installs `HttpServiceHook.before(request, context)` and `HttpServiceHook.after(response, context)`. `before` does not take request-body ownership. `after` runs before response commitment. If `after` throws, the server closes the handler-owned response and follows its normal handler-failure path.

```cj
let client = HttpClient.builder()
    .connector(connector)
    .poolHook(poolHook)
    .build()
let server = HttpServer.builder()
    .listen(endpoint)
    .handler(handler)
    .serviceHook(serviceHook)
    .build()
```

## Qualify an installed release

Run the M8-005 consumer from the repository root:

```text
python3 tools/m8_005_native_http.py --report docs/evidence/M8-005/native-http.json
```

The tool builds a fresh release archive in a temporary directory, extracts it outside the checkout, and uses only that install as the consumer's CJPM path dependency. The consumer does not import the source checkout.

The command runs five modes. Each mode must emit only its expected marker:

| Mode | Expected marker | Observable contract |
|---|---|---|
| `cookies-hooks` | `COOKIES_HOOKS_PASS` | Stored cookie, explicit `Cookie` precedence, custom connector reuse, pool acquire and release hooks, and service before and after hooks |
| `files-multipart` | `FILES_MULTIPART_PASS` | Quoted multipart boundary, binary upload, rooted publication, and binary download |
| `upgrade-http1` | `UPGRADE_HTTP1_PASS` | HTTP/1.1 `101` metadata, duplex `ping` and `pong`, and upgraded-connection close |
| `websocket-http1` | `WEBSOCKET_HTTP1_PASS` | HTTP/1.1 Upgrade, uncompressed binary echo, and graceful close |
| `websocket-http2-push` | `WEBSOCKET_HTTP2_PUSH_PASS` | HTTP/2 extended CONNECT, uncompressed binary echo, queued same-origin push after parent EOF, retained authority host and port, a usable sibling request, and graceful close |

The tool writes `native-http.json` and durable raw logs under `docs/evidence/M8-005`. The qualification archive, extracted install, and consumer binary are temporary, not published release artifacts. Their typed digests remain in the report. Treat the run as successful only when the command exits with zero and the report has top-level `status` set to `PASS` and `source_task` set to `M8-005`.

A previous source test, source inspection, or pre-M8-005 report is not equivalent to this installed-consumer qualification.

## Exclusions

M8-005 does not claim these behaviors:

- WebSocket compression or another WebSocket extension
- `ws` or `wss` URL parsing
- native `FileHandler` support outside Linux x86_64 GNU targets
- interruption of a blocking filesystem syscall already in the kernel
- browser SameSite, public-suffix-list updates, or other browser cookie policy
- release signing, a final release soak, or M8-007 release qualification
