package yjson

import std.collection.*
import std.io.*
import std.math.numeric.*
import std.time.*

/// Backend-neutral semantic reader consumed by typed JSON codecs.
///
/// `JsonFastReader` remains a separate generated-code optimization contract;
/// implementations of this interface must preserve the normal configured
/// parsing, resource-limit, and error-location semantics.
public interface JsonReader {
    func path(): String
    func location(): Option<JsonLocation>
    func error(message: String, code: String): JsonException
    func startObject(): Unit
    func endObject(): Unit
    func hasObjectField(): Bool
    func readName(): String
    func startArray(): Unit
    func endArray(): Unit
    func hasArrayItem(): Bool
    func tryReadNull(): Bool
    func readNull(): Unit
    func readBool(): Bool
    func readString(): String
    func readInt64(): Int64
    func readUInt64(): UInt64
    func readFloat64(): Float64
    func readBigInt(): BigInt
    func readDecimal(): Decimal
    func readNumberLiteral(): String
    func skipValue(): Unit
    func readNode(): JsonNode
}

/// A captured JSON value that can be replayed without serializing and parsing
/// it again. This is public because generated codecs live in a separate
/// package; applications normally do not need to implement it.
public interface GeneratedReplayValueV1 <: Resource {
    func rootStringField(name: String): Option<String>

    /// Opens a fresh reader over the captured root object while omitting every
    /// occurrence of `name`. Duplicate rejection has already happened when the
    /// value was captured; LastWins lookup is used by `rootStringField`.
    func openObjectReaderExcluding(name: String): JsonReader

    func materialize(): JsonNode
}

/// Backend-neutral semantic writer consumed by typed JSON codecs.
public interface JsonWriter {
    func path(): String
    func error(message: String, code: String): JsonException
    func startObject(): Unit
    func endObject(): Unit
    func startArray(): Unit
    func endArray(): Unit
    func writeName(name: String): Unit
    func writeNull(): Unit
    func writeBool(value: Bool): Unit
    func writeInt64(value: Int64): Unit
    func writeUInt64(value: UInt64): Unit
    func writeFloat64(value: Float64): Unit
    func writeNumberLiteral(value: String): Unit
    func writeString(value: String): Unit
}

// Runtime-owned cursor state used only by the matching generated-code SPI.
// It is deliberately absent from JsonCodec, JsonReader, and JsonWriter so
// application codecs never manage mutable path or depth bookkeeping.
public interface GeneratedWriteStateV1Owner {
    func generatedWriteStateV1(): GeneratedWriteStateV1
}

interface GeneratedReadStateV1Owner {
    func generatedReadStateV1(): GeneratedReadStateV1
}

/// Optional bulk hooks used by generated and built-in codecs. Returning false
/// asks the codec to use the structural `JsonWriter` fallback.
public interface GeneratedBulkWriterV1 {
    func tryWriteCompactInt64Array(values: Array<Int64>): Bool
    func tryWriteCompactFloat64Array(values: Array<Float64>): Bool
    func tryWriteCompactStringArray(values: Array<String>): Bool
    func tryWriteCompactInt64ArrayList(values: ArrayList<Int64>): Bool
    func tryWriteCompactStringArrayList(values: ArrayList<String>): Bool
    func tryWriteCompactInt64Map(values: HashMap<String, Int64>): Bool
    func tryWriteCompactStringMap(values: HashMap<String, String>): Bool
    func tryWriteCompactInt64ArrayMap(values: HashMap<String, Array<Int64>>): Bool
}

public func jsonTryWriteCompactInt64Array(
    writer: JsonWriter,
    values: Array<Int64>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactInt64Array(values)
        case _ => false
    }
}

public func jsonTryWriteCompactFloat64Array(
    writer: JsonWriter,
    values: Array<Float64>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactFloat64Array(values)
        case _ => false
    }
}

public func jsonTryWriteCompactStringArray(
    writer: JsonWriter,
    values: Array<String>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactStringArray(values)
        case _ => false
    }
}

public func jsonTryWriteCompactInt64ArrayList(
    writer: JsonWriter,
    values: ArrayList<Int64>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactInt64ArrayList(values)
        case _ => false
    }
}

public func jsonTryWriteCompactStringArrayList(
    writer: JsonWriter,
    values: ArrayList<String>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactStringArrayList(values)
        case _ => false
    }
}

public func jsonTryWriteCompactInt64Map(
    writer: JsonWriter,
    values: HashMap<String, Int64>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactInt64Map(values)
        case _ => false
    }
}

public func jsonTryWriteCompactStringMap(
    writer: JsonWriter,
    values: HashMap<String, String>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactStringMap(values)
        case _ => false
    }
}

public func jsonTryWriteCompactInt64ArrayMap(
    writer: JsonWriter,
    values: HashMap<String, Array<Int64>>
): Bool {
    match (writer) {
        case bulk: GeneratedBulkWriterV1 => bulk.tryWriteCompactInt64ArrayMap(values)
        case _ => false
    }
}

public interface JsonCodec<T> {
    func write(value: T, writer: JsonWriter): Unit

    func read(reader: JsonReader): T
}

public interface GeneratedObjectCodecV1<T> <: JsonCodec<T> {
    func writeObjectFields(value: T, writer: JsonWriter): Unit
}

/// Zero-state type token that keeps inherited generated-codec providers
/// overloadable without erasing `T`.
public class GeneratedCodecTokenV1<T> {
    init() {}
}

public interface GeneratedCodecProviderV1<T> {
    static func generatedCodecV1(_: GeneratedCodecTokenV1<T>): JsonCodec<T>
}

/// Static dispatch seam for generated compact codecs. The explicit codec
/// argument remains part of the public overload for source compatibility, but
/// generated model types can route the hot path through their own static
/// provider without an erased codec-interface call on every value.
public interface GeneratedCompactCodecProviderV1<T> {
    static func generatedCompactRawV1(value: T, writer: JsonDirectWriter): Unit
}

/// Typed object-codec bridge used by generated polymorphic dispatch.
///
/// This is deliberately separate from GeneratedCodecProviderV1<T>: a
/// polymorphic base codec performs subtype dispatch, while each concrete
/// subtype must expose its own object fields.
public interface GeneratedObjectCodecProviderV1<T> {
    static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<T>): GeneratedObjectCodecV1<T>
}

public func generatedCodecV1Of<T>(): JsonCodec<T> where T <: GeneratedCodecProviderV1<T> {
    T.generatedCodecV1(GeneratedCodecTokenV1<T>())
}

public func generatedObjectCodecV1Of<T>(): GeneratedObjectCodecV1<T>
    where T <: GeneratedObjectCodecProviderV1<T> {
    T.generatedObjectCodecV1(GeneratedCodecTokenV1<T>())
}

// Kept as an internal optimization surface for the existing built-in codecs.
public interface GeneratedCodecV1<T> <: JsonCodec<T> {
    func readFast(reader: GeneratedSupportV1Reader): T
}

/// Opt-in generated-code seam for codecs that can consume an already-resolved
/// reader cursor. Recursive codecs pass the same cursor through the whole
/// value graph and use GeneratedCodecV1 only as a compatibility fallback.
public interface GeneratedCursorReadCodecV1<T> <: JsonCodec<T> {
    func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): T
}

/// Matching-version bridge used by generated codecs to retain the concrete
/// direct-writer type across nested semantic encode calls.
public interface GeneratedDirectWriteCodecV1<T> <: JsonCodec<T> {
    func writeDirect(value: T, writer: GeneratedSupportV1Writer): Unit
}

/// Matching-version generated-code bridge for objects whose fields can be
/// emitted directly in compact mode without bypassing encode context checks.
public interface GeneratedCompactWriteCodecV1<T> <: GeneratedDirectWriteCodecV1<T> {
    func supportsCompactRaw(): Bool
    func writeCompactRaw(value: T, writer: GeneratedSupportV1Writer): Unit
}

