# ADR-0002: Linux-first delivery profile

- Status: Accepted
- Date: 2026-08-23
- Decision owner: Wirestack project owner
- Amended by: ADR-0004

## Context

The product PRD defines a six-platform release. The current delivery request is
to complete Linux independently instead of making Linux implementation wait for
Windows, Apple, Android or Harmony native evidence.

The global PRD is not being relabeled as complete. A separate Linux profile is
needed so Linux work has truthful dependencies and release evidence while the
six-platform matrix remains open.

## Decision

Wirestack will deliver a complete Linux profile with:

- native glibc x86_64 evidence;
- `StdNetTransport`, bounded resolver and Happy Eyeballs connector;
- TLS 1.2/1.3 client and server, system/custom trust, file keys, external
  signer, mTLS, ALPN/SNI and session resumption;
- HTTP/1.1 and HTTP/2 client and server;
- the PRD's Deadline, cancellation, structured error, resource-bound,
  security, fuzz, benchmark, soak and packaging requirements;
- default artifacts with no dynamic dependency on a system TLS library.

Windows and mobile platform tasks do not block the Linux profile. They remain
required by the global six-platform PRD and retain their current status.

Linux musl is outside the current delivery profile because the Cangjie SDK does
not provide a supported musl target, standard library, or runtime. ADR-0004
defines the adoption trigger and supersedes the earlier musl requirement in
this ADR.

## Linux M0 decisions

1. Linux `close()` wakeup evidence from M0-006/M0-008/M0-009 permits logical
   Transport `abort()` and cancellation to close the owned `TcpSocket`. Local
   lifecycle state must classify that result as `Cancelled`, `Closed` or
   `DeadlineExceeded`; peer FIN must remain `EndOfStream`.
2. The supplied SDK has no public typed TCP half-close. ADR-0005 makes this an
   optional transport capability. `StdNetTransport` reports it as unsupported,
   and the Linux release does not depend on UP-003. Wirestack must not use a
   private handle or `CJ_MRT_Sock*`.
3. M0-013's carrier-thread starvation is a real Linux failure. Production DNS
   must use a strictly bounded blocking resolver pool until a runtime-native
   asynchronous resolver exists. No unbounded thread fallback is allowed.
4. A TLS provider may be selected for Linux only after its native glibc PoC has
   all required capabilities, including external signer and session resumption.
   Existing musl provider PoC results remain portability evidence, not product
   support.
5. Linux implementation tasks may begin when their Linux-specific dependencies
   are satisfied. This does not change the status of their global six-platform
   counterparts.

## Consequences

- Linux progress is tracked separately in `docs/planning/linux-status.md`.
- Global task status and six-platform release claims remain fail-closed.
- Platform-independent core code is implemented once and remains suitable for
  later platform adapters.
- A usable Linux release cannot omit native glibc evidence, external signing,
  long soak, fuzzing, benchmarks, or protocol conformance merely because other
  platforms are deferred. Optional transport capabilities must fail with a
  stable error when the public SDK does not provide them.
