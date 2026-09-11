package wirestack_m8_004_native_dns

import std.collection.ArrayList
import std.convert.Parsable
import std.env.getStdOut
import std.env.getVariable
import wirestack as api
import wirestack.net.*

func announce(value: String): Unit { println(value); getStdOut().flush() }
func require(value: Bool, message: String): Unit { if (!value) { throw Exception(message) } }

func dnsPort(): UInt16 { UInt16.parse(getVariable("WIRESTACK_DNS_PORT").getOrThrow()) }
func endpoint(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}
func config(cacheCapacity!: Int64 = 32): DnsResolverConfig {
    DnsResolverConfig(
        nameservers: [endpoint(dnsPort())],
        hostsPath: "",
        queryTimeout: 5 * Duration.second,
        attempts: 1,
        cacheCapacity: cacheCapacity,
        maximumCacheTtl: 60 * Duration.second
    )
}
func ipv4Options(): api.ResolveOptions {
    api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4, maxResults: 4)
}
func boundedContext(seconds!: Int64 = 5): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(seconds * Duration.second)))
}
func typeCode(value: DnsRecordType): Int64 {
    match (value) {
        case DnsRecordType.A => 1
        case DnsRecordType.AAAA => 28
        case DnsRecordType.CNAME => 5
        case DnsRecordType.SRV => 33
        case DnsRecordType.TXT => 16
        case DnsRecordType.MX => 15
        case DnsRecordType.PTR => 12
        case DnsRecordType.SOA => 6
        case DnsRecordType.Unknown(code) => code
    }
}
func sameResolveCode(actual: api.ResolveErrorCode, expected: api.ResolveErrorCode): Bool {
    match ((actual, expected)) {
        case (api.ResolveErrorCode.NameNotFound, api.ResolveErrorCode.NameNotFound) => true
        case (api.ResolveErrorCode.NoData, api.ResolveErrorCode.NoData) => true
        case (api.ResolveErrorCode.TemporaryFailure, api.ResolveErrorCode.TemporaryFailure) => true
        case (api.ResolveErrorCode.Timeout, api.ResolveErrorCode.Timeout) => true
        case (api.ResolveErrorCode.Cancelled, api.ResolveErrorCode.Cancelled) => true
        case (api.ResolveErrorCode.SystemFailure, api.ResolveErrorCode.SystemFailure) => true
        case _ => false
    }
}
func resolveCode(operation: () -> Unit): api.ResolveErrorCode {
    try {
        operation()
    } catch (error: api.ResolveException) {
        return error.resolveCode
    }
    throw Exception("DNS operation unexpectedly succeeded")
}
func expectResolve(expected: api.ResolveErrorCode, operation: () -> Unit): Unit {
    require(sameResolveCode(resolveCode(operation), expected), "DNS operation returned the wrong structured error")
}
func firstOctets(result: api.ResolveResult): Array<Byte> {
    require(!result.addresses.isEmpty(), "DNS result contained no addresses")
    result.addresses[0].toOctets()
}

func runBasic(): Unit {
    let client = DnsClient(config: config())
    try {
        let a = client.query("a.native.test.", DnsRecordType.A, context: boundedContext())
        require(a.answerCount == 1 && a.questions.size == 1 && typeCode(a.questions[0].recordType) == 1,
            "UDP A response summary changed")
        require(a.records[0].data() == [192u8, 0u8, 2u8, 10u8], "UDP A bytes changed")
        let resolved = client.lookup(api.HostName("a.native.test"), options: ipv4Options(), context: boundedContext())
        require(resolved.addresses.size == 1 && firstOctets(resolved) == [192u8, 0u8, 2u8, 10u8],
            "authority glue entered the address answer")

        let aaaa = client.query("aaaa.native.test", DnsRecordType.AAAA, context: boundedContext())
        require(aaaa.answerCount == 1 && typeCode(aaaa.questions[0].recordType) == 28,
            "UDP AAAA response summary changed")
        require(aaaa.records[0].data() == [0x20u8, 0x01u8, 0x0Du8, 0xB8u8, 0u8, 0u8, 0u8, 0u8,
            0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0x2Au8], "UDP AAAA bytes changed")

        let owner = client.lookup(api.HostName("owner.native.test"), options: ipv4Options(), context: boundedContext())
        require(owner.canonicalHost.ascii == "target.native.test", "CNAME canonical owner changed")
        require(firstOctets(owner) == [198u8, 51u8, 100u8, 77u8],
            "unrelated answer owner poisoned CNAME address selection")
    } finally { client.close() }
    announce("BASIC_PASS")
}

