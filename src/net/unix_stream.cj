package wirestack.net

import wirestack as api
import wirestack.internal.transport_stdnet as stdnet

/**
 * A connected Unix-domain byte stream backed by the qualified std.net stream
 * lifecycle. One read and one write may proceed concurrently; overlapping
 * operations in the same direction fail. Cancellation of active I/O is
 * terminal because the public SDK exposes socket close as its wake mechanism.
 * Directional half-close is unavailable.
 */
public class UnixStream <: StreamSocket & api.DuplexTransport {
    private let delegate: TcpStream

    internal init(transport: stdnet.SocketTransport) {
        this.delegate = TcpStream(transport, nonBlocking: true,
            closeOnExec: true, streamLabel: "Unix")
    }

    /**
     * Connects to a named Unix endpoint without DNS.
     *
     * Unnamed destinations are rejected. Pathnames remain caller-owned and are
     * never unlinked by Wirestack. This std.net backend supports abstract names
     * only when they contain exactly 107 valid UTF-8 bytes, including embedded
     * NUL. Other names fail with Unsupported rather than gaining padding bytes.
     *
     * @param endpoint Pathname or Linux abstract destination.
     * @param context Absolute deadline and cancellation token for the connect.
     */
    public static func connect(
        endpoint: api.UnixEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): UnixStream {
        let remote = Some(api.NetworkEndpoint.Unix(endpoint))
        try {
            UnixStream(stdnet.StdNetTransport.connectUnix(endpoint, context: context))
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.Connect,
                api.NetworkPhase.UnixSocket, None<api.NetworkEndpoint>, remote)
        }
    }

    /** Current retained stream lifecycle state. */
    public prop state: SocketState { get() { delegate.state } }

    /** Advisory capabilities; `halfClose` is false for this backend. */
    public prop capabilities: SocketCapabilities { get() { delegate.capabilities } }

    /** Immutable local Unix endpoint; automatically bound clients are unnamed. */
    public prop localEndpoint: ?api.NetworkEndpoint { get() { delegate.localEndpoint } }

    /** Immutable connected Unix peer endpoint. */
    public prop remoteEndpoint: ?api.NetworkEndpoint { get() { delegate.remoteEndpoint } }

    /**
     * Reads one partial chunk.
     * @param destination Destination byte span.
     * @param context Shared absolute operation context.
     */
    public func read(
        destination: api.MutableByteSpan,
        context!: api.OperationContext
    ): ReadResult {
        delegate.read(destination, context: context)
    }

    /**
     * Reads one provider-neutral transport chunk.
     * @param destination Destination byte span.
     * @param context Shared absolute operation context.
     */
    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        delegate.readSome(destination, context: context)
    }

    /**
     * Writes one partial chunk.
     * @param source Source byte span.
     * @param context Shared absolute operation context.
     */
    public func write(
        source: api.ByteSpan,
        context!: api.OperationContext
    ): Int64 {
        delegate.write(source, context: context)
    }

    /**
     * Writes one provider-neutral transport chunk.
     * @param source Source byte span.
     * @param context Shared absolute operation context.
     */
    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        delegate.writeSome(source, context: context)
    }

    /**
     * Fills the destination or reports EOF/failure with both Unix endpoints.
     * @param destination Destination byte span.
     * @param context Shared absolute operation context.
     */
    public func readExact(
        destination: api.MutableByteSpan,
        context!: api.OperationContext
    ): Unit {
        delegate.readExact(destination, context: context)
    }

    /**
     * Writes the complete source under one absolute context.
     * @param source Source byte span.
     * @param context Shared absolute operation context.
     */
    public func writeAll(
        source: api.ByteSpan,
        context!: api.OperationContext
    ): Unit {
        delegate.writeAll(source, context: context)
    }

    /**
     * Reports `Unsupported`; the pinned public std.net API has no half-close.
     * @param direction Direction requested by the caller.
     */
    public func shutdown(direction: api.ShutdownDirection): Unit {
        delegate.shutdown(direction)
    }

    /**
     * Gracefully closes once; a bounded caller may stop waiting without taking
     * close ownership away from the admitted cleanup.
     * @param context Context for waiting for close completion.
     */
    public func close(context!: api.OperationContext): Unit {
        delegate.close(context: context)
    }

    /** Closes with a background context for `Resource` callers. */
    public func close(): Unit { delegate.close() }

    /**
     * Terminates both directions idempotently.
     * @param reason Optional stable local abort reason.
     */
    public func abort(
        reason!: ?api.AbortReason = None<api.AbortReason>
    ): Unit {
        delegate.abort(reason: reason)
    }

    /** Reports whether the underlying stream is terminal. */
    public func isClosed(): Bool { delegate.isClosed() }

    /** Provider-neutral diagnostics; Unix endpoints are exposed by the stream properties. */
    public prop info: api.TransportInfo { get() { delegate.info } }
}
