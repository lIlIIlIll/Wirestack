# M12-001 native measured baselines

All cases:14 measured process rounds after2 process warmup rounds. Latencies retain every outcome.

| Scenario | Regime | Operations | Successes | Expected rejections | Successful ops/s | Successful MiB/s | P50 μs | P95 μs | P99 μs | Reference |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| tcp_bulk | normal | 112 | 112 | 0 | 21.17 | 338.79 | 45941.71 | 56365.85 | 71387.59 | NOISY |
| tcp_partial | normal | 3584 | 3584 | 0 | 5302.95 | 1.29 | 174.11 | 284.61 | 375.64 | NOISY |
| tcp_cancel | cleanup | 448 | 0 | 448 | 0.00 | 0.00 | 1106.72 | 1201.30 | 1259.44 | NOISY |
| udp_packets | normal | 14336 | 14336 | 0 | 65285.12 | 149.43 | 14.72 | 33.05 | 45.37 | NOISY |
| tls_full | normal | 448 | 448 | 0 | 117.71 | 0.03 | 1475.89 | 2214.84 | 2282.67 | NOISY |
| tls_resumed | normal | 448 | 448 | 0 | 1789.10 | 0.44 | 343.29 | 488.19 | 561.35 | NOISY |
| tls_small | normal | 3584 | 3584 | 0 | 1747.84 | 0.43 | 61.73 | 102.66 | 141.15 | NOISY |
| tls_bulk | normal | 112 | 112 | 0 | 27.86 | 445.79 | 34006.40 | 42847.80 | 46699.15 | NOISY |
| tls_failure | failure | 224 | 0 | 224 | 0.00 | 0.00 | 10293.41 | 10548.85 | 10797.41 | NOISY |
| tls_close | cleanup | 448 | 448 | 0 | 1823.83 | 0.45 | 76.93 | 94.42 | 125.64 | NOISY |
| h1_short_reuse | normal | 2800 | 2800 | 0 | 7205.71 | 0.05 | 121.32 | 224.53 | 316.85 | NOISY |
| h1_new_connection | normal | 2800 | 2800 | 0 | 4058.15 | 0.03 | 233.02 | 326.54 | 398.48 | NOISY |
| h1_bulk_4096 | normal | 14 | 14 | 0 | 58.64 | 469.13 | 16951.08 | 22789.03 | 22789.03 | NOISY |
| h1_bulk_32768 | normal | 14 | 14 | 0 | 34.93 | 279.41 | 28546.50 | 35093.00 | 35093.00 | NOISY |
| h1_concurrent | normal | 1400 | 1400 | 0 | 520.86 | 0.00 | 16744.81 | 20774.61 | 20943.49 | NOISY |
| h1_early_close | cleanup | 2800 | 2800 | 0 | 4346.18 | 0.00 | 210.65 | 309.95 | 495.00 | NOISY |
| h2_streams_1 | normal | 2800 | 2800 | 0 | 3315.24 | 0.02 | 281.33 | 355.71 | 493.99 | NOISY |
| h2_streams_10 | normal | 1400 | 1400 | 0 | 640.71 | 0.00 | 11152.42 | 21698.47 | 22910.14 | NOISY |
| h2_streams_100 | normal | 14000 | 14000 | 0 | 4096.25 | 0.03 | 18044.83 | 29346.16 | 31109.41 | NOISY |
| h2_slow_consumer | slow | 182 | 182 | 0 | 16.46 | 10.13 | 286.91 | 780610.82 | 866534.35 | NOISY |
| h2_stream_cancel | cleanup | 42 | 28 | 14 | 47.89 | 0.00 | 10766.87 | 41673.67 | 52058.42 | STABLE |
| http_overload | overload | 84 | 56 | 28 | 140.48 | 0.00 | 843.62 | 21088.28 | 21528.51 | STABLE |
| http_observed | normal | 2800 | 2800 | 0 | 6734.94 | 0.04 | 125.89 | 268.08 | 393.48 | NOISY |
| http_unobserved | normal | 2800 | 2800 | 0 | 7102.10 | 0.05 | 121.86 | 224.33 | 374.03 | NOISY |
| sse_h1 | normal | 3584 | 3584 | 0 | 57.14 | 0.00 | 140.14 | 10214.06 | 10277.92 | NOISY |
| sse_h2 | normal | 3584 | 3584 | 0 | 60.60 | 0.00 | 233.21 | 455.44 | 638.31 | NOISY |
| sse_slow | slow | 3584 | 3584 | 0 | 35.79 | 0.00 | 10228.67 | 10396.77 | 10543.66 | NOISY |
| sse_cancel | cleanup | 126 | 112 | 14 | 56.13 | 0.00 | 210.93 | 20179.31 | 20307.06 | NOISY |
| websocket_h1 | normal | 3584 | 3584 | 0 | 97.00 | 0.00 | 138.00 | 285.00 | 447.93 | NOISY |
| websocket_h2 | normal | 3584 | 3584 | 0 | 95.84 | 0.00 | 203.82 | 401.61 | 623.13 | NOISY |
| websocket_fragmented | normal | 2800 | 2800 | 0 | 92.48 | 0.00 | 509.27 | 1078.37 | 1883.02 | NOISY |
| websocket_slow | slow | 3584 | 3584 | 0 | 48.81 | 0.00 | 10231.51 | 10429.36 | 10592.85 | STABLE |
| websocket_disconnect | cleanup | 126 | 112 | 14 | 77.39 | 0.00 | 178.36 | 20639.76 | 30570.76 | NOISY |

The reference column is a noise/stability decision, not a release qualification.
Whole-process RSS/runtime and public managed-buffer ownership have different boundaries.
See [measurement contract](../../performance/end-to-end-baselines.md) and [raw corpus](native-final/report.json).
