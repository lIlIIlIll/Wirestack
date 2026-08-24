package wirestack.internal.http2

import std.collection.ArrayList

public enum Http2HeaderBlockKind {
    | Headers
    | PushPromise
}

/** One complete, owned compressed header block after frame overhead removal. */
public class Http2HeaderBlock {
    public let kind: Http2HeaderBlockKind
    public let streamId: Http2StreamId
    public let promisedStreamId: ?Http2StreamId
    public let endStream: Bool
    private let ownedBytes: Array<Byte>

    public prop bytes: Array<Byte> { get() { ownedBytes.clone() } }

    public init(
        kind: Http2HeaderBlockKind,
        streamId: Http2StreamId,
        promisedStreamId: ?Http2StreamId,
        endStream: Bool,
        bytes: Array<Byte>
    ) {
        this.kind = kind
        this.streamId = streamId
        this.promisedStreamId = promisedStreamId
        this.endStream = endStream
        ownedBytes = bytes.clone()
    }
}

/** Strict HEADERS/PUSH_PROMISE + CONTINUATION connection-level assembler. */
public class Http2HeaderBlockAssembler {
    private let limits: Http2Limits
    private let fragments = ArrayList<Byte>()
    private var pending: ?PendingHeaderBlock = None<PendingHeaderBlock>

    public init(limits!: Http2Limits = Http2Limits()) { this.limits = limits }

    /**
     * Returns a block only when END_HEADERS closes it. While a block is open,
     * every intervening frame must be CONTINUATION on the same stream.
     */
    public func accept(frame: Http2Frame): ?Http2HeaderBlock {
        if (let Some(active) <- pending) {
            if (!isContinuationFrame(frame.header.frameType) || frame.header.streamId.value != active.streamId.value) {
                headerProtocolError("HTTP/2 header block was interleaved or continued on another stream")
            }
            appendFragment(frame.payload)
            if (frame.header.flags.isEndHeaders()) { return Some(finish(active)) }
            return None<Http2HeaderBlock>
        }

        if (isContinuationFrame(frame.header.frameType)) {
            headerProtocolError("HTTP/2 CONTINUATION has no open header block")
        }
        let started = match (frame.header.frameType) {
            case Http2FrameType.Headers => Some(startHeaders(frame))
            case Http2FrameType.PushPromise => Some(startPushPromise(frame))
            case _ => None<StartedHeaderBlock>
        }
        if (let Some(value) <- started) {
            appendFragment(value.fragment)
            let active = PendingHeaderBlock(
                value.kind, frame.header.streamId, value.promisedStreamId, value.endStream
            )
            if (frame.header.flags.isEndHeaders()) { return Some(finish(active)) }
            pending = Some(active)
        }
        None<Http2HeaderBlock>
    }

    public func hasOpenBlock(): Bool { pending.isSome() }

    private func startHeaders(frame: Http2Frame): StartedHeaderBlock {
        let payload = frame.payload
        let layout = payloadLayout(payload, frame.header.flags)
        var offset = layout.contentOffset
        if (frame.header.flags.hasPriority()) {
            if (offset > layout.contentEnd || 5 > layout.contentEnd - offset) {
                headerFrameSizeError("HTTP/2 HEADERS priority section is truncated")
            }
            let rawDependency = (UInt32(payload[offset]) << 24) | (UInt32(payload[offset + 1]) << 16) |
                (UInt32(payload[offset + 2]) << 8) | UInt32(payload[offset + 3])
            let dependency = Http2StreamId.fromWire(rawDependency)
            if (dependency.value == frame.header.streamId.value) {
                headerProtocolError("HTTP/2 stream cannot depend on itself")
            }
            offset += 5
        }
        StartedHeaderBlock(
            Http2HeaderBlockKind.Headers,
            None<Http2StreamId>,
            frame.header.flags.isEndStream(),
            copyHeaderFragment(payload, offset, layout.contentEnd)
        )
    }

