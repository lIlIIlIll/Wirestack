package wirestack.internal.http2

import std.collection.*
import std.sync.*
import wirestack.internal.transport.*

private const HTTP2_READER_BUFFER_SIZE: Int64 = 16 * 1024

/** Serialized consumer for decoded inbound frames and connection responses. */
public interface Http2InboundFrameHandler {
    func handle(frame: Http2Frame, result: Http2ConnectionReceiveResult): Unit
    func readerTerminated(completion: Http2ConnectionCompletion, terminalGoAway: ?Http2Frame): Unit
}

/** A stream-owned wakeup target. Implementations must not block the reader. */
public interface Http2ReaderTerminationListener {
    func readerTerminated(completion: Http2ConnectionCompletion): Unit
}

/** Idempotent removal of a not-yet-claimed terminal listener. */
public class Http2ReaderTerminationRegistration {
    private let registry: Http2ReaderTerminationRegistry
    private let id: Int64
    private let removed = AtomicBool(false)

    internal init(registry: Http2ReaderTerminationRegistry, id: Int64) {
        this.registry = registry
        this.id = id
    }

    public func unregister(): Unit {
        if (!removed.swap(true)) { registry.unregister(id) }
    }
}

/** Bounded exactly-once terminal fanout used by all streams on one connection. */
public class Http2ReaderTerminationRegistry {
    private let limit: Int64
    private let mutex = Mutex()
    private var nextId: Int64 = 1
    private var listeners = HashMap<Int64, Http2ReaderTerminationListener>()
    private var terminal: ?Http2ConnectionCompletion = None<Http2ConnectionCompletion>

    public prop activeCount: Int64 { get() { synchronized(mutex) { listeners.size } } }

    public init(maxListeners: UInt32) {
        if (maxListeners == 0u32) { throw IllegalArgumentException("HTTP/2 reader listener limit must be positive") }
        limit = Int64(maxListeners)
    }

    /** A late registration is invoked synchronously with retained terminal evidence. */
    public func register(listener: Http2ReaderTerminationListener): Http2ReaderTerminationRegistration {
        var immediate: ?Http2ConnectionCompletion = None<Http2ConnectionCompletion>
        let id = synchronized(mutex) {
            match (terminal) {
                case Some(value) => immediate = Some(value); 0
                case None =>
                    if (listeners.size >= limit) {
                        throw IllegalStateException("HTTP/2 reader listener limit reached")
                    }
                    let current = nextId
                    nextId += 1
                    listeners[current] = listener
                    current
            }
        }
        if (let Some(value) <- immediate) { notifyReaderListener(listener, value) }
        Http2ReaderTerminationRegistration(this, id)
    }

    /** Claims every current listener and invokes each one at most once. */
    public func terminate(completion: Http2ConnectionCompletion): Bool {
        let claimed = synchronized(mutex) {
            if (terminal.isSome()) { return false }
            terminal = Some(completion)
            let result = ArrayList<Http2ReaderTerminationListener>()
            for (listener in listeners.values()) { result.add(listener) }
            listeners = HashMap<Int64, Http2ReaderTerminationListener>()
            result
        }
        for (listener in claimed) { notifyReaderListener(listener, completion) }
        true
    }

    internal func unregister(id: Int64): Unit {
        if (id == 0) { return }
        synchronized(mutex) { listeners.remove(id) }
    }
}

/**
 * The only transport reader for one HTTP/2 connection.
 *
 * It incrementally consumes the server-side client magic, decodes all frames
 * in wire order, and serially calls the handler. Any terminal path completes
 * the state machine and wakes every registered stream without spawning a
 * per-stream reader task.
 */
public class Http2ConnectionReader {
    private let transport: DuplexTransport
    private let machine: Http2ConnectionStateMachine
    private let handler: Http2InboundFrameHandler
    private let parser: Http2FrameParser
    private let terminations: Http2ReaderTerminationRegistry
    private let lifecycleMutex = Mutex()
    private var claimed = false
    private var running = false

    public prop isRunning: Bool { get() { synchronized(lifecycleMutex) { running } } }
    public prop terminationRegistry: Http2ReaderTerminationRegistry { get() { terminations } }

    public init(
        transport: DuplexTransport,
        machine: Http2ConnectionStateMachine,
        handler: Http2InboundFrameHandler,
        limits!: Http2Limits = Http2Limits()
    ) {
        this.transport = transport
        this.machine = machine
        this.handler = handler
        parser = Http2FrameParser(limits: limits)
        terminations = Http2ReaderTerminationRegistry(limits.maxConcurrentStreams)
    }

