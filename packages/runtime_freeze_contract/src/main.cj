package yjson_runtime_freeze_contract

import std.collection.*
import std.sync.*
import yjson.*

private class ProbeProvider <: JsonAccelerationProviderV1 {
    private let providerIdentity: String
    private let protocol: Int64
    private let abi: Int64
    private let activations: AtomicInt64
    private let failActivation: Bool

    init(providerIdentity: String, activations: AtomicInt64,
        protocol!: Int64 = 1, abi!: Int64 = 1, failActivation!: Bool = false) {
        this.providerIdentity = providerIdentity
        this.activations = activations
        this.protocol = protocol
        this.abi = abi
        this.failActivation = failActivation
    }

    public func identity(): String { providerIdentity }
    public func protocolVersion(): Int64 { protocol }
    public func abiVersion(): Int64 { abi }
    public func activate(): Unit {
        activations.fetchAdd(1)
        if (failActivation) { throw Exception("intentional activation failure") }
    }
}

private class ReentrantUseProvider <: JsonAccelerationProviderV1 {
    public var observedCode: String = "none"

    public func identity(): String { "reentrant" }
    public func protocolVersion(): Int64 { 1 }
    public func abiVersion(): Int64 { 1 }
    public func activate(): Unit {
        try {
            let _ = YJson.parseDocument("null")
        } catch (error: JsonException) {
            observedCode = error.code
        }
    }
}

private class BlockingProvider <: JsonAccelerationProviderV1 {
    private let entered: AtomicInt64
    private let release: AtomicInt64

    init(entered: AtomicInt64, release: AtomicInt64) {
        this.entered = entered
        this.release = release
    }

    public func identity(): String { "blocking" }
    public func protocolVersion(): Int64 { 1 }
    public func abiVersion(): Int64 { 1 }
    public func activate(): Unit {
        entered.store(1)
        while (release.load() == 0) {}
    }
}

private func accelerationCode(action: () -> Unit): String {
    try {
        action()
        "none"
    } catch (error: JsonException) {
        error.code
    }
}

private func requireEqual<T>(actual: T, expected: T, label: String): Unit where T <: Equatable<T> {
    if (actual != expected) {
        throw Exception("${label}: values differ")
    }
}

private func pureLateInitialization(): Unit {
    let activations = AtomicInt64(0)
    let _ = YJson.parseDocument("null")
    requireEqual(accelerationCode({ => initializeYJsonAccelerationV1(
        ProbeProvider("A", activations)) }), "acceleration_initialized_too_late", "late initialization")
    requireEqual(activations.load(), 0, "late activation count")
}

private func generatedReaderLateInitialization(): Unit {
    let activations = AtomicInt64(0)
    let reader = GeneratedSupportV1.newFastReader("true")
    requireEqual(reader.readRawBool(), true, "generated reader value")
    reader.expectEnd()
    requireEqual(accelerationCode({ => initializeYJsonAccelerationV1(
        ProbeProvider("A", activations)) }), "acceleration_initialized_too_late",
        "generated reader late initialization")
    requireEqual(activations.load(), 0, "generated reader late activation count")
}

private func versionMismatch(): Unit {
    let activations = AtomicInt64(0)
    requireEqual(accelerationCode({ => initializeYJsonAccelerationV1(
        ProbeProvider("protocol", activations, protocol: 2)) }),
        "acceleration_protocol_mismatch", "protocol mismatch")
    requireEqual(accelerationCode({ => initializeYJsonAccelerationV1(
        ProbeProvider("abi", activations, abi: 2)) }),
        "acceleration_abi_mismatch", "ABI mismatch")
    requireEqual(activations.load(), 0, "mismatch activation count")
}

