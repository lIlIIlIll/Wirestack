package wirestack


/**
 * Wirestack 公开 API：表示一次操作的结果及其状态。
 */
public enum ReadResult {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Data(Int64)
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | EndOfStream
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum ShutdownDirection {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Read
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Write
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum AbortReason {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Cancelled
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | DeadlineExceeded
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ProtocolFailure
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ApplicationAbort
}

/**
 * Provider-neutral, read-only transport diagnostics.
 *
 * runtimeIoBackend names a stable runtime family. It must not claim an
 * operating-system event mechanism unless the public SDK exposes one.
 * Endpoints use Wirestack types and never expose a provider socket object.
 */
public struct TransportInfo {
    /** Transport adapter identity, such as std.net or memory. */
    public let backend: String
    /** Stable runtime family, such as cjnative or deterministic. */
    public let runtimeIoBackend: String
    /** Bound local endpoint when the adapter can report it. */
    public let localEndpoint: ?SocketEndpoint
    /** Connected peer endpoint when the adapter can report it. */
    public let remoteEndpoint: ?SocketEndpoint
    /** Whether directional read and write shutdown are supported. */
    public let supportsHalfClose: Bool
    /** Whether immediate abort is supported. */
    public let supportsAbort: Bool

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param backend 调用方提供的输入值。
 * @param localEndpoint 调用方提供的输入值。
 * @param remoteEndpoint 调用方提供的输入值。
 * @param runtimeIoBackend 调用方提供的输入值。
 * @param supportsAbort 调用方提供的输入值。
 * @param supportsHalfClose 调用方提供的输入值。
 */
    public init(
        backend: String,
        runtimeIoBackend!: String = "",
        localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
        remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
        supportsHalfClose!: Bool = true,
        supportsAbort!: Bool = true
    ) {
        if (backend.isEmpty()) {
            throw IllegalArgumentException("transport backend must not be empty")
        }
        this.backend = backend
        this.runtimeIoBackend = runtimeIoBackend
        this.localEndpoint = localEndpoint
        this.remoteEndpoint = remoteEndpoint
        this.supportsHalfClose = supportsHalfClose
        this.supportsAbort = supportsAbort
    }
}

/** Provider-neutral byte-stream contract used by public TLS and custom transports. */
public interface DuplexTransport <: Resource {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    prop info: TransportInfo

    /**
     * Reads at most destination.length bytes. Empty destinations return
     * Data(0) immediately; only a peer FIN is reported as EndOfStream.
     * At most one read may be active, independently of one active write.
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param destination 调用方提供的输入值。
     */
    func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult

    /**
     * Writes at most source.length bytes and may return a partial count. Empty
     * sources return zero immediately. At most one write may be active.
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param source 调用方提供的输入值。
     */
    func writeSome(source: ByteSpan, context!: OperationContext): Int64

/**
 * Closes only the selected direction and preserves the other direction.
 * @param direction 调用方提供的输入值。
 */
    func shutdown(direction: ShutdownDirection): Unit

/**
 * Attempts graceful, idempotent completion without resetting context.
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 */
    func close(context: OperationContext): Unit

/**
 * Immediately and idempotently terminates both directions.
 * @param reason 描述终止原因的稳定值。
 */
    func abort(reason!: ?AbortReason): Unit
}

/** A bounded transport acceptor. Closing it must wake an active accept. */
public interface TransportListener <: Resource {
/**
 * Wirestack 公开 API：接受一个待处理连接。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 */
    func accept(context: OperationContext): DuplexTransport
/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    func close(): Unit
}

/** DNS-free connection-attempt boundary consumed by higher-level connectors. */
public interface TransportFactory {
/**
 * Wirestack 公开 API：建立到目标端点的连接。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param endpoint 调用方提供的输入值。
 */
    func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport
}

/**
 * Writes an entire span through partial writes. Every attempt receives the
 * original OperationContext, so retries never reset its absolute deadline.
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param source 调用方提供的输入值。
 * @param transport 调用方提供的输入值。
 */
public func writeAll(
    transport: DuplexTransport,
    source: ByteSpan,
    context!: OperationContext = OperationContext.background()
): Unit {
    var remaining = source
    while (!remaining.isEmpty()) {
        let written = transport.writeSome(remaining, context: context)
        if (written <= 0 || written > remaining.length) {
            throw NetworkException(
                NetworkErrorCategory.System,
                NetworkPhase.TcpWrite,
                NetworkErrorCode.SystemFailure,
                "transport writeSome returned an invalid byte count",
                retryability: Retryability.Never
            )
        }
        remaining = remaining.advance(written)
    }
}

/**
 * Reads exactly one span through partial reads. Every attempt receives the
 * original OperationContext. Peer EOF before completion is UnexpectedEof.
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param destination 调用方提供的输入值。
 * @param transport 调用方提供的输入值。
 */
public func readExact(
    transport: DuplexTransport,
    destination: MutableByteSpan,
    context!: OperationContext = OperationContext.background()
): Unit {
    var remaining = destination
    while (!remaining.isEmpty()) {
        match (transport.readSome(remaining, context: context)) {
            case ReadResult.Data(count) =>
                if (count <= 0 || count > remaining.length) {
                    throw NetworkException(
                        NetworkErrorCategory.System,
                        NetworkPhase.TcpRead,
                        NetworkErrorCode.SystemFailure,
                        "transport readSome returned an invalid byte count",
                        retryability: Retryability.Never
                    )
                }
                remaining = remaining.advance(count)
            case ReadResult.EndOfStream =>
                throw NetworkException(
                    NetworkErrorCategory.Read,
                    NetworkPhase.TcpRead,
                    NetworkErrorCode.UnexpectedEof,
                    "peer reached end of stream before the requested bytes were read",
                    retryability: Retryability.Never
                )
        }
    }
}
