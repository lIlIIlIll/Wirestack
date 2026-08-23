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
| M1-013 `MemoryTransport` | IN_PROGRESS | Bounded duplex, backpressure, half-close, EOF, cancellation and terminal tests pass; listener/fault scripting remains |

## Next critical path

1. Complete shared Transport lifecycle/exactly-once primitives and deterministic
   race tests.
2. Freeze the Linux Transport SPI and minimal `std.net` upstream interface RFC.
3. Implement `StdNetTransport` without DNS or private-handle access.
4. Implement the bounded Linux resolver and Happy Eyeballs connector.
5. Complete the Linux TLS provider PoC, select/pin one provider, then implement
   TLS Core and Linux trust/key adapters.
6. Implement HTTP/1.1, HTTP/2, Linux conformance, fuzz, benchmark, 24-hour soak,
   packaging and installation verification.
