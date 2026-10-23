package wirestack_m11_004_streams

import std.convert.*
import std.fs.*
import wirestack as api
import wirestack.http.*
import wirestack.sse.*

func require(ok: Bool): Unit { if (!ok) { throw IllegalStateException("assertion") } }

func boundedFile(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        let info = file.info
        require(info.isRegular() && info.size > 0 && info.size <= 65536)
        let content = Array<Byte>(info.size, repeat: 0)
        let chunk = Array<Byte>(8192, repeat: 0)
        var total: Int64 = 0
        while (true) {
            let count = file.read(chunk)
            if (count == 0) { break }
            require(count > 0 && count <= chunk.size && count <= info.size - total)
            for (index in 0 .. count) { content[total + index] = chunk[index] }
            total += count
        }
        require(total == info.size)
        content
    } finally {
        file.close()
    }
}
func owner(ms!: Int64 = 10000): OperationContext { OperationContext(deadline: Some(Deadline.after(ms * Duration.millisecond))) }
func policy(recover: Int64): SseSessionPolicy {
    SseSessionPolicy(maximumReconnects: recover, initialRetryDelay: 50 * Duration.millisecond, jitterPermille: 0)
}
func codec(): SseLimits { SseLimits(maximumLineBytes: 2048, maximumEventBytes: 4096, maximumIdBytes: 128) }
func sseOpen(client: HttpClient, url: String, post: Bool, recover: Int64, context: OperationContext): SseSession {
    if (post) {
        return SseSession.oneShot(client, HttpRequest.post(url, RequestBody.string("submit"))
            .withHeaders(HttpHeaders.builder().add("Content-Length", "6").build()),
            limits: codec(), policy: policy(recover), readBufferBytes: 1024, context: context)
    }
    SseSession.eventSource(client, HttpUrl.parse(url), limits: codec(), policy: policy(recover), readBufferBytes: 1024, context: context)
}
// DOC-BEGIN stream-sse
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
// DOC-END stream-sse
func wsOpen(client: HttpClient, url: String, context: OperationContext): WebSocketConnection {
    match (client.connectWebSocket(WebSocketUrl.parse(url), context: context,
        webSocketLimits: WebSocketLimits(maximumFrameBytes: 32768, maximumMessageBytes: 32768, ioBufferBytes: 1024))) {
        case WebSocketConnectResult.Connected(session) => session
        case WebSocketConnectResult.Rejected(response) => response.close(); throw IllegalStateException("handshake")
    }
}
// DOC-BEGIN stream-websocket
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
// DOC-END stream-websocket
func help(): Unit {
    println("streams sse URL [--trust CERT.der] [--budget-ms N] [--max-events N] [--recover N] [--cursor-policy parsed|none] [--method GET|POST]")
    println("streams websocket URL [--trust CERT.der] [--budget-ms N] [--max-frames N] [--recover N] [--command TEXT]")
    println("streams self-check CERT.der KEY.pk8 UNTRUSTED.der")
    println("streams fixture CERT.der KEY.pk8; stdin stop terminates the endpoint")
    println("Recovery is finite and opt-in. SSE cursor is parsed, not acknowledged; duplicates are possible. POST is never replayed. WebSocket recovery sends a new recover command, not the old command.")
}
main(args: Array<String>): Int64 {
    try {
        if (args.size == 0 || args[0] == "--help") { help(); return 0 }
        if (args[0] == "self-check") { require(args.size == 4); selfCheck(args[1], args[2], args[3]); return 0 }
        if (args[0] == "fixture") { require(args.size == 3); runFixture(args[1], args[2]); return 0 }
        require(args.size >= 2 && (args[0] == "sse" || args[0] == "websocket"))
        var trust = ""; var budget: Int64 = 10000; var maximum: Int64 = 10; var recover: Int64 = 0; var post = false; var command = "echo"
        var cursorPolicy = "parsed"
        var index: Int64 = 2
        while (index < args.size) {
            require(index + 1 < args.size); let flag = args[index]; let value = args[index + 1]
            match (flag) {
                case "--trust" => trust = value
                case "--budget-ms" => budget = Int64.parse(value)
                case "--max-events" => require(args[0] == "sse"); maximum = Int64.parse(value)
                case "--max-frames" => require(args[0] == "websocket"); maximum = Int64.parse(value)
                case "--recover" => recover = Int64.parse(value)
                case "--cursor-policy" => require(args[0] == "sse" && (value == "parsed" || value == "none")); cursorPolicy = value
                case "--method" => require(args[0] == "sse" && (value == "GET" || value == "POST")); post = value == "POST"
                case "--command" => require(args[0] == "websocket" && value.size <= 1024); command = value
                case _ => throw IllegalArgumentException("option")
            }
            index += 2
        }
        require(budget > 0 && budget <= 60000 && maximum > 0 && maximum <= 10000 && recover >= 0 && recover <= 8)
        require(cursorPolicy != "none" || recover == 0)
        let builder = HttpClient.builder()
        // The builder clones the handshaker, so this caller-owned trust configuration keeps its
        // own copy and is closed here even though the client is closed in the same scope.
        let config = if (trust.isEmpty()) { None<HttpClientTlsConfig> } else { Some(HttpClientTlsConfig([boundedFile(trust)])) }
        if (let Some(value) <- config) { builder.tls(value) }
        let client = try { builder.build() }
            catch (error: Exception) { if (let Some(value) <- config) { value.close() }; throw error }
        try {
            if (args[0] == "sse") { let _ = consumeSse(client, args[1], post, recover, maximum, owner(ms: budget)) }
            else { let _ = consumeWebSocket(client, args[1], maximum, recover, command, owner(ms: budget)) }
        } finally {
            client.close()
            if (let Some(value) <- config) { value.close(); require(value.isClosed()) }
        }
        return 0
    } catch (_: api.NetworkException) { eprintln("ERROR category=network phase=operation code=2"); return 1 }
    catch (_: HttpException) { eprintln("ERROR category=http phase=operation code=3"); return 1 }
    catch (_: WebSocketException) { eprintln("ERROR category=websocket phase=operation code=4"); return 1 }
    catch (_: SseException) { eprintln("ERROR category=sse phase=operation code=5"); return 1 }
    catch (_: Exception) { eprintln("ERROR category=application phase=operation code=1"); return 1 }
}
