package wirestack.http

import std.collection.ArrayList

/** Stable multipart failure categories. */
public enum MultipartErrorCode <: Equatable<MultipartErrorCode> {
    /** The boundary is missing, duplicated, empty, too long, or contains a disallowed byte. */
    | InvalidBoundary
    /** A part name, filename, content type, or header value violates multipart metadata rules. */
    | InvalidMetadata
    /** Multipart framing, line endings, or a boundary terminator is malformed or truncated. */
    | Malformed
    /** The number of parts exceeds the configured maximum. */
    | PartLimitExceeded
    /** One part exceeds its configured header-byte or header-count maximum. */
    | HeaderLimitExceeded
    /** One part payload exceeds the configured byte maximum. */
    | PartBytesLimitExceeded
    /** The complete multipart source or encoded body exceeds the configured byte maximum. */
    | BodyBytesLimitExceeded
    /** An operation attempted to use a closed reader, decoder, or body stream. */
    | Closed
    /** The reader was advanced before the current part reached EOF or was closed. */
    | ActivePart
    /** The operation context was cancelled or its deadline expired. */
    | ContextStopped
    /** An underlying body stream failed or reported invalid read progress. */
    | StreamFailure

    /**
     * Compares two multipart error categories.
     * @param other Category to compare with this value.
     */
    public operator func ==(other: MultipartErrorCode): Bool {
        match ((this, other)) {
            case (MultipartErrorCode.InvalidBoundary, MultipartErrorCode.InvalidBoundary) |
                (MultipartErrorCode.InvalidMetadata, MultipartErrorCode.InvalidMetadata) |
                (MultipartErrorCode.Malformed, MultipartErrorCode.Malformed) |
                (MultipartErrorCode.PartLimitExceeded, MultipartErrorCode.PartLimitExceeded) |
                (MultipartErrorCode.HeaderLimitExceeded, MultipartErrorCode.HeaderLimitExceeded) |
                (MultipartErrorCode.PartBytesLimitExceeded, MultipartErrorCode.PartBytesLimitExceeded) |
                (MultipartErrorCode.BodyBytesLimitExceeded, MultipartErrorCode.BodyBytesLimitExceeded) |
                (MultipartErrorCode.Closed, MultipartErrorCode.Closed) |
                (MultipartErrorCode.ActivePart, MultipartErrorCode.ActivePart) |
                (MultipartErrorCode.ContextStopped, MultipartErrorCode.ContextStopped) |
                (MultipartErrorCode.StreamFailure, MultipartErrorCode.StreamFailure) => true
            case _ => false
        }
    }

    /**
     * Reports whether two multipart error categories differ.
     * @param other Category to compare with this value.
     */
    public operator func !=(other: MultipartErrorCode): Bool { !(this == other) }
}

/** A bounded multipart encoding or parsing failure. */
public class MultipartException <: Exception {
    /** Stable category for this failure. */
    public let code: MultipartErrorCode
    /** Underlying stream failure, when one was preserved. */
    public let cause: ?Exception
    /**
     * Creates a multipart failure.
     * @param code Stable failure category.
     * @param message Diagnostic text.
     * @param cause Optional underlying stream failure.
     */
    public init(code: MultipartErrorCode, message: String,
        cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

    /** Returns the stable exception class name. */
    protected override func getClassName(): String { "MultipartException" }
}

/** Explicit memory, metadata and payload bounds for multipart parsing. */
public class MultipartLimits {
    /** Maximum number of parts, from 1 through 4096. */
    public let maximumParts: Int64
    /** Maximum bytes across the header lines and terminators of one part, from 1 through 1048576. */
    public let maximumHeaderBytes: Int64
    /** Maximum number of header fields in one part, from 1 through 1024. */
    public let maximumHeaderCount: Int64
    /** Maximum payload bytes in one part. The value is nonnegative and no greater than maximumBodyBytes. */
    public let maximumPartBytes: Int64
    /** Maximum bytes read from the multipart source, including boundaries and headers. */
    public let maximumBodyBytes: Int64
    /** Source-read and part-discard buffer size, from 1 through 1048576 bytes. */
    public let readBufferBytes: Int64

    /**
     * Creates a validated set of multipart parser limits.
     * @param maximumParts Maximum number of parts, from 1 through 4096.
     * @param maximumHeaderBytes Maximum bytes across one part's header block, from 1 through 1048576.
     * @param maximumHeaderCount Maximum header fields in one part, from 1 through 1024.
     * @param maximumPartBytes Maximum payload bytes in one part; nonnegative and no greater than maximumBodyBytes.
     * @param maximumBodyBytes Maximum source bytes including multipart framing; must be nonnegative.
     * @param readBufferBytes Source-read and part-discard buffer size, from 1 through 1048576 bytes.
     */
    public init(
        maximumParts!: Int64 = 128,
        maximumHeaderBytes!: Int64 = 64 * 1024,
        maximumHeaderCount!: Int64 = 32,
        maximumPartBytes!: Int64 = 64 * 1024 * 1024,
        maximumBodyBytes!: Int64 = 128 * 1024 * 1024,
        readBufferBytes!: Int64 = 16 * 1024
    ) {
        if (maximumParts <= 0 || maximumParts > 4096 || maximumHeaderBytes <= 0 ||
            maximumHeaderBytes > 1024 * 1024 || maximumHeaderCount <= 0 ||
            maximumHeaderCount > 1024 || maximumPartBytes < 0 || maximumBodyBytes < 0 ||
            maximumPartBytes > maximumBodyBytes || readBufferBytes <= 0 ||
            readBufferBytes > 1024 * 1024) {
            throw IllegalArgumentException("multipart limits are invalid")
        }
        this.maximumParts = maximumParts
        this.maximumHeaderBytes = maximumHeaderBytes
        this.maximumHeaderCount = maximumHeaderCount
        this.maximumPartBytes = maximumPartBytes
        this.maximumBodyBytes = maximumBodyBytes
        this.readBufferBytes = readBufferBytes
    }
}

/** One outbound multipart part backed by a replayable or one-shot body source. */
public class MultipartPart {
    /** Validated form field name, containing 1 through 256 printable ASCII bytes except quote and backslash. */
    public let name: String
    /** Optional validated filename, containing 1 through 1024 printable ASCII bytes except quote and backslash. */
    public let filename: ?String
    /** Content-Type value of 1 through 256 printable ASCII bytes; defaults to application/octet-stream. */
    public let contentType: String
    /** Body source retained by reference and opened when encoding reaches this part. */
    public let body: RequestBody
    /**
     * Creates a part backed by an existing body source.
     * @param name Form field name.
     * @param body Body source. Its declared replayability determines whether the encoded body can be replayed.
     * @param filename Optional filename included in Content-Disposition.
     * @param contentType Content-Type value of 1 through 256 printable ASCII bytes; defaults to application/octet-stream.
     */
    public init(name: String, body: RequestBody,
        filename!: ?String = None<String>,
        contentType!: String = "application/octet-stream") {
        validateMultipartMetadata(name, "multipart field name", 256)
        match (filename) {
            case Some(value) => validateMultipartMetadata(value, "multipart filename", 1024)
            case None => ()
        }
        validateMultipartContentType(contentType)
        this.name = name
        this.filename = filename
        this.contentType = contentType
        this.body = body
    }

