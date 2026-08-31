package yjson

import std.collection.*

const YJ_JSON_SCAN_OK: Int32 = 0
const YJ_JSON_SCAN_FALLBACK: Int32 = 1
const YJ_JSON_SCAN_CAPACITY: Int32 = 2
const YJ_JSON_SCAN_VALIDATE_STRINGS = 1u32
const YJSON_NATIVE_FLOAT_MAX_TOKEN_BYTES: Int64 = 256

const YJSON_NATIVE_MIN_SKIP_BYTES = 32
const YJSON_NATIVE_MIN_OBJECT_SCAN_BYTES = 1024
const YJSON_NATIVE_MIN_ARRAY_SCAN_BYTES = 240
const YJSON_NATIVE_MIN_DECODE_BYTES = 16
const YJSON_NATIVE_MIN_READER_DECODE_BYTES = 256
const YJSON_NATIVE_MIN_WRITER_ESCAPE_BYTES = 4096
const YJSON_NATIVE_MIN_WRITER_INT64_COUNT = 256
const YJSON_NATIVE_MIN_ARRAY_ELEMENT_COUNT = 16

// Cross-package seam used by the optional native package. The core package has
// no foreign declarations and continues to work when no backend is installed.
public interface JsonNativeScannerBackend {
    func simdCaps(): UInt32
    func skipValue(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32
    func scanObjectFields(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, fields: CPointer<UInt64>, fieldCap: Int64, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32
    func scanArrayElements(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, elements: CPointer<UInt64>, elementCap: Int64, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32
    func scanString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32
    func decodeString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, output: CPointer<UInt8>, outputCap: Int64, outEnd: CPointer<Int64>, outWritten: CPointer<Int64>, outError: CPointer<Int64>): Int32
}

// Separate additive seam for bulk numeric scanning. Keeping it independent
// avoids changing third-party implementations of the established scanner
// backend while allowing one FFI call to return many validated number tokens.
public interface JsonNativeNumericScannerBackend {
    func scanNumericArrayChunk(input: CPointer<UInt8>, len: Int64, start: Int64,
        flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64,
        outNext: CPointer<Int64>, outCount: CPointer<Int64>, outDone: CPointer<Int64>,
        outError: CPointer<Int64>): Int32
    func parseInt64Array(input: CPointer<UInt8>, len: Int64, start: Int64,
        values: CPointer<Int64>, valueCap: Int64, outEnd: CPointer<Int64>,
        outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32
}

public interface JsonNativeNumericTapeBackend {
    func scanNumericTape(input: CPointer<UInt8>, len: Int64, start: Int64, pageBytes: Int64,
        flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64,
        outNext: CPointer<Int64>, outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32
}

/// Optional scalar seam for numeric-heavy typed codecs. The portable package
/// never installs this backend; yjson_native provides a short, non-blocking
/// @FastNative implementation. A Float64 NaN return means that the backend
/// declined the token and the caller must use the semantic Cangjie parser.
public interface JsonNativeFloatParserBackend {
    func parseFloat64(input: CPointer<UInt8>, len: Int64, start: Int64, tokenLength: Int64): Float64
}

/// Writer-side primitive. It only transforms a single already accepted
/// Cangjie String into one quoted JSON token; separator/state/limits remain in
/// JsonDirectWriter.
public interface JsonNativeWriterBackend {
    func escapeString(input: CPointer<UInt8>, len: Int64, htmlSafe: Bool,
        output: CPointer<UInt8>, outputCap: Int64, outWritten: CPointer<Int64>): Int32
    func formatInt64Array(values: CPointer<Int64>, count: Int64,
        output: CPointer<UInt8>, outputCap: Int64, outputOffset: Int64,
        outWritten: CPointer<Int64>): Int32
}

/// Versioned internal product bundle consumed by yjson_native. Applications
/// configure it only through YJsonNativeAccel.initialize().
public interface JsonNativeAccelerationPrimitivesV1 <: JsonNativeScannerBackend &
    JsonNativeNumericScannerBackend & JsonNativeNumericTapeBackend & JsonNativeFloatParserBackend &
    JsonNativeWriterBackend {}

// Published once while the runtime initialization lock is held. Keeping the
// complete primitive table in one slot prevents partial installation and makes
// every hot-path lookup observe either Pure or the full Native bundle.
private var jsonNativeAccelerationPrimitives: Option<JsonNativeAccelerationPrimitivesV1> =
    None<JsonNativeAccelerationPrimitivesV1>

func jsonNativeFormatInt64ArrayInto(values: ArrayList<Int64>, output: Array<Byte>,
    outputOffset: Int64): Option<Int64> {
    if (values.size < YJSON_NATIVE_MIN_WRITER_INT64_COUNT) {
        return None<Int64>
    }
    let backend = match (jsonNativeAccelerationPrimitives) {
        case Some(item) => item
        case None => return None<Int64>
    }
    if (values.size > (Int64.Max - 1) / 21) {
        throw JsonException("JSON integer array is too large for native formatting",
            code: "acceleration_writer_failure")
    }
    let contiguous = values.toArray()
    let required = values.size * 21 + 1
    if (outputOffset < 0 || outputOffset > output.size ||
        required > output.size - outputOffset) {
        throw JsonException("Native JSON integer output buffer is too small",
            code: "acceleration_writer_failure")
    }
    let written = Array<Int64>(1, repeat: 0)
    unsafe {
        let valuesHandle = acquireArrayRawData(contiguous)
        let outputHandle = acquireArrayRawData(output)
        let writtenHandle = acquireArrayRawData(written)
        let status = backend.formatInt64Array(valuesHandle.pointer, contiguous.size,
            outputHandle.pointer, output.size, outputOffset, writtenHandle.pointer)
        releaseArrayRawData(writtenHandle)
        releaseArrayRawData(outputHandle)
        releaseArrayRawData(valuesHandle)
        if (status != YJ_JSON_SCAN_OK || written[0] < 2 || written[0] > output.size) {
            throw JsonException("Native JSON integer formatting failed",
                code: "acceleration_writer_failure")
        }
    }
    Some(written[0])
}

/// Installs the complete v1 primitive bundle atomically during runtime freeze.
public func activateJsonNativePrimitivesV1(backend: JsonNativeAccelerationPrimitivesV1): Unit {
    if (jsonNativeAccelerationPrimitives.isSome()) {
        throw IllegalStateException("JSON native acceleration is already installed")
    }
    jsonNativeAccelerationPrimitives = Some(backend)
}

func jsonNativeEscapedStringSize(value: String, htmlSafe: Bool): Option<Int64> {
    if (value.size < YJSON_NATIVE_MIN_WRITER_ESCAPE_BYTES) {
        return None<Int64>
    }
    if (jsonNativeAccelerationPrimitives.isNone()) {
        return None<Int64>
    }
    if (value.size > (Int64.Max - 2) / 6) {
        throw JsonException("JSON string is too large for native escaping",
            code: "acceleration_writer_failure")
    }
    Some(jsonEscapedStringLiteralSize(value, htmlSafe))
}

func jsonEscapedStringLiteralSize(value: String, htmlSafe: Bool): Int64 {
    var required: Int64 = 2
    unsafe {
        let bytes = value.rawData()
        for (byte in bytes) {
            if (byte >= 0x20u8 && byte != b'"' && byte != b'\\' &&
                (!htmlSafe || !jsonNativeWriterNeedsHtmlEscape(byte))) {
                required++
            } else if (byte == b'"' || byte == b'\\' || byte == b'\b' || byte == b'\f' ||
                byte == b'\n' || byte == b'\r' || byte == b'\t') {
                required += 2
            } else {
                required += 6
            }
        }
    }
    required
}

private func jsonNativeWriterNeedsHtmlEscape(value: Byte): Bool {
    value == b'<' || value == b'>' || value == b'&' || value == b'=' || value == b'\''
}

func jsonNativeEscapeString(value: String, htmlSafe: Bool,
    required: Int64): Option<Array<Byte>> {
    let backend = match (jsonNativeAccelerationPrimitives) {
        case Some(item) => item
        case None => return None<Array<Byte>>
    }
    let output = Array<Byte>(required, repeat: 0)
    let written = Array<Int64>(1, repeat: 0)
    unsafe {
        let input = value.rawData()
        let inputHandle = acquireArrayRawData(input)
        let outputHandle = acquireArrayRawData(output)
        let writtenHandle = acquireArrayRawData(written)
        let status = backend.escapeString(inputHandle.pointer, input.size, htmlSafe,
            outputHandle.pointer, output.size, writtenHandle.pointer)
        releaseArrayRawData(writtenHandle)
        releaseArrayRawData(outputHandle)
        releaseArrayRawData(inputHandle)
        if (status != YJ_JSON_SCAN_OK || written[0] != output.size) {
            throw JsonException("Native JSON string escaping failed",
                code: "acceleration_writer_failure")
        }
    }
    Some(output[0..written[0]])
}

func jsonNativeFloatParserAvailable(): Bool {
    jsonNativeAccelerationPrimitives.isSome()
}

func jsonNativeParseFloat64(reader: JsonFastReader): Option<Float64> {
    let tokenLength = reader.currentRawTokenSize()
    if (tokenLength <= 0 || tokenLength > YJSON_NATIVE_FLOAT_MAX_TOKEN_BYTES) {
        return None<Float64>
    }
    let backend = match (jsonNativeAccelerationPrimitives) {
        case Some(value) => value
        case None => return None<Float64>
    }
    let data = reader.currentRawTokenData()
    var result = Float64.NaN
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        result = backend.parseFloat64(dataHandle.pointer, data.size,
            reader.currentRawTokenStartOffset(), tokenLength)
        releaseArrayRawData(dataHandle)
    }
    if (result.isNaN()) { None<Float64> } else { Some(result) }
}

class JsonNativeNumericTape {
    private let words: Array<UInt64>
    private let next = Array<Int64>(1, repeat: 0)
    private let count = Array<Int64>(1, repeat: 0)
    private let error = Array<Int64>(1, repeat: -1)
    private var cursor: Int64 = 0
    private var filled: Int64 = 0
    private var scannedTo: Int64 = 0
    var calls: Int64 = 0
    var classifiedBytes: Int64 = 0
    var events: Int64 = 0
    var refillsBeforeExhaustion: Int64 = 0

    init(capacity: Int64) { words = Array<UInt64>(capacity * 4, repeat: 0u64) }

    func tokenAt(data: Array<Byte>, position: Int64, pageBytes: Int64): Option<(Int64, Int64, UInt64, UInt64)> {
        while (cursor < filled && Int64(words[cursor * 4]) < position) { cursor++ }
        if (cursor >= filled || Int64(words[cursor * 4]) != position) {
            if (cursor < filled) { refillsBeforeExhaustion++ }
            let backend = match (jsonNativeAccelerationPrimitives) {
                case Some(value) => value
                case None => return None<(Int64, Int64, UInt64, UInt64)>
            }
            let start = if (position > scannedTo) { position } else { scannedTo }
            unsafe {
                let dataHandle = acquireArrayRawData(data)
                let wordsHandle = acquireArrayRawData(words)
                let nextHandle = acquireArrayRawData(next)
                let countHandle = acquireArrayRawData(count)
                let errorHandle = acquireArrayRawData(error)
                let status = backend.scanNumericTape(dataHandle.pointer, data.size, start, pageBytes,
                    YJ_JSON_SCAN_VALIDATE_STRINGS, wordsHandle.pointer, words.size / 4,
                    nextHandle.pointer, countHandle.pointer, errorHandle.pointer)
                releaseArrayRawData(errorHandle); releaseArrayRawData(countHandle)
                releaseArrayRawData(nextHandle); releaseArrayRawData(wordsHandle); releaseArrayRawData(dataHandle)
                if (status != YJ_JSON_SCAN_OK) {
                    throw JsonException("Native numeric tape error at byte ${error[0]}", code: "parse_error")
                }
            }
            calls++; classifiedBytes += next[0] - start; events += count[0]
            scannedTo = next[0]; cursor = 0; filled = count[0]
            while (cursor < filled && Int64(words[cursor * 4]) < position) { cursor++ }
        }
        if (cursor < filled && Int64(words[cursor * 4]) == position) {
            let base = cursor * 4; cursor++
            return Some((Int64(words[base]), Int64(words[base + 1]), words[base + 2], words[base + 3]))
        }
        None<(Int64, Int64, UInt64, UInt64)>
    }

    func callCount(): Int64 { calls }
    func classifiedByteCount(): Int64 { classifiedBytes }
    func eventCount(): Int64 { events }
    func earlyRefillCount(): Int64 { refillsBeforeExhaustion }
}


class JsonNativeNumericChunk {
    let words: Array<UInt64>
    let count: Int64
    let next: Int64
    let done: Bool
    let fallback: Bool

    init(words: Array<UInt64>, count: Int64, next: Int64, done: Bool, fallback: Bool) {
        this.words = words; this.count = count; this.next = next
        this.done = done; this.fallback = fallback
    }
    func tokenStart(index: Int64): Int64 { Int64(words[index * 4]) }
    func tokenEnd(index: Int64): Int64 { Int64(words[index * 4 + 1]) }
    func magnitude(index: Int64): Int64 { Int64(words[index * 4 + 2]) }
    func flags(index: Int64): UInt64 { words[index * 4 + 3] }
}

class JsonNativeInt64Array {
    let values: Array<Int64>
    let count: Int64
    let end: Int64

    init(values: Array<Int64>, count: Int64, end: Int64) {
        this.values = values; this.count = count; this.end = end
    }
}

func jsonNativeParseInt64Array(data: Array<Byte>, start: Int64): Option<JsonNativeInt64Array> {
    let backend = match (jsonNativeAccelerationPrimitives) {
        case Some(value) => value
        case None => return None<JsonNativeInt64Array>
    }
    let capacity = (data.size - start + 1) / 2
    let values = Array<Int64>(capacity, repeat: 0)
    let end = Array<Int64>(1, repeat: 0)
    let count = Array<Int64>(1, repeat: 0)
    let error = Array<Int64>(1, repeat: -1)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let valuesHandle = acquireArrayRawData(values)
        let endHandle = acquireArrayRawData(end)
        let countHandle = acquireArrayRawData(count)
        let errorHandle = acquireArrayRawData(error)
        let status = backend.parseInt64Array(dataHandle.pointer, data.size, start,
            valuesHandle.pointer, values.size, endHandle.pointer, countHandle.pointer,
            errorHandle.pointer)
        releaseArrayRawData(errorHandle); releaseArrayRawData(countHandle)
        releaseArrayRawData(endHandle); releaseArrayRawData(valuesHandle)
        releaseArrayRawData(dataHandle)
        if (status == YJ_JSON_SCAN_OK && count[0] >= 0 && count[0] <= values.size) {
            return Some(JsonNativeInt64Array(values, count[0], end[0]))
        }
        if (status == YJ_JSON_SCAN_FALLBACK) { return None<JsonNativeInt64Array> }
        throw JsonException("Native JSON Int64 array conversion failed",
            code: "acceleration_reader_failure")
    }
}

func jsonNativeScanNumericArrayChunk(data: Array<Byte>, start: Int64,
    validateStrings: Bool, tokenCap: Int64): Option<JsonNativeNumericChunk> {
    let backend = match (jsonNativeAccelerationPrimitives) {
        case Some(value) => value
        case None => return None<JsonNativeNumericChunk>
    }
    let words = Array<UInt64>(tokenCap * 4, repeat: 0u64)
    let next = Array<Int64>(1, repeat: 0)
    let count = Array<Int64>(1, repeat: 0)
    let done = Array<Int64>(1, repeat: 0)
    let error = Array<Int64>(1, repeat: -1)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let wordsHandle = acquireArrayRawData(words)
        let nextHandle = acquireArrayRawData(next)
        let countHandle = acquireArrayRawData(count)
        let doneHandle = acquireArrayRawData(done)
        let errorHandle = acquireArrayRawData(error)
        let status = backend.scanNumericArrayChunk(dataHandle.pointer, data.size, start,
            nativeJsonScannerFlags(validateStrings), wordsHandle.pointer, tokenCap,
            nextHandle.pointer, countHandle.pointer, doneHandle.pointer, errorHandle.pointer)
        releaseArrayRawData(errorHandle); releaseArrayRawData(doneHandle)
        releaseArrayRawData(countHandle); releaseArrayRawData(nextHandle)
        releaseArrayRawData(wordsHandle); releaseArrayRawData(dataHandle)
        if (status == YJ_JSON_SCAN_OK || status == YJ_JSON_SCAN_FALLBACK) {
            return Some(JsonNativeNumericChunk(words, count[0], next[0], done[0] != 0,
                status == YJ_JSON_SCAN_FALLBACK))
        }
        throw JsonException("Native numeric scanner error at byte ${error[0]}", code: "parse_error")
    }
}

private func YJ_JSON_SimdCaps(): UInt32 {
    match (jsonNativeAccelerationPrimitives) {
        case Some(backend) => backend.simdCaps()
        case None => 0u32
    }
}

private func YJ_JSON_SkipValue(
    input: CPointer<UInt8>,
    len: Int64,
    start: Int64,
    flags: UInt32,
    outEnd: CPointer<Int64>,
    outError: CPointer<Int64>
): Int32 {
    match (jsonNativeAccelerationPrimitives) {
        case Some(backend) => backend.skipValue(input, len, start, flags, outEnd, outError)
        case None => YJ_JSON_SCAN_FALLBACK
    }
}

private func YJ_JSON_ScanString(
    input: CPointer<UInt8>,
    len: Int64,
    start: Int64,
    flags: UInt32,
    outEnd: CPointer<Int64>,
    outError: CPointer<Int64>
): Int32 {
    match (jsonNativeAccelerationPrimitives) {
        case Some(backend) => backend.scanString(input, len, start, flags, outEnd, outError)
        case None => YJ_JSON_SCAN_FALLBACK
    }
}

private func YJ_JSON_DecodeString(
    input: CPointer<UInt8>,
    len: Int64,
    start: Int64,
    flags: UInt32,
    output: CPointer<UInt8>,
    outputCap: Int64,
    outEnd: CPointer<Int64>,
    outWritten: CPointer<Int64>,
    outError: CPointer<Int64>
): Int32 {
    match (jsonNativeAccelerationPrimitives) {
        case Some(backend) => backend.decodeString(input, len, start, flags, output, outputCap, outEnd, outWritten, outError)
        case None => YJ_JSON_SCAN_FALLBACK
    }
}

private func nativeJsonScannerFlags(validateStrings: Bool): UInt32 {
    if (validateStrings) {
        return YJ_JSON_SCAN_VALIDATE_STRINGS
    }
    0u32
}

private func nativeJsonScannerAvailable(): Bool {
    unsafe {
        (YJ_JSON_SimdCaps() & 1u32) != 0u32
    }
}

class JsonNativeDecodedString {
    let value: String
    let end: Int64

