package wirestack.internal.http1

import wirestack.internal.http_model.*
import wirestack.internal.transport.*
import wirestack.internal.http2.*

/** A protocol-neutral head and the exclusive transport or stream claim it established. */
public class HttpDuplexConnection {
    public let status: Int64
    public let headers: HttpHeaders
    public let version: HttpVersion
    public let transport: DuplexTransport
    public let operationContext: OperationContext

    public init(status: Int64, headers: HttpHeaders, version: HttpVersion, transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()) {
        this.status = status
        this.headers = headers
        this.version = version
        this.transport = transport
        this.operationContext = context
    }
}

public enum HttpDuplexExchangeResult {
    | Connected(HttpDuplexConnection)
    | Response(HttpResponse)
}

protected func mapHttp1Upgrade(value: Http1UpgradeExchangeResult): HttpDuplexExchangeResult {
    match (value) {
        case Http1UpgradeExchangeResult.Upgraded(upgraded) =>
            HttpDuplexExchangeResult.Connected(HttpDuplexConnection(
                Int64(upgraded.responseHead.status), upgraded.responseHead.headers,
                upgraded.responseHead.version, upgraded.transport, context: upgraded.operationContext
            ))
        case Http1UpgradeExchangeResult.Response(rejected) => HttpDuplexExchangeResult.Response(rejected.response)
    }
}

internal func mapHttp2Connect(value: Http2ConnectResult): HttpDuplexExchangeResult {
    match (value) {
        case Http2ConnectResult.Connected(connected) =>
            HttpDuplexExchangeResult.Connected(HttpDuplexConnection(
                connected.status, connected.headers, HttpVersion.Http2, connected.transport,
                context: connected.operationContext
            ))
        case Http2ConnectResult.Rejected(response) => HttpDuplexExchangeResult.Response(response)
    }
}
