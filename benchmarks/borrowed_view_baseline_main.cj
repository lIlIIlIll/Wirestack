package yjson_person_hotpath_probe

import yjson.*

import std.env.*
import std.runtime.*
import std.time.*

private let WARMUP: Int64 = 20000
private let ITERATIONS: Int64 = 100000
private let PROFILE_DECODER = YJson.fastDecoder(ProfileRecordJson)
private let ADDRESS_DECODER = YJson.fastDecoder(AddressJson)
private let PERSON_DECODER = YJson.fastDecoder(PersonJson)

private func personChecksum(value: Person): Int64 {
    var result = value.id + Int64(value.age) + value.name.size
    for (tag in value.tags) { result += tag.size }
    result += value.scores["math"] + value.scores["english"]
    result += value.address.street.size + value.address.zipcode
    match (value.nick) { case Some(text) => result += text.size; case None => () }
    result
}

private func report(action: () -> Int64): Unit {
    var warmupSink: Int64 = 0
    for (_ in 0..WARMUP) { warmupSink += action() }
    let gcCountBefore = getGCCount()
    let gcFreedBefore = getGCFreedSize()
    var sink = warmupSink
    let start = DateTime.now()
    for (_ in 0..ITERATIONS) { sink += action() }
    let elapsed = (DateTime.now() - start).toNanoseconds()
    if (sink == 0) { throw Exception("unexpected zero probe sink") }
    println(
        "ns_per_op=${Float64(elapsed) / Float64(ITERATIONS)}," +
        "gc_count=${getGCCount() - gcCountBefore}," +
        "gc_freed_bytes=${getGCFreedSize() - gcFreedBefore}"
    )
}

main(): Unit {
    let args = getCommandLine()
    let mode = if (args.size > 1) { args[1] } else { "person-owned-full-string" }
    let profileText = YJson.encodeStringWith(ProfileRecordJson, sampleProfileRecord())
    let addressText = YJson.encodeStringWith(AddressJson, samplePerson().address)
    let personText = YJson.encodeStringWith(PersonJson, samplePerson())
    let profileBytes = unsafe { profileText.rawData() }
    let addressBytes = unsafe { addressText.rawData() }
    let personBytes = unsafe { personText.rawData() }
    match (mode) {
        case "profile-owned-full-string" => report({ =>
            let value = PROFILE_DECODER.decodeString(profileText)
            value.id + value.alias.size + Int64(value.level)
        })
        case "profile-owned-full-bytes" => report({ =>
            let value = PROFILE_DECODER.decodeBytes(profileBytes)
            value.id + value.alias.size + Int64(value.level)
        })
        case "address-owned-full-string" => report({ =>
            let value = ADDRESS_DECODER.decodeString(addressText)
            value.street.size + value.zipcode
        })
        case "address-owned-full-bytes" => report({ =>
            let value = ADDRESS_DECODER.decodeBytes(addressBytes)
            value.street.size + value.zipcode
        })
        case "person-owned-full-string" => report({ => personChecksum(PERSON_DECODER.decodeString(personText)) })
        case "person-owned-full-bytes" => report({ => personChecksum(PERSON_DECODER.decodeBytes(personBytes)) })
        case _ => throw Exception("unknown probe mode: ${mode}")
    }
}
