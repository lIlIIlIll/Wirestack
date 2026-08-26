package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.Mutex
import wirestack.internal.transport.*

private const HTTP2_DEFAULT_WINDOW: Int64 = 65535
private const HTTP2_MAX_WINDOW: Int64 = 2147483647
private const HTTP2_CONNECTION_UPDATE_THRESHOLD: Int64 = HTTP2_DEFAULT_WINDOW / 2

public enum Http2SendPermitState {
    | Reserved
    | Sending
    | Cancelled
}

/** Immutable view of one stream's current flow-control accounting. */
public class Http2FlowSnapshot {
    public let sendWindow: Int64
    public let receiveWindow: Int64
    public let reservedSendBytes: Int64
    public let bufferedReceiveBytes: Int64

    public init(sendWindow: Int64, receiveWindow: Int64, reservedSendBytes: Int64, bufferedReceiveBytes: Int64) {
        this.sendWindow = sendWindow
        this.receiveWindow = receiveWindow
        this.reservedSendBytes = reservedSendBytes
        this.bufferedReceiveBytes = bufferedReceiveBytes
    }
}

/**
 * A bounded outbound DATA reservation.
 *
 * `beginSend` consumes protocol credit immediately before a writer emits the
 * frame. Before that point `cancel` returns the reservation exactly once. This
 * separation lets a SETTINGS decrease pause already-reserved DATA without
 * leaking connection credit or buffering body bytes inside the controller.
 */
public class Http2SendPermit {
    internal let id: Int64
    public let streamId: Http2StreamId
    public let amount: Int64
    private let controller: Http2FlowController
    internal var current = Http2SendPermitState.Reserved

    public prop state: Http2SendPermitState { get() { controller.permitState(this) } }

    internal init(id: Int64, controller: Http2FlowController, streamId: Http2StreamId, amount: Int64) {
        this.id = id
        this.controller = controller
        this.streamId = streamId
        this.amount = amount
    }

    /** Blocks without polling until current connection and stream credit permit this DATA. */
    public func beginSend(context!: OperationContext = OperationContext.background()): Bool {
        controller.beginPermit(this, context)
    }

    /** Returns reserved capacity before sending; repeated cancellation is a no-op. */
    public func cancel(): Bool { controller.cancelPermit(this) }
}

/**
 * Atomic connection-plus-stream HTTP/2 flow control.
 *
 * The controller stores no DATA. Receive buffering is accounting only and can
 * never exceed the protocol windows. Send reservations and waiters are capped
 * by the configured pending-write count, and every blocking path is woken by
 * cancellation, WINDOW_UPDATE, SETTINGS, stream cleanup, or connection close.
 */
public class Http2FlowController {
    private let limits: Http2Limits
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let streams = ArrayList<Http2FlowStream>()
    private let permits = ArrayList<Http2SendPermit>()
    private var sendConnectionWindow: Int64 = HTTP2_DEFAULT_WINDOW
    private var receiveConnectionWindow: Int64 = HTTP2_DEFAULT_WINDOW
    private var pendingConnectionReceiveCredit: Int64 = 0
    private var reservedConnectionBytes: Int64 = 0
    private var sendInitialStreamWindow: Int64 = HTTP2_DEFAULT_WINDOW
    private var receiveInitialStreamWindow: Int64 = HTTP2_DEFAULT_WINDOW
    private var peerMaxFrameSize: Int64 = 16384
    private var waitingReservations: Int64 = 0
    private var sendStallCount: Int64 = 0
    private var nextPermitId: Int64 = 1
    private var closed = false

