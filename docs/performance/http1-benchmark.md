# HTTP/1 benchmark evidence

The benchmark runner measures three isolated cases on Linux:

- 2,000 sequential small requests over one keep-alive connection;
- a 16 MiB streamed response;
- a 64 MiB streamed response.

It samples aggregate RSS and open file descriptors for the command and all of
its descendants from `/proc`. The streaming check passes only when the 64 MiB
case grows by no more than 16 MiB and 1.5x relative to the 16 MiB case.

Run the measurement from the pinned Cangjie environment:

```sh
cangjie_env python3 tools/benchmarks/http1_benchmark.py \
  --output /tmp/wirestack-http1-benchmark.json \
  --allow-missing-stdx-baseline
```

`--allow-missing-stdx-baseline` permits evidence collection but leaves the
overall decision `PARTIAL`. A release-quality `PASS` requires a same-host,
same-SDK stdx keep-alive result:

```sh
cangjie_env python3 tools/benchmarks/http1_benchmark.py \
  --stdx-baseline-rps <requests-per-second> \
  --output /tmp/wirestack-http1-benchmark.json
```

The current pinned SDK inventory contains no stdx HTTP module or source, so no
comparable local stdx baseline is claimed. Never replace it with a synthetic or
historical number.