/// Opt-in generated-code seam for custom and recursive codecs that can emit a
/// compact value through an already-resolved writer cursor.
public interface GeneratedCursorWriteCodecV1<T> <: JsonCodec<T> {
    func supportsCompactCursorWrite(): Bool
    func writeCompactWithCursor(value: T, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit
}

/// Optional generated-code seam for nested compact objects. It refines the
/// general cursor protocol, so statically compact generated codecs need only
/// advertise one interface while remaining usable by generic containers.
public interface GeneratedCompactCursorWriteCodecV1<T> <:
    GeneratedCompactWriteCodecV1<T> & GeneratedCursorWriteCodecV1<T> {
    func writeCompactRawWithCursor(value: T, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit
}
/// Optional generated-code bulk seam. ArrayList resolves it once so an
/// element codec can reuse one writer cursor across the complete loop.
public interface GeneratedCompactArrayListElementCodecV1<T> {
    func writeCompactRawArrayList(value: ArrayList<T>, writer: GeneratedSupportV1Writer): Unit
}

public func writeJsonDirectWith<T>(
    codec: JsonCodec<T>,
    value: T,
    writer: GeneratedSupportV1Writer
): Unit {
    match (codec) {
        case direct: GeneratedDirectWriteCodecV1<T> => direct.writeDirect(value, writer)
        case _ => codec.write(value, writer)
    }
}

public func jsonTryBeginGeneratedCompactRawValue(writer: GeneratedSupportV1Writer): Bool {
    writer.tryBeginGeneratedCompactRawValue()
}

public func jsonWriteGeneratedCompactObjectBegin(writer: GeneratedSupportV1Writer): Unit {
    writer.writeRawBeginObject()
}

public func jsonWriteGeneratedCompactObjectEnd(writer: GeneratedSupportV1Writer): Unit {
    writer.writeRawEndObject()
}

public func jsonWriteGeneratedCompactArrayBegin(writer: GeneratedSupportV1Writer): Unit {
    writer.writeRawBeginArray()
}

public func jsonWriteGeneratedCompactArrayEnd(writer: GeneratedSupportV1Writer): Unit {
    writer.writeRawEndArray()
}

public func jsonWriteGeneratedCompactComma(writer: GeneratedSupportV1Writer): Unit {
    writer.writeRawByte(b',')
}

public func jsonWriteGeneratedCompactObjectEntryName(
    writer: GeneratedSupportV1Writer,
    first: Bool,
    name: String
): Bool {
    writer.writeRawObjectEntryName(first, name)
}

public func jsonWriteGeneratedCompactObjectEntryString(
    writer: GeneratedSupportV1Writer,
    first: Bool,
    name: String,
    value: String
): Bool {
    writer.writeRawObjectEntryNameString(first, name, value)
}

public func jsonWriteGeneratedCompactObjectEntryBool(
    writer: GeneratedSupportV1Writer,
    first: Bool,
    name: String,
    value: Bool
): Bool {
    writer.writeRawObjectEntryNameBool(first, name, value)
}

public func jsonWriteGeneratedCompactObjectEntryInt64(
    writer: GeneratedSupportV1Writer,
    first: Bool,
    name: String,
    value: Int64
): Bool {
    writer.writeRawObjectEntryNameInt64(first, name, value)
}

public func jsonWriteGeneratedCompactObjectEntryUInt64(
    writer: GeneratedSupportV1Writer,
    first: Bool,
    name: String,
    value: UInt64
): Bool {
    writer.writeRawObjectEntryNameUInt64(first, name, value)
}

public func jsonWriteGeneratedCompactObjectEntryFloat64(
    writer: GeneratedSupportV1Writer,
    first: Bool,
    name: String,
    value: Float64
): Bool {
    writer.writeRawObjectEntryNameFloat64(first, name, value)
}

interface JsonRawWriteCodec<T> <: JsonCodec<T> {
    func writeRaw(value: T, writer: GeneratedSupportV1Writer): Unit
}

private const GENERATED_PATH_MANUAL: UInt8 = 0u8
private const GENERATED_PATH_AUTO_CLAIMABLE: UInt8 = 1u8
private const GENERATED_PATH_AUTO_ACTIVE: UInt8 = 2u8

private struct GeneratedPathEntryV1 {
    let value: String
    let index: Int64
    let origin: UInt8

    init(value: String, index: Int64, origin: UInt8) {
        this.value = value
        this.index = index
        this.origin = origin
    }
}

private class GeneratedPathStateV1 {
    private let entries = ArrayList<GeneratedPathEntryV1>()

    func size(): Int64 { entries.size }

    func pushField(name: String): Unit {
        if (!entries.isEmpty()) {
            let position = entries.size - 1
            let last = entries[position]
            if (last.origin == GENERATED_PATH_AUTO_CLAIMABLE && last.index < 0 && last.value == name) {
                entries[position] = GeneratedPathEntryV1(last.value, last.index, GENERATED_PATH_MANUAL)
                return
            }
        }
        append(name, -1, GENERATED_PATH_MANUAL)
    }

    func pushIndex(index: Int64): Unit {
        if (!entries.isEmpty()) {
            let position = entries.size - 1
            let last = entries[position]
            if (last.origin == GENERATED_PATH_AUTO_CLAIMABLE && last.index == index) {
                entries[position] = GeneratedPathEntryV1(last.value, last.index, GENERATED_PATH_MANUAL)
                return
            }
        }
        append("", index, GENERATED_PATH_MANUAL)
    }

    func pushAutoField(name: String, baseDepth: Int64): Bool {
        if (entries.size > baseDepth) { return false }
        append(name, -1, GENERATED_PATH_AUTO_CLAIMABLE)
        true
    }

    func pushAutoIndex(index: Int64, baseDepth: Int64): Bool {
        if (entries.size > baseDepth) { return false }
        append("", index, GENERATED_PATH_AUTO_CLAIMABLE)
        true
    }

    func beginAutoValue(pushed: Bool): Unit {
        if (pushed && !entries.isEmpty()) {
            let position = entries.size - 1
            let last = entries[position]
            if (last.origin == GENERATED_PATH_AUTO_CLAIMABLE) {
                entries[position] = GeneratedPathEntryV1(last.value, last.index, GENERATED_PATH_AUTO_ACTIVE)
            }
        }
    }

    func completeAutoValue(pushed: Bool): Unit {
        if (pushed && !entries.isEmpty() && entries[entries.size - 1].origin == GENERATED_PATH_AUTO_ACTIVE) {
            pop()
        }
    }

    func pop(): Unit {
        if (!entries.isEmpty()) { entries.remove(at: entries.size - 1) }
    }

    func updateLastField(name: String): Unit {
        if (entries.isEmpty()) { return }
        let position = entries.size - 1
        let last = entries[position]
        entries[position] = GeneratedPathEntryV1(name, -1, last.origin)
    }

    func updateLastIndex(index: Int64): Unit {
        if (entries.isEmpty()) { return }
        let position = entries.size - 1
        let last = entries[position]
        entries[position] = GeneratedPathEntryV1("", index, last.origin)
    }

    func pointer(): String {
        if (entries.isEmpty()) { return "" }
        let result = StringBuilder()
        for (entry in entries) {
            result.append("/")
            if (entry.index >= 0) { result.append(entry.index.toString()) }
            else { result.append(jsonPointerEscape(entry.value)) }
        }
        result.toString()
    }

    private func append(value: String, index: Int64, origin: UInt8): Unit {
        entries.add(GeneratedPathEntryV1(value, index, origin))
    }
}

public class GeneratedWriteStateV1 {
    private let maxDepth: Int64
    private var depth: Int64 = 0
    private var path: Option<GeneratedPathStateV1> = None<GeneratedPathStateV1>

    init(config: JsonWriteOptions) { maxDepth = config.maxDepth }

    public func pushField(name: String): Unit { pathState().pushField(name) }
    public func pushIndex(index: Int64): Unit { pathState().pushIndex(index) }
    public func popPath(): Unit { if (let Some(value) <- path) { value.pop() } }
    public func updateLastField(name: String): Unit {
        if (let Some(value) <- path) { value.updateLastField(name) }
    }
    public func updateLastIndex(index: Int64): Unit {
        if (let Some(value) <- path) { value.updateLastIndex(index) }
    }

    func pathDepth(): Int64 { match (path) { case Some(value) => value.size(); case None => 0 } }
    func pushAutoField(name: String, baseDepth: Int64): Bool { pathState().pushAutoField(name, baseDepth) }
    func pushAutoIndex(index: Int64, baseDepth: Int64): Bool { pathState().pushAutoIndex(index, baseDepth) }
    func beginAutoValue(pushed: Bool): Unit {
        if (let Some(value) <- path) { value.beginAutoValue(pushed) }
    }
    func completeAutoValue(pushed: Bool): Unit {
        if (let Some(value) <- path) { value.completeAutoValue(pushed) }
    }

    public func enterValue(): Unit {
        if (depth >= maxDepth) {
            throw JsonException("Maximum JSON depth ${maxDepth} exceeded", code: "max_depth", path: currentPath())
        }
        depth++
    }
    public func leaveValue(): Unit { if (depth > 0) { depth-- } }
    public func enterObject<T>(value: T): Unit { let _ = value; enterValue() }
    public func leaveObject(): Unit { leaveValue() }
    public func currentPath(): String {
        match (path) { case Some(value) => value.pointer(); case None => "" }
    }

    private func pathState(): GeneratedPathStateV1 {
        match (path) {
            case Some(value) => value
            case None =>
                let value = GeneratedPathStateV1()
                path = Some(value)
                value
        }
    }
}

public class GeneratedReadStateV1 {
    private let maxDepth: Int64
    private var depth: Int64 = 0
    private var path: Option<GeneratedPathStateV1> = None<GeneratedPathStateV1>

    init(config: JsonReadOptions) { maxDepth = config.maxDepth }

    public func pushField(name: String): Unit { pathState().pushField(name) }
    public func pushIndex(index: Int64): Unit { pathState().pushIndex(index) }
    public func popPath(): Unit { if (let Some(value) <- path) { value.pop() } }
    func updateLastField(name: String): Unit {
        if (let Some(value) <- path) { value.updateLastField(name) }
    }
    func updateLastIndex(index: Int64): Unit {
        if (let Some(value) <- path) { value.updateLastIndex(index) }
    }

    func pathDepth(): Int64 { match (path) { case Some(value) => value.size(); case None => 0 } }
    func pushAutoField(name: String, baseDepth: Int64): Bool { pathState().pushAutoField(name, baseDepth) }
    func pushAutoIndex(index: Int64, baseDepth: Int64): Bool { pathState().pushAutoIndex(index, baseDepth) }
    func beginAutoValue(pushed: Bool): Unit {
        if (let Some(value) <- path) { value.beginAutoValue(pushed) }
    }
    func completeAutoValue(pushed: Bool): Unit {
        if (let Some(value) <- path) { value.completeAutoValue(pushed) }
    }

    public func enterValue(): Unit {
        if (depth >= maxDepth) {
            throw JsonException("Maximum JSON depth ${maxDepth} exceeded", code: "max_depth", path: currentPath())
        }
        depth++
    }
    public func leaveValue(): Unit { if (depth > 0) { depth-- } }
    public func remainingDepth(): Int64 { maxDepth - depth }
    public func currentPath(): String {
        match (path) { case Some(value) => value.pointer(); case None => "" }
    }

    private func pathState(): GeneratedPathStateV1 {
        match (path) {
            case Some(value) => value
            case None =>
                let value = GeneratedPathStateV1()
                path = Some(value)
                value
        }
    }
}

private func jsonPointerEscape(value: String): String {
    value.replace("~", "~0").replace("/", "~1")
}

class LambdaFastRawJsonCodec<T> <: GeneratedCodecV1<T> &
    GeneratedCursorReadCodecV1<T> & GeneratedCursorWriteCodecV1<T> & JsonRawWriteCodec<T> {
    private let writerFn: (T, JsonWriter) -> Unit
    private let readerFn: (JsonReader) -> T
    private let fastReaderFn: (JsonFastReader) -> T
    private let rawWriterFn: (T, JsonDirectWriter) -> Unit

    public init(
        writerFn: (T, JsonWriter) -> Unit,
        readerFn: (JsonReader) -> T,
        fastReaderFn: (JsonFastReader) -> T,
        rawWriterFn: (T, JsonDirectWriter) -> Unit
    ) {
        this.writerFn = writerFn
        this.readerFn = readerFn
        this.fastReaderFn = fastReaderFn
        this.rawWriterFn = rawWriterFn
    }

    public func write(value: T, writer: JsonWriter): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        let _ = context
        match (writer) {
            case direct: JsonDirectWriter =>
                if (direct.canWriteRawCompactValue()) {
                    rawWriterFn(value, direct)
                } else {
                    writerFn(value, writer)
                }
            case _ => writerFn(value, writer)
        }
    }

    public func writeRaw(value: T, writer: GeneratedSupportV1Writer): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        rawWriterFn(value, yJsonGeneratedWriterV1(writer))
    }

