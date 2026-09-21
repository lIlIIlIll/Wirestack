# M8-005 evidence

M8-005 aligns the public HTTP facade with the bounded Linux network foundation.
The work stays provider-neutral: `CookieJar`, `MultipartWriter`,
`HttpUpgrade`, `WebSocketFrame`, push policy and lifecycle hooks are Wirestack
types and do not expose `std.net`, native descriptors or TLS provider state.

`HttpClientBuilder.cookieJar` applies caller-owned cookies only when a request
does not already carry a Cookie header and captures bounded Set-Cookie values
from responses. `MultipartWriter.body()` produces an owned, replayable body
with bounded metadata and total output. WebSocket frames support masking,
extended lengths and strict control-frame validation without compression.

The existing HTTP/2 client continues to reject server push by default. The
public `DenyHttp2PushPolicy` documents that fail-closed boundary, while the
existing stream admission/reset limits remain authoritative. Server lifecycle
hooks run around both H1 and H2 handler dispatch using the existing
`OperationContext`.

Native Linux evidence: the HTTP package suite passes 76/76, including the
parity contract tests; Cangjie check/build and the architecture guard pass.
No non-Linux run, one-hour SSE profile, or 86,400-second soak was run here.
M8-007 owns final release artifact regeneration and the candidate long gate.
