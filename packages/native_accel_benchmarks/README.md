# Native acceleration qualification benchmarks

This package is repository-only release infrastructure. Run it through
`scripts/json_native_accel_perf_run.py`; ordinary applications only call
`YJsonNativeAccel.initialize()` once and continue using the `YJson` API.

The runner uses separate Pure and Native processes because the engine choice is
frozen by the first `YJson` call. It alternates process order for 11 rounds,
pins both sides to the same CPU, fixes the heap at 128 MiB, and retains every
raw `csv-raw` report.

The advertised acceleration cases are `writeNumericBytes` and
`readNumericDocument`. They must be stable on both sides, reach `Native/Pure <=
0.95`, and win at least 6 of 11 pairs. `writeNumericArray`, `readNumericArray`,
`writeEscapedStrings`, `writeEscapedBytes`, and `writePlainStrings` are ordinary
regression checks: both sides must be stable and `Native/Pure <= 1.05`.

Only the default 11-round run is a formal qualification. Other `--runs` values
are diagnostic and always return a non-zero gate result. The manifest records a
SHA-256 digest for each raw report, while metadata records the tested source
digest, compiler, platform, CPU affinity, and heap limit.

If either side exceeds 5% CV, discard the qualification and run all 11 rounds
once more. `--skip-build` is accepted for that immediate rerun only when the
recorded build-source digest still matches the current workspace.

The latest dated result is documented in
[`docs/performance/results/2026-08-26-native-acceleration.md`](../../docs/performance/results/2026-08-26-native-acceleration.md).
