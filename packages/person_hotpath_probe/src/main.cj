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
    let mode = if (args.size > 1) { args[1] } else { "person-string" }
    let profileText = YJson.encodeStringWith(ProfileRecordJson, sampleProfileRecord())
    let addressText = YJson.encodeStringWith(AddressJson, samplePerson().address)
    let personText = YJson.encodeStringWith(PersonJson, samplePerson())
    let profileBytes = unsafe { profileText.rawData() }
    let addressBytes = unsafe { addressText.rawData() }
    let personBytes = unsafe { personText.rawData() }
    match (mode) {
        case "profile-string" => report({ => PROFILE_DECODER.decodeString(profileText).id })
        case "profile-bytes" => report({ => PROFILE_DECODER.decodeBytes(profileBytes).id })
        case "address-string" => report({ => ADDRESS_DECODER.decodeString(addressText).zipcode })
        case "address-bytes" => report({ => ADDRESS_DECODER.decodeBytes(addressBytes).zipcode })
        case "person-string" => report({ => PERSON_DECODER.decodeString(personText).id })
        case "person-bytes" => report({ => PERSON_DECODER.decodeBytes(personBytes).id })
        case _ => throw Exception("unknown probe mode: ${mode}")
    }
}
