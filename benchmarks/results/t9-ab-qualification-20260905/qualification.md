# 2026-09-05 T9 A/B qualification — bb43321 (base) vs dev b1725e6+ (optimized)

11-round alternating A/B on the msgc toolchain, per the 0.1.0 performance
discipline: fixed CPU (`--cpu 8` on a 96-core server, `ubuntu2223131`),
alternating/reversed cell order per round, one independent process per cell,
11 rounds per side. All 30 cases stable (CV <= 3% on both sides).

- A (base): yjson @ bb43321 (pre-optimization remediation tree)
- B (opt): dev @ b1725e6 series (map add-detect, overwrite-array path state,
  table-driven escape scan, cursor-direct Option scalar reads, pooled-writer
  state reuse, linear seen scan for policy-aware skips)

## Verdict

**geomean B/A = 0.9482** over all 30 cases (all stable). The optimization
series improves overall typed throughput by 5.2% with zero unstable rows.

## Per-case medians (11-round median of medians; A/B ratio)

| case | A median (us) | B median (us) | CV A / B % | B/A |
|---|---:|---:|---|---:|
| t9_1_1_primitiveSerialize | 0.635 | 0.628 | 1.6 / 2.4 | 0.989 |
| t9_1_2_primitiveDeserialize | 0.659 | 0.694 | 1.5 / 1.0 | 1.053 |
| t9_1_3_primitiveRoundTrip | 1.363 | 1.423 | 1.3 / 2.0 | 1.044 |
| t9_2_1_shortStringSerialize | 0.509 | 0.494 | 2.1 / 2.0 | 0.972 |
| t9_2_2_longStringSerialize | 3.265 | 2.057 | 0.3 / 1.8 | **0.630** |
| t9_2_3_escapeStringSerialize | 0.706 | 0.675 | 0.6 / 1.2 | 0.957 |
| t9_2_4_unicodeStringSerialize | 0.511 | 0.533 | 0.9 / 0.4 | 1.042 |
| t9_3_1_smallArraySerialize | 0.487 | 0.477 | 0.1 / 0.8 | 0.979 |
| t9_3_2_largeArraySerialize | 4.107 | 4.124 | 0.2 / 0.4 | 1.004 |
| t9_3_3_largeArrayDeserialize | 13.321 | 13.081 | 0.2 / 0.3 | 0.982 |
| t9_3_4_smallMapSerialize | 0.709 | 0.702 | 1.3 / 0.1 | 0.991 |
| t9_3_5_largeMapSerialize | 3.926 | 3.946 | 0.1 / 0.0 | 1.005 |
| t9_3_6_largeMapDeserialize | 9.967 | 10.345 | 0.2 / 0.2 | 1.038 |
| t9_3_7_nestedCollectionSerialize | 1.464 | 1.457 | 0.1 / 0.2 | 0.995 |
| t9_3_8_nestedCollectionDeserialize | 4.283 | 4.462 | 0.2 / 0.1 | 1.042 |
| t9_3_9_largeFloat64ArraySerialize | 29.711 | 29.889 | 0.5 / 0.4 | 1.006 |
| t9_4_1_deepNestedSerialize | 0.697 | 0.704 | 0.8 / 2.5 | 1.010 |
| t9_4_2_deepNestedDeserialize | 0.554 | 0.594 | 0.2 / 0.3 | 1.072 |
| t9_4_3_wideSerialize | 1.499 | 1.496 | 0.7 / 1.5 | 0.998 |
| t9_4_4_wideDeserialize | 1.893 | 1.933 | 1.3 / 2.1 | 1.021 |
| t9_4_5_ultraWideSerialize | 1.222 | 1.208 | 0.3 / 0.5 | 0.989 |
| t9_4_6_ultraWideDeserialize | 1.381 | 1.409 | 0.3 / 0.1 | 1.020 |
| t9_5_1_optionSerialize | 0.820 | 0.723 | 3.0 / 1.1 | **0.881** |
| t9_5_2_optionDeserialize | 1.761 | 0.824 | 1.2 / 0.9 | **0.468** |
| t9_5_3_optionRoundTrip | 3.560 | 2.129 | 0.8 / 0.7 | **0.598** |
| t9_5_4_emptyContainersSerialize | 0.541 | 0.559 | 0.2 / 2.1 | 1.033 |
| t9_5_5_emptyContainersDeserialize | 0.736 | 0.746 | 2.2 / 1.7 | 1.014 |
| t9_5_6_int64ExtremesSerialize | 0.361 | 0.361 | 0.2 / 1.2 | 1.000 |
| t9_5_7_int64ExtremesDeserialize | 0.269 | 0.301 | 0.1 / 0.2 | 1.118 |
| t9_5_8_unknownFieldDeserialize | 1.903 | 1.741 | 1.3 / 1.0 | **0.915** |

(A/B absolute medians are medians of 11 single-run cells; ratio is the
qualification metric and is unaffected by unit scaling.)

## Improved / regressed (>5% thresholds)

Improved: t9_5_2_optionDeserialize -53.2%, t9_5_3_optionRoundTrip -40.2%,
t9_2_2_longStringSerialize -37.0%, t9_5_1_optionSerialize -11.9%,
t9_5_8_unknownFieldDeserialize -8.5%.

Regressed (sub-100ns on sub-microsecond deserialize cases):
t9_5_7 +11.8% (+32ns), t9_4_2 +7.2% (+40ns), t9_1_2 +5.3% (+35ns) —
attributable to the cursor-direct Option null check and branch layout
shifts; geomean impact absorbed by the improved cases.

## A-side vs Jackson

The archived single-run T9 matrix (`t9-matrix-20260905-bb43321`) measured
yjson-msgc / Jackson geomean 1.018 (hand-timed). Applying this
qualification's 0.9482 ratio, the optimized tree sits at ≈0.965 vs
Jackson on the same hand-timed caliber. Jackson's own 11-round A/B
vs-Jackson multiplier claim remains out of scope here (single-run
diagnostic for the Jackson side).
