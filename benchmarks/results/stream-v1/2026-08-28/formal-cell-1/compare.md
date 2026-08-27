| Case | Baseline | Candidate | Paired improvement | Candidate wins | CV B/C |
|:--|--:|--:|--:|--:|--:|
| decode-person-chunk-4k | 48.922 us | 18.992 us | +59.62% | 11/11 | 9.53% / 6.48% |
| decode-person-chunk-64 | 48.917 us | 21.350 us | +56.49% | 10/11 | 21.46% / 9.11% |
| decode-person-chunk-random | 48.831 us | 18.874 us | +60.15% | 11/11 | 14.38% / 3.52% |
| decode-records-1m-chunk-4k | 151062.656 us | 72135.936 us | +52.63% | 11/11 | 0.55% / 6.24% |
| decode-records-1m-chunk-64 | 152077.824 us | 88562.432 us | +41.64% | 11/11 | 0.57% / 3.83% |
| decode-records-1m-chunk-random | 151162.112 us | 68197.632 us | +55.00% | 11/11 | 0.46% / 6.99% |
| decode-records-64k-chunk-4k | 9161.736 us | 3484.311 us | +61.93% | 11/11 | 2.90% / 12.92% |
| decode-records-64k-chunk-64 | 9147.128 us | 4074.923 us | +54.50% | 11/11 | 11.23% / 15.57% |
| decode-records-64k-chunk-random | 8921.525 us | 3433.798 us | +62.06% | 11/11 | 2.96% / 0.54% |
| encode-person-counting | 7.808 us | 8.686 us | -10.64% | 1/11 | 25.80% / 16.35% |
| encode-person-memory | 7.507 us | 8.333 us | -13.32% | 2/11 | 24.56% / 20.18% |
| encode-records-1m-counting | 14962.887 us | 13814.810 us | +6.64% | 10/11 | 1.57% / 3.59% |
| encode-records-1m-memory | 12635.555 us | 11909.691 us | +5.60% | 10/11 | 19.19% / 17.01% |
| encode-records-64k-counting | 1267.005 us | 1231.787 us | +3.35% | 10/11 | 1.96% / 4.80% |
| encode-records-64k-memory | 1167.054 us | 1186.162 us | -1.80% | 3/11 | 2.42% / 9.42% |

Gates:

- PASS `no_stable_core_regression_over_5_percent`
- FAIL `two_canonical_decode_improvements`
- FAIL `both_sides_cv_at_most_5_percent`
