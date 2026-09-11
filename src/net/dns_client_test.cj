package wirestack.net

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func dnsClientTestLoopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func dnsClientTestEndpoint(socket: UdpSocket): api.SocketEndpoint {
    match (socket.localEndpoint) {
        case Some(api.NetworkEndpoint.Internet(value)) => value
        case _ => throw IllegalStateException("expected an Internet UDP endpoint")
    }
}

private func dnsClientTestAppendU16(output: ArrayList<Byte>, value: Int64): Unit {
    output.add(UInt8(UInt64((value >> 8) & 0xFF)))
    output.add(UInt8(UInt64(value & 0xFF)))
}

private func dnsClientTestAppendU32(output: ArrayList<Byte>, value: UInt32): Unit {
    output.add(UInt8(UInt64((value >> 24) & 0xFFu32)))
    output.add(UInt8(UInt64((value >> 16) & 0xFFu32)))
    output.add(UInt8(UInt64((value >> 8) & 0xFFu32)))
    output.add(UInt8(UInt64(value & 0xFFu32)))
}

private func dnsClientTestHeader(
    query: Array<Byte>,
    flags: UInt16,
    answers!: Int64 = 0,
    authority!: Int64 = 0,
    additional!: Int64 = 0
): ArrayList<Byte> {
    let header = query.clone()
    header[2] = UInt8(UInt64((flags >> 8) & 0xFFu16))
    header[3] = UInt8(UInt64(flags & 0xFFu16))
    header[6] = UInt8(UInt64((answers >> 8) & 0xFF))
    header[7] = UInt8(UInt64(answers & 0xFF))
    header[8] = UInt8(UInt64((authority >> 8) & 0xFF))
    header[9] = UInt8(UInt64(authority & 0xFF))
    header[10] = UInt8(UInt64((additional >> 8) & 0xFF))
    header[11] = UInt8(UInt64(additional & 0xFF))
    let output = ArrayList<Byte>()
    for (value in header) { output.add(value) }
    output
}

private func dnsClientTestAppendA(
    output: ArrayList<Byte>,
    ownerPointer: Int64,
    ttl: UInt32,
    address: Array<Byte>
): Unit {
    dnsClientTestAppendU16(output, 0xC000 | ownerPointer)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU32(output, ttl)
    dnsClientTestAppendU16(output, 4)
    for (value in address) { output.add(value) }
}

private func dnsClientTestAResponse(
    query: Array<Byte>,
    address: Array<Byte>,
    ttl!: UInt32 = 30u32
): Array<Byte> {
    let output = dnsClientTestHeader(query, 0x8180u16, answers: 1)
    dnsClientTestAppendA(output, 12, ttl, address)
    output.toArray()
}

private func dnsClientTestName(name: String): Array<Byte> {
    let output = ArrayList<Byte>()
    for (label in name.split(".")) {
        let bytes = label.toArray()
        output.add(UInt8(UInt64(bytes.size)))
        for (value in bytes) { output.add(value) }
    }
    output.add(0u8)
    output.toArray()
}

private func dnsClientTestAppendCname(
    output: ArrayList<Byte>,
    target: String,
    ttl: UInt32
): Unit {
    let targetBytes = dnsClientTestName(target)
    dnsClientTestAppendU16(output, 0xC00C)
    dnsClientTestAppendU16(output, 5)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU32(output, ttl)
    dnsClientTestAppendU16(output, targetBytes.size)
    for (value in targetBytes) { output.add(value) }
}

private func dnsClientTestCnameAddressResponse(
    query: Array<Byte>,
    target: String,
    address: Array<Byte>
): Array<Byte> {
    let output = dnsClientTestHeader(query, 0x8180u16, answers: 2)
    dnsClientTestAppendCname(output, target, 20u32)
    let targetBytes = dnsClientTestName(target)
    for (value in targetBytes) { output.add(value) }
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU32(output, 10u32)
    dnsClientTestAppendU16(output, 4)
    for (value in address) { output.add(value) }
    output.toArray()
}

private func dnsClientTestConflictingCnames(query: Array<Byte>): Array<Byte> {
    let output = dnsClientTestHeader(query, 0x8180u16, answers: 2)
    dnsClientTestAppendCname(output, "first.test", 20u32)
    dnsClientTestAppendCname(output, "second.test", 20u32)
    output.toArray()
}

private func dnsClientTestPoisonedAdditional(query: Array<Byte>): Array<Byte> {
    let output = dnsClientTestHeader(query, 0x8180u16, answers: 1, additional: 1)
    output.add(4u8)
    for (value in "evil".toArray()) { output.add(value) }
    output.add(4u8)
    for (value in "test".toArray()) { output.add(value) }
    output.add(0u8)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU32(output, 30u32)
    dnsClientTestAppendU16(output, 4)
    for (value in [203u8, 0u8, 113u8, 9u8]) { output.add(value) }
    dnsClientTestAppendA(output, 12, 30u32, [198u8, 51u8, 100u8, 8u8])
    output.toArray()
}

