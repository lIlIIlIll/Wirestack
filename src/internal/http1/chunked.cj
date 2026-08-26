package wirestack.internal.http1

import std.collection.ArrayList
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

public enum Http1ChunkErrorCode {
    | InvalidChunkSize
    | ChunkLineTooLong
    | InvalidChunkExtension
    | InvalidChunkTerminator
    | BodyTooLarge
    | InvalidTrailer
    | TrailerTooLarge
    | UnexpectedEof
    | DecoderAlreadyCompleted
}

public class Http1ChunkException <: Exception {
    public let code: Http1ChunkErrorCode

    public init(code: Http1ChunkErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "Http1ChunkException" }
}

/** One bounded incremental decode result. */
public class Http1ChunkDecodeBatch {
    private let ownedData: Array<Byte>
    private let ownedRemaining: Array<Byte>
    public let trailer: ?HttpTrailer
    public let complete: Bool

    public prop data: Array<Byte> { get() { ownedData.clone() } }
    public prop remaining: Array<Byte> { get() { ownedRemaining.clone() } }

    public init(
        data: Array<Byte>,
        remaining: Array<Byte>,
        trailer: ?HttpTrailer,
        complete: Bool
    ) {
        ownedData = data.clone()
        ownedRemaining = remaining.clone()
        this.trailer = trailer
        this.complete = complete
    }
}

private enum ChunkDecoderState {
    | SizeLine
    | Data
    | DataTerminator
    | Trailers
    | Complete
}

/** Strict streaming chunked decoder; body bytes are emitted instead of accumulated. */
public class Http1ChunkedDecoder {
    private let limits: HttpLimits
    private let enforceCumulativeBodyLimit: Bool
    private var state = ChunkDecoderState.SizeLine
    private var line = ArrayList<Byte>()
    private var lineSawCr = false
    private var chunkRemaining: Int64 = 0
    private var terminatorProgress: Int64 = 0
    private var decodedBytes: Int64 = 0
    private var trailerBytes: Int64 = 0
    private let trailerFields = ArrayList<HttpHeader>()
    private var completedTrailer: ?HttpTrailer = None<HttpTrailer>

    public init(limits!: HttpLimits = HttpLimits()) {
        this.limits = limits
        enforceCumulativeBodyLimit = true
    }

    /** Response streams retain per-chunk bounds without imposing a lifetime byte ceiling. */
    internal init(limits: HttpLimits, streamingResponse!: Bool) {
        this.limits = limits
        enforceCumulativeBodyLimit = !streamingResponse
    }

    public func feed(input: Array<Byte>): Http1ChunkDecodeBatch {
        match (state) {
            case ChunkDecoderState.Complete =>
                throw Http1ChunkException(
                    Http1ChunkErrorCode.DecoderAlreadyCompleted,
                    "chunked decoder cannot be reused after completion"
                )
            case _ => ()
        }
        let output = ArrayList<Byte>()
        var index = 0
        while (index < input.size) {
            match (state) {
                case ChunkDecoderState.SizeLine =>
                    let complete = consumeLineByte(input[index], limits.maxChunkLineBytes)
                    index += 1
                    if (complete) { processSizeLine() }
                case ChunkDecoderState.Data =>
                    let count = min(chunkRemaining, input.size - index)
                    for (offset in 0..count) { output.add(input[index + offset]) }
                    index += count
                    chunkRemaining -= count
                    if (chunkRemaining == 0) {
                        state = ChunkDecoderState.DataTerminator
                        terminatorProgress = 0
                    }
                case ChunkDecoderState.DataTerminator =>
                    let expected = if (terminatorProgress == 0) { 13u8 } else { 10u8 }
                    if (input[index] != expected) {
                        throw Http1ChunkException(Http1ChunkErrorCode.InvalidChunkTerminator, "chunk data must end with CRLF")
                    }
                    terminatorProgress += 1
                    index += 1
                    if (terminatorProgress == 2) {
                        state = ChunkDecoderState.SizeLine
                        terminatorProgress = 0
                    }
                case ChunkDecoderState.Trailers =>
                    let complete = consumeLineByte(input[index], min(limits.maxHeaderLineBytes, limits.maxTrailerBytes))
                    index += 1
                    if (complete) { processTrailerLine() }
                case ChunkDecoderState.Complete => break
            }
        }
        let remaining = if (isChunkComplete()) { chunkCopy(input, index, input.size) } else { Array<Byte>() }
        Http1ChunkDecodeBatch(output.toArray(), remaining, completedTrailer, isChunkComplete())
    }

