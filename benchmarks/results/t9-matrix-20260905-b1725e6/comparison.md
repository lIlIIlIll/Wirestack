# T9 matrix: Jackson + yjson/json4cj/cjjson x {msgc, daily}

Single run, CPU pinned, cjHeapSize=128MB; values are per-case medians in microseconds.

| case | jackson | yjson msgc | yjson daily | json4cj msgc | json4cj daily | cjjson msgc | cjjson daily |
|---|---|---|---|---|---|---|---|
| t9_1_1_primitiveSerialize | 0.43 | 0.61 | 1.14 | 0.89 | ABSENT | 2.24 | 4.95 |
| t9_1_2_primitiveDeserialize | 0.64 | 0.69 | 2.05 | 5.44 | ABSENT | 1.72 | 6.89 |
| t9_1_3_primitiveRoundTrip | 1.11 | 1.37 | 3.02 | 6.40 | ABSENT | 3.45 | 15.67 |
| t9_2_1_shortStringSerialize | 0.42 | 0.49 | 1.35 | 0.85 | ABSENT | 1.47 | 4.31 |
| t9_2_2_longStringSerialize | 13.97 | 2.30 | 6.26 | 11.93 | ABSENT | 17.15 | 21.35 |
| t9_2_3_escapeStringSerialize | 0.52 | 0.68 | 1.31 | 1.02 | ABSENT | 1.67 | 6.55 |
| t9_2_4_unicodeStringSerialize | 0.80 | 0.53 | 1.33 | 0.89 | ABSENT | 1.70 | 5.52 |
| t9_3_1_smallArraySerialize | 0.32 | 0.48 | 0.87 | 0.82 | ABSENT | 5.28 | 11.34 |
| t9_3_2_largeArraySerialize | 7.14 | 4.13 | 5.50 | 7.18 | ABSENT | 281.11 | 606.89 |
| t9_3_3_largeArrayDeserialize | 28.62 | 15.22 | 35.07 | 38.08 | ABSENT | 83.30 | 482.00 |
| t9_3_4_smallMapSerialize | 0.59 | 0.70 | 1.23 | 1.35 | ABSENT | 8.23 | 31.12 |
| t9_3_5_largeMapSerialize | 3.59 | 3.95 | 5.24 | 8.58 | ABSENT | 51.63 | 275.01 |
| t9_3_6_largeMapDeserialize | 7.34 | 10.29 | 35.94 | 15.46 | ABSENT | 104.83 | 495.76 |
| t9_3_7_nestedCollectionSerialize | 1.03 | 1.47 | 2.08 | 2.07 | ABSENT | 29.99 | 66.73 |
| t9_3_8_nestedCollectionDeserialize | 3.54 | 4.48 | 23.87 | 10.18 | ABSENT | 20.52 | 96.97 |
| t9_3_9_largeFloat64ArraySerialize | 191.24 | 30.00 | 34.37 | 86.08 | ABSENT | 368.35 | 1908.70 |
| t9_4_1_deepNestedSerialize | 0.44 | 0.72 | 1.20 | 0.84 | ABSENT | 1.20 | 11.14 |
| t9_4_2_deepNestedDeserialize | 0.80 | 0.59 | 2.63 | 5.27 | ABSENT | 2.09 | 13.38 |
| t9_4_3_wideSerialize | 0.95 | 1.47 | 1.57 | 1.79 | ABSENT | 5.66 | 13.92 |
| t9_4_4_wideDeserialize | 1.61 | 1.92 | 3.65 | 5.53 | ABSENT | 5.67 | 27.02 |
| t9_4_5_ultraWideSerialize | 1.79 | 1.23 | 2.47 | 1.74 | ABSENT | 15.77 | 41.23 |
| t9_4_6_ultraWideDeserialize | 4.04 | 1.41 | 3.59 | 5.07 | ABSENT | 7.83 | 31.57 |
| t9_5_1_optionSerialize | 0.39 | 0.72 | 1.73 | 0.97 | ABSENT | 2.36 | 6.08 |
| t9_5_2_optionDeserialize | 0.76 | 0.83 | 5.41 | 5.64 | ABSENT | 2.05 | 13.47 |
| t9_5_3_optionRoundTrip | 1.19 | 2.14 | 6.51 | 5.58 | ABSENT | 4.28 | 17.77 |
| t9_5_4_emptyContainersSerialize | 0.29 | 0.55 | 1.15 | 0.85 | ABSENT | 2.39 | 7.69 |
| t9_5_5_emptyContainersDeserialize | 0.50 | 0.75 | 6.09 | 5.62 | ABSENT | 3.24 | 17.97 |
| t9_5_6_int64ExtremesSerialize | 0.35 | 0.38 | 0.70 | 0.73 | ABSENT | 1.91 | 4.48 |
| t9_5_7_int64ExtremesDeserialize | 0.71 | 0.30 | 1.56 | 5.15 | ABSENT | 1.87 | 8.52 |
| t9_5_8_unknownFieldDeserialize | 1.12 | 1.79 | 7.91 | 8.79 | ABSENT | 6.91 | 26.66 |

