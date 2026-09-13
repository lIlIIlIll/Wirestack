package wirestack.internal.http2

import std.sync.*
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
}

private class ClientPushOwnershipFixture {
    let source: Http2ClientPushSource
    let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
    let flow = Http2FlowController()
    let writer: Http2WriteScheduler
    let reset: Http2StreamResetManager
    let terminations = AtomicInt64(0)
    private let transport: MemoryTransport

    init() {
        let (owned, _) = MemoryTransport.pair()
        transport = owned
        writer = Http2WriteScheduler(transport)
        reset = Http2StreamResetManager(registry, flow, writer)
        source = Http2ClientPushSource(
            Http2PushConfig(
                AllowClientPushPolicy(), maximumConcurrentPushes: 2,
                maximumPendingPushes: 2, maximumPushesPerRequest: 2
            ),
            Http2StreamId(1u32), HttpUrl.parse("https://example.test/parent")
        )
    }

    func offer(id: UInt32, path: String): Http2ClientPushedExchange {
        let streamId = Http2StreamId(id)
        let _ = registry.reservePeer(streamId)
        flow.openStream(streamId)
        let exchange = Http2ClientPushedExchange(
            streamId,
            HttpRequest.get("https://example.test${path}"),
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

private func pushResponseFields(): Array<HpackHeaderField> {
    [
        HpackHeaderField(":status", "200"),
        HpackHeaderField("content-length", "0")
    ]
}