    public func supportsCompactCursorWrite(): Bool { true }

    public func writeCompactWithCursor(value: T, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = writer
        rawWriterFn(value, cursor.generatedWriterV1())
    }

    public func read(reader: JsonReader): T {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        let _ = context
        readerFn(reader)
    }

    public func readFast(reader: GeneratedSupportV1Reader): T {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        let _ = context
        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): T {
        let context = GeneratedSupportV1.readState(reader)
        let _ = context
        fastReaderFn(cursor.generatedReaderV1())
    }
}

public func readJsonFastWith<T>(codec: JsonCodec<T>, reader: GeneratedSupportV1Reader): T {
    let context = GeneratedSupportV1.readState(reader)
    match (codec) {
        case fast: GeneratedCodecV1<T> => fast.readFast(reader)
        case _ => throw JsonException("Codec does not provide a fast-reader implementation",
            code: "codec_contract", path: context.currentPath())
    }
}

func readJsonNestedFastWith<T>(codec: JsonCodec<T>, reader: GeneratedSupportV1Reader): T {
    match (codec) {
        case fast: GeneratedCodecV1<T> => fast.readFast(reader)
        case _ => codec.read(yJsonSemanticReaderV1(reader))
    }
}

func readJsonNestedFastWithCursor<T>(codec: JsonCodec<T>, reader: GeneratedSupportV1Reader,
    cursor: GeneratedSupportV1ReadCursor): T {
    match (codec) {
        case fast: GeneratedCursorReadCodecV1<T> => fast.readFastWithCursor(reader, cursor)
        case legacy: GeneratedCodecV1<T> => legacy.readFast(reader)
        case _ => codec.read(yJsonSemanticReaderV1(reader))
    }
}

private class ContractFastCodecAdapter<T> <: GeneratedCodecV1<T> {
    private let inner: JsonCodec<T>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
    }

    public func write(value: T, writer: JsonWriter): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        inner.write(value, writer)
    }

    public func read(reader: JsonReader): T {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        inner.read(reader)
    }

    public func readFast(reader: GeneratedSupportV1Reader): T {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        readJsonNestedFastWith(inner, reader)
    }
}

private func resolvedGeneratedCodecV1<T>(codec: JsonCodec<T>): GeneratedCodecV1<T> {
    match (codec) {
        case fast: GeneratedCodecV1<T> => fast
        case _ => ContractFastCodecAdapter<T>(codec)
    }
}

private class OptionJsonCodec<T> <: GeneratedCodecV1<Option<T>> &
    GeneratedCursorReadCodecV1<Option<T>> & GeneratedCompactWriteCodecV1<Option<T>> &
    GeneratedCursorWriteCodecV1<Option<T>> {
    private let inner: JsonCodec<T>
    private let directInner: Option<GeneratedDirectWriteCodecV1<T>>
    private let compactRawInner: Option<GeneratedCompactWriteCodecV1<T>>
    private let cursorReadInner: Option<GeneratedCursorReadCodecV1<T>>
    private let cursorWriteInner: Option<GeneratedCursorWriteCodecV1<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.directInner = match (inner) {
            case direct: GeneratedDirectWriteCodecV1<T> => Some(direct)
            case _ => None<GeneratedDirectWriteCodecV1<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: GeneratedCompactWriteCodecV1<T> => Some(raw)
            case _ => None<GeneratedCompactWriteCodecV1<T>>
        }
        this.cursorReadInner = match (inner) {
            case cursor: GeneratedCursorReadCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorReadCodecV1<T>>
        }
        this.cursorWriteInner = match (inner) {
            case cursor: GeneratedCursorWriteCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorWriteCodecV1<T>>
        }
    }

    public func write(value: Option<T>, writer: JsonWriter): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct)
                return
            case _ => ()
        }
        match (value) {
            case Some(item) => inner.write(item, writer)
            case None => writer.writeNull()
        }
    }

    public func writeDirect(value: Option<T>, writer: GeneratedSupportV1Writer): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        if (supportsCompactRaw() && writer.tryBeginGeneratedCompactRawValue()) {
            writeCompactRaw(value, writer)
            return
        }
        match (value) {
            case Some(item) =>
                match (directInner) {
                    case Some(direct) => direct.writeDirect(item, writer)
                    case None => inner.write(item, writer)
                }
            case None => writer.writeNull()
        }
    }

    public func supportsCompactRaw(): Bool {
        if (let Some(cursor) <- cursorWriteInner) {
            return cursor.supportsCompactCursorWrite()
        }
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: Option<T>, writer: GeneratedSupportV1Writer): Unit {

        writeCompactWithCursor(value, writer, GeneratedSupportV1.writeCursor(writer))
    }

    public func supportsCompactCursorWrite(): Bool { supportsCompactRaw() }

    public func writeCompactWithCursor(value: Option<T>, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        match (value) {
            case Some(item) =>
                match (cursorWriteInner) {
                    case Some(raw) => raw.writeCompactWithCursor(item, writer, cursor)
                    case None => match (compactRawInner) {
                        case Some(raw) => raw.writeCompactRaw(item, writer)
                        case None => throw JsonException("Compact raw codec is unavailable")
                    }
                }
            case None => cursor.writeRawNull()
        }
    }

    public func read(reader: JsonReader): Option<T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        if (reader.tryReadNull()) {
            return None<T>
        }
        Some(inner.read(reader))
    }

    public func readFast(reader: GeneratedSupportV1Reader): Option<T> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): Option<T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        if (cursor.tryReadRawNull()) {
            return None<T>
        }
        match (cursorReadInner) {
            case Some(fast) => Some(fast.readFastWithCursor(reader, cursor))
            case None => Some(readJsonNestedFastWith(inner, reader))
        }
    }
}

private class StringOptionJsonCodec <: GeneratedCodecV1<Option<String>> &
    GeneratedCursorReadCodecV1<Option<String>> & GeneratedCursorWriteCodecV1<Option<String>> {
    public func write(value: Option<String>, writer: JsonWriter): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        let _ = context
        let _ = context
        match (value) {
            case Some(item) => writer.writeString(item)
            case None => writer.writeNull()
        }
    }

    public func read(reader: JsonReader): Option<String> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        let _ = context
        if (reader.tryReadNull()) {
            return None<String>
        }
        Some(reader.readString())
    }

    public func readFast(reader: GeneratedSupportV1Reader): Option<String> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): Option<String> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        let _ = context
        if (cursor.tryReadRawNull()) {
            return None<String>
        }
        Some(cursor.readRawString())
    }

    public func supportsCompactCursorWrite(): Bool { true }

    public func writeCompactWithCursor(value: Option<String>, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = writer
        match (value) {
            case Some(item) => cursor.writeRawString(item)
            case None => cursor.writeRawNull()
        }
    }
}

