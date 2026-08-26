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
public interface JsonCodecReader {
    func readConfig(): JsonReadConfig

    func readReplayValue(maxBytes: Int64): JsonReplayValue

    func expectEnd(): Unit
    func startObject(): Unit
    func endObject(): Unit
    func hasObjectField(): Bool
    func readName(): String
    func readNameId(candidates: Array<String>): Int64
    func startArray(): Unit
    func endArray(): Unit
    func hasArrayItem(): Bool
    func tryReadNull(): Bool
    func readNull(): Unit
    func readBool(): Bool
    func readString(): String
    func skipString(): Unit
    func readInt64(): Int64
    func readUInt64(): UInt64
    func readFloat64(): Float64
    func readBigInt(): BigInt
    func readDecimal(): Decimal
    func readNumberLiteral(): String
    func skipValue(): Unit
    func skipValueWithDepth(maxDepth: Int64): Unit
}

/// A captured JSON value that can be replayed without serializing and parsing
/// it again. This is public because generated codecs live in a separate
/// package; applications normally do not need to implement it.
public interface JsonReplayValue <: Resource {
    func rootStringField(name: String): Option<String>

    /// Opens a fresh reader over the captured root object while omitting every
    /// occurrence of `name`. Duplicate rejection has already happened when the
    /// value was captured; LastWins lookup is used by `rootStringField`.
    func openObjectReaderExcluding(name: String): JsonCodecReader

    func materialize(): JsonNode
}

/// Backend-neutral semantic writer consumed by typed JSON codecs.
public interface JsonCodecWriter {
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
    func writeRawNumber(value: String): Unit
    func writeString(value: String): Unit
}

/// Optional bulk hooks used by generated and built-in codecs. Returning false
/// asks the codec to use the structural `JsonCodecWriter` fallback.
public interface JsonCodecBulkWriter {
    func tryWriteCompactInt64ArrayList(values: ArrayList<Int64>): Bool
    func tryWriteCompactStringArrayList(values: ArrayList<String>): Bool
    func tryWriteCompactInt64Map(values: HashMap<String, Int64>): Bool
}

public func jsonTryWriteCompactInt64ArrayList(
    writer: JsonCodecWriter,
    values: ArrayList<Int64>
): Bool {
    match (writer) {
        case bulk: JsonCodecBulkWriter => bulk.tryWriteCompactInt64ArrayList(values)
        case _ => false
    }
}

public func jsonTryWriteCompactStringArrayList(
    writer: JsonCodecWriter,
    values: ArrayList<String>
): Bool {
    match (writer) {
        case bulk: JsonCodecBulkWriter => bulk.tryWriteCompactStringArrayList(values)
        case _ => false
    }
}

public func jsonTryWriteCompactInt64Map(
    writer: JsonCodecWriter,
    values: HashMap<String, Int64>
): Bool {
    match (writer) {
        case bulk: JsonCodecBulkWriter => bulk.tryWriteCompactInt64Map(values)
        case _ => false
    }
}

public interface JsonCodec<T> {
    func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit

    func read(reader: JsonCodecReader, context: JsonDecodeContext): T
}

public interface JsonObjectCodec<T> <: JsonCodec<T> {
    func writeObjectFields(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit
}

public interface JsonAnyCodec {
    func writeAny(value: Any, writer: JsonCodecWriter, context: JsonEncodeContext): Unit

    func readAny(reader: JsonCodecReader, context: JsonDecodeContext): Any

    func readAnyFast(reader: JsonFastReader, context: JsonDecodeContext): Any
}

public interface JsonCodecProvider {
    static func jsonCodec(): JsonAnyCodec
}

private class ErasedJsonCodec<T> <: JsonAnyCodec {
    private let codec: JsonCodec<T>

    public init(codec: JsonCodec<T>) {
        this.codec = codec
    }

    public func writeAny(value: Any, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        match (value) {
            case typed: T => codec.write(typed, writer, context)
            case _ => throw JsonException("Codec value type mismatch", code: "codec_type_mismatch",
                path: context.currentPath())
        }
    }

    public func readAny(reader: JsonCodecReader, context: JsonDecodeContext): Any {
        codec.read(reader, context)
    }

    public func readAnyFast(reader: JsonFastReader, context: JsonDecodeContext): Any {
        match (codec) {
            case fast: JsonFastCodec<T> => fast.readFast(reader, context)
            case _ => throw JsonException("Codec does not provide a fast-reader implementation", code: "codec_contract",
                path: context.currentPath())
        }
    }

    func typedCodec(): JsonCodec<T> {
        codec
    }
}

private class ReifiedJsonCodec<T> <: JsonCodec<T> {
    private let codec: JsonAnyCodec

    public init(codec: JsonAnyCodec) {
        this.codec = codec
    }

    public func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        codec.writeAny(value, writer, context)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): T {
        match (codec.readAny(reader, context)) {
            case typed: T => typed
            case _ => throw JsonException("Decoded value type mismatch", code: "codec_type_mismatch",
                path: context.currentPath())
        }
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        match (codec.readAnyFast(reader, context)) {
            case typed: T => typed
            case _ => throw JsonException("Decoded value type mismatch", code: "codec_type_mismatch",
                path: context.currentPath())
        }
    }
}

public func eraseJsonCodec<T>(codec: JsonCodec<T>): JsonAnyCodec {
    ErasedJsonCodec(codec)
}