## Geomeans

| metric | yjson | json4cj | cjjson |
|---|---|---|---|
| msgc / Jackson | 0.964 | 2.538 | 5.098 |
| daily / Jackson | 2.353 | ABSENT | 18.783 |
| daily / msgc | 2.442 | ABSENT | 3.684 |

- group `serialize` (n=17) msgc/Jackson geomean: yjson=0.949, json4cj=1.657, cjjson=6.353
- group `deserialize` (n=11) msgc/Jackson geomean: yjson=0.911, json4cj=4.306, cjjson=3.918
- group `roundtrip` (n=2) msgc/Jackson geomean: yjson=1.490, json4cj=5.193, cjjson=3.340

## Bytes/stream track (t9_b_*; cjjson has no bytes API — not comparable)

| case | jackson | jackson vs string | yjson msgc | yjson msgc vs string | yjson daily | yjson daily vs string | json4cj msgc | json4cj msgc vs string | json4cj daily | json4cj daily vs string |
|---|---|---|---|---|---|---|---|---|---|---|
| t9_b_1_bytesParsePrimitive | 0.68 | 1.061 | 13.40 | 19.315 | 20.33 | 9.918 | 5.26 | 0.968 | ABSENT | ABSENT |

Reading: `vs string` = bytes/stream case divided by its String-input counterpart (b_1 vs t9_1_2, b_2/b_3 vs t9_5_10); <1.0 means the bytes path is faster. Jackson's A track already parses bytes natively, so its ratio is ~1 by construction.

## Max RSS (MB, /usr/bin/time -v per cjpm bench process)

