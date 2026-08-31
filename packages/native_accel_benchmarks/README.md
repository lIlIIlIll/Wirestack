# Native acceleration qualification benchmarks

This package is repository-only release infrastructure. Run it through
`scripts/json_native_accel_perf_run.py`; ordinary applications call
`YJsonNativeAccel.initialize()` once and continue using the `YJson` API.

The runner uses separate Pure and Native processes because the first ordinary
`YJson` call freezes the engine. A formal run alternates process order for 11
rounds, pins both sides to the same CPU, fixes the heap at 128 MiB, records RSS,
and retains every raw report with a checksum.

Advertised read and write workloads must each reach `Native/Pure <= 0.95` and
win at least 6 of 11 pairs. Ordinary stability workloads require
`Native/Pure <= 1.05`. Every row on both sides must have CV no greater than
5%.

Only the default 11-round run is a formal qualification. Other `--runs`
values are diagnostic. If either side exceeds the CV threshold, discard the
whole batch and run all 11 rounds once more. A second unstable batch does not
qualify the release.

No historical result is automatically a `0.1.0` claim. Release evidence must
bind the source digest, compiler, platform, CPU affinity, heap limit, raw report
checksums, and runner version.

