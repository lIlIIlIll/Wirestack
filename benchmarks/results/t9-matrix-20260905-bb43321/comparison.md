# T9 matrix: Jackson + yjson/json4cj/cjjson x {msgc, daily}

Single run, CPU pinned, cjHeapSize=128MB; values are per-case medians in microseconds.

| case | jackson | yjson msgc | yjson daily | json4cj msgc | json4cj daily | cjjson msgc | cjjson daily |
|---|---|---|---|---|---|---|---|
| t9_1_1_primitiveSerialize | 0.42 | 0.63 | 0.85 | 0.92 | ABSENT | 2.24 | 4.85 |
| t9_1_2_primitiveDeserialize | 0.63 | 0.66 | 1.45 | 5.41 | ABSENT | 1.75 | 6.82 |
| t9_1_3_primitiveRoundTrip | 1.15 | 1.36 | 2.37 | 6.98 | ABSENT | 3.45 | 15.37 |
| t9_2_1_shortStringSerialize | 0.42 | 0.51 | 1.36 | 0.84 | ABSENT | 1.49 | 5.81 |
| t9_2_2_longStringSerialize | 13.38 | 3.27 | 6.83 | 12.12 | ABSENT | 17.13 | 19.79 |
| t9_2_3_escapeStringSerialize | 0.52 | 0.71 | 1.33 | 1.02 | ABSENT | 1.68 | 6.11 |
| t9_2_4_unicodeStringSerialize | 0.77 | 0.51 | 1.46 | 0.89 | ABSENT | 1.71 | 5.79 |
| t9_3_1_smallArraySerialize | 0.34 | 0.49 | 1.45 | 0.81 | ABSENT | 5.24 | 12.45 |
| t9_3_2_largeArraySerialize | 7.82 | 4.11 | 5.73 | 7.13 | ABSENT | 278.93 | 485.46 |
| t9_3_3_largeArrayDeserialize | 27.58 | 13.32 | 34.01 | 41.29 | ABSENT | 83.39 | 664.84 |
| t9_3_4_smallMapSerialize | 0.59 | 0.71 | 1.90 | 1.34 | ABSENT | 8.19 | 31.24 |
| t9_3_5_largeMapSerialize | 3.39 | 3.93 | 6.86 | 8.63 | ABSENT | 51.49 | 280.45 |
| t9_3_6_largeMapDeserialize | 6.76 | 9.97 | 33.60 | 15.77 | ABSENT | 105.98 | 227.84 |
| t9_3_7_nestedCollectionSerialize | 1.07 | 1.46 | 2.20 | 2.06 | ABSENT | 29.97 | 85.89 |
| t9_3_8_nestedCollectionDeserialize | 3.60 | 4.28 | 23.10 | 10.38 | ABSENT | 20.57 | 98.38 |
| t9_3_9_largeFloat64ArraySerialize | 195.29 | 29.71 | 34.44 | 85.73 | ABSENT | 368.19 | 1772.95 |
| t9_4_1_deepNestedSerialize | 0.44 | 0.70 | 1.63 | 0.84 | ABSENT | 1.14 | 11.07 |
| t9_4_2_deepNestedDeserialize | 0.73 | 0.55 | 3.32 | 4.99 | ABSENT | 2.07 | 13.28 |
| t9_4_3_wideSerialize | 0.93 | 1.50 | 1.70 | 1.80 | ABSENT | 5.68 | 13.73 |
| t9_4_4_wideDeserialize | 1.57 | 1.89 | 2.89 | 5.69 | ABSENT | 4.45 | 26.51 |
| t9_4_5_ultraWideSerialize | 1.65 | 1.22 | 2.59 | 1.74 | ABSENT | 15.75 | 41.24 |
| t9_4_6_ultraWideDeserialize | 3.50 | 1.38 | 2.15 | 5.13 | ABSENT | 7.81 | 44.54 |
| t9_5_1_optionSerialize | 0.41 | 0.82 | 2.34 | 0.97 | ABSENT | 2.44 | 6.13 |
| t9_5_2_optionDeserialize | 0.73 | 1.76 | 4.57 | 4.22 | ABSENT | 2.05 | 12.98 |
| t9_5_3_optionRoundTrip | 1.19 | 3.56 | 7.57 | 5.65 | ABSENT | 4.27 | 20.25 |
| t9_5_4_emptyContainersSerialize | 0.29 | 0.54 | 1.46 | 0.83 | ABSENT | 2.34 | 9.84 |
| t9_5_5_emptyContainersDeserialize | 0.50 | 0.74 | 5.36 | 5.70 | ABSENT | 3.30 | 16.77 |
| t9_5_6_int64ExtremesSerialize | 0.37 | 0.36 | 0.96 | 0.73 | ABSENT | 1.83 | 4.39 |
| t9_5_7_int64ExtremesDeserialize | 0.66 | 0.27 | 1.00 | 5.03 | ABSENT | 1.87 | 5.64 |
| t9_5_8_unknownFieldDeserialize | 1.09 | 1.90 | 10.92 | 10.51 | ABSENT | 6.90 | 16.75 |

