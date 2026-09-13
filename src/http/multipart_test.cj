package wirestack.http

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MultipartTest {
    @TestCase
    func writerStreamsExactBinaryFramingAndReplaysIndependently(): Unit {
        let writer = MultipartWriter("wirestack-boundary")
            .add(MultipartPart("text", "value".toArray(), contentType: "text/plain"))
            .add(MultipartPart("file", [0u8, 255u8, 13u8, 10u8, 1u8],
                filename: Some("bytes.bin")))
        let body = writer.body(maximumBytes: 4096)

        @Expect(body.replayability, BodyReplayability.Replayable)
        let first = readMultipartStream(body.open(), 3)
        let second = readMultipartStream(body.open(), 7)
        @Expect(first, second)
        @Expect(first, joinMultipartBytes([
            "--wirestack-boundary\r\n".toArray(),
            "Content-Disposition: form-data; name=\"text\"\r\n".toArray(),
            "Content-Type: text/plain\r\n\r\n".toArray(),
            "value\r\n".toArray(),
            "--wirestack-boundary\r\n".toArray(),
            "Content-Disposition: form-data; name=\"file\"; filename=\"bytes.bin\"\r\n".toArray(),
            "Content-Type: application/octet-stream\r\n\r\n".toArray(),
            [0u8, 255u8, 13u8, 10u8, 1u8],
            "\r\n--wirestack-boundary--\r\n".toArray()
        ]))
    }

    @TestCase
    func boundarySeparatorsRoundtripThroughContentTypeAndBody(): Unit {
        let writer = MultipartWriter("upload:part/with=separators?")
            .add(MultipartPart("field", "value".toArray()))
        @Expect(writer.contentType(), "multipart/form-data; boundary=\"upload:part/with=separators?\"")
        let reader = MultipartReader(ResponseBody(writer.body().open()),
            boundaryFromMultipartContentType(writer.contentType()))
        try {
            let part = reader.next().getOrThrow()
            @Expect(readMultipartStream(part.body, 3), "value".toArray())
            part.close()
            @Expect(reader.next().isNone())
        } finally { reader.close() }
    }

    @TestCase
    func readerPreservesBinaryWhenEveryDelimiterIsSplitAcrossReads(): Unit {
        let encoded = joinMultipartBytes([
            "--b123\r\n".toArray(),
            "Content-Disposition: form-data; name=\"first\"\r\n\r\n".toArray(),
            [0u8, 1u8, 13u8, 10u8],
            "--b123X".toArray(),
            [255u8],
            "\r\n--b123\r\n".toArray(),
            "Content-Disposition: form-data; name=\"second\"; filename=\"x.bin\"\r\n".toArray(),
            "Content-Type: application/octet-stream\r\n\r\n".toArray(),
            [9u8, 8u8, 7u8],
            "\r\n--b123--\r\n".toArray()
        ])
        let response = ResponseBody(SplitMultipartStream(encoded, 1))
        let reader = MultipartReader(response, "b123", limits: MultipartLimits(
            maximumPartBytes: 1024,
            maximumBodyBytes: 4096,
            readBufferBytes: 4
        ))

        let first = reader.next().getOrThrow()
        @Expect(first.name, "first")
        @Expect(first.filename.isNone())
        @Expect(readMultipartStream(first.body, 2), joinMultipartBytes([
            [0u8, 1u8, 13u8, 10u8],
            "--b123X".toArray(),
            [255u8]
        ]))
        first.close()

        let second = reader.next().getOrThrow()
        @Expect(second.name, "second")
        @Expect(second.filename, Some("x.bin"))
        @Expect(readMultipartStream(second.body, 2), [9u8, 8u8, 7u8])
        second.close()
        @Expect(reader.next().isNone())
        @Expect(reader.isClosed())
    }

    @TestCase
    func closingPartDiscardsOnlyThatPartAndReleasesNextPart(): Unit {
        let encoded = MultipartWriter("discard-boundary")
            .add(MultipartPart("discard", Array<Byte>(257, { index => UInt8(index % 251) })))
            .add(MultipartPart("keep", "kept".toArray()))
            .body(maximumBytes: 4096)
        let reader = MultipartReader(ResponseBody(encoded.open()), "discard-boundary",
            limits: MultipartLimits(maximumPartBytes: 1024, maximumBodyBytes: 4096,
                readBufferBytes: 8))

        let discarded = reader.next().getOrThrow()
        let prefix = Array<Byte>(3, repeat: 0u8)
        @Expect(discarded.body.read(prefix), 3)
        let activeError = @AssertThrows[MultipartException](reader.next())
        @Expect(activeError.code, MultipartErrorCode.ActivePart)
        discarded.close()

        let kept = reader.next().getOrThrow()
        @Expect(readMultipartStream(kept.body, 1), "kept".toArray())
        kept.close()
        @Expect(reader.next().isNone())
    }

    @TestCase
    func malformedAndConfiguredLimitsCloseOwnedSource(): Unit {
        let malformedResponse = ResponseBody(SplitMultipartStream(
            "--bad\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\npayload".toArray(), 2
        ))
        let malformed = MultipartReader(malformedResponse, "bad", limits: MultipartLimits(
            maximumPartBytes: 64,
            maximumBodyBytes: 256,
            readBufferBytes: 4
        ))
        let part = malformed.next().getOrThrow()
        @AssertThrows[MultipartException](readMultipartStream(part.body, 3))
        @Expect(malformedResponse.isClosed())

        let oversizedResponse = ResponseBody(SplitMultipartStream(Array<Byte>(65, repeat: 1u8), 4))
        let error = @AssertThrows[MultipartException](MultipartReader(
            oversizedResponse,
            "b",
            limits: MultipartLimits(maximumPartBytes: 32, maximumBodyBytes: 64,
                readBufferBytes: 4)
        ))
        @Expect(error.code, MultipartErrorCode.BodyBytesLimitExceeded)
        @Expect(oversizedResponse.isClosed())
    }

    @TestCase
    func partCountLimitRejectsBeforeParsingUnboundedAdditionalMetadata(): Unit {
        let body = MultipartWriter("count-boundary")
            .add(MultipartPart("one", "1".toArray()))
            .add(MultipartPart("two", "2".toArray()))
            .body(maximumBytes: 4096)
        let reader = MultipartReader(ResponseBody(body.open()), "count-boundary",
            limits: MultipartLimits(maximumParts: 1, maximumPartBytes: 64,
                maximumBodyBytes: 4096, readBufferBytes: 4))
        let first = reader.next().getOrThrow()
        @Expect(readMultipartStream(first.body, 1), "1".toArray())
        first.close()
        let error = @AssertThrows[MultipartException](reader.next())
        @Expect(error.code, MultipartErrorCode.PartLimitExceeded)
        @Expect(reader.isClosed())
    }

    @TestCase
    func boundedDeterministicWireMutationsAreChunkIndependent(): Unit {
        let replacements: Array<Byte> = [
            0u8, 9u8, 10u8, 13u8, 34u8, 45u8, 59u8, 127u8, 255u8
        ]
        var cases: Int64 = 0
        var accepted: Int64 = 0
        var rejected: Int64 = 0
        var truncations: Int64 = 0
        var deletions: Int64 = 0
        var byteMutations: Int64 = 0
        var delimiterPaddings: Int64 = 0
        var boundaryMutations: Int64 = 0

        for (seed in m8005MultipartSeeds()) {
            let baseline = m8005AssertChunkIndependent(seed.wire, seed.boundary)
            m8005ExpectAccepted(baseline, seed.expected)
            cases++
            accepted++

            for (length in 0..seed.wire.size) {
                let observed = m8005AssertChunkIndependent(
                    m8005MultipartPrefix(seed.wire, length), seed.boundary)
                cases++
                truncations++
                if (observed.terminal.isNone()) { accepted++ } else { rejected++ }
            }
            for (index in 0..seed.wire.size) {
                let observed = m8005AssertChunkIndependent(
                    m8005MultipartDelete(seed.wire, index), seed.boundary)
                cases++
                deletions++
                if (observed.terminal.isNone()) { accepted++ } else { rejected++ }
                for (replacement in replacements) {
                    if (seed.wire[index] == replacement) { continue }
                    let mutated = seed.wire.clone()
                    mutated[index] = replacement
                    let replaced = m8005AssertChunkIndependent(mutated, seed.boundary)
                    cases++
                    byteMutations++
                    if (replaced.terminal.isNone()) { accepted++ } else { rejected++ }
                }
            }

            let delimiter = "--${seed.boundary}".toArray()
            for (index in m8005MultipartOccurrences(seed.wire, delimiter)) {
                for (padding in [b' ', b'\t']) {
                    let observed = m8005AssertChunkIndependent(
                        m8005MultipartInsert(seed.wire, index + delimiter.size, padding),
                        seed.boundary
                    )
                    cases++
                    delimiterPaddings++
                    if (observed.terminal.isNone()) { accepted++ } else { rejected++ }
                }
            }

            let longBoundary = String.fromUtf8(Array<Byte>(71, repeat: b'a'))
            for (boundary in [
                "", "${seed.boundary}x", "bad boundary", "bad\u{007f}", longBoundary, "aaaaaa?"
            ]) {
                let observed = m8005AssertChunkIndependent(seed.wire, boundary)
                cases++
                boundaryMutations++
                if (observed.terminal.isNone()) { accepted++ } else { rejected++ }
            }
        }

        println(
            "M8005_FUZZ target=multipart seeds=2 schedules=4 replacements=${replacements.size} " +
            "truncations=${truncations} deletions=${deletions} byte_mutations=${byteMutations} " +
            "delimiter_padding=${delimiterPaddings} boundary_inputs=${boundaryMutations} " +
            "cases=${cases} executions=${cases * 4} accepted=${accepted} rejected=${rejected} " +
            "decision=PASS"
        )
    }

    @TestCase
    func deterministicMutationHarnessEnforcesSmallLimitsAndOwnedClosure(): Unit {
        let limits = m8005MultipartLimits()
        let payloadLimited = joinMultipartBytes([
            "--limit\r\nContent-Disposition: form-data; name=\"payload\"\r\n\r\n".toArray(),
            Array<Byte>(97, repeat: 1u8),
            "\r\n--limit--\r\n".toArray()
        ])
        @Expect(
            m8005AssertChunkIndependentWithLimits(payloadLimited, "limit", limits).terminal,
            Some(MultipartErrorCode.PartBytesLimitExceeded)
        )

        let headerLimited = joinMultipartBytes([
            "--limit\r\nContent-Disposition: form-data; name=\"headers\"\r\nX-Pad: ".toArray(),
            Array<Byte>(193, repeat: b'a'),
            "\r\n\r\nx\r\n--limit--\r\n".toArray()
        ])
        @Expect(
            m8005AssertChunkIndependentWithLimits(headerLimited, "limit", limits).terminal,
            Some(MultipartErrorCode.HeaderLimitExceeded)
        )

        let tooManyParts = joinMultipartBytes([
            "--limit\r\nContent-Disposition: form-data; name=\"one\"\r\n\r\n1\r\n".toArray(),
            "--limit\r\nContent-Disposition: form-data; name=\"two\"\r\n\r\n2\r\n".toArray(),
            "--limit\r\nContent-Disposition: form-data; name=\"three\"\r\n\r\n3\r\n".toArray(),
            "--limit\r\nContent-Disposition: form-data; name=\"four\"\r\n\r\n4\r\n".toArray(),
            "--limit--\r\n".toArray()
        ])
        @Expect(
            m8005AssertChunkIndependentWithLimits(tooManyParts, "limit", limits).terminal,
            Some(MultipartErrorCode.PartLimitExceeded)
        )

        @Expect(
            m8005AssertChunkIndependentWithLimits(
                Array<Byte>(513, repeat: 1u8), "limit", limits
            ).terminal,
            Some(MultipartErrorCode.BodyBytesLimitExceeded)
        )

        println(
            "M8005_FUZZ target=multipart corpus=limits cases=4 schedules=4 " +
            "executions=16 decision=PASS"
        )
    }

}

