package wirestack.internal.http2

import std.collection.ArrayList
import wirestack.internal as internal
import std.sync.*
import wirestack.internal.transport.*

/** One complete HTTP/2 frame with an owned, immutable payload. */
public class Http2Frame {
    public let header: Http2FrameHeader
    private let ownedPayload: Array<Byte>
    private let receivedBufferReservation: ?Http2ReceivedBufferReservation
    private let receiveBufferRejected: Bool
    private let receivedBufferClaimed = AtomicBool(false)

    public prop payload: Array<Byte> { get() { ownedPayload.clone() } }
    internal prop wasReceiveBufferRejected: Bool { get() { receiveBufferRejected } }

    public init(header: Http2FrameHeader, payload: Array<Byte>) {
        if (payload.size != Int64(header.length)) {
            throw IllegalArgumentException("HTTP/2 frame header length must equal its payload length")
        }
        this.header = header
        ownedPayload = payload.clone()
        receivedBufferReservation = None<Http2ReceivedBufferReservation>
        receiveBufferRejected = false
    }

    internal init(
        header: Http2FrameHeader,
        payload: Array<Byte>,
        reservation: ?Http2ReceivedBufferReservation,
        rejected: Bool,
        adoptPayload: Bool
    ) {
        if (rejected) {
            if (!payload.isEmpty() || !isDataFrameType(header.frameType)) {
                throw IllegalArgumentException("only refused DATA frames may omit their payload")
            }
        } else if (payload.size != Int64(header.length)) {
            throw IllegalArgumentException("HTTP/2 frame header length must equal its payload length")
        }
        if (reservation.isSome() && (!isDataFrameType(header.frameType) || rejected)) {
            throw IllegalArgumentException("receive-buffer reservation requires admitted DATA")
        }
        this.header = header
        ownedPayload = if (adoptPayload) { payload } else { payload.clone() }
        receivedBufferReservation = reservation
        receiveBufferRejected = rejected
    }

    internal func payloadView(): Array<Byte> { ownedPayload }

    internal func takeReceivedBufferReservation(): ?Http2ReceivedBufferReservation {
        match (receivedBufferReservation) {
            case Some(value) =>
                if (!receivedBufferClaimed.compareAndSwap(false, true)) {
                    throw IllegalStateException("HTTP/2 received-buffer reservation was already transferred")
                }
                Some(value)
            case None => None<Http2ReceivedBufferReservation>
        }
    }

    internal func releaseUnclaimedReceivedBufferReservation(): Unit {
        if (let Some(value) <- receivedBufferReservation) {
            if (receivedBufferClaimed.compareAndSwap(false, true)) { value.close() }
        }
    }
}

/** A receive DATA reservation transferred from the frame parser to its body owner. */
internal class Http2ReceivedBufferReservation {
    let bytes: UInt64
    private let budget: internal.HttpResourceBudget
    private let owner: internal.HttpResourceOwnerKey
    private let released = AtomicBool(false)

    init(budget: internal.HttpResourceBudget, owner: internal.HttpResourceOwnerKey, bytes: UInt64) {
        this.budget = budget
        this.owner = owner
        this.bytes = bytes
    }

    func close(): Unit {
        if (released.compareAndSwap(false, true)) { budget.releaseReceivedBuffer(owner, bytes) }
    }
}

/**
 * Incremental frame decoder.
 *
 * Input may end at any header or payload byte. Complete frames are returned in
 * wire order. DATA payload storage is admitted before allocation and transferred
 * with the frame to the retained body owner.
 */
public class Http2FrameParser {
    private let limits: Http2Limits
    private let resourceBudget: ?internal.HttpResourceBudget
    private let resourceOwner: ?internal.HttpResourceOwnerKey
    private let headerBytes = ArrayList<Byte>()
    private var payloadBytes: Array<Byte> = []
    private var payloadOffset: Int64 = 0
    private var currentHeader: ?Http2FrameHeader = None<Http2FrameHeader>
    private var currentReservation: ?Http2ReceivedBufferReservation =
        None<Http2ReceivedBufferReservation>
    private var rejectingDataPayload = false
    private var failed = false

    public init(limits!: Http2Limits = Http2Limits()) {
        this.limits = limits
        resourceBudget = None<internal.HttpResourceBudget>
        resourceOwner = None<internal.HttpResourceOwnerKey>
    }

    internal init(
        limits: Http2Limits,
        resourceBudget: ?internal.HttpResourceBudget,
        resourceOwner: ?internal.HttpResourceOwnerKey
    ) {
        if (resourceBudget.isSome() != resourceOwner.isSome()) {
            throw IllegalArgumentException("HTTP/2 parser budget and owner must be supplied together")
        }
        this.limits = limits
        this.resourceBudget = resourceBudget
        this.resourceOwner = resourceOwner
    }

