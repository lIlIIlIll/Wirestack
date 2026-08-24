package wirestack.internal.connector

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

public struct AttemptDiagnostic {
    public let candidate: ConnectCandidate
    public let startedAt: MonoTime
    public let completedAt: MonoTime
    public let error: ?NetworkException
    public let won: Bool

    public init(
        candidate: ConnectCandidate,
        startedAt: MonoTime,
        completedAt: MonoTime,
        error: ?NetworkException,
        won: Bool
    ) {
        this.candidate = candidate
        this.startedAt = startedAt
        this.completedAt = completedAt
        this.error = error
        this.won = won
    }
}

public struct ConnectDiagnostics {
    private let ownedAttempts: Array<AttemptDiagnostic>
    public let dns: ResolveDiagnostics
    public let winner: SocketEndpoint
    public let completedAt: MonoTime

    public init(
        attempts: Array<AttemptDiagnostic>,
        dns: ResolveDiagnostics,
        winner: SocketEndpoint,
        completedAt: MonoTime
    ) {
        ownedAttempts = attempts.clone()
        this.dns = dns
        this.winner = winner
        this.completedAt = completedAt
    }

    public prop attempts: Array<AttemptDiagnostic> {
        get() { ownedAttempts.clone() }
    }
}

public struct ConnectResult {
    public let transport: DuplexTransport
    public let diagnostics: ConnectDiagnostics

    public init(transport: DuplexTransport, diagnostics: ConnectDiagnostics) {
        this.transport = transport
        this.diagnostics = diagnostics
    }
}

public class ConnectException <: NetworkException {
    private let ownedAttempts: Array<AttemptDiagnostic>

    public init(code: NetworkErrorCode, message: String, attempts: Array<AttemptDiagnostic>) {
        super(
            NetworkErrorCategory.Connect,
            NetworkPhase.TcpConnect,
            code,
            message,
            retryability: Retryability.SafeBeforeWrite
        )
        ownedAttempts = attempts.clone()
    }

    public prop attempts: Array<AttemptDiagnostic> {
        get() { ownedAttempts.clone() }
    }

    protected override func getClassName(): String {
        "ConnectException"
    }
}

/** RFC 8305-style multi-attempt connector with bounded, joined candidates. */
public class HappyEyeballsConnector {
    private let resolver: Resolver
    private let attemptFactory: TransportFactory
    private let attemptDelay: Duration

    public init(
        resolver: Resolver,
        attemptFactory: TransportFactory,
        attemptDelay!: Duration = 250 * Duration.millisecond
    ) {
        if (attemptDelay < Duration.Zero) {
            throw IllegalArgumentException("attemptDelay must be non-negative")
        }
        this.resolver = resolver
        this.attemptFactory = attemptFactory
        this.attemptDelay = attemptDelay
    }

    public func connect(
        host: HostName,
        port: UInt16,
        options!: ResolveOptions = ResolveOptions(),
        context!: OperationContext = OperationContext.background()
    ): ConnectResult {
        checkConnectContext(context)
        emitNetworkEvent(context, NetworkEvent(
            NetworkEventKind.DnsStarted,
            NetworkEventOutcome.Started,
            trace: context.trace,
            phase: Some(NetworkPhase.Dns)
        ))
        let resolved = try {
            let value = resolver.resolve(host, None<String>, options, context)
            emitNetworkEvent(context, NetworkEvent(
                NetworkEventKind.DnsCompleted,
                NetworkEventOutcome.Succeeded,
                trace: context.trace,
                phase: Some(NetworkPhase.Dns)
            ))
            value
        } catch (error: Exception) {
            emitFailedEvent(context, NetworkEventKind.DnsCompleted, NetworkPhase.Dns, error)
            throw error
        }
        checkConnectContext(context)
        let plan = buildAttemptPlan(resolved.addresses, port, attemptDelay: attemptDelay)
        runPlan(plan, resolved.diagnostics, context)
    }

