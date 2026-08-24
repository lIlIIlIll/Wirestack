# 2026-08-24 typed stream backend result

## Identity and environment

- yjson candidate: `e47bef0b5c048b01a83f0dea227a6cfbdef38f67`
- machine: `ubuntu2223131`, Intel Xeon Gold 6248R, pinned logical CPU 8 of 96
- Cangjie compiler: `1.1.0-alpha.20260817040003`; `cjpm 1.1.3`; `-O2`
- heap: `cjHeapSize=2GB`
- execution: 11 rounds, 132 independent benchmark processes; workload and backend order rotate
  and reverse by round
- process measurement: 500 ms warmup, at least 2 s and 20 batches
- host one-minute load observed during the run: 0.436–4.498 on 96 logical CPUs

The Server's 20260817 SDK copy contains a `libpcre2` that requests
`GLIBC_ABI_DT_RELR`, which the host libc does not provide. Compilation used that SDK unchanged. At
execution time an isolated library directory retained the matching Cangjie runtime libraries but
excluded only the incompatible `libpcre2`, allowing the system `libpcre2` to resolve instead. This
workaround is part of the environment identity and must be retained when reproducing the snapshot.

## Workload contract

This measurement compares three implementations of the same typed stream API and the same
backend-neutral `JsonCodec<T>`:

| Label | Typed value / codec | Compact JSON size |
| --- | --- | ---: |
| Small | `HashMap<String, String>` with four fields | 80 B |
| Large | `Array<HashMap<String, String>>` with 512 four-field records | 56,101 B |

The Large workload is therefore an array of maps, not the single Large Map workload used by the
yjson/cjfast_json comparison. Its codec is
`YJson.arrayCodec(YJson.hashMapCodec(StringJson))`.

Encode measures creation of a caller-owned memory output stream, typed encoding, backend
finalization, and conversion to the final byte array. Decode reads the same compact bytes through a
caller-owned byte-array input stream and materializes the complete typed value. It does not compare
DOM APIs, framing, RSS, or allocation counts.

## Results

`Backend/Pure` is `backend median / Pure median`; below 1 means the selected backend used less
latency. `Faster pairs` compares that backend with Pure in the same round. A precise row requires
both the selected backend and Pure to pass the repository's CV ≤ 5% display gate.

| Workload | Backend | Median | p95 | CV | Backend/Pure | Faster pairs | Status |
|:--|:--|--:|--:|--:|--:|--:|:--|
| Small encode | Pure | 11.420 µs | 12.375 µs | 4.14% | 1.000x | — | stable |
| Small encode | Custom Native | 13.700 µs | 14.110 µs | 4.96% | 1.200x | 0/11 | stable |
| Small encode | yyjson | 13.500 µs | 14.205 µs | 4.55% | 1.182x | 0/11 | stable |
| Small decode | Pure | 14.620 µs | 15.010 µs | 3.73% | 1.000x | — | stable baseline |
| Small decode | Custom Native | 18.100 µs | 18.725 µs | 10.94% | 1.238x | 2/11 | noisy |
| Small decode | yyjson | 17.840 µs | 19.650 µs | 5.14% | 1.220x | 0/11 | noisy |
| Large encode | Pure | 2.628 ms | 2.931 ms | 7.13% | 1.000x | — | noisy |
| Large encode | Custom Native | 3.110 ms | 3.417 ms | 7.71% | 1.183x | 0/11 | noisy |
| Large encode | yyjson | 2.922 ms | 3.144 ms | 5.05% | 1.112x | 2/11 | noisy |
| Large decode | Pure | 4.361 ms | 4.641 ms | 8.32% | 1.000x | — | noisy |
| Large decode | Custom Native | 3.665 ms | 4.215 ms | 8.16% | 0.840x | 10/11 | noisy |
| Large decode | yyjson | 3.537 ms | 3.828 ms | 6.70% | 0.811x | 10/11 | noisy |

Only Small encode passes the two-sided CV ≤ 5% gate for all three backends. It shows the fixed
whole-document/tape cost clearly: Pure is lower latency, while Custom Native and yyjson are 1.200x
and 1.182x respectively.

The remaining rows are direction evidence only. Small decode and Large encode generally favor
Pure. Large decode favors Custom Native and yyjson in 10/11 paired rounds, but the observed 0.840x
and 0.811x ratios are not accepted as precise claims because both sides exceed the CV gate.

## Artifacts and audit boundary

The 132 process logs, raw CSV, metadata, summary JSON/Markdown, harness and checksums are retained:

- Server: `<home>/yjson-stream-backend-perf-20260824-e47bef0`
- development checkout: `target/perf-stream-backend-20260824-e47bef0`

Artifact identities:

- source archive SHA-256: `7fd66408bbd68474dc936f10b8d1da396c3bd68c4e6befe8ecbee97d08fbf1a0`
- harness SHA-256: `3f672a3216758169999d82b1bc6f27b65218fa31930e6d8f77d5c07c624b4e24`
- runner SHA-256: `c1a5c30c911b7c74c274184d4d9b3881e1f02c667e407aa3ab9ec26e4efe9bd9`
- evidence archive SHA-256:
  `f55fc7486a020598589ba994460f3dedee1bb61f62cb2e8dd30f71492136d4b7`

Checksums passed before the archive was copied back from the Server. The harness and raw evidence
are not committed to the repository, so this historical result is not independently reproducible or
externally auditable from a checkout alone.
