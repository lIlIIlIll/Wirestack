package wirestack.internal.http2

import std.sync.*
import std.time.MonoTime
import wirestack.internal.transport.*

/** Immutable decoded PING with an owned eight-octet payload. */
public class Http2Ping {
    public let ack: Bool
    private let ownedOpaqueData: Array<Byte>
    public prop opaqueData: Array<Byte> { get() { ownedOpaqueData.clone() } }

    public init(opaqueData: Array<Byte>, ack!: Bool = false) {
        if (opaqueData.size != 8) { throw IllegalArgumentException("HTTP/2 PING requires eight opaque bytes") }
        ownedOpaqueData = opaqueData.clone()
        this.ack = ack
    }
}

public func encodeHttp2Ping(opaqueData: Array<Byte>, ack!: Bool = false): Http2Frame {
    let value = Http2Ping(opaqueData, ack: ack)
    Http2Frame(
        Http2FrameHeader(
            8u32,
            Http2FrameType.Ping,
            Http2Flags(raw: if (value.ack) { 0x01u8 } else { 0u8 }),
            Http2StreamId(0u32)
        ),
        value.opaqueData
    )
}

public func decodeHttp2Ping(frame: Http2Frame): Http2Ping {
    if (http2FrameTypeCode(frame.header.frameType) != 6u8) {
        throw IllegalArgumentException("expected HTTP/2 PING frame")
    }
    Http2Ping(frame.payload, ack: frame.header.flags.isAck())
}

public class Http2HealthPolicy {
    public let idleTimeout: Duration
    public let pingTimeout: Duration

    public init(
        idleTimeout!: Duration = 30 * Duration.second,
        pingTimeout!: Duration = 10 * Duration.second
    ) {
        if (idleTimeout <= Duration.Zero || pingTimeout <= Duration.Zero) {
            throw IllegalArgumentException("HTTP/2 health timeouts must be positive")
        }
        this.idleTimeout = idleTimeout
        this.pingTimeout = pingTimeout
    }
}

public enum Http2HealthState {
    | Healthy
    | ProbePending
    | Unhealthy
    | Closed
}

/** One caller-driven health evaluation; it creates no timer or background task. */
public class Http2HealthPollResult {
    public let state: Http2HealthState
    public let probe: ?Http2WriteTicket
    public let timedOut: Bool

    internal init(
        state: Http2HealthState,
        probe!: ?Http2WriteTicket = None<Http2WriteTicket>,
        timedOut!: Bool = false
    ) {
        this.state = state
        this.probe = probe
        this.timedOut = timedOut
    }
}

/**
 * Bounded connection health state: at most one outstanding PING and one
 * monotonic next-check instant. A shared connection driver calls `poll`.
 */
public class Http2ConnectionHealth {
    private let writer: Http2WriteScheduler
    private let policy: Http2HealthPolicy
    private let clock: MonotonicClock
    private let mutex = Mutex()
    private var current = Http2HealthState.Healthy
    private var lastActivity: MonoTime
    private var pendingPayload: ?Array<Byte> = None<Array<Byte>>
    private var pendingDeadline: ?MonoTime = None<MonoTime>
    private var sequence: UInt64 = 1u64

    public prop state: Http2HealthState { get() { synchronized(mutex) { current } } }
    public prop hasOutstandingPing: Bool { get() { synchronized(mutex) { pendingPayload.isSome() } } }
    public prop outstandingOpaqueData: ?Array<Byte> {
        get() {
            synchronized(mutex) {
                match (pendingPayload) {
                    case Some(value) => Some(value.clone())
                    case None => None<Array<Byte>>
                }
            }
        }
    }
    public prop nextCheckAt: ?MonoTime {
        get() {
            synchronized(mutex) {
                match (current) {
                    case Http2HealthState.Healthy => Some(lastActivity + policy.idleTimeout)
                    case Http2HealthState.ProbePending => pendingDeadline
                    case _ => None<MonoTime>
                }
            }
        }
    }

    public init(
        writer: Http2WriteScheduler,
        policy!: Http2HealthPolicy = Http2HealthPolicy(),
        clock!: MonotonicClock = SystemMonotonicClock()
    ) {
        this.writer = writer
        this.policy = policy
        this.clock = clock
        lastActivity = clock.now()
    }

    /** Records any successfully decoded inbound frame and matches a PING ACK if present. */
    public func observeInbound(frame: Http2Frame): Bool {
        synchronized(mutex) {
            if (isHealthTerminal(current)) { return false }
            lastActivity = clock.now()
            if (http2FrameTypeCode(frame.header.frameType) != 6u8) { return false }
            let ping = decodeHttp2Ping(frame)
            if (!ping.ack) { return false }
            match (pendingPayload) {
                case Some(expected) =>
                    if (samePingPayload(expected, ping.opaqueData)) {
                        pendingPayload = None<Array<Byte>>
                        pendingDeadline = None<MonoTime>
                        current = Http2HealthState.Healthy
                        true
                    } else { false }
                case None => false
            }
        }
    }

