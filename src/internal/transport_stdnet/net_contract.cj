package wirestack.internal.transport_stdnet

import std.net.*
import std.sync.*
import std.convert.Parsable
import wirestack as api

/*
 * This file is the only implementation bridge used by wirestack.net.  The
 * public package never imports std.net.  The bridge deliberately exposes only
 * Wirestack values and owns the small amount of polling needed to observe an
 * OperationContext while the pinned SDK is in use.
 */

internal let NET_WAIT_QUANTUM: Duration = 20 * Duration.millisecond
internal let MAX_DATAGRAM_SIZE: Int64 = 65507

public class ContractStreamBackend <: api.DuplexTransport {
    private let socket: StreamingSocket
    private let stagingBufferSize: Int64
    private let mutex = Mutex()
    private var readActive = false
    private var writeActive = false
    private var closed = false
    private var local: ?api.SocketEndpoint
    private var remote: ?api.SocketEndpoint
    private let backendName: String

    private init(
        socket: StreamingSocket,
        backendName: String,
        local!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
        remote!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
        stagingBufferSize!: Int64 = 16 * 1024
    ) {
        if (stagingBufferSize <= 0) {
            throw IllegalArgumentException("stagingBufferSize must be positive")
        }
        this.socket = socket
        this.backendName = backendName
        this.local = local
        this.remote = remote
        this.stagingBufferSize = stagingBufferSize
    }

    public static func connectTcp(
        endpoint: api.SocketEndpoint,
        context: api.OperationContext,
        stagingBufferSize!: Int64 = 16 * 1024
    ): ContractStreamBackend {
        checkNetContext(context, api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
            remote: Some(endpoint))
        // std.net exposes a bounded connect timeout but no readiness handle.
        // Recreate the provisional socket after a quantum timeout and keep
        // charging the same absolute OperationContext. This avoids turning
        // the adapter's wait quantum into a second timeout owner.
        var connected: ?ContractStreamBackend = None<ContractStreamBackend>
        while (connected.isNone()) {
            checkNetContext(context, api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
                remote: Some(endpoint))
            let socket = TcpSocket(netSocketAddress(endpoint))
            try {
                socket.connect(timeout: netRemaining(context, NET_WAIT_QUANTUM))
                let backend = ContractStreamBackend(
                    socket,
                    "std.net.tcp",
                    remote: Some(endpoint),
                    stagingBufferSize: stagingBufferSize
                )
                backend.refreshEndpoints()
                connected = Some(backend)
            } catch (error: SocketTimeoutException) {
                socket.close()
                if (context.isCancellationRequested()) {
                    throw netCancelled(api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
                        remote: Some(endpoint), cause: Some(error))
                }
                if (context.isDeadlineExceeded()) {
                    throw netDeadline(api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
                        remote: Some(endpoint), cause: Some(error))
                }
                // No deadline means a background connect remains pending.
                // A bounded retry is still observable by cancellation/close.
                continue
            } catch (error: SocketException) {
                socket.close()
                throw netSystemError(api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
                    remote: Some(endpoint), cause: Some(error))
            } catch (error: Exception) {
                socket.close()
                throw error
            }
        }
        match (connected) {
            case Some(value) => value
            case None => throw IllegalStateException("connect loop terminated unexpectedly")
        }
    }

    public static func connectUnix(
        address: Array<Byte>,
        abstractName: Bool,
        context: api.OperationContext,
        stagingBufferSize!: Int64 = 16 * 1024
    ): ContractStreamBackend {
        checkNetContext(context, api.NetworkErrorCategory.Connect, api.NetworkPhase.UnixSocket)
        let _ = abstractName
        // UnixSocketAddress(Array<Byte>) preserves Linux abstract names and
        // avoids an accidental UTF-8 conversion of the leading NUL/name bytes.
        let socket: UnixSocket = UnixSocket(UnixSocketAddress(address))
        let backend = ContractStreamBackend(
            socket,
            "std.net.unix",
            stagingBufferSize: stagingBufferSize
        )
        try {
            socket.connect(timeout: netRemaining(context, NET_WAIT_QUANTUM))
            backend.refreshEndpoints()
            backend
        } catch (error: SocketTimeoutException) {
            backend.close(api.OperationContext.background())
            throw netDeadline(api.NetworkErrorCategory.Connect, api.NetworkPhase.UnixSocket,
                cause: Some(error))
        } catch (error: SocketException) {
            backend.close(api.OperationContext.background())
            throw netSystemError(api.NetworkErrorCategory.Connect, api.NetworkPhase.UnixSocket,
                cause: Some(error))
        }
    }

