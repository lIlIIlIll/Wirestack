package wirestack.gzip

import std.sync.Mutex
import wirestack.*

/** Pull-owned RFC1952 body. Output is provisional until integrityVerified becomes true at verified EOF. */
public class GzipBodyStream <: HttpBodyStream {
    private let source: HttpBodyStream
    private let context: OperationContext
    private let extraCheck: () -> Unit
    private let mutex = Mutex()
    private var decoder: ?GzipPullDecoder = None<GzipPullDecoder>
    private var registration = None<CancellationRegistration>
    private var parentRegistration = None<CancellationRegistration>
    private var lease: ?Resource = None<Resource>
    private var active = false
    private var closed = false
    private var finished = false
    private var released = false
    private var encoded: Int64 = 0
    private var decoded: Int64 = 0
    private var members: Int64 = 0
    private var maximumWork: Int64 = 0

    /** Takes ownership of a compressed stream without making it replayable.
     * @param source Compressed input stream, closed on EOF/failure/local close.
     * @param limits Absolute input/output and fixed-work bounds.
     * @param context Original absolute deadline and cancellation, also checked during CPU work.
     */
    public init(source: HttpBodyStream, limits!: GzipLimits = GzipLimits(),
        context!: OperationContext = OperationContext.background()) {
        this.source = source; this.context = context; this.extraCheck = { => () }
        initialize(limits, None<CancellationToken>)
    }

    internal init(source: HttpBodyStream, limits: GzipLimits, context: OperationContext,
        parent: OperationContext, extraCheck: () -> Unit, lease: Resource) {
        this.source = source; this.context = context; this.extraCheck = extraCheck
        this.lease = Some(lease)
        initialize(limits, Some(parent.cancellation))
    }

    private func initialize(limits: GzipLimits, parent: ?CancellationToken): Unit {
        try {
            checkActive()
            decoder = Some(GzipPullDecoder(source, limits, { => checkActive() }))
            let first = context.cancellation.register({ => close() })
            attach(first)
            if (let Some(token) <- parent) { attach(token.register({ => close() }), parent: true) }
            checkActive()
        } catch (error: Exception) { close(); throw error }
    }
    private func attach(value: CancellationRegistration, parent!: Bool = false): Unit {
        let keep = synchronized(mutex) {
            if (released || closed) { false } else {
                if (parent) { parentRegistration = Some(value) } else { registration = Some(value) }; true
            }
        }
        if (!keep) { value.unregister() }
    }
    private func checkActive(): Unit {
        checkGzipContext(context)
        extraCheck()
        if (synchronized(mutex) { closed }) { throw GzipException(GzipErrorCode.Closed, "gzip body closed") }
    }
    /** Decoded length is unknown until EOF and never equals the wire Content-Length by assumption. */
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    /** Actual compressed bytes read, including bounded read-ahead. */
    public prop encodedBytesRead: Int64 { get() { synchronized(mutex) { encoded } } }
    /** Actual produced decoded bytes, including provisional output before a later integrity failure. */
    public prop decodedBytes: Int64 { get() { synchronized(mutex) { decoded } } }
    /** Members whose headers have been accepted. */
    public prop memberCount: Int64 { get() { synchronized(mutex) { members } } }
    /** True only after all trailers and the physical end of the compressed body are verified. */
    public prop integrityVerified: Bool { get() { synchronized(mutex) { finished } } }
    /** Observed maximum codec work steps between context checks, bounded by 512. */
    public prop maximumWorkBetweenChecks: Int64 { get() { synchronized(mutex) { maximumWork } } }

    /** Reads bounded output; zero with a nonempty destination means verified physical EOF.
     * @param destination Caller-owned output buffer, never retained or expanded by the decoder.
     * @return Decoded bytes written, at most the configured maximumReadBytes.
     */
    public func read(destination: Array<Byte>): Int64 {
        checkActive()
        synchronized(mutex) {
            if (active) { throw GzipException(GzipErrorCode.ConcurrentOperation, "gzip reader already active") }
            if (finished || destination.isEmpty()) { return 0 }
            active = true
        }
        let codec = decoder.getOrThrow()
        try {
            let count = codec.read(destination)
            checkActive()
            if (count == 0) { synchronized(mutex) { finished = codec.validatedEof } }
            count
        } catch (error: Exception) {
            var contextual = None<Exception>
            try { checkGzipContext(context); extraCheck() }
            catch (failure: Exception) { contextual = Some(failure) }
            let locallyClosed = synchronized(mutex) { closed }
            close()
            if (let Some(failure) <- contextual) {
                match (failure) {
                    case value: NetworkException =>
                        throw NetworkException(value.category, value.phase, value.code, value.message,
                            retryability: value.retryability, nativeCode: value.nativeCode,
                            localEndpoint: value.localEndpoint, remoteEndpoint: value.remoteEndpoint, cause: Some(error))
                    case _ => throw failure
                }
            }
            if (locallyClosed) {
                throw GzipException(GzipErrorCode.Closed, "gzip body closed during read", cause: Some(error))
            }
            throw error
        } finally {
            synchronized(mutex) {
                encoded = codec.encodedBytesRead; decoded = codec.decodedBytes
                members = codec.memberCount; maximumWork = codec.maximumWorkBetweenChecks
                active = false
            }
            releaseIfTerminal()
        }
    }
    /** Idempotently interrupts only the owned source; does not close a shared client or sibling streams. */
    public func close(): Unit {
        let first = synchronized(mutex) { if (closed) { false } else { closed = true; true } }
        if (first) { try { source.close() } finally { releaseIfTerminal() } }
    }
    /** Reports local close or verified EOF with all owned resources released. */
    public func isClosed(): Bool { synchronized(mutex) { closed || finished } }
    private func releaseIfTerminal(): Unit {
        let claim = synchronized(mutex) {
            if (released || active || !(closed || finished)) { false } else { released = true; true }
        }
        if (!claim) { return }
        try { source.close() }
        finally {
            if (let Some(value) <- registration) { registration = None<CancellationRegistration>; value.unregister() }
            if (let Some(value) <- parentRegistration) { parentRegistration = None<CancellationRegistration>; value.unregister() }
            if (let Some(value) <- decoder) { value.release(); decoder = None<GzipPullDecoder> }
            if (let Some(value) <- lease) { lease = None<Resource>; value.close() }
        }
    }
}