    /** Outbound application/control progress also resets the idle interval. */
    public func observeOutboundActivity(): Unit {
        synchronized(mutex) {
            if (!isHealthTerminal(current)) { lastActivity = clock.now() }
        }
    }

    /** Evaluates idle/probe state once; repeated calls retain at most one probe. */
    public func poll(): Http2HealthPollResult {
        synchronized(mutex) {
            let now = clock.now()
            match (current) {
                case Http2HealthState.Closed => return Http2HealthPollResult(current)
                case Http2HealthState.Unhealthy => return Http2HealthPollResult(current, timedOut: true)
                case Http2HealthState.ProbePending =>
                    if (now >= pendingDeadline.getOrThrow()) {
                        current = Http2HealthState.Unhealthy
                        return Http2HealthPollResult(current, timedOut: true)
                    }
                    return Http2HealthPollResult(current)
                case Http2HealthState.Healthy => ()
            }
            if (now < lastActivity + policy.idleTimeout) { return Http2HealthPollResult(current) }
            let payload = nextPingPayloadLocked()
            let ticket = writer.enqueue(encodeHttp2Ping(payload))
            pendingPayload = Some(payload)
            pendingDeadline = Some(now + policy.pingTimeout)
            current = Http2HealthState.ProbePending
            lastActivity = now
            Http2HealthPollResult(current, probe: Some(ticket))
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            current = Http2HealthState.Closed
            pendingPayload = None<Array<Byte>>
            pendingDeadline = None<MonoTime>
        }
    }

    private func nextPingPayloadLocked(): Array<Byte> {
        let value = sequence
        sequence = if (sequence == 18446744073709551615u64) { 1u64 } else { sequence + 1u64 }
        [
            UInt8((value >> 56) & 0xffu64), UInt8((value >> 48) & 0xffu64),
            UInt8((value >> 40) & 0xffu64), UInt8((value >> 32) & 0xffu64),
            UInt8((value >> 24) & 0xffu64), UInt8((value >> 16) & 0xffu64),
            UInt8((value >> 8) & 0xffu64), UInt8(value & 0xffu64)
        ]
    }
}

public enum Http2ConnectionCloseMode {
    | Graceful
    | Aborted
}

public class Http2ConnectionCloseResult {
    public let mode: Http2ConnectionCloseMode
    public let reason: ?AbortReason

    internal init(mode: Http2ConnectionCloseMode, reason: ?AbortReason) {
        this.mode = mode
        this.reason = reason
    }
}

private enum Http2ConnectionClosePhase {
    | Open
    | Closing
    | Finalizing
    | Aborting
    | Terminal
}

/**
 * Exactly-once graceful connection close. GOAWAY, active-stream drain, writer
 * drain and transport close share the caller's one absolute Deadline; cancel,
 * timeout or explicit abort upgrades the same close to immediate termination.
 */
public class Http2ConnectionCloser {
    private let machine: Http2ConnectionStateMachine
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let goAway: Http2GoAwayManager
    private let health: ?Http2ConnectionHealth
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var phase = Http2ConnectionClosePhase.Open
    private var terminal: ?Http2ConnectionCloseResult = None<Http2ConnectionCloseResult>

    public prop result: ?Http2ConnectionCloseResult { get() { synchronized(mutex) { terminal } } }

    public init(
        machine: Http2ConnectionStateMachine,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        goAway: Http2GoAwayManager,
        health!: ?Http2ConnectionHealth = None<Http2ConnectionHealth>
    ) {
        this.machine = machine
        this.registry = registry
        this.flow = flow
        this.writer = writer
        this.goAway = goAway
        this.health = health
    }

