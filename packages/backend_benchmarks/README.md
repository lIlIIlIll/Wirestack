# Backend benchmarks

This package compares yjson's semantic DOM backends through their public APIs:

- mutable Pure Cangjie `JsonNode`;
- read-only Pure Cangjie `CompactJsonDocument`;
- custom Native `NativeCompactJsonDocument`;
- yyjson Direct `YyjsonCompactJsonDocument`.

It is intentionally separate from `packages/benchmarks`: backend DOM operations are
not equivalent to generated typed codec encode/decode, and the Native dependencies
should not be pulled into the ordinary benchmark package.

The benchmark covers parse lifecycle, retained root lookup, retained traversal,
retained serialization, and parse-plus-serialize round trips on one 16,384-entry
object. Native parse and round-trip cases include `close()` in the timed lifecycle.
The contract test verifies the same observable root value and validates each
backend's serialization through the Pure Cangjie parser. Traversal checksums are
backend-local blackhole operations, not cross-backend semantic hashes.

From this directory:

```bash
../../scripts/codex_cangjie_env cjpm test --no-color
../../scripts/codex_cangjie_env cjpm bench --no-color --filter BackendDomBenchmarks
```

For controlled multi-round collection from the repository root:

```bash
scripts/json_backend_perf_run.py target/backend-perf --cpu 8
scripts/json_backend_perf_summary.py target/backend-perf
```

Use repeatable `--operation` selectors for a focused rerun, for example
`--operation serialize --operation roundtrip`.

That runner writes raw benchmark CSV files plus a manifest and environment metadata.
It does not by itself establish that the host was otherwise idle.
