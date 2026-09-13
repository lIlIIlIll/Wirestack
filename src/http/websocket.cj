package wirestack.http

import std.sync.*
import wirestack as api
import wirestack.internal.tls_engine.{secureWebSocketRandom, webSocketBase64, webSocketSha1Base64}

private const WEBSOCKET_ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
private const WEBSOCKET_CLIENT_KEY_BYTES: Int64 = 16
private const WEBSOCKET_MASK_BYTES: Int64 = 4
private const WEBSOCKET_CONTROL_BYTES: Int64 = 125

/** The endpoint role, which determines the mandatory RFC 6455 masking direction. */
public enum WebSocketRole {
    /** Client endpoint; outbound frames are masked and inbound frames must be unmasked. */
    | Client
    /** Server endpoint; outbound frames are unmasked and inbound frames must be masked. */
    | Server
}

/** RFC 6455 opcodes supported without extensions. */
public enum WebSocketOpcode {
    /** Continues the current fragmented text or binary message. */
    | Continuation
    /** Starts a UTF-8 text message. */
    | Text
    /** Starts a binary message. */
    | Binary
    /** Performs the closing handshake with an empty or validated status-and-reason payload. */
    | Close
    /** Requests a Pong with the same payload. */
    | Ping
    /** Carries a response to a Ping. */
    | Pong
}

/** Stable WebSocket framing, ownership and transport failure categories. */
public enum WebSocketErrorCode {
    /** A locally supplied frame exceeds the configured frame bound or violates a role-specific close rule. */
    | InvalidFrame
    /** Framing, masking, sequencing, length encoding, or another protocol rule is invalid. */
    | ProtocolViolation
    /** A frame or complete data message exceeds the configured byte bound. */
    | MessageTooLarge
    /** Text data or a close reason is not valid UTF-8. */
    | InvalidPayload
    /** The connection is terminal or cannot accept the requested frame after a close was sent. */
    | Closed
    /** Cancellation was requested or the absolute operation deadline expired. */
    | ContextStopped
    /** Transport I/O failed, ended without a close frame, or reported invalid progress. */
    | TransportFailure
    /** Secure random generation or handshake digest encoding failed. */
    | CryptoFailure
}

/** A structured WebSocket failure. closeCode is the RFC close status when one applies. */
public class WebSocketException <: Exception {
    /** Stable failure category for programmatic handling. */
    public let code: WebSocketErrorCode
    /** Optional RFC close status associated with the failure. */
    public let closeCode: ?UInt16
    /** Underlying crypto, transport, or context failure, when one was caught. */
    public let cause: ?Exception

    /**
     * Creates a structured failure without modifying the supplied cause.
     * @param code Stable failure category.
     * @param message Human-readable failure detail.
     * @param closeCode RFC close status associated with this failure, when one applies.
     * @param cause Underlying exception, when this failure wraps another operation.
     */
    public init(
        code: WebSocketErrorCode,
        message: String,
        closeCode!: ?UInt16 = None<UInt16>,
        cause!: ?Exception = None<Exception>
    ) {
        super(message)
        this.code = code
        this.closeCode = closeCode
        this.cause = cause
    }

    /** Returns the stable class name used by exception diagnostics. */
    protected override func getClassName(): String { "WebSocketException" }
}

/** Explicit frame, message, staging and graceful-close bounds. */
public class WebSocketLimits {
    /** Maximum payload bytes in one frame, from zero through 1 GiB. */
    public let maximumFrameBytes: Int64
    /** Maximum data-message bytes across all fragments, from maximumFrameBytes through 1 GiB. */
    public let maximumMessageBytes: Int64
    /** Temporary outbound client-masking buffer bytes, from 1 through 1 MiB. */
    public let ioBufferBytes: Int64
    /** Maximum automatic control-response and graceful-close duration, greater than zero and at most 60 seconds. */
    public let closeTimeout: Duration

    /**
     * Creates validated frame, message, masking-buffer, and graceful-close bounds.
     * Control frames also obey the configured frame limit and a hard 125-byte payload limit.
     * @param maximumFrameBytes Maximum payload bytes retained or sent for one frame.
     * @param maximumMessageBytes Maximum combined data payload across a fragmented message; control payloads are excluded.
     * @param ioBufferBytes Maximum temporary chunk used while masking an outbound client frame.
     * @param closeTimeout Maximum automatic Pong or close-handshake budget; it only shortens an operation context.
     */
    public init(
        maximumFrameBytes!: Int64 = 1024 * 1024,
        maximumMessageBytes!: Int64 = 16 * 1024 * 1024,
        ioBufferBytes!: Int64 = 16 * 1024,
        closeTimeout!: Duration = 5 * Duration.second
    ) {
        if (maximumFrameBytes < 0 || maximumFrameBytes > 1024 * 1024 * 1024 ||
            maximumMessageBytes < maximumFrameBytes || maximumMessageBytes > 1024 * 1024 * 1024 ||
            ioBufferBytes <= 0 || ioBufferBytes > 1024 * 1024 ||
            closeTimeout <= Duration.Zero || closeTimeout > 60 * Duration.second) {
            throw IllegalArgumentException("WebSocket limits are invalid")
        }
        this.maximumFrameBytes = maximumFrameBytes
        this.maximumMessageBytes = maximumMessageBytes
        this.ioBufferBytes = ioBufferBytes
        this.closeTimeout = closeTimeout
    }
}