public func jsonCodecOf<T>(): JsonCodec<T> where T <: JsonCodecProvider {
    let erased = T.jsonCodec()
    match (erased) {
        // @JsonCodec providers and built-ins originate from eraseJsonCodec.
        // Recover their typed codec once during resolution so every subsequent
        // field operation avoids Any boxing, runtime type tests and the
        // ReifiedJsonCodec/ErasedJsonCodec method-table round trip.
        case typed: ErasedJsonCodec<T> => typed.typedCodec()
        // A custom provider may implement JsonAnyCodec directly. Preserve its
        // existing erased contract and diagnostics through the compatibility
        // adapter instead of assuming generated-code semantics.
        case _ => ReifiedJsonCodec<T>(erased)
    }
}

// Kept as an internal optimization surface for the existing built-in codecs.
public interface JsonFastCodec<T> <: JsonCodec<T> {
    func readFast(reader: JsonFastReader, context: JsonDecodeContext): T
}

/// Matching-version bridge used by generated codecs to retain the concrete
/// direct-writer type across nested semantic encode calls.
public interface JsonDirectWriteCodec<T> <: JsonCodec<T> {
    func writeDirect(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit
}

/// Matching-version generated-code bridge for objects whose fields can be
/// emitted directly in compact mode without bypassing encode context checks.
public interface JsonCompactRawCodec<T> <: JsonDirectWriteCodec<T> {
    func supportsCompactRaw(): Bool
    func writeCompactRaw(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit
}

public func writeJsonDirectWith<T>(
    codec: JsonCodec<T>,
    value: T,
    writer: JsonDirectWriter,
    context: JsonEncodeContext
): Unit {
    match (codec) {
        case direct: JsonDirectWriteCodec<T> => direct.writeDirect(value, writer, context)
        case _ => codec.write(value, writer, context)
    }
}

public func jsonTryBeginGeneratedCompactRawValue(writer: JsonDirectWriter): Bool {
    writer.tryBeginGeneratedCompactRawValue()
}

public func jsonWriteGeneratedCompactObjectBegin(writer: JsonDirectWriter): Unit {
    writer.writeRawBeginObject()
}

public func jsonWriteGeneratedCompactObjectEnd(writer: JsonDirectWriter): Unit {
    writer.writeRawEndObject()
}

public func jsonWriteGeneratedCompactArrayBegin(writer: JsonDirectWriter): Unit {
    writer.writeRawBeginArray()
}

public func jsonWriteGeneratedCompactArrayEnd(writer: JsonDirectWriter): Unit {
    writer.writeRawEndArray()
}

public func jsonWriteGeneratedCompactComma(writer: JsonDirectWriter): Unit {
    writer.writeRawByte(b',')
}

public func jsonWriteGeneratedCompactObjectEntryName(
    writer: JsonDirectWriter,
    first: Bool,
    name: String
): Bool {
    writer.writeRawObjectEntryName(first, name)
}

public func jsonWriteGeneratedCompactObjectEntryString(
    writer: JsonDirectWriter,
    first: Bool,
    name: String,
    value: String
): Bool {
    writer.writeRawObjectEntryNameString(first, name, value)
}

public func jsonWriteGeneratedCompactObjectEntryBool(
    writer: JsonDirectWriter,
    first: Bool,
    name: String,
    value: Bool
): Bool {
    writer.writeRawObjectEntryNameBool(first, name, value)
}

public func jsonWriteGeneratedCompactObjectEntryInt64(
    writer: JsonDirectWriter,
    first: Bool,
    name: String,
    value: Int64
): Bool {
    writer.writeRawObjectEntryNameInt64(first, name, value)
}

/// Reusable typed decoder that resolves the fast codec contract once.
///
/// Create instances through `YJson.fastDecoder`. Its decode methods are
/// intentionally non-generic so repeated calls avoid per-call generic runtime
/// type resolution while preserving the normal read-configuration semantics.
public interface JsonFastDecoder<T> {
    func decodeString(text: String): T

    func decodeString(text: String, config!: JsonReadConfig): T

    func decodeBytes(bytes: Array<Byte>): T

    func decodeBytes(bytes: Array<Byte>, config!: JsonReadConfig): T
}

public interface JsonArrayListFastCodec<T> <: JsonFastCodec<T> {
    func readFastArrayList(reader: JsonFastReader, context: JsonDecodeContext): ArrayList<T>
}

interface JsonRawWriteCodec<T> <: JsonCodec<T> {
    func writeRaw(value: T, writer: JsonDirectWriter): Unit
}

interface JsonArrayListRawWriteCodec<T> <: JsonArrayListFastCodec<T> {
    func writeRawArrayList(value: ArrayList<T>, writer: JsonDirectWriter): Unit
}

public class JsonEncodeContext {
    private let maxDepth: Int64
    private var depth: Int64 = 0
    private var path: Option<ArrayList<String>> = None<ArrayList<String>>
    private var pathIndexPairs: Option<ArrayList<Int64>> = None<ArrayList<Int64>>

    public init(config: JsonWriteConfig) {
        maxDepth = config.maxDepth
    }

    public func pushField(name: String): Unit {
        pathValues().add(name)
    }

    public func pushIndex(index: Int64): Unit {
        let values = pathValues()
        let pairs = match (pathIndexPairs) {
            case Some(value) => value
            case None =>
                let value = ArrayList<Int64>()
                pathIndexPairs = Some(value)
                value
        }
        pairs.add(values.size)
        pairs.add(index)
        values.add("")
    }

    public func popPath(): Unit {
        if (let Some(values) <- path) {
            if (!values.isEmpty()) {
                let position = values.size - 1
                if (let Some(pairs) <- pathIndexPairs) {
                    if (!pairs.isEmpty() && pairs[pairs.size - 2] == position) {
                        pairs.remove(at: pairs.size - 1)
                        pairs.remove(at: pairs.size - 1)
                    }
                }
                values.remove(at: position)
            }
        }
    }

    public func updateLastField(name: String): Unit {
        let values = pathValues()
        if (!values.isEmpty()) {
            values[values.size - 1] = name
        }
    }