    /**
     * Creates a replayable part from an owned copy of an in-memory byte array.
     * @param name Form field name.
     * @param bytes Payload bytes, copied during construction.
     * @param filename Optional filename included in Content-Disposition.
     * @param contentType Content-Type value of 1 through 256 printable ASCII bytes; defaults to application/octet-stream.
     */
    public init(name: String, bytes: Array<Byte>,
        filename!: ?String = None<String>,
        contentType!: String = "application/octet-stream") {
        this(name, RequestBody.bytes(bytes), filename: filename, contentType: contentType)
    }
}

/** Bounded multipart/form-data encoder whose result preserves part stream replayability. */
public class MultipartWriter {
    /** Validated boundary written into every delimiter and the generated Content-Type value. */
    public let boundary: String
    private let maximumParts: Int64
    private let maximumPartBytes: Int64
    private let parts = ArrayList<MultipartPart>()
    /**
     * Creates an empty multipart writer.
     * @param boundary Boundary of 1 through 70 ASCII bytes containing only letters, digits, apostrophe, parentheses, plus, underscore, comma, hyphen, period, slash, colon, equals, or question mark.
     * @param maximumParts Maximum number of added parts, from 1 through 4096.
     * @param maximumPartBytes Maximum payload bytes allowed for each part; must be nonnegative.
     */
    public init(boundary: String, maximumParts!: Int64 = 128,
        maximumPartBytes!: Int64 = 64 * 1024 * 1024) {
        validateMultipartBoundary(boundary)
        if (maximumParts <= 0 || maximumParts > 4096 || maximumPartBytes < 0) {
            throw IllegalArgumentException("multipart writer limits are invalid")
        }
        this.boundary = boundary
        this.maximumParts = maximumParts
        this.maximumPartBytes = maximumPartBytes
    }

    /**
     * Appends one part without reading its payload.
     * A known oversized payload is rejected now. An unknown-length payload is checked while it streams.
     * @param part Immutable part descriptor and body source to append.
     * @return This writer.
     */
    public func add(part: MultipartPart): MultipartWriter {
        if (parts.size >= maximumParts) {
            throw MultipartException(MultipartErrorCode.PartLimitExceeded,
                "multipart writer part limit exceeded")
        }
        if (let Some(length) <- part.body.contentLength) {
            if (length > maximumPartBytes) {
                throw MultipartException(MultipartErrorCode.PartBytesLimitExceeded,
                    "multipart writer part exceeds configured byte limit")
            }
        }
        parts.add(part)
        this
    }

    /** Returns a new array of part references. Later additions do not change it, and payloads are not copied. */
    public func snapshot(): Array<MultipartPart> { parts.toArray() }

    /** Returns multipart/form-data with the validated boundary as a quoted parameter. */
    public func contentType(): String { "multipart/form-data; boundary=\"${boundary}\"" }

    /**
     * Captures the current parts as a lazily streamed request body.
     * Payload bytes are not materialized. The result is one-shot if any captured part is one-shot.
     * A fully declared encoded length is checked now. Unknown lengths are checked while the body streams.
     * @param maximumBytes Maximum encoded bytes including headers and boundaries; must be nonnegative.
     * @return A body with a known content length only when every captured part has one.
     */
    public func body(maximumBytes!: Int64 = 128 * 1024 * 1024): RequestBody {
        if (maximumBytes < 0) {
            throw IllegalArgumentException("multipart body byte limit cannot be negative")
        }
        let captured = parts.toArray()
        let declared = multipartEncodedLength(captured, boundary, maximumBytes)
        var replayable = true
        for (part in captured) {
            if (part.body.replayability == BodyReplayability.OneShot) { replayable = false }
        }
        let factory = { => MultipartEncodingStream(
            captured, boundary, maximumPartBytes, maximumBytes, declared
        ) }
        if (replayable) { RequestBody.replayableFactory(declared, factory) }
        else { RequestBody.oneShot(factory()) }
    }
}

/** One inbound multipart part. Its body must reach EOF or be closed before next(). */
public class MultipartReadPart <: Resource {
    /** Validated form field name from Content-Disposition. */
    public let name: String
    /** Optional validated filename from Content-Disposition. */
    public let filename: ?String
    /** Part Content-Type, or application/octet-stream when the header is absent. */
    public let contentType: String
    /** Parsed part headers, including Content-Disposition and any Content-Type field. */
    public let headers: HttpHeaders
    /** Streaming payload owned by this part. Consume it to EOF or close it before requesting another part. */
    public let body: HttpBodyStream