/** One owned, immutable WebSocket frame. payload returns a defensive copy. */
public class WebSocketFrame {
    /** Opcode carried by this frame. */
    public let opcode: WebSocketOpcode
    /** Whether this frame completes its message or control operation. */
    public let finalFragment: Bool
    private let ownedPayload: Array<Byte>

    /** Returns a new copy of the frame payload. */
    public prop payload: Array<Byte> { get() { ownedPayload.clone() } }
    internal prop wirePayload: Array<Byte> { get() { ownedPayload } }

    /**
     * Creates an immutable frame by copying payload.
     * Control frames must be final and contain at most 125 bytes. Close payloads must contain a valid
     * status and no more than 123 UTF-8 reason bytes. Data-frame bounds are checked when a connection sends it.
     * @param opcode Frame opcode.
     * @param payload Payload bytes to copy.
     * @param finalFragment Whether this frame completes its message.
     */
    public init(
        opcode: WebSocketOpcode,
        payload!: Array<Byte> = [],
        finalFragment!: Bool = true
    ) {
        validateLocalWebSocketFrame(opcode, payload, finalFragment)
        this.opcode = opcode
        this.finalFragment = finalFragment
        ownedPayload = payload.clone()
    }

    private init(opcode: WebSocketOpcode, payload: Array<Byte>, finalFragment: Bool, owned: Bool) {
        let _ = owned
        this.opcode = opcode
        this.finalFragment = finalFragment
        ownedPayload = payload
    }

    internal static func fromWire(
        opcode: WebSocketOpcode,
        payload: Array<Byte>,
        finalFragment: Bool
    ): WebSocketFrame {
        WebSocketFrame(opcode, payload, finalFragment, true)
    }
}

/** A completed handshake transfers either a concrete session or an owned rejection response. */
public enum WebSocketConnectResult {
    /** Successful handshake and caller-owned uncompressed session. */
    | Connected(WebSocketConnection)
    /** Rejected handshake and caller-owned response, including its body. */
    | Rejected(HttpResponse)
}

/**
 * Bounded, uncompressed RFC 6455 framing over a provider-neutral DuplexTransport.
 * The connection owns its transport. Extension bits are rejected because no extensions are negotiated.
 * Exactly one reader and one writer operate at a time. Control responses share
 * the same bounded writer gate and never splice bytes into a data frame.
 */
public class WebSocketConnection <: Resource {
    /** Endpoint role that controls outbound and inbound masking requirements. */
    public let role: WebSocketRole
    /** Server-selected handshake subprotocol, or None when none was selected. */
    public let subProtocol: ?String
    /** Frame, complete-message, masking-buffer, and close bounds for this session. */
    public let limits: WebSocketLimits

    private let transport: api.DuplexTransport
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let readProgress = WebSocketIoProgress()
    private let writeProgress = WebSocketIoProgress()
    private var readerActive = false
    private var writerActive = false
    private var terminal = false
    private var closeSent = false
    private var closeReceived = false

    private var inboundFragment: ?WebSocketOpcode = None<WebSocketOpcode>
    private var inboundMessageBytes: Int64 = 0
    private let inboundUtf8 = WebSocketUtf8Validator()
    private var outboundFragment: ?WebSocketOpcode = None<WebSocketOpcode>
    private var outboundMessageBytes: Int64 = 0
    private let outboundUtf8 = WebSocketUtf8Validator()

    /** Handshake owners call this only after transferring exclusive transport ownership. */
    internal init(
        transport: api.DuplexTransport,
        role: WebSocketRole,
        subProtocol!: ?String = None<String>,
        limits!: WebSocketLimits = WebSocketLimits()
    ) {
        if (let Some(value) <- subProtocol) {
            validateWebSocketSubProtocol(value)
        }
        this.transport = transport
        this.role = role
        this.subProtocol = subProtocol
        this.limits = limits
    }

    /**
     * Sends one frame under the caller's unchanged absolute operation budget.
     * Client-role connections mask the frame; server-role connections do not. A failure after transport
     * I/O starts aborts the connection, while validation and context failures before I/O leave it usable.
     * @param frame Immutable frame to validate against this connection's frame and message bounds.
     * @param context Cancellation and absolute deadline for writer admission and transport I/O.
     */
    public func send(
        frame: WebSocketFrame,
        context!: OperationContext = OperationContext.background()
    ): Unit {
        checkWebSocketContext(context)
        acquireWriter(context)
        let outboundUtf8State = outboundUtf8.snapshot()
        let attemptedIo = writeProgress
        attemptedIo.started = false
        try {
            requireWritable(frame.opcode)
            validateOutboundProgression(frame)
            writeWireFrame(frame.opcode, frame.finalFragment, frame.wirePayload, context, attemptedIo)
            commitOutboundProgression(frame)
            if (isCloseOpcode(frame.opcode)) {
                synchronized(mutex) {
                    closeSent = true
                    changed.notifyAll()
                }
            }
        } catch (error: WebSocketException) {
            if (!attemptedIo.started) { outboundUtf8.restore(outboundUtf8State) }
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw error
        } catch (error: Exception) {
            if (!attemptedIo.started) { outboundUtf8.restore(outboundUtf8State) }
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw wrapWebSocketOperationFailure(error, context)
        } finally {
            releaseWriter()
        }
    }