private class Int64ArrayJsonCodec <: GeneratedCodecV1<Array<Int64>> &
    GeneratedCursorReadCodecV1<Array<Int64>> & GeneratedCompactWriteCodecV1<Array<Int64>> &
    GeneratedCursorWriteCodecV1<Array<Int64>> {
    public func write(value: Array<Int64>, writer: JsonWriter): Unit {
        match (writer) {
            case direct: GeneratedSupportV1Writer => writeDirect(value, direct)
            case _ => writeStructural(value, writer)
        }
    }

    private func writeStructural(value: Array<Int64>, writer: JsonWriter): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            writer.startArray()
            for (item in value) { writer.writeInt64(item) }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func writeDirect(value: Array<Int64>, writer: GeneratedSupportV1Writer): Unit {
        if (jsonTryWriteCompactInt64Array(writer, value)) { return }
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            writer.startArray()
            for (item in value) { writer.writeInt64(item) }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactRaw(): Bool { true }

    public func writeCompactRaw(value: Array<Int64>, writer: GeneratedSupportV1Writer): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            if (!jsonTryWriteCompactInt64Array(writer, value)) {
                throw JsonException("Compact raw codec is unavailable")
            }
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactCursorWrite(): Bool { true }

    public func writeCompactWithCursor(value: Array<Int64>, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = cursor
        writeCompactRaw(value, writer)
    }

    public func read(reader: JsonReader): Array<Int64> {
        ArrayJsonCodec<Int64>(Int64Json).read(reader)
    }

    public func readFast(reader: GeneratedSupportV1Reader): Array<Int64> {
        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): Array<Int64> {
        let context = GeneratedSupportV1.readState(reader)
        context.enterValue()
        try {
            if (let Some(result) <- yJsonTryReadNativeInt64ArrayListV1(reader)) {
                return result.toArray()
            }
            cursor.startRawArray()
            if (!cursor.hasRawArrayItem(true)) {
                cursor.endRawArray()
                return Array<Int64>()
            }
            let result = ArrayList<Int64>(cursor.suggestRawArrayCapacity())
            var first = true
            while (cursor.hasRawArrayItem(first)) {
                cursor.beforeRawArrayItem(first)
                result.add(cursor.readRawInt64())
                first = false
            }
            cursor.endRawArray()
            return result.toArray()
        } finally {
            context.leaveValue()
        }
    }
}

private class ArrayJsonCodec<T> <: GeneratedCodecV1<Array<T>> &
    GeneratedCursorReadCodecV1<Array<T>> & GeneratedCompactWriteCodecV1<Array<T>> &
    GeneratedCursorWriteCodecV1<Array<T>> {
    private let inner: JsonCodec<T>
    private let fastInner: GeneratedCodecV1<T>
    private let directInner: Option<GeneratedDirectWriteCodecV1<T>>
    private let compactRawInner: Option<GeneratedCompactWriteCodecV1<T>>
    private let cursorReadInner: Option<GeneratedCursorReadCodecV1<T>>
    private let cursorWriteInner: Option<GeneratedCursorWriteCodecV1<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedGeneratedCodecV1(inner)
        this.directInner = match (inner) {
            case direct: GeneratedDirectWriteCodecV1<T> => Some(direct)
            case _ => None<GeneratedDirectWriteCodecV1<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: GeneratedCompactWriteCodecV1<T> => Some(raw)
            case _ => None<GeneratedCompactWriteCodecV1<T>>
        }
        this.cursorReadInner = match (inner) {
            case cursor: GeneratedCursorReadCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorReadCodecV1<T>>
        }
        this.cursorWriteInner = match (inner) {
            case cursor: GeneratedCursorWriteCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorWriteCodecV1<T>>
        }
    }

    public func write(value: Array<T>, writer: JsonWriter): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct)
                return
            case _ => ()
        }
        context.enterValue()
        try {
            writer.startArray()
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (index in 0..value.size) {
                        if (index > 0) {
                            context.updateLastIndex(index)
                        }
                        inner.write(value[index], writer)
                    }
                } finally {
                    context.popPath()
                }
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func writeDirect(value: Array<T>, writer: GeneratedSupportV1Writer): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        if (supportsCompactRaw() && writer.tryBeginGeneratedCompactRawValue()) {
            writeCompactRaw(value, writer)
            return
        }
        context.enterValue()
        try {
            writer.startArray()
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (index in 0..value.size) {
                        if (index > 0) {
                            context.updateLastIndex(index)
                        }
                        match (directInner) {
                            case Some(direct) => direct.writeDirect(value[index], writer)
                            case None => inner.write(value[index], writer)
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactRaw(): Bool {
        if (let Some(cursor) <- cursorWriteInner) {
            return cursor.supportsCompactCursorWrite()
        }
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: Array<T>, writer: GeneratedSupportV1Writer): Unit {

        writeCompactWithCursor(value, writer, GeneratedSupportV1.writeCursor(writer))
    }

    public func supportsCompactCursorWrite(): Bool { supportsCompactRaw() }

    public func writeCompactWithCursor(value: Array<T>, writer: GeneratedSupportV1Writer,
        rawWriter: GeneratedSupportV1WriteCursor): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        context.enterValue()
        try {
            rawWriter.reserveRawCollectionCapacity(value.size)
            rawWriter.writeRawBeginArray()
            if (!value.isEmpty()) {
                // writeCompactRaw is reachable only after supportsCompactRaw
                // has confirmed this invariant.
                context.pushIndex(0)
                try {
                    for (index in 0..value.size) {
                        if (index > 0) {
                            rawWriter.writeRawByte(b',')
                            context.updateLastIndex(index)
                        }
                        match (cursorWriteInner) {
                            case Some(raw) => raw.writeCompactWithCursor(value[index], writer, rawWriter)
                            case None => compactRawInner.getOrThrow().writeCompactRaw(value[index], writer)
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            rawWriter.writeRawEndArray()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonReader): Array<T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            let result = ArrayList<T>()
            reader.startArray()
            var index: Int64 = 0
            while (reader.hasArrayItem()) {
                context.pushIndex(index)
                try {
                    result.add(inner.read(reader))
                } finally {
                    context.popPath()
                }
                index++
            }
            reader.endArray()
            return result.toArray()
        } finally {
            context.leaveValue()
        }
    }

    public func readFast(reader: GeneratedSupportV1Reader): Array<T> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): Array<T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            cursor.startRawArray()
            if (!cursor.hasRawArrayItem(true)) {
                cursor.endRawArray()
                return Array<T>()
            }
            let capacity = cursor.suggestRawCollectionCapacity()
            let result = if (capacity > 4) {
                ArrayList<T>(capacity)
            } else {
                ArrayList<T>()
            }
            var first = true
            var index: Int64 = 0
            if (cursor.hasRawArrayItem(first)) {
                context.pushIndex(index)
                try {
                    while (true) {
                        cursor.beforeRawArrayItem(first)
                        if (!first) {
                            context.updateLastIndex(index)
                        }
                        match (cursorReadInner) {
                            case Some(fast) => result.add(fast.readFastWithCursor(reader, cursor))
                            case None => result.add(fastInner.readFast(reader))
                        }
                        first = false
                        index++
                        if (!cursor.hasRawArrayItem(first)) {
                            break
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            cursor.endRawArray()
            return result.toArray()
        } finally {
            context.leaveValue()
        }
    }
}

private class ArrayListJsonCodec<T> <: GeneratedCodecV1<ArrayList<T>> &
    GeneratedCursorReadCodecV1<ArrayList<T>> & GeneratedCompactWriteCodecV1<ArrayList<T>> &
    GeneratedCursorWriteCodecV1<ArrayList<T>> {
    private let inner: JsonCodec<T>
    private let fastInner: GeneratedCodecV1<T>
    private let directInner: Option<GeneratedDirectWriteCodecV1<T>>
    private let compactRawInner: Option<GeneratedCompactWriteCodecV1<T>>
    private let compactRawArrayListInner: Option<GeneratedCompactArrayListElementCodecV1<T>>
    private let cursorReadInner: Option<GeneratedCursorReadCodecV1<T>>
    private let cursorWriteInner: Option<GeneratedCursorWriteCodecV1<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedGeneratedCodecV1(inner)
        this.directInner = match (inner) {
            case direct: GeneratedDirectWriteCodecV1<T> => Some(direct)
            case _ => None<GeneratedDirectWriteCodecV1<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: GeneratedCompactWriteCodecV1<T> => Some(raw)
            case _ => None<GeneratedCompactWriteCodecV1<T>>
        }
        this.compactRawArrayListInner = match (inner) {
            case bulk: GeneratedCompactArrayListElementCodecV1<T> => Some(bulk)
            case _ => None<GeneratedCompactArrayListElementCodecV1<T>>
        }
        this.cursorReadInner = match (inner) {
            case cursor: GeneratedCursorReadCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorReadCodecV1<T>>
        }
        this.cursorWriteInner = match (inner) {
            case cursor: GeneratedCursorWriteCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorWriteCodecV1<T>>
        }
    }

    public func write(value: ArrayList<T>, writer: JsonWriter): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct)
                return
            case _ => ()
        }
        context.enterValue()
        try {
            writer.startArray()
            var index: Int64 = 0
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (position in 0..value.size) {
                        if (index > 0) {
                            context.updateLastIndex(index)
                        }
                        inner.write(value[position], writer)
                        index++
                    }
                } finally {
                    context.popPath()
                }
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func writeDirect(value: ArrayList<T>, writer: GeneratedSupportV1Writer): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        if (supportsCompactRaw() && writer.tryBeginGeneratedCompactRawValue()) {
            writeCompactRaw(value, writer)
            return
        }
        context.enterValue()
        try {
            writer.startArray()
            var index: Int64 = 0
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (position in 0..value.size) {
                        if (index > 0) {
                            context.updateLastIndex(index)
                        }
                        match (directInner) {
                            case Some(direct) => direct.writeDirect(value[position], writer)
                            case None => inner.write(value[position], writer)
                        }
                        index++
                    }
                } finally {
                    context.popPath()
                }
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactRaw(): Bool {
        if (let Some(cursor) <- cursorWriteInner) {
            return cursor.supportsCompactCursorWrite()
        }
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: ArrayList<T>, writer: GeneratedSupportV1Writer): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        if (let Some(bulk) <- compactRawArrayListInner) {
            bulk.writeCompactRawArrayList(value, writer)
            return
        }
        writeCompactWithCursor(value, writer, GeneratedSupportV1.writeCursor(writer))
    }

    public func supportsCompactCursorWrite(): Bool { supportsCompactRaw() }

    public func writeCompactWithCursor(value: ArrayList<T>, writer: GeneratedSupportV1Writer,
        rawWriter: GeneratedSupportV1WriteCursor): Unit {

        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            rawWriter.reserveRawCollectionCapacity(value.size)
            rawWriter.writeRawBeginArray()
            var index: Int64 = 0
            if (!value.isEmpty()) {
                // writeCompactRaw is reachable only after supportsCompactRaw
                // has confirmed this invariant.
                context.pushIndex(0)
                try {
                    for (position in 0..value.size) {
                        if (index > 0) {
                            rawWriter.writeRawByte(b',')
                            context.updateLastIndex(index)
                        }
                        match (cursorWriteInner) {
                            case Some(raw) => raw.writeCompactWithCursor(value[position], writer, rawWriter)
                            case None => compactRawInner.getOrThrow().writeCompactRaw(value[position], writer)
                        }
                        index++
                    }
                } finally {
                    context.popPath()
                }
            }
            rawWriter.writeRawEndArray()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonReader): ArrayList<T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            let result = ArrayList<T>()
            reader.startArray()
            var index: Int64 = 0
            while (reader.hasArrayItem()) {
                context.pushIndex(index)
                try {
                    result.add(inner.read(reader))
                } finally {
                    context.popPath()
                }
                index++
            }
            reader.endArray()
            return result
        } finally {
            context.leaveValue()
        }
    }

    public func readFast(reader: GeneratedSupportV1Reader): ArrayList<T> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): ArrayList<T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            cursor.startRawArray()
            if (!cursor.hasRawArrayItem(true)) {
                cursor.endRawArray()
                return ArrayList<T>()
            }
            let capacity = cursor.suggestRawCollectionCapacity()
            let result = if (capacity > 4) {
                ArrayList<T>(capacity)
            } else {
                ArrayList<T>()
            }
            var first = true
            var index: Int64 = 0
            if (cursor.hasRawArrayItem(first)) {
                context.pushIndex(index)
                try {
                    while (true) {
                        cursor.beforeRawArrayItem(first)
                        if (!first) {
                            context.updateLastIndex(index)
                        }
                        match (cursorReadInner) {
                            case Some(fast) => result.add(fast.readFastWithCursor(reader, cursor))
                            case None => result.add(fastInner.readFast(reader))
                        }
                        first = false
                        index++
                        if (!cursor.hasRawArrayItem(first)) {
                            break
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            cursor.endRawArray()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

private class Int64ArrayListJsonCodec <: GeneratedCodecV1<ArrayList<Int64>> &
    GeneratedCursorReadCodecV1<ArrayList<Int64>> &
    GeneratedCursorWriteCodecV1<ArrayList<Int64>> {
    public func write(value: ArrayList<Int64>, writer: JsonWriter): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        let _ = context
        context.enterValue()
        try {
            if (jsonTryWriteCompactInt64ArrayList(writer, value)) {
                return
            }
            writer.startArray()
            for (index in 0..value.size) {
                writer.writeInt64(value[index])
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }
    public func read(reader: JsonReader): ArrayList<Int64> {
        let context = GeneratedSupportV1.readState(reader)
        let _ = context
        ArrayListJsonCodec<Int64>(Int64Json).read(reader)
    }
    public func readFast(reader: GeneratedSupportV1Reader): ArrayList<Int64> {
        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }
    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): ArrayList<Int64> {
        let context = GeneratedSupportV1.readState(reader)
        let _ = context
        context.enterValue()
        try {
            if (let Some(result) <- yJsonTryReadNativeInt64ArrayListV1(reader)) {
                return result
            }
            cursor.startRawArray()
            if (!cursor.hasRawArrayItem(true)) {
                cursor.endRawArray()
                return ArrayList<Int64>()
            }
            let result = ArrayList<Int64>(cursor.suggestRawArrayCapacity())
            var first = true
            while (cursor.hasRawArrayItem(first)) {
                cursor.beforeRawArrayItem(first)
                result.add(cursor.readRawInt64())
                first = false
            }
            cursor.endRawArray()
            return result
        } finally {
            context.leaveValue()
        }
    }
    public func supportsCompactCursorWrite(): Bool { true }
    public func writeCompactWithCursor(value: ArrayList<Int64>, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = cursor
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            if (!jsonTryWriteCompactInt64ArrayList(writer, value)) {
                throw JsonException("Compact raw codec is unavailable")
            }
        } finally {
            context.leaveValue()
        }
    }
}

private class StringArrayListJsonCodec <: GeneratedCodecV1<ArrayList<String>> &
    GeneratedCursorReadCodecV1<ArrayList<String>> &
    GeneratedCursorWriteCodecV1<ArrayList<String>> {
    public func write(value: ArrayList<String>, writer: JsonWriter): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        let _ = context
        context.enterValue()
        try {
            if (jsonTryWriteCompactStringArrayList(writer, value)) {
                return
            }
            writer.startArray()
            for (index in 0..value.size) {
                writer.writeString(value[index])
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonReader): ArrayList<String> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            let result = ArrayList<String>()
            reader.startArray()
            while (reader.hasArrayItem()) {
                result.add(reader.readString())
            }
            reader.endArray()
            return result
        } finally {
            context.leaveValue()
        }
    }

    public func readFast(reader: GeneratedSupportV1Reader): ArrayList<String> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): ArrayList<String> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            cursor.startRawArray()
            if (!cursor.hasRawArrayItem(true)) {
                cursor.endRawArray()
                return ArrayList<String>()
            }
            let result = ArrayList<String>(cursor.suggestRawArrayCapacity())
            var first = true
            while (cursor.hasRawArrayItem(first)) {
                cursor.beforeRawArrayItem(first)
                result.add(cursor.readRawString())
                first = false
            }
            cursor.endRawArray()
            return result
        } finally {
            context.leaveValue()
        }
    }
    public func supportsCompactCursorWrite(): Bool { true }
    public func writeCompactWithCursor(value: ArrayList<String>, writer: GeneratedSupportV1Writer,
        cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = cursor
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            if (!jsonTryWriteCompactStringArrayList(writer, value)) {
                throw JsonException("Compact raw codec is unavailable")
            }
        } finally {
            context.leaveValue()
        }
    }
}

