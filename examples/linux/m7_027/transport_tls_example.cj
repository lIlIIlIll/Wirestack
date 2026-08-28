package wirestack_m7_027_examples

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import wirestack.tls as tls

func runTransportTlsExample(): Unit {
    let certificate = tls.DerCertificate(exampleCertificateDer())
    let chain = tls.CertificateChain([certificate])
    let serverKey = tls.PrivateKeyRef.pkcs8(examplePrivateKeyDer())
    let clientKey = tls.PrivateKeyRef.pkcs8(examplePrivateKeyDer())
    let serverContext = tls.TlsServerContext.builder()
        .identity(tls.LocalIdentity(chain, serverKey))
        .clientAuthentication(tls.ClientAuthentication.Required)
        .clientTrust(tls.TrustPolicy.customRoots(chain))
        .alpn(["example/1"])
        .build()
    let clientContext = tls.TlsClientContext.builder()
        .trust(tls.TrustPolicy.customRoots(chain))
        .identity(tls.LocalIdentity(chain, clientKey))
        .alpn(["example/1"])
        .build()
    let (clientTransport, serverTransport) = ExampleTransport.pair()
    let exchangeComplete = ExampleExchangeLatch()
    let context = tls.OperationContext(
        deadline: Some(tls.Deadline.after(5 * Duration.second))
    )
    let serverResult: Future<Bool> = spawn {
        let connection = serverContext.handshake(serverTransport, context: context)
        try {
            let received = readTlsBytes(connection, 4, context)
            exampleRequire(String.fromUtf8(received) == "ping", "mTLS server payload")
            writeTlsBytes(connection, "pong".toArray(), context)
            let accepted = connection.handshakeInfo.negotiatedAlpn == Some("example/1") &&
                connection.handshakeInfo.peerCertificateChain.isSome()
            exchangeComplete.wait()
            accepted
        } finally { connection.abort(reason: Some(tls.AbortReason.ApplicationAbort)) }
    }
    try {
        let connection = clientContext.handshake(
            clientTransport,
            tls.HostName("example.com"),
            context: context
        )
        try {
            exampleRequire(
                connection.handshakeInfo.negotiatedAlpn == Some("example/1"),
                "existing transport ALPN"
            )
            exampleRequire(
                connection.handshakeInfo.provider.id == "aws-lc",
                "existing transport provider metadata"
            )
            writeTlsBytes(connection, "ping".toArray(), context)
            exampleRequire(
                String.fromUtf8(readTlsBytes(connection, 4, context)) == "pong",
                "existing transport payload"
            )
            exchangeComplete.release()
            exampleRequire(serverResult.get(5 * Duration.second), "required client certificate")
        } finally { connection.abort(reason: Some(tls.AbortReason.ApplicationAbort)) }
        println("EXISTING_TRANSPORT_TLS=PASS")
        println("MTLS=PASS")
    } finally {
        clientTransport.abort(reason: Some(tls.AbortReason.ApplicationAbort))
        serverTransport.abort(reason: Some(tls.AbortReason.ApplicationAbort))
        serverKey.close()
        clientKey.close()
    }
}

private class ExampleExchangeLatch {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var complete = false

    func release(): Unit {
        synchronized(mutex) { complete = true; changed.notifyAll() }
    }

    func wait(): Unit {
        synchronized(mutex) {
            let expires = MonoTime.now() + 5 * Duration.second
            while (!complete) {
                let remaining = expires - MonoTime.now()
                if (remaining <= Duration.Zero) {
                    throw IllegalStateException("example TLS exchange did not complete")
                }
                changed.wait(timeout: remaining)
            }
        }
    }
}

private func writeTlsBytes(
    connection: tls.TlsConnection,
    bytes: Array<Byte>,
    context: tls.OperationContext
): Unit {
    var remaining = tls.ByteSpan(bytes)
    while (!remaining.isEmpty()) {
        let count = connection.writeSome(remaining, context: context)
        exampleRequire(count > 0 && count <= remaining.length, "TLS partial write")
        remaining = remaining.advance(count)
    }
}

private func readTlsBytes(
    connection: tls.TlsConnection,
    count: Int64,
    context: tls.OperationContext
): Array<Byte> {
    let bytes = Array<Byte>(count, repeat: 0u8)
    var remaining = tls.MutableByteSpan(bytes)
    while (!remaining.isEmpty()) {
        match (connection.readSome(remaining, context: context)) {
            case tls.ReadResult.Data(received) =>
                exampleRequire(received > 0 && received <= remaining.length, "TLS partial read")
                remaining = remaining.advance(received)
            case tls.ReadResult.EndOfStream =>
                throw IllegalStateException("TLS peer closed before example payload completed")
        }
    }
    bytes
}

