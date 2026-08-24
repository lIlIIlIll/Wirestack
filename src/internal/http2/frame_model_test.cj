package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class Http2FrameModelTest {
    @TestCase
    func frameAndErrorCodesRoundTripIncludingExtensions(): Unit {
        for (code in [0u8, 1u8, 4u8, 6u8, 9u8, 0xf0u8]) {
            @Expect(http2FrameTypeCode(http2FrameTypeFromCode(code)), code)
        }
        for (code in [0u32, 1u32, 3u32, 9u32, 13u32, 0xfeedu32]) {
            @Expect(http2ErrorCodeToWire(http2ErrorCodeFromWire(code)), code)
        }
    }

    @TestCase
    func streamIdentifierIgnoresReservedBitAndKeepsThirtyOneBits(): Unit {
        @Expect(Http2StreamId.fromWire(2147483647u32).value, 2147483647u32)
        @Expect(Http2StreamId.fromWire(0x80000001u32).value, 1u32)
    }

    @TestCase
    func limitsAreExplicitAndFrameSizeIsBounded(): Unit {
        let limits = Http2Limits()
        @Expect(limits.maxFrameSize, 16384u32)
        @Expect(limits.maxConcurrentStreams, 100u32)
        @Expect(limits.maxPendingWriteBytes, 1048576u32)
        expectIllegalLimits()
        expectFrameError(
            Http2ErrorCode.FrameSizeError,
            16385u32,
            Http2FrameType.Data,
            Http2Flags(),
            Http2StreamId(1u32)
        )
    }

    @TestCase
    func fixedFrameShapesAndStreamScopesAreValidated(): Unit {
        let zero = Http2StreamId(0u32)
        let one = Http2StreamId(1u32)
        let _ = Http2FrameHeader(0u32, Http2FrameType.Settings, Http2Flags(raw: 1u8), zero)
        let _ = Http2FrameHeader(8u32, Http2FrameType.Ping, Http2Flags(), zero)
        let _ = Http2FrameHeader(4u32, Http2FrameType.RstStream, Http2Flags(), one)
        let _ = Http2FrameHeader(0u32, Http2FrameType.Data, Http2Flags(), one)

        expectFrameError(Http2ErrorCode.ProtocolError, 0u32, Http2FrameType.Data, Http2Flags(), zero)
        expectFrameError(Http2ErrorCode.ProtocolError, 0u32, Http2FrameType.Settings, Http2Flags(), one)
        expectFrameError(Http2ErrorCode.FrameSizeError, 4u32, Http2FrameType.Ping, Http2Flags(), zero)
        expectFrameError(Http2ErrorCode.FrameSizeError, 6u32, Http2FrameType.Settings, Http2Flags(raw: 1u8), zero)
    }

    @TestCase
    func settingsRejectInvalidProtocolValuesButRetainExtensions(): Unit {
        let _ = Http2Setting(Http2SettingId.EnablePush, 1u32)
        let _ = Http2Setting(Http2SettingId.InitialWindowSize, 2147483647u32)
        let _ = Http2Setting(Http2SettingId.MaxFrameSize, 16777215u32)
        let extensionSetting = Http2Setting(http2SettingIdFromWire(0xf00du16), 0xffffffffu32)
        @Expect(extensionSetting.value, 0xffffffffu32)

        expectSettingError(Http2SettingId.EnablePush, 2u32, Http2ErrorCode.ProtocolError)
        expectSettingError(Http2SettingId.InitialWindowSize, 2147483648u32, Http2ErrorCode.FlowControlError)
        expectSettingError(Http2SettingId.MaxFrameSize, 16383u32, Http2ErrorCode.ProtocolError)
    }

    @TestCase
    func unknownFlagsAndFramesRemainForwardCompatible(): Unit {
        let header = Http2FrameHeader(
            3u32,
            Http2FrameType.Unknown(0xfeu8),
            Http2Flags(raw: 0xffu8),
            Http2StreamId(0u32)
        )
        @Expect(header.flags.raw, 0xffu8)
        @Expect(http2FrameTypeCode(header.frameType), 0xfeu8)
    }
}

private func expectIllegalLimits(): Unit {
    var rejected = false
    try {
        let _ = Http2Limits(maxPendingWrites: 0u32)
    } catch (_: IllegalArgumentException) {
        rejected = true
    }
    @Expect(rejected)
}

private func expectFrameError(
    expected: Http2ErrorCode,
    length: UInt32,
    frameType: Http2FrameType,
    flags: Http2Flags,
    streamId: Http2StreamId
): Unit {
    var matched = false
    try {
        let _ = Http2FrameHeader(length, frameType, flags, streamId)
    } catch (error: Http2ProtocolException) {
        matched = sameError(error.code, expected)
    }
    @Expect(matched)
}

private func expectSettingError(identifier: Http2SettingId, value: UInt32, expected: Http2ErrorCode): Unit {
    var matched = false
    try {
        let _ = Http2Setting(identifier, value)
    } catch (error: Http2ProtocolException) {
        matched = sameError(error.code, expected)
    }
    @Expect(matched)
}

private func sameError(left: Http2ErrorCode, right: Http2ErrorCode): Bool {
    http2ErrorCodeToWire(left) == http2ErrorCodeToWire(right)
}
