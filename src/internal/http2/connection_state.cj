package wirestack.internal.http2

import std.sync.Mutex

public enum Http2ConnectionRole {
    | Client
    | Server
}

public enum Http2ConnectionPhase {
    | Preface
    | Open
    | Draining
    | Closed
}

/** Immutable terminal evidence retained exactly once. */
public class Http2ConnectionCompletion {
    public let code: Http2ErrorCode
    public let reason: String

    public init(code: Http2ErrorCode, reason: String) {
        this.code = code
        this.reason = reason
    }
}

/** Decoded GOAWAY payload with owned debug data. */
public class Http2GoAway {
    public let lastStreamId: Http2StreamId
    public let errorCode: Http2ErrorCode
    private let ownedDebugData: Array<Byte>

    public prop debugData: Array<Byte> { get() { ownedDebugData.clone() } }

    public init(lastStreamId: Http2StreamId, errorCode: Http2ErrorCode, debugData: Array<Byte>) {
        this.lastStreamId = lastStreamId
        this.errorCode = errorCode
        ownedDebugData = debugData.clone()
    }
}

/** One connection-level receive result; all returned collections are owned. */
public class Http2ConnectionReceiveResult {
    private let ownedOutbound: Array<Http2Frame>
    public let headerBlock: ?Http2HeaderBlock
    public let peerGoAway: ?Http2GoAway

    public prop outbound: Array<Http2Frame> { get() { ownedOutbound.clone() } }

    public init(
        outbound: Array<Http2Frame>,
        headerBlock!: ?Http2HeaderBlock = None<Http2HeaderBlock>,
        peerGoAway!: ?Http2GoAway = None<Http2GoAway>
    ) {
        ownedOutbound = outbound.clone()
        this.headerBlock = headerBlock
        this.peerGoAway = peerGoAway
    }
}

/**
 * Serialized HTTP/2 connection state independent of transport I/O.
 *
 * A future reader loop owns `receive`; local drain/close may race it, so every
 * phase and completion transition is protected and terminal evidence is set at
 * most once.
 */
public class Http2ConnectionStateMachine {
    private let role: Http2ConnectionRole
    private let limits: Http2Limits
    private let mutex = Mutex()
    private let settingsState: Http2SettingsState
    private let headerAssembler: Http2HeaderBlockAssembler
    private var phaseState = Http2ConnectionPhase.Preface
    private var localStarted = false
    private var prefaceReceived: Int64
    private var peerInitialSettings = false
    private var terminalState: ?Http2ConnectionCompletion = None<Http2ConnectionCompletion>
    private var terminalTransitions: Int64 = 0
    private var terminalGoAway: ?Http2Frame = None<Http2Frame>
    private var localGoAwayLast: ?Http2StreamId = None<Http2StreamId>
    private var remoteGoAwayState: ?Http2GoAway = None<Http2GoAway>
    private var lastProcessedPeerStream = Http2StreamId(0u32)

    public prop phase: Http2ConnectionPhase { get() { synchronized(mutex) { phaseState } } }
    public prop peerPrefaceComplete: Bool {
        get() { synchronized(mutex) { prefaceReceived == http2ClientPreface().size } }
    }
    public prop completion: ?Http2ConnectionCompletion { get() { synchronized(mutex) { terminalState } } }
    public prop completionCount: Int64 { get() { synchronized(mutex) { terminalTransitions } } }
    public prop peerSettings: Http2SettingsSnapshot { get() { synchronized(mutex) { settingsState.peer } } }
    public prop remoteGoAway: ?Http2GoAway { get() { synchronized(mutex) { remoteGoAwayState } } }

    public init(role: Http2ConnectionRole, limits!: Http2Limits = Http2Limits()) {
        this.role = role
        this.limits = limits
        settingsState = Http2SettingsState(limits: limits)
        headerAssembler = Http2HeaderBlockAssembler(limits: limits)
        prefaceReceived = if (isClient(role)) { http2ClientPreface().size } else { 0 }
    }

