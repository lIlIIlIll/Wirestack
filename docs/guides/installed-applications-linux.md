# Run independent installed Wirestack applications

Build a download CLI, an opt-in decoded CLI, a long-stream client and a small HTTP service against an extracted Wirestack package. Each directory is a standalone CJPM executable with one relative dependency. No consumer imports internal packages or requires a provider handle.

This is Linux x86_64 glibc development acceptance, not a signed or qualified release. M9 native option/UDP integration uses its qualified SDK 1.1.3 profile; the applications also run on SDK 1.3.0-alpha.06.

## 1. Arrange the extracted package and applications

Use a supported Cangjie SDK, its normal envsetup script, a Wirestack source archive containing its pinned static native archives, and the four complete projects under `examples/linux/m11_004`. No system OpenSSL or compression library is an application runtime prerequisite. OpenSSL is used only by the controlled acceptance fixture to generate disposable certificates.

Keep this layout so the checked-in relative dependency resolves without edits:

```text
workspace/
  install/wirestack/cjpm.toml
  consumers/cli/cjpm.toml
  consumers/decoded/cjpm.toml
  consumers/streams/cjpm.toml
  consumers/service/cjpm.toml
```

Extract the archive into `install/wirestack`, then copy each complete application directory into `consumers`. Initialize the SDK environment before building. The archive supplies the Wirestack sources and all three required native archives; do not add checkout paths or FFI overrides to an application manifest.

```sh
for app in cli decoded streams service; do
  (cd "consumers/$app" && cjpm build)
done
```

Every executable is `consumers/<app>/target/release/bin/main`. Start with `--help`. A missing static archive or stale source/snippet binding fails acceptance, rather than selecting a system provider.

## 2. Run the service and download a response

For local TLS, provide a DER certificate with an IP SAN for the selected listener and an unencrypted PKCS8 DER key. These are caller-owned configuration files. Do not use production credentials in acceptance. The local service binds loopback; this example is not a deployment framework.

```sh
consumers/service/target/release/bin/main serve --port 8443 \
  --certificate certificate.der --key key.pk8 \
  --max-requests 16 --max-streams 16 --budget-ms 20000
```

The service prints `SERVICE_READY port=8443`. From another terminal, download its deterministic eight-byte response:

```sh
consumers/cli/target/release/bin/main download \
  --url https://127.0.0.1:8443/download --output download.bin \
  --trust certificate.der --budget-ms 5000 --max-bytes 1048576
```

Successful publication prints `DOWNLOAD_PASS bytes=8`. Existing output and `.partial` files are refused. Failure closes the file and response and removes only the unpublished file owned by this operation. The application does not print the URL, body or authorization value.

The base CLI returns encoded bytes unchanged. Use the separate decoded executable with the same command plus `--decoded` for bounded gzip decoding, or `--raw` to retain the encoded representation. The base binary has no SSE, gzip or asynchronous-observability module symbols. The decoded binary uses the public optional wrapper rather than silently changing HTTP defaults.

Add `--proxy HOST:PORT` for an explicit proxy. DNS and literal IP endpoints are decoded into public typed proxy values. `--proxy-authorization VALUE` remains explicit; command-line values can be visible to local process inspection, so do not pass production credentials this way. Diagnostics omit them. `--pre-cancel` and `--cancel-after-bytes N` exercise deterministic cancellation without adding another timeout owner.

## 3. Read a finite long stream

The service provides `/stream` and `/hold` SSE endpoints. Event summaries contain only counts, byte lengths and recovery count.

```sh
consumers/streams/target/release/bin/main sse \
  https://127.0.0.1:8443/stream --trust certificate.der \
  --budget-ms 5000 --max-events 1 --recover 0 --cursor-policy none
```

`--recover` is finite and opt-in. `parsed` uses the session's last parsed Last-Event-ID on GET recovery; parsing is not an acknowledgement, so duplicates are possible. `none` requires zero recovery and does not disable local cursor parsing. POST uses the one-shot session and is not replayed, even if an adversarial caller marks its request retry-safe. The operational POST retains default conservative retry safety.

For WebSocket, point the client at an actual ws/wss endpoint. The separate bounded fixture supplies one for reproducible local use:

```sh
consumers/streams/target/release/bin/main fixture certificate.der key.pk8
# Use the actual STREAM_READY port, then run in another terminal:
consumers/streams/target/release/bin/main websocket \
  wss://127.0.0.1:8444/socket --trust certificate.der \
  --budget-ms 5000 --max-frames 1 --recover 0 --command echo
```

Replace 8444 with the printed port. `--recover 1 --command disconnect` exercises one explicit new session and sends a new `recover` command. It does not resend the original command. Ping/Pong and frame counts do not prove business progress or exactly-once delivery. The input context caps all connection attempts and session work.

