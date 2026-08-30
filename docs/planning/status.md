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
| M0-005 | COMPLETE | [`docs/evidence/M0-005/README.md`](../evidence/M0-005/README.md) | Schema-v3 native Linux evidence covers all six payloads on loopback and a separate KVM/virbr0 LAN peer with exact bytes, percentiles, read count, threads, RSS, native allocations/op and raw receive copied-bytes/op. |
| M0-006 | COMPLETE | [`docs/evidence/M0-006/README.md`](../evidence/M0-006/README.md) | Linux close/wakeup probes pass; global six-platform GATE-NET-01 remains incomplete. |
| M0-007 | COMPLETE | [`docs/evidence/M0-007/README.md`](../evidence/M0-007/README.md) | Full duplex and close races pass; public abort is unavailable, so GATE-NET-02 remains incomplete. |
| M0-008 | COMPLETE | [`docs/evidence/M0-008/README.md`](../evidence/M0-008/README.md) | All 240 Linux absolute-budget samples pass; global GATE-NET-03 remains incomplete. |
| M0-009 | COMPLETE | [`docs/evidence/M0-009/README.md`](../evidence/M0-009/README.md) | FIN, RST and local-close evidence is retained; public abort/cancel and global GATE-NET-04 remain incomplete. |
| M0-010 | BLOCKED | [`docs/evidence/M0-010/README.md`](../evidence/M0-010/README.md) | Schema-v2 evidence completes all five Linux payloads, copied-byte/allocation instrumentation and an 11-round O2 adapter comparison. GATE-NET-05 fails all five throughput cases and four P95 cases, providing evidence for the future UP-004 candidate; Windows remains missing. UP-004 does not block Wirestack release. |
| M0-011 | BLOCKED | [`docs/evidence/M0-011/README.md`](../evidence/M0-011/README.md) | Linux GATE-NET-06 acceptance passes, including production cancellation/TLS cleanup and all resource classes; Windows, macOS and mobile native profiles remain outstanding. |
| M0-012 | BLOCKED | — | Requires M0-011 evidence completion and Android/iOS/Harmony native-device execution. |
| M0-013 | COMPLETE | [`docs/evidence/M0-013/README.md`](../evidence/M0-013/README.md) | Native Linux evidence shows carrier-thread starvation at 16+ delayed DNS resolutions. Wirestack uses a bounded resolver pool; the failure remains evidence for the future UP-007 candidate, which does not block release. |
| M0-014 | BLOCKED | — | Requires a native Windows SDK/runner and copied-byte instrumentation. |
| M0-015 | COMPLETE | [`docs/evidence/M0-015/README.md`](../evidence/M0-015/README.md) | Provider matrix and M0-016 PoC contract frozen; ADR-0003 selects AWS-LC for Linux only. |
| M0-016 | BLOCKED | [`docs/evidence/M0-016/README.md`](../evidence/M0-016/README.md) | AWS-LC glibc/musl schema-v2 results PASS every capability; seven retained cells remain PARTIAL and Windows/mobile native evidence is missing. |
| M0-017 | BLOCKED | — | Depends on M0-012 and M0-016 native evidence. |
| M0-018 | COMPLETE | [`docs/evidence/M0-018/README.md`](../evidence/M0-018/README.md) | Versioned threat register, fail-closed validator, tests and CI are active. |
| M0-019 | BLOCKED | — | Depends on complete M0-006 through M0-014 evidence; M0-010..014 are not all complete. |
| M0-020 | BLOCKED | [`docs/architecture/adr/0003-linux-tls-provider.md`](../architecture/adr/0003-linux-tls-provider.md) | Linux profile selects pinned AWS-LC; the global six-platform provider decision remains deferred. |
| M0-021 | BLOCKED | — | Future upstream-candidate inventory. It requires all M0 gate evidence and the accepted Transport SPI, but it does not block a Wirestack release. |
| M0-022 | BLOCKED | — | Depends on M0-004 through M0-020 and M0-024. It does not depend on M0-021 or an upstream source change. |
| M0-023 | COMPLETE | [`docs/evidence/M0-023/README.md`](../evidence/M0-023/README.md) | ADR-0004 freezes the current Linux release target as glibc and defers musl to P1-011 until the Cangjie SDK supports it. |
| M0-024 | COMPLETE | [`docs/evidence/M0-024/README.md`](../evidence/M0-024/README.md) | ADR-0005 removes runtime and `std.net` source changes from the release dependency graph; unsupported transport capabilities fail through stable public Wirestack contracts. |

