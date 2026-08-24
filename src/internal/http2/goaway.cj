package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*

/** Whether the peer's GOAWAY boundary proves that a request was not processed. */
public enum Http2GoAwayRequestDisposition {
    | DefinitelyNotProcessed
    | MayHaveBeenProcessed
}

/** Immutable evidence used by the HTTP retry policy; debug data is deliberately excluded. */
public class Http2GoAwayRetryEvidence {
    public let streamId: Http2StreamId
    public let lastStreamId: Http2StreamId
    public let errorCode: Http2ErrorCode
    public let disposition: Http2GoAwayRequestDisposition

    public init(
        streamId: Http2StreamId,
        lastStreamId: Http2StreamId,
        errorCode: Http2ErrorCode,
        disposition: Http2GoAwayRequestDisposition
    ) {
        if (!streamId.isStream()) { throw IllegalArgumentException("HTTP/2 GOAWAY evidence requires a stream") }
        this.streamId = streamId
        this.lastStreamId = lastStreamId
        this.errorCode = errorCode
        this.disposition = disposition
    }

    public prop definitelyNotProcessed: Bool {
        get() {
            match (disposition) {
                case Http2GoAwayRequestDisposition.DefinitelyNotProcessed => true
                case Http2GoAwayRequestDisposition.MayHaveBeenProcessed => false
            }
        }
    }
}

/** Stream-scoped GOAWAY failure retaining only bounded protocol/retry evidence. */
public class Http2GoAwayException <: Exception {
    public let evidence: Http2GoAwayRetryEvidence

    public init(evidence: Http2GoAwayRetryEvidence) {
        super("HTTP/2 peer GOAWAY excluded this request stream")
        this.evidence = evidence
    }

    protected override func getClassName(): String { "Http2GoAwayException" }
}

/** Request owner wakeup. Implementations must not block the connection reader. */
public interface Http2GoAwayListener {
    func connectionGoAway(error: Http2GoAwayException): Unit
}

public class Http2GoAwayRegistration {
    private let manager: Http2GoAwayManager
    private let streamId: Http2StreamId
    private let removed = AtomicBool(false)

    internal init(manager: Http2GoAwayManager, streamId: Http2StreamId) {
        this.manager = manager
        this.streamId = streamId
    }

    public func unregister(): Unit {
        if (removed.compareAndSwap(false, true)) { manager.unregister(streamId) }
    }
}

/** One stream admission plus its removable GOAWAY wakeup registration. */
public class Http2GoAwayStreamAdmission {
    public let stream: Http2StreamStateMachine
    public let registration: Http2GoAwayRegistration

    internal init(stream: Http2StreamStateMachine, registration: Http2GoAwayRegistration) {
        this.stream = stream
        this.registration = registration
    }
}

/**
 * Coordinates GOAWAY admission, unprocessed-stream cleanup and retry evidence.
 * Listener state is bounded by maxConcurrentStreams; callbacks run without the
 * coordinator lock and cannot disrupt the single reader.
 */
public class Http2GoAwayManager {
    private let machine: Http2ConnectionStateMachine
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let listenerLimit: Int64
    private let mutex = Mutex()
    private let listeners = ArrayList<Http2GoAwayListenerEntry>()
    private var remote: ?Http2GoAway = None<Http2GoAway>
    private var deferredConnectionCredit: UInt32 = 0u32

    public prop activeListenerCount: Int64 { get() { synchronized(mutex) { listeners.size } } }
    public prop remoteGoAway: ?Http2GoAway { get() { synchronized(mutex) { remote } } }
    public prop acceptingNewStreams: Bool {
        get() {
            synchronized(mutex) {
                match (machine.phase) { case Http2ConnectionPhase.Open => true; case _ => false }
            }
        }
    }
    public prop deferredCredit: UInt32 { get() { synchronized(mutex) { deferredConnectionCredit } } }

    public init(
        machine: Http2ConnectionStateMachine,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        limits!: Http2Limits = Http2Limits()
    ) {
        this.machine = machine
        this.registry = registry
        this.flow = flow
        this.writer = writer
        listenerLimit = Int64(limits.maxConcurrentStreams)
    }

    /** Atomically opens flow/lifecycle state and installs its bounded GOAWAY owner. */
    public func openLocal(
        listener: Http2GoAwayListener,
        endStream!: Bool = false
    ): Http2GoAwayStreamAdmission {
        synchronized(mutex) {
            if (listeners.size >= listenerLimit) {
                throw Http2StreamLimitException("HTTP/2 GOAWAY listener limit reached")
            }
            let stream = machine.openLocalStream(registry, endStream: endStream)
            try {
                flow.openStream(stream.id)
            } catch (error: Exception) {
                let _ = registry.reset(stream.id, Http2ErrorCode.InternalError, "HTTP/2 stream admission rolled back")
                throw error
            }
            listeners.add(Http2GoAwayListenerEntry(stream.id, listener))
            Http2GoAwayStreamAdmission(stream, Http2GoAwayRegistration(this, stream.id))
        }
    }

    /** Starts local draining before queueing GOAWAY, so queue pressure cannot admit another stream. */
    public func beginLocalDrain(
        lastStreamId!: ?Http2StreamId = None<Http2StreamId>,
        code!: Http2ErrorCode = Http2ErrorCode.NoError,
        debugData!: Array<Byte> = []
    ): Http2WriteTicket {
        synchronized(mutex) {
            writer.enqueue(machine.beginDrain(lastStreamId: lastStreamId, code: code, debugData: debugData))
        }
    }

