package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.Mutex

public enum Http2StreamState {
    | Idle
    | Open
    | HalfClosedLocal
    | HalfClosedRemote
    | Closed
}

public enum Http2StreamInitiator {
    | Local
    | Peer
}

/** Immutable terminal evidence retained by a stream after registry cleanup. */
public class Http2StreamCompletion {
    public let code: Http2ErrorCode
    public let reason: String

    public init(code: Http2ErrorCode, reason: String) {
        this.code = code
        this.reason = reason
    }
}

public class Http2StreamLimitException <: Exception {
    public init(message: String) { super(message) }
    protected override func getClassName(): String { "Http2StreamLimitException" }
}

/**
 * One RFC 9113 stream state machine.
 *
 * State is independently synchronized so a connection terminal event may race
 * either END_STREAM direction without double completion. Registry mutation is
 * deliberately separate and never occurs while this lock is held.
 */
public class Http2StreamStateMachine {
    public let id: Http2StreamId
    public let initiator: Http2StreamInitiator
    private let mutex = Mutex()
    private var current = Http2StreamState.Idle
    private var terminal: ?Http2StreamCompletion = None<Http2StreamCompletion>
    private var terminalTransitions: Int64 = 0

    public prop state: Http2StreamState { get() { synchronized(mutex) { current } } }
    public prop completion: ?Http2StreamCompletion { get() { synchronized(mutex) { terminal } } }
    public prop completionCount: Int64 { get() { synchronized(mutex) { terminalTransitions } } }

    internal init(id: Http2StreamId, initiator: Http2StreamInitiator) {
        if (!id.isStream()) { throw IllegalArgumentException("HTTP/2 stream id must be non-zero") }
        this.id = id
        this.initiator = initiator
    }

    /** Opens an idle stream; an initial END_STREAM half-closes its sender. */
    internal func open(endStream: Bool): Unit {
        synchronized(mutex) {
            if (!isStreamIdle(current)) { invalidLocalStreamState("HTTP/2 stream was already opened") }
            current = if (!endStream) { Http2StreamState.Open }
                else if (isLocalInitiator(initiator)) { Http2StreamState.HalfClosedLocal }
                else { Http2StreamState.HalfClosedRemote }
        }
    }

    /** Applies a locally sent END_STREAM and returns whether this closed the stream. */
    internal func localEnd(): Bool {
        synchronized(mutex) {
            match (current) {
                case Http2StreamState.Open => current = Http2StreamState.HalfClosedLocal; false
                case Http2StreamState.HalfClosedRemote => completeLocked(
                    Http2ErrorCode.NoError, "HTTP/2 stream completed normally"
                )
                case Http2StreamState.Idle => invalidLocalStreamState("HTTP/2 idle stream cannot send END_STREAM")
                case Http2StreamState.HalfClosedLocal =>
                    invalidLocalStreamState("HTTP/2 local stream side is already closed")
                case Http2StreamState.Closed => invalidLocalStreamState("HTTP/2 stream is closed")
            }
        }
    }

    /** Applies a peer END_STREAM and returns whether this closed the stream. */
    internal func peerEnd(): Bool {
        synchronized(mutex) {
            match (current) {
                case Http2StreamState.Open => current = Http2StreamState.HalfClosedRemote; false
                case Http2StreamState.HalfClosedLocal => completeLocked(
                    Http2ErrorCode.NoError, "HTTP/2 stream completed normally"
                )
                case Http2StreamState.Idle => throw streamProtocolFailure(
                    id, Http2ErrorCode.ProtocolError, "HTTP/2 idle stream cannot receive END_STREAM"
                )
                case Http2StreamState.HalfClosedRemote => throw streamProtocolFailure(
                    id, Http2ErrorCode.StreamClosed, "HTTP/2 remote stream side is already closed"
                )
                case Http2StreamState.Closed => throw streamProtocolFailure(
                    id, Http2ErrorCode.StreamClosed, "HTTP/2 stream is closed"
                )
            }
        }
    }

    /** RST_STREAM is terminal and idempotent against all other terminal races. */
    internal func reset(code: Http2ErrorCode, reason: String): Bool {
        synchronized(mutex) {
            if (isStreamIdle(current)) {
                throw streamProtocolFailure(id, Http2ErrorCode.ProtocolError, "HTTP/2 idle stream cannot be reset")
            }
            completeLocked(code, reason)
        }
    }

    /** Connection termination closes every live stream exactly once. */
    internal func connectionTerminated(completion: Http2ConnectionCompletion): Bool {
        synchronized(mutex) { completeLocked(completion.code, completion.reason) }
    }

    private func completeLocked(code: Http2ErrorCode, reason: String): Bool {
        if (isStreamClosed(current)) { return false }
        current = Http2StreamState.Closed
        terminal = Some(Http2StreamCompletion(code, reason))
        terminalTransitions += 1
        true
    }
}

/**
 * Bounded active-stream registry for one HTTP/2 connection.
 *
 * Closed streams are removed immediately. Only the greatest peer id and the
 * next local id are retained, so rejecting reused/skipped ids requires O(1)
 * metadata rather than an unbounded closed-stream tombstone set.
 */
