package wirestack.internal.http2

import std.collection.*
import std.sync.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

/** Read-only bounded resource counters used by diagnostics and benchmarks. */
public class Http2ClientMetrics {
    public let pendingWrites: Int64
    public let pendingWriteBytes: UInt64
    public let maximumPendingWrites: Int64
    public let maximumPendingWriteBytes: UInt64
    public let pendingFlowPermits: Int64
    public let flowControlStalls: Int64
    public let readerTerminationListeners: Int64
    public let resetListeners: Int64
    public let goAwayListeners: Int64

    internal init(
        pendingWrites: Int64,
        pendingWriteBytes: UInt64,
        maximumPendingWrites: Int64,
        maximumPendingWriteBytes: UInt64,
        pendingFlowPermits: Int64,
        flowControlStalls: Int64,
        readerTerminationListeners: Int64,
        resetListeners: Int64,
        goAwayListeners: Int64
    ) {
        this.pendingWrites = pendingWrites
        this.pendingWriteBytes = pendingWriteBytes
        this.maximumPendingWrites = maximumPendingWrites
        this.maximumPendingWriteBytes = maximumPendingWriteBytes
        this.pendingFlowPermits = pendingFlowPermits
        this.flowControlStalls = flowControlStalls
        this.readerTerminationListeners = readerTerminationListeners
        this.resetListeners = resetListeners
        this.goAwayListeners = goAwayListeners
    }
}

/**
 * One multiplexed HTTP/2 client connection. A single reader and writer own the
 * transport while request tasks own independent stream exchanges.
 */
public class Http2ClientConnection <: Resource {
    private let machine: Http2ConnectionStateMachine
    private let reader: Http2ConnectionReader
    private let writer: Http2WriteScheduler
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let goAway: Http2GoAwayManager
    private let reset: Http2StreamResetManager
    private let health: Http2ConnectionHealth
    private let closer: Http2ConnectionCloser
    private let dispatcher: Http2ClientDispatcher
    private let encoder: HpackEncoder
    private let encoderMutex = Mutex()
    private let limits: HttpLimits
    private let http2Limits: Http2Limits

    private init(
        machine: Http2ConnectionStateMachine,
        reader: Http2ConnectionReader,
        writer: Http2WriteScheduler,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        goAway: Http2GoAwayManager,
        reset: Http2StreamResetManager,
        health: Http2ConnectionHealth,
        closer: Http2ConnectionCloser,
        dispatcher: Http2ClientDispatcher,
        encoder: HpackEncoder,
        limits: HttpLimits,
        http2Limits: Http2Limits
    ) {
        this.machine = machine
        this.reader = reader
        this.writer = writer
        this.registry = registry
        this.flow = flow
        this.goAway = goAway
        this.reset = reset
        this.health = health
        this.closer = closer
        this.dispatcher = dispatcher
        this.encoder = encoder
        this.limits = limits
        this.http2Limits = http2Limits
    }

