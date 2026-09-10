package wirestack.net

import std.sync.*
import wirestack as api
import wirestack.internal.transport_stdnet as stdnet
import wirestack.NetworkEndpoint


/** Socket lifecycle states observable through Wirestack-owned types. */
public enum SocketState {
/** Socket object has been created. */
    | Created
/** Connect is in progress. */
    | Connecting
/** Listener is accepting connections. */
    | Listening
/** Socket is open. */
    | Open
/** Socket read direction has been shut down successfully. */
    | ReadHalfClosed
/** Socket write direction has been shut down successfully. */
    | WriteHalfClosed
/** Close has started. */
    | Closing
/** Socket is closed after graceful completion. */
    | Closed
/** Socket was terminated after abort won native close ownership. */
    | Aborted
/** Socket was terminated by an operation or close failure. */
    | Failed
}

/** Advisory capabilities. The operation remains authoritative. */
public struct SocketCapabilities {
/** Whether the descriptor is non-blocking. */
    public let nonBlocking: Bool
/** Whether the descriptor is close-on-exec. */
    public let closeOnExec: Bool
/** Whether directional half-close is available. */
    public let halfClose: Bool
/** Whether broadcast is available. */
    public let broadcast: Bool
/** Whether multicast is available. */
    public let multicast: Bool
/** Whether raw socket operations are available. */
    public let raw: Bool
/** Whether ancillary data is available. */
    public let ancillaryData: Bool
/** Whether this backend can send a zero-length datagram. Empty datagram reception is independent. */
    public let zeroLengthDatagramSend: Bool

    /** Creates an advisory capability value.
     *
     * @param ancillaryData Ancillary-data capability.
     * @param broadcast Broadcast capability.
     * @param closeOnExec Close-on-exec capability.
     * @param halfClose Half-close capability.
     * @param multicast Multicast capability.
     * @param nonBlocking Non-blocking capability.
     * @param raw Raw-socket capability.
     * @param zeroLengthDatagramSend Whether the backend supports empty datagram sends.
     */
    public init(
        nonBlocking!: Bool = true,
        closeOnExec!: Bool = true,
        halfClose!: Bool = false,
        broadcast!: Bool = true,
        multicast!: Bool = true,
        raw!: Bool = false,
        ancillaryData!: Bool = false,
        zeroLengthDatagramSend!: Bool = false
    ) {
        this.nonBlocking = nonBlocking
        this.closeOnExec = closeOnExec
        this.halfClose = halfClose
        this.broadcast = broadcast
        this.multicast = multicast
        this.raw = raw
        this.ancillaryData = ancillaryData
        this.zeroLengthDatagramSend = zeroLengthDatagramSend
    }
}

/** Typed socket-option values. M8-001 does not expose an option application operation. */
public enum SocketOption {
/** Enables address reuse. */
    | ReuseAddress(Bool)
/** Enables port reuse. */
    | ReusePort(Bool)
/** Enables TCP no-delay. */
    | NoDelay(Bool)
/** Enables keep-alive probes. */
    | KeepAlive(Bool)
/** Enables datagram broadcast. */
    | Broadcast(Bool)
/** Requests a receive buffer size. */
    | ReceiveBuffer(Int64)
/** Requests a send buffer size. */
    | SendBuffer(Int64)
/** Sets the multicast TTL. */
    | MulticastTtl(UInt8)
}

/** A bounded opaque option value for a future capability adapter. Constructing it does not apply it. */
public struct UnsafeSocketOption {
/** Native option level number. */
    public let level: Int32
/** Native option number. */
    public let option: Int32
    private let bytes: Array<Byte>

    /** Creates a bounded opaque option payload.
     *
     * @param level Native option level number.
     * @param option Native option number.
     * @param value Option payload bytes.
     */
    public init(level: Int32, option: Int32, value: api.ByteSpan) {
        if (level < 0 || option < 0 || value.length > 4096) {
            throw IllegalArgumentException("unsafe socket option is outside the bounded range")
        }
        let copy = Array<Byte>(value.length, repeat: 0)
        for (index in 0..value.length) { copy[index] = value.bytes[value.offset + index] }
        this.level = level
        this.option = option
        this.bytes = copy
    }