private class SplitMultipartStream <: HttpBodyStream {
    private let bytes: Array<Byte>
    private let maximumRead: Int64
    private let maximumReads: Int64
    private var offset: Int64 = 0
    private var reads: Int64 = 0
    private var closed = false

    init(bytes: Array<Byte>, maximumRead: Int64, maximumReads!: Int64 = 4096) {
        if (maximumRead <= 0 || maximumReads <= 0) {
            throw IllegalArgumentException("multipart test read bounds must be positive")
        }
        this.bytes = bytes.clone()
        this.maximumRead = maximumRead
        this.maximumReads = maximumReads
    }

    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }

    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "test stream is closed") }
        if (destination.isEmpty()) { return 0 }
        reads++
        if (reads > maximumReads) {
            throw IllegalStateException("multipart test source exceeded its finite read budget")
        }
        if (offset == bytes.size) { return 0 }
        let count = min(destination.size, min(maximumRead, bytes.size - offset))
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }

    prop readCalls: Int64 { get() { reads } }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func joinMultipartBytes(parts: Array<Array<Byte>>): Array<Byte> {
    let output = ArrayList<Byte>()
    for (part in parts) {
        for (byte in part) { output.add(byte) }
    }
    output.toArray()
}

private func readMultipartStream(stream: HttpBodyStream, chunkSize: Int64,
    maximumReads!: Int64 = 8192): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(chunkSize, repeat: 0u8)
    var reads: Int64 = 0
    try {
        while (true) {
            reads++
            if (reads > maximumReads) {
                @Fail("multipart test payload exceeded its finite read budget")
            }
            let count = stream.read(buffer)
            if (count == 0) { break }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        output.toArray()
    } finally {
        stream.close()
    }
}