private func nativeIdempotenceAndConflict(): Unit {
    let activations = AtomicInt64(0)
    initializeYJsonAccelerationV1(ProbeProvider("A", activations))
    initializeYJsonAccelerationV1(ProbeProvider("A", activations))
    requireEqual(activations.load(), 1, "idempotent activation count")
    requireEqual(accelerationCode({ => initializeYJsonAccelerationV1(
        ProbeProvider("B", activations)) }), "acceleration_provider_conflict", "provider conflict")
    requireEqual(JsonNode.parse("[1]").asArray()[0].asInt64(), 1, "native-frozen YJson API")
}

private func failedActivationDoesNotFreeze(): Unit {
    let activations = AtomicInt64(0)
    requireEqual(accelerationCode({ => initializeYJsonAccelerationV1(
        ProbeProvider("failing", activations, failActivation: true)) }),
        "acceleration_initialization_failed", "activation failure")
    initializeYJsonAccelerationV1(ProbeProvider("working", activations))
    requireEqual(activations.load(), 2, "retry activation count")
    requireEqual((JsonNode.boolean(true)).toJson(), "true", "retry engine")
}

private func concurrentProviderCompetition(): Unit {
    let activations = AtomicInt64(0)
    let ready = AtomicInt64(0)
    let start = AtomicInt64(0)
    let taskCount: Int64 = 24
    let futures = ArrayList<Future<String>>()
    for (index in 0..taskCount) {
        let identity = if (index % 2 == 0) { "A" } else { "B" }
        futures.add(spawn {
            ready.fetchAdd(1)
            while (start.load() == 0) {}
            accelerationCode({ => initializeYJsonAccelerationV1(
                ProbeProvider(identity, activations)) })
        })
    }
    while (ready.load() != taskCount) {}
    start.store(1)
    var successes: Int64 = 0
    var conflicts: Int64 = 0
    for (future in futures) {
        match (future.get()) {
            case "none" => successes++
            case "acceleration_provider_conflict" => conflicts++
            case code => throw Exception("unexpected concurrent result ${code}")
        }
    }
    requireEqual(activations.load(), 1, "concurrent activation count")
    requireEqual(successes, taskCount / 2, "same-provider successes")
    requireEqual(conflicts, taskCount / 2, "competing-provider conflicts")
}

private func reentrantUseFailsWithoutDeadlock(): Unit {
    let provider = ReentrantUseProvider()
    initializeYJsonAccelerationV1(provider)
    requireEqual(provider.observedCode, "acceleration_reentrant_use", "reentrant use")
    requireEqual(YJson.parseDocument("42").root().asInt64(), 42, "post-initialization use")
}

private func ordinaryUseWaitsForInitialization(): Unit {
    let entered = AtomicInt64(0)
    let release = AtomicInt64(0)
    let started = AtomicInt64(0)
    let finished = AtomicInt64(0)
    let initializer = spawn {
        initializeYJsonAccelerationV1(BlockingProvider(entered, release))
    }
    while (entered.load() == 0) {}
    let reader = spawn {
        started.store(1)
        let value = YJson.parseDocument("42").root().asInt64()
        finished.store(1)
        value
    }
    while (started.load() == 0) {}
    requireEqual(finished.load(), 0, "ordinary use before initialization commit")
    release.store(1)
    initializer.get()
    requireEqual(reader.get(), 42, "ordinary use after initialization commit")
    requireEqual(finished.load(), 1, "ordinary use completion")
}

main(args: Array<String>): Int64 {
    if (args.size != 1) { return 2 }
    match (args[0]) {
        case "pure-late" => pureLateInitialization()
        case "generated-reader-late" => generatedReaderLateInitialization()
        case "version-mismatch" => versionMismatch()
        case "native-conflict" => nativeIdempotenceAndConflict()
        case "activation-failure" => failedActivationDoesNotFreeze()
        case "concurrent-race" => concurrentProviderCompetition()
        case "reentrant-use" => reentrantUseFailsWithoutDeadlock()
        case "initialization-wait" => ordinaryUseWaitsForInitialization()
        case _ => return 2
    }
    println("runtime freeze contract passed: ${args[0]}")
    0
}