## Linux M1 closure work

This table records Linux-only completion and does not generalize to the global
six-platform milestone.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M1-001 | COMPLETE | [`docs/evidence/M1-001/README.md`](../evidence/M1-001/README.md) | The Linux static project has physical Transport Core and StdNet packages, co-located package tests, an adapter benchmark harness, enforced internal dependency rules, and no legacy stdx network dependency. |
| M1-002 | COMPLETE | [`docs/evidence/M1-002/README.md`](../evidence/M1-002/README.md) | Checked non-copying immutable and mutable spans reject invalid constructor, slice, and advance ranges, retain the original array, support write-through conversion, and preserve empty-end semantics without exposing native addresses. |
| M1-003 | COMPLETE | [`docs/evidence/M1-003/README.md`](../evidence/M1-003/README.md) | `Deadline` uses only `MonoTime`, clamps expired budgets to zero, accepts an injected clock, and caps every child expiry at its parent, including delayed, zero-duration, and already-expired cases. |
| M1-005 | COMPLETE | [`docs/evidence/M1-005/README.md`](../evidence/M1-005/README.md) | Immutable operation inputs retain Deadline, cancellation, trace, and event destination across derivation; relative and absolute helpers cannot extend the parent, and a pre-cancelled write produces no peer data. |
| M1-006 | COMPLETE | [`docs/evidence/M1-006/README.md`](../evidence/M1-006/README.md) | Read-only bounded trace identifiers propagate unchanged; events are disabled by default, expose no sensitive protocol payload fields, and isolate user sink failures. |
| M1-007 | COMPLETE | [`docs/evidence/M1-007/README.md`](../evidence/M1-007/README.md) | Structured errors retain stable category, phase, code, retryability, optional native code, both endpoints and cause; received HTTP 4xx/5xx statuses remain responses. |
| M1-008 | COMPLETE | [`docs/evidence/M1-008/README.md`](../evidence/M1-008/README.md) | One terminal winner drains the bounded cleanup registry before its callback; unregister and late registration have explicit semantics, cleanup failures are isolated, and 100-round registration/completion/unregister races retain exactly-once behavior. |
| M1-010 | COMPLETE | [`docs/evidence/M1-010/README.md`](../evidence/M1-010/README.md) | `DuplexTransport` semantics are frozen; lifecycle claims enforce one reader and one writer, and MemoryTransport proves empty-buffer, half-close, cancellation, deadline, close and abort behavior. |
| M1-011 | COMPLETE | [`docs/evidence/M1-011/README.md`](../evidence/M1-011/README.md) | `writeAll` and `readExact` retain one absolute operation budget across partial I/O, reject invalid progress without spinning, preserve partial results, and distinguish premature EOF, cancellation and deadline failure. |
| M1-012 | COMPLETE | [`docs/evidence/M1-012/README.md`](../evidence/M1-012/README.md) | `TransportListener` and the Linux adapter enforce a bounded backlog, cancellable and deadline-aware accept, deterministic close wakeup, exactly-once terminal selection and structured accept errors. |
| M1-013 | COMPLETE | [`docs/evidence/M1-013/README.md`](../evidence/M1-013/README.md) | `MemoryTransport` now includes a bounded listener and manually advanced FIFO scheduler while preserving paired partial I/O, half-close, EOF, backpressure and terminal cleanup. |
| M1-014 | COMPLETE | [`docs/evidence/M1-014/README.md`](../evidence/M1-014/README.md) | Bounded read/write scripts reproduce manual delay, short I/O, EOF, terminal reset, cancellation races and structured error phases through a FIFO virtual waiter. |
| M1-015 | COMPLETE | [`docs/evidence/M1-015/README.md`](../evidence/M1-015/README.md) | Linux construction accepts only resolved `SocketEndpoint` values, creates or receives the exclusively owned socket inside the adapter package, exposes no socket alias or private handle, and fast-fails a pre-cancelled context before socket construction. |
| M1-018 | COMPLETE | [`docs/evidence/M1-018/README.md`](../evidence/M1-018/README.md) | `writeSome` performs bounded partial writes through one connection-retained exact-size staging array, the 16 KiB default carries a typical TLS record, and copied bytes remain measurable; the canonical repository gate separately retains one unrelated HTTP/2 package-interference error. |
| M1-019 | COMPLETE | [`docs/evidence/M1-019/README.md`](../evidence/M1-019/README.md) | Native Linux loopback qualification proves both directional shutdown calls return stable `Unsupported` without changing the bidirectional connection; the adapter uses no private ABI and does not depend on UP-003. |
| M1-020 | COMPLETE | [`docs/evidence/M1-020/README.md`](../evidence/M1-020/README.md) | Linux loopback qualification proves close-first retains peer EOF, abort-first produces a non-EOF terminal result, active reads wake, repeated mixed terminal calls preserve the first result, and the adapter uses only public `std.net` socket options. |
| M1-022 | COMPLETE | [`docs/evidence/M1-022/README.md`](../evidence/M1-022/README.md) | Native Linux qualification covers cancellation, Deadline, local close, listener errors, and an unclassified connect failure with stable coordinates, optional native code, retained endpoints and no message matching. |
| M1-023 | COMPLETE | [`docs/evidence/M1-023/README.md`](../evidence/M1-023/README.md) | Native Linux qualification proves provider-neutral backend, `cjnative` runtime family, mirrored typed endpoints, stable capability flags and post-close diagnostic retention without guessing an operating-system event backend. |
| M1-024 | COMPLETE | [`docs/evidence/M1-024/README.md`](../evidence/M1-024/README.md) | Deterministic Linux tests admit blocked read/write operations before close/abort, cover both success/cancel orders without leaked data, and retain supported and unsupported half-close, repeated terminal calls and exactly-once registration cleanup. No runtime or `std.net` source change is required. |
| M1-025 | COMPLETE | [`docs/evidence/M1-025/README.md`](../evidence/M1-025/README.md) | The Linux profile revalidates the five-payload same-binary benchmark and digest-pinned 24-hour soak, retains 100,000-iteration cleanup workloads, and measures blocked read/write cancellation P99 at 9.098 ms and 4.118 ms. No runtime or `std.net` source change is required. |
| M1-027 | COMPLETE | [`docs/evidence/M1-027/README.md`](../evidence/M1-027/README.md) | The internal background fast path reduces empty `readSome` P50 from 297.042 ns to 92.110 ns; the formal Linux 5-payload x 11-round GATE-NET-05 comparison passes every throughput and P95 threshold with zero staging copies. |