private class M8005MultipartObservedPart {
    let name: String
    let filename: ?String
    let contentType: String
    let headers: Array<HttpHeader>
    let payload: Array<Byte>

    init(name: String, filename: ?String, contentType: String,
        headers: Array<HttpHeader>, payload: Array<Byte>) {
        this.name = name
        this.filename = filename
        this.contentType = contentType
        this.headers = headers
        this.payload = payload
    }
}

private class M8005MultipartOutcome {
    let parts: Array<M8005MultipartObservedPart>
    let terminal: ?MultipartErrorCode

    init(parts: Array<M8005MultipartObservedPart>, terminal: ?MultipartErrorCode) {
        this.parts = parts
        this.terminal = terminal
    }
}

private class M8005MultipartSeed {
    let boundary: String
    let wire: Array<Byte>
    let expected: Array<M8005MultipartObservedPart>

    init(boundary: String, wire: Array<Byte>,
        expected: Array<M8005MultipartObservedPart>) {
        this.boundary = boundary
        this.wire = wire
        this.expected = expected
    }
}

private func m8005MultipartLimits(): MultipartLimits {
    MultipartLimits(
        maximumParts: 3,
        maximumHeaderBytes: 192,
        maximumHeaderCount: 4,
        maximumPartBytes: 96,
        maximumBodyBytes: 512,
        readBufferBytes: 11
    )
}