    public func feed(input: Array<Byte>): Array<Http2Frame> {
        if (failed) { throw IllegalStateException("HTTP/2 frame parser cannot continue after a protocol error") }
        let frames = ArrayList<Http2Frame>()
        try {
            for (value in input) {
                match (currentHeader) {
                    case None =>
                        headerBytes.add(value)
                        if (headerBytes.size == 9) {
                            let header = decodeHttp2FrameHeader(headerBytes.toArray(), limits: limits)
                            currentHeader = Some(header)
                            headerBytes.clear()
                            if (isDataFrameType(header.frameType) && header.length > 0u32) {
                                if (let Some(budget) <- resourceBudget) {
                                    if (!budget.tryReserveReceivedBuffer(
                                        resourceOwner.getOrThrow(), UInt64(header.length)
                                    )) {
                                        rejectingDataPayload = true
                                    } else {
                                        currentReservation = Some(Http2ReceivedBufferReservation(
                                            budget, resourceOwner.getOrThrow(), UInt64(header.length)
                                        ))
                                    }
                                }
                            }
                            if (!rejectingDataPayload && header.length > 0u32) {
                                payloadBytes = Array<Byte>(Int64(header.length), repeat: 0u8)
                            }
                            if (header.length == 0u32) { finishFrame(frames, header) }
                        }
                    case Some(header) =>
                        if (!rejectingDataPayload) { payloadBytes[payloadOffset] = value }
                        payloadOffset++
                        if (payloadOffset == Int64(header.length)) { finishFrame(frames, header) }
                }
            }
        } catch (error: Exception) {
            failed = true
            for (frame in frames) { frame.releaseUnclaimedReceivedBufferReservation() }
            releasePartialFrame()
            throw error
        }
        frames.toArray()
    }

    public func hasIncompleteFrame(): Bool {
        !headerBytes.isEmpty() || currentHeader.isSome()
    }

    /** Releases a partial frame if the reader terminates before parser reuse. */
    internal func releasePartialFrame(): Unit {
        if (let Some(value) <- currentReservation) { value.close() }
        currentReservation = None<Http2ReceivedBufferReservation>
        currentHeader = None<Http2FrameHeader>
        payloadBytes = []
        payloadOffset = 0
        rejectingDataPayload = false
        headerBytes.clear()
    }

    private func finishFrame(frames: ArrayList<Http2Frame>, header: Http2FrameHeader): Unit {
        frames.add(Http2Frame(
            header,
            payloadBytes,
            currentReservation,
            rejectingDataPayload,
            true
        ))
        payloadBytes = []
        payloadOffset = 0
        currentReservation = None<Http2ReceivedBufferReservation>
        rejectingDataPayload = false
        currentHeader = None<Http2FrameHeader>
    }
}

private func isDataFrameType(frameType: Http2FrameType): Bool {
    match (frameType) { case Http2FrameType.Data => true; case _ => false }
}

/** Decodes exactly the nine-byte frame envelope. */
public func decodeHttp2FrameHeader(bytes: Array<Byte>, limits!: Http2Limits = Http2Limits()): Http2FrameHeader {
    if (bytes.size != 9) { throw IllegalArgumentException("HTTP/2 frame header must contain exactly nine bytes") }
    let length = (UInt32(bytes[0]) << 16) | (UInt32(bytes[1]) << 8) | UInt32(bytes[2])
    let rawStreamId = (UInt32(bytes[5]) << 24) | (UInt32(bytes[6]) << 16) |
        (UInt32(bytes[7]) << 8) | UInt32(bytes[8])
    Http2FrameHeader(
        length,
        http2FrameTypeFromCode(bytes[3]),
        Http2Flags(raw: bytes[4]),
        Http2StreamId.fromWire(rawStreamId),
        limits: limits
    )
}

/** Serializes one complete frame and always clears the stream reserved bit. */
public func serializeHttp2Frame(frame: Http2Frame): Array<Byte> {
    let payload = frame.payload
    if (payload.size != Int64(frame.header.length)) {
        throw IllegalArgumentException("HTTP/2 frame payload changed after construction")
    }
    let output = Array<Byte>(9 + payload.size, repeat: 0u8)
    let length = frame.header.length
    output[0] = UInt8((length >> 16) & 0xffu32)
    output[1] = UInt8((length >> 8) & 0xffu32)
    output[2] = UInt8(length & 0xffu32)
    output[3] = http2FrameTypeCode(frame.header.frameType)
    output[4] = frame.header.flags.raw
    let streamId = frame.header.streamId.value
    output[5] = UInt8((streamId >> 24) & 0x7fu32)
    output[6] = UInt8((streamId >> 16) & 0xffu32)
    output[7] = UInt8((streamId >> 8) & 0xffu32)
    output[8] = UInt8(streamId & 0xffu32)
    for (index in 0..payload.size) { output[9 + index] = payload[index] }
    output
}

/** Writes one frame through the Transport partial-write loop under one budget. */
public func writeHttp2Frame(
    transport: DuplexTransport,
    frame: Http2Frame,
    context!: OperationContext = OperationContext.background()
): Unit {
    writeAll(transport, ByteSpan(serializeHttp2Frame(frame)), context: context)
}
