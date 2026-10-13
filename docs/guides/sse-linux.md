# Bounded SSE on Linux

Import `wirestack.sse` alongside `wirestack` and `wirestack.http`. The codec and
HTTP adapter are opt-in; ordinary HTTP requests do not enable reconnection.
The [native example](../../examples/linux/m11_001/sse.cj) is compiled and run
against an extracted installation, without checkout include or library paths,
by `python3 tools/m11_001_native_sse.py`.

## Receive events

`SseSession.eventSource(client, url, policy:, context:)` submits GET requests.
The default `SseSessionPolicy.maximumReconnects` is zero. Each `receive()` returns
the next complete `SseEvent` or `None` at graceful completion. There is no decoded
event queue. The session does not own the supplied client.

To opt into recovery, set finite `maximumReconnects` and `maximumDuration`.
The duration shortens the caller's monotonic absolute deadline. Admission, DNS,
pool acquisition, TCP, proxy, TLS, headers, body reads and backoff retain the same
cancellation and deadline. Optional `bodyReadIdle` takes the smaller of the
supplied cap and `OperationTimeoutPolicy.bodyReadIdle`; it constrains an active
body read, not application processing time between `receive()` calls.

Policy defaults: five-minute total duration, one-second initial retry delay,
50-millisecond minimum, 30-second maximum and symmetric jitter of 200
thousandths. A valid wire `retry` field replaces the base delay within these
bounds. Hard ceilings: 1000 reconnects, 24-hour duration, one-hour maximum
backoff. There is no infinite reconnect mode.

Recovery covers graceful GET stream end and recoverable transport failures,
including prematurely terminated HTTP chunk framing. Malformed framing,
invalid response metadata, codec limits, cancellation and expiry are fatal.
HTTP 200 requires MIME `text/event-stream`, with optional parameters. HTTP 204
ends without another GET. Redirects are not followed.

The parsed `lastEventId` becomes `Last-Event-ID` on a subsequent GET. A
blank-line-terminated id-only block can update it without dispatching data;
an incomplete block at EOF cannot. An empty id clears it, and an id containing
NUL is ignored. **Parsing a cursor is not acknowledgement of application
processing.** Duplicate ids and events remain possible. Applications own
deduplication and processing checkpoints; there is no Exactly-once contract.

## POST and other one-shot streams

`SseSession.oneShot(client, request, policy:, context:)` sends the request once,
including POST. It never follows redirects or resubmits a body, even when the
body is replayable, the request is `HttpRetrySafety.ExplicitlySafe`, or the
policy permits GET reconnects. Clean EOF returns `None`. Premature framed EOF
retains a typed `NetworkException(UnexpectedEof)` cause under the terminal
`SseException(ReconnectLimit)`; it is not successful EOF.

`HttpClient.sendOnce` supplies the underlying no-retry/no-redirect operation.
Ordinary `send` retains its existing retry and redirect policies.

## Decode bounded input

`SseDecoder.decode(bytes, offset:, length:)` accepts arbitrary input cuts,
including cuts inside UTF-8, a BOM and CRLF. Its result's `consumed` count is
relative to that window. Preserve its unconsumed bytes and submit them on the
next call. `finish()` discards incomplete state without dispatching it;
`close()` releases retained storage.

The decoder replaces malformed UTF-8 with U+FFFD, strips one initial BOM,
accepts CR/LF/CRLF, joins data lines with LF, and dispatches empty data fields.
It removes at most one space after a colon. Names are case-sensitive. Comments
and unknown fields do not dispatch. Empty event names select `message`. Retry
accepts ASCII digits only and saturates/clamps instead of overflowing. Payloads
are opaque: `[DONE]` and similar markers have no special meaning.

