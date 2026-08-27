package wirestack.internal.resolver

import std.collection.ArrayList
import std.sync.*
import std.time.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private const RESOLVER_OK: Int32 = 0
private const RESOLVER_OUT_OF_MEMORY: Int32 = 2
private const RESOLVER_CLOSED: Int32 = 3
private const RESOLVER_OVERLOADED: Int32 = 4
private const RESOLVER_PENDING: Int32 = 5
private const RESOLVER_OUTPUT_TOO_SMALL: Int32 = 6

private const RESOLVER_RESULT_SUCCESS: Int32 = 0
private const RESOLVER_RESULT_SYSTEM_FAILURE: Int32 = 6

private const RESOLVER_FAMILY_ANY: Int32 = 0
private const RESOLVER_FAMILY_IPV4: Int32 = 4
private const RESOLVER_FAMILY_IPV6: Int32 = 6
private const RESOLVER_METRIC_COUNT: Int64 = 10
private const RESOLVER_ADDRESS_BYTES: Int64 = 16
private let RESOLVER_WAIT_QUANTUM = Duration.millisecond

foreign func wirestack_resolver_pool_create(
    workerCount: UInt64,
    queueCapacity: UInt64,
    outPoolHandle: CPointer<UInt64>
): Int32

foreign func wirestack_resolver_pool_destroy(poolHandle: UInt64): Int32

foreign func wirestack_resolver_submit(
    poolHandle: UInt64,
    host: CString,
    service: CString,
    family: Int32,
    maximumResults: UInt64,
    outJobHandle: CPointer<UInt64>
): Int32

foreign func wirestack_resolver_poll(
    jobHandle: UInt64,
    outFamilies: CPointer<Int32>,
    outAddresses: CPointer<Byte>,
    outputCapacity: UInt64,
    outCount: CPointer<UInt64>,
    outResult: CPointer<Int32>,
    outNativeCode: CPointer<Int64>
): Int32

foreign func wirestack_resolver_job_release(jobHandle: UInt64): Unit

foreign func wirestack_resolver_pool_metrics(
    poolHandle: UInt64,
    output: CPointer<UInt64>,
    outputCapacity: UInt64
): Int32

/** Bounded scheduler diagnostics. No hostname or address data is retained. */
internal struct ResolverPoolMetrics {
    internal let workerCount: Int64
    internal let queueCapacity: Int64
    internal let activeJobs: Int64
    internal let queuedJobs: Int64
    internal let runningJobs: Int64
    internal let peakActiveJobs: Int64
    internal let peakQueuedJobs: Int64
    internal let submittedJobs: Int64
    internal let completedJobs: Int64
    internal let rejectedJobs: Int64

    internal init(values: Array<UInt64>) {
        workerCount = Int64(values[0])
        queueCapacity = Int64(values[1])
        activeJobs = Int64(values[2])
        queuedJobs = Int64(values[3])
        runningJobs = Int64(values[4])
        peakActiveJobs = Int64(values[5])
        peakQueuedJobs = Int64(values[6])
        submittedJobs = Int64(values[7])
        completedJobs = Int64(values[8])
        rejectedJobs = Int64(values[9])
    }
}

/**
 * Linux blocking resolver backend isolated on a fixed native worker pool.
 *
 * This type is intentionally internal. M2-005 owns the public SystemResolver
 * adapter and its platform error mapping.
 */
internal class LinuxBoundedResolverBackend {
    private let mutex = Mutex()
    private var poolHandle: UInt64 = 0u64