private func m8005AssertChunkIndependent(wire: Array<Byte>,
    boundary: String): M8005MultipartOutcome {
    m8005AssertChunkIndependentWithLimits(wire, boundary, m8005MultipartLimits())
}

private func m8005AssertChunkIndependentWithLimits(wire: Array<Byte>, boundary: String,
    limits: MultipartLimits): M8005MultipartOutcome {
    let expected = m8005ObserveMultipart(wire, boundary, 1, limits)
    for (chunkSize in [2, 7, max(wire.size, 1)]) {
        let actual = m8005ObserveMultipart(wire, boundary, chunkSize, limits)
        m8005ExpectSameMultipartOutcome(actual, expected)
    }
    expected
}

private func m8005ObserveMultipart(wire: Array<Byte>, boundary: String,
    sourceChunkSize: Int64, limits: MultipartLimits): M8005MultipartOutcome {
    let source = SplitMultipartStream(wire, sourceChunkSize, maximumReads: 1024)
    let response = ResponseBody(source)
    let observed = ArrayList<M8005MultipartObservedPart>()
    var reader = None<MultipartReader>
    var terminal = None<MultipartErrorCode>
    try {
        let opened = MultipartReader(response, boundary, limits: limits)
        reader = Some(opened)
        var finished = false
        while (!finished) {
            match (opened.next()) {
                case Some(part) =>
                    let headers = part.headers.entries
                    let payload = readMultipartStream(part.body, 5, maximumReads: 128)
                    observed.add(M8005MultipartObservedPart(
                        part.name, part.filename, part.contentType, headers, payload
                    ))
                case None => finished = true
            }
        }
        @Assert(response.isClosed())
    } catch (error: MultipartException) {
        if (error.code == MultipartErrorCode.StreamFailure) {
            @Fail("multipart mutation reached an unexpected stream failure")
        }
        if (response.isClosed()) {
            @Assert(reader.isSome() || error.code == MultipartErrorCode.BodyBytesLimitExceeded)
        } else {
            @Assert(reader.isNone())
            @Assert(error.code, MultipartErrorCode.InvalidBoundary)
            @Assert(source.readCalls, 0)
        }
        terminal = Some(error.code)
    } finally {
        match (reader) {
            case Some(value) => value.close()
            case None => response.close()
        }
    }
    @Assert(source.readCalls <= 1024)
    M8005MultipartOutcome(observed.toArray(), terminal)
}