## Geomeans

| metric | yjson | json4cj | cjjson |
|---|---|---|---|
| msgc / Jackson | 1.018 | 2.576 | 5.111 |
| daily / Jackson | 2.466 | ABSENT | 18.682 |
| daily / msgc | 2.423 | ABSENT | 3.655 |

- group `serialize` (n=17) msgc/Jackson geomean: yjson=0.970, json4cj=1.648, cjjson=6.285
- group `deserialize` (n=11) msgc/Jackson geomean: yjson=0.981, json4cj=4.497, cjjson=4.023
- group `roundtrip` (n=2) msgc/Jackson geomean: yjson=1.884, json4cj=5.373, cjjson=3.286

## Bytes/stream track (t9_b_*; cjjson has no bytes API — not comparable)

| case | jackson | jackson vs string | yjson msgc | yjson msgc vs string | yjson daily | yjson daily vs string | json4cj msgc | json4cj msgc vs string | json4cj daily | json4cj daily vs string |
|---|---|---|---|---|---|---|---|---|---|---|
| t9_b_1_bytesParsePrimitive | 0.68 | 1.081 | 13.44 | 20.405 | 19.35 | 13.374 | 5.20 | 0.961 | ABSENT | ABSENT |

Reading: `vs string` = bytes/stream case divided by its String-input counterpart (b_1 vs t9_1_2, b_2/b_3 vs t9_5_10); <1.0 means the bytes path is faster. Jackson's A track already parses bytes natively, so its ratio is ~1 by construction.

## Max RSS (MB, /usr/bin/time -v per cjpm bench process)