    /** Must be called when the transport reports EOF. */
    public func finish(): Unit {
        if (!isChunkComplete()) {
            throw Http1ChunkException(Http1ChunkErrorCode.UnexpectedEof, "EOF arrived before the final chunk and trailers")
        }
    }

    private func consumeLineByte(value: Byte, maximum: Int64): Bool {
        if (lineSawCr) {
            if (value != 10u8) {
                throw Http1ChunkException(Http1ChunkErrorCode.InvalidChunkTerminator, "chunk lines require exact CRLF")
            }
            lineSawCr = false
            return true
        }
        if (value == 13u8) {
            lineSawCr = true
            return false
        }
        if (value == 10u8) {
            throw Http1ChunkException(Http1ChunkErrorCode.InvalidChunkTerminator, "bare LF is forbidden in chunked coding")
        }
        line.add(value)
        if (line.size > maximum) {
            throw Http1ChunkException(Http1ChunkErrorCode.ChunkLineTooLong, "chunk or trailer line exceeds configured limit")
        }
        false
    }

    private func processSizeLine(): Unit {
        let bytes = takeLine()
        let semicolon = chunkFind(bytes, b';', 0)
        let sizeEnd = if (semicolon < 0) { bytes.size } else { semicolon }
        let left = chunkTrimStart(bytes, 0, sizeEnd)
        let right = chunkTrimEnd(bytes, left, sizeEnd)
        let size = parseChunkSize(bytes, left, right)
        if (semicolon >= 0) { validateChunkExtensions(bytes, semicolon, bytes.size) }
        if (size > limits.maxBodyBytes ||
            (enforceCumulativeBodyLimit && size > limits.maxBodyBytes - decodedBytes)) {
            throw Http1ChunkException(Http1ChunkErrorCode.BodyTooLarge, "decoded chunked body exceeds configured limit")
        }
        if (enforceCumulativeBodyLimit) { decodedBytes += size }
        if (size == 0) {
            state = ChunkDecoderState.Trailers
        } else {
            chunkRemaining = size
            state = ChunkDecoderState.Data
        }
    }

    private func processTrailerLine(): Unit {
        let bytes = takeLine()
        trailerBytes += bytes.size + 2
        if (trailerBytes > limits.maxTrailerBytes) { trailerTooLarge() }
        if (bytes.isEmpty()) {
            let lineLimit = min(limits.maxHeaderLineBytes, limits.maxTrailerBytes)
            let trailerLimits = HttpLimits(
                maxHeaderLineBytes: lineLimit,
                maxHeaderBytes: limits.maxTrailerBytes,
                maxHeaderCount: limits.maxTrailerCount,
                maxChunkLineBytes: limits.maxChunkLineBytes,
                maxTrailerBytes: limits.maxTrailerBytes,
                maxTrailerCount: limits.maxTrailerCount,
                maxBodyBytes: limits.maxBodyBytes
            )
            let fields = try {
                HttpHeaders(entries: trailerFields.toArray(), limits: trailerLimits)
            } catch (_: IllegalArgumentException) {
                invalidTrailer("trailer fields exceed configured bounds")
            }
            completedTrailer = try {
                Some(HttpTrailer(headers: fields))
            } catch (_: IllegalArgumentException) {
                invalidTrailer("trailer contains a forbidden field")
            }
            state = ChunkDecoderState.Complete
            return
        }
        if (bytes[0] == b' ' || bytes[0] == 9u8) { invalidTrailer("obs-fold is forbidden in trailers") }
        let colon = chunkFind(bytes, b':', 0)
        if (colon <= 0) { invalidTrailer("trailer line has no valid field name") }
        let start = chunkTrimStart(bytes, colon + 1, bytes.size)
        let end = chunkTrimEnd(bytes, start, bytes.size)
        let field = try {
            HttpHeader(chunkString(bytes, 0, colon), chunkString(bytes, start, end))
        } catch (_: IllegalArgumentException) {
            invalidTrailer("trailer field is invalid")
        }
        trailerFields.add(field)
        if (trailerFields.size > limits.maxTrailerCount) { trailerTooLarge() }
    }

