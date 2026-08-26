# Wirestack Implementation Status

This file is the lightweight execution index. The PRD and backlog remain the
sources of truth for scope, dependencies, and acceptance criteria.

Status values:

- `READY`: dependencies satisfied; task may start.
- `IN_PROGRESS`: exactly one active implementation branch/PR owns the task.
- `BLOCKED`: dependency, gate, platform, upstream, or evidence requirement is missing.
- `COMPLETE`: all acceptance criteria are satisfied and durable evidence is linked.

## Repository bootstrap

| ID | Status | Evidence | Notes |
|---|---|---|---|
| BOOTSTRAP-001 | COMPLETE | [`docs/evidence/BOOTSTRAP-001/README.md`](../evidence/BOOTSTRAP-001/README.md) | Initialized the repository control plane; no production network implementation. |

## M0

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M0-001 | COMPLETE | [`docs/evidence/M0-001/README.md`](../evidence/M0-001/README.md) | SDK/source inventory and disposition decisions complete. |
| M0-002 | COMPLETE | [`docs/evidence/M0-002/README.md`](../evidence/M0-002/README.md) | CJPM package/path mapping frozen by ADR-0001. |
| M0-003 | COMPLETE | [`docs/evidence/M0-003/README.md`](../evidence/M0-003/README.md) | Architecture dependency guard and CI are active. |
| M0-004 | COMPLETE | [`docs/evidence/M0-004/README.md`](../evidence/M0-004/README.md) | Versioned gate runner and evidence framework complete. |
| M0-005 | COMPLETE | [`docs/evidence/M0-005/README.md`](../evidence/M0-005/README.md) | Existing Linux x86_64 `std.net` raw TCP baseline captured. |
| M0-006 | COMPLETE | [`docs/evidence/M0-006/README.md`](../evidence/M0-006/README.md) | Linux close/wakeup probes pass; global six-platform GATE-NET-01 remains incomplete. |
| M0-007 | COMPLETE | [`docs/evidence/M0-007/README.md`](../evidence/M0-007/README.md) | Full duplex and close races pass; public abort is unavailable, so GATE-NET-02 remains incomplete. |
| M0-008 | COMPLETE | [`docs/evidence/M0-008/README.md`](../evidence/M0-008/README.md) | All 240 Linux absolute-budget samples pass; global GATE-NET-03 remains incomplete. |
| M0-009 | COMPLETE | [`docs/evidence/M0-009/README.md`](../evidence/M0-009/README.md) | FIN, RST and local-close evidence is retained; public abort/cancel and global GATE-NET-04 remain incomplete. |
| M0-010 | BLOCKED | [`docs/evidence/M0-010/README.md`](../evidence/M0-010/README.md) | Linux 64 KiB-buffer/100 MiB profile passes, but copied-byte instrumentation, Windows evidence and future adapter comparison are missing. |
| M0-011 | BLOCKED | [`docs/evidence/M0-011/README.md`](../evidence/M0-011/README.md) | Linux 100k transport/TLS workloads and 24-hour soak pass; timer/waiter/native-buffer/GC-root/background-task accounting and required native platforms remain outstanding. |
| M0-012 | BLOCKED | — | Requires M0-011 evidence completion and Android/iOS/Harmony native-device execution. |
| M0-013 | COMPLETE | [`docs/evidence/M0-013/README.md`](../evidence/M0-013/README.md) | Native Linux evidence shows carrier-thread starvation at 16+ delayed DNS resolutions; gate FAIL supports conditional UP-007 analysis, while global evidence remains incomplete. |
| M0-014 | BLOCKED | — | Requires a native Windows SDK/runner and copied-byte instrumentation. |
| M0-015 | COMPLETE | [`docs/evidence/M0-015/README.md`](../evidence/M0-015/README.md) | Provider matrix and M0-016 PoC contract frozen; ADR-0003 selects AWS-LC for Linux only. |
| M0-016 | BLOCKED | [`docs/evidence/M0-016/README.md`](../evidence/M0-016/README.md) | AWS-LC glibc/musl schema-v2 results PASS every capability; seven retained cells remain PARTIAL and Windows/mobile native evidence is missing. |
| M0-017 | BLOCKED | — | Depends on M0-012 and M0-016 native evidence. |
| M0-018 | COMPLETE | [`docs/evidence/M0-018/README.md`](../evidence/M0-018/README.md) | Versioned threat register, fail-closed validator, tests and CI are active. |
| M0-019 | BLOCKED | — | Depends on complete M0-006 through M0-014 evidence; M0-010..014 are not all complete. |
| M0-020 | BLOCKED | [`docs/architecture/adr/0003-linux-tls-provider.md`](../architecture/adr/0003-linux-tls-provider.md) | Linux profile selects pinned AWS-LC; the global six-platform provider decision remains deferred. |
| M0-021 | BLOCKED | — | Depends on all M0 gate evidence plus the accepted Transport SPI. |
| M0-022 | BLOCKED | — | Depends on M0-004 through M0-021. |

