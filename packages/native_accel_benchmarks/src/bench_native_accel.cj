package yjson_native_accel_benchmarks

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_native_accel.*

main(): Unit {}

@OverflowWrapping
private func fnv1a64Step(hash: UInt64, byte: Byte): UInt64 {
    (hash ^ UInt64(byte)) * 0x100000001b3u64
}

/// FNV-1a 64 over the produced artifact bytes; hex digits are ASCII-encoded so
/// the digest line is pure UTF-8 and reproducible across engines.
private func fnv1a64Hex(bytes: Array<Byte>): String {
    var hash: UInt64 = 0xcbf29ce484222325u64
    for (byte in bytes) { hash = fnv1a64Step(hash, byte) }
    let out = Array<Byte>(16, repeat: 0u8)
    for (index in 0..16) {
        let nibble = Int64((hash >> (60 - index * 4)) & 0xFu64)
        out[index] = if (nibble < 10) { UInt8(nibble + 48) } else { UInt8(nibble + 87) }
    }
    String.fromUtf8(out)
}

private func fnv1a64Hex(text: String): String {
    fnv1a64Hex(unsafe { text.rawData() })
}

private func configureAccelerationMode(): Unit {
    let mode = match (getVariable("YJSON_ACCEL_MODE")) {
        case Some(value) => value
        case None => throw Exception("YJSON_ACCEL_MODE must be pure or native")
    }
    match (mode) {
        case "pure" => ()
        case "native" => YJsonNativeAccel.initialize()
        case _ => throw Exception("YJSON_ACCEL_MODE must be pure or native")
    }
}

@Test
@Configure[
    warmup: Duration.second,
    minDuration: Duration.second * 3,
    minBatches: 20
]
class NativeAccelerationBenchmarks {
    let escapedValues = ArrayList<String>()
    let numericValues = ArrayList<Int64>()
    let numericText: String
    let plainValues = ArrayList<String>()
    let escapedCodec = JsonCodecs.arrayList(JsonCodecs.string)
    let numericCodec = JsonCodecs.arrayList(JsonCodecs.int64)
    var stringSink = ""
    var bytesSink: Array<Byte> = Array<Byte>(0, repeat: 0u8)
    var intSink: Int64 = 0

    init() {
        configureAccelerationMode()
        let escaped = "0123456789012345678901234567890123456789012345678901234567890123\n\"\\<中🙂"
        for (_ in 0..1024) { escapedValues.add(escaped) }
        for (index in 0..16384) { numericValues.add(index * 17 - 12345) }
        for (index in 0..1024) { plainValues.add("plain-${index}-abcdefghijklmnopqrstuvwxyz") }
        numericText = YJson.toJson(numericValues)
        if (YJson.fromJson<ArrayList<Int64>>(numericText).size != numericValues.size) {
            throw Exception("Native acceleration benchmark fixture validation failed")
        }
        // Deterministic content checksum for every workload. Computed once per
        // process in init(), outside the measured region, so timings are not
        // polluted by digest work. The runner binds each raw report to these
        // lines (stdout contract: `CHECKSUM <case> <fnv1a-64-hex>`).
        println("CHECKSUM writeEscapedStrings ${fnv1a64Hex(YJson.toJson(escapedValues))}")
        println("CHECKSUM writeEscapedBytes ${fnv1a64Hex(YJson.toJsonBytes(escapedValues, codec: escapedCodec))}")
        println("CHECKSUM writeNumericArray ${fnv1a64Hex(YJson.toJson(numericValues))}")
        println("CHECKSUM writeNumericBytes ${fnv1a64Hex(YJson.toJsonBytes(numericValues, codec: numericCodec))}")
        println("CHECKSUM writePlainStrings ${fnv1a64Hex(YJson.toJson(plainValues))}")
        let readArray = YJson.fromJson<ArrayList<Int64>>(numericText)
        println("CHECKSUM readNumericArray ${fnv1a64Hex("count=${readArray.size};last=${readArray[readArray.size - 1]}")}")
        let readDocument = YJson.parseDocument(numericText)
        println("CHECKSUM readNumericDocument ${fnv1a64Hex("count=${readDocument.root().size()}")}")
    }

    @Bench
    func writeEscapedStrings(): Unit {
        stringSink = YJson.toJson(escapedValues)
    }

    @Bench
    func writeEscapedBytes(): Unit {
        bytesSink = YJson.toJsonBytes(escapedValues, codec: escapedCodec)
    }

    @Bench
    func writeNumericArray(): Unit {
        stringSink = YJson.toJson(numericValues)
    }

    @Bench
    func writeNumericBytes(): Unit {
        bytesSink = YJson.toJsonBytes(numericValues, codec: numericCodec)
    }

    @Bench
    func readNumericArray(): Unit {
        let values = YJson.fromJson<ArrayList<Int64>>(numericText)
        intSink = values[values.size - 1]
    }

    @Bench
    func readNumericDocument(): Unit {
        let document = YJson.parseDocument(numericText)
        intSink = document.root().size()
    }

    @Bench
    func writePlainStrings(): Unit {
        stringSink = YJson.toJson(plainValues)
    }
}