func runFallbackIdentity(): Unit {
    let client = DnsClient(config: config(cacheCapacity: 0))
    try {
        let summary = client.query("fallback.native.test", DnsRecordType.A, context: boundedContext())
        require(summary.answerCount == 1, "TCP fallback answer count changed")
        require(summary.records[0].data() == [203u8, 0u8, 113u8, 91u8],
            "wrong-source or wrong-identity DNS response was accepted")
    } finally { client.close() }
    announce("FALLBACK_IDENTITY_PASS")
}

func expectIpv4Lookup(client: DnsClient, name: String, expected: Array<Byte>): Unit {
    let result = client.lookup(api.HostName(name), options: ipv4Options(), context: boundedContext())
    require(firstOctets(result) == expected, "DNS lookup returned unexpected IPv4 bytes for ${name}")
}

func runCachePolicy(): Unit {
    let client = DnsClient(config: config())
    try {
        for (_ in 0..2) {
            expectResolve(api.ResolveErrorCode.NameNotFound, { =>
                let _ = client.lookup(api.HostName("auth-negative.native.test"),
                    options: ipv4Options(), context: boundedContext())
            })
        }
        for (_ in 0..2) {
            expectResolve(api.ResolveErrorCode.NameNotFound, { =>
                let _ = client.lookup(api.HostName("no-soa.native.test"),
                    options: ipv4Options(), context: boundedContext())
            })
        }
        for (_ in 0..2) {
            expectResolve(api.ResolveErrorCode.NameNotFound, { =>
                let _ = client.lookup(api.HostName("unrelated-soa.native.test"),
                    options: ipv4Options(), context: boundedContext())
            })
        }
        for (_ in 0..2) {
            expectResolve(api.ResolveErrorCode.NameNotFound, { =>
                let _ = client.lookup(api.HostName("nonauth-soa.native.test"),
                    options: ipv4Options(), context: boundedContext())
            })
        }
        expectIpv4Lookup(client, "ttl-zero.native.test", [192u8, 0u8, 2u8, 1u8])
        expectIpv4Lookup(client, "ttl-zero.native.test", [192u8, 0u8, 2u8, 2u8])
    } finally { client.close() }
    announce("CACHE_POLICY_PASS")
}

func runCnameTtl(): Unit {
    let client = DnsClient(config: config())
    try {
        expectIpv4Lookup(client, "short-alias.native.test", [192u8, 0u8, 2u8, 41u8])
        expectIpv4Lookup(client, "short-alias.native.test", [192u8, 0u8, 2u8, 42u8])
        for (_ in 0..2) {
            expectResolve(api.ResolveErrorCode.NameNotFound, { =>
                let _ = client.lookup(api.HostName("short-negative-alias.native.test"),
                    options: ipv4Options(), context: boundedContext())
            })
        }
    } finally { client.close() }
    announce("CNAME_TTL_PASS")
}

func runCacheCapacity(): Unit {
    let client = DnsClient(config: config(cacheCapacity: 2))
    try {
        let first = client.lookup(api.HostName("lru-a.native.test"), options: ipv4Options(), context: boundedContext())
        require(firstOctets(first) == [192u8, 0u8, 2u8, 1u8], "initial cache address changed")
        require(first.expiration.getOrThrow() <= first.diagnostics.completedAt + 60 * Duration.second,
            "wire TTL escaped the configured cache lifetime cap")
        expectIpv4Lookup(client, "lru-b.native.test", [192u8, 0u8, 2u8, 2u8])
        expectIpv4Lookup(client, "lru-a.native.test", [192u8, 0u8, 2u8, 1u8])
        expectIpv4Lookup(client, "lru-c.native.test", [192u8, 0u8, 2u8, 3u8])
        expectIpv4Lookup(client, "lru-b.native.test", [192u8, 0u8, 2u8, 4u8])
    } finally { client.close() }
    announce("CACHE_CAPACITY_PASS")
}

