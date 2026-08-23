# M0-011 evidence: GATE-NET-06 leak and soak harness

## Status

- Harness and bounded Linux x86_64 execution: **PASS**
- M0-011 task: **INCOMPLETE**
- Global GATE-NET-06: **INCOMPLETE**

The task remains incomplete by design. The bounded run does not satisfy the
PRD's full transport/TLS cleanup counts, 24-hour soak, or six-platform native
matrix.

## Executed bounded scenarios

| Scenario | Iterations | Verification |
|---|---:|---|
| repeated connect/close | 2,000 | exact connect, accept, completion and close totals |
| repeated active echo/connect/close | 1,000 | exact 64-byte payload and echo totals |
| repeated peer reset | 1,000 | one public `SocketException` per reset |
| repeated close during blocked read | 500 | each waiter reached EOF or `SocketException` and terminated |

For every scenario the harness retains process exit/timeout state, server totals,
raw RSS samples, raw native file-descriptor samples and aggregate percentiles.
All subprocesses, server loops and sampler threads have explicit bounds.

## Deferred requirements

- 100,000 transport cleanup iterations: `NOT_RUN`.
- 100,000 TLS handshake-failure cleanups: `NOT_YET_APPLICABLE`.
- 24-hour idle/active mixed soak: `NOT_RUN`.
- Windows, macOS, Android, iOS and HarmonyOS/OpenHarmony: `BLOCKED`.

Non-execution never contributes to a PASS result.

## Toolchain

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu
Cangjie Project Manager: 1.1.3
SDK archive SHA-256: bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d
```

## Execution

```bash
source /mnt/data/cangjie-sdk/cangjie/envsetup.sh
scripts/with-host-gate-lock linux-native-gate -- \
  bash scripts/gate-net06-leak-soak
```

## Boundary

No production Transport/TLS/HTTP implementation, private socket handle,
`CJ_MRT_Sock*`, polling workaround or simulated platform result is added.