    /** Returns a defensive copy of the option payload. */
    public func value(): Array<Byte> { bytes.clone() }
}

/** A datagram result that preserves message boundaries and reports truncation. */
public struct DatagramReceiveResult {
/** Received datagram bytes. */
    public let payload: Array<Byte>
/** Source endpoint when one is available. */
    public let source: ?NetworkEndpoint
/** Whether the incoming datagram exceeded the receive capacity. */
    public let truncated: Bool

    /** Creates an owned result, including valid zero-length datagrams.
     *
     * @param payload Received bytes, bounded to 65,507 bytes.
     * @param source Source endpoint, or none when unavailable.
     * @param truncated Whether the datagram exceeded the receive capacity.
     */
    public init(payload: Array<Byte>, source: ?NetworkEndpoint, truncated: Bool) {
        if (payload.size > 65507) {
            throw IllegalArgumentException("datagram payload exceeds the IPv4 payload bound")
        }
        this.payload = payload.clone()
        this.source = source
        this.truncated = truncated
    }

    internal init(source: ?NetworkEndpoint, truncated: Bool, ownedPayload!: Array<Byte>) {
        if (ownedPayload.size > 65507) {
            throw IllegalArgumentException("datagram payload exceeds the IPv4 payload bound")
        }
        this.payload = ownedPayload
        this.source = source
        this.truncated = truncated
    }
}

/**
 * Synchronous datagram operations shared by Internet and Unix adapters.
 *
 * One send and one receive may proceed concurrently; overlapping operations
 * in the same direction fail rather than creating an unbounded queue.
 * Each operation completes at most once under the supplied absolute context.
 * Local close, abort, cancellation and deadline retain distinct error causes.
 * Native bind factories and adapter qualification belong to M8-002/M8-003.
 */
public interface DatagramSocket <: Resource {
    /** Current lifecycle state. */
    prop state: SocketState
    /** Advisory capabilities; an operation remains authoritative. */
    prop capabilities: SocketCapabilities
    /** Local endpoint when known. */
    prop localEndpoint: ?NetworkEndpoint
    /** Selected peer endpoint when connected. */
    prop remoteEndpoint: ?NetworkEndpoint

    /** Selects a resolved peer without DNS or a new timeout owner.
     *
     * @param endpoint Peer of the adapter's supported endpoint kind.
     * @param context Shared absolute deadline and cancellation token.
     */
    func connect(endpoint: NetworkEndpoint, context!: api.OperationContext): Unit

    /** Sends one complete datagram to the selected peer.
     *
     * Success returns exactly `source.length`. Empty datagrams remain valid:
     * a backend without `zeroLengthDatagramSend` rejects only their sending
     * with `Unsupported`. Missing peers and payloads above 65,507 bytes fail
     * before I/O; a partial send is never successful stream-like progress.
     *
     * @param source Datagram payload retained only for this operation.
     * @param context Shared absolute deadline and cancellation token.
     */
    func send(source: api.ByteSpan, context!: api.OperationContext): Int64

    /** Sends one complete datagram without changing the selected peer.
     *
     * The same payload bound and atomic-send rules apply as for `send`.
     * Endpoint kinds unsupported by the adapter fail explicitly.
     *
     * @param endpoint Resolved destination endpoint.
     * @param source Datagram payload retained only for this operation.
     * @param context Shared absolute deadline and cancellation token.
     */
    func sendTo(endpoint: NetworkEndpoint, source: api.ByteSpan,
        context!: api.OperationContext): Int64

    /** Consumes exactly one datagram into an owned bounded result.
     *
     * Excess bytes are discarded and `truncated` is true. An empty payload is
     * a datagram, not stream EOF. Invalid capacity fails before receiving.
     *
     * @param capacity Maximum retained payload size, from 1 through 65,507.
     * @param context Shared absolute deadline and cancellation token.
     */
    func receive(capacity: Int64,
        context!: api.OperationContext): DatagramReceiveResult

