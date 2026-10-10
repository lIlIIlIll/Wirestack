package wirestack.sse

/** Incremental WHATWG SSE decoder. One owner must serialize all access. */
public class SseDecoder {
    private let limits: SseLimits
    private var line: Array<Byte>
    private var scratch: Array<Byte>
    private var data: Array<Byte>
    private var lineSize: Int64 = 0
    private var dataSize: Int64 = 0
    private var fields: Int64 = 0
    private var blockBytes: Int64 = 0
    private var withoutEvent: Int64 = 0
    private var eventName = ""
    private var pendingId: String
    private var cursor: String
    private var retry: ?UInt64 = None<UInt64>
    private var initial = true
    private var bomSize: Int64 = 0
    private var bom = Array<Byte>(3, repeat: 0u8)
    private var skipLf = false
    private var ended = false
    private var closed = false

    /** Last cursor committed at a blank line, even for an id-only block. */
    public prop lastEventId: String { get() { cursor } }
    /** Last valid digit-only retry, applied at its line ending and clamped. */
    public prop retryMilliseconds: ?UInt64 { get() { retry } }
    /** Current retained arrays and UTF-8 strings, excluding returned events and input. */
    public prop retainedBytes: UInt64 {
        get() {
            UInt64(line.size + scratch.size + data.size + bom.size +
                eventName.size + pendingId.size + cursor.size)
        }
    }
    /**
     * Creates a bounded decoder. Malformed UTF-8 is replaced, never rejected.
     * @param limits Validated decoder resource limits.
     * @param lastEventId Initial committed cursor, without CR, LF, or NUL.
     */
    public init(limits!: SseLimits = SseLimits(), lastEventId!: String = "") {
        if (lastEventId.size > limits.maximumIdBytes) {
            throw SseException(SseErrorCode.IdLimit, "initial SSE cursor exceeds limit")
        }
        for (i in 0..lastEventId.size) {
            let byte = lastEventId[i]
            if (byte == 0u8 || byte == 10u8 || byte == 13u8) {
                throw SseException(SseErrorCode.InvalidMetadata, "invalid initial SSE cursor")
            }
        }
        this.limits = limits
        this.cursor = lastEventId
        this.pendingId = lastEventId
        this.line = Array<Byte>(limits.maximumLineBytes, repeat: 0u8)
        this.scratch = Array<Byte>(3 * limits.maximumLineBytes, repeat: 0u8)
        this.data = Array<Byte>(3 * limits.maximumEventBytes, repeat: 0u8)
    }
    /**
     * Consumes a window and stops immediately after its first dispatched event.
     * Resource failures close the decoder and release storage before throwing.
     * @param bytes Caller-owned input, not retained by the decoder.
     * @param offset Start of the input window.
     * @param length Window length, defaulting to the remaining array.
     * @return Relative consumed-byte count and at most one event.
     */
    public func decode(bytes: Array<Byte>, offset!: Int64 = 0,
        length!: ?Int64 = None<Int64>): SseDecodeResult {
        if (closed || ended) { throw SseException(SseErrorCode.Closed, "SSE decoder is closed") }
        if (offset < 0 || offset > bytes.size) { throw IllegalArgumentException("invalid SSE input offset") }
        let count = length.getOrDefault({ => bytes.size - offset })
        if (count < 0 || count > bytes.size - offset) { throw IllegalArgumentException("invalid SSE input length") }
        var consumed: Int64 = 0
        try {
            while (consumed < count) {
                if (withoutEvent >= limits.maximumBytesWithoutEvent) {
                    throw SseException(SseErrorCode.NoProgress, "SSE stream made no event progress")
                }
                withoutEvent++
                let byte = bytes[offset + consumed]
                consumed++
                let event = accept(byte)
                if (event.isSome()) { return SseDecodeResult(consumed, event) }
            }
        } catch (error: SseException) {
            close()
            throw error
        }
        SseDecodeResult(consumed, None<SseEvent>)
    }
    /** Discards unfinished lines/events without dispatch. The decoder cannot be reused. */
    public func finish(): Unit {
        if (closed || ended) { return }
        ended = true
        releaseBuffers()
        pendingId = cursor
    }
    /** Idempotently releases all arrays and strings, including cursor and retry state. */
    public func close(): Unit {
        if (closed) { return }
        closed = true
        releaseBuffers()
        pendingId = ""
        cursor = ""
        retry = None<UInt64>
    }
    private func releaseBuffers(): Unit {
        line = Array<Byte>()
        scratch = Array<Byte>()
        data = Array<Byte>()
        bom = Array<Byte>()
        lineSize = 0
        dataSize = 0
        fields = 0
        blockBytes = 0
        bomSize = 0
        eventName = ""
    }
    private func accept(byte: Byte): ?SseEvent {
        if (!initial) { return acceptLineByte(byte) }
        bom[bomSize] = byte
        bomSize++
        let expected = if (bomSize == 1) { 239u8 } else if (bomSize == 2) { 187u8 } else { 191u8 }
        if (byte == expected) {
            if (bomSize == 3) { initial = false; bomSize = 0 }
            return None<SseEvent>
        }
        initial = false
        // A failed BOM prefix cannot contain a blank line before its last byte.
        var event: ?SseEvent = None<SseEvent>
        for (index in 0..bomSize) { event = acceptLineByte(bom[index]) }
        bomSize = 0
        event
    }
    private func acceptLineByte(byte: Byte): ?SseEvent {
        if (skipLf) {
            skipLf = false
            if (byte == 10u8) { return None<SseEvent> }
        }
        if (blockBytes >= limits.maximumEventBytes) {
            throw SseException(SseErrorCode.EventLimit, "SSE block exceeds byte limit")
        }
        blockBytes++
        if (byte == 10u8 || byte == 13u8) {
            skipLf = byte == 13u8
            let event = processLine()
            lineSize = 0
            return event
        }
        if (lineSize >= limits.maximumLineBytes) {
            throw SseException(SseErrorCode.LineLimit, "SSE line exceeds byte limit")
        }
        line[lineSize] = byte
        lineSize++
        None<SseEvent>
    }
    private func processLine(): ?SseEvent {
        if (lineSize == 0) {
            cursor = pendingId
            fields = 0
            blockBytes = 0
            if (dataSize == 0) { eventName = ""; return None<SseEvent> }
            let payload = String.fromUtf8(data[0..dataSize - 1])
            let event = SseEvent(payload,
                eventType: if (eventName.isEmpty()) { "message" } else { eventName }, lastEventId: cursor)
            dataSize = 0
            eventName = ""
            withoutEvent = 0
            return Some(event)
        }
        if (fields >= limits.maximumFieldsPerEvent) {
            throw SseException(SseErrorCode.FieldLimit, "SSE block exceeds field limit")
        }
        fields++
        if (line[0] == 58u8) { return None<SseEvent> }
        var colon: Int64 = 0
        while (colon < lineSize && line[colon] != 58u8) { colon++ }
        var start = if (colon == lineSize) { lineSize } else { colon + 1 }
        if (start < lineSize && line[start] == 32u8) { start++ }
        if (fieldIs(colon, "retry")) {
            parseRetry(start)
        } else if (fieldIs(colon, "data")) {
            let size = replaceUtf8(start)
            if (size + 1 > data.size - dataSize) {
                throw SseException(SseErrorCode.EventLimit, "SSE decoded payload exceeds bound")
            }
            scratch.copyTo(data, 0, dataSize, size)
            dataSize += size
            data[dataSize] = 10u8
            dataSize++
        } else if (fieldIs(colon, "event")) {
            let size = replaceUtf8(start)
            eventName = String.fromUtf8(scratch[0..size])
        } else if (fieldIs(colon, "id")) {
            for (index in start..lineSize) {
                if (line[index] == 0u8) { return None<SseEvent> }
            }
            let size = replaceUtf8(start)
            if (size > limits.maximumIdBytes) {
                throw SseException(SseErrorCode.IdLimit, "SSE cursor exceeds byte limit")
            }
            pendingId = String.fromUtf8(scratch[0..size])
        }
        None<SseEvent>
    }
    private func fieldIs(size: Int64, name: String): Bool {
        if (size != name.size) { return false }
        for (index in 0..size) { if (line[index] != name[index]) { return false } }
        true
    }
    private func parseRetry(start: Int64): Unit {
        if (start == lineSize) { return }
        var value = 0u64
        let cap = limits.maximumRetryMilliseconds
        for (index in start..lineSize) {
            let byte = line[index]
            if (byte < 48u8 || byte > 57u8) { return }
            let digit = UInt64(byte - 48u8)
            if (value > cap / 10u64 || (value == cap / 10u64 && digit > cap % 10u64)) {
                value = cap
            } else { value = value * 10u64 + digit }
        }
        retry = Some(value)
    }
    // Encoding Standard UTF-8 decoder: invalid continuation is reprocessed;
    // an incomplete valid prefix produces one replacement, not one per byte.
    private func replaceUtf8(start: Int64): Int64 {
        var input = start
        var output: Int64 = 0
        while (input < lineSize) {
            let first = line[input]
            if (first <= 127u8) { scratch[output] = first; output++; input++; continue }
            var count: Int64 = 0
            var lower = 128u8
            var upper = 191u8
            if (first >= 194u8 && first <= 223u8) { count = 2 }
            else if (first >= 224u8 && first <= 239u8) {
                count = 3
                if (first == 224u8) { lower = 160u8 }
                if (first == 237u8) { upper = 159u8 }
            } else if (first >= 240u8 && first <= 244u8) {
                count = 4
                if (first == 240u8) { lower = 144u8 }
                if (first == 244u8) { upper = 143u8 }
            }
            if (count == 0) { output = replacement(output); input++; continue }
            var accepted: Int64 = 1
            while (accepted < count && input + accepted < lineSize) {
                let next = line[input + accepted]
                if (next < lower || next > upper) { break }
                accepted++
                lower = 128u8
                upper = 191u8
            }
            if (accepted != count) {
                output = replacement(output)
                input += accepted
            } else {
                line.copyTo(scratch, input, output, count)
                input += count
                output += count
            }
        }
        output
    }
    private func replacement(offset: Int64): Int64 {
        scratch[offset] = 239u8
        scratch[offset + 1] = 191u8
        scratch[offset + 2] = 189u8
        offset + 3
    }
}