    init(name: String, filename: ?String, contentType: String,
        headers: HttpHeaders, body: HttpBodyStream) {
        this.name = name
        this.filename = filename
        this.contentType = contentType
        this.headers = headers
        this.body = body
    }

    /** Discards any unread payload through the next boundary and releases this part. */
    public func close(): Unit { body.close() }
    /** Reports whether the payload stream was explicitly closed or failed. EOF alone does not close it. */
    public func isClosed(): Bool { body.isClosed() }
}

/** Incremental multipart/form-data reader with single-active-part ownership. */
public class MultipartReader <: Resource {
    private let decoder: MultipartDecoder

    /**
     * Creates a reader for a response body. After successful construction, the reader owns the body.
     * It closes the body at the final boundary, on failure, or when close is called.
     * @param body Multipart source body.
     * @param boundary Boundary of 1 through 70 ASCII bytes containing only letters, digits, apostrophe, parentheses, plus, underscore, comma, hyphen, period, slash, colon, equals, or question mark.
     * @param limits Bounds applied while headers and payload bytes stream from the source.
     * @param context Cancellation and deadline checked before and after source reads.
     */
    public init(body: ResponseBody, boundary: String,
        limits!: MultipartLimits = MultipartLimits(),
        context!: OperationContext = OperationContext.background()) {
        validateMultipartBoundary(boundary)
        decoder = MultipartDecoder(body, boundary, limits, context)
    }

    /**
     * Creates a reader from the request's sole Content-Type field. On success, it owns the request body.
     * @param request Request whose Content-Type boundary and body are consumed.
     * @param limits Bounds applied while headers and payload bytes stream from the request.
     * @param context Cancellation and deadline checked before and after source reads.
     * @return A reader positioned before the first part.
     */
    public static func fromRequest(request: HttpServerRequest,
        limits!: MultipartLimits = MultipartLimits(),
        context!: OperationContext = OperationContext.background()): MultipartReader {
        let values = request.headers.getAll("content-type")
        if (values.size != 1) {
            throw MultipartException(MultipartErrorCode.InvalidBoundary,
                "multipart request requires exactly one Content-Type field")
        }
        MultipartReader(request.body, boundaryFromMultipartContentType(values[0]),
            limits: limits, context: context)
    }

    /**
     * Parses and returns the next part without materializing its payload.
     * The previous part must have reached EOF or been closed. The final boundary returns None and closes the source.
     */
    public func next(): ?MultipartReadPart { decoder.nextPart() }
    /** Closes the source body without draining the remaining multipart data. */
    public func close(): Unit { decoder.close() }
    /** Reports whether the reader has closed its source or reached the final boundary. */
    public func isClosed(): Bool { decoder.isClosed() }
}

private enum MultipartWriteStage {
    | Header
    | Payload
    | Separator
    | Closing
    | Done
}

private class MultipartEncodingStream <: HttpBodyStream {
    private let parts: Array<MultipartPart>
    private let boundary: String
    private let maximumPartBytes: Int64
    private let maximumBytes: Int64
    private let declared: ?Int64
    private var partIndex: Int64 = 0
    private var stage: MultipartWriteStage
    private var segment: Array<Byte>
    private var segmentOffset: Int64 = 0
    private var active: ?HttpBodyStream = None<HttpBodyStream>
    private var activePartBytes: Int64 = 0
    private var emitted: Int64 = 0
    private var closed = false

    init(parts: Array<MultipartPart>, boundary: String, maximumPartBytes: Int64,
        maximumBytes: Int64, declared: ?Int64) {
        this.parts = parts
        this.boundary = boundary
        this.maximumPartBytes = maximumPartBytes
        this.maximumBytes = maximumBytes
        this.declared = declared
        if (parts.isEmpty()) {
            stage = MultipartWriteStage.Closing
            segment = multipartClosing(boundary)
        } else {
            stage = MultipartWriteStage.Header
            segment = multipartHeader(boundary, parts[0])
        }
    }

    /** Encoded byte length when every captured part declared a length; otherwise None. */
    public prop contentLength: ?Int64 { get() { declared } }

