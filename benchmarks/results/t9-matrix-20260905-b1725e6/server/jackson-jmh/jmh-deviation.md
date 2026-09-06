# Jackson JMH vs hand-timed deviation

JMH (1 fork, 2x1s warmup, 5x1s measurement, AverageTime us/op) vs the
hand-written loop timer (1s warmup, 5s in 200 batches, median of batch
medians). Same fixtures, same Jackson 2.17.2, same CPU pin.

| case | hand-timed us | JMH us | JMH/hand |
|---|---|---|---|
| t9_1_1_primitiveSerialize | 0.434 | 0.420 | 0.968 |
| t9_1_2_primitiveDeserialize | 0.636 | 0.629 | 0.990 |
| t9_1_3_primitiveRoundTrip | 1.111 | 1.105 | 0.995 |
| t9_2_1_shortStringSerialize | 0.417 | 0.397 | 0.953 |
| t9_2_2_longStringSerialize | 13.973 | 13.232 | 0.947 |
| t9_2_3_escapeStringSerialize | 0.516 | 0.520 | 1.008 |
| t9_2_4_unicodeStringSerialize | 0.796 | 0.576 | 0.723 |
| t9_3_1_smallArraySerialize | 0.321 | 0.305 | 0.951 |
| t9_3_2_largeArraySerialize | 7.136 | 7.429 | 1.041 |
| t9_3_3_largeArrayDeserialize | 28.620 | 25.142 | 0.878 |
| t9_3_4_smallMapSerialize | 0.594 | 0.531 | 0.894 |
| t9_3_5_largeMapSerialize | 3.594 | 3.006 | 0.836 |
| t9_3_6_largeMapDeserialize | 7.337 | 6.821 | 0.930 |
| t9_3_7_nestedCollectionSerialize | 1.026 | 1.003 | 0.977 |
| t9_3_8_nestedCollectionDeserialize | 3.540 | 2.727 | 0.770 |
| t9_3_9_largeFloat64ArraySerialize | 191.240 | 199.468 | 1.043 |
| t9_4_1_deepNestedSerialize | 0.436 | 0.405 | 0.928 |
| t9_4_2_deepNestedDeserialize | 0.796 | 0.676 | 0.849 |
| t9_4_3_wideSerialize | 0.953 | 0.845 | 0.887 |
| t9_4_4_wideDeserialize | 1.615 | 1.446 | 0.895 |
| t9_4_5_ultraWideSerialize | 1.791 | 1.588 | 0.887 |
| t9_4_6_ultraWideDeserialize | 4.035 | 2.746 | 0.681 |
| t9_5_1_optionSerialize | 0.389 | 0.355 | 0.914 |
| t9_5_2_optionDeserialize | 0.759 | 0.613 | 0.807 |
| t9_5_3_optionRoundTrip | 1.192 | 1.087 | 0.912 |
| t9_5_4_emptyContainersSerialize | 0.288 | 0.236 | 0.819 |
| t9_5_5_emptyContainersDeserialize | 0.499 | 0.413 | 0.829 |
| t9_5_6_int64ExtremesSerialize | 0.350 | 0.309 | 0.884 |
| t9_5_7_int64ExtremesDeserialize | 0.706 | 0.546 | 0.774 |
| t9_5_8_unknownFieldDeserialize | 1.118 | 1.101 | 0.985 |
| t9_b_1_bytesParsePrimitive | 0.675 | 0.619 | 0.917 |
| t9_b_2_bytesParseLargeDoc | ABSENT | 2817.618 | ABSENT |
| t9_b_3_streamLargeDoc | ABSENT | 3147.552 | ABSENT |

Geomean of JMH/hand ratios: **0.895** (>1.0 means the hand-timed numbers were faster-looking, i.e. optimistic).