    /**
     * Takes ownership of an already-negotiated h2 transport, sends the client
     * preface, starts exactly one reader/writer and waits for peer SETTINGS.
     */
    public static func connect(
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background(),
        limits!: HttpLimits = HttpLimits(),
        http2Limits!: Http2Limits = Http2Limits()
    ): Http2ClientConnection {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client, limits: http2Limits)
        let writer = Http2WriteScheduler(transport, limits: http2Limits)
        let flow = Http2FlowController(limits: http2Limits)
        let dispatcher = Http2ClientDispatcher(machine, writer, flow, limits, http2Limits)
        let reader = Http2ConnectionReader(transport, machine, dispatcher, limits: http2Limits)
        let registry = Http2StreamRegistry(
            Http2ConnectionRole.Client,
            limits: http2Limits,
            terminationRegistry: Some(reader.terminationRegistry)
        )
        let goAway = Http2GoAwayManager(machine, registry, flow, writer, limits: http2Limits)
        let reset = Http2StreamResetManager(registry, flow, writer, limits: http2Limits)
        let health = Http2ConnectionHealth(writer)
        let closer = Http2ConnectionCloser(machine, registry, flow, writer, goAway, health: Some(health))
        let connection = Http2ClientConnection(
            machine, reader, writer, registry, flow, goAway, reset, health, closer,
            dispatcher, HpackEncoder(limits: http2Limits), limits, http2Limits
        )
        dispatcher.attach(connection, registry, goAway, reset, health)
        try {
            let preface = machine.start(settings: [Http2Setting(Http2SettingId.EnablePush, 0u32)])
            writeAll(transport, ByteSpan(preface), context: context)
            let _ = spawn { writer.run() }
            let _ = spawn { reader.run() }
            dispatcher.waitUntilReady(context)
            connection
        } catch (error: Exception) {
            let _ = closer.abort(reason: clientAbortReason(context))
            throw error
        }
    }

    public prop activeStreamCount: Int64 { get() { registry.activeLocalCount } }
    public prop streamCapacity: UInt32 { get() { registry.peerMaxConcurrentStreams } }
    public prop acceptingNewStreams: Bool {
        get() { goAway.acceptingNewStreams && closer.result.isNone() && machine.completion.isNone() }
    }

    public func metrics(): Http2ClientMetrics {
        Http2ClientMetrics(
            writer.pendingWrites,
            writer.pendingBytes,
            writer.maximumPendingWrites,
            writer.maximumPendingBytes,
            flow.pendingPermitCount,
            flow.flowControlStalls,
            reader.terminationRegistry.activeCount,
            reset.activeListenerCount,
            goAway.activeListenerCount
        )
    }

    /** Executes one request on an independently-owned stream. */
    public func execute(
        request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()
    ): HttpResponse {
        let plan = mapHttp2ClientRequest(request, trailer: trailer, limits: limits, http2Limits: http2Limits)
        let signal = Http2ClientExecutionSignal()
        if (!acceptingNewStreams) { throw Http2StreamLimitException("HTTP/2 connection is draining") }
        let admitted = admitStream(signal, plan.endStreamOnHeaders)
        executeAdmitted(
            request, plan, admitted.stream, admitted.registration, signal, context: context
        )
    }

    /** Atomically admits a stream for a capacity-aware external pool. */
    public func openStream(
        listener: Http2GoAwayListener,
        endStream: Bool
    ): Http2GoAwayStreamAdmission {
        if (!acceptingNewStreams) { throw Http2StreamLimitException("HTTP/2 connection is draining") }
        admitStream(listener, endStream)
    }

    /** Executes a request on a stream already claimed by a multiplexing pool. */
    public func executeAdmitted(
        request: HttpRequest,
        plan: Http2ClientRequestPlan,
        stream: Http2StreamStateMachine,
        goAwayRegistration: Http2GoAwayRegistration,
        signal: Http2ClientExecutionSignal,
        context!: OperationContext = OperationContext.background(),
        connectionCancellation!: CancellationToken = CancellationToken.none(),
        onTerminated!: () -> Unit = { => }
    ): HttpResponse {
        let termination = reader.terminationRegistry.register(signal)
        var exchange: ?Http2ClientExchange = None<Http2ClientExchange>
        try {
            let opened = Http2ClientExchange(
                stream.id, request.method, registry, flow, writer, reset,
                goAwayRegistration, termination, signal, context, limits, http2Limits,
                onTerminated
            )
            exchange = Some(opened)
            signal.attach(opened)
            opened.bindReset(reset.register(opened.streamId, signal))
            dispatcher.add(opened)
            opened.bindCancellation(context.cancellation, connectionCancellation)
            submitHeaderFields(opened.streamId, plan.initialHeaders, plan.endStreamOnHeaders, context)
            if (!plan.endStreamOnHeaders) {
                sendRequestBody(opened, plan.openBody(), context)
            }
            opened.awaitResponse(context)
        } catch (error: Exception) {
            match (exchange) {
                case Some(value) => value.failLocal(error)
                case None =>
                    goAwayRegistration.unregister()
                    termination.unregister()
                    try { let _ = reset.cancelLocal(stream.id) } catch (_: Exception) {}
            }
            throw error
        }
    }

    public func pollHealth(): Http2HealthPollResult { health.poll() }
    public func close(): Unit { let _ = closer.close() }
    public func isClosed(): Bool { closer.result.isSome() || machine.completion.isSome() }
    public func cancel(): Unit {
        dispatcher.cancelAll()
        let _ = closer.abort(reason: AbortReason.Cancelled)
    }
    public func abort(reason!: AbortReason = AbortReason.ApplicationAbort): Unit {
        let _ = closer.abort(reason: reason)
    }

    private func submitHeaderFields(
        streamId: Http2StreamId,
        fields: Array<HpackFieldEncoding>,
        endStream: Bool,
        context: OperationContext
    ): Unit {
        let tickets = synchronized(encoderMutex) {
            let block = encoder.encode(fields)
            writer.enqueueControlBatch(fragmentClientHeaders(
                streamId, block, endStream, machine.peerSettings.maxFrameSize, http2Limits
            ))
        }
        waitClientWrites(tickets, context)
        health.observeOutboundActivity()
    }

    private func sendRequestBody(
        exchange: Http2ClientExchange,
        body: Http2ClientRequestBody,
        context: OperationContext
    ): Unit {
        try {
            let stagingCapacity = min(Int64(http2Limits.maxFrameSize), 16384)
            let staging = Array<Byte>(stagingCapacity, repeat: 0u8)
            while (true) {
                let count = body.read(staging)
                if (count == 0) { break }
                var offset: Int64 = 0
                while (offset < count) {
                    let permit = flow.reserveSend(exchange.streamId, count - offset, context: context)
                    let payload = Array<Byte>(permit.amount, repeat: 0u8)
                    for (index in 0..permit.amount) { payload[index] = staging[offset + index] }
                    offset += permit.amount
                    let frame = Http2Frame(
                        Http2FrameHeader(
                            UInt32(payload.size), Http2FrameType.Data, Http2Flags(),
                            exchange.streamId, limits: http2Limits
                        ),
                        payload
                    )
                    waitClientWrite(writer.enqueueReservedData(frame, permit), context)
                    health.observeOutboundActivity()
                }
            }
            let trailers = body.finishTrailers()
            if (trailers.isEmpty()) {
                let terminal = Http2Frame(
                    Http2FrameHeader(
                        0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8),
                        exchange.streamId, limits: http2Limits
                    ),
                    []
                )
                waitClientWrite(writer.enqueue(terminal), context)
            } else {
                submitHeaderFields(exchange.streamId, trailers, true, context)
            }
            registry.localEnd(exchange.streamId)
        } finally {
            body.close()
        }
    }

    internal func updatePeerSettings(peer: Http2SettingsSnapshot): Unit {
        registry.updatePeerMaxConcurrentStreams(peer.maxConcurrentStreams)
        flow.applyPeerSettings(Http2SettingsUpdate(peer, 0, http2SettingsAck()))
        synchronized(encoderMutex) { encoder.updatePeerTableCapacity(UInt64(peer.headerTableSize)) }
    }

    internal func remove(streamId: Http2StreamId): Unit { dispatcher.remove(streamId) }

    private func admitStream(
        listener: Http2GoAwayListener,
        endStream: Bool
    ): Http2GoAwayStreamAdmission {
        try {
            goAway.openLocal(listener, endStream: endStream)
        } catch (error: IllegalStateException) {
            // GOAWAY may win after the optimistic phase check. Keep that
            // internal state-machine race behind the stable capacity error.
            if (!goAway.acceptingNewStreams) {
                throw Http2StreamLimitException("HTTP/2 connection is draining")
            }
            throw error
        }
    }
}