    /**
     * Receives one complete frame while retaining only its bounded payload.
     * Ping frames trigger a matching Pong before return. Close frames trigger a bounded reply and transport close.
     * @param context Cancellation and absolute deadline for reader admission, transport I/O, and automatic replies.
     */
    public func receive(
        context!: OperationContext = OperationContext.background()
    ): WebSocketFrame {
        checkWebSocketContext(context)
        acquireReader(context)
        let attemptedIo = readProgress
        attemptedIo.started = false
        try {
            let frame = readWireFrame(context, attemptedIo)
            validateInboundProgression(frame)
            if (isPingOpcode(frame.opcode)) {
                sendAutomaticControl(
                    WebSocketOpcode.Pong,
                    frame.wirePayload,
                    context.shortenDeadline(limits.closeTimeout)
                )
            } else if (isCloseOpcode(frame.opcode)) {
                synchronized(mutex) {
                    closeReceived = true
                    changed.notifyAll()
                }
                let bounded = context.shortenDeadline(limits.closeTimeout)
                sendAutomaticCloseIfNeeded(
                    webSocketCloseReplyPayload(role, frame.wirePayload),
                    bounded
                )
                completeGracefully(bounded)
            }
            frame
        } catch (error: WebSocketException) {
            if (attemptedIo.started && webSocketProtocolClose(error).isSome()) {
                terminateProtocol(webSocketProtocolClose(error).getOrThrow(), context)
            } else if (attemptedIo.started && !isClosed()) {
                failClosed(webSocketAbortReason(context))
            }
            throw error
        } catch (error: Exception) {
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw wrapWebSocketOperationFailure(error, context)
        } finally {
            releaseReader()
        }
    }

    /**
     * Sends a close frame, waits for the peer's close frame, and closes the transport.
     * The wait uses the shorter of closeTimeout and the caller's existing absolute deadline.
     * Server-role connections reject close status 1010.
     * @param code RFC close status: 1000, 1001, 1002, 1003, 1007 through 1014, or 3000 through 4999.
     * @param reason UTF-8 close reason of at most 123 encoded bytes.
     * @param context Cancellation and absolute deadline for the complete closing handshake.
     */
    public func close(
        code: UInt16,
        reason: String,
        context!: OperationContext = OperationContext.background()
    ): Unit {
        checkWebSocketContext(context)
        if (isServerRole(role) && code == 1010u16) {
            throw IllegalArgumentException("WebSocket servers cannot send close status 1010")
        }
        let payload = encodeWebSocketClose(code, reason)
        let bounded = context.shortenDeadline(limits.closeTimeout)
        sendAutomaticCloseIfNeeded(payload, bounded)
        while (true) {
            if (synchronized(mutex) { closeReceived }) {
                completeGracefully(bounded)
                return
            }
            try {
                let _ = receive(context: bounded)
            } catch (error: WebSocketException) {
                if (synchronized(mutex) { closeReceived }) { return }
                if (synchronized(mutex) { closeSent }) { failClosed(webSocketAbortReason(bounded)) }
                throw error
            }
        }
    }

    /** Prompt, terminal, idempotent resource cleanup; it never waits on protocol I/O. */
    public func close(): Unit {
        synchronized(mutex) {
            terminal = true
            changed.notifyAll()
        }
        transport.abort(reason: Some(api.AbortReason.ApplicationAbort))
    }

    /** Reports whether this connection has entered its terminal state. */
    public func isClosed(): Bool { synchronized(mutex) { terminal } }

    private func acquireReader(context: OperationContext): Unit {
        acquireOperation(context, reader: true)
    }

    private func acquireWriter(context: OperationContext): Unit {
        acquireOperation(context, reader: false)
    }

    private func acquireOperation(context: OperationContext, reader!: Bool): Unit {
        checkWebSocketContext(context)
        let registration = context.cancellation.register { => wakeOperations() }
        try {
            synchronized(mutex) {
                while ((if (reader) { readerActive } else { writerActive }) && !terminal) {
                    checkWebSocketContext(context)
                    waitWebSocketCondition(changed, context)
                }
                checkWebSocketContext(context)
                if (terminal) { throw webSocketClosed() }
                if (reader) { readerActive = true } else { writerActive = true }
            }
        } finally {
            registration.unregister()
        }
    }

    private func releaseReader(): Unit {
        synchronized(mutex) {
            readerActive = false
            changed.notifyAll()
        }
    }

    private func releaseWriter(): Unit {
        synchronized(mutex) {
            writerActive = false
            changed.notifyAll()
        }
    }

    private func wakeOperations(): Unit {
        synchronized(mutex) { changed.notifyAll() }
    }

    private func requireWritable(opcode: WebSocketOpcode): Unit {
        synchronized(mutex) {
            if (terminal) { throw webSocketClosed() }
            if (closeSent && !isCloseOpcode(opcode)) {
                throw WebSocketException(WebSocketErrorCode.Closed,
                    "WebSocket cannot send frames after its close frame")
            }
        }
    }