    private func takeLine(): Array<Byte> {
        let result = line.toArray()
        line = ArrayList<Byte>()
        result
    }

    private func isChunkComplete(): Bool {
        match (state) { case ChunkDecoderState.Complete => true; case _ => false }
    }
}

/** Encodes one non-final chunk without buffering any other body bytes. */
public func encodeHttp1Chunk(
    data: Array<Byte>,
    extension!: ?String = None<String>,
    limits!: HttpLimits = HttpLimits()
): Array<Byte> {
    if (data.isEmpty()) {
        throw IllegalArgumentException("non-final HTTP/1 chunk must not be empty")
    }
    if (data.size > limits.maxBodyBytes) {
        throw Http1ChunkException(Http1ChunkErrorCode.BodyTooLarge, "encoded chunk exceeds configured body limit")
    }
    let output = ArrayList<Byte>()
    let sizeText = chunkHex(data.size)
    appendChunkText(output, sizeText)
    var extensionBytes: Int64 = 0
    if (let Some(value) <- extension) {
        let encoded = ";${value}"
        let bytes = encoded.toArray()
        validateChunkExtensions(bytes, 0, bytes.size)
        extensionBytes = bytes.size
        appendChunkText(output, encoded)
    }
    if (sizeText.toArray().size + extensionBytes > limits.maxChunkLineBytes) {
        throw Http1ChunkException(Http1ChunkErrorCode.ChunkLineTooLong, "encoded chunk line exceeds configured limit")
    }
    appendChunkText(output, "\r\n")
    for (byte in data) { output.add(byte) }
    appendChunkText(output, "\r\n")
    output.toArray()
}

/** Encodes the final chunk and a bounded, prevalidated trailer block. */
public func encodeHttp1FinalChunk(
    trailer!: HttpTrailer = HttpTrailer(),
    limits!: HttpLimits = HttpLimits()
): Array<Byte> {
    let output = ArrayList<Byte>()
    appendChunkText(output, "0\r\n")
    var total: Int64 = 2
    if (trailer.headers.size > limits.maxTrailerCount) { trailerTooLarge() }
    for (entry in trailer.headers.entries) {
        let lineBytes = entry.name.toArray().size + entry.value.toArray().size + 4
        total += lineBytes
        if (lineBytes - 2 > min(limits.maxHeaderLineBytes, limits.maxTrailerBytes) || total > limits.maxTrailerBytes) {
            trailerTooLarge()
        }
        appendChunkText(output, "${entry.name}: ${entry.value}\r\n")
    }
    appendChunkText(output, "\r\n")
    output.toArray()
}

public func writeHttp1Chunk(
    transport: DuplexTransport,
    encoded: Array<Byte>,
    context!: OperationContext = OperationContext.background()
): Unit {
    writeAll(transport, ByteSpan(encoded), context: context)
}

private func parseChunkSize(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    if (start >= end || end - start > 16) { invalidChunkSize() }
    var result: Int64 = 0
    for (index in start..end) {
        let digit = hexValue(bytes[index])
        if (digit < 0 || result > (Int64.Max - digit) / 16) { invalidChunkSize() }
        result = result * 16 + digit
    }
    result
}