    public prop sendConnectionAvailable: Int64 {
        get() { synchronized(mutex) { sendConnectionWindow - reservedConnectionBytes } }
    }
    public prop receiveConnectionAvailable: Int64 { get() { synchronized(mutex) { receiveConnectionWindow } } }
    public prop activeStreamCount: Int64 { get() { synchronized(mutex) { streams.size } } }
    public prop pendingPermitCount: Int64 { get() { synchronized(mutex) { permits.size } } }
    public prop flowControlStalls: Int64 { get() { synchronized(mutex) { sendStallCount } } }
    public prop bufferedReceiveBytes: Int64 {
        get() {
            synchronized(mutex) {
                var total: Int64 = 0
                for (stream in streams) { total += stream.bufferedReceiveBytes }
                total
            }
        }
    }

    public init(limits!: Http2Limits = Http2Limits()) { this.limits = limits }

    public func openStream(streamId: Http2StreamId): Unit {
        if (!streamId.isStream()) { throw IllegalArgumentException("HTTP/2 flow stream id must be non-zero") }
        synchronized(mutex) {
            requireFlowOpenLocked()
            if (findFlowStreamLocked(streamId).isSome()) {
                throw IllegalStateException("HTTP/2 flow stream is already open")
            }
            if (streams.size >= Int64(limits.maxConcurrentStreams)) {
                throw Http2StreamLimitException("HTTP/2 flow stream limit reached")
            }
            streams.add(Http2FlowStream(streamId, sendInitialStreamWindow, receiveInitialStreamWindow))
        }
    }

    /**
     * Removes one stream, cancels its unsent permits, and returns connection
     * credit for discarded inbound bytes. Stream credit is not updated after close.
     */
    public func closeStream(streamId: Http2StreamId): Array<Http2Frame> {
        let discarded = synchronized(mutex) {
            let index = findFlowStreamIndexLocked(streamId)
            if (index < 0) { 0 }
            else {
                let stream = streams.remove(at: index)
                cancelStreamPermitsLocked(streamId)
                // A stream boundary is a natural flush point for all coalesced
                // connection credit, including credit consumed on other streams.
                let returned = stream.bufferedReceiveBytes + pendingConnectionReceiveCredit
                pendingConnectionReceiveCredit = 0
                receiveConnectionWindow += returned
                changed.notifyAll()
                returned
            }
        }
        if (discarded == 0) { [] }
        else { [encodeHttp2WindowUpdate(Http2StreamId(0u32), UInt32(discarded), limits: limits)] }
    }

    /** Idempotently releases every waiter and all bounded flow state. */
    public func close(): Unit {
        synchronized(mutex) {
            if (closed) { return }
            closed = true
            for (permit in permits) { permit.current = Http2SendPermitState.Cancelled }
            permits.clear()
            streams.clear()
            reservedConnectionBytes = 0
            pendingConnectionReceiveCredit = 0
            changed.notifyAll()
        }
    }

    public func snapshot(streamId: Http2StreamId): Http2FlowSnapshot {
        synchronized(mutex) {
            let stream = requireFlowStreamLocked(streamId)
            Http2FlowSnapshot(
                stream.sendWindow, stream.receiveWindow, stream.reservedSendBytes, stream.bufferedReceiveBytes
            )
        }
    }

    /** Returns immediately with None when either current window has no reservable credit. */
    public func tryReserveSend(streamId: Http2StreamId, requested: Int64): ?Http2SendPermit {
        requirePositiveFlowBytes(requested)
        synchronized(mutex) {
            requireFlowOpenLocked()
            if (permits.size + waitingReservations >= Int64(limits.maxPendingWrites)) {
                return None<Http2SendPermit>
            }
            let stream = requireFlowStreamLocked(streamId)
            let amount = reservableLocked(stream, requested)
            if (amount <= 0) { None<Http2SendPermit> }
            else { Some(reserveLocked(stream, amount)) }
        }
    }