private func dnsClientTestNegative(
    query: Array<Byte>,
    nxdomain: Bool,
    soaTtl!: UInt32 = 20u32,
    soaMinimum!: UInt32 = 5u32
): Array<Byte> {
    let output = dnsClientTestHeader(
        query,
        if (nxdomain) { 0x8183u16 } else { 0x8180u16 },
        authority: 1
    )
    dnsClientTestAppendU16(output, 0xC00C)
    dnsClientTestAppendU16(output, 6)
    dnsClientTestAppendU16(output, 1)
    dnsClientTestAppendU32(output, soaTtl)
    dnsClientTestAppendU16(output, 22)
    output.add(0u8)
    output.add(0u8)
    dnsClientTestAppendU32(output, 1u32)
    dnsClientTestAppendU32(output, 2u32)
    dnsClientTestAppendU32(output, 3u32)
    dnsClientTestAppendU32(output, 4u32)
    dnsClientTestAppendU32(output, soaMinimum)
    output.toArray()
}

private func dnsClientTestTcpFrame(message: Array<Byte>): Array<Byte> {
    let frame = Array<Byte>(message.size + 2, repeat: 0u8)
    frame[0] = UInt8(UInt64((message.size >> 8) & 0xFF))
    frame[1] = UInt8(UInt64(message.size & 0xFF))
    for (index in 0..message.size) { frame[index + 2] = message[index] }
    frame
}

private func dnsClientTestConfig(
    endpoint: api.SocketEndpoint,
    cacheCapacity!: Int64 = 8,
    maximumCacheTtl!: Duration = 30 * Duration.second
): DnsResolverConfig {
    DnsResolverConfig(
        nameservers: [endpoint],
        queryTimeout: Duration.second,
        attempts: 1,
        cacheCapacity: cacheCapacity,
        maximumCacheTtl: maximumCacheTtl
    )
}


private func dnsClientTestTypeCode(recordType: DnsRecordType): Int64 {
    match (recordType) {
        case DnsRecordType.A => 1
        case DnsRecordType.AAAA => 28
        case DnsRecordType.CNAME => 5
        case DnsRecordType.SRV => 33
        case DnsRecordType.TXT => 16
        case DnsRecordType.MX => 15
        case DnsRecordType.PTR => 12
        case DnsRecordType.SOA => 6
        case DnsRecordType.Unknown(value) => value
    }
}

private func dnsClientTestResolveCode(
    operation: () -> Unit
): api.ResolveErrorCode {
    try {
        operation()
    } catch (error: api.ResolveException) {
        return error.resolveCode
    }
    throw Exception("expected ResolveException")
}