    internal init(workerCount!: Int64 = 4, queueCapacity!: Int64 = 64) {
        if (workerCount <= 0 || workerCount > 32) {
            throw IllegalArgumentException("resolver workerCount must be between 1 and 32")
        }
        if (queueCapacity <= 0 || queueCapacity > 1024) {
            throw IllegalArgumentException("resolver queueCapacity must be between 1 and 1024")
        }
        let output = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let raw = acquireArrayRawData(output)
            try {
                wirestack_resolver_pool_create(
                    UInt64(workerCount),
                    UInt64(queueCapacity),
                    raw.pointer
                )
            } finally {
                releaseArrayRawData(raw)
            }
        }
        if (status != RESOLVER_OK || output[0] == 0u64) {
            throw ResolveException(
                ResolveErrorCode.SystemFailure,
                "failed to create bounded Linux resolver pool: ${status}"
            )
        }
        poolHandle = output[0]
    }

    internal func resolve(
        host: HostName,
        service: ?String,
        options: ResolveOptions,
        context: OperationContext
    ): ResolveResult {
        checkResolveContext(context)
        let startedAt = MonoTime.now()
        let jobHandle = submit(host, service, options)
        let output = ResolverPollOutput(options.maxResults)
        try {
            while (true) {
                checkResolveContext(context)
                if (let Some(result) <- poll(jobHandle, host, options, startedAt, output)) {
                    return result
                }
                waitForNextPoll(context)
            }
        } finally {
            unsafe { wirestack_resolver_job_release(jobHandle) }
        }
        throw ResolveException(ResolveErrorCode.SystemFailure, "resolver loop terminated unexpectedly")
    }

    internal func metrics(): ResolverPoolMetrics {
        synchronized(mutex) {
            let current = requireOpen()
            let values = Array<UInt64>(RESOLVER_METRIC_COUNT, repeat: 0u64)
            let status = unsafe {
                let raw = acquireArrayRawData(values)
                try {
                    wirestack_resolver_pool_metrics(
                        current,
                        raw.pointer,
                        UInt64(RESOLVER_METRIC_COUNT)
                    )
                } finally {
                    releaseArrayRawData(raw)
                }
            }
            if (status != RESOLVER_OK) {
                throw ResolveException(
                    ResolveErrorCode.SystemFailure,
                    "failed to read resolver pool metrics: ${status}"
                )
            }
            ResolverPoolMetrics(values)
        }
    }

    internal func close(): Unit {
        let current = synchronized(mutex) {
            let value = poolHandle
            poolHandle = 0u64
            value
        }
        if (current != 0u64) {
            let status = unsafe { wirestack_resolver_pool_destroy(current) }
            if (status != RESOLVER_OK) {
                throw ResolveException(
                    ResolveErrorCode.SystemFailure,
                    "failed to close resolver pool: ${status}"
                )
            }
        }
    }

    private func submit(
        host: HostName,
        service: ?String,
        options: ResolveOptions
    ): UInt64 {
        let output = Array<UInt64>(1, repeat: 0u64)
        let status = synchronized(mutex) {
            let current = requireOpen()
            withCStringResult(host.ascii, {hostValue =>
                match (service) {
                    case Some(value) => withCStringResult(value, {serviceValue =>
                        submitNative(current, hostValue, serviceValue, options, output)
                    })
                    case None => withCStringResult("", {serviceValue =>
                        submitNative(current, hostValue, serviceValue, options, output)
                    })
                }
            })
        }
        if (status == RESOLVER_OVERLOADED) {
            throw ResolveException(
                ResolveErrorCode.TemporaryFailure,
                "bounded Linux resolver pool is full"
            )
        }
        if (status == RESOLVER_CLOSED) {
            throw ResolveException(ResolveErrorCode.SystemFailure, "Linux resolver pool is closed")
        }
        if (status == RESOLVER_OUT_OF_MEMORY) {
            throw ResolveException(ResolveErrorCode.SystemFailure, "Linux resolver pool allocation failed")
        }
        if (status != RESOLVER_OK || output[0] == 0u64) {
            throw ResolveException(
                ResolveErrorCode.InvalidName,
                "Linux resolver rejected the request: ${status}"
            )
        }
        output[0]
    }

    private func submitNative(
        current: UInt64,
        host: CString,
        service: CString,
        options: ResolveOptions,
        output: Array<UInt64>
    ): Int32 {
        unsafe {
            let raw = acquireArrayRawData(output)
            try {
                wirestack_resolver_submit(
                    current,
                    host,
                    service,
                    nativeFamily(options.family),
                    UInt64(options.maxResults),
                    raw.pointer
                )
            } finally {
                releaseArrayRawData(raw)
            }
        }
    }

    private func poll(
        jobHandle: UInt64,
        host: HostName,
        options: ResolveOptions,
        startedAt: MonoTime,
        output: ResolverPollOutput
    ): ?ResolveResult {
        let maximum = options.maxResults
        let status = unsafe {
            let familiesRaw = acquireArrayRawData(output.families)
            let packedRaw = acquireArrayRawData(output.packed)
            let countRaw = acquireArrayRawData(output.count)
            let resultRaw = acquireArrayRawData(output.result)
            let nativeRaw = acquireArrayRawData(output.nativeCode)
            try {
                wirestack_resolver_poll(
                    jobHandle,
                    familiesRaw.pointer,
                    packedRaw.pointer,
                    UInt64(maximum),
                    countRaw.pointer,
                    resultRaw.pointer,
                    nativeRaw.pointer
                )
            } finally {
                releaseArrayRawData(nativeRaw)
                releaseArrayRawData(resultRaw)
                releaseArrayRawData(countRaw)
                releaseArrayRawData(packedRaw)
                releaseArrayRawData(familiesRaw)
            }
        }
        if (status == RESOLVER_PENDING) {
            return None<ResolveResult>
        }
        if (status == RESOLVER_OUTPUT_TOO_SMALL || output.count[0] > UInt64(maximum)) {
            throw ResolveException(ResolveErrorCode.SystemFailure, "resolver produced an oversized result")
        }
        if (status != RESOLVER_OK) {
            throw ResolveException(
                ResolveErrorCode.SystemFailure,
                "resolver result query failed: ${status}"
            )
        }
        if (output.result[0] != RESOLVER_RESULT_SUCCESS) {
            let code = resolveError(output.result[0])
            throw ResolveException(
                code,
                "Linux resolver failed with native code ${output.nativeCode[0]}"
            )
        }
        let addresses = ArrayList<IpAddress>()
        for (index in 0..Int64(output.count[0])) {
            let size = if (output.families[index] == RESOLVER_FAMILY_IPV4) { 4 } else { 16 }
            let octets = Array<Byte>(size, repeat: 0)
            for (offset in 0..size) {
                octets[offset] = output.packed[index * RESOLVER_ADDRESS_BYTES + offset]
            }
            addresses.add(IpAddress(
                if (output.families[index] == RESOLVER_FAMILY_IPV4) {
                    IpAddressFamily.Ipv4
                } else {
                    IpAddressFamily.Ipv6
                },
                octets
            ))
        }
        if (addresses.isEmpty()) {
            throw ResolveException(ResolveErrorCode.NoData, "Linux resolver returned no addresses")
        }
        Some(ResolveResult(
            addresses.toArray(),
            host,
            ResolverSource.System,
            startedAt: startedAt,
            completedAt: MonoTime.now()
        ))
    }

    private func requireOpen(): UInt64 {
        if (poolHandle == 0u64) {
            throw ResolveException(ResolveErrorCode.SystemFailure, "Linux resolver pool is closed")
        }
        poolHandle
    }
}