| case | yjson-msgc | yjson-daily | json4cj-msgc | cjjson-msgc | cjjson-daily |
|---|---|---|---|---|---|
| t9_1_1_primitiveSerialize | 84.4 | 331.2 | 84.5 | 84.3 | 331.2 |
| t9_1_2_primitiveDeserialize | 84.3 | 331.0 | 102.3 | 84.2 | 331.2 |
| t9_1_3_primitiveRoundTrip | 84.2 | 331.2 | 86.2 | 84.5 | 331.2 |
| t9_2_1_shortStringSerialize | 84.5 | 331.2 | 84.7 | 84.6 | 331.3 |
| t9_2_2_longStringSerialize | 84.1 | 331.2 | 85.6 | 84.2 | 331.1 |
| t9_2_3_escapeStringSerialize | 84.1 | 331.2 | 84.6 | 84.3 | 331.2 |
| t9_2_4_unicodeStringSerialize | 84.3 | 331.2 | 84.8 | 84.3 | 331.2 |
| t9_3_1_smallArraySerialize | 84.2 | 331.2 | 84.2 | 84.4 | 331.2 |
| t9_3_2_largeArraySerialize | 84.5 | 331.2 | 84.6 | 84.6 | 331.2 |
| t9_3_3_largeArrayDeserialize | 84.6 | 331.1 | 86.7 | 84.3 | 331.1 |
| t9_3_4_smallMapSerialize | 84.3 | 331.2 | 84.4 | 84.5 | 331.2 |
| t9_3_5_largeMapSerialize | 84.3 | 331.1 | 85.6 | 84.3 | 331.2 |
| t9_3_6_largeMapDeserialize | 84.4 | 331.2 | 85.5 | 84.6 | 331.2 |
| t9_3_7_nestedCollectionSerialize | 84.0 | 331.2 | 84.3 | 84.3 | 331.2 |
| t9_3_8_nestedCollectionDeserialize | 84.7 | 331.2 | 85.6 | 84.6 | 331.2 |
| t9_3_9_largeFloat64ArraySerialize | 84.3 | 331.2 | 85.1 | 84.3 | 331.2 |
| t9_4_1_deepNestedSerialize | 84.4 | 331.2 | 85.8 | 84.3 | 331.1 |
| t9_4_2_deepNestedDeserialize | 84.7 | 331.2 | 93.8 | 84.5 | 331.2 |
| t9_4_3_wideSerialize | 84.6 | 331.1 | 107.5 | 84.1 | 331.1 |
| t9_4_4_wideDeserialize | 84.5 | 331.2 | 85.7 | 84.3 | 331.0 |
| t9_4_5_ultraWideSerialize | 84.7 | 331.1 | 85.5 | 84.4 | 331.2 |
| t9_4_6_ultraWideDeserialize | 84.6 | 331.1 | 85.7 | 84.3 | 331.2 |
| t9_5_1_optionSerialize | 84.6 | 331.2 | 89.1 | 84.6 | 331.2 |
| t9_5_2_optionDeserialize | 84.6 | 331.2 | 87.9 | 84.4 | 331.0 |
| t9_5_3_optionRoundTrip | 84.4 | 331.2 | 87.3 | 84.6 | 331.2 |
| t9_5_4_emptyContainersSerialize | 84.3 | 331.2 | 84.6 | 84.6 | 331.2 |
| t9_5_5_emptyContainersDeserialize | 84.3 | 331.2 | 87.8 | 84.7 | 331.2 |
| t9_5_6_int64ExtremesSerialize | 84.2 | 331.2 | 85.4 | 84.6 | 331.2 |
| t9_5_7_int64ExtremesDeserialize | 84.4 | 331.3 | 119.0 | 84.3 | 331.1 |
| t9_5_8_unknownFieldDeserialize | 84.5 | 331.2 | 86.4 | 84.7 | 331.2 |

## Jackson: JMH vs hand-timed timer

See `jmh-deviation.md` in the jackson-jmh cell for the per-case table;
summary: JMH geomean / hand-timed geomean over all measured cases.
- Geomean of JMH/hand ratios: **0.899** (>1.0 means the hand-timed numbers were faster-looking, i.e. optimistic).


## Consistency

- cjjson-daily: host=ubuntu2223131 cfg=False cjc=Cangjie Compiler: 1.1.0-alpha.20260829040003 (cjnative) stdx=<home>/yjson-t9-matrix-041976b/daily-sdk/linux_x86_64_cjnative/dynamic/stdx
- cjjson-msgc: host=ubuntu2223131 cfg=True cjc=Cangjie Compiler: 0.0.1 (cjnative) stdx=<home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64/linux_x86_64_cjnative/dynamic/stdx
- jackson: host=ubuntu2223131 cfg=None cjc=? stdx=None
- json4cj-msgc: host=ubuntu2223131 cfg=True cjc=Cangjie Compiler: 0.0.1 (cjnative) stdx=<home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64/linux_x86_64_cjnative/dynamic/stdx
- yjson-daily: host=ubuntu2223131 cfg=False cjc=Cangjie Compiler: 1.1.0-alpha.20260829040003 (cjnative) stdx=<home>/yjson-t9-matrix-041976b/daily-sdk/linux_x86_64_cjnative/dynamic/stdx
- yjson-msgc: host=ubuntu2223131 cfg=True cjc=Cangjie Compiler: 0.0.1 (cjnative) stdx=<home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64/linux_x86_64_cjnative/dynamic/stdx
