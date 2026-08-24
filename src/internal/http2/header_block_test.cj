package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class Http2HeaderBlockAssemblerTest {
    @TestCase
    func sameStreamContinuationsAssembleInExactOrder(): Unit {
        let assembler = Http2HeaderBlockAssembler()
        @Expect(assembler.accept(testFrame(Http2FrameType.Headers, 1u32, [1, 2], flags: 0x01u8)).isNone())
        @Expect(assembler.hasOpenBlock())
        let complete = assembler.accept(
            testFrame(Http2FrameType.Continuation, 1u32, [3, 4], flags: 0x04u8)
        ).getOrThrow()
        @Expect(complete.bytes, bytes([1, 2, 3, 4]))
        @Expect(complete.endStream)
        @Expect(!assembler.hasOpenBlock())
    }

    @TestCase
    func continuationWithoutStartWrongStreamAndInterleavingFailConnection(): Unit {
        expectHeaderProtocolFailure({ =>
            let _ = Http2HeaderBlockAssembler().accept(
                testFrame(Http2FrameType.Continuation, 1u32, [], flags: 0x04u8)
            )
        })
        let wrong = Http2HeaderBlockAssembler()
        let _ = wrong.accept(testFrame(Http2FrameType.Headers, 1u32, []))
        expectHeaderProtocolFailure({ =>
            let _ = wrong.accept(testFrame(Http2FrameType.Continuation, 3u32, [], flags: 0x04u8))
        })
        let interleaved = Http2HeaderBlockAssembler()
        let _ = interleaved.accept(testFrame(Http2FrameType.Headers, 1u32, []))
        expectHeaderProtocolFailure({ =>
            let _ = interleaved.accept(testFrame(Http2FrameType.Data, 1u32, []))
        })
    }

    @TestCase
    func paddingAndPriorityOverheadAreExcludedFromHeaderBytes(): Unit {
        let payload: Array<Byte> = [2, 0, 0, 0, 3, 15, 0x82, 0x84, 0, 0]
        let complete = Http2HeaderBlockAssembler().accept(
            testFrame(Http2FrameType.Headers, 1u32, payload, flags: 0x2du8)
        ).getOrThrow()
        @Expect(complete.bytes, bytes([0x82, 0x84]))
        @Expect(complete.endStream)
    }

    @TestCase
    func pushPromiseRetainsPromisedStreamAndFragmentOnly(): Unit {
        let payload: Array<Byte> = [0, 0, 0, 2, 0x82]
        let complete = Http2HeaderBlockAssembler().accept(
            testFrame(Http2FrameType.PushPromise, 1u32, payload, flags: 0x04u8)
        ).getOrThrow()
        @Expect(complete.promisedStreamId.getOrThrow().value, 2u32)
        @Expect(complete.bytes, bytes([0x82]))
    }

    @TestCase
    func invalidPaddingPriorityAndSelfDependencyFailClosed(): Unit {
        expectHeaderFailure({ =>
            let _ = Http2HeaderBlockAssembler().accept(
                testFrame(Http2FrameType.Headers, 1u32, [3, 1, 2], flags: 0x0cu8)
            )
        })
        expectHeaderFailure({ =>
            let _ = Http2HeaderBlockAssembler().accept(
                testFrame(Http2FrameType.Headers, 1u32, [0, 0, 0, 1], flags: 0x24u8)
            )
        })
        expectHeaderProtocolFailure({ =>
            let _ = Http2HeaderBlockAssembler().accept(
                testFrame(Http2FrameType.Headers, 1u32, [0, 0, 0, 1, 0], flags: 0x24u8)
            )
        })
    }

    @TestCase
    func accumulatedCompressedBytesHaveOneHardLimit(): Unit {
        let assembler = Http2HeaderBlockAssembler(limits: Http2Limits(maxHeaderBlockBytes: 3u32))
        let _ = assembler.accept(testFrame(Http2FrameType.Headers, 1u32, [1, 2]))
        var bounded = false
        try {
            let _ = assembler.accept(testFrame(Http2FrameType.Continuation, 1u32, [3, 4], flags: 0x04u8))
        } catch (error: Http2ProtocolException) {
            bounded = http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(Http2ErrorCode.EnhanceYourCalm)
        }
        @Expect(bounded)
    }
}

private func testFrame(
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

private func bytes(values: Array<Int64>): Array<Byte> {
    let output = Array<Byte>(values.size, repeat: 0u8)
    for (index in 0..values.size) { output[index] = UInt8(values[index]) }
    output
}

private func expectHeaderProtocolFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (error: Http2ProtocolException) {
        rejected = http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(Http2ErrorCode.ProtocolError)
    }
    @Expect(rejected)
}

private func expectHeaderFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: Http2ProtocolException) { rejected = true }
    @Expect(rejected)
}
