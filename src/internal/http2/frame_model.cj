package wirestack.internal.http2

/** RFC 9113 frame payload bounds and Wirestack's explicit resource policy. */
public class Http2Limits {
    public let maxFrameSize: UInt32
    public let maxHeaderTableBytes: UInt32
    public let maxHeaderListBytes: UInt32
    public let maxHeaderBlockBytes: UInt32
    public let maxPendingWriteBytes: UInt32
    public let maxPendingWrites: UInt32
    public let maxConcurrentStreams: UInt32
    public let initialWindowSize: UInt32

    public init(
        maxFrameSize!: UInt32 = 16384u32,
        maxHeaderTableBytes!: UInt32 = 4096u32,
        maxHeaderListBytes!: UInt32 = 65536u32,
        maxHeaderBlockBytes!: UInt32 = 65536u32,
        maxPendingWriteBytes!: UInt32 = 1048576u32,
        maxPendingWrites!: UInt32 = 256u32,
        maxConcurrentStreams!: UInt32 = 100u32,
        initialWindowSize!: UInt32 = 65535u32
    ) {
        if (maxFrameSize < 16384u32 || maxFrameSize > 16777215u32) {
            throw IllegalArgumentException("HTTP/2 max frame size must be in [16384, 16777215]")
        }
        requirePositive(maxHeaderListBytes, "header list bytes")
        requirePositive(maxHeaderBlockBytes, "header block bytes")
        requirePositive(maxPendingWriteBytes, "pending write bytes")
        requirePositive(maxPendingWrites, "pending writes")
        requirePositive(maxConcurrentStreams, "concurrent streams")
        if (initialWindowSize > 2147483647u32) {
            throw IllegalArgumentException("HTTP/2 initial window must fit 31 bits")
        }
        this.maxFrameSize = maxFrameSize
        this.maxHeaderTableBytes = maxHeaderTableBytes
        this.maxHeaderListBytes = maxHeaderListBytes
        this.maxHeaderBlockBytes = maxHeaderBlockBytes
        this.maxPendingWriteBytes = maxPendingWriteBytes
        this.maxPendingWrites = maxPendingWrites
        this.maxConcurrentStreams = maxConcurrentStreams
        this.initialWindowSize = initialWindowSize
    }
}

/** A validated 31-bit HTTP/2 stream identifier. Zero denotes the connection. */
public struct Http2StreamId {
    public let value: UInt32

    public init(value: UInt32) {
        if (value > 2147483647u32) {
            throw IllegalArgumentException("HTTP/2 stream id must fit 31 bits")
        }
        this.value = value
    }

    public static func fromWire(raw: UInt32): Http2StreamId {
        // RFC 9113 requires receivers to ignore the reserved bit. The typed
        // value drops it, and serializers therefore always emit it as zero.
        Http2StreamId(raw & 0x7fffffffu32)
    }

    public func isConnection(): Bool { value == 0u32 }
    public func isStream(): Bool { value != 0u32 }
}

/** Known frame types plus extension frame codes that compliant peers must ignore. */
public enum Http2FrameType {
    | Data
    | Headers
    | Priority
    | RstStream
    | Settings
    | PushPromise
    | Ping
    | GoAway
    | WindowUpdate
    | Continuation
    | Unknown(Byte)
}

public func http2FrameTypeFromCode(code: Byte): Http2FrameType {
    match (code) {
        case 0u8 => Http2FrameType.Data
        case 1u8 => Http2FrameType.Headers
        case 2u8 => Http2FrameType.Priority
        case 3u8 => Http2FrameType.RstStream
        case 4u8 => Http2FrameType.Settings
        case 5u8 => Http2FrameType.PushPromise
        case 6u8 => Http2FrameType.Ping
        case 7u8 => Http2FrameType.GoAway
        case 8u8 => Http2FrameType.WindowUpdate
        case 9u8 => Http2FrameType.Continuation
        case value => Http2FrameType.Unknown(value)
    }
}

public func http2FrameTypeCode(frameType: Http2FrameType): Byte {
    match (frameType) {
        case Http2FrameType.Data => 0u8
        case Http2FrameType.Headers => 1u8
        case Http2FrameType.Priority => 2u8
        case Http2FrameType.RstStream => 3u8
        case Http2FrameType.Settings => 4u8
        case Http2FrameType.PushPromise => 5u8
        case Http2FrameType.Ping => 6u8
        case Http2FrameType.GoAway => 7u8
        case Http2FrameType.WindowUpdate => 8u8
        case Http2FrameType.Continuation => 9u8
        case Http2FrameType.Unknown(value) => value
    }
}