    /** Closes idempotently and wakes pending operations.
     * @param context Shared context for any completion wait.
     */
    func close(context!: api.OperationContext): Unit

    /** Aborts idempotently without waiting and wakes pending operations.
     * @param reason Optional local abort reason.
     */
    func abort(reason!: ?api.AbortReason): Unit
}

/** A synchronous stream socket contract. */
public interface StreamSocket <: Resource {
    /** Current lifecycle state. */
    prop state: SocketState
    /** Advisory socket capabilities. */
    prop capabilities: SocketCapabilities
    /** Local endpoint when known. */
    prop localEndpoint: ?NetworkEndpoint
    /** Remote endpoint when known. */
    prop remoteEndpoint: ?NetworkEndpoint
    /** Reads at most the destination capacity and may return partial data.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    func read(destination: api.MutableByteSpan, context!: api.OperationContext): ReadResult
    /** Writes at most one bounded chunk and may return partial progress.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    func write(source: api.ByteSpan, context!: api.OperationContext): Int64
    /** Fills the destination or raises a terminal error.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    func readExact(destination: api.MutableByteSpan, context!: api.OperationContext): Unit
    /** Writes the complete source or raises a terminal error.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    func writeAll(source: api.ByteSpan, context!: api.OperationContext): Unit
    /** Requests a directional shutdown.
     * @param direction Direction to shut down.
     */
    func shutdown(direction: api.ShutdownDirection): Unit
    /** Closes the socket idempotently.
     * @param context Shared operation context.
     */
    func close(context!: api.OperationContext): Unit
    /** Aborts the socket idempotently.
     * @param reason Optional abort reason.
     */
    func abort(reason!: ?api.AbortReason): Unit
}

/** Partial-progress result for stream reads. */
public enum ReadResult {
/** A data read with its byte count. */
    | Data(Int64)
/** Peer reached EOF. */
    | EndOfStream
}

/** TCP stream backed by the provider-neutral Transport SPI. */
public class TcpStream <: StreamSocket & api.DuplexTransport {
    private let delegate: stdnet.SocketTransport
    private let connectionInfo: api.TransportInfo
    private let localEndpointValue: ?NetworkEndpoint
    private let remoteEndpointValue: ?NetworkEndpoint
    private let capabilityValue: SocketCapabilities
    private let lifecycleMutex = Mutex()
    private var lifecycleState = SocketState.Open
    private var closeActive = false
    private var closeCoordination: ?SocketCloseCoordination = None<SocketCloseCoordination>
    private var readShutdownInFlight: Int64 = 0
    private var writeShutdownInFlight: Int64 = 0

    internal init(delegate: stdnet.SocketTransport,
        nonBlocking!: Bool = false, closeOnExec!: Bool = false) {
        let info = delegate.info
        this.delegate = delegate
        this.connectionInfo = info
        this.localEndpointValue = match (info.localEndpoint) {
            case Some(value) => Some(NetworkEndpoint.Internet(value))
            case None => None<NetworkEndpoint>
        }
        this.remoteEndpointValue = match (info.remoteEndpoint) {
            case Some(value) => Some(NetworkEndpoint.Internet(value))
            case None => None<NetworkEndpoint>
        }
        this.capabilityValue = SocketCapabilities(
            nonBlocking: nonBlocking,
            closeOnExec: closeOnExec,
            halfClose: info.supportsHalfClose,
            broadcast: false,
            multicast: false,
            raw: false,
            ancillaryData: false
        )
    }

