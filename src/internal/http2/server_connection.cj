package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

/** One production HTTP/2 server connection with one reader and one writer. */
public class Http2ServerConnection <: Http2InboundFrameHandler & Http2ServerControlSink & Resource {
    private let transport: DuplexTransport
    private let handler: Http2ServerHandler
    private let machine: Http2ConnectionStateMachine
    private let writer: Http2WriteScheduler
    private let flow: Http2FlowController
    private var reader: ?Http2ConnectionReader = None<Http2ConnectionReader>
    private var registry: ?Http2StreamRegistry = None<Http2StreamRegistry>
    private var reset: ?Http2StreamResetManager = None<Http2StreamResetManager>
    private let decoder: HpackDecoder
    private let encoder: HpackEncoder
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let mutex = Mutex()
    private let pushAdmissionMutex = Mutex()
    private let exchanges = ArrayList<Http2ServerExchange>()
    private let pushWorkers = ArrayList<Http2ServerPushWorker>()
    private let pushChanged = synchronized(mutex) { mutex.condition() }
    private var activePushes: Int64 = 0
    private var pendingPushes: Int64 = 0
    private var draining = false
    private var closed = false
    private var operationContext = OperationContext.background()
    internal prop pushesPerRequestLimit: UInt32 {
        get() { http2Limits.maxPushesPerRequest }
    }

