package wirestack.gzip

import std.collection.ArrayList
import std.sync.Mutex
import wirestack.*

/** Pull-owned RFC1952 body. Output is provisional until integrityVerified becomes true at verified EOF. */
public class GzipBodyStream <: HttpBodyStream {
    private let source: HttpBodyStream
    private let context: OperationContext
    private let mutex = Mutex()
    private var decoder: ?GzipPullDecoder = None<GzipPullDecoder>
    private var registration = None<CancellationRegistration>
    private var retainedRegistrations = ArrayList<CancellationRegistration>()
    private var lease: ?Resource = None<Resource>
    private var cancellation: ?Resource = None<Resource>
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
        this.source = source; this.context = context
        initialize(limits)
    }

    internal init(source: HttpBodyStream, limits: GzipLimits, context: OperationContext, lease: Resource) {
        this.source = source; this.context = context
        this.lease = Some(lease)
        initialize(limits)
    }

    private func initialize(limits: GzipLimits): Unit {
        try {
            checkActive()
            decoder = Some(GzipPullDecoder(source, limits, { => checkActive() }))
            attach(context.cancellation.register({ => close() }))
            checkActive()
        } catch (error: Exception) {
            try { close() } catch (_: Exception) { /* Preserve the initialization failure. */ }
            throw error
        }
    }
    private func attach(value: CancellationRegistration): Unit {
        let keep = synchronized(mutex) {
            if (released || closed) { false } else { registration = Some(value); true }
        }
        if (!keep) { value.unregister() }
    }
    private func checkActive(): Unit {
        checkGzipContext(context)
        if (synchronized(mutex) { closed }) { throw GzipException(GzipErrorCode.Closed, "gzip body closed") }
    }
    /** Retains the typed-handle cancellation lifetime until this decoded body ends. */
    internal func attachCancellation(lifetime: Resource): Unit {
        let keep = synchronized(mutex) {
            if (released || closed) { false } else { cancellation = Some(lifetime); true }
        }
        if (!keep) { lifetime.close() }
    }
    /** Retains an external cancellation link until this decoded body ends, so a parent or
     * typed-handle cancellation stays observable through the published response context
     * even after the compressed wire body has been fully drained.
     */
    internal func attachRegistration(value: CancellationRegistration): Unit {
        let keep = synchronized(mutex) {
            if (released || closed) { false } else { retainedRegistrations.add(value); true }
        }
        if (!keep) { value.unregister() }
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
     * Terminal states precede context polling so a later deadline never rewrites EOF, and an
     * empty destination returns zero without failing or closing the owned source.
     * Owned read failures release resources without replacing the read error with a close error.
     * @param destination Caller-owned output buffer, never retained or expanded by the decoder.
     * @return Decoded bytes written, at most the configured maximumReadBytes.
     */
    public func read(destination: Array<Byte>): Int64 {
        if (destination.isEmpty()) { return 0 }
        var terminal = false
        let codec = synchronized(mutex) {
            if (active) { throw GzipException(GzipErrorCode.ConcurrentOperation, "gzip reader already active") }
            if (finished) {
                terminal = true
                None<GzipPullDecoder>
            } else {
                active = true
                decoder
            }
        }
        if (terminal) { return 0 }
        var failed = false
        try {
            checkActive()
            let value = codec.getOrThrow()
            let count = value.read(destination)
            if (count == 0) {
                // Verified EOF is terminal: do not let a later context state turn it into an error.
                let verified = value.validatedEof
                if (verified) { synchronized(mutex) { finished = true }; return 0 }
            }
            checkActive()
            count
        } catch (error: Exception) {
            failed = true
            var contextual = None<Exception>
            try { checkGzipContext(context) }
            catch (failure: Exception) { contextual = Some(failure) }
            let locallyClosed = synchronized(mutex) { closed }
            try { close() } catch (_: Exception) { /* Preserve the read failure. */ }
            if (let Some(failure) <- contextual) {
                match (failure) {
                    case value: NetworkException => throw gzipContextualFailure(value, error)
                    case _ => throw failure
                }
            }
            if (locallyClosed) {
                throw GzipException(GzipErrorCode.Closed, "gzip body closed during read", cause: Some(error))
            }
            throw error
        } finally {
            synchronized(mutex) {
                if (let Some(value) <- codec) {
                    encoded = value.encodedBytesRead; decoded = value.decodedBytes
                    members = value.memberCount; maximumWork = value.maximumWorkBetweenChecks
                }
                active = false
            }
            if (failed) {
                try { releaseIfTerminal() } catch (_: Exception) { /* Cleanup must not replace the read failure. */ }
            } else { releaseIfTerminal() }
        }
    }
    /** Idempotently interrupts only the owned source; does not close a shared client or sibling streams.
     * Source close errors may propagate, but owned resources are still released. */
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
            let retained = synchronized(mutex) {
                let current = retainedRegistrations
                retainedRegistrations = ArrayList<CancellationRegistration>()
                current
            }
            for (value in retained) { value.unregister() }
            if (let Some(value) <- decoder) { value.release(); decoder = None<GzipPullDecoder> }
            if (let Some(value) <- lease) { lease = None<Resource>; value.close() }
            if (let Some(value) <- cancellation) { cancellation = None<Resource>; value.close() }
        }
    }
}

/** Rebuilds a contextual cancellation/deadline failure around a racing transport error.
 * The contextual category, phase and code win because the operation really was cancelled or
 * expired; the original transport error stays as the cause, and its native code and endpoints
 * are carried over so transport diagnostics are not lost during contextualization.
 */
private func gzipContextualFailure(failure: NetworkException, transport: Exception): NetworkException {
    var nativeCode = failure.nativeCode
    var localEndpoint = failure.localEndpoint
    var remoteEndpoint = failure.remoteEndpoint
    match (transport) {
        case original: NetworkException =>
            match (original.nativeCode) { case Some(value) => nativeCode = Some(value); case None => () }
            match (original.localEndpoint) { case Some(value) => localEndpoint = Some(value); case None => () }
            match (original.remoteEndpoint) { case Some(value) => remoteEndpoint = Some(value); case None => () }
        case _ => ()
    }
    NetworkException(failure.category, failure.phase, failure.code, failure.message,
        retryability: failure.retryability, nativeCode: nativeCode,
        localEndpoint: localEndpoint, remoteEndpoint: remoteEndpoint, cause: Some(transport))
}
