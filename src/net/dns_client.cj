package wirestack.net

import std.collection.*
import std.fs.File
import std.fs.OpenMode
import std.sync.*
import std.time.*
import wirestack as api
import wirestack.internal.resolver as system_resolver

private const DNS_IN_CLASS: UInt16 = 1u16
private const DNS_MAX_UDP_PAYLOAD: Int64 = 65507
private const DNS_MAX_PACKETS_PER_ATTEMPT: Int64 = 16
private const DNS_MAX_CNAME_HOPS: Int64 = 8

private enum DnsNegativeKind {
    | NameNotFound
    | NoData
}

private enum DnsCachedValue {
    | Positive(api.ResolveResult)
    | Negative(DnsNegativeKind)
}

private class DnsCacheEntry {
    let key: String
    let value: DnsCachedValue
    let expiresAt: MonoTime

    init(key: String, value: DnsCachedValue, expiresAt: MonoTime) {
        this.key = key
        this.value = value
        this.expiresAt = expiresAt
    }
}

private class ActiveDnsOperation {
    let id: Int64
    let cancellation: api.CancellationSource

    init(id: Int64, cancellation: api.CancellationSource) {
        this.id = id
        this.cancellation = cancellation
    }
}

private enum DnsAddressAnswer {
    | Addresses(Array<api.IpAddress>, String, UInt32)
    | Alias(String, UInt32)
    | NoData
}

/**
 * DNS wire client with bounded admission, UDP retry, TCP truncation fallback,
 * CNAME traversal, and TTL-governed positive and RFC 2308 negative caching.
 *
 * `lookup` explicitly uses the bounded platform system resolver only when the
 * captured configuration has no nameservers. `query` requires at least one
 * configured nameserver. Closing the client stops admission, cancels queued and
 * active operations, waits for admitted cleanup, and is idempotent.
 */
public class DnsClient <: Resource {
    private let delegate: ?system_resolver.SystemResolver
    private let workerCount: Int64
    private let queueCapacity: Int64
    private let lifecycleMutex = Mutex()
    private let lifecycleChanged = synchronized(lifecycleMutex) { lifecycleMutex.condition() }
    private let active = ArrayList<ActiveDnsOperation>()
    private let cache = ArrayList<DnsCacheEntry>()
    private let limits = DnsParserLimits()
    private var nextOperationId: Int64 = 1
    private var queued: Int64 = 0
    private var closed = false

    /** Resolver configuration captured for the lifetime of this client. */
    public let config: DnsResolverConfig

    /**
     * Creates a DNS client whose callers execute on at most `workerCount`
     * concurrent admission slots and whose waiting set is bounded by
     * `queueCapacity`.
     *
     * @param config Immutable resolver, timeout, retry, and cache policy.
     * @param workerCount Maximum concurrently executing lookups or queries, from 1 through 32.
     * @param queueCapacity Maximum waiting callers, from 1 through 1024.
     */
    public init(
        config!: DnsResolverConfig = DnsResolverConfig.fromSystem(),
        workerCount!: Int64 = 4,
        queueCapacity!: Int64 = 64
    ) {
        if (workerCount <= 0 || workerCount > 32) {
            throw IllegalArgumentException("DNS workerCount must be between 1 and 32")
        }
        if (queueCapacity <= 0 || queueCapacity > 1024) {
            throw IllegalArgumentException("DNS queueCapacity must be between 1 and 1024")
        }
        this.config = config
        this.workerCount = workerCount
        this.queueCapacity = queueCapacity
        delegate = if (config.nameservers.isEmpty()) {
            Some(system_resolver.SystemResolver(
                workerCount: workerCount,
                queueCapacity: queueCapacity
            ))
        } else {
            None<system_resolver.SystemResolver>
        }
    }

