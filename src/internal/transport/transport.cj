package wirestack.internal.transport

import wirestack.internal.common.SocketEndpoint

public enum ReadResult {
    | Data(Int64)
    | EndOfStream
}

public enum ShutdownDirection {
    | Read
    | Write
}

public enum AbortReason {
    | Cancelled
    | DeadlineExceeded
    | ProtocolFailure
    | ApplicationAbort
}

public enum TransportState {
    | Created
    | Connecting
    | Accepted
    | Open
    | ReadHalfClosed
    | WriteHalfClosed
    | Closing
    | Closed
    | Aborted
    | Failed
}

public struct TransportInfo {
    public let backend: String
    public let runtimeIoBackend: String
    public let localEndpoint: ?SocketEndpoint
    public let remoteEndpoint: ?SocketEndpoint
    public let supportsHalfClose: Bool
    public let supportsAbort: Bool

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

/** Internal byte-stream contract consumed by TLS and HTTP implementations. */
public interface DuplexTransport <: Resource {
    prop info: TransportInfo

    func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult
    func writeSome(source: ByteSpan, context!: OperationContext): Int64
    func shutdown(direction: ShutdownDirection): Unit
    func close(context: OperationContext): Unit
    func abort(reason!: ?AbortReason): Unit
}

/** Writes an entire span without resetting the caller's operation budget. */
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
                NetworkPhase.HttpBody,
                NetworkErrorCode.SystemFailure,
                "transport writeSome returned an invalid byte count"
            )
        }
        remaining = remaining.advance(written)
    }
}

/** Reads exactly one span or reports a structured premature EOF. */
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
                        NetworkPhase.HttpBody,
                        NetworkErrorCode.SystemFailure,
                        "transport readSome returned an invalid byte count"
                    )
                }
                remaining = remaining.advance(count)
            case ReadResult.EndOfStream =>
                throw NetworkException(
                    NetworkErrorCategory.Read,
                    NetworkPhase.HttpBody,
                    NetworkErrorCode.UnexpectedEof,
                    "peer reached end of stream before the requested bytes were read",
                    retryability: Retryability.Never
                )
        }
    }
}
