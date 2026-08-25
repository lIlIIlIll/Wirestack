package yjson

import std.collection.*
import std.convert.Parsable
import std.math.numeric.*

private let JSON_STREAM_TAPE_NULL: Byte = 0u8
private let JSON_STREAM_TAPE_BOOL: Byte = 1u8
private let JSON_STREAM_TAPE_INT: Byte = 2u8
private let JSON_STREAM_TAPE_NUMBER: Byte = 3u8
private let JSON_STREAM_TAPE_STRING: Byte = 4u8
private let JSON_STREAM_TAPE_ARRAY: Byte = 5u8
private let JSON_STREAM_TAPE_OBJECT: Byte = 6u8

private class JsonStreamTapeWriteContext {
    let objectContext: Bool
    let countPosition: Int64
    var count: UInt32 = 0u32
    var expectingValue: Bool = false

    init(objectContext: Bool, countPosition: Int64) {
        this.objectContext = objectContext
        this.countPosition = countPosition
    }
}

/// Matching-version Native bridge writer. Application codecs should depend on
/// `JsonCodecWriter`, not on this concrete tape representation.
public class JsonStreamTapeWriter <: JsonCodecWriter & JsonCodecBulkWriter {
    private let bytes = ArrayList<Byte>()
    private let contexts = ArrayList<JsonStreamTapeWriteContext>()
    private var rootWritten: Bool = false
    private var finished: Bool = false

    public init() {
        bytes.add(b'Y')
        bytes.add(b'J')
        bytes.add(b'T')
        bytes.add(b'1')
    }

    public func startObject(): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_OBJECT)
        let countPosition = bytes.size
        appendUInt32(0u32)
        contexts.add(JsonStreamTapeWriteContext(true, countPosition))
    }

    public func endObject(): Unit { endContainer(true) }

    public func startArray(): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_ARRAY)
        let countPosition = bytes.size
        appendUInt32(0u32)
        contexts.add(JsonStreamTapeWriteContext(false, countPosition))
    }

    public func endArray(): Unit { endContainer(false) }

    public func writeName(name: String): Unit {
        requireWritable()
        if (contexts.isEmpty()) { throw JsonException("Cannot write a field name outside object") }
        let context = contexts[contexts.size - 1]
        if (!context.objectContext || context.expectingValue) {
            throw JsonException("Cannot write a field name here")
        }
        appendString(name)
        context.expectingValue = true
    }

    public func writeNull(): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_NULL)
    }

    public func writeBool(value: Bool): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_BOOL)
        bytes.add(if (value) { 1u8 } else { 0u8 })
    }

    public func writeInt64(value: Int64): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_INT)
        appendUInt64(int64Bits(value))
    }

    public func writeUInt64(value: UInt64): Unit {
        if (value <= UInt64(0x7FFF_FFFF_FFFF_FFFF)) {
            writeInt64(Int64(value))
        } else {
            writeRawNumber(value.toString())
        }
    }

    public func writeFloat64(value: Float64): Unit {
        ensureFiniteJsonFloat(value)
        writeRawNumber(value.toString())
    }

    public func writeRawNumber(value: String): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_NUMBER)
        appendString(value)
    }

    public func writeString(value: String): Unit {
        beforeValue()
        bytes.add(JSON_STREAM_TAPE_STRING)
        appendString(value)
    }

    public func tryWriteCompactInt64ArrayList(values: ArrayList<Int64>): Bool {
        startArray()
        for (value in values) { writeInt64(value) }
        endArray()
        true
    }

    public func tryWriteCompactStringArrayList(values: ArrayList<String>): Bool {
        startArray()
        for (value in values) { writeString(value) }
        endArray()
        true
    }

    public func tryWriteCompactInt64Map(values: HashMap<String, Int64>): Bool {
        startObject()
        for ((name, value) in values) {
            writeName(name)
            writeInt64(value)
        }
        endObject()
        true
    }

    public func finishTape(): Array<Byte> {
        requireWritable()
        if (!contexts.isEmpty() || !rootWritten) {
            throw JsonException("Unbalanced JSON tape writer state", code: "codec_contract")
        }
        finished = true
        bytes.toArray()
    }

    private func beforeValue(): Unit {
        requireWritable()
        if (contexts.isEmpty()) {
            if (rootWritten) { throw JsonException("Only one root JSON value may be written") }
            rootWritten = true
            return
        }
        let context = contexts[contexts.size - 1]
        if (context.objectContext) {
            if (!context.expectingValue) {
                throw JsonException("Object values must be preceded by a field name")
            }
            context.expectingValue = false
        }
        if (context.count == 0xFFFF_FFFFu32) {
            throw JsonException("JSON container is too large", code: "output_too_large")
        }
        context.count++
    }

    private func endContainer(expectedObject: Bool): Unit {
        requireWritable()
        if (contexts.isEmpty()) { throw JsonException("Unbalanced JSON tape writer state") }
        let index = contexts.size - 1
        let context = contexts[index]
        if (context.objectContext != expectedObject || context.expectingValue) {
            throw JsonException("Unbalanced JSON tape writer state")
        }
        patchUInt32(context.countPosition, context.count)
        contexts.remove(at: index)
    }

    private func appendString(value: String): Unit {
        if (value.size > 0xFFFF_FFFF) {
            throw JsonException("JSON string is too large", code: "output_too_large")
        }
        appendUInt32(UInt32(value.size))
        bytes.add(all: unsafe { value.rawData() })
    }

    private func appendUInt32(value: UInt32): Unit {
        for (shift in 0..4) { bytes.add(UInt8(UInt64(value >> (shift * 8)) & 0xFFu64)) }
    }

    private func appendUInt64(value: UInt64): Unit {
        for (shift in 0..8) { bytes.add(UInt8((value >> (shift * 8)) & 0xFFu64)) }
    }

    private func patchUInt32(position: Int64, value: UInt32): Unit {
        for (shift in 0..4) {
            bytes[position + shift] = UInt8(UInt64(value >> (shift * 8)) & 0xFFu64)
        }
    }

    private func requireWritable(): Unit {
        if (finished) { throw IllegalStateException("JSON tape writer is finished") }
    }

    @OverflowWrapping
    private func int64Bits(value: Int64): UInt64 { UInt64(value) }
}