| case | yjson-msgc | yjson-daily | json4cj-msgc | cjjson-msgc | cjjson-daily |
|---|---|---|---|---|---|
| t9_1_1_primitiveSerialize | 84.7 | 331.3 | 85.9 | 84.5 | 331.2 |
| t9_1_2_primitiveDeserialize | 84.4 | 331.2 | 103.1 | 84.3 | 331.2 |
| t9_1_3_primitiveRoundTrip | 84.6 | 331.0 | 85.8 | 84.4 | 331.1 |
| t9_2_1_shortStringSerialize | 84.3 | 331.2 | 84.3 | 84.6 | 331.2 |
| t9_2_2_longStringSerialize | 84.4 | 331.2 | 87.3 | 84.6 | 331.2 |
| t9_2_3_escapeStringSerialize | 84.4 | 331.2 | 84.5 | 84.3 | 331.0 |
| t9_2_4_unicodeStringSerialize | 84.5 | 331.1 | 84.3 | 84.6 | 331.2 |
| t9_3_1_smallArraySerialize | 84.1 | 331.2 | 84.3 | 84.2 | 331.2 |
| t9_3_2_largeArraySerialize | 84.3 | 331.2 | 84.5 | 84.4 | 331.0 |
| t9_3_3_largeArrayDeserialize | 84.6 | 331.2 | 85.5 | 84.7 | 331.1 |
| t9_3_4_smallMapSerialize | 84.2 | 331.1 | 84.2 | 84.5 | 331.1 |
| t9_3_5_largeMapSerialize | 84.2 | 331.2 | 84.4 | 84.4 | 331.2 |
| t9_3_6_largeMapDeserialize | 84.5 | 331.2 | 84.5 | 84.2 | 331.1 |
| t9_3_7_nestedCollectionSerialize | 84.4 | 331.2 | 84.7 | 84.6 | 331.2 |
| t9_3_8_nestedCollectionDeserialize | 84.3 | 331.2 | 88.6 | 84.6 | 331.2 |
| t9_3_9_largeFloat64ArraySerialize | 84.2 | 331.1 | 88.2 | 84.3 | 331.2 |
| t9_4_1_deepNestedSerialize | 84.6 | 331.2 | 86.2 | 84.6 | 331.2 |
| t9_4_2_deepNestedDeserialize | 84.3 | 331.1 | 92.7 | 84.2 | 331.2 |
| t9_4_3_wideSerialize | 84.7 | 331.0 | 85.9 | 84.2 | 331.2 |
| t9_4_4_wideDeserialize | 84.1 | 331.2 | 86.1 | 84.5 | 331.2 |
| t9_4_5_ultraWideSerialize | 84.7 | 331.2 | 84.4 | 84.2 | 331.2 |
| t9_4_6_ultraWideDeserialize | 84.3 | 331.2 | 85.4 | 84.5 | 331.0 |
| t9_5_1_optionSerialize | 84.1 | 331.2 | 84.3 | 84.4 | 331.2 |
| t9_5_2_optionDeserialize | 84.4 | 331.2 | 88.0 | 84.5 | 331.3 |
| t9_5_3_optionRoundTrip | 84.3 | 331.3 | 87.7 | 84.6 | 331.1 |
| t9_5_4_emptyContainersSerialize | 84.3 | 331.2 | 84.4 | 84.2 | 331.2 |
| t9_5_5_emptyContainersDeserialize | 84.7 | 331.2 | 85.3 | 84.2 | 331.2 |
| t9_5_6_int64ExtremesSerialize | 84.6 | 331.2 | 84.2 | 84.5 | 331.2 |
| t9_5_7_int64ExtremesDeserialize | 84.3 | 331.2 | 105.0 | 84.2 | 331.2 |
| t9_5_8_unknownFieldDeserialize | 84.1 | 331.2 | 86.7 | 84.4 | 331.2 |

## Jackson: JMH vs hand-timed timer

See `jmh-deviation.md` in the jackson-jmh cell for the per-case table;
summary: JMH geomean / hand-timed geomean over all measured cases.
- Geomean of JMH/hand ratios: **0.895** (>1.0 means the hand-timed numbers were faster-looking, i.e. optimistic).


## Consistency

- cjjson-daily: host=ubuntu2223131 cfg=False cjc=Cangjie Compiler: 1.1.0-alpha.20260829040003 (cjnative) stdx=<home>/yjson-t9-matrix-b1725e6/daily-sdk/linux_x86_64_cjnative/dynamic/stdx
- cjjson-msgc: host=ubuntu2223131 cfg=True cjc=Cangjie Compiler: 0.0.1 (cjnative) stdx=<home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64/linux_x86_64_cjnative/dynamic/stdx
- jackson: host=ubuntu2223131 cfg=None cjc=? stdx=None
- json4cj-msgc: host=ubuntu2223131 cfg=True cjc=Cangjie Compiler: 0.0.1 (cjnative) stdx=<home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64/linux_x86_64_cjnative/dynamic/stdx
- yjson-daily: host=ubuntu2223131 cfg=False cjc=Cangjie Compiler: 1.1.0-alpha.20260829040003 (cjnative) stdx=<home>/yjson-t9-matrix-b1725e6/daily-sdk/linux_x86_64_cjnative/dynamic/stdx
- yjson-msgc: host=ubuntu2223131 cfg=True cjc=Cangjie Compiler: 0.0.1 (cjnative) stdx=<home>/cangjie_sdk/msgc-final-20260902/linux_release_x86_64/linux_x86_64_cjnative/dynamic/stdx
