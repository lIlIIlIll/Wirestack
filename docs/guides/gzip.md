# Decode bounded gzip responses

Import `wirestack.gzip` explicitly to decode gzip HTTP response bodies. Ordinary
`HttpClient` calls return raw content and do not negotiate or decompress gzip.
HTTP Core does not depend on this optional package. Its RFC 1951 DEFLATE and
RFC 1952 gzip decoder is pure Cangjie, with no compression library or native
compression dependency.

The installed-consumer examples show the two choices:
[raw HTTP](../../examples/linux/m11_002/raw.cj) and
[explicit gzip](../../examples/linux/m11_002/gzip.cj). They use installed public
packages, not internal decoder APIs. See the
[Linux setup guide](getting-started-linux.md) for installation prerequisites.

## Select decoding

`GzipClient(client, limits:, passThroughUnsupported:)` wraps your existing
`HttpClient` without taking ownership of it. Call
`send(request, context:, cancellation:)` and read `result.response.body` into a
caller-owned buffer. Close the returned `GzipResponse` in a finally block.
`GzipResponse.close()` closes its owned response, not the shared client.

The wrapper adds `Accept-Encoding: gzip` only when your request has no
`Accept-Encoding` header. Your header wins, including an explicit `identity`.
Response selection still follows the received `Content-Encoding`.

Only a single `gzip` coding is decoded, case-insensitively. Missing coding or a
single `identity` returns the raw response. Unknown, repeated or layered codings
raise `GzipException(UnsupportedCoding)`. Set `passThroughUnsupported: true` to
return those responses raw instead. This does not add another decoder.

HEAD responses and bodyless statuses, including 204, 205 and 304, stay raw even
if they declare gzip. Informational responses are also bodyless. There is no
attempt to decode a nonexistent body.

## Keep wire and decoded metadata separate

`GzipResponse.wireHeaders` preserves the original immutable response headers.
`wireContentLength` is the declared wire-body length, not a decoded length.
`isDecoded` tells you whether the wrapper selected gzip decoding. The decoded
body has unknown `contentLength`.

For decoded responses, `response.headers` removes `Content-Encoding`,
`Content-Length` and `Transfer-Encoding`. It also removes representation
validators `Content-MD5`, `Content-Digest`, `Digest` and `ETag`: wire validators
must not be presented as validators for the decoded bytes. `Content-Range` is
removed as well, because a gzip-coded `206 Partial Content` describes offsets and
a total length in the coded representation that no longer apply to decoded
bytes; it remains available unchanged in `wireHeaders`. Other headers remain.
Raw responses keep their headers unchanged.

**HTTP trailers currently remain wire metadata.** After successful gzip
integrity verification, `response.body.trailer` exposes the original HTTP
trailers unchanged. These are not decoded-representation validators, even if
trailer fields contain a digest or other validator. Do not use them to validate
decoded bytes without a separate application-defined contract. Gzip's binary
CRC32/ISIZE trailer is different from an HTTP trailer.

## Treat output as provisional

`read(destination)` pulls compressed input only as needed to fill bounded
output. It returns at most `min(destination.size, limits.maximumReadBytes)`
bytes. There is no background decoder or decoded-output queue. A slow caller
therefore applies pull backpressure to the source.

Bytes returned before completion are provisional. Every member's CRC32 and
ISIZE must match, and the decoder must reach the physical EOF of the compressed
HTTP body, before `integrityVerified` becomes true. Reaching the declared wire
length or producing the expected decoded length is not enough. Keep reading
with a nonempty destination until a read returns zero and integrity is verified.
An empty destination returns zero without proving EOF, failing, or closing the
owned source. Once verified EOF has been observed a later deadline or cancellation
does not rewrite it: subsequent reads with a nonempty destination keep returning
zero. Do not publish a complete trusted artifact from a prefix that may later
fail integrity checks.

`encodedBytesRead`, `decodedBytes` and `memberCount` report actual progress.
Decoded-byte counts include provisional output. Raw `GzipResponse` views report
zero counts and `integrityVerified == false`; they make no gzip integrity claim.

For an existing compressed `HttpBodyStream`, use
`GzipBodyStream(source, limits:, context:)` directly. It owns and closes that
source on EOF, failure or local close. It never makes a body replayable.

## Set absolute bounds

All constructor values are `Int64`. Every value has a minimum of 1, inclusive.
Values above the hard maximum or below 1 raise `IllegalArgumentException` before
reading or submitting a request.

| `GzipLimits` field | Default | Hard maximum | What it counts |
|---|---:|---:|---|
| `maximumEncodedBytes` | 67,108,864 | 1,073,741,824 | Compressed bytes read, including headers, trailers and read-ahead |
| `maximumDecodedBytes` | 67,108,864 | 1,073,741,824 | Cumulative decoded bytes across all members |
| `maximumHeaderBytes` | 4,096 | 65,536 | Bytes scanned per gzip header, including optional fields |
| `maximumMembers` | 1 | 128 | Accepted gzip members |
| `maximumBlocks` | 4,096 | 65,536 | Cumulative DEFLATE blocks, including empty blocks |
| `inputBufferBytes` | 4,096 | 65,536 | Retained compressed input buffer |
| `maximumReadBytes` | 16,384 | 65,536 | Output delivered by one read |

