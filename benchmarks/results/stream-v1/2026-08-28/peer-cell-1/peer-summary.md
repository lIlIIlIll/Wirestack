| Case | yjson | stdx.json | yjson/stdx | yjson wins | CV yjson/stdx | Stability |
|:--|--:|--:|--:|--:|--:|:--|
| decode-person-chunk-4k | 18.098 us | 143.312 us | 0.126x | 11/11 | 7.18% / 29.42% | noisy |
| decode-person-chunk-64 | 20.862 us | 88.430 us | 0.236x | 11/11 | 1.52% / 35.69% | noisy |
| decode-person-chunk-random | 17.909 us | 87.735 us | 0.204x | 11/11 | 15.60% / 27.72% | noisy |
| decode-records-1m-chunk-4k | 75826.944 us | 181590.400 us | 0.418x | 11/11 | 7.25% / 2.74% | noisy |
| decode-records-1m-chunk-64 | 93446.912 us | 191492.352 us | 0.488x | 11/11 | 3.41% / 3.01% | stable |
| decode-records-1m-chunk-random | 76646.400 us | 179625.984 us | 0.427x | 11/11 | 1.83% / 2.57% | stable |
| decode-records-64k-chunk-4k | 3389.456 us | 20953.984 us | 0.162x | 11/11 | 3.08% / 34.60% | noisy |
| decode-records-64k-chunk-64 | 4229.398 us | 21005.312 us | 0.201x | 11/11 | 0.52% / 31.61% | noisy |
| decode-records-64k-chunk-random | 3520.950 us | 10235.577 us | 0.344x | 11/11 | 1.73% / 40.32% | noisy |
| encode-person-counting | 7.920 us | 117.845 us | 0.067x | 11/11 | 4.62% / 12.65% | noisy |
| encode-person-memory | 7.243 us | 116.901 us | 0.062x | 11/11 | 28.91% / 10.98% | noisy |
| encode-records-1m-counting | 14737.050 us | 110584.064 us | 0.133x | 11/11 | 2.30% / 0.83% | stable |
| encode-records-1m-memory | 12528.352 us | 109379.584 us | 0.115x | 11/11 | 16.21% / 0.68% | noisy |
| encode-records-64k-counting | 1363.193 us | 9489.138 us | 0.144x | 11/11 | 0.56% / 14.39% | noisy |
| encode-records-64k-memory | 1245.374 us | 5567.198 us | 0.224x | 11/11 | 1.73% / 15.33% | noisy |