private class ResolverPollOutput {
    let families: Array<Int32>
    let packed: Array<Byte>
    let count = Array<UInt64>(1, repeat: 0u64)
    let result = Array<Int32>(1, repeat: RESOLVER_RESULT_SYSTEM_FAILURE)
    let nativeCode = Array<Int64>(1, repeat: 0)

    init(maximum: Int64) {
        families = Array<Int32>(maximum, repeat: 0i32)
        packed = Array<Byte>(maximum * RESOLVER_ADDRESS_BYTES, repeat: 0)
    }
}

private func nativeFamily(value: ResolveAddressFamily): Int32 {
    match (value) {
        case ResolveAddressFamily.Any => RESOLVER_FAMILY_ANY
        case ResolveAddressFamily.Ipv4 => RESOLVER_FAMILY_IPV4
        case ResolveAddressFamily.Ipv6 => RESOLVER_FAMILY_IPV6
    }
}

private func resolveError(value: Int32): ResolveErrorCode {
    match (value) {
        case 1 => ResolveErrorCode.NameNotFound
        case 2 => ResolveErrorCode.NoData
        case 3 => ResolveErrorCode.TemporaryFailure
        case 4 => ResolveErrorCode.InvalidName
        case 5 => ResolveErrorCode.UnsupportedFamily
        case _ => ResolveErrorCode.SystemFailure
    }
}

private func waitForNextPoll(context: OperationContext): Unit {
    checkResolveContext(context)
    let delay = match (context.deadline) {
        case Some(value) =>
            let remaining = value.remaining()
            if (remaining <= Duration.Zero) {
                checkResolveContext(context)
                Duration.nanosecond
            } else if (remaining < RESOLVER_WAIT_QUANTUM) {
                remaining
            } else {
                RESOLVER_WAIT_QUANTUM
            }
        case None => RESOLVER_WAIT_QUANTUM
    }
    sleep(delay)
}

private func withCStringResult<T>(value: String, action: (CString) -> T): T {
    unsafe {
        let encoded = LibC.mallocCString(value)
        try {
            return action(encoded)
        } finally {
            LibC.free(encoded)
        }
    }
}