    /** Emits the client magic (client only) plus the mandatory initial SETTINGS exactly once. */
    public func start(settings!: Array<Http2Setting> = []): Array<Byte> {
        synchronized(mutex) {
            requireNotClosedLocked()
            if (localStarted) { throw IllegalStateException("HTTP/2 connection was already started") }
            localStarted = true
            let prefix = if (isClient(role)) { http2ClientPreface() } else { Array<Byte>() }
            let frame = settingsState.sendLocal(settings)
            let encoded = serializeHttp2Frame(frame)
            let output = Array<Byte>(prefix.size + encoded.size, repeat: 0u8)
            for (index in 0..prefix.size) { output[index] = prefix[index] }
            for (index in 0..encoded.size) { output[prefix.size + index] = encoded[index] }
            output
        }
    }

    /**
     * Incrementally consumes only the 24-byte client magic. The caller retains
     * any bytes after the returned count for the frame parser.
     */
    public func acceptClientPreface(input: Array<Byte>): Int64 {
        try {
            synchronized(mutex) {
                requireNotClosedLocked()
                if (isClient(role)) { throw IllegalStateException("HTTP/2 clients do not receive client prefaces") }
                let expected = http2ClientPreface()
                if (prefaceReceived == expected.size) {
                    throw IllegalStateException("HTTP/2 client preface is already complete")
                }
                let count = min(input.size, expected.size - prefaceReceived)
                for (index in 0..count) {
                    if (input[index] != expected[prefaceReceived + index]) {
                        throw Http2ProtocolException(
                            Http2ErrorCode.ProtocolError,
                            Http2ErrorScope.Connection,
                            "HTTP/2 client preface does not match the required magic"
                        )
                    }
                }
                prefaceReceived += count
                count
            }
        } catch (error: Http2ProtocolException) {
            synchronized(mutex) { failLocked(error.code, error.message) }
            throw error
        }
    }

    /** Receives one already shape-validated frame from the single reader path. */
    public func receive(frame: Http2Frame): Http2ConnectionReceiveResult {
        try {
            synchronized(mutex) { receiveLocked(frame) }
        } catch (error: Http2ProtocolException) {
            synchronized(mutex) { failLocked(error.code, error.message) }
            throw error
        } catch (error: HpackException) {
            synchronized(mutex) { failLocked(Http2ErrorCode.CompressionError, error.message) }
            throw Http2ProtocolException(Http2ErrorCode.CompressionError, Http2ErrorScope.Connection, error.message)
        }
    }

    /** Records a fully accepted peer-created stream for the next local GOAWAY boundary. */
    public func markPeerStreamProcessed(streamId: Http2StreamId): Unit {
        synchronized(mutex) {
            requireNotClosedLocked()
            requirePeerInitiatedStream(streamId)
            if (streamId.value < lastProcessedPeerStream.value) {
                throw IllegalArgumentException("HTTP/2 processed peer stream ids must be monotonic")
            }
            lastProcessedPeerStream = streamId
        }
    }

    /**
     * Atomically admits one locally initiated stream only while the connection
     * is open. Serializing this check with GOAWAY reception closes the
     * check-then-open race that a pool-level phase snapshot cannot close.
     */
    public func openLocalStream(
        registry: Http2StreamRegistry,
        endStream!: Bool = false
    ): Http2StreamStateMachine {
        synchronized(mutex) {
            requireOpenForNewStreamLocked()
            registry.openLocal(endStream: endStream)
        }
    }

    /** Atomically admits a peer stream only before local or remote draining starts. */
    public func openPeerStream(
        registry: Http2StreamRegistry,
        streamId: Http2StreamId,
        endStream!: Bool = false
    ): Http2StreamStateMachine {
        synchronized(mutex) {
            requireOpenForNewStreamLocked()
            registry.openPeer(streamId, endStream: endStream)
        }
    }

    /** Starts or narrows graceful drain and returns the corresponding GOAWAY. */
    public func beginDrain(
        lastStreamId!: ?Http2StreamId = None<Http2StreamId>,
        code!: Http2ErrorCode = Http2ErrorCode.NoError,
        debugData!: Array<Byte> = []
    ): Http2Frame {
        synchronized(mutex) {
            requireNotClosedLocked()
            let boundary = match (lastStreamId) {
                case Some(value) => value
                case None => lastProcessedPeerStream
            }
            requirePeerInitiatedStreamOrZero(boundary)
            if (let Some(previous) <- localGoAwayLast) {
                if (boundary.value > previous.value) {
                    throw IllegalArgumentException("HTTP/2 GOAWAY boundary cannot increase while draining")
                }
            }
            let frame = encodeHttp2GoAway(Http2GoAway(boundary, code, debugData), limits: limits)
            localGoAwayLast = Some(boundary)
            phaseState = Http2ConnectionPhase.Draining
            frame
        }
    }

