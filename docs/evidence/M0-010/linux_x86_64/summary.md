# GATE-NET-05 — Linux x86_64 large-buffer profile

**Task implementation:** COMPLETE  
**Linux application-visible profile:** PASS  
**Linux copied-byte/allocation profile:** INCOMPLETE  
**Global gate:** INCOMPLETE

| Case | Measured samples | Buffer | Exact bytes | Reads above 4 KiB | Result |
|---|---:|---:|---|---|---|
| 1 MiB | 5 | 64 KiB | yes | yes | PASS |
| 100 MiB | 5 | 64 KiB | yes | yes | PASS |

The 100 MiB case reuses one 64 KiB Cangjie receive buffer; it does not allocate
a body-sized Cangjie byte array. The harness records raw read-size arrays,
throughput samples, server send sizes, RSS samples and process outcomes in its
schema-versioned JSON output.

The current public SDK/runtime environment provides no reliable allocation
counter or copied-byte instrumentation. Those fields remain `UNAVAILABLE`, not
zero. Native Windows evidence and the future `StdNetTransport` comparison are
also outstanding, so GATE-NET-05 remains incomplete.