func runCnameBounds(): Unit {
    let client = DnsClient(config: config(cacheCapacity: 0))
    try {
        for (name in ["long-chain.native.test", "loop-chain.native.test"]) {
            expectResolve(api.ResolveErrorCode.SystemFailure, { =>
                let _ = client.lookup(api.HostName(name), options: ipv4Options(), context: boundedContext())
            })
        }
    } finally { client.close() }
    announce("CNAME_BOUNDS_PASS")
}

func runCombinedNegative(): Unit {
    let client = DnsClient(config: config())
    try {
        expectResolve(api.ResolveErrorCode.NameNotFound, { =>
            let _ = client.lookup(api.HostName("combined-negative.native.test"),
                options: ipv4Options(), context: boundedContext())
        })
        let _ = client.query("expiry-barrier.native.test", DnsRecordType.A, context: boundedContext())
        expectIpv4Lookup(client, "combined-negative.native.test", [192u8, 0u8, 2u8, 73u8])
    } finally { client.close() }
    announce("COMBINED_NEGATIVE_PASS")
}

func runNegativeScope(): Unit {
    let client = DnsClient(config: config())
    try {
        for (family in [api.ResolveAddressFamily.Ipv4, api.ResolveAddressFamily.Ipv6]) {
            expectResolve(api.ResolveErrorCode.NameNotFound, { =>
                let _ = client.lookup(api.HostName("namewide.native.test"),
                    options: api.ResolveOptions(family: family), context: boundedContext())
            })
        }
    } finally { client.close() }
    announce("NEGATIVE_SCOPE_PASS")
}

func runSearchBoundary(): Unit {
    let suffixes = ArrayList<api.HostName>()
    for (index in 0..15) { suffixes.add(api.HostName("s${index}.test")) }
    let resolver = Resolver(config: DnsResolverConfig(
        nameservers: [endpoint(dnsPort())], searchDomains: suffixes.toArray(), ndots: 1,
        hostsPath: "", queryTimeout: 5 * Duration.second, attempts: 1, cacheCapacity: 0
    ))
    try {
        let result = resolver.resolve("node.test", options: ipv4Options(), context: boundedContext())
        require(firstOctets(result) == [192u8, 0u8, 2u8, 74u8], "last search suffix was not resolved")
    } finally { resolver.close() }
    announce("SEARCH_BOUNDARY_PASS")
}

func waitForPending(kind: String, action: String): Unit {
    let client = DnsClient(config: config(cacheCapacity: 0))
    let cancellation = api.CancellationSource()
    announce("WAIT_READY ${kind} ${action}")
    let pending = spawn {
        resolveCode({ =>
            let _ = client.query("pending-${kind}-${action}.native.test", DnsRecordType.A,
                context: api.OperationContext(cancellation: cancellation.token,
                    deadline: Some(api.Deadline.after(5 * Duration.second))))
        })
    }
    try {
        require(readln() == "stop", "pending DNS fixture was not acknowledged")
        if (action == "cancel") { cancellation.cancel() } else { client.close() }
        require(sameResolveCode(pending.get(2 * Duration.second), api.ResolveErrorCode.Cancelled),
            "pending DNS operation did not finish as cancelled")
        require(action != "close" || client.isClosed(), "client close did not become terminal")
        announce("WAIT_PASS ${kind} ${action}")
        require(readln() == "next", "pending DNS completion was not acknowledged")
    } finally { cancellation.cancel(); client.close() }
}

func runLifecycle(): Unit {
    waitForPending("udp", "cancel")
    waitForPending("udp", "close")
    waitForPending("tcp", "cancel")
    waitForPending("tcp", "close")
    announce("LIFECYCLE_PASS")
}

