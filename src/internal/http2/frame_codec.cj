package wirestack.internal.http2

import std.collection.ArrayList
import wirestack.internal.transport.*

/** One complete HTTP/2 frame with an owned, immutable payload. */
public class Http2Frame {
    public let header: Http2FrameHeader
    private let ownedPayload: Array<Byte>

    public prop payload: Array<Byte> { get() { ownedPayload.clone() } }

    public init(header: Http2FrameHeader, payload: Array<Byte>) {
        if (payload.size != Int64(header.length)) {
            throw IllegalArgumentException("HTTP/2 frame header length must equal its payload length")
        }
        this.header = header
        ownedPayload = payload.clone()
    }
}

/**
 * Incremental frame decoder.
 *
 * Input may end at any header or payload byte. Complete frames are returned in
 * wire order, while at most one bounded incomplete frame remains buffered.
 */
public class Http2FrameParser {
    private let limits: Http2Limits
    private let headerBytes = ArrayList<Byte>()
    private let payloadBytes = ArrayList<Byte>()
    private var currentHeader: ?Http2FrameHeader = None<Http2FrameHeader>
    private var failed = false

    public init(limits!: Http2Limits = Http2Limits()) { this.limits = limits }

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
                            if (header.length == 0u32) { finishFrame(frames, header) }
                        }
                    case Some(header) =>
                        payloadBytes.add(value)
                        if (payloadBytes.size == Int64(header.length)) { finishFrame(frames, header) }
                }
            }
        } catch (error: Http2ProtocolException) {
            failed = true
            throw error
        }
        frames.toArray()
    }

    public func hasIncompleteFrame(): Bool {
        !headerBytes.isEmpty() || currentHeader.isSome()
    }

    private func finishFrame(frames: ArrayList<Http2Frame>, header: Http2FrameHeader): Unit {
        frames.add(Http2Frame(header, payloadBytes.toArray()))
        payloadBytes.clear()
        currentHeader = None<Http2FrameHeader>
    }
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
