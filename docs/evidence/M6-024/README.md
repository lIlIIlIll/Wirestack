# M6-024 discovery evidence

Date: 2026-08-27

## Status

READY. All declared dependencies are COMPLETE. This file records discovery
evidence only. It does not claim an implementation or a passing gate.

## Scope and affected platforms

- Task: eliminate HTTP/2 sibling starvation after one slow stream exhausts the
  connection window.
- Reproduced platform: native Arch Linux x86_64 with glibc, kernel
  `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003` with `cjnative`.
- cjpm: `1.1.3`.
- Windows, macOS, Android, iOS, and Harmony behavior is unverified.
- musl is outside the current SDK-supported Linux profile.

## Failed gate and reproduction

The M6-022 stability run repeated
`HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes` with a
five-second request deadline. A pre-fix invocation failed while reading a
2-byte sibling response:

```text
NetworkException: HTTP/2 operation deadline exceeded
at wirestack.internal.http2.Http2ClientBodyChannel.read
at wirestack.http/test.readPublicBody
at wirestack.http/test.HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes
```

The failing sequence was:

1. Open a 256-KiB response on one HTTP/2 stream.
2. Consume 4 KiB from that response.
3. Open a 2-byte sibling response on the same connection.
4. Read the sibling without cancelling or closing the first stream.

The repeated command exited 1 after one invocation reached the deadline. The
same run passed 100/100 only after M6-022 moved its sibling read after stream
cancellation. That change fixed the cancellation acceptance order. It did not
fix uncancelled sibling progress.

The retained command and exact result are in
[`docs/evidence/M6-022/README.md`](../M6-022/README.md#2026-08-27-stability-follow-up).

## Source diagnosis

- `Http2FlowController` starts with a 65,535-byte connection receive window.
- `consumeReceived` coalesces connection credit until half of the default
  window is consumed.
- The 4-KiB application read does not emit `WINDOW_UPDATE`.
- The large response can consume the remaining connection window before the
  sibling DATA frame becomes ready.
- The server then has no connection credit for the sibling body. The sibling
  waits until the first stream consumes enough data, closes, or is cancelled.

This is a flow-control liveness and DATA fairness defect. It is not a
cancellation-handle defect.

## Frozen implementation boundary

- Keep all changes inside Wirestack HTTP/2 internals and tests.
- Do not change public HTTP, cancellation, TLS, or transport declarations.
- Do not add a timeout owner or raise the five-second test deadline.
- Do not increase queue, window, stream, or body-buffer limits to hide the
  failure.
- Preserve coalesced `WINDOW_UPDATE` behavior for ordinary small reads. The fix
  must not create one control frame per application read.
- Keep control frames ahead of DATA and retain one bounded writer.

## Acceptance gate

M6-024 is COMPLETE only when all of these conditions pass:

1. A real TLS h2 loopback test reproduces the 256-KiB slow stream and 4-KiB
   consumption without cancelling or closing that stream.
2. One, ten, and one hundred 2-byte sibling responses complete within their
   own monotonic absolute deadlines on the same connection.
3. Deterministic scheduler and flow-control tests prove bounded progress under
   initial-window exhaustion and repeated `WINDOW_UPDATE`.
4. The retained frame counters show bounded `WINDOW_UPDATE` traffic. The write
   queue, connection window, stream window, and body buffers stay within their
   configured limits.
5. A 100-run race profile has no sibling timeout, connection abort, leaked
   stream, or duplicate terminal completion.
6. Raw sibling latency and flow-control-stall output records the environment,
   baseline, candidate, and an explicit PASS or FAIL decision.
7. Existing cancellation, SSE sibling-isolation, HTTP/2 conformance, and full
   `scripts/check` gates pass.

Native Linux evidence closes only the Linux cell. Other platform claims still
require execution on a real device or a native VM.