    private func runPlan(
        plan: AttemptPlan,
        dns: ResolveDiagnostics,
        parent: OperationContext
    ): ConnectResult {
        let candidates = plan.candidates
        let coordinator = AttemptCoordinator(candidates.size, parent)
        let attemptCancellation = CancellationSource()
        let parentRegistration = parent.cancellation.register { =>
            attemptCancellation.cancel()
            coordinator.wake()
        }
        let futures = ArrayList<Future<Unit>>()

        try {
            for (candidate in candidates) {
                let future: Future<Unit> = spawn {
                    runCandidate(
                        candidate,
                        plan.attemptDelay,
                        coordinator,
                        attemptCancellation.token,
                        parent
                    )
                }
                futures.add(future)
            }

            let outcome = coordinator.awaitOutcome()
            attemptCancellation.cancel()
            coordinator.wake()
            for (future in futures) {
                future.get()
            }

            match (outcome) {
                case Some(winner) =>
                    emitNetworkEvent(parent, NetworkEvent(
                        NetworkEventKind.TcpConnected,
                        NetworkEventOutcome.Succeeded,
                        trace: parent.trace,
                        phase: Some(NetworkPhase.TcpConnect)
                    ))
                    ConnectResult(
                        winner.transport,
                        ConnectDiagnostics(
                            coordinator.diagnostics(),
                            dns,
                            winner.candidate.endpoint,
                            MonoTime.now()
                        )
                    )
                case None => throw coordinator.failure()
            }
        } finally {
            attemptCancellation.cancel()
            coordinator.wake()
            parentRegistration.unregister()
        }
    }

    private func runCandidate(
        candidate: ConnectCandidate,
        delay: Duration,
        coordinator: AttemptCoordinator,
        cancellation: CancellationToken,
        parent: OperationContext
    ): Unit {
        let scheduledAt = coordinator.startedAt + candidate.ordinal * delay
        try {
            if (!coordinator.awaitStart(scheduledAt, cancellation)) {
                coordinator.recordSkipped(candidate, MonoTime.now())
                return
            }
            let startedAt = MonoTime.now()
            let child = OperationContext(
                deadline: parent.deadline,
                cancellation: cancellation,
                trace: parent.trace,
                eventSink: parent.eventSink
            )
            emitNetworkEvent(parent, NetworkEvent(
                NetworkEventKind.ConnectAttemptStarted,
                NetworkEventOutcome.Started,
                trace: parent.trace,
                phase: Some(NetworkPhase.TcpConnect)
            ))
            try {
                let connected = attemptFactory.connect(candidate.endpoint, child)
                emitNetworkEvent(parent, NetworkEvent(
                    NetworkEventKind.ConnectAttemptCompleted,
                    NetworkEventOutcome.Succeeded,
                    trace: parent.trace,
                    phase: Some(NetworkPhase.TcpConnect)
                ))
                let won = coordinator.tryWin(candidate, connected, startedAt, MonoTime.now())
                if (!won) {
                    connected.abort(reason: Some(AbortReason.ApplicationAbort))
                }
            } catch (error: NetworkException) {
                emitFailedEvent(parent, NetworkEventKind.ConnectAttemptCompleted,
                    NetworkPhase.TcpConnect, error)
                coordinator.recordFailure(candidate, startedAt, MonoTime.now(), error)
            } catch (error: Exception) {
                emitFailedEvent(parent, NetworkEventKind.ConnectAttemptCompleted,
                    NetworkPhase.TcpConnect, error)
                coordinator.recordFailure(
                    candidate,
                    startedAt,
                    MonoTime.now(),
                    NetworkException(
                        NetworkErrorCategory.Connect,
                        NetworkPhase.TcpConnect,
                        NetworkErrorCode.SystemFailure,
                        "connect attempt failed with an unclassified exception",
                        cause: Some(error)
                    )
                )
            }
        } finally {
            coordinator.completeAttempt()
        }
    }
}

private func emitFailedEvent(context: OperationContext, kind: NetworkEventKind,
    phase: NetworkPhase, error: Exception): Unit {
    let code = match (error) {
        case value: NetworkException => Some(value.code)
        case _ => Some(NetworkErrorCode.SystemFailure)
    }
    emitNetworkEvent(context, NetworkEvent(
        kind,
        NetworkEventOutcome.Failed,
        trace: context.trace,
        phase: Some(phase),
        errorCode: code
    ))
}

private struct Winner {
    let candidate: ConnectCandidate
    let transport: DuplexTransport

    init(candidate: ConnectCandidate, transport: DuplexTransport) {
        this.candidate = candidate
        this.transport = transport
    }
}

private class AttemptCoordinator {
    let startedAt = MonoTime.now()
    private let expected: Int64
    private let parent: OperationContext
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var completed: Int64 = 0
    private var winner: ?Winner = None<Winner>
    private let records = ArrayList<AttemptDiagnostic>()

