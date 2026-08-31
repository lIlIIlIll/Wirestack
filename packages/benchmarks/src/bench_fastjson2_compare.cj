/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
 * This source file is part of the Cangjie project, licensed under Apache-2.0
 * with Runtime Library Exception.
 *
 * See https://cangjie-lang.cn/pages/LICENSE for license information.
 */

package yjson_benchmarks

import yjson.*

import std.unittest.*
import std.unittest.testmacro.*

func encodeYjsonReflectBytesWith<T>(codec: JsonCodec<T>, value: T): Array<Byte> {
    YJson.toJsonBytes(value, codec: codec)
}

func decodeYjsonReflectBytesWith<T>(codec: JsonCodec<T>, bytes: Array<Byte>): T {
    YJson.fromJson(bytes, codec: codec)
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class Fastjson2CompareBenchmarks {
    let person = samplePerson()
    let profileBundle = sampleProfileBundleForBench()
    let uint64Envelope = sampleUInt64Envelope()
    let temporalStats = sampleTemporalStats()
    let personText: String
    let personBytes: Array<Byte>
    let profileBundleText: String
    let uint64EnvelopeText: String
    let temporalStatsText: String
    let personAst: JsonNode
    var stringSink = ""
    var intSink: Int64 = 0
    var bytesSink: Array<Byte> = Array<Byte>(0, repeat: 0u8)
    var astSink: JsonNode = JsonNode.nullValue

    init() {
        personText = YJson.toJson(person, codec: PersonJson)
        personBytes = encodeYjsonReflectBytesWith(PersonJson, person)
        profileBundleText = YJson.toJson(profileBundle, codec: ProfileBundleJson)
        uint64EnvelopeText = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
        temporalStatsText = YJson.toJson(temporalStats, codec: TemporalStatsJson)
        personAst = JsonNode.parse(personText)
    }

    @Bench
    func parseAstYjsonReflectPerson(): Unit {
        astSink = JsonNode.parse(personText)
    }

    @Bench
    func stringifyAstYjsonReflectPerson(): Unit {
        stringSink = (personAst).toJson()
    }

    @Bench
    func encodeStringYjsonReflectPerson(): Unit {
        stringSink = YJson.toJson(person, codec: PersonJson)
    }

    @Bench
    func decodeStringYjsonReflectPerson(): Unit {
        intSink = YJson.fromJson(personText, codec: PersonJson).id
    }

    @Bench
    func encodeBytesYjsonReflectPerson(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(PersonJson, person)
    }

    @Bench
    func decodeBytesYjsonReflectPerson(): Unit {
        intSink = decodeYjsonReflectBytesWith(PersonJson, personBytes).id
    }

    @Bench
    func encodeObjectYjsonReflectProfileBundle(): Unit {
        stringSink = YJson.toJson(profileBundle, codec: ProfileBundleJson)
    }

    @Bench
    func decodeObjectYjsonReflectProfileBundle(): Unit {
        intSink = YJson.fromJson(profileBundleText, codec: ProfileBundleJson).groups["platform"][0].id
    }

    @Bench
    func encodeObjectYjsonReflectUInt64Envelope(): Unit {
        stringSink = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
    }

    @Bench
    func decodeObjectYjsonReflectUInt64Envelope(): Unit {
        intSink = Int64(YJson.fromJson(uint64EnvelopeText, codec: UInt64EnvelopeJson).shardIds.size)
    }

    @Bench
    func encodeObjectYjsonReflectTemporalStats(): Unit {
        stringSink = YJson.toJson(temporalStats, codec: TemporalStatsJson)
    }

    @Bench
    func decodeObjectYjsonReflectTemporalStats(): Unit {
        stringSink = YJson.fromJson(temporalStatsText, codec: TemporalStatsJson).totalEvents.toString()
    }
}
