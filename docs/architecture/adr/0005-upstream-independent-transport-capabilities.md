# ADR-0005: Upstream-independent transport capabilities

- Status: Accepted
- Date: 2026-08-27
- Owner: Wirestack project owner
- Related task: M0-024
- PRD references: §8.4, §10.3, §11.3, §16.1, §20

## Context

The pinned public Cangjie SDK does not expose directional TCP shutdown, stable
socket native error codes, or the exact runtime I/O backend. Wirestack already
uses only public `std.net` APIs. It does not access private socket handles or
call `CJ_MRT_Sock*`.

Earlier planning made the Linux release depend on new runtime or `std.net`
interfaces. That dependency prevents Wirestack from releasing against a
supported SDK even when cancellation, TLS shutdown, and HTTP stream shutdown
already pass their Linux gates.

TCP directional shutdown is different from protocol shutdown. TLS uses
`close_notify`. HTTP/2 uses `END_STREAM`, `RST_STREAM`, and `GOAWAY`. These
protocol operations do not require TCP directional shutdown.

## Decision

Wirestack release gates use the capabilities of the pinned public SDK. A
runtime or `std.net` change is an optional future improvement, not a Wirestack
release dependency.

The Transport contract keeps typed directional shutdown so adapters that
support it can expose one consistent operation. Each adapter reports
`supportsHalfClose`. If the value is `false`, `shutdown(Read)` and
`shutdown(Write)` return the stable `Unsupported` error without changing the
connection state. `close()` and `abort()` remain required.

`NetworkException.nativeCode` remains optional. When the SDK does not expose a
stable native code, the adapter derives errors only from the operation context
and Wirestack-owned lifecycle state. Other socket failures map to a stable
generic code with `Retryability.Unknown`. The adapter does not inspect
`SocketException.message`.

`TransportInfo.runtimeIoBackend` may report a stable runtime family such as
`cjnative`. It does not claim that the SDK exposes the operating-system event
mechanism. Exact runtime backend discovery is optional.

The Linux release continues to require cancellation wakeup, peer EOF
classification, TLS truncation detection, TLS `close_notify`, HTTP/1 graceful
drain, and HTTP/2 stream and connection shutdown. Existing native Linux
evidence covers these requirements.

## Alternatives considered

### Require runtime and std changes before release

Rejected. Wirestack would depend on an SDK change that it does not control.

### Access a private socket handle from Wirestack

Rejected. This would violate the architecture boundary and tie Wirestack to a
private runtime ABI.

### Remove directional shutdown from the Transport contract

Rejected. Memory transports and future adapters can implement the operation.
Capability reporting gives callers one stable contract without inventing TCP
behavior on an unsupported adapter.

## Consequences

- M1-019 qualifies capability reporting and the `Unsupported` path on the
  current `StdNetTransport`. It does not wait for UP-003.
- M1-022 requires stable Wirestack errors. A native socket code is retained
  when available and omitted when the SDK does not expose one.
- M1-023 may report the runtime family without identifying epoll, kqueue, or
  IOCP.
- M1-020 through M1-026 do not depend on an upstream patch.
- UP-003 and UP-005 remain future upstream improvements. They are not on the
  Wirestack release critical path.
- A future SDK capability requires its own compatibility and regression gates
  before Wirestack enables it.

## Evidence

- `docs/evidence/M0-024/README.md`
- `docs/evidence/M0-006/README.md`
- `docs/evidence/M0-009/README.md`
- `docs/evidence/M1-010/README.md`
- `docs/evidence/M3-028/README.md`
- `docs/evidence/M6-021/README.md`
- `docs/evidence/M6-022/README.md`

