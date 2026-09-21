package wirestack.tls

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class TlsContextVersioningTest {
    @TestCase
    func replacementUsesNewEpochAndRetainsOldSnapshot(): Unit {
        let first = TlsClientContext.builder().build()
        let second = TlsClientContext.builder().build()
        @Expect(second.version > first.version)
        let store = TlsClientContextStore(first)
        let held = store.snapshot()
        @Expect(store.replace(second), second.version)
        @Expect(held.version, first.version)
        @Expect(store.snapshot().version, second.version)
    }

    @TestCase
    func externalHooksReceiveTheCallerOperationContext(): Unit {
        let decryptor = RecordingDecryptor()
        let sink = RecordingKeyLogSink()
        let context = TlsClientContext.builder()
            .externalDecryptor(decryptor)
            .keyLogSink(sink)
            .build()
        @Expect(context.externalDecryptor.isSome())
        @Expect(context.keyLogSink.isSome())

        let cancellation = api.CancellationSource()
        cancellation.cancel()
        let operation = api.OperationContext(cancellation: cancellation.token)
        let request = api.ExternalDecryptionRequest("test", [1u8, 2u8])
        let output = decryptor.decrypt(request, operation)
        @Expect(output, [1u8, 2u8])
        @Expect(decryptor.sawCancellation)
        sink.emit(api.TlsKeyLogLine("CLIENT_TRAFFIC_SECRET_0", [3u8], [4u8]), operation)
        @Expect(sink.sawCancellation)
    }
}

private class RecordingDecryptor <: api.ExternalDecryptor {
    var sawCancellation = false

    public func decrypt(
        request: api.ExternalDecryptionRequest,
        context: api.OperationContext
    ): Array<Byte> {
        sawCancellation = context.isCancellationRequested()
        request.ciphertextBytes()
    }
}

private class RecordingKeyLogSink <: api.KeyLogSink {
    var sawCancellation = false

    public func emit(line: api.TlsKeyLogLine, context: api.OperationContext): Unit {
        let _ = line.label
        sawCancellation = context.isCancellationRequested()
    }
}
