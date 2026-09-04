# Native acceleration qualification benchmarks

This package is repository-only release infrastructure. Run it through
`scripts/json_native_accel_perf_run.py`; ordinary applications call
`YJsonNativeAccel.initialize()` once and continue using the `YJson` API.

The runner uses separate Pure and Native processes because the first ordinary
`YJson` call freezes the engine. A formal run alternates process order for 11
rounds, pins both sides to the same CPU, fixes the heap at 128 MiB, records RSS
with `/usr/bin/time -v`, and retains every raw report with a checksum.

## Content checksum protocol

Each benchmark process prints one deterministic content line per workload to
stdout during fixture initialization (outside the measured region):

```text
CHECKSUM <case> <16-hex-fnv1a-64>
```

The digest is FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime
`0x100000001b3`) over the exact artifact bytes the workload produces:

- String writers (`writeNumericArray`, `writeEscapedStrings`,
  `writePlainStrings`): the UTF-8 bytes of the serialized JSON string.
- Byte writers (`writeNumericBytes`, `writeEscapedBytes`): the serialized
  byte array itself.
- Readers (`readNumericArray`, `readNumericDocument`): a short deterministic
  summary of the parsed value (count/last-element).

The runner parses these lines from each process log, binds them to the raw
report row in `manifest.csv`, and requires the Pure and Native digests to
match for every case. A mismatch fails the batch: it proves the two engines
did not produce the same observable result.

## RSS

The runner wraps every benchmark invocation in `/usr/bin/time -v -o <rss-file>`
and parses `Maximum resident set size (kbytes)` from the output file. A formal
run must capture RSS for all 11 rounds on both sides; any missing value fails
the batch.

## Qualification rules

Advertised read and write workloads must each reach `Native/Pure <= 0.95`,
win at least 6 of 11 pairs, capture RSS on every run, and match Pure/Native
content checksums. Ordinary stability workloads require `Native/Pure <= 1.05`.
Every row on both sides must have CV no greater than 5%.

Only the default 11-round run is a formal qualification. Other `--runs`
values are diagnostic. If either side exceeds the CV threshold, discard the
whole batch and run all 11 rounds once more. A second unstable batch does not
qualify the release.

No historical result is automatically a `0.1.0` claim. Release evidence must
bind the source digest, compiler, platform, CPU affinity, heap limit, raw report
checksums, RSS captures, and runner version (`release/0.1.0/evidence.md`).