    /** Waits without polling and never retains more than the configured number of waiters/permits. */
    public func reserveSend(
        streamId: Http2StreamId,
        requested: Int64,
        context!: OperationContext = OperationContext.background()
    ): Http2SendPermit {
        requirePositiveFlowBytes(requested)
        let registration = context.cancellation.register { => wakeFlowWaiters() }
        var counted = false
        var stalled = false
        try {
            synchronized(mutex) {
                requireFlowOpenLocked()
                if (permits.size + waitingReservations >= Int64(limits.maxPendingWrites)) {
                    throw Http2WriteQueueFullException("HTTP/2 flow reservation limit reached")
                }
                waitingReservations += 1
                counted = true
                while (true) {
                    checkFlowContext(context)
                    requireFlowOpenLocked()
                    let stream = requireFlowStreamLocked(streamId)
                    let amount = reservableLocked(stream, requested)
                    if (amount > 0) { return reserveLocked(stream, amount) }
                    if (!stalled) { sendStallCount += 1; stalled = true }
                    waitFlowChangeLocked(context)
                }
                throw IllegalStateException("unreachable HTTP/2 flow reservation state")
            }
        } finally {
            if (counted) { synchronized(mutex) { waitingReservations -= 1; changed.notifyAll() } }
            registration.unregister()
        }
    }

    /** Applies an inbound WINDOW_UPDATE to outbound protocol credit. */
    public func receiveWindowUpdate(frame: Http2Frame): Unit {
        let increment = decodeHttp2WindowUpdate(frame)
        synchronized(mutex) {
            requireFlowOpenLocked()
            if (frame.header.streamId.isConnection()) {
                if (sendConnectionWindow > HTTP2_MAX_WINDOW - Int64(increment)) {
                    throw flowConnectionError("HTTP/2 connection send window overflow")
                }
                sendConnectionWindow += Int64(increment)
            } else {
                let stream = requireFlowStreamProtocolLocked(frame.header.streamId)
                if (stream.sendWindow > HTTP2_MAX_WINDOW - Int64(increment)) {
                    throw flowStreamError(frame.header.streamId, "HTTP/2 stream send window overflow")
                }
                stream.sendWindow += Int64(increment)
            }
            changed.notifyAll()
        }
    }

    /** Atomically applies the peer SETTINGS initial-window delta to every live stream. */
    public func applyPeerSettings(update: Http2SettingsUpdate): Unit {
        synchronized(mutex) {
            requireFlowOpenLocked()
            let nextInitial = Int64(update.peer.initialWindowSize)
            let delta = nextInitial - sendInitialStreamWindow
            for (stream in streams) {
                let next = stream.sendWindow + delta
                if (next > HTTP2_MAX_WINDOW || next < -HTTP2_MAX_WINDOW) {
                    throw flowConnectionError("HTTP/2 SETTINGS caused a stream send window overflow")
                }
            }
            for (stream in streams) { stream.sendWindow += delta }
            sendInitialStreamWindow = nextInitial
            peerMaxFrameSize = Int64(update.peer.maxFrameSize)
            changed.notifyAll()
        }
    }

    /** Mirrors a locally emitted SETTINGS_INITIAL_WINDOW_SIZE for inbound validation. */
    public func updateLocalInitialWindowSize(value: UInt32): Unit {
        if (value > UInt32(HTTP2_MAX_WINDOW)) {
            throw IllegalArgumentException("HTTP/2 local initial window must fit 31 bits")
        }
        synchronized(mutex) {
            requireFlowOpenLocked()
            let nextInitial = Int64(value)
            let delta = nextInitial - receiveInitialStreamWindow
            for (stream in streams) {
                let next = stream.receiveWindow + delta
                if (next > HTTP2_MAX_WINDOW || next < -HTTP2_MAX_WINDOW) {
                    throw IllegalStateException("HTTP/2 local SETTINGS caused a receive window overflow")
                }
            }
            for (stream in streams) { stream.receiveWindow += delta }
            receiveInitialStreamWindow = nextInitial
        }
    }