    init(value: String, end: Int64) {
        this.value = value
        this.end = end
    }
}

func jsonNativeScanString(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool
): Int64 {
    if (!nativeJsonScannerAvailable()) {
        return -1
    }
    let end = Array<Int64>(1, repeat: 0)
    let error = Array<Int64>(1, repeat: 0)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let endHandle = acquireArrayRawData(end)
        let errorHandle = acquireArrayRawData(error)
        let status = YJ_JSON_ScanString(
            dataHandle.pointer,
            size,
            start,
            nativeJsonScannerFlags(validateStrings),
            endHandle.pointer,
            errorHandle.pointer
        )
        releaseArrayRawData(errorHandle)
        releaseArrayRawData(endHandle)
        releaseArrayRawData(dataHandle)
        if (status == YJ_JSON_SCAN_OK) {
            return end[0]
        }
        if (status == YJ_JSON_SCAN_FALLBACK) {
            return -1
        }
        throw JsonException("Native JSON scanner error at byte ${error[0]}")
    }
}

func jsonNativeDecodeString(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool
): Option<JsonNativeDecodedString> {
    if (!nativeJsonScannerAvailable() || size - start < YJSON_NATIVE_MIN_DECODE_BYTES) {
        return None<JsonNativeDecodedString>
    }
    let stringEnd = jsonNativeScanString(data, size, start, validateStrings)
    if (stringEnd <= start) {
        return None<JsonNativeDecodedString>
    }
    let output = Array<Byte>(stringEnd - start - 1, repeat: 0)
    let end = Array<Int64>(1, repeat: 0)
    let written = Array<Int64>(1, repeat: 0)
    let error = Array<Int64>(1, repeat: 0)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let outputHandle = acquireArrayRawData(output)
        let endHandle = acquireArrayRawData(end)
        let writtenHandle = acquireArrayRawData(written)
        let errorHandle = acquireArrayRawData(error)
        let status = YJ_JSON_DecodeString(
            dataHandle.pointer,
            size,
            start,
            nativeJsonScannerFlags(validateStrings),
            outputHandle.pointer,
            output.size,
            endHandle.pointer,
            writtenHandle.pointer,
            errorHandle.pointer
        )
        releaseArrayRawData(errorHandle)
        releaseArrayRawData(writtenHandle)
        releaseArrayRawData(endHandle)
        releaseArrayRawData(outputHandle)
        releaseArrayRawData(dataHandle)
        if (status == YJ_JSON_SCAN_OK) {
            return Some(JsonNativeDecodedString(String.fromUtf8Unchecked(output[0..written[0]]), end[0]))
        }
        if (status == YJ_JSON_SCAN_FALLBACK || status == YJ_JSON_SCAN_CAPACITY) {
            return None<JsonNativeDecodedString>
        }
        throw JsonException("Native JSON scanner error at byte ${error[0]}")
    }
}

func jsonNativeSkipValue(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool
): Int64 {
    if (!nativeJsonScannerAvailable()) {
        return -1
    }
    let end = Array<Int64>(1, repeat: 0)
    let error = Array<Int64>(1, repeat: 0)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let endHandle = acquireArrayRawData(end)
        let errorHandle = acquireArrayRawData(error)
        let status = YJ_JSON_SkipValue(
            dataHandle.pointer,
            size,
            start,
            nativeJsonScannerFlags(validateStrings),
            endHandle.pointer,
            errorHandle.pointer
        )
        releaseArrayRawData(errorHandle)
        releaseArrayRawData(endHandle)
        releaseArrayRawData(dataHandle)
        if (status == YJ_JSON_SCAN_OK) {
            return end[0]
        }
        if (status == YJ_JSON_SCAN_FALLBACK) {
            return -1
        }
        throw JsonException("Native JSON scanner error at byte ${error[0]}")
    }
}
