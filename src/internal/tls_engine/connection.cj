package wirestack.internal.tls_engine

import std.sync.*
import wirestack.internal.transport.*

public enum TlsConnectionState {
    | Open
    | Closing
    | Closed
    | Aborted
}

/**
 * Owns one TLS engine and the sole reference to its ciphertext transport.
 * Construction consumes both inputs whether the handshake succeeds or fails.
 */
public class TlsConnection <: DuplexTransport {
    private let engine: TlsEngine
    private let transport: DuplexTransport
    private let pump: TlsEnginePump
    private let transportInfo: TransportInfo
    public let handshakeInfo: ?TlsHandshakeInfo
    private let lifecycleMutex = Mutex()
    private var lifecycle = TlsConnectionState.Open
    private var readActive = false
    private var writeActive = false
    private var engineReleased = false
    private var closeStarted = false
    private var abortStarted = false

    private init(
        engine: TlsEngine,
        transport: DuplexTransport,
        pump: TlsEnginePump,
        handshakeInfo: ?TlsHandshakeInfo
    ) {
        this.engine = engine
        this.transport = transport
        this.pump = pump
        this.handshakeInfo = handshakeInfo
        let underlying = transport.info
        transportInfo = TransportInfo(
            "tls",
            runtimeIoBackend: underlying.runtimeIoBackend,
            localEndpoint: underlying.localEndpoint,
            remoteEndpoint: underlying.remoteEndpoint,
            supportsHalfClose: false,
            supportsAbort: underlying.supportsAbort
        )
    }

    public static func handshake(
        engine: TlsEngine,
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background(),
        pump!: TlsEnginePump = TlsEnginePump()
    ): TlsConnection {
        try {
            pump.driveHandshake(engine, transport, context: context)
            let info = match (engine) {
                case value: HandshakeInfoTlsEngine => Some(value.handshakeInfo())
                case _ => None<TlsHandshakeInfo>
            }
            TlsConnection(engine, transport, pump, info)
        } catch (error: NetworkException) {
            try { transport.abort(reason: abortReason(error)) }
            finally { engine.close() }
            throw error
        } catch (error: Exception) {
            try { transport.abort(reason: Some(AbortReason.ProtocolFailure)) }
            finally { engine.close() }
            throw error
        }
    }

    public prop info: TransportInfo {
        get() { transportInfo }
    }

    public prop state: TlsConnectionState {
        get() { synchronized(lifecycleMutex) { lifecycle } }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        beginRead()
        try {
            pump.readPlaintext(engine, transport, destination, context: context)
        } catch (error: NetworkException) {
            abort(reason: abortReason(error))
            throw error
        } catch (error: Exception) {
            abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        } finally {
            synchronized(lifecycleMutex) { readActive = false }
        }
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        beginWrite()
        try {
            pump.writePlaintext(engine, transport, source, context: context)
        } catch (error: NetworkException) {
            abort(reason: abortReason(error))
            throw error
        } catch (error: Exception) {
            abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        } finally {
            synchronized(lifecycleMutex) { writeActive = false }
        }
    }

    public func shutdown(direction: ShutdownDirection): Unit {
        let _ = direction
        throw NetworkException(
            NetworkErrorCategory.Unsupported,
            NetworkPhase.TransportClose,
            NetworkErrorCode.Unsupported,
            "TLS half-close requires close_notify and is not exposed as transport shutdown",
            retryability: Retryability.Never
        )
    }

    public func close(context: OperationContext): Unit {
        let performClose = synchronized(lifecycleMutex) {
            match (lifecycle) {
                case TlsConnectionState.Open =>
                    lifecycle = TlsConnectionState.Closing
                    if (!closeStarted) {
                        closeStarted = true
                        true
                    } else {
                        false
                    }
                case _ => false
            }
        }
        if (!performClose) {
            return
        }
        try {
            transport.close(context)
        } catch (error: Exception) {
            abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        } finally {
            releaseEngineOnce()
        }
        synchronized(lifecycleMutex) {
            match (lifecycle) {
                case TlsConnectionState.Closing => lifecycle = TlsConnectionState.Closed
                case _ => ()
            }
        }
    }

    public func close(): Unit {
        close(OperationContext.background())
    }

    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let performAbort = synchronized(lifecycleMutex) {
            match (lifecycle) {
                case TlsConnectionState.Closed | TlsConnectionState.Aborted => false
                case _ =>
                    lifecycle = TlsConnectionState.Aborted
                    if (!abortStarted) {
                        abortStarted = true
                        true
                    } else {
                        false
                    }
            }
        }
        if (performAbort) {
            try { transport.abort(reason: reason) }
            finally { releaseEngineOnce() }
        }
    }

    public func isClosed(): Bool {
        synchronized(lifecycleMutex) {
            match (lifecycle) {
                case TlsConnectionState.Closed | TlsConnectionState.Aborted => true
                case _ => false
            }
        }
    }

    private func beginRead(): Unit {
        synchronized(lifecycleMutex) {
            requireOpen(NetworkPhase.TlsRead)
            if (readActive) {
                throw concurrentTlsOperation(NetworkErrorCategory.Read, NetworkPhase.TlsRead)
            }
            readActive = true
        }
    }

    private func beginWrite(): Unit {
        synchronized(lifecycleMutex) {
            requireOpen(NetworkPhase.TlsWrite)
            if (writeActive) {
                throw concurrentTlsOperation(NetworkErrorCategory.Write, NetworkPhase.TlsWrite)
            }
            writeActive = true
        }
    }

    private func requireOpen(phase: NetworkPhase): Unit {
        match (lifecycle) {
            case TlsConnectionState.Open => ()
            case _ =>
                throw NetworkException(
                    NetworkErrorCategory.Closed,
                    phase,
                    NetworkErrorCode.Closed,
                    "TLS connection is not open",
                    retryability: Retryability.Never
                )
        }
    }

    private func releaseEngineOnce(): Unit {
        let release = synchronized(lifecycleMutex) {
            if (engineReleased) {
                false
            } else {
                engineReleased = true
                true
            }
        }
        if (release) {
            engine.close()
        }
    }

}

private func concurrentTlsOperation(
    category: NetworkErrorCategory,
    phase: NetworkPhase
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.ConcurrentOperation,
        "a same-direction TLS operation is already active",
        retryability: Retryability.Never
    )
}

private func abortReason(error: NetworkException): ?AbortReason {
    match (error.code) {
        case NetworkErrorCode.Cancelled => Some(AbortReason.Cancelled)
        case NetworkErrorCode.TimedOut => Some(AbortReason.DeadlineExceeded)
        case _ => Some(AbortReason.ProtocolFailure)
    }
}