    private func startPushPromise(frame: Http2Frame): StartedHeaderBlock {
        let payload = frame.payload
        let layout = payloadLayout(payload, frame.header.flags)
        let offset = layout.contentOffset
        if (offset > layout.contentEnd || 4 > layout.contentEnd - offset) {
            headerFrameSizeError("HTTP/2 PUSH_PROMISE promised stream id is truncated")
        }
        let rawPromised = (UInt32(payload[offset]) << 24) | (UInt32(payload[offset + 1]) << 16) |
            (UInt32(payload[offset + 2]) << 8) | UInt32(payload[offset + 3])
        let promised = Http2StreamId.fromWire(rawPromised)
        if (!promised.isStream()) { headerProtocolError("HTTP/2 PUSH_PROMISE requires a non-zero promised stream") }
        StartedHeaderBlock(
            Http2HeaderBlockKind.PushPromise,
            Some(promised),
            false,
            copyHeaderFragment(payload, offset + 4, layout.contentEnd)
        )
    }

    private func appendFragment(fragment: Array<Byte>): Unit {
        if (UInt64(fragment.size) > UInt64(limits.maxHeaderBlockBytes) -
            min(UInt64(fragments.size), UInt64(limits.maxHeaderBlockBytes))) {
            throw Http2ProtocolException(
                Http2ErrorCode.EnhanceYourCalm,
                Http2ErrorScope.Connection,
                "HTTP/2 compressed header block exceeds the configured limit"
            )
        }
        for (octet in fragment) { fragments.add(octet) }
    }

    private func finish(active: PendingHeaderBlock): Http2HeaderBlock {
        let block = Http2HeaderBlock(
            active.kind, active.streamId, active.promisedStreamId, active.endStream, fragments.toArray()
        )
        fragments.clear()
        pending = None<PendingHeaderBlock>
        block
    }
}

private class PendingHeaderBlock {
    let kind: Http2HeaderBlockKind
    let streamId: Http2StreamId
    let promisedStreamId: ?Http2StreamId
    let endStream: Bool
    init(kind: Http2HeaderBlockKind, streamId: Http2StreamId, promisedStreamId: ?Http2StreamId, endStream: Bool) {
        this.kind = kind
        this.streamId = streamId
        this.promisedStreamId = promisedStreamId
        this.endStream = endStream
    }
}

private class StartedHeaderBlock {
    let kind: Http2HeaderBlockKind
    let promisedStreamId: ?Http2StreamId
    let endStream: Bool
    let fragment: Array<Byte>
    init(kind: Http2HeaderBlockKind, promisedStreamId: ?Http2StreamId, endStream: Bool, fragment: Array<Byte>) {
        this.kind = kind
        this.promisedStreamId = promisedStreamId
        this.endStream = endStream
        this.fragment = fragment
    }
}

private struct HeaderPayloadLayout {
    let contentOffset: Int64
    let contentEnd: Int64
    init(contentOffset: Int64, contentEnd: Int64) { this.contentOffset = contentOffset; this.contentEnd = contentEnd }
}

private func payloadLayout(payload: Array<Byte>, flags: Http2Flags): HeaderPayloadLayout {
    if (!flags.isPadded()) { return HeaderPayloadLayout(0, payload.size) }
    if (payload.isEmpty()) { headerFrameSizeError("HTTP/2 padded header frame has no pad length") }
    let padding = Int64(payload[0])
    if (padding >= payload.size) { headerProtocolError("HTTP/2 header padding consumes the complete payload") }
    HeaderPayloadLayout(1, payload.size - padding)
}

private func copyHeaderFragment(payload: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    if (start < 0 || end < start || end > payload.size) { headerFrameSizeError("HTTP/2 header fragment layout is invalid") }
    let output = Array<Byte>(end - start, repeat: 0u8)
    for (index in 0..output.size) { output[index] = payload[start + index] }
    output
}

private func isContinuationFrame(frameType: Http2FrameType): Bool {
    match (frameType) { case Http2FrameType.Continuation => true; case _ => false }
}

private func headerProtocolError(message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection, message)
}

private func headerFrameSizeError(message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.FrameSizeError, Http2ErrorScope.Connection, message)
}