    /** Connects to an already-resolved endpoint without invoking DNS.
     * @param context Shared operation context.
     * @param endpoint Remote Internet endpoint.
     */
    public static func connect(
        endpoint: api.SocketEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): TcpStream {
        try {
            TcpStream(stdnet.StdNetTransport.connect(endpoint, context: context),
                nonBlocking: true, closeOnExec: true)
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.Connect, api.NetworkPhase.TcpConnect,
                None<NetworkEndpoint>, Some(NetworkEndpoint.Internet(endpoint)))
        }
    }

    /** Current retained stream lifecycle state. A returned stream is already connected. */
    public prop state: SocketState {
        get() { synchronized(lifecycleMutex) { lifecycleState } }
    }
    /** Advisory stream capabilities. Native Linux factories report qualified descriptor flags. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }
    /** Immutable local endpoint captured when the connection completed. */
    public prop localEndpoint: ?NetworkEndpoint { get() { localEndpointValue } }
    /** Immutable remote endpoint captured when the connection completed. */
    public prop remoteEndpoint: ?NetworkEndpoint { get() { remoteEndpointValue } }

    /** Reads one partial chunk.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func read(destination: api.MutableByteSpan, context!: api.OperationContext): ReadResult {
        if (destination.isEmpty()) { return ReadResult.Data(0) }
        requireReadable()
        try {
            match (delegate.readSome(destination, context: context)) {
                case api.ReadResult.Data(count) => ReadResult.Data(count)
                case api.ReadResult.EndOfStream => ReadResult.EndOfStream
            }
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                localEndpointValue, remoteEndpointValue)
            recordIoNetworkFailure(reported, api.ShutdownDirection.Read)
            throw reported
        }
    }
    /** Reads one transport chunk and returns the provider-neutral result.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        if (destination.isEmpty()) { return api.ReadResult.Data(0) }
        requireReadable()
        try {
            delegate.readSome(destination, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                localEndpointValue, remoteEndpointValue)
            recordIoNetworkFailure(reported, api.ShutdownDirection.Read)
            throw reported
        }
    }
    /** Writes one partial chunk.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func write(source: api.ByteSpan, context!: api.OperationContext): Int64 {
        if (source.isEmpty()) { return 0 }
        requireWritable()
        try {
            delegate.writeSome(source, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                localEndpointValue, remoteEndpointValue)
            recordIoNetworkFailure(reported, api.ShutdownDirection.Write)
            throw reported
        }
    }
    /** Writes one transport chunk.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        if (source.isEmpty()) { return 0 }
        requireWritable()
        try {
            delegate.writeSome(source, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                localEndpointValue, remoteEndpointValue)
            recordIoNetworkFailure(reported, api.ShutdownDirection.Write)
            throw reported
        }
    }
    /** Reads until the destination is full.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func readExact(destination: api.MutableByteSpan, context!: api.OperationContext): Unit {
        if (destination.isEmpty()) { return }
        requireReadable()
        try {
            api.readExact(delegate, destination, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                localEndpointValue, remoteEndpointValue)
            recordIoNetworkFailure(reported, api.ShutdownDirection.Read)
            throw reported
        }
    }
    /** Writes until the source is consumed.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func writeAll(source: api.ByteSpan, context!: api.OperationContext): Unit {
        if (source.isEmpty()) { return }
        requireWritable()
        try {
            api.writeAll(delegate, source, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                localEndpointValue, remoteEndpointValue)
            recordIoNetworkFailure(reported, api.ShutdownDirection.Write)
            throw reported
        }
    }
    /** Requests a directional shutdown.
     *
     * The lifecycle changes only after the delegate accepts the operation.
     * An unsupported shutdown therefore leaves the stream open.
     *
     * @param direction Direction to shut down.
     */
    public func shutdown(direction: api.ShutdownDirection): Unit {
        if (alreadyShutDown(direction)) { return }
        recordShutdownStarted(direction)
        try {
            delegate.shutdown(direction)
            recordShutdown(direction)
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.Shutdown,
                api.NetworkPhase.TransportClose, localEndpointValue, remoteEndpointValue)
            recordNetworkFailure(reported)
            if (delegate.isClosed()) { recordFailure() }
            throw reported
        } finally {
            recordShutdownFinished(direction)
        }
    }
    /** Closes the stream idempotently.
     *
     * Closed, aborted, and failed streams return before consulting the caller's
     * cancellation token or clock. A stopped context rejects states that still
     * require close before close ownership is admitted. Once admitted, graceful
     * cleanup retains ownership even when this caller's completion wait is
     * cancelled or reaches its deadline.
     *
     * @param context Shared operation context.
     */
    public func close(context!: api.OperationContext): Unit {
        try {
            if (isTerminalLifecycle()) { return }
            if (retainAbortOwnership()) { return }
            checkCloseContext(context, localEndpointValue, remoteEndpointValue)
            let coordinated = requiresCloseCoordination(context)
            let (ownsClose, coordination) = beginClose(coordinated)
            if (!ownsClose) {
                match (coordination) {
                    case Some(pending) =>
                        pending.wait(context, localEndpointValue, remoteEndpointValue)
                    case None => ()
                }
                return
            }
            if (!coordinated) {
                let result = runClose(context)
                publishCloseResult(result)
                match (result) {
                    case Some(error) => throw error
                    case None => ()
                }
                return
            }
            let pending = coordination.getOrThrow()
            let cleanupContext = api.OperationContext(
                trace: context.trace,
                eventSink: context.eventSink
            )
            try {
                spawn {
                    let result = runClose(cleanupContext)
                    publishCloseResult(result)
                }
            } catch (error: Exception) {
                let reported = socketFailure(error, api.NetworkErrorCategory.System,
                    api.NetworkPhase.TransportClose, localEndpointValue, remoteEndpointValue)
                try {
                    failClose()
                } finally {
                    publishCloseResult(Some(reported))
                }
                throw reported
            }
            pending.wait(context, localEndpointValue, remoteEndpointValue)
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose, localEndpointValue, remoteEndpointValue)
        }
    }
    /** Closes the stream with a background context for Resource callers. */
    public func close(): Unit { close(context: api.OperationContext.background()) }
    /** Aborts idempotently and publishes Aborted only when abort owns the native close.
     * @param reason Optional abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        try {
            if (isTerminalLifecycle()) { return }
            try {
                delegate.abort(reason: reason)
            } catch (error: Exception) {
                try {
                    let _ = retainAbortOwnership()
                } catch (_: Exception) {}
                throw error
            }
            let _ = retainAbortOwnership()
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose, localEndpointValue, remoteEndpointValue)
        }
    }
    /** Reports whether the delegate resource has reached its terminal lifecycle. */
    public func isClosed(): Bool { delegate.isClosed() }

    /** Returns the immutable connection diagnostics captured after connect. */
    public prop info: api.TransportInfo { get() { connectionInfo } }

    private func requireReadable(): Unit {
        let rejected = synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Open | SocketState.WriteHalfClosed => false
                case _ => true
            }
        }
        if (rejected) {
            throw directionClosedError(
                api.NetworkErrorCategory.Read,
                api.NetworkPhase.TcpRead,
                "TCP stream read direction is closed"
            )
        }
    }

    private func requireWritable(): Unit {
        let rejected = synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Open | SocketState.ReadHalfClosed => false
                case _ => true
            }
        }
        if (rejected) {
            throw directionClosedError(
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.TcpWrite,
                "TCP stream write direction is closed"
            )
        }
    }


    private func directionClosedError(
        category: api.NetworkErrorCategory,
        phase: api.NetworkPhase,
        message: String
    ): api.NetworkException {
        api.NetworkException(
            category,
            phase,
            api.NetworkErrorCode.Closed,
            message,
            retryability: api.Retryability.Never,
            localEndpoint: localEndpointValue,
            remoteEndpoint: remoteEndpointValue
        )
    }

    private func recordShutdownStarted(direction: api.ShutdownDirection): Unit {
        synchronized(lifecycleMutex) {
            match (direction) {
                case api.ShutdownDirection.Read => readShutdownInFlight++
                case api.ShutdownDirection.Write => writeShutdownInFlight++
            }
        }
    }

    private func recordShutdownFinished(direction: api.ShutdownDirection): Unit {
        synchronized(lifecycleMutex) {
            match (direction) {
                case api.ShutdownDirection.Read => readShutdownInFlight--
                case api.ShutdownDirection.Write => writeShutdownInFlight--
            }
        }
    }

    private func alreadyShutDown(direction: api.ShutdownDirection): Bool {
        synchronized(lifecycleMutex) {
            match ((lifecycleState, direction)) {
                case (SocketState.ReadHalfClosed, api.ShutdownDirection.Read) => true
                case (SocketState.WriteHalfClosed, api.ShutdownDirection.Write) => true
                case _ => false
            }
        }
    }

    private func recordShutdown(direction: api.ShutdownDirection): Unit {
        let bothDirectionsClosed = synchronized(lifecycleMutex) {
            match ((lifecycleState, direction)) {
                case (SocketState.Open, api.ShutdownDirection.Read) =>
                    lifecycleState = SocketState.ReadHalfClosed
                    false
                case (SocketState.Open, api.ShutdownDirection.Write) =>
                    lifecycleState = SocketState.WriteHalfClosed
                    false
                case (SocketState.ReadHalfClosed, api.ShutdownDirection.Write) |
                     (SocketState.WriteHalfClosed, api.ShutdownDirection.Read) =>
                    lifecycleState = SocketState.Closing
                    true
                case _ => false
            }
        }
        if (bothDirectionsClosed && delegate.isClosed()) { finishClose() }
    }

    private func beginClose(coordinated: Bool): (Bool, ?SocketCloseCoordination) {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Open | SocketState.ReadHalfClosed |
                     SocketState.WriteHalfClosed | SocketState.Closing =>
                    if (closeActive) {
                        if (closeCoordination.isNone()) {
                            closeCoordination = Some(SocketCloseCoordination())
                        }
                        (false, closeCoordination)
                    } else {
                        let pending = if (coordinated) {
                            Some(SocketCloseCoordination())
                        } else {
                            None<SocketCloseCoordination>
                        }
                        lifecycleState = SocketState.Closing
                        closeActive = true
                        closeCoordination = pending
                        (true, pending)
                    }
                case _ => (false, closeCoordination)
            }
        }
    }

    private func runClose(context: api.OperationContext): ?api.NetworkException {
        try {
            delegate.close(context)
            finishClose()
            None<api.NetworkException>
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose, localEndpointValue, remoteEndpointValue)
            failClose()
            Some(reported)
        }
    }

    private func finishClose(): Unit {
        let aborted = delegate.wasClosedByAbort()
        synchronized(lifecycleMutex) {
            closeActive = false
            match (lifecycleState) {
                case SocketState.Closing =>
                    lifecycleState = if (aborted) { SocketState.Aborted } else { SocketState.Closed }
                case _ => ()
            }
        }
    }

    private func failClose(): Unit {
        if (retainAbortOwnership()) {
            synchronized(lifecycleMutex) { closeActive = false }
            return
        }
        let shouldAbort = synchronized(lifecycleMutex) {
            closeActive = false
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => false
                case _ => lifecycleState = SocketState.Failed; true
            }
        }
        if (shouldAbort) {
            try {
                delegate.abort(reason: Some(api.AbortReason.ProtocolFailure))
            } catch (_: Exception) {}
        }
    }

    private func publishCloseResult(result: ?api.NetworkException): Unit {
        let pending = synchronized(lifecycleMutex) {
            let value = closeCoordination
            closeCoordination = None<SocketCloseCoordination>
            value
        }
        match (pending) {
            case Some(value) => value.complete(result)
            case None => ()
        }
    }

    private func isTerminalLifecycle(): Bool {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => true
                case _ => false
            }
        }
    }

    private func retainAbortOwnership(): Bool {
        if (!delegate.wasClosedByAbort()) { return false }
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => ()
                case _ => lifecycleState = SocketState.Aborted
            }
        }
        true
    }

    private func recordIoNetworkFailure(
        error: api.NetworkException,
        direction: api.ShutdownDirection
    ): Unit {
        match (error.code) {
            case api.NetworkErrorCode.Closed =>
                let (readShutDown, writeShutDown) = synchronized(lifecycleMutex) {
                    var readShutDown = readShutdownInFlight > 0
                    var writeShutDown = writeShutdownInFlight > 0
                    match (lifecycleState) {
                        case SocketState.ReadHalfClosed => readShutDown = true
                        case SocketState.WriteHalfClosed => writeShutDown = true
                        case _ => ()
                    }
                    (readShutDown, writeShutDown)
                }
                let directionWasShutDown = match (direction) {
                    case api.ShutdownDirection.Read => readShutDown
                    case api.ShutdownDirection.Write => writeShutDown
                }
                if (directionWasShutDown &&
                    ((readShutDown && writeShutDown) || !delegate.isClosed())) {
                    let _ = retainAbortOwnership()
                    return
                }
            case _ => ()
        }
        recordNetworkFailure(error)
    }

    private func recordNetworkFailure(error: api.NetworkException): Unit {
        if (retainAbortOwnership()) { return }
        match (error.code) {
            case api.NetworkErrorCode.ConnectionReset |
                 api.NetworkErrorCode.BrokenPipe |
                 api.NetworkErrorCode.SystemFailure |
                 api.NetworkErrorCode.Closed => recordFailure()
            case _ => ()
        }
    }

    private func recordFailure(): Unit {
        if (retainAbortOwnership()) { return }
        let shouldAbort = synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted |
                     SocketState.Failed | SocketState.Closing => false
                case _ => lifecycleState = SocketState.Failed; true
            }
        }
        if (shouldAbort) {
            try {
                delegate.abort(reason: Some(api.AbortReason.ProtocolFailure))
            } catch (_: Exception) {}
        }
    }
}