private class JsonStreamTapeReadContext {
    let objectContext: Bool
    var remaining: UInt32
    var expectingValue: Bool = false

    init(objectContext: Bool, remaining: UInt32) {
        this.objectContext = objectContext
        this.remaining = remaining
    }
}

/// Matching-version Native bridge reader for the compact preorder tape.
public class JsonStreamTapeReader <: JsonCodecReader {
    private let bytes: Array<Byte>
    private let config: JsonReadConfig
    private let replayBudgetPrevalidated: Bool
    private let contexts = ArrayList<JsonStreamTapeReadContext>()
    private var position: Int64 = 4
    private var rootConsumed: Bool = false
    private var valuePrefixReady: Bool = false

    public init(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults,
        replayBudgetPrevalidated!: Bool = false) {
        this.bytes = bytes
        this.config = config
        this.replayBudgetPrevalidated = replayBudgetPrevalidated
        if (bytes.size < 5 || bytes[0] != b'Y' || bytes[1] != b'J' ||
            bytes[2] != b'T' || bytes[3] != b'1') {
            throw JsonException("Invalid JSON stream tape", code: "codec_contract")
        }
    }

    public func readConfig(): JsonReadConfig { config }

    public func readReplayValue(maxBytes: Int64): JsonReplayValue {
        if (maxBytes < 0) { throw IllegalArgumentException("maxBytes must not be negative") }
        beforeValue()
        let start = position
        let end = scanValue(position)
        if (!replayBudgetPrevalidated && maxBytes > 0 && end - start > maxBytes) {
            throw JsonException("Polymorphic JSON object exceeds ${maxBytes} bytes",
                code: "polymorphic_object_too_large")
        }
        position = end
        let captured = ArrayList<Byte>()
        captured.add(b'Y'); captured.add(b'J'); captured.add(b'T'); captured.add(b'1')
        captured.add(all: bytes[start..end])
        JsonStreamTapeReplayValue(captured.toArray(), config)
    }

    public func expectEnd(): Unit {
        if (!contexts.isEmpty() || !rootConsumed || position != bytes.size) {
            fail("Unexpected trailing JSON tape data")
        }
    }

    public func startObject(): Unit {
        beforeValue()
        expectKind(JSON_STREAM_TAPE_OBJECT)
        contexts.add(JsonStreamTapeReadContext(true, readUInt32Raw()))
    }

    public func endObject(): Unit { endContainer(true) }

    public func hasObjectField(): Bool {
        let context = currentContext(true)
        !context.expectingValue && context.remaining > 0u32
    }