## Linux M2 closure work

This table records Linux-only deterministic completion and does not override
the native platform dependencies in the global backlog.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M2-001 | COMPLETE | [`docs/evidence/M2-001/README.md`](../evidence/M2-001/README.md) | Canonical ASCII/A-label host names and typed immutable IPv4/IPv6/zone endpoints cover exact name, label and port boundaries without implicit DNS or accepting authority syntax as a host. |
| M2-003 | COMPLETE | [`docs/evidence/M2-003/README.md`](../evidence/M2-003/README.md) | A fixed native pthread pool provides strictly bounded FIFO DNS admission, metrics, prompt canonical cancellation/Deadline handling and worker cleanup without occupying scheduler carriers or using private runtime ABI. |
| M2-005 | COMPLETE | [`docs/evidence/M2-005/README.md`](../evidence/M2-005/README.md) | The public resolver, stable errors, cancellation, lifecycle, and default client integration pass on native Linux glibc. ADR-0004 defers musl to P1-011. |
| M2-010 | COMPLETE | [`docs/evidence/M2-010/README.md`](../evidence/M2-010/README.md) | Immutable direct and explicit-proxy routes separate origin/connect targets and DNS ownership while retaining bounded network-binding, TLS-context and ALPN parameters; system-proxy discovery remains out of scope. |
| M2-014 | COMPLETE | [`docs/evidence/M2-014/README.md`](../evidence/M2-014/README.md) | Scripted resolver and connector tests cover IPv6 first success and blackhole fallback, simultaneous success, all-fail, pre-cancel, success-plus-cancel and the exact Deadline publication boundary. |
| M2-015 | COMPLETE | [`docs/evidence/M2-015/README.md`](../evidence/M2-015/README.md) | Native glibc network namespaces prove IPv6 available/blackhole fallback, 20/100 ms RTT, 1% loss, joined losers with bounded resources, and one shared Deadline for 2/8 candidates. |
| M2-016 | COMPLETE | [`docs/evidence/M2-016/README.md`](../evidence/M2-016/README.md) | The isolated `-O2` native benchmark retains DNS, first-attempt, winner, total, connection-count and cancellation metrics across six profiles and 528 measured samples; cancellation P99 is 3.908 ms against the 50 ms limit. |

