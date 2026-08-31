package yjson_native_accel_benchmarks

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_native_accel.*

main(): Unit {}

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
