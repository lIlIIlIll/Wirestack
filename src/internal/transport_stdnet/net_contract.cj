package wirestack.internal.transport_stdnet

import wirestack as api

/*
 * Initial wirestack.net bridge. It delegates TCP to the already-established
 * provider-neutral Transport SPI; listener/datagram ownership arrives in
 * M8-002 and does not appear here as an unsupported placeholder.
 */
public class ContractStreamBackend <: api.DuplexTransport {
    private let delegate: api.DuplexTransport

    private init(delegate: api.DuplexTransport) {
        this.delegate = delegate
    }

    public static func connectTcp(
        endpoint: api.SocketEndpoint,
        context: api.OperationContext,
        stagingBufferSize!: Int64 = 16 * 1024
    ): ContractStreamBackend {
        ContractStreamBackend(StdNetTransportFactory(
            stagingBufferSize: stagingBufferSize
        ).connect(endpoint, context))
    }

    public prop info: api.TransportInfo { get() { delegate.info } }

    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        delegate.readSome(destination, context: context)
    }

    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        delegate.writeSome(source, context: context)
    }

    public func shutdown(direction: api.ShutdownDirection): Unit {
        delegate.shutdown(direction)
    }

    public func close(context: api.OperationContext): Unit {
        delegate.close(context)
    }

    public func close(): Unit {
        delegate.close(api.OperationContext.background())
    }

    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        delegate.abort(reason: reason)
    }

    public func isClosed(): Bool {
        delegate.isClosed()
    }
}
