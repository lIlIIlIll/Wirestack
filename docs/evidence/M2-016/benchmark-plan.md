# M2-016 DNS-to-connected benchmark plan

- Task: `M2-016`
- Platform: native Linux x86_64 glibc
- Dependency: M2-015 native network gate
- Build: one isolated `-O2` repository snapshot

## Metrics

Each operation uses the production `SystemResolver`,
`HappyEyeballsConnector`, and `StdNetTransportFactory`. A non-blocking
`NetworkEventSink` records `MonoTime` when the connector emits each event.

| Metric | Start | End | Unit |
|---|---|---|---|
| DNS | `DnsStarted` | `DnsCompleted` | ns |
| First attempt | operation start | first `ConnectAttemptStarted` | ns |
| Winner | operation start | `TcpConnected` | ns |
| DNS-to-connected total | operation start | `connect` returns | ns |
| Connection count | operation start | count of `ConnectAttemptStarted` events | count |
| Accepted connections | listener start | successful native accepts | count |
| Cancellation latency | `CancellationSource.cancel` call | connector returns its joined `Cancelled` result | ns |

The report retains every sample and calculates nearest-rank P50, P95, and P99.
The first-attempt and winner values are offsets, not isolated phase durations.
The connection count is the number of native attempts that started. The
accepted-connection count is a separate server observation.

## Profiles and repetitions

Each profile runs one warmup round and 11 measured rounds. Each measured round
contains eight operations, for 88 retained samples per profile.

| Profile | Resolver | Network setup | Expected attempts per operation |
|---|---|---|---:|
| IPv6 available | native `localhost` lookup | reachable `::1` listener | 1 |
| IPv6 blackhole | native `localhost` lookup | drop `::1` SYN; reachable `127.0.0.1` listener | 2 |
| 20 ms RTT | native `localhost` lookup | 10 ms per-direction netem delay | 1 |
| 100 ms RTT | native `localhost` lookup | 50 ms per-direction netem delay | 1 |
| 1% loss | native `localhost` lookup | deterministic-seed 1% netem loss | 1, or 2 when loss delays the IPv6 winner past `attemptDelay` |
| Cancellation | native `localhost` lookup | drop both IPv6 and IPv4 SYN; after the first-attempt event, allow 5 ms for the SYN to enter the filter, then start the cancellation timer and cancel | 1 |

The runner creates an ephemeral user and network namespace. It does not change
the host network. The benchmark uses the same native address and impairment
mechanisms that M2-015 accepted.

## Acceptance rules

The initial M2-016 result qualifies a versioned Wirestack baseline. It does not
claim that Wirestack is faster than another implementation.

The report passes only if all these conditions hold:

- The toolchain builds the snapshot with `-O2`.
- Every profile retains exactly 11 rounds and 88 samples.
- Every successful sample reports a system DNS source, one winner, and ordered
  non-negative timestamps: DNS completion, first attempt, winner, and return.
- IPv6 available, 20 ms RTT, and 100 ms RTT start one attempt with the
  production-default 250 ms `attemptDelay`.
- The 1% loss profile records either one attempt or the legitimate two-attempt
  fallback when packet loss delays the IPv6 winner past `attemptDelay`.
- IPv6 blackhole starts two attempts and accepts one IPv4 connection.
- The loss qdisc reports at least one dropped packet.
- Each blackhole filter reports at least one dropped SYN per operation.
- Every cancellation returns `Cancelled`, starts one attempt, and has no
  winner.
- Cancellation P99 is at most 50 ms, as required by PRD section 19.4.
- No process times out, skips the benchmark case, emits a duplicate sample, or
  leaves a listener short of its expected accept count.

Missing tools, native execution, event timestamps, qdisc counters, samples, or
environment metadata make the report fail. M2-016 does not weaken a threshold
to publish a baseline.

## Evidence files

The formal run writes:

- `docs/evidence/M2-016/linux_glibc_x86_64/dns-to-connected.json`
- `docs/evidence/M2-016/README.md`

The JSON report records the raw samples, aggregate percentiles, process output,
source digests, compiler, libc, kernel, CPU model, CPU affinity, and scaling
governor.