## 4. Rotate and stop deliberately

Write a bounded administrative command to the service's stdin:

```text
rotate replacement-certificate.der replacement-key.pk8
secure-rotate replacement-certificate.der replacement-key.pk8
stop
```

Ordinary rotation permits admitted old-generation requests to finish. Security rotation requires client authentication using the configured certificate as the fixture trust root, cancels old-generation work and rejects new unauthenticated clients. Use an actual reviewed trust policy for an application, not this fixture policy by accident. `stop` rejects new admissions, drains admitted work within its context and prints `SERVICE_STOPPED` after shutdown. The upload handler caps request payload at 4096 bytes and reports the consumed byte count; streamed producers inherit the same shortened absolute context.

The standalone stream fixture accepts `stop` and prints `STREAM_STOPPED`. Acceptance enforces bounded process stop even on a failed client invocation.

## Compiled operational code

The following regions are copied byte-for-byte from the built applications, with their source location retained. A method/helper region uses its surrounding complete project; it is not a standalone pasted program. The acceptance validator rejects snippet drift or an omitted application.

### cli download

<!-- compiled: cli/src/main.cj#cli-download -->
```cangjie
func download(client: HttpClient, url: String, output: String, context: OperationContext,
    maximum!: Int64 = 1048576, progress!: () -> Unit = { => }): Int64 {
    checkOperation(context)
    if (exists(output) || exists(output + ".partial")) { throw DownloadFailure(4) }
    let response = client.get(url, context: context)
    let partial = output + ".partial"
    var owned = false
    var published = false
    try {
        if (response.status != 200) { throw DownloadFailure(5) }
        let file = try { File.create(partial) } catch (_: IOException) { throw DownloadFailure(4) }
        owned = true
        var total = 0
        try {
            let buffer = Array<Byte>(4096, repeat: 0u8)
            while (true) {
                checkOperation(context)
                let count = response.body.read(buffer)
                if (count == 0) { break }
                if (count > maximum - total) { throw DownloadFailure(3) }
                try { file.write(buffer[..count]) } catch (_: IOException) { throw DownloadFailure(4) }
                total += count
                progress()
            }
            checkOperation(context)
        } finally { file.close() }
        try { rename(partial, to: output) } catch (_: IOException) { throw DownloadFailure(4) }
        published = true
        total
    } finally {
        try { response.close() } finally { if (owned && !published) { removeIfExists(partial) } }
    }
}
```

### decoded download

<!-- compiled: decoded/src/main.cj#decoded-download -->
```cangjie
func download(client: HttpClient, url: String, output: String, context: OperationContext,
    maximum!: Int64 = 1048576, decoded!: Bool = true, progress!: () -> Unit = { => }): Int64 {
    checkOperation(context)
    if (exists(output) || exists(output + ".partial")) { throw DownloadFailure(4) }
    let wrapped = if (decoded) { Some(GzipClient(client, limits: GzipLimits(maximumEncodedBytes: maximum, maximumDecodedBytes: maximum)).send(HttpRequest.get(url), context: context)) } else { None<GzipResponse> }
    let response = match (wrapped) { case Some(value) => value.response; case None => client.get(url, context: context) }
    let partial = output + ".partial"
    var owned = false
    var published = false
    try {
        if (response.status != 200) { throw DownloadFailure(5) }
        let file = try { File.create(partial) } catch (_: IOException) { throw DownloadFailure(4) }
        owned = true
        var total = 0
        try {
            let buffer = Array<Byte>(4096, repeat: 0u8)
            while (true) {
                checkOperation(context)
                let count = response.body.read(buffer)
                if (count == 0) { break }
                if (count > maximum - total) { throw DownloadFailure(3) }
                try { file.write(buffer[..count]) } catch (_: IOException) { throw DownloadFailure(4) }
                total += count
                progress()
            }
            checkOperation(context)
        } finally { file.close() }
        try { rename(partial, to: output) } catch (_: IOException) { throw DownloadFailure(4) }
        published = true
        total
    } finally {
        try { response.close() } finally { if (owned && !published) { removeIfExists(partial) } }
    }
}
```

### stream sse

<!-- compiled: streams/src/main.cj#stream-sse -->
```cangjie
func consumeSse(client: HttpClient, url: String, post: Bool, recover: Int64,
    maximumEvents: Int64, context: OperationContext): (Int64, Int64, Int64) {
    let session = sseOpen(client, url, post, recover, context)
    var events: Int64 = 0; var bytes: Int64 = 0
    try {
        while (events < maximumEvents) {
            match (session.receive()) {
                case Some(event) => events++; bytes += event.data.size
                case None => break
            }
        }
        // Parsed Last-Event-ID is not an application acknowledgement. Never print its value.
        println("SUMMARY events=${events} bytes=${bytes} recoveries=${session.reconnectCount} cursor_bytes=${session.lastEventId.size}")
        (events, bytes, session.reconnectCount)
    } finally { session.close() }
}
```