    /**
     * Streams multipart framing and payload bytes into the destination.
     * @param destination Buffer that receives up to its length in encoded bytes.
     * @return Bytes written, or 0 for an empty destination or at the end of the encoded body.
     */
    public func read(destination: Array<Byte>): Int64 {
        ensureEncodingOpen()
        if (destination.isEmpty()) { return 0 }
        var produced: Int64 = 0
        try {
            while (produced < destination.size) {
                if (segmentOffset < segment.size) {
                    let count = min(destination.size - produced, segment.size - segmentOffset)
                    ensureEncodingTotal(count)
                    for (index in 0..count) {
                        destination[produced + index] = segment[segmentOffset + index]
                    }
                    segmentOffset += count
                    produced += count
                    emitted += count
                    if (produced == destination.size) { return produced }
                    continue
                }

                match (stage) {
                    case MultipartWriteStage.Header =>
                        active = Some(parts[partIndex].body.open())
                        activePartBytes = 0
                        stage = MultipartWriteStage.Payload
                    case MultipartWriteStage.Payload =>
                        if (produced > 0) { return produced }
                        let stream = active.getOrThrow({ => MultipartException(
                            MultipartErrorCode.StreamFailure, "multipart part stream is unavailable"
                        ) })
                        let partRemaining = maximumPartBytes - activePartBytes
                        let totalRemaining = maximumBytes - emitted
                        let allowed = min(destination.size, min(partRemaining, totalRemaining))
                        let request = if (allowed < destination.size) { allowed + 1 } else { allowed }
                        if (request <= 0) {
                            let probe = Array<Byte>(1, repeat: 0u8)
                            let count = stream.read(probe)
                            if (count == 0) {
                                stream.close()
                                active = None<HttpBodyStream>
                                stage = MultipartWriteStage.Separator
                                segment = "\r\n".toArray()
                                segmentOffset = 0
                                continue
                            }
                            if (partRemaining <= 0) { partEncodingLimit() }
                            bodyEncodingLimit()
                        }
                        let staging = if (request == destination.size) { destination }
                            else { Array<Byte>(request, repeat: 0u8) }
                        let count = stream.read(staging)
                        if (count < 0 || count > staging.size) {
                            throw MultipartException(MultipartErrorCode.StreamFailure,
                                "multipart part stream returned invalid progress")
                        }
                        if (count == 0) {
                            stream.close()
                            active = None<HttpBodyStream>
                            stage = MultipartWriteStage.Separator
                            segment = "\r\n".toArray()
                            segmentOffset = 0
                        } else {
                            if (count > partRemaining) { partEncodingLimit() }
                            if (count > totalRemaining) { bodyEncodingLimit() }
                            if (request != destination.size) {
                                for (index in 0..count) { destination[index] = staging[index] }
                            }
                            activePartBytes += count
                            emitted += count
                            return count
                        }
                    case MultipartWriteStage.Separator =>
                        partIndex += 1
                        if (partIndex < parts.size) {
                            stage = MultipartWriteStage.Header
                            segment = multipartHeader(boundary, parts[partIndex])
                        } else {
                            stage = MultipartWriteStage.Closing
                            segment = multipartClosing(boundary)
                        }
                        segmentOffset = 0
                    case MultipartWriteStage.Closing =>
                        stage = MultipartWriteStage.Done
                        segment = Array<Byte>()
                        segmentOffset = 0
                    case MultipartWriteStage.Done => return produced
                }
            }
            produced
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    /** Closes the active part stream, if any, without opening later parts. */
    public func close(): Unit {
        if (!closed) {
            closed = true
            if (let Some(stream) <- active) {
                try { stream.close() } catch (_: Exception) {}
            }
            active = None<HttpBodyStream>
        }
    }

    /** Reports whether this encoded body stream was closed. */
    public func isClosed(): Bool { closed }

    private func ensureEncodingOpen(): Unit {
        if (closed) {
            throw MultipartException(MultipartErrorCode.Closed,
                "multipart encoding stream is closed")
        }
    }

    private func ensureEncodingTotal(count: Int64): Unit {
        if (count > maximumBytes - emitted) { bodyEncodingLimit() }
    }

    private func partEncodingLimit(): Nothing {
        throw MultipartException(MultipartErrorCode.PartBytesLimitExceeded,
            "multipart part exceeds configured byte limit while encoding")
    }

    private func bodyEncodingLimit(): Nothing {
        throw MultipartException(MultipartErrorCode.BodyBytesLimitExceeded,
            "multipart body exceeds configured byte limit while encoding")
    }
}

private class MultipartPartStream <: HttpBodyStream {
    private let decoder: MultipartDecoder
    private let generation: Int64
    private var closed = false
    private var finished = false

    init(decoder: MultipartDecoder, generation: Int64) {
        this.decoder = decoder
        this.generation = generation
    }

    /** Always None because a decoded part length is not known before its boundary is found. */
    public prop contentLength: ?Int64 { get() { None<Int64> } }

    /**
     * Streams payload bytes up to, but not including, the next multipart boundary.
     * @param destination Buffer that receives up to its length in payload bytes.
     * @return Bytes written, or 0 for an empty destination or when this part reaches its boundary.
     */
    public func read(destination: Array<Byte>): Int64 {
        if (closed) {
            throw MultipartException(MultipartErrorCode.Closed,
                "multipart part stream is closed")
        }
        if (finished) { return 0 }
        try {
            let count = decoder.readPart(generation, destination)
            if (count == 0 && !destination.isEmpty()) { finished = true }
            count
        } catch (error: Exception) {
            closed = true
            throw error
        }
    }

    /** Discards unread payload through this part's boundary so the reader can advance. */
    public func close(): Unit {
        if (!closed) {
            closed = true
            decoder.discardPart(generation)
        }
    }

    /** Reports whether this part stream was explicitly closed or failed. */
    public func isClosed(): Bool { closed }
}

private class MultipartDecoder <: Resource {
    private let source: ResponseBody
    private let limits: MultipartLimits
    private let context: OperationContext
    private let firstBoundary: Array<Byte>
    private let delimiter: Array<Byte>
    private let delimiterPrefix: Array<Int64>
    private var pending = ArrayList<Byte>()
    private var pendingOffset: Int64 = 0
    private var sourceBytes: Int64 = 0
    private var sourceEof = false
    private var started = false
    private var finalBoundary = false
    private var activePart = false
    private var generation: Int64 = 0
    private var partCount: Int64 = 0
    private var partBytes: Int64 = 0
    private var closed = false

    init(source: ResponseBody, boundary: String, limits: MultipartLimits,
        context: OperationContext) {
        this.source = source
        this.limits = limits
        this.context = context
        firstBoundary = "--${boundary}".toArray()
        delimiter = "\r\n--${boundary}".toArray()
        delimiterPrefix = multipartPrefixTable(delimiter)
        if (let Some(length) <- source.contentLength) {
            if (length > limits.maximumBodyBytes) {
                source.close()
                throw MultipartException(MultipartErrorCode.BodyBytesLimitExceeded,
                    "multipart body declared length exceeds configured limit")
            }
        }
    }

    func nextPart(): ?MultipartReadPart {
        ensureDecoderOpen()
        checkContext()
        if (activePart) {
            throw MultipartException(MultipartErrorCode.ActivePart,
                "current multipart part must reach EOF or be closed before next")
        }
        try {
            if (!started) { readFirstBoundary() }
            if (finalBoundary) {
                closeAtEnd()
                return None<MultipartReadPart>
            }
            if (partCount >= limits.maximumParts) {
                fail(MultipartErrorCode.PartLimitExceeded,
                    "multipart part count exceeds configured limit")
            }
            let headers = readPartHeaders()
            let dispositions = headers.getAll("content-disposition")
            if (dispositions.size != 1) {
                fail(MultipartErrorCode.InvalidMetadata,
                    "multipart part requires exactly one Content-Disposition field")
            }
            let (name, filename) = parseContentDisposition(dispositions[0])
            let contentTypes = headers.getAll("content-type")
            if (contentTypes.size > 1) {
                fail(MultipartErrorCode.InvalidMetadata,
                    "multipart part has duplicate Content-Type fields")
            }
            let contentType = if (contentTypes.isEmpty()) {
                "application/octet-stream"
            } else {
                validateMultipartContentType(contentTypes[0])
                contentTypes[0]
            }
            partCount += 1
            partBytes = 0
            generation += 1
            activePart = true
            let stream = MultipartPartStream(this, generation)
            Some(MultipartReadPart(name, filename, contentType, headers, stream))
        } catch (error: MultipartException) {
            throw error
        } catch (error: Exception) {
            fail(MultipartErrorCode.StreamFailure,
                "multipart source stream failed", cause: Some(error))
        }
    }

    func readPart(expectedGeneration: Int64, destination: Array<Byte>): Int64 {
        ensureActive(expectedGeneration)
        if (destination.isEmpty()) { return 0 }
        checkContext()
        try {
            while (true) {
                let candidate = findDelimiter(destination.size)
                if (candidate >= 0) {
                    let required = candidate - pendingOffset + delimiter.size + 2
                    if (available() < required) {
                        if (sourceEof) {
                            fail(MultipartErrorCode.Malformed,
                                "multipart boundary suffix is truncated")
                        }
                        fill()
                        continue
                    }
                    let suffix = candidate + delimiter.size
                    let valid = (pending[suffix] == b'-' && pending[suffix + 1] == b'-') ||
                        (pending[suffix] == b'\r' && pending[suffix + 1] == b'\n')
                    if (valid) {
                        let before = candidate - pendingOffset
                        if (before > 0) {
                            return copyPartBytes(destination, before)
                        }
                        consume(delimiter.size)
                        if (pending[pendingOffset] == b'-') {
                            consume(2)
                            validateFinalBoundaryTerminator()
                            finalBoundary = true
                        } else {
                            consume(2)
                        }
                        activePart = false
                        partBytes = 0
                        return 0
                    }
                    let throughCandidate = candidate - pendingOffset + 1
                    return copyPartBytes(destination, throughCandidate)
                }

                let safe = available() - (delimiter.size - 1)
                if (safe > 0) { return copyPartBytes(destination, safe) }
                if (sourceEof) {
                    fail(MultipartErrorCode.Malformed,
                        "multipart body ended before a closing boundary")
                }
                fill()
            }
            0
        } catch (error: MultipartException) {
            throw error
        } catch (error: Exception) {
            fail(MultipartErrorCode.StreamFailure,
                "multipart source stream failed", cause: Some(error))
        }
    }

    func discardPart(expectedGeneration: Int64): Unit {
        if (!activePart || expectedGeneration != generation || closed) { return }
        let buffer = Array<Byte>(limits.readBufferBytes, repeat: 0u8)
        while (readPart(expectedGeneration, buffer) != 0) {}
    }

    /** Closes the owned source body and invalidates any active part stream without draining it. */
    public func close(): Unit {
        if (!closed) {
            closed = true
            activePart = false
            try { source.close() } catch (_: Exception) {}
            pending = ArrayList<Byte>()
            pendingOffset = 0
        }
    }

    /** Reports whether the decoder has closed its owned source body. */
    public func isClosed(): Bool { closed }

    private func readFirstBoundary(): Unit {
        ensureAvailable(firstBoundary.size + 2)
        for (index in 0..firstBoundary.size) {
            if (pending[pendingOffset + index] != firstBoundary[index]) {
                fail(MultipartErrorCode.Malformed,
                    "multipart body does not begin with the declared boundary")
            }
        }
        consume(firstBoundary.size)
        if (pending[pendingOffset] == b'-' && pending[pendingOffset + 1] == b'-') {
            consume(2)
            validateFinalBoundaryTerminator()
            finalBoundary = true
        } else if (pending[pendingOffset] == b'\r' && pending[pendingOffset + 1] == b'\n') {
            consume(2)
        } else {
            fail(MultipartErrorCode.Malformed, "multipart initial boundary suffix is invalid")
        }
        started = true
    }

    private func validateFinalBoundaryTerminator(): Unit {
        while (available() < 2 && !sourceEof) { fill() }
        if (available() == 0 && sourceEof) { return }
        if (available() < 2 || pending[pendingOffset] != b'\r' ||
            pending[pendingOffset + 1] != b'\n') {
            fail(MultipartErrorCode.Malformed,
                "multipart closing boundary must end with CRLF or end of stream")
        }
    }

    private func readPartHeaders(): HttpHeaders {
        let builder = HttpHeaders.builder(limits: HttpLimits(
            maxHeaderLineBytes: limits.maximumHeaderBytes,
            maxHeaderBytes: limits.maximumHeaderBytes,
            maxHeaderCount: limits.maximumHeaderCount,
            maxBodyBytes: limits.maximumBodyBytes
        ))
        var total: Int64 = 0
        var count: Int64 = 0
        while (true) {
            let line = readHeaderLine()
            total = checkedMultipartAdd(total, line.size + 2,
                MultipartErrorCode.HeaderLimitExceeded,
                "multipart part headers exceed configured byte limit")
            if (total > limits.maximumHeaderBytes) {
                fail(MultipartErrorCode.HeaderLimitExceeded,
                    "multipart part headers exceed configured byte limit")
            }
            if (line.isEmpty()) { return builder.build() }
            count += 1
            if (count > limits.maximumHeaderCount) {
                fail(MultipartErrorCode.HeaderLimitExceeded,
                    "multipart part header count exceeds configured limit")
            }
            var colon: Int64 = -1
            for (index in 0..line.size) {
                let value = line[index]
                if (value >= 128u8 || value == 0u8) {
                    fail(MultipartErrorCode.InvalidMetadata,
                        "multipart headers must use unambiguous ASCII metadata")
                }
                if (colon < 0 && value == b':') { colon = index }
            }
            if (colon <= 0) {
                fail(MultipartErrorCode.Malformed, "multipart header line has no field separator")
            }
            var valueStart = colon + 1
            while (valueStart < line.size &&
                (line[valueStart] == b' ' || line[valueStart] == b'\t')) { valueStart += 1 }
            var valueEnd = line.size
            while (valueEnd > valueStart &&
                (line[valueEnd - 1] == b' ' || line[valueEnd - 1] == b'\t')) { valueEnd -= 1 }
            try {
                let _ = builder.add(
                    String.fromUtf8(copyMultipartRange(line, 0, colon)),
                    String.fromUtf8(copyMultipartRange(line, valueStart, valueEnd))
                )
            } catch (_: IllegalArgumentException) {
                fail(MultipartErrorCode.InvalidMetadata, "multipart header metadata is invalid")
            }
        }
        builder.build()
    }

    private func readHeaderLine(): Array<Byte> {
        var scanned: Int64 = 0
        while (true) {
            var index = pendingOffset + scanned
            while (index < pending.size) {
                if (pending[index] == b'\n') {
                    if (index == pendingOffset || pending[index - 1] != b'\r') {
                        fail(MultipartErrorCode.Malformed,
                            "multipart headers require CRLF line endings")
                    }
                    let length = index - 1 - pendingOffset
                    if (length + 2 > limits.maximumHeaderBytes) {
                        fail(MultipartErrorCode.HeaderLimitExceeded,
                            "multipart header line exceeds configured byte limit")
                    }
                    let result = copyPending(length)
                    consume(length + 2)
                    return result
                }
                index += 1
            }
            scanned = available()
            if (scanned > limits.maximumHeaderBytes) {
                fail(MultipartErrorCode.HeaderLimitExceeded,
                    "multipart header line exceeds configured byte limit")
            }
            if (sourceEof) {
                fail(MultipartErrorCode.Malformed, "multipart headers are truncated")
            }
            fill()
        }
        Array<Byte>()
    }

    private func copyPartBytes(destination: Array<Byte>, availablePayload: Int64): Int64 {
        let count = min(destination.size, availablePayload)
        if (count > limits.maximumPartBytes - partBytes) {
            fail(MultipartErrorCode.PartBytesLimitExceeded,
                "multipart part exceeds configured byte limit")
        }
        for (index in 0..count) { destination[index] = pending[pendingOffset + index] }
        consume(count)
        partBytes += count
        count
    }

    private func findDelimiter(maximumStartDistance: Int64): Int64 {
        if (available() < delimiter.size) { return -1 }
        let lastPossible = pending.size - delimiter.size
        let requestedEnd = if (maximumStartDistance > Int64.Max - pendingOffset) {
            Int64.Max
        } else {
            pendingOffset + maximumStartDistance
        }
        let maximumStart = min(lastPossible, requestedEnd)
        let scanEnd = if (maximumStart > pending.size - delimiter.size) {
            pending.size
        } else {
            maximumStart + delimiter.size
        }
        var matched: Int64 = 0
        var index = pendingOffset
        while (index < scanEnd) {
            while (matched > 0 && pending[index] != delimiter[matched]) {
                matched = delimiterPrefix[matched - 1]
            }
            if (pending[index] == delimiter[matched]) { matched += 1 }
            if (matched == delimiter.size) { return index + 1 - delimiter.size }
            index += 1
        }
        -1
    }

    private func ensureAvailable(count: Int64): Unit {
        while (available() < count) {
            if (sourceEof) {
                fail(MultipartErrorCode.Malformed, "multipart body is truncated")
            }
            fill()
        }
    }

    private func fill(): Unit {
        checkContext()
        let remaining = limits.maximumBodyBytes - sourceBytes
        let capacity = if (remaining >= limits.readBufferBytes) {
            limits.readBufferBytes
        } else {
            remaining + 1
        }
        if (capacity <= 0) {
            fail(MultipartErrorCode.BodyBytesLimitExceeded,
                "multipart body exceeds configured byte limit")
        }
        let buffer = Array<Byte>(capacity, repeat: 0u8)
        let count = source.read(buffer)
        if (count < 0 || count > buffer.size) {
            fail(MultipartErrorCode.StreamFailure,
                "multipart source stream returned invalid progress")
        }
        if (count == 0) {
            sourceEof = true
            return
        }
        if (count > limits.maximumBodyBytes - sourceBytes) {
            fail(MultipartErrorCode.BodyBytesLimitExceeded,
                "multipart body exceeds configured byte limit")
        }
        sourceBytes += count
        compactPending()
        for (index in 0..count) { pending.add(buffer[index]) }
        checkContext()
    }

    private func compactPending(): Unit {
        if (pendingOffset == 0) { return }
        if (pendingOffset < limits.readBufferBytes && pendingOffset * 2 < pending.size) { return }
        let compacted = ArrayList<Byte>()
        for (index in pendingOffset..pending.size) { compacted.add(pending[index]) }
        pending = compacted
        pendingOffset = 0
    }

    private func available(): Int64 { pending.size - pendingOffset }

    private func consume(count: Int64): Unit {
        pendingOffset += count
        compactPending()
    }

    private func copyPending(count: Int64): Array<Byte> {
        let result = Array<Byte>(count, repeat: 0u8)
        for (index in 0..count) { result[index] = pending[pendingOffset + index] }
        result
    }

    private func ensureDecoderOpen(): Unit {
        if (closed) {
            throw MultipartException(MultipartErrorCode.Closed, "multipart reader is closed")
        }
    }

    private func ensureActive(expectedGeneration: Int64): Unit {
        ensureDecoderOpen()
        if (!activePart || generation != expectedGeneration) {
            throw MultipartException(MultipartErrorCode.Closed,
                "multipart part stream is no longer active")
        }
    }

    private func closeAtEnd(): Unit {
        if (!closed) {
            pending = ArrayList<Byte>()
            pendingOffset = 0
            while (!sourceEof) {
                fill()
                pending = ArrayList<Byte>()
                pendingOffset = 0
            }
            closed = true
            source.close()
        }
    }

    private func checkContext(): Unit {
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            fail(MultipartErrorCode.ContextStopped,
                "multipart operation context is cancelled or expired")
        }
    }

    private func fail(code: MultipartErrorCode, message: String,
        cause!: ?Exception = None<Exception>): Nothing {
        close()
        throw MultipartException(code, message, cause: cause)
    }
}

internal func boundaryFromMultipartContentType(value: String): String {
    let bytes = value.toArray()
    var index: Int64 = 0
    index = skipMultipartSpaces(bytes, index)
    let mediaStart = index
    while (index < bytes.size && bytes[index] != b';') { index += 1 }
    let mediaEnd = trimMultipartRight(bytes, mediaStart, index)
    let media = String.fromUtf8(copyMultipartRange(bytes, mediaStart, mediaEnd)).toAsciiLower()
    if (media != "multipart/form-data") {
        throw MultipartException(MultipartErrorCode.InvalidBoundary,
            "Content-Type is not multipart/form-data")
    }
    var boundary: ?String = None<String>
    while (index < bytes.size) {
        if (bytes[index] != b';') {
            throw MultipartException(MultipartErrorCode.InvalidBoundary,
                "multipart Content-Type parameter separator is invalid")
        }
        index += 1
        index = skipMultipartSpaces(bytes, index)
        let nameStart = index
        while (index < bytes.size && isMultipartTokenByte(bytes[index])) { index += 1 }
        let name = String.fromUtf8(copyMultipartRange(bytes, nameStart, index)).toAsciiLower()
        index = skipMultipartSpaces(bytes, index)
        if (name.isEmpty() || index >= bytes.size || bytes[index] != b'=') {
            throw MultipartException(MultipartErrorCode.InvalidBoundary,
                "multipart Content-Type parameter is invalid")
        }
        index += 1
        index = skipMultipartSpaces(bytes, index)
        let (parameter, nextIndex) = readMultipartParameter(bytes, index)
        index = nextIndex
        if (name == "boundary") {
            if (boundary.isSome()) {
                throw MultipartException(MultipartErrorCode.InvalidBoundary,
                    "multipart Content-Type has duplicate boundary parameters")
            }
            boundary = Some(parameter)
        }
        index = skipMultipartSpaces(bytes, index)
    }
    let result = boundary.getOrThrow({ => MultipartException(
        MultipartErrorCode.InvalidBoundary, "multipart Content-Type has no boundary parameter"
    ) })
    validateMultipartBoundary(result)
    result
}

private func parseContentDisposition(value: String): (String, ?String) {
    let bytes = value.toArray()
    var index: Int64 = 0
    index = skipMultipartSpaces(bytes, index)
    let kindStart = index
    while (index < bytes.size && bytes[index] != b';') { index += 1 }
    let kindEnd = trimMultipartRight(bytes, kindStart, index)
    if (String.fromUtf8(copyMultipartRange(bytes, kindStart, kindEnd)).toAsciiLower() != "form-data") {
        throw MultipartException(MultipartErrorCode.InvalidMetadata,
            "multipart Content-Disposition must be form-data")
    }
    var fieldName: ?String = None<String>
    var filename: ?String = None<String>
    while (index < bytes.size) {
        if (bytes[index] != b';') {
            throw MultipartException(MultipartErrorCode.InvalidMetadata,
                "multipart Content-Disposition parameter separator is invalid")
        }
        index += 1
        index = skipMultipartSpaces(bytes, index)
        let parameterStart = index
        while (index < bytes.size && isMultipartTokenByte(bytes[index])) { index += 1 }
        let parameterName = String.fromUtf8(
            copyMultipartRange(bytes, parameterStart, index)).toAsciiLower()
        index = skipMultipartSpaces(bytes, index)
        if (parameterName.isEmpty() || index >= bytes.size || bytes[index] != b'=') {
            throw MultipartException(MultipartErrorCode.InvalidMetadata,
                "multipart Content-Disposition parameter is invalid")
        }
        index += 1
        index = skipMultipartSpaces(bytes, index)
        let (parameterValue, nextIndex) = readMultipartParameter(bytes, index)
        index = nextIndex
        if (parameterName == "name") {
            if (fieldName.isSome()) {
                throw MultipartException(MultipartErrorCode.InvalidMetadata,
                    "multipart Content-Disposition has duplicate name parameters")
            }
            fieldName = Some(parameterValue)
        } else if (parameterName == "filename") {
            if (filename.isSome()) {
                throw MultipartException(MultipartErrorCode.InvalidMetadata,
                    "multipart Content-Disposition has duplicate filename parameters")
            }
            filename = Some(parameterValue)
        }
        index = skipMultipartSpaces(bytes, index)
    }
    let name = fieldName.getOrThrow({ => MultipartException(
        MultipartErrorCode.InvalidMetadata,
        "multipart Content-Disposition has no name parameter"
    ) })
    validateMultipartMetadata(name, "multipart field name", 256)
    if (let Some(file) <- filename) {
        validateMultipartMetadata(file, "multipart filename", 1024)
    }
    (name, filename)
}

private func readMultipartParameter(bytes: Array<Byte>, start: Int64): (String, Int64) {
    var index = start
    let output = ArrayList<Byte>()
    if (index < bytes.size && bytes[index] == b'\"') {
        index += 1
        var closed = false
        while (index < bytes.size) {
            let value = bytes[index]
            index += 1
            if (value == b'\"') { closed = true; break }
            if (value == b'\\') {
                if (index >= bytes.size) {
                    throw MultipartException(MultipartErrorCode.InvalidMetadata,
                        "multipart quoted parameter escape is truncated")
                }
                output.add(bytes[index])
                index += 1
            } else {
                output.add(value)
            }
        }
        if (!closed) {
            throw MultipartException(MultipartErrorCode.InvalidMetadata,
                "multipart quoted parameter is unterminated")
        }
    } else {
        while (index < bytes.size && bytes[index] != b';' &&
            bytes[index] != b' ' && bytes[index] != b'\t') {
            output.add(bytes[index])
            index += 1
        }
    }
    if (output.isEmpty()) {
        throw MultipartException(MultipartErrorCode.InvalidMetadata,
            "multipart parameter value must not be empty")
    }
    (String.fromUtf8(output.toArray()), index)
}

private func multipartEncodedLength(parts: Array<MultipartPart>, boundary: String,
    maximumBytes: Int64): ?Int64 {
    var total: Int64 = 0
    for (part in parts) {
        total = checkedMultipartAdd(total, multipartHeader(boundary, part).size,
            MultipartErrorCode.BodyBytesLimitExceeded,
            "multipart body framing exceeds configured byte limit")
        if (let Some(length) <- part.body.contentLength) {
            total = checkedMultipartAdd(total, length,
                MultipartErrorCode.BodyBytesLimitExceeded,
                "multipart body exceeds configured byte limit")
        } else {
            return None<Int64>
        }
        total = checkedMultipartAdd(total, 2,
            MultipartErrorCode.BodyBytesLimitExceeded,
            "multipart body framing exceeds configured byte limit")
        if (total > maximumBytes) {
            throw MultipartException(MultipartErrorCode.BodyBytesLimitExceeded,
                "multipart body exceeds configured byte limit")
        }
    }
    total = checkedMultipartAdd(total, multipartClosing(boundary).size,
        MultipartErrorCode.BodyBytesLimitExceeded,
        "multipart closing boundary exceeds configured byte limit")
    if (total > maximumBytes) {
        throw MultipartException(MultipartErrorCode.BodyBytesLimitExceeded,
            "multipart body exceeds configured byte limit")
    }
    Some(total)
}

private func multipartHeader(boundary: String, part: MultipartPart): Array<Byte> {
    var disposition = "Content-Disposition: form-data; name=\"${part.name}\""
    if (let Some(filename) <- part.filename) {
        disposition += "; filename=\"${filename}\""
    }
    ("--${boundary}\r\n${disposition}\r\n" +
        "Content-Type: ${part.contentType}\r\n\r\n").toArray()
}

private func multipartClosing(boundary: String): Array<Byte> {
    "--${boundary}--\r\n".toArray()
}

private func validateMultipartBoundary(value: String): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 70) {
        throw MultipartException(MultipartErrorCode.InvalidBoundary,
            "multipart boundary length is invalid")
    }
    for (byte in bytes) {
        let valid = (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'\'' || byte == b'(' ||
            byte == b')' || byte == b'+' || byte == b'_' || byte == b',' ||
            byte == b'-' || byte == b'.' || byte == b'/' || byte == b':' ||
            byte == b'=' || byte == b'?'
        if (!valid) {
            throw MultipartException(MultipartErrorCode.InvalidBoundary,
                "multipart boundary contains an unsafe byte")
        }
    }
}

private func validateMultipartMetadata(value: String, kind: String, maximumBytes: Int64): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > maximumBytes) {
        throw MultipartException(MultipartErrorCode.InvalidMetadata,
            "${kind} length is invalid")
    }
    for (byte in bytes) {
        if (byte < 0x20u8 || byte >= 0x7fu8 || byte == b'\"' || byte == b'\\') {
            throw MultipartException(MultipartErrorCode.InvalidMetadata,
                "${kind} contains an unsafe byte")
        }
    }
}

