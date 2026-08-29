package wirestack.internal.transport

import wirestack as api

public type ReadResult = api.ReadResult
public type ShutdownDirection = api.ShutdownDirection
public type AbortReason = api.AbortReason
public type TransportInfo = api.TransportInfo
public type DuplexTransport = api.DuplexTransport
public type TransportListener = api.TransportListener
public type TransportFactory = api.TransportFactory

public enum TransportState {
    | Created
    | Connecting
    | Accepted
    | Open
    | ReadHalfClosed
    | WriteHalfClosed
    | Closing
    | Closed
    | Aborted
    | Failed
}

public func writeAll(
    transport: DuplexTransport,
    source: ByteSpan,
    context!: OperationContext = OperationContext.background()
): Unit {
    api.writeAll(transport, source, context: context)
}

public func readExact(
    transport: DuplexTransport,
    destination: MutableByteSpan,
    context!: OperationContext = OperationContext.background()
): Unit {
    api.readExact(transport, destination, context: context)
}
