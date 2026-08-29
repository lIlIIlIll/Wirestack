# Parsers and resource limits

The review scope includes TLS records and handshake messages, certificate
chains, HTTP/1.1 start lines, headers and chunk framing, HTTP/2 frames and stream
state, HPACK tables and lists, proxy responses, and SSE streaming bodies.

Every queue, buffer, table, cache, pool, session store, parser length, and flow
control window must have an explicit bound. Invalid lengths, illegal state
transitions, truncated TLS records, malformed chunk framing, HPACK violations,
and HTTP/2 protocol errors fail closed with structured categories and codes.
Exception message text is never a parser decision input.

M7-023 supplies deterministic replay and fuzz evidence for the security-sensitive
parsers. The evidence package digest-binds those reports. Long-duration SSE and
release soak profiles are not part of M7-028.