    private func requireOpenForAutomaticControl(): Unit {
        synchronized(mutex) {
            if (terminal) { throw webSocketClosed() }
        }
    }

    private func validateOutboundProgression(frame: WebSocketFrame): Unit {
        if (frame.wirePayload.size > limits.maximumFrameBytes) {
            throw WebSocketException(WebSocketErrorCode.InvalidFrame,
                "WebSocket frame exceeds the configured byte limit")
        }
        if (isCloseOpcode(frame.opcode) && isServerRole(role) &&
            webSocketCloseCode(frame.wirePayload) == Some(1010u16)) {
            throw WebSocketException(WebSocketErrorCode.InvalidFrame,
                "WebSocket servers cannot send close status 1010")
        }
        validateMessageProgression(
            frame,
            outboundFragment,
            outboundMessageBytes,
            outboundUtf8,
            limits
        )
    }

    private func commitOutboundProgression(frame: WebSocketFrame): Unit {
        let (nextFragment, nextBytes) = nextMessageProgression(
            frame,
            outboundFragment,
            outboundMessageBytes
        )
        outboundFragment = nextFragment
        outboundMessageBytes = nextBytes
    }

    private func validateInboundProgression(frame: WebSocketFrame): Unit {
        if (isCloseOpcode(frame.opcode)) {
            validateWireClose(frame.wirePayload)
            if (isClientRole(role) && webSocketCloseCode(frame.wirePayload) == Some(1010u16)) {
                throw webSocketProtocol("WebSocket servers cannot send close status 1010")
            }
        }
        validateMessageProgression(
            frame,
            inboundFragment,
            inboundMessageBytes,
            inboundUtf8,
            limits
        )
        let (nextFragment, nextBytes) =
            nextMessageProgression(frame, inboundFragment, inboundMessageBytes)
        inboundFragment = nextFragment
        inboundMessageBytes = nextBytes
    }

    private func sendAutomaticControl(
        opcode: WebSocketOpcode,
        payload: Array<Byte>,
        context: OperationContext
    ): Unit {
        acquireWriter(context)
        let attemptedIo = writeProgress
        attemptedIo.started = false
        try {
            requireOpenForAutomaticControl()
            writeWireFrame(opcode, true, payload, context, attemptedIo)
        } catch (error: WebSocketException) {
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw error
        } catch (error: Exception) {
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw wrapWebSocketOperationFailure(error, context)
        } finally {
            releaseWriter()
        }
    }

    private func sendAutomaticCloseIfNeeded(payload: Array<Byte>, context: OperationContext): Unit {
        if (synchronized(mutex) { closeSent }) { return }
        acquireWriter(context)
        let attemptedIo = writeProgress
        attemptedIo.started = false
        try {
            if (synchronized(mutex) { closeSent }) { return }
            writeWireFrame(WebSocketOpcode.Close, true, payload, context, attemptedIo)
            synchronized(mutex) {
                closeSent = true
                changed.notifyAll()
            }
        } catch (error: WebSocketException) {
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw error
        } catch (error: Exception) {
            if (attemptedIo.started) { failClosed(webSocketAbortReason(context)) }
            throw wrapWebSocketOperationFailure(error, context)
        } finally {
            releaseWriter()
        }
    }