/** Raw flags are retained because unknown flag bits must be ignored, not rejected. */
public struct Http2Flags {
    public let raw: Byte

    public init(raw!: Byte = 0u8) { this.raw = raw }

    public func contains(mask: Byte): Bool { (raw & mask) == mask }
    public func isAck(): Bool { contains(0x01u8) }
    public func isEndStream(): Bool { contains(0x01u8) }
    public func isEndHeaders(): Bool { contains(0x04u8) }
    public func isPadded(): Bool { contains(0x08u8) }
    public func hasPriority(): Bool { contains(0x20u8) }
}

public enum Http2ErrorCode {
    | NoError
    | ProtocolError
    | InternalError
    | FlowControlError
    | SettingsTimeout
    | StreamClosed
    | FrameSizeError
    | RefusedStream
    | Cancel
    | CompressionError
    | ConnectError
    | EnhanceYourCalm
    | InadequateSecurity
    | Http11Required
    | Unknown(UInt32)
}

public func http2ErrorCodeFromWire(code: UInt32): Http2ErrorCode {
    match (code) {
        case 0u32 => Http2ErrorCode.NoError
        case 1u32 => Http2ErrorCode.ProtocolError
        case 2u32 => Http2ErrorCode.InternalError
        case 3u32 => Http2ErrorCode.FlowControlError
        case 4u32 => Http2ErrorCode.SettingsTimeout
        case 5u32 => Http2ErrorCode.StreamClosed
        case 6u32 => Http2ErrorCode.FrameSizeError
        case 7u32 => Http2ErrorCode.RefusedStream
        case 8u32 => Http2ErrorCode.Cancel
        case 9u32 => Http2ErrorCode.CompressionError
        case 10u32 => Http2ErrorCode.ConnectError
        case 11u32 => Http2ErrorCode.EnhanceYourCalm
        case 12u32 => Http2ErrorCode.InadequateSecurity
        case 13u32 => Http2ErrorCode.Http11Required
        case value => Http2ErrorCode.Unknown(value)
    }
}

public func http2ErrorCodeToWire(code: Http2ErrorCode): UInt32 {
    match (code) {
        case Http2ErrorCode.NoError => 0u32
        case Http2ErrorCode.ProtocolError => 1u32
        case Http2ErrorCode.InternalError => 2u32
        case Http2ErrorCode.FlowControlError => 3u32
        case Http2ErrorCode.SettingsTimeout => 4u32
        case Http2ErrorCode.StreamClosed => 5u32
        case Http2ErrorCode.FrameSizeError => 6u32
        case Http2ErrorCode.RefusedStream => 7u32
        case Http2ErrorCode.Cancel => 8u32
        case Http2ErrorCode.CompressionError => 9u32
        case Http2ErrorCode.ConnectError => 10u32
        case Http2ErrorCode.EnhanceYourCalm => 11u32
        case Http2ErrorCode.InadequateSecurity => 12u32
        case Http2ErrorCode.Http11Required => 13u32
        case Http2ErrorCode.Unknown(value) => value
    }
}

public enum Http2ErrorScope {
    | Connection
    | Stream(Http2StreamId)
}

public class Http2ProtocolException <: Exception {
    public let code: Http2ErrorCode
    public let scope: Http2ErrorScope

    public init(code: Http2ErrorCode, scope: Http2ErrorScope, message: String) {
        super(message)
        this.code = code
        this.scope = scope
    }

    protected override func getClassName(): String { "Http2ProtocolException" }
}

public enum Http2SettingId {
    | HeaderTableSize
    | EnablePush
    | MaxConcurrentStreams
    | InitialWindowSize
    | MaxFrameSize
    | MaxHeaderListSize
    | Unknown(UInt16)
}

public func http2SettingIdFromWire(identifier: UInt16): Http2SettingId {
    match (identifier) {
        case 1u16 => Http2SettingId.HeaderTableSize
        case 2u16 => Http2SettingId.EnablePush
        case 3u16 => Http2SettingId.MaxConcurrentStreams
        case 4u16 => Http2SettingId.InitialWindowSize
        case 5u16 => Http2SettingId.MaxFrameSize
        case 6u16 => Http2SettingId.MaxHeaderListSize
        case value => Http2SettingId.Unknown(value)
    }
}

public struct Http2Setting {
    public let identifier: Http2SettingId
    public let value: UInt32