/** One bounded retained terminal signal shared by GOAWAY, RST and reader death. */
public class Http2ClientExecutionSignal <: Http2GoAwayListener &
    Http2StreamResetListener & Http2ReaderTerminationListener {
    private let mutex = Mutex()
    private var exchange: ?Http2ClientExchange = None<Http2ClientExchange>
    private var failure: ?Exception = None<Exception>

    func attach(value: Http2ClientExchange): Unit {
        let retained = synchronized(mutex) { exchange = Some(value); failure }
        if (let Some(error) <- retained) { value.signalFailure(error) }
    }

    public func connectionGoAway(error: Http2GoAwayException): Unit { retain(error) }

    public func streamReset(event: Http2StreamResetEvent): Unit {
        retain(Http2ProtocolException(event.code, Http2ErrorScope.Stream(event.streamId), event.reason))
    }

    public func readerTerminated(completion: Http2ConnectionCompletion): Unit {
        retain(Http2ProtocolException(completion.code, Http2ErrorScope.Connection, completion.reason))
    }

    private func retain(error: Exception): Unit {
        let target = synchronized(mutex) {
            if (failure.isNone()) { failure = Some(error) }
            exchange
        }
        if (let Some(value) <- target) { value.signalFailure(error) }
    }
}

/** Per-stream client response owner and body lifecycle hook. */
class Http2ClientExchange <: ResponseBodyObserver {
    public let streamId: Http2StreamId
    private let sequence: Http2ClientResponseSequence
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let reset: Http2StreamResetManager
    private let goAwayRegistration: Http2GoAwayRegistration
    private let readerRegistration: Http2ReaderTerminationRegistration
    private let signal: Http2ClientExecutionSignal
    private let context: OperationContext
    private let channel: Http2ClientBodyChannel
    private let onTerminated: () -> Unit
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var response: ?HttpResponse = None<HttpResponse>
    private var failure: ?Exception = None<Exception>
    private var resetRegistration: ?Http2StreamResetRegistration = None<Http2StreamResetRegistration>
    private var streamCancellation: ?CancellationRegistration = None<CancellationRegistration>
    private var connectionCancellation: ?CancellationRegistration = None<CancellationRegistration>
    private var connection: ?Http2ClientConnection = None<Http2ClientConnection>
    private var terminal = false

