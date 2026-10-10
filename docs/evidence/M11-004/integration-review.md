# M11-004 public integration and ownership review

All four consumers depend only on the extracted `wirestack` package. No production package, public API, native provider, SDK or upstream repository was changed by this task. Each executable includes an operational command and a native acceptance command; the operational commands are exercised separately by the installed runner.

## Ownership

| Consumer | Owned lifetime | Terminal proof |
|---|---|---|
| CLI/raw | One absolute OperationContext, CancellationSource, TLS configuration, resolver, client, response, output handle and owned `.partial` | Response/file/client/resolver/configuration close; cancellation and publication failure remove only the owned partial file; a pre-existing destination survives. Public client ledger returns to zero. |
| CLI/decoded | Same ownership plus the optional GzipResponse/body wrapper | Wrapper/body and output are closed on success and all terminal failures. Decoded output/storage limits are separate from the raw transport. |
| Long stream | Finite SseSession/WebSocketSession, one root context across explicit recovery, bounded cursor/codec/data budgets and an independent H2 sibling | Slow stream capacity is observed while the pre-opened sibling still receives exact bytes; cancellation releases the slow stream without replacing the physical connection. Final public ledger is zero. |
| Service | TLS generations, listener/server, canonical shortened request contexts, bounded uploads, streaming producers and administrative input | Ordinary rotation preserves a held old exchange; security rotation cancels it and requires client identity; overload refuses an actual fifth exchange; graceful shutdown remains pending until the held request is released. Server ledger and producer count return to zero. |

Parsed SSE cursor advancement is not a downstream acknowledgement. Recovery is an explicit, finite caller policy and is off by default. Operational POST keeps conservative retry safety. The adversarial POST acceptance request is deliberately marked ExplicitlySafe to prove that SSE still does not replay POST after peer failure. WebSocket recovery opens a new session and sends a recovery message, not the original business message.

The proxy fixture records actual EOF and reset as distinct terminal observations. A verified application success followed by a native TCP reset is not relabelled as EOF. CONNECT authorization is consumed by the proxy; its TLS ClientHello retains `example.test` SNI. Python fixture sockets are bounded and are not a second application networking backend.

## Public API gaps and necessary boilerplate

| Observed gap | Consumer consequence and decision | Backlink |
|---|---|---|
| Public IpAddress is a typed byte value, not a public string parser | Both independent CLI variants carry small IPv4/IPv6 literal decoding helpers for proxy endpoints. They retain literal and DNS proxy support; no test-only resolver or new convenience API was added. | [M8-001 public facade evidence](../M8-001/README.md) |
| HttpException exposes code and cause, but no top-level phase | CLI projects project the actual NetworkException phase when present. A cause without a network phase reports `not_available`, not an invented stage. Network failures retain their actual phase in operational stderr. | [M10-005 diagnostic evidence](../M10-005/README.md) |
| Public enums have no common diagnostic formatting surface used by these projects | Independent CLIs carry explicit phase-name projections instead of matching exception text. The numeric application exit contract is distinct from public exception categories. | [M10-005 diagnostic evidence](../M10-005/README.md) |
| A valid but too-small SSE codec reservation can fail at session construction with IllegalArgumentException | The long-stream capacity case exercises the real reservation failure and verifies cleanup. It does not replace this with a constructor-default assertion or classify the exception as a network reset. | [M11-001 SSE evidence](../M11-001/README.md), [M10-002 resources](../M10-002/verification.json) |
| HttpServer builder has no documented accepted-socket adapter injection | Service uses the supported public listener/server builder. SDK1.1.3 socket-option and UDP probes remain separate installed public consumers of the same archive. No service-level accepted-policy qualification is claimed. | [M9-002 socket evidence](../M9-002/README.md) |
| Nonblocking server tryAcquire refusal does not increment rejectedOperations | Overload is proven by real held requests/streams and a typed refusal of an additional exchange. No rejectedOperations increment is asserted or claimed. | [M10-002 resource evidence](../M10-002/verification.json), [M10-005 diagnostics](../M10-005/README.md) |
| Native required-mTLS refusal can surface SystemFailure/TcpWrite; an actual old-H2 or SDK1.1.3 CLI peer abort can surface ProtocolViolation | Service and CLI acceptance enumerate these typed terminal outcomes while keeping EOF, reset and protocol failure distinct. The CLI first waits for the real producer barrier, then closes the server, requires failure, checks unpublished output and verifies zero client resources. No message matching or successful EOF substitution. | [M10-004 rotation evidence](../M10-004/verification.json), [M11-003 lifecycle evidence](../M11-003/README.md) |

Shared application code was not extracted into a sibling dependency: that would defeat the independently installed, package-only projects. No public alias, accessor, compatibility shim or follow-on implementation was introduced to hide these gaps. Upstream interface work and release qualification remain outside M11-004.
