package wirestack

import std.io.IOException

/**
 * Wirestack 公开 API：NetworkErrorCategory。
 */
public enum NetworkErrorCategory {
/**
 * Wirestack 公开 API：Resolve。
 */
    | Resolve
/**
 * Wirestack 公开 API：Connect。
 */
    | Connect
/**
 * Wirestack 公开 API：Accept。
 */
    | Accept
/**
 * Wirestack 公开 API：Read。
 */
    | Read
/**
 * Wirestack 公开 API：Write。
 */
    | Write
/**
 * Wirestack 公开 API：Shutdown。
 */
    | Shutdown
/**
 * Wirestack 公开 API：Closed。
 */
    | Closed
/**
 * Wirestack 公开 API：Cancelled。
 */
    | Cancelled
/**
 * Wirestack 公开 API：DeadlineExceeded。
 */
    | DeadlineExceeded
/**
 * Wirestack 公开 API：Address。
 */
    | Address
/**
 * Wirestack 公开 API：Option。
 */
    | Option
/**
 * Wirestack 公开 API：ResourceExhausted。
 */
    | ResourceExhausted
/**
 * Wirestack 公开 API：Unsupported。
 */
    | Unsupported
/**
 * Wirestack 公开 API：System。
 */
    | System
}

/**
 * Wirestack 公开 API：NetworkPhase。
 */
public enum NetworkPhase {
/**
 * Wirestack 公开 API：Dns。
 */
    | Dns
/**
 * Wirestack 公开 API：AddressSelection。
 */
    | AddressSelection
/**
 * Wirestack 公开 API：TcpConnect。
 */
    | TcpConnect
/**
 * Wirestack 公开 API：TcpRead。
 */
    | TcpRead
/**
 * Wirestack 公开 API：TcpWrite。
 */
    | TcpWrite
/**
 * Wirestack 公开 API：TransportClose。
 */
    | TransportClose
/**
 * Wirestack 公开 API：ProxyConnect。
 */
    | ProxyConnect
/**
 * Wirestack 公开 API：TlsHandshake。
 */
    | TlsHandshake
/**
 * Wirestack 公开 API：TlsRead。
 */
    | TlsRead
/**
 * Wirestack 公开 API：TlsWrite。
 */
    | TlsWrite
/**
 * Wirestack 公开 API：HttpHeaders。
 */
    | HttpHeaders
/**
 * Wirestack 公开 API：HttpBody。
 */
    | HttpBody
/**
 * Wirestack 公开 API：PoolAcquire。
 */
    | PoolAcquire
/**
 * Wirestack 公开 API：ServerAccept。
 */
    | ServerAccept
}

/**
 * Wirestack 公开 API：NetworkErrorCode。
 */
public enum NetworkErrorCode {
/**
 * Wirestack 公开 API：Resolve。
 */
    | Resolve
/**
 * Wirestack 公开 API：NameNotFound。
 */
    | NameNotFound
/**
 * Wirestack 公开 API：NoData。
 */
    | NoData
/**
 * Wirestack 公开 API：TemporaryFailure。
 */
    | TemporaryFailure
/**
 * Wirestack 公开 API：InvalidName。
 */
    | InvalidName
/**
 * Wirestack 公开 API：UnsupportedFamily。
 */
    | UnsupportedFamily
/**
 * Wirestack 公开 API：ConnectRefused。
 */
    | ConnectRefused
/**
 * Wirestack 公开 API：NetworkUnreachable。
 */
    | NetworkUnreachable
/**
 * Wirestack 公开 API：HostUnreachable。
 */
    | HostUnreachable
/**
 * Wirestack 公开 API：ConnectionReset。
 */
    | ConnectionReset
/**
 * Wirestack 公开 API：BrokenPipe。
 */
    | BrokenPipe
/**
 * Wirestack 公开 API：TimedOut。
 */
    | TimedOut
/**
 * Wirestack 公开 API：Cancelled。
 */
    | Cancelled
/**
 * Wirestack 公开 API：Closed。
 */
    | Closed
/**
 * Wirestack 公开 API：AddressInUse。
 */
    | AddressInUse
/**
 * Wirestack 公开 API：PermissionDenied。
 */
    | PermissionDenied
/**
 * Wirestack 公开 API：ResourceExhausted。
 */
    | ResourceExhausted
/**
 * Wirestack 公开 API：ConcurrentOperation。
 */
    | ConcurrentOperation
/**
 * Wirestack 公开 API：UnexpectedEof。
 */
    | UnexpectedEof
/**
 * Wirestack 公开 API：Unsupported。
 */
    | Unsupported
/**
 * Wirestack 公开 API：SystemFailure。
 */
    | SystemFailure
/**
 * Wirestack 公开 API：InvalidState。
 */
    | InvalidState
}

/**
 * Wirestack 公开 API：Retryability。
 */
public enum Retryability {
/**
 * Wirestack 公开 API：Never。
 */
    | Never
/**
 * Wirestack 公开 API：SafeBeforeWrite。
 */
    | SafeBeforeWrite
/**
 * Wirestack 公开 API：SafeIfReplayable。
 */
    | SafeIfReplayable
/**
 * Wirestack 公开 API：Temporary。
 */
    | Temporary
/**
 * Wirestack 公开 API：Unknown。
 */
    | Unknown
}

/** Stable error evidence shared by transport, TLS and HTTP phases. */
public open class NetworkException <: IOException {
/**
 * Wirestack 公开 API：category。
 */
    public let category: NetworkErrorCategory
/**
 * Wirestack 公开 API：phase。
 */
    public let phase: NetworkPhase
/**
 * Wirestack 公开 API：code。
 */
    public let code: NetworkErrorCode
/**
 * Wirestack 公开 API：retryability。
 */
    public let retryability: Retryability
/**
 * Wirestack 公开 API：nativeCode。
 */
    public let nativeCode: ?Int64
/**
 * Wirestack 公开 API：localEndpoint。
 */
    public let localEndpoint: ?SocketEndpoint
/**
 * Wirestack 公开 API：remoteEndpoint。
 */
    public let remoteEndpoint: ?SocketEndpoint
/**
 * Wirestack 公开 API：cause。
 */
    public let cause: ?Exception

/**
 * Wirestack 公开 API：init。
 * @param category 参数 category。
 * @param cause 参数 cause。
 * @param code 参数 code。
 * @param localEndpoint 参数 localEndpoint。
 * @param message 参数 message。
 * @param nativeCode 参数 nativeCode。
 * @param phase 参数 phase。
 * @param remoteEndpoint 参数 remoteEndpoint。
 * @param retryability 参数 retryability。
 */
    public init(
        category: NetworkErrorCategory,
        phase: NetworkPhase,
        code: NetworkErrorCode,
        message: String,
        retryability!: Retryability = Retryability.Unknown,
        nativeCode!: ?Int64 = None<Int64>,
        localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
        remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
        cause!: ?Exception = None<Exception>
    ) {
        super(message)
        this.category = category
        this.phase = phase
        this.code = code
        this.retryability = retryability
        this.nativeCode = nativeCode
        this.localEndpoint = localEndpoint
        this.remoteEndpoint = remoteEndpoint
        this.cause = cause
    }

/**
 * Wirestack 公开 API：getClassName。
 */
    protected open override func getClassName(): String {
        "NetworkException"
    }
}
