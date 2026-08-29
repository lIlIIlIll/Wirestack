package wirestack

/** A non-2xx proxy CONNECT response without credentials or response bodies. */
public class HttpProxyConnectException <: NetworkException {
    public let status: Int64
    public let reason: String

    public init(status: Int64, reason: String) {
        super(
            NetworkErrorCategory.Connect,
            NetworkPhase.ProxyConnect,
            NetworkErrorCode.ConnectRefused,
            "HTTP proxy rejected CONNECT with status ${status}",
            retryability: Retryability.Never
        )
        this.status = status
        this.reason = reason
    }

    protected override func getClassName(): String { "HttpProxyConnectException" }
}

public struct HttpServerShutdownResult {
    public let gracefullyCompleted: Int64
    public let aborted: Int64
    public let activeAtReturn: Int64

    public init(gracefullyCompleted: Int64, aborted: Int64, activeAtReturn: Int64) {
        this.gracefullyCompleted = gracefullyCompleted
        this.aborted = aborted
        this.activeAtReturn = activeAtReturn
    }
}