    private func writeWireFrame(
        opcode: WebSocketOpcode,
        finalFragment: Bool,
        payload: Array<Byte>,
        context: OperationContext,
        attemptedIo: WebSocketIoProgress
    ): Unit {
        let masked = isClientRole(role)
        let mask = if (masked) {
            try {
                secureWebSocketRandom(WEBSOCKET_MASK_BYTES)
            } catch (error: Exception) {
                throw WebSocketException(WebSocketErrorCode.CryptoFailure,
                    "WebSocket client mask generation failed", cause: Some(error))
            }
        } else {
            Array<Byte>()
        }
        let header = encodeWebSocketHeader(opcode, finalFragment, payload.size, mask)
        writeWebSocketBytes(transport, header, context, attemptedIo)
        if (!masked) {
            writeWebSocketBytes(transport, payload, context, attemptedIo)
            return
        }
        var offset: Int64 = 0
        while (offset < payload.size) {
            let count = min(limits.ioBufferBytes, payload.size - offset)
            let staging = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) {
                staging[index] = payload[offset + index] ^ mask[(offset + index) % WEBSOCKET_MASK_BYTES]
            }
            writeWebSocketBytes(transport, staging, context, attemptedIo)
            offset += count
        }
    }

    private func readWireFrame(
        context: OperationContext,
        attemptedIo: WebSocketIoProgress
    ): WebSocketFrame {
        let first = Array<Byte>(2, repeat: 0u8)
        readWebSocketExact(transport, first, context, attemptedIo)
        if ((first[0] & 0x70u8) != 0u8) {
            throw webSocketProtocol("WebSocket extensions were not negotiated but RSV is set")
        }
        let finalFragment = (first[0] & 0x80u8) != 0u8
        let opcode = webSocketOpcodeFromWire(first[0] & 0x0fu8)
        let masked = (first[1] & 0x80u8) != 0u8
        if (masked != isServerRole(role)) {
            throw webSocketProtocol("WebSocket frame masking does not match the endpoint role")
        }
        let indicator = Int64(first[1] & 0x7fu8)
        let length = readWebSocketLength(indicator, context, attemptedIo)
        if (length > limits.maximumFrameBytes) {
            throw WebSocketException(WebSocketErrorCode.MessageTooLarge,
                "WebSocket frame exceeds the configured byte limit", closeCode: Some(1009u16))
        }
        if (isControlOpcode(opcode) && (!finalFragment || length > WEBSOCKET_CONTROL_BYTES)) {
            throw webSocketProtocol("WebSocket control frames must be final and at most 125 bytes")
        }
        let mask = if (masked) {
            let value = Array<Byte>(WEBSOCKET_MASK_BYTES, repeat: 0u8)
            readWebSocketExact(transport, value, context, attemptedIo)
            value
        } else {
            Array<Byte>()
        }
        let payload = Array<Byte>(length, repeat: 0u8)
        readWebSocketExact(transport, payload, context, attemptedIo)
        if (masked) {
            for (index in 0..payload.size) {
                payload[index] = payload[index] ^ mask[index % WEBSOCKET_MASK_BYTES]
            }
        }
        WebSocketFrame.fromWire(opcode, payload, finalFragment)
    }

    private func readWebSocketLength(
        indicator: Int64,
        context: OperationContext,
        attemptedIo: WebSocketIoProgress
    ): Int64 {
        if (indicator <= WEBSOCKET_CONTROL_BYTES) { return indicator }
        if (indicator == 126) {
            let bytes = Array<Byte>(2, repeat: 0u8)
            readWebSocketExact(transport, bytes, context, attemptedIo)
            let value = (Int64(bytes[0]) << 8) | Int64(bytes[1])
            if (value < 126) {
                throw webSocketProtocol("WebSocket frame length is not canonical")
            }
            return value
        }
        let bytes = Array<Byte>(8, repeat: 0u8)
        readWebSocketExact(transport, bytes, context, attemptedIo)
        if ((bytes[0] & 0x80u8) != 0u8) {
            throw webSocketProtocol("WebSocket frame length exceeds 63 bits")
        }
        var value: UInt64 = 0u64
        for (byte in bytes) { value = (value << 8) | UInt64(byte) }
        if (value < 65536u64) {
            throw webSocketProtocol("WebSocket frame length is not canonical")
        }
        if (value > UInt64(limits.maximumFrameBytes)) {
            throw WebSocketException(
                WebSocketErrorCode.MessageTooLarge,
                "WebSocket frame exceeds the configured byte limit",
                closeCode: Some(1009u16)
            )
        }
        Int64(value)
    }

    private func terminateProtocol(code: UInt16, context: OperationContext): Unit {
        let bounded = context.shortenDeadline(limits.closeTimeout)
        try {
            sendAutomaticCloseIfNeeded(encodeWebSocketClose(code, ""), bounded)
            completeGracefully(bounded)
        } catch (_: Exception) {
            failClosed(webSocketAbortReason(bounded))
        }
    }

    private func completeGracefully(context: OperationContext): Unit {
        let shouldClose = synchronized(mutex) {
            if (terminal) {
                false
            } else {
                terminal = true
                changed.notifyAll()
                true
            }
        }
        if (!shouldClose) { return }
        try {
            transport.close(context)
        } catch (_: Exception) {
            transport.abort(reason: Some(webSocketAbortReason(context)))
        }
    }

    private func failClosed(reason: api.AbortReason): Unit {
        synchronized(mutex) {
            terminal = true
            changed.notifyAll()
        }
        transport.abort(reason: Some(reason))
    }
}

/** Generates one fresh canonical Sec-WebSocket-Key using AWS-LC RAND_bytes. */
internal func newWebSocketKey(): String {
    try {
        webSocketBase64(secureWebSocketRandom(WEBSOCKET_CLIENT_KEY_BYTES))
    } catch (error: Exception) {
        throw WebSocketException(WebSocketErrorCode.CryptoFailure,
            "WebSocket handshake key generation failed", cause: Some(error))
    }
}

/** Computes Sec-WebSocket-Accept with the RFC GUID via audited AWS-LC SHA-1/base64. */
internal func webSocketAcceptKey(key: String): String {
    if (!validWebSocketClientKey(key)) {
        throw IllegalArgumentException("Sec-WebSocket-Key is not canonical base64 for 16 bytes")
    }
    try {
        webSocketSha1Base64("${key}${WEBSOCKET_ACCEPT_GUID}".toArray())
    } catch (error: Exception) {
        throw WebSocketException(WebSocketErrorCode.CryptoFailure,
            "WebSocket accept-key computation failed", cause: Some(error))
    }
}

private func validateLocalWebSocketFrame(
    opcode: WebSocketOpcode,
    payload: Array<Byte>,
    finalFragment: Bool
): Unit {
    if (isControlOpcode(opcode) && (!finalFragment || payload.size > WEBSOCKET_CONTROL_BYTES)) {
        throw IllegalArgumentException("WebSocket control frames must be final and at most 125 bytes")
    }
    if (isCloseOpcode(opcode)) {
        try {
            validateWireClose(payload)
        } catch (error: WebSocketException) {
            throw IllegalArgumentException(error.message)
        }
    }
}