    public func updateLastIndex(index: Int64): Unit {
        if (let Some(pairs) <- pathIndexPairs) {
            if (!pairs.isEmpty()) {
                pairs[pairs.size - 1] = index
            }
        }
    }

    public func enterValue(): Unit {
        if (depth >= maxDepth) {
            throw JsonException("Maximum JSON depth ${maxDepth} exceeded", code: "max_depth", path: currentPath())
        }
        depth++
    }

    public func leaveValue(): Unit {
        if (depth > 0) {
            depth--
        }
    }

    public func enterObject<T>(value: T): Unit {
        let _ = value
        enterValue()
    }

    public func leaveObject(): Unit {
        leaveValue()
    }

    public func currentPath(): String {
        let values = match (path) {
            case Some(value) => value
            case None => return "$"
        }
        let result = StringBuilder("$")
        let pairs = pathIndexPairs.getOrDefault({=> ArrayList<Int64>()})
        var pairCursor: Int64 = 0
        for (position in 0..values.size) {
            if (pairCursor < pairs.size && pairs[pairCursor] == position) {
                result.append("[")
                result.append(pairs[pairCursor + 1].toString())
                result.append("]")
                pairCursor += 2
            } else {
                result.append(".")
                result.append(values[position])
            }
        }
        result.toString()
    }

    private func pathValues(): ArrayList<String> {
        match (path) {
            case Some(value) => value
            case None =>
                let value = ArrayList<String>()
                path = Some(value)
                value
        }
    }
}

public class JsonDecodeContext {
    private let maxDepth: Int64
    private var depth: Int64 = 0
    private var path: Option<ArrayList<String>> = None<ArrayList<String>>
    private var pathIndexPairs: Option<ArrayList<Int64>> = None<ArrayList<Int64>>

    public init(config: JsonReadConfig) {
        maxDepth = config.maxDepth
    }

    public func pushField(name: String): Unit {
        pathValues().add(name)
    }

    public func pushIndex(index: Int64): Unit {
        let values = pathValues()
        let pairs = match (pathIndexPairs) {
            case Some(value) => value
            case None =>
                let value = ArrayList<Int64>()
                pathIndexPairs = Some(value)
                value
        }
        pairs.add(values.size)
        pairs.add(index)
        values.add("")
    }

    public func popPath(): Unit {
        if (let Some(values) <- path) {
            if (!values.isEmpty()) {
                let position = values.size - 1
                if (let Some(pairs) <- pathIndexPairs) {
                    if (!pairs.isEmpty() && pairs[pairs.size - 2] == position) {
                        pairs.remove(at: pairs.size - 1)
                        pairs.remove(at: pairs.size - 1)
                    }
                }
                values.remove(at: values.size - 1)
            }
        }
    }

    func updateLastField(name: String): Unit {
        let values = pathValues()
        if (!values.isEmpty()) {
            values[values.size - 1] = name
        }
    }

    func updateLastIndex(index: Int64): Unit {
        if (let Some(pairs) <- pathIndexPairs) {
            if (!pairs.isEmpty()) {
                pairs[pairs.size - 1] = index
            }
        }
    }

    public func enterValue(): Unit {
        if (depth >= maxDepth) {
            throw JsonException("Maximum JSON depth ${maxDepth} exceeded", code: "max_depth", path: currentPath())
        }
        depth++
    }

    public func leaveValue(): Unit {
        if (depth > 0) {
            depth--
        }
    }

    /// Remaining container levels available to a subtree skipped by a reader.
    /// Generated codecs use this bridge so unknown fields obey the same depth
    /// budget as known fields.
    public func remainingDepth(): Int64 {
        maxDepth - depth
    }

    public func currentPath(): String {
        let values = match (path) {
            case Some(value) => value
            case None => return "$"
        }
        let result = StringBuilder("$")
        match (pathIndexPairs) {
            case Some(pairs) =>
                var pairCursor: Int64 = 0
                for (position in 0..values.size) {
                    if (pairCursor < pairs.size && pairs[pairCursor] == position) {
                        result.append("[")
                        result.append(pairs[pairCursor + 1].toString())
                        result.append("]")
                        pairCursor += 2
                    } else {
                        result.append(".")
                        result.append(values[position])
                    }
                }
            case None => for (value in values) {
                result.append(".")
                result.append(value)
            }
        }
        result.toString()
    }

    private func pathValues(): ArrayList<String> {
        match (path) {
            case Some(value) => value
            case None =>
                let value = ArrayList<String>()
                path = Some(value)
                value
        }
    }
}

// Compatibility adapters for the existing highly specialized built-in codecs.
class LambdaSemanticJsonCodec<T> <: JsonCodec<T> {
    private let writerFn: (T, JsonCodecWriter) -> Unit
    private let readerFn: (JsonCodecReader) -> T

    public init(writerFn: (T, JsonCodecWriter) -> Unit, readerFn: (JsonCodecReader) -> T) {
        this.writerFn = writerFn
        this.readerFn = readerFn
    }

    public func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writerFn(value, writer)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): T {
        let _ = context
        readerFn(reader)
    }
}

class LambdaYJsonCodec<T> <: JsonFastCodec<T> {
    private let writerFn: (T, JsonCodecWriter) -> Unit
    private let readerFn: (JsonCodecReader) -> T
    private let fastReaderFn: (JsonFastReader) -> T

    public init(
        writerFn: (T, JsonCodecWriter) -> Unit,
        readerFn: (JsonCodecReader) -> T,
        fastReaderFn: (JsonFastReader) -> T
    ) {
        this.writerFn = writerFn
        this.readerFn = readerFn
        this.fastReaderFn = fastReaderFn
    }

