package wirestack.internal.http2

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2FrameCodecTest {
    @TestCase
    func everyRequiredFrameEnvelopeRoundTrips(): Unit {
        let frames = [
            frame(Http2FrameType.Settings, 0u32, [0, 1, 0, 0, 0, 0]),
            frame(Http2FrameType.Headers, 1u32, [1, 2, 3]),
            frame(Http2FrameType.Data, 1u32, [4, 5]),
            frame(Http2FrameType.Continuation, 1u32, [6]),
            frame(Http2FrameType.WindowUpdate, 1u32, [0, 0, 0, 1]),
            frame(Http2FrameType.RstStream, 1u32, [0, 0, 0, 8]),
            frame(Http2FrameType.GoAway, 0u32, [0, 0, 0, 1, 0, 0, 0, 0]),
            frame(Http2FrameType.Ping, 0u32, [0, 1, 2, 3, 4, 5, 6, 7])
        ]
        for (expected in frames) {
            let decoded = Http2FrameParser().feed(serializeHttp2Frame(expected))
            @Expect(decoded.size, 1)
            expectSameFrame(decoded[0], expected)
        }
    }

    @TestCase
    func parserAcceptsEverySingleByteBoundaryAndMultipleFrames(): Unit {
        let first = frame(Http2FrameType.Headers, 1u32, [10, 11, 12, 13])
        let second = frame(Http2FrameType.Data, 1u32, [20, 21, 22])
        let wire = concatenate(serializeHttp2Frame(first), serializeHttp2Frame(second))
        let parser = Http2FrameParser()
        let decoded = ArrayList<Http2Frame>()
        for (value in wire) {
            for (completed in parser.feed([value])) { decoded.add(completed) }
        }
        @Expect(decoded.size, 2)
        @Expect(!parser.hasIncompleteFrame())
        expectSameFrame(decoded[0], first)
        expectSameFrame(decoded[1], second)
    }

    @TestCase
    func incompleteInputStaysBoundedUntilCompletion(): Unit {
        let parser = Http2FrameParser()
        @Expect(parser.feed([0, 0, 3, 0, 0, 0, 0, 0]).isEmpty())
        @Expect(parser.hasIncompleteFrame())
        @Expect(parser.feed([1, 7, 8]).isEmpty())
        let completed = parser.feed([9])
        @Expect(completed.size, 1)
        let expected: Array<Byte> = [7, 8, 9]
        @Expect(completed[0].payload, expected)
        @Expect(!parser.hasIncompleteFrame())
    }

    @TestCase
    func oversizedFrameFailsBeforePayloadBufferingAndParserBecomesTerminal(): Unit {
        let parser = Http2FrameParser()
        var rejected = false
        try {
            let _ = parser.feed([0, 0x40, 1, 0, 0, 0, 0, 0, 1])
        } catch (error: Http2ProtocolException) {
            rejected = sameHttp2Error(error.code, Http2ErrorCode.FrameSizeError)
        }
        @Expect(rejected)
        var terminal = false
        try { let _ = parser.feed([]) } catch (_: IllegalStateException) { terminal = true }
        @Expect(terminal)
    }

    @TestCase
    func reservedBitIsIgnoredOnReadAndClearedOnWrite(): Unit {
        let parser = Http2FrameParser()
        let decoded = parser.feed([0, 0, 0, 0, 0, 0x80, 0, 0, 1])
        @Expect(decoded.size, 1)
        @Expect(decoded[0].header.streamId.value, 1u32)
        @Expect(serializeHttp2Frame(decoded[0])[5], 0u8)
    }

    @TestCase
    func unknownFramesAndFlagsRoundTripWithoutInterpretation(): Unit {
        let expected = frame(Http2FrameType.Unknown(0xf0u8), 0u32, [1, 2], flags: 0xffu8)
        let decoded = Http2FrameParser().feed(serializeHttp2Frame(expected))
        @Expect(decoded.size, 1)
        @Expect(http2FrameTypeCode(decoded[0].header.frameType), 0xf0u8)
        @Expect(decoded[0].header.flags.raw, 0xffu8)
        let expectedPayload: Array<Byte> = [1, 2]
        @Expect(decoded[0].payload, expectedPayload)
    }

    @TestCase
    func transportWriterHandlesRepeatedPartialWrites(): Unit {
        let transport = PartialWriteTransport(2)
        let expected = frame(Http2FrameType.Data, 3u32, [1, 2, 3, 4, 5])
        writeHttp2Frame(transport, expected)
        @Expect(transport.writeCalls > 1)
        @Expect(transport.bytes(), serializeHttp2Frame(expected))
    }
}

private func frame(
    frameType: Http2FrameType,
    streamId: UInt32,
    payload: Array<Byte>,
    flags!: Byte = 0u8
): Http2Frame {
    Http2Frame(
        Http2FrameHeader(UInt32(payload.size), frameType, Http2Flags(raw: flags), Http2StreamId(streamId)),
        payload
    )
}

private func concatenate(left: Array<Byte>, right: Array<Byte>): Array<Byte> {
    let output = ArrayList<Byte>()
    for (value in left) { output.add(value) }
    for (value in right) { output.add(value) }
    output.toArray()
}

private func expectSameFrame(left: Http2Frame, right: Http2Frame): Unit {
    @Expect(left.header.length, right.header.length)
    @Expect(http2FrameTypeCode(left.header.frameType), http2FrameTypeCode(right.header.frameType))
    @Expect(left.header.flags.raw, right.header.flags.raw)
    @Expect(left.header.streamId.value, right.header.streamId.value)
    @Expect(left.payload, right.payload)
}

private func sameHttp2Error(left: Http2ErrorCode, right: Http2ErrorCode): Bool {
    http2ErrorCodeToWire(left) == http2ErrorCodeToWire(right)
}

private class PartialWriteTransport <: DuplexTransport {
    private let maximum: Int64
    private let output = ArrayList<Byte>()
    public var writeCalls: Int64 = 0

    public init(maximum: Int64) { this.maximum = maximum }

    public prop info: TransportInfo { get() { TransportInfo("http2-partial-test") } }

    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        let count = min(maximum, source.length)
        for (index in 0..count) { output.add(source.bytes[source.offset + index]) }
        writeCalls += 1
        count
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit { closed = true }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason; closed = true }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }

    public func bytes(): Array<Byte> { output.toArray() }

    private var closed = false
}
