package yjson


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
const YJSON_NATIVE_MIN_WRITER_ESCAPE_BYTES = 64
const YJSON_NATIVE_MIN_ARRAY_ELEMENT_COUNT = 16
const YJSON_NATIVE_OBJECT_FIELD_CAP = 64
const YJSON_NATIVE_OBJECT_FIELD_WORDS = 5
const YJSON_NATIVE_ARRAY_INITIAL_ELEMENT_CAP = 16
const YJSON_NATIVE_ARRAY_ELEMENT_CAP = 512

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
}

/// Versioned internal product bundle consumed by yjson_native. Applications
/// configure it only through YJsonNativeAccel.initialize().
public interface JsonNativeAccelerationPrimitivesV1 <: JsonNativeScannerBackend &
    JsonNativeNumericScannerBackend & JsonNativeNumericTapeBackend & JsonNativeFloatParserBackend &
    JsonNativeWriterBackend {}

private var jsonNativeScannerBackend: Option<JsonNativeScannerBackend> = None<JsonNativeScannerBackend>
private var jsonNativeNumericScannerBackend: Option<JsonNativeNumericScannerBackend> =
    None<JsonNativeNumericScannerBackend>
private var jsonNativeNumericTapeBackend: Option<JsonNativeNumericTapeBackend> =
    None<JsonNativeNumericTapeBackend>
private var jsonNativeFloatParserBackend: Option<JsonNativeFloatParserBackend> =
    None<JsonNativeFloatParserBackend>
private var jsonNativeWriterBackend: Option<JsonNativeWriterBackend> = None<JsonNativeWriterBackend>

private func installJsonNativeScannerBackend(backend: JsonNativeScannerBackend): Unit {
    if (jsonNativeScannerBackend.isSome()) {
        throw IllegalStateException("A JSON native scanner backend is already installed")
    }
    jsonNativeScannerBackend = Some(backend)
}

private func installJsonNativeNumericScannerBackend(backend: JsonNativeNumericScannerBackend): Unit {
    if (jsonNativeNumericScannerBackend.isSome()) {
        throw IllegalStateException("A JSON native numeric scanner backend is already installed")
    }
    jsonNativeNumericScannerBackend = Some(backend)
}

private func installJsonNativeNumericTapeBackend(backend: JsonNativeNumericTapeBackend): Unit {
    jsonNativeNumericTapeBackend = Some(backend)
}

/// Installs one process-global Float64 parser backend. Install before any
/// concurrent decoding and do not mix this low-level hook with another owner.
private func installJsonNativeFloatParserBackend(backend: JsonNativeFloatParserBackend): Unit {
    if (jsonNativeFloatParserBackend.isSome()) {
        throw IllegalStateException("A JSON native float parser backend is already installed")
    }
    jsonNativeFloatParserBackend = Some(backend)
}

/// Installs the complete v1 primitive bundle atomically during runtime freeze.
public func activateJsonNativePrimitivesV1(backend: JsonNativeAccelerationPrimitivesV1): Unit {
    if (jsonNativeScannerBackend.isSome() || jsonNativeNumericScannerBackend.isSome() ||
        jsonNativeNumericTapeBackend.isSome() || jsonNativeFloatParserBackend.isSome() ||
        jsonNativeWriterBackend.isSome()) {
        throw IllegalStateException("JSON native acceleration is already installed")
    }
    installJsonNativeScannerBackend(backend)
    installJsonNativeNumericScannerBackend(backend)
    installJsonNativeNumericTapeBackend(backend)
    installJsonNativeFloatParserBackend(backend)
    jsonNativeWriterBackend = Some(backend)
}

func jsonNativeEscapeString(value: String, htmlSafe: Bool): Option<Array<Byte>> {
    if (value.size < YJSON_NATIVE_MIN_WRITER_ESCAPE_BYTES) {
        return None<Array<Byte>>
    }
    let backend = match (jsonNativeWriterBackend) {
        case Some(item) => item
        case None => return None<Array<Byte>>
    }
    if (value.size > (Int64.Max - 2) / 6) {
        throw JsonAccelerationException("JSON string is too large for native escaping",
            code: "acceleration_writer_failure")
    }
    let output = Array<Byte>(value.size * 6 + 2, repeat: 0)
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
        if (status != YJ_JSON_SCAN_OK || written[0] < 2 || written[0] > output.size) {
            throw JsonAccelerationException("Native JSON string escaping failed",
                code: "acceleration_writer_failure")
        }
    }
    Some(output[0..written[0]])
}

