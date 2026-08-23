# Linux delivery status

This file tracks the Linux-first profile accepted by
[ADR-0002](../architecture/adr/0002-linux-first-delivery-profile.md). The
global six-platform status remains in [`status.md`](status.md).

Status values have the same fail-closed meaning as the global status file.

## M0 Linux exit

| Area | Status | Current evidence or next requirement |
|---|---|---|
| Architecture and gate harness | COMPLETE | M0-001 through M0-004 and M0-018 evidence |
| close/wakeup and absolute Deadline | COMPLETE | M0-006 and M0-008 native Linux results |
| duplex and EOF classification | BLOCKED | Executed behavior passes; public typed half-close is absent and requires UP-003 |
| large-buffer/copy profile | BLOCKED | Large-buffer behavior passes; copied-byte/allocation instrumentation and adapter comparison remain |
| leak/soak | BLOCKED | Bounded stress passes; 100k cleanup and 24-hour Linux soak remain |
| DNS scheduler behavior | COMPLETE | M0-013 records starvation and mandates a bounded resolver pool |
| TLS provider | BLOCKED | glibc/musl results are PARTIAL; external signer remains unproved and no provider is selected |
| Transport SPI | IN_PROGRESS | Core types are implemented; listener, lifecycle closure and upstream capability mapping remain |
| Linux continuous gates | BLOCKED | Depends on the remaining Linux M0 evidence and decisions |

## Implemented Transport Core

| Task | Status | Evidence |
|---|---|---|
| M1-002 `ByteSpan`/`MutableByteSpan` | COMPLETE | Checked zero-copy ranges, slice/advance and tests |
| M1-003 monotonic `Deadline` | COMPLETE | `MonoTime`, injected clock, remaining/expiry/child tests |
| M1-004 cancellation primitive | IN_PROGRESS | Registration, unregister, fast-fail and exactly-once tests pass; larger race matrix remains |
| M1-005 `OperationContext` | COMPLETE | Immutable Deadline/cancellation/trace propagation tests |
| M1-006 trace context | IN_PROGRESS | Bounded read-only identifiers exist; event sink remains |
| M1-007 structured network error | COMPLETE | category/phase/code/retryability/native/endpoint/cause model and tests |
| M1-010 `DuplexTransport` contract | IN_PROGRESS | Contract and MemoryTransport semantics exist; shared lifecycle state machine remains |
| M1-011 `writeAll`/`readExact` | COMPLETE | Partial I/O, empty range and premature EOF tests |
| M1-012 `TransportListener` | COMPLETE | Contract plus bounded `StdNetTransportListener`; Deadline/cancel/close wakeup integration tests |
| M1-013 `MemoryTransport` | IN_PROGRESS | Bounded duplex, backpressure, half-close, EOF, cancellation and terminal tests pass; listener/fault scripting remains |
| M1-015/016 `StdNetTransport` ownership/connect | COMPLETE | DNS-free `IPSocketAddress` construction, exclusive adapter ownership, absolute connect budget and actual endpoints |
| M1-017 `StdNetTransport.readSome` | COMPLETE | Partial reads, peer EOF, local close/cancel distinction, Deadline and one-reader guard tested on Linux loopback |
| M1-018 bounded write staging | IN_PROGRESS | Bounded partial writes and copied-byte counters exist; current whole-Array `std.net` API still forces per-call staging allocation |
| M1-019 typed half-close | BLOCKED | Public pinned `TcpSocket` has no shutdown API; adapter reports `Unsupported` and requires UP-003 |
| M1-020 idempotent close/abort | COMPLETE | Native close is claimed once; close/cancel wake blocked read and listener accept without returning false EOF |
| M1-021 `StdNetTransportListener` | COMPLETE | IP-only bind, bounded backlog, endpoints and accept Deadline/cancel/close semantics |
| M1-022 stable std.net errors | BLOCKED | Timeout/cancel/closed are stable; public `SocketException` exposes no native code, so errno classes require an upstream API instead of message matching |
| M1-023 transport diagnostics | IN_PROGRESS | Backend/endpoints/capabilities and staging copied-byte counters exist; event sink/runtime backend discovery remain |

## Next critical path

1. Complete shared Transport lifecycle/exactly-once primitives and the remaining
   deterministic race tests.
2. Submit the minimal `std.net` upstream interface RFC for typed half-close and
   stable native error evidence.
3. Implement the bounded Linux resolver and Happy Eyeballs connector.
4. Complete the Linux TLS provider PoC, select/pin one provider, then implement
   TLS Core and Linux trust/key adapters.
5. Implement HTTP/1.1, HTTP/2, Linux conformance, fuzz, benchmark, 24-hour soak,
   packaging and installation verification.
