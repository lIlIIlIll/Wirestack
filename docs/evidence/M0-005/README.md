# M0-005 Linux raw TCP baseline audit

- Task: `M0-005`
- Profile: Linux x86_64 glibc
- Result: **BLOCKED**
- Audit date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Decision

The previous `COMPLETE` status had no retained M0-005 evidence file and is not
supported by the current repository. M0-005 requires a current `std.net` raw
TCP baseline for every 0 B, 1 KiB, 16 KiB, 64 KiB, 1 MiB and 100 MiB payload
over loopback and LAN, including throughput, latency, allocation, copied-byte,
thread and RSS measurements.

The retained M0-010 evidence is useful but is not a substitute for that matrix.
Its formal Linux run covers only 1 MiB and 100 MiB loopback receives. It records
read sizes, throughput, transfer latency and RSS, while explicitly reporting
allocation count and copied bytes per operation as `UNAVAILABLE`. It also
states that it is not a `StdNetTransport` comparison.

Therefore M0-005 is blocked on missing baseline measurements rather than
complete. M0-010 and M0-014 must not treat it as a satisfied dependency until
the missing matrix and durable raw report are produced.

## Requirement audit

| Requirement | Current evidence | Decision |
|---|---|---|
| 0 B / 1 KiB / 16 KiB / 64 KiB payloads | no retained M0-005 samples | MISSING |
| 1 MiB / 100 MiB payloads | retained M0-010 loopback samples | PARTIAL |
| loopback | current M0-010 quick profile and retained formal profile | PARTIAL |
| LAN | no native LAN peer/run metadata | MISSING |
| throughput and P50/P95/P99 latency | retained for the two M0-010 payloads | PARTIAL |
| allocations/op | public SDK exposes heap size and GC totals, not allocation-event count | UNAVAILABLE |
| copied bytes/op | raw `std.net` exposes no public copied-byte counter | UNAVAILABLE |
| thread count | absent from retained report | MISSING |
| peak RSS | retained for the two M0-010 payloads | PARTIAL |
| durable raw baseline report | M0-010 raw report is referenced but not checked in; no M0-005 artifact exists | MISSING |

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

## SDK capability evidence

The cached Cangjie `main` standard-library index records:

- `std.runtime.getUsedHeapSize(): Int64` for physical heap occupancy;
- `std.runtime.getAllocatedHeapSize(): Int64` for currently used heap bytes;
- `std.runtime.getGCCount(): Int64` and aggregate GC freed-size/time counters.

It contains no public allocation-event counter. Heap occupancy deltas cannot be
reported as allocations per operation because GC timing, retained objects and
allocator reuse change that value. Wirestack also cannot call a private runtime
allocation or socket ABI to manufacture the missing metric.

## Unblock requirements

M0-005 can become complete only after a dedicated baseline runner retains:

1. every required payload on loopback and a real LAN path;
2. warmup plus enough measured repetitions for P50/P95/P99;
3. process/thread/RSS metadata and exact byte validation;
4. a supported allocation-event measurement and copied-byte accounting method;
5. the raw schema-versioned report, digest and exact tested revision.

Cross-compilation, inferred zero allocations, heap-size deltas, or the partial
M0-010 profile do not satisfy those requirements.
