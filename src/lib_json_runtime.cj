package yjson

import std.sync.*

/// Versioned cross-package activation seam used by yjson_native_accel.
/// Applications configure it through YJsonNativeAccel.initialize().
public interface JsonAccelerationProviderV1 {
    func identity(): String
    func protocolVersion(): Int64
    func abiVersion(): Int64
    func activate(): Unit
}

/// Optional extension implemented by the first-party native primitive
/// provider. It lets the runtime validate and install the primitive bundle
/// itself, inside the initialization lock, instead of exposing a public
/// unvalidated installation entry point.
public interface JsonNativePrimitivesProviderV1 <: JsonAccelerationProviderV1 {
    func primitives(): JsonNativeAccelerationPrimitivesV1
}

private const YJSON_ACCEL_PROTOCOL_V1: Int64 = 1
private const YJSON_ACCEL_ABI_V1: Int64 = 1
private const YJSON_RUNTIME_UNCONFIGURED: Int64 = 0
private const YJSON_RUNTIME_INITIALIZING: Int64 = 1
private const YJSON_RUNTIME_PURE_FROZEN: Int64 = 2
private const YJSON_RUNTIME_NATIVE_FROZEN: Int64 = 3

private let yJsonRuntimeMutex = Mutex()
private let yJsonRuntimeChanged = synchronized(yJsonRuntimeMutex) {
    yJsonRuntimeMutex.condition()
}
// Ordinary calls are overwhelmingly made after the process engine is frozen.
// Publish that terminal state atomically so the hot path never enters Mutex.
private let yJsonRuntimeFrozen = AtomicInt64(0)
// Package-visible test seam. The production path also updates the counter, so
// product-only builds do not acquire an unused test-helper declaration.
let yJsonRuntimeSlowFreezeEntriesForTest = AtomicInt64(0)
private var yJsonRuntimeState: Int64 = YJSON_RUNTIME_UNCONFIGURED
private var yJsonRuntimeProviderIdentity: String = ""
private var yJsonRuntimeInitializationOwner: Int64 = 0

/// Freezes the portable engine on the first ordinary YJson call.
func freezeYJsonRuntime(): Unit {
    if (yJsonRuntimeFrozen.load() != 0) { return }
    yJsonRuntimeSlowFreezeEntriesForTest.fetchAdd(1)
    synchronized(yJsonRuntimeMutex) {
        while (yJsonRuntimeState == YJSON_RUNTIME_INITIALIZING) {
            if (yJsonRuntimeInitializationOwner == Thread.currentThread.id) {
                throw JsonException(
                    "YJson cannot be used recursively while acceleration is initializing",
                    code: "acceleration_reentrant_use")
            }
            yJsonRuntimeChanged.wait()
        }
        if (yJsonRuntimeState == YJSON_RUNTIME_UNCONFIGURED) {
            yJsonRuntimeState = YJSON_RUNTIME_PURE_FROZEN
            yJsonRuntimeFrozen.store(1)
        }
    }
}

/// Internal product seam. Optional acceleration packages must call this only
/// from their single public initialize entry point.
public func initializeYJsonAccelerationV1(provider: JsonAccelerationProviderV1): Unit {
    // Provider methods are callbacks into another package. Resolve metadata
    // before taking the runtime lock and run activation without holding it.
    let identity = provider.identity()
    let protocol = provider.protocolVersion()
    let abi = provider.abiVersion()
    if (identity.isEmpty()) {
        throw JsonException("Acceleration provider identity must not be empty",
            code: "acceleration_provider_identity_invalid")
    }
    if (protocol != YJSON_ACCEL_PROTOCOL_V1) {
        throw JsonException(
            "Acceleration protocol mismatch: expected 1, got ${protocol}",
            code: "acceleration_protocol_mismatch")
    }
    if (abi != YJSON_ACCEL_ABI_V1) {
        throw JsonException(
            "Acceleration ABI mismatch: expected 1, got ${abi}",
            code: "acceleration_abi_mismatch")
    }

    synchronized(yJsonRuntimeMutex) {
        while (yJsonRuntimeState == YJSON_RUNTIME_INITIALIZING) {
            if (yJsonRuntimeInitializationOwner == Thread.currentThread.id) {
                throw JsonException(
                    "Acceleration initialization cannot recursively initialize a provider",
                    code: "acceleration_reentrant_initialization")
            }
            yJsonRuntimeChanged.wait()
        }
        if (yJsonRuntimeState == YJSON_RUNTIME_PURE_FROZEN) {
            throw JsonException(
                "YJson is already frozen in portable mode; initialize acceleration before the first YJson call",
                code: "acceleration_initialized_too_late")
        }
        if (yJsonRuntimeState == YJSON_RUNTIME_NATIVE_FROZEN) {
            if (yJsonRuntimeProviderIdentity != identity) {
                throw JsonException(
                    "A different JSON acceleration provider is already active",
                    code: "acceleration_provider_conflict")
            }
            return
        }
        yJsonRuntimeState = YJSON_RUNTIME_INITIALIZING
        yJsonRuntimeInitializationOwner = Thread.currentThread.id
    }

    var primitives: Option<JsonNativeAccelerationPrimitivesV1> = None<JsonNativeAccelerationPrimitivesV1>
    match (provider) {
        case nativeProvider: JsonNativePrimitivesProviderV1 =>
            primitives = Some(nativeProvider.primitives())
        case _ => ()
    }

    try {
        provider.activate()
    } catch (error: JsonException) {
        rollbackYJsonAccelerationInitialization()
        throw error
    } catch (error: Exception) {
        rollbackYJsonAccelerationInitialization()
        throw JsonException(
            "JSON acceleration initialization failed: ${error.message}",
            code: "acceleration_initialization_failed")
    }

    synchronized(yJsonRuntimeMutex) {
        // Install the primitive bundle only after activation validated the
        // linked native code. The slot is package-visible and updated under
        // the runtime lock, so hot paths observe either Pure or the complete
        // bundle.
        match (primitives) {
            case Some(bundle) => installJsonNativePrimitivesLocked(bundle)
            case None => ()
        }
        yJsonRuntimeProviderIdentity = identity
        yJsonRuntimeInitializationOwner = 0
        yJsonRuntimeState = YJSON_RUNTIME_NATIVE_FROZEN
        yJsonRuntimeFrozen.store(1)
        yJsonRuntimeChanged.notifyAll()
    }
}

private func rollbackYJsonAccelerationInitialization(): Unit {
    synchronized(yJsonRuntimeMutex) {
        yJsonRuntimeProviderIdentity = ""
        yJsonRuntimeInitializationOwner = 0
        yJsonRuntimeState = YJSON_RUNTIME_UNCONFIGURED
        yJsonRuntimeChanged.notifyAll()
    }
}

/// Version queried by generated codecs. Patch releases remain compatible as
/// long as this value stays unchanged.
public func yJsonGeneratedProtocolVersion(): Int64 { 1 }