    /** Runs to terminal completion on the caller's task; a second call is rejected forever. */
    public func run(context!: OperationContext = OperationContext.background()): Http2ConnectionCompletion {
        synchronized(lifecycleMutex) {
            if (claimed) { throw IllegalStateException("HTTP/2 connection already has a reader loop") }
            claimed = true
            running = true
        }
        var abortReason = AbortReason.ApplicationAbort
        try {
            readUntilTerminal(context)
            abortReason = AbortReason.ApplicationAbort
        } catch (error: Http2ProtocolException) {
            let _ = machine.failConnection(error.code, error.message)
            abortReason = AbortReason.ProtocolFailure
        } catch (error: NetworkException) {
            if (context.isCancellationRequested()) {
                let _ = machine.finish(reason: "HTTP/2 reader cancelled")
                abortReason = AbortReason.Cancelled
            } else if (context.isDeadlineExceeded()) {
                let _ = machine.finish(code: Http2ErrorCode.InternalError, reason: "HTTP/2 reader deadline exceeded")
                abortReason = AbortReason.DeadlineExceeded
            } else {
                let _ = machine.finish(code: Http2ErrorCode.InternalError, reason: error.message)
                abortReason = AbortReason.ApplicationAbort
            }
        } catch (error: Exception) {
            let _ = machine.failConnection(Http2ErrorCode.InternalError, error.message)
            abortReason = AbortReason.ProtocolFailure
        } finally {
            let _ = machine.finish(reason: "HTTP/2 reader stopped")
            synchronized(lifecycleMutex) { running = false }
        }

        let completion = machine.completion.getOrThrow()
        let terminalGoAway = machine.takeTerminalGoAway()
        try { handler.readerTerminated(completion, terminalGoAway) } catch (_: Exception) {}
        let _ = terminations.terminate(completion)
        try { transport.abort(reason: Some(abortReason)) } catch (_: Exception) {}
        completion
    }

    private func readUntilTerminal(context: OperationContext): Unit {
        let buffer = Array<Byte>(HTTP2_READER_BUFFER_SIZE, repeat: 0u8)
        while (machine.completion.isNone()) {
            match (transport.readSome(MutableByteSpan(buffer), context: context)) {
                case ReadResult.Data(count) =>
                    if (count <= 0 || count > buffer.size) {
                        throw NetworkException(
                            NetworkErrorCategory.Read,
                            NetworkPhase.HttpHeaders,
                            NetworkErrorCode.SystemFailure,
                            "HTTP/2 transport returned invalid read progress",
                            retryability: Retryability.Never
                        )
                    }
                    consume(copyReaderBytes(buffer, count))
                case ReadResult.EndOfStream =>
                    if (!machine.peerPrefaceComplete || parser.hasIncompleteFrame() ||
                        isReaderPrefacePhase(machine.phase)) {
                        throw Http2ProtocolException(
                            Http2ErrorCode.ProtocolError,
                            Http2ErrorScope.Connection,
                            "HTTP/2 transport ended with an incomplete preface or frame"
                        )
                    }
                    let _ = machine.finish(reason: "HTTP/2 peer closed the transport")
            }
        }
    }

    private func consume(bytes: Array<Byte>): Unit {
        var offset: Int64 = 0
        if (!machine.peerPrefaceComplete) {
            offset = machine.acceptClientPreface(bytes)
        }
        if (offset == bytes.size) { return }
        let remainder = Array<Byte>(bytes.size - offset, repeat: 0u8)
        for (index in 0..remainder.size) { remainder[index] = bytes[offset + index] }
        let frames = parser.feed(remainder)
        for (frame in frames) {
            let result = machine.receive(frame)
            handler.handle(frame, result)
        }
    }
}

private func copyReaderBytes(input: Array<Byte>, count: Int64): Array<Byte> {
    let output = Array<Byte>(count, repeat: 0u8)
    for (index in 0..count) { output[index] = input[index] }
    output
}

private func notifyReaderListener(
    listener: Http2ReaderTerminationListener,
    completion: Http2ConnectionCompletion
): Unit {
    try { listener.readerTerminated(completion) } catch (_: Exception) {}
}

private func isReaderPrefacePhase(phase: Http2ConnectionPhase): Bool {
    match (phase) { case Http2ConnectionPhase.Preface => true; case _ => false }
}
