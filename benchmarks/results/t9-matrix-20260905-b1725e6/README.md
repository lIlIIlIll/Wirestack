# T9 matrix — 2026-09-05 — yjson @ b1725e6 (post-optimization)

Second single-run T9 matrix, identical environment and method to
`t9-matrix-20260905-bb43321` (same server, same toolchains, same
Jackson/JMH setup, CPU-pinned). Candidate = dev HEAD after the
hot-path optimization series:

- `dec97ac` map duplicate detection via HashMap.add return
- `4a8d0b0` overwrite-array path state + table-driven escape scan
- `a33add5` cursor-direct Option<Int64>/String scalar reads
- `4f110b0` linear seen scan for policy-aware skips
- `c959735` pooled-writer state reuse

## yjson-msgc vs the bb43321 archived run (same server)

| group | geomean ratio (new/base) |
| --- | ---: |
| overall (n=30) | **0.9585** |
| serialize (n=17) | 0.9733 |
| deserialize (n=11) | 0.9723 |

Largest per-case improvements (>5%):
t9_5_2_optionDeserialize -52.8%, t9_5_3_optionRoundTrip -39.8%,
t9_2_2_longStringSerialize -29.6%, t9_5_1_optionSerialize -11.9%,
t9_5_8_unknownFieldDeserialize -6.1%.

Single run vs single run: ratios within ±5% are noise. Still not a
release qualification (no 11-round alternating A-B).

## Contents

- `comparison.md`, `provenance.json` (this run), `provenance-5c9ee7c.json`
  (intermediate run kept for reference), `server/<cell>/` raw evidence.
