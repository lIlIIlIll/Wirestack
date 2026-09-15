package wirestack.internal.tls_engine

import std.sync.*
import wirestack.internal.transport.*
import wirestack as api

public type TlsConnectionState = api.TlsConnectionState

/** Stable evidence explaining how the TLS byte stream terminated. */
public type TlsClosureEvidence = api.TlsClosureEvidence

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
    private var closeActive = false
    private var abortStarted = false
    private var terminalEvidence = None<TlsClosureEvidence>

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
            pump.releaseIdleBuffers()
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

    public prop closureEvidence: ?TlsClosureEvidence {
        get() { synchronized(lifecycleMutex) { terminalEvidence } }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        beginRead()
        try {
            let result = pump.readPlaintext(engine, transport, destination, context: context)
            match (result) {
                case ReadResult.EndOfStream => recordEvidence(TlsClosureEvidence.CloseNotify)
                case _ => ()
            }
            result
        } catch (error: NetworkException) {
            recordTruncation(error)
            abort(reason: abortReason(error))
            throw error
        } catch (error: Exception) {
            abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        } finally {
            finishRead()
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
            finishWrite()
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
                        closeActive = true
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
        var registration = None<api.CancellationRegistration>
        try {
            try {
                try {
                    registration = Some(context.cancellation.register {
                        => abort(reason: Some(AbortReason.Cancelled))
                    })
                    pump.shutdown(engine, transport, context: context)
                    recordEvidence(TlsClosureEvidence.CloseNotify)
                } catch (error: NetworkException) {
                    recordTruncation(error)
                    let closedByAbort = match (error.code) {
                        case NetworkErrorCode.Closed => synchronized(lifecycleMutex) {
                            match (lifecycle) {
                                case TlsConnectionState.Aborted => true
                                case _ => false
                            }
                        }
                        case _ => false
                    }
                    if (!closedByAbort) { throw error }
                    if (context.isCancellationRequested()) {
                        throw TlsEngineException(TlsEngineErrorCode.HandshakeCancelled, "TLS close was cancelled")
                    }
                    if (context.isDeadlineExceeded()) {
                        throw TlsEngineException(TlsEngineErrorCode.HandshakeTimeout, "TLS close deadline exceeded")
                    }
                }
            } finally {
                pump.requestTerminal()
                try {
                    // Terminal cleanup keeps the caller's own budget: handing a
                    // context-free close to a peer-waiting transport could hang
                    // past the caller's deadline. Once this budget has stopped
                    // graceful cleanup, only an immediate abort claims the
                    // transport without waiting for a peer again.
                    if (context.isCancellationRequested()) {
                        transport.abort(reason: Some(AbortReason.Cancelled))
                    } else if (context.isDeadlineExceeded()) {
                        transport.abort(reason: Some(AbortReason.DeadlineExceeded))
                    } else {
                        transport.close(context)
                    }
                } catch (error: NetworkException) {
                    // The transport stopped graceful cleanup with this same
                    // budget or failed before claiming disposal; abort claims
                    // terminal cleanup so no active owner stays blocked.
                    if (context.isCancellationRequested()) {
                        transport.abort(reason: Some(AbortReason.Cancelled))
                        throw TlsEngineException(TlsEngineErrorCode.HandshakeCancelled, "TLS close was cancelled")
                    }
                    if (context.isDeadlineExceeded()) {
                        transport.abort(reason: Some(AbortReason.DeadlineExceeded))
                        throw TlsEngineException(TlsEngineErrorCode.HandshakeTimeout, "TLS close deadline exceeded")
                    }
                    transport.abort(reason: abortReason(error))
                    throw error
                } finally {
                    synchronized(lifecycleMutex) {
                        closeActive = false
                        match (lifecycle) {
                            case TlsConnectionState.Closing => lifecycle = TlsConnectionState.Closed
                            case _ => ()
                        }
                    }
                    releaseEngineIfIdle()
                }
            }
        } finally {
            match (registration) {
                case Some(value) => value.unregister()
                case None => ()
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
                    if (terminalEvidence.isNone()) {
                        terminalEvidence = Some(TlsClosureEvidence.LocalAbort)
                    }
                    if (!abortStarted) {
                        abortStarted = true
                        true
                    } else {
                        false
                    }
            }
        }
        if (performAbort) {
            pump.requestTerminal()
            try { transport.abort(reason: reason) }
            finally { releaseEngineIfIdle() }
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
            match (terminalEvidence) {
                case Some(TlsClosureEvidence.CloseNotify) =>
                    throw NetworkException(
                        NetworkErrorCategory.Closed,
                        NetworkPhase.TlsWrite,
                        NetworkErrorCode.Closed,
                        "TLS peer has sent close_notify",
                        retryability: Retryability.Never
                    )
                case _ => ()
            }
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

    private func finishRead(): Unit {
        synchronized(lifecycleMutex) { readActive = false }
        releaseEngineIfIdle()
    }

    private func finishWrite(): Unit {
        synchronized(lifecycleMutex) { writeActive = false }
        releaseEngineIfIdle()
    }

    /**
     * Claims engine destruction only after every connection-owned pump caller
     * has left. Terminal transport cleanup wakes blocked I/O; the last caller
     * then performs the one exact engine release instead of racing engine use.
     */
    private func releaseEngineIfIdle(): Unit {
        let release = synchronized(lifecycleMutex) {
            let terminal = match (lifecycle) {
                case TlsConnectionState.Closed | TlsConnectionState.Aborted => true
                case _ => false
            }
            if (!engineReleased && terminal && !readActive && !writeActive && !closeActive) {
                engineReleased = true
                true
            } else {
                false
            }
        }
        if (release) {
            try { engine.close() }
            finally { pump.releaseIdleBuffers() }
        }
    }

    private func recordEvidence(value: TlsClosureEvidence): Unit {
        synchronized(lifecycleMutex) {
            if (terminalEvidence.isNone()) {
                terminalEvidence = Some(value)
            }
        }
    }

    private func recordTruncation(error: NetworkException): Unit {
        match (error.code) {
            case NetworkErrorCode.UnexpectedEof => synchronized(lifecycleMutex) {
                    terminalEvidence = Some(TlsClosureEvidence.PeerClosedWithoutCloseNotify)
                }
            case _ => ()
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