    public func readName(): String {
        let context = currentContext(true)
        if (context.expectingValue || context.remaining == 0u32) {
            fail("Cannot read a field name here")
        }
        let name = readStringRaw()
        context.expectingValue = true
        name
    }

    public func readNameId(candidates: Array<String>): Int64 {
        let name = readName()
        for (index in 0..candidates.size) {
            if (candidates[index] == name) { return index }
        }
        if (config.rejectsUnknownFields()) {
            throw JsonException("Unknown JSON field: ${name}", code: "unknown_field")
        }
        -1
    }

    public func startArray(): Unit {
        beforeValue()
        expectKind(JSON_STREAM_TAPE_ARRAY)
        contexts.add(JsonStreamTapeReadContext(false, readUInt32Raw()))
    }

    public func endArray(): Unit { endContainer(false) }

    public func hasArrayItem(): Bool {
        currentContext(false).remaining > 0u32
    }

    public func tryReadNull(): Bool {
        beforeValue()
        if (peekByte() != JSON_STREAM_TAPE_NULL) {
            valuePrefixReady = true
            return false
        }
        position++
        true
    }

    public func readNull(): Unit {
        beforeValue()
        expectKind(JSON_STREAM_TAPE_NULL)
    }

    public func readBool(): Bool {
        beforeValue()
        expectKind(JSON_STREAM_TAPE_BOOL)
        readByteRaw() != 0u8
    }

    public func readString(): String {
        beforeValue()
        expectKind(JSON_STREAM_TAPE_STRING)
        readStringRaw()
    }

    public func skipString(): Unit { let _ = readString() }

    public func readInt64(): Int64 {
        beforeValue()
        match {
            case peekByte() == JSON_STREAM_TAPE_INT => position++; bitsToInt64(readUInt64Raw())
            case peekByte() == JSON_STREAM_TAPE_NUMBER =>
                position++
                let literal = readStringRaw()
                try { Int64.parse(literal) } catch (_: Exception) { fail("Expected integer") }
            case _ => fail("Expected integer")
        }
    }

    public func readUInt64(): UInt64 {
        beforeValue()
        match {
            case peekByte() == JSON_STREAM_TAPE_INT =>
                position++
                let value = bitsToInt64(readUInt64Raw())
                if (value < 0) { fail("Expected unsigned integer") }
                UInt64(value)
            case peekByte() == JSON_STREAM_TAPE_NUMBER =>
                position++
                let literal = readStringRaw()
                try { UInt64.parse(literal) } catch (_: Exception) { fail("Expected unsigned integer") }
            case _ => fail("Expected unsigned integer")
        }
    }

    public func readFloat64(): Float64 { Float64.parse(readNumberLiteral()) }
    public func readBigInt(): BigInt { BigInt.parse(readNumberLiteral()) }
    public func readDecimal(): Decimal { Decimal.parse(readNumberLiteral()) }

    public func readNumberLiteral(): String {
        beforeValue()
        match {
            case peekByte() == JSON_STREAM_TAPE_INT => position++; bitsToInt64(readUInt64Raw()).toString()
            case peekByte() == JSON_STREAM_TAPE_NUMBER => position++; readStringRaw()
            case _ => fail("Expected number")
        }
    }

    public func skipValue(): Unit {
        beforeValue()
        position = scanValue(position)
    }

    public func skipValueWithDepth(maxDepth: Int64): Unit {
        if (maxDepth < 0) { throw IllegalArgumentException("maxDepth must not be negative") }
        beforeValue()
        position = scanValueBounded(position, 0, maxDepth)
    }

    func copyNextValueTo(writer: JsonCodecWriter): Unit {
        match {
            case peekByte() == JSON_STREAM_TAPE_NULL => readNull(); writer.writeNull()
            case peekByte() == JSON_STREAM_TAPE_BOOL => writer.writeBool(readBool())
            case peekByte() == JSON_STREAM_TAPE_INT => writer.writeInt64(readInt64())
            case peekByte() == JSON_STREAM_TAPE_NUMBER => writer.writeRawNumber(readNumberLiteral())
            case peekByte() == JSON_STREAM_TAPE_STRING => writer.writeString(readString())
            case peekByte() == JSON_STREAM_TAPE_ARRAY =>
                startArray(); writer.startArray()
                while (hasArrayItem()) { copyNextValueTo(writer) }
                endArray(); writer.endArray()
            case peekByte() == JSON_STREAM_TAPE_OBJECT =>
                startObject(); writer.startObject()
                while (hasObjectField()) {
                    let name = readName()
                    writer.writeName(name)
                    copyNextValueTo(writer)
                }
                endObject(); writer.endObject()
            case _ => fail("Unknown JSON tape value kind")
        }
    }

