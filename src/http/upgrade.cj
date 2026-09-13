package wirestack.http

import wirestack as api
import wirestack.internal.http1 as http1

/** Exclusive HTTP/1.1 connection or HTTP/2 CONNECT stream transferred to the caller. */
public class HttpUpgradedConnection <: Resource {
    /** Accepted handshake status from the peer. */
    public let status: Int64
    /** Accepted handshake response headers. */
    public let headers: HttpHeaders
    /** HTTP version that established this connection or stream. */
    public let version: HttpVersion
    /** Exclusive transport for the upgraded HTTP/1.1 connection or HTTP/2 CONNECT stream. */
    public let transport: api.DuplexTransport

    internal init(value: http1.HttpDuplexConnection) {
        status = value.status
        headers = value.headers
        version = value.version
        transport = value.transport
    }

    /** Closes only the transferred connection or stream, never sibling HTTP/2 streams. */
    public func close(): Unit { transport.close() }
    /** Reports whether the transferred transport is closed. */
    public func isClosed(): Bool { transport.isClosed() }
}

/** Rejection retains the complete owned response instead of discarding its body. */
public enum HttpUpgradeResult {
    /** Successful handshake and caller-owned upgraded connection or CONNECT stream. */
    | Connected(HttpUpgradedConnection)
    /** Rejected handshake and caller-owned response, including its body. */
    | Rejected(HttpResponse)
}

internal func publicHttpUpgradeResult(value: http1.HttpDuplexExchangeResult): HttpUpgradeResult {
    match (value) {
        case http1.HttpDuplexExchangeResult.Connected(connection) =>
            HttpUpgradeResult.Connected(HttpUpgradedConnection(connection))
        case http1.HttpDuplexExchangeResult.Response(response) => HttpUpgradeResult.Rejected(response)
    }
}