The default accepts one member only. Raise `maximumMembers` explicitly to
accept concatenated members. Output and block limits remain cumulative, not
per-member. A compression-ratio threshold cannot replace these absolute caps.

At exactly `maximumEncodedBytes`, the decoder probes physical EOF. It may read
one additional byte solely to reject excess input with `InputLimit`; it does not
decode that byte. Accordingly, the failure counter can be one byte above the
configured cap. An exact-cap valid stream still needs a zero-byte EOF probe.

`maximumRetainedBytes` is a conservative reservation of
`128 * 1024 + inputBufferBytes`, or 135,168 bytes with defaults. It covers codec
storage, the fixed 32 KiB history, bounded Huffman tables and compressed input.
It excludes your output buffer and the source stream's own storage.

Before request submission and codec allocation, `GzipClient` reserves this
amount from the same client's managed DATA ledger, with route/origin attribution.
When the client's redirect policy follows the request to a different origin or
proxy route, the reservation is re-homed to the actual final response target
before codec allocation, so decoder storage is charged to the origin that
produced the body. HEAD needs no decoder reservation. Raw selection releases an
unused reservation. Verified EOF, failure and close release the lease. HTTP/2
control and cleanup reserves are not available to the decoder. The standalone
`GzipBodyStream` bounds its own storage but does not obtain an HTTP-client
ledger lease.

Incoming HTTP/2 DATA is charged to the same route/origin owner, so a reservation
that would leave less than one minimum 16 KiB DATA frame of headroom is refused
before submission with a typed `ResourceExhausted`/`PoolAcquire` error instead of
deadlocking the stream. `HttpClient.reserveResponseBuffer` applies the same rule
to every managed response-buffer consumer, so a later HTTP/2 DATA frame for that
owner is still admissible at exactly the configured route or origin capacity.

## Share time and cancellation

The wrapper uses one monotonic absolute `OperationContext` for admission,
network stages, body reads and CPU decoding. `HttpClient.contextForRequest`
applies the client's configured total timeout before admission; the response's
`operationContext` retains the effective request context. Decoding does not
restart a timeout after headers or create a second timeout owner. Request,
connection and stream cancellation handles remain active during decoding.

The decoder checks the context at I/O boundaries and every 512 counted codec
work steps, including bounded table construction and output/history work.
`GzipBodyStream.maximumWorkBetweenChecks` exposes the observed count. This is a
work-count bound, not a wall-clock cancellation latency SLA. Scheduling and a
source that blocks outside the context contract can take longer.

One read may be active at a time. An overlapping read raises
`GzipException(ConcurrentOperation)` rather than starting another decoder.

The wrapper links the caller context and every supplied typed handle before data
admission, so a cancelled handle wakes a blocked admission wait instead of
leaving it pending, and cancellation stays observable through
`response.operationContext` until decoded EOF or close, even after the compressed
wire body is fully drained. A cancellation or expiry observed before admission or
submission is classified as `NetworkPhase.PoolAcquire`, because no response body
processing has started yet; later body-read failures keep `HttpBody`.

## Handle terminal errors

Use typed codes, not exception messages. `GzipException` reports phase
`HttpBody`, retryability `Never`, and an optional original `cause`.

| Codes | Meaning |
|---|---|
| `InputLimit`, `OutputLimit`, `HeaderLimit`, `MemberLimit`, `BlockLimit` | A configured absolute bound was exceeded |
| `InvalidHeader`, `InvalidDeflate`, `TrailingData` | Invalid gzip/DEFLATE framing or non-member suffix bytes |
| `ChecksumMismatch`, `SizeMismatch` | Header/payload CRC or member ISIZE failed |
| `UnexpectedEof` | Gzip framing or DEFLATE ended before completion |
| `UnsupportedCoding` | Unknown, repeated or layered response coding |
| `ConcurrentOperation` | Another read is already active |
| `Closed` | The decoded body was closed locally |

Cancellation and deadline expiry remain typed `NetworkException` results,
separate from local `Closed` and gzip `UnexpectedEof`. Underlying HTTP framing
EOF and TLS truncation retain their transport/network errors; neither becomes
successful decoded EOF. When a transport failure races an observable cancellation
or expiry, the contextual classification wins but the transport error's native
code, local endpoint and remote endpoint are preserved and the transport error
remains the cause.

A limit or decode failure is terminal and closes the owned source. Cancellation
also ends that decoded response. You cannot retry reads to resume it or replay a
returned response. The underlying client's existing retry/redirect policy may
act before a response is returned; decoding never grants request replay safety.
Unread HTTP/1 bodies discard their connection. HTTP/2 closes/resets only the
owned stream, preserving siblings and the shared client.

## Acceptance evidence

The [public API inventory](../api/baselines/wirestack-linux-pre1-m11-002.json),
[API check](../evidence/M11-002/public-api.json) and
[strict documentation report](../evidence/M11-002/docs/report.json) record the
source-bound working-tree checks. Historical inventories remain historical;
this inventory does not claim compatibility with them. These checks are not
release qualification or acceptance of a committed candidate.
