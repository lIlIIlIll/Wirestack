package wirestack.internal.http1

import wirestack.http.*
import wirestack.internal.transport.*

/** Handler-owned response plus optional chunk trailer. */
public class Http1ServerResponse {
    public let response: HttpResponse
    public let trailer: HttpTrailer

    public init(response: HttpResponse, trailer!: HttpTrailer = HttpTrailer()) {
        this.response = response
        this.trailer = trailer
    }
}

public interface Http1ServerHandler {
    func handle(request: Http1ServerRequest): Http1ServerResponse
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
    try {
        while (served < maximumRequests) {
            let request = readHttp1ServerRequest(transport, context: context, limits: limits)
            var produced: ?Http1ServerResponse = None<Http1ServerResponse>
            try {
                produced = Some(handler.handle(request))
            } catch (error: Exception) {
                request.close()
                writeServerFailure(transport, request.head.method, context, limits)
                served += 1
                return Http1ServerConnectionResult(served, true, None<DuplexTransport>)
            }

            let requestConsumed = request.body.isFullyConsumed()
            request.close()
            let output = produced.getOrThrow()
            let evidence = writeHttp1Response(
                transport, request.head.method, output.response,
                context: context, limits: limits, trailer: output.trailer
            )
            served += 1
            unread = !requestConsumed
            tunnel = evidence.tunnelEstablished
            if (unread || tunnel || evidence.mustClose ||
                headerContainsToken(request.head.headers, "connection", "close") ||
                headerContainsToken(output.response.headers, "connection", "close")) {
                break
            }
        }
        Http1ServerConnectionResult(
            served, unread,
            if (tunnel) { Some<DuplexTransport>(transport) } else { None<DuplexTransport> }
        )
    } finally {
        // A successful CONNECT hands ownership to a future explicit tunnel API.
        if (!tunnel) { transport.close() }
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