private func validateMessageProgression(
    frame: WebSocketFrame,
    fragmented: ?WebSocketOpcode,
    messageBytes: Int64,
    utf8: WebSocketUtf8Validator,
    limits: WebSocketLimits
): Unit {
    if (isControlOpcode(frame.opcode)) { return }
    let payload = frame.wirePayload
    match (frame.opcode) {
        case WebSocketOpcode.Continuation =>
            if (fragmented.isNone()) {
                throw webSocketProtocol("WebSocket continuation has no fragmented message")
            }
            requireWebSocketMessageBound(messageBytes, payload.size, limits)
            if (isTextOpcode(fragmented.getOrThrow())) {
                utf8.feed(payload, finalChunk: frame.finalFragment)
            }
        case WebSocketOpcode.Text | WebSocketOpcode.Binary =>
            if (fragmented.isSome()) {
                throw webSocketProtocol("WebSocket data frame interrupted a fragmented message")
            }
            requireWebSocketMessageBound(0, payload.size, limits)
            if (isTextOpcode(frame.opcode)) {
                utf8.reset()
                utf8.feed(payload, finalChunk: frame.finalFragment)
            }
        case _ => ()
    }
}

private func nextMessageProgression(
    frame: WebSocketFrame,
    fragmented: ?WebSocketOpcode,
    messageBytes: Int64
): (?WebSocketOpcode, Int64) {
    if (isControlOpcode(frame.opcode)) { return (fragmented, messageBytes) }
    match (frame.opcode) {
        case WebSocketOpcode.Continuation =>
            if (frame.finalFragment) { (None<WebSocketOpcode>, 0) }
            else { (fragmented, messageBytes + frame.wirePayload.size) }
        case WebSocketOpcode.Text | WebSocketOpcode.Binary =>
            if (frame.finalFragment) { (None<WebSocketOpcode>, 0) }
            else { (Some(frame.opcode), frame.wirePayload.size) }
        case _ => (fragmented, messageBytes)
    }
}

private func requireWebSocketMessageBound(
    current: Int64,
    added: Int64,
    limits: WebSocketLimits
): Unit {
    if (added > limits.maximumMessageBytes - min(current, limits.maximumMessageBytes)) {
        throw WebSocketException(WebSocketErrorCode.MessageTooLarge,
            "WebSocket message exceeds the configured byte limit", closeCode: Some(1009u16))
    }
}

private class WebSocketUtf8Validator {
    private var remaining: Int64 = 0
    private var lower: Byte = 0x80u8
    private var upper: Byte = 0xbfu8

    func reset(): Unit {
        remaining = 0
        lower = 0x80u8
        upper = 0xbfu8
    }

    func snapshot(): (Int64, Byte, Byte) { (remaining, lower, upper) }

    func restore(state: (Int64, Byte, Byte)): Unit {
        let (nextRemaining, nextLower, nextUpper) = state
        remaining = nextRemaining
        lower = nextLower
        upper = nextUpper
    }

    func feed(bytes: Array<Byte>, finalChunk!: Bool): Unit {
        for (byte in bytes) {
            if (remaining == 0) {
                if (byte <= 0x7fu8) {
                    continue
                } else if (byte >= 0xc2u8 && byte <= 0xdfu8) {
                    begin(1, 0x80u8, 0xbfu8)
                } else if (byte == 0xe0u8) {
                    begin(2, 0xa0u8, 0xbfu8)
                } else if ((byte >= 0xe1u8 && byte <= 0xecu8) ||
                    (byte >= 0xeeu8 && byte <= 0xefu8)) {
                    begin(2, 0x80u8, 0xbfu8)
                } else if (byte == 0xedu8) {
                    begin(2, 0x80u8, 0x9fu8)
                } else if (byte == 0xf0u8) {
                    begin(3, 0x90u8, 0xbfu8)
                } else if (byte >= 0xf1u8 && byte <= 0xf3u8) {
                    begin(3, 0x80u8, 0xbfu8)
                } else if (byte == 0xf4u8) {
                    begin(3, 0x80u8, 0x8fu8)
                } else {
                    invalidWebSocketUtf8()
                }
            } else {
                if (byte < lower || byte > upper) { invalidWebSocketUtf8() }
                remaining--
                lower = 0x80u8
                upper = 0xbfu8
            }
        }
        if (finalChunk && remaining != 0) { invalidWebSocketUtf8() }
    }

    private func begin(count: Int64, firstLower: Byte, firstUpper: Byte): Unit {
        remaining = count
        lower = firstLower
        upper = firstUpper
    }
}

private func invalidWebSocketUtf8(): Nothing {
    throw WebSocketException(WebSocketErrorCode.InvalidPayload,
        "WebSocket text is not valid UTF-8", closeCode: Some(1007u16))
}

