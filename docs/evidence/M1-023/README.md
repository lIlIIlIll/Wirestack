# M1-023 Linux transport diagnostics evidence

- Task: `M1-023`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Evidence |
|---|---|
| Transport backend | Both native loopback endpoints report `backend=std.net`; the deterministic adapter reports `backend=memory`. |
| Runtime family | Native endpoints report `runtimeIoBackend=cjnative`. The value names the stable runtime family and does not claim epoll, kqueue, IOCP, or io_uring discovery. |
| Typed endpoints | The client remote endpoint equals the listener endpoint. Accepted server local and remote endpoints are the exact inverse of the client endpoints. |
| Capabilities | Native endpoints report `supportsHalfClose=false` and `supportsAbort=true`; the deterministic adapter reports both supported. |
| Stable diagnostics | Closing the native client does not erase or change its backend, runtime family, endpoints, or capability flags. |
| Provider-neutral contract | `TransportInfo` contains only Wirestack strings, endpoints, and booleans. Transport Core imports no `std.net` type or private runtime ABI. |

The current public SDK does not expose the operating-system event mechanism.
Wirestack therefore reports `cjnative`, as allowed by ADR-0005, and does not
guess a more specific backend. This task does not depend on runtime or std
changes.

## Commands and results

Focused native Linux qualification:

```text
/home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter M123TransportDiagnosticsTest \
  --no-color --no-progress
```

Result outside the restricted socket sandbox: exit `0`. Both M1-023 cases
passed, with project summary `PASSED 2`, `SKIPPED 561`, `FAILED 0`, `ERROR 0`.
The first sandboxed attempt compiled the test and then failed before execution
because the unittest runner could not create its local control socket:
`SocketException: Failed to create socket 1: Operation not permitted`.

Static dependency checks:

```text
rp-rg -n "import std\\.net" src --glob '*.cj'
rp-rg -n "TcpSocket|TcpServerSocket|SocketException|CJ_MRT_Sock" \
  src/internal/transport --glob '*.cj'
rp-rg -n "runtimeIoBackend:\\s*\\\"(epoll|kqueue|iocp|io_uring)" \
  src --glob '*.cj'
```

Only the allowed `transport_stdnet` adapter and its benchmark tests import
`std.net`. The Transport Core and exact-backend scans returned no matches.

Canonical repository gate:

```text
scripts/check
```

Result outside the restricted socket sandbox: exit `0`. Tool tests passed
`57/57`, gate tests passed `114/114`, benchmark-tool tests passed `23/23`, and
the architecture guard, `cjpm check`, and `cjpm build` passed. The native test
summary was `PASSED 543`, `SKIPPED 20`, `FAILED 0`, `ERROR 0` out of `563`.
The sandboxed run reached the final test stage and then hit the same unittest
control-socket restriction. Existing unused-helper warnings remain unchanged.

## Compatibility and scope

No declaration, field layout, default, or runtime behavior changed. The source
change documents the existing `TransportInfo` contract, and the new tests lock
down its Linux behavior. The result covers native glibc. Exact event-backend
discovery remains an optional future SDK capability and is not a release
dependency.