    /** Completes transport teardown; exactly one racing caller wins. */
    public func finish(
        code!: Http2ErrorCode = Http2ErrorCode.NoError,
        reason!: String = "HTTP/2 connection closed"
    ): Bool {
        synchronized(mutex) { completeLocked(code, reason) }
    }

    /** Records a locally detected connection error and publishes one terminal GOAWAY. */
    public func failConnection(code: Http2ErrorCode, reason: String): Bool {
        synchronized(mutex) {
            if (terminalState.isSome()) { return false }
            failLocked(code, reason)
            true
        }
    }

    /** Takes the best-effort terminal GOAWAY generated by a connection error once. */
    public func takeTerminalGoAway(): ?Http2Frame {
        synchronized(mutex) {
            let frame = terminalGoAway
            terminalGoAway = None<Http2Frame>
            frame
        }
    }

    private func receiveLocked(frame: Http2Frame): Http2ConnectionReceiveResult {
        requireNotClosedLocked()
        if (prefaceReceived != http2ClientPreface().size) {
            connectionProtocolError("HTTP/2 frame arrived before the complete client preface")
        }
        if (!peerInitialSettings) {
            if (!isSettingsFrameType(frame.header.frameType) || frame.header.flags.isAck()) {
                connectionProtocolError("HTTP/2 peer's first frame must be a non-ACK SETTINGS frame")
            }
            let result = settingsState.receive(frame)
            let ack = match (result) {
                case Http2SettingsReceiveResult.Applied(update) => update.ack
                case Http2SettingsReceiveResult.Acknowledged(_) =>
                    throw IllegalStateException("unreachable initial SETTINGS acknowledgement")
            }
            peerInitialSettings = true
            phaseState = Http2ConnectionPhase.Open
            return Http2ConnectionReceiveResult([ack])
        }

        let headerBlock = headerAssembler.accept(frame)
        if (isSettingsFrameType(frame.header.frameType)) {
            let result = settingsState.receive(frame)
            return match (result) {
                case Http2SettingsReceiveResult.Applied(update) => Http2ConnectionReceiveResult([update.ack])
                case Http2SettingsReceiveResult.Acknowledged(_) => Http2ConnectionReceiveResult([])
            }
        }
        if (isGoAwayFrameType(frame.header.frameType)) {
            let decoded = decodeHttp2GoAway(frame)
            requireLocallyInitiatedStreamOrZero(decoded.lastStreamId)
            if (let Some(previous) <- remoteGoAwayState) {
                if (decoded.lastStreamId.value > previous.lastStreamId.value) {
                    connectionProtocolError("HTTP/2 peer GOAWAY boundary increased while draining")
                }
            }
            remoteGoAwayState = Some(decoded)
            phaseState = Http2ConnectionPhase.Draining
            return Http2ConnectionReceiveResult([], peerGoAway: Some(decoded))
        }
        Http2ConnectionReceiveResult([], headerBlock: headerBlock)
    }

    private func failLocked(code: Http2ErrorCode, reason: String): Unit {
        if (terminalState.isSome()) { return }
        terminalGoAway = Some(encodeHttp2GoAway(Http2GoAway(lastProcessedPeerStream, code, []), limits: limits))
        let _ = completeLocked(code, reason)
    }

    private func completeLocked(code: Http2ErrorCode, reason: String): Bool {
        if (terminalState.isSome()) { return false }
        terminalState = Some(Http2ConnectionCompletion(code, reason))
        terminalTransitions += 1
        phaseState = Http2ConnectionPhase.Closed
        true
    }

    private func requireNotClosedLocked(): Unit {
        if (isClosedPhase(phaseState)) { throw IllegalStateException("HTTP/2 connection is closed") }
    }

