package wirestack_m12_001

import std.collection.ArrayList
import std.runtime.{getAllocatedHeapSize, getGCCount}
import wirestack as api
import wirestack.tls.TlsRuntime

// Prefix the runner uses to read the provider identity observed from this exact binary.
let tlsIdentityPrefix = "TLS_IDENTITY "
let tlsIdentityRequest = "tls-identity"

func jsonString(value: String): String {
    let escaped = ArrayList<Byte>(value.size + 2)
    escaped.append(34u8)
    for (b in value.toArray()) {
        if (b == 34u8 || b == 92u8) { escaped.append(92u8) }
        escaped.append(b)
    }
    escaped.append(34u8)
    String.fromUtf8(escaped.toArray())
}

// Emitted by the measured executable so capture identity never depends on a literal in the runner.
func tlsIdentityLine(): String {
    let info = TlsRuntime.info()
    tlsIdentityPrefix + "{" +
        "\"provider\":" + jsonString(info.tlsProvider) + "," +
        "\"version\":" + jsonString(info.tlsProviderVersion) + "," +
        "\"build_fingerprint\":" + jsonString(info.buildFingerprint) + "," +
        "\"target_triple\":" + jsonString(info.targetTriple) + "," +
        "\"external_openssl\":" + "${info.externalOpenSslDependency}" + "," +
        "\"trust_backend\":" + jsonString(info.trustBackend) + "}"
}

func isTlsIdentityRequest(args: Array<String>): Bool {
    args.size == 1 && args[0] == tlsIdentityRequest
}

func perfRequire(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func perfLoopback(): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
}
func perfOwner(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(60 * Duration.second)))
}
func emitSample(scenario: String, regime: String, durationNs: Int64,
    latencies: Array<Int64>, operations: Int64, successes: Int64, failures: Int64,
    bytes: Int64, checksum: Int64, metrics!: String = "{}", expectedRejections!: Int64 = 0): Unit {
    perfRequire(operations > 0 && latencies.size == operations, "missing per-operation latency samples")
    perfRequire(successes + failures + expectedRejections == operations, "incomplete operation accounting")
    perfRequire(durationNs > 0, "invalid measurement duration")
    let heapAfter = getAllocatedHeapSize()
    let gcAfter = getGCCount()
    let encoded = StringBuilder(latencies.size * 24)
    for (i in 0..latencies.size) {
        perfRequire(latencies[i] > 0, "invalid operation latency")
        if (i > 0) { encoded.append(",") }
        encoded.append(latencies[i])
    }
    // Serialization is outside the timed operation interval.
    println("{\"scenario\":\"${scenario}\",\"regime\":\"${regime}\",\"duration_ns\":${durationNs}," +
        "\"latencies_ns\":[${encoded.toString()}],\"operations\":${operations},\"successes\":${successes}," +
        "\"failures\":${failures},\"expected_rejections\":${expectedRejections},\"bytes\":${bytes}," +
        "\"checksum\":${checksum},\"runtime_heap_after_bytes\":${heapAfter},\"gc_count_after\":${gcAfter},\"metrics\":${metrics}}")
}
