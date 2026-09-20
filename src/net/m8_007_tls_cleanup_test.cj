package wirestack.net

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.transport.*
import wirestack.internal.tls_engine.*

@Test
class M8007TlsDeadlineCleanupTest {
    @TestCase
    func closeDeadlineReleasesAnExistingNativeTcpReadWithoutPeerAssistance(): Unit {
        let listener = TcpListener.bind(api.SocketEndpoint(
            api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16
        ))
        let accepting = spawn { listener.accept() }
        let client = TcpStream.connect(listener.localEndpoint)
        let peer = accepting.get(Duration.second)
        let entered = SyncCounter(1)
        let engine = DeadlineProbeEngine()
        let connection = TlsConnection.handshake(engine, NativeDeadlineTransport(client, entered))
        let reading: Future<Bool> = spawn {
            try {
                let _ = connection.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
                false
            } catch (_: NetworkException) {
                true
            }
        }
        try {
            entered.waitUntilZero()
            var timedOut = false
            try {
                connection.close(OperationContext(
                    deadline: Some(Deadline.after(20 * Duration.millisecond))
                ))
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.TimedOut => timedOut = true
                    case _ => ()
                }
            }
            var readStopped = false
            try { readStopped = reading.get(Duration.second) }
            catch (_: TimeoutException) {}
            @Expect(timedOut)
            @Expect(readStopped)
            @Expect(client.isClosed())
            @Expect(engine.closeCalls.load(), 1)
        } finally {
            client.abort()
            peer.abort()
            listener.close()
            let _ = reading.get(Duration.second)
        }
    }
}

private class NativeDeadlineTransport <: DuplexTransport {
    private let delegate: TcpStream
    private let entered: SyncCounter
    init(delegate: TcpStream, entered: SyncCounter) {
        this.delegate = delegate
        this.entered = entered
    }
    public prop info: TransportInfo { get() { delegate.info } }
    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): api.ReadResult {
        entered.dec()
        delegate.readSome(destination, context: context)
    }
    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 { delegate.writeSome(source, context: context) }
    public func shutdown(direction: ShutdownDirection): Unit { delegate.shutdown(direction) }
    public func close(context: OperationContext): Unit { delegate.close(context: context) }
    public func close(): Unit { delegate.close() }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit { delegate.abort(reason: reason) }
    public func isClosed(): Bool { delegate.isClosed() }
}

private class DeadlineProbeEngine <: TlsEngine {
    let closeCalls = AtomicInt64(0)
    public func handshakeStep(): TlsEngineStep { TlsEngineStep.Complete }
    public func pendingCiphertext(): Int64 { 0 }
    public func drainCiphertext(_: MutableByteSpan): Int64 { 0 }
    public func feedCiphertext(source: ByteSpan): Int64 { source.length }
    public func readPlaintext(_: MutableByteSpan): TlsEngineReadResult { TlsEngineReadResult.WantRead }
    public func writePlaintext(source: ByteSpan): TlsEngineWriteResult { TlsEngineWriteResult.Consumed(source.length) }
    public func shutdownStep(): TlsEngineShutdownResult { TlsEngineShutdownResult.WantRead }
    public func close(): Unit { closeCalls.fetchAdd(1); () }
    public func isClosed(): Bool { closeCalls.load() > 0 }
}