## Linux M1 closure work

This table records Linux-only completion and does not generalize to the global
six-platform milestone.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M1-010 | COMPLETE | [`docs/evidence/M1-010/README.md`](../evidence/M1-010/README.md) | `DuplexTransport` semantics are frozen; lifecycle claims enforce one reader and one writer, and MemoryTransport proves empty-buffer, half-close, cancellation, deadline, close and abort behavior. |
| M1-011 | COMPLETE | [`docs/evidence/M1-011/README.md`](../evidence/M1-011/README.md) | `writeAll` and `readExact` retain one absolute operation budget across partial I/O, reject invalid progress without spinning, preserve partial results, and distinguish premature EOF, cancellation and deadline failure. |
| M1-012 | COMPLETE | [`docs/evidence/M1-012/README.md`](../evidence/M1-012/README.md) | `TransportListener` and the Linux adapter enforce a bounded backlog, cancellable and deadline-aware accept, deterministic close wakeup, exactly-once terminal selection and structured accept errors. |
| M1-013 | COMPLETE | [`docs/evidence/M1-013/README.md`](../evidence/M1-013/README.md) | `MemoryTransport` now includes a bounded listener and manually advanced FIFO scheduler while preserving paired partial I/O, half-close, EOF, backpressure and terminal cleanup. |
| M1-014 | COMPLETE | [`docs/evidence/M1-014/README.md`](../evidence/M1-014/README.md) | Bounded read/write scripts reproduce manual delay, short I/O, EOF, terminal reset, cancellation races and structured error phases through a FIFO virtual waiter. |
| M1-018 | COMPLETE | [`docs/evidence/M1-018/README.md`](../evidence/M1-018/README.md) | `writeSome` performs bounded partial writes through one connection-retained exact-size staging array, the 16 KiB default carries a typical TLS record, and copied bytes remain measurable; the canonical repository gate separately retains one unrelated HTTP/2 package-interference error. |
| M1-027 | COMPLETE | [`docs/evidence/M1-027/README.md`](../evidence/M1-027/README.md) | The internal background fast path reduces empty `readSome` P50 from 297.042 ns to 92.110 ns; the formal Linux 5-payload x 11-round GATE-NET-05 comparison passes every throughput and P95 threshold with zero staging copies. |

## Linux M2 closure work

This table records Linux-only deterministic completion and does not override
the native platform dependencies in the global backlog.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M2-001 | COMPLETE | [`docs/evidence/M2-001/README.md`](../evidence/M2-001/README.md) | Canonical ASCII/A-label host names and typed immutable IPv4/IPv6/zone endpoints cover exact name, label and port boundaries without implicit DNS or accepting authority syntax as a host. |
| M2-010 | COMPLETE | [`docs/evidence/M2-010/README.md`](../evidence/M2-010/README.md) | Immutable direct and explicit-proxy routes separate origin/connect targets and DNS ownership while retaining bounded network-binding, TLS-context and ALPN parameters; system-proxy discovery remains out of scope. |
| M2-014 | COMPLETE | [`docs/evidence/M2-014/README.md`](../evidence/M2-014/README.md) | Scripted resolver and connector tests cover IPv6 first success and blackhole fallback, simultaneous success, all-fail, pre-cancel, success-plus-cancel and the exact Deadline publication boundary. |

## Conditional upstream work

`UP-001` through `UP-007` remain **BLOCKED / DO NOT START** until the corresponding
failed gate provides reproducible evidence and an approved minimal upstream-interface RFC.
Actual `std.net`/runtime source changes belong in their upstream repositories,
not in the Wirestack worktree.

The M0-007 and M0-009 capability probes record that the supplied SDK exposes no
public `TcpSocket.abort()` and no public cancellation member. M0-013 additionally
shows native Linux carrier-thread starvation under delayed DNS and identifies
`UP-007` as a conditional candidate. These are inputs to M0-021; none independently
authorize an upstream implementation task.

## Later milestones

M1 through M7 and P1 tasks remain blocked by their backlog dependencies. A Linux-only
M0 result must not be generalized to the six-platform release matrix.