private func dnsClientTestCodeIs(
    actual: api.ResolveErrorCode,
    expected: api.ResolveErrorCode
): Bool {
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

private class DnsClientTestGate {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var arrived = false
    private var released = false

    func arriveAndWait(): Unit {
        synchronized(mutex) {
            arrived = true
            changed.notifyAll()
            while (!released) { changed.wait() }
        }
    }

    func waitForArrival(): Unit {
        let deadline = api.Deadline.after(Duration.second)
        synchronized(mutex) {
            while (!arrived) {
                if (deadline.isExpired()) { throw Exception("DNS fixture did not receive a query") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }

    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}

private class DnsClientTestCompletion {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var count: Int64 = 0

    func finish(): Unit {
        synchronized(mutex) {
            count++
            changed.notifyAll()
        }
    }

    func waitFor(expected: Int64): Unit {
        let deadline = api.Deadline.after(Duration.second)
        synchronized(mutex) {
            while (count < expected) {
                if (deadline.isExpired()) { throw Exception("bounded DNS contender did not finish") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
}

@Test
class DnsClientWireTest {
    @TestCase
    func publicQueryAndLookupUseRealUdpAndRetainAbsoluteCacheExpiry(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving: Future<Int64> = spawn {
            var served: Int64 = 0
            while (served < 2) {
                let received = server.receive(
                    512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
                )
                let _ = server.sendTo(
                    received.source.getOrThrow(),
                    api.ByteSpan(dnsClientTestAResponse(received.payload, [192u8, 0u8, 2u8, 44u8], ttl: 10u32))
                )
                served++
            }
            served
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            let summary = client.query("Example.Test.", DnsRecordType.A)
            @Expect(summary.answerCount, 1)
            @Expect(summary.records[0].data(), [192u8, 0u8, 2u8, 44u8])


            let first = client.lookup(
                api.HostName("example.test"),
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
            )
            let retainedExpiry = first.expiration
            let second = client.lookup(
                api.HostName("example.test"),
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
            )
            @Expect(first.addresses, second.addresses)
            @Expect(second.expiration, retainedExpiry)
            @Expect(second.addresses[0].toOctets(), [192u8, 0u8, 2u8, 44u8])
            @Expect(serving.get(Duration.second), 2)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func publicQueryEncodesEveryModeledRecordType(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let types = [
            DnsRecordType.A,
            DnsRecordType.AAAA,
            DnsRecordType.CNAME,
            DnsRecordType.SRV,
            DnsRecordType.TXT,
            DnsRecordType.MX,
            DnsRecordType.PTR,
            DnsRecordType.SOA,
            DnsRecordType.Unknown(65280)
        ]
        let serving: Future<Int64> = spawn {
            var served: Int64 = 0
            while (served < types.size) {
                let received = server.receive(
                    512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
                )
                let response = dnsClientTestHeader(received.payload, 0x8180u16).toArray()
                let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response))
                served++
            }
            served
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            for (recordType in types) {
                let summary = client.query("_service._tcp.example.test", recordType)
                @Expect(summary.answerCount, 0)
                @Expect(
                    dnsClientTestTypeCode(summary.questions[0].recordType),
                    dnsClientTestTypeCode(recordType)
                )
            }
            @Expect(serving.get(Duration.second), types.size)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func wrongSourceIdAndQuestionAreIgnoredBeforeValidUdpResponse(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let rogue = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving = spawn {
            let received = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let destination = received.source.getOrThrow()
            let poison = dnsClientTestAResponse(received.payload, [203u8, 0u8, 113u8, 7u8])
            let _ = rogue.sendTo(destination, api.ByteSpan(poison))

            let wrongId = poison.clone()
            wrongId[1] = wrongId[1] ^ 1u8
            let _ = server.sendTo(destination, api.ByteSpan(wrongId))

            let wrongQuestion = poison.clone()
            wrongQuestion[received.payload.size - 3] = 28u8
            let _ = server.sendTo(destination, api.ByteSpan(wrongQuestion))

            let valid = dnsClientTestAResponse(received.payload, [198u8, 51u8, 100u8, 17u8])
            let _ = server.sendTo(destination, api.ByteSpan(valid))
            true
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            let summary = client.query("identity.test", DnsRecordType.A)
            @Expect(summary.records[0].data(), [198u8, 51u8, 100u8, 17u8])
            @Expect(serving.get(Duration.second))
        } finally {
            client.close()
            rogue.close()
            server.close()
        }
    }

    @TestCase
    func validatedTruncationFallsBackToExactTcpFrame(): Unit {
        let udp = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(udp)
        let tcp = TcpListener.bind(endpoint)
        let udpServing = spawn {
            let received = udp.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let truncated = dnsClientTestHeader(received.payload, 0x8380u16, answers: 1).toArray()
            let _ = udp.sendTo(received.source.getOrThrow(), api.ByteSpan(truncated))
            true
        }
        let tcpServing = spawn {
            let stream = tcp.accept(
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            try {
                let lengthBytes = Array<Byte>(2, repeat: 0u8)
                stream.readExact(
                    api.MutableByteSpan(lengthBytes),
                    context: api.OperationContext.background()
                )
                let length = (Int64(lengthBytes[0]) << 8) | Int64(lengthBytes[1])
                let query = Array<Byte>(length, repeat: 0u8)
                stream.readExact(
                    api.MutableByteSpan(query),
                    context: api.OperationContext.background()
                )
                let response = dnsClientTestAResponse(query, [192u8, 0u8, 2u8, 91u8])
                stream.writeAll(
                    api.ByteSpan(dnsClientTestTcpFrame(response)),
                    context: api.OperationContext.background()
                )
                true
            } finally {
                stream.close()
            }
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            let summary = client.query("tcp.test", DnsRecordType.A)
            @Expect(summary.records[0].data(), [192u8, 0u8, 2u8, 91u8])
            @Expect(udpServing.get(Duration.second))
            @Expect(tcpServing.get(Duration.second))
        } finally {
            client.close()
            tcp.close()
            udp.close()
        }
    }

    @TestCase
    func activeCancellationRetainsNameserverWithoutRetry(): Unit {
        let first = UdpSocket.bind(dnsClientTestLoopback(0))
        let second = UdpSocket.bind(dnsClientTestLoopback(0))
        let firstEndpoint = dnsClientTestEndpoint(first)
        let cancellation = api.CancellationSource()
        let serving = spawn {
            let _ = first.receive(512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
            cancellation.cancel()
            true
        }
        let client = DnsClient(config: DnsResolverConfig(
            nameservers: [firstEndpoint, dnsClientTestEndpoint(second)], attempts: 2))
        try {
            let error = @AssertThrows[api.ResolveException](client.query("cancel-failover.test",
                DnsRecordType.A, context: api.OperationContext(cancellation: cancellation.token)))
            @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.Cancelled))
            match (error.remoteEndpoint) {
                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, firstEndpoint)
                case _ => @Fail("active DNS cancellation lost its nameserver")
            }
            @Expect(serving.get(Duration.second))
            let noRetry = @AssertThrows[api.NetworkException](second.receive(512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(50 * Duration.millisecond)))))
            @Expect(match (noRetry.code) {
                case api.NetworkErrorCode.TimedOut => true
                case _ => false
            })
        } finally {
            client.close()
            second.close()
            first.close()
        }
    }

    @TestCase
    func silentDnsAttemptsLeaveBudgetForServerAndPassFailover(): Unit {
        for (retrySameServer in [false, true]) {
            let first = UdpSocket.bind(dnsClientTestLoopback(0))
            let responder = if (retrySameServer) { first } else { UdpSocket.bind(dnsClientTestLoopback(0)) }
            let firstEndpoint = dnsClientTestEndpoint(first)
            let responderEndpoint = dnsClientTestEndpoint(responder)
            let serving = spawn {
                let peerContext = api.OperationContext(
                    deadline: Some(api.Deadline.after(2 * Duration.second)))
                if (retrySameServer) { let _ = first.receive(512, context: peerContext) }
                let query = responder.receive(512, context: peerContext)
                let _ = responder.sendTo(query.source.getOrThrow(),
                    api.ByteSpan(dnsClientTestAResponse(query.payload, [192u8, 0u8, 2u8, 88u8])))
                true
            }
            let nameservers = if (retrySameServer) { [firstEndpoint] } else { [firstEndpoint, responderEndpoint] }
            let client = DnsClient(config: DnsResolverConfig(nameservers: nameservers,
                attempts: if (retrySameServer) { 2 } else { 1 }, queryTimeout: Duration.second))
            let context = api.OperationContext(
                deadline: Some(api.Deadline.after(500 * Duration.millisecond)))
            try {
                let response = client.query("failover.test", DnsRecordType.A, context: context)
                @Expect(response.records[0].data(), [192u8, 0u8, 2u8, 88u8])
                @Expect(!context.isDeadlineExceeded())
                @Expect(serving.get(Duration.second))
            } finally {
                client.close()
                responder.close()
                first.close()
            }
        }
    }

    @TestCase
    func exhaustedResponseCodesRetainTheLastRespondingNameserver(): Unit {
        let first = UdpSocket.bind(dnsClientTestLoopback(0))
        let second = UdpSocket.bind(dnsClientTestLoopback(0))
        let firstEndpoint = dnsClientTestEndpoint(first)
        let secondEndpoint = dnsClientTestEndpoint(second)
        let serving = spawn {
            let context = api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            let firstQuery = first.receive(512, context: context)
            let _ = first.sendTo(firstQuery.source.getOrThrow(),
                api.ByteSpan(dnsClientTestHeader(firstQuery.payload, 0x8182u16).toArray()))
            let secondQuery = second.receive(512, context: context)
            let _ = second.sendTo(secondQuery.source.getOrThrow(),
                api.ByteSpan(dnsClientTestHeader(secondQuery.payload, 0x8185u16).toArray()))
            true
        }
        let client = DnsClient(config: DnsResolverConfig(
            nameservers: [firstEndpoint, secondEndpoint], attempts: 1))
        try {
            let error = @AssertThrows[api.ResolveException](client.query("refused.test", DnsRecordType.A))
            @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.TemporaryFailure))
            match (error.remoteEndpoint) {
                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, secondEndpoint)
                case _ => @Fail("DNS RCODE failure lost its responding nameserver")
            }
            @Expect(serving.get(Duration.second))
        } finally {
            client.close()
            second.close()
            first.close()
        }
    }

    @TestCase
    func unsupportedResponseCodeRetainsRespondingNameserver(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving = spawn {
            let received = server.receive(512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
            let _ = server.sendTo(received.source.getOrThrow(),
                api.ByteSpan(dnsClientTestHeader(received.payload, 0x8181u16).toArray()))
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            let error = @AssertThrows[api.ResolveException](client.lookup(api.HostName("formerr.test"),
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)))
            @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.SystemFailure))
            match (error.remoteEndpoint) {
                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                case _ => @Fail("unsupported DNS response code lost its responding nameserver")
            }
            serving.get(Duration.second)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func dnsTransportFailuresRetainSelectedNameserver(): Unit {
        for (tcpFallback in [false, true]) {
            let server = UdpSocket.bind(dnsClientTestLoopback(0))
            let endpoint = dnsClientTestEndpoint(server)
            let tcp = if (tcpFallback) { Some(TcpListener.bind(endpoint)) } else { None<TcpListener> }
            let serving = spawn {
                let received = server.receive(512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
                if (let Some(listener) <- tcp) {
                    let truncated = dnsClientTestHeader(received.payload, 0x8380u16).toArray()
                    let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(truncated))
                    let stream = listener.accept(
                        context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
                    stream.close()
                }
                received.source.getOrThrow()
            }
            let client = DnsClient(config: DnsResolverConfig(
                nameservers: [endpoint], attempts: 1, queryTimeout: 250 * Duration.millisecond))
            try {
                let error = @AssertThrows[api.ResolveException](
                    client.query("transport-error.test", DnsRecordType.A))
                let caller = serving.get(Duration.second)
                match (error.remoteEndpoint) {
                    case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                    case _ => @Fail("DNS transport error lost the selected nameserver")
                }
                if (!tcpFallback) {
                    @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.Timeout))
                    match ((error.localEndpoint, caller)) {
                        case (Some(api.NetworkEndpoint.Internet(local)), api.NetworkEndpoint.Internet(peer)) =>
                            @Expect(local.port, peer.port)
                        case _ => @Fail("DNS receive error lost its local socket")
                    }
                } else {
                    @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.TemporaryFailure))
                }
                @Expect(error.cause.isSome())
            } finally {
                client.close()
                if (let Some(listener) <- tcp) { listener.close() }
                server.close()
            }
        }
    }

    @TestCase
    func tcpResponseCannotRemainTruncated(): Unit {
        let udp = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(udp)
        let tcp = TcpListener.bind(endpoint)
        let udpServing = spawn {
            let received = udp.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let truncated = dnsClientTestHeader(received.payload, 0x8380u16).toArray()
            let _ = udp.sendTo(received.source.getOrThrow(), api.ByteSpan(truncated))
            true
        }
        let tcpServing = spawn {
            let stream = tcp.accept(
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            try {
                let lengthBytes = Array<Byte>(2, repeat: 0u8)
                stream.readExact(
                    api.MutableByteSpan(lengthBytes),
                    context: api.OperationContext.background()
                )
                let length = (Int64(lengthBytes[0]) << 8) | Int64(lengthBytes[1])
                let query = Array<Byte>(length, repeat: 0u8)
                stream.readExact(
                    api.MutableByteSpan(query),
                    context: api.OperationContext.background()
                )
                let stillTruncated = dnsClientTestHeader(query, 0x8380u16).toArray()
                stream.writeAll(
                    api.ByteSpan(dnsClientTestTcpFrame(stillTruncated)),
                    context: api.OperationContext.background()
                )
                true
            } finally {
                stream.close()
            }
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            let error = @AssertThrows[api.ResolveException](
                client.query("still-truncated.test", DnsRecordType.A))
            @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.SystemFailure))
            match (error.remoteEndpoint) {
                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                case _ => @Fail("truncated TCP DNS response lost its nameserver")
            }
            @Expect(error.cause.isSome())
            @Expect(udpServing.get(Duration.second))
            @Expect(tcpServing.get(Duration.second))
        } finally {
            client.close()
            tcp.close()
            udp.close()
        }
    }

    @TestCase
    func malformedMatchingResponseAndUnrelatedSectionsCannotPoisonCache(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving = spawn {
            let first = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let malformed = dnsClientTestHeader(first.payload, 0x8180u16, answers: 1).toArray()
            let _ = server.sendTo(first.source.getOrThrow(), api.ByteSpan(malformed))
            let second = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let _ = server.sendTo(
                second.source.getOrThrow(),
                api.ByteSpan(dnsClientTestPoisonedAdditional(second.payload))
            )
            let third = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let _ = server.sendTo(
                third.source.getOrThrow(),
                api.ByteSpan(dnsClientTestAResponse(third.payload, [192u8, 0u8, 2u8, 33u8]))
            )
            true
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        let options = api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
        try {
            let malformed = @AssertThrows[api.ResolveException](
                client.lookup(api.HostName("poison.test"), options: options))
            @Expect(dnsClientTestCodeIs(malformed.resolveCode, api.ResolveErrorCode.SystemFailure))
            match (malformed.remoteEndpoint) {
                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                case _ => @Fail("malformed UDP DNS response lost its nameserver")
            }
            @Expect(malformed.cause.isSome())
            let noData = dnsClientTestResolveCode({ =>
                let _ = client.lookup(api.HostName("poison.test"), options: options)
            })
            @Expect(dnsClientTestCodeIs(noData, api.ResolveErrorCode.NoData))
            let valid = client.lookup(api.HostName("poison.test"), options: options)
            @Expect(valid.addresses[0].toOctets(), [192u8, 0u8, 2u8, 33u8])
            @Expect(serving.get(Duration.second))
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func cnameTraversalUsesAnswerOwnersAndRejectsConflictingTargets(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving: Future<Int64> = spawn {
            let first = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let _ = server.sendTo(
                first.source.getOrThrow(),
                api.ByteSpan(dnsClientTestCnameAddressResponse(
                    first.payload,
                    "target.test",
                    [192u8, 0u8, 2u8, 61u8]
                ))
            )
            let second = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            let _ = server.sendTo(
                second.source.getOrThrow(),
                api.ByteSpan(dnsClientTestConflictingCnames(second.payload))
            )
            2
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        let options = api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
        try {
            let result = client.lookup(api.HostName("alias.test"), options: options)
            @Expect(result.canonicalHost.ascii, "target.test")
            @Expect(result.addresses[0].toOctets(), [192u8, 0u8, 2u8, 61u8])
            let conflict = @AssertThrows[api.ResolveException](
                client.lookup(api.HostName("conflict.test"), options: options))
            @Expect(dnsClientTestCodeIs(conflict.resolveCode, api.ResolveErrorCode.SystemFailure))
            match (conflict.remoteEndpoint) {
                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                case _ => @Fail("conflicting CNAME response lost its responding nameserver")
            }
            @Expect(serving.get(Duration.second), 2)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func fullResultCapacityDoesNotQueryAnotherFamily(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving = spawn {
            let received = server.receive(512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
            let _ = server.sendTo(received.source.getOrThrow(),
                api.ByteSpan(dnsClientTestAResponse(received.payload, [192u8, 0u8, 2u8, 71u8])))
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            for (_ in 0..2) {
                let result = client.lookup(api.HostName("capacity.test"),
                    options: api.ResolveOptions(family: api.ResolveAddressFamily.Any, maxResults: 1))
                @Expect(result.addresses.size, 1)
                @Expect(result.addresses[0].toOctets(), [192u8, 0u8, 2u8, 71u8])
            }
            serving.get(Duration.second)
            try {
                let _ = server.receive(512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(50 * Duration.millisecond))))
                @Expect(false)
            } catch (error: api.NetworkException) {
                match (error.code) {
                    case api.NetworkErrorCode.TimedOut => ()
                    case _ => @Fail("unexpected receive error")
                }
            }
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func rfc2308CacheRetainsNxdomainVersusNodataWithoutNewPackets(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving: Future<Int64> = spawn {
            var served: Int64 = 0
            while (served < 3) {
                let received = server.receive(
                    512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
                )
                let question = DnsMessageParser().parse(received.payload).questions[0]
                var response = dnsClientTestNegative(
                    received.payload,
                    question.name != "empty.test"
                )
                if (question.name == "alias.test") {
                    let output = dnsClientTestHeader(received.payload, 0x8183u16, answers: 1, authority: 1)
                    dnsClientTestAppendCname(output, "missing.test", 20u32)
                    output.add(0u8)
                    for (index in (received.payload.size + 2)..response.size) { output.add(response[index]) }
                    response = output.toArray()
                }
                let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response))
                served++
            }
            served
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        let options = api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
        try {
            for (pass in 0..2) {
                for (name in ["missing.test", "empty.test", "alias.test"]) {
                    try {
                        let _ = client.lookup(api.HostName(name), options: options)
                        @Expect(false)
                    } catch (error: api.ResolveException) {
                        let expected = if (name == "empty.test") {
                            api.ResolveErrorCode.NoData
                        } else {
                            api.ResolveErrorCode.NameNotFound
                        }
                        @Expect(dnsClientTestCodeIs(error.resolveCode, expected))
                        if (pass == 0) {
                            match (error.remoteEndpoint) {
                                case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                                case _ => @Fail("live negative answer lost its responding nameserver")
                            }
                        } else {
                            @Expect(error.remoteEndpoint.isNone())
                        }
                    }
                }
            }
            @Expect(serving.get(Duration.second), 3)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func zeroTtlNeverCreatesAPositiveCacheEntry(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving: Future<Int64> = spawn {
            var served: Int64 = 0
            while (served < 2) {
                let received = server.receive(
                    512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
                )
                let response = dnsClientTestAResponse(
                    received.payload,
                    [192u8, 0u8, 2u8, UInt8(UInt64(served + 1))],
                    ttl: 0u32
                )
                let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response))
                served++
            }
            served
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        let options = api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
        try {
            let first = client.lookup(api.HostName("zero.test"), options: options)
            let second = client.lookup(api.HostName("zero.test"), options: options)
            @Expect(first.addresses[0].toOctets(), [192u8, 0u8, 2u8, 1u8])
            @Expect(second.addresses[0].toOctets(), [192u8, 0u8, 2u8, 2u8])
            @Expect(serving.get(Duration.second), 2)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func callerCancellationAndClientCloseWakeActiveNativeReceive(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let firstGate = DnsClientTestGate()
        let firstServer = spawn {
            let _ = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            firstGate.arriveAndWait()
        }
        let cancellation = api.CancellationSource()
        let firstClient = DnsClient(config: dnsClientTestConfig(endpoint))
        let cancelled = spawn {
            dnsClientTestResolveCode({ =>
                let _ = firstClient.query(
                    "cancel.test",
                    DnsRecordType.A,
                    context: api.OperationContext(cancellation: cancellation.token)
                )
            })
        }
        firstGate.waitForArrival()
        cancellation.cancel()
        @Expect(dnsClientTestCodeIs(cancelled.get(Duration.second), api.ResolveErrorCode.Cancelled))
        firstGate.release()
        firstServer.get(Duration.second)
        firstClient.close()

        let secondGate = DnsClientTestGate()
        let secondServer = spawn {
            let _ = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            secondGate.arriveAndWait()
        }
        let secondClient = DnsClient(config: dnsClientTestConfig(endpoint))
        let closed = spawn {
            dnsClientTestResolveCode({ =>
                let _ = secondClient.query("close.test", DnsRecordType.A)
            })
        }
        secondGate.waitForArrival()
        secondClient.close()
        @Expect(dnsClientTestCodeIs(closed.get(Duration.second), api.ResolveErrorCode.Cancelled))
        @Expect(secondClient.isClosed())
        let afterClose = dnsClientTestResolveCode({ =>
            let _ = secondClient.query("after-close.test", DnsRecordType.A)
        })
        @Expect(dnsClientTestCodeIs(afterClose, api.ResolveErrorCode.SystemFailure))
        secondGate.release()
        secondServer.get(Duration.second)
        server.close()
    }

    @TestCase
    func anyFamilyRetainsAddressesWhenTheOtherFamilyFails(): Unit {
        for ((failingType, flags) in [(1, 0x8182u16), (28, 0x8181u16)]) {
            let server = UdpSocket.bind(dnsClientTestLoopback(0))
            let endpoint = dnsClientTestEndpoint(server)
            let serving = spawn {
                for (_ in 0..2) {
                    let received = server.receive(
                        512,
                        context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
                    )
                    let query = received.payload
                    let kind = Int64(query[query.size - 3])
                    let response = if (kind == failingType) {
                        dnsClientTestHeader(query, flags).toArray()
                    } else {
                        let output = dnsClientTestHeader(query, 0x8180u16, answers: 1)
                        dnsClientTestAppendU16(output, 0xC00C)
                        dnsClientTestAppendU16(output, kind)
                        dnsClientTestAppendU16(output, 1)
                        dnsClientTestAppendU32(output, 30u32)
                        let bytes = if (kind == 1) {
                            [192u8, 0u8, 2u8, 44u8]
                        } else {
                            Array<Byte>(16, repeat: 1u8)
                        }
                        dnsClientTestAppendU16(output, bytes.size)
                        for (value in bytes) { output.add(value) }
                        output.toArray()
                    }
                    let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response))
                }
                true
            }
            let client = DnsClient(config: dnsClientTestConfig(endpoint))
            try {
                let result = client.lookup(api.HostName("family.test"))
                @Assert(result.addresses.size, 1)
                @Expect(result.addresses[0].toOctets(),
                    if (failingType == 1) { Array<Byte>(16, repeat: 1u8) } else { [192u8, 0u8, 2u8, 44u8] })
                @Expect(serving.get(Duration.second))
            } finally {
                client.close()
                server.close()
            }
        }
    }

    @TestCase
    func crossFamilyConflictsRetainTheLivePeerAlongsideCachedResults(): Unit {
        for (cachedFamily in [api.ResolveAddressFamily.Ipv4, api.ResolveAddressFamily.Ipv6]) {
            let server = UdpSocket.bind(dnsClientTestLoopback(0))
            let endpoint = dnsClientTestEndpoint(server)
            let serving = spawn {
                for (_ in 0..2) {
                    let received = server.receive(512,
                        context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
                    let query = received.payload
                    let kind = Int64(query[query.size - 3])
                    let target = if (kind == 1) { "v4.test" } else { "v6.test" }
                    let output = dnsClientTestHeader(query, 0x8180u16, answers: 2)
                    dnsClientTestAppendCname(output, target, 30u32)
                    for (value in dnsClientTestName(target)) { output.add(value) }
                    dnsClientTestAppendU16(output, kind)
                    dnsClientTestAppendU16(output, 1)
                    dnsClientTestAppendU32(output, 30u32)
                    let bytes = if (kind == 1) { [192u8, 0u8, 2u8, 81u8] } else { Array<Byte>(16, repeat: 1u8) }
                    dnsClientTestAppendU16(output, bytes.size)
                    for (value in bytes) { output.add(value) }
                    let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(output.toArray()))
                }
            }
            let client = DnsClient(config: dnsClientTestConfig(endpoint))
            try {
                let _ = client.lookup(api.HostName("split.test"),
                    options: api.ResolveOptions(family: cachedFamily))
                for (pass in 0..2) {
                    let error = @AssertThrows[api.ResolveException](client.lookup(api.HostName("split.test")))
                    @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.SystemFailure))
                    if (pass == 0) {
                        match (error.remoteEndpoint) {
                            case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                            case _ => @Fail("cross-family conflict lost its live responding nameserver")
                        }
                    } else {
                        @Expect(error.remoteEndpoint.isNone())
                    }
                }
                serving.get(Duration.second)
            } finally {
                client.close()
                server.close()
            }
        }
    }

    @TestCase
    func noncacheableNxdomainStopsOtherFamilyQueries(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let served = AtomicInt64(0)
        let serving = spawn {
            for (index in 0..2) {
                let received = server.receive(512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
                let response = if (index == 0) {
                    dnsClientTestHeader(received.payload, 0x8183u16).toArray()
                } else {
                    let output = dnsClientTestHeader(received.payload, 0x8180u16, answers: 1)
                    dnsClientTestAppendU16(output, 0xC00C)
                    dnsClientTestAppendU16(output, 28)
                    dnsClientTestAppendU16(output, 1)
                    dnsClientTestAppendU32(output, 30u32)
                    dnsClientTestAppendU16(output, 16)
                    for (_ in 0..16) { output.add(1u8) }
                    output.toArray()
                }
                let _ = served.fetchAdd(1)
                let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response))
            }
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            let error = @AssertThrows[api.ResolveException](client.lookup(api.HostName("uncached-negative.test")))
            @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.NameNotFound))
            @Expect(served.load(), 1)
            let later = client.lookup(api.HostName("uncached-negative.test"),
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv6))
            @Expect(later.addresses[0].toOctets(), Array<Byte>(16, repeat: 1u8))
            serving.get(Duration.second)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func nameWideNegativeOverridesEarlierFamilyFailure(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let serving = spawn {
            for (_ in 0..2) {
                let received = server.receive(512,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
                let query = received.payload
                let response = if (query[query.size - 3] == 1u8) {
                    dnsClientTestHeader(query, 0x8182u16).toArray()
                } else {
                    dnsClientTestNegative(query, true)
                }
                let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response))
            }
        }
        let client = DnsClient(config: dnsClientTestConfig(endpoint))
        try {
            for (pass in 0..2) {
                let error = @AssertThrows[api.ResolveException](client.lookup(api.HostName("definitive.test")))
                @Expect(dnsClientTestCodeIs(error.resolveCode, api.ResolveErrorCode.NameNotFound))
                if (pass == 0) {
                    match (error.remoteEndpoint) {
                        case Some(api.NetworkEndpoint.Internet(remote)) => @Expect(remote, endpoint)
                        case _ => @Fail("definitive negative response lost its nameserver")
                    }
                } else {
                    @Expect(error.remoteEndpoint.isNone())
                }
            }
            serving.get(Duration.second)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func boundedAdmissionRejectsExcessAndCloseWakesQueuedCallers(): Unit {
        let server = UdpSocket.bind(dnsClientTestLoopback(0))
        let endpoint = dnsClientTestEndpoint(server)
        let activeGate = DnsClientTestGate()
        let serverTask = spawn {
            let _ = server.receive(
                512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
            )
            activeGate.arriveAndWait()
        }
        let client = DnsClient(
            config: dnsClientTestConfig(endpoint),
            workerCount: 1,
            queueCapacity: 1
        )
        let activeQuery = spawn {
            dnsClientTestResolveCode({ =>
                let _ = client.query("active.test", DnsRecordType.A)
            })
        }
        activeGate.waitForArrival()

        let simultaneous = SyncCounter(4)
        let completed = DnsClientTestCompletion()
        let contenders = ArrayList<Future<api.ResolveErrorCode>>()
        for (index in 0..4) {
            contenders.add(spawn {
                simultaneous.dec()
                simultaneous.waitUntilZero()
                let code = dnsClientTestResolveCode({ =>
                    let _ = client.query(
                        "queued-${index}.test",
                        DnsRecordType.A,
                        context: api.OperationContext(
                            deadline: Some(api.Deadline.after(Duration.second))
                        )
                    )
                })
                completed.finish()
                code
            })
        }
        simultaneous.waitUntilZero()
        completed.waitFor(3)
        let closing = spawn { client.close(); true }
        @Expect(closing.get(Duration.second))
        @Expect(dnsClientTestCodeIs(activeQuery.get(Duration.second), api.ResolveErrorCode.Cancelled))
        var temporaryFailures: Int64 = 0
        var cancellations: Int64 = 0
        for (contender in contenders) {
            let code = contender.get(Duration.second)
            match (code) {
                case api.ResolveErrorCode.TemporaryFailure => temporaryFailures++
                case api.ResolveErrorCode.Cancelled => cancellations++
                case api.ResolveErrorCode.SystemFailure => ()
                case _ => @Fail("bounded contender returned an unexpected resolver error")
            }
        }
        activeGate.release()
        serverTask.get(Duration.second)
        server.close()
        @Expect(temporaryFailures, 3)
        @Expect(cancellations, 1)
    }
}