## Linux M3 closure work

This table records Linux glibc TLS completion only. It does not complete the
global six-platform M3 milestone.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M3-028 | COMPLETE | [`docs/evidence/M3-028/README.md`](../evidence/M3-028/README.md) | Native Linux qualification passes 70 deterministic TLS/trust tests, four bounded fuzz targets, TLS 1.2/1.3 OpenSSL interoperability, dependency scanning, body and idle-memory limits, 11-round full/resumed handshake gates, and 1.2125 times the pinned stdx bulk throughput. |
| M3-029 | COMPLETE | [`docs/evidence/M3-029/README.md`](../evidence/M3-029/README.md) | Provider-neutral public client/server contexts, existing-transport handshake, TLS connection/listener ownership, negotiated metadata and stable errors pass public-package tests, clean-consumer Linux TLS acceptance and current pre-1.0 ownership guards; historical experimental API compatibility is not required. |
| M3-030 | COMPLETE | [`docs/evidence/M3-030/README.md`](../evidence/M3-030/README.md), [`platform-provider-matrix.json`](../evidence/M3-030/platform-provider-matrix.json), [`native-abi-report.json`](../evidence/M3-030/native-abi-report.json), [`release-validation.json`](../evidence/M3-030/release-validation.json), [`sbom-validation.json`](../evidence/M3-030/sbom-validation.json) | The final six-command Linux gate passes. The provider ABI v1 contract records and validates 56 C signatures, Cangjie FFI declarations, native header prototypes and archive symbols; M7-029 independently closes both ABI High findings. Only Linux x86_64 glibc with AWS-LC 5.5.0 is implemented. |

## Future upstream enhancements

`UP-001` through `UP-007` are not Wirestack release dependencies. They remain
**BLOCKED / DO NOT START** until a failed gate provides reproducible evidence
and an approved minimal upstream-interface RFC. Actual `std.net` or runtime
source changes belong in their upstream repositories, not in the Wirestack
worktree.

No current Wirestack task may list an `UP-*` task or a runtime/`std.net` source
change as a dependency, readiness condition, completion condition, or release
gate. Supported profiles must close against public SDK capabilities and the
documented Wirestack fallback.

The M0-007 and M0-009 capability probes record that the supplied SDK exposes no
public `TcpSocket.abort()` and no public cancellation member. M0-013 additionally
shows native Linux carrier-thread starvation under delayed DNS. Wirestack uses
stable capability fallback for missing socket features and a bounded resolver
pool for DNS. UP-003, UP-005, and UP-007 remain optional future improvements;
none authorizes an upstream implementation task.

## Linux M5 closure work

This table records Linux-only HTTP/1 completion. It does not replace the global
platform matrix.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M5-030 | COMPLETE | [`docs/evidence/M5-030/README.md`](../evidence/M5-030/README.md) | Native Linux O2 comparison reaches 2.0857 times the pinned stdx keep-alive throughput; 16/64 MiB streaming RSS growth is bounded; client/server, CONNECT, and mTLS examples are documented. |

## Later milestones

M1 through M7 and P1 global completion remains blocked by backlog dependencies. A
Linux-only result must not be generalized to the six-platform release matrix.

