| Case | Baseline | Candidate | Paired improvement | Candidate wins | CV B/C |
|:--|--:|--:|--:|--:|--:|
| decode-person-chunk-4k | 48.922 us | 18.531 us | +61.94% | 11/11 | 9.53% / 7.21% |
| decode-person-chunk-64 | 48.917 us | 20.506 us | +55.82% | 10/11 | 21.46% / 2.12% |
| decode-person-chunk-random | 48.831 us | 18.264 us | +62.58% | 11/11 | 14.38% / 17.56% |
| decode-records-1m-chunk-4k | 151062.656 us | 70358.784 us | +53.42% | 11/11 | 0.55% / 6.80% |
| decode-records-1m-chunk-64 | 152077.824 us | 91109.504 us | +40.51% | 11/11 | 0.57% / 4.66% |
| decode-records-1m-chunk-random | 151162.112 us | 69936.896 us | +53.73% | 11/11 | 0.46% / 9.26% |
| decode-records-64k-chunk-4k | 9161.736 us | 3407.584 us | +63.07% | 11/11 | 2.90% / 7.12% |
| decode-records-64k-chunk-64 | 9147.128 us | 4071.836 us | +54.21% | 11/11 | 11.23% / 11.40% |
| decode-records-64k-chunk-random | 8921.525 us | 3431.866 us | +62.45% | 11/11 | 2.96% / 1.71% |
| encode-person-counting | 7.808 us | 8.078 us | -8.67% | 5/11 | 25.80% / 18.62% |
| encode-person-memory | 7.507 us | 7.963 us | -4.48% | 3/11 | 24.56% / 15.95% |
| encode-records-1m-counting | 14962.887 us | 13749.670 us | +7.61% | 11/11 | 1.57% / 2.08% |
| encode-records-1m-memory | 12635.555 us | 19183.744 us | -33.71% | 4/11 | 19.19% / 21.75% |
| encode-records-64k-counting | 1267.005 us | 1238.965 us | +2.48% | 9/11 | 1.96% / 2.67% |
| encode-records-64k-memory | 1167.054 us | 1199.052 us | -2.86% | 3/11 | 2.42% / 13.95% |

Gates:

- PASS `no_stable_core_regression_over_5_percent`
- FAIL `two_canonical_decode_improvements`
- FAIL `both_sides_cv_at_most_5_percent`
