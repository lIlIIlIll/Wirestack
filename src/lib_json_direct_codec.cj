package yjson

import std.collection.*
import std.io.*
import std.math.numeric.*
import std.time.*

public interface JsonDirectCodec<T> {
    func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit

    func read(reader: JsonDirectReader, context: JsonDecodeContext): T
}

public interface JsonObjectCodec<T> <: JsonDirectCodec<T> {
    func writeObjectFields(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit
}

public interface JsonAnyCodec {
    func writeAny(value: Any, writer: JsonDirectWriter, context: JsonEncodeContext): Unit

    func readAny(reader: JsonDirectReader, context: JsonDecodeContext): Any

    func readAnyFast(reader: JsonFastReader, context: JsonDecodeContext): Any
}

public interface JsonCodecProvider {
    static func jsonCodec(): JsonAnyCodec
}

private class ErasedJsonCodec<T> <: JsonAnyCodec {
    private let codec: JsonDirectCodec<T>

    public init(codec: JsonDirectCodec<T>) {
        this.codec = codec
    }

    public func writeAny(value: Any, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        match (value) {
            case typed: T => codec.write(typed, writer, context)
            case _ => throw JsonException("Codec value type mismatch", code: "codec_type_mismatch",
                path: context.currentPath())
        }
    }

    public func readAny(reader: JsonDirectReader, context: JsonDecodeContext): Any {
        codec.read(reader, context)
    }

    public func readAnyFast(reader: JsonFastReader, context: JsonDecodeContext): Any {
        match (codec) {
            case fast: JsonArrayDirectCodec<T> => fast.readFast(reader, context)
            case _ => throw JsonException("Codec does not provide a fast-reader implementation", code: "codec_contract",
                path: context.currentPath())
        }
    }

    func typedCodec(): JsonDirectCodec<T> {
        codec
    }
}

private class ReifiedJsonCodec<T> <: JsonDirectCodec<T> {
    private let codec: JsonAnyCodec

    public init(codec: JsonAnyCodec) {
        this.codec = codec
    }