public class Http2StreamRegistry <: Http2ReaderTerminationListener {
    private let role: Http2ConnectionRole
    private let hardMaximum: UInt32
    private let mutex = Mutex()
    private let streams = ArrayList<Http2ManagedStream>()
    private var localMaximum: UInt32
    private var peerMaximum: UInt32
    private var nextLocalId: UInt32
    private var localIdsExhausted = false
    private var greatestPeerId: UInt32 = 0u32
    private var terminal: ?Http2ConnectionCompletion = None<Http2ConnectionCompletion>
    private var readerRegistration: ?Http2ReaderTerminationRegistration = None<Http2ReaderTerminationRegistration>

    public prop activeCount: Int64 { get() { synchronized(mutex) { streams.size } } }
    public prop activeLocalCount: Int64 { get() { synchronized(mutex) { countInitiatorLocked(true) } } }
    public prop activePeerCount: Int64 { get() { synchronized(mutex) { countInitiatorLocked(false) } } }
    public prop peerMaxConcurrentStreams: UInt32 { get() { synchronized(mutex) { peerMaximum } } }
    public prop completion: ?Http2ConnectionCompletion { get() { synchronized(mutex) { terminal } } }

    public init(
        role: Http2ConnectionRole,
        limits!: Http2Limits = Http2Limits(),
        terminationRegistry!: ?Http2ReaderTerminationRegistry = None<Http2ReaderTerminationRegistry>
    ) {
        this.role = role
        hardMaximum = limits.maxConcurrentStreams
        localMaximum = limits.maxConcurrentStreams
        peerMaximum = limits.maxConcurrentStreams
        nextLocalId = if (isStreamClient(role)) { 1u32 } else { 2u32 }
        if (let Some(registry) <- terminationRegistry) {
            let registration = registry.register(this)
            let discard = synchronized(mutex) {
                if (terminal.isSome()) { true }
                else { readerRegistration = Some(registration); false }
            }
            if (discard) { registration.unregister() }
        }
    }

    /** Applies the peer's current SETTINGS_MAX_CONCURRENT_STREAMS to new local streams. */
    public func updatePeerMaxConcurrentStreams(value: UInt32): Unit {
        synchronized(mutex) { peerMaximum = min(value, hardMaximum) }
    }

    /** Applies the locally advertised bound to subsequently opened peer streams. */
    public func updateLocalMaxConcurrentStreams(value: UInt32): Unit {
        synchronized(mutex) { localMaximum = min(value, hardMaximum) }
    }

    /** Allocates the next role-correct stream id and admits it under the peer limit. */
    public func openLocal(endStream!: Bool = false): Http2StreamStateMachine {
        synchronized(mutex) {
            requireRegistryOpenLocked()
            if (countInitiatorLocked(true) >= Int64(peerMaximum)) {
                throw Http2StreamLimitException("HTTP/2 peer concurrent stream limit reached")
            }
            if (localIdsExhausted) { throw Http2StreamLimitException("HTTP/2 local stream ids are exhausted") }
            let id = nextLocalId
            if (id > 2147483645u32) { localIdsExhausted = true } else { nextLocalId += 2u32 }
            addStreamLocked(Http2StreamId(id), Http2StreamInitiator.Local, endStream)
        }
    }

    /** Admits a strictly increasing, role-correct peer stream under the local limit. */
    public func openPeer(streamId: Http2StreamId, endStream!: Bool = false): Http2StreamStateMachine {
        synchronized(mutex) {
            requireRegistryOpenLocked()
            requirePeerStreamIdLocked(streamId)
            if (streamId.value <= greatestPeerId) {
                throw streamConnectionFailure("HTTP/2 peer stream ids must increase monotonically")
            }
            // A refused stream id is still consumed. Retaining the greatest id
            // prevents a peer from repeatedly retrying one id without keeping
            // an unbounded tombstone for each refusal.
            greatestPeerId = streamId.value
            if (countInitiatorLocked(false) >= Int64(localMaximum)) {
                throw streamProtocolFailure(
                    streamId, Http2ErrorCode.RefusedStream, "HTTP/2 local concurrent stream limit reached"
                )
            }
            addStreamLocked(streamId, Http2StreamInitiator.Peer, endStream)
        }
    }

    public func stream(streamId: Http2StreamId): ?Http2StreamStateMachine {
        synchronized(mutex) {
            match (findStreamLocked(streamId)) {
                case Some(value) => Some(value.machine)
                case None => None<Http2StreamStateMachine>
            }
        }
    }

    public func localEnd(streamId: Http2StreamId): Unit {
        let managed = requireActiveStream(streamId, false)
        let _ = managed.machine.localEnd()
        cleanupClosed(streamId, managed.machine)
    }

    public func peerEnd(streamId: Http2StreamId): Unit {
        let managed = requireActiveStream(streamId, true)
        let _ = managed.machine.peerEnd()
        cleanupClosed(streamId, managed.machine)
    }

