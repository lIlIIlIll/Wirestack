package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Http2StreamLifecycleTest {
    @TestCase
    func bothEndStreamOrdersReachClosedExactlyOnce(): Unit {
        let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
        let localFirst = registry.openLocal()
        registry.localEnd(localFirst.id)
        @Expect(isHalfClosedLocal(localFirst.state))
        registry.peerEnd(localFirst.id)
        @Expect(isStreamTestClosed(localFirst.state))
        @Expect(localFirst.completionCount, 1)
        @Expect(registry.activeCount, 0)

        let remoteFirst = registry.openLocal()
        registry.peerEnd(remoteFirst.id)
        @Expect(isHalfClosedRemote(remoteFirst.state))
        registry.localEnd(remoteFirst.id)
        @Expect(isStreamTestClosed(remoteFirst.state))
        @Expect(remoteFirst.completionCount, 1)
    }

    @TestCase
    func initialEndStreamHalfClosesTheInitiatingSide(): Unit {
        let client = Http2StreamRegistry(Http2ConnectionRole.Client)
        let local = client.openLocal(endStream: true)
        @Expect(isHalfClosedLocal(local.state))
        client.peerEnd(local.id)

        let peer = client.openPeer(Http2StreamId(2u32), endStream: true)
        @Expect(isHalfClosedRemote(peer.state))
        client.localEnd(peer.id)
        @Expect(client.activeCount, 0)
    }

    @TestCase
    func clientAndServerAllocateCorrectMonotonicParity(): Unit {
        let client = Http2StreamRegistry(Http2ConnectionRole.Client)
        @Expect(client.openLocal().id.value, 1u32)
        @Expect(client.openLocal().id.value, 3u32)

        let server = Http2StreamRegistry(Http2ConnectionRole.Server)
        @Expect(server.openLocal().id.value, 2u32)
        @Expect(server.openLocal().id.value, 4u32)
        @Expect(server.openPeer(Http2StreamId(1u32)).id.value, 1u32)
        @Expect(server.openPeer(Http2StreamId(5u32)).id.value, 5u32)
    }

    @TestCase
    func peerParityReuseAndDecreasingIdsFailConnection(): Unit {
        let client = Http2StreamRegistry(Http2ConnectionRole.Client)
        expectStreamConnectionProtocol({ => let _ = client.openPeer(Http2StreamId(1u32)) })
        let first = client.openPeer(Http2StreamId(2u32))
        let _ = client.reset(first.id, Http2ErrorCode.Cancel, "test reset")
        expectStreamConnectionProtocol({ => let _ = client.openPeer(Http2StreamId(2u32)) })
        expectStreamConnectionProtocol({ => let _ = client.openPeer(Http2StreamId(0u32)) })
    }

    @TestCase
    func localAndPeerConcurrencyLimitsAreIndependentAndCapacityReturns(): Unit {
        let limits = Http2Limits(maxConcurrentStreams: 3u32)
        let registry = Http2StreamRegistry(Http2ConnectionRole.Client, limits: limits)
        registry.updatePeerMaxConcurrentStreams(1u32)
        registry.updateLocalMaxConcurrentStreams(2u32)
        let local = registry.openLocal()
        expectLocalStreamLimit({ => let _ = registry.openLocal() })

        let peerTwo = registry.openPeer(Http2StreamId(2u32))
        let peerFour = registry.openPeer(Http2StreamId(4u32))
        expectRefusedStream({ => let _ = registry.openPeer(Http2StreamId(6u32)) })
        expectStreamConnectionProtocol({ => let _ = registry.openPeer(Http2StreamId(6u32)) })
        @Expect(registry.activeCount, 3)

        let _ = registry.reset(local.id, Http2ErrorCode.Cancel, "release local capacity")
        @Expect(registry.openLocal().id.value, 3u32)
        let _ = registry.reset(peerTwo.id, Http2ErrorCode.Cancel, "release peer capacity")
        @Expect(registry.openPeer(Http2StreamId(8u32)).id.value, 8u32)
        let _ = peerFour
    }

    @TestCase
    func invalidHalfClosedDirectionsAndUnknownStreamsFailClosed(): Unit {
        let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
        let localClosed = registry.openLocal(endStream: true)
        expectLocalStreamState({ => registry.localEnd(localClosed.id) })

        let remoteClosed = registry.openPeer(Http2StreamId(2u32), endStream: true)
        expectStreamClosed({ => registry.peerEnd(remoteClosed.id) })
        expectStreamConnectionProtocol({ => registry.peerEnd(Http2StreamId(4u32)) })
        expectStreamConnectionProtocol({ => registry.peerEnd(Http2StreamId(3u32)) })
    }

    @TestCase
    func readerTerminationClosesAndUnregistersEveryActiveStream(): Unit {
        let terminations = Http2ReaderTerminationRegistry(4u32)
        let registry = Http2StreamRegistry(
            Http2ConnectionRole.Client,
            limits: Http2Limits(maxConcurrentStreams: 4u32),
            terminationRegistry: Some(terminations)
        )
        let first = registry.openLocal()
        let second = registry.openPeer(Http2StreamId(2u32))
        @Expect(terminations.activeCount, 1)
        let completion = Http2ConnectionCompletion(Http2ErrorCode.InternalError, "reader stopped")
        @Expect(terminations.terminate(completion))
        @Expect(registry.activeCount, 0)
        @Expect(isStreamTestClosed(first.state))
        @Expect(isStreamTestClosed(second.state))
        @Expect(first.completionCount, 1)
        @Expect(second.completionCount, 1)
        @Expect(terminations.activeCount, 0)
        @Expect(registry.completion.isSome())
        expectLocalStreamState({ => let _ = registry.openLocal() })

        let alreadyTerminal = Http2ReaderTerminationRegistry(1u32)
        let _ = alreadyTerminal.terminate(completion)
        let late = Http2StreamRegistry(
            Http2ConnectionRole.Client,
            terminationRegistry: Some(alreadyTerminal)
        )
        @Expect(late.completion.isSome())
        @Expect(alreadyTerminal.activeCount, 0)

        let explicitTerminations = Http2ReaderTerminationRegistry(1u32)
        let explicit = Http2StreamRegistry(
            Http2ConnectionRole.Client,
            terminationRegistry: Some(explicitTerminations)
        )
        @Expect(explicitTerminations.activeCount, 1)
        @Expect(explicit.closeConnection(completion))
        @Expect(!explicit.closeConnection(completion))
        @Expect(explicitTerminations.activeCount, 0)
    }

    @TestCase
    func racingAdmissionNeverExceedsConfiguredBoundOrDuplicatesIds(): Unit {
        let registry = Http2StreamRegistry(
            Http2ConnectionRole.Client,
            limits: Http2Limits(maxConcurrentStreams: 16u32)
        )
        let admitted = AtomicInt64(0)
        let tasks = ArrayList<Future<Unit>>()
        for (_ in 0..64) {
            tasks.add(spawn {
                try { let _ = registry.openLocal(); let _ = admitted.fetchAdd(1) }
                catch (_: Http2StreamLimitException) {}
            })
        }
        for (task in tasks) { task.get(Duration.second) }
        @Expect(admitted.load(), 16)
        @Expect(registry.activeLocalCount, 16)
        @Expect(registry.activeCount, 16)
        for (odd in 0..16) {
            @Expect(registry.stream(Http2StreamId(UInt32(odd * 2 + 1))).isSome())
        }
    }

    @TestCase
    func racingEndDirectionsCompleteAndCleanupExactlyOnce(): Unit {
        for (_ in 0..100) {
            let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
            let stream = registry.openLocal()
            let local = spawn { registry.localEnd(stream.id) }
            let peer = spawn { registry.peerEnd(stream.id) }
            local.get(Duration.second)
            peer.get(Duration.second)
            @Expect(isStreamTestClosed(stream.state))
            @Expect(stream.completionCount, 1)
            @Expect(registry.activeCount, 0)
        }
    }
}

private func expectStreamConnectionProtocol(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        matched = http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(Http2ErrorCode.ProtocolError) &&
            isConnectionScope(error.scope)
    }
    @Expect(matched)
}

private func expectRefusedStream(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        matched = http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(Http2ErrorCode.RefusedStream)
    }
    @Expect(matched)
}

private func expectStreamClosed(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        matched = http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(Http2ErrorCode.StreamClosed)
    }
    @Expect(matched)
}

private func expectLocalStreamLimit(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: Http2StreamLimitException) { matched = true }
    @Expect(matched)
}

private func expectLocalStreamState(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: IllegalStateException) { matched = true }
    @Expect(matched)
}

private func isConnectionScope(value: Http2ErrorScope): Bool {
    match (value) { case Http2ErrorScope.Connection => true; case _ => false }
}

private func isHalfClosedLocal(value: Http2StreamState): Bool {
    match (value) { case Http2StreamState.HalfClosedLocal => true; case _ => false }
}

private func isHalfClosedRemote(value: Http2StreamState): Bool {
    match (value) { case Http2StreamState.HalfClosedRemote => true; case _ => false }
}

private func isStreamTestClosed(value: Http2StreamState): Bool {
    match (value) { case Http2StreamState.Closed => true; case _ => false }
}
