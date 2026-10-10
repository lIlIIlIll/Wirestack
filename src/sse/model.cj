package wirestack.sse

/** Stable SSE codec and session failure categories. */
public enum SseErrorCode <: Equatable<SseErrorCode> {
    /** A raw input or encoded line exceeds its configured bound. */
    | LineLimit
    /** A blank-delimited block exceeds its configured byte bound. */
    | EventLimit
    /** A block contains too many fields, including comments and unknown fields. */
    | FieldLimit
    /** Too many input bytes have arrived without a dispatched data event. */
    | NoProgress
    /** A decoded or encoded cursor exceeds its UTF-8 byte bound. */
    | IdLimit
    /** A value cannot be represented safely by the encoder or session. */
    | InvalidMetadata
    /** The codec or session is closed or finished. */
    | Closed
    /** A single-owner operation overlaps another operation. */
    | ConcurrentOperation
    /** The HTTP response is not an acceptable event stream. */
    | InvalidResponse
    /** The explicit reconnection policy is exhausted. */
    | ReconnectLimit

    /** Compares stable SSE failure categories.
     * @param other Failure category to compare.
     */
    public operator func ==(other: SseErrorCode): Bool {
        match ((this, other)) {
            case (SseErrorCode.LineLimit, SseErrorCode.LineLimit) => true
            case (SseErrorCode.EventLimit, SseErrorCode.EventLimit) => true
            case (SseErrorCode.FieldLimit, SseErrorCode.FieldLimit) => true
            case (SseErrorCode.NoProgress, SseErrorCode.NoProgress) => true
            case (SseErrorCode.IdLimit, SseErrorCode.IdLimit) => true
            case (SseErrorCode.InvalidMetadata, SseErrorCode.InvalidMetadata) => true
            case (SseErrorCode.Closed, SseErrorCode.Closed) => true
            case (SseErrorCode.ConcurrentOperation, SseErrorCode.ConcurrentOperation) => true
            case (SseErrorCode.InvalidResponse, SseErrorCode.InvalidResponse) => true
            case (SseErrorCode.ReconnectLimit, SseErrorCode.ReconnectLimit) => true
            case _ => false
        }
    }
    /** Compares whether stable SSE failure categories differ.
     * @param other Failure category to compare.
     */
    public operator func !=(other: SseErrorCode): Bool { !(this == other) }
}

/** An SSE failure with a stable code and optional original cause. */
public class SseException <: Exception {
    /** Stable machine-readable category. */
    public let code: SseErrorCode
    /** Original failure, when present. */
    public let cause: ?Exception
    /**
     * Constructs an SSE failure.
     * @param code Stable failure category.
     * @param message Human-readable diagnostic, not a control-flow value.
     * @param cause Original failure, if any.
     */
    public init(code: SseErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }
    /** Returns the exception's diagnostic class name. */
    protected override func getClassName(): String { "SseException" }
}

/** An immutable event. Decoding does not interpret application payloads. */
public class SseEvent {
    /** Payload with data lines joined by LF. An empty payload is a dispatched event. */
    public let data: String
    /** Event name, defaulting to message when the wire field is empty. */
    public let eventType: String
    /** Parsed cursor, not an application processing acknowledgement. */
    public let lastEventId: String
    /**
     * Constructs an event value. The encoder validates representability.
     * @param data Application payload.
     * @param eventType Event name.
     * @param lastEventId Cursor, including an explicit empty cursor.
     */
    public init(data: String, eventType!: String = "message", lastEventId!: String = "") {
        this.data = data
        this.eventType = eventType
        this.lastEventId = lastEventId
    }
}

/** Immutable resource bounds. Byte limits are UTF-8 bytes, never character counts. */
public class SseLimits {
    /** Maximum raw bytes in a line, excluding its terminator and initial BOM. */
    public let maximumLineBytes: Int64
    /** Maximum raw bytes per block, including terminators. CRLF counts as one terminator. */
    public let maximumEventBytes: Int64
    /** Maximum nonempty lines per block, including comments and ignored fields. */
    public let maximumFieldsPerEvent: Int64
    /** Maximum wire bytes since the last dispatched event, including BOM and CRLF. */
    public let maximumBytesWithoutEvent: Int64
    /** Maximum decoded cursor UTF-8 bytes. */
    public let maximumIdBytes: Int64
    /** Maximum accepted retry value. Larger digit-only values are clamped. */
    public let maximumRetryMilliseconds: UInt64
    /**
     * Conservative peak decoder-owned byte-array/string storage reservation.
     * Includes replacement expansion, temporary string conversion, and pending metadata.
     * Caller-owned input chunks and returned events are excluded; there is no event queue.
     */
    public prop maximumRetainedBytes: UInt64 {
        get() { UInt64(12 * maximumEventBytes + 18 * maximumLineBytes + 6 * maximumIdBytes + 256) }
    }
    /**
     * Validates positive limits against fixed hard ceilings.
     * @param maximumLineBytes Raw line bound, at most 1 MiB.
     * @param maximumEventBytes Raw block bound, at most 16 MiB.
     * @param maximumFieldsPerEvent Field count bound, at most 65536.
     * @param maximumBytesWithoutEvent No-progress wire bound, at most 64 MiB.
     * @param maximumIdBytes Cursor bound, at most 64 KiB.
     * @param maximumRetryMilliseconds Retry cap, at most one day; zero disables server delay.
     */
    public init(maximumLineBytes!: Int64 = 16 * 1024,
        maximumEventBytes!: Int64 = 256 * 1024,
        maximumFieldsPerEvent!: Int64 = 1024,
        maximumBytesWithoutEvent!: Int64 = 1024 * 1024,
        maximumIdBytes!: Int64 = 4096,
        maximumRetryMilliseconds!: UInt64 = 60000u64) {
        checkSseLimit(maximumLineBytes, 1024 * 1024)
        checkSseLimit(maximumEventBytes, 16 * 1024 * 1024)
        checkSseLimit(maximumFieldsPerEvent, 65536)
        checkSseLimit(maximumBytesWithoutEvent, 64 * 1024 * 1024)
        checkSseLimit(maximumIdBytes, 64 * 1024)
        if (maximumRetryMilliseconds > 86400000u64) {
            throw IllegalArgumentException("SSE retry cap exceeds one day")
        }
        this.maximumLineBytes = maximumLineBytes
        this.maximumEventBytes = maximumEventBytes
        this.maximumFieldsPerEvent = maximumFieldsPerEvent
        this.maximumBytesWithoutEvent = maximumBytesWithoutEvent
        this.maximumIdBytes = maximumIdBytes
        this.maximumRetryMilliseconds = maximumRetryMilliseconds
    }
}

private func checkSseLimit(value: Int64, ceiling: Int64): Unit {
    if (value <= 0 || value > ceiling) { throw IllegalArgumentException("invalid SSE resource limit") }
}

/** One incremental decode step, with no retained event queue. */
public class SseDecodeResult {
    /** Bytes consumed from the supplied window, not an absolute offset. */
    public let consumed: Int64
    /** First complete event, if any. The caller retains all unconsumed input. */
    public let event: ?SseEvent
    /**
     * Constructs a result.
     * @param consumed Relative consumed-byte count.
     * @param event Optional dispatched event.
     */
    public init(consumed: Int64, event: ?SseEvent) {
        this.consumed = consumed
        this.event = event
    }
}
