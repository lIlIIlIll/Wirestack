package wirestack.internal.transport_stdnet

import std.net.*
import std.sync.*
import wirestack as api

/**
 * Unix listener backed only by public std.net APIs.
 *
 * A single native accept worker is retained across operation-local cancellation,
 * so cancellation wakes the caller without closing the listener or creating an
 * unbounded set of blocked accepts. A connection completed after its waiter has
 * left is closed instead of escaping without an owner.
 */
public class StdNetUnixTransportListener <: Resource {
    private let server: UnixServerSocket
    private let stagingBufferSize: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var closed = false
    private var nativeClosed = false
    private var nativeAcceptActive = false
    private var waiterActive = false
    private var acceptedSocket: ?UnixSocket = None<UnixSocket>
    private var acceptFailure: ?Exception = None<Exception>
    public let localEndpoint: api.UnixEndpoint

    private init(
        server: UnixServerSocket,
        localEndpoint: api.UnixEndpoint,
        stagingBufferSize: Int64
    ) {
        this.server = server
        this.localEndpoint = localEndpoint
        this.stagingBufferSize = stagingBufferSize
    }

    /** Binds a named Unix endpoint. Pathname nodes remain caller-owned after close. */
    public static func bind(
        endpoint: api.UnixEndpoint,
        backlog!: Int64 = 128,
        stagingBufferSize!: Int64 = 16 * 1024
    ): StdNetUnixTransportListener {
        if (backlog <= 0 || backlog > 65535) {
            throw IllegalArgumentException("listener backlog must be between 1 and 65535")
        }
        if (stagingBufferSize <= 0) {
            throw IllegalArgumentException("stagingBufferSize must be positive")
        }
        let server = UnixServerSocket(bindAt: toStdUnixEndpoint(endpoint, local: true))
        try {
            server.backlogSize = backlog
            server.bind()
            StdNetUnixTransportListener(
                server,
                fromStdUnixEndpoint(server.localAddress),
                stagingBufferSize
            )
        } catch (error: Exception) {
            server.close()
            throw error
        }
    }

    /**
     * Accepts one stream. Cancellation and deadline expiry end only this waiter;
     * the listener and its one bounded native accept worker remain reusable.
     */
    public func accept(context: api.OperationContext): SocketTransport {
        let local = Some(api.NetworkEndpoint.Unix(localEndpoint))
        checkNetworkContext(context, api.NetworkErrorCategory.Accept,
            api.NetworkPhase.ServerAccept, localEndpoint: local)
        let cancellationObserved = AtomicBool(false)
        let registration = context.cancellation.register {
            =>
            cancellationObserved.store(true)
            wakeWaiter()
        }
        var ownsWaiter = false
        var cleanupSocket: ?UnixSocket = None<UnixSocket>
        try {
            let startWorker = synchronized(mutex) {
                if (closed) {
                    throw networkClosedError(api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept, localEndpoint: local)
                }
                if (waiterActive) {
                    throw networkConcurrent(api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept, localEndpoint: local)
                }
                waiterActive = true
                ownsWaiter = true
                if (nativeAcceptActive) {
                    false
                } else {
                    nativeAcceptActive = true
                    true
                }
            }
            if (startWorker) {
                try {
                    spawn { runNativeAccept() }
                } catch (error: Exception) {
                    synchronized(mutex) {
                        nativeAcceptActive = false
                        changed.notifyAll()
                    }
                    throw error
                }
            }

            var deadlineExpired = false
            while (true) {
                if (cancellationObserved.load()) { break }
                if (context.isDeadlineExceeded()) {
                    deadlineExpired = true
                    break
                }
                let waitFor = match (context.deadline) {
                    case Some(deadline) =>
                        let value = deadline.remaining()
                        if (value <= Duration.Zero) {
                            deadlineExpired = true
                            None<Duration>
                        } else {
                            Some(value)
                        }
                    case None => None<Duration>
                }
                if (deadlineExpired) { break }
                let ready = synchronized(mutex) {
                    if (acceptedSocket.isSome() || acceptFailure.isSome() || closed ||
                        cancellationObserved.load()) {
                        true
                    } else {
                        match (waitFor) {
                            case Some(value) => changed.wait(timeout: value)
                            case None => changed.wait()
                        }
                        false
                    }
                }
                if (ready) { break }
            }
            if (!deadlineExpired) {
                deadlineExpired = context.isDeadlineExceeded()
            }

            var accepted: ?UnixSocket = None<UnixSocket>
            var discarded: ?UnixSocket = None<UnixSocket>
            var failure: ?Exception = None<Exception>
            var terminal: ?api.NetworkException = None<api.NetworkException>
            synchronized(mutex) {
                if (cancellationObserved.load()) {
                    discarded = acceptedSocket
                    acceptedSocket = None<UnixSocket>
                    acceptFailure = None<Exception>
                    terminal = Some(networkCancelled(api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept, localEndpoint: local))
                } else if (deadlineExpired) {
                    discarded = acceptedSocket
                    acceptedSocket = None<UnixSocket>
                    acceptFailure = None<Exception>
                    terminal = Some(networkDeadlineExceeded(api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept, localEndpoint: local))
                } else if (closed) {
                    discarded = acceptedSocket
                    acceptedSocket = None<UnixSocket>
                    acceptFailure = None<Exception>
                    terminal = Some(networkClosedError(api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept, localEndpoint: local))
                } else {
                    accepted = acceptedSocket
                    acceptedSocket = None<UnixSocket>
                    failure = acceptFailure
                    acceptFailure = None<Exception>
                }
            }
            match (discarded) {
                case Some(socket) => try { socket.close() } catch (_: Exception) {}
                case None => ()
            }
            match (terminal) {
                case Some(error) => throw error
                case None => ()
            }
            match (failure) {
                case Some(error) => throw mapAcceptFailure(error, context)
                case None => ()
            }
            let socket = accepted.getOrThrow()
            try {
                checkNetworkContext(context, api.NetworkErrorCategory.Accept,
                    api.NetworkPhase.ServerAccept, localEndpoint: local)
                StdNetTransport.fromAcceptedUnix(socket,
                    stagingBufferSize: stagingBufferSize)
            } catch (error: Exception) {
                socket.close()
                throw error
            }
        } finally {
            registration.unregister()
            if (ownsWaiter) {
                cleanupSocket = synchronized(mutex) {
                    waiterActive = false
                    let pending = acceptedSocket
                    acceptedSocket = None<UnixSocket>
                    acceptFailure = None<Exception>
                    changed.notifyAll()
                    pending
                }
                match (cleanupSocket) {
                    case Some(socket) => try { socket.close() } catch (_: Exception) {}
                    case None => ()
                }
            }
        }
    }

