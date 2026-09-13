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

/** Successful stream-scoped CONNECT metadata and its uniquely-owned transport. */
public class Http2ConnectedStream <: Resource {
    public let transport: DuplexTransport
    public let status: Int64
    public let headers: HttpHeaders

    internal init(transport: DuplexTransport, status: Int64, headers: HttpHeaders) {
        this.transport = transport
        this.status = status
        this.headers = headers
    }

    public func close(): Unit { transport.close() }
    public func isClosed(): Bool { transport.isClosed() }
}

/** A CONNECT either transfers a duplex stream or returns the full rejected response. */
public enum Http2ConnectResult {
    | Connected(Http2ConnectedStream)
    | Rejected(HttpResponse)
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
    private let initialHeadersMutex = Mutex()
    private let initialHeadersChanged = synchronized(initialHeadersMutex) {
        initialHeadersMutex.condition()
    }
    private var nextInitialHeadersStreamId: UInt32 = 1u32
    private let abandonedInitialHeaders = ArrayList<UInt32>()
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
        http2Limits!: Http2Limits = Http2Limits(),
        pushConfig!: ?Http2PushConfig = None<Http2PushConfig>
    ): Http2ClientConnection {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client, limits: http2Limits)
        let writer = Http2WriteScheduler(transport, limits: http2Limits)
        let pushCapacity = clientPushCapacity(pushConfig, http2Limits)
        let flow = Http2FlowController(
            limits: http2Limits,
            maximumStreams: combinedClientStreamCapacity(http2Limits.maxConcurrentStreams, pushCapacity)
        )
        let dispatcher = Http2ClientDispatcher(
            machine, writer, flow, limits, http2Limits, pushConfig
        )
        let reader = Http2ConnectionReader(
            transport, machine, dispatcher, limits: http2Limits,
            additionalStreamListeners: pushCapacity
        )
        let registry = Http2StreamRegistry(
            Http2ConnectionRole.Client,
            limits: http2Limits,
            terminationRegistry: Some(reader.terminationRegistry)
        )
        registry.updateLocalMaxConcurrentStreams(pushCapacity)
        let goAway = Http2GoAwayManager(machine, registry, flow, writer, limits: http2Limits)
        let reset = Http2StreamResetManager(
            registry, flow, writer, limits: http2Limits,
            additionalStreamListeners: pushCapacity
        )
        let health = Http2ConnectionHealth(writer)
        let closer = Http2ConnectionCloser(machine, registry, flow, writer, goAway, health: Some(health))
        let connection = Http2ClientConnection(
            machine, reader, writer, registry, flow, goAway, reset, health, closer,
            dispatcher, HpackEncoder(limits: http2Limits), limits, http2Limits
        )
        dispatcher.attach(connection, registry, goAway, reset, health, reader.terminationRegistry)
        try {
            let preface = machine.start(settings: initialHttp2Settings(
                Http2ConnectionRole.Client, http2Limits,
                enablePush: pushConfig.isSome(),
                maximumConcurrentStreams: pushCapacity
            ))
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
    /** Total protocol and response-body owners retained by this connection. */
    public prop ownedStreamCount: Int64 { get() { dispatcher.ownerCount } }
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

    /**
     * Opens an ordinary or extended CONNECT without ending either DATA
     * direction at handshake completion.
     */
    public func connectStream(
        request: HttpRequest,
        protocol!: ?String = None<String>,
        context!: OperationContext = OperationContext.background(),
        onTerminated!: () -> Unit = { => },
        connectionCancellation!: CancellationToken = CancellationToken.none()
    ): Http2ConnectResult {
        let plan = prepareConnectPlan(request, protocol)
        let signal = Http2ClientExecutionSignal()
        if (!acceptingNewStreams) {
            throw Http2StreamLimitException("HTTP/2 connection is draining")
        }
        let admitted = admitStream(signal, false)
        connectPlanAdmitted(
            request, plan, admitted.stream, admitted.registration, signal,
            context, connectionCancellation, onTerminated
        )
    }

    /** Executes CONNECT on a stream already claimed by a multiplexing pool. */
    public func connectAdmitted(
        request: HttpRequest,
        protocol: ?String,
        stream: Http2StreamStateMachine,
        goAwayRegistration: Http2GoAwayRegistration,
        signal: Http2ClientExecutionSignal,
        context: OperationContext,
        connectionCancellation: CancellationToken,
        onTerminated: () -> Unit
    ): Http2ConnectResult {
        let plan = try {
            prepareConnectPlan(request, protocol)
        } catch (error: Exception) {
            releaseUnpublishedAdmission(
                stream, goAwayRegistration, onTerminated,
                "HTTP/2 CONNECT mapping failed before initial headers"
            )
            throw error
        }
        connectPlanAdmitted(
            request, plan, stream, goAwayRegistration, signal,
            context, connectionCancellation, onTerminated
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
        var initialHeadersQueued = false
        try {
            let pushSource = dispatcher.newPushSource(stream.id, request.url)
            let opened = Http2ClientExchange(
                stream.id, request.method, registry, flow, writer, reset,
                goAwayRegistration, termination, signal, context, limits, http2Limits,
                pushSource, false, onTerminated
            )
            exchange = Some(opened)
            signal.attach(opened)
            opened.bindReset(reset.register(opened.streamId, opened))
            dispatcher.add(opened)
            signal.attachInitialHeadersWakeup({ => wakeInitialHeaders() })
            let initialTickets = enqueueInitialHeaderFields(
                opened.streamId, plan.initialHeaders, plan.endStreamOnHeaders, signal, context
            )
            initialHeadersQueued = true
            opened.bindCancellation(context.cancellation, connectionCancellation)
            waitClientWrites(initialTickets, context)
            health.observeOutboundActivity()
            if (!plan.endStreamOnHeaders) {
                sendRequestBody(opened, plan.openBody(), context)
            }
            opened.awaitResponse(context)
        } catch (error: Exception) {
            if (!initialHeadersQueued) { abandonInitialHeaders(stream.id) }
            match (exchange) {
                case Some(value) =>
                    if (initialHeadersQueued) { value.failLocal(error) }
                    else { value.failBeforeInitialHeaders(error) }
                case None =>
                    goAwayRegistration.unregister()
                    termination.unregister()
                    if (initialHeadersQueued) {
                        try { let _ = reset.cancelLocal(stream.id) } catch (_: Exception) {}
                    } else {
                        try {
                            let _ = registry.reset(
                                stream.id, Http2ErrorCode.Cancel,
                                "HTTP/2 request failed before initial headers"
                            )
                        } catch (_: Exception) {}
                        let _ = flow.closeStream(stream.id)
                    }
            }
            throw error
        }
    }

    private func connectPlanAdmitted(
        request: HttpRequest,
        plan: Http2ClientRequestPlan,
        stream: Http2StreamStateMachine,
        goAwayRegistration: Http2GoAwayRegistration,
        signal: Http2ClientExecutionSignal,
        context: OperationContext,
        connectionCancellation: CancellationToken,
        onTerminated: () -> Unit
    ): Http2ConnectResult {
        let termination = reader.terminationRegistry.register(signal)
        var exchange: ?Http2ClientExchange = None<Http2ClientExchange>
        var initialHeadersQueued = false
        try {
            let pushSource = dispatcher.newPushSource(stream.id, request.url)
            let opened = Http2ClientExchange(
                stream.id, request.method, registry, flow, writer, reset,
                goAwayRegistration, termination, signal, context, limits, http2Limits,
                pushSource, true, onTerminated
            )
            exchange = Some(opened)
            signal.attach(opened)
            opened.bindReset(reset.register(opened.streamId, opened))
            dispatcher.add(opened)
            signal.attachInitialHeadersWakeup({ => wakeInitialHeaders() })
            let initialTickets = enqueueInitialHeaderFields(
                opened.streamId, plan.initialHeaders, false, signal, context
            )
            initialHeadersQueued = true
            opened.bindCancellation(context.cancellation, connectionCancellation)
            waitClientWrites(initialTickets, context)
            health.observeOutboundActivity()
            let result = opened.awaitConnect(context)
            match (result) {
                case Http2ConnectResult.Connected(_) => opened.releaseHandshakeCancellation()
                case Http2ConnectResult.Rejected(_) => ()
            }
            result
        } catch (error: Exception) {
            if (!initialHeadersQueued) { abandonInitialHeaders(stream.id) }
            match (exchange) {
                case Some(value) =>
                    if (initialHeadersQueued) { value.failLocal(error) }
                    else { value.failBeforeInitialHeaders(error) }
                case None =>
                    goAwayRegistration.unregister()
                    termination.unregister()
                    if (initialHeadersQueued) {
                        try { let _ = reset.cancelLocal(stream.id) } catch (_: Exception) {}
                    } else {
                        try {
                            let _ = registry.reset(
                                stream.id, Http2ErrorCode.Cancel,
                                "HTTP/2 CONNECT failed before initial headers"
                            )
                        } catch (_: Exception) {}
                        let _ = flow.closeStream(stream.id)
                        try { onTerminated() } catch (_: Exception) {}
                    }
            }
            throw error
        }
    }

    private func prepareConnectPlan(
        request: HttpRequest,
        protocol: ?String
    ): Http2ClientRequestPlan {
        if (protocol.isSome() && !machine.peerSettings.enableConnectProtocol) {
            throw IllegalStateException(
                "HTTP/2 peer did not advertise SETTINGS_ENABLE_CONNECT_PROTOCOL"
            )
        }
        mapHttp2ClientConnectRequest(
            request, protocol: protocol, limits: limits, http2Limits: http2Limits
        )
    }

    private func releaseUnpublishedAdmission(
        stream: Http2StreamStateMachine,
        registration: Http2GoAwayRegistration,
        onTerminated: () -> Unit,
        reason: String
    ): Unit {
        abandonInitialHeaders(stream.id)
        registration.unregister()
        try {
            let _ = registry.reset(stream.id, Http2ErrorCode.Cancel, reason)
        } catch (_: Exception) {}
        let _ = flow.closeStream(stream.id)
        try { onTerminated() } catch (_: Exception) {}
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
        let tickets = try {
            synchronized(encoderMutex) {
                let block = encoder.encode(fields)
                writer.enqueueControlBatch(fragmentClientHeaders(
                    streamId, block, endStream, machine.peerSettings.maxFrameSize, http2Limits
                ))
            }
        } catch (error: Exception) {
            // The encoder may already contain dynamic entries that never reached the peer.
            try { abort(reason: AbortReason.ProtocolFailure) } catch (_: Exception) {}
            throw error
        }
        waitClientWrites(tickets, context)
        health.observeOutboundActivity()
    }

    /**
     * Publishes newly opened streams in stream-id order. Admission and request
     * execution are intentionally separate for pool capacity accounting, so
     * concurrent callers may otherwise enqueue stream 3 before stream 1.
     */
    private func enqueueInitialHeaderFields(
        streamId: Http2StreamId,
        fields: Array<HpackFieldEncoding>,
        endStream: Bool,
        signal: Http2ClientExecutionSignal,
        context: OperationContext
    ): Array<Http2WriteTicket> {
        var encodingStarted = false
        try {
            synchronized(initialHeadersMutex) {
                while (streamId.value != nextInitialHeadersStreamId) {
                    if (streamId.value < nextInitialHeadersStreamId) {
                        throw Http2ProtocolException(
                            Http2ErrorCode.StreamClosed, Http2ErrorScope.Stream(streamId),
                            "HTTP/2 client stream was abandoned before initial headers"
                        )
                    }
                    if (let Some(error) <- signal.retainedFailure()) { throw error }
                    checkClientContext(context)
                    match (context.deadline) {
                        case Some(deadline) => initialHeadersChanged.wait(timeout: deadline.remaining())
                        case None => initialHeadersChanged.wait()
                    }
                }
                if (let Some(error) <- signal.retainedFailure()) { throw error }
                checkClientContext(context)
                let tickets = synchronized(encoderMutex) {
                    encodingStarted = true
                    let block = encoder.encode(fields)
                    writer.enqueueControlBatch(fragmentClientHeaders(
                        streamId, block, endStream, machine.peerSettings.maxFrameSize, http2Limits
                    ))
                }
                advanceInitialHeadersLocked()
                tickets
            }
        } catch (error: Exception) {
            if (encodingStarted) {
                try { abort(reason: AbortReason.ProtocolFailure) } catch (_: Exception) {}
            }
            throw error
        }
    }

    private func abandonInitialHeaders(streamId: Http2StreamId): Unit {
        synchronized(initialHeadersMutex) {
            if (streamId.value < nextInitialHeadersStreamId) { return }
            if (streamId.value == nextInitialHeadersStreamId) {
                advanceInitialHeadersLocked()
                return
            }
            for (value in abandonedInitialHeaders) {
                if (value == streamId.value) { return }
            }
            if (abandonedInitialHeaders.size >= Int64(http2Limits.maxConcurrentStreams)) {
                throw IllegalStateException("HTTP/2 initial-header abandonment limit reached")
            }
            abandonedInitialHeaders.add(streamId.value)
        }
    }

    private func advanceInitialHeadersLocked(): Unit {
        nextInitialHeadersStreamId += 2u32
        while (true) {
            var found: Int64 = -1
            for (index in 0..abandonedInitialHeaders.size) {
                if (abandonedInitialHeaders[index] == nextInitialHeadersStreamId) {
                    found = index
                    break
                }
            }
            if (found < 0) { break }
            let _ = abandonedInitialHeaders.remove(at: found)
            nextInitialHeadersStreamId += 2u32
        }
        initialHeadersChanged.notifyAll()
    }

    private func wakeInitialHeaders(): Unit {
        synchronized(initialHeadersMutex) { initialHeadersChanged.notifyAll() }
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
    private var initialHeadersWakeup: () -> Unit = { => }

    func attach(value: Http2ClientExchange): Unit {
        let retained = synchronized(mutex) { exchange = Some(value); failure }
        if (let Some(error) <- retained) { value.signalFailure(error) }
    }

    func attachInitialHeadersWakeup(value: () -> Unit): Unit {
        let failed = synchronized(mutex) {
            initialHeadersWakeup = value
            failure.isSome()
        }
        if (failed) { value() }
    }

    func retainedFailure(): ?Exception { synchronized(mutex) { failure } }

    public func connectionGoAway(error: Http2GoAwayException): Unit { retain(error) }

    public func streamReset(event: Http2StreamResetEvent): Unit {
        retain(Http2ProtocolException(event.code, Http2ErrorScope.Stream(event.streamId), event.reason))
    }

    public func readerTerminated(completion: Http2ConnectionCompletion): Unit {
        retain(Http2ProtocolException(completion.code, Http2ErrorScope.Connection, completion.reason))
    }

    private func retain(error: Exception): Unit {
        let targets = synchronized(mutex) {
            if (failure.isNone()) { failure = Some(error) }
            (exchange, initialHeadersWakeup)
        }
        if (let Some(value) <- targets[0]) { value.signalFailure(error) }
        targets[1]()
    }
}

/** Per-stream client response owner and body lifecycle hook. */
class Http2ClientExchange <: ResponseBodyObserver & Http2StreamResetListener {
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
    private let pushSource: ?Http2ClientPushSource
    private let connectMode: Bool
    private let onTerminated: () -> Unit
    private let http2Limits: Http2Limits
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var response: ?HttpResponse = None<HttpResponse>
    private var connectResult: ?Http2ConnectResult = None<Http2ConnectResult>
    private var duplexTransport: ?Http2StreamTransport = None<Http2StreamTransport>
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
        pushSource: ?Http2ClientPushSource,
        connectMode: Bool,
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
        this.http2Limits = http2Limits
        this.pushSource = pushSource
        this.connectMode = connectMode
        this.onTerminated = onTerminated
        channel = Http2ClientBodyChannel(streamId, flow, writer, context, http2Limits)
    }

    func bind(connection: Http2ClientConnection): Unit { this.connection = Some(connection) }

    func pushAdmissionSource(): ?Http2ClientPushSource { pushSource }
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
                if (connectMode && head.status >= 200 && head.status < 300) {
                    if (let Some(source) <- pushSource) { source.close() }
                    let transport = Http2StreamTransport(
                        streamId, channel, registry, flow, writer, reset, http2Limits,
                        { => finish() }
                    )
                    let connected = Http2ConnectResult.Connected(
                        Http2ConnectedStream(transport, head.status, head.headers)
                    )
                    synchronized(mutex) {
                        if (connectResult.isSome()) {
                            throw IllegalStateException("HTTP/2 CONNECT result was already published")
                        }
                        duplexTransport = Some(transport)
                        connectResult = Some(connected)
                        changed.notifyAll()
                    }
                    if (endStream) {
                        registry.peerEnd(streamId)
                        channel.finish(None<HttpTrailer>)
                        transport.peerTerminated()
                    }
                } else {
                    if (connectMode) { endRejectedConnectRequest() }
                    let body = ResponseBody(
                        channel,
                        observer: this,
                        trailerProvider: { => channel.trailer },
                        completeAtDeclaredLength: false
                    )
                    let source = match (pushSource) {
                        case Some(value) => Some<HttpPushSource>(value)
                        case None => None<HttpPushSource>
                    }
                    let value = head.toResponse(body, pushes: source)
                    synchronized(mutex) {
                        if (response.isSome()) {
                            throw IllegalStateException("HTTP/2 response was already published")
                        }
                        response = Some(value)
                        if (connectMode) {
                            connectResult = Some(Http2ConnectResult.Rejected(value))
                        }
                        changed.notifyAll()
                    }
                    if (endStream) {
                        registry.peerEnd(streamId)
                        channel.finish(None<HttpTrailer>)
                    }
                }
            case Http2ClientHeaderEventKind.Trailer =>
                registry.peerEnd(streamId)
                channel.finish(event.trailer)
                if (let Some(transport) <- synchronized(mutex) { duplexTransport }) {
                    transport.peerTerminated()
                }
        }
        if (endStream) {
            if (let Some(source) <- pushSource) { source.parentFinished() }
        }
    }

    func acceptData(frame: Http2Frame): Unit {
        let decoded = decodeClientData(frame, streamId)
        sequence.acceptData(decoded.size, frame.header.flags.isEndStream())
        if (frame.header.flags.isEndStream()) {
            channel.offer(decoded, Int64(frame.header.length), false)
            registry.peerEnd(streamId)
            channel.finish(None<HttpTrailer>)
            if (let Some(source) <- pushSource) { source.parentFinished() }
        } else {
            channel.offer(decoded, Int64(frame.header.length), false)
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

    func awaitConnect(waitContext: OperationContext): Http2ConnectResult {
        let registration = waitContext.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (connectResult.isNone() && failure.isNone()) {
                    checkClientContext(waitContext)
                    match (waitContext.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                if (let Some(error) <- failure) { throw error }
                connectResult.getOrThrow()
            }
        } finally {
            registration.unregister()
        }
    }

    /** A connected stream no longer inherits the handshake operation budget. */
    func releaseHandshakeCancellation(): Unit {
        let registration = synchronized(mutex) {
            let value = streamCancellation
            streamCancellation = None<CancellationRegistration>
            value
        }
        if (let Some(value) <- registration) { value.unregister() }
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

    func failBeforeInitialHeaders(error: Exception): Unit {
        signalFailure(error)
        try { channel.close() } catch (_: Exception) {}
        try {
            let _ = registry.reset(
                streamId, Http2ErrorCode.Cancel,
                "HTTP/2 request failed before initial headers"
            )
        } catch (_: Exception) {}
        finish()
    }

    func connectionTerminated(error: Exception): Unit {
        signalFailure(error)
        match (synchronized(mutex) { duplexTransport }) {
            case Some(value) => value.peerTerminated(resetStream: true)
            case None => finish()
        }
    }

    public func completed(): Unit { finish() }
    public func abandoned(): Unit {
        try { let _ = reset.cancelLocal(streamId) } catch (_: Exception) {}
        finish()
    }

    public func streamReset(event: Http2StreamResetEvent): Unit {
        if (event.streamId.value != streamId.value) { return }
        signalFailure(Http2ProtocolException(
            event.code, Http2ErrorScope.Stream(event.streamId), event.reason
        ))
        let disposition = synchronized(mutex) { (duplexTransport, response.isSome()) }
        match (disposition[0]) {
            case Some(value) => value.peerTerminated(resetStream: true)
            case None => if (!disposition[1]) { finish() }
        }
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
        if (let Some(value) <- pushSource) { value.parentFinished() }
        try { onTerminated() } catch (_: Exception) {}
    }
    private func endRejectedConnectRequest(): Unit {
        let _ = writer.enqueue(Http2Frame(
            Http2FrameHeader(
                0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8),
                streamId, limits: http2Limits
            ),
            []
        ))
        registry.localEnd(streamId)
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

internal class Http2ClientBodyChannel <: HttpBodyStream & Http2DuplexInbound {
    private let streamId: Http2StreamId
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let defaultContext: OperationContext
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
        defaultContext = context
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
        enqueueClientUpdates(writer, if (immediateCredit > 0) {
            flow.consumeReceived(streamId, immediateCredit)
        } else { Array<Http2Frame>() })
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
        match (readSome(MutableByteSpan(destination), defaultContext)) {
            case ReadResult.Data(count) => count
            case ReadResult.EndOfStream => 0
        }
    }

    public func readSome(
        destination: MutableByteSpan,
        context: OperationContext
    ): ReadResult {
        if (destination.isEmpty()) { return ReadResult.Data(0) }
        submitClientUpdates(
            writer, flow.flushStalledConnectionReceiveCredit(), context
        )
        let registration = context.cancellation.register { => wake() }
        var updates = Array<Http2Frame>()
        try {
            let result = synchronized(mutex) {
                while (segments.isEmpty() && !eof && !closed && failure.isNone()) {
                    checkClientContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                checkClientContext(context)
                if (let Some(error) <- failure) { throw error }
                if (closed) { return ReadResult.EndOfStream }
                if (segments.isEmpty()) { return ReadResult.EndOfStream }
                let segment = segments[0]
                let count = min(destination.length, segment.remainingData)
                for (index in 0..count) {
                    destination.bytes[destination.offset + index] =
                        segment.data[segment.offset + index]
                }
                segment.offset += count
                let credit = if (segment.remainingData == 0) {
                    segment.remainingFlowBytes
                } else { count }
                segment.remainingFlowBytes -= credit
                if (segment.remainingData == 0) { let _ = segments.remove(at: 0) }
                if (credit > 0) { updates = flow.consumeReceived(streamId, credit) }
                ReadResult.Data(count)
            }
            submitClientUpdates(writer, updates, context)
            result
        } finally {
            registration.unregister()
        }
    }

    public func awaitEnd(context: OperationContext): Unit {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (!eof && !closed && failure.isNone()) {
                    checkClientContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                checkClientContext(context)
                if (let Some(error) <- failure) { throw error }
            }
        } finally {
            registration.unregister()
        }
    }

    public func discard(): Unit { close() }

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
        enqueueClientUpdates(writer, updates)
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

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
    private let pushConfig: ?Http2PushConfig
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let exchanges = ArrayList<Http2ClientExchange>()
    private var connection: ?Http2ClientConnection = None<Http2ClientConnection>
    private var registry: ?Http2StreamRegistry = None<Http2StreamRegistry>
    private var goAway: ?Http2GoAwayManager = None<Http2GoAwayManager>
    private var reset: ?Http2StreamResetManager = None<Http2StreamResetManager>
    private var health: ?Http2ConnectionHealth = None<Http2ConnectionHealth>
    private var pushCoordinator: ?Http2ClientPushCoordinator =
        None<Http2ClientPushCoordinator>

    init(
        machine: Http2ConnectionStateMachine,
        writer: Http2WriteScheduler,
        flow: Http2FlowController,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        pushConfig: ?Http2PushConfig
    ) {
        this.machine = machine
        this.writer = writer
        this.flow = flow
        this.limits = limits
        this.http2Limits = http2Limits
        this.pushConfig = pushConfig
        decoder = HpackDecoder(limits: http2Limits)
    }

    func attach(
        connection: Http2ClientConnection,
        registry: Http2StreamRegistry,
        goAway: Http2GoAwayManager,
        reset: Http2StreamResetManager,
        health: Http2ConnectionHealth,
        terminationRegistry: Http2ReaderTerminationRegistry
    ): Unit {
        synchronized(mutex) {
            this.connection = Some(connection)
            this.registry = Some(registry)
            this.goAway = Some(goAway)
            this.reset = Some(reset)
            this.health = Some(health)
            if (let Some(config) <- pushConfig) {
                pushCoordinator = Some(Http2ClientPushCoordinator(
                    config, machine, registry, flow, writer, reset,
                    terminationRegistry, limits, http2Limits
                ))
            }
        }
    }

    prop ownerCount: Int64 {
        get() {
            let local = synchronized(mutex) { exchanges.size }
            let pushes = match (synchronized(mutex) { pushCoordinator }) {
                case Some(value) => value.ownerCount
                case None => 0
            }
            local + pushes
        }
    }

    func newPushSource(
        parentStreamId: Http2StreamId,
        parent: HttpUrl
    ): ?Http2ClientPushSource {
        match (synchronized(mutex) { pushCoordinator }) {
            case Some(value) => Some(value.newSource(parentStreamId, parent))
            case None => None<Http2ClientPushSource>
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
                case Http2FrameType.Data => acceptData(frame)
                case Http2FrameType.PushPromise => ()
                case _ => ()
            }
            if (let Some(block) <- result.headerBlock) {
                let fields = decoder.decode(block.bytes)
                match (block.kind) {
                    case Http2HeaderBlockKind.Headers =>
                        acceptHeaders(block.streamId, fields, block.endStream)
                    case Http2HeaderBlockKind.PushPromise =>
                        let coordinator = match (synchronized(mutex) { pushCoordinator }) {
                            case Some(value) => value
                            case None => throw Http2ProtocolException(
                                Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                                "HTTP/2 server push is disabled by the client"
                            )
                        }
                        let parent = requireExchange(block.streamId)
                        let source = match (parent.pushAdmissionSource()) {
                            case Some(value) => value
                            case None => throw Http2ProtocolException(
                                Http2ErrorCode.RefusedStream, Http2ErrorScope.Stream(block.streamId),
                                "HTTP/2 parent does not accept promised responses"
                            )
                        }
                        coordinator.accept(source, block, fields)
                }
            }
        } catch (error: Http2ProtocolException) {
            match (error.scope) {
                case Http2ErrorScope.Stream(streamId) =>
                    try { let _ = reset.getOrThrow().cancelLocal(
                        streamId, code: error.code, reason: error.message
                    ) } catch (_: Exception) {}
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
        if (let Some(value) <- synchronized(mutex) { pushCoordinator }) {
            value.connectionTerminated(completion)
        }
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
    private func findExchange(streamId: Http2StreamId): ?Http2ClientExchange {
        synchronized(mutex) {
            for (exchange in exchanges) {
                if (exchange.streamId.value == streamId.value) { return Some(exchange) }
            }
            None<Http2ClientExchange>
        }
    }

    private func acceptData(frame: Http2Frame): Unit {
        if (let Some(value) <- findExchange(frame.header.streamId)) {
            value.acceptData(frame)
            return
        }
        if (let Some(coordinator) <- synchronized(mutex) { pushCoordinator }) {
            if (let Some(value) <- coordinator.exchange(frame.header.streamId)) {
                value.acceptData(frame)
                return
            }
        }
        throw inactiveClientStream(frame.header.streamId)
    }

    private func acceptHeaders(
        streamId: Http2StreamId,
        fields: Array<HpackHeaderField>,
        endStream: Bool
    ): Unit {
        if (let Some(value) <- findExchange(streamId)) {
            value.acceptHeaders(fields, endStream)
            return
        }
        if (let Some(coordinator) <- synchronized(mutex) { pushCoordinator }) {
            if (let Some(value) <- coordinator.exchange(streamId)) {
                value.acceptHeaders(fields, endStream)
                return
            }
        }
        throw inactiveClientStream(streamId)
    }

    private func inactiveClientStream(streamId: Http2StreamId): Http2ProtocolException {
        Http2ProtocolException(
            Http2ErrorCode.StreamClosed, Http2ErrorScope.Stream(streamId),
            "HTTP/2 frame referenced an inactive client stream"
        )
    }
}


private func decodeClientData(frame: Http2Frame, streamId: Http2StreamId): Array<Byte> {
    if (frame.header.streamId.value != streamId.value) {
        throw IllegalArgumentException("HTTP/2 DATA belongs to another client stream")
    }
    let payload = frame.payload
    if (!frame.header.flags.isPadded()) { return payload }
    if (payload.isEmpty()) { clientStreamError(streamId, "HTTP/2 padded DATA has no pad length") }
    let padding = Int64(payload[0])
    if (padding >= payload.size) { clientStreamError(streamId, "HTTP/2 DATA padding consumes its payload") }
    let count = payload.size - padding - 1
    let data = Array<Byte>(count, repeat: 0u8)
    for (index in 0..count) { data[index] = payload[index + 1] }
    data
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

private func clientPushCapacity(
    config: ?Http2PushConfig,
    limits: Http2Limits
): UInt32 {
    match (config) {
        case Some(value) => min(UInt32(value.maximumConcurrentPushes), limits.maxConcurrentStreams)
        case None => 0u32
    }
}

private func combinedClientStreamCapacity(local: UInt32, peer: UInt32): UInt32 {
    if (peer > UInt32.Max - local) {
        throw IllegalArgumentException("HTTP/2 combined client stream capacity overflows UInt32")
    }
    local + peer
}
private func enqueueClientUpdates(
    writer: Http2WriteScheduler,
    frames: Array<Http2Frame>
): Unit {
    for (frame in frames) { let _ = writer.enqueue(frame) }
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