private func validateChunkExtensions(bytes: Array<Byte>, start: Int64, end: Int64): Unit {
    var index = start
    while (index < end) {
        index = chunkSkipOws(bytes, index, end)
        if (index >= end || bytes[index] != b';') { invalidChunkExtension() }
        index = chunkSkipOws(bytes, index + 1, end)
        let nameStart = index
        while (index < end && isChunkToken(bytes[index])) { index += 1 }
        if (index == nameStart) { invalidChunkExtension() }
        index = chunkSkipOws(bytes, index, end)
        if (index < end && bytes[index] == b'=') {
            index = chunkSkipOws(bytes, index + 1, end)
            if (index >= end) { invalidChunkExtension() }
            if (bytes[index] == b'"') {
                index += 1
                var closed = false
                while (index < end) {
                    let value = bytes[index]
                    if (value == b'"') { closed = true; index += 1; break }
                    if (value == b'\\') {
                        index += 1
                        if (index >= end || bytes[index] == 10u8 || bytes[index] == 13u8) { invalidChunkExtension() }
                    } else if ((value < 32u8 && value != 9u8) || value == 127u8) {
                        invalidChunkExtension()
                    }
                    index += 1
                }
                if (!closed) { invalidChunkExtension() }
            } else {
                let valueStart = index
                while (index < end && isChunkToken(bytes[index])) { index += 1 }
                if (index == valueStart) { invalidChunkExtension() }
            }
            index = chunkSkipOws(bytes, index, end)
        }
        if (index < end && bytes[index] != b';') { invalidChunkExtension() }
    }
}

private func chunkHex(value: Int64): String {
    let digits = "0123456789abcdef".toArray()
    let reversed = ArrayList<Byte>()
    var remaining = value
    while (remaining > 0) {
        reversed.add(digits[remaining % 16])
        remaining /= 16
    }
    let output = ArrayList<Byte>()
    var index = reversed.size
    while (index > 0) { index -= 1; output.add(reversed[index]) }
    String.fromUtf8(output.toArray())
}

private func hexValue(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value - b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value - b'A') + 10 }
    -1
}

private func isChunkToken(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'A' && value <= b'Z') ||
        (value >= b'a' && value <= b'z') || value == b'!' || value == b'#' ||
        value == b'$' || value == b'%' || value == b'&' || value == b'\'' ||
        value == b'*' || value == b'+' || value == b'-' || value == b'.' ||
        value == b'^' || value == b'_' || value == b'`' || value == b'|' || value == b'~'
}

private func chunkSkipOws(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var index = start
    while (index < end && (bytes[index] == b' ' || bytes[index] == 9u8)) { index += 1 }
    index
}

private func chunkTrimStart(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    chunkSkipOws(bytes, start, end)
}

private func chunkTrimEnd(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var index = end
    while (index > start && (bytes[index - 1] == b' ' || bytes[index - 1] == 9u8)) { index -= 1 }
    index
}

private func chunkFind(bytes: Array<Byte>, needle: Byte, start: Int64): Int64 {
    for (index in start..bytes.size) { if (bytes[index] == needle) { return index } }
    -1
}

private func chunkCopy(bytes: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let output = ArrayList<Byte>()
    for (index in start..end) { output.add(bytes[index]) }
    output.toArray()
}

private func chunkString(bytes: Array<Byte>, start: Int64, end: Int64): String {
    String.fromUtf8(chunkCopy(bytes, start, end))
}

private func appendChunkText(output: ArrayList<Byte>, value: String): Unit {
    for (byte in value.toArray()) { output.add(byte) }
}

private func invalidChunkSize(): Nothing {
    throw Http1ChunkException(Http1ChunkErrorCode.InvalidChunkSize, "chunk size is not a bounded hexadecimal integer")
}

private func invalidChunkExtension(): Nothing {
    throw Http1ChunkException(Http1ChunkErrorCode.InvalidChunkExtension, "chunk extension syntax is invalid")
}

private func invalidTrailer(message: String): Nothing {
    throw Http1ChunkException(Http1ChunkErrorCode.InvalidTrailer, message)
}

private func trailerTooLarge(): Nothing {
    throw Http1ChunkException(Http1ChunkErrorCode.TrailerTooLarge, "HTTP trailer exceeds configured limits")
}
