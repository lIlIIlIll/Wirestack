package wirestack.internal.http2

import std.collection.ArrayList

/** Effective, resource-capped settings used by one side of a connection. */
public class Http2SettingsSnapshot {
    public let headerTableSize: UInt32
    public let enablePush: Bool
    public let maxConcurrentStreams: UInt32
    public let initialWindowSize: UInt32
    public let maxFrameSize: UInt32
    public let maxHeaderListSize: UInt32

    public init(
        headerTableSize: UInt32,
        enablePush: Bool,
        maxConcurrentStreams: UInt32,
        initialWindowSize: UInt32,
        maxFrameSize: UInt32,
        maxHeaderListSize: UInt32
    ) {
        let _ = Http2Setting(Http2SettingId.InitialWindowSize, initialWindowSize)
        let _ = Http2Setting(Http2SettingId.MaxFrameSize, maxFrameSize)
        this.headerTableSize = headerTableSize
        this.enablePush = enablePush
        this.maxConcurrentStreams = maxConcurrentStreams
        this.initialWindowSize = initialWindowSize
        this.maxFrameSize = maxFrameSize
        this.maxHeaderListSize = maxHeaderListSize
    }
}

/** Normal SETTINGS application result; the caller must enqueue `ack`. */
public class Http2SettingsUpdate {
    public let peer: Http2SettingsSnapshot
    public let initialWindowDelta: Int64
    public let ack: Http2Frame

    public init(peer: Http2SettingsSnapshot, initialWindowDelta: Int64, ack: Http2Frame) {
        this.peer = peer
        this.initialWindowDelta = initialWindowDelta
        this.ack = ack
    }
}

public enum Http2SettingsReceiveResult {
    | Applied(Http2SettingsUpdate)
    | Acknowledged(Http2SettingsSnapshot)
}

/**
 * SETTINGS negotiation state.
 *
 * Peer settings apply atomically when received. ACK confirms the oldest local
 * SETTINGS batch; it never delays enforcement of a received peer batch.
 */
public class Http2SettingsState {
    private let limits: Http2Limits
    private let pendingLocal = ArrayList<Http2SettingsSnapshot>()
    private var peerState: Http2SettingsSnapshot
    private var advertisedLocalState: Http2SettingsSnapshot
    private var acknowledgedLocalState: Http2SettingsSnapshot

    public prop peer: Http2SettingsSnapshot { get() { peerState } }
    public prop advertisedLocal: Http2SettingsSnapshot { get() { advertisedLocalState } }
    public prop acknowledgedLocal: Http2SettingsSnapshot { get() { acknowledgedLocalState } }
    public prop pendingLocalCount: Int64 { get() { pendingLocal.size } }

    public init(limits!: Http2Limits = Http2Limits()) {
        this.limits = limits
        let defaults = defaultHttp2Settings(limits)
        peerState = defaults
        advertisedLocalState = defaults
        acknowledgedLocalState = defaults
    }

    /** Encodes and tracks one local batch; ACKs resolve these batches FIFO. */
    public func sendLocal(settings: Array<Http2Setting>): Http2Frame {
        if (pendingLocal.size >= Int64(limits.maxPendingSettings)) {
            throw IllegalStateException("HTTP/2 pending SETTINGS batches reached the configured limit")
        }
        let next = applyHttp2Settings(advertisedLocalState, settings, limits)
        let frame = encodeHttp2Settings(settings)
        advertisedLocalState = next
        pendingLocal.add(next)
        frame
    }

    /** Applies a peer batch or acknowledges exactly one pending local batch. */
    public func receive(frame: Http2Frame): Http2SettingsReceiveResult {
        let decoded = decodeHttp2Settings(frame)
        if (decoded.acknowledgement) {
            if (pendingLocal.isEmpty()) {
                throw Http2ProtocolException(
                    Http2ErrorCode.ProtocolError,
                    Http2ErrorScope.Connection,
                    "HTTP/2 received an unexpected SETTINGS acknowledgement"
                )
            }
            let acknowledged = pendingLocal.remove(at: 0)
            acknowledgedLocalState = acknowledged
            return Http2SettingsReceiveResult.Acknowledged(acknowledged)
        }

        // Build the entire next snapshot before mutating state. A malformed
        // entry therefore leaves all previously effective settings unchanged.
        let next = applyHttp2Settings(peerState, decoded.settings, limits)
        let delta = Int64(next.initialWindowSize) - Int64(peerState.initialWindowSize)
        peerState = next
        Http2SettingsReceiveResult.Applied(Http2SettingsUpdate(next, delta, http2SettingsAck()))
    }
}

public class Http2DecodedSettings {
    public let acknowledgement: Bool
    private let ownedSettings: Array<Http2Setting>

    public prop settings: Array<Http2Setting> { get() { ownedSettings.clone() } }

