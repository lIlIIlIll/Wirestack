# Comparison benchmarks

The Cangjie package-local benchmark cases live in `packages/benchmarks/`.
They depend on public generated fixture codecs and the public benchmark support
helpers exported by `yjson`.

External adapters live here:

- `cjfast_json/` checks out the pinned cjfast_json revision and injects the adapter
  into that repository's benchmark package.
- `java_fastjson2/` compiles and runs the standalone fastjson2 comparison harness.

Use `scripts/json_perf_baseline.py` to run and merge the package-local, cjfast_json,
and Java results with one output format.
