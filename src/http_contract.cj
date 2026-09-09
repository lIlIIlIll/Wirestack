package wirestack

/** A non-2xx proxy CONNECT response without credentials or response bodies. */
public class HttpProxyConnectException <: NetworkException {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let status: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let reason: String

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param reason 描述终止原因的稳定值。
 * @param status 待记录的协议状态码。
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
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "HttpProxyConnectException" }
}

/**
 * Wirestack 公开 API：表示一次操作的结果及其状态。
 */
public struct HttpServerShutdownResult {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let gracefullyCompleted: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let aborted: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let activeAtReturn: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param aborted 调用方提供的输入值。
 * @param activeAtReturn 调用方提供的输入值。
 * @param gracefullyCompleted 调用方提供的输入值。
 */
    public init(gracefullyCompleted: Int64, aborted: Int64, activeAtReturn: Int64) {
        this.gracefullyCompleted = gracefullyCompleted
        this.aborted = aborted
        this.activeAtReturn = activeAtReturn
    }
}
