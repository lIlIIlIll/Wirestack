package wirestack.internal.transport

import std.io.IOException
import wirestack.internal.common.SocketEndpoint

public enum NetworkErrorCategory {
    | Resolve
    | Connect
    | Accept
    | Read
    | Write
    | Shutdown
    | Closed
    | Cancelled
    | DeadlineExceeded
    | Address
    | Option
    | ResourceExhausted
    | Unsupported
    | System
}

public enum NetworkPhase {
    | Dns
    | AddressSelection
    | TcpConnect
    | TcpRead
    | TcpWrite
    | TransportClose
    | ProxyConnect
    | TlsHandshake
    | TlsRead
    | TlsWrite
    | HttpHeaders
    | HttpBody
    | PoolAcquire
    | ServerAccept
}

public enum NetworkErrorCode {
    | Resolve
    | NameNotFound
    | NoData
    | TemporaryFailure
    | InvalidName
    | UnsupportedFamily
    | ConnectRefused
    | NetworkUnreachable
    | HostUnreachable
    | ConnectionReset
    | BrokenPipe
    | TimedOut
    | Cancelled
    | Closed
    | AddressInUse
    | PermissionDenied
    | ResourceExhausted
    | ConcurrentOperation
    | UnexpectedEof
    | Unsupported
    | SystemFailure
    | InvalidState
}

public enum Retryability {
    | Never
    | SafeBeforeWrite
    | SafeIfReplayable
    | Temporary
    | Unknown
}

/** Stable error evidence shared by transport, TLS and HTTP phases. */
public open class NetworkException <: IOException {
    public let category: NetworkErrorCategory
    public let phase: NetworkPhase
    public let code: NetworkErrorCode
    public let retryability: Retryability
    public let nativeCode: ?Int64
    public let localEndpoint: ?SocketEndpoint
    public let remoteEndpoint: ?SocketEndpoint
    public let cause: ?Exception

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

    protected open override func getClassName(): String {
        "NetworkException"
    }
}
