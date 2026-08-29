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
    private let exchanges = ArrayList<Http2ServerExchange>()
    private var draining = false
    private var closed = false

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
        flow = Http2FlowController(limits: http2Limits)
        decoder = HpackDecoder(limits: http2Limits)
        encoder = HpackEncoder(limits: http2Limits)
        let createdReader = Http2ConnectionReader(transport, machine, this, limits: http2Limits)
        reader = Some(createdReader)
        let createdRegistry = Http2StreamRegistry(
            Http2ConnectionRole.Server,
            limits: http2Limits,
            terminationRegistry: Some(createdReader.terminationRegistry)
        )
        registry = Some(createdRegistry)
        reset = Some(Http2StreamResetManager(createdRegistry, flow, writer, limits: http2Limits))
    }

    public func serve(context!: OperationContext = OperationContext.background()): Unit {
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
            if (draining || closed) { false } else { draining = true; true }
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
                    }
                case Http2FrameType.WindowUpdate => flow.receiveWindowUpdate(frame)
                case Http2FrameType.RstStream => let _ = reset.getOrThrow().acceptPeer(frame)
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
                    try { let _ = reset.getOrThrow().cancelLocal(
                        streamId, code: error.code, reason: error.message
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
        let _ = completion
        if (let Some(frame) <- terminalGoAway) {
            try { let _ = writer.enqueue(frame) } catch (_: Exception) {}
        }
        flow.close()
        writer.close()
    }

    public func submit(frames: Array<Http2Frame>): Unit {
        for (frame in frames) { let _ = writer.enqueue(frame) }
    }

    public func close(): Unit { beginDrain() }

    public func abort(): Unit {
        let won = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (won) {
            flow.close()
            writer.abort(reason: AbortReason.ApplicationAbort)
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
                let exchange = Http2ServerExchange.open(
                    block.streamId, decoder.decode(block.bytes), block.endStream,
                    registry.getOrThrow(), flow, this, limits: limits, http2Limits: http2Limits,
                    streamAlreadyOpened: true,
                    localCancellation: { =>
                        try {
                            let _ = reset.getOrThrow().cancelLocal(
                                block.streamId,
                                code: Http2ErrorCode.Cancel,
                                reason: "HTTP/2 server stream cancelled by public handle"
                            )
                        } catch (_: Exception) {}
                    }
                )
                machine.markPeerStreamProcessed(block.streamId)
                synchronized(mutex) { exchanges.add(exchange) }
                let registration = reset.getOrThrow().register(block.streamId, exchange)
                let response = exchange.start(handler)
                let _ = spawn {
                    try { sendResponse(exchange, response.get()) }
                    catch (error: Exception) {
                        try {
                            let _ = reset.getOrThrow().cancelLocal(
                                block.streamId,
                                code: Http2ErrorCode.InternalError,
                                reason: "HTTP/2 server handler failed: ${error.message}"
                            )
                        } catch (_: Exception) {}
                    } finally {
                        registration.unregister()
                        removeExchange(block.streamId)
                    }
                }
        }
    }

    private func sendResponse(
        exchange: Http2ServerExchange,
        plan: Http2ServerResponsePlan
    ): Unit {
        let initial = synchronized(mutex) { encoder.encode(plan.initialHeaders) }
        waitWrites(writer.enqueueControlBatch(fragmentServerHeaders(
            plan.streamId, initial, plan.endStreamOnHeaders,
            machine.peerSettings.maxFrameSize, http2Limits
        )))
        if (plan.endStreamOnHeaders) { exchange.finishLocal(); return }
        let body = plan.openBody()
        try {
            while (true) {
                let event = body.next()
                match (event.kind) {
                    case Http2ServerBodyEventKind.Data =>
                        waitWrite(event.enqueueData(writer))
                    case Http2ServerBodyEventKind.EndData =>
                        waitWrite(writer.enqueue(Http2Frame(
                            Http2FrameHeader(
                                0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8),
                                plan.streamId, limits: http2Limits
                            ), []
                        )))
                        exchange.finishLocal()
                        return
                    case Http2ServerBodyEventKind.Trailers =>
                        let trailerBlock = synchronized(mutex) { encoder.encode(event.trailerFields) }
                        waitWrites(writer.enqueueControlBatch(fragmentServerHeaders(
                            plan.streamId, trailerBlock, true,
                            machine.peerSettings.maxFrameSize, http2Limits
                        )))
                        exchange.finishLocal()
                        return
                }
            }
        } finally { body.close() }
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

private func waitWrites(tickets: Array<Http2WriteTicket>): Unit {
    for (ticket in tickets) { waitWrite(ticket) }
}

private func waitWrite(ticket: Http2WriteTicket): Unit {
    match (ticket.wait()) {
        case Http2WriteState.Written => ()
        case Http2WriteState.Cancelled => throw IllegalStateException("HTTP/2 server write was cancelled")
        case Http2WriteState.Failed => throw IllegalStateException("HTTP/2 server write failed: ${ticket.failure}")
        case _ => throw IllegalStateException("HTTP/2 server write did not complete")
    }
}