The following M6 closure work is now formally tracked from the current Linux
source audit; status here describes task readiness, not global milestone completion:

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M6-021 | COMPLETE | [`docs/evidence/M6-021/README.md`](../evidence/M6-021/README.md) | Public `HttpServer` dispatches real TLS loopback connections by negotiated `h2` or `http/1.1`, with bounded H2 streams, graceful GOAWAY and structured stream errors. |
| M6-022 | COMPLETE | [`docs/evidence/M6-022/README.md`](../evidence/M6-022/README.md) | Typed request, connection and H2 stream handles provide idempotent public cancellation across routing/DNS through body ownership; real H1/H2 loopback tests prove connection fan-out, stream isolation and prompt terminal cleanup, including a 100/100 focused stability rerun after correcting the sibling-read acceptance order. |
| M6-023 | COMPLETE | [`docs/evidence/M6-023/README.md`](../evidence/M6-023/README.md) | Parallel real H1/H2 SSE profiles each ran for at least one hour and consumed more than 90 million numbered events with bounded resource trends, slow-consumer backpressure, public cancellation below 50 ms and H2 sibling isolation. |
| M6-024 | COMPLETE | [`docs/evidence/M6-024/README.md`](../evidence/M6-024/README.md) | A zero-window-only connection-credit flush and bounded least-recently-served send reservations keep 1/10/100 siblings live while the slow stream remains open. Real TLS h2 passes 100/100 independent runs and 10,000 sibling responses without timeout or connection abort; the public API and existing bounds are unchanged. |
| M6-025 | COMPLETE | [`docs/evidence/M6-025/README.md`](../evidence/M6-025/README.md) | TLS scratch is leased exclusively to each active read/write call and returned to bounded per-direction caches, so HTTP/2 full-duplex facade traffic no longer aliases active mutable buffers. The original three-case sequence completed 100/100 same-process rounds (300 scenario executions), `src/http` passed 66/66 non-Performance cases, `scripts/check` passed 538/538 non-Performance cases, and the requalified M3-028 performance gate remained PASS. |
| M6-026 | COMPLETE | [`docs/evidence/M6-026/README.md`](../evidence/M6-026/README.md) | Concurrent pool claims now publish initial HEADERS in increasing stream-ID order; cancellation before publication advances bounded local ordering without an idle-stream RST. The real-TLS public gate passes 1,000 batches and 2,000 exact bodies with zero failure, timeout or residual handler, and the full repository check passes. |

## Linux M7 stable-release closure

