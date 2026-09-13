package wirestack.internal.http1

import wirestack.internal.http_model.*
import wirestack.internal.transport.*

/** Handler-owned response plus optional chunk trailer. */
public class Http1ServerResponse {
    public let response: HttpResponse
    public let trailer: HttpTrailer
    public let duplexHandler: ?Http1DuplexHandler

    public init(response: HttpResponse, trailer!: HttpTrailer = HttpTrailer(),
        duplexHandler!: ?Http1DuplexHandler = None<Http1DuplexHandler>) {
        this.response = response
        this.trailer = trailer
        this.duplexHandler = duplexHandler
    }
}

public interface Http1ServerHandler {
    func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse
}

/** Runs after a validated protocol-switch response has been committed. */
public interface Http1DuplexHandler {
    func serve(transport: DuplexTransport, context: OperationContext): Unit
    /** Releases pre-session ownership when response validation or commitment fails. */
    func failed(): Unit {}
}

public struct Http1ServerConnectionResult {
    public let requestsServed: Int64
    public let closedForUnreadRequestBody: Bool
    public let tunnelTransport: ?DuplexTransport

    public prop tunnelEstablished: Bool { get() { tunnelTransport.isSome() } }

    public init(requestsServed: Int64, closedForUnreadRequestBody: Bool,
        tunnelTransport: ?DuplexTransport) {
        this.requestsServed = requestsServed
        this.closedForUnreadRequestBody = closedForUnreadRequestBody
        this.tunnelTransport = tunnelTransport
    }
}

/**
 * Serves one HTTP/1.1 transport serially. A handler must fully consume its request body
 * before the connection can process another request; unread bodies fail closed.
 */
public func serveHttp1Connection(
    transport: DuplexTransport,
    handler: Http1ServerHandler,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    maximumRequests!: Int64 = 1000
): Http1ServerConnectionResult {
    if (maximumRequests <= 0 || maximumRequests > 1000000) {
        throw IllegalArgumentException("HTTP/1 maximum requests per connection is invalid")
    }
    var served: Int64 = 0
    var unread = false
    var tunnel = false
    var tunnelRemainder = Array<Byte>()
    var pendingHandoff = None<Http1DuplexHandler>
    let requestReadBuffer = Array<Byte>(16 * 1024, repeat: 0)
    try {
        while (served < maximumRequests) {
            let request = readHttp1ServerRequest(
                transport, context: context, limits: limits,
                readBuffer: Some(requestReadBuffer)
            )
            var produced: ?Http1ServerResponse = None<Http1ServerResponse>
            try {
                produced = Some(handler.handle(request, context))
                pendingHandoff = produced.getOrThrow().duplexHandler
                validateServerHandoff(request, produced.getOrThrow())
            } catch (error: Exception) {
                request.close()
                if (let Some(value) <- produced) { value.response.close() }
                writeServerFailure(transport, request.head.method, context, limits)
                served += 1
                return Http1ServerConnectionResult(served, true, None<DuplexTransport>)
            }

            let requestConsumed = request.body.isFullyConsumed() || request.body.contentLength == Some(0)
            request.close()
            let output = produced.getOrThrow()
            let evidence = writeHttp1Response(
                transport, request.head.method, output.response,
                context: context, limits: limits, trailer: output.trailer
            )
            served += 1
            unread = !requestConsumed
            if (let Some(handoff) <- output.duplexHandler) {
                let upgraded = Http1PrefixedTransport(transport, request.upgradeRemainder)
                pendingHandoff = None<Http1DuplexHandler>
                try { handoff.serve(upgraded, context) }
                finally { upgraded.close() }
                return Http1ServerConnectionResult(served, false, None<DuplexTransport>)
            }
            tunnel = evidence.tunnelEstablished
            if (tunnel) { tunnelRemainder = request.upgradeRemainder }
            if (unread || tunnel || !request.upgradeRemainder.isEmpty() || evidence.mustClose ||
                headerContainsToken(request.head.headers, "connection", "close") ||
                headerContainsToken(output.response.headers, "connection", "close")) {
                break
            }
        }
        Http1ServerConnectionResult(
            served, unread,
            if (tunnel) {
                Some<DuplexTransport>(Http1PrefixedTransport(transport, tunnelRemainder))
            } else { None<DuplexTransport> }
        )
    } finally {
        try { if (let Some(handoff) <- pendingHandoff) { handoff.failed() } }
        finally {
            // Only the explicit low-level CONNECT result transfers ownership beyond this call.
            if (!tunnel) { transport.close() }
        }
    }
}

private func writeServerFailure(transport: DuplexTransport, method: HttpMethod,
    context: OperationContext, limits: HttpLimits): Unit {
    let response = HttpResponse(
        500, "Internal Server Error", ResponseBody.empty(),
        headers: HttpHeaders.builder(limits: limits)
            .add("Content-Length", "0").add("Connection", "close").build()
    )
    let _ = writeHttp1Response(transport, method, response, context: context, limits: limits)
}

private func validateServerHandoff(request: Http1ServerRequest, output: Http1ServerResponse): Unit {
    let status = output.response.status
    if (output.duplexHandler.isNone()) {
        if (status == 101) { throw IllegalArgumentException("101 response requires a protocol handler") }
        return
    }
    if (request.body.contentLength != Some(0) || output.response.body.contentLength != Some(0) ||
        !output.trailer.headers.entries.isEmpty()) {
        throw IllegalArgumentException("HTTP protocol handoff requires empty HTTP bodies and no trailer")
    }
    if (request.head.method == HttpMethod("CONNECT")) {
        if (status < 200 || status >= 300) {
            throw IllegalArgumentException("CONNECT handoff requires a successful response")
        }
        return
    }
    let selected = output.response.headers.getAll("upgrade")
    if (status != 101 || selected.size != 1 ||
        !isUpgradeProtocol(selected[0]) ||
        !headerContainsToken(request.head.headers, "upgrade", selected[0]) ||
        !headerContainsToken(request.head.headers, "connection", "upgrade") ||
        !headerContainsToken(output.response.headers, "connection", "upgrade")) {
        throw IllegalArgumentException("HTTP protocol handoff does not confirm the requested Upgrade")
    }
}