    public init(acknowledgement: Bool, settings: Array<Http2Setting>) {
        if (acknowledgement && !settings.isEmpty()) {
            throw IllegalArgumentException("HTTP/2 SETTINGS acknowledgement cannot contain entries")
        }
        this.acknowledgement = acknowledgement
        ownedSettings = settings.clone()
    }
}

public func decodeHttp2Settings(frame: Http2Frame): Http2DecodedSettings {
    if (!isSettingsFrame(frame.header.frameType)) {
        throw IllegalArgumentException("expected an HTTP/2 SETTINGS frame")
    }
    let payload = frame.payload
    if (frame.header.flags.isAck()) {
        if (!payload.isEmpty()) {
            throw Http2ProtocolException(
                Http2ErrorCode.FrameSizeError,
                Http2ErrorScope.Connection,
                "HTTP/2 SETTINGS acknowledgement must be empty"
            )
        }
        return Http2DecodedSettings(true, [])
    }
    let settings = ArrayList<Http2Setting>()
    var offset: Int64 = 0
    while (offset < payload.size) {
        let identifier = (UInt16(payload[offset]) << 8) | UInt16(payload[offset + 1])
        let value = (UInt32(payload[offset + 2]) << 24) | (UInt32(payload[offset + 3]) << 16) |
            (UInt32(payload[offset + 4]) << 8) | UInt32(payload[offset + 5])
        settings.add(Http2Setting(http2SettingIdFromWire(identifier), value))
        offset += 6
    }
    Http2DecodedSettings(false, settings.toArray())
}

public func encodeHttp2Settings(settings: Array<Http2Setting>): Http2Frame {
    let payload = Array<Byte>(settings.size * 6, repeat: 0u8)
    for (index in 0..settings.size) {
        let offset = index * 6
        let identifier = http2SettingIdToWire(settings[index].identifier)
        let value = settings[index].value
        payload[offset] = UInt8((identifier >> 8) & 0xffu16)
        payload[offset + 1] = UInt8(identifier & 0xffu16)
        payload[offset + 2] = UInt8((value >> 24) & 0xffu32)
        payload[offset + 3] = UInt8((value >> 16) & 0xffu32)
        payload[offset + 4] = UInt8((value >> 8) & 0xffu32)
        payload[offset + 5] = UInt8(value & 0xffu32)
    }
    Http2Frame(
        Http2FrameHeader(
            UInt32(payload.size), Http2FrameType.Settings, Http2Flags(), Http2StreamId(0u32)
        ),
        payload
    )
}

public func http2SettingsAck(): Http2Frame {
    Http2Frame(
        Http2FrameHeader(0u32, Http2FrameType.Settings, Http2Flags(raw: 0x01u8), Http2StreamId(0u32)),
        []
    )
}

private func defaultHttp2Settings(limits: Http2Limits): Http2SettingsSnapshot {
    Http2SettingsSnapshot(
        limits.maxHeaderTableBytes,
        true,
        limits.maxConcurrentStreams,
        limits.initialWindowSize,
        limits.maxFrameSize,
        limits.maxHeaderListBytes
    )
}

private func applyHttp2Settings(
    current: Http2SettingsSnapshot,
    settings: Array<Http2Setting>,
    limits: Http2Limits
): Http2SettingsSnapshot {
    var headerTableSize = current.headerTableSize
    var enablePush = current.enablePush
    var maxConcurrentStreams = current.maxConcurrentStreams
    var initialWindowSize = current.initialWindowSize
    var maxFrameSize = current.maxFrameSize
    var maxHeaderListSize = current.maxHeaderListSize
    for (setting in settings) {
        match (setting.identifier) {
            case Http2SettingId.HeaderTableSize =>
                headerTableSize = min(setting.value, limits.maxHeaderTableBytes)
            case Http2SettingId.EnablePush => enablePush = setting.value == 1u32
            case Http2SettingId.MaxConcurrentStreams =>
                maxConcurrentStreams = min(setting.value, limits.maxConcurrentStreams)
            case Http2SettingId.InitialWindowSize => initialWindowSize = setting.value
            case Http2SettingId.MaxFrameSize => maxFrameSize = min(setting.value, limits.maxFrameSize)
            case Http2SettingId.MaxHeaderListSize =>
                maxHeaderListSize = min(setting.value, limits.maxHeaderListBytes)
            case Http2SettingId.Unknown(_) => ()
        }
    }
    Http2SettingsSnapshot(
        headerTableSize, enablePush, maxConcurrentStreams, initialWindowSize, maxFrameSize, maxHeaderListSize
    )
}

private func isSettingsFrame(frameType: Http2FrameType): Bool {
    match (frameType) { case Http2FrameType.Settings => true; case _ => false }
}