internal class SocketCloseCoordination {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var completed = false
    private var failure: ?api.NetworkException = None<api.NetworkException>

    func complete(value: ?api.NetworkException): Unit {
        synchronized(mutex) {
            if (!completed) {
                failure = value
                completed = true
                changed.notifyAll()
            }
        }
    }

    func wait(
        context: api.OperationContext,
        localEndpoint: ?NetworkEndpoint,
        remoteEndpoint: ?NetworkEndpoint
    ): Unit {
        if (!requiresCloseCoordination(context)) {
            let result = synchronized(mutex) {
                while (!completed) { changed.wait() }
                failure
            }
            match (result) {
                case Some(error) => throw error
                case None => return
            }
        }
        let registration = context.cancellation.register { => wake() }
        try {
            let result = synchronized(mutex) {
                while (!completed) {
                    match (closeContextFailure(context, localEndpoint, remoteEndpoint)) {
                        case Some(error) => throw error
                        case None => ()
                    }
                    match (context.deadline) {
                        case Some(deadline) =>
                            let remaining = deadline.remaining()
                            if (remaining <= Duration.Zero) {
                                throw closeContextFailure(
                                    context,
                                    localEndpoint,
                                    remoteEndpoint
                                ).getOrThrow()
                            }
                            changed.wait(timeout: remaining)
                        case None => changed.wait()
                    }
                }
                failure
            }
            match (result) {
                case Some(error) => throw error
                case None => ()
            }
        } finally {
            registration.unregister()
        }
    }