    public func close(
        context!: OperationContext = OperationContext.background()
    ): Http2ConnectionCloseResult {
        let owns = synchronized(mutex) {
            match (terminal) {
                case Some(_) => false
                case None => match (phase) {
                    case Http2ConnectionClosePhase.Open => phase = Http2ConnectionClosePhase.Closing; true
                    case _ => false
                }
            }
        }
        if (!owns) { return waitOrUpgrade(context) }
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            return abort(reason: closeAbortReason(context))
        }
        try {
            let goAwayTicket = goAway.beginLocalDrain()
            if (!isCloseWriteWritten(goAwayTicket.wait(context: context))) {
                return abort(reason: closeAbortReason(context))
            }
            if (!registry.waitUntilEmpty(context: context)) {
                return abort(reason: closeAbortReason(context))
            }
            writer.close()
            if (!isCloseWriterClosed(writer.waitUntilTerminal(context: context))) {
                return abort(reason: closeAbortReason(context))
            }
            let finalizing = synchronized(mutex) {
                match (phase) {
                    case Http2ConnectionClosePhase.Closing =>
                        phase = Http2ConnectionClosePhase.Finalizing
                        true
                    case _ => false
                }
            }
            if (!finalizing) { return waitForTerminal(OperationContext.background()) }
            let _ = writer.finishTransport(context: context)
            let stillFinalizing = synchronized(mutex) {
                match (phase) { case Http2ConnectionClosePhase.Finalizing => true; case _ => false }
            }
            if (!stillFinalizing) { return waitForTerminal(OperationContext.background()) }
            let _ = machine.finish(reason: "HTTP/2 connection closed gracefully")
            let completion = machine.completion.getOrThrow()
            let _ = registry.closeConnection(completion)
            flow.close()
            if (let Some(value) <- health) { value.close() }
            publishTerminal(Http2ConnectionCloseResult(
                Http2ConnectionCloseMode.Graceful, None<AbortReason>
            ))
        } catch (_: Exception) {
            abort(reason: closeAbortReason(context))
        }
    }

    public func abort(
        reason!: AbortReason = AbortReason.ApplicationAbort
    ): Http2ConnectionCloseResult {
        let owns = synchronized(mutex) {
            if (terminal.isSome()) { false }
            else {
                match (phase) {
                    case Http2ConnectionClosePhase.Aborting => false
                    case _ => phase = Http2ConnectionClosePhase.Aborting; true
                }
            }
        }
        if (!owns) { return waitForTerminal(OperationContext.background()) }
        try {
            writer.abort(reason: reason)
            flow.close()
            if (let Some(value) <- health) { value.close() }
            let code = if (isProtocolAbort(reason)) { Http2ErrorCode.ProtocolError }
                else { Http2ErrorCode.InternalError }
            let _ = machine.finish(code: code, reason: "HTTP/2 connection aborted")
            let completion = machine.completion.getOrThrow()
            let _ = registry.closeConnection(completion)
        } catch (_: Exception) {
            let _ = machine.finish(code: Http2ErrorCode.InternalError, reason: "HTTP/2 abort cleanup failed")
        }
        publishTerminal(Http2ConnectionCloseResult(Http2ConnectionCloseMode.Aborted, Some(reason)))
    }

    private func waitOrUpgrade(context: OperationContext): Http2ConnectionCloseResult {
        let pending = waitForTerminalOrBudget(context)
        match (pending) {
            case Some(value) => value
            case None => abort(reason: closeAbortReason(context))
        }
    }

    private func waitForTerminal(context: OperationContext): Http2ConnectionCloseResult {
        waitForTerminalOrBudget(context).getOrThrow()
    }

    private func waitForTerminalOrBudget(context: OperationContext): ?Http2ConnectionCloseResult {
        let registration = context.cancellation.register { => wakeCloseWaiters() }
        try {
            synchronized(mutex) {
                while (terminal.isNone()) {
                    if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                        return None<Http2ConnectionCloseResult>
                    }
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                terminal
            }
        } finally {
            registration.unregister()
        }
    }

    private func publishTerminal(value: Http2ConnectionCloseResult): Http2ConnectionCloseResult {
        synchronized(mutex) {
            if (terminal.isNone()) { terminal = Some(value) }
            phase = Http2ConnectionClosePhase.Terminal
            changed.notifyAll()
            terminal.getOrThrow()
        }
    }

    private func wakeCloseWaiters(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private func samePingPayload(left: Array<Byte>, right: Array<Byte>): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size) { if (left[index] != right[index]) { return false } }
    true
}

private func isHealthTerminal(value: Http2HealthState): Bool {
    match (value) {
        case Http2HealthState.Unhealthy | Http2HealthState.Closed => true
        case _ => false
    }
}

private func isCloseWriteWritten(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Written => true; case _ => false }
}

private func isCloseWriterClosed(value: Http2WriteSchedulerState): Bool {
    match (value) { case Http2WriteSchedulerState.Closed => true; case _ => false }
}

private func closeAbortReason(context: OperationContext): AbortReason {
    if (context.isCancellationRequested()) { AbortReason.Cancelled }
    else if (context.isDeadlineExceeded()) { AbortReason.DeadlineExceeded }
    else { AbortReason.ApplicationAbort }
}

private func isProtocolAbort(value: AbortReason): Bool {
    match (value) { case AbortReason.ProtocolFailure => true; case _ => false }
}
