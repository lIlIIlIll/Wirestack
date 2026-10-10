package wirestack_m12_001

import std.runtime.{getAllocatedHeapSize, getGCCount}
import wirestack as api

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
