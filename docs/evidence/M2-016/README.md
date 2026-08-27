# M2-016 DNS-to-connected benchmark evidence

- Task: `M2-016`
- Profile: native Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`
- CJPM: `1.1.3`
- Host libc: glibc `2.44`

## Scope

The benchmark runs the production `SystemResolver`,
`HappyEyeballsConnector`, and `StdNetTransportFactory` from one isolated
`-O2` repository snapshot. A test-only event sink records DNS duration and
monotonic offsets for the first native attempt and winner. The runner records
the connector return time, started connection count, listener accepts, and
joined cancellation latency.

Each profile uses one discarded warmup round followed by 11 measured rounds
of eight operations. The report therefore retains 88 samples per profile and
528 measured samples in total. Percentiles use nearest rank.

## Acceptance decision

| Profile | P50 total | P95 total | P99 total | Attempts | Native observation | Decision |
|---|---:|---:|---:|---:|---|---|
| IPv6 available | 10.248 ms | 13.165 ms | 15.891 ms | 1 | 88/88 IPv6 accepts | PASS |
| IPv6 blackhole | 263.972 ms | 272.736 ms | 279.874 ms | 2 | 96/96 IPv6 SYNs dropped; 88/88 IPv4 accepts | PASS |
| 20 ms RTT | 30.226 ms | 33.690 ms | 34.503 ms | 1 | 88/88 accepts | PASS |
| 100 ms RTT | 110.314 ms | 112.605 ms | 115.896 ms | 1 | 88/88 accepts | PASS |
| 1% loss | 10.242 ms | 13.532 ms | 1,051.085 ms | 1–2 | 6/610 packets dropped; 88/88 accepts | PASS |
| Cancellation | 1.126 ms | 1.608 ms | 3.908 ms | 1 | 96/96 SYNs dropped; no winner | PASS |

The 1% loss P99 records a real TCP retransmission tail. Two of 88 operations
started the legitimate delayed second-family attempt; the runner retains this
instead of hiding it behind a median-only summary.

Cancellation starts only after the first-attempt event and a 5 ms scheduling
allowance for the SYN to enter the drop filter. That allowance is outside the
measured interval. All 88 retained operations returned typed `Cancelled`,
joined their attempt, and stayed below the PRD's 50 ms P99 limit.

The complete raw samples, per-round unittest output, listener counts,
qdisc/filter statistics, environment metadata, commands, and source SHA-256
digests are retained in
[`linux_glibc_x86_64/dns-to-connected.json`](linux_glibc_x86_64/dns-to-connected.json).
The metric and fail-closed contract is in
[`benchmark-plan.md`](benchmark-plan.md).

## Commands and results

Runner unit tests:

```text
python3 -m unittest tools/benchmarks/tests/test_m2_016_dns_to_connected.py
```

Result: exit 0; 7/7 parser, sample-contract, nearest-rank, and isolated `-O2`
manifest tests passed.

Cangjie target compilation:

```text
/home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test src/internal/transport_stdnet -j 1 --no-run
```

Result: exit 0; the transport adapter unittest target compiled successfully.

Formal native benchmark:

```text
scripts/benchmark-m2-016-dns-to-connected
```

Result: exit 0 and report decision `PASS`. The runner built one isolated `-O2`
snapshot and ran inside `unshare --user --map-root-user --net`; no soak or
24-hour profile ran.

## Compatibility and architecture

Production declarations and behavior are unchanged. The Cangjie benchmark is
a test-only consumer of existing resolver, connector, transport SPI, and
StdNet adapter APIs. Only the existing StdNet adapter package imports
`std.net`; the runner uses Linux namespace and iproute2 interfaces without
calling private runtime ABI or changing an external repository.

## Remaining boundary

This result establishes the first versioned Wirestack DNS-to-connected
baseline. It is not a cross-implementation speed claim and does not establish
Windows, Apple, Android, iOS, Harmony, or musl results. Linux musl remains
deferred under ADR-0004 until the Cangjie SDK supports it.