// Concrete generated-code bridges. They are public only because macro output
// may live in a consumer package; ordinary users should use YJson codecs.
public func __yJsonReadStringArrayList(reader: JsonReader): ArrayList<String> {
    let context = GeneratedSupportV1.readState(reader)
    let _ = context
    context.enterValue()
    try {
        let result = ArrayList<String>();
        reader.startArray()
        while (reader.hasArrayItem()) {
            result.add(reader.readString())
        }
        reader.endArray();
        result
    } finally {
        context.leaveValue()
    }
}

public func __yJsonReadFastStringArrayList(reader: GeneratedSupportV1Reader): ArrayList<String> {

    let context = GeneratedSupportV1.readState(reader)

    let _ = context
    context.enterValue()
    try {
        reader.startRawArray()
        if (!reader.hasRawArrayItem(true)) {
            reader.endRawArray();
            return ArrayList<String>()
        }
        let result = ArrayList<String>(reader.suggestRawArrayCapacity());
        var first = true
        while (reader.hasRawArrayItem(first)) {
            reader.beforeRawArrayItem(first);
            result.add(reader.readRawString());
            first = false
        }
        reader.endRawArray();
        result
    } finally {
        context.leaveValue()
    }
}

public func __yJsonWriteStringArrayList(
    value: ArrayList<String>,
    writer: JsonWriter
): Unit {

    let context = GeneratedSupportV1.writeState(writer)

    let _ = context
    JsonCodecs.arrayList(JsonCodecs.string).write(value, writer)
}

public func __yJsonWriteStringOption(value: Option<String>, writer: JsonWriter): Unit {

    let context = GeneratedSupportV1.writeState(writer)

    let _ = context
    let _ = context
    match (value) {
        case Some(item) => writer.writeString(item);
        case None => writer.writeNull()
    }
}

public func __yJsonReadStringOption(reader: JsonReader): Option<String> {

    let context = GeneratedSupportV1.readState(reader)

    let _ = context
    let _ = context
    if (reader.tryReadNull()) {
        None<String>
    } else {
        Some(reader.readString())
    }
}

public func __yJsonReadFastStringOption(reader: GeneratedSupportV1Reader): Option<String> {

    let context = GeneratedSupportV1.readState(reader)

    let _ = context
    let _ = context
    if (reader.tryReadRawNull()) {
        None<String>
    } else {
        Some(reader.readRawString())
    }
}

