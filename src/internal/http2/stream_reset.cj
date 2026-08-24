package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*

private const HTTP2_RESET_REASON_LIMIT: Int64 = 256

/** Immutable evidence delivered once to a stream owner after either reset direction wins. */
public class Http2StreamResetEvent {
    public let streamId: Http2StreamId
    public let code: Http2ErrorCode
    public let reason: String
    public let peerInitiated: Bool

    public init(streamId: Http2StreamId, code: Http2ErrorCode, reason: String, peerInitiated: Bool) {
        this.streamId = streamId
        this.code = code
        this.reason = reason
        this.peerInitiated = peerInitiated
    }
}

/** Stream-owned wakeup target. Implementations must not block the connection reader. */
public interface Http2StreamResetListener {
    func streamReset(event: Http2StreamResetEvent): Unit
}

public class Http2StreamResetRegistration {
    private let manager: Http2StreamResetManager
    private let streamId: Http2StreamId
    private let removed = AtomicBool(false)

    internal init(manager: Http2StreamResetManager, streamId: Http2StreamId) {
        this.manager = manager
        this.streamId = streamId
    }

    public func unregister(): Unit {
        if (!removed.swap(true)) { manager.unregister(streamId) }
    }
}

/**
 * Coordinates RST_STREAM with lifecycle, queued writes, flow permits and one
 * bounded stream-owner listener without terminating the containing connection.
 */
public class Http2StreamResetManager {
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let listenerLimit: Int64
    private let mutex = Mutex()
    private let listeners = ArrayList<Http2ResetListenerEntry>()
    private var deferredConnectionCredit: UInt32 = 0u32

    public prop activeListenerCount: Int64 { get() { synchronized(mutex) { listeners.size } } }
    public prop deferredCredit: UInt32 { get() { synchronized(mutex) { deferredConnectionCredit } } }

    public init(
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        limits!: Http2Limits = Http2Limits()
    ) {
        this.registry = registry
        this.flow = flow
        this.writer = writer
        listenerLimit = Int64(limits.maxConcurrentStreams)
    }

    /** Registers at most one removable wakeup target for one currently active stream. */
    public func register(
        streamId: Http2StreamId,
        listener: Http2StreamResetListener
    ): Http2StreamResetRegistration {
        synchronized(mutex) {
            if (registry.stream(streamId).isNone()) {
                throw IllegalStateException("HTTP/2 reset listener requires an active stream")
            }
            if (findListenerIndexLocked(streamId) >= 0) {
                throw IllegalStateException("HTTP/2 stream already has a reset listener")
            }
            if (listeners.size >= listenerLimit) {
                throw IllegalStateException("HTTP/2 reset listener limit reached")
            }
            listeners.add(Http2ResetListenerEntry(streamId, listener))
        }
        Http2StreamResetRegistration(this, streamId)
    }

    /**
     * Accepts the reset frame into the bounded writer before making cancellation
     * locally visible. Queue exhaustion therefore leaves the stream unchanged.
     */
    public func cancelLocal(
        streamId: Http2StreamId,
        code!: Http2ErrorCode = Http2ErrorCode.Cancel,
        reason!: String = "HTTP/2 stream cancelled locally"
    ): ?Http2WriteTicket {
        validateResetReason(reason)
        var listener: ?Http2StreamResetListener = None<Http2StreamResetListener>
        var event: ?Http2StreamResetEvent = None<Http2StreamResetEvent>
        let ticket = synchronized(mutex) {
            if (registry.stream(streamId).isNone()) { return None<Http2WriteTicket> }
            let accepted = writer.enqueue(encodeHttp2RstStream(streamId, code))
            try {
                if (!registry.reset(streamId, code, reason)) {
                    let _ = accepted.cancel()
                    return None<Http2WriteTicket>
                }
            } catch (error: Http2ProtocolException) {
                let _ = accepted.cancel()
                if (isClosedReset(error)) { return None<Http2WriteTicket> }
                throw error
            } catch (error: Exception) {
                let _ = accepted.cancel()
                throw error
            }
            let _ = writer.cancelStream(streamId, preservingTicketId: Some(accepted.id))
            retainCleanupCreditLocked(flow.closeStream(streamId))
            listener = claimListenerLocked(streamId)
            event = Some(Http2StreamResetEvent(streamId, code, reason, false))
            flushDeferredCreditLocked()
            Some(accepted)
        }
        notifyResetListener(listener, event)
        ticket
    }

