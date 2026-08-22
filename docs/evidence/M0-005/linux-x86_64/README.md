# Linux x86_64 raw TCP baseline

The supplied SDK baseline completed all six cases with three measured samples after one warmup. Exact byte verification passed for every sample, including the 100 MiB case.

Toolchain:

```text
cjc 1.1.0-alpha.20260817040003 (cjnative)
target: x86_64-unknown-linux-gnu
cjpm 1.1.3
```

The generated JSON retains raw samples and aggregate P50/P95/P99 values. Results are loopback- and host-specific and must not be generalized to other platforms.