    /**
     * Applies the GOAWAY produced by the state machine's serialized receive path.
     * Streams above the boundary are proven unprocessed, cancelled locally and
     * woken exactly once. Streams at/below it continue draining.
     */
    public func acceptPeer(result: Http2ConnectionReceiveResult): Int64 {
        let goAway = match (result.peerGoAway) {
            case Some(value) => value
            case None => return 0
        }
        let notifications = synchronized(mutex) {
            let observed = match (machine.remoteGoAway) {
                case Some(value) => value
                case None => throw IllegalStateException(
                    "HTTP/2 GOAWAY manager requires state-machine receive evidence"
                )
            }
            if (observed.lastStreamId.value != goAway.lastStreamId.value ||
                http2ErrorCodeToWire(observed.errorCode) != http2ErrorCodeToWire(goAway.errorCode)) {
                throw IllegalArgumentException("HTTP/2 GOAWAY result does not match connection state")
            }
            if (let Some(previous) <- remote) {
                if (goAway.lastStreamId.value > previous.lastStreamId.value) {
                    throw IllegalArgumentException("HTTP/2 GOAWAY boundary cannot increase")
                }
            }
            remote = Some(goAway)
            let claimed = ArrayList<Http2GoAwayNotification>()
            var index: Int64 = listeners.size - 1
            while (index >= 0) {
                let entry = listeners[index]
                if (entry.streamId.value > goAway.lastStreamId.value) {
                    let removed = listeners.remove(at: index)
                    retireUnprocessedLocked(removed.streamId)
                    claimed.add(Http2GoAwayNotification(
                        removed.listener,
                        Http2GoAwayException(Http2GoAwayRetryEvidence(
                            removed.streamId,
                            goAway.lastStreamId,
                            goAway.errorCode,
                            Http2GoAwayRequestDisposition.DefinitelyNotProcessed
                        ))
                    ))
                }
                index -= 1
            }
            let _ = flushDeferredCreditLocked()
            claimed.toArray()
        }
        for (notification in notifications) {
            try { notification.listener.connectionGoAway(notification.error) } catch (_: Exception) {}
        }
        notifications.size
    }

    /** Classifies an existing request without implying that policy permits retry. */
    public func evidenceFor(streamId: Http2StreamId): ?Http2GoAwayRetryEvidence {
        synchronized(mutex) {
            match (remote) {
                case None => None<Http2GoAwayRetryEvidence>
                case Some(value) => Some(Http2GoAwayRetryEvidence(
                    streamId,
                    value.lastStreamId,
                    value.errorCode,
                    if (streamId.value > value.lastStreamId.value) {
                        Http2GoAwayRequestDisposition.DefinitelyNotProcessed
                    } else {
                        Http2GoAwayRequestDisposition.MayHaveBeenProcessed
                    }
                ))
            }
        }
    }

    /** Retries aggregated connection credit after bounded writer capacity returns. */
    public func flush(): Bool { synchronized(mutex) { flushDeferredCreditLocked() } }

    internal func unregister(streamId: Http2StreamId): Unit {
        synchronized(mutex) {
            let index = findListenerIndexLocked(streamId)
            if (index >= 0) { let _ = listeners.remove(at: index) }
        }
    }

    private func retireUnprocessedLocked(streamId: Http2StreamId): Unit {
        if (registry.stream(streamId).isSome()) {
            try {
                let _ = registry.reset(
                    streamId, Http2ErrorCode.RefusedStream, "HTTP/2 peer GOAWAY did not process this stream"
                )
            } catch (error: Http2ProtocolException) {
                if (http2ErrorCodeToWire(error.code) != http2ErrorCodeToWire(Http2ErrorCode.StreamClosed)) {
                    throw error
                }
            }
        }
        let _ = writer.cancelStream(streamId)
        retainCleanupCreditLocked(flow.closeStream(streamId))
    }

    private func retainCleanupCreditLocked(frames: Array<Http2Frame>): Unit {
        for (frame in frames) {
            let increment = decodeHttp2WindowUpdate(frame)
            if (increment > UInt32(2147483647) - deferredConnectionCredit) {
                throw IllegalStateException("HTTP/2 deferred GOAWAY credit overflow")
            }
            deferredConnectionCredit += increment
        }
    }

    private func flushDeferredCreditLocked(): Bool {
        if (deferredConnectionCredit == 0u32) { return true }
        try {
            let _ = writer.enqueue(encodeHttp2WindowUpdate(Http2StreamId(0u32), deferredConnectionCredit))
            deferredConnectionCredit = 0u32
            true
        } catch (_: Http2WriteQueueFullException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
    }

    private func findListenerIndexLocked(streamId: Http2StreamId): Int64 {
        for (index in 0..listeners.size) {
            if (listeners[index].streamId.value == streamId.value) { return index }
        }
        -1
    }
}

private class Http2GoAwayListenerEntry {
    let streamId: Http2StreamId
    let listener: Http2GoAwayListener
    init(streamId: Http2StreamId, listener: Http2GoAwayListener) {
        this.streamId = streamId
        this.listener = listener
    }
}

private class Http2GoAwayNotification {
    let listener: Http2GoAwayListener
    let error: Http2GoAwayException
    init(listener: Http2GoAwayListener, error: Http2GoAwayException) {
        this.listener = listener
        this.error = error
    }
}