    public func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writerFn(value, writer)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): T {
        let _ = context
        readerFn(reader)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        let _ = context
        fastReaderFn(reader)
    }
}

class LambdaFastRawJsonCodec<T> <: JsonFastCodec<T> & JsonRawWriteCodec<T> {
    private let writerFn: (T, JsonCodecWriter) -> Unit
    private let readerFn: (JsonCodecReader) -> T
    private let fastReaderFn: (JsonFastReader) -> T
    private let rawWriterFn: (T, JsonDirectWriter) -> Unit

    public init(
        writerFn: (T, JsonCodecWriter) -> Unit,
        readerFn: (JsonCodecReader) -> T,
        fastReaderFn: (JsonFastReader) -> T,
        rawWriterFn: (T, JsonDirectWriter) -> Unit
    ) {
        this.writerFn = writerFn
        this.readerFn = readerFn
        this.fastReaderFn = fastReaderFn
        this.rawWriterFn = rawWriterFn
    }

    public func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
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

    public func writeRaw(value: T, writer: JsonDirectWriter): Unit {
        rawWriterFn(value, writer)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): T {
        let _ = context
        readerFn(reader)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        let _ = context
        fastReaderFn(reader)
    }
}

public func readJsonFastWith<T>(codec: JsonCodec<T>, reader: JsonFastReader, context: JsonDecodeContext): T {
    match (codec) {
        case reified: ReifiedJsonCodec<T> => reified.readFast(reader, context)
        case fast: JsonFastCodec<T> => fast.readFast(reader, context)
        case _ => throw JsonException("Codec does not provide a fast-reader implementation", code: "codec_contract",
            path: context.currentPath())
    }
}

private class ReifiedFastCodecAdapter<T> <: JsonFastCodec<T> {
    private let inner: ReifiedJsonCodec<T>

    public init(inner: ReifiedJsonCodec<T>) {
        this.inner = inner
    }

    public func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        inner.write(value, writer, context)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): T {
        inner.read(reader, context)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        inner.readFast(reader, context)
    }
}

private class ContractFastCodecAdapter<T> <: JsonFastCodec<T> {
    private let inner: JsonCodec<T>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
    }

    public func write(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        inner.write(value, writer, context)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): T {
        inner.read(reader, context)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        readJsonFastWith(inner, reader, context)
    }
}

private func resolvedJsonFastCodec<T>(codec: JsonCodec<T>): JsonFastCodec<T> {
    match (codec) {
        case reified: ReifiedJsonCodec<T> => ReifiedFastCodecAdapter<T>(reified)
        case fast: JsonFastCodec<T> => fast
        case _ => ContractFastCodecAdapter<T>(codec)
    }
}

private class OptionJsonCodec<T> <: JsonFastCodec<Option<T>> & JsonCompactRawCodec<Option<T>> {
    private let inner: JsonCodec<T>
    private let directInner: Option<JsonDirectWriteCodec<T>>
    private let compactRawInner: Option<JsonCompactRawCodec<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.directInner = match (inner) {
            case direct: JsonDirectWriteCodec<T> => Some(direct)
            case _ => None<JsonDirectWriteCodec<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: JsonCompactRawCodec<T> => Some(raw)
            case _ => None<JsonCompactRawCodec<T>>
        }
    }

    public func write(value: Option<T>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct, context)
                return
            case _ => ()
        }
        match (value) {
            case Some(item) => inner.write(item, writer, context)
            case None => writer.writeNull()
        }
    }

    public func writeDirect(value: Option<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        if (supportsCompactRaw() && jsonTryBeginGeneratedCompactRawValue(writer)) {
            writeCompactRaw(value, writer, context)
            return
        }
        match (value) {
            case Some(item) =>
                match (directInner) {
                    case Some(direct) => direct.writeDirect(item, writer, context)
                    case None => inner.write(item, writer, context)
                }
            case None => writer.writeNull()
        }
    }

    public func supportsCompactRaw(): Bool {
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: Option<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        match (value) {
            case Some(item) =>
                match (compactRawInner) {
                    case Some(raw) => raw.writeCompactRaw(item, writer, context)
                    case None => throw JsonException("Compact raw codec is unavailable")
                }
            case None => writer.writeRawNull()
        }
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): Option<T> {
        if (reader.tryReadNull()) {
            return None<T>
        }
        Some(inner.read(reader, context))
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): Option<T> {
        if (reader.tryReadRawNull()) {
            return None<T>
        }
        Some(readJsonFastWith(inner, reader, context))
    }
}

private class StringOptionJsonCodec <: JsonFastCodec<Option<String>> {
    public func write(value: Option<String>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        let _ = context
        match (value) {
            case Some(item) => writer.writeString(item)
            case None => writer.writeNull()
        }
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): Option<String> {
        let _ = context
        if (reader.tryReadNull()) {
            return None<String>
        }
        Some(reader.readString())
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): Option<String> {
        let _ = context
        if (reader.tryReadRawNull()) {
            return None<String>
        }
        Some(reader.readRawString())
    }
}