These tasks close only the native Linux x86_64 glibc profile. They do not
change the status of the six-platform M7-001 through M7-017 tasks.

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M7-018 | COMPLETE | [`docs/evidence/M7-018/README.md`](../evidence/M7-018/README.md) | The Linux M7 graph now has separate trace, architecture, artifact, soak, fuzz, performance, SBOM, API, documentation, security, signing and candidate-report tasks. No Linux task depends on M1-026, M4, `UP-*`, or runtime/`std.net` source changes. |
| M7-019 | COMPLETE | [`docs/evidence/M7-019/README.md`](../evidence/M7-019/README.md) | The fail-closed Linux audit maps 32 P0 requirements, all 15 lifecycle invariants and all 22 release criteria. It records 31/32 P0 PASS, 15/15 invariants PASS, 15/22 release criteria PASS, six release gaps and one mobile-only NOT_APPLICABLE item. runtime/std changes remain optional future requirements, never Wirestack dependencies. |
| M7-020 | COMPLETE | [`docs/evidence/M7-020/README.md`](../evidence/M7-020/README.md) | The repeatable Linux audit scans 210 Cangjie files, 12 build/native files and 46 public-package files. Core has no `std.net`; public packages expose no low-level types; private socket ABI, old bridges, global TLS providers, and system OpenSSL loaders are absent. runtime/std source changes remain optional future work. |
| M7-021 | COMPLETE | [`docs/evidence/M7-021/README.md`](../evidence/M7-021/README.md) | The native glibc artifact is byte-reproducible, installs in a clean CJPM consumer, runs an HTTPS client/server and runtime-info smoke, and has no system OpenSSL dependency or loader string. |
| M7-022 | COMPLETE | [`docs/evidence/M7-022/README.md`](../evidence/M7-022/README.md) | The final candidate artifact ran for 86,400.354 seconds under the mixed H1, H2, SSE, cancellation, reset, churn and idle workload. All 507,408 spawned tasks joined, terminal owners were zero, and 289 application plus 1,440 process-tree samples passed every bounded-resource trend. |
| M7-023 | COMPLETE | [`docs/evidence/M7-023/README.md`](../evidence/M7-023/README.md) | The native `-O2` Linux gate consumes digest-pinned corpora for all ten PRD fuzz targets, passes 6,465 deterministic iterations, retains bounded crash artifacts and validates checked-in-coordinate replay; the current run has no unresolved crash. |
| M7-024 | COMPLETE | [`docs/evidence/M7-024/README.md`](../evidence/M7-024/README.md) | The post-M6-026 HTTP/2 matrix was rerun with the original 1/10/100-stream, forward/reverse and 20-round controls. The digest-pinned Linux manifest aggregates seven raw reports and passes 254 field-level checks across all eight domains, including equality of the H2 report, manifest and current production-source fingerprints. |
| M7-025 | COMPLETE | [`docs/evidence/M7-025/README.md`](../evidence/M7-025/README.md) | The SPDX 2.3 SBOM, provider manifest and deterministic fingerprint bind the qualified artifact, provider/resolver digests, target, toolchain, trust, capabilities and features. runtime/std source changes remain optional long-term upstream requirements, not release dependencies. |
| M7-026 | COMPLETE | [`docs/evidence/M7-026/README.md`](../evidence/M7-026/README.md) | The post-M7-032 pre-1.0 Linux inventory records package `wirestack` major 0, 243 declarations, 103 public alias targets and all three public cancellation handles. It is not a compatibility target for the earlier experimental API. The deterministic gate rejects legacy/global TLS, low-level socket and OpenSSL cipher-string surfaces without depending on runtime/std source changes. |
| M7-027 | COMPLETE | [`docs/evidence/M7-027/README.md`](../evidence/M7-027/README.md) | The Linux migration guide covers Deadline, scoped cancellation, custom CA, mTLS, streaming bodies, bounded retry, structured errors and OpenSSL removal. A native temporary consumer builds and runs public HTTPS, caller-owned transport TLS, CONNECT configuration, H1/H2 server, SSE, custom CA, mTLS and scoped-cancellation examples. |
| M7-028 | COMPLETE | [`docs/evidence/M7-028/README.md`](../evidence/M7-028/README.md) | The Linux independent-review package covers threat model, architecture, provider and C ABI, parsers and bounds, key/trust handling, fuzz, SBOM, known limits, environment and reproduction. Its refreshed fail-closed index records 8 current PASS reports, 3 current bundle-bound inputs, 1 stale point-in-time audit and 1 historical non-gating entry; pre-1.0 compatibility is not a release gate. |
| M7-029 | COMPLETE | [`docs/evidence/M7-029/README.md`](../evidence/M7-029/README.md) | A no-history process-isolated reviewer accepted final-candidate package `47da664a9d0e9450a9fe38c0a7fea3f39f4afba721f064a4a5fd917f2d3ea70e` from a clean detached checkout. All 17 findings are Fixed: 2 Critical, 14 High, and 1 Medium. The final 86,400-second soak remains M7-022 work. |
| M7-030 | IN_PROGRESS | [`docs/evidence/M7-030/README.md`](../evidence/M7-030/README.md) | Dependencies are complete. Local signature, tamper rejection, clean-consumer, provider update and authorized rollback rehearsals pass; the production GitHub-hosted OIDC attestations have not run. |
| M7-031 | BLOCKED | — | Depends on M7-019 through M7-030 and M7-032. |
| M7-032 | COMPLETE | [`docs/evidence/M7-032/README.md`](../evidence/M7-032/README.md) | Public contracts now have public owners; architecture guards reject internal type leakage and public/internal cycles. The new pre-1.0 inventory records 243 declarations, 103 public alias targets and zero internal alias targets. No compatibility layer or verdict was added. |

## P1 independent repository infrastructure

| ID | Status | Evidence | Notes |
|---|---|---|---|
| P1-012 | COMPLETE | [`docs/evidence/P1-012/README.md`](../evidence/P1-012/README.md) | Fail-closed repository diagnostics, task contracts, layered checks and source-bound evidence freshness validation pass on Linux glibc; no long-duration gate ran. |
