# GATE-NET-05 Linux x86_64 comparison

- Task evidence: COMPLETE
- Linux gate: FAIL
- Global gate: INCOMPLETE

Eleven alternating `-O2` samples compare raw `std.net` and
`StdNetTransport` for every GATE-NET-05 payload. Exact bytes and all ten native
instrumentation operations pass. The adapter misses the 95% throughput floor
for 16 KiB through 100 MiB and misses the P95 latency limit for 64 KiB and
100 MiB. See [`result.json`](result.json) for every sample and trace.