    /**
     * Resolves owned IPv4 and/or IPv6 candidates. One absolute deadline,
     * shortened at entry by `config.queryTimeout`, is reused by every family,
     * retry, CNAME hop, and TCP fallback.
     *
     * When no nameserver is configured this method delegates to the bounded
     * platform resolver. That fallback is intentionally unavailable to `query`.
     *
     * @param host Validated host name to resolve.
     * @param options Address-family and result-count policy.
     * @param context Caller cancellation, absolute deadline, trace, and event sink.
     * @return An immutable result whose address accessor returns an owned copy.
     */
    public func lookup(
        host: api.HostName,
        options!: api.ResolveOptions = api.ResolveOptions(),
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ResolveResult {
        let bounded = context.shortenDeadline(config.queryTimeout)
        let operationCancellation = api.CancellationSource()
        let parentRegistration = bounded.cancellation.register { =>
            operationCancellation.cancel()
            wakeAdmission()
        }
        let effective = bounded.withCancellation(operationCancellation.token)
        var operationId: Int64 = 0
        try {
            operationId = admit(operationCancellation, effective)
            checkDnsContext(effective)
            if (config.nameservers.isEmpty()) {
                return match (delegate) {
                    case Some(value) => value.resolveExact(host, options, effective)
                    case None => throw api.ResolveException(
                        api.ResolveErrorCode.SystemFailure,
                        "DNS system-resolver fallback is unavailable"
                    )
                }
            }
            return lookupWire(host, options, effective)
        } finally {
            if (operationId != 0) { finishOperation(operationId) }
            parentRegistration.unregister()
        }
    }

    /**
     * Sends one validated DNS wire query for any modeled record type. The
     * returned summary owns its arrays and RDATA. NXDOMAIN and other valid DNS
     * response codes remain observable in `responseCode`; transport failures,
     * exhausted temporary server failures, malformed matching responses, and
     * lifecycle stops raise `ResolveException`.
     *
     * @param name DNS owner name in presentation form.
     * @param recordType Record type to encode, including bounded unknown numeric types.
     * @param context Caller cancellation, absolute deadline, trace, and event sink.
     * @return A strictly parsed response with matching source and question identity.
     */
    public func query(
        name: String,
        recordType: DnsRecordType,
        context!: api.OperationContext = api.OperationContext.background()
    ): DnsMessageSummary {
        let bounded = context.shortenDeadline(config.queryTimeout)
        let operationCancellation = api.CancellationSource()
        let parentRegistration = bounded.cancellation.register { =>
            operationCancellation.cancel()
            wakeAdmission()
        }
        let effective = bounded.withCancellation(operationCancellation.token)
        var operationId: Int64 = 0
        try {
            operationId = admit(operationCancellation, effective)
            checkDnsContext(effective)
            if (config.nameservers.isEmpty()) {
                throw api.ResolveException(
                    api.ResolveErrorCode.SystemFailure,
                    "DNS query requires at least one configured nameserver"
                )
            }
            let (summary, _) = queryWire(dnsCanonicalName(name), recordType, effective)
            return summary
        } finally {
            if (operationId != 0) { finishOperation(operationId) }
            parentRegistration.unregister()
        }
    }

    /**
     * Stops new and queued operations, cancels active socket operations, waits
     * until every admitted caller has released its slot, and closes the bounded
     * system-resolver fallback. Repeated calls are idempotent.
     */
    public func close(): Unit {
        let cancellations = synchronized(lifecycleMutex) {
            if (!closed) {
                closed = true
                cache.clear()
                lifecycleChanged.notifyAll()
            }
            let values = ArrayList<api.CancellationSource>()
            for (operation in active) { values.add(operation.cancellation) }
            values
        }
        for (source in cancellations) { source.cancel() }
        synchronized(lifecycleMutex) {
            while (!active.isEmpty()) { lifecycleChanged.wait() }
        }
        match (delegate) {
            case Some(value) => value.close()
            case None => ()
        }
    }

    /** Returns whether this client has permanently stopped admission. */
    public func isClosed(): Bool { synchronized(lifecycleMutex) { closed } }

    private func lookupWire(
        host: api.HostName,
        options: api.ResolveOptions,
        context: api.OperationContext
    ): api.ResolveResult {
        let startedAt = MonoTime.now()
        let types = match (options.family) {
            case api.ResolveAddressFamily.Ipv4 => [DnsRecordType.A]
            case api.ResolveAddressFamily.Ipv6 => [DnsRecordType.AAAA]
            case api.ResolveAddressFamily.Any => [DnsRecordType.A, DnsRecordType.AAAA]
        }
        let addresses = ArrayList<api.IpAddress>()
        var earliestExpiration = None<MonoTime>
        var canonical = None<String>
        var canonicalNameserver = None<api.SocketEndpoint>
        var noDataError = None<api.ResolveException>
        var familyError = None<api.ResolveException>

        for (recordType in types) {
            checkDnsContext(context)
            let (result, nameserver) = try {
                resolveAddressType(host.ascii, recordType, context)
            } catch (error: api.ResolveException) {
                match (error.resolveCode) {
                    case api.ResolveErrorCode.NoData =>
                        if (noDataError.isNone() || error.remoteEndpoint.isSome()) { noDataError = Some(error) }
                    case api.ResolveErrorCode.TemporaryFailure | api.ResolveErrorCode.SystemFailure =>
                        familyError = Some(error)
                    case _ => throw error
                }
                continue
            }
            match (canonical) {
                case Some(value) =>
                    if (value != result.canonicalHost.ascii) {
                        let peer = if (nameserver.isSome()) { nameserver } else { canonicalNameserver }
                        let remote = match (peer) {
                            case Some(server) => Some(api.NetworkEndpoint.Internet(server))
                            case None => None<api.NetworkEndpoint>
                        }
                        throw api.ResolveException(
                            api.ResolveErrorCode.SystemFailure,
                            "DNS address families returned conflicting canonical names",
                            None<Int64>, None<api.NetworkEndpoint>, remote, None<Exception>
                        )
                    }
                case None =>
                    canonical = Some(result.canonicalHost.ascii)
                    canonicalNameserver = nameserver
            }
            let resolved = result.addresses
            for (address in resolved) {
                if (addresses.size >= options.maxResults) { break }
                if (!containsAddress(addresses, address)) { addresses.add(address) }
            }
            if (let Some(expiration) <- result.expiration) {
                earliestExpiration = match (earliestExpiration) {
                    case Some(current) => Some(if (expiration < current) { expiration } else { current })
                    case None => Some(expiration)
                }
            }
            if (addresses.size >= options.maxResults) { break }
        }

        if (addresses.isEmpty()) {
            if (let Some(error) <- familyError) { throw error }
            if (let Some(error) <- noDataError) { throw error }
            throw api.ResolveException(api.ResolveErrorCode.NoData, "DNS response contained no address records")
        }
        let completedAt = MonoTime.now()
        api.ResolveResult(
            addresses.toArray(),
            api.HostName(match (canonical) { case Some(value) => value; case None => host.ascii }),
            api.ResolverSource.System,
            expiration: earliestExpiration,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func resolveAddressType(
        initialName: String,
        recordType: DnsRecordType,
        context: api.OperationContext
    ): (api.ResolveResult, ?api.SocketEndpoint) {
        let initial = dnsCanonicalName(initialName)
        match (cached(initial)) {
            case Some(DnsCachedValue.Negative(kind)) => throw negativeCacheError(kind)
            case _ => ()
        }
        let initialKey = cacheKey(initial, recordType)
        match (cached(initialKey)) {
            case Some(DnsCachedValue.Positive(result)) => return (result, None<api.SocketEndpoint>)
            case Some(DnsCachedValue.Negative(kind)) => throw negativeCacheError(kind)
            case None => ()
        }

        let startedAt = MonoTime.now()
        let visited = ArrayList<String>()
        visited.add(initial)
        var current = initial
        var chainExpiration = None<MonoTime>

        while (true) {
            checkDnsContext(context)
            let (summary, nameserver) = queryWire(current, recordType, context)
            let receivedAt = MonoTime.now()
            try {
                match (summary.responseCode) {
                    case 0 | 3 => ()
                    case 2 | 5 => throw api.ResolveException(
                        api.ResolveErrorCode.TemporaryFailure,
                        "DNS servers exhausted temporary response failures"
                    )
                    case _ => throw api.ResolveException(
                        api.ResolveErrorCode.SystemFailure,
                        "DNS response uses an unsupported response code"
                    )
                }

                match (addressAnswer(summary, current, recordType, visited)) {
                    case DnsAddressAnswer.Addresses(values, finalName, ttl) =>
                        if (summary.responseCode == 3) {
                            throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "NXDOMAIN contains an address answer")
                        }
                        let completedAt = MonoTime.now()
                        let expiration = Some(earlierDnsExpiration(chainExpiration, receivedAt + ttlDuration(ttl)))
                        let result = api.ResolveResult(
                            values,
                            validatedCanonicalHost(finalName),
                            api.ResolverSource.System,
                            expiration: expiration,
                            startedAt: startedAt,
                            completedAt: completedAt
                        )
                        checkDnsContext(context)
                        cachePositive(initialKey, result)
                        return (result, Some(nameserver))
                    case DnsAddressAnswer.Alias(target, ttl) =>
                        chainExpiration = Some(earlierDnsExpiration(chainExpiration, receivedAt + ttlDuration(ttl)))
                        if (summary.responseCode == 3) {
                            cacheNegative(initial, DnsNegativeKind.NameNotFound, summary, target, receivedAt, chainExpiration, context)
                            throw negativeResponseError(DnsNegativeKind.NameNotFound, nameserver)
                        }
                        current = target
                    case DnsAddressAnswer.NoData =>
                        let nxdomain = summary.responseCode == 3
                        let kind = if (nxdomain) { DnsNegativeKind.NameNotFound } else { DnsNegativeKind.NoData }
                        let key = if (nxdomain) { initial } else { initialKey }
                        cacheNegative(key, kind, summary, current, receivedAt, chainExpiration, context)
                        throw negativeResponseError(kind, nameserver)
                }
            } catch (error: api.ResolveException) {
                throw mapResolveError(error, context, nameserver)
            }
        }
        throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS CNAME traversal terminated unexpectedly")
    }

    private func queryWire(
        name: String,
        recordType: DnsRecordType,
        context: api.OperationContext
    ): (DnsMessageSummary, api.SocketEndpoint) {
        let transactionId = dnsTransactionId()
        let request = dnsEncodeQuery(name, recordType, transactionId)
        let nameservers = config.nameservers
        var lastError: ?api.ResolveException = None<api.ResolveException>
        var remainingAttempts = config.attempts * nameservers.size

        for (_ in 0..config.attempts) {
            for (nameserver in nameservers) {
                checkDnsContext(context)
                // Entry points install one total deadline. Share its remaining
                // time across pending server attempts without extending it.
                let attemptContext = if (remainingAttempts > 1) {
                    context.shortenDeadline(context.deadline.getOrThrow().remaining() / remainingAttempts)
                } else {
                    context
                }
                remainingAttempts -= 1
                let failure = try {
                    let summary = queryUdp(nameserver, request, name, recordType, transactionId, attemptContext)
                    match (summary.responseCode) {
                        case 2 | 5 =>
                            mapResolveError(api.ResolveException(
                                api.ResolveErrorCode.TemporaryFailure,
                                "DNS server reported a temporary failure",
                                None<Int64>,
                                None<api.NetworkEndpoint>,
                                Some(api.NetworkEndpoint.Internet(nameserver)),
                                None<Exception>
                            ), context, nameserver)
                        case _ => return (summary, nameserver)
                    }
                } catch (error: api.ResolveException) {
                    mapResolveError(error, context, nameserver)
                } catch (error: api.NetworkException) {
                    mapNetworkError(error, context, nameserver)
                } catch (error: Exception) {
                    mapResolveError(api.ResolveException(api.ResolveErrorCode.SystemFailure,
                        "DNS transport failed", cause: Some(error)), context, nameserver)
                }
                match (failure.resolveCode) {
                    case api.ResolveErrorCode.Cancelled => throw failure
                    case api.ResolveErrorCode.Timeout =>
                        if (context.isDeadlineExceeded()) { throw failure }
                    case _ => ()
                }
                lastError = Some(failure)
            }
        }
        match (lastError) {
            case Some(error) => throw error
            case None => throw api.ResolveException(
                api.ResolveErrorCode.TemporaryFailure,
                "DNS query exhausted its bounded attempts"
            )
        }
    }

    private func queryUdp(
        nameserver: api.SocketEndpoint,
        request: Array<Byte>,
        name: String,
        recordType: DnsRecordType,
        transactionId: UInt16,
        context: api.OperationContext
    ): DnsMessageSummary {
        let socket = UdpSocket.bind(wildcardEndpoint(nameserver.address.family), context: context)
        var lastMalformed = None<api.ResolveException>
        try {
            let _ = socket.sendTo(
                api.NetworkEndpoint.Internet(nameserver),
                api.ByteSpan(request),
                context: context
            )
            for (_ in 0..DNS_MAX_PACKETS_PER_ATTEMPT) {
                checkDnsContext(context)
                let received = socket.receive(
                    min(limits.maximumMessageBytes, DNS_MAX_UDP_PAYLOAD),
                    context: context
                )
                if (!sourceMatches(received.source, nameserver)) { continue }
                if (received.truncated) {
                    lastMalformed = Some(api.ResolveException(
                        api.ResolveErrorCode.SystemFailure,
                        "DNS UDP datagram exceeded the parser message bound"
                    ))
                    continue
                }
                let identity = try {
                    dnsResponseQuestion(received.payload, limits)
                } catch (error: api.ResolveException) {
                    lastMalformed = Some(api.ResolveException(
                        api.ResolveErrorCode.SystemFailure,
                        "DNS response from the selected server is malformed",
                        cause: Some(error)
                    ))
                    continue
                }
                if (!identityMatches(identity, name, recordType, transactionId)) { continue }
                if (identity.truncated) {
                    return queryTcp(nameserver, request, name, recordType, transactionId, context)
                }
                let summary = DnsMessageParser(limits: limits).parse(received.payload)
                if (!identityMatches(summary, name, recordType, transactionId)) {
                    throw api.ResolveException(
                        api.ResolveErrorCode.SystemFailure,
                        "strict DNS response identity differs from its validated question"
                    )
                }
                return summary
            }
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
        match (lastMalformed) {
            case Some(error) => throw error
            case None => throw api.ResolveException(
                api.ResolveErrorCode.TemporaryFailure,
                "DNS response packet limit was exhausted by unrelated datagrams"
            )
        }
    }

    private func queryTcp(
        nameserver: api.SocketEndpoint,
        request: Array<Byte>,
        name: String,
        recordType: DnsRecordType,
        transactionId: UInt16,
        context: api.OperationContext
    ): DnsMessageSummary {
        let stream = TcpStream.connect(nameserver, context: context)
        try {
            let frame = Array<Byte>(request.size + 2, repeat: 0u8)
            frame[0] = UInt8(UInt64((request.size >> 8) & 0xFF))
            frame[1] = UInt8(UInt64(request.size & 0xFF))
            for (index in 0..request.size) { frame[index + 2] = request[index] }
            stream.writeAll(api.ByteSpan(frame), context: context)

            let lengthBytes = Array<Byte>(2, repeat: 0u8)
            stream.readExact(api.MutableByteSpan(lengthBytes), context: context)
            let length = (Int64(lengthBytes[0]) << 8) | Int64(lengthBytes[1])
            if (length < 12 || length > limits.maximumMessageBytes) {
                throw api.ResolveException(
                    api.ResolveErrorCode.SystemFailure,
                    "DNS TCP response length is outside the parser bounds"
                )
            }
            let response = Array<Byte>(length, repeat: 0u8)
            stream.readExact(api.MutableByteSpan(response), context: context)
            let summary = DnsMessageParser(limits: limits).parse(response)
            if (!identityMatches(summary, name, recordType, transactionId)) {
                throw api.ResolveException(
                    api.ResolveErrorCode.SystemFailure,
                    "DNS TCP response identity does not match the UDP query"
                )
            }
            if (summary.truncated) {
                throw api.ResolveException(
                    api.ResolveErrorCode.SystemFailure,
                    "DNS TCP response repeated the truncation flag"
                )
            }
            summary
        } finally {
            try { stream.close() } catch (_: Exception) {}
        }
    }

    private func addressAnswer(
        summary: DnsMessageSummary,
        queryName: String,
        recordType: DnsRecordType,
        visited: ArrayList<String>
    ): DnsAddressAnswer {
        var current = dnsCanonicalName(queryName)
        var chainTtl = None<UInt32>
        let records = summary.records

        while (true) {
            let addresses = ArrayList<api.IpAddress>()
            var alias = None<String>
            var ownerTtl = None<UInt32>
            for (index in 0..summary.answerCount) {
                let record = records[index]
                if (record.recordClass != DNS_IN_CLASS || dnsCanonicalName(record.name) != current) {
                    continue
                }
                if (isRecordType(record.recordType, recordType)) {
                    let data = record.data()
                    let address = match (recordType) {
                        case DnsRecordType.A =>
                            api.IpAddress(api.IpAddressFamily.Ipv4, data)
                        case DnsRecordType.AAAA =>
                            api.IpAddress(api.IpAddressFamily.Ipv6, data)
                        case _ => throw api.ResolveException(
                            api.ResolveErrorCode.SystemFailure,
                            "address extraction accepts only A and AAAA queries"
                        )
                    }
                    if (!containsAddress(addresses, address)) { addresses.add(address) }
                    ownerTtl = minimumTtl(ownerTtl, record.ttl)
                } else {
                    match (record.recordType) {
                        case DnsRecordType.CNAME =>
                            let target = match (record.targetName) {
                                case Some(value) => dnsCanonicalName(value)
                                case None => throw api.ResolveException(
                                    api.ResolveErrorCode.SystemFailure,
                                    "DNS CNAME answer has no decoded target"
                                )
                            }
                            match (alias) {
                                case Some(existing) =>
                                    if (existing != target) {
                                        throw api.ResolveException(
                                            api.ResolveErrorCode.SystemFailure,
                                            "DNS answer contains conflicting CNAME targets"
                                        )
                                    }
                                case None => alias = Some(target)
                            }
                            ownerTtl = minimumTtl(ownerTtl, record.ttl)
                        case _ => ()
                    }
                }
            }

            if (!addresses.isEmpty() && alias.isSome()) {
                throw api.ResolveException(
                    api.ResolveErrorCode.SystemFailure,
                    "DNS answer contains both CNAME and address data for one owner"
                )
            }
            if (!addresses.isEmpty()) {
                let ttl = ownerTtl.getOrThrow()
                return DnsAddressAnswer.Addresses(
                    addresses.toArray(),
                    current,
                    minimumTtl(chainTtl, ttl).getOrThrow()
                )
            }
            match (alias) {
                case Some(target) =>
                    let ttl = ownerTtl.getOrThrow()
                    chainTtl = minimumTtl(chainTtl, ttl)
                    if (containsName(visited, target)) {
                        throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS CNAME loop detected")
                    }
                    if (visited.size > DNS_MAX_CNAME_HOPS) {
                        throw api.ResolveException(
                            api.ResolveErrorCode.SystemFailure,
                            "DNS CNAME chain exceeds the bounded hop limit"
                        )
                    }
                    visited.add(target)
                    current = target
                case None =>
                    match (chainTtl) {
                        case Some(ttl) => return DnsAddressAnswer.Alias(current, ttl)
                        case None => return DnsAddressAnswer.NoData
                    }
            }
        }
        DnsAddressAnswer.NoData
    }

    private func identityMatches(
        summary: DnsMessageSummary,
        name: String,
        recordType: DnsRecordType,
        transactionId: UInt16
    ): Bool {
        if (!summary.isResponse || summary.opcode != 0 || summary.transactionId != transactionId ||
            summary.questionCount != 1) {
            return false
        }
        let questions = summary.questions
        if (questions.size != 1) { return false }
        let question = questions[0]
        question.recordClass == DNS_IN_CLASS &&
            dnsCanonicalName(question.name) == dnsCanonicalName(name) &&
            isRecordType(question.recordType, recordType)
    }

    private func admit(
        cancellation: api.CancellationSource,
        context: api.OperationContext
    ): Int64 {
        var isQueued = false
        try {
            while (true) {
                checkDnsContext(context)
                let waitDuration = match (context.deadline) {
                    case Some(deadline) =>
                        let remaining = deadline.remaining()
                        if (remaining <= Duration.Zero) { Duration.nanosecond } else { remaining }
                    case None => Duration.Max
                }
                let admitted = synchronized(lifecycleMutex) {
                    if (closed) {
                        if (isQueued) {
                            throw api.ResolveException(api.ResolveErrorCode.Cancelled, "DNS queued operation was cancelled")
                        }
                        throw clientClosedError()
                    }
                    if (cancellation.token.isCancellationRequested) {
                        -1
                    } else if (active.size < workerCount) {
                        if (isQueued) { queued--; isQueued = false }
                        let id = nextOperationId
                        nextOperationId++
                        active.add(ActiveDnsOperation(id, cancellation))
                        id
                    } else {
                        if (!isQueued) {
                            if (queued >= queueCapacity) {
                                throw api.ResolveException(
                                    api.ResolveErrorCode.TemporaryFailure,
                                    "DNS client admission queue is full"
                                )
                            }
                            queued++
                            isQueued = true
                        }
                        if (!closed && !cancellation.token.isCancellationRequested) {
                            lifecycleChanged.wait(timeout: waitDuration)
                        }
                        0
                    }
                }
                if (admitted > 0) { return admitted }
                if (admitted < 0) { checkDnsContext(context) }
            }
        } finally {
            if (isQueued) {
                synchronized(lifecycleMutex) {
                    queued--
                    lifecycleChanged.notifyAll()
                }
            }
        }
        throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS admission terminated unexpectedly")
    }

    private func finishOperation(id: Int64): Unit {
        synchronized(lifecycleMutex) {
            for (index in 0..active.size) {
                if (active[index].id == id) {
                    let _ = active.remove(at: index)
                    lifecycleChanged.notifyAll()
                    return
                }
            }
        }
    }

    private func wakeAdmission(): Unit {
        synchronized(lifecycleMutex) { lifecycleChanged.notifyAll() }
    }

    private func cached(key: String): ?DnsCachedValue {
        synchronized(lifecycleMutex) {
            let now = MonoTime.now()
            for (index in 0..cache.size) {
                let entry = cache[index]
                if (entry.key == key) {
                    if (now >= entry.expiresAt) {
                        let _ = cache.remove(at: index)
                        return None<DnsCachedValue>
                    }
                    let _ = cache.remove(at: index)
                    cache.add(entry)
                    return Some(entry.value)
                }
            }
            None<DnsCachedValue>
        }
    }

    private func cachePositive(
        key: String,
        result: api.ResolveResult
    ): Unit {
        match (result.expiration) {
            case Some(expiration) =>
                if (expiration > MonoTime.now()) {
                    putCache(DnsCacheEntry(key, DnsCachedValue.Positive(result), expiration))
                }
            case None => ()
        }
    }

    private func cacheNegative(
        key: String,
        kind: DnsNegativeKind,
        summary: DnsMessageSummary,
        deniedName: String,
        receivedAt: MonoTime,
        chainExpiration: ?MonoTime,
        context: api.OperationContext
    ): Unit {
        checkDnsContext(context)
        match (negativeCacheDuration(summary, deniedName)) {
            case Some(duration) =>
                let expiration = earlierDnsExpiration(chainExpiration, receivedAt + duration)
                if (expiration > MonoTime.now()) {
                    putCache(DnsCacheEntry(key, DnsCachedValue.Negative(kind), expiration))
                }
            case None => ()
        }
    }

    private func putCache(entry: DnsCacheEntry): Unit {
        synchronized(lifecycleMutex) {
            if (closed || config.cacheCapacity <= 0) { return }
            let nameWide = match (entry.value) {
                case DnsCachedValue.Negative(DnsNegativeKind.NameNotFound) => true
                case _ => false
            }
            let invalidatedPrefix = if (nameWide) { entry.key + "|" } else { "" }
            var index = cache.size
            while (index > 0) {
                index--
                if (cache[index].key == entry.key ||
                    (nameWide && cache[index].key.startsWith(invalidatedPrefix))) {
                    let _ = cache.remove(at: index)
                    if (!nameWide) { break }
                }
            }
            while (cache.size >= config.cacheCapacity) { let _ = cache.remove(at: 0) }
            cache.add(entry)
        }
    }

    private func negativeCacheDuration(summary: DnsMessageSummary, deniedName: String): ?Duration {
        var minimum = None<UInt32>
        let start = summary.answerCount
        let end = start + summary.authorityCount
        let records = summary.records
        for (index in start..end) {
            let record = records[index]
            if (record.recordClass != DNS_IN_CLASS) { continue }
            if (record.name != "." && record.name != deniedName &&
                !deniedName.endsWith("." + record.name)) { continue }
            match (record.recordType) {
                case DnsRecordType.SOA =>
                    if (let Some(soaMinimum) <- record.soaMinimum) {
                        minimum = minimumTtl(minimum, min(record.ttl, soaMinimum))
                    }
                case _ => ()
            }
        }
        match (minimum) {
            case Some(value) => Some(ttlDuration(value))
            case None => None<Duration>
        }
    }

    private func ttlDuration(ttl: UInt32): Duration {
        let wire = Duration.second * Int64(ttl)
        if (wire < config.maximumCacheTtl) { wire } else { config.maximumCacheTtl }
    }

    private func mapResolveError(
        error: api.ResolveException,
        context: api.OperationContext,
        nameserver: api.SocketEndpoint
    ): api.ResolveException {
        let (code, message) = if (context.isCancellationRequested()) {
            (api.ResolveErrorCode.Cancelled, "DNS operation cancelled")
        } else if (context.isDeadlineExceeded()) {
            (api.ResolveErrorCode.Timeout, "DNS operation deadline exceeded")
        } else {
            if (error.remoteEndpoint.isSome()) { return error }
            (error.resolveCode, error.message)
        }
        let remote = match (error.remoteEndpoint) {
            case Some(endpoint) => Some(endpoint)
            case None => Some(api.NetworkEndpoint.Internet(nameserver))
        }
        api.ResolveException(code, message, error.nativeCode, error.localEndpoint, remote, Some(error))
    }

    private func mapNetworkError(
        error: api.NetworkException,
        context: api.OperationContext,
        nameserver: api.SocketEndpoint
    ): api.ResolveException {
        let (code, message) = if (context.isCancellationRequested()) {
            (api.ResolveErrorCode.Cancelled, "DNS operation cancelled")
        } else if (context.isDeadlineExceeded()) {
            (api.ResolveErrorCode.Timeout, "DNS operation deadline exceeded")
        } else {
            match (error.code) {
                case api.NetworkErrorCode.Cancelled =>
                    (api.ResolveErrorCode.Cancelled, "DNS transport was cancelled")
                case api.NetworkErrorCode.TimedOut =>
                    (api.ResolveErrorCode.Timeout, "DNS transport timed out")
                case _ =>
                    (api.ResolveErrorCode.TemporaryFailure,
                        "DNS transport failed before a valid response was received")
            }
        }
        let remoteEndpoint = match (error.remoteEndpoint) {
            case Some(endpoint) => Some(endpoint)
            case None => Some(api.NetworkEndpoint.Internet(nameserver))
        }
        api.ResolveException(code, message, error.nativeCode,
            error.localEndpoint, remoteEndpoint, Some(error))
    }

    private func wildcardEndpoint(family: api.IpAddressFamily): api.SocketEndpoint {
        match (family) {
            case api.IpAddressFamily.Ipv4 => api.SocketEndpoint(
                api.IpAddress(api.IpAddressFamily.Ipv4, [0u8, 0u8, 0u8, 0u8]),
                0u16
            )
            case api.IpAddressFamily.Ipv6 => api.SocketEndpoint(
                api.IpAddress(api.IpAddressFamily.Ipv6, Array<Byte>(16, repeat: 0u8)),
                0u16
            )
        }
    }

    private func sourceMatches(
        source: ?api.NetworkEndpoint,
        expected: api.SocketEndpoint
    ): Bool {
        match (source) {
            case Some(api.NetworkEndpoint.Internet(value)) => value == expected
            case _ => false
        }
    }

    private func cacheKey(name: String, recordType: DnsRecordType): String {
        "${dnsCanonicalName(name)}|${dnsTypeCode(recordType)}"
    }

    private func clientClosedError(): api.ResolveException {
        api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS client is closed")
    }

    private func negativeResponseError(
        kind: DnsNegativeKind,
        nameserver: api.SocketEndpoint
    ): api.ResolveException {
        let (code, message) = match (kind) {
            case DnsNegativeKind.NameNotFound =>
                (api.ResolveErrorCode.NameNotFound, "DNS name does not exist")
            case DnsNegativeKind.NoData =>
                (api.ResolveErrorCode.NoData, "DNS name has no records for the requested family")
        }
        api.ResolveException(code, message, None<Int64>, None<api.NetworkEndpoint>,
            Some(api.NetworkEndpoint.Internet(nameserver)), None<Exception>)
    }

    private func negativeCacheError(kind: DnsNegativeKind): api.ResolveException {
        match (kind) {
            case DnsNegativeKind.NameNotFound => api.ResolveException(
                api.ResolveErrorCode.NameNotFound,
                "DNS NXDOMAIN negative cache hit"
            )
            case DnsNegativeKind.NoData => api.ResolveException(
                api.ResolveErrorCode.NoData,
                "DNS NODATA negative cache hit"
            )
        }
    }
}

private func dnsTransactionId(): UInt16 {
    try {
        let source = File("/dev/urandom", OpenMode.Read)
        try {
            let bytes = Array<Byte>(2, repeat: 0u8)
            let first = source.read(bytes)
            if (first == 2) { return (UInt16(bytes[0]) << 8) | UInt16(bytes[1]) }
            if (first == 1) {
                let remaining = Array<Byte>(1, repeat: 0u8)
                if (source.read(remaining) == 1) {
                    return (UInt16(bytes[0]) << 8) | UInt16(remaining[0])
                }
            }
            throw api.ResolveException(api.ResolveErrorCode.SystemFailure,
                "DNS transaction entropy source returned an incomplete value")
        } finally { source.close() }
    } catch (error: api.ResolveException) {
        throw error
    } catch (error: Exception) {
        throw api.ResolveException(api.ResolveErrorCode.SystemFailure,
            "DNS transaction entropy is unavailable", cause: Some(error))
    }
}


private func isRecordType(left: DnsRecordType, right: DnsRecordType): Bool {
    dnsTypeCode(left) == dnsTypeCode(right)
}

private func validatedCanonicalHost(name: String): api.HostName {
    try {
        api.HostName(name)
    } catch (error: IllegalArgumentException) {
        throw api.ResolveException(
            api.ResolveErrorCode.SystemFailure,
            "DNS CNAME target is not a valid address host name",
            cause: Some(error)
        )
    }
}

private func minimumTtl(current: ?UInt32, candidate: UInt32): ?UInt32 {
    match (current) {
        case Some(value) => Some(min(value, candidate))
        case None => Some(candidate)
    }
}

private func earlierDnsExpiration(current: ?MonoTime, candidate: MonoTime): MonoTime {
    match (current) {
        case Some(value) => if (value < candidate) { value } else { candidate }
        case None => candidate
    }
}

private func containsName(values: ArrayList<String>, expected: String): Bool {
    for (value in values) { if (value == expected) { return true } }
    false
}

private func containsAddress(
    values: ArrayList<api.IpAddress>,
    expected: api.IpAddress
): Bool {
    for (value in values) { if (value == expected) { return true } }
    false
}
