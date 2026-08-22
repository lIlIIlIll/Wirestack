# Architecture

Wirestack architecture is governed by the PRD plus accepted Architecture
Decision Records (ADRs).

The mandatory dependency direction is:

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

Core rules:

- only the StdNet adapter may import `std.net`;
- public API and Core must not expose `std.net` or provider-native types;
- no direct `CJ_MRT_Sock*` use;
- no independent six-platform socket event-loop implementation;
- one absolute monotonic Deadline and one cancellation model across all phases;
- all resource collections and protocol limits are bounded.

## Accepted ADRs

- [ADR-0001: CJPM Package and Source Layout](adr/0001-cjpm-package-layout.md)

## Supporting architecture records

- [Current Cangjie TLS/HTTP/std.net inventory](current-network-stack-inventory.md)

## ADR policy

Use [`adr/0000-template.md`](adr/0000-template.md).

An ADR may refine an implementation choice but may not silently weaken a PRD
requirement. If a proposed ADR conflicts with the PRD, update/review the PRD
explicitly before accepting the ADR.

M0 is expected to freeze at least:

- actual repository/package/target layout;
- Transport SPI semantics;
- TLS provider and build strategy;
- minimum OS/API/SDK matrix;
- any gate-driven upstream `std.net`/runtime changes.
