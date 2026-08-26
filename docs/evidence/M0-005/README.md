# M0-005 Linux raw TCP baseline audit

- Task: `M0-005`
- Profile: Linux x86_64 glibc
- Result: **COMPLETE**
- Audit date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Decision

The previous `COMPLETE` status had no retained M0-005 evidence file and was not
supported by the repository. The schema-v3 runner now retains every required
payload on both Linux loopback and a separate native KVM Linux peer, including
throughput, latency, read-count, thread, RSS, native allocation-event and
receive-copy measurements.

The retained M0-010 evidence covers 1 MiB and 100 MiB loopback receives. The
dedicated M0-005 runner closes the missing loopback payload and thread-count
coverage without changing M0-010's conclusions.

The formal KVM run uses a separate kernel and virtual NIC over `virbr0`; the
route is neither loopback nor a synthetic local-address alias. M0-005 is now
complete. This does not complete M0-010's future `StdNetTransport` comparison
or the global Windows M0-014 profile.

## Requirement audit

| Requirement | Current evidence | Decision |
|---|---|---|
| 0 B / 1 KiB / 16 KiB / 64 KiB payloads | five retained measurements per payload | PASS |
| 1 MiB / 100 MiB payloads | five retained measurements per payload | PASS |
| loopback | all six payloads, exact bytes and bounded process execution | PASS |
| LAN | all six payloads against native KVM Linux `5.15.0-117-generic` over `virbr0` | PASS |
| throughput and P50/P95/P99 latency | retained for every payload and topology | PASS |
| allocations/op | one separate `heaptrack` sample per payload records native allocator events for the complete process operation | PASS |
| copied bytes/op | one separate `strace` sample sums successful `recvfrom` bytes entering the process buffer and verifies the exact payload | PASS |
| thread count | sampled from `/proc/<pid>/status`; maximum was six for every case | PASS |
| peak RSS | retained for every payload and topology | PASS |
| durable raw baseline report | [`linux_x86_64/loopback-baseline.json`](linux_x86_64/loopback-baseline.json), SHA-256 `c6a406682d689224b8bfbdc9d93cde363fa0ce6dcb7213d0733cd78364fa88f9` | PASS |

## Current reproducible evidence

