package yjson_person_hotpath_probe

import yjson.*

import std.env.*
import std.runtime.*
import std.time.*

private let WARMUP: Int64 = 20000
private let ITERATIONS: Int64 = 100000
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
    let profileText = YJson.toJson(sampleProfileRecord(), codec: ProfileRecordJson)
    let addressText = YJson.toJson(samplePerson().address, codec: AddressJson)
    let personText = YJson.toJson(samplePerson(), codec: PersonJson)
    let profileBytes = unsafe { profileText.rawData() }
    let addressBytes = unsafe { addressText.rawData() }
    let personBytes = unsafe { personText.rawData() }
    match (mode) {
        case "profile-owned-full-string" => report({ =>
            let value = YJson.fromJson(profileText, codec: ProfileRecordJson)
            value.id + value.alias.size + Int64(value.level)
        })
        case "profile-owned-full-bytes" => report({ =>
            let value = YJson.fromJson(profileBytes, codec: ProfileRecordJson)
            value.id + value.alias.size + Int64(value.level)
        })
        case "address-owned-full-string" => report({ =>
            let value = YJson.fromJson(addressText, codec: AddressJson)
            value.street.size + value.zipcode
        })
        case "address-owned-full-bytes" => report({ =>
            let value = YJson.fromJson(addressBytes, codec: AddressJson)
            value.street.size + value.zipcode
        })
        case "person-owned-full-string" => report({ => personChecksum(YJson.fromJson(personText, codec: PersonJson)) })
        case "person-owned-full-bytes" => report({ => personChecksum(YJson.fromJson(personBytes, codec: PersonJson)) })
        case _ => throw Exception("unknown probe mode: ${mode}")
    }
}