    init(expected: Int64, parent: OperationContext) {
        this.expected = expected
        this.parent = parent
    }

    func awaitStart(scheduledAt: MonoTime, cancellation: CancellationToken): Bool {
        synchronized(mutex) {
            while (winner.isNone() && !cancellation.isCancellationRequested) {
                if (parent.isDeadlineExceeded()) {
                    return false
                }
                let now = MonoTime.now()
                if (now >= scheduledAt) {
                    return true
                }
                let delayRemaining = scheduledAt - now
                let waitFor = match (parent.deadline) {
                    case Some(deadline) => min(delayRemaining, deadline.remaining())
                    case None => delayRemaining
                }
                if (waitFor <= Duration.Zero) {
                    return false
                }
                changed.wait(timeout: waitFor)
            }
            false
        }
    }

    func tryWin(
        candidate: ConnectCandidate,
        transport: DuplexTransport,
        started: MonoTime,
        completedAt: MonoTime
    ): Bool {
        synchronized(mutex) {
            if (winner.isNone() && !parent.isCancellationRequested() && !parent.isDeadlineExceeded()) {
                winner = Some(Winner(candidate, transport))
                records.add(AttemptDiagnostic(candidate, started, completedAt, None<NetworkException>, true))
                changed.notifyAll()
                true
            } else {
                records.add(AttemptDiagnostic(candidate, started, completedAt, None<NetworkException>, false))
                false
            }
        }
    }

    func recordFailure(
        candidate: ConnectCandidate,
        started: MonoTime,
        completedAt: MonoTime,
        error: NetworkException
    ): Unit {
        synchronized(mutex) {
            records.add(AttemptDiagnostic(candidate, started, completedAt, Some(error), false))
            changed.notifyAll()
        }
    }

    func recordSkipped(candidate: ConnectCandidate, at: MonoTime): Unit {
        let code = if (parent.isDeadlineExceeded()) {
            NetworkErrorCode.TimedOut
        } else {
            NetworkErrorCode.Cancelled
        }
        let error = NetworkException(
            NetworkErrorCategory.Connect,
            NetworkPhase.TcpConnect,
            code,
            "connect candidate did not start after cancellation, deadline, or winner selection",
            retryability: Retryability.Never
        )
        synchronized(mutex) {
            records.add(AttemptDiagnostic(candidate, at, at, Some(error), false))
            changed.notifyAll()
        }
    }

    func completeAttempt(): Unit {
        synchronized(mutex) {
            completed++
            changed.notifyAll()
        }
    }

    func awaitOutcome(): ?Winner {
        synchronized(mutex) {
            while (winner.isNone() && completed < expected) {
                if (parent.isCancellationRequested() || parent.isDeadlineExceeded()) {
                    return None<Winner>
                }
                match (parent.deadline) {
                    case Some(deadline) =>
                        let waitFor = deadline.remaining()
                        if (waitFor <= Duration.Zero) {
                            return None<Winner>
                        }
                        changed.wait(timeout: waitFor)
                    case None => changed.wait()
                }
            }
            winner
        }
    }

    func diagnostics(): Array<AttemptDiagnostic> {
        synchronized(mutex) {
            let ordered = ArrayList<AttemptDiagnostic>()
            for (ordinal in 0..expected) {
                for (record in records) {
                    if (record.candidate.ordinal == ordinal) {
                        ordered.add(record)
                        break
                    }
                }
            }
            ordered.toArray()
        }
    }

    func failure(): ConnectException {
        let attempts = diagnostics()
        if (parent.isCancellationRequested()) {
            return ConnectException(NetworkErrorCode.Cancelled, "connection cancelled", attempts)
        }
        if (parent.isDeadlineExceeded()) {
            return ConnectException(NetworkErrorCode.TimedOut, "connection deadline exceeded", attempts)
        }
        ConnectException(NetworkErrorCode.SystemFailure, "all connection attempts failed", attempts)
    }

    func wake(): Unit {
        synchronized(mutex) { changed.notifyAll() }
    }
}

private func checkConnectContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw ConnectException(NetworkErrorCode.Cancelled, "connection cancelled before start", Array<AttemptDiagnostic>())
    }
    if (context.isDeadlineExceeded()) {
        throw ConnectException(NetworkErrorCode.TimedOut, "connection deadline exceeded before start", Array<AttemptDiagnostic>())
    }
}