    public static func accepted(socket: StreamingSocket, backendName: String): ContractStreamBackend {
        let backend = ContractStreamBackend(socket, backendName)
        backend.refreshEndpoints()
        backend
    }

    internal func localEndpoint(): ?api.SocketEndpoint { synchronized(mutex) { local } }
    internal func remoteEndpoint(): ?api.SocketEndpoint { synchronized(mutex) { remote } }

    public prop info: api.TransportInfo {
        get() {
            api.TransportInfo(
                backendName,
                runtimeIoBackend: "cjnative",
                localEndpoint: localEndpoint(),
                remoteEndpoint: remoteEndpoint(),
                supportsHalfClose: false,
                supportsAbort: true
            )
        }
    }

    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        beginRead()
        try {
            if (destination.isEmpty()) { return api.ReadResult.Data(0) }
            checkNetContext(context, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                local: localEndpoint(), remote: remoteEndpoint())
            let count = min(destination.length, stagingBufferSize)
            let direct = destination.offset == 0 && destination.length == destination.bytes.size &&
                count == destination.bytes.size
            let target = if (direct) { destination.bytes } else { Array<Byte>(count, repeat: 0) }
            while (true) {
                checkNetContext(context, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                    local: localEndpoint(), remote: remoteEndpoint())
                try {
                    socket.readTimeout = netRemaining(context, NET_WAIT_QUANTUM)
                    let received = socket.read(target)
                    socket.readTimeout = None<Duration>
                    if (received == 0) {
                        checkNetContext(context, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                            local: localEndpoint(), remote: remoteEndpoint())
                        return api.ReadResult.EndOfStream
                    }
                    if (!direct) {
                        for (index in 0..received) {
                            destination.bytes[destination.offset + index] = target[index]
                        }
                    }
                    return api.ReadResult.Data(received)
                } catch (_: SocketTimeoutException) {
                    resetReadTimeout()
                    continue
                } catch (error: SocketException) {
                    resetReadTimeout()
                    if (isClosed()) {
                        throw netClosed(api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                            local: localEndpoint(), remote: remoteEndpoint(), cause: Some(error))
                    }
                    throw netSystemError(api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                        local: localEndpoint(), remote: remoteEndpoint(), cause: Some(error))
                }
            }
            throw IllegalStateException("stream read loop terminated unexpectedly")
        } finally {
            endRead()
        }
    }

    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        beginWrite()
        try {
            if (source.isEmpty()) { return 0 }
            checkNetContext(context, api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                local: localEndpoint(), remote: remoteEndpoint())
            let count = min(source.length, stagingBufferSize)
            let payload = Array<Byte>(count, repeat: 0)
            for (index in 0..count) {
                payload[index] = source.bytes[source.offset + index]
            }
            while (true) {
                checkNetContext(context, api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                    local: localEndpoint(), remote: remoteEndpoint())
                try {
                    socket.writeTimeout = netRemaining(context, NET_WAIT_QUANTUM)
                    socket.write(payload)
                    socket.writeTimeout = None<Duration>
                    return count
                } catch (_: SocketTimeoutException) {
                    resetWriteTimeout()
                    continue
                } catch (error: SocketException) {
                    resetWriteTimeout()
                    if (isClosed()) {
                        throw netClosed(api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                            local: localEndpoint(), remote: remoteEndpoint(), cause: Some(error))
                    }
                    throw netSystemError(api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                        local: localEndpoint(), remote: remoteEndpoint(), cause: Some(error))
                }
            }
            throw IllegalStateException("stream write loop terminated unexpectedly")
        } finally {
            endWrite()
        }
    }

    public func shutdown(direction: api.ShutdownDirection): Unit {
        let _ = direction
        throw api.NetworkException(
            api.NetworkErrorCategory.Unsupported,
            api.NetworkPhase.TransportClose,
            api.NetworkErrorCode.Unsupported,
            "directional shutdown is not available through the pinned public std.net API",
            retryability: api.Retryability.Never,
            localEndpoint: localEndpoint(),
            remoteEndpoint: remoteEndpoint()
        )
    }

    public func close(context: api.OperationContext): Unit {
        let _ = context
        let shouldClose = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (shouldClose) { socket.close() }
    }

    public func close(): Unit { close(api.OperationContext.background()) }

    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        close(api.OperationContext.background())
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func refreshEndpoints(): Unit {
        let localValue = socket.localAddress
        let remoteValue = socket.remoteAddress
        synchronized(mutex) {
            local = netEndpoint(localValue)
            remote = netEndpoint(remoteValue)
        }
    }

    private func beginRead(): Unit {
        synchronized(mutex) {
            if (closed) {
                throw netClosed(api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                    local: local, remote: remote)
            }
            if (readActive) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Read,
                    api.NetworkPhase.TcpRead,
                    api.NetworkErrorCode.ConcurrentOperation,
                    "same-direction read is already active",
                    retryability: api.Retryability.Never,
                    localEndpoint: local,
                    remoteEndpoint: remote
                )
            }
            readActive = true
        }
    }

    private func endRead(): Unit { synchronized(mutex) { readActive = false } }
    private func beginWrite(): Unit {
        synchronized(mutex) {
            if (closed) {
                throw netClosed(api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                    local: local, remote: remote)
            }
            if (writeActive) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.TcpWrite,
                    api.NetworkErrorCode.ConcurrentOperation,
                    "same-direction write is already active",
                    retryability: api.Retryability.Never,
                    localEndpoint: local,
                    remoteEndpoint: remote
                )
            }
            writeActive = true
        }
    }
    private func endWrite(): Unit { synchronized(mutex) { writeActive = false } }

    private func resetReadTimeout(): Unit {
        try {
            socket.readTimeout = None<Duration>
        } catch (_: Exception) {
            // A concurrent close can make timeout reset unavailable. The
            // closed socket is already terminal and cannot be reused.
        }
    }

    private func resetWriteTimeout(): Unit {
        try {
            socket.writeTimeout = None<Duration>
        } catch (_: Exception) {
            // A concurrent close can make timeout reset unavailable. The
            // closed socket is already terminal and cannot be reused.
        }
    }
}

