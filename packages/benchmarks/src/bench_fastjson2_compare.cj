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

func encodeYjsonReflectBytesWith<T>(codec: JsonDirectCodec<T>, value: T): Array<Byte> {
    YJson.encodeBytesWith(codec, value)
}

func decodeYjsonReflectBytesWith<T>(codec: JsonDirectCodec<T>, bytes: Array<Byte>): T {
    YJson.decodeBytesWith(codec, bytes)
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
    let personAst: JsonValue
    var stringSink = ""
    var intSink: Int64 = 0
    var bytesSink: Array<Byte> = Array<Byte>(0, repeat: 0u8)
    var astSink: JsonValue = JsonNullValue()

    init() {
        personText = YJson.encodeStringWith(PersonJson, person)
        personBytes = encodeYjsonReflectBytesWith(PersonJson, person)
        profileBundleText = YJson.encodeStringWith(ProfileBundleJson, profileBundle)
        uint64EnvelopeText = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
        temporalStatsText = YJson.encodeStringWith(TemporalStatsJson, temporalStats)
        personAst = YJson.parse(personText)
    }

    @Bench
    func parseAstYjsonReflectPerson(): Unit {
        astSink = YJson.parse(personText)
    }

    @Bench
    func stringifyAstYjsonReflectPerson(): Unit {
        stringSink = YJson.stringify(personAst)
    }

    @Bench
    func encodeStringYjsonReflectPerson(): Unit {
        stringSink = YJson.encodeStringWith(PersonJson, person)
    }

    @Bench
    func decodeStringYjsonReflectPerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, personText).id
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
        stringSink = YJson.encodeStringWith(ProfileBundleJson, profileBundle)
    }

    @Bench
    func decodeObjectYjsonReflectProfileBundle(): Unit {
        intSink = YJson.decodeStringWith(ProfileBundleJson, profileBundleText).groups["platform"][0].id
    }

    @Bench
    func encodeObjectYjsonReflectUInt64Envelope(): Unit {
        stringSink = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
    }

    @Bench
    func decodeObjectYjsonReflectUInt64Envelope(): Unit {
        intSink = Int64(YJson.decodeStringWith(UInt64EnvelopeJson, uint64EnvelopeText).shardIds.size)
    }

    @Bench
    func encodeObjectYjsonReflectTemporalStats(): Unit {
        stringSink = YJson.encodeStringWith(TemporalStatsJson, temporalStats)
    }

    @Bench
    func decodeObjectYjsonReflectTemporalStats(): Unit {
        stringSink = YJson.decodeStringWith(TemporalStatsJson, temporalStatsText).totalEvents.toString()
    }
}