    /** Accounts the full flow-controlled DATA payload, including padding fields. */
    public func receiveData(streamId: Http2StreamId, flowControlledBytes: Int64): Unit {
        if (flowControlledBytes < 0) { throw IllegalArgumentException("HTTP/2 DATA length must not be negative") }
        synchronized(mutex) {
            requireFlowOpenLocked()
            let stream = requireFlowStreamProtocolLocked(streamId)
            if (flowControlledBytes > receiveConnectionWindow) {
                throw flowConnectionError("HTTP/2 DATA exceeded the connection receive window")
            }
            if (flowControlledBytes > stream.receiveWindow) {
                throw flowStreamError(streamId, "HTTP/2 DATA exceeded the stream receive window")
            }
            receiveConnectionWindow -= flowControlledBytes
            stream.receiveWindow -= flowControlledBytes
            stream.bufferedReceiveBytes += flowControlledBytes
        }
    }

    /**
     * Returns credit only after application consumption and coalesces small
     * reads until half-window thresholds. This bounds WINDOW_UPDATE pressure
     * without retaining body bytes or delaying a peer once useful credit is
     * available.
     */
    public func consumeReceived(streamId: Http2StreamId, bytes: Int64): Array<Http2Frame> {
        consumeReceivedWithPolicy(streamId, bytes, false)
    }

    /**
     * Returns consumed credit immediately when an application discards a body.
     * This prevents an abandoned stream from withholding connection capacity.
     */
    internal func consumeReceivedNow(streamId: Http2StreamId, bytes: Int64): Array<Http2Frame> {
        consumeReceivedWithPolicy(streamId, bytes, true)
    }

    private func consumeReceivedWithPolicy(
        streamId: Http2StreamId,
        bytes: Int64,
        force: Bool
    ): Array<Http2Frame> {
        requirePositiveFlowBytes(bytes)
        synchronized(mutex) {
            requireFlowOpenLocked()
            let stream = requireFlowStreamLocked(streamId)
            if (bytes > stream.bufferedReceiveBytes) {
                throw IllegalArgumentException("HTTP/2 cannot consume more DATA than was received")
            }
            if (pendingConnectionReceiveCredit > HTTP2_MAX_WINDOW - bytes ||
                stream.pendingReceiveCredit > HTTP2_MAX_WINDOW - bytes) {
                throw IllegalStateException("HTTP/2 receive credit accounting overflow")
            }
            stream.bufferedReceiveBytes -= bytes
            pendingConnectionReceiveCredit += bytes
            stream.pendingReceiveCredit += bytes
            let updates = ArrayList<Http2Frame>()
            let streamThreshold = max(1, receiveInitialStreamWindow / 2)
            if (force || stream.pendingReceiveCredit >= streamThreshold) {
                let credit = stream.pendingReceiveCredit
                if (stream.receiveWindow > HTTP2_MAX_WINDOW - credit) {
                    throw IllegalStateException("HTTP/2 stream receive credit accounting overflow")
                }
                stream.receiveWindow += credit
                stream.pendingReceiveCredit = 0
                updates.add(encodeHttp2WindowUpdate(streamId, UInt32(credit), limits: limits))
            }
            if (force || pendingConnectionReceiveCredit >= HTTP2_CONNECTION_UPDATE_THRESHOLD) {
                let credit = pendingConnectionReceiveCredit
                if (receiveConnectionWindow > HTTP2_MAX_WINDOW - credit) {
                    throw IllegalStateException("HTTP/2 connection receive credit accounting overflow")
                }
                receiveConnectionWindow += credit
                pendingConnectionReceiveCredit = 0
                updates.add(encodeHttp2WindowUpdate(
                    Http2StreamId(0u32), UInt32(credit), limits: limits
                ))
            }
            updates.toArray()
        }
    }

    internal func permitState(permit: Http2SendPermit): Http2SendPermitState {
        synchronized(mutex) { permit.current }
    }

