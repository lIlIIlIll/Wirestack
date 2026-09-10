# ADR-0008: Linux provider-neutral network foundation

- **Status:** Accepted
- **Date:** 2026-09-06
- **Owner:** Wirestack project owner
- **Related task:** M8-001
- **PRD references:** §7, §8, §9, §10, §11, §15, §17, §19, §21, §24

## Context

The completed Linux profile exposes a provider-neutral Transport SPI, but it
does not yet provide a public socket substrate. Callers still need a
Wirestack-owned API for synchronous TCP, UDP, Unix-domain and capability-scoped
raw sockets, together with the same absolute `OperationContext` used by TLS
and HTTP. The pinned SDK remains the only supported Cangjie toolchain; this
decision therefore cannot depend on runtime, `std`, `stdx` or SDK changes.

The substrate must remain useful when a later platform or provider adapter is
added. Network transport and TLS provider selection are separate dimensions:
the former owns sockets and listeners, while the latter owns cryptography and
certificate operations.

## Decision

1. `wirestack.net` is a public, Wirestack-owned package. It exposes no
   `std.net`, native descriptor, pointer or platform handle.
2. Synchronous potentially blocking operations accept an absolute
   `OperationContext`. Sockets do not retain relative timeout state. The
   current SDK adapter performs bounded public-API waits and rechecks the same
   context on every iteration; it does not create a private event loop or call
   private runtime socket ABI.
3. TCP and datagram lifecycles are explicit and idempotent. At most one
   read-like and one write-like operation may be active per socket; opposite
   directions may proceed concurrently. Stream progress is partial, while
   `readExact` and `writeAll` are explicit helpers. `DatagramSocket` freezes
   connect, atomic send, receive, lifecycle and context operations. Datagram
   operations retain message boundaries, report truncation and reject payloads
   above the bounded IPv4 maximum of 65,507 bytes.
   Successful directional shutdown publishes `ReadHalfClosed` or
   `WriteHalfClosed`; unsupported shutdown does not advance state. Graceful
   `Closed`, local `Aborted` and terminal `Failed` remain distinct, and later
   terminal operations do not overwrite the retained cause.
4. Internet and Unix endpoint values are immutable and live in the shared
   `wirestack` package, below socket, TLS and HTTP consumers. `NetworkEndpoint`
   carries either `SocketEndpoint` or `UnixEndpoint`; `NetworkException` uses
   that same sum type so all phases preserve Unix endpoint evidence without a
   dependency on `wirestack.net`. Unix pathname, abstract byte-name and unnamed
   forms are distinct. Pathnames reject NUL; abstract names retain arbitrary
   bytes. M8-003 must establish native evidence for each supported Unix
   stream/datagram address form. A constructor is not evidence of an adapter.
5. M8 Linux explicitly excludes AF_PACKET, AF_NETLINK, SOCK_SEQPACKET and
   ancillary-data APIs. IPv4/IPv6 raw socket construction is capability-scoped
   and requires an explicit protocol; there is no domain-independent ICMP
   default. Actual privileged I/O is not reported as successful without a
   dedicated native capability adapter.
6. DNS policy remains separate from socket construction. M8-004 owns the
   bounded wire parser, response identity checks, hosts/search/ndots policy,
   negative cache and UDP-to-TCP fallback. Happy Eyeballs remains the
   connector policy consumer.
7. TLS contexts remain immutable and provider-neutral. External signer,
   decryptor and key-log hooks inherit the handshake context; context
   replacement affects future handshakes only. Provider state and native
   handles stay internal.

## Alternatives considered

### Use `std.net` types directly in public APIs

Rejected because it leaks SDK implementation types, makes cancellation and
close semantics provider-specific, and prevents future platform adapters from
sharing the contract.

### Add a private runtime event loop

Rejected because it violates the upstream-independent transport decision and
would create a second scheduler and timeout owner.

### Claim every raw and Unix capability immediately

Rejected. Missing SDK or process capabilities must be reported as unsupported
or blocked; a compile-only shape is not runtime evidence.

## Consequences

- The package boundary and operation semantics can be tested on Linux without
  changing `std.net` or runtime sources.
- M8-001 freezes Unix/raw address and capability contracts, not their native
  adapters. Unsupported capabilities remain non-PASS until the owning task
  supplies native execution evidence.
- M8-002 through M8-007 can add adapters and protocol layers without changing
  the public dependency direction or the existing TLS/HTTP state machines.
- Linux release evidence must include native loopback, capability, DNS, HTTP,
  TLS, installation, SBOM and bounded resource results. Long soak is a final
  candidate gate, not a development fast gate.

## Evidence

- `docs/evidence/M8-001/README.md`
- `docs/evidence/M8-001/evidence.json`
- `docs/evidence/M8-001/test-plan.md`
