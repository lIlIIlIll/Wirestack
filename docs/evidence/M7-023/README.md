# M7-023 Linux continuous fuzz release gate

Status: **COMPLETE**

Decision: **PASS**

M7-023 qualifies the ten parser targets required by PRD section 21.4 on the
native Linux x86_64 glibc release profile. The gate uses committed corpus files,
seed 7023, explicit iteration thresholds, bounded process output, crash
artifacts, and a checked-in-coordinate replay mode.

## Formal result

| Field | Result |
|---|---|
| Profile | Linux x86_64 glibc |
| Build | Isolated CJPM snapshot, `compile-option = "-O2"` |
| Compiler | Cangjie 1.1.0-alpha.20260817040003, cjnative |
| CJPM | 1.1.3 |
| Kernel | Linux 7.1.9-arch1-2 |
| libc | glibc 2.44 |
| Targets | 10/10 PASS |
| Total deterministic iterations | 6,465 |
| Current-run crash artifacts | 0 |
| Gate report | [`linux_glibc_x86_64/fuzz-report.json`](linux_glibc_x86_64/fuzz-report.json) |
| Gate report SHA-256 | `81d056538ed5ac99a1ca33e0ad6fad3c7e62f9b52f699265fd8e9325e3b8a711` |
| Qualified source SHA-256 | `9707d1454f279a1688e1602e722385cc52b86e7e0feb01474210f29543789a7f` |

## Target thresholds

| Target | Executed | Required | Decision |
|---|---:|---:|---|
| TLS record parser | 512 | 512 | PASS |
| TLS handshake parser | 512 | 512 | PASS |
| Hostname verifier | 2,048 | 2,048 | PASS |
| Certificate input adapter | 512 | 512 | PASS |
| HTTP/1.1 request/response parser | 870 | 800 | PASS |
| Chunked decoder | 127 | 100 | PASS |
| HTTP/2 frame parser | 289 | 200 | PASS |
| HPACK decoder | 290 | 250 | PASS |
| URL authority parser | 825 | 500 | PASS |
| Proxy parser | 480 | 300 | PASS |

The manifest
[`tools/gates/manifests/m7-023-linux-fuzz.json`](../../../tools/gates/manifests/m7-023-linux-fuzz.json)
pins the corpus path, raw-file SHA-256, test filter, seed, threshold, package,
and timeout for every target. Each target consumes the corpus bytes supplied by
the gate and emits exactly one independently checked `M7023_FUZZ` marker.

The formal campaign was rerun after M6-026 changed HTTP/2 and public HTTP test
sources. The previous report's source fingerprint no longer matched the
working tree, so it was not reused. The unchanged manifest, corpora, seed and
thresholds passed again with the source fingerprint recorded above.

## Crash retention and replay

A nonzero exit, signal, timeout, missing or duplicate marker, target/seed
mismatch, or threshold miss produces a bounded JSON artifact under
`linux_glibc_x86_64/crashes/<run-id>/`. The artifact records the checked-in
campaign coordinates, process result, corpus and manifest digests, and this
replay command:

```shell
scripts/gate-m7-023-linux-fuzz \
  --replay-crash <crash.json> \
  --output <replay-report.json>
```

Replay ignores executable commands stored in an artifact. It resolves the
target from the current checked-in manifest and requires the artifact's seed,
filter, threshold, corpus path, corpus digest, and manifest digest to match.
A native replay of the chunked-decoder campaign passed 127/100 iterations. Its
report is
[`linux_glibc_x86_64/replay-report.json`](linux_glibc_x86_64/replay-report.json)
with SHA-256
`016b02bf365492b7fb230beeefa486221178e5a6905a661e32b1009433dbc7af`.
The replay report carries the same current source and manifest fingerprints as
the formal campaign report.

## Verification

| Command | Result |
|---|---|
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-023/test-plan.md --json` | PASS; P=7, S=13, T=12 |
| `python3 -m py_compile tools/gates/m7_023_linux_fuzz.py tools/gates/tests/test_m7_023_linux_fuzz.py` | PASS |
| `python3 -m unittest tools.gates.tests.test_m7_023_linux_fuzz` | 6 passed |
| `cjpm test -j 1 --no-run --no-progress --no-color` | PASS; all test packages compiled |
| Direct normal-mode execution of the five affected package test classes | 17 selected cases passed, 0 failed |
| `scripts/gate-m7-023-linux-fuzz` | PASS; 10 targets, 6,465 iterations, 0 crashes |
| `scripts/gate-m7-023-linux-fuzz --replay-crash ...` | PASS; one target replayed with the same corpus, seed and threshold |
| `scripts/check` | PASS; 99 repository tests, 124 gate tests, 23 benchmark tests, architecture/check/build PASS, 554 Cangjie tests passed, 22 skipped, 0 failed |

The first formal attempt ran in a restricted sandbox. The Cangjie unittest
runner could not create its loopback control socket and all ten processes
failed before entering their test bodies with `Operation not permitted`. The
gate correctly saved replay artifacts. The same source then passed in the
authorized native Linux environment. Those sandbox artifacts were removed
because they were environmental diagnostics, not unresolved parser crashes.

The first complete `scripts/check` run observed one unrelated timing miss in
`StdNetTransportTest.cancellationWakesBlockedReadAndIsNeverReportedAsEof`.
That exact test passed 10/10 isolated reruns, and the second complete
`scripts/check` run passed. M7-023 does not change transport production code.

## Scope boundary

This result closes only M7-023 for native Linux x86_64 glibc. It does not claim
coverage-guided compiler fuzzing, another operating system, Linux musl, the
M7-022 soak, M7-024 performance qualification, or global M7 completion. It
does not modify or depend on runtime, `std`, `std.net`, stdx, or SDK source.