private func validateWireClose(payload: Array<Byte>): Unit {
    if (payload.size == 1) { throw webSocketProtocol("WebSocket close payload cannot contain one byte") }
    if (payload.isEmpty()) { return }
    let code = (UInt16(payload[0]) << 8) | UInt16(payload[1])
    if (!validWebSocketCloseCode(code)) {
        throw webSocketProtocol("WebSocket close status code is invalid")
    }
    let reason = Array<Byte>(payload.size - 2, repeat: 0u8)
    for (index in 0..reason.size) { reason[index] = payload[index + 2] }
    let validator = WebSocketUtf8Validator()
    validator.feed(reason, finalChunk: true)
}

private func webSocketCloseCode(payload: Array<Byte>): ?UInt16 {
    if (payload.size < 2) { return None<UInt16> }
    Some((UInt16(payload[0]) << 8) | UInt16(payload[1]))
}

private func webSocketCloseReplyPayload(
    role: WebSocketRole,
    received: Array<Byte>
): Array<Byte> {
    if (isServerRole(role) && webSocketCloseCode(received) == Some(1010u16)) {
        encodeWebSocketClose(1000u16, "")
    } else {
        received
    }
}

private func encodeWebSocketClose(code: UInt16, reason: String): Array<Byte> {
    if (!validWebSocketCloseCode(code)) {
        throw IllegalArgumentException("WebSocket close status code is invalid")
    }
    let reasonBytes = reason.toArray()
    if (reasonBytes.size > 123) {
        throw IllegalArgumentException("WebSocket close reason exceeds 123 UTF-8 bytes")
    }
    let output = Array<Byte>(reasonBytes.size + 2, repeat: 0u8)
    output[0] = UInt8(code >> 8)
    output[1] = UInt8(code & 0xffu16)
    for (index in 0..reasonBytes.size) { output[index + 2] = reasonBytes[index] }
    output
}

private func validWebSocketCloseCode(code: UInt16): Bool {
    match (code) {
        case 1000u16 | 1001u16 | 1002u16 | 1003u16 | 1007u16 | 1008u16 |
            1009u16 | 1010u16 | 1011u16 | 1012u16 | 1013u16 | 1014u16 => true
        case value => value >= 3000u16 && value <= 4999u16
    }
}

internal func validateWebSocketSubProtocol(value: String): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 256) {
        throw IllegalArgumentException("WebSocket subprotocol length is invalid")
    }
    for (byte in bytes) {
        if (!webSocketTokenByte(byte)) {
            throw IllegalArgumentException("WebSocket subprotocol is not an HTTP token")
        }
    }
}

private func webSocketTokenByte(byte: Byte): Bool {
    if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9')) { return true }
    byte == b'!' || byte == b'#' || byte == b'$' || byte == b'%' || byte == b'&' ||
        byte == b'\'' || byte == b'*' || byte == b'+' || byte == b'-' || byte == b'.' ||
        byte == b'^' || byte == b'_' || byte == b'`' || byte == b'|' || byte == b'~'
}

private func validWebSocketClientKey(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.size != 24 || bytes[22] != b'=' || bytes[23] != b'=') { return false }
    for (index in 0..22) {
        if (webSocketBase64Value(bytes[index]) < 0) { return false }
    }
    let finalValue = webSocketBase64Value(bytes[21])
    finalValue >= 0 && (finalValue & 0x0f) == 0
}

private func webSocketBase64Value(byte: Byte): Int64 {
    if (byte >= b'A' && byte <= b'Z') { return Int64(byte - b'A') }
    if (byte >= b'a' && byte <= b'z') { return Int64(byte - b'a') + 26 }
    if (byte >= b'0' && byte <= b'9') { return Int64(byte - b'0') + 52 }
    if (byte == b'+') { return 62 }
    if (byte == b'/') { return 63 }
    -1
}

private func encodeWebSocketHeader(
    opcode: WebSocketOpcode,
    finalFragment: Bool,
    payloadBytes: Int64,
    mask: Array<Byte>
): Array<Byte> {
    let masked = !mask.isEmpty()
    let extended = if (payloadBytes <= 125) { 0 } else if (payloadBytes <= 65535) { 2 } else { 8 }
    let output = Array<Byte>(2 + extended + mask.size, repeat: 0u8)
    output[0] = (if (finalFragment) { 0x80u8 } else { 0u8 }) | webSocketOpcodeToWire(opcode)
    output[1] = if (masked) { 0x80u8 } else { 0u8 }
    if (extended == 0) {
        output[1] = output[1] | UInt8(payloadBytes)
    } else if (extended == 2) {
        output[1] = output[1] | 126u8
        output[2] = UInt8((UInt64(payloadBytes) >> 8) & 0xffu64)
        output[3] = UInt8(UInt64(payloadBytes) & 0xffu64)
    } else {
        output[1] = output[1] | 127u8
        let value = UInt64(payloadBytes)
        for (index in 0..8) {
            output[2 + index] = UInt8((value >> UInt64((7 - index) * 8)) & 0xffu64)
        }
    }
    for (index in 0..mask.size) { output[2 + extended + index] = mask[index] }
    output
}