    public init(identifier: Http2SettingId, value: UInt32) {
        validateHttp2Setting(identifier, value)
        this.identifier = identifier
        this.value = value
    }
}

/** A decoded frame header whose reserved bit and configured size bound are valid. */
public struct Http2FrameHeader {
    public let length: UInt32
    public let frameType: Http2FrameType
    public let flags: Http2Flags
    public let streamId: Http2StreamId

    public init(
        length: UInt32,
        frameType: Http2FrameType,
        flags: Http2Flags,
        streamId: Http2StreamId,
        limits!: Http2Limits = Http2Limits()
    ) {
        if (length > 16777215u32 || length > limits.maxFrameSize) {
            throw Http2ProtocolException(
                Http2ErrorCode.FrameSizeError,
                Http2ErrorScope.Connection,
                "HTTP/2 frame payload exceeds the configured maximum"
            )
        }
        validateHttp2FrameShape(length, frameType, flags, streamId)
        this.length = length
        this.frameType = frameType
        this.flags = flags
        this.streamId = streamId
    }
}

private func validateHttp2Setting(identifier: Http2SettingId, value: UInt32): Unit {
    match (identifier) {
        case Http2SettingId.EnablePush =>
            if (value > 1u32) { protocolError("HTTP/2 ENABLE_PUSH must be zero or one") }
        case Http2SettingId.InitialWindowSize =>
            if (value > 2147483647u32) {
                throw Http2ProtocolException(
                    Http2ErrorCode.FlowControlError,
                    Http2ErrorScope.Connection,
                    "HTTP/2 initial window must fit 31 bits"
                )
            }
        case Http2SettingId.MaxFrameSize =>
            if (value < 16384u32 || value > 16777215u32) {
                protocolError("HTTP/2 maximum frame size is outside the protocol range")
            }
        case _ => ()
    }
}

private func validateHttp2FrameShape(
    length: UInt32,
    frameType: Http2FrameType,
    flags: Http2Flags,
    streamId: Http2StreamId
): Unit {
    match (frameType) {
        case Http2FrameType.Settings =>
            requireConnectionFrame(streamId, "SETTINGS")
            if (flags.isAck() && length != 0u32) { frameSizeError("SETTINGS ACK must have an empty payload") }
            if (length % 6u32 != 0u32) { frameSizeError("SETTINGS payload must contain six-byte entries") }
        case Http2FrameType.Ping =>
            requireConnectionFrame(streamId, "PING")
            if (length != 8u32) { frameSizeError("PING payload must contain eight bytes") }
        case Http2FrameType.GoAway =>
            requireConnectionFrame(streamId, "GOAWAY")
            if (length < 8u32) { frameSizeError("GOAWAY payload must contain at least eight bytes") }
        case Http2FrameType.RstStream =>
            requireStreamFrame(streamId, "RST_STREAM")
            if (length != 4u32) { frameSizeError("RST_STREAM payload must contain four bytes") }
        case Http2FrameType.WindowUpdate =>
            if (length != 4u32) { frameSizeError("WINDOW_UPDATE payload must contain four bytes") }
        case Http2FrameType.Priority =>
            requireStreamFrame(streamId, "PRIORITY")
            if (length != 5u32) { frameSizeError("PRIORITY payload must contain five bytes") }
        case Http2FrameType.Data => requireStreamFrame(streamId, "DATA")
        case Http2FrameType.Headers => requireStreamFrame(streamId, "HEADERS")
        case Http2FrameType.PushPromise =>
            requireStreamFrame(streamId, "PUSH_PROMISE")
            if (length < 4u32) { frameSizeError("PUSH_PROMISE payload is too short") }
        case Http2FrameType.Continuation => requireStreamFrame(streamId, "CONTINUATION")
        case Http2FrameType.Unknown(_) => ()
    }
}

private func requireConnectionFrame(streamId: Http2StreamId, name: String): Unit {
    if (!streamId.isConnection()) { protocolError("HTTP/2 ${name} frame requires stream zero") }
}

private func requireStreamFrame(streamId: Http2StreamId, name: String): Unit {
    if (!streamId.isStream()) { protocolError("HTTP/2 ${name} frame requires a non-zero stream") }
}

private func frameSizeError(message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.FrameSizeError, Http2ErrorScope.Connection, message)
}

private func protocolError(message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection, message)
}

private func requirePositive(value: UInt32, name: String): Unit {
    if (value == 0u32) { throw IllegalArgumentException("HTTP/2 ${name} limit must be positive") }
}
