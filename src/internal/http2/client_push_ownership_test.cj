package wirestack.internal.http2

import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http2ClientPushOwnershipTest {
    @TestCase
    func resetLostOfferIsClosedAndNextOfferRemainsDeliverable(): Unit {
        let fixture = ClientPushOwnershipFixture()
        let resetLost = fixture.offer(2u32, "/lost")
        let deliverable = fixture.offer(4u32, "/next")
        resetLost.acceptHeaders(pushResponseFields(), false)
        deliverable.acceptHeaders(pushResponseFields(), true)

        // Deterministically split receive's await and ownership claim around a real peer reset.
        let untransferred = resetLost.awaitResponse(OperationContext.background())
        @Expect(fixture.reset.acceptPeer(encodeHttp2RstStream(
            resetLost.streamId, Http2ErrorCode.Cancel
        )))
        @Expect(!fixture.source.claimAfterAwait(resetLost, untransferred))
        @Expect(untransferred.isClosed())

        let pushed = fixture.source.receive(
            context: OperationContext.background()
        ).getOrThrow()
        @Expect(pushed.request.url.toString(), "https://example.test/next")
        @Expect(pushed.response.body.read(Array<Byte>(1, repeat: 0u8)), 0)
        pushed.close()
        fixture.source.parentFinished()

        @Expect(fixture.source.receive(
            context: OperationContext.background()
        ).isNone())
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
        @Expect(fixture.terminations.load(), 2)
    }

    @TestCase
    func parentCancellationStopsTransferredStalledBodyWithoutCancellingIndependentSibling(): Unit {
        let cancellation = CancellationSource()
        let cancelledFixture = ClientPushOwnershipFixture(
            context: OperationContext(cancellation: cancellation.token)
        )
        let siblingFixture = ClientPushOwnershipFixture()
        let stalled = cancelledFixture.offer(2u32, "/stalled")
        let sibling = siblingFixture.offer(2u32, "/sibling")
        stalled.acceptHeaders(pushResponseFields(contentLength: 1), false)
        sibling.acceptHeaders(pushResponseFields(contentLength: 1), false)
        cancelledFixture.source.parentFinished()
        siblingFixture.source.parentFinished()

        let cancelledPush = cancelledFixture.source.receive().getOrThrow()
        let siblingPush = siblingFixture.source.receive().getOrThrow()
        let releaseBaselineRead = cancellation.token.register { =>
            stalled.acceptData(pushData(stalled.streamId, b'x'))
        }
        let cancelledRead = spawn { pushBodyReadWasCancelled(cancelledPush.response.body) }
        cancellation.cancel()
        sibling.acceptData(pushData(sibling.streamId, b's'))

        @Expect(cancelledRead.get(Duration.second))
        let siblingBytes = Array<Byte>(1, repeat: 0u8)
        @Expect(siblingPush.response.body.read(siblingBytes), 1)
        @Expect(siblingBytes[0], b's')
        @Expect(siblingPush.response.body.read(siblingBytes), 0)
        releaseBaselineRead.unregister()
        cancelledPush.close()
        siblingPush.close()
        @Expect(cancelledFixture.registry.activeCount, 0)
        @Expect(cancelledFixture.flow.activeStreamCount, 0)
        @Expect(cancelledFixture.terminations.load(), 1)
        @Expect(siblingFixture.registry.activeCount, 0)
        @Expect(siblingFixture.flow.activeStreamCount, 0)
        @Expect(siblingFixture.terminations.load(), 1)
    }

    @TestCase
    func expiredParentAbsoluteDeadlineStillGovernsTransferredBodyAfterHeaders(): Unit {
        let clock = PushContextClock(MonoTime.now())
        let parentDeadline = Deadline.after(Duration.second, clock: clock)
        let fixture = ClientPushOwnershipFixture(
            context: OperationContext(deadline: Some(parentDeadline))
        )
        let exchange = fixture.offer(2u32, "/deadline")
        exchange.acceptHeaders(pushResponseFields(contentLength: 1), false)
        fixture.source.parentFinished()
        let pushed = fixture.source.receive().getOrThrow()

        clock.advance(Duration.second)
        exchange.acceptData(pushData(exchange.streamId, b'd'))

        @Expect(pushBodyReadExceededDeadline(pushed.response.body))
        pushed.close()
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
        @Expect(fixture.terminations.load(), 1)
    }
}

private class ClientPushOwnershipFixture {
    let source: Http2ClientPushSource
    let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
    let flow = Http2FlowController()
    let writer: Http2WriteScheduler
    let reset: Http2StreamResetManager
    let terminations = AtomicInt64(0)
    private let transport: MemoryTransport

    init(context!: OperationContext = OperationContext.background()) {
        let (owned, _) = MemoryTransport.pair()
        transport = owned
        writer = Http2WriteScheduler(transport)
        reset = Http2StreamResetManager(registry, flow, writer)
        source = Http2ClientPushSource(
            Http2PushConfig(
                AllowClientPushPolicy(), maximumConcurrentPushes: 2,
                maximumPendingPushes: 2, maximumPushesPerRequest: 2
            ),
            Http2StreamId(1u32), HttpUrl.parse("https://example.test/parent"),
            context
        )
    }

    func offer(id: UInt32, path: String): Http2ClientPushedExchange {
        let streamId = Http2StreamId(id)
        let _ = registry.reservePeer(streamId)
        flow.openStream(streamId)
        let exchange = Http2ClientPushedExchange(
            streamId,
            HttpRequest.get("https://example.test${path}"),
            source.parentContext,
            source,
            registry,
            flow,
            writer,
            reset,
            HttpLimits(),
            Http2Limits(),
            { _ => let _ = terminations.fetchAdd(1) }
        )
        exchange.bindReset(reset.register(streamId, exchange))
        if (!source.admit(exchange)) {
            throw Exception("push ownership fixture failed to admit an offer")
        }
        exchange
    }
}

private class AllowClientPushPolicy <: Http2PushPolicy {
    public func allow(
        parent: HttpUrl,
        promised: HttpUrl,
        context: OperationContext
    ): Bool {
        let _ = parent
        let _ = promised
        let _ = context
        true
    }
}

private class PushContextClock <: MonotonicClock {
    private var current: MonoTime
    init(start: MonoTime) { current = start }
    public func now(): MonoTime { current }
    func advance(value: Duration): Unit { current += value }
}

private func pushResponseFields(contentLength!: Int64 = 0): Array<HpackHeaderField> {
    [
        HpackHeaderField(":status", "200"),
        HpackHeaderField("content-length", "${contentLength}")
    ]
}

private func pushData(streamId: Http2StreamId, value: Byte): Http2Frame {
    Http2Frame(
        Http2FrameHeader(
            1u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8), streamId
        ),
        [value]
    )
}

private func pushBodyReadWasCancelled(body: ResponseBody): Bool {
    try {
        let _ = body.read(Array<Byte>(1, repeat: 0u8))
        false
    } catch (error: NetworkException) {
        match (error.code) {
            case NetworkErrorCode.Cancelled => true
            case _ => false
        }
    }
}

private func pushBodyReadExceededDeadline(body: ResponseBody): Bool {
    try {
        let _ = body.read(Array<Byte>(1, repeat: 0u8))
        false
    } catch (error: NetworkException) {
        match (error.category) {
            case NetworkErrorCategory.DeadlineExceeded => true
            case _ => false
        }
    }
}