    private func wake(): Unit {
        synchronized(mutex) { changed.notifyAll() }
    }
}

internal func requiresCloseCoordination(context: api.OperationContext): Bool {
    context.deadline.isSome() || !context.cancellation.permanentlyActive
}

internal func checkCloseContext(
    context: api.OperationContext,
    localEndpoint: ?NetworkEndpoint,
    remoteEndpoint: ?NetworkEndpoint
): Unit {
    match (closeContextFailure(context, localEndpoint, remoteEndpoint)) {
        case Some(error) => throw error
        case None => ()
    }
}

private func closeContextFailure(
    context: api.OperationContext,
    localEndpoint: ?NetworkEndpoint,
    remoteEndpoint: ?NetworkEndpoint
): ?api.NetworkException {
    if (context.isCancellationRequested()) {
        return Some(api.NetworkException(
            api.NetworkErrorCategory.Cancelled,
            api.NetworkPhase.TransportClose,
            api.NetworkErrorCode.Cancelled,
            "socket close cancelled",
            retryability: api.Retryability.Never,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        ))
    }
    if (context.isDeadlineExceeded()) {
        return Some(api.NetworkException(
            api.NetworkErrorCategory.DeadlineExceeded,
            api.NetworkPhase.TransportClose,
            api.NetworkErrorCode.TimedOut,
            "socket close deadline exceeded",
            retryability: api.Retryability.Temporary,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        ))
    }
    None<api.NetworkException>
}

