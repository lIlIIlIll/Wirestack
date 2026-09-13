package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

/** Connection-scoped admission and routing for bounded peer-promised streams. */
internal class Http2ClientPushCoordinator {
    private let config: Http2PushConfig
    private let machine: Http2ConnectionStateMachine
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let reset: Http2StreamResetManager
    private let terminations: Http2ReaderTerminationRegistry
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let mutex = Mutex()
    private let exchanges = ArrayList<Http2ClientPushedExchange>()

    internal prop ownerCount: Int64 { get() { synchronized(mutex) { exchanges.size } } }

    init(
        config: Http2PushConfig,
        machine: Http2ConnectionStateMachine,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        reset: Http2StreamResetManager,
        terminations: Http2ReaderTerminationRegistry,
        limits: HttpLimits,
        http2Limits: Http2Limits
    ) {
        this.config = config
        this.machine = machine
        this.registry = registry
        this.flow = flow
        this.writer = writer
        this.reset = reset
        this.terminations = terminations
        this.limits = limits
        this.http2Limits = http2Limits
    }

    func newSource(parentStreamId: Http2StreamId, parent: HttpUrl): Http2ClientPushSource {
        Http2ClientPushSource(config, parentStreamId, parent)
    }

    /** Called only after the connection decoder has consumed the complete HPACK block. */
    func accept(
        source: Http2ClientPushSource,
        block: Http2HeaderBlock,
        fields: Array<HpackHeaderField>
    ): Unit {
        if (!machine.localSettings.enablePush) {
            throw Http2ProtocolException(
                Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                "HTTP/2 server sent PUSH_PROMISE after push was disabled"
            )
        }
        let promisedId = match (block.promisedStreamId) {
            case Some(value) => value
            case None => throw Http2ProtocolException(
                Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                "HTTP/2 PUSH_PROMISE omitted its promised stream id"
            )
        }
        if (block.streamId.value != source.parentStreamId.value ||
            registry.stream(block.streamId).isNone()) {
            throw Http2ProtocolException(
                Http2ErrorCode.StreamClosed, Http2ErrorScope.Stream(block.streamId),
                "HTTP/2 PUSH_PROMISE referenced an inactive parent stream"
            )
        }
        let stream = machine.reservePeerStream(registry, promisedId)
        var flowOpened = false
        var exchange: ?Http2ClientPushedExchange = None<Http2ClientPushedExchange>
        try {
            flow.openStream(stream.id)
            flowOpened = true
            let request = decodeHttp2PushedRequest(
                fields, stream.id, source.parent,
                limits: limits, http2Limits: http2Limits
            )
            let admitted = synchronized(mutex) {
                if (exchanges.size >= config.maximumConcurrentPushes) {
                    false
                } else {
                    let value = Http2ClientPushedExchange(
                        stream.id, request, source, registry, flow, writer, reset,
                        limits, http2Limits, { id => remove(id) }
                    )
                    exchanges.add(value)
                    exchange = Some(value)
                    true
                }
            }
            if (!admitted) {
                refuseReserved(stream.id, "HTTP/2 concurrent push limit reached")
                return
            }
            let value = exchange.getOrThrow()
            value.bindReader(terminations.register(value))
            value.bindReset(reset.register(stream.id, value))
            if (!source.admit(value)) {
                value.reject(
                    Http2ErrorCode.RefusedStream,
                    "HTTP/2 parent push queue or per-request limit reached"
                )
            }
        } catch (error: Http2ProtocolException) {
            cleanupFailedAdmission(
                stream.id, flowOpened, exchange, error.code,
                "HTTP/2 promised stream admission failed"
            )
            throw error
        } catch (error: Exception) {
            cleanupFailedAdmission(
                stream.id, flowOpened, exchange, Http2ErrorCode.InternalError,
                "HTTP/2 promised stream admission failed"
            )
            throw error
        }
    }

    func exchange(streamId: Http2StreamId): ?Http2ClientPushedExchange {
        synchronized(mutex) {
            for (value in exchanges) {
                if (value.streamId.value == streamId.value) { return Some(value) }
            }
            None<Http2ClientPushedExchange>
        }
    }

    func connectionTerminated(completion: Http2ConnectionCompletion): Unit {
        let current = synchronized(mutex) { exchanges.toArray() }
        for (value in current) { value.readerTerminated(completion) }
    }

    private func refuseReserved(streamId: Http2StreamId, reason: String): Unit {
        try {
            let _ = reset.cancelLocal(
                streamId, code: Http2ErrorCode.RefusedStream, reason: reason
            )
        } catch (_: Exception) {
            let _ = flow.closeStream(streamId)
        }
    }