| Bound | Default | Hard ceiling |
|---|---:|---:|
| Raw line bytes, excluding terminator/initial BOM | 16,384 | 1,048,576 |
| Raw block bytes, including terminators | 262,144 | 16,777,216 |
| Nonempty fields per block, including comments/unknown fields | 1,024 | 65,536 |
| Wire bytes without a dispatched event | 1,048,576 | 67,108,864 |
| Decoded cursor UTF-8 bytes | 4,096 | 65,536 |
| Accepted retry milliseconds | 60,000 | 86,400,000 |

CRLF counts as one block terminator but two no-progress wire bytes. These are
byte counts, not character counts. Increasing a limit changes resource policy;
it does not justify accumulating more events.

Before allocation or request submission, the session reserves
`SseLimits.maximumRetainedBytes + readBufferBytes` from the **same client's**
managed DATA ledger. The read buffer defaults to 16,384 bytes and is bounded
from 1 through 1,048,576. The conservative decoder reservation is
`12 * maximumEventBytes + 18 * maximumLineBytes + 6 * maximumIdBytes + 256`.
Caller-owned inputs and returned events are excluded. Default session
reservation: 3,481,856 bytes. `HttpResourceSnapshot.managedBufferBytes` reports
this real lease with route/origin attribution. Close, EOF, invalid MIME,
cancellation and failure release it.

`HttpClient.reserveResponseBuffer(url, bytes, context:)` also admits other
bounded response consumers through the existing bounded admission queue.
Zero bytes or a reservation larger than the instance DATA, route or origin
capacity fails immediately instead of waiting for impossible capacity.
HTTP/2 control/cleanup reserves are unavailable to consumers. Release the
returned `HttpResourceLease` in ownership cleanup; repeated close is safe.

## Publish a server stream

`SseEncoder.encode(SseEvent(...), retryMilliseconds:)` produces a complete UTF-8
block. `comment(text)` produces comment blocks. Metadata rejects CR, LF and
NUL. Data permits LF but rejects CR. Empty event types are rejected because
they cannot round-trip; empty data still dispatches. Retry is clamped. All
encoded line, block and field bounds are checked before result allocation.

Use `SseWriter` through `ResponseBody(writer)` as the HTTP response body, with
`Content-Type: text/event-stream`. Use chunked transfer framing for HTTP/1.1
streaming; never add `Transfer-Encoding` to an HTTP/2 response. The tested
native example provides handlers for both protocols.

The writer permits one active producer and one active body reader. Its byte
ring defaults to 65,536 bytes, with a 1,048,576-byte ceiling. A full ring applies
backpressure. The sole producer retains at most one bounded encoded block.
Produce outside the handler's response-return path: waiting for flush before
returning the body would prevent the server from starting its reader. The
writer creates no timer or worker itself.

`flush()` waits for consumption by the HTTP body reader, **not** socket delivery
or peer acknowledgement. `complete()` ends publication and drains queued bytes
before EOF. `close()` aborts, discards bytes, wakes both directions, and makes
later reads fail with `Closed`. A failed partial publication aborts so another
event cannot complete that prefix. Both writer lifetime and operation context
constrain waits.

## Ownership, errors and observability

Close the session in a finally block. It closes only its request/body, not the
shared client. Unread HTTP/1 bodies discard their connection. HTTP/2 cancellation
resets the owned stream and preserves siblings. Local close, cancellation,
deadline, graceful EOF and truncation stay distinct. Overlapping receive fails
with `ConcurrentOperation`.

`SseException.code` is stable; `cause` and `session.lastFailure` retain underlying
structured failures where present. Do not branch on message text. Existing M10
request/attempt, connection and H2 stream correlations remain active across
reconnects. Parser payload and event ids do not enter network telemetry.

[M11-001 evidence](../evidence/M11-001/README.md) records negative framing,
malformed UTF-8, fuzzing, POST no-replay, reconnect bounds, real leases and
installed consumers. Native platform claims are limited to Linux x86_64 glibc.
Browser APIs/CORS, application acknowledgements, WebSocket expansion and gRPC
are outside this task.