    func readNode(): JsonNode {
        match {
            case peekByte() == JSON_STREAM_TAPE_NULL => readNull(); JsonNullValue()
            case peekByte() == JSON_STREAM_TAPE_BOOL => JsonBoolValue(readBool())
            case peekByte() == JSON_STREAM_TAPE_INT => JsonIntValue(readInt64())
            case peekByte() == JSON_STREAM_TAPE_NUMBER =>
                let literal = readNumberLiteral()
                match (config.numberPolicy) {
                    case JsonNumberPolicy.Int64WhenExact =>
                        try { JsonIntValue(Int64.parse(literal)) }
                        catch (_: Exception) { JsonNumberLiteralValue.fromParsedLiteral(literal) }
                    case _ => JsonNumberLiteralValue.fromParsedLiteral(literal)
                }
            case peekByte() == JSON_STREAM_TAPE_STRING => JsonStringValue(readString())
            case peekByte() == JSON_STREAM_TAPE_ARRAY =>
                let value = JsonArrayValue(); startArray()
                while (hasArrayItem()) { value.add(readNode()) }
                endArray(); value
            case peekByte() == JSON_STREAM_TAPE_OBJECT =>
                let value = JsonObjectValue(); startObject()
                while (hasObjectField()) { value.put(readName(), readNode()) }
                endObject(); value
            case _ => fail("Unknown JSON tape value kind")
        }
    }

    private func beforeValue(): Unit {
        if (valuePrefixReady) { valuePrefixReady = false; return }
        if (contexts.isEmpty()) {
            if (rootConsumed) { fail("Only one root JSON value may be read") }
            rootConsumed = true
            return
        }
        let context = contexts[contexts.size - 1]
        if (context.remaining == 0u32) { fail("JSON container has no remaining values") }
        if (context.objectContext) {
            if (!context.expectingValue) { fail("Object values must follow a field name") }
            context.expectingValue = false
        }
        context.remaining--
    }

    private func endContainer(expectedObject: Bool): Unit {
        let context = currentContext(expectedObject)
        if (context.remaining != 0u32 || context.expectingValue) {
            fail("JSON container was not fully consumed")
        }
        contexts.remove(at: contexts.size - 1)
    }

    private func currentContext(expectedObject: Bool): JsonStreamTapeReadContext {
        if (contexts.isEmpty()) { fail("Not reading a JSON container") }
        let context = contexts[contexts.size - 1]
        if (context.objectContext != expectedObject) { fail("JSON container type mismatch") }
        context
    }

    private func scanValue(start: Int64): Int64 {
        var cursor = start
        let kind = byteAt(cursor); cursor++
        match {
            case kind == JSON_STREAM_TAPE_NULL => cursor
            case kind == JSON_STREAM_TAPE_BOOL => requireRange(cursor, 1); cursor + 1
            case kind == JSON_STREAM_TAPE_INT => requireRange(cursor, 8); cursor + 8
            case kind == JSON_STREAM_TAPE_NUMBER || kind == JSON_STREAM_TAPE_STRING => scanString(cursor)
            case kind == JSON_STREAM_TAPE_ARRAY =>
                let count = uint32At(cursor); cursor += 4
                for (_ in 0..Int64(count)) { cursor = scanValue(cursor) }
                cursor
            case kind == JSON_STREAM_TAPE_OBJECT =>
                let count = uint32At(cursor); cursor += 4
                for (_ in 0..Int64(count)) {
                    cursor = scanString(cursor)
                    cursor = scanValue(cursor)
                }
                cursor
            case _ => fail("Unknown JSON tape value kind")
        }
    }