    /** Applies one peer reset and ignores a duplicate reset for an already-closed stream. */
    public func acceptPeer(frame: Http2Frame): Bool {
        let code = decodeHttp2RstStream(frame)
        let streamId = frame.header.streamId
        var listener: ?Http2StreamResetListener = None<Http2StreamResetListener>
        var event: ?Http2StreamResetEvent = None<Http2StreamResetEvent>
        let won = synchronized(mutex) {
            let resetWon = try {
                registry.reset(streamId, code, "HTTP/2 stream reset by peer")
            } catch (error: Http2ProtocolException) {
                if (isClosedReset(error)) { return false }
                throw error
            }
            if (!resetWon) { return false }
            let _ = writer.cancelStream(streamId)
            retainCleanupCreditLocked(flow.closeStream(streamId))
            listener = claimListenerLocked(streamId)
            event = Some(Http2StreamResetEvent(streamId, code, "HTTP/2 stream reset by peer", true))
            flushDeferredCreditLocked()
            true
        }
        notifyResetListener(listener, event)
        won
    }

    /** Retries one aggregated connection WINDOW_UPDATE after writer capacity returns. */
    public func flush(): Bool { synchronized(mutex) { flushDeferredCreditLocked() } }

    internal func unregister(streamId: Http2StreamId): Unit {
        synchronized(mutex) {
            let index = findListenerIndexLocked(streamId)
            if (index >= 0) { let _ = listeners.remove(at: index) }
        }
    }

    private func retainCleanupCreditLocked(frames: Array<Http2Frame>): Unit {
        for (frame in frames) {
            let increment = decodeHttp2WindowUpdate(frame)
            if (increment > UInt32(2147483647) - deferredConnectionCredit) {
                throw IllegalStateException("HTTP/2 deferred reset credit overflow")
            }
            deferredConnectionCredit += increment
        }
    }

    private func flushDeferredCreditLocked(): Bool {
        if (deferredConnectionCredit == 0u32) { return true }
        let frame = encodeHttp2WindowUpdate(Http2StreamId(0u32), deferredConnectionCredit)
        try {
            let _ = writer.enqueue(frame)
            deferredConnectionCredit = 0u32
            true
        } catch (_: Http2WriteQueueFullException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
    }

    private func claimListenerLocked(streamId: Http2StreamId): ?Http2StreamResetListener {
        let index = findListenerIndexLocked(streamId)
        if (index < 0) { None<Http2StreamResetListener> }
        else { Some(listeners.remove(at: index).listener) }
    }

    private func findListenerIndexLocked(streamId: Http2StreamId): Int64 {
        for (index in 0..listeners.size) {
            if (listeners[index].streamId.value == streamId.value) { return index }
        }
        -1
    }
}

private class Http2ResetListenerEntry {
    let streamId: Http2StreamId
    let listener: Http2StreamResetListener
    init(streamId: Http2StreamId, listener: Http2StreamResetListener) {
        this.streamId = streamId
        this.listener = listener
    }
}

public func encodeHttp2RstStream(streamId: Http2StreamId, code: Http2ErrorCode): Http2Frame {
    if (!streamId.isStream()) { throw IllegalArgumentException("HTTP/2 RST_STREAM requires a non-zero stream") }
    let value = http2ErrorCodeToWire(code)
    Http2Frame(
        Http2FrameHeader(4u32, Http2FrameType.RstStream, Http2Flags(), streamId),
        [
            UInt8((value >> 24) & 0xffu32), UInt8((value >> 16) & 0xffu32),
            UInt8((value >> 8) & 0xffu32), UInt8(value & 0xffu32)
        ]
    )
}

public func decodeHttp2RstStream(frame: Http2Frame): Http2ErrorCode {
    if (http2FrameTypeCode(frame.header.frameType) != 3u8 || frame.payload.size != 4) {
        throw Http2ProtocolException(
            Http2ErrorCode.FrameSizeError, Http2ErrorScope.Connection,
            "HTTP/2 RST_STREAM payload must contain four bytes"
        )
    }
    let value = (UInt32(frame.payload[0]) << 24) | (UInt32(frame.payload[1]) << 16) |
        (UInt32(frame.payload[2]) << 8) | UInt32(frame.payload[3])
    http2ErrorCodeFromWire(value)
}

private func notifyResetListener(
    listener: ?Http2StreamResetListener,
    event: ?Http2StreamResetEvent
): Unit {
    if (let Some(target) <- listener) {
        if (let Some(value) <- event) {
            try { target.streamReset(value) } catch (_: Exception) {}
        }
    }
}

private func validateResetReason(value: String): Unit {
    if (value.toArray().size > HTTP2_RESET_REASON_LIMIT) {
        throw IllegalArgumentException("HTTP/2 reset reason exceeds its configured bound")
    }
}

private func isClosedReset(error: Http2ProtocolException): Bool {
    http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(Http2ErrorCode.StreamClosed)
}