Command:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack bash scripts/gate-net05-large-buffer-profile --quick
```

Result: exit 0. The single 1 MiB loopback sample transferred exact bytes,
observed a 65,536-byte maximum read (not a fixed 4 KiB cap), measured
22.195 MiB/s and 27,852 KiB peak RSS. The generated schema-v1 report still
declared `allocation_count` and `copied_bytes_per_operation` unavailable and
made no global GATE-NET-05 or `StdNetTransport` claim.

The first attempt invoked the non-executable script path directly through the
environment wrapper and exited 126. The documented `bash` entry point above is
the valid command; no source change was made for that invocation error.

Formal loopback plus KVM LAN command, run from the M0-005 LAN working tree:

```text
timeout 120s /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack bash scripts/gate-m0-005-raw-tcp-baseline --warmup 1 --repetitions 5 --repository-revision working-tree-m0-005-lan --output docs/evidence/M0-005/linux_x86_64/loopback-baseline.json --lan-peer-host 192.168.122.100 --lan-peer-port 19005 --lan-peer-image-id cirros-0.6.3-x86_64-disk.img --lan-peer-image-sha256 7d6355852aeb6dbcd191bcda7cd74f1536cfe5cbf8a10495a7283a8396e4b75b --lan-peer-hypervisor libvirt-kvm-virbr0 --lan-peer-binary-sha256 1eedad6a7517041e76ffa25145b9a7e73308c9d1c91a3a8072cb85f6c6187b61
```

Result: exit 0 in 84.2 seconds including one tool yield. Every measured sample
passed exact-byte and payload-pattern validation. The report records
`loopback=PASS`, `LAN=PASS`, `Linux=PASS`, and `task=COMPLETE`.

| Topology | Payload | P50 MiB/s | P50 reads | Native allocations/op | Copied bytes/op |
|---|---|---:|---:|---:|---:|
| loopback | 0 B | 0 | 0 | 9,160 | 0 |
| loopback | 1 KiB | 7.779 | 1 | 9,162 | 1,024 |
| loopback | 16 KiB | 14.082 | 1 | 9,160 | 16,384 |
| loopback | 64 KiB | 15.164 | 1 | 9,162 | 65,536 |
| loopback | 1 MiB | 13.547 | 21 | 9,160 | 1,048,576 |
| loopback | 100 MiB | 19.105 | 1,714 | 378,493 | 104,857,600 |
| KVM LAN | 0 B | 0 | 0 | 9,162 | 0 |
| KVM LAN | 1 KiB | 9.969 | 1 | 9,160 | 1,024 |
| KVM LAN | 16 KiB | 15.748 | 1 | 9,162 | 16,384 |
| KVM LAN | 64 KiB | 14.773 | 1 | 9,160 | 65,536 |
| KVM LAN | 1 MiB | 15.128 | 19 | 9,160 | 1,048,576 |
| KVM LAN | 100 MiB | 16.612 | 1,620 | 409,206 | 104,857,600 |

The LAN peer reported `Linux 5.15.0-117-generic x86_64`. The host route was
`192.168.122.100 dev virbr0 src 192.168.122.1`. The peer used the checksum-pinned
CirrOS 0.6.3 x86_64 image and the statically linked peer built from
[`m0_005_lan_peer.c`](../../../tools/gates/native/m0_005_lan_peer.c). The peer
has a 180-second bounded accept, an eight-connection listen backlog, a fixed
64-KiB send buffer and a fixed connection matrix; it exits after the matrix.

Performance samples are deliberately uninstrumented. Each payload also has one
separate instrumented operation. `heaptrack 1.5.0` counts calls to the native
allocation functions for the complete Cangjie process operation. `strace 7.0`
records every `recvfrom` result; the report retains the raw trace, its digest,
the successful call count and the exact sum of positive return values. The
instrumented probe suppresses per-read logging so diagnostic output does not
inflate its allocation count.

The allocation metric is not a claim about Cangjie language-level object
allocations. The copied-byte metric is the unavoidable kernel-to-process-buffer
copy observed at the raw `std.net` boundary; it does not infer unobservable
internal `memcpy` traffic.

The first formal run exposed a report-classification bug: a 1 KiB payload was
mistaken for a fixed 4 KiB cap. The runner now requires the payload itself to
exceed 4 KiB before making that classification. An added regression test
passes, and the discarded report is not retained. The final report marks every
case `fixed_4k_cap=false`.

Static peer build and local six-payload protocol smoke:

```text
/usr/lib/llvm15/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -static tools/gates/native/m0_005_lan_peer.c -o /tmp/wirestack-m0-005-lan-peer
```

Result: exit 0. `file` classified the output as a statically linked x86-64 ELF.
The local protocol smoke received exact payload totals
`0/1024/16384/65536/1048576/104857600`, verified every byte as `37`, and the
peer exited with `RESULT status=PASS connections=6 bytes_per_matrix=105989120`.

Focused runner tests:

```text
python3 -m unittest tools.gates.tests.test_net05_large_buffer_profile tools.gates.tests.test_m0_005_raw_tcp_baseline -v
```

Result: exit 0; all 16 parser, classifier, LAN completeness, non-loopback route,
instrumentation, zero-byte, payload-matrix and fail-closed report tests passed.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python suites passed 50, 94 and 11 tests; the architecture guard
passed; `cjpm check` and `cjpm build` succeeded. The Cangjie non-performance
suite reported 515 total, 511 passed, 4 intentionally skipped, zero errors and
zero failures. The build retained two unrelated unused-function warnings in
the transport adapter and HTTP/1 connection pool.

## Measurement capability evidence

The cached Cangjie `main` standard-library index records:

- `std.runtime.getUsedHeapSize(): Int64` for physical heap occupancy;
- `std.runtime.getAllocatedHeapSize(): Int64` for currently used heap bytes;
- `std.runtime.getGCCount(): Int64` and aggregate GC freed-size/time counters.

It contains no public allocation-event counter. Heap occupancy deltas therefore
remain unsuitable for allocations/op because GC timing, retained objects and
allocator reuse change them. The gate instead uses the installed supported
Linux profiling tools against the dynamically linked public program: heaptrack
interposes the native allocation functions and strace observes `recvfrom`
returns. Wirestack still calls no private runtime or socket ABI.

## Boundary

The temporary KVM domain, HTTP bootstrap service and downloaded image were
removed after the run. The committed report retains the peer kernel, machine,
image and binary digests, non-loopback route, raw syscall traces and every
sample. M0-005 makes no `StdNetTransport`, TLS, HTTP, Windows or musl claim.