private func validateMultipartContentType(value: String): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 256) {
        throw MultipartException(MultipartErrorCode.InvalidMetadata,
            "multipart content type length is invalid")
    }
    for (byte in bytes) {
        if (byte < 0x20u8 || byte >= 0x7fu8 || byte == b'\r' || byte == b'\n') {
            throw MultipartException(MultipartErrorCode.InvalidMetadata,
                "multipart content type contains an unsafe byte")
        }
    }
}

private func checkedMultipartAdd(left: Int64, right: Int64,
    code: MultipartErrorCode, message: String): Int64 {
    if (right < 0 || left > Int64.Max - right) {
        throw MultipartException(code, message)
    }
    left + right
}

private func copyMultipartRange(bytes: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let result = Array<Byte>(end - start, repeat: 0u8)
    for (index in start..end) { result[index - start] = bytes[index] }
    result
}

private func multipartPrefixTable(value: Array<Byte>): Array<Int64> {
    let result = Array<Int64>(value.size, repeat: 0)
    var matched: Int64 = 0
    var index: Int64 = 1
    while (index < value.size) {
        while (matched > 0 && value[index] != value[matched]) {
            matched = result[matched - 1]
        }
        if (value[index] == value[matched]) { matched += 1 }
        result[index] = matched
        index += 1
    }
    result
}


private func skipMultipartSpaces(bytes: Array<Byte>, start: Int64): Int64 {
    var index = start
    while (index < bytes.size && (bytes[index] == b' ' || bytes[index] == b'\t')) { index += 1 }
    index
}

private func trimMultipartRight(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var result = end
    while (result > start && (bytes[result - 1] == b' ' || bytes[result - 1] == b'\t')) { result -= 1 }
    result
}

private func isMultipartTokenByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'!' || value == b'#' ||
        value == b'$' || value == b'%' || value == b'&' || value == b'\'' ||
        value == b'*' || value == b'+' || value == b'-' || value == b'.' ||
        value == b'^' || value == b'_' || value == b'`' || value == b'|' || value == b'~'
}