public class ContractStreamListener <: Resource {
    private let server: ServerSocket
    private let backendName: String
    private let mutex = Mutex()
    private var closed = false
    private let endpoint: ?api.SocketEndpoint

    private init(server: ServerSocket, backendName: String, endpoint: ?api.SocketEndpoint) {
        this.server = server
        this.backendName = backendName
        this.endpoint = endpoint
    }

    public static func bindTcp(endpoint: api.SocketEndpoint, backlog: Int64): ContractStreamListener {
        if (backlog <= 0 || backlog > 65535) {
            throw IllegalArgumentException("backlog must be between 1 and 65535")
        }
        let server = TcpServerSocket(bindAt: netSocketAddress(endpoint))
        try {
            server.backlogSize = backlog
            server.bind()
            ContractStreamListener(server, "std.net.tcp-listener", netEndpoint(server.localAddress))
        } catch (error: Exception) {
            server.close()
            throw error
        }
    }

    public static func bindUnix(path: Array<Byte>, abstractName: Bool, backlog: Int64): ContractStreamListener {
        if (backlog <= 0 || backlog > 65535) {
            throw IllegalArgumentException("backlog must be between 1 and 65535")
        }
        let server: UnixServerSocket = if (abstractName) {
            UnixServerSocket(bindAt: UnixSocketAddress(path))
        } else {
            UnixServerSocket(bindAt: String.fromUtf8(path))
        }
        try {
            server.backlogSize = backlog
            server.bind()
            ContractStreamListener(server, "std.net.unix-listener", None<api.SocketEndpoint>)
        } catch (error: Exception) {
            server.close()
            throw error
        }
    }

