# HTTP/1 Linux benchmark

The M5-030 runner measures three cases on native Linux x86_64:

- 2,000 sequential empty responses over one keep-alive connection;
- a 16 MiB streamed response;
- a 64 MiB streamed response.

The runner copies the current source to a temporary build directory and builds
Wirestack there with `-O2`; the repository's ordinary test profile stays
unchanged. It also compiles the stdx driver with `-O2`. The runner alternates seven
Wirestack and seven stdx measurements on the same host, then compares median
requests per second. The keep-alive gate requires Wirestack to reach at least
90% of stdx.

The stdx input is release `v1.1.3.1`, commit
`8fa4b04b4cb1753e8f3581e4935cf72ad145fedc`. The runner verifies the archive,
`stdx.net.http.cjo`, and `libstdx.net.http.so` hashes against
[`stdx-http1-baseline-linux.data`](../references/stdx-http1-baseline-linux.data)
before it compiles or runs the comparison.

For the streaming cases, the runner samples aggregate RSS and open file
descriptors for the process tree from `/proc`. The memory gate requires the 64
MiB peak RSS to stay within 16 MiB and 1.5 times the 16 MiB result.

Run the measurement after extracting the pinned release archive:

```sh
cangjie_env python3 tools/benchmarks/http1_benchmark.py \
  --stdx-archive /tmp/cangjie-stdx-linux-x64-1.1.3.1.zip \
  --stdx-root /tmp/wirestack-stdx-1.1.3.1 \
  --stdx-reference docs/references/stdx-http1-baseline-linux.data \
  --output docs/evidence/M5-030/linux_x86_64/http1-benchmark.data
```

The command fails closed if the release files do not match the pinned hashes,
the temporary build cannot enable `-O2`, a checksum differs, a child command fails, or
either acceptance threshold is missed. The retained Linux result is
[`http1-benchmark.data`](../evidence/M5-030/linux_x86_64/http1-benchmark.data).
It records every duration, process-tree peak, command, source hash, and the
final decision.

The benchmark classes use `@Tag[Performance]`. The canonical `scripts/check`
command excludes that tag so 16/64 MiB measurements do not contend with
ordinary concurrency tests. The benchmark runner selects each class directly.
