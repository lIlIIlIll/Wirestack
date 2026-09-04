package wirestack

/** A non-2xx proxy CONNECT response without credentials or response bodies. */
public class HttpProxyConnectException <: NetworkException {
/**
 * Wirestack 公开 API：status。
 */
    public let status: Int64
/**
 * Wirestack 公开 API：reason。
 */
    public let reason: String

/**
 * Wirestack 公开 API：init。
 * @param reason 参数 reason。
 * @param status 参数 status。
 */
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

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "HttpProxyConnectException" }
}

/**
 * Wirestack 公开 API：HttpServerShutdownResult。
 */
public struct HttpServerShutdownResult {
/**
 * Wirestack 公开 API：gracefullyCompleted。
 */
    public let gracefullyCompleted: Int64
/**
 * Wirestack 公开 API：aborted。
 */
    public let aborted: Int64
/**
 * Wirestack 公开 API：activeAtReturn。
 */
    public let activeAtReturn: Int64

/**
 * Wirestack 公开 API：init。
 * @param aborted 参数 aborted。
 * @param activeAtReturn 参数 activeAtReturn。
 * @param gracefullyCompleted 参数 gracefullyCompleted。
 */
    public init(gracefullyCompleted: Int64, aborted: Int64, activeAtReturn: Int64) {
        this.gracefullyCompleted = gracefullyCompleted
        this.aborted = aborted
        this.activeAtReturn = activeAtReturn
    }
}
