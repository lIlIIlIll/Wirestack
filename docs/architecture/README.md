# Architecture

Wirestack separates protocol semantics from the default Cangjie socket adapter:

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

Only `wirestack.internal.transport_stdnet` may import `std.net`. Public packages
and protocol Core must not expose `std.net`, AWS-LC or platform-native types.
Wirestack does not call `CJ_MRT_Sock*`, build a second socket event loop, parse
exception messages as control flow, or introduce a second timeout owner.

All waiting phases share one monotonic absolute `Deadline` and cancellation
model. EOF, local close, abort, cancel, deadline, RST and TLS truncation remain
different terminal evidence. Every queue, buffer, pool, cache, table, window and
session store is bounded.

## Public and internal packages

- `wirestack.http`: public HTTP/1.1 and HTTP/2 facade.
- `wirestack.tls`: public provider-neutral TLS facade and Transport contract.
- `wirestack.internal.transport_stdnet`: the only default adapter for `std.net`.
- `wirestack.internal.resolver` and `.connector`: bounded DNS and route setup.
- `wirestack.internal.tls_engine`, `.trust`, `.identity`: provider-neutral TLS
  state, trust and key boundaries.
- `wirestack.internal.http1` and `.http2`: strict bounded protocol engines.

The exact physical mapping is frozen by ADR-0001 and checked by
[`scripts/architecture-guard`](architecture-guard.md).

## Accepted decisions

1. [ADR-0001: CJPM package and source layout](adr/0001-cjpm-package-layout.md)
2. [ADR-0002: Linux-first delivery profile](adr/0002-linux-first-delivery-profile.md)
3. [ADR-0003: Linux TLS provider selection](adr/0003-linux-tls-provider.md)
4. [ADR-0004: Current Linux libc support](adr/0004-linux-glibc-support.md)
5. [ADR-0005: Upstream-independent transport capabilities](adr/0005-upstream-independent-transport-capabilities.md)

Accepted ADRs refine the [PRD](../product/prd.md) but may not silently weaken
it. Use [the ADR template](adr/0000-template.md) for a new decision.

## Design records

- [Network-stack inventory](current-network-stack-inventory.md)
- [Linux TLS provider build and ABI](linux-tls-provider-build.md)
- [Provider candidate matrix](tls-provider-candidate-matrix.md)
- [Provider PoC contract](tls-provider-poc-contract.md)
- [P0 threat model](../security/threat-model.md)

These records describe the evidence and decisions available at their recorded
date. Current execution state lives in the [status index](../planning/status.md).
