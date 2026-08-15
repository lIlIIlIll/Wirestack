# Performance methodology

Performance claims are backend- and representation-specific. Typed codecs,
`JsonValue`, Pure Compact, Custom Native DOM, yyjson Direct Native DOM, serde
Value, raw yyjson, and simdjson DOM are not interchangeable results.

The retained Round-18 architecture was measured on an Intel Xeon Gold 6248R,
CPU 8 affinity, Cangjie SDK 20260803, Cangjie `-O2`, and native C
`-std=c11 -O3 -fPIC -DNDEBUG` without `-march=native` or LTO. Representative
yyjson semantic-adapter release-smoke ranges were:

| Workload | Approximate retained range |
|---|---:|
| Flat64 | 0.59–0.62 s |
| ObjectArray64 | 0.34 s |
| numeric64 | 0.42 s |
| Canada | 3.5 ms |
| Twitter | 0.89 ms |
| CITM | 1.55 ms |

These figures are regression references, not universal promises. They include
YJson-required duplicate, number, Unicode, and lifetime semantics. Raw yyjson
kernel numbers are a ceiling reference and must not be presented as adapter API
performance.

Memory also depends on shape. yyjson is often speed-for-memory relative to
Custom Native on huge objects, while numeric-heavy inputs may improve both time
and memory. Native heap reduction is not automatically total RSS reduction.

The grouped/control-byte semantic-index experiment was rejected and is not in
production: scalar candidates regressed about 47–48%, AVX2 candidates about
93–112%. Production retains the packed 8-byte semantic/runtime index. Native
DOM performance architecture is frozen for this release candidate; release
hardening reopens performance work only after a stable >10% regression or new
evidence of at least 15% realistic end-to-end upside.