private func m8005ExpectSameMultipartOutcome(actual: M8005MultipartOutcome,
    expected: M8005MultipartOutcome): Unit {
    @Assert(actual.terminal, expected.terminal)
    @Assert(actual.parts.size, expected.parts.size)
    for (index in 0..expected.parts.size) {
        let left = actual.parts[index]
        let right = expected.parts[index]
        @Assert(left.name, right.name)
        @Assert(left.filename, right.filename)
        @Assert(left.contentType, right.contentType)
        @Assert(left.headers.size, right.headers.size)
        for (headerIndex in 0..right.headers.size) {
            @Assert(left.headers[headerIndex].name, right.headers[headerIndex].name)
            @Assert(left.headers[headerIndex].value, right.headers[headerIndex].value)
        }
        @Assert(left.payload, right.payload)
    }
}

private func m8005ExpectAccepted(actual: M8005MultipartOutcome,
    expected: Array<M8005MultipartObservedPart>): Unit {
    @Assert(actual.terminal.isNone())
    m8005ExpectSameMultipartOutcome(
        actual, M8005MultipartOutcome(expected, None<MultipartErrorCode>)
    )
}

private func m8005MultipartSeeds(): Array<M8005MultipartSeed> {
    let firstPayload = joinMultipartBytes([
        [0u8, 255u8, 1u8],
        "\r\n--abababX\r\n--ababa".toArray(),
        [13u8, 0u8, 2u8]
    ])
    let firstWire = joinMultipartBytes([
        "--ababab\r\n".toArray(),
        "Content-Disposition: form-data; name=\"alpha\"\r\n".toArray(),
        "X-Trace: one\r\n\r\n".toArray(),
        firstPayload,
        "\r\n--ababab\r\n".toArray(),
        "Content-Disposition: form-data; name=\"file\"; filename=\"raw.bin\"\r\n".toArray(),
        "Content-Type: application/octet-stream\r\n\r\n".toArray(),
        [9u8, 8u8, 7u8, 0u8, 255u8],
        "\r\n--ababab--\r\n".toArray()
    ])
    let firstExpected = [
        M8005MultipartObservedPart(
            "alpha", None<String>, "application/octet-stream",
            [
                HttpHeader("Content-Disposition", "form-data; name=\"alpha\""),
                HttpHeader("X-Trace", "one")
            ],
            firstPayload
        ),
        M8005MultipartObservedPart(
            "file", Some("raw.bin"), "application/octet-stream",
            [
                HttpHeader(
                    "Content-Disposition",
                    "form-data; name=\"file\"; filename=\"raw.bin\""
                ),
                HttpHeader("Content-Type", "application/octet-stream")
            ],
            [9u8, 8u8, 7u8, 0u8, 255u8]
        )
    ]

    let secondPayload = joinMultipartBytes([
        "left".toArray(),
        "\r\n--aabaaab-\r\n--aabaaa\r\n--aabaa".toArray(),
        [0u8, 254u8]
    ])
    let secondWire = joinMultipartBytes([
        "--aabaaab\r\n".toArray(),
        "content-disposition: form-data; name=\"left\"\r\n".toArray(),
        "Content-Type: text/plain\r\n\r\n".toArray(),
        secondPayload,
        "\r\n--aabaaab\r\n".toArray(),
        "Content-Disposition: form-data; name=\"right\"; filename=\"r.dat\"\r\n\r\n".toArray(),
        [128u8, 64u8, 0u8, 13u8, 10u8, 3u8],
        "\r\n--aabaaab--\r\n".toArray()
    ])
    let secondExpected = [
        M8005MultipartObservedPart(
            "left", None<String>, "text/plain",
            [
                HttpHeader("content-disposition", "form-data; name=\"left\""),
                HttpHeader("Content-Type", "text/plain")
            ],
            secondPayload
        ),
        M8005MultipartObservedPart(
            "right", Some("r.dat"), "application/octet-stream",
            [
                HttpHeader(
                    "Content-Disposition",
                    "form-data; name=\"right\"; filename=\"r.dat\""
                )
            ],
            [128u8, 64u8, 0u8, 13u8, 10u8, 3u8]
        )
    ]

    [
        M8005MultipartSeed("ababab", firstWire, firstExpected),
        M8005MultipartSeed("aabaaab", secondWire, secondExpected)
    ]
}

