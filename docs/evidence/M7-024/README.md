# M7-024 Linux performance release gate

Status: **COMPLETE**

Decision: **PASS**

M7-024 turns the completed Linux component benchmarks into one versioned,
fail-closed release gate. The manifest pins seven raw reports by SHA-256. The
gate performs 252 field-level checks across eight required performance domains.
It does not accept a component's top-level `PASS` value by itself.

## Formal result

| Field | Result |
|---|---|
| Profile | Native Linux x86_64 glibc |
| Compiler baseline | Cangjie 1.1.0-alpha.20260817040003, cjnative |
| CJPM baseline | 1.1.3 |
| Build profile | `-O2` component reports |
| Pinned raw artifacts | 7/7 verified |
| Performance domains | 8/8 PASS |
| Field-level checks | 252/252 PASS |
| Failed domains | 0 |
| Manifest | [`tools/gates/manifests/m7-024-linux-performance.json`](../../../tools/gates/manifests/m7-024-linux-performance.json) |
| Manifest SHA-256 | `0a85c9140b808e8e21a808589c1a4f1f8523f516a946a7b63d00738af8a243cb` |
| Aggregate report | [`linux_glibc_x86_64/performance-gate.json`](linux_glibc_x86_64/performance-gate.json) |
| Aggregate report SHA-256 | `6acf4df4b3237df294e375ee8d6a618efbc81481ced99b29cdf08665397559df` |

## Release baselines

| Domain | Frozen workload and measured result | Threshold | Decision |
|---|---|---|---|
| Raw TCP | Five payloads from 1 KiB through 100 MiB, 11 paired rounds; minimum throughput ratio 0.988339, maximum P95 ratio 0.990445 | throughput ratio at least 0.95; P95 ratio at most 1.10; zero staging copies | PASS |
| DNS-to-connected | Six profiles, 11 rounds and 88 samples each; IPv6 blackhole P95 272.736 ms; cancellation P99 3.908 ms | complete profile matrix; cancellation P99 at most 50 ms | PASS |
| TLS | Bulk ratio 1.4494; full-handshake P50 ratio 0.1112 and P95 ratio 0.1326; 11 resumed rounds | bulk at least 0.90; handshake P50 at most 1.10 and P95 at most 1.20 | PASS |
| HTTP/1.1 | Seven alternating rounds; 10,073.727 req/s versus 4,829.858 req/s, ratio 2.0857 | keep-alive throughput ratio at least 0.90 | PASS |
| HTTP/2 | 1, 10 and 100 streams, 20 rounds in forward and reverse order; one connection; connection ratio 0.01 | exact concurrency matrix; ratio at most 0.25; bounded queues and zero outstanding flow permits | PASS |
| Cancellation | 100 measured blocked-read and blocked-write samples; P99 9.098 ms and 4.118 ms | P99 at most 50 ms | PASS |
| SSE | H1 95,935,756 events and H2 90,877,593 events, one hour each | at least one hour and one million events per protocol; cancellation at most 50 ms | PASS |
| Memory | Eight Transport resource classes; TLS body growth 4,788 KiB and idle slope 45.597 KiB/connection; H1 and SSE RSS trends non-growing | component memory limits, bounded H2 queues and steady SSE resources | PASS |

The 1% packet-loss DNS profile retains its real retransmission tail, including
a 1.051-second P99. No release threshold hides that sample. The profile passes
because all operations completed, the configured impairment was observed and
the acceptance contract does not impose an invented latency ceiling on packet
loss.

## Gate behavior

The command is:

```shell
scripts/gate-m7-024-linux-performance
```

It rejects:

- a missing, extra or reordered performance domain;
- repository-path escape, missing files and changed SHA-256 digests;
- malformed JSON, `NaN`, infinity and wrong scalar types;
- mismatched platform, optimization, workload, round or sample controls;
- missing payloads, network profiles, stream counts or protocols;
- any metric outside its frozen PRD or component threshold.

The gate writes its report atomically and exits nonzero on any failure. Raw
component reports remain unchanged and continue to hold every benchmark sample
and subprocess output.

## Verification

| Command | Result |
|---|---|
| `python3 .../validate_test_plan_matrix.py docs/evidence/M7-024/test-plan.md` | PASS; P=16, S=8, T=8 |
| `python3 -m py_compile tools/gates/m7_024_linux_performance.py tools/gates/tests/test_m7_024_linux_performance.py` | PASS |
| `python3 -m unittest tools.gates.tests.test_m7_024_linux_performance -v` | PASS; 7/7 tests |
| `scripts/gate-m7-024-linux-performance` | PASS; 7 artifacts, 8 domains, 252 checks, 0 failures |
| `scripts/check` | PASS; exit 0; 99 repository tests, 131 gate tests, 23 benchmark tests, architecture/check/build PASS, 554 Cangjie tests passed, 22 skipped, 0 failed |

## Evidence boundary

M7-024 validates retained native component runs. It does not rerun the one-hour
SSE profile or the component benchmark workloads. Digest pinning ensures the
release decision cannot silently consume different raw data. A changed
component, SDK, provider pin, workload contract or raw report requires a new
baseline run and manifest update rather than an automatic carry-forward.

The original component runs did not share one fixed CPU affinity or governor,
so this evidence does not claim cross-host comparability. It proves the frozen
Linux glibc release thresholds represented by the retained raw reports. Linux
musl and non-Linux platforms remain outside this task. No runtime, std, stdx or
SDK source was changed or built.