internal func socketFailure(
    error: Exception,
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase,
    localEndpoint: ?NetworkEndpoint,
    remoteEndpoint: ?NetworkEndpoint
): api.NetworkException {
    let structured = error as api.NetworkException
    if (let Some(network) <- structured) {
        if ((network.localEndpoint.isSome() || localEndpoint.isNone()) &&
            (network.remoteEndpoint.isSome() || remoteEndpoint.isNone())) {
            return network
        }
        api.NetworkException(
            network.category, network.phase, network.code, network.message,
            retryability: network.retryability,
            nativeCode: network.nativeCode,
            localEndpoint: if (network.localEndpoint.isSome()) { network.localEndpoint } else { localEndpoint },
            remoteEndpoint: if (network.remoteEndpoint.isSome()) { network.remoteEndpoint } else { remoteEndpoint },
            cause: network.cause
        )
    } else {
        api.NetworkException(
            category, phase, api.NetworkErrorCode.SystemFailure,
            "socket operation failed",
            retryability: api.Retryability.Never,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint,
            cause: Some(error)
        )
    }
}

/** Raw protocol/domain configuration, independent from destination addressing. */
public enum RawSocketDomain {
/** IPv4 raw socket domain. */
    | Ipv4
/** IPv6 raw socket domain. */
    | Ipv6
/** Linux packet domain; not implemented in the M8 profile. */
    | Packet
/** Linux netlink domain; not implemented in the M8 profile. */
    | Netlink
}

