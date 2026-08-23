package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.transport.*

@Test
class Http1ServerTest {
    @TestCase
    func gracefulShutdownStopsAcceptAfterCompletedConnection(): Unit {
        let listener = Http1TestListener()
        let (client, accepted) = MemoryTransport.pair(capacity: 4096)
        listener.enqueue(accepted)
        let server = Http1Server(listener, Http1StaticHandler(),
            config: Http1ServerConfig(maximumConnections: 1))
        let serving: Future<Unit> = spawn { server.serve() }
        listener.waitForAccepted(1)

        let request = HttpRequest(HttpMethod("GET"), HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder().add("Connection", "close").build())
        let _ = writeHttp1Request(client, request)
        let response = readHttp1Response(client, request.method)
        @Expect(response.response.status, 200)
        response.response.close()

        let result = server.shutdown(context: OperationContext(
            deadline: Some(Deadline.after(Duration.second))))
        @Expect(result.aborted, 0)
        @Expect(result.activeAtReturn, 0)
        serving.get(Duration.second)
        @Expect(server.isClosed())
        client.close()
    }

    @TestCase
    func expiredShutdownAbortsBlockedConnectionAndReturnsBoundedly(): Unit {
        let listener = Http1TestListener()
        let (client, accepted) = MemoryTransport.pair(capacity: 4096)
        listener.enqueue(accepted)
        let server = Http1Server(listener, Http1StaticHandler(),
            config: Http1ServerConfig(maximumConnections: 1))
        let serving: Future<Unit> = spawn { server.serve() }
        listener.waitForAccepted(1)

        let result = server.shutdown(context: OperationContext(
            deadline: Some(Deadline.after(5 * Duration.millisecond))))
        @Expect(result.aborted, 1)
        let drained = server.shutdown(context: OperationContext(
            deadline: Some(Deadline.after(Duration.second))))
        @Expect(drained.activeAtReturn, 0)
        serving.get(Duration.second)
        client.close()
    }

    @TestCase
    func connectionLimitPreventsSecondAcceptUntilCapacityReturns(): Unit {
        let listener = Http1TestListener()
        let (firstClient, firstAccepted) = MemoryTransport.pair(capacity: 4096)
        let (secondClient, secondAccepted) = MemoryTransport.pair(capacity: 4096)
        listener.enqueue(firstAccepted)
        listener.enqueue(secondAccepted)
        let server = Http1Server(listener, Http1StaticHandler(),
            config: Http1ServerConfig(maximumConnections: 1))
        let serving: Future<Unit> = spawn { server.serve() }
        listener.waitForAccepted(1)

        var secondAcceptedTooSoon = true
        try { listener.waitForAccepted(2, timeout: 5 * Duration.millisecond) }
        catch (_: Exception) { secondAcceptedTooSoon = false }
        @Expect(!secondAcceptedTooSoon)

        firstClient.close()
        listener.waitForAccepted(2)
        server.close()
        serving.get(Duration.second)
        secondClient.close()
    }
}

private class Http1StaticHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = request
        let _ = context
        Http1ServerResponse(HttpResponse(200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()))
    }
}

private class Http1TestListener <: TransportListener {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var pending = ArrayList<DuplexTransport>()
    private var accepted: Int64 = 0
    private var closed = false

    func enqueue(transport: DuplexTransport): Unit {
        synchronized(mutex) { pending.add(transport); changed.notifyAll() }
    }

    public func accept(context: OperationContext): DuplexTransport {
        let registration = context.cancellation.register({ => synchronized(mutex) { changed.notifyAll() } })
        try {
            synchronized(mutex) {
                while (pending.isEmpty() && !closed) {
                    if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                        throw Exception("test accept cancelled")
                    }
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                if (closed) { throw Exception("test listener closed") }
                accepted++
                changed.notifyAll()
                pending.remove(at: 0)
            }
        } finally {
            registration.unregister()
        }
    }

    public func close(): Unit {
        let leftovers = synchronized(mutex) {
            if (closed) { return }
            closed = true
            let values = pending
            pending = ArrayList<DuplexTransport>()
            changed.notifyAll()
            values
        }
        for (transport in leftovers) { transport.close() }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    func waitForAccepted(expected: Int64, timeout!: Duration = Duration.second): Unit {
        let deadline = Deadline.after(timeout)
        synchronized(mutex) {
            while (accepted < expected) {
                if (deadline.isExpired()) { throw Exception("accept count timed out") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
}