    private func cleanupFailedAdmission(
        streamId: Http2StreamId,
        flowOpened: Bool,
        exchange: ?Http2ClientPushedExchange,
        code: Http2ErrorCode,
        reason: String
    ): Unit {
        match (exchange) {
            case Some(value) => value.reject(code, reason)
            case None =>
                try {
                    let _ = reset.cancelLocal(streamId, code: code, reason: reason)
                } catch (_: Exception) {
                    try { let _ = registry.reset(streamId, code, reason) }
                    catch (_: Exception) {}
                    if (flowOpened) { let _ = flow.closeStream(streamId) }
                }
        }
    }

    private func remove(streamId: Http2StreamId): Unit {
        synchronized(mutex) {
            for (index in 0..exchanges.size) {
                if (exchanges[index].streamId.value == streamId.value) {
                    let _ = exchanges.remove(at: index)
                    return
                }
            }
        }
    }
}

/** One parent-associated, caller-driven queue. Policy never runs on the reader task. */
internal class Http2ClientPushSource <: HttpPushSource {
    private let policy: Http2PushPolicy
    private let maximumPending: Int64
    private let maximumPerRequest: Int64
    internal let parentStreamId: Http2StreamId
    internal let parent: HttpUrl
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let offers = ArrayList<Http2ClientPushedExchange>()
    private var admittedTotal: Int64 = 0
    private var receiveActive = false
    private var finished = false
    private var closed = false

    init(
        config: Http2PushConfig,
        parentStreamId: Http2StreamId,
        parent: HttpUrl
    ) {
        policy = config.policy
        maximumPending = config.maximumPendingPushes
        maximumPerRequest = config.maximumPushesPerRequest
        this.parentStreamId = parentStreamId
        this.parent = parent
    }

    func admit(exchange: Http2ClientPushedExchange): Bool {
        synchronized(mutex) {
            if (closed || finished || exchange.isTerminal ||
                admittedTotal >= maximumPerRequest || offers.size >= maximumPending) {
                return false
            }
            admittedTotal++
            offers.add(exchange)
            changed.notifyAll()
            true
        }
    }

    func parentFinished(): Unit {
        synchronized(mutex) {
            finished = true
            changed.notifyAll()
        }
    }

    func failed(exchange: Http2ClientPushedExchange): Unit {
        synchronized(mutex) {
            removeOfferLocked(exchange)
            changed.notifyAll()
        }
    }