    public func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        codec.writeAny(value, writer, context)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): T {
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

public func eraseJsonCodec<T>(codec: JsonDirectCodec<T>): JsonAnyCodec {
    ErasedJsonCodec(codec)
}

public func jsonCodecOf<T>(): JsonDirectCodec<T> where T <: JsonCodecProvider {
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
public interface JsonArrayDirectCodec<T> <: JsonDirectCodec<T> {
    func readFast(reader: JsonFastReader, context: JsonDecodeContext): T
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

public interface JsonArrayListDirectCodec<T> <: JsonArrayDirectCodec<T> {
    func readFastArrayList(reader: JsonFastReader, context: JsonDecodeContext): ArrayList<T>
}

interface JsonRawWriteCodec<T> <: JsonDirectCodec<T> {
    func writeRaw(value: T, writer: JsonDirectWriter): Unit
}

interface JsonArrayListRawWriteCodec<T> <: JsonArrayListDirectCodec<T> {
    func writeRawArrayList(value: ArrayList<T>, writer: JsonDirectWriter): Unit
}

public class JsonEncodeContext {
    private let maxDepth: Int64
    private var depth: Int64 = 0
    private let path = ArrayList<String>()
    private var pathIndexPairs: Option<ArrayList<Int64>> = None<ArrayList<Int64>>

    public init(config: JsonWriteConfig) {
        maxDepth = config.maxDepth
    }

    public func pushField(name: String): Unit {
        path.add(name)
    }

    public func pushIndex(index: Int64): Unit {
        let pairs = match (pathIndexPairs) {
            case Some(value) => value
            case None =>
                let value = ArrayList<Int64>()
                pathIndexPairs = Some(value)
                value
        }
        pairs.add(path.size)
        pairs.add(index)
        path.add("")
    }

    public func popPath(): Unit {
        if (!path.isEmpty()) {
            let position = path.size - 1
            if (let Some(pairs) <- pathIndexPairs) {
                if (!pairs.isEmpty() && pairs[pairs.size - 2] == position) {
                    pairs.remove(at: pairs.size - 1)
                    pairs.remove(at: pairs.size - 1)
                }
            }
            path.remove(at: path.size - 1)
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
        let result = StringBuilder("$")
        let pairs = pathIndexPairs.getOrDefault({=> ArrayList<Int64>()})
        var pairCursor: Int64 = 0
        for (position in 0..path.size) {
            if (pairCursor < pairs.size && pairs[pairCursor] == position) {
                result.append("[")
                result.append(pairs[pairCursor + 1].toString())
                result.append("]")
                pairCursor += 2
            } else {
                result.append(".")
                result.append(path[position])
            }
        }
        result.toString()
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
class LambdaJsonDirectCodec<T> <: JsonDirectCodec<T> {
    private let writerFn: (T, JsonDirectWriter) -> Unit
    private let readerFn: (JsonDirectReader) -> T

    public init(writerFn: (T, JsonDirectWriter) -> Unit, readerFn: (JsonDirectReader) -> T) {
        this.writerFn = writerFn
        this.readerFn = readerFn
    }

    public func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writerFn(value, writer)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): T {
        let _ = context
        readerFn(reader)
    }
}

class LambdaYJsonDirectCodec<T> <: JsonArrayDirectCodec<T> {
    private let writerFn: (T, JsonDirectWriter) -> Unit
    private let readerFn: (JsonDirectReader) -> T
    private let fastReaderFn: (JsonFastReader) -> T

    public init(
        writerFn: (T, JsonDirectWriter) -> Unit,
        readerFn: (JsonDirectReader) -> T,
        fastReaderFn: (JsonFastReader) -> T
    ) {
        this.writerFn = writerFn
        this.readerFn = readerFn
        this.fastReaderFn = fastReaderFn
    }

    public func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writerFn(value, writer)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): T {
        let _ = context
        readerFn(reader)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        let _ = context
        fastReaderFn(reader)
    }
}

class LambdaFastRawJsonDirectCodec<T> <: JsonArrayDirectCodec<T> & JsonRawWriteCodec<T> {
    private let writerFn: (T, JsonDirectWriter) -> Unit
    private let readerFn: (JsonDirectReader) -> T
    private let fastReaderFn: (JsonFastReader) -> T
    private let rawWriterFn: (T, JsonDirectWriter) -> Unit

    public init(
        writerFn: (T, JsonDirectWriter) -> Unit,
        readerFn: (JsonDirectReader) -> T,
        fastReaderFn: (JsonFastReader) -> T,
        rawWriterFn: (T, JsonDirectWriter) -> Unit
    ) {
        this.writerFn = writerFn
        this.readerFn = readerFn
        this.fastReaderFn = fastReaderFn
        this.rawWriterFn = rawWriterFn
    }

    public func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        let _ = context
        if (writer.canWriteRawCompactValue()) {
            rawWriterFn(value, writer)
        } else {
            writerFn(value, writer)
        }
    }

    public func writeRaw(value: T, writer: JsonDirectWriter): Unit {
        rawWriterFn(value, writer)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): T {
        let _ = context
        readerFn(reader)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        let _ = context
        fastReaderFn(reader)
    }
}

public func readJsonFastWith<T>(codec: JsonDirectCodec<T>, reader: JsonFastReader, context: JsonDecodeContext): T {
    match (codec) {
        case reified: ReifiedJsonCodec<T> => reified.readFast(reader, context)
        case fast: JsonArrayDirectCodec<T> => fast.readFast(reader, context)
        case _ => throw JsonException("Codec does not provide a fast-reader implementation", code: "codec_contract",
            path: context.currentPath())
    }
}

private class ReifiedFastCodecAdapter<T> <: JsonArrayDirectCodec<T> {
    private let inner: ReifiedJsonCodec<T>

    public init(inner: ReifiedJsonCodec<T>) {
        this.inner = inner
    }

    public func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        inner.write(value, writer, context)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): T {
        inner.read(reader, context)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        inner.readFast(reader, context)
    }
}

private class ContractFastCodecAdapter<T> <: JsonArrayDirectCodec<T> {
    private let inner: JsonDirectCodec<T>

    public init(inner: JsonDirectCodec<T>) {
        this.inner = inner
    }

    public func write(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        inner.write(value, writer, context)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): T {
        inner.read(reader, context)
    }

    public func readFast(reader: JsonFastReader, context: JsonDecodeContext): T {
        readJsonFastWith(inner, reader, context)
    }
}

private func resolvedJsonFastCodec<T>(codec: JsonDirectCodec<T>): JsonArrayDirectCodec<T> {
    match (codec) {
        case reified: ReifiedJsonCodec<T> => ReifiedFastCodecAdapter<T>(reified)
        case fast: JsonArrayDirectCodec<T> => fast
        case _ => ContractFastCodecAdapter<T>(codec)
    }
}

private class OptionJsonCodec<T> <: JsonArrayDirectCodec<Option<T>> {
    private let inner: JsonDirectCodec<T>

    public init(inner: JsonDirectCodec<T>) {
        this.inner = inner
    }

    public func write(value: Option<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        match (value) {
            case Some(item) => inner.write(item, writer, context)
            case None => writer.writeNull()
        }
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): Option<T> {
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

private class StringOptionJsonCodec <: JsonArrayDirectCodec<Option<String>> {
    public func write(value: Option<String>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        let _ = context
        match (value) {
            case Some(item) => writer.writeString(item)
            case None => writer.writeNull()
        }
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): Option<String> {
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

private class ArrayJsonCodec<T> <: JsonArrayDirectCodec<Array<T>> {
    private let inner: JsonDirectCodec<T>
    private let fastInner: JsonArrayDirectCodec<T>

    public init(inner: JsonDirectCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedJsonFastCodec(inner)
    }

    public func write(value: Array<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            writer.startArray()
            for (index in 0..value.size) {
                context.pushIndex(index)
                try {
                    inner.write(value[index], writer, context)
                } finally {
                    context.popPath()
                }
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): Array<T> {
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

private class ArrayListJsonCodec<T> <: JsonArrayDirectCodec<ArrayList<T>> {
    private let inner: JsonDirectCodec<T>
    private let fastInner: JsonArrayDirectCodec<T>

    public init(inner: JsonDirectCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedJsonFastCodec(inner)
    }

    public func write(value: ArrayList<T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            writer.startArray()
            var index: Int64 = 0
            for (item in value) {
                context.pushIndex(index)
                try {
                    inner.write(item, writer, context)
                } finally {
                    context.popPath()
                }
                index++
            }
            writer.endArray()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): ArrayList<T> {
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

private class Int64ArrayListJsonCodec <: JsonArrayDirectCodec<ArrayList<Int64>> {
    public func write(value: ArrayList<Int64>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            if (writer.tryWriteCompactInt64ArrayList(value)) {
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
    public func read(reader: JsonDirectReader, context: JsonDecodeContext): ArrayList<Int64> {
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

private class StringArrayListJsonCodec <: JsonArrayDirectCodec<ArrayList<String>> {
    public func write(value: ArrayList<String>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            if (writer.tryWriteCompactStringArrayList(value)) {
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

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): ArrayList<String> {
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
public func __yJsonWriteStringArrayList(value: ArrayList<String>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
    context.enterValue()
    try {
        if (writer.tryWriteCompactStringArrayList(value)) {
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

public func __yJsonReadStringArrayList(reader: JsonDirectReader, context: JsonDecodeContext): ArrayList<String> {
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

public func __yJsonWriteStringOption(value: Option<String>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
    let _ = context
    match (value) {
        case Some(item) => writer.writeString(item);
        case None => writer.writeNull()
    }
}

public func __yJsonReadStringOption(reader: JsonDirectReader, context: JsonDecodeContext): Option<String> {
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

private class HashMapJsonCodec<T> <: JsonArrayDirectCodec<HashMap<String, T>> {
    private let inner: JsonDirectCodec<T>
    private let fastInner: JsonArrayDirectCodec<T>
    private let rawInner: Option<JsonRawWriteCodec<T>>

    public init(inner: JsonDirectCodec<T>) {
        this.inner = inner
        this.fastInner = resolvedJsonFastCodec(inner)
        this.rawInner = match (inner) {
            case raw: JsonRawWriteCodec<T> => Some(raw)
            case _ => None<JsonRawWriteCodec<T>>
        }
    }

    public func write(value: HashMap<String, T>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            if (let Some(raw) <- rawInner) {
                if (writer.tryWriteCompactRawMap(value, raw)) {
                    return
                }
            }
            writer.startObject()
            for ((name, item) in value) {
                writer.writeName(name)
                context.pushField(name)
                try {
                    inner.write(item, writer, context)
                } finally {
                    context.popPath()
                }
            }
            writer.endObject()
        } finally {
            context.leaveValue()
        }
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): HashMap<String, T> {
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

private class Int64HashMapJsonCodec <: JsonArrayDirectCodec<HashMap<String, Int64>> {
    public func write(value: HashMap<String, Int64>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        context.enterValue()
        try {
            if (writer.tryWriteCompactInt64Map(value)) {
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

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): HashMap<String, Int64> {
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

public func __yJsonWriteInt64HashMap(value: HashMap<String, Int64>, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
    context.enterValue()
    try {
        if (writer.tryWriteCompactInt64Map(value)) {
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

public func __yJsonReadInt64HashMap(reader: JsonDirectReader, context: JsonDecodeContext): HashMap<String, Int64> {
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

private func remainingJsonInputBytes(input: InputStream): Option<Array<Byte>> {
    match (input) {
        case byteInput: YJsonByteArrayInputStream => Some(byteInput.readRemainingBytes())
        case _ => None<Array<Byte>>
    }
}

public class YJson {
    public static func parse(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
        JsonNode.parse(text, config: config)
    }

    public static func parse(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
        JsonNode.parse(bytes, config: config)
    }

    /// Parses a read-only document using one explicit backend. The portable
    /// Pure Compact backend remains the default and does not enable Native code.
    public static func parseDocument(text: String,
        backend!: JsonDocumentBackend = PureCompactBackend,
        config!: JsonReadConfig = JsonReadConfig.defaults): JsonDocument {
        backend.parse(unsafe { text.rawData() }, config)
    }

    /// Parses raw UTF-8 into the unified read-only document facade.
    public static func parseDocument(bytes: Array<Byte>,
        backend!: JsonDocumentBackend = PureCompactBackend,
        config!: JsonReadConfig = JsonReadConfig.defaults): JsonDocument {
        backend.parse(bytes, config)
    }

    public static func stringify(value: JsonNode, config!: JsonWriteConfig = JsonWriteConfig.compact): String {
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

    public static func writeValue(value: JsonNode, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writeJsonValueDirect(writer, value)
    }

    public static func writeValue<T>(value: T, writer: JsonDirectWriter, context: JsonEncodeContext): Unit where T <: JsonCodecProvider {
        jsonCodecOf<T>().write(value, writer, context)
    }

    public static func toJson<T>(value: T, config!: JsonWriteConfig = JsonWriteConfig.compact): String where T <: JsonCodecProvider {
        encodeStringWith(jsonCodecOf<T>(), value, config: config)
    }

    public static func fromJson<T>(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): T where T <: JsonCodecProvider {
        decodeStringWith(jsonCodecOf<T>(), text, config: config)
    }

    public static func encodeWith<T>(codec: JsonDirectCodec<T>, value: T,
        config!: JsonCodecConfig = JsonCodecConfig.compact): JsonNode {
        parse(encodeStringWith(codec, value, config: config.write), config: config.read)
    }

    public static func decodeWith<T>(codec: JsonDirectCodec<T>, value: JsonNode,
        config!: JsonCodecConfig = JsonCodecConfig.compact): T {
        decodeStringWith(codec, stringify(value, config: config.write), config: config.read)
    }

    /// Resolves a codec's fast-reader contract once for repeated typed decode.
    public static func fastDecoder<T>(codec: JsonDirectCodec<T>): JsonFastDecoder<T> {
        match (codec) {
            case fast: JsonFastDecoder<T> => fast
            case _ => throw JsonException(
                "Codec does not provide a fast-reader implementation",
                code: "codec_contract",
                path: "$"
            )
        }
    }

    public static func encodeStringWith<T>(codec: JsonDirectCodec<T>, value: T,
        config!: JsonWriteConfig = JsonWriteConfig.compact): String {
        let writer = JsonDirectWriter(config)
        codec.write(value, writer, JsonEncodeContext(config))
        writer.finishString()
    }

    public static func encodeBytesWith<T>(codec: JsonDirectCodec<T>, value: T,
        config!: JsonWriteConfig = JsonWriteConfig.compact): Array<Byte> {
        let writer = JsonDirectWriter.bytes(config: config)
        codec.write(value, writer, JsonEncodeContext(config))
        writer.finishBytes()
    }

    public static func decodeStringWith<T>(codec: JsonDirectCodec<T>, text: String,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        if (jsonReadConfigUsesDefaultFastPath(config)) {
            match (codec) {
                case fast: JsonArrayDirectCodec<T> =>
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

    public static func decodeBytesWith<T>(codec: JsonDirectCodec<T>, bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        if (jsonReadConfigUsesDefaultFastPath(config)) {
            match (codec) {
                case fast: JsonArrayDirectCodec<T> =>
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

    public static func encodeToStreamWith<T>(codec: JsonDirectCodec<T>, value: T, out: OutputStream,
        config!: JsonWriteConfig = JsonWriteConfig.compact): Unit {
        let writer = JsonDirectWriter(out, config: config)
        codec.write(value, writer, JsonEncodeContext(config))
        writer.finish()
    }

    public static func decodeFromStreamWith<T>(codec: JsonDirectCodec<T>, input: InputStream,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        if (jsonReadConfigUsesDefaultFastPath(config)) {
            if (let Some(bytes) <- remainingJsonInputBytes(input)) {
                return decodeBytesWith(codec, bytes, config: config)
            }
        }
        let reader = JsonDirectReader(input, config: config)
        let result = codec.read(reader, JsonDecodeContext(config))
        reader.expectEnd()
        result
    }

    /// Memory-backed stream overload. It consumes only the unread bytes and
    /// preserves the public stream API while selecting the byte-native reader.
    public static func decodeFromStreamWith<T>(codec: JsonDirectCodec<T>, input: YJsonByteArrayInputStream,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        decodeBytesWith(codec, input.readRemainingBytes(), config: config)
    }

    public static func optionCodec<T>(inner: JsonDirectCodec<T>): JsonDirectCodec<Option<T>> {
        OptionJsonCodec(inner)
    }
    public static func stringOptionCodec(): JsonDirectCodec<Option<String>> {
        StringOptionJsonCodec()
    }
    public static func arrayCodec<T>(inner: JsonDirectCodec<T>): JsonDirectCodec<Array<T>> {
        ArrayJsonCodec(inner)
    }
    public static func arrayListCodec<T>(inner: JsonDirectCodec<T>): JsonDirectCodec<ArrayList<T>> {
        ArrayListJsonCodec(inner)
    }
    public static func int64ArrayListCodec(): JsonDirectCodec<ArrayList<Int64>> {
        Int64ArrayListJsonCodec()
    }
    public static func stringArrayListCodec(): JsonDirectCodec<ArrayList<String>> {
        StringArrayListJsonCodec()
    }
    public static func hashMapCodec<T>(inner: JsonDirectCodec<T>): JsonDirectCodec<HashMap<String, T>> {
        HashMapJsonCodec(inner)
    }
    public static func int64HashMapCodec(): JsonDirectCodec<HashMap<String, Int64>> {
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