    public func accept(context: api.OperationContext): ContractStreamBackend {
        checkNetContext(context, api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
            local: endpoint)
        synchronized(mutex) {
            if (closed) {
                throw netClosed(api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
                    local: endpoint)
            }
        }
        while (true) {
            checkNetContext(context, api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
                local: endpoint)
            try {
                let accepted = server.accept(timeout: netRemaining(context, NET_WAIT_QUANTUM))
                return ContractStreamBackend.accepted(accepted, backendName)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (error: SocketException) {
                if (isClosed()) {
                    throw netClosed(api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
                        local: endpoint, cause: Some(error))
                }
                throw netSystemError(api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
                    local: endpoint, cause: Some(error))
            }
        }
        throw IllegalStateException("listener accept loop terminated unexpectedly")
    }

    public func localEndpoint(): ?api.SocketEndpoint { endpoint }
    /** Explicit alias used by public facades to avoid Resource overload ambiguity. */
    public func stop(): Unit { close() }
    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (shouldClose) { server.close() }
    }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

public class ContractDatagramBackend {
    private let socket: DatagramSocket
    private let mutex = Mutex()
    private var closed = false
    private var receiveActive = false
    private var sendActive = false
    private var local: ?api.SocketEndpoint
    private var remote: ?api.SocketEndpoint

    private init(socket: DatagramSocket, local!: ?api.SocketEndpoint = None<api.SocketEndpoint>) {
        this.socket = socket
        this.local = local
        this.remote = None<api.SocketEndpoint>
    }

    public static func bind(endpoint: ?api.SocketEndpoint): ContractDatagramBackend {
        let socket: UdpSocket = match (endpoint) {
            case Some(value) => UdpSocket(bindAt: netSocketAddress(value))
            case None => UdpSocket(bindAt: UInt16(0))
        }
        try {
            socket.bind()
            ContractDatagramBackend(socket, local: netEndpoint(socket.localAddress))
        } catch (error: Exception) {
            socket.close()
            throw error
        }
    }

    public static func bindUnix(path: Array<Byte>, abstractName: Bool): ContractDatagramBackend {
        let socket: UnixDatagramSocket = if (abstractName) {
            UnixDatagramSocket(bindAt: UnixSocketAddress(path))
        } else {
            UnixDatagramSocket(bindAt: String.fromUtf8(path))
        }
        try {
            socket.bind()
            ContractDatagramBackend(socket)
        } catch (error: Exception) {
            socket.close()
            throw error
        }
    }

    public func connect(endpoint: api.SocketEndpoint, context: api.OperationContext): Unit {
        checkNetContext(context, api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
            remote: Some(endpoint))
        synchronized(mutex) { remote = Some(endpoint) }
    }

    public func localEndpoint(): ?api.SocketEndpoint { synchronized(mutex) { local } }
    public func remoteEndpoint(): ?api.SocketEndpoint { synchronized(mutex) { remote } }

