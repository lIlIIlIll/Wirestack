package wirestack.http

import wirestack as api
import wirestack.internal.http1 as http1

internal class WebSocketHandshake {
    let key: String
    let protocols: Array<String>
    let http1Request: HttpRequest
    let http2Request: HttpRequest

    init(url: HttpUrl, protocols: Array<String>, headers: HttpHeaders, limits: HttpLimits) {
        if (protocols.size > 32) { throw IllegalArgumentException("too many WebSocket subprotocols") }
        for (index in 0..protocols.size) {
            validateWebSocketSubProtocol(protocols[index])
            for (previous in 0..index) {
                if (protocols[previous] == protocols[index]) {
                    throw IllegalArgumentException("duplicate WebSocket subprotocol")
                }
            }
        }
        this.protocols = protocols.clone()
        key = newWebSocketKey()
        let h1 = HttpHeaders.builder(limits: limits)
        let h2 = HttpHeaders.builder(limits: limits)
        for (entry in headers.entries) {
            let name = entry.name.toAsciiLower()
            if (name == "connection" || name == "upgrade" || name == "host" ||
                name == "content-length" || name == "transfer-encoding" ||
                name.startsWith("sec-websocket-")) {
                throw IllegalArgumentException("WebSocket handshake header is managed by the client")
            }
            h1.add(entry.name, entry.value)
            h2.add(entry.name, entry.value)
        }
        h1.add("Connection", "Upgrade")
        h1.add("Upgrade", "websocket")
        h1.add("Sec-WebSocket-Key", key)
        h1.add("Sec-WebSocket-Version", "13")
        h2.add("Sec-WebSocket-Version", "13")
        if (!protocols.isEmpty()) {
            var offered = protocols[0]
            for (index in 1..protocols.size) { offered += ", " + protocols[index] }
            h1.add("Sec-WebSocket-Protocol", offered)
            h2.add("Sec-WebSocket-Protocol", offered)
        }
        http1Request = HttpRequest(HttpMethod("GET"), url, headers: h1.build(),
            retrySafety: api.HttpRetrySafety.Disabled)
        http2Request = HttpRequest(HttpMethod("CONNECT"), url, headers: h2.build(),
            retrySafety: api.HttpRetrySafety.Disabled)
    }

    func accept(value: http1.HttpDuplexExchangeResult, limits: WebSocketLimits): WebSocketConnectResult {
        match (value) {
            case http1.HttpDuplexExchangeResult.Response(response) => WebSocketConnectResult.Rejected(response)
            case http1.HttpDuplexExchangeResult.Connected(connection) =>
                try {
                    if (!connection.headers.getAll("sec-websocket-extensions").isEmpty()) {
                        throw IllegalArgumentException("WebSocket extensions are unsupported")
                    }
                    match (connection.version) {
                        case HttpVersion.Http2 => ()
                        case _ =>
                            let accepts = connection.headers.getAll("sec-websocket-accept")
                            if (accepts.size != 1 || accepts[0] != webSocketAcceptKey(key)) {
                                throw IllegalArgumentException("WebSocket accept key does not match")
                            }
                    }
                    let selected = connection.headers.getAll("sec-websocket-protocol")
                    if (selected.size > 1) { throw IllegalArgumentException("multiple WebSocket subprotocol selections") }
                    var subProtocol = None<String>
                    if (selected.size == 1) {
                        var offered = false
                        for (protocol in protocols) { if (protocol == selected[0]) { offered = true } }
                        if (!offered) { throw IllegalArgumentException("server selected an unoffered WebSocket subprotocol") }
                        subProtocol = Some(selected[0])
                    }
                    WebSocketConnectResult.Connected(WebSocketConnection(connection.transport,
                        WebSocketRole.Client, subProtocol: subProtocol, limits: limits))
                } catch (error: Exception) {
                    connection.transport.abort(reason: Some(api.AbortReason.ProtocolFailure))
                    throw WebSocketException(WebSocketErrorCode.ProtocolViolation,
                        "WebSocket response handshake is invalid", cause: Some(error))
                }
        }
    }
}
