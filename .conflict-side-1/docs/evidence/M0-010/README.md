# M0-010 evidence: GATE-NET-05 large-buffer and copy characteristics

## Status

- Task implementation and Linux profiling harness: **COMPLETE**
- Linux x86_64 application-visible large-buffer profile: **PASS**
- Linux copied-byte/allocation profile: **INCOMPLETE**
- Native Windows copy profile: **BLOCKED**
- Global GATE-NET-05: **INCOMPLETE**

The supplied SDK compiled and executed a real `std.net.TcpSocket` receive probe
with one reusable 64 KiB destination buffer. The host streamed 1 MiB and
100 MiB bodies in bounded 64 KiB chunks. Every received byte and the exact total
were verified. The Linux path produced application-visible reads larger than
4 KiB, so this host does not exhibit a fixed 4 KiB cap.

## Measurements

For each payload size the formal run used one warmup plus five measured samples
and retained:

- every application-visible `read()` size;
- exact client and server byte totals;
- client transfer duration and throughput;
- process peak RSS and raw `/proc/<pid>/status` RSS samples;
- actual server `send()` sizes;
- process exit, timeout, stdout and stderr evidence.

Allocation counts and copied bytes per operation are explicitly unavailable in
this public SDK/runtime setup. No values are inferred. A future
`StdNetTransport` comparison and native Windows instrumentation remain required.

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
  bash scripts/gate-net05-large-buffer-profile \
    --warmup 1 \
    --repetitions 5 \
    --repository-revision <tested-commit>
```

## Boundary

This task does not claim the global GATE-NET-05 passes. It adds no production
Transport, TLS or HTTP code, no private socket handle or `CJ_MRT_Sock*` use, and
no unmeasured allocation/copy claim.