    internal func beginPermit(permit: Http2SendPermit, context: OperationContext): Bool {
        let registration = context.cancellation.register { => wakeFlowWaiters() }
        var stalled = false
        try {
            synchronized(mutex) {
                while (true) {
                    if (!isPermitReserved(permit.current)) { return false }
                    checkFlowContext(context)
                    requireFlowOpenLocked()
                    let stream = requireFlowStreamLocked(permit.streamId)
                    if (sendConnectionWindow >= permit.amount && stream.sendWindow >= permit.amount) {
                        sendConnectionWindow -= permit.amount
                        stream.sendWindow -= permit.amount
                        reservedConnectionBytes -= permit.amount
                        stream.reservedSendBytes -= permit.amount
                        removePermitLocked(permit)
                        permit.current = Http2SendPermitState.Sending
                        changed.notifyAll()
                        return true
                    }
                    if (!stalled) { sendStallCount += 1; stalled = true }
                    waitFlowChangeLocked(context)
                }
                false
            }
        } catch (error: NetworkException) {
            let _ = cancelPermit(permit)
            throw error
        } finally {
            registration.unregister()
        }
    }

    internal func cancelPermit(permit: Http2SendPermit): Bool {
        synchronized(mutex) {
            if (!isPermitReserved(permit.current)) { return false }
            permit.current = Http2SendPermitState.Cancelled
            let stream = findFlowStreamLocked(permit.streamId)
            if (let Some(value) <- stream) { value.reservedSendBytes -= permit.amount }
            reservedConnectionBytes -= permit.amount
            removePermitLocked(permit)
            changed.notifyAll()
            true
        }
    }

    private func reserveLocked(stream: Http2FlowStream, amount: Int64): Http2SendPermit {
        let permit = Http2SendPermit(nextPermitId, this, stream.id, amount)
        nextPermitId += 1
        stream.reservedSendBytes += amount
        reservedConnectionBytes += amount
        permits.add(permit)
        permit
    }

    private func reservableLocked(stream: Http2FlowStream, requested: Int64): Int64 {
        minFlow(
            minFlow(requested, peerMaxFrameSize),
            minFlow(sendConnectionWindow - reservedConnectionBytes, stream.sendWindow - stream.reservedSendBytes)
        )
    }

    private func cancelStreamPermitsLocked(streamId: Http2StreamId): Unit {
        var index: Int64 = permits.size - 1
        while (index >= 0) {
            let permit = permits[index]
            if (permit.streamId.value == streamId.value && isPermitReserved(permit.current)) {
                permit.current = Http2SendPermitState.Cancelled
                reservedConnectionBytes -= permit.amount
                let _ = permits.remove(at: index)
            }
            index -= 1
        }
    }

    private func removePermitLocked(target: Http2SendPermit): Unit {
        for (index in 0..permits.size) {
            if (permits[index].id == target.id) { let _ = permits.remove(at: index); return }
        }
    }

    private func findFlowStreamLocked(streamId: Http2StreamId): ?Http2FlowStream {
        for (stream in streams) { if (stream.id.value == streamId.value) { return Some(stream) } }
        None<Http2FlowStream>
    }

    private func findFlowStreamIndexLocked(streamId: Http2StreamId): Int64 {
        for (index in 0..streams.size) { if (streams[index].id.value == streamId.value) { return index } }
        -1
    }

    private func requireFlowStreamLocked(streamId: Http2StreamId): Http2FlowStream {
        match (findFlowStreamLocked(streamId)) {
            case Some(value) => value
            case None => throw IllegalStateException("HTTP/2 flow stream is not active")
        }
    }

    private func requireFlowStreamProtocolLocked(streamId: Http2StreamId): Http2FlowStream {
        match (findFlowStreamLocked(streamId)) {
            case Some(value) => value
            case None => throw Http2ProtocolException(
                Http2ErrorCode.StreamClosed, Http2ErrorScope.Stream(streamId), "HTTP/2 flow stream is not active"
            )
        }
    }

    private func requireFlowOpenLocked(): Unit {
        if (closed) { throw IllegalStateException("HTTP/2 flow controller is closed") }
    }