    /** Closes once, wakes the waiter, and disposes any completed late accept. */
    public func close(): Unit {
        var pending: ?UnixSocket = None<UnixSocket>
        let shouldClose = synchronized(mutex) {
            if (closed) {
                false
            } else {
                closed = true
                pending = acceptedSocket
                acceptedSocket = None<UnixSocket>
                changed.notifyAll()
                takeNativeCloseLocked()
            }
        }
        match (pending) {
            case Some(socket) => try { socket.close() } catch (_: Exception) {}
            case None => ()
        }
        if (shouldClose) { server.close() }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func runNativeAccept(): Unit {
        try {
            let socket = server.accept()
            let dispose = synchronized(mutex) {
                nativeAcceptActive = false
                if (closed || !waiterActive) {
                    true
                } else {
                    acceptedSocket = Some(socket)
                    changed.notifyAll()
                    false
                }
            }
            if (dispose) {
                try { socket.close() } catch (_: Exception) {}
            }
        } catch (error: Exception) {
            synchronized(mutex) {
                nativeAcceptActive = false
                if (!closed && waiterActive) {
                    acceptFailure = Some(error)
                }
                changed.notifyAll()
            }
        }
    }

    private func mapAcceptFailure(
        error: Exception,
        context: api.OperationContext
    ): api.NetworkException {
        let local = Some(api.NetworkEndpoint.Unix(localEndpoint))
        if (context.isCancellationRequested()) {
            return networkCancelled(api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, cause: Some(error), localEndpoint: local)
        }
        if (context.isDeadlineExceeded()) {
            return networkDeadlineExceeded(api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, cause: Some(error), localEndpoint: local)
        }
        if (isClosed()) {
            return networkClosedError(api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, cause: Some(error), localEndpoint: local)
        }
        api.NetworkException(api.NetworkErrorCategory.Accept,
            api.NetworkPhase.ServerAccept, api.NetworkErrorCode.SystemFailure,
            "std.net Unix accept failed without a public native error code",
            retryability: api.Retryability.Unknown, localEndpoint: local,
            cause: Some(error))
    }

    private func wakeWaiter(): Unit {
        synchronized(mutex) { changed.notifyAll() }
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