    init(
        streamId: Http2StreamId,
        method: HttpMethod,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        reset: Http2StreamResetManager,
        goAwayRegistration: Http2GoAwayRegistration,
        readerRegistration: Http2ReaderTerminationRegistration,
        signal: Http2ClientExecutionSignal,
        context: OperationContext,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        onTerminated: () -> Unit
    ) {
        this.streamId = streamId
        sequence = Http2ClientResponseSequence(streamId, method, limits: limits, http2Limits: http2Limits)
        this.registry = registry
        this.flow = flow
        this.writer = writer
        this.reset = reset
        this.goAwayRegistration = goAwayRegistration
        this.readerRegistration = readerRegistration
        this.signal = signal
        this.context = context
        this.onTerminated = onTerminated
        channel = Http2ClientBodyChannel(streamId, flow, writer, context, http2Limits)
    }

    func bind(connection: Http2ClientConnection): Unit { this.connection = Some(connection) }
    func bindReset(value: Http2StreamResetRegistration): Unit { resetRegistration = Some(value) }

    func bindCancellation(streamToken: CancellationToken, connectionToken: CancellationToken): Unit {
        let streamRegistration = streamToken.register { => cancelStream() }
        let connectionRegistration = connectionToken.register { => cancelConnection() }
        let discard = synchronized(mutex) {
            if (terminal) {
                true
            } else {
                streamCancellation = Some(streamRegistration)
                connectionCancellation = Some(connectionRegistration)
                false
            }
        }
        if (discard) {
            streamRegistration.unregister()
            connectionRegistration.unregister()
        }
    }