private class HashMapJsonCodec<T> <: GeneratedCodecV1<HashMap<String, T>> &
    GeneratedCursorReadCodecV1<HashMap<String, T>> &
    GeneratedCompactWriteCodecV1<HashMap<String, T>> &
    GeneratedCursorWriteCodecV1<HashMap<String, T>> {
    private let inner: JsonCodec<T>
    private let fastInner: GeneratedCodecV1<T>
    private let rawInner: Option<JsonRawWriteCodec<T>>
    private let directInner: Option<GeneratedDirectWriteCodecV1<T>>
    private let compactRawInner: Option<GeneratedCompactWriteCodecV1<T>>
    private let cursorReadInner: Option<GeneratedCursorReadCodecV1<T>>
    private let cursorWriteInner: Option<GeneratedCursorWriteCodecV1<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedGeneratedCodecV1(inner)
        this.rawInner = match (inner) {
            case raw: JsonRawWriteCodec<T> => Some(raw)
            case _ => None<JsonRawWriteCodec<T>>
        }
        this.directInner = match (inner) {
            case direct: GeneratedDirectWriteCodecV1<T> => Some(direct)
            case _ => None<GeneratedDirectWriteCodecV1<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: GeneratedCompactWriteCodecV1<T> => Some(raw)
            case _ => None<GeneratedCompactWriteCodecV1<T>>
        }
        this.cursorReadInner = match (inner) {
            case cursor: GeneratedCursorReadCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorReadCodecV1<T>>
        }
        this.cursorWriteInner = match (inner) {
            case cursor: GeneratedCursorWriteCodecV1<T> => Some(cursor)
            case _ => None<GeneratedCursorWriteCodecV1<T>>
        }
    }

    public func write(value: HashMap<String, T>, writer: JsonWriter): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct)
                return
            case _ => ()
        }
        context.enterValue()
        try {
            if (let Some(raw) <- rawInner) {
                match (writer) {
                    case direct: JsonDirectWriter =>
                        if (direct.tryWriteCompactRawMap(value, raw)) { return }
                    case _ => ()
                }
            }
            writer.startObject()
            if (!value.isEmpty()) {
                var first = true
                try {
                    for ((name, item) in value) {
                        writer.writeName(name)
                        if (first) {
                            context.pushField(name)
                            first = false
                        } else {
                            context.updateLastField(name)
                        }
                        inner.write(item, writer)
                    }
                } finally {
                    if (!first) {
                        context.popPath()
                    }
                }
            }
            writer.endObject()
        } finally {
            context.leaveValue()
        }
    }

    public func writeDirect(value: HashMap<String, T>, writer: GeneratedSupportV1Writer): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        if (supportsCompactRaw() && writer.tryBeginGeneratedCompactRawValue()) {
            writeCompactRaw(value, writer)
            return
        }
        context.enterValue()
        try {
            if (let Some(raw) <- rawInner) {
                if (yJsonGeneratedWriterV1(writer).tryWriteCompactRawMap(value, raw)) {
                    return
                }
            }
            writer.startObject()
            if (!value.isEmpty()) {
                var first = true
                try {
                    for ((name, item) in value) {
                        writer.writeName(name)
                        if (first) {
                            context.pushField(name)
                            first = false
                        } else {
                            context.updateLastField(name)
                        }
                        match (directInner) {
                            case Some(direct) => direct.writeDirect(item, writer)
                            case None => inner.write(item, writer)
                        }
                    }
                } finally {
                    if (!first) {
                        context.popPath()
                    }
                }
            }
            writer.endObject()
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactRaw(): Bool {
        if (let Some(cursor) <- cursorWriteInner) {
            return cursor.supportsCompactCursorWrite()
        }
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: HashMap<String, T>, writer: GeneratedSupportV1Writer): Unit {

        writeCompactWithCursor(value, writer, GeneratedSupportV1.writeCursor(writer))
    }

    public func supportsCompactCursorWrite(): Bool { supportsCompactRaw() }

    public func writeCompactWithCursor(value: HashMap<String, T>, writer: GeneratedSupportV1Writer,
        rawWriter: GeneratedSupportV1WriteCursor): Unit {

        let context = GeneratedSupportV1.writeState(writer)

        let _ = context
        context.enterValue()
        try {
            rawWriter.writeRawBeginObject()
            if (!value.isEmpty()) {
                // writeCompactRaw is reachable only after supportsCompactRaw
                // has confirmed this invariant.
                var first = true
                try {
                    for ((name, item) in value) {
                        if (first) {
                            context.pushField(name)
                        } else {
                            context.updateLastField(name)
                        }
                        first = rawWriter.writeRawObjectEntryName(first, name)
                        match (cursorWriteInner) {
                            case Some(raw) => raw.writeCompactWithCursor(item, writer, rawWriter)
                            case None => compactRawInner.getOrThrow().writeCompactRaw(item, writer)
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            rawWriter.writeRawEndObject()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonReader): HashMap<String, T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            let result = HashMap<String, T>()
            reader.startObject()
            while (reader.hasObjectField()) {
                let name = reader.readName()
                context.pushField(name)
                try {
                    result[name] = inner.read(reader)
                } finally {
                    context.popPath()
                }
            }
            reader.endObject()
            return result
        } finally {
            context.leaveValue()
        }
    }

    public func readFast(reader: GeneratedSupportV1Reader): HashMap<String, T> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): HashMap<String, T> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            cursor.startRawObject()
            if (!cursor.hasRawObjectField(true)) {
                cursor.endRawObject()
                return HashMap<String, T>()
            }
            let result = HashMap<String, T>(cursor.suggestRawObjectCapacity())
            var first = true
            let firstName = cursor.readRawName(true)
            context.pushField(firstName)
            try {
                match (cursorReadInner) {
                    case Some(fast) => result[firstName] = fast.readFastWithCursor(reader, cursor)
                    case None => result[firstName] = fastInner.readFast(reader)
                }
                first = false
                while (cursor.hasRawObjectField(first)) {
                    let name = cursor.readRawName(first)
                    context.updateLastField(name)
                    match (cursorReadInner) {
                        case Some(fast) => result[name] = fast.readFastWithCursor(reader, cursor)
                        case None => result[name] = fastInner.readFast(reader)
                    }
                }
            } finally {
                context.popPath()
            }
            cursor.endRawObject()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

private class Int64ArrayHashMapJsonCodec <: GeneratedCodecV1<HashMap<String, Array<Int64>>> &
    GeneratedCursorReadCodecV1<HashMap<String, Array<Int64>>> &
    GeneratedCompactWriteCodecV1<HashMap<String, Array<Int64>>> &
    GeneratedCursorWriteCodecV1<HashMap<String, Array<Int64>>> {
    private let fallback = HashMapJsonCodec<Array<Int64>>(Int64ArrayJsonCodec())

    public func write(value: HashMap<String, Array<Int64>>, writer: JsonWriter): Unit {
        match (writer) {
            case direct: GeneratedSupportV1Writer => writeDirect(value, direct)
            case _ => fallback.write(value, writer)
        }
    }

    public func writeDirect(
        value: HashMap<String, Array<Int64>>,
        writer: GeneratedSupportV1Writer
    ): Unit {
        if (jsonTryWriteCompactInt64ArrayMap(writer, value)) { return }
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            writer.startObject()
            for ((name, items) in value) {
                writer.writeName(name)
                writer.startArray()
                for (item in items) { writer.writeInt64(item) }
                writer.endArray()
            }
            writer.endObject()
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactRaw(): Bool { true }

    public func writeCompactRaw(
        value: HashMap<String, Array<Int64>>,
        writer: GeneratedSupportV1Writer
    ): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            if (!jsonTryWriteCompactInt64ArrayMap(writer, value)) {
                throw JsonException("Compact raw codec is unavailable")
            }
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonReader): HashMap<String, Array<Int64>> {
        fallback.read(reader)
    }

    public func readFast(reader: GeneratedSupportV1Reader): HashMap<String, Array<Int64>> {
        fallback.readFast(reader)
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): HashMap<String, Array<Int64>> {
        fallback.readFastWithCursor(reader, cursor)
    }

    public func supportsCompactCursorWrite(): Bool { true }

    public func writeCompactWithCursor(value: HashMap<String, Array<Int64>>,
        writer: GeneratedSupportV1Writer, cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = cursor
        writeCompactRaw(value, writer)
    }
}

private class Int64HashMapJsonCodec <: GeneratedCodecV1<HashMap<String, Int64>> &
    GeneratedCursorReadCodecV1<HashMap<String, Int64>> &
    GeneratedCursorWriteCodecV1<HashMap<String, Int64>> {
    public func write(value: HashMap<String, Int64>, writer: JsonWriter): Unit {
        let context = GeneratedSupportV1.writeState(writer)
        let _ = context
        context.enterValue()
        try {
            if (jsonTryWriteCompactInt64Map(writer, value)) {
                return
            }
            writer.startObject()
            for ((name, item) in value) {
                writer.writeName(name)
                writer.writeInt64(item)
            }
            writer.endObject()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonReader): HashMap<String, Int64> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            let result = HashMap<String, Int64>()
            reader.startObject()
            while (reader.hasObjectField()) {
                result[reader.readName()] = reader.readInt64()
            }
            reader.endObject()
            return result
        } finally {
            context.leaveValue()
        }
    }

    public func readFast(reader: GeneratedSupportV1Reader): HashMap<String, Int64> {

        readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
    }

    public func readFastWithCursor(reader: GeneratedSupportV1Reader,
        cursor: GeneratedSupportV1ReadCursor): HashMap<String, Int64> {

        let context = GeneratedSupportV1.readState(reader)

        let _ = context
        context.enterValue()
        try {
            cursor.startRawObject()
            if (!cursor.hasRawObjectField(true)) {
                cursor.endRawObject()
                return HashMap<String, Int64>()
            }
            let result = HashMap<String, Int64>(cursor.suggestRawObjectCapacity())
            var first = true
            while (cursor.hasRawObjectField(first)) {
                result[cursor.readRawName(first)] = cursor.readRawInt64()
                first = false
            }
            cursor.endRawObject()
            return result
        } finally {
            context.leaveValue()
        }
    }

    public func supportsCompactCursorWrite(): Bool { true }

    public func writeCompactWithCursor(value: HashMap<String, Int64>,
        writer: GeneratedSupportV1Writer, cursor: GeneratedSupportV1WriteCursor): Unit {
        let _ = cursor
        let context = GeneratedSupportV1.writeState(writer)
        context.enterValue()
        try {
            if (!jsonTryWriteCompactInt64Map(writer, value)) {
                throw JsonException("Compact raw codec is unavailable")
            }
        } finally {
            context.leaveValue()
        }
    }
}

public func __yJsonReadInt64HashMap(reader: JsonReader): HashMap<String, Int64> {

    let context = GeneratedSupportV1.readState(reader)

    let _ = context
    context.enterValue()
    try {
        let result = HashMap<String, Int64>();
        reader.startObject()
        while (reader.hasObjectField()) {
            result[reader.readName()] = reader.readInt64()
        }
        reader.endObject();
        result
    } finally {
        context.leaveValue()
    }
}

public func __yJsonReadFastInt64HashMap(reader: GeneratedSupportV1Reader): HashMap<String, Int64> {

    let context = GeneratedSupportV1.readState(reader)

    let _ = context
    context.enterValue()
    try {
        reader.startRawObject()
        if (!reader.hasRawObjectField(true)) {
            reader.endRawObject();
            return HashMap<String, Int64>()
        }
        let result = HashMap<String, Int64>(reader.suggestRawObjectCapacity());
        var first = true
        while (reader.hasRawObjectField(first)) {
            result[reader.readRawName(first)] = reader.readRawInt64()
            first = false
        }
        reader.endRawObject();
        result
    } finally {
        context.leaveValue()
    }
}

public func __yJsonWriteInt64HashMap(
    value: HashMap<String, Int64>,
    writer: JsonWriter
): Unit {

    let context = GeneratedSupportV1.writeState(writer)

    let _ = context
    JsonCodecs.stringMap(JsonCodecs.int64).write(value, writer)
}

private func writeJsonValueView(writer: JsonWriter, value: JsonValueView): Unit {
    // JsonNode is itself a view, but mutable DOM values require the guarded
    // serializer so direct and indirect cycles fail deterministically.
    match (value) {
        case node: JsonNode =>
            writeJsonNodeToCodecWriter(writer, node)
            return
        case _ => ()
    }
    match (value.kind()) {
        case JsonKind.Null => writer.writeNull()
        case JsonKind.Boolean => writer.writeBool(value.asBool())
        case JsonKind.Number => writer.writeNumberLiteral(value.asNumberText())
        case JsonKind.String => writer.writeString(value.asString())
        case JsonKind.Array =>
            writer.startArray()
            for (index in 0..value.size()) {
                let item = value.element(index).getOrThrow({ =>
                    JsonException("Array view changed during traversal", code: "view_contract")
                })
                writeJsonValueView(writer, item)
            }
            writer.endArray()
        case JsonKind.Object =>
            writer.startObject()
            for (index in 0..value.size()) {
                writer.writeName(value.memberName(index))
                writeJsonValueView(writer, value.memberValue(index))
            }
            writer.endObject()
    }
}

/// Stateless entry points for typed JSON encoding, decoding, and documents.
public class YJson {
    public static func parseDocument(text: String,
        config!: JsonReadOptions = JsonReadOptions.defaults): JsonDocument {
        freezeYJsonRuntime()
        parseManagedJsonDocument(text, config)
    }

    public static func parseDocument(bytes: Array<Byte>,
        config!: JsonReadOptions = JsonReadOptions.defaults): JsonDocument {
        freezeYJsonRuntime()
        parseManagedJsonDocument(bytes, config)
    }

    public static func toJson(value: JsonValueView,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        freezeYJsonRuntime()
        let writer = JsonDirectWriter(options)
        writeJsonValueView(writer, value)
        writer.finishString()
    }

    public static func toJsonBytes(value: JsonValueView,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> {
        freezeYJsonRuntime()
        let writer = JsonDirectWriter.bytes(config: options)
        writeJsonValueView(writer, value)
        writer.finishBytes()
    }

    public static func writeJson(value: JsonValueView, output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        freezeYJsonRuntime()
        let writer = JsonDirectWriter(output, config: options)
        // Resolve the root kind before the first output token so a closed
        // resource-backed view fails without producing a new prefix.
        let _ = value.kind()
        writeJsonValueView(writer, value)
        writer.finish()
    }

    public static func toJson<T>(value: T,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String where T <: GeneratedCodecProviderV1<T> {
        encodeString(value, generatedCodecV1Of<T>(), options)
    }

    public static func toJson<T>(value: T,
        codec!: GeneratedCompactCursorWriteCodecV1<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String
        where T <: GeneratedCompactCodecProviderV1<T> {
        encodeStringStatic(value, codec, options)
    }

    public static func toJson<T>(value: T, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        encodeString(value, codec, options)
    }

    public static func toJsonBytes<T>(value: T,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> where T <: GeneratedCodecProviderV1<T> {
        encodeBytes(value, generatedCodecV1Of<T>(), options)
    }

    public static func toJsonBytes<T>(value: T,
        codec!: GeneratedCompactCursorWriteCodecV1<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> {
        encodeBytes(value, codec, options)
    }

    public static func toJsonBytes<T>(value: T, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> {
        encodeBytes(value, codec, options)
    }

    public static func writeJson<T>(value: T, output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit where T <: GeneratedCodecProviderV1<T> {
        encodeStream(value, generatedCodecV1Of<T>(), output, options)
    }

    public static func writeJson<T>(value: T, output: OutputStream, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        encodeStream(value, codec, output, options)
    }

    public static func fromJson<T>(text: String,
        options!: JsonReadOptions = JsonReadOptions.defaults): T where T <: GeneratedCodecProviderV1<T> {
        decodeString(text, generatedCodecV1Of<T>(), options)
    }

    public static func fromJson<T>(text: String,
        codec!: GeneratedCompactCursorWriteCodecV1<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeString(text, codec, options)
    }

    public static func fromJson<T>(text: String, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeString(text, codec, options)
    }

    public static func fromJson<T>(bytes: Array<Byte>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T where T <: GeneratedCodecProviderV1<T> {
        decodeBytes(bytes, generatedCodecV1Of<T>(), options)
    }

    public static func fromJson<T>(bytes: Array<Byte>,
        codec!: GeneratedCompactCursorWriteCodecV1<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeBytes(bytes, codec, options)
    }

    public static func fromJson<T>(bytes: Array<Byte>, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeBytes(bytes, codec, options)
    }

    public static func fromJson<T>(input: InputStream,
        options!: JsonReadOptions = JsonReadOptions.defaults): T where T <: GeneratedCodecProviderV1<T> {
        decodeStream(input, generatedCodecV1Of<T>(), options)
    }

    public static func fromJson<T>(input: InputStream, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeStream(input, codec, options)
    }

    private static func encodeString<T>(value: T,
        codec: GeneratedCompactCursorWriteCodecV1<T>,
        options: JsonWriteOptions): String {
        let writer = JsonDirectWriter(options)
        if (writer.tryBeginGeneratedCompactRawValue()) {
            codec.writeCompactRawWithWriter(value, writer)
            return writer.finishGeneratedCompactString()
        }
        codec.write(value, writer)
        writer.finishString()
    }

    private static func encodeStringStatic<T>(value: T,
        codec: GeneratedCompactCursorWriteCodecV1<T>,
        options: JsonWriteOptions): String
        where T <: GeneratedCompactCodecProviderV1<T> {
        let writer = JsonDirectWriter(options)
        if (writer.tryBeginGeneratedCompactRawValue()) {
            T.generatedCompactRawV1(value, writer)
            return writer.finishGeneratedCompactString()
        }
        codec.write(value, writer)
        writer.finishString()
    }

    private static func encodeString<T>(value: T, codec: JsonCodec<T>,
        options: JsonWriteOptions): String {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        let writer = JsonDirectWriter(options)
        writeEncoded(value, codec, writer)
        writer.finishString()
    }

    private static func encodeBytes<T>(value: T,
        codec: GeneratedCompactCursorWriteCodecV1<T>,
        options: JsonWriteOptions): Array<Byte> {
        let writer = JsonDirectWriter.bytes(config: options)
        if (writer.tryBeginGeneratedCompactRawValue()) {
            codec.writeCompactRawWithWriter(value, writer)
            return writer.finishBytes()
        }
        codec.write(value, writer)
        writer.finishBytes()
    }

    private static func encodeBytes<T>(value: T, codec: JsonCodec<T>,
        options: JsonWriteOptions): Array<Byte> {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        let writer = JsonDirectWriter.bytes(config: options)
        writeEncoded(value, codec, writer)
        writer.finishBytes()
    }

    private static func encodeStream<T>(value: T, codec: JsonCodec<T>, output: OutputStream,
        options: JsonWriteOptions): Unit {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        let writer = JsonDirectWriter(output, config: options)
        writeEncoded(value, codec, writer)
        writer.finish()
    }

    private static func decodeString<T>(text: String,
        codec: GeneratedCompactCursorWriteCodecV1<T>,
        options: JsonReadOptions): T {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        if (jsonReadOptionsUsesDefaultFastPath(options)) {
            let reader = JsonFastReader(text)
            let result = codec.readFast(reader)
            reader.expectEnd()
            return result
        }
        let reader = JsonDirectReader(text, config: options)
        let result = codec.read(reader)
        reader.expectEnd()
        result
    }

    private static func writeEncoded<T>(value: T, codec: JsonCodec<T>,
        writer: JsonDirectWriter): Unit {
        match (codec) {
            case compact: GeneratedCompactCursorWriteCodecV1<T> =>
                if (writer.tryBeginGeneratedCompactRawValue()) {
                    compact.writeCompactRawWithCursor(value, writer, writer.generatedCursorV1())
                    return
                }
            case _ => ()
        }
        match (codec) {
            case cursor: GeneratedCursorWriteCodecV1<T> =>
                if (cursor.supportsCompactCursorWrite() && writer.tryBeginGeneratedCompactRawValue()) {
                    cursor.writeCompactWithCursor(value, writer, writer.generatedCursorV1())
                    return
                }
            case _ => ()
        }
        codec.write(value, writer)
    }
    private static func decodeString<T>(text: String, codec: JsonCodec<T>,
        options: JsonReadOptions): T {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        if (jsonReadOptionsUsesDefaultFastPath(options)) {
            match (codec) {
                case fast: GeneratedCodecV1<T> =>
                    let reader = JsonFastReader(text)
                    let result = fast.readFast(reader)
                    reader.expectEnd()
                    return result
                case cursor: GeneratedCursorReadCodecV1<T> =>
                    let reader = JsonFastReader(text)
                    let result = cursor.readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
                    reader.expectEnd()
                    return result
                case _ => ()
            }
        }
        let reader = JsonDirectReader(text, config: options)
        let result = codec.read(reader)
        reader.expectEnd()
        result
    }

    private static func decodeBytes<T>(bytes: Array<Byte>,
        codec: GeneratedCompactCursorWriteCodecV1<T>,
        options: JsonReadOptions): T {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        if (jsonReadOptionsUsesDefaultFastPath(options)) {
            let reader = JsonFastReader(bytes)
            let result = codec.readFast(reader)
            reader.expectEnd()
            return result
        }
        let reader = JsonDirectReader(bytes, config: options)
        let result = codec.read(reader)
        reader.expectEnd()
        result
    }

    private static func decodeBytes<T>(bytes: Array<Byte>, codec: JsonCodec<T>,
        options: JsonReadOptions): T {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        if (jsonReadOptionsUsesDefaultFastPath(options)) {
            match (codec) {
                case fast: GeneratedCodecV1<T> =>
                    let reader = JsonFastReader(bytes)
                    let result = fast.readFast(reader)
                    reader.expectEnd()
                    return result
                case cursor: GeneratedCursorReadCodecV1<T> =>
                    let reader = JsonFastReader(bytes)
                    let result = cursor.readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))
                    reader.expectEnd()
                    return result
                case _ => ()
            }
        }
        let reader = JsonDirectReader(bytes, config: options)
        let result = codec.read(reader)
        reader.expectEnd()
        result
    }

    private static func decodeStream<T>(input: InputStream, codec: JsonCodec<T>,
        options: JsonReadOptions): T {
        GeneratedSupportV1.requireProtocolVersion(1)
        freezeYJsonRuntime()
        let reader = JsonDirectReader(input, config: options)
        let result = codec.read(reader)
        reader.expectEnd()
        result
    }
}

/// Built-in and composition codecs used with the explicit `codec:` overloads.
public class JsonCodecs {
    public static prop bool: JsonCodec<Bool> { get() { BoolJson } }
    public static prop int64: JsonCodec<Int64> { get() { Int64Json } }
    public static prop int32: JsonCodec<Int32> { get() { Int32Json } }
    public static prop int16: JsonCodec<Int16> { get() { Int16Json } }
    public static prop int8: JsonCodec<Int8> { get() { Int8Json } }
    public static prop uint64: JsonCodec<UInt64> { get() { UInt64Json } }
    public static prop uint32: JsonCodec<UInt32> { get() { UInt32Json } }
    public static prop uint16: JsonCodec<UInt16> { get() { UInt16Json } }
    public static prop uint8: JsonCodec<UInt8> { get() { UInt8Json } }
    public static prop float64: JsonCodec<Float64> { get() { Float64Json } }
    public static prop float32: JsonCodec<Float32> { get() { Float32Json } }
    public static prop float16: JsonCodec<Float16> { get() { Float16Json } }
    public static prop string: JsonCodec<String> { get() { StringJson } }
    public static prop rune: JsonCodec<Rune> { get() { RuneJson } }
    public static prop bigInt: JsonCodec<BigInt> { get() { BigIntJson } }
    public static prop decimal: JsonCodec<Decimal> { get() { DecimalJson } }
    public static prop rfc3339DateTime: JsonCodec<DateTime> { get() { DateTimeJson } }

    public static func option<T>(inner: JsonCodec<T>): JsonCodec<Option<T>> {
        match (inner) {
            case _: LambdaFastRawJsonCodec<String> =>
                return (StringOptionJsonCodec() as JsonCodec<Option<T>>).getOrThrow()
            case _ => OptionJsonCodec(inner)
        }
    }

    public static func array<T>(inner: JsonCodec<T>): JsonCodec<Array<T>> {
        match (inner) {
            case _: LambdaFastRawJsonCodec<Int64> =>
                return (Int64ArrayJsonCodec() as JsonCodec<Array<T>>).getOrThrow()
            case _ => ArrayJsonCodec(inner)
        }
    }

    public static func arrayList<T>(inner: JsonCodec<T>): JsonCodec<ArrayList<T>> {
        match (inner) {
            case _: LambdaFastRawJsonCodec<Int64> =>
                return (Int64ArrayListJsonCodec() as JsonCodec<ArrayList<T>>).getOrThrow()
            case _: LambdaFastRawJsonCodec<String> =>
                return (StringArrayListJsonCodec() as JsonCodec<ArrayList<T>>).getOrThrow()
            case _ => ArrayListJsonCodec(inner)
        }
    }

    public static func stringMap<T>(inner: JsonCodec<T>): JsonCodec<HashMap<String, T>> {
        match (inner) {
            case _: LambdaFastRawJsonCodec<Int64> =>
                return (Int64HashMapJsonCodec() as JsonCodec<HashMap<String, T>>).getOrThrow()
            case _: Int64ArrayJsonCodec =>
                return (Int64ArrayHashMapJsonCodec() as JsonCodec<HashMap<String, T>>).getOrThrow()
            case _ => ()
        }
        HashMapJsonCodec(inner)
    }
}

extend Bool <: GeneratedCodecProviderV1<Bool> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Bool>): JsonCodec<Bool> {
        JsonCodecs.bool
    }
}

extend Int64 <: GeneratedCodecProviderV1<Int64> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Int64>): JsonCodec<Int64> {
        JsonCodecs.int64
    }
}

extend Int32 <: GeneratedCodecProviderV1<Int32> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Int32>): JsonCodec<Int32> {
        JsonCodecs.int32
    }
}

extend Int16 <: GeneratedCodecProviderV1<Int16> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Int16>): JsonCodec<Int16> {
        JsonCodecs.int16
    }
}