/** A numeric raw protocol value. */
public struct RawSocketProtocol {
    /** Numeric protocol identifier. */
    public let number: Int32
    /** Creates a bounded numeric raw protocol value.
     * @param number Protocol identifier in the supported numeric range.
     */
    public init(number: Int32) {
        if (number < 0 || number > 255) { throw IllegalArgumentException("raw protocol must be between 0 and 255") }
        this.number = number
    }
    /** Returns the IPv4 ICMP protocol number. */
    public static func icmp(): RawSocketProtocol { RawSocketProtocol(1) }
    /** Returns the IPv6 ICMP protocol number. */
    public static func icmpv6(): RawSocketProtocol { RawSocketProtocol(58) }
}

/** Opaque raw address bytes. C pointers and native descriptors never escape. */
public struct RawAddress {
    private let value: Array<Byte>
    /** Creates a bounded raw destination address.
     * @param bytes Address bytes owned by this value.
     */
    public init(bytes: Array<Byte>) {
        if (bytes.isEmpty() || bytes.size > 256) { throw IllegalArgumentException("raw address is outside the bounded range") }
        value = bytes.clone()
    }
    /** Returns a defensive copy of the address bytes. */
    public func bytes(): Array<Byte> { value.clone() }
}

/**
 * Explicit raw-socket capability boundary.
 *
 * M8-001 installs no privileged raw adapter, so construction always fails
 * with a structured Unsupported error. It does not return a placeholder
 * object with operations that can never succeed.
 */
public class RawSocket {
    private init() {}

    /** Attempts to open a raw socket through an installed capability adapter.
     *
     * Callers must select a protocol explicitly because protocol numbers are
     * domain-specific. In particular, IPv6 does not default to IPv4 ICMP.
     *
     * @param domain Address domain to open.
     * @param protocolValue Raw protocol number for that domain.
     */
    public static func open(
        domain: RawSocketDomain,
        protocolValue: RawSocketProtocol
    ): RawSocket {
        let _ = domain
        let _ = protocolValue
        throw api.NetworkException(
            api.NetworkErrorCategory.Unsupported,
            api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Unsupported,
            "raw socket capability adapter is not installed in the M8 Linux profile",
            retryability: api.Retryability.Never
        )
    }
}