    func acceptHeaders(fields: Array<HpackHeaderField>, endStream: Bool): Unit {
        let event = sequence.acceptHeaders(fields, endStream)
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
                    if (response.isSome()) { throw IllegalStateException("HTTP/2 response was already published") }
                    response = Some(head.toResponse(body))
                    changed.notifyAll()
                }
                if (endStream) {
                    registry.peerEnd(streamId)
                    channel.finish(None<HttpTrailer>)
                }
            case Http2ClientHeaderEventKind.Trailer =>
                registry.peerEnd(streamId)
                channel.finish(event.trailer)
        }
    }

    func acceptData(frame: Http2Frame): Unit {
        let decoded = decodeClientData(frame, streamId)
        sequence.acceptData(decoded.data.size, frame.header.flags.isEndStream())
        if (frame.header.flags.isEndStream()) {
            channel.offer(decoded.data, Int64(frame.header.length), false)
            registry.peerEnd(streamId)
            channel.finish(None<HttpTrailer>)
        } else {
            channel.offer(decoded.data, Int64(frame.header.length), false)
        }
    }

    func awaitResponse(waitContext: OperationContext): HttpResponse {
        let registration = waitContext.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (response.isNone() && failure.isNone()) {
                    checkClientContext(waitContext)
                    match (waitContext.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                if (let Some(error) <- failure) { throw error }
                response.getOrThrow()
            }
        } finally {
            registration.unregister()
        }
    }

    func signalFailure(error: Exception): Unit {
        synchronized(mutex) {
            if (failure.isNone()) { failure = Some(error) }
            changed.notifyAll()
        }
        channel.fail(error)
    }

    func failLocal(error: Exception): Unit {
        signalFailure(error)
        // Return any buffered connection credit while the flow stream still
        // exists. RST removes that state, so doing this afterwards could turn
        // failure cleanup into a second exception and leak registrations.
        try { channel.close() } catch (_: Exception) {}
        try { let _ = reset.cancelLocal(streamId) } catch (_: Exception) {}
        finish()
    }

    func connectionTerminated(error: Exception): Unit {
        signalFailure(error)
        finish()
    }

    public func completed(): Unit { finish() }
    public func abandoned(): Unit {
        try { let _ = reset.cancelLocal(streamId) } catch (_: Exception) {}
        finish()
    }

    private func finish(): Unit {
        let owns = synchronized(mutex) {
            if (terminal) { false } else { terminal = true; true }
        }
        if (!owns) { return }
        try { channel.close() } catch (_: Exception) {}
        if (let Some(value) <- streamCancellation) { value.unregister() }
        if (let Some(value) <- connectionCancellation) { value.unregister() }
        if (let Some(value) <- resetRegistration) { value.unregister() }
        goAwayRegistration.unregister()
        readerRegistration.unregister()
        let updates = flow.closeStream(streamId)
        for (frame in updates) {
            try { let _ = writer.enqueue(frame) } catch (_: Exception) {}
        }
        if (let Some(value) <- connection) { value.remove(streamId) }
        try { onTerminated() } catch (_: Exception) {}
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }

    private func cancelStream(): Unit {
        let error = NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 stream cancelled", retryability: Retryability.Never
        )
        signalFailure(error)
        try { let _ = reset.cancelLocal(streamId) } catch (_: Exception) {}
        finish()
    }

    private func cancelConnection(): Unit {
        match (connection) {
            case Some(value) => value.cancel()
            case None => cancelStream()
        }
    }
}

private class Http2ClientBodyChannel <: HttpBodyStream {
    private let streamId: Http2StreamId
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let context: OperationContext
    private let maxSegments: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let segments = ArrayList<Http2ClientBodySegment>()
    private var expectedLength: ?Int64 = None<Int64>
    private var retainedTrailer: ?HttpTrailer = None<HttpTrailer>
    private var failure: ?Exception = None<Exception>
    private var eof = false
    private var closed = false

    public prop contentLength: ?Int64 { get() { synchronized(mutex) { expectedLength } } }
    prop trailer: ?HttpTrailer { get() { synchronized(mutex) { retainedTrailer } } }

    init(
        streamId: Http2StreamId,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        context: OperationContext,
        limits: Http2Limits
    ) {
        this.streamId = streamId
        this.flow = flow
        this.writer = writer
        this.context = context
        maxSegments = Int64(limits.maxPendingWrites)
    }

    func setExpectedLength(value: ?Int64): Unit { synchronized(mutex) { expectedLength = value } }

    func offer(data: Array<Byte>, flowBytes: Int64, endStream: Bool): Unit {
        if (flowBytes < data.size) { clientStreamError(streamId, "HTTP/2 DATA accounting is smaller than content") }
        var immediateCredit: Int64 = 0
        synchronized(mutex) {
            if (eof) { clientStreamError(streamId, "HTTP/2 DATA arrived after response completion") }
            if (!closed && !data.isEmpty() && segments.size >= maxSegments) {
                clientStreamError(streamId, "HTTP/2 response body segment queue reached its bound")
            }
            flow.receiveData(streamId, flowBytes)
            if (closed || data.isEmpty()) { immediateCredit = flowBytes }
            else { segments.add(Http2ClientBodySegment(data, flowBytes)) }
            if (endStream) { eof = true }
            changed.notifyAll()
        }
        publishCredit(immediateCredit)
    }

