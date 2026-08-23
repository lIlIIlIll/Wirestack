# M0-009 evidence: GATE-NET-04 EOF and terminal classification

## Status

- Task: **COMPLETE**
- Linux x86_64 FIN/RST/local-close classification: **PASS**
- Linux GATE-NET-04: **INCOMPLETE**
- Global six-platform GATE-NET-04: **INCOMPLETE**

Every required scenario was executed or represented by a compile-time public API
capability probe. The Linux gate remains incomplete because the supplied SDK
exposes neither public `TcpSocket.abort()` nor `TcpSocket.cancel()`.

## Executed scenarios

1. Peer graceful FIN while `read()` is blocked.
2. Peer RST while `read()` is blocked.
3. Another Cangjie task closes the local socket while `read()` is blocked.
4. Ninety deterministic close/read races: 30 peer-first, 30 local-first, and
   30 equal-delay samples.
5. Public `abort()` and `cancel()` capability probes.

Classification uses return values and typed Cangjie catch arms only. Exception
message text is retained as bounded diagnostics but never drives control flow.

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
flock -x /mnt/data/wirestack-linux-native-gate.lock \
  python3 tools/gates/net04_terminal_evidence.py \
    --repetitions 20 \
    --race-seeds 90 \
    --repository-revision f284e9f079526013c4b547a4c851deb9a38661cd
```

The full schema-versioned result is stored as
`linux_x86_64/result.json.gz`, with compressed and uncompressed SHA-256 values
alongside it.

## Boundary

No private native handle, `CJ_MRT_Sock*`, TLS-layer EOF inference, polling
workaround, production Transport/TLS/HTTP implementation, or exception-message
classification is introduced. Missing public abort/cancel remains an input to
M0-021; it does not independently authorize an `UP-*` change.