/** Bounded caller-owned transport used to demonstrate the public TLS SPI. */
private class ExampleTransport <: tls.DuplexTransport {
    private let incoming: ExamplePipe
    private let outgoing: ExamplePipe
    private let mutex = Mutex()
    private var closed = false

    private init(incoming: ExamplePipe, outgoing: ExamplePipe) {
        this.incoming = incoming
        this.outgoing = outgoing
    }

    static func pair(): (ExampleTransport, ExampleTransport) {
        let leftToRight = ExamplePipe(256 * 1024)
        let rightToLeft = ExamplePipe(256 * 1024)
        (
            ExampleTransport(rightToLeft, leftToRight),
            ExampleTransport(leftToRight, rightToLeft)
        )
    }

    public prop info: tls.TransportInfo {
        get() { tls.TransportInfo("example-pipe", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        destination: tls.MutableByteSpan,
        context!: tls.OperationContext = tls.OperationContext.background()
    ): tls.ReadResult {
        incoming.read(destination, context)
    }

    public func writeSome(
        source: tls.ByteSpan,
        context!: tls.OperationContext = tls.OperationContext.background()
    ): Int64 {
        outgoing.write(source, context)
    }

    public func shutdown(direction: tls.ShutdownDirection): Unit {
        match (direction) {
            case tls.ShutdownDirection.Read => incoming.closeReader()
            case tls.ShutdownDirection.Write => outgoing.closeWriter()
        }
    }

    public func close(_: tls.OperationContext): Unit { close() }

    public func close(): Unit {
        let claimed = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (claimed) {
            incoming.closeReader()
            outgoing.closeWriter()
        }
    }

    public func abort(reason!: ?tls.AbortReason = None<tls.AbortReason>): Unit {
        let _ = reason
        let claimed = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (claimed) {
            incoming.abort()
            outgoing.abort()
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private class ExamplePipe {
    private let capacity: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let bytes = ArrayList<Byte>()
    private var writerClosed = false
    private var readerClosed = false
    private var aborted = false

    init(capacity: Int64) { this.capacity = capacity }

    func read(destination: tls.MutableByteSpan, context: tls.OperationContext): tls.ReadResult {
        if (destination.isEmpty()) { return tls.ReadResult.Data(0) }
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (bytes.isEmpty() && !writerClosed && !readerClosed && !aborted) {
                    checkContext(context)
                    match (context.deadline) {
                        case Some(deadline) =>
                            let remaining = deadline.remaining()
                            if (remaining <= Duration.Zero) {
                                throw IllegalStateException("example transport deadline exceeded")
                            }
                            changed.wait(timeout: remaining)
                        case None => changed.wait()
                    }
                }
                checkContext(context)
                if (aborted) { throw IllegalStateException("example transport aborted") }
                if (readerClosed) { throw IllegalStateException("example transport reader closed") }
                if (bytes.isEmpty() && writerClosed) { return tls.ReadResult.EndOfStream }
                let count = min(destination.length, bytes.size)
                for (index in 0..count) {
                    destination.bytes[destination.offset + index] = bytes.remove(at: 0)
                }
                tls.ReadResult.Data(count)
            }
        } finally { registration.unregister() }
    }

    func write(source: tls.ByteSpan, context: tls.OperationContext): Int64 {
        if (source.isEmpty()) { return 0 }
        checkContext(context)
        synchronized(mutex) {
            if (aborted || writerClosed || readerClosed) {
                throw IllegalStateException("example transport is closed")
            }
            if (source.length > capacity - bytes.size) {
                throw IllegalStateException("example transport capacity exceeded")
            }
            for (index in 0..source.length) {
                bytes.add(source.bytes[source.offset + index])
            }
            changed.notifyAll()
            source.length
        }
    }

    func closeWriter(): Unit {
        synchronized(mutex) { writerClosed = true; changed.notifyAll() }
    }

    func closeReader(): Unit {
        synchronized(mutex) { readerClosed = true; bytes.clear(); changed.notifyAll() }
    }

    func abort(): Unit {
        synchronized(mutex) { aborted = true; bytes.clear(); changed.notifyAll() }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }

    private func checkContext(context: tls.OperationContext): Unit {
        if (context.isCancellationRequested()) {
            throw IllegalStateException("example transport cancelled")
        }
        if (context.isDeadlineExceeded()) {
            throw IllegalStateException("example transport deadline exceeded")
        }
    }
}
