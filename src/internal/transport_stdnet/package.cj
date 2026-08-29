package wirestack.internal.transport_stdnet

import std.net.*
import std.sync.*
import std.time.MonoTime
import std.convert.Parsable
import wirestack.internal.common.*
import wirestack.internal.transport.*

private const DEFAULT_STAGING_BUFFER_SIZE: Int64 = 16 * 1024
private const MAX_LISTENER_BACKLOG: Int64 = 65535

@When[os == "Windows"]
@C
private struct AbortiveLinger {
    var enabled: UInt16 = 1
    var seconds: UInt16 = 0

    static const size: UIntNative = 4
}

@When[os != "Windows"]
@C
private struct AbortiveLinger {
    var enabled: Int32 = 1
    var seconds: Int32 = 0

    static const size: UIntNative = 8
}

/** Default DNS-free connection factory for Linux Happy Eyeballs attempts. */
public class StdNetTransportFactory <: TransportFactory {
    private let stagingBufferSize: Int64

    public init(stagingBufferSize!: Int64 = DEFAULT_STAGING_BUFFER_SIZE) {
        if (stagingBufferSize <= 0) {
            throw IllegalArgumentException("stagingBufferSize must be positive")
        }
        this.stagingBufferSize = stagingBufferSize
    }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        StdNetTransport.connect(endpoint, context: context, stagingBufferSize: stagingBufferSize)
    }
}

/**
 * Linux TCP adapter over public std.net APIs.
 *
 * Cancellation is terminal for the transport: the registered callback closes
 * the socket, which is the only public operation proven to wake blocked I/O in
 * the pinned SDK. The adapter never reads or caches a private native handle.
 */
public class StdNetTransport <: DuplexTransport {
    private let socket: TcpSocket
    private let stagingBufferSize: Int64
    private let lifecycleMutex = Mutex()
    private let lifecycleChanged = synchronized(lifecycleMutex) { lifecycleMutex.condition() }
    private var localEndpoint: ?SocketEndpoint
    private var remoteEndpoint: ?SocketEndpoint
    private var readActive = false
    private var writeActive = false
    private var closed = false
    private var aborted = false
    private var nativeClosed = false
    private var copiedReadBytes: Int64 = 0
    private var copiedWriteBytes: Int64 = 0
    private var writeStaging = Array<Byte>()

    private init(
        socket: TcpSocket,
        localEndpoint: ?SocketEndpoint,
        remoteEndpoint: ?SocketEndpoint,
        stagingBufferSize: Int64
    ) {
        if (stagingBufferSize <= 0) {
            throw IllegalArgumentException("stagingBufferSize must be positive")
        }
        this.socket = socket
        this.localEndpoint = localEndpoint
        this.remoteEndpoint = remoteEndpoint
        this.stagingBufferSize = stagingBufferSize
    }

    /** Connects to an already-resolved IP endpoint without invoking DNS. */
    public static func connect(
        endpoint: SocketEndpoint,
        context!: OperationContext = OperationContext.background(),
        stagingBufferSize!: Int64 = DEFAULT_STAGING_BUFFER_SIZE
    ): StdNetTransport {
        checkContext(
            context,
            NetworkErrorCategory.Connect,
            NetworkPhase.TcpConnect,
            remoteEndpoint: Some(endpoint)
        )
        let socket = TcpSocket(toStdEndpoint(endpoint))
        let transport = StdNetTransport(
            socket,
            None<SocketEndpoint>,
            Some(endpoint),
            stagingBufferSize
        )
        try {
            transport.connectSocket(context)
            transport
        } catch (error: Exception) {
            transport.abort(reason: Some(AbortReason.ApplicationAbort))
            throw error
        }
    }

