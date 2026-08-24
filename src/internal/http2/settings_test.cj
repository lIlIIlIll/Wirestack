package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class Http2SettingsTest {
    @TestCase
    func codecPreservesKnownUnknownAndRepeatedSettingsInOrder(): Unit {
        let input = [
            Http2Setting(Http2SettingId.HeaderTableSize, 1024u32),
            Http2Setting(Http2SettingId.MaxConcurrentStreams, 12u32),
            Http2Setting(Http2SettingId.HeaderTableSize, 2048u32),
            Http2Setting(Http2SettingId.Unknown(0xf00du16), 0xfeedbeefu32)
        ]
        let decoded = decodeHttp2Settings(encodeHttp2Settings(input))
        @Expect(!decoded.acknowledgement)
        @Expect(decoded.settings.size, 4)
        @Expect(http2SettingIdToWire(decoded.settings[3].identifier), 0xf00du16)
        @Expect(decoded.settings[3].value, 0xfeedbeefu32)
    }

    @TestCase
    func peerBatchAppliesAtomicallyAndReturnsAckAndWindowDelta(): Unit {
        let state = Http2SettingsState()
        let result = state.receive(encodeHttp2Settings([
            Http2Setting(Http2SettingId.InitialWindowSize, 70000u32),
            Http2Setting(Http2SettingId.MaxConcurrentStreams, 8u32),
            Http2Setting(Http2SettingId.EnablePush, 0u32)
        ]))
        let update = applied(result)
        @Expect(update.initialWindowDelta, 4465)
        @Expect(update.peer.initialWindowSize, 70000u32)
        @Expect(update.peer.maxConcurrentStreams, 8u32)
        @Expect(!update.peer.enablePush)
        @Expect(decodeHttp2Settings(update.ack).acknowledgement)
        @Expect(state.peer.initialWindowSize, 70000u32)
    }

    @TestCase
    func invalidPeerBatchLeavesEffectiveStateUnchanged(): Unit {
        let state = Http2SettingsState()
        let before = state.peer.initialWindowSize
        let invalidWire: Array<Byte> = [0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 4, 0x80, 0, 0, 0]
        let frame = Http2FrameParser().feed(invalidWire)[0]
        var rejected = false
        try { let _ = state.receive(frame) } catch (error: Http2ProtocolException) {
            rejected = sameSettingsError(error.code, Http2ErrorCode.FlowControlError)
        }
        @Expect(rejected)
        @Expect(state.peer.initialWindowSize, before)
    }

    @TestCase
    func localBatchesAreAcknowledgedInFifoOrder(): Unit {
        let state = Http2SettingsState()
        let _ = state.sendLocal([Http2Setting(Http2SettingId.MaxConcurrentStreams, 10u32)])
        let _ = state.sendLocal([Http2Setting(Http2SettingId.MaxConcurrentStreams, 20u32)])
        @Expect(state.pendingLocalCount, 2)
        @Expect(acknowledged(state.receive(http2SettingsAck())).maxConcurrentStreams, 10u32)
        @Expect(acknowledged(state.receive(http2SettingsAck())).maxConcurrentStreams, 20u32)
        @Expect(state.pendingLocalCount, 0)
    }

    @TestCase
    func unexpectedAckAndPendingBatchOverflowFailClosed(): Unit {
        let state = Http2SettingsState(limits: Http2Limits(maxPendingSettings: 1u32))
        var unexpected = false
        try { let _ = state.receive(http2SettingsAck()) } catch (error: Http2ProtocolException) {
            unexpected = sameSettingsError(error.code, Http2ErrorCode.ProtocolError)
        }
        @Expect(unexpected)

        let _ = state.sendLocal([])
        var bounded = false
        try { let _ = state.sendLocal([]) } catch (_: IllegalStateException) { bounded = true }
        @Expect(bounded)
    }

    @TestCase
    func advertisedResourceValuesAreCappedByLocalPolicy(): Unit {
        let limits = Http2Limits(
            maxHeaderTableBytes: 128u32,
            maxHeaderListBytes: 1024u32,
            maxConcurrentStreams: 4u32
        )
        let state = Http2SettingsState(limits: limits)
        let update = applied(state.receive(encodeHttp2Settings([
            Http2Setting(Http2SettingId.HeaderTableSize, 9999u32),
            Http2Setting(Http2SettingId.MaxHeaderListSize, 9999u32),
            Http2Setting(Http2SettingId.MaxConcurrentStreams, 9999u32)
        ])))
        @Expect(update.peer.headerTableSize, 128u32)
        @Expect(update.peer.maxHeaderListSize, 1024u32)
        @Expect(update.peer.maxConcurrentStreams, 4u32)
    }

    @TestCase
    func settingsFrameLengthAndAckPayloadAreRejectedByFrameLayer(): Unit {
        var badLength = false
        try {
            let _ = Http2FrameParser().feed([0, 0, 5, 4, 0, 0, 0, 0, 0])
        } catch (error: Http2ProtocolException) {
            badLength = sameSettingsError(error.code, Http2ErrorCode.FrameSizeError)
        }
        @Expect(badLength)

        var badAck = false
        try {
            let _ = Http2FrameParser().feed([0, 0, 6, 4, 1, 0, 0, 0, 0])
        } catch (error: Http2ProtocolException) {
            badAck = sameSettingsError(error.code, Http2ErrorCode.FrameSizeError)
        }
        @Expect(badAck)
    }
}

private func applied(result: Http2SettingsReceiveResult): Http2SettingsUpdate {
    match (result) {
        case Http2SettingsReceiveResult.Applied(value) => value
        case _ => throw IllegalStateException("expected applied SETTINGS")
    }
}

private func acknowledged(result: Http2SettingsReceiveResult): Http2SettingsSnapshot {
    match (result) {
        case Http2SettingsReceiveResult.Acknowledged(value) => value
        case _ => throw IllegalStateException("expected acknowledged SETTINGS")
    }
}

private func sameSettingsError(left: Http2ErrorCode, right: Http2ErrorCode): Bool {
    http2ErrorCodeToWire(left) == http2ErrorCodeToWire(right)
}