    public func send(endpoint: ?api.SocketEndpoint, payload: api.ByteSpan,
        context: api.OperationContext): Int64 {
        beginSend()
        try {
            if (payload.length > MAX_DATAGRAM_SIZE) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.ResourceExhausted,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.MessageTooLarge,
                    "datagram exceeds the 65507-byte IPv4 payload limit",
                    retryability: api.Retryability.Never,
                    localEndpoint: localEndpoint(),
                    remoteEndpoint: endpoint
                )
            }
            checkNetContext(context, api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                local: localEndpoint(), remote: endpoint)
            let data = Array<Byte>(payload.length, repeat: 0)
            for (index in 0..payload.length) {
                data[index] = payload.bytes[payload.offset + index]
            }
            try {
                socket.sendTimeout = netRemaining(context, NET_WAIT_QUANTUM)
                match (endpoint) {
                    case Some(value) => socket.sendTo(netSocketAddress(value), data)
                    case None => throw api.NetworkException(
                        api.NetworkErrorCategory.Connect,
                        api.NetworkPhase.DatagramSend,
                        api.NetworkErrorCode.NotConnected,
                        "datagram socket is not connected",
                        retryability: api.Retryability.Never)
                }
                socket.sendTimeout = None<Duration>
                payload.length
            } catch (error: SocketTimeoutException) {
                socket.sendTimeout = None<Duration>
                if (context.isCancellationRequested()) {
                    throw netCancelled(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                        local: localEndpoint(), remote: endpoint, cause: Some(error))
                }
                throw netDeadline(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                    local: localEndpoint(), remote: endpoint, cause: Some(error))
            } catch (error: SocketException) {
                socket.sendTimeout = None<Duration>
                throw netSystemError(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                    local: localEndpoint(), remote: endpoint, cause: Some(error))
            }
        } finally {
            endSend()
        }
    }

    /** Sends one Unix datagram through the public SocketAddress overload. */
    public func sendUnix(path: Array<Byte>, payload: api.ByteSpan,
        context: api.OperationContext): Int64 {
        beginSend()
        try {
            if (payload.length > MAX_DATAGRAM_SIZE) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.ResourceExhausted,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.MessageTooLarge,
                    "datagram exceeds the bounded payload limit",
                    retryability: api.Retryability.Never
                )
            }
            checkNetContext(context, api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend)
            let data = Array<Byte>(payload.length, repeat: 0)
            for (index in 0..payload.length) {
                data[index] = payload.bytes[payload.offset + index]
            }
            try {
                socket.sendTimeout = netRemaining(context, NET_WAIT_QUANTUM)
                socket.sendTo(UnixSocketAddress(path), data)
                socket.sendTimeout = None<Duration>
                payload.length
            } catch (error: SocketTimeoutException) {
                resetSendTimeout()
                if (context.isCancellationRequested()) {
                    throw netCancelled(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                        cause: Some(error))
                }
                throw netDeadline(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                    cause: Some(error))
            } catch (error: SocketException) {
                resetSendTimeout()
                throw netSystemError(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                    cause: Some(error))
            }
        } finally {
            endSend()
        }
    }

    public func receive(capacity: Int64, context: api.OperationContext): (Array<Byte>, ?api.SocketEndpoint, Bool) {
        if (capacity <= 0 || capacity > MAX_DATAGRAM_SIZE) {
            throw IllegalArgumentException("datagram receive capacity must be between 1 and 65507")
        }
        beginReceive()
        try {
            // Read one sentinel byte beyond the caller capacity. std.net's
            // receiveFrom reports only the copied count, so count > capacity
            // is the only portable way to distinguish an exact-size datagram
            // from a truncated one without exposing a native message header.
            let buffer = Array<Byte>(capacity + 1, repeat: 0)
            while (true) {
                checkNetContext(context, api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive,
                    local: localEndpoint())
                try {
                    socket.receiveTimeout = netRemaining(context, NET_WAIT_QUANTUM)
                    let (address, count) = socket.receiveFrom(buffer)
                    socket.receiveTimeout = None<Duration>
                    let copied = min(count, capacity)
                    let payload = Array<Byte>(copied, repeat: 0)
                    for (index in 0..copied) { payload[index] = buffer[index] }
                    return (payload, netEndpoint(address), count > capacity)
                } catch (_: SocketTimeoutException) {
                    socket.receiveTimeout = None<Duration>
                    continue
                } catch (error: SocketException) {
                    socket.receiveTimeout = None<Duration>
                    if (isClosed()) {
                        throw netClosed(api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive,
                            local: localEndpoint(), cause: Some(error))
                    }
                    throw netSystemError(api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive,
                        local: localEndpoint(), cause: Some(error))
                }
            }
            throw IllegalStateException("datagram receive loop terminated unexpectedly")
        } finally {
            endReceive()
        }
    }

    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (shouldClose) { socket.close() }
    }
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func beginReceive(): Unit {
        synchronized(mutex) {
            if (closed) { throw netClosed(api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive) }
            if (receiveActive) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive,
                    api.NetworkErrorCode.ConcurrentOperation, "same-direction receive is already active",
                    retryability: api.Retryability.Never)
            }
            receiveActive = true
        }
    }
    private func endReceive(): Unit { synchronized(mutex) { receiveActive = false } }
    private func beginSend(): Unit {
        synchronized(mutex) {
            if (closed) { throw netClosed(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend) }
            if (sendActive) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.ConcurrentOperation, "same-direction send is already active",
                    retryability: api.Retryability.Never)
            }
            sendActive = true
        }
    }
    private func endSend(): Unit { synchronized(mutex) { sendActive = false } }

    private func resetSendTimeout(): Unit {
        try {
            socket.sendTimeout = None<Duration>
        } catch (_: Exception) {
            // A concurrent close makes timeout reset unnecessary.
        }
    }
}