    internal static func fromAccepted(
        socket: TcpSocket,
        stagingBufferSize!: Int64 = DEFAULT_STAGING_BUFFER_SIZE
    ): StdNetTransport {
        StdNetTransport(
            socket,
            Some(fromStdEndpoint(socket.localAddress)),
            Some(fromStdEndpoint(socket.remoteAddress)),
            stagingBufferSize
        )
    }

    public prop info: TransportInfo {
        get() {
            synchronized(lifecycleMutex) {
                TransportInfo(
                    "std.net",
                    runtimeIoBackend: "cjnative",
                    localEndpoint: localEndpoint,
                    remoteEndpoint: remoteEndpoint,
                    supportsHalfClose: false,
                    supportsAbort: true
                )
            }
        }
    }

    /** Bytes copied solely because std.net only accepts whole Array values. */
    public prop stagingCopiedBytes: (Int64, Int64) {
        get() {
            synchronized(lifecycleMutex) { (copiedReadBytes, copiedWriteBytes) }
        }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let background = isBackgroundContext(context)
        if (!background) {
            checkContext(
                context,
                NetworkErrorCategory.Read,
                NetworkPhase.TcpRead,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        beginRead()
        try {
            if (destination.isEmpty()) {
                return ReadResult.Data(0)
            }
            let count = min(destination.length, stagingBufferSize)
            let direct = destination.offset == 0 &&
                destination.length == destination.bytes.size &&
                count == destination.bytes.size
            let target = if (direct) {
                destination.bytes
            } else {
                Array<Byte>(count, repeat: 0)
            }
            if (background) {
                try {
                    return finishRead(socket.read(target), target, destination, direct, context)
                } catch (error: SocketTimeoutException) {
                    throw timedOut(
                        NetworkErrorCategory.Read,
                        NetworkPhase.TcpRead,
                        error,
                        localEndpoint: localEndpoint,
                        remoteEndpoint: remoteEndpoint
                    )
                } catch (error: SocketException) {
                    throw mapSocketError(error, context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                }
            }
            let gate = OperationGate()
            let registration = context.cancellation.register {
                => gate.interrupt { => abort(reason: Some(AbortReason.Cancelled)) }
            }
            try {
                socket.readTimeout = remaining(context)
                let received = socket.read(target)
                if (!gate.complete()) {
                    throw contextOrTerminalError(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                }
                finishRead(received, target, destination, direct, context)
            } catch (error: SocketTimeoutException) {
                let _ = gate.complete()
                throw timedOut(
                    NetworkErrorCategory.Read,
                    NetworkPhase.TcpRead,
                    error,
                    localEndpoint: localEndpoint,
                    remoteEndpoint: remoteEndpoint
                )
            } catch (error: SocketException) {
                let _ = gate.complete()
                throw mapSocketError(error, context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
            } finally {
                resetReadTimeout()
                registration.unregister()
            }
        } finally {
            endRead()
        }
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let background = isBackgroundContext(context)
        if (!background) {
            checkContext(
                context,
                NetworkErrorCategory.Write,
                NetworkPhase.TcpWrite,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        beginWrite()
        try {
            if (source.isEmpty()) {
                return 0
            }
            let count = min(source.length, stagingBufferSize)
            let direct = source.offset == 0 &&
                source.length == source.bytes.size &&
                count == source.bytes.size
            let payload = if (direct) {
                source.bytes
            } else {
                synchronized(lifecycleMutex) {
                    if (writeStaging.size != count) {
                        writeStaging = Array<Byte>(count, repeat: 0)
                    }
                    writeStaging
                }
            }
            if (!direct) {
                for (index in 0..count) {
                    payload[index] = source.bytes[source.offset + index]
                }
            }
            if (background) {
                try {
                    socket.write(payload)
                    return finishWrite(count, direct)
                } catch (error: SocketTimeoutException) {
                    throw writeTimedOut(
                        error,
                        localEndpoint: localEndpoint,
                        remoteEndpoint: remoteEndpoint
                    )
                } catch (error: SocketException) {
                    throw mapSocketError(error, context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                }
            }
            let gate = OperationGate()
            let registration = context.cancellation.register {
                => gate.interrupt { => abort(reason: Some(AbortReason.Cancelled)) }
            }
            try {
                socket.writeTimeout = remaining(context)
                socket.write(payload)
                if (!gate.complete()) {
                    throw contextOrTerminalError(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                }
                finishWrite(count, direct)
            } catch (error: SocketTimeoutException) {
                let _ = gate.complete()
                throw writeTimedOut(
                    error,
                    localEndpoint: localEndpoint,
                    remoteEndpoint: remoteEndpoint
                )
            } catch (error: SocketException) {
                let _ = gate.complete()
                throw mapSocketError(error, context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
            } finally {
                resetWriteTimeout()
                registration.unregister()
            }
        } finally {
            endWrite()
        }
    }

    /** Typed half-close is unavailable in the pinned public std.net API. */
    public func shutdown(direction: ShutdownDirection): Unit {
        let _ = direction
        throw NetworkException(
            NetworkErrorCategory.Unsupported,
            NetworkPhase.TransportClose,
            NetworkErrorCode.Unsupported,
            "this transport adapter does not support directional TCP shutdown",
            retryability: Retryability.Never,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        )
    }

    public func close(context: OperationContext): Unit {
        let _ = context
        let shouldClose = synchronized(lifecycleMutex) {
            if (closed || aborted) {
                false
            } else {
                closed = true
                lifecycleChanged.notifyAll()
                takeNativeCloseLocked()
            }
        }
        if (shouldClose) {
            socket.close()
        }
    }

    public func close(): Unit {
        close(OperationContext.background())
    }

    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        let shouldClose = synchronized(lifecycleMutex) {
            if (closed || aborted) {
                false
            } else {
                aborted = true
                lifecycleChanged.notifyAll()
                takeNativeCloseLocked()
            }
        }
        if (shouldClose) {
            try {
                configureAbortiveClose(socket)
            } catch (_: Exception) {
                // Abort still closes if SO_LINGER cannot be configured.
            }
            socket.close()
        }
    }

    public func isClosed(): Bool {
        synchronized(lifecycleMutex) { closed || aborted }
    }

    private func connectSocket(context: OperationContext): Unit {
        let gate = OperationGate()
        let registration = context.cancellation.register {
            => gate.interrupt { => abort(reason: Some(AbortReason.Cancelled)) }
        }
        try {
            socket.connect(timeout: remaining(context))
            if (!gate.complete()) {
                throw contextOrTerminalError(context, NetworkErrorCategory.Connect, NetworkPhase.TcpConnect)
            }
            let actualLocal = fromStdEndpoint(socket.localAddress)
            let actualRemote = fromStdEndpoint(socket.remoteAddress)
            synchronized(lifecycleMutex) {
                localEndpoint = Some(actualLocal)
                remoteEndpoint = Some(actualRemote)
            }
        } catch (error: SocketTimeoutException) {
            let _ = gate.complete()
            throw timedOut(
                NetworkErrorCategory.Connect,
                NetworkPhase.TcpConnect,
                error,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        } catch (error: SocketException) {
            let _ = gate.complete()
            throw mapSocketError(error, context, NetworkErrorCategory.Connect, NetworkPhase.TcpConnect)
        } finally {
            registration.unregister()
        }
    }

    private func beginRead(): Unit {
        synchronized(lifecycleMutex) {
            if (readActive) {
                throw concurrent(NetworkErrorCategory.Read, NetworkPhase.TcpRead)
            }
            if (closed || aborted) {
                throw closedError(
                    NetworkErrorCategory.Read,
                    NetworkPhase.TcpRead,
                    localEndpoint: localEndpoint,
                    remoteEndpoint: remoteEndpoint
                )
            }
            readActive = true
        }
    }

    private func endRead(): Unit {
        synchronized(lifecycleMutex) {
            readActive = false
        }
    }

    private func beginWrite(): Unit {
        synchronized(lifecycleMutex) {
            if (writeActive) {
                throw concurrent(NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
            }
            if (closed || aborted) {
                throw closedError(
                    NetworkErrorCategory.Write,
                    NetworkPhase.TcpWrite,
                    localEndpoint: localEndpoint,
                    remoteEndpoint: remoteEndpoint
                )
            }
            writeActive = true
        }
    }

    private func endWrite(): Unit {
        synchronized(lifecycleMutex) { writeActive = false }
    }

    private func finishRead(
        received: Int64,
        target: Array<Byte>,
        destination: MutableByteSpan,
        direct: Bool,
        context: OperationContext
    ): ReadResult {
        if (received == 0) {
            ensureNotLocallyTerminated(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
            return ReadResult.EndOfStream
        }
        if (!direct) {
            for (index in 0..received) {
                destination.bytes[destination.offset + index] = target[index]
            }
            synchronized(lifecycleMutex) { copiedReadBytes += received }
        }
        ReadResult.Data(received)
    }

    private func finishWrite(count: Int64, direct: Bool): Int64 {
        if (!direct) {
            synchronized(lifecycleMutex) { copiedWriteBytes += count }
        }
        count
    }

    private func resetReadTimeout(): Unit {
        try {
            socket.readTimeout = None<Duration>
        } catch (_: Exception) {
            // A concurrent close can make the reset unavailable. The closed
            // transport cannot perform another background read.
        }
    }

    private func resetWriteTimeout(): Unit {
        try {
            socket.writeTimeout = None<Duration>
        } catch (_: Exception) {
            // A concurrent close can make the reset unavailable. The closed
            // transport cannot perform another background write.
        }
    }

    /** Waits for read activity for bounded lifecycle diagnostics and race gates. */
    public func waitUntilReadActive(timeout: Duration): Bool {
        let expiresAt = MonoTime.now() + timeout
        while (true) {
            let (active, terminal) = synchronized(lifecycleMutex) { (readActive, closed || aborted) }
            if (active) {
                return true
            }
            if (terminal || MonoTime.now() >= expiresAt) {
                return false
            }
            sleep(Duration.millisecond)
        }
        false
    }

    /** Waits for write activity for bounded lifecycle diagnostics and race gates. */
    internal func waitUntilWriteActive(timeout: Duration): Bool {
        let expiresAt = MonoTime.now() + timeout
        while (true) {
            let (active, terminal) = synchronized(lifecycleMutex) { (writeActive, closed || aborted) }
            if (active) {
                return true
            }
            if (terminal || MonoTime.now() >= expiresAt) {
                return false
            }
            sleep(Duration.millisecond)
        }
        false
    }

    private func ensureNotLocallyTerminated(
        context: OperationContext,
        category: NetworkErrorCategory,
        phase: NetworkPhase
    ): Unit {
        if (context.isCancellationRequested()) {
            throw cancelled(
                category,
                phase,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            throw deadlineExceeded(
                category,
                phase,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        if (isClosed()) {
            throw closedError(
                category,
                phase,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
    }

    private func contextOrTerminalError(
        context: OperationContext,
        category: NetworkErrorCategory,
        phase: NetworkPhase
    ): NetworkException {
        if (context.isCancellationRequested()) {
            return cancelled(
                category,
                phase,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            return deadlineExceeded(
                category,
                phase,
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        closedError(
            category,
            phase,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        )
    }

    private func mapSocketError(
        error: SocketException,
        context: OperationContext,
        category: NetworkErrorCategory,
        phase: NetworkPhase
    ): NetworkException {
        if (context.isCancellationRequested()) {
            return cancelled(
                category,
                phase,
                cause: Some(error),
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            return deadlineExceeded(
                category,
                phase,
                cause: Some(error),
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        if (isClosed()) {
            return closedError(
                category,
                phase,
                cause: Some(error),
                localEndpoint: localEndpoint,
                remoteEndpoint: remoteEndpoint
            )
        }
        // SocketException exposes no stable native code. Message matching is
        // deliberately forbidden, so fail closed instead of guessing errno.
        NetworkException(
            category,
            phase,
            NetworkErrorCode.SystemFailure,
            "std.net socket operation failed without a public native error code",
            retryability: Retryability.Unknown,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint,
            cause: Some(error)
        )
    }

    private func takeNativeCloseLocked(): Bool {
        if (nativeClosed) {
            false
        } else {
            nativeClosed = true
            true
        }
    }
}

private func configureAbortiveClose(socket: TcpSocket): Unit {
    unsafe {
        let value = LibC.malloc<AbortiveLinger>()
        if (value.isNull()) {
            throw IllegalMemoryException("failed to allocate SO_LINGER value")
        }
        try {
            value.write(AbortiveLinger())
            socket.setSocketOption(
                OptionLevel.SOCKET,
                OptionName.SO_LINGER,
                CPointer(value),
                AbortiveLinger.size
            )
        } finally {
            LibC.free(value)
        }
    }
}

/** Linux TCP listener using the public std.net accept timeout/close surface. */
public class StdNetTransportListener <: TransportListener {
    private static let ACCEPT_WAIT_QUANTUM = 20 * Duration.millisecond
    private let server: TcpServerSocket
    private let stagingBufferSize: Int64
    private let mutex = Mutex()
    private var closed = false
    private let activeAccepts = AtomicInt64(0)
    public let localEndpoint: SocketEndpoint

    private init(server: TcpServerSocket, localEndpoint: SocketEndpoint, stagingBufferSize: Int64) {
        this.server = server
        this.localEndpoint = localEndpoint
        this.stagingBufferSize = stagingBufferSize
    }

    public static func bind(
        endpoint: SocketEndpoint,
        backlog!: Int64 = 128,
        stagingBufferSize!: Int64 = DEFAULT_STAGING_BUFFER_SIZE
    ): StdNetTransportListener {
        if (backlog <= 0 || backlog > MAX_LISTENER_BACKLOG) {
            throw IllegalArgumentException("listener backlog must be between 1 and 65535")
        }
        if (stagingBufferSize <= 0) {
            throw IllegalArgumentException("stagingBufferSize must be positive")
        }
        let server = TcpServerSocket(bindAt: toStdEndpoint(endpoint))
        try {
            server.backlogSize = backlog
            server.bind()
            StdNetTransportListener(server, fromStdEndpoint(server.localAddress), stagingBufferSize)
        } catch (error: Exception) {
            server.close()
            throw error
        }
    }

    public func accept(
        context: OperationContext
    ): DuplexTransport {
        checkContext(
            context,
            NetworkErrorCategory.Accept,
            NetworkPhase.ServerAccept,
            localEndpoint: Some(localEndpoint)
        )
        if (isClosed()) {
            throw closedError(
                NetworkErrorCategory.Accept,
                NetworkPhase.ServerAccept,
                localEndpoint: Some(localEndpoint)
            )
        }
        beginAccept()
        try {
            while (true) {
                checkContext(
                    context,
                    NetworkErrorCategory.Accept,
                    NetworkPhase.ServerAccept,
                    localEndpoint: Some(localEndpoint)
                )
                try {
                    let accepted = server.accept(timeout: acceptWait(context))
                    try {
                        checkContext(
                            context,
                            NetworkErrorCategory.Accept,
                            NetworkPhase.ServerAccept,
                            localEndpoint: Some(localEndpoint)
                        )
                        return StdNetTransport.fromAccepted(
                            accepted,
                            stagingBufferSize: stagingBufferSize
                        )
                    } catch (error: Exception) {
                        accepted.close()
                        throw error
                    }
                } catch (_: SocketTimeoutException) {
                    // The quantum only wakes the adapter to observe the one
                    // canonical OperationContext; it is not a second deadline.
                    continue
                } catch (error: SocketException) {
                    if (context.isCancellationRequested()) {
                        throw cancelled(
                            NetworkErrorCategory.Accept,
                            NetworkPhase.ServerAccept,
                            cause: Some(error),
                            localEndpoint: Some(localEndpoint)
                        )
                    }
                    if (context.isDeadlineExceeded()) {
                        throw deadlineExceeded(
                            NetworkErrorCategory.Accept,
                            NetworkPhase.ServerAccept,
                            cause: Some(error),
                            localEndpoint: Some(localEndpoint)
                        )
                    }
                    if (isClosed()) {
                        throw closedError(
                            NetworkErrorCategory.Accept,
                            NetworkPhase.ServerAccept,
                            cause: Some(error),
                            localEndpoint: Some(localEndpoint)
                        )
                    }
                    throw NetworkException(
                        NetworkErrorCategory.Accept,
                        NetworkPhase.ServerAccept,
                        NetworkErrorCode.SystemFailure,
                        "std.net accept failed without a public native error code",
                        retryability: Retryability.Unknown,
                        localEndpoint: Some(localEndpoint),
                        cause: Some(error)
                    )
                }
            }
            throw IllegalStateException("unreachable std.net accept loop exit")
        } finally {
            endAccept()
        }
    }

    public func accept(): DuplexTransport {
        accept(OperationContext.background())
    }

    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            if (closed) {
                false
            } else {
                closed = true
                true
            }
        }
        if (shouldClose) {
            server.close()
        }
    }

    public func isClosed(): Bool {
        synchronized(mutex) { closed }
    }

    /** Waits for an active accept for deterministic lifecycle and race tests. */
    func waitUntilAcceptActive(timeout: Duration): Bool {
        let expiresAt = MonoTime.now() + timeout
        while (activeAccepts.load() == 0 && !isClosed()) {
            if (MonoTime.now() >= expiresAt) {
                return false
            }
            sleep(Duration.millisecond)
        }
        activeAccepts.load() > 0
    }

    private func beginAccept(): Unit {
        if (isClosed()) {
            throw closedError(
                NetworkErrorCategory.Accept,
                NetworkPhase.ServerAccept,
                localEndpoint: Some(localEndpoint)
            )
        }
        activeAccepts.fetchAdd(1)
    }

    private func endAccept(): Unit {
        activeAccepts.fetchSub(1)
    }

    private func acceptWait(context: OperationContext): ?Duration {
        match (context.deadline) {
            case Some(value) => Some(min(value.remaining(), ACCEPT_WAIT_QUANTUM))
            case None => Some(ACCEPT_WAIT_QUANTUM)
        }
    }
}

private class OperationGate {
    private let active = AtomicBool(true)

    func complete(): Bool {
        active.compareAndSwap(true, false)
    }

    func interrupt(action: () -> Unit): Unit {
        if (active.compareAndSwap(true, false)) {
            action()
        }
    }
}

private func remaining(context: OperationContext): ?Duration {
    match (context.deadline) {
        case Some(deadline) => Some(deadline.remaining())
        case None => None<Duration>
    }
}

private func isBackgroundContext(context: OperationContext): Bool {
    context.deadline.isNone() &&
        context.cancellation.permanentlyActive &&
        context.trace.isNone() &&
        context.eventSink.isNone()
}

private func checkContext(
    context: OperationContext,
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
    remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>
): Unit {
    if (context.isCancellationRequested()) {
        throw cancelled(
            category,
            phase,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        )
    }
    if (context.isDeadlineExceeded()) {
        throw deadlineExceeded(
            category,
            phase,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        )
    }
}

private func toStdEndpoint(endpoint: SocketEndpoint): IPSocketAddress {
    let octets = endpoint.address.toOctets()
    match (endpoint.address.family) {
        case IpAddressFamily.Ipv4 => IPSocketAddress(IPv4Address(octets[0], octets[1], octets[2], octets[3]), endpoint.port)
        case IpAddressFamily.Ipv6 =>
            let scope = match (endpoint.address.zone) {
                case Some(zone) =>
                    match (UInt32.tryParse(zone)) {
                        case Some(value) => Some(value)
                        case None => throw NetworkException(
                            NetworkErrorCategory.Unsupported,
                            NetworkPhase.AddressSelection,
                            NetworkErrorCode.Unsupported,
                            "std.net accepts numeric IPv6 scope IDs; interface-name zones require an upstream mapping API",
                            retryability: Retryability.Never,
                            remoteEndpoint: Some(endpoint)
                        )
                    }
                case None => None<UInt32>
            }
            IPSocketAddress(IPv6Address(octets, scopeId: scope), endpoint.port)
    }
}

private func fromStdEndpoint(address: SocketAddress): SocketEndpoint {
    match (address) {
        case endpoint: IPSocketAddress =>
            let ip = endpoint.address
            if (ip.isIPv4()) {
                SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, ip.getAddressBytes()), endpoint.port)
            } else {
                let zone = match (ip) {
                    case v6: IPv6Address =>
                        match (v6.scopeId) {
                            case Some(value) => Some(value.toString())
                            case None => None<String>
                        }
                    case _ => None<String>
                }
                SocketEndpoint(IpAddress(IpAddressFamily.Ipv6, ip.getAddressBytes(), zone: zone), endpoint.port)
            }
        case _ => throw NetworkException(
            NetworkErrorCategory.Address,
            NetworkPhase.AddressSelection,
            NetworkErrorCode.Unsupported,
            "std.net returned a non-IP socket address",
            retryability: Retryability.Never
        )
    }
}

private func concurrent(category: NetworkErrorCategory, phase: NetworkPhase): NetworkException {
    NetworkException(category, phase, NetworkErrorCode.ConcurrentOperation, "same-direction operation already active")
}

private func cancelled(
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    cause!: ?Exception = None<Exception>,
    localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
    remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.Cancelled,
        "operation cancelled",
        retryability: Retryability.Never,
        localEndpoint: localEndpoint,
        remoteEndpoint: remoteEndpoint,
        cause: cause
    )
}

private func deadlineExceeded(
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    cause!: ?Exception = None<Exception>,
    localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
    remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.TimedOut,
        "operation deadline exceeded",
        retryability: Retryability.Temporary,
        localEndpoint: localEndpoint,
        remoteEndpoint: remoteEndpoint,
        cause: cause
    )
}

private func timedOut(
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    cause: Exception,
    localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
    remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.TimedOut,
        "std.net operation timed out",
        retryability: Retryability.Temporary,
        localEndpoint: localEndpoint,
        remoteEndpoint: remoteEndpoint,
        cause: Some(cause)
    )
}

/** A write timeout cannot prove that the kernel committed zero bytes. */
internal func writeTimedOut(
    cause: Exception,
    localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
    remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>
): NetworkException {
    NetworkException(
        NetworkErrorCategory.Write,
        NetworkPhase.TcpWrite,
        NetworkErrorCode.TimedOut,
        "std.net write timed out with unknown physical commit state",
        retryability: Retryability.Never,
        localEndpoint: localEndpoint,
        remoteEndpoint: remoteEndpoint,
        cause: Some(cause)
    )
}

private func closedError(
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    cause!: ?Exception = None<Exception>,
    localEndpoint!: ?SocketEndpoint = None<SocketEndpoint>,
    remoteEndpoint!: ?SocketEndpoint = None<SocketEndpoint>
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.Closed,
        "transport is closed",
        retryability: Retryability.Never,
        localEndpoint: localEndpoint,
        remoteEndpoint: remoteEndpoint,
        cause: cause
    )
}