    /** M6-015 owns RST emission; this method provides its terminal lifecycle primitive. */
    public func reset(streamId: Http2StreamId, code: Http2ErrorCode, reason: String): Bool {
        let managed = requireActiveStream(streamId, true)
        let won = managed.machine.reset(code, reason)
        cleanupClosed(streamId, managed.machine)
        won
    }

    /** Idempotently closes and removes every active stream. */
    public func closeConnection(completion: Http2ConnectionCompletion): Bool {
        let (won, claimed, registration) = synchronized(mutex) {
            if (terminal.isSome()) {
                (false, Array<Http2ManagedStream>(), None<Http2ReaderTerminationRegistration>)
            } else {
                terminal = Some(completion)
                let result = streams.toArray()
                streams.clear()
                let currentRegistration = readerRegistration
                readerRegistration = None<Http2ReaderTerminationRegistration>
                (true, result, currentRegistration)
            }
        }
        if (let Some(value) <- registration) { value.unregister() }
        for (managed in claimed) { let _ = managed.machine.connectionTerminated(completion) }
        won
    }

    public func readerTerminated(completion: Http2ConnectionCompletion): Unit {
        let _ = closeConnection(completion)
    }

    private func addStreamLocked(
        id: Http2StreamId,
        initiator: Http2StreamInitiator,
        endStream: Bool
    ): Http2StreamStateMachine {
        let machine = Http2StreamStateMachine(id, initiator)
        machine.open(endStream)
        streams.add(Http2ManagedStream(machine))
        machine
    }

    private func requireActiveStream(streamId: Http2StreamId, peerOperation: Bool): Http2ManagedStream {
        synchronized(mutex) {
            match (findStreamLocked(streamId)) {
                case Some(value) => value
                case None =>
                    if (peerOperation) {
                        throw missingPeerStreamFailureLocked(streamId)
                    }
                    invalidLocalStreamState("HTTP/2 stream is not active")
            }
        }
    }

    private func cleanupClosed(streamId: Http2StreamId, machine: Http2StreamStateMachine): Unit {
        if (!isStreamClosed(machine.state)) { return }
        synchronized(mutex) {
            for (index in 0..streams.size) {
                if (streams[index].machine.id.value == streamId.value) {
                    let _ = streams.remove(at: index)
                    return
                }
            }
        }
    }

    private func findStreamLocked(streamId: Http2StreamId): ?Http2ManagedStream {
        for (managed in streams) {
            if (managed.machine.id.value == streamId.value) { return Some(managed) }
        }
        None<Http2ManagedStream>
    }

    private func countInitiatorLocked(local: Bool): Int64 {
        var count: Int64 = 0
        for (managed in streams) {
            if (isLocalInitiator(managed.machine.initiator) == local) { count += 1 }
        }
        count
    }

    private func requireRegistryOpenLocked(): Unit {
        if (terminal.isSome()) { throw IllegalStateException("HTTP/2 connection stream registry is closed") }
    }

    private func requirePeerStreamIdLocked(streamId: Http2StreamId): Unit {
        if (!streamId.isStream()) { throw streamConnectionFailure("HTTP/2 peer stream id must be non-zero") }
        let expectedOdd = !isStreamClient(role)
        if (((streamId.value & 1u32) == 1u32) != expectedOdd) {
            throw streamConnectionFailure("HTTP/2 peer stream id has the wrong initiator parity")
        }
    }

    private func missingPeerStreamFailureLocked(streamId: Http2StreamId): Http2ProtocolException {
        if (!streamId.isStream()) { return streamConnectionFailure("HTTP/2 frame cannot end stream zero") }
        let peerOdd = !isStreamClient(role)
        let actualOdd = (streamId.value & 1u32) == 1u32
        let isUnused = if (actualOdd == peerOdd) { streamId.value > greatestPeerId }
            else { !localIdsExhausted && streamId.value >= nextLocalId }
        if (isUnused) { return streamConnectionFailure("HTTP/2 frame referenced an idle stream") }
        streamProtocolFailure(streamId, Http2ErrorCode.StreamClosed, "HTTP/2 stream is not active")
    }
}

private class Http2ManagedStream {
    let machine: Http2StreamStateMachine
    init(machine: Http2StreamStateMachine) { this.machine = machine }
}

private func invalidLocalStreamState(message: String): Nothing { throw IllegalStateException(message) }

private func streamConnectionFailure(message: String): Http2ProtocolException {
    Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection, message)
}

private func streamProtocolFailure(
    streamId: Http2StreamId,
    code: Http2ErrorCode,
    message: String
): Http2ProtocolException {
    Http2ProtocolException(code, Http2ErrorScope.Stream(streamId), message)
}

private func isLocalInitiator(value: Http2StreamInitiator): Bool {
    match (value) { case Http2StreamInitiator.Local => true; case _ => false }
}

private func isStreamClient(value: Http2ConnectionRole): Bool {
    match (value) { case Http2ConnectionRole.Client => true; case _ => false }
}

private func isStreamIdle(value: Http2StreamState): Bool {
    match (value) { case Http2StreamState.Idle => true; case _ => false }
}

private func isStreamClosed(value: Http2StreamState): Bool {
    match (value) { case Http2StreamState.Closed => true; case _ => false }
}
