# M0-006 evidence: GATE-NET-01 close/wakeup

## Status

- Task: **COMPLETE**
- Linux x86_64 supplied-SDK decision: **PASS**
- Global six-platform GATE-NET-01: **INCOMPLETE**
- Conditional upstream work unlocked: **none**

## Scope

The harness compiles four probes against the supplied Cangjie SDK and verifies:

1. blocked `TcpSocket.read` + another task calls `close`;
2. blocked `TcpSocket.write` + another task calls `close`;
3. pending `TcpSocket.connect` + another task calls `close`;
4. blocked `TcpServerSocket.accept` + another task closes the listener.

The connect case uses a saturated local listen backlog so a pending operation is observed rather than inferred from an unroutable address. The write case requires two stable progress samples before close. No result is accepted unless the operation was pending before close and the waiter terminates through the expected typed `SocketException` category.

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
bash scripts/gate-net01-close-wakeup \
  --warmup 2 \
  --repetitions 20 \
  --repository-revision 0234649070cf486689cf68d73179142f66ad78eb
```

The complete schema-versioned result is stored as `linux_x86_64/result.json.gz`; its digest and a human-readable summary are committed beside it.

## Boundary

This evidence applies only to the supplied Linux x86_64 SDK and current public `std.net` behavior. It does not establish Windows, macOS, Android, iOS, HarmonyOS/OpenHarmony, musl, or future `StdNetTransport` behavior, and it does not mark the global gate complete.