    public func receive(
        context!: OperationContext = OperationContext.background()
    ): ?HttpPushedResponse {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP/2 push source is closed") }
            if (receiveActive) {
                throw IllegalStateException("HTTP/2 push source already has an active receiver")
            }
            receiveActive = true
        }
        let registration = context.cancellation.register { => wake() }
        try {
            while (true) {
                let selected = synchronized(mutex) {
                    while (offers.isEmpty() && !finished && !closed) {
                        checkPushContext(context)
                        match (context.deadline) {
                            case Some(deadline) => changed.wait(timeout: deadline.remaining())
                            case None => changed.wait()
                        }
                    }
                    checkPushContext(context)
                    if (closed) { throw IllegalStateException("HTTP/2 push source is closed") }
                    if (offers.isEmpty()) { return None<HttpPushedResponse> }
                    offers[0]
                }
                let allowed = try {
                    policy.allow(parent, selected.request.url, context)
                } catch (error: Exception) {
                    synchronized(mutex) { removeOfferLocked(selected); changed.notifyAll() }
                    selected.reject(Http2ErrorCode.Cancel, "HTTP/2 push policy failed")
                    throw error
                }
                if (!allowed) {
                    synchronized(mutex) { removeOfferLocked(selected); changed.notifyAll() }
                    selected.reject(Http2ErrorCode.Cancel, "HTTP/2 push policy rejected the promise")
                    continue
                }
                let response = try {
                    selected.awaitResponse(context)
                } catch (error: Exception) {
                    if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                        throw error
                    }
                    synchronized(mutex) { removeOfferLocked(selected); changed.notifyAll() }
                    continue
                }
                if (!claimAfterAwait(selected, response)) { continue }
                return Some(HttpPushedResponse(selected.request, response))
            }
            None<HttpPushedResponse>
        } finally {
            registration.unregister()
            synchronized(mutex) { receiveActive = false; changed.notifyAll() }
        }
    }

    /**
     * Atomically removes one still-owned offer and claims its response.
     * Resource cleanup remains outside both source and exchange locks.
     */
    func claimAfterAwait(
        exchange: Http2ClientPushedExchange,
        response: HttpResponse
    ): Bool {
        let outcome = synchronized(mutex) {
            if (closed) {
                (false, true)
            } else if (!removeOfferLocked(exchange)) {
                (false, false)
            } else {
                (exchange.tryTransfer(), false)
            }
        }
        if (!outcome[0]) {
            try { response.close() } catch (_: Exception) {}
            if (outcome[1]) {
                throw IllegalStateException("HTTP/2 push source closed before ownership transfer")
            }
        }
        outcome[0]
    }

    public func close(): Unit {
        let claimed = synchronized(mutex) {
            if (closed) { return }
            closed = true
            finished = true
            let current = offers.toArray()
            offers.clear()
            changed.notifyAll()
            current
        }
        for (value in claimed) {
            value.reject(Http2ErrorCode.Cancel, "HTTP/2 parent response closed its unclaimed push")
        }
    }

    public func isClosed(): Bool {
        synchronized(mutex) { closed || (finished && offers.isEmpty() && !receiveActive) }
    }

    private func removeOfferLocked(target: Http2ClientPushedExchange): Bool {
        for (index in 0..offers.size) {
            if (offers[index].streamId.value == target.streamId.value) {
                let _ = offers.remove(at: index)
                return true
            }
        }
        false
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

/** One promised response owner retained until transfer, reset, or parent cleanup. */
internal class Http2ClientPushedExchange <: ResponseBodyObserver &
    Http2StreamResetListener & Http2ReaderTerminationListener {
    internal let streamId: Http2StreamId
    internal let request: HttpRequest
    private let source: Http2ClientPushSource
    private let sequence: Http2ClientResponseSequence
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let reset: Http2StreamResetManager
    private let channel: Http2ClientBodyChannel
    private let onTerminated: (Http2StreamId) -> Unit
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var response: ?HttpResponse = None<HttpResponse>
    private var failure: ?Exception = None<Exception>
    private var resetRegistration: ?Http2StreamResetRegistration = None<Http2StreamResetRegistration>
    private var readerRegistration: ?Http2ReaderTerminationRegistration = None<Http2ReaderTerminationRegistration>
    private var opened = false
    private var transferred = false
    private var terminal = false

    internal prop isTerminal: Bool { get() { synchronized(mutex) { terminal } } }

    init(
        streamId: Http2StreamId,
        request: HttpRequest,
        source: Http2ClientPushSource,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        reset: Http2StreamResetManager,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        onTerminated: (Http2StreamId) -> Unit
    ) {
        this.streamId = streamId
        this.request = request
        this.source = source
        this.registry = registry
        this.flow = flow
        this.writer = writer
        this.reset = reset
        this.onTerminated = onTerminated
        sequence = Http2ClientResponseSequence(
            streamId, request.method, limits: limits, http2Limits: http2Limits
        )
        channel = Http2ClientBodyChannel(
            streamId, flow, writer, OperationContext.background(), http2Limits
        )
    }

    func bindReset(value: Http2StreamResetRegistration): Unit {
        let discard = synchronized(mutex) {
            if (terminal) { true } else { resetRegistration = Some(value); false }
        }
        if (discard) { value.unregister() }
    }

    func bindReader(value: Http2ReaderTerminationRegistration): Unit {
        let discard = synchronized(mutex) {
            if (terminal) { true } else { readerRegistration = Some(value); false }
        }
        if (discard) { value.unregister() }
    }

    func acceptHeaders(fields: Array<HpackHeaderField>, endStream: Bool): Unit {
        let event = sequence.acceptHeaders(fields, endStream)
        let first = synchronized(mutex) {
            if (opened) { false } else { opened = true; true }
        }
        if (first) {
            registry.openReservedPeer(streamId, endStream: endStream)
        }
        match (event.kind) {
            case Http2ClientHeaderEventKind.Informational => ()
            case Http2ClientHeaderEventKind.Final =>
                let head = event.head.getOrThrow()
                channel.setExpectedLength(head.expectedContentLength)
                let body = ResponseBody(
                    channel,
                    observer: this,
                    trailerProvider: { => channel.trailer },
                    completeAtDeclaredLength: false
                )
                synchronized(mutex) {
                    if (response.isSome()) {
                        throw IllegalStateException("HTTP/2 pushed response was already published")
                    }
                    response = Some(head.toResponse(body))
                    changed.notifyAll()
                }
                if (endStream) {
                    if (!first) { registry.peerEnd(streamId) }
                    channel.finish(None<HttpTrailer>)
                }
            case Http2ClientHeaderEventKind.Trailer =>
                if (first) {
                    throw Http2ProtocolException(
                        Http2ErrorCode.ProtocolError, Http2ErrorScope.Stream(streamId),
                        "HTTP/2 promised stream cannot begin with trailers"
                    )
                }
                registry.peerEnd(streamId)
                channel.finish(event.trailer)
        }
    }

    func acceptData(frame: Http2Frame): Unit {
        let decoded = decodePushedData(frame, streamId)
        sequence.acceptData(decoded.data.size, frame.header.flags.isEndStream())
        channel.offer(decoded.data, Int64(frame.header.length), false)
        if (frame.header.flags.isEndStream()) {
            registry.peerEnd(streamId)
            channel.finish(None<HttpTrailer>)
        }
    }

    func awaitResponse(context: OperationContext): HttpResponse {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (response.isNone() && failure.isNone()) {
                    checkPushContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                checkPushContext(context)
                if (let Some(error) <- failure) { throw error }
                response.getOrThrow()
            }
        } finally { registration.unregister() }
    }

    /** Claims caller ownership unless reset or teardown already made the exchange terminal. */
    func tryTransfer(): Bool {
        synchronized(mutex) {
            if (terminal || transferred || response.isNone()) { return false }
            transferred = true
            true
        }
    }

    func reject(code: Http2ErrorCode, reason: String): Unit {
        signalFailure(Http2ProtocolException(code, Http2ErrorScope.Stream(streamId), reason))
        try { channel.close() } catch (_: Exception) {}
        try { let _ = reset.cancelLocal(streamId, code: code, reason: reason) }
        catch (_: Exception) {}
        finish()
    }

    public func streamReset(event: Http2StreamResetEvent): Unit {
        if (event.streamId.value != streamId.value) { return }
        signalFailure(Http2ProtocolException(
            event.code, Http2ErrorScope.Stream(event.streamId), event.reason
        ))
        finish()
    }

    public func readerTerminated(completion: Http2ConnectionCompletion): Unit {
        signalFailure(Http2ProtocolException(
            completion.code, Http2ErrorScope.Connection, completion.reason
        ))
        finish()
    }

    public func completed(): Unit { finish() }

    public func abandoned(): Unit {
        try { let _ = reset.cancelLocal(streamId) } catch (_: Exception) {}
        finish()
    }

    private func signalFailure(error: Exception): Unit {
        synchronized(mutex) {
            if (failure.isNone()) { failure = Some(error) }
            changed.notifyAll()
        }
        channel.fail(error)
    }

    private func finish(): Unit {
        let disposition = synchronized(mutex) {
            if (terminal) { return }
            terminal = true
            (resetRegistration, readerRegistration, transferred)
        }
        try { channel.close() } catch (_: Exception) {}
        if (let Some(value) <- disposition[0]) { value.unregister() }
        if (let Some(value) <- disposition[1]) { value.unregister() }
        let updates = flow.closeStream(streamId)
        for (frame in updates) {
            try { let _ = writer.enqueue(frame) } catch (_: Exception) {}
        }
        onTerminated(streamId)
        if (!disposition[2]) { source.failed(this) }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private struct Http2DecodedPushedData {
    let data: Array<Byte>
    init(data: Array<Byte>) { this.data = data }
}

private func decodePushedData(
    frame: Http2Frame,
    streamId: Http2StreamId
): Http2DecodedPushedData {
    if (frame.header.streamId.value != streamId.value) {
        throw IllegalArgumentException("HTTP/2 DATA belongs to another promised stream")
    }
    let payload = frame.payload
    if (!frame.header.flags.isPadded()) { return Http2DecodedPushedData(payload) }
    if (payload.isEmpty()) { pushedStreamError(streamId, "HTTP/2 padded DATA has no pad length") }
    let padding = Int64(payload[0])
    if (padding >= payload.size) {
        pushedStreamError(streamId, "HTTP/2 DATA padding consumes its payload")
    }
    let count = payload.size - padding - 1
    let data = Array<Byte>(count, repeat: 0u8)
    for (index in 0..count) { data[index] = payload[index + 1] }
    Http2DecodedPushedData(data)
}

private func checkPushContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 push receive cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody,
            NetworkErrorCode.TimedOut, "HTTP/2 push receive deadline exceeded",
            retryability: Retryability.Temporary
        )
    }
}

private func pushedStreamError(streamId: Http2StreamId, message: String): Nothing {
    throw Http2ProtocolException(
        Http2ErrorCode.ProtocolError, Http2ErrorScope.Stream(streamId), message
    )
}
