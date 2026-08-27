# M2-015 native Linux network-emulation evidence

- Task: `M2-015`
- Profile: native Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`
- CJPM: `1.1.3`
- Host libc: glibc `2.44`

## Scope

The native gate runs the production `HappyEyeballsConnector`,
`StaticResolver`, `StdNetTransportFactory`, `OperationContext`, and real TCP
sockets in a disposable Linux user/network namespace. It uses `tc netem` for
20/100 ms RTT and deterministic-seed 1% loss. `tc flower` drops selected TCP
SYN packets to produce IPv6 and multi-candidate blackholes without modifying
the host network.

The Cangjie gate is `Performance`-tagged so the canonical correctness suite
compiles it without attempting privileged network setup. The dedicated Python
runner owns namespace creation, listeners, impairment counters, process-tree
sampling, threshold decisions, and the machine-readable report.

## Acceptance decision

| Criterion | Native result | Decision |
|---|---|---|
| IPv6 available | IPv6 won the real dual-family attempt; the later IPv4 diagnostic was skipped and cancelled | PASS |
| IPv6 blackhole fallback | 64/64 IPv4 fallbacks won; 64/64 IPv6 SYNs were dropped; all 64 losers were cancelled and joined | PASS |
| 20 ms RTT | 10 ms per-direction netem produced a 21 ms connector result and observed 65 packets | PASS |
| 100 ms RTT | 50 ms per-direction netem produced a 100 ms connector result and observed 60 packets | PASS |
| 1% packet loss | 128/128 connections completed; netem observed 969 packets and dropped 7 | PASS |
| Loser/resource cleanup | blackhole and loss profiles retained flat FD, socket, thread and process medians; RSS growth stayed within 16 MiB | PASS |
| Deadline is not multiplied by candidate count | 2 candidates completed in 355 ms and 8 in 352 ms against the same 350 ms parent budget; absolute delta 3 ms, limit 150 ms | PASS |
| Fail-closed prerequisites | missing namespace, `tc` counters, native marker, process success, listener count, or resource trend makes the report fail | PASS |

The complete raw commands, unittest output, qdisc/filter statistics,
process-tree samples, thresholds, environment metadata, and source SHA-256
digests are retained in
[`linux_glibc_x86_64/report.json`](linux_glibc_x86_64/report.json). The frozen
path/scenario/test matrix is in [`test-plan.md`](test-plan.md).

## Resource evidence

The 64-iteration blackhole profile recorded 43 process-tree samples. Median
FDs, sockets, threads, and process count had zero growth; RSS grew 1,924 KiB.
The 128-iteration loss profile recorded 50 samples. The same lifecycle metrics
had zero growth; RSS grew 1,064 KiB. Both profiles passed the 16 MiB RSS, 8 FD,
2 socket, 4 thread, and zero process-count growth limits.

Every successful Cangjie iteration closes its winner. Every fallback result
asserts one winner plus one typed `Cancelled` loser diagnostic before
`connect` returns. Deadline cases assert typed `TimedOut` results containing
all 2 or 8 terminal attempt diagnostics.

## Commands and results

Test-plan structure validation:

```text
python3 /home/elliot/.codex/skills/cangjie-test-scenario-analysis/scripts/validate_test_plan_matrix.py docs/evidence/M2-015/test-plan.md --json
```

Result: exit 0; 8 scenario IDs and 8 test IDs were linked with no errors or
warnings. The shallow validator also tokenized the priority label `P0` as a
path-like ID; the actual path matrix is P001 through P009.

Gate unit tests:

```text
python3 -m unittest tools.gates.tests.test_m2_015_native_network -v
```

Result: exit 0; 4/4 parser, duplicate-marker, deadline-marker and resource-trend
tests passed.

Final native gate:

```text
env DISABLE_ZOXIDE=1 ./scripts/gate-m2-015-native-network
```

Result: exit 0; all seven native scenarios and the separate candidate-count
scaling decision passed. The complete execution took about 22 seconds; no soak
or 24-hour profile ran.

## Compatibility and architecture

Production declarations and behavior are unchanged. The new Cangjie file is a
test-only consumer of the existing connector, resolver, transport SPI, and the
only adapter allowed to import `std.net`. The gate uses public Linux namespace
and iproute2 interfaces and never calls `CJ_MRT_Sock*` or modifies an external
repository.

## Remaining boundary

M2-015 is complete for the ADR-0002/ADR-0004 native glibc Linux profile. It is
not global Windows, Apple, Android, iOS, or Harmony platform evidence. M2-016
still owns DNS-to-connected and per-attempt benchmark metrics and is now the
next READY M2 task. Linux musl remains deferred to P1-011 until the Cangjie SDK
supports it.