private func writeWebSocketBytes(
    transport: api.DuplexTransport,
    bytes: Array<Byte>,
    context: OperationContext,
    attemptedIo: WebSocketIoProgress
): Unit {
    var remaining = api.ByteSpan(bytes)
    while (!remaining.isEmpty()) {
        checkWebSocketContext(context)
        attemptedIo.started = true
        let written = transport.writeSome(remaining, context: context)
        if (written <= 0 || written > remaining.length) {
            throw WebSocketException(WebSocketErrorCode.TransportFailure,
                "WebSocket transport returned invalid write progress")
        }
        remaining = remaining.advance(written)
    }
}

private func readWebSocketExact(
    transport: api.DuplexTransport,
    bytes: Array<Byte>,
    context: OperationContext,
    attemptedIo: WebSocketIoProgress
): Unit {
    var remaining = api.MutableByteSpan(bytes)
    while (!remaining.isEmpty()) {
        checkWebSocketContext(context)
        attemptedIo.started = true
        match (transport.readSome(remaining, context: context)) {
            case api.ReadResult.Data(count) =>
                if (count <= 0 || count > remaining.length) {
                    throw WebSocketException(WebSocketErrorCode.TransportFailure,
                        "WebSocket transport returned invalid read progress")
                }
                remaining = remaining.advance(count)
            case api.ReadResult.EndOfStream =>
                throw WebSocketException(WebSocketErrorCode.TransportFailure,
                    "WebSocket transport ended before a close frame")
        }
    }
}

private func checkWebSocketContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw WebSocketException(WebSocketErrorCode.ContextStopped,
            "WebSocket operation was cancelled")
    }
    if (context.isDeadlineExceeded()) {
        throw WebSocketException(WebSocketErrorCode.ContextStopped,
            "WebSocket operation deadline was exceeded")
    }
}

private func waitWebSocketCondition(condition: Condition, context: OperationContext): Unit {
    match (context.deadline) {
        case Some(deadline) =>
            let remaining = deadline.remaining()
            if (remaining <= Duration.Zero) { checkWebSocketContext(context) }
            condition.wait(timeout: remaining)
        case None => condition.wait()
    }
}

private func wrapWebSocketOperationFailure(
    error: Exception,
    context: OperationContext
): WebSocketException {
    if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
        WebSocketException(WebSocketErrorCode.ContextStopped,
            "WebSocket operation context stopped during transport I/O", cause: Some(error))
    } else {
        WebSocketException(WebSocketErrorCode.TransportFailure,
            "WebSocket transport operation failed", cause: Some(error))
    }
}

private func webSocketAbortReason(context: OperationContext): api.AbortReason {
    if (context.isCancellationRequested()) { api.AbortReason.Cancelled }
    else if (context.isDeadlineExceeded()) { api.AbortReason.DeadlineExceeded }
    else { api.AbortReason.ProtocolFailure }
}

private func webSocketProtocol(message: String): WebSocketException {
    WebSocketException(WebSocketErrorCode.ProtocolViolation, message, closeCode: Some(1002u16))
}

private func webSocketProtocolClose(error: WebSocketException): ?UInt16 {
    match (error.code) {
        case WebSocketErrorCode.ProtocolViolation | WebSocketErrorCode.MessageTooLarge |
            WebSocketErrorCode.InvalidPayload => error.closeCode
        case _ => None<UInt16>
    }
}

private func webSocketClosed(): WebSocketException {
    WebSocketException(WebSocketErrorCode.Closed, "WebSocket connection is closed")
}

private func webSocketOpcodeFromWire(value: Byte): WebSocketOpcode {
    match (value) {
        case 0u8 => WebSocketOpcode.Continuation
        case 1u8 => WebSocketOpcode.Text
        case 2u8 => WebSocketOpcode.Binary
        case 8u8 => WebSocketOpcode.Close
        case 9u8 => WebSocketOpcode.Ping
        case 10u8 => WebSocketOpcode.Pong
        case _ => throw webSocketProtocol("WebSocket opcode is reserved or unknown")
    }
}

private func webSocketOpcodeToWire(value: WebSocketOpcode): Byte {
    match (value) {
        case WebSocketOpcode.Continuation => 0u8
        case WebSocketOpcode.Text => 1u8
        case WebSocketOpcode.Binary => 2u8
        case WebSocketOpcode.Close => 8u8
        case WebSocketOpcode.Ping => 9u8
        case WebSocketOpcode.Pong => 10u8
    }
}

private func isClientRole(value: WebSocketRole): Bool {
    match (value) { case WebSocketRole.Client => true; case _ => false }
}

private func isServerRole(value: WebSocketRole): Bool {
    match (value) { case WebSocketRole.Server => true; case _ => false }
}

private func isControlOpcode(value: WebSocketOpcode): Bool {
    match (value) {
        case WebSocketOpcode.Close | WebSocketOpcode.Ping | WebSocketOpcode.Pong => true
        case _ => false
    }
}

private func isCloseOpcode(value: WebSocketOpcode): Bool {
    match (value) { case WebSocketOpcode.Close => true; case _ => false }
}

private func isPingOpcode(value: WebSocketOpcode): Bool {
    match (value) { case WebSocketOpcode.Ping => true; case _ => false }
}

private func isTextOpcode(value: WebSocketOpcode): Bool {
    match (value) { case WebSocketOpcode.Text => true; case _ => false }
}

private class WebSocketIoProgress {
    var started = false
}