### stream websocket

<!-- compiled: streams/src/main.cj#stream-websocket -->
```cangjie
func consumeWebSocket(client: HttpClient, url: String, maximumFrames: Int64,
    recover: Int64, command: String, context: OperationContext): (Int64, Int64) {
    var frames: Int64 = 0; var recoveries: Int64 = 0; var bytes: Int64 = 0
    while (true) {
        let session = wsOpen(client, url, context)
        var disconnected = false
        try {
            // Recovery opens a new session. It never resends this application command.
            if (recoveries == 0) { session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: command.toArray()), context: context) }
            else { session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "recover".toArray()), context: context) }
            while (frames < maximumFrames) {
                let frame = session.receive(context: context)
                match (frame.opcode) { case WebSocketOpcode.Close => break; case _ => frames++; bytes += frame.payload.size }
            }
        } catch (error: WebSocketException) {
            match (error.code) {
                case WebSocketErrorCode.TransportFailure => disconnected = true
                case _ => throw error
            }
        } finally { session.close() }
        if (!disconnected) { break }
        if (recoveries >= recover) { throw WebSocketException(WebSocketErrorCode.TransportFailure, "disconnect") }
        recoveries++
    }
    println("SUMMARY frames=${frames} bytes=${bytes} recoveries=${recoveries}")
    (frames, recoveries)
}
```

### service handler

<!-- compiled: service/src/main.cj#service-handler -->
```cangjie
    public func handle(request: HttpServerRequest, owner: OperationContext): HttpServerResponse {
        admissions.fetchAdd(1)
        let operation = owner.shortenDeadline(budget * Duration.millisecond)
        let buffer = Array<Byte>(256, repeat: 0u8)
        var bytes: Int64 = 0
        try {
            while (true) {
                let count = request.body.read(buffer)
                if (count == 0) { break }
                bytes += count
                if (bytes > 4096) {
                    return HttpServerResponse(HttpResponse(413, "Content Too Large", ResponseBody.empty()))
                }
            }
        } finally { request.body.close() }
        if (request.target == "/upload") {
            uploads.fetchAdd(bytes)
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("${bytes}").open())))
        }
        if (request.target == "/graceful") { graceful.hold(operation) }
        if (request.target == "/security") { security.hold(operation) }
        if (request.target == "/drain") { draining.hold(operation) }
        if (request.target == "/stream" || request.target == "/hold") {
            let writer = SseWriter(maximumBufferBytes: 128, context: operation)
            producers.fetchAdd(1)
            let held = request.target == "/hold"
            spawn {
                try {
                    writer.write(SseEvent("chunk")); writer.flush()
                    if (held) {
                        while (!writer.isClosed() && !operation.isCancellationRequested() && !operation.isDeadlineExceeded()) {
                            sleep(20 * Duration.millisecond)
                            writer.comment("heartbeat"); writer.flush()
                        }
                    } else { writer.write(SseEvent("complete")); writer.flush() }
                    writer.complete()
                } catch (_: Exception) { writer.close() }
                finally { producers.fetchSub(1) }
            }
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(writer),
                headers: HttpHeaders.builder().add("Content-Type", "text/event-stream").build()))
        }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("download").open())))
    }
```

### service rotation

<!-- compiled: service/src/main.cj#service-rotation -->
```cangjie
func rotate(server: HttpServer, certificate: Array<Byte>, key: Array<Byte>, secure: Bool): UInt64 {
    let material = if (secure) {
        HttpServerTlsConfig([certificate], key, clientAuthentication: HttpServerClientAuthentication.Required,
            clientTrustRootsDer: [certificate])
    } else { HttpServerTlsConfig([certificate], key) }
    try {
        server.rotateTls(material, policy: if (secure) { HttpConfigurationRotation.SecurityReplacement }
            else { HttpConfigurationRotation.Graceful })
    } finally { material.close() }
}
```


## Verify the installed acceptance

Run the canonical gate from the development checkout in the SDK environment. Its runner copies the applications and extracts a fresh package, then mounts an empty directory over the checkout for every build, help command, operational invocation and native self-check. Only its own disk-backed scratch is writable.

```sh
scripts/check-task M11-004
```

The installed reports bind the exact application sources, package payload, binary, SDK compiler, target and full normalized command/log inventory. The separate SDK1.1.3 run includes actual installed typed socket-option, UDP disconnect, broadcast and IPv4/IPv6 multicast probes. IPv6 multicast routing is configured only inside a disposable network namespace. It does not alter host networking.

See [acceptance evidence](../evidence/M11-004/README.md) for results, public API integration gaps and ownership/boilerplate review. A performance, security, formal-soak or another-platform qualification is outside this task.
