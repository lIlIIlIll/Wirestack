# T9 matrix — 2026-09-05 — yjson @ bb43321

Single-run T9 matrix over Jackson + yjson/json4cj/cjjson × {msgc, daily},
produced by `scripts/run_t9_matrix.py`. **Diagnostic snapshot, not a release
qualification**: one run per cell, no alternating/reversed A-B rounds, no
cross-profile repetition. Per the 0.1.0 performance discipline these numbers
must not be quoted as performance-multiplier claims.

## Identity

- yjson source: local commit `bb43321` (post-remediation tree), uploaded as
  `Server:<home>/yjson-t9-041976b/`; per-file sha256 identity recorded
  in `provenance.json` (`yjson_source_cj_sha256` = 74da3e61…).
- json4cj: pinned `df204648387cba7d2c7cb9d249557ee741318a99` (`main`).
- cjjson: `<home>/cangjieJSON` server checkout
  (cj tree sha 0a237d6b…).
- Toolchains: msgc cjc 0.0.1 (msgc-final-20260902) with
  `--gc-mode=marksweep` via `--cfg`; daily cjc 1.1.0-alpha.20260829040003.
  Server toolchain digests in `provenance.json`.

## Environment

- Server `ubuntu2223131`, 96 cores, CPU-pinned (`--cpu 8`), cjHeapSize=128MB
  for the JVM cells.
- Jackson 2.17.2 + JMH 1.37 (jars fetched from Maven Central at run time).

## Reproduce

```bash
python3 scripts/run_t9_matrix.py <output-dir> \
  --server Server \
  --msgc-sdk <home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64 \
  --daily-sdk-local ~/cangjie_sdk/daily \
  --yjson-source <home>/yjson-t9-041976b \
  --cjpm-tools-bin <home>/cangjie_sdk/msgc-bugfix-20260831/linux_release_x86_64/tools/bin \
  --cjjson-source <home>/cangjieJSON \
  --remote-workdir <home>/yjson-t9-matrix-041976b \
  --cpu 8
```

The orchestrator re-prepares both yjson copies re-entrantly, clones json4cj,
copies the cjjson T9 port, builds every cell, runs the 22-case throughput
battery per cell, the bytes/stream track, Jackson via both a hand-timed
harness and JMH, and captures per-process Max RSS via `/usr/bin/time -v`.

## Contents

- `comparison.md` — per-case medians, geomeans, bytes/stream ratios,
  Max-RSS table, JMH-vs-hand-timed deviation, per-cell consistency line.
- `provenance.json` — source/toolchain identity (commit, sha256 digests).
- `server/<cell>/` — raw per-cell evidence: `metadata.json`, `summary.csv`,
  `manifest.csv`, per-case raw outputs under `raw/`.
- `checksums.txt` — sha256 over every archived file.