private class ArrayJsonCodec<T> <: JsonFastCodec<Array<T>> & JsonCompactRawCodec<Array<T>> {
    private let inner: JsonCodec<T>
    private let fastInner: JsonFastCodec<T>
    private let directInner: Option<JsonDirectWriteCodec<T>>
    private let compactRawInner: Option<JsonCompactRawCodec<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedJsonFastCodec(inner)
        this.directInner = match (inner) {
            case direct: JsonDirectWriteCodec<T> => Some(direct)
            case _ => None<JsonDirectWriteCodec<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: JsonCompactRawCodec<T> => Some(raw)
            case _ => None<JsonCompactRawCodec<T>>
        }
    }

    public func write(value: Array<T>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct, context)
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
                        inner.write(value[index], writer, context)
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

    public func writeDirect(value: Array<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        if (supportsCompactRaw() && jsonTryBeginGeneratedCompactRawValue(writer)) {
            writeCompactRaw(value, writer, context)
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
                            case Some(direct) => direct.writeDirect(value[index], writer, context)
                            case None => inner.write(value[index], writer, context)
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
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: Array<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            jsonWriteGeneratedCompactArrayBegin(writer)
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (index in 0..value.size) {
                        if (index > 0) {
                            jsonWriteGeneratedCompactComma(writer)
                            context.updateLastIndex(index)
                        }
                        match (compactRawInner) {
                            case Some(raw) => raw.writeCompactRaw(value[index], writer, context)
                            case None => throw JsonException("Compact raw codec is unavailable")
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            jsonWriteGeneratedCompactArrayEnd(writer)
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): Array<T> {
        context.enterValue()
        try {
            let result = ArrayList<T>()
            reader.startArray()
            var index: Int64 = 0
            while (reader.hasArrayItem()) {
                context.pushIndex(index)
                try {
                    result.add(inner.read(reader, context))
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

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): Array<T> {
        context.enterValue()
        try {
            reader.startRawArray()
            if (!reader.hasRawArrayItem(true)) {
                reader.endRawArray()
                return Array<T>()
            }
            let capacity = reader.suggestRawCollectionCapacity()
            let result = if (capacity > 4) {
                ArrayList<T>(capacity)
            } else {
                ArrayList<T>()
            }
            var first = true
            var index: Int64 = 0
            if (reader.hasRawArrayItem(first)) {
                context.pushIndex(index)
                try {
                    while (true) {
                        reader.beforeRawArrayItem(first)
                        if (!first) {
                            context.updateLastIndex(index)
                        }
                        result.add(fastInner.readFast(reader, context))
                        first = false
                        index++
                        if (!reader.hasRawArrayItem(first)) {
                            break
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            reader.endRawArray()
            return result.toArray()
        } finally {
            context.leaveValue()
        }
    }
}

private class ArrayListJsonCodec<T> <: JsonFastCodec<ArrayList<T>> & JsonCompactRawCodec<ArrayList<T>> {
    private let inner: JsonCodec<T>
    private let fastInner: JsonFastCodec<T>
    private let directInner: Option<JsonDirectWriteCodec<T>>
    private let compactRawInner: Option<JsonCompactRawCodec<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedJsonFastCodec(inner)
        this.directInner = match (inner) {
            case direct: JsonDirectWriteCodec<T> => Some(direct)
            case _ => None<JsonDirectWriteCodec<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: JsonCompactRawCodec<T> => Some(raw)
            case _ => None<JsonCompactRawCodec<T>>
        }
    }

    public func write(value: ArrayList<T>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct, context)
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
                    for (item in value) {
                        if (index > 0) {
                            context.updateLastIndex(index)
                        }
                        inner.write(item, writer, context)
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

    public func writeDirect(value: ArrayList<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        if (supportsCompactRaw() && jsonTryBeginGeneratedCompactRawValue(writer)) {
            writeCompactRaw(value, writer, context)
            return
        }
        context.enterValue()
        try {
            writer.startArray()
            var index: Int64 = 0
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (item in value) {
                        if (index > 0) {
                            context.updateLastIndex(index)
                        }
                        match (directInner) {
                            case Some(direct) => direct.writeDirect(item, writer, context)
                            case None => inner.write(item, writer, context)
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
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: ArrayList<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            jsonWriteGeneratedCompactArrayBegin(writer)
            var index: Int64 = 0
            if (!value.isEmpty()) {
                context.pushIndex(0)
                try {
                    for (item in value) {
                        if (index > 0) {
                            jsonWriteGeneratedCompactComma(writer)
                            context.updateLastIndex(index)
                        }
                        match (compactRawInner) {
                            case Some(raw) => raw.writeCompactRaw(item, writer, context)
                            case None => throw JsonException("Compact raw codec is unavailable")
                        }
                        index++
                    }
                } finally {
                    context.popPath()
                }
            }
            jsonWriteGeneratedCompactArrayEnd(writer)
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): ArrayList<T> {
        context.enterValue()
        try {
            let result = ArrayList<T>()
            reader.startArray()
            var index: Int64 = 0
            while (reader.hasArrayItem()) {
                context.pushIndex(index)
                try {
                    result.add(inner.read(reader, context))
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

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): ArrayList<T> {
        context.enterValue()
        try {
            reader.startRawArray()
            if (!reader.hasRawArrayItem(true)) {
                reader.endRawArray()
                return ArrayList<T>()
            }
            let capacity = reader.suggestRawCollectionCapacity()
            let result = if (capacity > 4) {
                ArrayList<T>(capacity)
            } else {
                ArrayList<T>()
            }
            var first = true
            var index: Int64 = 0
            if (reader.hasRawArrayItem(first)) {
                context.pushIndex(index)
                try {
                    while (true) {
                        reader.beforeRawArrayItem(first)
                        if (!first) {
                            context.updateLastIndex(index)
                        }
                        result.add(fastInner.readFast(reader, context))
                        first = false
                        index++
                        if (!reader.hasRawArrayItem(first)) {
                            break
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            reader.endRawArray()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

private class Int64ArrayListJsonCodec <: JsonFastCodec<ArrayList<Int64>> {
    public func write(value: ArrayList<Int64>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            if (jsonTryWriteCompactInt64ArrayList(writer, value)) {
                return
            }
            writer.startArray()
            for (item in value) {
                writer.writeInt64(item)
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }
    public func read(reader: JsonCodecReader, context: JsonDecodeContext): ArrayList<Int64> {
        ArrayListJsonCodec<Int64>(Int64Json).read(reader, context)
    }
    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): ArrayList<Int64> {
        context.enterValue()
        try {
            reader.startRawArray()
            if (!reader.hasRawArrayItem(true)) {
                reader.endRawArray()
                return ArrayList<Int64>()
            }
            let result = ArrayList<Int64>(reader.suggestRawArrayCapacity())
            var first = true
            while (reader.hasRawArrayItem(first)) {
                reader.beforeRawArrayItem(first)
                result.add(reader.readRawInt64())
                first = false
            }
            reader.endRawArray()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

private class StringArrayListJsonCodec <: JsonFastCodec<ArrayList<String>> {
    public func write(value: ArrayList<String>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            if (jsonTryWriteCompactStringArrayList(writer, value)) {
                return
            }
            writer.startArray()
            for (item in value) {
                writer.writeString(item)
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): ArrayList<String> {
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

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): ArrayList<String> {
        context.enterValue()
        try {
            reader.startRawArray()
            if (!reader.hasRawArrayItem(true)) {
                reader.endRawArray()
                return ArrayList<String>()
            }
            let result = ArrayList<String>(reader.suggestRawArrayCapacity())
            var first = true
            while (reader.hasRawArrayItem(first)) {
                reader.beforeRawArrayItem(first)
                result.add(reader.readRawString())
                first = false
            }
            reader.endRawArray()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

// Concrete generated-code bridges. They are public only because macro output
// may live in a consumer package; ordinary users should use YJson codecs.
public func __yJsonWriteStringArrayList(value: ArrayList<String>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
    context.enterValue()
    try {
        if (jsonTryWriteCompactStringArrayList(writer, value)) {
            return
        }
        writer.startArray();
        for (item in value) {
            writer.writeString(item)
        };
        writer.endArray()
    } finally {
        context.leaveValue()
    }
}

public func __yJsonReadStringArrayList(reader: JsonCodecReader, context: JsonDecodeContext): ArrayList<String> {
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

public func __yJsonReadFastStringArrayList(reader: JsonFastReader, context: JsonDecodeContext): ArrayList<String> {
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

public func __yJsonWriteStringOption(value: Option<String>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
    let _ = context
    match (value) {
        case Some(item) => writer.writeString(item);
        case None => writer.writeNull()
    }
}

public func __yJsonReadStringOption(reader: JsonCodecReader, context: JsonDecodeContext): Option<String> {
    let _ = context
    if (reader.tryReadNull()) {
        None<String>
    } else {
        Some(reader.readString())
    }
}

public func __yJsonReadFastStringOption(reader: JsonFastReader, context: JsonDecodeContext): Option<String> {
    let _ = context
    if (reader.tryReadRawNull()) {
        None<String>
    } else {
        Some(reader.readRawString())
    }
}

private class HashMapJsonCodec<T> <: JsonFastCodec<HashMap<String, T>> & JsonCompactRawCodec<HashMap<String, T>> {
    private let inner: JsonCodec<T>
    private let fastInner: JsonFastCodec<T>
    private let rawInner: Option<JsonRawWriteCodec<T>>
    private let directInner: Option<JsonDirectWriteCodec<T>>
    private let compactRawInner: Option<JsonCompactRawCodec<T>>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedJsonFastCodec(inner)
        this.rawInner = match (inner) {
            case raw: JsonRawWriteCodec<T> => Some(raw)
            case _ => None<JsonRawWriteCodec<T>>
        }
        this.directInner = match (inner) {
            case direct: JsonDirectWriteCodec<T> => Some(direct)
            case _ => None<JsonDirectWriteCodec<T>>
        }
        this.compactRawInner = match (inner) {
            case raw: JsonCompactRawCodec<T> => Some(raw)
            case _ => None<JsonCompactRawCodec<T>>
        }
    }

    public func write(value: HashMap<String, T>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        match (writer) {
            case direct: JsonDirectWriter =>
                writeDirect(value, direct, context)
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
                        inner.write(item, writer, context)
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

    public func writeDirect(value: HashMap<String, T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        if (supportsCompactRaw() && jsonTryBeginGeneratedCompactRawValue(writer)) {
            writeCompactRaw(value, writer, context)
            return
        }
        context.enterValue()
        try {
            if (let Some(raw) <- rawInner) {
                if (writer.tryWriteCompactRawMap(value, raw)) {
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
                            case Some(direct) => direct.writeDirect(item, writer, context)
                            case None => inner.write(item, writer, context)
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
        match (compactRawInner) {
            case Some(raw) => raw.supportsCompactRaw()
            case None => false
        }
    }

    public func writeCompactRaw(value: HashMap<String, T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            jsonWriteGeneratedCompactObjectBegin(writer)
            if (!value.isEmpty()) {
                var first = true
                try {
                    for ((name, item) in value) {
                        if (first) {
                            context.pushField(name)
                        } else {
                            context.updateLastField(name)
                        }
                        first = jsonWriteGeneratedCompactObjectEntryName(writer, first, name)
                        match (compactRawInner) {
                            case Some(raw) => raw.writeCompactRaw(item, writer, context)
                            case None => throw JsonException("Compact raw codec is unavailable")
                        }
                    }
                } finally {
                    context.popPath()
                }
            }
            jsonWriteGeneratedCompactObjectEnd(writer)
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): HashMap<String, T> {
        context.enterValue()
        try {
            let result = HashMap<String, T>()
            reader.startObject()
            while (reader.hasObjectField()) {
                let name = reader.readName()
                context.pushField(name)
                try {
                    result[name] = inner.read(reader, context)
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

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): HashMap<String, T> {
        context.enterValue()
        try {
            reader.startRawObject()
            if (!reader.hasRawObjectField(true)) {
                reader.endRawObject()
                return HashMap<String, T>()
            }
            let result = HashMap<String, T>()
            var first = true
            let firstName = reader.readRawName(true)
            context.pushField(firstName)
            try {
                result[firstName] = fastInner.readFast(reader, context)
                first = false
                while (reader.hasRawObjectField(first)) {
                    let name = reader.readRawName(first)
                    context.updateLastField(name)
                    result[name] = fastInner.readFast(reader, context)
                }
            } finally {
                context.popPath()
            }
            reader.endRawObject()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

private class Int64HashMapJsonCodec <: JsonFastCodec<HashMap<String, Int64>> {
    public func write(value: HashMap<String, Int64>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
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

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): HashMap<String, Int64> {
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

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): HashMap<String, Int64> {
        context.enterValue()
        try {
            reader.startRawObject()
            if (!reader.hasRawObjectField(true)) {
                reader.endRawObject()
                return HashMap<String, Int64>()
            }
            let result = HashMap<String, Int64>(reader.suggestRawObjectCapacity())
            var first = true
            while (reader.hasRawObjectField(first)) {
                result[reader.readRawName(first)] = reader.readRawInt64()
                first = false
            }
            reader.endRawObject()
            return result
        } finally {
            context.leaveValue()
        }
    }
}

public func __yJsonWriteInt64HashMap(value: HashMap<String, Int64>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
    context.enterValue()
    try {
        if (jsonTryWriteCompactInt64Map(writer, value)) {
            return
        }
        writer.startObject();
        for ((name, item) in value) {
            writer.writeName(name);
            writer.writeInt64(item)
        };
        writer.endObject()
    } finally {
        context.leaveValue()
    }
}

public func __yJsonReadInt64HashMap(reader: JsonCodecReader, context: JsonDecodeContext): HashMap<String, Int64> {
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

public func __yJsonReadFastInt64HashMap(reader: JsonFastReader, context: JsonDecodeContext): HashMap<String, Int64> {
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

public class YJson {
    public static func parse(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
        freezeYJsonRuntime()
        JsonNode.parse(text, config: config)
    }

    public static func parse(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
        freezeYJsonRuntime()
        JsonNode.parse(bytes, config: config)
    }

    /// Parses a GC-managed read-only Compact document with the frozen engine.
    public static func parseDocument(text: String,
        config!: JsonReadConfig = JsonReadConfig.defaults): JsonDocument {
        freezeYJsonRuntime()
        parseManagedJsonDocument(unsafe { text.rawData() }, config)
    }

    /// Parses raw UTF-8 into the unified read-only document facade.
    public static func parseDocument(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): JsonDocument {
        freezeYJsonRuntime()
        parseManagedJsonDocument(bytes, config)
    }

    public static func stringify(value: JsonNode, config!: JsonWriteConfig = JsonWriteConfig.compact): String {
        freezeYJsonRuntime()
        writeJsonValueToString(value, config)
    }

    public static func stringifyPretty(value: JsonNode, indent!: String = "  "): String {
        stringify(value, config: JsonWriteConfig("\n", indent, true, false))
    }

    public static func nullValue(): JsonNullValue {
        JsonNullValue()
    }

    public static func array(): JsonArrayValue {
        JsonArrayValue()
    }

    public static func object(): JsonObjectValue {
        JsonObjectValue()
    }

    public static func value(value: JsonNode): JsonNode {
        value
    }

    public static func value(value: Bool): JsonNode {
        JsonBoolValue(value)
    }

    public static func value(value: Int64): JsonNode {
        JsonIntValue(value)
    }

    public static func value(value: Float64): JsonNode {
        JsonFloatValue(value)
    }

    public static func value(value: Rune): JsonNode {
        JsonStringValue(value.toString())
    }

    public static func value(value: String): JsonNode {
        JsonStringValue(value)
    }

    public static func value(value: Array<JsonNode>): JsonNode {
        JsonArrayValue(value)
    }

    public static func value<T>(value: T): JsonNode where T <: JsonCodecProvider {
        encodeWith(jsonCodecOf<T>(), value)
    }

    public static func writeValue(value: JsonNode, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writeJsonNodeToCodecWriter(writer, value)
    }

    public static func writeValue<T>(value: T, writer: JsonCodecWriter, context: JsonEncodeContext): Unit where T <: JsonCodecProvider {
        jsonCodecOf<T>().write(value, writer, context)
    }

    public static func toJson<T>(value: T, config!: JsonWriteConfig = JsonWriteConfig.compact): String where T <: JsonCodecProvider {
        freezeYJsonRuntime()
        encodeStringWith(jsonCodecOf<T>(), value, config: config)
    }

    public static func fromJson<T>(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): T where T <: JsonCodecProvider {
        freezeYJsonRuntime()
        decodeStringWith(jsonCodecOf<T>(), text, config: config)
    }

    public static func encodeWith<T>(codec: JsonCodec<T>, value: T,
        config!: JsonCodecConfig = JsonCodecConfig.compact): JsonNode {
        parse(encodeStringWith(codec, value, config: config.write), config: config.read)
    }

    public static func decodeWith<T>(codec: JsonCodec<T>, value: JsonNode,
        config!: JsonCodecConfig = JsonCodecConfig.compact): T {
        decodeStringWith(codec, stringify(value, config: config.write), config: config.read)
    }

    /// Resolves a codec's fast-reader contract once for repeated typed decode.
    public static func fastDecoder<T>(codec: JsonCodec<T>): JsonFastDecoder<T> {
        match (codec) {
            case fast: JsonFastDecoder<T> => fast
            case _ => throw JsonException(
                "Codec does not provide a fast-reader implementation",
                code: "codec_contract",
                path: "$"
            )
        }
    }

    public static func encodeStringWith<T>(codec: JsonCodec<T>, value: T,
        config!: JsonWriteConfig = JsonWriteConfig.compact): String {
        freezeYJsonRuntime()
        let writer = JsonDirectWriter(config)
        codec.write(value, writer, JsonEncodeContext(config))
        writer.finishString()
    }

    public static func encodeBytesWith<T>(codec: JsonCodec<T>, value: T,
        config!: JsonWriteConfig = JsonWriteConfig.compact): Array<Byte> {
        freezeYJsonRuntime()
        let writer = JsonDirectWriter.bytes(config: config)
        codec.write(value, writer, JsonEncodeContext(config))
        writer.finishBytes()
    }

    public static func decodeStringWith<T>(codec: JsonCodec<T>, text: String,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        freezeYJsonRuntime()
        if (jsonReadConfigUsesDefaultFastPath(config)) {
            match (codec) {
                case fast: JsonFastCodec<T> =>
                    let reader = JsonFastReader(text)
                    let result = fast.readFast(reader, JsonDecodeContext(config))
                    reader.expectEnd()
                    return result
                case _ => ()
            }
        }
        let reader = JsonDirectReader(text, config: config)
        let result = codec.read(reader, JsonDecodeContext(config))
        reader.expectEnd()
        result
    }

    public static func decodeBytesWith<T>(codec: JsonCodec<T>, bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        freezeYJsonRuntime()
        if (jsonReadConfigUsesDefaultFastPath(config)) {
            match (codec) {
                case fast: JsonFastCodec<T> =>
                    let reader = JsonFastReader(bytes)
                    let result = fast.readFast(reader, JsonDecodeContext(config))
                    reader.expectEnd()
                    return result
                case _ => ()
            }
        }
        let reader = JsonDirectReader(bytes, config: config)
        let result = codec.read(reader, JsonDecodeContext(config))
        reader.expectEnd()
        result
    }

    public static func encodeToStreamWith<T>(codec: JsonCodec<T>, value: T, out: OutputStream,
        config!: JsonWriteConfig = JsonWriteConfig.compact): Unit {
        freezeYJsonRuntime()
        let writer = JsonDirectWriter(out, config: config)
        codec.write(value, writer, JsonEncodeContext(config))
        writer.finish()
    }

    public static func decodeFromStreamWith<T>(codec: JsonCodec<T>, input: InputStream,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        freezeYJsonRuntime()
        let reader = JsonDirectReader(input, config: config)
        let result = codec.read(reader, JsonDecodeContext(config))
        reader.expectEnd()
        result
    }

    public static func toStream<T>(value: T, out: OutputStream,
        config!: JsonWriteConfig = JsonWriteConfig.compact): Unit where T <: JsonCodecProvider {
        freezeYJsonRuntime()
        encodeToStreamWith(jsonCodecOf<T>(), value, out, config: config)
    }

    public static func fromStream<T>(input: InputStream,
        config!: JsonReadConfig = JsonReadConfig.defaults): T where T <: JsonCodecProvider {
        freezeYJsonRuntime()
        decodeFromStreamWith(jsonCodecOf<T>(), input, config: config)
    }

    public static func optionCodec<T>(inner: JsonCodec<T>): JsonCodec<Option<T>> {
        OptionJsonCodec(inner)
    }
    public static func stringOptionCodec(): JsonCodec<Option<String>> {
        StringOptionJsonCodec()
    }
    public static func arrayCodec<T>(inner: JsonCodec<T>): JsonCodec<Array<T>> {
        ArrayJsonCodec(inner)
    }
    public static func arrayListCodec<T>(inner: JsonCodec<T>): JsonCodec<ArrayList<T>> {
        ArrayListJsonCodec(inner)
    }
    public static func int64ArrayListCodec(): JsonCodec<ArrayList<Int64>> {
        Int64ArrayListJsonCodec()
    }
    public static func stringArrayListCodec(): JsonCodec<ArrayList<String>> {
        StringArrayListJsonCodec()
    }
    public static func hashMapCodec<T>(inner: JsonCodec<T>): JsonCodec<HashMap<String, T>> {
        HashMapJsonCodec(inner)
    }
    public static func int64HashMapCodec(): JsonCodec<HashMap<String, Int64>> {
        Int64HashMapJsonCodec()
    }
}

extend Bool <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(BoolJson)
    }
}

extend Int64 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Int64Json)
    }
}

extend Int32 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Int32Json)
    }
}

extend Int16 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Int16Json)
    }
}

extend Int8 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Int8Json)
    }
}

extend UInt64 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(UInt64Json)
    }
}

extend UInt32 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(UInt32Json)
    }
}

extend UInt16 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(UInt16Json)
    }
}

extend UInt8 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(UInt8Json)
    }
}

extend Float64 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Float64Json)
    }
}

extend Float32 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Float32Json)
    }
}

extend Float16 <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(Float16Json)
    }
}

extend String <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(StringJson)
    }
}

extend Rune <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(RuneJson)
    }
}

extend DateTime <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(DateTimeJson)
    }
}

extend BigInt <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(BigIntJson)
    }
}

extend Decimal <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(DecimalJson)
    }
}

extend<T> Option<T> <: JsonCodecProvider where T <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(YJson.optionCodec(jsonCodecOf<T>()))
    }
}

extend<T> Array<T> <: JsonCodecProvider where T <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(YJson.arrayCodec(jsonCodecOf<T>()))
    }
}

extend<T> ArrayList<T> <: JsonCodecProvider where T <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(YJson.arrayListCodec(jsonCodecOf<T>()))
    }
}

extend<T> HashMap<String, T> <: JsonCodecProvider where T <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(YJson.hashMapCodec(jsonCodecOf<T>()))
    }
}