    private func scanValueBounded(start: Int64, depth: Int64, maxDepth: Int64): Int64 {
        var cursor = start
        let kind = byteAt(cursor); cursor++
        match {
            case kind == JSON_STREAM_TAPE_NULL => cursor
            case kind == JSON_STREAM_TAPE_BOOL => requireRange(cursor, 1); cursor + 1
            case kind == JSON_STREAM_TAPE_INT => requireRange(cursor, 8); cursor + 8
            case kind == JSON_STREAM_TAPE_NUMBER || kind == JSON_STREAM_TAPE_STRING => scanString(cursor)
            case kind == JSON_STREAM_TAPE_ARRAY =>
                requireSkippedContainerDepth(depth, maxDepth)
                let count = uint32At(cursor); cursor += 4
                for (_ in 0..Int64(count)) {
                    cursor = scanValueBounded(cursor, depth + 1, maxDepth)
                }
                cursor
            case kind == JSON_STREAM_TAPE_OBJECT =>
                requireSkippedContainerDepth(depth, maxDepth)
                let count = uint32At(cursor); cursor += 4
                for (_ in 0..Int64(count)) {
                    cursor = scanString(cursor)
                    cursor = scanValueBounded(cursor, depth + 1, maxDepth)
                }
                cursor
            case _ => fail("Unknown JSON tape value kind")
        }
    }

    private func requireSkippedContainerDepth(depth: Int64, maxDepth: Int64): Unit {
        if (depth >= maxDepth) {
            throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth")
        }
    }

    private func scanString(start: Int64): Int64 {
        let size = Int64(uint32At(start))
        requireRange(start + 4, size)
        start + 4 + size
    }

    private func readStringRaw(): String {
        let size = Int64(readUInt32Raw())
        requireRange(position, size)
        let value = unsafe { String.fromUtf8Unchecked(bytes[position..position + size]) }
        position += size
        value
    }

    private func readByteRaw(): Byte {
        let value = byteAt(position)
        position++
        value
    }

    private func peekByte(): Byte { byteAt(position) }

    private func expectKind(expected: Byte): Unit {
        if (readByteRaw() != expected) { fail("JSON value type mismatch") }
    }

    private func readUInt32Raw(): UInt32 {
        let value = uint32At(position)
        position += 4
        value
    }

    private func readUInt64Raw(): UInt64 {
        requireRange(position, 8)
        var value = 0u64
        for (shift in 0..8) { value |= UInt64(bytes[position + shift]) << (shift * 8) }
        position += 8
        value
    }

    private func uint32At(start: Int64): UInt32 {
        requireRange(start, 4)
        var value = 0u32
        for (shift in 0..4) { value |= UInt32(bytes[start + shift]) << (shift * 8) }
        value
    }

    private func byteAt(index: Int64): Byte {
        requireRange(index, 1)
        bytes[index]
    }

    private func requireRange(start: Int64, size: Int64): Unit {
        if (start < 0 || size < 0 || start > bytes.size - size) {
            fail("Truncated JSON stream tape")
        }
    }

    private func fail(message: String): Nothing {
        throw JsonException(message, code: "parse_error")
    }

    @OverflowWrapping
    private func bitsToInt64(value: UInt64): Int64 { Int64(value) }
}

private class JsonStreamTapeReplayValue <: JsonReplayValue {
    private let tape: Array<Byte>
    private let config: JsonReadConfig
    private var closed: Bool = false

    init(tape: Array<Byte>, config: JsonReadConfig) {
        this.tape = tape
        this.config = config
    }

    public func isClosed(): Bool { closed }
    public func close(): Unit { closed = true }

    public func rootStringField(name: String): Option<String> {
        requireOpen()
        let reader = JsonStreamTapeReader(tape, config: config)
        var result = None<String>
        reader.startObject()
        while (reader.hasObjectField()) {
            let current = reader.readName()
            if (current == name) { result = Some(reader.readString()) }
            else { reader.skipValue() }
        }
        reader.endObject(); reader.expectEnd()
        result
    }

    public func openObjectReaderExcluding(name: String): JsonCodecReader {
        requireOpen()
        let reader = JsonStreamTapeReader(tape, config: config)
        let writer = JsonStreamTapeWriter()
        reader.startObject(); writer.startObject()
        while (reader.hasObjectField()) {
            let current = reader.readName()
            if (current == name) {
                reader.skipValue()
            } else {
                writer.writeName(current)
                reader.copyNextValueTo(writer)
            }
        }
        reader.endObject(); reader.expectEnd(); writer.endObject()
        JsonStreamTapeReader(writer.finishTape(), config: config)
    }

    public func materialize(): JsonNode {
        requireOpen()
        let reader = JsonStreamTapeReader(tape, config: config)
        let value = reader.readNode()
        reader.expectEnd()
        value
    }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("JSON replay value is closed") }
    }
}

@OverflowWrapping
private func int64Bits(value: Int64): UInt64 { UInt64(value) }