func jsonNativeFloatParserAvailable(): Bool {
    jsonNativeFloatParserBackend.isSome()
}

func jsonNativeParseFloat64(reader: JsonFastReader): Option<Float64> {
    let tokenLength = reader.currentRawTokenSize()
    if (tokenLength <= 0 || tokenLength > YJSON_NATIVE_FLOAT_MAX_TOKEN_BYTES) {
        return None<Float64>
    }
    let backend = match (jsonNativeFloatParserBackend) {
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
            let backend = match (jsonNativeNumericTapeBackend) {
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

func jsonNativeScanNumericArrayChunk(data: Array<Byte>, start: Int64,
    validateStrings: Bool, tokenCap: Int64): Option<JsonNativeNumericChunk> {
    let backend = match (jsonNativeNumericScannerBackend) {
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
    match (jsonNativeScannerBackend) {
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
    match (jsonNativeScannerBackend) {
        case Some(backend) => backend.skipValue(input, len, start, flags, outEnd, outError)
        case None => YJ_JSON_SCAN_FALLBACK
    }
}

private func YJ_JSON_ScanObjectFields(
    input: CPointer<UInt8>,
    len: Int64,
    start: Int64,
    flags: UInt32,
    fields: CPointer<UInt64>,
    fieldCap: Int64,
    outEnd: CPointer<Int64>,
    outError: CPointer<Int64>
): Int32 {
    match (jsonNativeScannerBackend) {
        case Some(backend) => backend.scanObjectFields(input, len, start, flags, fields, fieldCap, outEnd, outError)
        case None => YJ_JSON_SCAN_FALLBACK
    }
}

private func YJ_JSON_ScanArrayElements(
    input: CPointer<UInt8>,
    len: Int64,
    start: Int64,
    flags: UInt32,
    elements: CPointer<UInt64>,
    elementCap: Int64,
    outEnd: CPointer<Int64>,
    outError: CPointer<Int64>
): Int32 {
    match (jsonNativeScannerBackend) {
        case Some(backend) => backend.scanArrayElements(input, len, start, flags, elements, elementCap, outEnd, outError)
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
    match (jsonNativeScannerBackend) {
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
    match (jsonNativeScannerBackend) {
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

class JsonNativeObjectFields {
    private let data: Array<Byte>
    private let words: Array<UInt64>
    private let count: Int64
    let objectEnd: Int64
    private var cursor: Int64 = 0

    init(data: Array<Byte>, words: Array<UInt64>, count: Int64, objectEnd: Int64) {
        this.data = data
        this.words = words
        this.count = count
        this.objectEnd = objectEnd
    }

    func hasCurrent(): Bool {
        cursor < count
    }

    func advance(): Unit {
        cursor++
    }

    func currentValueStart(): Int64 {
        Int64(words[cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS + 3])
    }

    func currentValueEnd(): Int64 {
        Int64(words[cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS + 4])
    }

    func currentNameSize(): Int64 {
        Int64(words[cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS + 1])
    }

    func currentNameByte(offset: Int64): Byte {
        let nameStart = Int64(words[cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS])
        data[nameStart + offset]
    }

    func currentNameEqualsAscii3(b0: Byte, b1: Byte, b2: Byte): Bool {
        let base = cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS
        let nameStart = Int64(words[base])
        Int64(words[base + 1]) == 3 &&
            data[nameStart] == b0 &&
            data[nameStart + 1] == b1 &&
            data[nameStart + 2] == b2
    }

    func currentNameEqualsAscii4(b0: Byte, b1: Byte, b2: Byte, b3: Byte): Bool {
        let base = cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS
        let nameStart = Int64(words[base])
        Int64(words[base + 1]) == 4 &&
            data[nameStart] == b0 &&
            data[nameStart + 1] == b1 &&
            data[nameStart + 2] == b2 &&
            data[nameStart + 3] == b3
    }

    func currentNameEqualsAscii6(b0: Byte, b1: Byte, b2: Byte, b3: Byte, b4: Byte, b5: Byte): Bool {
        let base = cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS
        let nameStart = Int64(words[base])
        Int64(words[base + 1]) == 6 &&
            data[nameStart] == b0 &&
            data[nameStart + 1] == b1 &&
            data[nameStart + 2] == b2 &&
            data[nameStart + 3] == b3 &&
            data[nameStart + 4] == b4 &&
            data[nameStart + 5] == b5
    }

    func currentNameEqualsAscii7(
        b0: Byte,
        b1: Byte,
        b2: Byte,
        b3: Byte,
        b4: Byte,
        b5: Byte,
        b6: Byte
    ): Bool {
        let base = cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS
        let nameStart = Int64(words[base])
        Int64(words[base + 1]) == 7 &&
            data[nameStart] == b0 &&
            data[nameStart + 1] == b1 &&
            data[nameStart + 2] == b2 &&
            data[nameStart + 3] == b3 &&
            data[nameStart + 4] == b4 &&
            data[nameStart + 5] == b5 &&
            data[nameStart + 6] == b6
    }

    func currentNameEqualsAscii11(
        b0: Byte,
        b1: Byte,
        b2: Byte,
        b3: Byte,
        b4: Byte,
        b5: Byte,
        b6: Byte,
        b7: Byte,
        b8: Byte,
        b9: Byte,
        b10: Byte
    ): Bool {
        let base = cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS
        let nameStart = Int64(words[base])
        Int64(words[base + 1]) == 11 &&
            data[nameStart] == b0 &&
            data[nameStart + 1] == b1 &&
            data[nameStart + 2] == b2 &&
            data[nameStart + 3] == b3 &&
            data[nameStart + 4] == b4 &&
            data[nameStart + 5] == b5 &&
            data[nameStart + 6] == b6 &&
            data[nameStart + 7] == b7 &&
            data[nameStart + 8] == b8 &&
            data[nameStart + 9] == b9 &&
            data[nameStart + 10] == b10
    }

    func currentNameEqualsBytes(nameBytes: Array<Byte>): Bool {
        let nameStart = Int64(words[cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS])
        let nameSize = Int64(words[cursor * YJSON_NATIVE_OBJECT_FIELD_WORDS + 1])
        if (nameBytes.size != nameSize) {
            return false
        }
        for (offset in 0..nameSize) {
            if (data[nameStart + offset] != nameBytes[offset]) {
                return false
            }
        }
        true
    }
}

class JsonNativeArrayElements {
    private let words: Array<UInt64>
    private let count: Int64
    let arrayEnd: Int64
    private var cursor: Int64 = 0

    init(words: Array<UInt64>, count: Int64, arrayEnd: Int64) {
        this.words = words
        this.count = count
        this.arrayEnd = arrayEnd
    }

    func elementCount(): Int64 {
        count
    }

    func hasCurrent(): Bool {
        cursor < count
    }

    func advance(): Unit {
        cursor++
    }

    func currentValueStart(): Int64 {
        Int64(words[cursor * 2])
    }

    func currentValueEnd(): Int64 {
        Int64(words[cursor * 2 + 1])
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

private class JsonNativeArrayScanAttempt {
    let status: Int32
    let words: Array<UInt64>
    let end: Int64
    let countOrError: Int64

    init(status: Int32, words: Array<UInt64>, end: Int64, countOrError: Int64) {
        this.status = status
        this.words = words
        this.end = end
        this.countOrError = countOrError
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

func jsonNativeScanObjectFields(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool
): Option<JsonNativeObjectFields> {
    if (!nativeJsonScannerAvailable()) {
        return None<JsonNativeObjectFields>
    }
    let words = Array<UInt64>(
        YJSON_NATIVE_OBJECT_FIELD_CAP * YJSON_NATIVE_OBJECT_FIELD_WORDS,
        repeat: 0u64
    )
    let end = Array<Int64>(1, repeat: 0)
    let countOrError = Array<Int64>(1, repeat: 0)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let wordsHandle = acquireArrayRawData(words)
        let endHandle = acquireArrayRawData(end)
        let countHandle = acquireArrayRawData(countOrError)
        let status = YJ_JSON_ScanObjectFields(
            dataHandle.pointer,
            size,
            start,
            nativeJsonScannerFlags(validateStrings),
            wordsHandle.pointer,
            YJSON_NATIVE_OBJECT_FIELD_CAP,
            endHandle.pointer,
            countHandle.pointer
        )
        releaseArrayRawData(countHandle)
        releaseArrayRawData(endHandle)
        releaseArrayRawData(wordsHandle)
        releaseArrayRawData(dataHandle)
        if (status == YJ_JSON_SCAN_OK) {
            let count = if (countOrError[0] < 0) {
                0
            } else {
                countOrError[0]
            }
            return Some(JsonNativeObjectFields(data, words, count, end[0]))
        }
        if (status == YJ_JSON_SCAN_FALLBACK || status == YJ_JSON_SCAN_CAPACITY) {
            return None<JsonNativeObjectFields>
        }
        throw JsonException("Native JSON scanner error at byte ${countOrError[0]}")
    }
}

func jsonNativeScanArrayElements(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool
): Option<JsonNativeArrayElements> {
    jsonNativeScanArrayElementsAtLeast(data, size, start, validateStrings, 0, 0)
}

func jsonNativeScanArrayElementsAtLeast(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool,
    minBytes: Int64,
    minElements: Int64
): Option<JsonNativeArrayElements> {
    if (!nativeJsonScannerAvailable()) {
        return None<JsonNativeArrayElements>
    }
    var elementCap: Int64 = YJSON_NATIVE_ARRAY_INITIAL_ELEMENT_CAP
    while (true) {
        let attempt = jsonNativeScanArrayElementsAttempt(data, size, start, validateStrings, elementCap)
        if (attempt.status == YJ_JSON_SCAN_OK) {
            let count = if (attempt.countOrError < 0) { 0 } else { attempt.countOrError }
            if (attempt.end - start < minBytes || count < minElements) {
                return None<JsonNativeArrayElements>
            }
            return Some(JsonNativeArrayElements(attempt.words, count, attempt.end))
        }
        if (attempt.status == YJ_JSON_SCAN_FALLBACK) {
            return None<JsonNativeArrayElements>
        }
        if (attempt.status != YJ_JSON_SCAN_CAPACITY) {
            throw JsonException("Native JSON scanner error at byte ${attempt.countOrError}")
        }
        if (elementCap >= YJSON_NATIVE_ARRAY_ELEMENT_CAP) {
            return None<JsonNativeArrayElements>
        }
        elementCap *= 4
        if (elementCap > YJSON_NATIVE_ARRAY_ELEMENT_CAP) {
            elementCap = YJSON_NATIVE_ARRAY_ELEMENT_CAP
        }
    }
    None<JsonNativeArrayElements>
}

private func jsonNativeScanArrayElementsAttempt(
    data: Array<Byte>,
    size: Int64,
    start: Int64,
    validateStrings: Bool,
    elementCap: Int64
): JsonNativeArrayScanAttempt {
    let words = Array<UInt64>(elementCap * 2, repeat: 0u64)
    let end = Array<Int64>(1, repeat: 0)
    let countOrError = Array<Int64>(1, repeat: 0)
    unsafe {
        let dataHandle = acquireArrayRawData(data)
        let wordsHandle = acquireArrayRawData(words)
        let endHandle = acquireArrayRawData(end)
        let countHandle = acquireArrayRawData(countOrError)
        let status = YJ_JSON_ScanArrayElements(
            dataHandle.pointer,
            size,
            start,
            nativeJsonScannerFlags(validateStrings),
            wordsHandle.pointer,
            elementCap,
            endHandle.pointer,
            countHandle.pointer
        )
        releaseArrayRawData(countHandle)
        releaseArrayRawData(endHandle)
        releaseArrayRawData(wordsHandle)
        releaseArrayRawData(dataHandle)
        JsonNativeArrayScanAttempt(status, words, end[0], countOrError[0])
    }
}