extend Int8 <: GeneratedCodecProviderV1<Int8> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Int8>): JsonCodec<Int8> {
        JsonCodecs.int8
    }
}

extend UInt64 <: GeneratedCodecProviderV1<UInt64> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<UInt64>): JsonCodec<UInt64> {
        JsonCodecs.uint64
    }
}

extend UInt32 <: GeneratedCodecProviderV1<UInt32> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<UInt32>): JsonCodec<UInt32> {
        JsonCodecs.uint32
    }
}

extend UInt16 <: GeneratedCodecProviderV1<UInt16> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<UInt16>): JsonCodec<UInt16> {
        JsonCodecs.uint16
    }
}

extend UInt8 <: GeneratedCodecProviderV1<UInt8> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<UInt8>): JsonCodec<UInt8> {
        JsonCodecs.uint8
    }
}

extend Float64 <: GeneratedCodecProviderV1<Float64> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Float64>): JsonCodec<Float64> {
        JsonCodecs.float64
    }
}

extend Float32 <: GeneratedCodecProviderV1<Float32> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Float32>): JsonCodec<Float32> {
        JsonCodecs.float32
    }
}

extend Float16 <: GeneratedCodecProviderV1<Float16> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Float16>): JsonCodec<Float16> {
        JsonCodecs.float16
    }
}

