# M7-024 Linux performance release gate

Status: **COMPLETE**

Decision: **PASS**

M7-024 turns the completed Linux component benchmarks into one versioned,
fail-closed release gate. The manifest pins seven raw reports by SHA-256. The
gate performs 254 field-level checks across eight required performance domains.
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
| Field-level checks | 254/254 PASS |
| Failed domains | 0 |
| Manifest | [`tools/gates/manifests/m7-024-linux-performance.json`](../../../tools/gates/manifests/m7-024-linux-performance.json) |
| Manifest SHA-256 | `4e5d3425fd2b31794b44d72d75c245f40bc96ed318ca8aba2eaf373ee46eab0d` |
| Aggregate report | [`linux_glibc_x86_64/performance-gate.json`](linux_glibc_x86_64/performance-gate.json) |
| Aggregate report SHA-256 | `a354e448489fe3680f68c5298fd79a4ab0555dbf135ebe84ae5c1c0e5e6be65e` |

## Release baselines

| Domain | Frozen workload and measured result | Threshold | Decision |
|---|---|---|---|
| Raw TCP | Five payloads from 1 KiB through 100 MiB, 11 paired rounds; minimum throughput ratio 0.988339, maximum P95 ratio 0.990445 | throughput ratio at least 0.95; P95 ratio at most 1.10; zero staging copies | PASS |
| DNS-to-connected | Six profiles, 11 rounds and 88 samples each; IPv6 blackhole P95 272.736 ms; cancellation P99 3.908 ms | complete profile matrix; cancellation P99 at most 50 ms | PASS |
| TLS | Bulk ratio 1.4494; full-handshake P50 ratio 0.1112 and P95 ratio 0.1326; 11 resumed rounds | bulk at least 0.90; handshake P50 at most 1.10 and P95 at most 1.20 | PASS |
| HTTP/1.1 | Seven alternating rounds; 10,073.727 req/s versus 4,829.858 req/s, ratio 2.0857 | keep-alive throughput ratio at least 0.90 | PASS |
| HTTP/2 | Post-M3-030 1, 10 and 100 streams, 20 rounds in forward and reverse order; one connection; 854.426, 1,517.105 and 1,245.926 req/s; connection ratio 0.01 | exact concurrency matrix; ratio at most 0.25; bounded queues, zero outstanding flow permits and current production-source fingerprint | PASS |
| Cancellation | 100 measured blocked-read and blocked-write samples; P99 9.098 ms and 4.118 ms | P99 at most 50 ms | PASS |
| SSE | H1 95,935,756 events and H2 90,877,593 events, one hour each | at least one hour and one million events per protocol; cancellation at most 50 ms | PASS |
| Memory | Eight Transport resource classes; TLS body growth 4,788 KiB and idle slope 45.597 KiB/connection; H1 and SSE RSS trends non-growing | component memory limits, bounded H2 queues and steady SSE resources | PASS |

The 1% packet-loss DNS profile retains its real retransmission tail, including
a 1.051-second P99. No release threshold hides that sample. The profile passes
because all operations completed, the configured impairment was observed and
the acceptance contract does not impose an invented latency ceiling on packet
loss.

## Post-M3-030 HTTP/2 requalification

M3-030 changed the provider-neutral HTTP/TLS path covered by the HTTP/2 source
fingerprint, so the earlier M6-026 raw report was not reused as current
performance evidence. The original 2-warmup,
20-measured-round, forward/reverse 1/10/100-stream matrix was rerun and saved as
[`linux_glibc_x86_64/http2-benchmark-after-m6-026.json`](linux_glibc_x86_64/http2-benchmark-after-m6-026.json),
SHA-256
`ca9cbf1710cffdae0d75361cbc6796c69d5459e15146a1ddc8dcbd5a41b145c6`.
It records production-source SHA-256
`2450fe679d91e0dd51c735a969f71351c6b378b76525a4b6d1a8b88248cd9b07`.
The release gate now requires the raw report, manifest and current production
tree to carry that exact digest; source drift fails the HTTP/2 domain.

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
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-024/test-plan.md --json` | PASS; P=12, S=8, T=8 |
| `python3 -m py_compile tools/gates/m7_024_linux_performance.py tools/gates/tests/test_m7_024_linux_performance.py` | PASS |
| `python3 -m unittest tools.benchmarks.tests.test_http2_benchmark tools.gates.tests.test_m7_024_linux_performance tools.tests.test_m7_linux_task_graph` | PASS; 19/19 tests |
| `scripts/gate-m7-024-linux-performance` | PASS; 7 artifacts, 8 domains, 254 checks, 0 failures |
| `scripts/check` | PASS; exit 0; 132 repository tests, 132 gate tests, 24 benchmark tests, architecture/check/build PASS, 561 Cangjie tests passed, 23 skipped, 0 failed |

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