internal func netSocketAddress(endpoint: api.SocketEndpoint): IPSocketAddress {
    let bytes = endpoint.address.toOctets()
    match (endpoint.address.family) {
        case api.IpAddressFamily.Ipv4 => IPSocketAddress(
            IPv4Address(bytes[0], bytes[1], bytes[2], bytes[3]), endpoint.port)
        case api.IpAddressFamily.Ipv6 =>
            let scope = match (endpoint.address.zone) {
                case Some(value) =>
                    match (UInt32.tryParse(value)) {
                        case Some(parsed) => Some(parsed)
                        case None => throw IllegalArgumentException("IPv6 zone must be numeric for std.net")
                    }
                case None => None<UInt32>
            }
            IPSocketAddress(IPv6Address(bytes, scopeId: scope), endpoint.port)
    }
}

internal func netEndpoint(address: SocketAddress): ?api.SocketEndpoint {
    match (address) {
        case value: IPSocketAddress =>
            let family = if (value.isIPv4()) { api.IpAddressFamily.Ipv4 } else { api.IpAddressFamily.Ipv6 }
            let zone = match (value.address) {
                case v6: IPv6Address => match (v6.scopeId) {
                    case Some(scope) => Some(scope.toString())
                    case None => None<String>
                }
                case _ => None<String>
            }
            Some(api.SocketEndpoint(api.IpAddress(family, value.address.getAddressBytes(), zone: zone), value.port))
        case _ => None<api.SocketEndpoint>
    }
}

internal func netRemaining(context: api.OperationContext, quantum: Duration): ?Duration {
    match (context.deadline) {
        case Some(deadline) => Some(min(deadline.remaining(), quantum))
        case None => Some(quantum)
    }
}

internal func checkNetContext(
    context: api.OperationContext,
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase,
    local!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    remote!: ?api.SocketEndpoint = None<api.SocketEndpoint>
): Unit {
    if (context.isCancellationRequested()) {
        throw netCancelled(category, phase, local: local, remote: remote)
    }
    if (context.isDeadlineExceeded()) {
        throw netDeadline(category, phase, local: local, remote: remote)
    }
}

internal func netCancelled(
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase,
    local!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    remote!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    cause!: ?Exception = None<Exception>
): api.NetworkException {
    api.NetworkException(category, phase, api.NetworkErrorCode.Cancelled, "operation cancelled",
        retryability: api.Retryability.Never, localEndpoint: local, remoteEndpoint: remote, cause: cause)
}

internal func netDeadline(
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase,
    local!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    remote!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    cause!: ?Exception = None<Exception>
): api.NetworkException {
    api.NetworkException(category, phase, api.NetworkErrorCode.TimedOut, "operation deadline exceeded",
        retryability: api.Retryability.Temporary, localEndpoint: local, remoteEndpoint: remote, cause: cause)
}

internal func netClosed(
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase,
    local!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    remote!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    cause!: ?Exception = None<Exception>
): api.NetworkException {
    api.NetworkException(category, phase, api.NetworkErrorCode.Closed, "socket is closed",
        retryability: api.Retryability.Never, localEndpoint: local, remoteEndpoint: remote, cause: cause)
}

internal func netSystemError(
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase,
    local!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    remote!: ?api.SocketEndpoint = None<api.SocketEndpoint>,
    cause!: ?Exception = None<Exception>
): api.NetworkException {
    api.NetworkException(category, phase, api.NetworkErrorCode.SystemFailure,
        "socket operation failed without a stable public native code",
        retryability: api.Retryability.Unknown, localEndpoint: local, remoteEndpoint: remote, cause: cause)
}