    public init(
        transport: DuplexTransport,
        handler: Http2ServerHandler,
        limits!: HttpLimits = HttpLimits(),
        http2Limits!: Http2Limits = Http2Limits()
    ) {
        this.transport = transport
        this.handler = handler
        this.limits = limits
        this.http2Limits = http2Limits
        machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server, limits: http2Limits)
        writer = Http2WriteScheduler(transport, limits: http2Limits)
        flow = Http2FlowController(
            limits: http2Limits,
            maximumStreams: combinedServerStreamCapacity(http2Limits)
        )
        decoder = HpackDecoder(limits: http2Limits)
        encoder = HpackEncoder(limits: http2Limits)
        let createdReader = Http2ConnectionReader(
            transport, machine, this, limits: http2Limits,
            additionalStreamListeners: http2Limits.maxConcurrentPushes
        )
        reader = Some(createdReader)
        let createdRegistry = Http2StreamRegistry(
            Http2ConnectionRole.Server,
            limits: http2Limits,
            terminationRegistry: Some(createdReader.terminationRegistry)
        )
        registry = Some(createdRegistry)
        reset = Some(Http2StreamResetManager(
            createdRegistry, flow, writer, limits: http2Limits,
            additionalStreamListeners: http2Limits.maxConcurrentPushes
        ))
    }

    public func serve(context!: OperationContext = OperationContext.background()): Unit {
        operationContext = context
        try {
            let settings = machine.start(settings: initialHttp2Settings(
                Http2ConnectionRole.Server, http2Limits
            ))
            writeAll(transport, ByteSpan(settings), context: context)
            let _ = spawn { writer.run() }
            let _ = reader.getOrThrow().run(context: context)
        } finally {
            abort()
        }
    }

    /** Sends GOAWAY before closing and lets every already-admitted stream finish. */
    public func beginDrain(): Unit {
        let shouldStart = synchronized(mutex) {
            if (draining || closed) { false } else {
                draining = true
                pushChanged.notifyAll()
                true
            }
        }
        if (!shouldStart) { return }
        try { let _ = writer.enqueue(machine.beginDrain()) }
        catch (_: Exception) { abort(); return }
        let _ = spawn {
            let _ = registry.getOrThrow().waitUntilEmpty()
            writer.close()
            try {
                let _ = writer.waitUntilTerminal()
                let _ = writer.finishTransport()
            } catch (_: Exception) { writer.abort() }
        }
    }

    public func handle(frame: Http2Frame, result: Http2ConnectionReceiveResult): Unit {
        for (outbound in result.outbound) { let _ = writer.enqueue(outbound) }
        try {
            match (frame.header.frameType) {
                case Http2FrameType.Settings =>
                    if (!frame.header.flags.isAck()) {
                        flow.applyPeerSettings(Http2SettingsUpdate(
                            machine.peerSettings, 0, http2SettingsAck()
                        ))
                        registry.getOrThrow().updatePeerMaxConcurrentStreams(
                            machine.peerSettings.maxConcurrentStreams
                        )
                    }
                case Http2FrameType.WindowUpdate => flow.receiveWindowUpdate(frame)
                case Http2FrameType.RstStream =>
                    synchronized(pushAdmissionMutex) {
                        let _ = reset.getOrThrow().acceptPeer(frame)
                    }
                case Http2FrameType.Data => requireExchange(frame.header.streamId).acceptData(frame)
                case Http2FrameType.PushPromise =>
                    throw Http2ProtocolException(
                        Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                        "HTTP/2 client push promise is invalid on a server connection"
                    )
                case _ => ()
            }
            if (let Some(block) <- result.headerBlock) {
                match (block.kind) {
                    case Http2HeaderBlockKind.Headers => acceptHeaders(block)
                    case Http2HeaderBlockKind.PushPromise =>
                        throw Http2ProtocolException(
                            Http2ErrorCode.ProtocolError, Http2ErrorScope.Connection,
                            "HTTP/2 client push promise is invalid on a server connection"
                        )
                }
            }
        } catch (error: Http2ProtocolException) {
            match (error.scope) {
                case Http2ErrorScope.Stream(streamId) =>
                    try { let _ = cancelLocalStream(
                        streamId, error.code, error.message
                    ) }
                    catch (_: Exception) {}
                case Http2ErrorScope.Connection => throw error
            }
        }
    }

    public func readerTerminated(
        completion: Http2ConnectionCompletion,
        terminalGoAway: ?Http2Frame
    ): Unit {
        synchronized(mutex) {
            closed = true
            draining = true
            pushChanged.notifyAll()
        }
        if (let Some(frame) <- terminalGoAway) {
            try { let _ = writer.enqueue(frame) } catch (_: Exception) {}
        }
        flow.close()
        writer.close()
        terminatePushWorkers()
        terminateExchanges(completion)
    }

    public func submit(frames: Array<Http2Frame>): Unit {
        for (frame in frames) { let _ = writer.enqueue(frame) }
    }

    public func close(): Unit { beginDrain() }

    public func abort(): Unit {
        let won = synchronized(mutex) {
            if (closed) { false } else {
                closed = true
                pushChanged.notifyAll()
                true
            }
        }
        if (won) {
            flow.close()
            writer.abort(reason: AbortReason.ApplicationAbort)
            terminatePushWorkers()
            terminateExchanges(Http2ConnectionCompletion(
                Http2ErrorCode.Cancel, "HTTP/2 server connection aborted"
            ))
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func acceptHeaders(block: Http2HeaderBlock): Unit {
        let existing = findExchange(block.streamId)
        match (existing) {
            case Some(exchange) => exchange.acceptTrailers(decoder.decode(block.bytes), block.endStream)
            case None =>
                let _ = machine.openPeerStream(
                    registry.getOrThrow(), block.streamId, endStream: block.endStream
                )
                let decoded = decoder.decode(block.bytes)
                if (let Some(_) <- decodeHttp2ServerRequestHead(
                    decoded, block.streamId, limits: limits, http2Limits: http2Limits
                ).protocol) {
                    if (!machine.localSettings.enableConnectProtocol) {
                        throw Http2ProtocolException(
                            Http2ErrorCode.ProtocolError, Http2ErrorScope.Stream(block.streamId),
                            "HTTP/2 extended CONNECT was not negotiated"
                        )
                    }
                }
                let exchange = Http2ServerExchange.open(
                    block.streamId, decoded, block.endStream,
                    registry.getOrThrow(), flow, this, limits: limits, http2Limits: http2Limits,
                    streamAlreadyOpened: true,
                    pushSenderFactory: { head =>
                        if (let Some(scheme) <- head.scheme) {
                            if (head.protocol.isNone() && machine.peerSettings.enablePush) {
                                Some<Http2ServerPushSender>(
                                    Http2ServerPushSenderImpl(
                                        this, block.streamId,
                                        HttpUrl.parse("${scheme}://${head.authority}/")
                                    )
                                )
                            } else { None<Http2ServerPushSender> }
                        } else { None<Http2ServerPushSender> }
                    },
                    localCancellation: { =>
                        try {
                            let _ = cancelLocalStream(
                                block.streamId, Http2ErrorCode.Cancel,
                                "HTTP/2 server stream cancelled by public handle"
                            )
                        } catch (_: Exception) {}
                    },
                    onOwnerTerminated: { => removeExchange(block.streamId) }
                )
                machine.markPeerStreamProcessed(block.streamId)
                synchronized(mutex) { exchanges.add(exchange) }
                let registration = reset.getOrThrow().register(block.streamId, exchange)
                exchange.bindReset(registration)
                let response = exchange.start(handler, context: operationContext)
                let _ = spawn {
                    var transferred = false
                    try { transferred = sendResponse(exchange, response.get()) }
                    catch (error: Exception) {
                        try {
                            let _ = cancelLocalStream(
                                block.streamId, Http2ErrorCode.InternalError,
                                "HTTP/2 server handler failed: ${error.message}"
                            )
                        } catch (_: Exception) {}
                    } finally {
                        if (!transferred) { exchange.completeOwner() }
                    }
                }
        }
    }

    private func sendResponse(
        exchange: Http2ServerExchange,
        plan: Http2ServerResponsePlan
    ): Bool {
        var duplexStarted = false
        try {
            waitWrites(enqueueActiveServerHeaders(
                plan.streamId, plan.initialHeaders, plan.endStreamOnHeaders
            ))
            if (plan.endStreamOnHeaders) { exchange.finishLocal(); return false }
            if (let Some(duplexHandler) <- plan.duplexHandler) {
                let streamTransport = exchange.activateDuplex(writer, reset.getOrThrow())
                duplexStarted = true
                try { duplexHandler.serve(streamTransport, operationContext) }
                finally { streamTransport.close() }
                return true
            }
            let body = plan.openBody()
            try {
                while (true) {
                    let event = body.next()
                    match (event.kind) {
                        case Http2ServerBodyEventKind.Data =>
                            waitWrite(event.enqueueData(writer))
                        case Http2ServerBodyEventKind.EndData =>
                            waitWrite(enqueueActiveServerControl(Http2Frame(
                                Http2FrameHeader(
                                    0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8),
                                    plan.streamId, limits: http2Limits
                                ), []
                            )))
                            exchange.finishLocal()
                            return false
                        case Http2ServerBodyEventKind.Trailers =>
                            waitWrites(enqueueActiveServerHeaders(
                                plan.streamId, event.trailerFields, true
                            ))
                            exchange.finishLocal()
                            return false
                    }
                }
                throw IllegalStateException("unreachable HTTP/2 response body loop exit")
            } finally { body.close() }
        } catch (error: Exception) {
            if (!duplexStarted) {
                if (let Some(duplexHandler) <- plan.duplexHandler) {
                    try { duplexHandler.failed() } catch (_: Exception) {}
                }
            }
            throw error
        }
    }

    internal func push(
        parentStreamId: Http2StreamId,
        parentOrigin: HttpUrl,
        request: HttpRequest,
        handled: Http2ServerResponse,
        context: OperationContext,
        lifetime: ?Resource
    ): Unit {
        var slotOwned = false
        var promised: ?Http2StreamId = None<Http2StreamId>
        var worker: ?Http2ServerPushWorker = None<Http2ServerPushWorker>
        var promiseAdmitted = false
        try {
            if (request.method != HttpMethod("GET")) {
                throw IllegalArgumentException("HTTP/2 server push requires GET")
            }
            if (request.body.contentLength != Some(0)) {
                throw IllegalArgumentException("HTTP/2 server push request body must be known empty")
            }
            if (!sameServerPushOrigin(parentOrigin, request.url)) {
                throw IllegalArgumentException("HTTP/2 server push requires the parent canonical origin")
            }
            if (!machine.peerSettings.enablePush) {
                throw IllegalStateException("HTTP/2 peer disabled server push")
            }
            if (registry.getOrThrow().stream(parentStreamId).isNone()) {
                throw IllegalStateException("HTTP/2 push parent stream is no longer active")
            }
            let requestPlan = mapHttp2ClientRequest(
                request, limits: limits, http2Limits: http2Limits
            )
            if (!requestPlan.endStreamOnHeaders) {
                throw IllegalArgumentException("HTTP/2 server push request must end on promised headers")
            }

            acquirePushSlot(context)
            slotOwned = true
            // Reserve the promised id first, then perform response mapping
            // without excluding the reader: header-only mapping may close an
            // application body.
            synchronized(pushAdmissionMutex) {
                if (registry.getOrThrow().stream(parentStreamId).isNone()) {
                    throw IllegalStateException("HTTP/2 push parent stream is no longer active")
                }
                let stream = machine.reserveLocalStream(registry.getOrThrow())
                promised = Some(stream.id)
            }
            let streamId = promised.getOrThrow()
            flow.openStream(streamId)
            let responsePlan = mapHttp2ServerResponse(
                streamId, request.method, handled, flow,
                limits: limits, http2Limits: http2Limits
            )
            let ownedWorker = Http2ServerPushWorker(this, responsePlan, lifetime)
            var promiseTickets = Array<Http2WriteTicket>()
            // The final parent/promised-stream check and promise admission are
            // atomic with peer RST_STREAM handling.
            synchronized(pushAdmissionMutex) {
                if (registry.getOrThrow().stream(parentStreamId).isNone() ||
                    registry.getOrThrow().stream(streamId).isNone()) {
                    throw IllegalStateException("HTTP/2 push parent or promised stream is no longer active")
                }
                adoptPushWorker(ownedWorker)
                worker = Some(ownedWorker)
                slotOwned = false
                ownedWorker.bindReset(reset.getOrThrow().register(streamId, ownedWorker))
                promiseTickets = encodeAndEnqueuePushPromise(
                    parentStreamId, streamId, requestPlan.initialHeaders
                )
                promiseAdmitted = true
            }
            waitWrites(promiseTickets, context: context)
            ownedWorker.bindTask(spawn { ownedWorker.run(context) })
        } catch (error: Exception) {
            if (let Some(ownedWorker) <- worker) {
                if (promiseAdmitted) {
                    failPushWorker(ownedWorker, error)
                } else if (let Some(streamId) <- promised) {
                    releaseUnpromisedStream(streamId, error)
                }
                ownedWorker.complete()
            } else {
                try { handled.response.close() } catch (_: Exception) {}
                if (let Some(value) <- lifetime) {
                    try { value.close() } catch (_: Exception) {}
                }
                if (let Some(streamId) <- promised) {
                    releaseUnpromisedStream(streamId, error)
                }
            }
            throw error
        } finally {
            if (slotOwned) { releasePushSlot() }
        }
    }

    internal func sendPushedResponse(
        plan: Http2ServerResponsePlan,
        context: OperationContext
    ): Unit {
        var initialTickets = Array<Http2WriteTicket>()
        synchronized(pushAdmissionMutex) {
            checkServerPushContext(context)
            if (registry.getOrThrow().stream(plan.streamId).isNone()) {
                throw IllegalStateException("HTTP/2 pushed stream is no longer active")
            }
            initialTickets = encodeAndEnqueueServerHeaders(
                plan.streamId, plan.initialHeaders, plan.endStreamOnHeaders
            )
        }
        waitWrites(initialTickets, context: context)
        registry.getOrThrow().openReservedLocal(
            plan.streamId, endStream: plan.endStreamOnHeaders
        )
        if (plan.endStreamOnHeaders) {
            let _ = flow.closeStream(plan.streamId)
            return
        }
        let body = plan.openBody()
        try {
            while (true) {
                let event = body.next(context: context)
                match (event.kind) {
                    case Http2ServerBodyEventKind.Data =>
                        waitWrite(event.enqueueData(writer), context: context)
                    case Http2ServerBodyEventKind.EndData =>
                        var terminalTicket: ?Http2WriteTicket = None<Http2WriteTicket>
                        synchronized(pushAdmissionMutex) {
                            checkServerPushContext(context)
                            if (registry.getOrThrow().stream(plan.streamId).isNone()) {
                                throw IllegalStateException("HTTP/2 pushed stream is no longer active")
                            }
                            terminalTicket = Some(writer.enqueue(Http2Frame(
                                Http2FrameHeader(
                                    0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8),
                                    plan.streamId, limits: http2Limits
                                ), []
                            )))
                        }
                        waitWrite(terminalTicket.getOrThrow(), context: context)
                        registry.getOrThrow().localEnd(plan.streamId)
                        let _ = flow.closeStream(plan.streamId)
                        return
                    case Http2ServerBodyEventKind.Trailers =>
                        var trailerTickets = Array<Http2WriteTicket>()
                        synchronized(pushAdmissionMutex) {
                            checkServerPushContext(context)
                            if (registry.getOrThrow().stream(plan.streamId).isNone()) {
                                throw IllegalStateException("HTTP/2 pushed stream is no longer active")
                            }
                            trailerTickets = encodeAndEnqueueServerHeaders(
                                plan.streamId, event.trailerFields, true
                            )
                        }
                        waitWrites(trailerTickets, context: context)
                        registry.getOrThrow().localEnd(plan.streamId)
                        let _ = flow.closeStream(plan.streamId)
                        return
                }
            }
        } finally { body.close() }
    }

    private func enqueueActiveServerHeaders(
        streamId: Http2StreamId,
        fields: Array<HpackFieldEncoding>,
        endStream: Bool
    ): Array<Http2WriteTicket> {
        synchronized(pushAdmissionMutex) {
            if (registry.getOrThrow().stream(streamId).isNone()) {
                throw IllegalStateException("HTTP/2 response stream is no longer active")
            }
            encodeAndEnqueueServerHeaders(streamId, fields, endStream)
        }
    }

    private func encodeAndEnqueueServerHeaders(
        streamId: Http2StreamId,
        fields: Array<HpackFieldEncoding>,
        endStream: Bool
    ): Array<Http2WriteTicket> {
        try {
            synchronized(mutex) {
                let block = encoder.encode(fields)
                writer.enqueueControlBatch(fragmentServerHeaders(
                    streamId, block, endStream,
                    machine.peerSettings.maxFrameSize, http2Limits
                ))
            }
        } catch (error: Exception) {
            // Encoder state changes before admission; only connection teardown
            // can keep the peer's dynamic table from diverging on failure.
            abort()
            throw error
        }
    }

    private func encodeAndEnqueuePushPromise(
        parentStreamId: Http2StreamId,
        promisedStreamId: Http2StreamId,
        fields: Array<HpackFieldEncoding>
    ): Array<Http2WriteTicket> {
        try {
            synchronized(mutex) {
                let block = encoder.encode(fields)
                writer.enqueueControlBatch(fragmentServerPushPromise(
                    parentStreamId, promisedStreamId, block,
                    machine.peerSettings.maxFrameSize, http2Limits
                ))
            }
        } catch (error: Exception) {
            abort()
            throw error
        }
    }

    private func enqueueActiveServerControl(frame: Http2Frame): Http2WriteTicket {
        synchronized(pushAdmissionMutex) {
            if (registry.getOrThrow().stream(frame.header.streamId).isNone()) {
                throw IllegalStateException("HTTP/2 response stream is no longer active")
            }
            writer.enqueue(frame)
        }
    }

    private func cancelLocalStream(
        streamId: Http2StreamId,
        code: Http2ErrorCode,
        reason: String
    ): ?Http2WriteTicket {
        synchronized(pushAdmissionMutex) {
            reset.getOrThrow().cancelLocal(streamId, code: code, reason: reason)
        }
    }

    internal func finishPushWorker(streamId: Http2StreamId): Unit {
        synchronized(mutex) {
            for (index in 0..pushWorkers.size) {
                if (pushWorkers[index].streamId.value == streamId.value) {
                    let _ = pushWorkers.remove(at: index)
                    activePushes--
                    pushChanged.notifyAll()
                    return
                }
            }
        }
    }

    internal func failPushWorker(worker: Http2ServerPushWorker, error: Exception): Unit {
        try {
            let _ = cancelLocalStream(
                worker.streamId, Http2ErrorCode.InternalError,
                "HTTP/2 server push failed: ${error.message}"
            )
        } catch (_: Exception) {
            forceReleasePushStream(worker.streamId, error)
        }
    }

    private func forceReleasePushStream(streamId: Http2StreamId, error: Exception): Unit {
        releaseUnpromisedStream(streamId, error)
        // Once promise or response writes may exist, inability to enqueue the
        // terminal reset cannot leave those frames live on a reusable connection.
        abort()
    }

    private func releaseUnpromisedStream(streamId: Http2StreamId, error: Exception): Unit {
        try {
            let _ = registry.getOrThrow().reset(
                streamId, Http2ErrorCode.InternalError,
                "HTTP/2 server push failed: ${error.message}"
            )
        } catch (_: Exception) {}
        let _ = writer.cancelStream(streamId)
        let _ = flow.closeStream(streamId)
    }

    private func adoptPushWorker(worker: Http2ServerPushWorker): Unit {
        synchronized(mutex) {
            if (closed || draining) {
                throw IllegalStateException("HTTP/2 connection no longer accepts server push")
            }
            pushWorkers.add(worker)
        }
    }

    private func terminatePushWorkers(): Unit {
        let current = synchronized(mutex) { pushWorkers.toArray() }
        for (worker in current) { worker.stop() }
    }

    private func acquirePushSlot(context: OperationContext): Unit {
        let registration = context.cancellation.register { =>
            synchronized(mutex) { pushChanged.notifyAll() }
        }
        var queued = false
        try {
            synchronized(mutex) {
                while (activePushes >= Int64(http2Limits.maxConcurrentPushes)) {
                    checkServerPushContext(context)
                    if (!queued) {
                        if (pendingPushes >= Int64(http2Limits.maxPendingPushes)) {
                            throw Http2StreamLimitException("HTTP/2 pending server push limit reached")
                        }
                        pendingPushes++
                        queued = true
                    }
                    if (closed || draining) {
                        throw IllegalStateException("HTTP/2 connection no longer accepts server push")
                    }
                    match (context.deadline) {
                        case Some(deadline) => pushChanged.wait(timeout: deadline.remaining())
                        case None => pushChanged.wait()
                    }
                }
                checkServerPushContext(context)
                if (closed || draining) {
                    throw IllegalStateException("HTTP/2 connection no longer accepts server push")
                }
                if (queued) { pendingPushes--; queued = false }
                activePushes++
            }
        } finally {
            if (queued) { synchronized(mutex) { pendingPushes--; pushChanged.notifyAll() } }
            registration.unregister()
        }
    }

    private func releasePushSlot(): Unit {
        synchronized(mutex) {
            activePushes--
            pushChanged.notifyAll()
        }
    }

    private func findExchange(streamId: Http2StreamId): ?Http2ServerExchange {
        synchronized(mutex) {
            for (exchange in exchanges) {
                if (exchange.streamId.value == streamId.value) { return Some(exchange) }
            }
            None<Http2ServerExchange>
        }
    }

    private func requireExchange(streamId: Http2StreamId): Http2ServerExchange {
        match (findExchange(streamId)) {
            case Some(value) => value
            case None => throw Http2ProtocolException(
                Http2ErrorCode.StreamClosed, Http2ErrorScope.Stream(streamId),
                "HTTP/2 frame targets an inactive server stream"
            )
        }
    }


    private func terminateExchanges(completion: Http2ConnectionCompletion): Unit {
        let current = synchronized(mutex) { exchanges.toArray() }
        for (exchange in current) { exchange.connectionTerminated(completion) }
    }

    private func removeExchange(streamId: Http2StreamId): Unit {
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
/** Bounded owner for one admitted promised response until completion or teardown. */
internal class Http2ServerPushWorker <: Http2StreamResetListener {
    let streamId: Http2StreamId
    private let connection: Http2ServerConnection
    private let plan: Http2ServerResponsePlan
    private let lifetime: ?Resource
    private let mutex = Mutex()
    private var resetRegistration: ?Http2StreamResetRegistration =
        None<Http2StreamResetRegistration>
    private var task: ?Future<Unit> = None<Future<Unit>>
    private let cancellation = CancellationSource()
    private var terminal = false

    init(
        connection: Http2ServerConnection,
        plan: Http2ServerResponsePlan,
        lifetime: ?Resource
    ) {
        this.connection = connection
        this.plan = plan
        this.lifetime = lifetime
        streamId = plan.streamId
    }

    func bindReset(registration: Http2StreamResetRegistration): Unit {
        let discard = synchronized(mutex) {
            if (terminal) { true } else {
                resetRegistration = Some(registration)
                false
            }
        }
        if (discard) { registration.unregister() }
    }
    func bindTask(value: Future<Unit>): Unit {
        let cancel = synchronized(mutex) {
            if (terminal) { true } else {
                task = Some(value)
                false
            }
        }
        if (cancel) { value.cancel() }
    }


    func run(context: OperationContext): Unit {
        if (synchronized(mutex) { terminal }) { return }
        let registration = context.cancellation.register { => cancellation.cancel() }
        try {
            connection.sendPushedResponse(
                plan, context.withCancellation(cancellation.token)
            )
        } catch (error: Exception) {
            connection.failPushWorker(this, error)
        } finally {
            registration.unregister()
            completeFromWorker()
        }
    }

    public func streamReset(event: Http2StreamResetEvent): Unit {
        if (event.streamId.value == streamId.value) { stop() }
    }

    func stop(): Unit {
        cancellation.cancel()
        if (let Some(value) <- synchronized(mutex) { task }) { value.cancel() }
    }

    func complete(): Unit { completeOwned(true) }

    private func completeFromWorker(): Unit { completeOwned(false) }

    private func completeOwned(cancelTask: Bool): Unit {
        let (registration, workerTask) = synchronized(mutex) {
            if (terminal) { return }
            terminal = true
            let retainedRegistration = resetRegistration
            resetRegistration = None<Http2StreamResetRegistration>
            let retainedTask = task
            task = None<Future<Unit>>
            (retainedRegistration, retainedTask)
        }
        if (let Some(value) <- registration) { value.unregister() }
        if (cancelTask) {
            if (let Some(value) <- workerTask) { value.cancel() }
        }
        try { plan.close() } catch (_: Exception) {}
        if (let Some(value) <- lifetime) {
            try { value.close() } catch (_: Exception) {}
        }
        connection.finishPushWorker(streamId)
    }
}

private class Http2ServerPushSenderImpl <: Http2ServerPushSender {
    private let connection: Http2ServerConnection
    private let parentStreamId: Http2StreamId
    private let parentOrigin: HttpUrl
    private let mutex = Mutex()
    private var accepted: Int64 = 0

    init(
        connection: Http2ServerConnection,
        parentStreamId: Http2StreamId,
        parentOrigin: HttpUrl
    ) {
        this.connection = connection
        this.parentStreamId = parentStreamId
        this.parentOrigin = parentOrigin
    }

    public func push(
        request: HttpRequest,
        response: Http2ServerResponse,
        context!: OperationContext = OperationContext.background(),
        lifetime!: ?Resource = None<Resource>
    ): Unit {
        var counted = false
        try {
            synchronized(mutex) {
                if (accepted >= Int64(connection.pushesPerRequestLimit)) {
                    throw Http2StreamLimitException("HTTP/2 per-request server push limit reached")
                }
                accepted++
                counted = true
            }
            connection.push(parentStreamId, parentOrigin, request, response, context, lifetime)
        } catch (error: Exception) {
            if (counted) { synchronized(mutex) { accepted-- } }
            try { response.response.close() } catch (_: Exception) {}
            if (let Some(value) <- lifetime) {
                try { value.close() } catch (_: Exception) {}
            }
            throw error
        }
    }
}
private func fragmentServerPushPromise(
    parentStreamId: Http2StreamId,
    promisedStreamId: Http2StreamId,
    block: Array<Byte>,
    peerMaxFrameSize: UInt32,
    limits: Http2Limits
): Array<Http2Frame> {
    let maximum = Int64(min(peerMaxFrameSize, limits.maxFrameSize))
    let frames = ArrayList<Http2Frame>()
    var offset: Int64 = 0
    var first = true
    while (first || offset < block.size) {
        let prefix = if (first) { 4 } else { 0 }
        let count = min(maximum - prefix, block.size - offset)
        let payload = Array<Byte>(prefix + count, repeat: 0u8)
        if (first) { writeServerStreamId(payload, promisedStreamId.value) }
        for (index in 0..count) { payload[prefix + index] = block[offset + index] }
        offset += count
        let last = offset == block.size
        frames.add(Http2Frame(
            Http2FrameHeader(
                UInt32(payload.size),
                if (first) { Http2FrameType.PushPromise } else { Http2FrameType.Continuation },
                Http2Flags(raw: if (last) { 0x04u8 } else { 0u8 }),
                parentStreamId, limits: limits
            ), payload
        ))
        first = false
    }
    frames.toArray()
}

private func writeServerStreamId(output: Array<Byte>, value: UInt32): Unit {
    output[0] = UInt8((value >> 24) & 0x7fu32)
    output[1] = UInt8((value >> 16) & 0xffu32)
    output[2] = UInt8((value >> 8) & 0xffu32)
    output[3] = UInt8(value & 0xffu32)
}

private func combinedServerStreamCapacity(limits: Http2Limits): UInt32 {
    if (limits.maxConcurrentPushes > UInt32.Max - limits.maxConcurrentStreams) {
        throw IllegalArgumentException("HTTP/2 combined server stream capacity overflows UInt32")
    }
    limits.maxConcurrentStreams + limits.maxConcurrentPushes
}

private func checkServerPushContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 server push cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut,
            "HTTP/2 server push deadline exceeded", retryability: Retryability.Temporary
        )
    }
}
private func sameServerPushOrigin(parent: HttpUrl, promised: HttpUrl): Bool {
    parent.scheme == promised.scheme &&
        parent.host.toAsciiLower() == promised.host.toAsciiLower() &&
        parent.port == promised.port
}

private func fragmentServerHeaders(
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
            ), payload
        ))
        first = false
    }
    frames.toArray()
}

private func waitWrites(
    tickets: Array<Http2WriteTicket>,
    context!: OperationContext = OperationContext.background()
): Unit {
    for (ticket in tickets) { waitWrite(ticket, context: context) }
}

private func waitWrite(
    ticket: Http2WriteTicket,
    context!: OperationContext = OperationContext.background()
): Unit {
    match (ticket.wait(context: context)) {
        case Http2WriteState.Written => ()
        case Http2WriteState.Cancelled => throw IllegalStateException("HTTP/2 server write was cancelled")
        case Http2WriteState.Failed => throw IllegalStateException("HTTP/2 server write failed: ${ticket.failure}")
        case _ => throw IllegalStateException("HTTP/2 server write did not complete")
    }
}