extend String <: GeneratedCodecProviderV1<String> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<String>): JsonCodec<String> {
        JsonCodecs.string
    }
}

extend Rune <: GeneratedCodecProviderV1<Rune> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Rune>): JsonCodec<Rune> {
        JsonCodecs.rune
    }
}

extend BigInt <: GeneratedCodecProviderV1<BigInt> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<BigInt>): JsonCodec<BigInt> {
        JsonCodecs.bigInt
    }
}

extend Decimal <: GeneratedCodecProviderV1<Decimal> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Decimal>): JsonCodec<Decimal> {
        JsonCodecs.decimal
    }
}

extend<T> Option<T> <: GeneratedCodecProviderV1<Option<T>> where T <: GeneratedCodecProviderV1<T> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Option<T>>): JsonCodec<Option<T>> {
        JsonCodecs.option(generatedCodecV1Of<T>())
    }
}

extend<T> Array<T> <: GeneratedCodecProviderV1<Array<T>> where T <: GeneratedCodecProviderV1<T> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<Array<T>>): JsonCodec<Array<T>> {
        JsonCodecs.array(generatedCodecV1Of<T>())
    }
}

extend<T> ArrayList<T> <: GeneratedCodecProviderV1<ArrayList<T>> where T <: GeneratedCodecProviderV1<T> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<ArrayList<T>>): JsonCodec<ArrayList<T>> {
        JsonCodecs.arrayList(generatedCodecV1Of<T>())
    }
}

extend<T> HashMap<String, T> <: GeneratedCodecProviderV1<HashMap<String, T>>
    where T <: GeneratedCodecProviderV1<T> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<HashMap<String, T>>): JsonCodec<HashMap<String, T>> {
        JsonCodecs.stringMap(generatedCodecV1Of<T>())
    }
}