    private func waitFlowChangeLocked(context: OperationContext): Unit {
        match (context.deadline) {
            case Some(deadline) => changed.wait(timeout: deadline.remaining())
            case None => changed.wait()
        }
    }

    private func wakeFlowWaiters(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private class Http2FlowStream {
    let id: Http2StreamId
    var sendWindow: Int64
    var receiveWindow: Int64
    var reservedSendBytes: Int64 = 0
    var bufferedReceiveBytes: Int64 = 0
    var pendingReceiveCredit: Int64 = 0

    init(id: Http2StreamId, sendWindow: Int64, receiveWindow: Int64) {
        this.id = id
        this.sendWindow = sendWindow
        this.receiveWindow = receiveWindow
    }
}

public func encodeHttp2WindowUpdate(
    streamId: Http2StreamId,
    increment: UInt32,
    limits!: Http2Limits = Http2Limits()
): Http2Frame {
    if (increment == 0u32 || increment > UInt32(HTTP2_MAX_WINDOW)) {
        throw IllegalArgumentException("HTTP/2 WINDOW_UPDATE increment must be in [1, 2^31-1]")
    }
    let payload: Array<Byte> = [
        UInt8((increment >> 24) & 0x7fu32),
        UInt8((increment >> 16) & 0xffu32),
        UInt8((increment >> 8) & 0xffu32),
        UInt8(increment & 0xffu32)
    ]
    Http2Frame(
        Http2FrameHeader(4u32, Http2FrameType.WindowUpdate, Http2Flags(), streamId, limits: limits), payload
    )
}

public func decodeHttp2WindowUpdate(frame: Http2Frame): UInt32 {
    if (!isWindowUpdateFrame(frame.header.frameType)) {
        throw IllegalArgumentException("expected HTTP/2 WINDOW_UPDATE frame")
    }
    let payload = frame.payload
    let increment = ((UInt32(payload[0]) & 0x7fu32) << 24) | (UInt32(payload[1]) << 16) |
        (UInt32(payload[2]) << 8) | UInt32(payload[3])
    if (increment == 0u32) {
        let scope = if (frame.header.streamId.isConnection()) { Http2ErrorScope.Connection }
            else { Http2ErrorScope.Stream(frame.header.streamId) }
        throw Http2ProtocolException(
            Http2ErrorCode.ProtocolError, scope, "HTTP/2 WINDOW_UPDATE increment must not be zero"
        )
    }
    increment
}

public func http2DataFlowControlledBytes(frame: Http2Frame): Int64 {
    if (!isDataFrameForFlow(frame.header.frameType)) { throw IllegalArgumentException("expected HTTP/2 DATA frame") }
    Int64(frame.header.length)
}

private func checkFlowContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 flow-control wait cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut,
            "HTTP/2 flow-control deadline exceeded", retryability: Retryability.Temporary
        )
    }
}

private func requirePositiveFlowBytes(value: Int64): Unit {
    if (value <= 0) { throw IllegalArgumentException("HTTP/2 flow-control byte count must be positive") }
}

private func flowConnectionError(message: String): Http2ProtocolException {
    Http2ProtocolException(Http2ErrorCode.FlowControlError, Http2ErrorScope.Connection, message)
}

private func flowStreamError(streamId: Http2StreamId, message: String): Http2ProtocolException {
    Http2ProtocolException(Http2ErrorCode.FlowControlError, Http2ErrorScope.Stream(streamId), message)
}

private func minFlow(left: Int64, right: Int64): Int64 { if (left < right) { left } else { right } }

private func isPermitReserved(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Reserved => true; case _ => false }
}

private func isWindowUpdateFrame(value: Http2FrameType): Bool {
    match (value) { case Http2FrameType.WindowUpdate => true; case _ => false }
}

private func isDataFrameForFlow(value: Http2FrameType): Bool {
    match (value) { case Http2FrameType.Data => true; case _ => false }
}