    func finish(trailer: ?HttpTrailer): Unit {
        synchronized(mutex) {
            retainedTrailer = trailer
            eof = true
            changed.notifyAll()
        }
    }

    func fail(error: Exception): Unit {
        synchronized(mutex) {
            if (failure.isNone()) { failure = Some(error) }
            eof = true
            changed.notifyAll()
        }
    }

    public func read(destination: Array<Byte>): Int64 {
        if (destination.isEmpty()) { return 0 }
        let registration = context.cancellation.register { => wake() }
        var updates = Array<Http2Frame>()
        try {
            let count = synchronized(mutex) {
                while (segments.isEmpty() && !eof && !closed && failure.isNone()) {
                    checkClientContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                checkClientContext(context)
                if (let Some(error) <- failure) { throw error }
                if (closed) { throw IllegalStateException("HTTP/2 response body is closed") }
                if (segments.isEmpty()) { return 0 }
                let segment = segments[0]
                let result = min(destination.size, segment.remainingData)
                for (index in 0..result) { destination[index] = segment.data[segment.offset + index] }
                segment.offset += result
                let credit = if (segment.remainingData == 0) { segment.remainingFlowBytes } else { result }
                segment.remainingFlowBytes -= credit
                if (segment.remainingData == 0) { let _ = segments.remove(at: 0) }
                if (credit > 0) { updates = flow.consumeReceived(streamId, credit) }
                result
            }
            submitClientUpdates(writer, updates, context)
            count
        } finally {
            registration.unregister()
        }
    }

    public func close(): Unit {
        var updates = Array<Http2Frame>()
        synchronized(mutex) {
            if (closed) { return }
            closed = true
            var credit: Int64 = 0
            for (segment in segments) { credit += segment.remainingFlowBytes }
            segments.clear()
            if (credit > 0) { updates = flow.consumeReceivedNow(streamId, credit) }
            changed.notifyAll()
        }
        submitClientUpdates(writer, updates, context)
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func publishCredit(bytes: Int64): Unit {
        if (bytes > 0) {
            submitClientUpdates(writer, flow.consumeReceived(streamId, bytes), context)
        }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private class Http2ClientBodySegment {
    let data: Array<Byte>
    var offset: Int64 = 0
    var remainingFlowBytes: Int64
    prop remainingData: Int64 { get() { data.size - offset } }
    init(data: Array<Byte>, flowBytes: Int64) {
        this.data = data.clone()
        remainingFlowBytes = flowBytes
    }
}

private class Http2ClientDispatcher <: Http2InboundFrameHandler {
    private let machine: Http2ConnectionStateMachine
    private let writer: Http2WriteScheduler
    private let flow: Http2FlowController
    private let decoder: HpackDecoder
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let exchanges = ArrayList<Http2ClientExchange>()
    private var connection: ?Http2ClientConnection = None<Http2ClientConnection>
    private var registry: ?Http2StreamRegistry = None<Http2StreamRegistry>
    private var goAway: ?Http2GoAwayManager = None<Http2GoAwayManager>
    private var reset: ?Http2StreamResetManager = None<Http2StreamResetManager>
    private var health: ?Http2ConnectionHealth = None<Http2ConnectionHealth>

    init(
        machine: Http2ConnectionStateMachine,
        writer: Http2WriteScheduler,
        flow: Http2FlowController,
        limits: HttpLimits,
        http2Limits: Http2Limits
    ) {
        this.machine = machine
        this.writer = writer
        this.flow = flow
        this.limits = limits
        this.http2Limits = http2Limits
        decoder = HpackDecoder(limits: http2Limits)
    }

    func attach(
        connection: Http2ClientConnection,
        registry: Http2StreamRegistry,
        goAway: Http2GoAwayManager,
        reset: Http2StreamResetManager,
        health: Http2ConnectionHealth
    ): Unit {
        synchronized(mutex) {
            this.connection = Some(connection)
            this.registry = Some(registry)
            this.goAway = Some(goAway)
            this.reset = Some(reset)
            this.health = Some(health)
        }
    }

    func add(exchange: Http2ClientExchange): Unit {
        let connection = synchronized(mutex) {
            if (exchanges.size >= Int64(http2Limits.maxConcurrentStreams)) {
                throw Http2StreamLimitException("HTTP/2 client exchange limit reached")
            }
            exchanges.add(exchange)
            this.connection.getOrThrow()
        }
        exchange.bind(connection)
    }

    func remove(streamId: Http2StreamId): Unit {
        synchronized(mutex) {
            for (index in 0..exchanges.size) {
                if (exchanges[index].streamId.value == streamId.value) {
                    let _ = exchanges.remove(at: index)
                    return
                }
            }
        }
    }

    func waitUntilReady(context: OperationContext): Unit {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (isClientPrefacePhase(machine.phase) && machine.completion.isNone()) {
                    checkClientContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                if (let Some(completion) <- machine.completion) {
                    throw Http2ProtocolException(completion.code, Http2ErrorScope.Connection, completion.reason)
                }
            }
        } finally {
            registration.unregister()
        }
    }

    func cancelAll(): Unit {
        let current = synchronized(mutex) {
            let result = ArrayList<Http2ClientExchange>()
            for (exchange in exchanges) { result.add(exchange) }
            result.toArray()
        }
        for (exchange in current) {
            exchange.connectionTerminated(NetworkException(
                NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody,
                NetworkErrorCode.Cancelled, "HTTP/2 connection cancelled",
                retryability: Retryability.Never
            ))
        }
    }

    public func handle(frame: Http2Frame, result: Http2ConnectionReceiveResult): Unit {
        if (let Some(value) <- health) { let _ = value.observeInbound(frame) }
        for (outbound in result.outbound) { let _ = writer.enqueue(outbound) }
        try {
            match (frame.header.frameType) {
                case Http2FrameType.Settings => handleSettings(frame)
                case Http2FrameType.WindowUpdate => flow.receiveWindowUpdate(frame)
                case Http2FrameType.RstStream => let _ = reset.getOrThrow().acceptPeer(frame)
                case Http2FrameType.GoAway => let _ = goAway.getOrThrow().acceptPeer(result)
                case Http2FrameType.Data => requireExchange(frame.header.streamId).acceptData(frame)
                case Http2FrameType.PushPromise =>
                    throw Http2ProtocolException(
                        Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                        "HTTP/2 server push is disabled by the client"
                    )
                case _ => ()
            }
            if (let Some(block) <- result.headerBlock) {
                match (block.kind) {
                    case Http2HeaderBlockKind.Headers =>
                        requireExchange(block.streamId).acceptHeaders(decoder.decode(block.bytes), block.endStream)
                    case Http2HeaderBlockKind.PushPromise =>
                        throw Http2ProtocolException(
                            Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                            "HTTP/2 server push is disabled by the client"
                        )
                }
            }
        } catch (error: Http2ProtocolException) {
            match (error.scope) {
                case Http2ErrorScope.Stream(streamId) =>
                    try { let _ = reset.getOrThrow().cancelLocal(streamId, code: error.code, reason: error.message) }
                    catch (_: Exception) {}
                case Http2ErrorScope.Connection => throw error
            }
        }
    }

    public func readerTerminated(
        completion: Http2ConnectionCompletion,
        terminalGoAway: ?Http2Frame
    ): Unit {
        if (let Some(frame) <- terminalGoAway) {
            try { let _ = writer.enqueue(frame) } catch (_: Exception) {}
        }
        flow.close()
        if (let Some(value) <- health) { value.close() }
        let current = synchronized(mutex) {
            changed.notifyAll()
            let result = ArrayList<Http2ClientExchange>()
            for (exchange in exchanges) { result.add(exchange) }
            result.toArray()
        }
        let error = Http2ProtocolException(
            completion.code, Http2ErrorScope.Connection, completion.reason
        )
        for (exchange in current) { exchange.connectionTerminated(error) }
    }

    private func handleSettings(frame: Http2Frame): Unit {
        if (!frame.header.flags.isAck()) {
            connection.getOrThrow().updatePeerSettings(machine.peerSettings)
            synchronized(mutex) { changed.notifyAll() }
        }
    }

    private func requireExchange(streamId: Http2StreamId): Http2ClientExchange {
        synchronized(mutex) {
            for (exchange in exchanges) {
                if (exchange.streamId.value == streamId.value) { return exchange }
            }
        }
        throw Http2ProtocolException(
            Http2ErrorCode.StreamClosed, Http2ErrorScope.Stream(streamId),
            "HTTP/2 frame referenced an inactive client stream"
        )
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private struct Http2DecodedClientData {
    let data: Array<Byte>
    init(data: Array<Byte>) { this.data = data }
}

private func decodeClientData(frame: Http2Frame, streamId: Http2StreamId): Http2DecodedClientData {
    if (frame.header.streamId.value != streamId.value) {
        throw IllegalArgumentException("HTTP/2 DATA belongs to another client stream")
    }
    let payload = frame.payload
    if (!frame.header.flags.isPadded()) { return Http2DecodedClientData(payload) }
    if (payload.isEmpty()) { clientStreamError(streamId, "HTTP/2 padded DATA has no pad length") }
    let padding = Int64(payload[0])
    if (padding >= payload.size) { clientStreamError(streamId, "HTTP/2 DATA padding consumes its payload") }
    let count = payload.size - padding - 1
    let data = Array<Byte>(count, repeat: 0u8)
    for (index in 0..count) { data[index] = payload[index + 1] }
    Http2DecodedClientData(data)
}

private func fragmentClientHeaders(
    streamId: Http2StreamId,
    block: Array<Byte>,
    endStream: Bool,
    peerMaxFrameSize: UInt32,
    limits: Http2Limits
): Array<Http2Frame> {
    let maximum = Int64(min(peerMaxFrameSize, limits.maxFrameSize))
    let frames = ArrayList<Http2Frame>()
    var offset: Int64 = 0
    var first = true
    while (first || offset < block.size) {
        let count = min(maximum, block.size - offset)
        let payload = Array<Byte>(count, repeat: 0u8)
        for (index in 0..count) { payload[index] = block[offset + index] }
        offset += count
        let last = offset == block.size
        var flags: Byte = if (last) { 0x04u8 } else { 0u8 }
        if (first && endStream) { flags |= 0x01u8 }
        frames.add(Http2Frame(
            Http2FrameHeader(
                UInt32(count),
                if (first) { Http2FrameType.Headers } else { Http2FrameType.Continuation },
                Http2Flags(raw: flags), streamId, limits: limits
            ),
            payload
        ))
        first = false
    }
    frames.toArray()
}

private func waitClientWrites(tickets: Array<Http2WriteTicket>, context: OperationContext): Unit {
    for (ticket in tickets) { waitClientWrite(ticket, context) }
}

private func waitClientWrite(ticket: Http2WriteTicket, context: OperationContext): Unit {
    let state = ticket.wait(context: context)
    match (state) {
        case Http2WriteState.Written => ()
        case Http2WriteState.Cancelled => throw IllegalStateException("HTTP/2 write was cancelled")
        case Http2WriteState.Failed => throw IllegalStateException("HTTP/2 write failed: ${ticket.failure}")
        case _ => throw IllegalStateException("HTTP/2 write did not reach a terminal state")
    }
}

private func submitClientUpdates(
    writer: Http2WriteScheduler,
    frames: Array<Http2Frame>,
    context: OperationContext
): Unit {
    if (frames.isEmpty()) { return }
    waitClientWrites(
        writer.enqueueControlBatchWaiting(frames, context: context), context
    )
}

private func checkClientContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 operation cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut,
            "HTTP/2 operation deadline exceeded", retryability: Retryability.Temporary
        )
    }
}

private func clientAbortReason(context: OperationContext): AbortReason {
    if (context.isCancellationRequested()) { AbortReason.Cancelled }
    else if (context.isDeadlineExceeded()) { AbortReason.DeadlineExceeded }
    else { AbortReason.ProtocolFailure }
}

private func clientStreamError(streamId: Http2StreamId, message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Stream(streamId), message)
}

private func isClientPrefacePhase(phase: Http2ConnectionPhase): Bool {
    match (phase) { case Http2ConnectionPhase.Preface => true; case _ => false }
}
