# Jackson JMH vs hand-timed deviation

JMH (1 fork, 2x1s warmup, 5x1s measurement, AverageTime us/op) vs the
hand-written loop timer (1s warmup, 5s in 200 batches, median of batch
medians). Same fixtures, same Jackson 2.17.2, same CPU pin.

| case | hand-timed us | JMH us | JMH/hand |
|---|---|---|---|
| t9_1_1_primitiveSerialize | 0.425 | 0.418 | 0.982 |
| t9_1_2_primitiveDeserialize | 0.633 | 0.608 | 0.961 |
| t9_1_3_primitiveRoundTrip | 1.152 | 1.121 | 0.973 |
| t9_2_1_shortStringSerialize | 0.423 | 0.399 | 0.944 |
| t9_2_2_longStringSerialize | 13.379 | 13.544 | 1.012 |
| t9_2_3_escapeStringSerialize | 0.516 | 0.523 | 1.013 |
| t9_2_4_unicodeStringSerialize | 0.773 | 0.547 | 0.707 |
| t9_3_1_smallArraySerialize | 0.345 | 0.316 | 0.917 |
| t9_3_2_largeArraySerialize | 7.821 | 7.377 | 0.943 |
| t9_3_3_largeArrayDeserialize | 27.584 | 25.223 | 0.914 |
| t9_3_4_smallMapSerialize | 0.594 | 0.513 | 0.864 |
| t9_3_5_largeMapSerialize | 3.392 | 3.020 | 0.890 |
| t9_3_6_largeMapDeserialize | 6.760 | 6.456 | 0.955 |
| t9_3_7_nestedCollectionSerialize | 1.067 | 1.028 | 0.963 |
| t9_3_8_nestedCollectionDeserialize | 3.604 | 2.809 | 0.779 |
| t9_3_9_largeFloat64ArraySerialize | 195.294 | 201.026 | 1.029 |
| t9_4_1_deepNestedSerialize | 0.437 | 0.401 | 0.918 |
| t9_4_2_deepNestedDeserialize | 0.728 | 0.662 | 0.909 |
| t9_4_3_wideSerialize | 0.930 | 0.879 | 0.945 |
| t9_4_4_wideDeserialize | 1.566 | 1.415 | 0.904 |
| t9_4_5_ultraWideSerialize | 1.651 | 1.379 | 0.835 |
| t9_4_6_ultraWideDeserialize | 3.503 | 2.801 | 0.800 |
| t9_5_1_optionSerialize | 0.405 | 0.359 | 0.887 |
| t9_5_2_optionDeserialize | 0.730 | 0.611 | 0.837 |
| t9_5_3_optionRoundTrip | 1.186 | 1.079 | 0.910 |
| t9_5_4_emptyContainersSerialize | 0.289 | 0.233 | 0.805 |
| t9_5_5_emptyContainersDeserialize | 0.498 | 0.418 | 0.839 |
| t9_5_6_int64ExtremesSerialize | 0.373 | 0.291 | 0.779 |
| t9_5_7_int64ExtremesDeserialize | 0.659 | 0.548 | 0.831 |
| t9_5_8_unknownFieldDeserialize | 1.095 | 1.124 | 1.026 |
| t9_b_1_bytesParsePrimitive | 0.684 | 0.620 | 0.906 |
| t9_b_2_bytesParseLargeDoc | ABSENT | 2853.564 | ABSENT |
| t9_b_3_streamLargeDoc | ABSENT | 3032.890 | ABSENT |

Geomean of JMH/hand ratios: **0.899** (>1.0 means the hand-timed numbers were faster-looking, i.e. optimistic).

