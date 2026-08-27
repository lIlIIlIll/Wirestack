# M1-015 Linux ownership and construction evidence

## Status

- Task: `M1-015`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

This task qualifies the `StdNetTransport` ownership and construction boundary.
It does not claim the global six-platform M1 exit gate.

## Dependency decision

M1-010 and M0-024 are complete and have retained evidence. Global M0-019
remains blocked by non-Linux platform gates. ADR-0002 permits Linux tasks to use
their completed Linux-specific dependencies, and ADR-0004 defines the current
Linux target as native glibc x86_64. This evidence does not change the global
M0-019 status.

## Acceptance mapping

| Criterion | Current implementation and evidence | Result |
|---|---|---|
| Construction accepts only a resolved IP endpoint | Public `StdNetTransport.connect` accepts `SocketEndpoint`. That type contains an `IpAddress` and port, not a host name. `toStdEndpoint` constructs `IPSocketAddress` directly. | PASS |
| The adapter exclusively owns its `TcpSocket` | Public connect creates the socket inside the adapter. The socket field and initializer are private. No public constructor accepts a caller-owned socket. | PASS |
| Accepted sockets transfer ownership once | `fromAccepted` is internal and is called only by `StdNetTransportListener` after `accept`. The accepted socket is not returned separately or exposed after wrapping. | PASS |
| No private native handle is cached or exposed | The adapter stores a private public-SDK `TcpSocket` reference only. The architecture guard rejects `CJ_MRT_Sock*` and public leakage of `std.net` types. | PASS |
| Resolved-IP construction produces a usable duplex transport | `connectsByResolvedIpAndTransfersBothDirections` connects through a loopback `SocketEndpoint`, records the actual local endpoint, and transfers bytes in both directions. | PASS |
| Pre-cancelled construction has no socket side effect | `preCancelledConnectDoesNotCreateASocket` receives `Cancelled`; `checkContext` runs before `TcpSocket` construction. | PASS |

The public boundary is stricter than a caller-owned socket wrapper. Wirestack
does not expose such a wrapper, so callers cannot retain a usable socket alias
after construction.

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='StdNetTransportTest.connectsByResolvedIpAndTransfersBothDirections,StdNetTransportTest.preCancelledConnectDoesNotCreateASocket' \
  --no-color --no-progress
```

Result: 2 passed, 563 skipped, 0 failed, 0 errors. Exit status 0.

```bash
sh scripts/architecture-guard
```

Result: `architecture guard: PASS`. Exit status 0.

Direct execution of `scripts/architecture-guard` returned exit 126 because the
file is not executable. Running the documented shell script through `sh`
executed the guard successfully; no product source changed to work around it.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository-tool tests, 114 gate-tool
tests, 23 benchmark-tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. The non-performance Cangjie suite finished with 545 passed, 20
skipped, 0 failed, and 0 errors. The build retained existing unused-function
warnings for resolver metrics and two package-visible test hooks.

## Scope limits

- No runtime, std, or SDK source was modified.
- No SDK component was built.
- M1-016 separately owns connect Deadline, cancellation during connect, and
  endpoint result qualification.
- Windows, macOS, Android, iOS, and Harmony were not executed.