private func m8005MultipartPrefix(bytes: Array<Byte>, length: Int64): Array<Byte> {
    let output = Array<Byte>(length, repeat: 0u8)
    for (index in 0..length) { output[index] = bytes[index] }
    output
}

private func m8005MultipartDelete(bytes: Array<Byte>, removed: Int64): Array<Byte> {
    let output = ArrayList<Byte>()
    for (index in 0..bytes.size) {
        if (index != removed) { output.add(bytes[index]) }
    }
    output.toArray()
}

private func m8005MultipartInsert(bytes: Array<Byte>, insertion: Int64,
    value: Byte): Array<Byte> {
    let output = ArrayList<Byte>()
    for (index in 0..bytes.size) {
        if (index == insertion) { output.add(value) }
        output.add(bytes[index])
    }
    if (insertion == bytes.size) { output.add(value) }
    output.toArray()
}

private func m8005MultipartOccurrences(bytes: Array<Byte>,
    needle: Array<Byte>): Array<Int64> {
    let output = ArrayList<Int64>()
    if (needle.isEmpty() || needle.size > bytes.size) { return output.toArray() }
    for (index in 0..(bytes.size - needle.size + 1)) {
        if (m8005MultipartStartsAt(bytes, needle, index)) { output.add(index) }
    }
    output.toArray()
}

private func m8005MultipartStartsAt(bytes: Array<Byte>, needle: Array<Byte>,
    start: Int64): Bool {
    for (index in 0..needle.size) {
        if (bytes[start + index] != needle[index]) { return false }
    }
    true
}
