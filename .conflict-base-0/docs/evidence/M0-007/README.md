# M0-007 evidence: GATE-NET-02 full duplex and close races

## Status

- Task: **COMPLETE**
- Linux x86_64 functional read/write and close-race result: **PASS**
- Linux GATE-NET-02: **INCOMPLETE**
- Global six-platform GATE-NET-02: **INCOMPLETE**

The task is complete because all required behaviors were executed and retained. The gate is not complete because the public `TcpSocket` API in the supplied SDK has no `abort()` member and because only Linux x86_64 has run.

## Executed scenarios

1. One reader and one writer concurrently transfer independent 256 KiB streams on one `TcpSocket`; both directions verify exact byte values.
2. One blocked reader and one blocked writer race with `close()` across 100 deterministic seeds and delays from 1 to 100 ms.
3. Two simultaneous reads are executed and their actual outcomes recorded without declaring them the Wirestack contract.
4. Two simultaneous writes are executed; every successful write is verified byte-for-byte at the peer.
5. A compile-time public abort capability probe is executed. Compilation fails because `abort` is not a public member of `TcpSocket`; the diagnostic is retained by hash and bounded excerpt.

## Toolchain

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu
Cangjie Project Manager: 1.1.3
SDK archive SHA-256: bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d
```

## Execution

```bash
source /mnt/data/cangjie-env-wirestack.sh
bash scripts/gate-net02-full-duplex-races \
  --repetitions 20 \
  --race-seeds 100 \
  --repository-revision e756516541f0df1f568ad60175b62ed797c48da1
```

The complete schema-versioned result is stored as `linux_x86_64/result.json.gz`, with digests and a readable summary alongside it.

## Boundary

No private socket handle, `CJ_MRT_Sock*`, polling workaround, production Transport/TLS/HTTP implementation, or exception-message control flow is used. Same-direction results are observations of the current SDK, not the future Wirestack concurrency contract. The missing public abort capability remains an input to M0 architecture/upstream decisions; this task does not directly start an `UP-*` change.