    private func requireOpenForNewStreamLocked(): Unit {
        match (phaseState) {
            case Http2ConnectionPhase.Open => ()
            case Http2ConnectionPhase.Preface =>
                throw IllegalStateException("HTTP/2 connection is not ready for new streams")
            case Http2ConnectionPhase.Draining =>
                throw IllegalStateException("HTTP/2 draining connection does not accept new streams")
            case Http2ConnectionPhase.Closed =>
                throw IllegalStateException("HTTP/2 connection is closed")
        }
    }

    private func requirePeerInitiatedStream(streamId: Http2StreamId): Unit {
        if (!streamId.isStream()) { throw IllegalArgumentException("HTTP/2 stream id must be non-zero") }
        requirePeerInitiatedStreamOrZero(streamId)
    }

    private func requirePeerInitiatedStreamOrZero(streamId: Http2StreamId): Unit {
        if (streamId.isConnection()) { return }
        let expectedOdd = !isClient(role)
        if (((streamId.value & 1u32) == 1u32) != expectedOdd) {
            throw IllegalArgumentException("HTTP/2 GOAWAY boundary is not a peer-initiated stream")
        }
    }

    private func requireLocallyInitiatedStreamOrZero(streamId: Http2StreamId): Unit {
        if (streamId.isConnection()) { return }
        let expectedOdd = isClient(role)
        if (((streamId.value & 1u32) == 1u32) != expectedOdd) {
            connectionProtocolError("HTTP/2 peer GOAWAY boundary is not a locally initiated stream")
        }
    }
}

public func http2ClientPreface(): Array<Byte> { "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".toArray() }

public func encodeHttp2GoAway(value: Http2GoAway, limits!: Http2Limits = Http2Limits()): Http2Frame {
    if (UInt64(value.debugData.size) + 8u64 > UInt64(limits.maxFrameSize)) {
        throw IllegalArgumentException("HTTP/2 GOAWAY debug data exceeds the configured frame limit")
    }
    let payload = Array<Byte>(8 + value.debugData.size, repeat: 0u8)
    writeUInt32(payload, 0, value.lastStreamId.value)
    writeUInt32(payload, 4, http2ErrorCodeToWire(value.errorCode))
    let debug = value.debugData
    for (index in 0..debug.size) { payload[8 + index] = debug[index] }
    Http2Frame(
        Http2FrameHeader(
            UInt32(payload.size), Http2FrameType.GoAway, Http2Flags(), Http2StreamId(0u32), limits: limits
        ),
        payload
    )
}

public func decodeHttp2GoAway(frame: Http2Frame): Http2GoAway {
    if (!isGoAwayFrameType(frame.header.frameType)) { throw IllegalArgumentException("expected HTTP/2 GOAWAY frame") }
    let payload = frame.payload
    let last = Http2StreamId.fromWire(readUInt32(payload, 0))
    let code = http2ErrorCodeFromWire(readUInt32(payload, 4))
    let debug = Array<Byte>(payload.size - 8, repeat: 0u8)
    for (index in 0..debug.size) { debug[index] = payload[8 + index] }
    Http2GoAway(last, code, debug)
}

private func readUInt32(input: Array<Byte>, offset: Int64): UInt32 {
    (UInt32(input[offset]) << 24) | (UInt32(input[offset + 1]) << 16) |
        (UInt32(input[offset + 2]) << 8) | UInt32(input[offset + 3])
}

private func writeUInt32(output: Array<Byte>, offset: Int64, value: UInt32): Unit {
    output[offset] = UInt8((value >> 24) & 0xffu32)
    output[offset + 1] = UInt8((value >> 16) & 0xffu32)
    output[offset + 2] = UInt8((value >> 8) & 0xffu32)
    output[offset + 3] = UInt8(value & 0xffu32)
}

private func connectionProtocolError(message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection, message)
}

private func isClient(role: Http2ConnectionRole): Bool {
    match (role) { case Http2ConnectionRole.Client => true; case _ => false }
}

private func isClosedPhase(phase: Http2ConnectionPhase): Bool {
    match (phase) { case Http2ConnectionPhase.Closed => true; case _ => false }
}

private func isSettingsFrameType(frameType: Http2FrameType): Bool {
    match (frameType) { case Http2FrameType.Settings => true; case _ => false }
}

private func isGoAwayFrameType(frameType: Http2FrameType): Bool {
    match (frameType) { case Http2FrameType.GoAway => true; case _ => false }
}