func runConnect(): Unit {
    let resolver = Resolver(config: config(cacheCapacity: 0))
    let servicePort = UInt16.parse(getVariable("WIRESTACK_SERVICE_PORT").getOrThrow())
    let operation = api.OperationContext(deadline: Some(api.Deadline.after(2 * Duration.second)))
    try {
        let transport = resolver.connect(api.HostName("service.native.test"), servicePort,
            options: ipv4Options(), attemptDelay: 10 * Duration.millisecond, context: operation)
        try {
            api.writeAll(transport, api.ByteSpan("ping".toArray()), context: operation)
            let reply = Array<Byte>(4, repeat: 0u8)
            api.readExact(transport, api.MutableByteSpan(reply), context: operation)
            require(reply == "pong".toArray(), "Resolver.connect service exchange changed")
        } finally { transport.close() }
    } finally { resolver.close() }
    announce("CONNECT_PASS")
}

func runSystemFallback(): Unit {
    let settings = DnsResolverConfig(searchDomains: [api.HostName("chosen.test")],
        hostsPath: "", queryTimeout: 5 * Duration.second, cacheCapacity: 0)
    let resolver = Resolver(config: settings)
    try {
        let absolute = resolver.resolve("printer.", options: ipv4Options(), context: boundedContext())
        require(firstOctets(absolute) == [192u8, 0u8, 2u8, 10u8],
            "absolute name was expanded by the system search policy")
        let relative = resolver.resolve("printer", options: ipv4Options(), context: boundedContext())
        require(firstOctets(relative) == [192u8, 0u8, 2u8, 20u8],
            "configured search candidate was expanded twice")
    } finally { resolver.close() }
    let client = DnsClient(config: settings)
    try {
        let direct = client.lookup(api.HostName("direct"), options: ipv4Options(), context: boundedContext())
        require(firstOctets(direct) == [192u8, 0u8, 2u8, 30u8],
            "direct DNS lookup applied the system search policy")
        let label = String.fromUtf8(Array<Byte>(63, repeat: b'a'))
        let last = String.fromUtf8(Array<Byte>(61, repeat: b'a'))
        let maximum = client.lookup(api.HostName("${label}.${label}.${label}.${last}"),
            options: ipv4Options(), context: boundedContext())
        require(firstOctets(maximum) == [192u8, 0u8, 2u8, 40u8],
            "maximum-length DNS name was rejected by the system fallback")
    } finally { client.close() }
    let literalResolver = Resolver(config: settings)
    try {
        let literal = literalResolver.resolve("127.0.0.1", options: ipv4Options(), context: boundedContext())
        require(firstOctets(literal) == [127u8, 0u8, 0u8, 1u8], "IPv4 literal depended on system DNS")
        let port = UInt16.parse(getVariable("WIRESTACK_SERVICE_PORT").getOrThrow())
        let stream = literalResolver.connect(api.HostName("127.0.0.1"), port,
            options: ipv4Options(), context: boundedContext())
        try {
            api.writeAll(stream, api.ByteSpan("ping".toArray()), context: boundedContext())
            let reply = Array<Byte>(4, repeat: 0u8)
            api.readExact(stream, api.MutableByteSpan(reply), context: boundedContext())
            require(reply == "pong".toArray(), "literal Resolver.connect exchange failed")
        } finally { stream.close() }
    } finally { literalResolver.close() }
    announce("SYSTEM_FALLBACK_PASS")
}

main(arguments: Array<String>): Int64 {
    require(arguments.size == 1, "expected exactly one native DNS scenario argument")
    match (arguments[0]) {
        case "basic" => runBasic()
        case "fallback-identity" => runFallbackIdentity()
        case "cache-policy" => runCachePolicy()
        case "cname-ttl" => runCnameTtl()
        case "cache-capacity" => runCacheCapacity()
        case "cname-bounds" => runCnameBounds()
        case "combined-negative" => runCombinedNegative()
        case "negative-scope" => runNegativeScope()
        case "search-boundary" => runSearchBoundary()
        case "system-fallback" => runSystemFallback()
        case "lifecycle" => runLifecycle()
        case "connect" => runConnect()
        case _ => throw IllegalArgumentException("unknown native DNS scenario")
    }
    0
}
