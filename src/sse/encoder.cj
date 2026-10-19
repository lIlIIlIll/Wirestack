package wirestack.sse

import std.convert.*

/** Encodes representable SSE events without retaining an event queue. */
public class SseEncoder {
    private let limits: SseLimits

    /** Creates an encoder.
     * @param limits Bounds checked before allocating the encoded result.
     */
    public init(limits!: SseLimits = SseLimits()) { this.limits = limits }

    /** Encodes one event, including its terminating blank line.
     * Empty data dispatches an event. Empty id explicitly clears the cursor.
     * CR in data and empty event types are not representable and are rejected.
     * @param event Event whose data may contain LF-separated lines.
     * @param retryMilliseconds Optional retry delay, clamped to the configured maximum.
     * @return Complete UTF-8 event bytes.
     */
    public func encode(event: SseEvent, retryMilliseconds!: ?UInt64 = None<UInt64>): Array<Byte> {
        requireSize(event.data, limits.maximumEventBytes, SseErrorCode.EventLimit)
        requireSize(event.eventType, limits.maximumLineBytes, SseErrorCode.LineLimit)
        requireSize(event.lastEventId, limits.maximumIdBytes, SseErrorCode.IdLimit)
        metadata(event.eventType)
        metadata(event.lastEventId)
        if (event.eventType.isEmpty()) {
            throw SseException(SseErrorCode.InvalidMetadata, "empty event type cannot roundtrip")
        }
        let retry = match (retryMilliseconds) {
            case Some(value) => min(value, limits.maximumRetryMilliseconds).toString()
            case None => ""
        }
        line(event.eventType.size + 7)
        line(event.lastEventId.size + 4)
        if (retryMilliseconds.isSome()) { line(retry.size + 7) }
        var fields: Int64 = 3 + if (retryMilliseconds.isSome()) { 1 } else { 0 }
        var total = event.eventType.size + event.lastEventId.size + 14 + event.data.size + 7
        if (retryMilliseconds.isSome()) { total += retry.size + 8 }
        var current: Int64 = 6
        for (i in 0..event.data.size) {
            let byte = event.data[i]
            if (byte == 13) { throw SseException(SseErrorCode.InvalidMetadata, "data must not contain CR") }
            if (byte == 10) { line(current); current = 6; fields++; total += 6 }
            else { current++; line(current) }
        }
        line(current)
        block(total, fields)
        let result = Array<Byte>(total, repeat: 0u8)
        var offset = copyText(result, 0, "event: ")
        offset = copyText(result, offset, event.eventType)
        result[offset] = 10; offset++
        offset = copyText(result, offset, "id: ")
        offset = copyText(result, offset, event.lastEventId)
        result[offset] = 10; offset++
        if (retryMilliseconds.isSome()) {
            offset = copyText(result, offset, "retry: ")
            offset = copyText(result, offset, retry)
            result[offset] = 10; offset++
        }
        offset = copyText(result, offset, "data: ")
        for (i in 0..event.data.size) {
            result[offset] = event.data[i]; offset++
            if (event.data[i] == 10) { offset = copyText(result, offset, "data: ") }
        }
        result[offset] = 10; result[offset + 1] = 10
        result
    }

    /** Encodes LF-separated comment lines followed by a blank line.
     * @param value Comment text, without CR or NUL.
     * @return Bounded UTF-8 comment bytes.
     */
    public func comment(value: String): Array<Byte> {
        requireSize(value, limits.maximumEventBytes, SseErrorCode.EventLimit)
        var fields: Int64 = 1
        var total = value.size + 4
        var current: Int64 = 2
        for (i in 0..value.size) {
            let byte = value[i]
            if (byte == 13 || byte == 0) { throw SseException(SseErrorCode.InvalidMetadata, "comment must not contain CR or NUL") }
            if (byte == 10) { line(current); current = 2; fields++; total += 2 }
            else { current++; line(current) }
        }
        line(current); block(total, fields)
        let result = Array<Byte>(total, repeat: 0u8)
        var offset = copyText(result, 0, ": ")
        for (i in 0..value.size) {
            result[offset] = value[i]; offset++
            if (value[i] == 10) { offset = copyText(result, offset, ": ") }
        }
        result[offset] = 10; result[offset + 1] = 10
        result
    }

    private func line(bytes: Int64): Unit {
        requireCount(bytes, limits.maximumLineBytes, SseErrorCode.LineLimit)
    }
    private func block(bytes: Int64, fields: Int64): Unit {
        requireCount(bytes, limits.maximumEventBytes, SseErrorCode.EventLimit)
        requireCount(bytes, limits.maximumBytesWithoutEvent, SseErrorCode.NoProgress)
        requireCount(fields, limits.maximumFieldsPerEvent, SseErrorCode.FieldLimit)
    }
}

private func requireCount(value: Int64, maximum: Int64, code: SseErrorCode): Unit {
    if (value > maximum) { throw SseException(code, "SSE encoding exceeds configured bound") }
}
private func requireSize(value: String, maximum: Int64, code: SseErrorCode): Unit {
    requireCount(value.size, maximum, code)
}
private func metadata(value: String): Unit {
    for (i in 0..value.size) {
        if (value[i] == 0 || value[i] == 10 || value[i] == 13) {
            throw SseException(SseErrorCode.InvalidMetadata, "SSE metadata must not contain CR, LF or NUL")
        }
    }
}
private func copyText(destination: Array<Byte>, offset: Int64, value: String): Int64 {
    for (i in 0..value.size) { destination[offset + i] = value[i] }
    offset + value.size
}
