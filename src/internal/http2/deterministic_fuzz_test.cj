package wirestack.internal.http2

import std.env.getVariable
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Http2DeterministicFuzzTest {
    @TestCase
    func frameParserDeterministicMutationCorpusStaysBounded(): Unit {
        let seeds: Array<Array<Byte>> = [
            m7023Http2Seed("http2-frame", serializeHttp2Frame(encodeHttp2Settings([]))),
            serializeHttp2Frame(encodeHttp2Ping([0u8, 1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8])),
            serializeHttp2Frame(encodeHttp2RstStream(Http2StreamId(1u32), Http2ErrorCode.Cancel)),
            serializeHttp2Frame(encodeHttp2WindowUpdate(Http2StreamId(1u32), 1u32)),
            serializeHttp2Frame(encodeHttp2GoAway(
                Http2GoAway(Http2StreamId(1u32), Http2ErrorCode.NoError, [1u8, 2u8])
            ))
        ]
        var executions: Int64 = 0
        for (seed in seeds) {
            runFrameMutation(seed)
            executions += 1
            for (index in 0..seed.size) {
                for (mask in [0x01u8, 0x20u8, 0x80u8]) {
                    let mutated = seed.clone()
                    mutated[index] = mutated[index] ^ mask
                    runFrameMutation(mutated)
                    executions += 1
                }
            }
            for (length in 0..seed.size) {
                runFrameMutation(copyPrefix(seed, length))
                executions += 1
            }
        }
        @Expect(executions > 200)
        println(
            "M7023_FUZZ target=http2-frame seed=7023 " +
            "iterations=${executions} decision=PASS"
        )
    }

    @TestCase
    func hpackDecoderDeterministicMutationCorpusFailsClosed(): Unit {
        let seeds: Array<Array<Byte>> = [
            m7023Http2Seed("hpack-decoder", [0x82u8]),
            [0x82u8, 0x86u8, 0x84u8],
            fuzzHexBytes("828684410f7777772e6578616d706c652e636f6d"),
            fuzzHexBytes("828684be58086e6f2d6361636865"),
            fuzzHexBytes("828684418cf1e3c2e5f23a6ba0ab90f4ff")
        ]
        var executions: Int64 = 0
        for (seed in seeds) {
            runHpackMutation(seed)
            executions += 1
            for (index in 0..seed.size) {
                for (mask in [0x01u8, 0x08u8, 0x40u8, 0x80u8]) {
                    let mutated = seed.clone()
                    mutated[index] = mutated[index] ^ mask
                    runHpackMutation(mutated)
                    executions += 1
                }
            }
            for (length in 0..seed.size) {
                runHpackMutation(copyPrefix(seed, length))
                executions += 1
            }
        }
        @Expect(executions > 250)
        println(
            "M7023_FUZZ target=hpack-decoder seed=7023 " +
            "iterations=${executions} decision=PASS"
        )
    }

    @TestCase
    func protocolLimitBoundaryMutationsRejectOversizedInputs(): Unit {
        let parser = Http2FrameParser()
        let oversizedHeader: Array<Byte> = [0x00u8, 0x40u8, 0x01u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x01u8]
        expectFuzzProtocolFailure({ => let _ = parser.feed(oversizedHeader) })

        let blockLimit = Http2Limits(maxHeaderBlockBytes: 1u32)
        expectFuzzHpackFailure({ => let _ = HpackDecoder(limits: blockLimit).decode([0x82u8, 0x84u8]) })

        let fieldLimit = Http2Limits(maxHeaderFields: 1u32)
        expectFuzzHpackFailure({ => let _ = HpackDecoder(limits: fieldLimit).decode([0x82u8, 0x84u8]) })

        let listLimit = Http2Limits(maxHeaderListBytes: 33u32)
        expectFuzzHpackFailure({ => let _ = HpackDecoder(limits: listLimit).decode([0x82u8]) })

        let tableLimit = Http2Limits(maxHeaderTableBytes: 0u32)
        expectFuzzHpackFailure({ => let _ = HpackDecoder(limits: tableLimit).decode([0x21u8]) })
    }
}

private func m7023Http2Seed(target: String, fallback: Array<Byte>): Array<Byte> {
    match (getVariable("WIRESTACK_M7_023_TARGET")) {
        case None => fallback
        case Some(actual) =>
            if (actual != target) {
                throw IllegalStateException("M7-023 target mismatch: ${actual}")
            }
            match (getVariable("WIRESTACK_M7_023_CORPUS_HEX")) {
                case Some(value) => m7023Http2Hex(value)
                case None => throw IllegalStateException("missing M7-023 corpus")
            }
    }
}

private func m7023Http2Hex(value: String): Array<Byte> {
    let input = value.toArray()
    var digits: Int64 = 0
    for (byte in input) { if (byte > 32u8) { digits++ } }
    if (digits == 0 || digits % 2 != 0) {
        throw IllegalArgumentException("invalid M7-023 hex corpus")
    }
    let output = Array<Byte>(digits / 2, repeat: 0u8)
    var high: ?Byte = None<Byte>
    var index: Int64 = 0
    for (byte in input) {
        if (byte <= 32u8) { continue }
        let nibble = m7023Http2Nibble(byte)
        match (high) {
            case None => high = Some(nibble)
            case Some(value) =>
                output[index] = (value << 4) | nibble
                index++
                high = None<Byte>
        }
    }
    output
}

private func m7023Http2Nibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else if (value >= b'A' && value <= b'F') { value - b'A' + 10u8 }
    else { throw IllegalArgumentException("invalid M7-023 hex digit") }
}

private func runFrameMutation(input: Array<Byte>): Unit {
    let parser = Http2FrameParser()
    var produced: Int64 = 0
    try {
        for (value in input) {
            let frames = parser.feed([value])
            produced += frames.size
            @Expect(produced <= 1)
            for (frame in frames) { @Expect(serializeHttp2Frame(frame).size <= 16393) }
        }
    } catch (_: Http2ProtocolException) {}
}

private func runHpackMutation(input: Array<Byte>): Unit {
    try {
        let fields = HpackDecoder(limits: Http2Limits(
            maxHeaderTableBytes: 128u32,
            maxHeaderListBytes: 512u32,
            maxHeaderBlockBytes: 128u32,
            maxHeaderFields: 8u32
        )).decode(input)
        @Expect(fields.size <= 8)
    } catch (_: HpackException) {}
}

private func copyPrefix(input: Array<Byte>, length: Int64): Array<Byte> {
    let output = Array<Byte>(length, repeat: 0u8)
    for (index in 0..length) { output[index] = input[index] }
    output
}

private func expectFuzzProtocolFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: Http2ProtocolException) { rejected = true }
    @Expect(rejected)
}

private func expectFuzzHpackFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: HpackException) { rejected = true }
    @Expect(rejected)
}

private func fuzzHexBytes(value: String): Array<Byte> {
    let input = value.toArray()
    let output = Array<Byte>(input.size / 2, repeat: 0u8)
    for (index in 0..output.size) {
        output[index] = (fuzzNibble(input[index * 2]) << 4) | fuzzNibble(input[index * 2 + 1])
    }
    output
}

private func fuzzNibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else { throw IllegalArgumentException("invalid hex fixture") }
}
